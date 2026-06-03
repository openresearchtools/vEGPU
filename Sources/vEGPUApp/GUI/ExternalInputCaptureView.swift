import AppKit
import ApplicationServices
import SwiftUI

struct ExternalInputCaptureView: NSViewRepresentable {
    @ObservedObject var session: SpiceSessionController

    func makeNSView(context: Context) -> ExternalInputCaptureNSView {
        let view = ExternalInputCaptureNSView(frame: .zero)
        view.session = session
        view.captureEnabled = session.externalInputCaptureEnabled
        return view
    }

    func updateNSView(_ nsView: ExternalInputCaptureNSView, context: Context) {
        nsView.session = session
        nsView.captureEnabled = session.externalInputCaptureEnabled
    }

    static func dismantleNSView(_ nsView: ExternalInputCaptureNSView, coordinator: ()) {
        nsView.captureEnabled = false
    }
}

final class ExternalInputCaptureNSView: NSView {
    weak var session: SpiceSessionController?

    var captureEnabled = false {
        didSet {
            guard oldValue != captureEnabled else { return }
            captureEnabled ? enableCapture() : disableCapture()
        }
    }

    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var cursorHidden = false
    private var previousWindowTitle: String?
    private static var requestedInputCapturePermission = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowTitle()
    }

    private func enableCapture() {
        updateWindowTitle()
        if installEventTap() {
            centerHostCursor()
            CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
            if !cursorHidden {
                NSCursor.hide()
                cursorHidden = true
            }
        } else if window?.isVisible == true {
            installLocalMonitor()
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
        restoreWindowTitle()
    }

    private func updateWindowTitle() {
        guard captureEnabled, let window else { return }
        if previousWindowTitle == nil {
            previousWindowTitle = window.title
        }
        window.title = "vEGPU - External Mouse Captured - Option-Cmd-1 Releases"
    }

    private func restoreWindowTitle() {
        guard let window else {
            previousWindowTitle = nil
            return
        }
        if let previousWindowTitle {
            window.title = previousWindowTitle
        }
        previousWindowTitle = nil
    }

    private func installLocalMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.eventMask) { [weak self] event in
            guard let self, self.captureEnabled else { return event }
            self.session?.handleExternalCaptureEvent(event)
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
        guard Self.ensureInputCapturePermissionPrompted() else { return false }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.cgEventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let view = Unmanaged<ExternalInputCaptureNSView>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let eventTap = view.eventTap {
                        CGEvent.tapEnable(tap: eventTap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard view.captureEnabled, let nsEvent = NSEvent(cgEvent: event) else {
                    return Unmanaged.passUnretained(event)
                }
                DispatchQueue.main.async { [weak view] in
                    guard let view, view.captureEnabled else { return }
                    view.session?.handleExternalCaptureEvent(nsEvent)
                }
                return nil
            },
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

    private static func ensureInputCapturePermissionPrompted() -> Bool {
        let listenGranted = CGPreflightListenEventAccess()
        let accessibilityGranted = AXIsProcessTrusted()
        if listenGranted && accessibilityGranted {
            return true
        }

        guard !requestedInputCapturePermission else {
            return CGPreflightListenEventAccess() && AXIsProcessTrusted()
        }
        requestedInputCapturePermission = true

        if !listenGranted {
            _ = CGRequestListenEventAccess()
        }
        if !accessibilityGranted {
            let options = [
                "AXTrustedCheckOptionPrompt": true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        return CGPreflightListenEventAccess() && AXIsProcessTrusted()
    }

    private func removeEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        eventTap = nil
        eventTapSource = nil
    }

    private func centerHostCursor() {
        let screen = window?.screen ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        CGWarpMouseCursorPosition(center)
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
