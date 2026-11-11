import AppKit
import Carbon
import SwiftUI

/// The Settings window: a page per toolbar icon, the standard Mac layout. The window takes each
/// page's size and title.
final class SettingsWindow {
    private var window: NSWindow?
    private let preferences: Preferences
    private let model: SearchModel
    private let updater: Updater

    init(preferences: Preferences, model: SearchModel, updater: Updater) {
        self.preferences = preferences
        self.model = model
        self.updater = updater
    }

    func show() {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            let pages: [(String, String, AnyView)] = [
                ("General", "gearshape", AnyView(GeneralSettings(preferences: preferences, model: model))),
                ("Shortcuts", "command", AnyView(ShortcutSettings(preferences: preferences))),
                ("Privacy", "hand.raised", AnyView(PrivacySettings(preferences: preferences))),
                ("Updates", "arrow.down.circle", AnyView(UpdateSettings(updater: updater))),
            ]
            for (title, icon, view) in pages {
                let host = NSHostingController(rootView: view)
                host.sizingOptions = .preferredContentSize
                host.title = title // the window shows the selected page's title
                let item = NSTabViewItem(viewController: host)
                item.label = title
                item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
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

private struct GeneralSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var model: SearchModel

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { preferences.launchAtLogin },
                                                        set: { preferences.launchAtLogin = $0 }))
                Toggle("Show in menu bar", isOn: $preferences.showMenuBarIcon)
                Toggle("Suggest the login for your browser's current tab", isOn: $preferences.suggestFromBrowser)
            } footer: {
                if !preferences.showMenuBarIcon {
                    Text("To get back here, open QuickPass again from Applications or Spotlight.")
                }
            }

            Section("Passwords app") {
                Toggle("Unlock Passwords when QuickPass opens", isOn: $preferences.unlockOnOpen)
                Picker("Quit the Passwords app", selection: $preferences.quitPasswords) {
                    Text("Once Passwords locks").tag(QuitPasswords.onceLocked)
                    Text("When QuickPass closes").tag(QuitPasswords.rightAway)
                    Text("Never").tag(QuitPasswords.never)
                }
                LabeledContent("Logins") {
                    HStack {
                        Text(model.logins.count.formatted())
                        Button("Reload") { model.refresh(unlock: true) }
                            .disabled(model.busy)
                    }
                }
            }

            Section {
                Toggle("Show website icons", isOn: $preferences.showSiteIcons)
                LabeledContent("Websites checked") {
                    HStack {
                        Text("\(model.websitesKnown.formatted()) of \(model.logins.count.formatted())")
                        if model.backfillRunning || model.websitesKnown < model.logins.count {
                            BackfillButton(model: model, showsProgress: false)
                                .disabled(model.logins.isEmpty)
                        }
                    }
                }
            } header: {
                Text("Website icons")
            } footer: {
                if model.backfillRunning {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(model.websitesKnown), total: Double(max(model.logins.count, 1)))
                        Text("Keeping Passwords open speeds this up. It may ask for Touch ID again.")
                    }
                } else if let note = model.backfillNote {
                    Text(note)
                }
            }

        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        // The footer under Website icons adds a line while the scan runs or after it stops early.
        .frame(width: 480, height: model.backfillRunning ? 506 : model.backfillNote != nil ? 486 : 458)
    }
}

private struct PrivacySettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Picker("Clear copied passwords", selection: $preferences.clearClipboardAfter) {
                    Text("After 30 seconds").tag(30)
                    Text("After 1 minute").tag(60)
                    Text("After 90 seconds").tag(90)
                    Text("Never").tag(0)
                }
                Picker("Remember last search", selection: $preferences.rememberSearchFor) {
                    Text("Off").tag(0)
                    Text("30 seconds").tag(30)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 120)
    }
}

private struct ShortcutSettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section {
                ShortcutRow(title: "Open QuickPass", shortcut: $preferences.openShortcut, defaultShortcut: .open,
                            preferences: preferences)
                if preferences.openShortcutTaken {
                    Text("Another app already uses this shortcut. Pick a different one.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            Section("In the search bar") {
                ShortcutRow(title: "Copy username", shortcut: $preferences.copyUsernameShortcut, defaultShortcut: .copyUsername,
                            preferences: preferences)
                ShortcutRow(title: "Copy password", shortcut: $preferences.copyPasswordShortcut, defaultShortcut: .copyPassword,
                            preferences: preferences)
                ShortcutRow(title: "Copy verification code", shortcut: $preferences.copyCodeShortcut, defaultShortcut: .copyCode,
                            preferences: preferences)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 270)
    }
}

private struct UpdateSettings: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecks },
                                                                        set: { updater.automaticallyChecks = $0 }))
                LabeledContent("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")") {
                    Button("Check Now", action: updater.checkForUpdates)
                        .disabled(!updater.canCheck)
                }
            }
            Section {
                HStack {
                    Text("QuickPass is free and open source.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("GitHub", destination: URL(string: "https://github.com/jessekhach/QuickPass")!)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480, height: 190)
    }
}

private struct ShortcutRow: View {
    let title: String
    @Binding var shortcut: Shortcut
    let defaultShortcut: Shortcut
    @ObservedObject var preferences: Preferences

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                if shortcut != defaultShortcut {
                    Button {
                        shortcut = defaultShortcut
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to \(defaultShortcut.display)")
                }
                ShortcutRecorder(shortcut: $shortcut, preferences: preferences)
            }
        }
    }
}

/// Click, then press the new shortcut. Escape cancels.
private struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    @ObservedObject var preferences: Preferences
    @State private var monitor: Any?

    private var recording: Bool { monitor != nil }

    var body: some View {
        Button(recording ? "Press shortcut" : shortcut.display) {
            recording ? stop() : start()
        }
        .frame(minWidth: 110)
        .onDisappear(perform: stop)
    }

    private func start() {
        preferences.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == kVK_Escape {
                stop()
            } else if let recorded = Shortcut(event: event) {
                shortcut = recorded
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        preferences.isRecordingShortcut = false
    }
}
