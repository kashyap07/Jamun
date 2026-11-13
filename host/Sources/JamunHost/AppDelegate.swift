import AppKit

/// One zsh process connected over the socket.
final class ShellSession {
    let id: String
    let connection: SocketServer.Connection
    var pid: Int = 0
    var tty: String = ""
    var shellPath: String = "/bin/zsh"
    var cwd: String = ""
    var path: String = ""
    var buffer: String = ""
    /// Cursor as a count of unicode scalars, the way zsh reports it.
    var cursor: Int = 0
    /// True while zsh is reading a command line.
    var atPrompt = false
    var keyEditRejected = false
    var revision = 0
    var aliases: [String: String] = [:]
    var environment: [String: String] = [:]
    var keyID: String?

    init(id: String, connection: SocketServer.Connection) {
        self.id = id
        self.connection = connection
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let terminalBundleID = "com.apple.Terminal"

    private let server = SocketServer()
    private var popup: PopupController!
    private var statusItem: NSStatusItem!
    private var trustItem: NSMenuItem!
    private var sessionsItem: NSMenuItem!
    private var enabledItem: NSMenuItem!
    private var healthItem: NSMenuItem!

    private var sessions: [String: ShellSession] = [:]
    private var activeSessionID: String?
    private var caretGeneration = 0
    private var lastCaretLog = ""
    private var enabled = true
    private var socketReady = false
    private var pendingEdits: [String: (sessionID: String, reply: (Result<Any, BridgeError>) -> Void)] = [:]
    private let supportedKeys: Set<String> = ["up", "down", "tab", "shift+tab", "enter", "esc", "control+p", "control+n", "control+k", "control+r"]
    private let contextKeys: Set<String> = ["PATH", "HOME", "USER", "LANG", "LC_ALL", "LC_CTYPE", "KUBECONFIG", "AWS_PROFILE", "AWS_DEFAULT_PROFILE", "AWS_REGION", "AWS_DEFAULT_REGION", "GOOGLE_CLOUD_PROJECT", "CLOUDSDK_CORE_PROJECT", "VIRTUAL_ENV", "CONDA_PREFIX", "PYENV_VERSION", "NVM_BIN", "GOPATH", "CARGO_HOME", "XDG_CONFIG_HOME", "SSH_AUTH_SOCK"]
    private var snapshotSignal: DispatchSourceSignal?
    private var timingSignal: DispatchSourceSignal?
    private lazy var terminalWatcher = TerminalWatcher { [weak self] in
        self?.terminalFocusChanged()
    }

    private var activeSession: ShellSession? {
        activeSessionID.flatMap { sessions[$0] }
    }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("jamun host started, pid \(ProcessInfo.processInfo.processIdentifier)")
        enabled = Settings.all()["jamun.enabled"] as? Bool ?? true
        setUpStatusItem()

        let trusted = CaretTracker.isTrusted(prompt: true)
        Log.write("accessibility trusted: \(trusted)")

        popup = PopupController()
        popup.onRequest = { [weak self] method, params, reply in
            self?.handleWebRequest(method, params, reply)
        }
        popup.onUnavailable = { [weak self] in self?.resetInterception() }
        popup.load()

        server.onMessage = { [weak self] connection, message in
            self?.handleShellMessage(connection, message)
        }
        server.onClose = { [weak self] connection in
            self?.handleShellClosed(connection)
        }
        do {
            try server.start(path: Paths.socket)
            socketReady = true
            Log.write("socket ready")
        } catch {
            Log.write("could not start socket server: \(error)")
            if (error as? POSIXError)?.code == .EADDRINUSE { NSApp.terminate(nil) }
        }

        // Debug aid: `kill -USR1 <pid>` saves a picture of the popup contents.
        signal(SIGUSR1, SIG_IGN)
        let snapshotSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        snapshotSignal.setEventHandler { [weak self] in
            self?.popup.snapshot(to: Paths.dataDir.appendingPathComponent("snapshot.png"))
        }
        snapshotSignal.resume()
        self.snapshotSignal = snapshotSignal

        // Debug aid: `kill -USR2 <pid>` times caret lookups against Terminal.
        signal(SIGUSR2, SIG_IGN)
        let timingSignal = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        timingSignal.setEventHandler {
            guard let terminal = NSRunningApplication.runningApplications(withBundleIdentifier: Self.terminalBundleID).first else { return }
            var samples: [Double] = []
            for _ in 0..<10 {
                let start = CFAbsoluteTimeGetCurrent()
                _ = CaretTracker.caret(pid: terminal.processIdentifier, trailingSpaces: 1)
                samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            Log.write("caret lookup ms: " + samples.map { String(format: "%.1f", $0) }.joined(separator: " "))
        }
        timingSignal.resume()
        self.timingSignal = timingSignal

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontmostAppChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        resetInterception()
        server.stop()
        ProcessRunner.shutdown()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "Jamun") {
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "J"
        }
        let menu = NSMenu()
        menu.delegate = self
        trustItem = NSMenuItem(title: "Accessibility: checking", action: nil, keyEquivalent: "")
        sessionsItem = NSMenuItem(title: "Shells connected: 0", action: nil, keyEquivalent: "")
        enabledItem = NSMenuItem(title: "Enable Autocomplete", action: #selector(toggleEnabled), keyEquivalent: "")
        healthItem = NSMenuItem(title: "Popup: loading", action: nil, keyEquivalent: "")
        menu.addItem(enabledItem)
        menu.addItem(healthItem)
        menu.addItem(trustItem)
        menu.addItem(sessionsItem)
        menu.addItem(NSMenuItem(title: "Open Accessibility Settings", action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Set Up Shell Integration…", action: #selector(installShell), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Remove Shell Integration…", action: #selector(uninstallShell), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reload Autocomplete", action: #selector(reloadPopup), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show Diagnostics…", action: #selector(showDiagnostics), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Trust Developer Specs Folder…", action: #selector(chooseDeveloperSpecs), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Disable Developer Specs", action: #selector(disableDeveloperSpecs), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Jamun", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showMessage(_ title: String, _ detail: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
    @objc private func toggleEnabled() {
        enabled.toggle()
        try? Settings.set(key: "jamun.enabled", json: enabled ? "true" : "false")
        resetInterception(); updateAllowed()
        if enabled { popup.load() }
    }
    @objc private func reloadPopup() { popup.load() }
    @objc private func installShell() {
        let alert = NSAlert()
        alert.messageText = "Set up Jamun for zsh?"
        alert.informativeText = "Adds a marked source block to \(ShellIntegration.zshrc.path) and installs the bundled integration in ~/.jamun. Your existing configuration is preserved."
        alert.addButton(withTitle: "Install"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ShellIntegration.install()
            showMessage("Shell integration installed", "Open a new Terminal window to use this version. Existing shells keep their currently loaded integration until restarted.")
        } catch { showMessage("Installation failed", error.localizedDescription) }
    }
    @objc private func uninstallShell() {
        let alert = NSAlert(); alert.messageText = "Remove Jamun shell integration?"
        alert.informativeText = "Removes only Jamun's marked zshrc block and installed script. Settings and logs are retained. Restart existing shells afterward."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try ShellIntegration.uninstall(); enabled = false; resetInterception(); updateAllowed() }
        catch { showMessage("Removal failed", error.localizedDescription) }
    }
    @objc private func chooseDeveloperSpecs() {
        let alert = NSAlert(); alert.messageText = "Trust a developer specs folder?"
        alert.informativeText = "JavaScript in the selected folder can run commands with your account's privileges. Trust only code you control. This also trusts future edits in that folder; project-local specs elsewhere remain disabled."
        alert.addButton(withTitle: "Choose Folder…"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: url.resolvingSymlinksInPath().path, options: [.fragmentsAllowed])
            try Settings.set(key: "autocomplete.devCompletionsFolder", json: String(data: data, encoding: .utf8))
            try Settings.set(key: "autocomplete.developerMode", json: "true")
            try Settings.set(key: "jamun.allowLocalSpecs", json: "true")
            popup.load()
        } catch { showMessage("Could not save developer settings", error.localizedDescription) }
    }
    @objc private func disableDeveloperSpecs() {
        do {
            try Settings.set(key: "jamun.allowLocalSpecs", json: "false")
            try Settings.set(key: "autocomplete.developerMode", json: "false")
            popup.load()
        } catch { showMessage("Could not save settings", error.localizedDescription) }
    }
    @objc private func showDiagnostics() {
        let manager = FileManager.default
        let resourcesOK = [Paths.web.appendingPathComponent("index.html"), Paths.specs.appendingPathComponent("index.json"), Paths.shellIntegration].allSatisfy { manager.fileExists(atPath: $0.path) }
        showMessage("Jamun diagnostics", [
            "Host socket: \(socketReady ? "ready" : "unavailable")",
            "Shells connected: \(sessions.count)",
            "Shell integration: \(ShellIntegration.installed ? "installed" : "not installed")",
            "Accessibility: \(CaretTracker.isTrusted(prompt: false) ? "granted" : "not granted")",
            "Bundled resources: \(resourcesOK ? "available" : "missing — rebuild/reinstall the app")",
            "Popup: \(popup.health)", "Supported terminal: Terminal.app with zsh",
            "Frontmost terminal: \(terminalIsFrontmost ? "supported" : "switch to Terminal.app")",
            Diagnostics.summary(),
        ].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    // MARK: visibility

    private var terminalIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.terminalBundleID
    }

    @objc private func frontmostAppChanged() {
        updateAllowed()
        watchTerminal()
        if terminalIsFrontmost { refreshCaret() }
    }

    private func watchTerminal() {
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == Self.terminalBundleID {
            terminalWatcher.attach(to: app.processIdentifier)
        }
    }

    /// Another Terminal window or tab took focus, or the window moved. The
    /// caret we know about is stale, so hide until the shell reports typing.
    private func terminalFocusChanged() {
        caretGeneration += 1
        popup.setCaret(nil)
    }

    private func updateAllowed() {
        popup.setAllowed(enabled && terminalIsFrontmost && (activeSession?.atPrompt ?? false))
    }

    // MARK: caret

    /// The shell reports an edit before the terminal has drawn it, so read the
    /// caret a moment later, and once more in case the first read was early.
    private func refreshCaret() {
        caretGeneration += 1
        let generation = caretGeneration
        for delay in [0.012, 0.07] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, generation == self.caretGeneration else { return }
                self.readCaret()
            }
        }
    }

    private func readCaret() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == Self.terminalBundleID
        else { return }

        var trailingSpaces: Int?
        if let session = activeSession {
            let scalars = Array(session.buffer.unicodeScalars)
            if session.cursor >= scalars.count {
                trailingSpaces = scalars.reversed().prefix { $0 == " " }.count
            } else {
                trailingSpaces = 0
            }
        }

        let lookupStarted = ProcessInfo.processInfo.systemUptime
        defer { Diagnostics.record("caret_ms", value: (ProcessInfo.processInfo.systemUptime - lookupStarted) * 1000) }
        switch CaretTracker.caret(pid: app.processIdentifier, trailingSpaces: trailingSpaces) {
        case .success(let caret):
            popup.setCaret(caret.rect)
        case .failure(let error):
            let line = "caret unavailable: \(error)"
            if line != lastCaretLog {
                lastCaretLog = line
                Log.write(line)
            }
            popup.setCaret(nil)
        }
    }

    // MARK: shell -> host

    private func handleShellMessage(_ connection: SocketServer.Connection, _ message: [String: Any]) {
        guard let type = message["t"] as? String else { return }
        Log.debug("shell event: \(type)")

        if type == "hello" {
            guard connection.sessionID == nil,
                  (message["version"] as? Int) == 2,
                  let id = message["sid"] as? String, id.count <= 128,
                  id.range(of: "^[a-zA-Z0-9-]+$", options: .regularExpression) != nil,
                  sessions[id] == nil else { server.closeConnection(connection); return }
            let session = ShellSession(id: id, connection: connection)
            session.pid = (message["pid"] as? NSNumber)?.intValue ?? 0
            session.tty = message["tty"] as? String ?? ""
            session.shellPath = message["shell"] as? String ?? "/bin/zsh"
            connection.sessionID = id
            sessions[id] = session
            server.send(connection, fields: ["hello", "2"])
            Log.write("shell connected: \(id) pid \(session.pid) \(session.tty)")
            return
        }

        guard let id = connection.sessionID, let session = sessions[id], session.connection === connection else { return }

        switch type {
        case "prompt":
            session.cwd = message["cwd"] as? String ?? session.cwd
            session.environment = (message["environment"] as? [String: String] ?? [:]).filter { contextKeys.contains($0.key) && $0.value.utf8.count <= 8192 }
            session.path = session.environment["PATH"] ?? ""
            session.aliases = message["aliases"] as? [String: String] ?? [:]
        case "edit":
            guard let revision = message["rev"] as? Int, revision > session.revision else { return }
            session.buffer = message["buf"] as? String ?? ""
            session.cursor = min(max(0, (message["cur"] as? NSNumber)?.intValue ?? 0), session.buffer.unicodeScalars.count)
            session.revision = revision
            session.cwd = message["cwd"] as? String ?? session.cwd
            session.atPrompt = true
            if activeSessionID != id, let previous = activeSession {
                server.send(previous.connection, fields: ["keys", ""])
                ProcessRunner.cancelSession(previous.id)
            }
            activeSessionID = id
            updateAllowed()
            watchTerminal()
            emitEditBuffer(session)
            refreshCaret()
        case "finish":
            // The command line was accepted or aborted.
            session.atPrompt = false
            session.revision = max(session.revision + 1, message["rev"] as? Int ?? 0)
            ProcessRunner.cancelSession(session.id)
            session.buffer = ""
            session.cursor = 0
            if activeSessionID == id {
                updateAllowed()
                emitEditBuffer(session)
            }
        case "key":
            guard let key = message["key"] as? String,
                  let keyID = message["keyId"] as? String,
                  Int(keyID) != nil else { return }
            guard enabled, popup.isReady, supportedKeys.contains(key), activeSessionID == id,
                  session.atPrompt, message["rev"] as? Int == session.revision else {
                server.send(connection, fields: ["done", keyID, "0"]); return
            }
            session.keyID = keyID
            session.keyEditRejected = false
            popup.emit(event: "key", payload: ["key": key, "keyId": keyID, "context": context(for: session)])
        case "editAck":
            guard let requestID = message["requestId"] as? String,
                  let pending = pendingEdits[requestID], pending.sessionID == session.id else { return }
            pendingEdits.removeValue(forKey: requestID)
            if message["accepted"] as? Bool == true { pending.reply(.success(["accepted": true])) }
            else { pending.reply(.failure(BridgeError("stale_edit"))) }
        default:
            break
        }
    }

    private func handleShellClosed(_ connection: SocketServer.Connection) {
        guard let id = connection.sessionID, sessions[id]?.connection === connection else { return }
        ProcessRunner.cancelSession(id)
        for (requestID, pending) in Array(pendingEdits) where pending.sessionID == id {
            pendingEdits.removeValue(forKey: requestID); pending.reply(.failure(BridgeError("session_closed")))
        }
        sessions.removeValue(forKey: id)
        Log.write("shell disconnected: \(id)")
        if activeSessionID == id {
            activeSessionID = nil
            updateAllowed()
        }
    }

    private func resetInterception() {
        for session in sessions.values {
            session.keyID = nil
            server.send(session.connection, fields: ["keys", ""])
        }
        for pending in pendingEdits.values { pending.reply(.failure(BridgeError("popup_reset"))) }
        pendingEdits.removeAll()
        ProcessRunner.cancelAll()
    }

    private func context(for session: ShellSession) -> [String: Any] {
        [
            "pid": session.pid,
            "ttys": session.tty,
            "processName": "zsh",
            "currentWorkingDirectory": session.cwd,
            "sessionId": session.id,
            "shellPath": session.shellPath,
            "integrationVersion": 2,
            "revision": session.revision,
            "aliases": session.aliases,
            "environmentVariables": session.environment.map { ["key": $0.key, "value": $0.value] },
        ]
    }

    private func emitEditBuffer(_ session: ShellSession) {
        guard enabled else { return }
        // zsh counts the cursor in unicode scalars, JavaScript strings index by UTF-16.
        let scalars = session.buffer.unicodeScalars
        let end = scalars.index(scalars.startIndex, offsetBy: max(0, min(session.cursor, scalars.count)))
        let cursor = String(scalars[scalars.startIndex..<end]).utf16.count
        popup.emit(event: "editbuffer", payload: [
            "sessionId": session.id,
            "buffer": session.buffer,
            "cursor": cursor,
            "revision": session.revision,
            "context": context(for: session),
        ])
    }

    // MARK: web -> host

    private func session(for params: [String: Any]) -> ShellSession? {
        if let id = params["sessionId"] as? String { return sessions[id] }
        return activeSession
    }

    private func handleWebRequest(
        _ method: String,
        _ params: [String: Any],
        _ reply: @escaping (Result<Any, BridgeError>) -> Void
    ) {
        func number(_ key: String) -> CGFloat {
            CGFloat((params[key] as? NSNumber)?.doubleValue ?? 0)
        }
        func string(_ key: String) -> String? { params[key] as? String }
        if method != "log" { Log.debug("web method: \(method)") }

        switch method {
        case "log":
            let message = (string("message") ?? "").prefix(600)
            Log.write("web \(string("level") ?? "log") (details require debug mode)")
            Log.debug(String(message))

        case "window.position":
            let placement = popup.position(
                width: number("width"),
                height: number("height"),
                anchorX: number("anchorX"),
                dryrun: params["dryrun"] as? Bool ?? false
            )
            reply(.success(["isAbove": placement.isAbove, "isClipped": placement.isClipped]))

        case "metrics.record":
            if let name = string("name"), let value = params["value"] as? Double { Diagnostics.record(name, value: value) }
        case "bridge.ready":
            guard params["version"] as? Int == 2 else { reply(.failure(BridgeError("protocol_mismatch"))); return }
            popup.markReady()
            if let session = activeSession {
                emitEditBuffer(session)
                server.send(session.connection, fields: ["resync"])
            }
            reply(.success(["version": 2]))
        case "bridge.closed":
            resetInterception()
        case "keys.intercept":
            guard let id = string("sessionId"), let session = sessions[id] else { reply(.failure(BridgeError("unknown_session"))); return }
            let keys = (params["keys"] as? [String] ?? []).filter { supportedKeys.contains($0) }
            let allowedKeys = enabled && activeSessionID == id && session.atPrompt ? keys : []
            server.send(session.connection, fields: ["keys", allowedKeys.joined(separator: ",")])
            reply(.success([:] as [String: Any]))
        case "key.done":
            if let session = session(for: params), let keyID = string("keyId"), session.keyID == keyID {
                server.send(session.connection, fields: ["done", keyID, params["handled"] as? Bool == true && !session.keyEditRejected ? "1" : "0"])
                session.keyID = nil
            }
        case "shell.insert":
            guard enabled, popup.isReady, let id = string("sessionId"), let session = sessions[id],
                  session.atPrompt, activeSessionID == id,
                  string("expectedBuffer") == session.buffer,
                  params["expectedCursor"] as? Int == session.cursor,
                  params["revision"] as? Int == session.revision,
                  let deletion = params["deletion"] as? Int, deletion >= 0, deletion <= session.cursor,
                  let insertion = string("insertion"), !insertion.contains("\0"), insertion.utf8.count <= 65536,
                  let moveLeft = params["moveLeft"] as? Int, moveLeft >= 0,
                  moveLeft <= session.cursor - deletion + insertion.unicodeScalars.count,
                  let keyID = string("keyId"), keyID == "0" || keyID == session.keyID else {
                if let id = string("sessionId"), let target = sessions[id], string("keyId") == target.keyID { target.keyEditRejected = true }
                Diagnostics.increment("rejected_edits"); reply(.failure(BridgeError("stale_or_invalid_edit"))); return
            }
            let requestID = UUID().uuidString
            pendingEdits[requestID] = (session.id, reply)
            let expires = Int(Date().timeIntervalSince1970 * 1000) + 1500
            server.send(session.connection, fields: [
                "insert", requestID, keyID, String(session.revision), String(session.cursor), String(expires),
                String(deletion), String(moveLeft), params["immediate"] as? Bool == true ? "1" : "0",
                "v" + SocketServer.escapeField(session.buffer), "v" + SocketServer.escapeField(insertion),
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.pendingEdits.removeValue(forKey: requestID)?.reply(.failure(BridgeError("edit_timeout")))
            }
        case "process.cancel":
            if let requestID = params["requestId"] as? Int, let generation = string("_generation") { ProcessRunner.cancel("\(generation):\(requestID)") }
        case "spec.read":
            do {
                let contents = try SpecPolicy.read(path: string("path") ?? "")
                reply(.success(["contents": contents]))
            } catch { reply(.failure(BridgeError("local_spec_not_trusted"))) }
        case "process.run":
            runProcess(params, reply)

        case "settings.get":
            var result: [String: Any] = [:]
            if let blob = Settings.jsonBlob(key: string("key")) { result["jsonBlob"] = blob }
            reply(.success(result))

        case "settings.set":
            guard let key = string("key") else {
                reply(.failure(BridgeError("settings.set needs a key")))
                return
            }
            guard !["jamun.allowLocalSpecs", "autocomplete.devCompletionsFolder"].contains(key),
                  key != "autocomplete.developerMode" || string("value") == "false" else {
                reply(.failure(BridgeError("use_native_developer_settings"))); return
            }
            do { try Settings.set(key: key, json: string("value")) }
            catch { reply(.failure(BridgeError("settings_write_failed"))); return }
            popup.emit(event: "settings", payload: ["jsonBlob": Settings.jsonBlob(key: nil) ?? "{}"])
            reply(.success([:] as [String: Any]))

        case "history.query":
            // History arrives with step 4.
            reply(.success(["rows": [] as [Any]]))

        case "fs.read", "fs.list", "fs.write", "fs.append", "fs.readlink", "fs.mkdir":
            handleFileRequest(method, params, reply)

        default:
            reply(.failure(BridgeError("unknown method \(method)")))
        }
    }

    private func runProcess(_ params: [String: Any], _ reply: @escaping (Result<Any, BridgeError>) -> Void) {
        guard enabled else { reply(.failure(BridgeError("autocomplete_paused"))); return }
        guard let executable = params["executable"] as? String else {
            reply(.failure(BridgeError("process.run needs an executable")))
            return
        }
        let session = session(for: params)
        if params["sessionId"] != nil && session == nil { reply(.failure(BridgeError("unknown_session"))); return }
        var environment = ["HOME": Paths.home.path, "USER": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        environment.merge(session?.environment ?? [:]) { _, value in value }
        for (key, value) in params["environment"] as? [String: Any] ?? [:] {
            if let value = value as? String { environment[key] = value }
        }
        // Keeps shells started by generators from connecting back as sessions.
        environment["JAMUN_DISABLE"] = "1"
        environment["TERM"] = "dumb"

        let timeoutMs = (params["timeout"] as? NSNumber)?.doubleValue ?? 5000
        ProcessRunner.run(
            id: params["_processId"] as? String ?? UUID().uuidString, sessionID: session?.id,
            executable: executable,
            arguments: params["args"] as? [String] ?? [],
            environment: environment,
            workingDirectory: (params["workingDirectory"] as? String) ?? session?.cwd,
            timeout: min(max(timeoutMs.isFinite ? timeoutMs : 5000, 50), 120000) / 1000
        ) { result in
            switch result {
            case .success(let output):
                reply(.success([
                    "exitCode": Int(output.exitCode),
                    "stdout": output.stdout,
                    "stderr": output.stderr,
                ]))
            case .failure(let error):
                Diagnostics.increment("process_failures")
                reply(.failure(BridgeError("could not run \(executable): \(error.localizedDescription)")))
            }
        }
    }

    private func handleFileRequest(_ method: String, _ params: [String: Any], _ reply: (Result<Any, BridgeError>) -> Void) {
        guard let rawPath = params["path"] as? String else {
            reply(.failure(BridgeError("\(method) needs a path")))
            return
        }
        let path = Paths.expandTilde(rawPath)
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        if ["fs.write", "fs.append", "fs.mkdir"].contains(method) && !candidate.hasPrefix(Paths.dataDir.resolvingSymlinksInPath().path + "/") {
            reply(.failure(BridgeError("write_outside_jamun_data"))); return
        }
        let manager = FileManager.default
        do {
            switch method {
            case "fs.read":
                let attributes = try manager.attributesOfItem(atPath: path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 2_000_000 else { throw BridgeError("file_too_large_or_not_regular") }
                let contents = try? String(contentsOfFile: path, encoding: .utf8)
                reply(.success(["contents": contents as Any? ?? NSNull()]))
            case "fs.list":
                reply(.success(["fileNames": try manager.contentsOfDirectory(atPath: path)]))
            case "fs.write":
                try (params["contents"] as? String ?? "").write(toFile: path, atomically: true, encoding: .utf8)
                reply(.success([:] as [String: Any]))
            case "fs.append":
                if let size = (try? manager.attributesOfItem(atPath: path)[.size]) as? NSNumber, size.intValue > 1_048_576 { try Data().write(to: URL(fileURLWithPath: path), options: .atomic) }
                let data = Data((params["contents"] as? String ?? "").utf8)
                if let handle = FileHandle(forWritingAtPath: path) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: URL(fileURLWithPath: path))
                }
                reply(.success([:] as [String: Any]))
            case "fs.readlink":
                reply(.success(["destination": try manager.destinationOfSymbolicLink(atPath: path)]))
            case "fs.mkdir":
                try manager.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: params["recursive"] as? Bool ?? false
                )
                reply(.success([:] as [String: Any]))
            default:
                reply(.failure(BridgeError("unknown method \(method)")))
            }
        } catch {
            reply(.failure(BridgeError("\(method) failed: \(error.localizedDescription)")))
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let trusted = CaretTracker.isTrusted(prompt: false)
        enabledItem.state = enabled ? .on : .off
        healthItem.title = "Popup: \(popup.health)"
        trustItem.title = trusted ? "Accessibility: granted" : "Accessibility: not granted"
        sessionsItem.title = "Shells connected: \(sessions.count)"
    }
}
