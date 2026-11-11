import AppKit

/// The menu bar icon: Apple's "key.viewfinder" symbol, sized to match other menu bar icons.
/// SF Symbols are template images, so macOS tints it for light and dark menu bars.
enum MenuBarIcon {
    static let image: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: "key.viewfinder", accessibilityDescription: "QuickPass")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }()
}
