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

    /// The terminals that are waiting for the person, most pressing
    /// first: the core's order (`pulses`). What a stack's strip goes by to
    /// say that somebody behind its `more` is waiting.
    @Published private(set) var waiting: [String] = []

    private var listening: AnyCancellable?

    /// Start listening. Asked for by every tab as it appears; only the
    /// first does anything.
    func attach(_ ghostty: Ghostty.App) {
        guard listening == nil else { return }
        listening = ControlRoomFeed.shared(ghostty).listen { [weak self] snapshot in
            guard let self else { return }
            let waiting = (snapshot.pulses ?? []).map(\.terminal)
            if self.waiting != waiting { self.waiting = waiting }
            guard self.terminals != snapshot.terminals else { return }
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

private struct PaneHasTitleKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PaneFrameTreeKey: EnvironmentKey {
    /// Outside a scope no pane holds a stack.
    static let defaultValue: SplitTree<Ghostty.SurfaceView>? = nil
}

extension EnvironmentValues {
    /// Where the panes of this tab are, as far as a frame cares.
    var paneFramePlace: PaneFrame.Place {
        get { self[PaneFramePlaceKey.self] }
        set { self[PaneFramePlaceKey.self] = newValue }
    }

    /// The tree the panes of this tab are in: where a pane finds the
    /// terminals stacked behind the one it shows.
    var paneFrameTree: SplitTree<Ghostty.SurfaceView>? {
        get { self[PaneFrameTreeKey.self] }
        set { self[PaneFrameTreeKey.self] = newValue }
    }

    /// Whether the tab's ground shows between its panes. The split view
    /// draws no divider line when it does: the gap is the divider.
    var paneFrameGround: Bool {
        get { self[PaneFrameGroundKey.self] }
        set { self[PaneFrameGroundKey.self] = newValue }
    }

    /// Whether the pane this is inside wears a title. It is then picked up
    /// by the title, and the terminal draws no drag handle (task 1508).
    var paneHasTitle: Bool {
        get { self[PaneHasTitleKey.self] }
        set { self[PaneHasTitleKey.self] = newValue }
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
            .environment(\.paneFrameTree, place.quickTerminal ? nil : tree)
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
    @ObservedObject private var lender = ControlRoomLender.shared
    @Environment(\.paneFramePlace) private var place
    @Environment(\.paneFrameGround) private var ground
    @Environment(\.paneFrameTree) private var tree
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
        //
        // The same for a stack: a pane that holds one hands the chain the
        // stack, and what changes is what the chain's top layer draws --
        // the tabs in place of the title. A stacked pane always wears a
        // frame, an ordinary terminal's included
        // (`PaneStackRules.Choices`): without the strip nothing reaches
        // the terminals behind.
        let members = tree?.stack(of: surfaceView)
        let stack = members.map { members in
            PaneStackRules.stack(
                members: members.members.map {
                    .init(terminal: ControlRoomLender.terminal(of: $0), ownName: $0.title)
                },
                shown: members.members.firstIndex { $0.id == members.shown } ?? 0,
                terminals: source.terminals, pulses: source.waiting)
        }
        let outside = drawn != nil || ground ? PaneFrameSplit.inset : 0
        // The title is where the pane is picked up (task 1508) -- except
        // over a stack, where that band is the strip and its tabs have to
        // take the clicks. Such a pane keeps the terminal's own handle.
        let grip = stack == nil ? drawn : nil
        content
            .environment(\.paneHasTitle, grip != nil)
            .modifier(PaneFrameChrome(
                wears: stack.map(PaneStackRules.wears) ?? drawn?.wears,
                title: stack.map { PaneStackRules.title($0, framed: drawn?.title) } ?? drawn?.title,
                caption: nil,
                focused: lastFocused?.value === surfaceView,
                well: ghostty.config.backgroundColor,
                cover: Look.theme(scheme).windowBase.color,
                outside: outside,
                stack: stack,
                stackActions: actions(members: members, names: stack?.members.map(\.name) ?? [])))
            // A layer over the title band, and nothing round what is framed.
            .overlay(alignment: .top) {
                if let grip {
                    Ghostty.SurfaceTitleGrip(
                        surfaceView: surfaceView,
                        dragHandle: ghostty.config.dragHandle,
                        lent: lender.lentID == surfaceView.id)
                    .frame(height: PaneFrameChrome.room(for: grip.wears).top)
                    .padding(outside)
                }
            }
    }

    /// What pressing the strip does: each is the tab's own controller's,
    /// found by the terminal this pane shows.
    private func actions(
        members: SplitTree<Ghostty.SurfaceView>.Stack?, names: [String]
    ) -> PaneStackActions {
        guard let members else { return PaneStackActions() }
        let view = surfaceView
        return PaneStackActions(
            select: { index in
                guard members.members.indices.contains(index) else { return }
                BaseTerminalController.controller(owning: view)?.showStackMember(members.members[index])
            },
            add: {
                BaseTerminalController.controller(owning: view)?.stackNewTerminal(onto: view)
            },
            more: { hidden in
                BaseTerminalController.controller(owning: view)?
                    .presentStackMenu(of: view, members: hidden, names: names)
            })
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
