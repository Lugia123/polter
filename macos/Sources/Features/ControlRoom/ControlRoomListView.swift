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
    /// "OK" on the notice that the first sweep of old records is waiting.
    var onRetentionAgree: () -> Void = {}
    /// Which cards are wholly on screen, each time that changes
    /// (`ControlRoomListLayout.inSight`).
    var onInSight: ([String]) -> Void = { _ in }
    /// Return while the list has the keyboard: the selected group's
    /// supervisor (task 1551).
    var onEnter: () -> Void = {}
    /// "Fix" on a card that reads "Failed" (task 1560), and why the last
    /// one was refused, on which row.
    var onFix: (Row) -> Void = { _ in }
    var fixRefusal: (row: String, message: String)?
    /// Whether the chip is the system's glass while it slides, which bends
    /// what is under its edge. The table's to say; a still picture turns
    /// it off, because the system's glass cannot be drawn off screen.
    var refraction: Bool = Look.Selection.refractionShown
    /// Stops every motion, as Reduce Motion does. For still pictures.
    var still: Bool = false
    /// The menu a right-click on a row opens (task 1660); nil for none.
    var menu: (Row) -> NSMenu? = { _ in nil }
    /// The row whose name is a field, and what the field says and does.
    var renaming: ControlRoomRowMenuState.Renaming?
    var onRenameTyped: (String) -> Void = { _ in }
    var onRenameSubmit: () -> Void = {}
    var onRenameCancel: () -> Void = {}
    /// The line under a row, by row: what its supervisor was asked, or
    /// why something the menu did was refused (task 1660).
    var rowLines: [String: ControlRoomRowMenuState.RowLine] = [:]
    /// Whether "Archived" at the bottom is open, and opening or closing it.
    var archivedOpen = false
    var onToggleArchived: () -> Void = {}
    /// The menu a right-click on an archived group opens.
    var archivedMenu: (ControlRoomList.ArchivedGroup) -> NSMenu? = { _ in nil }

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
    /// How far the rows are scrolled up (`ControlRoomListLayout.inSight`).
    @State private var scrolled: CGFloat = 0
    /// Moves the rows' scroll view.
    @State private var scroller = ControlRoomScroller()

    /// `midSlide` draws the chip as it is in the air, this far from its
    /// row, and moves nothing: for still pictures of the slide.
    init(list: ControlRoomList, selection: Binding<String?>, onNewGroup: @escaping (String) -> String? = { _ in nil },
         onRetentionAgree: @escaping () -> Void = {},
         onInSight: @escaping ([String]) -> Void = { _ in },
         onEnter: @escaping () -> Void = {},
         onFix: @escaping (Row) -> Void = { _ in },
         fixRefusal: (row: String, message: String)? = nil,
         refraction: Bool = Look.Selection.refractionShown, still: Bool = false, midSlide: CGSize? = nil,
         menu: @escaping (Row) -> NSMenu? = { _ in nil },
         renaming: ControlRoomRowMenuState.Renaming? = nil,
         onRenameTyped: @escaping (String) -> Void = { _ in },
         onRenameSubmit: @escaping () -> Void = {},
         onRenameCancel: @escaping () -> Void = {},
         rowLines: [String: ControlRoomRowMenuState.RowLine] = [:],
         archivedOpen: Bool = false,
         onToggleArchived: @escaping () -> Void = {},
         archivedMenu: @escaping (ControlRoomList.ArchivedGroup) -> NSMenu? = { _ in nil }) {
        self.list = list
        self._selection = selection
        self.onNewGroup = onNewGroup
        self.onRetentionAgree = onRetentionAgree
        self.onInSight = onInSight
        self.onEnter = onEnter
        self.onFix = onFix
        self.fixRefusal = fixRefusal
        self.refraction = refraction
        self.still = still
        self.menu = menu
        self.renaming = renaming
        self.onRenameTyped = onRenameTyped
        self.onRenameSubmit = onRenameSubmit
        self.onRenameCancel = onRenameCancel
        self.rowLines = rowLines
        self.archivedOpen = archivedOpen
        self.onToggleArchived = onToggleArchived
        self.archivedMenu = archivedMenu
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
            // The first sweep waiting for the person takes the same room,
            // when no refusal is there to take it (task 1511).
            let retention = note == nil ? list.retentionWaitingBytes : nil
            let retentionText = retention.map(LogManagementRules.noticeTitle)
            let layout = layout(height: proxy.size.height,
                                noteUnderHeader: note.map(Self.noteHeight)
                                    ?? retentionText.map { Self.noteHeight($0) + ControlRoomRetentionNotice.buttonHeight } ?? 0)
            ZStack(alignment: .topLeading) {
                if naming {
                    nameField.place(layout.header)
                } else {
                    header.place(layout.header)
                }
                rows(layout).place(layout.viewport)
                if let quota = list.quota {
                    ControlRoomQuotaView(quota: quota, still: still).place(layout.quota)
                }
                if let retentionText {
                    ControlRoomRetentionNotice(text: retentionText, onAgree: onRetentionAgree)
                        .frame(width: layout.header.width, alignment: .topLeading)
                        .offset(x: layout.header.minX, y: layout.header.maxY)
                }
                // In the room the layout left under the header.
                if let note {
                    nameNote(note)
                        .frame(width: layout.header.width, height: Self.noteHeight(note), alignment: .topLeading)
                        .offset(x: layout.header.minX, y: layout.header.maxY)
                }
            }
            .onAppear { onInSight(layout.inSight(order: list.rows.map(\.id), scrolled: scrolled)) }
            .onChange(of: layout.inSight(order: list.rows.map(\.id), scrolled: scrolled)) { onInSight($0) }
        }
        .frame(width: CGFloat(Look.Side.width))
        .background(ControlRoomSidePanel())
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
        // Only while the list itself has the keyboard: Return in the new
        // group's name field -- or any text box -- is that box's (#1554).
        // `listHasKeyboard` alone cannot say so: it is true with the
        // keyboard anywhere inside the list, the name field included.
        .backport.onKeyPress(.return) { _ in
            let text = nameHasKeyboard || Self.isText(NSApp.keyWindow?.firstResponder)
            switch ControlRoomRules.returnOwner(
                textHasKeyboard: text, listHasKeyboard: listHasKeyboard, hasSelection: selection != nil) {
            case .list:
                onEnter()
                return .handled
            case .text, .nobody:
                return .ignored
            }
        }
        .onChange(of: selection) { _ in takeOff() }
    }

    /// The text of the line under each row that has one: why its new name
    /// is refused, while it is being renamed and that is so; otherwise what
    /// its supervisor was asked or what was refused.
    private var lineTexts: [String: (text: String, delivered: Bool, refusal: Bool)] {
        var out = rowLines.mapValues { (text: $0.text, delivered: $0.delivered, refusal: false) }
        if let renaming, let refusal = renaming.refusal {
            out[renaming.row] = (refusal, false, true)
        }
        return out
    }

    /// Where everything is, with the menu's lines and the groups put away
    /// counted in (`ControlRoomListLayout`, task 1661): the one place the
    /// list's layout is made, so the chip and the rows agree.
    private func layout(height: CGFloat, noteUnderHeader: CGFloat) -> ControlRoomListLayout {
        ControlRoomListLayout(list: list, height: height, noteUnderHeader: noteUnderHeader,
                              needed: ControlRoomAskText.needed,
                              linesUnder: Set(lineTexts.keys),
                              archived: list.archived.map(\.name), archivedOpen: archivedOpen)
    }

    /// A line under a row, its text where the row's name starts.
    @ViewBuilder
    private func lineUnder(_ id: String) -> some View {
        if let line = lineTexts[id] {
            Group {
                if line.refusal {
                    ControlRoomRowRefusal(text: line.text)
                } else {
                    ControlRoomAskedLine(text: line.text, delivered: line.delivered)
                }
            }
            .padding(.leading, CGFloat(Look.Side.rowPaddingX) + CGFloat(Look.Side.glyph) + CGFloat(Look.Side.rowItemGap))
            .padding(.trailing, CGFloat(Look.Side.rowPaddingX))
        }
    }

    /// A group put away: its name and the day, a step back, and the menu
    /// for it on a right-click.
    private func archivedRow(_ group: ControlRoomList.ArchivedGroup) -> some View {
        HStack(spacing: CGFloat(Look.Side.rowItemGap)) {
            Color.clear.frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
            Text(group.name)
                .font(.system(size: CGFloat(Look.Font.body), design: .monospaced))
                .lineLimit(1)
                .fixedSize()
            Text(ControlRoomGroupWords.archivedOn(group.archivedMs, calendar: .current, locale: .current))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.textTertiary.color)
        .padding(.horizontal, CGFloat(Look.Side.rowPaddingX))
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .overlay { ControlRoomRightClick { archivedMenu(group) } }
    }

    /// The chip and the rows, clipped to the room above the allowance block
    /// and scrolled inside it (task 1654). Each piece stands where the
    /// layout put it, less the viewport's top; a row is moved there by
    /// padding rather than an offset, so that its frame is where it is seen.
    private func rows(_ layout: ControlRoomListLayout) -> some View {
        let top = layout.viewport.minY
        func inside(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: 0, dy: -top) }
        return ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                if let chip = layout.chip(for: selection) {
                    self.chip.place(inside(chip).offsetBy(dx: away.width, dy: away.height))
                }
                ForEach(list.waiting) { row in
                    waitingRow(row, fit: layout.fits[row.id] ?? .none)
                        .stand(inside(layout.rows[row.id] ?? .zero))
                }
                if layout.quietHeader.height > 0 {
                    theme.lineFaint.color.place(inside(layout.separator))
                    quietHeader.place(inside(layout.quietHeader))
                }
                ForEach(list.quiet) { row in
                    // The row is its own height; the line under it is apart.
                    let rect = layout.rows[row.id] ?? .zero
                    let line = layout.lineRects[row.id]?.height ?? 0
                    quietRow(row).stand(inside(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - line)))
                }
                // In the core's order of the rows, as everything else.
                ForEach(list.rows.filter { layout.lineRects[$0.id] != nil }) { row in
                    lineUnder(row.id).stand(inside(layout.lineRects[row.id] ?? .zero))
                }
                if layout.archivedHeader.height > 0 {
                    theme.lineFaint.color.place(inside(layout.archivedSeparator))
                    ControlRoomArchivedHeader(count: list.archived.count, open: archivedOpen, onToggle: onToggleArchived)
                        .place(inside(layout.archivedHeader))
                }
                ForEach(list.archived) { group in
                    if let rect = layout.archivedRows[group.name] {
                        archivedRow(group).stand(inside(rect))
                    }
                }
            }
            .frame(width: layout.viewport.width, height: layout.contentHeight, alignment: .topLeading)
            .background(ControlRoomScrollReader(scroller: scroller) { scrolled = $0 })
        }
        .onAppear { reveal(selection, in: layout) }
        .onChange(of: selection) { reveal($0, in: layout) }
        // The selection moved in the list without being changed -- a group
        // made, or pinned, above it pushed it down (task 1664): into sight
        // again. Where it was laid out, not where it is seen, so scrolling
        // away from it is left alone.
        .onChange(of: selection.flatMap { layout.rows[$0] }) { frame in
            // From the frame handed in, not `layout`: what this closure
            // holds is from before the change (measured: it still had the
            // row where it was, and said it was in sight). The viewport is
            // the same. And on the next turn, when the scroll view's
            // content has grown to the new list -- a scroll past its old
            // end would be held at it.
            guard let frame,
                  let to = ControlRoomListLayout.reveal(row: frame, viewport: layout.viewport, scrolled: scrolled) else { return }
            DispatchQueue.main.async { scroller.scroll(to: to) }
        }
    }

    /// Brings a row wholly into sight, by the least scroll that does.
    ///
    /// By setting the scroll view's offset to what the layout says, not by
    /// `ScrollViewReader.scrollTo`: with these rows its `.top` anchor
    /// scrolled to the top of the list rather than to the row (task 1654,
    /// measured off screen). Not animated, while the chip is.
    private func reveal(_ id: String?, in layout: ControlRoomListLayout) {
        guard let to = layout.reveal(id, scrolled: scrolled) else { return }
        scroller.scroll(to: to)
    }

    /// Whether the window's first responder is somewhere text is typed: a
    /// text field, or the field editor one is using (an `NSText`).
    static func isText(_ responder: NSResponder?) -> Bool {
        responder is NSText || responder is NSTextField
    }

    // MARK: Selection

    private var spring: Animation {
        .spring(response: Look.Selection.springPeriod, dampingFraction: Look.Selection.springDamping)
    }

    /// Selecting is one call whether it came from a click or a key, so both
    /// slide the chip the same way.
    private func select(_ id: String?) {
        let layout = layout(height: 0, noteUnderHeader: 0)
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

    private var header: some View {
        HStack(spacing: 0) {
            Text(list.waitingHeaderText)
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
        Text(list.quietHeaderText)
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

    /// How wide the pinned and muted marks after a name are, with the gap
    /// before them: none when there are none.
    static func marksWidth(_ facts: ControlRoomList.GroupFacts?) -> CGFloat {
        let n = [facts?.pinned == true, facts?.muted == true].filter { $0 }.count
        guard n > 0 else { return 0 }
        return CGFloat(Look.Side.rowItemGap) + CGFloat(n) * CGFloat(Look.Side.glyph)
            + CGFloat(n - 1) * CGFloat(Look.Side.markGap)
    }

    /// The marks after a row's name.
    @ViewBuilder
    private func marks(_ row: Row) -> some View {
        if let facts = row.facts, facts.pinned || facts.muted {
            ControlRoomRowMarks(pinned: facts.pinned, muted: facts.muted)
                .padding(.leading, CGFloat(Look.Side.rowItemGap))
        }
    }

    /// The field a row's name becomes while it is renamed, at the name's
    /// size; nil when this row is not being renamed.
    private func renameField(_ row: Row, size: Double) -> ControlRoomRenameField? {
        guard let renaming, renaming.row == row.id else { return nil }
        return ControlRoomRenameField(
            text: Binding(get: { renaming.draft }, set: { onRenameTyped($0) }),
            refused: renaming.refusal != nil,
            size: size,
            onSubmit: onRenameSubmit,
            onCancel: onRenameCancel)
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
        // The marks after the name take its room on the line: they are
        // measured with it, and the name is cut before they are.
        let marksWidth = Self.marksWidth(row.facts)
        let line1 = ControlRoomLine1.fit(
            width: Double(ControlRoomListLayout.askWidth), gap: Double(gap),
            name: Double(Self.width(of: row.name, font: nameFont) + marksWidth),
            who: whoText.map { _ in Double(Self.whoWidth(row.waiter)) },
            word: row.word.isEmpty ? 0 : Double(Self.width(of: row.word, font: wordFont)))
        return HStack(alignment: .top, spacing: gap) {
            glyphColumn(height: Look.Side.rowLine1Height) {
                ControlRoomGlyph(shown: row.shown, pulses: row.pulses, still: still)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if let field = renameField(row, size: Look.Font.groupName) {
                        // Who waits and for what fold away while it is
                        // renamed (design v21 `03`).
                        field.frame(maxWidth: .infinity)
                    } else {
                    Text(row.name)
                        .font(.system(size: CGFloat(Look.Font.groupName), design: .monospaced))
                        .fontWeight(Look.weight(selected ? Look.Font.weightStrong : Look.Font.weightGroupName))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: max(0, CGFloat(line1.name) - marksWidth), alignment: .leading)
                    marks(row)
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
        // While its name is a field, the field is reachable on its own.
        .accessibilityElement(children: renaming?.row == row.id ? .contain : .ignore)
        .accessibilityLabel(ControlRoomList.spoken(row))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .overlay { ControlRoomRightClick { menu(row) } }
        // Over the row and not in it: the row is one element to the
        // accessibility tree, and the button is a second, beside it. In the
        // room `rowHeight` left at the bottom, under the row's text.
        .overlay(alignment: .bottomLeading) {
            if row.fix != .none {
                ControlRoomFixLine(
                    fix: row.fix,
                    refusal: fixRefusal.flatMap { $0.row == row.id ? $0.message : nil },
                    onFix: { onFix(row) })
                    .padding(.leading, CGFloat(Look.Side.rowPaddingX) + CGFloat(Look.Side.glyph) + gap)
                    .padding(.trailing, CGFloat(Look.Side.rowPaddingX))
                    .padding(.bottom, CGFloat(Look.Side.rowPaddingY))
            }
        }
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
            if let field = renameField(row, size: Look.Font.body) {
                field
            } else {
                Text(row.name)
                    .font(.system(size: CGFloat(Look.Font.body), design: .monospaced))
                    .fontWeight(Look.weight(selected ? Look.Font.weightStrong : Look.Font.weightBody))
                    .foregroundStyle((idle && !selected ? theme.textSecondary : theme.text).color)
                    .lineLimit(1)
                    .fixedSize()
                // Right after the name, before what it is doing; the row's
                // gap is already `row_item_gap`.
                if let facts = row.facts, facts.pinned || facts.muted {
                    ControlRoomRowMarks(pinned: facts.pinned, muted: facts.muted)
                }
                Text(said)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, CGFloat(Look.Side.rowPaddingX))
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { select(row.id) }
        .help(said)
        // While its name is a field, the field is reachable on its own.
        .accessibilityElement(children: renaming?.row == row.id ? .contain : .ignore)
        .accessibilityLabel(ControlRoomList.spoken(row))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .overlay { ControlRoomRightClick { menu(row) } }
    }
}

/// The ground of a panel at the side of the control room: the group list,
/// and the group's note when it is being edited (task 1660), which is the
/// same kind of thing at the other side.
struct ControlRoomSidePanel: View {
    typealias Look = ControlRoomLook

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        let shape = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.sidePanel), style: .continuous)
        let hairline = CGFloat(Look.Line.hairline)
        shape
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

    /// The same, by padding: the row's frame is then where it is seen.
    func stand(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height)
            .padding(.leading, rect.minX)
            .padding(.top, rect.minY)
    }
}

/// The rows' scroll view, once it is there, to be scrolled.
/// A scroll asked for before the scroll view is there -- the list opening
/// on a row below the bottom -- is made when it arrives.
final class ControlRoomScroller {
    fileprivate weak var clip: NSClipView? {
        didSet { if clip != nil, let waiting { self.waiting = nil; scroll(to: waiting) } }
    }
    private var waiting: CGFloat?

    func scroll(to y: CGFloat) {
        guard let clip, let scrollView = clip.enclosingScrollView else { waiting = y; return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// How far the scroll view this sits in is scrolled, from the scroll view
/// itself, each time it moves. A `GeometryReader` in the scrolled content
/// was tried first and was not told when the rows scrolled, so what the
/// selection was brought into sight from was stale (task 1654, measured
/// off screen: the second row from the bottom scrolled to although in
/// sight, and the first row never scrolled back to).
private struct ControlRoomScrollReader: NSViewRepresentable {
    var scroller: ControlRoomScroller
    var onScroll: (CGFloat) -> Void

    final class Reader: NSView {
        var onScroll: (CGFloat) -> Void = { _ in }
        var scroller: ControlRoomScroller?
        private var watched: NSClipView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watch(enclosingScrollView?.contentView)
        }

        private func watch(_ clip: NSClipView?) {
            guard clip !== watched else { return }
            if let watched { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: watched) }
            watched = clip
            scroller?.clip = clip
            guard let clip else { return }
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(moved),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
            moved()
        }

        @objc private func moved() {
            guard let watched else { return }
            let y = watched.bounds.origin.y
            DispatchQueue.main.async { [onScroll] in onScroll(y) }
        }
    }

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.onScroll = onScroll
        view.scroller = scroller
        return view
    }

    func updateNSView(_ view: Reader, context: Context) {
        view.onScroll = onScroll
        view.scroller = scroller
        if let clip = view.enclosingScrollView?.contentView, clip !== scroller.clip { scroller.clip = clip }
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
