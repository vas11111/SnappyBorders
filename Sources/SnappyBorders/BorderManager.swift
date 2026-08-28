import Foundation
import CoreGraphics
import CSkyLight

final class BorderManager {
    static var shared: BorderManager?

    private(set) var settings: Settings
    private var borders: [UInt32: BorderWindow] = [:]
    private var ownWIDs: Set<UInt32> = []
    private var focusedWID: UInt32 = 0
    private var appNameCache: [pid_t: String] = [:]
    private var focusGeneration: UInt64 = 0
    private var pendingSpaceReconcile = false
    private var pendingResize: Set<UInt32> = []
    private var resizeDrainScheduled = false
    private var resizeGeneration: [UInt32: UInt64] = [:]
    /// Raw count of every window-server notification, by id. Tells us what the
    /// window server actually reports during a live resize, rather than what we
    /// assume it reports.
    private var eventCounts: [UInt32: Int] = [:]

    /// End-to-end timing of the update path, so "is it snappy" is a measurement
    /// rather than an impression. Costs one clock read per event.
    private struct Timing {
        var count = 0
        var totalNS: UInt64 = 0
        var maxNS: UInt64 = 0
        mutating func add(_ ns: UInt64) {
            count += 1; totalNS += ns; maxNS = max(maxNS, ns)
        }
        var summary: String {
            guard count > 0 else { return "none" }
            return String(format: "%d events, avg %.0f us, worst %.0f us",
                          count, Double(totalNS) / Double(count) / 1000, Double(maxNS) / 1000)
        }
    }
    private var moveTiming = Timing()
    private var frontQueryTiming = Timing()
    private var lastFrontProcess: UInt64 = 0
    /// A reorder naming a window we do not currently consider focused is the
    /// only way focus can move without the frontmost application changing.
    private var focusHintPending = false
    private var resizeTiming = Timing()
    private var focusTiming = Timing()

    @inline(__always)
    private func timed(_ t: inout Timing, _ body: () -> Void) {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        body()
        t.add(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start)
    }

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: - Bootstrap

    func start() {
        Events.installEventPortDrain()
        Events.register()
        adoptExistingWindows()
        trace("start: adopted, refreshing focus")
        refreshFocus()
        trace("start: focus refreshed")
    }

    private func adoptExistingWindows() {
        let spaces = WS.allSpaceIDs()
        let wids = WS.windowIDs(onSpaces: spaces)
        for snap in WS.snapshots(wids, includeCornerRadius: true) where snap.isSuitable {
            _ = makeBorder(for: snap, spaceID: 0)
        }
        trace("adopt: all borders made, syncing notifications for \(borders.count)")
        syncNotifications()
        trace("adopt: notifications synced")
        trace("adopt: flushed")
    }

    // MARK: - Border bookkeeping

    private func appName(for wid: UInt32) -> String {
        let pid = WS.ownerPID(wid)
        if let cached = appNameCache[pid] { return cached }
        // Bounded: pids are recycled and apps come and go over a long session.
        if appNameCache.count > 512 { appNameCache.removeAll(keepingCapacity: true) }
        var buf = [CChar](repeating: 0, count: 1024)
        proc_name(pid, &buf, UInt32(buf.count))
        let name = String(cString: buf)
        appNameCache[pid] = name
        return name
    }

    @discardableResult
    private func makeBorder(for snap: WS.Snapshot, spaceID: UInt64) -> BorderWindow? {
        guard settings.enabled else { return nil }
        if let existing = borders[snap.wid] { return existing }
        guard WS.ownerPID(snap.wid) != WS.pid else { return nil }
        guard settings.allows(app: appName(for: snap.wid)) else { return nil }

        let border = BorderWindow(targetWID: snap.wid)
        border.spaceID = spaceID != 0 ? spaceID : WS.spaceID(for: snap.wid)
        borders[snap.wid] = border
        border.update(target: snap, settings: settings, focused: snap.wid == focusedWID)
        refreshOwnWIDsIfNeeded(border)
        return border
    }

    private func destroyBorder(_ wid: UInt32) {
        trace("destroy border for target=\(wid)")
        guard let border = borders.removeValue(forKey: wid) else { return }
        ownWIDs.subtract(border.ownedWindowIDs)
        // Per-window bookkeeping has to go too, or these grow for the lifetime
        // of the process as windows come and go.
        resizeGeneration.removeValue(forKey: wid)
        pendingResize.remove(wid)
        border.destroy()
    }

    private func syncNotifications() {
        WS.requestNotifications(for: Array(borders.keys))
    }

    /// Re-reads which window ids belong to our own borders. Cheap, and only
    /// called when a border actually rebuilt its strip windows.
    private func refreshOwnWIDsIfNeeded(_ border: BorderWindow) {
        guard border.stripsDidChange else { return }
        border.clearStripsDidChange()
        ownWIDs.removeAll(keepingCapacity: true)
        for b in borders.values { ownWIDs.formUnion(b.ownedWindowIDs) }
    }

    // MARK: - Event handling

    func handleWindowEvent(_ event: UInt32, wid: UInt32) {
        guard settings.enabled, !ownWIDs.contains(wid) else { return }
        eventCounts[event, default: 0] += 1
        trace("event \(event) wid=\(wid) tracked=\(borders[wid] != nil)")

        switch event {
        case WSEvent.windowMove:
            // Hot path: only the origin moved, so skip every query except the
            // one that tells us where the window went.
            guard let border = borders[wid] else { return }
            timed(&moveTiming) {
                if let bounds = WS.bounds(wid) {
                    border.move(targetOrigin: bounds.origin, settings: settings)
                }
            }
            scheduleSettle(wid)

        case WSEvent.windowResize:
            // Coalesce. A live resize delivers events faster than a redraw
            // completes, and handling each one in turn builds a backlog that
            // makes the border trail further and further behind. Collapsing a
            // runloop pass worth of events into one update, using the latest
            // bounds, keeps it attached.
            guard borders[wid] != nil else { return }
            pendingResize.insert(wid)
            guard !resizeDrainScheduled else { return }
            resizeDrainScheduled = true
            DispatchQueue.main.async { [weak self] in self?.drainResizes() }

        case WSEvent.windowReorder, WSEvent.windowLevel:
            if let border = borders[wid], let snap = WS.snapshot(wid) {
                border.update(target: snap, settings: settings, focused: border.focused)
                refreshOwnWIDsIfNeeded(border)
            }
            if event == WSEvent.windowReorder {
                if wid != focusedWID { focusHintPending = true }
                scheduleFocusRefresh(authoritative: false)
            }

        case WSEvent.windowUnhide:
            borders[wid]?.show(settings: settings)

        case WSEvent.windowHide:
            borders[wid]?.hide()

        case WSEvent.windowClose:
            destroyBorder(wid)
            syncNotifications()

        case WSEvent.windowTitle, WSEvent.windowUpdate:
            scheduleFocusRefresh(authoritative: false)

        default:
            break
        }
    }

    private func drainResizes() {
        resizeDrainScheduled = false
        let pending = pendingResize
        pendingResize.removeAll(keepingCapacity: true)
        for wid in pending {
            guard let border = borders[wid] else { continue }
            timed(&resizeTiming) {
                if var snap = WS.snapshot(wid, includeCornerRadius: true) {
                    snap.wid = wid
                    border.update(target: snap, settings: settings, focused: border.focused)
                    refreshOwnWIDsIfNeeded(border)
                }
            }
            scheduleSettle(wid)
        }
    }

    /// Once a resize gesture stops, rebuild the border from scratch rather than
    /// from what we believe its state to be. Geometry and stacking are sent
    /// asynchronously and can be dropped or reordered while the window server is
    /// saturated mid-drag; without this the border stays broken afterwards,
    /// because our record says it is already correct. Once per gesture, so the
    /// cost does not land on the hot path.
    private func scheduleSettle(_ wid: UInt32) {
        let generation = (resizeGeneration[wid] ?? 0) &+ 1
        resizeGeneration[wid] = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.resizeGeneration[wid] == generation,
                  let border = self.borders[wid] else { return }
            border.markNeedsResync()
            if var snap = WS.snapshot(wid, includeCornerRadius: true) {
                snap.wid = wid
                border.update(target: snap, settings: self.settings, focused: border.focused)
                self.refreshOwnWIDsIfNeeded(border)
            }
        }
    }

    func handleSpawnEvent(_ event: UInt32, wid: UInt32, spaceID: UInt64) {
        eventCounts[event, default: 0] += 1
        trace("spawn event \(event) wid=\(wid) sid=\(spaceID)")
        guard settings.enabled, wid != 0, spaceID != 0, !ownWIDs.contains(wid) else { return }
        // Belt and braces: a border window we created can generate its own
        // spawn event before we have recorded its id, and reacting to that
        // would have us drawing borders around our own borders.
        guard WS.ownerPID(wid) != WS.pid else { return }
        switch event {
        case WSEvent.windowCreate:
            guard borders[wid] == nil, let snap = WS.snapshot(wid, includeCornerRadius: true), snap.isSuitable else { return }
            makeBorder(for: snap, spaceID: spaceID)
            syncNotifications()
            scheduleFocusRefresh()
        case WSEvent.windowDestroy:
            if let border = borders[wid], border.spaceID == spaceID || border.sticky {
                destroyBorder(wid)
                syncNotifications()
                scheduleFocusRefresh()
            }
        default:
            break
        }
    }

    func handleSpaceChange() {
        trace("space change")
        WS.invalidateSpaceCache()
        // JankyBorders sleeps 20ms here because native-fullscreen windows have
        // not settled yet. Reconcile immediately so the common case is instant,
        // then once more on the next runloop turn to catch the stragglers.
        reconcileVisibleSpaces()
        guard !pendingSpaceReconcile else { return }
        pendingSpaceReconcile = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pendingSpaceReconcile = false
            self?.reconcileVisibleSpaces()
        }
    }

    func rescan() { reconcileVisibleSpaces() }

    func resetCounters() {
        eventCounts.removeAll()
        OpCounts.reset()
        moveTiming = Timing(); resizeTiming = Timing()
        focusTiming = Timing(); frontQueryTiming = Timing()
    }

    private func reconcileVisibleSpaces() {
        let visible = WS.visibleSpaceIDs()
        guard !visible.isEmpty else { return }
        let visibleSet = Set(visible)
        let wids = WS.windowIDs(onSpaces: visible)
        var seen = Set<UInt32>()

        for snap in WS.snapshots(wids, includeCornerRadius: true) where snap.isSuitable {
            seen.insert(snap.wid)
            if let border = borders[snap.wid] {
                let sid = WS.spaceID(for: snap.wid)
                border.moveToSpace(sid)
                border.update(target: snap, settings: settings, focused: snap.wid == focusedWID)
                refreshOwnWIDsIfNeeded(border)
            } else {
                makeBorder(for: snap, spaceID: 0)
            }
        }

        // Anything we track that is not on a visible space must be ordered out,
        // otherwise it bleeds through onto the space that just came forward.
        for (wid, border) in borders where !seen.contains(wid) {
            if border.sticky { continue }
            if !visibleSet.contains(border.spaceID) { border.hide() }
        }

        syncNotifications()
    }

    // MARK: - Focus

    /// `authoritative` marks the front-application change, which is the event
    /// that actually means focus moved. It runs the query at once, so switching
    /// windows has no visible delay.
    ///
    /// Everything else - window reorders, title changes - is a hint. Those fire
    /// continuously while a window is being dragged, and resolving the front
    /// window costs a window list plus a batched query each time, so they only
    /// arm the trailing check. That alone removed ~120 redundant front-window
    /// queries per drag.
    func scheduleFocusRefresh(authoritative: Bool = true) {
        if authoritative { refreshFocus() }
        focusGeneration &+= 1
        let generation = focusGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            guard let self, self.focusGeneration == generation else { return }
            self.refreshFocus()
        }
    }

    func refreshFocus() {
        guard settings.enabled else { return }
        let focusStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer { focusTiming.add(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - focusStart) }
        trace("refreshFocus: querying front window")
        // Resolving the front window costs several synchronous window-server
        // round trips, and those get dramatically more expensive while the
        // server is busy handling a drag. Focus can only have moved if the
        // frontmost application changed, or a window we do not think is focused
        // was raised - and checking that costs well under a microsecond.
        let frontProcess = WS.frontProcessKey()
        if frontProcess == lastFrontProcess, !focusHintPending, focusedWID != 0,
           borders[focusedWID]?.focused == true {
            return
        }
        lastFrontProcess = frontProcess
        focusHintPending = false

        let q0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let front = WS.frontWindow()
        frontQueryTiming.add(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- q0)
        trace("refreshFocus: front=\(front)")
        // The frontmost process is not always one with windows: the lock
        // screen, Spotlight, a menu or a status item can all hold it. Dropping
        // focus in that case makes every border blink off, so keep the last
        // known focus until something real takes over.
        guard front != 0 else { return }
        guard front != focusedWID || borders[front]?.focused == false else { return }

        let previous = focusedWID
        focusedWID = front

        if previous != 0, let border = borders[previous], border.focused {
            if let snap = WS.snapshot(previous) {
                border.update(target: snap, settings: settings, focused: false)
                refreshOwnWIDsIfNeeded(border)
            }
        }
        if front != 0 {
            if let border = borders[front] {
                if let snap = WS.snapshot(front) {
                    border.update(target: snap, settings: settings, focused: true)
                    refreshOwnWIDsIfNeeded(border)
                }
            } else if let snap = WS.snapshot(front, includeCornerRadius: true), snap.isSuitable {
                // A window we had not seen yet just took focus.
                makeBorder(for: snap, spaceID: 0)
                borders[front]?.update(target: snap, settings: settings, focused: true)
                syncNotifications()
            }
        }
    }

    // MARK: - Settings

    func apply(arguments: [String]) {
        // A `window=<id>` prefix scopes the rest of the message to one border.
        var targetWID: UInt32?
        var rest: [String] = []
        for arg in arguments {
            if arg.hasPrefix("window=") {
                targetWID = UInt32(arg.dropFirst(7))
            } else {
                rest.append(arg)
            }
        }

        if let targetWID, let border = borders[targetWID] {
            var overrides = border.overrides ?? settings
            SettingsParser.apply(rest, to: &overrides)
            border.overrides = overrides
            border.invalidate()
            if let snap = WS.snapshot(targetWID) {
                border.update(target: snap, settings: settings, focused: border.focused, force: true)
                refreshOwnWIDsIfNeeded(border)
            }
            return
        }

        let mask = SettingsParser.apply(rest, to: &settings)
        guard !mask.isEmpty else { return }

        if mask.contains(.recreate) {
            let tracked = Array(borders.keys)
            for wid in tracked { destroyBorder(wid) }
            if settings.enabled { adoptExistingWindows(); refreshFocus() }
            return
        }

        for (wid, border) in borders {
            let wantsUpdate = mask.contains(.geometry)
                || (border.focused && mask.contains(.active))
                || (!border.focused && mask.contains(.inactive))
            guard wantsUpdate, let snap = WS.snapshot(wid) else { continue }
            border.invalidate()
            border.update(target: snap, settings: settings, focused: border.focused, force: true)
            refreshOwnWIDsIfNeeded(border)
        }
    }

    private func fmt(_ r: CGRect) -> String {
        String(format: "%.0f,%.0f %.0fx%.0f", r.origin.x, r.origin.y, r.width, r.height)
    }

    /// Front-to-back on-screen order, as the window server reports it. Lets us
    /// confirm a border landed next to its target without looking at pixels.
    private func zIndexMap() -> [UInt32: Int] {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [:] }
        var map: [UInt32: Int] = [:]
        for (idx, i) in infos.enumerated() {
            if let n = i[kCGWindowNumber as String] as? UInt32 { map[n] = idx }
        }
        return map
    }

    var statusReport: String {
        let z = zIndexMap()
        var lines: [String] = []
        lines.append("snappyborders: \(borders.count) tracked window(s), focus=\(focusedWID)")
        lines.append("  move:   \(moveTiming.summary)")
        lines.append("  resize: \(resizeTiming.summary)")
        lines.append("  focus:  \(focusTiming.summary)")
        lines.append("  front-window query: \(frontQueryTiming.summary)")
        lines.append("  stages: \(DrawStats.summary)")
        lines.append("  geometry: \(GeometryCheck.summary)")
        lines.append("  ops:      \(OpCounts.summary)")
        let names: [UInt32: String] = [723: "update", 804: "close", 806: "MOVE", 807: "RESIZE",
                                       808: "reorder", 811: "level", 815: "unhide", 816: "hide",
                                       1322: "title", 1325: "create", 1326: "destroy"]
        let counts = eventCounts.sorted { $0.value > $1.value }
            .map { "\(names[$0.key] ?? "\($0.key)")=\($0.value)" }
            .joined(separator: " ")
        lines.append("  events:   \(counts.isEmpty ? "none" : counts)")
        for (wid, border) in borders.sorted(by: { $0.key < $1.key }) {
            let t = WS.bounds(wid) ?? .zero
            let outset = (border.overrides ?? settings).outset
            let expected = t.insetBy(dx: -outset, dy: -outset)
            let f = border.borderFrame
            let onScreen = border.ownedWindowIDs.filter { z[$0] != nil }.count
            // A hidden border is not kept up to date on purpose, so comparing
            // its frame to the window would report a problem that is not one.
            let tracking = border.wid == 0 ? "-"
                : onScreen == 0 ? "hidden"
                : (abs(f.origin.x - expected.origin.x) < 0.5 && abs(f.origin.y - expected.origin.y) < 0.5
                   && abs(f.width - expected.width) < 0.5 && abs(f.height - expected.height) < 0.5
                   ? "in-sync" : "OUT-OF-SYNC by \(Int(f.origin.x - expected.origin.x)),\(Int(f.origin.y - expected.origin.y))")
            lines.append("  target=\(wid) space=\(border.spaceID) focused=\(border.focused) "
                         + "radius=\(Int(border.cornerRadius)) \(tracking) "
                         + "onScreen=\(onScreen)/\(border.stripCount)")
            lines.append("      window \(fmt(t))  border \(fmt(f))")
            lines.append("      \(border.diagnostics)")
            lines.append("      \(border.displayDiagnostics)")
            lines.append("      \(border.liveStripGeometry)")
            let stripZ = border.ownedWindowIDs.compactMap { z[$0] }.sorted()
            if let tz = z[wid], border.stripCount > 0 {
                // Lower index is nearer the front, so strips stacked above the
                // window occupy the slots before it and below-stacked ones the
                // slots after it.
                let n = border.stripCount
                let expected: Set<Int> = (border.overrides ?? settings).order == .above
                    ? Set((tz - n)...(tz - 1)) : Set((tz + 1)...(tz + n))
                let ok = stripZ.allSatisfy { expected.contains($0) }
                lines.append("      z: target=\(tz) strips=\(stripZ) \(ok ? "adjacent" : "*** NOT ADJACENT ***")")
            }
        }
        return lines.joined(separator: "\n")
    }
}
