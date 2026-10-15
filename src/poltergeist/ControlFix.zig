//! The control room's "Fix" button on a card that reads "Failed" (task
//! 1560): the core types a paragraph into the card's supervisor saying who
//! failed, with what and when, and leaves what to do about it to that
//! supervisor -- go on, retry, say "done", or close it.
//!
//! **Nothing here clears a failure.** A failure is cleared by the failed
//! terminal's next event and by nothing else; this only tells somebody who
//! can bring that event about. There is no "force clear", on purpose.
//!
//! Four pieces, each a pure function with its own tests:
//!
//!   * `offered` -- which cards have the button: those whose word is
//!     `failed`, and no other.
//!   * `plan` -- the paragraph and who it is typed into: the supervisor,
//!     about its workers and itself; or, with no supervisor, each failed
//!     terminal about itself.
//!   * `deliver` -- the road a `group_post` mention takes: kept in the
//!     group, then typed with a return, refused by the same names
//!     (`NoAgent`, `UserPresent`, `DraftInLine`, ...).
//!   * `Sent` / `stateOf` -- "notified" stands until the card changes: the
//!     set of failed terminals or when they failed.

const ControlFix = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Attention = @import("Attention.zig");
const Bus = @import("Bus.zig");

pub const Id = Bus.Id;

/// What a card's button is.
pub const State = enum {
    /// No button: the card does not read "Failed".
    none,
    /// "Fix", to be pressed.
    offered,
    /// "Supervisor notified", greyed, until the card changes.
    sent,
};

/// Whether a card with this word has the button. The word and not the
/// kind: a terminal off duty, or one whose screen cannot be read, is not
/// drawn "Failed" whatever its kind, and the button goes with what is
/// drawn.
pub fn offered(word: Attention.Word) bool {
    return switch (word) {
        .failed => true,
        .needs_approval,
        .needs_answer,
        .suspect_stuck,
        .done_unseen,
        .working,
        .quiet_unknown,
        .screen_unreadable,
        .unattended,
        .snoozed,
        .off_duty,
        .none,
        => false,
    };
}

/// One failed terminal under a card.
pub const Failing = struct {
    id: Id,
    /// Its title; empty when it has none.
    title: []const u8,
    /// What failed, as the CLI said it (`server_error`, `rate_limit`), or
    /// `process_exited`. Empty when nothing said.
    what: []const u8,
    /// When it failed: the bus's clock, for the stamp, and the wall's,
    /// for the sentence.
    since_ms: u64,
    at_wall_ms: u64,
};

/// Which card: a group's, or a terminal's that is in no group.
pub const Key = union(enum) {
    group: []const u8,
    terminal: Id,
};

/// A card, as much of it as the button needs.
pub const Card = struct {
    key: Key,
    /// The group's supervisor; null for a group without one and for a
    /// terminal on its own.
    steward: ?Id,
    failing: []const Failing,
    state: State,
};

/// What tells one moment of a card from another: who would be told, who
/// failed, and when. The same failures told to the same terminal are the
/// same press, however often the card is redrawn.
///
/// **No group's name in it**, so a rename neither loses a press nor needs
/// re-keying (`tools/group-names-are-registered.py`). Two cards that would
/// tell the same terminal about the same failures share it, which is right:
/// pressing either would type the same paragraph into the same place.
pub fn stampOf(steward: ?Id, failing: []const Failing) u64 {
    var h: std.hash.Wyhash = .init(0x1560);
    const to: Id = steward orelse 0;
    h.update(std.mem.asBytes(&to));
    for (failing) |f| {
        h.update(std.mem.asBytes(&f.id));
        h.update(std.mem.asBytes(&f.since_ms));
    }
    return h.final();
}

/// The presses that have been made (`stampOf`). Eight bytes a press, kept
/// for the run: a stamp whose moment has passed is never matched again, and
/// a run sees few failures.
pub const Sent = struct {
    stamps: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub fn deinit(self: *Sent, alloc: Allocator) void {
        self.stamps.deinit(alloc);
        self.* = undefined;
    }

    pub fn mark(self: *Sent, alloc: Allocator, stamp: u64) Allocator.Error!void {
        try self.stamps.put(alloc, stamp, {});
    }

    pub fn has(self: *const Sent, stamp: u64) bool {
        return self.stamps.contains(stamp);
    }
};

/// The button on a card drawn with `word`, whose supervisor is `steward`,
/// failing as `failing`.
pub fn stateOf(word: Attention.Word, sent: *const Sent, steward: ?Id, failing: []const Failing) State {
    if (!offered(word) or failing.len == 0) return .none;
    return if (sent.has(stampOf(steward, failing))) .sent else .offered;
}

/// One paragraph to type into one terminal.
pub const Delivery = struct {
    to: Id,
    text: []const u8,
};

/// How a moment reads in a sentence; `daylog.stamp` in the app, a fixed
/// string in a test.
pub const Clock = *const fn (buf: *[19]u8, at_ms: i64) []const u8;

pub const tag = "[Polter 修复]";

/// Who is told, and what. One paragraph to the supervisor when there is
/// one, naming every failed terminal under the card; otherwise one to each
/// failed terminal, about itself.
pub fn plan(arena: Allocator, card: Card, clock: Clock) Allocator.Error![]const Delivery {
    if (card.steward) |steward| {
        const text = try paragraph(arena, steward, card.failing, clock);
        const out = try arena.alloc(Delivery, 1);
        out[0] = .{ .to = steward, .text = text };
        return out;
    }
    const out = try arena.alloc(Delivery, card.failing.len);
    for (card.failing, out) |f, *d| d.* = .{
        .to = f.id,
        .text = try paragraph(arena, f.id, &.{f}, clock),
    };
    return out;
}

/// The paragraph typed into `to` about `failing`, of which `to` itself may
/// be one.
pub fn paragraph(arena: Allocator, to: Id, failing: []const Failing, clock: Clock) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    writeParagraph(&out.writer, to, failing, clock) catch return error.OutOfMemory;
    return out.written();
}

fn writeParagraph(w: *std.Io.Writer, to: Id, failing: []const Failing, clock: Clock) std.Io.Writer.Error!void {
    var own: ?Failing = null;
    var workers: usize = 0;
    for (failing) |f| {
        if (f.id == to) own = f else workers += 1;
    }

    // One of them: the sentence the supervisor wrote, word for word.
    if (failing.len == 1) {
        const f = failing[0];
        if (own != null) {
            try w.print("{s} 你上一轮出错了：", .{tag});
            try writeWhatWhen(w, f, clock);
            try w.writeAll("。" ++ own_ask);
        } else {
            try w.print("{s} ", .{tag});
            try writeWho(w, f);
            try w.writeAll("出错了：");
            try writeWhatWhen(w, f, clock);
            try w.writeAll("。" ++ worker_ask);
        }
        return;
    }

    // Several: each named in turn, then what to do about each kind.
    try w.print("{s} 这里有 {d} 处出错：", .{ tag, failing.len });
    var first = true;
    for (failing) |f| {
        if (!first) try w.writeAll("；");
        first = false;
        if (f.id == to) {
            try w.writeAll("你自己上一轮出错了：");
        } else {
            try writeWho(w, f);
            try w.writeAll("出错了：");
        }
        try writeWhatWhen(w, f, clock);
    }
    try w.writeAll("。");
    if (workers > 0) try w.writeAll("对每个出错的终端，" ++ worker_ask);
    if (own != null) try w.writeAll("你自己：" ++ own_ask);
}

const worker_ask = "请先 terminal_read 看它停在哪：没做完，就让它接着做（terminal_send 叫它继续或重试）；" ++
    "已经做完了，就让它回一句完成（这一句会消掉出错），或者在不再需要时关掉它。处理完在群里说一声。";
const own_ask = "请判断上一轮做完没有：没做完就接着做；做完了就回一句完成。";

fn writeWho(w: *std.Io.Writer, f: Failing) std.Io.Writer.Error!void {
    if (f.title.len > 0) {
        try w.print("终端 {s}（0x{x:0>16}）", .{ f.title, f.id });
    } else {
        try w.print("终端 0x{x:0>16} ", .{f.id});
    }
}

fn writeWhatWhen(w: *std.Io.Writer, f: Failing, clock: Clock) std.Io.Writer.Error!void {
    try w.writeAll(if (f.what.len > 0) f.what else "原因不明");
    var buf: [19]u8 = undefined;
    const at = clock(&buf, @intCast(@min(f.at_wall_ms, std.math.maxInt(i64))));
    try w.print("，{s}", .{at});
}

/// What delivering needs from outside this file.
pub const Port = struct {
    ctx: *anyopaque,
    /// Whether an agent is connected from that terminal right now.
    agentPresent: *const fn (ctx: *anyopaque, id: Id) bool,
    /// Keep `text` in `group` from the person, naming `to`, and type it
    /// into each of `to` with a return -- `group_post`'s road, which fills
    /// in each one's `err`.
    post: *const fn (ctx: *anyopaque, group: []const u8, text: []const u8, to: []Target) anyerror!void,
    /// Type `text` into a terminal that is in no group, with a return.
    send: *const fn (ctx: *anyopaque, id: Id, text: []const u8) anyerror!void,
};

pub const Target = struct {
    to: Id,
    err: ?anyerror = null,
};

/// Carry a plan out. Every paragraph is kept in the group, whether or not
/// it can be typed; the first refusal is returned, by name, after all of
/// them have been tried.
///
/// **Nobody listening, nothing typed**: a terminal with no agent connected
/// is a bare shell, and a paragraph typed there with a return is run as a
/// command. `NoAgent`, the same gate a mention has.
pub fn deliver(key: Key, deliveries: []const Delivery, port: Port) anyerror!void {
    var first: ?anyerror = null;
    for (deliveries) |d| {
        const present = port.agentPresent(port.ctx, d.to);
        switch (key) {
            .group => |group| {
                var one = [_]Target{.{ .to = d.to }};
                const to: []Target = if (present) &one else &.{};
                try port.post(port.ctx, group, d.text, to);
                if (!present) {
                    if (first == null) first = error.NoAgent;
                } else if (one[0].err) |err| {
                    if (first == null) first = err;
                }
            },
            .terminal => {
                if (!present) {
                    if (first == null) first = error.NoAgent;
                    continue;
                }
                port.send(port.ctx, d.to, d.text) catch |err| {
                    if (first == null) first = err;
                };
            },
        }
    }
    if (first) |err| return err;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn fixedClock(buf: *[19]u8, at_ms: i64) []const u8 {
    return std.fmt.bufPrint(buf, "T{d}", .{@divFloor(at_ms, 1000)}) catch unreachable;
}

const boss: Id = 0xb055;
const w1: Id = 0xa1;
const w2: Id = 0xa2;

fn failed(id: Id, title: []const u8, what: []const u8, at_s: u64) Failing {
    return .{ .id = id, .title = title, .what = what, .since_ms = at_s * 1000, .at_wall_ms = at_s * 1000 };
}

test "ControlFix: the button is on a card that reads Failed, and on no other" {
    for (std.enums.values(Attention.Word)) |word| {
        try testing.expectEqual(word == .failed, offered(word));
    }
    // What the kinds are drawn as: only `failed` is.
    for (std.enums.values(Attention.Kind)) |kind| {
        try testing.expectEqual(kind == .failed, offered(Attention.displayOf(kind).word));
    }
}

test "ControlFix: a worker that failed: the supervisor is told, in the sentence the supervisor wrote" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try plan(arena.allocator(), .{
        .key = .{ .group = "build" },
        .steward = boss,
        .failing = &.{failed(w1, "api", "server_error", 7)},
        .state = .offered,
    }, fixedClock);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(boss, out[0].to);
    try testing.expectEqualStrings(
        "[Polter 修复] 终端 api（0x00000000000000a1）出错了：server_error，T7。" ++
            "请先 terminal_read 看它停在哪：没做完，就让它接着做（terminal_send 叫它继续或重试）；" ++
            "已经做完了，就让它回一句完成（这一句会消掉出错），或者在不再需要时关掉它。处理完在群里说一声。",
        out[0].text,
    );
}

test "ControlFix: the supervisor that failed is told about itself" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try plan(arena.allocator(), .{
        .key = .{ .group = "build" },
        .steward = boss,
        .failing = &.{failed(boss, "boss", "rate_limit", 9)},
        .state = .offered,
    }, fixedClock);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(boss, out[0].to);
    try testing.expectEqualStrings(
        "[Polter 修复] 你上一轮出错了：rate_limit，T9。请判断上一轮做完没有：没做完就接着做；做完了就回一句完成。",
        out[0].text,
    );
}

test "ControlFix: several failed under one card: one paragraph, each named in turn" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try plan(arena.allocator(), .{
        .key = .{ .group = "build" },
        .steward = boss,
        .failing = &.{ failed(w1, "api", "server_error", 7), failed(w2, "", "", 8), failed(boss, "boss", "rate_limit", 9) },
        .state = .offered,
    }, fixedClock);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(boss, out[0].to);
    try testing.expectEqualStrings(
        "[Polter 修复] 这里有 3 处出错：" ++
            "终端 api（0x00000000000000a1）出错了：server_error，T7；" ++
            "终端 0x00000000000000a2 出错了：原因不明，T8；" ++
            "你自己上一轮出错了：rate_limit，T9。" ++
            "对每个出错的终端，请先 terminal_read 看它停在哪：没做完，就让它接着做（terminal_send 叫它继续或重试）；" ++
            "已经做完了，就让它回一句完成（这一句会消掉出错），或者在不再需要时关掉它。处理完在群里说一声。" ++
            "你自己：请判断上一轮做完没有：没做完就接着做；做完了就回一句完成。",
        out[0].text,
    );
}

test "ControlFix: no supervisor: each failed terminal is told about itself" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try plan(arena.allocator(), .{
        .key = .{ .group = "loose" },
        .steward = null,
        .failing = &.{ failed(w1, "api", "server_error", 7), failed(w2, "web", "rate_limit", 8) },
        .state = .offered,
    }, fixedClock);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(w1, out[0].to);
    try testing.expectEqualStrings(
        "[Polter 修复] 你上一轮出错了：server_error，T7。请判断上一轮做完没有：没做完就接着做；做完了就回一句完成。",
        out[0].text,
    );
    try testing.expectEqual(w2, out[1].to);
    try testing.expectEqualStrings(
        "[Polter 修复] 你上一轮出错了：rate_limit，T8。请判断上一轮做完没有：没做完就接着做；做完了就回一句完成。",
        out[1].text,
    );
}

test "ControlFix: notified stands until the card changes" {
    var sent: Sent = .{};
    defer sent.deinit(testing.allocator);
    const now = [_]Failing{failed(w1, "api", "server_error", 7)};

    try testing.expectEqual(State.offered, stateOf(.failed, &sent, boss, &now));
    try sent.mark(testing.allocator, stampOf(boss, &now));
    try testing.expectEqual(State.sent, stateOf(.failed, &sent, boss, &now));
    // Marked again, as after a second press: one mark, not two.
    try sent.mark(testing.allocator, stampOf(boss, &now));
    try testing.expectEqual(@as(u32, 1), sent.stamps.count());

    // It failed again, later: a new moment, and the button again.
    const again = [_]Failing{failed(w1, "api", "server_error", 70)};
    try testing.expectEqual(State.offered, stateOf(.failed, &sent, boss, &again));
    // Another one failed beside it.
    const more = [_]Failing{ now[0], failed(w2, "web", "", 8) };
    try testing.expectEqual(State.offered, stateOf(.failed, &sent, boss, &more));
    // No longer failed: no button at all.
    try testing.expectEqual(State.none, stateOf(.working, &sent, boss, &now));
    // The same failure, told to somebody else -- another group's
    // supervisor, or the terminal itself: not this press.
    try testing.expectEqual(State.offered, stateOf(.failed, &sent, w2, &now));
    try testing.expectEqual(State.offered, stateOf(.failed, &sent, null, &now));
    // Drawn Failed with nobody failing under it: nothing to tell anyone.
    try testing.expectEqual(State.none, stateOf(.failed, &sent, boss, &.{}));
}

/// A port that writes down what it was asked to do.
const Recorder = struct {
    absent: []const Id = &.{},
    refuse: ?anyerror = null,
    posts: std.ArrayListUnmanaged(Post) = .empty,
    sends: std.ArrayListUnmanaged(Id) = .empty,

    const Post = struct { group: []const u8, text: []const u8, typed: ?Id };

    fn deinit(self: *Recorder) void {
        self.posts.deinit(testing.allocator);
        self.sends.deinit(testing.allocator);
    }

    fn port(self: *Recorder) Port {
        return .{ .ctx = self, .agentPresent = agentPresent, .post = post, .send = send };
    }

    fn agentPresent(ctx: *anyopaque, id: Id) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        return std.mem.indexOfScalar(Id, self.absent, id) == null;
    }

    fn post(ctx: *anyopaque, group: []const u8, text: []const u8, to: []Target) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        for (to) |*t| t.err = self.refuse;
        try self.posts.append(testing.allocator, .{
            .group = group,
            .text = text,
            .typed = if (to.len > 0 and self.refuse == null) to[0].to else null,
        });
    }

    fn send(ctx: *anyopaque, id: Id, _: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse) |err| return err;
        try self.sends.append(testing.allocator, id);
    }
};

test "ControlFix: a group's fix is kept in the group and typed into the supervisor" {
    var r: Recorder = .{};
    defer r.deinit();
    try deliver(.{ .group = "build" }, &.{.{ .to = boss, .text = "x" }}, r.port());
    try testing.expectEqual(@as(usize, 1), r.posts.items.len);
    try testing.expectEqualStrings("build", r.posts.items[0].group);
    try testing.expectEqualStrings("x", r.posts.items[0].text);
    try testing.expectEqual(@as(?Id, boss), r.posts.items[0].typed);
    try testing.expectEqual(@as(usize, 0), r.sends.items.len);
}

test "ControlFix: a refused typing is said by its name, and the paragraph is still kept" {
    var r: Recorder = .{ .refuse = error.UserPresent };
    defer r.deinit();
    try testing.expectError(error.UserPresent, deliver(.{ .group = "build" }, &.{.{ .to = boss, .text = "x" }}, r.port()));
    try testing.expectEqual(@as(usize, 1), r.posts.items.len);
}

test "ControlFix: nobody listening: kept, not typed, and refused as NoAgent" {
    var r: Recorder = .{ .absent = &.{boss} };
    defer r.deinit();
    try testing.expectError(error.NoAgent, deliver(.{ .group = "build" }, &.{.{ .to = boss, .text = "x" }}, r.port()));
    try testing.expectEqual(@as(usize, 1), r.posts.items.len);
    try testing.expectEqual(@as(?Id, null), r.posts.items[0].typed);

    // A terminal in no group: nothing to keep it in, and nothing typed.
    var lone: Recorder = .{ .absent = &.{w1} };
    defer lone.deinit();
    try testing.expectError(error.NoAgent, deliver(.{ .terminal = w1 }, &.{.{ .to = w1, .text = "x" }}, lone.port()));
    try testing.expectEqual(@as(usize, 0), lone.posts.items.len);
    try testing.expectEqual(@as(usize, 0), lone.sends.items.len);
}

test "ControlFix: a terminal in no group is typed into, and nothing is posted" {
    var r: Recorder = .{};
    defer r.deinit();
    try deliver(.{ .terminal = w1 }, &.{.{ .to = w1, .text = "x" }}, r.port());
    try testing.expectEqual(@as(usize, 0), r.posts.items.len);
    try testing.expectEqualSlices(Id, &.{w1}, r.sends.items);
}

test "ControlFix: several to tell: every one is tried, and the first refusal is the answer" {
    var r: Recorder = .{ .absent = &.{w1} };
    defer r.deinit();
    try testing.expectError(error.NoAgent, deliver(
        .{ .group = "loose" },
        &.{ .{ .to = w1, .text = "a" }, .{ .to = w2, .text = "b" } },
        r.port(),
    ));
    try testing.expectEqual(@as(usize, 2), r.posts.items.len);
    try testing.expectEqual(@as(?Id, null), r.posts.items[0].typed);
    try testing.expectEqual(@as(?Id, w2), r.posts.items[1].typed);
}
