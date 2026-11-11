import AppKit
import Carbon

/// A key plus modifiers, as recorded in Settings.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifierFlags: UInt
    /// How the key reads on screen, such as "C" or "Space". Saved at record time because the
    /// character a key code produces depends on the keyboard layout.
    var key: String

    static let open = Shortcut(keyCode: kVK_Space, modifiers: [.control, .option], key: "Space")
    static let copyUsername = Shortcut(keyCode: kVK_ANSI_C, modifiers: [.command], key: "C")
    static let copyPassword = Shortcut(keyCode: kVK_ANSI_C, modifiers: [.command, .shift], key: "C")
    static let copyCode = Shortcut(keyCode: kVK_ANSI_C, modifiers: [.command, .option], key: "C")

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = UInt16(keyCode)
        self.modifierFlags = modifiers.intersection(.shortcutKeys).rawValue
        self.key = key
    }

    /// Needs at least one modifier, so a plain letter can't become a shortcut by accident.
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.shortcutKeys)
        guard !modifiers.isEmpty else { return nil }
        self.init(keyCode: Int(event.keyCode), modifiers: modifiers, key: Self.name(for: event))
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && event.modifierFlags.intersection(.shortcutKeys) == modifiers
    }

    /// "⌃⌥Space", in the order macOS menus use.
    var display: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + key
    }

    /// The key as a menu item key equivalent. nil for keys a menu can't show, like Space or arrows.
    var menuKey: String? {
        key.count == 1 && key.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespaces.contains($0) })
            ? key.lowercased() : nil
    }

    /// The same modifiers in the form Carbon's RegisterEventHotKey expects.
    var carbonModifiers: Int {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        return flags
    }

    private static func name(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        default: event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
    }
}

extension NSEvent.ModifierFlags {
    /// The modifiers that count toward a shortcut. Leaves out Caps Lock, Fn and the like.
    static let shortcutKeys: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
}
