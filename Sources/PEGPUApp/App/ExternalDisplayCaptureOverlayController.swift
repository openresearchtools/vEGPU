import AppKit

@MainActor
final class ExternalDisplayCaptureOverlayController {
    private var windows: [ExternalDisplayCaptureWindow] = []
    private var eventHandler: ((NSEvent) -> Void)?
    private weak var previousFrontmostApp: NSRunningApplication?
    private var screenObserver: NSObjectProtocol?
    private var cursorHidden = false
    private var cursorDetached = false

    var isVisible: Bool {
        !windows.isEmpty
    }

    func show(eventHandler: @escaping (NSEvent) -> Void) {
        self.eventHandler = eventHandler
        let current = NSRunningApplication.current
        let front = NSWorkspace.shared.frontmostApplication
        let appWasAlreadyFrontmost = front?.processIdentifier == current.processIdentifier
        let shouldActivateApp = appWasAlreadyFrontmost || NSApp.activationPolicy() == .accessory
        if previousFrontmostApp == nil {
            if front?.processIdentifier != current.processIdentifier {
                previousFrontmostApp = front
            }
        }

        installScreenObserver()
        rebuildWindows()
        detachCursor()
        if shouldActivateApp {
            NSApp.activate(ignoringOtherApps: true)
        }
        orderWindowsFront(activateApp: shouldActivateApp)
    }

    func hide(restorePreviousApp: Bool = true) {
        removeScreenObserver()
        eventHandler = nil
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        restoreCursor()

        if restorePreviousApp {
            previousFrontmostApp?.activate(options: [.activateIgnoringOtherApps])
        }
        previousFrontmostApp = nil
    }

    private func installScreenObserver() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.eventHandler != nil else { return }
                self.rebuildWindows()
                self.orderWindowsFront()
            }
        }
    }

    private func removeScreenObserver() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
    }

    private func rebuildWindows() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = NSScreen.screens.map { screen in
            let contentView = ExternalDisplayCaptureView(
                frame: NSRect(origin: .zero, size: screen.frame.size)
            ) { [weak self] event in
                self?.eventHandler?(event)
            }
            let window = ExternalDisplayCaptureWindow(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = false
            window.worksWhenModal = true
            window.contentView = contentView
            return window
        }
    }

    private func orderWindowsFront(activateApp: Bool = false) {
        guard !windows.isEmpty else { return }
        let mouseLocation = NSEvent.mouseLocation
        let keyWindow = windows.first { $0.frame.contains(mouseLocation) } ?? windows.first
        for window in windows {
            if window === keyWindow {
                if activateApp {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    window.orderFrontRegardless()
                    window.makeKey()
                }
            } else {
                window.orderFrontRegardless()
            }
        }
    }

    private func detachCursor() {
        if !cursorDetached {
            _ = CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
            cursorDetached = true
        }
        if !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
    }

    private func restoreCursor() {
        if cursorDetached {
            _ = CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            cursorDetached = false
        }
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }
}

private final class ExternalDisplayCaptureWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ExternalDisplayCaptureView: NSView {
    private let eventHandler: (NSEvent) -> Void

    init(frame frameRect: NSRect, eventHandler: @escaping (NSEvent) -> Void) {
        self.eventHandler = eventHandler
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseMoved(with event: NSEvent) {
        eventHandler(event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        eventHandler(event)
    }

    override func mouseUp(with event: NSEvent) {
        eventHandler(event)
    }

    override func mouseDragged(with event: NSEvent) {
        eventHandler(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        eventHandler(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        eventHandler(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        eventHandler(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        eventHandler(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        eventHandler(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        eventHandler(event)
    }

    override func scrollWheel(with event: NSEvent) {
        eventHandler(event)
    }

    override func keyDown(with event: NSEvent) {
        eventHandler(event)
    }

    override func keyUp(with event: NSEvent) {
        eventHandler(event)
    }

    override func flagsChanged(with event: NSEvent) {
        eventHandler(event)
    }
}
