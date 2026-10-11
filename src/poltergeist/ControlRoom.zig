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
//!   "needs_me": 3,            "N waiting for you": terminals, each once
//!   "groups_needing_me": 4,   rows in `groups` with needs_me, in a row
//!   "groups_other": 3,        from the top; the rest
//!   "groups": [ {             already in the order to draw them
//!       "name": "web-app", "brief": "", "last_ms": 0,
//!       "seen_ms": null,
//!       "snooze": {"until":"none","at_ms":null,"until_ms":null},
//!                             until: none | next_event | time
//!       "steward": "0x00000000000000a1" | null,
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
//!       "shown": "needs_you",   needs_you | trouble | done_unseen |
//!                               working | none
//!       "word": "needs_approval", "text": "等批准",
//!       "waited_min": 4 | null, only on rows that need the person
//!       "reason": {"from":"hook_note","text":"Bash(rm -rf dist/)",
//!                  "missing":null},
//!                             from: hook_note | hook_detail | process |
//!                             clocks | hooks | last_turn | none.
//!                             When the line could not be had, text is
//!                             empty and `missing` says which kind of
//!                             missing: empty_note | empty_detail |
//!                             no_turn_kept | self_report_text
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
//!   "ungrouped": [ { "id", "title", "attention", "needs_me", "unseen",
//!       "shown", "word", "text", "waited_min", "reason" } ],
//!   "terminals": [ { the member fields but `role`, and "event_ms",
//!       "window":"0x…"|null, "tab":"0x…"|null } ],
//!   "tabs": [ { "window":"0x…"|null, "tab":"0x…",
//!       "shown":…, "terminal":"0x…"|null } ],
//!   "pulses": [ { "terminal":"0x…", "window":"0x…"|null,
//!       "tab":"0x…"|null, "group":"billing"|null } ],
//!                             every terminal waiting for the person,
//!                             longest first. The one glyph that breathes
//!                             in a window is the first of these not in
//!                             the tab that window is showing (and, for a
//!                             glyph in a tab bar or a pane, in that
//!                             window). `group` is the row that is about
//!                             it. A host tests equality and nothing else.
//!   "band": {                 "kept you waiting today"; wall clock
//!       "start_ms":…, "start_label":"09:00", "now_ms":…,
//!       "total_min": 47,      minutes in which anyone waited, once
//!       "lanes": [ { "name":"web-app", "spans": [
//!           { "from_ms":…, "to_ms":…, "ongoing":false } ] } ] } }
//!                             a span still going on has to_ms = now.
//!                             Kept in memory from when this run began;
//!                             a restart starts the day again.
//! ```
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

/// The stretches in which a group kept the person waiting, for the band at
/// the foot of the list. **Kept from when this run started and nowhere
/// else**: nothing writes them down, so a restart begins the day again.
waits: std.ArrayListUnmanaged(Wait),

/// When this run first looked, on the wall clock: where the band begins if
/// that was today.
began_ms: ?u64,

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
        .waits = .empty,
        .began_ms = null,
    };
}

pub fn deinit(self: *ControlRoom) void {
    for (self.waits.items) |w| self.alloc.free(w.name);
    self.waits.deinit(self.alloc);
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

/// The whole snapshot as of now, with today's waiting brought up to date.
/// Everything in the result lives in `arena`.
fn compute(self: *ControlRoom, arena: Allocator, in: Input) Allocator.Error!Built {
    var built = try build(arena, in);
    self.recomputes += 1;

    try self.noteWaits(built.snapshot.groups, in);
    const band = try bandOf(arena, self.waits.items, self.began_ms orelse in.wall_ms, in);
    built.snapshot.band = band.band;
    // The total is in whole minutes, and grows only while somebody waits.
    if (band.ongoing) built.wake_ms = earlier(
        built.wake_ms,
        in.now_ms + (min_ms - band.total_ms % min_ms),
    );
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
    /// The bus's clock, and the real one.
    now_ms: u64,
    wall_ms: u64,
    /// What to add to the wall clock to get the reader's own time of day.
    /// Passed in so that what a day is does not depend on where this runs.
    local_offset_ms: i64,
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

    pub const From = enum { hook_note, hook_detail, process, clocks, hooks, last_turn, none };
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

pub const GroupRow = struct {
    name: []const u8,
    brief: []const u8,
    last_ms: u64,
    seen_ms: ?u64,
    snooze: SnoozeOut,
    steward: ?Hex,
    attention: AttentionOut,
    needs_me: bool,
    unseen: bool,
    shown: Attention.Shown,
    word: Attention.Word,
    text: []const u8,
    waited_min: ?u64,
    reason: Reason,
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
    waited_min: ?u64,
    reason: Reason,
};

pub const TerminalOut = struct {
    id: Hex,
    title: []const u8,
    window: ?Hex,
    tab: ?Hex,
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

/// One stretch of today in which a group kept the person waiting. Wall
/// clock.
pub const Span = struct {
    from_ms: u64,
    /// For one still going on, now.
    to_ms: u64,
    ongoing: bool,
};

pub const Lane = struct {
    name: []const u8,
    spans: []const Span,
};

/// "Kept you waiting today".
pub const Band = struct {
    /// The left end of the axis, and how to label it: `09:00`.
    start_ms: u64,
    start_label: []const u8,
    /// The right end. Wall clock, unlike the snapshot's own `now_ms`.
    now_ms: u64,
    /// Minutes in which at least one group was waiting; two waiting at
    /// once are the person waiting once.
    total_min: u64,
    lanes: []const Lane,

    pub const none: Band = .{ .start_ms = 0, .start_label = "", .now_ms = 0, .total_min = 0, .lanes = &.{} };
};

pub const Snapshot = struct {
    rev: u64,
    now_ms: u64,
    needs_me: usize,
    groups_needing_me: usize,
    groups_other: usize,
    groups: []const GroupRow,
    ungrouped: []const LoneRow,
    terminals: []const TerminalOut,
    tabs: []const Tab,
    /// Every "waiting for you" terminal, longest-waiting first. **The one
    /// glyph that breathes in a window is the first of these that is not
    /// in the tab that window is showing** -- and, for a glyph that stands
    /// in a tab bar or a pane, that is in that window at all. A host finds
    /// it by asking "is this the tab I am showing" and "is this my window",
    /// which are equalities; the order, which is a comparison, is here.
    pulses: []const Pulse,
    band: Band,
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

    // The right end of the band is now, and so is the end of a stretch
    // still going on.
    out.band.now_ms = 0;
    const lanes = try arena.dupe(Lane, s.band.lanes);
    for (lanes) |*l| {
        const spans = try arena.dupe(Span, l.spans);
        for (spans) |*sp| {
            if (sp.ongoing) sp.to_ms = 0;
        }
        l.spans = spans;
    }
    out.band.lanes = lanes;

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
    const f = in.bus.facts(id, in.now_ms, .{
        .process = if (open) |t| t.process else .gone,
        .seen_ms = seen_ms,
        // The agent's own report is the next piece; nothing raises yet.
        .raised_ms = null,
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
    wake: *Wake,
) Allocator.Error!Reason {
    const agent = in.bus.agentOf(s.id);
    switch (s.kind) {
        .needs_approval => {
            const note = agent.note.get() orelse return .lacking(.hook_note, .empty_note);
            return .{ .from = .hook_note, .text = try arena.dupe(u8, note), .missing = null };
        },
        .needs_answer => {
            if (s.source == .self_report) return .lacking(.none, .self_report_text);
            const note = agent.note.get() orelse return .lacking(.hook_note, .empty_note);
            return .{ .from = .hook_note, .text = try arena.dupe(u8, note), .missing = null };
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
        .working, .idle, .unattended, .snoozed => return .none,
    }
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

/// The minutes a row that needs the person has waited, which changes on
/// the minute.
fn waitedMin(a: Attention, now_ms: u64, wake: *Wake) ?u64 {
    if (!Attention.needsMe(a)) return null;
    const waited = now_ms -| a.since_ms;
    wake.consider(now_ms + (min_ms - waited % min_ms));
    return waited / min_ms;
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
    const by = in.chat.createdBy(name) catch Chat.user_id;
    if (by != Chat.user_id and in.bus.isSupervisor(by) and
        std.mem.indexOfScalar(Id, members, by) != null) return by;
    // Nobody who made it is minding it: whoever in it is a supervisor.
    for (members) |id| {
        if (id != Chat.user_id and in.bus.isSupervisor(id)) return id;
    }
    return null;
}

const Pending = struct {
    row: GroupRow,
    attention: Attention,
};

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

        for (all) |id| {
            if (id == Chat.user_id) continue;

            // Seen in any of its groups is seen, for the glyph on its tab.
            const gop = try grouped.getOrPut(arena, id);
            if (!gop.found_existing) gop.value_ptr.* = null;
            if (seen) |ms| gop.value_ptr.* = @max(gop.value_ptr.* orelse 0, ms);

            const s = statusOf(in, id, seen, &wake);
            const is_steward = steward_id != null and steward_id.? == id;
            if (is_steward) steward = s else try workers.append(arena, s);

            // A worker's first minute is its supervisor's; the row changes
            // when that minute is up.
            if (!is_steward and s.alive and s.duty == .on) switch (s.kind) {
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
        try rows.append(arena, .{ .attention = a, .row = .{
            .name = try arena.dupe(u8, name),
            .brief = try arena.dupe(u8, in.chat.briefOf(name) catch ""),
            .last_ms = last_ms,
            .seen_ms = marks.seen_ms,
            .snooze = .of(marks.snooze),
            .steward = .opt(steward_id),
            .attention = .of(a, in.bus),
            .needs_me = Attention.needsMe(a),
            .unseen = Attention.unseen(a),
            .shown = d.shown,
            .word = d.word,
            .text = d.word.text(),
            .waited_min = waitedMin(a, in.now_ms, &wake),
            .reason = if (about != null and a.kind == about.?.kind)
                try reasonOf(arena, in, about.?, &wake)
            else
                .none,
            .more = more,
            .same_as = null,
            .members = members.items,
        } });
    }

    std.mem.sort(Pending, rows.items, {}, pendingBefore);

    // One supervisor, several groups: the one spoken in last carries the
    // reason, the others point at it (4.4). 暂定: "spoken in last" is the
    // group's last message, not that supervisor's own.
    for (rows.items, 0..) |*r, i| {
        if (r.attention.what != .own) continue;
        const t = r.attention.terminal orelse continue;
        var lead = i;
        for (rows.items, 0..) |o, j| {
            if (o.attention.what != .own or o.attention.terminal == null) continue;
            if (o.attention.terminal.? != t) continue;
            if (o.row.last_ms > rows.items[lead].row.last_ms) lead = j;
        }
        if (lead != i) r.row.same_as = rows.items[lead].row.name;
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
        const s = statusOf(in, t.id, if (in_group) |seen| seen else null, &wake);
        try statuses.append(arena, s);

        const d = Attention.display(s);
        try terminals.append(arena, .{
            .id = .{ .id = t.id },
            .title = try arena.dupe(u8, t.title),
            .window = .opt(t.window),
            .tab = .opt(t.tab),
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
        const alone = switch (in.bus.roleOf(t.id)) {
            .supervisor, .watched => true,
            .none => in.bus.agentOf(t.id).hooks != .none or t.agent_present,
        };
        if (!alone) continue;

        const a = Attention.ofTerminal(s);
        const rd = rowDisplay(a, s);
        try lone.append(arena, .{ .attention = a, .row = .{
            .id = .{ .id = t.id },
            .title = try arena.dupe(u8, t.title),
            .attention = .of(a, in.bus),
            .needs_me = Attention.needsMe(a),
            .unseen = Attention.unseen(a),
            .shown = rd.shown,
            .word = rd.word,
            .text = rd.word.text(),
            .waited_min = waitedMin(a, in.now_ms, &wake),
            .reason = if (a.kind == s.kind) try reasonOf(arena, in, s, &wake) else .none,
        } });
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

    // The count, from the one function that counts.
    var counted: std.ArrayListUnmanaged(Attention) = .empty;
    var needing: usize = 0;
    const group_rows = try arena.alloc(GroupRow, rows.items.len);
    for (rows.items, group_rows) |r, *out| {
        out.* = r.row;
        try counted.append(arena, r.attention);
        if (r.row.needs_me) needing += 1;
    }
    const lone_rows = try arena.alloc(LoneRow, lone.items.len);
    for (lone.items, lone_rows) |r, *out| {
        out.* = r.row;
        try counted.append(arena, r.attention);
    }

    return .{
        .snapshot = .{
            .rev = 0,
            .now_ms = in.now_ms,
            .needs_me = Attention.needsMeCount(counted.items),
            .groups_needing_me = needing,
            .groups_other = group_rows.len - needing,
            .groups = group_rows,
            .ungrouped = lone_rows,
            .terminals = terminals.items,
            .tabs = tabs.items,
            .pulses = pulses,
            .band = .none,
        },
        .wake_ms = wake.at,
    };
}

// -- today's waiting --------------------------------------------------------

const Wait = struct {
    /// Owned.
    name: []u8,
    from_ms: u64,
    /// Null while it is still going on.
    to_ms: ?u64,
};

const day_ms: u64 = 24 * std.time.ms_per_hour;

/// The most stretches kept. Past it the oldest finished one goes, so a
/// group flickering all day cannot grow this without bound.
const max_waits = 2048;

fn localMs(wall_ms: u64, offset_ms: i64) u64 {
    return @intCast(@max(0, @as(i64, @intCast(wall_ms)) + offset_ms));
}

/// The start of the reader's own day.
fn dayStart(wall_ms: u64, offset_ms: i64) u64 {
    return wall_ms -| (localMs(wall_ms, offset_ms) % day_ms);
}

/// Open a stretch for each group that has started waiting, and close the
/// ones that have stopped.
fn noteWaits(self: *ControlRoom, groups: []const GroupRow, in: Input) Allocator.Error!void {
    if (self.began_ms == null) self.began_ms = in.wall_ms;
    const today = dayStart(in.wall_ms, in.local_offset_ms);

    // Yesterday's are not on today's band.
    var i: usize = 0;
    while (i < self.waits.items.len) {
        const w = self.waits.items[i];
        if (w.to_ms != null and w.to_ms.? < today) {
            self.alloc.free(w.name);
            _ = self.waits.orderedRemove(i);
        } else i += 1;
    }

    for (self.waits.items) |*w| {
        if (w.to_ms != null) continue;
        const still = for (groups) |g| {
            if (g.needs_me and std.mem.eql(u8, g.name, w.name)) break true;
        } else false;
        if (!still) w.to_ms = in.wall_ms;
    }

    for (groups) |g| {
        if (!g.needs_me) continue;
        const open = for (self.waits.items) |w| {
            if (w.to_ms == null and std.mem.eql(u8, w.name, g.name)) break true;
        } else false;
        if (open) continue;

        if (self.waits.items.len >= max_waits) {
            for (self.waits.items, 0..) |w, n| if (w.to_ms != null) {
                self.alloc.free(w.name);
                _ = self.waits.orderedRemove(n);
                break;
            };
        }
        const name = try self.alloc.dupe(u8, g.name);
        errdefer self.alloc.free(name);
        try self.waits.append(self.alloc, .{
            .name = name,
            // It began when it began, which may be before anybody looked.
            .from_ms = in.wall_ms -| (in.now_ms -| g.attention.since_ms),
            .to_ms = null,
        });
    }
}

/// A group was renamed: what it kept the person waiting for goes with it.
pub fn renameGroup(self: *ControlRoom, old: []const u8, new: []const u8) Allocator.Error!void {
    for (self.waits.items) |*w| {
        if (!std.mem.eql(u8, w.name, old)) continue;
        const name = try self.alloc.dupe(u8, new);
        self.alloc.free(w.name);
        w.name = name;
    }
}

const BandOf = struct { band: Band, total_ms: u64, ongoing: bool };

fn bandOf(arena: Allocator, waits: []const Wait, began_ms: u64, in: Input) Allocator.Error!BandOf {
    const today = dayStart(in.wall_ms, in.local_offset_ms);
    // From the top of the hour this run began in, or from midnight when it
    // began before today. 暂定: the design shows `09:00` and says no more.
    const hour = std.time.ms_per_hour;
    const start = @max(today, began_ms -| (localMs(began_ms, in.local_offset_ms) % hour));
    const of_day = localMs(start, in.local_offset_ms) % day_ms;
    const label = try std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}", .{
        of_day / hour,
        of_day % hour / std.time.ms_per_min,
    });

    const Cut = struct { from: u64, to: u64 };
    var all: std.ArrayListUnmanaged(Cut) = .empty;
    var lanes: std.ArrayListUnmanaged(Lane) = .empty;
    var ongoing = false;

    for (waits, 0..) |w, i| {
        // One lane per name, made at its first stretch.
        const first = for (waits[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, w.name)) break false;
        } else true;
        if (!first) continue;

        var spans: std.ArrayListUnmanaged(Span) = .empty;
        for (waits[i..]) |o| {
            if (!std.mem.eql(u8, o.name, w.name)) continue;
            // A stretch still going on runs to now.
            const to = o.to_ms orelse in.wall_ms;
            const from = @max(o.from_ms, start);
            if (to <= from) continue;
            if (o.to_ms == null) ongoing = true;
            try spans.append(arena, .{ .from_ms = from, .to_ms = to, .ongoing = o.to_ms == null });
            try all.append(arena, .{ .from = from, .to = to });
        }
        if (spans.items.len == 0) continue;
        try lanes.append(arena, .{ .name = try arena.dupe(u8, w.name), .spans = spans.items });
    }
    std.mem.sort(Lane, lanes.items, {}, struct {
        fn lt(_: void, a: Lane, b: Lane) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    // Two groups waiting at once are one person waiting once.
    std.mem.sort(Cut, all.items, {}, struct {
        fn lt(_: void, a: Cut, b: Cut) bool {
            return a.from < b.from;
        }
    }.lt);
    var total: u64 = 0;
    var covered: u64 = 0;
    for (all.items) |c| {
        const from = @max(c.from, covered);
        if (c.to > from) total += c.to - from;
        covered = @max(covered, c.to);
    }

    return .{
        .band = .{
            .start_ms = start,
            .start_label = label,
            .now_ms = in.wall_ms,
            .total_min = total / min_ms,
            .lanes = lanes.items,
        },
        .total_ms = total,
        .ongoing = ongoing,
    };
}

/// A terminal that is itself waiting on the person.
fn waiting(s: Attention.Status) bool {
    return s.alive and s.duty == .on and s.kind.needsMe();
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const AgentEvent = @import("agent_event.zig");
const T = Attention.Thresholds.defaults;

/// A bus and a chat with terminals in them, and the list of what is open.
const World = struct {
    bus: Bus,
    chat: Chat,
    open: std.ArrayListUnmanaged(Terminal) = .empty,
    wall_ms: u64 = 1_700_000_000_000,

    fn init() World {
        return .{
            .bus = .init(testing.allocator, .{}),
            .chat = .init(testing.allocator, .{}),
        };
    }

    fn deinit(self: *World) void {
        self.open.deinit(testing.allocator);
        self.chat.deinit();
        self.bus.deinit();
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
            .now_ms = now_ms,
            .wall_ms = self.wall_ms + now_ms,
            .local_offset_ms = 8 * std.time.ms_per_hour,
        };
    }
};

const min = std.time.ms_per_min;

/// Six groups, one of each thing a row can say, and a seventh that shares
/// its supervisor with the first.
fn fixtureWorld() !World {
    var w: World = .init();
    errdefer w.deinit();

    // Waiting on an approval, for four minutes; a worker also waiting.
    try w.steward(0xa1, "web-app", 0x21, "web-app");
    try w.hook(0xa1, .awaiting_approval, "Bash(rm -rf dist/ && npm run build)", 96 * min);
    try w.worker(0xb1, "web-app worker", 0x21, 0xa1, "web-app");
    try w.hook(0xb1, .awaiting_approval, "Edit(src/app.ts)", 99 * min + 30_000);

    // The same supervisor minds a second group, spoken in more recently.
    try w.chat.create("web-app-docs", 0xa1);
    _ = try w.chat.post("web-app-docs", 0xa1, "docs next", 1_700_000_000_000);

    // Waiting on an answer.
    try w.steward(0xa2, "billing", 0x22, "billing");
    try w.hook(0xa2, .awaiting_input, "发票编号用哪一种格式？", 89 * min);

    // Failed.
    try w.steward(0xa3, "docs-site", 0x23, "docs-site");
    var failed: AgentEvent.Event = .none;
    failed.event = .turn_failed;
    failed.detail = "rate_limit";
    failed.note = "resets 13:40";
    _ = try w.bus.agentEvent(0xa3, failed, 98 * min);

    // Finished a turn nobody has looked at.
    try w.steward(0xa4, "infra", 0x24, "infra");
    try w.hook(0xa4, .turn_ended, "迁移脚本跑完了。\n要不要现在切流量？", 70 * min);

    // Working, with a worker that clocked off.
    try w.steward(0xa5, "design-system", 0x25, "design-system");
    try w.hook(0xa5, .turn_started, null, 95 * min);
    try w.worker(0xb5, "tokens", 0x25, 0xa5, "design-system");
    try w.bus.clockOff(0xb5, .supervisor);

    // Idle.
    try w.steward(0xa6, "notes", 0x26, "notes");
    try w.hook(0xa6, .session_started, null, 10 * min);

    // On its own: an agent with hooks that nobody minds, waiting.
    try w.terminal(0xc1, "zsh — ~/work", 0x27);
    try w.hook(0xc1, .awaiting_approval, "Bash(git push)", 99 * min);
    // And a plain shell, which is in no list but `terminals`.
    try w.terminal(0xc2, "zsh", 0x27);

    return w;
}

/// A room that has been open since the run began, in which docs-site had
/// already kept the person waiting once this morning.
fn fixtureRoom(w: *const World) !ControlRoom {
    var room: ControlRoom = .init(testing.allocator);
    errdefer room.deinit();
    room.began_ms = w.wall_ms;
    try room.waits.append(testing.allocator, .{
        .name = try testing.allocator.dupe(u8, "docs-site"),
        .from_ms = w.wall_ms + 50 * min,
        .to_ms = w.wall_ms + 58 * min,
    });
    return room;
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
    try testing.expectEqual(@as(usize, 7), read.groups.len);
    try testing.expectEqual(@as(u64, 0xa1), read.groups[0].steward.?.id);
}

test "ControlRoom snapshot: rows come sorted, counted, and with what they draw" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    const order = [_][]const u8{ "web-app", "web-app-docs", "billing", "docs-site", "infra", "design-system", "notes" };
    try testing.expectEqual(order.len, s.groups.len);
    for (order, s.groups) |name, g| try testing.expectEqualStrings(name, g.name);

    const kinds = [_]Attention.Kind{ .needs_approval, .needs_approval, .needs_answer, .failed, .done_unseen, .working, .idle };
    const shown = [_]Attention.Shown{ .needs_you, .needs_you, .needs_you, .trouble, .done_unseen, .working, .none };
    for (kinds, shown, s.groups) |k, sh, g| {
        try testing.expectEqual(k, g.attention.kind);
        try testing.expectEqual(sh, g.shown);
        try testing.expectEqualStrings(g.word.text(), g.text);
    }

    try testing.expectEqual(@as(usize, 4), s.groups_needing_me);
    try testing.expectEqual(@as(usize, 3), s.groups_other);
    try testing.expectEqual(@as(?u64, 4), s.groups[0].waited_min);
    try testing.expectEqual(@as(?u64, null), s.groups[4].waited_min);
}

test "ControlRoom snapshot: one supervisor in two groups is counted once" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    // 0xa1 (two rows), 0xa2, 0xa3, and the lone 0xc1: four terminals, five rows.
    try testing.expectEqual(@as(usize, 4), s.needs_me);
    try testing.expectEqual(@as(usize, 1), s.ungrouped.len);

    // The row spoken in last carries the reason; the other points at it.
    const main = try rowNamed(s, "web-app");
    const docs = try rowNamed(s, "web-app-docs");
    try testing.expectEqualStrings("web-app-docs", main.same_as.?);
    try testing.expectEqual(@as(?[]const u8, null), docs.same_as);
    try testing.expectEqual(main.attention.terminal.?.id, docs.attention.terminal.?.id);
}

test "ControlRoom snapshot: the reason line, and which kind of missing when there is none" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // An approval whose hook said nothing about what for.
    try w.steward(0xa7, "quiet", 0x28, "quiet");
    try w.hook(0xa7, .awaiting_approval, null, 99 * min);
    // A turn that ended with no text kept.
    try w.steward(0xa8, "silent", 0x29, "silent");
    try w.hook(0xa8, .turn_ended, null, 99 * min);

    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    const approval = (try rowNamed(s, "web-app-docs")).reason;
    try testing.expectEqual(Reason.From.hook_note, approval.from);
    try testing.expectEqualStrings("Bash(rm -rf dist/ && npm run build)", approval.text);

    try testing.expectEqualStrings("发票编号用哪一种格式？", (try rowNamed(s, "billing")).reason.text);
    try testing.expectEqualStrings("rate_limit：resets 13:40", (try rowNamed(s, "docs-site")).reason.text);
    // The last thing it said, which is where a question in prose is.
    try testing.expectEqualStrings("要不要现在切流量？", (try rowNamed(s, "infra")).reason.text);
    try testing.expectEqual(Reason.none, (try rowNamed(s, "design-system")).reason);

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
    };
    try testing.expectEqual(wants.len, s.tabs.len);
    for (wants, s.tabs) |want, tab| {
        try testing.expectEqual(want[0], tab.tab.id);
        try testing.expectEqual(want[1], tab.shown);
        try testing.expectEqual(want[2], if (tab.terminal) |t| t.id else null);
    }
    try testing.expectEqual(w.open.items.len, s.terminals.len);
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
    try testing.expectEqual(@as(usize, 3), during.snapshot.needs_me);
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

    // Waiting for the person: 0xa2 since 89, 0xa1 since 96, 0xc1 since 99,
    // 0xb1 since 99:30. Failed (0xa3) is trouble, and is not in this.
    const order = [_]u64{ 0xa2, 0xa1, 0xc1, 0xb1 };
    try testing.expectEqual(order.len, s.pulses.len);
    for (order, s.pulses) |id, p| try testing.expectEqual(id, p.terminal.id);

    // Each says where it is, which is all a host compares.
    try testing.expectEqual(@as(u64, 0x22), s.pulses[0].tab.?.id);
    try testing.expectEqual(@as(u64, 0x10), s.pulses[0].window.?.id);

    // And which row is about it: the one that carries the reason when its
    // supervisor has two, none for a terminal in no row.
    try testing.expectEqualStrings("billing", s.pulses[0].group.?);
    try testing.expectEqualStrings("web-app-docs", s.pulses[1].group.?);
    try testing.expectEqual(@as(?[]const u8, null), s.pulses[2].group);
    try testing.expectEqual(@as(?[]const u8, null), s.pulses[3].group);
}

test "ControlRoom band: a group still waiting runs to now, and one that stopped does not" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var room = try fixtureRoom(&w);
    defer room.deinit();

    const wall = w.wall_ms;
    const band = (try room.compute(arena.allocator(), w.input(fixture_now))).snapshot.band;

    // The run began at 06:13 local; the axis starts on the hour.
    try testing.expectEqualStrings("06:00", band.start_label);
    try testing.expectEqual(wall - 13 * min - 20_000, band.start_ms);
    try testing.expectEqual(wall + fixture_now, band.now_ms);

    const names = [_][]const u8{ "billing", "docs-site", "web-app", "web-app-docs" };
    try testing.expectEqual(names.len, band.lanes.len);
    for (names, band.lanes) |name, lane| try testing.expectEqualStrings(name, lane.name);

    // billing has waited since 89 and is waiting still.
    const billing = band.lanes[0].spans;
    try testing.expectEqual(@as(usize, 1), billing.len);
    try testing.expectEqual(wall + 89 * min, billing[0].from_ms);
    try testing.expectEqual(wall + fixture_now, billing[0].to_ms);
    try testing.expect(billing[0].ongoing);

    // docs-site: once this morning, over; and again since 98.
    const docs = band.lanes[1].spans;
    try testing.expectEqual(@as(usize, 2), docs.len);
    try testing.expectEqual(Span{ .from_ms = wall + 50 * min, .to_ms = wall + 58 * min, .ongoing = false }, docs[0]);
    try testing.expectEqual(Span{ .from_ms = wall + 98 * min, .to_ms = wall + fixture_now, .ongoing = true }, docs[1]);

    // Eight minutes then, and eleven since 89 with everything overlapping.
    try testing.expectEqual(@as(u64, 19), band.total_min);
}

test "ControlRoom band: a wait that ends is closed where it ended, and a rename keeps it" {
    var w = try fixtureWorld();
    defer w.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    _ = try room.refresh(w.input(fixture_now), .event);
    // The answer is given: billing's agent starts a turn.
    try w.hook(0xa2, .turn_started, null, fixture_now + 2 * min);
    _ = try room.refresh(w.input(fixture_now + 2 * min), .event);
    try room.renameGroup("billing", "invoices");
    try w.chat.rename("billing", "invoices");
    _ = try room.refresh(w.input(fixture_now + 5 * min), .event);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const band = (try room.compute(arena.allocator(), w.input(fixture_now + 5 * min))).snapshot.band;
    const lane = for (band.lanes) |l| {
        if (std.mem.eql(u8, l.name, "invoices")) break l;
    } else return error.TestLaneMissing;
    try testing.expectEqual(@as(usize, 1), lane.spans.len);
    try testing.expectEqual(w.wall_ms + fixture_now + 2 * min, lane.spans[0].to_ms);
    try testing.expect(!lane.spans[0].ongoing);
    for (band.lanes) |l| try testing.expect(!std.mem.eql(u8, l.name, "billing"));
}

test "ControlRoom band: yesterday is not on it" {
    var w = try fixtureWorld();
    defer w.deinit();
    var room = try fixtureRoom(&w);
    defer room.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The same world a day later: the morning's finished stretch is gone
    // and the axis starts at midnight.
    w.wall_ms += day_ms;
    const band = (try room.compute(arena.allocator(), w.input(fixture_now))).snapshot.band;
    try testing.expectEqualStrings("00:00", band.start_label);
    for (band.lanes) |l| for (l.spans) |sp| try testing.expect(sp.from_ms >= band.start_ms);
    const docs = for (band.lanes) |l| {
        if (std.mem.eql(u8, l.name, "docs-site")) break l;
    } else return error.TestLaneMissing;
    try testing.expectEqual(@as(usize, 1), docs.spans.len);
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
