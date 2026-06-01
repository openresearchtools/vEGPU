import Foundation
import vEGPUCore

@MainActor
final class LocalProxySupervisor: ObservableObject {
    @Published private(set) var status = "Stopped"

    private let paths: AppPaths
    private let runner = ProcessRunner()
    private var process: Process?
    private var stopping = false
    private var restartTask: Task<Void, Never>?

    init(paths: AppPaths) {
        self.paths = paths
    }

    func start() throws {
        if process?.isRunning == true {
            status = "Running"
            return
        }
        let executable = paths.toolsBin.appendingPathComponent("vegpu-local-proxy")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            status = "Missing"
            throw RuntimeError.message("Local port proxy helper is missing: \(executable.path)")
        }
        StaleProcessCleaner.terminateProcesses(containing: executable.path)
        try FileManager.default.createDirectory(at: paths.appData, withIntermediateDirectories: true)
        let portsFile = paths.machine.appendingPathComponent("ports.json")
        let targetHost = NetworkStateStore(paths: paths).read().guestHost
        stopping = false
        let log = paths.appData.appendingPathComponent("local-proxy.log")
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
                try self?.start()
            } catch {
                self?.status = "Error"
            }
        }
    }
}
