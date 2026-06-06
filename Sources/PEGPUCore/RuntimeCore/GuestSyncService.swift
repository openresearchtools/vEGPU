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
        _ = try await ssh.ssh("mkdir -p /tmp/pegpu-sync")
        try await syncGuestScripts()
        try await syncGuiAssets()
        try await syncScalingApp()
        try await syncBundledLlamaRuntimeSeed()
        if !force, let runtimePid, markerMatches(runtimePid: runtimePid, fingerprint: fingerprint) {
            if await guestDriverReady() {
                try await reconcileBundledLlamaRuntimes()
                return false
            }
            progress.report(ProgressEvent(stage: "driver", message: "Refreshing Linux guest DMA driver for current kernel"))
        }

        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pegpu-guest-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        progress.report(ProgressEvent(stage: "guest-sync", message: "Preparing guest manifest"))
        let manifestFile = temp.appendingPathComponent("manifest.json")
        try JSON.write(manifest, to: manifestFile)

        progress.report(ProgressEvent(stage: "guest-sync", message: "Uploading manifest"))
        try await ssh.scpToGuest(localPath: manifestFile.path, remotePath: "/tmp/pegpu-sync/manifest.json")
        _ = try await ssh.agent(["configure-private-network"])
        progress.report(ProgressEvent(stage: "guest-sync", message: "Applying runtime manifest"))
        _ = try await ssh.agent(["ingest-manifest", "/tmp/pegpu-sync/manifest.json"])

        try await syncPackages(kind: "driver DKMS", packages: manifest.driver.dkmsPackages)
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
        try await reconcileBundledLlamaRuntimes()
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
            ("pegpu-agent.sh", "/usr/local/libexec/pegpu/pegpu-agent"),
            ("customization.sh", "/usr/local/libexec/pegpu/customization.sh"),
            ("reconcile-llama-runtimes.sh", "/usr/local/libexec/pegpu/reconcile-llama-runtimes"),
            ("pegpu-firstboot.sh", "/usr/local/sbin/pegpu-firstboot.sh"),
            ("pegpu-gui-ensure.sh", "/usr/local/sbin/pegpu-gui-ensure.sh")
        ]
        for (name, destination) in scripts {
            let source = guestDir.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: source) else { continue }
            let remote = "/tmp/pegpu-sync/\(name)"
            try await ssh.scpToGuest(localPath: source, remotePath: remote)
            _ = try await ssh.ssh("sudo -n install -d \(shellQuote(URL(fileURLWithPath: destination).deletingLastPathComponent().path)) && sudo -n install -m 0755 \(shellQuote(remote)) \(shellQuote(destination))")
        }
    }

    private func syncGuiAssets() async throws {
        let assetsDir = paths.resources.appendingPathComponent("Assets", isDirectory: true)
        let assets: [(String, String)] = [
            ("PEGPU-logo-transparent.png", "/usr/share/pegpu/gui/PEGPU-logo-transparent.png")
        ]
        for (name, destination) in assets {
            let source = assetsDir.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: source) else { continue }
            let remote = "/tmp/pegpu-sync/\(name)"
            try await ssh.scpToGuest(localPath: source, remotePath: remote)
            _ = try await ssh.ssh("sudo -n install -D -m 0644 \(shellQuote(remote)) \(shellQuote(destination))")
        }
    }

    private func syncScalingApp() async throws {
        let root = paths.resources.appendingPathComponent("Guest/scaling-app", isDirectory: true)
        if let package = scalingAppPackage(in: root) {
            let remote = "/tmp/pegpu-sync/\(package.lastPathComponent)"
            try await ssh.scpToGuest(localPath: package.path, remotePath: remote)
            let aptOptions = "-o DPkg::Lock::Timeout=600 -o APT::Get::Lock-Timeout=600"
            let command = [
                "sudo -n env DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true",
                "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get \(aptOptions) -f install -y",
                "sudo -n env DEBIAN_FRONTEND=noninteractive dpkg --configure -a",
                aptInstallLocalDebCommand(remote: remote, aptOptions: aptOptions),
                "rm -f \(shellQuote(remote))"
            ].joined(separator: " && ")
            _ = try await ssh.ssh(command)
            return
        }
        let files: [(String, String)] = [
            ("install.sh", "0755"),
            ("bin/pegpu-scaling", "0755"),
            ("src/pegpu_scaling.py", "0644"),
            ("share/applications/pegpu-scaling.desktop", "0644"),
            ("share/icons/hicolor/scalable/apps/pegpu-scaling.svg", "0644"),
            ("share/xdg/autostart/pegpu-scaling-reapply.desktop", "0644")
        ]
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("install.sh").path) else { return }
        _ = try await ssh.ssh("sudo -n rm -rf /usr/local/libexec/pegpu/scaling-app && sudo -n install -d /usr/local/libexec/pegpu/scaling-app")
        for (relative, mode) in files {
            let source = root.appendingPathComponent(relative).path
            guard FileManager.default.fileExists(atPath: source) else { continue }
            let remote = "/tmp/pegpu-sync/scaling-app/\(relative)"
            let destination = "/usr/local/libexec/pegpu/scaling-app/\(relative)"
            _ = try await ssh.ssh("mkdir -p \(shellQuote(URL(fileURLWithPath: remote).deletingLastPathComponent().path))")
            try await ssh.scpToGuest(localPath: source, remotePath: remote)
            _ = try await ssh.ssh("sudo -n install -D -m \(mode) \(shellQuote(remote)) \(shellQuote(destination))")
        }
        _ = try await ssh.ssh("sudo -n env PEGPU_SCALING_SKIP_DEPS=1 /usr/local/libexec/pegpu/scaling-app/install.sh")
    }

    private func scalingAppPackage(in root: URL) -> URL? {
        let packageDir = root.appendingPathComponent("package", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: packageDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        return items
            .filter { $0.lastPathComponent.hasPrefix("pegpu-scaling_") && $0.pathExtension == "deb" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last
    }

    private func aptInstallLocalDebCommand(remote: String, aptOptions: String) -> String {
        let remoteURL = URL(fileURLWithPath: remote)
        let remoteDir = remoteURL.deletingLastPathComponent().path
        let relativeDeb = "./\(remoteURL.lastPathComponent)"
        return "cd \(shellQuote(remoteDir)) && sudo -n env DEBIAN_FRONTEND=noninteractive apt-get \(aptOptions) install -y \(shellQuote(relativeDeb))"
    }

    private func syncPackages(kind: String, packages: [ManifestPackage]) async throws {
        for package in packages {
            guard let local = manifestStore.resolvePackage(package) else {
                throw RuntimeError.message("Missing \(kind) package referenced by manifest: \(package.path)")
            }
            let remote = "/tmp/pegpu-sync/\(URL(fileURLWithPath: package.path).lastPathComponent)"
            progress.report(ProgressEvent(stage: "guest-sync", message: "Uploading \(kind) package", detail: URL(fileURLWithPath: package.path).lastPathComponent))
            try await ssh.scpToGuest(localPath: local, remotePath: remote)
            progress.report(ProgressEvent(stage: "guest-sync", message: "Registering \(kind) package", detail: package.path))
            _ = try await ssh.agent(["ingest-package", remote, package.path])
        }
    }

    private func syncBundledLlamaRuntimeSeed() async throws {
        guard let seed = try bundledLlamaRuntimeSeed() else { return }
        let remoteRoot = "/var/lib/pegpu/llama-runtime-seed"
        let tempRoot = "/tmp/pegpu-sync/llama-runtime-seed-\(UUID().uuidString)"
        progress.report(ProgressEvent(stage: "guest-sync", message: "Checking bundled llama.cpp VM runtime seed"))
        _ = try await ssh.ssh("rm -rf \(shellQuote(tempRoot)) && mkdir -p \(shellQuote(tempRoot))")
        defer { Task { try? await ssh.ssh("rm -rf \(shellQuote(tempRoot))") } }
        try await ssh.scpToGuest(localPath: seed.manifest.path, remotePath: "\(tempRoot)/llama-runtime-manifest.json")
        _ = try await ssh.ssh("sudo -n install -D -m 0644 \(shellQuote("\(tempRoot)/llama-runtime-manifest.json")) \(shellQuote("\(remoteRoot)/llama-runtime-manifest.json"))")
        for asset in seed.assets {
            let remotePath = "\(remoteRoot)/\(asset.relativePath)"
            if let sha = try? await remoteSHA256(remotePath), !asset.sha256.isEmpty, sha == asset.sha256 {
                continue
            }
            progress.report(ProgressEvent(stage: "guest-sync", message: "Uploading bundled llama.cpp VM runtime", detail: asset.localURL.lastPathComponent))
            let remoteTemp = "\(tempRoot)/\(asset.localURL.lastPathComponent)"
            try await ssh.scpToGuest(localPath: asset.localURL.path, remotePath: remoteTemp)
            _ = try await ssh.ssh("sudo -n install -D -m 0644 \(shellQuote(remoteTemp)) \(shellQuote(remotePath))")
        }
    }

    private func reconcileBundledLlamaRuntimes() async throws {
        guard (try? bundledLlamaRuntimeSeed()) != nil else { return }
        progress.report(ProgressEvent(stage: "guest-sync", message: "Reconciling bundled llama.cpp VM runtimes"))
        _ = try await ssh.agent(["reconcile-llama-runtimes"], timeout: 1_800)
    }

    private func remoteSHA256(_ path: String) async throws -> String? {
        let output = try await ssh.ssh("if [ -f \(shellQuote(path)) ]; then sha256sum \(shellQuote(path)) | awk '{print $1}'; fi")
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func guestDriverReady() async -> Bool {
        guard let text = try? await ssh.agent(["status", "--json"]),
              let data = text.data(using: .utf8),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return status["driverInstalled"] as? String == "yes" &&
            status["moduleLoaded"] as? String == "yes" &&
            status["driverReady"] as? String == "yes"
    }

    private func guestSyncFingerprint(manifest: RuntimeManifest) throws -> String {
        var hasher = SHA256()
        hasher.update(data: try JSON.encoder.encode(manifest))
        let guestDir = paths.resources.appendingPathComponent("Guest", isDirectory: true)
        for script in ["pegpu-agent.sh", "customization.sh", "reconcile-llama-runtimes.sh", "pegpu-gui-ensure.sh", "pegpu-firstboot.sh"] {
            hasher.update(data: Data([0]))
            hasher.update(data: Data(script.utf8))
            if let data = try? Data(contentsOf: guestDir.appendingPathComponent(script)) {
                hasher.update(data: Data([0]))
                hasher.update(data: data)
            }
        }
        try hashBundledLlamaRuntimeSeed(into: &hasher)
        let assetsDir = paths.resources.appendingPathComponent("Assets", isDirectory: true)
        for asset in ["PEGPU-logo-transparent.png"] {
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
            "bin/pegpu-scaling",
            "src/pegpu_scaling.py",
            "share/applications/pegpu-scaling.desktop",
            "share/icons/hicolor/scalable/apps/pegpu-scaling.svg",
            "share/xdg/autostart/pegpu-scaling-reapply.desktop"
        ] {
            hasher.update(data: Data([0]))
            hasher.update(data: Data("scaling-app/\(relative)".utf8))
            if let data = try? Data(contentsOf: scalingAppDir.appendingPathComponent(relative)) {
                hasher.update(data: Data([0]))
                hasher.update(data: data)
            }
        }
        for package in manifest.driver.dkmsPackages {
            hasher.update(data: Data([0]))
            hasher.update(data: Data(package.path.utf8))
            if let local = manifestStore.resolvePackage(package) {
                hasher.update(data: Data([0]))
                hasher.update(data: Data(try sha512Hex(of: URL(fileURLWithPath: local)).utf8))
            } else {
                hasher.update(data: Data([0]))
                hasher.update(data: Data("missing".utf8))
            }
        }
        for package in manifest.guestPackages {
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

    private struct BundledLlamaRuntimeSeed {
        var manifest: URL
        var assets: [BundledLlamaRuntimeAsset]
    }

    private struct BundledLlamaRuntimeAsset {
        var backend: String
        var relativePath: String
        var sha256: String
        var localURL: URL
    }

    private func bundledLlamaRuntimeSeed() throws -> BundledLlamaRuntimeSeed? {
        let root = paths.root.appendingPathComponent("ai/bootstrap-runtimes/llama", isDirectory: true)
        let manifestURL = root.appendingPathComponent("llama-runtime-manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let data = try Data(contentsOf: manifestURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = object["assets"] as? [String: Any] else {
            throw RuntimeError.message("Bundled llama runtime manifest is invalid: \(manifestURL.path)")
        }
        let rootPath = root.standardizedFileURL.path + "/"
        var runtimeAssets: [BundledLlamaRuntimeAsset] = []
        for backend in ["cuda13", "vulkan"] {
            guard let asset = assets[backend] as? [String: Any],
                  let relativePath = asset["path"] as? String,
                  !relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RuntimeError.message("Bundled llama runtime manifest is missing \(backend) Linux asset")
            }
            let localURL = root.appendingPathComponent(relativePath).standardizedFileURL
            guard localURL.path.hasPrefix(rootPath) else {
                throw RuntimeError.message("Bundled llama runtime asset escapes seed root: \(relativePath)")
            }
            guard FileManager.default.fileExists(atPath: localURL.path) else {
                throw RuntimeError.message("Bundled llama runtime asset is missing: \(localURL.path)")
            }
            runtimeAssets.append(BundledLlamaRuntimeAsset(
                backend: backend,
                relativePath: relativePath,
                sha256: asset["sha256"] as? String ?? "",
                localURL: localURL
            ))
        }
        return BundledLlamaRuntimeSeed(manifest: manifestURL, assets: runtimeAssets)
    }

    private func hashBundledLlamaRuntimeSeed(into hasher: inout SHA256) throws {
        guard let seed = try bundledLlamaRuntimeSeed() else {
            hasher.update(data: Data("llama-runtime-seed:none".utf8))
            return
        }
        hasher.update(data: Data("llama-runtime-seed".utf8))
        hasher.update(data: try Data(contentsOf: seed.manifest))
        for asset in seed.assets.sorted(by: { $0.backend < $1.backend }) {
            hasher.update(data: Data([0]))
            hasher.update(data: Data(asset.backend.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(asset.relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(asset.sha256.utf8))
        }
    }

    private func markerMatches(runtimePid: Int32, fingerprint: String) -> Bool {
        guard let marker = try? JSON.read(GuestSyncMarker.self, from: markerURL) else { return false }
        return marker.runtimePid == runtimePid && marker.fingerprint == fingerprint
    }
}
