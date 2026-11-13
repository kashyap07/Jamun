import AppKit
import WebKit

// The production scheme handler and production web bundle are used unchanged.
// Native commands are stubbed so this harness cannot touch the user's shell.
enum Paths {
    static let root = URL(fileURLWithPath: CommandLine.arguments[1])
    static let bundled = root.pathExtension == "app"
    static let web = root.appendingPathComponent(bundled ? "Contents/Resources/web" : "packages/web/dist")
    static let specs = root.appendingPathComponent(bundled ? "Contents/Resources/specs" : "node_modules/@withfig/autocomplete/build")
    static let icons = root.appendingPathComponent(bundled ? "Contents/Resources/icons" : "node_modules/@withfig/autocomplete/icons")
    static func expandTilde(_ path: String) -> String { path }
}
enum Log { static func write(_ value: String) { print(value) } }
final class Harness: NSObject, WKScriptMessageHandler {
    var web: WKWebView!
    var ready = false
    var failures: [String] = []
    var intercepts: [[String: Any]] = []
    var doneKeys: [[String: Any]] = []
    var inserts: [[String: Any]] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let method = body["method"] as? String else { return }
        let params = body["params"] as? [String: Any] ?? [:]
        let id = body["id"] as? Int ?? 0
        var result: [String: Any] = [:]
        var ok = true
        switch method {
        case "bridge.ready": ready = true; result = ["version": 2]
        case "settings.get": result = ["jsonBlob": params["key"] == nil ? "{\"autocomplete.history.disableLoading\":true,\"autocomplete.scrollWrapAround\":true}" : "true"]
        case "window.position": result = ["isAbove": false, "isClipped": false]
        case "process.run": result = ["exitCode": 0, "stdout": "", "stderr": ""]
        case "keys.intercept": intercepts.append(params)
        case "key.done": doneKeys.append(params)
        case "shell.insert": inserts.append(params); result = ["accepted": true]
        case "spec.read": ok = false
        case "test.error": failures.append(params["message"] as? String ?? "JS error")
        default: break
        }
        if id > 0 { send(["id": id, "ok": ok, "result": result, "error": "local_specs_disabled"]) }
    }
    func send(_ value: [String: Any]) {
        let json = String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
        web.evaluateJavaScript("window.__jamunReceive && window.__jamunReceive(\(json))")
    }
    func context(_ session: String) -> [String: Any] {
        ["sessionId": session, "revision": 1, "currentWorkingDirectory": "/tmp", "shellPath": "/bin/zsh", "processName": "zsh", "aliases": [:], "environmentVariables": [["key": "PATH", "value": "/usr/bin:/bin"]]]
    }
    func edit(_ session: String, text: String = "git ") { send(["event": "editbuffer", "payload": ["buffer": text, "cursor": text.utf16.count, "context": context(session)]]) }
    func key(_ name: String, _ id: String, session: String = "A") { send(["event": "key", "payload": ["key": name, "keyId": id, "context": context(session)]]) }
    func evaluate(_ code: String) -> Any? {
        var done = false; var value: Any?
        web.evaluateJavaScript(code) { result, error in value = result; if let error { self.failures.append(error.localizedDescription) }; done = true }
        wait({ done }, "JavaScript response")
        return value
    }
    func wait(_ condition: () -> Bool, _ name: String, seconds: Double = 5) {
        let until = Date().addingTimeInterval(seconds)
        while !condition() && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        if !condition() { failures.append("Timeout: " + name) }
    }
    func check(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }
    func selection() -> Int { (evaluate("Number(document.querySelector('[aria-selected=true]')?.getAttribute('aria-posinset') || 0)") as? NSNumber)?.intValue ?? 0 }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let harness = Harness()
let config = WKWebViewConfiguration()
let handler = SchemeHandler()
for scheme in SchemeHandler.schemes { config.setURLSchemeHandler(handler, forURLScheme: scheme) }
config.userContentController.add(harness, name: "jamun")
let bootstrap = """
window.fig={constants:{os:'macos',home:'/tmp',user:'test',version:'test',newUriFormat:true,env:{}},settings:{}};
window.addEventListener('error',e=>window.webkit.messageHandlers.jamun.postMessage({method:'test.error',params:{message:e.message}}));
window.addEventListener('unhandledrejection',e=>window.webkit.messageHandlers.jamun.postMessage({method:'test.error',params:{message:String(e.reason)}}));
"""
config.userContentController.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
harness.web = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 320), configuration: config)
let window = NSWindow(contentRect: harness.web.frame, styleMask: .borderless, backing: .buffered, defer: false)
window.contentView = harness.web
harness.web.load(URLRequest(url: URL(string: "jamun://app/index.html")!))
harness.wait({ harness.ready }, "readiness")
for text in ["", "g", "gi", "git", "git "] {
    harness.edit("A", text: text)
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
}
harness.wait({ harness.intercepts.contains { ($0["sessionId"] as? String) == "A" && ($0["keys"] as? [String] ?? []).contains("down") } }, "session A keyboard bindings")
harness.check(harness.selection() == 1, "initial selection")
for (key, position) in [("down", 2), ("down", 3), ("up", 2)] {
    let id = String(harness.doneKeys.count + 1)
    harness.key(key, id)
    harness.wait({ harness.doneKeys.contains { ($0["keyId"] as? String) == id } }, "key acknowledgement")
    harness.check(harness.doneKeys.last?["handled"] as? Bool == true, "handled key")
    harness.check(harness.selection() == position, "navigation \(key) -> \(position)")
}
harness.edit("B")
harness.wait({ harness.intercepts.contains { ($0["sessionId"] as? String) == "B" && ($0["keys"] as? [String] ?? []).contains("down") } }, "session B keyboard bindings")
harness.check(harness.intercepts.contains { ($0["sessionId"] as? String) == "A" && ($0["keys"] as? [String])?.isEmpty == true }, "release old session")
harness.key("enter", "insert", session: "B")
harness.wait({ !harness.inserts.isEmpty }, "completion edit")
harness.check(harness.inserts.last?["expectedBuffer"] as? String == "git ", "validated buffer")
harness.check(harness.inserts.last?["sessionId"] as? String == "B", "validated session")
harness.check(harness.inserts.last?["keyId"] as? String == "insert", "validated transaction")
print("WebKit: \(harness.failures.isEmpty ? "PASS" : "FAIL")")
for failure in harness.failures { print("FAIL: \(failure)") }
exit(harness.failures.isEmpty ? 0 : 1)
