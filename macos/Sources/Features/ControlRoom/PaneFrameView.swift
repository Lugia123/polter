import SwiftUI

/// One of the three frames a pane wears (`control-room.md`, 12.6; the
/// design's `06-panes`), round whatever is put in it.
///
/// - **supervisor**: a border all round, its top edge thickened into the
///   title bar, floating over the ground; the line round it deepens while
///   what is inside has the keyboard.
/// - **worker**: a line all round and a band for the title, with no line
///   under the band. It does not float.
/// - **plain**: no line and no band. The title is written on the
///   terminal's own ground.
///
/// The control room's right-hand side and every pane of a split terminal
/// tab draw this one view. Every size and colour is `ControlRoomLook`'s;
/// which of the three, and what the title says, is the core's
/// (`PaneFrame`).
struct PaneFrameView<Content: View>: View {
    var wears: PaneFrame.Kind
    /// What the bar says while the frame holds a terminal.
    var title: PaneFrame.Title?
    /// What it says while the frame holds a sentence.
    var caption: String?
    /// What is inside has the keyboard.
    var focused: Bool
    /// The ground of what is inside; nil for the design's terminal ground.
    var well: Color?
    /// See `PaneFrameChrome.cover`.
    var cover: Color?
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().modifier(PaneFrameChrome(wears: wears, title: title, caption: caption, focused: focused, well: well, cover: cover))
    }
}

/// A frame, put round a view **without changing which view it is**.
///
/// What is framed keeps its identity through every change of `wears` --
/// from no frame to one, from one frame to another, and back. That is the
/// whole reason this is one chain of modifiers whose values change, and not
/// a choice between a framed view and a bare one: a choice is two places in
/// SwiftUI's tree, and moving between them unmakes what was in one and
/// makes it again in the other.
///
/// **What that cost when it was a choice** (task 1461). A terminal's view is
/// an `NSView` that outlives SwiftUI's; whatever holds it for SwiftUI
/// (`SurfaceScrollView`) takes it for its own when it is made. The split
/// view is rebuilt whole whenever the tree changes shape, and the old one
/// is still handed the new facts on its way out -- a pane that was alone is
/// now one of two, so it is framed. With a choice, that made a second
/// holder inside the view being thrown away, which took the terminal from
/// the holder just made for the new one; then it was thrown away. The
/// terminal was in no window: a blank pane on the commonest action there
/// is, splitting a tab that had one terminal in it.
///
/// So: nothing here may be an `if` round `content`. Everything a frame
/// draws is behind it or over it, and what changes is how much room is
/// kept clear round it.
struct PaneFrameChrome: ViewModifier {
    typealias Look = ControlRoomLook

    /// Which frame; nil for none, and then nothing is drawn and no room is
    /// kept: what is framed is laid out and painted as if this were not
    /// here.
    var wears: PaneFrame.Kind?
    var title: PaneFrame.Title?
    var caption: String?
    var focused: Bool
    var well: Color?
    /// The colour of what the frame sits on, when the corners of what is
    /// inside have to be covered rather than clipped: a terminal's own
    /// view is not clipped by a SwiftUI shape, so its corners are painted
    /// over. Nil where something else clips it (the control room rounds
    /// the layer that holds the terminal).
    var cover: Color?
    /// Kept clear outside the frame, on every side.
    var outside: CGFloat = 0

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let theme = Look.theme(scheme)
        content
            .overlay { overContent(theme).allowsHitTesting(false) }
            .padding(Self.room(for: wears))
            .background { behind(theme) }
            .overlay { overFrame(theme).allowsHitTesting(false) }
            .padding(outside)
    }

    /// The room a frame keeps between its own edge and what is inside:
    /// the title above, and a supervisor's border on the other three sides.
    static func room(for wears: PaneFrame.Kind?) -> EdgeInsets {
        switch wears {
        case .supervisor:
            let bezel = CGFloat(Look.Space.supervisorBezel)
            return EdgeInsets(top: CGFloat(Look.Pane.barHeight), leading: bezel, bottom: bezel, trailing: bezel)
        case .worker:
            return EdgeInsets(top: CGFloat(Look.Pane.barHeight), leading: 0, bottom: 0, trailing: 0)
        case .plain:
            return EdgeInsets(top: CGFloat(Look.Pane.plainTitleBandHeight), leading: 0, bottom: 0, trailing: 0)
        case nil:
            return EdgeInsets()
        }
    }

    private var hairline: CGFloat { CGFloat(Look.Line.hairline) }

    private func ground(_ theme: Look.Theme) -> Color {
        well ?? theme.terminalBackground.color
    }

    /// Over what is inside, and exactly its size: a supervisor's terminal
    /// has its corners rounded and a line round it.
    @ViewBuilder
    private func overContent(_ theme: Look.Theme) -> some View {
        if wears == .supervisor {
            let inner = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.supervisorInner), style: .continuous)
            ZStack {
                if let cover {
                    // The bezel is not quite opaque, so what shows in a
                    // corner is the bezel over the ground: paint both.
                    PaneFrameCorners(radius: CGFloat(Look.Radius.supervisorInner), top: true).cover(cover)
                    PaneFrameCorners(radius: CGFloat(Look.Radius.supervisorInner), top: true)
                        .cover(theme.supervisorBezel.color)
                }
                inner.strokeBorder(theme.supervisorTerminalEdge.color, lineWidth: hairline)
            }
        }
    }

    /// Behind everything: the frame's own ground, the size of the frame.
    @ViewBuilder
    private func behind(_ theme: Look.Theme) -> some View {
        switch wears {
        case .supervisor:
            let outer = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.supervisorOuter), style: .continuous)
            let inner = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.supervisorInner), style: .continuous)
            ZStack {
                outer.shadowOutside(Look.Pane.supervisorFloats
                    ? [(theme.supervisorShadowAlpha, Look.Pane.frameShadowBlur / 2, Look.Pane.frameShadowY)]
                    : [])
                // The line round it, deeper while the terminal has the keyboard.
                outer.inset(by: -hairline)
                    .strokeBorder((focused ? theme.supervisorEdgeFocused : theme.supervisorEdge).color, lineWidth: hairline)
                outer.fill(theme.supervisorBezel.color)
                // A highlight along the top edge only.
                outer.strokeBorder(theme.supervisorHighlight.color, lineWidth: hairline)
                    .mask(alignment: .top) { Rectangle().frame(height: CGFloat(Look.Radius.supervisorOuter)) }
                // The ground of what is inside, where it is.
                inner.fill(ground(theme)).padding(Self.room(for: .supervisor))
            }
        case .worker:
            let line = CGFloat(Look.Pane.workerLine)
            let shape = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.worker), style: .continuous)
            ZStack {
                shape.inset(by: -line).strokeBorder(theme.workerEdge.color, lineWidth: line)
                // The terminal's ground all over, and the band across the top of it.
                VStack(spacing: 0) {
                    theme.workerBand.color
                        .frame(height: CGFloat(Look.Pane.barHeight))
                        .overlay(alignment: .bottom) {
                            if Look.Pane.workerBandHasLineBelow {
                                Rectangle().fill(theme.lineFaint.color).frame(height: hairline)
                            }
                        }
                    Spacer(minLength: 0)
                }
                .background(ground(theme))
                .clipShape(shape)
            }
        case .plain:
            RoundedRectangle(cornerRadius: CGFloat(Look.Radius.plain), style: .continuous).fill(ground(theme))
        case nil:
            EmptyView()
        }
    }

    /// Over the whole frame: its title, and what rounds the corners of a
    /// terminal that reaches the frame's own bottom edge.
    @ViewBuilder
    private func overFrame(_ theme: Look.Theme) -> some View {
        if let wears {
            let padding: CGFloat = switch wears {
            case .supervisor: CGFloat(Look.Space.supervisorBezel) + CGFloat(Look.Pane.supervisorBarPaddingX)
            case .worker: CGFloat(Look.Pane.barPaddingX)
            case .plain: CGFloat(Look.Pane.plainTitleInsetX)
            }
            ZStack {
                VStack(spacing: 0) {
                    PaneFrameBar(wears: wears, title: title, caption: caption)
                        .frame(height: Self.room(for: wears).top)
                        .padding(.horizontal, padding)
                    Spacer(minLength: 0)
                }
                switch wears {
                case .supervisor:
                    EmptyView()
                case .worker:
                    let shape = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.worker), style: .continuous)
                    if let cover {
                        PaneFrameCorners(radius: CGFloat(Look.Radius.worker), top: false).cover(cover)
                    }
                    // Inside the edge: there in the dark theme only.
                    shape.strokeBorder(theme.workerEdgeInner.color, lineWidth: CGFloat(Look.Pane.workerLine))
                case .plain:
                    let shape = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.plain), style: .continuous)
                    if let cover {
                        PaneFrameCorners(radius: CGFloat(Look.Radius.plain), top: false).cover(cover)
                    }
                    if Look.Pane.plainHasLine {
                        shape.strokeBorder(theme.lineFaint.color, lineWidth: hairline)
                    }
                }
            }
        }
    }
}

/// What lies between a rectangle and the rounded one inside it: the
/// corners. Filled (even-odd) with the colour behind, it rounds something
/// that cannot be clipped. The top two are left alone unless asked for,
/// because under a title band the top of the frame is the band's.
struct PaneFrameCorners: Shape {
    var radius: CGFloat
    var top: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        // Taller than the rectangle when the top is not wanted, so that
        // the top corners of the rounded one fall outside it.
        let rounded = top ? rect : CGRect(x: rect.minX, y: rect.minY - radius * 2, width: rect.width, height: rect.height + radius * 2)
        path.addPath(Path(roundedRect: rounded, cornerRadius: radius, style: .continuous))
        return path
    }

    /// The corners in `color`, and nothing outside the rectangle. Nothing
    /// in it takes a click: what is under a corner is still the terminal.
    func cover(_ color: Color) -> some View {
        fill(color, style: FillStyle(eoFill: true))
            .clipped()
            .allowsHitTesting(false)
    }
}

/// The title of a frame: the name and what the pane is on the left; on the
/// right its status -- the glyph and the word. Not how long it has waited:
/// that was here once and told the person nothing they could act on.
struct PaneFrameBar: View {
    typealias Look = ControlRoomLook

    var wears: PaneFrame.Kind
    var title: PaneFrame.Title?
    var caption: String?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        HStack(spacing: CGFloat(Look.Pane.barGap)) {
            if let title {
                HStack(spacing: CGFloat(Look.Pane.nameRoleGap)) {
                    Text(title.name)
                        .font(.system(size: CGFloat(Look.Font.body), design: .monospaced))
                        .fontWeight(Look.weight(wears == .plain ? Look.Font.weightBody : Look.Font.weightEmphasis))
                        .foregroundStyle(nameColor(theme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let role = PaneFrame.roleWord(wears) {
                        Text(role)
                            .foregroundStyle(secondaryColor(theme))
                            .fixedSize()
                    }
                }
                Spacer(minLength: CGFloat(Look.Pane.barGap))
                status(title, theme: theme)
            } else {
                Text(caption ?? "")
                    .font(.system(size: CGFloat(Look.Font.body), design: .monospaced))
                    .foregroundStyle(secondaryColor(theme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: CGFloat(Look.Font.body)))
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func status(_ title: PaneFrame.Title, theme: Look.Theme) -> some View {
        if title.shown != .none || !title.word.isEmpty {
            HStack(spacing: CGFloat(Look.Side.statusWordGap)) {
                ControlRoomGlyph(shown: title.shown)
                Text(title.word)
                    .fontWeight(Look.weight(Look.Font.weightEmphasis))
                    .foregroundStyle(wordColor(title.shown, theme: theme))
                    .fixedSize()
            }
        }
    }

    /// The name: the frame's own text on a supervisor's bar, the
    /// terminal's bold on a worker's band, and a step back on an ordinary
    /// terminal's ground.
    private func nameColor(_ theme: Look.Theme) -> Color {
        switch wears {
        case .supervisor: return theme.text.color
        case .worker: return theme.terminalBold.color
        case .plain: return theme.terminalDim.color
        }
    }

    private func secondaryColor(_ theme: Look.Theme) -> Color {
        wears == .supervisor ? theme.textSecondary.color : theme.terminalDim.color
    }

    /// The colour of the status word on this bar: the table's, including
    /// where a red word is not red.
    private func wordColor(_ shown: ControlRoomList.Shown, theme: Look.Theme) -> Color {
        switch shown {
        case .needsYou, .doneUnseen:
            return theme.attentionText.color
        case .trouble:
            switch wears {
            case .supervisor: return theme.problemTextOnSupervisorBar.color
            case .worker: return theme.problemTextOnWorkerBand.color
            case .plain: return theme.problemTextOnTerminal.color
            }
        case .working, .none:
            return secondaryColor(theme)
        }
    }
}
