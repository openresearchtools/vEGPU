import Foundation
import SwiftUI
import AppKit
import PEGPUCore

@MainActor
final class NativeAppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case runtime = "Runtime"
        case files = "Files"
        case gui = "GUI"
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

        var id: String { rawValue }
    }

    var selectedSection: Section = .runtime
    @Published var runtimeLaunchMode: RuntimeLaunchMode = MachineConfig.defaultLaunchMode
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
            saveWebShortcuts(shortcuts)
        }
    }
    @Published var showingAddWebUI = false
    @Published var showingCreateRoutingRoute = false
    @Published var showingManageRoutingRoutes = false
    @Published var showingManageMachines = false
    @Published private(set) var machineProfiles: [MachineProfile] = []
    @Published var pendingMachineID = ""
    @Published private(set) var selectedMachineID = ""
    @Published var machineProfileMessage: String?
    @Published private(set) var profileRevision = UUID()
    @Published private(set) var machineProfileLockedState = false
    @Published var showDeveloperOptions = UserDefaults.standard.bool(forKey: PreferencesKeys.developerOptions) {
        didSet { UserDefaults.standard.set(showDeveloperOptions, forKey: PreferencesKeys.developerOptions) }
    }
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
    var outputLines: [String] { get { runtimeScreen.log.outputLines } set { setIfChanged(runtimeScreen.log, \.outputLines, newValue) } }
    var currentProgress: ProgressEvent? { get { runtimeScreen.log.currentProgress } set { runtimeScreen.log.currentProgress = newValue } }
    var commandState: String { get { runtimeScreen.log.commandState } set { setIfChanged(runtimeScreen.log, \.commandState, newValue) } }
    var linuxPassword: String { get { runtimeScreen.terminal.linuxPassword } set { setIfChanged(runtimeScreen.terminal, \.linuxPassword, newValue) } }
    @Published var webHelperStatus = "Stopped"
    @Published var hostSleepGuardStatus = "Sleep Guard: Off"
    @Published var hostSleepGuardActive = false
    var terminalConnected: Bool { get { runtimeScreen.terminal.terminalConnected } set { setIfChanged(runtimeScreen.terminal, \.terminalConnected, newValue) } }
    var terminalSessionID: UUID { get { runtimeScreen.terminal.terminalSessionID } set { runtimeScreen.terminal.terminalSessionID = newValue } }
    var terminalInput: TerminalInput? { get { runtimeScreen.terminal.terminalInput } set { runtimeScreen.terminal.terminalInput = newValue } }
    var showingNvidiaInstallConfirm: Bool { get { runtimeScreen.drivers.showingNvidiaInstallConfirm } set { setIfChanged(runtimeScreen.drivers, \.showingNvidiaInstallConfirm, newValue) } }

    private let registryStore: MachineProfileRegistryStore
    private let appRoot: URL
    private var machineContext: MachineProfileContext
    var paths: AppPaths
    let sidebarMonitor: SidebarMonitorState
    let runtimeScreen: RuntimeScreenState
    var configStore: MachineConfigStore
    let progress: ProgressCenter
    var machineService: MachineService
    var llmsRuntime: LlmsRuntimeService
    var nativeBridge: NativeBridgeService
    var goHelperSupervisor: GoHelperSupervisor
    var localProxySupervisor: LocalProxySupervisor
    var hostSetupService: HostSetupService
    var metricsService: MetricsService
    let vfioService: VfioService
    var displayControlMenu: DisplayControlMenuModel
    @Published private(set) var displaySession: SpiceSessionController
    let externalDisplayCapture: ExternalDisplayCaptureCoordinator
    let updates: AppUpdateService
    private var pollingStarted = false
    private var backgroundServicesStarted = false
    private var statusRefreshInFlight = false
    private var metricsRefreshInFlight = false
    private var driverRefreshInFlight = false
    private var activeSection: Section = .runtime
    private var outputTextRemainder = ""

    init(paths requestedPaths: AppPaths = AppPaths()) {
        let registryStore = MachineProfileRegistryStore()
        var registry = (try? registryStore.loadOrCreate(preferredProfileRoot: requestedPaths.appData)) ?? {
            let profile = MachineProfile(name: "Default", path: requestedPaths.appData.path)
            return MachineProfileRegistry(selectedID: profile.id, machines: [profile])
        }()
        if registry.machines.isEmpty {
            let profile = MachineProfile(name: "Default", path: requestedPaths.appData.path)
            registry = MachineProfileRegistry(selectedID: profile.id, machines: [profile])
            try? registryStore.save(registry)
        }
        let selectedProfile = registry.machines.first(where: { $0.id == registry.selectedID }) ?? registry.machines[0]
        let paths = AppPaths(root: requestedPaths.root, dataRoot: selectedProfile.url)
        let context = (try? MachineProfileMaintenance.profileContext(profile: selectedProfile)) ??
            MachineProfileContext(profileRoot: selectedProfile.url, profileID: selectedProfile.id, name: selectedProfile.name)
        self.registryStore = registryStore
        self.appRoot = requestedPaths.root
        self.machineContext = context
        self.paths = paths
        self.machineProfiles = registry.machines
        self.selectedMachineID = selectedProfile.id
        self.pendingMachineID = selectedProfile.id
        self.sidebarMonitor = SidebarMonitorState(logoURL: paths.resources.appendingPathComponent("Assets/PEGPU-logo-transparent.png"))
        self.runtimeScreen = RuntimeScreenState()
        let progress = ProgressCenter()
        self.progress = progress
        let services = Self.makeServices(paths: paths, context: context, progress: progress)
        let displaySession = Self.makeDisplaySession(paths: paths, context: context)
        self.configStore = services.configStore
        let loadedConfig = services.configStore.load()
        self.runtimeLaunchMode = loadedConfig.launchMode
        self.guiRetina = loadedConfig.guiRetina
        self.machineService = services.machineService
        self.displayControlMenu = services.displayControlMenu
        self.llmsRuntime = services.llmsRuntime
        self.nativeBridge = services.nativeBridge
        self.goHelperSupervisor = services.goHelperSupervisor
        self.localProxySupervisor = services.localProxySupervisor
        self.hostSetupService = services.hostSetupService
        self.metricsService = services.metricsService
        self.vfioService = VfioService()
        self.updates = AppUpdateService()
        self.displaySession = displaySession
        self.externalDisplayCapture = ExternalDisplayCaptureCoordinator(
            displaySession: displaySession,
            displayControl: services.displayControlMenu,
            machine: services.machineService
        )
        self.sidebarCollapsed = UserDefaults.standard.bool(forKey: PreferencesKeys.sidebarCollapsed)
        self.shortcuts = Self.loadWebShortcuts(paths: paths)
        progress.observe { [weak self] (event: ProgressEvent) in
            Task { @MainActor in
                guard let self else { return }
                self.currentProgress = event
                self.appendOutput(Self.progressLine(event))
            }
        }
    }

    private static func makeServices(paths: AppPaths, context: MachineProfileContext, progress: ProgressCenter) -> (
        configStore: MachineConfigStore,
        machineService: MachineService,
        llmsRuntime: LlmsRuntimeService,
        nativeBridge: NativeBridgeService,
        goHelperSupervisor: GoHelperSupervisor,
        localProxySupervisor: LocalProxySupervisor,
        hostSetupService: HostSetupService,
        metricsService: MetricsService,
        displayControlMenu: DisplayControlMenuModel
    ) {
        let runtimePaths = MachineRuntimePaths(root: context.hostRuntimeRoot)
        let configStore = MachineConfigStore(paths: paths)
        let machine = MachineService(paths: paths, runtimePaths: runtimePaths, progress: progress)
        let llmsRuntime = LlmsRuntimeService(paths: paths, machine: machine)
        let nativeBridge = NativeBridgeService(runtime: llmsRuntime)
        let goHelperSupervisor = GoHelperSupervisor(paths: paths, runtimePaths: runtimePaths, profileID: context.profileID, bridge: nativeBridge)
        let localProxySupervisor = LocalProxySupervisor(paths: paths, runtimePaths: runtimePaths)
        let hostSetupService = HostSetupService(paths: paths, progress: progress)
        let networkStore = NetworkStateStore(paths: paths, liveDir: runtimePaths.root)
        let ssh = SSHClient(paths: paths, networkStore: networkStore, progress: progress)
        let metricsService = MetricsService(ssh: ssh, machinePid: { machine.currentPid() })
        let displayControlMenu = DisplayControlMenuModel(paths: paths, machine: machine)
        return (
            configStore: configStore,
            machineService: machine,
            llmsRuntime: llmsRuntime,
            nativeBridge: nativeBridge,
            goHelperSupervisor: goHelperSupervisor,
            localProxySupervisor: localProxySupervisor,
            hostSetupService: hostSetupService,
            metricsService: metricsService,
            displayControlMenu: displayControlMenu
        )
    }

    private static func makeDisplaySession(paths: AppPaths, context: MachineProfileContext) -> SpiceSessionController {
        let files = MachineFiles(machineDir: paths.machine, liveDir: context.hostRuntimeRoot)
        return SpiceSessionController(socketURL: files.spiceSocket, qmpSocketURL: files.qmp, paths: paths)
    }

    var webHelperBaseURL: URL {
        goHelperSupervisor.baseURL
    }

    var machineFiles: MachineFiles {
        MachineFiles(machineDir: paths.machine, liveDir: machineContext.hostRuntimeRoot)
    }

    var machineProfileLocked: Bool {
        machineProfileLockedState || machineService.currentPid() != nil
    }

    func showManageMachines() {
        guard !machineProfileLocked else {
            machineProfileMessage = "VM is running. Stop VM first."
            return
        }
        showingManageMachines = true
    }

    func refreshMachineProfiles() {
        do {
            let registry = try registryStore.loadOrCreate(preferredProfileRoot: paths.appData)
            machineProfiles = registry.machines
            selectedMachineID = registry.selectedID
            if pendingMachineID.isEmpty || !registry.machines.contains(where: { $0.id == pendingMachineID }) {
                pendingMachineID = registry.selectedID
            }
        } catch {
            machineProfileMessage = "Could not load VMs: \(firstLine(String(describing: error)))"
        }
    }

    func switchMachineProfile(id: String, persist: Bool = false) {
        guard !machineProfileLocked else {
            machineProfileMessage = "VM is running. Stop VM first."
            pendingMachineID = selectedMachineID
            return
        }
        guard let profile = machineProfiles.first(where: { $0.id == id }) else { return }
        do {
            if persist {
                let registry = try registryStore.select(profile.id)
                machineProfiles = registry.machines
                selectedMachineID = registry.selectedID
            }
            pendingMachineID = profile.id
            rebindServices(to: profile)
            machineProfileMessage = nil
            appendOutput("[info] VM selected: \(profile.name)")
        } catch {
            machineProfileMessage = "Could not switch VM: \(firstLine(String(describing: error)))"
            pendingMachineID = selectedMachineID
        }
    }

    func createDefaultMachineProfile() {
        let base = uniqueDefaultProfileURL(name: "Machine")
        createMachineProfile(name: base.lastPathComponent, url: base)
    }

    func createCustomMachineProfile() {
        guard let url = chooseDirectory(title: "Create Machine Profile", message: "Choose an empty folder for the new PEGPU VM.") else { return }
        createMachineProfile(name: url.lastPathComponent.isEmpty ? "Machine" : url.lastPathComponent, url: url)
    }

    func addExistingMachineProfile() {
        guard let url = chooseDirectory(title: "Add Machine Profile", message: "Choose a PEGPU machine profile folder.") else { return }
        guard !machineProfileLocked else {
            machineProfileMessage = "VM is running. Stop VM first."
            return
        }
        do {
            let standardized = url.standardizedFileURL
            if let existing = machineProfiles.first(where: { $0.url.standardizedFileURL.path == standardized.path }) {
                switchMachineProfile(id: existing.id, persist: true)
                return
            }
            try validateProfileCandidate(standardized, allowEmpty: false)
            let name = standardized.lastPathComponent.isEmpty ? "Machine" : standardized.lastPathComponent
            MachineProfileMaintenance.deleteRouterConfig(profileRoot: standardized)
            MachineProfileMaintenance.cleanTransientFiles(profileRoot: standardized)
            try MachineProfileMaintenance.ensureProfileScaffold(profileRoot: standardized, name: name, preserveIdentity: true)
            let identity = try MachineProfileMaintenance.ensureProfileIdentity(profileRoot: standardized, name: name, preserveExisting: true)
            var registry = try registryStore.loadOrCreate(preferredProfileRoot: paths.appData)
            if let index = registry.machines.firstIndex(where: { $0.id == identity.profileID }) {
                registry.machines[index].path = standardized.path
                registry.machines[index].name = name
                registry.selectedID = identity.profileID
                try registryStore.save(registry)
                machineProfiles = registry.machines
                selectedMachineID = registry.selectedID
                pendingMachineID = identity.profileID
                rebindServices(to: registry.machines[index])
                appendOutput("[success] VM reattached: \(name)")
                return
            }
            let profile = MachineProfile(id: identity.profileID, name: name, path: standardized.path)
            registry.machines.append(profile)
            registry.selectedID = profile.id
            try registryStore.save(registry)
            machineProfiles = registry.machines
            selectedMachineID = registry.selectedID
            pendingMachineID = profile.id
            rebindServices(to: profile)
            appendOutput("[success] VM added: \(profile.name)")
        } catch {
            machineProfileMessage = "Could not add VM: \(firstLine(String(describing: error)))"
        }
    }

    func copySelectedMachineProfile() {
        guard !machineProfileLocked else {
            machineProfileMessage = "VM is running. Stop VM first."
            return
        }
        guard let source = machineProfiles.first(where: { $0.id == pendingMachineID }) else { return }
        guard let destination = chooseSaveFolder(defaultName: "\(source.name) Copy", message: "Choose where to copy this PEGPU VM.") else { return }
        do {
            try validateCopyMoveDestination(destination, source: source.url)
            var registry = try registryStore.loadOrCreate(preferredProfileRoot: paths.appData)
            let profile = MachineProfile(name: destination.lastPathComponent.isEmpty ? "\(source.name) Copy" : destination.lastPathComponent, path: destination.path)
            try MachineProfileMaintenance.copyProfile(from: source.url, to: destination)
            MachineProfileMaintenance.cleanTransientFiles(profileRoot: destination)
            try MachineProfileMaintenance.ensureProfileScaffold(profileRoot: destination, name: profile.name, preferredID: profile.id, preserveIdentity: false)
            registry.machines.append(profile)
            registry.selectedID = profile.id
            try registryStore.save(registry)
            machineProfiles = registry.machines
            selectedMachineID = registry.selectedID
            pendingMachineID = profile.id
            rebindServices(to: profile)
            appendOutput("[success] VM copied: \(profile.name)")
        } catch {
            machineProfileMessage = "Could not copy VM: \(firstLine(String(describing: error)))"
        }
    }

    func moveSelectedMachineProfile() {
        guard !machineProfileLocked else {
            machineProfileMessage = "VM is running. Stop VM first."
            return
        }
        guard let index = machineProfiles.firstIndex(where: { $0.id == pendingMachineID }) else { return }
        let source = machineProfiles[index]
        guard let destination = chooseSaveFolder(defaultName: source.name, message: "Choose where to move this PEGPU VM.") else { return }
        do {
            try validateCopyMoveDestination(destination, source: source.url)
            MachineProfileMaintenance.cleanTransientFiles(profileRoot: source.url)
            try FileManager.default.moveItem(at: source.url, to: destination)
            MachineProfileMaintenance.cleanTransientFiles(profileRoot: destination)
            try MachineProfileMaintenance.ensureProfileScaffold(profileRoot: destination, name: destination.lastPathComponent.isEmpty ? source.name : destination.lastPathComponent, preferredID: source.id, preserveIdentity: true)
            var registry = try registryStore.loadOrCreate(preferredProfileRoot: paths.appData)
            guard let registryIndex = registry.machines.firstIndex(where: { $0.id == source.id }) else {
                throw RuntimeError.message("Machine profile is not registered.")
            }
            registry.machines[registryIndex].path = destination.standardizedFileURL.path
            registry.machines[registryIndex].name = destination.lastPathComponent.isEmpty ? registry.machines[registryIndex].name : destination.lastPathComponent
            registry.selectedID = source.id
            try registryStore.save(registry)
            machineProfiles = registry.machines
            selectedMachineID = registry.selectedID
            pendingMachineID = source.id
            rebindServices(to: registry.machines[registryIndex])
            appendOutput("[success] VM moved: \(registry.machines[registryIndex].name)")
        } catch {
            machineProfileMessage = "Could not move VM: \(firstLine(String(describing: error)))"
        }
    }

    func revealMachineProfile(_ profile: MachineProfile) {
        NSWorkspace.shared.activateFileViewerSelecting([profile.url])
    }

    @discardableResult
    func removeMachineProfile(_ profile: MachineProfile, deleteFiles: Bool = false) -> Bool {
        do {
            if machineProfileLocked, profile.id == pendingMachineID {
                throw RuntimeError.message("VM is running. Stop VM first.")
            }
            var registry = try registryStore.loadOrCreate(preferredProfileRoot: paths.appData)
            guard registry.machines.count > 1 else {
                throw RuntimeError.message("At least one VM must stay registered.")
            }
            guard registry.machines.contains(where: { $0.id == profile.id }) else {
                throw RuntimeError.message("Machine profile is not registered.")
            }
            let profileRoot = profile.url.standardizedFileURL
            let runtimeRoot = deleteFiles ? runtimeRootForRemoval(profile) : nil
            registry.machines.removeAll { $0.id == profile.id }
            if registry.selectedID == profile.id {
                registry.selectedID = registry.machines[0].id
            }
            try registryStore.save(registry)
            machineProfiles = registry.machines
            if pendingMachineID == profile.id || selectedMachineID == profile.id {
                selectedMachineID = registry.selectedID
                pendingMachineID = registry.selectedID
                if let next = registry.machines.first(where: { $0.id == registry.selectedID }), !machineProfileLocked {
                    rebindServices(to: next)
                }
            }
            if deleteFiles {
                try deleteMachineProfileFiles(profileRoot: profileRoot, runtimeRoot: runtimeRoot)
                appendOutput("[success] VM deleted: \(profile.name)")
            } else {
                appendOutput("[info] VM removed from list: \(profile.name)")
            }
            machineProfileMessage = nil
            return true
        } catch {
            machineProfileMessage = "Could not \(deleteFiles ? "delete" : "remove") VM: \(firstLine(String(describing: error)))"
            return false
        }
    }

    func removeMachineProfileFromList(_ profile: MachineProfile) {
        removeMachineProfile(profile, deleteFiles: false)
    }

    private func runtimeRootForRemoval(_ profile: MachineProfile) -> URL? {
        let identityURL = MachineProfileMaintenance.identityURL(profileRoot: profile.url)
        if let identity = try? JSON.read(MachineProfileIdentity.self, from: identityURL) {
            return MachineRuntimePaths.hostRuntimeRoot(for: identity.profileID)
        }
        return MachineRuntimePaths.hostRuntimeRoot(for: profile.id)
    }

    private func deleteMachineProfileFiles(profileRoot: URL, runtimeRoot: URL?) throws {
        let fm = FileManager.default
        let roots = [profileRoot.standardizedFileURL, runtimeRoot?.standardizedFileURL].compactMap { $0 }
        var deleted = Set<String>()
        for root in roots where !deleted.contains(root.path) {
            deleted.insert(root.path)
            if fm.fileExists(atPath: root.path) {
                try fm.removeItem(at: root)
            }
        }
    }

    private func createMachineProfile(name: String, url: URL) {
        guard !machineProfileLocked else {
            machineProfileMessage = "VM is running. Stop VM first."
            return
        }
        do {
            let target = url.standardizedFileURL
            try validateCreateDestination(target)
            let profile = MachineProfile(name: name.isEmpty ? target.lastPathComponent : name, path: target.path)
            try MachineProfileMaintenance.ensureProfileScaffold(profileRoot: target, name: profile.name, preferredID: profile.id, preserveIdentity: false)
            var registry = try registryStore.loadOrCreate(preferredProfileRoot: paths.appData)
            registry.machines.append(profile)
            registry.selectedID = profile.id
            try registryStore.save(registry)
            machineProfiles = registry.machines
            selectedMachineID = registry.selectedID
            pendingMachineID = profile.id
            rebindServices(to: profile)
            appendOutput("[success] VM created: \(profile.name)")
        } catch {
            machineProfileMessage = "Could not create VM: \(firstLine(String(describing: error)))"
        }
    }

    private func commitPendingMachineSelection() throws {
        guard !pendingMachineID.isEmpty else { return }
        guard let profile = machineProfiles.first(where: { $0.id == pendingMachineID }) else {
            throw RuntimeError.message("Machine profile is not registered.")
        }
        if paths.appData.standardizedFileURL.path != profile.url.standardizedFileURL.path {
            rebindServices(to: profile)
        }
        guard pendingMachineID != selectedMachineID else { return }
        let registry = try registryStore.select(pendingMachineID)
        machineProfiles = registry.machines
        selectedMachineID = registry.selectedID
    }

    private func rebindServices(to profile: MachineProfile) {
        NotificationCenter.default.post(name: .pegpuMachineProfileWillSwitch, object: self)
        externalDisplayCapture.forceRelease(disconnect: true, restorePreviousApp: false)
        localProxySupervisor.stop()
        goHelperSupervisor.stop()
        nativeBridge.stop()
        terminalConnected = false
        let newPaths = AppPaths(root: appRoot, dataRoot: profile.url)
        let context = (try? MachineProfileMaintenance.profileContext(profile: profile)) ??
            MachineProfileContext(profileRoot: profile.url, profileID: profile.id, name: profile.name)
        let services = Self.makeServices(paths: newPaths, context: context, progress: progress)
        machineContext = context
        paths = newPaths
        configStore = services.configStore
        machineService = services.machineService
        llmsRuntime = services.llmsRuntime
        nativeBridge = services.nativeBridge
        goHelperSupervisor = services.goHelperSupervisor
        localProxySupervisor = services.localProxySupervisor
        hostSetupService = services.hostSetupService
        metricsService = services.metricsService
        displayControlMenu = services.displayControlMenu
        let newDisplaySession = Self.makeDisplaySession(paths: newPaths, context: context)
        displaySession = newDisplaySession
        externalDisplayCapture.rebind(
            displaySession: newDisplaySession,
            displayControl: services.displayControlMenu,
            machine: services.machineService
        )
        let loaded = services.configStore.load()
        runtimeLaunchMode = loaded.launchMode
        guiRetina = loaded.guiRetina
        linuxPassword = services.machineService.linuxPassword() ?? ""
        shortcuts = Self.loadWebShortcuts(paths: newPaths)
        profileRevision = UUID()
        if backgroundServicesStarted {
            backgroundServicesStarted = false
        }
        refreshStatus()
        displayControlMenu.refresh()
        NotificationCenter.default.post(name: .pegpuMachineProfileDidSwitch, object: self)
    }

    private func validateProfileCandidate(_ url: URL, allowEmpty: Bool) throws {
        let target = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RuntimeError.message("Machine folder does not exist.")
        }
        for profile in machineProfiles {
            let profileURL = profile.url.standardizedFileURL
            if target.path == profileURL.path {
                throw RuntimeError.message("Machine folder is already registered.")
            }
            if MachineProfileValidation.path(target, isInside: profileURL) || MachineProfileValidation.path(profileURL, isInside: target) {
                throw RuntimeError.message("Machine folders cannot be nested inside another registered VM.")
            }
        }
        if allowEmpty, (try? FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty) == true {
            return
        }
        guard MachineProfileValidation.isProfileFolder(target) else {
            throw RuntimeError.message("Selected folder does not look like a PEGPU machine profile.")
        }
    }

    private func validateCreateDestination(_ url: URL) throws {
        let target = url.standardizedFileURL
        for profile in machineProfiles {
            let profileURL = profile.url.standardizedFileURL
            if MachineProfileValidation.path(target, isInside: profileURL) || MachineProfileValidation.path(profileURL, isInside: target) {
                throw RuntimeError.message("Machine folders cannot be nested inside another registered VM.")
            }
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw RuntimeError.message("Destination is not a folder.")
            }
            let items = try FileManager.default.contentsOfDirectory(atPath: target.path)
            guard items.isEmpty else {
                throw RuntimeError.message("Create destination must be empty.")
            }
        }
    }

    private func validateCopyMoveDestination(_ destination: URL, source: URL) throws {
        let target = destination.standardizedFileURL
        let source = source.standardizedFileURL
        if MachineProfileValidation.path(target, isInside: source) || target.path == source.path {
            throw RuntimeError.message("Destination cannot be inside the current VM folder.")
        }
        try validateCreateDestination(target)
        if FileManager.default.fileExists(atPath: target.path) {
            let items = try FileManager.default.contentsOfDirectory(atPath: target.path)
            guard items.isEmpty else {
                throw RuntimeError.message("Destination folder must be empty.")
            }
            try FileManager.default.removeItem(at: target)
        }
    }

    private func uniqueDefaultProfileURL(name: String) -> URL {
        let safe = safeProfileFolderName(name)
        let root = AppPaths.defaultProfilesRoot
        var candidate = root.appendingPathComponent(safe, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) || machineProfiles.contains(where: { $0.url.standardizedFileURL.path == candidate.standardizedFileURL.path }) {
            candidate = root.appendingPathComponent("\(safe)-\(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    private func safeProfileFolderName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? "Machine" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let filtered = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(filtered).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Machine" : result
    }

    private func chooseDirectory(title: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }

    private func chooseSaveFolder(defaultName: String, message: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Choose VM Folder"
        panel.message = message
        panel.nameFieldStringValue = safeProfileFolderName(defaultName)
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }

    func refreshStatus() {
        refreshRuntimeSnapshot()
        webHelperStatus = goHelperSupervisor.status
        refreshHostSleepGuard()
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
            while !Task.isCancelled {
                refreshRuntimeSnapshot()
                refreshMetrics()
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
        NotificationCenter.default.post(name: .pegpuReloadWebTab, object: self, userInfo: ["tabID": tab.id])
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
        try await localProxySupervisor.start()

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
                try await ensureBackgroundServicesRunning()
                await hostSetupService.ensureFirstRunHostSetup()
            } catch {
                backgroundServicesStarted = false
                appendOutput("[error] Background helper failed: \(error)")
            }
        }
    }

    private func ensureBackgroundServicesRunning() async throws {
        try await localProxySupervisor.start()
        try await goHelperSupervisor.start()
        webHelperStatus = goHelperSupervisor.status
        backgroundServicesStarted = true
    }

    func startRuntime(config: MachineConfig) {
        runtimePane = .output
        Task {
            await runAction("start") {
                try self.commitPendingMachineSelection()
                try await self.ensureBackgroundServicesRunning()
                let saved = try await self.machineService.saveConfig(config)
                await MainActor.run {
                    self.runtimeLaunchMode = saved.launchMode
                    self.guiRetina = saved.guiRetina
                }
                try await self.machineService.startMachine()
                await MainActor.run {
                    self.displayControlMenu.refresh()
                    if saved.launchMode == .gui {
                        self.displaySession.start()
                        NotificationCenter.default.post(name: .pegpuReconnectDisplay, object: self)
                    }
                }
            }
        }
    }

    func saveRuntimeConfig(_ config: MachineConfig) {
        runtimePane = .output
        Task {
            await runAction("save-config") {
                try self.commitPendingMachineSelection()
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
        NotificationCenter.default.post(name: .pegpuRuntimeWillStop, object: self)
        Task {
            await runAction("stop") {
                await self.externalDisplayCapture.releaseForRuntimeStop(disconnect: true)
                try await self.machineService.stopMachine()
            }
        }
    }

    func shutdownRuntimeForLowBattery() async throws -> String {
        runtimePane = .output
        terminalConnected = false
        NotificationCenter.default.post(name: .pegpuRuntimeWillStop, object: self)
        appendOutput("[warning] Battery below 15%; PEGPU is shutting down the VM to prevent battery drain and PCIe sleep risk")
        await externalDisplayCapture.releaseForRuntimeStop(disconnect: true)

        guard machineService.currentPid() != nil else {
            try? await machineService.forceHostSleepGuardOff()
            refreshStatus()
            return "Runtime was already stopped. Sleep prevention has been turned off."
        }

        do {
            try await machineService.stopMachine(timeout: 90)
            try? await machineService.forceHostSleepGuardOff()
            appendOutput("[success] Low-battery VM shutdown completed cleanly")
            refreshStatus()
            return "The VM stopped cleanly. Sleep prevention has been turned off."
        } catch {
            let stopError = error
            appendOutput("[warning] Clean low-battery VM shutdown failed; force killing QEMU: \(firstLine(String(describing: stopError)))")
            do {
                try await machineService.forceKillMachineProcess()
                try? await machineService.forceHostSleepGuardOff()
                appendOutput("[success] QEMU was force killed for low-battery protection")
                refreshStatus()
                return "Clean shutdown did not finish in time. QEMU was force killed for low-battery protection, and sleep prevention has been turned off."
            } catch {
                try? await machineService.forceHostSleepGuardOff()
                appendOutput("[error] Low-battery force kill failed: \(error)")
                refreshStatus()
                throw RuntimeError.message("Clean shutdown failed: \(firstLine(String(describing: stopError))). Force kill failed: \(firstLine(String(describing: error))).")
            }
        }
    }

    func resetRuntime(config: MachineConfig? = nil) {
        runtimePane = .output
        terminalConnected = false
        NotificationCenter.default.post(name: .pegpuRuntimeWillStop, object: self)
        Task {
            await runAction("reset") {
                await self.externalDisplayCapture.releaseForRuntimeStop(disconnect: true)
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
                        self.displaySession.start()
                        NotificationCenter.default.post(name: .pegpuReconnectDisplay, object: self)
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

    func refreshHostSleepGuard() {
        Task {
            let status = await machineService.hostSleepGuardStatus()
            await MainActor.run {
                self.applyHostSleepGuardStatus(status)
            }
        }
    }

    func forceHostSleepGuardOn() {
        Task {
            do {
                try await machineService.forceHostSleepGuardOn()
                appendOutput("[success] Mac sleep guard forced on")
            } catch {
                appendOutput("[error] Could not force Mac sleep guard on: \(error)")
            }
            refreshHostSleepGuard()
        }
    }

    func forceHostSleepGuardOff() {
        Task {
            do {
                try await machineService.forceHostSleepGuardOff()
                appendOutput("[success] Mac sleep guard forced off")
            } catch {
                appendOutput("[error] Could not force Mac sleep guard off: \(error)")
            }
            refreshHostSleepGuard()
        }
    }

    func stopHostSleepGuardForShutdown() {
        Task {
            try? await machineService.forceHostSleepGuardOff()
            refreshHostSleepGuard()
        }
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
            NotificationCenter.default.post(name: .pegpuRuntimeWillStop, object: self)
            await externalDisplayCapture.releaseForRuntimeStop(disconnect: true)
            try await machineService.stopMachine(timeout: 90)
        }
        try? await machineService.forceHostSleepGuardOff()
        localProxySupervisor.stop()
        goHelperSupervisor.stop()
        nativeBridge.stop()
    }

    func shutdownBackgroundServices() {
        externalDisplayCapture.forceRelease(disconnect: true, restorePreviousApp: false)
        localProxySupervisor.stop()
        goHelperSupervisor.stop()
        nativeBridge.stop()
        stopHostSleepGuardForShutdown()
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

    private func refreshRuntimeSnapshot() {
        guard !statusRefreshInFlight else { return }
        statusRefreshInFlight = true
        let machineService = machineService
        let revision = profileRevision
        Task(priority: .utility) { [machineService, revision] in
            let status = await machineService.statusMachine()
            let password = machineService.linuxPassword() ?? ""
            guard revision == profileRevision else {
                statusRefreshInFlight = false
                return
            }
            applyRuntimeStatus(status)
            linuxPassword = password
            webHelperStatus = goHelperSupervisor.status
            refreshHostSleepGuard()
            statusRefreshInFlight = false
        }
    }

    private func runAction(_ name: String, operation: @escaping () async throws -> Void) async {
        commandState = "running"
        appendOutput("$ pegpu machine \(name)")
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

    private static func webShortcutsURL(paths: AppPaths) -> URL {
        paths.appData.appendingPathComponent(".pegpu", isDirectory: true).appendingPathComponent("web-shortcuts.json")
    }

    private static func loadWebShortcuts(paths: AppPaths) -> [WebShortcut] {
        let url = webShortcutsURL(paths: paths)
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONDecoder().decode([WebShortcut].self, from: data) {
            return parsed
        }
        if let data = UserDefaults.standard.data(forKey: PreferencesKeys.webShortcuts),
           let parsed = try? JSONDecoder().decode([WebShortcut].self, from: data) {
            try? JSON.write(parsed, to: url)
            return parsed
        }
        return []
    }

    private func saveWebShortcuts(_ shortcuts: [WebShortcut]) {
        try? JSON.write(shortcuts, to: Self.webShortcutsURL(paths: paths))
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
            displayControlMenu.clearRuntimeState()
        default:
            nextStatus = "Needs attention"
            nextMetric = "Check logs"
            nextDetail = status.detail ?? status.state
        }
        sidebarMonitor.updateRuntime(status: nextStatus, detail: nextDetail, metric: nextMetric, state: normalized)
        machineProfileLockedState = normalized != "stopped"
    }

    private func applyHostSleepGuardStatus(_ status: HostSleepGuardStatus) {
        hostSleepGuardActive = status.active
        if !status.installed {
            hostSleepGuardStatus = "Sleep Guard: Not installed"
        } else if status.active {
            let mode = status.mode == "manual" ? "manual" : "runtime"
            let pid = status.pid.map { " pid=\($0)" } ?? ""
            hostSleepGuardStatus = "Sleep Guard: On (\(mode)\(pid))"
        } else if status.mode == "error" {
            hostSleepGuardStatus = "Sleep Guard: Error"
        } else {
            hostSleepGuardStatus = "Sleep Guard: Off"
        }
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
        let nvidiaGpuWidgets = nvidiaGpus.map { Self.nvidiaGpuWidget($0) }

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
    static let sidebarCollapsed = "pegpu.sidebar.collapsed"
    static let webShortcuts = "pegpu.web.shortcuts"
    static let updateChannel = "pegpu.update.channel"
    static let developerOptions = "pegpu.developer.options"
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
