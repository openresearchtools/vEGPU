import Foundation

public struct RunResult: Sendable, Codable, Equatable {
    public let code: Int32
    public let stdout: String
    public let stderr: String
}

public final class ProcessRunner: @unchecked Sendable {
    public init() {}

    public func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval? = nil,
        cwd: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> RunResult {
        try await Task.detached(priority: .userInitiated) {
            try self.runBlocking(
                executable,
                arguments,
                timeout: timeout,
                cwd: cwd,
                environment: environment
            )
        }.value
    }

    public func runChecked(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval? = nil,
        cwd: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> RunResult {
        let result = try await run(executable, arguments, timeout: timeout, cwd: cwd, environment: environment)
        guard result.code == 0 else {
            throw RuntimeError.commandFailed(command: ([executable] + arguments).joined(separator: " "), code: result.code, output: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }

    public func runStreaming(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval? = nil,
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> RunResult {
        try await Task.detached(priority: .userInitiated) {
            try self.runStreamingBlocking(
                executable,
                arguments,
                timeout: timeout,
                cwd: cwd,
                environment: environment,
                onOutput: onOutput
            )
        }.value
    }

    public func runCheckedStreaming(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval? = nil,
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> RunResult {
        let result = try await runStreaming(executable, arguments, timeout: timeout, cwd: cwd, environment: environment, onOutput: onOutput)
        guard result.code == 0 else {
            throw RuntimeError.commandFailed(command: ([executable] + arguments).joined(separator: " "), code: result.code, output: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }

    public func runAdminScript(_ script: String, prompt: String) async throws -> RunResult {
        try await runChecked("/usr/bin/osascript", [
            "-e",
            "do shell script \(appleScriptQuote(script)) with administrator privileges with prompt \(appleScriptQuote(prompt))"
        ])
    }

    public func spawnDetached(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        stdout: URL? = nil,
        stderr: URL? = nil
    ) throws -> Process {
        let workingDirectory = try ProcessLaunchSupport.workingDirectory(cwd)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        if let environment {
            process.environment = environment
        }
        process.standardInput = FileHandle.nullDevice
        if let stdout {
            FileManager.default.createFile(atPath: stdout.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: stdout)
        }
        if let stderr {
            FileManager.default.createFile(atPath: stderr.path, contents: nil)
            process.standardError = try FileHandle(forWritingTo: stderr)
        }
        try process.run()
        return process
    }

    private func runBlocking(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval?,
        cwd: URL?,
        environment: [String: String]?
    ) throws -> RunResult {
        let workingDirectory = try ProcessLaunchSupport.workingDirectory(cwd)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        if let environment {
            process.environment = environment
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe

        let started = Date()
        var timedOut = false
        try process.run()
        while process.isRunning {
            if let timeout, Date().timeIntervalSince(started) > timeout {
                timedOut = true
                process.terminate()
                Thread.sleep(forTimeInterval: 1.5)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return RunResult(
            code: timedOut ? 124 : process.terminationStatus,
            stdout: stdout,
            stderr: timedOut && stderr.isEmpty ? "\(executable) timed out after \(Int((timeout ?? 0) * 1000))ms" : stderr
        )
    }

    private func runStreamingBlocking(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval?,
        cwd: URL?,
        environment: [String: String]?,
        onOutput: @escaping @Sendable (String) -> Void
    ) throws -> RunResult {
        let workingDirectory = try ProcessLaunchSupport.workingDirectory(cwd)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        if let environment {
            process.environment = environment
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe

        let accumulator = StreamAccumulator(onOutput: onOutput)

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            while true {
                let data = outPipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                accumulator.consume(data, isError: false)
            }
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            while true {
                let data = errPipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                accumulator.consume(data, isError: true)
            }
        }

        let started = Date()
        var timedOut = false
        try process.run()
        while process.isRunning {
            if let timeout, Date().timeIntervalSince(started) > timeout {
                timedOut = true
                process.terminate()
                Thread.sleep(forTimeInterval: 1.5)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        group.wait()

        let output = accumulator.output()
        return RunResult(
            code: timedOut ? 124 : process.terminationStatus,
            stdout: output.stdout,
            stderr: timedOut && output.stderr.isEmpty ? "\(executable) timed out after \(Int((timeout ?? 0) * 1000))ms" : output.stderr
        )
    }
}

enum ProcessLaunchSupport {
    private static let fallbackDirectory = URL(fileURLWithPath: "/", isDirectory: true)

    static func workingDirectory(_ cwd: URL?) throws -> URL {
        _ = FileManager.default.changeCurrentDirectoryPath(fallbackDirectory.path)
        guard let cwd else {
            return fallbackDirectory
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RuntimeError.message("Process working directory does not exist: \(cwd.path)")
        }
        return cwd
    }
}

private final class StreamAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private let onOutput: @Sendable (String) -> Void

    init(onOutput: @escaping @Sendable (String) -> Void) {
        self.onOutput = onOutput
    }

    func consume(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if isError {
            stderr.append(data)
        } else {
            stdout.append(data)
        }
        lock.unlock()
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            onOutput(text)
        }
    }

    func output() -> (stdout: String, stderr: String) {
        lock.lock()
        let out = stdout
        let err = stderr
        lock.unlock()
        return (
            String(data: out, encoding: .utf8) ?? "",
            String(data: err, encoding: .utf8) ?? ""
        )
    }
}

public enum RuntimeError: Error, CustomStringConvertible, Sendable {
    case commandFailed(command: String, code: Int32, output: String)
    case message(String)

    public var description: String {
        switch self {
        case let .commandFailed(command, code, output):
            return "\(command) failed with \(code)\n\(output)"
        case let .message(message):
            return message
        }
    }
}
