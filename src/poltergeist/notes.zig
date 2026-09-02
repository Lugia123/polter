//! The one line a group's supervisor is handed about its group.
//!
//! Not a channel of its own: what this produces goes into the same box as
//! the quiet-screen reports and rides out on the same clock (`Bus.leaveNote`,
//! `poltergeist-notice-interval`). A second schedule would be a way round
//! the one number the user set to say how often a supervisor may be
//! interrupted at all -- see `docs/poltergeist/stats.md`, which argues the
//! same point against an hourly summary.
//!
//! **Everything here is arithmetic, and none of it is a verdict.** How long
//! since a task's last event, how long since anybody spoke, how many times
//! a task has been handed out. A task untouched for two days may be stalled
//! or may be a standing lease that is *meant* to stay open -- the terminal
//! holding a machine nobody else may touch is a task by design, and no rule
//! written over this record can tell those apart. So the line says how
//! long and stops there, exactly as `Sampler` reports how long a screen has
//! been still and never says "stuck".
//!
//! Its own file so the wording and the thresholds can be tested. `App.zig`
//! fetches the records and delivers the result; a rule that lived only
//! there would be a rule with no test, in the one file that has none.

const std = @import("std");

const TaskLog = @import("TaskLog.zig");

/// One task off the panel, reduced to what a note needs.
pub const Task = struct {
    id: u64,
    open: bool,
};

pub const Input = struct {
    group: []const u8,

    /// Wall clock, because everything it is compared against was stamped
    /// off the wall clock: an event's `at_ms`, a group's last message.
    now_ms: i64,

    /// When anybody last spoke in this group, or zero for a group nothing
    /// has ever been said in -- which says nothing rather than reporting a
    /// silence of fifty-six years.
    last_said_ms: i64 = 0,

    /// `poltergeist-task-idle-after` and `poltergeist-group-quiet-after`.
    /// Zero switches that half off.
    task_idle_ms: u64 = 0,
    group_quiet_ms: u64 = 0,

    tasks: []const Task,
    events: []const TaskLog.Event,
};

/// The most tasks one line names individually.
///
/// Beyond this the line stops rather than growing: it is typed into
/// somebody's input box, and a line long enough to scroll is a line nobody
/// reads. The statistics tab has all of them, which is where somebody who
/// wants the whole picture is looking anyway.
pub const max_listed = 3;

/// How many times a task has to have been handed out before that is worth
/// saying.
///
/// Three, not two. A task given back once and handed to somebody else is an
/// ordinary night; a third time is a pattern, and the pattern is about the
/// supervisor's own arrangement rather than about the task.
pub const churn_at = 3;

/// Write the line for one group into `buf`, or return empty when there is
/// nothing to say.
///
/// Empty is the common case and is the point: a note that arrived every
/// interval saying all was well would be read for a night and skipped
/// after that.
pub fn line(buf: []u8, in: Input) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var said: usize = 0;

    // Written as it goes, and each clause is rolled back if it did not
    // fit whole. **A failed `print` does not leave the writer where it
    // found it** -- it fills the buffer and then reports the failure, so
    // without the rollback a note that ran out of room ends mid-number,
    // which is exactly the "#93 untouched 3d1" that this is here to stop.
    w.print("{s}:", .{in.group}) catch return "";

    if (in.task_idle_ms > 0) said += tasks(&w, in);

    if (in.group_quiet_ms > 0 and in.last_said_ms > 0) {
        const silent: u64 = @intCast(@max(in.now_ms - in.last_said_ms, 0));
        if (silent >= in.group_quiet_ms) {
            var stamp: [16]u8 = undefined;
            const mark = w.end;
            if (w.print("{s} nothing said for {s}", .{
                if (said == 0) "" else ",",
                brief(&stamp, silent),
            })) |_| {
                said += 1;
            } else |_| {
                w.end = mark;
            }
        }
    }

    if (said == 0) return "";
    return w.buffered();
}

/// The open tasks worth naming, and why each one is worth naming.
fn tasks(w: *std.Io.Writer, in: Input) usize {
    var said: usize = 0;

    for (in.tasks) |t| {
        if (!t.open) continue;
        if (said >= max_listed) break;

        var last: ?i64 = null;
        var handed: usize = 0;
        for (in.events) |e| {
            if (e.task != t.id) continue;
            if (last == null or e.at_ms > last.?) last = e.at_ms;
            if (std.mem.eql(u8, e.op, "assigned")) handed += 1;
        }

        // Nothing in the record at all is not the same as something a long
        // time ago: the log may be off, or the task may be older than what
        // was read back. Saying nothing is the honest answer, and it is
        // what the statistics tab does with the same case.
        const touched = last orelse continue;
        const silent: u64 = @intCast(@max(in.now_ms - touched, 0));

        const idle = silent >= in.task_idle_ms;
        const churned = handed >= churn_at;
        if (!idle and !churned) continue;

        var stamp: [16]u8 = undefined;
        const sep = if (said == 0) "" else ",";
        const mark = w.end;
        const wrote = if (idle and churned)
            w.print("{s} #{d} untouched {s}, handed out {d} times", .{
                sep,
                t.id,
                brief(&stamp, silent),
                handed,
            })
        else if (churned)
            w.print("{s} #{d} handed out {d} times", .{ sep, t.id, handed })
        else
            w.print("{s} #{d} untouched {s}", .{ sep, t.id, brief(&stamp, silent) });

        // Out of room: wound back to where this clause started, so what
        // stands is whole. See the note in `line`.
        wrote catch {
            w.end = mark;
            break;
        };
        said += 1;
    }

    return said;
}

/// A duration in the shortest form that still says which unit it is.
///
/// Coarse on purpose, and for a line typed into an input box: `49h`,
/// `3h40m`, `12m`, `4d4h`. The difference between 49 and 50 hours changes
/// nothing anybody would do, and reporting it to the minute would invite
/// the line to be read as a measurement.
///
/// Hours all the way to three days, rather than rolling over at one: what
/// this is measuring is a night, and "49h" is read at a glance as two
/// nights while "2d1h" has to be worked out. Past three days the days are
/// the point and the hours are noise.
pub fn brief(buf: []u8, ms: u64) []const u8 {
    const mins = ms / std.time.ms_per_min;
    if (mins < 60) return std.fmt.bufPrint(buf, "{d}m", .{mins}) catch "?";

    const hours = mins / 60;
    const rest = mins % 60;
    if (hours < 72) {
        // Minutes only while they still change the picture. At two days
        // the odd forty minutes is noise on a number nobody acts on to
        // that precision.
        if (rest == 0 or hours >= 24) {
            return std.fmt.bufPrint(buf, "{d}h", .{hours}) catch "?";
        }
        return std.fmt.bufPrint(buf, "{d}h{d}m", .{ hours, rest }) catch "?";
    }

    return std.fmt.bufPrint(buf, "{d}d{d}h", .{ hours / 24, hours % 24 }) catch "?";
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const hour: i64 = 60 * 60 * 1000;
const hour_ms: u64 = 60 * 60 * 1000;

fn event(at_h: i64, op: []const u8, task: u64) TaskLog.Event {
    return .{
        .seq = 0,
        .at_ms = at_h * hour,
        .op = op,
        .task = task,
        .title = "a task",
        .owner = 0x2222,
        .state = "open",
        .progress = "queued",
    };
}

test "a quiet night says nothing at all" {
    // The failure mode this is written against is a note that always
    // arrives: after eight of "all is well" nobody reads the ninth.
    var buf: [160]u8 = undefined;
    const out = line(&buf, .{
        .group = "build",
        .now_ms = 100 * hour,
        .last_said_ms = 100 * hour,
        .task_idle_ms = 12 * hour_ms,
        .group_quiet_ms = hour_ms,
        .tasks = &.{.{ .id = 1, .open = true }},
        .events = &.{event(99, "progressed", 1)},
    });
    try testing.expectEqualStrings("", out);
}

test "a task nothing has happened to is named with how long" {
    var buf: [160]u8 = undefined;
    const out = line(&buf, .{
        .group = "build",
        .now_ms = 100 * hour,
        .last_said_ms = 100 * hour,
        .task_idle_ms = 12 * hour_ms,
        .group_quiet_ms = hour_ms,
        .tasks = &.{ .{ .id = 93, .open = true }, .{ .id = 94, .open = true } },
        .events = &.{ event(51, "assigned", 93), event(99, "progressed", 94) },
    });

    try testing.expectEqualStrings("build: #93 untouched 49h", out);
}

test "a closed task is not waiting for anybody" {
    var buf: [160]u8 = undefined;
    const out = line(&buf, .{
        .group = "build",
        .now_ms = 100 * hour,
        .task_idle_ms = 12 * hour_ms,
        .tasks = &.{.{ .id = 93, .open = false }},
        .events = &.{event(10, "closed", 93)},
    });
    try testing.expectEqualStrings("", out);
}

test "a task with nothing in the record is left alone rather than guessed at" {
    // The log may be off, or the task may be older than what was read
    // back. Reporting it as untouched since the epoch is the one answer
    // that would send somebody to look at a task that is fine.
    var buf: [160]u8 = undefined;
    const out = line(&buf, .{
        .group = "build",
        .now_ms = 100 * hour,
        .task_idle_ms = hour_ms,
        .tasks = &.{.{ .id = 93, .open = true }},
        .events = &.{},
    });
    try testing.expectEqualStrings("", out);
}

test "a task handed round three times is worth saying even while it moves" {
    // Twice is an ordinary night. The third time is about the
    // arrangement, not about the task, which is why it is said even though
    // something happened to it a minute ago.
    var buf: [160]u8 = undefined;
    const out = line(&buf, .{
        .group = "build",
        .now_ms = 100 * hour,
        .task_idle_ms = 12 * hour_ms,
        .tasks = &.{.{ .id = 12, .open = true }},
        .events = &.{
            event(10, "assigned", 12),
            event(50, "assigned", 12),
            event(100, "assigned", 12),
        },
    });
    try testing.expectEqualStrings("build: #12 handed out 3 times", out);
}

test "a task that is both says both, in one clause" {
    var buf: [160]u8 = undefined;
    const out = line(&buf, .{
        .group = "build",
        .now_ms = 100 * hour,
        .task_idle_ms = 12 * hour_ms,
        .tasks = &.{.{ .id = 12, .open = true }},
        .events = &.{
            event(10, "assigned", 12),
            event(20, "assigned", 12),
            event(30, "assigned", 12),
        },
    });
    try testing.expectEqualStrings("build: #12 untouched 70h, handed out 3 times", out);
}

test "silence is reported as a duration and nothing more" {
    var buf: [160]u8 = undefined;
    const out = line(&buf, .{
        .group = "build",
        .now_ms = 100 * hour,
        .last_said_ms = 96 * hour + 20 * 60 * 1000,
        .group_quiet_ms = hour_ms,
        .tasks = &.{},
        .events = &.{},
    });
    try testing.expectEqualStrings("build: nothing said for 3h40m", out);
}

test "a group nobody has ever spoken in reports no silence" {
    var buf: [160]u8 = undefined;
    const out = line(&buf, .{
        .group = "build",
        .now_ms = 100 * hour,
        .last_said_ms = 0,
        .group_quiet_ms = hour_ms,
        .tasks = &.{},
        .events = &.{},
    });
    try testing.expectEqualStrings("", out);
}

test "zero switches a half off" {
    var buf: [160]u8 = undefined;

    const no_tasks = line(&buf, .{
        .group = "build",
        .now_ms = 100 * hour,
        .last_said_ms = 50 * hour,
        .task_idle_ms = 0,
        .group_quiet_ms = hour_ms,
        .tasks = &.{.{ .id = 93, .open = true }},
        .events = &.{event(10, "assigned", 93)},
    });
    try testing.expectEqualStrings("build: nothing said for 50h", no_tasks);

    var buf2: [160]u8 = undefined;
    const no_silence = line(&buf2, .{
        .group = "build",
        .now_ms = 100 * hour,
        .last_said_ms = 50 * hour,
        .task_idle_ms = 12 * hour_ms,
        .group_quiet_ms = 0,
        .tasks = &.{.{ .id = 93, .open = true }},
        .events = &.{event(10, "assigned", 93)},
    });
    try testing.expectEqualStrings("build: #93 untouched 3d18h", no_silence);
}

test "both halves share one line" {
    var buf: [160]u8 = undefined;
    const out = line(&buf, .{
        .group = "build",
        .now_ms = 100 * hour,
        .last_said_ms = 96 * hour,
        .task_idle_ms = 12 * hour_ms,
        .group_quiet_ms = hour_ms,
        .tasks = &.{ .{ .id = 93, .open = true }, .{ .id = 71, .open = true } },
        .events = &.{ event(51, "assigned", 93), event(60, "assigned", 71) },
    });
    try testing.expectEqualStrings(
        "build: #93 untouched 49h, #71 untouched 40h, nothing said for 4h",
        out,
    );
}

test "a line that will not fit stops rather than being cut in half" {
    // The buffer is fixed and shared with the terminal reports, so what
    // has to be true is that the last thing written is whole.
    var buf: [56]u8 = undefined;
    const out = line(&buf, .{
        .group = "a-group-with-a-fairly-long-name",
        .now_ms = 100 * hour,
        .task_idle_ms = hour_ms,
        .tasks = &.{ .{ .id = 93, .open = true }, .{ .id = 71, .open = true } },
        .events = &.{ event(10, "assigned", 93), event(20, "assigned", 71) },
    });

    try testing.expect(out.len <= buf.len);
    try testing.expect(std.mem.endsWith(u8, out, "h"));
    try testing.expectEqualStrings("a-group-with-a-fairly-long-name: #93 untouched 3d18h", out);
}

test "no more than three tasks are named however many there are" {
    var buf: [160]u8 = undefined;
    const out = line(&buf, .{
        .group = "g",
        .now_ms = 100 * hour,
        .task_idle_ms = hour_ms,
        .tasks = &.{
            .{ .id = 1, .open = true },
            .{ .id = 2, .open = true },
            .{ .id = 3, .open = true },
            .{ .id = 4, .open = true },
        },
        .events = &.{
            event(10, "assigned", 1),
            event(10, "assigned", 2),
            event(10, "assigned", 3),
            event(10, "assigned", 4),
        },
    });

    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "untouched"));
}

test "a duration says which unit it is" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("12m", brief(&buf, 12 * 60 * 1000));
    try testing.expectEqualStrings("3h", brief(&buf, 3 * hour_ms));
    try testing.expectEqualStrings("3h40m", brief(&buf, 3 * hour_ms + 40 * 60 * 1000));
    try testing.expectEqualStrings("49h", brief(&buf, 49 * hour_ms));
    try testing.expectEqualStrings("4d4h", brief(&buf, 100 * hour_ms));
}
