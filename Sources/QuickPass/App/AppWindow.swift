import AppKit
import SwiftUI

/// A standard titled window for SwiftUI content, created on first show and reused after that.
final class AppWindow {
    private let title: String
    private let makeContent: () -> AnyView
    private var window: NSWindow?

    init<Content: View>(title: String, content: @escaping () -> Content) {
        self.title = title
        makeContent = { AnyView(content()) }
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: makeContent()))
            window.title = title
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}
