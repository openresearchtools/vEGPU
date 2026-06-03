import AppKit
import Foundation
import vEGPUCore

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
        try? await prepareDisplayHelper()
        let output = try await ssh.ssh("/usr/local/bin/vegpu-display-control status --json", timeout: 10)
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
            try await prepareDisplayHelper()
            let output = try await ssh.ssh("/usr/local/bin/vegpu-display-control list-gpus --json", timeout: 10)
            let payload = try JSONDecoder().decode(DisplayControlGPUListPayload.self, from: Data(output.utf8))
            return payload.gpus.filter { $0.valid }
        } catch {
            return try await listGPUsDirectly()
        }
    }

    func sessions() async throws -> DisplaySessionsPayload {
        try await prepareDisplayHelper()
        let output = try await ssh.ssh("/usr/local/bin/vegpu-display-control sessions --json", timeout: 15)
        return try JSONDecoder().decode(DisplaySessionsPayload.self, from: Data(output.utf8))
    }

    func startSession(_ session: DisplaySession) async throws {
        try await prepareDisplayHelper(force: true)
        let command = "/usr/local/bin/vegpu-display-control session-start \(shellQuote(session.bdf)) \(shellQuote(session.index))"
        _ = try await ssh.ssh(command, timeout: 45)
    }

    func enterSession(_ session: DisplaySession) async throws {
        try await prepareDisplayHelper()
        if !session.running {
            try await startSession(session)
        }
        let command = "/usr/local/bin/vegpu-display-control session-enter \(shellQuote(session.id))"
        _ = try await ssh.ssh(command, timeout: 20)
    }

    func releaseSession() async throws {
        try await prepareDisplayHelper()
        _ = try await ssh.ssh("/usr/local/bin/vegpu-display-control session-release", timeout: 20)
    }

    func stopSession(_ session: DisplaySession) async throws {
        try await prepareDisplayHelper(force: true)
        let command = "/usr/local/bin/vegpu-display-control session-stop \(shellQuote(session.id))"
        _ = try await ssh.ssh(command, timeout: 30)
    }

    func refreshOutputs(_ session: DisplaySession) async throws {
        try await prepareDisplayHelper()
        let command = "/usr/local/bin/vegpu-display-control session-outputs \(shellQuote(session.id))"
        _ = try await ssh.ssh(command, timeout: 15)
    }

    func rescanSessionDisplays(_ session: DisplaySession) async throws {
        try await prepareDisplayHelper(force: true)
        let command = "/usr/local/bin/vegpu-display-control session-rescan \(shellQuote(session.id))"
        _ = try await ssh.ssh(command, timeout: 30)
    }

    func restartSession(_ session: DisplaySession) async throws {
        try await prepareDisplayHelper(force: true)
        let command = "/usr/local/bin/vegpu-display-control session-restart \(shellQuote(session.id))"
        _ = try await ssh.ssh(command, timeout: 60)
    }

    func switchToExternalPrimary(gpu: DisplayControlGPU) async throws {
        try await prepareDisplayHelper(force: true)
        let command = "/usr/local/bin/vegpu-display-control external-primary \(shellQuote(gpu.bdf)) \(shellQuote(gpu.index))"
        _ = try await ssh.ssh(command, timeout: 45)
    }

    func switchToSpice() async throws {
        try await prepareDisplayHelper(force: true)
        _ = try await ssh.ssh("/usr/local/bin/vegpu-display-control spice", timeout: 45)
    }

    func reload() async throws {
        try await prepareDisplayHelper(force: true)
        _ = try await ssh.ssh("/usr/local/bin/vegpu-display-control reload", timeout: 45)
    }

    private func prepareDisplayHelper(force: Bool = false) async throws {
        guard force || !helperPrepared else { return }

        let source = paths.resources.appendingPathComponent("Guest/gui-ensure.sh")
        let customizationSource = paths.resources.appendingPathComponent("Guest/customization.sh")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RuntimeError.message("Bundled GUI helper is missing: \(source.path)")
        }
        guard FileManager.default.fileExists(atPath: customizationSource.path) else {
            throw RuntimeError.message("Bundled GUI customization helper is missing: \(customizationSource.path)")
        }
        let remote = "/tmp/vegpu-gui-ensure-\(UUID().uuidString).sh"
        let customizationRemote = "/tmp/vegpu-customization-\(UUID().uuidString).sh"
        try await ssh.scpToGuest(localPath: source.path, remotePath: remote)
        try await ssh.scpToGuest(localPath: customizationSource.path, remotePath: customizationRemote)
        let config = MachineConfigStore(paths: paths).load()
        let guiPrefs = [
            "VEGPU_GUI_RETINA=\(config.guiRetina ? "1" : "0")",
            "VEGPU_GUI_DENSITY=\(shellQuote(config.guiDensity.rawValue))",
            "VEGPU_GUI_APPEARANCE=\(shellQuote(config.guiAppearance.rawValue))"
        ].joined(separator: " ")
        let command = [
            "sudo -n install -d /usr/local/libexec/vegpu",
            "sudo -n install -m 0755 \(shellQuote(customizationRemote)) /usr/local/libexec/vegpu/customization.sh",
            "sudo -n install -m 0755 \(shellQuote(remote)) /usr/local/sbin/vegpu-gui-ensure.sh",
            "sudo -n env \(guiPrefs) /usr/local/sbin/vegpu-gui-ensure.sh --install-display-control-only",
            "rm -f \(shellQuote(remote)) \(shellQuote(customizationRemote))"
        ].joined(separator: " && ")
        _ = try await ssh.ssh(command, timeout: 30)
        helperPrepared = true
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
    @Published private(set) var audioBusy = false
    @Published private(set) var microphonePassthroughEnabled = false
    @Published private(set) var message: String?

    private let service: DisplayControlService
    private let machine: MachineService
    private var refreshTask: Task<Void, Never>?
    private var audioBufferMs = 20
    private var refreshGeneration = 0

    init(paths: AppPaths, machine: MachineService? = nil) {
        self.service = DisplayControlService(paths: paths)
        self.machine = machine ?? MachineService(paths: paths)
        refreshAudioBridgeStatus()
    }

    var externalPrimaryActive: Bool {
        activeSessionID != nil
    }

    var statusTitle: String {
        if busy {
            return "Working"
        }
        if let activeSessionID,
           let session = sessions.first(where: { $0.id == activeSessionID }) {
            return "External \(session.display)"
        }
        let runningCount = sessions.filter { $0.running }.count
        if runningCount > 0 {
            return runningCount == 1 ? "1 External Session Running" : "\(runningCount) External Sessions Running"
        }
        return "SPICE"
    }

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            await refreshNow(generation: generation)
        }
    }

    func switchToSpice() {
        guard confirmModeSwitch("Switch to vEGPU GUI?") else { return }
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
        perform(postReconnect: false) {
            try await self.service.startSession(session)
        }
    }

    func enterSession(_ session: DisplaySession) {
        perform(postReconnect: false) {
            try await self.service.enterSession(session)
            await MainActor.run {
                self.activeSessionID = session.id
            }
        }
    }

    func releaseSession() {
        busy = true
        message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await self.service.releaseSession()
                activeSessionID = nil
                message = nil
                NotificationCenter.default.post(name: .vegpuReconnectDisplay, object: self)
            } catch {
                message = String(describing: error)
            }
            await refreshSessionsOnly()
        }
    }

    func stopSession(_ session: DisplaySession) {
        perform(postReconnect: false) {
            try await self.service.stopSession(session)
        }
    }

    func refreshOutputs(_ session: DisplaySession) {
        perform(postReconnect: false) {
            try await self.service.refreshOutputs(session)
        }
    }

    func rescanSessionDisplays(_ session: DisplaySession) {
        perform(postReconnect: false) {
            try await self.service.rescanSessionDisplays(session)
        }
    }

    func restartSession(_ session: DisplaySession) {
        guard confirmSessionRestart(session) else { return }
        perform(postReconnect: false) {
            try await self.service.restartSession(session)
        }
    }

    func enterOrderedSession(number: Int) {
        guard number > 0 else { return }
        if sessions.indices.contains(number - 1) {
            enterSession(sessions[number - 1])
            return
        }
        Task { @MainActor in
            refreshGeneration += 1
            let generation = refreshGeneration
            await refreshNow(generation: generation)
            guard self.sessions.indices.contains(number - 1) else { return }
            self.enterSession(self.sessions[number - 1])
        }
    }

    func handleShortcutDigit(_ digit: Int) {
        guard (1...9).contains(digit) else { return }
        if digit == 1 {
            releaseSession()
        } else {
            enterOrderedSession(number: digit - 1)
        }
    }

    func reload() {
        perform {
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
        busy = true
        message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await action()
                if postReconnect {
                    refreshGeneration += 1
                    await refreshNow(generation: refreshGeneration)
                    NotificationCenter.default.post(name: .vegpuReconnectDisplay, object: self)
                } else {
                    await refreshSessionsOnly()
                }
            } catch {
                message = String(describing: error)
            }
        }
    }

    private func refreshSessionsOnly() async {
        do {
            let sessionsPayload = try await service.sessions()
            apply(sessionsPayload: sessionsPayload)
            message = nil
        } catch {
            message = String(describing: error)
        }
    }

    private func refreshNow(generation: Int? = nil) async {
        if let generation, generation != refreshGeneration {
            return
        }
        var sessionsLoaded = false
        do {
            let sessionsPayload = try await service.sessions()
            if let generation, generation != refreshGeneration {
                return
            }
            apply(sessionsPayload: sessionsPayload)
            sessionsLoaded = true
            message = nil
        } catch {
            do {
                let gpuList = try await service.listGPUs()
                if let generation, generation != refreshGeneration {
                    return
                }
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
                if let generation, generation != refreshGeneration {
                    return
                }
                message = String(describing: error)
            }
        }

        do {
            let status = try await service.status()
            if let generation, generation != refreshGeneration {
                return
            }
            mode = status.mode
            selectedGPU = status.selectedGPU
            if sessionsLoaded {
                message = nil
            }
        } catch {
            if let generation, generation != refreshGeneration {
                return
            }
            if !sessionsLoaded || sessions.isEmpty {
                message = String(describing: error)
            } else {
                message = nil
            }
        }
    }

    private func apply(sessionsPayload: DisplaySessionsPayload) {
        sessions = sessionsPayload.sessions.filter { $0.valid }
        activeSessionID = sessionsPayload.active == "macos" ? nil : sessionsPayload.active
        gpus = sessions.map(\.gpu)
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

    private func confirmSessionRestart(_ session: DisplaySession) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restart \(session.display) \(session.name)?"
        alert.informativeText = "This restarts only this GPU display session. Other GPU sessions, SSH, the VM runtime, and background compute stay running. Windows on this GPU display session will close."
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
