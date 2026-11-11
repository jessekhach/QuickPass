import AppKit
import Combine
import SwiftUI

/// First-run setup: Accessibility access, loading the login list, and the shortcut.
/// Shown again at launch whenever Accessibility access is missing.
struct WelcomeView: View {
    @ObservedObject var model: SearchModel
    @ObservedObject var preferences: Preferences
    /// Brings this window back after Passwords was in front for Touch ID.
    let refocus: () -> Void
    let finish: () -> Void

    @State private var trusted = AXIsProcessTrusted()
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                Text("Welcome to QuickPass")
                    .font(.system(size: 24, weight: .semibold))
                Text("Search Apple Passwords from anywhere with a shortcut.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                Step(number: 1, title: "Allow Accessibility",
                     detail: "QuickPass reads the Passwords app the way a screen reader does.",
                     done: trusted) {
                    Button("Open System Settings", action: requestAccess)
                }
                Divider().padding(.leading, 52)
                Step(number: 2, title: "Load your logins",
                     detail: model.logins.isEmpty
                        ? "Unlock Passwords with Touch ID. QuickPass keeps site names and usernames, never passwords."
                        : "\(model.logins.count.formatted()) logins ready to search.",
                     done: !model.logins.isEmpty) {
                    Button("Unlock Passwords") { model.refresh(unlock: true, done: refocus) }
                        .disabled(!trusted || model.busy)
                }
                Divider().padding(.leading, 52)
                Step(number: 3, title: "Show website icons",
                     detail: model.backfillRunning || model.websitesKnown > 0
                        ? "\(model.websitesKnown.formatted()) of \(model.logins.count.formatted()) logins checked. Optional, and you can stop any time."
                        : "QuickPass reads each login's website from Passwords and gets the icon from that site. Optional.",
                     done: !model.logins.isEmpty && model.websitesKnown == model.logins.count) {
                    BackfillButton(model: model)
                        .disabled(!trusted || model.logins.isEmpty)
                }
                Divider().padding(.leading, 52)
                Step(number: 4, title: "Press \(preferences.openShortcut.display) anywhere",
                     detail: "The search bar opens over whatever you're doing. You can change the shortcut in Settings.",
                     done: false) {
                    EmptyView()
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))

            Button("Get Started", action: finish)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!trusted || model.logins.isEmpty)
        }
        .padding(32)
        .frame(width: 540)
        .onReceive(poll) { _ in trusted = AXIsProcessTrusted() }
    }

    /// Adds QuickPass to the Accessibility list, then opens that page so it's one switch away.
    private func requestAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

private struct Step<Action: View>: View {
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor.opacity(0.15))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if !done { action() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
