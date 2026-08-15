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

/// What gets put in front of the supervisor.
///
/// Only durations and identity -- no screen contents. The supervisor reads
/// the other terminal itself if it wants to know what is on it, which keeps
/// the judgement (and the reading) on the AI's side of the line.
pub const Notice = struct {
    to: Id,
    about: Id,
    kind: Kind,
    quiet_ms: u64,
    silent_ms: u64,

    pub const Kind = enum { quiescent, still_quiescent, resumed };
};

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
};

pub const Config = struct {
    /// Minimum gap between notices about the same terminal.
    ///
    /// A backstop, not the main control: how often a still terminal is
    /// mentioned is the user's to set through the sampler's repeat
    /// interval, and a large value here would silently override that. This
    /// only exists to stop a terminal flapping between quiet and busy from
    /// flooding the supervisor.
    min_notice_gap_ms: u64 = std.time.ms_per_s,
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
) ?Notice {
    const to = self.supervisor orelse return null;
    if (to == about) return null;

    const e = self.entries.getPtr(about) orelse return null;

    const kind: Notice.Kind, const report_data = switch (event) {
        .quiescent => |r| .{ Notice.Kind.quiescent, r },
        .still_quiescent => |r| .{ Notice.Kind.still_quiescent, r },
        .resumed => |r| .{ Notice.Kind.resumed, r },
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

    if (e.role != .watched) return null;

    // A terminal that has clocked off is supposed to be quiet. Saying so
    // again every quarter of an hour is exactly the kind of nagging that
    // makes someone turn the whole thing off.
    if (e.duty == .off) return null;

    // `resumed` is a one-shot: it marks a transition that will not be
    // repeated, so dropping it does not merely delay a notice -- it leaves
    // the supervisor believing a terminal is still stuck long after it went
    // back to work. Only the repeatable kinds are rate limited.
    if (kind != .resumed) {
        if (e.last_notice_ms) |last| {
            if (now_ms -| last < self.config.min_notice_gap_ms) return null;
        }
        e.last_notice_ms = now_ms;
    }

    return .{
        .to = to,
        .about = about,
        .kind = kind,
        .quiet_ms = report_data.quiet_ms,
        .silent_ms = report_data.silent_ms,
    };
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

/// Render a notice as the line the supervisor's terminal will receive.
///
/// Deliberately terse and deliberately not the screen contents: it says
/// which terminal and for how long, and leaves the supervisor to go and
/// look. Pushing the whole screen in would flood its context and would also
/// take the decision of whether to look away from it.
pub fn formatNotice(notice: Notice, buf: []u8) std.fmt.BufPrintError![]u8 {
    const what = switch (notice.kind) {
        .quiescent => "has gone quiet",
        .still_quiescent => "is still quiet",
        .resumed => "is active again",
    };

    return std.fmt.bufPrint(
        buf,
        "[poltergeist] terminal 0x{x:0>16} {s} (screen unchanged {d}s, pty silent {d}s)",
        .{
            notice.about,
            what,
            notice.quiet_ms / std.time.ms_per_s,
            notice.silent_ms / std.time.ms_per_s,
        },
    );
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
    return .init(testing.allocator, .{ .min_notice_gap_ms = 1000 });
}

test "the default notice gap cannot override the sampler's repeat interval" {
    // A large default here would silently take the repeat interval away
    // from the user, who sets it through poltergeist-quiescence-repeat.
    const d: Config = .{};
    try testing.expect(d.min_notice_gap_ms <= std.time.ms_per_s);
}

test "no supervisor means no notices" {
    var b = testBus();
    defer b.deinit();

    try b.watch(worker);
    try testing.expect(b.report(worker, quiet(60_000), 0) == null);
}

test "a watched terminal going quiet reaches the supervisor" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);

    const n = b.report(worker, quiet(180_000), 0) orelse
        return error.TestExpectedNotice;
    try testing.expectEqual(boss, n.to);
    try testing.expectEqual(worker, n.about);
    try testing.expectEqual(Notice.Kind.quiescent, n.kind);
}

test "the supervisor is not reported to itself" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try testing.expect(b.report(boss, quiet(180_000), 0) == null);
}

test "an unwatched terminal is not reported" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.register(worker); // known, but not watched
    try testing.expect(b.report(worker, quiet(180_000), 0) == null);
}

test "a resumed notice is never rate limited away" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);

    // Quiescent first, which arms the rate limiter.
    try testing.expect(b.report(worker, quiet(180_000), 0) != null);

    // Coming back to work is a one-shot transition. Dropping it would leave
    // the supervisor thinking this terminal is still stuck.
    const back = b.report(worker, .{ .resumed = .{
        .quiet_ms = 180_000,
        .silent_ms = 0,
        .changed_rows = 12,
        .total_rows = 24,
    } }, 100) orelse return error.TestExpectedNotice;
    try testing.expectEqual(Notice.Kind.resumed, back.kind);
}

test "a resumed notice does not reset the gap for repeatable kinds" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);

    try testing.expect(b.report(worker, quiet(180_000), 0) != null);
    _ = b.report(worker, .{ .resumed = .{
        .quiet_ms = 180_000,
        .silent_ms = 0,
        .changed_rows = 1,
        .total_rows = 24,
    } }, 100);

    // The gap still runs from the quiescent notice at t=0, not from the
    // resumed one at t=100.
    try testing.expect(b.report(worker, quiet(180_000), 999) == null);
    try testing.expect(b.report(worker, quiet(180_000), 1000) != null);
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
    try testing.expect(b.report(worker, quiet(180_000), 180_000) == null);
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

test "rounds count even while rate limited" {
    // The supervisor is told less often than the terminal goes quiet, but
    // the count is what the clock-out skill reasons about, so it must
    // follow the terminal rather than the notices.
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);

    try testing.expect(b.report(worker, quiet(180_000), 0) != null);
    try testing.expect(b.report(worker, quiet(181_000), 100) == null);
    try testing.expectEqual(@as(u16, 2), b.get(worker).?.rounds);
}

test "notices about one terminal are rate limited" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);

    try testing.expect(b.report(worker, quiet(180_000), 0) != null);
    try testing.expect(b.report(worker, quiet(180_000), 500) == null);
    try testing.expect(b.report(worker, quiet(180_000), 999) == null);
    try testing.expect(b.report(worker, quiet(180_000), 1000) != null);
}

test "rate limiting is per terminal" {
    var b = testBus();
    defer b.deinit();

    const other: Id = 0x3333;
    try b.setSupervisor(boss);
    try b.watch(worker);
    try b.watch(other);

    try testing.expect(b.report(worker, quiet(180_000), 0) != null);
    try testing.expect(b.report(other, quiet(180_000), 0) != null);
}

test "a clocked off terminal stops being reported" {
    var b = testBus();
    defer b.deinit();

    try b.setSupervisor(boss);
    try b.watch(worker);

    try b.clockOff(worker, .supervisor);
    try testing.expect(b.report(worker, quiet(180_000), 10_000) == null);

    // Back on duty, reported again.
    try b.clockOn(worker);
    try testing.expect(b.report(worker, quiet(180_000), 20_000) != null);
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
    try testing.expect(b.report(worker, quiet(180_000), 0) == null);
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

test "a notice reads as a pointer, not as the screen" {
    var buf: [256]u8 = undefined;
    const line = try formatNotice(.{
        .to = boss,
        .about = worker,
        .kind = .quiescent,
        .quiet_ms = 185_000,
        .silent_ms = 12_000,
    }, &buf);

    try testing.expectEqualStrings(
        "[poltergeist] terminal 0x0000000000002222 has gone quiet " ++
            "(screen unchanged 185s, pty silent 12s)",
        line,
    );
}

test "resumed and still quiescent read differently" {
    var buf: [256]u8 = undefined;

    const still = try formatNotice(.{
        .to = boss,
        .about = worker,
        .kind = .still_quiescent,
        .quiet_ms = 900_000,
        .silent_ms = 900_000,
    }, &buf);
    try testing.expect(std.mem.indexOf(u8, still, "is still quiet") != null);

    const back = try formatNotice(.{
        .to = boss,
        .about = worker,
        .kind = .resumed,
        .quiet_ms = 900_000,
        .silent_ms = 0,
    }, &buf);
    try testing.expect(std.mem.indexOf(u8, back, "is active again") != null);
}
