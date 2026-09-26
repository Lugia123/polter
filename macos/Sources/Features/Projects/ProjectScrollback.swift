import Foundation

/// Where a project's per-pane scrollback snapshots live on disk, and the
/// only filenames a project file is allowed to point at. See
/// `dev-docs/project-scrollback.md` (4.5) for the layout this implements:
/// `<projects>/<project file stem>.scrollback/<n>.snap`.
///
/// Foundation-only on purpose, so the rules below can be exercised without
/// a live `ghostty_app_t`.
enum ProjectScrollback {
    /// The snapshot directory for the project saved at `projectFile`.
    ///
    /// Derived from the project file's own URL rather than by sanitizing
    /// the project name a second time: save and load both reach this
    /// through `ProjectStore.fileURL`, so there is exactly one sanitizer
    /// between the name and the directory, and the two can't disagree about
    /// where the snapshots are.
    static func directory(forProjectFile projectFile: URL) -> URL {
        projectFile.deletingPathExtension().appendingPathExtension("scrollback")
    }

    /// The name snapshot number `number` is written under, as stored in a
    /// leaf's `scrollback` field.
    static func filename(number: Int) -> String {
        "\(number).snap"
    }

    /// The number in a name `filename(number:)` produced, or nil.
    static func number(of name: String) -> Int? {
        guard isSnapshotFilename(name) else { return nil }
        return Int(name.dropLast(".snap".count))
    }

    /// Whether `name` is something `filename(number:)` could have
    /// produced. A project file is read as untrusted data, and the core
    /// **deletes** a snapshot it can't decode -- so a `scrollback` of
    /// `../../something` would be a way to have an arbitrary file deleted
    /// by opening a project. Only plain `<digits>.snap` is ever resolved.
    static func isSnapshotFilename(_ name: String) -> Bool {
        guard name.hasSuffix(".snap") else { return false }
        let stem = name.dropLast(".snap".count)
        return !stem.isEmpty && stem.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Where a project's snapshots live, and the identity a pane's
    /// `PaneSnapshot` is scoped to (`ProjectStore.bindingKey`).
    struct Location {
        let directory: URL
        let key: String
    }

    /// The snapshot a pane writes to, and in which project. Scoped to the
    /// project because numbers are handed out per project: a pane saved
    /// into two projects has a number in each, and they needn't agree.
    struct PaneSnapshot: Equatable {
        let project: String
        let filename: String
    }

    /// Hands out snapshot names that belong to a *pane*, not to a position.
    ///
    /// A number is given to a pane the first time it is captured and stays
    /// with it for life. Numbering by position in the tree instead would be
    /// right for a one-off export and silently wrong for autosave: swap two
    /// panes and each would restore the other's history -- which looks like
    /// success. And a number is never given out twice, even after its pane
    /// has closed, or a new pane would restore the old one's history.
    struct Allocator {
        let project: String
        private(set) var next: Int

        /// `storedNext` is the project file's counter; `inUse` is every
        /// snapshot name already on disk or in the file. The counter starts
        /// past all of them, so a file that lost its counter (written by
        /// another port, or by hand) still can't hand out a used number.
        init(project: String, storedNext: Int?, inUse: [String]) {
            self.project = project
            let highest = inUse.compactMap(ProjectScrollback.number(of:)).max() ?? -1
            self.next = max(storedNext ?? 0, highest + 1)
        }

        /// The pane's snapshot in this project: the one it already has, or,
        /// when `allocate` is set, a new one. Nil for a pane that has none
        /// and isn't being given one.
        mutating func snapshot(for current: PaneSnapshot?, allocate: Bool) -> PaneSnapshot? {
            if let current, current.project == project, let number = ProjectScrollback.number(of: current.filename) {
                next = max(next, number + 1)
                return current
            }
            guard allocate else { return nil }
            defer { next += 1 }
            return PaneSnapshot(project: project, filename: ProjectScrollback.filename(number: next))
        }
    }

    /// Remove everything in `directory` that this save did not write.
    ///
    /// `written` is every snapshot name the saved tree refers to.
    ///
    /// The filter is "what this save actually wrote", not a name pattern:
    /// a pane that existed last time and is gone now leaves a `<n>.snap`
    /// that matches every pattern and must still go. `<name>.tmp` is kept
    /// alongside each kept `<name>` because the core writes the snapshot
    /// there first and renames it into place asynchronously -- by the time
    /// this runs, that write may not have happened yet.
    ///
    /// With nothing kept, the directory itself is removed.
    static func prune(directory: URL, keeping written: Set<String>) {
        let fm = FileManager.default
        guard !written.isEmpty else {
            try? fm.removeItem(at: directory)
            return
        }

        let keep = written.union(written.map { "\($0).tmp" })
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where !keep.contains(name) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
