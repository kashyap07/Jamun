import Foundation

/// Version stamped into Info.plist by scripts/build-host.sh.
enum AppVersion {
    static var description: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let commit = info["JamunCommit"] as? String ?? ""
        return "\(version) (\(build)\(commit.isEmpty ? "" : ", \(commit)"))"
    }
}
