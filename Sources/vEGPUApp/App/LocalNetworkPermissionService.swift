import Foundation
import Network
import vEGPUCore

@MainActor
final class LocalNetworkPermissionService {
    private let progress: ProgressCenter
    private var browser: NWBrowser?
    private var started = false
    private var completed = false

    init(progress: ProgressCenter) {
        self.progress = progress
    }

    func start() {
        guard !started else { return }
        started = true

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_ssh._tcp", domain: "local."), using: parameters)
        self.browser = browser

        progress.report(ProgressEvent(
            stage: "network",
            message: "Checking macOS Local Network permission",
            detail: "Required for VM SSH, proxy routes, and runtime RPC"
        ))

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handle(state)
            }
        }
        browser.start(queue: DispatchQueue.global(qos: .utility))

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run {
                self?.reportPendingPromptIfNeeded()
            }
        }
    }

    private func handle(_ state: NWBrowser.State) {
        guard !completed else { return }
        switch state {
        case .ready:
            completed = true
            progress.report(ProgressEvent(
                stage: "network",
                message: "macOS Local Network access is available",
                detail: "vEGPU can use VM SSH and local routing",
                level: .success
            ))
            stop()
        case let .waiting(error):
            if isLocalNetworkDenied(error) {
                completed = true
                reportDenied(error)
                stop()
            }
        case let .failed(error):
            completed = true
            if isLocalNetworkDenied(error) {
                reportDenied(error)
            } else {
                progress.report(ProgressEvent(
                    stage: "network",
                    message: "Local Network permission preflight did not finish",
                    detail: String(describing: error)
                ))
            }
            stop()
        case .cancelled:
            browser = nil
        case .setup:
            break
        @unknown default:
            break
        }
    }

    private func reportPendingPromptIfNeeded() {
        guard !completed, browser != nil else { return }
        progress.report(ProgressEvent(
            stage: "network",
            message: "macOS Local Network permission prompt requested",
            detail: "If macOS asks, allow vEGPU. If it was denied, enable vEGPU in System Settings > Privacy & Security > Local Network."
        ))
    }

    private func reportDenied(_ error: NWError) {
        progress.report(ProgressEvent(
            stage: "network",
            message: "macOS Local Network access is denied",
            detail: "Enable vEGPU in System Settings > Privacy & Security > Local Network. Without it, VM SSH and proxy routes cannot work. \(String(describing: error))",
            level: .error
        ))
    }

    private func stop() {
        browser?.cancel()
        browser = nil
    }

    private func isLocalNetworkDenied(_ error: NWError) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("policydenied")
            || text.contains("policy denied")
            || text.contains("denied")
            || text.contains("not permitted")
            || text.contains("-65570")
    }
}
