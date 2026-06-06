import SwiftUI
import PEGPUCore

struct DriverCardsView: View {
    let model: NativeAppModel
    @ObservedObject var drivers: RuntimeDriverState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                DriverStatusCard(state: drivers.pcieDriver) {
                    model.toggleMacOSDriver()
                }
                DriverStatusCard(state: drivers.linuxDriver) {
                    model.reinstallLinuxDriver()
                }
                NvidiaStatusCard(state: drivers.nvidiaDriver, output: drivers.nvidiaOutput) {
                    model.requestNvidiaInstall()
                }
            }
            if !drivers.nvidiaGpus.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(drivers.nvidiaGpus, id: \.widgetID) { gpu in
                        NvidiaGpuMetricCard(gpu: gpu)
                    }
                }
            }
        }
    }
}

private struct DriverStatusCard: View {
    let state: DriverCardState
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(state.title)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if let actionTitle = state.actionTitle {
                    Button(action: action) {
                        HitTargetLabel(actionTitle, minWidth: 74, minHeight: 22)
                    }
                        .controlSize(.small)
                        .disabled(!state.actionEnabled)
                }
            }
            Text(state.status)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(state.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .padding(12)
        .padding(.leading, 4)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.panelBackground(colorScheme))
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(statusColor)
                .frame(width: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border(colorScheme, opacity: 0.6), lineWidth: 1))
    }

    private var statusColor: Color {
        switch state.state {
        case "ready":
            return .green
        case "booting", "working":
            return .orange
        case "stopped":
            return .secondary
        default:
            return .red
        }
    }
}

private struct NvidiaStatusCard: View {
    let state: DriverCardState
    let output: String
    let action: () -> Void
    @State private var showNotice = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(state.title)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Button {
                    showNotice.toggle()
                } label: {
                    CircleHitTargetLabel("i", size: 22)
                }
                .controlSize(.small)
                .buttonStyle(.plain)
                .clipShape(Circle())
                .popover(isPresented: $showNotice) {
                    Text(NvidiaInstallCopy.cardNotice)
                        .font(.caption)
                        .padding(12)
                        .frame(width: 260)
                }
                Spacer()
                if let actionTitle = state.actionTitle {
                    Button(action: action) {
                        HitTargetLabel(actionTitle, minWidth: 84, minHeight: 22)
                    }
                        .controlSize(.small)
                        .disabled(!state.actionEnabled)
                }
            }
            Text(state.status)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(state.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if !output.isEmpty {
                ScrollView(.horizontal) {
                    Text(output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 72)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .padding(12)
        .padding(.leading, 4)
        .contextMenu {
            Button(state.state == "ready" ? "Reinstall NVIDIA Driver" : "Run Installer") {
                action()
            }
            .disabled(!state.actionEnabled)
        }
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.panelBackground(colorScheme))
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(statusColor)
                .frame(width: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border(colorScheme, opacity: 0.6), lineWidth: 1))
    }

    private var statusColor: Color {
        switch state.state {
        case "ready":
            return .green
        case "booting", "working":
            return .orange
        case "stopped":
            return .secondary
        default:
            return state.state == "missing" ? .orange : .red
        }
    }
}

private struct NvidiaGpuMetricCard: View {
    let gpu: NvidiaGpuMetric
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(gpu.index.map { "NVIDIA GPU \($0)" } ?? "NVIDIA GPU")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text(formatPercent(gpu.utilizationPercent))
                    .font(.title3.weight(.semibold))
            }
            Text(gpu.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let util = gpu.utilizationPercent {
                ProgressView(value: max(0, min(100, util)), total: 100)
                    .progressViewStyle(.linear)
            }
            Text(memoryLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(temperatureLine) / \(powerLine)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !gpu.driverVersion.isEmpty {
                Text("Driver \(gpu.driverVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .padding(12)
        .background(AppTheme.panelBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border(colorScheme, opacity: 0.6), lineWidth: 1))
    }

    private var memoryLine: String {
        guard let used = gpu.memoryUsedMiB, let total = gpu.memoryTotalMiB, total > 0 else { return "VRAM unavailable" }
        return "VRAM \(Int(used.rounded())) / \(Int(total.rounded())) MiB"
    }

    private var temperatureLine: String {
        gpu.temperatureC.map { "\(Int($0.rounded()))C" } ?? "Temp --"
    }

    private var powerLine: String {
        gpu.powerW.map { String(format: "%.1f W", $0) } ?? "Power --"
    }

    private func formatPercent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--%" }
        return "\(Int(value.rounded()))%"
    }
}

private extension NvidiaGpuMetric {
    var widgetID: String {
        index.map { "\($0)-\(name)" } ?? name
    }
}
