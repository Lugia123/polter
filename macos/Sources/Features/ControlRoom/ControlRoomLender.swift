import AppKit
import Combine
import GhosttyKit
import CoreImage
import SwiftUI

/// The one terminal the control room has on loan, as the rest of the
/// application needs to know it (`ControlRoomLending` decides; this is the
/// part with views in it).
///
/// **The terminal never leaves its tab's split tree.** What moves is its
/// view: the pane it lives in draws a placeholder while this says it is
/// lent, and the control room puts the view on its right-hand side. So
/// everything that finds a terminal through its tree -- closing it,
/// splitting it, saving the window -- goes on working, and giving it back is
/// only saying it is no longer lent.
///
/// Two things do follow the view and not the tree, and have to be told:
///
///   * its own tab's controller keeps every terminal in its tree told
///     whether it has the keyboard and whether it can be seen, from its own
///     window. For the lent one those are the control room's to say
///     (`BaseTerminalController` skips it; `ControlRoomController` says).
///   * `view.window` is now the control room's. Code that wants the window
///     the terminal belongs to asks `homeWindow`.
///
/// And one thing follows the view late: its own window's keyboard. That
/// window lost its first responder when the view left, and gets the view
/// back only when its pane next draws. `settle` hands the keyboard over
/// when the view has arrived (`ControlRoomHomecoming`).
final class ControlRoomLender: ObservableObject {
    static let shared = ControlRoomLender()

    /// The lent terminal's view id; nil when nothing is lent. What a pane
    /// watches to know whether to draw itself or the placeholder.
    @Published private(set) var lentID: UUID?
    private(set) weak var lent: Ghostty.SurfaceView?
    /// The last frame the lent terminal drew in its own pane, taken as it
    /// left: what the placeholder there is drawn over. Nil with nothing
    /// lent, or when the terminal had drawn nothing.
    @Published private(set) var frozenAtHome: CGImage?

    /// The person asked for it back from the placeholder.
    var onReclaim: ((Ghostty.SurfaceView) -> Void)?
    /// Its place in its own tab is gone.
    var onHomeGone: ((Ghostty.SurfaceView) -> Void)?

    func isLent(_ view: Ghostty.SurfaceView) -> Bool {
        lent === view
    }

    /// Terminals given back whose own window has not handed them the
    /// keyboard yet.
    private var homecoming = ControlRoomHomecoming()
    /// Search bars open on a terminal when it changed views.
    private var movedSearches = ControlRoomMovedSearches<Ghostty.SurfaceView.SearchState>()

    func markLent(_ view: Ghostty.SurfaceView) {
        if let terminal = Self.terminal(of: view) { homecoming.cancelled(terminal) }
        if let search = view.searchState { movedSearches.moved(search) }
        // Before it moves: this is the frame at the size of its own pane.
        frozenAtHome = Self.freeze(view)
        lent = view
        lentID = view.id
    }

    func markReturned() {
        if let search = lent?.searchState { movedSearches.moved(search) }
        lent = nil
        lentID = nil
        frozenAtHome = nil
    }

    /// `view` was given back and its own tab is still there. `wanted`
    /// when the person asked for it back from that tab.
    func goingHome(_ view: Ghostty.SurfaceView, wanted: Bool) {
        guard let terminal = Self.terminal(of: view) else { return }
        homecoming.returned(terminal, wanted: wanted)
    }

    /// Something happened that may let `view`'s own window hand it the
    /// keyboard: the view moved into a window, or that window became key.
    /// Asked as often as that happens; does something once per return.
    func settle(_ view: Ghostty.SurfaceView) {
        guard !homecoming.awaited.isEmpty, !isLent(view),
              let terminal = Self.terminal(of: view),
              let home = BaseTerminalController.controller(owning: view),
              let window = home.window else { return }
        let steps = homecoming.settle(terminal, home: .init(
            attached: view.window === window,
            isFocusedPane: home.focusedSurface === view,
            keyboardIsUnclaimed: window.firstResponder == nil || window.firstResponder === window))
        guard !steps.isEmpty else { return }
        // Said when it does something (task 1873): making a window key is
        // one of the window operations a return can cause.
        Ghostty.logger.notice("control room: settle \(terminal, privacy: .public) -> \(String(describing: steps), privacy: .public)")
        for step in steps {
            switch step {
            case .makeKey:
                home.focusedSurface = view
                window.makeKeyAndOrderFront(nil)
            case .takeKeyboard:
                window.makeFirstResponder(view)
            }
        }
        home.syncFocusToSurfaceTree()
    }

    /// Whether the bar of `search`, appearing now, may take the keyboard:
    /// not when it appears only because its terminal changed views.
    func searchMayTakeKeyboard(_ search: Ghostty.SurfaceView.SearchState) -> Bool {
        movedSearches.mayTakeKeyboard(search)
    }

    func reclaim(_ view: Ghostty.SurfaceView) {
        guard isLent(view) else { return }
        onReclaim?(view)
    }

    /// A terminal controller's tree changed. If the lent terminal is in no
    /// tree once things have settled -- a move between trees takes it out of
    /// one before putting it in the other -- its home is gone.
    func treesChanged() {
        guard lent != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let lent = self.lent,
                  BaseTerminalController.controller(owning: lent) == nil else { return }
            if let terminal = Self.terminal(of: lent) { self.homecoming.cancelled(terminal) }
            self.onHomeGone?(lent)
        }
    }

    /// A terminal window is closing. Its tree is not emptied when it does,
    /// so this is the only word that the lent terminal's home went with it.
    func windowClosing(_ controller: BaseTerminalController) {
        guard let lent, controller.surfaceTree.contains(lent) else { return }
        onHomeGone?(lent)
    }

    private static let freezer = CIContext()

    /// A still, frosted copy of the frame `view` is showing now; nil when
    /// it has drawn none.
    ///
    /// The renderer hands each frame to the view's layer as its `contents`
    /// (`IOSurfaceLayer.setSurface`), one of a few surfaces it draws into
    /// in turn -- so the surface itself goes on changing. This copies it
    /// out (`ControlRoomElsewhere.frosted`).
    static func freeze(_ view: Ghostty.SurfaceView) -> CGImage? {
        guard let contents = view.layer?.contents,
              CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return nil }
        // Checked the line above.
        let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        return ControlRoomElsewhere.frosted(CIImage(ioSurface: surface), with: freezer)
    }

    /// The id the core gives a terminal, as the snapshot writes it; nil for
    /// a view with no terminal behind it.
    static func terminal(of view: Ghostty.SurfaceView) -> String? {
        guard let surface = view.surface else { return nil }
        let id = ghostty_surface_poltergeist_id(surface)
        return id == 0 ? nil : ControlRoomPulse.id(id)
    }

    /// The view of the terminal the core calls `terminal`, if a tab holds
    /// it. An equality test over what is open; nothing is worked out.
    static func surface(for terminal: String) -> Ghostty.SurfaceView? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            for view in controller.surfaceTree where Self.terminal(of: view) == terminal {
                return view
            }
        }
        return nil
    }

    /// Tell the core whether the terminal can be seen, as its own tab's
    /// controller would.
    static func setVisible(_ view: Ghostty.SurfaceView, _ visible: Bool) {
        guard let surface = view.surface, view.isWindowVisible != visible else { return }
        ghostty_surface_set_occlusion(surface, visible)
        view.isWindowVisible = visible
    }
}

extension Ghostty.SurfaceView {
    /// The window this terminal belongs to: its own tab's. The same as
    /// `window` except while the control room has borrowed the view.
    var homeWindow: NSWindow? {
        guard ControlRoomLender.shared.isLent(self) else { return window }
        return BaseTerminalController.controller(owning: self)?.window
    }
}

/// What a pane draws while its terminal is in the control room: where it
/// went, and one press to have it back.
struct ControlRoomLentPlaceholder: View {
    let surfaceView: Ghostty.SurfaceView
    /// The last frame it drew here (`ControlRoomLender.frozenAtHome`).
    let lastFrame: CGImage?

    var body: some View {
        ControlRoomElsewhere(
            frame: lastFrame,
            sentence: String(localized: "Showing in the control room", comment: "总控台：终端被借到总控台时，它自己那一格上的第一行：界面现在在哪"),
            action: ControlRoomElsewhere.switchHere,
            perform: { ControlRoomLender.shared.reclaim(surfaceView) })
    }
}
