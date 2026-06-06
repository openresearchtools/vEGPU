import Foundation

public final class SSHClient: @unchecked Sendable {
    public static let user = "pegpu"
    public static let controlUser = "pegpuctl"

    public enum Role: Sendable {
        case control
        case human

        var user: String {
            switch self {
            case .control: return SSHClient.controlUser
            case .human: return SSHClient.user
            }
        }
    }

    private let paths: AppPaths
    private let networkStore: NetworkStateStore
    private let runner: ProcessRunner
    private let progress: ProgressCenter
    private let role: Role

    public init(paths: AppPaths, networkStore: NetworkStateStore, runner: ProcessRunner = ProcessRunner(), progress: ProgressCenter = .shared, role: Role = .control) {
        self.paths = paths
        self.networkStore = networkStore
        self.runner = runner
        self.progress = progress
        self.role = role
    }

    public var privateKeyPath: String {
        paths.ssh.appendingPathComponent("id_ed25519").path
    }

    public func ensureKey() async throws -> String {
        try FileManager.default.createDirectory(at: paths.ssh, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: privateKeyPath) {
            _ = try await runner.runChecked("/usr/bin/ssh-keygen", ["-t", "ed25519", "-N", "", "-f", privateKeyPath, "-C", "pegpu-machine"])
        }
        return privateKeyPath
    }

    public func args(command: String? = nil, tty: Bool = false) -> [String] {
        let endpoint = networkStore.read()
        var out: [String] = []
        if tty {
            out.append("-tt")
        }
        out += [
            "-i", privateKeyPath,
            "-p", String(endpoint.sshPort),
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=3",
            "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=2",
            "-o", "ServerAliveCountMax=1",
            "\(role.user)@\(endpoint.sshHost)"
        ]
        if let command {
            out.append(command)
        }
        return out
    }

    public func ssh(_ command: String, timeout: TimeInterval? = nil) async throws -> String {
        let result = try await runner.runChecked("/usr/bin/ssh", args(command: command), timeout: timeout)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func sshStreaming(_ command: String, timeout: TimeInterval? = nil, onOutput: @escaping @Sendable (String) -> Void) async throws -> String {
        let result = try await runner.runCheckedStreaming("/usr/bin/ssh", args(command: command), timeout: timeout, onOutput: onOutput)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func sshMaybe(_ command: String) async -> Bool {
        (try? await runner.run("/usr/bin/ssh", args(command: command))).map { $0.code == 0 } ?? false
    }

    public func scpToGuest(localPath: String, remotePath: String) async throws {
        let endpoint = networkStore.read()
        _ = try await runner.runChecked("/usr/bin/scp", [
            "-i", privateKeyPath,
            "-P", String(endpoint.sshPort),
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=3",
            "-o", "ConnectionAttempts=1",
            localPath,
            "\(role.user)@\(endpoint.sshHost):\(remotePath)"
        ])
    }

    public func scpFromGuest(remotePath: String, localPath: String) async throws {
        let endpoint = networkStore.read()
        _ = try await runner.runChecked("/usr/bin/scp", [
            "-i", privateKeyPath,
            "-P", String(endpoint.sshPort),
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=3",
            "-o", "ConnectionAttempts=1",
            "\(role.user)@\(endpoint.sshHost):\(remotePath)",
            localPath
        ])
    }

    public func agentCommand(_ args: [String]) -> String {
        "sudo -n /usr/local/libexec/pegpu/pegpu-agent \(args.map(shellQuote).joined(separator: " "))"
    }

    public func agent(_ args: [String], timeout: TimeInterval? = nil) async throws -> String {
        try await ssh(agentCommand(args), timeout: timeout)
    }

    public func agentStreaming(_ args: [String], timeout: TimeInterval? = nil, onOutput: @escaping @Sendable (String) -> Void) async throws -> String {
        try await sshStreaming(agentCommand(args), timeout: timeout, onOutput: onOutput)
    }

    public func waitForSSH(timeout: TimeInterval = 180) async throws {
        let started = Date()
        var lastReport: TimeInterval = 0
        while Date().timeIntervalSince(started) < timeout {
            if await sshMaybe("true") {
                return
            }
            let elapsed = Date().timeIntervalSince(started)
            if elapsed - lastReport > 8 {
                progress.report(ProgressEvent(stage: "ssh", message: "Waiting for Linux SSH", detail: "\(Int(elapsed))s elapsed"))
                lastReport = elapsed
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if role == .control {
            let humanSSH = SSHClient(paths: paths, networkStore: networkStore, runner: runner, progress: progress, role: .human)
            if await humanSSH.sshMaybe("true") {
                throw RuntimeError.message("Runtime SSH is reachable as pegpu, but the passwordless pegpuctl control user is missing or blocked. Reset/reseed this VM disk so cloud-init can create pegpuctl.")
            }
        }
        throw RuntimeError.message("Timed out waiting for PEGPU runtime SSH")
    }

    public func waitForGuestAgent(timeout: TimeInterval = 300) async throws {
        let started = Date()
        var lastReport: TimeInterval = 0
        while Date().timeIntervalSince(started) < timeout {
            if await sshMaybe(agentCommand(["status", "--json"])) {
                return
            }
            let elapsed = Date().timeIntervalSince(started)
            if elapsed - lastReport > 8 {
                progress.report(ProgressEvent(stage: "agent", message: "Waiting for PEGPU guest agent", detail: "\(Int(elapsed))s elapsed"))
                lastReport = elapsed
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw RuntimeError.message("Timed out waiting for PEGPU guest agent sudo access")
    }

    public func waitForCloudInit(timeout: TimeInterval = 1_200) async throws {
        let started = Date()
        var lastDetail = ""
        var reportedResizeWarning = false
        while Date().timeIntervalSince(started) < timeout {
            let result = try? await runner.run("/usr/bin/ssh", args(command: "cloud-init status --format=json 2>/dev/null || cloud-init status --long 2>&1"))
            let text = ((result?.stdout.isEmpty == false ? result?.stdout : result?.stderr) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = parseCloudInitStatus(text)
            if parsed.status == "done", parsed.ok || parsed.resizefsOnly {
                if parsed.resizefsOnly {
                    reportCloudInitResizefsWarningOnce(&reportedResizeWarning)
                    await repairCloudInitResizefsWarning()
                }
                return
            }
            if parsed.status == "error" || !parsed.ok {
                if parsed.resizefsOnly {
                    reportCloudInitResizefsWarningOnce(&reportedResizeWarning)
                    await repairCloudInitResizefsWarning()
                    return
                }
                if parsed.scriptsUserFailure {
                    progress.report(ProgressEvent(
                        stage: "cloud-init",
                        message: "Continuing after cloud-init firstboot failure",
                        detail: "Guest sync will refresh PEGPU tools and report the failing runtime step",
                        level: .error
                    ))
                    return
                }
                throw RuntimeError.message("cloud-init failed\n\(text)\n\(await cloudInitDiagnostics())")
            }
            let detail = parsed.detail ?? "\(Int(Date().timeIntervalSince(started)))s elapsed"
            if detail != lastDetail {
                progress.report(ProgressEvent(stage: "cloud-init", message: "cloud-init is still configuring Linux", detail: detail))
                lastDetail = detail
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        throw RuntimeError.message("Timed out waiting for cloud-init\n\(await cloudInitDiagnostics())")
    }

    private func parseCloudInitStatus(_ text: String) -> (status: String?, ok: Bool, detail: String?, resizefsOnly: Bool, scriptsUserFailure: Bool) {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let errors = object["errors"] as? [Any] ?? []
            let recoverable = object["recoverable_errors"] as? [String: [Any]] ?? [:]
            let status = object["status"] as? String
            let detail = object["extended_status"] as? String ?? status
            let errorText = (errors + recoverable.values.flatMap { $0 }).map { String(describing: $0) }
            let hasErrors = !errorText.isEmpty
            return (
                status,
                !hasErrors,
                detail,
                hasErrors && errorText.allSatisfy(isCloudInitResizefsWarning),
                hasErrors && errorText.allSatisfy(isCloudInitScriptsUserFailure)
            )
        }
        let done = text.range(of: #"status:\s*done"#, options: [.regularExpression, .caseInsensitive]) != nil
        let error = text.range(of: #"status:\s*error"#, options: [.regularExpression, .caseInsensitive]) != nil
        return (
            done ? "done" : (error ? "error" : nil),
            !error,
            firstLine(text),
            error && isCloudInitResizefsWarning(text),
            error && isCloudInitScriptsUserFailure(text)
        )
    }

    private func isCloudInitResizefsWarning(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.contains("resizefs") || lower.contains("resize2fs") else {
            return false
        }
        guard lower.contains("/dev/vda1") else {
            return false
        }
        return lower.contains("device or resource busy") ||
            lower.contains("failed to resize filesystem") ||
            lower.contains("cc_resizefs.py")
    }

    private func isCloudInitScriptsUserFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.contains("scripts-user") || lower.contains("cc_scripts_user.py") || lower.contains("runcmd") else {
            return false
        }
        return lower.contains("runparts: 1 failures") ||
            lower.contains("failed to run module scripts-user") ||
            lower.contains("runtimeerror")
    }

    private func reportCloudInitResizefsWarningOnce(_ reported: inout Bool) {
        if !reported {
            progress.report(ProgressEvent(
                stage: "cloud-init",
                message: "Repairing Linux root filesystem growth",
                detail: "cloud-init resizefs reported a mounted-root warning"
            ))
            reported = true
        }
    }

    private func repairCloudInitResizefsWarning() async {
        _ = try? await runner.run("/usr/bin/ssh", args(command: agentCommand(["grow-root-filesystem"])), timeout: 120)
    }

    private func cloudInitDiagnostics() async -> String {
        let command = [
            "cloud-init status --long 2>&1 || true",
            "echo '--- cloud-init-output.log ---'",
            "tail -n 160 /var/log/cloud-init-output.log 2>/dev/null || true",
            "echo '--- pegpu-firstboot.log ---'",
            "tail -n 160 /var/log/pegpu-firstboot.log 2>/dev/null || true"
        ].joined(separator: "; ")
        return ((try? await runner.run("/usr/bin/ssh", args(command: command))).map { $0.stdout.isEmpty ? $0.stderr : $0.stdout }) ?? ""
    }
}
