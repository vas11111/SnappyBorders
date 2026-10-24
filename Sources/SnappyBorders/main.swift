import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CSkyLight

let version = "0.1.0"

let usage = """
snappyborders \(version) - window borders for macOS, drawn by the compositor.

Usage:
  snappyborders [option=value ...]

Options:
  active_color=<color>      Border of the focused window     (default 0xff2f9bff)
  inactive_color=<color>    Border of unfocused windows      (default 0x00000000)
  color=<color>             Sets both of the above
  width=<float>             Stroke width in points           (default 4.0)
  padding=<float>           Slack around the stroke, for glow (default 4.0)
  style=round|uniform|square
                            round follows the window's own corner radius,
                            uniform pins it to 9pt, square squares it off
  order=above|below         Stack the border over or under the window (default
                            above; the stroke is outside the window so it hides
                            nothing, and below-stacking lets a growing window
                            sweep over its own border while resizing)
  hidpi=on|off              Render at the display's backing scale (default on)
  glow_radius=<float>       Blur radius for glow() colors    (default 10.0)
  blacklist="A,B"           Never draw borders for these apps
  whitelist="A,B"           Only draw borders for these apps
  strips=on|off             Draw the border as four thin strips instead of one
                            window-sized one (default on). Strips use ~15x less
                            memory; turning them off makes a resize slightly
                            cheaper at a large memory cost.
  enabled=on|off            Master switch
  window=<id>               Scope the remaining options to a single window

Colors:
  0xAARRGGBB
  glow(0xAARRGGBB)
  gradient(top_left=0xAARRGGBB,bottom_right=0xAARRGGBB)
  gradient(top_right=0xAARRGGBB,bottom_left=0xAARRGGBB)

Other:
  --status                  Print what the running instance is tracking
  --stop                    Ask the running instance to exit
  --rescan                  Re-adopt every window on the visible spaces
  --selftest                Check the private-API plumbing and exit
  --verbose                 Log tracked-window state every 3s to stdout
  --version, --help

Passing options while an instance is running reconfigures it in place.
Config file, run at startup when no options are given:
  ~/.config/snappyborders/snappybordersrc   (executed if +x, else read as options)
  ~/.snappybordersrc
"""

func runConfigFile() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
        "\(home)/.config/snappyborders/snappybordersrc",
        "\(home)/.snappybordersrc",
    ]
    let fm = FileManager.default
    guard let path = candidates.first(where: { fm.fileExists(atPath: $0) }) else { return }

    switch Configuration.load(path) {
    case .options(let args):
        BorderManager.shared?.apply(arguments: args)
    case .script(let url):
        do { try Configuration.startScript(url) }
        catch { FileHandle.standardError.write(Data("snappyborders: could not run config script\n".utf8)) }
    case nil:
        FileHandle.standardError.write(Data("snappyborders: config must be a regular, user-owned file without group/other write access (64 KiB maximum)\n".utf8))
    }
}

func selftest() -> Int32 {
    var ok = true
    func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        print("  [\(passed ? "ok" : "FAIL")] \(name)\(detail.isEmpty ? "" : "  \(detail)")")
        if !passed { ok = false }
    }
    print("snappyborders \(version) selftest")
    check("window-server connection", WS.cid != 0, "cid=\(WS.cid)")

    // Build a real border window offscreen and draw into it.
    let frame = CGRect(x: -20000, y: -20000, width: 400, height: 300)
    var wid: UInt32 = 0
    var tags: UInt64 = (1 << 1) | (1 << 9)
    let err = SLSNewWindowWithOpaqueShapeAndContext(
        WS.cid, 2, WS.region(CGRect(origin: .zero, size: frame.size)), WS.emptyRegion, 13,
        &tags, Float(frame.origin.x), Float(frame.origin.y), 64, &wid, nil)
    check("create window-server window", err == .success && wid != 0, "wid=\(wid)")
    guard wid != 0 else { return 1 }

    SLSSetWindowTags(WS.cid, wid, &tags, 64)
    SLSSetWindowOpacity(WS.cid, wid, false)
    SLSSetWindowResolution(WS.cid, wid, 2.0)

    if let raw = SLWindowContextCreate(WS.cid, wid, nil)?.takeRetainedValue() {
        let ctx = raw
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(5)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 10, y: 10, width: 380, height: 280),
                           cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.strokePath()
        ctx.flush()
        check("draw into window backing store", SLSFlushWindowContentRegion(WS.cid, wid, nil) == .success)
        let m = ctx.ctm
        check("context orientation", true,
              String(format: "ctm a=%.2f b=%.2f c=%.2f d=%.2f tx=%.1f ty=%.1f -> %@",
                     m.a, m.b, m.c, m.d, m.tx, m.ty,
                     (m.d < 0 ? "y-down (top-left origin)" : "y-up (bottom-left origin)") as NSString))
    } else {
        check("draw into window backing store", false, "SLWindowContextCreate returned nil")
    }

    if let t = Transaction() {
        t.setShape(wid, origin: frame.origin, shape: WS.region(CGRect(origin: .zero, size: frame.size)))
        t.setLevel(wid, 20)
        t.order(wid, 1, relativeTo: 0)
        t.commit()
        check("transaction commit", true)
    } else {
        check("transaction commit", false)
    }

    let front = WS.frontWindow()
    check("front window lookup", front != 0, "wid=\(front)")
    if front != 0, let snap = WS.snapshot(front, includeCornerRadius: true) {
        check("window snapshot", snap.bounds.width > 0,
              "bounds=\(snap.bounds) level=\(snap.level) radius=\(snap.cornerRadius) suitable=\(snap.isSuitable)")
        // Cross-check the batched query against the single-window call.
        if let direct = WS.bounds(front) {
            check("iterator bounds match direct query", snap.bounds.equalTo(direct))
        }
        check("sublevel query", true, "\(WS.subLevel(front))")
    }
    check("visible spaces", !WS.visibleSpaceIDs().isEmpty, "\(WS.visibleSpaceIDs())")

    SLSReleaseWindow(WS.cid, wid)
    print(ok ? "\nAll checks passed." : "\nSome checks failed.")
    return ok ? 0 : 1
}

/// Writes a PNG of the composed border for a given window size, so the strip
/// decomposition can be inspected directly.
func renderTest(_ args: [String]) -> Int32 {
    var settings = Settings()
    SettingsParser.apply(args.filter { $0.contains("=") && !$0.hasPrefix("--") }, to: &settings)
    var w = 900.0, h = 600.0, radius = 16.0
    var out = "/tmp/snappyborders-render.png"
    for a in args {
        let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { continue }
        switch kv[0] {
        case "--w": w = Double(kv[1]) ?? w
        case "--h": h = Double(kv[1]) ?? h
        case "--radius": radius = Double(kv[1]) ?? radius
        case "--out": out = kv[1]
        default: break
        }
    }
    guard BorderWindow.validSize(CGSize(width: w, height: h)), radius.isFinite,
          (0...1024).contains(radius) else { print("invalid render geometry"); return 1 }
    let border = BorderWindow(targetWID: 0)
    border.focused = true
    guard let image = border.renderComposite(targetSize: CGSize(width: w, height: h),
                                             radius: radius, settings: settings) else {
        print("render failed"); return 1
    }
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                                     "public.png" as CFString, 1, nil) else {
        print("cannot write \(out)"); return 1
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { print("cannot finish writing image"); return 1 }
    print("wrote \(out)  (\(image.width)x\(image.height), window \(Int(w))x\(Int(h)) radius \(Int(radius)))")
    return 0
}

/// Drives the real update path through a sequence of window sizes offscreen and
/// writes what the strips end up holding. Reproduces "it breaks after resizing
/// and stays broken" without needing to watch the screen.
func renderSequence(_ args: [String]) -> Int32 {
    var settings = Settings()
    SettingsParser.apply(args.filter { $0.contains("=") && !$0.hasPrefix("--") }, to: &settings)
    var radius = 16.0
    var out = "/tmp/snappyborders-sequence.png"
    var sizes: [CGSize] = []
    for a in args {
        let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { continue }
        switch kv[0] {
        case "--radius": radius = Double(kv[1]) ?? radius
        case "--out": out = kv[1]
        case "--sizes":
            for pair in kv[1].split(separator: ",") {
                let d = pair.split(separator: "x")
                if d.count == 2, let w = Double(d[0]), let h = Double(d[1]) {
                    sizes.append(CGSize(width: w, height: h))
                }
            }
        default: break
        }
    }
    if sizes.isEmpty { sizes = [CGSize(width: 900, height: 600)] }
    guard sizes.allSatisfy(BorderWindow.validSize), radius.isFinite,
          (0...1024).contains(radius) else { print("invalid render geometry"); return 1 }

    let border = BorderWindow(targetWID: 0)
    border.simulated = true
    border.focused = true
    for size in sizes {
        var snap = WS.Snapshot()
        snap.wid = 0
        snap.bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        snap.cornerRadius = radius
        snap.hasCornerRadius = true
        border.update(target: snap, settings: settings, focused: true)
    }
    guard let image = border.composite() else { print("composite failed"); return 1 }
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                                     "public.png" as CFString, 1, nil) else {
        print("cannot write \(out)"); return 1
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { print("cannot finish writing image"); return 1 }
    print("wrote \(out) after \(sizes.count) size(s), final \(Int(sizes.last!.width))x\(Int(sizes.last!.height))")
    return 0
}

/// Runs a resize sequence and, separately, builds a border straight at the final
/// size, then compares. Any difference is stale strip content: the incremental
/// path should land exactly where a fresh build does.
func renderDiff(_ args: [String]) -> Int32 {
    var settings = Settings()
    SettingsParser.apply(args.filter { $0.contains("=") && !$0.hasPrefix("--") }, to: &settings)
    var radius = 16.0
    var sizes: [CGSize] = []
    for a in args {
        let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { continue }
        if kv[0] == "--radius" { radius = Double(kv[1]) ?? radius }
        if kv[0] == "--sizes" {
            for pair in kv[1].split(separator: ",") {
                let d = pair.split(separator: "x")
                if d.count == 2, let w = Double(d[0]), let h = Double(d[1]) {
                    sizes.append(CGSize(width: w, height: h))
                }
            }
        }
    }
    guard sizes.count >= 1 else { print("need --sizes"); return 1 }
    guard sizes.allSatisfy(BorderWindow.validSize), radius.isFinite,
          (0...1024).contains(radius) else { print("invalid render geometry"); return 1 }

    func render(_ seq: [CGSize]) -> CGImage? {
        let b = BorderWindow(targetWID: 0)
        b.simulated = true
        b.focused = true
        for size in seq {
            var snap = WS.Snapshot()
            snap.bounds = CGRect(origin: .zero, size: size)
            snap.cornerRadius = radius
            snap.hasCornerRadius = true
            b.update(target: snap, settings: settings, focused: true)
        }
        return b.composite(showStripOutlines: false)
    }
    guard let incremental = render(sizes), let fresh = render([sizes.last!]) else {
        print("render failed"); return 1
    }
    guard incremental.width == fresh.width, incremental.height == fresh.height else {
        print("size mismatch"); return 1
    }

    func pixels(_ img: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8,
                            bytesPerRow: img.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return buf
    }
    let a = pixels(incremental), c = pixels(fresh)
    var differing = 0
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for y in 0..<incremental.height {
        for x in 0..<incremental.width {
            let i = (y * incremental.width + x) * 4
            if abs(Int(a[i]) - Int(c[i])) > 12 || abs(Int(a[i+1]) - Int(c[i+1])) > 12
                || abs(Int(a[i+2]) - Int(c[i+2])) > 12 {
                differing += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    let total = incremental.width * incremental.height
    if differing == 0 {
        print("identical after \(sizes.count) resizes - no stale content")
    } else {
        print("STALE: \(differing)/\(total) px differ (\(String(format: "%.2f", Double(differing) * 100 / Double(total)))%), region x \(minX)..\(maxX) y \(minY)..\(maxY) of \(incremental.width)x\(incremental.height)")
    }
    return differing == 0 ? 0 : 2
}

// MARK: - Entry

let rawArgs = Array(CommandLine.arguments.dropFirst())

if rawArgs.contains("--version") || rawArgs.contains("-v") {
    print("snappyborders \(version)")
    exit(0)
}
if rawArgs.contains("--help") || rawArgs.contains("-h") {
    print(usage)
    exit(0)
}
if rawArgs.contains("--render-diff") {
    exit(renderDiff(rawArgs))
}
if rawArgs.contains("--render-sequence") {
    exit(renderSequence(rawArgs))
}
if rawArgs.contains("--render-test") {
    exit(renderTest(rawArgs))
}
if rawArgs.contains("--selftest") {
    exit(selftest())
}

// Hand off to an already-running instance if there is one.
let isQuery = rawArgs.contains("--status") || rawArgs.contains("--stop")
    || rawArgs.contains("--rescan") || rawArgs.contains("--reset-counters")
switch Control.send(rawArgs) {
case .delivered(let reply):
    if !reply.isEmpty { print(reply) }
    if rawArgs.isEmpty {
        FileHandle.standardError.write("snappyborders: already running (pass options to reconfigure it)\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
case .notRunning:
    if isQuery {
        FileHandle.standardError.write("snappyborders: not running\n".data(using: .utf8)!)
        exit(1)
    }
case .failed(let reason):
    FileHandle.standardError.write(Data("snappyborders: \(reason)\n".utf8))
    exit(1)
}

// The window server only composites windows belonging to a process it knows as
// an application. Registering as an accessory app gets that with no Dock icon,
// no menu bar and no focus stealing. AppKit then owns the connection's event
// delivery, which is why the run loop below has to be AppKit's rather than a
// bare CFRunLoopRun - otherwise window-server notifications never arrive and
// borders stop following focus.
NSApplication.shared.setActivationPolicy(.accessory)

// Border updates are latency-critical and tiny. Without this the main thread
// runs at default priority and gets descheduled behind background work, which
// shows up as occasional multi-millisecond stalls while dragging.
pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)

var settings = Settings()
SettingsParser.apply(rawArgs.filter { !$0.hasPrefix("--") }, to: &settings)

let manager = BorderManager(settings: settings)
BorderManager.shared = manager

guard Control.listen() else {
    FileHandle.standardError.write("snappyborders: could not claim the control port\n".data(using: .utf8)!)
    exit(1)
}

manager.start()
if rawArgs.isEmpty { runConfigFile() }

if rawArgs.contains("--verbose") {
    let timer = Timer(timeInterval: 3.0, repeats: true) { _ in
        print("---- \(Date()) ----")
        print(BorderManager.shared?.statusReport ?? "")
        fflush(stdout)
    }
    RunLoop.main.add(timer, forMode: .default)
}

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

NSApplication.shared.run()
