import Foundation

/// Runs the commands that completion specs use to generate suggestions
/// (for example `git branch`), off the main thread.
enum ProcessRunner {
    struct Output {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private static let queue = DispatchQueue(label: "dev.jamun.process", attributes: .concurrent)

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?,
        timeout: TimeInterval,
        completion: @escaping (Result<Output, Error>) -> Void
    ) {
        queue.async {
            let process = Process()
            // Bare command names are resolved through PATH, like a shell would.
            if executable.contains("/") {
                process.executableURL = URL(fileURLWithPath: Paths.expandTilde(executable))
                process.arguments = arguments
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [executable] + arguments
            }
            process.environment = environment
            // Specs pass paths like "~/src/", which only a shell would expand.
            if let directory = workingDirectory.map(Paths.expandTilde),
               FileManager.default.fileExists(atPath: directory) {
                process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            let killer = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: killer)

            // Drain both pipes concurrently so a chatty stderr cannot block stdout.
            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            queue.async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            process.waitUntilExit()
            killer.cancel()

            let output = Output(
                exitCode: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self)
            )
            DispatchQueue.main.async { completion(.success(output)) }
        }
    }
}
