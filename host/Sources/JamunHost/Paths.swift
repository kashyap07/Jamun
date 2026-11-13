import Foundation

/// Filesystem locations used by the host. Everything user-facing lives in ~/.jamun.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static let dataDir = home.appendingPathComponent(".jamun", isDirectory: true)
    static let socket = dataDir.appendingPathComponent("jamun.sock").path
    static let settings = dataDir.appendingPathComponent("settings.json")
    /// Fig completion specs (build output of @withfig/autocomplete).
    static let specs = dataDir.appendingPathComponent("specs", isDirectory: true)
    /// Icon PNGs shipped with the specs.
    static let icons = dataDir.appendingPathComponent("icons", isDirectory: true)

    /// Built web app. JAMUN_WEB_DIR overrides the copy inside the app bundle.
    static let web: URL = {
        if let override = ProcessInfo.processInfo.environment["JAMUN_WEB_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return (Bundle.main.resourceURL ?? URL(fileURLWithPath: "/"))
            .appendingPathComponent("web", isDirectory: true)
    }()

    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
