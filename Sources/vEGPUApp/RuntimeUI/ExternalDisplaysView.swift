import SwiftUI

struct ExternalDisplaysView: View {
    let model: NativeAppModel
    @ObservedObject private var displayControl: DisplayControlMenuModel
    @Environment(\.colorScheme) private var colorScheme

    init(model: NativeAppModel) {
        self.model = model
        self.displayControl = model.displayControlMenu
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let message = displayControl.message?.friendlyDisplayLine, !message.isEmpty {
                        statusBanner(message)
                    }
                    if displayControl.sessions.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(Array(displayControl.sessions.enumerated()), id: \.element.id) { index, session in
                                ExternalDisplayGPUCard(
                                    session: session,
                                    shortcutNumber: index + 2,
                                    busy: displayControl.busy,
                                    enter: { displayControl.enterSession(session) },
                                    release: { displayControl.releaseSession() },
                                    rescan: { displayControl.rescanSessionDisplays(session) },
                                    restart: { displayControl.restartSession(session) },
                                    stop: { displayControl.stopSession(session) }
                                )
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.windowBackground(colorScheme))
        .onAppear {
            displayControl.refresh()
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 320), spacing: 14)]
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("External Displays")
                    .font(.headline.weight(.semibold))
                Text(displayControl.statusTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                displayControl.releaseSession()
            } label: {
                Label("Release", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(displayControl.busy || displayControl.activeSessionID == nil)
            Button {
                displayControl.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(displayControl.busy)
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(AppTheme.panelBackground(colorScheme))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayControl.busy ? "Loading GPUs" : "No External GPUs")
                .font(.title3.weight(.semibold))
            Text(displayControl.busy ? "Scanning display sessions." : "No valid plugged NVIDIA display sessions are visible.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
        .padding(16)
        .background(AppTheme.panelBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border(colorScheme, opacity: 0.6), lineWidth: 1))
    }

    private func statusBanner(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(AppTheme.cardBackground(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.border(colorScheme, opacity: 0.55), lineWidth: 1))
    }
}

private struct ExternalDisplayGPUCard: View {
    let session: DisplaySession
    let shortcutNumber: Int
    let busy: Bool
    let enter: () -> Void
    let release: () -> Void
    let rescan: () -> Void
    let restart: () -> Void
    let stop: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            portSummary
            outputList
            Spacer(minLength: 0)
            controls
        }
        .frame(maxWidth: .infinity, minHeight: 292, alignment: .topLeading)
        .padding(14)
        .padding(.leading, 5)
        .background(AppTheme.panelBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(statusColor)
                .frame(width: 5)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border(colorScheme, opacity: 0.65), lineWidth: 1))
        .contextMenu {
            Button(session.running ? "Enter Display Session" : "Start Display Session", action: enter)
                .disabled(busy)
            Button("Return to vEGPU GUI", action: release)
                .disabled(busy)
            Divider()
            Button("Rescan Displays", action: rescan)
                .disabled(busy || !session.running)
            Button("Restart GPU Session", action: restart)
                .disabled(busy || !session.running)
            Button("Stop GPU Session", role: .destructive, action: stop)
                .disabled(busy || !session.running)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GPU \(session.index)")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(session.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    StatusPill(text: statusText, color: statusColor)
                    Text("Option-Cmd-\(shortcutNumber)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                metadataChip(session.display)
                metadataChip(session.bdf)
            }
        }
    }

    private var portSummary: some View {
        HStack(spacing: 10) {
            Label("\(connectedOutputs.count)", systemImage: "display")
                .font(.caption.weight(.semibold))
            Text(connectedOutputs.count == 1 ? "connected output" : "connected outputs")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let primaryOutput {
                Text("Primary \(primaryOutput.name)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var outputList: some View {
        if session.outputs.isEmpty {
            Text(session.running ? "No output scan yet" : "Start session to scan outputs")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                .padding(10)
                .background(AppTheme.cardBackground(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            VStack(spacing: 6) {
                ForEach(session.outputs) { output in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(output.connected ? Color.green : Color.secondary.opacity(0.45))
                            .frame(width: 8, height: 8)
                        Text(output.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if output.primary {
                            Text("PRIMARY")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(statusColor)
                        }
                        Spacer(minLength: 8)
                        Text(outputModeText(output))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
            .background(AppTheme.cardBackground(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: enter) {
                    Label(session.running ? "Enter" : "Start", systemImage: session.running ? "arrow.right.to.line" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(busy)
                Button(action: release) {
                    Label("Release", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .disabled(busy)
            }
            HStack(spacing: 8) {
                Button(action: rescan) {
                    Label("Rescan", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .disabled(busy || !session.running)
                Button(action: restart) {
                    Label("Restart", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .disabled(busy || !session.running)
                Button(role: .destructive, action: stop) {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(busy || !session.running)
            }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    private var connectedOutputs: [DisplaySessionOutput] {
        session.outputs.filter(\.connected)
    }

    private var primaryOutput: DisplaySessionOutput? {
        session.outputs.first(where: \.primary)
    }

    private var statusText: String {
        if session.active {
            return "Active"
        }
        if session.running {
            return "Running"
        }
        return "Stopped"
    }

    private var statusColor: Color {
        if session.active {
            return .blue
        }
        if session.running {
            return .green
        }
        return .secondary
    }

    private func metadataChip(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(AppTheme.cardBackground(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func outputModeText(_ output: DisplaySessionOutput) -> String {
        guard output.connected else { return "disconnected" }
        if output.mode.isEmpty {
            return "connected"
        }
        return "\(output.mode) +\(output.x)+\(output.y)"
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

private extension String {
    var firstDisplayLine: String {
        components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? self
    }

    var friendlyDisplayLine: String {
        let line = firstDisplayLine
        if line.contains("RuntimeError") || line.contains("ssh") || line.contains("JSON") || line.contains("operation couldn") {
            return "Display control is not reachable yet."
        }
        return line
    }
}
