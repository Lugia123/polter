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
        /// The group's name, which is its identity -- or, for a terminal
        /// that is in no group, `rowId(ofTerminal:)`, which no group can be
        /// named.
        var id: String
        var shown: Shown
        /// The words beside the glyph: which one of the four it is.
        var word: String
        /// Who the row is about: the group's supervisor, or one of its
        /// workers by name. The core's word; nothing here works it out.
        var waiter: Waiter
        /// What it is waiting for -- or, on a row that needs nothing, what
        /// it is doing -- in the pieces it is drawn in. The core says
        /// whether it is a command or words, and where a command's steps
        /// are.
        var what: What
        /// How many other terminals of this group are also waiting.
        var others: Int
        /// This is the one glyph that pulses: the longest-waiting that is
        /// not already in front of the person. The core lists the
        /// candidates in order (`ControlRoomPulse`); which is first is an
        /// equality test.
        var pulses: Bool
        /// The core says nobody has looked at this since it stopped.
        var unseen: Bool = false
        /// What the title of the supervisor's frame says, when the core
        /// names a supervisor for this group (`SupervisorTitle`).
        var supervisor: SupervisorTitle?
        /// What an action on this row hands back so the core can tell
        /// whether the row is still what was on screen: whose state it is
        /// and the two moments it was drawn from. Nil where there is no
        /// terminal behind the row.
        var target: Target?
        /// Whether this group has a supervisor and what starting one would
        /// use, as the core says it. Nil in a list made by hand.
        var start: SupervisorStart?
        /// Set on a row that is a terminal on its own, in no group
        /// (`ungrouped` in the snapshot): which terminal, and its title.
        var alone: Alone?
        /// The "Fix" button on a card that reads "Failed" (task 1560): the
        /// core's word, from the snapshot's `fix`.
        var fix: Fix = .none

        /// What the row is called: the group's name, or the terminal's
        /// title.
        var name: String { alone?.title ?? id }
    }

    /// The "Fix" button (`ControlFix.zig`): not there, there, or pressed
    /// and greyed until the card changes. Which is the core's to say.
    enum Fix: String, Equatable, Decodable {
        case none, offered, sent
    }

    /// A terminal that is in no group and has a row of its own: a
    /// supervisor that has made no group yet, a worker minded outside any
    /// group, an agent nobody minds. The core lists them; which they are is
    /// not asked here.
    struct Alone: Equatable {
        var terminal: String
        var title: String
        /// Which frame its own pane wears, as the core says it for that
        /// terminal; plain when the core does not list it.
        var pane: ControlRoomSnapshot.Terminal.Pane
    }

    /// What the bar over the right-hand side says: a title (name, the word
    /// "Supervisor", status) while it holds a group's supervisor, and
    /// otherwise one name and nothing more.
    ///
    /// A terminal with a row of its own has a title like any other; what
    /// follows its name is that terminal's own word -- "Worker", or nothing
    /// for an ordinary agent -- because its title says so (`says`), not
    /// because anything here looked at what it is.
    static func detailBar(row: Row?, selection: String?, holdsTerminal: Bool,
                          title: SupervisorTitle?) -> (title: SupervisorTitle?, caption: String?) {
        guard holdsTerminal else { return (nil, row?.name ?? selection) }
        return (title, nil)
    }

    /// The identity of a lone terminal's row. A group's name is letters,
    /// digits and hyphens, so nothing with a colon in it is one.
    static func rowId(ofTerminal terminal: String) -> String {
        "terminal:" + terminal
    }

    /// What the core says about a group's supervisor (`ControlRoom.zig`,
    /// `SupervisorOut`). **Whether one can be started is `canStart`, the
    /// core's word**: a host shows the button on that and works nothing
    /// out from `state`, which only picks the sentence.
    struct SupervisorStart: Equatable {
        enum State: String, Equatable, Decodable {
            case present, absent, starting, failed
        }

        /// Why the last try made no supervisor.
        enum Failure: String, Equatable, Decodable, CaseIterable {
            case none
            case terminalNeverOpened = "terminal_never_opened"
            case agentNeverConnected = "agent_never_connected"
            case terminalClosed = "terminal_closed"
            /// `+launch` said so itself, at once: the CLI's program is not
            /// there to run.
            case cliNotFound = "cli_not_found"
            /// `+launch` said so itself: something else stopped it before
            /// the CLI ran.
            case cliDidNotStart = "cli_did_not_start"
        }

        /// Why a start does not go on with the last supervisor's session,
        /// or `none` when it does (`ControlRoom.zig`, `ResumeOut.Why`).
        enum ResumeWhy: String, Equatable, Decodable, CaseIterable {
            case none
            case noRecord = "no_record"
            case noSession = "no_session"
            case lastTryFailed = "last_try_failed"
            case cliDiffers = "cli_differs"
            case clisUnread = "clis_unread"
            case cliCannotResume = "cli_cannot_resume"
            case sessionInUse = "session_in_use"
        }

        /// What the core says of the supervisor a group last had, and
        /// whether a start goes on with its session. What the right-hand
        /// side makes of it is `ControlRoomStartChoice`.
        struct Last: Equatable {
            /// The CLI the default role is started in.
            var cli: String?
            /// The role and the CLI the last supervisor was, and when it
            /// was last heard from (the real clock). Each nil when nobody
            /// wrote it down.
            var role: String?
            var lastCli: String?
            var heardMs: Int64?
            /// Whether a start goes on with its session: a host offers
            /// that on this and on nothing else, and says `why` when not.
            var canResume: Bool
            var why: ResumeWhy
            /// The directory the core names for the start (`cwd`) is where
            /// that supervisor last worked (`cwd_from: last_supervisor`),
            /// and not somewhere worked out another way.
            var cwdIsTheLastSupervisors: Bool = false
            /// What the two CLIs are called to a person, as the core says
            /// (`cli_label`): the one a start uses, and the one the last
            /// supervisor was. Nil when the core has no name for it, and
            /// then the key is what is written.
            var cliLabel: String?
            var lastCliLabel: String?
        }

        var state: State
        var canStart: Bool
        var failed: Failure
        /// The role it is started in unless the person picks another.
        var role: String?
        /// Where it is started unless the person picks elsewhere.
        var cwd: String
        /// Nil for a snapshot from before the core said it.
        var last: Last?
    }

    /// A role a supervisor can be started in.
    struct SupervisorRole: Equatable, Identifiable {
        var key: String
        var name: String
        var id: String { key }

        /// The name to show: the name, as the role library shows it. An
        /// official role is English as shipped.
        var displayName: String { name }
    }

    /// Who a row is about, as the core says it (`ControlRoom.zig`,
    /// `Waiter`). A host turns `is` into words and never into a decision.
    struct Waiter: Equatable {
        enum Is: String, Equatable, Decodable {
            case none
            case supervisor
            case workerViaSupervisor = "worker_via_supervisor"
            case worker
            case terminal
        }

        var `is`: Is
        /// The worker's name when it is a worker; empty otherwise.
        var name: String

        static let none = Waiter(is: .none, name: "")
    }

    /// What a row says under its name (`ControlRoom.zig`, `What`): all of
    /// it, already cut into the lines it is drawn on.
    struct What: Equatable {
        enum Form: String, Equatable, Decodable {
            case none
            /// A shell command: one step to a line, in the terminal's face.
            case command
            /// Something literal in one piece, in the terminal's face.
            case code
            /// A sentence.
            case words
        }

        /// Whether `lines` is all of it (`ControlRoom.zig`, `What.Cut`).
        enum Cut: String, Equatable, Decodable {
            /// Everything that was said.
            case none
            /// The start of something longer, or it may be.
            case tail
            /// The end of something longer.
            case head
        }

        /// The core's word for whether this is all of it. Never left out:
        /// a part shown as the whole is the thing this exists to stop.
        var cut: Cut
        var form: Form
        var lines: [String]

        static let none = What(cut: .none, form: .none, lines: [])

        /// The mark that stands where the rest would be.
        static let ellipsis = "…"

        /// The lines as a row sets them: the core's, with the mark before
        /// the first when what came before is missing and after the last
        /// when what came after is. Everything that draws, measures or
        /// reads out a row uses these, so a part is marked wherever it
        /// appears.
        var drawn: [String] {
            guard !lines.isEmpty else { return lines }
            var out = lines
            switch cut {
            case .none: break
            case .head: out[out.startIndex] = Self.ellipsis + " " + out[out.startIndex]
            case .tail: out[out.endIndex - 1] += " " + Self.ellipsis
            }
            return out
        }

        /// Set in the terminal's face.
        var isCode: Bool { form == .command || form == .code }
        /// Everything it says, for a tooltip and for VoiceOver.
        var whole: String { drawn.joined(separator: "\n") }
    }

    /// The title bar of a supervisor's frame on the right-hand side
    /// (`control-room.md`, 3.5, item 6): its name on the left, and on the
    /// right its status -- the glyph and the word.
    ///
    /// Everything in it is the core's. The name is the terminal's title as
    /// the snapshot lists it among the group's members, and the status is
    /// that member's own glyph and word -- the supervisor's, whether the
    /// group's row is about it or about one of its workers. Nothing is
    /// counted or compared to get any of it, and nothing in it says how
    /// long.
    struct SupervisorTitle: Equatable {
        var name: String
        var shown: Shown
        var word: String
        /// Whose word follows the name on the bar, when it is not the
        /// frame's own: the control room has one frame -- a supervisor's --
        /// and shows in it a terminal that may be a worker or neither. Nil
        /// for "what the frame is", which is every title but those.
        var says: ControlRoomSnapshot.Terminal.Pane?
    }

    /// The terminal a row is about, and when. Both times are on the core's
    /// own clock and are only ever handed back, never compared here.
    struct Target: Equatable {
        var terminal: String
        var sinceMs: UInt64
        var eventMs: UInt64?
    }

    /// How many rows are under the first heading. The core's number, not
    /// `waiting.count`: the rows of groups, and of lone terminals when
    /// they are listed.
    var waitingCount: Int
    var waiting: [Row]
    /// How many rows are under the second heading. Also the core's.
    var quietCount: Int
    var quiet: [Row]
    /// What each heading says, as the core put it (`ControlRoom.zig`,
    /// `HeaderOut`); nil in a list made by hand or from an older snapshot,
    /// and then the heading is written from the count alone, as it was.
    var waitingHeader: Header?
    var quietHeader: Header?

    /// A heading: how many rows, whether every one is a group, and which
    /// grammatical number that is. **All three are the core's.** A host
    /// picks a sentence by `of` and `number` and puts `count` in it; it
    /// does not add the groups to the lone terminals, and it does not
    /// compare the count with one to find the singular.
    struct Header: Equatable, Decodable {
        enum Of: String, Equatable, Decodable { case groups, rows }
        enum Number: String, Equatable, Decodable { case none, one, other }

        var count: Int
        var of: Of
        var number: Number
    }
    /// The allowance block at the bottom, as the core says it; nil when
    /// the snapshot has none, and then nothing is drawn there.
    var quota: ControlRoomQuota?
    /// The roles a supervisor can be started in, in the core's order.
    var supervisorRoles: [SupervisorRole] = []
    /// Whether there is a choice of role to offer. The core's word, not
    /// `supervisorRoles.count`.
    var chooseSupervisorRole: Bool = false
    /// The first sweep of old records is waiting for the person, and would
    /// delete this much (task 1511); nil when nothing waits. Said once, as
    /// a note under the header with an OK.
    var retentionWaitingBytes: UInt64?

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

    /// Who is waiting, as the row writes it at its right: "Supervisor", or
    /// the worker's name and that the person reaches it through the
    /// supervisor. Which of them is the core's word (`waiter.is`); this
    /// only puts it in the person's language. Nil when there is nothing to
    /// say: a row nobody waits on, or a terminal in no group.
    static func waiterText(_ waiter: Waiter) -> String? {
        switch waiter.is {
        case .supervisor:
            return String(localized: "Supervisor", comment: "总控台：在等的是这个群的总管自己")
        case .workerViaSupervisor:
            return String(localized: "\(waiter.name), via the supervisor", comment: "总控台：在等的是总管手下的一个 worker，%@ 是它的名字")
        case .worker:
            return waiter.name
        case .none, .terminal:
            return nil
        }
    }

    /// The list's header: how many groups are waiting, by the core's
    /// count, or that none is.
    static func headerText(waiting: Int) -> String {
        waiting == 0
            ? String(localized: "No group is waiting for you", comment: "总控台：左栏标题，没有群在等的时候")
            : String(localized: "\(String(waiting)) groups waiting for you", comment: "总控台：左栏标题，N 是核心给的数")
    }

    /// The first heading as the core says it: so many waiting, called
    /// groups only when every one of them is a group, and "1 group" where
    /// the core says the number is one.
    static func headerText(_ header: Header) -> String {
        let n = String(header.count)
        switch (header.number, header.of) {
        case (.none, _):
            return String(localized: "No group is waiting for you", comment: "总控台：左栏标题，没有群在等的时候")
        case (.one, .groups):
            return String(localized: "\(n) group waiting for you", comment: "总控台：左栏标题，正好一个群在等（英文单数）")
        case (.other, .groups):
            return String(localized: "\(n) groups waiting for you", comment: "总控台：左栏标题，N 是核心给的数")
        case (.one, .rows), (.other, .rows):
            return String(localized: "\(n) waiting for you", comment: "总控台：左栏标题，在等的里有不在任何群里的终端，所以不说「群」")
        }
    }

    /// The second heading, by the same rule.
    static func quietHeaderText(_ header: Header) -> String {
        let n = String(header.count)
        switch (header.number, header.of) {
        case (.one, .groups):
            return String(localized: "\(n) group needs nothing from you", comment: "总控台：左栏第二段的标题，正好一个群（英文单数）")
        case (.none, .groups), (.other, .groups):
            return String(localized: "\(n) groups need nothing from you", comment: "总控台：左栏第二段的标题")
        case (.one, .rows):
            return String(localized: "\(n) needs nothing from you", comment: "总控台：左栏第二段的标题，正好一行、而且不是群（英文单数）")
        case (.none, .rows), (.other, .rows):
            return String(localized: "\(n) need nothing from you", comment: "总控台：左栏第二段的标题，里面有不在任何群里的终端，所以不说「群」")
        }
    }

    /// The heading of a list: the core's when it gave one, otherwise the
    /// count of groups, written as it always was.
    var waitingHeaderText: String {
        waitingHeader.map(Self.headerText) ?? Self.headerText(waiting: waitingCount)
    }

    var quietHeaderText: String {
        quietHeader.map(Self.quietHeaderText)
            ?? String(localized: "\(String(quietCount)) groups need nothing from you", comment: "总控台：左栏第二段的标题")
    }

    /// The line that stands for the steps of a command that are not shown;
    /// nil when every step is.
    static func hiddenStepsText(_ hidden: Int) -> String? {
        hidden > 0 ? String(localized: "\(String(hidden)) more steps", comment: "总控台：命令太长，后面还有几步没显示") : nil
    }

    /// What a row that needs nothing says after its name: what the group
    /// is doing when the core knows, the status word when it does not, and
    /// nothing for a group with neither.
    static func quietText(_ row: Row) -> String {
        row.what.lines.isEmpty ? row.word : row.what.drawn.joined(separator: " ")
    }

    /// What a row says when it is read out rather than looked at: which
    /// group, who is waiting, which of the four it is, and what it waits
    /// on -- every step, whole, whatever the row had room to draw -- then
    /// how many others.
    static func spoken(_ row: Row) -> String {
        var parts = [row.name]
        if let who = waiterText(row.waiter) { parts.append(who) }
        if !row.word.isEmpty { parts.append(row.word) }
        parts.append(contentsOf: row.what.drawn.filter { !$0.isEmpty })
        if let others = othersText(row.others) { parts.append(others) }
        return parts.joined(separator: ", ")
    }

    /// What the pointer shows for a row whose lines may be cut short: the
    /// whole of it. Nil when there is nothing that could have been cut.
    static func tooltip(for row: Row) -> String? {
        row.what.lines.isEmpty ? nil : row.what.whole
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

    struct Waiter: Decodable, Equatable {
        var `is`: ControlRoomList.Waiter.Is
        var name: String
    }

    struct What: Decodable, Equatable {
        var cut: ControlRoomList.What.Cut
        var form: ControlRoomList.What.Form
        var lines: [String]
        /// Set when `lines` is one of the core's own sentences (task 1525):
        /// `lines` holds it in English; `ControlRoomList.lines(of:)` says it
        /// in the person's language. Absent from a core before it said so.
        var say: Say?

        /// The English msgid with `{1}`, `{2}` where `args` go. The
        /// arguments are as they go in -- minutes in decimal, an agent's
        /// own words -- and none is translated.
        struct Say: Decodable, Equatable {
            var key: String
            var template: String
            var args: [String]
        }
    }

    /// One terminal of a group, as much of it as a title bar shows.
    struct Member: Decodable, Equatable {
        var id: String
        var title: String
        var shown: ControlRoomList.Shown
        var text: String
    }

    /// One open terminal, as much of it as its pane's frame shows
    /// (`PaneFrame`).
    struct Terminal: Decodable, Equatable {
        /// Which of the three frames its pane wears, as the core spells
        /// them. A value this does not know is an error, as with `shown`.
        enum Pane: String, Decodable, Equatable, CaseIterable {
            /// A border all round, its top edge thickened into the title bar.
            case supervisor
            /// A line all round and a band for the title.
            case worker
            /// No line and no band: the title on the terminal's own ground.
            case plain
        }

        var id: String
        var title: String
        var shown: ControlRoomList.Shown
        var text: String
        /// Absent in a snapshot from before the core said it; such a
        /// terminal is drawn as an ordinary one.
        var pane: Pane?

        /// What the right end of its pane's title draws: the glyph and the
        /// words, as the core worked them out (`ControlRoom.zig`, `Bar`).
        /// **A host draws this pair and makes none of its own** out of
        /// `shown`, `text` and whether the terminal is held: which of them
        /// wins is the core's rule.
        struct Bar: Decodable, Equatable {
            /// The five a row draws, and `held`, which only a title does. A
            /// value this does not know is an error, as with `shown`.
            enum Shown: String, Decodable, Equatable, CaseIterable {
                case needsYou = "needs_you"
                case trouble
                case doneUnseen = "done_unseen"
                case working
                case none
                case held

                /// The same glyph, for a status that is not a pane's.
                init(_ status: ControlRoomList.Shown) {
                    switch status {
                    case .needsYou: self = .needsYou
                    case .trouble: self = .trouble
                    case .doneUnseen: self = .doneUnseen
                    case .working: self = .working
                    case .none: self = .none
                    }
                }

                /// The status glyph this is; nil for `held`, which is not
                /// one of the four.
                var status: ControlRoomList.Shown? {
                    switch self {
                    case .needsYou: return .needsYou
                    case .trouble: return .trouble
                    case .doneUnseen: return .doneUnseen
                    case .working: return .working
                    case .none: return ControlRoomList.Shown.none
                    case .held: return nil
                    }
                }
            }

            var shown: Shown
            var text: String
        }

        /// Absent in a snapshot from before the core said it; the title
        /// then says the terminal's status, as it did before.
        var bar: Bar?

        /// Who is working in it (`ControlRoom.zig`, `WhoOut`): what a
        /// project's pane keeps. `role`, `cli` and `session` are the
        /// core's words as it wrote them -- for an agent an empty string
        /// is that part not known, and for the other two all three are
        /// nil. Read and carried; nothing here draws it.
        struct Who: Decodable, Equatable {
            /// `unknown` is not `none`: the core could not tell, which is
            /// not nobody. A value this does not know is an error.
            enum Is: String, Decodable, Equatable, CaseIterable {
                case unknown, none, agent
            }

            /// Which of the three: the snapshot's `who.is`.
            var `is`: Is
            var role: String?
            var cli: String?
            var session: String?
            /// The supervisor this one was opened for as a worker, in this
            /// run.
            var worker_of: String?
        }

        /// Absent in a snapshot from before the core said it.
        var who: Who?
    }

    /// See `ControlRoomList.SupervisorStart`.
    struct Supervisor: Decodable, Equatable {
        var state: ControlRoomList.SupervisorStart.State
        var can_start: Bool
        var failed: ControlRoomList.SupervisorStart.Failure
        var role: String?
        var cwd: String
        /// The three the core added together; absent together in a
        /// snapshot from before it did.
        var cli: String?
        var last: Last?
        var resume: Resume?
        /// How the core arrived at `cwd`. Kept as the word it wrote: the
        /// one value asked about is `last_supervisor`.
        var cwd_from: String?
        /// What `cli` is called to a person; nil when the core has no
        /// name for it, or is from before it said.
        var cli_label: String?

        struct Last: Decodable, Equatable {
            var role: String?
            var cli: String?
            var cli_label: String?
            var heard_ms: Int64?
        }

        struct Resume: Decodable, Equatable {
            var can: Bool
            var why: ControlRoomList.SupervisorStart.ResumeWhy
        }

        var startLast: ControlRoomList.SupervisorStart.Last? {
            guard let last, let resume else { return nil }
            return .init(cli: cli, role: last.role, lastCli: last.cli, heardMs: last.heard_ms,
                         canResume: resume.can, why: resume.why,
                         cwdIsTheLastSupervisors: cwd_from == "last_supervisor",
                         cliLabel: cli_label, lastCliLabel: last.cli_label)
        }
    }

    struct SupervisorRole: Decodable, Equatable {
        var key: String
        var name: String
    }

    struct Group: Decodable, Equatable {
        var name: String
        /// Absent in snapshots from before the core said it.
        var supervisor: Supervisor?
        /// The group's terminals. Absent in a snapshot cut down by hand.
        var members: [Member]?
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
        /// Absent in a snapshot cut down by hand: then nobody is named and
        /// nothing is said.
        var waiter: Waiter
        var what: What
        var reason: Reason
        var more: Int
        var same_as: String?
        /// Absent in snapshots from before task 1560: no button.
        var fix: ControlRoomList.Fix?
    }

    /// A terminal in no group, with a row of its own (`ControlRoom.zig`,
    /// `LoneRow`): the same things a group's row says, about one terminal.
    struct Lone: Decodable, Equatable {
        var id: String
        var title: String
        var needs_me: Bool
        var unseen: Bool?
        var attention: Attention?
        var shown: ControlRoomList.Shown
        var text: String
        var waiter: Waiter
        var what: What
        /// Absent in snapshots from before task 1560: no button.
        var fix: ControlRoomList.Fix?
    }

    var rev: UInt64
    /// "N waiting for you": terminals, each once. The number on the Dock
    /// icon. Absent in a snapshot cut down by hand.
    var needs_me: Int?
    var groups_needing_me: Int
    var groups_other: Int
    /// What the list's two headings say. Absent in snapshots from before
    /// the core said it: then the headings count groups.
    var header_waiting: ControlRoomList.Header?
    var header_quiet: ControlRoomList.Header?
    /// The group to start on when the control room opens with nothing
    /// selected. The core's choice: which is first and which have an agent
    /// in them are both its to say.
    var open_on: String?
    /// Already in the order to draw them.
    var groups: [Group]
    /// Terminals in no group. **Read and not drawn**: they have no row in
    /// the list (`ControlRoomList.init(snapshot:showing:loneRows:)`), and
    /// the core counts them in nothing the person is shown (task 1485).
    /// Absent in a snapshot cut down by hand.
    var ungrouped: [Lone]?
    /// The three below are newer than the rest; a snapshot without them
    /// draws no tab glyphs, breathes nothing and has no band.
    var tabs: [Tab]?
    var pulses: [Pulse]?
    /// How much of each account's allowance is used. Newer than the rest:
    /// a snapshot without it draws no block. One with a word in it this
    /// does not know is not read at all.
    var quota: ControlRoomQuota?
    /// Every open terminal, for the frame its pane wears (`PaneFrame`).
    var terminals: [Terminal]?
    /// Absent in snapshots from before a supervisor could be started here:
    /// then there is no role to start one in and nothing is offered.
    var supervisor_roles: [SupervisorRole]?
    var choose_supervisor_role: Bool?
    /// Absent before task 1511, and then nothing waits.
    var retention_waiting_bytes: UInt64?
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
    /// A word beside a glyph -- "Awaiting approval", "Working", "Held" -- in
    /// the person's language (task 1522). The core writes it as an English
    /// msgid, because it does not know the person's language; it was a
    /// Chinese literal before, and so Chinese in an English window. Said
    /// here, where a snapshot's words become a row's or a title's, so that
    /// nothing downstream measures one set of words and draws another.
    /// `tools/control-room-words-are-translated.py` checks each word has an
    /// entry in both `Localizable.strings`.
    static func say(_ word: String, in bundle: Bundle = .main) -> String {
        word.isEmpty ? word : bundle.localizedString(forKey: word, value: word, table: nil)
    }

    /// A row's line, where it is one of the core's own sentences, in the
    /// person's language (task 1525); anything else as the core sent it.
    static func lines(of what: ControlRoomSnapshot.What, in bundle: Bundle = .main) -> [String] {
        guard let s = what.say else { return what.lines }
        return [fill(bundle.localizedString(forKey: s.template, value: s.template, table: nil), s.args)]
    }

    /// `template` with `{1}`..`{9}` replaced by `args`; a placeholder with no
    /// argument is left as written. The same few lines as the core's
    /// `Say.fill` and Windows' `snapshot::fill` -- not `String(format:)`,
    /// which dies on a translation whose placeholders do not match.
    static func fill(_ template: String, _ args: [String]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            let digit = rest.index(after: open)
            let close = digit < rest.endIndex ? rest.index(after: digit) : rest.endIndex
            if close < rest.endIndex, rest[close] == "}",
               let n = rest[digit].wholeNumberValue, (1...9).contains(n), n <= args.count {
                out += rest[..<open]
                out += args[n - 1]
                rest = rest[rest.index(after: close)...]
            } else {
                out += rest[...open]
                rest = rest[digit...]
            }
        }
        return out + rest
    }
}

extension ControlRoomList {
    /// What the title of `group`'s supervisor frame says; nil when the core
    /// names no supervisor, or lists no such member.
    static func supervisorTitle(of group: ControlRoomSnapshot.Group) -> SupervisorTitle? {
        guard let steward = group.steward,
              let member = group.members?.first(where: { $0.id == steward }) else { return nil }
        // Always the supervisor's own member, as the core wrote it. Whether
        // the row is about the supervisor or about one of its workers is
        // not asked here: the core says who waits (`waiter`), and the
        // member's glyph and word are the supervisor's either way.
        return SupervisorTitle(name: member.title, shown: member.shown, word: say(member.text))
    }
}

extension ControlRoomList {
    /// The list a snapshot describes. A copy: the rows keep the snapshot's
    /// order, each goes in the section its own `needs_me` says, and the two
    /// counts are the snapshot's. `showing` is the tab in front in the
    /// window that draws this list, which decides only which glyph breathes.
    ///
    /// **The terminals in no group (`ungrouped`) get no row.** They had one
    /// each, after the groups'; the rows read as groups nobody had made,
    /// and the user had them taken out (2026-10-13, task 1485). The core
    /// counts them in neither heading nor in `needs_me`, so what is drawn
    /// is still what every number says. `loneRows` true is the list as it
    /// was: nothing in the app asks for it, and it is kept so that what
    /// such a row says stays under test for the day they are drawn
    /// somewhere of their own.
    init(snapshot: ControlRoomSnapshot, showing: String? = nil, loneRows: Bool = false) {
        let first = ControlRoomPulse.first(of: snapshot.pulses ?? [], notIn: showing)
        let breathing = first?.group
        // Which frame a terminal's own pane wears, as the core says it for
        // that terminal; plain for one it does not list.
        func pane(of terminal: String) -> ControlRoomSnapshot.Terminal.Pane {
            snapshot.terminals?.first { $0.id == terminal }?.pane ?? .plain
        }
        // A terminal on its own, after the groups, in the section its own
        // `needs_me` says -- the same test a group's row is put by.
        let lone = (loneRows ? snapshot.ungrouped ?? [] : []).map { one in
            (one.needs_me, Row(
                id: Self.rowId(ofTerminal: one.id),
                shown: one.shown,
                word: Self.say(one.text),
                waiter: Waiter(is: one.waiter.is, name: one.waiter.name),
                what: What(cut: one.what.cut, form: one.what.form, lines: Self.lines(of: one.what)),
                others: 0,
                // The one that breathes is the first the core lists; it is
                // this row when that one is in no group and is this terminal.
                pulses: first != nil && first?.group == nil && first?.terminal == one.id,
                unseen: one.unseen ?? false,
                supervisor: SupervisorTitle(name: one.title, shown: one.shown, word: Self.say(one.text), says: pane(of: one.id)),
                target: one.attention.flatMap { attention in
                    attention.terminal.map {
                        Target(terminal: $0, sinceMs: attention.since_ms, eventMs: attention.event_ms)
                    }
                },
                start: nil,
                alone: Alone(terminal: one.id, title: one.title, pane: pane(of: one.id)),
                fix: one.fix ?? .none))
        }
        let groups = snapshot.groups.map { group in
            (group.needs_me, Row(
                id: group.name,
                shown: group.shown,
                word: Self.say(group.text),
                waiter: Waiter(is: group.waiter.is, name: group.waiter.name),
                what: What(cut: group.what.cut, form: group.what.form, lines: Self.lines(of: group.what)),
                others: group.more,
                pulses: breathing != nil && breathing == group.name,
                unseen: group.unseen ?? false,
                supervisor: Self.supervisorTitle(of: group),
                target: group.attention.flatMap { attention in
                    attention.terminal.map {
                        Target(terminal: $0, sinceMs: attention.since_ms, eventMs: attention.event_ms)
                    }
                },
                start: group.supervisor.map {
                    SupervisorStart(state: $0.state, canStart: $0.can_start, failed: $0.failed,
                                    role: $0.role, cwd: $0.cwd, last: $0.startLast)
                },
                fix: group.fix ?? .none))
        }
        let rows = groups + lone
        self.init(
            // The heading's count where the core gave one, and the groups'
            // otherwise: the same number since task 1485. The
            // layout goes by the same number: with nobody waiting there is
            // one heading and no line under it.
            waitingCount: snapshot.header_waiting?.count ?? snapshot.groups_needing_me,
            waiting: rows.filter { $0.0 }.map { $0.1 },
            quietCount: snapshot.header_quiet?.count ?? snapshot.groups_other,
            quiet: rows.filter { !$0.0 }.map { $0.1 },
            waitingHeader: snapshot.header_waiting,
            quietHeader: snapshot.header_quiet,
            quota: snapshot.quota,
            supervisorRoles: (snapshot.supervisor_roles ?? []).map { SupervisorRole(key: $0.key, name: $0.name) },
            chooseSupervisorRole: snapshot.choose_supervisor_role ?? false,
            retentionWaitingBytes: snapshot.retention_waiting_bytes)
    }

    static func decode(snapshot json: Data, showing: String? = nil, loneRows: Bool = false) throws -> ControlRoomList {
        ControlRoomList(snapshot: try JSONDecoder().decode(ControlRoomSnapshot.self, from: json),
                        showing: showing, loneRows: loneRows)
    }
}

// MARK: - Where things are

/// Where everything in the list panel is, in the panel's own points with
/// the origin at its top left. Sizes come from `ControlRoomLook`; this adds
/// only the arithmetic, so that the view places things and never measures.
/// How much of what a row waits on is drawn: how many lines each step
/// gets, and how many steps are said only as a number.
///
/// **The rule** (`control-room.md`, 3.5): what is cut is the end of a line,
/// never a step. A sentence wraps to `ask_max_lines` and ends in an
/// ellipsis. A command of that many steps or fewer gives each step a line
/// first and what is left over to the earliest steps that need a second. A
/// command of more steps than that keeps one line a step -- the row grows --
/// up to `ask_max_steps`; past that the last line says how many steps are
/// not shown. So a step is either on the row from its first character or
/// counted on it, and none goes without a word.
struct ControlRoomAskFit: Equatable {
    /// How many lines each step that is shown is drawn on, in order.
    var lines: [Int]
    /// Steps that are not shown and are said as a number instead.
    var hidden: Int

    static let none = ControlRoomAskFit(lines: [], hidden: 0)

    /// Every line this takes on the row, the one that says `hidden` among
    /// them.
    var drawn: Int { lines.reduce(0, +) + (hidden > 0 ? 1 : 0) }

    /// `needed` is how many lines each step would take with all the room
    /// it wanted, in order: a measurement, which is the host's to make.
    static func fit(needed: [Int]) -> ControlRoomAskFit {
        let maxLines = Int(ControlRoomLook.Side.askMaxLines)
        let maxSteps = Int(ControlRoomLook.Side.askMaxSteps)
        let steps = needed.count
        guard steps > 0 else { return .none }
        if steps > maxSteps {
            // One line is kept for the number.
            return ControlRoomAskFit(lines: Array(repeating: 1, count: maxSteps - 1), hidden: steps - (maxSteps - 1))
        }
        var lines = Array(repeating: 1, count: steps)
        var spare = maxLines - steps
        for at in needed.indices where spare > 0 {
            let more = min(spare, max(needed[at], 1) - 1)
            lines[at] += more
            spare -= more
        }
        return ControlRoomAskFit(lines: lines, hidden: 0)
    }
}

extension ControlRoomList {
    /// How many lines `text` takes with no font to measure it by: so many
    /// cells to a line (`ask_cells_per_line`), a wide character two. What
    /// the two hosts are held to one answer with, and what a test lays a
    /// list out by; a host that draws measures with its own font.
    static func nominalLines(_ text: String) -> Int {
        let perLine = Int(ControlRoomLook.Side.askCellsPerLine)
        var cells = 0
        for scalar in text.unicodeScalars {
            cells += scalar.value >= 0x2E80 ? 2 : 1
        }
        return max(1, (cells + perLine - 1) / perLine)
    }
}

/// How the first line of a waiting row is shared out when it is too narrow
/// for all three things on it: the group's name, who is waiting, and the
/// status word.
///
/// **What keeps its width, in order**: the status word, whole; then the
/// name, cut only by the status word; then who is waiting, in what is left
/// -- cut from its start, so the end of a long title is what stays, and
/// not drawn at all when nothing is left. It used to be the other way
/// round: who is waiting kept its width and the name was cut to an
/// ellipsis, so a worker with a long title left a row that did not say
/// which group it was (task 1444, defect 3). The Windows host's
/// `scene::place_line` is the same rule.
enum ControlRoomLine1 {
    struct Fit: Equatable {
        /// How wide the name is drawn; less than it wanted when it is cut.
        var name: Double
        /// How wide who is waiting is drawn; nil when it is not.
        var who: Double?
    }

    /// Widths are what each would take alone on a line; `who` nil when
    /// there is nobody to name. `gap` is the space between two things.
    static func fit(width: Double, gap: Double, name: Double, who: Double?, word: Double) -> Fit {
        // The status word and the gap before it come off the right -- the
        // gap whether or not there is a word, as the Windows host's
        // `place_line` has it, so that the two are one rule to the point.
        let trail = width - word - gap
        let drawnName = max(0, min(name, trail))
        guard let who, who > 0 else { return Fit(name: drawnName, who: nil) }
        // What the name wanted, not what it got: a name that is cut has
        // left no room, even if rounding says a point remains.
        let room = trail - (name + gap)
        return Fit(name: drawnName, who: room > 0 ? min(who, room) : nil)
    }
}

struct ControlRoomListLayout: Equatable {
    typealias Look = ControlRoomLook

    var size: CGSize
    var header: CGRect
    /// The waiting rows and then the quiet ones, keyed by `Row.id`.
    var rows: [String: CGRect]
    /// How what each waiting row waits on is fitted, by `Row.id`. The row's
    /// height came from this, so whatever draws the row draws by it too.
    var fits: [String: ControlRoomAskFit]
    var separator: CGRect
    var quietHeader: CGRect
    /// The allowance block: against the bottom of the panel whatever the
    /// list above it holds, so that it is there when the list is long. No
    /// height when the list has none.
    var quota: CGRect

    /// How wide what a row waits on is: the row, less its padding and the
    /// column the glyph stands in.
    static var askWidth: CGFloat {
        CGFloat(Look.Side.width) - 2 * CGFloat(Look.Space.sidePanelPadding) - 2 * CGFloat(Look.Side.rowPaddingX)
            - CGFloat(Look.Side.glyph) - CGFloat(Look.Side.rowItemGap)
    }

    /// How high a waiting row is: its first line, the lines of what it
    /// waits on, one more when other terminals of the group wait too, and
    /// the line with "Fix" on a card that has it (task 1560).
    static func rowHeight(fit: ControlRoomAskFit, others: Int, fix: ControlRoomList.Fix = .none) -> CGFloat {
        let lines = fit.drawn + (others > 0 ? 1 : 0)
        return 2 * CGFloat(Look.Side.rowPaddingY) + CGFloat(Look.Side.rowLine1Height)
            + CGFloat(lines) * CGFloat(Look.Side.askLineHeight)
            + (fix == .none ? 0 : CGFloat(Look.Side.fixLineHeight))
    }

    /// `needed` says how many lines one step would take with all the room
    /// it wanted, and whether it is set in the terminal's face: the host's
    /// measurement. Left out, the nominal count stands in.
    ///
    /// `noteUnderHeader` is how high whatever is said under the header is
    /// -- why a name made no group -- and the rows start below it: a note
    /// laid over the first row hid the row it was laid over.
    init(list: ControlRoomList, height: CGFloat, noteUnderHeader: CGFloat = 0,
         needed: (String, Bool) -> Int = { text, _ in ControlRoomList.nominalLines(text) }) {
        let pad = CGFloat(Look.Space.sidePanelPadding)
        let width = CGFloat(Look.Side.width)
        let inner = width - 2 * pad
        let padX = CGFloat(Look.Side.headerPaddingX)
        let headerH = CGFloat(Look.Side.headerHeight)
        let gap = CGFloat(Look.Side.rowGap)
        size = CGSize(width: width, height: height)

        var y = pad
        header = CGRect(x: pad, y: y, width: inner, height: headerH)
        y += headerH + max(0, noteUnderHeader)

        var frames: [String: CGRect] = [:]
        var fitted: [String: ControlRoomAskFit] = [:]
        for row in list.waiting {
            let fit = ControlRoomAskFit.fit(needed: row.what.drawn.map { needed($0, row.what.isCode) })
            let rowH = Self.rowHeight(fit: fit, others: row.others, fix: row.fix)
            fitted[row.id] = fit
            frames[row.id] = CGRect(x: pad, y: y, width: inner, height: rowH)
            y += rowH + gap
        }
        fits = fitted

        if list.waitingCount == 0 {
            // The core says nobody is waiting: the one header says so, and
            // the groups follow it with no line and no second header
            // between. Both are kept, with no height, where they would be.
            separator = CGRect(x: pad + padX, y: y, width: inner - 2 * padX, height: 0)
            quietHeader = CGRect(x: pad, y: y, width: inner, height: 0)
        } else {
            y += CGFloat(Look.Side.separatorSpaceAbove)
            separator = CGRect(x: pad + padX, y: y, width: inner - 2 * padX, height: CGFloat(Look.Line.hairline))
            y += CGFloat(Look.Line.hairline) + CGFloat(Look.Side.separatorSpaceBelow)

            quietHeader = CGRect(x: pad, y: y, width: inner, height: headerH)
            y += headerH
        }
        for row in list.quiet {
            frames[row.id] = CGRect(x: pad, y: y, width: inner, height: CGFloat(Look.Side.quietRowHeight))
            y += CGFloat(Look.Side.quietRowHeight)
        }
        rows = frames

        let quotaH = list.quota.map { ControlRoomQuotaLayout(quota: $0).height } ?? 0
        quota = CGRect(x: pad, y: height - pad - quotaH, width: inner, height: quotaH)
    }

    /// Where the selection chip rests for a row; nil for a row not listed.
    func chip(for id: String?) -> CGRect? {
        id.flatMap { rows[$0] }
    }

    /// The rows whose whole card is on screen: above the allowance block,
    /// or above the panel's bottom when there is none. The list does not
    /// scroll -- rows past the bottom are simply cut off -- so this is what
    /// "the card is in sight" is (task 1505: no notification about a card
    /// the person can see). `order` is the list's own (`ControlRoomList.rows`);
    /// this only filters it.
    func inSight(order: [String]) -> [String] {
        let bottom = quota.height > 0 ? quota.minY : size.height
        return order.filter { id in rows[id].map { $0.height > 0 && $0.maxY <= bottom } ?? false }
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

    /// How fast progress is changing at `t` seconds, per second.
    static func speed(at t: Double,
                      period: Double = ControlRoomLook.Selection.springPeriod,
                      damping: Double = ControlRoomLook.Selection.springDamping) -> Double {
        guard t > 0, period > 0 else { return 0 }
        let omega = 2 * Double.pi / period
        guard damping < 1 else { return omega * omega * t * exp(-omega * t) }
        let wd = omega * (1 - damping * damping).squareRoot()
        return exp(-damping * omega * t) * omega * omega / wd * sin(wd * t)
    }

    /// When it first has only `remaining` of the way left to go.
    static func reaches(remaining: Double,
                        period: Double = ControlRoomLook.Selection.springPeriod,
                        damping: Double = ControlRoomLook.Selection.springDamping) -> Double {
        let step = period / 1000
        var t = 0.0
        while t < period * 20, progress(at: t, period: period, damping: damping) < 1 - remaining { t += step }
        return t
    }

    /// After how long it stays within `within` of its end.
    static func settles(within: Double = ControlRoomLook.Selection.settledWithin,
                        period: Double = ControlRoomLook.Selection.springPeriod,
                        damping: Double = ControlRoomLook.Selection.springDamping) -> Double {
        guard period > 0, within > 0 else { return 0 }
        let step = period / 1000
        // Walk back from well past the end to the last moment it was out.
        var t = period * 20
        while t > 0, abs(1 - progress(at: t, period: period, damping: damping)) <= within { t -= step }
        return t + step
    }
}

/// One selection chip's move from where it was to where it is now, written
/// out: whether it moves at all, and if so where it is, and how it is
/// stretched, at every moment until it is still.
///
/// The row's chip is animated by SwiftUI and takes only `Plan` and the two
/// times from here. The window tab's chip is the system's own glass, which
/// can only be handed positions, so it takes `samples` (`WindowTabChipSlide`).
enum ControlRoomChipSlide {
    typealias Look = ControlRoomLook.Selection

    enum Plan: Equatable {
        /// The chip is simply at the new place: Reduce Motion, nowhere to
        /// come from, or nowhere to go.
        case jump
        /// It slides in from this far away (where it was, less where it is).
        case slide(dx: Double, dy: Double)
    }

    static func plan(from: CGRect?, to: CGRect, reduceMotion: Bool) -> Plan {
        guard !reduceMotion, let from else { return .jump }
        let dx = Double(from.midX - to.midX), dy = Double(from.midY - to.midY)
        guard dx != 0 || dy != 0 else { return .jump }
        return .slide(dx: dx, dy: dy)
    }

    /// When the chip starts back down.
    static let landsAt: Double = ControlRoomChipSpring.reaches(remaining: Look.liftLandsWithRemaining)
    /// When it is still.
    static let duration: Double = ControlRoomChipSpring.settles()

    /// How far the chip is lifted at `t`: up to 1 in `lift_in`, there until
    /// `landsAt`, and down again by the time it is still.
    static func lift(at t: Double) -> Double {
        let lands = landsAt, end = duration
        if t <= 0 || t >= end { return 0 }
        if t < Look.liftIn { return t / Look.liftIn }
        if t <= lands { return 1 }
        let x = (t - lands) / (end - lands)
        // Eased, so that it does not drop off a corner.
        return 1 - x * x * (3 - 2 * x)
    }

    struct Sample: Equatable {
        /// From where it will rest, in points.
        var dx: Double
        var dy: Double
        /// Along the way it is going, and across it; 1 is its own size.
        var along: Double
        var across: Double
    }

    /// The chip at `t` seconds into a slide of (`dx`, `dy`).
    static func sample(at t: Double, dx: Double, dy: Double, liftScale: Double) -> Sample {
        let left = 1 - ControlRoomChipSpring.progress(at: t)
        let lifted = 1 + liftScale * lift(at: t)
        // Fastest is what an undamped spring of this period would reach.
        let fastest = 2 * Double.pi / Look.springPeriod
        let quick = min(1, abs(ControlRoomChipSpring.speed(at: t)) / fastest)
        return Sample(dx: dx * left, dy: dy * left,
                      along: lifted * (1 + Look.stretchAlong * quick),
                      across: lifted * (1 - Look.squeezeAcross * quick))
    }

    /// The whole slide, `slide_samples_per_second` of them, the last one at
    /// rest exactly.
    static func samples(dx: Double, dy: Double, liftScale: Double) -> [Sample] {
        let count = max(2, Int((duration * Look.slideSamplesPerSecond).rounded(.up)) + 1)
        var all = (0 ..< count - 1).map {
            sample(at: Double($0) / Look.slideSamplesPerSecond, dx: dx, dy: dy, liftScale: liftScale)
        }
        all.append(Sample(dx: 0, dy: 0, along: 1, across: 1))
        return all
    }
}

// MARK: - Made-up data

extension ControlRoomList {
    /// The design's own example (v18, direction A), for still pictures and
    /// tests: four groups waiting, four that need nothing.
    static let sample: ControlRoomList = {
        let supervisor = Waiter(is: .supervisor, name: "")
        return ControlRoomList(
            waitingCount: 4,
            waiting: [
                Row(id: "billing", shown: .needsYou, word: "等回答", waiter: supervisor,
                    what: What(cut: .none, form: .words, lines: [
                        "发票编号要按租户分开，还是全局连续？分开的话，旧发票要不要一起改编号；改的那几天新开的发票先用哪一种，财务对账的报表是不是也要跟着改，还是等月底结账以后再统一处理？",
                    ]), others: 0, pulses: true),
                Row(id: "web-app", shown: .needsYou, word: "等批准", waiter: supervisor,
                    what: What(cut: .none, form: .command, lines: [
                        "rm -rf dist/ .cache/ node_modules/.vite", "&& npm ci", "&& npm run build -- --mode production",
                    ]), others: 0, pulses: false),
                Row(id: "mobile", shown: .needsYou, word: "等批准",
                    waiter: Waiter(is: .workerViaSupervisor, name: "ios-build"),
                    what: What(cut: .none, form: .command, lines: ["git push --force-with-lease origin release/2.4"]),
                    others: 0, pulses: false),
                Row(id: "docs-site", shown: .trouble, word: "出错", waiter: supervisor,
                    what: What(cut: .none, form: .words, lines: ["调用次数用完了，13:40 恢复。"]), others: 0, pulses: false),
            ],
            quietCount: 4,
            quiet: [
                Row(id: "infra", shown: .doneUnseen, word: "做完了，没看", waiter: .none,
                    what: What(cut: .none, form: .words, lines: ["迁移脚本写完了，12 条测试全过"]), others: 0, pulses: false),
                Row(id: "design-system", shown: .working, word: "在干活", waiter: .none,
                    what: What(cut: .none, form: .words, lines: ["在改按钮的三种尺寸"]), others: 0, pulses: false),
                Row(id: "search", shown: .working, word: "在干活", waiter: .none,
                    what: What(cut: .none, form: .words, lines: ["在重建搜索索引，跑到第 2 步，共 5 步"]), others: 0, pulses: false),
                Row(id: "notes", shown: .none, word: "", waiter: .none, what: .none, others: 0, pulses: false),
            ])
    }()
}
