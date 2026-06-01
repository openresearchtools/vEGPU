import AppKit
import vEGPUCore

@MainActor
final class AppTrayController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var appDelegate: AppDelegate?
    private weak var model: NativeAppModel?
    private var statusText = "checking"
    private var timer: Timer?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
        configureIcon()
    }

    func configure(model: NativeAppModel) {
        self.model = model
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

        menu.addItem(.separator())
        let openAtLogin = item("Open at Login", #selector(toggleOpenAtLogin(_:)))
        openAtLogin.state = LoginItemService.openAtLogin ? .on : .off
        menu.addItem(openAtLogin)

        let startAtLogin = item("Start Runtime at Login", #selector(toggleStartRuntimeAtLogin(_:)))
        startAtLogin.state = model?.configStore.load().startRuntimeAtLogin == true ? .on : .off
        menu.addItem(startAtLogin)

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
}
