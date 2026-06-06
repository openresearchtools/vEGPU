import AppKit
import Carbon.HIToolbox

@MainActor
enum SpiceKeyboardMapper {
    static func scanCode(for event: NSEvent) -> Int32? {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let keyCode = convertToCurrentLayout(Int(event.keyCode))
        return scanCode(forVirtualKey: keyCode)
    }

    static func clipboardCommand(for event: NSEvent) -> Selector? {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else {
            return nil
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "x": return #selector(NSText.cut(_:))
        default: return nil
        }
    }

    static func modifierScanCodes(for flags: NSEvent.ModifierFlags) -> Set<Int32> {
        let masked = flags.intersection(.deviceIndependentFlagsMask)
        var scans = Set<Int32>()
        if masked.contains(.shift) {
            let key = flags.contains(.rightShift) ? kVK_RightShift : kVK_Shift
            insertScan(forVirtualKey: key, into: &scans)
        }
        if masked.contains(.control) {
            let key = flags.contains(.rightControl) ? kVK_RightControl : kVK_Control
            insertScan(forVirtualKey: key, into: &scans)
        }
        if masked.contains(.option) {
            let key = flags.contains(.rightOption) ? kVK_RightOption : kVK_Option
            insertScan(forVirtualKey: key, into: &scans)
        }
        if masked.contains(.capsLock) {
            insertScan(forVirtualKey: kVK_CapsLock, into: &scans)
        }
        return scans
    }

    static func isModifierScan(_ scan: Int32) -> Bool {
        switch scan {
        case 0x2a, 0x36, 0x1d, 0x11d, 0x38, 0x138, 0x3a:
            return true
        default:
            return false
        }
    }

    private static func insertScan(forVirtualKey key: Int, into scans: inout Set<Int32>) {
        if let scan = scanCode(forVirtualKey: key) {
            scans.insert(scan)
        }
    }

    private static func scanCode(forVirtualKey key: Int) -> Int32? {
        guard let rawCode = KeyCodeMap.keyCodeToScanCodes[key]?.down, rawCode != 0 else { return nil }
        let raw = Int(rawCode)
        if (raw & 0xff00) == 0xe000 {
            return Int32(0x100 | (raw & 0xff))
        }
        if raw >= 0x100 {
            return nil
        }
        return Int32(raw)
    }

    private static func convertToCurrentLayout(_ keyCode: Int) -> Int {
        guard KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO else {
            return keyCode
        }
        switch keyCode {
        case kVK_ISO_Section:
            return kVK_ANSI_Grave
        case kVK_ANSI_Grave:
            return kVK_ISO_Section
        default:
            return keyCode
        }
    }
}

private extension NSEvent.ModifierFlags {
    static var rightControl: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: 0x2000)
    }

    static var rightOption: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: 0x40)
    }

    static var rightShift: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: 0x4)
    }
}
