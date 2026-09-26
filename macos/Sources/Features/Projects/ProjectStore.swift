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
    /// `name` doubles as identity -- saving under a name that already
    /// exists overwrites that file, the same trade `Project.zig`'s
    /// `pathFor` documents ("two names that sanitize to the same filename
    /// collide -- last write wins"). This store doesn't invent a second,
    /// stable identifier the user never sees either.
    struct Entry: Identifiable, Equatable {
        var id: String { name }
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
        /// `name` is bound to an open tab, titled `holder`, and the action
        /// would either give it a second writer or change the file under it.
        case boundElsewhere(name: String, holder: String)

        var errorDescription: String? {
            switch self {
            case .nameEmpty:
                return String(localized: "Project name can't be empty.", comment: "项目存储出错：名字为空")
            case .notFound:
                return String(localized: "That project no longer exists.", comment: "项目存储出错：项目已不存在")
            case .boundElsewhere(let name, let holder):
                return String(localized: "\"\(name)\" is open in the tab \"\(holder)\", which saves it automatically. Close that tab first.", comment: "项目存储出错：项目已绑定到另一个 tab，参数依次是项目名、那个 tab 的标题")
            }
        }
    }

    /// Which open tab each project is bound to. One per store, so tests
    /// with their own directory get their own bindings.
    let bindings = ProjectBindingRegistry()

    /// The identity a binding is keyed by: the project's file, so names
    /// that sanitize to one filename are one project.
    func bindingKey(name: String) -> String {
        fileURL(name: name).standardizedFileURL.path
    }

    private let directory: URL

    init(directory: URL? = nil) {
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
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)) ?? []

        let decoded = ProjectListing.decode(urls.filter { $0.pathExtension == "json" }) { url, error in
            Self.logger.warning(
                "not listing '\(url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
        let entries = decoded.map { makeEntry($0.file, at: $0.url) }

        return entries.sorted { $0.savedAt > $1.savedAt }
    }

    func entry(name: String) -> Entry? {
        let url = fileURL(name: name)
        guard let data = try? Data(contentsOf: url),
              let file = try? ProjectFile.decode(from: data)
        else { return nil }
        return makeEntry(file, at: url)
    }

    private func makeEntry(_ file: ProjectFile, at url: URL) -> Entry {
        Entry(
            name: file.name,
            savedAt: file.savedAtDate,
            paneCount: file.paneCount,
            hasPrevious: FileManager.default.fileExists(atPath: ProjectFileWriter.previousURL(for: url).path))
    }

    /// Save (or overwrite -- see `Entry`) a project under `name`: `tree`'s
    /// current shape, each pane's `cwd`/`title`/`history`, and each pane's
    /// scrollback snapshot name.
    ///
    /// `capturingScrollback` is whether to also ask the core to write each
    /// pane's snapshot, handing a pane that has none a new number. Only an
    /// explicit save and the flush when a bound tab closes do that: a full
    /// snapshot is up to `project-scrollback-limit-bytes` per pane, and
    /// autosave runs whenever a title changes. Autosave writes the layout
    /// and carries each pane's existing snapshot name over unchanged.
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
        guard !trimmed.isEmpty else { throw StoreError.nameEmpty }

        let url = fileURL(name: trimmed)
        let scrollbackDirectory = ProjectScrollback.directory(forProjectFile: url)
        let existing = (try? Data(contentsOf: url)).flatMap { try? ProjectFile.decode(from: $0) }
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: scrollbackDirectory.path)) ?? []
        var allocator = ProjectScrollback.Allocator(
            project: bindingKey(name: trimmed),
            storedNext: existing?.nextScrollback,
            inUse: (existing?.scrollbackFilenames ?? []) + onDisk)

        if capturingScrollback && tree.root != nil {
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
                guard let snapshot = allocator.snapshot(for: view.projectSnapshot, allocate: capturingScrollback) else {
                    return ""
                }
                view.projectSnapshot = snapshot
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
        let url = fileURL(name: file.name)
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
    func loadTree(name: String, app: ghostty_app_t) throws -> SplitTree<Ghostty.SurfaceView> {
        let url = fileURL(name: name)
        guard let data = try? Data(contentsOf: url) else {
            throw StoreError.notFound
        }
        let file = try ProjectFile.decode(from: data)
        let location = ProjectScrollback.Location(
            directory: ProjectScrollback.directory(forProjectFile: url),
            key: bindingKey(name: name))
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
    func restorePrevious(name: String) throws {
        try refuseIfBound(name: name)
        try ProjectFileWriter.restorePrevious(at: fileURL(name: name))
        Self.logger.info("restored previous version of project '\(name, privacy: .public)'")
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
    func delete(name: String) throws {
        try refuseIfBound(name: name)
        let url = fileURL(name: name)
        try FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: ProjectFileWriter.previousURL(for: url))
        // Snapshots mean nothing without the project that captured them
        // (unlike `history`, which outlives any one project). Absent is
        // fine: a project saved before scrollback existed has none.
        try? FileManager.default.removeItem(at: ProjectScrollback.directory(forProjectFile: url))
        Self.logger.info("deleted project '\(name, privacy: .public)'")
    }

    /// Mirrors `Project.zig`'s `sanitizeFilename`: control bytes, `/`, and
    /// `\` become `_`; an empty result falls back to `"project"`; the
    /// result is capped in length before the `.json` extension is
    /// appended. Capped by `Character` rather than by UTF-8 byte count --
    /// the Zig side caps raw bytes and can in principle split a multi-byte
    /// sequence, which isn't a boundary worth reproducing here since a
    /// project name only has to collide-or-not the same way across
    /// platforms, not produce byte-identical filenames.
    private static func sanitizedFilename(for name: String) -> String {
        var sanitized = ""
        for scalar in name.unicodeScalars {
            let v = scalar.value
            // Control bytes (incl. NUL), DEL, and the two path separators --
            // same set `Project.zig`'s `sanitizeFilename` replaces.
            let isUnsafe = v <= 0x1f || v == 0x7f || v == 0x2f /* / */ || v == 0x5c /* \ */
            sanitized.unicodeScalars.append(isUnsafe ? "_" : scalar)
        }

        let capped = String(sanitized.prefix(200))
        return capped.isEmpty ? "project" : capped
    }

    private func fileURL(name: String) -> URL {
        directory.appendingPathComponent(Self.sanitizedFilename(for: name)).appendingPathExtension("json")
    }
}
