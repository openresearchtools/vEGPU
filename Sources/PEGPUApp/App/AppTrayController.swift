import AppKit
import Combine
import PEGPUCore

@MainActor
final class AppTrayController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var appDelegate: AppDelegate?
    private weak var model: NativeAppModel?
    private var globalHotkeys: DisplayGlobalHotkeyService?
    private var profileObserver: NSObjectProtocol?
    private var captureObserver: NSObjectProtocol?
    private var releaseCaptureObserver: NSObjectProtocol?
    private var reconnectDisplayObserver: NSObjectProtocol?
    private var runtimeStopObserver: NSObjectProtocol?
    private var displayControlObserver: AnyCancellable?
    private var activeSessionObserver: AnyCancellable?
    private var captureSyncTask: Task<Void, Never>?
    private var menuUpdateScheduled = false
    private var statusText = "checking"
    private var externalInputCaptureActive = false
    private var timer: Timer?

    var screenAnchorRect: NSRect? {
        guard let button = statusItem.button,
              let window = button.window else {
            return nil
        }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
        configureIcon()
    }

    func configure(model: NativeAppModel) {
        self.model = model
        if globalHotkeys == nil {
            let globalHotkeys = DisplayGlobalHotkeyService(displayControl: model.displayControlMenu)
            globalHotkeys.start()
            self.globalHotkeys = globalHotkeys
        }
        bindDisplayControlMenu(model.displayControlMenu)
        bindExternalInputCapture(model)
        if profileObserver == nil {
            profileObserver = NotificationCenter.default.addObserver(
                forName: .pegpuMachineProfileDidSwitch,
                object: model,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.rebindDisplayHotkeys()
                }
            }
        }
        if releaseCaptureObserver == nil {
            releaseCaptureObserver = NotificationCenter.default.addObserver(
                forName: .pegpuReleaseExternalInputCapture,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.model?.setExternalDisplayInputCapture(false)
                }
            }
        }
        if reconnectDisplayObserver == nil {
            reconnectDisplayObserver = NotificationCenter.default.addObserver(
                forName: .pegpuReconnectDisplay,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.model?.reconnectDisplayInputSession()
                }
            }
        }
        if runtimeStopObserver == nil {
            runtimeStopObserver = NotificationCenter.default.addObserver(
                forName: .pegpuRuntimeWillStop,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.model?.disconnectDisplayInputSession()
                }
            }
        }
        if captureObserver == nil {
            captureObserver = NotificationCenter.default.addObserver(
                forName: .pegpuExternalInputCaptureDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let active = notification.object as? Bool == true
                Task { @MainActor [weak self] in
                    self?.externalInputCaptureActive = active
                    self?.updateStatusItemPresentation()
                }
            }
        }
        updateMenu()
        updateStatusItemPresentation()
        model.displayControlMenu.refresh()
        refreshStatus()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus()
            }
        }
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
        if let profileObserver {
            NotificationCenter.default.removeObserver(profileObserver)
        }
        profileObserver = nil
        if let captureObserver {
            NotificationCenter.default.removeObserver(captureObserver)
        }
        captureObserver = nil
        if let releaseCaptureObserver {
            NotificationCenter.default.removeObserver(releaseCaptureObserver)
        }
        releaseCaptureObserver = nil
        if let reconnectDisplayObserver {
            NotificationCenter.default.removeObserver(reconnectDisplayObserver)
        }
        reconnectDisplayObserver = nil
        if let runtimeStopObserver {
            NotificationCenter.default.removeObserver(runtimeStopObserver)
        }
        runtimeStopObserver = nil
        displayControlObserver = nil
        activeSessionObserver = nil
        captureSyncTask?.cancel()
        captureSyncTask = nil
        globalHotkeys?.invalidate()
        globalHotkeys = nil
        model?.stopHostSleepGuardForShutdown()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func restartDisplayHotkeys() {
        globalHotkeys?.restart()
        if globalHotkeys == nil, let model {
            let globalHotkeys = DisplayGlobalHotkeyService(displayControl: model.displayControlMenu)
            globalHotkeys.start()
            self.globalHotkeys = globalHotkeys
        }
    }

    private func configureIcon() {
        statusItem.button?.toolTip = "PEGPU"
        let root = AppPaths.discoverRoot()
        let trayURL = root.appendingPathComponent("Resources/Assets/PEGPU-tray.png")
        let image = NSImage(contentsOf: trayURL) ?? NSImage(named: "PEGPU")
        image?.size = NSSize(width: 19, height: 19)
        image?.isTemplate = true
        statusItem.button?.image = image
        updateStatusItemPresentation()
    }

    private func updateStatusItemPresentation() {
        statusItem.length = externalInputCaptureActive ? NSStatusItem.variableLength : NSStatusItem.squareLength
        guard let button = statusItem.button else { return }
        button.imagePosition = externalInputCaptureActive ? .imageLeft : .imageOnly
        button.title = externalInputCaptureActive ? " ⌥⌘1 Release" : ""
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.toolTip = externalInputCaptureActive ? "PEGPU external display captured. Press ⌥⌘1 to release." : "PEGPU"
    }

    private func refreshStatus() {
        guard let model else { return }
        Task {
            let next = await model.machineStatusText()
            model.refreshHostSleepGuard()
            await MainActor.run {
                self.statusText = next
                if next.contains("running") {
                    model.displayControlMenu.refresh()
                }
                self.updateMenu()
            }
        }
    }

    private func updateMenu() {
        statusItem.menu = makeMenu()
    }

    private func rebindDisplayHotkeys() {
        globalHotkeys?.invalidate()
        if let model {
            bindDisplayControlMenu(model.displayControlMenu)
            bindExternalInputCapture(model)
            let globalHotkeys = DisplayGlobalHotkeyService(displayControl: model.displayControlMenu)
            globalHotkeys.start()
            self.globalHotkeys = globalHotkeys
        } else {
            globalHotkeys = nil
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        menu.addItem(disabled("PEGPU: \(statusText)"))
        menu.addItem(.separator())
        menu.addItem(item("Open PEGPU", #selector(openApp)))
        let close = item("Close to Tray", #selector(closeToTray))
        close.isEnabled = appDelegate?.mainWindowIsVisible == true
        menu.addItem(close)

        let running = statusText.contains("running")
        let start = item("Start Runtime", #selector(startRuntime))
        start.isEnabled = !running
        menu.addItem(start)
        let stop = item("Stop Runtime", #selector(stopRuntime))
        stop.isEnabled = running
        menu.addItem(stop)

        menu.addItem(disabled(model?.hostSleepGuardStatus ?? "Sleep Guard: checking"))
        let forceSleepGuardOn = item("Force Sleep Guard On", #selector(forceSleepGuardOn))
        forceSleepGuardOn.isEnabled = model?.hostSleepGuardActive != true
        menu.addItem(forceSleepGuardOn)
        let forceSleepGuardOff = item("Force Sleep Guard Off", #selector(forceSleepGuardOff))
        forceSleepGuardOff.isEnabled = model?.hostSleepGuardActive == true
        menu.addItem(forceSleepGuardOff)

        menu.addItem(.separator())
        let openAtLogin = item("Open at Login", #selector(toggleOpenAtLogin(_:)))
        openAtLogin.state = LoginItemService.openAtLogin ? .on : .off
        menu.addItem(openAtLogin)

        let startAtLogin = item("Start Runtime at Login", #selector(toggleStartRuntimeAtLogin(_:)))
        startAtLogin.state = model?.configStore.load().startRuntimeAtLogin == true ? .on : .off
        menu.addItem(startAtLogin)

        if model?.machineService.currentPid() != nil {
            menu.addItem(.separator())
            addDisplaySessionItems(to: menu)
        }

        menu.addItem(item("Quit and Stop Runtime...", #selector(quitAndStopRuntime)))
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        model?.displayControlMenu.refresh()
    }

    private func bindDisplayControlMenu(_ displayControl: DisplayControlMenuModel) {
        displayControlObserver = displayControl.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleMenuUpdate()
            }
        }
    }

    private func bindExternalInputCapture(_ model: NativeAppModel) {
        captureSyncTask?.cancel()
        activeSessionObserver = model.displayControlMenu.$activeSessionID.sink { [weak self, weak model] activeSessionID in
            Task { @MainActor [weak self, weak model] in
                guard let self, let model else { return }
                self.syncExternalInputCapture(activeSessionID: activeSessionID, model: model)
            }
        }
    }

    private func syncExternalInputCapture(activeSessionID: String?, model: NativeAppModel) {
        captureSyncTask?.cancel()
        guard activeSessionID != nil else {
            model.setExternalDisplayInputCapture(false)
            return
        }
        model.startDisplayInputSession()
        captureSyncTask = Task { @MainActor [weak self, weak model] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, let model, !Task.isCancelled else { return }
            guard model.displayControlMenu.activeSessionID != nil else {
                model.setExternalDisplayInputCapture(false)
                return
            }
            model.setExternalDisplayInputCapture(true)
            self.updateStatusItemPresentation()
        }
    }

    private func scheduleMenuUpdate() {
        guard !menuUpdateScheduled else { return }
        menuUpdateScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.menuUpdateScheduled = false
            self.updateMenu()
        }
    }

    private func addDisplaySessionItems(to menu: NSMenu) {
        guard model?.machineService.currentPid() != nil else { return }
        guard let displayControl = model?.displayControlMenu else {
            menu.addItem(disabled("External Displays: unavailable"))
            return
        }
        if displayControl.sessions.isEmpty {
            menu.addItem(disabled(displayControl.busy ? "Loading eGPU displays..." : "No PCIe GPUs found"))
            return
        }
        for (offset, session) in displayControl.sessions.enumerated() {
            if session.running {
                let enter = displaySessionItem(
                    "Enter \(session.title) (Option-Cmd-\(offset + 2))",
                    #selector(enterDisplaySession(_:)),
                    session: session
                )
                enter.isEnabled = !displayControl.busy
                menu.addItem(enter)

                let stop = displaySessionItem("Stop \(session.title)", #selector(stopDisplaySession(_:)), session: session)
                stop.isEnabled = !displayControl.busy
                menu.addItem(stop)

                let reload = displaySessionItem("Reload \(session.title)", #selector(reloadDisplaySession(_:)), session: session)
                reload.isEnabled = !displayControl.busy
                menu.addItem(reload)
            } else {
                let start = displaySessionItem(
                    "Start \(session.title) on eGPU Display (Option-Cmd-\(offset + 2))",
                    #selector(startDisplaySession(_:)),
                    session: session
                )
                start.isEnabled = !displayControl.busy
                menu.addItem(start)
            }
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func displaySessionItem(_ title: String, _ action: Selector, session: DisplaySession) -> NSMenuItem {
        let item = item(title, action)
        item.representedObject = session.id
        return item
    }

    private func displaySession(from sender: NSMenuItem) -> DisplaySession? {
        guard let sessionID = sender.representedObject as? String,
              let displayControl = model?.displayControlMenu else {
            return nil
        }
        return displayControl.sessions.first { $0.id == sessionID }
    }

    @objc private func openApp() {
        appDelegate?.showMainWindow()
    }

    @objc private func closeToTray() {
        appDelegate?.closeToTray()
    }

    @objc private func startRuntime() {
        guard let model else { return }
        Task {
            model.startRuntime(config: model.configStore.load())
            refreshStatus()
        }
    }

    @objc private func stopRuntime() {
        guard let model else { return }
        Task {
            model.stopRuntime()
            refreshStatus()
        }
    }

    @objc private func forceSleepGuardOn() {
        model?.forceHostSleepGuardOn()
        refreshStatus()
    }

    @objc private func forceSleepGuardOff() {
        model?.forceHostSleepGuardOff()
        refreshStatus()
    }

    @objc private func toggleOpenAtLogin(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        do {
            try LoginItemService.setOpenAtLogin(enabled)
            if !enabled {
                model?.setStartRuntimeAtLogin(false)
            }
        } catch {
            model?.runtimeScreen.log.outputLines.append("[error] Could not update Open at Login: \(error)")
        }
        refreshStatus()
    }

    @objc private func toggleStartRuntimeAtLogin(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        model?.setStartRuntimeAtLogin(enabled)
        if enabled {
            try? LoginItemService.setOpenAtLogin(true)
        }
        refreshStatus()
    }

    @objc private func quitAndStopRuntime() {
        appDelegate?.quitAndStopRuntime()
    }

    @objc private func startDisplaySession(_ sender: NSMenuItem) {
        guard let session = displaySession(from: sender) else { return }
        model?.displayControlMenu.startSession(session)
    }

    @objc private func enterDisplaySession(_ sender: NSMenuItem) {
        guard let session = displaySession(from: sender) else { return }
        model?.displayControlMenu.enterSession(session)
    }

    @objc private func stopDisplaySession(_ sender: NSMenuItem) {
        guard let session = displaySession(from: sender) else { return }
        model?.displayControlMenu.stopSession(session)
    }

    @objc private func reloadDisplaySession(_ sender: NSMenuItem) {
        guard let session = displaySession(from: sender) else { return }
        model?.displayControlMenu.reloadSession(session)
    }

}
