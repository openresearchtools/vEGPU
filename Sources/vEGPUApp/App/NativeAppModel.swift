import Foundation
import SwiftUI
import AppKit
import vEGPUCore

@MainActor
final class NativeAppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case runtime = "Runtime"
        case files = "Files"
        case gui = "GUI"
        case externalDisplays = "External Displays"
        case models = "Models"
        case chat = "Chat"

        var id: String { rawValue }
    }

    enum Tab: Hashable, Identifiable {
        case section(Section)
        case webShortcut(UUID)

        var id: String {
            switch self {
            case let .section(section): return "section:\(section.id)"
            case let .webShortcut(id): return "web:\(id.uuidString)"
            }
        }
    }

    enum RuntimePane: String, CaseIterable, Identifiable {
        case terminal = "Terminal"
        case output = "Output"
        case manifest = "Manifest"

        var id: String { rawValue }
    }

    var selectedSection: Section = .runtime
    @Published var runtimeLaunchMode: RuntimeLaunchMode = .headless
    @Published var guiRetina = true
    var runtimePane: RuntimePane {
        get { runtimeScreen.navigation.runtimePane }
        set { setIfChanged(runtimeScreen.navigation, \.runtimePane, newValue) }
    }
    var sidebarCollapsed: Bool {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: PreferencesKeys.sidebarCollapsed) }
    }
    @Published var shortcuts: [WebShortcut] {
        didSet {
            if let data = try? JSONEncoder().encode(shortcuts) {
                UserDefaults.standard.set(data, forKey: PreferencesKeys.webShortcuts)
            }
        }
    }
    @Published var showingAddWebUI = false
    @Published var showingCreateRoutingRoute = false
    @Published var showingManageRoutingRoutes = false
    var runtimeStatus: String { sidebarMonitor.runtimeStatus }
    var runtimeDetail: String { sidebarMonitor.runtimeDetail }
    var runtimeMetric: String { sidebarMonitor.runtimeMetric }
    var runtimeState: String { sidebarMonitor.runtimeState }
    var hostMetrics: MetricGroup { sidebarMonitor.hostMetrics }
    var vmMetrics: MetricGroup { sidebarMonitor.vmMetrics }
    var powerMetric: PowerMetric { sidebarMonitor.powerMetric }
    var pcieDriver: DriverCardState { get { runtimeScreen.drivers.pcieDriver } set { setIfChanged(runtimeScreen.drivers, \.pcieDriver, newValue) } }
    var linuxDriver: DriverCardState { get { runtimeScreen.drivers.linuxDriver } set { setIfChanged(runtimeScreen.drivers, \.linuxDriver, newValue) } }
    var nvidiaDriver: DriverCardState { get { runtimeScreen.drivers.nvidiaDriver } set { setIfChanged(runtimeScreen.drivers, \.nvidiaDriver, newValue) } }
    var nvidiaGpus: [NvidiaGpuMetric] { get { runtimeScreen.drivers.nvidiaGpus } set { setIfChanged(runtimeScreen.drivers, \.nvidiaGpus, newValue) } }
    var nvidiaOutput: String { get { runtimeScreen.drivers.nvidiaOutput } set { setIfChanged(runtimeScreen.drivers, \.nvidiaOutput, newValue) } }
    var manifestSummary: String { get { runtimeScreen.manifest.manifestSummary } set { setIfChanged(runtimeScreen.manifest, \.manifestSummary, newValue) } }
    var outputLines: [String] { get { runtimeScreen.log.outputLines } set { setIfChanged(runtimeScreen.log, \.outputLines, newValue) } }
    var currentProgress: ProgressEvent? { get { runtimeScreen.log.currentProgress } set { runtimeScreen.log.currentProgress = newValue } }
    var commandState: String { get { runtimeScreen.log.commandState } set { setIfChanged(runtimeScreen.log, \.commandState, newValue) } }
    var linuxPassword: String { get { runtimeScreen.terminal.linuxPassword } set { setIfChanged(runtimeScreen.terminal, \.linuxPassword, newValue) } }
    var webHelperStatus = "Stopped"
    var terminalConnected: Bool { get { runtimeScreen.terminal.terminalConnected } set { setIfChanged(runtimeScreen.terminal, \.terminalConnected, newValue) } }
    var terminalSessionID: UUID { get { runtimeScreen.terminal.terminalSessionID } set { runtimeScreen.terminal.terminalSessionID = newValue } }
    var terminalInput: TerminalInput? { get { runtimeScreen.terminal.terminalInput } set { runtimeScreen.terminal.terminalInput = newValue } }
    var showingNvidiaInstallConfirm: Bool { get { runtimeScreen.drivers.showingNvidiaInstallConfirm } set { setIfChanged(runtimeScreen.drivers, \.showingNvidiaInstallConfirm, newValue) } }

    let paths: AppPaths
    let sidebarMonitor: SidebarMonitorState
    let runtimeScreen: RuntimeScreenState
    let configStore: MachineConfigStore
    let progress: ProgressCenter
    let machineService: MachineService
    let llmsRuntime: LlmsRuntimeService
    let nativeBridge: NativeBridgeService
    let goHelperSupervisor: GoHelperSupervisor
    let localProxySupervisor: LocalProxySupervisor
    let hostSetupService: HostSetupService
    let metricsService: MetricsService
    let vfioService: VfioService
    let displayControlMenu: DisplayControlMenuModel
    let spiceSession: SpiceSessionController
    let updates: AppUpdateService
    private var pollingStarted = false
    private var backgroundServicesStarted = false
    private var statusRefreshInFlight = false
    private var metricsRefreshInFlight = false
    private var driverRefreshInFlight = false
    private var activeSection: Section = .runtime
    private var outputTextRemainder = ""

    init(paths: AppPaths = AppPaths()) {
        self.paths = paths
        self.sidebarMonitor = SidebarMonitorState(logoURL: paths.resources.appendingPathComponent("Assets/vEGPU-logo-transparent.png"))
        self.runtimeScreen = RuntimeScreenState()
        let progress = ProgressCenter()
        self.progress = progress
        self.configStore = MachineConfigStore(paths: paths)
        let loadedConfig = self.configStore.load()
        self.runtimeLaunchMode = loadedConfig.launchMode
        self.guiRetina = loadedConfig.guiRetina
        let machine = MachineService(paths: paths, progress: progress)
        self.machineService = machine
        let files = MachineFiles(machineDir: paths.machine)
        self.spiceSession = SpiceSessionController(socketURL: files.spiceSocket, paths: paths)
        self.displayControlMenu = DisplayControlMenuModel(paths: paths, machine: machine)
        self.llmsRuntime = LlmsRuntimeService(paths: paths, machine: machine)
        self.nativeBridge = NativeBridgeService(runtime: llmsRuntime)
        self.goHelperSupervisor = GoHelperSupervisor(paths: paths, bridge: nativeBridge)
        self.localProxySupervisor = LocalProxySupervisor(paths: paths)
        self.hostSetupService = HostSetupService(paths: paths, progress: progress)
        let networkStore = NetworkStateStore(paths: paths)
        let ssh = SSHClient(paths: paths, networkStore: networkStore, progress: progress)
        self.metricsService = MetricsService(ssh: ssh, machinePid: { machine.currentPid() })
        self.vfioService = VfioService()
        self.updates = AppUpdateService()
        self.sidebarCollapsed = UserDefaults.standard.bool(forKey: PreferencesKeys.sidebarCollapsed)
        if let data = UserDefaults.standard.data(forKey: PreferencesKeys.webShortcuts),
           let parsed = try? JSONDecoder().decode([WebShortcut].self, from: data) {
            self.shortcuts = parsed
        } else {
            self.shortcuts = []
        }
        progress.observe { [weak self] (event: ProgressEvent) in
            Task { @MainActor in
                guard let self else { return }
                self.currentProgress = event
                self.appendOutput(Self.progressLine(event))
            }
        }
    }

    func refreshStatus() {
        refreshRuntimeSnapshot(loadManifest: true)
        webHelperStatus = goHelperSupervisor.status
        refreshDriverCards()
        refreshMetrics()
    }

    func checkForUpdates(silent: Bool = false) {
        Task {
            await updates.checkForUpdates(silent: silent)
            if !silent {
                appendOutput("[info] \(updates.statusText)")
            }
        }
    }

    func togglePrereleaseUpdates() {
        updates.togglePrerelease()
        appendOutput("[info] Update channel: \(updates.channel.title)")
        checkForUpdates(silent: false)
    }

    func startPolling() {
        guard !pollingStarted else { return }
        pollingStarted = true
        Task {
            var displayPollTick = 0
            while !Task.isCancelled {
                refreshRuntimeSnapshot(loadManifest: false)
                refreshMetrics()
                displayPollTick += 1
                if runtimeLaunchMode == .gui,
                   runtimeState == "running",
                   displayPollTick >= 2 {
                    displayPollTick = 0
                    displayControlMenu.refresh()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func setActiveSection(_ section: Section) {
        activeSection = section
    }

    func setActiveTab(_ tab: Tab) {
        if case let .section(section) = tab {
            setActiveSection(section)
        }
    }

    func showCreateRoutingRoute() {
        showingCreateRoutingRoute = true
    }

    func showAddWebUI() {
        showingAddWebUI = true
    }

    func showManageRoutingRoutes() {
        showingManageRoutingRoutes = true
    }

    func reloadWebTab(_ tab: Tab) {
        NotificationCenter.default.post(name: .vegpuReloadWebTab, object: self, userInfo: ["tabID": tab.id])
    }

    func removeWebShortcut(id: UUID) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        let removed = shortcuts.remove(at: index)
        appendOutput("[info] Web UI tab removed: \(removed.title)")
    }

    func defaultWebUIHost() -> String {
        NetworkStateStore(paths: paths).read().guestHost
    }

    func addDirectWebUI(title: String, host: String, port: Int) throws {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            throw RuntimeError.message("Type a Web UI tab name.")
        }
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else {
            throw RuntimeError.message("Type the VM address, for example \(VMNet.guestIP).")
        }
        guard cleanHost.range(of: #"[/:?#]"#, options: .regularExpression) == nil else {
            throw RuntimeError.message("Type only the VM address, for example \(VMNet.guestIP). Do not include http:// or a port.")
        }
        guard var components = URLComponents(string: "http://\(cleanHost)") else {
            throw RuntimeError.message("Invalid VM address: \(cleanHost)")
        }
        components.port = port
        components.path = "/"
        guard let url = components.url else {
            throw RuntimeError.message("Invalid Web UI address: \(cleanHost):\(port)")
        }
        upsertWebShortcut(title: cleanTitle, url: url)
        appendOutput("[success] Web UI tab added: \(cleanTitle) -> \(url.absoluteString)")
    }

    func routingRoutes() -> [HostForward] {
        let networkStore = NetworkStateStore(paths: paths)
        let ssh = SSHClient(paths: paths, networkStore: networkStore, progress: progress)
        return PortForwardService(paths: paths, networkStore: networkStore, ssh: ssh).readHostForwards()
    }

    func deleteRoutingRoute(_ forward: HostForward) throws {
        let networkStore = NetworkStateStore(paths: paths)
        let ssh = SSHClient(paths: paths, networkStore: networkStore, progress: progress)
        try PortForwardService(paths: paths, networkStore: networkStore, ssh: ssh)
            .deleteHostForward(forward)
        appendOutput("[info] Route removed: \(Self.routingRouteTitle(forward))")
    }

    func createRoutingRoute(direction: PortForwardDirection, vmPort: Int, localPort: Int, useUDP: Bool, webUITitle: String?) async throws {
        let proto = useUDP ? "udp" : "tcp"
        let networkStore = NetworkStateStore(paths: paths)
        let ssh = SSHClient(paths: paths, networkStore: networkStore, progress: progress)
        let portForwardService = PortForwardService(paths: paths, networkStore: networkStore, ssh: ssh)
        let forward = HostForward(
            macHost: networkStore.read().macHost,
            macPort: localPort,
            vmPort: vmPort,
            protocol: proto,
            direction: direction
        )
        if let existing = portForwardService.readHostForwards().first(where: { $0.listenerKey == forward.listenerKey && $0 != forward }) {
            throw RuntimeError.message("\(Self.routeListenerDescription(forward)) already belongs to \(Self.routingRouteTitle(existing)). Choose a different route port.")
        }
        try portForwardService.saveHostForwards([forward])
        try localProxySupervisor.start()

        let suffix = useUDP ? "/udp" : ""
        if direction == .vmToMac, machineService.currentPid() != nil {
            do {
                try await portForwardService.applyGuestPrivatePorts([forward])
            } catch {
                appendOutput("[warning] Route saved, but Linux firewall update is waiting: \(firstLine(String(describing: error))). Run Doctor after the VM is ready.")
            }
        } else if direction == .vmToMac {
            appendOutput("[info] Route saved. It will be applied inside Linux the next time the runtime starts.")
        }

        if let webUITitle, !webUITitle.isEmpty {
            upsertWebShortcut(title: webUITitle, url: URL(string: "http://127.0.0.1:\(localPort)/")!)
        }
        appendOutput("[success] Route ready: \(Self.routingRouteTitle(forward))\(direction == .macToVM ? " - inside VM use 172.29.253.1:\(vmPort)\(suffix)" : "")")
    }

    func startBackgroundServices() {
        guard !backgroundServicesStarted else { return }
        backgroundServicesStarted = true
        Task {
            do {
                try localProxySupervisor.start()
                try await goHelperSupervisor.start()
                webHelperStatus = goHelperSupervisor.status
                await hostSetupService.ensureFirstRunHostSetup()
            } catch {
                appendOutput("[error] Background helper failed: \(error)")
            }
        }
    }

    func startRuntime(config: MachineConfig) {
        runtimePane = .output
        Task {
            await runAction("start") {
                let saved = try await self.machineService.saveConfig(config)
                await MainActor.run {
                    self.runtimeLaunchMode = saved.launchMode
                    self.guiRetina = saved.guiRetina
                }
                try await self.machineService.startMachine()
                await MainActor.run {
                    self.displayControlMenu.refresh()
                    if saved.launchMode == .gui {
                        NotificationCenter.default.post(name: .vegpuReconnectDisplay, object: self)
                    }
                }
            }
        }
    }

    func saveRuntimeConfig(_ config: MachineConfig) {
        runtimePane = .output
        Task {
            await runAction("save-config") {
                let saved = try await self.machineService.saveConfig(config)
                await MainActor.run {
                    self.runtimeLaunchMode = saved.launchMode
                    self.guiRetina = saved.guiRetina
                    self.appendOutput("[info] VM defaults saved: \(saved.cpuMode == .auto ? "Auto" : "\(saved.cpuCount)") CPU / \(saved.memoryMiB) MiB / \(saved.launchMode.label) / Retina \(saved.guiRetina ? "on" : "off") / \(saved.guiResolutionMode.rawValue) / \(saved.guiDensity.rawValue) density / \(saved.guiAppearance.rawValue) appearance / share \(saved.shareRoot) / Linux home \(saved.linuxHomeMountPath). CPU/RAM/mode apply on next runtime start; share changes apply live when the runtime is running.")
                }
            }
        }
    }

    func stopRuntime() {
        runtimePane = .output
        terminalConnected = false
        NotificationCenter.default.post(name: .vegpuRuntimeWillStop, object: self)
        Task {
            await runAction("stop") {
                try await self.machineService.stopMachine()
            }
        }
    }

    func resetRuntime(config: MachineConfig? = nil) {
        runtimePane = .output
        terminalConnected = false
        NotificationCenter.default.post(name: .vegpuRuntimeWillStop, object: self)
        Task {
            await runAction("reset") {
                if let config {
                    let saved = try await self.machineService.saveConfig(config)
                    await MainActor.run {
                        self.runtimeLaunchMode = saved.launchMode
                        self.guiRetina = saved.guiRetina
                    }
                }
                try await self.machineService.resetMachine()
                await MainActor.run {
                    self.displayControlMenu.refresh()
                    if self.runtimeLaunchMode == .gui {
                        NotificationCenter.default.post(name: .vegpuReconnectDisplay, object: self)
                    }
                }
            }
        }
    }

    func doctorRuntime() {
        runtimePane = .output
        Task {
            await runAction("doctor") {
                try await self.machineService.repairRunningMachine(reason: "manual doctor")
            }
        }
    }

    func repairFileShares() {
        Task {
            do {
                appendOutput("[info] Repairing file shares")
                try await machineService.repairRunningMachine(reason: "files tab")
                refreshStatus()
            } catch {
                appendOutput("[error] File share repair failed: \(error)")
                refreshStatus()
            }
        }
    }

    func repairAfterWake() {
        guard machineService.currentPid() != nil else { return }
        Task {
            do {
                appendOutput("[info] macOS wake detected; checking runtime networking and share")
                try await machineService.repairRunningMachine(reason: "macOS wake")
                refreshStatus()
            } catch {
                appendOutput("[error] Wake repair failed: \(error)")
                refreshStatus()
            }
        }
    }

    func clearOutput() {
        outputLines.removeAll()
        currentProgress = nil
        commandState = "idle"
    }

    func chooseShareRoot(current: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: normalizeShareRoot(current))
        panel.message = "Choose the Mac folder to share with the Linux runtime."
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func openTerminal() {
        guard runtimeState == "running" || runtimeState == "booting" else {
            runtimePane = .output
            appendOutput("[info] Start the runtime before opening the Linux SSH terminal.")
            return
        }
        runtimePane = .terminal
        terminalSessionID = UUID()
        terminalConnected = true
    }

    func closeTerminal() {
        terminalConnected = false
    }

    func copyLinuxPassword() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(linuxPassword, forType: .string)
    }

    func sendLinuxPassword() {
        guard terminalConnected else {
            appendOutput("[info] Open the Linux terminal before sending the password.")
            return
        }
        guard !linuxPassword.isEmpty else {
            appendOutput("[info] Linux password is not available yet.")
            return
        }
        terminalInput = TerminalInput(text: "\(linuxPassword)\n")
        appendOutput("[info] Linux password sent to the active terminal.")
    }

    func changeLinuxPassword(_ password: String) {
        runtimePane = .output
        Task {
            await runAction("change-linux-password") {
                let secrets = try await self.machineService.changeLinuxPassword(password)
                await MainActor.run {
                    self.linuxPassword = secrets.linuxPassword
                    self.appendOutput("[info] Linux password updated for user \(SSHClient.user).")
                }
            }
        }
    }

    func toggleMacOSDriver() {
        if pcieDriver.state == "ready" {
            uninstallMacOSDriver()
        } else {
            installMacOSDriver()
        }
    }

    private func installMacOSDriver() {
        runtimePane = .output
        pcieDriver = DriverCardState(
            title: VfioApp.displayName,
            status: "Installing",
            detail: "Submitting macOS DriverKit activation request.",
            state: "working",
            actionTitle: "Install Driver",
            actionEnabled: false
        )
        Task {
            await runAction("install-macos-driver") {
                let output = try await self.vfioService.activateDriver()
                let status = try await self.vfioService.driverStatus()
                await MainActor.run {
                    self.appendOutputText(output + "\n")
                    self.applyVfioDriverStatus(status)
                }
            }
        }
    }

    private func uninstallMacOSDriver() {
        runtimePane = .output
        pcieDriver = DriverCardState(
            title: VfioApp.displayName,
            status: "Uninstalling",
            detail: "Submitting macOS DriverKit deactivation request.",
            state: "working",
            actionTitle: "Uninstall Driver",
            actionEnabled: false
        )
        Task {
            await runAction("uninstall-macos-driver") {
                let output = try await self.vfioService.deactivateDriver()
                let status = try await self.vfioService.driverStatus()
                await MainActor.run {
                    self.appendOutputText(output + "\n")
                    self.applyVfioDriverStatus(status)
                }
            }
        }
    }

    func reinstallLinuxDriver() {
        runtimePane = .output
        Task {
            await runAction("reinstall-linux-driver") {
                let status = try await self.machineService.reinstallGuestDriver()
                await MainActor.run {
                    self.applyGuestDriverStatus(status)
                    self.appendOutput("[info] Linux guest DMA driver \(status.ready ? "ready" : "not ready"): \(status.detail)")
                }
            }
        }
    }

    func requestNvidiaInstall() {
        showingNvidiaInstallConfirm = true
    }

    func installNvidiaStack() {
        showingNvidiaInstallConfirm = false
        runtimePane = .output
        Task {
            await runAction("install-nvidia") {
                let status = try await self.machineService.installNvidiaStack { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        self?.appendOutputText(chunk)
                    }
                }
                let guestStatus = await self.machineService.guestDriverStatus()
                await MainActor.run {
                    self.flushOutputTextRemainder()
                    self.applyGuestDriverStatus(guestStatus)
                    self.applyNvidiaStatus(status)
                    self.appendOutput("[info] NVIDIA installer finished: \(status.summary.isEmpty ? status.state : status.summary)")
                }
            }
        }
    }

    func machineStatusText() async -> String {
        let status = await machineService.statusMachine()
        let normalized = Self.normalizeStatus(status)
        if let pid = status.pid {
            return "\(normalized) pid=\(pid)"
        }
        return normalized
    }

    func setStartRuntimeAtLogin(_ enabled: Bool) {
        do {
            var config = configStore.load()
            config.startRuntimeAtLogin = enabled
            _ = try configStore.save(config)
        } catch {
            appendOutput("[error] Could not save start-at-login setting: \(error)")
        }
    }

    func setGuiRetina(_ enabled: Bool) {
        do {
            var config = configStore.load()
            config.guiRetina = enabled
            let saved = try configStore.save(config)
            guiRetina = saved.guiRetina
        } catch {
            appendOutput("[error] Could not save GUI Retina setting: \(error)")
        }
    }

    func quitAndStopRuntime() async throws {
        if machineService.currentPid() != nil {
            await MainActor.run {
                NotificationCenter.default.post(name: .vegpuRuntimeWillStop, object: self)
            }
            try await machineService.stopMachine(timeout: 90)
        }
        localProxySupervisor.stop()
        goHelperSupervisor.stop()
        nativeBridge.stop()
    }

    func shutdownBackgroundServices() {
        localProxySupervisor.stop()
        goHelperSupervisor.stop()
        nativeBridge.stop()
    }

    func refreshDriverCards() {
        guard !driverRefreshInFlight else { return }
        driverRefreshInFlight = true
        Task {
            defer { driverRefreshInFlight = false }
            do {
                let status = try await vfioService.driverStatus()
                await MainActor.run {
                    applyVfioDriverStatus(status)
                }
            } catch {
                await MainActor.run {
                    pcieDriver = DriverCardState(title: VfioApp.displayName, status: "Unavailable", detail: firstLine(String(describing: error)), state: "unavailable", actionTitle: "Install Driver")
                }
            }

            let guestStatus = await machineService.guestDriverStatus()
            let nvidia = await metricsService.readNvidiaSmiStatus()
            await MainActor.run {
                applyGuestDriverStatus(guestStatus)
                applyNvidiaStatus(nvidia)
            }
        }
    }

    func refreshMetrics() {
        guard !metricsRefreshInFlight else { return }
        metricsRefreshInFlight = true
        Task {
            let payload = await metricsService.metrics()
            await MainActor.run {
                applyMetrics(payload.value)
                metricsRefreshInFlight = false
            }
        }
    }

    private func refreshRuntimeSnapshot(loadManifest: Bool) {
        guard !statusRefreshInFlight else { return }
        statusRefreshInFlight = true
        let paths = paths
        let machineService = machineService
        Task(priority: .utility) { [paths, machineService, loadManifest] in
            let status = await machineService.statusMachine()
            let manifest = loadManifest ? (try? ManifestStore(paths: paths).load()) : nil
            let password = machineService.linuxPassword() ?? ""
            applyRuntimeStatus(status)
            if loadManifest {
                manifestSummary = Self.manifestText(manifest)
            }
            linuxPassword = password
            webHelperStatus = goHelperSupervisor.status
            statusRefreshInFlight = false
        }
    }

    private func runAction(_ name: String, operation: @escaping () async throws -> Void) async {
        commandState = "running"
        appendOutput("$ vegpu machine \(name)")
        do {
            try await operation()
            flushOutputTextRemainder()
            appendOutput("[success] \(name) completed")
            commandState = "exit 0"
            refreshStatus()
        } catch {
            flushOutputTextRemainder()
            appendOutput("[error] \(name) failed: \(error)")
            commandState = "error"
            refreshStatus()
        }
    }

    private func appendOutput(_ line: String) {
        outputLines.append(line)
        if outputLines.count > 1_000 {
            outputLines.removeFirst(outputLines.count - 1_000)
        }
    }

    private func appendOutputText(_ text: String) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty else { return }
        let parts = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return }

        if parts.count == 1, !normalized.hasSuffix("\n") {
            outputTextRemainder += parts[0]
            return
        }

        var lines = parts
        lines[0] = outputTextRemainder + lines[0]
        outputTextRemainder = ""

        let hasTrailingNewline = normalized.hasSuffix("\n")
        let completeLines = hasTrailingNewline ? lines : Array(lines.dropLast())
        for line in completeLines {
            appendOutput(line)
        }
        if !hasTrailingNewline {
            outputTextRemainder = lines.last ?? ""
        }
    }

    private func flushOutputTextRemainder() {
        guard !outputTextRemainder.isEmpty else { return }
        appendOutput(outputTextRemainder)
        outputTextRemainder = ""
    }

    private func upsertWebShortcut(title: String, url: URL) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = shortcuts.firstIndex(where: { $0.url == url }) {
            shortcuts[index].title = cleanTitle
        } else {
            shortcuts.append(WebShortcut(title: cleanTitle, url: url))
        }
    }

    private func setIfChanged<Root: AnyObject, Value: Equatable>(_ root: Root, _ keyPath: ReferenceWritableKeyPath<Root, Value>, _ value: Value) {
        if root[keyPath: keyPath] != value {
            root[keyPath: keyPath] = value
        }
    }

    private func applyRuntimeStatus(_ status: MachineStatus) {
        let normalized = Self.normalizeStatus(status)
        let nextStatus: String
        let nextMetric: String
        let nextDetail: String
        switch normalized {
        case "running":
            nextStatus = "Running"
            nextMetric = "Ready"
            nextDetail = status.pid.map { "Backend online - PID \($0)" } ?? "Backend online"
        case "booting":
            nextStatus = "Starting"
            nextMetric = "Starting"
            nextDetail = status.pid.map { "Booting - PID \($0)" } ?? "Booting backend"
        case "stopped":
            nextStatus = "Stopped"
            nextMetric = "Stopped"
            nextDetail = "Backend VM is not running"
        default:
            nextStatus = "Needs attention"
            nextMetric = "Check logs"
            nextDetail = status.detail ?? status.state
        }
        sidebarMonitor.updateRuntime(status: nextStatus, detail: nextDetail, metric: nextMetric, state: normalized)
    }

    private func applyMetrics(_ metrics: [String: Any]) {
        let host = metrics["host"] as? [String: Any] ?? [:]
        let guest = metrics["guest"] as? [String: Any] ?? [:]
        let hostNetwork = host["network"] as? [String: Any]
        let guestNetwork = guest["network"] as? [String: Any]
        let hostDisk = host["disk"] as? [String: Any]
        let guestDisk = guest["disk"] as? [String: Any]
        let nvidia = metrics["nvidia"] as? [String: Any] ?? [:]
        let nvidiaGpus = nvidia["gpus"] as? [NvidiaGpuMetric] ?? []
        let hostGpuWidgets = Self.hostGpuWidgets(host["gpus"], host: host)
        let nvidiaGpuWidgets = nvidiaGpus.map(Self.nvidiaGpuWidget)

        let nextHost = MetricGroup(
            cpu: "CPU \(Self.formatPercent(host["cpuPercent"]))",
            ram: Self.memoryLine(prefix: "RAM", used: host["memoryUsedBytes"], total: host["memoryTotalBytes"], fallback: "RAM unavailable"),
            net: Self.networkLine(hostNetwork, fallback: "NET unavailable"),
            disk: Self.diskLine(hostDisk, includeLoad: false, fallback: "DISK unavailable"),
            gpu: Self.hostPowerLine(host),
            bar: Self.metricPercent(used: host["memoryUsedBytes"], total: host["memoryTotalBytes"])
        )
        let nextVM: MetricGroup
        if guest["state"] as? String == "ready" {
            nextVM = MetricGroup(
                cpu: "CPU \(Self.formatPercent(guest["cpuPercent"]))",
                ram: Self.memoryLine(prefix: "RAM", used: guest["memoryUsedBytes"], total: guest["memoryTotalBytes"], fallback: "RAM unavailable"),
                net: Self.networkLine(guestNetwork, fallback: "NET unavailable"),
                disk: Self.diskLine(guestDisk, includeLoad: true, fallback: "DISK unavailable"),
                gpu: nvidiaGpus.isEmpty ? "GPU none" : "\(nvidiaGpus.count) NVIDIA GPU",
                bar: Self.metricPercent(used: guest["memoryUsedBytes"], total: guest["memoryTotalBytes"])
            )
        } else {
            nextVM = MetricGroup(cpu: "CPU --%", ram: guest["detail"] as? String ?? "VM stopped", net: "NET stopped", disk: "DISK stopped", gpu: "GPU stopped", bar: 0)
        }
        let hostPower = host["powerW"] as? Double
        let nvidiaPower = nvidiaGpus.reduce(0) { $0 + ($1.powerW ?? 0) }
        let totalPower = (hostPower ?? 0) + nvidiaPower
        let nextPower = PowerMetric(
            total: totalPower > 0 ? Self.formatWatts(totalPower) : "-- W",
            detail: totalPower > 0 ? Self.powerDetail(host: host, nvidiaPower: nvidiaPower) : (host["powerDetail"] as? String ?? "Power unavailable"),
            percent: min(100, totalPower / 6)
        )
        sidebarMonitor.updateMetrics(host: nextHost, vm: nextVM, power: nextPower, hostGpus: hostGpuWidgets, nvidiaGpus: nvidiaGpuWidgets)
    }

    private func applyGuestDriverStatus(_ status: GuestDriverStatus) {
        linuxDriver = DriverCardState(
            title: "Linux Guest Driver",
            status: status.ready ? "Ready" : Self.linuxDriverLabel(status.state),
            detail: status.ready ? (status.detail.isEmpty ? "Installed and loaded" : status.detail) : Self.linuxDriverDetail(status),
            state: status.ready ? "ready" : status.state,
            actionTitle: status.ready ? nil : "Reinstall",
            actionEnabled: status.canReinstall
        )
    }

    private func applyVfioDriverStatus(_ status: VfioDriverStatus) {
        let active = status.active
        let needsApproval = status.needsUserApproval == true
        pcieDriver = DriverCardState(
            title: VfioApp.displayName,
            status: active ? "Ready" : (needsApproval ? "Approval needed" : "Not active"),
            detail: active ? "Installed and active" : (needsApproval ? "Approve in System Settings, then refresh." : "Use Install Driver to activate the macOS DriverKit extension."),
            state: active ? "ready" : (needsApproval ? "booting" : "not-ready"),
            actionTitle: active ? "Uninstall Driver" : "Install Driver"
        )
    }

    private func applyNvidiaStatus(_ status: NvidiaSmiStatus) {
        nvidiaDriver = DriverCardState(
            title: "GPU",
            status: status.available ? "Live" : Self.nvidiaLabel(status.state),
            detail: status.summary.isEmpty ? status.detail : status.summary,
            state: status.available ? "ready" : status.state,
            actionTitle: status.available ? nil : "Run Installer",
            actionEnabled: runtimeState != "stopped"
        )
        nvidiaOutput = status.available ? status.output : ""
        nvidiaGpus = status.available ? (status.gpus ?? []) : []
    }

    private static func routingRouteTitle(_ route: HostForward) -> String {
        let suffix = route.protocol == "udp" ? "/udp" : ""
        switch route.direction {
        case .vmToMac:
            return "VM:\(route.vmPort)\(suffix) -> Mac 127.0.0.1:\(route.macPort)\(suffix)"
        case .macToVM:
            return "Mac 127.0.0.1:\(route.macPort)\(suffix) -> VM 172.29.253.1:\(route.vmPort)\(suffix)"
        }
    }

    private static func routeListenerDescription(_ route: HostForward) -> String {
        let suffix = route.protocol == "udp" ? "/udp" : ""
        switch route.direction {
        case .vmToMac:
            return "Mac 127.0.0.1:\(route.macPort)\(suffix)"
        case .macToVM:
            return "VM 172.29.253.1:\(route.vmPort)\(suffix)"
        }
    }

    private static func normalizeStatus(_ status: MachineStatus) -> String {
        let text = status.state.lowercased()
        if text.contains("running") { return "running" }
        if text.contains("booting") || text.contains("starting") { return "booting" }
        if text.contains("stopped") { return "stopped" }
        return "error"
    }

    private static func manifestText(_ manifest: RuntimeManifest?) -> String {
        guard let manifest else { return "manifest unavailable" }
        return [
            "image: \(manifest.debian.name)",
            "manifest: \(manifest.id)",
            "kernel: \(manifest.kernel.version)",
            "driver: \(manifest.driver.version)",
            "packages: \(manifest.guestPackages.count) guest, \(manifest.kernel.packages.count) kernel, \(manifest.driver.prebuiltPackages.count + manifest.driver.dkmsPackages.count) driver"
        ].joined(separator: "\n")
    }

    private static func formatPercent(_ value: Any?) -> String {
        guard let number = value as? Double, number.isFinite else { return "--%" }
        return "\(Int(number.rounded()))%"
    }

    private static func memoryLine(prefix: String, used: Any?, total: Any?, fallback: String) -> String {
        guard let used = used as? Int64, let total = total as? Int64, total > 0 else { return fallback }
        return "\(prefix) \(formatBytes(used)) / \(formatBytes(total))"
    }

    private static func metricPercent(used: Any?, total: Any?) -> Double? {
        let usedValue = numericDouble(used)
        let totalValue = numericDouble(total)
        guard let usedValue, let totalValue, totalValue > 0 else { return nil }
        return max(0, min(100, (usedValue / totalValue) * 100))
    }

    private static func networkLine(_ network: [String: Any]?, fallback: String) -> String {
        guard let network else { return fallback }
        let rx = network["receiveBytesPerSecond"] as? Double
        let tx = network["transmitBytesPerSecond"] as? Double
        if rx == nil && tx == nil { return fallback }
        return "NET RX \(formatBytesPerSecond(rx ?? 0)) / TX \(formatBytesPerSecond(tx ?? 0))"
    }

    private static func diskLine(_ disk: [String: Any]?, includeLoad: Bool, fallback: String) -> String {
        guard let disk, let bytesPerSecond = numericDouble(disk["bytesPerSecond"]) else { return fallback }
        var line = "DISK \(formatBytesPerSecond(bytesPerSecond))"
        if includeLoad, let load = numericDouble(disk["loadPercent"]) {
            line += " / LOAD \(Int(load.rounded()))%"
        }
        return line
    }

    private static func hostGpuWidgets(_ value: Any?, host: [String: Any]) -> [GpuWidgetMetric] {
        guard let gpus = value as? [[String: Any]] else { return [] }
        return gpus.enumerated().map { offset, gpu in
            let name = gpu["name"] as? String ?? "Mac GPU"
            let util = gpu["utilizationPercent"] as? Double
            let usedMemory = gpu["memoryUsedBytes"] as? Double
            let allocatedMemory = gpu["memoryAllocatedBytes"] as? Double
            let cores = gpu["coreCount"] as? Double
            var lines: [String] = []
            let memoryText: String
            if let usedMemory, usedMemory > 0 {
                memoryText = "\(formatBytes(Int64(usedMemory))) in use"
            } else if let allocatedMemory, allocatedMemory > 0 {
                memoryText = "\(formatBytes(Int64(allocatedMemory))) allocated"
            } else {
                memoryText = "memory unknown"
            }
            let coreText = cores.map { " · \(Int($0)) cores" } ?? ""
            lines.append("\(memoryText)\(coreText)")
            lines.append(hostTotalPowerLine(host))
            return GpuWidgetMetric(
                source: "mac",
                index: offset,
                title: "Mac GPU",
                name: name,
                primary: formatPercent(util),
                lines: lines,
                percent: util
            )
        }
    }

    private static func nvidiaGpuWidget(_ gpu: NvidiaGpuMetric) -> GpuWidgetMetric {
        let memory = nvidiaMemoryLine(gpu)
        let temp = gpu.temperatureC.map { " · \(Int($0.rounded()))C" } ?? ""
        let power = gpu.powerW.map { "Power \(formatWatts($0))" } ?? "Power -- W"
        return GpuWidgetMetric(
            source: "nvidia",
            index: gpu.index,
            title: gpu.index.map { "VM GPU \($0)" } ?? "VM GPU",
            name: gpu.name,
            primary: formatPercent(gpu.utilizationPercent),
            lines: ["\(memory)\(temp)", power],
            percent: gpu.utilizationPercent
        )
    }

    private static func nvidiaMemoryLine(_ gpu: NvidiaGpuMetric) -> String {
        guard let used = gpu.memoryUsedMiB, let total = gpu.memoryTotalMiB, total > 0 else { return "VRAM unavailable" }
        return "VRAM \(Int(used.rounded())) / \(Int(total.rounded())) MiB"
    }

    private static func hostPowerLine(_ host: [String: Any]) -> String {
        guard let watts = host["powerW"] as? Double, watts.isFinite, watts > 0 else {
            return "Power -- W"
        }
        let source = host["powerSource"] as? String
        return source.map { "Power \(formatWatts(watts)) \($0)" } ?? "Power \(formatWatts(watts))"
    }

    private static func hostTotalPowerLine(_ host: [String: Any]) -> String {
        guard let watts = host["powerW"] as? Double, watts.isFinite, watts > 0 else {
            return "Power -- W"
        }
        return "Mac total \(formatWatts(watts))"
    }

    private static func powerDetail(host: [String: Any], nvidiaPower: Double) -> String {
        let mac = hostTotalPowerLine(host)
        if nvidiaPower > 0 {
            return "\(mac) + VM GPU \(formatWatts(nvidiaPower))"
        }
        return mac
    }

    private static func formatWatts(_ value: Double) -> String {
        guard value.isFinite else { return "-- W" }
        return value >= 100 ? "\(Int(value.rounded())) W" : String(format: "%.1f W", value)
    }

    private static func numericDouble(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: return value.isFinite ? value : nil
        case let value as Int64: return Double(value)
        case let value as Int: return Double(value)
        case let value as UInt64: return Double(value)
        default: return nil
        }
    }

    private static func formatBytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        return unit <= 1 ? "\(Int(amount)) \(units[unit])" : String(format: "%.1f %@", amount, units[unit])
    }

    private static func formatBytesPerSecond(_ value: Double) -> String {
        "\(formatBytes(Int64(max(0, value))))/s"
    }

    private static func nvidiaLabel(_ state: String) -> String {
        if state == "stopped" { return "Stopped" }
        if state == "booting" { return "Booting" }
        if state == "missing" { return "Missing" }
        return "Optional"
    }

    private static func linuxDriverLabel(_ state: String) -> String {
        if state == "stopped" { return "Stopped" }
        if state == "booting" { return "Booting" }
        if state == "not-loaded" { return "Not loaded" }
        if state == "not-ready" { return "Not ready" }
        if state == "working" { return "Working" }
        return "Check driver"
    }

    private static func linuxDriverDetail(_ status: GuestDriverStatus) -> String {
        if status.state == "stopped" { return "Runtime stopped" }
        if status.state == "booting" { return "Waiting for guest" }
        if status.state == "not-loaded" { return status.detail.isEmpty ? "Installed; not loaded" : firstLine(status.detail) }
        if status.state == "not-ready" { return status.detail.isEmpty ? "Needs reinstall" : firstLine(status.detail) }
        return status.detail.isEmpty ? "Status unavailable" : firstLine(status.detail)
    }

    private static func progressLine(_ event: ProgressEvent) -> String {
        var text = "[\(event.level.rawValue)] \(event.message)"
        if let percent = event.percent {
            text += " \(Int(percent.rounded()))%"
        }
        if let detail = event.detail, !detail.isEmpty {
            text += " - \(detail)"
        }
        return text
    }
}

enum PreferencesKeys {
    static let sidebarCollapsed = "vegpu.sidebar.collapsed"
    static let webShortcuts = "vegpu.web.shortcuts"
    static let updateChannel = "vegpu.update.channel"
}

struct MetricGroup: Equatable {
    var cpu: String = "CPU --%"
    var ram: String = "RAM checking"
    var net: String = "NET checking"
    var disk: String = "DISK checking"
    var gpu: String = "GPU checking"
    var bar: Double? = nil
}

struct PowerMetric: Equatable {
    var total: String = "-- W"
    var detail: String = "Mac + detected GPU draw"
    var percent: Double = 0
}

struct DriverCardState: Equatable {
    var title: String
    var status: String
    var detail: String
    var state: String
    var actionTitle: String? = nil
    var actionEnabled: Bool = true
}

struct TerminalInput: Equatable, Identifiable {
    let id = UUID()
    var text: String
}
