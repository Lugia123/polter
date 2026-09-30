import AppKit
import GhosttyKit
import OSLog

/// Where projects are saved, listed, opened, and removed on macOS -- the
/// Swift-side counterpart of `src/Project.zig`'s `write`/`read`/`list`/
/// `delete`. Ported natively here rather than called through a C bridge,
/// matching how `SplitTree.swift` ports the core's split-tree shape rather
/// than binding to it: each apprt owns its own reader/writer for this
/// format, per `Project.zig`'s doc comment.
@MainActor
final class ProjectStore {
    static let shared = ProjectStore()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "projects")

    /// One saved project, as shown in a picker: enough to render a row
    /// without decoding (let alone materializing) its tree.
    ///
    /// Its identity is `url`, the file a listing found it in -- not a
    /// filename recomputed from `name`. A project saved under an older
    /// filename rule still sits under that name, and recomputing would look
    /// for it somewhere else and quietly not find it (issue #23). Opening,
    /// deleting and restoring all go through `url`; only saving uses the
    /// current rule (`ProjectFilename`), and it moves an older file over
    /// when it does (`ProjectFileAdoption`).
    struct Entry: Identifiable, Equatable {
        var id: String { url.path }
        let url: URL
        let name: String
        let savedAt: Date
        let paneCount: Int
        /// Whether a `.prev` generation exists to go back to -- see
        /// `ProjectFileWriter.write`.
        var hasPrevious = false
    }

    enum StoreError: LocalizedError {
        case nameEmpty
        case notFound
        /// Another project, `name`, already has the name (or the file the
        /// name would be saved in).
        case nameTaken(String)
        /// `name` is bound to an open tab, titled `holder`, and the action
        /// would either give it a second writer or change the file under it.
        case boundElsewhere(name: String, holder: String)

        var errorDescription: String? {
            switch self {
            case .nameEmpty:
                return String(localized: "Project name can't be empty.", comment: "项目存储出错：名字为空")
            case .notFound:
                return String(localized: "That project no longer exists.", comment: "项目存储出错：项目已不存在")
            case .nameTaken(let name):
                return String(localized: "There is already a project called \"\(name)\".", comment: "项目存储出错：重名，参数是已有的那个项目名")
            case .boundElsewhere(let name, let holder):
                return String(localized: "\"\(name)\" is open in the tab \"\(holder)\", which saves it automatically. Close that tab first.", comment: "项目存储出错：项目已绑定到另一个 tab，参数依次是项目名、那个 tab 的标题")
            }
        }
    }

    /// Which open tab each project is bound to. One per store, so tests
    /// with their own directory get their own bindings.
    let bindings = ProjectBindingRegistry()

    /// The identity a binding is keyed by: the file the current rule gives
    /// `name`, so names that sanitize to one filename are one project. The
    /// empty name has no file and keys as ""; nothing binds it, because
    /// `save` refuses it before a binding is made.
    func bindingKey(name: String) -> String {
        ruleURL(name: name)?.standardizedFileURL.path ?? ""
    }

    private let directory: URL

    /// Moves a file to the Trash and says where it landed. A test passes one
    /// of its own, so running the tests leaves nothing in the person's Trash.
    private let trashItem: (URL) throws -> URL

    init(directory: URL? = nil, trashItem: @escaping (URL) throws -> URL = ProjectStore.systemTrash) {
        self.trashItem = trashItem
        self.directory = directory ?? Self.defaultDirectory
        try? FileManager.default.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true)
    }

    /// `$XDG_STATE_HOME/polter/projects` (falling back to
    /// `~/.local/state/polter/projects`) -- the generic XDG state
    /// directory `src/os/xdg.zig`'s `state()` resolves with `.subdir =
    /// "polter"`, same as `Plugin.logDirectory`'s `.../polter/plugins`.
    /// Deliberately not `ClosedTabs`'s `sessionURL`: that one is
    /// poltergeist's own session-restore state, a different subsystem that
    /// happens to share the "polter" top directory, not a shared helper
    /// this reuses.
    private static var defaultDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = home
                .appendingPathComponent(".local")
                .appendingPathComponent("state")
        }
        return base
            .appendingPathComponent("polter")
            .appendingPathComponent("projects")
    }

    /// All saved projects, most recently saved first. Reads and decodes
    /// each file (there's no cheaper summary-only path once the format
    /// dropped the AppKit-fused leaf decode -- see `ProjectDocument.swift`)
    /// but never materializes a tree, so listing never spins up a terminal
    /// process.
    func list() -> [Entry] {
        listed()
            .map { makeEntry($0.file, at: $0.url) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    /// Every project file in the directory, decoded; unreadable ones are
    /// skipped and logged (see `ProjectListing.decode` for why skipped).
    private func listed() -> [(url: URL, file: ProjectFile)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)) ?? []
        return ProjectListing.decode(urls.filter { $0.pathExtension == "json" }) { url, error in
            Self.logger.warning(
                "not listing '\(url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The project called `name`, wherever it is saved -- see
    /// `ProjectListing.locate`.
    func entry(name: String) -> Entry? {
        let listed = listed()
        guard let url = ProjectListing.locate(name: name, ruleFile: ruleURL(name: name), listed: listed),
              let file = listed.first(where: { $0.url == url })?.file
        else { return nil }
        return makeEntry(file, at: url)
    }

    private func makeEntry(_ file: ProjectFile, at url: URL) -> Entry {
        Entry(
            url: url,
            name: file.name,
            savedAt: file.savedAtDate,
            paneCount: file.paneCount,
            hasPrevious: FileManager.default.fileExists(atPath: ProjectFileWriter.previousURL(for: url).path))
    }

    /// Save (or overwrite -- see `Entry`) a project under `name`: `tree`'s
    /// current shape, each pane's `cwd`/`title`/`history`, and each pane's
    /// scrollback snapshot name.
    ///
    /// Every pane is given a snapshot number if it has none, and its
    /// scrollback journaled there from now on (`SurfaceView.journalScrollback`):
    /// the core writes what changed, every `project-scrollback-autosave-interval`
    /// and when the pane closes, so a pane's history survives a crash.
    ///
    /// `capturingScrollback` also asks the core to write each pane's whole
    /// snapshot now, flushed. Only an explicit save and the flush when a
    /// bound tab closes do that; autosave, which runs whenever a title
    /// changes, leaves the writing to the journal.
    ///
    /// - Important: When capturing, call this while every pane in `tree` is
    ///   still alive. The snapshots are written asynchronously on each
    ///   surface's IO thread; the core guarantees a capture requested before
    ///   `ghostty_surface_free` has landed by the time that returns, and
    ///   nothing about one requested after.
    @discardableResult
    func save(
        name: String,
        tree: SplitTree<Ghostty.SurfaceView>,
        capturingScrollback: Bool = true
    ) throws -> Entry {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = ruleURL(name: trimmed) else { throw StoreError.nameEmpty }
        try adoptLegacyFile(name: trimmed, as: url)

        let scrollbackDirectory = ProjectScrollback.directory(forProjectFile: url)
        let existing = (try? Data(contentsOf: url)).flatMap { try? ProjectFile.decode(from: $0) }
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: scrollbackDirectory.path)) ?? []
        var allocator = ProjectScrollback.Allocator(
            project: bindingKey(name: trimmed),
            storedNext: existing?.nextScrollback,
            inUse: (existing?.scrollbackFilenames ?? []) + onDisk)

        if tree.root != nil {
            try? FileManager.default.createDirectory(
                at: scrollbackDirectory,
                withIntermediateDirectories: true)
        }

        // A pane's snapshot name is recorded whether or not the capture
        // request was accepted: the name is the pane's for life, and a name
        // whose file never landed reads back as "no scrollback" -- the core
        // starts an empty terminal -- which is today's behavior.
        let root = tree.root.map { node in
            ProjectNode.capturing(node) { view in
                // Every pane gets a number, autosave included: a number is
                // now what keeps a pane's scrollback journaled, and a pane
                // opened after the tab was bound that waited for an explicit
                // save would have nothing on disk when the machine goes
                // down. Handing one out used to mean a full capture; it no
                // longer does -- the journal writes only what changed.
                guard let snapshot = allocator.snapshot(for: view.projectSnapshot, allocate: true) else {
                    return ""
                }
                view.journalScrollback(snapshot, in: scrollbackDirectory)
                if capturingScrollback, let surface = view.surface {
                    let path = scrollbackDirectory.appendingPathComponent(snapshot.filename).path
                    if !ghostty_surface_capture_scrollback(surface, path) {
                        Self.logger.warning("scrollback capture for '\(snapshot.filename, privacy: .public)' was not queued")
                    }
                }
                return snapshot.filename
            }
        }

        let entry = try write(ProjectFile(
            name: trimmed,
            savedAt: Int(Date().timeIntervalSince1970),
            root: root,
            nextScrollback: allocator.next))

        // Kept: exactly the names the saved tree refers to (and their
        // in-flight `.tmp`). A pane closed since the last save leaves a
        // snapshot nothing refers to, and it goes -- here, on every save,
        // not only the capturing ones.
        ProjectScrollback.prune(
            directory: scrollbackDirectory,
            keeping: Set(root?.scrollbackFilenames ?? []))

        return entry
    }

    /// The file-level half of `save`, keeping one previous generation --
    /// see `ProjectFileWriter.write`. Separate so it can be driven without
    /// live surfaces.
    @discardableResult
    func write(_ file: ProjectFile) throws -> Entry {
        guard let url = ruleURL(name: file.name) else { throw StoreError.nameEmpty }
        let outcome = try ProjectFileWriter.write(file, to: url)

        switch outcome {
        case .unchanged:
            Self.logger.debug("project '\(file.name, privacy: .public)' unchanged, not written")
        case .written(let rotated):
            Self.logger.info(
                "saved project '\(file.name, privacy: .public)' with \(file.paneCount, privacy: .public) pane(s), previous kept: \(rotated, privacy: .public)")
        }

        return makeEntry(file, at: url)
    }

    /// Materialize a saved project's tree, ready to hand to
    /// `TerminalController(withSurfaceTree:)`.
    ///
    /// - Important: This is the expensive path -- each leaf spins up a live
    ///   terminal process (see `ProjectNode.materializing`), which is the
    ///   entire point when actually opening a project, so only call this
    ///   then. Use `list()`/`entry(name:)` for anything that just displays
    ///   metadata.
    func loadTree(_ entry: Entry, app: ghostty_app_t) throws -> SplitTree<Ghostty.SurfaceView> {
        guard let data = try? Data(contentsOf: entry.url) else {
            throw StoreError.notFound
        }
        let file = try ProjectFile.decode(from: data)
        // The snapshots sit beside the file they were saved with, which is
        // `entry.url` even when that is an older rule's name.
        let location = ProjectScrollback.Location(
            directory: ProjectScrollback.directory(forProjectFile: entry.url),
            key: bindingKey(name: entry.name))
        let root = file.root.map { $0.materializing(app, scrollback: location) }
        return SplitTree(root: root, zoomed: nil)
    }

    /// Put `name`'s previous generation back, keeping the current one as
    /// the new `.prev` (so this is undone by doing it again).
    ///
    /// Refused while a tab is bound to the project: that tab's layout is
    /// what it would autosave next, so the restored file would be
    /// overwritten by the very layout it was restored to get away from.
    ///
    /// Scrollback isn't versioned (see `dev-docs/project-scrollback.md`
    /// 3.5.6): a pane that exists only in the previous version restores
    /// without its history.
    func restorePrevious(_ entry: Entry) throws {
        try refuseIfBound(name: entry.name)
        try ProjectFileWriter.restorePrevious(at: entry.url)
        Self.logger.info("restored previous version of project '\(entry.name, privacy: .public)'")
    }

    /// The title of the tab bound to `name`, for saying who holds it.
    func holderTitle(name: String) -> String? {
        guard let holder = bindings.owner(of: bindingKey(name: name)) else { return nil }
        return (holder as? ProjectBindingHolder)?.projectBindingTitle ?? ""
    }

    private func refuseIfBound(name: String) throws {
        if let holder = holderTitle(name: name) {
            throw StoreError.boundElsewhere(name: name, holder: holder)
        }
    }

    /// Refused while a tab is bound to the project -- it would write the
    /// project straight back on its next autosave.
    func delete(_ entry: Entry) throws {
        try refuseIfBound(name: entry.name)
        try FileManager.default.removeItem(at: entry.url)
        // The `.prev` and the snapshots mean nothing without the project
        // (unlike `history`, which outlives any one project). Absent is
        // fine: a project saved before either existed has none.
        for sidecar in ProjectFileAdoption.sidecars(of: entry.url) {
            try? FileManager.default.removeItem(at: sidecar)
        }
        Self.logger.info("deleted project '\(entry.name, privacy: .public)'")
    }

    // MARK: - The settings window's operations (settings.md §6.2)

    /// The saved file itself, for what the settings window shows about a
    /// project (its tree, its directories). Nil when it can't be read.
    func document(_ entry: Entry) -> ProjectFile? {
        (try? Data(contentsOf: entry.url)).flatMap { try? ProjectFile.decode(from: $0) }
    }

    /// The versions `entry` can go back to: the current file, and the one
    /// `.prev` keeps when there is one (`ProjectFileWriter`). A `.prev` that
    /// doesn't decode isn't offered: restoring it would give back a project
    /// nothing can open.
    func versions(_ entry: Entry) -> [ProjectsRules.Version] {
        let current = ProjectsRules.Version(isCurrent: true, savedAt: entry.savedAt, paneCount: entry.paneCount)
        let previous = (try? Data(contentsOf: ProjectFileWriter.previousURL(for: entry.url)))
            .flatMap { try? ProjectFile.decode(from: $0) }
            .map { ProjectsRules.Version(isCurrent: false, savedAt: $0.savedAtDate, paneCount: $0.paneCount) }
        return ProjectsRules.versions(current: current, previous: previous)
    }

    /// Bytes the project's scrollback snapshots take on disk.
    func scrollbackBytes(_ entry: Entry) -> Int64 {
        let dir = ProjectScrollback.directory(forProjectFile: entry.url)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.reduce(Int64(0)) { sum, name in
            let size = (try? FileManager.default.attributesOfItem(
                atPath: dir.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value ?? 0
            return sum + size
        }
    }

    /// Whether `proposed` can name the project called `current` -- see
    /// `ProjectsRules.renameVerdict`. `current` nil asks for a new project.
    func nameVerdict(current: String?, proposed: String) -> ProjectsRules.NameVerdict {
        let others = listed()
            .filter { $0.file.name != current }
            .map { (name: $0.file.name, filename: $0.url.lastPathComponent) }
        return ProjectsRules.renameVerdict(
            current: current ?? "",
            proposed: proposed,
            others: others,
            ruleFilename: ProjectFilename.forNewFile(named: proposed.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Rename `entry` to `newName`, with its `.prev` and its snapshots. A
    /// name another project has -- or one saved under the same file -- is
    /// refused. A tab bound to the project stays bound, under the new name
    /// (settings.md §6.2); it is told through `ProjectMoveFollower`.
    ///
    /// Every part goes through a temporary name first, so that a rename
    /// that only changes case (one file, on a case-insensitive disk) moves
    /// the file rather than deleting it.
    @discardableResult
    func rename(_ entry: Entry, to newName: String) throws -> Entry {
        let name: String
        switch nameVerdict(current: entry.name, proposed: newName) {
        case .unchanged: return entry
        case .empty: throw StoreError.nameEmpty
        case .taken(let other): throw StoreError.nameTaken(other)
        case .ok(let ok): name = ok
        }
        guard let target = ruleURL(name: name) else { throw StoreError.nameEmpty }
        guard let data = try? Data(contentsOf: entry.url) else { throw StoreError.notFound }
        let file = try ProjectFile.decode(from: data)

        let oldKey = bindingKey(name: entry.name)
        let newKey = bindingKey(name: name)
        let follower = bindings.owner(of: oldKey) as? ProjectMoveFollower
        follower?.projectWillMove()

        let fm = FileManager.default
        let parked = try park(entry.url)
        do {
            try ProjectFile(name: name, savedAt: file.savedAt, root: file.root, nextScrollback: file.nextScrollback)
                .encoded().write(to: target, options: .atomic)
        } catch {
            try? fm.moveItem(at: parked, to: entry.url)
            follower?.projectDidMove(to: entry.name, oldKey: oldKey, key: oldKey,
                                     scrollback: ProjectScrollback.directory(forProjectFile: entry.url))
            throw error
        }
        try? fm.removeItem(at: parked)

        for (from, to) in zip(ProjectFileAdoption.sidecars(of: entry.url), ProjectFileAdoption.sidecars(of: target))
        where fm.fileExists(atPath: from.path) {
            do {
                try fm.moveItem(at: try park(from), to: to)
            } catch {
                Self.logger.warning("renaming project '\(entry.name, privacy: .public)': '\(from.lastPathComponent, privacy: .public)' not moved: \(error.localizedDescription, privacy: .public)")
            }
        }
        // The `.prev` says who it is too; left alone, restoring it would
        // put the old name back.
        let prev = ProjectFileWriter.previousURL(for: target)
        if let old = (try? Data(contentsOf: prev)).flatMap({ try? ProjectFile.decode(from: $0) }) {
            try? ProjectFile(name: name, savedAt: old.savedAt, root: old.root, nextScrollback: old.nextScrollback)
                .encoded().write(to: prev, options: .atomic)
        }

        bindings.move(oldKey, to: newKey)
        follower?.projectDidMove(to: name, oldKey: oldKey, key: newKey,
                                 scrollback: ProjectScrollback.directory(forProjectFile: target))
        Self.logger.info("renamed project '\(entry.name, privacy: .public)' to '\(name, privacy: .public)'")
        return makeEntry(ProjectFile(name: name, savedAt: file.savedAt, root: file.root, nextScrollback: file.nextScrollback), at: target)
    }

    /// Move `url` to a hidden name beside it, and return that name.
    private func park(_ url: URL) throws -> URL {
        let parked = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).moving")
        try FileManager.default.moveItem(at: url, to: parked)
        return parked
    }

    /// A copy of `entry` under the first free "<name> Copy" name, with its
    /// snapshots (so the copy opens with the same scrollback) but not its
    /// `.prev`: a copy starts its own history. Saved now, so it lists at
    /// the top.
    @discardableResult
    func duplicate(_ entry: Entry) throws -> Entry {
        guard let file = document(entry) else { throw StoreError.notFound }
        let name = ProjectsRules.copyName(of: entry.name) { candidate in
            if case .ok = nameVerdict(current: nil, proposed: candidate) { return false }
            return true
        }
        guard let target = ruleURL(name: name) else { throw StoreError.nameEmpty }
        let copy = ProjectFile(
            name: name,
            savedAt: Int(Date().timeIntervalSince1970),
            root: file.root,
            nextScrollback: file.nextScrollback)
        let snapshots = ProjectScrollback.directory(forProjectFile: entry.url)
        if FileManager.default.fileExists(atPath: snapshots.path) {
            try FileManager.default.copyItem(at: snapshots, to: ProjectScrollback.directory(forProjectFile: target))
        }
        try copy.encoded().write(to: target, options: .atomic)
        Self.logger.info("copied project '\(entry.name, privacy: .public)' to '\(name, privacy: .public)'")
        return makeEntry(copy, at: target)
    }

    /// A project `trash` moved to the Trash: where each of its parts was
    /// and where it went, which is what `untrash` needs to put it back.
    struct Trashed: Equatable {
        struct Move: Equatable {
            let from: URL
            let to: URL
        }

        let name: String
        let moves: [Move]
    }

    /// Delete `entry` so that it can be undone (settings.md §6.2): the file,
    /// its `.prev` and its snapshots go to the Trash. Refused while a tab is
    /// bound to the project, like `delete`.
    func trash(_ entry: Entry) throws -> Trashed {
        try refuseIfBound(name: entry.name)
        // The file first: once it is gone the project is gone from every
        // list, and a sidecar that then fails to move is only an orphan.
        var moves = [Trashed.Move(from: entry.url, to: try trashItem(entry.url))]
        for sidecar in ProjectFileAdoption.sidecars(of: entry.url)
        where FileManager.default.fileExists(atPath: sidecar.path) {
            do {
                moves.append(.init(from: sidecar, to: try trashItem(sidecar)))
            } catch {
                Self.logger.warning("deleting project '\(entry.name, privacy: .public)': '\(sidecar.lastPathComponent, privacy: .public)' not moved to the Trash: \(error.localizedDescription, privacy: .public)")
            }
        }
        Self.logger.info("moved project '\(entry.name, privacy: .public)' to the Trash")
        return Trashed(name: entry.name, moves: moves)
    }

    /// Put back what `trash` moved. Refused, touching nothing, if the
    /// project's file has been taken since -- a project saved under the same
    /// name in the meantime is not overwritten.
    func untrash(_ trashed: Trashed) throws {
        let fm = FileManager.default
        if let file = trashed.moves.first, fm.fileExists(atPath: file.from.path) {
            throw StoreError.nameTaken(trashed.name)
        }
        guard trashed.moves.allSatisfy({ fm.fileExists(atPath: $0.to.path) }) else {
            throw StoreError.notFound
        }
        // Sidecars first, the file last, as `ProjectFileAdoption` does: until
        // the file is back nothing lists the project.
        for move in trashed.moves.reversed() where !fm.fileExists(atPath: move.from.path) {
            try fm.moveItem(at: move.to, to: move.from)
        }
        Self.logger.info("put project '\(trashed.name, privacy: .public)' back from the Trash")
    }

    nonisolated static func systemTrash(_ url: URL) throws -> URL {
        var landed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
        guard let landed else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]) }
        return landed as URL
    }

    /// Before saving `name` to `target`: if the project is still in a file
    /// an older filename rule named, move it (and its `.prev` and
    /// snapshots) to `target` first, so this save carries on from it --
    /// its layout becomes `.prev` if the layout changed, its snapshot
    /// numbers stay allocated -- instead of starting a second copy beside
    /// it.
    private func adoptLegacyFile(name: String, as target: URL) throws {
        guard let found = ProjectListing.locate(name: name, ruleFile: target, listed: listed()),
              found.lastPathComponent != target.lastPathComponent
        else { return }
        switch try ProjectFileAdoption.adopt(found, as: target) {
        case .adopted:
            Self.logger.info(
                "moved project '\(name, privacy: .public)' from '\(found.lastPathComponent, privacy: .public)' to '\(target.lastPathComponent, privacy: .public)'")
        case .targetTaken:
            // The rule's file exists but didn't list (it doesn't decode).
            // Not overwritten: it may be somebody's project in a form this
            // build can't read. The save that follows rotates it into
            // `.prev` (`ProjectFileWriter` keeps undecodable files).
            Self.logger.warning(
                "not moving project '\(name, privacy: .public)' from '\(found.lastPathComponent, privacy: .public)': '\(target.lastPathComponent, privacy: .public)' exists")
        }
    }

    /// The file the current rule gives a *new* project called `name`, or
    /// nil for the empty name -- see `ProjectFilename`. Never used to find
    /// an existing project; that is `entry(name:)`.
    private func ruleURL(name: String) -> URL? {
        ProjectFilename.forNewFile(named: name).map { directory.appendingPathComponent($0) }
    }
}
