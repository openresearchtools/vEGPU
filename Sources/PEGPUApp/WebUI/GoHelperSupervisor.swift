import Foundation
import Darwin
import PEGPUCore

@MainActor
final class GoHelperSupervisor: ObservableObject {
    @Published private(set) var status = "Stopped"
    private let paths: AppPaths
    private let runtimePaths: MachineRuntimePaths
    private let profileID: String
    private let bridge: NativeBridgeService
    private let runner = ProcessRunner()
    private var process: Process?
    private var stopping = false
    private var restartTask: Task<Void, Never>?
    private let webPort: Int

    init(paths: AppPaths, runtimePaths: MachineRuntimePaths, profileID: String, bridge: NativeBridgeService) {
        self.paths = paths
        self.runtimePaths = runtimePaths
        self.profileID = profileID
        self.bridge = bridge
        self.webPort = Self.loadOrAssignPort(runtimePaths: runtimePaths, profileID: profileID)
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(webPort)")!
    }

    func start() async throws {
        if process?.isRunning == true {
            status = "Running"
            return
        }
        let appDir = paths.root.appendingPathComponent("ai/web-ui-app", isDirectory: true)
        let binary = appDir.appendingPathComponent("web-ui-app")
        try runtimePaths.ensureDirectories()
        try await clearStaleHelperOnPort()
        var environment = ProcessInfo.processInfo.environment
        environment["PEGPU_APP_DATA_DIR"] = paths.appData.path
        environment["PEGPU_HOST_RUNTIME_DIR"] = runtimePaths.root.path
        environment["PEGPU_WEB_UI_PORT"] = String(webPort)
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
        process = try runner.spawnDetached(
            executable,
            arguments,
            cwd: appDir,
            environment: environment,
            stdout: runtimePaths.helperLog,
            stderr: runtimePaths.helperErrorLog
        )
        process?.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.handleExit()
            }
        }
        status = "Running"
    }

    private func clearStaleHelperOnPort() async throws {
        let result = try? await runner.run("/usr/sbin/lsof", ["-nP", "-iTCP@127.0.0.1:\(webPort)", "-sTCP:LISTEN", "-t"], timeout: 2)
        let pids = (result?.stdout ?? "")
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 && $0 != getpid() }
        guard !pids.isEmpty else { return }

        for pid in pids {
            let processInfo = try? await runner.run("/bin/ps", ["eww", "-p", String(pid)], timeout: 2)
            let command = processInfo?.stdout ?? ""
            guard command.contains("web-ui-app"),
                  command.contains("PEGPU_WEB_UI_PORT=\(webPort)"),
                  command.contains("PEGPU_APP_DATA_DIR=\(paths.appData.path)") else {
                throw RuntimeError.message("Web helper port \(webPort) is already in use by another process. Stop that process before opening PEGPU Models.")
            }
            kill(pid, SIGTERM)
            for _ in 0..<20 {
                if kill(pid, 0) != 0 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
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

    private static func loadOrAssignPort(runtimePaths: MachineRuntimePaths, profileID: String) -> Int {
        if let state = try? JSON.read(WebHelperRuntimeState.self, from: runtimePaths.helperState),
           state.profileID == profileID,
           isValidPort(state.port) {
            return state.port
        }
        let start = 39_292 + (stableHash(profileID) % 10_000)
        for offset in 0..<10_000 {
            let port = 30_000 + ((start + offset) % 30_000)
            if port != 9_292 && isValidPort(port) && isPortAvailable(port) {
                try? JSON.write(WebHelperRuntimeState(profileID: profileID, port: port), to: runtimePaths.helperState)
                return port
            }
        }
        let fallback = 39_292
        try? JSON.write(WebHelperRuntimeState(profileID: profileID, port: fallback), to: runtimePaths.helperState)
        return fallback
    }

    private static func stableHash(_ value: String) -> Int {
        var hash = UInt64(14_695_981_039_346_656_037)
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(Int.max))
    }

    private static func isValidPort(_ port: Int) -> Bool {
        port > 1_024 && port < 65_536
    }

    private static func isPortAvailable(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

private struct WebHelperRuntimeState: Codable {
    var profileID: String
    var port: Int
}
