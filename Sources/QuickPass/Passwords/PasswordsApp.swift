import AppKit
import ApplicationServices
import os

/// Why a step in Passwords failed. Never logs passwords or login details.
/// Watch with: log stream --predicate 'subsystem == "com.jkcreativestudios.quickpass"'
private let log = Logger(subsystem: "com.jkcreativestudios.quickpass", category: "Passwords")

enum PasswordsError: LocalizedError {
    case locked, unlockFailed, notFound, copyFailed, saveFailed, deleteFailed, notSureWhichLogin

    var errorDescription: String? {
        switch self {
        case .locked: "Passwords is locked."
        case .unlockFailed: "Passwords didn't unlock."
        case .notFound: "Couldn't find that login in Passwords. Try again in a moment."
        case .copyFailed: "Passwords didn't copy. Try again."
        case .saveFailed: "Passwords didn't save the login. Try again."
        case .deleteFailed: "Passwords didn't delete the login. Try again."
        case .notSureWhichLogin: "Couldn't confirm which login is selected, so nothing was deleted. Use Open in Passwords instead."
        }
    }
}

/// Reads from Apple's Passwords app through the Accessibility API.
///
/// Apple doesn't let other apps read the Passwords store, so QuickPass drives the Passwords app
/// itself, the way a screen reader would: it reads the visible list and detail pane, and uses
/// Passwords' own Copy commands for the password. Passwords stays hidden except for Touch ID.
///
/// Every call blocks while it waits on Passwords, so use one serial background queue.
class PasswordsApp {
    static let bundleID = "com.apple.Passwords"

    /// Which sidebar tile the list shows, as far as we know. nil when the user may have changed it.
    private var shownTile: String?

    /// Where QuickPass's search bar is on screen, measured from the top-left, while it's open.
    /// Passwords' window is tucked behind it while QuickPass works in Passwords. Called on the main thread.
    var hidingSpot: () -> CGRect? = { nil }

    /// What the list shows in place of a missing username. Accessibility doesn't mark it as a placeholder.
    private static let noUsernameLabel = appleString("no user name (label)", fallback: "no user name")
    private static let revealPasswordLabel = appleString("Reveal Password", fallback: "Reveal Password")

    /// One of Passwords' own strings in the system language, so matching what Passwords shows
    /// works in any language.
    private static func appleString(_ key: String, fallback: String) -> String {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/PasswordManagerUI.framework"),
              let language = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: Locale.preferredLanguages).first,
              let path = bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language),
              let strings = NSDictionary(contentsOfFile: path) as? [String: String] else { return fallback }
        return strings[key] ?? fallback
    }

    private var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
    }

    // MARK: - Reading

    /// Every login in the "All" list, marked with whether it has a 2FA code. nil while locked.
    /// Filling blank rows brings Passwords forward for a moment, so without fillBlanks a list with
    /// blank rows comes back nil.
    func loadLogins(fillBlanks: Bool = true) -> [Login]? {
        prepare()
        guard list() != nil else { return nil }
        clearSearch()
        shownTile = nil
        show("AllTile")
        var logins = rows().enumerated().map { login(of: $1, at: $0) }
        // An empty read means the list hadn't drawn yet. Saving it would wipe the cache.
        guard !logins.isEmpty else { return nil }
        if logins.contains(where: { $0.title.isEmpty }) {
            guard fillBlanks else { return nil }
            fillBlankRows()
            logins = rows().enumerated().map { login(of: $1, at: $0) }
        }
        guard !logins.isEmpty, let withCodes = loginsWithCodes() else { return nil }
        for i in logins.indices where withCodes.contains(logins[i]) { logins[i].hasCode = true }
        return logins
    }

    /// Up to `max` rows of the All list from row `start`, and how many rows the list has. Reading
    /// the whole list takes seconds, so background reloads read it in pieces and other work runs
    /// in between. nil while locked, or when a row is blank and `fillBlanks` is off.
    func logins(from start: Int, max: Int, fillBlanks: Bool) -> (logins: [Login], total: Int)? {
        prepare()
        guard list() != nil else { return nil }
        clearSearch()
        if start == 0 { shownTile = nil }
        show("AllTile")
        var rows = rows()
        func piece() -> [Login] { rows.indices.dropFirst(start).prefix(max).map { login(of: rows[$0], at: $0) } }
        var logins = piece()
        // An empty read means the list hadn't drawn yet.
        guard !rows.isEmpty else { return nil }
        if logins.contains(where: { $0.title.isEmpty }) {
            guard fillBlanks else { return nil }
            fillBlankRows()
            rows = self.rows()
            logins = piece()
        }
        return (logins, rows.count)
    }

    /// The logins listed under Codes. nil if Passwords locked while reading, since the reads
    /// then come back empty.
    func loginsWithCodes() -> Set<Login>? {
        show("CodesTile")
        let withCodes = Set(rows().compactMap(codeEntry).map { Login(title: $0.title, username: $0.username, index: 0, hasCode: true) })
        show("AllTile")
        return list() != nil ? withCodes : nil
    }

    /// Website, current 2FA code and the password if Passwords reveals it, all read in one visit to
    /// the login's detail pane while Passwords stays hidden. Each visit waits about half a second
    /// for the pane. `copyPassword` falls back to Copy Password, which brings Passwords forward and
    /// takes a few seconds, so it's only for an actual password copy.
    func details(for login: Login, copyPassword: Bool) throws -> [Field: String] {
        let window = try select(login)
        var out: [Field: String] = [:]
        if let site = field("WebsiteField", in: window), !site.isEmpty { out[.website] = site }
        let code = login.hasCode ? field("VerificationCodeField", in: window)?.filter(\.isNumber) ?? "" : ""
        if !code.isEmpty { out[.code] = code }
        // Revealing clears the selection afterwards, so it comes after the pane's other fields.
        out[.password] = try copyPassword ? password(in: window, for: login, website: out[.website]) : revealPassword(in: window)
        // Switching to the Codes list moves away from the login, so it comes last.
        if login.hasCode, code.isEmpty { out[.code] = try codeFromList(for: login) }
        return out
    }

    /// Reads the website of each of `logins`, for the website icons backfill, passing each to
    /// `found` as it's read. Goes to each login's row by its saved position, so logins already
    /// done cost nothing. Checks `stop` before every login.
    func websites(of logins: [Login], fillBlanks: Bool, stop: () -> Bool, found: (Login, String) -> Void) throws {
        prepare()
        guard list() != nil else { throw PasswordsError.locked }
        clearSearch()
        show("AllTile")
        // Rows that loaded while Passwords was hidden can be blank. Filling them brings Passwords
        // forward for a moment, so the caller asks for it once per scan.
        if fillBlanks { fillBlankRows() }
        // A login usually sits at its saved row. When rows have moved, read the whole list once
        // for the batch instead of once per login.
        var rowsByLogin: [Login: AXUIElement]?
        func row(for login: Login) -> AXUIElement? {
            let rows = rows()
            if rows.indices.contains(login.index), self.login(of: rows[login.index], at: login.index) == login {
                return rows[login.index]
            }
            if rowsByLogin == nil {
                rowsByLogin = Dictionary(rows.enumerated().map { (self.login(of: $1, at: $0), $1) }, uniquingKeysWith: { first, _ in first })
            }
            return rowsByLogin?[login]
        }
        for login in logins where !stop() {
            guard let list = list() else { throw PasswordsError.locked }
            guard let row = row(for: login) else { continue }
            AXUIElementSetAttributeValue(list, kAXSelectedRowsAttribute as CFString, [row] as CFArray)
            // Same short wait as select(), so the previous login's pane isn't read for this one.
            usleep(80_000)
            for _ in 0..<30 {
                if let window = windows().first(where: { field("TitleField", in: $0) == login.title }) {
                    found(login, field("WebsiteField", in: window) ?? "")
                    break
                }
                usleep(20_000)
            }
        }
    }

    /// Read with Passwords' own Reveal Password, which works while Passwords stays hidden and keeps
    /// the password off the clipboard. A Passwords without it falls back to Copy Password, which
    /// puts the password on the clipboard and only works while Passwords is the active app.
    private func password(in window: AXUIElement, for login: Login, website: String?) throws -> String? {
        if let password = revealPassword(in: window) { return password }
        let saved = snapshotPasteboard()
        defer { restorePasteboard(saved) }
        let password = try whileActive { try copy(.password) }
        // Copy Password is found by its shortcut. If a Passwords version assigns the shortcuts
        // differently, this stops the username or website from going out as the password.
        if let password, !password.isEmpty, [login.username, website].contains(password) { throw PasswordsError.copyFailed }
        return password
    }

    /// Shows the password in the detail pane and reads it. It stays shown until the selection
    /// changes, and running Reveal again doesn't hide it, so the selection is cleared afterwards.
    private func revealPassword(in window: AXUIElement) -> String? {
        guard let field = formElement("PasswordField", in: window),
              let masked = value(field, kAXValueAttribute) as? String,
              let reveal = actionNames(field).first(where: { $0.hasPrefix("Name:\(Self.revealPasswordLabel)") }) else { return nil }
        AXUIElementPerformAction(field, reveal as CFString)
        defer { if let list = list() { AXUIElementSetAttributeValue(list, kAXSelectedRowsAttribute as CFString, [] as CFArray) } }
        for _ in 0..<40 {
            if let shown = formElement("PasswordField", in: window).flatMap({ value($0, kAXValueAttribute) as? String }),
               shown != masked { return shown }
            usleep(25_000)
        }
        return nil
    }

    /// Saves a new login through Passwords' own New Password form, out of sight like a password copy.
    ///
    /// The fields are typed into, moving between them with Tab the way a person would. Two things
    /// that look simpler don't work: setting a field's value through Accessibility shows the text
    /// but doesn't reach the form's data, and focusing a field through Accessibility doesn't move
    /// the keyboard to it. Everything is read back before Save, and the form is cancelled on any
    /// mismatch, so Passwords never keeps a half-filled login.
    func create(_ login: NewLogin) throws {
        prepare()
        guard list() != nil else { throw PasswordsError.locked }
        guard let app else { throw PasswordsError.saveFailed }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let parked = activateParked(app) { self.value(root, kAXFrontmostAttribute) as? Bool == true }
        defer { restore(app, parked) }

        log.notice("create: Passwords frontmost \(self.value(root, kAXFrontmostAttribute) as? Bool == true, privacy: .public)")
        pressMenuItem(char: "N", modifiers: 0) // File > New Password… (⌘N)
        func formField(_ identifier: String) -> AXUIElement? {
            windows().lazy.compactMap { self.formElement(identifier, in: $0) }.first
        }
        for _ in 0..<40 where formField("SaveButton") == nil { usleep(50_000) }
        guard let save = formField("SaveButton") else {
            log.error("create: the New Password form didn't open")
            throw PasswordsError.saveFailed
        }
        var saved = false
        defer {
            if !saved, let cancel = formField("CancelButton") { AXUIElementPerformAction(cancel, kAXPressAction as CFString) }
        }

        let website = login.website.trimmingCharacters(in: .whitespaces)
        usleep(300_000) // the form opens with the cursor in Title
        // Tab until the cursor is in the wanted field. Passwords puts buttons between some fields,
        // so the number of Tabs isn't fixed.
        func moveCursor(to identifier: String) throws {
            for _ in 0..<10 {
                if focusedIdentifier(in: root) == identifier { return }
                Keyboard.pressTab()
                usleep(60_000)
            }
            guard focusedIdentifier(in: root) == identifier else {
                log.error("create: Tab never reached \(identifier, privacy: .public), focus is on \(self.focusedIdentifier(in: root) ?? "nothing", privacy: .public)")
                throw PasswordsError.saveFailed
            }
        }
        func text(_ identifier: String) -> String { formField(identifier).flatMap { value($0, kAXValueAttribute) as? String } ?? "" }
        let title = login.title.trimmingCharacters(in: .whitespaces)
        try moveCursor(to: "TitleField")
        Keyboard.type(title)
        try moveCursor(to: "UserNameTextField")
        Keyboard.type(login.username)
        try moveCursor(to: "WebsiteTextField")
        Keyboard.type(website)
        usleep(200_000)
        // The password goes in last: editing the website makes Passwords put a fresh suggestion of
        // its own in the password field.
        try moveCursor(to: "PasswordTextField")
        try pastePassword(login.password, into: { text("PasswordTextField") })

        // The password field shows one dot per character, so its length is all that can be compared.
        guard text("TitleField") == title, text("WebsiteTextField") == website, text("UserNameTextField") == login.username,
              text("PasswordTextField").count == login.password.count else {
            log.error("create: read back didn't match. title \(text("TitleField") == title, privacy: .public), website \(text("WebsiteTextField") == website, privacy: .public), username \(text("UserNameTextField") == login.username, privacy: .public), password length \(text("PasswordTextField").count == login.password.count, privacy: .public)")
            throw PasswordsError.saveFailed
        }

        AXUIElementPerformAction(save, kAXPressAction as CFString)
        for _ in 0..<40 {
            if formField("SaveButton") == nil { saved = true; return }
            usleep(50_000)
        }
        log.error("create: the form was still open 2 s after Save")
        throw PasswordsError.saveFailed
    }

    /// The password goes in by pasting, Select All then ⌘V. Paste is pressed as a keystroke because
    /// Passwords on macOS 27 reports its Paste menu item as disabled to Accessibility, so pressing
    /// the menu item does nothing. A one-character paste comes first, so the length check afterwards
    /// can't pass by coincidence with Passwords' own suggestion still in the field.
    private func pastePassword(_ password: String, into field: () -> String) throws {
        let saved = snapshotPasteboard()
        defer { restorePasteboard(saved) }
        func paste(_ text: String) {
            pressMenuItem(char: "A", modifiers: 0) // Edit > Select All
            usleep(80_000)
            // Kept off Universal Clipboard, like every password QuickPass copies.
            _ = NSPasteboard.general.prepareForNewContents(with: .currentHostOnly)
            NSPasteboard.general.setString(text, forType: .string)
            // Asks clipboard managers not to record it.
            NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            Keyboard.pressCommand("v")
            usleep(200_000)
        }
        paste("x")
        let first = field().count
        guard first == 1 else {
            log.error("create: test paste left \(first, privacy: .public) characters in the password field, not 1")
            throw PasswordsError.saveFailed
        }
        paste(password)
        let pasted = field().count
        guard pasted == password.count else {
            log.error("create: password field has \(pasted, privacy: .public) characters after paste, expected \(password.count, privacy: .public)")
            throw PasswordsError.saveFailed
        }
    }

    /// The identifier of the element that has the keyboard in Passwords, such as "WebsiteTextField".
    private func focusedIdentifier(in root: AXUIElement) -> String? {
        guard let focused = value(root, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return value(focused as! AXUIElement, kAXIdentifierAttribute) as? String
    }

    /// An element by identifier, such as a New Password form field. Skips the list, which holds thousands of rows.
    private func formElement(_ identifier: String, in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 12 else { return nil }
        for child in children(element) where role(child) != kAXOutlineRole {
            if value(child, kAXIdentifierAttribute) as? String == identifier { return child }
            if let found = formElement(identifier, in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Deletes a login with Passwords' own Delete command and confirms Passwords' prompt.
    /// Stricter than other actions: the detail pane has to show this login's username as well as
    /// its title, or nothing happens.
    func delete(_ login: Login) throws {
        log.notice("delete: start")
        let window = try select(login)
        if !login.username.isEmpty, field("UserNameField", in: window) != login.username {
            throw PasswordsError.notSureWhichLogin
        }
        guard let at = find(login)?.index else { throw PasswordsError.notFound }
        let count = rows().count
        try whileActive {
            // Delete only applies to the list's selection, and stays disabled while the search
            // field has focus.
            guard let delete = menuItem(identifier: "delete:"), let list = list() else { throw PasswordsError.deleteFailed }
            AXUIElementSetAttributeValue(list, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            for _ in 0..<20 where value(delete, kAXEnabledAttribute) as? Bool != true { usleep(50_000) }
            AXUIElementPerformAction(delete, kAXPressAction as CFString)
            try confirmDeletePrompt()
        }
        // Gone once the list is a row shorter and the login isn't at its row or the one above,
        // where it would sit if a different row had gone. Looking through every row takes seconds.
        for _ in 0..<40 {
            let rows = rows()
            if rows.count == count - 1,
               ![at - 1, at].contains(where: { rows.indices.contains($0) && self.login(of: rows[$0], at: $0) == login }) {
                log.notice("delete: done, confirmed from the row count")
                return
            }
            usleep(50_000)
        }
        // The count can be off if Passwords added or removed another login meanwhile.
        if find(login) == nil {
            log.notice("delete: done, confirmed by reading the whole list")
            return
        }
        log.error("delete: the login was still listed afterwards")
        throw PasswordsError.deleteFailed
    }

    /// Passwords asks before deleting, in a sheet on its window.
    private func confirmDeletePrompt() throws {
        for _ in 0..<40 {
            for window in windows() {
                for sheet in children(window) where role(sheet) == kAXSheetRole {
                    if let button = element(in: sheet, identifier: "ConfirmationDialogDeleteButton") {
                        AXUIElementPerformAction(button, kAXPressAction as CFString)
                        return
                    }
                }
            }
            usleep(50_000)
        }
        throw PasswordsError.deleteFailed
    }

    /// Selects the login and brings Passwords' window forward, centered, for the user to work in.
    func reveal(_ login: Login) throws {
        let window = try select(login)
        guard let app else { return }
        center(window)
        DispatchQueue.main.sync { _ = app.unhide(); _ = app.activate() }
    }

    /// Quits Passwords if QuickPass left it running in the background: not in front, and hidden or
    /// without a window. Leaves it alone while the user has it open.
    func quitIfIdle(onlyIfLocked: Bool) {
        guard let app, !app.isActive, app.isHidden || windows().isEmpty else { return }
        if onlyIfLocked, list() != nil { return }
        DispatchQueue.main.sync { _ = app.terminate() }
        shownTile = nil
    }

    var isLocked: Bool {
        prepare()
        return list() == nil
    }

    var isRunning: Bool { app != nil }

    /// Passwords shows its Touch ID prompt by itself when its locked window comes forward.
    /// Moving the window or pressing its unlock button while the prompt is up cancels Touch ID,
    /// so center the window once and leave it alone.
    func unlock() -> Bool {
        prepare()
        if list() != nil { return true }
        guard let app else { return false }
        windows().forEach(center)
        // macOS only lets an app come forward when the active app hands over to it.
        DispatchQueue.main.sync { NSApp.yieldActivation(to: app); _ = app.unhide(); _ = app.activate() }
        defer { DispatchQueue.main.sync { _ = app.hide() } }
        // Once Passwords has come forward and then stepped back (a click elsewhere, or Cancel),
        // there is nothing left to wait for. If it never comes forward, its Touch ID prompt can
        // still show on its own, so wait a while for that before giving up.
        var wasActive = false
        var inactiveChecks = 0
        for attempt in 0..<240 {
            if list() != nil {
                waitForListToFill()
                return true
            }
            if app.isActive {
                wasActive = true
                inactiveChecks = 0
            } else {
                inactiveChecks += 1
            }
            if wasActive, inactiveChecks >= 3 { return false }
            if !wasActive, attempt >= 80 { return false }
            usleep(250_000)
        }
        return false
    }

    /// Right after an unlock Passwords fills its list in over a moment. Reading it too early
    /// misses logins, so wait until the row count holds steady.
    private func waitForListToFill() {
        var last = -1
        for _ in 0..<20 {
            let count = rows().count
            if count > 0, count == last { return }
            last = count
            usleep(250_000)
        }
    }

    // MARK: - Passwords app state

    /// Launches Passwords hidden if needed and makes sure it has a window to read.
    private func prepare() {
        if app == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
            for _ in 0..<50 where app == nil { usleep(100_000) }
            usleep(500_000)
            shownTile = nil
        }
        if windows().isEmpty {
            pressMenuItem(char: "N", modifiers: 1) // File > New Window (⇧⌘N)
            for _ in 0..<20 where windows().isEmpty { usleep(100_000) }
            if let app, !app.isActive { DispatchQueue.main.sync { _ = app.hide() } }
            shownTile = nil
        }
    }

    private func windows() -> [AXUIElement] {
        guard let app else { return [] }
        return value(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    /// The lock screen has no outlines. Unlocked, the sidebar comes first and the login list second.
    private func outlines() -> [AXUIElement] {
        for window in windows() {
            var found: [AXUIElement] = []
            findOutlines(in: window, depth: 0, into: &found)
            if found.count >= 2 { return found }
        }
        return []
    }

    private func findOutlines(in element: AXUIElement, depth: Int, into found: inout [AXUIElement]) {
        guard depth < 9 else { return }
        for child in children(element) {
            if role(child) == kAXOutlineRole { found.append(child) } else { findOutlines(in: child, depth: depth + 1, into: &found) }
        }
    }

    private func list() -> AXUIElement? { outlines().last }

    private func rows() -> [AXUIElement] {
        list().flatMap { value($0, kAXRowsAttribute) as? [AXUIElement] } ?? []
    }

    /// Passwords' own search box filters the list QuickPass reads, and setting its text through
    /// Accessibility doesn't refresh the list. A new window starts unfiltered, so open one and close
    /// the filtered ones. Opening first matters: closing the last window locks Passwords.
    private func clearSearch() {
        let filtered = windows().filter { window in
            guard let search = searchField(in: window) else { return false }
            return !(value(search, kAXValueAttribute) as? String ?? "").isEmpty
        }
        guard !filtered.isEmpty else { return }
        let count = windows().count
        pressMenuItem(char: "N", modifiers: 1) // File > New Window (⇧⌘N)
        for _ in 0..<20 where windows().count <= count { usleep(100_000) }
        for window in filtered {
            if let close = value(window, kAXCloseButtonAttribute), CFGetTypeID(close) == AXUIElementGetTypeID() {
                AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
            }
        }
        usleep(300_000)
        shownTile = nil
    }

    private func searchField(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }
        for child in children(element) where role(child) != kAXOutlineRole {
            if value(child, kAXSubroleAttribute) as? String == kAXSearchFieldSubrole { return child }
            if let found = searchField(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Passwords fills in list rows as its window lays out. Rows that load while it's hidden, as
    /// right after an unlock, can stay blank. Bringing it forward off-screen for a moment lets
    /// them fill in.
    /// Blank rows can be anywhere in the list, so this waits on the ones that were blank, not just
    /// the last row.
    private func fillBlankRows() {
        let blank = rows().enumerated().filter { isBlank($1) }.map(\.offset)
        guard let app, !blank.isEmpty else { return }
        let parked = activateParked(app) {
            let rows = self.rows()
            return blank.allSatisfy { rows.indices.contains($0) && !self.isBlank(rows[$0]) }
        }
        restore(app, parked)
    }

    private func isBlank(_ row: AXUIElement) -> Bool {
        texts(in: row, depth: 0).first?.isEmpty ?? true
    }

    /// Switches the list with a sidebar tile ("AllTile", "CodesTile"). Works while hidden.
    private func show(_ tile: String) {
        guard shownTile != tile, let sidebar = outlines().first, let button = element(in: sidebar, identifier: tile) else { return }
        if value(button, kAXSelectedAttribute) as? Bool != true {
            func titles() -> [String] { windows().compactMap { value($0, kAXTitleAttribute) as? String } }
            let before = titles()
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            // The window title names the list and its count ("Codes – 47 Items") and changes along
            // with the rows, about 150 ms after the press.
            for _ in 0..<40 where titles() == before { usleep(10_000) }
        }
        shownTile = tile
    }

    // MARK: - Finding a login

    /// Selects the login in the All list and waits until the detail pane shows it.
    private func select(_ login: Login) throws -> AXUIElement {
        prepare()
        guard list() != nil else { throw PasswordsError.locked }
        clearSearch()
        show("AllTile")
        var row = find(login)?.row
        if row == nil {
            shownTile = nil
            show("AllTile")
            fillBlankRows()
            row = find(login)?.row
        }
        guard let row, let list = list() else { throw PasswordsError.notFound }
        AXUIElementSetAttributeValue(list, kAXSelectedRowsAttribute as CFString, [row] as CFArray)
        // The list can show an account's display name where the detail pane shows the username,
        // so only the title is compared. The short wait keeps a previous login with the same title
        // from passing for this one before the pane updates.
        usleep(150_000)
        for _ in 0..<40 {
            if let window = windows().first(where: { field("TitleField", in: $0) == login.title }) { return window }
            usleep(25_000)
        }
        throw PasswordsError.notFound
    }

    /// The login's row and row number. Adding or removing a login moves the rows below it, usually
    /// by a few, so this reads outward from the saved position. Reading the whole list takes seconds.
    private func find(_ login: Login) -> (row: AXUIElement, index: Int)? {
        let rows = rows()
        let index = rows.indices
            .sorted { abs($0 - login.index) < abs($1 - login.index) }
            .first { self.login(of: rows[$0], at: $0) == login }
        return index.map { (rows[$0], $0) }
    }

    /// Rows in the All list read [title, username].
    private func login(of row: AXUIElement, at index: Int) -> Login {
        let t = texts(in: row, depth: 0)
        return Login(title: t.first ?? "", username: t.count > 1 ? username(t[1]) : "", index: index, hasCode: false)
    }

    /// Rows in the Codes list read [title, code, username].
    private func codeEntry(_ row: AXUIElement) -> (title: String, code: String, username: String)? {
        let t = texts(in: row, depth: 0)
        guard t.count >= 2 else { return nil }
        return (t[0], t[1].filter(\.isNumber), t.count > 2 ? username(t[2]) : "")
    }

    private func username(_ text: String) -> String {
        text == Self.noUsernameLabel ? "" : text
    }

    /// Fallback when the detail pane doesn't show a code: the Codes list does.
    private func codeFromList(for login: Login) throws -> String? {
        show("CodesTile")
        defer { show("AllTile") }
        return rows().lazy.compactMap(codeEntry).first { $0.title == login.title && $0.username == login.username }?.code
    }

    /// A detail-pane value by its identifier. Skips the sidebar and list, which hold thousands of rows.
    private func field(_ identifier: String, in element: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 14 else { return nil }
        for child in children(element) where role(child) != kAXOutlineRole {
            if value(child, kAXIdentifierAttribute) as? String == identifier { return value(child, kAXValueAttribute) as? String }
            if let found = field(identifier, in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    // MARK: - Copying the password

    /// Passwords only enables its Copy commands while it's the active app. Activate it with its
    /// windows parked off-screen, run the copy, then hide it and put the windows back.
    private func whileActive<T>(_ body: () throws -> T) throws -> T {
        guard let app else { throw PasswordsError.copyFailed }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let parked = activateParked(app) { self.value(root, kAXFrontmostAttribute) as? Bool == true && self.copyEnabled() }
        defer { restore(app, parked) }
        return try body()
    }

    private typealias Parked = [(window: AXUIElement, position: CGPoint, size: CGSize)]

    /// Activates Passwords with its windows out of the way. While the search bar is open they shrink
    /// to their smallest size and sit behind it, since the bar floats above every window. Otherwise
    /// they move off-screen, where macOS still keeps a small corner visible.
    private func activateParked(_ app: NSRunningApplication, until ready: () -> Bool) -> Parked {
        let parked = windows().map { (window: $0, position: position(of: $0), size: size(of: $0)) }
        let spot = DispatchQueue.main.sync { hidingSpot() }
        if spot != nil {
            // Passwords won't go below its minimum size, so asking for 1×1 gives the smallest it allows.
            parked.forEach { resize($0.window, to: CGSize(width: 1, height: 1)) }
        }
        DispatchQueue.main.sync { _ = app.unhide() }
        park(parked, behind: spot)
        DispatchQueue.main.sync { _ = app.activate() }
        // Activation can pull windows back into view, so keep placing them until it settles.
        for _ in 0..<100 {
            park(parked, behind: spot)
            if ready() { break }
            usleep(10_000)
        }
        return parked
    }

    private func park(_ parked: Parked, behind spot: CGRect?) {
        for (window, _, _) in parked {
            guard let spot else { move(window, to: CGPoint(x: 30_000, y: 30_000)); continue }
            let width = size(of: window).width
            move(window, to: CGPoint(x: spot.midX - width / 2, y: spot.minY + 8))
        }
    }

    private func restore(_ app: NSRunningApplication, _ parked: Parked) {
        DispatchQueue.main.sync { _ = app.hide() }
        usleep(50_000)
        for (window, position, size) in parked {
            resize(window, to: size)
            move(window, to: position)
        }
    }

    private func copyEnabled() -> Bool {
        [Field.username, .password, .website].contains { field in
            menuItem(char: "C", modifiers: field.rawValue).map { value($0, kAXEnabledAttribute) as? Bool == true } ?? false
        }
    }

    private func copy(_ field: Field) throws -> String? {
        guard let item = menuItem(char: "C", modifiers: field.rawValue) else { throw PasswordsError.copyFailed }
        guard value(item, kAXEnabledAttribute) as? Bool == true else { return nil }
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        for _ in 0..<40 {
            if pasteboard.changeCount != before { return pasteboard.string(forType: .string) }
            usleep(25_000)
        }
        throw PasswordsError.copyFailed
    }

    /// Copying goes through the clipboard, so put back whatever was there.
    private func snapshotPasteboard() -> [NSPasteboardItem] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private func restorePasteboard(_ items: [NSPasteboardItem]) {
        NSPasteboard.general.clearContents()
        if !items.isEmpty { NSPasteboard.general.writeObjects(items) }
    }

    // MARK: - Menu commands

    private func pressMenuItem(char: String, modifiers: Int) {
        if let item = menuItem(char: char, modifiers: modifiers) {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
    }

    /// Edit › Delete has no shortcut to match, but AppKit names it after its action, `delete:`.
    private func menuItem(identifier: String) -> AXUIElement? {
        guard let app,
              let bar = value(AXUIElementCreateApplication(app.processIdentifier), kAXMenuBarAttribute),
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        for top in children(bar as! AXUIElement) {
            for menu in children(top) {
                for item in children(menu) where value(item, kAXIdentifierAttribute) as? String == identifier {
                    return item
                }
            }
        }
        return nil
    }

    /// Matches by keyboard shortcut rather than title so it works in any system language.
    private func menuItem(char: String, modifiers: Int) -> AXUIElement? {
        guard let app,
              let bar = value(AXUIElementCreateApplication(app.processIdentifier), kAXMenuBarAttribute),
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        for top in children(bar as! AXUIElement) {
            for menu in children(top) {
                for item in children(menu)
                where value(item, kAXMenuItemCmdCharAttribute) as? String == char
                    && value(item, kAXMenuItemCmdModifiersAttribute) as? Int == modifiers {
                    return item
                }
            }
        }
        return nil
    }

    // MARK: - Window position

    private func position(of window: AXUIElement) -> CGPoint {
        var point = CGPoint.zero
        if let v = value(window, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &point) }
        return point
    }

    private func size(of window: AXUIElement) -> CGSize {
        var size = CGSize.zero
        if let v = value(window, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
        return size
    }

    private func resize(_ window: AXUIElement, to size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) }
    }

    private func move(_ window: AXUIElement, to point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) }
    }

    /// Accessibility positions are measured from the top-left, AppKit's from the bottom-left.
    private func center(_ window: AXUIElement) {
        var size = CGSize.zero
        if let v = value(window, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
        let (visible, primaryHeight) = DispatchQueue.main.sync {
            (NSScreen.main?.visibleFrame ?? .zero, NSScreen.screens.first?.frame.height ?? 0)
        }
        move(window, to: CGPoint(x: visible.midX - size.width / 2, y: primaryHeight - visible.midY - size.height / 2))
    }

    // MARK: - Accessibility helpers

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success ? v : nil
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func role(_ element: AXUIElement) -> String? {
        value(element, kAXRoleAttribute) as? String
    }

    private func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        return names as? [String] ?? []
    }

    private func element(in root: AXUIElement, identifier: String, depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }
        for child in children(root) {
            if value(child, kAXIdentifierAttribute) as? String == identifier { return child }
            if let found = element(in: child, identifier: identifier, depth: depth + 1) { return found }
        }
        return nil
    }

    private func texts(in element: AXUIElement, depth: Int) -> [String] {
        guard depth < 6 else { return [] }
        return children(element).flatMap { child -> [String] in
            role(child) == kAXStaticTextRole ? [value(child, kAXValueAttribute) as? String ?? ""] : texts(in: child, depth: depth + 1)
        }
    }
}
