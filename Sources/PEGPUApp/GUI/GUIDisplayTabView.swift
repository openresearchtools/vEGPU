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
        .onReceive(NotificationCenter.default.publisher(for: .pegpuReconnectDisplay)) { _ in
            session.reconnect()
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
