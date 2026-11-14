import AppKit
import WebKit

/// Floating panel that never takes keyboard focus away from the terminal.
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the popup window and the web view inside it.
/// The web app decides how big the popup should be. The host decides where it
/// goes (next to the caret) and whether it may be on screen at all.
final class PopupController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    struct Placement {
        var isAbove: Bool
        var isClipped: Bool
    }

    /// Called for every request from the web app. `reply` must be called once
    /// when `id` is non-zero.
    var onRequest: ((_ method: String, _ params: [String: Any], _ reply: @escaping (Result<Any, BridgeError>) -> Void) -> Void)?

    var onUnavailable: (() -> Void)?
    private(set) var isReady = false
    private(set) var health = "Loading"
    private var generation = UUID().uuidString
    func markReady() { isReady = true; health = "Ready" }

    private let panel: PopupPanel
    private let webView: WKWebView
    private let gap: CGFloat = 3

    // Inputs to placement.
    private var requestedSize: NSSize = .zero
    private var anchorX: CGFloat = 0
    /// Shell history grows upwards from the prompt, like atuin's own list.
    private var preferAbove = false
    private var caret: CGRect?
    /// False while the terminal is in the background or no shell is at a prompt.
    private var allowed = false

    override init() {
        panel = PopupPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No window shadow: on a transparent window it draws a dark rim around
        // the glass, which already has its own edge lighting.
        panel.hasShadow = false
        panel.animationBehavior = .none
        // Dress for the terminal, not the system: a dark terminal on a light
        // desktop still wants the dark popup. The web view follows this too.
        if let dark = TerminalProfile.hasDarkBackground() {
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            Log.write("terminal background is \(dark ? "dark" : "light"), popup follows it")
        }

        let configuration = WKWebViewConfiguration()
        let schemeHandler = SchemeHandler()
        for scheme in SchemeHandler.schemes {
            configuration.setURLSchemeHandler(schemeHandler, forURLScheme: scheme)
        }
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.bootstrapScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        webView = WKWebView(frame: panel.contentLayoutRect, configuration: configuration)
        super.init()

        configuration.userContentController.add(self, name: "jamun")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        if #available(macOS 13.3, *) {
            webView.isInspectable = Log.verbose
        }
        panel.contentView = Self.makeBackground(containing: webView)
    }

    /// Liquid Glass on macOS 26 and later, a blurred material before that.
    private static func makeBackground(containing content: NSView) -> NSView {
        let radius: CGFloat = 12
        if #available(macOS 26.0, *), !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let glass = NSGlassEffectView(frame: content.frame)
            // "jamun.glass" in settings.json: "clear" (default) or "regular".
            let style = Settings.all()["jamun.glass"] as? String ?? "clear"
            glass.style = style == "regular" ? .regular : .clear
            glass.cornerRadius = radius
            // A little plum in the glass gives the panel a body of its own, so it
            // does not dissolve into a dark or blurred terminal behind it.
            if let dark = TerminalProfile.hasDarkBackground() {
                glass.tintColor = dark
                    ? NSColor(srgbRed: 0.16, green: 0.10, blue: 0.26, alpha: 0.55)
                    : NSColor(srgbRed: 0.96, green: 0.93, blue: 1.0, alpha: 0.55)
            }
            glass.contentView = content
            glass.autoresizingMask = [.width, .height]
            return glass
        }
        let material = NSVisualEffectView(frame: content.frame)
        material.material = .popover
        material.blendingMode = .behindWindow
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            material.blendingMode = .withinWindow
            material.wantsLayer = true
            material.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = radius
        material.layer?.masksToBounds = true
        material.autoresizingMask = [.width, .height]
        content.frame = material.bounds
        material.addSubview(content)
        return material
    }

    /// Debug aid: save what the web view is currently drawing.
    func snapshot(to url: URL) {
        webView.takeSnapshot(with: nil) { image, error in
            guard let image, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else {
                Log.write("snapshot failed: \(error?.localizedDescription ?? "no image")")
                return
            }
            try? png.write(to: url)
            Log.write("snapshot saved to \(url.path), panel frame \(self.panel.frame), visible \(self.panel.isVisible)")
        }
    }

    func load() {
        isReady = false; health = "Loading"; requestedSize = .zero; apply()
        onUnavailable?()
        guard let url = URL(string: "jamun://app/index.html") else { return }
        webView.load(URLRequest(url: url))
    }

    /// Values Fig's web app reads from `window.fig.constants` at startup.
    private static func bootstrapScript() -> String {
        let constants: [String: Any] = [
            "version": "0.0.1",
            "os": "macos",
            "home": Paths.home.path,
            "user": NSUserName(),
            "newUriFormat": true,
            "env": [:] as [String: String],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: constants)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // Forward web console warnings and errors to the host log.
        let logging = """
        (function () {
          const text = (a) => {
            if (a instanceof Error) return a.stack || a.message;
            if (typeof a === "string") return a;
            try { return JSON.stringify(a); } catch (e) { return String(a); }
          };
          const send = (level, args) => {
            try {
              window.webkit.messageHandlers.jamun.postMessage({
                id: 0, protocol: 2, method: "log", params: { level, message: args.map(text).join(" ") },
              });
            } catch (e) {}
          };
          for (const level of ["error", "warn"]) {
            const original = console[level];
            console[level] = (...args) => { send(level, args); original.apply(console, args); };
          }
          window.addEventListener("error", (e) => send("error", [e.message, e.filename + ":" + e.lineno]));
          window.addEventListener("unhandledrejection", (e) => send("error", ["unhandled rejection", e.reason]));
        })();
        """
        return "window.fig = { constants: \(json), settings: {} };\n" + logging
    }

    // MARK: host -> web

    func emit(event: String, payload: [String: Any]) {
        guard isReady else { return }
        send(["event": event, "payload": payload])
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("window.__jamunReceive && window.__jamunReceive(\(json))")
    }

    // MARK: web -> host

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.scheme == "jamun",
              message.frameInfo.request.url?.host == "app",
              let body = message.body as? [String: Any],
              body["protocol"] as? Int == 2,
              let method = body["method"] as? String
        else { return }
        let id = (body["id"] as? NSNumber)?.intValue ?? 0
        var params = body["params"] as? [String: Any] ?? [:]
        let requestGeneration = generation
        params["_processId"] = "\(generation):\(id)"
        params["_generation"] = generation
        onRequest?(method, params) { [weak self] result in
            guard id != 0, self?.generation == requestGeneration else { return }
            switch result {
            case .success(let value):
                self?.send(["id": id, "ok": true, "result": value])
            case .failure(let error):
                self?.send(["id": id, "ok": false, "error": error.message])
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let allowed = navigationAction.targetFrame?.isMainFrame == true && url?.scheme == "jamun" && url?.host == "app" && ["/", "/index.html"].contains(url?.path ?? "")
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        generation = UUID().uuidString; isReady = false; health = "Loading"
        requestedSize = .zero; apply(); onUnavailable?()
        let loadingGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.generation == loadingGeneration, !self.isReady else { return }
            self.health = "Initialization failed — reload autocomplete"; self.onUnavailable?()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.write("web app loaded")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isReady = false; health = "Load failed"; onUnavailable?()
        Log.write("web app failed to load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isReady = false; health = "Load failed"; onUnavailable?()
        Log.write("web app failed to load: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.write("web content process terminated, reloading")
        load()
    }

    // MARK: placement

    /// True when a requested frame would actually appear on screen.
    var canShow: Bool { allowed && caret != nil }

    func setAllowed(_ allowed: Bool) {
        self.allowed = allowed
        apply()
    }

    func setCaret(_ caret: CGRect?) {
        self.caret = caret
        apply()
    }

    /// The web app asks for a frame. With `dryrun` nothing moves, the caller
    /// only learns where the popup would land.
    func position(width: CGFloat, height: CGFloat, anchorX: CGFloat, preferAbove: Bool = false, dryrun: Bool) -> Placement {
        guard width.isFinite, height.isFinite, anchorX.isFinite,
              width > 0, height > 0, width <= 16384, height <= 16384, abs(anchorX) <= 16384 else { return Placement(isAbove: false, isClipped: true) }
        let size = NSSize(width: width, height: height)
        if !dryrun {
            requestedSize = size
            self.anchorX = anchorX
            self.preferAbove = preferAbove
            apply()
        }
        return layout(size: size, anchorX: anchorX, preferAbove: preferAbove)?.placement ?? Placement(isAbove: false, isClipped: false)
    }

    private func layout(size: NSSize, anchorX: CGFloat, preferAbove: Bool) -> (frame: NSRect, placement: Placement)? {
        guard let caret, let primary = NSScreen.screens.first else { return nil }
        // Accessibility coordinates have a top-left origin. AppKit's is bottom-left.
        let primaryHeight = primary.frame.height
        let caretTop = primaryHeight - caret.minY
        let caretBottom = primaryHeight - caret.maxY
        let probe = NSPoint(x: caret.midX, y: (caretTop + caretBottom) / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(probe) } ?? primary
        let visible = screen.visibleFrame
        let size = NSSize(width: min(size.width, visible.width), height: min(size.height, visible.height))

        var origin = NSPoint(x: caret.minX + anchorX, y: caretBottom - gap - size.height)
        var isAbove = false
        let fitsAbove = caretTop + gap + size.height <= visible.maxY
        if origin.y < visible.minY || (preferAbove && fitsAbove) {
            origin.y = caretTop + gap
            isAbove = true
        }
        let isClipped = origin.x + size.width > visible.maxX || origin.x < visible.minX
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        return (NSRect(origin: origin, size: size), Placement(isAbove: isAbove, isClipped: isClipped))
    }

    private func apply() {
        // The web app requests a 1x1 frame when it has nothing to show.
        guard allowed, requestedSize.width > 1, requestedSize.height > 1,
              let frame = layout(size: requestedSize, anchorX: anchorX, preferAbove: preferAbove)?.frame
        else {
            if panel.isVisible { panel.orderOut(nil) }
            // Keep the hidden panel at the requested size so the web view
            // lays out at its real dimensions (and debug snapshots work).
            if requestedSize.width > 1, requestedSize.height > 1, panel.frame.size != requestedSize {
                panel.setFrame(NSRect(origin: panel.frame.origin, size: requestedSize), display: false)
            }
            return
        }
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }
}

struct BridgeError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
