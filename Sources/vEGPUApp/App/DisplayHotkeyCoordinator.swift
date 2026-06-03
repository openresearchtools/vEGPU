import AppKit
import Carbon.HIToolbox

@MainActor
final class DisplayHotkeyCoordinator {
    private weak var model: DisplayControlMenuModel?
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var shortcutObserver: NSObjectProtocol?
    private var lastShortcutDigit: Int?
    private var lastShortcutDate = Date.distantPast

    init(model: DisplayControlMenuModel) {
        self.model = model
    }

    func start() {
        installNotificationObserver()
        installCarbonHotkeys()
    }

    func invalidate() {
        if let shortcutObserver {
            NotificationCenter.default.removeObserver(shortcutObserver)
        }
        shortcutObserver = nil

        for hotKey in hotKeys {
            UnregisterEventHotKey(hotKey)
        }
        hotKeys.removeAll()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
    }

    private func installNotificationObserver() {
        guard shortcutObserver == nil else { return }
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: .vegpuExternalSessionShortcut,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let digit = notification.object as? Int else { return }
            Task { @MainActor in
                self?.handleShortcutDigit(digit)
            }
        }
    }

    private func installCarbonHotkeys() {
        guard eventHandler == nil, hotKeys.isEmpty else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandlerCallback,
            1,
            &eventSpec,
            userData,
            &eventHandler
        )
        guard handlerStatus == noErr else { return }

        for (digit, keyCode) in Self.keyCodesByDigit {
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: UInt32(digit))
            var hotKey: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                UInt32(cmdKey | optionKey),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKey
            )
            if status == noErr, let hotKey {
                hotKeys.append(hotKey)
            }
        }
    }

    private func handleShortcutDigit(_ digit: Int) {
        guard (1...9).contains(digit), !isDuplicateShortcut(digit) else { return }
        model?.handleShortcutDigit(digit)
    }

    private func isDuplicateShortcut(_ digit: Int) -> Bool {
        let now = Date()
        defer {
            lastShortcutDigit = digit
            lastShortcutDate = now
        }
        guard lastShortcutDigit == digit else { return false }
        return now.timeIntervalSince(lastShortcutDate) < 0.25
    }

    private static let eventHandlerCallback: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else { return noErr }

        let coordinator = Unmanaged<DisplayHotkeyCoordinator>.fromOpaque(userData).takeUnretainedValue()
        let digit = Int(hotKeyID.id)
        Task { @MainActor in
            coordinator.handleShortcutDigit(digit)
        }
        return noErr
    }

    private static let signature: OSType = {
        var result: UInt32 = 0
        for byte in "vEGP".utf8 {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }()

    private static let keyCodesByDigit: [(Int, Int)] = [
        (1, kVK_ANSI_1),
        (2, kVK_ANSI_2),
        (3, kVK_ANSI_3),
        (4, kVK_ANSI_4),
        (5, kVK_ANSI_5),
        (6, kVK_ANSI_6),
        (7, kVK_ANSI_7),
        (8, kVK_ANSI_8),
        (9, kVK_ANSI_9)
    ]
}
