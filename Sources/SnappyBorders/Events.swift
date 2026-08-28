import Foundation
import CSkyLight

/// Window-server notification ids.
enum WSEvent {
    static let windowUpdate: UInt32   = 723
    static let windowClose: UInt32    = 804
    static let windowMove: UInt32     = 806
    static let windowResize: UInt32   = 807
    static let windowReorder: UInt32  = 808
    static let windowLevel: UInt32    = 811
    static let windowUnhide: UInt32   = 815
    static let windowHide: UInt32     = 816
    static let windowTitle: UInt32    = 1322
    static let windowCreate: UInt32   = 1325
    static let windowDestroy: UInt32  = 1326
    static let spaceChange: UInt32    = 1401
    static let frontChange: UInt32    = 1508

    static let modify: [UInt32] = [windowUpdate, windowClose, windowMove, windowResize,
                                   windowReorder, windowLevel, windowUnhide, windowHide,
                                   windowTitle]
    static let spawn: [UInt32] = [windowCreate, windowDestroy]
}

private func modifyHandler(_ event: UInt32, _ data: UnsafeMutableRawPointer?, _ len: Int, _ ctx: UnsafeMutableRawPointer?) {
    guard let data, len >= MemoryLayout<UInt32>.size else { return }
    let wid = data.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
    BorderManager.shared?.handleWindowEvent(event, wid: wid)
}

private func spawnHandler(_ event: UInt32, _ data: UnsafeMutableRawPointer?, _ len: Int, _ ctx: UnsafeMutableRawPointer?) {
    // Payload is { uint64_t space_id; uint32_t window_id }.
    guard let data, len >= 12 else { return }
    let sid = data.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
    let wid = data.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
    BorderManager.shared?.handleSpawnEvent(event, wid: wid, spaceID: sid)
}

private func spaceHandler(_ event: UInt32, _ data: UnsafeMutableRawPointer?, _ len: Int, _ ctx: UnsafeMutableRawPointer?) {
    BorderManager.shared?.handleSpaceChange()
}

private func frontHandler(_ event: UInt32, _ data: UnsafeMutableRawPointer?, _ len: Int, _ ctx: UnsafeMutableRawPointer?) {
    BorderManager.shared?.scheduleFocusRefresh()
}

enum Events {
    typealias Handler = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void

    static func register() {
        func ptr(_ h: @escaping Handler) -> UnsafeMutableRawPointer {
            unsafeBitCast(h, to: UnsafeMutableRawPointer.self)
        }
        let modify = ptr(modifyHandler)
        let spawn = ptr(spawnHandler)
        for e in WSEvent.modify { SLSRegisterNotifyProc(modify, e, nil) }
        for e in WSEvent.spawn { SLSRegisterNotifyProc(spawn, e, nil) }
        SLSRegisterNotifyProc(ptr(spaceHandler), WSEvent.spaceChange, nil)
        SLSRegisterNotifyProc(ptr(frontHandler), WSEvent.frontChange, nil)
    }

    /// Drains the connection's event queue. Without this the queue backs up and
    /// the window server throttles notification delivery to this process,
    /// which is one of the ways a border starts lagging behind its window.
    static func installEventPortDrain() {
        var port: mach_port_t = 0
        guard SLSGetEventPort(WS.cid, &port) == .success, port != 0 else { return }
        let callback: CFMachPortCallBack = { _, _, _, _ in
            while let event = SLEventCreateNextEvent(WS.cid) {
                _ = event
            }
        }
        guard let machPort = CFMachPortCreateWithPort(nil, port, callback, nil, nil) else { return }
        _CFMachPortSetOptions(machPort, 0x40)
        guard let source = CFMachPortCreateRunLoopSource(nil, machPort, 0) else { return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
    }
}
