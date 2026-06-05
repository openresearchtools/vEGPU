import AppKit
import Carbon.HIToolbox

@MainActor
final class DisplayGlobalHotkeyService {
    private weak var displayControl: DisplayControlMenuModel?
    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private let signature: OSType = 0x56454750

    init(displayControl: DisplayControlMenuModel) {
        self.displayControl = displayControl
    }

    func start() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            displayGlobalHotkeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else {
            NSLog("vEGPU display hotkeys could not install event handler: \(status)")
            handlerRef = nil
            return
        }

        registerDigits()
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

    private func registerDigits() {
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
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            if status == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
            } else {
                NSLog("vEGPU display hotkey Cmd+Option+\(digit) could not register: \(status)")
            }
        }
    }

    fileprivate func handleHotkey(signature: OSType, id: UInt32) {
        guard signature == self.signature else { return }
        let digit = Int(id)
        guard (1...9).contains(digit) else { return }
        if digit == 1 {
            NotificationCenter.default.post(name: .vegpuReleaseExternalInputCapture, object: nil)
        }
        displayControl?.handleExternalSessionShortcut(digit: digit)
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
    MainActor.assumeIsolated {
        service.handleHotkey(signature: signature, id: id)
    }
    return noErr
}
