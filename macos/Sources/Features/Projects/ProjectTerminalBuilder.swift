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
    /// its own: at `frame` when the project recorded where it was, and
    /// where any new window goes when it did not. The project's other pages
    /// of that window are then added to it as tabs.
    func presentAsProjectWindow(at frame: CGRect?) {
        guard let window else { return }
        showWindowSafely(self)
        scheduleInitialPresentation { [weak self] in
            guard let self, !window.styleMask.contains(.fullScreen) else { return }
            if let frame {
                window.setFrame(frame, display: true)
            } else {
                let fixed = self.derivedConfig.windowPositionX != nil && self.derivedConfig.windowPositionY != nil
                Self.applyCascade(to: window, hasFixedPos: fixed)
            }
        }
    }
}
