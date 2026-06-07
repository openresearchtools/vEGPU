import Foundation

public struct AppPaths: Sendable {
    public let root: URL
    public let appData: URL
    public let runtime: URL
    public let machine: URL
    public let ssh: URL
    public let shares: URL
    public let manifest: URL
    public let machineConfig: URL

    public init(root: URL = AppPaths.discoverRoot(), dataRoot explicitDataRoot: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.root = root
        let dataRoot = explicitDataRoot?.standardizedFileURL
            ?? environment["PEGPU_APP_DATA_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
            ?? AppPaths.defaultProfileRoot
        self.appData = dataRoot
        self.runtime = dataRoot
        self.machine = dataRoot.appendingPathComponent("machines/default", isDirectory: true)
        self.ssh = dataRoot.appendingPathComponent("ssh", isDirectory: true)
        self.shares = dataRoot.appendingPathComponent("shares", isDirectory: true)
        self.manifest = dataRoot.appendingPathComponent("manifest.json")
        self.machineConfig = dataRoot.appendingPathComponent("machine.json")
    }

    public func ensureDirectories() throws {
        for dir in [runtime, machine, ssh, shares] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public static func discoverRoot(startingAt start: URL = URL(fileURLWithPath: #filePath)) -> URL {
        if let bundledRoot = Bundle.main.resourceURL?.appendingPathComponent("PEGPURoot", isDirectory: true),
           FileManager.default.fileExists(atPath: bundledRoot.appendingPathComponent("Package.swift").path) {
            return bundledRoot
        }
        if let executable = Bundle.main.executableURL {
            var dir = executable.deletingLastPathComponent()
            for _ in 0..<10 {
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                    return dir
                }
                let next = dir.deletingLastPathComponent()
                if next.path == dir.path { break }
                dir = next
            }
        }
        var dir = start.deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            let next = dir.deletingLastPathComponent()
            if next.path == dir.path { break }
            dir = next
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    public var resources: URL { root.appendingPathComponent("Resources", isDirectory: true) }
    public var toolsBin: URL { root.appendingPathComponent("tools/bin", isDirectory: true) }
    public var guestPackages: URL { root.appendingPathComponent("build/guest-packages", isDirectory: true) }

    public static var globalDataRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PEGPU", isDirectory: true)
    }

    public static var defaultProfileRoot: URL {
        globalDataRoot.appendingPathComponent("Machine", isDirectory: true)
    }

    public static var defaultProfilesRoot: URL {
        globalDataRoot.appendingPathComponent("Machines", isDirectory: true)
    }

    public static var machineRegistry: URL {
        globalDataRoot.appendingPathComponent("machines.json")
    }
}
