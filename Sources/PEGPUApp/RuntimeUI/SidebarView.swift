import AppKit
import SwiftUI
import PEGPUCore

struct SidebarView: View {
    let monitor: SidebarMonitorState
    @ObservedObject var displayControlMenu: DisplayControlMenuModel
    let sections: [NativeAppModel.Section]
    let shortcuts: [WebShortcut]
    let reloadRuntime: () -> Void
    let removeWebShortcut: (UUID) -> Void
    @Binding var selectedTab: NativeAppModel.Tab
    @Binding var collapsed: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: collapsed ? .center : .leading, spacing: 14) {
            SidebarBrand(collapsed: collapsed, logoImage: monitor.logoImage) {
                collapsed.toggle()
                UserDefaults.standard.set(collapsed, forKey: PreferencesKeys.sidebarCollapsed)
            }

            ScrollView(.vertical) {
                VStack(alignment: collapsed ? .center : .leading, spacing: 14) {
                    VStack(spacing: collapsed ? 8 : 4) {
                        ForEach(sections) { section in
                            let tab = NativeAppModel.Tab.section(section)
                            SidebarRow(
                                title: section.rawValue,
                                short: section.shortTitle,
                                icon: section.systemImage,
                                selected: selectedTab == tab,
                                collapsed: collapsed,
                                onReload: reloadAction(for: section, tab: tab),
                                displayControlMenu: section == .gui ? displayControlMenu : nil,
                                beforeDisplayMenuAction: section == .gui ? { selectedTab = .section(.gui) } : nil
                            ) {
                                selectedTab = .section(section)
                            }
                        }
                        if !shortcuts.isEmpty {
                            if collapsed {
                                Divider()
                                    .padding(.vertical, 2)
                            } else {
                                Text("Web UIs")
                                    .font(.caption.weight(.heavy))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.top, 4)
                                    .padding(.horizontal, 10)
                            }
                            ForEach(shortcuts) { shortcut in
                                let tab = NativeAppModel.Tab.webShortcut(shortcut.id)
                                SidebarRow(
                                    title: shortcut.title,
                                    short: Self.shortcutShort(shortcut.title),
                                    icon: "globe",
                                    selected: selectedTab == tab,
                                    collapsed: collapsed,
                                    onReload: { reload(tab) },
                                    onRemove: { removeShortcut(shortcut.id) }
                                ) {
                                    selectedTab = .webShortcut(shortcut.id)
                                }
                            }
                        }
                    }
                    if !collapsed {
                        SidebarMonitorPanel(monitor: monitor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: collapsed ? .center : .topLeading)
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.vertical, collapsed ? 12 : 18)
        .padding(.horizontal, collapsed ? 8 : 14)
        .background(AppTheme.sidebarBackground(colorScheme))
    }

    private static func shortcutShort(_ title: String) -> String {
        let words = title.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        let initials = words.prefix(2).compactMap(\.first)
        if !initials.isEmpty {
            return String(initials).uppercased()
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "UI" : String(trimmed.prefix(2)).uppercased()
    }

    private func reload(_ tab: NativeAppModel.Tab) {
        NotificationCenter.default.post(name: .pegpuReloadWebTab, object: nil, userInfo: ["tabID": tab.id])
    }

    private func reloadAction(for section: NativeAppModel.Section, tab: NativeAppModel.Tab) -> (() -> Void)? {
        switch section {
        case .runtime:
            return reloadRuntime
        case .models, .chat:
            return { reload(tab) }
        case .files, .gui:
            return nil
        }
    }

    private func removeShortcut(_ id: UUID) {
        if selectedTab == .webShortcut(id) {
            selectedTab = .section(.models)
        }
        removeWebShortcut(id)
    }
}

private struct SidebarMonitorPanel: View {
    @ObservedObject var monitor: SidebarMonitorState

    var body: some View {
        Divider()
        Text("Monitor")
            .font(.caption.weight(.heavy))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
        SidebarRuntimeMetric(monitor: monitor)
        SidebarMetricCard(
            title: "Mac",
            primary: monitor.hostMetrics.cpu,
            lines: [monitor.hostMetrics.ram, monitor.hostMetrics.net, monitor.hostMetrics.disk, monitor.hostMetrics.gpu],
            bar: monitor.hostMetrics.bar,
            barKind: .mac,
            gpuMetrics: monitor.hostGpuWidgets
        )
        SidebarMetricCard(
            title: "VM",
            primary: monitor.vmMetrics.cpu,
            lines: [monitor.vmMetrics.ram, monitor.vmMetrics.net, monitor.vmMetrics.disk],
            bar: monitor.vmMetrics.bar,
            barKind: .vm,
            gpuMetrics: monitor.nvidiaGpuWidgets
        )
        SidebarMetricCard(title: "Total Power", primary: monitor.powerMetric.total, lines: [monitor.powerMetric.detail], bar: monitor.powerMetric.percent, barKind: .power)
    }
}

private struct SidebarBrand: View {
    let collapsed: Bool
    let logoImage: NSImage?
    let toggle: () -> Void

    var body: some View {
        if collapsed {
            VStack(spacing: 7) {
                BrandMark(logoImage: logoImage)
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .frame(width: 34, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Expand sidebar")
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 12) {
                BrandMark(logoImage: logoImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PEGPU")
                        .font(.system(size: 22, weight: .bold))
                    Text("VM AI runtime")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: toggle) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Collapse sidebar")
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
    }
}

private struct BrandMark: View {
    let logoImage: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.logoBackground(colorScheme))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border(colorScheme), lineWidth: 1))
            if let image = logoImage {
                logo(image)
            } else {
                Text("PE")
                    .font(.headline.weight(.heavy))
            }
        }
        .frame(width: 38, height: 38)
    }

    @ViewBuilder
    private func logo(_ image: NSImage) -> some View {
        if colorScheme == .dark {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .colorInvert()
                .saturation(0)
                .contrast(0.9)
                .opacity(0.92)
                .padding(4)
        } else {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(4)
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let short: String
    let icon: String
    let selected: Bool
    let collapsed: Bool
    var onReload: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    var displayControlMenu: DisplayControlMenuModel? = nil
    var beforeDisplayMenuAction: (() -> Void)? = nil
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    var body: some View {
        if let displayControlMenu {
            row
                .contextMenu {
                    DisplayControlMenuItems(
                        model: displayControlMenu,
                        beforeAction: beforeDisplayMenuAction,
                        deferAfterBeforeAction: beforeDisplayMenuAction != nil
                    )
                }
                .help(title)
        } else if onReload == nil && onRemove == nil {
            row.help(title)
        } else {
            row
                .contextMenu {
                    if let onReload {
                        Button("Reload", action: onReload)
                    }
                    if let onRemove {
                        Button("Remove", role: .destructive, action: onRemove)
                    }
                }
                .help(title)
        }
    }

    private var row: some View {
        Button(action: action) {
            if collapsed {
                Text(short)
                    .font(.caption.weight(.heavy))
                    .frame(width: 40, height: 38)
                    .background(selected ? AppTheme.selectedBackground(colorScheme) : AppTheme.cardBackground(colorScheme))
                    .foregroundStyle(selected ? AppTheme.selectedForeground(colorScheme) : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.border(colorScheme), lineWidth: selected ? 0 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .frame(width: 18)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .padding(.horizontal, 10)
                .background(selected ? AppTheme.selectedBackground(colorScheme) : Color.clear)
                .foregroundStyle(selected ? AppTheme.selectedForeground(colorScheme) : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

private extension NativeAppModel.Section {
    var shortTitle: String {
        switch self {
        case .runtime: return "R"
        case .files: return "F"
        case .gui: return "G"
        case .models: return "M"
        case .chat: return "C"
        }
    }

    var systemImage: String {
        switch self {
        case .runtime: return "bolt.horizontal.circle"
        case .files: return "folder"
        case .gui: return "display"
        case .models: return "square.stack.3d.up"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }

    var isWebTab: Bool {
        switch self {
        case .models, .chat: return true
        case .runtime, .files, .gui: return false
        }
    }
}

private struct SidebarRuntimeMetric: View {
    @ObservedObject var monitor: SidebarMonitorState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.runtimeStatus)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(monitor.runtimeDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(AppTheme.cardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.border(colorScheme, opacity: 0.55), lineWidth: 1))
    }

    private var statusColor: Color {
        switch monitor.runtimeState {
        case "running": return .green
        case "booting": return .orange
        case "stopped": return .red
        default: return .red
        }
    }
}

private struct SidebarMetricCard: View {
    let title: String
    let primary: String
    let lines: [String]
    let bar: Double?
    let barKind: MetricBarKind
    var gpuMetrics: [GpuWidgetMetric] = []
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text(primary)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .truncationMode(.tail)
            }
            if let bar {
                MetricBarView(value: bar, kind: barKind)
            }
            ForEach(lines.filter { !$0.isEmpty }, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(gpuMetrics) { gpu in
                SidebarGpuMiniCard(metric: gpu)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(AppTheme.cardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.border(colorScheme, opacity: 0.55), lineWidth: 1))
    }
}

private struct SidebarGpuMiniCard: View {
    let metric: GpuWidgetMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(metric.title)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(metric.primary) load")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            Text(metric.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            ForEach(metric.lines.filter { !$0.isEmpty }, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            MetricBarView(value: metric.percent ?? 0, kind: metric.source == "nvidia" ? .vm : .mac)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.55))
                .frame(height: 1)
        }
    }
}

private enum MetricBarKind {
    case mac
    case vm
    case power

    var gradient: LinearGradient {
        switch self {
        case .mac:
            return LinearGradient(colors: [Color(red: 0.18, green: 0.65, blue: 0.44), Color(red: 0.30, green: 0.52, blue: 0.91)], startPoint: .leading, endPoint: .trailing)
        case .vm:
            return LinearGradient(colors: [Color(red: 0.78, green: 0.51, blue: 0.08), Color(red: 0.30, green: 0.52, blue: 0.91)], startPoint: .leading, endPoint: .trailing)
        case .power:
            return LinearGradient(colors: [Color(red: 0.18, green: 0.65, blue: 0.44), Color(red: 0.78, green: 0.51, blue: 0.08), Color(red: 0.83, green: 0.20, blue: 0.18)], startPoint: .leading, endPoint: .trailing)
        }
    }
}

private struct MetricBarView: View {
    let value: Double
    let kind: MetricBarKind
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                Capsule()
                    .fill(kind.gradient)
                    .frame(width: geometry.size.width * CGFloat(max(0, min(100, value)) / 100))
            }
        }
        .frame(height: 5)
    }

    private var trackColor: Color {
        colorScheme == .dark ? Color(red: 0.16, green: 0.155, blue: 0.145) : Color(nsColor: .separatorColor).opacity(0.22)
    }
}
