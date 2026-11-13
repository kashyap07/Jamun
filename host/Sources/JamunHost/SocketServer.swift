import Foundation

/// Unix domain socket server speaking newline-delimited messages.
/// Shells send one JSON object per line. The host answers with tab-separated
/// lines, since zsh has no JSON parser.
final class SocketServer {
    final class Connection {
        let fd: Int32
        fileprivate var buffer = Data()
        fileprivate var source: DispatchSourceRead?
        /// Set by the owner once the shell introduces itself.
        var sessionID: String?

        fileprivate init(fd: Int32) { self.fd = fd }
    }

    /// Both callbacks run on the main queue.
    var onMessage: ((Connection, [String: Any]) -> Void)?
    var onClose: ((Connection) -> Void)?

    private let queue = DispatchQueue(label: "dev.jamun.socket")
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?

    func start(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = strlcpy(destination, path, capacity)
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        chmod(path, 0o600)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        listenSource = source
    }

    private func acceptConnection() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let connection = Connection(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable(connection) }
        source.setCancelHandler { close(fd) }
        connection.source = source
        source.resume()
    }

    private func readAvailable(_ connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = read(connection.fd, &chunk, chunk.count)
        guard count > 0 else {
            connection.source?.cancel()
            connection.source = nil
            DispatchQueue.main.async { [weak self] in self?.onClose?(connection) }
            return
        }
        connection.buffer.append(contentsOf: chunk[0..<count])

        while let newline = connection.buffer.firstIndex(of: 0x0A) {
            let line = connection.buffer.subdata(in: connection.buffer.startIndex..<newline)
            connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line),
                  let message = object as? [String: Any]
            else {
                if !line.isEmpty {
                    Log.write("socket: dropped malformed line (\(line.count) bytes)")
                }
                continue
            }
            DispatchQueue.main.async { [weak self] in self?.onMessage?(connection, message) }
        }
    }

    /// Send one line to a shell. Fields are joined with tabs.
    func send(_ connection: Connection, fields: [String]) {
        let line = fields.joined(separator: "\t") + "\n"
        let fd = connection.fd
        queue.async {
            guard connection.source != nil else { return }
            let bytes = Array(line.utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if written <= 0 { return }
                offset += written
            }
        }
    }

    /// Escape a value so it survives the tab-separated line format.
    /// The zsh side decodes it with the (g::) expansion flag.
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
