import Foundation

extension Notification.Name {
    static let vegpuRuntimeWillStop = Notification.Name("dev.vegpu.runtimeWillStop")
    static let vegpuReloadWebTab = Notification.Name("dev.vegpu.reloadWebTab")
    static let vegpuReconnectDisplay = Notification.Name("dev.vegpu.reconnectDisplay")
    static let vegpuExternalSessionShortcut = Notification.Name("dev.vegpu.externalSessionShortcut")
    static let vegpuReleaseExternalInputCapture = Notification.Name("dev.vegpu.releaseExternalInputCapture")
}
