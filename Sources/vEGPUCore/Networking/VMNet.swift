import Foundation

public enum NetworkMode: String, Codable, Sendable {
    case vmnet
}

public struct NetworkState: Codable, Equatable, Sendable {
    public var mode: NetworkMode
    public var sshHost: String
    public var sshPort: Int
    public var guestHost: String
    public var macHost: String

    public init(mode: NetworkMode = .vmnet, sshHost: String = VMNet.guestIP, sshPort: Int = 22, guestHost: String = VMNet.guestIP, macHost: String = VMNet.gateway) {
        self.mode = mode
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.guestHost = guestHost
        self.macHost = macHost
    }
}

public enum VMNet {
    public static let gateway = "172.29.253.1"
    public static let dhcpEnd = "172.29.253.99"
    public static let mask = "255.255.255.0"
    public static let guestIP = "172.29.253.100"
    public static let mac = "de:ad:be:ef:10:01"
}

public final class NetworkStateStore: @unchecked Sendable {
    private let paths: AppPaths
    private var stateURL: URL { paths.machine.appendingPathComponent("network.json") }

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func read() -> NetworkState {
        guard let data = try? Data(contentsOf: stateURL),
              let parsed = try? JSONDecoder().decode(NetworkState.self, from: data),
              parsed.mode == .vmnet else {
            return NetworkState()
        }
        let guestHost = parsed.guestHost.isEmpty ? VMNet.guestIP : parsed.guestHost
        let macHost = parsed.macHost.isEmpty || parsed.macHost == guestHost ? VMNet.gateway : parsed.macHost
        return NetworkState(sshHost: guestHost, sshPort: parsed.sshPort, guestHost: guestHost, macHost: macHost)
    }

    public func write(_ state: NetworkState) throws {
        try JSON.write(state, to: stateURL)
    }

    public func launcherNetwork(toolPaths: ToolPaths) -> LauncherNetwork {
        LauncherNetwork(
            state: NetworkState(),
            launchCommand: toolPaths.qemuLauncher,
            launcherArgs: [
                "--vmnet-netdev", "vmnet-shared",
                "--vmnet-start-address", VMNet.gateway,
                "--vmnet-end-address", VMNet.dhcpEnd,
                "--vmnet-subnet-mask", VMNet.mask
            ]
        )
    }
}

public struct LauncherNetwork: Sendable {
    public let state: NetworkState
    public let launchCommand: String
    public let launcherArgs: [String]
}
