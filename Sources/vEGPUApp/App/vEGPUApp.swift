import SwiftUI
import vEGPUCore

@main
struct vEGPUApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("vEGPU") {
            RootView(model: appDelegate.model)
                .background(WindowBinder(appDelegate: appDelegate))
                .frame(minWidth: 760, minHeight: 680)
                .task {
                    appDelegate.configure(model: appDelegate.model)
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About vEGPU") {
                    NSApplication.shared.orderFrontStandardAboutPanel()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Web UI...") {
                    appDelegate.model.showAddWebUI()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Create Routing Route...") {
                    appDelegate.model.showCreateRoutingRoute()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Manage Routing Routes...") {
                    appDelegate.model.showManageRoutingRoutes()
                }
            }
            CommandGroup(replacing: .help) {
                Button("Check for Updates...") {
                    appDelegate.checkForUpdates()
                }
                Button("Use Pre-release Updates") {
                    appDelegate.togglePrereleaseUpdates()
                }
                Button("Install Available Update...") {
                    appDelegate.installAvailableUpdate()
                }
                Divider()
                Button("vEGPU Licenses and Notices...") {
                    appDelegate.showLegalNotices()
                }
                Button("Reveal vEGPU Legal Files") {
                    appDelegate.revealVEGPULegalFiles()
                }
                Button("Export vEGPU Sources...") {
                    appDelegate.exportVEGPUSources()
                }
                Divider()
                Button("Reveal vEGPU Machine Legal Files") {
                    appDelegate.revealVEGPUMachineLegalFiles()
                }
                Button("Export vEGPU Machine Sources...") {
                    appDelegate.exportVEGPUMachineSources()
                }
            }
        }
    }
}
