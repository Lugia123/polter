import SwiftUI

/// The task page's answer for one group (task 2015, Q9; API.md §2.2):
/// asked when the page comes in front, when the core says the control room
/// changed, and when a task is opened or shut or the closed ones are listed
/// or folded. **Never on a timer.**
final class ControlRoomTasksFeed: ObservableObject {
    typealias Tasks = ControlRoomTasks

    @Published private(set) var answer: Tasks.Answer?
    /// The task the arrow keys are on, and the one whose detail is open:
    /// **two things** (group seq 290: with one flag for "the selected one is
    /// open", ↓ carried the opening to the next task and Return then shut
    /// it, while the screen still showed the first one open).
    @Published var selected: UInt64?
    @Published var openTask: UInt64?
    @Published var closed = false
    /// What is typed in the filter box: "" while it is open and empty, nil
    /// with no box (#2083). **The core filters**: it goes in the request.
    @Published private(set) var filter: String?
    /// Which way the arrow keys last went, for keeping a line's room past
    /// the selected one in sight (#2083); nil after a press or Return.
    private(set) var movedDown: Bool?
    /// Counts the times the selected task is to be brought back into sight
    /// though it did not change: the filter cleared, the list back whole
    /// (round 6, F5: it was left at the top, the selected one off screen).
    @Published private(set) var reveal = 0

    private var group: String?
    private var said: String?
    /// What the last answer lacked, as last said.
    private var saidMissing: [String] = []
    let source: ControlRoomPageSource

    init(source: ControlRoomPageSource) {
        self.source = source
    }

    func show(group: String) {
        if self.group != group {
            self.group = group
            answer = nil
            selected = nil
            openTask = nil
            closed = false
            filter = nil
        }
        fetch()
    }

    /// f: the box opens, empty, and the page is asked with it.
    func openFilter() {
        if filter == nil { filter = "" }
        fetch()
    }

    /// The box's words changed: asked again with them.
    func setFilter(_ text: String) {
        // **Not once the box is shut** (round 6, F5: Esc took two presses):
        // the field, going away, writes its words back -- "" -- and that
        // opened the box again.
        guard filter != nil, filter != text else { return }
        filter = text
        fetch()
        // The list the words leave is shorter: the selected one is brought
        // back into sight with it (round 7b, b2').
        reveal += 1
    }

    /// Esc: the box goes, and what it found with it.
    func clearFilter() {
        guard filter != nil else { return }
        filter = nil
        Ghostty.logger.notice("control room: task page: filter cleared")
        fetch()
        reveal += 1
    }

    /// A press on a task: selected and opened, or shut when pressed again.
    func press(_ id: UInt64) {
        movedDown = nil
        (selected, openTask) = Tasks.afterPress(id, open: openTask)
        Ghostty.logger.notice("control room: task page: task #\(id) \(self.openTask == id ? "opened" : "shut", privacy: .public)")
        fetch()
    }

    func toggleClosed() {
        closed.toggle()
        Ghostty.logger.notice("control room: task page: closed tasks \(self.closed ? "listed" : "folded", privacy: .public)")
        fetch()
    }

    func step(down: Bool) {
        guard let a = answer else { return }
        movedDown = down
        selected = Tasks.step(a, from: selected, down: down)
        fetch()
    }

    /// Return: on the selected task -- the first when none is -- opened
    /// (any other shut) when it is not, shut when it is
    /// (`ControlRoomTasks.afterReturn`). The line says what was done to
    /// which.
    func toggleOpen() {
        guard let a = answer else { return }
        movedDown = nil
        (selected, openTask) = Tasks.afterReturn(selected: selected, open: openTask, first: Tasks.step(a, from: nil, down: true))
        if let s = selected {
            Ghostty.logger.notice("control room: task page: Return: task #\(s) \(self.openTask == s ? "opened" : "shut", privacy: .public)")
        }
        fetch()
    }

    func fetch() {
        guard let group else { return }
        let request = Tasks.request(group: group, openTask: openTask, closed: closed, filter: filter, selected: selected)
        let result = source.ask(request).flatMap { text -> Result<Tasks.Answer, ControlRoomPageSource.Failure> in
            do { return .success(try Tasks.decode(Data(text.utf8))) } catch { return .failure(.unreadable("\(error)")) }
        }
        switch result {
        case let .success(a) where a.group == group:
            let was = selected
            // A task the core no longer has is neither selected nor open;
            // while filtering, the first it found is (#2083).
            if let s = selected, !a.inOrder.contains(where: { $0.id == s }) { selected = nil }
            if filter != nil && selected == nil { selected = a.inOrder.first?.id }
            // **And the list goes to it** (round 7b, b2'): the list follows
            // the selected one, always -- next turn, by the item's own id,
            // as after Esc (`reveal`).
            if filter != nil && selected != was { reveal += 1 }
            if let o = openTask, !a.inOrder.contains(where: { $0.id == o }) { openTask = nil }
            // **Only when it differs** (#2082): every snapshot asks again,
            // and a page told its answer changed works every line out anew.
            if answer != a { answer = a }
            said = nil
            // What the core left out, said when it changes (group seq 309).
            if a.missing != saidMissing {
                if !a.missing.isEmpty {
                    Ghostty.logger.notice("control room: task page of \(group, privacy: .public): the answer is missing \(ControlRoomAnswerReader.words(a.missing), privacy: .public); those are not drawn")
                }
                saidMissing = a.missing
            }
        case .success:
            break
        case let .failure(why):
            let words = "\(why)"
            if said != words {
                said = words
                Ghostty.logger.notice("control room: task page of \(group, privacy: .public): no answer (\(words, privacy: .public))")
            }
        }
    }
}

/// The task page (the design's v9 `main-tasks`, without its Stats and Files
/// tabs): the goal, the columns' heading, the open tasks -- the open one on
/// a pane of glass with its wording, its history and what the group said
/// of it -- the closed ones folded under a line, and the keys at the
/// bottom. Every word is the core's; every length is `task_page`'s.
struct ControlRoomTasksPage: View {
    typealias Look = ControlRoomLook
    typealias Tasks = ControlRoomTasks
    typealias Metrics = Look.TaskPage

    var group: String
    /// **Not observed** (#2082): the body draws nothing of the model's,
    /// and observed, every change the model publishes -- a snapshot, the
    /// lent terminal, a row's line -- worked the whole page out again,
    /// all of it, in the middle of a scroll. The page has what it wants of
    /// the model by `onReceive` and the page source.
    let model: ControlRoomModel
    @StateObject private var feed: ControlRoomTasksFeed
    @FocusState private var hasKeyboard: Bool
    @FocusState private var filterHasKeyboard: Bool

    @Environment(\.colorScheme) private var scheme

    /// `feed` is for a test that drives the page as the keys would (the
    /// render test of #2083); the app leaves it out.
    init(group: String, model: ControlRoomModel, feed: ControlRoomTasksFeed? = nil) {
        self.group = group
        self.model = model
        _feed = StateObject(wrappedValue: feed ?? ControlRoomTasksFeed(source: model.pageSource))
    }

    /// What `scrollTo` finds a task's line by: **its `ForEach` identity,
    /// the task's id itself** -- which a lazy list finds before the item is
    /// made. Not a `.id` of our own (v4 hung one on each branch of an
    /// open-or-not item; the two branches then shared an identity, and
    /// opening a task drew nothing new: r6c).
    static func rowID(_ id: UInt64) -> UInt64 { id }
    /// The heading's and the closed tasks' line's.
    static let headID = "task-head"
    static let closedLineID = "task-closed-line"

    var body: some View {
        let theme = Look.theme(scheme)
        GeometryReader { proxy in
            let width = max(proxy.size.width - 2 * CGFloat(Metrics.padX), 0)
            // The goal and the filter box stay at the top; the heading, the
            // tasks and the closed ones' line scroll; **the keys have a
            // strip of their own under the list** (#2083, plan A: they lay
            // over the tasks), so no task is ever under them.
            VStack(alignment: .leading, spacing: 0) {
                if let a = feed.answer {
                    goal(a, width: width, theme: theme)
                        .padding(.horizontal, CGFloat(Metrics.padX))
                    if feed.filter != nil {
                        filterBox(a.filter, width: width, theme: theme)
                            .padding(.horizontal, CGFloat(Metrics.padX))
                    }
                }
                ScrollViewReader { scroller in
                    ControlRoomScrollFades(ground: theme.terminalBackground.color, fade: CGFloat(Metrics.edgeFade)) {
                        if let a = feed.answer {
                            list(a, width: width, theme: theme)
                                .padding(.horizontal, CGFloat(Metrics.padX))
                        }
                    }
                    // **A line's room past the selected task stays in
                    // sight** (#2083): the one beyond it the way the keys
                    // went is brought in, by as little as it takes; at the
                    // ends, the heading or the closed tasks' line.
                    .onChange(of: feed.selected) { id in
                        guard let id, let a = feed.answer else { return }
                        guard let down = feed.movedDown else { return scroller.scrollTo(Self.rowID(id)) }
                        let beyond = Tasks.step(a, from: id, down: down)
                        if let beyond, beyond != id {
                            scroller.scrollTo(Self.rowID(beyond))
                        } else {
                            if !down {
                                scroller.scrollTo(Self.headID)
                            } else if a.closed_title == nil {
                                scroller.scrollTo(Self.rowID(id))
                            } else {
                                scroller.scrollTo(Self.closedLineID)
                            }
                        }
                    }
                    // In the middle: a line's room or more either side.
                    //
                    // **Next turn, by the list item's own identity** (r6b:
                    // with the selected one open, the list stayed at its
                    // top). The id was on the task's line inside the open
                    // one's glass, which a lazy list cannot find while that
                    // item is not made; and asked in the same turn as the
                    // new answer, the list had not taken it in yet. Now the
                    // `ForEach` identity is what is asked for (`rowID`). An
                    // open one goes to the top -- its line, with its detail
                    // under it, which may be taller than the page -- any
                    // other to the middle.
                    .onChange(of: feed.reveal) { _ in
                        guard let id = feed.selected else { return }
                        let open = feed.answer?.open.contains { $0.id == id && $0.detail != nil } ?? false
                        // **Then once more, a moment later** (r6d: Esc with
                        // the selected one open left the top ~170pt blank
                        // until a scroll, and then its line was above the
                        // top). A lazy list guesses the height of the lines
                        // it has not made, and the first jump lands by that
                        // guess; once the lines round it are made, the line
                        // is asked for again -- as the scroll that mended
                        // it did by hand.
                        let anchor: UnitPoint = open ? .top : .center
                        DispatchQueue.main.async { scroller.scrollTo(Self.rowID(id), anchor: anchor) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { scroller.scrollTo(Self.rowID(id), anchor: anchor) }
                    }
                }
                if let a = feed.answer {
                    bar(a, theme: theme)
                        .frame(width: proxy.size.width, height: CGFloat(Metrics.barHeight))
                }
            }
        }
        .clipped()
        .background(theme.terminalBackground.color)
        .font(.system(size: CGFloat(Look.Font.body)))
        // The keys are the page's once the person has pressed on it.
        .taskPageFocus()
        .focused($hasKeyboard)
        .onMoveCommand { direction in
            switch direction {
            case .up: feed.step(down: false)
            case .down: feed.step(down: true)
            default: break
            }
        }
        // Return is not taken here: the window's content view takes it
        // first, while the page has the keyboard (`returnIsThePages`).
        .onChange(of: hasKeyboard) { has in
            model.taskPageReturn = has ? { [feed] in feed.toggleOpen() } : nil
        }
        .onDisappear { model.taskPageReturn = nil }
        .backport.onKeyPress("c") { _ in
            guard hasKeyboard else { return .ignored }
            feed.toggleClosed()
            return .handled
        }
        .backport.onKeyPress("f") { _ in
            guard hasKeyboard else { return .ignored }
            feed.openFilter()
            filterHasKeyboard = true
            return .handled
        }
        .onExitCommand { closeFilter() }
        .onAppear { feed.show(group: group) }
        .onChange(of: group) { feed.show(group: $0) }
        // A task may have moved: asked again (API.md §2.2).
        .onReceive(model.$list.dropFirst()) { _ in feed.fetch() }
    }

    /// Esc: the filter box goes, and the keys come back to the page.
    private func closeFilter() {
        guard feed.filter != nil else { return }
        feed.clearFilter()
        hasKeyboard = true
    }

    /// The goal a line at a time, two rows at most (#2060); a second row
    /// makes it a line taller, as on Windows.
    private func goal(_ a: Tasks.Answer, width: CGFloat, theme: Look.Theme) -> some View {
        let face = SafeFace(size: CGFloat(Look.Font.body))
        let goalShown = Tasks.goalRows(a.goal_lines, width: width) { SafeTextMeasure.width($0, in: face) }
        let pad = CGFloat(Metrics.goalHeight - Metrics.bodyLineHeight) / 2
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(goalShown.enumerated()), id: \.offset) { _, row in
                Text(row)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .frame(width: width, height: CGFloat(Metrics.bodyLineHeight), alignment: .leading)
            }
        }
        .padding(.vertical, pad)
        .frame(width: width, height: CGFloat(Metrics.goalHeight) + CGFloat(max(goalShown.count - 1, 0)) * CGFloat(Metrics.bodyLineHeight),
               alignment: .topLeading)
    }

    /// The filter box under the goal (#2083), the keys in it: what it says
    /// while empty, what was typed, how many it found, and the key that
    /// clears it -- every word the core's (`filter`), asked again at each
    /// change. Drawn as the group list's name field is.
    private func filterBox(_ f: Tasks.Filter?, width: CGFloat, theme: Look.Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row), style: .continuous)
        let typed = Binding(get: { feed.filter ?? "" }, set: { feed.setFilter($0) })
        return HStack(spacing: CGFloat(Metrics.filterGap)) {
            HStack(spacing: CGFloat(Metrics.filterGap)) {
                TextField(f?.prompt ?? "", text: typed)
                    .textFieldStyle(.plain)
                    .focused($filterHasKeyboard)
                    .onSubmit { feed.toggleOpen() }
                    .onExitCommand { closeFilter() }
                    // The arrow keys still go through what it found.
                    .backport.onKeyPress(.upArrow) { _ in feed.step(down: false); return .handled }
                    .backport.onKeyPress(.downArrow) { _ in feed.step(down: true); return .handled }
                if let count = f?.count {
                    Text(count).foregroundStyle(theme.textSecondary.color).monospacedDigit().fixedSize()
                }
            }
            .padding(.horizontal, CGFloat(Metrics.filterPadX))
            .frame(height: CGFloat(Metrics.rowHeight))
            .background(shape.strokeBorder(theme.attentionText.color, lineWidth: CGFloat(Look.Line.hairline)))
            if let clear = f?.clear {
                keyed(clear, words: theme.textSecondary, theme: theme)
                    .contentShape(Rectangle())
                    .onTapGesture { closeFilter() }
            }
        }
        .frame(width: width)
        .padding(.top, CGFloat(Metrics.filterTop))
        .padding(.bottom, CGFloat(Metrics.filterBottom))
    }

    private func list(_ a: Tasks.Answer, width: CGFloat, theme: Look.Theme) -> some View {
        let cols = Tasks.columns(width: width)
        let lines = a.inOrder
        let keys = hasKeyboard || filterHasKeyboard
        // A hairline over a line, but not round the glass, the selected
        // task's chip or the first closed one (the design's `.trow::before`).
        func ruled(_ i: Int, closed: Bool) -> Bool {
            let at = closed ? a.open.count + i : i
            guard i > 0, lines[at - 1].detail == nil, lines[at].detail == nil else { return false }
            return feed.selected != lines[at].id && feed.selected != lines[at - 1].id
        }
        // **Lazy** (#2082): a line is made when it comes into sight, so a
        // scroll step, or a new answer, costs the lines on the screen and
        // not every line of a list hundreds long.
        return LazyVStack(alignment: .leading, spacing: 0) {
            // From the left, as each line is: the cells are placed by
            // offset, which does not size the stack, and centred it was
            // as far right as the line was wider than its widest cell
            // (0x373c, group seq 261: 214.5 points).
            head(a.head, cols: cols, theme: theme)
                .frame(width: width, height: CGFloat(Metrics.rowHeight), alignment: .topLeading)
                .overlay(alignment: .bottom) { rule(theme) }
                .id(Self.headID)
            if let m = a.no_match {
                VStack(alignment: .leading, spacing: CGFloat(Metrics.noMatchGap)) {
                    Text(m.title).fontWeight(.semibold).foregroundStyle(theme.text.color)
                    Text(m.detail).foregroundStyle(theme.textSecondary.color)
                }
                .padding(.top, CGFloat(Metrics.noMatchTop))
                .padding(.horizontal, CGFloat(Metrics.rowPadX))
                .frame(width: width, alignment: .leading)
            }
            ForEach(Array(a.open.enumerated()), id: \.element.id) { i, task in
                if let detail = task.detail {
                    VStack(alignment: .leading, spacing: 0) {
                        line(task, cols: cols, width: width, closed: false, keys: keys, theme: theme)
                        ControlRoomTaskDetail(detail: detail, width: width, theme: theme)
                    }
                    .background(RoundedRectangle(cornerRadius: CGFloat(Metrics.detailRadiusMac), style: .continuous)
                        .fill(theme.perfCard.color))
                    .overlay(RoundedRectangle(cornerRadius: CGFloat(Metrics.detailRadiusMac), style: .continuous)
                        .strokeBorder(theme.perfCardEdge.color, lineWidth: CGFloat(Look.Line.hairline)))
                    .padding(.vertical, CGFloat(Metrics.detailMarginY))
                } else {
                    line(task, cols: cols, width: width, closed: false, keys: keys, theme: theme)
                        .overlay(alignment: .top) { if ruled(i, closed: false) { rule(theme) } }
                }
            }
            if let title = a.closed_title {
                ControlRoomTaskClosedLine(title: title, key: a.closed_key, width: width, theme: theme) {
                    hasKeyboard = true
                    feed.toggleClosed()
                }
                .padding(.top, CGFloat(Metrics.closedTop))
                .id(Self.closedLineID)
            }
            ForEach(Array(a.closed.enumerated()), id: \.element.id) { i, task in
                line(task, cols: cols, width: width, closed: true, keys: keys, theme: theme)
                    .overlay(alignment: .top) { if ruled(i, closed: true) { rule(theme) } }
            }
        }
    }

    private func rule(_ theme: Look.Theme) -> some View {
        theme.stackTabSeparator.color.frame(height: CGFloat(Look.Line.hairline))
    }

    private func head(_ h: Tasks.Head, cols: [(x: CGFloat, width: CGFloat)], theme: Look.Theme) -> some View {
        ZStack(alignment: .topLeading) {
            cell(h.id, cols[1], .leading)
            cell(h.state, cols[2], .leading)
            cell(h.title, cols[3], .leading)
            cell(h.owner, cols[4], .leading)
            // None when the page is too narrow for it (`columns`).
            if cols[5].width > 0 { cell(h.idle, cols[5], .trailing) }
        }
        .foregroundStyle(theme.textSecondary.color)
    }

    private func cell(_ text: String, _ col: (x: CGFloat, width: CGFloat), _ align: Alignment) -> some View {
        cell(Text(text), col, align)
    }

    private func cell(_ text: Text, _ col: (x: CGFloat, width: CGFloat), _ align: Alignment) -> some View {
        text
            .lineLimit(1).truncationMode(.tail)
            .frame(width: col.width, height: CGFloat(Metrics.rowHeight), alignment: align)
            .offset(x: col.x)
    }

    /// A task's title: as it is, or -- filtering -- in the core's pieces,
    /// those it found bold on a ground of their own (#2083).
    private func title(_ task: Tasks.Task, weight: Font.Weight, theme: Look.Theme) -> Text {
        guard let parts = task.title_parts else { return Text(task.title).fontWeight(weight) }
        var out = AttributedString()
        for p in parts {
            var piece = AttributedString(p.text)
            if p.hit {
                piece.font = .system(size: CGFloat(Look.Font.body), weight: .semibold)
                piece.backgroundColor = theme.taskHit.color
            } else {
                piece.font = .system(size: CGFloat(Look.Font.body), weight: weight)
            }
            out += piece
        }
        return Text(out)
    }

    /// One task's line: bold when it is the open one, faint when closed,
    /// the chip and its bar when the arrow keys are on it.
    private func line(_ task: Tasks.Task, cols: [(x: CGFloat, width: CGFloat)], width: CGFloat, closed: Bool, keys: Bool, theme: Look.Theme) -> some View {
        let main = closed ? theme.textTertiary : theme.text
        let side = closed ? theme.textTertiary : (task.bold ? theme.text : theme.textSecondary)
        let weight: Font.Weight = task.bold ? .semibold : .regular
        return ZStack(alignment: .topLeading) {
            ControlRoomTaskGround(selected: feed.selected == task.id, keys: keys, width: width, theme: theme)
            // None when the core named no glyph this build knows.
            if let glyph = task.glyph {
                Image(systemName: Tasks.symbol(glyph))
                    .font(.system(size: CGFloat(Look.Side.glyph) - 2))
                    .foregroundStyle(Tasks.color(glyph, theme: theme).color)
                    // In the middle of its column (0x4881 found the Windows
                    // host's at the column's left, group seq 221).
                    .frame(width: cols[0].width, height: CGFloat(Metrics.rowHeight))
                    .offset(x: cols[0].x)
            }
            cell("#\(task.id)", cols[1], .leading).font(.system(size: CGFloat(Look.Font.body), weight: weight, design: .monospaced))
                .foregroundStyle(side.color)
            cell(task.state, cols[2], .leading).fontWeight(weight).foregroundStyle(main.color)
            cell(title(task, weight: weight, theme: theme), cols[3], .leading).foregroundStyle(main.color)
            cell(task.owner, cols[4], .leading).font(.system(size: CGFloat(Look.Font.body), weight: weight, design: .monospaced))
                .foregroundStyle(side.color)
            if cols[5].width > 0 {
                cell(task.idle, cols[5], .trailing).fontWeight(weight).foregroundStyle(side.color)
            }
        }
        .frame(width: width, height: CGFloat(Metrics.rowHeight), alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { hasKeyboard = true; feed.press(task.id) }
    }

    /// A key in its cap and what it does.
    private func keyed(_ h: Tasks.Hint, words: Look.RGBA, theme: Look.Theme) -> some View {
        HStack(spacing: CGFloat(Metrics.keyGap)) {
            Text(h.key)
                .font(.system(size: CGFloat(Metrics.keyFont), design: .monospaced))
                .foregroundStyle(theme.text.color)
                .padding(.horizontal, CGFloat(Metrics.keyPadX))
                .frame(height: CGFloat(Metrics.keyHeight))
                .background(RoundedRectangle(cornerRadius: CGFloat(Metrics.keyRadius)).fill(theme.perfCardEdge.color))
            Text(h.text).foregroundStyle(words.color)
        }
        .fixedSize()
    }

    /// The keys' strip (#2083, plan A): a hairline along its top, the keys
    /// at its left -- as many as fit, the first first, since one cut in
    /// half says nothing -- and at its right, always, whether the closed
    /// ones are shown and how to change it.
    private func bar(_ a: Tasks.Answer, theme: Look.Theme) -> some View {
        HStack(spacing: CGFloat(Metrics.hintsGap)) {
            ViewThatFits(in: .horizontal) {
                ForEach((0...a.hints.count).reversed(), id: \.self) { n in
                    HStack(spacing: CGFloat(Metrics.hintsGap)) {
                        ForEach(Array(a.hints.prefix(n).enumerated()), id: \.offset) { _, h in
                            keyed(h, words: theme.textSecondary, theme: theme)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let h = a.hint_closed {
                keyed(h, words: theme.text, theme: theme)
                    .contentShape(Rectangle())
                    .onTapGesture { hasKeyboard = true; feed.toggleClosed() }
            }
        }
        .padding(.horizontal, CGFloat(Metrics.barPadX))
        // **Its height before its hairline** (round 6, F5): laid over the
        // keys' own height, the line stood on the keys' tops and the strip
        // read 30 points, its top 10 taken for the list's.
        .frame(height: CGFloat(Metrics.barHeight))
        .overlay(alignment: .top) { rule(theme) }
        .clipped()
    }
}

/// What the open task shows under its line: on the left its wording and
/// its history, on the right what the group said of it.
struct ControlRoomTaskDetail: View {
    typealias Look = ControlRoomLook
    typealias Tasks = ControlRoomTasks
    typealias Metrics = Look.TaskPage

    var detail: Tasks.Detail
    var width: CGFloat
    var theme: Look.Theme

    /// What lies between two lines of the wording so that a line is
    /// `task_page.body_line_height` tall: that less the body font's own.
    static let bodyLineSpacing: CGFloat = {
        let font = NSFont.systemFont(ofSize: CGFloat(Look.Font.body))
        return max(CGFloat(Metrics.bodyLineHeight) - (font.ascender - font.descender + font.leading), 0)
    }()

    var body: some View {
        let inner = max(width - CGFloat(Metrics.detailPadLeft + Metrics.detailPadRight), 0)
        let leftW = max(min(CGFloat(Metrics.detailLeftWidth), (inner - CGFloat(Metrics.detailColumnGap)) / 2), 0)
        HStack(alignment: .top, spacing: CGFloat(Metrics.detailColumnGap)) {
            VStack(alignment: .leading, spacing: 0) {
                heading(detail.body_title)
                Text(detail.body).foregroundStyle(theme.text.color).lineSpacing(Self.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, CGFloat(Metrics.bodyBottom))
                heading(detail.log_title)
                ForEach(Array(detail.log.enumerated()), id: \.offset) { i, l in
                    log(l, first: i == 0, last: i == detail.log.count - 1)
                }
            }
            .frame(width: leftW, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                heading(detail.said_title)
                ForEach(Array(detail.said.enumerated()), id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: CGFloat(Metrics.saidHeadGap)) {
                            Text(s.at).font(.system(size: CGFloat(Look.Font.body), design: .monospaced)).foregroundStyle(theme.textSecondary.color)
                            Text(s.who).font(.system(size: CGFloat(Look.Font.body), weight: .semibold, design: .monospaced)).foregroundStyle(theme.text.color)
                        }
                        Text(s.text).foregroundStyle(theme.text.color).lineSpacing(Self.bodyLineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, CGFloat(Metrics.saidBottom))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, CGFloat(Metrics.detailPadTop))
        .padding(.leading, CGFloat(Metrics.detailPadLeft))
        .padding(.trailing, CGFloat(Metrics.detailPadRight))
        .padding(.bottom, CGFloat(Metrics.detailPadBottom))
    }

    private func heading(_ text: String) -> some View {
        HStack(spacing: CGFloat(Metrics.headingRuleGap)) {
            Text(text).foregroundStyle(theme.textSecondary.color).fixedSize()
            theme.stackTabSeparator.color.frame(height: CGFloat(Look.Line.hairline))
        }
        .frame(height: CGFloat(Metrics.headingHeight))
    }

    /// One line of the history. The track runs through every line from the
    /// first dot to the last; across a gap it is dashed.
    @ViewBuilder
    private func log(_ l: Tasks.LogLine, first: Bool, last: Bool) -> some View {
        switch l {
        case let .event(at, who, text, isLast):
            HStack(spacing: 0) {
                Text(at ?? "").font(.system(size: CGFloat(Look.Font.body), design: .monospaced)).foregroundStyle(theme.textSecondary.color)
                    .frame(width: CGFloat(Metrics.logTime), alignment: .leading)
                track(height: CGFloat(Metrics.logRow), from: first ? CGFloat(Metrics.logRow) / 2 : 0, to: last ? CGFloat(Metrics.logRow) / 2 : CGFloat(Metrics.logRow),
                      dot: isLast ? .filled : .ring, dashed: false)
                Text(who ?? "").font(.system(size: CGFloat(Look.Font.body), design: .monospaced)).foregroundStyle(theme.textSecondary.color)
                    .frame(width: CGFloat(Metrics.logWho), alignment: .leading)
                Text(text).foregroundStyle(theme.text.color).lineLimit(1).truncationMode(.tail)
            }
            .frame(height: CGFloat(Metrics.logRow))
        case let .gap(text):
            HStack(spacing: 0) {
                Color.clear.frame(width: CGFloat(Metrics.logTime))
                track(height: CGFloat(Metrics.logGapRow), from: 0, to: CGFloat(Metrics.logGapRow), dot: nil, dashed: true)
                Text(text).foregroundStyle(theme.textSecondary.color).lineLimit(1)
            }
            .frame(height: CGFloat(Metrics.logGapRow))
        }
    }

    private enum Dot { case ring, filled }

    private func track(height: CGFloat, from: CGFloat, to: CGFloat, dot: Dot?, dashed: Bool) -> some View {
        let x = CGFloat(Metrics.logTrackX)
        return ZStack(alignment: .topLeading) {
            Path { p in p.move(to: CGPoint(x: x, y: from)); p.addLine(to: CGPoint(x: x, y: to)) }
                .stroke(theme.textTertiary.color, style: StrokeStyle(lineWidth: CGFloat(Look.Line.hairline), dash: dashed ? [CGFloat(Metrics.gapDash), CGFloat(Metrics.gapDashGap)] : []))
            if let dot {
                let d = CGFloat(Metrics.logDot)
                Circle()
                    .fill(dot == .filled ? theme.text.color : theme.terminalBackground.color)
                    .overlay(Circle().strokeBorder(dot == .filled ? .clear : theme.textSecondary.color, lineWidth: 1))
                    .frame(width: d, height: d)
                    .offset(x: x - d / 2, y: CGFloat(Metrics.logDotTop))
            }
        }
        .frame(width: CGFloat(Metrics.logTrack), height: height, alignment: .topLeading)
    }
}

private extension View {
    /// Takes the keyboard without the system's ring round the whole page,
    /// as the list does (`controlRoomListFocus`, private to its file).
    @ViewBuilder
    func taskPageFocus() -> some View {
        if #available(macOS 14.0, *) {
            focusable().focusEffectDisabled()
        } else {
            focusable()
        }
    }
}

/// Under a task's line (#2083, plan S2): for the arrow keys' task, the
/// group list's chip and a bar at its left in the main text colour -- the
/// chip alone is all but white on white (1.01 to the page, the design's
/// reading), the bar is what is seen -- lifted while the pointer is on it;
/// with the keyboard elsewhere, an outline and the bar. Under the pointer
/// otherwise, a flat faint ground, the window tabs' hover. **Never a grey
/// ground for the selection.** Its own state, so that the pointer moving
/// over the list redraws one line, not the page.
struct ControlRoomTaskGround: View {
    typealias Look = ControlRoomLook
    typealias Metrics = Look.TaskPage

    var selected: Bool
    /// Whether the page, or its filter box, has the keyboard.
    var keys: Bool
    var width: CGFloat
    var theme: Look.Theme
    @State private var over = false

    var body: some View {
        let height = CGFloat(Metrics.rowHeight)
        let shape = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row), style: .continuous)
        ZStack(alignment: .topLeading) {
            if selected && keys {
                ControlRoomTaskChip(theme: theme, lifted: over)
            } else if selected {
                shape.strokeBorder(theme.line.color, lineWidth: 1)
            } else {
                shape.fill(over ? theme.windowTabHover.color : Color.clear)
            }
            if selected {
                RoundedRectangle(cornerRadius: CGFloat(Metrics.markRadius))
                    .fill(theme.text.color)
                    .frame(width: CGFloat(Metrics.markWidth), height: height - 2 * CGFloat(Metrics.markInsetY))
                    .offset(x: CGFloat(Metrics.markX), y: CGFloat(Metrics.markInsetY))
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onHover { over = $0 }
    }
}

/// The group list's selection chip (`ControlRoomListView.chip`): a bright
/// piece with a fine band inside its edge, a halo and a short shadow; with
/// the pointer on it, the shadow its lifted values (`selection_*_moving`).
struct ControlRoomTaskChip: View {
    typealias Look = ControlRoomLook

    var theme: Look.Theme
    var lifted: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row), style: .continuous)
        let edge = theme.selectionEdge
        let halo = lifted ? (theme.selectionHaloMovingAlpha, theme.selectionHaloMovingBlur, 0.0)
                          : (theme.selectionHaloAlpha, theme.selectionHaloBlur, 0.0)
        let drop = lifted ? (theme.selectionShadowMovingAlpha, theme.selectionShadowMovingBlur, theme.selectionShadowMovingY)
                          : (theme.selectionShadowAlpha, theme.selectionShadowBlur, theme.selectionShadowY)
        shape
            .fill(Color.white.opacity(theme.selectionTint))
            .overlay(
                shape.strokeBorder((edge < 0 ? Color.black : Color.white).opacity(abs(edge)),
                                   lineWidth: CGFloat(Look.Selection.edgeBand))
                    .blur(radius: CGFloat(Look.Selection.edgeBand) / 2)
                    .clipShape(shape)
            )
            .background(shape.shadowOutside([halo, drop]))
    }
}

/// The closed tasks' line (#2083): its words, a rule to the key at its
/// right and what the key does -- "已隐藏 8 条已关闭或已取消的任务 ——— c 或点
/// 这一行显示". A press anywhere on it does what c does. Under the pointer,
/// the flat ground, and no rule.
struct ControlRoomTaskClosedLine: View {
    typealias Look = ControlRoomLook
    typealias Tasks = ControlRoomTasks
    typealias Metrics = Look.TaskPage

    var title: String
    var key: Tasks.Hint?
    var width: CGFloat
    var theme: Look.Theme
    var press: () -> Void
    @State private var over = false

    var body: some View {
        HStack(spacing: CGFloat(Metrics.closedRuleGap)) {
            Text(title).foregroundStyle(theme.textSecondary.color).lineLimit(1)
            (over ? Color.clear : theme.stackTabSeparator.color)
                .frame(height: CGFloat(Look.Line.hairline))
                .frame(maxWidth: .infinity)
            if let key {
                HStack(spacing: CGFloat(Metrics.keyGap)) {
                    Text(key.key)
                        .font(.system(size: CGFloat(Metrics.keyFont), design: .monospaced))
                        .foregroundStyle(theme.text.color)
                        .padding(.horizontal, CGFloat(Metrics.keyPadX))
                        .frame(height: CGFloat(Metrics.keyHeight))
                        .background(RoundedRectangle(cornerRadius: CGFloat(Metrics.keyRadius)).fill(theme.perfCardEdge.color))
                    Text(key.text).foregroundStyle(theme.textSecondary.color)
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, CGFloat(Metrics.rowPadX))
        .frame(width: width, height: CGFloat(Metrics.rowHeight))
        .background(RoundedRectangle(cornerRadius: CGFloat(Look.Radius.row), style: .continuous)
            .fill(over ? theme.windowTabHover.color : Color.clear))
        .contentShape(Rectangle())
        .onHover { over = $0 }
        .onTapGesture(perform: press)
    }
}

/// A vertical scroll view with a fade at an edge while there is more of
/// its content that way (#2083). **Its own state, set only when an edge
/// changes**: the content's place is read on every scroll step, and a page
/// redrawn on every step is what #2082 took away.
struct ControlRoomScrollFades<Content: View>: View {
    var ground: Color
    var fade: CGFloat
    @ViewBuilder var content: Content
    @State private var above = false
    @State private var below = false

    var body: some View {
        GeometryReader { outer in
            ScrollView(.vertical) {
                content.background(GeometryReader { g in
                    Color.clear.preference(key: ControlRoomScrollPlace.self, value: g.frame(in: .named("ControlRoomScrollFades")))
                })
            }
            .coordinateSpace(name: "ControlRoomScrollFades")
            .onPreferenceChange(ControlRoomScrollPlace.self) { at in
                let a = at.minY < -0.5, b = at.maxY > outer.size.height + 0.5
                if a != above { above = a }
                if b != below { below = b }
            }
            .overlay(alignment: .top) {
                if above { edge(from: .top) }
            }
            .overlay(alignment: .bottom) {
                if below { edge(from: .bottom) }
            }
        }
    }

    private func edge(from: UnitPoint) -> some View {
        LinearGradient(colors: [ground, ground.opacity(0)], startPoint: from, endPoint: from == .top ? .bottom : .top)
            .frame(height: fade)
            .allowsHitTesting(false)
    }
}

/// Where `ControlRoomScrollFades`'s content is, in its scroll view.
private struct ControlRoomScrollPlace: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
