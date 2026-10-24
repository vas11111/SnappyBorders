import Foundation
import CoreGraphics
import CSkyLight

/// Ground-truth dump for a specific window id: everything the daemon reads
/// when deciding whether a border should be visible, plus the public
/// CGWindowList view of the same window, so a mismatch between what SkyLight
/// reports and what is actually on screen is visible directly.
func probeInspect() {
    let cid = SLSMainConnectionID()
    let wids = CommandLine.arguments.dropFirst(2).compactMap { UInt32($0) }
    guard !wids.isEmpty else { print("usage: sbprobe inspect <wid> [wid...]"); return }

    for wid in wids {
        print("=== wid \(wid) ===")
        var bounds = CGRect.zero
        SLSGetWindowBounds(cid, wid, &bounds)
        var orderedIn = false
        SLSWindowIsOrderedIn(cid, wid, &orderedIn)
        var level: Int64 = 0
        SLSGetWindowLevel(cid, wid, &level)
        let sub = SLSGetWindowSubLevel(cid, wid)
        var ownerCID: CGSConnectionID = 0
        SLSGetWindowOwner(cid, wid, &ownerCID)
        var ownerPID: pid_t = 0
        SLSConnectionGetPID(ownerCID, &ownerPID)
        var nameBuf = [CChar](repeating: 0, count: 1024)
        proc_name(ownerPID, &nameBuf, UInt32(nameBuf.count))
        let appName = String(cString: nameBuf)
        print("  bounds=\(bounds) orderedIn=\(orderedIn) level=\(level) sub=\(sub) owner=\(appName)(\(ownerPID))")

        if let spaces = SLSCopySpacesForWindows(cid, 0x7, [wid] as CFArray)?.takeRetainedValue() as? [NSNumber] {
            print("  spaces (all masks)=\(spaces.map(\.uint64Value))")
        }
        if let uuid = SLSCopyManagedDisplayForWindow(cid, wid)?.takeRetainedValue() {
            let space = SLSManagedDisplayGetCurrentSpace(cid, uuid)
            print("  managed display=\(uuid) currentSpaceOfThatDisplay=\(space)")
        }

        if let infos = CGWindowListCopyWindowInfo([.optionAll], wid) as? [[String: Any]] {
            for info in infos where (info[kCGWindowNumber as String] as? UInt32) == wid {
                print("  CGWindowList: onscreen=\(info[kCGWindowIsOnscreen as String] ?? "nil")"
                    + " layer=\(info[kCGWindowLayer as String] ?? "nil")"
                    + " alpha=\(info[kCGWindowAlpha as String] ?? "nil")"
                    + " name=\(info[kCGWindowName as String] ?? "nil")"
                    + " ownerName=\(info[kCGWindowOwnerName as String] ?? "nil")"
                    + " bounds=\(info[kCGWindowBounds as String] ?? "nil")")
            }
        } else {
            print("  CGWindowList: not present in .optionAll list at all")
        }
    }

    let activeDisplays = SLSCopyManagedDisplays(cid)?.takeRetainedValue() as? [CFString] ?? []
    for d in activeDisplays {
        print("display \(d) currentSpace=\(SLSManagedDisplayGetCurrentSpace(cid, d))")
    }
}
