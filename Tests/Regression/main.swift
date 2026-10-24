import Foundation
import CoreGraphics
import Darwin

final class RegressionTests {
    func testRejectsNonfiniteNegativeAndExcessiveGeometry() {
        for option in ["width", "padding", "glow_radius"] {
            for value in ["nan", "inf", "-inf", "-1", "1e300", "129"] {
                var settings = Settings()
                expectTrue(SettingsParser.apply(["\(option)=\(value)"], to: &settings).isEmpty)
            }
        }
        expectFalse(BorderWindow.validSize(CGSize(width: CGFloat.infinity, height: 100)))
        expectFalse(BorderWindow.validSize(CGSize(width: -1, height: 100)))
    }

    func testEmptyListsCanBeCleared() {
        var settings = Settings()
        SettingsParser.apply(["blacklist=Terminal", "whitelist=Safari"], to: &settings)
        SettingsParser.apply(["blacklist=", "whitelist="], to: &settings)
        expectTrue(settings.blacklist.isEmpty)
        expectTrue(settings.whitelist.isEmpty)
    }

    func testInvalidOrMissingWindowNeverChangesGlobalOptions() {
        let manager = BorderManager(settings: Settings())
        for target in ["bogus", "0", "4294967295"] {
            manager.apply(arguments: ["window=\(target)", "width=90"])
            expectEqual(manager.settings.width, 4)
        }
    }

    func testControlRejectsMalformedMessages() {
        expectEqual(Control.decode(Control.encode(["width=8", "blacklist="])), ["width=8", "blacklist="])
        expectNil(Control.decode(Data([0xff, 0])))
        expectNil(Control.decode(Data("width=8".utf8)))
        expectNil(Control.decode(Data(repeating: 0, count: Control.maxRequestBytes + 1)))
    }

    func testConfigurationRejectsUnsafeFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config ; literal")
        try Data("# comment\nwidth=8\nblacklist=\n".utf8).write(to: file)
        expectEqual(chmod(file.path, 0o600), 0)
        guard case .options(let options) = Configuration.load(file.path) else { return fail("safe config rejected") }
        expectEqual(options, ["width=8", "blacklist="])
        expectEqual(chmod(directory.path, 0o777), 0)
        expectNil(Configuration.load(file.path))
        expectEqual(chmod(directory.path, 0o700), 0)
        expectEqual(chmod(file.path, 0o666), 0)
        expectNil(Configuration.load(file.path))
        expectEqual(chmod(file.path, 0o600), 0)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        expectNil(Configuration.load(link.path))
        try Data(repeating: 32, count: Control.maxRequestBytes + 1).write(to: file)
        expectNil(Configuration.load(file.path))
        expectNil(Configuration.load(directory.path))
    }

    func testExecutableConfigPathIsNeverShellCode() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config ; exit 91 # literal")
        try Data("#!/bin/sh\nexit 37\n".utf8).write(to: file)
        expectEqual(chmod(file.path, 0o700), 0)
        let process = try Configuration.startScript(file)
        process.waitUntilExit()
        expectEqual(process.terminationStatus, 37)
    }

    func testControlSocketIsolationAndSlowClients() throws {
        let directory = "/tmp/sbtest-\(UUID().uuidString)"
        setenv("SB_TEST_SOCKET_DIRECTORY", directory, 1)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        expectTrue(Control.listen())
        let competing = Process()
        competing.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        competing.arguments = ["--control-lock-probe"]
        try competing.run()
        competing.waitUntilExit()
        expectEqual(competing.terminationStatus, 0)

        let script = #"""
        import os, socket, stat, subprocess, sys, time
        directory = os.environ['SB_TEST_SOCKET_DIRECTORY']
        path = directory + '/control.sock'
        assert stat.S_IMODE(os.stat(directory).st_mode) == 0o700
        assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
        def connect():
            client = socket.socket(socket.AF_UNIX)
            client.settimeout(4)
            client.connect(path)
            return client
        slow = connect()
        slow.sendall(b'width=8')
        time.sleep(2.3)
        assert slow.recv(1) == b''
        slow.close()
        subprocess.run([sys.argv[1], '--control-client-probe'], check=True, timeout=4)
        def ping():
            with connect() as client:
                client.sendall(b'--ping\0')
                client.shutdown(socket.SHUT_WR)
                assert client.recv(8) == b'ok'
        ping()
        for payload in [b'\xff\0', b'width=8', b'x' * 65537 + b'\0']:
            with connect() as client:
                client.sendall(payload)
                client.shutdown(socket.SHUT_WR)
                try:
                    assert client.recv(8) == b''
                except ConnectionResetError:
                    pass
        with connect() as client:
            client.sendall(b'--ping\0')
        time.sleep(0.05)
        ping()
        """#
        let client = Process()
        client.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        client.arguments = ["python3", "-c", script, CommandLine.arguments[0]]
        try client.run()
        let deadline = Date().addingTimeInterval(12)
        var ticks = 0
        while client.isRunning && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            ticks += 1
        }
        if client.isRunning { client.terminate(); fail("socket integration timed out") }
        client.waitUntilExit()
        expectEqual(client.terminationStatus, 0)
        expectTrue(ticks > 30) // A slow client must not block the main run loop.
    }

    private func update(_ border: BorderWindow, size: CGSize, settings: Settings, force: Bool = false) {
        var snapshot = WS.Snapshot()
        snapshot.bounds = CGRect(origin: .zero, size: size)
        snapshot.cornerRadius = 16
        snapshot.hasCornerRadius = true
        border.update(target: snapshot, settings: settings, focused: true, force: force)
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    func testGradientResizeMatchesFreshRender() throws {
        var settings = Settings()
        settings.active = .gradient(0xffff0000, 0xff0000ff, .topLeftToBottomRight)
        let incremental = BorderWindow(targetWID: 0)
        incremental.simulated = true
        update(incremental, size: CGSize(width: 300, height: 200), settings: settings)
        update(incremental, size: CGSize(width: 420, height: 200), settings: settings)
        let fresh = BorderWindow(targetWID: 0)
        fresh.simulated = true
        update(fresh, size: CGSize(width: 420, height: 200), settings: settings)
        let actual = pixels(try require(incremental.composite(showStripOutlines: false)))
        let expected = pixels(try require(fresh.composite(showStripOutlines: false)))
        expectEqual(actual.count, expected.count)
        expectAtMost(zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0, 12)
    }

    func testColorChangeReusesStripsAndGlowChangeUpdatesLayout() {
        let border = BorderWindow(targetWID: 0)
        border.simulated = true
        var settings = Settings()
        let size = CGSize(width: 300, height: 120)
        update(border, size: size, settings: settings)
        let rebuilds = OpCounts.rebuilds
        settings.active = .solid(0xff00ff00)
        update(border, size: size, settings: settings, force: true)
        expectEqual(OpCounts.rebuilds, rebuilds)
        settings.active = .glow(0xff00ff00)
        settings.glowRadius = 128
        update(border, size: size, settings: settings)
        expectEqual(border.stripCount, 2)
    }

    func testHiddenBorderTracksFocusAndZeroCornerRadius() {
        let border = BorderWindow(targetWID: 0)
        border.simulated = true
        var settings = Settings()
        settings.width = 0
        var snapshot = WS.Snapshot()
        snapshot.bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        snapshot.hasCornerRadius = true
        border.update(target: snapshot, settings: settings, focused: true)
        expectTrue(border.focused)
        settings.width = 4
        snapshot.cornerRadius = 16
        border.update(target: snapshot, settings: settings, focused: true)
        expectEqual(border.cornerRadius, 16)
        snapshot.cornerRadius = 0
        border.update(target: snapshot, settings: settings, focused: true)
        expectEqual(border.cornerRadius, 0)
    }

    func testOversizedRenderRefusesAllocation() {
        let border = BorderWindow(targetWID: 0)
        border.simulated = true
        expectNil(border.renderComposite(targetSize: CGSize(width: 32768, height: 32768),
                                         radius: 16, settings: Settings()))
        expectNil(border.composite())
    }
}

// A dependency-free runner also works with Command Line Tools installations.
var failures = 0
func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    failures += 1
    print("FAIL: \(message) at \(file):\(line)")
}
func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !value { fail("expected true", file: file, line: line) }
}
func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    expectTrue(!value, file: file, line: line)
}
func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    expectTrue(value == nil, file: file, line: line)
}
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    if actual != expected { fail("expected \(expected), got \(actual)", file: file, line: line) }
}
func expectAtMost<T: Comparable>(_ actual: T, _ maximum: T, file: StaticString = #filePath, line: UInt = #line) {
    expectTrue(actual <= maximum, file: file, line: line)
}
enum TestError: Error { case missingValue }
func require<T>(_ value: T?) throws -> T {
    guard let value else { throw TestError.missingValue }
    return value
}
if CommandLine.arguments.contains("--control-lock-probe") {
    exit(Control.listen() ? 1 : 0)
}
if CommandLine.arguments.contains("--control-client-probe") {
    if case .delivered(let reply) = Control.send(["--ping"]), reply == "ok" { exit(0) }
    exit(1)
}
let suite = RegressionTests()
let tests: [(String, () throws -> Void)] = [
    ("numeric validation", suite.testRejectsNonfiniteNegativeAndExcessiveGeometry),
    ("clearing app lists", suite.testEmptyListsCanBeCleared),
    ("per-window scoping", suite.testInvalidOrMissingWindowNeverChangesGlobalOptions),
    ("control protocol", suite.testControlRejectsMalformedMessages),
    ("config trust checks", suite.testConfigurationRejectsUnsafeFiles),
    ("literal executable config paths", suite.testExecutableConfigPathIsNeverShellCode),
    ("gradient resize", suite.testGradientResizeMatchesFreshRender),
    ("strip reuse and glow layout", suite.testColorChangeReusesStripsAndGlowChangeUpdatesLayout),
    ("hidden focus and square corners", suite.testHiddenBorderTracksFocusAndZeroCornerRadius),
    ("bounded bitmap allocations", suite.testOversizedRenderRefusesAllocation),
    ("socket isolation, limits and slow clients", suite.testControlSocketIsolationAndSlowClients),
]
for (name, test) in tests {
    let before = failures
    do { try test() } catch { fail("\(name): \(error)") }
    print("\(failures == before ? "PASS" : "FAIL"): \(name)")
}
print("\(tests.count) regression tests, \(failures) failures")
exit(failures == 0 ? 0 : 1)
