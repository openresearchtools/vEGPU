import Foundation

extension Notification.Name {
    static let pegpuRuntimeWillStop = Notification.Name("dev.pegpu.runtimeWillStop")
    static let pegpuReloadWebTab = Notification.Name("dev.pegpu.reloadWebTab")
    static let pegpuReconnectDisplay = Notification.Name("dev.pegpu.reconnectDisplay")
    static let pegpuMachineProfileWillSwitch = Notification.Name("dev.pegpu.machineProfileWillSwitch")
    static let pegpuMachineProfileDidSwitch = Notification.Name("dev.pegpu.machineProfileDidSwitch")
    static let pegpuExternalInputCaptureDidChange = Notification.Name("dev.pegpu.externalInputCaptureDidChange")
}
