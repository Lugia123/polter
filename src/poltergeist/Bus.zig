//! Who is watching whom, and what each watched terminal is allowed to do.
//!
//! One bus per app. It holds the roles, the duty state, and the work mode of
//! every terminal Poltergeist knows about, and it decides whether a
//! quiescence report is worth putting in front of the supervisor.
//!
//! What it does *not* do is decide what a quiet terminal means. That is the
//! supervisor AI's job, and this file exists partly to keep that boundary
//! from eroding: everything here is bookkeeping and rate limiting, with no
//! reading of screen contents anywhere.
//!
//! Poltergeist also never holds tasks. There is no queue here, no task list,
//! and no scheduling -- work comes from whatever system the agents already
//! read from. See `docs/poltergeist/mcp.md`.
//!
//! Pure: no allocation beyond the registry, time arrives as a parameter.

const Bus = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Sampler = @import("Sampler.zig");

/// A terminal's identity. This is `Surface.id`, which Ghostty already
/// assigns and already exports to child processes as `GHOSTTY_SURFACE_ID`,
/// so agents and the bus agree on names without inventing a second scheme.
pub const Id = u64;

pub const Role = enum {
    /// Known to the bus but neither supervising nor supervised.
    none,

    /// The terminal whose agent is minding the others.
    supervisor,

    /// Watched by the supervisor.
    watched,
};

/// Whether a terminal is still expected to be working.
pub const Duty = enum {
    /// On duty. Quiescence here is worth telling the supervisor about.
    on,

    /// Clocked off. The supervisor decided there was no more to do, so
    /// going quiet is expected and is not reported again.
    off,
};

pub const WorkMode = enum {
    /// The supervisor may clock this terminal off once its skill says
    /// there is no more worth doing.
    clock_off,

    /// Keep working within a standing direction the user set. Never clocks
    /// off.
    infinite_directed,

    /// Finish one task, move to the next. Never clocks off.
    infinite_sequential,

    /// Whether the program refuses to clock this terminal off.
    ///
    /// This is enforced here rather than written into the supervisor's
    /// prompt on purpose: a prompt gets pushed out of a long session's
    /// context, and running unattended overnight is exactly when that
    /// happens. Code does not forget.
    pub fn forbidsClockOff(self: WorkMode) bool {
        return switch (self) {
            .clock_off => false,
            .infinite_directed, .infinite_sequential => true,
        };
    }
};

/// Who is asking for a change. Some changes are the user's alone.
pub const Authority = enum { user, supervisor };

pub const ClockOffError = error{
    /// The terminal's work mode forbids clocking off.
    WorkModeForbids,

    /// The bus has never heard of this terminal.
    UnknownTerminal,

    /// Only the supervisor clocks terminals off.
    NotPermitted,
};

pub const SetModeError = error{
    UnknownTerminal,

    /// The supervisor may not change a work mode. Otherwise the rule that
    /// infinite modes cannot clock off would be worth nothing: the
    /// supervisor would simply switch the mode first and then clock off.
    NotPermitted,
};

/// What a report says happened, and all that is kept of one.
///
/// No screen contents anywhere -- the supervisor reads the other terminal
/// itself if it wants to know what is on it, which keeps the judgement (and
/// the reading) on the AI's side of the line. Durations are not stored
/// either: `quietMs` computes the true figure on demand, so a report that
/// sat in the box says how long the terminal has been quiet now rather than
/// how long it had been when it arrived.
pub const NoticeKind = enum { quiescent, still_quiescent, resumed };

pub const Entry = struct {
    role: Role = .none,
    duty: Duty = .on,
    work_mode: WorkMode = .clock_off,

    /// When this terminal last produced a notice, for rate limiting.
    last_notice_ms: ?u64 = null,

    /// How long the screen had been unchanged as of the last report, and
    /// when that report arrived. Together these give the current figure
    /// exactly; see `Bus.quietMs`.
    last_quiet_ms: u64 = 0,
    last_event_ms: u64 = 0,

    /// How many times the supervisor has been told this terminal is quiet
    /// since it last came back to work.
    ///
    /// Kept here because a count is the first thing a long session forgets,
    /// and the clock-out skill needs one. The judgement of whether there is
    /// anything left to do stays with the supervisor; this is only the
    /// number it counts against.
    rounds: u16 = 0,

    /// What the supervisor has not been shown about this terminal yet.
    ///
    /// One slot, not a queue. A terminal that has been still for an hour
    /// has one thing to say -- that it has been still for an hour -- not
    /// four copies of it a repeat interval apart. Merging as they arrive is
    /// what keeps what the supervisor receives proportional to how many
    /// terminals there are, rather than to how long they have been quiet or
    /// how often anyone looked.
    ///
    /// A later kind overwrites an earlier one, so a terminal that went
    /// quiet and came back before anybody read the box reads as back at
    /// work. That is the true state, and the excursion in between is
    /// precisely the case where nobody needed to do anything.
    pending: ?NoticeKind = null,
};

pub const Config = struct {
    /// Least time between two interruptions of the supervisor.
    ///
    /// Nothing is put in front of the supervisor as it happens. Reports go
    /// into the box and are handed over on this interval, all of them at
    /// once. So this bounds how often the supervisor is interrupted no
    /// matter how many terminals are watched or how often they report --
    /// the per-terminal gap above cannot do that, because every terminal
    /// keeps its own clock and ten of them make ten times the noise.
    ///
    /// A minute by default, on the grounds that a terminal which has been
    /// still long enough to be worth mentioning is not going to become
    /// urgent in the next sixty seconds. The supervisor can always look
    /// sooner: reading the box itself is not on this schedule.
    notice_interval_ms: u64 = std.time.ms_per_min,
};

alloc: Allocator,
config: Config,
entries: std.AutoHashMapUnmanaged(Id, Entry) = .empty,

/// The current supervisor, if one has been named.
///
/// One at a time. Two supervisors watching the same terminal would each
/// nudge it without knowing about the other, and the terminal on the
/// receiving end has no way to tell the difference.
supervisor: ?Id = null,

/// When the box was last handed to the supervisor on its own initiative.
/// Null until the first delivery.
last_delivery_ms: ?u64 = null,

pub fn init(alloc: Allocator, config: Config) Bus {
    return .{ .alloc = alloc, .config = config };
}

pub fn deinit(self: *Bus) void {
    self.entries.deinit(self.alloc);
    self.* = undefined;
}

/// Start tracking a terminal. Idempotent.
pub fn register(self: *Bus, id: Id) Allocator.Error!void {
    const gop = try self.entries.getOrPut(self.alloc, id);
    if (!gop.found_existing) gop.value_ptr.* = .{};
}

/// Stop tracking a terminal, for example because it closed.
pub fn unregister(self: *Bus, id: Id) void {
    _ = self.entries.remove(id);
    if (self.supervisor == id) self.supervisor = null;
}

pub fn get(self: *const Bus, id: Id) ?Entry {
    return self.entries.get(id);
}

/// How long this terminal's screen has been unchanged, as of now.
///
/// Extrapolated rather than stale, and exactly so: a screen that changed
/// would have produced a `resumed` report, so the absence of one since the
/// last report means it has not changed since either. Adding the elapsed
/// time is therefore the true figure, not an estimate.
pub fn quietMs(self: *const Bus, id: Id, now_ms: u64) u64 {
    const e = self.entries.get(id) orelse return 0;
    return e.last_quiet_ms + (now_ms -| e.last_event_ms);
}

/// Name the supervisor. Naming a new one steps the previous one down.
pub fn setSupervisor(self: *Bus, id: Id) Allocator.Error!void {
    try self.register(id);

    if (self.supervisor) |old| {
        if (old != id) {
            if (self.entries.getPtr(old)) |e| e.role = .none;
        }
    }

    self.entries.getPtr(id).?.role = .supervisor;
    self.supervisor = id;
}

/// Put a terminal under the supervisor's eye.
pub fn watch(self: *Bus, id: Id) Allocator.Error!void {
    try self.register(id);
    const e = self.entries.getPtr(id).?;
    if (e.role == .supervisor) return;
    e.role = .watched;
    e.duty = .on;
}

/// Stop watching a terminal, without forgetting it.
pub fn unwatch(self: *Bus, id: Id) void {
    if (self.entries.getPtr(id)) |e| {
        if (e.role == .watched) e.role = .none;
    }
}

/// Set a terminal's work mode. The user only -- see `SetModeError`.
pub fn setWorkMode(
    self: *Bus,
    id: Id,
    mode: WorkMode,
    who: Authority,
) SetModeError!void {
    if (who != .user) return error.NotPermitted;
    const e = self.entries.getPtr(id) orelse return error.UnknownTerminal;
    e.work_mode = mode;
}

/// Clock a terminal off. The supervisor only, and never in a work mode that
/// forbids it.
pub fn clockOff(self: *Bus, id: Id, who: Authority) ClockOffError!void {
    if (who != .supervisor) return error.NotPermitted;
    const e = self.entries.getPtr(id) orelse return error.UnknownTerminal;
    if (e.work_mode.forbidsClockOff()) return error.WorkModeForbids;
    e.duty = .off;
}

/// Put a terminal back on duty. Either the user or the supervisor may do
/// this: coming back to work is not the dangerous direction.
pub fn clockOn(self: *Bus, id: Id) ClockOffError!void {
    const e = self.entries.getPtr(id) orelse return error.UnknownTerminal;
    e.duty = .on;
}

/// Turn a sampler event into a notice for the supervisor, or decide there
/// is nothing worth saying.
///
/// Returns null when there is no supervisor, when the terminal is not
/// watched, when it has clocked off, when it is the supervisor itself, or
/// when it spoke too recently.
pub fn report(
    self: *Bus,
    about: Id,
    event: Sampler.Event,
    now_ms: u64,
) bool {
    const to = self.supervisor orelse return false;
    if (to == about) return false;

    const e = self.entries.getPtr(about) orelse return false;

    const kind: NoticeKind, const report_data = switch (event) {
        .quiescent => |r| .{ NoticeKind.quiescent, r },
        .still_quiescent => |r| .{ NoticeKind.still_quiescent, r },
        .resumed => |r| .{ NoticeKind.resumed, r },
    };

    // Track the duration whatever we decide to do about telling anyone.
    // `terminal_list` reads this, and a terminal that is not being reported
    // -- clocked off, or rate limited -- is still worth answering about
    // when the supervisor asks directly.
    e.last_event_ms = now_ms;
    e.last_quiet_ms = switch (kind) {
        .quiescent, .still_quiescent => report_data.quiet_ms,
        // Just came back to work: the clock starts again from here.
        .resumed => 0,
    };
    e.rounds = switch (kind) {
        .quiescent, .still_quiescent => e.rounds +| 1,
        .resumed => 0,
    };

    if (e.role != .watched) return false;

    // A terminal that has clocked off is supposed to be quiet. Saying so
    // again every quarter of an hour is exactly the kind of nagging that
    // makes someone turn the whole thing off.
    if (e.duty == .off) return false;

    // Into the box. One slot per terminal, so a later report replaces an
    // earlier one rather than stacking behind it.
    //
    // There is no rate limit here any more, and there should not be one: a
    // limit at this end would decide what the supervisor is allowed to find
    // out, and a terminal that went quiet during a busy moment would stay
    // unmentioned for good. How often the supervisor is *interrupted* is a
    // separate question, answered by `notice_interval_ms` at the other end.
    e.pending = kind;
    e.last_notice_ms = now_ms;
    return true;
}

/// What a tab should say about a terminal beyond its own title.
///
/// A short marker rather than a sentence: it sits in front of whatever the
/// program running there called itself, and that title is the part somebody
/// is actually reading.
pub const TabMark = enum {
    /// Nothing to say. The tab shows only the program's own title.
    none,

    /// Watched and working.
    on_duty,

    /// Watched, and the screen has stopped moving.
    quiet,

    /// Done for the day.
    off_duty,

    /// The terminal minding the others.
    supervisor,

    pub fn prefix(self: TabMark) []const u8 {
        return switch (self) {
            .none => "",
            .on_duty => "\u{25CF} ",
            .quiet => "\u{25CB} ",
            .off_duty => "\u{1F4A4} ",
            .supervisor => "\u{2691} ",
        };
    }
};

/// How this terminal's tab should be marked, given how long it has been
/// quiet.
///
/// Takes the quiescence threshold rather than reading one: the bus does not
/// own that number, and passing it in keeps this decidable without a
/// terminal.
pub fn tabMark(self: *const Bus, id: Id, now_ms: u64, quiet_after_ms: u64) TabMark {
    const e = self.entries.get(id) orelse return .none;
    return switch (e.role) {
        .none => .none,
        .supervisor => .supervisor,
        .watched => switch (e.duty) {
            .off => .off_duty,
            .on => if (self.quietMs(id, now_ms) >= quiet_after_ms)
                .quiet
            else
                .on_duty,
        },
    };
}


/// Most terminals named individually in one summary. Beyond this the rest
/// are counted rather than listed: a line long enough to need scrolling is
/// not a line anybody reads, and `terminal_list` gives the full picture to
/// a supervisor that wants it.
const max_listed = 5;

/// Everything the supervisor has not been shown, written into `buf`, and
/// cleared as it goes.
///
/// **Reading is consuming.** What comes back here does not come back again;
/// a terminal that is still quiet will make a fresh entry on its next
/// report. This is the whole point of the box: the supervisor is
/// interrupted on a schedule the user sets, not once per event per
/// terminal, and it never sees the same thing twice.
///
/// Returns null when the box is empty, which is most of the time. Nothing
/// is put in front of the supervisor to say that all is well -- an
/// interruption that carries no information is still an interruption.
///
/// Durations are recomputed here rather than stored at report time, so a
/// notice that waited in the box says how long the terminal has been quiet
/// *now*, not how long it had been when it first came up.
pub fn drain(self: *Bus, now_ms: u64, buf: []u8) ?[]u8 {
    var listed: usize = 0;
    var total: usize = 0;

    // Written into a fixed buffer with a running end, because the whole
    // point is to produce one line for one injection.
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("[poltergeist]") catch return null;

    var it = self.entries.iterator();
    while (it.next()) |kv| {
        const e = kv.value_ptr;
        const kind = e.pending orelse continue;
        e.pending = null;
        total += 1;

        if (listed >= max_listed) continue;

        const sep = if (listed == 0) " " else ", ";
        const written = switch (kind) {
            .quiescent, .still_quiescent => w.print(
                "{s}0x{x:0>16} quiet {d}s",
                .{ sep, kv.key_ptr.*, self.quietMs(kv.key_ptr.*, now_ms) / std.time.ms_per_s },
            ),
            .resumed => w.print(
                "{s}0x{x:0>16} back at work",
                .{ sep, kv.key_ptr.* },
            ),
        };

        // Out of room. What is written already stands, and the rest is
        // covered by the count below. The `pending` flags are cleared
        // either way: they have been accounted for.
        written catch break;
        listed += 1;
    }

    if (total == 0) return null;
    if (total > listed) {
        w.print(" (+{d} more)", .{total - listed}) catch {};
    }

    return w.buffered();
}

/// The box, but only if enough time has passed to interrupt the supervisor
/// again. Null when it is too soon, or when there is nothing to say.
///
/// This is the scheduled hand-over. `drain` is the other way in, for a
/// supervisor that asks of its own accord -- that one is never held back,
/// because somebody choosing to look is not an interruption.
///
/// The clock only advances on a delivery that actually happened. An empty
/// box does not count as having been shown anything, so a terminal going
/// quiet a second after a silent tick is not made to wait another full
/// interval.
pub fn drainIfDue(self: *Bus, now_ms: u64, buf: []u8) ?[]u8 {
    if (self.last_delivery_ms) |last| {
        if (now_ms -| last < self.config.notice_interval_ms) return null;
    }

    const line = self.drain(now_ms, buf) orelse return null;
    self.last_delivery_ms = now_ms;
    return line;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const boss: Id = 0x1111;
const worker: Id = 0x2222;

fn quiet(quiet_ms: u64) Sampler.Event {
    return .{ .quiescent = .{
        .quiet_ms = quiet_ms,
        .silent_ms = quiet_ms,
        .changed_rows = 0,
        .total_rows = 24,
    } };
}

fn testBus() Bus {
    return .init(testing.allocator, .{});
}

test "no supervisor means no notices" {
    var b = testBus();
    defer b.deinit();

    try b.watch(worker);
    try testing.expect(b.report(worker, quiet(60_000), 0) == false);
}

test "a watched terminal going quiet reaches the supervisor" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);

    try testing.expect(b.report(worker, quiet(180_000), 0));
    try testing.expectEqual(NoticeKind.quiescent, b.get(worker).?.pending.?);

    // And it is the supervisor that would be handed it.
    try testing.expectEqual(boss, b.supervisor.?);
}

test "the supervisor is not reported to itself" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try testing.expect(b.report(boss, quiet(180_000), 0) == false);
}

test "an unwatched terminal is not reported" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.register(worker); // known, but not watched
    try testing.expect(b.report(worker, quiet(180_000), 0) == false);
}

test "quiet duration is extrapolated, not left stale" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);

    // Reported still for 180s at t=180_000.
    _ = b.report(worker, quiet(180_000), 180_000);

    // A minute later with no further report. The screen cannot have moved
    // in between -- that would have produced a `resumed` -- so the true
    // figure is 240s, not the 180s that was last announced.
    try testing.expectEqual(@as(u64, 240_000), b.quietMs(worker, 240_000));
}

test "coming back to work restarts the quiet clock" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);

    _ = b.report(worker, quiet(180_000), 180_000);
    _ = b.report(worker, .{ .resumed = .{
        .quiet_ms = 180_000,
        .silent_ms = 0,
        .changed_rows = 4,
        .total_rows = 24,
    } }, 200_000);

    try testing.expectEqual(@as(u64, 0), b.quietMs(worker, 200_000));
    try testing.expectEqual(@as(u64, 5_000), b.quietMs(worker, 205_000));
}

test "a clocked off terminal still answers how long it has been quiet" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);
    try b.clockOff(worker, .supervisor);

    // No notice is produced -- that is the point of clocking off -- but the
    // supervisor asking directly still gets a real answer.
    try testing.expect(b.report(worker, quiet(180_000), 180_000) == false);
    try testing.expectEqual(@as(u64, 200_000), b.quietMs(worker, 200_000));
}

test "an unknown terminal reports no quiet time rather than misleading" {
    var b = testBus();
    defer b.deinit();
    try testing.expectEqual(@as(u64, 0), b.quietMs(0xdead, 999_999));
}

test "rounds count up while quiet and reset on coming back" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);
    try testing.expectEqual(@as(u16, 0), b.get(worker).?.rounds);

    _ = b.report(worker, quiet(180_000), 0);
    try testing.expectEqual(@as(u16, 1), b.get(worker).?.rounds);

    _ = b.report(worker, quiet(190_000), 10_000);
    try testing.expectEqual(@as(u16, 2), b.get(worker).?.rounds);

    _ = b.report(worker, .{ .resumed = .{
        .quiet_ms = 190_000,
        .silent_ms = 0,
        .changed_rows = 2,
        .total_rows = 24,
    } }, 20_000);
    try testing.expectEqual(@as(u16, 0), b.get(worker).?.rounds);
}

test "rounds count every report, not every interruption" {
    // The supervisor is interrupted far less often than the terminals
    // report, but the count is what the clock-out skill reasons about, so
    // it has to follow the terminal rather than the hand-overs.
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);

    try testing.expect(b.report(worker, quiet(180_000), 0));
    try testing.expect(b.report(worker, quiet(181_000), 100));
    try testing.expectEqual(@as(u16, 2), b.get(worker).?.rounds);

    // Both of them are one entry in the box, not two.
    var buf: [255]u8 = undefined;
    const line = b.drain(100, &buf) orelse return error.ExpectedANotice;
    const first = std.mem.indexOf(u8, line, "0x0000000000002222").?;
    try testing.expect(std.mem.indexOfPos(u8, line, first + 1, "0x0000000000002222") == null);
}

test "a clocked off terminal stops being reported" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);

    try b.clockOff(worker, .supervisor);
    try testing.expect(b.report(worker, quiet(180_000), 10_000) == false);

    // Back on duty, reported again.
    try b.clockOn(worker);
    try testing.expect(b.report(worker, quiet(180_000), 20_000));
}

test "infinite work modes cannot be clocked off" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);

    for ([_]WorkMode{ .infinite_directed, .infinite_sequential }) |mode| {
        try b.setWorkMode(worker, mode, .user);
        try testing.expectError(
            error.WorkModeForbids,
            b.clockOff(worker, .supervisor),
        );
        try testing.expectEqual(Duty.on, b.get(worker).?.duty);
    }

    // And the mode that does allow it still does.
    try b.setWorkMode(worker, .clock_off, .user);
    try b.clockOff(worker, .supervisor);
    try testing.expectEqual(Duty.off, b.get(worker).?.duty);
}

test "the supervisor cannot change a work mode to get around the ban" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);
    try b.setWorkMode(worker, .infinite_directed, .user);

    // The obvious way around the rule: switch the mode, then clock off.
    try testing.expectError(
        error.NotPermitted,
        b.setWorkMode(worker, .clock_off, .supervisor),
    );
    try testing.expectEqual(WorkMode.infinite_directed, b.get(worker).?.work_mode);
    try testing.expectError(
        error.WorkModeForbids,
        b.clockOff(worker, .supervisor),
    );
}

test "only the supervisor clocks terminals off" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);

    try testing.expectError(error.NotPermitted, b.clockOff(worker, .user));
}

test "naming a new supervisor steps the old one down" {
    var b = testBus();
    defer b.deinit();

    const second: Id = 0x4444;
    try b.setSupervisor(boss);
    try b.setSupervisor(second);

    try testing.expectEqual(second, b.supervisor.?);
    try testing.expectEqual(Role.none, b.get(boss).?.role);
    try testing.expectEqual(Role.supervisor, b.get(second).?.role);
}

test "watching the supervisor does not demote it" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(boss);
    try testing.expectEqual(Role.supervisor, b.get(boss).?.role);
    try testing.expectEqual(boss, b.supervisor.?);
}

test "closing the supervisor's terminal leaves nobody supervising" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);

    b.unregister(boss);
    try testing.expect(b.supervisor == null);
    try testing.expect(b.report(worker, quiet(180_000), 0) == false);
}

test "register is idempotent and keeps existing state" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);
    try b.setWorkMode(worker, .infinite_directed, .user);

    try b.register(worker);
    try testing.expectEqual(WorkMode.infinite_directed, b.get(worker).?.work_mode);
    try testing.expectEqual(Role.watched, b.get(worker).?.role);
}

test "unknown terminals are rejected rather than silently created" {
    var b = testBus();
    defer b.deinit();

    try testing.expectError(
        error.UnknownTerminal,
        b.setWorkMode(0xdead, .clock_off, .user),
    );
    try b.setSupervisor(boss);
    try testing.expectError(
        error.UnknownTerminal,
        b.clockOff(0xdead, .supervisor),
    );
}

test "an unwatched terminal's tab says nothing" {
    var b = testBus();
    defer b.deinit();

    try testing.expectEqual(TabMark.none, b.tabMark(worker, 0, 1000));
    try b.register(worker);
    try testing.expectEqual(TabMark.none, b.tabMark(worker, 0, 1000));
}

test "a tab mark follows the terminal's role and duty" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);

    try testing.expectEqual(TabMark.supervisor, b.tabMark(boss, 0, 1000));
    try testing.expectEqual(TabMark.on_duty, b.tabMark(worker, 0, 1000));

    try b.clockOff(worker, .supervisor);
    try testing.expectEqual(TabMark.off_duty, b.tabMark(worker, 0, 1000));
}

test "a tab says quiet once the screen has been still long enough" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);
    _ = b.report(worker, quiet(60_000), 60_000);

    try testing.expectEqual(TabMark.on_duty, b.tabMark(worker, 60_000, 120_000));
    try testing.expectEqual(TabMark.quiet, b.tabMark(worker, 180_000, 120_000));
}

test "a clocked off terminal reads as off duty even while quiet" {
    // Off duty is the more useful thing to say: it is quiet because it was
    // told to stop, not because it got stuck.
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);
    _ = b.report(worker, quiet(600_000), 600_000);
    try b.clockOff(worker, .supervisor);

    try testing.expectEqual(TabMark.off_duty, b.tabMark(worker, 600_000, 1000));
}

test "every mark but none has a marker, and none has nothing" {
    try testing.expectEqualStrings("", TabMark.none.prefix());
    for ([_]TabMark{ .on_duty, .quiet, .off_duty, .supervisor }) |m| {
        try testing.expect(m.prefix().len > 0);
        // Trailing space, because it sits in front of a title.
        try testing.expect(m.prefix()[m.prefix().len - 1] == ' ');
    }
}

test "reading the box clears it" {
    // The point of the box: what has been shown once is not shown again.
    var bus = testBus();
    defer bus.deinit();

    try bus.setSupervisor(boss);
    try bus.watch(worker);
    _ = bus.report(worker, quiet(60_000), 1000);

    var buf: [255]u8 = undefined;
    const first = bus.drain(1000, &buf) orelse return error.ExpectedANotice;
    try testing.expect(std.mem.indexOf(u8, first, "0x0000000000002222") != null);
    try testing.expect(std.mem.indexOf(u8, first, "quiet") != null);

    // Nothing new has happened, so there is nothing to say.
    try testing.expect(bus.drain(2000, &buf) == null);
}

test "many reports about one terminal read as one line" {
    // Fifteen repeats of "still quiet" are one fact, not fifteen. This is
    // what keeps the supervisor's screen proportional to how many terminals
    // exist rather than to how long they have been idle.
    var bus = testBus();
    defer bus.deinit();

    try bus.setSupervisor(boss);
    try bus.watch(worker);

    var t: u64 = 1000;
    for (0..15) |_| {
        _ = bus.report(worker, quiet(60_000), t);
        t += 20_000;
    }

    var buf: [255]u8 = undefined;
    const line = bus.drain(t, &buf) orelse return error.ExpectedANotice;

    // One mention of the terminal, and no "+N more".
    const first = std.mem.indexOf(u8, line, "0x0000000000002222").?;
    try testing.expect(std.mem.indexOfPos(u8, line, first + 1, "0x0000000000002222") == null);
    try testing.expect(std.mem.indexOf(u8, line, "more") == null);
}

test "coming back to work replaces the quiet it is waiting on" {
    // Quiet then busy again before anybody read the box: the terminal is
    // working, and that is all worth saying. The excursion in between is
    // exactly the case that needed nobody.
    var bus = testBus();
    defer bus.deinit();

    try bus.setSupervisor(boss);
    try bus.watch(worker);

    _ = bus.report(worker, quiet(60_000), 1000);
    _ = bus.report(worker, .{ .resumed = .{
        .quiet_ms = 0,
        .silent_ms = 0,
        .changed_rows = 3,
        .total_rows = 24,
    } }, 3000);

    var buf: [255]u8 = undefined;
    const line = bus.drain(3000, &buf) orelse return error.ExpectedANotice;
    try testing.expect(std.mem.indexOf(u8, line, "back at work") != null);
    try testing.expect(std.mem.indexOf(u8, line, "quiet") == null);
}

test "an empty box says nothing rather than saying all is well" {
    // An interruption carrying no information is still an interruption.
    var bus = testBus();
    defer bus.deinit();

    try bus.setSupervisor(boss);
    try bus.watch(worker);

    var buf: [255]u8 = undefined;
    try testing.expect(bus.drain(1000, &buf) == null);
}

test "more terminals than fit are counted rather than listed" {
    var bus = testBus();
    defer bus.deinit();

    try bus.setSupervisor(boss);

    var id: Id = 0x100;
    for (0..max_listed + 3) |_| {
        try bus.watch(id);
        _ = bus.report(id, quiet(60_000), 1000);
        id += 1;
    }

    var buf: [255]u8 = undefined;
    const line = bus.drain(1000, &buf) orelse return error.ExpectedANotice;
    try testing.expect(std.mem.indexOf(u8, line, "(+3 more)") != null);

    // Counted or listed, every one of them was consumed.
    try testing.expect(bus.drain(1000, &buf) == null);
}

test "a notice that waited says how long it has been quiet now" {
    // The figure is recomputed on reading, not frozen at report time, so a
    // supervisor reading a minute later is not told a minute-old number.
    var bus = testBus();
    defer bus.deinit();

    try bus.setSupervisor(boss);
    try bus.watch(worker);
    _ = bus.report(worker, quiet(60_000), 1000);

    var buf: [255]u8 = undefined;
    const line = bus.drain(1000 + 30_000, &buf) orelse return error.ExpectedANotice;
    try testing.expect(std.mem.indexOf(u8, line, "quiet 90s") != null);
}

test "a terminal the supervisor never watched is not in the box" {
    var bus = testBus();
    defer bus.deinit();

    try bus.setSupervisor(boss);
    try bus.register(worker);
    _ = bus.report(worker, quiet(60_000), 1000);

    var buf: [255]u8 = undefined;
    try testing.expect(bus.drain(1000, &buf) == null);
}
