//! Who is editing which file (task 2565 C6a, PLAN §1.5): the lock the
//! editor takes when the person starts to edit, and the one `file_guard`
//! reads to tell an agent's `Write` to wait.
//!
//! **Pure, and the clock is an argument.** Nothing here reads the time, so
//! the lease can be tested to the millisecond and the app decides what "now"
//! is (`App.fileLockNowMs`, the one monotonic clock every call here is
//! given -- a wall clock passed to one call and not another would make a
//! lease read as a negative age).
//!
//! **The key is `(workdir id, real path)`.** The path is the one `Access`
//! answers -- every link followed -- so two spellings of one file are one
//! lock, and a link that leads to a locked file does not walk round it.
//!
//! **One file, one holder.** A second owner asking for a file that is held
//! is told who holds it; the same owner asking again is a renewal.
//!
//! **A lease, not a flag.** The host renews every `renew_ms`; a lock that has
//! not been renewed for `lease_ms` is gone, whether anybody swept it or not
//! -- every question here is asked against the clock it is given, so a lapsed
//! lock is never read as held. That is what keeps a host that crashed from
//! locking a file for ever. **A lapsed lease cannot be renewed**: after 30
//! seconds somebody else may have the file, so the holder has to ask again
//! and is told if it lost.

const Locks = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How often the host renews. The host's number; kept here so the two
/// numbers that must agree (a renewal three times inside a lease) are read
/// together.
pub const renew_ms: i64 = 10_000;
/// How long a lock lives without a renewal.
pub const lease_ms: i64 = 30_000;

pub const Key = struct {
    workdir_id: []const u8,
    /// Real.
    path: []const u8,
};

pub const Holder = struct {
    /// Who holds it, as the host says it (a window id); two asks by the same
    /// owner are the same person.
    owner: u64,
    /// What to call them to an agent: "w2", the person's name.
    name: []const u8,
};

pub const Acquired = union(enum) {
    /// Yours now, or still: the lease is renewed from `now`.
    granted,
    /// Somebody else has it, and their lease is live.
    held: Holder,
};

const Entry = struct {
    workdir_id: []u8,
    path: []u8,
    owner: u64,
    name: []u8,
    renewed_ms: i64,

    fn live(self: Entry, now_ms: i64) bool {
        // A negative age means the clock the caller gave is not the one the
        // lock was stamped with; that reads as lapsed, never as held.
        const age = now_ms - self.renewed_ms;
        return age >= 0 and age < lease_ms;
    }

    fn is(self: Entry, key: Key) bool {
        return std.mem.eql(u8, self.workdir_id, key.workdir_id) and
            std.mem.eql(u8, self.path, key.path);
    }
};

alloc: Allocator,
entries: std.ArrayListUnmanaged(Entry) = .empty,

pub fn init(alloc: Allocator) Locks {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *Locks) void {
    for (self.entries.items) |e| freeEntry(self.alloc, e);
    self.entries.deinit(self.alloc);
}

fn freeEntry(alloc: Allocator, e: Entry) void {
    alloc.free(e.workdir_id);
    alloc.free(e.path);
    alloc.free(e.name);
}

fn find(self: *const Locks, key: Key) ?usize {
    for (self.entries.items, 0..) |e, i| if (e.is(key)) return i;
    return null;
}

/// Take the lock on `key` for `owner`, or say who has it.
pub fn acquire(
    self: *Locks,
    now_ms: i64,
    key: Key,
    owner: u64,
    name: []const u8,
) Allocator.Error!Acquired {
    if (self.find(key)) |i| {
        const e = &self.entries.items[i];
        if (e.live(now_ms) and e.owner != owner)
            return .{ .held = .{ .owner = e.owner, .name = e.name } };
        // Ours again, or a lapsed one: either way it is this owner's now.
        const renamed = try self.alloc.dupe(u8, name);
        self.alloc.free(e.name);
        e.name = renamed;
        e.owner = owner;
        e.renewed_ms = now_ms;
        return .granted;
    }
    const wd = try self.alloc.dupe(u8, key.workdir_id);
    errdefer self.alloc.free(wd);
    const path = try self.alloc.dupe(u8, key.path);
    errdefer self.alloc.free(path);
    const nm = try self.alloc.dupe(u8, name);
    errdefer self.alloc.free(nm);
    try self.entries.append(self.alloc, .{
        .workdir_id = wd,
        .path = path,
        .owner = owner,
        .name = nm,
        .renewed_ms = now_ms,
    });
    return .granted;
}

/// Renew `owner`'s lock on `key`. False when it is not theirs to renew:
/// never taken, taken by somebody else, or lapsed.
pub fn renew(self: *Locks, now_ms: i64, key: Key, owner: u64) bool {
    const i = self.find(key) orelse return false;
    const e = &self.entries.items[i];
    if (e.owner != owner or !e.live(now_ms)) return false;
    e.renewed_ms = now_ms;
    return true;
}

/// Let go. False when `owner` did not hold it; somebody else's lock is not
/// released by asking.
pub fn release(self: *Locks, key: Key, owner: u64) bool {
    const i = self.find(key) orelse return false;
    if (self.entries.items[i].owner != owner) return false;
    freeEntry(self.alloc, self.entries.orderedRemove(i));
    return true;
}

/// Who holds `key` now, or null. A lapsed lease is null, swept or not.
/// The name belongs to the table and is good until the next call that
/// changes it.
pub fn holder(self: *const Locks, now_ms: i64, key: Key) ?Holder {
    const i = self.find(key) orelse return null;
    const e = self.entries.items[i];
    if (!e.live(now_ms)) return null;
    return .{ .owner = e.owner, .name = e.name };
}

/// Drop the lapsed ones; how many went. Memory only: `holder` is right
/// without it.
pub fn sweep(self: *Locks, now_ms: i64) usize {
    var gone: usize = 0;
    var i: usize = 0;
    while (i < self.entries.items.len) {
        if (self.entries.items[i].live(now_ms)) {
            i += 1;
            continue;
        }
        freeEntry(self.alloc, self.entries.orderedRemove(i));
        gone += 1;
    }
    return gone;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const k1: Key = .{ .workdir_id = "00000000000000aa", .path = "/w/a/docs/x.md" };

test "2565 C6: a free file is granted, and its holder is the one who took it" {
    var l: Locks = .init(testing.allocator);
    defer l.deinit();
    try testing.expect(l.holder(0, k1) == null);
    try testing.expectEqual(Acquired.granted, try l.acquire(1000, k1, 7, "w2"));
    const h = l.holder(1000, k1).?;
    try testing.expectEqual(@as(u64, 7), h.owner);
    try testing.expectEqualStrings("w2", h.name);
}

test "2565 C6: one file has one holder, and the second is told who" {
    var l: Locks = .init(testing.allocator);
    defer l.deinit();
    _ = try l.acquire(0, k1, 7, "w2");
    const got = try l.acquire(5000, k1, 8, "w3");
    try testing.expectEqual(@as(u64, 7), got.held.owner);
    try testing.expectEqualStrings("w2", got.held.name);
    // The refusal changed nothing.
    try testing.expectEqual(@as(u64, 7), l.holder(5000, k1).?.owner);
    // The same owner asking again is the renewal, not a refusal.
    try testing.expectEqual(Acquired.granted, try l.acquire(6000, k1, 7, "w2"));
}

test "2565 C6: the key is the workdir and the path together" {
    var l: Locks = .init(testing.allocator);
    defer l.deinit();
    _ = try l.acquire(0, k1, 7, "w2");
    const other_dir: Key = .{ .workdir_id = "00000000000000bb", .path = k1.path };
    const other_file: Key = .{ .workdir_id = k1.workdir_id, .path = "/w/a/docs/y.md" };
    try testing.expect(l.holder(0, other_dir) == null);
    try testing.expect(l.holder(0, other_file) == null);
    try testing.expectEqual(Acquired.granted, try l.acquire(0, other_dir, 8, "w3"));
    try testing.expectEqual(Acquired.granted, try l.acquire(0, other_file, 8, "w3"));
}

test "2565 C6: the lease is 30 seconds from the last renewal, to the millisecond" {
    var l: Locks = .init(testing.allocator);
    defer l.deinit();
    _ = try l.acquire(1000, k1, 7, "w2");
    const Case = struct { at: i64, held: bool };
    const cases = [_]Case{
        .{ .at = 1000, .held = true },
        .{ .at = 1000 + renew_ms, .held = true },
        .{ .at = 1000 + lease_ms - 1, .held = true },
        .{ .at = 1000 + lease_ms, .held = false },
        .{ .at = 1000 + lease_ms + 1, .held = false },
        .{ .at = 1000 + 10 * lease_ms, .held = false },
    };
    for (cases) |c| {
        try testing.expectEqual(c.held, l.holder(c.at, k1) != null);
    }
}

test "2565 C6: a renewal moves the lease, and only the holder's renewal" {
    var l: Locks = .init(testing.allocator);
    defer l.deinit();
    _ = try l.acquire(0, k1, 7, "w2");
    try testing.expect(l.renew(10_000, k1, 7));
    try testing.expect(l.renew(20_000, k1, 7));
    // 20 s + 29.999 s: still held, because the clock restarted at the renewal.
    try testing.expect(l.holder(20_000 + lease_ms - 1, k1) != null);
    // Not theirs to renew.
    try testing.expect(!l.renew(21_000, k1, 8));
    try testing.expect(!l.renew(21_000, .{ .workdir_id = "x", .path = "/y" }, 7));
}

test "2565 C6: a lapsed lease cannot be renewed, and the file can be taken" {
    var l: Locks = .init(testing.allocator);
    defer l.deinit();
    _ = try l.acquire(0, k1, 7, "w2");
    try testing.expect(!l.renew(lease_ms, k1, 7));
    try testing.expectEqual(Acquired.granted, try l.acquire(lease_ms, k1, 8, "w3"));
    try testing.expectEqual(@as(u64, 8), l.holder(lease_ms, k1).?.owner);
    try testing.expectEqualStrings("w3", l.holder(lease_ms, k1).?.name);
    // And the first owner is now the one who is told.
    try testing.expectEqual(@as(u64, 8), (try l.acquire(lease_ms + 1, k1, 7, "w2")).held.owner);
}

test "2565 C6: only the holder releases, and a released file is free" {
    var l: Locks = .init(testing.allocator);
    defer l.deinit();
    _ = try l.acquire(0, k1, 7, "w2");
    try testing.expect(!l.release(k1, 8));
    try testing.expect(l.holder(0, k1) != null);
    try testing.expect(l.release(k1, 7));
    try testing.expect(l.holder(0, k1) == null);
    try testing.expect(!l.release(k1, 7));
    try testing.expectEqual(Acquired.granted, try l.acquire(0, k1, 8, "w3"));
}

test "2565 C6: sweeping drops the lapsed and keeps the live" {
    var l: Locks = .init(testing.allocator);
    defer l.deinit();
    _ = try l.acquire(0, k1, 7, "w2");
    _ = try l.acquire(20_000, .{ .workdir_id = "a", .path = "/b" }, 8, "w3");
    try testing.expectEqual(@as(usize, 0), l.sweep(lease_ms - 1));
    try testing.expectEqual(@as(usize, 1), l.sweep(lease_ms));
    try testing.expectEqual(@as(usize, 1), l.entries.items.len);
    try testing.expect(l.holder(lease_ms, .{ .workdir_id = "a", .path = "/b" }) != null);
}

test "2565 C6: a lock stamped on another clock, in the future of now, is not held" {
    var l: Locks = .init(testing.allocator);
    defer l.deinit();
    const key: Key = .{ .workdir_id = "w", .path = "/w/a" };
    _ = try l.acquire(1_700_000_000_000, key, 1, "w1");
    try testing.expect(l.holder(5_000, key) == null);
    try testing.expect(l.holder(1_700_000_000_000 + 1, key) != null);
}
