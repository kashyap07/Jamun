import Foundation
import Darwin

/// Each generator owns a process group; all mutable state lives on one serial queue.
enum ProcessRunner {
    struct Output { var exitCode: Int32; var stdout: String; var stderr: String }
    struct Failure: LocalizedError {
        let code: String
        var errorDescription: String? { code }
    }
    private final class Job {
        let id: String
        let sessionID: String?
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        let directory: String?
        let deadline: TimeInterval
        let completion: (Result<Output, Error>) -> Void
        var pid: pid_t = 0
        var stdout = Data(); var stderr = Data()
        var readers: [Int32: DispatchSourceRead] = [:]
        var timer: DispatchSourceTimer?
        var failure: String?
        var killAt: TimeInterval?
        var status: Int32?
        var finished = false
        init(id: String, sessionID: String?, executable: String, arguments: [String], environment: [String: String], directory: String?, timeout: TimeInterval, completion: @escaping (Result<Output, Error>) -> Void) {
            self.id = id; self.sessionID = sessionID; self.executable = executable
            self.arguments = arguments; self.environment = environment; self.directory = directory
            self.deadline = ProcessInfo.processInfo.systemUptime + timeout
            self.completion = completion
        }
    }
    private static let queue = DispatchQueue(label: "dev.jamun.process")
    private static var jobs: [String: Job] = [:]
    private static var waiting: [Job] = []
    private static let outputLimit = 2 * 1024 * 1024

    static func run(id: String = UUID().uuidString, sessionID: String? = nil, executable: String, arguments: [String], environment: [String: String], workingDirectory: String?, timeout: TimeInterval, completion: @escaping (Result<Output, Error>) -> Void) {
        let job = Job(id: id, sessionID: sessionID, executable: executable, arguments: arguments, environment: environment, directory: workingDirectory, timeout: min(max(timeout.isFinite ? timeout : 5, 0.05), 120), completion: completion)
        queue.async {
            guard jobs[id] == nil, jobs.count < 36 else {
                DispatchQueue.main.async { completion(.failure(Failure(code: "process_queue_full"))) }; return
            }
            jobs[id] = job; waiting.append(job); startWaiting()
        }
    }
    static func cancel(_ id: String) { queue.async { if let job = jobs[id] { terminate(job, reason: "process_cancelled") } } }
    static func cancelSession(_ id: String) { queue.async { for job in Array(jobs.values) where job.sessionID == id { terminate(job, reason: "process_cancelled") } } }
    static func cancelAll() { queue.async { for job in Array(jobs.values) { terminate(job, reason: "process_cancelled") } } }
    /// Termination cannot depend on the main run loop delivering a later cancellation.
    static func shutdown() {
        queue.sync {
            for job in jobs.values where job.pid > 0 { kill(-job.pid, SIGKILL) }
        }
    }
    private static func startWaiting() {
        while jobs.values.filter({ $0.pid > 0 }).count < 4, !waiting.isEmpty {
            let job = waiting.removeFirst()
            guard !job.finished else { continue }
            if ProcessInfo.processInfo.systemUptime >= job.deadline { finish(job, result: .failure(Failure(code: "process_timeout"))); continue }
            do { try spawn(job) } catch { finish(job, result: .failure(error)) }
        }
    }
    private static func spawn(_ job: Job) throws {
        guard !job.executable.isEmpty, !job.executable.contains("\0"),
              job.arguments.allSatisfy({ !$0.contains("\0") }),
              job.environment.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else { throw Failure(code: "invalid_process_arguments") }
        var out: [Int32] = [0, 0]; var err: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard pipe(&err) == 0 else { close(out[0]); close(out[1]); throw POSIXError(.EIO) }
        var launched = false
        defer {
            close(out[1]); close(err[1])
            if !launched { close(out[0]); close(err[0]) }
        }
        for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func check(_ code: Int32) throws { if code != 0 { throw POSIXError(.init(rawValue: code) ?? .EIO) } }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var mask = sigset_t(); sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        var defaults = sigset_t(); sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGPIPE, SIGUSR1, SIGUSR2] { sigaddset(&defaults, signal) }
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO))
        for fd in out + err { try check(posix_spawn_file_actions_addclose(&actions, fd)) }
        if let directory = job.directory {
            try check(posix_spawn_file_actions_addchdir_np(&actions, Paths.expandTilde(directory)))
        }
        let command = job.executable.hasPrefix("~") ? Paths.expandTilde(job.executable) : job.executable
        var argv = (["/usr/bin/env", command] + job.arguments).map { strdup($0) } + [nil]
        var envp = job.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        try check(posix_spawn(&job.pid, "/usr/bin/env", &actions, &attributes, &argv, &envp))
        launched = true
        for (fd, isError) in [(out[0], false), (err[0], true)] {
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { drain(job, fd: fd, isError: isError) }
            source.setCancelHandler { close(fd) }
            job.readers[fd] = source; source.resume()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(25), leeway: .milliseconds(5))
        timer.setEventHandler { poll(job) }
        job.timer = timer; timer.resume()
    }
    private static func drain(_ job: Job, fd: Int32, isError: Bool) {
        guard !job.finished else { return }
        var buffer = [UInt8](repeating: 0, count: 16384)
        // Yield to timers/cancellation even if a producer writes continuously.
        for _ in 0..<16 {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            if count <= 0 { job.readers.removeValue(forKey: fd)?.cancel(); return }
            guard job.stdout.count + job.stderr.count + count <= outputLimit else { terminate(job, reason: "process_output_limit"); return }
            if isError { job.stderr.append(contentsOf: buffer.prefix(count)) }
            else { job.stdout.append(contentsOf: buffer.prefix(count)) }
        }
    }
    private static func terminate(_ job: Job, reason: String) {
        guard !job.finished, job.failure == nil else { return }
        job.failure = reason
        if job.pid == 0 { finish(job, result: .failure(Failure(code: reason))); return }
        kill(-job.pid, SIGTERM)
        job.killAt = ProcessInfo.processInfo.systemUptime + 0.1
    }
    private static func poll(_ job: Job) {
        guard !job.finished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now >= job.deadline { terminate(job, reason: "process_timeout") }
        if let killAt = job.killAt, now >= killAt { kill(-job.pid, SIGKILL); job.killAt = nil }
        if job.status == nil {
            var status: Int32 = 0
            let result = waitpid(job.pid, &status, WNOHANG)
            if result == job.pid { job.status = status }
            else if result < 0 && errno == ECHILD { job.status = 0 }
        }
        guard let status = job.status else { return }
        if let failure = job.failure {
            // The leader has exited; kill remaining group members before releasing pipe readers.
            kill(-job.pid, SIGKILL)
            finish(job, result: .failure(Failure(code: failure)))
        } else if job.readers.isEmpty {
            let signal = status & 0x7f
            let exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
            kill(-job.pid, SIGKILL)
            finish(job, result: .success(Output(exitCode: exitCode, stdout: String(decoding: job.stdout, as: UTF8.self), stderr: String(decoding: job.stderr, as: UTF8.self))))
        }
        // Descendants keeping pipes open are still subject to the original deadline.
    }
    private static func finish(_ job: Job, result: Result<Output, Error>) {
        guard !job.finished else { return }
        job.finished = true
        for reader in job.readers.values { reader.cancel() }; job.readers.removeAll()
        job.timer?.cancel(); job.timer = nil
        jobs.removeValue(forKey: job.id); waiting.removeAll { $0 === job }
        DispatchQueue.main.async { job.completion(result) }
        queue.async { startWaiting() }
    }
}
