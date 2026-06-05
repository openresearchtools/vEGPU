import AppKit
import vEGPUCore

@MainActor
final class AppTrayController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var appDelegate: AppDelegate?
    private weak var model: NativeAppModel?
    private var globalHotkeys: DisplayGlobalHotkeyService?
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
        if globalHotkeys == nil {
            let globalHotkeys = DisplayGlobalHotkeyService(displayControl: model.displayControlMenu)
            globalHotkeys.start()
            self.globalHotkeys = globalHotkeys
        }
        updateMenu()
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
        globalHotkeys?.invalidate()
        globalHotkeys = nil
        model?.stopHostSleepGuardForShutdown()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureIcon() {
        statusItem.button?.toolTip = "vEGPU"
        let root = AppPaths.discoverRoot()
        let trayURL = root.appendingPathComponent("Resources/Assets/vEGPU-tray.png")
        let image = NSImage(contentsOf: trayURL) ?? NSImage(named: "vEGPU")
        image?.size = NSSize(width: 19, height: 19)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
    }

    private func refreshStatus() {
        guard let model else { return }
        Task {
            let next = await model.machineStatusText()
            model.refreshHostSleepGuard()
            await MainActor.run {
                self.statusText = next
                self.updateMenu()
            }
        }
    }

    private func updateMenu() {
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(disabled("vEGPU: \(statusText)"))
        menu.addItem(.separator())
        menu.addItem(item("Open vEGPU", #selector(openApp)))
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

        menu.addItem(.separator())
        menu.addItem(disabled(model?.updates.statusText ?? "Updates not checked"))
        let prerelease = item("Use Pre-release Updates", #selector(togglePrereleaseUpdates(_:)))
        prerelease.state = model?.updates.channel == .prerelease ? .on : .off
        prerelease.isEnabled = model?.updates.isChecking != true && model?.updates.isDownloading != true
        menu.addItem(prerelease)
        let checkUpdates = item("Check for Updates", #selector(checkForUpdates))
        checkUpdates.isEnabled = model?.updates.isChecking != true && model?.updates.isDownloading != true
        menu.addItem(checkUpdates)
        if let update = model?.updates.availableUpdate {
            let installUpdate = item("Update to v\(update.version)...", #selector(installAvailableUpdate))
            installUpdate.isEnabled = model?.updates.isDownloading != true
            menu.addItem(installUpdate)
        }

        menu.addItem(item("Quit and Stop Runtime...", #selector(quitAndStopRuntime)))
        return menu
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

    @objc private func checkForUpdates() {
        model?.checkForUpdates(silent: false)
        refreshStatus()
    }

    @objc private func togglePrereleaseUpdates(_ sender: NSMenuItem) {
        model?.togglePrereleaseUpdates()
        refreshStatus()
    }

    @objc private func installAvailableUpdate() {
        appDelegate?.installAvailableUpdate()
    }
}
