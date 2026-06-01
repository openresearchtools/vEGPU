import Foundation
import vEGPUCore

@MainActor
final class GoHelperSupervisor: ObservableObject {
    @Published private(set) var status = "Stopped"
    private let paths: AppPaths
    private let bridge: NativeBridgeService
    private let runner = ProcessRunner()
    private var process: Process?
    private var stopping = false
    private var restartTask: Task<Void, Never>?

    init(paths: AppPaths, bridge: NativeBridgeService) {
        self.paths = paths
        self.bridge = bridge
    }

    func start() async throws {
        if process?.isRunning == true {
            status = "Running"
            return
        }
        let appDir = paths.root.appendingPathComponent("ai/web-ui-app", isDirectory: true)
        let binary = appDir.appendingPathComponent("web-ui-app")
        let logs = paths.appData.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["VEGPU_APP_DATA_DIR"] = paths.appData.path
        environment["WEB_UI_APP_DIR"] = appDir.path
        for (key, value) in try bridge.environment() {
            environment[key] = value
        }
        stopping = false

        let executable: String
        let arguments: [String]
        if FileManager.default.isExecutableFile(atPath: binary.path) {
            executable = binary.path
            arguments = []
        } else {
            executable = "/usr/bin/env"
            arguments = ["go", "run", "."]
        }
        StaleProcessCleaner.terminateProcesses(containing: "/ai/web-ui-app/web-ui-app")
        StaleProcessCleaner.terminateProcesses(containing: executable == binary.path ? binary.path : appDir.path)
        process = try runner.spawnDetached(
            executable,
            arguments,
            cwd: appDir,
            environment: environment,
            stdout: logs.appendingPathComponent("web-ui-app.stdout.log"),
            stderr: logs.appendingPathComponent("web-ui-app.stderr.log")
        )
        process?.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.handleExit()
            }
        }
        status = "Running"
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
}
