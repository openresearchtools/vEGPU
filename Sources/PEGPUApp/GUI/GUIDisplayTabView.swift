import AppKit
import SwiftUI
import PEGPUCore

struct GUIDisplayTabView: View {
    @ObservedObject var model: NativeAppModel
    @ObservedObject private var session: SpiceSessionController
    @ObservedObject private var displayControl: DisplayControlMenuModel

    init(model: NativeAppModel) {
        self.model = model
        self.session = model.displaySession
        self.displayControl = model.displayControlMenu
    }

    var body: some View {
        displayBody
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            session.start()
            session.setDynamicResolutionEnabled(true)
            displayControl.refresh()
            syncExternalCapture(displayControl.activeSessionID)
        }
        .onDisappear {
            session.setExternalInputCapture(false)
            session.disconnect()
        }
        .onReceive(displayControl.$activeSessionID) { activeSessionID in
            syncExternalCapture(activeSessionID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pegpuRuntimeWillStop)) { _ in
            session.disconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pegpuMachineProfileWillSwitch)) { _ in
            session.disconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pegpuReconnectDisplay)) { _ in
            session.reconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pegpuExternalSessionShortcut)) { notification in
            guard let digit = notification.object as? Int else { return }
            if digit == 1 {
                displayControl.releaseSession()
                session.setExternalInputCapture(false)
            } else {
                displayControl.enterOrderedSession(number: digit - 1)
            }
        }
    }

    @ViewBuilder
    private var displayBody: some View {
        ZStack {
            if session.connected {
                SpiceDisplayView(session: session, retina: model.guiRetina)
                    .background(Color.black)
                    .ignoresSafeArea()
            } else {
                Color.black
                    .ignoresSafeArea()
            }
        }
    }

    private func syncExternalCapture(_ activeSessionID: String?) {
        session.setDynamicResolutionEnabled(true)
        if activeSessionID == nil {
            session.setExternalInputCapture(false)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard displayControl.activeSessionID != nil else {
                    session.setExternalInputCapture(false)
                    return
                }
                session.setExternalInputCapture(true)
            }
        }
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
