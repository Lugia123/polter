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

    /// One place in a task's squad. **`slot` is the whole of its state** --
    /// `filled`, `empty` (nobody has taken it) or `vacated` (its terminal
    /// has gone) -- and the word drawn is this host's (`Slot`). There is no
    /// status from the core: it holds no per-seat progress, and a sentence
    /// invented in the core would be one language inside a page both hosts
    /// translate.
    struct SquadSeat: Decodable, Equatable {
        var alias: String
        var role: String
        var lead: Bool
        var slot: String
        var terminal: String
        var cli: String

        /// What the seat's chip says. A slot this build does not know draws
        /// no word at all, rather than guessing one.
        var slotWord: String? {
            switch slot {
            case "filled": return String(localized: "Seated", comment: "任务详情·小队席位：位子上有人")
            case "empty": return String(localized: "Not seated yet", comment: "任务详情·小队席位：位子空着，还没人坐")
            case "vacated": return String(localized: "Seat left", comment: "任务详情·小队席位：坐过的人走了，位子空着")
            default: return nil
            }
        }
    }

    struct SquadDetail: Decodable, Equatable {
        var name: String
        var seats: [SquadSeat]
    }

    struct WorktreeDetail: Decodable, Equatable {
        var branch: String
        /// The ledger's path; empty for a tree that is only planned.
        var path: String
        /// `made` or `planned`, a token: the word is this host's.
        var state: String

        var stateWord: String? {
            switch state {
            case "made": return String(localized: "Ready", comment: "任务详情·工作树：树已经建好了")
            case "planned": return String(localized: "Planned, not made yet", comment: "任务详情·工作树：计划要建，还没建")
            default: return nil
            }
        }
    }

    struct TokenSlice: Decodable, Equatable {
        var alias: String
        var role: String
        var tokens: String
        var pct: UInt8
        var color: String
    }

    struct TokensDetail: Decodable, Equatable {
        var total: String
        var breakdown: [TokenSlice]
    }

    struct Detail: Decodable, Equatable {
        var body_title: String
        var body: String
        var log_title: String
        var log: [LogLine]
        var said_title: String
        var said: [Said]
        var squad: SquadDetail?
        var worktree: WorktreeDetail?
        var tokens: TokensDetail?
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
        /// The tree's branch (`wt/group/task`), drawn as the tag after the
        /// title; nil for a task with no tree.
        var worktree: String?

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
        let worktreeTag = (v["worktree"] as? String)
        return Task(id: id, glyph: r.named(v, path, "glyph", as: Glyph.self), state: r.text(v, path, "state"),
                    title: r.text(v, path, "title"), owner: r.text(v, path, "owner"), idle: r.text(v, path, "idle"),
                    title_parts: parts, emph: r.bool(v, path, "emph") ?? false, detail: detail, worktree: worktreeTag)
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

        let squad: SquadDetail? = {
            guard let sq = v["squad"] as? Reader.Object else { return nil }
            let sp = Reader.join(path, "squad")
            let name = r.text(sq, sp, "name")
            let seats = r.list(sq, sp, "seats").enumerated().map { i, s -> SquadSeat in
                let s = (s as? Reader.Object) ?? [:], p = Reader.at(Reader.join(sp, "seats"), i)
                return SquadSeat(
                    alias: r.text(s, p, "alias"),
                    role: r.text(s, p, "role"),
                    lead: r.bool(s, p, "lead") ?? false,
                    slot: r.text(s, p, "slot"),
                    terminal: r.text(s, p, "terminal"),
                    cli: r.text(s, p, "cli")
                )
            }
            return SquadDetail(name: name, seats: seats)
        }()

        let worktree: WorktreeDetail? = {
            guard let wt = v["worktree"] as? Reader.Object else { return nil }
            let wp = Reader.join(path, "worktree")
            return WorktreeDetail(
                branch: r.text(wt, wp, "branch"),
                path: r.text(wt, wp, "path"),
                state: r.text(wt, wp, "state")
            )
        }()

        let tokens: TokensDetail? = {
            guard let tk = v["tokens"] as? Reader.Object else { return nil }
            let tp = Reader.join(path, "tokens")
            let total = r.text(tk, tp, "total")
            let breakdown = r.list(tk, tp, "breakdown").enumerated().map { i, b -> TokenSlice in
                let b = (b as? Reader.Object) ?? [:], p = Reader.at(Reader.join(tp, "breakdown"), i)
                return TokenSlice(
                    alias: r.text(b, p, "alias"),
                    role: r.text(b, p, "role"),
                    tokens: r.text(b, p, "tokens"),
                    pct: UInt8(r.int(b, p, "pct") ?? 0),
                    color: r.text(b, p, "color")
                )
            }
            return TokensDetail(total: total, breakdown: breakdown)
        }()

        return Detail(body_title: r.text(v, path, "body_title"), body: r.text(v, path, "body"), log_title: r.text(v, path, "log_title"),
                      log: log, said_title: r.text(v, path, "said_title"), said: said, squad: squad, worktree: worktree, tokens: tokens)
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

    /// `text` in lines `width` wide: where the room ends when that is between
    /// words or beside a Chinese, Japanese or Korean character, otherwise at
    /// the last space or such character before it (`breakAt`, task 2105),
    /// never a closing mark first. The Windows host's `layout::wrap` with
    /// `tasks_scene::wrapped`'s measuring, step for step, so that the two
    /// hosts break a goal alike.
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
                let cut = breakAt(rest, n)
                var head = Array(rest[0..<cut])
                while let last = head.last, last.isWhitespace { head.removeLast() }
                out.append(String(head))
                rest = Array(rest[cut...].drop(while: \.isWhitespace))
            }
            out.append(String(rest))
        }
        return out
    }

    /// Where a line of `s` ends when the room runs out at `end` (task 2105):
    /// there, when the next character is a space or either side of it is
    /// Chinese, Japanese or Korean, and not after an opening bracket (避尾);
    /// inside a word, at the last space or edge of such a character before
    /// it; at `end` when there is neither. The Windows host's
    /// `layout::break_at`, step for step. **Only a space was a break
    /// before**: a Chinese goal with one space in it broke as 「第 5」.
    static func breakAt(_ s: [Character], _ end: Int) -> Int {
        let next: Character? = end < s.count ? s[end] : nil
        let prev: Character? = end > 0 ? s[end - 1] : nil
        let free = !(prev.map(opens) ?? false)
        if next?.isWhitespace ?? true { return end }
        if free && ((prev.map(wide) ?? false) || (next.map(wide) ?? false)) { return end }
        var last: Int?
        var at = 1
        while at < end {
            let c = s[at], before = s[at - 1]
            if !opens(before) && (c.isWhitespace || wide(c) || wide(before)) { last = at }
            at += 1
        }
        return last ?? end
    }

    /// Whether `c` is from a script that breaks between any two characters
    /// -- Chinese, Japanese, Korean -- or one of their full-width marks. The
    /// Windows host's `layout::wide`, the same ranges.
    static func wide(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    /// What may not end a line (避尾) -- the Windows host's `layout::opens`.
    static func opens(_ c: Character) -> Bool {
        "（【「『《〈〔［｛“‘([{".contains(c)
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
