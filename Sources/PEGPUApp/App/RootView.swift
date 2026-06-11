import AppKit
import SwiftUI

struct RootView: View {
    @ObservedObject var model: NativeAppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: NativeAppModel.Tab
    @State private var sidebarCollapsed = UserDefaults.standard.bool(forKey: PreferencesKeys.sidebarCollapsed)
    @State private var externalInputCaptureActive = false
    @State private var displayTitleRefresh = 0

    init(model: NativeAppModel) {
        self.model = model
        _selectedTab = State(initialValue: .section(.runtime))
    }

    var body: some View {
        GeometryReader { proxy in
            let effectiveCollapsed = sidebarCollapsed
            HStack(spacing: 0) {
                SidebarView(
                    monitor: model.sidebarMonitor,
                    displayControlMenu: model.displayControlMenu,
                    externalDisplayCapture: model.externalDisplayCapture,
                    sections: availableSections,
                    shortcuts: model.shortcuts,
                    reloadRuntime: {
                        model.refreshStatus()
                    },
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
        .sheet(isPresented: $model.showingManageMachines) {
            ManageMachinesView(model: model)
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
        .onChange(of: model.runtimeLaunchMode) { _, mode in
            if mode != .gui, selectedTab == .section(.gui) {
                selectedTab = .section(.runtime)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pegpuExternalInputCaptureDidChange)) { notification in
            externalInputCaptureActive = notification.object as? Bool == true
        }
        .onReceive(model.displayControlMenu.objectWillChange) { _ in
            displayTitleRefresh = displayTitleRefresh &+ 1
        }
        .onReceive(model.externalDisplayCapture.objectWillChange) { _ in
            displayTitleRefresh = displayTitleRefresh &+ 1
        }
    }

    private var availableSections: [NativeAppModel.Section] {
        switch model.runtimeLaunchMode {
        case .headless:
            return [.runtime, .files, .models, .chat]
        case .gui:
            return [.runtime, .files, .gui, .models, .chat]
        }
    }

    private var windowTitle: String {
        _ = displayTitleRefresh
        let activeID = model.externalDisplayCapture.captureSessionID ?? model.displayControlMenu.activeSessionID
        let runningSessionShortcuts = model.displayControlMenu.sessions.enumerated()
            .filter { $0.element.running }
            .filter { $0.element.id != activeID }
            .map { "⌥⌘\($0.offset + 2) \($0.element.modelTitle)" }
        if model.externalDisplayCapture.captureActive || externalInputCaptureActive || activeID != nil {
            let items = ["⌥⌘1 - Release"] + runningSessionShortcuts
            return "PEGPU - \(items.joined(separator: " · "))"
        }
        guard !runningSessionShortcuts.isEmpty else { return "PEGPU" }
        return "PEGPU - \(runningSessionShortcuts.joined(separator: " · "))"
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
