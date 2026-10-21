//! What each pane in the history was called, and which group it was in
//! (task 2015 Q3): the history grid keeps a row for a pane that has
//! closed, and the history files know it only by its id.
//!
//! `<state>/resources/names.json`: `{"0x…":{"name":"…","group":"…","seen":ms},…}`,
//! rewritten whole when a name or a group changes (`File.keepNames`), read
//! back on the next start. A pane not seen for `ResourceHistory.keep_days`
//! is dropped with the days that could show it.
//!
//! Pure but for what the caller does with `encode`'s bytes.

const ResourceNames = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const History = @import("ResourceHistory.zig");

pub const Entry = struct {
    /// Owned.
    name: []u8,
    /// Owned; empty for none.
    group: []u8,
    seen_ms: i64,
};

entries: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
/// Something changed since `encode` was last asked.
dirty: bool = false,

pub fn deinit(self: *ResourceNames, alloc: Allocator) void {
    var it = self.entries.valueIterator();
    while (it.next()) |e| free(alloc, e.*);
    self.entries.deinit(alloc);
}

fn free(alloc: Allocator, e: Entry) void {
    alloc.free(e.name);
    alloc.free(e.group);
}

/// `pane` is called `name` in `group` at `now_ms`. Only a new name or group
/// makes the file worth writing again; the time alone does not, so a
/// reading every two seconds writes nothing.
pub fn note(self: *ResourceNames, alloc: Allocator, pane: u64, name: []const u8, group: []const u8, now_ms: i64) Allocator.Error!void {
    const gop = try self.entries.getOrPut(alloc, pane);
    if (gop.found_existing) {
        const e = gop.value_ptr;
        // The day matters to the pruning, not the moment.
        e.seen_ms = now_ms;
        if (std.mem.eql(u8, e.name, name) and std.mem.eql(u8, e.group, group)) return;
        const n = try alloc.dupe(u8, name);
        errdefer alloc.free(n);
        const g = try alloc.dupe(u8, group);
        free(alloc, e.*);
        e.* = .{ .name = n, .group = g, .seen_ms = now_ms };
    } else {
        errdefer _ = self.entries.remove(pane);
        const n = try alloc.dupe(u8, name);
        errdefer alloc.free(n);
        gop.value_ptr.* = .{ .name = n, .group = try alloc.dupe(u8, group), .seen_ms = now_ms };
    }
    self.dirty = true;
}

pub fn get(self: *const ResourceNames, pane: u64) ?Entry {
    return self.entries.get(pane);
}

/// A group renamed (`group_stores.Table.resource_names`): its panes' rows
/// follow it to the new name.
pub fn renameGroup(self: *ResourceNames, alloc: Allocator, from: []const u8, to: []const u8) Allocator.Error!void {
    var it = self.entries.valueIterator();
    while (it.next()) |e| {
        if (!std.mem.eql(u8, e.group, from)) continue;
        const g = try alloc.dupe(u8, to);
        alloc.free(e.group);
        e.group = g;
        self.dirty = true;
    }
}

/// A group deleted: its panes are no one's, and their rows are drawn in no
/// group's grid.
pub fn dropGroup(self: *ResourceNames, alloc: Allocator, group: []const u8) void {
    var it = self.entries.iterator();
    while (it.next()) |kv| {
        if (!std.mem.eql(u8, kv.value_ptr.group, group)) continue;
        free(alloc, kv.value_ptr.*);
        self.entries.removeByPtr(kv.key_ptr);
        self.dirty = true;
    }
}

/// Forget panes not seen for longer than the history is kept.
pub fn prune(self: *ResourceNames, alloc: Allocator, now_ms: i64) void {
    const keep: i64 = @as(i64, History.keep_days) * 24 * 3600 * 1000;
    var it = self.entries.iterator();
    while (it.next()) |kv| {
        if (now_ms - kv.value_ptr.seen_ms <= keep) continue;
        free(alloc, kv.value_ptr.*);
        self.entries.removeByPtr(kv.key_ptr);
        self.dirty = true;
    }
}

/// The file's bytes, in `alloc`.
pub fn encode(self: *ResourceNames, alloc: Allocator) Allocator.Error![]u8 {
    self.dirty = false;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    // Sorted, so the same names make the same file.
    const keys = try alloc.alloc(u64, self.entries.count());
    defer alloc.free(keys);
    var it = self.entries.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) keys[i] = k.*;
    std.mem.sort(u64, keys, {}, std.sort.asc(u64));
    w.writeByte('{') catch return error.OutOfMemory;
    for (keys, 0..) |k, n| {
        const e = self.entries.get(k).?;
        if (n > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.print("\"0x{x}\":", .{k}) catch return error.OutOfMemory;
        std.json.Stringify.value(.{ .name = e.name, .group = e.group, .seen = e.seen_ms }, .{}, w) catch return error.OutOfMemory;
    }
    w.writeAll("}\n") catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Read `bytes` back. What does not parse is left out: a pane with no name
/// is a row the grid does not draw, not a reason to start without the rest.
pub fn decode(alloc: Allocator, bytes: []const u8) Allocator.Error!ResourceNames {
    var self: ResourceNames = .{};
    errdefer self.deinit(alloc);
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const Rec = struct { name: []const u8 = "", group: []const u8 = "", seen: i64 = 0 };
    const v = std.json.parseFromSliceLeaky(std.json.ArrayHashMap(Rec), arena.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return self,
    };
    var it = v.map.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        if (!std.mem.startsWith(u8, key, "0x")) continue;
        const pane = std.fmt.parseUnsigned(u64, key[2..], 16) catch continue;
        const r = kv.value_ptr.*;
        if (r.name.len == 0) continue;
        try self.note(alloc, pane, r.name, r.group, r.seen);
    }
    self.dirty = false;
    return self;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "2015: a closed pane's name and group outlive it, written only when they change" {
    var n: ResourceNames = .{};
    defer n.deinit(testing.allocator);
    try n.note(testing.allocator, 0xdead, "ocr-mask", "web-app", 1000);
    try testing.expect(n.dirty);
    const first = try n.encode(testing.allocator);
    defer testing.allocator.free(first);
    try testing.expect(!n.dirty);
    // The same, later: nothing to write.
    try n.note(testing.allocator, 0xdead, "ocr-mask", "web-app", 9000);
    try testing.expect(!n.dirty);
    // A new title: something to write.
    try n.note(testing.allocator, 0xdead, "ocr-mask-2", "web-app", 9000);
    try testing.expect(n.dirty);

    // Back from the file as it was written the first time.
    var back = try decode(testing.allocator, first);
    defer back.deinit(testing.allocator);
    const e = back.get(0xdead).?;
    try testing.expectEqualStrings("ocr-mask", e.name);
    try testing.expectEqualStrings("web-app", e.group);
    try testing.expectEqual(@as(i64, 1000), e.seen_ms);
    try testing.expect(!back.dirty);
}

test "2015: a renamed group takes its panes' names with it, and a deleted one drops them" {
    var n: ResourceNames = .{};
    defer n.deinit(testing.allocator);
    try n.note(testing.allocator, 1, "ocr-mask", "web-app", 0);
    try n.note(testing.allocator, 2, "api", "billing", 0);
    testing.allocator.free(try n.encode(testing.allocator));
    try n.renameGroup(testing.allocator, "web-app", "shop");
    try testing.expectEqualStrings("shop", n.get(1).?.group);
    try testing.expectEqualStrings("billing", n.get(2).?.group);
    try testing.expect(n.dirty);
    n.dropGroup(testing.allocator, "billing");
    try testing.expect(n.get(2) == null);
    try testing.expect(n.get(1) != null);
}

test "2015: names not seen for longer than the history is kept are dropped, and a broken file is no names" {
    var n: ResourceNames = .{};
    defer n.deinit(testing.allocator);
    const day: i64 = 24 * 3600 * 1000;
    try n.note(testing.allocator, 1, "old", "g", 0);
    try n.note(testing.allocator, 2, "new", "g", 7 * day);
    testing.allocator.free(try n.encode(testing.allocator));
    n.prune(testing.allocator, 8 * day);
    try testing.expect(n.get(1) == null);
    try testing.expect(n.get(2) != null);
    try testing.expect(n.dirty);

    var broken = try decode(testing.allocator, "{\"0x1\":{\"name\":\"a\"");
    defer broken.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), broken.entries.count());
}
