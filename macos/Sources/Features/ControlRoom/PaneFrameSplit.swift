import Combine
import SwiftUI

/// The three frames, put round the panes of a terminal tab
/// (`control-room.md`, 12.6).
///
/// **Wrapped round the split view, not built into it.**
/// `TerminalSplitTreeView` is shared with upstream, so what it has from
/// here is two modifiers and one colour: `paneFrameScope` on the whole
/// tree, `paneFramed` on what a leaf shows, and the divider's colour.
/// Everything else -- the tree, the divider and its dragging, the drop
/// zones, zoom, the drag handle, the search bar, the placeholder of a
/// terminal lent to the control room -- is as it was, and with
/// `poltergeist-pane-frames = false` so is every pixel.
///
/// Which frame a pane wears and what its title says is `PaneFrame`, from
/// the core's snapshot. Here is only the wiring.

/// The snapshot's terminals, for every pane that is drawn.
///
/// One listener on the application's one feed, so a tab with eight panes
/// does not ask the core eight times. It publishes only when the list of
/// terminals is different from the last one: most snapshots change
/// something else, and those redraw no pane.
final class PaneFrameSource: ObservableObject {
    static let shared = PaneFrameSource()

    /// Nil until the core has a snapshot.
    @Published private(set) var terminals: [ControlRoomSnapshot.Terminal]?

    private var listening: AnyCancellable?

    /// Start listening. Asked for by every tab as it appears; only the
    /// first does anything.
    func attach(_ ghostty: Ghostty.App) {
        guard listening == nil else { return }
        listening = ControlRoomFeed.shared(ghostty).listen { [weak self] snapshot in
            guard let self, self.terminals != snapshot.terminals else { return }
            self.terminals = snapshot.terminals
        }
    }
}

private struct PaneFramePlaceKey: EnvironmentKey {
    /// Outside a scope nothing is framed.
    static let defaultValue = PaneFrame.Place(enabled: false, quickTerminal: false, alone: true)
}

private struct PaneFrameGroundKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Where the panes of this tab are, as far as a frame cares.
    var paneFramePlace: PaneFrame.Place {
        get { self[PaneFramePlaceKey.self] }
        set { self[PaneFramePlaceKey.self] = newValue }
    }

    /// Whether the tab's ground shows between its panes. The split view
    /// draws no divider line when it does: the gap is the divider.
    var paneFrameGround: Bool {
        get { self[PaneFrameGroundKey.self] }
        set { self[PaneFrameGroundKey.self] = newValue }
    }
}

/// Round the whole tree: says where its panes are, and lays the ground
/// they sit on when any of them is framed.
private struct PaneFrameScope: ViewModifier {
    typealias Look = ControlRoomLook

    let tree: SplitTree<Ghostty.SurfaceView>

    @EnvironmentObject private var ghostty: Ghostty.App
    @ObservedObject private var source = PaneFrameSource.shared
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        // What is showing: the zoomed pane when there is one.
        let showing = (tree.zoomed ?? tree.root)?.shownLeaves() ?? []
        let place = PaneFrame.Place(
            enabled: ghostty.config.poltergeistPaneFrames,
            quickTerminal: showing.first.map { BaseTerminalController.controller(owning: $0) is QuickTerminalController } ?? false,
            alone: showing.count == 1)
        let ground = PaneFrame.groundShows(showing.map {
            PaneFrame.drawn(terminal: ControlRoomLender.terminal(of: $0), ownName: $0.title, at: place, in: source.terminals)
        })
        content
            .environment(\.paneFramePlace, place)
            .environment(\.paneFrameGround, ground)
            // Each pane keeps half the gap on every side, so the window's
            // edge is owed the rest.
            .padding(ground ? CGFloat(Look.Space.windowEdge) - PaneFrameSplit.inset : 0)
            .background(ground ? Look.theme(scheme).windowBase.color : Color.clear)
            .onAppear { source.attach(ghostty) }
    }
}

/// Round what one leaf shows.
private struct PaneFramed: ViewModifier {
    typealias Look = ControlRoomLook

    let surfaceView: Ghostty.SurfaceView

    @EnvironmentObject private var ghostty: Ghostty.App
    @ObservedObject private var source = PaneFrameSource.shared
    @Environment(\.paneFramePlace) private var place
    @Environment(\.paneFrameGround) private var ground
    @Environment(\.ghosttyLastFocusedSurface) private var lastFocused
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let drawn = PaneFrame.drawn(
            terminal: ControlRoomLender.terminal(of: surfaceView), ownName: surfaceView.title,
            at: place, in: source.terminals)
        // **One chain, whatever the pane wears** -- never a choice between a
        // framed pane and a bare one: see `PaneFrameChrome` for what a
        // choice here did to the terminal (task 1461). A pane with nothing
        // of its own whose neighbours are framed keeps the same gap; with
        // no ground it is as it ever was.
        content.modifier(PaneFrameChrome(
            wears: drawn?.wears, title: drawn?.title, caption: nil,
            focused: lastFocused?.value === surfaceView,
            well: ghostty.config.backgroundColor,
            cover: Look.theme(scheme).windowBase.color,
            outside: drawn != nil || ground ? PaneFrameSplit.inset : 0))
    }
}

enum PaneFrameSplit {
    /// What each pane keeps clear on every side: half the gap between two
    /// frames, less half of the divider's own width, which the split view
    /// puts between them.
    static let inset = (CGFloat(ControlRoomLook.Space.betweenFrames) - dividerWidth) / 2
    /// `SplitView.splitterVisibleSize`.
    static let dividerWidth: CGFloat = 1
}

extension View {
    /// On the whole split tree of a tab.
    func paneFrameScope(_ tree: SplitTree<Ghostty.SurfaceView>) -> some View {
        modifier(PaneFrameScope(tree: tree))
    }

    /// On what one leaf of it shows.
    func paneFramed(_ surfaceView: Ghostty.SurfaceView) -> some View {
        modifier(PaneFramed(surfaceView: surfaceView))
    }
}
