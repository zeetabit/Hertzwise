import AppKit
import Observation
import Sparkle

/// Updates through Sparkle: a daily check of the appcast published with each
/// release, and an install that verifies the update's EdDSA signature and that
/// the new app carries the same code signature before replacing this one.
///
/// Hertzwise lives in the menu bar, so a scheduled check doesn't pop a window
/// over the user's work: it shows "Update available" in the panel's menu
/// (Sparkle's gentle reminders) until the user looks at it. Main thread only.
@Observable
final class Updates: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()

    /// A newer version a scheduled check found and the user hasn't seen yet.
    private(set) var availableVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                  userDriverDelegate: self)
    }

    func checkForUpdates() {
        // A menu-bar app is never the active app: without this, Sparkle's
        // window opens behind the frontmost app.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        availableVersion = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}
