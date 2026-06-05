import Foundation
import Darwin

public struct MachineStatus: Codable, Equatable, Sendable {
    public var state: String
    public var pid: Int32?
    public var detail: String?
}

public struct GuestDriverStatus: Codable, Equatable, Sendable {
    public var ready: Bool
    public var canReinstall: Bool
    public var state: String
    public var detail: String
}

public final class MachineService: @unchecked Sendable {
    private let paths: AppPaths
    private let files: MachineFiles
    private let runner: ProcessRunner
    private let progress: ProgressCenter
    private let configStore: MachineConfigStore
    private let manifestStore: ManifestStore
    private let secrets: SecretsStore
    private let networkStore: NetworkStateStore
    private let ssh: SSHClient
    private let share: NFSShareService
    private let audio: AudioBridgeService
    private let guestSync: GuestSyncService
    private let cloudInit: CloudInitService
    private let download: DownloadService
    private let startLock = NSLock()
    private var starting = false

    public init(paths: AppPaths = AppPaths(), runner: ProcessRunner = ProcessRunner(), progress: ProgressCenter = .shared) {
        self.paths = paths
        self.files = MachineFiles(machineDir: paths.machine)
        self.runner = runner
        self.progress = progress
        self.configStore = MachineConfigStore(paths: paths)
        self.manifestStore = ManifestStore(paths: paths)
        self.secrets = SecretsStore(paths: paths)
        self.networkStore = NetworkStateStore(paths: paths)
        self.ssh = SSHClient(paths: paths, networkStore: networkStore, runner: runner, progress: progress)
        self.share = NFSShareService(paths: paths, ssh: ssh, runner: runner, progress: progress)
        self.audio = AudioBridgeService(paths: paths, files: files, networkStore: networkStore, runner: runner)
        self.guestSync = GuestSyncService(paths: paths, ssh: ssh, manifestStore: manifestStore, progress: progress)
        self.cloudInit = CloudInitService(paths: paths, ssh: ssh, secrets: secrets, manifestStore: manifestStore, runner: runner)
        self.download = DownloadService(progress: progress)
    }

    public func currentPid() -> Int32? {
        guard let raw = try? String(contentsOf: files.pid, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(raw) else {
            return nil
        }
        guard kill(pid, 0) == 0 else {
            try? FileManager.default.removeItem(at: files.pid)
            return nil
        }
        guard isRuntimeProcess(pid) else {
            try? FileManager.default.removeItem(at: files.pid)
            return nil
        }
        return pid
    }

    public func initMachine() async throws {
        try paths.ensureDirectories()
        progress.report(ProgressEvent(stage: "init", message: "Preparing vEGPU runtime folders"))
        _ = try manifestStore.ensure()
        _ = try secrets.ensure()
        let tools = try ToolResolver().resolve()
        if !FileManager.default.fileExists(atPath: files.disk.path) {
            try await downloadMachineDisk()
            progress.report(ProgressEvent(stage: "disk", message: "Expanding runtime disk", detail: "qemu-img resize disk.qcow2 64G"))
            _ = try await runner.runChecked(tools.qemuImg, ["resize", files.disk.path, "64G"])
        }
        if !FileManager.default.fileExists(atPath: files.efiVars.path) {
            progress.report(ProgressEvent(stage: "firmware", message: "Creating UEFI variable store"))
            try createPflashVars(templatePath: tools.firmwareVarsTemplate, destination: files.efiVars)
        }
        progress.report(ProgressEvent(stage: "cloud-init", message: "Creating cloud-init seed ISO"))
        let config = configStore.effective()
        _ = try await cloudInit.createSeedIso(mode: config.launchMode, guiAppearance: config.guiAppearance, force: true)
    }

    public func startMachine() async throws {
        try beginStart()
        defer { endStart() }
        try await startMachineInner()
    }

    public func repairRunningMachine(reason: String) async throws {
        guard let pid = currentPid() else {
            throw RuntimeError.message("Runtime is not running")
        }
        await ensureHostAwakeAssertion(for: pid)
        try networkStore.write(networkStore.read())
        try await ssh.waitForSSH()
        try await ssh.waitForCloudInit()
        try await ssh.waitForGuestAgent()
        let synced = try await guestSync.sync(runtimePid: pid)
        try await repairRuntimeDependencies(shareRoot: configStore.effective().shareRoot, reason: reason)
        if synced {
            progress.report(ProgressEvent(stage: "ready", message: "vEGPU runtime is ready", level: .success))
        }
    }

    public func stopMachine(timeout: TimeInterval = 360) async throws {
        guard currentPid() != nil else {
            audio.stop()
            progress.report(ProgressEvent(stage: "stop", message: "Runtime is already stopped"))
            return
        }
        audio.stop()
        progress.report(ProgressEvent(stage: "stop", message: "Asking guest to power off"))
        let sshPoweroff = (try? await ssh.agent(["poweroff"])) != nil
        if !sshPoweroff {
            progress.report(ProgressEvent(stage: "stop", message: "SSH is offline; using QMP power button"))
            try? await requestQemuPowerdown()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentPid() == nil {
                progress.report(ProgressEvent(stage: "stop", message: "Runtime stopped cleanly", level: .success))
                return
            }
            if serialLogShowsGuestPowerOff() {
                progress.report(ProgressEvent(stage: "stop", message: "Guest powered off; closing QEMU"))
                try? await requestQemuQuit()
                _ = await waitForPidExit(currentPid(), timeout: 20)
                if currentPid() == nil {
                    progress.report(ProgressEvent(stage: "stop", message: "Runtime stopped cleanly", level: .success))
                    return
                }
                break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if currentPid() != nil {
            progress.report(ProgressEvent(stage: "stop", message: "Guest did not shut down cleanly; leaving QEMU running"))
            throw RuntimeError.message("Guest did not shut down cleanly. QEMU was left running to avoid unsafe PCIe teardown.")
        }
        progress.report(ProgressEvent(stage: "stop", message: "Runtime stopped", level: .success))
    }

    public func resetMachine() async throws {
        progress.report(ProgressEvent(stage: "reset", message: "Resetting runtime disk and state"))
        try await terminateQemuForReset()
        try? FileManager.default.removeItem(at: paths.machine)
        try paths.ensureDirectories()
        progress.report(ProgressEvent(stage: "reset", message: "Downloading clean runtime disk"))
        try await initMachine()
        progress.report(ProgressEvent(stage: "reset", message: "Runtime reset complete", detail: "Clean disk is ready; start the runtime when needed", level: .success))
    }

    public func forceKillMachineProcess() async throws {
        audio.stop()
        guard let pid = currentPid() else {
            try? FileManager.default.removeItem(at: files.pid)
            return
        }
        progress.report(ProgressEvent(stage: "stop", message: "Force killing QEMU runtime process"))
        kill(pid, SIGTERM)
        if await !waitForPidExit(pid, timeout: 3) {
            kill(pid, SIGKILL)
            _ = await waitForPidExit(pid, timeout: 2)
        }
        try? FileManager.default.removeItem(at: files.pid)
    }

    public func statusMachine() async -> MachineStatus {
        guard let pid = currentPid() else {
            return MachineStatus(state: "stopped", pid: nil, detail: nil)
        }
        let result = try? await runner.run("/usr/bin/ssh", ssh.args(command: "hostname"), timeout: 4)
        return MachineStatus(state: result?.code == 0 ? "running" : "booting", pid: pid, detail: result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func linuxPassword() -> String? {
        secrets.read()?.linuxPassword
    }

    public func audioBridgeStatus() -> AudioBridgeStatus {
        audio.status()
    }

    @discardableResult
    public func startAudioBridge(microphoneEnabled: Bool = false, bufferMs: Int = 20) async throws -> AudioBridgeStatus {
        if currentPid() == nil {
            throw RuntimeError.message("Runtime is stopped; start it before starting the audio bridge.")
        }
        try await ssh.waitForGuestAgent(timeout: 60)
        try await configureGuestAudioRTP()
        return try audio.start(microphoneEnabled: microphoneEnabled, bufferMs: bufferMs)
    }

    public func stopAudioBridge() {
        audio.stop()
    }

    @discardableResult
    public func changeLinuxPassword(_ newPassword: String) async throws -> MachineSecrets {
        try validateLinuxPassword(newPassword)
        let updated = MachineSecrets(linuxPassword: newPassword)
        if currentPid() == nil {
            guard !FileManager.default.fileExists(atPath: files.disk.path) else {
                throw RuntimeError.message("Runtime is stopped. Start the runtime before changing the Linux password so the VM disk and saved password stay in sync.")
            }
            try secrets.save(updated)
            let config = configStore.effective()
            _ = try await cloudInit.createSeedIso(mode: config.launchMode, guiAppearance: config.guiAppearance, force: true)
            return updated
        }

        progress.report(ProgressEvent(stage: "password", message: "Changing Linux user password", detail: SSHClient.user))
        try await ssh.waitForSSH(timeout: 60)
        let payload = Data("\(SSHClient.user):\(newPassword)\n".utf8).base64EncodedString()
        _ = try await ssh.ssh("printf %s \(shellQuote(payload)) | base64 -d | sudo -n chpasswd", timeout: 30)
        try secrets.save(updated)
        let config = configStore.effective()
        _ = try await cloudInit.createSeedIso(mode: config.launchMode, guiAppearance: config.guiAppearance, force: true)
        progress.report(ProgressEvent(stage: "password", message: "Linux password changed", detail: SSHClient.user, level: .success))
        return updated
    }

    @discardableResult
    public func saveConfig(_ config: MachineConfig) async throws -> MachineConfig {
        let before = configStore.load()
        let saved = try configStore.save(config)
        let shareChanged = saved.shareRoot != before.shareRoot ||
            saved.linuxHomeShareEnabled != before.linuxHomeShareEnabled ||
            saved.linuxHomeMountPath != before.linuxHomeMountPath
        if shareChanged, currentPid() != nil {
            progress.report(ProgressEvent(stage: "share", message: "Applying share settings", detail: saved.shareRoot))
            try await repairRuntimeDependencies(shareRoot: saved.shareRoot, reason: "share settings changed")
        }
        return saved
    }

    public func guestDriverStatus() async -> GuestDriverStatus {
        guard currentPid() != nil else {
            return GuestDriverStatus(ready: false, canReinstall: false, state: "stopped", detail: "Runtime is stopped.")
        }
        do {
            let text = try await ssh.agent(["status", "--json"])
            guard let data = text.data(using: .utf8),
                  let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return GuestDriverStatus(ready: false, canReinstall: false, state: "booting", detail: "Guest agent returned unreadable driver status.")
            }
            let driverInstalled = raw["driverInstalled"] as? String == "yes"
            let driverPersistent = raw["driverPersistent"] as? String == "yes"
            let moduleLoaded = raw["moduleLoaded"] as? String == "yes" || raw["driverLoaded"] as? String == "yes"
            let boundCount = (raw["boundDeviceCount"] as? NSNumber)?.intValue ?? Int(raw["boundDeviceCount"] as? String ?? "0") ?? 0
            let driverReady = raw["driverReady"] as? String == "yes"
            let passthroughReady = raw["passthroughReady"] as? String == "yes" || (driverReady && boundCount > 0)
            let boundDevices = textValue(raw["boundDevices"], fallback: "")
            if driverReady && passthroughReady {
                return GuestDriverStatus(
                    ready: true,
                    canReinstall: false,
                    state: "ready",
                    detail: "Passthrough ready (\(boundCount) device\(boundCount == 1 ? "" : "s"))"
                )
            }
            if driverReady {
                return GuestDriverStatus(ready: true, canReinstall: false, state: "ready", detail: "Installed and loaded; waiting for passthrough device")
            }
            if driverInstalled || driverPersistent {
                return GuestDriverStatus(ready: false, canReinstall: true, state: "not-loaded", detail: moduleLoaded ? "Loaded module does not match the running kernel" : "DKMS module is not loaded")
            }
            return GuestDriverStatus(
                ready: false,
                canReinstall: true,
                state: "not-loaded",
                detail: boundDevices.isEmpty
                    ? "DKMS module is not installed for this kernel"
                    : "DKMS module is not installed for this kernel - stale binding: \(boundDevices)"
            )
        } catch {
            return GuestDriverStatus(
                ready: false,
                canReinstall: false,
                state: "booting",
                detail: "Guest agent is not reachable yet: \(firstLine(String(describing: error)))"
            )
        }
    }

    public func reinstallGuestDriver() async throws -> GuestDriverStatus {
        guard let pid = currentPid() else {
            throw RuntimeError.message("Runtime is stopped; start it before reinstalling the Linux guest DMA driver.")
        }
        progress.report(ProgressEvent(stage: "driver", message: "Reinstalling Linux guest DMA driver"))
        try await guestSync.sync(force: true, runtimePid: pid)
        return await guestDriverStatus()
    }

    public func installNvidiaStack(onOutput: (@Sendable (String) -> Void)? = nil) async throws -> NvidiaSmiStatus {
        guard currentPid() != nil else {
            throw RuntimeError.message("Runtime is stopped; start it before installing NVIDIA support.")
        }
        progress.report(ProgressEvent(stage: "nvidia", message: "Installing NVIDIA driver and CUDA support", detail: "This runs apt inside the Linux VM."))
        if let onOutput {
            _ = try await ssh.agentStreaming(["install-nvidia-stack"], timeout: 7_200, onOutput: onOutput)
        } else {
            _ = try await ssh.agent(["install-nvidia-stack"], timeout: 7_200)
        }
        progress.report(ProgressEvent(stage: "nvidia", message: "NVIDIA installer finished", level: .success))
        return await MetricsService(ssh: ssh, runner: runner, machinePid: { self.currentPid() }).readNvidiaSmiStatus()
    }

    private func startMachineInner() async throws {
        if let existingPid = currentPid() {
            await ensureHostAwakeAssertion(for: existingPid)
            try networkStore.write(networkStore.read())
            do {
                try await ssh.waitForSSH()
            } catch {
                if serialLogShowsGuestPowerOff() {
                    progress.report(ProgressEvent(stage: "stop", message: "Cleaning up powered-off QEMU runtime"))
                    try? await requestQemuQuit()
                    if !(await waitForPidExit(existingPid, timeout: 20)) {
                        throw RuntimeError.message("Powered-off QEMU runtime did not exit after QMP quit. It was left running to avoid unsafe PCIe teardown.")
                    }
                    try? FileManager.default.removeItem(at: files.pid)
                    return try await startMachineInner()
                }
                throw error
            }
            try await ssh.waitForCloudInit()
            try await ssh.waitForGuestAgent()
            let synced = try await guestSync.sync(runtimePid: existingPid)
            try await repairRuntimeDependencies(shareRoot: configStore.effective().shareRoot, reason: "existing runtime start")
            if synced {
                progress.report(ProgressEvent(stage: "ready", message: "vEGPU runtime is ready", level: .success))
            }
            return
        }

        progress.report(ProgressEvent(stage: "start", message: "Starting vEGPU runtime"))
        try await initMachine()
        let config = configStore.effective()
        _ = try await cloudInit.createSeedIso(mode: config.launchMode, guiAppearance: config.guiAppearance, force: true)
        let tools = try ToolResolver().resolve()
        let network = networkStore.launcherNetwork(toolPaths: tools)
        _ = try await share.ensureHostShare(config.shareRoot)
        try? FileManager.default.removeItem(at: files.qmp)
        try? FileManager.default.removeItem(at: files.memoryFile)
        try? FileManager.default.removeItem(at: files.serialLog)
        try? FileManager.default.removeItem(at: files.stdoutLog)
        try? FileManager.default.removeItem(at: files.stderrLog)
        try? FileManager.default.removeItem(at: files.spiceSocket)

        var args = [
            "start",
            "--disk", files.disk.path,
            "--cpus", String(config.effectiveCpuCount),
            "--memory", "\(config.memoryMiB)M",
            "--efi-vars", files.efiVars.path,
            "--seed-iso", files.seedIso.path,
            "--qmp", files.qmp.path,
            "--pidfile", files.pid.path,
            "--serial-log", files.serialLog.path,
            "--qemu-log", files.qemuLog.path
        ]
        switch config.launchMode {
        case .headless:
            args += ["--headless"]
        case .gui:
            args += ["--spice-socket", files.spiceSocket.path]
            guard let angleFrameworks = AngleRuntime.frameworkDirectory(root: paths.root) else {
                throw RuntimeError.message("Missing app-side ANGLE runtime frameworks. Build the display runtime artifact and bundle EGL.framework and GLESv2.framework into vEGPU.app.")
            }
            args += ["--angle-framework-dir", angleFrameworks.path]
        }
        args += network.launcherArgs

        progress.report(ProgressEvent(stage: "qemu", message: "Launching runtime through \(VfioApp.displayName)", detail: config.launchMode.label))
        try networkStore.write(network.state)
        let child = try runner.spawnDetached(network.launchCommand, args, stdout: files.stdoutLog, stderr: files.stderrLog)
        await ensureHostAwakeAssertion(for: child.processIdentifier)
        try await waitForQmp(socket: files.qmp, timeout: 20, child: child)
        if let pid = currentPid() {
            await ensureHostAwakeAssertion(for: pid)
        }
        progress.report(ProgressEvent(stage: "qmp", message: "QEMU monitor is ready"))
        try await ssh.waitForSSH()
        progress.report(ProgressEvent(stage: "ssh", message: "SSH is reachable"))
        try await ssh.waitForCloudInit()
        progress.report(ProgressEvent(stage: "cloud-init", message: "cloud-init is complete"))
        try await ssh.waitForGuestAgent()
        progress.report(ProgressEvent(stage: "agent", message: "Guest agent is ready"))
        try await guestSync.sync(runtimePid: currentPid())
        try await repairRuntimeDependencies(shareRoot: config.shareRoot, reason: "runtime start")
        _ = try? await ssh.agent(["status", "--json"])
        progress.report(ProgressEvent(stage: "ready", message: "vEGPU runtime is ready", level: .success))
    }

    private func validateLinuxPassword(_ password: String) throws {
        guard password.count >= 8 else {
            throw RuntimeError.message("Linux password must be at least 8 characters.")
        }
        guard password.rangeOfCharacter(from: .newlines) == nil else {
            throw RuntimeError.message("Linux password cannot contain line breaks.")
        }
        guard !password.contains(":") else {
            throw RuntimeError.message("Linux password cannot contain ':' because Linux chpasswd uses it as a field separator.")
        }
    }

    private func repairRuntimeDependencies(shareRoot: String, reason: String) async throws {
        progress.report(ProgressEvent(stage: "runtime", message: "Repairing runtime dependencies", detail: reason))
        do {
            _ = try await ssh.agent(["configure-private-network"])
            let portForwardService = PortForwardService(paths: paths, networkStore: networkStore, ssh: ssh)
            let savedForwards = portForwardService.readHostForwards()
            if !savedForwards.isEmpty {
                try await portForwardService.applyGuestPrivatePorts(savedForwards)
                progress.report(ProgressEvent(stage: "network", message: "Applied localhost routes inside Linux", detail: "\(savedForwards.count) route(s)", level: .success))
            }
        } catch {
            let detail = firstLine(String(describing: error))
            progress.report(ProgressEvent(stage: "network", message: "Private vmnet needs attention", detail: detail, level: .error))
            throw RuntimeError.message("Private vmnet repair failed: \(detail)")
        }
        let config = configStore.effective()
        let result = try await share.ensureBidirectional(
            macShareRoot: shareRoot,
            linuxHomeMountPath: config.linuxHomeMountPath,
            linuxHomeEnabled: config.linuxHomeShareEnabled
        )
        switch result.macToLinux {
        case let .ready(_, expected, _):
            progress.report(ProgressEvent(stage: "share", message: "Mac share is mounted in Linux", detail: expected, level: .success))
        case let .busy(_, _, detail), let .unavailable(_, _, detail):
            progress.report(ProgressEvent(stage: "share", message: "Mac share needs attention", detail: detail, level: .error))
            throw RuntimeError.message("Mac share is not ready: \(firstLine(detail))")
        }
        if let linuxToMac = result.linuxToMac {
            switch linuxToMac {
            case let .ready(_, expected, _):
                progress.report(ProgressEvent(stage: "share", message: "Linux home is mounted on macOS", detail: expected, level: .success))
            case let .busy(_, _, detail), let .unavailable(_, _, detail):
                progress.report(ProgressEvent(stage: "share", message: "Linux home share needs attention", detail: detail, level: .error))
                throw RuntimeError.message("Linux home share is not ready: \(firstLine(detail))")
            }
        }
        if config.launchMode == .gui {
            try await configureGuestAudioRTP()
            let micEnabled = ProcessInfo.processInfo.environment["VEGPU_AUDIO_MIC"] == "1"
            let bufferMs = Int(ProcessInfo.processInfo.environment["VEGPU_AUDIO_BUFFER_MS"] ?? "") ?? 20
            do {
                let audioStatus = try audio.start(microphoneEnabled: micEnabled, bufferMs: bufferMs)
                progress.report(ProgressEvent(stage: "audio", message: audioStatus.running ? "Mac audio bridge is running" : "Mac audio bridge is unavailable", detail: audioStatus.detail, level: audioStatus.running ? .success : .info))
            } catch {
                progress.report(ProgressEvent(stage: "audio", message: "Mac audio bridge could not start", detail: firstLine(String(describing: error))))
            }
            progress.report(ProgressEvent(stage: "gui", message: "Ensuring GUI desktop integration"))
            let command = [
                "sudo -n",
                "env",
                "VEGPU_FORCE_SPICE_ON_LAUNCH=1",
                "VEGPU_GUI_RETINA=\(config.guiRetina ? "1" : "0")",
                "VEGPU_GUI_DENSITY=\(shellQuote(config.guiDensity.rawValue))",
                "VEGPU_GUI_APPEARANCE=\(shellQuote(config.guiAppearance.rawValue))",
                "/usr/local/sbin/vegpu-gui-ensure.sh"
            ].joined(separator: " ")
            _ = try await ssh.ssh(command, timeout: 1_800)
        }
    }

    private func configureGuestAudioRTP() async throws {
        do {
            _ = try await ssh.agent([
                "configure-audio-rtp",
                networkStore.read().macHost,
                String(AudioBridgeService.vmToMacPort),
                String(AudioBridgeService.macToVMPort)
            ], timeout: 60)
            progress.report(ProgressEvent(stage: "audio", message: "PipeWire RTP audio endpoints are ready", level: .success))
        } catch {
            let detail = firstLine(String(describing: error))
            progress.report(ProgressEvent(stage: "audio", message: "PipeWire RTP audio needs attention", detail: detail))
        }
    }

    private func ensureHostAwakeAssertion(for pid: Int32) async {
        guard pid > 0 else { return }
        let script = """
        set -eu
        PID=\(pid)
        if ! /bin/kill -0 "$PID" 2>/dev/null; then
          exit 0
        fi
        if /usr/bin/pgrep -fq "caffeinate .* -w $PID"; then
          exit 0
        fi
        /usr/bin/caffeinate -i -m -s -w "$PID" >/dev/null 2>&1 &
        """
        _ = try? await runner.run("/bin/sh", ["-lc", script], timeout: 2)
    }

    private func downloadMachineDisk() async throws {
        if FileManager.default.fileExists(atPath: files.disk.path) { return }
        try FileManager.default.createDirectory(at: files.disk.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifest = try manifestStore.load()
        let temporary = files.disk.deletingPathExtension().appendingPathExtension("qcow2.download")
        try? FileManager.default.removeItem(at: temporary)
        progress.report(ProgressEvent(stage: "download", message: "Downloading Debian runtime image", detail: manifest.debian.name, percent: 0))
        guard let url = URL(string: manifest.debian.url) else {
            throw RuntimeError.message("Invalid Debian image URL: \(manifest.debian.url)")
        }
        try await download.download(url, to: temporary)
        progress.report(ProgressEvent(stage: "verify", message: "Verifying Debian image checksum", detail: "SHA-512"))
        let actual = try sha512Hex(of: temporary)
        guard actual == manifest.debian.sha512 else {
            try? FileManager.default.removeItem(at: temporary)
            throw RuntimeError.message("Debian image checksum mismatch\nexpected \(manifest.debian.sha512)\nactual   \(actual)")
        }
        try FileManager.default.moveItem(at: temporary, to: files.disk)
        try JSON.write(DiskSource(manifest: manifest.id, image: manifest.debian.name, url: manifest.debian.url, sha512: manifest.debian.sha512), to: files.diskSource)
        progress.report(ProgressEvent(stage: "download", message: "Runtime image is ready", detail: manifest.debian.name, percent: 100, level: .success))
    }

    private func createPflashVars(templatePath: String, destination: URL) throws {
        let template = try Data(contentsOf: URL(fileURLWithPath: templatePath))
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 64 * 1024 * 1024)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: template)
    }

    private func waitForQmp(socket: URL, timeout: TimeInterval, child: Process) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !child.isRunning && currentPid() == nil {
                let log = (try? String(contentsOf: files.qemuLog, encoding: .utf8)) ?? ""
                throw RuntimeError.message("QEMU exited before QMP was ready\n\(log)")
            }
            if FileManager.default.fileExists(atPath: socket.path) { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw RuntimeError.message("Timed out waiting for QMP socket")
    }

    private func requestQemuQuit() async throws {
        try await QMPClient(socketURL: files.qmp).executeVoid("quit")
    }

    private func requestQemuPowerdown() async throws {
        try await QMPClient(socketURL: files.qmp).executeVoid("system_powerdown")
    }

    private func waitForPidExit(_ pid: Int32?, timeout: TimeInterval) async -> Bool {
        guard let pid else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func terminateQemuForReset() async throws {
        guard let pid = currentPid() else { return }
        progress.report(ProgressEvent(stage: "reset", message: "Terminating QEMU runtime process"))
        kill(pid, SIGTERM)
        if !(await waitForPidExit(pid, timeout: 3)) {
            progress.report(ProgressEvent(stage: "reset", message: "Force killing QEMU runtime process"))
            kill(pid, SIGKILL)
            _ = await waitForPidExit(pid, timeout: 2)
        }
    }

    private func serialLogShowsGuestPowerOff() -> Bool {
        guard let data = try? Data(contentsOf: files.serialLog) else { return false }
        let tail = data.suffix(256 * 1024)
        let text = String(data: tail, encoding: .utf8) ?? ""
        return text.range(of: #"System Power Off|systemd-shutdown\[1\]: Syncing filesystems|Reached target poweroff\.target"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func isRuntimeProcess(_ pid: Int32) -> Bool {
        guard let command = try? Process.runAndCapture("/bin/ps", ["-p", String(pid), "-o", "command="]).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return command.range(of: #"\b(qemu-system-aarch64|qemu-vfio-apple)\b"#, options: .regularExpression) != nil
    }

    private func beginStart() throws {
        startLock.lock()
        defer { startLock.unlock() }
        if starting {
            throw RuntimeError.message("Runtime start is already in progress")
        }
        starting = true
    }

    private func endStart() {
        startLock.lock()
        starting = false
        startLock.unlock()
    }

    private func textValue(_ value: Any?, fallback: String) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case .some(let other):
            return String(describing: other)
        case .none:
            return fallback
        }
    }
}

private struct DiskSource: Codable, Sendable {
    var manifest: String
    var image: String
    var url: String
    var sha512: String
    var downloadedAt: String = ISO8601DateFormatter().string(from: Date())
}
