import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = NativeAppModel()
    private var tray: AppTrayController?
    private weak var mainWindow: NSWindow?
    private var mainWindowController: NSWindowController?
    private var legalNoticesWindowController: LegalNoticesWindowController?
    private var explicitQuitRequested = false
    private var configured = false
    private var launchStartupHandled = false

    var mainWindowIsVisible: Bool {
        mainWindow?.isVisible == true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configure(model: model)
        startLaunchServicesIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.installHelpMenuItems()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if !NSApplication.shared.windows.contains(where: { $0.canHide }) {
                self.showMainWindow()
            }
        }
    }

    func configure(model: NativeAppModel) {
        guard !configured else { return }
        configured = true
        let tray = AppTrayController(appDelegate: self)
        tray.configure(model: model)
        self.tray = tray
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
        window.title = "vEGPU"
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
            model.shutdownBackgroundServices()
            tray?.invalidate()
            return .terminateNow
        }
        closeToTray()
        return .terminateCancel
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open vEGPU", action: #selector(openFromDockMenu), keyEquivalent: "")
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

    @objc private func showLegalNotices() {
        legalController().show()
    }

    @objc private func revealVEGPUNotices() {
        legalController().revealVEGPUNotices()
    }

    @objc private func revealVEGPUSource() {
        legalController().revealVEGPUSource()
    }

    @objc private func openVEGPUMachine() {
        legalController().openVEGPUMachine()
    }

    @objc private func revealVEGPUMachineNotices() {
        legalController().revealVEGPUMachineNotices()
    }

    private func startLaunchServicesIfNeeded() {
        guard !launchStartupHandled else { return }
        launchStartupHandled = true
        model.refreshStatus()
        model.displayControlMenu.refresh()
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

    private func installHelpMenuItems() {
        guard let mainMenu = NSApplication.shared.mainMenu else { return }
        let helpMenu: NSMenu
        if let existing = mainMenu.item(withTitle: "Help")?.submenu {
            helpMenu = existing
        } else {
            helpMenu = NSMenu(title: "Help")
            let item = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
            item.submenu = helpMenu
            mainMenu.addItem(item)
        }
        guard helpMenu.item(withTitle: "vEGPU Licenses and Notices...") == nil else { return }

        if helpMenu.numberOfItems > 0 {
            helpMenu.addItem(.separator())
        }
        addHelpMenuItem("vEGPU Licenses and Notices...", action: #selector(showLegalNotices), to: helpMenu)
        addHelpMenuItem("Reveal vEGPU Notice Files", action: #selector(revealVEGPUNotices), to: helpMenu)
        addHelpMenuItem("Reveal vEGPU Source Archive", action: #selector(revealVEGPUSource), to: helpMenu)
        helpMenu.addItem(.separator())
        addHelpMenuItem("Open vEGPU Machine", action: #selector(openVEGPUMachine), to: helpMenu)
        addHelpMenuItem("Reveal vEGPU Machine Notices", action: #selector(revealVEGPUMachineNotices), to: helpMenu)
    }

    private func addHelpMenuItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func showStopFailedAlert(error: Error) async -> NSApplication.ModalResponse {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "vEGPU could not stop the runtime cleanly."
            alert.informativeText = [
                "vEGPU tried to stop Linux and close QEMU through the normal control paths, but the runtime process is still running.",
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
            alert.messageText = "vEGPU could not force kill QEMU."
            alert.informativeText = String(describing: error)
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
