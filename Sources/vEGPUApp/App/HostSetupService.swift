import Foundation
import vEGPUCore

final class HostSetupService: @unchecked Sendable {
    private let paths: AppPaths
    private let configStore: MachineConfigStore
    private let share: NFSShareService
    private let progress: ProgressCenter
    private let version = "2026-06-05-stable-nfs-share"

    init(paths: AppPaths, progress: ProgressCenter) {
        self.paths = paths
        self.progress = progress
        self.configStore = MachineConfigStore(paths: paths)
        let networkStore = NetworkStateStore(paths: paths)
        let ssh = SSHClient(paths: paths, networkStore: networkStore, progress: progress)
        self.share = NFSShareService(paths: paths, ssh: ssh, progress: progress)
    }

    func ensureFirstRunHostSetup() async {
        let shareRoot = configStore.effective().shareRoot
        let stateURL = paths.appData.appendingPathComponent("setup/host-setup.json")
        if setupStateMatches(stateURL: stateURL, shareRoot: shareRoot) {
            return
        }
        do {
            progress.report(ProgressEvent(stage: "setup", message: "Preparing Mac host services", detail: "NFS share and local helper state"))
            _ = try await share.ensureHostShare(shareRoot)
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload: [String: String] = [
                "version": version,
                "shareRoot": shareRoot,
                "configuredAt": ISO8601DateFormatter().string(from: Date())
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: stateURL, options: .atomic)
            progress.report(ProgressEvent(stage: "setup", message: "Mac host services are ready", level: .success))
        } catch {
            progress.report(ProgressEvent(stage: "setup", message: "Mac host setup is incomplete", detail: firstLine(String(describing: error)), level: .error))
        }
    }

    private func setupStateMatches(stateURL: URL, shareRoot: String) -> Bool {
        guard let data = try? Data(contentsOf: stateURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return raw["version"] as? String == version && raw["shareRoot"] as? String == shareRoot
    }
}
