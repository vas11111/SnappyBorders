import Foundation
import CoreGraphics
import CSkyLight

/// Creates and destroys windows so a running daemon has real window-server
/// events to react to.
func probeChurn() {
    setbuf(stdout, nil)
    let cid = SLSMainConnectionID()
    for i in 1...4 {
        var r = CGRect(x: 0, y: 0, width: 300, height: 200)
        var reg: Unmanaged<CGSRegion>?
        CGSNewRegionWithRect(&r, &reg)
        var wid: UInt32 = 0
        var tags: UInt64 = (1 << 1) | (1 << 9)
        SLSNewWindowWithOpaqueShapeAndContext(cid, 2, reg!.takeRetainedValue(),
                                              CGRegionCreateEmptyRegion().takeRetainedValue(),
                                              13, &tags, 400, 400, 64, &wid, nil)
        SLSSetWindowTags(cid, wid, &tags, 64)
        SLSOrderWindow(cid, wid, 1, 0)
        usleep(200_000)
        var p = CGPoint(x: 400 + Double(i) * 30, y: 400)
        SLSMoveWindow(cid, wid, &p)
        usleep(200_000)
        SLSReleaseWindow(cid, wid)
        usleep(200_000)
        print("churn \(i) wid=\(wid)")
    }
}
