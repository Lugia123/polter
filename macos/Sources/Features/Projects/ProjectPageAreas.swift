import AppKit
import GhosttyKit
import SwiftUI

/// Where a project page's split tree will be laid out, worked out before the
/// page's window exists (#47). `ProjectPaneSizes` divides it among the panes.
///
/// Only one case is answered: a window of its own at a frame the file
/// recorded, with the `native` or `transparent` titlebar. Everything else
/// is nil -- not known -- and its panes start at the core's placeholder, as
/// they always did: a page opened as a tab beside others (the tab bar's
/// height depends on what is already there), a window with no recorded
/// frame (its size is the cascade's), and the `tabs` and `hidden` titlebar
/// styles, whose tree does not sit under an ordinary titlebar.
@MainActor
enum ProjectPageAreas {
    /// The tree's area in a window of its own whose frame is `frame`: the
    /// frame less the titlebar, and less the debug build's warning band,
    /// which `TerminalView` stacks above the tree.
    static func ownWindow(_ frame: CGRect, ghostty: Ghostty.App) -> ProjectPageArea? {
        let config = ghostty.config
        guard config.windowDecorations else { return nil }
        switch config.macosTitlebarStyle {
        case .native, .transparent: break
        case .tabs, .hidden: return nil
        }
        let titlebar = titlebarHeight(frame)
        let band = DebugBuildWarningView.shows ? DebugBuildWarningView.height(width: frame.width) : 0
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        return ProjectPageArea(
            size: CGSize(width: frame.width, height: frame.height - titlebar - band),
            scale: screen?.backingScaleFactor ?? 1,
            framed: config.poltergeistPaneFrames)
    }

    /// The titlebar of a `native` or `transparent` terminal window with no
    /// tab bar, as AppKit has it for the window's style. Asked of the class
    /// rather than read off a window on screen: while a project opens, the
    /// windows it has just made are not on screen yet, and the one that is
    /// may be showing a tab bar. Measured on macOS 26 against a real
    /// window: 32 both ways.
    private static func titlebarHeight(_ frame: CGRect) -> CGFloat {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        return frame.height - NSWindow.contentRect(forFrameRect: frame, styleMask: style).height
    }
}

extension DebugBuildWarningView {
    /// Whether `TerminalView` shows this band above the split tree.
    static var shows: Bool {
        Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE
    }

    /// Its height at `width`, as it lays itself out.
    @MainActor
    static func height(width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: DebugBuildWarningView())
        host.frame.size = CGSize(width: width, height: 0)
        return host.fittingSize.height
    }
}
