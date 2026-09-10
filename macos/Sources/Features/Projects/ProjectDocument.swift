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

    private enum CodingKeys: String, CodingKey {
        case name
        case savedAt = "saved_at"
        case root
    }

    init(name: String, savedAt: Int, root: ProjectNode?) {
        self.name = name
        self.savedAt = savedAt
        self.root = root
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
    case leaf(cwd: String, title: String, history: String)
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
}

extension ProjectNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, cwd, title, history, direction, ratio, left, right
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "leaf":
            self = .leaf(
                cwd: try container.decodeIfPresent(String.self, forKey: .cwd) ?? "",
                title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
                history: try container.decodeIfPresent(String.self, forKey: .history) ?? "")

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
        case .leaf(let cwd, let title, let history):
            try container.encode("leaf", forKey: .kind)
            if !cwd.isEmpty { try container.encode(cwd, forKey: .cwd) }
            if !title.isEmpty { try container.encode(title, forKey: .title) }
            if !history.isEmpty { try container.encode(history, forKey: .history) }

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
    static func capturing(_ node: SplitTree<Ghostty.SurfaceView>.Node) -> ProjectNode {
        switch node {
        case .leaf(let view):
            return .leaf(cwd: view.pwd ?? "", title: view.title, history: view.historyFilename ?? "")

        case .split(let split):
            return .split(
                direction: Direction(split.direction),
                ratio: split.ratio,
                left: capturing(split.left),
                right: capturing(split.right))
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
    func materializing(_ app: ghostty_app_t) -> SplitTree<Ghostty.SurfaceView>.Node {
        switch self {
        case .leaf(let cwd, let title, let history):
            var config = Ghostty.SurfaceConfiguration()
            if !cwd.isEmpty { config.workingDirectory = cwd }
            // Passed through opaquely -- see `SurfaceConfiguration.historyRestore`.
            // The core decides what it means per shell once it knows which
            // shell this pane is running (`Exec.zig`, after shell detection).
            if !history.isEmpty { config.historyRestore = history }
            let view = Ghostty.SurfaceView(app, baseConfig: config)
            // Not forced into the "explicitly named" tier (see
            // `titleFromTerminal` in `SurfaceView_AppKit.swift`): a saved
            // title is a snapshot of what the pane showed, not necessarily
            // something a person chose, so it's free to be replaced once
            // the shell reports its own title.
            if !title.isEmpty { view.setTitle(title) }
            return .leaf(view: view)

        case .split(let direction, let ratio, let left, let right):
            return .split(.init(
                direction: direction.splitTreeDirection,
                ratio: ratio,
                left: left.materializing(app),
                right: right.materializing(app)))
        }
    }
}
