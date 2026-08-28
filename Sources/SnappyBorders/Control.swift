import Foundation
import Darwin

/// Single-instance control channel over a Unix domain socket. A second
/// invocation with arguments hands them to the running daemon instead of
/// starting a second one.
enum Control {
    static var socketPath: String {
        "/tmp/snappyborders-\(getuid()).sock"
    }

    private static func makeAddr() -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8)
            precondition(bytes.count < raw.count, "socket path too long")
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func encode(_ args: [String]) -> Data {
        var data = Data()
        for a in args {
            data.append(contentsOf: Array(a.utf8))
            data.append(0)
        }
        return data
    }

    static func decode(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: true)
            .compactMap { String(data: Data($0), encoding: .utf8) }
    }

    enum SendResult {
        case notRunning
        case delivered(String)
    }

    static func send(_ args: [String]) -> SendResult {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .notRunning }
        defer { close(fd) }

        var addr = makeAddr()
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return .notRunning }

        let payload = encode(args)
        payload.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
        shutdown(fd, SHUT_WR)

        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            reply.append(contentsOf: buf[0..<n])
        }
        return .delivered(String(data: reply, encoding: .utf8) ?? "")
    }

    private static var listenSource: DispatchSourceRead?

    /// Installs the listening socket. Returns false if another instance owns it.
    static func listen() -> Bool {
        // A socket file left behind by a killed daemon is only stale if nothing
        // answers on it; probing first avoids stealing a live instance's socket.
        if FileManager.default.fileExists(atPath: socketPath) {
            if case .delivered = send(["--ping"]) { return false }
            unlink(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var addr = makeAddr()
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { close(fd); return false }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { accept(on: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listenSource = source

        atexit { unlink(Control.socketPath) }
        return true
    }

    private static func accept(on listenFD: Int32) {
        let client = Darwin.accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        var request = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            request.append(contentsOf: buf[0..<n])
        }

        let args = decode(request)
        var reply = ""
        if args.contains("--ping") {
            reply = "ok"
        } else if args.contains("--stop") {
            reply = "stopping"
            DispatchQueue.main.async { exit(0) }
        } else if args.contains("--reset-counters") {
            BorderManager.shared?.resetCounters()
            reply = "counters reset"
        } else if args.contains("--rescan") {
            BorderManager.shared?.rescan()
            reply = "rescanned"
        } else if args.contains("--status") {
            reply = BorderManager.shared?.statusReport ?? "snappyborders: not running"
        } else {
            BorderManager.shared?.apply(arguments: args)
            reply = ""
        }
        let out = Data(reply.utf8)
        out.withUnsafeBytes { _ = Darwin.write(client, $0.baseAddress, $0.count) }
    }
}
