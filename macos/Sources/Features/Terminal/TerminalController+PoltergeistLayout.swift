import AppKit
import GhosttyKit

/// Applying `poltergeist_layout` to a tab.
///
/// Mirrors `apply_layout` in `windows/host/src/tabs.rs`: parse and validate
/// the whole shape before touching anything, so a layout that is wrong in
/// one place changes nothing rather than applying half of itself. The
/// glue that turns this into a C ABI answer is
/// `Ghostty.App.poltergeistLayout` in `Ghostty.App.swift`.
extension TerminalController {
    /// What came of applying a shape: the refusal text, or the resulting
    /// layout as JSON (`{"layout": …}`, every pane named by its surface
    /// handle -- see `describingForLayoutReply`).
    enum ToolLayoutResult {
        case refused(String)
        case applied(String)
    }

    /// Apply a tool layout (`poltergeist_layout`). `specText` is the core's
    /// envelope, `{"layout": …, "into": …}` (task 1571); `aimed` is the
    /// surface the action was aimed at, whose tab the shape replaces when
    /// `into` says nothing.
    ///
    /// **Terminals named from other tabs and windows are moved, never
    /// rebuilt**: the same view goes into the new tree, and leaves its old
    /// one, the way `splitDidDrop` moves a pane dropped on another window.
    /// A tab left with nothing in it closes, and with it a window left with
    /// no tab.
    static func applyToolLayout(_ specText: String, aimed: Ghostty.SurfaceView) -> ToolLayoutResult {
        guard let data = specText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return .refused("the layout is not JSON")
        }

        let shape: PoltergeistLayoutCell
        let into: PolterArrangePlan.Into
        do {
            let envelope = try PolterArrangePlan.envelope(json)
            into = envelope.into
            shape = try PoltergeistLayoutParser.parse(envelope.layout)
        } catch let error as PoltergeistLayoutError {
            return .refused(error.message)
        } catch {
            return .refused("the layout could not be parsed")
        }

        // Every terminal Polter has open, by handle, from one reading of
        // every tab -- the stacked ones included (`SplitTree` iterates
        // members). Two readings a moment apart could straddle a close.
        let controllers = TerminalController.all
        var everywhere: [UInt: PolterArrangePlan.Placed<Ghostty.SurfaceView>] = [:]
        for controller in controllers {
            for view in controller.surfaceTree {
                guard let handle = PoltergeistLayoutCell.surfaceHandle(for: view) else { continue }
                everywhere[handle] = .init(
                    view: view,
                    home: ObjectIdentifier(controller),
                    lent: ControlRoomLender.shared.isLent(view))
            }
        }
        func controller(of id: ObjectIdentifier) -> TerminalController? {
            controllers.first { ObjectIdentifier($0) == id }
        }

        // Where the shape goes.
        let destination: TerminalController?
        var neighbor: NSWindow?
        switch into {
        case .here:
            guard let c = controllers.first(where: { $0.surfaceTree.contains(aimed) }) else {
                return .refused("that terminal is not in a tab this window can lay out")
            }
            destination = c
        case .newTabBeside(let handle):
            guard let placed = everywhere[handle],
                  let c = controller(of: placed.home),
                  let window = c.window else {
                return .refused("0x\(String(handle, radix: 16)) is not a terminal in a tab")
            }
            destination = nil
            neighbor = window
        case .newWindow:
            destination = nil
        }

        guard let ghosttyApp = (destination ?? controllers.first(where: { $0.surfaceTree.contains(aimed) }) ?? controllers.first)?.ghostty,
              let app = ghosttyApp.app else {
            return .refused("the app is not ready")
        }

        var namedHandles: [UInt] = []
        shape.collectExisting(into: &namedHandles)
        let plan: PolterArrangePlan.Plan<Ghostty.SurfaceView>
        switch PolterArrangePlan.decide(
            named: namedHandles,
            everywhere: everywhere,
            destination: destination.map { (ObjectIdentifier($0), Array($0.surfaceTree)) },
            handleOf: { PoltergeistLayoutCell.handleString(for: $0) }) {
        case .failure(let refusal): return .refused(refusal.wire)
        case .success(let p): plan = p
        }

        // Every check above passed: only now does anything get created or
        // a tree get replaced.
        // The stacks come out beside the node and go into the tree with it.
        // ⚠️ A tree made of the node alone keeps only the terminal each
        // pane shows: every terminal stacked behind one would be left
        // running with no pane, and no check above would have noticed --
        // they are all "in the shape".
        var stacks: [SplitTree<Ghostty.SurfaceView>.Stack] = []
        let node = shape.materializing(
            existingByHandle: plan.byHandle,
            makeNew: { cwd in
                var config = Ghostty.SurfaceConfiguration()
                if let cwd, !cwd.isEmpty { config.workingDirectory = cwd }
                return Ghostty.SurfaceView(app, baseConfig: config)
            },
            stacks: &stacks)
        let tree = SplitTree<Ghostty.SurfaceView>(root: node, zoomed: nil, stacks: stacks)

        // **The new home first, then the old ones let go**, so a tab the new
        // one is opened beside is still there to open it beside -- it may be
        // one the move empties. A view is only ever drawn by one tree: the
        // trees are swapped in this turn of the run loop and drawn after it.
        let opacity = destination?.isBackgroundOpaque ?? controllers.first?.isBackgroundOpaque
        switch into {
        case .here:
            destination?.replaceSurfaceTree(tree, undoAction: "Layout")
        case .newTabBeside:
            guard let neighbor else { return .refused("that tab went while the layout was being built") }
            _ = TerminalController.newTab(
                ghosttyApp,
                tree: tree,
                beside: neighbor,
                ordered: .above,
                inheritBackgroundOpacity: opacity)
        case .newWindow:
            _ = TerminalController.newWindow(
                ghosttyApp,
                tree: tree,
                confirmUndo: false,
                inheritBackgroundOpacity: opacity)
        }

        for (home, views) in plan.leaving {
            guard let source = controller(of: home) else { continue }
            var remaining = source.surfaceTree
            for view in views {
                // By member, not by node: a terminal stacked behind another
                // leaves its stack and the pane stays, showing the next.
                if let next = try? remaining.removing(member: view) { remaining = next }
            }
            // ⚠️ **A tab the move empties is retired, not closed.** Closing
            // (`replaceSurfaceTree` with an empty tree) keeps the old tree
            // for undo -- and undoing it would put the moved terminals back
            // in a second tree while they live in the new one. It also kept
            // the dead controller claiming them, so the "after" reading of
            // where they went found the closed tab. An empty tree assigned
            // directly closes the window with nothing to undo
            // (`surfaceTreeDidChange`), as the Windows host's
            // `retire_emptied_tab` takes away a tab a move left empty.
            if remaining.isEmpty {
                source.surfaceTree = .init()
                continue
            }
            let keepFocus = source.focusedSurface.flatMap { f in remaining.contains(f) ? f : nil }
            source.replaceSurfaceTree(
                remaining,
                moveFocusTo: keepFocus ?? remaining.shownLeaves().first,
                undoAction: "Move Split")
        }

        // The reply is in the caller's namespace: `App.zig`'s
        // `layoutSurfacesToIds` walks this text for `pane` cells and
        // rewrites each surface handle to the terminal id that can be fed
        // back to `terminal_read`/`terminal_send`. Wrapped in `"layout"`
        // to match `windows/host/src/layout.rs`'s reply shape, so a caller
        // sees the same envelope on either platform.
        let reply: [String: Any] = ["layout": tree.describingForLayoutReply(node)]
        guard let replyData = try? JSONSerialization.data(withJSONObject: reply),
              let replyText = String(data: replyData, encoding: .utf8)
        else {
            // The layout is already applied at this point; only the reply
            // text failed to build, which should not be possible for JSON
            // this method built itself. Applied wins over a perfect reply.
            return .applied("{\"layout\":null}")
        }
        return .applied(replyText)
    }
}
