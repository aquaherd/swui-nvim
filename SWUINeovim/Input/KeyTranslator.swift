// KeyTranslator.swift
// SWUINeovim
//
// Converts platform key events (macOS NSEvent / iPadOS UIKey) into
// Neovim key notation strings like "<C-a>", "<D-s>", "<M-x>",
// "<S-Tab>", "<CR>", "<Esc>", "<BS>", "<Up>", etc.

import Foundation

#if os(macOS)
import AppKit
import Carbon.HIToolbox
#else
import UIKit
#endif

public enum KeyTranslator {

    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: UInt

        public init(rawValue: UInt) {
            self.rawValue = rawValue
        }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let alt = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        public var isEmpty: Bool { rawValue == 0 }
    }

    #if os(macOS)

    public static func translate(event: NSEvent) -> String? {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }

        let modifiers = modifiersFromNSEvent(event)

        if let special = specialKeyName(forKeyCode: Int(event.keyCode)) {
            return formatKey(name: special, modifiers: modifiers)
        }

        guard let baseChars = event.charactersIgnoringModifiers, let char = baseChars.first else {
            return nil
        }

        if let special = specialKeyName(forCharacter: char) {
            return formatKey(name: special, modifiers: modifiers)
        }

        let charString = String(char)

        if modifiers.isEmpty {
            if let chars = event.characters, let resolved = chars.first {
                if resolved == "<" { return "<lt>" }
                if resolved == "\\" { return "<Bslash>" }
                return String(resolved)
            }
            return charString
        }

        let keyName: String
        if modifiers.contains(.control) {
            keyName = charString.lowercased()
        } else {
            keyName = charString
        }

        return formatKey(name: keyName, modifiers: modifiers)
    }

    private static func modifiersFromNSEvent(_ event: NSEvent) -> Modifiers {
        var mods = Modifiers()
        let flags = event.modifierFlags

        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.alt) }
        if flags.contains(.command) { mods.insert(.command) }

        return mods
    }

    private static func specialKeyName(forKeyCode keyCode: Int) -> String? {
        switch keyCode {
        case kVK_Return: return "CR"
        case kVK_Tab: return "Tab"
        case kVK_Space: return "Space"
        case kVK_Delete: return "BS"
        case kVK_ForwardDelete: return "Del"
        case kVK_Escape: return "Esc"

        case kVK_LeftArrow: return "Left"
        case kVK_RightArrow: return "Right"
        case kVK_UpArrow: return "Up"
        case kVK_DownArrow: return "Down"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "PageUp"
        case kVK_PageDown: return "PageDown"

        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"

        default: return nil
        }
    }

    #else

    public static func translate(key: UIKey) -> String? {
        let modifiers = modifiersFromUIKeyFlags(key.modifierFlags)

        if let special = specialKeyName(for: key) {
            return formatKey(name: special, modifiers: modifiers)
        }

        guard let chars = key.charactersIgnoringModifiers, let char = chars.first else {
            return nil
        }

        if modifiers.isEmpty {
            if char == "<" { return "<lt>" }
            if char == "\\" { return "<Bslash>" }
            return String(char)
        }

        let keyName = modifiers.contains(.control) ? String(char).lowercased() : String(char)
        return formatKey(name: keyName, modifiers: modifiers)
    }

    private static func modifiersFromUIKeyFlags(_ flags: UIKeyModifierFlags) -> Modifiers {
        var mods = Modifiers()
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.alternate) { mods.insert(.alt) }
        if flags.contains(.command) { mods.insert(.command) }
        return mods
    }

    private static func specialKeyName(for key: UIKey) -> String? {
        switch key.keyCode {
        case .keyboardReturnOrEnter: return "CR"
        case .keyboardTab: return "Tab"
        case .keyboardSpacebar: return "Space"
        case .keyboardDeleteOrBackspace: return "BS"
        case .keyboardDeleteForward: return "Del"
        case .keyboardEscape: return "Esc"
        case .keyboardLeftArrow: return "Left"
        case .keyboardRightArrow: return "Right"
        case .keyboardUpArrow: return "Up"
        case .keyboardDownArrow: return "Down"
        case .keyboardHome: return "Home"
        case .keyboardEnd: return "End"
        case .keyboardPageUp: return "PageUp"
        case .keyboardPageDown: return "PageDown"
        case .keyboardF1: return "F1"
        case .keyboardF2: return "F2"
        case .keyboardF3: return "F3"
        case .keyboardF4: return "F4"
        case .keyboardF5: return "F5"
        case .keyboardF6: return "F6"
        case .keyboardF7: return "F7"
        case .keyboardF8: return "F8"
        case .keyboardF9: return "F9"
        case .keyboardF10: return "F10"
        case .keyboardF11: return "F11"
        case .keyboardF12: return "F12"
        default: return nil
        }
    }

    #endif

    private static func specialKeyName(forCharacter character: Character) -> String? {
        switch character {
        case "\r", "\n": return "CR"
        case "\t": return "Tab"
        case "\u{08}", "\u{7F}": return "BS"
        case "\u{1B}": return "Esc"
        default: return nil
        }
    }

    public static func formatKey(name: String, modifiers: Modifiers = []) -> String {
        guard !modifiers.isEmpty else {
            return "<\(name)>"
        }

        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("C") }
        if modifiers.contains(.shift) { parts.append("S") }
        if modifiers.contains(.alt) { parts.append("M") }
        if modifiers.contains(.command) { parts.append("D") }
        parts.append(name)
        return "<\(parts.joined(separator: "-"))>"
    }
}
