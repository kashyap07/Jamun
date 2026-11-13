import AppKit
import Darwin

/// Finds the terminal app that hosts a shell by walking up its parent processes.
enum ProcessTree {
    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The first ancestor that is a regular (Dock) app, for example Terminal,
    /// iTerm2, or VS Code above its helper processes. Nil when the chain is
    /// broken, as it is under tmux.
    static func hostApp(ofShell pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<32 {
            guard let next = parent(of: current), next > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: next), app.activationPolicy == .regular {
                return app
            }
            current = next
        }
        return nil
    }
}
