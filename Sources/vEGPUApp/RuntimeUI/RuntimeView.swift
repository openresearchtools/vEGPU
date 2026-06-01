import SwiftUI
import vEGPUCore

struct RuntimeView: View {
    let model: NativeAppModel
    private let screen: RuntimeScreenState
    @State private var config: MachineConfig

    init(model: NativeAppModel) {
        self.model = model
        self.screen = model.runtimeScreen
        self._config = State(initialValue: model.configStore.load())
    }

    var body: some View {
        VStack(spacing: 0) {
            RuntimeToolbarView(model: model, config: $config)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DriverCardsView(model: model, drivers: screen.drivers)
                    RuntimePaneToolbarView(model: model, navigation: screen.navigation, terminal: screen.terminal)
                    RuntimePaneContentView(model: model, screen: screen)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(NvidiaInstallSheetHost(model: model, drivers: screen.drivers))
    }
}

private struct NvidiaInstallSheetHost: View {
    let model: NativeAppModel
    @ObservedObject var drivers: RuntimeDriverState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: $drivers.showingNvidiaInstallConfirm) {
                NvidiaInstallConfirmView(model: model, isPresented: $drivers.showingNvidiaInstallConfirm)
            }
    }
}

private struct RuntimePaneContentView: View {
    let model: NativeAppModel
    let screen: RuntimeScreenState
    @ObservedObject private var navigation: RuntimeNavigationState

    init(model: NativeAppModel, screen: RuntimeScreenState) {
        self.model = model
        self.screen = screen
        self._navigation = ObservedObject(initialValue: screen.navigation)
    }

    var body: some View {
        Group {
            switch navigation.runtimePane {
            case .terminal:
                RuntimeTerminalView(model: model, terminal: screen.terminal)
            case .output:
                RuntimeOutputPaneView(model: model, log: screen.log)
            case .manifest:
                ManifestPaneView(manifest: screen.manifest)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: RuntimePaneSizing.minHeight,
            idealHeight: RuntimePaneSizing.idealHeight,
            maxHeight: RuntimePaneSizing.maxHeight
        )
    }
}
