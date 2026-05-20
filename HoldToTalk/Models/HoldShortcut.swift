import AppKit
import Foundation

struct HoldShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt16?
    var modifierFlagsRawValue: UInt

    static let defaultShortcut = HoldShortcut(keyCode: nil, modifierFlags: [.function])

    init(keyCode: UInt16?, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlagsRawValue = Self.normalized(modifierFlags).rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    }

    var isValidGlobalShortcut: Bool {
        if keyCode == nil {
            return !modifierFlags.isEmpty
        }

        if !modifierFlags.isEmpty {
            return true
        }

        return Self.isFunctionKey(keyCode)
    }

    var displayName: String {
        let modifierText = Self.displayText(for: modifierFlags)
        guard let keyCode else {
            return modifierText.isEmpty ? "Fn" : modifierText
        }

        let keyText = Self.keyName(for: keyCode)
        return modifierText.isEmpty ? keyText : "\(modifierText)+\(keyText)"
    }

    func matchesModifierState(_ flags: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == nil else { return false }

        let normalizedFlags = Self.normalized(flags)
        return !modifierFlags.isEmpty && normalizedFlags.intersection(modifierFlags) == modifierFlags
    }

    func matchesKeyEvent(_ event: NSEvent) -> Bool {
        guard let keyCode, event.keyCode == keyCode else { return false }
        return Self.normalized(event.modifierFlags) == modifierFlags
    }

    static func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .option, .control, .shift, .function])
    }

    private static func displayText(for flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append(L10n.tr("Control")) }
        if flags.contains(.option) { parts.append(L10n.tr("Option")) }
        if flags.contains(.shift) { parts.append(L10n.tr("Shift")) }
        if flags.contains(.command) { parts.append(L10n.tr("Command")) }
        if flags.contains(.function) { parts.append("Fn") }
        return parts.joined(separator: "+")
    }

    private static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 49: return L10n.tr("Space")
        case 50: return "`"
        case 51: return L10n.tr("Delete")
        case 53: return L10n.tr("Escape")
        case 76: return L10n.tr("Enter")
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 106: return "F16"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 115: return L10n.tr("Home")
        case 116: return L10n.tr("Page Up")
        case 117: return L10n.tr("Forward Delete")
        case 118: return "F4"
        case 119: return L10n.tr("End")
        case 120: return "F2"
        case 121: return L10n.tr("Page Down")
        case 122: return "F1"
        case 123: return L10n.tr("Left")
        case 124: return L10n.tr("Right")
        case 125: return L10n.tr("Down")
        case 126: return L10n.tr("Up")
        default: return L10n.tr("Key %d", Int(keyCode))
        }
    }

    private static func isFunctionKey(_ keyCode: UInt16?) -> Bool {
        guard let keyCode else { return false }
        switch keyCode {
        case 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 118, 120, 122:
            return true
        default:
            return false
        }
    }
}
