import AppKit
import Foundation
import PEGPUCore

enum DisplayControlMode: Equatable, Sendable {
    case spice
    case externalPrimary
    case unknown(String)

    init(_ rawValue: String) {
        switch rawValue {
        case "spice":
            self = .spice
        case "external-primary":
            self = .externalPrimary
        default:
            self = .unknown(rawValue)
        }
    }

    var title: String {
        switch self {
        case .spice:
            return "SPICE"
        case .externalPrimary:
            return "eGPU"
        case .unknown:
            return "Display"
        }
    }
}

struct DisplayControlGPU: Decodable, Equatable, Identifiable, Sendable {
    let index: String
    let name: String
    let bdf: String
    let valid: Bool

    var id: String { bdf }

    var menuTitle: String {
        "\(name) [\(bdf)]"
    }

    private enum CodingKeys: String, CodingKey {
        case index
        case name
        case bdf
        case valid
    }

    init(index: String, name: String, bdf: String, valid: Bool = true) {
        self.index = index
        self.name = name
        self.bdf = bdf
        self.valid = valid
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(String.self, forKey: .index)
        name = try container.decode(String.self, forKey: .name)
        bdf = try container.decode(String.self, forKey: .bdf)
        valid = try container.decodeIfPresent(Bool.self, forKey: .valid) ?? true
    }
}

struct DisplayControlStatus: Equatable, Sendable {
    let mode: DisplayControlMode
    let selectedGPU: DisplayControlGPU?
    let displayManagerActive: Bool
    let sessionActive: Bool
}

private struct DisplayControlStatusPayload: Decodable {
    let mode: String
    let selectedGPU: DisplayControlGPU?
    let displayManagerActive: Bool?
    let sessionActive: Bool?
}

private struct DisplayControlGPUListPayload: Decodable {
    let gpus: [DisplayControlGPU]
}

struct DisplaySessionOutput: Decodable, Equatable, Identifiable, Sendable {
    let name: String
    let connected: Bool
    let primary: Bool
    let mode: String
    let x: Int
    let y: Int

    var id: String { name }
}

struct DisplaySession: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let index: String
    let name: String
    let bdf: String
    let display: String
    let state: String
    let active: Bool
    let valid: Bool
    let outputs: [DisplaySessionOutput]

    var gpu: DisplayControlGPU {
        DisplayControlGPU(index: index, name: name, bdf: bdf, valid: valid)
    }

    var running: Bool {
        state == "running"
    }

    var title: String {
        "\(name) [\(bdf)]"
    }

    var modelTitle: String {
        Self.sanitizedGPUModel(name)
    }

    private static func sanitizedGPUModel(_ rawName: String) -> String {
        var value = rawName
        for token in ["NVIDIA", "GeForce", "AMD", "Radeon", "Graphics", "GPU", "RTX", "GTX"] {
            value = value.replacingOccurrences(
                of: "\\b\(token)\\b",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        let cleaned = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? rawName : cleaned
    }
}

struct DisplaySessionsPayload: Decodable {
    let active: String
    let sessions: [DisplaySession]
}

final class DisplayControlService: @unchecked Sendable {
    private let paths: AppPaths
    private let ssh: SSHClient
    private var helperPrepared = false

    init(paths: AppPaths) {
        self.paths = paths
        self.ssh = SSHClient(
            paths: paths,
            networkStore: NetworkStateStore(paths: paths),
            role: .control
        )
    }

    func status() async throws -> DisplayControlStatus {
        let output = try await ssh.ssh("/usr/local/bin/pegpu-display-control status --json", timeout: 10)
        let payload = try JSONDecoder().decode(DisplayControlStatusPayload.self, from: Data(output.utf8))
        return DisplayControlStatus(
            mode: DisplayControlMode(payload.mode),
            selectedGPU: payload.selectedGPU,
            displayManagerActive: payload.displayManagerActive ?? false,
            sessionActive: payload.sessionActive ?? false
        )
    }

    func listGPUs() async throws -> [DisplayControlGPU] {
        do {
            let output = try await ssh.ssh("/usr/local/bin/pegpu-display-control list-gpus --json", timeout: 10)
            let payload = try JSONDecoder().decode(DisplayControlGPUListPayload.self, from: Data(output.utf8))
            return payload.gpus.filter(\.valid)
        } catch {
            return try await listGPUsDirectly()
        }
    }

    func sessions() async throws -> DisplaySessionsPayload {
        let output = try await ssh.ssh("/usr/local/bin/pegpu-display-control sessions --json", timeout: 15)
        return try JSONDecoder().decode(DisplaySessionsPayload.self, from: Data(output.utf8))
    }

    func startSession(_ session: DisplaySession) async throws {
        let command = "/usr/local/bin/pegpu-display-control session-start \(shellQuote(session.bdf)) \(shellQuote(session.index))"
        _ = try await ssh.ssh(command, timeout: 45)
    }

    func enterSession(_ session: DisplaySession) async throws {
        let command = "/usr/local/bin/pegpu-display-control session-enter \(shellQuote(session.id))"
        _ = try await ssh.ssh(command, timeout: 20)
    }

    func releaseSession() async throws {
        _ = try await ssh.ssh("/usr/local/bin/pegpu-display-control session-release", timeout: 20)
    }

    func stopSession(_ session: DisplaySession) async throws {
        let command = "/usr/local/bin/pegpu-display-control session-stop \(shellQuote(session.id))"
        _ = try await ssh.ssh(command, timeout: 30)
    }

    func refreshOutputs(_ session: DisplaySession) async throws {
        let command = "/usr/local/bin/pegpu-display-control session-outputs \(shellQuote(session.id))"
        _ = try await ssh.ssh(command, timeout: 15)
    }

    func reloadSession(_ session: DisplaySession) async throws {
        let command = "/usr/local/bin/pegpu-display-control session-reload \(shellQuote(session.id))"
        _ = try await ssh.ssh(command, timeout: 30)
    }

    func switchToExternalPrimary(gpu: DisplayControlGPU) async throws {
        let command = "/usr/local/bin/pegpu-display-control external-primary \(shellQuote(gpu.bdf)) \(shellQuote(gpu.index))"
        _ = try await ssh.ssh(command, timeout: 45)
    }

    func switchToSpice() async throws {
        _ = try await ssh.ssh("/usr/local/bin/pegpu-display-control spice", timeout: 45)
    }

    func reload() async throws {
        _ = try await ssh.ssh("/usr/local/bin/pegpu-display-control reload", timeout: 45)
    }

    private func prepareDisplayHelper(force: Bool = false) async throws {
        guard force || !helperPrepared else { return }
        let source = paths.resources.appendingPathComponent("Guest/pegpu-gui-ensure.sh")
        let customizationSource = paths.resources.appendingPathComponent("Guest/customization.sh")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RuntimeError.message("Bundled GUI helper is missing: \(source.path)")
        }
        guard FileManager.default.fileExists(atPath: customizationSource.path) else {
            throw RuntimeError.message("Bundled GUI customization helper is missing: \(customizationSource.path)")
        }
        let remote = "/tmp/pegpu-gui-ensure-\(UUID().uuidString).sh"
        let customizationRemote = "/tmp/pegpu-customization-\(UUID().uuidString).sh"
        try await ssh.scpToGuest(localPath: source.path, remotePath: remote)
        try await ssh.scpToGuest(localPath: customizationSource.path, remotePath: customizationRemote)
        try await uploadScalingApp()
        try await uploadPerformanceApp()
        let config = MachineConfigStore(paths: paths).load()
        let guiPrefs = [
            "PEGPU_GUI_RETINA=\(config.guiRetina ? "1" : "0")",
            "PEGPU_GUI_DENSITY=\(shellQuote(config.guiDensity.rawValue))",
            "PEGPU_GUI_APPEARANCE=\(shellQuote(config.guiAppearance.rawValue))"
        ].joined(separator: " ")
        let command = [
            "sudo -n install -d /usr/local/libexec/pegpu",
            "sudo -n install -m 0755 \(shellQuote(customizationRemote)) /usr/local/libexec/pegpu/customization.sh",
            "sudo -n install -m 0755 \(shellQuote(remote)) /usr/local/sbin/pegpu-gui-ensure.sh",
            "sudo -n env \(guiPrefs) /usr/local/sbin/pegpu-gui-ensure.sh --install-display-control-only",
            "rm -f \(shellQuote(remote)) \(shellQuote(customizationRemote))"
        ].joined(separator: " && ")
        _ = try await ssh.ssh(command, timeout: 30)
        helperPrepared = true
    }

    private func uploadScalingApp() async throws {
        let root = paths.resources.appendingPathComponent("Guest/scaling-app", isDirectory: true)
        if let package = scalingAppPackage(in: root) {
            let remote = "/tmp/pegpu-scaling-app-\(UUID().uuidString)-\(package.lastPathComponent)"
            try await ssh.scpToGuest(localPath: package.path, remotePath: remote)
            let aptOptions = "-o DPkg::Lock::Timeout=600 -o APT::Get::Lock-Timeout=600"
            _ = try await ssh.ssh("\(aptInstallLocalDebCommand(remote: remote, aptOptions: aptOptions)) && rm -f \(shellQuote(remote))", timeout: 60)
            return
        }
        let files: [(String, String)] = [
            ("install.sh", "0755"),
            ("bin/pegpu-scaling", "0755"),
            ("src/pegpu_scaling.py", "0644"),
            ("share/applications/pegpu-scaling.desktop", "0644"),
            ("share/icons/hicolor/scalable/apps/pegpu-scaling.svg", "0644"),
            ("share/xdg/autostart/pegpu-scaling-reapply.desktop", "0644")
        ]
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("install.sh").path) else { return }
        _ = try await ssh.ssh("sudo -n rm -rf /usr/local/libexec/pegpu/scaling-app && sudo -n install -d /usr/local/libexec/pegpu/scaling-app", timeout: 10)
        for (relative, mode) in files {
            let source = root.appendingPathComponent(relative).path
            guard FileManager.default.fileExists(atPath: source) else { continue }
            let remote = "/tmp/pegpu-scaling-app-\(UUID().uuidString)-\(URL(fileURLWithPath: relative).lastPathComponent)"
            let destination = "/usr/local/libexec/pegpu/scaling-app/\(relative)"
            try await ssh.scpToGuest(localPath: source, remotePath: remote)
            _ = try await ssh.ssh("sudo -n install -D -m \(mode) \(shellQuote(remote)) \(shellQuote(destination)) && rm -f \(shellQuote(remote))", timeout: 10)
        }
        _ = try await ssh.ssh("sudo -n env PEGPU_SCALING_SKIP_DEPS=1 /usr/local/libexec/pegpu/scaling-app/install.sh", timeout: 20)
    }

    private func uploadPerformanceApp() async throws {
        let root = paths.resources.appendingPathComponent("Guest/performance-app", isDirectory: true)
        if let package = performanceAppPackage(in: root) {
            let remote = "/tmp/pegpu-performance-app-\(UUID().uuidString)-\(package.lastPathComponent)"
            try await ssh.scpToGuest(localPath: package.path, remotePath: remote)
            let aptOptions = "-o DPkg::Lock::Timeout=600 -o APT::Get::Lock-Timeout=600"
            _ = try await ssh.ssh("\(aptInstallLocalDebCommand(remote: remote, aptOptions: aptOptions)) && rm -f \(shellQuote(remote))", timeout: 60)
            return
        }
        let files: [(String, String)] = [
            ("install.sh", "0755"),
            ("bin/pegpu-performance", "0755"),
            ("src/pegpu_performance.py", "0644"),
            ("share/applications/pegpu-performance.desktop", "0644"),
            ("share/icons/source/pegpu-performance.png", "0644"),
            ("share/icons/hicolor/256x256/apps/pegpu-performance.png", "0644"),
            ("share/icons/hicolor/512x512/apps/pegpu-performance.png", "0644"),
            ("share/icons/hicolor/1024x1024/apps/pegpu-performance.png", "0644")
        ]
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("install.sh").path) else { return }
        _ = try await ssh.ssh("sudo -n rm -rf /usr/local/libexec/pegpu/performance-app && sudo -n install -d /usr/local/libexec/pegpu/performance-app", timeout: 10)
        for (relative, mode) in files {
            let source = root.appendingPathComponent(relative).path
            guard FileManager.default.fileExists(atPath: source) else { continue }
            let remote = "/tmp/pegpu-performance-app-\(UUID().uuidString)-\(URL(fileURLWithPath: relative).lastPathComponent)"
            let destination = "/usr/local/libexec/pegpu/performance-app/\(relative)"
            try await ssh.scpToGuest(localPath: source, remotePath: remote)
            _ = try await ssh.ssh("sudo -n install -D -m \(mode) \(shellQuote(remote)) \(shellQuote(destination)) && rm -f \(shellQuote(remote))", timeout: 10)
        }
        _ = try await ssh.ssh("sudo -n env PEGPU_PERFORMANCE_SKIP_DEPS=1 /usr/local/libexec/pegpu/performance-app/install.sh", timeout: 20)
    }

    private func scalingAppPackage(in root: URL) -> URL? {
        let packageDir = root.appendingPathComponent("package", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: packageDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        return items
            .filter { $0.lastPathComponent.hasPrefix("pegpu-scaling_") && $0.pathExtension == "deb" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last
    }

    private func performanceAppPackage(in root: URL) -> URL? {
        let packageDir = root.appendingPathComponent("package", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: packageDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        return items
            .filter { $0.lastPathComponent.hasPrefix("pegpu-performance_") && $0.pathExtension == "deb" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last
    }

    private func aptInstallLocalDebCommand(remote: String, aptOptions: String) -> String {
        let remoteURL = URL(fileURLWithPath: remote)
        let remoteDir = remoteURL.deletingLastPathComponent().path
        let relativeDeb = "./\(remoteURL.lastPathComponent)"
        return "cd \(shellQuote(remoteDir)) && sudo -n env DEBIAN_FRONTEND=noninteractive apt-get \(aptOptions) install -y \(shellQuote(relativeDeb))"
    }

    private func listGPUsDirectly() async throws -> [DisplayControlGPU] {
        let script = """
        set -eu
        if ! command -v nvidia-smi >/dev/null 2>&1; then
          exit 0
        fi
        nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv,noheader,nounits 2>/dev/null || true
        """
        let output = try await ssh.ssh("bash -lc \(shellQuote(script))", timeout: 10)
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> DisplayControlGPU? in
                let parts = line.split(separator: ",", maxSplits: 2).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard parts.count == 3, let bdf = Self.normalizeBDF(parts[2]) else { return nil }
                return DisplayControlGPU(index: parts[0], name: parts[1], bdf: bdf)
            }
    }

    private static func normalizeBDF(_ rawValue: String) -> String? {
        let raw = rawValue
            .replacingOccurrences(of: "pci:", with: "")
            .lowercased()
        let pieces = raw.split { $0 == ":" || $0 == "." }.map(String.init)
        guard pieces.count == 4,
              let domain = Int(String(pieces[0].suffix(4)), radix: 16),
              let bus = Int(pieces[1], radix: 16),
              let slot = Int(pieces[2], radix: 16),
              let function = Int(pieces[3], radix: 10) else {
            return nil
        }
        return String(format: "%04x:%02x:%02x.%d", domain, bus, slot, function)
    }
}

@MainActor
final class DisplayControlMenuModel: ObservableObject {
    @Published private(set) var gpus: [DisplayControlGPU] = []
    @Published private(set) var sessions: [DisplaySession] = []
    @Published private(set) var activeSessionID: String?
    @Published private(set) var mode: DisplayControlMode = .spice
    @Published private(set) var selectedGPU: DisplayControlGPU?
    @Published private(set) var busy = false
    @Published private(set) var embeddedBusy = false
    @Published private(set) var audioBusy = false
    @Published private(set) var microphonePassthroughEnabled = false
    @Published private(set) var message: String?

    private let service: DisplayControlService
    private let machine: MachineService
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var audioBufferMs = 20

    init(paths: AppPaths, machine: MachineService? = nil) {
        self.service = DisplayControlService(paths: paths)
        self.machine = machine ?? MachineService(paths: paths)
        refreshAudioBridgeStatus()
    }

    var externalPrimaryActive: Bool {
        activeSessionID != nil
    }

    var activeSession: DisplaySession? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }

    var statusTitle: String {
        if busy {
            return "Working"
        }
        if let session = activeSession {
            return "External \(session.display)"
        }
        return "SPICE"
    }

    func refresh() {
        guard !busy, !embeddedBusy else { return }
        guard machine.currentPid() != nil else {
            clearRuntimeState()
            return
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            await refreshNow(refreshGeneration: generation)
        }
    }

    func clearRuntimeState(message: String? = nil) {
        cancelRefresh()
        gpus = []
        sessions = []
        activeSessionID = nil
        selectedGPU = nil
        mode = .spice
        self.message = message
    }

    func switchToSpice() {
        guard confirmModeSwitch("Switch to PEGPU GUI?") else { return }
        perform {
            try await self.service.switchToSpice()
        }
    }

    func switchToExternalPrimary(gpu: DisplayControlGPU) {
        guard confirmModeSwitch("Switch to \(gpu.name)?") else { return }
        perform {
            try await self.service.switchToExternalPrimary(gpu: gpu)
        }
    }

    func startSession(_ session: DisplaySession) {
        guard machine.currentPid() != nil else {
            clearRuntimeState()
            return
        }
        perform(postReconnect: false) {
            try await self.service.startSession(session)
        }
    }

    func enterSession(_ session: DisplaySession) {
        guard machine.currentPid() != nil else {
            clearRuntimeState()
            return
        }
        perform(postReconnect: false) {
            try await self.service.enterSession(session)
        }
    }

    func releaseSession() {
        guard !busy else { return }
        guard machine.currentPid() != nil else {
            clearRuntimeState()
            return
        }
        cancelRefresh()
        busy = true
        message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await self.service.releaseSession()
                message = nil
            } catch {
                message = String(describing: error)
            }
            await refreshSessionsOnly()
        }
    }

    func activateSessionForCapture(_ session: DisplaySession) async -> Bool {
        guard !busy else { return false }
        guard machine.currentPid() != nil else {
            clearRuntimeState()
            return false
        }
        cancelRefresh()
        busy = true
        message = nil
        defer { busy = false }
        return await activateSessionForCaptureLocked(session)
    }

    func activateOrderedSessionForCapture(number: Int) async -> Bool {
        guard !busy else { return false }
        guard machine.currentPid() != nil else {
            clearRuntimeState()
            return false
        }
        cancelRefresh()
        busy = true
        message = nil
        defer { busy = false }

        if sessions.isEmpty {
            await refreshSessionsOnly()
        }
        guard number > 0, sessions.indices.contains(number - 1) else {
            message = "External display shortcut has no matching GPU."
            return false
        }
        return await activateSessionForCaptureLocked(sessions[number - 1])
    }

    func releaseSessionForCapture() async {
        var waits = 0
        while busy, machine.currentPid() != nil, waits < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waits += 1
        }
        guard machine.currentPid() != nil else {
            clearRuntimeState()
            return
        }
        cancelRefresh()
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await service.releaseSession()
            message = nil
        } catch {
            message = String(describing: error)
        }
        await refreshSessionsOnly()
    }

    func stopSession(_ session: DisplaySession) {
        guard machine.currentPid() != nil else {
            clearRuntimeState()
            return
        }
        perform(postReconnect: false) {
            try await self.service.stopSession(session)
        }
    }

    func refreshOutputs(_ session: DisplaySession) {
        guard machine.currentPid() != nil else {
            clearRuntimeState()
            return
        }
        perform(postReconnect: false) {
            try await self.service.refreshOutputs(session)
        }
    }

    func reloadSession(_ session: DisplaySession) {
        guard machine.currentPid() != nil else {
            clearRuntimeState()
            return
        }
        perform(postReconnect: false) {
            try await self.service.reloadSession(session)
        }
    }

    func enterOrderedSession(number: Int) {
        guard number > 0, sessions.indices.contains(number - 1) else { return }
        let session = sessions[number - 1]
        if session.running {
            enterSession(session)
        } else {
            startSession(session)
        }
    }

    func reload() {
        guard machine.currentPid() != nil else {
            clearRuntimeState()
            return
        }
        performEmbedded {
            try await self.service.reload()
        }
    }

    func refreshAudioBridgeStatus() {
        let status = machine.audioBridgeStatus()
        microphonePassthroughEnabled = status.running && status.microphoneEnabled
        if status.bufferMs > 0 {
            audioBufferMs = status.bufferMs
        }
    }

    func toggleMicrophonePassthrough() {
        guard !audioBusy else { return }
        let requestedState = !microphonePassthroughEnabled
        audioBusy = true
        message = nil
        Task { @MainActor in
            defer { audioBusy = false }
            do {
                let status = try await machine.startAudioBridge(
                    microphoneEnabled: requestedState,
                    bufferMs: audioBufferMs
                )
                microphonePassthroughEnabled = status.running && status.microphoneEnabled
                if status.bufferMs > 0 {
                    audioBufferMs = status.bufferMs
                }
                message = nil
            } catch {
                refreshAudioBridgeStatus()
                message = String(describing: error)
            }
        }
    }

    private func perform(postReconnect: Bool = true, _ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        cancelRefresh()
        busy = true
        message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await action()
                if postReconnect {
                    await refreshNow()
                    NotificationCenter.default.post(name: .pegpuReconnectDisplay, object: self)
                } else {
                    await refreshSessionsOnly()
                }
            } catch {
                message = String(describing: error)
            }
        }
    }

    private func performEmbedded(_ action: @escaping () async throws -> Void) {
        guard !embeddedBusy else { return }
        cancelRefresh()
        embeddedBusy = true
        message = nil
        Task { @MainActor in
            defer { embeddedBusy = false }
            do {
                try await action()
                await refreshNow()
                NotificationCenter.default.post(name: .pegpuReconnectDisplay, object: self)
            } catch {
                message = String(describing: error)
            }
        }
    }

    private func cancelRefresh() {
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func activateSessionForCaptureLocked(_ requestedSession: DisplaySession) async -> Bool {
        do {
            var session = sessions.first { $0.id == requestedSession.id } ?? requestedSession
            if !session.running {
                try await service.startSession(session)
                await refreshSessionsOnly()
                session = sessions.first { $0.id == requestedSession.id } ?? session
            }
            try await service.enterSession(session)
            await refreshSessionsOnly()
            guard activeSessionID != nil else {
                message = "External display session did not become active."
                return false
            }
            message = nil
            return true
        } catch {
            message = String(describing: error)
            await refreshSessionsOnly()
            return false
        }
    }

    private func refreshSessionsOnly() async {
        guard machine.currentPid() != nil else {
            clearRuntimeState()
            return
        }
        do {
            let sessionsPayload = try await service.sessions()
            sessions = sessionsPayload.sessions.filter(\.valid)
            activeSessionID = sessionsPayload.active == "macos" ? nil : sessionsPayload.active
            gpus = sessions.map(\.gpu)
            message = nil
        } catch {
            message = String(describing: error)
        }
    }

    private func refreshNow(refreshGeneration expectedGeneration: Int? = nil) async {
        guard machine.currentPid() != nil else {
            guard expectedGeneration == nil || expectedGeneration == refreshGeneration else { return }
            clearRuntimeState()
            return
        }
        do {
            let status = try await service.status()
            let sessionsPayload = try await service.sessions()
            guard expectedGeneration == nil || expectedGeneration == refreshGeneration else { return }
            mode = status.mode
            selectedGPU = status.selectedGPU
            sessions = sessionsPayload.sessions.filter(\.valid)
            activeSessionID = sessionsPayload.active == "macos" ? nil : sessionsPayload.active
            gpus = sessions.map(\.gpu)
            message = nil
        } catch {
            guard machine.currentPid() != nil else {
                guard expectedGeneration == nil || expectedGeneration == refreshGeneration else { return }
                clearRuntimeState()
                return
            }
            do {
                let gpuList = try await service.listGPUs()
                guard expectedGeneration == nil || expectedGeneration == refreshGeneration else { return }
                gpus = gpuList
                sessions = gpuList.map {
                    DisplaySession(
                        id: "gpu-\($0.bdf.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-"))",
                        index: $0.index,
                        name: $0.name,
                        bdf: $0.bdf,
                        display: ":\(10 + (Int($0.index) ?? 0))",
                        state: "unknown",
                        active: false,
                        valid: $0.valid,
                        outputs: []
                    )
                }
                activeSessionID = nil
                message = String(describing: error)
            } catch {
                guard expectedGeneration == nil || expectedGeneration == refreshGeneration else { return }
                message = String(describing: error)
            }
        }
    }

    private func confirmModeSwitch(_ title: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = "This restarts only the Linux graphical session. The VM runtime, SSH, and background compute stay running."
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
