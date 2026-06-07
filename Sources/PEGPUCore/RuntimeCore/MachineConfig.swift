import Foundation

public enum CpuMode: String, Codable, Sendable {
    case auto
    case manual
}

public enum RuntimeLaunchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case headless
    case gui

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .headless: return "Headless"
        case .gui: return "GUI"
        }
    }
}

public enum GUIResolutionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case nativeFit

    public var id: String { rawValue }
}

public enum GUIDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case comfort

    public var id: String { rawValue }
}

public enum GUIAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case light
    case dark

    public var id: String { rawValue }
}

public struct MachineConfig: Codable, Equatable, Sendable {
    public static let defaultLaunchMode: RuntimeLaunchMode = .gui
    public static let defaultGuiRetina = true

    public var cpuMode: CpuMode
    public var cpuCount: Int
    public var memoryMiB: Int
    public var startRuntimeAtLogin: Bool
    public var shareRoot: String
    public var launchMode: RuntimeLaunchMode
    public var guiRetina: Bool
    public var guiResolutionMode: GUIResolutionMode
    public var guiDensity: GUIDensity
    public var guiAppearance: GUIAppearance
    public var linuxHomeShareEnabled: Bool
    public var linuxHomeMountPath: String
    public var macShareGuestPath: String

    private enum CodingKeys: String, CodingKey {
        case cpuMode
        case cpuCount
        case memoryMiB
        case startRuntimeAtLogin
        case shareRoot
        case launchMode
        case guiRetina
        case guiResolutionMode
        case guiDensity
        case guiAppearance
        case linuxHomeShareEnabled
        case linuxHomeMountPath
        case macShareGuestPath
    }

    public init(cpuMode: CpuMode = .auto, cpuCount: Int = 8, memoryMiB: Int = 8192, startRuntimeAtLogin: Bool = false, shareRoot: String = "~", launchMode: RuntimeLaunchMode = MachineConfig.defaultLaunchMode, guiRetina: Bool = MachineConfig.defaultGuiRetina, guiResolutionMode: GUIResolutionMode = .nativeFit, guiDensity: GUIDensity = .comfort, guiAppearance: GUIAppearance = .dark, linuxHomeShareEnabled: Bool = true, linuxHomeMountPath: String = defaultLinuxHomeMountPath, macShareGuestPath: String = guestShareRoot) {
        self.cpuMode = cpuMode
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.startRuntimeAtLogin = startRuntimeAtLogin
        self.shareRoot = shareRoot
        self.launchMode = launchMode
        self.guiRetina = guiRetina
        self.guiResolutionMode = guiResolutionMode
        self.guiDensity = guiDensity
        self.guiAppearance = guiAppearance
        self.linuxHomeShareEnabled = linuxHomeShareEnabled
        self.linuxHomeMountPath = linuxHomeMountPath
        self.macShareGuestPath = macShareGuestPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cpuMode = try container.decodeIfPresent(CpuMode.self, forKey: .cpuMode) ?? .auto
        self.cpuCount = try container.decodeIfPresent(Int.self, forKey: .cpuCount) ?? 8
        self.memoryMiB = try container.decodeIfPresent(Int.self, forKey: .memoryMiB) ?? 8192
        self.startRuntimeAtLogin = try container.decodeIfPresent(Bool.self, forKey: .startRuntimeAtLogin) ?? false
        self.shareRoot = try container.decodeIfPresent(String.self, forKey: .shareRoot) ?? "~"
        self.launchMode = try container.decodeIfPresent(RuntimeLaunchMode.self, forKey: .launchMode) ?? Self.defaultLaunchMode
        self.guiRetina = try container.decodeIfPresent(Bool.self, forKey: .guiRetina) ?? Self.defaultGuiRetina
        self.guiResolutionMode = try container.decodeIfPresent(GUIResolutionMode.self, forKey: .guiResolutionMode) ?? .nativeFit
        self.guiDensity = try container.decodeIfPresent(GUIDensity.self, forKey: .guiDensity) ?? .comfort
        self.guiAppearance = try container.decodeIfPresent(GUIAppearance.self, forKey: .guiAppearance) ?? .dark
        self.linuxHomeShareEnabled = try container.decodeIfPresent(Bool.self, forKey: .linuxHomeShareEnabled) ?? true
        self.linuxHomeMountPath = try container.decodeIfPresent(String.self, forKey: .linuxHomeMountPath) ?? defaultLinuxHomeMountPath
        self.macShareGuestPath = try container.decodeIfPresent(String.self, forKey: .macShareGuestPath) ?? guestShareRoot
    }
}

public struct EffectiveMachineConfig: Codable, Equatable, Sendable {
    public var cpuMode: CpuMode
    public var cpuCount: Int
    public var memoryMiB: Int
    public var startRuntimeAtLogin: Bool
    public var shareRoot: String
    public var effectiveCpuCount: Int
    public var launchMode: RuntimeLaunchMode
    public var guiRetina: Bool
    public var guiResolutionMode: GUIResolutionMode
    public var guiDensity: GUIDensity
    public var guiAppearance: GUIAppearance
    public var linuxHomeShareEnabled: Bool
    public var linuxHomeMountPath: String
    public var macShareGuestPath: String
}

public final class MachineConfigStore: @unchecked Sendable {
    private let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func load() -> MachineConfig {
        guard let data = try? Data(contentsOf: paths.machineConfig),
              let parsed = try? JSONDecoder().decode(MachineConfig.self, from: data) else {
            return normalized(MachineConfig(cpuCount: defaultCpuCount()))
        }
        return normalized(parsed)
    }

    @discardableResult
    public func save(_ partial: MachineConfig) throws -> MachineConfig {
        let normalized = normalized(partial)
        try JSON.write(normalized, to: paths.machineConfig)
        return normalized
    }

    public func effective() -> EffectiveMachineConfig {
        let config = load()
        let autoCpuCount = defaultCpuCount()
        return EffectiveMachineConfig(
            cpuMode: config.cpuMode,
            cpuCount: config.cpuCount,
            memoryMiB: config.memoryMiB,
            startRuntimeAtLogin: config.startRuntimeAtLogin,
            shareRoot: normalizeShareRoot(config.shareRoot),
            effectiveCpuCount: config.cpuMode == .auto ? autoCpuCount : config.cpuCount,
            launchMode: config.launchMode,
            guiRetina: config.guiRetina,
            guiResolutionMode: config.guiResolutionMode,
            guiDensity: config.guiDensity,
            guiAppearance: config.guiAppearance,
            linuxHomeShareEnabled: config.linuxHomeShareEnabled,
            linuxHomeMountPath: normalizeAbsolutePath(config.linuxHomeMountPath, fallback: defaultLinuxHomeMountPath),
            macShareGuestPath: config.macShareGuestPath.isEmpty ? guestShareRoot : config.macShareGuestPath
        )
    }

    private func normalized(_ config: MachineConfig) -> MachineConfig {
        let maxCPU = max(1, ProcessInfo.processInfo.processorCount)
        let cpuCount = min(max(config.cpuCount, 1), maxCPU)
        let memoryMiB = min(max(config.memoryMiB, 1024), 262_144)
        let shareRoot = portableShareRoot(config.shareRoot)
        return MachineConfig(
            cpuMode: config.cpuMode,
            cpuCount: cpuCount,
            memoryMiB: memoryMiB,
            startRuntimeAtLogin: config.startRuntimeAtLogin,
            shareRoot: shareRoot,
            launchMode: config.launchMode,
            guiRetina: config.guiRetina,
            guiResolutionMode: config.guiResolutionMode,
            guiDensity: config.guiDensity,
            guiAppearance: config.guiAppearance,
            linuxHomeShareEnabled: config.linuxHomeShareEnabled,
            linuxHomeMountPath: normalizeAbsolutePath(config.linuxHomeMountPath, fallback: defaultLinuxHomeMountPath),
            macShareGuestPath: config.macShareGuestPath.isEmpty ? guestShareRoot : config.macShareGuestPath
        )
    }
}

public func normalizeShareRoot(_ value: String?) -> String {
    let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let expanded: String
    if raw == "~" {
        expanded = NSHomeDirectory()
    } else if raw.hasPrefix("~/") {
        expanded = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(String(raw.dropFirst(2))).path
    } else if raw.isEmpty {
        expanded = NSHomeDirectory()
    } else {
        expanded = raw
    }
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
}

public func portableShareRoot(_ value: String?) -> String {
    let expanded = normalizeShareRoot(value)
    let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
    if expanded == home {
        return "~"
    }
    if expanded.hasPrefix(home + "/") {
        return "~/" + String(expanded.dropFirst(home.count + 1))
    }
    return expanded
}

public func normalizeAbsolutePath(_ value: String?, fallback: String) -> String {
    let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let expanded: String
    if raw == "~" {
        expanded = NSHomeDirectory()
    } else if raw.hasPrefix("~/") {
        expanded = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(String(raw.dropFirst(2))).path
    } else if raw.isEmpty {
        expanded = fallback
    } else {
        expanded = raw
    }
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
}

public func defaultCpuCount(runner: ProcessRunner = ProcessRunner()) -> Int {
    let names = ["hw.perflevel0.physicalcpu", "hw.physicalcpu"]
    for name in names {
        if let raw = try? Foundation.Process.runAndCapture("/usr/sbin/sysctl", ["-n", name]).trimmingCharacters(in: .whitespacesAndNewlines),
           let value = Int(raw), value > 0 {
            return value
        }
    }
    return max(1, min(8, ProcessInfo.processInfo.processorCount))
}
