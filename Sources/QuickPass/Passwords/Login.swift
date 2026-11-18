import Foundation

/// One saved login, as listed in Apple Passwords. Holds no secrets.
struct Login: Codable, Hashable {
    let title: String
    let username: String
    /// Row position in Passwords' "All" list when it was read. A lookup hint, not part of identity.
    var index: Int
    var hasCode: Bool
    /// Passwords can hold several logins with the same title and username. They sit together in
    /// the list, and this counts which one it is from the top of that run, 0 for the first.
    var copy = 0

    /// Identity is title, username and copy, so a reload that moves the list keeps the same logins equal.
    static func == (a: Login, b: Login) -> Bool { a.title == b.title && a.username == b.username && a.copy == b.copy }
    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(username)
        hasher.combine(copy)
    }

    func sameName(as other: Login) -> Bool { title == other.title && username == other.username }

    /// Stable key for storing per-login data such as usage counts.
    var key: String { copy == 0 ? "\(title)\n\(username)" : "\(title)\n\(username)\n\(copy)" }
}

extension Login {
    /// Lists saved before copies were counted have no "copy".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(title: try c.decode(String.self, forKey: .title), username: try c.decode(String.self, forKey: .username),
                  index: try c.decode(Int.self, forKey: .index), hasCode: try c.decode(Bool.self, forKey: .hasCode),
                  copy: try c.decodeIfPresent(Int.self, forKey: .copy) ?? 0)
    }
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
