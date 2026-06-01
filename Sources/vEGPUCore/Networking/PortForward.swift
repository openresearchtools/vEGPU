import Foundation

public enum PortForwardDirection: String, Codable, Sendable {
    case vmToMac
    case macToVM
}

public struct HostForward: Codable, Equatable, Sendable {
    public var macHost: String
    public var macPort: Int
    public var vmPort: Int
    public var `protocol`: String
    public var direction: PortForwardDirection

    public init(macHost: String, macPort: Int, vmPort: Int, protocol: String, direction: PortForwardDirection = .vmToMac) {
        self.macHost = macHost
        self.macPort = macPort
        self.vmPort = vmPort
        self.protocol = `protocol`.lowercased()
        self.direction = direction
    }

    public var listenerHost: String {
        direction == .macToVM ? VMNet.gateway : "127.0.0.1"
    }

    public var listenerPort: Int {
        direction == .macToVM ? vmPort : macPort
    }

    public var listenerKey: String {
        "\(direction.rawValue):\(`protocol`):\(listenerHost):\(listenerPort)"
    }

    private enum CodingKeys: String, CodingKey {
        case macHost
        case macPort
        case vmPort
        case `protocol`
        case direction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        macHost = try container.decode(String.self, forKey: .macHost)
        macPort = try container.decode(Int.self, forKey: .macPort)
        vmPort = try container.decode(Int.self, forKey: .vmPort)
        self.protocol = (try container.decodeIfPresent(String.self, forKey: .protocol) ?? "tcp").lowercased()
        let rawDirection = try container.decodeIfPresent(String.self, forKey: .direction)
        direction = rawDirection.flatMap(PortForwardDirection.init(rawValue:)) ?? .vmToMac
    }
}

public final class PortForwardService: @unchecked Sendable {
    private let paths: AppPaths
    private let networkStore: NetworkStateStore
    private let ssh: SSHClient

    public init(paths: AppPaths, networkStore: NetworkStateStore, ssh: SSHClient) {
        self.paths = paths
        self.networkStore = networkStore
        self.ssh = ssh
    }

    public var stateURL: URL {
        paths.machine.appendingPathComponent("ports.json")
    }

    public func parseForwardSpec(_ value: String) throws -> HostForward {
        let protoMatch = value.range(of: #"/(tcp|udp)$"#, options: [.regularExpression, .caseInsensitive])
        let proto = protoMatch.map { String(value[$0].dropFirst()).lowercased() } ?? "tcp"
        let withoutProto = protoMatch.map { String(value[..<$0.lowerBound]) } ?? value
        let parts = withoutProto.split(separator: ":").map(String.init)
        let network = networkStore.read()
        if parts.count == 2 {
            return HostForward(macHost: network.macHost, macPort: try requirePort(parts[0], original: value), vmPort: try requirePort(parts[1], original: value), protocol: proto)
        }
        if parts.count == 3 {
            return HostForward(macHost: try coercePrivateHost(parts[0], original: value), macPort: try requirePort(parts[1], original: value), vmPort: try requirePort(parts[2], original: value), protocol: proto)
        }
        throw RuntimeError.message("Invalid forward value: \(value). Use MAC_PORT:VM_PORT or HOST:MAC_PORT:VM_PORT.")
    }

    public func ensureHostForwards(_ forwards: [HostForward]) async throws {
        try await applyGuestPrivatePorts(forwards)
        try saveHostForwards(forwards)
    }

    public func saveHostForwards(_ forwards: [HostForward]) throws {
        try mergePortState(forwards)
    }

    public func applyGuestPrivatePorts(_ forwards: [HostForward]? = nil) async throws {
        for forward in forwards ?? readPortState() {
            guard forward.direction == .vmToMac else { continue }
            _ = try await ssh.agent(["apply-private-port", String(forward.vmPort), forward.protocol], timeout: 10)
        }
    }

    public func readHostForwards() -> [HostForward] {
        readPortState()
    }

    public func deleteHostForward(macPort: Int, protocol: String) throws {
        let proto = `protocol`.lowercased()
        var byPort = Dictionary(uniqueKeysWithValues: readPortState().map { ($0.listenerKey, $0) })
        byPort.removeValue(forKey: "\(PortForwardDirection.vmToMac.rawValue):\(proto):127.0.0.1:\(macPort)")
        let merged = sortedForwards(Array(byPort.values))
        try JSON.write(["forwards": merged], to: stateURL)
    }

    public func deleteHostForward(_ forward: HostForward) throws {
        var byPort = Dictionary(uniqueKeysWithValues: readPortState().map { ($0.listenerKey, $0) })
        byPort.removeValue(forKey: forward.listenerKey)
        let merged = sortedForwards(Array(byPort.values))
        try JSON.write(["forwards": merged], to: stateURL)
    }

    private func mergePortState(_ forwards: [HostForward]) throws {
        var byPort = Dictionary(uniqueKeysWithValues: readPortState().map { ($0.listenerKey, $0) })
        for forward in forwards {
            byPort[forward.listenerKey] = forward
        }
        let merged = sortedForwards(Array(byPort.values))
        try JSON.write(["forwards": merged], to: stateURL)
    }

    private func readPortState() -> [HostForward] {
        guard let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["forwards"],
              let encoded = try? JSONSerialization.data(withJSONObject: raw),
              let forwards = try? JSONDecoder().decode([HostForward].self, from: encoded) else {
            return []
        }
        return forwards.filter {
            $0.macPort > 0 && $0.macPort < 65536 &&
                $0.vmPort > 0 && $0.vmPort < 65536 &&
                ($0.protocol == "tcp" || $0.protocol == "udp")
        }
    }

    private func sortedForwards(_ forwards: [HostForward]) -> [HostForward] {
        forwards.sorted {
            if $0.direction != $1.direction {
                return $0.direction.rawValue < $1.direction.rawValue
            }
            if $0.listenerPort != $1.listenerPort {
                return $0.listenerPort < $1.listenerPort
            }
            if $0.protocol != $1.protocol {
                return $0.protocol < $1.protocol
            }
            return $0.macPort == $1.macPort ? $0.vmPort < $1.vmPort : $0.macPort < $1.macPort
        }
    }

    private func requirePort(_ value: String, original: String) throws -> Int {
        guard let port = Int(value), port > 0, port < 65536 else {
            throw RuntimeError.message("Invalid port in \(original)")
        }
        return port
    }

    private func coercePrivateHost(_ value: String, original: String) throws -> String {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let network = networkStore.read()
        if host.isEmpty || [network.macHost, network.guestHost, "127.0.0.1", "localhost", "::1", "[::1]", "0.0.0.0", "::", "[::]"].contains(host) {
            return network.macHost
        }
        throw RuntimeError.message("VM port publishing is private to this Mac; \(original) tried to bind \(value)")
    }
}
