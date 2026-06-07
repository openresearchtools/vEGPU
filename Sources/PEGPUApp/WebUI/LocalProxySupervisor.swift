import Foundation
import Darwin
import PEGPUCore

@MainActor
final class LocalProxySupervisor: ObservableObject {
    @Published private(set) var status = "Stopped"

    private let paths: AppPaths
    private let runtimePaths: MachineRuntimePaths
    private let runner = ProcessRunner()
    private var process: Process?
    private var stopping = false
    private var restartTask: Task<Void, Never>?

    init(paths: AppPaths, runtimePaths: MachineRuntimePaths) {
        self.paths = paths
        self.runtimePaths = runtimePaths
    }

    func start() async throws {
        let portsFile = paths.machine.appendingPathComponent("ports.json")
        try await clearStaleProxies(portsFile: portsFile, preserving: process?.processIdentifier)
        if process?.isRunning == true {
            status = "Running"
            return
        }
        let executable = paths.toolsBin.appendingPathComponent("pegpu-local-proxy")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            status = "Missing"
            throw RuntimeError.message("Local port proxy helper is missing: \(executable.path)")
        }
        try runtimePaths.ensureDirectories()
        let targetHost = NetworkStateStore(paths: paths, liveDir: runtimePaths.root).read().guestHost
        stopping = false
        let log = runtimePaths.localProxyLog
        let child = try runner.spawnDetached(
            executable.path,
            [
                "--ports-file", portsFile.path,
                "--bind-host", "127.0.0.1",
                "--target-host", targetHost,
                "--gateway-host", VMNet.gateway,
                "--reload-interval", "1s",
                "--udp-ttl", "60s"
            ],
            cwd: paths.appData,
            stdout: log,
            stderr: log
        )
        process = child
        status = "Running"
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.handleExit()
            }
        }
    }

    func stop() {
        stopping = true
        restartTask?.cancel()
        restartTask = nil
        process?.terminate()
        process = nil
        status = "Stopped"
    }

    private func handleExit() {
        process = nil
        status = "Stopped"
        guard !stopping else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await self?.start()
            } catch {
                self?.status = "Error"
            }
        }
    }

    private func clearStaleProxies(portsFile: URL, preserving preservedPID: Int32?) async throws {
        let output = try await runner.run("/bin/ps", ["-axww", "-o", "pid=", "-o", "command="], timeout: 2).stdout
        let needle = "--ports-file \(portsFile.path)"
        let pids = output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Int32? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let firstSpace = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }),
                      let pid = Int32(String(trimmed[..<firstSpace]))
                else { return nil }
                let command = String(trimmed[firstSpace...])
                let isPreserved = preservedPID.map { $0 == pid } ?? false
                guard pid > 0,
                      pid != getpid(),
                      !isPreserved,
                      command.contains("pegpu-local-proxy"),
                      command.contains(needle)
                else { return nil }
                return pid
            }
        for pid in pids {
            await terminate(pid: pid)
        }
    }

    private func terminate(pid: Int32) async {
        kill(pid, SIGTERM)
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        kill(pid, SIGKILL)
    }
}
