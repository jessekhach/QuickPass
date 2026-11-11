import Foundation

/// One saved login, as listed in Apple Passwords. Holds no secrets.
struct Login: Codable, Hashable {
    let title: String
    let username: String
    /// Row position in Passwords' "All" list when it was read. A lookup hint, not part of identity.
    var index: Int
    var hasCode: Bool

    /// Identity is title plus username, so a reload that reorders the list keeps the same logins equal.
    static func == (a: Login, b: Login) -> Bool { a.title == b.title && a.username == b.username }
    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(username)
    }

    /// Stable key for storing per-login data such as usage counts.
    var key: String { "\(title)\n\(username)" }
}

/// The parts of a login QuickPass can show or copy.
///
/// Raw values are the AXMenuItemCmdModifiers of the matching Copy command in Passwords' Edit menu
/// (⇧⌘C, ⌥⌘C, ⌃⌘C, ⇧⌥⌘C), which is how the bridge finds those commands in any language.
enum Field: Int, CaseIterable {
    case username = 1
    case password = 2
    case code = 4
    case website = 3
}

/// A row in the detail view: a field to copy, or an action to run.
enum DetailItem: Hashable {
    case field(Field)
    case fill
    case fillCode
    case openInPasswords
    case delete
}

/// What the new-login form holds.
struct NewLogin {
    /// The name Passwords lists it under. Passwords falls back to the website when it's empty.
    var title: String
    var website: String
    var username = ""
    var password: String
}
