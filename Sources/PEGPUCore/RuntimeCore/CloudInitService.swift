import Foundation

public final class CloudInitService: @unchecked Sendable {
    private let paths: AppPaths
    private let files: MachineFiles
    private let ssh: SSHClient
    private let secrets: SecretsStore
    private let manifestStore: ManifestStore
    private let bundledGuestPackages: BundledGuestPackages
    private let runner: ProcessRunner

    public init(paths: AppPaths, ssh: SSHClient, secrets: SecretsStore, manifestStore: ManifestStore, runner: ProcessRunner = ProcessRunner()) {
        self.paths = paths
        self.files = MachineFiles(machineDir: paths.machine)
        self.ssh = ssh
        self.secrets = secrets
        self.manifestStore = manifestStore
        self.bundledGuestPackages = BundledGuestPackages(paths: paths)
        self.runner = runner
    }

    @discardableResult
    public func createSeedIso(mode: RuntimeLaunchMode = MachineConfig.defaultLaunchMode, guiRetina: Bool = MachineConfig.defaultGuiRetina, guiAppearance: GUIAppearance = .dark, force: Bool = false) async throws -> String {
        _ = try await ssh.ensureKey()
        let machineSecrets = try secrets.ensure()
        let publicKey = try String(contentsOfFile: "\(ssh.privateKeyPath).pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let seedDir = paths.machine.appendingPathComponent("seed", isDirectory: true)
        if !force, FileManager.default.fileExists(atPath: files.seedIso.path) {
            return files.seedIso.path
        }
        try? FileManager.default.removeItem(at: seedDir)
        try FileManager.default.createDirectory(at: seedDir, withIntermediateDirectories: true)
        try "instance-id: pegpu-machine-vmnet-static-v3-\(mode.rawValue)\nlocal-hostname: pegpu-runtime\n".write(to: seedDir.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)
        try networkConfig().write(to: seedDir.appendingPathComponent("network-config"), atomically: true, encoding: .utf8)
        try userData(publicKey: publicKey, password: machineSecrets.linuxPassword, mode: mode, guiRetina: guiRetina, guiAppearance: guiAppearance).write(to: seedDir.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
        try writeSeedGuestBundle(seedDir: seedDir)
        try? FileManager.default.removeItem(at: files.seedIso)
        _ = try await runner.runChecked("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata", "-o", files.seedIso.path, seedDir.path])
        chmod(files.seedIso.path, 0o600)
        return files.seedIso.path
    }

    private func networkConfig() -> String {
        """
        version: 2
        ethernets:
          vmnet0:
            match:
              macaddress: \(VMNet.mac)
            set-name: enp0s3
            dhcp4: false
            dhcp6: false
            mtu: 1500
            addresses:
              - \(VMNet.guestIP)/24
            routes:
              - to: default
                via: \(VMNet.gateway)
            nameservers:
              addresses:
                - \(VMNet.gateway)
                - 1.1.1.1
        """
    }

    private func userData(publicKey: String, password: String, mode: RuntimeLaunchMode, guiRetina: Bool, guiAppearance: GUIAppearance) throws -> String {
        let agent = try String(contentsOf: paths.resources.appendingPathComponent("Guest/pegpu-agent.sh"), encoding: .utf8)
        let firstBoot = try String(contentsOf: paths.resources.appendingPathComponent("Guest/pegpu-firstboot.sh"), encoding: .utf8)
        let llamaRuntimeReconcile = try String(contentsOf: paths.resources.appendingPathComponent("Guest/reconcile-llama-runtimes.sh"), encoding: .utf8)
        let guiBoot = mode == .gui ? try String(contentsOf: paths.resources.appendingPathComponent("Guest/pegpu-gui-ensure.sh"), encoding: .utf8) : nil
        let guiCustomization = mode == .gui ? try String(contentsOf: paths.resources.appendingPathComponent("Guest/customization.sh"), encoding: .utf8) : nil
        let guiAssetWriteFile = mode == .gui ? try guiAssetWriteFiles() : ""
        let guiScalingAppWriteFiles = mode == .gui ? try scalingAppWriteFiles() : ""
        let guiWriteFile = guiBoot.map {
            """
              - path: /usr/local/sbin/pegpu-gui-ensure.sh
                owner: root:root
                permissions: '0755'
                encoding: b64
                content: \(base64($0))
            """
        } ?? ""
        let guiCustomizationWriteFile = guiCustomization.map {
            """
              - path: /usr/local/libexec/pegpu/customization.sh
                owner: root:root
                permissions: '0755'
                encoding: b64
                content: \(base64($0))
            """
        } ?? ""
        let guiRunCommand = mode == .gui ? "\n  - [ env, PEGPU_FORCE_SPICE_ON_LAUNCH=1, PEGPU_GUI_RETINA=\(guiRetina ? "1" : "0"), PEGPU_GUI_APPEARANCE=\(guiAppearance.rawValue), /usr/local/sbin/pegpu-gui-ensure.sh ]" : ""
        return """
        #cloud-config
        users:
          - name: pegpu
            groups: sudo
            shell: /bin/bash
            sudo: ALL=(ALL) ALL
            lock_passwd: false
            plain_text_passwd: \(yamlSingleQuote(password))
            ssh_authorized_keys:
              - \(yamlSingleQuote(publicKey))
          - name: pegpuctl
            groups: sudo
            shell: /bin/bash
            sudo: ALL=(ALL) NOPASSWD:ALL
            lock_passwd: true
            ssh_authorized_keys:
              - \(yamlSingleQuote(publicKey))
        chpasswd:
          expire: false
          users:
            - name: pegpu
              password: \(yamlSingleQuote(password))
              type: text
        ssh_pwauth: false
        disable_root: true
        package_update: false
        growpart:
          mode: off
        resize_rootfs: false
        write_files:
          - path: /usr/local/libexec/pegpu/pegpu-agent
            owner: root:root
            permissions: '0755'
            encoding: b64
            content: \(base64(agent))
          - path: /usr/local/sbin/pegpu-firstboot.sh
            owner: root:root
            permissions: '0755'
            encoding: b64
            content: \(base64(firstBoot))
          - path: /usr/local/libexec/pegpu/reconcile-llama-runtimes
            owner: root:root
            permissions: '0755'
            encoding: b64
            content: \(base64(llamaRuntimeReconcile))
          - path: /etc/sudoers.d/90-pegpu-control
            owner: root:root
            permissions: '0440'
            content: |
              pegpuctl ALL=(root) NOPASSWD:ALL
        \(guiAssetWriteFile)
        \(guiScalingAppWriteFiles)
        \(guiCustomizationWriteFile)
        \(guiWriteFile)
        runcmd:
          - [ /usr/local/sbin/pegpu-firstboot.sh ]\(guiRunCommand)
        """
    }

    private func guiAssetWriteFiles() throws -> String {
        let logo = paths.resources.appendingPathComponent("Assets/PEGPU-logo-transparent.png")
        guard FileManager.default.fileExists(atPath: logo.path) else { return "" }
        let data = try Data(contentsOf: logo).base64EncodedString()
        return """
          - path: /usr/share/pegpu/gui/PEGPU-logo-transparent.png
            owner: root:root
            permissions: '0644'
            encoding: b64
            content: \(data)
        """
    }

    private func scalingAppWriteFiles() throws -> String {
        let root = paths.resources.appendingPathComponent("Guest/scaling-app", isDirectory: true)
        let files: [(String, String)] = [
            ("install.sh", "0755"),
            ("bin/pegpu-scaling", "0755"),
            ("src/pegpu_scaling.py", "0644"),
            ("share/applications/pegpu-scaling.desktop", "0644"),
            ("share/icons/hicolor/scalable/apps/pegpu-scaling.svg", "0644"),
            ("share/xdg/autostart/pegpu-scaling-reapply.desktop", "0644")
        ]
        var entries: [String] = try files.compactMap { relative, mode in
            let source = root.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: source.path) else { return nil }
            let text = try String(contentsOf: source, encoding: .utf8)
            return """
              - path: /usr/local/libexec/pegpu/scaling-app/\(relative)
                owner: root:root
                permissions: '\(mode)'
                encoding: b64
                content: \(base64(text))
            """
        }
        if let package = scalingAppPackage(in: root) {
            let data = try Data(contentsOf: package)
            entries.append("""
              - path: /var/lib/pegpu/packages/\(package.lastPathComponent)
                owner: root:root
                permissions: '0644'
                encoding: b64
                content: \(base64(data))
            """)
        }
        return entries.joined(separator: "\n")
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

    private func writeSeedGuestBundle(seedDir: URL) throws {
        let manifest = try manifestStore.load()
        let bundledDriverPackages = bundledGuestPackages.driverDKMSPackages()
        let bundle = seedDir.appendingPathComponent("pegpu", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try JSON.write(manifest, to: bundle.appendingPathComponent("manifest.json"))
        let packages = bundledDriverPackages + manifest.guestPackages
        for package in packages {
            try copySeedPackage(bundle: bundle, package: package)
        }
    }

    private func copySeedPackage(bundle: URL, package: ManifestPackage) throws {
        guard let source = bundledGuestPackages.resolve(package) else {
            throw RuntimeError.message("Missing guest package: \(package.path)")
        }
        let destination = bundle.appendingPathComponent(package.path).standardizedFileURL
        let root = bundle.standardizedFileURL.path + "/"
        guard destination.path.hasPrefix(root) else {
            throw RuntimeError.message("Refusing to copy guest package outside seed bundle: \(package.path)")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(atPath: source, toPath: destination.path)
    }

}
