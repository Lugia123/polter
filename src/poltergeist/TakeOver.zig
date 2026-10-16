//! "Let the control room take over?" (task 1635): quit an agent CLI a
//! person started by hand, and start it again through Polter -- with
//! hooks, in the supervisor's role, in the same terminal, the same
//! directory and the same group, going on with its session.
//!
//! The steps are the app's (`App.takeOverStep`); what is decided, and can
//! be decided without a terminal, is here:
//!
//!   * **when typing the quit is safe** (`ready`): the adapter's screen rule
//!     (`agent_cli.Identified.Quit`), asked of the screen twice, three
//!     seconds apart, and the two screens the same. No hooks means no
//!     state; the screen is all there is, and a rule that cannot tell is a
//!     refusal, never a guess -- the guess that goes wrong presses return in
//!     a permission box;
//!   * **whether the session it names is still the one it is in** (`sure`);
//!   * **where it is** (`Phase`), and **why it stopped** (`Why`), which the
//!     snapshot carries.

const std = @import("std");
const agent_cli = @import("agent_cli.zig");

/// How long the screen has to stay the same before the quit is typed.
pub const settle_ms: u64 = 3 * std.time.ms_per_s;
/// How many more times a screen that moved is looked at, `settle_ms` after
/// it moved, before it counts as busy. Once is not enough: the terminal is
/// laid out again when the confirm box closes or the frame changes hands,
/// and its lines wrap differently without anything going on in it. A
/// spinner moves every time it is looked at, and is busy all the same.
pub const settle_tries: u8 = 3;
/// How long the CLI has to quit -- its sidecar gone and its shell back at
/// the prompt -- before the take-over gives up.
pub const quit_ms: u64 = 15 * std.time.ms_per_s;
/// How long the new one has to say, through `+launch`, that it is coming.
pub const start_ms: u64 = 60 * std.time.ms_per_s;
/// How much older than the agent's last tool call the session's record may
/// be and still be the session it is in.
pub const sure_slack_ms: i64 = 5 * std.time.ms_per_min;
/// How many of the screen's last rows the ready line is looked for in.
pub const ready_rows: usize = 15;

pub const Phase = enum {
    /// Looked at the screen once; looks again at `settle_ms`.
    settling,
    /// Typed the quit; waits for it to have quit.
    quitting,
    /// Typed the launch line; waits for `+launch` to say it is coming.
    starting,
};

/// Why a take-over stopped without taking over. Each is a sentence the
/// person is told (`ControlRoom.Say`).
pub const Why = enum {
    /// The screen moved, or did not read as waiting at its prompt.
    busy,
    /// Somebody typed in it, or there is half a line in it.
    typing,
    /// It was told to quit and did not, within `quit_ms`.
    did_not_quit,
    /// It quit, and the one started in its place did not come.
    did_not_start,
    /// The role or the CLI to start it again is not there any more.
    cannot_start,
};

/// Whether `screen` -- the active area, top to bottom -- is one the quit
/// may be typed into: one of its last `ready_rows` rows, trimmed of spaces,
/// is one of `quit.ready_lines`, and none of its rows contains any of
/// `quit.ready_none`.
pub fn ready(screen: []const u8, quit: agent_cli.Identified.Quit) bool {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    var buf: [256][]const u8 = undefined;
    rows = .initBuffer(&buf);
    var it = std.mem.splitScalar(u8, screen, '\n');
    while (it.next()) |row| {
        for (quit.ready_none) |bad| if (std.mem.indexOf(u8, row, bad) != null) return false;
        if (rows.items.len == buf.len) _ = rows.orderedRemove(0);
        rows.appendAssumeCapacity(row);
    }
    // Trailing blank rows are not rows to count back from.
    var end = rows.items.len;
    while (end > 0 and std.mem.trim(u8, rows.items[end - 1], " \t\r").len == 0) end -= 1;
    const start = end -| ready_rows;
    for (rows.items[start..end]) |row| {
        const t = std.mem.trim(u8, row, " \t\r");
        for (quit.ready_lines) |line| if (std.mem.eql(u8, t, line)) return true;
    }
    return false;
}

pub const Settle = enum {
    /// Still, and at its prompt: type the quit.
    quit,
    /// It moved since it was last looked at: look again `settle_ms` on.
    again,
    /// Still and not at its prompt, or never still.
    busy,
};

/// What to do with the screen `now`, `settle_ms` after it was `before`,
/// with `tries` looks left after this one.
pub fn settle(before: []const u8, now: []const u8, quit: agent_cli.Identified.Quit, tries: u8) Settle {
    if (!std.mem.eql(u8, before, now)) return if (tries > 0) .again else .busy;
    return if (ready(now, quit)) .quit else .busy;
}

/// Whether the session an adapter named is the one the agent is in: its
/// record was written no longer than `sure_slack_ms` before the agent's
/// last tool call. **A record that stopped being written while the agent
/// went on working is the sign of a `/clear`** -- the sidecar's environment
/// still names the session it started in, and the CLI has moved to a new
/// one. Both on the real clock; with no call ever made, or no time known
/// for the record, it is taken as sure only when there was no call.
pub fn sure(written_ms: ?i64, last_call_ms: ?i64) bool {
    const call = last_call_ms orelse return true;
    const written = written_ms orelse return false;
    return written + sure_slack_ms >= call;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

const claude_quit: agent_cli.Identified.Quit = .{
    .text = "/exit",
    .ready_lines = &.{ "\u{276f}", ">" },
    .ready_none = &.{ "esc to interrupt", "Do you want", "\u{276f} 1." },
};

test "TakeOver ready: an empty input line and nothing going on" {
    // Claude Code 2.1.301 at rest, as read off a real terminal.
    const idle =
        \\  ⎿  Referenced file .claude/skills/x/SKILL.md
        \\
        \\⏺ Compacted while idle
        \\
        \\─────────────────────────────────────────────
        \\❯
        \\─────────────────────────────────────────────
        \\  5 h 17% · 7 d 45%
        \\
        \\
    ;
    try testing.expect(ready(idle, claude_quit));

    // A turn going on: the same input line, and the spinner says so.
    const busy =
        \\✻ Working… (12s · esc to interrupt)
        \\─────────────────────────────────────────────
        \\❯
        \\─────────────────────────────────────────────
    ;
    try testing.expect(!ready(busy, claude_quit));

    // A permission question: a numbered menu, no empty input line.
    const asking =
        \\ Do you want to proceed?
        \\ ❯ 1. Yes
        \\   2. No, and tell Claude what to do differently
    ;
    try testing.expect(!ready(asking, claude_quit));

    // Something half typed: the line is not empty, so it is not ready.
    const draft =
        \\─────────────────────────────────────────────
        \\❯ please also check
        \\─────────────────────────────────────────────
    ;
    try testing.expect(!ready(draft, claude_quit));

    // A bare shell, or nothing at all.
    try testing.expect(!ready("user@host ~ % ", claude_quit));
    try testing.expect(!ready("", claude_quit));
}

test "TakeOver ready: the input line counts only near the bottom" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "❯\n");
    for (0..ready_rows) |_| try buf.appendSlice(testing.allocator, "output\n");
    try testing.expect(!ready(buf.items, claude_quit));
    try buf.appendSlice(testing.allocator, "❯\n");
    try testing.expect(ready(buf.items, claude_quit));
}

test "TakeOver settle: a screen that moved is looked at again, a spinner is busy" {
    const idle = "\u{276f}\n";
    const wrapped = "\u{276f} \n";
    // Still and at its prompt.
    try testing.expectEqual(Settle.quit, settle(idle, idle, claude_quit, 0));
    // Laid out again once: looked at again, and then it is still.
    try testing.expectEqual(Settle.again, settle(wrapped, idle, claude_quit, settle_tries));
    try testing.expectEqual(Settle.quit, settle(idle, idle, claude_quit, settle_tries - 1));
    // Moving every time: busy once the looks run out.
    try testing.expectEqual(Settle.busy, settle("\u{273b} 1s\n", "\u{273b} 2s\n", claude_quit, 0));
    // Still, and not at its prompt: busy at once.
    try testing.expectEqual(Settle.busy, settle("Do you want\n", "Do you want\n", claude_quit, settle_tries));
}

test "TakeOver sure: a record that stopped while the agent went on is a /clear" {
    const min: i64 = std.time.ms_per_min;
    // Written at the last call, or a little before: sure.
    try testing.expect(sure(100 * min, 100 * min));
    try testing.expect(sure(96 * min, 100 * min));
    // Written long before the last call: not.
    try testing.expect(!sure(90 * min, 100 * min));
    // No call ever made: nothing says it moved on.
    try testing.expect(sure(10 * min, null));
    // A call made and no time for the record: not sure.
    try testing.expect(!sure(null, 100 * min));
}
