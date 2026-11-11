import SwiftUI

/// One login's details, opened with → from the result list.
struct DetailView: View {
    @ObservedObject var model: SearchModel
    @ObservedObject var preferences: Preferences
    let login: Login
    let activate: (DetailItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 12)
            HStack(spacing: 12) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                LoginIcon(login: login, host: model.iconHost(for: login), size: 34, icons: model.icons, preferences: preferences)
                Text(login.title).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 62)
            Divider().padding(.horizontal, 12)
            VStack(spacing: 0) {
                ForEach(Array(model.items(for: login).enumerated()), id: \.element) { index, item in
                    row(for: item, selected: index == model.detailSelection)
                        .onTapGesture(count: 2) { activate(item) }
                        .onTapGesture { model.detailSelection = index }
                }
            }
            .padding(6)
        }
    }
}

private extension DetailView {
    @ViewBuilder func row(for item: DetailItem, selected: Bool) -> some View {
        switch item {
        case .field(let field):
            FieldRow(model: model, preferences: preferences, login: login, field: field, selected: selected)
                .frame(height: 54)
        case .fill:
            ActionRow(icon: "keyboard", title: "Fill in username and password", shortcut: "⌘↩", selected: selected)
                .frame(height: 42)
        case .fillCode:
            ActionRow(icon: "number", title: "Fill in verification code", shortcut: "⌥⌘↩", selected: selected)
                .frame(height: 42)
        case .openInPasswords:
            ActionRow(icon: "key.viewfinder", title: "Open in Passwords", shortcut: "⇧⌘O", selected: selected)
                .frame(height: 42)
        case .delete:
            if model.confirmingDelete {
                ConfirmDeleteRow(login: login).frame(height: 42)
            } else {
                ActionRow(icon: "trash", title: "Delete…", shortcut: "⌘⌫", selected: selected, destructive: true)
                    .frame(height: 42)
            }
        }
    }
}

private struct ActionRow: View {
    let icon: String
    let title: String
    let shortcut: String
    let selected: Bool
    var destructive = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            Text(title).font(.system(size: 14)).foregroundStyle(destructive ? Color.red : Color.primary)
            Spacer(minLength: 8)
            Chip(icon: icon, label: shortcut)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }
}

/// Asks once more before deleting: Return deletes, any other key cancels.
private struct ConfirmDeleteRow: View {
    let login: Login

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.fill")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .frame(width: 30)
            Text(login.username.isEmpty ? "Delete \(login.title)?" : "Delete \(login.title) (\(login.username))?")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("↩ Delete   ⎋ Cancel")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red))
    }
}

private struct FieldRow: View {
    @ObservedObject var model: SearchModel
    @ObservedObject var preferences: Preferences
    let login: Login
    let field: Field
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: field.icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(field.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                content.lineLimit(1)
            }
            Spacer(minLength: 8)
            if let shortcut = preferences.shortcut(for: field) {
                Chip(icon: field.icon, label: shortcut.display, done: model.copied[login]?.contains(field) == true)
            } else if field == .website {
                Chip(icon: "arrow.up.right.square", label: "⌘O")
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var content: some View {
        let value = model.value(field, for: login)
        switch field {
        case .password:
            Text(model.reveal ? value ?? "…" : String(repeating: "•", count: 12))
                .font(.system(size: 15, design: .monospaced))
        case .code:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let value, model.codeIsFresh(for: login, at: context.date) {
                    HStack(spacing: 8) {
                        Text(Self.grouped(value)).font(.system(size: 15, weight: .medium, design: .monospaced))
                        Text("\(30 - Int(context.date.timeIntervalSince1970) % 30)s")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    loading
                }
            }
        default:
            if let value { Text(value).font(.system(size: 15)) } else { loading }
        }
    }

    private var loading: some View {
        ProgressView().controlSize(.small).frame(height: 18)
    }

    /// "123456" reads as "123 456".
    private static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
