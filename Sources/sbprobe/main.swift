import Foundation
import CoreGraphics
import ImageIO

// Diagnostics for the window-server behaviour snappyborders depends on.
// Kept because these are the checks that pinned down each private-API
// signature and each rendering requirement.
//
//   bench   measured cost of every window-server call on the update path
//   zorder  where a window actually lands in the stack, per window level
//   txn     which SLSTransaction* operations really take effect
//   show    put a window on screen via the backing store, to eyeball it
//   churn   create/move/destroy windows, to drive a running daemon

let which = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "help"
switch which {
case "bench":  probeBench()
case "zorder": probeZOrder()
case "txn":    probeTxn()
case "show":   probeShow()
case "churn":  probeChurn()
case "drive":  probeDrive()
case "front":  probeFront()
case "pixels": probePixels()
case "restack": probeRestack()
case "inspect": probeInspect()
default:
    print("usage: sbprobe <bench|zorder|txn|show|churn|drive|front|pixels|restack|inspect>")
}
