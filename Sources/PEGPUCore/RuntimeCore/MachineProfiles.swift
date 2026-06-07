import Foundation
import Darwin

public struct MachineProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var createdAt: String
    public var lastOpenedAt: String

    public init(id: String = UUID().uuidString, name: String, path: String, createdAt: String = MachineProfileRegistryStore.nowString(), lastOpenedAt: String = MachineProfileRegistryStore.nowString()) {
        self.id = id
        self.name = name
        self.path = MachineProfileRegistryStore.standardPath(path)
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }

    public var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}

public struct MachineProfileRegistry: Codable, Equatable, Sendable {
    public var version: Int
    public var selectedID: String
    public var machines: [MachineProfile]

    public init(version: Int = 1, selectedID: String, machines: [MachineProfile]) {
        self.version = version
        self.selectedID = selectedID
        self.machines = machines
    }
}

public struct MachineProfileIdentity: Codable, Equatable, Sendable {
    public var version: Int
    public var profileID: String
    public var name: String
    public var createdAt: String
    public var migratedAt: String?

    public init(version: Int = 1, profileID: String = UUID().uuidString, name: String, createdAt: String = MachineProfileRegistryStore.nowString(), migratedAt: String? = nil) {
        self.version = version
        self.profileID = profileID
        self.name = name
        self.createdAt = createdAt
        self.migratedAt = migratedAt
    }
}

public struct MachineProfileContext: Sendable {
    public let profileRoot: URL
    public let profileID: String
    public let name: String

    public init(profileRoot: URL, profileID: String, name: String) {
        self.profileRoot = profileRoot.standardizedFileURL
        self.profileID = profileID
        self.name = name
    }

    public var hostRuntimeRoot: URL {
        MachineRuntimePaths.hostRuntimeRoot(for: profileID)
    }
}

public struct MachineRuntimePaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static func hostRuntimeRoot(for profileID: String) -> URL {
        AppPaths.hostRuntimeRoot.appendingPathComponent(safeProfileID(profileID), isDirectory: true)
    }

    public static func safeProfileID(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let filtered = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(filtered).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return result.isEmpty ? UUID().uuidString : result
    }

    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public var helperState: URL { root.appendingPathComponent("web-ui-helper.json") }
    public var helperLog: URL { root.appendingPathComponent("web-ui-app.stdout.log") }
    public var helperErrorLog: URL { root.appendingPathComponent("web-ui-app.stderr.log") }
    public var localProxyLog: URL { root.appendingPathComponent("local-proxy.log") }
    public var owner: URL { root.appendingPathComponent("owner.json") }
}

public enum MachineProfileValidation {
    public static func isProfileFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        let root = url.standardizedFileURL
        if fm.fileExists(atPath: root.appendingPathComponent("machine.json").path) {
            return true
        }
        if fm.fileExists(atPath: root.appendingPathComponent("secrets.json").path),
           fm.fileExists(atPath: root.appendingPathComponent("ssh/id_ed25519").path) {
            return true
        }
        if fm.fileExists(atPath: root.appendingPathComponent("machines/default/disk.qcow2").path) {
            return true
        }
        return false
    }

    public static func path(_ child: URL, isInside parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }
}

public final class MachineProfileRegistryStore: @unchecked Sendable {
    public let url: URL
    private let fileManager: FileManager

    public init(url: URL = AppPaths.machineRegistry, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func loadOrCreate(preferredProfileRoot: URL? = nil) throws -> MachineProfileRegistry {
        if let loaded = try loadIfPresent() {
            return try repair(loaded, preferredProfileRoot: preferredProfileRoot)
        }
        let root = (preferredProfileRoot ?? AppPaths.defaultProfileRoot).standardizedFileURL
        let profile = MachineProfile(name: "Default", path: root.path)
        let registry = MachineProfileRegistry(selectedID: profile.id, machines: [profile])
        try save(registry)
        return registry
    }

    public func loadIfPresent() throws -> MachineProfileRegistry? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MachineProfileRegistry.self, from: data)
    }

    public func save(_ registry: MachineProfileRegistry) throws {
        var next = registry
        next.version = 1
        next.machines = dedupe(next.machines)
        if !next.machines.contains(where: { $0.id == next.selectedID }) {
            next.selectedID = next.machines.first?.id ?? ""
        }
        try JSON.write(next, to: url)
    }

    @discardableResult
    public func select(_ id: String) throws -> MachineProfileRegistry {
        var registry = try loadOrCreate()
        guard let index = registry.machines.firstIndex(where: { $0.id == id }) else {
            throw RuntimeError.message("Machine profile is not registered.")
        }
        registry.selectedID = id
        registry.machines[index].lastOpenedAt = Self.nowString()
        try save(registry)
        return registry
    }

    public static func standardPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.path
    }

    public static func nowString() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func repair(_ registry: MachineProfileRegistry, preferredProfileRoot: URL?) throws -> MachineProfileRegistry {
        var next = registry
        next.version = 1
        next.machines = dedupe(next.machines.map { profile in
            var copy = profile
            copy.path = Self.standardPath(copy.path)
            if copy.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                copy.name = "Machine"
            }
            return copy
        })
        let preferredPath = preferredProfileRoot?.standardizedFileURL.path
        if let preferredPath,
           !next.machines.contains(where: { $0.path == preferredPath }) {
            next.machines.append(MachineProfile(name: profileName(for: preferredPath), path: preferredPath))
        }
        let defaultPath = AppPaths.defaultProfileRoot.standardizedFileURL.path
        if !next.machines.contains(where: { $0.path == defaultPath }),
           fileManager.fileExists(atPath: defaultPath) {
            next.machines.insert(MachineProfile(name: "Default", path: defaultPath), at: 0)
        }
        if !next.machines.contains(where: { $0.id == next.selectedID }) {
            if let preferredPath,
               let preferred = next.machines.first(where: { $0.path == preferredPath }) {
                next.selectedID = preferred.id
            } else {
                next.selectedID = next.machines.first?.id ?? ""
            }
        }
        try save(next)
        return next
    }

    private func dedupe(_ machines: [MachineProfile]) -> [MachineProfile] {
        var seenIDs = Set<String>()
        var seenPaths = Set<String>()
        var out: [MachineProfile] = []
        for machine in machines {
            let id = machine.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = Self.standardPath(machine.path)
            guard !id.isEmpty, !path.isEmpty, !seenIDs.contains(id), !seenPaths.contains(path) else {
                continue
            }
            seenIDs.insert(id)
            seenPaths.insert(path)
            var copy = machine
            copy.id = id
            copy.path = path
            out.append(copy)
        }
        return out
    }

    private func profileName(for path: String) -> String {
        let leaf = URL(fileURLWithPath: path).lastPathComponent
        return leaf.isEmpty ? "Machine" : leaf
    }
}

public enum MachineProfileMaintenance {
    private static let transientRelativePaths = [
        "machines/default/qemu.pid",
        "machines/default/qmp.sock",
        "machines/default/display.spice",
        "machines/default/memory.bin",
        "machines/default/seed.iso",
        "machines/default/seed",
        "machines/default/serial.log",
        "machines/default/qemu.log",
        "machines/default/qemu.stdout.log",
        "machines/default/qemu.stderr.log",
        "machines/default/audio-host.pid",
        "machines/default/audio-host.json",
        "machines/default/audio-host.stdout.log",
        "machines/default/audio-host.stderr.log",
        "machines/default/network.json",
        "machines/default/model-api-route.json"
    ]

    public static func identityURL(profileRoot: URL) -> URL {
        profileRoot.standardizedFileURL
            .appendingPathComponent(".pegpu", isDirectory: true)
            .appendingPathComponent("profile.json")
    }

    @discardableResult
    public static func ensureProfileIdentity(profileRoot: URL, name: String, preferredID: String? = nil, preserveExisting: Bool = true) throws -> MachineProfileIdentity {
        let root = profileRoot.standardizedFileURL
        let url = identityURL(profileRoot: root)
        if preserveExisting,
           FileManager.default.fileExists(atPath: url.path),
           var existing = try? JSON.read(MachineProfileIdentity.self, from: url) {
            existing.version = 1
            if existing.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.name = name.isEmpty ? root.lastPathComponent : name
            }
            try JSON.write(existing, to: url)
            return existing
        }
        let identity = MachineProfileIdentity(
            profileID: MachineRuntimePaths.safeProfileID(preferredID ?? UUID().uuidString),
            name: name.isEmpty ? root.lastPathComponent : name,
            migratedAt: preserveExisting ? MachineProfileRegistryStore.nowString() : nil
        )
        try JSON.write(identity, to: url)
        return identity
    }

    public static func profileContext(profile: MachineProfile) throws -> MachineProfileContext {
        let identity = try ensureProfileIdentity(profileRoot: profile.url, name: profile.name, preferredID: profile.id)
        return MachineProfileContext(profileRoot: profile.url, profileID: identity.profileID, name: identity.name)
    }

    public static func ensureProfileScaffold(profileRoot: URL, name: String = "Machine", preferredID: String? = nil, preserveIdentity: Bool = true) throws {
        let root = profileRoot.standardizedFileURL
        let dirs = [
            root,
            root.appendingPathComponent(".pegpu", isDirectory: true),
            root.appendingPathComponent("setup", isDirectory: true),
            root.appendingPathComponent("ssh", isDirectory: true),
            root.appendingPathComponent("logs", isDirectory: true),
            root.appendingPathComponent("machines/default", isDirectory: true),
            root.appendingPathComponent("ai/llms", isDirectory: true),
            root.appendingPathComponent("ai/llms/.runtime", isDirectory: true),
            root.appendingPathComponent("ai/llms/runtimes", isDirectory: true),
            root.appendingPathComponent("shares/nfs", isDirectory: true)
        ]
        for dir in dirs {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        _ = try ensureProfileIdentity(profileRoot: root, name: name, preferredID: preferredID, preserveExisting: preserveIdentity)
    }

    public static func copyProfile(from sourceRoot: URL, to destinationRoot: URL) throws {
        let fm = FileManager.default
        let source = sourceRoot.standardizedFileURL
        let destination = destinationRoot.standardizedFileURL
        let skipped = Set(transientRelativePaths)

        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            throw RuntimeError.message("Could not read VM folder.")
        }

        for case let rawSourceItem as URL in enumerator {
            let sourceItem = rawSourceItem.standardizedFileURL
            guard sourceItem.path.hasPrefix(source.path + "/") else {
                continue
            }
            let relative = String(sourceItem.path.dropFirst(source.path.count + 1))
            let values = try sourceItem.resourceValues(forKeys: [.isDirectoryKey])
            if skipped.contains(relative) {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let destinationItem = destination.appendingPathComponent(relative)
            if values.isDirectory == true {
                try fm.createDirectory(at: destinationItem, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: destinationItem.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: sourceItem, to: destinationItem)
            }
        }
    }

    public static func cleanTransientFiles(profileRoot: URL) {
        let root = profileRoot.standardizedFileURL
        if legacyRuntimeLooksLive(profileRoot: root) {
            return
        }
        for path in transientRelativePaths {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
        }
    }

    public static func deleteRouterConfig(profileRoot: URL) {
        try? FileManager.default.removeItem(at: profileRoot.standardizedFileURL.appendingPathComponent("ai/llms/app.yaml"))
    }

    private static func legacyRuntimeLooksLive(profileRoot: URL) -> Bool {
        let machineDir = profileRoot.appendingPathComponent("machines/default", isDirectory: true)
        let pidURL = machineDir.appendingPathComponent("qemu.pid")
        guard let raw = try? String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(raw),
              kill(pid, 0) == 0,
              let command = try? Process.runAndCapture("/bin/ps", ["-p", String(pid), "-o", "command="]) else {
            return false
        }
        return command.contains(machineDir.appendingPathComponent("disk.qcow2").path) ||
            command.contains(profileRoot.path)
    }
}
