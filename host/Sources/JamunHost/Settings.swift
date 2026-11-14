import AppKit

/// User settings in ~/.jamun/settings.json, using Fig's setting keys
/// (for example "autocomplete.theme").
enum Settings {
    /// What the user wrote in settings.json.
    static func stored() -> [String: Any] {
        guard let data = try? Data(contentsOf: Paths.settings),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// Stored settings on top of jamun's defaults.
    static func all() -> [String: Any] {
        defaults.merging(stored()) { _, user in user }
    }

    /// Defaults that differ from Fig's: follow the system appearance, and match
    /// the font of the Terminal profile so the popup reads as part of the window.
    private static let defaults: [String: Any] = {
        var values: [String: Any] = [
            "autocomplete.theme": "system",
            "autocomplete.firstTokenCompletion": true,
            // Down on the last row wraps to the first. Up on the first row
            // opens shell history when atuin is installed, and wraps otherwise.
            "autocomplete.scrollWrapAround": true,
        ]
        if let font = TerminalProfile.font() {
            let size = Double(font.pointSize)
            values["autocomplete.fontFamily"] = TerminalProfile.cssFamily(for: font)
            values["autocomplete.fontSize"] = size
            // Fig's 320px width was tuned for its 12.8px default font.
            values["autocomplete.width"] = (320 * max(1, size / 12.8)).rounded()
            Log.write("terminal font: \(font.fontName) \(size)pt")
        }
        return values
    }()

    static func jsonBlob(key: String?) -> String? {
        let settings = all()
        let value: Any
        if let key, !key.isEmpty {
            guard let found = settings[key] else { return nil }
            value = found
        } else {
            value = settings
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `json` is the JSON-encoded value. Nil removes the key.
    static func set(key: String, json: String?) throws {
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: Paths.settings.path) {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: Paths.settings)) as? [String: Any] else { throw BridgeError("invalid_settings_file") }
            settings = object
        }
        if let json {
            guard let data = json.data(using: .utf8), data.count <= 65536 else { throw BridgeError("invalid_setting") }
            settings[key] = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } else { settings.removeValue(forKey: key) }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: Paths.dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: Paths.settings, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.settings.path)
    }
}

/// Reads the default profile of Terminal.app.
enum TerminalProfile {
    private static func profile() -> [String: Any]? {
        let app = "com.apple.Terminal" as CFString
        guard let name = CFPreferencesCopyAppValue("Default Window Settings" as CFString, app) as? String,
              let profiles = CFPreferencesCopyAppValue("Window Settings" as CFString, app) as? [String: Any]
        else { return nil }
        return profiles[name] as? [String: Any]
    }

    static func font() -> NSFont? {
        guard let data = profile()?["Font"] as? Data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data)
    }

    /// True or false when the profile sets its own background color, nil when
    /// it follows the system appearance (the stock "Basic" profile does).
    static func hasDarkBackground() -> Bool? {
        guard let data = profile()?["BackgroundColor"] as? Data,
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data),
              let rgb = color.usingColorSpace(.sRGB)
        else { return nil }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance < 0.5
    }

    /// A CSS font-family value for a terminal font. SF Mono ships inside
    /// Terminal.app rather than as an installed family, so name it generically.
    static func cssFamily(for font: NSFont) -> String {
        let family = font.familyName ?? font.fontName
        if font.fontName.hasPrefix("SFMono") || family.hasPrefix("SF Mono") {
            return "ui-monospace"
        }
        return "\"\(family)\""
    }
}
