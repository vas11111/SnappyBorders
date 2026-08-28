import Foundation
import CoreGraphics
import CSkyLight

/// Can we read a window's backing store directly? If so we can verify what is
/// actually in it - including whether a freshly reshaped one is already zeroed,
/// which decides whether the expensive per-redraw clear is needed at all.
func probePixels() {
    setbuf(stdout, nil)
    let cid = SLSMainConnectionID()

    func newWin(_ w: CGFloat, _ h: CGFloat) -> UInt32 {
        var r = CGRect(x: 0, y: 0, width: w, height: h)
        var reg: Unmanaged<CGSRegion>?
        CGSNewRegionWithRect(&r, &reg)
        var wid: UInt32 = 0
        var tags: UInt64 = (1 << 1) | (1 << 9)
        SLSNewWindowWithOpaqueShapeAndContext(cid, 2, reg!.takeRetainedValue(),
                                              CGRegionCreateEmptyRegion().takeRetainedValue(),
                                              13, &tags, -30000, -30000, 64, &wid, nil)
        SLSSetWindowTags(cid, wid, &tags, 64)
        SLSSetWindowOpacity(cid, wid, false)
        SLSSetWindowResolution(cid, wid, 1.0)
        return wid
    }

    let wid = newWin(200, 60)
    guard let ctx = SLWindowContextCreate(cid, wid, nil)?.takeRetainedValue() else {
        print("no context"); return
    }
    print("context: \(ctx.width)x\(ctx.height) bpr=\(ctx.bytesPerRow) bpp=\(ctx.bitsPerPixel)")
    guard let data = ctx.data else {
        print("CGBitmapContextGetData -> nil (backing store not directly readable)")
        SLSReleaseWindow(cid, wid); return
    }
    print("CGBitmapContextGetData -> readable")

    func sample(_ label: String) {
        let px = data.assumingMemoryBound(to: UInt8.self)
        var nonZero = 0
        var first: [UInt8] = []
        let count = min(ctx.bytesPerRow * ctx.height, 200 * 60 * 4)
        for i in 0..<count where px[i] != 0 { nonZero += 1 }
        for i in 0..<8 { first.append(px[i]) }
        print("  \(label): nonZeroBytes=\(nonZero)/\(count) firstBytes=\(first)")
    }

    sample("fresh window, nothing drawn")

    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 60))
    ctx.flush()
    SLSFlushWindowContentRegion(cid, wid, nil)
    sample("after filling opaque red")

    // Reshape larger: is the replacement backing store zeroed?
    var r2 = CGRect(x: 0, y: 0, width: 300, height: 90)
    var reg2: Unmanaged<CGSRegion>?
    CGSNewRegionWithRect(&r2, &reg2)
    SLSSetWindowShape(cid, wid, -30000, -30000, reg2!.takeRetainedValue())
    guard let ctx2 = SLWindowContextCreate(cid, wid, nil)?.takeRetainedValue(), let d2 = ctx2.data else {
        print("no context after reshape"); SLSReleaseWindow(cid, wid); return
    }
    let px2 = d2.assumingMemoryBound(to: UInt8.self)
    var nz = 0
    let n2 = ctx2.bytesPerRow * ctx2.height
    for i in 0..<n2 where px2[i] != 0 { nz += 1 }
    print("  after reshape 200x60 -> 300x90: size=\(ctx2.width)x\(ctx2.height) nonZeroBytes=\(nz)/\(n2)")
    print("  => fresh backing store is \(nz == 0 ? "ZEROED (clear can be skipped)" : "NOT zeroed (clear required)")")

    SLSReleaseWindow(cid, wid)
}
