import AppKit
import Carbon.HIToolbox

@MainActor
final class DisplayHotkeyService {
    private let onHotkey: (Int) -> Void
    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private let signature: OSType = 0x50475055
    private(set) var registrationWarning: String?

    init(onHotkey: @escaping (Int) -> Void) {
        self.onHotkey = onHotkey
    }

    func start() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let target = GetApplicationEventTarget()
        let status = InstallEventHandler(
            target,
            displayHotkeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else {
            registrationWarning = "Display hotkeys unavailable: \(status)"
            NSLog("PEGPU display hotkey handler could not install: \(status)")
            handlerRef = nil
            return
        }

        registerDigits(target: target)
    }

    func invalidate() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()

        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        handlerRef = nil
    }

    fileprivate func handleHotkey(signature: OSType, id: UInt32) {
        guard signature == self.signature else { return }
        let digit = Int(id)
        guard (1...9).contains(digit) else { return }
        onHotkey(digit)
    }

    private func registerDigits(target: EventTargetRef?) {
        registrationWarning = nil
        var failed: [String] = []
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
                failed.append("⌥⌘\(digit)")
                NSLog("PEGPU display hotkey Option-Command-\(digit) could not register: \(status)")
            }
        }

        if !failed.isEmpty {
            registrationWarning = "Display hotkey conflict: \(failed.joined(separator: ", "))"
        }
    }
}

private let displayHotkeyHandler: EventHandlerUPP = { _, eventRef, userData in
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
    let service = Unmanaged<DisplayHotkeyService>
        .fromOpaque(userData)
        .takeUnretainedValue()
    Task { @MainActor in
        service.handleHotkey(signature: signature, id: id)
    }
    return noErr
}
