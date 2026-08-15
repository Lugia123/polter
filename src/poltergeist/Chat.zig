//! Groups the terminals talk in.
//!
//! A group is made by the supervisor, which decides who is in it and
//! whether a terminal joining late sees what was said before it arrived.
//! There are no direct messages: a conversation between two terminals is a
//! group with two terminals in it, which is one set of rules instead of two.
//!
//! Kept apart from `Bus`, which is about supervision: who may talk to whom
//! is not who may steer whom, and running them together would make that
//! easy to confuse.
//!
//! What a terminal is *told* when a message arrives is only that there is
//! one, and where. The body is fetched by asking. See
//! `docs/poltergeist/mcp.md`.
//!
//! Pure: time arrives as a parameter, and the only allocation is the log.

const Chat = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");

pub const Id = Bus.Id;

/// The person at the keyboard.
///
/// Zero, which `Surface.id` is documented never to be, so it cannot
/// collide with a terminal. The user is put in every group as it is made:
/// these are conversations happening on their machine, and a window they
/// can read but not answer in would be a strange thing to build.
pub const user_id: Id = 0;

/// What a terminal added to a group is shown of what came before.
pub const History = enum {
    /// Nothing. The conversation starts for them now.
    none,

    /// Everything still in the log.
    all,
};

pub const Message = struct {
    /// Monotonic within its group, so one cursor per group is enough.
    seq: u64,
    from: Id,
    at_ms: u64,

    /// True when this stands in for messages the supervisor compacted
    /// away, so a reader can tell a summary from something somebody
    /// actually said.
    summary: bool = false,

    /// Owned by the group.
    text: []const u8,
};

pub const Config = struct {
    /// Messages kept per group before the oldest start falling off.
    max_messages: usize = 1000,

    /// Longest single message. Agents paste log fragments at each other,
    /// and one of them should not be able to fill a group by itself.
    max_text_bytes: usize = 8 * 1024,

    /// Most groups that may exist at once.
    max_groups: usize = 32,
};

pub const Error = error{
    NoSuchGroup,
    GroupExists,
    NotAMember,
    TooManyGroups,
    BadName,

    /// Nothing to say, or nothing to compact.
    Empty,
} || Allocator.Error;

const Member = struct {
    /// Messages at or below this are not shown to this member: it was
    /// added without history, and this is where its view begins.
    floor: u64 = 0,

    /// Highest seq this member has been shown.
    cursor: u64 = 0,

    /// When it was last told this group had messages, for rate limiting.
    last_told_ms: ?u64 = null,
};

const Group = struct {
    /// Owned by the chat, and also the key it is stored under.
    name: []const u8,
    created_by: Id,
    next_seq: u64 = 1,
    log: std.ArrayListUnmanaged(Message) = .empty,
    members: std.AutoHashMapUnmanaged(Id, Member) = .empty,

    fn deinit(self: *Group, alloc: Allocator) void {
        for (self.log.items) |m| alloc.free(m.text);
        self.log.deinit(alloc);
        self.members.deinit(alloc);
        alloc.free(self.name);
    }

    fn head(self: *const Group) u64 {
        return self.next_seq - 1;
    }
};

alloc: Allocator,
config: Config,

/// Keyed by name, which is what agents use to refer to one.
groups: std.StringHashMapUnmanaged(Group) = .empty,

pub fn init(alloc: Allocator, config: Config) Chat {
    return .{ .alloc = alloc, .config = config };
}

pub fn deinit(self: *Chat) void {
    var it = self.groups.valueIterator();
    while (it.next()) |g| g.deinit(self.alloc);
    self.groups.deinit(self.alloc);
    self.* = undefined;
}

/// Group names get passed around by agents, so they are restricted rather
/// than sanitised: lowercase, digits and dashes.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > 48) return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// Make a group. The creator is its first member and sees everything in
/// it, there being nothing yet to miss.
pub fn create(self: *Chat, name: []const u8, by: Id) Error!void {
    if (!isValidName(name)) return error.BadName;
    if (self.groups.contains(name)) return error.GroupExists;
    if (self.groups.count() >= self.config.max_groups) return error.TooManyGroups;

    const owned = try self.alloc.dupe(u8, name);
    errdefer self.alloc.free(owned);

    var group: Group = .{ .name = owned, .created_by = by };
    errdefer group.deinit(self.alloc);
    try group.members.put(self.alloc, by, .{});

    try self.groups.put(self.alloc, owned, group);
}

pub fn destroy(self: *Chat, name: []const u8) Error!void {
    const entry = self.groups.fetchRemove(name) orelse return error.NoSuchGroup;
    var group = entry.value;
    group.deinit(self.alloc);
}

/// Put a terminal in a group, deciding what it sees of what came before.
pub fn add(self: *Chat, name: []const u8, id: Id, history: History) Error!void {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;

    // Already in it: leave its view alone rather than silently rewriting
    // what it can see.
    if (group.members.contains(id)) return;

    try group.members.put(self.alloc, id, switch (history) {
        // Nothing before now, and nothing waiting.
        .none => .{ .floor = group.head(), .cursor = group.head() },

        // Everything, and all of it unread and worth fetching.
        .all => .{ .floor = 0, .cursor = 0 },
    });
}

pub fn remove(self: *Chat, name: []const u8, id: Id) Error!void {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    _ = group.members.remove(id);
}

pub fn isMember(self: *const Chat, name: []const u8, id: Id) bool {
    const group = self.groups.getPtr(name) orelse return false;
    return group.members.contains(id);
}

pub fn exists(self: *const Chat, name: []const u8) bool {
    return self.groups.contains(name);
}

/// Forget a terminal everywhere, for example because it closed.
pub fn forget(self: *Chat, id: Id) void {
    var it = self.groups.valueIterator();
    while (it.next()) |g| _ = g.members.remove(id);
}

/// Say something to a group.
pub fn post(
    self: *Chat,
    name: []const u8,
    from: Id,
    text: []const u8,
    now_ms: u64,
) Error!u64 {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    if (!group.members.contains(from)) return error.NotAMember;
    return self.append(group, from, text, now_ms, false);
}

fn append(
    self: *Chat,
    group: *Group,
    from: Id,
    text: []const u8,
    now_ms: u64,
    summary: bool,
) Error!u64 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.Empty;

    const kept = trimmed[0..@min(trimmed.len, self.config.max_text_bytes)];
    const owned = try self.alloc.dupe(u8, kept);
    errdefer self.alloc.free(owned);

    const seq = group.next_seq;
    group.next_seq += 1;

    try group.log.append(self.alloc, .{
        .seq = seq,
        .from = from,
        .at_ms = now_ms,
        .summary = summary,
        .text = owned,
    });

    // The sender has seen its own message by definition.
    if (group.members.getPtr(from)) |m| m.cursor = seq;

    self.trim(group);
    return seq;
}

fn trim(self: *Chat, group: *Group) void {
    if (group.log.items.len <= self.config.max_messages) return;

    const drop = group.log.items.len - self.config.max_messages;
    for (group.log.items[0..drop]) |m| self.alloc.free(m.text);
    std.mem.copyForwards(
        Message,
        group.log.items[0 .. group.log.items.len - drop],
        group.log.items[drop..],
    );
    group.log.shrinkRetainingCapacity(group.log.items.len - drop);
}

/// Replace everything up to and including `through` with one summary the
/// supervisor wrote.
///
/// The supervisor writes the summary and the program does the replacing,
/// which is the division used everywhere else here: judging what a
/// conversation amounted to is not something code can do, and rewriting a
/// log correctly is not something a prompt should be trusted with.
///
/// The summary keeps the seq of the last message it replaces, so a member
/// that had not caught up is left with something to read rather than a gap.
pub fn compact(
    self: *Chat,
    name: []const u8,
    through: u64,
    summary: []const u8,
    by: Id,
    now_ms: u64,
) Error!u64 {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;

    const trimmed = std.mem.trim(u8, summary, " \t\r\n");
    if (trimmed.len == 0) return error.Empty;

    // Where the replaced range ends.
    var cut: usize = 0;
    while (cut < group.log.items.len and group.log.items[cut].seq <= through) {
        cut += 1;
    }

    // Nothing covered: refuse rather than leave a summary standing for
    // messages it did not replace.
    if (cut == 0) return error.Empty;

    const kept = trimmed[0..@min(trimmed.len, self.config.max_text_bytes)];
    const owned = try self.alloc.dupe(u8, kept);
    errdefer self.alloc.free(owned);

    const seq = group.log.items[cut - 1].seq;
    for (group.log.items[0..cut]) |m| self.alloc.free(m.text);

    if (cut > 1) {
        std.mem.copyForwards(
            Message,
            group.log.items[1 .. group.log.items.len - (cut - 1)],
            group.log.items[cut..],
        );
        group.log.shrinkRetainingCapacity(group.log.items.len - (cut - 1));
    }

    group.log.items[0] = .{
        .seq = seq,
        .from = by,
        .at_ms = now_ms,
        .summary = true,
        .text = owned,
    };

    // A member whose view began inside the replaced range should see the
    // summary rather than nothing: that is what leaving one is for.
    var it = group.members.valueIterator();
    while (it.next()) |m| {
        if (m.floor >= seq) continue;
        m.floor = seq - 1;
        if (m.cursor >= seq) m.cursor = seq - 1;
    }

    return seq;
}

/// How many messages `id` has not been shown in this group.
pub fn unread(self: *const Chat, name: []const u8, id: Id) usize {
    const group = self.groups.getPtr(name) orelse return 0;
    const who = group.members.get(id) orelse return 0;

    var n: usize = 0;
    for (group.log.items) |m| {
        if (m.seq <= who.cursor) continue;
        if (m.seq <= who.floor) continue;
        if (m.from == id) continue;
        n += 1;
    }
    return n;
}

/// Total unread across every group `id` is in.
pub fn unreadTotal(self: *const Chat, id: Id) usize {
    var n: usize = 0;
    var it = self.groups.keyIterator();
    while (it.next()) |name| n += self.unread(name.*, id);
    return n;
}

/// Everything `id` may see in this group above `since`, oldest first.
///
/// The slice is the caller's; the texts inside it still belong to the
/// group, so a caller that keeps them must copy.
pub fn read(
    self: *Chat,
    alloc: Allocator,
    name: []const u8,
    id: Id,
    since: u64,
) Error![]const Message {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    const who = group.members.getPtr(id) orelse return error.NotAMember;

    var out: std.ArrayListUnmanaged(Message) = .empty;
    errdefer out.deinit(alloc);

    for (group.log.items) |m| {
        if (m.seq <= since) continue;
        if (m.seq <= who.floor) continue;
        try out.append(alloc, m);
    }

    if (group.log.items.len > 0) {
        const newest = group.log.items[group.log.items.len - 1].seq;
        if (newest > who.cursor) who.cursor = newest;
    }

    return out.toOwnedSlice(alloc);
}

/// The groups `id` is in, sorted so two listings can be compared.
///
/// The names belong to the chat, so a caller that keeps them must copy.
pub fn groupsFor(
    self: *const Chat,
    alloc: Allocator,
    id: Id,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(alloc);

    var it = self.groups.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.members.contains(id)) try out.append(alloc, kv.key_ptr.*);
    }

    const owned = try out.toOwnedSlice(alloc);
    std.mem.sort([]const u8, owned, {}, lessThan);
    return owned;
}

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

/// Whether `id` should be told this group has messages waiting.
pub fn shouldNotify(
    self: *Chat,
    name: []const u8,
    id: Id,
    now_ms: u64,
    gap_ms: u64,
) bool {
    if (self.unread(name, id) == 0) return false;

    const group = self.groups.getPtr(name) orelse return false;
    const who = group.members.getPtr(id) orelse return false;

    if (who.last_told_ms) |last| {
        if (now_ms -| last < gap_ms) return false;
    }
    who.last_told_ms = now_ms;
    return true;
}

/// The line a terminal is given when a group has messages waiting.
///
/// A count, a group name, and how to fetch. Never the messages: an agent's
/// context is for its own work, and going to look is its own decision.
pub fn formatNotice(
    name: []const u8,
    count: usize,
    buf: []u8,
) std.fmt.BufPrintError![]u8 {
    return std.fmt.bufPrint(
        buf,
        "[poltergeist] {d} new message{s} in \"{s}\". Read them with group_read.",
        .{ count, if (count == 1) "" else "s", name },
    );
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const boss: Id = 0x1111;
const a: Id = 0x2222;
const b: Id = 0x3333;

fn testChat() Chat {
    return .init(testing.allocator, .{});
}

test "the user's id cannot collide with a terminal's" {
    // Surface.id is documented never to be zero, which is what makes zero
    // safe to reserve.
    try testing.expect(user_id == 0);
}

test "a group starts with its creator in it" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try testing.expect(chat.isMember("build", boss));
    try testing.expect(!chat.isMember("build", a));
}

test "group names are restricted" {
    var chat = testChat();
    defer chat.deinit();

    try testing.expectError(error.BadName, chat.create("Has Spaces", boss));
    try testing.expectError(error.BadName, chat.create("../escape", boss));
    try testing.expectError(error.BadName, chat.create("", boss));
    try chat.create("build-2", boss);
}

test "a group cannot be made twice" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try testing.expectError(error.GroupExists, chat.create("build", boss));
}

test "there can be several groups at once" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.create("research", boss);
    try chat.add("build", a, .none);
    try chat.add("research", b, .none);

    _ = try chat.post("build", boss, "for the builders", 0);
    try testing.expectEqual(@as(usize, 1), chat.unread("build", a));
    try testing.expectEqual(@as(usize, 0), chat.unread("research", b));
}

test "only members may post" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try testing.expectError(error.NotAMember, chat.post("build", a, "hi", 0));

    try chat.add("build", a, .none);
    _ = try chat.post("build", a, "hi", 0);
}

test "a group that does not exist refuses everything" {
    var chat = testChat();
    defer chat.deinit();

    try testing.expectError(error.NoSuchGroup, chat.post("nope", boss, "hi", 0));
    try testing.expectError(error.NoSuchGroup, chat.add("nope", a, .none));
    try testing.expectError(error.NoSuchGroup, chat.destroy("nope"));
    try testing.expectError(
        error.NoSuchGroup,
        chat.read(testing.allocator, "nope", boss, 0),
    );
}

test "a terminal added without history sees nothing that came before" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    _ = try chat.post("build", boss, "old one", 0);
    _ = try chat.post("build", boss, "old two", 1);

    try chat.add("build", a, .none);
    try testing.expectEqual(@as(usize, 0), chat.unread("build", a));

    const seen = try chat.read(testing.allocator, "build", a, 0);
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 0), seen.len);

    _ = try chat.post("build", boss, "fresh", 2);
    try testing.expectEqual(@as(usize, 1), chat.unread("build", a));
}

test "a terminal added with history sees everything still in the log" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    _ = try chat.post("build", boss, "old one", 0);
    _ = try chat.post("build", boss, "old two", 1);

    try chat.add("build", a, .all);
    try testing.expectEqual(@as(usize, 2), chat.unread("build", a));

    const seen = try chat.read(testing.allocator, "build", a, 0);
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 2), seen.len);
    try testing.expectEqualStrings("old one", seen[0].text);
}

test "adding somebody already in a group leaves their view alone" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none);
    _ = try chat.post("build", boss, "after", 0);

    // A second add with `.all` must not hand them the backlog they were
    // deliberately kept out of.
    try chat.add("build", a, .all);
    try testing.expectEqual(@as(usize, 1), chat.unread("build", a));
}

test "removing a member stops them reading" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all);
    try chat.remove("build", a);

    try testing.expectError(
        error.NotAMember,
        chat.read(testing.allocator, "build", a, 0),
    );
    try testing.expectEqual(@as(usize, 0), chat.unread("build", a));
}

test "a two terminal group is what a direct message used to be" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("boss-and-a", boss);
    try chat.add("boss-and-a", a, .none);
    try chat.create("everyone", boss);
    try chat.add("everyone", a, .none);
    try chat.add("everyone", b, .none);

    _ = try chat.post("boss-and-a", boss, "just between us", 0);

    try testing.expectEqual(@as(usize, 1), chat.unread("boss-and-a", a));
    try testing.expectEqual(@as(usize, 0), chat.unread("everyone", b));
    try testing.expect(!chat.isMember("boss-and-a", b));
}

test "reading marks seen, and a cursor picks up where it left off" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none);
    const first = try chat.post("build", boss, "one", 0);
    _ = try chat.post("build", boss, "two", 1);

    try testing.expectEqual(@as(usize, 2), chat.unread("build", a));

    const rest = try chat.read(testing.allocator, "build", a, first);
    defer testing.allocator.free(rest);
    try testing.expectEqual(@as(usize, 1), rest.len);
    try testing.expectEqualStrings("two", rest[0].text);
    try testing.expectEqual(@as(usize, 0), chat.unread("build", a));
}

test "compacting replaces what it covers with one summary" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all);
    for (0..5) |i| {
        var buf: [8]u8 = undefined;
        _ = try chat.post("build", boss, try std.fmt.bufPrint(&buf, "m{d}", .{i}), i);
    }
    _ = try chat.post("build", boss, "kept", 9);

    const at = try chat.compact("build", 5, "we argued about the build", boss, 10);
    try testing.expectEqual(@as(u64, 5), at);

    const seen = try chat.read(testing.allocator, "build", a, 0);
    defer testing.allocator.free(seen);

    try testing.expectEqual(@as(usize, 2), seen.len);
    try testing.expect(seen[0].summary);
    try testing.expectEqualStrings("we argued about the build", seen[0].text);
    try testing.expect(!seen[1].summary);
    try testing.expectEqualStrings("kept", seen[1].text);
}

test "compacting leaves somebody who had not caught up with the summary" {
    // The point of leaving a summary is that a member behind the cut sees
    // what it stood for rather than a hole.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all);
    for (0..4) |i| {
        var buf: [8]u8 = undefined;
        _ = try chat.post("build", boss, try std.fmt.bufPrint(&buf, "m{d}", .{i}), i);
    }

    _ = try chat.compact("build", 4, "the gist of it", boss, 5);

    const seen = try chat.read(testing.allocator, "build", a, 0);
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 1), seen.len);
    try testing.expectEqualStrings("the gist of it", seen[0].text);
}

test "compacting nothing is refused rather than leaving a stray summary" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    _ = try chat.post("build", boss, "one", 0);

    // Nothing at or below seq 0.
    try testing.expectError(error.Empty, chat.compact("build", 0, "nothing", boss, 1));
    try testing.expectEqual(
        @as(usize, 1),
        chat.groups.getPtr("build").?.log.items.len,
    );
}

test "an empty summary is refused" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    _ = try chat.post("build", boss, "one", 0);
    try testing.expectError(error.Empty, chat.compact("build", 1, "  ", boss, 1));
}

test "compacting shrinks what a later read has to carry" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all);
    for (0..20) |i| {
        var buf: [16]u8 = undefined;
        _ = try chat.post("build", boss, try std.fmt.bufPrint(&buf, "chatter {d}", .{i}), i);
    }

    _ = try chat.compact("build", 20, "twenty lines of chatter", boss, 21);

    const seen = try chat.read(testing.allocator, "build", a, 0);
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 1), seen.len);
}

test "empty messages are refused" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try testing.expectError(error.Empty, chat.post("build", boss, "", 0));
    try testing.expectError(error.Empty, chat.post("build", boss, " \n\t ", 0));
}

test "one message cannot fill a group by itself" {
    var chat: Chat = .init(testing.allocator, .{ .max_text_bytes = 16 });
    defer chat.deinit();

    try chat.create("build", boss);
    _ = try chat.post("build", boss, "x" ** 100, 0);
    try testing.expectEqual(
        @as(usize, 16),
        chat.groups.getPtr("build").?.log.items[0].text.len,
    );
}

test "a group's log is capped and the oldest go first" {
    var chat: Chat = .init(testing.allocator, .{ .max_messages = 3 });
    defer chat.deinit();

    try chat.create("build", boss);
    for (0..5) |i| {
        var buf: [8]u8 = undefined;
        _ = try chat.post("build", boss, try std.fmt.bufPrint(&buf, "m{d}", .{i}), i);
    }

    const log = chat.groups.getPtr("build").?.log.items;
    try testing.expectEqual(@as(usize, 3), log.len);
    try testing.expectEqualStrings("m2", log[0].text);
}

test "there is a limit on how many groups can exist" {
    var chat: Chat = .init(testing.allocator, .{ .max_groups = 2 });
    defer chat.deinit();

    try chat.create("one", boss);
    try chat.create("two", boss);
    try testing.expectError(error.TooManyGroups, chat.create("three", boss));

    try chat.destroy("one");
    try chat.create("three", boss);
}

test "groupsFor lists what a terminal is in, sorted" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("zebra", boss);
    try chat.create("alpha", boss);
    try chat.create("other", boss);
    try chat.add("zebra", a, .none);
    try chat.add("alpha", a, .none);

    const mine = try chat.groupsFor(testing.allocator, a);
    defer testing.allocator.free(mine);

    try testing.expectEqual(@as(usize, 2), mine.len);
    try testing.expectEqualStrings("alpha", mine[0]);
    try testing.expectEqualStrings("zebra", mine[1]);
}

test "unreadTotal counts across every group" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("one", boss);
    try chat.create("two", boss);
    try chat.add("one", a, .none);
    try chat.add("two", a, .none);

    _ = try chat.post("one", boss, "x", 0);
    _ = try chat.post("two", boss, "y", 1);
    _ = try chat.post("two", boss, "z", 2);

    try testing.expectEqual(@as(usize, 3), chat.unreadTotal(a));
}

test "a terminal is never unread to itself" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none);
    _ = try chat.post("build", a, "mine", 0);

    try testing.expectEqual(@as(usize, 0), chat.unread("build", a));
    try testing.expectEqual(@as(usize, 1), chat.unread("build", boss));
}

test "notices are rate limited per group and per terminal" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none);
    _ = try chat.post("build", boss, "one", 0);

    try testing.expect(chat.shouldNotify("build", a, 0, 1000));
    try testing.expect(!chat.shouldNotify("build", a, 500, 1000));

    _ = try chat.post("build", boss, "two", 900);
    try testing.expect(chat.shouldNotify("build", a, 1000, 1000));
}

test "being noisy in one group does not silence another" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("one", boss);
    try chat.create("two", boss);
    try chat.add("one", a, .none);
    try chat.add("two", a, .none);

    _ = try chat.post("one", boss, "x", 0);
    _ = try chat.post("two", boss, "y", 0);

    try testing.expect(chat.shouldNotify("one", a, 0, 60_000));
    try testing.expect(chat.shouldNotify("two", a, 0, 60_000));
}

test "forgetting a terminal takes it out of every group" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("one", boss);
    try chat.create("two", boss);
    try chat.add("one", a, .none);
    try chat.add("two", a, .none);

    chat.forget(a);
    try testing.expect(!chat.isMember("one", a));
    try testing.expect(!chat.isMember("two", a));
}

test "destroying a group takes its messages with it" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    _ = try chat.post("build", boss, "something", 0);
    try chat.destroy("build");

    try testing.expect(!chat.exists("build"));
    try testing.expectError(error.NoSuchGroup, chat.post("build", boss, "again", 1));
}

test "a notice names the group but never quotes it" {
    var buf: [256]u8 = undefined;

    const one = try formatNotice("build", 1, &buf);
    try testing.expect(std.mem.indexOf(u8, one, "1 new message ") != null);
    try testing.expect(std.mem.indexOf(u8, one, "\"build\"") != null);
    try testing.expect(std.mem.indexOf(u8, one, "group_read") != null);

    const many = try formatNotice("build", 4, &buf);
    try testing.expect(std.mem.indexOf(u8, many, "4 new messages") != null);
}
