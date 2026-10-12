import AppKit
import SwiftUI

/// The control room's group list (`control-room.md`, 3.1, 3.2 and 3.5): the
/// groups waiting for you -- who waits, and for what -- and the ones that
/// need nothing, each with what it is doing when the core knows.
///
/// **Nothing here says how long.** The minutes on each row and the band of
/// today's waiting along the bottom were taken out (the user, 2026-10-13:
/// they do nothing but tell you that you have been slow). The bottom left
/// holds how much of each account's allowance is used
/// (`ControlRoomQuotaView`), which is something to act on.
///
/// It draws a `ControlRoomList` and decides nothing about it. Every size and
/// colour is `ControlRoomLook`'s, and every position is
/// `ControlRoomListLayout`'s; this file has no numbers of its own.
///
/// **A row has nothing to press but itself.** It says that somebody is
/// waiting and for what; it does not answer for the person. Approve and
/// refuse buttons were on the waiting rows for one build and were taken
/// off (the user, 2026-10-12): a row is too small to show what would be
/// approved, and what an agent asks is often not a yes or a no. The person
/// goes into the terminal. `tools/control-room-rows-only-tell.py` holds
/// this.
///
/// The one button is "new group": pressing it puts a field for the name
/// where the header was. Return makes the group, Escape gives up, and a
/// name the core refuses is said under the field, which stays.
struct ControlRoomListView: View {
    typealias Look = ControlRoomLook
    typealias Row = ControlRoomList.Row

    var list: ControlRoomList
    @Binding var selection: String?
    /// Make a group by this name. Returns what to tell the person when it
    /// was not made; nil when it was.
    var onNewGroup: (String) -> String? = { _ in nil }
    /// Whether the chip is the system's glass while it slides, which bends
    /// what is under its edge. The table's to say; a still picture turns
    /// it off, because the system's glass cannot be drawn off screen.
    var refraction: Bool = Look.Selection.refractionShown
    /// Stops every motion, as Reduce Motion does. For still pictures.
    var still: Bool = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 at rest, 1 while the chip is in the air.
    @State private var lift: CGFloat
    @State private var landing: DispatchWorkItem?
    /// The person pressed "new group" and has not made one or given up.
    @State private var naming = false
    @State private var newName = ""
    /// Why the name as typed made no group.
    @State private var nameRefusal: String?
    @FocusState private var nameHasKeyboard: Bool
    /// The list itself has the keyboard: the arrow keys walk the rows.
    @FocusState private var listHasKeyboard: Bool

    /// `midSlide` draws the chip as it is in the air, this far from its
    /// row, and moves nothing: for still pictures of the slide.
    init(list: ControlRoomList, selection: Binding<String?>, onNewGroup: @escaping (String) -> String? = { _ in nil },
         refraction: Bool = Look.Selection.refractionShown, still: Bool = false, midSlide: CGSize? = nil) {
        self.list = list
        self._selection = selection
        self.onNewGroup = onNewGroup
        self.refraction = refraction
        self.still = still
        self.away = midSlide ?? .zero
        self._lift = State(initialValue: midSlide == nil ? 0 : 1)
    }

    private let away: CGSize

    private var theme: Look.Theme { Look.theme(scheme) }
    private var moves: Bool { !still && !reduceMotion }

    var body: some View {
        GeometryReader { proxy in
            // Why a name made no group stands under the field, and the
            // rows move down to make room for it.
            let note = naming ? nameRefusal : nil
            let layout = ControlRoomListLayout(list: list, height: proxy.size.height,
                                               noteUnderHeader: note.map(Self.noteHeight) ?? 0,
                                               needed: ControlRoomAskText.needed)
            ZStack(alignment: .topLeading) {
                if let chip = layout.chip(for: selection) {
                    self.chip.place(chip.offsetBy(dx: away.width, dy: away.height))
                }
                if naming {
                    nameField.place(layout.header)
                } else {
                    header.place(layout.header)
                }
                ForEach(list.waiting) { row in
                    waitingRow(row, fit: layout.fits[row.id] ?? .none).place(layout.rows[row.id] ?? .zero)
                }
                if layout.quietHeader.height > 0 {
                    theme.lineFaint.color.place(layout.separator)
                    quietHeader.place(layout.quietHeader)
                }
                ForEach(list.quiet) { row in
                    quietRow(row).place(layout.rows[row.id] ?? .zero)
                }
                if let quota = list.quota {
                    ControlRoomQuotaView(quota: quota, still: still).place(layout.quota)
                }
                // In the room the layout left under the header.
                if let note {
                    nameNote(note)
                        .frame(width: layout.header.width, height: Self.noteHeight(note), alignment: .topLeading)
                        .offset(x: layout.header.minX, y: layout.header.maxY)
                }
            }
        }
        .frame(width: CGFloat(Look.Side.width))
        .background(panel)
        .font(.system(size: CGFloat(Look.Font.body)))
        .monospacedDigit()
        .foregroundStyle(theme.text.color)
        .controlRoomListFocus()
        .focused($listHasKeyboard)
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
        let layout = ControlRoomListLayout(list: list, height: 0, needed: ControlRoomAskText.needed)
        let plan = id.flatMap { layout.chip(for: $0) }.map {
            ControlRoomChipSlide.plan(from: layout.chip(for: selection), to: $0, reduceMotion: !moves)
        }
        if case .slide = plan {
            withAnimation(spring) { selection = id }
        } else {
            // Nothing to slide from or to, or Reduce Motion: it is simply
            // there. Also a row pressed again, which is still the person's
            // doing: a row the control room opened on is theirs once they
            // press it.
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
        DispatchQueue.main.asyncAfter(deadline: .now() + ControlRoomChipSlide.landsAt, execute: land)
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
            .background(glass(in: shape))
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

    /// The system's glass under the chip's tint: only while the chip is in
    /// the air, unless the table says at rest too. Sitting still there is
    /// nothing live behind the chip, so nothing is recomposited when the
    /// terminal beside it scrolls.
    @ViewBuilder
    private func glass(in shape: RoundedRectangle) -> some View {
        if #available(macOS 26.0, *), refraction, !still, lift > 0 || Look.Selection.glassAtRest {
            Color.clear
                .glassEffect(.clear, in: shape)
                .opacity(Look.Selection.glassAtRest ? 1 : Double(lift))
        }
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
            Text(ControlRoomList.headerText(waiting: list.waitingCount))
                .fontWeight(Look.weight(Look.Font.weightEmphasis))
            Spacer(minLength: CGFloat(Look.Side.rowItemGap))
            Button(action: beginNaming) {
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

    // MARK: A new group

    private func beginNaming() {
        newName = ""
        nameRefusal = nil
        naming = true
        // After the field is there to take it.
        DispatchQueue.main.async { nameHasKeyboard = true }
    }

    private func endNaming() {
        naming = false
        nameRefusal = nil
        nameHasKeyboard = false
        // Back to the list, so that the arrow keys work at once: with the
        // field gone the keyboard was left on the window, on nothing.
        DispatchQueue.main.async { listHasKeyboard = true }
    }

    /// How wide the words of the note under the field are set.
    private static var noteWidth: CGFloat {
        CGFloat(Look.Side.width) - 2 * CGFloat(Look.Space.sidePanelPadding) - 2 * CGFloat(Look.Side.headerPaddingX)
    }

    /// How high the note is with these words in it: its lines, and the
    /// row's padding above and below.
    static func noteHeight(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: CGFloat(Look.Font.body))
        let box = (text as NSString).boundingRect(
            with: CGSize(width: noteWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return ceil(box.height) + 2 * CGFloat(Look.Side.rowPaddingY)
    }

    private func submitName() {
        nameRefusal = onNewGroup(newName)
        if nameRefusal == nil {
            endNaming()
        } else {
            // Still theirs to put right.
            nameHasKeyboard = true
        }
    }

    /// Where the header was: the name of the group being made.
    private var nameField: some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row), style: .continuous)
        return TextField(
            String(localized: "Group name", comment: "总控台：新建群时输入框里的占位字"),
            text: $newName)
            .textFieldStyle(.plain)
            .font(.system(size: CGFloat(Look.Font.body), design: .monospaced))
            .focused($nameHasKeyboard)
            .onSubmit(submitName)
            .onExitCommand(perform: endNaming)
            .padding(.horizontal, CGFloat(Look.Side.rowPaddingX))
            .frame(maxHeight: .infinity)
            .background(shape.strokeBorder(theme.attentionText.color, lineWidth: CGFloat(Look.Line.hairline)))
            .padding(.horizontal, CGFloat(Look.Side.headerPaddingX) - CGFloat(Look.Side.rowPaddingX))
            .accessibilityLabel(String(localized: "New Group", comment: "总控台：左栏右上的按钮"))
    }

    /// Why the name made no group, under the field.
    private func nameNote(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(theme.problemTextOnRow.color)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, CGFloat(Look.Side.rowPaddingX))
            .padding(.vertical, CGFloat(Look.Side.rowPaddingY))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row), style: .continuous)
                    .fill(theme.windowBase.color))
            .padding(.horizontal, CGFloat(Look.Side.headerPaddingX) - CGFloat(Look.Side.rowPaddingX))
    }

    private var quietHeader: some View {
        Text(String(localized: "\(String(list.quietCount)) groups need nothing from you", comment: "总控台：左栏第二段的标题"))
            .foregroundStyle(theme.textSecondary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CGFloat(Look.Side.headerPaddingX))
    }

    /// The colour of a status word.
    private func ink(_ shown: ControlRoomList.Shown, selected: Bool) -> Color {
        switch shown {
        case .needsYou, .doneUnseen:
            return theme.attentionText.color
        case .trouble:
            // Where the word is not red is the table's to say (`text_on`).
            return (selected ? theme.problemTextOnRowSelected : theme.problemTextOnRow).color
        case .working, .none:
            return theme.textSecondary.color
        }
    }

    /// The column every row's glyph stands in, so that the eye runs down
    /// one line of them.
    private func glyphColumn<Glyph: View>(height: Double, @ViewBuilder _ glyph: () -> Glyph) -> some View {
        // The column is there whether or not there is a glyph to stand in it.
        Color.clear
            .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(height))
            .overlay(glyph())
    }

    /// One line of what a row says under its first line, in the secondary
    /// colour: how many steps are not shown, how many others wait.
    private func note(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(theme.textSecondary.color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: CGFloat(Look.Side.askLineHeight),
                   maxHeight: CGFloat(Look.Side.askLineHeight), alignment: .leading)
    }

    /// Who is waiting: the worker's name in the terminal's face, the rest
    /// in the interface's.
    private func who(_ waiter: ControlRoomList.Waiter) -> Text? {
        guard let said = ControlRoomList.waiterText(waiter) else { return nil }
        var text = AttributedString(said)
        if !waiter.name.isEmpty, let name = text.range(of: waiter.name) {
            text[name].font = .system(size: CGFloat(Look.Font.body), design: .monospaced)
        }
        return Text(text)
    }

    /// A group that is waiting: the glyph in its column; the name, and at
    /// the right who is waiting and for which of the four; then what it is
    /// waiting for -- a sentence in the interface's face, a command in the
    /// terminal's, one step to a line. `fit` is how many lines each step
    /// has (`ControlRoomAskFit`); the row's height came from the same.
    private func waitingRow(_ row: Row, fit: ControlRoomAskFit) -> some View {
        let selected = row.id == selection
        let gap = CGFloat(Look.Side.rowItemGap)
        // Who gets how much of the first line is the rule's
        // (`ControlRoomLine1`); what is measured here is only how wide each
        // would be alone.
        let nameFont = NSFont.monospacedSystemFont(
            ofSize: CGFloat(Look.Font.groupName),
            weight: Self.weight(selected ? Look.Font.weightStrong : Look.Font.weightGroupName))
        let wordFont = NSFont.systemFont(ofSize: CGFloat(Look.Font.body), weight: Self.weight(Look.Font.weightEmphasis))
        let whoText = who(row.waiter)
        let line1 = ControlRoomLine1.fit(
            width: Double(ControlRoomListLayout.askWidth), gap: Double(gap),
            name: Double(Self.width(of: row.name, font: nameFont)),
            who: whoText.map { _ in Double(Self.whoWidth(row.waiter)) },
            word: row.word.isEmpty ? 0 : Double(Self.width(of: row.word, font: wordFont)))
        return HStack(alignment: .top, spacing: gap) {
            glyphColumn(height: Look.Side.rowLine1Height) {
                ControlRoomGlyph(shown: row.shown, pulses: row.pulses, still: still)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(row.name)
                        .font(.system(size: CGFloat(Look.Font.groupName), design: .monospaced))
                        .fontWeight(Look.weight(selected ? Look.Font.weightStrong : Look.Font.weightGroupName))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: CGFloat(line1.name), alignment: .leading)
                    Spacer(minLength: 0)
                    if let whoText, let room = line1.who {
                        // Cut from its start: the end of a long title is
                        // the part that tells two workers apart.
                        whoText.foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(width: CGFloat(room), alignment: .trailing)
                            .padding(.leading, gap)
                    }
                    if !row.word.isEmpty {
                        Text(row.word)
                            .fontWeight(Look.weight(Look.Font.weightEmphasis))
                            .foregroundStyle(ink(row.shown, selected: selected))
                            .fixedSize()
                            .padding(.leading, gap)
                    }
                }
                .frame(height: CGFloat(Look.Side.rowLine1Height))
                // Only the steps that have lines: the rest are counted below.
                ForEach(Array(zip(row.what.drawn, fit.lines).enumerated()), id: \.offset) { _, step in
                    ControlRoomAskText(text: step.0, code: row.what.isCode, lines: step.1)
                }
                if let hidden = ControlRoomList.hiddenStepsText(fit.hidden) {
                    note(hidden)
                }
                // 暂定: a line of its own under what the row waits on. The
                // design drew no row with a second thing waiting.
                if let others = ControlRoomList.othersText(row.others) {
                    note(others)
                }
            }
        }
        .padding(.horizontal, CGFloat(Look.Side.rowPaddingX))
        .padding(.vertical, CGFloat(Look.Side.rowPaddingY))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { select(row.id) }
        .help(ControlRoomList.tooltip(for: row) ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ControlRoomList.spoken(row))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The face's weight for one of the table's.
    private static func weight(_ value: Double) -> NSFont.Weight {
        switch value {
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        default: return .bold
        }
    }

    /// How wide `text` is on one line, rounded up so that a text that fits
    /// exactly is not cut by a fraction of a point.
    static func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
    }

    /// How wide who is waiting would be alone: the worker's name in the
    /// terminal's face, the rest in the interface's, as `who` sets them.
    static func whoWidth(_ waiter: ControlRoomList.Waiter) -> CGFloat {
        guard let said = ControlRoomList.waiterText(waiter) else { return 0 }
        let size = CGFloat(Look.Font.body)
        let text = NSMutableAttributedString(string: said, attributes: [.font: NSFont.systemFont(ofSize: size)])
        if !waiter.name.isEmpty {
            let range = (said as NSString).range(of: waiter.name)
            if range.location != NSNotFound {
                text.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), range: range)
            }
        }
        return ceil(text.size().width) + 1
    }

    /// A group that needs nothing: the glyph in the same column, the name,
    /// and what it is doing. A group with nothing to say is its name alone,
    /// a step back.
    private func quietRow(_ row: Row) -> some View {
        let selected = row.id == selection
        let said = ControlRoomList.quietText(row)
        let idle = row.shown == .none && said.isEmpty
        return HStack(spacing: CGFloat(Look.Side.rowItemGap)) {
            glyphColumn(height: Look.Side.glyph) {
                if row.shown != .none {
                    ControlRoomGlyph(shown: row.shown, still: still)
                }
            }
            Text(row.name)
                .font(.system(size: CGFloat(Look.Font.body), design: .monospaced))
                .fontWeight(Look.weight(selected ? Look.Font.weightStrong : Look.Font.weightBody))
                .foregroundStyle((idle && !selected ? theme.textSecondary : theme.text).color)
                .lineLimit(1)
                .fixedSize()
            Text(said)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CGFloat(Look.Side.rowPaddingX))
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { select(row.id) }
        .help(said)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ControlRoomList.spoken(row))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// One step of what a row waits on: so many lines of it, each
/// `ask_line_height` high, the last ending in an ellipsis when there is
/// more.
///
/// It also measures: how many lines a step would take with all the room it
/// wanted is asked of the same two faces, at the same width, that draw it.
struct ControlRoomAskText: View {
    typealias Look = ControlRoomLook

    var text: String
    var code: Bool
    var lines: Int

    @Environment(\.colorScheme) private var scheme

    static func face(code: Bool) -> NSFont {
        let size = CGFloat(Look.Font.body)
        return code ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
    }

    /// What one line of `font` is high when nothing is added between lines.
    static func natural(_ font: NSFont) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: font)
    }

    /// How many lines `text` takes at the width a row gives it.
    static func needed(_ text: String, code: Bool) -> Int {
        guard !text.isEmpty else { return 1 }
        let font = face(code: code)
        let box = (text as NSString).boundingRect(
            with: CGSize(width: ControlRoomListLayout.askWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font])
        return max(1, Int((box.height / natural(font)).rounded()))
    }

    var body: some View {
        let font = Self.face(code: code)
        let lineH = CGFloat(Look.Side.askLineHeight)
        let extra = max(0, lineH - Self.natural(font))
        Text(text)
            .font(Font(font))
            .lineSpacing(extra)
            .lineLimit(lines)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .foregroundStyle(Look.theme(scheme).text.color)
            .padding(.top, extra / 2)
            .frame(maxWidth: .infinity, minHeight: lineH * CGFloat(lines), maxHeight: lineH * CGFloat(lines),
                   alignment: .topLeading)
    }
}

extension InsettableShape {
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
