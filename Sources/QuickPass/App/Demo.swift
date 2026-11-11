#if DEBUG
import Foundation

/// Made-up logins for the README screenshots and the demo video. Debug builds only, turned on with
/// the -demo launch argument. Demo mode never touches the Passwords app or QuickPass's saved files.
enum Demo {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-demo")
}

/// Stands in for the Passwords app with a fixed set of fake logins.
final class DemoPasswords: PasswordsApp {
    private struct Entry {
        let title: String
        let username: String
        let website: String
        let hasCode: Bool
    }

    private var entries: [Entry] = [
        Entry(title: "GitHub", username: "alex.rivera@example.com", website: "github.com", hasCode: true),
        Entry(title: "Figma", username: "alex@example.com", website: "figma.com", hasCode: true),
        Entry(title: "Netflix", username: "alex.rivera@example.com", website: "netflix.com", hasCode: false),
        Entry(title: "Notion", username: "alex@example.com", website: "notion.so", hasCode: false),
        Entry(title: "Stripe", username: "alex@example.com", website: "dashboard.stripe.com", hasCode: true),
        Entry(title: "Spotify", username: "alexrivera", website: "spotify.com", hasCode: false),
        Entry(title: "Linear", username: "alex@example.com", website: "linear.app", hasCode: true),
        Entry(title: "Airbnb", username: "alex.rivera@example.com", website: "airbnb.com", hasCode: false),
        Entry(title: "YouTube", username: "alex.rivera@example.com", website: "youtube.com", hasCode: false),
        Entry(title: "Slack", username: "alex@example.com", website: "slack.com", hasCode: true),
        Entry(title: "Northwind", username: "alex@example.com", website: "northwind.example", hasCode: true),
        Entry(title: "Discord", username: "alexr", website: "discord.com", hasCode: false),
        Entry(title: "Vercel", username: "alex@example.com", website: "vercel.com", hasCode: true),
        Entry(title: "Amazon", username: "alex.rivera@example.com", website: "amazon.com", hasCode: false),
    ]

    private func entry(_ login: Login) -> Entry? {
        entries.first { $0.title == login.title && $0.username == login.username }
    }

    override func loadLogins(fillBlanks: Bool = true) -> [Login]? {
        entries.enumerated().map { Login(title: $1.title, username: $1.username, index: $0, hasCode: $1.hasCode) }
    }

    override func details(for login: Login) throws -> [Field: String] {
        guard let entry = entry(login) else { throw PasswordsError.notFound }
        var out: [Field: String] = [.website: entry.website]
        if entry.hasCode { out[.code] = code(for: entry.title) }
        return out
    }

    override func websites(of logins: [Login], fillBlanks: Bool, stop: () -> Bool, found: (Login, String) -> Void) throws {
        for login in logins where !stop() {
            if let entry = entry(login) { found(login, entry.website) }
        }
    }

    override func password(for login: Login) throws -> String? {
        let words = ["Cobalt", "Harbor", "Tundra", "Maple", "Quartz", "Ember", "Willow", "Nimbus", "Saffron", "Juniper"]
        let n = seed(login.title)
        return "\(words[n % 10])-\(words[(n / 10) % 10].lowercased())-\(words[(n / 100) % 10].lowercased())-\(n % 90 + 10)"
    }

    override func create(_ login: NewLogin) throws {
        usleep(700_000)
        entries.append(Entry(title: login.title, username: login.username, website: login.website, hasCode: false))
    }

    override func delete(_ login: Login) throws {
        entries.removeAll { $0.title == login.title && $0.username == login.username }
    }

    override func reveal(_ login: Login) throws {}
    override func quitIfIdle(onlyIfLocked: Bool) {}
    override var isLocked: Bool { false }
    override func unlock() -> Bool { true }

    /// A code that changes every 30 seconds, like a real one.
    private func code(for title: String) -> String {
        let window = Int(Date().timeIntervalSince1970 / 30)
        return String(format: "%06d", seed("\(title)\(window)") % 1_000_000)
    }

    private func seed(_ text: String) -> Int {
        text.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7fffffff }
    }
}
#endif
