import AppKit
import SwiftUI

/// The floating window behind the search bar. Borderless and transparent; the SwiftUI view
/// draws the visible card.
final class SearchPanel: NSPanel {
    /// The card's distance from the window's top and side edges. The window clips the card's
    /// shadow, so this leaves room for the shadow to fade out.
    static let cardTop: CGFloat = 40
    static let cardSide: CGFloat = 56
    /// Tall enough for the longest details view and its shadow.
    static let size = NSSize(width: 640 + 2 * cardSide, height: 680)

    init<Content: View>(rootView: Content) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: rootView.frame(width: Self.size.width, height: Self.size.height, alignment: .top))
    }

    override var canBecomeKey: Bool { true }

    /// AppKit beeps when a key reaches the end of the responder chain unhandled. Every key the
    /// panel cares about is handled before that, so stay quiet.
    override func noResponder(for eventSelector: Selector) {}

    /// Esc in a panel defaults to closing it, which beeps on a borderless window. QuickPass handles
    /// Esc itself.
    override func cancelOperation(_ sender: Any?) {}
}
