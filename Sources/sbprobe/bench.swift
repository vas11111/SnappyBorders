import Foundation
import CoreGraphics
import QuartzCore
import ObjectiveC.runtime
import CSkyLight

private func ns() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

private func time(_ name: String, _ n: Int, _ body: () -> Void) {
    body() // warm
    let t0 = ns()
    for _ in 0..<n { body() }
    let t1 = ns()
    let per = Double(t1 - t0) / Double(n) / 1000.0
    print(String(format: "  %-46s %8.1f us/op", (name as NSString).utf8String!, per))
}

func probeBench() {
    setbuf(stdout, nil)
    let cid = SLSMainConnectionID()

    // A target window owned by someone else, to measure cross-process queries.
    var target: UInt32 = 0
    let me = ProcessInfo.processInfo.processIdentifier
    if let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        for i in infos {
            if let pid = i[kCGWindowOwnerPID as String] as? Int32, pid != me,
               let l = i[kCGWindowLayer as String] as? Int, l == 0,
               let n = i[kCGWindowNumber as String] as? UInt32 { target = n; break }
        }
    }
    print("target wid = \(target)")

    print("\n[window-server queries]")
    var b = CGRect.zero
    time("SLSGetWindowBounds (other app's window)", 2000) { _ = SLSGetWindowBounds(cid, target, &b) }
    var lvl: Int64 = 0
    time("SLSGetWindowLevel", 2000) { _ = SLSGetWindowLevel(cid, target, &lvl) }
    time("SLSGetWindowSubLevel", 2000) { _ = SLSGetWindowSubLevel(cid, target) }
    var shown = false
    time("SLSWindowIsOrderedIn", 2000) { _ = SLSWindowIsOrderedIn(cid, target, &shown) }

    let arr = [target] as CFArray
    time("SLSWindowQueryWindows + iterate (tags/level/bounds)", 1000) {
        guard let q = SLSWindowQueryWindows(cid, arr, 0)?.takeRetainedValue() else { return }
        guard let it = SLSWindowQueryResultCopyWindows(q)?.takeRetainedValue() else { return }
        if SLSWindowIteratorAdvance(it) {
            _ = SLSWindowIteratorGetTags(it)
            _ = SLSWindowIteratorGetLevel(it)
            _ = SLSWindowIteratorGetBounds(it)
        }
    }

    // Our border window.
    let W = 1600.0, H = 1000.0
    var rect = CGRect(x: 0, y: 0, width: W, height: H)
    var reg: Unmanaged<CGSRegion>?
    CGSNewRegionWithRect(&rect, &reg)
    let region = reg!.takeRetainedValue()
    let empty = CGRegionCreateEmptyRegion().takeRetainedValue()
    var wid: UInt32 = 0
    var tags: UInt64 = (1 << 1) | (1 << 9)
    SLSNewWindowWithOpaqueShapeAndContext(cid, 2, region, empty, 13 | (1 << 18), &tags, 100, 100, 64, &wid, nil)
    SLSSetWindowTags(cid, wid, &tags, 64)
    SLSSetWindowOpacity(cid, wid, false)
    SLSSetWindowResolution(cid, wid, 2.0)

    print("\n[geometry updates]")
    var i = 0
    time("region create + SLSSetWindowShape", 2000) {
        i += 1
        var r = CGRect(x: 0, y: 0, width: W + Double(i % 20), height: H)
        var rr: Unmanaged<CGSRegion>?
        CGSNewRegionWithRect(&r, &rr)
        _ = SLSSetWindowShape(cid, wid, 100, 100, rr!.takeRetainedValue())
    }
    time("transaction: shape + order + commit", 2000) {
        i += 1
        var r = CGRect(x: 0, y: 0, width: W + Double(i % 20), height: H)
        var rr: Unmanaged<CGSRegion>?
        CGSNewRegionWithRect(&r, &rr)
        guard let t = SLSTransactionCreate(cid)?.takeRetainedValue() else { return }
        SLSTransactionSetWindowShape(t, wid, 100, 100, rr!.takeRetainedValue())
        SLSTransactionOrderWindow(t, wid, -1, target)
        SLSTransactionCommit(t, 0)
    }
    var p = CGPoint(x: 100, y: 100)
    time("SLSMoveWindow", 2000) { i += 1; p.x = 100 + Double(i % 40); _ = SLSMoveWindow(cid, wid, &p) }

    // CoreAnimation layer update (what our resize path costs).
    let cls: AnyClass = NSClassFromString("CAContext")!
    let sel = NSSelectorFromString("contextWithCGSConnection:options:")
    typealias Fn = @convention(c) (AnyObject, Selector, Int32, NSDictionary?) -> AnyObject?
    let fn = unsafeBitCast(method_getImplementation(class_getClassMethod(cls, sel)!), to: Fn.self)
    let ctx = fn(cls, sel, cid, [:] as NSDictionary)!
    let ctxId = (ctx.value(forKey: "contextId") as! NSNumber).uint32Value
    let root = CALayer()
    root.bounds = CGRect(x: 0, y: 0, width: W, height: H)
    root.position = CGPoint(x: W/2, y: H/2)
    let ring = CALayer()
    ring.frame = root.bounds
    ring.borderWidth = 5; ring.cornerRadius = 12
    ring.borderColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    root.addSublayer(ring)
    ctx.setValue(root, forKey: "layer")
    CATransaction.flush()
    var sid: UInt32 = 0
    SLSAddSurface(cid, wid, &sid)
    SLSSetSurfaceBounds(cid, wid, sid, root.bounds)
    SLSOrderSurface(cid, wid, sid, 1, 0)
    print("bindSurface err=\(SLSBindSurface(cid, wid, sid, ctxId).rawValue)")

    print("\n[content updates]")
    time("CA: set layer bounds + flush (no rasterization)", 2000) {
        i += 1
        let w = W + Double(i % 20)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.bounds = CGRect(x: 0, y: 0, width: w, height: H)
        root.position = CGPoint(x: w/2, y: H/2)
        ring.frame = CGRect(x: 0, y: 0, width: w, height: H)
        CATransaction.commit()
        CATransaction.flush()
    }

    print("\n[per-resize costs: what the update path may repeat]")
    var madeWIDs: [UInt32] = []
    time("SLSNewWindowWithOpaqueShapeAndContext", 300) {
        var r = CGRect(x: 0, y: 0, width: 1600, height: 40)
        var rr: Unmanaged<CGSRegion>?
        CGSNewRegionWithRect(&r, &rr)
        var w: UInt32 = 0
        var tg: UInt64 = (1 << 1) | (1 << 9)
        SLSNewWindowWithOpaqueShapeAndContext(cid, 2, rr!.takeRetainedValue(),
                                              CGRegionCreateEmptyRegion().takeRetainedValue(),
                                              13, &tg, -30000, -30000, 64, &w, nil)
        if w != 0 { madeWIDs.append(w) }
    }
    for w in madeWIDs { SLSReleaseWindow(cid, w) }
    madeWIDs.removeAll()

    var stripW: UInt32 = 0
    do {
        var r = CGRect(x: 0, y: 0, width: 1600, height: 40)
        var rr: Unmanaged<CGSRegion>?
        CGSNewRegionWithRect(&r, &rr)
        var tg: UInt64 = (1 << 1) | (1 << 9)
        SLSNewWindowWithOpaqueShapeAndContext(cid, 2, rr!.takeRetainedValue(),
                                              CGRegionCreateEmptyRegion().takeRetainedValue(),
                                              13, &tg, -30000, -30000, 64, &stripW, nil)
        SLSSetWindowResolution(cid, stripW, 2.0)
    }
    time("SLWindowContextCreate (per strip)", 300) {
        _ = SLWindowContextCreate(cid, stripW, nil)?.takeRetainedValue()
    }
    var j = 0
    time("txn: 4x (setShape + move) + commit", 500) {
        j += 1
        guard let t = SLSTransactionCreate(cid)?.takeRetainedValue() else { return }
        for k in 0..<4 {
            var r = CGRect(x: 0, y: 0, width: 1600 + Double(j % 8), height: 40)
            var rr: Unmanaged<CGSRegion>?
            CGSNewRegionWithRect(&r, &rr)
            SLSTransactionSetWindowShape(t, stripW, -30000, -30000, rr!.takeRetainedValue())
            SLSTransactionMoveWindowWithGroup(t, stripW, CGPoint(x: -30000 + Double(k), y: -30000))
        }
        SLSTransactionCommit(t, 0)
    }
    time("4x SLSOrderWindow", 500) {
        for _ in 0..<4 { _ = SLSOrderWindow(cid, stripW, 1, target) }
    }
    time("8x SLSSetWindowTags/ClearWindowTags", 500) {
        var st: UInt64 = (1 << 1) | (1 << 9)
        var ct: UInt64 = 0
        for _ in 0..<4 {
            SLSSetWindowTags(cid, stripW, &st, 64)
            SLSClearWindowTags(cid, stripW, &ct, 64)
        }
    }
    if let raw = SLWindowContextCreate(cid, stripW, nil)?.takeRetainedValue() {
        let sc = unsafeBitCast(raw, to: CGContext.self)
        func paint() {
            sc.clear(CGRect(x: 0, y: 0, width: 1600, height: 40))
            sc.setLineWidth(4)
            sc.setStrokeColor(CGColor(gray: 1, alpha: 1))
            sc.addPath(CGPath(roundedRect: CGRect(x: 14, y: -1000, width: 1572, height: 2000),
                              cornerWidth: 16, cornerHeight: 16, transform: nil))
            sc.strokePath()
        }
        let bigPath = CGPath(roundedRect: CGRect(x: 14, y: -1000, width: 1572, height: 2000),
                             cornerWidth: 16, cornerHeight: 16, transform: nil)
        let smallPath = CGPath(rect: CGRect(x: 14, y: 10, width: 1572, height: 20), transform: nil)
        time("clear 1600x40 only", 500) { sc.clear(CGRect(x: 0, y: 0, width: 1600, height: 40)) }
        time("stroke big rounded path only", 500) {
            sc.setLineWidth(4); sc.addPath(bigPath); sc.strokePath()
        }
        time("stroke big path WITH clip to strip", 500) {
            sc.saveGState()
            sc.clip(to: CGRect(x: 0, y: 0, width: 1600, height: 40))
            sc.setLineWidth(4); sc.addPath(bigPath); sc.strokePath()
            sc.restoreGState()
        }
        time("stroke small in-strip path only", 500) {
            sc.setLineWidth(4); sc.addPath(smallPath); sc.strokePath()
        }
        time("strip: draw only (no flush)", 500) { paint() }
        time("strip: draw + CGContextFlush", 500) { paint(); sc.flush() }
        time("strip: draw + SLSFlushWindowContentRegion", 500) {
            paint(); SLSFlushWindowContentRegion(cid, stripW, nil)
        }
        time("strip: draw + both flushes", 500) {
            paint(); sc.flush(); SLSFlushWindowContentRegion(cid, stripW, nil)
        }
        time("CGContextFlush alone", 500) { sc.flush() }
        time("SLSFlushWindowContentRegion alone", 500) { SLSFlushWindowContentRegion(cid, stripW, nil) }
    }
    SLSReleaseWindow(cid, stripW)

    print("\n[async vs synchronous reshape commit]")
    do {
        var wids: [UInt32] = []
        for _ in 0..<4 {
            var rr = CGRect(x: 0, y: 0, width: 900, height: 30)
            var rreg: Unmanaged<CGSRegion>?
            CGSNewRegionWithRect(&rr, &rreg)
            var sw: UInt32 = 0
            var tg2: UInt64 = (1 << 1) | (1 << 9)
            SLSNewWindowWithOpaqueShapeAndContext(cid, 2, rreg!.takeRetainedValue(),
                                                  CGRegionCreateEmptyRegion().takeRetainedValue(),
                                                  13, &tg2, -30000, -30000, 64, &sw, nil)
            wids.append(sw)
        }
        var k = 0
        func reshape(_ sync: Int32) {
            k += 1
            guard let t = SLSTransactionCreate(cid)?.takeRetainedValue() else { return }
            for w in wids {
                var r = CGRect(x: 0, y: 0, width: 900 + Double(k % 40), height: 30)
                var rr: Unmanaged<CGSRegion>?
                CGSNewRegionWithRect(&r, &rr)
                SLSTransactionSetWindowShape(t, w, 0, 0, rr!.takeRetainedValue())
                SLSTransactionMoveWindowWithGroup(t, w, CGPoint(x: -30000, y: -30000))
            }
            SLSTransactionCommit(t, sync)
        }
        time("4x reshape, async commit", 300) { reshape(0) }
        time("4x reshape, synchronous commit", 300) { reshape(1) }

        // Does the context we get straight after an async commit describe the
        // new size, or the one we just replaced?
        var asyncWrong = 0, syncWrong = 0
        for round in 0..<80 {
            let want = 700.0 + Double(round % 30) * 5
            for (i, w) in wids.enumerated() {
                var r = CGRect(x: 0, y: 0, width: want, height: 30)
                var rr: Unmanaged<CGSRegion>?
                CGSNewRegionWithRect(&r, &rr)
                guard let t = SLSTransactionCreate(cid)?.takeRetainedValue() else { continue }
                SLSTransactionSetWindowShape(t, w, 0, 0, rr!.takeRetainedValue())
                SLSTransactionCommit(t, i < 2 ? 0 : 1)
                var b = CGRect.zero
                SLSGetWindowBounds(cid, w, &b)
                if abs(b.width - want) > 0.5 { if i < 2 { asyncWrong += 1 } else { syncWrong += 1 } }
            }
        }
        print("  bounds wrong straight after commit: async \(asyncWrong)/160, sync \(syncWrong)/160")
        for w in wids { SLSReleaseWindow(cid, w) }
    }

    print("\n[can the fixed per-op cost be batched away?]")
    do {
        var wids: [UInt32] = []
        var ctxs: [CGContext] = []
        for _ in 0..<4 {
            var rr = CGRect(x: 0, y: 0, width: 900, height: 30)
            var rreg: Unmanaged<CGSRegion>?
            CGSNewRegionWithRect(&rr, &rreg)
            var sw: UInt32 = 0
            var tg2: UInt64 = (1 << 1) | (1 << 9)
            SLSNewWindowWithOpaqueShapeAndContext(cid, 2, rreg!.takeRetainedValue(),
                                                  CGRegionCreateEmptyRegion().takeRetainedValue(),
                                                  13, &tg2, -30000, -30000, 64, &sw, nil)
            SLSSetWindowResolution(cid, sw, 2.0)
            if let raw2 = SLWindowContextCreate(cid, sw, nil)?.takeRetainedValue() {
                wids.append(sw); ctxs.append(raw2)
            }
        }
        let local = CGRect(x: 0, y: 0, width: 900, height: 30)
        let seg = CGMutablePath()
        seg.move(to: CGPoint(x: 10, y: 0)); seg.addLine(to: CGPoint(x: 10, y: 30))
        func paintAll() {
            for c in ctxs {
                c.clear(local)
                c.setLineWidth(3); c.addPath(seg); c.strokePath()
            }
            for (i, c) in ctxs.enumerated() {
                c.flush(); SLSFlushWindowContentRegion(cid, wids[i], nil)
            }
        }
        time("4 strips x (clear+stroke), plain", 200) { paintAll() }
        time("4 strips, inside DisableUpdate/Reenable", 200) {
            SLSDisableUpdate(cid); paintAll(); SLSReenableUpdate(cid)
        }
        time("4 strips, inside Freeze/Thaw", 200) {
            for w in wids { SLSWindowFreezeWithOptions(cid, w, nil) }
            paintAll()
            for w in wids { SLSWindowThaw(cid, w) }
        }
        // One prepared image blitted per strip: one drawing op instead of two.
        let cs = CGColorSpaceCreateDeviceRGB()
        let bmp = CGContext(data: nil, width: 1800, height: 60, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)!
        time("4 strips, render to bitmap + 1 blit each", 200) {
            bmp.clear(CGRect(x: 0, y: 0, width: 1800, height: 60))
            bmp.setStrokeColor(CGColor(gray: 1, alpha: 1))
            bmp.setLineWidth(6); bmp.addPath(seg); bmp.strokePath()
            guard let img = bmp.makeImage() else { return }
            for (i, c) in ctxs.enumerated() {
                c.setBlendMode(.copy)
                c.draw(img, in: local)
                c.setBlendMode(.normal)
                c.flush(); SLSFlushWindowContentRegion(cid, wids[i], nil)
            }
        }
        for w in wids { SLSReleaseWindow(cid, w) }
    }

    print("\n[draw cost vs strip size: fixed overhead or area?]")
    for (w, h) in [(100.0, 20.0), (400.0, 20.0), (900.0, 20.0), (1600.0, 40.0), (1600.0, 200.0), (1600.0, 1000.0)] {
        var rr = CGRect(x: 0, y: 0, width: w, height: h)
        var rreg: Unmanaged<CGSRegion>?
        CGSNewRegionWithRect(&rr, &rreg)
        var sw: UInt32 = 0
        var tg2: UInt64 = (1 << 1) | (1 << 9)
        SLSNewWindowWithOpaqueShapeAndContext(cid, 2, rreg!.takeRetainedValue(),
                                              CGRegionCreateEmptyRegion().takeRetainedValue(),
                                              13, &tg2, -30000, -30000, 64, &sw, nil)
        SLSSetWindowResolution(cid, sw, 2.0)
        guard let raw2 = SLWindowContextCreate(cid, sw, nil)?.takeRetainedValue() else { continue }
        let gc2 = raw2
        let local = CGRect(x: 0, y: 0, width: w, height: h)
        let seg = CGMutablePath()
        seg.move(to: CGPoint(x: 10, y: 0))
        seg.addLine(to: CGPoint(x: 10, y: h))
        time(String(format: "clear %.0fx%.0f", w, h), 400) { gc2.clear(local) }
        time(String(format: "stroke short segment in %.0fx%.0f", w, h), 400) {
            gc2.setLineWidth(3); gc2.addPath(seg); gc2.strokePath()
        }
        SLSReleaseWindow(cid, sw)
    }

    // JankyBorders' path: full-frame CGContext clear + rounded-rect stroke.
    guard let cgctx = SLWindowContextCreate(cid, wid, nil)?.takeRetainedValue() else {
        print("  (SLWindowContextCreate failed - skipping CGContext comparison)")
        SLSReleaseWindow(cid, wid); return
    }
    let ctx2 = unsafeBitCast(cgctx, to: CGContext.self)
    time("CGContext: clear + stroke full frame + flush", 300) {
        i += 1
        let frame = CGRect(x: 0, y: 0, width: W + Double(i % 20), height: H)
        ctx2.saveGState()
        ctx2.setLineWidth(5)
        ctx2.clear(frame)
        let path = CGPath(roundedRect: frame.insetBy(dx: 6, dy: 6), cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx2.addPath(path)
        ctx2.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx2.strokePath()
        ctx2.flush()
        ctx2.restoreGState()
        SLSFlushWindowContentRegion(cid, wid, nil)
    }
    SLSReleaseWindow(cid, wid)
}
