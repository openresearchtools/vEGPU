import AppKit
import CocoaSpiceNoUsb
import CocoaSpiceRenderer
import MetalKit
import PEGPUCore

// CocoaSpice delivers these Objective-C channel objects from its GLib worker
// thread. We immediately hop callbacks onto the main actor before using them.
extension CSInput: @retroactive @unchecked Sendable {}
extension CSDisplay: @retroactive @unchecked Sendable {}
extension CSConnection: @retroactive @unchecked Sendable {}

private let supportedHostPasteboardTypes: [NSPasteboard.PasteboardType] = [
    .png,
    .tiff,
    .string
]

private func hostPasteboardType(for type: CSPasteboardType) -> NSPasteboard.PasteboardType? {
    switch type {
    case .png:
        return .png
    case .tiff:
        return .tiff
    case .string:
        return .string
    default:
        return nil
    }
}

@MainActor
final class SpiceSessionController: NSObject, ObservableObject, CSConnectionDelegate, CSPasteboardDelegate {
    @Published private(set) var status = "Waiting for GUI runtime"
    @Published private(set) var connected = false
    @Published private(set) var displayHealthy = false
    @Published private(set) var displayPixelSize = CGSize(width: 1280, height: 800)
    @Published private(set) var externalInputCaptureEnabled = false

    private let socketURL: URL
    private let qmpSocketURL: URL
    private let resizeCoordinator = DisplayResizeCoordinator()
    private let guestResolution: GuestDisplayResolutionService
    private weak var metalView: MTKView?
    private var renderer: CSMetalRenderer?
    private var connection: CSConnection?
    private var display: CSDisplay?
    private var input: CSInput?
    private var pressedButtons: CSInputButton = []
    private var pressedKeys: Set<Int32> = []
    private var lastRenderSize = CGSize.zero
    private var lastBackingScale: CGFloat = 1
    private var retina = true
    private var dynamicResolutionSupported = false
    private var dynamicResolutionEnabled = true
    private var spiceStarted = false
    private var shouldConnect = false
    private var connecting = false
    private var connectTask: Task<Void, Never>?
    private var pendingReconnectTask: Task<Void, Never>?
    private var displayWatchdogTask: Task<Void, Never>?
    private var displayReconnectAttempts = 0
    private var qmpMouseTask: Task<Void, Never>?
    private var qmpMousePendingRelative: Bool?
    private var qmpMouseActiveRelative: Bool?
    private var pasteboardTimer: Timer?
    private var pasteboardChangeCount = NSPasteboard.general.changeCount
    private var desiredDisplayPixelSize = CGSize.zero
    private var scrollAccumulator: CGFloat = 0

    init(socketURL: URL, qmpSocketURL: URL, paths: AppPaths) {
        self.socketURL = socketURL
        self.qmpSocketURL = qmpSocketURL
        self.guestResolution = GuestDisplayResolutionService(paths: paths)
        super.init()
    }

    func start() {
        displayReconnectAttempts = 0
        guard !spiceStarted else {
            startConnectLoop()
            return
        }
        spiceStarted = true
        if CSMain.shared.spiceStart() {
            startConnectLoop()
        } else {
            status = "SPICE worker failed to start"
        }
    }

    func reconnect() {
        displayReconnectAttempts = 0
        pendingReconnectTask?.cancel()
        Task { @MainActor [weak self] in
            await self?.guestResolution.wakeDisplay()
        }
        reconnectAfterDisconnect()
    }

    private func reconnectAfterDisconnect() {
        pendingReconnectTask?.cancel()
        disconnect()
        status = "Reconnecting"
        pendingReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            self.pendingReconnectTask = nil
            self.startConnectLoop()
        }
    }

    func disconnect() {
        shouldConnect = false
        connectTask?.cancel()
        connectTask = nil
        pendingReconnectTask?.cancel()
        pendingReconnectTask = nil
        displayWatchdogTask?.cancel()
        displayWatchdogTask = nil
        qmpMouseTask?.cancel()
        qmpMouseTask = nil
        qmpMousePendingRelative = nil
        qmpMouseActiveRelative = nil
        connecting = false
        resizeCoordinator.cancel()
        guestResolution.cancel()
        if let display, let renderer {
            display.removeRenderer(renderer)
        }
        if let connection {
            SpiceConnectionDrain.shared.drain(connection)
        }
        releaseAllInput()
        setExternalInputCaptureState(false)
        connection = nil
        display = nil
        input = nil
        stopPasteboardPolling()
        connected = false
        dynamicResolutionSupported = false
        updateDisplayHealth()
        status = "Disconnected"
    }

    func attach(metalView: MTKView, renderer: CSMetalRenderer) {
        if let currentRenderer = self.renderer, currentRenderer !== renderer, let display {
            display.removeRenderer(currentRenderer)
        }
        self.metalView = metalView
        self.renderer = renderer
        if let display {
            display.addRenderer(renderer)
            requestMetalDraw()
        }
    }

    func detach(metalView: MTKView, renderer: CSMetalRenderer) {
        if self.metalView === metalView {
            self.metalView = nil
        }
        if self.renderer === renderer {
            display?.removeRenderer(renderer)
            self.renderer = nil
        }
    }

    func setRetina(_ enabled: Bool) {
        guard retina != enabled else { return }
        retina = enabled
        requestCurrentRenderSize(force: true)
        metalView?.needsLayout = true
    }

    func setDynamicResolutionEnabled(_ enabled: Bool) {
        guard dynamicResolutionEnabled != enabled else { return }
        dynamicResolutionEnabled = enabled
        if enabled {
            requestCurrentRenderSize(force: true)
        } else {
            resizeCoordinator.cancel()
            guestResolution.cancel()
            desiredDisplayPixelSize = .zero
        }
    }

    func updateRenderSize(_ size: CGSize, backingScale: CGFloat, retina: Bool) {
        lastRenderSize = size
        lastBackingScale = backingScale
        self.retina = retina
        requestCurrentRenderSize()
    }

    func displaySize() -> CGSize {
        displayPixelSize
    }

    func handleSpiceDisplayEvent(_ event: NSEvent, geometry: DisplayRenderGeometry, in view: NSView) {
        guard let input else { return }
        guard !externalInputCaptureEnabled else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        let absolute = DisplayGeometryMapper.guestPoint(point, in: geometry)
        let monitorID = display?.monitorID ?? 0

        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            sendMouseMove(input: input, absolutePoint: absolute, event: event, monitorID: monitorID)
        case .leftMouseDown:
            sendMouseMove(input: input, absolutePoint: absolute, event: event, monitorID: monitorID)
            pressedButtons.insert(.left)
            input.sendMouseButton(.left, mask: pressedButtons, pressed: true)
        case .leftMouseUp:
            pressedButtons.remove(.left)
            input.sendMouseButton(.left, mask: pressedButtons, pressed: false)
        case .rightMouseDown:
            sendMouseMove(input: input, absolutePoint: absolute, event: event, monitorID: monitorID)
            pressedButtons.insert(.right)
            input.sendMouseButton(.right, mask: pressedButtons, pressed: true)
        case .rightMouseUp:
            pressedButtons.remove(.right)
            input.sendMouseButton(.right, mask: pressedButtons, pressed: false)
        case .otherMouseDown:
            sendMouseMove(input: input, absolutePoint: absolute, event: event, monitorID: monitorID)
            pressedButtons.insert(.middle)
            input.sendMouseButton(.middle, mask: pressedButtons, pressed: true)
        case .otherMouseUp:
            pressedButtons.remove(.middle)
            input.sendMouseButton(.middle, mask: pressedButtons, pressed: false)
        case .scrollWheel:
            sendDeterministicScroll(event, input: input)
        case .keyDown:
            sendKeyDown(event, input: input)
        case .keyUp:
            sendKeyUp(event, input: input)
        case .flagsChanged:
            syncModifiers(event.modifierFlags, input: input)
        default:
            break
        }
    }

    func handleExternalCaptureEvent(_ event: NSEvent) {
        guard externalInputCaptureEnabled, let input else { return }

        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            sendRelativeMouseMove(input: input, event: event, monitorID: 0)
        case .leftMouseDown:
            sendRelativeMouseMove(input: input, event: event, monitorID: 0)
            pressedButtons.insert(.left)
            input.sendMouseButton(.left, mask: pressedButtons, pressed: true)
        case .leftMouseUp:
            pressedButtons.remove(.left)
            input.sendMouseButton(.left, mask: pressedButtons, pressed: false)
        case .rightMouseDown:
            sendRelativeMouseMove(input: input, event: event, monitorID: 0)
            pressedButtons.insert(.right)
            input.sendMouseButton(.right, mask: pressedButtons, pressed: true)
        case .rightMouseUp:
            pressedButtons.remove(.right)
            input.sendMouseButton(.right, mask: pressedButtons, pressed: false)
        case .otherMouseDown:
            sendRelativeMouseMove(input: input, event: event, monitorID: 0)
            pressedButtons.insert(.middle)
            input.sendMouseButton(.middle, mask: pressedButtons, pressed: true)
        case .otherMouseUp:
            pressedButtons.remove(.middle)
            input.sendMouseButton(.middle, mask: pressedButtons, pressed: false)
        case .scrollWheel:
            sendDeterministicScroll(event, input: input)
        case .keyDown:
            sendKeyDown(event, input: input)
        case .keyUp:
            sendKeyUp(event, input: input)
        case .flagsChanged:
            syncModifiers(event.modifierFlags, input: input)
        default:
            break
        }
    }

    private func sendDeterministicScroll(_ event: NSEvent, input: CSInput) {
        if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
            scrollAccumulator = 0
        }
        if !event.momentumPhase.isEmpty {
            scrollAccumulator = 0
            return
        }

        scrollAccumulator += -event.scrollingDeltaY / 32.0
        while abs(scrollAccumulator) >= 1 {
            if scrollAccumulator < 0 {
                input.sendMouseScroll(.up, buttonMask: pressedButtons, dy: 0)
                scrollAccumulator += 1
            } else {
                input.sendMouseScroll(.down, buttonMask: pressedButtons, dy: 0)
                scrollAccumulator -= 1
            }
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            scrollAccumulator = 0
        }
    }

    func setExternalInputCapture(_ enabled: Bool) {
        guard externalInputCaptureEnabled != enabled else {
            if enabled {
                input?.requestMouseMode(true)
                selectQemuMouse(relative: true)
                status = "External mouse captured - ⌥⌘1 releases"
            } else {
                releaseAllInput()
                input?.requestMouseMode(false)
                selectQemuMouse(relative: false)
                if connected {
                    status = "SPICE connected"
                }
            }
            return
        }
        setExternalInputCaptureState(enabled)
        releaseAllInput()
        input?.requestMouseMode(enabled)
        selectQemuMouse(relative: enabled)
        if enabled {
            status = "External mouse captured - ⌥⌘1 releases"
        } else if connected {
            status = "SPICE connected"
        }
    }

    private func setExternalInputCaptureState(_ enabled: Bool) {
        guard externalInputCaptureEnabled != enabled else { return }
        externalInputCaptureEnabled = enabled
        NotificationCenter.default.post(name: .pegpuExternalInputCaptureDidChange, object: enabled)
    }

    func releaseAllInput() {
        guard let input else {
            pressedButtons = []
            pressedKeys.removeAll()
            return
        }
        input.releaseKeys()
        for scan in pressedKeys {
            input.send(.release, code: scan)
        }
        pressedKeys.removeAll()
        for button in [CSInputButton.left, .right, .middle] where pressedButtons.contains(button) {
            input.sendMouseButton(button, mask: [], pressed: false)
        }
        pressedButtons = []
    }

    func spiceCursorIsVisible() -> Bool {
        display?.cursor?.isVisible == true
    }

    private func sendMouseMove(input: CSInput, absolutePoint: CGPoint?, event: NSEvent, monitorID: Int) {
        if input.serverModeCursor {
            input.requestMouseMode(false)
        }
        guard let absolutePoint else { return }
        input.sendMousePosition(pressedButtons, absolutePoint: absolutePoint, forMonitorID: monitorID)
        display?.cursor?.move(to: absolutePoint)
    }

    private func sendRelativeMouseMove(input: CSInput, event: NSEvent, monitorID: Int) {
        if !input.serverModeCursor {
            input.requestMouseMode(true)
        }
        let cgDx = event.cgEvent?.getIntegerValueField(.mouseEventDeltaX) ?? 0
        let cgDy = event.cgEvent?.getIntegerValueField(.mouseEventDeltaY) ?? 0
        let fallbackDx = Int64(event.deltaX.rounded())
        let fallbackDy = Int64(event.deltaY.rounded())
        let dx = cgDx != 0 ? cgDx : fallbackDx
        let dy = cgDy != 0 ? cgDy : fallbackDy
        guard dx != 0 || dy != 0 else { return }
        input.sendMouseMotion(
            pressedButtons,
            relativePoint: CGPoint(x: CGFloat(dx), y: CGFloat(dy)),
            forMonitorID: monitorID
        )
    }

    private func selectQemuMouse(relative: Bool) {
        if qmpMousePendingRelative == relative || qmpMouseActiveRelative == relative {
            return
        }
        let qmpSocketURL = qmpSocketURL
        qmpMousePendingRelative = relative
        qmpMouseTask?.cancel()
        qmpMouseTask = Task { [weak self] in
            do {
                let qmp = QMPClient(socketURL: qmpSocketURL)
                if relative {
                    try await Self.ensureRelativeMouseDevice(qmp)
                }
                guard let index = try await Self.mouseIndex(qmp, relative: relative) else {
                    await MainActor.run { [weak self] in
                        guard let self, self.qmpMousePendingRelative == relative else { return }
                        self.qmpMousePendingRelative = nil
                    }
                    return
                }
                try await qmp.executeVoid(
                    "human-monitor-command",
                    arguments: ["command-line": "mouse_set \(index)"]
                )
                await MainActor.run { [weak self] in
                    guard let self, self.qmpMousePendingRelative == relative else { return }
                    self.qmpMouseActiveRelative = relative
                    self.qmpMousePendingRelative = nil
                }
            } catch {
                // SPICE input mode remains the fallback; QMP is only needed to pick
                // the tablet vs relative mouse device when both are present.
                await MainActor.run { [weak self] in
                    guard let self, self.qmpMousePendingRelative == relative else { return }
                    self.qmpMousePendingRelative = nil
                }
            }
        }
    }

    private nonisolated static func ensureRelativeMouseDevice(_ qmp: QMPClient) async throws {
        if try await mouseIndex(qmp, relative: true) != nil {
            return
        }
        do {
            try await qmp.executeVoid(
                "device_add",
                arguments: [
                    "driver": "usb-mouse",
                    "id": "pegpu-relative-mouse",
                    "bus": "xhci.0"
                ]
            )
        } catch {
            // If the device already exists but query-mice had not refreshed yet,
            // keep going and try to select it below.
        }
    }

    private nonisolated static func mouseIndex(_ qmp: QMPClient, relative: Bool) async throws -> Int? {
        let mice = try await qmp.queryMice()
        for mouse in mice {
            guard mouse.absolute != relative else {
                continue
            }
            return mouse.index
        }
        return nil
    }

    private func requestCurrentRenderSize(force: Bool = false) {
        guard dynamicResolutionEnabled else { return }
        guard lastRenderSize.width > 0, lastRenderSize.height > 0 else { return }
        desiredDisplayPixelSize = resizeCoordinator.targetSize(
            size: lastRenderSize,
            backingScale: lastBackingScale,
            retina: retina
        )
        let target = resizeCoordinator.request(
            display: display,
            size: lastRenderSize,
            backingScale: lastBackingScale,
            retina: retina,
            force: force
        )
        if let target {
            let desktopScale = retina ? max(1, lastBackingScale) : 1
            guestResolution.request(target, desktopScale: desktopScale, force: force)
        }
    }

    private func updateDisplayHealth() {
        displayHealthy = display != nil && dynamicResolutionSupported
    }

    private func connect() {
        guard shouldConnect else { return }
        guard !connected, !connecting else { return }
        connection?.disconnect()
        let connection = CSConnection(unixSocketFile: socketURL.standardizedFileURL)
        connection.delegate = self
        connection.audioEnabled = true
        connection.session.shareClipboard = true
        connection.session.pasteboardDelegate = self
        self.connection = connection
        if connection.connect() {
            connecting = true
            status = "Connecting to \(socketURL.lastPathComponent)"
        } else {
            connecting = false
            status = "SPICE connect failed"
        }
    }

    private func startConnectLoop() {
        shouldConnect = true
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.connect()
                if self.connected || self.connecting {
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func bind(display newDisplay: CSDisplay) {
        if let display, let renderer {
            display.removeRenderer(renderer)
        }
        display = newDisplay
        displayPixelSize = newDisplay.displaySize
        updateDisplayHealth()
        if let renderer {
            newDisplay.addRenderer(renderer)
        }
        status = "Display \(Int(newDisplay.displaySize.width))x\(Int(newDisplay.displaySize.height))"
        metalView?.needsLayout = true
        requestMetalDraw()
        requestCurrentRenderSize(force: true)
    }

    private func sendKeyDown(_ event: NSEvent, input: CSInput) {
        if sendCommandShortcut(event, input: input) {
            return
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            return
        }
        guard !event.isARepeat else { return }
        guard let scan = SpiceKeyboardMapper.scanCode(for: event) else { return }
        syncModifiers(event.modifierFlags, input: input)
        guard !pressedKeys.contains(scan) else { return }
        pressedKeys.insert(scan)
        input.send(.press, code: scan)
    }

    private func sendKeyUp(_ event: NSEvent, input: CSInput) {
        guard let scan = SpiceKeyboardMapper.scanCode(for: event) else { return }
        if pressedKeys.remove(scan) != nil {
            input.send(.release, code: scan)
        }
    }

    private func sendCommandShortcut(_ event: NSEvent, input: CSInput) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let char = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }
        let scan: Int32?
        switch char {
        case "c": scan = 0x2e
        case "v": scan = 0x2f
        case "x": scan = 0x2d
        default: scan = nil
        }
        guard let scan else { return false }
        input.send(.press, code: 0x1d)
        input.send(.press, code: scan)
        input.send(.release, code: scan)
        input.send(.release, code: 0x1d)
        return true
    }

    private func syncModifiers(_ flags: NSEvent.ModifierFlags, input: CSInput) {
        let desired = modifierScans(for: flags)
        let currentlyPressed = Set(pressedKeys.filter { isModifierScan($0) })
        for scan in currentlyPressed.subtracting(desired) {
            input.send(.release, code: scan)
            pressedKeys.remove(scan)
        }
        for scan in desired.subtracting(currentlyPressed) {
            input.send(.press, code: scan)
            pressedKeys.insert(scan)
        }
    }

    private func modifierScans(for flags: NSEvent.ModifierFlags) -> Set<Int32> {
        SpiceKeyboardMapper.modifierScanCodes(for: flags)
    }

    private func isModifierScan(_ scan: Int32) -> Bool {
        SpiceKeyboardMapper.isModifierScan(scan)
    }

    private func didConnect() {
        connecting = false
        connectTask?.cancel()
        connectTask = nil
        connected = true
        updateDisplayHealth()
        startPasteboardPolling()
        status = "SPICE connected"
        scheduleDisplayWatchdogIfNeeded()
    }

    private func didDisconnect() {
        connecting = false
        connected = false
        releaseAllInput()
        setExternalInputCaptureState(false)
        qmpMouseTask?.cancel()
        qmpMouseTask = nil
        connection = nil
        display = nil
        input = nil
        stopPasteboardPolling()
        dynamicResolutionSupported = false
        updateDisplayHealth()
        status = "SPICE disconnected"
        if shouldConnect {
            startConnectLoop()
        }
    }

    private func startPasteboardPolling() {
        pasteboardChangeCount = NSPasteboard.general.changeCount
        pasteboardTimer?.invalidate()
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollPasteboard()
            }
        }
    }

    private func stopPasteboardPolling() {
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
    }

    private func pollPasteboard() {
        let pasteboard = NSPasteboard.general
        let next = pasteboard.changeCount
        guard next != pasteboardChangeCount else { return }
        pasteboardChangeCount = next

        if pasteboard.availableType(from: supportedHostPasteboardTypes) == nil {
            if pasteboard.pasteboardItems?.isEmpty == true {
                NotificationCenter.default.post(name: Notification.Name("CSPasteboardRemovedNotification"), object: self)
            }
            return
        }

        NotificationCenter.default.post(
            name: Notification.Name("CSPasteboardChangedNotification"),
            object: self
        )
    }

    private func didReceiveInput(_ input: CSInput) {
        self.input = input
        input.releaseKeys()
        pressedKeys.removeAll()
        pressedButtons = []
        let relative = externalInputCaptureEnabled
        input.requestMouseMode(relative)
        selectQemuMouse(relative: relative)
        status = dynamicResolutionSupported ? "Input ready" : "Input ready; waiting for SPICE agent"
    }

    private func didLoseInput(_ input: CSInput) {
        if self.input === input {
            setExternalInputCapture(false)
            releaseAllInput()
            self.input = nil
        }
        status = "Input closed"
    }

    private func didReceiveError(code: CSConnectionError, message: String?) {
        connecting = false
        dynamicResolutionSupported = false
        updateDisplayHealth()
        status = "SPICE error \(code.rawValue): \(message ?? "unknown")"
        if shouldConnect {
            startConnectLoop()
        }
    }

    private func didCreateDisplay(_ display: CSDisplay) {
        if display.isPrimaryDisplay || self.display == nil {
            displayReconnectAttempts = 0
            displayWatchdogTask?.cancel()
            displayWatchdogTask = nil
            bind(display: display)
        }
    }

    private func didUpdateDisplay(_ display: CSDisplay) {
        if self.display === display {
            displayPixelSize = display.displaySize
            updateDisplayHealth()
            status = "Display \(Int(display.displaySize.width))x\(Int(display.displaySize.height))"
            metalView?.needsLayout = true
            requestMetalDraw()
            if desiredDisplayPixelSize.width > 0,
               abs(display.displaySize.width - desiredDisplayPixelSize.width) > 1 ||
               abs(display.displaySize.height - desiredDisplayPixelSize.height) > 1 {
                requestCurrentRenderSize(force: true)
            }
        }
    }

    private func didDestroyDisplay(_ display: CSDisplay) {
        if self.display === display {
            if let renderer {
                display.removeRenderer(renderer)
            }
            self.display = nil
            displayPixelSize = CGSize(width: 1280, height: 800)
            updateDisplayHealth()
            scheduleDisplayWatchdogIfNeeded()
        }
        status = "Display closed"
    }

    private func requestMetalDraw() {
        guard let metalView else { return }
        metalView.needsDisplay = true
        metalView.draw()
    }

    private func scheduleDisplayWatchdogIfNeeded() {
        displayWatchdogTask?.cancel()
        guard connected, display == nil else { return }
        status = "Waiting for SPICE display"
        displayWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self,
                  !Task.isCancelled,
                  self.connected,
                  self.display == nil else { return }
            guard self.displayReconnectAttempts < 5 else {
                self.status = "SPICE display not ready; reload may be needed"
                return
            }
            self.displayReconnectAttempts += 1
            self.reconnectAfterDisconnect()
        }
    }

    private func didConnectAgent(features: CSConnectionAgentFeature) {
        dynamicResolutionSupported = (features.rawValue & 1) != 0
        updateDisplayHealth()
        status = dynamicResolutionSupported ? "SPICE agent connected" : "SPICE agent connected; dynamic resolution unavailable"
        requestCurrentRenderSize(force: true)
    }

    private func didDisconnectAgent() {
        dynamicResolutionSupported = false
        updateDisplayHealth()
        status = "SPICE agent disconnected"
    }

    nonisolated func spiceConnected(_ connection: CSConnection) {
        Task { @MainActor [weak self] in self?.didConnect() }
    }

    nonisolated func spiceDisconnected(_ connection: CSConnection) {
        Task { @MainActor [weak self] in self?.didDisconnect() }
    }

    nonisolated func spiceInputAvailable(_ connection: CSConnection, input: CSInput) {
        Task { @MainActor [weak self] in self?.didReceiveInput(input) }
    }

    nonisolated func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) {
        Task { @MainActor [weak self] in self?.didLoseInput(input) }
    }

    nonisolated func spiceError(_ connection: CSConnection, code: CSConnectionError, message: String?) {
        Task { @MainActor [weak self] in self?.didReceiveError(code: code, message: message) }
    }

    nonisolated func spiceDisplayCreated(_ connection: CSConnection, display: CSDisplay) {
        Task { @MainActor [weak self] in self?.didCreateDisplay(display) }
    }

    nonisolated func spiceDisplayUpdated(_ connection: CSConnection, display: CSDisplay) {
        Task { @MainActor [weak self] in self?.didUpdateDisplay(display) }
    }

    nonisolated func spiceDisplayDestroyed(_ connection: CSConnection, display: CSDisplay) {
        Task { @MainActor [weak self] in self?.didDestroyDisplay(display) }
    }

    nonisolated func spiceAgentConnected(_ connection: CSConnection, supportingFeatures features: CSConnectionAgentFeature) {
        Task { @MainActor [weak self] in self?.didConnectAgent(features: features) }
    }

    nonisolated func spiceAgentDisconnected(_ connection: CSConnection) {
        Task { @MainActor [weak self] in self?.didDisconnectAgent() }
    }

    nonisolated func spiceForwardedPortOpened(_ connection: CSConnection, port: CSPort) {}
    nonisolated func spiceForwardedPortClosed(_ connection: CSConnection, port: CSPort) {}

    nonisolated func canReadItem(for type: CSPasteboardType) -> Bool {
        mainSync {
            guard let pasteboardType = hostPasteboardType(for: type) else { return false }
            return NSPasteboard.general.availableType(from: [pasteboardType]) != nil
        }
    }

    nonisolated func data(for type: CSPasteboardType) -> Data? {
        mainSync {
            guard let pasteboardType = hostPasteboardType(for: type) else { return nil }
            if pasteboardType == .string {
                return NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
            }
            return NSPasteboard.general.data(forType: pasteboardType)
        }
    }

    nonisolated func setData(_ data: Data, for type: CSPasteboardType) {
        mainSync {
            guard let pasteboardType = hostPasteboardType(for: type) else { return }
            NSPasteboard.general.clearContents()
            if pasteboardType == .string, let value = String(data: data, encoding: .utf8) {
                NSPasteboard.general.setString(value, forType: .string)
            } else {
                NSPasteboard.general.setData(data, forType: pasteboardType)
            }
        }
        markPasteboardChangeHandled()
    }

    nonisolated func string() -> String? {
        mainSync {
            NSPasteboard.general.string(forType: .string)
        }
    }

    nonisolated func setString(_ string: String) {
        mainSync {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }
        markPasteboardChangeHandled()
    }

    nonisolated func clearContents() {
        // A guest clipboard release must not erase host contents or cause a
        // text-only echo that steals Linux file-manager clipboard formats.
        markPasteboardChangeHandled()
    }

    private nonisolated func markPasteboardChangeHandled() {
        Task { @MainActor [weak self] in
            self?.pasteboardChangeCount = NSPasteboard.general.changeCount
        }
    }

    private nonisolated func mainSync<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }
}

@MainActor
private final class SpiceConnectionDrain: NSObject, CSConnectionDelegate {
    static let shared = SpiceConnectionDrain()

    private final class Entry {
        let connection: CSConnection

        init(_ connection: CSConnection) {
            self.connection = connection
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func drain(_ connection: CSConnection) {
        let id = ObjectIdentifier(connection)
        entries[id] = Entry(connection)
        connection.delegate = self
        connection.disconnect()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            self?.entries[id] = nil
        }
    }

    private func finish(_ connection: CSConnection) {
        let id = ObjectIdentifier(connection)
        connection.delegate = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.entries[id] = nil
        }
    }

    nonisolated func spiceConnected(_ connection: CSConnection) {}

    nonisolated func spiceDisconnected(_ connection: CSConnection) {
        Task { @MainActor [weak self] in
            self?.finish(connection)
        }
    }

    nonisolated func spiceError(_ connection: CSConnection, code: CSConnectionError, message: String?) {
        Task { @MainActor [weak self] in
            self?.finish(connection)
        }
    }

    nonisolated func spiceInputAvailable(_ connection: CSConnection, input: CSInput) {}
    nonisolated func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) {}
    nonisolated func spiceDisplayCreated(_ connection: CSConnection, display: CSDisplay) {}
    nonisolated func spiceDisplayUpdated(_ connection: CSConnection, display: CSDisplay) {}
    nonisolated func spiceDisplayDestroyed(_ connection: CSConnection, display: CSDisplay) {}
    nonisolated func spiceAgentConnected(_ connection: CSConnection, supportingFeatures features: CSConnectionAgentFeature) {}
    nonisolated func spiceAgentDisconnected(_ connection: CSConnection) {}
    nonisolated func spiceForwardedPortOpened(_ connection: CSConnection, port: CSPort) {}
    nonisolated func spiceForwardedPortClosed(_ connection: CSConnection, port: CSPort) {}
}
