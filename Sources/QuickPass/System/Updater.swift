import AppKit
import Combine
import Sparkle

/// Checks GitHub for new versions and installs them, using Sparkle. The feed and the public key
/// that verifies each update are set in Info.plist (SUFeedURL, SUPublicEDKey).
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    @Published private(set) var canCheck = false

    private lazy var controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                               userDriverDelegate: self)

    override init() {
        super.init()
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// QuickPass has no Dock icon, so an update window would otherwise open behind other apps.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        NSApp.activate(ignoringOtherApps: true)
    }
}
