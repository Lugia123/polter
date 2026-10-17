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
    /// See `PaneFrameChrome.stack`. **Nothing passes one yet.**
    var stack: PaneStack?
    var stackActions = PaneStackActions()
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().modifier(PaneFrameChrome(wears: wears, title: title, caption: caption, focused: focused, well: well, cover: cover,
                                           stack: stack, stackActions: stackActions))
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
    /// The terminals this pane holds, when it holds more than the one it
    /// shows: the title gives way to a strip of tabs (`PaneStackStripView`;
    /// `control-room.md`, 12.6.2). **Nothing passes one yet** -- no pane
    /// holds a stack -- and without one this draws what it drew.
    ///
    /// Having one or not is, like `wears`, only a matter of what is drawn
    /// over the frame: the strip is one more layer over it, there or
    /// empty, and what is framed is the same view either way.
    var stack: PaneStack?
    var stackActions = PaneStackActions()
    /// The pane's close button is showing over the title's left end, which
    /// the split view lays there (task 1642): the title is cut away under
    /// its disc. Never in the control room.
    var closeHole = false

    @Environment(\.colorScheme) private var scheme

    /// From the frame's edge to its title's text, left and right.
    static func barPadding(for wears: PaneFrame.Kind) -> CGFloat {
        switch wears {
        case .supervisor: CGFloat(Look.Space.supervisorBezel) + CGFloat(Look.Pane.supervisorBarPaddingX)
        case .worker: CGFloat(Look.Pane.barPaddingX)
        case .plain: CGFloat(Look.Pane.plainTitleInsetX)
        }
    }

    func body(content: Content) -> some View {
        let theme = Look.theme(scheme)
        content
            .overlay { overContent(theme).allowsHitTesting(false) }
            .padding(Self.room(for: wears))
            .background { behind(theme) }
            // Nothing over the frame takes a click but the take-over button
            // on a supervisor's bar (task 1635): each of its parts says so
            // itself, since a layer that takes none passes the button's
            // clicks through to whatever is under it.
            .overlay { overFrame(theme) }
            // The strip takes clicks, so it is a layer of its own.
            .overlay(alignment: .top) { strip(theme) }
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

    /// The strip of tabs, across the top of the frame where the title is,
    /// when the pane holds a stack. Between the content's edges: inside a
    /// supervisor's border, the frame's own edges for the other two.
    @ViewBuilder
    private func strip(_ theme: Look.Theme) -> some View {
        if let wears, let stack {
            PaneStackStripView(stack: stack, wears: wears, title: title, well: ground(theme), actions: stackActions)
                .padding(.horizontal, Self.room(for: wears).leading)
                .background {
                    // An ordinary terminal has no band -- unless it holds
                    // a stack and is drawn the first of the two ways the
                    // design did not draw (`PaneStack.PlainStyle`). The
                    // band is the strip's, so that a pane with no stack
                    // is painted by exactly what painted it before.
                    if wears == .plain, stack.plainStyle == .band {
                        theme.workerBand.color
                            .clipShape(PaneStackBandShape(radius: CGFloat(Look.Radius.plain)))
                    }
                }
        }
    }

    /// Over the whole frame: its title, and what rounds the corners of a
    /// terminal that reaches the frame's own bottom edge.
    @ViewBuilder
    private func overFrame(_ theme: Look.Theme) -> some View {
        if let wears {
            let padding = Self.barPadding(for: wears)
            ZStack {
                VStack(spacing: 0) {
                    // Under a strip the bar is still there and says
                    // nothing: taking it out would be one more thing that
                    // changes shape when a pane gains a stack.
                    PaneFrameBar(wears: wears, title: stack == nil ? title : nil, caption: stack == nil ? caption : nil)
                        .frame(height: Self.room(for: wears).top)
                        .padding(.horizontal, padding)
                        // Over the name's start while it shows, and taking
                        // no place of its own (task 1642): the name is cut
                        // away under its disc.
                        .polterCloseHole(closeHole && stack == nil, textLeading: padding)
                    Spacer(minLength: 0)
                }
                edges(wears, theme: theme)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func edges(_ wears: PaneFrame.Kind, theme: Look.Theme) -> some View {
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

/// The line just inside a supervisor's pane when panes wear no frames
/// (`PaneFrame.edged`, task 1692): over what is in it, on every side, and
/// taking no click. Only ever drawn over, never a choice round what is in
/// the pane (task 1461). It lies on the terminal's own padding -- 2 pt by
/// default (`window-padding-x`, `-y`); with none, on its outermost pixels.
struct PaneSupervisorEdge: ViewModifier {
    typealias Look = ControlRoomLook

    var shows: Bool

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.overlay {
            if shows {
                Rectangle()
                    .strokeBorder(Look.theme(scheme).supervisorMark.color, lineWidth: CGFloat(Look.SupervisorBadge.edge))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A band across the top of a pane: round at the two top corners, square
/// along the bottom where the terminal begins.
struct PaneStackBandShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radius), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
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

private struct PaneFrameTakeOverKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    /// "Let the control room take over?" on a supervisor's frame (task
    /// 1635): handed the question the core asks before anything is done.
    var paneFrameTakeOver: ((String) -> Void)? {
        get { self[PaneFrameTakeOverKey.self] }
        set { self[PaneFrameTakeOverKey.self] = newValue }
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
    /// What "Let the control room take over?" does, handed the core's
    /// question; nil where nothing can take over (task 1635).
    @Environment(\.paneFrameTakeOver) private var takeOver

    var body: some View {
        let theme = Look.theme(scheme)
        Group {
            if let title {
                // **What gives way when the bar is narrow, in order** (#1498):
                // the word for what the pane is; then the name, cut in the
                // middle down to `nameFloor`; then the status word, leaving
                // its glyph; then the name. Each line is laid out whole or
                // not at all, so nothing is drawn over anything else. At
                // 80 pt they used to overlap: the role and status words
                // would not shrink, and the name had nothing left.
                //
                // The first three steps are the Windows host's order too
                // (`scene::place_line`: trailing parts whole, the name cut
                // by them, the role only after a whole name). The last two
                // are this host's alone; Windows lets the status run past
                // the bar's left edge instead.
                //
                // A note (a supervisor started by hand, task 1635) is said
                // whole or not at all, and goes before anything else does:
                // the bar is still the frame's title first.
                //
                // A supervisor's title says what it is with a badge at its
                // left end, in place of the word after the name (task 1692),
                // and the badge is on every one of these lines: it is never
                // what gives way.
                ViewThatFits(in: .horizontal) {
                    if title.note != nil {
                        line(title, theme: theme, role: true, nameCut: false, word: true, note: true)
                        line(title, theme: theme, role: false, nameCut: false, word: true, note: true)
                        line(title, theme: theme, role: false, nameCut: true, word: true, note: true)
                        // Where the note and what became of a take-over do
                        // not both fit, the note gives way: "not taken
                        // over: it is busy" is the newer news, and the
                        // button stays with it.
                        if title.takeOver?.status != nil || title.takeOver?.offered == true {
                            line(title, theme: theme, role: false, nameCut: true, word: true, note: true, said: false)
                        }
                    }
                    line(title, theme: theme, role: true, nameCut: false, word: true)
                    line(title, theme: theme, role: false, nameCut: false, word: true)
                    line(title, theme: theme, role: false, nameCut: true, word: true)
                    line(title, theme: theme, role: false, nameCut: true, word: false)
                    HStack(spacing: 0) {
                        // The badge never gives way (task 1692): it is
                        // what says this is the supervisor.
                        if title.badge(in: wears) {
                            PaneSupervisorBadge(word: PaneFrame.roleWord(.supervisor) ?? "", paneColor: nil)
                                .padding(.trailing, CGFloat(Look.Pane.barGap))
                        }
                        Spacer(minLength: 0)
                        status(title, theme: theme, word: false)
                    }
                    .accessibilityElement(children: .combine)
                    .allowsHitTesting(false)
                    // Narrower than a supervisor's badge and its glyph: the
                    // glyph goes, and then the badge's word -- never the
                    // badge, and nothing past the bar's edge.
                    if title.badge(in: wears) {
                        HStack(spacing: 0) {
                            PaneSupervisorBadge(word: PaneFrame.roleWord(.supervisor) ?? "", paneColor: nil)
                            Spacer(minLength: 0)
                        }
                        .allowsHitTesting(false)
                        HStack(spacing: 0) {
                            PaneSupervisorBadge(word: "", paneColor: nil)
                                .accessibilityLabel(PaneFrame.roleWord(.supervisor) ?? "")
                            Spacer(minLength: 0)
                        }
                        .allowsHitTesting(false)
                    }
                }
            } else {
                HStack(spacing: CGFloat(Look.Pane.barGap)) {
                    Text(caption ?? "")
                        .font(.system(size: CGFloat(Look.Font.body), design: .monospaced))
                        .foregroundStyle(secondaryColor(theme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)
            }
        }
        .font(.system(size: CGFloat(Look.Font.body)))
        .monospacedDigit()
        .accessibilityElement(children: .contain)
    }

    /// The narrowest a cut name is let go before the status word gives way:
    /// four characters of the name's face, which with the ellipsis is a
    /// beginning and an end to recognise it by.
    static let nameFloor: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(Look.Font.body), weight: .regular)
        return ceil(("MMMM" as NSString).size(withAttributes: [.font: font]).width)
    }()

    /// One way of laying out the bar. `nameCut`: the name asks only for
    /// `nameFloor` and takes what it is given; otherwise it asks for all of
    /// itself, so the line fits only where the whole name does.
    @ViewBuilder
    private func line(_ title: PaneFrame.Title, theme: Look.Theme, role: Bool, nameCut: Bool, word: Bool,
                      note: Bool = false, said: Bool = true) -> some View {
        // The gap between the two sides is the spacer's, and only the
        // spacer's: a spacing here would be added on both sides of it.
        HStack(spacing: 0) {
            words(title, theme: theme, role: role, nameCut: nameCut, word: word,
                  hookless: note ? (said ? .said : .status) : .none)
            // The button, last: at the bar's right end, as on Windows
            // (`scene::build_right`), and an element of its own -- inside
            // the bar's `.combine` it is no button anybody can press but
            // with the pointer (task 1635).
            if note, let take = title.takeOver, take.offered, let confirm = take.confirm, let takeOver {
                Button(String(localized: "Let the control room take over?",
                              comment: "总控台：手动启动的总管，标题条上的按钮")) { takeOver(confirm) }
                    .buttonStyle(.link)
                    .fixedSize()
                    .padding(.leading, CGFloat(Look.Pane.barGap))
            }
        }
    }

    /// How much of a hand-started supervisor (task 1635) a line says.
    private enum HooklessWords {
        case none
        /// What became of a take-over, without the note.
        case status
        /// The note too.
        case said
    }

    /// Everything on a line but the take-over button, said as one.
    @ViewBuilder
    private func words(_ title: PaneFrame.Title, theme: Look.Theme, role: Bool, nameCut: Bool, word: Bool,
                       hookless: HooklessWords) -> some View {
        HStack(spacing: 0) {
            let badge = title.badge(in: wears)
            if badge {
                PaneSupervisorBadge(word: PaneFrame.roleWord(.supervisor) ?? "", paneColor: nil)
                    .padding(.trailing, CGFloat(Look.Pane.barGap))
            }
            HStack(spacing: CGFloat(Look.Pane.nameRoleGap)) {
                if nameCut {
                    name(title, theme: theme)
                        .frame(minWidth: 0, idealWidth: Self.nameFloor, maxWidth: .infinity, alignment: .leading)
                } else {
                    name(title, theme: theme)
                        .fixedSize()
                }
                // The title's own word when it brings one; the frame's
                // otherwise (`SupervisorTitle.says`).
                if role, !badge, let word = title.roleWord(in: wears) {
                    Text(word)
                        .foregroundStyle(secondaryColor(theme))
                        .fixedSize()
                }
            }
            Spacer(minLength: CGFloat(Look.Pane.barGap))
            if hookless == .said, let note = title.note {
                Text(note)
                    .foregroundStyle(theme.attentionText.color)
                    .fixedSize()
                    .padding(.trailing, CGFloat(Look.Pane.barGap))
            }
            if hookless != .none, let take = title.takeOver {
                if let status = take.status {
                    Text(status)
                        .foregroundStyle(secondaryColor(theme))
                        .fixedSize()
                        .padding(.trailing, CGFloat(Look.Pane.barGap))
                }
            }
            status(title, theme: theme, word: word)
        }
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    private func name(_ title: PaneFrame.Title, theme: Look.Theme) -> some View {
        Text(title.name)
            .font(.system(size: CGFloat(Look.Font.body), design: .monospaced))
            .fontWeight(Look.weight(wears == .plain ? Look.Font.weightBody : Look.Font.weightEmphasis))
            .foregroundStyle(nameColor(theme))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private func status(_ title: PaneFrame.Title, theme: Look.Theme, word: Bool) -> some View {
        if title.shown != .none || !title.word.isEmpty {
            HStack(spacing: CGFloat(Look.Side.statusWordGap)) {
                // Held is not a status and has no colour of its own: the
                // design draws it in the title's second ink.
                if let status = title.shown.status {
                    ControlRoomGlyph(shown: status)
                } else {
                    PaneHeldGlyph()
                        .fill(secondaryColor(theme))
                        .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
                        .accessibilityHidden(true)
                }
                if word {
                    Text(title.word)
                        .fontWeight(Look.weight(Look.Font.weightEmphasis))
                        .foregroundStyle(wordColor(title.shown, theme: theme))
                        .fixedSize()
                }
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
    private func wordColor(_ shown: ControlRoomSnapshot.Terminal.Bar.Shown, theme: Look.Theme) -> Color {
        switch shown {
        case .needsYou, .doneUnseen:
            return theme.attentionText.color
        case .trouble:
            switch wears {
            case .supervisor: return theme.problemTextOnSupervisorBar.color
            case .worker: return theme.problemTextOnWorkerBand.color
            case .plain: return theme.problemTextOnTerminal.color
            }
        case .working, .none, .held:
            return secondaryColor(theme)
        }
    }
}

/// The badge at the left end of a supervisor's title (task 1692, the
/// design's `supervisor-pane-v1` C): the mark and the word for what it is,
/// on the app icon's colour, round at both ends. As wide as what is on it,
/// so it fits the word in every language; with no word, the mark alone, as
/// far from both ends. The Windows host draws the same from the same
/// numbers (`Piece::Badge`).
struct PaneSupervisorBadge: View {
    typealias Look = ControlRoomLook

    var word: String
    /// The pane's own colour, when it has one (`PaneFrame.badgeGround`).
    var paneColor: Look.RGBA?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        let b = Look.SupervisorBadge.self
        HStack(spacing: CGFloat(b.markWordGap)) {
            PaneSupervisorMark()
                .fill(theme.supervisorBadgeText.color)
                .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
                .accessibilityHidden(true)
            if !word.isEmpty {
                Text(word)
                    .font(.system(size: CGFloat(Look.Font.body)))
                    .fontWeight(Look.weight(Look.Font.weightEmphasis))
                    .foregroundStyle(theme.supervisorBadgeText.color)
                    .lineLimit(1)
            }
        }
        .padding(.leading, CGFloat(b.paddingLeading))
        .padding(.trailing, CGFloat(word.isEmpty ? b.paddingLeading : b.paddingTrailing))
        .frame(height: CGFloat(b.height))
        .background(Capsule(style: .continuous).fill(PaneFrame.badgeGround(paneColor, theme: theme).color))
        .fixedSize()
    }
}

/// The supervisor's mark, the flag the window's tab puts before a
/// supervisor's title (`TabMark.supervisor`, ⚑), on the status glyphs' own
/// artboard: a pole 1.4 wide from 0.9 to 13.3, round at its ends, and a
/// pennant notched at its free end. The Windows host draws the same from the
/// same numbers (`polter_control_room::glyph::Mark::Supervisor`).
struct PaneSupervisorMark: Shape {
    /// The pole: x, y, width, height, corner.
    static let pole = (x: 2.5, y: 0.9, width: 1.4, height: 12.4, corner: 0.7)
    /// The pennant's corners, in order.
    static let pennant: [(x: Double, y: Double)] = [(3.9, 2.1), (11.5, 2.1), (9.6, 5.0), (11.5, 7.9), (3.9, 7.9)]

    func path(in rect: CGRect) -> Path {
        let unit = rect.width / CGFloat(ControlRoomLook.Status.artboard)
        let at = { (x: Double, y: Double) in CGPoint(x: rect.minX + CGFloat(x) * unit, y: rect.minY + CGFloat(y) * unit) }
        var path = Path()
        let p = Self.pole
        path.addRoundedRect(in: CGRect(origin: at(p.x, p.y), size: CGSize(width: CGFloat(p.width) * unit, height: CGFloat(p.height) * unit)),
                            cornerSize: CGSize(width: CGFloat(p.corner) * unit, height: CGFloat(p.corner) * unit))
        path.addLines(Self.pennant.map { at($0.x, $0.y) })
        path.closeSubpath()
        return path
    }
}

/// The glyph of a terminal the person is holding: two bars, as the design
/// draws them on the status glyphs' own artboard (`06-panes`: each 2.4 wide
/// and 8 high, their corners 0.8, at 3.8 and 7.8 across and 3 down, of 14).
/// The Windows host draws the same two from the same numbers
/// (`polter_control_room::glyph::held`).
struct PaneHeldGlyph: Shape {
    /// Where the two bars are on the artboard: x, y, width, height, corner.
    static let bars: [(x: Double, y: Double, width: Double, height: Double, corner: Double)] = [
        (3.8, 3, 2.4, 8, 0.8),
        (7.8, 3, 2.4, 8, 0.8),
    ]

    func path(in rect: CGRect) -> Path {
        let unit = rect.width / CGFloat(ControlRoomLook.Status.artboard)
        var path = Path()
        for bar in Self.bars {
            let box = CGRect(
                x: rect.minX + CGFloat(bar.x) * unit, y: rect.minY + CGFloat(bar.y) * unit,
                width: CGFloat(bar.width) * unit, height: CGFloat(bar.height) * unit)
            path.addRoundedRect(in: box, cornerSize: CGSize(width: CGFloat(bar.corner) * unit, height: CGFloat(bar.corner) * unit))
        }
        return path
    }
}
