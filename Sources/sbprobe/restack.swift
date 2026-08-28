import Foundation
import CoreGraphics
import CSkyLight

/// Does changing a window's shape disturb its position in the stack?
func probeRestack() {
    setbuf(stdout, nil)
    let cid = SLSMainConnectionID()
    let me = ProcessInfo.processInfo.processIdentifier

    var target: UInt32 = 0
    var tb = CGRect.zero
    if let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        for i in infos {
            guard let pid = i[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let l = i[kCGWindowLayer as String] as? Int, l == 0,
                  let n = i[kCGWindowNumber as String] as? UInt32,
                  let bd = i[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bd["Width"], let h = bd["Height"], w > 300, h > 300 else { continue }
            target = n; tb = CGRect(x: bd["X"]!, y: bd["Y"]!, width: w, height: h); break
        }
    }
    guard target != 0 else { print("no target"); return }

    func zmap() -> [UInt32: Int] {
        var m: [UInt32: Int] = [:]
        if let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for (i, info) in infos.enumerated() {
                if let n = info[kCGWindowNumber as String] as? UInt32 { m[n] = i }
            }
        }
        return m
    }
    func report(_ label: String, _ wid: UInt32) {
        let m = zmap()
        let s = m[wid].map(String.init) ?? "not on screen"
        let t = m[target].map(String.init) ?? "?"
        print("  \(label): strip z=\(s)  target z=\(t)")
    }

    var r = CGRect(x: 0, y: 0, width: 600, height: 40)
    var reg: Unmanaged<CGSRegion>?
    CGSNewRegionWithRect(&r, &reg)
    var wid: UInt32 = 0
    var tags: UInt64 = (1 << 1) | (1 << 9)
    var clear: UInt64 = 0
    SLSNewWindowWithOpaqueShapeAndContext(cid, 2, reg!.takeRetainedValue(),
                                          CGRegionCreateEmptyRegion().takeRetainedValue(),
                                          13, &tags, Float(tb.minX), Float(tb.minY), 64, &wid, nil)
    SLSSetWindowTags(cid, wid, &tags, 64)
    SLSClearWindowTags(cid, wid, &clear, 64)
    SLSSetWindowOpacity(cid, wid, false)
    SLSSetWindowAlpha(cid, wid, 1.0)
    if let raw = SLWindowContextCreate(cid, wid, nil)?.takeRetainedValue() {
        raw.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 1, alpha: 1))
        raw.fill(CGRect(x: 0, y: 0, width: 600, height: 40))
        raw.flush(); SLSFlushWindowContentRegion(cid, wid, nil)
    }
    if let sp = SLSCopySpacesForWindows(cid, 0x7, [target] as CFArray)?.takeRetainedValue() as? [NSNumber],
       let sid = sp.first?.uint64Value, sid != 0 {
        SLSMoveWindowsToManagedSpace(cid, [wid] as CFArray, sid)
    }
    var lvl: Int64 = 0; SLSGetWindowLevel(cid, target, &lvl)
    SLSSetWindowLevel(cid, wid, Int32(lvl))
    SLSOrderWindow(cid, wid, -1, target)
    usleep(250_000)
    report("after ordering below target", wid)

    // Reshape via transaction, exactly as the resize path does.
    for i in 1...3 {
        var r2 = CGRect(x: 0, y: 0, width: 600 + Double(i) * 20, height: 40)
        var reg2: Unmanaged<CGSRegion>?
        CGSNewRegionWithRect(&r2, &reg2)
        if let t = SLSTransactionCreate(cid)?.takeRetainedValue() {
            SLSTransactionSetWindowShape(t, wid, 0, 0, reg2!.takeRetainedValue())
            SLSTransactionMoveWindowWithGroup(t, wid, CGPoint(x: tb.minX, y: tb.minY))
            SLSTransactionCommit(t, 0)
        }
        usleep(250_000)
        report("after transaction reshape #\(i)", wid)
    }

    // And via the direct call.
    var r3 = CGRect(x: 0, y: 0, width: 700, height: 40)
    var reg3: Unmanaged<CGSRegion>?
    CGSNewRegionWithRect(&r3, &reg3)
    SLSSetWindowShape(cid, wid, Float(tb.minX), Float(tb.minY), reg3!.takeRetainedValue())
    usleep(250_000)
    report("after direct SLSSetWindowShape", wid)

    SLSOrderWindow(cid, wid, -1, target)
    usleep(250_000)
    report("after re-ordering below target", wid)

    SLSReleaseWindow(cid, wid)
}
