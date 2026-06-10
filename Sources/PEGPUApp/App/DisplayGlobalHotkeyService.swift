import AppKit
import Carbon.HIToolbox

@MainActor
final class DisplayGlobalHotkeyService {
    private let displayControl: DisplayControlMenuModel
    private var handlerRef: EventHandlerRef?
    private var shortcutObserver: NSObjectProtocol?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var shortcutEventTap: CFMachPort?
    private var shortcutEventTapSource: CFRunLoopSource?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var lastShortcutDigit: Int?
    private var lastShortcutTime: TimeInterval = 0
    private let signature: OSType = 0x56454750
    private let duplicateShortcutWindow: TimeInterval = 0.25

    init(displayControl: DisplayControlMenuModel) {
        self.displayControl = displayControl
    }

    func start() {
        installShortcutObserver()
        installNSEventMonitors()
        installShortcutEventTap()
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let target = GetApplicationEventTarget()
        let status = InstallEventHandler(
            target,
            displayGlobalHotkeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else {
            NSLog("PEGPU display hotkeys could not install event handler: \(status)")
            handlerRef = nil
            return
        }

        registerDigits(target: target)
    }

    func invalidate() {
        removeNSEventMonitors()
        removeShortcutEventTap()

        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()

        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        handlerRef = nil

        if let shortcutObserver {
            NotificationCenter.default.removeObserver(shortcutObserver)
        }
        shortcutObserver = nil
    }

    func restart() {
        invalidate()
        start()
    }

    private func installShortcutEventTap() {
        guard shortcutEventTap == nil else { return }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: displayShortcutEventTapHandler,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("PEGPU display hotkey event tap could not install; relying on registered hotkeys")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        shortcutEventTap = tap
        shortcutEventTapSource = source
    }

    private func removeShortcutEventTap() {
        if let shortcutEventTap {
            CGEvent.tapEnable(tap: shortcutEventTap, enable: false)
            CFMachPortInvalidate(shortcutEventTap)
        }
        if let shortcutEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), shortcutEventTapSource, .commonModes)
        }
        shortcutEventTap = nil
        shortcutEventTapSource = nil
    }

    fileprivate func reenableShortcutEventTap() {
        if let shortcutEventTap {
            CGEvent.tapEnable(tap: shortcutEventTap, enable: true)
        } else {
            installShortcutEventTap()
        }
    }

    private func installShortcutObserver() {
        guard shortcutObserver == nil else { return }
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: .pegpuExternalSessionShortcut,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let digit = notification.object as? Int else { return }
            Task { @MainActor [weak self] in
                self?.handleShortcut(digit: digit)
            }
        }
    }

    private func installNSEventMonitors() {
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if let digit = displayShortcutDigit(for: event) {
                    Task { @MainActor [weak self] in
                        self?.handleShortcut(digit: digit)
                    }
                }
                return event
            }
        }
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let digit = displayShortcutDigit(for: event) else { return }
                Task { @MainActor [weak self] in
                    self?.handleShortcut(digit: digit)
                }
            }
        }
    }

    private func removeNSEventMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
    }

    private func registerDigits(target: EventTargetRef?) {
        let keyCodes: [Int: Int] = [
            1: kVK_ANSI_1,
            2: kVK_ANSI_2,
            3: kVK_ANSI_3,
            4: kVK_ANSI_4,
            5: kVK_ANSI_5,
            6: kVK_ANSI_6,
            7: kVK_ANSI_7,
            8: kVK_ANSI_8,
            9: kVK_ANSI_9
        ]

        for digit in 1...9 {
            guard let keyCode = keyCodes[digit] else { continue }

            var hotKeyID = EventHotKeyID()
            hotKeyID.signature = signature
            hotKeyID.id = UInt32(digit)

            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                UInt32(cmdKey | optionKey),
                hotKeyID,
                target,
                0,
                &hotKeyRef
            )
            if status == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
            } else {
                NSLog("PEGPU display hotkey Cmd+Option+\(digit) could not register: \(status)")
            }
        }
    }

    fileprivate func handleHotkey(signature: OSType, id: UInt32) {
        guard signature == self.signature else { return }
        let digit = Int(id)
        guard (1...9).contains(digit) else { return }
        handleShortcut(digit: digit)
    }

    fileprivate func handleShortcut(digit: Int) {
        guard (1...9).contains(digit) else { return }
        guard shouldHandleShortcut(digit) else { return }
        if digit == 1 {
            NotificationCenter.default.post(name: .pegpuReleaseExternalInputCapture, object: nil)
        }
        displayControl.handleExternalSessionShortcut(digit: digit)
    }

    private func shouldHandleShortcut(_ digit: Int) -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        defer {
            lastShortcutDigit = digit
            lastShortcutTime = now
        }
        guard lastShortcutDigit == digit else { return true }
        return now - lastShortcutTime > duplicateShortcutWindow
    }
}

private let displayGlobalHotkeyHandler: EventHandlerUPP = { _, eventRef, userData in
    guard let eventRef, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else {
        return status
    }

    let signature = hotKeyID.signature
    let id = hotKeyID.id
    let service = Unmanaged<DisplayGlobalHotkeyService>
        .fromOpaque(userData)
        .takeUnretainedValue()
    Task { @MainActor in
        service.handleHotkey(signature: signature, id: id)
    }
    return noErr
}

private let displayShortcutEventTapHandler: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let service = Unmanaged<DisplayGlobalHotkeyService>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in
            service.reenableShortcutEventTap()
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown,
          let digit = displayShortcutDigit(for: event) else {
        return Unmanaged.passUnretained(event)
    }
    Task { @MainActor in
        service.handleShortcut(digit: digit)
    }
    return Unmanaged.passUnretained(event)
}

private func displayShortcutDigit(for event: CGEvent) -> Int? {
    let flags = event.flags
    guard flags.contains(.maskCommand),
          flags.contains(.maskAlternate),
          !flags.contains(.maskControl),
          !flags.contains(.maskShift) else {
        return nil
    }

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    switch keyCode {
    case kVK_ANSI_1: return 1
    case kVK_ANSI_2: return 2
    case kVK_ANSI_3: return 3
    case kVK_ANSI_4: return 4
    case kVK_ANSI_5: return 5
    case kVK_ANSI_6: return 6
    case kVK_ANSI_7: return 7
    case kVK_ANSI_8: return 8
    case kVK_ANSI_9: return 9
    default: return nil
    }
}

private func displayShortcutDigit(for event: NSEvent) -> Int? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command),
          flags.contains(.option),
          !flags.contains(.control),
          !flags.contains(.shift) else {
        return nil
    }

    switch Int(event.keyCode) {
    case kVK_ANSI_1: return 1
    case kVK_ANSI_2: return 2
    case kVK_ANSI_3: return 3
    case kVK_ANSI_4: return 4
    case kVK_ANSI_5: return 5
    case kVK_ANSI_6: return 6
    case kVK_ANSI_7: return 7
    case kVK_ANSI_8: return 8
    case kVK_ANSI_9: return 9
    default: return nil
    }
}
