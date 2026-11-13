import Foundation

/// Append-only log at ~/Library/Logs/Jamun/host.log, mirrored to stderr.
enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Jamun", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("host.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let handle: FileHandle? = {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()

    /// Verbose logging is on when ~/.jamun/debug exists.
    static let verbose = FileManager.default.fileExists(
        atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".jamun/debug").path
    )

    static func debug(_ message: @autoclosure () -> String) {
        if verbose { write(message()) }
    }

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        handle?.write(Data(line.utf8))
    }
}
