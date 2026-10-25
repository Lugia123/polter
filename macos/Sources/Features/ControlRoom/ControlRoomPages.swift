import SwiftUI

/// The strip itself, over the supervisor's frame where its title was.
struct ControlRoomPageStripView: View {
    typealias Look = ControlRoomLook

    var current: ControlRoomPage
    /// The group's level: the dot before "Performance".
    var level: ControlRoomResourceLevel
    /// What the bar said, for its right end: the supervisor's state and
    /// the take-over button. Nil with no supervisor shown.
    var title: PaneFrame.Title?
    /// The ground of the tab in front: what is under the strip.
    var well: Color
    var select: (ControlRoomPage) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.paneFrameTakeOver) private var takeOver

    private static let face = SafeFace(size: CGFloat(Look.Font.body))
    private static let faceCurrent = SafeFace(size: CGFloat(Look.Font.body), weight: .semibold)

    /// Whether a page's tab carries a mark before its name: the
    /// supervisor's flag; the level's dot on "Performance", only past `ok`.
    static func marked(_ page: ControlRoomPage, level: ControlRoomResourceLevel, theme: Look.Theme) -> Bool {
        switch page {
        case .supervisor: true
        case .performance: level.ink(theme) != nil
        case .chat, .tasks: false
        }
    }

    var body: some View {
        let theme = Look.theme(scheme)
        GeometryReader { proxy in
            let wants = ControlRoomPage.allCases.map { page in
                ControlRoomPageStripLayout.want(
                    name: SafeTextMeasure.width(page.label, in: page == current ? Self.faceCurrent : Self.face).rounded(.up),
                    marked: Self.marked(page, level: level, theme: theme))
            }
            let layout = ControlRoomPageStripLayout(width: proxy.size.width, wants: wants, current: current)
            let foot = CGFloat(Look.StackTab.reverseArcRadius)
            ZStack(alignment: .topLeading) {
                if let front = layout.tabs.first(where: \.current) {
                    PaneStackTabShape(corner: CGFloat(Look.StackTab.cornerRadius), foot: foot,
                                      below: CGFloat(Look.StackTab.overlapBelow))
                        .path(in: CGRect(x: front.x, y: front.y, width: front.width, height: front.height))
                        .fill(well)
                        .allowsHitTesting(false)
                }
                ForEach(layout.tabs, id: \.page) { tab in
                    if tab.separatorBefore {
                        theme.stackTabSeparator.color
                            .frame(width: CGFloat(Look.Line.hairline), height: CGFloat(Look.StackTab.separatorHeight))
                            .offset(x: tab.x - CGFloat(Look.Line.hairline) / 2,
                                    y: tab.y + (tab.height - CGFloat(Look.StackTab.separatorHeight)) / 2)
                            .allowsHitTesting(false)
                    }
                    self.tab(tab, theme: theme)
                        .frame(width: tab.width, height: tab.height)
                        .offset(x: tab.x, y: tab.y)
                }
                if let title, layout.status.width > 0 {
                    status(title, theme: theme)
                        .frame(width: layout.status.width, height: CGFloat(Look.StackTab.height), alignment: .trailing)
                        .offset(x: layout.status.x, y: layout.tabs[0].y)
                }
            }
        }
        .frame(height: CGFloat(Look.StackTab.stripHeight))
        .font(.system(size: CGFloat(Look.Font.body)))
    }

    private func tab(_ tab: ControlRoomPageStripLayout.Tab, theme: Look.Theme) -> some View {
        Button { select(tab.page) } label: {
            HStack(spacing: CGFloat(Look.StackTab.gap)) {
                switch tab.page {
                case .supervisor:
                    PaneSupervisorMark()
                        .fill(tab.current ? theme.text.color : theme.textSecondary.color)
                        .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
                case .performance:
                    if let ink = level.ink(theme) {
                        Circle().fill(ink.base.color)
                            .frame(width: CGFloat(Look.Side.glyph) * 4 / 7, height: CGFloat(Look.Side.glyph) * 4 / 7)
                            .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
                    }
                case .chat, .tasks:
                    EmptyView()
                }
                Text(tab.page.label)
                    .fontWeight(tab.current ? Look.weight(Look.Font.weightEmphasis) : Look.weight(Look.Font.weightBody))
                    .foregroundStyle(tab.current ? theme.text.color : theme.textSecondary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, CGFloat(Look.StackTab.paddingX))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab.current ? .isSelected : [])
    }

    /// The supervisor's state, and the take-over button last, at the right
    /// end -- as the bar wrote them.
    private func status(_ title: PaneFrame.Title, theme: Look.Theme) -> some View {
        // The note whole or not at all (group seq 315, the Windows host's
        // `Side::Whole`): on the strip it is the first to go, and a note cut
        // to "不认得的 C…" says less than none.
        ViewThatFits(in: .horizontal) {
            statusRow(title, note: true, theme: theme)
            statusRow(title, note: false, theme: theme)
        }
    }

    private func statusRow(_ title: PaneFrame.Title, note withNote: Bool, theme: Look.Theme) -> some View {
        HStack(spacing: CGFloat(Look.Pane.barGap)) {
            Spacer(minLength: 0)
            // A supervisor started by hand says so, in the attention ink --
            // the first to give way when the room is short, as on the bar
            // and on Windows (`Side::Squeezed`). 0x373c, group seq 231: the
            // strip drew nothing where the bar said "不认得的 CLI，状态未知",
            // because only the status and the glyph were carried over.
            if withNote, let note = title.note, !note.isEmpty {
                Text(note)
                    .foregroundStyle(theme.attentionText.color)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let said = title.takeOver?.status {
                Text(said)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Only when there is a glyph or a word: an empty stack is still
            // one of this stack's children and costs a `barGap` after the
            // note (0x373c, group seq 261: the note ended 26 from the
            // frame's edge, not 16; a bare window measures the 8).
            let glyph = title.shown.status.flatMap { $0 == .none ? nil : $0 }
            if glyph != nil || !title.word.isEmpty {
                HStack(spacing: CGFloat(Look.Side.statusWordGap)) {
                    if let glyph {
                        ControlRoomGlyph(shown: glyph, still: false)
                            .frame(width: CGFloat(Look.Side.glyph), height: CGFloat(Look.Side.glyph))
                    }
                    if !title.word.isEmpty {
                        Text(title.word)
                            .fontWeight(Look.weight(Look.Font.weightEmphasis))
                            .foregroundStyle(wordInk(title.shown.status, theme: theme))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            if let take = title.takeOver, take.offered, let confirm = take.confirm, let takeOver {
                Button(String(localized: "Let the control room take over?",
                              comment: "总控台：手动启动的总管，标题条上的按钮")) { takeOver(confirm) }
                    .buttonStyle(.link)
                    .fixedSize()
            }
        }
        .monospacedDigit()
    }

    private func wordInk(_ shown: ControlRoomList.Shown?, theme: Look.Theme) -> Color {
        switch shown {
        case .needsYou, .doneUnseen: theme.attentionText.color
        case .trouble: theme.problemTextOnSupervisorBar.color
        // The status's own `.none`, and no status at all.
        case .working, .some(.none), nil: theme.textSecondary.color
        }
    }
}

extension ControlRoomModel {
    /// Whether the right side has pages: a group is selected. Nothing
    /// selected, or a terminal on its own -- which is not a group -- has
    /// none, and the right side is as it was before there were pages.
    var hasPages: Bool {
        guard let row = selectedRow, row.alone == nil else { return false }
        return detail != .nothingSelected
    }

    /// The page in front for the selected group; nil with no pages.
    var pageInFront: ControlRoomPage? {
        guard hasPages, let group = selection else { return nil }
        return pages[group] ?? .supervisor
    }

    /// Bring `page` to the front for the selected group.
    func show(_ page: ControlRoomPage) {
        guard hasPages, let group = selection else { return }
        let was = pages[group] ?? .supervisor
        guard was != page else { return }
        if was.showsTerminal { leavingSupervisorPage() }
        if was == .chat { leavingChatPage() }
        pages[group] = page
        Ghostty.logger.notice("control room: \(group, privacy: .public): page \(String(describing: page), privacy: .public) in front")
    }

    /// The selected group's level, for the dot before "Performance".
    var selectedLevel: ControlRoomResourceLevel {
        selectedRow?.facts?.resourceLevel ?? .none
    }

    // MARK: - The overall view (task 2149, slice 2)

    /// **Whether the right side is showing the whole of Polter** (the
    /// supervisor's ruling of 2026-10-25): it belongs to no group, so it
    /// stands beside "a group is selected" rather than being a page of one.
    /// Nil for every group, and then the right side is the group's own.
    var overallInFront: Bool { showingOverall && overallAsk != nil }

    /// **Whether a piece of the selected group's own side is drawn** (task
    /// 2149, slice 2, the reviewer's second must-fix): its page has to be in
    /// front **and** the whole of Polter must not be.
    ///
    /// One question, asked by every one of those pieces -- the project link
    /// strip over the terminal, the "start a supervisor" sentence when there
    /// is no terminal, the page body -- so that a piece added later has one
    /// thing to ask rather than its own copy of the condition. The two that
    /// only asked `onSupervisorPage` were drawn over the overall view: the
    /// strip over the chart, and the sentence and its button visible and
    /// clickable under a pane that had already taken the right side.
    func groupSideDrawn(_ onSupervisorPage: Bool) -> Bool {
        onSupervisorPage && !overallInFront
    }

    /// Show the overall view on the right side.
    ///
    /// **The group selection is left alone.** Coming back to a group puts
    /// that group back on the page it was left on (`pages[group]`, which
    /// nothing here writes), so nothing about a group's page has to be
    /// remembered twice.
    func showOverall() {
        guard overallAsk != nil else { return }
        guard !showingOverall else { return }
        if pageInFront?.showsTerminal ?? false { leavingSupervisorPage() }
        if pageInFront == .chat { leavingChatPage() }
        showingOverall = true
        Ghostty.logger.notice("control room: the overall view is in front")
    }

    /// Back to the selected group's own page, where it was left.
    func leaveOverall() {
        guard showingOverall else { return }
        showingOverall = false
        Ghostty.logger.notice("control room: the overall view is out of sight")
    }
}

/// What a frame is told about the control room's pages
/// (`PaneFrameChrome.pages`).
struct PaneFramePages {
    var current: ControlRoomPage
    var level: ControlRoomResourceLevel
    var select: (ControlRoomPage) -> Void
}

/// What a page other than the supervisor's shows, where the supervisor's
/// terminal is: the terminal's ground until the page has something of its
/// own (Q7, Q9 and the chat page fill it).
struct ControlRoomPageBody: View {
    typealias Look = ControlRoomLook

    var page: ControlRoomPage
    @ObservedObject var model: ControlRoomModel

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch page {
        case .performance:
            ControlRoomPerfPage(group: model.selection ?? "", source: model.pageSource, overallAsk: model.overallAsk)
        case .tasks:
            ControlRoomTasksPage(group: model.selection ?? "", model: model)
        case .chat:
            ControlRoomChatPage(group: model.selection ?? "", model: model)
        case .supervisor:
            Look.theme(scheme).terminalBackground.color
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(page.label)
        }
    }
}
