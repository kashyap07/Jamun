import Foundation
import Darwin

/// Bounded, nonblocking newline protocol. One process owns the socket for its lifetime.
final class SocketServer {
    final class Connection {
        let fd: Int32
        var sessionID: String?
        fileprivate var input = Data()
        fileprivate var output = Data()
        fileprivate var reader: DispatchSourceRead?
        fileprivate var writer: DispatchSourceWrite?
        fileprivate var closed = false
        fileprivate var pendingMessages = 0
        init(fd: Int32) { self.fd = fd }
    }
    var onMessage: ((Connection, [String: Any]) -> Void)?
    var onClose: ((Connection) -> Void)?
    private let queue = DispatchQueue(label: "dev.jamun.socket")
    private var listener: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private var lockFD: Int32 = -1
    private var ownedPath: String?
    private let limit = 512 * 1024

    func start(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw POSIXError(.EACCES) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { close(lock); throw POSIXError(.EADDRINUSE) }
        var success = false
        defer { if !success { close(lock) } }
        var addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { throw POSIXError(.ENAMETOOLONG) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { if !success { close(fd) } }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        unlink(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAvailable(fd) }
        source.setCancelHandler { close(fd) }
        listener = source; lockFD = lock; ownedPath = path; success = true
        source.resume()
    }
    func stop() {
        queue.sync {
            for connection in Array(connections.values) { disconnect(connection) }
            listener?.cancel(); listener = nil
            if let path = ownedPath { unlink(path); ownedPath = nil }
            if lockFD >= 0 { close(lockFD); lockFD = -1 }
        }
    }
    func closeConnection(_ connection: Connection) { queue.async { self.disconnect(connection) } }
    private func acceptAvailable(_ listenerFD: Int32) {
        while true {
            let fd = accept(listenerFD, nil, nil)
            if fd < 0 { return }
            var uid: uid_t = 0; var gid: gid_t = 0
            guard connections.count < 64, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK); _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let connection = Connection(fd: fd)
            connections[fd] = connection
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable(connection) }
            // The write source is canceled before the read source releases the fd.
            source.setCancelHandler { close(fd) }
            connection.reader = source; source.resume()
        }
    }
    private func disconnect(_ connection: Connection) {
        guard !connection.closed else { return }
        connection.closed = true
        connection.writer?.cancel(); connection.writer = nil
        connection.reader?.cancel(); connection.reader = nil
        connections.removeValue(forKey: connection.fd)
        DispatchQueue.main.async { [weak self] in self?.onClose?(connection) }
    }
    private func readAvailable(_ connection: Connection) {
        guard !connection.closed else { return }
        var bytes = [UInt8](repeating: 0, count: 65536)
        for _ in 0..<16 {
            let count = read(connection.fd, &bytes, bytes.count)
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { disconnect(connection); return }
            connection.input.append(contentsOf: bytes.prefix(count))
            guard connection.input.count <= limit else { disconnect(connection); return }
            while let newline = connection.input.firstIndex(of: 10) {
                let line = connection.input.prefix(upTo: newline)
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { disconnect(connection); return }
                connection.input.removeSubrange(...newline)
                guard connection.pendingMessages < 256 else { disconnect(connection); return }
                connection.pendingMessages += 1
                DispatchQueue.main.async { [weak self] in
                    self?.onMessage?(connection, message)
                    self?.queue.async { connection.pendingMessages -= 1 }
                }
            }
        }
    }
    func send(_ connection: Connection, fields: [String]) {
        let data = Data((fields.joined(separator: "\t") + "\n").utf8)
        queue.async {
            guard !connection.closed else { return }
            guard connection.output.count + data.count <= self.limit else { self.disconnect(connection); return }
            connection.output.append(data)
            self.flush(connection)
        }
    }
    private func flush(_ connection: Connection) {
        guard !connection.closed else { return }
        while !connection.output.isEmpty {
            let count = connection.output.withUnsafeBytes { write(connection.fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if connection.writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: connection.fd, queue: queue)
                    source.setEventHandler { [weak self] in self?.flush(connection) }
                    connection.writer = source; source.resume()
                }
                return
            }
            guard count > 0 else { disconnect(connection); return }
            connection.output.removeFirst(count)
        }
        connection.writer?.cancel(); connection.writer = nil
    }
    static func escapeField(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
