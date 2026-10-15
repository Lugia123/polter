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
/// - `{"stack": [cell, cell, …], "shown": 0}` -- one pane holding several
///   terminals, one of them in front (control-room.md, 12.6.2). Each
///   member is a `pane` or a `new`, never a split or another stack: a
///   stack is what one pane holds. `shown` is which member is in front,
///   the first when it is left out. Two members at least -- a stack of
///   one is that terminal, and is written as the cell itself.
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
    /// One pane holding `members` (each `existing` or `new`), showing
    /// `members[shown]`.
    case stack(members: [PoltergeistLayoutCell], shown: Int)
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

        if let stackValue = obj["stack"] {
            guard let listed = stackValue as? [Any] else {
                throw PoltergeistLayoutError(message: "\"stack\" must be a list of cells")
            }
            // One is not a stack and none is nothing at all: a caller who
            // wrote either meant something this cannot work out.
            guard listed.count >= 2 else {
                throw PoltergeistLayoutError(
                    message: "a stack holds two terminals or more; for one, write the cell itself")
            }
            let members = try listed.map { try parse($0) }
            for member in members {
                switch member {
                case .existing, .new: break
                case .split, .stack:
                    throw PoltergeistLayoutError(
                        message: "a stack's members are terminals: each must be {\"pane\":…} or {\"new\":…}, not a split or another stack")
                }
            }
            var shown = 0
            if let shownValue = obj["shown"] {
                // A whole number, and not a boolean in a number's clothes.
                guard let n = shownValue as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue == Double(n.intValue) else {
                    throw PoltergeistLayoutError(message: "\"shown\" must be a whole number: which member is in front, counting from 0")
                }
                guard members.indices.contains(n.intValue) else {
                    throw PoltergeistLayoutError(
                        message: "\"shown\" is \(n.intValue), and the stack has members 0 to \(members.count - 1)")
                }
                shown = n.intValue
            }
            return .stack(members: members, shown: shown)
        }

        guard let splitValue = obj["split"] as? String else {
            throw PoltergeistLayoutError(message: "a cell must be {\"pane\":…}, {\"new\":…}, {\"split\":\"h\"|\"v\",…} or {\"stack\":[…]}")
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
        case .stack(let members, _):
            for member in members { member.collectExisting(into: &out) }
        }
    }

    /// Turn this cell into a real node. `existingByHandle` must already
    /// contain every handle this cell names -- validated by the caller
    /// before this runs (see `TerminalController.applyToolLayout`), so a
    /// missing entry here is a bug upstream, not a shape to refuse.
    ///
    /// **A stack is not in the node**: a node knows only the terminal each
    /// pane shows. Every stack this cell holds is added to `stacks`, for
    /// the tree that is made of the node -- a tree made of the node alone
    /// would leave the terminals behind with no pane.
    func materializing(
        existingByHandle: [UInt: Ghostty.SurfaceView],
        makeNew: (String?) -> Ghostty.SurfaceView,
        stacks: inout [SplitTree<Ghostty.SurfaceView>.Stack]
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
                left: left.materializing(existingByHandle: existingByHandle, makeNew: makeNew, stacks: &stacks),
                right: right.materializing(existingByHandle: existingByHandle, makeNew: makeNew, stacks: &stacks)))

        case .stack(let members, let shown):
            let views: [Ghostty.SurfaceView] = members.map { member in
                switch member {
                case .existing(let handle):
                    guard let view = existingByHandle[handle] else {
                        preconditionFailure("layout validation let an unvalidated handle through")
                    }
                    return view
                case .new(let cwd):
                    return makeNew(cwd)
                case .split, .stack:
                    preconditionFailure("the parser lets only terminals into a stack")
                }
            }
            stacks.append(.init(shown: views[shown].id, members: views))
            return .leaf(view: views[shown])
        }
    }
}

extension SplitTree<Ghostty.SurfaceView> {
    /// The shape as it ended up, as JSON, every terminal named by its
    /// surface handle -- the form the core's `layoutSurfacesToIds` step
    /// reads to translate the reply back into terminal ids. Mirrors
    /// `layout::describe` in `windows/host/src/layout.rs`, with one cell
    /// that has no counterpart there yet: a pane that holds a stack is
    /// said as the stack, every member of it, so that a terminal behind
    /// another is never missing from what the caller is told is there.
    func describingForLayoutReply(_ node: Node) -> [String: Any] {
        switch node {
        case .leaf(let view):
            guard let stack = stack(of: view) else {
                return ["pane": PoltergeistLayoutCell.handleString(for: view)]
            }
            return [
                "stack": stack.members.map { ["pane": PoltergeistLayoutCell.handleString(for: $0)] },
                "shown": stack.members.firstIndex { $0.id == stack.shown } ?? 0,
            ]

        case .split(let split):
            return [
                "split": split.direction == .horizontal ? "h" : "v",
                "ratio": split.ratio,
                "left": describingForLayoutReply(split.left),
                "right": describingForLayoutReply(split.right),
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
