import AppKit

/// Reads the address of the browser tab QuickPass was opened over, so the matching login can
/// be suggested. macOS asks once per browser before allowing this.
enum BrowserTab {
    /// AppleScript property holding the current tab's URL, per browser. Firefox has no equivalent.
    private static let urlProperty: [String: String] = [
        "com.apple.Safari": "URL of current tab of front window",
        "com.google.Chrome": "URL of active tab of front window",
        "com.brave.Browser": "URL of active tab of front window",
        "com.microsoft.edgemac": "URL of active tab of front window",
        "company.thebrowser.Browser": "URL of active tab of front window",
        "com.vivaldi.Vivaldi": "URL of active tab of front window",
        "org.chromium.Chromium": "URL of active tab of front window",
    ]

    /// The current tab's host without "www.", such as "accounts.github.com". nil when the app isn't
    /// a supported browser or has no window open.
    static func host(in app: NSRunningApplication?) -> String? {
        guard let id = app?.bundleIdentifier, let property = urlProperty[id] else { return nil }
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application id \"\(id)\" to get \(property)")
        guard let address = script?.executeAndReturnError(&error).stringValue,
              let host = URL(string: address)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The label just left of the domain suffix, so subdomains and "co.uk" style suffixes drop off.
    static func siteName(fromHost host: String) -> String? {
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        let secondLevel: Set = ["co", "com", "org", "net", "gov", "ac", "edu"]
        let index = parts.count >= 3 && secondLevel.contains(parts[parts.count - 2]) ? parts.count - 3 : parts.count - 2
        return parts[index]
    }
}
