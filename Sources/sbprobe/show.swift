import Foundation
import CoreGraphics
import QuartzCore
import ObjectiveC.runtime
import CSkyLight

private var keep: [AnyObject] = []

/// Puts two opaque rectangles on screen side by side:
///   left  = content from a bound CAContext layer tree (the snappyborders path)
///   right = content drawn into the window backing store (the JankyBorders path)
/// Whichever appears tells us which rendering path actually composites.
func probeShow() {
    setbuf(stdout, nil)
    let cid = SLSMainConnectionID()
    let activeSpace = WSSpace.current(cid)
    print("active space = \(activeSpace)")

    func newWindow(_ frame: CGRect, backingStore: Bool) -> UInt32 {
        var local = CGRect(origin: .zero, size: frame.size)
        var reg: Unmanaged<CGSRegion>?
        CGSNewRegionWithRect(&local, &reg)
        var wid: UInt32 = 0
        var tags: UInt64 = (1 << 1) | (1 << 9)
        let opts: Int32 = backingStore ? 13 : 9
        let e = SLSNewWindowWithOpaqueShapeAndContext(cid, 2, reg!.takeRetainedValue(),
                                                      CGRegionCreateEmptyRegion().takeRetainedValue(),
                                                      opts, &tags,
                                                      Float(frame.origin.x), Float(frame.origin.y),
                                                      64, &wid, nil)
        print("  newWindow err=\(e.rawValue) wid=\(wid) opts=\(opts)")
        var clear: UInt64 = 0
        SLSSetWindowTags(cid, wid, &tags, 64)
        SLSClearWindowTags(cid, wid, &clear, 64)
        SLSSetWindowOpacity(cid, wid, false)
        SLSSetWindowAlpha(cid, wid, 1.0)
        SLSSetWindowResolution(cid, wid, 1.0)
        if activeSpace != 0 {
            SLSMoveWindowsToManagedSpace(cid, [wid] as CFArray, activeSpace)
        }
        return wid
    }

    // --- Left: CAContext layer tree -------------------------------------
    let aFrame = CGRect(x: 300, y: 300, width: 300, height: 200)
    print("A: CAContext layer tree at \(aFrame)")
    let a = newWindow(aFrame, backingStore: true)
    let cls: AnyClass = NSClassFromString("CAContext")!
    let sel = NSSelectorFromString("contextWithCGSConnection:options:")
    typealias Fn = @convention(c) (AnyObject, Selector, Int32, NSDictionary?) -> AnyObject?
    let fn = unsafeBitCast(method_getImplementation(class_getClassMethod(cls, sel)!), to: Fn.self)
    let ctx = fn(cls, sel, cid, [:] as NSDictionary)!
    keep.append(ctx)
    let root = CALayer()
    root.anchorPoint = .zero
    root.position = .zero
    root.bounds = CGRect(origin: .zero, size: aFrame.size)
    root.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)   // magenta
    ctx.setValue(root, forKey: "layer")
    CATransaction.flush()
    let ctxId = (ctx.value(forKey: "contextId") as! NSNumber).uint32Value
    var sidA: UInt32 = 0
    SLSAddSurface(cid, a, &sidA)
    SLSSetSurfaceBounds(cid, a, sidA, root.bounds)
    SLSSetSurfaceResolution(cid, a, sidA, 1.0)
    SLSOrderSurface(cid, a, sidA, 1, 0)
    print("  bind err=\(SLSBindSurface(cid, a, sidA, ctxId).rawValue)")
    SLSSetWindowLevel(cid, a, 20)
    SLSOrderWindow(cid, a, 1, 0)

    // --- Right: window backing store ------------------------------------
    let bFrame = CGRect(x: 650, y: 300, width: 300, height: 200)
    print("B: CGContext backing store at \(bFrame)")
    let b = newWindow(bFrame, backingStore: true)
    if let raw = SLWindowContextCreate(cid, b, nil)?.takeRetainedValue() {
        let gc = unsafeBitCast(raw, to: CGContext.self)
        gc.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 1, alpha: 1))     // cyan
        gc.fill(CGRect(origin: .zero, size: bFrame.size))
        gc.flush()
        SLSFlushWindowContentRegion(cid, b, nil)
        print("  drew into backing store")
    } else {
        print("  SLWindowContextCreate FAILED")
    }
    SLSSetWindowLevel(cid, b, 20)
    SLSOrderWindow(cid, b, 1, 0)

    CATransaction.flush()
    var ba = CGRect.zero, bb = CGRect.zero
    SLSGetWindowBounds(cid, a, &ba); SLSGetWindowBounds(cid, b, &bb)
    var oa = false, ob = false
    SLSWindowIsOrderedIn(cid, a, &oa); SLSWindowIsOrderedIn(cid, b, &ob)
    print("A bounds=\(ba) orderedIn=\(oa)   B bounds=\(bb) orderedIn=\(ob)")
    print("Holding: MAGENTA (left) = CAContext, CYAN (right) = backing store")

    let hold = Double(ProcessInfo.processInfo.environment["SB_HOLD"] ?? "30") ?? 30
    RunLoop.main.run(until: Date().addingTimeInterval(hold))
    SLSReleaseWindow(cid, a)
    SLSReleaseWindow(cid, b)
    print("done")
}

enum WSSpace {
    static func current(_ cid: Int32) -> UInt64 {
        guard let displays = SLSCopyManagedDisplays(cid)?.takeRetainedValue() as? [CFString],
              let first = displays.first else { return 0 }
        return SLSManagedDisplayGetCurrentSpace(cid, first)
    }
}
