import Foundation
import CoreGraphics

/// The overall answer, and the left panel's bottom line that opens it (task
/// 2149, handoff §6, the first of slice 2's three blocks).
///
/// **The core decides, this reads.** Which numbers there are, whether the
/// swap is rising and whether the disk is under its line all arrive as
/// fields (`OverallPage.render`); nothing here compares, sorts or judges
/// (`tools/control-room-hosts-do-not-decide.py`). What is local is what a
/// host is for: the words in the person's language, and where the parts of
/// one row go.
///
/// No SwiftUI here: the reading and the arithmetic are tested on their own
/// (`tools/mac-logic-tests`), and the row that draws them is
/// `ControlRoomOverallView.swift`.
enum ControlRoomOverall {
    typealias Look = ControlRoomLook

    /// **The door onto the core, in the one spelling this file and the row
    /// that draws it can compile against.** `ControlRoomPageSource` names
    /// `GhosttyKit` and is built only into the application; this file and
    /// the row are also built into `tools/mac-logic-tests`, where that name
    /// has no definition. So the door is a closure over this file's own two
    /// outcomes, and whoever has the core hands one in
    /// (`ControlRoomController`, which holds the real source).
    ///
    /// **`notReady` and `refused` are two things and stay two** (CLAUDE.md
    /// 「验证」第 5 条): the first means the core has no reading yet and is
    /// silent by design, the second is a fault worth writing down. One
    /// "failed" case would have the first tick of every window opening --
    /// which always has nothing in it -- written down as an error.
    typealias Ask = (String) -> Reply

    enum Reply: Equatable {
        /// The core's own bytes.
        case answer(String)
        /// Nothing yet: the row is simply not drawn.
        case notReady
        /// Refused, with words worth writing down.
        case refused(String)
    }

    /// The machine, as much of it as this row says: the swap, and the free
    /// space on the startup disk.
    struct Machine {
        var swapUsedMib: UInt64?
        var swapTotalMib: UInt64?
        var diskFreeMib: UInt64?
        /// The core's own verdict, by its own rules (handoff §4).
        var swapRising: Bool
        /// MiB an hour, the core's own least-squares slope; the overall
        /// view's swap figure writes it beside the number. Zero with no
        /// reading, and then the figure writes no rate.
        var swapSlopeMibPerHour: Int
        /// Below the line macOS starts closing apps at. A line, not a rise.
        var diskLow: Bool
        /// **The line itself**, MiB (handoff §4: 15 GB, below which the
        /// system starts closing applications). The figure writes it, so
        /// that the number a reader is told is the core's and not one this
        /// side remembered.
        var diskLowLineMib: UInt64?
        /// `[second, MiB]`, oldest first: what the little curve draws.
        ///
        /// **No step beside it.** The core's `hour_step_s` is
        /// `polter.series`' own, for the layer chart; this row draws the
        /// last 24 hours on the points' own axis and has no use for it, and
        /// a field nothing reads is a field that is wrong quietly.
        var swapHour: [(UInt64, UInt64)]
        /// The same for the free space on the startup disk, which is what
        /// the 15 GB line is drawn against (`machine.disk_hour`).
        var diskHour: [(UInt64, UInt64)]
    }

    struct Answer {
        var totalMib: UInt64
        /// Tenths of a core, as the core writes them ("2.6"). Kept as the
        /// core's string: the overall view's first block draws it.
        var cpuCores: String
        var machine: Machine
        /// **One entry per group**, in the core's own order (task 2149,
        /// handoff §6): the group page's strip draws the first of them, the
        /// one the page is about (`overall?group=<群>`). Empty when the
        /// answer is not about groups, or when none could be read.
        ///
        /// A list and not one group, because the same answer is what the
        /// overall view reads with no group named, where the group page's
        /// strip is not drawn at all.
        var groups: [Group]
        /// **All of Polter**: every process the reading tracks, in the core's
        /// own order, and what is under it that no process table holds
        /// (task 2149, handoff §6's process table and the chart).
        var polter: Whole
    }

    /// **Which row the chart's rise line and its sentence are about** (task
    /// 2149, handoff §6), as the core names it: the one row that is rising,
    /// and by how much.
    ///
    /// **The core chooses this row, not the host.** The chart draws one line
    /// at the moment the rising began, and one sentence under it naming who
    /// it is; a host that picked the row itself -- the largest slope, the
    /// first rising one -- would be answering a question the core answers
    /// (`tools/control-room-hosts-do-not-decide.py`, rule 4: no `max(by:)`).
    /// So the core sends the row it means, and this side reads it and draws
    /// it.
    ///
    /// **Nil is not zero**: it means nothing is rising, and then no line and
    /// no sentence are drawn. An answer that does not carry the block at all
    /// reads the same way, so the view is written against one case.
    struct Rise {
        /// The core's own name for the rising row's group: what the sentence
        /// says after its category. Null for the main process and the
        /// monitor, which are in no group.
        var group: String?
        var category: String
        /// **Which process the rising row is.** Two sidecars of one group are
        /// two rows with one group between them, so the group alone does not
        /// say which one is climbing. Nothing on the page draws it yet; it is
        /// here because it is the fact that tells the two apart
        /// (`OverallPage.zig`'s `Rise.pid`).
        var pid: UInt64
        /// When it began rising, seconds since Polter started: **the chart's
        /// rise line is placed from this and the core's own `now_s`**
        /// (`riseMarkFraction`).
        var sinceS: UInt64
        /// The same moment on the reader's clock, for the sentence.
        var since: String?
        /// How much the window gained, MiB, and the rate it is going at:
        /// both the core's, so that the sentence is not the host doing the
        /// arithmetic.
        var roseMib: UInt64
        var slopeMibPerHour: Int
    }

    /// **One heading of the process table, with the two numbers the core
    /// counted and added up itself** (task 2149, slice 2, review r2 ①).
    ///
    /// The heading says the group's name, how many rows are behind it and
    /// what they add up to. **Both numbers are the core's**, read here
    /// verbatim: a host that added the rows it was handed up would be
    /// counting rows, which is rule 2 of
    /// `tools/control-room-hosts-do-not-decide.py` -- and it would get the
    /// main process's group wrong, because the core's own category puts the
    /// monitor's row there while its memory is already inside the main
    /// process's. The core leaves that row out of both numbers
    /// (`OverallPage.zig`'s `sectionsOf`), so `count: 1` over the main
    /// process counts its one row of its own: the "of which" row drawn
    /// under it is not counted, and neither number is a count of processes.
    ///
    /// **The rows under a heading are drawn by the core's own `category` on
    /// each of them** (`Process.category`, which the core names for exactly
    /// this): this side takes `processes` in the order they arrive and draws
    /// each under the heading whose name it carries. Nothing here decides
    /// which row is whose group either.
    struct Section: Equatable {
        var category: String
        /// How many of the rows drawn under this heading count on their
        /// own: the `inside_main` row is drawn here and not counted. Not a
        /// number of processes.
        var count: UInt64
        /// What those rows add up to, MiB, the monitor's row not in it.
        var totalMib: UInt64
    }

    /// The whole answer's `polter` block: the numbers the four figures draw
    /// and the three stacked layers.
    struct Whole {
        /// Tenths of a core, all of Polter's rows together.
        var cpuDecimals: UInt64
        /// What the monitor itself holds, for the last row of the process
        /// table (handoff §1's fifth point).
        var monitorBytes: UInt64
        /// Readings that had no row to go in: "another N are not tracked"
        /// is then answerable rather than silent.
        var untracked: UInt64
        /// When Polter started, on the reader's own clock: the chart's
        /// x-axis begins here.
        var runStarted: String
        /// The three layers, oldest cell first, for each span. **In the
        /// order the stack is drawn**, which is the core's order
        /// (`layers`), not one this side sorts.
        var series: Series
        /// **Every row of the process table, in the core's own order**, each
        /// carrying the core's own `category`: which heading a row is drawn
        /// under is the core's word on the row, and this side neither sorts
        /// the rows nor works out whose they are
        /// (`ControlRoomOverall.Process.category`).
        var processes: [Process]
        /// **The table's three headings, each with the core's own count and
        /// total** (`Section`): the rows under them are `processes`, taken in
        /// the order they arrive, and neither number is worked out here.
        var sections: [Section]
        /// **The row the chart's rise line and its sentence are about**, as
        /// the core chose it; nil when nothing is rising. Never worked out
        /// here (`Rise`).
        var rise: Rise?
    }

    /// One span's three layers. **The step between cells is the core's**:
    /// the host places a point, it does not choose the resolution.
    struct Series {
        var hour: [Layer]
        var week: [Layer]
        var hourStepS: UInt64
        var weekStepS: UInt64
        /// **The moment the chart's right-hand edge is**, seconds since
        /// Polter started: the core's `series.now_s`, on the same clock as
        /// `growth.since_s`, which is what the rise mark is placed from
        /// (`riseMarkFraction`).
        var nowS: UInt64

        /// The three layers of a span, in the core's order.
        func layers(_ span: Span) -> [Layer] { span == .day ? hour : week }
        func stepS(_ span: Span) -> UInt64 { span == .day ? hourStepS : weekStepS }

        static let none = Series(hour: [], week: [], hourStepS: 0, weekStepS: 0, nowS: 0)
    }

    /// One layer of the stack: a category, and its cells in MiB.
    struct Layer: Equatable {
        /// The core's own name for the category, in the order the stack is
        /// drawn; the host draws it as it comes. **Never compared**: the
        /// order is the core's (`layers`), and a host that sorted or matched
        /// these would be deciding the stack a second time
        /// (`tools/control-room-hosts-do-not-decide.py`).
        var name: String
        var cells: [UInt64]
    }

    /// Which of the two spans the chart is drawn over. The same two names
    /// the performance page's own switch uses (`ControlRoomResources.Span`),
    /// because they are the same two spans.
    enum Span: String, CaseIterable, Equatable {
        case day = "hour"
        case week

        /// What the switch says, in the person's language.
        var label: String {
            switch self {
            case .day: String(localized: "24 hours", comment: "总控台：整体视图面积图的跨度切换，最近 24 小时")
            case .week: String(localized: "7 days", comment: "总控台：整体视图面积图的跨度切换，最近 7 天")
            }
        }
    }

    /// One process behind the table (task 2149, handoff §3): what the core
    /// read, and the two verdicts it made itself.
    struct Process: Equatable {
        /// **Which of the table's three groups this row is drawn in**, as
        /// the core named it (`main`, `chats`, `sidecars`). The core has the
        /// row's kind beside it and this side **must not read that**: which
        /// kind belongs to which group is the core's own rule
        /// (`Overall.categoryOf`), and a host mapping the four kinds itself
        /// would have a second copy of it
        /// (`tools/control-room-hosts-do-not-decide.py`). Drawn as it comes,
        /// and never compared.
        var category: String
        var pid: UInt64
        /// Null for the main process and the monitor, which are in no group.
        var group: String?
        /// How many processes are behind this row: one, except a sidecar
        /// row, which may be several `polter +mcp` processes.
        var count: UInt64
        var memMib: UInt64
        var cpuDecimals: UInt64
        var rising: Bool
        var slopeMibPerHour: Int
        /// **This row is inside the main process's, already counted there**
        /// (the monitor's own row): a reader who adds the rows up must not
        /// count it twice, and the words beside it say so.
        var insideMain: Bool
        /// **Whether the reading in front of the reader still names it.** A
        /// row nothing names is kept for 24 hours, so the morning shows what
        /// died overnight.
        var alive: Bool
        /// When it stopped being named, on the reader's clock.
        var diedAt: String?
        /// When the process started; null for a row that is several
        /// processes or a platform that does not say.
        var started: String?
        /// The terminal this row is, for a sidecar or a chat.
        var terminal: String?

        /// Whether this row is one the table's own ordering already puts
        /// last: the monitor's, drawn as "其中：性能监控".
        var isTheMonitor: Bool { insideMain }
    }

    /// One group's own cost, as `OverallPage.zig`'s `Group` writes it.
    struct Group: Equatable {
        var group: String
        /// What the bar's four widths fill: the group's terminals' whole
        /// trees plus its embedded chat. **Carried for the words beside the
        /// bar, not for the widths** -- those come from `parts.sumMib`, so
        /// that the pieces and the bar they fill cannot disagree by a
        /// rounding.
        var totalMib: UInt64
        var parts: Parts
        var own: Own
    }

    /// The four parts of a group's own cost, in the order the bar draws
    /// them and the order the legend names them.
    struct Parts: Equatable {
        /// The group's supervisor terminal's tree.
        var supervisorMib: UInt64
        /// Every other working terminal's tree.
        var workersMib: UInt64
        /// The person's own terminals.
        var yoursMib: UInt64
        /// The group's embedded chat: the group's own and no terminal's.
        var ownMib: UInt64

        /// The four, in the order they are drawn.
        var inOrder: [UInt64] { [supervisorMib, workersMib, yoursMib, ownMib] }
        /// **Added up here rather than read from `total_mib`.** The core
        /// makes both from one walk (`groupsOf`), so they agree; taking the
        /// sum means a bar whose pieces over- or under-fill it is not a
        /// thing that can be drawn.
        var sumMib: UInt64 { inOrder.reduce(0, +) }

        static let none = Parts(supervisorMib: 0, workersMib: 0, yoursMib: 0, ownMib: 0)
    }

    /// What the group holds that is not one of its terminals: its embedded
    /// chat, and the two numbers no process table has (task 2149, handoff
    /// §2 and §3).
    struct Own: Equatable {
        /// The row behind the chat, so a press can point at a process; nil
        /// when the group has no chat running.
        var chatPid: UInt64?
        var chatMib: UInt64
        /// **The core's own verdict**, by its own rules (handoff §4): the
        /// card is then in the warning ink. Nothing here weighs a slope.
        var rising: Bool
        /// MiB an hour, as the core worked it out; the card writes it, and
        /// a reader is not shown zero when it is not rising.
        var slopeMibPerHour: Int
        /// When it began rising, on the reader's own clock; null when it is
        /// not rising.
        var since: String?
        var tasks: UInt64
        var tasksOpen: UInt64
        var recordBytes: UInt64

        static let none = Own(chatPid: nil, chatMib: 0, rising: false, slopeMibPerHour: 0,
                              since: nil, tasks: 0, tasksOpen: 0, recordBytes: 0)
    }

    enum DecodeError: Error, Equatable {
        /// Not JSON, or not an object.
        case unreadable
        /// The core's own refusal: never an empty page.
        case refused(String)
        /// No `machine` or `polter`: not this answer.
        case notTheOverall
    }

    /// The answer, read field by field (`ControlRoomAnswerReader`), so that
    /// one missing number costs what it is drawn as and not the row: a
    /// machine whose swap could not be read draws no swap, and the rest of
    /// the line is there.
    static func decode(_ data: Data) throws -> Answer {
        guard let v = (try? JSONSerialization.jsonObject(with: data)) as? ControlRoomAnswerReader.Object else {
            throw DecodeError.unreadable
        }
        if let e = v["error"] as? String { throw DecodeError.refused(e) }
        guard let polter = v["polter"] as? ControlRoomAnswerReader.Object else { throw DecodeError.notTheOverall }
        let r = ControlRoomAnswerReader()
        let m = v["machine"] as? ControlRoomAnswerReader.Object
        if m == nil { r.miss("machine") }
        return Answer(
            totalMib: r.int(polter, "polter", "total_mib") ?? 0,
            cpuCores: r.text(polter, "polter", "cpu_cores"),
            machine: Machine(
                swapUsedMib: m.flatMap { r.nullableInt($0, "machine", "swap_used_mib") },
                swapTotalMib: m.flatMap { r.nullableInt($0, "machine", "swap_total_mib") },
                diskFreeMib: m.flatMap { r.nullableInt($0, "machine", "disk_free_mib") },
                swapRising: m.flatMap { r.obj($0, "machine", "swap_growth") }.flatMap { r.bool($0, "machine.swap_growth", "rising") } ?? false,
                swapSlopeMibPerHour: m.flatMap { r.obj($0, "machine", "swap_growth") }
                    .flatMap { r.number($0, "machine.swap_growth", "slope_mib_per_h") }.map(Int.init) ?? 0,
                diskLow: m.flatMap { r.bool($0, "machine", "disk_low") } ?? false,
                diskLowLineMib: m.flatMap { r.nullableInt($0, "machine", "disk_low_line_mib") },
                swapHour: m.map { readPairs(r, $0, "machine", "swap_hour") } ?? [],
                diskHour: m.map { readPairs(r, $0, "machine", "disk_hour") } ?? []),
            groups: readGroups(r, v),
            polter: readWhole(r, polter))
    }

    /// All of Polter: the numbers the overall view's four blocks draw, the
    /// three stacked layers of its chart, and the rows of its process table
    /// (task 2149, handoff §6).
    ///
    /// **A missing `polter` is not this answer at all** (`decode` refuses
    /// above), so what is read here is read leniently: a field that is not
    /// there is the number it is drawn as, and the reading is still a
    /// reading.
    private static func readWhole(_ r: ControlRoomAnswerReader, _ p: ControlRoomAnswerReader.Object) -> Whole {
        let series = r.obj(p, "polter", "series")
        return Whole(
            cpuDecimals: r.int(p, "polter", "cpu_ds") ?? 0,
            monitorBytes: r.int(p, "polter", "monitor_bytes") ?? 0,
            untracked: r.int(p, "polter", "untracked") ?? 0,
            runStarted: r.text(p, "polter", "run_started"),
            series: Series(
                hour: readLayers(r, series, "polter.series", "hour"),
                week: readLayers(r, series, "polter.series", "week"),
                hourStepS: series.flatMap { r.int($0, "polter.series", "hour_step_s") } ?? 0,
                weekStepS: series.flatMap { r.int($0, "polter.series", "week_step_s") } ?? 0,
                nowS: series.flatMap { r.int($0, "polter.series", "now_s") } ?? 0),
            processes: readProcesses(r, p),
            sections: readSections(r, p),
            rise: readRise(r, p))
    }

    /// **The table's headings, as the core counted and added them up**
    /// (`Section`). Read verbatim and never recomputed: the count and the
    /// total are the two numbers the heading draws, and both are answers
    /// this side is not allowed to work out for itself
    /// (`tools/control-room-hosts-do-not-decide.py`, rule 2).
    ///
    /// A missing list is no headings, and then the table draws its rows with
    /// no lines over them rather than inventing groups.
    private static func readSections(_ r: ControlRoomAnswerReader, _ p: ControlRoomAnswerReader.Object) -> [Section] {
        r.list(p, "polter", "sections").enumerated().compactMap { i, item in
            let path = ControlRoomAnswerReader.at("polter.sections", i)
            guard let o = item as? ControlRoomAnswerReader.Object else {
                r.miss(path)
                return nil
            }
            return Section(category: r.text(o, path, "category"),
                           count: r.int(o, path, "count") ?? 0,
                           totalMib: r.int(o, path, "total_mib") ?? 0)
        }
    }

    /// **The row the chart's rise line and its sentence are about**, as the
    /// core chose it (task 2149, slice 2). Nil when the answer carries no
    /// such block -- which is what a machine nothing is rising on looks
    /// like, and what an older answer looks like -- and then the chart
    /// draws no line and no sentence.
    ///
    /// **The host never picks this row.** Which one is rising, by how much
    /// and at what rate are the core's answers
    /// (`tools/control-room-hosts-do-not-decide.py`, rule 4).
    private static func readRise(_ r: ControlRoomAnswerReader, _ p: ControlRoomAnswerReader.Object) -> Rise? {
        guard let o = r.obj(p, "polter", "rise") else { return nil }
        return Rise(
            group: r.nullableText(o, "polter.rise", "group"),
            category: r.text(o, "polter.rise", "category"),
            pid: r.int(o, "polter.rise", "pid") ?? 0,
            sinceS: r.int(o, "polter.rise", "since_s") ?? 0,
            since: r.nullableText(o, "polter.rise", "since"),
            roseMib: r.int(o, "polter.rise", "rose_mib") ?? 0,
            slopeMibPerHour: r.number(o, "polter.rise", "slope_mib_per_h").map(Int.init) ?? 0)
    }

    /// The process table's rows, **in the core's order and with the core's
    /// own group on each** (task 2149, handoff §6).
    ///
    /// **Not sorted here, and the groups not worked out here.** The core
    /// orders the rows and names each one's group
    /// (`OverallPage.zig`'s `rowsOf`); a host that sorted them, or that
    /// took the rows with `category == "chats"` because it knew what a chat
    /// is, would be deciding the table a second time
    /// (`tools/control-room-hosts-do-not-decide.py`).
    private static func readProcesses(_ r: ControlRoomAnswerReader, _ p: ControlRoomAnswerReader.Object) -> [Process] {
        r.list(p, "polter", "processes").enumerated().compactMap { i, item in
            let path = ControlRoomAnswerReader.at("polter.processes", i)
            guard let o = item as? ControlRoomAnswerReader.Object else {
                r.miss(path)
                return nil
            }
            let growth = r.obj(o, path, "growth")
            return Process(
                category: r.text(o, path, "category"),
                pid: r.int(o, path, "pid") ?? 0,
                group: r.nullableText(o, path, "group"),
                count: r.int(o, path, "count") ?? 1,
                memMib: r.int(o, path, "mem_mib") ?? 0,
                cpuDecimals: r.int(o, path, "cpu_ds") ?? 0,
                rising: growth.flatMap { r.bool($0, "\(path).growth", "rising") } ?? false,
                slopeMibPerHour: growth.flatMap { r.number($0, "\(path).growth", "slope_mib_per_h") }.map(Int.init) ?? 0,
                insideMain: r.bool(o, path, "inside_main") ?? false,
                alive: r.bool(o, path, "alive") ?? true,
                diedAt: r.nullableText(o, path, "died_at"),
                started: r.nullableText(o, path, "started"),
                terminal: r.nullableText(o, path, "terminal"))
        }
    }

    /// The three layers of one span, **in the order the core stacked them**
    /// (`.main`, `.chats`, `.sidecars`). Nothing here sorts them or works
    /// out which is which: the name arrives beside the cells
    /// (`tools/control-room-hosts-do-not-decide.py`).
    private static func readLayers(_ r: ControlRoomAnswerReader, _ s: ControlRoomAnswerReader.Object?,
                                   _ path: String, _ span: String) -> [Layer] {
        guard let s else {
            r.miss(ControlRoomAnswerReader.join(path, span))
            return []
        }
        return r.list(s, path, span).enumerated().compactMap { i, item in
            let at = ControlRoomAnswerReader.at(ControlRoomAnswerReader.join(path, span), i)
            guard let o = item as? ControlRoomAnswerReader.Object else {
                r.miss(at)
                return nil
            }
            return Layer(name: r.text(o, at, "category"), cells: readCells(r, o, at, "cells"))
        }
    }

    /// One layer's cells, MiB, oldest first. A cell that is not a number is
    /// a cell of nothing rather than a hole: a chart with a gap in it is
    /// not what a missing number means.
    private static func readCells(_ r: ControlRoomAnswerReader, _ o: ControlRoomAnswerReader.Object,
                                  _ path: String, _ key: String) -> [UInt64] {
        r.list(o, path, key).enumerated().map { i, cell in
            if let n = cell as? NSNumber { return n.uint64Value }
            r.miss(ControlRoomAnswerReader.at(ControlRoomAnswerReader.join(path, key), i))
            return 0
        }
    }

    /// Each group's own cost (task 2149, handoff §6). **A missing list is an
    /// answer with no groups in it, and said** -- the group page then draws
    /// no strip, which is what it draws for a group nobody has.
    private static func readGroups(_ r: ControlRoomAnswerReader, _ v: ControlRoomAnswerReader.Object) -> [Group] {
        r.list(v, "", "groups").enumerated().compactMap { i, item in
            let path = ControlRoomAnswerReader.at("groups", i)
            guard let g = item as? ControlRoomAnswerReader.Object else {
                r.miss(path)
                return nil
            }
            let parts = r.obj(g, path, "parts")
            let own = r.obj(g, path, "own")
            let growth = own.flatMap { r.obj($0, "\(path).own", "growth") }
            return Group(
                group: r.text(g, path, "group"),
                totalMib: r.int(g, path, "total_mib") ?? 0,
                parts: Parts(
                    supervisorMib: parts.flatMap { r.int($0, "\(path).parts", "supervisor_mib") } ?? 0,
                    workersMib: parts.flatMap { r.int($0, "\(path).parts", "workers_mib") } ?? 0,
                    yoursMib: parts.flatMap { r.int($0, "\(path).parts", "yours_mib") } ?? 0,
                    ownMib: parts.flatMap { r.int($0, "\(path).parts", "own_mib") } ?? 0),
                own: Own(
                    chatPid: own.flatMap { r.nullableInt($0, "\(path).own", "chat_pid") },
                    chatMib: own.flatMap { r.int($0, "\(path).own", "chat_mib") } ?? 0,
                    rising: growth.flatMap { r.bool($0, "\(path).own.growth", "rising") } ?? false,
                    slopeMibPerHour: growth.flatMap { r.number($0, "\(path).own.growth", "slope_mib_per_h") }.map(Int.init) ?? 0,
                    since: growth.flatMap { r.nullableText($0, "\(path).own.growth", "since") },
                    tasks: own.flatMap { r.int($0, "\(path).own", "tasks") } ?? 0,
                    tasksOpen: own.flatMap { r.int($0, "\(path).own", "tasks_open") } ?? 0,
                    recordBytes: own.flatMap { r.int($0, "\(path).own", "record_bytes") } ?? 0))
        }
    }

    private static func readPairs(_ r: ControlRoomAnswerReader, _ v: ControlRoomAnswerReader.Object,
                                  _ path: String, _ key: String) -> [(UInt64, UInt64)] {
        r.list(v, path, key).enumerated().compactMap { i, item in
            guard let pair = item as? [Any], pair.count == 2,
                  let t = pair[0] as? NSNumber, let val = pair[1] as? NSNumber else {
                r.miss(ControlRoomAnswerReader.at(ControlRoomAnswerReader.join(path, key), i))
                return nil
            }
            return (t.uint64Value, val.uint64Value)
        }
    }

    // MARK: - The overall view's chart (task 2149, handoff §6, the third of
    // slice 2's three blocks)

    /// **The three layers added up, cell by cell**: what a stacked area
    /// chart is made of, and the one piece of arithmetic on this side.
    ///
    /// **Adding up is not deciding.** How many layers there are, what they
    /// are called and which order they come in all arrive from the core
    /// (`Series.layers`, whose order *is* the stack's); the sum of what is
    /// already there is the figure itself. Nothing here sorts them, names
    /// them, or works out which cell belongs to which layer.
    struct Stack: Equatable {
        /// One row per layer, **in the core's order, which is the order the
        /// stack is drawn**: `tops[i][j]` is where the top edge of layer `i`
        /// stands in cell `j`, the layers under it counted in.
        var tops: [[UInt64]]
        /// **The chart's own y axis**: the highest top edge anywhere, which
        /// is what the box's height is a drawing of. Zero with nothing to
        /// draw, and then the chart lies flat on its floor rather than
        /// dividing by nothing.
        var maxMib: UInt64
        /// How many cells the chart has: the longest layer's own count, so
        /// that a layer which came short is zero in the cells it has not
        /// rather than a chart of another width.
        var cells: Int

        /// The bottom edge of one layer in one cell: everything below it,
        /// which is the layer below's own top edge -- and nothing at all for
        /// the bottom layer (`handoff §6`: the three are stacked, not laid
        /// side by side).
        func base(_ layer: Int, _ cell: Int) -> UInt64 {
            guard layer > 0, layer < tops.count, cell >= 0, cell < cells else { return 0 }
            return tops[layer - 1][cell]
        }

        /// One layer's top edge across the whole box, oldest cell first.
        /// Empty for a layer the core did not send.
        func top(_ layer: Int) -> [UInt64] {
            guard layer >= 0, layer < tops.count else { return [] }
            return tops[layer]
        }

        static let none = Stack(tops: [], maxMib: 0, cells: 0)
    }

    /// The core's layers added up (`Stack`). **The order out is the order
    /// in**: the core stacks them and this side draws that stack.
    ///
    /// A layer shorter than the longest is **zero in the cells it does not
    /// have**, not a narrower chart: three layers over one span are all the
    /// same length, and a shorter one is a reading that came short, which is
    /// a gap of nothing rather than a different window.
    static func stack(_ layers: [Layer]) -> Stack {
        let cells = layers.map(\.cells.count).max() ?? 0
        guard cells > 0 else { return .none }
        var tops: [[UInt64]] = []
        tops.reserveCapacity(layers.count)
        var maxMib: UInt64 = 0
        for (i, layer) in layers.enumerated() {
            var row = [UInt64](repeating: 0, count: cells)
            for j in 0..<cells {
                let below = i == 0 ? 0 : tops[i - 1][j]
                // Saturating: a stack whose top edge wrapped round would be
                // drawn as nothing rather than as too much.
                row[j] = below &+ (j < layer.cells.count ? layer.cells[j] : 0)
            }
            maxMib = max(maxMib, row.max() ?? 0)
            tops.append(row)
        }
        return Stack(tops: tops, maxMib: maxMib, cells: cells)
    }

    /// Where a value stands in the chart's box: the tallest at the box's top
    /// edge, nothing on its floor.
    ///
    /// **The area chart's y axis is its own**, in MiB from zero to
    /// `maxMib` -- unlike the two little curves, whose axis is the points
    /// themselves (`ControlRoomResources.curve`). Zero is the floor and not
    /// the middle, and a chart with nothing to draw lies flat on the floor
    /// instead of dividing by it.
    static func stackY(_ mib: UInt64, of maxMib: UInt64, in rect: CGRect) -> CGFloat {
        guard maxMib > 0, mib > 0 else { return rect.maxY }
        let share = min(1, Double(mib) / Double(maxMib))
        return rect.maxY - CGFloat(share) * rect.height
    }

    /// One cell's own band across the box: the cells divide the width
    /// evenly, the first at the left edge and the last ending at the right
    /// one, so that the chart has no gap at either end.
    ///
    /// **The cells are the core's** (`polter.series`): this side places
    /// them; it does not choose how many there are nor how much time each
    /// one is.
    static func cellBand(_ i: Int, of cells: Int, in rect: CGRect) -> CGRect {
        guard cells > 0, i >= 0, i < cells else {
            return CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
        }
        let w = rect.width / CGFloat(cells)
        return CGRect(x: rect.minX + CGFloat(i) * w, y: rect.minY, width: w, height: rect.height)
    }

    /// **Where the rise mark stands across the chart** (handoff §6's
    /// vertical dashed line), as a fraction of the box's width, or nil when
    /// there is no mark to draw.
    ///
    /// The chart's right edge is the core's own `series.now_s`, and the mark
    /// is the moment a row began climbing, on that same clock
    /// (`growth.since_s`); the box is `cells` cells `stepS` seconds apart, so
    /// the moment stands `nowS - sinceS` seconds back from the right edge.
    /// **This side never works that window out from the answer's clock**
    /// (`at` minus `run_started`): that is the core's arithmetic a second
    /// time, and wrong the moment the two clocks are a minute apart.
    ///
    /// Nil when it cannot be drawn, and each nil is a real case: nothing
    /// rising (a null `since_s`), a rise older than the box -- the 7-day
    /// view of one that began an hour ago, or the 24-hour view of one that
    /// began last week -- no cells, no step.
    static func riseMarkFraction(sinceS: UInt64, nowS: UInt64, stepS: UInt64, cells: Int) -> CGFloat? {
        guard cells > 0, stepS > 0, nowS >= sinceS else { return nil }
        let span = Double(cells) * Double(stepS)
        guard span > 0 else { return nil }
        let back = Double(nowS - sinceS)
        guard back <= span else { return nil }
        return CGFloat(1 - back / span)
    }

    /// The same fraction as a place in the box, for a `Path` to be drawn at:
    /// nil on the same terms.
    static func riseMarkX(sinceS: UInt64, nowS: UInt64, stepS: UInt64, cells: Int, in rect: CGRect) -> CGFloat? {
        guard let f = riseMarkFraction(sinceS: sinceS, nowS: nowS, stepS: stepS, cells: cells) else { return nil }
        return rect.minX + f * rect.width
    }

    // MARK: - The process table (handoff §6, the third of slice 2's three
    // blocks)

    /// One line of the process table: a group's own heading, or a process
    /// under one.
    enum TableLine: Equatable {
        case section(Section)
        case process(Process)

        /// The heading, on the line that is one; nil on a process's line.
        var sectionOrNil: Section? {
            if case let .section(s) = self { return s }
            return nil
        }

        /// The pid, on a process's line; nil on a heading's. For tests and
        /// for anything that wants to point at a row.
        var pidOrNil: UInt64? {
            if case let .process(p) = self { return p.pid }
            return nil
        }
    }

    /// **The table's lines, in the core's own order**: one heading per group
    /// the core sent, and under it the rows the core named that group on --
    /// each row drawn once, in the order the core's `processes` has them.
    ///
    /// **Which row is whose group is the core's word on the row**
    /// (`Process.category`) matched against the core's own heading
    /// (`Section.category`): two facts it sent, compared as the two strings
    /// it chose. Nothing here sorts the rows, weighs them against each other
    /// or works out a group the core did not name
    /// (`tools/control-room-hosts-do-not-decide.py`).
    ///
    /// **A row whose category is no heading** -- an answer that carries rows
    /// and no such group -- is left out rather than drawn in a group of its
    /// own, because the host would then be naming a group the core did not.
    static func tableLines(_ w: Whole) -> [TableLine] {
        var out: [TableLine] = []
        for s in w.sections {
            out.append(.section(s))
            for p in w.processes where p.category == s.category { out.append(.process(p)) }
        }
        return out
    }

    /// What the table calls one row.
    ///
    /// **The monitor's own row says it is already counted in the main
    /// process's** (handoff §1's fifth point): a reader who adds the rows up
    /// must not count it twice. Which row that is arrives as the core's
    /// `inside_main`; nothing here works it out from the category, and
    /// "其中" is what says so in the person's language.
    ///
    /// The other rows are named from what the core sent beside them: the
    /// group a chat is, the terminal a sidecar serves, and the application
    /// itself for the main process. **The names are the host's** -- they are
    /// sentences in the person's language and belong in the catalogue -- and
    /// the facts in them are the core's.
    ///
    /// **A sidecar's row names its terminal and not its group.** Both facts
    /// arrive on that row -- the core says which group the terminal behind
    /// the sidecar is in, and that is what draws in the table's own "which
    /// group" column -- so naming it by the group first made every sidecar
    /// read "Chat web-app", the same words as the chat in that group. Which
    /// of the two a row is named by is the core's own `category`, the same
    /// word this file already switches on for the section headings.
    static func rowName(_ p: Process) -> String {
        if p.isTheMonitor {
            return String(localized: "of which: performance monitoring",
                          comment: "总控台：整体视图进程表里监控自己那一行，说明它已经算在主进程里了")
        }
        switch p.category {
        case "sidecars":
            if let terminal = p.terminal, !terminal.isEmpty {
                return String(format: String(localized: "Sidecar for %@",
                                             comment: "总控台：整体视图进程表，MCP 边车那一行，参数是它服务的终端"),
                              terminal)
            }
        case "chats":
            if let group = p.group, !group.isEmpty {
                return String(format: String(localized: "Chat %@",
                                             comment: "总控台：整体视图进程表，「群聊 <群名>」那一行"),
                              group)
            }
        default:
            break
        }
        // A fact that did not arrive leaves the application's own name
        // rather than half a sentence.
        return String(localized: "Polter", comment: "总控台：整体视图进程表，主进程那一行，也是左栏底部那一行的应用名")
    }

    /// **The last row of the table**, which is the monitor's: it is the one
    /// the core flags as inside the main process's, and a reader who adds the
    /// rows up must not count it twice. Nil when the answer carries none,
    /// and then the table draws no such line rather than an empty one.
    static func theMonitorRow(_ processes: [Process]) -> Process? {
        processes.last { $0.isTheMonitor }
    }

    // MARK: - Where the overall view's parts go (handoff §6)

    /// The overall view, top to bottom, in a page `width` points wide and as
    /// tall as its own parts need: the four figures, the chart with its rise
    /// line, the machine's two curves, and the process table.
    ///
    /// **One place**, so that the view and the tests that measure it cannot
    /// work the same box out twice -- the rule `ControlRoomPerfLayout`
    /// follows for the performance page. Built up out of the look's own
    /// numbers and **nothing measured**: a word getting longer in a figure
    /// must not move the chart under it.
    struct Layout: Equatable {
        /// The page's own box, inset by the look's padding.
        var page: CGRect
        /// The four figures, left to right, in the order the answer's
        /// numbers are read (`kpiCount`).
        var kpis: [CGRect]
        var chart: CGRect
        /// **The chart's own inside**: the card less its padding. What the
        /// chart draws is placed against this and not against the card, so
        /// that the card's padding and the page's are not two readings of
        /// where the chart's contents begin.
        var chartInner: CGRect
        /// The chart's title row, its box, and the label rows under it.
        var chartHead: CGRect
        var plot: CGRect
        /// The column the chart's y labels stand in, left of `plot`.
        var plotGutter: CGRect
        var plotXLabels: CGRect
        /// The sentence beside the rise line; empty when nothing is rising.
        var riseNote: CGRect
        var minis: [CGRect]
        var table: CGRect
        var tableHead: CGRect
        /// The whole page's height: what the scroll view has to hold.
        var contentHeight: CGFloat

        /// How many figures the view draws, and which number is which: the
        /// view's own list, in the design's order (`perf5.py`'s `overall`).
        static let kpiCount = 4
    }

    static func layout(width: CGFloat, rising: Bool) -> Layout {
        let o = Look.OverallPage.self
        let padX = CGFloat(o.padX)
        let w = max(0, width - 2 * padX)
        let left = padX
        var y = CGFloat(o.padY)

        // The four figures: equal columns with `kpi_gap` between them, and
        // the value's line, the label's and the sub-line under it.
        let kpiH = CGFloat(o.cardPadY) + CGFloat(o.kpiLine) + CGFloat(o.kpiValueTop)
            + CGFloat(o.kpiValueHeight) + CGFloat(o.kpiLine) + CGFloat(o.cardPadY)
        let cols = Layout.kpiCount
        let gap = CGFloat(o.kpiGap)
        let colW = cols > 0 ? max(0, (w - CGFloat(cols - 1) * gap) / CGFloat(cols)) : 0
        var kpis: [CGRect] = []
        for i in 0..<cols {
            kpis.append(CGRect(x: left + CGFloat(i) * (colW + gap), y: y, width: colW, height: kpiH))
        }
        y += kpiH + CGFloat(o.gap)

        // The chart: a title row, the sentence while something is rising,
        // then the box. The plot's height loses the sentence's room
        // (`plot_height_rising`), as the design's two states do.
        let noteH = rising ? CGFloat(o.riseNoteHeight) + CGFloat(o.riseNoteTop) : 0
        let plotH = CGFloat(rising ? o.plotHeightRising : o.plotHeight)
        let plotTop = CGFloat(o.plotTop)
        let xLabels = CGFloat(o.plotAxisGap) + CGFloat(o.plotLabelHeight)
        let chartH = CGFloat(o.cardPadY) + CGFloat(o.chartHeadHeight) + noteH + plotTop
            + plotH + xLabels + CGFloat(o.cardPadY)
        let chart = CGRect(x: left, y: y, width: w, height: chartH)
        let inX = left + CGFloat(o.cardPadX)
        let inW = max(0, w - 2 * CGFloat(o.cardPadX))
        let inner = CGRect(x: inX, y: y + CGFloat(o.cardPadY), width: inW,
                           height: max(0, chartH - 2 * CGFloat(o.cardPadY)))
        let head = CGRect(x: inX, y: y + CGFloat(o.cardPadY), width: inW, height: CGFloat(o.chartHeadHeight))
        let riseNote = rising
            ? CGRect(x: inX, y: head.maxY + CGFloat(o.riseNoteTop), width: inW, height: CGFloat(o.riseNoteHeight))
            : .zero
        let plotTopY = head.maxY + noteH + plotTop
        let gutter = CGFloat(o.plotGutter)
        let plot = CGRect(x: inX + gutter, y: plotTopY, width: max(0, inW - gutter), height: plotH)
        y += chartH + CGFloat(o.gap)

        // The machine's two curves, side by side, half the width each.
        let miniH = CGFloat(o.cardPadY) + CGFloat(o.miniHeadHeight) + CGFloat(o.miniTop)
            + CGFloat(o.miniHeight) + CGFloat(o.cardPadY)
        let miniW = max(0, (w - CGFloat(o.miniGap)) / 2)
        let swap = CGRect(x: left, y: y, width: miniW, height: miniH)
        let disk = CGRect(x: left + miniW + CGFloat(o.miniGap), y: y, width: miniW, height: miniH)
        y += miniH + CGFloat(o.gap)

        // The table takes what is left of the page, and the page's own
        // height is everything above it plus what the rows need: the view
        // sets `tableH` from how many rows the core sent, through
        // `tableHeight(rows:)`.
        let tableTop = y
        return Layout(page: CGRect(x: 0, y: 0, width: max(0, width), height: 0),
                      kpis: kpis,
                      chart: chart,
                      chartInner: inner,
                      chartHead: head,
                      plot: plot,
                      plotGutter: CGRect(x: inX, y: plot.minY, width: gutter, height: plot.height),
                      plotXLabels: CGRect(x: plot.minX, y: plot.maxY + CGFloat(o.plotAxisGap),
                                          width: plot.width, height: CGFloat(o.plotLabelHeight)),
                      riseNote: riseNote,
                      minis: [swap, disk],
                      table: CGRect(x: left, y: tableTop, width: w, height: 0),
                      tableHead: CGRect(x: left, y: tableTop + CGFloat(o.tableTop), width: w,
                                        height: CGFloat(o.tableHeadHeight)),
                      contentHeight: tableTop)
    }

    /// How tall the table is with `rows` lines in it -- one per group and one
    /// per process -- plus its head and the room the bottom fades over.
    static func tableHeight(rows: Int) -> CGFloat {
        let o = Look.OverallPage.self
        return CGFloat(o.tableTop) + CGFloat(o.tableHeadHeight)
            + CGFloat(max(0, rows)) * CGFloat(o.tableRowHeight)
            + CGFloat(o.tableFade)
    }

    // MARK: - The row's words

    /// What the row says, in the person's language, and the two verdicts
    /// that colour it: everything else is drawing.
    struct Entry {
        /// The application's own name.
        var app: String
        /// "22.4 GB".
        var size: String
        /// Whether the swap is rising: the size is then in the warning ink.
        var rising: Bool
        /// "交换 18.6 GB · 磁盘剩 9.1 GB" -- or as much of it as could be
        /// read. Empty when neither could be.
        var machine: String
        /// Whether the free space is under its line: that part of the line
        /// is then in the bad ink.
        var diskLow: Bool
        /// Whether the disk reading is in the line at all, so that the ink
        /// and the words cannot disagree.
        var saysDisk: Bool
    }

    static func entry(_ a: Answer) -> Entry {
        let swap = a.machine.swapUsedMib.map(size)
        let disk = a.machine.diskFreeMib.map(size)
        // One sentence for the two, so that the separator between them and
        // the order they come in are the translator's to place: "交换 X ·
        // 磁盘剩 Y" is not "Swap X · Disk Y left" word for word.
        var line = ""
        if let swap, let disk {
            line = String(localized: "Swap \(swap) · Disk \(disk) left",
                          comment: "总控台：左栏底部那一行的第二行，交换区与磁盘剩余")
        } else if let swap {
            line = String(localized: "Swap \(swap)", comment: "总控台：左栏底部那一行，只有交换区")
        } else if let disk {
            line = String(localized: "Disk \(disk) left", comment: "总控台：左栏底部那一行，只有磁盘剩余")
        }
        return Entry(
            app: String(localized: "Polter", comment: "总控台：左栏底部那一行，应用自己的名字"),
            size: size(a.totalMib),
            rising: a.machine.swapRising,
            machine: line,
            diskLow: a.machine.diskLow,
            saysDisk: disk != nil)
    }

    /// MiB as the cards and the panel write a size: one decimal of a GB, or
    /// whole MB under one. The number and its unit together, because the
    /// unit is not a word either host translates.
    static func size(_ mib: UInt64) -> String {
        guard mib >= 1024 else { return "\(mib) MB" }
        let tenths = (mib * 10 + 512) / 1024
        return "\(tenths / 10).\(tenths % 10) GB"
    }

    /// A group's record, which the core counts in bytes (handoff §3). A
    /// tenth of a MB, because that is the size these come in and "4 MB"
    /// throws away what a reader compares.
    static func record(_ bytes: UInt64) -> String {
        let mib = Double(bytes) / 1_048_576
        if mib >= 1024 { return String(format: "%.1f GB", mib / 1024) }
        if mib >= 1 { return String(format: "%.1f MB", mib) }
        return String(format: "%.1f KB", Double(bytes) / 1024)
    }

    /// What an hour gained, with its sign: the core's own
    /// `slope_mib_per_h`, so that "↗ +1.3 GB an hour" and "→ +4 MB an hour"
    /// are one template and neither host writes a minus of its own.
    static func rate(_ slopeMibPerHour: Int) -> String {
        (slopeMibPerHour < 0 ? "\u{2212}" : "+") + size(UInt64(abs(slopeMibPerHour)))
    }

    /// After the size while the swap is rising, as the design draws it
    /// (`.pself .up`). **A mark and not a word**: there is nothing here for
    /// a translator to place, and no sentence of the core's says which of
    /// the two lines is the one that grew -- that is `rising`, beside it.
    static let risingMark = "↗"

    // MARK: - Where the row's parts go

    /// The row, and the four things in it, from the panel's top left.
    ///
    /// One place, so that the chip and the words inside it cannot be laid
    /// out from two readings -- the rule `ControlRoomPerfLayout` follows for
    /// the performance page.
    struct EntryLayout: Equatable {
        var chip: CGRect
        var line1: CGRect
        var line2: CGRect
        var curve: CGRect
        /// The mark at the chip's left edge while this row is the one in
        /// front; empty when it is not drawn at all.
        var rail: CGRect

        /// The row's own height, without the margin under it.
        static var height: CGFloat { CGFloat(Look.OverallEntry.height) }
    }

    /// The row in a panel `width` points wide -- `width` being the row's own
    /// width, exactly what `ControlRoomListLayout.overallEntry` hands it, so
    /// that the row's left edge and the rows' above it are one edge
    /// (`handoff §6`: that alignment is one of the things to measure). The
    /// row's origin is its own top left; nothing here adds the panel's
    /// padding, which is what put it here.
    static func entryLayout(width: CGFloat) -> EntryLayout {
        let e = Look.OverallEntry.self
        let chip = CGRect(x: 0, y: 0, width: max(0, width), height: CGFloat(e.height))
        let left = CGFloat(e.paddingX)
        let right = CGFloat(e.paddingRight)
        let curve = CGRect(x: max(left, chip.maxX - right - CGFloat(e.curveWidth)),
                           y: chip.minY + (chip.height - CGFloat(e.curveHeight)) / 2,
                           width: CGFloat(e.curveWidth), height: CGFloat(e.curveHeight))
        // The words stop `gap` short of the curve, and the curve is the
        // rightmost thing in the row: both from the same left edge the rows
        // above start at.
        let lineH = CGFloat(e.lineHeight)
        let twoH = 2 * lineH + CGFloat(e.lineGap)
        let top = chip.minY + (chip.height - twoH) / 2
        let wordsW = max(0, curve.minX - CGFloat(e.gap) - left)
        return EntryLayout(
            chip: chip,
            line1: CGRect(x: left, y: top, width: wordsW, height: lineH),
            line2: CGRect(x: left, y: top + lineH + CGFloat(e.lineGap), width: wordsW, height: lineH),
            curve: curve,
            rail: CGRect(x: chip.minX + CGFloat(e.railLeft), y: chip.minY + CGFloat(e.railInset),
                         width: CGFloat(e.railWidth), height: max(0, chip.height - 2 * CGFloat(e.railInset))))
    }

    /// The little curve in `rect`: the swap over the 24 hours the core sent,
    /// the same line the cards draw (`ControlRoomResources.curve`), on the
    /// axis the points themselves carry.
    ///
    /// **`now_s` is the right-hand edge**, the core's own clock, which is the
    /// same one the overall view's chart and its two curves end at: taken
    /// from the newest point instead, this row and the page it opens onto
    /// would end up to a sampling interval apart and nothing would say which
    /// was the machine's time. Zero -- an answer with no `series` -- falls
    /// back to the newest point, which is a reading of the same curve rather
    /// than none.
    static func curve(_ m: Machine, nowS: UInt64, rect: CGRect) -> (line: [CGPoint], killY: CGFloat?) {
        let span = UInt64(24 * 60 * 60)
        let at = nowS > 0 ? nowS : (m.swapHour.map(\.0).max() ?? 0)
        return ControlRoomResources.curve(m.swapHour, lineAt: nil, rect: rect, now: at, span: span)
    }

    /// The request this row's numbers come from: the same `overall` page the
    /// left panel's bottom line asks, about one group. **The same page and
    /// the same decoding**, so that the strip under the group page's grid
    /// and the overall view cannot come to mean two readings of one group.
    static func groupRequest(group: String) -> String {
        "{\"page\":\"overall\",\"group\":\(ControlRoomPageRequest.quoted(group))}"
    }

    /// The group the answer is about, if it is about one: the strip draws
    /// the first -- the core sends only the group asked for, and a page with
    /// no group in it draws no strip.
    static func group(_ a: Answer, named name: String) -> Group? {
        a.groups.first { $0.group == name }
    }

    // MARK: - The group page's strip

    /// Which ink one part of the strip is drawn in. **The core's verdict and
    /// nothing else**: whether the group is rising arrives as
    /// `own.growth.rising`, and nothing here weighs a slope
    /// (`tools/control-room-hosts-do-not-decide.py`).
    enum Tone: Equatable {
        case normal
        /// The warning ink: the part that is rising.
        case warn
    }

    /// **The group-itself card's ink** (handoff §6): the warning one while
    /// the core says the group's own part is rising, the usual one
    /// otherwise. One place, so that the card's ground, its tag and the
    /// fourth segment of the bar cannot be coloured by two readings.
    static func ownCardTone(_ o: Own) -> Tone { o.rising ? .warn : .normal }

    /// The four segments of the bar in a bar `width` points wide, left to
    /// right, in the order `Parts.inOrder` names them.
    ///
    /// **Each width is its part's share of the sum, and the four fill the
    /// bar exactly** (`handoff §6`: the widths are proportional to the MiB,
    /// to within a point). The sum is the four parts' own, not
    /// `total_mib`, so a bar whose pieces over- or under-fill it cannot be
    /// drawn.
    ///
    /// **Four empty rectangles when there is nothing to divide**, rather
    /// than one full bar: a group that costs nothing is not a group that
    /// costs everything, and the two are otherwise the same arithmetic.
    ///
    /// **The design's two-point gaps between segments are not drawn.** A
    /// gap takes a constant off every segment, so the drawn widths would no
    /// longer be the parts' shares -- and the shares are what the strip is
    /// for. The four abut and the bar's own corners round the ends.
    static func groupBar(_ p: Parts, width: CGFloat) -> [CGRect] {
        let total = p.sumMib
        let parts = p.inOrder
        guard total > 0, width > 0 else {
            return parts.map { _ in CGRect(x: 0, y: 0, width: 0, height: 0) }
        }
        var x: CGFloat = 0
        return parts.enumerated().map { i, mib in
            // The last segment ends at the bar's right edge exactly, so that
            // four roundings cannot leave a hairline of nothing at the end.
            let w = i == parts.count - 1 ? max(0, width - x) : width * CGFloat(mib) / CGFloat(total)
            let r = CGRect(x: x, y: 0, width: w, height: 0)
            x += w
            return r
        }
    }

    /// The same four widths, as fractions of the bar: what a reader compares
    /// is the shares, and a test can hold those without a width.
    static func groupBarShares(_ p: Parts) -> [Double] {
        let total = p.sumMib
        guard total > 0 else { return p.inOrder.map { _ in 0 } }
        return p.inOrder.map { Double($0) / Double(total) }
    }

    /// How high the group page's strip is, from the look's own numbers and
    /// **nothing measured**: the bar's box and the card are each built up
    /// out of their parts and the taller one is the row's.
    ///
    /// Computed rather than measured, because the terminal cards standing
    /// under this row must not move when a word in one of them gets longer.
    static var groupStripHeight: CGFloat {
        let g = Look.GroupStrip.self
        let left = CGFloat(g.padY) + CGFloat(g.headHeight) + CGFloat(g.barTop) + CGFloat(g.barHeight)
            + CGFloat(g.legendTop) + groupStripLegendHeight + CGFloat(g.padY)
        let card = CGFloat(g.padY) + max(CGFloat(g.headHeight), CGFloat(g.tagHeight))
            + CGFloat(g.cardLineGap) + CGFloat(g.cardValueHeight)
            + CGFloat(g.cardFootGap) + CGFloat(g.legendRow)
            + CGFloat(g.cardFootGap) + CGFloat(g.legendRow)
            + CGFloat(g.padY)
        return max(left, card)
    }

    /// The legend's own height: `legend_rows` lines and the gaps between
    /// them. The count is reserved rather than worked out from how many
    /// entries fit, for the reason above.
    static var groupStripLegendHeight: CGFloat {
        let g = Look.GroupStrip.self
        let rows = CGFloat(g.legendRows)
        return rows * CGFloat(g.legendRow) + max(0, rows - 1) * CGFloat(g.legendGapY)
    }
}
