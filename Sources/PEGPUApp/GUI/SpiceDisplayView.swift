import AppKit
import CocoaSpiceRenderer
import MetalKit
import SwiftUI

struct SpiceDisplayView: NSViewRepresentable {
    @ObservedObject var session: SpiceSessionController
    let retina: Bool

    func makeNSView(context: Context) -> SpiceDisplayContainerView {
        SpiceDisplayContainerView(session: session, retina: retina)
    }

    func updateNSView(_ nsView: SpiceDisplayContainerView, context: Context) {
        nsView.session = session
        nsView.retina = retina
        nsView.needsLayout = true
    }
}

final class SpiceDisplayContainerView: NSView {
    var session: SpiceSessionController {
        didSet {
            session.attach(metalView: metalView, renderer: renderer)
            needsLayout = true
        }
    }
    var retina: Bool {
        didSet {
            session.setRetina(retina)
            needsLayout = true
        }
    }
    private let metalView: SpiceMetalInputView
    private let renderer: CSMetalRenderer
    private var geometry = DisplayRenderGeometry(
        displayRect: .zero,
        viewportOrigin: .zero,
        viewportScaleX: 1,
        viewportScaleY: 1,
        backingScale: 1
    )

    init(session: SpiceSessionController, retina: Bool) {
        self.session = session
        self.retina = retina
        let view = SpiceMetalInputView(frame: .zero)
        view.device = MTLCreateSystemDefaultDevice()
        view.clearColor = MTLClearColor(red: 0.01, green: 0.01, blue: 0.012, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
        let renderer = CSMetalRenderer(metalKitView: view)
        self.metalView = view
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        metalView.inputDelegate = self
        metalView.delegate = renderer
        addSubview(metalView)
        session.attach(metalView: view, renderer: renderer)
        session.setRetina(retina)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(metalView)
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let displaySize = session.displaySize()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let localBounds = CGRect(origin: .zero, size: bounds.size)
        geometry = DisplayGeometryMapper.renderGeometry(displaySize: displaySize, in: localBounds, backingScale: scale)
        metalView.frame = bounds
        let drawableSize = CGSize(
            width: max(1, localBounds.width * scale),
            height: max(1, localBounds.height * scale)
        )
        if metalView.drawableSize != drawableSize {
            metalView.drawableSize = drawableSize
        }
        renderer.mtkView(metalView, drawableSizeWillChange: drawableSize)
        renderer.viewportOrigin = geometry.viewportOrigin
        renderer.viewportScaleSize = CGSize(width: geometry.viewportScaleX, height: geometry.viewportScaleY)
        session.updateRenderSize(localBounds.size, backingScale: scale, retina: retina)
    }
}

extension SpiceDisplayContainerView: SpiceMetalInputViewDelegate {
    func spiceMetalInputView(_ view: SpiceMetalInputView, handle event: NSEvent) {
        session.handleSpiceDisplayEvent(event, geometry: geometry, in: view)
    }

    func spiceMetalInputViewDidGainFocus(_ view: SpiceMetalInputView) {
        session.releaseAllInput()
    }

    func spiceMetalInputViewDidLoseFocus(_ view: SpiceMetalInputView) {
        session.releaseAllInput()
    }

    func spiceMetalInputViewShouldHideHostCursor(_ view: SpiceMetalInputView) -> Bool {
        session.spiceCursorIsVisible()
    }
}

@MainActor
protocol SpiceMetalInputViewDelegate: AnyObject {
    func spiceMetalInputView(_ view: SpiceMetalInputView, handle event: NSEvent)
    func spiceMetalInputViewDidGainFocus(_ view: SpiceMetalInputView)
    func spiceMetalInputViewDidLoseFocus(_ view: SpiceMetalInputView)
    func spiceMetalInputViewShouldHideHostCursor(_ view: SpiceMetalInputView) -> Bool
}

final class SpiceMetalInputView: MTKView {
    weak var inputDelegate: SpiceMetalInputViewDelegate?
    private var tracking: NSTrackingArea?
    private var hostCursorHidden = false
    private weak var cursorObservedWindow: NSWindow?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        installCursorRestoreObservers()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            inputDelegate?.spiceMetalInputViewDidGainFocus(self)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        inputDelegate?.spiceMetalInputViewDidLoseFocus(self)
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            showHostCursorIfNeeded()
            removeCursorRestoreObservers()
            inputDelegate?.spiceMetalInputViewDidLoseFocus(self)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        self.tracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        inputDelegate?.spiceMetalInputView(self, handle: event)
        updateHostCursorVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        showHostCursorIfNeeded()
        inputDelegate?.spiceMetalInputView(self, handle: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        inputDelegate?.spiceMetalInputView(self, handle: event)
        updateHostCursorVisibility()
    }

    override func mouseUp(with event: NSEvent) {
        inputDelegate?.spiceMetalInputView(self, handle: event)
        updateHostCursorVisibility()
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        inputDelegate?.spiceMetalInputView(self, handle: event)
        updateHostCursorVisibility()
    }

    override func rightMouseUp(with event: NSEvent) {
        inputDelegate?.spiceMetalInputView(self, handle: event)
        updateHostCursorVisibility()
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        inputDelegate?.spiceMetalInputView(self, handle: event)
        updateHostCursorVisibility()
    }

    override func otherMouseUp(with event: NSEvent) {
        inputDelegate?.spiceMetalInputView(self, handle: event)
        updateHostCursorVisibility()
    }

    override func mouseMoved(with event: NSEvent) {
        inputDelegate?.spiceMetalInputView(self, handle: event)
        updateHostCursorVisibility()
    }

    override func mouseDragged(with event: NSEvent) {
        inputDelegate?.spiceMetalInputView(self, handle: event)
        updateHostCursorVisibility()
    }

    override func rightMouseDragged(with event: NSEvent) {
        inputDelegate?.spiceMetalInputView(self, handle: event)
        updateHostCursorVisibility()
    }

    override func otherMouseDragged(with event: NSEvent) {
        inputDelegate?.spiceMetalInputView(self, handle: event)
        updateHostCursorVisibility()
    }

    override func scrollWheel(with event: NSEvent) {
        inputDelegate?.spiceMetalInputView(self, handle: event)
        updateHostCursorVisibility()
    }

    override func keyDown(with event: NSEvent) {
        inputDelegate?.spiceMetalInputView(self, handle: event)
    }

    override func keyUp(with event: NSEvent) {
        inputDelegate?.spiceMetalInputView(self, handle: event)
    }

    override func flagsChanged(with event: NSEvent) {
        inputDelegate?.spiceMetalInputView(self, handle: event)
    }

    private func updateHostCursorVisibility() {
        if inputDelegate?.spiceMetalInputViewShouldHideHostCursor(self) == true {
            hideHostCursorIfNeeded()
        } else {
            showHostCursorIfNeeded()
        }
    }

    private func hideHostCursorIfNeeded() {
        guard !hostCursorHidden else { return }
        NSCursor.hide()
        hostCursorHidden = true
    }

    private func showHostCursorIfNeeded() {
        guard hostCursorHidden else { return }
        NSCursor.unhide()
        hostCursorHidden = false
    }

    private func installCursorRestoreObservers() {
        removeCursorRestoreObservers()
        let center = NotificationCenter.default
        if let window {
            cursorObservedWindow = window
            center.addObserver(self, selector: #selector(restoreHostCursorFromNotification), name: NSWindow.willCloseNotification, object: window)
            center.addObserver(self, selector: #selector(restoreHostCursorFromNotification), name: NSWindow.didResignKeyNotification, object: window)
            center.addObserver(self, selector: #selector(restoreHostCursorFromNotification), name: NSWindow.didMiniaturizeNotification, object: window)
        }
        center.addObserver(self, selector: #selector(restoreHostCursorFromNotification), name: NSApplication.didResignActiveNotification, object: nil)
    }

    private func removeCursorRestoreObservers() {
        let center = NotificationCenter.default
        if let cursorObservedWindow {
            center.removeObserver(self, name: NSWindow.willCloseNotification, object: cursorObservedWindow)
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: cursorObservedWindow)
            center.removeObserver(self, name: NSWindow.didMiniaturizeNotification, object: cursorObservedWindow)
        }
        center.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        cursorObservedWindow = nil
    }

    @objc private func restoreHostCursorFromNotification(_ notification: Notification) {
        showHostCursorIfNeeded()
    }
}
