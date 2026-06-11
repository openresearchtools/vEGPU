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
