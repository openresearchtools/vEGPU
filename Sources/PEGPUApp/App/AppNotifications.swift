import Foundation

extension Notification.Name {
    static let pegpuRuntimeWillStop = Notification.Name("dev.pegpu.runtimeWillStop")
    static let pegpuReloadWebTab = Notification.Name("dev.pegpu.reloadWebTab")
    static let pegpuReconnectDisplay = Notification.Name("dev.pegpu.reconnectDisplay")
    static let pegpuExternalSessionShortcut = Notification.Name("dev.pegpu.externalSessionShortcut")
    static let pegpuReleaseExternalInputCapture = Notification.Name("dev.pegpu.releaseExternalInputCapture")
}
