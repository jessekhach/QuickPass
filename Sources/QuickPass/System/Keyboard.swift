import Carbon
import CoreGraphics
import Foundation

/// Types into the frontmost app with synthetic key events. Uses the Accessibility permission
/// QuickPass already has.
///
/// Every event comes from a private event source with its modifiers set explicitly. With the
/// shared source, a synthetic ⌘A leaves macOS thinking ⌘ is still held, and the next Tab turns
/// into ⌘Tab and switches apps.
enum Keyboard {
    private static let source = CGEventSource(stateID: .privateState)

    /// One character at a time. Some apps drop the rest when a single event carries several.
    static func type(_ text: String) {
        for character in text {
            var units = Array(String(character).utf16)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                event?.flags = []
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                event?.post(tap: .cghidEventTap)
            }
            usleep(4_000)
        }
    }

    static func pressTab() {
        press(kVK_Tab, flags: [])
    }

    /// ⌘ plus a letter. The key is looked up in the keyboard layout, since the same key types a
    /// different letter in other layouts (on AZERTY, QWERTY's A key is Q, and ⌘Q quits).
    static func pressCommand(_ letter: Character) {
        // The layout can only be read on the main thread. Elsewhere macOS stops the app.
        let code = Thread.isMainThread ? keyCode(for: letter) : DispatchQueue.main.sync { keyCode(for: letter) }
        guard let code else { return }
        press(code, flags: .maskCommand)
    }

    /// Shortcuts use the ASCII-capable layout, the one macOS falls back to under layouts like Russian.
    private static func keyCode(for letter: Character) -> Int? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
              let bytes = CFDataGetBytePtr(unsafeBitCast(data, to: CFData.self)) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            (0..<128).first { code in
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                return length == 1 && UnicodeScalar(chars[0]).map(Character.init) == letter
            }
        }
    }

    private static func press(_ key: Int, flags: CGEventFlags) {
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        usleep(30_000)
    }
}
