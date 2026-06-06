import AppKit
import SwiftUI
import PEGPUCore

struct RuntimeOutputPaneView: View {
    let model: NativeAppModel
    @ObservedObject var log: RuntimeLogState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Output")
                    .font(.headline)
                Spacer()
                Button {
                    model.clearOutput()
                } label: {
                    HitTargetLabel("Clear", minWidth: 52)
                }
                Text(log.commandState)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(commandColor)
                    .frame(minWidth: 62, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ProgressDockView(event: log.currentProgress)

            Divider()

            SelectableTextPane(
                text: outputText,
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                autoScrollToBottom: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: RuntimePaneSizing.minHeight,
            idealHeight: RuntimePaneSizing.idealHeight,
            maxHeight: RuntimePaneSizing.maxHeight
        )
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1))
    }

    private var commandColor: Color {
        if log.commandState == "running" { return .orange }
        if log.commandState == "error" { return .red }
        if log.commandState.hasPrefix("exit") { return .green }
        return .secondary
    }

    private var outputText: String {
        log.outputLines.isEmpty ? "Runtime output will appear here." : log.outputLines.joined(separator: "\n")
    }
}

private struct ProgressDockView: View {
    let event: ProgressEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(event?.message ?? "Runtime idle")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(rateText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progressValue, total: 100)
                .progressViewStyle(.linear)
            Text(detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var progressValue: Double {
        guard let percent = event?.percent, percent.isFinite else { return 0 }
        return max(0, min(100, percent))
    }

    private var detailText: String {
        guard let event else { return "No active command." }
        if let detail = event.detail, !detail.isEmpty {
            return detail
        }
        return "\(event.stage) · \(event.level.rawValue)"
    }

    private var rateText: String {
        guard let event else { return "" }
        if let rate = event.rateBytesPerSecond, rate > 0 {
            return "\(formatBytes(Int64(rate)))/s"
        }
        if let percent = event.percent {
            return "\(Int(percent.rounded()))%"
        }
        return ""
    }

    private func formatBytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        return unit <= 1 ? "\(Int(amount)) \(units[unit])" : String(format: "%.1f %@", amount, units[unit])
    }
}
