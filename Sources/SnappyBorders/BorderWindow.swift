import Foundation
import CoreGraphics
import CSkyLight

let sbTrace = ProcessInfo.processInfo.environment["SB_TRACE"] != nil
@inline(__always) func trace(_ s: @autoclosure () -> String) {
    guard sbTrace else { return }
    FileHandle.standardError.write(Data(("[trace] " + s() + "\n").utf8))
}

/// Stage timings for the resize path, so the cost can be attributed rather than
/// guessed at. Cheap enough to leave in: two clock reads per stage.
let sbVerify = ProcessInfo.processInfo.environment["SB_VERIFY"] != nil

/// Counts strips whose real geometry does not match what we asked for. If the
/// window server ever drops or reorders a shape/move, this is where it shows.
enum GeometryCheck {
    nonisolated(unsafe) static var checked = 0
    nonisolated(unsafe) static var wrong = 0
    nonisolated(unsafe) static var orderedOut = 0
    nonisolated(unsafe) static var notAdjacent = 0
    nonisolated(unsafe) static var samples: [String] = []
    static var summary: String {
        checked == 0 ? "not checked (set SB_VERIFY=1)"
            : "\(wrong)/\(checked) wrong geometry, \(orderedOut) ordered out, \(notAdjacent) not adjacent to target"
              + (samples.isEmpty ? "" : "; e.g. " + samples.prefix(3).joined(separator: " | "))
    }
}

/// Raw counts of the expensive structural operations. If a border falls apart
/// while resizing, one of these is happening when it should not be.
enum OpCounts {
    nonisolated(unsafe) static var windowsCreated = 0
    nonisolated(unsafe) static var rebuilds = 0
    nonisolated(unsafe) static var reshapes = 0
    nonisolated(unsafe) static var stripsReshaped = 0
    nonisolated(unsafe) static var draws = 0
    nonisolated(unsafe) static var hides = 0
    nonisolated(unsafe) static var orders = 0
    static func reset() {
        windowsCreated = 0; rebuilds = 0; reshapes = 0
        stripsReshaped = 0; draws = 0; hides = 0; orders = 0
    }
    static var summary: String {
        "windowsCreated=\(windowsCreated) rebuilds=\(rebuilds) reshapes=\(reshapes) "
            + "stripsReshaped=\(stripsReshaped) draws=\(draws) hides=\(hides) orderCalls=\(orders)"
    }
}

enum DrawStats {
    nonisolated(unsafe) static var reshapeNS: UInt64 = 0
    nonisolated(unsafe) static var reshapeCount = 0
    nonisolated(unsafe) static var contextNS: UInt64 = 0
    nonisolated(unsafe) static var clearNS: UInt64 = 0
    nonisolated(unsafe) static var strokeNS: UInt64 = 0
    nonisolated(unsafe) static var flushNS: UInt64 = 0
    nonisolated(unsafe) static var drawCount = 0

    static var summary: String {
        guard drawCount > 0 || reshapeCount > 0 else { return "no draws yet" }
        func us(_ ns: UInt64, _ n: Int) -> Double { n > 0 ? Double(ns) / Double(n) / 1000 : 0 }
        return String(format:
            "reshape %.0fus (txn) + %.0fus (ctx) over %d | per draw: clear %.0fus stroke %.0fus flush %.0fus over %d",
            us(reshapeNS, reshapeCount), us(contextNS, reshapeCount), reshapeCount,
            us(clearNS, drawCount), us(strokeNS, drawCount), us(flushNS, drawCount), drawCount)
    }
}

@inline(__always) func nowNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// One border, drawn as thin window-server windows arranged as a picture frame
/// around the target window.
///
/// Two things dominate this design, both measured rather than assumed
/// (`sbprobe bench`):
///
/// 1. The window server gives every window a backing store covering its whole
///    bounding box. A border drawn as one window the size of its target costs
///    `w * h * 4` bytes at 1x and four times that at 2x - ~128 MB for a 4K
///    window - to paint a few pixels at the edge. Strips make that cost track
///    the border's perimeter instead of the window's area.
///
/// 2. Creating a window-server window costs ~1-3 ms. Nothing on the update path
///    may create one. Strips are created once and then reshaped in place; the
///    drawing context is recreated after a reshape, which costs ~1 us.
///
/// So: a move is one transaction and no drawing at all; a resize is one
/// transaction plus a redraw of the strips; level, stacking and tags are cached
/// and only re-sent when they actually change.
final class BorderWindow {
    let targetWID: UInt32

    /// Which part of the ring a strip is responsible for. Knowing this lets
    /// each strip stroke only its own segment; stroking the whole ring in every
    /// strip makes the rasteriser scan the full window bounding box four times
    /// over, which is most of what a resize used to cost.
    enum StripKind: Equatable { case bottom, top, left, right, whole }

    private struct Strip {
        var wid: UInt32 = 0
        var context: CGContext?
        var kind: StripKind = .whole
        /// Position within the border frame, in the drawing context's own
        /// bottom-left-origin space.
        var rect: CGRect = .zero
        var needsDraw = true
        /// What this strip last painted. A strip only redraws when its own
        /// segment changes: widening a window moves the side strips but leaves
        /// the straight segment they draw identical, and a drawing operation
        /// costs a flat ~200us, so skipping them halves the work of an
        /// edge drag.
        var content: ContentKey?
    }

    /// The parameters that determine what a single strip paints, in its own
    /// local coordinates.
    private struct ContentKey: Equatable {
        var kind: StripKind
        var style: ColorStyle
        var width: CGFloat
        var glowRadius: CGFloat
        var radius: CGFloat
        var debugFill: Bool
        var gradientWidth: CGFloat = 0, gradientHeight: CGFloat = 0
        var p0: CGFloat = 0, p1: CGFloat = 0, p2: CGFloat = 0, p3: CGFloat = 0
    }

    private func contentKey(for strip: Strip, _ s: Settings, frameSize: CGSize) -> ContentKey {
        let rect = strokeRect(s)
        let glow = s.glowSlack(focused ? s.active : s.inactive)
        let band = min(s.outset + radius(for: s) + s.width + glow + 2, frameSize.height / 2)
        var key = ContentKey(kind: strip.kind, style: focused ? s.active : s.inactive,
                             width: s.width, glowRadius: s.glowRadius, radius: strokeRadius(s),
                             debugFill: s.debugFill)
        if case .gradient = key.style {
            key.gradientWidth = rect.width
            key.gradientHeight = rect.height
        }
        let ox = strip.rect.minX, oy = strip.rect.minY
        switch strip.kind {
        case .bottom:
            key.p0 = rect.minX - ox; key.p1 = rect.maxX - ox
            key.p2 = rect.minY - oy; key.p3 = min(band + 1, rect.midY) - oy
        case .top:
            key.p0 = rect.minX - ox; key.p1 = rect.maxX - ox
            key.p2 = rect.maxY - oy; key.p3 = max(frameSize.height - band - 1, rect.midY) - oy
        case .left:
            key.p0 = rect.minX - ox; key.p1 = band - 1 - oy
            key.p2 = frameSize.height - band + 1 - oy
        case .right:
            key.p0 = rect.maxX - ox; key.p1 = band - 1 - oy
            key.p2 = frameSize.height - band + 1 - oy
        case .whole:
            key.p0 = rect.minX - ox; key.p1 = rect.minY - oy
            key.p2 = rect.width; key.p3 = rect.height
        }
        return key
    }
    private var strips: [Strip] = []
    private var layoutRects: [CGRect] = []

    var spaceID: UInt64 = 0
    var focused = false
    var cornerRadius: CGFloat = 9
    var sticky = false
    var overrides: Settings?

    private var windowFrame: CGRect = .zero
    private var targetSize: CGSize = .zero
    private var scale: CGFloat = 2
    private var displayBounds: CGRect = .infinite
    private var isOrderedIn = false
    private var tooSmall = false
    private var needsRedraw = true
    private var appliedLevel: Int32 = .min
    private var appliedSubLevel: Int32 = .min
    private var appliedOrder: Int32 = 0
    private var appliedSticky: Bool?
    private(set) var stripsDidChange = false
    /// Offscreen mode: strips render into bitmaps instead of window-server
    /// windows, so the real update path can be driven through a sequence of
    /// resizes and the result inspected. Everything below takes the same
    /// branches it takes live; only the surfaces differ.
    var simulated = false
    /// Forces the next update to reshape and repaint every strip, even ones
    /// whose size we believe is already correct. The update path tracks the
    /// geometry it *asked* for, so a shape or stacking change the window server
    /// drops mid-gesture is never noticed and the border stays broken. A resync
    /// after a resize settles repairs that.
    private var pendingResync = false

    func markNeedsResync() { pendingResync = true }

    init(targetWID: UInt32) {
        self.targetWID = targetWID
    }

    static func validSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0
            && size.width <= 32768 && size.height <= 32768
    }

    private func bitmapSize(_ size: CGSize) -> (width: Int, height: Int)? {
        guard Self.validSize(size) else { return nil }
        let width = Int(ceil(size.width * 2)), height = Int(ceil(size.height * 2))
        guard width * height <= 16_777_216 else { return nil } // 64 MiB per bitmap
        return (width, height)
    }

    private func validSurface(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            && size.width * size.height * scale * scale <= 67_108_864
    }

    var wid: UInt32 { strips.first?.wid ?? 0 }
    var ownedWindowIDs: Set<UInt32> { Set(strips.map(\.wid)) }
    var stripCount: Int { strips.count }
    var borderFrame: CGRect { windowFrame }

    // MARK: - Geometry

    func radius(for s: Settings) -> CGFloat {
        switch s.style {
        case .round:   return cornerRadius
        case .uniform: return 9
        case .square:  return 0
        }
    }

    /// The target window's rect inside the border frame.
    private func targetRect(_ s: Settings) -> CGRect {
        CGRect(x: s.outset, y: s.outset, width: targetSize.width, height: targetSize.height)
    }

    /// Centreline of the stroke. Offsetting by half the width puts the stroke
    /// entirely *outside* the window: its inner edge lands exactly on the window
    /// edge, so `width=3` shows three points of border rather than hiding half
    /// of it behind the window the way a centred stroke does.
    func strokeRect(_ s: Settings) -> CGRect {
        targetRect(s).insetBy(dx: -s.width / 2, dy: -s.width / 2)
    }

    func strokeRadius(_ s: Settings) -> CGFloat {
        let r = radius(for: s)
        return r > 0 ? r + s.width / 2 : 0
    }

    /// Strips covering every pixel the stroke (and any glow) can reach.
    func stripLayout(_ s: Settings, frameSize: CGSize) -> [(StripKind, CGRect)] {
        let glow = s.glowSlack(focused ? s.active : s.inactive)
        let thickness = min(s.outset + glow + 2, frameSize.width / 2)
        let band = min(s.outset + radius(for: s) + s.width + glow + 2, frameSize.height / 2)
        let W = frameSize.width, H = frameSize.height
        guard s.strips else { return [(.whole, CGRect(x: 0, y: 0, width: W, height: H))] }

        let middle = H - 2 * band
        guard middle > 1 else {
            return [(.whole, CGRect(x: 0, y: 0, width: W, height: H / 2)),
                    (.whole, CGRect(x: 0, y: H / 2, width: W, height: H - H / 2))]
        }
        return [
            (.bottom, CGRect(x: 0, y: 0, width: W, height: band)),
            (.top,    CGRect(x: 0, y: H - band, width: W, height: band)),
            (.left,   CGRect(x: 0, y: band, width: thickness, height: middle)),
            (.right,  CGRect(x: W - thickness, y: band, width: thickness, height: middle)),
        ]
    }

    /// The part of the ring a given strip has to draw. Bands get the edge plus
    /// its two corner arcs; sides get a single straight segment. Segments are
    /// extended past the strip boundary so neighbouring strips overlap rather
    /// than leaving a hairline seam.
    func path(for kind: StripKind, _ s: Settings, frameSize: CGSize) -> CGPath {
        let rect = strokeRect(s)
        let r = strokeRadius(s)
        guard kind != .whole else {
            return r > 0
                ? CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
                : CGPath(rect: rect, transform: nil)
        }

        let glow = s.glowSlack(focused ? s.active : s.inactive)
        let band = min(s.outset + radius(for: s) + s.width + glow + 2, frameSize.height / 2)
        let p = CGMutablePath()
        let x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY

        switch kind {
        case .bottom:
            let stop = min(band + 1, rect.midY)
            p.move(to: CGPoint(x: x0, y: stop))
            p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x1, y: y0), radius: r)
            p.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: stop), radius: r)
            p.addLine(to: CGPoint(x: x1, y: stop))
        case .top:
            let stop = max(frameSize.height - band - 1, rect.midY)
            p.move(to: CGPoint(x: x0, y: stop))
            p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x1, y: y1), radius: r)
            p.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x1, y: stop), radius: r)
            p.addLine(to: CGPoint(x: x1, y: stop))
        case .left:
            p.move(to: CGPoint(x: x0, y: band - 1))
            p.addLine(to: CGPoint(x: x0, y: frameSize.height - band + 1))
        case .right:
            p.move(to: CGPoint(x: x1, y: band - 1))
            p.addLine(to: CGPoint(x: x1, y: frameSize.height - band + 1))
        case .whole:
            break
        }
        return p
    }

    /// Grows a strip's window past the region it strictly needs, centred on it,
    /// and keeps that size while it still covers the requirement.
    ///
    /// Cropping only ever happened when a strip had to *grow*: the window is
    /// reshaped and whatever is painted next can end up clipped to the old
    /// extent. Slack means an ordinary drag never resizes a strip at all - it
    /// just moves and repaints inside a window that is already big enough - so
    /// there is nothing to clip. Shrinking is free for the same reason, which is
    /// why the allocation is only given up once the window is far smaller.
    private static let stripSlack: CGFloat = 512

    private func allocate(_ required: CGRect, kind: StripKind, current: CGSize?) -> CGRect {
        var size = required.size
        let slack = BorderWindow.stripSlack
        let fits = current.map { $0.width >= required.width && $0.height >= required.height
                                 && $0.width <= required.width + 2 * slack
                                 && $0.height <= required.height + 2 * slack } ?? false
        if let current, fits {
            size = current
        } else {
            switch kind {
            case .bottom, .top, .whole: size.width = required.width + slack
            case .left, .right:         size.height = required.height + slack
            }
        }
        // Centred on the region it has to cover, so growth and shrinkage are
        // symmetric and the ring never approaches an edge of its own strip.
        return CGRect(x: required.midX - size.width / 2,
                      y: required.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Screen origin for a strip. Border-frame origins are top-left/y-down as
    /// the window server reports them; strip rects are bottom-left/y-up as the
    /// drawing context uses them, so the y axis flips here and only here.
    private func screenOrigin(of rect: CGRect, frame: CGRect) -> CGPoint {
        CGPoint(x: frame.origin.x + rect.minX,
                y: frame.origin.y + (frame.height - rect.maxY))
    }

    // MARK: - Lifecycle

    private func makeStrip(kind: StripKind, rect: CGRect, frame: CGRect) -> Strip? {
        guard validSurface(rect.size) else { return nil }
        var strip = Strip()
        strip.kind = kind
        strip.rect = rect
        if simulated {
            strip.context = makeBitmap(rect.size)
            return strip.context == nil ? nil : strip
        }
        let origin = screenOrigin(of: rect, frame: frame)
        var tags: UInt64 = (1 << 1) | (1 << 9)
        var newWID: UInt32 = 0

        // Option bit 2 (0x4) is what makes the window server allocate the
        // backing store. It is required: without it a window composites
        // nothing, however successfully every other call reports.
        let err = SLSNewWindowWithOpaqueShapeAndContext(
            WS.cid, 2 /* kCGBackingStoreBuffered */,
            WS.region(CGRect(origin: .zero, size: rect.size)), WS.emptyRegion, 13, &tags,
            Float(origin.x), Float(origin.y), 64, &newWID, nil)
        guard err == .success, newWID != 0 else { return nil }
        OpCounts.windowsCreated += 1
        strip.wid = newWID

        var clearTags: UInt64 = 0
        SLSSetWindowTags(WS.cid, newWID, &tags, 64)
        SLSClearWindowTags(WS.cid, newWID, &clearTags, 64)
        SLSSetWindowResolution(WS.cid, newWID, Double(scale))
        SLSSetWindowOpacity(WS.cid, newWID, false)
        SLSSetWindowAlpha(WS.cid, newWID, 1.0)
        SLSWindowSetShadowProperties(newWID, ["com.apple.WindowShadowDensity": 0] as CFDictionary)
        if spaceID != 0 { WS.send(newWID, toSpace: spaceID) }
        strip.context = makeContext(newWID)
        guard strip.context != nil else { SLSReleaseWindow(WS.cid, newWID); return nil }
        return strip
    }

    private func makeBitmap(_ size: CGSize) -> CGContext? {
        guard let pixels = bitmapSize(size) else { return nil }
        let px = 2.0
        let ctx = CGContext(data: nil,
                            width: pixels.width, height: pixels.height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.scaleBy(x: px, y: px)
        return ctx
    }

    private func makeContext(_ wid: UInt32) -> CGContext? {
        guard let raw = SLWindowContextCreate(WS.cid, wid, nil)?.takeRetainedValue() else { return nil }
        let ctx = raw
        ctx.interpolationQuality = .none
        return ctx
    }

    private func buildStrips(frame: CGRect, settings: Settings) -> Bool {
        if simulated {
            scale = 1.0
            displayBounds = .infinite
        } else if let screen = WS.display(for: frame) {
            scale = settings.hidpi ? screen.scale : 1.0
            displayBounds = screen.bounds
        } else {
            scale = settings.hidpi ? 2.0 : 1.0
            displayBounds = .infinite
        }
        OpCounts.rebuilds += 1
        if !simulated, spaceID == 0 { spaceID = WS.spaceID(for: targetWID) }
        destroyStrips()
        for (kind, required) in stripLayout(settings, frameSize: frame.size)
        where required.width > 0 && required.height > 0 {
            let rect = allocate(required, kind: kind, current: nil)
            guard let strip = makeStrip(kind: kind, rect: rect, frame: frame) else {
                destroyStrips()
                return false
            }
            strips.append(strip)
        }
        windowFrame = frame
        layoutRects = stripLayout(settings, frameSize: frame.size).map { $0.1 }
        needsRedraw = true
        stripsDidChange = true
        for i in strips.indices { strips[i].needsDraw = true }
        appliedLevel = .min
        appliedSubLevel = .min
        appliedOrder = 0
        appliedSticky = nil
        return !strips.isEmpty
    }

    /// Resize path: reshape the existing strips instead of rebuilding them.
    /// Creating a window costs ~1-3 ms, so doing that per resize event is what
    /// makes a border visibly trail its window during a drag.
    private func reshapeStrips(frame: CGRect, settings: Settings) -> Bool {
        let layout = stripLayout(settings, frameSize: frame.size)
        guard layout.count == strips.count else {
            return buildStrips(frame: frame, settings: settings)
        }
        let allocations = layout.enumerated().map { index, item in
            allocate(item.1, kind: item.0, current: strips[index].rect.size)
        }
        guard allocations.allSatisfy({ validSurface($0.size) }) else { hide(); return false }
        OpCounts.reshapes += 1
        // A resync repaints and restacks from the window's real bounds; it
        // deliberately keeps the existing allocation, because reshaping is the
        // one operation that can leave a border clipped.
        if pendingResync {
            for i in strips.indices { strips[i].content = nil }
            appliedOrder = 0
        }
        pendingResync = false
        let t0 = nowNS()
        let t = simulated ? nil : Transaction()
        if !simulated && t == nil { return false }
        for i in strips.indices {
            let kind = layout[i].0
            let rect = allocations[i]
            let sizeChanged = rect.size != strips[i].rect.size
            strips[i].kind = kind
            if sizeChanged {
                OpCounts.stripsReshaped += 1
                strips[i].needsDraw = true
                if simulated {
                    strips[i].context = makeBitmap(rect.size)
                    guard strips[i].context != nil else { hide(); return false }
                } else {
                    // Direct and synchronous, not through the transaction: the
                    // transaction form applies the size but ignores the origin,
                    // and it lands asynchronously, so anything painted straight
                    // afterwards can be clipped to the previous extent. This is
                    // rare now that strips carry slack, so its cost is fine.
                    SLSSetWindowShape(WS.cid, strips[i].wid,
                                      Float(screenOrigin(of: rect, frame: frame).x),
                                      Float(screenOrigin(of: rect, frame: frame).y),
                                      WS.region(CGRect(origin: .zero, size: rect.size)))
                }
            }
            t?.move(strips[i].wid, to: screenOrigin(of: rect, frame: frame))
            strips[i].rect = rect
        }
        t?.commit()
        let t1 = nowNS()
        // The drawing context is deliberately not recreated. It tracks the
        // window's current backing store, and re-making it right after a reshape
        // is what bound it to the surface being replaced.
        let t2 = nowNS()
        DrawStats.reshapeNS &+= t1 &- t0
        DrawStats.contextNS &+= t2 &- t1
        DrawStats.reshapeCount += 1
        windowFrame = frame
        layoutRects = layout.map { $0.1 }
        needsRedraw = strips.contains { $0.needsDraw }
        if sbVerify { verifyGeometry() }
        return true
    }

    /// Compares each strip's real window-server bounds against the rect it was
    /// just told to occupy.
    private func verifyGeometry() {
        guard !simulated else { return }
        // Where does everything actually sit in the stack right now?
        var zIndex: [UInt32: Int] = [:]
        if let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for (i, info) in infos.enumerated() {
                if let n = info[kCGWindowNumber as String] as? UInt32 { zIndex[n] = i }
            }
        }
        let targetZ = zIndex[targetWID]
        for strip in strips {
            if !WS.isOrderedIn(strip.wid) {
                GeometryCheck.orderedOut += 1
                if GeometryCheck.samples.count < 6 {
                    GeometryCheck.samples.append("\(strip.kind) ordered OUT after reshape")
                }
            } else if let tz = targetZ, let sz = zIndex[strip.wid],
                      // Below-order strips occupy the next `count` slots behind
                      // the target (higher index is further back); above-order
                      // strips occupy the `count` slots in front of it.
                      !(appliedOrder < 0 ? (sz > tz && sz <= tz + strips.count)
                                         : (sz < tz && sz >= tz - strips.count)) {
                GeometryCheck.notAdjacent += 1
                if GeometryCheck.samples.count < 6 {
                    GeometryCheck.samples.append("\(strip.kind) z=\(sz) target z=\(tz)")
                }
            } else if targetZ != nil && zIndex[strip.wid] == nil {
                GeometryCheck.orderedOut += 1
                if GeometryCheck.samples.count < 6 {
                    GeometryCheck.samples.append("\(strip.kind) not on screen after reshape")
                }
            }
            let want = CGRect(origin: screenOrigin(of: strip.rect, frame: windowFrame),
                              size: strip.rect.size)
            guard let got = WS.bounds(strip.wid) else { continue }
            GeometryCheck.checked += 1
            if abs(got.origin.x - want.origin.x) > 0.5 || abs(got.origin.y - want.origin.y) > 0.5
                || abs(got.width - want.width) > 0.5 || abs(got.height - want.height) > 0.5 {
                GeometryCheck.wrong += 1
                if GeometryCheck.samples.count < 6 {
                    GeometryCheck.samples.append(String(
                        format: "%@ want %.0fx%.0f@%.0f,%.0f got %.0fx%.0f@%.0f,%.0f",
                        "\(strip.kind)" as NSString as String,
                        want.width, want.height, want.origin.x, want.origin.y,
                        got.width, got.height, got.origin.x, got.origin.y))
                }
            }
        }
    }

    private func destroyStrips() {
        for strip in strips where strip.wid != 0 && !simulated {
            SLSReleaseWindow(WS.cid, strip.wid)
        }
        strips.removeAll(keepingCapacity: true)
        stripsDidChange = true
        isOrderedIn = false
    }

    func destroy() { destroyStrips() }
    func clearStripsDidChange() { stripsDidChange = false }

    // MARK: - Drawing

    private func draw(_ s: Settings) {
        let style = focused ? s.active : s.inactive
        let rect = strokeRect(s)
        let frameSize = windowFrame.size

        for index in strips.indices {
            let strip = strips[index]
            guard strip.needsDraw else { continue }
            strips[index].needsDraw = false
            let path = self.path(for: strip.kind, s, frameSize: frameSize)
            guard let ctx = strip.context else { continue }
            let local = CGRect(origin: .zero, size: strip.rect.size)
            let c0 = nowNS()
            ctx.saveGState()
            // Drawing into a window's backing store costs a flat ~1 ms per
            // operation regardless of area (measured: clearing 100x20 costs the
            // same as 1600x1000), so what matters is doing as few operations as
            // possible - not making them small.
            ctx.clear(local)
            DrawStats.clearNS &+= nowNS() &- c0

            ctx.translateBy(x: -strip.rect.minX, y: -strip.rect.minY)
            ctx.setLineWidth(s.width)
            let s0 = nowNS()
            if s.debugFill {
                ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
                ctx.fill(CGRect(x: strip.rect.minX, y: strip.rect.minY,
                                width: strip.rect.width, height: strip.rect.height))
            } else {
                paint(ctx, style: style, path: path, rect: rect, s: s)
            }
            DrawStats.strokeNS &+= nowNS() &- s0

            let f0 = nowNS()
            if !simulated {
                ctx.flush()
                SLSFlushWindowContentRegion(WS.cid, strip.wid, nil)
            }
            DrawStats.flushNS &+= nowNS() &- f0
            DrawStats.drawCount += 1
            OpCounts.draws += 1
            ctx.restoreGState()
        }
        needsRedraw = false
    }

    func paint(_ ctx: CGContext, style: ColorStyle, path: CGPath, rect: CGRect, s: Settings) {
            switch style {
            case .solid(let hex):
                ctx.setStrokeColor(RGBA(hex: hex).cgColor)
                ctx.addPath(path)
                ctx.strokePath()
            case .glow(let hex):
                let c = RGBA(hex: hex)
                ctx.setShadow(offset: .zero, blur: s.glowRadius,
                              color: CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1))
                ctx.setStrokeColor(c.cgColor)
                ctx.addPath(path)
                ctx.strokePath()
            case .gradient(let c1, let c2, let direction):
                ctx.addPath(path)
                ctx.replacePathWithStrokedPath()
                ctx.clip()
                let colors = [RGBA(hex: c1).cgColor, RGBA(hex: c2).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                             colors: colors, locations: nil) {
                    let (start, end): (CGPoint, CGPoint)
                    switch direction {
                    case .topLeftToBottomRight:
                        start = CGPoint(x: rect.minX, y: rect.maxY); end = CGPoint(x: rect.maxX, y: rect.minY)
                    case .topRightToBottomLeft:
                        start = CGPoint(x: rect.maxX, y: rect.maxY); end = CGPoint(x: rect.minX, y: rect.minY)
                    }
                    ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
                }
            }
    }

    // MARK: - Updates

    func update(target: WS.Snapshot, settings: Settings, focused newFocus: Bool, force: Bool = false) {
        let s = overrides ?? settings
        if force { invalidate() }
        if newFocus != focused { needsRedraw = true }
        focused = newFocus
        guard s.enabled, s.width > 0, Self.validSize(target.bounds.size),
              abs(target.bounds.origin.x) <= 1_000_000,
              abs(target.bounds.origin.y) <= 1_000_000 else { hide(); return }
        sticky = target.isSticky
        if target.hasCornerRadius, target.cornerRadius.isFinite, target.cornerRadius >= 0,
           target.cornerRadius <= 1024, target.cornerRadius != cornerRadius {
            cornerRadius = target.cornerRadius
            needsRedraw = true
        }

        let bounds = target.bounds
        let r = radius(for: s)
        tooSmall = bounds.width < max(2 * r, 4) || bounds.height < max(2 * r, 4)
        if tooSmall || (focused ? s.active : s.inactive).isInvisible {
            hide()
            return
        }

        let frame = bounds.insetBy(dx: -s.outset, dy: -s.outset)
        let sizeChanged = frame.size != windowFrame.size

        // A window that has been minimised or otherwise ordered out keeps its
        // bounds, so without asking, its border stays on screen with nothing
        // under it. This used to be skipped whenever the size also changed, on
        // the assumption that a size change means the window is mid-resize and
        // therefore visible - but an off-screen window can be resized by its
        // app too (e.g. a background-space or minimised window relaying out),
        // and skipping the check let update() rebuild and re-order the border
        // in anyway, leaving a border frozen at stale coordinates with nothing
        // under it. Checked unconditionally: update() already does several
        // window-server round trips, so one more here is not on the hot path.
        if !simulated, !WS.isOrderedIn(targetWID) {
            hide()
            return
        }

        targetSize = bounds.size
        // Only a genuine change of backing scale justifies a rebuild. Treating
        // "left the screen I was built for" as a rebuild trigger was a bad bug:
        // a window whose centre no screen contains - off-screen, or in the gap
        // between two displays - made this true on every single event, so all
        // four windows were destroyed and recreated per resize tick, at 1-3 ms
        // each. That is what made a border fall apart the instant you resized.
        var changedScale = false
        if !displayBounds.contains(CGPoint(x: frame.midX, y: frame.midY)),
           let screen = WS.display(for: frame) {
            displayBounds = screen.bounds
            let updated = s.hidpi ? screen.scale : 1.0
            changedScale = updated != scale
        }

        if strips.isEmpty || changedScale {
            guard buildStrips(frame: frame, settings: s) else { return }
        } else if sizeChanged || pendingResync || layoutRects != stripLayout(s, frameSize: frame.size).map({ $0.1 }) {
            guard reshapeStrips(frame: frame, settings: s) else { return }
        } else if frame.origin != windowFrame.origin {
            moveStrips(to: frame)
        }

        // Mark only the strips whose own segment actually changed.
        for i in strips.indices {
            let key = contentKey(for: strips[i], s, frameSize: windowFrame.size)
            if key != strips[i].content {
                strips[i].content = key
                strips[i].needsDraw = true
                needsRedraw = true
            }
        }

        // Level and stacking use the direct calls: the SLSTransaction forms
        // report success but do not take effect, leaving a border invisible
        // while every read-back still claims it is ordered in. They are also
        // round trips, so they are only sent when something actually changed.
        if target.level != appliedLevel, !simulated {
            appliedLevel = target.level
            for strip in strips { SLSSetWindowLevel(WS.cid, strip.wid, target.level) }
        }
        // Sub-level changes are rare; querying it on every resize would add a
        // window-server round trip to a hot path for nothing.
        if !simulated, appliedSubLevel == .min || force {
            let sub = WS.subLevel(targetWID)
            if sub != appliedSubLevel {
                appliedSubLevel = sub
                for strip in strips { SLSSetWindowSubLevel(WS.cid, strip.wid, sub) }
            }
        }
        // Stacking has to be re-asserted, not just set once. Ordering a strip
        // relative to the target places it there at that moment only; when the
        // target is later raised above other windows its strips stay put, and
        // the border ends up partly behind whatever is now between them, which
        // reads as missing edges. Skipped while resizing, where the stack is
        // not changing and these would be four round trips on the hot path.
        if !isOrderedIn || appliedOrder != s.order.rawValue || !sizeChanged {
            isOrderedIn = true
            appliedOrder = s.order.rawValue
            if !simulated {
                OpCounts.orders += 1
                for strip in strips { SLSOrderWindow(WS.cid, strip.wid, s.order.rawValue, targetWID) }
            }
        }

        if needsRedraw { draw(s) }
        if !simulated, appliedSticky != sticky { applyStickyTags() }
    }

    /// Hot path for a drag: all strips move together in one transaction, and
    /// nothing is redrawn because the border's content has not changed.
    func move(targetOrigin: CGPoint, settings: Settings) {
        guard !strips.isEmpty, isOrderedIn, !tooSmall else { return }
        guard abs(targetOrigin.x) <= 1_000_000, abs(targetOrigin.y) <= 1_000_000 else { hide(); return }
        let s = overrides ?? settings
        let origin = CGPoint(x: targetOrigin.x - s.outset, y: targetOrigin.y - s.outset)
        guard origin != windowFrame.origin else { return }
        let moved = CGRect(origin: origin, size: windowFrame.size)
        moveStrips(to: moved)
        // Deliberately no display check here: crossing screens is handled on
        // the next update, and only if the backing scale actually differs.
    }

    private func moveStrips(to frame: CGRect) {
        if simulated { windowFrame = frame; return }
        guard let t = Transaction() else { return }
        for strip in strips {
            t.move(strip.wid, to: screenOrigin(of: strip.rect, frame: frame))
        }
        t.commit()
        windowFrame = frame
    }

    func hide() {
        guard !strips.isEmpty, isOrderedIn else { return }
        OpCounts.hides += 1
        isOrderedIn = false
        appliedOrder = 0
        guard !simulated else { return }
        for strip in strips { SLSOrderWindow(WS.cid, strip.wid, 0, targetWID) }
    }

    func moveToSpace(_ sid: UInt64) {
        guard sid != 0, sid != spaceID else { return }
        spaceID = sid
        for strip in strips { WS.send(strip.wid, toSpace: sid) }
    }

    private func applyStickyTags() {
        appliedSticky = sticky
        var setTags: UInt64 = (1 << 1) | (1 << 9)
        var clearTags: UInt64 = 0
        if sticky {
            setTags |= WS.Snapshot.tagSticky
            clearTags |= (1 << 45)
        } else {
            clearTags |= WS.Snapshot.tagSticky
        }
        for strip in strips {
            SLSSetWindowTags(WS.cid, strip.wid, &setTags, 64)
            SLSClearWindowTags(WS.cid, strip.wid, &clearTags, 64)
        }
    }

    /// Renders the border the way the strips actually compose it: each strip is
    /// clipped to its own rect exactly as its window clips it, so a gap or a
    /// doubled seam shows up here just as it would on screen. Lets the strip
    /// geometry be checked without needing to capture the screen.
    func renderComposite(targetSize size: CGSize, radius: CGFloat, settings s: Settings) -> CGImage? {
        targetSize = size
        cornerRadius = radius
        let frame = CGRect(origin: .zero, size: CGSize(width: size.width + 2 * s.outset,
                                                       height: size.height + 2 * s.outset))
        windowFrame = frame
        let px = 2.0
        guard let pixels = bitmapSize(frame.size) else { return nil }
        guard let bmp = CGContext(data: nil,
                                  width: pixels.width, height: pixels.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        bmp.scaleBy(x: px, y: px)

        // Faint checkerboard so gaps in the ring are obvious.
        bmp.setFillColor(CGColor(gray: 0.18, alpha: 1))
        bmp.fill(CGRect(origin: .zero, size: frame.size))

        let style = focused ? s.active : s.inactive
        let rect = strokeRect(s)
        for (kind, stripRect) in stripLayout(s, frameSize: frame.size) {
            bmp.saveGState()
            bmp.clip(to: stripRect)          // exactly what the strip's window does
            bmp.setLineWidth(s.width)
            paint(bmp, style: style, path: path(for: kind, s, frameSize: frame.size), rect: rect, s: s)
            bmp.restoreGState()

            // Outline each strip's extent in red so the decomposition is visible.
            bmp.saveGState()
            bmp.setStrokeColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.35))
            bmp.setLineWidth(0.5)
            bmp.stroke(stripRect.insetBy(dx: 0.25, dy: 0.25))
            bmp.restoreGState()
        }
        return bmp.makeImage()
    }

    /// Composites the strips' current contents. Whatever is stale in a strip
    /// shows up here exactly as it would on screen.
    func composite(showStripOutlines: Bool = true) -> CGImage? {
        let frame = windowFrame
        let px = 2.0
        guard let pixels = bitmapSize(frame.size) else { return nil }
        guard let out = CGContext(data: nil,
                                  width: pixels.width, height: pixels.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        out.scaleBy(x: px, y: px)
        out.setFillColor(CGColor(gray: 0.18, alpha: 1))
        out.fill(CGRect(origin: .zero, size: frame.size))
        for strip in strips {
            guard let image = strip.context?.makeImage() else { continue }
            out.draw(image, in: strip.rect)
            // Only for eyeballing: strip extents legitimately differ between an
            // incremental run and a fresh build, so drawing them would make a
            // content comparison fail on the overlay rather than the border.
            guard showStripOutlines else { continue }
            out.setStrokeColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.3))
            out.setLineWidth(0.5)
            out.stroke(strip.rect.insetBy(dx: 0.25, dy: 0.25))
        }
        return out.makeImage()
    }

    /// True when the next update would tear down and rebuild every strip
    /// because it believes the window changed screen. Four window creations at
    /// ~1-3 ms each, so if this is ever wrongly true the border is being
    /// destroyed and remade on every single resize event.
    var wouldRebuildForDisplay: Bool {
        guard !displayBounds.contains(CGPoint(x: windowFrame.midX, y: windowFrame.midY)),
              let screen = WS.display(for: windowFrame) else { return false }
        return screen.scale != scale
    }

    /// Each strip's real window-server size against the size it should have for
    /// the window's current bounds. If the strips keep their original size while
    /// the window grows, it shows up here.
    var liveStripGeometry: String {
        guard !strips.isEmpty else { return "no strips" }
        var parts: [String] = []
        var bad = 0
        for strip in strips {
            guard let got = WS.bounds(strip.wid) else { continue }
            let want = strip.rect.size
            let ok = abs(got.width - want.width) < 0.5 && abs(got.height - want.height) < 0.5
            if !ok { bad += 1 }
            parts.append(String(format: "%@ %.0fx%.0f%@", "\(strip.kind)" as NSString as String,
                                got.width, got.height,
                                ok ? "" : String(format: " (want %.0fx%.0f)", want.width, want.height)))
        }
        return "strip sizes: " + parts.joined(separator: ", ") + (bad > 0 ? "  *** \(bad) WRONG ***" : "")
    }

    var displayDiagnostics: String {
        "displayBounds=\(displayBounds) center=(\(Int(windowFrame.midX)),\(Int(windowFrame.midY))) "
            + (wouldRebuildForDisplay ? "*** WOULD REBUILD EVERY UPDATE ***" : "ok")
    }

    var diagnostics: String {
        guard !strips.isEmpty else { return "no strips" }
        let px = strips.reduce(0.0) { $0 + $1.rect.width * $1.rect.height }
        let full = windowFrame.width * windowFrame.height
        let saving = full > 0 ? full / max(px, 1) : 0
        return String(format: "strips=%d backingPixels=%.0fk (%.1fx less than a full window) scale=%.0f",
                      strips.count, px / 1000, saving, scale)
    }

    func invalidate() {
        for i in strips.indices { strips[i].needsDraw = true }
        for i in strips.indices { strips[i].content = nil }
        appliedLevel = .min
        appliedSubLevel = .min
        appliedOrder = 0
        appliedSticky = nil
        needsRedraw = true
    }
}

private extension Settings {
    /// Extra margin a glow's blur needs beyond the stroke itself.
    func glowSlack(_ style: ColorStyle) -> CGFloat {
        if case .glow = style { return glowRadius + 2 }
        return 0
    }
}
