import Foundation
import CoreGraphics
import CSkyLight

/// CGWindowListCopyWindowInfo returns on-screen windows front-to-back, so it is
/// a direct read-back of where a border actually landed in the stack.
func probeZOrder() {
    setbuf(stdout, nil)
    let cid = SLSMainConnectionID()
    let me = ProcessInfo.processInfo.processIdentifier

    var target: UInt32 = 0
    var targetBounds = CGRect.zero
    var targetName = ""
    if let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        for i in infos {
            guard let pid = i[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let l = i[kCGWindowLayer as String] as? Int, l == 0,
                  let n = i[kCGWindowNumber as String] as? UInt32,
                  let bd = i[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bd["Width"], let h = bd["Height"], w > 300, h > 300 else { continue }
            target = n
            targetName = (i[kCGWindowOwnerName as String] as? String) ?? "?"
            targetBounds = CGRect(x: bd["X"]!, y: bd["Y"]!, width: w, height: h)
            break
        }
    }
    guard target != 0 else { print("no target"); return }
    var tLvl: Int64 = 0
    SLSGetWindowLevel(cid, target, &tLvl)
    print("target \(targetName) wid=\(target) reportedLevel=\(tLvl) bounds=\(targetBounds)\n")

    let sidList = SLSCopySpacesForWindows(cid, 0x7, [target] as CFArray)?.takeRetainedValue() as? [NSNumber]
    let sid = sidList?.first?.uint64Value ?? 0

    func stackReport(_ wid: UInt32) -> String {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return "no list" }
        var mine = -1, theirs = -1, myLayer = 0
        for (idx, i) in infos.enumerated() {
            guard let n = i[kCGWindowNumber as String] as? UInt32 else { continue }
            if n == wid { mine = idx; myLayer = (i[kCGWindowLayer as String] as? Int) ?? 0 }
            if n == target { theirs = idx }
        }
        if mine < 0 { return "NOT in on-screen list (layer set may exclude it)" }
        let rel = theirs < 0 ? "target missing" : (mine < theirs ? "ABOVE target by \(theirs - mine)" : "below target by \(mine - theirs)")
        return "index=\(mine) targetIndex=\(theirs) layer=\(myLayer) -> \(rel)"
    }

    for level in [Int32(-1), 0, 1, 2, 3, 4, 20] {
        var tags: UInt64 = (1 << 1) | (1 << 9)
        var clear: UInt64 = 0
        var wid: UInt32 = 0
        var r = CGRect(x: 0, y: 0, width: 240, height: 170)
        var reg: Unmanaged<CGSRegion>?
        CGSNewRegionWithRect(&r, &reg)
        SLSNewWindowWithOpaqueShapeAndContext(cid, 2, reg!.takeRetainedValue(),
                                              CGRegionCreateEmptyRegion().takeRetainedValue(), 13, &tags,
                                              Float(targetBounds.minX + 100), Float(targetBounds.minY + 100),
                                              64, &wid, nil)
        SLSSetWindowTags(cid, wid, &tags, 64)
        SLSClearWindowTags(cid, wid, &clear, 64)
        SLSSetWindowOpacity(cid, wid, false)
        SLSSetWindowAlpha(cid, wid, 1.0)
        if let raw = SLWindowContextCreate(cid, wid, nil)?.takeRetainedValue() {
            let gc = raw
            gc.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            gc.fill(CGRect(x: 0, y: 0, width: 240, height: 170))
            gc.flush()
            SLSFlushWindowContentRegion(cid, wid, nil)
        }
        if sid != 0 { SLSMoveWindowsToManagedSpace(cid, [wid] as CFArray, sid) }
        SLSSetWindowLevel(cid, wid, level)
        SLSOrderWindow(cid, wid, 1, target)
        usleep(250_000)
        var readBack: Int64 = 0
        SLSGetWindowLevel(cid, wid, &readBack)
        print(String(format: "level set=%-4d readback=%-4d  %@", level, readBack, stackReport(wid) as NSString))
        SLSReleaseWindow(cid, wid)
        usleep(80_000)
    }
}
