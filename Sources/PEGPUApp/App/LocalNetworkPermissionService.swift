import Foundation
import Network
import PEGPUCore

@MainActor
final class LocalNetworkPermissionService {
    private let progress: ProgressCenter
    private var browsers: [NWBrowser] = []
    private var listener: NWListener?
    private var started = false
    private var completed = false
    private let queue = DispatchQueue(label: "com.pegpu.app.local-network-preflight", qos: .utility)

    init(progress: ProgressCenter) {
        self.progress = progress
    }

    func start() {
        guard !started else { return }
        started = true

        progress.report(ProgressEvent(
            stage: "network",
            message: "Checking macOS Local Network permission",
            detail: "Required for VM SSH, proxy routes, and runtime RPC"
        ))

        startBonjourPublisher()
        startBonjourBrowser(type: "_pegpu-preflight._tcp")
        startBonjourBrowser(type: "_ssh._tcp")

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                self?.reportPendingPromptIfNeeded()
            }
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await MainActor.run {
                self?.finishPreflightIfNeeded()
            }
        }
    }

    private func startBonjourPublisher() {
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: "PEGPU", type: "_pegpu-preflight._tcp")
            listener.newConnectionHandler = { connection in
                connection.cancel()
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handlePublisher(state)
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            progress.report(ProgressEvent(
                stage: "network",
                message: "Local Network Bonjour preflight could not start",
                detail: String(describing: error)
            ))
        }
    }

    private func startBonjourBrowser(type: String) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleBrowser(state, type: type)
            }
        }
        browsers.append(browser)
        browser.start(queue: queue)
    }

    private func handleBrowser(_ state: NWBrowser.State, type: String) {
        guard !completed else { return }
        switch state {
        case .ready:
            break
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
                    detail: "\(type): \(String(describing: error))"
                ))
            }
            stop()
        case .cancelled:
            break
        case .setup:
            break
        @unknown default:
            break
        }
    }

    private func handlePublisher(_ state: NWListener.State) {
        guard !completed else { return }
        switch state {
        case .ready:
            break
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
                    message: "Local Network Bonjour preflight did not finish",
                    detail: String(describing: error)
                ))
            }
            stop()
        case .cancelled:
            break
        case .setup:
            break
        @unknown default:
            break
        }
    }

    private func reportPendingPromptIfNeeded() {
        guard !completed else { return }
        progress.report(ProgressEvent(
            stage: "network",
            message: "macOS Local Network permission prompt requested",
            detail: "If macOS asks, allow PEGPU. If it was denied, enable PEGPU in System Settings > Privacy & Security > Local Network."
        ))
    }

    private func finishPreflightIfNeeded() {
        guard !completed else { return }
        completed = true
        progress.report(ProgressEvent(
            stage: "network",
            message: "macOS Local Network preflight completed",
            detail: "PEGPU requested Local Network access for VM SSH and local routing.",
            level: .success
        ))
        stop()
    }

    private func reportDenied(_ error: NWError) {
        progress.report(ProgressEvent(
            stage: "network",
            message: "macOS Local Network access is denied",
            detail: "Enable PEGPU in System Settings > Privacy & Security > Local Network. Without it, VM SSH and proxy routes cannot work. \(String(describing: error))",
            level: .error
        ))
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        for browser in browsers {
            browser.cancel()
        }
        browsers.removeAll()
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
