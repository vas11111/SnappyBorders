import Foundation
import CoreGraphics
import CSkyLight

/// Creates a window the daemon will treat as a real one, then drags and resizes
/// it at display rate so the daemon's own timers see a realistic load.
func probeDrive() {
    setbuf(stdout, nil)
    let cid = SLSMainConnectionID()

    // Tags that satisfy the daemon's "is this a real window" test.
    var tags: UInt64 = (1 << 0) | (1 << 58)
    var clear: UInt64 = 0
    var wid: UInt32 = 0
    var frame = CGRect(x: 400, y: 300, width: 900, height: 600)
    var local = CGRect(origin: .zero, size: frame.size)
    var reg: Unmanaged<CGSRegion>?
    CGSNewRegionWithRect(&local, &reg)
    SLSNewWindowWithOpaqueShapeAndContext(cid, 2, reg!.takeRetainedValue(),
                                          CGRegionCreateEmptyRegion().takeRetainedValue(),
                                          13, &tags, Float(frame.minX), Float(frame.minY),
                                          64, &wid, nil)
    SLSSetWindowTags(cid, wid, &tags, 64)
    SLSClearWindowTags(cid, wid, &clear, 64)
    SLSSetWindowOpacity(cid, wid, false)
    SLSSetWindowAlpha(cid, wid, 1.0)
    if let raw = SLWindowContextCreate(cid, wid, nil)?.takeRetainedValue() {
        raw.setFillColor(CGColor(srgbRed: 0.15, green: 0.15, blue: 0.18, alpha: 1))
        raw.fill(CGRect(origin: .zero, size: frame.size))
        raw.flush()
        SLSFlushWindowContentRegion(cid, wid, nil)
    }
    if let displays = SLSCopyManagedDisplays(cid)?.takeRetainedValue() as? [CFString],
       let first = displays.first {
        let sid = SLSManagedDisplayGetCurrentSpace(cid, first)
        if sid != 0 { SLSMoveWindowsToManagedSpace(cid, [wid] as CFArray, sid) }
    }
    SLSSetWindowLevel(cid, wid, 0)
    SLSOrderWindow(cid, wid, 1, 0)
    var back: UInt64 = 0
    SLSGetWindowTags(cid, wid, &back, 64)
    let q = SLSWindowQueryWindows(cid, [wid] as CFArray, 0)?.takeRetainedValue()
    var attrs: UInt64 = 0, parent: UInt32 = 0, qtags: UInt64 = 0
    if let q, let it = SLSWindowQueryResultCopyWindows(q)?.takeRetainedValue(), SLSWindowIteratorAdvance(it) {
        attrs = SLSWindowIteratorGetAttributes(it)
        parent = SLSWindowIteratorGetParentID(it)
        qtags = SLSWindowIteratorGetTags(it)
    }
    let suitable = parent == 0
        && ((attrs & 0x2) != 0 || (qtags & 0x400_0000_0000_0000) != 0)
        && (qtags & (1 << 7)) == 0 && (qtags & (1 << 18)) == 0
        && ((qtags & 1) != 0 || ((qtags & (1 << 1)) != 0 && (qtags & (1 << 31)) != 0))
    print("driver wid=\(wid) tagsSet=0x\(String(back, radix: 16)) queryTags=0x\(String(qtags, radix: 16)) attrs=0x\(String(attrs, radix: 16)) parent=\(parent) suitable=\(suitable)")
    print("(run: snappyborders --rescan)")
    usleep(4_000_000)

    let steps = 150
    let frameInterval: UInt32 = 8_000    // ~120 Hz

    print("dragging \(steps) steps...")
    for i in 0..<steps {
        var p = CGPoint(x: 400 + Double(i % 60) * 4, y: 300 + Double(i % 30) * 3)
        SLSMoveWindow(cid, wid, &p)
        usleep(frameInterval)
    }

    let axis = ProcessInfo.processInfo.environment["SB_DRIVE_AXIS"] ?? "both"
    print("resizing \(steps) steps (axis=\(axis))...")
    for i in 0..<steps {
        let w = axis == "h" ? 900.0 : 700 + Double(i % 50) * 8
        let h = axis == "w" ? 600.0 : 500 + Double(i % 40) * 6
        var r = CGRect(x: 0, y: 0, width: w, height: h)
        var rr: Unmanaged<CGSRegion>?
        CGSNewRegionWithRect(&r, &rr)
        SLSSetWindowShape(cid, wid, 400, 300, rr!.takeRetainedValue())
        usleep(frameInterval)
    }
    frame = .zero
    print("done; releasing")
    SLSReleaseWindow(cid, wid)
}
