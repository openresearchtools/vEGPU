import AppKit
import PEGPUCore

@MainActor
final class BatteryRuntimeSafetyMonitor: NSObject {
    private struct BatteryState {
        var installed: Bool
        var onBattery: Bool
        var percent: Int?
        var detail: String
    }

    private static let warningPercent = 15
    private static let countdownSeconds: TimeInterval = 300
    private static let pollInterval: TimeInterval = 15
    private static let activeCountdownPollInterval: TimeInterval = 3

    private let model: NativeAppModel
    private let anchorProvider: () -> NSRect?
    private let runner = ProcessRunner()
    private var pollTimer: Timer?
    private var countdownTimer: Timer?
    private var readInFlight = false
    private var lastBatteryPoll = Date.distantPast
    private var latestBattery: BatteryState?
    private var deadline: Date?
    private var shutdownInProgress = false

    private var panel: NSPanel?
    private var titleLabel: NSTextField?
    private var messageLabel: NSTextField?
    private var countdownLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var actionButton: NSButton?

    init(model: NativeAppModel, anchorProvider: @escaping () -> NSRect?) {
        self.model = model
        self.anchorProvider = anchorProvider
        super.init()
    }

    func start() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollBattery()
            }
        }
        pollBattery()
    }

    func invalidate() {
        pollTimer?.invalidate()
        countdownTimer?.invalidate()
        pollTimer = nil
        countdownTimer = nil
        panel?.close()
        panel = nil
    }

    private func pollBattery() {
        guard !readInFlight else { return }
        readInFlight = true
        Task { [weak self, runner] in
            let state = await Self.readBatteryState(runner: runner)
            await MainActor.run {
                guard let self else { return }
                self.readInFlight = false
                self.lastBatteryPoll = Date()
                self.handleBatteryState(state)
            }
        }
    }

    private func handleBatteryState(_ state: BatteryState?) {
        latestBattery = state
        guard !shutdownInProgress else {
            updateCountdownLabels()
            return
        }
        guard model.machineService.currentPid() != nil else {
            cancelCountdown()
            return
        }
        guard let state, state.installed else {
            updateCountdownLabels()
            return
        }
        guard state.onBattery else {
            cancelCountdown()
            return
        }
        guard let percent = state.percent, percent <= Self.warningPercent else {
            cancelCountdown()
            return
        }
        if deadline == nil {
            startCountdown()
        }
        updateCountdownLabels()
    }

    private func startCountdown() {
        deadline = Date().addingTimeInterval(Self.countdownSeconds)
        showPanel()
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickCountdown()
            }
        }
    }

    private func cancelCountdown() {
        deadline = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        if !shutdownInProgress {
            panel?.close()
            panel = nil
        }
    }

    private func tickCountdown() {
        guard let deadline else { return }
        if model.machineService.currentPid() == nil {
            cancelCountdown()
            return
        }
        if Date().timeIntervalSince(lastBatteryPoll) >= Self.activeCountdownPollInterval {
            pollBattery()
        }
        updateCountdownLabels()
        if Date() >= deadline {
            beginEmergencyShutdown()
        }
    }

    private func showPanel() {
        if let panel {
            positionPanel(panel)
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "PEGPU Battery Safety"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = Self.label("Battery below 15%", size: 24, weight: .bold)
        let messageLabel = Self.label("", size: 14, weight: .regular)
        let countdownLabel = Self.label("", size: 32, weight: .bold)
        countdownLabel.alignment = .center
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 32, weight: .bold)
        let detailLabel = Self.label("", size: 13, weight: .regular)
        let actionButton = NSButton(title: "Shut Down VM Now", target: self, action: #selector(shutDownNow))
        actionButton.bezelStyle = .rounded
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(titleLabel)
        root.addSubview(messageLabel)
        root.addSubview(countdownLabel)
        root.addSubview(detailLabel)
        root.addSubview(actionButton)
        panel.contentView = root

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            messageLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            messageLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),

            countdownLabel.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 18),
            countdownLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            countdownLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),

            detailLabel.topAnchor.constraint(equalTo: countdownLabel.bottomAnchor, constant: 16),
            detailLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            detailLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),

            actionButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            actionButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])

        self.panel = panel
        self.titleLabel = titleLabel
        self.messageLabel = messageLabel
        self.countdownLabel = countdownLabel
        self.detailLabel = detailLabel
        self.actionButton = actionButton

        updateCountdownLabels()
        positionPanel(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func updateCountdownLabels() {
        guard panel != nil else { return }
        let percentText = latestBattery?.percent.map { "\($0)%" } ?? "below \(Self.warningPercent)%"
        if shutdownInProgress {
            titleLabel?.stringValue = "Low battery: shutting down PEGPU VM"
            messageLabel?.stringValue = "PEGPU is stopping the VM through the normal guest and QEMU paths. If the VM does not stop cleanly, QEMU will be force killed."
            countdownLabel?.stringValue = "Shutdown in progress"
            detailLabel?.stringValue = "Sleep prevention will be turned off after the VM has stopped or QEMU has been killed."
            actionButton?.isEnabled = false
            return
        }

        titleLabel?.stringValue = "Battery below \(Self.warningPercent)%"
        messageLabel?.stringValue = "Battery is \(percentText) and the Mac is running on battery. The PEGPU VM will shut down automatically to prevent full battery drain and PCIe sleep/panic risk."
        detailLabel?.stringValue = "Plug in a power adapter to cancel automatically, or shut down the VM now. Closing this warning will not cancel the countdown."
        actionButton?.isEnabled = true

        if let deadline {
            let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
            countdownLabel?.stringValue = "VM shutdown in \(Self.format(seconds: remaining))"
        } else {
            countdownLabel?.stringValue = "VM shutdown pending"
        }
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let anchor = anchorProvider() else {
            panel.center()
            return
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        let margin: CGFloat = 8
        let minX = visible.minX + 12
        let maxX = visible.maxX - size.width - 12
        let x = min(max(anchor.midX - size.width / 2, minX), maxX)
        var y = anchor.minY - size.height - margin
        if y < visible.minY + 12 {
            y = min(anchor.maxY + margin, visible.maxY - size.height - 12)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func shutDownNow() {
        beginEmergencyShutdown()
    }

    @objc private func dismissPanel() {
        panel?.close()
        panel = nil
    }

    private func beginEmergencyShutdown() {
        guard !shutdownInProgress else { return }
        shutdownInProgress = true
        countdownTimer?.invalidate()
        countdownTimer = nil
        showPanel()
        updateCountdownLabels()
        Task { [weak self] in
            do {
                let result = try await self?.model.shutdownRuntimeForLowBattery() ?? "Runtime shutdown completed."
                await MainActor.run {
                    self?.finishEmergencyShutdown(message: result, failed: false)
                }
            } catch {
                await MainActor.run {
                    self?.finishEmergencyShutdown(message: String(describing: error), failed: true)
                }
            }
        }
    }

    private func finishEmergencyShutdown(message: String, failed: Bool) {
        shutdownInProgress = false
        deadline = nil
        titleLabel?.stringValue = failed ? "Low battery VM shutdown needs attention" : "Low battery VM shutdown complete"
        messageLabel?.stringValue = message
        countdownLabel?.stringValue = failed ? "Check PEGPU" : "Sleep Guard Off"
        detailLabel?.stringValue = failed ? "PEGPU could not complete the emergency shutdown sequence. Plug in power now and check the runtime." : "The VM is stopped and Mac sleep prevention has been turned off."
        actionButton?.title = "OK"
        actionButton?.target = self
        actionButton?.action = #selector(dismissPanel)
        actionButton?.isEnabled = true
        if !failed {
            Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.dismissPanel()
                }
            }
        }
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: size, weight: weight)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private static func readBatteryState(runner: ProcessRunner) async -> BatteryState? {
        guard let result = try? await runner.run("/usr/sbin/ioreg", ["-r", "-d", "1", "-c", "AppleSmartBattery"], timeout: 3),
              result.code == 0,
              !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let output = result.stdout
        let installed = boolValue(output, "BatteryInstalled") ?? true
        let externalConnected = boolValue(output, "ExternalConnected")
            ?? boolValue(output, "AppleRawExternalConnected")
            ?? false
        let percent = batteryPercent(output)
        let detail = [
            percent.map { "battery \($0)%" },
            externalConnected ? "AC connected" : "on battery"
        ].compactMap { $0 }.joined(separator: "; ")
        return BatteryState(installed: installed, onBattery: !externalConnected, percent: percent, detail: detail)
    }

    private static func batteryPercent(_ text: String) -> Int? {
        if let stateOfCharge = numberValue(text, "StateOfCharge"),
           stateOfCharge >= 0,
           stateOfCharge <= 100 {
            return Int(stateOfCharge.rounded())
        }
        guard let current = numberValue(text, "CurrentCapacity") else { return nil }
        if current >= 0, current <= 100 {
            return Int(current.rounded())
        }
        guard let maxCapacity = numberValue(text, "MaxCapacity"), maxCapacity > 0 else { return nil }
        return max(0, min(100, Int((current / maxCapacity * 100).rounded())))
    }

    private static func boolValue(_ text: String, _ name: String) -> Bool? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let value = capture(text, #"\"\#(escaped)\"\s*=\s*(Yes|No)"#) else { return nil }
        return value == "Yes"
    }

    private static func numberValue(_ text: String, _ name: String) -> Double? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let value = capture(text, #"\"\#(escaped)\"\s*=\s*(-?[0-9]+(?:\.[0-9]+)?)"#) else { return nil }
        return Double(value)
    }

    private static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func format(seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}
