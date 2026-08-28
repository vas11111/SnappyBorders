import Foundation
import CoreGraphics
import CSkyLight

/// Checks each SLSTransaction* operation against its direct equivalent by
/// reading the result back, so a silently-ignored call cannot hide.
func probeTxn() {
    setbuf(stdout, nil)
    let cid = SLSMainConnectionID()
    let me = ProcessInfo.processInfo.processIdentifier

    var target: UInt32 = 0
    var targetBounds = CGRect.zero
    if let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        for i in infos {
            guard let pid = i[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let l = i[kCGWindowLayer as String] as? Int, l == 0,
                  let n = i[kCGWindowNumber as String] as? UInt32,
                  let bd = i[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bd["Width"], let h = bd["Height"], w > 300, h > 300 else { continue }
            target = n; targetBounds = CGRect(x: bd["X"]!, y: bd["Y"]!, width: w, height: h); break
        }
    }
    print("target=\(target)")

    func region(_ r: CGRect) -> CGSRegion {
        var rr = r; var out: Unmanaged<CGSRegion>?
        CGSNewRegionWithRect(&rr, &out); return out!.takeRetainedValue()
    }
    func newWin(_ frame: CGRect) -> UInt32 {
        var tags: UInt64 = (1 << 1) | (1 << 9); var clear: UInt64 = 0; var wid: UInt32 = 0
        SLSNewWindowWithOpaqueShapeAndContext(cid, 2, region(CGRect(origin: .zero, size: frame.size)),
                                              CGRegionCreateEmptyRegion().takeRetainedValue(), 13, &tags,
                                              Float(frame.origin.x), Float(frame.origin.y), 64, &wid, nil)
        SLSSetWindowTags(cid, wid, &tags, 64); SLSClearWindowTags(cid, wid, &clear, 64)
        SLSSetWindowOpacity(cid, wid, false); SLSSetWindowAlpha(cid, wid, 1.0)
        return wid
    }
    func onScreen(_ wid: UInt32) -> Bool {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return infos.contains { ($0[kCGWindowNumber as String] as? UInt32) == wid }
    }
    func bounds(_ wid: UInt32) -> CGRect { var b = CGRect.zero; SLSGetWindowBounds(cid, wid, &b); return b }
    func level(_ wid: UInt32) -> Int64 { var l: Int64 = 0; SLSGetWindowLevel(cid, wid, &l); return l }

    let start = CGRect(x: targetBounds.minX + 100, y: targetBounds.minY + 100, width: 240, height: 170)

    // --- transaction path ---
    let a = newWin(start)
    if let t = SLSTransactionCreate(cid)?.takeRetainedValue() {
        SLSTransactionSetWindowLevel(t, a, 7)
        SLSTransactionOrderWindow(t, a, 1, target)
        SLSTransactionCommit(t, 0)
    }
    usleep(300_000)
    print("txn  order+level: level=\(level(a)) (want 7)  onScreen=\(onScreen(a)) (want true)")

    if let t = SLSTransactionCreate(cid)?.takeRetainedValue() {
        SLSTransactionMoveWindowWithGroup(t, a, CGPoint(x: start.minX + 300, y: start.minY))
        SLSTransactionCommit(t, 0)
    }
    usleep(300_000)
    print("txn  move: bounds=\(bounds(a)) (want x=\(start.minX + 300))")

    if let t = SLSTransactionCreate(cid)?.takeRetainedValue() {
        SLSTransactionSetWindowShape(t, a, Float(start.minX), Float(start.minY),
                                     region(CGRect(x: 0, y: 0, width: 400, height: 300)))
        SLSTransactionCommit(t, 0)
    }
    usleep(300_000)
    print("txn  shape: bounds=\(bounds(a)) (want 400x300 at \(start.minX),\(start.minY))")

    // Same transaction ops, committed synchronously.
    let a2 = newWin(start)
    if let t = SLSTransactionCreate(cid)?.takeRetainedValue() {
        SLSTransactionSetWindowLevel(t, a2, 7)
        SLSTransactionOrderWindow(t, a2, 1, target)
        SLSTransactionCommit(t, 1)
    }
    usleep(300_000)
    print("txn(sync) order: level=\(level(a2)) onScreen=\(onScreen(a2))")

    // --- direct path ---
    let b = newWin(CGRect(x: start.minX, y: start.minY + 200, width: 240, height: 170))
    SLSSetWindowLevel(cid, b, 7)
    SLSOrderWindow(cid, b, 1, target)
    usleep(300_000)
    print("direct order+level: level=\(level(b)) (want 7)  onScreen=\(onScreen(b)) (want true)")

    var p = CGPoint(x: start.minX + 300, y: start.minY + 200)
    SLSMoveWindow(cid, b, &p)
    usleep(300_000)
    print("direct move: bounds=\(bounds(b)) (want x=\(start.minX + 300))")

    SLSSetWindowShape(cid, b, Float(start.minX), Float(start.minY + 200),
                      region(CGRect(x: 0, y: 0, width: 400, height: 300)))
    usleep(300_000)
    print("direct shape: bounds=\(bounds(b)) (want 400x300)  onScreen=\(onScreen(b))")

    SLSReleaseWindow(cid, a); SLSReleaseWindow(cid, a2); SLSReleaseWindow(cid, b)
}
