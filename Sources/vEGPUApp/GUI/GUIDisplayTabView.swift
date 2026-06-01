import AppKit
import SwiftUI
import vEGPUCore

struct GUIDisplayTabView: View {
    @ObservedObject var model: NativeAppModel
    @StateObject private var session: SpiceSessionController
    @ObservedObject private var displayControl: DisplayControlMenuModel

    init(model: NativeAppModel) {
        self.model = model
        let files = MachineFiles(machineDir: model.paths.machine)
        self._session = StateObject(wrappedValue: SpiceSessionController(socketURL: files.spiceSocket, paths: model.paths))
        self.displayControl = model.displayControlMenu
    }

    var body: some View {
        displayBody
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            session.start()
            displayControl.refresh()
            syncExternalCapture(displayControl.activeSessionID)
        }
        .onDisappear {
            session.disconnect()
        }
        .onReceive(displayControl.$activeSessionID) { activeSessionID in
            syncExternalCapture(activeSessionID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vegpuRuntimeWillStop)) { _ in
            session.disconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vegpuReconnectDisplay)) { _ in
            session.reconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vegpuExternalSessionShortcut)) { notification in
            guard let digit = notification.object as? Int else { return }
            if digit == 1 {
                releaseExternalInput()
            } else {
                displayControl.enterOrderedSession(number: digit - 1)
            }
        }
    }

    @ViewBuilder
    private var displayBody: some View {
        if session.connected {
            ZStack {
                SpiceDisplayView(session: session, retina: model.guiRetina)
                    .background(Color.black)
                    .ignoresSafeArea()
                ExternalInputCaptureView(session: session)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
            .background(ExternalSessionShortcutMonitor(model: displayControl, session: session))
        } else {
            InternalDisplayUnavailableView(
                status: session.status,
                message: displayControl.message,
                busy: displayControl.busy,
                reconnect: { session.reconnect() },
                switchToSpice: { displayControl.releaseSession() },
                reload: { displayControl.refresh() }
            )
            .background(ExternalSessionShortcutMonitor(model: displayControl, session: session))
        }
    }

    private func syncExternalCapture(_ activeSessionID: String?) {
        session.setDynamicResolutionEnabled(true)
        if activeSessionID == nil {
            session.setExternalInputCapture(false)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if displayControl.activeSessionID != nil {
                    session.setExternalInputCapture(true)
                }
            }
        }
    }

    private func releaseExternalInput() {
        session.setExternalInputCapture(false)
        displayControl.releaseSession()
    }
}

private struct ExternalSessionShortcutMonitor: NSViewRepresentable {
    @ObservedObject var model: DisplayControlMenuModel
    @ObservedObject var session: SpiceSessionController

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, session: session)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.model = model
        context.coordinator.session = session
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        var model: DisplayControlMenuModel
        var session: SpiceSessionController
        private var localMonitor: Any?
        private var globalMonitor: Any?

        init(model: DisplayControlMenuModel, session: SpiceSessionController) {
            self.model = model
            self.session = session
        }

        func install() {
            guard localMonitor == nil, globalMonitor == nil else { return }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event, consume: true) ?? event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                _ = self?.handle(event, consume: false)
            }
        }

        func uninstall() {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
            }
            if let globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
            }
            localMonitor = nil
            globalMonitor = nil
        }

        private func handle(_ event: NSEvent, consume: Bool) -> NSEvent? {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == [.command, .option],
                  let text = event.charactersIgnoringModifiers,
                  let digit = Int(text),
                  (1...9).contains(digit) else {
                return event
            }
            if digit == 1 {
                session.setExternalInputCapture(false)
                model.releaseSession()
            } else {
                model.enterOrderedSession(number: digit - 1)
            }
            return consume ? nil : event
        }
    }
}

private struct InternalDisplayUnavailableView: View {
    let status: String
    let message: String?
    let busy: Bool
    let reconnect: () -> Void
    let switchToSpice: () -> Void
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
                Button(action: switchToSpice) {
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
