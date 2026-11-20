import Combine
import Sparkle

/// In-app updates through Sparkle. The feed (`SUFeedURL` in Info.plist) is the `appcast.xml`
/// that scripts/release.sh attaches to each GitHub release; updates are verified with the
/// EdDSA key in `SUPublicEDKey`.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    /// A newer version found by a scheduled check that the user hasn't looked at yet.
    /// Shown in the menu bar instead of an alert window, which would land behind whatever
    /// the user is typing into.
    @Published private(set) var pendingVersion: String?
    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Also brings up an update a scheduled check already found.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        #if DEBUG
        // Xcode builds are numbered 1, so every release looks newer; only check when asked.
        if updateCheck == .updatesInBackground {
            throw NSError(domain: "ChillTalk", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Scheduled update checks are off in Debug builds"])
        }
        #endif
    }
}

// Sparkle calls the user driver delegate on the main thread but doesn't annotate the protocol.
extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Sparkle shows the alert itself only when it would come to the front (just after
        // launch, or when the Mac was idle); otherwise the menu bar reminds the user.
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        pendingVersion = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
