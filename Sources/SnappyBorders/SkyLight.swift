import Foundation
import CoreGraphics
import CSkyLight

/// Thin, allocation-light Swift wrappers over the window-server API.
enum WS {
    static let cid: CGSConnectionID = SLSMainConnectionID()
    static let pid: pid_t = ProcessInfo.processInfo.processIdentifier

    // MARK: - Regions

    static func region(_ rect: CGRect) -> CGSRegion {
        var r = rect
        var out: Unmanaged<CGSRegion>?
        CGSNewRegionWithRect(&r, &out)
        return out!.takeRetainedValue()
    }

    static let emptyRegion: CGSRegion = CGRegionCreateEmptyRegion().takeRetainedValue()

    // MARK: - CFArray of window ids

    static func cfArray(_ wids: [UInt32]) -> CFArray {
        let numbers = wids.map { wid -> CFNumber in
            var v = wid
            return CFNumberCreate(nil, .sInt32Type, &v)
        }
        return numbers as CFArray
    }

    static func cfArray64(_ values: [UInt64]) -> CFArray {
        let numbers = values.map { v -> CFNumber in
            var x = v
            return CFNumberCreate(nil, .sInt64Type, &x)
        }
        return numbers as CFArray
    }

    // MARK: - Window queries

    static func bounds(_ wid: UInt32) -> CGRect? {
        var r = CGRect.zero
        guard SLSGetWindowBounds(cid, wid, &r) == .success else { return nil }
        return r
    }

    static func isOrderedIn(_ wid: UInt32) -> Bool {
        var shown = false
        SLSWindowIsOrderedIn(cid, wid, &shown)
        return shown
    }

    static func level(_ wid: UInt32) -> Int32 {
        var l: Int64 = 0
        SLSGetWindowLevel(cid, wid, &l)
        return Int32(truncatingIfNeeded: l)
    }

    /// JankyBorders reaches for a hand-rolled mach message here because it
    /// assumes the symbol is unavailable; it is exported, so use it directly.
    /// That removes the per-OS-version hardcoded MIG message ids entirely.
    static func subLevel(_ wid: UInt32) -> Int32 {
        SLSGetWindowSubLevel(cid, wid)
    }

    static func ownerPID(_ wid: UInt32) -> pid_t {
        var ownerCID: CGSConnectionID = 0
        SLSGetWindowOwner(cid, wid, &ownerCID)
        var p: pid_t = 0
        SLSConnectionGetPID(ownerCID, &p)
        return p
    }

    /// One round trip for everything the border needs about a target window.
    struct Snapshot {
        var wid: UInt32 = 0
        var tags: UInt64 = 0
        var attributes: UInt64 = 0
        var parent: UInt32 = 0
        var level: Int32 = 0
        var bounds: CGRect = .zero
        var cornerRadius: CGFloat = 0

        static let tagDocument: UInt64      = 1 << 0
        static let tagFloating: UInt64      = 1 << 1
        static let tagAttached: UInt64      = 1 << 7
        static let tagSticky: UInt64        = 1 << 11
        static let tagIgnoresCycle: UInt64  = 1 << 18
        static let tagModal: UInt64         = 1 << 31

        var isSticky: Bool { tags & Snapshot.tagSticky != 0 }

        /// Mirrors JankyBorders' `window_suitable`: a real, cycle-able,
        /// top-level window rather than a panel, sheet or helper surface.
        var isSuitable: Bool {
            parent == 0
                && ((attributes & 0x2) != 0 || (tags & 0x400_0000_0000_0000) != 0)
                && (tags & Snapshot.tagAttached) == 0
                && (tags & Snapshot.tagIgnoresCycle) == 0
                && ((tags & Snapshot.tagDocument) != 0
                    || ((tags & Snapshot.tagFloating) != 0 && (tags & Snapshot.tagModal) != 0))
        }
    }

    private static let getCornerRadii: (@convention(c) (CFTypeRef) -> Unmanaged<CFArray>?)? = {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL),
              let sym = dlsym(lib, "SLSWindowIteratorGetCornerRadii") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (CFTypeRef) -> Unmanaged<CFArray>?).self)
    }()

    static func snapshots(_ wids: [UInt32], includeCornerRadius: Bool = false) -> [Snapshot] {
        guard !wids.isEmpty else { return [] }
        guard let query = SLSWindowQueryWindows(cid, cfArray(wids), 0)?.takeRetainedValue(),
              let it = SLSWindowQueryResultCopyWindows(query)?.takeRetainedValue()
        else { return [] }

        var out: [Snapshot] = []
        out.reserveCapacity(wids.count)
        while SLSWindowIteratorAdvance(it) {
            var s = Snapshot()
            s.wid = SLSWindowIteratorGetWindowID(it)
            s.tags = SLSWindowIteratorGetTags(it)
            s.attributes = SLSWindowIteratorGetAttributes(it)
            s.parent = SLSWindowIteratorGetParentID(it)
            s.level = Int32(SLSWindowIteratorGetLevel(it))
            s.bounds = SLSWindowIteratorGetBounds(it)
            // "Get" semantics: the array belongs to the iterator. Consuming it
            // as +1 over-releases and corrupts the process a while later.
            if includeCornerRadius, let f = getCornerRadii,
               let radii = f(it)?.takeUnretainedValue() as? [NSNumber],
               let first = radii.first {
                s.cornerRadius = CGFloat(first.doubleValue)
            }
            out.append(s)
        }
        return out
    }

    static func snapshot(_ wid: UInt32, includeCornerRadius: Bool = false) -> Snapshot? {
        snapshots([wid], includeCornerRadius: includeCornerRadius).first
    }

    // MARK: - Spaces

    static func spaceID(for wid: UInt32) -> UInt64 {
        if let spaces = SLSCopySpacesForWindows(cid, 0x7, cfArray([wid]))?.takeRetainedValue() as? [NSNumber],
           let first = spaces.first, first.uint64Value != 0 {
            return first.uint64Value
        }
        if let uuid = SLSCopyManagedDisplayForWindow(cid, wid)?.takeRetainedValue() {
            return SLSManagedDisplayGetCurrentSpace(cid, uuid)
        }
        return 0
    }

    /// Cached because resolving the front window needs it and that happens on
    /// every focus hint. Three window-server round trips per call otherwise.
    nonisolated(unsafe) private static var cachedVisibleSpaces: [UInt64]?

    static func invalidateSpaceCache() { cachedVisibleSpaces = nil }

    static func visibleSpaceIDs() -> [UInt64] {
        if let cached = cachedVisibleSpaces { return cached }
        guard let displays = SLSCopyManagedDisplays(cid)?.takeRetainedValue() as? [CFString] else { return [] }
        let spaces = displays.map { SLSManagedDisplayGetCurrentSpace(cid, $0) }
        cachedVisibleSpaces = spaces
        return spaces
    }

    static func allSpaceIDs() -> [UInt64] {
        guard let displaySpaces = SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var out: [UInt64] = []
        for display in displaySpaces {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                if let id = space["id64"] as? NSNumber { out.append(id.uint64Value) }
            }
        }
        return out
    }

    static func windowIDs(onSpaces spaces: [UInt64]) -> [UInt32] {
        guard !spaces.isEmpty else { return [] }
        var setTags: UInt64 = 1
        var clearTags: UInt64 = 0
        guard let list = SLSCopyWindowsWithOptionsAndTags(cid, 0, cfArray64(spaces), 0x2,
                                                          &setTags, &clearTags)?.takeRetainedValue() as? [NSNumber]
        else { return [] }
        return list.map { $0.uint32Value }
    }

    static func send(_ wid: UInt32, toSpace sid: UInt64) {
        guard sid != 0 else { return }
        SLSMoveWindowsToManagedSpace(cid, cfArray([wid]), sid)
    }

    // MARK: - Front window

    /// Identity of the frontmost process. Two orders of magnitude cheaper than
    /// resolving the front *window* (0.6 us against ~100 us idle, and far more
    /// than that when the window server is busy), so it is worth checking first.
    static func frontProcessKey() -> UInt64 {
        var psn = ProcessSerialNumber()
        guard _SLPSGetFrontProcess(&psn) == noErr else { return 0 }
        return UInt64(psn.highLongOfPSN) << 32 | UInt64(psn.lowLongOfPSN)
    }

    static func frontWindow() -> UInt32 {
        var psn = ProcessSerialNumber()
        guard _SLPSGetFrontProcess(&psn) == noErr else { return 0 }
        var targetCID: CGSConnectionID = 0
        guard SLSGetConnectionIDForPSN(cid, &psn, &targetCID) == .success else { return 0 }

        let activeSpaces = visibleSpaceIDs()
        guard !activeSpaces.isEmpty else { return 0 }
        var setTags: UInt64 = 1
        var clearTags: UInt64 = 0
        guard let list = SLSCopyWindowsWithOptionsAndTags(cid, UInt32(bitPattern: targetCID),
                                                          cfArray64(activeSpaces), 0x2,
                                                          &setTags, &clearTags)?.takeRetainedValue() as? [NSNumber],
              !list.isEmpty
        else { return 0 }

        for snap in snapshots(list.map { $0.uint32Value }) where snap.isSuitable {
            return snap.wid
        }
        return 0
    }

    // MARK: - Notifications

    static func requestNotifications(for wids: [UInt32]) {
        guard !wids.isEmpty else { return }
        var list = wids
        SLSRequestNotificationsForWindows(cid, &list, Int32(list.count))
    }

    // MARK: - Display scale

    /// The screen a rect sits on, with its bounds so callers can tell cheaply
    /// when a window has moved to a different one. Returns nil when no screen
    /// contains the point - a window can sit off-screen or straddle a gap
    /// between displays - so callers can keep what they have rather than act on
    /// a wrong answer.
    static func display(for rect: CGRect) -> (bounds: CGRect, scale: CGFloat)? {
        var display = CGDirectDisplayID(0)
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(CGPoint(x: rect.midX, y: rect.midY), 1, &display, &count)
        guard count > 0 else { return nil }
        let bounds = CGDisplayBounds(display)
        guard let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else {
            return (bounds, 2.0)
        }
        return (bounds, CGFloat(mode.pixelWidth) / CGFloat(mode.width))
    }

}

/// RAII wrapper: every geometry change goes through one async transaction.
/// Committing asynchronously (`synchronous: 0`) is what keeps the update off
/// the critical path - a synchronous commit would block on the window server.
struct Transaction {
    let ref: CFTypeRef

    init?() {
        guard let r = SLSTransactionCreate(WS.cid)?.takeRetainedValue() else { return nil }
        ref = r
    }

    func move(_ wid: UInt32, to origin: CGPoint) {
        SLSTransactionMoveWindowWithGroup(ref, wid, origin)
    }

    func setShape(_ wid: UInt32, origin: CGPoint, shape: CGSRegion) {
        SLSTransactionSetWindowShape(ref, wid, Float(origin.x), Float(origin.y), shape)
    }

    func setLevel(_ wid: UInt32, _ level: Int32) {
        SLSTransactionSetWindowLevel(ref, wid, level)
    }

    func setSubLevel(_ wid: UInt32, _ subLevel: Int32) {
        SLSTransactionSetWindowSubLevel(ref, wid, subLevel)
    }

    func order(_ wid: UInt32, _ order: Int32, relativeTo rel: UInt32) {
        SLSTransactionOrderWindow(ref, wid, order, rel)
    }

    func setAlpha(_ wid: UInt32, _ alpha: Float) {
        SLSTransactionSetWindowAlpha(ref, wid, alpha)
    }

    func commit() {
        SLSTransactionCommit(ref, 0)
    }

    /// Blocks until the window server has applied the transaction. Needed
    /// before creating a drawing context for a window that was just reshaped:
    /// the context binds to whatever backing store exists at that moment, so
    /// with an async commit it can still be the old, smaller one and everything
    /// painted into it is clipped to the previous size. Measured at ~200us
    /// against ~180us for an async commit, so the safety is nearly free.
    func commitSynchronously() {
        SLSTransactionCommit(ref, 1)
    }
}
