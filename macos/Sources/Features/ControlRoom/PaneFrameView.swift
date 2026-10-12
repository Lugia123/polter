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
    typealias Look = ControlRoomLook

    var wears: PaneFrame.Kind
    /// What the bar says while the frame holds a terminal.
    var title: PaneFrame.Title?
    /// What it says while the frame holds a sentence.
    var caption: String?
    /// What is inside has the keyboard.
    var focused: Bool
    /// The ground of what is inside; nil for the design's terminal ground.
    var well: Color?
    /// The colour of what the frame sits on, when the corners of what is
    /// inside have to be covered rather than clipped: a terminal's own
    /// view is not clipped by a SwiftUI shape, so its corners are painted
    /// over. Nil where something else clips it (the control room rounds
    /// the layer that holds the terminal).
    var cover: Color?
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        switch wears {
        case .supervisor: supervisor(theme)
        case .worker: worker(theme)
        case .plain: plain(theme)
        }
    }

    private func bar() -> PaneFrameBar {
        PaneFrameBar(wears: wears, title: title, caption: caption)
    }

    private func supervisor(_ theme: Look.Theme) -> some View {
        let bezel = CGFloat(Look.Space.supervisorBezel)
        let hairline = CGFloat(Look.Line.hairline)
        let outer = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.supervisorOuter), style: .continuous)
        let inner = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.supervisorInner), style: .continuous)
        return VStack(spacing: 0) {
            bar()
                .frame(height: CGFloat(Look.Pane.barHeight))
                .padding(.horizontal, bezel + CGFloat(Look.Pane.supervisorBarPaddingX))
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(well ?? theme.terminalBackground.color)
                .clipShape(inner)
                .overlay {
                    if let cover {
                        // The bezel is not quite opaque, so what shows in a
                        // corner is the bezel over the ground: paint both.
                        PaneFrameCorners(radius: CGFloat(Look.Radius.supervisorInner), top: true).cover(cover)
                        PaneFrameCorners(radius: CGFloat(Look.Radius.supervisorInner), top: true)
                            .cover(theme.supervisorBezel.color)
                    }
                }
                .overlay(inner.strokeBorder(theme.supervisorTerminalEdge.color, lineWidth: hairline))
                .padding([.horizontal, .bottom], bezel)
        }
        .background(
            outer
                .fill(theme.supervisorBezel.color)
                .overlay(
                    // A highlight along the top edge only.
                    outer.strokeBorder(theme.supervisorHighlight.color, lineWidth: hairline)
                        .mask(alignment: .top) { Rectangle().frame(height: CGFloat(Look.Radius.supervisorOuter)) }
                )
        )
        // The line round it, deeper while the terminal has the keyboard.
        .background(
            outer.inset(by: -hairline)
                .strokeBorder((focused ? theme.supervisorEdgeFocused : theme.supervisorEdge).color, lineWidth: hairline)
        )
        .background(
            outer.shadowOutside(Look.Pane.supervisorFloats
                ? [(theme.supervisorShadowAlpha, Look.Pane.frameShadowBlur / 2, Look.Pane.frameShadowY)]
                : [])
        )
    }

    private func worker(_ theme: Look.Theme) -> some View {
        let line = CGFloat(Look.Pane.workerLine)
        let radius = CGFloat(Look.Radius.worker)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return VStack(spacing: 0) {
            bar()
                .frame(height: CGFloat(Look.Pane.barHeight))
                .padding(.horizontal, CGFloat(Look.Pane.barPaddingX))
                .background(theme.workerBand.color)
                .overlay(alignment: .bottom) {
                    if Look.Pane.workerBandHasLineBelow {
                        Rectangle().fill(theme.lineFaint.color).frame(height: CGFloat(Look.Line.hairline))
                    }
                }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(well ?? theme.terminalBackground.color)
        .clipShape(shape)
        .overlay {
            if let cover {
                PaneFrameCorners(radius: radius, top: false).cover(cover)
            }
        }
        // Inside the edge: there in the dark theme only.
        .overlay(shape.strokeBorder(theme.workerEdgeInner.color, lineWidth: line))
        .background(shape.inset(by: -line).strokeBorder(theme.workerEdge.color, lineWidth: line))
    }

    private func plain(_ theme: Look.Theme) -> some View {
        let radius = CGFloat(Look.Radius.plain)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return VStack(spacing: 0) {
            bar()
                .frame(height: CGFloat(Look.Pane.plainTitleBandHeight))
                .padding(.horizontal, CGFloat(Look.Pane.plainTitleInsetX))
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(well ?? theme.terminalBackground.color)
        .clipShape(shape)
        .overlay {
            if let cover {
                PaneFrameCorners(radius: radius, top: false).cover(cover)
            }
        }
        .overlay {
            if Look.Pane.plainHasLine {
                shape.strokeBorder(theme.lineFaint.color, lineWidth: CGFloat(Look.Line.hairline))
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
