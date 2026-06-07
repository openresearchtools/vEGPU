import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let developerOptionsMenuItemTag = 0x5045_4744

    let model = NativeAppModel()
    private var tray: AppTrayController?
    private var batterySafetyMonitor: BatteryRuntimeSafetyMonitor?
    private weak var mainWindow: NSWindow?
    private var mainWindowController: NSWindowController?
    private var legalNoticesWindowController: LegalNoticesWindowController?
    private var localNetworkPermission: LocalNetworkPermissionService?
    private var explicitQuitRequested = false
    private var configured = false
    private var launchStartupHandled = false

    var mainWindowIsVisible: Bool {
        mainWindow?.isVisible == true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configure(model: model)
        configureHelpMenu()
        configureViewMenu()
        DispatchQueue.main.async { [weak self] in
            self?.configureHelpMenu()
            self?.configureViewMenu()
        }
        startLaunchServicesIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if !NSApplication.shared.windows.contains(where: { $0.canHide }) {
                self.showMainWindow()
            }
        }
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        configureHelpMenu()
        configureViewMenu()
    }

    func configure(model: NativeAppModel) {
        guard !configured else { return }
        configured = true
        let tray = AppTrayController(appDelegate: self)
        tray.configure(model: model)
        self.tray = tray
        let localNetworkPermission = LocalNetworkPermissionService(progress: model.progress)
        localNetworkPermission.start()
        self.localNetworkPermission = localNetworkPermission
        let batterySafetyMonitor = BatteryRuntimeSafetyMonitor(model: model) { [weak self] in
            self?.tray?.screenAnchorRect
        }
        batterySafetyMonitor.start()
        self.batterySafetyMonitor = batterySafetyMonitor
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func attach(window: NSWindow) {
        if let mainWindow, mainWindow !== window {
            window.delegate = nil
            window.orderOut(nil)
            window.close()
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }
        mainWindow = window
        window.delegate = self
        window.title = "PEGPU"
        window.minSize = NSSize(width: 760, height: 680)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if explicitQuitRequested {
            batterySafetyMonitor?.invalidate()
            model.shutdownBackgroundServices()
            tray?.invalidate()
            return .terminateNow
        }
        closeToTray()
        return .terminateCancel
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open PEGPU", action: #selector(openFromDockMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let close = NSMenuItem(title: "Close to Tray", action: #selector(closeFromDockMenu), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeToTray()
        return false
    }

    func closeToTray() {
        for window in NSApplication.shared.windows where window.canHide {
            window.orderOut(nil)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func showMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            if let window = NSApplication.shared.windows.first(where: { $0.canHide }) {
                attach(window: window)
                window.makeKeyAndOrderFront(nil)
            } else {
                let window = makeMainWindow()
                attach(window: window)
                window.makeKeyAndOrderFront(nil)
            }
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func quitAndStopRuntime() {
        Task {
            do {
                try await model.quitAndStopRuntime()
                explicitQuitRequested = true
                NSApplication.shared.terminate(nil)
            } catch {
                showMainWindow()
                let result = await showStopFailedAlert(error: error)
                if result == .alertSecondButtonReturn {
                    do {
                        try await model.machineService.forceKillMachineProcess()
                        model.shutdownBackgroundServices()
                        explicitQuitRequested = true
                        NSApplication.shared.terminate(nil)
                    } catch {
                        await showForceKillFailedAlert(error: error)
                    }
                }
            }
        }
    }

    @objc private func openFromDockMenu() {
        showMainWindow()
    }

    @objc private func closeFromDockMenu() {
        closeToTray()
    }

    @objc private func workspaceDidWake() {
        model.repairAfterWake()
    }

    @objc func openPEGPUHelp() {
        guard let url = URL(string: "https://pegpu.com") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func showLegalNotices() {
        legalController().showNotices()
    }

    @objc func showLegalLicenses() {
        legalController().showLicenses()
    }

    @objc func showGuestVMInstallNotices() {
        legalController().showGuestVMInstallNotices()
    }

    @objc func showMachineLegalNotices() {
        legalController().showMachineNotices()
    }

    @objc func showMachineLegalLicenses() {
        legalController().showMachineLicenses()
    }

    @objc func checkForUpdates() {
        Task {
            await model.updates.checkForUpdates(silent: false)
            await showUpdateStatusAlert()
        }
    }

    @objc func togglePrereleaseUpdates() {
        model.togglePrereleaseUpdates()
    }

    @objc func installAvailableUpdate() {
        Task {
            await installAvailableUpdateFlow()
        }
    }

    @objc private func toggleDeveloperOptions(_ sender: NSMenuItem) {
        model.showDeveloperOptions.toggle()
        sender.state = developerOptionsMenuState()
    }

    private func startLaunchServicesIfNeeded() {
        guard !launchStartupHandled else { return }
        launchStartupHandled = true
        model.refreshStatus()
        model.displayControlMenu.refresh()
        model.checkForUpdates(silent: true)
        model.startPolling()
        model.startBackgroundServices()

        let config = model.configStore.load()
        if config.startRuntimeAtLogin {
            model.startRuntime(config: config)
        }
    }

    private func makeMainWindow() -> NSWindow {
        let controller = NSHostingController(
            rootView: RootView(model: model)
                .frame(minWidth: 760, minHeight: 680)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.center()
        let windowController = NSWindowController(window: window)
        mainWindowController = windowController
        return window
    }

    private func legalController() -> LegalNoticesWindowController {
        if let legalNoticesWindowController {
            return legalNoticesWindowController
        }
        let controller = LegalNoticesWindowController()
        legalNoticesWindowController = controller
        return controller
    }

    private func configureViewMenu() {
        guard let viewMenu = NSApplication.shared.mainMenu?.items.first(where: { $0.title == "View" })?.submenu else {
            return
        }
        for item in viewMenu.items where item.tag == Self.developerOptionsMenuItemTag || item.action == #selector(toggleDeveloperOptions(_:)) {
            viewMenu.removeItem(item)
        }

        let item = NSMenuItem(title: "Developer Options", action: #selector(toggleDeveloperOptions(_:)), keyEquivalent: "")
        item.target = self
        item.tag = Self.developerOptionsMenuItemTag
        item.isEnabled = true
        item.state = developerOptionsMenuState()

        let insertionIndex = viewMenu.items.firstIndex { $0.title == "Enter Full Screen" } ?? viewMenu.numberOfItems
        viewMenu.insertItem(item, at: insertionIndex)
    }

    private func developerOptionsMenuState() -> NSControl.StateValue {
        model.showDeveloperOptions ? .on : .off
    }

    private func configureHelpMenu() {
        let helpMenu = NSMenu(title: "Help")
        helpMenu.autoenablesItems = false
        helpMenu.addItem(helpMenuItem(title: "PEGPU Help", action: #selector(openPEGPUHelp)))
        helpMenu.addItem(.separator())
        helpMenu.addItem(helpMenuItem(title: "Notices", action: #selector(showLegalNotices)))
        helpMenu.addItem(helpMenuItem(title: "Licenses", action: #selector(showLegalLicenses)))
        helpMenu.addItem(helpMenuItem(title: "VM Install Notices", action: #selector(showGuestVMInstallNotices)))
        helpMenu.addItem(externalHelpMenuItem(title: "PEGPU Machine Notices", action: #selector(showMachineLegalNotices)))
        helpMenu.addItem(externalHelpMenuItem(title: "PEGPU Machine Licenses", action: #selector(showMachineLegalLicenses)))

        guard let mainMenu = NSApplication.shared.mainMenu else {
            NSApplication.shared.helpMenu = helpMenu
            return
        }
        if let existingHelpItem = mainMenu.items.first(where: { item in
            item.title == "Help" || item.submenu === NSApplication.shared.helpMenu
        }) {
            existingHelpItem.title = "Help"
            existingHelpItem.submenu = helpMenu
        } else {
            let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
            helpItem.submenu = helpMenu
            mainMenu.addItem(helpItem)
        }
        NSApplication.shared.helpMenu = helpMenu
    }

    private func helpMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    private func externalHelpMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = helpMenuItem(title: "[EXTERNAL] \(title)", action: action)
        item.attributedTitle = externalHelpMenuTitle(title)
        return item
    }

    private func externalHelpMenuTitle(_ title: String) -> NSAttributedString {
        let attributedTitle = NSMutableAttributedString()
        attributedTitle.append(NSAttributedString(
            string: " EXTERNAL ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: externalBadgeForegroundColor(),
                .backgroundColor: externalBadgeBackgroundColor(),
                .baselineOffset: 1
            ]
        ))
        attributedTitle.append(NSAttributedString(
            string: " \(title)",
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor
            ]
        ))
        return attributedTitle
    }

    private func externalBadgeForegroundColor() -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(calibratedWhite: 0.92, alpha: 1.0)
                : NSColor(calibratedWhite: 0.28, alpha: 1.0)
        } ?? NSColor.secondaryLabelColor
    }

    private func externalBadgeBackgroundColor() -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(calibratedWhite: 0.24, alpha: 1.0)
                : NSColor(calibratedWhite: 0.86, alpha: 1.0)
        } ?? NSColor(calibratedWhite: 0.86, alpha: 1.0)
    }

    private func installAvailableUpdateFlow() async {
        do {
            let update = try await model.updates.refreshAndReturnAvailableUpdate()
            guard let update else {
                await showPlainAlert(title: "PEGPU is up to date.", message: model.updates.statusText)
                return
            }
            guard await confirmUpdate(update) else { return }
            let packageURL = try await model.updates.downloadPackage(for: update)
            try await stopRuntimeForUpdate()
            try await closePEGPUMachineForUpdate()
            try model.updates.openInstaller(packageURL: packageURL)
            explicitQuitRequested = true
            NSApplication.shared.terminate(nil)
        } catch {
            showMainWindow()
            await showPlainAlert(title: "Update failed.", message: String(describing: error), style: .critical)
        }
    }

    private func stopRuntimeForUpdate() async throws {
        do {
            try await model.quitAndStopRuntime()
        } catch {
            showMainWindow()
            let result = await showStopFailedAlert(error: error)
            guard result == .alertSecondButtonReturn else {
                throw error
            }
            try await model.machineService.forceKillMachineProcess()
            model.shutdownBackgroundServices()
        }
    }

    private func closePEGPUMachineForUpdate() async throws {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.pegpu.machine")
        guard !apps.isEmpty else { return }
        for app in apps {
            app.terminate()
        }
        for _ in 0..<50 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.pegpu.machine").isEmpty {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw RuntimeUpdateFlowError.message("PEGPU Machine.app is still running. Close it and run the update again.")
    }

    private func showUpdateStatusAlert() async {
        if let update = model.updates.availableUpdate {
            await showPlainAlert(
                title: "PEGPU \(update.version) is available.",
                message: "The update package will be downloaded and opened in Installer.app."
            )
        } else {
            await showPlainAlert(title: "Update Check", message: model.updates.statusText)
        }
    }

    private func confirmUpdate(_ update: AppUpdateService.Entry) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Install PEGPU \(update.version)?"
            alert.informativeText = [
                "PEGPU will shut down any running VM/runtime, close PEGPU Machine.app if it is open, open \(update.packageName) in Installer.app, and then quit.",
                "",
                "The installer remains the user-approved path for replacing app files, refreshing PEGPU Machine, and handling DriverKit approval or reboot prompts."
            ].joined(separator: "\n")
            alert.addButton(withTitle: "Download and Open Installer")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private func showPlainAlert(title: String, message: String, style: NSAlert.Style = .informational) async {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = style
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func showStopFailedAlert(error: Error) async -> NSApplication.ModalResponse {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "PEGPU could not stop the runtime cleanly."
            alert.informativeText = [
                "PEGPU tried to stop Linux and close QEMU through the normal control paths, but the runtime process is still running.",
                "",
                "Force killing QEMU may cause a macOS kernel panic or crash if a PCIe/eGPU device is still active. Save your work before confirming.",
                "",
                String(describing: error)
            ].joined(separator: "\n")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Force Kill QEMU")
            return alert.runModal()
        }
    }

    private func showForceKillFailedAlert(error: Error) async {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "PEGPU could not force kill QEMU."
            alert.informativeText = String(describing: error)
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

private enum RuntimeUpdateFlowError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): return message
        }
    }
}
