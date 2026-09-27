import Foundation
import GhosttyKit
import OSLog

extension ProjectScrollback {
    /// A pane's snapshot in a project, **as a pane whose scrollback is being
    /// journaled there.** The only way to make one is `Journal.start`, which
    /// is where the core is asked to keep the journal -- so a pane cannot be
    /// given a snapshot name without that request being made.
    ///
    /// The core keeps a pane's scrollback on disk as it runs
    /// (`ghostty_surface_set_scrollback_journal`, `src/termio/scrollback_journal.zig`),
    /// which is what survives a forced restart or a power cut. The function
    /// is useless unless a host calls it, and a call that a later change
    /// quietly drops leaves every test green: the snapshot name would still
    /// be written into the project file, and nothing would ever be written
    /// to it. Tying the name to the request is what keeps that from
    /// happening without a compile error.
    struct Journaled: Equatable {
        let snapshot: PaneSnapshot

        /// Only `Journal.start` makes these.
        fileprivate init(_ snapshot: PaneSnapshot) {
            self.snapshot = snapshot
        }
    }

    enum Journal {
        private static let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
            category: "projects")

        /// The call into the core, replaceable so a test can see what was
        /// asked of it. A nil path stops the journal.
        ///
        /// ⚠️ `true` only means the request was queued. The core logs
        /// "scrollback journal active path=..." when the journal is first
        /// really written; nothing before that line is evidence that it
        /// works (see `ghostty.h`).
        static var request: (ghostty_surface_t, String?) -> Bool = { surface, path in
            guard let path else { return ghostty_surface_set_scrollback_journal(surface, nil) }
            return path.withCString { ghostty_surface_set_scrollback_journal(surface, $0) }
        }

        /// Keep `surface`'s scrollback journaled at `snapshot` in `directory`,
        /// and hand back the pane's snapshot name as one that is.
        ///
        /// A pane with no surface still gets its name -- the name is the
        /// pane's for life -- but there is nothing to journal.
        static func start(
            on surface: ghostty_surface_t?,
            snapshot: PaneSnapshot,
            in directory: URL
        ) -> Journaled {
            if let surface {
                let path = directory.appendingPathComponent(snapshot.filename).path
                if !request(surface, path) {
                    logger.warning(
                        "scrollback journal for '\(snapshot.filename, privacy: .public)' was not queued: this pane's scrollback is not being saved")
                }
            }
            return Journaled(snapshot)
        }

        /// Stop journaling `surface`. The pane keeps its snapshot name; its
        /// file stays where it is, for the project.
        static func stop(on surface: ghostty_surface_t?) {
            guard let surface else { return }
            _ = request(surface, nil)
        }
    }
}
