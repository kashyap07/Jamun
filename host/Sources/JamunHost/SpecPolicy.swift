import Foundation

/// Local code is off by default. Only the directory explicitly selected by the user is executable.
enum SpecPolicy {
    static func read(path: String, settings: [String: Any] = Settings.all()) throws -> String {
        guard settings["jamun.allowLocalSpecs"] as? Bool == true,
              settings["autocomplete.developerMode"] as? Bool == true,
              let directory = settings["autocomplete.devCompletionsFolder"] as? String,
              !directory.isEmpty else { throw BridgeError("local_specs_disabled") }
        let root = URL(fileURLWithPath: Paths.expandTilde(directory)).resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = URL(fileURLWithPath: Paths.expandTilde(path)).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(root + "/"), candidate.pathExtension == "js" else { throw BridgeError("untrusted_spec_path") }
        let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2_000_000 else { throw BridgeError("spec_too_large") }
        return try String(contentsOf: candidate, encoding: .utf8)
    }
}
