import AppKit
import Carbon
import Combine
import SwiftUI

/// Owns the search panel, the global shortcut, the menu bar icon and Settings, and handles the
/// panel's keyboard: navigation, copying, opening websites and filling in logins.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let preferences = Preferences.shared
    private let updater = Updater()
    private lazy var model: SearchModel = {
        #if DEBUG
        if Demo.isOn { return SearchModel(preferences: preferences, passwords: DemoPasswords(), persists: false) }
        #endif
        return SearchModel(preferences: preferences)
    }()
    private lazy var settings = SettingsWindow(preferences: preferences, model: model, updater: updater)
    private lazy var welcome: AppWindow = AppWindow(title: "Welcome to QuickPass") { [unowned self] in
        WelcomeView(model: model, preferences: preferences,
                    refocus: { [unowned self] in welcome.show() },
                    finish: { [unowned self] in
                        preferences.didOnboard = true
                        welcome.close()
                    })
    }
    private var panel: SearchPanel!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    /// The app that was in front when the panel opened. Focus goes back to it afterwards.
    private var previousApp: NSRunningApplication?
    private var subscriptions: Set<AnyCancellable> = []
    private var quitTimer: Timer?
    /// Until this moment, losing focus means macOS is late handing it back after Passwords hid,
    /// not that the user clicked away.
    private var reclaimFocusUntil = Date.distantPast
    /// The last click in another app, which always means the user is moving on.
    private var lastClickAway = Date.distantPast
    /// The browser tab's host when the panel opened, for suggestions and new logins.
    private var browserHost: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = SearchPanel(rootView: SearchView(model: model, preferences: preferences,
                                                 activate: { [unowned self] item in activate(item) }))
        panel.delegate = self
        model.onUnlock = { [weak self] in self?.hidePanelOncePasswordsInFront() }
        model.passwordsHidingSpot = { [weak self] in self?.searchCardFrame() }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return handle(event)
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.lastClickAway = Date()
        }

        setUpStatusItem()
        observePreferences()
        preferences.enableLaunchAtLoginOnFirstRun()
        if !preferences.didOnboard || !AXIsProcessTrusted() {
            welcome.show()
        } else {
            model.refresh(unlock: false) { [weak self] in
                self?.quitPasswordsIfDone()
                #if DEBUG
                if Demo.isOn { self?.model.startBackfill() } // so every demo login has its icon
                #endif
            }
        }
        quitTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, preferences.quitPasswords == .onceLocked, !panel.isVisible else { return }
            model.quitPasswordsIfIdle(onlyIfLocked: true)
        }
        // Lets macOS fold this wake-up into others it's already doing, which saves battery.
        quitTimer?.tolerance = 10
    }

    /// With the default setting, Passwords leaves the Dock as soon as QuickPass is done with it.
    private func quitPasswordsIfDone() {
        guard preferences.quitPasswords == .rightAway, !panel.isVisible else { return }
        model.quitPasswordsIfIdle(onlyIfLocked: false)
    }

    /// Opening QuickPass again while it runs shows Settings. With the menu bar icon hidden,
    /// that's the way in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// Clicking elsewhere closes the panel, except when the app taking focus is Passwords itself,
    /// which happens on purpose for Touch ID and password copies.
    func windowDidResignKey(_ notification: Notification) {
        closeUnlessPasswordsTookFocus()
    }

    func applicationDidResignActive(_ notification: Notification) {
        closeUnlessPasswordsTookFocus()
    }

    /// The new front app isn't always reported yet when focus starts to move, so check a beat later.
    private func closeUnlessPasswordsTookFocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            guard panel.isVisible, !panel.isKeyWindow, !model.usingPasswords,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier != PasswordsApp.bundleID else { return }
            if Date() < reclaimFocusUntil, !clickedAway(since: Date().addingTimeInterval(-1)) { show() } else { close(restoringFocus: false) }
        }
    }

    /// When Passwords hides after Touch ID, macOS gives focus back to the previous app a moment
    /// later, after the panel is already up. For a second, take focus back instead of closing.
    private func expectFocusHandback() {
        reclaimFocusUntil = Date().addingTimeInterval(1)
    }

    private func clickedAway(since date: Date) -> Bool { lastClickAway > date }

    // MARK: - Setup

    private func observePreferences() {
        preferences.$openShortcut.combineLatest(preferences.$isRecordingShortcut)
            .sink { [weak self] shortcut, recording in
                guard let self else { return }
                hotKey = nil
                guard !recording else { return }
                hotKey = HotKey(shortcut) { [weak self] in self?.toggle() }
                preferences.openShortcutTaken = hotKey == nil
            }
            .store(in: &subscriptions)
        preferences.$showMenuBarIcon
            .sink { [weak self] visible in self?.statusItem.isVisible = visible }
            .store(in: &subscriptions)
        // Rebuilt after the change lands, since @Published publishes before the new value is stored.
        Publishers.CombineLatest3(preferences.$copyUsernameShortcut, preferences.$copyPasswordShortcut,
                                  preferences.$copyCodeShortcut)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in NSApp.mainMenu = self?.makeMainMenu() }
            .store(in: &subscriptions)
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image
        let menu = NSMenu()
        menu.addItem(withTitle: "Open QuickPass", action: #selector(openFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reload Logins", action: #selector(reloadLogins), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit QuickPass", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    /// A menu bar app shows no menus, but AppKit still matches ⌘ shortcuts against the main menu
    /// and beeps at a disabled match, such as Copy with no text selected. This hidden menu gives
    /// the copy shortcuts and the standard editing keys an enabled home.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = NSMenu(title: "Edit")
        let copyCommands: [(String, Field, Selector)] = [
            ("Copy Username", .username, #selector(copyUsername)),
            ("Copy Password", .password, #selector(copyPassword)),
            ("Copy Verification Code", .code, #selector(copyCode)),
        ]
        for (title, field, action) in copyCommands {
            guard let shortcut = preferences.shortcut(for: field), let key = shortcut.menuKey else { continue }
            let item = editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = shortcut.modifiers
            item.target = self
        }
        editMenu.addItem(withTitle: "Generate Password", action: #selector(generatePassword), keyEquivalent: "g").target = self
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let main = NSMenu()
        for submenu in [appMenu, editMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }

    // MARK: - Opening and closing

    @objc private func openFromMenu() { open() }

    @objc private func reloadLogins() { model.refresh(unlock: true) }

    @objc private func checkForUpdates() { updater.checkForUpdates() }

    @objc private func showSettings() {
        close(restoringFocus: false)
        settings.show()
    }

    private func toggle() { panel.isVisible ? close(restoringFocus: true) : open() }

    private func open() {
        guard AXIsProcessTrusted() else { welcome.show(); return }
        // Activating QuickPass would bring Settings forward along with the panel.
        settings.close()
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != getpid(), front.bundleIdentifier != PasswordsApp.bundleID {
            previousApp = front
        }
        browserHost = preferences.suggestFromBrowser ? BrowserTab.host(in: previousApp) : nil
        let site = browserHost.flatMap(BrowserTab.siteName(fromHost:))
        present(suggesting: site)
        // Touch ID up front, so copying, details and fill don't stop for it later. It has to come
        // after the panel: macOS only lets the active app bring Passwords forward, and QuickPass
        // becomes active by showing it.
        if preferences.unlockOnOpen {
            let opened = Date()
            model.unlockIfNeeded { [weak self] outcome in
                guard let self, outcome != .notNeeded else { return }
                // Touch ID stops when the user clicks elsewhere, and then they've moved on.
                if outcome == .failed, clickedAway(since: opened) { close(restoringFocus: false) } else { returnToPanel() }
            }
        }
    }

    private func present(suggesting site: String?) {
        model.willOpen(suggesting: site)
        show()
        selectSearchText()
        // Nothing to search yet: go straight to Touch ID and load the list.
        if model.logins.isEmpty, !model.busy {
            model.refresh(unlock: true) { [weak self] in self?.returnToPanel() }
        }
    }

    /// The visible search card while the panel is open, in top-left-based screen coordinates,
    /// which is how Accessibility positions windows. The card is 640 wide, centered and top-aligned
    /// in the panel.
    private func searchCardFrame() -> CGRect? {
        guard panel.isVisible, let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let top = panel.frame.maxY - SearchPanel.cardTop
        return CGRect(x: panel.frame.midX - 320, y: primaryHeight - top, width: 640, height: 300)
    }

    /// QuickPass becomes the active app while the panel is up, like Spotlight or Raycast, so
    /// every keystroke lands here instead of in the app behind it.
    private func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height * 0.16))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Hiding the panel while AppKit is still delivering the keypress that closed it (Esc, a copy
    /// shortcut) makes AppKit beep, because the key window it was routing to is gone. So hide it
    /// on the next turn of the run loop, once that keypress is done.
    private func close(restoringFocus: Bool, then: (() -> Void)? = nil) {
        DispatchQueue.main.async { [self] in
            panel.orderOut(nil)
            model.didClose()
            quitPasswordsIfDone()
            if restoringFocus { restoreFocus(then: then) }
        }
    }

    /// Selects the remembered search so typing replaces it. SwiftUI gives the field focus a beat
    /// after the panel shows, and focusing clears the selection, so wait for focus first.
    private func selectSearchText(attempt: Int = 0) {
        if attempt > 0, panel.isKeyWindow, let editor = panel.firstResponder as? NSTextView {
            editor.selectAll(nil)
            return
        }
        guard attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.selectSearchText(attempt: attempt + 1) }
    }

    /// Hands focus back to the previous app once the shortcut's keys are released. Doing it while
    /// they're still down sends the rest of the keypress to that app, which beeps.
    private func restoreFocus(then: (() -> Void)?, attempt: Int = 0) {
        let keysDown = !NSEvent.modifierFlags.intersection(.shortcutKeys).isEmpty
            || CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_C))
            || CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Return))
        if keysDown, attempt < 50 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.restoreFocus(then: then, attempt: attempt + 1) }
            return
        }
        previousApp?.activate()
        guard let then else { return }
        waitForPreviousApp(then: then)
    }

    private func waitForPreviousApp(then: @escaping () -> Void, attempt: Int = 0) {
        if NSWorkspace.shared.frontmostApplication == previousApp || attempt >= 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: then)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in self?.waitForPreviousApp(then: then, attempt: attempt + 1) }
    }

    /// Moves the panel out of the way of Passwords' Touch ID prompt, but only once Passwords is in
    /// front. Closing QuickPass's only window earlier makes macOS activate the next app in line,
    /// which takes focus from Passwords and cancels Touch ID.
    private func hidePanelOncePasswordsInFront(attempt: Int = 0) {
        let inFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == PasswordsApp.bundleID
        if inFront || attempt >= 40 { panel.orderOut(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.hidePanelOncePasswordsInFront(attempt: attempt + 1) }
    }

    /// After Passwords was in front (Touch ID or a password copy), takes focus back once it has
    /// stepped aside.
    private func returnToPanel(attempt: Int = 0, since start: Date = Date()) {
        if attempt == 0 { expectFocusHandback() }
        // A click elsewhere means the user has moved on, so don't pull the panel back.
        guard !clickedAway(since: start) else { return }
        let passwordsInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == PasswordsApp.bundleID
        if !passwordsInFront { show() }
        guard attempt < 40, passwordsInFront || !panel.isKeyWindow else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.returnToPanel(attempt: attempt + 1, since: start) }
    }

    // MARK: - Keyboard

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            if model.detail, panel.isKeyWindow { model.reveal = event.modifierFlags.contains(.option) }
            return event
        }
        // The release (and any repeats) of a key that just closed the panel still arrive addressed
        // to it, and AppKit beeps at events for a window that's gone. Swallow them.
        if !panel.isVisible, event.window == nil || event.window === panel { return nil }
        // Some keys, Esc among them, can arrive with no window set, so go by which window is key.
        guard event.type == .keyDown, event.window === panel || (event.window == nil && panel.isKeyWindow) else { return event }
        let modifiers = event.modifierFlags.intersection(.shortcutKeys)

        // The new-login form takes typing, so only its own keys are handled.
        if model.newLogin != nil {
            switch (Int(event.keyCode), modifiers) {
            case (kVK_Escape, []): model.newLogin = nil
            case (kVK_Return, []): saveNewLogin()
            case (kVK_ANSI_G, [.command]): model.regenerate()
            default: return event
            }
            return nil
        }

        if model.generatedPassword != nil {
            switch (Int(event.keyCode), modifiers) {
            case (kVK_Escape, []): model.generatedPassword = nil
            case (kVK_Return, []):
                model.copyGeneratedPassword()
                close(restoringFocus: true)
            case (kVK_ANSI_G, [.command]): model.regenerate()
            default: return event
            }
            return nil
        }

        // Delete waits for one more Return, or anything else cancels it.
        if model.confirmingDelete {
            if Int(event.keyCode) == kVK_Return, modifiers.isEmpty { delete() } else { model.confirmingDelete = false }
            return nil
        }

        for field in [Field.username, .password, .code] where preferences.shortcut(for: field)?.matches(event) == true {
            copy(field)
            return nil
        }
        switch (Int(event.keyCode), modifiers) {
        case (kVK_Escape, []):
            if model.detail { model.detail = false } else { close(restoringFocus: true) }
        case (kVK_LeftArrow, []) where model.detail:
            model.detail = false
        case (kVK_RightArrow, []) where !model.detail && model.selectedLogin != nil:
            model.openDetail { [weak self] in self?.returnToPanel() }
            // Typing a new search from the detail view replaces the old one.
            selectSearchText()
        case (kVK_DownArrow, []):
            model.detail ? model.moveInDetail(1) : model.move(1)
        case (kVK_UpArrow, []):
            model.detail ? model.moveInDetail(-1) : model.move(-1)
        case (kVK_Return, []) where !model.detail && model.isOnCreateRow, (kVK_ANSI_N, [.command]):
            model.startNewLogin(browserHost: browserHost)
        case (kVK_Return, []) where model.detail:
            if let item = model.selectedItem { activate(item) }
        case (kVK_Return, [.command]) where model.selectedLogin != nil:
            fill()
        case (kVK_Return, [.command, .option]) where model.selectedLogin?.hasCode == true:
            fillCode()
        case (kVK_ANSI_O, [.command]) where model.selectedLogin != nil:
            openWebsite()
        case (kVK_ANSI_O, [.command, .shift]) where model.selectedLogin != nil:
            openInPasswords()
        case (kVK_Delete, [.command]) where model.detail:
            model.confirmingDelete = true
        case (kVK_ANSI_G, [.command]):
            generatePassword()
        default:
            return event
        }
        return nil
    }

    // MARK: - Actions

    @objc private func copyUsername() { copy(.username) }
    @objc private func copyPassword() { copy(.password) }
    @objc private func copyCode() { copy(.code) }

    /// The copy commands only apply while the search panel is open.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copyUsername), #selector(copyPassword), #selector(copyCode), #selector(generatePassword): panel.isVisible
        default: true
        }
    }

    private func copy(_ field: Field) {
        model.copy(field) { [weak self] copied in
            if copied { self?.close(restoringFocus: true) } else { self?.returnToPanel() }
        }
    }

    private func openWebsite() {
        model.website { [weak self] url in
            guard let self else { return }
            guard let url else { returnToPanel(); return }
            close(restoringFocus: false)
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens the generator, or makes a different password where one is already showing.
    @objc private func generatePassword() {
        if model.newLogin != nil || model.generatedPassword != nil { model.regenerate() } else { model.openGenerator() }
    }

    /// Saved logins close the panel with the password on the clipboard, ready to paste into the
    /// sign-up form the panel was opened over.
    private func saveNewLogin() {
        model.saveNewLogin { [weak self] saved in
            if saved { self?.close(restoringFocus: true) } else { self?.returnToPanel() }
        }
    }

    /// Return or a double-click on a detail view row.
    private func activate(_ item: DetailItem) {
        switch item {
        case .field(.website): openWebsite()
        case .field(let field): copy(field)
        case .fill: fill()
        case .fillCode: fillCode()
        case .openInPasswords: openInPasswords()
        case .delete: model.confirmingDelete = true
        }
    }

    private func delete() {
        model.delete { [weak self] _ in self?.returnToPanel() }
    }

    private func openInPasswords() {
        model.openInPasswords { [weak self] opened in
            if opened { self?.close(restoringFocus: false) } else { self?.returnToPanel() }
        }
    }

    /// Types the username, Tab and the password into the app the panel was opened over.
    private func fill() {
        model.credentials { [weak self] credentials in
            guard let self else { return }
            guard let credentials else { returnToPanel(); return }
            close(restoringFocus: true) {
                DispatchQueue.global(qos: .userInitiated).async {
                    if !credentials.username.isEmpty {
                        Keyboard.type(credentials.username)
                        Keyboard.pressTab()
                    }
                    Keyboard.type(credentials.password)
                }
            }
        }
    }

    private func fillCode() {
        model.code { [weak self] code in
            guard let self else { return }
            guard let code else { returnToPanel(); return }
            close(restoringFocus: true) {
                DispatchQueue.global(qos: .userInitiated).async { Keyboard.type(code) }
            }
        }
    }
}

