//! The control room's snapshot: everything it shows, worked out in one
//! place, and the bookkeeping that says when it changed.
//!
//! **Everything in a snapshot is already decided.** The order of the rows,
//! which need the person, the number in "N waiting", the glyph on each tab,
//! the words beside it, how many minutes -- a host draws what it is given.
//! A host that compares a `kind` or counts rows is a defect
//! (dev-docs/poltergeist/control-room.md, 5.4).
//!
//! ## The JSON
//!
//! `write` gives one object. `testdata/control_snapshot.json` is a whole
//! one, built by the test at the bottom of this file, and is what a host
//! can start from.
//!
//! ```
//! { "rev": 3,                 changes exactly when anything below, other
//!                             than the two ages, changes
//!   "now_ms": 6000000,        the clock every *_ms below is on, except
//!                             last_ms / seen_ms / snooze, which are wall
//!   "needs_me": 5,            rows that wait, a group's or a lone terminal's:
//!                             groups_needing_me plus the rows of
//!                             `ungrouped` with needs_me. The Dock's number
//!   "groups_needing_me": 4,   rows in `groups` with needs_me, in a row
//!                             from the top. The list's header
//!   "groups_other": 3,        the rest of `groups`
//!   "header_waiting": {"count": 5, "of": "rows", "number": "other",
//!                      "groups": 4, "alone": 1},
//!   "header_quiet":   {"count": 3, "of": "groups", "number": "other",
//!                      "groups": 3, "alone": 0},
//!                             what the list's two headings say, for a host
//!                             that draws a lone terminal's row among the
//!                             groups'. count: the rows under that heading
//!                             -- for header_waiting the same number as
//!                             needs_me. of: groups (every one of them is a
//!                             group: "N groups …") | rows (a lone terminal
//!                             is among them: "N waiting …", no word for
//!                             what they are). number: none | one | other,
//!                             so that "1 group" and "3 groups" are the
//!                             host's two sentences and not its arithmetic.
//!                             groups / alone: the two that count is the
//!                             sum of, for a host that says them apart.
//!                             A host that draws only the groups' rows goes
//!                             by groups_needing_me / groups_other instead,
//!                             and is as true to what it draws
//!   "open_on": "web-app" | null,
//!                             the group a control room that opens with
//!                             nothing selected selects: the first row
//!                             with an agent in it, or the first row when
//!                             none has one. Null with no groups
//!   "groups": [ {             already in the order to draw them
//!       "name": "web-app", "brief": "", "last_ms": 0,
//!       "seen_ms": null,
//!       "snooze": {"until":"none","at_ms":null,"until_ms":null},
//!                             until: none | next_event | time
//!       "steward": "0x00000000000000a1" | null,
//!       "supervisor": {
//!         "state": "present",     present | absent | starting | failed.
//!                                 starting and failed are a supervisor
//!                                 the person asked for from the control
//!                                 room (ControlAct.zig, start_supervisor)
//!         "can_start": false,     whether the control room offers to
//!                                 start one: there is none, none is on
//!                                 its way, and there is a role to start
//!                                 it in. A host shows the button on this
//!                                 and on nothing else
//!         "terminal": "0x…"|null, the terminal one is being started in
//!         "failed": "none",       none | terminal_never_opened |
//!                                 agent_never_connected | terminal_closed
//!         "role": "polter-supervisor" | null,
//!                                 the role it is started in unless the
//!                                 person picks another; null with no
//!                                 supervisor role at all
//!         "cwd": "/Users/me/work",
//!         "cwd_from": "last_supervisor" },
//!                                 where it is started unless the person
//!                                 picks elsewhere, and how that was
//!                                 arrived at: last_supervisor (where this
//!                                 group's supervisor last worked, kept
//!                                 across restarts) | members (what most of
//!                                 its terminals are in) | home | none
//!       "attention": {
//!         "kind": "needs_approval",     Attention.Kind
//!         "under": "needs_approval",    what it is when not snoozed
//!         "since_ms": 5760000,
//!         "source": "hook",             Attention.Source
//!         "age_ms": 240000 | null,      not compared
//!         "terminal": "0x…" | null,     whose state this is
//!         "worker": "0x…" | null,       set when it bubbled up from one
//!         "event_ms": 5760000 | null }, when that terminal's agent was
//!                                       last heard from; with since_ms,
//!                                       what an act on this row hands
//!                                       back (ControlAct.zig)
//!       "needs_me": true, "unseen": false,
//!                             unseen: looking at the row changes it -- it
//!                             stopped and has not been looked at, or its
//!                             supervisor raised it (`notify_user`) and the
//!                             person has not looked since. What a host
//!                             starts its "seen" clock on; a row can be
//!                             both needs_me and unseen
//!       "shown": "needs_you",   needs_you | trouble | done_unseen |
//!                               working | none
//!       "word": "needs_approval", "text": "等批准",
//!       "waiter": {"is":"supervisor","name":""},
//!                             who the row is about. is: none | supervisor
//!                             | worker_via_supervisor | worker | terminal.
//!                             `name` is the worker's when it is one
//!       "reason": {"from":"hook_note","text":"rm -rf dist/ && npm ci",
//!                  "missing":null},
//!                             from: hook_note | hook_detail | process |
//!                             clocks | hooks | last_turn | task | raised |
//!                             none. `raised` is the supervisor's own
//!                             sentence from `notify_user`.
//!                             When the line could not be had, text is
//!                             empty and `missing` says which kind of
//!                             missing: empty_note | empty_detail |
//!                             no_turn_kept | self_report_text
//!       "what": {"form":"command",
//!                "lines":["rm -rf dist/","&& npm ci"],
//!                "cut":"none"},
//!                             the same thing in the pieces it is drawn
//!                             in. form: none | command | code | words. A
//!                             command is one step to a line; a host shows
//!                             as many lines as it has room for.
//!                             cut says whether lines is all of it: none |
//!                             tail (the start of something longer: a
//!                             summary, the whole not sent) | head (the end
//!                             of something longer: the last paragraph of
//!                             a turn). A host marks where the rest is and
//!                             never shows a part as the whole
//!       "more": 1,            other terminals in the group also waiting
//!       "same_as": "billing" | null,
//!                             same supervisor as that group's row, which
//!                             is the one that carries the reason
//!       "members": [ { "id":"0x…", "role":"steward"|"worker",
//!           "title":"…", "kind":…, "since_ms":…, "source":…,
//!           "age_ms":…, "shown":…, "word":…, "text":…,
//!           "screen":"unmeasured"|"unreadable"|"measured",
//!           "alive":true, "duty":"on"|"off",
//!           "held":false, "shielded":false } ] } ],
//!                             (a row of `ungrouped` is marked seen by its
//!                             terminal: {"act":"seen","terminal":"0x…"})
//!   "ungrouped": [ { "id", "title", "attention", "needs_me", "unseen",
//!       "shown", "word", "text", "waiter", "reason", "what" } ],
//!   "terminals": [ { the member fields but `role`, and "event_ms",
//!       "window":"0x…"|null, "tab":"0x…"|null,
//!       "pane":"supervisor"|"worker"|"plain" } ],
//!                             `pane` is which of the three frames this
//!                             terminal's pane wears in its own tab: the
//!                             terminal minding others, one being minded,
//!                             or neither. A host draws the frame it is
//!                             told and asks no role
//!   "tabs": [ { "window":"0x…"|null, "tab":"0x…",
//!       "shown":…, "terminal":"0x…"|null } ],
//!   "supervisor_roles": [ {"key":"polter-supervisor",
//!       "name":"Polter Supervisor"} ],
//!                             the roles a supervisor can be started in,
//!                             in the order to offer them
//!   "choose_supervisor_role": false,
//!                             whether there is a choice to offer: more
//!                             than one. A host does not count them
//!   "pulses": [ { "terminal":"0x…", "window":"0x…"|null,
//!       "tab":"0x…"|null, "group":"billing"|null } ],
//!                             every terminal waiting for the person,
//!                             longest first. The one glyph that breathes
//!                             in a window is the first of these not in
//!                             the tab that window is showing (and, for a
//!                             glyph in a tab bar or a pane, in that
//!                             window). `group` is the row that is about
//!                             it. A host tests equality and nothing else.
//!   "quota": { … }            how much of each account's allowance is
//!                             used: the block at the bottom of the list.
//!                             `quota.zig` has the shape. Its moments are
//!                             wall clock }
//! ```
//!
//! **Nothing here says how long anything has waited**, and nothing draws
//! the day's waiting: both were on screen once and told the person nothing
//! they could act on (the user, 2026-10-13). The order of the rows is still
//! longest-waiting first; that is this file's business and not a number.
//!
//! `since_ms` is when the state began and does not move when the agent
//! says the same thing again; `event_ms` moves on every word from it.
//!
//! Ids are strings, `0x` and sixteen hex digits, the way every other export
//! writes a terminal: they use all 64 bits and a JSON number does not.

const ControlRoom = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Attention = @import("Attention.zig");
const Bus = @import("Bus.zig");
const Chat = @import("Chat.zig");
const AgentEvent = @import("agent_event.zig");
const ShellSteps = @import("ShellSteps.zig");
const quota = @import("quota.zig");
const Tasks = @import("Tasks.zig");

pub const Id = Bus.Id;

/// The least time between two change notices: four a second.
pub const notice_gap_ms: u64 = 250;

alloc: Allocator,

/// Goes up by one each time the snapshot differs from the one before.
rev: u64,

/// The latest snapshot as JSON, and the part of it that is compared. Owned.
json: []u8,
stable: []u8,

/// The last `rev` a notice went out for, and when.
sent_rev: u64,
sent_ms: ?u64,

/// When to look again if nothing happens first, or null for never.
wake_ms: ?u64,

/// How many times the snapshot has been worked out.
recomputes: u64,

pub fn init(alloc: Allocator) ControlRoom {
    return .{
        .alloc = alloc,
        .rev = 0,
        .json = &.{},
        .stable = &.{},
        .sent_rev = 0,
        .sent_ms = null,
        .wake_ms = null,
        .recomputes = 0,
    };
}

pub fn deinit(self: *ControlRoom) void {
    self.alloc.free(self.json);
    self.alloc.free(self.stable);
    self.* = undefined;
}

pub const Cause = enum {
    /// Something happened: a hook, a report, a mark, a terminal coming or
    /// going.
    event,
    /// Only time passed.
    timer,
};

pub const Outcome = struct {
    /// Tell the host now, with this `rev`.
    notify: ?u64,
    /// Call again with `.timer` at this time, on the bus's clock, if
    /// nothing has happened by then. Null: nothing will change on its own,
    /// and nothing should wake to check.
    wake_ms: ?u64,
};

/// Bring the snapshot up to date.
///
/// On `.timer` before `wake_ms`, nothing is worked out at all: time passing
/// short of a threshold changes nothing that is compared.
pub fn refresh(self: *ControlRoom, in: Input, cause: Cause) Allocator.Error!Outcome {
    if (cause == .timer) {
        const due = self.wake_ms orelse return .{ .notify = null, .wake_ms = null };
        if (in.now_ms < due) return .{ .notify = null, .wake_ms = due };
    }

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();

    var built = try self.compute(arena.allocator(), in);

    const stable = try writeAlloc(self.alloc, try stripped(arena.allocator(), built.snapshot), .{});
    if (std.mem.eql(u8, stable, self.stable)) {
        self.alloc.free(stable);
    } else {
        self.alloc.free(self.stable);
        self.stable = stable;
        self.rev += 1;
    }

    built.snapshot.rev = self.rev;
    const json = try writeAlloc(self.alloc, built.snapshot, .{});
    self.alloc.free(self.json);
    self.json = json;

    // At most one notice per gap; a change inside the gap waits for its end
    // and goes out with whatever else changed meanwhile.
    var wake = built.wake_ms;
    var notify: ?u64 = null;
    if (self.rev != self.sent_rev) {
        const open_ms = if (self.sent_ms) |at| at +| notice_gap_ms else in.now_ms;
        if (in.now_ms >= open_ms) {
            notify = self.rev;
            self.sent_rev = self.rev;
            self.sent_ms = in.now_ms;
        } else {
            wake = earlier(wake, open_ms);
        }
    }

    self.wake_ms = wake;
    return .{ .notify = notify, .wake_ms = wake };
}

/// The whole snapshot as of now. Everything in the result lives in `arena`.
fn compute(self: *ControlRoom, arena: Allocator, in: Input) Allocator.Error!Built {
    const built = try build(arena, in);
    self.recomputes += 1;
    return built;
}

fn earlier(a: ?u64, b: u64) u64 {
    return if (a) |x| @min(x, b) else b;
}

// -- what goes in -----------------------------------------------------------

/// A terminal on screen, as the app sees it.
pub const Terminal = struct {
    id: Id,
    title: []const u8,
    /// Null when the apprt did not say.
    window: ?u64,
    tab: ?u64,
    process: Attention.Process,
    /// An agent is connected to Polter from this terminal.
    agent_present: bool,
    /// This terminal's own T1, when it was given one; null for the common
    /// one.
    still_ms: ?u64,
};

pub const Input = struct {
    bus: *const Bus,
    chat: *const Chat,
    /// Every terminal that is open. A group member not in here is gone.
    terminals: []const Terminal,
    thresholds: Attention.Thresholds,
    /// The task panel: what a group that is working says it is doing.
    tasks: *const Tasks,
    /// What was last read of each account's allowance (`QuotaWatch`). No
    /// default: a caller that forgot it would show "no number yet" for
    /// ever, which is also what a machine with no agent on it shows.
    quota: []const quota.Reading,
    /// The roles a supervisor can be started in from the control room, in
    /// the order to offer them; the first is the one used unless the person
    /// picks. Empty when there is none, and then nothing can be started.
    supervisor_roles: []const SupervisorRole,
    /// The person's home directory, where a supervisor is started when
    /// nothing says better. Empty when it is not known.
    home: []const u8,
    /// The bus's clock, and the real one.
    now_ms: u64,
    wall_ms: u64,
};

/// A role that makes the terminal it starts in a supervisor.
pub const SupervisorRole = struct {
    key: []const u8,
    name: []const u8,
};

// -- what comes out ---------------------------------------------------------

/// A 64-bit id, written as `"0x%016x"`.
pub const Hex = struct {
    id: u64,

    pub fn jsonStringify(self: Hex, jw: anytype) !void {
        try jw.print("\"0x{x:0>16}\"", .{self.id});
    }

    pub fn jsonParse(alloc: Allocator, source: anytype, options: std.json.ParseOptions) !Hex {
        _ = options;
        const s = switch (try source.nextAlloc(alloc, .alloc_if_needed)) {
            .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        if (s.len != 18 or !std.mem.startsWith(u8, s, "0x")) return error.UnexpectedToken;
        return .{ .id = std.fmt.parseInt(u64, s[2..], 16) catch return error.UnexpectedToken };
    }

    fn opt(id: ?u64) ?Hex {
        return if (id) |v| .{ .id = v } else null;
    }
};

pub const AttentionOut = struct {
    kind: Attention.Kind,
    under: Attention.Kind,
    since_ms: u64,
    source: Attention.Source,
    age_ms: ?u64,
    terminal: ?Hex,
    worker: ?Hex,
    /// When that terminal's agent was last heard from. With `since_ms`,
    /// what an action on this row has to hand back (`ControlAct`).
    event_ms: ?u64,

    fn of(a: Attention, bus: *const Bus) AttentionOut {
        return .{
            .kind = a.kind,
            .under = a.under,
            .since_ms = a.since_ms,
            .source = a.source,
            .age_ms = a.age_ms,
            .event_ms = if (a.terminal) |id| bus.agentOf(id).last_event_ms else null,
            .terminal = .opt(a.terminal),
            .worker = switch (a.what) {
                .worker => |id| .{ .id = id },
                .own, .nobody => null,
            },
        };
    }
};

pub const SnoozeOut = struct {
    until: enum { none, next_event, time },
    at_ms: ?u64,
    until_ms: ?u64,

    fn of(s: Chat.Marks.Snooze) SnoozeOut {
        return switch (s) {
            .none => .{ .until = .none, .at_ms = null, .until_ms = null },
            .next_event => |at| .{ .until = .next_event, .at_ms = at, .until_ms = null },
            .until => |u| .{ .until = .time, .at_ms = u.at_ms, .until_ms = u.until_ms },
        };
    }
};

/// The line that says what it is waiting on (3.2).
pub const Reason = struct {
    from: From,
    text: []const u8,
    /// Why there is no text, when there should have been.
    missing: ?Missing,

    /// `raised`: what the supervisor said when it put this in front of the
    /// person (`notify_user`, `authorisation`; `Bus.raise`).
    pub const From = enum { hook_note, hook_detail, process, clocks, hooks, last_turn, task, raised, none };
    pub const Missing = enum { empty_note, empty_detail, no_turn_kept, self_report_text };

    pub const none: Reason = .{ .from = .none, .text = "", .missing = null };

    /// Every sentence this file writes for the person, in one place. All
    /// 暂定, like the words in `Attention.Word`.
    pub const words = struct {
        pub const process_exited = "进程退出";
        pub const hooks_missing = "约好的 hook 没有来";
        /// Error type, then what the agent said about it.
        pub const failed = "{s}：{s}";
        pub const still = "屏幕 {d} 分没动";
        pub const still_and_silent = "屏幕 {d} 分没动，{d} 分没调工具";
    };

    fn lacking(from: From, missing: Missing) Reason {
        return .{ .from = from, .text = "", .missing = missing };
    }
};

/// What a row says under its name, already in the pieces it is drawn in.
///
/// For a row that is waiting, this is what it is waiting for; for one that
/// is not, what it is doing or has just done. **`form` says what kind of
/// text it is, so that no host guesses from where it came**: a command is
/// set in the terminal's face, one step to a line; words are set as words.
/// `lines` is all of it -- nothing is cut here. How many lines are shown is
/// a host's own matter.
pub const What = struct {
    form: Form,
    lines: []const []const u8,
    /// Whether `lines` is all of it. A host must not show a part as the
    /// whole: it marks where the rest would be.
    cut: Cut,

    pub const Cut = enum {
        /// `lines` is everything that was said.
        none,
        /// `lines` is the start of something longer, or may be: a summary
        /// that reached its limit, with the whole not sent.
        tail,
        /// `lines` is the end of something longer: the last paragraph of a
        /// turn, where a question asked in prose is.
        head,
    };

    pub const Form = enum {
        /// Nothing to say: `lines` is empty and a host draws no line.
        none,
        /// A shell command, cut into steps (`ShellSteps`): one step per
        /// line, each after the first starting with its `&&`, `|`, `;`.
        command,
        /// Something literal that is not a command to cut -- the file a
        /// tool wants to write, a command in a shell whose rules are not
        /// the ones `ShellSteps` knows. One line, set like a command.
        code,
        /// A sentence: a question, why it failed, what it is doing.
        words,
    };

    pub const none: What = .{ .form = .none, .lines = &.{}, .cut = .none };
};

/// Who is waiting: the terminal a waiting row is about, as one of the things
/// a host can say without working anything out.
///
/// **Only a row that needs the person has one.** A row about a group that is
/// working, or idle, is about a terminal too, but nobody is waiting there,
/// and `supervisor` on such a row would be one word for "the supervisor
/// waits" and "the supervisor is who this is about".
pub const Waiter = struct {
    is: Is,
    /// The worker's name when it is a worker; empty otherwise. 暂定: its
    /// terminal's title, the only name the control room is given.
    name: []const u8,

    pub const Is = enum {
        /// The row is about no terminal.
        none,
        /// The group's supervisor itself.
        supervisor,
        /// A worker of the group, whose wait has come up through its
        /// supervisor.
        worker_via_supervisor,
        /// A worker of a group that has no supervisor.
        worker,
        /// A terminal on its own, in no group.
        terminal,
    };

    pub const none: Waiter = .{ .is = .none, .name = "" };
};

pub const ScreenOut = enum { unmeasured, unreadable, measured };

pub const Member = struct {
    id: Hex,
    role: enum { steward, worker },
    title: []const u8,
    kind: Attention.Kind,
    since_ms: u64,
    source: Attention.Source,
    age_ms: ?u64,
    shown: Attention.Shown,
    word: Attention.Word,
    text: []const u8,
    screen: ScreenOut,
    alive: bool,
    duty: Bus.Duty,
    held: bool,
    shielded: bool,
};

/// Whether a group has a supervisor, and what starting one would use.
/// Everything a host needs to offer "start a supervisor" and nothing it
/// has to work out.
pub const SupervisorOut = struct {
    state: State,
    can_start: bool,
    terminal: ?Hex,
    failed: Chat.StartFailure,
    role: ?[]const u8,
    cwd: []const u8,
    cwd_from: CwdFrom,

    pub const State = enum { present, absent, starting, failed };
    pub const CwdFrom = enum { none, last_supervisor, members, home };
};

pub const GroupRow = struct {
    name: []const u8,
    brief: []const u8,
    last_ms: u64,
    seen_ms: ?u64,
    snooze: SnoozeOut,
    steward: ?Hex,
    supervisor: SupervisorOut,
    attention: AttentionOut,
    needs_me: bool,
    unseen: bool,
    shown: Attention.Shown,
    word: Attention.Word,
    text: []const u8,
    waiter: Waiter,
    reason: Reason,
    what: What,
    more: usize,
    same_as: ?[]const u8,
    members: []const Member,
};

pub const LoneRow = struct {
    id: Hex,
    title: []const u8,
    attention: AttentionOut,
    needs_me: bool,
    unseen: bool,
    shown: Attention.Shown,
    word: Attention.Word,
    text: []const u8,
    waiter: Waiter,
    reason: Reason,
    what: What,
};

/// Which of the three frames a terminal's pane wears in its own tab
/// (dev-docs/poltergeist/control-room.md, 12.6).
pub const Pane = enum {
    /// It is minding others.
    supervisor,
    /// Somebody is minding it.
    worker,
    /// Neither: a shell, or an agent nobody minds.
    plain,

    pub fn of(role: Bus.Role) Pane {
        return switch (role) {
            .supervisor => .supervisor,
            .watched => .worker,
            .none => .plain,
        };
    }
};

pub const TerminalOut = struct {
    id: Hex,
    title: []const u8,
    window: ?Hex,
    tab: ?Hex,
    pane: Pane,
    kind: Attention.Kind,
    since_ms: u64,
    event_ms: ?u64,
    source: Attention.Source,
    age_ms: ?u64,
    shown: Attention.Shown,
    word: Attention.Word,
    text: []const u8,
    screen: ScreenOut,
    alive: bool,
    duty: Bus.Duty,
    held: bool,
    shielded: bool,
};

pub const Tab = struct {
    window: ?Hex,
    tab: Hex,
    shown: Attention.Shown,
    /// The terminal the glyph is about, when there is one.
    terminal: ?Hex,
};

/// One "waiting for you" glyph that may be the one that breathes.
pub const Pulse = struct {
    terminal: Hex,
    window: ?Hex,
    tab: ?Hex,
    /// The row in `groups` that is about this terminal, when there is one.
    group: ?[]const u8,
};

/// What one of the list's two headings says: how many rows are under it,
/// whether they are all groups, and which grammatical number that is.
///
/// **Here because a host was writing it from half the facts.** The heading
/// said "1 group waiting for you" over three rows with a 3 on the Dock: the
/// host had begun to draw lone terminals' rows and went on counting groups
/// (2026-10-13). A count a host can only get right by adding two fields
/// and comparing the sum with one is a count the core should have said.
pub const HeaderOut = struct {
    count: usize,
    of: Of,
    number: Number,
    /// The two that `count` is the sum of: the rows that are groups, and
    /// the rows that are lone terminals. For a host that wants to say them
    /// apart; `count`, `of` and `number` are for one that does not.
    groups: usize,
    alone: usize,

    pub const Of = enum { groups, rows };
    pub const Number = enum { none, one, other };

    fn over(groups: usize, alone: usize) HeaderOut {
        const count = groups + alone;
        return .{
            .count = count,
            .of = if (alone == 0) .groups else .rows,
            .number = switch (count) {
                0 => .none,
                1 => .one,
                else => .other,
            },
            .groups = groups,
            .alone = alone,
        };
    }
};

pub const Snapshot = struct {
    rev: u64,
    now_ms: u64,
    needs_me: usize,
    groups_needing_me: usize,
    groups_other: usize,
    header_waiting: HeaderOut,
    header_quiet: HeaderOut,
    /// The row a control room opening with nothing selected starts on.
    /// The first, in the order below, of the groups that have an agent in
    /// them (`hasAgent`); the first group when every one is empty; null
    /// when there are none. Here and not in a host because "first" is an
    /// order and "has an agent" is a judgement.
    open_on: ?[]const u8,
    groups: []const GroupRow,
    ungrouped: []const LoneRow,
    terminals: []const TerminalOut,
    tabs: []const Tab,
    supervisor_roles: []const SupervisorRole,
    choose_supervisor_role: bool,
    /// Every "waiting for you" terminal, longest-waiting first. **The one
    /// glyph that breathes in a window is the first of these that is not
    /// in the tab that window is showing** -- and, for a glyph that stands
    /// in a tab bar or a pane, that is in that window at all. A host finds
    /// it by asking "is this the tab I am showing" and "is this my window",
    /// which are equalities; the order, which is a comparison, is here.
    pulses: []const Pulse,
    /// The allowance block at the bottom of the list (`quota.zig`).
    quota: quota.Out,
};

pub fn writeAlloc(alloc: Allocator, snapshot: Snapshot, options: std.json.Stringify.Options) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, snapshot, options);
}

/// The snapshot with everything that moves on its own taken out: what two
/// snapshots are compared by. An age grows every millisecond and says
/// nothing has happened; `since_ms` is a moment and stays put.
fn stripped(arena: Allocator, s: Snapshot) Allocator.Error!Snapshot {
    var out = s;
    out.rev = 0;
    out.now_ms = 0;

    const groups = try arena.dupe(GroupRow, s.groups);
    for (groups) |*g| {
        g.attention.age_ms = null;
        const members = try arena.dupe(Member, g.members);
        for (members) |*m| m.age_ms = null;
        g.members = members;
    }
    out.groups = groups;

    const lone = try arena.dupe(LoneRow, s.ungrouped);
    for (lone) |*r| r.attention.age_ms = null;
    out.ungrouped = lone;

    const terminals = try arena.dupe(TerminalOut, s.terminals);
    for (terminals) |*t| t.age_ms = null;
    out.terminals = terminals;

    out.quota = try quota.stripped(arena, s.quota);

    return out;
}

// -- working it out ---------------------------------------------------------

const Built = struct {
    snapshot: Snapshot,
    wake_ms: ?u64,
};

/// The earliest of the moments offered that is still ahead.
const Wake = struct {
    now_ms: u64,
    at: ?u64,

    fn consider(self: *Wake, at: ?u64) void {
        const v = at orelse return;
        if (v <= self.now_ms) return;
        self.at = earlier(self.at, v);
    }
};

const min_ms = std.time.ms_per_min;

fn find(terminals: []const Terminal, id: Id) ?Terminal {
    for (terminals) |t| if (t.id == id) return t;
    return null;
}

fn statusOf(in: Input, id: Id, seen_ms: ?u64, wake: *Wake) Attention.Status {
    const open = find(in.terminals, id);
    // A terminal given its own idea of "still" is judged by it.
    var thresholds = in.thresholds;
    if (open) |t| if (t.still_ms) |ms| {
        thresholds.screen_still_ms = ms;
    };
    // What this terminal has put in front of the person and they have not
    // looked at since (`Bus.raise`). Said from the later of that moment and
    // the start of the state it is in now: `classify` lets a raise stand
    // only for the state it was made in, and a supervisor that raises and
    // then ends its turn has not taken it back.
    const raised_ms: ?u64 = if (in.bus.raisedOf(id, seen_ms)) |r|
        @max(r.at_ms, in.bus.agentOf(id).since_ms)
    else
        null;
    const f = in.bus.facts(id, in.now_ms, .{
        .process = if (open) |t| t.process else .gone,
        .seen_ms = seen_ms,
        .raised_ms = raised_ms,
    });
    wake.consider(Attention.nextChange(f, thresholds, in.now_ms));
    return Attention.classify(f, thresholds, in.now_ms);
}

fn screenOut(s: Attention.Screen) ScreenOut {
    return switch (s) {
        .unmeasured => .unmeasured,
        .unreadable => .unreadable,
        .still_ms => .measured,
    };
}

/// The last line of what the agent said, which is where a question asked
/// in prose ends up.
fn lastLine(text: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, text, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0) return cut(t, 240);
    }
    return "";
}

/// The last paragraph of what the agent said, on one line: where a question
/// asked in prose is, all of it. `rest` says whether anything came before.
fn lastParagraph(arena: Allocator, text: []const u8) Allocator.Error!struct { text: []const u8, rest: bool } {
    const all = std.mem.trimEnd(u8, text, " \t\r\n");
    var start: usize = 0;
    var i: usize = all.len;
    // Back to the last line that is empty or only spaces.
    var line_end = all.len;
    while (i > 0) : (i -= 1) {
        if (all[i - 1] != '\n') continue;
        if (std.mem.trim(u8, all[i..line_end], " \t\r").len == 0) {
            start = line_end;
            break;
        }
        line_end = i - 1;
    }
    const para = std.mem.trim(u8, all[start..], " \t\r\n");
    const out = try arena.dupe(u8, para);
    for (out) |*c| if (c.* == '\n' or c.* == '\r' or c.* == '\t') {
        c.* = ' ';
    };
    return .{ .text = out, .rest = std.mem.trim(u8, all[0..start], " \t\r\n").len > 0 };
}

/// Whether a hook's one-line note may be less than what was said: it is as
/// long as the bus keeps one (`Bus.Agent.note`), or as the summary `+hook`
/// makes (`AgentEvent.summary_chars`). A note shorter than both is whole.
fn noteMayBeCut(note: []const u8) bool {
    if (note.len + 4 > note_bytes) return true;
    return (std.unicode.utf8CountCodepoints(note) catch note.len) >= AgentEvent.summary_chars;
}

/// How many bytes of a note the bus keeps.
const note_bytes = @typeInfo(@FieldType(@FieldType(Bus.Agent, "note"), "buf")).array.len;

fn cut(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var n = limit;
    while (n > 0 and (text[n] & 0xc0) == 0x80) n -= 1;
    return text[0..n];
}

/// The reason line for the terminal a row is about. The sentences are 暂定,
/// like the words in `Attention.Word`.
fn reasonOf(
    arena: Allocator,
    in: Input,
    s: Attention.Status,
    group: ?[]const u8,
    wake: *Wake,
) Allocator.Error!Reason {
    const agent = in.bus.agentOf(s.id);
    switch (s.kind) {
        .needs_approval => {
            const note = agent.note.get() orelse return .lacking(.hook_note, .empty_note);
            return .{ .from = .hook_note, .text = try arena.dupe(u8, note), .missing = null };
        },
        .needs_answer => {
            if (s.source == .self_report) {
                // The supervisor's own sentence. Asked for whatever the
                // person has seen: this row is a self-report because the
                // raise stands, and `statusOf` is what decided that.
                const r = in.bus.raisedOf(s.id, null) orelse return .lacking(.none, .self_report_text);
                if (r.text.len == 0) return .lacking(.raised, .self_report_text);
                return .{ .from = .raised, .text = try arena.dupe(u8, r.text), .missing = null };
            }
            if (agent.note.get()) |note| return .{ .from = .hook_note, .text = try arena.dupe(u8, note), .missing = null };
            // No note: the hook said only that it is waiting. What it asked
            // is how its last turn ended.
            const turn = in.bus.turnOf(s.id) orelse return .lacking(.hook_note, .empty_note);
            const line = lastLine(turn.text);
            if (line.len == 0) return .lacking(.hook_note, .empty_note);
            return .{ .from = .last_turn, .text = try arena.dupe(u8, line), .missing = null };
        },
        .failed => {
            if (s.source == .process) return .{ .from = .process, .text = Reason.words.process_exited, .missing = null };
            const detail = agent.detail.get();
            const note = agent.note.get();
            const text = if (detail != null and note != null)
                try std.fmt.allocPrint(arena, Reason.words.failed, .{ detail.?, note.? })
            else
                try arena.dupe(u8, detail orelse note orelse return .lacking(.hook_detail, .empty_detail));
            return .{ .from = .hook_detail, .text = text, .missing = null };
        },
        .suspect_stuck => {
            if (s.source == .hook_missing) return .{ .from = .hooks, .text = Reason.words.hooks_missing, .missing = null };
            return clocks(arena, in, s, wake);
        },
        .quiet_unknown => {
            if (s.source == .screen_unreadable) return .none;
            return clocks(arena, in, s, wake);
        },
        .done_unseen => {
            const turn = in.bus.turnOf(s.id) orelse return .lacking(.last_turn, .no_turn_kept);
            const line = lastLine(turn.text);
            if (line.len == 0) return .lacking(.last_turn, .no_turn_kept);
            return .{ .from = .last_turn, .text = try arena.dupe(u8, line), .missing = null };
        },
        .working => {
            // What the panel says is being worked on. The agent is working
            // now (that is this row's kind) and the title is what its
            // supervisor wrote the work down as; neither half is a guess.
            const title = workingOn(arena, in, s.id, group) orelse return .none;
            return .{ .from = .task, .text = title, .missing = null };
        },
        .idle, .unattended, .snoozed => return .none,
    }
}

/// The title of the task `id` is working on in `group`: its own open task
/// marked `working`, the newest when it has several. Null when it has none
/// -- then nothing is said, rather than another terminal's task or a task
/// nobody has started.
fn workingOn(arena: Allocator, in: Input, id: Id, group: ?[]const u8) ?[]const u8 {
    const name = group orelse return null;
    const mine = in.tasks.forWorker(arena, name, id) catch return null;
    var found: ?Tasks.Task = null;
    for (mine) |t| {
        if (t.progress != .working) continue;
        if (found == null or t.id > found.?.id) found = t;
    }
    const t = found orelse return null;
    return arena.dupe(u8, t.title) catch null;
}

/// A row's `what`: its reason, in the pieces it is drawn in.
fn whatOf(arena: Allocator, in: Input, s: Attention.Status, reason: Reason) Allocator.Error!What {
    // All of what the hook sent, when it sent all of it. One that reached
    // the limit `+hook` cuts at may have had more.
    const asked = in.bus.askOf(s.id);
    const asked_cut: What.Cut = if (asked) |a| (if (a.len + 4 > AgentEvent.max_text_bytes) .tail else .none) else .none;
    const note_cut: What.Cut = if (reason.from == .hook_note and noteMayBeCut(reason.text)) .tail else .none;

    if (s.kind == .needs_approval) {
        const agent = in.bus.agentOf(s.id);
        const text = asked orelse reason.text;
        if (text.len == 0) return .none;
        const how: What.Cut = if (asked != null) asked_cut else note_cut;
        switch (AgentEvent.toolKind(agent.detail.get())) {
            .shell => return .{ .form = .command, .lines = try ShellSteps.split(arena, try arena.dupe(u8, text)), .cut = how },
            .literal => return .{ .form = .code, .lines = try one(arena, text), .cut = how },
        }
    }
    if (s.kind == .needs_answer and reason.from == .raised) {
        // What the supervisor said the person is needed for, whole.
        return .{ .form = .words, .lines = try one(arena, reason.text), .cut = .none };
    }
    if (s.kind == .needs_answer) {
        // A dialog's question, whole.
        if (asked) |a| {
            if (a.len > 0) return .{ .form = .words, .lines = try one(arena, a), .cut = asked_cut };
        }
        // A question asked in prose: the paragraph its last turn ended on,
        // all of that paragraph, and said to be the end of something when
        // there was more before it.
        if (reason.from == .last_turn) {
            if (in.bus.turnOf(s.id)) |turn| {
                const para = try lastParagraph(arena, turn.text);
                if (para.text.len > 0) {
                    const shortened = turn.text_bytes > turn.text.len;
                    return .{ .form = .words, .lines = try one(arena, para.text), .cut = if (para.rest or shortened) .head else .none };
                }
            }
        }
    }
    if (reason.text.len == 0) return .none;
    // Everything else is the reason line. A last line is the end of a turn;
    // a hook's note may have been cut.
    const how: What.Cut = switch (reason.from) {
        .hook_note => note_cut,
        .hook_detail => if (noteMayBeCut(in.bus.agentOf(s.id).note.get() orelse "")) .tail else .none,
        .last_turn => how: {
            const turn = in.bus.turnOf(s.id) orelse break :how .none;
            const whole = std.mem.trim(u8, turn.text, " \t\r\n");
            break :how if (whole.len > reason.text.len) .head else .none;
        },
        .process, .clocks, .hooks, .task, .raised, .none => .none,
    };
    return .{ .form = .words, .lines = try one(arena, reason.text), .cut = how };
}

fn one(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    const lines = try arena.alloc([]const u8, 1);
    lines[0] = try arena.dupe(u8, text);
    return lines;
}

/// How long the screen has been still and the calls silent, in whole
/// minutes -- so the line changes once a minute and not otherwise.
fn clocks(arena: Allocator, in: Input, s: Attention.Status, wake: *Wake) Allocator.Error!Reason {
    const still = switch (s.screen) {
        .still_ms => |ms| ms,
        .unmeasured, .unreadable => return .none,
    };
    wake.consider(in.now_ms + (min_ms - still % min_ms));

    const silent = in.bus.callSilentMs(s.id, in.now_ms);
    const text = if (silent) |ms| text: {
        wake.consider(in.now_ms + (min_ms - ms % min_ms));
        break :text try std.fmt.allocPrint(
            arena,
            Reason.words.still_and_silent,
            .{ still / min_ms, ms / min_ms },
        );
    } else try std.fmt.allocPrint(arena, Reason.words.still, .{still / min_ms});
    return .{ .from = .clocks, .text = text, .missing = null };
}

const RowDisplay = struct { shown: Attention.Shown, word: Attention.Word };

/// What a row draws: the attention's kind, in the words of the terminal it
/// is about when that terminal has something more exact to say.
fn rowDisplay(a: Attention, about: ?Attention.Status) RowDisplay {
    var d = Attention.displayOf(a.kind);
    if (about) |s| if (a.kind == s.kind) {
        d = Attention.display(s);
    };
    return .{ .shown = d.shown, .word = d.word };
}

fn stewardOf(in: Input, name: []const u8, members: []const Id) ?Id {
    return stewardAmong(in.bus, in.chat, name, members);
}

fn stewardAmong(bus: *const Bus, chat: *const Chat, name: []const u8, members: []const Id) ?Id {
    const by = chat.createdBy(name) catch Chat.user_id;
    if (by != Chat.user_id and bus.isSupervisor(by) and
        std.mem.indexOfScalar(Id, members, by) != null) return by;
    // Nobody who made it is minding it: whoever in it is a supervisor.
    for (members) |id| {
        if (id != Chat.user_id and bus.isSupervisor(id)) return id;
    }
    return null;
}

/// The terminal that is `name`'s supervisor, by the rule the snapshot
/// uses, for whoever has to answer between two snapshots: an act that is
/// refused when a group already has one. Null when it has none, and when
/// it could not be worked out.
pub fn stewardOfGroup(arena: Allocator, bus: *const Bus, chat: *const Chat, name: []const u8) ?Id {
    const members = chat.membersOf(arena, name) catch return null;
    return stewardAmong(bus, chat, name, members);
}

/// What the control room says of `name`'s supervisor: there is one, one is
/// on its way, the last try failed, or there is none -- and what starting
/// one would use. `steward` is the answer `stewardOf` gave.
fn supervisorOf(arena: Allocator, in: Input, name: []const u8, steward: ?Id, wake: *Wake) Allocator.Error!SupervisorOut {
    const start = in.chat.startOf(name, in.now_ms);
    // Past its deadline a start reads as failed, and nothing else happens
    // at that moment to say so.
    if (start.deadline_ms) |at| wake.consider(at +| 1);

    const state: SupervisorOut.State = if (steward != null) .present else switch (start.state) {
        .none => .absent,
        .starting => .starting,
        .failed => .failed,
    };

    const last = in.chat.supervisorDirOf(name);
    const common = in.chat.commonDirOf(name);
    const cwd: struct { dir: []const u8, from: SupervisorOut.CwdFrom } = if (last.len > 0)
        .{ .dir = last, .from = .last_supervisor }
    else if (common.len > 0)
        .{ .dir = common, .from = .members }
    else if (in.home.len > 0)
        .{ .dir = in.home, .from = .home }
    else
        .{ .dir = "", .from = .none };

    return .{
        .state = state,
        .can_start = (state == .absent or state == .failed) and in.supervisor_roles.len > 0,
        .terminal = if (state == .starting or state == .failed) .opt(start.terminal) else null,
        .failed = if (state == .failed) start.failed else .none,
        .role = if (in.supervisor_roles.len > 0) try arena.dupe(u8, in.supervisor_roles[0].key) else null,
        .cwd = try arena.dupe(u8, cwd.dir),
        .cwd_from = cwd.from,
    };
}

const Pending = struct {
    row: GroupRow,
    attention: Attention,
    /// A terminal that is open and has an agent in it is a member.
    has_agent: bool,
};

/// Whether an open terminal is somebody's agent: a supervisor, a worker
/// somebody minds, or one whose agent has been heard from or is connected.
/// A plain shell that was added to a group is none of these.
fn hasAgent(in: Input, t: Terminal) bool {
    return switch (in.bus.roleOf(t.id)) {
        .supervisor, .watched => true,
        .none => in.bus.agentOf(t.id).hooks != .none or t.agent_present,
    };
}

fn pendingBefore(_: void, a: Pending, b: Pending) bool {
    if (Attention.before(a.attention, b.attention)) return true;
    if (Attention.before(b.attention, a.attention)) return false;
    return std.mem.lessThan(u8, a.row.name, b.row.name);
}

const Lone = struct {
    row: LoneRow,
    attention: Attention,
};

fn loneBefore(_: void, a: Lone, b: Lone) bool {
    return Attention.before(a.attention, b.attention);
}

fn tabBefore(_: void, a: Tab, b: Tab) bool {
    const aw = if (a.window) |w| w.id else 0;
    const bw = if (b.window) |w| w.id else 0;
    if (aw != bw) return aw < bw;
    return a.tab.id < b.tab.id;
}

fn terminalBefore(_: void, a: Terminal, b: Terminal) bool {
    return a.id < b.id;
}

/// Work the whole snapshot out. Everything in the result lives in `arena`.
fn build(arena: Allocator, in: Input) Allocator.Error!Built {
    var wake: Wake = .{ .now_ms = in.now_ms, .at = null };

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = in.chat.groups.keyIterator();
    while (it.next()) |k| try names.append(arena, k.*);

    var grouped: std.AutoHashMapUnmanaged(Id, ?u64) = .empty;
    var rows: std.ArrayListUnmanaged(Pending) = .empty;

    for (names.items) |name| {
        const all = in.chat.membersOf(arena, name) catch continue;
        const steward_id = stewardOf(in, name, all);
        const seen = in.chat.seenRunMs(name);
        const marks = in.chat.marksOf(name) catch Chat.Marks.none;
        const snooze = in.chat.snoozeOf(name, in.now_ms, in.wall_ms);

        var steward: ?Attention.Status = null;
        var workers: std.ArrayListUnmanaged(Attention.Status) = .empty;
        var members: std.ArrayListUnmanaged(Member) = .empty;
        var has_agent = false;

        for (all) |id| {
            if (id == Chat.user_id) continue;
            if (find(in.terminals, id)) |t| {
                if (hasAgent(in, t)) has_agent = true;
            }

            // Seen in any of its groups is seen, for the glyph on its tab.
            const gop = try grouped.getOrPut(arena, id);
            if (!gop.found_existing) gop.value_ptr.* = null;
            if (seen) |ms| gop.value_ptr.* = @max(gop.value_ptr.* orelse 0, ms);

            const s = statusOf(in, id, seen, &wake);
            const is_steward = steward_id != null and steward_id.? == id;
            if (is_steward) steward = s else try workers.append(arena, s);

            // A worker's first minute is its supervisor's; the row changes
            // when that minute is up.
            // (A prompt its supervisor may not answer never had that
            // minute, so there is nothing to wake for.)
            if (!is_steward and s.alive and s.duty == .on and Attention.firstMinuteIsTheSupervisors(s)) switch (s.kind) {
                .needs_approval, .failed => wake.consider(s.since_ms +| in.thresholds.bubble_after_ms +| 1),
                else => {},
            };

            const d = Attention.display(s);
            try members.append(arena, .{
                .id = .{ .id = id },
                .role = if (is_steward) .steward else .worker,
                .title = if (find(in.terminals, id)) |t| try arena.dupe(u8, t.title) else "",
                .kind = s.kind,
                .since_ms = s.since_ms,
                .source = s.source,
                .age_ms = s.age_ms,
                .shown = d.shown,
                .word = d.word,
                .text = d.word.text(),
                .screen = screenOut(s.screen),
                .alive = s.alive,
                .duty = s.duty,
                .held = s.held,
                .shielded = s.shielded,
            });
        }

        const last_ms = in.chat.lastMsOf(name);
        const a = Attention.ofGroup(.{
            .steward = steward,
            .workers = workers.items,
            .snooze = snooze,
            .last_ms = last_ms,
        }, in.thresholds, in.now_ms);
        switch (snooze) {
            .until_ms => |until| wake.consider(until),
            .none, .until_change => {},
        }

        // The terminal the row is about, and the others also waiting.
        var about: ?Attention.Status = null;
        var more: usize = 0;
        if (steward) |s| {
            if (a.terminal != null and a.terminal.? == s.id) about = s;
        }
        for (workers.items) |w| {
            if (a.terminal != null and a.terminal.? == w.id) about = w;
        }
        if (steward) |s| {
            if (waiting(s) and (about == null or about.?.id != s.id)) more += 1;
        }
        for (workers.items) |w| {
            if (waiting(w) and (about == null or about.?.id != w.id)) more += 1;
        }

        const d = rowDisplay(a, about);
        const reason: Reason = if (about != null and a.kind == about.?.kind)
            try reasonOf(arena, in, about.?, name, &wake)
        else
            .none;
        // Who is waiting: the supervisor, or one of its workers. Nobody,
        // on a row that needs nothing.
        const waiter: Waiter = if (!Attention.needsMe(a)) .none else if (about) |who| waiter: {
            if (steward_id != null and steward_id.? == who.id) break :waiter .{ .is = .supervisor, .name = "" };
            const title = if (find(in.terminals, who.id)) |t| try arena.dupe(u8, t.title) else "";
            break :waiter .{ .is = if (steward_id != null) .worker_via_supervisor else .worker, .name = title };
        } else .none;
        try rows.append(arena, .{
            .attention = a,
            .has_agent = has_agent,
            .row = .{
                .name = try arena.dupe(u8, name),
                .brief = try arena.dupe(u8, in.chat.briefOf(name) catch ""),
                .last_ms = last_ms,
                .seen_ms = marks.seen_ms,
                .snooze = .of(marks.snooze),
                .steward = .opt(steward_id),
                .supervisor = try supervisorOf(arena, in, name, steward_id, &wake),
                .attention = .of(a, in.bus),
                .needs_me = Attention.needsMe(a),
                // **Looking at this row changes it**: it stopped and nobody has
                // looked, or its supervisor raised it "until they have looked".
                // A host starts its "seen" clock on this and on nothing else, so
                // a raise that did not say so here could never be withdrawn --
                // which is what it was (the Windows machine, 2026-10-13: five
                // seconds on the row, in front, and no `seen` was ever sent).
                //
                // **Wherever in the row the raise is.** This asked whether
                // the raise was the row's reason, so one standing behind a
                // worker's prompt -- "1 more" -- was never looked at however
                // long the person looked (the same machine, the same day:
                // eight seconds, in front, and it stayed until the end).
                .unseen = Attention.unseen(a) or raiseStandsIn(in, steward, workers.items),
                .shown = d.shown,
                .word = d.word,
                .text = d.word.text(),
                .waiter = waiter,
                .reason = reason,
                .what = if (about) |who| try whatOf(arena, in, who, reason) else .none,
                .more = more,
                .same_as = null,
                .members = members.items,
            },
        });
    }

    std.mem.sort(Pending, rows.items, {}, pendingBefore);

    // One supervisor, several groups: the one spoken in last carries the
    // reason, the others point at it (4.4). 暂定: "spoken in last" is the
    // group's last message, not that supervisor's own.
    for (rows.items, 0..) |*r, i| {
        if (r.attention.what != .own) continue;
        const t = r.attention.terminal orelse continue;
        // The first of them in the list leads unless a later one was
        // spoken in more recently. Starting from this row instead would
        // leave two groups nobody has spoken in each leading itself, and
        // neither pointing at the other.
        var lead: ?usize = null;
        for (rows.items, 0..) |o, j| {
            if (o.attention.what != .own or o.attention.terminal == null) continue;
            if (o.attention.terminal.? != t) continue;
            if (lead == null or o.row.last_ms > rows.items[lead.?].row.last_ms) lead = j;
        }
        if (lead.? != i) r.row.same_as = rows.items[lead.?].row.name;
    }

    // Terminals on their own (4.6): a supervisor with no group, and an
    // agent nobody is minding.
    var lone: std.ArrayListUnmanaged(Lone) = .empty;
    const sorted = try arena.dupe(Terminal, in.terminals);
    std.mem.sort(Terminal, sorted, {}, terminalBefore);

    var terminals: std.ArrayListUnmanaged(TerminalOut) = .empty;
    var statuses: std.ArrayListUnmanaged(Attention.Status) = .empty;
    for (sorted) |t| {
        const in_group = grouped.get(t.id);
        // In a group: looked at through its group. On its own: through its
        // own row (`Bus.markSeen`).
        const s = statusOf(in, t.id, if (in_group) |seen| seen else in.bus.seenOf(t.id), &wake);
        try statuses.append(arena, s);

        const d = Attention.display(s);
        try terminals.append(arena, .{
            .id = .{ .id = t.id },
            .title = try arena.dupe(u8, t.title),
            .window = .opt(t.window),
            .tab = .opt(t.tab),
            .pane = .of(in.bus.roleOf(t.id)),
            .kind = s.kind,
            .since_ms = s.since_ms,
            .event_ms = in.bus.agentOf(t.id).last_event_ms,
            .source = s.source,
            .age_ms = s.age_ms,
            .shown = d.shown,
            .word = d.word,
            .text = d.word.text(),
            .screen = screenOut(s.screen),
            .alive = s.alive,
            .duty = s.duty,
            .held = s.held,
            .shielded = s.shielded,
        });

        if (in_group != null) continue;
        // A supervisor with no group, a worker somebody minds outside any
        // group, and an agent nobody minds at all.
        const alone = hasAgent(in, t);
        if (!alone) continue;

        const a = Attention.ofTerminal(s);
        const rd = rowDisplay(a, s);
        const reason: Reason = if (a.kind == s.kind) try reasonOf(arena, in, s, null, &wake) else .none;
        try lone.append(arena, .{
            .attention = a,
            .row = .{
                .id = .{ .id = t.id },
                .title = try arena.dupe(u8, t.title),
                .attention = .of(a, in.bus),
                .needs_me = Attention.needsMe(a),
                // As for a group's row: looking at it changes it.
                .unseen = Attention.unseen(a) or reason.from == .raised,
                .shown = rd.shown,
                .word = rd.word,
                .text = rd.word.text(),
                .waiter = if (Attention.needsMe(a)) .{ .is = .terminal, .name = "" } else .none,
                .reason = reason,
                .what = try whatOf(arena, in, s, reason),
            },
        });
    }
    std.mem.sort(Lone, lone.items, {}, loneBefore);

    // One glyph per window tab: the highest of what is in it.
    var tabs: std.ArrayListUnmanaged(Tab) = .empty;
    for (sorted) |t| {
        const tab = t.tab orelse continue;
        const known = for (tabs.items) |have| {
            if (have.tab.id == tab and (if (have.window) |w| w.id else null) == t.window) break true;
        } else false;
        if (known) continue;

        var inside: std.ArrayListUnmanaged(Attention.Status) = .empty;
        for (sorted, statuses.items) |o, s| {
            if (o.tab != null and o.tab.? == tab and o.window == t.window) try inside.append(arena, s);
        }
        const top = Attention.top(inside.items, .window_tab);
        try tabs.append(arena, .{
            .window = .opt(t.window),
            .tab = .{ .id = tab },
            .shown = top.shown,
            .terminal = if (top.index) |i| .{ .id = inside.items[i].id } else null,
        });
    }
    std.mem.sort(Tab, tabs.items, {}, tabBefore);

    // Which waiting glyph breathes: the order to pick it from.
    var waiting_now: std.ArrayListUnmanaged(usize) = .empty;
    for (statuses.items, 0..) |s, i| {
        if (Attention.display(s).shown == .needs_you) try waiting_now.append(arena, i);
    }
    std.mem.sort(usize, waiting_now.items, statuses.items, struct {
        fn lt(all: []const Attention.Status, a: usize, b: usize) bool {
            if (all[a].since_ms != all[b].since_ms) return all[a].since_ms < all[b].since_ms;
            return all[a].id < all[b].id;
        }
    }.lt);
    const pulses = try arena.alloc(Pulse, waiting_now.items.len);
    for (waiting_now.items, pulses) |i, *p| {
        const t = sorted[i];
        p.* = .{
            .terminal = .{ .id = t.id },
            .window = .opt(t.window),
            .tab = .opt(t.tab),
            .group = for (rows.items) |r| {
                if (r.row.same_as != null) continue;
                if (r.attention.terminal != null and r.attention.terminal.? == t.id) break r.row.name;
            } else null,
        };
    }

    // Where a control room opens: the first group with an agent in it,
    // and the first group at all when they are all empty.
    const open_on: ?[]const u8 = for (rows.items) |r| {
        if (r.has_agent) break r.row.name;
    } else if (rows.items.len > 0) rows.items[0].row.name else null;

    // The counts. **One meaning for every number the person is shown**:
    // a row that waits is one, whether it is a group's or a lone
    // terminal's. So `needs_me` -- the Dock -- is `groups_needing_me` --
    // the list's header -- plus the lone terminals that wait, and with no
    // lone terminal waiting the two are the same number.
    //
    // It used to count the terminals behind the rows, each once, so that
    // one supervisor minding three groups was 1. On a real window that
    // read as four rows under "4 groups waiting for you" and a 3 on the
    // Dock, with no way to tell which was right (verify-cr-03). 暂定.
    var needing: usize = 0;
    const group_rows = try arena.alloc(GroupRow, rows.items.len);
    for (rows.items, group_rows) |r, *out| {
        out.* = r.row;
        if (r.row.needs_me) needing += 1;
    }
    var lone_needing: usize = 0;
    const lone_rows = try arena.alloc(LoneRow, lone.items.len);
    for (lone.items, lone_rows) |r, *out| {
        out.* = r.row;
        if (r.row.needs_me) lone_needing += 1;
    }

    // The allowance counts on the wall clock, since that is the clock its
    // resets are on; the wake is on the bus's. A machine that slept wakes
    // late for these, and catches up on the next thing that happens.
    const allowance = try quota.build(arena, in.quota, in.wall_ms);
    if (allowance.wake_ms) |at| wake.consider(in.now_ms +| (at -| in.wall_ms));

    return .{
        .snapshot = .{
            .rev = 0,
            .now_ms = in.now_ms,
            .needs_me = needing + lone_needing,
            .groups_needing_me = needing,
            .groups_other = group_rows.len - needing,
            .header_waiting = .over(needing, lone_needing),
            .header_quiet = .over(group_rows.len - needing, lone_rows.len - lone_needing),
            .open_on = open_on,
            .groups = group_rows,
            .ungrouped = lone_rows,
            .terminals = terminals.items,
            .tabs = tabs.items,
            .supervisor_roles = roles: {
                const out = try arena.alloc(SupervisorRole, in.supervisor_roles.len);
                for (in.supervisor_roles, out) |r, *o| o.* = .{
                    .key = try arena.dupe(u8, r.key),
                    .name = try arena.dupe(u8, r.name),
                };
                break :roles out;
            },
            .choose_supervisor_role = in.supervisor_roles.len > 1,
            .pulses = pulses,
            .quota = allowance.out,
        },
        .wake_ms = wake.at,
    };
}

/// A terminal that is itself waiting on the person.
fn waiting(s: Attention.Status) bool {
    return s.alive and s.duty == .on and s.kind.needsMe();
}

/// Whether this terminal is waiting on something it raised (`Bus.raise`)
/// and the person has not looked at since. The same question `reasonOf`
/// asks before it takes the raise's words, and `statusOf` is what decided
/// it: a status is a self-reported "needs an answer" because a raise
/// stands.
fn raiseStands(in: Input, s: Attention.Status) bool {
    if (!waiting(s)) return false;
    if (s.kind != .needs_answer or s.source != .self_report) return false;
    return in.bus.raisedOf(s.id, null) != null;
}

/// Whether anything in a group's row is: its supervisor or any worker,
/// whichever of them the row happens to be about.
fn raiseStandsIn(in: Input, steward: ?Attention.Status, workers: []const Attention.Status) bool {
    if (steward) |s| if (raiseStands(in, s)) return true;
    for (workers) |w| if (raiseStands(in, w)) return true;
    return false;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const T = Attention.Thresholds.defaults;

/// A bus and a chat with terminals in them, and the list of what is open.
const World = struct {
    bus: Bus,
    chat: Chat,
    tasks: Tasks,
    open: std.ArrayListUnmanaged(Terminal) = .empty,
    wall_ms: u64 = 1_700_000_000_000,
    quota: []const quota.Reading = &.{},
    roles: []const SupervisorRole = &.{.{ .key = "polter-supervisor", .name = "Polter Supervisor" }},
    home: []const u8 = "/Users/me",

    fn init() World {
        return .{
            .bus = .init(testing.allocator, .{}),
            .chat = .init(testing.allocator, .{}),
            .tasks = .init(testing.allocator, .{}),
        };
    }

    fn deinit(self: *World) void {
        self.open.deinit(testing.allocator);
        self.tasks.deinit();
        self.chat.deinit();
        self.bus.deinit();
    }

    /// An approval asked through a tool: the tool's name, the one-line
    /// summary a hook cuts, and the whole of what is to be approved.
    fn approval(self: *World, id: Id, tool: []const u8, asked: []const u8, at_ms: u64) !void {
        var ev: AgentEvent.Event = .none;
        ev.event = .awaiting_approval;
        ev.cli = "claude-code";
        ev.session_id = "s";
        ev.detail = tool;
        ev.note = AgentEvent.cutBytes(asked, 120);
        ev.text = asked;
        ev.text_bytes = asked.len;
        _ = try self.bus.agentEvent(id, ev, at_ms);
    }

    /// A task of `group` that `owner` has started.
    fn working(self: *World, group: []const u8, owner: Id, title: []const u8) !void {
        const id = try self.tasks.create(group, title, .feature);
        try self.tasks.assign(id, owner);
        try self.tasks.setProgress(id, owner, .working);
    }

    fn terminal(self: *World, id: Id, title: []const u8, tab: u64) !void {
        try self.bus.register(id);
        try self.open.append(testing.allocator, .{
            .id = id,
            .title = title,
            .window = 0x10,
            .tab = tab,
            .process = .running,
            .agent_present = false,
            .still_ms = null,
        });
    }

    fn steward(self: *World, id: Id, title: []const u8, tab: u64, group: []const u8) !void {
        try self.terminal(id, title, tab);
        try self.bus.addSupervisor(id);
        try self.chat.create(group, id);
    }

    fn worker(self: *World, id: Id, title: []const u8, tab: u64, boss: Id, group: []const u8) !void {
        try self.terminal(id, title, tab);
        try self.bus.watch(id, boss);
        try self.chat.add(group, id, .all, .{});
    }

    fn hook(self: *World, id: Id, kind: AgentEvent.Kind, note: ?[]const u8, at_ms: u64) !void {
        var ev: AgentEvent.Event = .none;
        ev.event = kind;
        ev.cli = "claude-code";
        ev.session_id = "s";
        ev.note = note;
        if (kind == .turn_ended) {
            ev.text = note;
            ev.text_bytes = if (note) |n| n.len else 0;
            ev.note = null;
        }
        _ = try self.bus.agentEvent(id, ev, at_ms);
    }

    fn input(self: *const World, now_ms: u64) Input {
        return .{
            .bus = &self.bus,
            .chat = &self.chat,
            .terminals = self.open.items,
            .thresholds = T,
            .tasks = &self.tasks,
            .quota = self.quota,
            .supervisor_roles = self.roles,
            .home = self.home,
            .now_ms = now_ms,
            .wall_ms = self.wall_ms + now_ms,
        };
    }
};

const min = std.time.ms_per_min;

/// Seven groups, one of each thing a row can say, and an eighth that shares
/// its supervisor with the first.
fn fixtureWorld() !World {
    var w: World = .init();
    errdefer w.deinit();

    // Waiting on an approval of three steps; a worker also waiting.
    try w.steward(0xa1, "web-app", 0x21, "web-app");
    try w.approval(0xa1, "Bash", "rm -rf dist/ .cache/ node_modules/.vite && npm ci && npm run build -- --mode production", 96 * min);
    try w.worker(0xb1, "web-app worker", 0x21, 0xa1, "web-app");
    try w.approval(0xb1, "Edit", "src/app.ts", 99 * min + 30_000);

    // The same supervisor minds a second group, spoken in more recently.
    try w.chat.create("web-app-docs", 0xa1);
    _ = try w.chat.post("web-app-docs", 0xa1, "docs next", 1_700_000_000_000);

    // Waiting on an answer.
    try w.steward(0xa2, "billing", 0x22, "billing");
    try w.hook(0xa2, .awaiting_input, "发票编号要按租户分开，还是全局连续？分开的话，旧发票要不要一起改编号？", 89 * min);

    // Failed.
    try w.steward(0xa3, "docs-site", 0x23, "docs-site");
    var failed: AgentEvent.Event = .none;
    failed.event = .turn_failed;
    failed.detail = "rate_limit";
    failed.note = "resets 13:40";
    _ = try w.bus.agentEvent(0xa3, failed, 98 * min);

    // A worker waiting, and its supervisor not: the wait comes up through
    // the supervisor.
    try w.steward(0xa7, "mobile", 0x28, "mobile");
    try w.hook(0xa7, .session_started, null, 20 * min);
    try w.worker(0xb7, "ios-build", 0x28, 0xa7, "mobile");
    try w.approval(0xb7, "Bash", "git push --force-with-lease origin release/2.4", 97 * min);

    // Finished a turn nobody has looked at.
    try w.steward(0xa4, "infra", 0x24, "infra");
    try w.hook(0xa4, .turn_ended, "迁移脚本跑完了。\n要不要现在切流量？", 70 * min);

    // Working on a task of its own, with a worker that clocked off.
    try w.steward(0xa5, "design-system", 0x25, "design-system");
    try w.hook(0xa5, .turn_started, null, 95 * min);
    try w.working("design-system", 0xa5, "改按钮的三种尺寸");
    try w.worker(0xb5, "tokens", 0x25, 0xa5, "design-system");
    try w.bus.clockOff(0xb5, .supervisor);

    // Idle.
    try w.steward(0xa6, "notes", 0x26, "notes");
    try w.hook(0xa6, .session_started, null, 10 * min);

    // On its own: an agent with hooks that nobody minds, waiting.
    try w.terminal(0xc1, "zsh — ~/work", 0x27);
    try w.approval(0xc1, "Bash", "git push", 99 * min);
    // And a plain shell, which is in no list but `terminals`.
    try w.terminal(0xc2, "zsh", 0x27);

    // One account close to its limit and one with room.
    w.quota = &fixture_quota;

    return w;
}

const fixture_wall: u64 = 1_700_000_000_000 + fixture_now;
const fixture_quota = [_]quota.Reading{
    .{
        .family = .claude,
        .state = .have,
        .windows = .{
            .{ .span = .five_hour, .used = 92, .resets_ms = fixture_wall + 40 * min },
            .{ .span = .seven_day, .used = 30, .resets_ms = fixture_wall + 3 * std.time.ms_per_day },
        },
        .at_ms = fixture_wall - 2 * min,
    },
    .{
        .family = .codex,
        .state = .have,
        .windows = .{
            .{ .span = .five_hour, .used = 20, .resets_ms = fixture_wall + 2 * std.time.ms_per_hour },
            null,
        },
        .at_ms = fixture_wall - 5 * min,
    },
};

fn fixtureRoom(w: *const World) !ControlRoom {
    _ = w;
    return .init(testing.allocator);
}

const fixture_now: u64 = 100 * min;
const fixture_json = @embedFile("testdata/control_snapshot.json");
const pretty: std.json.Stringify.Options = .{ .whitespace = .indent_2 };

fn rowNamed(s: Snapshot, name: []const u8) !GroupRow {
    for (s.groups) |g| if (std.mem.eql(u8, g.name, name)) return g;
    return error.TestRowMissing;
}

test "ControlRoom snapshot: the fixture is what the fixture's world comes to" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var room = try fixtureRoom(&w);
    defer room.deinit();
    var built = try room.compute(arena.allocator(), w.input(fixture_now));
    built.snapshot.rev = 1;
    const json = try writeAlloc(arena.allocator(), built.snapshot, pretty);
    const want = std.mem.trimEnd(u8, fixture_json, "\n");
    if (!std.mem.eql(u8, want, json)) {
        std.debug.print("\n<<<control_snapshot.json\n{s}\n>>>control_snapshot.json\n", .{json});
        return error.TestFixtureOutOfDate;
    }
}

test "ControlRoom snapshot: the JSON reads back and writes out the same" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const want = std.mem.trimEnd(u8, fixture_json, "\n");
    const read = try std.json.parseFromSliceLeaky(Snapshot, arena.allocator(), want, .{});
    try testing.expectEqualStrings(want, try writeAlloc(arena.allocator(), read, pretty));

    // And it is the document a host would be handed, not an empty one.
    try testing.expectEqual(@as(usize, 8), read.groups.len);
    try testing.expectEqual(@as(u64, 0xa1), read.groups[0].steward.?.id);
}

test "ControlRoom snapshot: rows come sorted, counted, and with what they draw" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    const order = [_][]const u8{ "web-app", "web-app-docs", "mobile", "billing", "docs-site", "infra", "design-system", "notes" };
    try testing.expectEqual(order.len, s.groups.len);
    for (order, s.groups) |name, g| try testing.expectEqualStrings(name, g.name);

    const kinds = [_]Attention.Kind{ .needs_approval, .needs_approval, .needs_approval, .needs_answer, .failed, .done_unseen, .working, .idle };
    const shown = [_]Attention.Shown{ .needs_you, .needs_you, .needs_you, .needs_you, .trouble, .done_unseen, .working, .none };
    for (kinds, shown, s.groups) |k, sh, g| {
        try testing.expectEqual(k, g.attention.kind);
        try testing.expectEqual(sh, g.shown);
        try testing.expectEqualStrings(g.word.text(), g.text);
    }

    try testing.expectEqual(@as(usize, 5), s.groups_needing_me);
    try testing.expectEqual(@as(usize, 3), s.groups_other);
}

test "ControlRoom snapshot: one supervisor in two groups is two rows, and one of them points at the other" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    // Five groups wait and one lone terminal does: six rows, and six on
    // the Dock. 0xa1 is behind two of them and is counted with each.
    try testing.expectEqual(@as(usize, 5), s.groups_needing_me);
    try testing.expectEqual(@as(usize, 1), s.ungrouped.len);
    try testing.expect(s.ungrouped[0].needs_me);
    try testing.expectEqual(@as(usize, 6), s.needs_me);

    // The row spoken in last carries the reason; the other points at it.
    const main = try rowNamed(s, "web-app");
    const docs = try rowNamed(s, "web-app-docs");
    try testing.expectEqualStrings("web-app-docs", main.same_as.?);
    try testing.expectEqual(@as(?[]const u8, null), docs.same_as);
    try testing.expectEqual(main.attention.terminal.?.id, docs.attention.terminal.?.id);
}

test "ControlRoom snapshot: the number on the Dock is the number of rows that wait" {
    // What a real window showed (verify-cr-03): four rows under "4 groups
    // waiting for you" and a 3 on the Dock. One supervisor minds two groups
    // and has failed; another group's supervisor and its worker have both
    // failed; a fourth group's only member has.
    var w: World = .init();
    defer w.deinit();
    var failed: AgentEvent.Event = .none;
    failed.event = .turn_failed;
    failed.detail = "rate_limit";
    try w.steward(0xa1, "A", 0x21, "docs-site");
    try w.chat.create("web-app", 0xa1);
    try w.steward(0xa2, "B", 0x22, "billing");
    try w.worker(0xb3, "W3", 0x23, 0xa2, "billing");
    try w.chat.create("notes", Chat.user_id);
    try w.terminal(0xd1, "N1", 0x24);
    try w.bus.watch(0xd1, 0xa2);
    try w.chat.add("notes", 0xd1, .all, .{});
    for ([_]Id{ 0xa1, 0xa2, 0xb3, 0xd1 }) |id| _ = try w.bus.agentEvent(id, failed, 10 * min);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(100 * min))).snapshot;

    var rows: usize = 0;
    for (s.groups) |g| {
        if (g.needs_me) rows += 1;
    }
    try testing.expectEqual(@as(usize, 4), rows);
    try testing.expectEqual(@as(usize, 4), s.groups_needing_me);
    // **The one meaning**: every row the person is shown as waiting, a
    // group's or a lone terminal's, is one.
    try testing.expectEqual(@as(usize, 4), s.needs_me);

    // Two rows, one supervisor, neither group spoken in: one of the two
    // still points at the other.
    const docs = try rowNamed(s, "docs-site");
    const web = try rowNamed(s, "web-app");
    try testing.expectEqual(docs.attention.terminal.?.id, web.attention.terminal.?.id);
    try testing.expect((docs.same_as == null) != (web.same_as == null));
}

test "ControlRoom snapshot: the reason line, and which kind of missing when there is none" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // An approval whose hook said nothing about what for.
    try w.steward(0xaa, "quiet", 0x2a, "quiet");
    try w.hook(0xaa, .awaiting_approval, null, 99 * min);
    // A turn that ended with no text kept.
    try w.steward(0xab, "silent", 0x2b, "silent");
    try w.hook(0xab, .turn_ended, null, 99 * min);

    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    const approval = (try rowNamed(s, "web-app-docs")).reason;
    try testing.expectEqual(Reason.From.hook_note, approval.from);
    // The hook's one-line summary: the first 120 bytes of the command.
    try testing.expectEqualStrings("rm -rf dist/ .cache/ node_modules/.vite && npm ci && npm run build -- --mode production", approval.text);

    try testing.expectEqualStrings("发票编号要按租户分开，还是全局连续？分开的话，旧发票要不要一起改编号？", (try rowNamed(s, "billing")).reason.text);
    try testing.expectEqualStrings("rate_limit：resets 13:40", (try rowNamed(s, "docs-site")).reason.text);
    // The last thing it said, which is where a question in prose is.
    try testing.expectEqualStrings("要不要现在切流量？", (try rowNamed(s, "infra")).reason.text);
    // What a working group says it is doing is the panel's word for it.
    const doing = (try rowNamed(s, "design-system")).reason;
    try testing.expectEqual(Reason.From.task, doing.from);
    try testing.expectEqualStrings("改按钮的三种尺寸", doing.text);
    try testing.expectEqual(Reason.none, (try rowNamed(s, "notes")).reason);

    const quiet = (try rowNamed(s, "quiet")).reason;
    try testing.expectEqualStrings("", quiet.text);
    try testing.expectEqual(@as(?Reason.Missing, .empty_note), quiet.missing);
    try testing.expectEqual(@as(?Reason.Missing, .no_turn_kept), (try rowNamed(s, "silent")).reason.missing);
}

test "ControlRoom snapshot: how many more are waiting, and a worker bubbling up" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The supervisor and its worker are both waiting: one more.
    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;
    try testing.expectEqual(@as(usize, 1), (try rowNamed(s, "web-app")).more);
    try testing.expectEqual(@as(usize, 0), (try rowNamed(s, "billing")).more);

    // A worker of a busy supervisor fails; a minute later the row is its.
    try w.worker(0xb6, "tokens-2", 0x25, 0xa5, "design-system");
    try w.hook(0xb6, .turn_failed, "boom", fixture_now);
    var at: u64 = fixture_now + 1_000;
    const early = try build(arena.allocator(), w.input(at));
    try testing.expectEqual(Attention.Kind.working, (try rowNamed(early.snapshot, "design-system")).attention.kind);
    // And the core knows to look again exactly when the minute is up:
    // following its own wake times lands on that moment, not past it.
    var wake = early.wake_ms;
    while (wake != null and wake.? < fixture_now + 60_001) {
        at = wake.?;
        wake = (try build(arena.allocator(), w.input(at))).wake_ms;
    }
    try testing.expectEqual(@as(?u64, fixture_now + 60_001), wake);

    const late = (try build(arena.allocator(), w.input(fixture_now + 60_001))).snapshot;
    const row = try rowNamed(late, "design-system");
    try testing.expectEqual(Attention.Kind.failed, row.attention.kind);
    try testing.expectEqual(@as(u64, 0xb6), row.attention.worker.?.id);
    try testing.expectEqualStrings("boom", row.reason.text);
}

test "ControlRoom snapshot: each window tab gets the highest glyph of what is in it" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    const Want = struct { u64, Attention.Shown, ?u64 };
    const wants = [_]Want{
        .{ 0x21, .needs_you, 0xa1 }, // supervisor and worker both waiting: the longer
        .{ 0x22, .needs_you, 0xa2 },
        .{ 0x23, .trouble, 0xa3 },
        .{ 0x24, .done_unseen, 0xa4 },
        .{ 0x25, .none, null }, // working is not drawn on a window tab
        .{ 0x26, .none, null },
        .{ 0x27, .needs_you, 0xc1 },
        .{ 0x28, .needs_you, 0xb7 }, // the worker waits; its supervisor does not
    };
    try testing.expectEqual(wants.len, s.tabs.len);
    for (wants, s.tabs) |want, tab| {
        try testing.expectEqual(want[0], tab.tab.id);
        try testing.expectEqual(want[1], tab.shown);
        try testing.expectEqual(want[2], if (tab.terminal) |t| t.id else null);
    }
    try testing.expectEqual(w.open.items.len, s.terminals.len);
}

test "ControlRoom snapshot: what a supervisor raises is waiting for the person at once, in its words, until they look" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "api", 0x21, "api");
    try w.hook(0xa1, .turn_started, null, 10 * min);
    try w.worker(0xb1, "api worker", 0x21, 0xa1, "api");
    // The worker stops on a prompt; inside its first minute the group is
    // still the supervisor's business and the row says working.
    try w.approval(0xb1, "Bash", "git push --force", 20 * min);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const at = 20 * min + 5_000;
    {
        const row = try rowNamed((try build(arena.allocator(), w.input(at))).snapshot, "api");
        try testing.expect(!row.needs_me);
    }

    // The supervisor reads it, decides it is the person's, and says so.
    const said = "api worker wants to force-push main: yours to decide";
    try testing.expect(try w.bus.raise(0xa1, at, said));
    {
        const s = (try build(arena.allocator(), w.input(at + 1))).snapshot;
        const row = try rowNamed(s, "api");
        try testing.expect(row.needs_me);
        // And looking at it is what withdraws it, so the row says so: this
        // is what a host starts its "seen" clock on.
        try testing.expect(row.unseen);
        try testing.expectEqual(Attention.Kind.needs_answer, row.attention.kind);
        try testing.expectEqual(Waiter.Is.supervisor, row.waiter.is);
        try testing.expectEqual(Reason.From.raised, row.reason.from);
        try testing.expectEqualStrings(said, row.reason.text);
        try testing.expectEqual(What.Form.words, row.what.form);
        try testing.expectEqual(@as(usize, 1), row.what.lines.len);
        try testing.expectEqualStrings(said, row.what.lines[0]);
        try testing.expectEqual(@as(usize, 1), s.groups_needing_me);
    }

    // It does not lapse because the supervisor's turn ended after it spoke
    // -- which is what a supervisor does next.
    try w.hook(0xa1, .turn_ended, "told the person", at + 2_000);
    {
        const row = try rowNamed((try build(arena.allocator(), w.input(at + 3_000))).snapshot, "api");
        try testing.expect(row.needs_me);
        try testing.expectEqual(Reason.From.raised, row.reason.from);
    }

    // The person looks. What is left is what is actually so: the worker's
    // prompt, still inside its first minute, and a supervisor that is done.
    try w.chat.markSeen("api", at + 4_000, w.wall_ms + at + 4_000);
    {
        const row = try rowNamed((try build(arena.allocator(), w.input(at + 5_000))).snapshot, "api");
        try testing.expect(row.reason.from != .raised);
        try testing.expect(row.attention.kind != .needs_answer);
        // Nothing left for looking to change: a worker's prompt is not
        // withdrawn by being looked at.
        try testing.expect(!row.unseen);
    }

    // A terminal the bus does not know raises nothing.
    try testing.expect(!try w.bus.raise(0xdead, at, "x"));
}

test "ControlRoom snapshot: a raise standing behind a worker's prompt is still withdrawn by looking" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "api", 0x21, "api");
    try w.hook(0xa1, .turn_started, null, 10 * min);
    try w.worker(0xb1, "api worker", 0x21, 0xa1, "api");
    // The worker's prompt has had its minute: the row is about it.
    try w.approval(0xb1, "Bash", "git push --force", 20 * min);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const at = 21 * min + 5_000;
    {
        const row = try rowNamed((try build(arena.allocator(), w.input(at))).snapshot, "api");
        try testing.expect(row.needs_me);
        try testing.expectEqual(Attention.Kind.needs_approval, row.attention.kind);
        try testing.expectEqual(@as(usize, 0), row.more);
        // A prompt is not withdrawn by being looked at.
        try testing.expect(!row.unseen);
    }

    // Now the supervisor raises it as well. The row stays about the prompt;
    // the raise is the "1 more".
    try testing.expect(try w.bus.raise(0xa1, at, "the worker has waited a minute: yours"));
    {
        const row = try rowNamed((try build(arena.allocator(), w.input(at + 1))).snapshot, "api");
        try testing.expectEqual(Attention.Kind.needs_approval, row.attention.kind);
        try testing.expect(row.reason.from != .raised);
        try testing.expectEqual(@as(usize, 1), row.more);
        // Looking changes this row, and it says so.
        try testing.expect(row.unseen);
    }

    // The person looks: the raise goes, the prompt stays.
    try w.chat.markSeen("api", at + 4_000, w.wall_ms + at + 4_000);
    {
        const row = try rowNamed((try build(arena.allocator(), w.input(at + 5_000))).snapshot, "api");
        try testing.expectEqual(Attention.Kind.needs_approval, row.attention.kind);
        try testing.expect(row.needs_me);
        try testing.expectEqual(@as(usize, 0), row.more);
        try testing.expect(!row.unseen);
    }
}

test "ControlRoom snapshot: a prompt the supervisor may not answer is the person's without the minute" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "api", 0x21, "api");
    try w.hook(0xa1, .turn_started, null, 10 * min);
    try w.worker(0xb1, "api worker", 0x21, 0xa1, "api");
    try w.approval(0xb1, "Bash", "npm ci", 20 * min);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const at = 20 * min + 5_000;

    // Allowed, the default: the supervisor's minute, and the core asks to
    // be woken when it is up.
    {
        const b = try build(arena.allocator(), w.input(at));
        try testing.expect(!(try rowNamed(b.snapshot, "api")).needs_me);
        try testing.expectEqual(@as(?u64, 20 * min + T.bubble_after_ms + 1), b.wake_ms);
    }

    // The person switches it off for that terminal: it is theirs now.
    try w.bus.setMayAuthorise(0xb1, false, .user);
    {
        const b = try build(arena.allocator(), w.input(at));
        const row = try rowNamed(b.snapshot, "api");
        try testing.expect(row.needs_me);
        try testing.expectEqual(Attention.Kind.needs_approval, row.attention.kind);
        try testing.expectEqual(Waiter.Is.worker_via_supervisor, row.waiter.is);
        // And nothing is waited for: there was no minute.
        try testing.expect(b.wake_ms == null or b.wake_ms.? != 20 * min + T.bubble_after_ms + 1);
    }
}

test "ControlRoom snapshot: seen in a group takes its finished turn off the list" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try w.chat.markSeen("infra", fixture_now, w.wall_ms + fixture_now);
    const s = (try build(arena.allocator(), w.input(fixture_now + 1))).snapshot;
    const row = try rowNamed(s, "infra");
    try testing.expectEqual(Attention.Kind.idle, row.attention.kind);
    try testing.expectEqual(@as(?u64, w.wall_ms + fixture_now), row.seen_ms);
    // And the tab it is in stops carrying the dot.
    for (s.tabs) |tab| {
        if (tab.tab.id == 0x24) try testing.expectEqual(Attention.Shown.none, tab.shown);
    }
}

test "ControlRoom snapshot: a timed snooze ends on its own, and the core knows when" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const wall = w.wall_ms + fixture_now;
    try w.chat.setSnooze("billing", .{ .until = .{ .at_ms = wall, .until_ms = wall + 20_000 } }, fixture_now);

    const during = try build(arena.allocator(), w.input(fixture_now));
    const row = try rowNamed(during.snapshot, "billing");
    try testing.expectEqual(Attention.Kind.snoozed, row.attention.kind);
    try testing.expect(!row.needs_me);
    try testing.expectEqual(@as(usize, 5), during.snapshot.needs_me);
    try testing.expectEqual(@as(?u64, fixture_now + 20_000), during.wake_ms);

    const after = try build(arena.allocator(), w.input(fixture_now + 20_000));
    try testing.expectEqual(Attention.Kind.needs_answer, (try rowNamed(after.snapshot, "billing")).attention.kind);
}

test "ControlRoom rev: standing still does not change it" {
    var w = try fixtureWorld();
    defer w.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    const first = try room.refresh(w.input(fixture_now), .event);
    try testing.expectEqual(@as(?u64, 1), first.notify);
    try testing.expectEqual(@as(u64, 1), room.rev);

    // Later in the same minute: every age has grown and nothing happened.
    const again = try room.refresh(w.input(fixture_now + 20_000), .event);
    try testing.expectEqual(@as(u64, 1), room.rev);
    try testing.expectEqual(@as(?u64, null), again.notify);
    // The JSON a host would fetch is current all the same.
    try testing.expect(std.mem.indexOf(u8, room.json, "\"now_ms\":6020000") != null);

    // Something does happen.
    try w.hook(0xa5, .awaiting_approval, "Bash(ls)", fixture_now + 21_000);
    const changed = try room.refresh(w.input(fixture_now + 21_000), .event);
    try testing.expectEqual(@as(u64, 2), room.rev);
    try testing.expectEqual(@as(?u64, 2), changed.notify);
}

test "ControlRoom rev: ten changes in a second are at most four notices" {
    var w = try fixtureWorld();
    defer w.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    var notices: usize = 0;
    var last_rev: u64 = 0;
    var t: u64 = fixture_now;
    var changes: usize = 0;
    // One change every 100 ms, and the timer honoured in between.
    while (t < fixture_now + 1_000) : (t += 10) {
        var out: Outcome = .{ .notify = null, .wake_ms = room.wake_ms };
        if ((t - fixture_now) % 100 == 0) {
            const kind: AgentEvent.Kind = if (changes % 2 == 0) .awaiting_approval else .turn_started;
            try w.hook(0xa6, kind, "Bash(x)", t);
            changes += 1;
            out = try room.refresh(w.input(t), .event);
        } else if (room.wake_ms != null and t >= room.wake_ms.?) {
            out = try room.refresh(w.input(t), .timer);
        }
        if (out.notify) |rev| {
            notices += 1;
            last_rev = rev;
        }
    }
    try testing.expectEqual(@as(usize, 10), changes);
    try testing.expect(notices <= 4);
    try testing.expectEqual(@as(usize, 4), notices);

    // Nothing is lost by waiting: the last word goes out once the gap ends.
    const tail = try room.refresh(w.input(fixture_now + 1_000), .timer);
    try testing.expectEqual(@as(?u64, room.rev), tail.notify);
    try testing.expect(room.rev > last_rev);
}

test "ControlRoom wake: when nothing can change on its own, nothing wakes" {
    var w: World = .init();
    defer w.deinit();
    // An approval that is snoozed until it changes, a finished turn, an
    // idle agent, a plain shell: only an event moves any of them.
    try w.steward(0xa1, "one", 0x21, "one");
    try w.hook(0xa1, .awaiting_approval, "Bash(x)", 1 * min);
    try w.chat.setSnooze("one", .{ .next_event = w.wall_ms + 2 * min }, 2 * min);
    try w.steward(0xa2, "two", 0x22, "two");
    try w.hook(0xa2, .turn_ended, "done", 1 * min);
    try w.steward(0xa3, "three", 0x23, "three");
    try w.hook(0xa3, .session_started, null, 1 * min);
    try w.terminal(0xc1, "zsh", 0x24);

    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();
    const first = try room.refresh(w.input(3 * min), .event);
    try testing.expectEqual(@as(?u64, null), first.wake_ms);
    try testing.expectEqual(@as(u64, 1), room.recomputes);

    // An hour of timer calls, were anybody to make them: not one recompute.
    var t: u64 = 3 * min;
    while (t < 63 * min) : (t += 1_000) {
        const out = try room.refresh(w.input(t), .timer);
        try testing.expectEqual(@as(?u64, null), out.wake_ms);
        try testing.expectEqual(@as(?u64, null), out.notify);
    }
    try testing.expectEqual(@as(u64, 1), room.recomputes);
}

test "ControlRoom wake: a threshold is woken for once, at the moment it is crossed" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "one", 0x21, "one");
    try w.worker(0xb1, "w", 0x21, 0xa1, "one");
    try w.hook(0xb1, .turn_started, null, 1 * min);
    try w.hook(0xa1, .session_started, null, 1 * min);
    w.bus.noteSampling(0xb1, true, 1 * min);
    w.bus.noteQuiet(0xb1, 0, 2 * min);

    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();
    const first = try room.refresh(w.input(2 * min), .event);
    // Still since 2:00, so T1 is crossed at 5:00.
    try testing.expectEqual(@as(?u64, 5 * min), first.wake_ms);

    // Before it: asked, and nothing is worked out.
    _ = try room.refresh(w.input(4 * min), .timer);
    try testing.expectEqual(@as(u64, 1), room.recomputes);
    try testing.expectEqual(@as(u64, 1), room.rev);

    // At it: the worker is suspect, and that is a change.
    const crossed = try room.refresh(w.input(5 * min), .timer);
    try testing.expectEqual(@as(u64, 2), room.recomputes);
    try testing.expectEqual(@as(?u64, 2), crossed.notify);
    try testing.expect(std.mem.indexOf(u8, room.json, "\"kind\":\"suspect_stuck\"") != null);
}

test "ControlRoom pulses: one waiting glyph breathes, the longest-waiting, and the order is given" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    // Waiting for the person: 0xa2 since 89, 0xa1 since 96, 0xb7 since 97,
    // 0xc1 since 99, 0xb1 since 99:30. Failed (0xa3) is trouble, and is not
    // in this.
    const order = [_]u64{ 0xa2, 0xa1, 0xb7, 0xc1, 0xb1 };
    try testing.expectEqual(order.len, s.pulses.len);
    for (order, s.pulses) |id, p| try testing.expectEqual(id, p.terminal.id);

    // Each says where it is, which is all a host compares.
    try testing.expectEqual(@as(u64, 0x22), s.pulses[0].tab.?.id);
    try testing.expectEqual(@as(u64, 0x10), s.pulses[0].window.?.id);

    // And which row is about it: the one that carries the reason when its
    // supervisor has two, none for a terminal in no row.
    try testing.expectEqualStrings("billing", s.pulses[0].group.?);
    try testing.expectEqualStrings("web-app-docs", s.pulses[1].group.?);
    try testing.expectEqualStrings("mobile", s.pulses[2].group.?);
    try testing.expectEqual(@as(?[]const u8, null), s.pulses[3].group);
    try testing.expectEqual(@as(?[]const u8, null), s.pulses[4].group);
}

test "ControlRoom waiter: the supervisor itself, a worker through it, a worker with none, a terminal alone" {
    var w = try fixtureWorld();
    defer w.deinit();
    // A group with no supervisor in it, whose one worker -- minded by
    // somebody outside the group -- is waiting.
    try w.chat.create("orphans", Chat.user_id);
    try w.terminal(0xd1, "lint", 0x2c);
    try w.bus.watch(0xd1, 0xa1);
    try w.chat.add("orphans", 0xd1, .all, .{});
    // Long enough ago that the wait has come up to the row.
    try w.approval(0xd1, "Bash", "npm run lint", 90 * min);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    const own = (try rowNamed(s, "web-app")).waiter;
    try testing.expectEqual(Waiter.Is.supervisor, own.is);
    try testing.expectEqualStrings("", own.name);

    // The row is about the worker, and says whose wait it is by name.
    const through = try rowNamed(s, "mobile");
    try testing.expectEqual(@as(u64, 0xb7), through.attention.terminal.?.id);
    try testing.expectEqual(Waiter.Is.worker_via_supervisor, through.waiter.is);
    try testing.expectEqualStrings("ios-build", through.waiter.name);

    const alone = (try rowNamed(s, "orphans")).waiter;
    try testing.expectEqual(Waiter.Is.worker, alone.is);
    try testing.expectEqualStrings("lint", alone.name);

    try testing.expectEqual(Waiter.Is.terminal, s.ungrouped[0].waiter.is);
    // Nobody is waiting on a row that needs nothing, whoever it is about.
    for (s.groups) |g| {
        if (!g.needs_me) try testing.expectEqual(Waiter.Is.none, g.waiter.is);
        if (g.needs_me) try testing.expect(g.waiter.is != .none);
    }
}

test "ControlRoom what: a command is its steps, a file is one piece, words are words" {
    var w = try fixtureWorld();
    defer w.deinit();
    // A tool that is not a shell asks for a file whose name has a `;` in it.
    try w.steward(0xaa, "editor", 0x2a, "editing");
    try w.approval(0xaa, "Edit", "src/a;b && c.ts", 99 * min);
    // PowerShell's rules are not the ones the cutter knows: one piece.
    try w.steward(0xab, "win", 0x2b, "windows");
    try w.approval(0xab, "PowerShell", "Remove-Item dist; npm ci", 99 * min);
    // A command the hook sent only the summary of.
    try w.steward(0xac, "old", 0x2c, "summary-only");
    var ev: AgentEvent.Event = .none;
    ev.event = .awaiting_approval;
    ev.detail = "Bash";
    ev.note = "make clean && make";
    _ = try w.bus.agentEvent(0xac, ev, 99 * min);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    const command = (try rowNamed(s, "web-app")).what;
    try testing.expectEqual(What.Form.command, command.form);
    try testing.expectEqual(@as(usize, 3), command.lines.len);
    try testing.expectEqualStrings("rm -rf dist/ .cache/ node_modules/.vite", command.lines[0]);
    try testing.expectEqualStrings("&& npm ci", command.lines[1]);
    try testing.expectEqualStrings("&& npm run build -- --mode production", command.lines[2]);

    const file = (try rowNamed(s, "editing")).what;
    try testing.expectEqual(What.Form.code, file.form);
    try testing.expectEqual(@as(usize, 1), file.lines.len);
    try testing.expectEqualStrings("src/a;b && c.ts", file.lines[0]);

    const posh = (try rowNamed(s, "windows")).what;
    try testing.expectEqual(What.Form.code, posh.form);
    try testing.expectEqualStrings("Remove-Item dist; npm ci", posh.lines[0]);

    const summary = (try rowNamed(s, "summary-only")).what;
    try testing.expectEqual(What.Form.command, summary.form);
    try testing.expectEqual(@as(usize, 2), summary.lines.len);

    const question = (try rowNamed(s, "billing")).what;
    try testing.expectEqual(What.Form.words, question.form);
    try testing.expectEqual(@as(usize, 1), question.lines.len);

    try testing.expectEqual(What.Form.words, (try rowNamed(s, "docs-site")).what.form);
    try testing.expectEqual(What.none.form, (try rowNamed(s, "notes")).what.form);
    try testing.expectEqual(@as(usize, 0), (try rowNamed(s, "notes")).what.lines.len);
}

test "ControlRoom what: a command longer than the hook's summary is whole, every step of it" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "boss", 0x21, "long");
    // 31 steps; the summary a hook cuts stops inside the eighth.
    var command: std.ArrayListUnmanaged(u8) = .empty;
    defer command.deinit(testing.allocator);
    try command.appendSlice(testing.allocator, "echo step-00");
    for (1..30) |n| try command.print(testing.allocator, " && echo step-{d:0>2}", .{n});
    try command.appendSlice(testing.allocator, " && rm -rf /srv/data");
    try w.approval(0xa1, "Bash", command.items, 1 * min);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const row = try rowNamed((try build(arena.allocator(), w.input(2 * min))).snapshot, "long");
    try testing.expect(row.reason.text.len <= 120);
    try testing.expectEqual(@as(usize, 31), row.what.lines.len);
    // The last step is the one that matters, and it is there.
    try testing.expectEqualStrings("&& rm -rf /srv/data", row.what.lines[30]);

    // Once it is no longer waiting, what it was waiting for is not kept.
    try w.hook(0xa1, .turn_started, null, 3 * min);
    try testing.expectEqual(@as(?[]const u8, null), w.bus.askOf(0xa1));
}

test "ControlRoom what: a question is whole, and a part of one is never passed off as all of it" {
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A dialog: the hook sends a first line and all of it. Longer than the
    // 160 bytes the bus keeps of a note.
    var long: std.ArrayListUnmanaged(u8) = .empty;
    for (0..30) |_| try long.appendSlice(a, "发票编号要按租户分开吗？");
    try w.steward(0xa1, "one", 0x21, "dialog");
    var dialog: AgentEvent.Event = .none;
    dialog.event = .awaiting_input;
    dialog.note = AgentEvent.prefixChars(long.items, AgentEvent.summary_chars);
    dialog.text = long.items;
    dialog.text_bytes = long.items.len;
    _ = try w.bus.agentEvent(0xa1, dialog, 10 * min);

    // Asked in prose: the turn ends on a question and the hook then says
    // only that it is waiting.
    try w.steward(0xa2, "two", 0x22, "prose");
    try w.hook(0xa2, .turn_ended, "迁移脚本写完了，12 条测试全过。\n\n有两件事要你定：\n先切一半流量，还是一次切完？", 10 * min);
    try w.hook(0xa2, .awaiting_input, null, 11 * min);

    // The same, when the question is all there was.
    try w.steward(0xa3, "three", 0x23, "only");
    try w.hook(0xa3, .turn_ended, "先切一半流量，还是一次切完？\n", 10 * min);
    try w.hook(0xa3, .awaiting_input, null, 11 * min);

    // A note as long as the bus keeps one and nothing else: it may have
    // been cut, and the row says so.
    try w.steward(0xa4, "four", 0x24, "capped");
    try w.hook(0xa4, .awaiting_input, "x" ** 200, 10 * min);
    // A short note is all of it.
    try w.steward(0xa5, "five", 0x25, "short");
    try w.hook(0xa5, .awaiting_input, "用哪个分支？", 10 * min);

    const s = (try build(a, w.input(100 * min))).snapshot;

    const whole = (try rowNamed(s, "dialog")).what;
    try testing.expectEqual(What.Form.words, whole.form);
    try testing.expectEqualStrings(long.items, whole.lines[0]);
    try testing.expectEqual(What.Cut.none, whole.cut);
    try testing.expect(whole.lines[0].len > 160);

    const prose = try rowNamed(s, "prose");
    try testing.expectEqual(Reason.From.last_turn, prose.reason.from);
    try testing.expectEqualStrings("有两件事要你定： 先切一半流量，还是一次切完？", prose.what.lines[0]);
    try testing.expectEqual(What.Cut.head, prose.what.cut);

    const only = (try rowNamed(s, "only")).what;
    try testing.expectEqualStrings("先切一半流量，还是一次切完？", only.lines[0]);
    try testing.expectEqual(What.Cut.none, only.cut);

    const capped = (try rowNamed(s, "capped")).what;
    try testing.expectEqual(@as(usize, 160), capped.lines[0].len);
    try testing.expectEqual(What.Cut.tail, capped.cut);

    try testing.expectEqual(What.Cut.none, (try rowNamed(s, "short")).what.cut);

    // The question is forgotten with the wait: a new turn, and nothing of
    // it is left to show beside whatever comes next.
    try w.hook(0xa1, .turn_started, null, 101 * min);
    try testing.expect(w.bus.askOf(0xa1) == null);
}

test "ControlRoom what: a working group says its own started task, and nothing when it has none" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "boss", 0x21, "busy");
    try w.hook(0xa1, .turn_started, null, 1 * min);
    try w.worker(0xb1, "helper", 0x21, 0xa1, "busy");

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // No task of its own: nothing is said.
    const bare = try rowNamed((try build(arena.allocator(), w.input(2 * min))).snapshot, "busy");
    try testing.expectEqual(Attention.Kind.working, bare.attention.kind);
    try testing.expectEqual(What.Form.none, bare.what.form);

    // Somebody else's started task, and one of its own not started: still nothing.
    try w.working("busy", 0xb1, "the helper's task");
    const queued = try w.tasks.create("busy", "not started yet", .feature);
    try w.tasks.assign(queued, 0xa1);
    const other = try rowNamed((try build(arena.allocator(), w.input(2 * min))).snapshot, "busy");
    try testing.expectEqual(What.Form.none, other.what.form);

    // Its own, started: that title; and the newer of two.
    try w.working("busy", 0xa1, "first thing");
    try w.working("busy", 0xa1, "second thing");
    const doing = try rowNamed((try build(arena.allocator(), w.input(2 * min))).snapshot, "busy");
    try testing.expectEqual(Reason.From.task, doing.reason.from);
    try testing.expectEqualStrings("second thing", doing.what.lines[0]);
}

test "ControlRoom snapshot: nothing in it says how long, and nothing wakes it to count minutes" {
    var w = try fixtureWorld();
    defer w.deinit();
    // The one thing that does count down is an allowance close to its
    // limit, which has a test of its own below.
    w.quota = &.{};
    var room = try fixtureRoom(&w);
    defer room.deinit();

    const first = try room.refresh(w.input(fixture_now), .event);
    try testing.expect(first.notify != null);
    inline for (.{ "waited_min", "\"band\"", "total_min", "start_label", "lanes", "spans" }) |gone| {
        try testing.expect(std.mem.indexOf(u8, room.json, gone) == null);
    }

    // Five rows are waiting. An hour of looking again, were anybody to: the
    // snapshot is worked out only when something in it can have changed,
    // and never once a minute.
    const before = room.recomputes;
    var t: u64 = fixture_now;
    var notices: usize = 0;
    while (t < fixture_now + 60 * min) : (t += 1_000) {
        const out = try room.refresh(w.input(t), .timer);
        if (out.notify != null) notices += 1;
    }
    try testing.expect(room.recomputes - before < 10);
    try testing.expectEqual(@as(usize, 0), notices);
}

test "ControlRoom quota: an allowance close to its limit is woken for once a minute, and an ordinary one not at all" {
    var w = try fixtureWorld();
    defer w.deinit();
    var room = try fixtureRoom(&w);
    defer room.deinit();

    // Forty minutes to the reset: forty changes of the number, the reset
    // itself, and nothing between them.
    _ = try room.refresh(w.input(fixture_now), .event);
    try testing.expect(std.mem.indexOf(u8, room.json, "\"when\":{\"form\":\"minutes\",\"n\":40}") != null);
    var before = room.recomputes;
    var t: u64 = fixture_now;
    var notices: usize = 0;
    while (t < fixture_now + 39 * min + 30_000) : (t += 1_000) {
        const out = try room.refresh(w.input(t), .timer);
        if (out.notify != null) notices += 1;
    }
    const counted = notices;
    try testing.expectEqual(@as(usize, 39), counted);
    try testing.expect(room.recomputes - before < 50);
    try testing.expect(std.mem.indexOf(u8, room.json, "\"when\":{\"form\":\"minutes\",\"n\":1}") != null);

    // An account with room, its number just taken: most of an hour of
    // looking again finds nothing to say.
    const calm = [_]quota.Reading{
        .{
            .family = .claude,
            .state = .have,
            .windows = .{ .{ .span = .five_hour, .used = 30, .resets_ms = fixture_wall + 4 * std.time.ms_per_hour }, null },
            .at_ms = fixture_wall,
        },
    };
    w.quota = &calm;
    var again = try fixtureRoom(&w);
    defer again.deinit();
    _ = try again.refresh(w.input(fixture_now), .event);
    before = again.recomputes;
    t = fixture_now;
    notices = 0;
    while (t < fixture_now + 59 * min) : (t += 1_000) {
        const out = try again.refresh(w.input(t), .timer);
        if (out.notify != null) notices += 1;
    }
    const quiet = notices;
    try testing.expectEqual(@as(usize, 0), quiet);
    try testing.expect(again.recomputes - before < 10);
}

test "ControlRoom snapshot: a terminal with its own idea of still is judged by it" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "one", 0x21, "one");
    try w.worker(0xb1, "w", 0x21, 0xa1, "one");
    w.bus.noteSampling(0xb1, true, 0);
    w.bus.noteQuiet(0xb1, 0, 1 * min);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Still for one minute: under the common three, so it is working.
    const common = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    try testing.expectEqual(Attention.Kind.working, common.terminals[1].kind);

    // Given thirty seconds of its own, the same minute is past it.
    w.open.items[1].still_ms = 30_000;
    const own = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    try testing.expectEqual(Attention.Kind.quiet_unknown, own.terminals[1].kind);
}

test "ControlRoom open_on: the first group with an agent in it, not an empty one before it" {
    var w: World = .init();
    defer w.deinit();
    // Three idle groups. The first is the person's own with nobody in it,
    // the second holds a plain shell, and only the third has an agent.
    try w.chat.create("aaa-empty", Chat.user_id);
    try w.chat.create("bbb-shell", Chat.user_id);
    try w.terminal(0xc1, "zsh", 0x21);
    try w.chat.add("bbb-shell", 0xc1, .all, .{});
    try w.steward(0xa1, "boss", 0x22, "ccc-minded");
    // Heard from a minute in, so its row is younger than the empty ones
    // and sorts after them: an agent's group is not always first.
    try w.hook(0xa1, .session_started, null, 1 * min);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    // The first row is the shell's group, which has no agent in it.
    try testing.expectEqualStrings("bbb-shell", s.groups[0].name);
    try testing.expectEqualStrings("ccc-minded", s.open_on.?);
}

test "ControlRoom open_on: the first group when every one is empty, and none when there are none" {
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const none = (try build(arena.allocator(), w.input(1 * min))).snapshot;
    try testing.expectEqual(@as(?[]const u8, null), none.open_on);

    try w.chat.create("zzz-empty", Chat.user_id);
    try w.chat.create("mmm-empty", Chat.user_id);
    const empty = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    try testing.expectEqualStrings("mmm-empty", empty.groups[0].name);
    try testing.expectEqualStrings("mmm-empty", empty.open_on.?);
}

test "ControlRoom open_on: a group whose agent's terminal is closed counts as empty" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "gone", 0x21, "aaa-closed");
    try w.steward(0xa2, "here", 0x22, "bbb-open");
    // Put off, so its row comes after the one nobody is minding.
    try w.chat.setSnooze("bbb-open", .{ .next_event = w.wall_ms + 1 * min }, 1 * min);
    // 0xa1's tab is closed: it is in the group still, and not open.
    for (w.open.items, 0..) |t, i| {
        if (t.id == 0xa1) {
            _ = w.open.orderedRemove(i);
            break;
        }
    }

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    try testing.expectEqualStrings("aaa-closed", s.groups[0].name);
    try testing.expectEqualStrings("bbb-open", s.open_on.?);
}

test "ControlRoom snapshot: a worker minded outside any group is listed on its own" {
    var w: World = .init();
    defer w.deinit();
    try w.terminal(0xa1, "boss", 0x21);
    try w.bus.addSupervisor(0xa1);
    try w.terminal(0xb1, "stray", 0x22);
    try w.bus.watch(0xb1, 0xa1);
    try w.hook(0xb1, .awaiting_approval, "Bash(x)", 1 * min);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    try testing.expectEqual(@as(usize, 2), s.ungrouped.len);
    try testing.expectEqual(@as(u64, 0xb1), s.ungrouped[0].id.id);
    try testing.expect(s.ungrouped[0].needs_me);
    try testing.expectEqual(@as(usize, 1), s.needs_me);
    try testing.expectEqual(@as(?u64, 1 * min), s.ungrouped[0].attention.event_ms);
}

test "ControlRoom terminals: each says which frame its pane wears" {
    var w: World = .init();
    defer w.deinit();
    try w.terminal(0xa1, "boss", 0x21);
    try w.bus.addSupervisor(0xa1);
    try w.terminal(0xb1, "minded", 0x21);
    try w.bus.watch(0xb1, 0xa1);
    try w.terminal(0xc1, "zsh", 0x21);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    try testing.expectEqual(@as(usize, 3), s.terminals.len);
    const Want = struct { u64, Pane };
    for ([_]Want{ .{ 0xa1, .supervisor }, .{ 0xb1, .worker }, .{ 0xc1, .plain } }) |want| {
        const got: ?Pane = for (s.terminals) |t| {
            if (t.id.id == want[0]) break t.pane;
        } else null;
        try testing.expectEqual(@as(?Pane, want[1]), got);
    }
}

/// The size section 13.2 of the design names: 32 groups, 128 terminals, with
/// a bit of everything in them.
fn benchWorld() !World {
    var w: World = .init();
    errdefer w.deinit();

    const kinds = [_]AgentEvent.Kind{ .awaiting_approval, .awaiting_input, .turn_failed, .turn_ended, .turn_started, .session_started };
    var names: [32][16]u8 = undefined;
    for (0..32) |g| {
        const name = try std.fmt.bufPrint(&names[g], "group-{d:0>2}", .{g});
        const boss: Id = 0x1000 + g;
        try w.steward(boss, "supervisor", 0x100 + g, name);
        try w.hook(boss, kinds[g % kinds.len], "Bash(rm -rf dist/ && npm run build)", (40 + g) * min);
        for (0..3) |n| {
            const id: Id = 0x2000 + g * 4 + n;
            try w.worker(id, "worker", 0x100 + g, boss, name);
            try w.hook(id, kinds[(g + n + 1) % kinds.len], "Edit(src/app.ts)", (50 + n) * min);
            w.bus.noteSampling(id, true, 60 * min);
            w.bus.noteQuiet(id, (g % 5) * min, 90 * min);
            w.bus.noteCall(id, 80 * min);
        }
    }
    return w;
}

test "ControlRoom bench: 32 groups and 128 terminals, worked out and written" {
    // Not a gate: it asserts only that the world is the size it says, and
    // prints how long things took. The figure that means anything is the
    // release one:
    //
    //   zig build test -Doptimize=ReleaseFast -Dtest-filter="ControlRoom bench" \
    //     -Demit-macos-app=false -Demit-xcframework=false --summary all
    const builtin = @import("builtin");
    const rounds: usize = if (builtin.mode == .Debug) 20 else 2000;

    var w = try benchWorld();
    defer w.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const Lap = struct {
        fn ns(clock: std.Io, from: std.Io.Timestamp) u64 {
            const now: std.Io.Timestamp = .now(clock, .awake);
            return @intCast(from.durationTo(now).nanoseconds);
        }
    };

    var build_ns: u64 = 0;
    var write_ns: u64 = 0;
    var refresh_ns: u64 = 0;
    var bytes: usize = 0;
    for (0..rounds) |_| {
        _ = arena.reset(.retain_capacity);
        const t0: std.Io.Timestamp = .now(io, .awake);
        const built = try build(arena.allocator(), w.input(fixture_now));
        build_ns += Lap.ns(io, t0);

        const t1: std.Io.Timestamp = .now(io, .awake);
        const json = try writeAlloc(arena.allocator(), built.snapshot, .{});
        write_ns += Lap.ns(io, t1);
        bytes = json.len;

        try testing.expectEqual(@as(usize, 32), built.snapshot.groups.len);
        try testing.expectEqual(@as(usize, 128), built.snapshot.terminals.len);
    }

    // The whole of what one event costs: work it out, write the compared
    // form, compare, write the full form.
    //
    // On the allocator a release build runs on, not the testing one: that
    // one checks every allocation, and was most of the figure when this
    // was first measured on it.
    var room: ControlRoom = .init(std.heap.smp_allocator);
    defer room.deinit();
    for (0..rounds) |i| {
        const t0: std.Io.Timestamp = .now(io, .awake);
        _ = try room.refresh(w.input(fixture_now + i), .event);
        refresh_ns += Lap.ns(io, t0);
    }

    std.debug.print(
        "\nControlRoom bench ({t}, {d} rounds): build {d} us, write {d} us ({d} bytes), refresh {d} us\n",
        .{ builtin.mode, rounds, build_ns / rounds / 1000, write_ns / rounds / 1000, bytes, refresh_ns / rounds / 1000 },
    );
}

test "ControlRoom start: a group with no supervisor says one can be started, in which role and where" {
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    // Back from last night: nobody in it. And one somebody minds.
    try w.chat.restoreShell("nightly", "", 0, .none);
    try w.steward(0xa1, "web-app", 0x21, "web-app");

    var s = (try room.compute(arena.allocator(), w.input(1_000))).snapshot;
    const absent = (try rowNamed(s, "nightly")).supervisor;
    try testing.expectEqual(SupervisorOut.State.absent, absent.state);
    try testing.expect(absent.can_start);
    try testing.expectEqualStrings("polter-supervisor", absent.role.?);
    // Nothing better is known than home.
    try testing.expectEqualStrings("/Users/me", absent.cwd);
    try testing.expectEqual(SupervisorOut.CwdFrom.home, absent.cwd_from);
    try testing.expectEqual(@as(?Hex, null), absent.terminal);

    const present = (try rowNamed(s, "web-app")).supervisor;
    try testing.expectEqual(SupervisorOut.State.present, present.state);
    try testing.expect(!present.can_start);

    try testing.expectEqual(@as(usize, 1), s.supervisor_roles.len);
    try testing.expect(!s.choose_supervisor_role);

    // What most of its terminals are in beats home; where its supervisor
    // last worked beats both.
    try w.terminal(0xb1, "one", 0x22);
    try w.chat.add("nightly", 0xb1, .all, .{ .cwd = "/work/api", .title = "" });
    s = (try room.compute(arena.allocator(), w.input(1_000))).snapshot;
    try testing.expectEqualStrings("/work/api", (try rowNamed(s, "nightly")).supervisor.cwd);
    try testing.expectEqual(SupervisorOut.CwdFrom.members, (try rowNamed(s, "nightly")).supervisor.cwd_from);
    // A worker in it is not a supervisor of it.
    try testing.expect((try rowNamed(s, "nightly")).supervisor.can_start);

    _ = try w.chat.setSupervisorDir("nightly", "/work/repo");
    s = (try room.compute(arena.allocator(), w.input(1_000))).snapshot;
    try testing.expectEqualStrings("/work/repo", (try rowNamed(s, "nightly")).supervisor.cwd);
    try testing.expectEqual(SupervisorOut.CwdFrom.last_supervisor, (try rowNamed(s, "nightly")).supervisor.cwd_from);

    // Two roles is a choice, in the order given; none is nothing to start.
    w.roles = &.{
        .{ .key = "polter-supervisor", .name = "Polter Supervisor" },
        .{ .key = "night-lead", .name = "Night Lead" },
    };
    s = (try room.compute(arena.allocator(), w.input(1_000))).snapshot;
    try testing.expect(s.choose_supervisor_role);
    try testing.expectEqualStrings("night-lead", s.supervisor_roles[1].key);
    try testing.expectEqualStrings("polter-supervisor", (try rowNamed(s, "nightly")).supervisor.role.?);

    w.roles = &.{};
    w.home = "";
    _ = try w.chat.setSupervisorDir("web-app", "/x");
    try w.chat.restoreShell("empty", "", 0, .none);
    s = (try room.compute(arena.allocator(), w.input(1_000))).snapshot;
    const none = (try rowNamed(s, "empty")).supervisor;
    try testing.expectEqual(SupervisorOut.State.absent, none.state);
    try testing.expect(!none.can_start);
    try testing.expectEqual(@as(?[]const u8, null), none.role);
    try testing.expectEqualStrings("", none.cwd);
    try testing.expectEqual(SupervisorOut.CwdFrom.none, none.cwd_from);
}

test "ControlRoom start: one on its way is not offered again, and the snapshot wakes itself to say it failed" {
    var w: World = .init();
    defer w.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    try w.chat.restoreShell("nightly", "", 0, .none);
    _ = try room.refresh(w.input(1_000), .event);

    try w.chat.beginStart("nightly", 2_000, 11_000);
    var out = try room.refresh(w.input(2_000), .event);
    try testing.expect(out.notify != null);
    {
        const read = try std.json.parseFromSlice(Snapshot, testing.allocator, room.json, .{});
        defer read.deinit();
        const sup = (try rowNamed(read.value, "nightly")).supervisor;
        try testing.expectEqual(SupervisorOut.State.starting, sup.state);
        try testing.expect(!sup.can_start);
        try testing.expectEqual(@as(?Hex, null), sup.terminal);
    }
    // Nothing will happen at the deadline but the deadline: woken for it.
    try testing.expectEqual(@as(?u64, 11_001), out.wake_ms);

    // The tab came; now the agent is waited for.
    try w.terminal(0xa9, "zsh", 0x29);
    w.chat.startOpened("nightly", 0xa9, 61_000);
    out = try room.refresh(w.input(3_000), .event);
    try testing.expectEqual(@as(?u64, 61_001), out.wake_ms);
    {
        const read = try std.json.parseFromSlice(Snapshot, testing.allocator, room.json, .{});
        defer read.deinit();
        const sup = (try rowNamed(read.value, "nightly")).supervisor;
        try testing.expectEqual(SupervisorOut.State.starting, sup.state);
        try testing.expectEqual(@as(u64, 0xa9), sup.terminal.?.id);
    }

    // It never connected. The timer alone says so, and it is offered again.
    out = try room.refresh(w.input(61_001), .timer);
    try testing.expect(out.notify != null);
    try testing.expectEqual(@as(?u64, null), out.wake_ms);
    {
        const read = try std.json.parseFromSlice(Snapshot, testing.allocator, room.json, .{});
        defer read.deinit();
        const sup = (try rowNamed(read.value, "nightly")).supervisor;
        try testing.expectEqual(SupervisorOut.State.failed, sup.state);
        try testing.expectEqual(Chat.StartFailure.agent_never_connected, sup.failed);
        try testing.expect(sup.can_start);
        try testing.expectEqual(@as(u64, 0xa9), sup.terminal.?.id);
    }

    // It did connect, was made a supervisor and put in the group: present,
    // whatever is left of the start.
    try w.chat.beginStart("nightly", 62_000, 72_000);
    w.chat.startOpened("nightly", 0xa9, 122_000);
    try w.bus.addSupervisor(0xa9);
    try w.chat.add("nightly", 0xa9, .all, .{});
    out = try room.refresh(w.input(63_000), .event);
    {
        const read = try std.json.parseFromSlice(Snapshot, testing.allocator, room.json, .{});
        defer read.deinit();
        const row = try rowNamed(read.value, "nightly");
        try testing.expectEqual(SupervisorOut.State.present, row.supervisor.state);
        try testing.expect(!row.supervisor.can_start);
        try testing.expectEqual(@as(u64, 0xa9), row.steward.?.id);
        try testing.expectEqual(@as(?Hex, null), row.supervisor.terminal);
    }
}

test "ControlRoom wake: hooks that never came are said once, and there is no moment left to wake for" {
    // The crash: a supervisor was started, its CLI never spoke, and thirty
    // seconds on the bus said so once -- by moving the moment the hooks
    // were expected to the end of time. That number came out of here as
    // the next thing to wake for, and the wake thread could not hold it.
    var w: World = .init();
    defer w.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    try w.terminal(0xa1, "zsh", 0x21);
    try w.hook(0xa1, .hooks_expected, null, 10_000);

    // While the thirty seconds run, their end is the moment to wake at.
    var out = try room.refresh(w.input(11_000), .event);
    try testing.expectEqual(@as(?u64, 10_000 + Bus.hooks_expected_timeout_ms), out.wake_ms);

    // They ran out. The bus says so, once.
    const late = 10_000 + Bus.hooks_expected_timeout_ms + 1_000;
    _ = w.bus.considerAgents(late);
    try testing.expect(!w.bus.considerAgents(late + 60_000));
    // When they were expected is still when they were expected.
    try testing.expectEqual(@as(u64, 10_000), w.bus.agentOf(0xa1).expected_ms);

    // Nothing will change on its own now: no wake, and above all not one
    // at the end of time.
    out = try room.refresh(w.input(late), .event);
    try testing.expectEqual(@as(?u64, null), out.wake_ms);

    // And it is still what it is: hooks that were promised and did not come.
    const read = try std.json.parseFromSlice(Snapshot, testing.allocator, room.json, .{});
    defer read.deinit();
    try testing.expectEqual(@as(usize, 1), read.value.ungrouped.len);
    try testing.expectEqual(Attention.Kind.suspect_stuck, read.value.ungrouped[0].attention.kind);
    try testing.expectEqual(Attention.Source.hook_missing, read.value.ungrouped[0].attention.source);
}

test "ControlRoom header: with terminals on their own among the rows, the heading, the rows and the Dock are one number" {
    // What was on a real window: "1 group waiting for you", three rows
    // under it, and 3 on the Dock.
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try w.steward(0xa1, "web-app", 0x21, "web-app");
    try w.approval(0xa1, "Bash", "npm ci", 1 * min);
    // Two agents nobody minds, in no group, each stopped on a prompt.
    try w.terminal(0xc1, "one", 0x22);
    try w.approval(0xc1, "Bash", "git push", 1 * min);
    try w.terminal(0xc2, "two", 0x23);
    try w.approval(0xc2, "Bash", "rm -rf dist", 1 * min);
    // And one that needs nothing, with a group that needs nothing.
    try w.terminal(0xc3, "three", 0x24);
    try w.hook(0xc3, .session_started, null, 1 * min);
    try w.steward(0xa2, "notes", 0x25, "notes");
    try w.hook(0xa2, .session_started, null, 1 * min);

    var s = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    var waiting_rows: usize = 0;
    var quiet_rows: usize = 0;
    for (s.groups) |g| {
        if (g.needs_me) waiting_rows += 1 else quiet_rows += 1;
    }
    for (s.ungrouped) |t| {
        if (t.needs_me) waiting_rows += 1 else quiet_rows += 1;
    }
    try testing.expectEqual(@as(usize, 3), waiting_rows);

    // The three places, one number.
    try testing.expectEqual(waiting_rows, s.header_waiting.count);
    try testing.expectEqual(s.needs_me, s.header_waiting.count);
    // Not all of them are groups, so the heading does not call them that.
    try testing.expectEqual(HeaderOut.Of.rows, s.header_waiting.of);
    try testing.expectEqual(HeaderOut.Number.other, s.header_waiting.number);
    try testing.expectEqual(@as(usize, 1), s.header_waiting.groups);
    try testing.expectEqual(@as(usize, 2), s.header_waiting.alone);

    // The second heading is held to the same.
    try testing.expectEqual(quiet_rows, s.header_quiet.count);
    try testing.expectEqual(@as(usize, 2), s.header_quiet.count);
    try testing.expectEqual(HeaderOut.Of.rows, s.header_quiet.of);

    // A host that draws only the groups' rows still has its own two
    // numbers, and they are still only the groups.
    try testing.expectEqual(@as(usize, 1), s.groups_needing_me);
    try testing.expectEqual(@as(usize, 1), s.groups_other);

    // Only groups under a heading: it says "groups", and one is "one".
    var only: World = .init();
    defer only.deinit();
    try only.steward(0xa1, "web-app", 0x21, "web-app");
    try only.approval(0xa1, "Bash", "npm ci", 1 * min);
    s = (try build(arena.allocator(), only.input(2 * min))).snapshot;
    try testing.expectEqual(HeaderOut{ .count = 1, .of = .groups, .number = .one, .groups = 1, .alone = 0 }, s.header_waiting);
    try testing.expectEqual(HeaderOut{ .count = 0, .of = .groups, .number = .none, .groups = 0, .alone = 0 }, s.header_quiet);

    // One lone terminal waiting and nothing else: one, and not a group.
    var lone: World = .init();
    defer lone.deinit();
    try lone.terminal(0xc1, "one", 0x22);
    try lone.approval(0xc1, "Bash", "git push", 1 * min);
    s = (try build(arena.allocator(), lone.input(2 * min))).snapshot;
    try testing.expectEqual(HeaderOut{ .count = 1, .of = .rows, .number = .one, .groups = 0, .alone = 1 }, s.header_waiting);
    try testing.expectEqual(@as(usize, 1), s.needs_me);
    try testing.expectEqual(@as(usize, 0), s.groups_needing_me);
}

test "ControlRoom seen: a terminal on its own is looked at through its own row" {
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // An agent nobody minds, in no group, finishes a turn.
    try w.terminal(0xc1, "stray", 0x21);
    try w.hook(0xc1, .turn_started, null, 1 * min);
    try w.hook(0xc1, .turn_ended, "done", 2 * min);
    {
        const s = (try build(arena.allocator(), w.input(3 * min))).snapshot;
        try testing.expectEqual(@as(usize, 1), s.ungrouped.len);
        try testing.expectEqual(Attention.Kind.done_unseen, s.ungrouped[0].attention.kind);
        try testing.expect(s.ungrouped[0].unseen);
    }

    // The person looks at its row. It is no longer something not looked at.
    try testing.expect(w.bus.markSeen(0xc1, 3 * min));
    {
        const s = (try build(arena.allocator(), w.input(4 * min))).snapshot;
        try testing.expect(!s.ungrouped[0].unseen);
        try testing.expect(s.ungrouped[0].attention.kind != .done_unseen);
    }

    // It finishes another turn afterwards: that one has not been looked at.
    try w.hook(0xc1, .turn_started, null, 5 * min);
    try w.hook(0xc1, .turn_ended, "done again", 6 * min);
    {
        const s = (try build(arena.allocator(), w.input(7 * min))).snapshot;
        try testing.expect(s.ungrouped[0].unseen);
    }

    // A terminal the bus does not know has no row to look at.
    try testing.expect(!w.bus.markSeen(0xdead, 7 * min));
}

test "ControlRoom seen: what a supervisor with no group raises is withdrawn by looking at its row" {
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // A supervisor minding a worker, neither in any group.
    try w.terminal(0xa1, "boss", 0x21);
    try w.bus.addSupervisor(0xa1);
    try w.hook(0xa1, .session_started, null, 1 * min);
    const said = "the worker wants to force-push: yours to decide";
    try testing.expect(try w.bus.raise(0xa1, 2 * min, said));

    const rowOf = struct {
        fn of(s: Snapshot, id: u64) !LoneRow {
            for (s.ungrouped) |r| if (r.id.id == id) return r;
            return error.TestRowMissing;
        }
    }.of;
    {
        const s = (try build(arena.allocator(), w.input(2 * min + 1))).snapshot;
        const row = try rowOf(s, 0xa1);
        try testing.expect(row.needs_me);
        try testing.expectEqual(Reason.From.raised, row.reason.from);
        try testing.expectEqualStrings(said, row.reason.text);
        // Looking at it is what withdraws it, and the row says so: this is
        // what a host starts its "seen" clock on.
        try testing.expect(row.unseen);
        try testing.expectEqual(@as(usize, 1), s.header_waiting.count);
    }

    try testing.expect(w.bus.markSeen(0xa1, 3 * min));
    {
        const s = (try build(arena.allocator(), w.input(3 * min + 1))).snapshot;
        const row = try rowOf(s, 0xa1);
        try testing.expect(row.reason.from != .raised);
        try testing.expect(!row.needs_me);
        try testing.expect(!row.unseen);
        try testing.expectEqual(@as(usize, 0), s.needs_me);
    }

    // Raised again after that: there again.
    try testing.expect(try w.bus.raise(0xa1, 4 * min, "and now this"));
    {
        const s = (try build(arena.allocator(), w.input(4 * min + 1))).snapshot;
        try testing.expect((try rowOf(s, 0xa1)).needs_me);
    }
}

test "ControlRoom start: closing the tab fails the start in the very next snapshot, while the terminal is still there" {
    // A host that keeps a closed tab for undo does not destroy the
    // terminal, so nothing "forgets" it. The control room said "starting"
    // for fifteen to forty-odd seconds after the tab was gone.
    var w: World = .init();
    defer w.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    try w.chat.restoreShell("nightly", "", 0, .none);
    try w.terminal(0xa9, "zsh", 0x29);
    try w.chat.beginStart("nightly", 1_000, 11_000);
    w.chat.startOpened("nightly", 0xa9, 61_000);
    var out = try room.refresh(w.input(2_000), .event);
    try testing.expectEqual(@as(?u64, 61_001), out.wake_ms);

    // The tab is closed three seconds in. The terminal is still open as
    // far as the core can tell -- it is in `terminals` below.
    try testing.expect(w.chat.startTerminalClosed(0xa9));
    out = try room.refresh(w.input(5_000), .event);
    try testing.expect(out.notify != null);
    {
        const read = try std.json.parseFromSlice(Snapshot, testing.allocator, room.json, .{});
        defer read.deinit();
        const sup = (try rowNamed(read.value, "nightly")).supervisor;
        try testing.expectEqual(SupervisorOut.State.failed, sup.state);
        try testing.expectEqual(Chat.StartFailure.terminal_closed, sup.failed);
        try testing.expect(sup.can_start);
        try testing.expectEqual(@as(usize, 1), read.value.terminals.len);
    }
    // Nothing is left to wait for.
    try testing.expectEqual(@as(?u64, null), out.wake_ms);

    // Said once; a terminal nothing was starting in says nothing.
    try testing.expect(!w.chat.startTerminalClosed(0xa9));
    try testing.expect(!w.chat.startTerminalClosed(0xb0));
}

test "may-authorise off in the configuration: a worker's prompt is the person's at once, not after its supervisor's minute" {
    var w: World = .init();
    defer w.deinit();
    w.bus.config.may_authorise = false;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try w.steward(0xa1, "api", 0x21, "api");
    try w.hook(0xa1, .turn_started, null, 10 * min);
    try w.worker(0xb1, "api worker", 0x21, 0xa1, "api");
    try w.approval(0xb1, "Bash", "git push --force", 20 * min);

    // Five seconds in. With the gate open this row would still be the
    // supervisor's business; shut, there is nobody who may answer it but
    // the person.
    const s = (try build(arena.allocator(), w.input(20 * min + 5_000))).snapshot;
    const row = try rowNamed(s, "api");
    try testing.expect(row.needs_me);
    try testing.expectEqual(Attention.Kind.needs_approval, row.attention.kind);
    try testing.expectEqual(@as(usize, 1), s.needs_me);

    // The same world with the gate open, so that this can fail.
    w.bus.config.may_authorise = true;
    const open = (try build(arena.allocator(), w.input(20 * min + 5_000))).snapshot;
    try testing.expect(!(try rowNamed(open, "api")).needs_me);
}
