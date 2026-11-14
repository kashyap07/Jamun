import Foundation
import AppKit
import Darwin

struct BridgeError: Error { let message: String; init(_ message: String) { self.message = message } }
var failures = 0
var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    assertions += 1
    if !condition() { failures += 1; print("FAIL: \(name)") }
}
func waitUntil(_ predicate: () -> Bool, seconds: Double = 4) {
    let deadline = Date().addingTimeInterval(seconds)
    while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(predicate(), "async operation finished before deadline")
}
let cases: [(String, String, Double, String?)] = [
    ("ordinary", "printf output; printf error >&2; exit 7", 2, nil),
    ("ignores-term", "trap '' TERM; while :; do sleep 1; done", 0.1, "process_timeout"),
    ("inherited-pipes", "sleep 10 & exit 0", 0.1, "process_timeout"),
    ("output-limit", "yes flood", 2, "process_output_limit"),
]
var completed = 0
let started = Date()
for (name, script, timeout, error) in cases {
    ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/tmp", timeout: timeout) { result in
        switch result {
        case .success(let output):
            check(error == nil, name); check(output.exitCode == 7, "exit status")
            check(output.stdout == "output" && output.stderr == "error", "both output streams")
        case .failure(let actual): check(actual.localizedDescription == error, "\(name): \(actual)")
        }
        completed += 1
    }
}
waitUntil({ completed == cases.count })
check(Date().timeIntervalSince(started) < 3, "hard process deadlines")
var cancelled = false
ProcessRunner.run(id: "cancel-test", executable: "/bin/sh", arguments: ["-c", "sleep 10"], environment: ["PATH": "/bin:/usr/bin"], workingDirectory: nil, timeout: 10) { result in
    if case .failure(let error) = result { check(error.localizedDescription == "process_cancelled", "cancel reason") }
    else { check(false, "cancelled job must fail") }
    cancelled = true
}
ProcessRunner.cancel("cancel-test")
waitUntil({ cancelled })
var recovered = false
ProcessRunner.run(executable: "/usr/bin/printf", arguments: ["ok"], environment: [:], workingDirectory: nil, timeout: 1) { result in
    check((try? result.get().stdout) == "ok", "process after cancellation"); recovered = true
}
waitUntil({ recovered })
let directory = URL(fileURLWithPath: "/tmp/jm-" + UUID().uuidString.prefix(8))
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let before = "export KEEP=yes\n"
let block = "# >>> Jamun shell integration >>>\nsource something\n# <<< Jamun shell integration <<<\n"
check((try? ShellIntegration.removingBlock(before + block + block)) == before, "remove only managed blocks")
do { _ = try ShellIntegration.removingBlock("# >>> Jamun shell integration >>>"); check(false, "incomplete block") } catch { }
let bundledScript = directory.appendingPathComponent("bundled.zsh"), installedScript = directory.appendingPathComponent("installed.zsh")
try "new".write(to: bundledScript, atomically: true, encoding: .utf8)
check((try? ShellIntegration.refresh(from: bundledScript, to: installedScript)) == false, "refresh never installs from scratch")
check(!FileManager.default.fileExists(atPath: installedScript.path), "refresh left no file behind")
try "old".write(to: installedScript, atomically: true, encoding: .utf8)
check((try? ShellIntegration.refresh(from: bundledScript, to: installedScript)) == true, "refresh replaces a stale script")
check((try? String(contentsOf: installedScript, encoding: .utf8)) == "new", "refreshed script content")
check((try? ShellIntegration.refresh(from: bundledScript, to: installedScript)) == false, "refresh is a no-op when current")
let linkedScript = directory.appendingPathComponent("linked.zsh"), checkoutScript = directory.appendingPathComponent("checkout.zsh")
try "checkout".write(to: checkoutScript, atomically: true, encoding: .utf8)
try FileManager.default.createSymbolicLink(at: linkedScript, withDestinationURL: checkoutScript)
check((try? ShellIntegration.refresh(from: bundledScript, to: linkedScript)) == false, "refresh leaves symlinks alone")
check((try? String(contentsOf: checkoutScript, encoding: .utf8)) == "checkout", "symlink target untouched")
let spec = directory.appendingPathComponent("ok.js")
try "export default {}".write(to: spec, atomically: true, encoding: .utf8)
let settings: [String: Any] = ["jamun.allowLocalSpecs": true, "autocomplete.developerMode": true, "autocomplete.devCompletionsFolder": directory.path]
check((try? SpecPolicy.read(path: spec.path, settings: settings)) == "export default {}", "trusted spec")
do { _ = try SpecPolicy.read(path: spec.path, settings: [:]); check(false, "disabled spec") } catch { }
try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape.js"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
do { _ = try SpecPolicy.read(path: directory.appendingPathComponent("escape.js").path, settings: settings); check(false, "symlink escape") } catch { }
let path = directory.appendingPathComponent("s").path
let server = SocketServer(); try server.start(path: path)
do { try SocketServer().start(path: path); check(false, "second owner") } catch { }
var received = false; var closed = false
server.onMessage = { _, message in check(message["t"] as? String == "hello", "valid message"); received = true }
server.onClose = { _ in closed = true }
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutablePointer(to: &address.sun_path) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) } }
let connection = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
check(connection == 0, "socket connection")
let data = Data("{\"t\":\"hello\"}\nnot-json\n".utf8)
_ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
waitUntil({ received && closed }); close(fd); server.stop()
ProcessRunner.shutdown()
print("Native: \(assertions) assertions, \(failures) failures")
exit(failures == 0 ? 0 : 1)
