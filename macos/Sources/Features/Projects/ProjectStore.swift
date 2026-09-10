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
    }

    enum StoreError: LocalizedError {
        case nameEmpty
        case notFound

        var errorDescription: String? {
            switch self {
            case .nameEmpty:
                return String(localized: "Project name can't be empty.", comment: "项目存储出错：名字为空")
            case .notFound:
                return String(localized: "That project no longer exists.", comment: "项目存储出错：项目已不存在")
            }
        }
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

        let entries: [Entry] = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Entry? in
                guard let data = try? Data(contentsOf: url),
                      let file = try? ProjectFile.decode(from: data)
                else { return nil }
                return Entry(name: file.name, savedAt: file.savedAtDate, paneCount: file.paneCount)
            }

        return entries.sorted { $0.savedAt > $1.savedAt }
    }

    func entry(name: String) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL(name: name)),
              let file = try? ProjectFile.decode(from: data)
        else { return nil }
        return Entry(name: file.name, savedAt: file.savedAtDate, paneCount: file.paneCount)
    }

    /// Save (or overwrite -- see `Entry`) a project under `name`, capturing
    /// `tree`'s current shape and each pane's `cwd`/`title`.
    @discardableResult
    func save(name: String, tree: SplitTree<Ghostty.SurfaceView>) throws -> Entry {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.nameEmpty }

        let savedAt = Int(Date().timeIntervalSince1970)
        let root = tree.root.map { ProjectNode.capturing($0) }
        let file = ProjectFile(name: trimmed, savedAt: savedAt, root: root)
        let data = try file.encoded()

        try data.write(to: fileURL(name: trimmed), options: .atomic)

        Self.logger.info(
            "saved project '\(trimmed, privacy: .public)' with \(tree.count, privacy: .public) pane(s)")

        return Entry(name: trimmed, savedAt: file.savedAtDate, paneCount: tree.count)
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
        guard let data = try? Data(contentsOf: fileURL(name: name)) else {
            throw StoreError.notFound
        }
        let file = try ProjectFile.decode(from: data)
        let root = file.root.map { $0.materializing(app) }
        return SplitTree(root: root, zoomed: nil)
    }

    func delete(name: String) throws {
        try FileManager.default.removeItem(at: fileURL(name: name))
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
