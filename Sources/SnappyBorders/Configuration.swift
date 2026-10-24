import Foundation
import Darwin

enum Configuration {
    private static func trustedParents(of path: String) -> Bool {
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        while true {
            var info = stat()
            guard stat(parent.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid() || info.st_uid == 0 else { return false }
            // Root-owned sticky temporary directories prevent other users from
            // replacing this user's entries, while ordinary writable parents do not.
            if (info.st_mode & 0o022) != 0 && !(info.st_uid == 0 && (info.st_mode & S_ISVTX) != 0) {
                return false
            }
            if parent.path == "/" { return true }
            parent.deleteLastPathComponent()
        }
    }

    enum Contents {
        case options([String])
        case script(URL)
    }

    /// Configs can execute code, so accept only bounded regular files owned by
    /// this user and not writable by other users. Never follow a config symlink.
    static func load(_ path: String) -> Contents? {
        guard trustedParents(of: path) else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), (info.st_mode & 0o022) == 0,
              info.st_size <= Control.maxRequestBytes else { return nil }
        if (info.st_mode & 0o100) != 0 { return .script(URL(fileURLWithPath: path)) }
        guard let data = try? handle.read(upToCount: Control.maxRequestBytes + 1),
              data.count <= Control.maxRequestBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let args = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return .options(args)
    }

    @discardableResult
    static func startScript(_ url: URL) throws -> Process {
        guard case .script = load(url.path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let process = Process()
        process.executableURL = url
        process.arguments = []
        try process.run()
        return process
    }
}
