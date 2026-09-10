import AppKit

/// Turns a materialized project tree into an actual tab.
///
/// `ProjectStore.loadTree` already does the hard part -- each leaf's
/// `Ghostty.SurfaceView` is a real, running terminal surface at its saved
/// `cwd` by the time this is called (see `ProjectNode.materializing` in
/// `ProjectDocument.swift`). What's specific to "load a project" is
/// attaching that already-live tree as a *new tab*, which mirrors the
/// tab-group mechanics of `TerminalController.newTab(_:from:withBaseConfig:)`
/// for a tree that already has all of its surfaces rather than a single
/// surface config.
extension TerminalController {
    /// Open `tree` as a new tab of `parent`'s window, or as a new window if
    /// `parent` is nil or isn't a terminal window.
    @discardableResult
    static func openProject(
        _ ghostty: Ghostty.App,
        tree: SplitTree<Ghostty.SurfaceView>,
        attachingTo parent: NSWindow?
    ) -> TerminalController {
        guard let parent, parent.windowController is TerminalController else {
            return newWindow(ghostty, tree: tree)
        }

        let controller = TerminalController.init(ghostty, withSurfaceTree: tree)
        guard let window = controller.window else { return controller }

        // If the parent is miniaturized, macOS exhibits strange behavior
        // adding tabs to it, so bring it back out first. Same as
        // `newTab(_:from:withBaseConfig:)`.
        if parent.isMiniaturized { parent.deminiaturize(nil) }

        if let tg = parent.tabGroup, tg.windows.firstIndex(of: window) != nil {
            tg.removeWindow(window)
        }

        if window.tabbingMode != .disallowed {
            switch ghostty.config.windowNewTabPosition {
            case "end":
                if let last = parent.tabGroup?.windows.last {
                    last.addTabbedWindowSafely(window, ordered: .above)
                } else {
                    parent.addTabbedWindowSafely(window, ordered: .above)
                }
            case "current": fallthrough
            default:
                parent.addTabbedWindowSafely(window, ordered: .above)
            }
        }

        controller.scheduleInitialPresentation {
            controller.showWindowSafely(self)
            NSApp.activate(ignoringOtherApps: true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            controller.relabelTabs()
        }

        return controller
    }
}
