import AppKit

/// The shape a `poltergeist_layout` call asks for -- macOS's reader of the
/// JSON `apprt.action.PoltergeistLayout` carries, mirroring
/// `windows/host/src/layout.rs`'s `Shape` (see that file's header for why
/// a whole shape arrives at once rather than one split at a time).
///
/// A cell is one of:
/// - `{"pane": "0x…"}` -- a pane already in this tab, named by the surface
///   handle the core substituted for the caller's terminal id (see
///   `App.zig`'s `poltergeistLayout`/`rewriteLayoutValue` -- the caller
///   never sees this number, only the terminal id it wrote).
/// - `{"new": {"cwd": "…"}}` or `{"new": null}` -- a pane to make.
/// - `{"split": "h"|"v", "ratio": 0.5, "left": …, "right": …}`.
///
/// ⚠️ **`"h"`/`"v"` here is the wire shorthand, not the same spelling as
/// the project file format's `"horizontal"`/`"vertical"`**
/// (`ProjectNode.Direction` in `ProjectDocument.swift`). Windows hit the
/// same trap and left a comment; this is the macOS half of that comment.
indirect enum PoltergeistLayoutCell {
    /// A pane already in this tab. The handle is compared against this
    /// tab's own panes, never dereferenced as a pointer -- the spec string
    /// is caller-provided text, not something to be trusted as an address.
    case existing(handle: UInt)
    case new(cwd: String?)
    case split(direction: SplitTree<Ghostty.SurfaceView>.Direction, ratio: Double, left: PoltergeistLayoutCell, right: PoltergeistLayoutCell)
}

/// A refusal reason, in the caller's terms -- handed back verbatim as the
/// tool's refusal text. English, not localized: this crosses the
/// `poltergeist_layout` RPC to an agent, not the macOS UI the Chinese
/// strings checker covers.
struct PoltergeistLayoutError: Error {
    let message: String
}

enum PoltergeistLayoutParser {
    /// Parse a spec cell. **Refuses rather than repairing** -- an
    /// out-of-range ratio, an unknown key, a split missing a side are each
    /// a caller who meant something this cannot work out, and silently
    /// choosing a value for them is how a tool comes to report success for
    /// a shape nobody asked for. Mirrors `layout::parse` in
    /// `windows/host/src/layout.rs`.
    static func parse(_ value: Any) throws -> PoltergeistLayoutCell {
        guard let obj = value as? [String: Any] else {
            throw PoltergeistLayoutError(message: "each cell must be an object")
        }

        if let paneValue = obj["pane"] {
            guard let s = paneValue as? String else {
                throw PoltergeistLayoutError(message: "\"pane\" must be a terminal id as a string")
            }
            guard let handle = parseHandle(s) else {
                throw PoltergeistLayoutError(message: "\"\(s)\" is not a terminal id")
            }
            return .existing(handle: handle)
        }

        if let newValue = obj["new"] {
            if newValue is NSNull {
                return .new(cwd: nil)
            }
            guard let newObj = newValue as? [String: Any] else {
                throw PoltergeistLayoutError(message: "\"new\" must be an object or null")
            }
            if let cwd = newObj["cwd"] as? String, !cwd.isEmpty {
                return .new(cwd: cwd)
            }
            return .new(cwd: nil)
        }

        guard let splitValue = obj["split"] as? String else {
            throw PoltergeistLayoutError(message: "a cell must be {\"pane\":…}, {\"new\":…} or {\"split\":\"h\"|\"v\",…}")
        }
        let direction: SplitTree<Ghostty.SurfaceView>.Direction
        switch splitValue {
        case "h": direction = .horizontal
        case "v": direction = .vertical
        default:
            throw PoltergeistLayoutError(message: "\"split\" must be \"h\" or \"v\", not \"\(splitValue)\"")
        }

        // A ratio out of range is refused, not clamped: clamping would
        // apply a layout the caller did not ask for and report success.
        let ratio: Double
        if let ratioValue = obj["ratio"] {
            guard let r = (ratioValue as? NSNumber)?.doubleValue else {
                throw PoltergeistLayoutError(message: "\"ratio\" must be a number")
            }
            guard r > 0 && r < 1 else {
                throw PoltergeistLayoutError(message: "\"ratio\" must be between 0 and 1, not \(r)")
            }
            ratio = r
        } else {
            ratio = 0.5
        }

        guard let leftValue = obj["left"] else {
            throw PoltergeistLayoutError(message: "a split needs \"left\"")
        }
        guard let rightValue = obj["right"] else {
            throw PoltergeistLayoutError(message: "a split needs \"right\"")
        }
        let left = try parse(leftValue)
        let right = try parse(rightValue)
        return .split(direction: direction, ratio: ratio, left: left, right: right)
    }

    /// A terminal id as the core writes it into a `pane` cell after
    /// translating it from what the caller sent: `0x…` hex, though a plain
    /// decimal number is accepted too since nothing here depends on which.
    private static func parseHandle(_ s: String) -> UInt? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("0x") || t.hasPrefix("0X") {
            return UInt(t.dropFirst(2), radix: 16)
        }
        return UInt(t)
    }
}

extension PoltergeistLayoutCell {
    /// Every `existing` handle this cell (or its children) names, in the
    /// order named -- duplicates included, since a duplicate is itself
    /// something the caller has to be told about.
    func collectExisting(into out: inout [UInt]) {
        switch self {
        case .existing(let handle): out.append(handle)
        case .new: break
        case .split(_, _, let left, let right):
            left.collectExisting(into: &out)
            right.collectExisting(into: &out)
        }
    }

    /// Turn this cell into a real node. `existingByHandle` must already
    /// contain every handle this cell names -- validated by the caller
    /// before this runs (see `TerminalController.applyToolLayout`), so a
    /// missing entry here is a bug upstream, not a shape to refuse.
    func materializing(
        existingByHandle: [UInt: Ghostty.SurfaceView],
        makeNew: (String?) -> Ghostty.SurfaceView
    ) -> SplitTree<Ghostty.SurfaceView>.Node {
        switch self {
        case .existing(let handle):
            guard let view = existingByHandle[handle] else {
                preconditionFailure("layout validation let an unvalidated handle through")
            }
            return .leaf(view: view)

        case .new(let cwd):
            return .leaf(view: makeNew(cwd))

        case .split(let direction, let ratio, let left, let right):
            return .split(.init(
                direction: direction,
                ratio: ratio,
                left: left.materializing(existingByHandle: existingByHandle, makeNew: makeNew),
                right: right.materializing(existingByHandle: existingByHandle, makeNew: makeNew)))
        }
    }
}

extension SplitTree<Ghostty.SurfaceView>.Node {
    /// The shape as it ended up, as JSON, every leaf named by its surface
    /// handle -- the form the core's `layoutSurfacesToIds` step reads to
    /// translate the reply back into terminal ids. Mirrors `layout::describe`
    /// in `windows/host/src/layout.rs`.
    func describingForLayoutReply() -> [String: Any] {
        switch self {
        case .leaf(let view):
            return ["pane": PoltergeistLayoutCell.handleString(for: view)]

        case .split(let split):
            return [
                "split": split.direction == .horizontal ? "h" : "v",
                "ratio": split.ratio,
                "left": split.left.describingForLayoutReply(),
                "right": split.right.describingForLayoutReply(),
            ]
        }
    }
}

extension PoltergeistLayoutCell {
    /// The handle the core's translation expects: the same
    /// `ghostty_surface_t` pointer value every other action target
    /// carries, formatted `0x…`. See `App.zig`'s `rewriteLayoutValue`
    /// (`@intFromPtr(s.rt_surface)`) -- this is the Swift side of the same
    /// number, taken from `SurfaceView.surface` rather than recomputed.
    static func handleString(for view: Ghostty.SurfaceView) -> String {
        guard let handle = surfaceHandle(for: view) else { return "0x0" }
        return "0x" + String(handle, radix: 16)
    }

    static func surfaceHandle(for view: Ghostty.SurfaceView) -> UInt? {
        guard let surface = view.surface else { return nil }
        return UInt(bitPattern: surface)
    }
}
