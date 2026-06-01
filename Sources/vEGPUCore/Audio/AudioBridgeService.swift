import Foundation
import Darwin

public struct AudioBridgeStatus: Codable, Equatable, Sendable {
    public var running: Bool
    public var pid: Int32?
    public var microphoneEnabled: Bool
    public var bufferMs: Int
    public var detail: String
}

public final class AudioBridgeService: @unchecked Sendable {
    public static let vmToMacPort = 47_110
    public static let macToVMPort = 47_111

    private let paths: AppPaths
    private let files: MachineFiles
    private let networkStore: NetworkStateStore
    private let runner: ProcessRunner

    public init(paths: AppPaths, files: MachineFiles, networkStore: NetworkStateStore, runner: ProcessRunner = ProcessRunner()) {
        self.paths = paths
        self.files = files
        self.networkStore = networkStore
        self.runner = runner
    }

    public func status() -> AudioBridgeStatus {
        guard let state = try? JSON.read(AudioBridgeLaunchState.self, from: files.audioHostState),
              let pid = state.pid,
              processIsRunning(pid) else {
            return AudioBridgeStatus(running: false, pid: nil, microphoneEnabled: false, bufferMs: 0, detail: "Audio bridge is stopped")
        }
        return AudioBridgeStatus(
            running: true,
            pid: pid,
            microphoneEnabled: state.microphoneEnabled,
            bufferMs: state.bufferMs,
            detail: "Audio bridge is running"
        )
    }

    @discardableResult
    public func start(microphoneEnabled: Bool = false, bufferMs: Int = 20) throws -> AudioBridgeStatus {
        let boundedBufferMs = max(5, min(250, bufferMs))
        let current = status()
        if current.running && current.microphoneEnabled == microphoneEnabled && current.bufferMs == boundedBufferMs {
            return current
        } else if current.running {
            stop()
        }
        let helper = paths.toolsBin.appendingPathComponent("vegpu-audio-host")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            return AudioBridgeStatus(running: false, pid: nil, microphoneEnabled: false, bufferMs: 0, detail: "Audio helper is not installed at \(helper.path)")
        }
        try FileManager.default.createDirectory(at: files.audioHostPid.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: files.audioHostPid)
        try? FileManager.default.removeItem(at: files.audioHostState)

        let network = networkStore.read()
        var args = [
            "--vm", network.guestHost,
            "--listen", String(Self.vmToMacPort),
            "--send", String(Self.macToVMPort),
            "--buffer-ms", String(boundedBufferMs)
        ]
        if microphoneEnabled {
            args.append("--mic")
        }
        let child = try runner.spawnDetached(
            helper.path,
            args,
            stdout: files.audioHostLog,
            stderr: files.audioHostErr
        )
        let state = AudioBridgeLaunchState(
            pid: child.processIdentifier,
            microphoneEnabled: microphoneEnabled,
            bufferMs: boundedBufferMs
        )
        try JSON.write(state, to: files.audioHostState)
        try String(child.processIdentifier).write(to: files.audioHostPid, atomically: true, encoding: .utf8)
        return status()
    }

    public func stop() {
        guard let state = try? JSON.read(AudioBridgeLaunchState.self, from: files.audioHostState),
              let pid = state.pid else {
            try? FileManager.default.removeItem(at: files.audioHostPid)
            try? FileManager.default.removeItem(at: files.audioHostState)
            return
        }
        if processIsRunning(pid) {
            kill(pid, SIGTERM)
            for _ in 0..<20 {
                if !processIsRunning(pid) {
                    break
                }
                usleep(100_000)
            }
            if processIsRunning(pid) {
                kill(pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: files.audioHostPid)
        try? FileManager.default.removeItem(at: files.audioHostState)
    }

    private func processIsRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}

private struct AudioBridgeLaunchState: Codable {
    var pid: Int32?
    var microphoneEnabled: Bool
    var bufferMs: Int
}
