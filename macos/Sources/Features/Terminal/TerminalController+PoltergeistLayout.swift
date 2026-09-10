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

    func applyToolLayout(_ specText: String) -> ToolLayoutResult {
        guard let data = specText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return .refused("the layout is not JSON")
        }

        let shape: PoltergeistLayoutCell
        do {
            shape = try PoltergeistLayoutParser.parse(json)
        } catch let error as PoltergeistLayoutError {
            return .refused(error.message)
        } catch {
            return .refused("the layout could not be parsed")
        }

        guard let ghosttyApp = ghostty.app else {
            return .refused("the app is not ready")
        }

        // Both numberings, taken from one snapshot: the shape names
        // surfaces (the only handle a caller can have -- see
        // `PoltergeistLayoutCell`), and panes are matched by identity, so
        // the pairing has to come from a single read of `surfaceTree`. Two
        // reads a moment apart could straddle a close and describe two
        // different panes.
        let currentViews = Array(surfaceTree)
        var handleToView: [UInt: Ghostty.SurfaceView] = [:]
        for view in currentViews {
            if let handle = PoltergeistLayoutCell.surfaceHandle(for: view) {
                handleToView[handle] = view
            }
        }

        // Surfaces to views, and a caller naming something not in this tab
        // is told which one rather than left to compare two lists itself.
        var namedHandles: [UInt] = []
        shape.collectExisting(into: &namedHandles)

        var namedViews: [Ghostty.SurfaceView] = []
        for handle in namedHandles {
            guard let view = handleToView[handle] else {
                return .refused(
                    "0x\(String(handle, radix: 16)) is not a terminal in this tab. " +
                    "Every cell must name a terminal that is already here, or ask for " +
                    "a new one with {\"new\": …}.")
            }
            namedViews.append(view)
        }

        // Every pane that is here must be in the shape, and nothing else.
        // ⚠️ Rearranging is not a way to close a terminal: a shape that
        // leaves one out would destroy it, turning a layout change into
        // something irreversible the caller did not say out loud. Closing
        // is its own verb and has its own confirmation.
        for view in currentViews {
            guard namedViews.contains(where: { $0 === view }) else {
                let handleText = PoltergeistLayoutCell.surfaceHandle(for: view)
                    .map { "0x" + String($0, radix: 16) } ?? "that terminal"
                return .refused(
                    "the layout leaves out terminal \(handleText), which is in this tab. " +
                    "Rearranging never closes a terminal: close it first, then send the " +
                    "layout you want for what is left.")
            }
        }
        if namedHandles.count != currentViews.count {
            return .refused("the layout names a terminal twice")
        }

        // Every check above passed: only now does anything get created or
        // the tree get replaced.
        let node = shape.materializing(
            existingByHandle: handleToView,
            makeNew: { cwd in
                var config = Ghostty.SurfaceConfiguration()
                if let cwd, !cwd.isEmpty { config.workingDirectory = cwd }
                return Ghostty.SurfaceView(ghosttyApp, baseConfig: config)
            })

        replaceSurfaceTree(
            SplitTree(root: node, zoomed: nil),
            undoAction: "Layout")

        // The reply is in the caller's namespace: `App.zig`'s
        // `layoutSurfacesToIds` walks this text for `pane` cells and
        // rewrites each surface handle to the terminal id that can be fed
        // back to `terminal_read`/`terminal_send`. Wrapped in `"layout"`
        // to match `windows/host/src/layout.rs`'s reply shape, so a caller
        // sees the same envelope on either platform.
        let reply: [String: Any] = ["layout": node.describingForLayoutReply()]
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
