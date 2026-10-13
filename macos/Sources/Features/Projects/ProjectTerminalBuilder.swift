import AppKit

/// Puts a page of a project, already materialized, on screen.
///
/// `ProjectStore.materialize` does the hard part -- each leaf's
/// `Ghostty.SurfaceView` is a real, running terminal surface at its saved
/// `cwd` by the time this is called (see `ProjectNode.materializing` in
/// `ProjectDocument.swift`). Which pages open, in which window and in what
/// order is `ProjectSession.open`; a page that goes beside one already on
/// screen is added there as a tab, and this is the other case.
extension TerminalController {
    /// Show this tab, just made from a page of a project, as a window of
    /// its own. The project's other pages of that window are then added to
    /// it as tabs.
    ///
    /// **Where the window goes is not decided here when the project
    /// recorded it** (`placed` true): a frame set on this tab's window
    /// before the others are added and the one in front is chosen is a
    /// frame on a tab that may not be the one on screen -- the tab that is
    /// would keep a new window's place. `ProjectSession.open` sets it on
    /// the whole window once its tabs stand. With no place recorded the
    /// window goes where any new window goes.
    func presentAsProjectWindow(placed: Bool) {
        guard let window else { return }
        showWindowSafely(self)
        guard !placed else { return }
        scheduleInitialPresentation { [weak self] in
            guard let self, !window.styleMask.contains(.fullScreen) else { return }
            let fixed = self.derivedConfig.windowPositionX != nil && self.derivedConfig.windowPositionY != nil
            Self.applyCascade(to: window, hasFixedPos: fixed)
        }
    }
}
