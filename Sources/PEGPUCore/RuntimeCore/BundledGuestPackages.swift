import Foundation

public struct BundledGuestPackages: Sendable {
    private let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func driverDKMSPackages() -> [ManifestPackage] {
        var out: [ManifestPackage] = []
        var seen = Set<String>()
        for root in roots() {
            let packageDir = root.appendingPathComponent("packages", isDirectory: true)
            guard let items = try? FileManager.default.contentsOfDirectory(at: packageDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
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

    public func resolve(_ package: ManifestPackage) -> String? {
        roots()
            .map { $0.appendingPathComponent(package.path).path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    private func roots() -> [URL] {
        let roots = [
            URL(fileURLWithPath: VfioApp.resourcesPath("guest-tools")),
            paths.guestPackages
        ]
        var seen = Set<String>()
        return roots.filter { seen.insert($0.path).inserted }
    }

    private func isDriverDKMSDeb(_ name: String) -> Bool {
        name.hasSuffix(".deb") && name.hasPrefix("apple-dma-dkms_")
    }
}
