import AppKit
import SwiftUI
import vEGPUCore

struct RootView: View {
    @ObservedObject var model: NativeAppModel
    @ObservedObject private var displayControl: DisplayControlMenuModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: NativeAppModel.Tab
    @State private var sidebarCollapsed = UserDefaults.standard.bool(forKey: PreferencesKeys.sidebarCollapsed)

    init(model: NativeAppModel) {
        self.model = model
        self.displayControl = model.displayControlMenu
        _selectedTab = State(initialValue: .section(.runtime))
    }

    var body: some View {
        GeometryReader { proxy in
            let effectiveCollapsed = sidebarCollapsed
            HStack(spacing: 0) {
                SidebarView(
                    monitor: model.sidebarMonitor,
                    displayControlMenu: model.displayControlMenu,
                    sections: availableSections,
                    shortcuts: model.shortcuts,
                    removeWebShortcut: { id in
                        model.removeWebShortcut(id: id)
                    },
                    selectedTab: $selectedTab,
                    collapsed: Binding(
                        get: { effectiveCollapsed },
                        set: { value in
                            sidebarCollapsed = value
                            UserDefaults.standard.set(value, forKey: PreferencesKeys.sidebarCollapsed)
                        }
                    )
                )
                .frame(width: effectiveCollapsed ? 64 : 248)
                .layoutPriority(1)
                Divider()
                PersistentTabHost(model: model, selectedTab: $selectedTab)
                    .frame(width: max(0, proxy.size.width - (effectiveCollapsed ? 65 : 249)), height: proxy.size.height)
                    .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .background(AppTheme.windowBackground(colorScheme))
        .background(WindowTitleShortcutBinder(title: windowTitle))
        .tint(AppTheme.tint(colorScheme))
        .sheet(isPresented: $model.showingAddWebUI) {
            AddWebUIView(model: model)
        }
        .sheet(isPresented: $model.showingCreateRoutingRoute) {
            CreateRoutingRouteView(model: model)
        }
        .sheet(isPresented: $model.showingManageRoutingRoutes) {
            ManageRoutingRoutesView(model: model)
        }
        .task {
            model.setActiveTab(selectedTab)
            model.refreshStatus()
            model.displayControlMenu.refresh()
            model.startPolling()
            model.startBackgroundServices()
        }
        .onChange(of: selectedTab) { _, tab in
            model.setActiveTab(tab)
        }
        .onAppear {
            syncExternalCapture(mode: model.runtimeLaunchMode, activeSessionID: displayControl.activeSessionID)
        }
        .onChange(of: model.runtimeLaunchMode) { _, mode in
            if mode != .gui, selectedTab.isGUIRuntimeSection {
                selectedTab = .section(.runtime)
            }
            syncExternalCapture(mode: mode, activeSessionID: displayControl.activeSessionID)
        }
        .onChange(of: displayControl.activeSessionID) { _, activeSessionID in
            syncExternalCapture(mode: model.runtimeLaunchMode, activeSessionID: activeSessionID)
        }
        .overlay {
            ExternalInputCaptureView(session: model.spiceSession)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    private var availableSections: [NativeAppModel.Section] {
        switch model.runtimeLaunchMode {
        case .headless:
            return [.runtime, .files, .models, .chat]
        case .gui:
            return [.runtime, .files, .gui, .externalDisplays, .models, .chat]
        }
    }

    private var windowTitle: String {
        guard selectedTab.isGUIRuntimeSection, !displayControl.sessions.isEmpty else { return "vEGPU" }
        var parts = ["Option-Cmd-1 Release"]
        parts += displayControl.sessions.enumerated().map { index, _ in
            "Option-Cmd-\(index + 2) External \(index + 1)"
        }
        let prefix = displayControl.activeSessionID == nil ? "vEGPU" : "vEGPU - Captured"
        return "\(prefix) - \(parts.joined(separator: " · "))"
    }

    private func syncExternalCapture(mode: RuntimeLaunchMode, activeSessionID: String?) {
        model.spiceSession.setDynamicResolutionEnabled(true)
        guard mode == .gui, activeSessionID != nil else {
            model.spiceSession.setExternalInputCapture(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if model.runtimeLaunchMode == .gui, displayControl.activeSessionID != nil {
                model.spiceSession.start()
                model.spiceSession.setExternalInputCapture(true)
            }
        }
    }
}

private extension NativeAppModel.Tab {
    var isGUIRuntimeSection: Bool {
        switch self {
        case .section(.gui), .section(.externalDisplays):
            return true
        default:
            return false
        }
    }
}

private struct WindowTitleShortcutBinder: NSViewRepresentable {
    let title: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.apply(title, from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.apply(title, from: nsView)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?

        func apply(_ title: String, from view: NSView) {
            guard let window = view.window else { return }
            self.window = window
            if window.title != title {
                window.title = title
            }
        }
    }
}
