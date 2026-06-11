import AppKit
import Combine
import PEGPUCore

@MainActor
final class AppTrayController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var appDelegate: AppDelegate?
    private weak var model: NativeAppModel?
    private var profileObserver: NSObjectProtocol?
    private var displayControlObserver: AnyCancellable?
    private var externalCaptureObserver: AnyCancellable?
    private var displayHotkeys: DisplayHotkeyService?
    private var menuUpdateScheduled = false
    private var statusHintIndex = 0
    private var statusHintSignature = ""
    private var statusHintTimer: Timer?
    private var statusText = "checking"
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
        bindDisplayControlMenu(model.displayControlMenu)
        bindExternalCapture(model.externalDisplayCapture)
        startDisplayHotkeysIfNeeded()
        if profileObserver == nil {
            profileObserver = NotificationCenter.default.addObserver(
                forName: .pegpuMachineProfileDidSwitch,
                object: model,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let model = self.model else { return }
                    self.bindDisplayControlMenu(model.displayControlMenu)
                    self.bindExternalCapture(model.externalDisplayCapture)
                    self.updateMenu()
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
        statusHintTimer?.invalidate()
        statusHintTimer = nil
        if let profileObserver {
            NotificationCenter.default.removeObserver(profileObserver)
        }
        profileObserver = nil
        displayControlObserver = nil
        externalCaptureObserver = nil
        displayHotkeys?.invalidate()
        displayHotkeys = nil
        model?.stopHostSleepGuardForShutdown()
        NSStatusBar.system.removeStatusItem(statusItem)
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
        guard let button = statusItem.button else { return }
        let hints = statusShortcutHints()
        let signature = hints.joined(separator: "\u{1F}")
        if signature != statusHintSignature {
            statusHintSignature = signature
            statusHintIndex = 0
        }

        guard !hints.isEmpty else {
            statusItem.length = NSStatusItem.squareLength
            button.imagePosition = .imageOnly
            button.title = ""
            updateStatusHintTimer(hintCount: 0)
            return
        }

        if statusHintIndex >= hints.count {
            statusHintIndex = 0
        }
        statusItem.length = NSStatusItem.variableLength
        button.imagePosition = .imageLeading
        button.title = " \(hints[statusHintIndex])"
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.toolTip = "PEGPU"
        updateStatusHintTimer(hintCount: hints.count)
    }

    private func statusShortcutHints() -> [String] {
        guard let model else { return [] }
        let displayControl = model.displayControlMenu
        let activeID = model.externalDisplayCapture.captureSessionID ?? displayControl.activeSessionID
        let runningSessionShortcuts = displayControl.sessions.enumerated()
            .filter { $0.element.running }
            .filter { $0.element.id != activeID }
            .map { "⌥⌘\($0.offset + 2) \($0.element.modelTitle)" }
        if model.externalDisplayCapture.captureActive || activeID != nil {
            return ["⌥⌘1 - Release"] + runningSessionShortcuts
        }
        return runningSessionShortcuts
    }

    private func updateStatusHintTimer(hintCount: Int) {
        guard hintCount > 1 else {
            statusHintTimer?.invalidate()
            statusHintTimer = nil
            statusHintIndex = 0
            return
        }
        guard statusHintTimer == nil else { return }
        statusHintTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let hints = self.statusShortcutHints()
                guard hints.count > 1 else {
                    self.updateStatusItemPresentation()
                    return
                }
                self.statusHintIndex = (self.statusHintIndex + 1) % hints.count
                self.updateStatusItemPresentation()
            }
        }
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
        updateStatusItemPresentation()
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        menu.addItem(disabled("PEGPU: \(statusText)"))
        if let warning = displayHotkeys?.registrationWarning {
            menu.addItem(disabled(warning))
        }
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
            if model?.externalDisplayCapture.captureActive == true {
                let release = item("⌥⌘1 - Release eGPU Display Capture", #selector(releaseDisplayCapture))
                release.isEnabled = true
                menu.addItem(release)
            }
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

    private func bindExternalCapture(_ externalCapture: ExternalDisplayCaptureCoordinator) {
        externalCaptureObserver = externalCapture.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleMenuUpdate()
            }
        }
    }

    private func startDisplayHotkeysIfNeeded() {
        guard displayHotkeys == nil else { return }
        let service = DisplayHotkeyService { [weak self] digit in
            self?.model?.externalDisplayCapture.handleHotkey(digit: digit)
        }
        displayHotkeys = service
        service.start()
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
            let shortcut = "⌥⌘\(offset + 2)"
            if session.running {
                let stop = displaySessionItem("Stop \(session.title) (\(shortcut))", #selector(stopDisplaySession(_:)), session: session)
                stop.isEnabled = !displayControl.busy
                menu.addItem(stop)

                let reload = displaySessionItem("Reload \(session.title)", #selector(reloadDisplaySession(_:)), session: session)
                reload.isEnabled = !displayControl.busy
                menu.addItem(reload)
            } else {
                let start = displaySessionItem(
                    "Start \(session.title) on eGPU Display (\(shortcut))",
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

    @objc private func releaseDisplayCapture() {
        model?.externalDisplayCapture.releaseCapture()
    }

    @objc private func startDisplaySession(_ sender: NSMenuItem) {
        guard let session = displaySession(from: sender) else { return }
        model?.externalDisplayCapture.capture(session: session)
    }

    @objc private func stopDisplaySession(_ sender: NSMenuItem) {
        guard let session = displaySession(from: sender) else { return }
        model?.externalDisplayCapture.forceReleaseIfCapturing(sessionID: session.id)
        model?.displayControlMenu.stopSession(session)
    }

    @objc private func reloadDisplaySession(_ sender: NSMenuItem) {
        guard let session = displaySession(from: sender) else { return }
        model?.externalDisplayCapture.forceReleaseIfCapturing(sessionID: session.id)
        model?.displayControlMenu.reloadSession(session)
    }

}
