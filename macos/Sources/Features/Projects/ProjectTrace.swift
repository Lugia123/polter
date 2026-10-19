import AppKit
import OSLog

/// What a tab's project binding and its panes' snapshots were at the moments
/// that decide whether it comes back in its project (task 1784).
///
/// A project tab that ran vim came back from system window restoration as an
/// empty shell in no project, and nothing in the log said why: the state it
/// was restored from no longer existed by the time anyone looked. These
/// lines are what would have answered it -- what was encoded for each window
/// at quit, what was decoded for it at launch, what the binding did with it,
/// who attached and detached the tab, and which snapshot files a save
/// removed. They are few (one per window per encode, one per save that
/// removes something) and stay in, in the `projects` category.
///
/// A pane is named by the first eight characters of its id, and a project by
/// its name only -- never a path.
enum ProjectTrace {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "projects")

    /// `a1b2c3d4=3.snap@shop-web` for each pane, `a1b2c3d4=-` for one with
    /// no snapshot. The snapshot's project is its key, the project file's
    /// path; only the file's name is shown.
    static func panes(_ tree: SplitTree<Ghostty.SurfaceView>) -> String {
        let parts = tree.map { view -> String in
            let id = String(view.id.uuidString.prefix(8))
            guard let snapshot = view.projectSnapshot else { return "\(id)=-" }
            let project = URL(fileURLWithPath: snapshot.project).deletingPathExtension().lastPathComponent
            return "\(id)=\(snapshot.filename)@\(project)"
        }
        return parts.isEmpty ? "(none)" : parts.joined(separator: " ")
    }

    /// The window's state was encoded for restoration.
    static func encoded(_ controller: TerminalController) {
        logger.notice("window state encoded: window=\(controller.window?.windowNumber ?? -1, privacy: .public) project=\(controller.boundProject ?? "(none)", privacy: .public) panes=\(panes(controller.surfaceTree), privacy: .public)")
    }

    /// A window was decoded from restoration state, before its binding is
    /// put back.
    static func decoded(_ controller: TerminalController, boundProject: String?) {
        logger.notice("window state decoded: project=\(boundProject ?? "(none)", privacy: .public) panes=\(panes(controller.surfaceTree), privacy: .public)")
    }

    /// A tab joined or left a project; `caller` is the function that asked.
    static func membership(_ what: String, _ controller: TerminalController, project: String, page: Int?, caller: String) {
        logger.notice("tab \(what, privacy: .public): project=\(project, privacy: .public) page=\(page.map(String.init) ?? "-", privacy: .public) window=\(controller.window?.windowNumber ?? -1, privacy: .public) by=\(caller, privacy: .public)")
    }

    /// A pane was marked as the project's supervisor's (task 1794): which
    /// one, and who asked. The mark is what "go on with the last session"
    /// types into; when it is missing, this line's absence says it was
    /// never written.
    static func seated(_ view: Ghostty.SurfaceView, project: String, caller: String) {
        let id = String(view.id.uuidString.prefix(8))
        logger.notice("supervisor's pane marked: project=\(project, privacy: .public) pane=\(id, privacy: .public)=\(view.projectSnapshot?.filename ?? "-", privacy: .public) by=\(caller, privacy: .public)")
    }

    /// A save removed files from the project's snapshot directory.
    static func pruned(project: String, removed: [String], kept: Int, wholeDirectory: Bool) {
        if wholeDirectory {
            logger.notice("save removed the snapshot directory of project=\(project, privacy: .public): nothing in it is referred to")
        } else if !removed.isEmpty {
            logger.notice("save removed \(removed.count, privacy: .public) snapshot file(s) of project=\(project, privacy: .public), keeping \(kept, privacy: .public): \(removed.sorted().joined(separator: " "), privacy: .public)")
        }
    }
}
