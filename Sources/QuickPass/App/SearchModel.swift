import AppKit
import os

/// State behind the search panel: the login list, the search, the selection, and values fetched
/// from Passwords. Lives on the main thread; Passwords work happens on a background queue.
final class SearchModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { selection = 0; detail = false } } }
    /// The new-login form, when it's open.
    @Published var newLogin: NewLogin?
    /// The ⌘G generator's password, when it's open.
    @Published var generatedPassword: String?
    @Published var selection = 0 { didSet { if selection != oldValue { detailSelection = 0 } } }
    /// Showing the selected login's details instead of the result list.
    @Published var detail = false { didSet { if detail != oldValue { detailSelection = 0; reveal = false } } }
    @Published var detailSelection = 0 { didSet { confirmingDelete = false } }
    /// Delete asks once more inside the panel before it touches Passwords.
    @Published var confirmingDelete = false
    /// Holding ⌥ in the detail view shows a password that has already been fetched.
    @Published var reveal = false
    @Published private(set) var logins: [Login] = []
    @Published private(set) var copied: [Login: Set<Field>] = [:]
    @Published var status: String?
    @Published private(set) var busy = false
    /// True while an action has Passwords in front on purpose: Touch ID, copying a password,
    /// saving or opening a login. Focus moving around then isn't the user clicking away.
    private(set) var usingPasswords = false
    /// Bumped every time the panel opens, so the view can refocus the search field.
    @Published private(set) var opens = 0

    /// Called just before Passwords comes forward for Touch ID.
    var onUnlock: (() -> Void)?

    /// Values fetched from Passwords, held so one Touch ID covers a whole login.
    private struct Held {
        var values: [Field: String] = [:]
        var fetched: Set<Field> = []
        var codeAt = Date.distantPast
    }

    @Published private var held: [Login: Held] = [:]
    /// Each login's website by Login.key, for icons. Empty for a login without one.
    @Published private(set) var websites: [String: String] = [:]
    /// True while the website backfill runs.
    @Published private(set) var backfillRunning = false
    /// Why the last backfill stopped early.
    @Published private(set) var backfillNote: String?
    /// Read on the Passwords queue before each login, so Stop takes effect right away.
    private let backfillStop = OSAllocatedUnfairLock(initialState: false)
    private var usage: [String: Int]
    private var pending = 0 { didSet { busy = pending > 0 } }
    /// Fields being fetched right now, by login. A repeat press during a fetch is dropped, since
    /// the first one finishes the job and every extra fetch goes back to Passwords.
    private var fetching: [Login: Set<Field>] = [:]
    /// With Unlock on open, the list stays hidden until Passwords has unlocked.
    @Published private(set) var waitingForUnlock = false
    private var lastUsed = Date.distantPast
    /// When the list was last read from Passwords. Touched only on the Passwords queue.
    private var lastLoaded = Date.distantPast
    private var codeTimer: Timer?
    private var lastCodeAttempt = Date.distantPast
    private let passwords: PasswordsApp
    /// False in demo mode, which must never touch the real saved files.
    private let persists: Bool
    let icons = SiteIcons()
    private let queue = DispatchQueue(label: "QuickPass.Passwords")
    private let preferences: Preferences

    /// Titles and usernames only, so search works before Touch ID. Never passwords or codes.
    private static let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QuickPass/logins.json")
    private static let websitesURL = cacheURL.deletingLastPathComponent().appendingPathComponent("websites.json")
    private static let usageKey = "usage"

    /// Where to tuck Passwords' window while QuickPass works in it. See PasswordsApp.hidingSpot.
    var passwordsHidingSpot: () -> CGRect? {
        get { passwords.hidingSpot }
        set { passwords.hidingSpot = newValue }
    }

    init(preferences: Preferences, passwords: PasswordsApp = PasswordsApp(), persists: Bool = true) {
        self.preferences = preferences
        self.passwords = passwords
        self.persists = persists
        usage = persists ? UserDefaults.standard.dictionary(forKey: Self.usageKey) as? [String: Int] ?? [:] : [:]
        guard persists else { return }
        if let data = try? Data(contentsOf: Self.cacheURL), let saved = try? JSONDecoder().decode([Login].self, from: data) {
            logins = saved
        }
        if let data = try? Data(contentsOf: Self.websitesURL), let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            websites = saved
        }
        // Websites read by an earlier scan may not have their icons yet.
        DispatchQueue.main.async { self.logins.forEach(self.fetchIcon) }
    }

    // MARK: - What the panel shows

    /// Title prefix matches first, then title matches, then username matches. Within each group,
    /// the logins used most come first.
    var results: [Login] {
        guard !waitingForUnlock else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let ranked: [(login: Login, rank: Int)] = q.isEmpty ? logins.map { ($0, 0) } : logins.compactMap { login in
            let title = login.title.lowercased()
            if title.hasPrefix(q) { return (login, 0) }
            if title.contains(q) { return (login, 1) }
            if login.username.lowercased().contains(q) { return (login, 2) }
            return nil
        }
        return ranked.enumerated().sorted { a, b in
            if a.element.rank != b.element.rank { return a.element.rank < b.element.rank }
            let useA = usage[a.element.login.key, default: 0]
            let useB = usage[b.element.login.key, default: 0]
            return useA != useB ? useA > useB : a.offset < b.offset
        }
        .map(\.element.login)
    }

    var selectedLogin: Login? {
        let results = self.results
        return results.indices.contains(selection) ? results[selection] : nil
    }

    /// Fields in the detail view. Website shows until a fetch finds there isn't one.
    func fields(for login: Login) -> [Field] {
        var fields: [Field] = []
        if !login.username.isEmpty { fields.append(.username) }
        fields.append(.password)
        if login.hasCode { fields.append(.code) }
        let h = held[login]
        if !(h?.fetched.contains(.website) ?? false) || h?.values[.website] != nil { fields.append(.website) }
        return fields
    }

    func value(_ field: Field, for login: Login) -> String? {
        field == .username ? login.username : held[login]?.values[field]
    }

    /// 2FA codes roll over every 30 seconds, so a fetched code only counts within its own window.
    func codeIsFresh(for login: Login, at date: Date = Date()) -> Bool {
        guard let h = held[login], h.values[.code] != nil else { return false }
        return Self.codeWindow(h.codeAt) == Self.codeWindow(date)
    }

    // MARK: - Panel lifecycle

    /// Starts fresh unless the panel was used recently. A fresh start searches for the browser
    /// tab's site when there's a login for it.
    func willOpen(suggesting site: String?) {
        waitingForUnlock = false
        if Date().timeIntervalSince(lastUsed) > TimeInterval(preferences.rememberSearchFor) {
            forget()
            query = ""
            selection = 0
            detail = false
            newLogin = nil
            generatedPassword = nil
            if let site, logins.contains(where: { $0.title.lowercased().replacingOccurrences(of: " ", with: "").contains(site) }) {
                query = site
            }
        }
        status = nil
        opens += 1
        if detail { startCodeTimer() }
    }

    func didClose() {
        lastUsed = Date()
        codeTimer?.invalidate()
        let rememberFor = TimeInterval(preferences.rememberSearchFor)
        DispatchQueue.main.asyncAfter(deadline: .now() + rememberFor + 1) { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastUsed) > rememberFor else { return }
            self.forget()
        }
        // Picks up logins added or removed in Passwords. Done after closing because a reload takes
        // several seconds, and a copy queued behind it would wait.
        queue.async { if self.passwords.isRunning { self.reloadIfStale(fillBlanks: false) } }
    }

    /// Forgets fetched passwords and codes and the last search, so the next visit starts over.
    func lock() {
        forget()
        lastUsed = .distantPast
    }

    // MARK: - Navigation

    /// The list always ends with a "Create a new login" row, one past the last result.
    func move(_ delta: Int) {
        selection = max(0, min(results.count, selection + delta))
    }

    var isOnCreateRow: Bool { selection == results.count }

    /// Opens the new-login form. A search that looks like an address becomes the website, and any
    /// other search becomes the title. The browser tab QuickPass was opened over fills in whichever
    /// is still missing.
    func startNewLogin(browserHost: String?) {
        let typed = query.trimmingCharacters(in: .whitespaces)
        let isAddress = typed.contains(".") && !typed.contains(" ")
        let website = isAddress ? typed.lowercased() : browserHost ?? ""
        let siteName = BrowserTab.siteName(fromHost: website).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
        let title = isAddress || typed.isEmpty ? siteName : typed
        newLogin = NewLogin(title: title, website: website, password: preferences.generatePassword())
        status = nil
    }

    func moveInDetail(_ delta: Int) {
        guard let login = selectedLogin else { return }
        detailSelection = max(0, min(items(for: login).count - 1, detailSelection + delta))
    }

    /// Website and code come from Passwords' detail pane without bringing it forward. The
    /// password stays as dots until it's copied, since fetching it means activating Passwords.
    /// Calls done when anything it had to fetch has arrived, which may have taken Touch ID.
    func openDetail(done: @escaping () -> Void) {
        guard let login = selectedLogin else { return }
        detail = true
        startCodeTimer()
        let missing = ([Field.website] + (login.hasCode ? [.code] : [])).filter { field in
            field == .code ? !codeIsFresh(for: login) : !(held[login]?.fetched.contains(field) ?? false)
        }
        if missing.isEmpty { done(); return }
        load(missing, for: login, allowUnlock: true) { _ in done() }
    }

    // MARK: - Actions

    /// Puts a field of the selected login on the clipboard. Calls done(true) once it's there.
    func copy(_ field: Field, done: @escaping (Bool) -> Void) {
        guard let login = selectedLogin else { return }
        if field == .code, !login.hasCode { NSSound.beep(); return }
        if let value = freshValue(field, for: login) {
            finishCopy(value, field, login)
            done(true)
            return
        }
        if field == .username || (field != .code && held[login]?.fetched.contains(field) == true) {
            fail("Nothing saved for that in this login.")
            done(false)
            return
        }
        load([field], for: login, allowUnlock: true) { ok in
            guard ok else { done(false); return }
            if let value = self.freshValue(field, for: login) {
                self.finishCopy(value, field, login)
                done(true)
            } else {
                self.fail(field == .code ? "Passwords didn't return a code. Try again." : "Nothing saved for that in this login.")
                done(false)
            }
        }
    }

    /// Rows in the detail view: the fields, then the actions.
    func items(for login: Login) -> [DetailItem] {
        fields(for: login).map(DetailItem.field) + [.fill] + (login.hasCode ? [.fillCode] : []) + [.openInPasswords, .delete]
    }

    /// The highlighted row in the detail view.
    var selectedItem: DetailItem? {
        guard let login = selectedLogin else { return nil }
        let items = items(for: login)
        return items.indices.contains(detailSelection) ? items[detailSelection] : nil
    }

    /// The selected login's website, fetching it from Passwords if needed.
    func website(completion: @escaping (URL?) -> Void) {
        guard let login = selectedLogin else { return }
        let deliver = {
            guard let site = self.held[login]?.values[.website],
                  let url = URL(string: site.contains("://") ? site : "https://\(site)") else {
                self.fail("No website saved for this login.")
                completion(nil)
                return
            }
            self.recordUse(of: login)
            completion(url)
        }
        if held[login]?.fetched.contains(.website) == true { deliver(); return }
        load([.website], for: login, allowUnlock: true) { ok in ok ? deliver() : completion(nil) }
    }

    /// Saves the new-login form into Passwords, then copies the password for the sign-up form.
    func saveNewLogin(done: @escaping (Bool) -> Void) {
        guard let draft = newLogin else { return }
        guard !draft.website.trimmingCharacters(in: .whitespaces).isEmpty else { fail("Add a website first."); return }
        guard !draft.password.isEmpty else { fail("Add a password first."); return }
        pending += 1
        usingPasswords = true
        status = nil
        queue.async {
            var result = Result { try self.passwords.create(draft) }
            if case .failure(let error) = result, error as? PasswordsError == .locked {
                DispatchQueue.main.sync { self.onUnlock?() }
                result = self.passwords.unlock() ? Result { try self.passwords.create(draft) } : .failure(PasswordsError.unlockFailed)
            }
            DispatchQueue.main.async {
                self.pending -= 1
                self.usingPasswords = false
                switch result {
                case .success:
                    self.putOnClipboard(draft.password, secret: true)
                    self.newLogin = nil
                    done(true)
                case .failure(let error):
                    self.fail(error.localizedDescription)
                    done(false)
                }
            }
            // Pick up the new login so it's searchable right away.
            if case .success = result {
                self.lastLoaded = .distantPast
                self.reloadIfStale(fillBlanks: true)
            }
        }
    }

    /// Deletes the selected login in Passwords, which keeps it in its Deleted section for 30 days.
    func delete(done: @escaping (Bool) -> Void) {
        guard let login = selectedLogin else { return }
        confirmingDelete = false
        pending += 1
        usingPasswords = true
        status = nil
        queue.async {
            var result = Result { try self.passwords.delete(login) }
            if case .failure(let error) = result, error as? PasswordsError == .locked {
                DispatchQueue.main.sync { self.onUnlock?() }
                result = self.passwords.unlock() ? Result { try self.passwords.delete(login) } : .failure(PasswordsError.unlockFailed)
            }
            DispatchQueue.main.async {
                self.pending -= 1
                self.usingPasswords = false
                switch result {
                case .success:
                    self.detail = false
                    self.held[login] = nil
                    self.update(self.logins.filter { $0 != login })
                    self.status = "Deleted \(login.title). Passwords keeps it in Deleted for 30 days."
                    done(true)
                case .failure(let error):
                    self.fail(error.localizedDescription)
                    done(false)
                }
            }
        }
    }

    /// Shows the selected login in the Passwords app. Calls done(true) once Passwords is in front.
    func openInPasswords(done: @escaping (Bool) -> Void) {
        guard let login = selectedLogin else { return }
        pending += 1
        usingPasswords = true
        status = nil
        queue.async {
            var result = Result { try self.passwords.reveal(login) }
            if case .failure(let error) = result, error as? PasswordsError == .locked {
                DispatchQueue.main.sync { self.onUnlock?() }
                result = self.passwords.unlock() ? Result { try self.passwords.reveal(login) } : .failure(PasswordsError.unlockFailed)
            }
            DispatchQueue.main.async {
                self.pending -= 1
                self.usingPasswords = false
                if case .failure(let error) = result {
                    self.fail(error.localizedDescription)
                    done(false)
                } else {
                    self.recordUse(of: login)
                    done(true)
                }
            }
        }
    }

    /// Username and password of the selected login, for filling them in.
    func credentials(completion: @escaping ((username: String, password: String)?) -> Void) {
        guard let login = selectedLogin else { return }
        let deliver = {
            guard let password = self.held[login]?.values[.password] else {
                self.fail("No password saved for this login.")
                completion(nil)
                return
            }
            self.recordUse(of: login)
            completion((login.username, password))
        }
        if held[login]?.fetched.contains(.password) == true { deliver(); return }
        load([.password], for: login, allowUnlock: true) { ok in ok ? deliver() : completion(nil) }
    }

    /// The current 2FA code for filling into another app, fetched from Passwords when needed.
    func code(completion: @escaping (String?) -> Void) {
        guard let login = selectedLogin, login.hasCode else { return }
        let deliver = {
            guard let code = self.freshValue(.code, for: login) else {
                self.fail("Passwords didn't return a code. Try again.")
                completion(nil)
                return
            }
            self.recordUse(of: login)
            completion(code)
        }
        if freshValue(.code, for: login) != nil { deliver(); return }
        load([.code], for: login, allowUnlock: true) { ok in ok ? deliver() : completion(nil) }
    }

    enum UnlockOutcome { case notNeeded, unlocked, failed }

    /// Asks for Touch ID now if Passwords is locked, so nothing later in this visit has to.
    /// Skipped while other work is reading Passwords: that work needs it unlocked anyway, and the
    /// check would wait in line behind it.
    func unlockIfNeeded(done: @escaping (UnlockOutcome) -> Void) {
        guard !busy else { done(.notNeeded); return }
        pending += 1
        waitingForUnlock = true
        status = nil
        queue.async {
            var outcome = UnlockOutcome.notNeeded
            if self.passwords.isLocked {
                DispatchQueue.main.sync { self.usingPasswords = true; self.onUnlock?() }
                outcome = self.passwords.unlock() ? .unlocked : .failed
            }
            DispatchQueue.main.async {
                self.pending -= 1
                self.usingPasswords = false
                self.waitingForUnlock = outcome == .failed
                done(outcome)
            }
        }
    }

    /// Queued behind any Passwords work still in progress, so a copy or fill always finishes first.
    func quitPasswordsIfIdle(onlyIfLocked: Bool) {
        queue.async { self.passwords.quitIfIdle(onlyIfLocked: onlyIfLocked) }
    }

    func refresh(unlock: Bool, done: @escaping () -> Void = {}) {
        pending += 1
        queue.async {
            var list = self.passwords.loadLogins()
            if list == nil, unlock {
                DispatchQueue.main.sync { self.usingPasswords = true; self.onUnlock?() }
                if self.passwords.unlock() { list = self.passwords.loadLogins() }
            }
            if list != nil { self.lastLoaded = Date() }
            DispatchQueue.main.async {
                self.pending -= 1
                self.usingPasswords = false
                self.waitingForUnlock = false
                if let list { self.update(list) }
                done()
            }
        }
    }

    // MARK: - Fetching

    private static func codeWindow(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 30) }

    private func freshValue(_ field: Field, for login: Login) -> String? {
        switch field {
        case .username: login.username.isEmpty ? nil : login.username
        case .code: codeIsFresh(for: login) ? held[login]?.values[.code] : nil
        default: held[login]?.values[field]
        }
    }

    /// Username comes from the cached list. Website and code come from Passwords' detail pane
    /// while it stays hidden. Only the password needs Passwords brought forward for a moment.
    private func load(_ fields: [Field], for login: Login, allowUnlock: Bool, completion: @escaping (Bool) -> Void) {
        guard !Set(fields).isSubset(of: fetching[login] ?? []) else { return }
        fetching[login, default: []].formUnion(fields)
        pending += 1
        if fields.contains(.password) { usingPasswords = true }
        if allowUnlock { status = nil }
        let work = { () throws -> [Field: String] in
            var out: [Field: String] = [:]
            if fields.contains(.website) || fields.contains(.code) {
                let details = try self.passwords.details(for: login)
                for field in [Field.website, .code] where fields.contains(field) { out[field] = details[field] }
            }
            if fields.contains(.password) { out[.password] = try self.passwords.password(for: login) }
            return out
        }
        queue.async {
            var result = Result { try work() }
            var unlocked = false
            if allowUnlock, case .failure(let error) = result, error as? PasswordsError == .locked {
                DispatchQueue.main.sync { self.usingPasswords = true; self.onUnlock?() }
                unlocked = self.passwords.unlock()
                result = unlocked ? Result { try work() } : .failure(PasswordsError.unlockFailed)
            }
            DispatchQueue.main.async {
                self.pending -= 1
                self.usingPasswords = false
                self.fetching[login]?.subtract(fields)
                switch result {
                case .success(let values):
                    var h = self.held[login] ?? Held()
                    for field in fields {
                        h.values[field] = values[field]
                        h.fetched.insert(field)
                    }
                    if fields.contains(.code) { h.codeAt = Date() }
                    self.held[login] = h
                    if fields.contains(.website) { self.remember(website: values[.website] ?? "", for: login) }
                    completion(true)
                case .failure(let error):
                    if allowUnlock { self.fail(error.localizedDescription) }
                    completion(false)
                }
            }
        }
    }

    /// Picks up logins added or removed in Passwords, at most every 15 minutes, since a reload
    /// takes a few seconds and anything queued behind it waits.
    private func reloadIfStale(fillBlanks: Bool) {
        guard Date().timeIntervalSince(lastLoaded) > 15 * 60, let fresh = passwords.loadLogins(fillBlanks: fillBlanks) else { return }
        lastLoaded = Date()
        DispatchQueue.main.async { self.update(fresh) }
    }

    /// Keeps the code in the detail view current. Never asks for Touch ID on its own.
    private func startCodeTimer() {
        codeTimer?.invalidate()
        codeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, self.detail, let login = self.selectedLogin else { timer.invalidate(); return }
            guard login.hasCode, !self.codeIsFresh(for: login),
                  Date().timeIntervalSince(self.lastCodeAttempt) > 5 else { return }
            self.lastCodeAttempt = Date()
            self.load([.code], for: login, allowUnlock: false) { _ in }
        }
    }

    // MARK: - Bookkeeping

    private func finishCopy(_ value: String, _ field: Field, _ login: Login) {
        putOnClipboard(value, secret: field == .password || field == .code)
        copied[login, default: []].insert(field)
        recordUse(of: login)
        status = nil
    }

    func openGenerator() {
        generatedPassword = preferences.generatePassword()
    }

    /// A new password for whichever view is generating one: the generator or the new-login form.
    func regenerate() {
        if generatedPassword != nil { generatedPassword = preferences.generatePassword() }
        if newLogin != nil { newLogin?.password = preferences.generatePassword() }
    }

    /// Copies the generator's password, for a sign-up form.
    func copyGeneratedPassword() {
        guard let password = generatedPassword else { return }
        putOnClipboard(password, secret: true)
        generatedPassword = nil
    }

    private func putOnClipboard(_ value: String, secret: Bool) {
        let pasteboard = NSPasteboard.general
        // Secrets stay on this Mac instead of reaching nearby devices through Universal Clipboard.
        if secret { _ = pasteboard.prepareForNewContents(with: .currentHostOnly) } else { pasteboard.clearContents() }
        pasteboard.setString(value, forType: .string)
        guard secret else { return }
        // Asks clipboard managers not to record it.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let clearAfter = preferences.clearClipboardAfter
        guard clearAfter > 0 else { return }
        let count = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(clearAfter)) {
            if pasteboard.changeCount == count { pasteboard.clearContents() }
        }
    }

    private func recordUse(of login: Login) {
        usage[login.key, default: 0] += 1
        if persists { UserDefaults.standard.set(usage, forKey: Self.usageKey) }
    }

    private func forget() {
        held = [:]
        copied = [:]
    }

    // MARK: - Website icons

    func iconHost(for login: Login) -> String? {
        SiteIcons.host(website: websites[login.key], title: login.title)
    }

    /// Downloads a login's icon now rather than when its row first scrolls into view. Saved
    /// icons are skipped, so this costs nothing for logins that already have one.
    private func fetchIcon(for login: Login) {
        guard preferences.showSiteIcons, let host = iconHost(for: login) else { return }
        icons.request(host)
    }

    /// How many of the current logins have had their website read.
    var websitesKnown: Int { logins.filter { websites[$0.key] != nil }.count }

    /// Reads every login's website from Passwords so each can show its icon. Runs in small
    /// batches on the Passwords queue, so a copy or fill never waits for the whole list, and
    /// skips logins already read, so starting again continues where it stopped.
    func startBackfill() {
        guard !backfillRunning else { return }
        backfillRunning = true
        backfillStop.withLock { $0 = false }
        backfillNote = nil
        backfillBatch(first: true)
    }

    func stopBackfill() {
        backfillStop.withLock { $0 = true }
    }

    /// Batches let a copy or fill run between them instead of waiting for the whole scan.
    private func backfillBatch(first: Bool) {
        // A row Passwords never drew has no title to match, so it can't be read.
        let batch = Array(logins.filter { websites[$0.key] == nil && !$0.title.isEmpty }.prefix(20))
        guard !batch.isEmpty else { backfillRunning = false; return }
        queue.async {
            let read = {
                try self.passwords.websites(of: batch, fillBlanks: first,
                                            stop: { self.backfillStop.withLock { $0 } },
                                            found: { login, site in
                                                DispatchQueue.main.async {
                                                    self.websites[login.key] = site
                                                    self.fetchIcon(for: login)
                                                }
                                            })
            }
            var result = Result(catching: read)
            // Passwords locks itself after a few minutes in the background, which a full scan can
            // outlast. Ask for Touch ID and keep going rather than stopping.
            if case .failure(let error) = result, error as? PasswordsError == .locked {
                DispatchQueue.main.sync { self.usingPasswords = true; self.onUnlock?() }
                let unlocked = self.passwords.unlock()
                DispatchQueue.main.sync { self.usingPasswords = false }
                // Right after an unlock Passwords can take a moment to show its list again.
                for _ in 0..<4 where unlocked {
                    result = Result(catching: read)
                    guard case .failure(let error) = result, error as? PasswordsError == .locked else { break }
                    usleep(500_000)
                }
            }
            DispatchQueue.main.async {
                self.saveWebsites()
                switch result {
                case .success:
                    if self.backfillStop.withLock({ $0 }) {
                        self.backfillRunning = false
                    } else {
                        // A login Passwords couldn't show is marked done, so the scan can't loop on it.
                        for login in batch where self.websites[login.key] == nil { self.websites[login.key] = "" }
                        self.backfillBatch(first: false)
                    }
                case .failure(let error):
                    self.backfillRunning = false
                    self.backfillNote = error as? PasswordsError == .locked
                        ? "Stopped because Passwords locked. Press Continue to unlock it and pick up where it stopped."
                        : error.localizedDescription
                }
            }
        }
    }

    private func remember(website: String, for login: Login) {
        guard websites[login.key] != website else { return }
        websites[login.key] = website
        saveWebsites()
    }

    private func saveWebsites() {
        guard persists else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: Self.websitesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(websites).write(to: Self.websitesURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.websitesURL.path)
    }

    private func fail(_ message: String) {
        status = message
        NSSound.beep()
    }

    /// Replaces the list, keeps the same login selected, and saves it for the next launch.
    private func update(_ list: [Login]) {
        let current = selectedLogin
        logins = list
        if let current, let index = results.firstIndex(of: current), index != selection { selection = index }
        guard persists else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(list).write(to: Self.cacheURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.cacheURL.path)
    }
}
