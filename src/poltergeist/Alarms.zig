//! A supervisor's alarms, and the reminder a supervisor is given when
//! nothing has reached it for a long while (task 2148).
//!
//! **Why either exists.** A supervisor is an agent; it is woken by what is
//! typed into its terminal and by nothing else. A night was lost (10-24,
//! 3:57 to 12:10) to a supervisor waiting on a condition that could not
//! come true, with every worker gone and nothing left to type anything at
//! it. An alarm is a wake the supervisor sets for itself; the reminder is
//! the wake it gets when it set none and nobody else woke it either.
//!
//! **Kept by group, not by terminal.** Terminal ids are new after a restart
//! and group names are not; an alarm is the group's supervisor's, whoever
//! that is when it rings. One that rings while the group has no supervisor
//! -- or one with no agent in its terminal -- waits for one rather than
//! being printed on an empty shell or dropped.
//!
//! Everything here is arithmetic and text; `App.zig` keeps the clocks,
//! the file and the delivery.

const Alarms = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");
const Chat = @import("Chat.zig");

/// A terminal. `Chat.user_id` is the person, and is not one.
pub const Id = Bus.Id;

/// The longest an alarm may be set for. Past this a supervisor should be
/// woken by its workers, and a longer one is refused and says this number.
pub const max_minutes: u32 = 60;

/// The most alarms one group may have standing at once.
pub const per_group: usize = 3;

/// The longest note an alarm carries. It is typed into the supervisor's
/// terminal with the rest of the line, which is 254 bytes at most.
pub const max_note_bytes: usize = 160;

pub const Alarm = struct {
    id: u64,
    /// Owned.
    group: []const u8,
    /// Owned; may be empty.
    note: []const u8,
    minutes: u32,
    /// Wall clock: the file outlives the process, and so must the moment.
    set_ms: i64,
    due_ms: i64,
};

pub const Error = error{
    /// Zero minutes, or more than `max_minutes`.
    BadMinutes,
    /// `per_group` already stand for that group.
    TooManyAlarms,
    NoteTooLong,
    OutOfMemory,
};

alloc: Allocator,
list: std.ArrayListUnmanaged(Alarm) = .empty,
next_id: u64 = 1,
/// When each terminal was last heard from -- a line typed into it by
/// Polter, or a Polter tool called from it -- on the caller's awake clock.
/// A terminal not in here has had nothing since `started_ms`.
heard: std.AutoHashMapUnmanaged(u64, u64) = .empty,
started_ms: u64 = 0,

pub fn init(alloc: Allocator) Alarms {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *Alarms) void {
    for (self.list.items) |a| self.free(a);
    self.list.deinit(self.alloc);
    self.heard.deinit(self.alloc);
    self.* = undefined;
}

fn free(self: *Alarms, a: Alarm) void {
    self.alloc.free(a.group);
    self.alloc.free(a.note);
}

/// Set an alarm for `group`, `minutes` from `now_ms`.
pub fn set(self: *Alarms, group: []const u8, minutes: u32, note: []const u8, now_ms: i64) Error!Alarm {
    if (minutes == 0 or minutes > max_minutes) return error.BadMinutes;
    if (note.len > max_note_bytes) return error.NoteTooLong;
    if (self.countIn(group) >= per_group) return error.TooManyAlarms;
    const g = try self.alloc.dupe(u8, group);
    errdefer self.alloc.free(g);
    const n = try self.alloc.dupe(u8, note);
    errdefer self.alloc.free(n);
    const a: Alarm = .{
        .id = self.next_id,
        .group = g,
        .note = n,
        .minutes = minutes,
        .set_ms = now_ms,
        .due_ms = now_ms + @as(i64, minutes) * std.time.ms_per_min,
    };
    try self.list.append(self.alloc, a);
    self.next_id += 1;
    return a;
}

/// Take alarm `id` off, handing it back for the caller to say and then
/// `release`; null when there is none by that id in `group`.
pub fn cancel(self: *Alarms, group: []const u8, id: u64) ?Alarm {
    for (self.list.items, 0..) |a, i| {
        if (a.id == id and std.mem.eql(u8, a.group, group)) return self.list.orderedRemove(i);
    }
    return null;
}

/// Free an alarm `cancel` or `takeDue` handed back.
pub fn release(self: *Alarms, a: Alarm) void {
    self.free(a);
}

pub fn countIn(self: *const Alarms, group: []const u8) usize {
    var n: usize = 0;
    for (self.list.items) |a| {
        if (std.mem.eql(u8, a.group, group)) n += 1;
    }
    return n;
}

/// Whether `group` has an alarm that has not rung yet.
pub fn pendingIn(self: *const Alarms, group: []const u8, now_ms: i64) bool {
    for (self.list.items) |a| {
        if (a.due_ms > now_ms and std.mem.eql(u8, a.group, group)) return true;
    }
    return false;
}

/// The earliest moment an alarm that has not rung is due; null with none.
/// Ones already due and waiting for somebody to ring at are not counted:
/// what wakes those is somebody coming, not the clock.
pub fn nextDue(self: *const Alarms, now_ms: i64) ?i64 {
    var at: ?i64 = null;
    for (self.list.items) |a| {
        if (a.due_ms <= now_ms) continue;
        at = if (at) |t| @min(t, a.due_ms) else a.due_ms;
    }
    return at;
}

/// Whether any alarm is due and still waiting -- for its group to have a
/// supervisor with an agent in it, or for its line to be typed.
pub fn anyWaiting(self: *const Alarms, now_ms: i64) bool {
    for (self.list.items) |a| {
        if (a.due_ms <= now_ms) return true;
    }
    return false;
}

/// The first alarm that is due and whose group can be told (`ready`), taken
/// off the list. The caller says it and then `release`s it, or -- if the
/// line could not be typed -- puts it back with `restore`.
pub fn takeDue(self: *Alarms, now_ms: i64, ctx: anytype, comptime ready: fn (@TypeOf(ctx), []const u8) bool) ?Alarm {
    for (self.list.items, 0..) |a, i| {
        if (a.due_ms > now_ms) continue;
        if (!ready(ctx, a.group)) continue;
        return self.list.orderedRemove(i);
    }
    return null;
}

/// Put back an alarm `takeDue` handed out whose line was not typed.
pub fn restore(self: *Alarms, a: Alarm) Allocator.Error!void {
    try self.list.append(self.alloc, a);
}

/// The group renamed: its alarms go with it (`group_stores.Table.alarms`).
pub fn renameGroup(self: *Alarms, from: []const u8, to: []const u8) Allocator.Error!void {
    for (self.list.items) |*a| {
        if (!std.mem.eql(u8, a.group, from)) continue;
        const g = try self.alloc.dupe(u8, to);
        self.alloc.free(a.group);
        a.group = g;
    }
}

/// The group is gone: so are its alarms.
pub fn dropGroup(self: *Alarms, group: []const u8) void {
    var i: usize = 0;
    while (i < self.list.items.len) {
        if (std.mem.eql(u8, self.list.items[i].group, group)) {
            self.free(self.list.orderedRemove(i));
        } else i += 1;
    }
}

/// Drop every alarm whose group is gone.
pub fn forgetGroupsNotIn(self: *Alarms, ctx: anytype, comptime exists: fn (@TypeOf(ctx), []const u8) bool) usize {
    var dropped: usize = 0;
    var i: usize = 0;
    while (i < self.list.items.len) {
        const a = self.list.items[i];
        if (exists(ctx, a.group)) {
            i += 1;
            continue;
        }
        self.free(self.list.orderedRemove(i));
        dropped += 1;
    }
    return dropped;
}

// ------------------------------------------------------------- the reminder

/// Polter typed something into terminal `id` at `now_ms`, or the agent in
/// it called a Polter tool: either way that supervisor is alive and
/// working, and its quiet starts again.
///
/// **Every typed line counts** -- a quiet report, a mention, an alarm, the
/// reminder itself -- which is also what keeps the reminder to one per
/// quiet. **A tool call counts too** (`App.poltergeistRequest`): a
/// supervisor that is asking Polter things is not the stuck one this
/// reminder is for, and a supervisor sitting on a condition waits without
/// asking anything.
///
/// ⚠️ **The cost of counting calls**: a supervisor polling `task_list`
/// every minute on a condition that will never come true is never
/// reminded. That is the intended trade -- polling is work, and the night
/// this exists for (10-24) was a supervisor that had stopped calling
/// anything at all.
pub fn noteHeard(self: *Alarms, id: u64, now_ms: u64) void {
    self.heard.put(self.alloc, id, now_ms) catch {};
}

/// How long since anything was heard from terminal `id`.
pub fn quietOf(self: *const Alarms, id: u64, now_ms: u64) u64 {
    return now_ms -| (self.heard.get(id) orelse self.started_ms);
}

/// Drop every terminal we have heard from that is no longer here.
///
/// **The table only ever grows otherwise**: its keys are terminal ids, one
/// entry per terminal this run has ever heard from, and nothing else in
/// this file has a reason to remove one. Small per entry, but it is the
/// shape #2147 was filed about, and the caller already walks every group on
/// the same clock.
pub fn forgetTerminalsNotIn(self: *Alarms, ctx: anytype, comptime exists: fn (@TypeOf(ctx), u64) bool) usize {
    var dropped: usize = 0;
    var it = self.heard.iterator();
    while (it.next()) |kv| {
        if (exists(ctx, kv.key_ptr.*)) continue;
        _ = self.heard.remove(kv.key_ptr.*);
        dropped += 1;
    }
    return dropped;
}

/// What decides whether a supervisor is reminded that nothing has reached
/// it. Every field without a default, so that a caller that forgot one is a
/// compile error and not a reminder sent on a guess.
pub const Quiet = struct {
    /// The terminal that made the group, as `Chat.createdBy` says.
    created_by: Id,
    /// The group's members, in any order (`Chat.membersOf`).
    members: []const Id,
    /// Those of the members that mind the group: `Bus.isSupervisor` and not
    /// `Bus.agentHasLeft`. A supervisor whose agent has gone holds a
    /// terminal nobody is listening in, and a line typed there reaches
    /// nobody (`ControlRoom.minds`).
    minding: []const Id,
    /// Tasks on the group's panel that are not closed or cancelled. `done`
    /// counts: the supervisor has to check a task before closing it, and
    /// "every worker handed in, the supervisor did nothing" is exactly the
    /// case this is for.
    unfinished: usize,
    /// An agent is connected from the supervisor's terminal. A line
    /// printed on an empty shell helps nobody.
    agent_here: bool,
    /// The group has an alarm that has not rung: the supervisor said when
    /// it wants to be woken, and is not woken sooner on our account.
    alarm_pending: bool,
    /// How long since anything was last heard from that terminal: a line
    /// Polter typed into it (a quiet report, a mention, an alarm, this) or
    /// a Polter tool call from it.
    since_heard_ms: u64,
    /// `poltergeist-silence-remind-after`; zero switches it off.
    after_ms: u64,
};

/// The group's supervisor, by **the rule the whole product uses**
/// (`ControlRoom.stewardAmong`): the terminal that made the group while it
/// is still minding it, otherwise whichever member is minding it.
///
/// ⚠️ **Round 2's first defect was reading `created_by` alone.** That is a
/// different question with a different answer, and the three cases it gets
/// wrong are the ordinary ones: **a group the person made** from the
/// control room has `created_by == Chat.user_id` and no supervisor by that
/// rule at all, though it has one; **a take-over or a new supervisor** is
/// not the terminal that made the group; and **after a restart** the
/// creating terminal is gone while the group and its alarms are not --
/// which is the case this whole task is for (an alarm is kept by group
/// *because* terminals are new after a restart).
///
/// Both branches skip `Chat.user_id`: the person is not an agent, and
/// nothing is typed into the control room on its behalf.
pub fn supervisor(q: Quiet) ?Id {
    if (q.created_by != Chat.user_id and
        std.mem.indexOfScalar(Id, q.minding, q.created_by) != null) return q.created_by;
    for (q.members) |id| {
        if (id != Chat.user_id and std.mem.indexOfScalar(Id, q.minding, id) != null) return id;
    }
    return null;
}

/// The same rule, read straight off the bus and the chat -- what
/// `App.groupSupervisor` is, without an `App`.
///
/// **Kept beside `supervisor` and tested against `ControlRoom.stewardAmong`**
/// (`ControlRoom`'s test `2148: …`), because the two are one rule written
/// twice and this is where a drift would hide: nobody reads both files at
/// once.
pub fn supervisorOfGroup(
    arena: Allocator,
    bus: *const Bus,
    chat: *const Chat,
    group: []const u8,
) ?Id {
    const members = chat.membersOf(arena, group) catch return null;
    var minding: std.ArrayListUnmanaged(Id) = .empty;
    for (members) |id| {
        if (id == Chat.user_id) continue;
        if (bus.isSupervisor(id) and !bus.agentHasLeft(id)) {
            minding.append(arena, id) catch return null;
        }
    }
    return supervisor(.{
        .created_by = chat.createdBy(group) catch Chat.user_id,
        .members = members,
        .minding = minding.items,
        // The rest is not this question's: `supervisor` reads the three
        // above and nothing else.
        .unfinished = 0,
        .agent_here = false,
        .alarm_pending = false,
        .since_heard_ms = 0,
        .after_ms = 0,
    });
}

/// Whether that supervisor should be told now that nothing has reached it.
pub fn shouldRemind(q: Quiet) bool {
    if (q.after_ms == 0) return false;
    if (supervisor(q) == null or !q.agent_here) return false;
    if (q.unfinished == 0) return false;
    if (q.alarm_pending) return false;
    return q.since_heard_ms >= q.after_ms;
}

/// What one group's reminder comes to: say it now, and when the clock
/// should look at this group again.
///
/// **Split out of `App.considerSupervisorClocks` because both of round 1's
/// defects were in this arithmetic and neither could be read in that
/// function** (it wants surfaces, so it cannot be run in a test). The two
/// rules it is here to hold:
///
/// ⚠️ **`wake` is always strictly after `now_ms`, or null.** Arms a moment
/// that has already passed and the wake thread fires at once, the app
/// thread plans again, computes the same past moment, and arms it again:
/// that is a core burnt on the app thread for as long as the state lasts
/// (measured 2026-10-24: 12–17 s of CPU per 20 s window while an alarm
/// stood, and the stall probe's own `2495 ms into one tick`). An overdue
/// reminder with nowhere to type it is `recheck_ms` away instead.
///
/// ⚠️ **Reminding arms the next one.** The plan is asked for every group
/// whether or not it is reminded, and a group reminded a moment ago plans
/// its next moment a whole period off -- so the reminder repeats while the
/// silence lasts. Round 1 measured it stopping after two (`§7`), because
/// only the *not-yet-due* branch armed anything.
pub const Reminder = struct {
    /// Type the reminder line into the supervisor's terminal now.
    say: bool,
    /// The moment to arm, or null for "nothing to wait for".
    wake: ?u64,
};

/// How long to come back in while a reminder is due and nowhere can be told
/// it, or an alarm is due with nobody to ring at: nothing else says when a
/// supervisor arrives, and arms a moment the state does not change at.
pub const waiting_recheck_ms: u64 = 60 * std.time.ms_per_s;

/// `recheck_ms` bounds how long a group whose reminder is overdue and
/// cannot be said waits before it is looked at again; it is
/// `waiting_recheck_ms` for the app.
pub fn plan(q: Quiet, now_ms: u64, recheck_ms: u64) Reminder {
    // Nothing owed, and nothing a state change cannot bring back: every
    // one of these is decided again when a request arrives, which is where
    // a group, a supervisor or a task comes from.
    if (q.after_ms == 0) return .{ .say = false, .wake = null };
    if (supervisor(q) == null or q.unfinished == 0) return .{ .say = false, .wake = null };
    // An alarm standing is the supervisor's own answer to "when do you want
    // to be woken"; the alarm's own due is what the clock waits for.
    if (q.alarm_pending) return .{ .say = false, .wake = null };

    if (shouldRemind(q)) return .{ .say = true, .wake = now_ms +| q.after_ms };
    if (q.since_heard_ms < q.after_ms) {
        // Not yet: the moment it is due, which the silence makes a whole
        // period wide -- this is the bound round 1's first reminder had
        // none of (2 m 31 s and 5 m 27 s late, on a one-minute setting).
        return .{ .say = false, .wake = now_ms +| (q.after_ms - q.since_heard_ms) };
    }
    // Overdue and still not remindable: with the guards above and
    // `shouldRemind`, the only field left is `agent_here` -- there is
    // nowhere to type it. A line printed on an empty shell helps nobody,
    // and an agent may connect at any moment, so look again shortly rather
    // than spin on the moment that has passed.
    //
    // `@max` rather than trust: a caller passing a recheck of zero would
    // put this straight back into the loop the paragraph above is about,
    // and the guarantee is what the function is for.
    return .{ .say = false, .wake = now_ms +| @max(recheck_ms, 1) };
}

/// The reminder, said in full.
pub fn quietLine(buf: []u8, group: []const u8, after_ms: u64) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "[polter] {s}：{d} 分钟没有任何 worker 反馈，也没有闹钟，请看一下整体情况，是否卡住了。",
        .{ group, after_ms / std.time.ms_per_min },
    ) catch "";
}

// ------------------------------------------------------------ what is said

/// `hh:mm` of a wall-clock moment, in the offset given.
fn clock(buf: []u8, wall_ms: i64, offset_s: i64) []const u8 {
    const s = @divFloor(wall_ms, std.time.ms_per_s) + offset_s;
    const day_s = @mod(s, std.time.s_per_day);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(@divFloor(day_s, std.time.s_per_hour))),
        @as(u64, @intCast(@divFloor(@mod(day_s, std.time.s_per_hour), std.time.s_per_min))),
    }) catch "?";
}

/// The line typed into the supervisor's terminal when an alarm rings, with
/// how late it is when it rings late (a restart, nobody to ring at).
pub fn ringLine(buf: []u8, a: Alarm, now_ms: i64, offset_s: i64) []const u8 {
    var at: [8]u8 = undefined;
    var late: [48]u8 = undefined;
    const late_min = @divFloor(now_ms - a.due_ms, std.time.ms_per_min);
    const late_s = if (late_min >= 1)
        std.fmt.bufPrint(&late, "，迟了 {d} 分钟", .{late_min}) catch ""
    else
        "";
    return std.fmt.bufPrint(buf, "[polter] 闹钟 #{d} 到了（{s}，{s} 设的 {d} 分钟{s}）{s}{s}", .{
        a.id,
        a.group,
        clock(&at, a.set_ms, offset_s),
        a.minutes,
        late_s,
        if (a.note.len > 0) "：" else "",
        a.note,
    }) catch "";
}

pub const Event = enum { set, cancelled, rang };

/// The line left in the group for each of the three, so that the record
/// says when the supervisor meant to look again. No mention: it is the
/// supervisor's own line and is delivered to nobody.
pub fn traceLine(buf: []u8, ev: Event, a: Alarm, offset_s: i64) []const u8 {
    var due: [8]u8 = undefined;
    const what = switch (ev) {
        .set => "设了闹钟",
        .cancelled => "取消了闹钟",
        .rang => "闹钟到了",
    };
    return std.fmt.bufPrint(buf, "⏰ {s} #{d}：{d} 分钟，{s} 到点{s}{s}", .{
        what,
        a.id,
        a.minutes,
        clock(&due, a.due_ms, offset_s),
        if (a.note.len > 0) "。备注：" else "",
        a.note,
    }) catch "";
}

// ---------------------------------------------------------------- the file

/// The alarms as the file holds them.
pub fn render(self: *const Alarms, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{} };
    s.beginObject() catch return error.WriteFailed;
    s.objectField("next_id") catch return error.WriteFailed;
    s.write(self.next_id) catch return error.WriteFailed;
    s.objectField("alarms") catch return error.WriteFailed;
    s.beginArray() catch return error.WriteFailed;
    for (self.list.items) |a| s.write(a) catch return error.WriteFailed;
    s.endArray() catch return error.WriteFailed;
    s.endObject() catch return error.WriteFailed;
}

const File = struct {
    next_id: u64 = 1,
    alarms: []const Alarm = &.{},
};

/// Read back what `render` wrote, adding to what is held. A file that will
/// not parse is nothing, and says so to the caller (false): an alarm is a
/// reminder, and a broken record of one is worth no more than a missing
/// one -- but it is not the same answer as an empty list.
pub fn load(self: *Alarms, bytes: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const f = std.json.parseFromSliceLeaky(File, arena.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch return false;
    for (f.alarms) |a| {
        if (a.minutes == 0 or a.minutes > max_minutes) continue;
        const g = self.alloc.dupe(u8, a.group) catch return false;
        const n = self.alloc.dupe(u8, a.note) catch {
            self.alloc.free(g);
            return false;
        };
        self.list.append(self.alloc, .{ .id = a.id, .group = g, .note = n, .minutes = a.minutes, .set_ms = a.set_ms, .due_ms = a.due_ms }) catch {
            self.alloc.free(g);
            self.alloc.free(n);
            return false;
        };
        self.next_id = @max(self.next_id, a.id + 1);
    }
    self.next_id = @max(self.next_id, f.next_id);
    return true;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;
const min = std.time.ms_per_min;

test "2148: an alarm is at most 60 minutes and at least one, and a group holds three" {
    var al = Alarms.init(testing.allocator);
    defer al.deinit();
    const long = al.set("build", 61, "", 0);
    try testing.expectError(error.BadMinutes, long);
    const none = al.set("build", 0, "", 0);
    try testing.expectError(error.BadMinutes, none);
    const a = try al.set("build", 60, "check the round", 1_000);
    try testing.expectEqual(@as(i64, 1_000 + 60 * min), a.due_ms);
    _ = try al.set("build", 5, "", 0);
    _ = try al.set("build", 5, "", 0);
    const fourth = al.set("build", 5, "", 0);
    try testing.expectError(error.TooManyAlarms, fourth);
    // Another group's are its own.
    _ = try al.set("docs", 5, "", 0);
}

test "2148: what is due rings once, for a group that can be told, and waits otherwise" {
    var al = Alarms.init(testing.allocator);
    defer al.deinit();
    _ = try al.set("build", 10, "look", 0);
    _ = try al.set("docs", 20, "", 0);
    try testing.expectEqual(@as(?i64, 10 * min), al.nextDue(0));
    const Ready = struct {
        fn no(_: void, _: []const u8) bool {
            return false;
        }
        fn yes(_: void, _: []const u8) bool {
            return true;
        }
    };
    // Nobody to ring at: it waits, and is not the clock's to wake for.
    try testing.expect(al.takeDue(11 * min, {}, Ready.no) == null);
    try testing.expect(al.anyWaiting(11 * min));
    try testing.expectEqual(@as(?i64, 20 * min), al.nextDue(11 * min));
    // Somebody came: it rings, and is gone.
    const rung = al.takeDue(30 * min, {}, Ready.yes).?;
    defer al.release(rung);
    try testing.expectEqualStrings("build", rung.group);
    var buf: [256]u8 = undefined;
    const line = ringLine(&buf, rung, 30 * min, 0);
    try testing.expect(std.mem.indexOf(u8, line, "迟了 20 分钟") != null);
    try testing.expect(std.mem.endsWith(u8, line, "：look"));
}

test "2148: the reminder comes after the quiet and not with an alarm, a supervisor missing, or nothing open" {
    const base: Quiet = .{
        .created_by = 0xa1,
        .members = &SELF_GROUP,
        .minding = &SELF_MINDING,
        .unfinished = 2,
        .agent_here = true,
        .alarm_pending = false,
        .since_heard_ms = 15 * min,
        .after_ms = 15 * min,
    };
    try testing.expect(shouldRemind(base));
    var q = base;
    q.since_heard_ms = 15 * min - 1;
    try testing.expect(!shouldRemind(q));
    q = base;
    q.alarm_pending = true;
    try testing.expect(!shouldRemind(q));
    q = base;
    q.minding = &.{};
    try testing.expect(!shouldRemind(q));
    q = base;
    q.agent_here = false;
    try testing.expect(!shouldRemind(q));
    q = base;
    q.unfinished = 0;
    try testing.expect(!shouldRemind(q));
    q = base;
    q.after_ms = 0;
    try testing.expect(!shouldRemind(q));
}

/// A group whose supervisor is `SUP`, and nobody else in it.
const SELF_GROUP: [1]Id = .{0xa1};
const SELF_MINDING: [1]Id = .{0xa1};

test "2148: the group's supervisor is the product's rule, not whoever made the group" {
    // ⚠️ **Round 2's first defect, turned into a criterion.** Reading
    // `created_by` alone is a different question with a different answer,
    // and the three cases it gets wrong are the ordinary ones. Each is
    // asserted here with the shape the app actually hands over.
    const made_it: Quiet = overdueWith(.{ .created_by = 0xa1, .members = &SELF_GROUP, .minding = &SELF_MINDING });
    // 1. It made the group and still minds it: it is the group's.
    try testing.expectEqual(@as(?Id, 0xa1), supervisor(made_it));

    // 2. **A group the person made** (`created_by == Chat.user_id`, the
    //    control room's "start a supervisor"): the person is not a
    //    supervisor, so the rule moves on to whoever in the group is.
    const users: [2]Id = .{ Chat.user_id, 0xb2 };
    const users_minding: [1]Id = .{0xb2};
    const by_user: Quiet = overdueWith(.{ .created_by = Chat.user_id, .members = &users, .minding = &users_minding });
    try testing.expectEqual(@as(?Id, 0xb2), supervisor(by_user));

    // 3. **Taken over**: the terminal that made the group is still in it
    //    and is no supervisor any more; another member is.
    const taken: [2]Id = .{ 0xa1, 0xb2 };
    const taken_minding: [1]Id = .{0xb2};
    const replaced: Quiet = overdueWith(.{ .created_by = 0xa1, .members = &taken, .minding = &taken_minding });
    try testing.expectEqual(@as(?Id, 0xb2), supervisor(replaced));

    // 4. **After a restart**: the creating terminal is gone -- terminal ids
    //    do not outlive the run -- while the group and its alarms do. This
    //    is the case alarms are kept by group *for*.
    const restarted: Quiet = overdueWith(.{ .created_by = 0xa1, .members = &taken_minding, .minding = &taken_minding });
    try testing.expectEqual(@as(?Id, 0xb2), supervisor(restarted));

    // 5. A member whose agent has left minds nothing (`ControlRoom.minds`):
    //    a line typed there reaches nobody, so it is not the group's.
    try testing.expectEqual(@as(?Id, null), supervisor(overdueWith(.{ .minding = &.{} })));

    // **And it is what the reminder and the alarm go by**, not a second
    // rule beside them: with the group's supervisor found by the rule, the
    // reminder is due; with nobody minding it, it is not.
    try testing.expect(shouldRemind(by_user));
    try testing.expect(!shouldRemind(overdueWith(.{ .minding = &.{} })));
}

test "2148: the person is never the group's supervisor, however the group was made" {
    // The person's terminal is `Chat.user_id` and has no agent behind it.
    // Both branches of the rule skip it, or a control-room group would
    // report a supervisor nothing can be typed into.
    const only_person: [1]Id = .{Chat.user_id};
    const person_minding: [1]Id = .{Chat.user_id};
    try testing.expectEqual(@as(?Id, null), supervisor(overdueWith(.{
        .created_by = Chat.user_id,
        .members = &only_person,
        .minding = &person_minding,
    })));
}

/// The state round 1's hot loop was in: a group with open tasks and a quiet
/// that ran out long ago, with nothing typed into the supervisor's terminal
/// since.
const overdue: Quiet = .{
    .created_by = 0xa1,
    .members = &SELF_GROUP,
    .minding = &SELF_MINDING,
    .unfinished = 1,
    .agent_here = true,
    .alarm_pending = false,
    .since_heard_ms = 15 * min,
    .after_ms = 15 * min,
};

test "2148: a plan never wakes the clock for a moment that has gone by" {
    // ⚠️ **The floor of the defect, and the reason `arm` is safe.** Round 1
    // armed `quietEndsAt` -- an absolute instant already in the past -- and
    // `ControlWake.arm` reads a past moment as "now", so each pass fired at
    // once and the next pass computed the same past moment: the app thread
    // burnt a core for as long as the state lasted (12-17 s of CPU per 20 s
    // window while an alarm stood, measured 2026-10-24).
    //
    // **What this asserts**: over 1000 turns of "arm what the plan says and
    // look again at that moment", not one wake is at or before the moment
    // it was asked at. A plan that handed back a past instant -- or `now`
    // itself -- fails on the first turn.
    var now: u64 = 1_000_000;
    var turns: usize = 0;
    while (turns < 1000) : (turns += 1) {
        // Every shape of quiet the app can hand over, at every turn.
        const states = [_]Quiet{
            overdue,
            overdueWith(.{ .alarm_pending = true }),
            overdueWith(.{ .agent_here = false }),
            overdueWith(.{ .since_heard_ms = 0 }),
            overdueWith(.{ .minding = &.{} }),
            overdueWith(.{ .unfinished = 0 }),
            overdueWith(.{ .after_ms = 0 }),
        };
        for (states) |q| {
            const r = plan(q, now, 60_000);
            if (r.wake) |at| try testing.expect(at > now);
        }
        const r = plan(overdue, now, 60_000);
        try testing.expect(r.say);
        // An assertion, not a `.?`: a plan that leaves nothing to wait for
        // is the round-1 defect, and it should be named as a failed
        // expectation rather than as a panic on the line below.
        try testing.expect(r.wake != null);
        now = r.wake.?;
    }
    // And the 1000 turns really did move: a wake equal to `now` would have
    // left it where it started.
    try testing.expectEqual(@as(u64, 1_000_000 + 1000 * 15 * min), now);
}

fn overdueWith(over: anytype) Quiet {
    var q = overdue;
    inline for (@typeInfo(@TypeOf(over)).@"struct".fields) |f| {
        @field(q, f.name) = @field(over, f.name);
    }
    return q;
}

test "2148: an hour of one group wakes the clock once per period, not once per turn" {
    // ⚠️ **The counted form of the same floor.** The guarantee above is
    // one-sided; this says what it buys, in the words the round-1 defect
    // needs: how many times the wake thread is told to come back within one
    // hour. The loop below is the wake thread's own (`ControlWake.main`:
    // fire at the armed moment, ask the app again, arm what it says), with
    // no thread and no waiting -- the clock is the parameter.
    //
    // Round 1's arithmetic handed back a past moment every time, so this
    // loop would never advance: that is the core it burnt, in one test.
    //
    // **The ceiling**: an hour at a one-minute period is 60 turns. One more
    // than that means a turn that did not move the clock.
    const period = std.time.ms_per_min;
    var q: Quiet = overdue;
    q.since_heard_ms = 20 * min;
    q.after_ms = period;

    const hour = 60 * std.time.ms_per_min;
    var now: u64 = 1_000;
    const ends = now + hour;
    var wakeups: usize = 0;
    while (now < ends) {
        // Also the thing an unbounded loop would fail first: the clock
        // moves forward on every turn, or the count has no ceiling.
        try testing.expect(wakeups < 61);
        const r = plan(q, now, waiting_recheck_ms);
        const at = r.wake orelse break;
        try testing.expect(at > now);
        now = at;
        wakeups += 1;
    }
    try testing.expectEqual(@as(usize, 60), wakeups);
}

test "2148: the round-1 hot loop's own state arms nothing, rather than a moment gone by" {
    // The exact shape §6 was measured in: a group with an open task, a
    // quiet that ran out, **and an alarm standing** -- the tool's own
    // description tells a supervisor to set one while it waits. Round 1
    // took the `else if` branch and armed `quietEndsAt`, an instant already
    // in the past, once per pass.
    var q: Quiet = overdue;
    q.alarm_pending = true;
    q.since_heard_ms = 20 * min;
    const r = plan(q, 5_000, 60_000);
    try testing.expect(!r.say);
    // Not `5_000`, and not anything at or before it: the alarm's own due is
    // what the caller waits for, and `considerSupervisorClocks` arms that.
    try testing.expect(r.wake == null);

    // With no agent in the terminal either, the same as before: a recheck,
    // not the moment that has gone.
    var no_agent: Quiet = q;
    no_agent.alarm_pending = false;
    no_agent.agent_here = false;
    const w = plan(no_agent, 5_000, 60_000);
    try testing.expect(!w.say);
    try testing.expectEqual(@as(u64, 65_000), w.wake.?);
}

test "2148: the first reminder is bounded by the period, not by the last thing that happened" {
    // Round 1's second defect: nothing recomputed the wake when a group
    // appeared, so the first reminder came whenever the last alarm
    // operation (or the process start) happened to be -- 2 m 31 s and
    // 5 m 27 s late on a one-minute setting, with no bound at all.
    const quiet_just_now: Quiet = .{
        .created_by = 0xa1,
        .members = &SELF_GROUP,
        .minding = &SELF_MINDING,
        .unfinished = 1,
        .agent_here = true,
        .alarm_pending = false,
        .since_heard_ms = 0,
        .after_ms = 15 * min,
    };
    const at = plan(quiet_just_now, 1_000, 60_000).wake.?;
    try testing.expectEqual(@as(u64, 1_000 + 15 * min), at);

    var half: Quiet = quiet_just_now;
    half.since_heard_ms = 7 * min;
    try testing.expectEqual(@as(u64, 1_000 + 8 * min), plan(half, 1_000, 60_000).wake.?);

    // **And the caller asks again whenever anything that decides it has
    // changed** (`App.alarm_dirty`, set on every request): a group whose
    // tasks appear after the first tick arms its first reminder then,
    // rather than at the next alarm operation or restart.
    const nothing_yet: Quiet = .{
        .created_by = 0xa1,
        .members = &SELF_GROUP,
        .minding = &SELF_MINDING,
        .unfinished = 0,
        .agent_here = true,
        .alarm_pending = false,
        .since_heard_ms = 0,
        .after_ms = 15 * min,
    };
    try testing.expect(plan(nothing_yet, 1_000, 60_000).wake == null);
    var now_there: Quiet = nothing_yet;
    now_there.unfinished = 1;
    try testing.expectEqual(@as(u64, 1_000 + 15 * min), plan(now_there, 1_000, 60_000).wake.?);
}

test "2148: a reminder that is said arms the next one, so it repeats while the silence lasts" {
    // Round 1's third defect: the reminder rang twice and stopped (§7),
    // because only the not-yet-due branch armed anything. Saying it must
    // leave a moment behind, or the clock has nothing to wait for.
    var q = overdue;
    q.since_heard_ms = 20 * min;
    const said = plan(q, 5_000, 60_000);
    try testing.expect(said.say);
    // ⚠️ **Asserted before it is unwrapped.** Round 1 armed nothing here --
    // the `say` branch only printed -- so the moment it left behind is the
    // whole of what this test is for. `.?` alone would be a panic rather
    // than a failed assertion, and a panic names the line less usefully.
    try testing.expect(said.wake != null);
    try testing.expectEqual(@as(u64, 5_000 + 15 * min), said.wake.?);
    // At that moment, and with nothing having been typed since, it is due
    // again -- and says so again.
    const again = plan(q, said.wake.?, 60_000);
    try testing.expect(again.say);
}

test "2148: overdue with nowhere to type it waits a recheck, it does not spin" {
    // The one state left after the guards: due, and no agent in the
    // supervisor's terminal. There is no moment whose passing changes that
    // -- an agent connects when a person or a launch puts one there -- so
    // the plan hands back a recheck rather than the moment that has gone.
    var q = overdue;
    q.agent_here = false;
    q.since_heard_ms = 20 * min;
    const r = plan(q, 9_000, 60_000);
    try testing.expect(!r.say);
    try testing.expectEqual(@as(u64, 9_000 + 60_000), r.wake.?);
}

test "2148: what is not owed arms nothing at all" {
    const none: [4]Quiet = .{
        overdueWith(.{ .unfinished = 0 }),
        overdueWith(.{ .minding = &.{} }),
        overdueWith(.{ .alarm_pending = true }),
        overdueWith(.{ .after_ms = 0 }),
    };
    for (none) |q| {
        const r = plan(q, 1_000, 60_000);
        try testing.expect(!r.say);
        try testing.expect(r.wake == null);
    }
}

test "2148: anything heard from the supervisor's terminal starts its quiet again" {
    var al = Alarms.init(testing.allocator);
    defer al.deinit();
    al.started_ms = 1_000;
    // Nothing yet: counted from the start.
    try testing.expectEqual(@as(u64, 15 * min), al.quietOf(7, 1_000 + 15 * min));
    al.noteHeard(7, 10 * min);
    const after = al.quietOf(7, 20 * min);
    try testing.expectEqual(@as(u64, 10 * min), after);
    // Another terminal's line is not this one's.
    try testing.expectEqual(@as(u64, 20 * min - 1_000), al.quietOf(8, 20 * min));
}

test "2148: an alarm goes with its group's new name, and with the group" {
    var al = Alarms.init(testing.allocator);
    defer al.deinit();
    _ = try al.set("build", 10, "", 0);
    _ = try al.set("docs", 10, "", 0);
    try al.renameGroup("build", "ship");
    try testing.expectEqual(@as(usize, 1), al.countIn("ship"));
    try testing.expectEqual(@as(usize, 0), al.countIn("build"));
    al.dropGroup("docs");
    try testing.expectEqual(@as(usize, 1), al.list.items.len);
}

test "2148: the file brings the alarms back, numbering on from where it was" {
    var al = Alarms.init(testing.allocator);
    defer al.deinit();
    _ = try al.set("build", 30, "round 9", 5 * min);
    const gone = try al.set("docs", 10, "", 0);
    al.release(al.cancel("docs", gone.id).?);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try al.render(&out.writer);

    var back = Alarms.init(testing.allocator);
    defer back.deinit();
    try testing.expect(back.load(out.written()));
    try testing.expectEqual(@as(usize, 1), back.list.items.len);
    try testing.expectEqualStrings("round 9", back.list.items[0].note);
    try testing.expectEqual(@as(i64, 35 * min), back.list.items[0].due_ms);
    const next = try back.set("build", 5, "", 0);
    try testing.expectEqual(@as(u64, 3), next.id);
    try testing.expect(!back.load("not json"));
}
