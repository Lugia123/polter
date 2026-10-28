//! Who a terminal was before the restart, going by the agent session it
//! runs (task 1978).
//!
//! A terminal's id is drawn afresh every run, so after a restart every
//! task on the panel is under an id nothing answers to, and a `--resume`d
//! agent asking to move its own task is told it is not its own. The agent
//! is the same one: it says so with the session id its hooks carry, and
//! `TerminalMeta` wrote down which session each terminal ran last. That is
//! a fact the agent states, not a judgement about which pane on screen is
//! which -- which is why this is done by Polter and not left to the
//! supervisor.
//!
//! Built once at startup from what is on disk, before any terminal of this
//! run has said anything. Each old terminal is filed under the **last**
//! session it ran: a terminal that went on to another session is no longer
//! the first one's. A session is claimed once, by the first live terminal
//! to say it, and is then gone from here, so a second `--resume` of the
//! same session in another pane takes nothing.

const Reclaim = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const TerminalMeta = @import("TerminalMeta.zig");
const SessionLog = @import("SessionLog.zig");

alloc: Allocator,

/// `<cli> NUL <session id>` -> the old terminals whose last session it
/// was. Keys and lists owned.
by_session: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u64)) = .empty,

/// An old terminal -> the groups it was in and never said it left. Names
/// and lists owned.
groups: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged([]const u8)) = .empty,

/// Out of each old terminal's notes and the groups' membership record.
/// What is read is copied; both inputs may be freed after.
pub fn build(
    alloc: Allocator,
    notes: []const TerminalMeta.Note,
    stints: []const SessionLog.Stint,
) Allocator.Error!Reclaim {
    var self: Reclaim = .{ .alloc = alloc };
    errdefer self.deinit();

    // Each terminal's last agent note. `TerminalMeta.read` gives each
    // terminal's lines in the order written; the clock decides between
    // them all the same, so the order of the files does not matter.
    var last: std.AutoHashMapUnmanaged(u64, TerminalMeta.Note) = .empty;
    defer last.deinit(alloc);
    for (notes) |n| {
        if (n.kind != .agent or n.session_id.len == 0) continue;
        const gop = try last.getOrPut(alloc, n.terminal);
        if (!gop.found_existing or n.at_ms >= gop.value_ptr.at_ms) gop.value_ptr.* = n;
    }

    var it = last.iterator();
    while (it.next()) |kv| {
        const key = try keyOf(alloc, kv.value_ptr.cli, kv.value_ptr.session_id);
        const gop = self.by_session.getOrPut(alloc, key) catch |err| {
            alloc.free(key);
            return err;
        };
        if (gop.found_existing) alloc.free(key) else gop.value_ptr.* = .empty;
        try gop.value_ptr.append(alloc, kv.key_ptr.*);
    }

    for (stints) |s| {
        if (s.to_ms != null) continue;
        if (!last.contains(s.terminal)) continue;
        const gop = try self.groups.getOrPut(alloc, s.terminal);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        if (contains(gop.value_ptr.items, s.group)) continue;
        const name = try alloc.dupe(u8, s.group);
        gop.value_ptr.append(alloc, name) catch |err| {
            alloc.free(name);
            return err;
        };
    }
    return self;
}

pub fn deinit(self: *Reclaim) void {
    var it = self.by_session.iterator();
    while (it.next()) |kv| {
        self.alloc.free(kv.key_ptr.*);
        kv.value_ptr.deinit(self.alloc);
    }
    self.by_session.deinit(self.alloc);
    var g = self.groups.valueIterator();
    while (g.next()) |list| {
        for (list.items) |name| self.alloc.free(name);
        list.deinit(self.alloc);
    }
    self.groups.deinit(self.alloc);
    self.* = undefined;
}

/// A group renamed while its old members are still to be claimed: they go
/// back into it under its new name.
pub fn renameGroup(self: *Reclaim, from: []const u8, to: []const u8) Allocator.Error!void {
    var it = self.groups.valueIterator();
    while (it.next()) |list| for (list.items) |*name| {
        if (!std.mem.eql(u8, name.*, from)) continue;
        const owned = try self.alloc.dupe(u8, to);
        self.alloc.free(name.*);
        name.* = owned;
    };
}

/// A group deleted: nobody goes back into it.
pub fn dropGroup(self: *Reclaim, name: []const u8) void {
    var it = self.groups.valueIterator();
    while (it.next()) |list| {
        var i: usize = 0;
        while (i < list.items.len) {
            if (std.mem.eql(u8, list.items[i], name)) {
                self.alloc.free(list.orderedRemove(i));
            } else i += 1;
        }
    }
}

/// What a terminal saying a session takes up. Belongs to the allocator
/// passed to `claim`.
pub const Claimed = struct {
    /// The old terminals it is. Empty: nothing to take up.
    terminals: []const u64,
    /// The groups they were in, each once, in the order first met.
    groups: []const []const u8,
};

/// `claimer` says it runs `cli`'s `session_id`. The old terminals whose
/// last session that was, and their groups -- once: the session is gone
/// from here after this, whoever says it next.
///
/// An old terminal that is still live (`live`) is left alone: it is
/// itself, not something to be taken up.
pub fn claim(
    self: *Reclaim,
    alloc: Allocator,
    claimer: u64,
    cli: []const u8,
    session_id: []const u8,
    live: []const u64,
) Allocator.Error!Claimed {
    const none: Claimed = .{ .terminals = &.{}, .groups = &.{} };
    if (session_id.len == 0) return none;
    var buf: [512]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const key = keyOf(fba.allocator(), cli, session_id) catch return none;
    var kv = self.by_session.fetchRemove(key) orelse return none;
    defer {
        self.alloc.free(kv.key);
        kv.value.deinit(self.alloc);
    }

    var terminals: std.ArrayListUnmanaged(u64) = .empty;
    var groups: std.ArrayListUnmanaged([]const u8) = .empty;
    for (kv.value.items) |old| {
        if (old == claimer or std.mem.indexOfScalar(u64, live, old) != null) continue;
        try terminals.append(alloc, old);
        const in = self.groups.get(old) orelse continue;
        for (in.items) |name| {
            if (contains(groups.items, name)) continue;
            try groups.append(alloc, try alloc.dupe(u8, name));
        }
    }
    std.mem.sort(u64, terminals.items, {}, std.sort.asc(u64));
    return .{
        .terminals = try terminals.toOwnedSlice(alloc),
        .groups = try groups.toOwnedSlice(alloc),
    };
}

/// A task taken up, and the group it is filed under.
pub const Task = struct { id: u64, group: []const u8 };

/// The groups to say it in: each one gone back into, then each one a task
/// taken up is filed under, each once. Strings borrowed from the inputs.
pub fn groupsToTell(alloc: Allocator, rejoined: []const []const u8, tasks: []const Task) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (rejoined) |g| if (!contains(out.items, g)) try out.append(alloc, g);
    for (tasks) |t| if (!contains(out.items, t.group)) try out.append(alloc, t.group);
    return out.toOwnedSlice(alloc);
}

pub const Notice = struct {
    /// The terminal that is back.
    id: u64,
    /// `<cli> <first 8 of the session id>`: `TaskLog.viaText`.
    via: []const u8,
    /// The terminals it was.
    was: []const u64,
    /// The group this is said in.
    group: []const u8,
    /// Every task taken up; only this group's are named.
    tasks: []const Task,
    /// Whether it went back into this group.
    rejoined: bool,
};

/// What is said in a group when a terminal is taken to be one of before:
/// which session says so, and what of this group's it has again.
pub fn notice(w: *std.Io.Writer, n: Notice) std.Io.Writer.Error!void {
    try w.print("0x{x:0>16} is back after a restart as the same agent session ({s}) that ran in", .{ n.id, n.via });
    for (n.was, 0..) |old, i| try w.print("{s} 0x{x:0>16}", .{ if (i > 0) "," else "", old });
    try w.writeAll(".");
    var any = false;
    for (n.tasks) |t| {
        if (!std.mem.eql(u8, t.group, n.group)) continue;
        try w.print("{s} #{d}", .{ if (any) "," else " Its again:", t.id });
        any = true;
    }
    if (any) try w.writeAll(".");
    if (n.rejoined) try w.writeAll(" Back in this group.");
}

fn keyOf(alloc: Allocator, cli: []const u8, session_id: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ cli, session_id });
}

pub fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

const testing = std.testing;

fn note(terminal: u64, at_ms: i64, session_id: []const u8) TerminalMeta.Note {
    return .{ .terminal = terminal, .at_ms = at_ms, .kind = .agent, .cli = "claude-code", .session_id = session_id };
}

fn stint(group: []const u8, terminal: u64, to_ms: ?i64) SessionLog.Stint {
    return .{ .group = group, .terminal = terminal, .from_ms = 1, .to_ms = to_ms, .role = "", .cli = "", .inferred = false };
}

test "1978: a session said again is the terminal that ran it last, with the groups it never left" {
    var r = try build(testing.allocator, &.{
        note(0xa, 10, "s-1"),
        .{ .terminal = 0xa, .at_ms = 11, .kind = .role, .role = "polter-dev" },
        note(0xb, 10, "s-2"),
    }, &.{
        stint("build", 0xa, null),
        stint("ops", 0xa, 50), // left
        stint("build", 0xa, null), // joined twice: named once
        stint("review", 0xa, null),
    });
    defer r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try r.claim(arena.allocator(), 0x100, "claude-code", "s-1", &.{0x100});
    try testing.expectEqualSlices(u64, &.{0xa}, got.terminals);
    try testing.expectEqual(@as(usize, 2), got.groups.len);
    try testing.expectEqualStrings("build", got.groups[0]);
    try testing.expectEqualStrings("review", got.groups[1]);
}

test "2084: a session taken back twice, the second time by hand with no hooks, is found where it ran last" {
    const Identities = @import("Identities.zig");
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-reclaim-{x}", .{&raw});
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        alloc.free(dir);
    }

    // The first run: 0xa, started through Polter, says its session by hook.
    {
        var m = try TerminalMeta.open(alloc, io, dir);
        defer m.deinit();
        try testing.expect(m.agent(0xa, 10, "claude-code", "s-1", "/x/s-1.jsonl"));
    }
    // The second: `claude --resume s-1` typed into 0xb, which no hook
    // reaches. Its adapter says the session; this is all that writes it.
    {
        var m = try TerminalMeta.open(alloc, io, dir);
        defer m.deinit();
        const view: Identities.View = .{
            .state = .known,
            .key = "claude-code",
            .label = "Claude Code",
            .identified = .{ .me = true, .session = "s-1", .session_written_ms = null, .quit = null },
        };
        if (Identities.sessionToNote(view, false)) |said| _ = m.agent(0xb, 20, said.cli, said.session, "");
    }

    // The third: 0xc says s-1. 0xb is where it ran last, and 0xb's groups
    // are the ones it goes back into.
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const notes = try TerminalMeta.read(arena.allocator(), io, dir);
    var r = try build(alloc, notes, &.{ stint("old", 0xa, 15), stint("build", 0xb, null) });
    defer r.deinit();
    const got = try r.claim(arena.allocator(), 0xc, "claude-code", "s-1", &.{0xc});
    const ran_last = std.mem.indexOfScalar(u64, got.terminals, 0xb) != null;
    try testing.expect(ran_last);
    try testing.expectEqual(@as(usize, 1), got.groups.len);
    try testing.expectEqualStrings("build", got.groups[0]);
}

test "1978: a group renamed or deleted before the claim is gone back into by its new name, or not at all" {
    var r = try build(testing.allocator, &.{note(0xa, 10, "s-1")}, &.{
        stint("build", 0xa, null),
        stint("ops", 0xa, null),
        stint("review", 0xa, null),
    });
    defer r.deinit();
    try r.renameGroup("build", "web");
    r.dropGroup("ops");

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try r.claim(arena.allocator(), 0x100, "claude-code", "s-1", &.{});
    try testing.expectEqual(@as(usize, 2), got.groups.len);
    try testing.expectEqualStrings("web", got.groups[0]);
    try testing.expectEqualStrings("review", got.groups[1]);
}

test "1978: the same session in two live terminals goes to the first to say it" {
    var r = try build(testing.allocator, &.{note(0xa, 10, "s-1")}, &.{stint("build", 0xa, null)});
    defer r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const first = try r.claim(arena.allocator(), 0x100, "claude-code", "s-1", &.{ 0x100, 0x200 });
    try testing.expectEqualSlices(u64, &.{0xa}, first.terminals);
    const second = try r.claim(arena.allocator(), 0x200, "claude-code", "s-1", &.{ 0x100, 0x200 });
    try testing.expectEqual(@as(usize, 0), second.terminals.len);
    try testing.expectEqual(@as(usize, 0), second.groups.len);
}

test "1978: an old terminal that is still live is left alone" {
    var r = try build(testing.allocator, &.{note(0xa, 10, "s-1")}, &.{stint("build", 0xa, null)});
    defer r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try r.claim(arena.allocator(), 0x100, "claude-code", "s-1", &.{ 0x100, 0xa });
    try testing.expectEqual(@as(usize, 0), got.terminals.len);
    try testing.expectEqual(@as(usize, 0), got.groups.len);
}

test "1978: a session that does not match takes nothing" {
    var r = try build(testing.allocator, &.{
        note(0xa, 10, "s-1"),
        // 0xa went on to s-2: s-1 is no longer it.
        note(0xa, 20, "s-2"),
    }, &.{stint("build", 0xa, null)});
    defer r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), (try r.claim(a, 0x100, "claude-code", "s-3", &.{})).terminals.len);
    try testing.expectEqual(@as(usize, 0), (try r.claim(a, 0x100, "claude-code", "s-1", &.{})).terminals.len);
    // The same id from another CLI is another session.
    try testing.expectEqual(@as(usize, 0), (try r.claim(a, 0x100, "codex", "s-2", &.{})).terminals.len);
    try testing.expectEqual(@as(usize, 0), (try r.claim(a, 0x100, "claude-code", "", &.{})).terminals.len);
    try testing.expectEqualSlices(u64, &.{0xa}, (try r.claim(a, 0x100, "claude-code", "s-2", &.{})).terminals);
}

test "1978: a session two old terminals ended on is both of them" {
    // Resumed once already in a run that had no way to take it up.
    var r = try build(testing.allocator, &.{ note(0xb, 20, "s-1"), note(0xa, 10, "s-1") }, &.{
        stint("build", 0xa, null),
        stint("build", 0xb, null),
        stint("ops", 0xb, null),
    });
    defer r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try r.claim(arena.allocator(), 0x100, "claude-code", "s-1", &.{});
    try testing.expectEqualSlices(u64, &.{ 0xa, 0xb }, got.terminals);
    try testing.expectEqual(@as(usize, 2), got.groups.len);
}

test "1978: the notice names the session, the old terminals, and this group's tasks only" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const tasks = [_]Task{ .{ .id = 21, .group = "build" }, .{ .id = 34, .group = "ops" }, .{ .id = 55, .group = "build" } };
    try notice(&w, .{ .id = 0x100, .via = "claude-code 55a835df", .was = &.{ 0xa, 0xb }, .group = "build", .tasks = &tasks, .rejoined = true });
    try testing.expectEqualStrings(
        "0x0000000000000100 is back after a restart as the same agent session (claude-code 55a835df) that ran in 0x000000000000000a, 0x000000000000000b. Its again: #21, #55. Back in this group.",
        w.buffered(),
    );

    var buf2: [512]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    try notice(&w2, .{ .id = 0x100, .via = "codex 01a1468a", .was = &.{0xa}, .group = "review", .tasks = &tasks, .rejoined = true });
    try testing.expectEqualStrings(
        "0x0000000000000100 is back after a restart as the same agent session (codex 01a1468a) that ran in 0x000000000000000a. Back in this group.",
        w2.buffered(),
    );
}

test "1978: told in each group gone back into, then each group a task is under, once each" {
    const tasks = [_]Task{ .{ .id = 1, .group = "ops" }, .{ .id = 2, .group = "build" }, .{ .id = 3, .group = "ops" } };
    const got = try groupsToTell(testing.allocator, &.{ "build", "review" }, &tasks);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("build", got[0]);
    try testing.expectEqualStrings("review", got[1]);
    try testing.expectEqualStrings("ops", got[2]);
}

test "Reclaim: 重启后同 session 回到原位，alias 与牵头不变" {
    const Tasks = @import("Tasks.zig");
    var r = try build(testing.allocator, &.{ note(0xa, 10, "s-1"), note(0xb, 10, "s-2") }, &.{});
    defer r.deinit();

    var tasks: Tasks = .init(testing.allocator, .{});
    defer tasks.deinit();
    const id = try tasks.create("build", "squad work", .feature);
    try tasks.setSquad(id, "trio");
    try tasks.addSlot(id, "dev", "worker-dev");
    try tasks.addSlot(id, "test", "worker-test");
    try tasks.join(id, "dev", "", 0xa, "", 5, true);
    try tasks.join(id, "test", "", 0xb, "", 5, false);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // The agent that ran the lead's seat says its session, in a new terminal.
    const got = try r.claim(arena.allocator(), 0x100, "claude-code", "s-1", &.{0x100});
    try testing.expectEqualSlices(u64, &.{0xa}, got.terminals);
    var moved: std.ArrayListUnmanaged(Tasks.TaskId) = .empty;
    defer moved.deinit(testing.allocator);
    var gone: std.ArrayListUnmanaged(Tasks.Gone) = .empty;
    defer gone.deinit(testing.allocator);
    for (got.terminals) |old| try tasks.reown(testing.allocator, old, 0x100, "claude-code s-1", 777, &moved, &gone);
    try testing.expectEqualSlices(Tasks.TaskId, &.{id}, moved.items);

    const t = tasks.get(id).?;
    // The same seat, under the same alias, filled by the new terminal.
    try testing.expectEqualStrings("dev", t.members[0].alias);
    try testing.expectEqual(@as(u64, 0x100), t.members[0].id);
    try testing.expectEqual(Tasks.Slot.filled, t.members[0].slot);
    try testing.expectEqual(@as(u64, 0x100), t.owner);
    // The other seat is not touched, and nobody else moved into it.
    try testing.expectEqual(@as(u64, 0xb), t.members[1].id);
    // The stretch followed: the old terminal's ended, the new one's is open.
    var open_for_new = false;
    for (t.spans) |sp| {
        if (sp.to_ms == null and sp.id == 0x100 and std.mem.eql(u8, sp.alias, "dev")) {
            open_for_new = true;
            // Begun when the caller said it was, not at zero.
            try testing.expectEqual(@as(i64, 777), sp.from_ms);
        }
        try testing.expect(!(sp.to_ms == null and sp.id == 0xa));
        // And the old terminal's ended then.
        if (sp.id == 0xa) try testing.expectEqual(@as(?i64, 777), sp.to_ms);
    }
    try testing.expect(open_for_new);
}

test "squad: 认回按 session 核对，别的 session 的座位被腾空而不是指向死终端" {
    const Tasks = @import("Tasks.zig");
    var tasks: Tasks = .init(testing.allocator, .{});
    defer tasks.deinit();
    const id = try tasks.create("build", "squad work", .feature);
    try tasks.setSquad(id, "trio");
    try tasks.addSlot(id, "dev", "worker-dev");
    try tasks.addSlot(id, "test", "worker-test");
    try tasks.join(id, "dev", "", 0xa, "claude-code s-1", 5, true);
    try tasks.join(id, "test", "", 0xa2, "claude-code s-2", 5, false);

    var moved: std.ArrayListUnmanaged(Tasks.TaskId) = .empty;
    defer moved.deinit(testing.allocator);
    var gone: std.ArrayListUnmanaged(Tasks.Gone) = .empty;
    defer gone.deinit(testing.allocator);
    // Terminal 0xa came back as session s-9: neither seat it held was s-9's.
    try tasks.reown(testing.allocator, 0xa, 0x100, "claude-code s-9", 777, &moved, &gone);
    try testing.expectEqual(@as(usize, 0), moved.items.len);
    try testing.expectEqual(@as(usize, 1), gone.items.len);
    try testing.expectEqualStrings("dev", gone.items[0].alias);
    const t = tasks.get(id).?;
    try testing.expectEqual(Tasks.Slot.vacated, t.members[0].slot);
    try testing.expectEqual(Tasks.nobody, t.owner);
    // The seat of another terminal is untouched.
    try testing.expectEqual(@as(u64, 0xa2), t.members[1].id);

    // And its own session is taken back, as before.
    try tasks.join(id, "dev", "", 0xb, "claude-code s-1", 8, true);
    moved.clearRetainingCapacity();
    gone.clearRetainingCapacity();
    try tasks.reown(testing.allocator, 0xb, 0x101, "claude-code s-1", 900, &moved, &gone);
    try testing.expectEqualSlices(Tasks.TaskId, &.{id}, moved.items);
    try testing.expectEqual(@as(usize, 0), gone.items.len);
    try testing.expectEqual(@as(u64, 0x101), tasks.get(id).?.members[0].id);
}
