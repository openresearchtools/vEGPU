import Foundation

public struct ManifestPackage: Codable, Equatable, Sendable {
    public var path: String
    public var sha512: String?

    public init(path: String, sha512: String? = nil) {
        self.path = path
        self.sha512 = sha512
    }
}

public struct RuntimeManifest: Codable, Equatable, Sendable {
    public struct Debian: Codable, Equatable, Sendable {
        public var name: String
        public var url: String
        public var sha512: String
        public var size: String
        public var variant: String
    }

    public struct Kernel: Codable, Equatable, Sendable {
        public var version: String
        public var debianPackageVersion: String?
        public var packages: [ManifestPackage]

        enum CodingKeys: String, CodingKey {
            case version
            case debianPackageVersion
            case packages
        }

        public init(version: String, debianPackageVersion: String?, packages: [ManifestPackage]) {
            self.version = version
            self.debianPackageVersion = debianPackageVersion
            self.packages = packages
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(String.self, forKey: .version)
            debianPackageVersion = try container.decodeIfPresent(String.self, forKey: .debianPackageVersion)
            packages = try container.decodeIfPresent([ManifestPackage].self, forKey: .packages)
                ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encodeIfPresent(debianPackageVersion, forKey: .debianPackageVersion)
            try container.encode(packages, forKey: .packages)
        }
    }

    public struct Driver: Codable, Equatable, Sendable {
        public var version: String
        public var moduleName: String
        public var dkmsPackages: [ManifestPackage]
    }

    public struct Nvidia: Codable, Equatable, Sendable {
        public var repository: String
        public var branch: String
        public var cudaMajor: String
        public var recommendedPackages: [String]
    }

    public var manifestVersion: Int
    public var id: String
    public var createdBy: String
    public var debian: Debian
    public var kernel: Kernel
    public var driver: Driver
    public var nvidia: Nvidia
    public var guestPackages: [ManifestPackage]

    public static let defaultManifest = RuntimeManifest(
        manifestVersion: 1,
        id: "debian-13-generic-arm64-20260509-2473",
        createdBy: "PEGPU",
        debian: Debian(
            name: "debian-13-generic-arm64-20260509-2473.qcow2",
            url: "https://cloud.debian.org/images/cloud/trixie/20260509-2473/debian-13-generic-arm64-20260509-2473.qcow2",
            sha512: "16edf9daf931f2038d9f6ed4ee3e66d6e40c0cd3826dda83563a48ef1d76cb11a51ea9094b1e727deb4ed1bd253a58bd3c135c5cc77468ff64c1029878bc32dc",
            size: "408M",
            variant: "generic"
        ),
        kernel: Kernel(version: "6.12.86+deb13-arm64", debianPackageVersion: "6.12.86-1", packages: []),
        driver: Driver(version: "0.1.0", moduleName: "apple_dma", dkmsPackages: []),
        nvidia: Nvidia(
            repository: "https://developer.download.nvidia.com/compute/cuda/repos/debian13/sbsa",
            branch: "595.71.05",
            cudaMajor: "13.2",
            recommendedPackages: [
                "nvidia-driver-pinning-595.71.05",
                "nvidia-open=595.71.05-1",
                "cuda-toolkit-13-2=13.2.1-1"
            ]
        ),
        guestPackages: []
    )
}

public final class ManifestStore: @unchecked Sendable {
    private let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func ensure() throws -> RuntimeManifest {
        try paths.ensureDirectories()
        try ensureManifestFile()
        try reconcileDefaultManifest()
        return try load()
    }

    public func load() throws -> RuntimeManifest {
        try ensureManifestFile()
        try reconcileDefaultManifest()
        return try JSON.read(RuntimeManifest.self, from: paths.manifest)
    }

    public func write(_ manifest: RuntimeManifest) throws {
        try JSON.write(manifest, to: paths.manifest, mode: 0o644)
    }

    public func resolvePackage(_ package: ManifestPackage) -> String? {
        guestToolRoots()
            .map { $0.appendingPathComponent(package.path).path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    public func driverDKMSPackages() -> [ManifestPackage] {
        discoveredDriverDKMSPackages()
    }

    public func guestToolRoots() -> [URL] {
        let roots = [
            URL(fileURLWithPath: VfioApp.resourcesPath("guest-tools")),
            paths.guestPackages
        ]
        var seen = Set<String>()
        return roots.filter { seen.insert($0.path).inserted }
    }

    private func discoveredDriverDKMSPackages() -> [ManifestPackage] {
        var out: [ManifestPackage] = []
        var seen = Set<String>()
        for root in guestToolRoots() {
            let packages = root.appendingPathComponent("packages", isDirectory: true)
            guard let items = try? FileManager.default.contentsOfDirectory(at: packages, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for item in items where isDriverDKMSDeb(item.lastPathComponent) {
                let relative = "packages/\(item.lastPathComponent)"
                guard seen.insert(relative).inserted else { continue }
                out.append(ManifestPackage(path: relative))
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    private func isDriverDKMSDeb(_ name: String) -> Bool {
        name.hasSuffix(".deb") &&
            (name.hasPrefix("apple-dma-dkms_") || name.hasPrefix("pegpu-guest-dma-dkms_"))
    }

    private func ensureManifestFile() throws {
        if let bundled = externalGuestManifest() {
            try write(bundled)
            return
        }
        if !FileManager.default.fileExists(atPath: paths.manifest.path) {
            try write(defaultManifest())
            return
        }
    }

    private func reconcileDefaultManifest() throws {
        if let bundled = externalGuestManifest() {
            try write(bundled)
            return
        }
        guard let current = try? JSON.read(RuntimeManifest.self, from: paths.manifest) else {
            try write(defaultManifest())
            return
        }
        let expected = defaultManifest()
        if current.createdBy == "PEGPU" &&
            (current.id != expected.id ||
             current.kernel.version == "pinned-to-debian-image" ||
             current.guestPackages.signature != expected.guestPackages.signature) {
            try write(expected)
        }
    }

    private func externalGuestManifest() -> RuntimeManifest? {
        for root in guestToolRoots() {
            let manifest = root.appendingPathComponent("manifest.json")
            if let parsed = try? JSON.read(RuntimeManifest.self, from: manifest) {
                return parsed
            }
        }
        return nil
    }

    private func defaultManifest() -> RuntimeManifest {
        .defaultManifest
    }
}

private extension Array where Element == ManifestPackage {
    var signature: String {
        map { "\($0.path):\($0.sha512 ?? "")" }.sorted().joined(separator: "|")
    }
}
