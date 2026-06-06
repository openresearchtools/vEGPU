import Foundation
import SwiftUI
import PEGPUCore

@MainActor
final class RuntimeScreenState {
    let navigation = RuntimeNavigationState()
    let drivers = RuntimeDriverState()
    let log = RuntimeLogState()
    let terminal = RuntimeTerminalState()
    let manifest = RuntimeManifestState()
}

@MainActor
final class RuntimeNavigationState: ObservableObject {
    @Published var runtimePane: NativeAppModel.RuntimePane = .terminal
}

@MainActor
final class RuntimeDriverState: ObservableObject {
    @Published var pcieDriver = DriverCardState(title: VfioApp.displayName, status: "Checking", detail: "Waiting for status.", state: "booting")
    @Published var linuxDriver = DriverCardState(title: "Linux Guest Driver", status: "Stopped", detail: "Runtime stopped", state: "stopped", actionTitle: "Reinstall")
    @Published var nvidiaDriver = DriverCardState(title: "GPU", status: "Stopped", detail: "Runtime stopped", state: "stopped", actionTitle: "Run Installer")
    @Published var nvidiaGpus: [NvidiaGpuMetric] = []
    @Published var nvidiaOutput = ""
    @Published var showingNvidiaInstallConfirm = false
}

@MainActor
final class RuntimeLogState: ObservableObject {
    @Published var outputLines: [String] = []
    @Published var currentProgress: ProgressEvent?
    @Published var commandState = "idle"
}

@MainActor
final class RuntimeTerminalState: ObservableObject {
    @Published var linuxPassword = ""
    @Published var terminalConnected = false
    @Published var terminalSessionID = UUID()
    @Published var terminalInput: TerminalInput?
}

@MainActor
final class RuntimeManifestState: ObservableObject {
    @Published var manifestSummary = "loading manifest..."
}
