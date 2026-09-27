import AppKit
import GhosttyKit

/// macOS's port of the project file shape defined in `src/Project.zig` --
/// the same relationship `macos/Sources/Features/Splits/SplitTree.swift`
/// has to the core's split-tree shape, and `windows/split-tree` has on the
/// Windows side. See `Project.zig`'s doc comment for the full contract;
/// this file only restates the parts that shape the Swift types.
///
/// Deliberately **not** built on `SplitTree<Ghostty.SurfaceView>`'s own
/// `Codable` conformance (the one `TerminalRestorableState` uses for window
/// restoration): that conformance's leaf shape (`pwd`/`uuid`/`title`/
/// `isUserSetTitle`) is a macOS-only restoration format, not this
/// cross-platform one, and its `init(from:)` spins up a live terminal
/// process per leaf as a side effect of decoding -- exactly wrong for
/// something a picker lists without opening. `ProjectFile`/`ProjectNode`
/// are the inert, side-effect-free data; `capture`/`materialize` below are
/// the two, explicit, one-directional bridges to and from live surfaces.
struct ProjectFile: Codable, Equatable {
    let name: String

    /// Unix seconds. Kept as a plain `Int` rather than `Date` +
    /// `.secondsSince1970` on purpose: that date strategy round-trips a
    /// `Double`, and `Project.zig`'s reader requires a JSON *integer*
    /// (`.integer => |n| n, else => error.Corrupt`) -- a whole-number
    /// double that happens to print as `1757000000.0` would make a
    /// mac-saved project unreadable by every other port of this format.
    let savedAt: Int

    let root: ProjectNode?

    /// The next scrollback snapshot number this project will hand out --
    /// see `ProjectScrollback.Allocator`. Only ever grows, so a number that
    /// belonged to a pane that has since closed is never given to a new
    /// one (which would restore the old pane's history into the new pane).
    /// Absent in files written before snapshots existed, and by the other
    /// ports, which don't allocate.
    let nextScrollback: Int?

    private enum CodingKeys: String, CodingKey {
        case name
        case savedAt = "saved_at"
        case root
        case nextScrollback = "next_scrollback"
    }

    init(name: String, savedAt: Int, root: ProjectNode?, nextScrollback: Int?) {
        self.name = name
        self.savedAt = savedAt
        self.root = root
        self.nextScrollback = nextScrollback
    }

    /// Every snapshot filename the tree refers to.
    var scrollbackFilenames: [String] {
        root?.scrollbackFilenames ?? []
    }

    /// Convenience for UI code that wants a `Date` to format.
    var savedAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(savedAt))
    }

    /// How many panes `root` has, without materializing any of them.
    var paneCount: Int {
        root?.leafCount ?? 0
    }
}

/// One node of a project's layout tree. Mirrors `Project.Node` in
/// `src/Project.zig` field for field: a `kind` discriminator
/// (`"leaf"`/`"split"`) rather than Swift's default associated-value
/// encoding, because that's the shape every other port of this format
/// reads and writes.
indirect enum ProjectNode: Equatable {
    /// `scrollback` is a snapshot filename inside the project's
    /// `ProjectScrollback.directory`, or empty for a pane saved without one.
    /// Only ever a name `ProjectScrollback.filename(number:)` produces --
    /// the reader drops anything else, see `init(from:)`.
    case leaf(cwd: String, title: String, history: String, scrollback: String)
    case split(direction: Direction, ratio: Double, left: ProjectNode, right: ProjectNode)

    /// Mirrors `Project.Direction` in `src/Project.zig`, which mirrors
    /// `SplitTree.Direction` in `SplitTree.swift`: `horizontal` means the
    /// children sit side by side (the divider between them is a vertical
    /// line). This is a naming trap inherited on purpose -- W1 aligned the
    /// core's naming with what Swift already had, so this does not get to
    /// "fix" it a second time.
    enum Direction: String, Codable {
        case horizontal
        case vertical
    }

    var leafCount: Int {
        switch self {
        case .leaf: return 1
        case .split(_, _, let left, let right): return left.leafCount + right.leafCount
        }
    }

    var scrollbackFilenames: [String] {
        switch self {
        case .leaf(_, _, _, let scrollback): return scrollback.isEmpty ? [] : [scrollback]
        case .split(_, _, let left, let right): return left.scrollbackFilenames + right.scrollbackFilenames
        }
    }
}

extension ProjectNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, cwd, title, history, scrollback, direction, ratio, left, right
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "leaf":
            // A `scrollback` that isn't a plain `<n>.snap` is read as absent,
            // not as an error: the core deletes a snapshot it can't decode, so
            // resolving an arbitrary path from a project file would let the
            // file delete things; and failing the whole decode would make one
            // bad field cost the user the entire project.
            let scrollback = try container.decodeIfPresent(String.self, forKey: .scrollback) ?? ""
            self = .leaf(
                cwd: try container.decodeIfPresent(String.self, forKey: .cwd) ?? "",
                title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
                history: try container.decodeIfPresent(String.self, forKey: .history) ?? "",
                scrollback: ProjectScrollback.isSnapshotFilename(scrollback) ? scrollback : "")

        case "split":
            // Both children are required. A split with only a `left` is
            // exactly the "half a tree" this format's reader (on every
            // platform) promises never to hand back, so a missing child
            // fails the whole decode -- the same as `Project.zig`'s
            // `parseNode`, which requires both before returning a node at
            // all rather than producing a lopsided one.
            self = .split(
                direction: try container.decode(Direction.self, forKey: .direction),
                ratio: try container.decode(Double.self, forKey: .ratio),
                left: try container.decode(ProjectNode.self, forKey: .left),
                right: try container.decode(ProjectNode.self, forKey: .right))

        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown project node kind '\(kind)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let cwd, let title, let history, let scrollback):
            try container.encode("leaf", forKey: .kind)
            if !cwd.isEmpty { try container.encode(cwd, forKey: .cwd) }
            if !title.isEmpty { try container.encode(title, forKey: .title) }
            if !history.isEmpty { try container.encode(history, forKey: .history) }
            if !scrollback.isEmpty { try container.encode(scrollback, forKey: .scrollback) }

        case .split(let direction, let ratio, let left, let right):
            try container.encode("split", forKey: .kind)
            try container.encode(direction, forKey: .direction)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)
        }
    }
}

// MARK: - Coding

enum ProjectFileCoding {
    static var decoder: JSONDecoder { JSONDecoder() }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension ProjectFile {
    static func decode(from data: Data) throws -> Self {
        try ProjectFileCoding.decoder.decode(Self.self, from: data)
    }

    func encoded() throws -> Data {
        try ProjectFileCoding.encoder.encode(self)
    }
}

// MARK: - Listing

enum ProjectListing {
    /// Decode each of `urls` as a project file, skipping any that can't be
    /// read or decoded.
    ///
    /// Skipping is deliberate and shared with the other ports -- a listing
    /// is an inventory for a picker, not a load, so one bad file shouldn't
    /// empty it (`src/Project.zig:448-451`, `windows/host/src/project.rs:327-329`).
    /// Changing it here alone would make the platforms disagree about
    /// which projects exist. What was wrong was the skip being silent: a
    /// project that disappears from the picker has to leave a trace
    /// somewhere, so every skip is handed to `skipped`.
    static func decode(_ urls: [URL], skipped: (URL, Error) -> Void) -> [(url: URL, file: ProjectFile)] {
        urls.compactMap { url in
            do {
                return (url, try ProjectFile.decode(from: Data(contentsOf: url)))
            } catch {
                skipped(url, error)
                return nil
            }
        }
    }
}

// MARK: - Capture (live surfaces -> data)

extension ProjectNode {
    /// Capture a live split tree's shape and each pane's `cwd`/`title`/
    /// `history` as portable data. Pure: reads the surfaces, doesn't touch
    /// them.
    ///
    /// `history` is whatever the core named this surface's capture file as
    /// (`view.historyFilename`, set once by `GHOSTTY_ACTION_HISTORY_FILENAME`
    /// -- see `Ghostty.App.historyFilename`), or empty when history capture
    /// was never on for this surface. Opaque either way: this apprt doesn't
    /// parse it, just carries it. An empty string round-trips fine per
    /// `Project.zig`'s reader (`history` is optional on every leaf).
    ///
    /// `scrollback` is asked once per leaf and returns the snapshot filename
    /// to record for that pane, or empty for none. It is the one non-pure
    /// part: `ProjectStore.save` passes a closure that looks up (or hands
    /// out) the pane's own snapshot name and may ask the core to write it.
    /// The default records none.
    static func capturing(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        scrollback: (Ghostty.SurfaceView) -> String = { _ in "" }
    ) -> ProjectNode {
        switch node {
        case .leaf(let view):
            return .leaf(
                cwd: view.pwd ?? "",
                title: view.title,
                history: view.historyFilename ?? "",
                scrollback: scrollback(view))

        case .split(let split):
            return .split(
                direction: Direction(split.direction),
                ratio: split.ratio,
                left: capturing(split.left, scrollback: scrollback),
                right: capturing(split.right, scrollback: scrollback))
        }
    }
}

private extension ProjectNode.Direction {
    init(_ direction: SplitTree<Ghostty.SurfaceView>.Direction) {
        switch direction {
        case .horizontal: self = .horizontal
        case .vertical: self = .vertical
        }
    }

    var splitTreeDirection: SplitTree<Ghostty.SurfaceView>.Direction {
        switch self {
        case .horizontal: return .horizontal
        case .vertical: return .vertical
        }
    }
}

// MARK: - Materialize (data -> live surfaces)

extension ProjectNode {
    /// Rebuild live surfaces from this node -- each leaf spins up a real
    /// terminal process at its saved `cwd` (or the shell's default when
    /// `cwd` no longer exists; `Exec.zig` already falls back rather than
    /// failing, see `if (std.Io.Dir.cwd().access(...))` in
    /// `src/termio/Exec.zig`). The result is ready to hand to
    /// `TerminalController(withSurfaceTree:)`.
    ///
    /// `scrollback` is where this project's snapshots live (see
    /// `ProjectScrollback.directory`) and the project they belong to; nil
    /// restores no scrollback at all.
    func materializing(
        _ app: ghostty_app_t,
        scrollback project: ProjectScrollback.Location? = nil
    ) -> SplitTree<Ghostty.SurfaceView>.Node {
        switch self {
        case .leaf(let cwd, let title, let history, let scrollback):
            var config = Ghostty.SurfaceConfiguration()
            if !cwd.isEmpty { config.workingDirectory = cwd }
            // Passed through opaquely -- see `SurfaceConfiguration.historyRestore`.
            // The core decides what it means per shell once it knows which
            // shell this pane is running (`Exec.zig`, after shell detection).
            if !history.isEmpty { config.historyRestore = history }
            // No existence check here, deliberately: a missing, stale or
            // corrupt snapshot is the core's to handle (it starts an empty
            // terminal and deletes the file), and checking here would only
            // add a second, racier opinion about the same file.
            if let project, !scrollback.isEmpty {
                config.scrollbackRestore = project.directory.appendingPathComponent(scrollback).path
            }
            let view = Ghostty.SurfaceView(app, baseConfig: config)
            // Not forced into the "explicitly named" tier (see
            // `titleFromTerminal` in `SurfaceView_AppKit.swift`): a saved
            // title is a snapshot of what the pane showed, not necessarily
            // something a person chose, so it's free to be replaced once
            // the shell reports its own title.
            if !title.isEmpty { view.setTitle(title) }
            // The pane keeps the snapshot name it was saved under, so its
            // next save writes the same file wherever the pane has moved to --
            // and from now on the core keeps that file up to date. This is
            // the restored pane's journal: it has none yet, so this starts
            // one, and its first write rewrites the file from what was just
            // restored.
            if let project, !scrollback.isEmpty {
                view.journalScrollback(.init(project: project.key, filename: scrollback), in: project.directory)
            }
            return .leaf(view: view)

        case .split(let direction, let ratio, let left, let right):
            return .split(.init(
                direction: direction.splitTreeDirection,
                ratio: ratio,
                left: left.materializing(app, scrollback: project),
                right: right.materializing(app, scrollback: project)))
        }
    }
}
