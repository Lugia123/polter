import Combine
import SwiftUI
import UniformTypeIdentifiers

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
/// `poltergeist-pane-frames = false` so is every pixel -- but the line just
/// inside a supervisor's pane (`PaneFrame.edged`, task 1692).
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

private struct SurfaceInControlRoomKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PaneHoldsStackKey: EnvironmentKey {
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

    /// Whether the pane this is inside holds a stack. It is picked up by
    /// its tabs and has no handle (task 1582).
    var paneHoldsStack: Bool {
        get { self[PaneHoldsStackKey.self] }
        set { self[PaneHoldsStackKey.self] = newValue }
    }

    /// Whether the terminal this is inside is the one shown on the control
    /// room's right-hand side. Nothing there is dragged (task 1566).
    var surfaceInControlRoom: Bool {
        get { self[SurfaceInControlRoomKey.self] }
        set { self[SurfaceInControlRoomKey.self] = newValue }
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
    /// The colours of this pane and of a stack's members, as their surfaces
    /// last said (task 1699): kept here so a change redraws the frame, which
    /// does not observe the surfaces themselves.
    @State private var colours: [UUID: PaneColor] = [:]

    func body(content: Content) -> some View {
        let colourOf = { (view: Ghostty.SurfaceView) in colours[view.id] ?? view.poltergeistPaneColor }
        let drawn = PaneFrame.drawn(
            terminal: ControlRoomLender.terminal(of: surfaceView), ownName: surfaceView.title,
            at: place, in: source.terminals).map { framed -> PaneFrame.Drawn in
                var coloured = framed
                coloured.title.color = colourOf(surfaceView)
                return coloured
            }
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
                    .init(terminal: ControlRoomLender.terminal(of: $0), ownName: $0.title, color: colourOf($0))
                },
                shown: members.members.firstIndex { $0.id == members.shown } ?? 0,
                terminals: source.terminals, pulses: source.waiting)
        }
        let outside = drawn != nil || ground ? PaneFrameSplit.inset : 0
        // With no frames, a supervisor's pane still says it is one: a line
        // just inside it, over the terminal's own padding (task 1692). A
        // stack always wears a frame, so it never has this.
        // And any pane given a colour says which, the same way (task 1699).
        let edge = stack == nil ? PaneFrame.edge(
            terminal: ControlRoomLender.terminal(of: surfaceView), at: place, in: source.terminals,
            color: colourOf(surfaceView)) : nil
        // The title is where the pane is picked up (task 1508) -- except
        // over a stack, where that band is the strip and the pane is picked
        // up by its tabs, one terminal at a time (task 1582). Neither keeps
        // the terminal's own handle.
        let grip = stack == nil ? drawn : nil
        let focused = lastFocused?.value === surfaceView
        let lent = lender.lentID == surfaceView.id
        // Under the pointer only, as the window's own tabs (task 1642).
        let closeShows = grip != nil && !lent && PolterPaneTabRules.closeShows(hovering: titleHovered)
        content
            .environment(\.paneHasTitle, grip != nil)
            .environment(\.paneHoldsStack, stack != nil)
            .modifier(PaneFrameChrome(
                wears: stack.map(PaneStackRules.wears) ?? drawn?.wears,
                title: stack.map { PaneStackRules.title($0, framed: drawn?.title) } ?? drawn?.title,
                caption: nil,
                focused: focused,
                well: ghostty.config.backgroundColor,
                cover: Look.theme(scheme).windowBase.color,
                outside: outside,
                stack: stack,
                stackActions: actions(members: members),
                closeHole: closeShows))
            .modifier(PaneSupervisorEdge(color: edge))
            .onReceive(Publishers.MergeMany(((members?.members) ?? [surfaceView]).map { view in
                view.$poltergeistPaneColor.map { (view.id, $0) }
            })) { id, colour in
                if colours[id] != colour { colours[id] = colour }
            }
            // A layer over the title band, and nothing round what is framed:
            // what picks the pane up and opens its menu, and its close
            // button at the left end, over the name (tasks 1582, 1642).
            .overlay(alignment: .top) {
                if let grip {
                    let band = PaneFrameChrome.room(for: grip.wears).top
                    let button = PolterCloseCircle.frame(textLeading: PaneFrameChrome.barPadding(for: grip.wears), height: band)
                    ZStack(alignment: .leading) {
                        Ghostty.SurfaceTitleGrip(
                            surfaceView: surfaceView,
                            dragHandle: ghostty.config.dragHandle,
                            lent: lent,
                            menu: lent ? nil : { [weak surfaceView] in
                                guard let surfaceView else { return nil }
                                return (BaseTerminalController.controller(owning: surfaceView) as? TerminalController)?
                                    .polterPaneMenu(for: surfaceView, inStack: false)
                            },
                            // The cross below is a button: an arrow over it,
                            // not the hand (task 1634).
                            leadingButton: lent ? nil : .init(size: button.width, padding: button.minX))
                        if closeShows {
                            PolterCloseCircleButton { close(surfaceView) }
                                .padding(.leading, button.minX)
                        }
                    }
                    .frame(height: band)
                    .onHover { titleHovered = $0 }
                    .padding(outside)
                }
            }
    }

    /// The pointer is over this pane's title, for its close button.
    @State private var titleHovered = false

    /// Close one terminal by the path a key would: the core asks first
    /// when something is running (`close_surface`).
    private func close(_ view: Ghostty.SurfaceView) {
        BaseTerminalController.controller(owning: view)?.performAction("close_surface", on: view)
    }

    /// What pressing the strip does: each is the tab's own controller's,
    /// found by the terminal this pane shows.
    private func actions(members: SplitTree<Ghostty.SurfaceView>.Stack?) -> PaneStackActions {
        guard let members else { return PaneStackActions() }
        let view = surfaceView
        let select: (Int) -> Void = { index in
            guard members.members.indices.contains(index) else { return }
            BaseTerminalController.controller(owning: view)?.showStackMember(members.members[index])
        }
        let dragHandle = ghostty.config.dragHandle
        let lent = lender.lentID == surfaceView.id
        return PaneStackActions(
            select: select,
            add: {
                BaseTerminalController.controller(owning: view)?.stackNewTerminal(onto: view)
            },
            close: { index in
                guard members.members.indices.contains(index) else { return }
                close(members.members[index])
            },
            grip: { index in
                guard members.members.indices.contains(index) else { return AnyView(Color.clear) }
                let member = members.members[index]
                return AnyView(Ghostty.PolterStackTabGrip(
                    surfaceView: member,
                    dragHandle: dragHandle,
                    lent: lent,
                    inControlRoom: false,
                    select: { select(index) },
                    menu: { [weak member] in
                        guard let member else { return nil }
                        return (BaseTerminalController.controller(owning: member) as? TerminalController)?
                            .polterPaneMenu(for: member, inStack: true)
                    },
                    // The tab's close button (`PaneStackStripView.tab`), tasks 1634, 1642.
                    leadingButton: {
                        let button = PolterCloseCircle.frame(textLeading: CGFloat(ControlRoomLook.StackTab.paddingX),
                                                             height: CGFloat(ControlRoomLook.StackTab.height))
                        return .init(size: button.width, padding: button.minX)
                    }()))
            },
            dropTypes: [.ghosttySurfaceId],
            drop: { index, provider in
                _ = provider.loadTransferable(type: Ghostty.SurfaceView.self) { result in
                    guard case .success(let source) = result else { return }
                    DispatchQueue.main.async {
                        BaseTerminalController.controller(owning: view)?.polterDrop(source, onStackOf: view, at: index)
                    }
                }
                return true
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
