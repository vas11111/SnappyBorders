import Foundation
import Darwin

/// Same-user control channel. Socket I/O runs off the rendering thread, with
/// bounded messages and an absolute deadline, including slow senders.
enum Control {
    static let maxRequestBytes = 64 * 1024
    static let maxReplyBytes = 1024 * 1024
    private static let timeoutNS: UInt64 = 2_000_000_000
    private static let ioQueue = DispatchQueue(label: "snappyborders.control")
    private static let replyQueue = DispatchQueue(label: "snappyborders.control.replies", attributes: .concurrent)
    private static var pendingClients = 0 // Accessed only on ioQueue.
    private static var listenSource: DispatchSourceRead?
    private static var lockFD: Int32 = -1

    static var socketDirectory: String {
        #if SB_TESTING
        if let directory = ProcessInfo.processInfo.environment["SB_TEST_SOCKET_DIRECTORY"] { return directory }
        #endif
        return "/tmp/snappyborders-\(geteuid())"
    }
    static var socketPath: String { "\(socketDirectory)/control.sock" }

    private static func prepareDirectory() -> Bool {
        guard mkdir(socketDirectory, 0o700) == 0 || errno == EEXIST else { return false }
        var info = stat()
        return lstat(socketDirectory, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == geteuid() && (info.st_mode & 0o777) == 0o700
    }

    private static func makeAddr() -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(socketPath.utf8)
            precondition(bytes.count < raw.count, "socket path too long")
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    private static func configure(_ fd: Int32) -> Bool {
        var enabled: Int32 = 1
        return fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
            && fcntl(fd, F_SETFL, O_NONBLOCK) == 0
            && setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                          socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }

    private static func wait(_ fd: Int32, for events: Int16, until deadline: UInt64) -> Bool {
        while true {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            guard now < deadline else { return false }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(min((deadline - now + 999_999) / 1_000_000, 2000))
            let result = poll(&descriptor, 1, milliseconds)
            if result < 0 && errno == EINTR { continue }
            return result > 0 && (descriptor.revents & (events | Int16(POLLHUP))) != 0
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32, until deadline: UInt64) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard wait(fd, for: Int16(POLLOUT), until: deadline) else { return false }
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private static func readMessage(from fd: Int32, limit: Int, until deadline: UInt64) -> Data? {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while wait(fd, for: Int16(POLLIN), until: deadline) {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard count > 0, count <= limit - result.count else { return nil }
            result.append(contentsOf: buffer.prefix(count))
        }
        return nil
    }

    static func encode(_ args: [String]) -> Data {
        var data = Data()
        for arg in args {
            data.append(contentsOf: arg.utf8)
            data.append(0)
        }
        return data
    }

    static func decode(_ data: Data) -> [String]? {
        guard data.count <= maxRequestBytes, data.isEmpty || data.last == 0 else { return nil }
        var args: [String] = []
        for part in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let arg = String(data: Data(part), encoding: .utf8) else { return nil }
            args.append(arg)
        }
        return args
    }

    enum SendResult {
        case notRunning
        case delivered(String)
        case failed(String)
    }

    static func send(_ args: [String]) -> SendResult {
        guard prepareDirectory() else { return .failed("unsafe or inaccessible control directory") }
        var info = stat()
        if lstat(socketPath, &info) != 0 {
            return errno == ENOENT ? .notRunning : .failed("cannot inspect control socket")
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o600 else { return .failed("unsafe control socket") }
        guard !args.contains(where: { $0.utf8.contains(0) }) else { return .failed("invalid argument") }
        let payload = encode(args)
        guard payload.count <= maxRequestBytes else { return .failed("control request is too large") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed("cannot open control socket") }
        defer { close(fd) }
        guard configure(fd) else { return .failed("cannot configure control socket") }
        let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + timeoutNS
        var addr = makeAddr()
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            if errno == ENOENT || errno == ECONNREFUSED { return .notRunning }
            guard errno == EINPROGRESS, wait(fd, for: Int16(POLLOUT), until: deadline) else {
                return .failed("control connection failed or timed out")
            }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                return .failed("control connection failed")
            }
        }
        guard sameUser(fd) else { return .failed("control peer belongs to another user") }
        guard writeAll(payload, to: fd, until: deadline) else { return .failed("control write failed") }
        shutdown(fd, SHUT_WR)
        guard let reply = readMessage(from: fd, limit: maxReplyBytes, until: deadline),
              let text = String(data: reply, encoding: .utf8) else {
            return .failed("invalid control reply or timeout")
        }
        return .delivered(text)
    }

    /// A lifetime lock prevents starting daemons from unlinking each other's socket.
    static func listen() -> Bool {
        guard listenSource == nil, prepareDirectory() else { return false }
        let lock = open("\(socketDirectory)/control.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return false }
        var info = stat()
        guard fstat(lock, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), (info.st_mode & 0o777) == 0o600,
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { close(lock); return false }
        guard case .notRunning = send(["--ping"]) else { close(lock); return false }
        if lstat(socketPath, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid(),
                  unlink(socketPath) == 0 else { close(lock); return false }
        } else if errno != ENOENT { close(lock); return false }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { close(lock); return false }
        var addr = makeAddr()
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); close(lock); return false }
        guard chmod(socketPath, 0o600) == 0, configure(fd), Darwin.listen(fd, 8) == 0 else {
            unlink(socketPath); close(fd); close(lock); return false
        }
        lockFD = lock
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
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
        guard pendingClients < 32 else { close(client); return }
        let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + timeoutNS
        guard configure(client), sameUser(client),
              let request = readMessage(from: client, limit: maxRequestBytes, until: deadline),
              let args = decode(request) else { close(client); return }
        pendingClients += 1

        DispatchQueue.main.async {
            let reply: String
            let stopping = !args.contains("--ping") && args.contains("--stop")
            if args.contains("--ping") {
                reply = "ok"
            } else if stopping {
                reply = "stopping"
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
            replyQueue.async {
                let output = Data(reply.utf8)
                if output.count <= maxReplyBytes {
                    _ = writeAll(output, to: client,
                                 until: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + timeoutNS)
                }
                close(client)
                ioQueue.async { pendingClients -= 1 }
                if stopping { DispatchQueue.main.async { exit(0) } }
            }
        }
    }
}
