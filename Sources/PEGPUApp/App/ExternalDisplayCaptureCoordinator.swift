import AppKit
import PEGPUCore

@MainActor
final class ExternalDisplayCaptureCoordinator: ObservableObject {
    @Published private(set) var captureActive = false
    @Published private(set) var captureSessionID: String?
    @Published private(set) var statusMessage: String?

    private var displaySession: SpiceSessionController
    private var displayControl: DisplayControlMenuModel
    private var machine: MachineService
    private let overlay = ExternalDisplayCaptureOverlayController()
    private var activationTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var generation = UUID()

    init(displaySession: SpiceSessionController, displayControl: DisplayControlMenuModel, machine: MachineService) {
        self.displaySession = displaySession
        self.displayControl = displayControl
        self.machine = machine
    }

    func rebind(displaySession: SpiceSessionController, displayControl: DisplayControlMenuModel, machine: MachineService) {
        forceRelease(disconnect: true, restorePreviousApp: false)
        self.displaySession = displaySession
        self.displayControl = displayControl
        self.machine = machine
        statusMessage = nil
    }

    func handleHotkey(digit: Int) {
        guard (1...9).contains(digit) else { return }
        if digit == 1 {
            releaseCapture()
        } else {
            captureOrderedSession(number: digit - 1)
        }
    }

    func captureOrderedSession(number: Int) {
        startCapture(requestedSessionID: nil) { [weak self] in
            guard let self else { return false }
            return await self.displayControl.activateOrderedSessionForCapture(number: number)
        }
    }

    func capture(session: DisplaySession) {
        startCapture(requestedSessionID: session.id) { [weak self] in
            guard let self else { return false }
            return await self.displayControl.activateSessionForCapture(session)
        }
    }

    func releaseCapture() {
        let shouldReleaseGuest = machine.currentPid() != nil
        forceRelease(disconnect: false)
        guard shouldReleaseGuest else {
            displayControl.clearRuntimeState()
            return
        }
        releaseTask?.cancel()
        releaseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.displayControl.releaseSessionForCapture()
            self.releaseTask = nil
        }
    }

    func forceRelease(disconnect: Bool, restorePreviousApp: Bool = true) {
        generation = UUID()
        activationTask?.cancel()
        activationTask = nil
        releaseTask?.cancel()
        releaseTask = nil
        overlay.hide(restorePreviousApp: restorePreviousApp)
        displaySession.setExternalInputCapture(false)
        displaySession.releaseAllInput()
        if disconnect {
            displaySession.disconnect()
        }
        captureActive = false
        captureSessionID = nil
        statusMessage = nil
    }

    func releaseForRuntimeStop(disconnect: Bool) async {
        let shouldReleaseGuest = machine.currentPid() != nil
        forceRelease(disconnect: false, restorePreviousApp: false)
        if shouldReleaseGuest {
            await displayControl.releaseSessionForCapture()
        }
        displayControl.clearRuntimeState()
        if disconnect {
            displaySession.disconnect()
        }
    }

    func forceReleaseIfCapturing(sessionID: String) {
        guard captureSessionID == sessionID || displayControl.activeSessionID == sessionID else { return }
        forceRelease(disconnect: false)
    }

    private func startCapture(
        requestedSessionID: String?,
        activation: @escaping () async -> Bool
    ) {
        guard machine.currentPid() != nil else {
            displayControl.clearRuntimeState()
            forceRelease(disconnect: false)
            return
        }

        generation = UUID()
        let currentGeneration = generation
        activationTask?.cancel()
        releaseTask?.cancel()
        statusMessage = "Starting external display capture"

        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.displaySession.start()
            self.displaySession.setDynamicResolutionEnabled(true)

            let activated = await activation()
            guard !Task.isCancelled, self.generation == currentGeneration else { return }
            guard activated else {
                self.statusMessage = self.displayControl.message ?? "External display session did not start."
                self.forceRelease(disconnect: false)
                return
            }

            self.displaySession.start()
            self.overlay.show { [weak self] event in
                self?.displaySession.handleExternalCaptureEvent(event)
            }
            self.displaySession.setExternalInputCapture(true)
            self.captureSessionID = self.displayControl.activeSessionID ?? requestedSessionID
            self.captureActive = true
            self.statusMessage = nil
            self.activationTask = nil
        }
    }
}
