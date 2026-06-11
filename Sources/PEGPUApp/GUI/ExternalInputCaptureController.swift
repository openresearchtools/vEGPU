import AppKit

final class ExternalInputCaptureController {
    var captureEnabled = false {
        didSet {
            guard oldValue != captureEnabled else { return }
            captureEnabled ? enableCapture() : disableCapture()
        }
    }

    private let eventHandler: (NSEvent) -> Void
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var cursorHidden = false

    init(eventHandler: @escaping (NSEvent) -> Void) {
        self.eventHandler = eventHandler
    }

    deinit {
        disableCapture()
    }

    private func enableCapture() {
        if !installEventTap() {
            NSLog("PEGPU external input capture could not install global event tap; falling back to app-local monitor")
            installLocalMonitor()
        }
        centerHostCursorOnActiveScreen()
        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
        if !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
    }

    private func disableCapture() {
        removeLocalMonitor()
        removeEventTap()
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

    private func installLocalMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.eventMask) { [weak self] event in
            guard let self, self.captureEnabled else { return event }
            self.eventHandler(event)
            return nil
        }
    }

    private func removeLocalMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
    }

    private func installEventTap() -> Bool {
        guard eventTap == nil else { return true }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.cgEventMask,
            callback: externalInputCaptureEventTapHandler,
            userInfo: userInfo
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        return true
    }

    private func removeEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        eventTap = nil
        eventTapSource = nil
    }

    fileprivate func reenableEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        } else {
            _ = installEventTap()
        }
    }

    fileprivate func handleCapturedEvent(_ event: NSEvent) {
        eventHandler(event)
    }

    private func centerHostCursorOnActiveScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
    }

    private static let eventTypes: [CGEventType] = [
        .leftMouseDown,
        .leftMouseUp,
        .rightMouseDown,
        .rightMouseUp,
        .otherMouseDown,
        .otherMouseUp,
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
        .scrollWheel,
        .keyDown,
        .keyUp,
        .flagsChanged
    ]

    private static let cgEventMask: CGEventMask = eventTypes.reduce(CGEventMask(0)) { partial, event in
        partial | (CGEventMask(1) << CGEventMask(event.rawValue))
    }

    private static let eventMask: NSEvent.EventTypeMask = [
        .leftMouseDown,
        .leftMouseUp,
        .rightMouseDown,
        .rightMouseUp,
        .otherMouseDown,
        .otherMouseUp,
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
        .scrollWheel,
        .keyDown,
        .keyUp,
        .flagsChanged
    ]
}

private let externalInputCaptureEventTapHandler: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let controller = Unmanaged<ExternalInputCaptureController>
        .fromOpaque(userInfo)
        .takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        controller.reenableEventTap()
        return Unmanaged.passUnretained(event)
    }

    guard controller.captureEnabled, let nsEvent = NSEvent(cgEvent: event) else {
        return Unmanaged.passUnretained(event)
    }

    DispatchQueue.main.async { [weak controller] in
        guard let controller, controller.captureEnabled else { return }
        controller.handleCapturedEvent(nsEvent)
    }
    return nil
}
