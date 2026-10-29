//! Change watching for one working directory (task 2145 C5, PLAN §1.3).
//!
//! The OS half is `os/dirwatch.zig` (FSEvents, `ReadDirectoryChangesW`); it
//! reports every path that changes, from its own thread. **What counts, and
//! how often anyone is told, is decided here** in plain functions, so both
//! hosts get the same answer and the answer can be tested without a disk:
//!
//! - `isExcluded`: the directories nobody wants to hear about
//!   (`excluded_dirs`, a constant of the core; `.gitignore` is not read).
//!   Case is ignored where the filesystem ignores it by default (macOS,
//!   Windows), so `Target/` and `.GIT` are excluded there;
//! - `relative`: the path as the working directory spells it;
//! - `Throttle`: at most one notification a second, the first at once;
//! - `Pending`: the changed paths since the last notification, once each.
//!
//! `Watch` strings those onto an OS watch. Nothing here opens a window or
//! reaches the app; wiring is for a later slice.
//!
//! **`poll`'s `now_ms` must be a monotonic clock** (the app's elapsed time),
//! never the wall clock: after the wall clock is set back, `Throttle` would
//! see "less than a second" for as long as the step and no notification would
//! come.

const Watch = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const dirwatch = @import("../../os/dirwatch.zig");

/// Directories whose contents are never reported, at any depth.
pub const excluded_dirs = [_][]const u8{
    ".git",
    "node_modules",
    ".zig-cache",
    "zig-out",
    "target",
    ".build",
    "DerivedData",
};

/// The most a notification is held for: one a second.
pub const throttle_ms: i64 = 1000;

/// The most paths kept between two notifications. Past it only `overflowed`
/// is set: "something changed that cannot be listed, look again".
pub const max_pending: usize = 1000;

/// Is `rel` (relative, `/` or `\` separated) in a directory that is not
/// watched, or is it such a directory itself?
pub fn isExcluded(rel: []const u8) bool {
    return isExcludedWith(rel, default_ignore_case);
}

/// Whether names compare without case on this host's default filesystem.
pub const default_ignore_case = builtin.os.tag == .macos or builtin.os.tag == .windows;

pub fn isExcludedWith(rel: []const u8, ignore_case: bool) bool {
    var it = std.mem.tokenizeAny(u8, rel, "/\\");
    while (it.next()) |part| {
        for (excluded_dirs) |ex| {
            const same = if (ignore_case) std.ascii.eqlIgnoreCase(part, ex) else std.mem.eql(u8, part, ex);
            if (same) return true;
        }
    }
    return false;
}

/// `abs` as `root` spells it, or null when `abs` is `root` itself or is not
/// under it (`/a/bc` is not under `/a/b`).
pub fn relative(root: []const u8, abs: []const u8) ?[]const u8 {
    var r = root;
    while (r.len > 1 and (r[r.len - 1] == '/' or r[r.len - 1] == '\\')) r = r[0 .. r.len - 1];
    if (abs.len <= r.len + 1) return null;
    if (!std.mem.startsWith(u8, abs, r)) return null;
    if (abs[r.len] != '/' and abs[r.len] != '\\') return null;
    return abs[r.len + 1 ..];
}

/// At most one `true` per `throttle_ms`; the first is immediate.
pub const Throttle = struct {
    last_ms: ?i64 = null,

    pub fn allow(self: *Throttle, now_ms: i64) bool {
        if (self.last_ms) |l| {
            if (now_ms - l < throttle_ms) return false;
        }
        self.last_ms = now_ms;
        return true;
    }
};

/// Changed paths since the last notification.
pub const Pending = struct {
    alloc: Allocator,
    set: std.StringArrayHashMapUnmanaged(void) = .empty,
    overflowed: bool = false,

    pub fn deinit(self: *Pending) void {
        self.clear();
        self.set.deinit(self.alloc);
    }

    pub fn clear(self: *Pending) void {
        for (self.set.keys()) |k| self.alloc.free(k);
        self.set.clearRetainingCapacity();
        self.overflowed = false;
    }

    pub fn add(self: *Pending, rel: []const u8) Allocator.Error!void {
        if (self.set.contains(rel)) return;
        if (self.set.count() >= max_pending) {
            self.overflowed = true;
            return;
        }
        const k = try self.alloc.dupe(u8, rel);
        errdefer self.alloc.free(k);
        try self.set.put(self.alloc, k, {});
    }
};

/// What a notification carries; owned by the caller (`deinit`).
pub const Batch = struct {
    paths: [][]u8,
    overflowed: bool,

    pub fn deinit(self: *Batch, alloc: Allocator) void {
        for (self.paths) |p| alloc.free(p);
        alloc.free(self.paths);
    }
};

alloc: Allocator,
root: []u8,
lock: std.atomic.Mutex = .unlocked,
pending: Pending,
throttle: Throttle = .{},
handle: ?*dirwatch.Handle = null,

/// `root` must already be real (`Workdirs.Dir.path`): FSEvents reports real
/// paths and `relative` compares spellings.
pub fn start(alloc: Allocator, root: []const u8) !*Watch {
    const self = try alloc.create(Watch);
    errdefer alloc.destroy(self);
    const r = try alloc.dupe(u8, root);
    errdefer alloc.free(r);
    self.* = .{ .alloc = alloc, .root = r, .pending = .{ .alloc = alloc } };
    self.handle = try dirwatch.start(alloc, r, onEvent, self);
    return self;
}

pub fn stop(self: *Watch) void {
    if (self.handle) |h| dirwatch.stop(h); // no callback after this returns
    self.pending.deinit();
    self.alloc.free(self.root);
    self.alloc.destroy(self);
}

fn lockIt(self: *Watch) void {
    while (!self.lock.tryLock()) std.atomic.spinLoopHint();
}

fn onEvent(ctx: ?*anyopaque, ev: dirwatch.Event) void {
    const self: *Watch = @ptrCast(@alignCast(ctx.?));
    const abs = switch (ev) {
        .path => |p| p,
        // Events were lost: no path to name, "look again".
        .overflow => {
            self.lockIt();
            defer self.lock.unlock();
            self.pending.overflowed = true;
            return;
        },
    };
    const rel = relative(self.root, abs) orelse return;
    if (isExcluded(rel)) return;
    self.lockIt();
    defer self.lock.unlock();
    self.pending.add(rel) catch {
        self.pending.overflowed = true;
    };
}

/// The paths changed since the last notification, if there are any and a
/// second has passed since that one. Called from whoever polls.
pub fn poll(self: *Watch, now_ms: i64) Allocator.Error!?Batch {
    self.lockIt();
    defer self.lock.unlock();
    if (self.pending.set.count() == 0 and !self.pending.overflowed) return null;
    if (!self.throttle.allow(now_ms)) return null;
    const keys = self.pending.set.keys();
    const out = try self.alloc.alloc([]u8, keys.len);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |p| self.alloc.free(p);
        self.alloc.free(out);
    }
    for (keys) |k| {
        out[made] = try self.alloc.dupe(u8, k);
        made += 1;
    }
    const over = self.pending.overflowed;
    self.pending.clear();
    return .{ .paths = out, .overflowed = over };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "2569 C5: the excluded directories, at any depth, by whole name" {
    const Case = struct { rel: []const u8, excluded: bool };
    const cases = [_]Case{
        .{ .rel = ".git/HEAD", .excluded = true },
        .{ .rel = "a/node_modules/x/index.js", .excluded = true },
        .{ .rel = ".zig-cache/o/x", .excluded = true },
        .{ .rel = "zig-out/bin/a", .excluded = true },
        .{ .rel = "rust\\target\\debug\\a.exe", .excluded = true },
        .{ .rel = ".build/x", .excluded = true },
        .{ .rel = "App/DerivedData/Logs", .excluded = true },
        .{ .rel = ".git", .excluded = true },
        .{ .rel = "src/main.zig", .excluded = false },
        .{ .rel = ".github/workflows/a.yml", .excluded = false },
        .{ .rel = "targets/a", .excluded = false },
        .{ .rel = "my.git/a", .excluded = false },
        .{ .rel = "", .excluded = false },
    };
    for (cases) |c| try testing.expectEqual(c.excluded, isExcluded(c.rel));
}

test "2569 C5 v2: where the filesystem ignores case so does the exclusion" {
    try testing.expect(isExcludedWith("Target/debug/a", true));
    try testing.expect(isExcludedWith("x/.GIT/HEAD", true));
    try testing.expect(isExcludedWith("NODE_MODULES/a", true));
    try testing.expect(!isExcludedWith("Target/debug/a", false));
    try testing.expect(!isExcludedWith(".GIT/HEAD", false));
    try testing.expect(isExcludedWith(".git/HEAD", false));
    // Either way a name that only contains an excluded one is not it.
    try testing.expect(!isExcludedWith("Targets/a", true));
    try testing.expectEqual(builtin.os.tag == .macos or builtin.os.tag == .windows, default_ignore_case);
}

test "2569 C5: relative names a path under the root and nothing else" {
    try testing.expectEqualStrings("a/b", relative("/w", "/w/a/b").?);
    try testing.expectEqualStrings("a", relative("/w/", "/w/a").?);
    try testing.expectEqualStrings("a\\b", relative("C:\\w", "C:\\w\\a\\b").?);
    try testing.expect(relative("/w", "/w") == null);
    try testing.expect(relative("/w", "/w/") == null);
    try testing.expect(relative("/w", "/wx/a") == null);
    try testing.expect(relative("/w/a", "/w/b/c") == null);
}

test "2569 C5: the throttle lets one through a second, the first at once" {
    var t: Throttle = .{};
    try testing.expect(t.allow(5));
    try testing.expect(!t.allow(500));
    try testing.expect(!t.allow(1004));
    try testing.expect(t.allow(1005));
    try testing.expect(!t.allow(1999));
    try testing.expect(t.allow(2005));
}

test "2569 C5: pending keeps each path once and says when it could not keep them all" {
    var p: Pending = .{ .alloc = testing.allocator };
    defer p.deinit();
    try p.add("a");
    try p.add("a");
    try p.add("b");
    try testing.expectEqual(2, p.set.count());
    var buf: [16]u8 = undefined;
    for (0..max_pending + 3) |i| try p.add(try std.fmt.bufPrint(&buf, "f{d}", .{i}));
    try testing.expectEqual(max_pending, p.set.count());
    try testing.expect(p.overflowed);
    p.clear();
    try testing.expectEqual(0, p.set.count());
    try testing.expect(!p.overflowed);
}

test "2569 C5: poll hands over what changed, filtered, at most once a second" {
    var w: Watch = .{ .alloc = testing.allocator, .root = undefined, .pending = .{ .alloc = testing.allocator } };
    defer w.pending.deinit();
    var root = "/w".*;
    w.root = &root;
    onEvent(&w, .{ .path = "/w/src/a.zig" });
    onEvent(&w, .{ .path = "/w/.git/index" });
    onEvent(&w, .{ .path = "/elsewhere/x" });
    var b1 = (try w.poll(0)).?;
    defer b1.deinit(testing.allocator);
    try testing.expectEqual(1, b1.paths.len);
    try testing.expectEqualStrings("src/a.zig", b1.paths[0]);

    onEvent(&w, .{ .path = "/w/b.txt" });
    try testing.expect((try w.poll(400)) == null);
    var b2 = (try w.poll(1000)).?;
    defer b2.deinit(testing.allocator);
    try testing.expectEqualStrings("b.txt", b2.paths[0]);
    try testing.expect((try w.poll(5000)) == null);
}

test "2569 C5 v2: an overflow from the OS reaches the next notification, with no paths" {
    var w: Watch = .{ .alloc = testing.allocator, .root = undefined, .pending = .{ .alloc = testing.allocator } };
    defer w.pending.deinit();
    var root = "/w".*;
    w.root = &root;
    onEvent(&w, .overflow);
    var b = (try w.poll(0)).?;
    defer b.deinit(testing.allocator);
    try testing.expect(b.overflowed);
    try testing.expectEqual(0, b.paths.len);
    try testing.expect((try w.poll(5000)) == null);
}

test "2569 C5 v2: stopping right after starting is clean and nothing is called afterwards (macOS)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    // Writes land while the watch is being torn down: `stop` has to wait for
    // a callback in flight, or the freed `Watch` is read (the testing
    // allocator and the sanitizer-free build show it as a crash or a leak).
    for (0..30) |i| {
        const w = try Watch.start(testing.allocator, root);
        var buf: [24]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "f{d}.txt", .{i});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "x" });
        w.stop();
    }
}

test "2569 C5: a file written in a real directory is heard within a second (macOS)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "sub");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const w = try Watch.start(testing.allocator, root);
    defer w.stop();
    // FSEvents takes a moment to arm; events before then are not delivered.
    try std.Io.sleep(testing.io, .fromMilliseconds(200), .awake);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/hello.txt", .data = "hi" });

    var heard = false;
    var ms: i64 = 0;
    while (ms <= 1000 and !heard) : (ms += 20) {
        try std.Io.sleep(testing.io, .fromMilliseconds(20), .awake);
        var batch = (try w.poll(ms)) orelse continue;
        defer batch.deinit(testing.allocator);
        for (batch.paths) |p| {
            if (std.mem.eql(u8, p, "sub/hello.txt")) heard = true;
        }
    }
    try testing.expect(heard);
}
