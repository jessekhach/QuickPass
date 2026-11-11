import SwiftUI

/// A small capsule showing a shortcut. Turns into a green checkmark once that field is copied.
struct Chip: View {
    let icon: String
    let label: String
    var done = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: done ? "checkmark" : icon)
            Text(label)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(done ? Color.green : Color.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary))
    }
}

/// The site's own icon when Settings allows it and one has been fetched, otherwise a monogram.
struct LoginIcon: View {
    let login: Login
    let host: String?
    let size: CGFloat
    @ObservedObject var icons: SiteIcons
    @ObservedObject var preferences: Preferences

    var body: some View {
        Group {
            if preferences.showSiteIcons, let host, let image = icons.images[host] {
                // On white so dark logos and transparent ones read the same in dark mode.
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * 0.66, height: size * 0.66)
                    .frame(width: size, height: size)
                    .background(Circle().fill(.white))
                    .overlay(Circle().strokeBorder(.black.opacity(0.08)))
            } else {
                Monogram(title: login.title, size: size)
            }
        }
        .task(id: host) {
            if preferences.showSiteIcons, let host { icons.request(host) }
        }
    }
}

/// Starts reading every login's website for icons, and shows progress with a Stop button while
/// it runs. Used in Settings and the welcome window.
struct BackfillButton: View {
    @ObservedObject var model: SearchModel
    var showsProgress = true

    var body: some View {
        if model.backfillRunning {
            HStack(spacing: 8) {
                if showsProgress {
                    ProgressView(value: Double(model.websitesKnown), total: Double(max(model.logins.count, 1)))
                        .frame(width: 80)
                }
                Button("Stop", action: model.stopBackfill)
            }
        } else {
            Button(model.websitesKnown == 0 ? "Find Icons" : "Continue", action: model.startBackfill)
        }
    }
}

/// The first letter of a login's title on a colored circle.
struct Monogram: View {
    let title: String
    let size: CGFloat

    var body: some View {
        Text(String(title.prefix(1)).uppercased())
            .font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
    }

    /// Derived from the title so the same site always gets the same color.
    private var color: Color {
        let n = title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Color(hue: Double(n % 12) / 12, saturation: 0.45, brightness: 0.72)
    }
}

extension Field {
    var label: String {
        switch self {
        case .username: "Username"
        case .password: "Password"
        case .code: "Verification code"
        case .website: "Website"
        }
    }

    var icon: String {
        switch self {
        case .username: "person.fill"
        case .password: "key.fill"
        case .code: "clock.fill"
        case .website: "globe"
        }
    }
}
