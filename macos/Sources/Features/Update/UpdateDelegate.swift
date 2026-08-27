import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            return nil
        }

        // **Polter has no update feed, and must not borrow Ghostty's.**
        //
        // These two URLs serve Ghostty. Sparkle compares versions and
        // installs what it finds, so pointing Polter at them means every
        // Ghostty release looks like an upgrade -- especially now that this
        // build calls itself 0.1.x -- and accepting one would replace Polter
        // with a different program, silently, under `auto-update = download`.
        // The user asked for a terminal that minds their agents and would
        // get one that has never heard of them.
        //
        // Returning nil is Sparkle's way of saying there is nothing to
        // check. When Polter publishes its own appcast this is where its
        // URL goes; until then the honest answer is none.
        _ = appDelegate
        return nil
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            appcastItem: item,
            retryTerminatingApplication: immediateInstallHandler
        ))
        AppDelegate.logger.info("Version: \(item.displayVersionString) installed silently, waiting for relaunch...")
        // Even when hasUnobtrusiveTarget is false, we don't show the alert immediately.
        // We wait until the user manually checks for updates or relaunches.
        return true
    }
}
