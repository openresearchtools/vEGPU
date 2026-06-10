import Foundation

public struct LlmsRuntimeSpec: Codable, Equatable, Sendable {
    public var id: String?
    public var command: String?
    public var args: [String]?
    public var env: [String]?
    public var port: Int?
    public var modelPaths: [String]?
    public var mountPaths: [String]?

    public init(id: String? = nil, command: String? = nil, args: [String]? = nil, env: [String]? = nil, port: Int? = nil, modelPaths: [String]? = nil, mountPaths: [String]? = nil) {
        self.id = id
        self.command = command
        self.args = args
        self.env = env
        self.port = port
        self.modelPaths = modelPaths
        self.mountPaths = mountPaths
    }
}

public struct LlmsModelInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var provider: String
    public var source: String
    public var location: String
    public var format: String
    public var modelPath: String
    public var mmprojPath: String?
    public var sizeBytes: Int64
    public var metadata: [String: String]?
}

public struct LlmsModelList: Codable, Equatable, Sendable {
    public var models: [LlmsModelInfo]
}

public struct LlmsHFDownloadSpec: Codable, Equatable, Sendable {
    public var repo: String
    public var revision: String?
    public var paths: [String]
    public var token: String?
    public var progressPath: String?
    public var restart: Bool?
}

public struct LlmsModelCopySpec: Codable, Equatable, Sendable {
    public var provider: String
    public var sourceLocation: String
    public var files: [String]
    public var macRoot: String
    public var vmRoot: String
    public var progressPath: String?
}

public struct LlmsModelCopyResult: Codable, Equatable, Sendable {
    public var copied: [String]
}

public struct RuntimeResult: Codable, Equatable, Sendable {
    public var id: String
    public var role: String
    public var host: String
    public var baseUrl: String?
    public var endpoint: String?
    public var port: Int?
    public var pidFile: String
    public var logFile: String
}

public struct LlmsRuntimeInstallSpec: Codable, Equatable, Sendable {
    public var id: String
    public var platform: String
    public var sourceDir: String
    public var serverPath: String
    public var rpcPath: String?
    public var family: String?
    public var releaseTag: String?
    public var sourceRef: String?
    public var linuxBackend: String?
    public var pairID: String?
    public var assetName: String?
    public var sha256: String?

    enum CodingKeys: String, CodingKey {
        case id
        case platform
        case sourceDir
        case serverPath
        case rpcPath
        case family
        case releaseTag
        case sourceRef
        case linuxBackend
        case pairID = "pairId"
        case assetName
        case sha256
    }

    public init(id: String, platform: String, sourceDir: String, serverPath: String, rpcPath: String? = nil, family: String? = nil, releaseTag: String? = nil, sourceRef: String? = nil, linuxBackend: String? = nil, pairID: String? = nil, assetName: String? = nil, sha256: String? = nil) {
        self.id = id
        self.platform = platform
        self.sourceDir = sourceDir
        self.serverPath = serverPath
        self.rpcPath = rpcPath
        self.family = family
        self.releaseTag = releaseTag
        self.sourceRef = sourceRef
        self.linuxBackend = linuxBackend
        self.pairID = pairID
        self.assetName = assetName
        self.sha256 = sha256
    }
}

public struct LlmsRuntimeInstallResult: Codable, Equatable, Sendable {
    public var id: String
    public var root: String
    public var server: String
    public var rpc: String?
    public var active: Bool
}

public struct LlmsRuntimeInstalledResult: Codable, Equatable, Sendable {
    public var id: String
    public var root: String
    public var installed: Bool
    public var active: Bool
    public var detail: String?
    public var family: String? = nil
    public var releaseTag: String? = nil
    public var linuxBackend: String? = nil
    public var archiveName: String? = nil
    public var sha256: String? = nil
}

public struct LlamaDevice: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var backend: String
    public var totalMiB: Int
    public var freeMiB: Int
    public var pciAddress: String?
    public var uuid: String?
    public var remote: Bool?
    public var endpoint: String?
}
