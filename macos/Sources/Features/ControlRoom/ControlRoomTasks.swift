import Foundation
import CoreGraphics

/// The task page's data (task 2015, Q9; `polter-artifacts/2015/API.md`
/// §2.2): the core's answer to a `tasks` request, read; where the arrow
/// keys go; and where the columns of a task's line stand -- the Windows
/// host's `tasks_scene::columns`, from the same `task_page` keys.
///
/// **Every word is the core's**, and so is the order of the tasks. A glyph
/// or a kind of history line this build does not know is left out and said
/// (`ControlRoomAnswerReader`).
enum ControlRoomTasks {
    enum Glyph: String, Decodable, Equatable, CaseIterable {
        case queued, working, blocked, done, closed, cancelled
    }

    struct Head: Decodable, Equatable {
        var id: String
        var state: String
        var title: String
        var owner: String
        var idle: String
    }

    /// One line of a task's history: an event, or "隔了 18 分钟" between
    /// two events more than ten minutes apart.
    enum LogLine: Decodable, Equatable {
        /// `at` and `who` nil on a line that has none -- the one that says
        /// what came before was merged has no who (API.md §2.0).
        case event(at: String?, who: String?, text: String, last: Bool)
        case gap(text: String)

        private enum Keys: String, CodingKey { case entry, at, who, text, last }
        private enum Entry: String, Decodable { case event, gap }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decode(Entry.self, forKey: .entry) {
            case .event:
                self = .event(at: try c.decodeIfPresent(String.self, forKey: .at), who: try c.decodeIfPresent(String.self, forKey: .who),
                              text: try c.decode(String.self, forKey: .text), last: try c.decode(Bool.self, forKey: .last))
            case .gap:
                self = .gap(text: try c.decode(String.self, forKey: .text))
            }
        }
    }

    struct Said: Decodable, Equatable {
        var at: String
        var who: String
        var text: String
    }

    struct Detail: Decodable, Equatable {
        var body_title: String
        var body: String
        var log_title: String
        var log: [LogLine]
        var said_title: String
        var said: [Said]
    }

    struct Task: Decodable, Equatable, Identifiable {
        var id: UInt64
        /// Nil when the core named none, or one this build does not know:
        /// no symbol is drawn.
        var glyph: Glyph?
        var state: String
        var title: String
        var owner: String
        var idle: String
        /// The title cut where the filter found it (#2083): the pieces
        /// `hit` drawn bold on a ground of their own. Nil with no filter:
        /// the title is drawn as it is. **Cut by the core**, which alone
        /// knows how the filter matches; the page only draws the pieces.
        var title_parts: [TitlePart]?
        /// Its line in bold: the open one.
        var emph: Bool?
        var detail: Detail?

        var bold: Bool { emph ?? false }
    }

    struct Hint: Decodable, Equatable {
        var key: String
        var text: String
    }

    struct TitlePart: Decodable, Equatable {
        var text: String
        var hit: Bool
    }

    /// The filter box (#2083): what it says while empty, what is typed,
    /// how many it found ("4 / 9 条", nil while empty) and the key that
    /// clears it.
    struct Filter: Decodable, Equatable {
        var prompt: String
        var text: String
        var count: String?
        var clear: Hint
    }

    /// What the page says when no open task matches (#2083).
    struct NoMatch: Decodable, Equatable {
        var title: String
        var detail: String
    }

    struct Answer: Decodable, Equatable {
        var group: String
        var goal: String
        /// The goal as the person wrote it, a line each -- trimmed, the
        /// empty ones gone (`TaskPage.goalLines`, #2060). What the page
        /// draws, each line wrapped on its own (`goalRows`).
        var goal_lines: [String] = []
        var head: Head
        var open: [Task]
        /// The closed tasks' line, and the key at its right (#2083: "已隐藏
        /// 8 条已关闭或已取消的任务" · c "或点这一行显示"). Nil when there is
        /// no such line: none closed, or none the filter found.
        var closed_title: String?
        var closed_key: Hint?
        var closed_count: UInt64
        /// Empty unless asked for with `closed: true`.
        var closed: [Task]
        var hints: [Hint]
        /// The key kept at the strip's right end (#2083, plan A): whether
        /// the closed ones are shown, and how to change it. Nil when none is
        /// closed.
        var hint_closed: Hint?
        /// Nil without a filter box.
        var filter: Filter?
        /// Nil unless filtering found no open task.
        var no_match: NoMatch?
        /// What the answer should have said and did not, by path; none of
        /// it is drawn (`ControlRoomAnswerReader`). The page writes it down.
        var missing: [String] = []

        /// Every task in the order drawn: what the arrow keys go through.
        var inOrder: [Task] { open + closed }
    }

    enum DecodeError: Error, Equatable {
        case refused(String)
        case unreadable
        case noGroup
    }

    typealias Reader = ControlRoomAnswerReader

    /// The answer, read field by field (`ControlRoomAnswerReader`): only
    /// what is not JSON, `{"error": …}` and an answer that does not say
    /// whose group it is fail; everything else missing is left out of what
    /// is drawn and named in `missing`. The Windows host's `tasks::decode`.
    static func decode(_ data: Data) throws -> Answer {
        guard let v = (try? JSONSerialization.jsonObject(with: data)) as? Reader.Object else { throw DecodeError.unreadable }
        if let e = v["error"] as? String { throw DecodeError.refused(e) }
        guard let group = v["group"] as? String else { throw DecodeError.noGroup }
        let r = Reader()
        let head = r.obj(v, "", "head").map { h in
            Head(id: r.text(h, "head", "id"), state: r.text(h, "head", "state"), title: r.text(h, "head", "title"),
                 owner: r.text(h, "head", "owner"), idle: r.text(h, "head", "idle"))
        } ?? Head(id: "", state: "", title: "", owner: "", idle: "")
        func tasks(_ key: String) -> [Task] {
            r.list(v, "", key).enumerated().compactMap { i, t in readTask(r, (t as? Reader.Object) ?? [:], Reader.at(key, i)) }
        }
        let (open, closed) = (tasks("open"), tasks("closed"))
        func hint(_ h: Reader.Object, _ p: String) -> Hint {
            Hint(key: r.text(h, p, "key"), text: r.text(h, p, "text"))
        }
        let hints = r.list(v, "", "hints").enumerated().map { i, h in
            hint((h as? Reader.Object) ?? [:], Reader.at("hints", i))
        }
        let filter = r.nullableObj(v, "", "filter").map { f in
            Filter(prompt: r.text(f, "filter", "prompt"), text: r.text(f, "filter", "text"),
                   count: r.nullableText(f, "filter", "count"),
                   clear: r.obj(f, "filter", "clear").map { hint($0, "filter.clear") } ?? Hint(key: "", text: ""))
        }
        let noMatch = r.nullableObj(v, "", "no_match").map { m in
            NoMatch(title: r.text(m, "no_match", "title"), detail: r.text(m, "no_match", "detail"))
        }
        let goalLines = r.list(v, "", "goal_lines").enumerated().compactMap { i, l -> String? in
            if let s = l as? String { return s }
            r.miss(Reader.at("goal_lines", i))
            return nil
        }
        return Answer(group: group, goal: r.text(v, "", "goal"), goal_lines: goalLines, head: head, open: open,
                      closed_title: r.nullableText(v, "", "closed_title"),
                      closed_key: r.nullableObj(v, "", "closed_key").map { hint($0, "closed_key") },
                      closed_count: r.int(v, "", "closed_count") ?? 0,
                      closed: closed, hints: hints,
                      hint_closed: r.nullableObj(v, "", "hint_closed").map { hint($0, "hint_closed") },
                      filter: filter, no_match: noMatch, missing: r.missing)
    }

    /// One task, or nil without its `id`: what the arrow keys and the open
    /// detail are kept by -- not made up.
    private static func readTask(_ r: Reader, _ v: Reader.Object, _ path: String) -> Task? {
        guard let id = r.int(v, path, "id") else { return nil }
        let detail = r.nullableObj(v, path, "detail").map { readDetail(r, $0, Reader.join(path, "detail")) }
        // Null with no filter; a list of pieces with one. A piece that is
        // not one is left out and said, and the rest still drawn.
        let partsPath = Reader.join(path, "title_parts")
        let parts: [TitlePart]?
        if v["title_parts"] is NSNull {
            parts = nil
        } else if let list = v["title_parts"] as? [Any] {
            parts = list.enumerated().compactMap { i, x -> TitlePart? in
                let x = (x as? Reader.Object) ?? [:], p = Reader.at(partsPath, i)
                let text = r.text(x, p, "text")
                guard let hit = r.bool(x, p, "hit") else { return nil }
                return TitlePart(text: text, hit: hit)
            }
        } else {
            r.miss(partsPath)
            parts = nil
        }
        return Task(id: id, glyph: r.named(v, path, "glyph", as: Glyph.self), state: r.text(v, path, "state"),
                    title: r.text(v, path, "title"), owner: r.text(v, path, "owner"), idle: r.text(v, path, "idle"),
                    title_parts: parts, emph: r.bool(v, path, "emph") ?? false, detail: detail)
    }

    private static func readDetail(_ r: Reader, _ v: Reader.Object, _ path: String) -> Detail {
        let lp = Reader.join(path, "log")
        let log = r.list(v, path, "log").enumerated().compactMap { i, l -> LogLine? in
            let l = (l as? Reader.Object) ?? [:], p = Reader.at(lp, i)
            switch l["entry"] as? String {
            case "event":
                return .event(at: r.nullableText(l, p, "at"), who: r.nullableText(l, p, "who"), text: r.text(l, p, "text"), last: r.bool(l, p, "last") ?? false)
            case "gap":
                // The core writes every key on every line (API.md §2.0):
                // a gap's `at` and `who` null, its `last` false. Read, so
                // that one gone is said, and not drawn.
                _ = (r.nullableText(l, p, "at"), r.nullableText(l, p, "who"), r.bool(l, p, "last"))
                return .gap(text: r.text(l, p, "text"))
            default:
                // A kind of line this build does not know: that line is left out.
                r.miss(Reader.join(p, "entry"))
                return nil
            }
        }
        let sp = Reader.join(path, "said")
        let said = r.list(v, path, "said").enumerated().map { i, x -> Said in
            let x = (x as? Reader.Object) ?? [:], p = Reader.at(sp, i)
            return Said(at: r.text(x, p, "at"), who: r.text(x, p, "who"), text: r.text(x, p, "text"))
        }
        return Detail(body_title: r.text(v, path, "body_title"), body: r.text(v, path, "body"), log_title: r.text(v, path, "log_title"),
                      log: log, said_title: r.text(v, path, "said_title"), said: said)
    }

    /// The request: `openTask` is the one whose detail is wanted, `closed`
    /// whether the closed ones are listed, `filter` what is typed in the
    /// filter box -- "" while it is open and empty, nil with no box
    /// (#2083: **the core filters**, asked again at every change), and
    /// `selected` the one the arrow keys are on -- what Enter's hint speaks
    /// of: "fold" for the open one, "open" for another.
    static func request(group: String, openTask: UInt64?, closed: Bool, filter: String? = nil, selected: UInt64? = nil) -> String {
        let quoted = ControlRoomPageRequest.quoted(group)
        let open = (openTask.map { ",\"open_task\":\($0)" } ?? "") + (selected.map { ",\"selected\":\($0)" } ?? "")
        let typed = filter.map { ",\"filter\":\(ControlRoomPageRequest.quoted($0))" } ?? ""
        return "{\"page\":\"tasks\",\"group\":\(quoted)\(open),\"closed\":\(closed)\(typed)}"
    }

    /// Whether a key-down is the task page's Return: Return or keypad Enter
    /// with no modifier, the page holding the keyboard, and no text box
    /// holding it.
    ///
    /// **Why it is asked so early** (0x373c, group seq 261): on macOS 26 a
    /// Return pressed on the page never reached its `onKeyPress` -- no log,
    /// nothing drawn -- while `c` beside it did. The same page in a bare
    /// window gets Return there, so something in the control room takes it
    /// as a key equivalent first; what, reading did not find. The content
    /// view is offered every key equivalent before any view inside it.
    static func returnIsThePages(keyCode: UInt16, modifiers: UInt, pageHasKeyboard: Bool, textHasKeyboard: Bool) -> Bool {
        let returnKey: UInt16 = 36, enterKey: UInt16 = 76
        return (keyCode == returnKey || keyCode == enterKey) && modifiers == 0 && pageHasKeyboard && !textHasKeyboard
    }

    /// A press on task `id`: it is selected, and opened -- or shut, when it
    /// is the open one.
    static func afterPress(_ id: UInt64, open: UInt64?) -> (selected: UInt64?, open: UInt64?) {
        (id, open == id ? nil : id)
    }

    /// Return with `selected` (or, with none, `first`) and `open`: the
    /// selected one opened when it is not the open one -- the open one, if
    /// another, shut by that -- and shut when it is. The arrow keys move
    /// only the selection (`step`).
    static func afterReturn(selected: UInt64?, open: UInt64?, first: UInt64?) -> (selected: UInt64?, open: UInt64?) {
        guard let s = selected ?? first else { return (nil, open) }
        return (s, open == s ? nil : s)
    }

    /// The most rows the goal takes: the chat's brief takes as many
    /// (`briefRows` in chat.zig, #2043), and the Windows host's
    /// `tasks_scene::GOAL_ROWS`.
    static let goalRowLimit = 2

    /// The goal's rows `width` wide: each of the core's lines wrapped on its
    /// own (#2060: run together they read "…工具条- api: …"), the empty ones
    /// skipped, no more than `goalRowLimit` in all -- a first line that
    /// wraps to two leaves no room for the second. The Windows host's
    /// `tasks_scene::goal_rows`, wrapped the same way (`wrap`).
    static func goalRows(_ lines: [String], width: CGFloat, measure: (String) -> CGFloat) -> [String] {
        // The goal's text lines as drawn -- not the list's rows.
        var shown: [String] = []
        for line in lines {
            if shown.count >= goalRowLimit { break }
            if line.allSatisfy(\.isWhitespace) { continue }
            shown += wrap(line, width: width, measure: measure)
        }
        return Array(shown.prefix(goalRowLimit))
    }

    /// What may not begin a line (避头) -- the Windows host's
    /// `tasks_scene::closes`, the same marks.
    static func closes(_ c: Character) -> Bool {
        "。，、．：；！？）」』】〉》〕｝…—”’%,.;:!?)]}".contains(c)
    }

    /// Where a line of `chars` ends when `n` fit: earlier when the next line
    /// would begin with a closing mark, the character before going down with
    /// it (推出) -- the Windows host's `tasks_scene::break_before`.
    static func breakBefore(_ chars: [Character], _ n: Int) -> Int {
        guard n > 0, n < chars.count else { return n }
        var k = n
        while k > 1 && closes(chars[k]) { k -= 1 }
        return closes(chars[k]) ? n : k
    }

    /// `text` in lines `width` wide: at the last space that fits, or where
    /// the room ends when there is none, never a closing mark first. The
    /// Windows host's `layout::wrap` with `tasks_scene::wrapped`'s
    /// measuring, step for step, so that the two hosts break a goal alike.
    static func wrap(_ text: String, width: CGFloat, measure: (String) -> CGFloat) -> [String] {
        var out: [String] = []
        for para in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Array(para)
            while let last = rest.last, last.isWhitespace { rest.removeLast() }
            while !rest.isEmpty && out.count < 1000 {
                // How many fit, then pushed off a closing mark.
                var lo = 0, hi = rest.count
                while lo < hi {
                    let mid = (lo + hi + 1) / 2
                    if measure(String(rest[0..<mid])) <= width { lo = mid } else { hi = mid - 1 }
                }
                let total = rest.count
                let n = min(max(breakBefore(rest, lo), 1), total)
                if n >= total { break }
                let cut: Int
                if rest[n].isWhitespace {
                    cut = n
                } else if let at = rest[0..<n].lastIndex(where: \.isWhitespace), at != 0 {
                    cut = at
                } else {
                    cut = n
                }
                var head = Array(rest[0..<cut])
                while let last = head.last, last.isWhitespace { head.removeLast() }
                out.append(String(head))
                rest = Array(rest[cut...].drop(while: \.isWhitespace))
            }
            out.append(String(rest))
        }
        return out
    }

    /// Where the arrow keys go from `selected`: one on, one back, held at
    /// the ends; the first when none -- or one no longer there -- is.
    static func step(_ a: Answer, from selected: UInt64?, down: Bool) -> UInt64? {
        let ids = a.inOrder.map(\.id)
        guard let first = ids.first else { return nil }
        guard let at = selected.flatMap({ ids.firstIndex(of: $0) }) else { return first }
        return ids[down ? min(at + 1, ids.count - 1) : max(at - 1, 0)]
    }

    /// The columns of a task's line `width` wide, from its left: glyph, id,
    /// state, title, owner, idle -- as `(x, width)`. **Narrow, the idle
    /// column goes** (#2083): when the title would be narrower than
    /// `title_min`, the idle column is 0 wide -- not drawn -- and the owner
    /// takes `col_owner_narrow`. The Windows host's `tasks_scene::columns`.
    static func columns(width: CGFloat) -> [(x: CGFloat, width: CGFloat)] {
        typealias Metrics = ControlRoomLook.TaskPage
        let x0 = CGFloat(Metrics.rowPadX)
        let right = width - CGFloat(Metrics.rowPadX)
        let glyph = (x0, CGFloat(Metrics.colGlyph))
        let id = (glyph.0 + glyph.1, CGFloat(Metrics.colId))
        let state = (id.0 + id.1, CGFloat(Metrics.colState))
        let wide = right - (state.0 + state.1) - CGFloat(Metrics.colOwner + Metrics.colIdle) >= CGFloat(Metrics.titleMin)
        let idleWidth = wide ? CGFloat(Metrics.colIdle) : 0
        let idle = (right - idleWidth, idleWidth)
        let owner = (idle.0 - CGFloat(wide ? Metrics.colOwner : Metrics.colOwnerNarrow), CGFloat(wide ? Metrics.colOwner : Metrics.colOwnerNarrow))
        let title = (state.0 + state.1, max(owner.0 - (state.0 + state.1), 0))
        return [glyph, id, state, title, owner, idle].map { (x: $0.0, width: max($0.1, 0)) }
    }

    /// A state's symbol and colour key, from the look (`strings.task_symbol`,
    /// `colors.task_<state>`): the same data the Windows host draws by.
    static func symbol(_ g: Glyph) -> String {
        typealias Symbols = ControlRoomLook.TaskSymbol
        switch g {
        case .queued: return Symbols.queued
        case .working: return Symbols.working
        case .blocked: return Symbols.blocked
        case .done: return Symbols.done
        case .closed: return Symbols.closed
        case .cancelled: return Symbols.cancelled
        }
    }

    static func color(_ g: Glyph, theme t: ControlRoomLook.Theme) -> ControlRoomLook.RGBA {
        switch g {
        case .queued: t.taskQueued
        case .working: t.taskWorking
        case .blocked: t.taskBlocked
        case .done: t.taskDone
        case .closed: t.taskClosed
        case .cancelled: t.taskCancelled
        }
    }
}
