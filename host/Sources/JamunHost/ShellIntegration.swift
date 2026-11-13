import Foundation

/// Explicit menu actions install/remove only Jamun's marked zshrc block.
enum ShellIntegration {
    private static let begin = "# >>> Jamun shell integration >>>"
    private static let end = "# <<< Jamun shell integration <<<"
    static let sourceLine = "[[ -r \"$HOME/.jamun/jamun.zsh\" ]] && source \"$HOME/.jamun/jamun.zsh\""
    static var zshrc: URL {
        let directory = ProcessInfo.processInfo.environment["ZDOTDIR"].map { URL(fileURLWithPath: $0) } ?? Paths.home
        return directory.appendingPathComponent(".zshrc").resolvingSymlinksInPath()
    }
    static var installed: Bool { FileManager.default.fileExists(atPath: Paths.dataDir.appendingPathComponent("jamun.zsh").path) }
    static func removingBlock(_ text: String) throws -> String {
        guard let start = text.range(of: begin) else { return text }
        guard let finish = text.range(of: end, range: start.upperBound..<text.endIndex) else { throw BridgeError("Incomplete Jamun block in .zshrc; repair it before installing") }
        var copy = text
        let upper = finish.upperBound < text.endIndex && text[finish.upperBound] == "\n" ? text.index(after: finish.upperBound) : finish.upperBound
        copy.removeSubrange(start.lowerBound..<upper)
        return try removingBlock(copy)
    }
    static func install() throws {
        let manager = FileManager.default
        let data = try Data(contentsOf: Paths.shellIntegration)
        let original = manager.fileExists(atPath: zshrc.path) ? try String(contentsOf: zshrc, encoding: .utf8) : ""
        let cleaned = try removingBlock(original)
        let next = cleaned + (cleaned.isEmpty || cleaned.hasSuffix("\n") ? "" : "\n") + "\(begin)\n\(sourceLine)\n\(end)\n"
        try manager.createDirectory(at: Paths.dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = Paths.dataDir.appendingPathComponent("jamun.zsh")
        if (try? manager.destinationOfSymbolicLink(atPath: target.path)) != nil { try manager.removeItem(at: target) }
        try data.write(to: target, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        if next != original {
            if !original.isEmpty { try original.write(to: Paths.dataDir.appendingPathComponent("zshrc-before-install-\(Int(Date().timeIntervalSince1970)).txt"), atomically: true, encoding: .utf8) }
            try next.write(to: zshrc, atomically: true, encoding: .utf8)
        }
    }
    static func uninstall() throws {
        if FileManager.default.fileExists(atPath: zshrc.path) {
            let text = try String(contentsOf: zshrc, encoding: .utf8)
            try removingBlock(text).write(to: zshrc, atomically: true, encoding: .utf8)
        }
        let target = Paths.dataDir.appendingPathComponent("jamun.zsh")
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }
}
