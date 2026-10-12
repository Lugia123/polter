import CoreGraphics
import Foundation

/// The group list of the control room, as the host is handed it
/// (`dev-docs/poltergeist/control-room.md`, 3.2).
///
/// **Everything in here was decided somewhere else.** Which rows there are,
/// their order, which section each is in, which glyph it carries, the words
/// beside it and the two counts all come from the core's snapshot (5.4). The
/// host compares no kinds and counts no rows; it draws what it is given.
/// That is why the counts are fields and not `waiting.count`.
///
/// It is made from the core's snapshot by `init(snapshot:showing:)`, which
/// copies and tests equality and never works anything else out.
/// `ControlRoomList.sample` is the design's own example, for still pictures
/// and tests.
struct ControlRoomList: Equatable {
    /// What the core says to draw for a status: its `Attention.Shown`.
    enum Shown: String, Equatable, CaseIterable {
        case needsYou
        case trouble
        case doneUnseen
        case working
        case none
    }

    struct Row: Equatable, Identifiable {
        /// The group's name, which is its identity.
        var id: String
        var shown: Shown
        /// The words beside the glyph: which one of the four it is.
        var word: String
        /// What it is waiting on. Empty when there is nothing to say.
        var detail: String
        /// The detail is a command or a path, set in the terminal's face.
        var detailIsCode: Bool
        /// Whole minutes it has waited, as the core counted them; nil on a
        /// row that is not waiting for the person.
        var waitedMin: Int?
        /// How many other terminals of this group are also waiting.
        var others: Int
        /// This is the one glyph that pulses: the longest-waiting that is
        /// not already in front of the person. The core lists the
        /// candidates in order (`ControlRoomPulse`); which is first is an
        /// equality test.
        var pulses: Bool
        /// The core says nobody has looked at this since it stopped.
        var unseen: Bool = false
        /// What an action on this row hands back so the core can tell
        /// whether the row is still what was on screen: whose state it is
        /// and the two moments it was drawn from. Nil where there is no
        /// terminal behind the row.
        var target: Target?

        var name: String { id }
    }

    /// The terminal a row is about, and when. Both times are on the core's
    /// own clock and are only ever handed back, never compared here.
    struct Target: Equatable {
        var terminal: String
        var sinceMs: UInt64
        var eventMs: UInt64?
    }

    /// One stretch of the day in which a group kept the person waiting.
    struct Span: Equatable {
        var fromMs: UInt64
        var toMs: UInt64
        /// It is still waiting now.
        var ongoing: Bool
    }

    struct Lane: Equatable {
        var name: String
        var spans: [Span]
    }

    /// Today's waiting. **Wall-clock time**, unlike the rest of the list:
    /// its `nowMs` is its own and is the only "now" its spans are measured
    /// against.
    struct TimeBand: Equatable {
        var startMs: UInt64
        var nowMs: UInt64
        /// What the left end of the axis says, e.g. `09:00`.
        var startLabel: String
        /// Minutes the person was kept waiting today, all groups together.
        var totalMinutes: Int
        var lanes: [Lane]
    }

    /// "N groups are waiting for you". The core's number, not `waiting.count`.
    var waitingCount: Int
    var waiting: [Row]
    /// "N groups need nothing from you". Also the core's.
    var quietCount: Int
    var quiet: [Row]
    /// Nil when the snapshot carries none; the panel then has no band.
    var timeBand: TimeBand?

    /// Every row in the order it is listed, which is the order the up and
    /// down keys walk.
    var rows: [Row] { waiting + quiet }
}

// MARK: - What a row says

extension ControlRoomList {
    /// The "N more" at the end of a waiting row; nil when there are none.
    static func othersText(_ others: Int) -> String? {
        others > 0 ? String(localized: "\(String(others)) more", comment: "总控台：同一个群里还有几个终端也在等") : nil
    }

    /// What the pointer shows for a row whose detail may be cut short: the
    /// whole of it. Nil when there is nothing that could have been cut.
    static func tooltip(for row: Row) -> String? {
        row.detail.isEmpty ? nil : row.detail
    }

    /// The row the selection lands on after an arrow key. It stops at the
    /// ends, and with nothing selected a step lands on the first row going
    /// down and the last going up.
    static func move(_ selection: String?, by step: Int, in rows: [Row]) -> String? {
        guard !rows.isEmpty else { return nil }
        guard let selection, let at = rows.firstIndex(where: { $0.id == selection }) else {
            return step >= 0 ? rows.first?.id : rows.last?.id
        }
        return rows[min(max(at + step, 0), rows.count - 1)].id
    }
}

// MARK: - From the core's snapshot

/// The part of the core's control-room snapshot the group list draws
/// (`src/poltergeist/ControlRoom.zig` says the whole shape). Fields the list
/// does not show are not declared, so the core adding one breaks nothing.
struct ControlRoomSnapshot: Decodable, Equatable {
    struct Reason: Decodable, Equatable {
        var from: String
        var text: String
    }

    struct Attention: Decodable, Equatable {
        var since_ms: UInt64
        var terminal: String?
        var event_ms: UInt64?
    }

    /// One window tab and the one glyph it carries.
    struct Tab: Decodable, Equatable {
        var window: String?
        var tab: String
        var shown: ControlRoomList.Shown
    }

    /// A terminal waiting for the person. See `ControlRoomPulse`.
    struct Pulse: Decodable, Equatable {
        var terminal: String
        var window: String?
        var tab: String?
        var group: String?
    }

    struct Span: Decodable, Equatable {
        var from_ms: UInt64
        var to_ms: UInt64
        var ongoing: Bool
    }

    struct Lane: Decodable, Equatable {
        var name: String
        var spans: [Span]
    }

    struct Band: Decodable, Equatable {
        var start_ms: UInt64
        var start_label: String
        var now_ms: UInt64
        var total_min: Int
        var lanes: [Lane]
    }

    struct Group: Decodable, Equatable {
        var name: String
        /// The terminal that is this group's supervisor, as the core names
        /// it; nil when the group has none.
        var steward: String?
        var needs_me: Bool
        /// Absent in snapshots from before the core said it.
        var unseen: Bool?
        var attention: Attention?
        var shown: ControlRoomList.Shown
        /// The words beside the glyph, already in the person's language.
        var text: String
        var waited_min: Int?
        var reason: Reason
        var more: Int
        var same_as: String?
    }

    var rev: UInt64
    var groups_needing_me: Int
    var groups_other: Int
    /// The group to start on when the control room opens with nothing
    /// selected. The core's choice: which is first and which have an agent
    /// in them are both its to say.
    var open_on: String?
    /// Already in the order to draw them.
    var groups: [Group]
    /// The three below are newer than the rest; a snapshot without them
    /// draws no tab glyphs, breathes nothing and has no band.
    var tabs: [Tab]?
    var pulses: [Pulse]?
    var band: Band?
}

/// Which waiting glyph breathes.
///
/// The core lists every terminal waiting for the person, longest first.
/// **The one that breathes is the first of them the person is not already
/// looking at** -- the first not in the tab its window is showing. Finding
/// it is walking a list and testing equality; which waited longest was
/// decided when the list was ordered.
enum ControlRoomPulse {
    typealias Pulse = ControlRoomSnapshot.Pulse

    /// In a list of every group (the control room): the first not in
    /// `showing`, the tab that is in front.
    static func first(of pulses: [Pulse], notIn showing: String?) -> Pulse? {
        pulses.first { showing == nil || $0.tab != showing }
    }

    /// Among one window's tabs: the first in that window and not in the tab
    /// it is showing.
    static func first(of pulses: [Pulse], inWindow window: String, notIn showing: String?) -> Pulse? {
        pulses.first { $0.window == window && (showing == nil || $0.tab != showing) }
    }

    /// What one window tab carries: the glyph the core gives that tab, and
    /// whether it is the one that breathes among its window's tabs.
    struct TabStatus: Equatable {
        var shown: ControlRoomList.Shown
        var pulses: Bool

        static let none = TabStatus(shown: .none, pulses: false)
    }

    /// The status of `tab`, which is in `window`, whose tab in front is
    /// `showing` -- all three as the core spells them. A tab the snapshot
    /// does not list (the control room's own, or a terminal the core has
    /// not placed yet) carries nothing.
    static func status(ofTab tab: String, inWindow window: String, showing: String?,
                       in snapshot: ControlRoomSnapshot?) -> TabStatus {
        guard let snapshot, let entry = snapshot.tabs?.first(where: { $0.tab == tab }) else { return .none }
        let breathing = first(of: snapshot.pulses ?? [], inWindow: window, notIn: showing)
        return TabStatus(shown: entry.shown, pulses: breathing != nil && breathing?.tab == tab)
    }

    /// The id the core writes for a window or a tab: `0x` and sixteen hex
    /// digits.
    static func id(_ raw: UInt64) -> String {
        "0x" + String(repeating: "0", count: 16 - String(raw, radix: 16).count) + String(raw, radix: 16)
    }
}

extension ControlRoomList.Shown: Decodable {
    /// The core's spelling. A value this does not know is an error and not
    /// a blank: a glyph that silently went missing would look like a group
    /// with nothing to say.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "needs_you": self = .needsYou
        case "trouble": self = .trouble
        case "done_unseen": self = .doneUnseen
        case "working": self = .working
        case "none": self = .none
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "unknown `shown`: \(raw)"))
        }
    }
}

extension ControlRoomList {
    /// The list a snapshot describes. A copy: the rows keep the snapshot's
    /// order, each goes in the section its own `needs_me` says, and the two
    /// counts are the snapshot's. `showing` is the tab in front in the
    /// window that draws this list, which decides only which glyph breathes.
    init(snapshot: ControlRoomSnapshot, showing: String? = nil) {
        let breathing = ControlRoomPulse.first(of: snapshot.pulses ?? [], notIn: showing)?.group
        let rows = snapshot.groups.map { group in
            (group.needs_me, Row(
                id: group.name,
                shown: group.shown,
                word: group.text,
                detail: Self.detail(of: group),
                // A hook's note is a tool and what it was given.
                detailIsCode: group.same_as == nil && group.reason.from == "hook_note",
                waitedMin: group.waited_min,
                others: group.more,
                pulses: breathing != nil && breathing == group.name,
                unseen: group.unseen ?? false,
                target: group.attention.flatMap { attention in
                    attention.terminal.map {
                        Target(terminal: $0, sinceMs: attention.since_ms, eventMs: attention.event_ms)
                    }
                }))
        }
        self.init(
            waitingCount: snapshot.groups_needing_me,
            waiting: rows.filter { $0.0 }.map { $0.1 },
            quietCount: snapshot.groups_other,
            quiet: rows.filter { !$0.0 }.map { $0.1 },
            timeBand: snapshot.band.map { band in
                TimeBand(
                    startMs: band.start_ms, nowMs: band.now_ms, startLabel: band.start_label,
                    totalMinutes: band.total_min,
                    lanes: band.lanes.map { lane in
                        Lane(name: lane.name, spans: lane.spans.map {
                            Span(fromMs: $0.from_ms, toMs: $0.to_ms, ongoing: $0.ongoing)
                        })
                    })
            })
    }

    /// One supervisor minding several groups waits once: the reason is on
    /// one row, and the others point at it (`control-room.md`, 4.4).
    static func detail(of group: ControlRoomSnapshot.Group) -> String {
        if let other = group.same_as {
            return String(localized: "Same supervisor: see \(other)", comment: "总控台：一个总管管几个群时，其余几行指向带停因的那一行")
        }
        return group.reason.text
    }

    static func decode(snapshot json: Data, showing: String? = nil) throws -> ControlRoomList {
        ControlRoomList(snapshot: try JSONDecoder().decode(ControlRoomSnapshot.self, from: json), showing: showing)
    }
}

// MARK: - Where things are

/// Where everything in the list panel is, in the panel's own points with
/// the origin at its top left. Sizes come from `ControlRoomLook`; this adds
/// only the arithmetic, so that the view places things and never measures.
struct ControlRoomListLayout: Equatable {
    typealias Look = ControlRoomLook

    var size: CGSize
    var header: CGRect
    /// The waiting rows and then the quiet ones, keyed by `Row.id`.
    var rows: [String: CGRect]
    var separator: CGRect
    var quietHeader: CGRect
    var bandHeader: CGRect
    var lanes: [CGRect]
    var axis: CGRect

    init(list: ControlRoomList, height: CGFloat) {
        let pad = CGFloat(Look.Space.sidePanelPadding)
        let width = CGFloat(Look.Side.width)
        let inner = width - 2 * pad
        let padX = CGFloat(Look.Side.headerPaddingX)
        let headerH = CGFloat(Look.Side.headerHeight)
        let gap = CGFloat(Look.Side.rowGap)
        size = CGSize(width: width, height: height)

        var y = pad
        header = CGRect(x: pad, y: y, width: inner, height: headerH)
        y += headerH

        var frames: [String: CGRect] = [:]
        for row in list.waiting {
            frames[row.id] = CGRect(x: pad, y: y, width: inner, height: CGFloat(Look.Side.rowHeight))
            y += CGFloat(Look.Side.rowHeight) + gap
        }

        y += CGFloat(Look.Side.separatorSpaceAbove)
        separator = CGRect(x: pad + padX, y: y, width: inner - 2 * padX, height: CGFloat(Look.Line.hairline))
        y += CGFloat(Look.Line.hairline) + CGFloat(Look.Side.separatorSpaceBelow)

        quietHeader = CGRect(x: pad, y: y, width: inner, height: headerH)
        y += headerH
        for row in list.quiet {
            frames[row.id] = CGRect(x: pad, y: y, width: inner, height: CGFloat(Look.Side.quietRowHeight))
            y += CGFloat(Look.Side.quietRowHeight)
        }
        rows = frames

        // The time band hangs from the bottom: its own padding, the axis,
        // one lane per group, and its header on top.
        let laneH = CGFloat(Look.Side.timeLaneLabelledHeight)
        let axisH = CGFloat(Look.Side.timeAxisHeight)
        let bandX = pad + padX
        let bandW = inner - 2 * padX
        let count = CGFloat(list.timeBand?.lanes.count ?? 0)
        let axisTop = height - pad - CGFloat(Look.Side.timeBandPaddingBottom) - axisH
        axis = CGRect(x: bandX, y: axisTop, width: bandW, height: axisH)
        let lanesTop = axisTop - count * laneH
        lanes = (0..<Int(count)).map {
            CGRect(x: bandX, y: lanesTop + CGFloat($0) * laneH, width: bandW, height: laneH)
        }
        bandHeader = CGRect(x: bandX, y: lanesTop - headerH, width: bandW, height: headerH)
    }

    /// Where the selection chip rests for a row; nil for a row not listed.
    func chip(for id: String?) -> CGRect? {
        id.flatMap { rows[$0] }
    }

    /// How wide the part of a lane that draws time is, once the name at its
    /// left end and the gap after it are taken off.
    static func trackWidth(lane width: CGFloat) -> CGFloat {
        max(width - CGFloat(Look.Side.timeLaneLabelWidth) - CGFloat(Look.Side.rowItemGap), 0)
    }

    /// The pieces of one lane, as x and width inside a lane `width` wide.
    /// A span is clipped to the band, and one that ends before it starts or
    /// lies wholly outside is dropped.
    static func segments(_ lane: ControlRoomList.Lane, band: ControlRoomList.TimeBand,
                         width: CGFloat) -> [(x: CGFloat, width: CGFloat, ongoing: Bool)] {
        // The band's own now: it is on the wall clock and the rest of the
        // snapshot is not.
        let nowMs = band.nowMs
        guard nowMs > band.startMs, width > 0 else { return [] }
        let total = CGFloat(nowMs - band.startMs)
        return lane.spans.compactMap { span in
            let from = max(span.fromMs, band.startMs)
            let to = min(span.ongoing ? nowMs : span.toMs, nowMs)
            guard to > from else { return nil }
            let x = CGFloat(from - band.startMs) / total * width
            return (x, CGFloat(to - from) / total * width, span.ongoing)
        }
    }
}

// MARK: - How the chip moves

/// The chip's slide, as numbers: an under-damped spring from 0 to 1.
///
/// SwiftUI is handed the same period and damping and does the animating;
/// this is the same curve written out, so that "it overshoots by about 4%
/// and comes back" is something a test can read instead of something to
/// watch for.
enum ControlRoomChipSpring {
    /// Progress at `t` seconds: 0 at the start, settling on 1.
    static func progress(at t: Double,
                         period: Double = ControlRoomLook.Selection.springPeriod,
                         damping: Double = ControlRoomLook.Selection.springDamping) -> Double {
        guard t > 0, period > 0 else { return 0 }
        let omega = 2 * Double.pi / period
        guard damping < 1 else {
            // Critically damped: no overshoot.
            return 1 - (1 + omega * t) * exp(-omega * t)
        }
        let wd = omega * (1 - damping * damping).squareRoot()
        let decay = exp(-damping * omega * t)
        return 1 - decay * (cos(wd * t) + damping * omega / wd * sin(wd * t))
    }

    /// How far past 1 it goes at its furthest, as a fraction.
    static func overshoot(damping: Double = ControlRoomLook.Selection.springDamping) -> Double {
        guard damping < 1 else { return 0 }
        return exp(-damping * Double.pi / (1 - damping * damping).squareRoot())
    }
}

// MARK: - Made-up data

extension ControlRoomList {
    /// The design's own example, with the parts the snapshot does not carry
    /// yet. For still pictures and tests; nothing reads it in a running app.
    static let sample: ControlRoomList = {
        let minute: UInt64 = 60_000
        let start: UInt64 = 9 * 60 * minute
        let now: UInt64 = start + 400 * minute
        func span(_ from: Double, _ width: Double, ongoing: Bool = false) -> Span {
            let total = Double(now - start)
            return Span(fromMs: start + UInt64(from / 100 * total),
                        toMs: start + UInt64((from + width) / 100 * total), ongoing: ongoing)
        }
        return ControlRoomList(
            waitingCount: 3,
            waiting: [
                Row(id: "web-app", shown: .needsYou, word: "等批准", detail: "rm -rf dist/ && npm run build",
                    detailIsCode: true, waitedMin: 4, others: 1, pulses: false),
                Row(id: "billing", shown: .needsYou, word: "等回答", detail: "「发票编号要按租户分开吗？」",
                    detailIsCode: false, waitedMin: 11, others: 0, pulses: true),
                Row(id: "docs-site", shown: .trouble, word: "出错", detail: "限流，13:40 重置",
                    detailIsCode: false, waitedMin: 2, others: 0, pulses: false),
            ],
            quietCount: 2,
            quiet: [
                Row(id: "infra", shown: .doneUnseen, word: "做完了，没看", detail: "",
                    detailIsCode: false, waitedMin: nil, others: 0, pulses: false),
                Row(id: "design-system", shown: .working, word: "在干活", detail: "",
                    detailIsCode: false, waitedMin: nil, others: 0, pulses: false),
            ],
            timeBand: TimeBand(
                startMs: start, nowMs: now, startLabel: "09:00", totalMinutes: 47,
                lanes: [
                    Lane(name: "web-app", spans: [span(44, 5), span(93, 7, ongoing: true)]),
                    Lane(name: "billing", spans: [span(14, 8), span(62, 4), span(81, 19, ongoing: true)]),
                    Lane(name: "docs-site", spans: [span(27, 6), span(96.5, 3.5, ongoing: true)]),
                ]))
    }()
}
