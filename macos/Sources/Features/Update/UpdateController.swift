import Sparkle
import Cocoa
import Combine
import SwiftUI

/// Standard controller for managing Sparkle updates in Ghostty.
///
/// This controller wraps SPUStandardUpdaterController to provide a simpler interface
/// for managing updates with Ghostty's custom driver and delegate. It handles
/// initialization, starting the updater, and provides the check for updates action.
class UpdateController {
    private(set) var updater: SPUUpdater
    private let userDriver: UpdateDriver

    var viewModel: UpdateViewModel {
        userDriver.viewModel
    }

    /// True if we're installing an update triggered manually.
    var shouldTerminateWithoutWarning: Bool {
        viewModel.state.shouldTerminateWithoutWarning
    }

    /// Initialize a new update controller.
    init() {
        let hostBundle = Bundle.main
        self.userDriver = UpdateDriver(
            viewModel: .init(),
            hostBundle: hostBundle)
        self.updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: userDriver,
            delegate: userDriver
        )
    }

    /// Start the updater.
    ///
    /// This must be called before the updater can check for updates. If starting fails,
    /// the error will be shown to the user.
    func startUpdater() {
        do {
            try updater.start()
        } catch {
            userDriver.viewModel.state = .error(.init(
                error: error,
                retry: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                    self?.startUpdater()
                },
                dismiss: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                }
            ))
        }
    }

    /// Check for updates.
    ///
    /// This is typically connected to a menu item action.
    ///
    /// **Task 649: this checks GitHub, not Sparkle.** `updater.checkForUpdates()`
    /// would ask Sparkle to fetch `feedURLString`, which `UpdateDelegate`
    /// returns `nil` for on purpose (see the comment there) -- Polter has no
    /// appcast to serve. So checking here never touches `updater` at all;
    /// `startUpdater()` above still runs it for the auto-update machinery
    /// that state carries (`willInstallUpdateOnQuit` etc.), untouched by
    /// this change and just as inert as before, since a `nil` feed means
    /// Sparkle never finds anything on its own either.
    func checkForUpdates() {
        // If we're already idle, then just check for updates immediately.
        if viewModel.state == .idle {
            beginGitHubCheck()
            return
        }

        if case let .installing(installing) = viewModel.state {
            // If the update is already installed, we can't actually
            // cancel it, and SPUUpdater.checkForUpdates will simply fail,
            // so we just show an alert to remind the user to restart.
            let alert = NSAlert()
            alert.alertStyle = .informational
            let accessoryView = NSHostingView(
                rootView: InstallingAccessoryView(installing: installing)
                    .frame(width: 228, alignment: .leading)
            )
            accessoryView.frame = .init(origin: .zero, size: accessoryView.fittingSize)
            alert.accessoryView = accessoryView
            alert.addButton(withTitle: String(localized: "Restart Now", comment: "更新流程的系统提醒框"))
            alert.addButton(withTitle: String(localized: "Restart Later", comment: "更新流程的系统提醒框"))
                .keyEquivalent = .init([KeyboardShortcut(.escape).key.character])
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                viewModel.state.confirm()
            default:
                break
            }
            return
        }

        // If we're not idle then we need to cancel any prior state.
        viewModel.state.cancel()

        // The above will take time to settle, so we delay the check for some time.
        // The 100ms is arbitrary and I'd rather not, but we have to wait more than
        // one loop tick it seems.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.beginGitHubCheck()
        }
    }

    /// Starts (and can be cancelled out from under) a GitHub releases check.
    ///
    /// The task is built unresumed so `UpdateState.Checking.cancel` can
    /// actually cancel the request in flight rather than merely ignoring its
    /// result -- a dismissed check should not go on spending one of GitHub's
    /// 60 anonymous requests per hour in the background.
    private func beginGitHubCheck() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        // **Checked before anything else, and before any request goes out.**
        // Task 651: a build not cut from a tag or a `feature/vX.Y` branch
        // reports `CFBundleShortVersionString` as `0.1.<commit count>` --
        // indistinguishable, by the numbers alone, from a real `0.1.x`
        // release. Comparing that guess against GitHub's latest tag would
        // almost always say "update available", because a fallback build is
        // normally a dev checkout ahead of the last release, not behind it --
        // which is an update prompt asking the person to downgrade. See
        // `GitHubUpdateChecker.CheckError.versionUnknown`'s doc comment.
        let versionSource = Bundle.main.infoDictionary?["PolterVersionSource"] as? String
        if GitHubUpdateChecker.currentVersionIsAGuess(source: versionSource) {
            GitHubUpdateChecker.logVersionIsAGuess(currentVersion: currentVersion)
            viewModel.state = .error(.init(
                error: GitHubUpdateChecker.CheckError.versionUnknown,
                retry: { [weak self] in
                    self?.viewModel.state = .idle
                    self?.beginGitHubCheck()
                },
                dismiss: { [weak self] in self?.viewModel.state = .idle }
            ))
            return
        }

        let task = GitHubUpdateChecker.makeCheckTask(currentVersion: currentVersion) { [weak self] result in
            guard let self else { return }
            // A cancellation already moved the state off `.checking`; a
            // result that arrives after that must not clobber wherever the
            // user sent it instead.
            guard case .checking = self.viewModel.state else { return }

            switch result {
            case .success(let update):
                if let update {
                    self.viewModel.state = .gitHubUpdateAvailable(.init(
                        version: update.version,
                        htmlURL: update.htmlURL,
                        publishedAt: update.publishedAt,
                        dismiss: { [weak self] in self?.viewModel.state = .idle }
                    ))
                } else {
                    self.viewModel.state = .notFound(.init(acknowledgement: { [weak self] in
                        self?.viewModel.state = .idle
                    }))
                }
            case .failure(let error):
                self.viewModel.state = .error(.init(
                    error: error,
                    retry: { [weak self] in
                        self?.viewModel.state = .idle
                        self?.beginGitHubCheck()
                    },
                    dismiss: { [weak self] in self?.viewModel.state = .idle }
                ))
            }
        }

        viewModel.state = .checking(.init(cancel: { [weak self] in
            task.cancel()
            self?.viewModel.state = .idle
        }))
        task.resume()
    }
}

private struct InstallingAccessoryView: View {
    let installing: UpdateState.Installing

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Restart Required", comment: "更新流程的系统提醒框"))
                    .font(.system(size: 13, weight: .semibold))

                Text(String(localized: "The update is ready. Please restart the application to complete the installation.", comment: "更新流程的系统提醒框"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let item = installing.appcastItem, let releaseNotesURL = installing.releaseNotes?.url {
                    VStack(alignment: .leading, spacing: 4) {
                        Link(destination: releaseNotesURL) {
                            HStack(spacing: 6) {
                                Text(String(localized: "Version:", comment: "更新流程的系统提醒框"))
                                    .foregroundColor(.secondary)
                                    .frame(width: 60, alignment: .trailing)
                                Text(item.displayVersionString)
                            }
                            .font(.system(size: 11))
                        }

                        if let date = item.date {
                            HStack(spacing: 6) {
                                Text(String(localized: "Released:", comment: "更新流程的系统提醒框"))
                                    .foregroundColor(.secondary)
                                    .frame(width: 60, alignment: .trailing)
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                            }
                            .font(.system(size: 11))
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }
}
