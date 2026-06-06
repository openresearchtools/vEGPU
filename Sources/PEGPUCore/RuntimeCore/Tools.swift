import Foundation

public struct ToolPaths: Codable, Equatable, Sendable {
    public let qemu: String
    public let qemuLauncher: String
    public let qemuImg: String
    public let qemuShare: String
    public let firmwareCode: String
    public let firmwareVarsTemplate: String
}

public final class ToolResolver: @unchecked Sendable {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func resolve() throws -> ToolPaths {
        let qemuShare = environment["PEGPU_QEMU_SHARE"].flatMap { $0.isEmpty ? nil : $0 }
            ?? VfioApp.resourcesPath("share", "qemu", environment: environment)
        return ToolPaths(
            qemu: try executable(environment["PEGPU_QEMU"] ?? VfioApp.macOSPath("qemu-system-aarch64", environment: environment), hint: "qemu-system-aarch64"),
            qemuLauncher: try executable(VfioApp.helperPath(environment: environment), hint: "qemu-vfio-apple"),
            qemuImg: try executable(environment["PEGPU_QEMU_IMG"] ?? VfioApp.macOSPath("qemu-img", environment: environment), hint: "qemu-img"),
            qemuShare: try readable(qemuShare, hint: "QEMU share"),
            firmwareCode: try readable(URL(fileURLWithPath: qemuShare).appendingPathComponent("edk2-aarch64-code.fd").path, hint: "AArch64 EDK2 code firmware"),
            firmwareVarsTemplate: try firmwareVarsTemplate(qemuShare: qemuShare)
        )
    }

    private func firmwareVarsTemplate(qemuShare: String) throws -> String {
        for name in ["edk2-arm-vars.fd", "edk2-aarch64-vars.fd"] {
            let file = URL(fileURLWithPath: qemuShare).appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: file) {
                return file
            }
        }
        return try readable(URL(fileURLWithPath: qemuShare).appendingPathComponent("edk2-arm-vars.fd").path, hint: "AArch64 EDK2 vars firmware")
    }

    private func executable(_ file: String, hint: String) throws -> String {
        guard FileManager.default.fileExists(atPath: file) else {
            throw RuntimeError.message("Missing \(hint): \(file)")
        }
        guard FileManager.default.isExecutableFile(atPath: file) else {
            throw RuntimeError.message("Not executable \(hint): \(file)")
        }
        return file
    }

    private func readable(_ file: String, hint: String) throws -> String {
        guard FileManager.default.fileExists(atPath: file) else {
            throw RuntimeError.message("Missing \(hint): \(file)")
        }
        return file
    }
}
