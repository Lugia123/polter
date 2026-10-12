import SwiftUI

/// The control room's group list (`control-room.md`, 3.1 and 3.2): the
/// groups waiting for you, the ones that need nothing, and today's waiting
/// along the bottom.
///
/// It draws a `ControlRoomList` and decides nothing about it. Every size and
/// colour is `ControlRoomLook`'s, and every position is
/// `ControlRoomListLayout`'s; this file has no numbers of its own.
///
/// Not wired to anything yet: the list is whatever it is handed, and the
/// new-group button does nothing.
struct ControlRoomListView: View {
    typealias Look = ControlRoomLook
    typealias Row = ControlRoomList.Row

    var list: ControlRoomList
    @Binding var selection: String?
    var onNewGroup: () -> Void = {}
    /// Whether the chip's edge bends what is under it. Off, and nothing
    /// reads it yet: the table's `refractionShown` is still tentative, and
    /// the lift, the slide and the overshoot come first.
    var refraction: Bool = false
    /// Stops every motion, as Reduce Motion does. For still pictures.
    var still: Bool = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 at rest, 1 while the chip is in the air.
    @State private var lift: CGFloat = 0
    @State private var landing: DispatchWorkItem?

    private var theme: Look.Theme { Look.theme(scheme) }
    private var moves: Bool { !still && !reduceMotion }

    var body: some View {
        GeometryReader { proxy in
            let layout = ControlRoomListLayout(list: list, height: proxy.size.height)
            ZStack(alignment: .topLeading) {
                if let chip = layout.chip(for: selection) {
                    self.chip.place(chip)
                }
                header.place(layout.header)
                ForEach(list.waiting) { row in
                    waitingRow(row).place(layout.rows[row.id] ?? .zero)
                }
                theme.lineFaint.color.place(layout.separator)
                quietHeader.place(layout.quietHeader)
                ForEach(list.quiet) { row in
                    quietRow(row).place(layout.rows[row.id] ?? .zero)
                }
                if let band = list.timeBand {
                    bandHeader(band).place(layout.bandHeader)
                    ForEach(Array(band.lanes.enumerated()), id: \.offset) { n, lane in
                        self.lane(lane, in: band).place(layout.lanes[n])
                    }
                    axis(band).place(layout.axis)
                }
            }
        }
        .frame(width: CGFloat(Look.Side.width))
        .background(panel)
        .font(.system(size: CGFloat(Look.Font.body)))
        .monospacedDigit()
        .foregroundStyle(theme.text.color)
        .controlRoomListFocus()
        .onMoveCommand { direction in
            switch direction {
            case .up: select(ControlRoomList.move(selection, by: -1, in: list.rows))
            case .down: select(ControlRoomList.move(selection, by: 1, in: list.rows))
            default: break
            }
        }
        .onChange(of: selection) { _ in takeOff() }
    }

    // MARK: Selection

    private var spring: Animation {
        .spring(response: Look.Selection.springPeriod, dampingFraction: Look.Selection.springDamping)
    }

    /// Selecting is one call whether it came from a click or a key, so both
    /// slide the chip the same way.
    private func select(_ id: String?) {
        guard id != selection else {
            // Already there, and still the person's doing: a row the
            // control room opened on is theirs once they press it.
            selection = id
            return
        }
        if moves {
            withAnimation(spring) { selection = id }
        } else {
            selection = id
        }
    }

    /// The chip lifts as it leaves and comes down as it arrives.
    private func takeOff() {
        guard moves else { return }
        landing?.cancel()
        withAnimation(.easeOut(duration: Look.Selection.liftIn)) { lift = 1 }
        let land = DispatchWorkItem {
            withAnimation(spring) { lift = 0 }
        }
        landing = land
        // It starts down with the last of the way still to go.
        DispatchQueue.main.asyncAfter(deadline: .now() + Look.Selection.springPeriod / 2, execute: land)
    }

    private func mix(_ rest: Double, _ moving: Double) -> Double {
        rest + (moving - rest) * Double(lift)
    }

    /// The selected row's chip: a clean bright piece with a short soft
    /// shadow at rest; lifted, a little larger, more see-through, its
    /// shadow longer.
    private var chip: some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row), style: .continuous)
        let edge = theme.selectionEdge
        return shape
            .fill(Color.white.opacity(mix(theme.selectionTint, theme.selectionTintMoving)))
            .overlay(
                shape.strokeBorder((edge < 0 ? Color.black : Color.white).opacity(abs(edge)),
                                   lineWidth: CGFloat(Look.Selection.edgeBand))
                    .blur(radius: CGFloat(Look.Selection.edgeBand) / 2)
                    .clipShape(shape)
            )
            .background(
                shape.shadowOutside(
                    [(mix(theme.selectionHaloAlpha, theme.selectionHaloMovingAlpha),
                      mix(theme.selectionHaloBlur, theme.selectionHaloMovingBlur), 0),
                     (mix(theme.selectionShadowAlpha, theme.selectionShadowMovingAlpha),
                      mix(theme.selectionShadowBlur, theme.selectionShadowMovingBlur),
                      mix(theme.selectionShadowY, theme.selectionShadowMovingY))])
            )
            .scaleEffect(1 + CGFloat(Look.Selection.liftScaleRow) * lift)
    }

    // MARK: Pieces

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.sidePanel), style: .continuous)
        let hairline = CGFloat(Look.Line.hairline)
        return shape
            .fill(theme.sidePanel.color)
            .overlay(
                // A highlight along the top edge only.
                shape.strokeBorder(theme.sidePanelHighlight.color, lineWidth: hairline)
                    .mask(alignment: .top) { Rectangle().frame(height: CGFloat(Look.Radius.sidePanel)) }
            )
            .background(shape.inset(by: -hairline).strokeBorder(theme.sidePanelEdge.color, lineWidth: hairline))
            .background(
                shape.shadowOutside([(theme.sidePanelShadowAlpha, Look.Pane.frameShadowBlur / 2, Look.Pane.frameShadowY)])
            )
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text(String(localized: "\(String(list.waitingCount)) groups waiting for you", comment: "总控台：左栏标题，N 是核心给的数"))
                .fontWeight(Look.weight(Look.Font.weightEmphasis))
            Spacer(minLength: CGFloat(Look.Side.rowItemGap))
            Button(action: onNewGroup) {
                HStack(spacing: CGFloat(Look.Side.headerItemGap)) {
                    Image(systemName: "plus")
                    Text(String(localized: "New Group", comment: "总控台：左栏右上的按钮"))
                }
                .foregroundStyle(theme.textSecondary.color)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, CGFloat(Look.Side.headerPaddingX))
    }

    private var quietHeader: some View {
        Text(String(localized: "\(String(list.quietCount)) groups need nothing from you", comment: "总控台：左栏第二段的标题"))
            .foregroundStyle(theme.textSecondary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CGFloat(Look.Side.headerPaddingX))
    }

    /// The colour of a status word and of the minutes beside it.
    private func ink(_ shown: ControlRoomList.Shown, selected: Bool) -> (word: Color, minutes: Color) {
        switch shown {
        case .needsYou, .doneUnseen:
            return (theme.attentionText.color, theme.attentionText.color)
        case .trouble:
            // Where the word is not red is the table's to say (`text_on`).
            let word = selected ? theme.problemTextOnRowSelected : theme.problemTextOnRow
            return (word.color, theme.problemText.color)
        case .working, .none:
            return (theme.textSecondary.color, theme.textSecondary.color)
        }
    }

    private func waitingRow(_ row: Row) -> some View {
        let selected = row.id == selection
        let ink = ink(row.shown, selected: selected)
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(row.name)
                    .font(.system(size: CGFloat(Look.Font.groupName), design: .monospaced))
                    .fontWeight(Look.weight(selected ? Look.Font.weightStrong : Look.Font.weightGroupName))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: CGFloat(Look.Side.rowItemGap))
                if let minutes = row.waitedMin {
                    Text("\(minutes)")
                        .font(.system(size: CGFloat(Look.Font.minutes)))
                        .fontWeight(Look.weight(Look.Font.weightStrong))
                        .foregroundStyle(ink.minutes)
                        .frame(minWidth: CGFloat(Look.Side.minutesWidth), alignment: .trailing)
                    Text(String(localized: "min", comment: "总控台：等了几分钟，数字后面的单位"))
                        .foregroundStyle(theme.textSecondary.color)
                        .frame(width: CGFloat(Look.Side.minutesUnitWidth), alignment: .trailing)
                }
            }
            .frame(height: CGFloat(Look.Side.rowLine1Height))
            Spacer(minLength: 0)
            HStack(spacing: CGFloat(Look.Side.rowItemGap)) {
                HStack(spacing: CGFloat(Look.Side.statusWordGap)) {
                    ControlRoomGlyph(shown: row.shown, pulses: row.pulses, still: still)
                    Text(row.word)
                        .fontWeight(Look.weight(Look.Font.weightEmphasis))
                        .foregroundStyle(ink.word)
                        .fixedSize()
                }
                Text(row.detail)
                    .font(.system(size: CGFloat(Look.Font.body), design: row.detailIsCode ? .monospaced : .default))
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let others = ControlRoomList.othersText(row.others) {
                    Text(others)
                        .foregroundStyle(theme.textSecondary.color)
                        .fixedSize()
                }
            }
            .frame(height: CGFloat(Look.Side.rowLine2Height))
        }
        .padding(.horizontal, CGFloat(Look.Side.rowPaddingX))
        .padding(.vertical, CGFloat(Look.Side.rowPaddingY))
        .contentShape(Rectangle())
        .onTapGesture { select(row.id) }
        .help(ControlRoomList.tooltip(for: row) ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func quietRow(_ row: Row) -> some View {
        let selected = row.id == selection
        return HStack(spacing: CGFloat(Look.Side.rowItemGap)) {
            Text(row.name)
                .font(.system(size: CGFloat(Look.Font.body), design: .monospaced))
                .fontWeight(Look.weight(selected ? Look.Font.weightEmphasis : Look.Font.weightBody))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            HStack(spacing: CGFloat(Look.Side.quietItemGap)) {
                Text(row.word).fixedSize()
                if row.shown != .none {
                    ControlRoomGlyph(shown: row.shown, still: still)
                }
            }
        }
        .foregroundStyle((selected ? theme.text : theme.textSecondary).color)
        .padding(.horizontal, CGFloat(Look.Side.rowPaddingX))
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { select(row.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Today's waiting

    private func bandHeader(_ band: ControlRoomList.TimeBand) -> some View {
        HStack {
            Text(String(localized: "Kept you waiting today", comment: "总控台：左栏底部时间带的标题")).foregroundStyle(theme.textSecondary.color)
            Spacer()
            Text(String(localized: "\(String(band.totalMinutes)) min", comment: "总控台：今天累计让你等了多少分钟")).fontWeight(Look.weight(Look.Font.weightEmphasis))
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            theme.lineFaint.color.frame(height: CGFloat(Look.Line.hairline))
        }
    }

    /// One group's lane: the start of its name, then when today it kept
    /// the person waiting. The design does not say which lane is whose; the
    /// name is this build's answer and is marked tentative in the table.
    private func lane(_ lane: ControlRoomList.Lane, in band: ControlRoomList.TimeBand) -> some View {
        HStack(spacing: CGFloat(Look.Side.rowItemGap)) {
            Text(lane.name)
                .font(.system(size: CGFloat(Look.Font.min), design: .monospaced))
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: CGFloat(Look.Side.timeLaneLabelWidth), alignment: .leading)
            GeometryReader { proxy in
                let segments = ControlRoomListLayout.segments(
                    lane, band: band, width: proxy.size.width)
                ZStack(alignment: .leading) {
                    theme.line.color
                        .frame(height: CGFloat(Look.Line.stroke))
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, piece in
                        RoundedRectangle(cornerRadius: CGFloat(Look.Side.timeSegmentRadius))
                            .fill((piece.ongoing ? theme.text : theme.textSecondary).color)
                            .frame(width: piece.width, height: CGFloat(Look.Side.timeSegmentHeight))
                            .offset(x: piece.x)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .help(lane.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lane.name)
    }

    private func axis(_ band: ControlRoomList.TimeBand) -> some View {
        HStack {
            Text(band.startLabel)
            Spacer()
            Text(String(localized: "now", comment: "总控台：时间带的右端"))
        }
        .foregroundStyle(theme.textTertiary.color)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

private extension InsettableShape {
    /// Shadows that fall outside the shape and nowhere under it.
    ///
    /// The shapes they belong to are see-through, and a plain `.shadow`
    /// would show through them and grey the very surface that is meant to
    /// be the brightest one.
    func shadowOutside(_ shadows: [(alpha: Double, blur: Double, y: Double)]) -> some View {
        let reach = (shadows.map { $0.blur * 2 + abs($0.y) }.max() ?? 0) + 1
        return ZStack {
            ForEach(Array(shadows.enumerated()), id: \.offset) { _, shadow in
                self.fill(Color.black)
                    .shadow(color: .black.opacity(shadow.alpha), radius: CGFloat(shadow.blur), y: CGFloat(shadow.y))
            }
        }
        .padding(CGFloat(reach))
        .mask {
            Rectangle()
                .overlay(self.fill(Color.black).padding(CGFloat(reach)).blendMode(.destinationOut))
                .compositingGroup()
        }
        .padding(-CGFloat(reach))
    }
}

private extension View {
    /// Put a view exactly where the layout says.
    func place(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }
}

private extension View {
    /// Takes the keyboard, so that the arrow keys walk the rows, without
    /// the system's ring around the whole column: the selected row already
    /// says where the keyboard is.
    @ViewBuilder
    func controlRoomListFocus() -> some View {
        if #available(macOS 14.0, *) {
            focusable().focusEffectDisabled()
        } else {
            focusable()
        }
    }
}
