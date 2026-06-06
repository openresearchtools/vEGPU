import Foundation

public enum VfioApp {
    public static let displayName = "PEGPU Machine"
    public static let defaultPath = "/Applications/PEGPU Machine.app"
    public static let driverIdentifier = "com.pegpu.machine.VFIOUserPCIDriver"

    public static func appPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["PEGPU_VFIO_APP"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultPath
    }

    public static func macOSPath(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        URL(fileURLWithPath: appPath(environment: environment))
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(name)
            .path
    }

    public static func resourcesPath(_ parts: String..., environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var url = URL(fileURLWithPath: appPath(environment: environment)).appendingPathComponent("Contents/Resources")
        for part in parts {
            url.appendPathComponent(part)
        }
        return url.path
    }

    public static func helperPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["PEGPU_VFIO_HELPER"].flatMap { $0.isEmpty ? nil : $0 } ?? macOSPath("qemu-vfio-apple", environment: environment)
    }

    public static func appExecutablePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["PEGPU_VFIO_APP_EXECUTABLE"].flatMap { $0.isEmpty ? nil : $0 } ?? macOSPath(displayName, environment: environment)
    }
}
