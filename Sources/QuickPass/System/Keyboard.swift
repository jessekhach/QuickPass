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

    private static func press(_ key: Int, flags: CGEventFlags) {
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        usleep(30_000)
    }
}
