import Foundation

/// Private, bounded logs. Ordinary diagnostics never contain command buffers or environments.
enum Log {
    private static let queue = DispatchQueue(label: "dev.jamun.log")
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Jamun/host.log")
    static let verbose = FileManager.default.fileExists(atPath: Paths.dataDir.appendingPathComponent("debug").path)
    private static let formatter: ISO8601DateFormatter = ISO8601DateFormatter()
    static func debug(_ message: @autoclosure () -> String) { if verbose { write(message()) } }
    static func write(_ message: String) {
        let value = String(message.prefix(4096))
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let size = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber, size.intValue > 1_048_576 {
                let previous = url.appendingPathExtension("1")
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: url, to: previous)
            }
            if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let line = Data("\(formatter.string(from: Date())) \(value)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line)
            }
        }
    }
}
