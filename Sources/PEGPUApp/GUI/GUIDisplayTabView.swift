import AppKit
import SwiftUI
import PEGPUCore

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
        .onReceive(NotificationCenter.default.publisher(for: .pegpuRuntimeWillStop)) { _ in
            session.disconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pegpuReconnectDisplay)) { _ in
            session.reconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pegpuReleaseExternalInputCapture)) { _ in
            session.setExternalInputCapture(false)
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
            ExternalInputCaptureView(session: session)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
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
