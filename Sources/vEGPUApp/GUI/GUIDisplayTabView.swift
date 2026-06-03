import AppKit
import SwiftUI
import vEGPUCore

struct GUIDisplayTabView: View {
    @ObservedObject var model: NativeAppModel
    @ObservedObject private var session: SpiceSessionController
    @ObservedObject private var displayControl: DisplayControlMenuModel

    init(model: NativeAppModel) {
        self.model = model
        self.session = model.spiceSession
        self.displayControl = model.displayControlMenu
    }

    var body: some View {
        displayBody
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            session.start()
            displayControl.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vegpuRuntimeWillStop)) { _ in
            session.disconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vegpuExternalSessionShortcut)) { notification in
            guard let digit = notification.object as? Int else { return }
            if digit == 1 {
                session.setExternalInputCapture(false)
            }
        }
    }

    @ViewBuilder
    private var displayBody: some View {
        if let activeSession = displayControl.activeSessionID {
            InternalDisplayUnavailableView(
                status: "External display session active: \(activeSession)",
                message: "Release the external session to return input and display focus to the embedded GUI.",
                busy: displayControl.busy,
                reconnect: { session.reconnect() },
                returnToGUI: { displayControl.releaseSession() },
                reload: { displayControl.reload() }
            )
        } else if session.connected && session.displayHealthy {
            ZStack {
                SpiceDisplayView(session: session, retina: model.guiRetina)
                    .background(Color.black)
                    .ignoresSafeArea()
            }
        } else {
            InternalDisplayUnavailableView(
                status: session.status,
                message: displayControl.message,
                busy: displayControl.busy,
                reconnect: { session.reconnect() },
                returnToGUI: { displayControl.releaseSession() },
                reload: { displayControl.reload() }
            )
        }
    }

}

private struct InternalDisplayUnavailableView: View {
    let status: String
    let message: String?
    let busy: Bool
    let reconnect: () -> Void
    let returnToGUI: () -> Void
    let reload: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            Text(status)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let message = message?.friendlyDisplayLine, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                Button(action: reconnect) {
                    Label("Reconnect", systemImage: "cable.connector")
                }
                Button(action: reload) {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(busy)
                Button(action: returnToGUI) {
                    Label("Switch to vEGPU GUI", systemImage: "display")
                }
                .disabled(busy)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.96))
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
