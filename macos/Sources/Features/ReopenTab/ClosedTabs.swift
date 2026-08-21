import AppKit
import Foundation
import OSLog

/// Terminals that can be opened again, most recently closed first.
///
/// Two things people expect, served by one stack because a browser taught
/// everybody they are the same key: reopening a tab you closed by mistake,
/// and getting last session's tabs back after a restart.
///
/// The stack is primed at launch from what Polter wrote down as it went
/// (`session.json`), and pushed to as terminals close. So `⌘⇧T` walks back
/// through this run's closures and then keeps going into the previous
/// session, which is the order somebody pressing it repeatedly means.
@MainActor
final class ClosedTabs {
    static let shared = ClosedTabs()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "reopen-tab")

    /// One terminal worth reopening.
    struct Entry {
        let directory: String
        let title: String
    }

    /// Bounded: this is an undo stack for closing things, not a history.
    /// Twenty is more than anybody reaches for and keeps the menu honest.
    private static let limit = 20

    private var stack: [Entry] = []
    private var primed = false

    var canReopen: Bool {
        primeIfNeeded()
        return !stack.isEmpty
    }

    /// The directory of the next terminal to reopen, if there is one.
    var nextDirectory: String? {
        primeIfNeeded()
        return stack.last?.directory
    }

    /// Remember a terminal that just closed.
    func remember(directory: String?) {
        guard let directory, !directory.isEmpty else { return }

        // Priming first, so a terminal closed early in the session lands on
        // top of last session's rather than under it.
        primeIfNeeded()

        stack.append(.init(directory: directory, title: ""))
        if stack.count > Self.limit { stack.removeFirst() }
    }

    /// Take the next one to reopen.
    func take() -> Entry? {
        primeIfNeeded()
        return stack.popLast()
    }

    // MARK: Last session

    /// Fill the stack from what the previous run left behind, once.
    ///
    /// Read lazily rather than at launch: most sessions never press this,
    /// and a file read on the way to a menu that is about to be drawn is
    /// cheaper than one on every start.
    private func primeIfNeeded() {
        guard !primed else { return }
        primed = true

        guard let url = Self.sessionURL,
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let terminals = root["terminals"] as? [[String: Any]]
        else { return }

        for terminal in terminals {
            guard let directory = terminal["cwd"] as? String,
                  !directory.isEmpty
            else { continue }

            // Only somewhere that still exists. A directory deleted since
            // last night would open a tab that immediately fails, which
            // reads as the feature being broken rather than the folder
            // being gone.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: directory,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else { continue }

            stack.append(.init(
                directory: directory,
                title: (terminal["title"] as? String) ?? ""))
        }

        Self.logger.info("primed with \(self.stack.count) terminal(s) from last session")
    }

    /// `$XDG_STATE_HOME/polter/session.json`, where the core writes the
    /// arrangement as it goes.
    private static var sessionURL: URL? {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_STATE_HOME"],
           !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local")
                .appendingPathComponent("state")
        }

        return base
            .appendingPathComponent("polter")
            .appendingPathComponent("session.json")
    }
}
