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
        }
        fetch()
    }

    /// A press on a task: selected and opened, or shut when pressed again.
    func press(_ id: UInt64) {
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
        selected = Tasks.step(a, from: selected, down: down)
        fetch()
    }

    /// Return: on the selected task -- the first when none is -- opened
    /// (any other shut) when it is not, shut when it is
    /// (`ControlRoomTasks.afterReturn`). The line says what was done to
    /// which.
    func toggleOpen() {
        guard let a = answer else { return }
        (selected, openTask) = Tasks.afterReturn(selected: selected, open: openTask, first: Tasks.step(a, from: nil, down: true))
        if let s = selected {
            Ghostty.logger.notice("control room: task page: Return: task #\(s) \(self.openTask == s ? "opened" : "shut", privacy: .public)")
        }
        fetch()
    }

    func fetch() {
        guard let group else { return }
        let request = Tasks.request(group: group, openTask: openTask, closed: closed)
        let result = source.ask(request).flatMap { text -> Result<Tasks.Answer, ControlRoomPageSource.Failure> in
            do { return .success(try Tasks.decode(Data(text.utf8))) } catch { return .failure(.unreadable("\(error)")) }
        }
        switch result {
        case let .success(a) where a.group == group:
            // A task the core no longer has is neither selected nor open.
            if let s = selected, !a.inOrder.contains(where: { $0.id == s }) { selected = nil }
            if let o = openTask, !a.inOrder.contains(where: { $0.id == o }) { openTask = nil }
            answer = a
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
    @ObservedObject var model: ControlRoomModel
    @StateObject private var feed: ControlRoomTasksFeed
    @FocusState private var hasKeyboard: Bool

    @Environment(\.colorScheme) private var scheme

    init(group: String, model: ControlRoomModel) {
        self.group = group
        self.model = model
        _feed = StateObject(wrappedValue: ControlRoomTasksFeed(source: model.pageSource))
    }

    var body: some View {
        let theme = Look.theme(scheme)
        GeometryReader { proxy in
            ScrollView(.vertical) {
                if let a = feed.answer {
                    list(a, width: max(proxy.size.width - 2 * CGFloat(Metrics.padX), 0), theme: theme)
                        .padding(.horizontal, CGFloat(Metrics.padX))
                        // Room under the last line for the keys.
                        .padding(.bottom, CGFloat(Metrics.hintsHeight + 2 * Metrics.hintsBottom))
                }
            }
        }
        // **An overlay, not a sibling** (0x373c, group seq 261): beside the
        // rows its keys -- each as wide as its words -- made the page as
        // wide as they are, and in a narrow window the page pushed the right
        // side wider and the list narrower. Over the page it takes no room.
        .overlay(alignment: .bottomLeading) {
            if let a = feed.answer, !a.hints.isEmpty {
                hints(a.hints, theme: theme)
                    .padding(.leading, CGFloat(Metrics.hintsLeft))
                    .padding(.bottom, CGFloat(Metrics.hintsBottom))
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
        .onAppear { feed.show(group: group) }
        .onChange(of: group) { feed.show(group: $0) }
        // A task may have moved: asked again (API.md §2.2).
        .onReceive(model.$list.dropFirst()) { _ in feed.fetch() }
    }

    private func list(_ a: Tasks.Answer, width: CGFloat, theme: Look.Theme) -> some View {
        let cols = Tasks.columns(width: width)
        return VStack(alignment: .leading, spacing: 0) {
            Text(a.goal)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: width, height: CGFloat(Metrics.goalHeight), alignment: .leading)
            // From the left, as each line is: the cells are placed by
            // offset, which does not size the stack, and centred it was
            // as far right as the line was wider than its widest cell
            // (0x373c, group seq 261: 214.5 points).
            head(a.head, cols: cols, theme: theme)
                .frame(width: width, height: CGFloat(Metrics.rowHeight), alignment: .topLeading)
                .overlay(alignment: .bottom) { rule(theme) }
            ForEach(Array(a.open.enumerated()), id: \.element.id) { i, task in
                if let detail = task.detail {
                    VStack(alignment: .leading, spacing: 0) {
                        line(task, cols: cols, width: width, closed: false, theme: theme)
                        ControlRoomTaskDetail(detail: detail, width: width, theme: theme)
                    }
                    .background(RoundedRectangle(cornerRadius: CGFloat(Metrics.detailRadiusMac), style: .continuous)
                        .fill(theme.perfCard.color))
                    .overlay(RoundedRectangle(cornerRadius: CGFloat(Metrics.detailRadiusMac), style: .continuous)
                        .strokeBorder(theme.perfCardEdge.color, lineWidth: CGFloat(Look.Line.hairline)))
                    .padding(.vertical, CGFloat(Metrics.detailMarginY))
                } else {
                    let afterGlass = i > 0 && a.open[i - 1].detail != nil
                    line(task, cols: cols, width: width, closed: false, theme: theme)
                        .overlay(alignment: .top) { if i > 0 && !afterGlass { rule(theme) } }
                }
            }
            HStack(spacing: CGFloat(Metrics.closedRuleGap)) {
                Text(a.closed_title).foregroundStyle(theme.textSecondary.color).fixedSize()
                rule(theme)
            }
            .padding(.leading, CGFloat(Metrics.rowPadX))
            .frame(width: width, height: CGFloat(Metrics.rowHeight))
            .contentShape(Rectangle())
            .onTapGesture { hasKeyboard = true; feed.toggleClosed() }
            .padding(.top, CGFloat(Metrics.closedTop))
            ForEach(Array(a.closed.enumerated()), id: \.element.id) { i, task in
                line(task, cols: cols, width: width, closed: true, theme: theme)
                    .overlay(alignment: .top) { if i > 0 { rule(theme) } }
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
            cell(h.idle, cols[5], .trailing)
        }
        .foregroundStyle(theme.textSecondary.color)
    }

    private func cell(_ text: String, _ col: (x: CGFloat, width: CGFloat), _ align: Alignment) -> some View {
        Text(text)
            .lineLimit(1).truncationMode(.tail)
            .frame(width: col.width, height: CGFloat(Metrics.rowHeight), alignment: align)
            .offset(x: col.x)
    }

    /// One task's line: bold when it is the open one, faint when closed,
    /// lit when the arrow keys are on it and it is not open.
    private func line(_ task: Tasks.Task, cols: [(x: CGFloat, width: CGFloat)], width: CGFloat, closed: Bool, theme: Look.Theme) -> some View {
        let main = closed ? theme.textTertiary : theme.text
        let side = closed ? theme.textTertiary : (task.bold ? theme.text : theme.textSecondary)
        let weight: Font.Weight = task.bold ? .semibold : .regular
        let lit = feed.selected == task.id && task.detail == nil
        return ZStack(alignment: .topLeading) {
            if lit {
                RoundedRectangle(cornerRadius: CGFloat(Metrics.detailRadiusMac), style: .continuous)
                    .fill(theme.perfCard.color)
                    .frame(width: width, height: CGFloat(Metrics.rowHeight))
            }
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
            cell(task.title, cols[3], .leading).fontWeight(weight).foregroundStyle(main.color)
            cell(task.owner, cols[4], .leading).font(.system(size: CGFloat(Look.Font.body), weight: weight, design: .monospaced))
                .foregroundStyle(side.color)
            cell(task.idle, cols[5], .trailing).fontWeight(weight).foregroundStyle(side.color)
        }
        .frame(width: width, height: CGFloat(Metrics.rowHeight), alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { hasKeyboard = true; feed.press(task.id) }
    }

    /// The keys at the bottom: as many of them as fit, the first first --
    /// one cut in half says nothing.
    private func hints(_ hints: [Tasks.Hint], theme: Look.Theme) -> some View {
        ViewThatFits(in: .horizontal) {
            ForEach((1...hints.count).reversed(), id: \.self) { n in
                hintBar(Array(hints.prefix(n)), theme: theme)
            }
        }
    }

    private func hintBar(_ hints: [Tasks.Hint], theme: Look.Theme) -> some View {
        HStack(spacing: CGFloat(Metrics.hintsGap)) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, h in
                HStack(spacing: CGFloat(Metrics.keyGap)) {
                    Text(h.key)
                        .font(.system(size: CGFloat(Metrics.keyFont), design: .monospaced))
                        .foregroundStyle(theme.text.color)
                        .padding(.horizontal, CGFloat(Metrics.keyPadX))
                        .frame(height: CGFloat(Metrics.keyHeight))
                        .background(RoundedRectangle(cornerRadius: CGFloat(Metrics.keyRadius)).fill(theme.perfCardEdge.color))
                    Text(h.text).foregroundStyle(theme.textSecondary.color)
                }
                .fixedSize()
            }
        }
        .padding(.leading, CGFloat(Metrics.hintsPadLeft))
        .padding(.trailing, CGFloat(Metrics.hintsPadRight))
        .frame(height: CGFloat(Metrics.hintsHeight))
        .background(RoundedRectangle(cornerRadius: CGFloat(Metrics.hintsRadius), style: .continuous).fill(theme.perfTip.color))
        .overlay(RoundedRectangle(cornerRadius: CGFloat(Metrics.hintsRadius), style: .continuous)
            .strokeBorder(theme.perfTipEdge.color, lineWidth: CGFloat(Look.Line.hairline)))
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
