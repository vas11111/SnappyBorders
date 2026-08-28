import Foundation
import CoreGraphics
import CSkyLight

/// Step-by-step breakdown of front-window resolution.
func probeFront() {
    setbuf(stdout, nil)
    let cid = SLSMainConnectionID()
    var psn = ProcessSerialNumber()
    let e = _SLPSGetFrontProcess(&psn)
    print("_SLPSGetFrontProcess err=\(e) psn=(\(psn.highLongOfPSN), \(psn.lowLongOfPSN))")

    var targetCID: CGSConnectionID = 0
    let e2 = SLSGetConnectionIDForPSN(cid, &psn, &targetCID)
    print("SLSGetConnectionIDForPSN err=\(e2.rawValue) targetCID=\(targetCID)")
    var pid: pid_t = 0
    SLSConnectionGetPID(targetCID, &pid)
    var nameBuf = [CChar](repeating: 0, count: 1024)
    proc_name(pid, &nameBuf, 1024)
    print("front process pid=\(pid) name=\(String(cString: nameBuf))")

    guard let displays = SLSCopyManagedDisplays(cid)?.takeRetainedValue() as? [CFString] else {
        print("no managed displays"); return
    }
    let spaces = displays.map { SLSManagedDisplayGetCurrentSpace(cid, $0) }
    print("displays=\(displays.count) currentSpaces=\(spaces)")

    let spaceArr = spaces.map { v -> CFNumber in var x = v; return CFNumberCreate(nil, .sInt64Type, &x) } as CFArray
    var setTags: UInt64 = 1
    var clearTags: UInt64 = 0
    let list = SLSCopyWindowsWithOptionsAndTags(cid, UInt32(bitPattern: targetCID), spaceArr, 0x2,
                                                &setTags, &clearTags)?.takeRetainedValue() as? [NSNumber]
    print("windows for front process on those spaces: \(list?.count ?? -1) -> \(list?.map { $0.uint32Value } ?? [])")

    if let list, !list.isEmpty {
        let wids = list.map { $0.uint32Value }
        guard let q = SLSWindowQueryWindows(cid, wids as CFArray, 0)?.takeRetainedValue(),
              let it = SLSWindowQueryResultCopyWindows(q)?.takeRetainedValue() else { return }
        while SLSWindowIteratorAdvance(it) {
            let w = SLSWindowIteratorGetWindowID(it)
            let tags = SLSWindowIteratorGetTags(it)
            let attrs = SLSWindowIteratorGetAttributes(it)
            let parent = SLSWindowIteratorGetParentID(it)
            let suitable = parent == 0
                && ((attrs & 0x2) != 0 || (tags & 0x400_0000_0000_0000) != 0)
                && (tags & (1 << 7)) == 0 && (tags & (1 << 18)) == 0
                && ((tags & 1) != 0 || ((tags & (1 << 1)) != 0 && (tags & (1 << 31)) != 0))
            print("  wid=\(w) tags=0x\(String(tags, radix: 16)) attrs=0x\(String(attrs, radix: 16)) parent=\(parent) suitable=\(suitable)")
        }
    }

    // Cost of each step, since resolving the front window dominates focus.
    func bench(_ name: String, _ n: Int, _ body: () -> Void) {
        body()
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for _ in 0..<n { body() }
        let t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        print(String(format: "  %-52s %8.1f us", (name as NSString).utf8String!,
                     Double(t1 - t0) / Double(n) / 1000))
    }
    print("\n[cost of each step in front-window resolution]")
    bench("_SLPSGetFrontProcess", 500) { var p = ProcessSerialNumber(); _ = _SLPSGetFrontProcess(&p) }
    bench("SLSGetConnectionIDForPSN", 500) { var c: Int32 = 0; _ = SLSGetConnectionIDForPSN(cid, &psn, &c) }
    bench("SLSCopyManagedDisplays + current space", 500) {
        if let d = SLSCopyManagedDisplays(cid)?.takeRetainedValue() as? [CFString] {
            for u in d { _ = SLSManagedDisplayGetCurrentSpace(cid, u) }
        }
    }
    bench("SLSCopyWindowsWithOptionsAndTags (front app)", 500) {
        var st: UInt64 = 1; var ct: UInt64 = 0
        _ = SLSCopyWindowsWithOptionsAndTags(cid, UInt32(bitPattern: targetCID), spaceArr, 0x2, &st, &ct)?.takeRetainedValue()
    }
    if let list, !list.isEmpty {
        let wids = list.map { $0.uint32Value } as CFArray
        bench("SLSWindowQueryWindows + full iterate", 500) {
            guard let q = SLSWindowQueryWindows(cid, wids, 0)?.takeRetainedValue(),
                  let it = SLSWindowQueryResultCopyWindows(q)?.takeRetainedValue() else { return }
            while SLSWindowIteratorAdvance(it) {
                _ = SLSWindowIteratorGetTags(it); _ = SLSWindowIteratorGetAttributes(it)
                _ = SLSWindowIteratorGetParentID(it); _ = SLSWindowIteratorGetBounds(it)
            }
        }
        bench("SLSWindowQueryWindows + stop at first suitable", 500) {
            guard let q = SLSWindowQueryWindows(cid, wids, 0)?.takeRetainedValue(),
                  let it = SLSWindowQueryResultCopyWindows(q)?.takeRetainedValue() else { return }
            while SLSWindowIteratorAdvance(it) {
                let tg = SLSWindowIteratorGetTags(it)
                let at = SLSWindowIteratorGetAttributes(it)
                if SLSWindowIteratorGetParentID(it) == 0
                    && ((at & 0x2) != 0 || (tg & 0x400_0000_0000_0000) != 0)
                    && (tg & 1) != 0 { break }
            }
        }
    }

    // What does the plain on-screen list say is frontmost?
    if let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        print("top of on-screen list:")
        for i in infos.prefix(4) {
            print("  wid=\(i[kCGWindowNumber as String] ?? "?") layer=\(i[kCGWindowLayer as String] ?? "?") owner=\(i[kCGWindowOwnerName as String] ?? "?")")
        }
    }
}
