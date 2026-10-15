import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What pressing something on a stack's strip does: each is the tab's
/// own controller's, handed in by the split view that knows the terminals
/// (`PaneFrameSplit`). This file sees only indices.
struct PaneStackActions {
    /// A tab was pressed: the index of its member.
    var select: (Int) -> Void = { _ in }
    /// The plus was pressed.
    var add: () -> Void = {}
    /// A tab's close button was pressed (task 1582).
    var close: (Int) -> Void = { _ in }
    /// What a tab is picked up and right-clicked by, laid behind it: the
    /// member's drag source, which clicks through to `select` and opens the
    /// tab's menu (task 1582). Nil draws a tab that is only clicked.
    var grip: ((Int) -> AnyView)?
    /// A terminal let go on the strip, to go in at that place among the
    /// tabs (task 1582). `types` is what it accepts; the answer is whether
    /// it was taken.
    var dropTypes: [UTType] = []
    var drop: (Int, NSItemProvider) -> Bool = { _, _ in false }
}

/// The body of the tab in front: round at the top, and at the foot an arc
/// on each side turning outward into the content below it, so that the tab
/// and the content are one piece of the same ground with no line between
/// (the design's `07-tab-corners`). The rectangle it is given is the tab's
/// body; the feet reach `foot` further out on each side, and the fill runs
/// `below` past the bottom to cover whatever line the content has there.
struct PaneStackTabShape: Shape {
    var corner: CGFloat
    var foot: CGFloat
    var below: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        path.move(to: CGPoint(x: left - foot, y: bottom))
        path.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: bottom - foot), radius: foot)
        path.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left + corner, y: top), radius: corner)
        path.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: top + corner), radius: corner)
        path.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right + foot, y: bottom), radius: foot)
        path.addLine(to: CGPoint(x: right + foot, y: bottom))
        path.addLine(to: CGPoint(x: right + foot, y: bottom + below))
        path.addLine(to: CGPoint(x: left - foot, y: bottom + below))
        path.closeSubpath()
        return path
    }
}

/// The strip of tabs that stands where a frame's title would, when the
/// pane holds a stack (`control-room.md`, 12.6.2; the design's `06-panes`,
/// top right).
///
/// It draws a `PaneStack` where `PaneStackStripLayout` says, and decides
/// nothing: which tab is in front, which glyph each carries and what the
/// status at the right says are all handed in. Every size and colour is
/// `ControlRoomLook`'s.
///
/// - **supervisor**: the strip is the frame's thickened top edge; the tab
///   in front is the terminal's ground coming up into it.
/// - **worker**: the strip is the title band. This is the one the design
///   drew.
/// - **plain**: the design drew none. `PaneStack.plainStyle` picks between
///   the two candidates.
struct PaneStackStripView: View {
    typealias Look = ControlRoomLook
    typealias Layout = PaneStackStripLayout

    var stack: PaneStack
    /// The frame this strip is the top of: the showing member's.
    var wears: PaneFrame.Kind
    /// The status at the right end: the showing member's glyph and word.
    var title: PaneFrame.Title?
    /// The ground of what is under the strip, which the tab in front is a
    /// piece of.
    var well: Color
    var actions = PaneStackActions()
    /// Stops every motion. For still pictures.
    var still: Bool = false

    @Environment(\.colorScheme) private var scheme

    private var theme: Look.Theme { Look.theme(scheme) }

    /// No band and no tab shape: an ordinary terminal's second candidate.
    private var bare: Bool { wears == .plain && stack.plainStyle == .bare }

    /// How far the tabs are scrolled, 0 for not at all (task 1582).
    @State private var offset: CGFloat = 0
    /// The person scrolled the tabs with the wheel since the tab in front,
    /// the number of tabs or the strip's width last changed (task 1599).
    @State private var wheeled = false

    /// The tab the pointer is over, for its close button.
    @State private var hovered: Int?
    /// Where a terminal being dragged over the strip would go in.
    @State private var dropAt: Int?

    // MARK: Measuring

    static func nameFont(current: Bool) -> NSFont {
        .monospacedSystemFont(ofSize: CGFloat(Look.Font.body),
                              weight: current ? .semibold : .regular)
    }

    static func roleFont() -> NSFont {
        .systemFont(ofSize: CGFloat(Look.Font.body))
    }

    /// How wide a tab's body wants to be: its name at the heavier of its
    /// two weights and the word for what it is, and room for a glyph and
    /// for the close button whether or not either is there just now,
    /// between the paddings -- so that a tab is the same width in front and
    /// behind, waiting and not, pointed at and not, and the strip does not
    /// shuffle.
    static func wanted(_ member: PaneStack.Member) -> CGFloat {
        let t = Look.StackTab.self
        var name = (member.name as NSString).size(withAttributes: [.font: nameFont(current: true)]).width.rounded(.up)
        if let role = member.role {
            name += CGFloat(Look.Pane.nameRoleGap)
                + (role as NSString).size(withAttributes: [.font: roleFont()]).width.rounded(.up)
        }
        return 2 * CGFloat(t.paddingX) + name + CGFloat(t.gap) + CGFloat(Look.Side.glyph)
            + CGFloat(t.closeGap) + CGFloat(t.closeButton)
    }

    /// How wide the status at the right end is: the glyph, the gap, the word.
    static func statusWidth(_ title: PaneFrame.Title?) -> CGFloat {
        guard let title, title.shown != .none || !title.word.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: CGFloat(Look.Font.body), weight: .semibold)
        let word = (title.word as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        return CGFloat(Look.Side.glyph) + CGFloat(Look.Side.statusWordGap) + word
    }

    // MARK: Drawing

    var body: some View {
        GeometryReader { proxy in
            let layout = Layout(wants: stack.members.map(Self.wanted), current: stack.current,
                                width: proxy.size.width, status: Self.statusWidth(title),
                                minWidth: stack.minTabWidth ?? CGFloat(Look.StackTab.minWidth))
            let tabH = CGFloat(Look.StackTab.height)
            let top = CGFloat(Look.StackTab.stripHeight) - tabH
            let foot = CGFloat(Look.StackTab.reverseArcRadius)
            // **Where the tabs are drawn, worked out on every render**
            // (`settle`, task 1599): the tab in front is kept in sight
            // whenever the tabs change -- a name that comes later widens
            // one -- unless the person has scrolled them since the tab in
            // front, the number of tabs or the width last changed. Kept in
            // `offset` it went stale: a change to a name alone was never
            // seen (poltertest, #1599).
            let shown = layout.settle(stack.current, from: offset, changed: false, wheeled: wheeled)
            ZStack(alignment: .topLeading) {
                row(layout, shown: shown, top: top, tabH: tabH, foot: foot)
                    .offset(x: CGFloat(Look.StackTab.inset) - foot)
                button("plus", label: String(localized: "Add a terminal to this pane", comment: "分屏框：层叠标签条末尾的加号")) {
                    actions.add()
                }
                .offset(x: layout.addX, y: top)
                if let status = layout.status, let title {
                    self.status(title)
                        .frame(width: status.upperBound - status.lowerBound, height: tabH, alignment: .trailing)
                        .offset(x: status.lowerBound, y: top)
                }
            }
            // One of the three changed: the wheel's place no longer holds,
            // and the tab in front comes into view -- moved there, so the
            // move can be animated.
            .onChange(of: Reveal(current: stack.current, count: stack.members.count, width: proxy.size.width)) { _ in
                wheeled = false
                let to = layout.revealing(stack.current, from: offset)
                if to != offset {
                    if still { offset = to } else { withAnimation(.easeOut(duration: 0.2)) { offset = to } }
                }
            }
        }
        .frame(height: CGFloat(Look.StackTab.stripHeight))
        .font(.system(size: CGFloat(Look.Font.body)))
        // Over what is under it: the tab in front runs a hair past its
        // foot, across the line the content has along its top.
        .zIndex(1)
    }

    private struct Reveal: Equatable {
        var current: Int
        var count: Int
        var width: CGFloat
    }

    /// The row of tabs, seen through the room the layout gives it: a
    /// window as wide as `viewport`, and a foot's width more on each side
    /// so that the tab in front keeps its feet at either end. It scrolls
    /// sideways when the tabs are wider than the window (task 1582); what
    /// is past an edge fades out there, and a terminal waiting past an edge
    /// shows its glyph at that edge.
    private func row(_ layout: Layout, shown offset: CGFloat, top: CGFloat, tabH: CGFloat, foot: CGFloat) -> some View {
        let shift = foot - offset
        let beyond = layout.beyond(urgent: stack.urgent, offset: offset)
        return ZStack(alignment: .topLeading) {
            if !bare, let front = layout.tabs.first(where: \.current) {
                PaneStackTabShape(corner: CGFloat(Look.StackTab.cornerRadius),
                                  foot: foot,
                                  below: CGFloat(Look.StackTab.overlapBelow))
                    .path(in: CGRect(x: front.x - CGFloat(Look.StackTab.inset) + shift, y: top, width: front.width, height: tabH))
                    .fill(well)
                    .allowsHitTesting(false)
            }
            ForEach(layout.tabs, id: \.member) { tab in
                let x = tab.x - CGFloat(Look.StackTab.inset) + shift
                if tab.separatorBefore {
                    theme.stackTabSeparator.color
                        .frame(width: CGFloat(Look.Line.hairline), height: CGFloat(Look.StackTab.separatorHeight))
                        .offset(x: x - CGFloat(Look.Line.hairline) / 2,
                                y: top + (tabH - CGFloat(Look.StackTab.separatorHeight)) / 2)
                        .allowsHitTesting(false)
                }
                self.tab(stack.members[tab.member], index: tab.member, current: tab.current)
                    .frame(width: tab.width, height: tabH)
                    .offset(x: x, y: top)
            }
            if let at = dropAt {
                // Where a terminal let go now would go in.
                let x = (at < layout.tabs.count ? layout.tabs[at].x : CGFloat(Look.StackTab.inset) + layout.content)
                    - CGFloat(Look.StackTab.inset) + shift
                theme.text.color
                    .frame(width: 2, height: tabH - 8)
                    .offset(x: x - 1, y: top + 4)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: layout.viewport + 2 * foot, height: CGFloat(Look.StackTab.stripHeight), alignment: .topLeading)
        .clipped()
        .mask(fade(left: offset > 0.5, right: offset < layout.maxOffset - 0.5, foot: foot))
        .overlay(alignment: .topLeading) {
            edge(beyond.left, x: foot, top: top, tabH: tabH)
        }
        .overlay(alignment: .topTrailing) {
            edge(beyond.right, x: -foot, top: top, tabH: tabH)
        }
        .background {
            PolterWheelCatcher { delta in
                // From where the tabs are drawn, which `offset` is not while
                // the tab in front is being kept in sight.
                self.offset = min(max(offset + delta, 0), layout.maxOffset)
                wheeled = true
            }
        }
        .onDrop(of: actions.dropTypes, delegate: StripDrop(
            dropAt: $dropAt,
            types: actions.dropTypes,
            index: { x in layout.insertion(atRowX: x - foot + offset) },
            perform: actions.drop))
    }

    /// What fades the row out at an end that has more of it past the edge.
    private func fade(left: Bool, right: Bool, foot: CGFloat) -> some View {
        let w = CGFloat(Look.StackTab.scrollFade)
        return HStack(spacing: 0) {
            if left {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: foot + w)
            }
            Color.black
            if right {
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: foot + w)
            }
        }
    }

    /// The glyph of a terminal waiting past an edge, at that edge.
    @ViewBuilder
    private func edge(_ member: Int?, x: CGFloat, top: CGFloat, tabH: CGFloat) -> some View {
        if let member, stack.members.indices.contains(member) {
            glyph(stack.members[member].shown)
                .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
                .offset(x: x, y: top + (tabH - CGFloat(Look.Side.glyph)) / 2)
                .help(stack.members[member].name)
                .allowsHitTesting(false)
        }
    }

    /// One tab: its name and what it is at the left, its glyph and its
    /// close button at the right. What it is picked up and right-clicked
    /// by lies behind it (`PaneStackActions.grip`).
    private func tab(_ member: PaneStack.Member, index: Int, current: Bool) -> some View {
        let closeLabel = String(localized: "Close Terminal", comment: "分屏标题和层叠标签右端的 x；层叠标签右键菜单：关闭这一个终端")
        return ZStack {
            if let grip = actions.grip {
                grip(index)
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { actions.select(index) }
            }
            HStack(spacing: 0) {
                HStack(spacing: CGFloat(Look.Pane.nameRoleGap)) {
                    Text(member.name)
                        .font(Font(Self.nameFont(current: current)))
                        .foregroundStyle(current ? currentInk : otherInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if let role = member.role {
                        Text(role)
                            .font(Font(Self.roleFont()))
                            .foregroundStyle(otherInk)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: CGFloat(Look.StackTab.gap))
                // The glyph's place is kept when there is none to draw.
                Color.clear
                    .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
                    .overlay { glyph(member.shown) }
                Color.clear.frame(width: CGFloat(Look.StackTab.closeGap) + CGFloat(Look.StackTab.closeButton), height: 1)
            }
            .padding(.horizontal, CGFloat(Look.StackTab.paddingX))
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            // The close button: under the pointer, and always on the tab in
            // front (`PolterPaneTabRules.closeShows`).
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if PolterPaneTabRules.closeShows(hovering: hovered == index, current: current) {
                    Button { actions.close(index) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: CGFloat(Look.Font.body) - 2, weight: .semibold))
                            .foregroundStyle(otherInk)
                            .frame(width: CGFloat(Look.StackTab.closeButton), height: CGFloat(Look.StackTab.closeButton))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(closeLabel)
                    .accessibilityLabel(closeLabel)
                }
            }
            .padding(.trailing, CGFloat(Look.StackTab.paddingX))
        }
        .onHover { inside in
            if inside { hovered = index } else if hovered == index { hovered = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(member.name)
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
    }

    /// A status glyph, or the mark for a terminal that is held -- drawn as
    /// a frame's title draws it (`PaneFrameBar.status`).
    @ViewBuilder
    private func glyph(_ shown: ControlRoomSnapshot.Terminal.Bar.Shown) -> some View {
        switch PaneStackStatusGlyph(shown) {
        case .status(let status):
            if status != .none {
                ControlRoomGlyph(shown: status, still: still)
            }
        case .held:
            PaneHeldGlyph()
                .fill(otherInk)
                .accessibilityHidden(true)
        }
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: CGFloat(Look.Font.body)))
                .foregroundStyle(otherInk)
                .frame(width: CGFloat(Look.StackTab.addButton), height: CGFloat(Look.StackTab.height))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    /// The showing member's status, as a frame's title bar writes it.
    private func status(_ title: PaneFrame.Title) -> some View {
        HStack(spacing: CGFloat(Look.Side.statusWordGap)) {
            glyph(title.shown)
                .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
            Text(title.word)
                .fontWeight(Look.weight(Look.Font.weightEmphasis))
                .foregroundStyle(wordInk(title.shown))
                .lineLimit(1)
                .fixedSize()
        }
        .monospacedDigit()
    }

    // MARK: Colours

    /// The name of the tab in front: the frame's own text in a
    /// supervisor's border, the terminal's bold on the other two.
    private var currentInk: Color {
        wears == .supervisor ? theme.text.color : theme.terminalBold.color
    }

    /// Every other name, the plus and `more`: a step back.
    private var otherInk: Color {
        wears == .supervisor ? theme.textSecondary.color : theme.terminalDim.color
    }

    /// The status word, by the table: where a red word is not red is its
    /// to say.
    private func wordInk(_ shown: ControlRoomSnapshot.Terminal.Bar.Shown) -> Color {
        switch shown {
        case .needsYou, .doneUnseen:
            return theme.attentionText.color
        case .trouble:
            switch wears {
            case .supervisor: return theme.problemTextOnSupervisorBar.color
            case .worker: return theme.problemTextOnWorkerBand.color
            case .plain: return bare ? theme.problemTextOnTerminal.color : theme.problemTextOnWorkerBand.color
            }
        case .working, .none, .held:
            return otherInk
        }
    }
}

/// A terminal dragged over a stack's strip: where it would go in, and what
/// happens when it is let go (task 1582).
private struct StripDrop: DropDelegate {
    @Binding var dropAt: Int?
    let types: [UTType]
    /// The place among the tabs for a point along the row's window.
    let index: (CGFloat) -> Int
    let perform: (Int, NSItemProvider) -> Bool

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropAt = index(info.location.x)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        dropAt = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let at = index(info.location.x)
        dropAt = nil
        guard let provider = info.itemProviders(for: types).first else { return false }
        return perform(at, provider)
    }
}

/// Turns the wheel over a stack's strip into a sideways scroll of its tabs
/// (task 1582): a trackpad's sideways swipe as it is, and a mouse wheel's
/// up and down turned sideways (`PolterPaneTabRules.scroll`). It takes no
/// click -- the tabs over it do -- and listens only while it is on screen.
struct PolterWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: (CGFloat) -> Void = { _ in }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let delta = PolterPaneTabRules.scroll(
                    deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                    precise: event.hasPreciseScrollingDeltas)
                guard delta != 0 else { return event }
                self.onScroll(delta)
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
