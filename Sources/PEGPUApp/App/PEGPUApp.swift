import SwiftUI
import PEGPUCore

@main
struct PEGPUApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("PEGPU") {
            RootView(model: appDelegate.model)
                .background(WindowBinder(appDelegate: appDelegate))
                .frame(minWidth: 760, minHeight: 680)
                .textSelection(.enabled)
                .task {
                    appDelegate.configure(model: appDelegate.model)
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About PEGPU") {
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
            CommandGroup(after: .sidebar) {
                Toggle("Developer Options", isOn: Binding(
                    get: { appDelegate.model.showDeveloperOptions },
                    set: { appDelegate.model.showDeveloperOptions = $0 }
                ))
            }
        }
    }
}
