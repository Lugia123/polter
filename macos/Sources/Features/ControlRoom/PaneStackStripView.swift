import AppKit
import SwiftUI

/// What pressing something on a stack's strip does. **Nothing yet**: there
/// is no stack to act on (`control-room.md`, 12.6.2), so these are where
/// the wiring will go and are empty until then.
struct PaneStackActions {
    /// A tab was pressed: the index of its member.
    var select: (Int) -> Void = { _ in }
    /// The plus was pressed.
    var add: () -> Void = {}
    /// `more` was pressed: the members there was no room to draw.
    var more: ([Int]) -> Void = { _ in }
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

    // MARK: Measuring

    static func nameFont(current: Bool) -> NSFont {
        .monospacedSystemFont(ofSize: CGFloat(Look.Font.body),
                              weight: current ? .semibold : .regular)
    }

    /// How wide a tab's body wants to be: its name at the heavier of its
    /// two weights, and room for a glyph whether or not it has one just
    /// now, between the paddings -- so that a tab is the same width in
    /// front and behind, waiting and not, and the strip does not shuffle
    /// each time a terminal's status changes. (The design's `e2e`, which
    /// has no glyph, is as wide as if it had: 68.)
    static func wanted(_ member: PaneStack.Member) -> CGFloat {
        let name = (member.name as NSString).size(withAttributes: [.font: nameFont(current: true)]).width
        return 2 * CGFloat(Look.StackTab.paddingX) + name.rounded(.up)
            + CGFloat(Look.StackTab.gap) + CGFloat(Look.Side.glyph)
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
            ZStack(alignment: .topLeading) {
                if !bare, let front = layout.tabs.first(where: \.current) {
                    PaneStackTabShape(corner: CGFloat(Look.StackTab.cornerRadius),
                                      foot: CGFloat(Look.StackTab.reverseArcRadius),
                                      below: CGFloat(Look.StackTab.overlapBelow))
                        .path(in: CGRect(x: front.x, y: top, width: front.width, height: tabH))
                        .fill(well)
                        .allowsHitTesting(false)
                }
                ForEach(layout.tabs, id: \.member) { tab in
                    if tab.separatorBefore {
                        theme.stackTabSeparator.color
                            .frame(width: CGFloat(Look.Line.hairline), height: CGFloat(Look.StackTab.separatorHeight))
                            .offset(x: tab.x - CGFloat(Look.Line.hairline) / 2,
                                    y: top + (tabH - CGFloat(Look.StackTab.separatorHeight)) / 2)
                    }
                    self.tab(stack.members[tab.member], current: tab.current)
                        .frame(width: tab.width, height: tabH)
                        .contentShape(Rectangle())
                        .onTapGesture { actions.select(tab.member) }
                        .offset(x: tab.x, y: top)
                }
                if let moreX = layout.moreX {
                    more(layout).offset(x: moreX, y: top)
                }
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
        }
        .frame(height: CGFloat(Look.StackTab.stripHeight))
        .font(.system(size: CGFloat(Look.Font.body)))
        // Over what is under it: the tab in front runs a hair past its
        // foot, across the line the content has along its top.
        .zIndex(1)
    }

    /// One tab: its name at the left, its glyph at the right.
    private func tab(_ member: PaneStack.Member, current: Bool) -> some View {
        HStack(spacing: 0) {
            Text(member.name)
                .font(Font(Self.nameFont(current: current)))
                .foregroundStyle(current ? currentInk : otherInk)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: CGFloat(Look.StackTab.gap))
            // The glyph's place is kept when there is none to draw.
            Color.clear
                .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
                .overlay {
                    if member.shown != .none {
                        ControlRoomGlyph(shown: member.shown, still: still)
                    }
                }
        }
        .padding(.horizontal, CGFloat(Look.StackTab.paddingX))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(member.name)
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
    }

    /// `more`: the dots, and beside them the glyph of the most pressing
    /// terminal behind them -- the core's choice of which
    /// (`PaneStackStripLayout.behindMore`). The glyph's place is kept when
    /// there is none.
    private func more(_ layout: Layout) -> some View {
        let label = String(localized: "More tabs", comment: "分屏框：层叠标签条上排不下的标签收在这个按钮后面")
        let behind = layout.behindMore(urgent: stack.urgent).map { stack.members[$0] }
        return Button {
            actions.more(layout.hidden)
        } label: {
            HStack(spacing: CGFloat(Look.StackTab.moreGlyphGap)) {
                Image(systemName: "ellipsis")
                    .font(.system(size: CGFloat(Look.Font.body)))
                    .foregroundStyle(otherInk)
                    .frame(width: CGFloat(Look.Side.glyph))
                Color.clear
                    .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
                    .overlay {
                        if let behind {
                            ControlRoomGlyph(shown: behind.shown, still: still)
                        }
                    }
            }
            .frame(width: CGFloat(Look.StackTab.moreButton), height: CGFloat(Look.StackTab.height))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(behind.map { "\(label): \($0.name)" } ?? label)
        .accessibilityLabel(behind.map { "\(label), \($0.name)" } ?? label)
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
            // Held is not a status and has no colour of its own: drawn as
            // the frame's own title draws it (`PaneFrameTitleBar.status`).
            if let status = title.shown.status {
                ControlRoomGlyph(shown: status, still: still)
            } else {
                PaneHeldGlyph()
                    .fill(otherInk)
                    .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
                    .accessibilityHidden(true)
            }
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
