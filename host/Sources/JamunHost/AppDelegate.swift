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

    private var sessions: [String: ShellSession] = [:]
    private var activeSessionID: String?
    private var caretGeneration = 0
    private var lastCaretLog = ""
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
        setUpStatusItem()

        let trusted = CaretTracker.isTrusted(prompt: true)
        Log.write("accessibility trusted: \(trusted)")

        popup = PopupController()
        popup.onRequest = { [weak self] method, params, reply in
            self?.handleWebRequest(method, params, reply)
        }
        popup.load()

        server.onMessage = { [weak self] connection, message in
            self?.handleShellMessage(connection, message)
        }
        server.onClose = { [weak self] connection in
            self?.handleShellClosed(connection)
        }
        do {
            try server.start(path: Paths.socket)
            Log.write("listening on \(Paths.socket)")
        } catch {
            Log.write("could not start socket server: \(error)")
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
        unlink(Paths.socket)
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
        menu.addItem(trustItem)
        menu.addItem(sessionsItem)
        menu.addItem(NSMenuItem(title: "Open Accessibility Settings", action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Jamun", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
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
        popup.setAllowed(terminalIsFrontmost && (activeSession?.atPrompt ?? false))
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
        Log.debug("shell -> \(message)")

        if type == "hello" {
            let id = message["sid"] as? String ?? UUID().uuidString
            let session = ShellSession(id: id, connection: connection)
            session.pid = (message["pid"] as? NSNumber)?.intValue ?? 0
            session.tty = message["tty"] as? String ?? ""
            session.shellPath = message["shell"] as? String ?? "/bin/zsh"
            connection.sessionID = id
            sessions[id] = session
            Log.write("shell connected: \(id) pid \(session.pid) \(session.tty)")
            return
        }

        guard let id = connection.sessionID, let session = sessions[id] else { return }

        switch type {
        case "prompt":
            session.cwd = message["cwd"] as? String ?? session.cwd
            session.path = message["path"] as? String ?? session.path
        case "edit":
            session.buffer = message["buf"] as? String ?? ""
            session.cursor = (message["cur"] as? NSNumber)?.intValue ?? 0
            session.cwd = message["cwd"] as? String ?? session.cwd
            session.atPrompt = true
            activeSessionID = id
            updateAllowed()
            watchTerminal()
            emitEditBuffer(session)
            refreshCaret()
        case "finish":
            // The command line was accepted or aborted.
            session.atPrompt = false
            session.buffer = ""
            session.cursor = 0
            if activeSessionID == id {
                updateAllowed()
                emitEditBuffer(session)
            }
        case "key":
            guard let key = message["key"] as? String else { return }
            popup.emit(event: "key", payload: ["key": key, "context": context(for: session)])
        default:
            break
        }
    }

    private func handleShellClosed(_ connection: SocketServer.Connection) {
        guard let id = connection.sessionID else { return }
        sessions.removeValue(forKey: id)
        Log.write("shell disconnected: \(id)")
        if activeSessionID == id {
            activeSessionID = nil
            updateAllowed()
        }
    }

    private func context(for session: ShellSession) -> [String: Any] {
        [
            "pid": session.pid,
            "ttys": session.tty,
            "processName": "zsh",
            "currentWorkingDirectory": session.cwd,
            "sessionId": session.id,
            "shellPath": session.shellPath,
            // Specs expand "~" and similar from these, not from the host's own environment.
            "environmentVariables": [
                ["key": "PATH", "value": session.path],
                ["key": "HOME", "value": Paths.home.path],
                ["key": "USER", "value": NSUserName()],
            ],
        ]
    }

    private func emitEditBuffer(_ session: ShellSession) {
        // zsh counts the cursor in unicode scalars, JavaScript strings index by UTF-16.
        let scalars = session.buffer.unicodeScalars
        let end = scalars.index(scalars.startIndex, offsetBy: min(session.cursor, scalars.count))
        let cursor = String(scalars[scalars.startIndex..<end]).utf16.count
        popup.emit(event: "editbuffer", payload: [
            "sessionId": session.id,
            "buffer": session.buffer,
            "cursor": cursor,
            "context": context(for: session),
        ])
    }

    // MARK: web -> host

    private func session(for params: [String: Any]) -> ShellSession? {
        if let id = params["sessionId"] as? String, let session = sessions[id] {
            return session
        }
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
        if method != "log" { Log.debug("web -> \(method) \(params)") }

        switch method {
        case "log":
            let message = (string("message") ?? "").prefix(600)
            Log.write("web \(string("level") ?? "log"): \(message)")

        case "window.position":
            let placement = popup.position(
                width: number("width"),
                height: number("height"),
                anchorX: number("anchorX"),
                dryrun: params["dryrun"] as? Bool ?? false
            )
            reply(.success(["isAbove": placement.isAbove, "isClipped": placement.isClipped]))

        case "keys.intercept":
            let keys = params["keys"] as? [String] ?? []
            if let session = session(for: params) {
                server.send(session.connection, fields: ["keys", keys.joined(separator: ",")])
            }
            reply(.success([:] as [String: Any]))

        case "key.done":
            // The shell is blocked waiting for this after forwarding a key.
            if let session = session(for: params) {
                server.send(session.connection, fields: ["done"])
            }

        case "shell.insert":
            if let session = session(for: params) {
                let deletion = (params["deletion"] as? NSNumber)?.intValue ?? 0
                let moveLeft = (params["moveLeft"] as? NSNumber)?.intValue ?? 0
                let immediate = params["immediate"] as? Bool ?? false
                server.send(session.connection, fields: [
                    "insert",
                    String(deletion),
                    String(moveLeft),
                    immediate ? "1" : "0",
                    SocketServer.escapeField(string("insertion") ?? ""),
                ])
            }
            reply(.success([:] as [String: Any]))

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
            Settings.set(key: key, json: string("value"))
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
        guard let executable = params["executable"] as? String else {
            reply(.failure(BridgeError("process.run needs an executable")))
            return
        }
        let session = session(for: params)
        var environment = ProcessInfo.processInfo.environment
        if let path = session?.path, !path.isEmpty { environment["PATH"] = path }
        for (key, value) in params["environment"] as? [String: Any] ?? [:] {
            if let value = value as? String { environment[key] = value }
        }
        // Keeps shells started by generators from connecting back as sessions.
        environment["JAMUN_DISABLE"] = "1"
        environment["TERM"] = "dumb"

        let timeoutMs = (params["timeout"] as? NSNumber)?.doubleValue ?? 5000
        ProcessRunner.run(
            executable: executable,
            arguments: params["args"] as? [String] ?? [],
            environment: environment,
            workingDirectory: (params["workingDirectory"] as? String) ?? session?.cwd,
            timeout: max(timeoutMs, 5000) / 1000
        ) { result in
            switch result {
            case .success(let output):
                reply(.success([
                    "exitCode": Int(output.exitCode),
                    "stdout": output.stdout,
                    "stderr": output.stderr,
                ]))
            case .failure(let error):
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
        let manager = FileManager.default
        do {
            switch method {
            case "fs.read":
                let contents = try? String(contentsOfFile: path, encoding: .utf8)
                reply(.success(["contents": contents as Any? ?? NSNull()]))
            case "fs.list":
                reply(.success(["fileNames": try manager.contentsOfDirectory(atPath: path)]))
            case "fs.write":
                try (params["contents"] as? String ?? "").write(toFile: path, atomically: true, encoding: .utf8)
                reply(.success([:] as [String: Any]))
            case "fs.append":
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
        trustItem.title = trusted ? "Accessibility: granted" : "Accessibility: not granted"
        sessionsItem.title = "Shells connected: \(sessions.count)"
    }
}
