//! When the control room calls the person: the system notification of
//! dev-docs/poltergeist/control-room.md, section 9 (task 1505).
//!
//! **Pure, apart from what it remembers.** Nothing here reads a clock, a
//! window or the bus. The caller hands in the groups as the snapshot has
//! them (`Row`), what the hosts said about where the person is
//! (`Presence`), whether the hour allows it (`Hours`) and the time; it gets
//! back what to send now and when to look again. What it keeps between two
//! calls is which things it has already dealt with (`done`), so that one
//! thing calls once.
//!
//! The rules, each one a test below:
//!
//!   - **Only three kinds interrupt**: waiting for an approval, waiting for
//!     an answer, failed. "Maybe stuck", "a turn ended unseen" and "still,
//!     reason unknown" do not; neither does anything snoozed.
//!   - **Two minutes first.** A thing that starts waiting only lights the
//!     count (the snapshot does that); if it is still waiting two minutes
//!     after it started, it is sent, once.
//!   - **Once per thing.** A thing is the terminal that waits, the kind and
//!     the moment it started (`Signature`). The same thing is never sent
//!     twice -- not after a snooze ends, not after a restart of nothing; a
//!     changed state is a new thing.
//!   - **One supervisor, one notification.** Rows are merged by their
//!     supervisor: three groups waiting on it are one call that names the
//!     first and says how many more. While the supervisor itself waits, that
//!     is the thing -- its workers' states coming and going under it are
//!     not new things to call about.
//!   - **Not while the person is there.** At the moment it would be sent,
//!     if the card is in sight in a control room that is in front, or the
//!     person is in the terminal that waits, nothing is sent -- and that
//!     thing is dealt with: they saw it. Per window, because "in front" is
//!     the control room's window, and "in the terminal" is a terminal that
//!     has the keyboard, which only one window's can.
//!   - **Quiet hours** (`poltergeist-notify-window`) hold back an answer or
//!     a failure until they end; an approval is sent at any hour, as
//!     `notify.Reason.authorisation` is, because nobody else may answer it.

const ControlNotify = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Attention = @import("Attention.zig");
const Bus = @import("Bus.zig");

pub const Id = Bus.Id;

/// How long a thing waits before it is sent: section 9's two minutes.
pub const delay_ms: u64 = 2 * std.time.ms_per_min;

/// Every thing already sent, or found the person already looking at. Owned.
done: std.AutoHashMapUnmanaged(Signature, void),

pub const empty: ControlNotify = .{ .done = .empty };

pub fn deinit(self: *ControlNotify, alloc: Allocator) void {
    self.done.deinit(alloc);
    self.* = undefined;
}

/// What a kind of wait does to the person.
pub fn interrupts(kind: Attention.Kind) bool {
    return switch (kind) {
        .needs_approval, .needs_answer, .failed => true,
        .suspect_stuck, .done_unseen, .quiet_unknown, .working, .idle, .unattended, .snoozed => false,
    };
}

/// One terminal's wait, as the snapshot has it.
pub const Need = struct {
    kind: Attention.Kind,
    since_ms: u64,
    /// The terminal that waits. Null on a row about nobody.
    terminal: ?Id,
};

/// One group's row in the control room, in what this needs of it.
pub const Row = struct {
    group: []const u8,
    /// The group's supervisor: what rows are merged by. Null: the group is
    /// merged with nothing.
    steward: ?Id,
    /// What the row comes to, **before** a snooze: the snapshot's `under`.
    top: Need,
    snoozed: bool,
    /// The person muted the group's notifications (task 1659): like a
    /// snooze, nothing is raised for it, while its card is shown as ever.
    /// Unlike one, it does not end when the row changes -- only when its
    /// moment comes or the person lifts it.
    muted: bool,
    /// The supervisor's own wait, when it is alive and on duty; null
    /// otherwise.
    own: ?Need,
    /// Who waits, for the words: empty for the supervisor itself, a
    /// worker's name otherwise.
    who: []const u8,
    /// What it is waiting on, in its own words, or empty.
    text: []const u8,
};

/// What the hosts said about where the person is.
pub const Presence = struct {
    /// The groups whose card is on screen in a control room that is in
    /// front. Empty when the control room is behind, or closed.
    cards_in_sight: []const []const u8,
    /// The terminals that have the keyboard in a window that has it.
    terminals_in_use: []const Id,

    pub const nobody: Presence = .{ .cards_in_sight = &.{}, .terminals_in_use = &.{} };
};

/// What a host last said about its control room: whether it is in front,
/// and which groups' cards are on screen in it
/// (`ghostty_app_control_presence`). Owned.
pub const Sight = struct {
    in_front: bool,
    cards: []const []const u8,

    pub const none: Sight = .{ .in_front = false, .cards = &.{} };

    /// `{"in_front":bool,"cards":["group",…]}`. Anything else is refused
    /// whole: half a report about where the person is would be read as all
    /// of it.
    pub fn parse(alloc: Allocator, json: []const u8) (Allocator.Error || error{BadPresence})!Sight {
        const Wire = struct { in_front: bool, cards: []const []const u8 };
        const parsed = std.json.parseFromSlice(Wire, alloc, json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadPresence,
        };
        defer parsed.deinit();
        const cards = try alloc.alloc([]const u8, parsed.value.cards.len);
        var made: usize = 0;
        errdefer {
            for (cards[0..made]) |c| alloc.free(c);
            alloc.free(cards);
        }
        for (parsed.value.cards, cards) |src, *dst| {
            dst.* = try alloc.dupe(u8, src);
            made += 1;
        }
        return .{ .in_front = parsed.value.in_front, .cards = cards };
    }

    pub fn deinit(self: *Sight, alloc: Allocator) void {
        for (self.cards) |c| alloc.free(c);
        alloc.free(self.cards);
        self.* = .none;
    }

    /// The cards in sight: those on screen in a control room that is in
    /// front, and none when it is not.
    pub fn inSight(self: Sight) []const []const u8 {
        return if (self.in_front) self.cards else &.{};
    }
};

/// Whether the hour allows a notification that respects quiet hours.
pub const Hours = union(enum) {
    open,
    /// Not now; this many milliseconds until it is.
    closed_for_ms: u64,
};

/// One thing that waits: who, what, and since when.
pub const Signature = struct {
    terminal: Id,
    kind: Attention.Kind,
    since_ms: u64,

    fn of(n: Need) Signature {
        return .{ .terminal = n.terminal orelse 0, .kind = n.kind, .since_ms = n.since_ms };
    }
};

/// Something to send now.
pub const Alert = struct {
    /// The group to name and to select when the notification is clicked:
    /// the first of the supervisor's that waits, in the snapshot's order.
    group: []const u8,
    /// How many more of that supervisor's groups wait.
    more: usize,
    kind: Attention.Kind,
    who: []const u8,
    text: []const u8,
    signature: Signature,
};

/// Something due that was not sent, and why, for the log.
pub const Held = struct {
    group: []const u8,
    signature: Signature,
    why: Why,

    pub const Why = enum {
        /// The card was in sight in a control room in front. Dealt with.
        card_in_sight,
        /// The person was in the terminal that waits. Dealt with.
        in_the_terminal,
        /// Quiet hours. Held until they end, not dealt with.
        quiet_hours,
    };
};

pub const Decision = struct {
    alerts: []const Alert,
    held: []const Held,
    /// When to look again if nothing happens first; null for never.
    wake_ms: ?u64,
};

/// What one supervisor's rows come to: the thing it is about, the row that
/// names it, and how many more of its rows wait.
const Merged = struct {
    key: Key,
    first: usize,
    more: usize,
    groups: std.ArrayListUnmanaged(usize),
};

const Key = union(enum) {
    steward: Id,
    group: []const u8,

    fn eql(a: Key, b: Key) bool {
        return switch (a) {
            .steward => |x| switch (b) {
                .steward => |y| x == y,
                .group => false,
            },
            .group => |x| switch (b) {
                .group => |y| std.mem.eql(u8, x, y),
                .steward => false,
            },
        };
    }

    fn of(r: Row) Key {
        return if (r.steward) |s| .{ .steward = s } else .{ .group = r.group };
    }
};

/// Decide. `rows` in the snapshot's order. What the result points at lives
/// in `arena` and in `rows`.
pub fn step(
    self: *ControlNotify,
    alloc: Allocator,
    arena: Allocator,
    rows: []const Row,
    presence: Presence,
    hours: Hours,
    now_ms: u64,
) Allocator.Error!Decision {
    var merged: std.ArrayListUnmanaged(Merged) = .empty;
    // Every thing that is still there, interrupting or not -- what `done`
    // may keep. A snoozed row's thing is still there.
    var current: std.AutoHashMapUnmanaged(Signature, void) = .empty;

    for (rows, 0..) |r, i| {
        const key = Key.of(r);
        const m = for (merged.items) |*m| {
            if (m.key.eql(key)) break m;
        } else blk: {
            try merged.append(arena, .{
                .key = key,
                .first = i,
                .more = 0,
                .groups = .empty,
            });
            break :blk &merged.items[merged.items.len - 1];
        };
        try m.groups.append(arena, i);
    }

    var alerts: std.ArrayListUnmanaged(Alert) = .empty;
    var held: std.ArrayListUnmanaged(Held) = .empty;
    var wake: ?u64 = null;

    for (merged.items) |*m| {
        // The things this supervisor's rows are about. While the supervisor
        // itself waits, that is the one thing: its workers' states coming
        // and going under it are not new. Otherwise each waiting row's own
        // wait is a thing.
        var own: ?Need = null;
        var waiting: usize = 0;
        for (m.groups.items) |gi| {
            const r = rows[gi];
            if (r.own) |o| {
                if (interrupts(o.kind)) own = o;
            }
            try current.put(arena, Signature.of(r.top), {});
            if (r.own) |o| try current.put(arena, Signature.of(o), {});
            if (r.snoozed or r.muted or !interrupts(r.top.kind)) continue;
            waiting += 1;
        }
        if (waiting == 0) continue;

        // Every thing of this supervisor's that is waiting, with the row
        // that shows it.
        var things: std.ArrayListUnmanaged(Thing) = .empty;
        for (m.groups.items) |gi| {
            const r = rows[gi];
            if (r.snoozed or r.muted or !interrupts(r.top.kind)) continue;
            const need = own orelse r.top;
            const sig = Signature.of(need);
            const seen = for (things.items) |t| {
                if (std.meta.eql(t.signature, sig)) break true;
            } else false;
            if (!seen) try things.append(arena, .{ .signature = sig, .need = need, .row = gi });
        }

        // **One thing is said once, and so is what it was said with**
        // (task 1531). A thing that went out as "and 1 more" has been said:
        // when the group named first stops waiting, the one it carried is
        // not a new call. Only a thing nobody has been told of is news --
        // which a changed state always is, since its moment changes.
        //
        // Which of the new ones a call is about: one that is due, an
        // approval first (quiet hours never hold those), then the
        // snapshot's order.
        var lead: ?Thing = null;
        var next_due: ?u64 = null;
        for (things.items) |t| {
            if (self.done.contains(t.signature)) continue;
            const due = t.need.since_ms +| delay_ms;
            if (now_ms < due) {
                next_due = earlier(next_due, due);
                continue;
            }
            if (lead == null or (t.need.kind == .needs_approval and lead.?.need.kind != .needs_approval)) lead = t;
        }
        const l = lead orelse {
            if (next_due) |d| wake = earlier(wake, d);
            continue;
        };
        const r = rows[l.row];
        m.first = l.row;
        m.more = waiting - 1;

        if (inSight(presence, rows, m.groups.items)) {
            try self.settle(alloc, things.items);
            try held.append(arena, .{ .group = r.group, .signature = l.signature, .why = .card_in_sight });
            continue;
        }
        if (l.need.terminal) |t| {
            if (inUse(presence, t)) {
                try self.settle(alloc, things.items);
                try held.append(arena, .{ .group = r.group, .signature = l.signature, .why = .in_the_terminal });
                continue;
            }
        }
        switch (hours) {
            .open => {},
            .closed_for_ms => |ms| if (l.need.kind != .needs_approval) {
                wake = earlier(wake, now_ms +| @max(ms, 1));
                try held.append(arena, .{ .group = r.group, .signature = l.signature, .why = .quiet_hours });
                continue;
            },
        }

        // Everything it says is said: the one it names and the ones it
        // counts in "N more", due or not.
        try self.settle(alloc, things.items);
        const own_is_it = own != null;
        try alerts.append(arena, .{
            .group = r.group,
            .more = m.more,
            .kind = l.need.kind,
            // The supervisor's own wait has no worker to name, whichever
            // row came first.
            .who = if (own_is_it) "" else r.who,
            .text = if (own_is_it) ownText(rows, m.groups.items) else r.text,
            .signature = l.signature,
        });
    }

    // Forget what is not there any more: a thing that has gone cannot come
    // back with the same moment it started, so keeping it buys nothing.
    var it = self.done.keyIterator();
    var gone: std.ArrayListUnmanaged(Signature) = .empty;
    while (it.next()) |k| if (!current.contains(k.*)) try gone.append(arena, k.*);
    for (gone.items) |k| _ = self.done.remove(k);

    return .{ .alerts = alerts.items, .held = held.items, .wake_ms = wake };
}

/// One supervisor's waiting thing and the row that shows it.
const Thing = struct {
    signature: Signature,
    need: Need,
    row: usize,
};

/// Mark every thing a call was about -- or that the person was found
/// looking at -- as dealt with.
fn settle(self: *ControlNotify, alloc: Allocator, things: []const Thing) Allocator.Error!void {
    for (things) |t| try self.done.put(alloc, t.signature, {});
}

/// The words for a supervisor's own wait: from a row that is about the
/// supervisor itself, when one is.
fn ownText(rows: []const Row, groups: []const usize) []const u8 {
    for (groups) |gi| {
        const r = rows[gi];
        const o = r.own orelse continue;
        if (r.top.terminal != null and o.terminal != null and r.top.terminal.? == o.terminal.?) return r.text;
    }
    return "";
}

fn inSight(p: Presence, rows: []const Row, groups: []const usize) bool {
    for (groups) |gi| {
        for (p.cards_in_sight) |g| if (std.mem.eql(u8, g, rows[gi].group)) return true;
    }
    return false;
}

fn inUse(p: Presence, id: Id) bool {
    for (p.terminals_in_use) |t| if (t == id) return true;
    return false;
}

fn earlier(a: ?u64, b: u64) u64 {
    return if (a) |x| @min(x, b) else b;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const min = std.time.ms_per_min;

const sup: Id = 0xa1;
const worker: Id = 0xb2;

fn row(group: []const u8, kind: Attention.Kind, since_ms: u64, terminal: Id) Row {
    return .{
        .group = group,
        .steward = sup,
        .top = .{ .kind = kind, .since_ms = since_ms, .terminal = terminal },
        .snoozed = false,
        .muted = false,
        .own = if (terminal == sup) .{ .kind = kind, .since_ms = since_ms, .terminal = sup } else null,
        .who = if (terminal == sup) "" else "worker-core",
        .text = "may I write retry.py?",
    };
}

const Run = struct {
    n: ControlNotify = .empty,
    arena: std.heap.ArenaAllocator = .init(testing.allocator),

    fn at(self: *Run, rows: []const Row, p: Presence, h: Hours, now_ms: u64) !Decision {
        return self.n.step(testing.allocator, self.arena.allocator(), rows, p, h, now_ms);
    }

    fn deinit(self: *Run) void {
        self.n.deinit(testing.allocator);
        self.arena.deinit();
    }
};

test "ControlNotify: only an approval, an answer and a failure interrupt" {
    for (std.enums.values(Attention.Kind)) |k| {
        const want = switch (k) {
            .needs_approval, .needs_answer, .failed => true,
            else => false,
        };
        try testing.expectEqual(want, interrupts(k));
    }
    // Maybe-stuck needs the person in the count, and still does not call.
    try testing.expect(Attention.Kind.suspect_stuck.needsMe());
    var r: Run = .{};
    defer r.deinit();
    const d = try r.at(&.{row("web", .suspect_stuck, 0, sup)}, .nobody, .open, 10 * min);
    try testing.expectEqual(@as(usize, 0), d.alerts.len);
    try testing.expectEqual(@as(?u64, null), d.wake_ms);
}

test "ControlNotify: two minutes first, then once" {
    var r: Run = .{};
    defer r.deinit();
    const rows = [_]Row{row("web", .needs_approval, 1 * min, sup)};

    const early = try r.at(&rows, .nobody, .open, 1 * min + 5_000);
    try testing.expectEqual(@as(usize, 0), early.alerts.len);
    try testing.expectEqual(@as(?u64, 3 * min), early.wake_ms);

    // One millisecond short is still short.
    try testing.expectEqual(@as(usize, 0), (try r.at(&rows, .nobody, .open, 3 * min - 1)).alerts.len);

    const due = try r.at(&rows, .nobody, .open, 3 * min);
    try testing.expectEqual(@as(usize, 1), due.alerts.len);
    try testing.expectEqualStrings("web", due.alerts[0].group);
    try testing.expectEqual(Attention.Kind.needs_approval, due.alerts[0].kind);

    // And never again while it is the same thing.
    const later = try r.at(&rows, .nobody, .open, 30 * min);
    try testing.expectEqual(@as(usize, 0), later.alerts.len);
    try testing.expectEqual(@as(?u64, null), later.wake_ms);
}

test "ControlNotify: a changed state is a new thing" {
    var r: Run = .{};
    defer r.deinit();
    _ = try r.at(&.{row("web", .needs_approval, 0, sup)}, .nobody, .open, 3 * min);
    // Answered, and a second prompt comes: a new moment, a new call.
    const second = [_]Row{row("web", .needs_approval, 10 * min, sup)};
    try testing.expectEqual(@as(usize, 0), (try r.at(&second, .nobody, .open, 11 * min)).alerts.len);
    try testing.expectEqual(@as(usize, 1), (try r.at(&second, .nobody, .open, 12 * min)).alerts.len);
    // The same moment with another kind is another thing too.
    const failed = [_]Row{row("web", .failed, 10 * min, sup)};
    try testing.expectEqual(@as(usize, 1), (try r.at(&failed, .nobody, .open, 12 * min)).alerts.len);
}

test "ControlNotify: one supervisor's three groups are one call, naming the first" {
    var r: Run = .{};
    defer r.deinit();
    const rows = [_]Row{
        row("web", .needs_answer, 0, sup),
        row("api", .needs_answer, 0, sup),
        row("docs", .needs_answer, 0, sup),
    };
    const d = try r.at(&rows, .nobody, .open, 2 * min);
    try testing.expectEqual(@as(usize, 1), d.alerts.len);
    try testing.expectEqualStrings("web", d.alerts[0].group);
    try testing.expectEqual(@as(usize, 2), d.alerts[0].more);

    // Two supervisors are two calls.
    var r2: Run = .{};
    defer r2.deinit();
    var other = row("ops", .needs_answer, 0, 0xc3);
    other.steward = 0xc3;
    const two = [_]Row{ row("web", .needs_answer, 0, sup), other };
    try testing.expectEqual(@as(usize, 2), (try r2.at(&two, .nobody, .open, 2 * min)).alerts.len);
}

test "ControlNotify: while the supervisor waits, its workers' states are not new calls" {
    var r: Run = .{};
    defer r.deinit();
    // The supervisor waits for an answer; one call.
    var own = row("web", .needs_answer, 0, sup);
    try testing.expectEqual(@as(usize, 1), (try r.at(&.{own}, .nobody, .open, 2 * min)).alerts.len);

    // A worker's prompt comes up through it and is now what the row shows
    // (an approval sorts before an answer). Still the same thing.
    own.top = .{ .kind = .needs_approval, .since_ms = 5 * min, .terminal = worker };
    own.who = "worker-core";
    const d = try r.at(&.{own}, .nobody, .open, 10 * min);
    try testing.expectEqual(@as(usize, 0), d.alerts.len);
    try testing.expectEqual(@as(?u64, null), d.wake_ms);

    // The supervisor stops waiting: the worker's prompt is the thing now.
    own.own = .{ .kind = .working, .since_ms = 9 * min, .terminal = sup };
    const w = try r.at(&.{own}, .nobody, .open, 10 * min);
    try testing.expectEqual(@as(usize, 1), w.alerts.len);
    try testing.expectEqualStrings("worker-core", w.alerts[0].who);
}

test "ControlNotify: nothing is sent while snoozed, and what was sent is not sent again after" {
    var r: Run = .{};
    defer r.deinit();
    var x = row("web", .needs_approval, 0, sup);
    x.snoozed = true;
    try testing.expectEqual(@as(usize, 0), (try r.at(&.{x}, .nobody, .open, 10 * min)).alerts.len);
    // It comes back from the snooze still waiting on the same prompt. Not
    // sent before is not "sent": it is sent now, once.
    x.snoozed = false;
    try testing.expectEqual(@as(usize, 1), (try r.at(&.{x}, .nobody, .open, 11 * min)).alerts.len);
    // Snoozed after being sent, and back: not again.
    x.snoozed = true;
    _ = try r.at(&.{x}, .nobody, .open, 12 * min);
    x.snoozed = false;
    try testing.expectEqual(@as(usize, 0), (try r.at(&.{x}, .nobody, .open, 13 * min)).alerts.len);
}

test "ControlNotify: nothing is sent for a muted group, and it is not held over for when the mute ends (task 1659)" {
    var r: Run = .{};
    defer r.deinit();
    var x = row("web", .needs_approval, 0, sup);
    x.muted = true;
    try testing.expectEqual(@as(usize, 0), (try r.at(&.{x}, .nobody, .open, 10 * min)).alerts.len);
    // Another group waiting at the same time is not muted with it.
    var y = row("api", .needs_answer, 0, worker);
    y.steward = null;
    try testing.expectEqual(@as(usize, 1), (try r.at(&.{ x, y }, .nobody, .open, 11 * min)).alerts.len);
}

test "ControlNotify: the same supervisor's other group is named alone, the muted one not counted in it (task 1659)" {
    var r: Run = .{};
    defer r.deinit();
    var x = row("web", .needs_approval, 0, worker);
    x.muted = true;
    const z = row("api", .needs_answer, 0, 0xc3);
    const d = try r.at(&.{ x, z }, .nobody, .open, 10 * min);
    try testing.expectEqual(@as(usize, 1), d.alerts.len);
    try testing.expectEqualStrings("api", d.alerts[0].group);
    try testing.expectEqual(@as(usize, 0), d.alerts[0].more);
}

test "ControlNotify: not while the card is in sight or the person is in the terminal, and then never" {
    const rows = [_]Row{row("web", .needs_answer, 0, sup)};
    {
        var r: Run = .{};
        defer r.deinit();
        const looking: Presence = .{ .cards_in_sight = &.{"web"}, .terminals_in_use = &.{} };
        const d = try r.at(&rows, looking, .open, 2 * min);
        try testing.expectEqual(@as(usize, 0), d.alerts.len);
        try testing.expectEqual(Held.Why.card_in_sight, d.held[0].why);
        // They looked away: they saw it, so nothing comes after.
        try testing.expectEqual(@as(usize, 0), (try r.at(&rows, .nobody, .open, 5 * min)).alerts.len);
    }
    {
        var r: Run = .{};
        defer r.deinit();
        const in_it: Presence = .{ .cards_in_sight = &.{}, .terminals_in_use = &.{sup} };
        const d = try r.at(&rows, in_it, .open, 2 * min);
        try testing.expectEqual(@as(usize, 0), d.alerts.len);
        try testing.expectEqual(Held.Why.in_the_terminal, d.held[0].why);
    }
    {
        // Another card in sight, or another terminal in use, is not this.
        var r: Run = .{};
        defer r.deinit();
        const elsewhere: Presence = .{ .cards_in_sight = &.{"api"}, .terminals_in_use = &.{worker} };
        try testing.expectEqual(@as(usize, 1), (try r.at(&rows, elsewhere, .open, 2 * min)).alerts.len);
    }
}

test "ControlNotify: quiet hours hold an answer until they end, and never an approval" {
    var r: Run = .{};
    defer r.deinit();
    const answer = [_]Row{row("web", .needs_answer, 0, sup)};
    const d = try r.at(&answer, .nobody, .{ .closed_for_ms = 60 * min }, 2 * min);
    try testing.expectEqual(@as(usize, 0), d.alerts.len);
    try testing.expectEqual(Held.Why.quiet_hours, d.held[0].why);
    try testing.expectEqual(@as(?u64, 62 * min), d.wake_ms);
    // Held, not dealt with: sent when the hours open.
    try testing.expectEqual(@as(usize, 1), (try r.at(&answer, .nobody, .open, 62 * min)).alerts.len);

    var r2: Run = .{};
    defer r2.deinit();
    const approval = [_]Row{row("web", .needs_approval, 0, sup)};
    try testing.expectEqual(@as(usize, 1), (try r2.at(&approval, .nobody, .{ .closed_for_ms = 60 * min }, 2 * min)).alerts.len);
}

test "ControlNotify: a host's report of its control room is read whole or not at all" {
    var s = try Sight.parse(testing.allocator, "{\"in_front\":true,\"cards\":[\"web\",\"api\"]}");
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), s.inSight().len);
    try testing.expectEqualStrings("api", s.inSight()[1]);
    // Behind something else, nothing on it is in sight.
    var behind = try Sight.parse(testing.allocator, "{\"in_front\":false,\"cards\":[\"web\"]}");
    defer behind.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), behind.inSight().len);
    try testing.expectError(error.BadPresence, Sight.parse(testing.allocator, "{\"cards\":[\"web\"]}"));
    try testing.expectError(error.BadPresence, Sight.parse(testing.allocator, "not json"));
}

test "ControlNotify: what has gone is forgotten" {
    var r: Run = .{};
    defer r.deinit();
    _ = try r.at(&.{row("web", .needs_approval, 0, sup)}, .nobody, .open, 2 * min);
    try testing.expectEqual(@as(u32, 1), r.n.done.count());
    _ = try r.at(&.{row("web", .working, 3 * min, sup)}, .nobody, .open, 4 * min);
    try testing.expectEqual(@as(u32, 0), r.n.done.count());
}

test "ControlNotify 1531: what went out as \"N more\" has been said, and is not called again when the first stops" {
    var r: Run = .{};
    defer r.deinit();
    var b = row("r11b", .needs_approval, 0, worker);
    var c = row("r11c", .needs_approval, 0, 0xb3);
    c.who = "worker-c";
    const both = [_]Row{ b, c };
    const d = try r.at(&both, .nobody, .open, 2 * min);
    try testing.expectEqual(@as(usize, 1), d.alerts.len);
    try testing.expectEqualStrings("r11b", d.alerts[0].group);
    try testing.expectEqual(@as(usize, 1), d.alerts[0].more);

    // r11b is answered; r11c is still on the same prompt it was counted on.
    b.top = .{ .kind = .working, .since_ms = 2 * min + 1_000, .terminal = worker };
    const after = [_]Row{ b, c };
    const e = try r.at(&after, .nobody, .open, 2 * min + 21_000);
    try testing.expectEqual(@as(usize, 0), e.alerts.len);
    try testing.expectEqual(@as(?u64, null), e.wake_ms);

    // Its state changes -- a second prompt -- and that is news.
    c.top = .{ .kind = .needs_approval, .since_ms = 5 * min, .terminal = 0xb3 };
    const changed = [_]Row{ b, c };
    const f = try r.at(&changed, .nobody, .open, 7 * min);
    try testing.expectEqual(@as(usize, 1), f.alerts.len);
    try testing.expectEqualStrings("r11c", f.alerts[0].group);
}

test "ControlNotify 1531: a group that starts waiting after the call is its own news, two minutes on" {
    var r: Run = .{};
    defer r.deinit();
    const b = row("r11b", .needs_approval, 0, worker);
    try testing.expectEqual(@as(usize, 1), (try r.at(&.{b}, .nobody, .open, 2 * min)).alerts.len);

    // r11b still waits; r11c begins later. It was in no call.
    var c = row("r11c", .needs_approval, 3 * min, 0xb3);
    c.who = "worker-c";
    const both = [_]Row{ b, c };
    const early = try r.at(&both, .nobody, .open, 4 * min);
    try testing.expectEqual(@as(usize, 0), early.alerts.len);
    try testing.expectEqual(@as(?u64, 5 * min), early.wake_ms);
    const due = try r.at(&both, .nobody, .open, 5 * min);
    try testing.expectEqual(@as(usize, 1), due.alerts.len);
    try testing.expectEqualStrings("r11c", due.alerts[0].group);
}

test "ControlNotify 1531: in quiet hours an approval leads, and is not held behind an answer" {
    var r: Run = .{};
    defer r.deinit();
    var a = row("ask", .needs_answer, 0, worker);
    a.who = "worker-a";
    var p = row("perm", .needs_approval, 0, 0xb3);
    p.who = "worker-p";
    const d = try r.at(&.{ a, p }, .nobody, .{ .closed_for_ms = 60 * min }, 2 * min);
    try testing.expectEqual(@as(usize, 1), d.alerts.len);
    try testing.expectEqualStrings("perm", d.alerts[0].group);
    try testing.expectEqual(@as(usize, 1), d.alerts[0].more);
}
