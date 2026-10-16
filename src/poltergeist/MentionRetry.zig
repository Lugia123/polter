//! A mention that was refused for a reason that clears by itself, tried
//! again a few times (#60).
//!
//! A mention is typed through the same door `terminal_send` uses, so it is
//! refused the same way: `UserPresent` when a key reached that terminal in
//! the last ten seconds, `DraftInLine` when there is half a line in front
//! of the cursor. Both are right to refuse -- typing into somebody's
//! sentence submits it -- but both are also over soon, and the caller used
//! to be left to notice the row and post again. Measured on the night #60
//! was filed: 2 refusals in 17 deliveries, each one gone on a second try.
//!
//! **Bounded, and the end is said out loud.** `attempts` tries, `delayMs`
//! apart; when the last one is refused too, the caller decides what to say
//! to the author (`App` types one line into the author's terminal). A
//! retry that kept going would only move the silence later.
//!
//! **Its own file so the bookkeeping is tested without an app.** The clock
//! and the outcome of every delivery arrive as parameters; `App` does the
//! typing and the waking.

const MentionRetry = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");
const Id = Bus.Id;

/// How many more times a refused mention is typed, after the refusal that
/// put it here.
pub const attempts: u8 = 3;

/// `UserPresent`: the ten seconds of keyboard quiet it asks for
/// (`Surface.notice_quiet_keyboard_ms`), and a margin so the retry does not
/// land on the boundary and be refused for the same key again.
pub const user_present_delay_ms: u64 = 10_250;

/// `DraftInLine`: nothing on a clock clears a draft -- somebody has to send
/// or clear the line -- so this is a guess at how long that takes, longer
/// than the keyboard's so three tries cover most of a minute.
pub const draft_delay_ms: u64 = 15_000;

/// How long until a mention refused with `err` is tried again, or null when
/// trying again would not help (the terminal is gone, the text can never be
/// typed there, nobody is listening).
pub fn delayMs(err: anyerror) ?u64 {
    return switch (err) {
        error.UserPresent, error.Composing => user_present_delay_ms,
        error.DraftInLine => draft_delay_ms,
        else => null,
    };
}

/// The code a refusal is reported under -- the one `group_post` puts in its
/// row, so the author reads the same word twice.
pub fn codeOf(err: anyerror) []const u8 {
    return switch (err) {
        error.Composing => "UserPresent",
        else => @errorName(err),
    };
}

pub const Entry = struct {
    /// Owned.
    group: []u8,
    seq: u64,
    from: Id,
    to: Id,
    /// The line exactly as it was first typed (`Chat.formatDelivery`). Owned.
    line: []u8,
    /// Tries still to come, counting the one at `due_ms`.
    left: u8,
    due_ms: u64,
};

/// What became of a retry that was refused again.
pub const Outcome = union(enum) {
    /// Queued once more, this far from now.
    again: u64,
    /// That was the last try, or the refusal is not one that clears. The
    /// entry is not queued again and is the caller's to `free`, after it
    /// has said so; the code is the last refusal's.
    gave_up: []const u8,
};

alloc: Allocator,
items: std.ArrayListUnmanaged(Entry) = .empty,

pub fn deinit(self: *MentionRetry) void {
    for (self.items.items) |e| self.free(e);
    self.items.deinit(self.alloc);
}

pub fn free(self: *MentionRetry, e: Entry) void {
    self.alloc.free(e.group);
    self.alloc.free(e.line);
}

/// Queue a mention that was just refused with `err`. Answers how long until
/// it is tried again, or null when `err` is not worth trying again and
/// nothing was queued.
pub fn add(
    self: *MentionRetry,
    group: []const u8,
    seq: u64,
    from: Id,
    to: Id,
    line: []const u8,
    err: anyerror,
    now_ms: u64,
) Allocator.Error!?u64 {
    const delay = delayMs(err) orelse return null;
    const g = try self.alloc.dupe(u8, group);
    errdefer self.alloc.free(g);
    const l = try self.alloc.dupe(u8, line);
    errdefer self.alloc.free(l);
    try self.items.append(self.alloc, .{
        .group = g,
        .seq = seq,
        .from = from,
        .to = to,
        .line = l,
        .left = attempts,
        .due_ms = now_ms +| delay,
    });
    return delay;
}

/// The earliest moment anything here is due, or null when nothing is.
pub fn nextDueMs(self: *const MentionRetry) ?u64 {
    var at: ?u64 = null;
    for (self.items.items) |e| at = if (at) |a| @min(a, e.due_ms) else e.due_ms;
    return at;
}

/// Move every entry that is due at `now_ms` into `out`, oldest first. The
/// caller owns them now: each goes back through `requeue`, or to `free`
/// once it has been typed.
pub fn takeDue(self: *MentionRetry, now_ms: u64, out: *std.ArrayListUnmanaged(Entry)) Allocator.Error!void {
    try out.ensureUnusedCapacity(self.alloc, self.items.items.len);
    var i: usize = 0;
    while (i < self.items.items.len) {
        if (self.items.items[i].due_ms <= now_ms) {
            out.appendAssumeCapacity(self.items.orderedRemove(i));
        } else i += 1;
    }
}

/// A due entry was refused again with `err`. Queued for another try if it
/// has any left and the refusal is one that clears; otherwise handed back
/// as `gave_up`, still the caller's.
pub fn requeue(self: *MentionRetry, e: Entry, err: anyerror, now_ms: u64) Outcome {
    const code = codeOf(err);
    const delay = delayMs(err) orelse return .{ .gave_up = code };
    if (e.left <= 1) return .{ .gave_up = code };
    var next = e;
    next.left -= 1;
    next.due_ms = now_ms +| delay;
    self.items.append(self.alloc, next) catch return .{ .gave_up = code };
    return .{ .again = delay };
}

/// The group was renamed: what is waiting under `old` waits under `new`.
pub fn renameGroup(self: *MentionRetry, old: []const u8, new: []const u8) Allocator.Error!void {
    for (self.items.items) |*e| {
        if (!std.mem.eql(u8, e.group, old)) continue;
        const n = try self.alloc.dupe(u8, new);
        self.alloc.free(e.group);
        e.group = n;
    }
}

/// The one line the author is told when the last try was refused too.
pub fn writeGaveUp(
    w: *std.Io.Writer,
    group: []const u8,
    seq: u64,
    to: Id,
    code: []const u8,
) std.Io.Writer.Error!void {
    try w.print(
        "[polter] Your mention of 0x{x:0>16} in \"{s}\" (message {d}) was not " ++
            "delivered after {d} more tries: {s}. The message is in the group, " ++
            "unread by them -- type to that terminal yourself if it cannot wait.",
        .{ to, group, seq, attempts, code },
    );
}

const testing = std.testing;

test "mention retry: only the refusals that clear by themselves are tried again" {
    try testing.expectEqual(@as(?u64, user_present_delay_ms), delayMs(error.UserPresent));
    try testing.expectEqual(@as(?u64, user_present_delay_ms), delayMs(error.Composing));
    try testing.expectEqual(@as(?u64, draft_delay_ms), delayMs(error.DraftInLine));
    try testing.expectEqual(@as(?u64, null), delayMs(error.NoSuchTerminal));
    try testing.expectEqual(@as(?u64, null), delayMs(error.ChildExited));
    try testing.expectEqual(@as(?u64, null), delayMs(error.UnsafeText));
    // An input method composing is reported as `UserPresent`, the word the
    // row already used.
    try testing.expectEqualStrings("UserPresent", codeOf(error.Composing));
    try testing.expectEqualStrings("DraftInLine", codeOf(error.DraftInLine));
}

test "mention retry: a refusal that does not clear queues nothing" {
    var r: MentionRetry = .{ .alloc = testing.allocator };
    defer r.deinit();
    try testing.expectEqual(@as(?u64, null), try r.add("g", 1, 1, 2, "line", error.ChildExited, 0));
    try testing.expectEqual(@as(usize, 0), r.items.items.len);
    try testing.expectEqual(@as(?u64, null), r.nextDueMs());
}

test "mention retry: three more tries, then it gives up with the last refusal's code" {
    var r: MentionRetry = .{ .alloc = testing.allocator };
    defer r.deinit();
    var due: std.ArrayListUnmanaged(Entry) = .empty;
    defer due.deinit(testing.allocator);

    var now: u64 = 1_000;
    try testing.expectEqual(@as(?u64, user_present_delay_ms), try r.add("build", 7, 0xa, 0xb, "the line", error.UserPresent, now));
    try testing.expectEqual(@as(?u64, now + user_present_delay_ms), r.nextDueMs());

    // Not due yet: nothing is handed out.
    try r.takeDue(now + user_present_delay_ms - 1, &due);
    try testing.expectEqual(@as(usize, 0), due.items.len);

    var tries: usize = 0;
    var last: Outcome = undefined;
    while (r.nextDueMs()) |at| {
        now = at;
        due.clearRetainingCapacity();
        try r.takeDue(now, &due);
        try testing.expectEqual(@as(usize, 1), due.items.len);
        try testing.expectEqualStrings("the line", due.items[0].line);
        tries += 1;
        // The first two refused for the keyboard, the last for a draft:
        // the code given up with is the last one's.
        last = r.requeue(due.items[0], if (tries < attempts) error.UserPresent else error.DraftInLine, now);
        if (last == .gave_up) r.free(due.items[0]);
    }
    try testing.expectEqual(@as(usize, attempts), tries);
    try testing.expectEqualStrings("DraftInLine", last.gave_up);
    try testing.expectEqual(@as(usize, 0), r.items.items.len);
}

test "mention retry: a retry refused for a reason that does not clear stops at once" {
    var r: MentionRetry = .{ .alloc = testing.allocator };
    defer r.deinit();
    var due: std.ArrayListUnmanaged(Entry) = .empty;
    defer due.deinit(testing.allocator);
    _ = try r.add("g", 1, 1, 2, "x", error.DraftInLine, 0);
    try r.takeDue(draft_delay_ms, &due);
    const out = r.requeue(due.items[0], error.NoSuchTerminal, draft_delay_ms);
    r.free(due.items[0]);
    try testing.expectEqualStrings("NoSuchTerminal", out.gave_up);
    try testing.expectEqual(@as(?u64, null), r.nextDueMs());
}

test "mention retry: a renamed group's waiting mentions follow it" {
    var r: MentionRetry = .{ .alloc = testing.allocator };
    defer r.deinit();
    _ = try r.add("old", 1, 1, 2, "x", error.UserPresent, 0);
    _ = try r.add("other", 2, 1, 3, "y", error.UserPresent, 0);
    try r.renameGroup("old", "new");
    try testing.expectEqualStrings("new", r.items.items[0].group);
    try testing.expectEqualStrings("other", r.items.items[1].group);
}

test "mention retry: the line the author is told names who, where, and why" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeGaveUp(&w, "build", 12, 0xab, "UserPresent");
    const s = w.buffered();
    try testing.expect(std.mem.indexOf(u8, s, "0x00000000000000ab") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"build\" (message 12)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "UserPresent") != null);
}
