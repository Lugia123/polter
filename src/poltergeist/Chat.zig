//! Messages between the terminals Poltergeist knows about.
//!
//! One group everyone may join, plus direct messages between any two
//! terminals. Kept apart from `Bus`, which is about supervision: who may
//! talk to whom here is not who may steer whom there, and running them
//! together would make it easy to confuse the two.
//!
//! What a terminal is *told* when a message arrives is only that there is
//! one. The body is fetched by asking. That is the whole reason this exists
//! as a log rather than as a delivery mechanism -- see
//! `docs/poltergeist/mcp.md`.
//!
//! Pure: time arrives as a parameter, and the only allocation is the log.

const Chat = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");

pub const Id = Bus.Id;

/// Where a message went.
pub const Audience = union(enum) {
    /// Everyone in the group at the time it was read.
    group,

    /// One terminal, and nobody else -- not even the supervisor.
    direct: Id,
};

pub const Message = struct {
    /// Monotonic across the whole log, group and direct alike, so one
    /// cursor is enough to say "everything I have not seen".
    seq: u64,
    from: Id,
    audience: Audience,
    at_ms: u64,

    /// Owned by the log.
    text: []const u8,

    /// Whether `reader` is allowed to see this at all.
    pub fn visibleTo(self: Message, reader: Id) bool {
        return switch (self.audience) {
            .group => true,
            .direct => |to| to == reader or self.from == reader,
        };
    }
};

pub const Config = struct {
    /// How many messages to keep. A group of agents left running overnight
    /// will produce more than anyone will read; the oldest go first.
    max_messages: usize = 1000,

    /// Longest single message. Agents paste log fragments at each other,
    /// and one of them should not be able to fill the log by itself.
    max_text_bytes: usize = 8 * 1024,
};

pub const PostError = error{
    /// The sender is not in the group.
    NotJoined,

    /// Nothing to say.
    Empty,

    /// A terminal cannot send itself a direct message.
    SelfTarget,
} || Allocator.Error;

const Reader = struct {
    /// Highest seq this terminal has been shown.
    cursor: u64 = 0,

    /// Whether it is in the group. Direct messages work either way: they
    /// are between two terminals and have nothing to do with the group.
    joined: bool = false,

    /// When this terminal was last told it had messages, for rate
    /// limiting.
    last_told_ms: ?u64 = null,
};

alloc: Allocator,
config: Config,

/// Oldest first. A plain list with a cap rather than a ring buffer: reads
/// are rare and the cap is small, so the copying does not matter and the
/// ordering stays obvious.
log: std.ArrayListUnmanaged(Message) = .empty,

readers: std.AutoHashMapUnmanaged(Id, Reader) = .empty,
next_seq: u64 = 1,

pub fn init(alloc: Allocator, config: Config) Chat {
    return .{ .alloc = alloc, .config = config };
}

pub fn deinit(self: *Chat) void {
    for (self.log.items) |m| self.alloc.free(m.text);
    self.log.deinit(self.alloc);
    self.readers.deinit(self.alloc);
    self.* = undefined;
}

fn readerFor(self: *Chat, id: Id) Allocator.Error!*Reader {
    const gop = try self.readers.getOrPut(self.alloc, id);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    return gop.value_ptr;
}

/// Put a terminal in the group.
///
/// Joining does not show it what was said before it arrived: its cursor
/// starts at the present. Handing a newcomer the whole night's backlog
/// would flood the context it needs for its own work.
pub fn join(self: *Chat, id: Id) Allocator.Error!void {
    const r = try self.readerFor(id);
    if (!r.joined) {
        r.joined = true;
        r.cursor = self.next_seq - 1;
    }
}

pub fn leave(self: *Chat, id: Id) void {
    if (self.readers.getPtr(id)) |r| r.joined = false;
}

pub fn isJoined(self: *const Chat, id: Id) bool {
    const r = self.readers.get(id) orelse return false;
    return r.joined;
}

/// Forget a terminal entirely, for example because it closed.
pub fn forget(self: *Chat, id: Id) void {
    _ = self.readers.remove(id);
}

/// Say something to the group.
pub fn post(self: *Chat, from: Id, text: []const u8, now_ms: u64) PostError!u64 {
    if (!self.isJoined(from)) return error.NotJoined;
    return self.append(from, .group, text, now_ms);
}

/// Say something to one terminal.
pub fn direct(
    self: *Chat,
    from: Id,
    to: Id,
    text: []const u8,
    now_ms: u64,
) PostError!u64 {
    if (from == to) return error.SelfTarget;
    return self.append(from, .{ .direct = to }, text, now_ms);
}

fn append(
    self: *Chat,
    from: Id,
    audience: Audience,
    text: []const u8,
    now_ms: u64,
) PostError!u64 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.Empty;

    const kept = trimmed[0..@min(trimmed.len, self.config.max_text_bytes)];
    const owned = try self.alloc.dupe(u8, kept);
    errdefer self.alloc.free(owned);

    // The sender has seen its own message by definition, so posting never
    // makes a terminal unread to itself.
    const r = try self.readerFor(from);

    const seq = self.next_seq;
    self.next_seq += 1;

    try self.log.append(self.alloc, .{
        .seq = seq,
        .from = from,
        .audience = audience,
        .at_ms = now_ms,
        .text = owned,
    });
    r.cursor = seq;

    self.trim();
    return seq;
}

fn trim(self: *Chat) void {
    if (self.log.items.len <= self.config.max_messages) return;

    const drop = self.log.items.len - self.config.max_messages;
    for (self.log.items[0..drop]) |m| self.alloc.free(m.text);
    std.mem.copyForwards(
        Message,
        self.log.items[0 .. self.log.items.len - drop],
        self.log.items[drop..],
    );
    self.log.shrinkRetainingCapacity(self.log.items.len - drop);
}

/// How many messages `id` has not been shown.
///
/// Its own messages never count: a terminal is not unread to itself.
pub fn unread(self: *const Chat, id: Id) usize {
    // A terminal with no record has simply never taken part: cursor at
    // zero, not in the group. It can still have direct messages waiting,
    // which is why this defaults rather than returning early.
    const r: Reader = self.readers.get(id) orelse .{};

    var n: usize = 0;
    for (self.log.items) |m| {
        if (m.seq <= r.cursor) continue;
        if (m.from == id) continue;
        if (!m.visibleTo(id)) continue;
        if (m.audience == .group and !r.joined) continue;
        n += 1;
    }
    return n;
}

/// Everything `id` may see with a seq above `since`, oldest first.
///
/// The returned slice is the caller's; the message texts inside it are
/// still the log's, so a caller that keeps them must copy.
pub fn read(
    self: *Chat,
    alloc: Allocator,
    id: Id,
    since: u64,
) Allocator.Error![]const Message {
    const r = try self.readerFor(id);

    var out: std.ArrayListUnmanaged(Message) = .empty;
    errdefer out.deinit(alloc);

    for (self.log.items) |m| {
        if (m.seq <= since) continue;
        if (!m.visibleTo(id)) continue;
        if (m.audience == .group and !r.joined) continue;
        try out.append(alloc, m);
    }

    // Reading is what marks messages seen. Anything that arrives after
    // this call keeps its own seq and will still be unread.
    if (self.log.items.len > 0) {
        const newest = self.log.items[self.log.items.len - 1].seq;
        if (newest > r.cursor) r.cursor = newest;
    }

    return out.toOwnedSlice(alloc);
}

/// Whether `id` should be told it has messages, given how recently it was
/// last told.
///
/// Kept here rather than at the delivery site so the rule is testable
/// without a terminal to type into.
pub fn shouldNotify(
    self: *Chat,
    id: Id,
    now_ms: u64,
    gap_ms: u64,
) Allocator.Error!bool {
    if (self.unread(id) == 0) return false;

    const r = try self.readerFor(id);
    if (r.last_told_ms) |last| {
        if (now_ms -| last < gap_ms) return false;
    }
    r.last_told_ms = now_ms;
    return true;
}

/// The line a terminal is given when it has messages waiting.
///
/// A count and how to fetch them, never the messages. An agent's context
/// is for its own work; what it does with a nudge to go and look is its
/// own decision, and one it can decline.
pub fn formatNotice(count: usize, buf: []u8) std.fmt.BufPrintError![]u8 {
    return std.fmt.bufPrint(
        buf,
        "[poltergeist] {d} new message{s} waiting. Read them with group_read or dm_read.",
        .{ count, if (count == 1) "" else "s" },
    );
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const a: Id = 0x1111;
const b: Id = 0x2222;
const c: Id = 0x3333;

fn testChat() Chat {
    return .init(testing.allocator, .{});
}

test "a terminal must join before it can post" {
    var chat = testChat();
    defer chat.deinit();

    try testing.expectError(error.NotJoined, chat.post(a, "hello", 0));

    try chat.join(a);
    _ = try chat.post(a, "hello", 0);
}

test "group messages reach everyone in the group" {
    var chat = testChat();
    defer chat.deinit();

    try chat.join(a);
    try chat.join(b);
    _ = try chat.post(a, "build is green", 100);

    try testing.expectEqual(@as(usize, 1), chat.unread(b));

    // Never unread to the sender.
    try testing.expectEqual(@as(usize, 0), chat.unread(a));
}

test "somebody outside the group sees nothing of it" {
    var chat = testChat();
    defer chat.deinit();

    try chat.join(a);
    try chat.join(b);
    _ = try chat.post(a, "internal", 0);

    // c exists but never joined.
    try chat.join(c);
    chat.leave(c);
    try testing.expectEqual(@as(usize, 0), chat.unread(c));

    const seen = try chat.read(testing.allocator, c, 0);
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 0), seen.len);
}

test "a direct message is seen by exactly two terminals" {
    var chat = testChat();
    defer chat.deinit();

    for ([_]Id{ a, b, c }) |id| try chat.join(id);
    _ = try chat.direct(a, b, "just between us", 0);

    try testing.expectEqual(@as(usize, 1), chat.unread(b));
    try testing.expectEqual(@as(usize, 0), chat.unread(a));

    // Not even a third terminal in the group, and not the supervisor
    // either -- there is no privileged reader here.
    try testing.expectEqual(@as(usize, 0), chat.unread(c));

    const seen = try chat.read(testing.allocator, c, 0);
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 0), seen.len);
}

test "a direct message works without either side being in the group" {
    var chat = testChat();
    defer chat.deinit();

    _ = try chat.direct(a, b, "private", 0);
    try testing.expectEqual(@as(usize, 1), chat.unread(b));
}

test "a terminal cannot message itself" {
    var chat = testChat();
    defer chat.deinit();
    try testing.expectError(error.SelfTarget, chat.direct(a, a, "hi", 0));
}

test "empty and whitespace-only messages are refused" {
    var chat = testChat();
    defer chat.deinit();
    try chat.join(a);

    try testing.expectError(error.Empty, chat.post(a, "", 0));
    try testing.expectError(error.Empty, chat.post(a, "   \n\t ", 0));
}

test "reading marks everything seen" {
    var chat = testChat();
    defer chat.deinit();

    try chat.join(a);
    try chat.join(b);
    _ = try chat.post(a, "one", 0);
    _ = try chat.post(a, "two", 1);

    try testing.expectEqual(@as(usize, 2), chat.unread(b));

    const seen = try chat.read(testing.allocator, b, 0);
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 2), seen.len);
    try testing.expectEqualStrings("one", seen[0].text);
    try testing.expectEqual(@as(usize, 0), chat.unread(b));

    // Something said afterwards is unread again.
    _ = try chat.post(a, "three", 2);
    try testing.expectEqual(@as(usize, 1), chat.unread(b));
}

test "a cursor lets a reader pick up where it left off" {
    var chat = testChat();
    defer chat.deinit();

    try chat.join(a);
    try chat.join(b);
    const first = try chat.post(a, "one", 0);
    _ = try chat.post(a, "two", 1);

    const rest = try chat.read(testing.allocator, b, first);
    defer testing.allocator.free(rest);
    try testing.expectEqual(@as(usize, 1), rest.len);
    try testing.expectEqualStrings("two", rest[0].text);
}

test "joining does not hand over the backlog" {
    // A terminal that joins at midnight should not wake up to everything
    // said since dinner; that context belongs to its own work.
    var chat = testChat();
    defer chat.deinit();

    try chat.join(a);
    _ = try chat.post(a, "old news", 0);
    _ = try chat.post(a, "older news", 1);

    try chat.join(b);
    try testing.expectEqual(@as(usize, 0), chat.unread(b));

    _ = try chat.post(a, "fresh", 2);
    try testing.expectEqual(@as(usize, 1), chat.unread(b));
}

test "leaving and rejoining does not replay what was missed" {
    var chat = testChat();
    defer chat.deinit();

    try chat.join(a);
    try chat.join(b);
    chat.leave(b);
    _ = try chat.post(a, "while you were out", 0);

    try chat.join(b);
    try testing.expectEqual(@as(usize, 0), chat.unread(b));
}

test "the log is capped and the oldest go first" {
    var chat: Chat = .init(testing.allocator, .{ .max_messages = 3 });
    defer chat.deinit();

    try chat.join(a);
    for (0..5) |i| {
        var buf: [8]u8 = undefined;
        _ = try chat.post(a, try std.fmt.bufPrint(&buf, "m{d}", .{i}), i);
    }

    try testing.expectEqual(@as(usize, 3), chat.log.items.len);
    try testing.expectEqualStrings("m2", chat.log.items[0].text);
    try testing.expectEqualStrings("m4", chat.log.items[2].text);
}

test "one message cannot fill the log by itself" {
    var chat: Chat = .init(testing.allocator, .{ .max_text_bytes = 16 });
    defer chat.deinit();

    try chat.join(a);
    _ = try chat.post(a, "x" ** 100, 0);
    try testing.expectEqual(@as(usize, 16), chat.log.items[0].text.len);
}

test "notices are rate limited per terminal" {
    var chat = testChat();
    defer chat.deinit();

    try chat.join(a);
    try chat.join(b);
    _ = try chat.post(a, "one", 0);

    try testing.expect(try chat.shouldNotify(b, 0, 1000));
    try testing.expect(!try chat.shouldNotify(b, 500, 1000));

    _ = try chat.post(a, "two", 900);
    try testing.expect(!try chat.shouldNotify(b, 900, 1000));
    try testing.expect(try chat.shouldNotify(b, 1000, 1000));
}

test "a terminal with nothing waiting is never told anything" {
    var chat = testChat();
    defer chat.deinit();

    try chat.join(a);
    try chat.join(b);
    try testing.expect(!try chat.shouldNotify(b, 0, 1000));

    // And not for its own messages either.
    _ = try chat.post(b, "mine", 0);
    try testing.expect(!try chat.shouldNotify(b, 10_000, 1000));
}

test "forgetting a terminal clears what it had seen" {
    var chat = testChat();
    defer chat.deinit();

    try chat.join(a);
    try chat.join(b);
    _ = try chat.post(a, "hello", 0);

    chat.forget(b);
    try testing.expectEqual(@as(usize, 0), chat.unread(b));
    try testing.expect(!chat.isJoined(b));
}

test "a notice carries a count and how to fetch, never the message" {
    var buf: [256]u8 = undefined;

    const one = try formatNotice(1, &buf);
    try testing.expect(std.mem.indexOf(u8, one, "1 new message ") != null);
    try testing.expect(std.mem.indexOf(u8, one, "group_read") != null);

    const many = try formatNotice(4, &buf);
    try testing.expect(std.mem.indexOf(u8, many, "4 new messages") != null);
}
