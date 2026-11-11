import Foundation
import ServiceManagement

/// When QuickPass quits the Passwords app after using it, which takes it out of the Dock.
enum QuitPasswords: Int {
    case rightAway, onceLocked, never
}

extension QuitPasswords {
    /// Waiting for Passwords to lock costs no extra Touch ID, and it still leaves the Dock a
    /// minute or two later.
    static let standard = QuitPasswords.onceLocked
}

/// User settings, saved in UserDefaults.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var openShortcut: Shortcut { didSet { save(openShortcut, as: Key.openShortcut) } }
    @Published var copyUsernameShortcut: Shortcut { didSet { save(copyUsernameShortcut, as: Key.copyUsername) } }
    @Published var copyPasswordShortcut: Shortcut { didSet { save(copyPasswordShortcut, as: Key.copyPassword) } }
    @Published var copyCodeShortcut: Shortcut { didSet { save(copyCodeShortcut, as: Key.copyCode) } }
    @Published var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) } }
    @Published var suggestFromBrowser: Bool { didSet { defaults.set(suggestFromBrowser, forKey: Key.suggestFromBrowser) } }
    /// Ask for Touch ID as the panel opens when Passwords is locked, instead of mid-copy.
    @Published var unlockOnOpen: Bool { didSet { defaults.set(unlockOnOpen, forKey: Key.unlockOnOpen) } }
    /// Show each site's own icon in place of the letter, fetched from the site.
    @Published var showSiteIcons: Bool { didSet { defaults.set(showSiteIcons, forKey: Key.showSiteIcons) } }
    @Published var quitPasswords: QuitPasswords { didSet { defaults.set(quitPasswords.rawValue, forKey: Key.quitPasswords) } }
    @Published var passwordRecipe: PasswordRecipe { didSet { saveRecipe() } }
    /// Seconds before a copied password or code is cleared from the clipboard. 0 means never.
    @Published var clearClipboardAfter: Int { didSet { defaults.set(clearClipboardAfter, forKey: Key.clearClipboardAfter) } }
    /// Seconds the last search survives after the panel closes. 0 means it always starts fresh.
    @Published var rememberSearchFor: Int { didSet { defaults.set(rememberSearchFor, forKey: Key.rememberSearchFor) } }

    /// True while a shortcut field in Settings is listening, so the open shortcut doesn't fire.
    @Published var isRecordingShortcut = false
    /// Set when another app already owns the open shortcut.
    @Published var openShortcutTaken = false

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            objectWillChange.send()
        }
    }

    /// Turns on launch at login the first time QuickPass runs, and never again after that,
    /// so turning it off in Settings sticks.
    func enableLaunchAtLoginOnFirstRun() {
        guard !defaults.bool(forKey: Key.didFirstRun) else { return }
        defaults.set(true, forKey: Key.didFirstRun)
        launchAtLogin = true
    }

    /// Whether the welcome window has been finished once.
    var didOnboard: Bool {
        get { defaults.bool(forKey: Key.didOnboard) }
        set { defaults.set(newValue, forKey: Key.didOnboard) }
    }

    func generatePassword() -> String {
        PasswordGenerator.make(passwordRecipe)
    }

    private func saveRecipe() {
        defaults.set(try? JSONEncoder().encode(passwordRecipe), forKey: Key.passwordRecipe)
    }

    func shortcut(for field: Field) -> Shortcut? {
        switch field {
        case .username: copyUsernameShortcut
        case .password: copyPasswordShortcut
        case .code: copyCodeShortcut
        case .website: nil
        }
    }

    private let defaults = UserDefaults.standard

    private enum Key {
        static let openShortcut = "openShortcut"
        static let copyUsername = "copyUsernameShortcut"
        static let copyPassword = "copyPasswordShortcut"
        static let copyCode = "copyCodeShortcut"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let suggestFromBrowser = "suggestFromBrowser"
        static let unlockOnOpen = "unlockOnOpen"
        static let showSiteIcons = "showSiteIcons"
        static let quitPasswords = "quitPasswords"
        static let passwordRecipe = "passwordRecipe"
        static let clearClipboardAfter = "clearClipboardAfter"
        static let rememberSearchFor = "rememberSearchFor"
        static let didFirstRun = "didFirstRun"
        static let didOnboard = "didOnboard"
    }

    private init() {
        let defaults = UserDefaults.standard
        func shortcut(_ key: String) -> Shortcut? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
        }
        openShortcut = shortcut(Key.openShortcut) ?? .open
        copyUsernameShortcut = shortcut(Key.copyUsername) ?? .copyUsername
        copyPasswordShortcut = shortcut(Key.copyPassword) ?? .copyPassword
        copyCodeShortcut = shortcut(Key.copyCode) ?? .copyCode
        showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        suggestFromBrowser = defaults.object(forKey: Key.suggestFromBrowser) as? Bool ?? true
        unlockOnOpen = defaults.object(forKey: Key.unlockOnOpen) as? Bool ?? true
        showSiteIcons = defaults.object(forKey: Key.showSiteIcons) as? Bool ?? true
        quitPasswords = (defaults.object(forKey: Key.quitPasswords) as? Int).flatMap(QuitPasswords.init) ?? .standard
        passwordRecipe = defaults.data(forKey: Key.passwordRecipe)
            .flatMap { try? JSONDecoder().decode(PasswordRecipe.self, from: $0) } ?? PasswordRecipe()
        clearClipboardAfter = defaults.object(forKey: Key.clearClipboardAfter) as? Int ?? 60
        rememberSearchFor = defaults.object(forKey: Key.rememberSearchFor) as? Int ?? 120
    }

    private func save(_ shortcut: Shortcut, as key: String) {
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: key)
    }
}
