import CryptoKit
import Foundation

public struct GuestSyncMarker: Codable, Equatable, Sendable {
    public var fingerprint: String
    public var runtimePid: Int32
    public var syncedAt: String
}

public final class GuestSyncService: @unchecked Sendable {
    private let paths: AppPaths
    private let ssh: SSHClient
    private let manifestStore: ManifestStore
    private let progress: ProgressCenter

    private var markerURL: URL { paths.machine.appendingPathComponent("guest-sync.json") }

    public init(paths: AppPaths, ssh: SSHClient, manifestStore: ManifestStore, progress: ProgressCenter = .shared) {
        self.paths = paths
        self.ssh = ssh
        self.manifestStore = manifestStore
        self.progress = progress
    }

    @discardableResult
    public func sync(force: Bool = false, runtimePid: Int32? = nil) async throws -> Bool {
        let manifest = try manifestStore.load()
        let fingerprint = try guestSyncFingerprint(manifest: manifest)
        progress.report(ProgressEvent(stage: "guest-sync", message: "Refreshing guest scripts"))
        _ = try await ssh.ssh("mkdir -p /tmp/vegpu-sync")
        try await syncGuestScripts()
        try await syncGuiAssets()
        try await syncScalingApp()
        if !force, let runtimePid, markerMatches(runtimePid: runtimePid, fingerprint: fingerprint) {
            return false
        }

        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vegpu-guest-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        progress.report(ProgressEvent(stage: "guest-sync", message: "Preparing guest manifest"))
        let manifestFile = temp.appendingPathComponent("manifest.json")
        try JSON.write(manifest, to: manifestFile)

        progress.report(ProgressEvent(stage: "guest-sync", message: "Uploading manifest"))
        try await ssh.scpToGuest(localPath: manifestFile.path, remotePath: "/tmp/vegpu-sync/manifest.json")
        _ = try await ssh.agent(["configure-private-network"])
        progress.report(ProgressEvent(stage: "guest-sync", message: "Applying runtime manifest"))
        _ = try await ssh.agent(["ingest-manifest", "/tmp/vegpu-sync/manifest.json"])

        try await syncPackages(kind: "driver prebuilt", packages: manifest.driver.prebuiltPackages)
        try await syncPackages(kind: "driver DKMS", packages: manifest.driver.dkmsPackages)
        try await syncPackages(kind: "kernel", packages: manifest.kernel.packages)
        try await syncPackages(kind: "guest", packages: manifest.guestPackages)
        progress.report(ProgressEvent(stage: "guest-tools", message: "Installing or refreshing guest tools"))
        _ = try await ssh.agent(["update-tools"])
        if await guestDriverReady() {
            progress.report(ProgressEvent(stage: "driver", message: "Linux guest DMA driver already ready"))
        } else {
            progress.report(ProgressEvent(stage: "driver", message: "Installing or validating Linux guest DMA driver"))
            do {
                _ = try await ssh.agent(["install-driver"])
            } catch {
                progress.report(ProgressEvent(stage: "driver", message: "Linux guest DMA driver install needs attention", detail: firstLine(String(describing: error)), level: .error))
                throw RuntimeError.message("Linux guest DMA driver install failed: \(firstLine(String(describing: error)))")
            }
        }
        _ = try await ssh.agent(["status", "--json"])
        if let runtimePid {
            try JSON.write(GuestSyncMarker(fingerprint: fingerprint, runtimePid: runtimePid, syncedAt: ISO8601DateFormatter().string(from: Date())), to: markerURL)
        }
        progress.report(ProgressEvent(stage: "guest-sync", message: "Guest sync complete", level: .success))
        return true
    }

    private func syncGuestScripts() async throws {
        let guestDir = paths.resources.appendingPathComponent("Guest", isDirectory: true)
        let scripts: [(String, String)] = [
            ("vegpu-agent.sh", "/usr/local/libexec/vegpu/vegpu-agent"),
            ("customization.sh", "/usr/local/libexec/vegpu/customization.sh"),
            ("firstboot.sh", "/usr/local/sbin/vegpu-firstboot.sh"),
            ("gui-ensure.sh", "/usr/local/sbin/vegpu-gui-ensure.sh")
        ]
        for (name, destination) in scripts {
            let source = guestDir.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: source) else { continue }
            let remote = "/tmp/vegpu-sync/\(name)"
            try await ssh.scpToGuest(localPath: source, remotePath: remote)
            _ = try await ssh.ssh("sudo -n install -d \(shellQuote(URL(fileURLWithPath: destination).deletingLastPathComponent().path)) && sudo -n install -m 0755 \(shellQuote(remote)) \(shellQuote(destination))")
        }
    }

    private func syncGuiAssets() async throws {
        let assetsDir = paths.resources.appendingPathComponent("Assets", isDirectory: true)
        let assets: [(String, String)] = [
            ("vEGPU-logo-transparent.png", "/usr/share/vegpu/gui/vEGPU-logo-transparent.png")
        ]
        for (name, destination) in assets {
            let source = assetsDir.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: source) else { continue }
            let remote = "/tmp/vegpu-sync/\(name)"
            try await ssh.scpToGuest(localPath: source, remotePath: remote)
            _ = try await ssh.ssh("sudo -n install -D -m 0644 \(shellQuote(remote)) \(shellQuote(destination))")
        }
    }

    private func syncScalingApp() async throws {
        let root = paths.resources.appendingPathComponent("Guest/scaling-app", isDirectory: true)
        if let package = scalingAppPackage(in: root) {
            let remote = "/tmp/vegpu-sync/\(package.lastPathComponent)"
            try await ssh.scpToGuest(localPath: package.path, remotePath: remote)
            _ = try await ssh.ssh("sudo -n env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 -o APT::Get::Lock-Timeout=600 install -y \(shellQuote(remote)) && rm -f \(shellQuote(remote))")
            return
        }
        let files: [(String, String)] = [
            ("install.sh", "0755"),
            ("bin/vegpu-scaling", "0755"),
            ("src/vegpu_scaling.py", "0644"),
            ("share/applications/vegpu-scaling.desktop", "0644"),
            ("share/icons/hicolor/scalable/apps/vegpu-scaling.svg", "0644"),
            ("share/xdg/autostart/vegpu-scaling-reapply.desktop", "0644")
        ]
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("install.sh").path) else { return }
        _ = try await ssh.ssh("sudo -n rm -rf /usr/local/libexec/vegpu/scaling-app && sudo -n install -d /usr/local/libexec/vegpu/scaling-app")
        for (relative, mode) in files {
            let source = root.appendingPathComponent(relative).path
            guard FileManager.default.fileExists(atPath: source) else { continue }
            let remote = "/tmp/vegpu-sync/scaling-app/\(relative)"
            let destination = "/usr/local/libexec/vegpu/scaling-app/\(relative)"
            _ = try await ssh.ssh("mkdir -p \(shellQuote(URL(fileURLWithPath: remote).deletingLastPathComponent().path))")
            try await ssh.scpToGuest(localPath: source, remotePath: remote)
            _ = try await ssh.ssh("sudo -n install -D -m \(mode) \(shellQuote(remote)) \(shellQuote(destination))")
        }
        _ = try await ssh.ssh("sudo -n env VEGPU_SCALING_SKIP_DEPS=1 /usr/local/libexec/vegpu/scaling-app/install.sh")
    }

    private func scalingAppPackage(in root: URL) -> URL? {
        let packageDir = root.appendingPathComponent("package", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: packageDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        return items
            .filter { $0.lastPathComponent.hasPrefix("vegpu-scaling_") && $0.pathExtension == "deb" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last
    }

    private func syncPackages(kind: String, packages: [ManifestPackage]) async throws {
        for package in packages {
            guard let local = manifestStore.resolvePackage(package) else {
                throw RuntimeError.message("Missing \(kind) package referenced by manifest: \(package.path)")
            }
            let remote = "/tmp/vegpu-sync/\(URL(fileURLWithPath: package.path).lastPathComponent)"
            progress.report(ProgressEvent(stage: "guest-sync", message: "Uploading \(kind) package", detail: URL(fileURLWithPath: package.path).lastPathComponent))
            try await ssh.scpToGuest(localPath: local, remotePath: remote)
            progress.report(ProgressEvent(stage: "guest-sync", message: "Registering \(kind) package", detail: package.path))
            _ = try await ssh.agent(["ingest-package", remote, package.path])
        }
    }

    private func guestDriverReady() async -> Bool {
        guard let text = try? await ssh.agent(["status", "--json"]),
              let data = text.data(using: .utf8),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return status["driverInstalled"] as? String == "yes" &&
            status["moduleLoaded"] as? String == "yes" &&
            status["driverReady"] as? String == "yes" &&
            status["passthroughReady"] as? String == "yes" &&
            status["dmaDevicePresent"] as? String == "yes"
    }

    private func guestSyncFingerprint(manifest: RuntimeManifest) throws -> String {
        var hasher = SHA256()
        hasher.update(data: try JSON.encoder.encode(manifest))
        let guestDir = paths.resources.appendingPathComponent("Guest", isDirectory: true)
        for script in ["vegpu-agent.sh", "customization.sh", "gui-ensure.sh", "firstboot.sh"] {
            hasher.update(data: Data([0]))
            hasher.update(data: Data(script.utf8))
            if let data = try? Data(contentsOf: guestDir.appendingPathComponent(script)) {
                hasher.update(data: Data([0]))
                hasher.update(data: data)
            }
        }
        let assetsDir = paths.resources.appendingPathComponent("Assets", isDirectory: true)
        for asset in ["vEGPU-logo-transparent.png"] {
            hasher.update(data: Data([0]))
            hasher.update(data: Data(asset.utf8))
            if let data = try? Data(contentsOf: assetsDir.appendingPathComponent(asset)) {
                hasher.update(data: Data([0]))
                hasher.update(data: data)
            }
        }
        let scalingAppDir = guestDir.appendingPathComponent("scaling-app", isDirectory: true)
        for relative in [
            "install.sh",
            "bin/vegpu-scaling",
            "src/vegpu_scaling.py",
            "share/applications/vegpu-scaling.desktop",
            "share/icons/hicolor/scalable/apps/vegpu-scaling.svg",
            "share/xdg/autostart/vegpu-scaling-reapply.desktop"
        ] {
            hasher.update(data: Data([0]))
            hasher.update(data: Data("scaling-app/\(relative)".utf8))
            if let data = try? Data(contentsOf: scalingAppDir.appendingPathComponent(relative)) {
                hasher.update(data: Data([0]))
                hasher.update(data: data)
            }
        }
        for package in manifest.driver.prebuiltPackages + manifest.driver.dkmsPackages + manifest.kernel.packages + manifest.guestPackages {
            hasher.update(data: Data([0]))
            hasher.update(data: Data(package.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data((package.sha512 ?? "").utf8))
            if let local = manifestStore.resolvePackage(package),
               let attrs = try? FileManager.default.attributesOfItem(atPath: local) {
                hasher.update(data: Data([0]))
                let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                hasher.update(data: Data(String(fileSize).utf8))
                hasher.update(data: Data([0]))
                hasher.update(data: Data(String((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0).utf8))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func markerMatches(runtimePid: Int32, fingerprint: String) -> Bool {
        guard let marker = try? JSON.read(GuestSyncMarker.self, from: markerURL) else { return false }
        return marker.runtimePid == runtimePid && marker.fingerprint == fingerprint
    }
}
