import CoreGraphics

/// What a project page's split tree will be laid out in: the window's
/// content less its titlebar and whatever sits above the tree, in points.
struct ProjectPageArea: Equatable {
    let size: CGSize
    /// The backing scale of the screen the window goes on.
    let scale: CGFloat
    /// `poltergeist-pane-frames`.
    let framed: Bool
}

/// The size each pane of a project page will be laid out at, worked out
/// before any of its terminals exists (issue #47).
///
/// **Why before.** A pane reopened from a project has its scrollback
/// restored when its surface is created (`ghostty_surface_config_s.width`/
/// `height`, `src/apprt/initial_size.zig`), and on macOS that is before the
/// view has been laid out. Without a size the core restores into an 800x600
/// placeholder, and the shell has written its first bytes before the real
/// size arrives -- so the restored screen is resized under the shell's
/// output, and what was on it ends up above the viewport.
///
/// **What it repeats.** The arithmetic the views do, for the one case it
/// can know: a tree of plain panes, as every pane of a page is when it has
/// just been reopened (nobody is working in it yet, so `PaneFrame.drawn`
/// gives it the plain frame, or none when it is alone).
/// - `SplitView.leftRect`/`rightRect`: half the divider off each side, the
///   left one cut to whole points.
/// - `PaneFrameScope`: once any pane wears a frame the tree is inset from
///   the window's edge.
/// - `PaneFramed`: each framed pane keeps `PaneFrameSplit.inset` clear on
///   every side and the plain frame's title band above.
///
/// A tree with a stack in it gets nil for every pane: a stack's strip is
/// drawn from what the core says about its terminals, which is not known
/// yet. Nil means "not known", and the surface then starts at the
/// placeholder, as every surface did before.
enum ProjectPaneSizes {
    typealias Look = ControlRoomLook

    /// One entry per terminal `ProjectNode.building` makes, in the order it
    /// makes them, in points; nil where the size is not known.
    static func sizes(of root: ProjectNode, in area: CGSize, framed: Bool) -> [CGSize?] {
        guard !root.holdsStack else { return Array(repeating: nil, count: root.terminalCount) }
        // A pane alone wears nothing; split, every one wears the plain frame.
        let ground = framed && !root.isLeaf
        let edge = ground ? CGFloat(Look.Space.windowEdge) - PaneFrameSplit.inset : 0
        let tree = CGSize(width: area.width - 2 * edge, height: area.height - 2 * edge)
        var out: [CGSize?] = []
        collect(root, in: tree, ground: ground, into: &out)
        return out.map { size in
            size.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        }
    }

    private static func collect(_ node: ProjectNode, in size: CGSize, ground: Bool, into out: inout [CGSize?]) {
        switch node {
        case .leaf:
            guard ground else { out.append(size); return }
            let room = PaneFrameChrome.room(for: .plain)
            let inset = PaneFrameSplit.inset
            out.append(CGSize(
                width: size.width - 2 * inset - room.leading - room.trailing,
                height: size.height - 2 * inset - room.top - room.bottom))

        case .stack:
            preconditionFailure("sizes(of:in:framed:) answers nil for a tree with a stack")

        case .split(let direction, let ratio, let left, let right):
            let (first, second) = split(size, direction: direction, ratio: CGFloat(ratio))
            collect(left, in: first, ground: ground, into: &out)
            collect(right, in: second, ground: ground, into: &out)
        }
    }

    /// `SplitView.leftRect` and `rightRect` with `resizeIncrements` of one
    /// point, which is what `TerminalSplitTreeView` passes.
    static func split(_ size: CGSize, direction: ProjectNode.Direction, ratio: CGFloat) -> (CGSize, CGSize) {
        let divider = PaneFrameSplit.dividerWidth
        switch direction {
        case .horizontal:
            var left = size.width * ratio - divider / 2
            left -= left.truncatingRemainder(dividingBy: 1)
            return (CGSize(width: left, height: size.height),
                    CGSize(width: size.width - (left + divider / 2), height: size.height))
        case .vertical:
            var top = size.height * ratio - divider / 2
            top -= top.truncatingRemainder(dividingBy: 1)
            return (CGSize(width: size.width, height: top),
                    CGSize(width: size.width, height: size.height - (top + divider / 2)))
        }
    }

    /// Points to the pixels `SurfaceView.sizeDidChange` hands the core
    /// (`convertToBacking`, then truncated to `UInt32`).
    static func pixels(_ size: CGSize, scale: CGFloat) -> (width: UInt32, height: UInt32) {
        (UInt32(size.width * scale), UInt32(size.height * scale))
    }
}

private extension ProjectNode {
    var isLeaf: Bool {
        if case .leaf = self { return true }
        return false
    }

    var holdsStack: Bool {
        switch self {
        case .leaf: return false
        case .stack: return true
        case .split(_, _, let left, let right): return left.holdsStack || right.holdsStack
        }
    }

    /// How many terminals `building` makes of this node.
    var terminalCount: Int {
        switch self {
        case .leaf: return 1
        case .stack(let shown, let members):
            return members.count > 1 && members.indices.contains(shown) ? members.count : 1
        case .split(_, _, let left, let right): return left.terminalCount + right.terminalCount
        }
    }
}
