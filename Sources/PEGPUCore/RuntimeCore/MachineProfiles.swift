import Foundation

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
        if let items = try? fm.contentsOfDirectory(atPath: root.path), items.isEmpty {
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
    public static func cleanTransientFiles(profileRoot: URL) {
        let root = profileRoot.standardizedFileURL
        let machine = root.appendingPathComponent("machines/default", isDirectory: true)
        let paths = [
            machine.appendingPathComponent("qemu.pid"),
            machine.appendingPathComponent("qmp.sock"),
            machine.appendingPathComponent("display.spice"),
            machine.appendingPathComponent("memory.bin"),
            machine.appendingPathComponent("audio-host.pid"),
            machine.appendingPathComponent("audio-host.json"),
            machine.appendingPathComponent("network.json"),
            machine.appendingPathComponent("model-api-route.json")
        ]
        for path in paths {
            try? FileManager.default.removeItem(at: path)
        }
    }

    public static func deleteRouterConfig(profileRoot: URL) {
        try? FileManager.default.removeItem(at: profileRoot.standardizedFileURL.appendingPathComponent("ai/llms/app.yaml"))
    }
}
