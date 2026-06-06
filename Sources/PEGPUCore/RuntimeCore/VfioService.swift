import Foundation

public struct VfioDriverStatus: Codable, Equatable, Sendable {
    public var active: Bool
    public var bundleId: String?
    public var detail: String?
    public var needsUserApproval: Bool?
    public var state: String?
}

public final class VfioService: @unchecked Sendable {
    private let runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    public func helperExists() -> Bool {
        FileManager.default.fileExists(atPath: VfioApp.helperPath())
    }

    public func driverStatus() async throws -> VfioDriverStatus {
        let result = try await helper(["driver-status", "--json"], capture: true)
        return try JSON.decoder.decode(VfioDriverStatus.self, from: Data(result.utf8))
    }

    public func activateDriver() async throws -> String {
        let result = try await machineApp(["--driver-activate"], timeout: 60)
        return commandOutput(result)
    }

    public func deactivateDriver() async throws -> String {
        do {
            let result = try await machineApp(["--driver-deactivate"], timeout: 60)
            return commandOutput(result)
        } catch {
            let forced = try await forceUninstallDriver()
            return """
            Graceful driver deactivation failed: \(error)
            Forced driver uninstall result:
            \(forced)
            """
        }
    }

    public func forceUninstallDriver() async throws -> String {
        let result = try await runner.runChecked(
            "/usr/bin/systemextensionsctl",
            ["uninstall", "-", VfioApp.driverIdentifier],
            timeout: 30
        )
        return commandOutput(result)
    }

    private func helper(_ args: [String], capture: Bool) async throws -> String {
        let bin = VfioApp.helperPath()
        guard FileManager.default.fileExists(atPath: bin) else {
            throw RuntimeError.message("Missing \(VfioApp.displayName) helper at \(bin). Install \(VfioApp.displayName) in /Applications.")
        }
        if capture {
            let result = try await runner.runChecked(bin, args)
            return result.stdout
        }
        _ = try runner.spawnDetached(bin, args)
        return ""
    }

    private func machineApp(_ args: [String], timeout: TimeInterval) async throws -> RunResult {
        let bin = VfioApp.appExecutablePath()
        guard FileManager.default.fileExists(atPath: bin) else {
            throw RuntimeError.message("Missing \(VfioApp.displayName) executable at \(bin). Install \(VfioApp.displayName) in /Applications.")
        }
        return try await runner.runChecked(bin, args, timeout: timeout)
    }

    private func commandOutput(_ result: RunResult) -> String {
        let output = [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return output.isEmpty ? "command completed" : output
    }
}
