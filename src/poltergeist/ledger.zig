//! Which processes are each pane's, and what they add up to (task 1993,
//! #1985): one reading of the machine (`procscan`) split by pane.
//!
//! **A pane's processes are its child and everything under it, plus
//! whatever still has the pane's terminal as its controlling terminal.**
//! - From the child (`/usr/bin/login` on macOS, which this user cannot
//!   read) down by parent link. A process this user cannot read is not in
//!   the reading, but its children name it as their parent all the same,
//!   so the walk starts from the pid, not from a row of the table.
//! - Plus the pane's terminal: a process that double-forked away from its
//!   parent (its parent is now launchd) still has the terminal it was
//!   started on, unless it went as far as `setsid` -- and one that did is
//!   not counted, which is said wherever the readings are shown.
//! - A process is counted in one pane at most: the first that claims it.
//!
//! Pure: a reading and a list of panes in, a usage per pane out, so every
//! rule above is tested here without a process to run.

const std = @import("std");
const Allocator = std.mem.Allocator;
const procscan = @import("procscan.zig");
const Proc = procscan.Proc;

pub const Pane = struct {
    id: u64,
    /// The pane's child (the process the terminal started).
    root: u32,
    /// The pane terminal's device, as `e_tdev` reads it; null when unknown.
    tty: ?u32,
};

pub const Usage = struct {
    id: u64,
    /// Bytes, summed over the pane's processes.
    mem: u64,
    procs: u32,
    /// The name holding the most memory, how many processes have it and
    /// what they hold together: "python3.13 ×7, 160 GB".
    top: [16]u8 = @splat(0),
    top_len: u8 = 0,
    top_count: u32 = 0,
    top_mem: u64 = 0,

    pub fn topName(self: *const Usage) []const u8 {
        return self.top[0..self.top_len];
    }
};

/// Parent → children, by index into `procs`.
const Kids = std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32));

fn kidsOf(alloc: Allocator, procs: []const Proc) Allocator.Error!Kids {
    var kids: Kids = .empty;
    errdefer freeKids(alloc, &kids);
    for (procs, 0..) |p, i| {
        const e = try kids.getOrPut(alloc, p.ppid);
        if (!e.found_existing) e.value_ptr.* = .empty;
        try e.value_ptr.append(alloc, @intCast(i));
    }
    return kids;
}

fn freeKids(alloc: Allocator, kids: *Kids) void {
    var it = kids.valueIterator();
    while (it.next()) |l| l.deinit(alloc);
    kids.deinit(alloc);
}

/// One usage per pane, in the panes' order, in `alloc`.
pub fn account(alloc: Allocator, procs: []const Proc, panes: []const Pane) Allocator.Error![]Usage {
    var kids = try kidsOf(alloc, procs);
    defer freeKids(alloc, &kids);

    const claimed = try alloc.alloc(bool, procs.len);
    defer alloc.free(claimed);
    @memset(claimed, false);

    const out = try alloc.alloc(Usage, panes.len);
    errdefer alloc.free(out);
    var mine: std.ArrayListUnmanaged(u32) = .empty;
    defer mine.deinit(alloc);

    for (panes, out) |pane, *u| {
        mine.clearRetainingCapacity();
        try walk(alloc, procs, &kids, claimed, pane, &mine);
        u.* = .{ .id = pane.id, .mem = 0, .procs = 0 };
        for (mine.items) |i| {
            u.mem += procs[i].footprint;
            u.procs += 1;
        }
        // The name holding the most, summed over every process with it.
        for (mine.items) |i| {
            const nm = procs[i].name();
            var count: u32 = 0;
            var total: u64 = 0;
            for (mine.items) |k| if (std.mem.eql(u8, procs[k].name(), nm)) {
                count += 1;
                total += procs[k].footprint;
            };
            if (total > u.top_mem) {
                u.top_mem = total;
                u.top_count = count;
                u.top_len = @intCast(nm.len);
                @memcpy(u.top[0..nm.len], nm);
            }
        }
    }
    return out;
}

/// The indices into `procs` that are `pane`'s, appended to `mine`: the
/// rules at the top of this file. `claimed` is shared across panes so that
/// a process is counted once.
fn walk(
    alloc: Allocator,
    procs: []const Proc,
    kids: *const Kids,
    claimed: []bool,
    pane: Pane,
    mine: *std.ArrayListUnmanaged(u32),
) Allocator.Error!void {
    var stack: std.ArrayListUnmanaged(u32) = .empty;
    defer stack.deinit(alloc);
    // The tree under the child: walked by pid, so an unreadable child
    // (login) still leads to its readable children.
    try stack.append(alloc, pane.root);
    for (procs, 0..) |p, i| if (p.pid == pane.root and !claimed[i]) {
        claimed[i] = true;
        try mine.append(alloc, @intCast(i));
    };
    while (stack.pop()) |pid| {
        const l = kids.get(pid) orelse continue;
        for (l.items) |i| {
            if (claimed[i]) continue;
            claimed[i] = true;
            try mine.append(alloc, i);
            try stack.append(alloc, procs[i].pid);
        }
    }
    // And whatever still runs on the pane's terminal, with its own tree.
    if (pane.tty) |tty| if (tty != procscan.no_tty) {
        for (procs, 0..) |p, i| {
            if (claimed[i] or p.tdev != tty) continue;
            claimed[i] = true;
            try mine.append(alloc, @intCast(i));
            try stack.append(alloc, p.pid);
            while (stack.pop()) |pid| {
                const l = kids.get(pid) orelse continue;
                for (l.items) |k| {
                    if (claimed[k]) continue;
                    claimed[k] = true;
                    try mine.append(alloc, k);
                    try stack.append(alloc, procs[k].pid);
                }
            }
        }
    };
}

/// What a kill of `pane` stops (task 1993, #1985 §3.2): every one of its
/// processes except the terminal's child and the children of that child
/// -- `login` and the shell it started, on macOS -- so the pane is left at
/// its prompt. Pids, in `alloc`.
///
/// ⚠️ A pane whose child runs the agent with no shell in between (a
/// command given instead of a shell) has the agent at that second level,
/// and it is not stopped: the pane's own process is never killed.
pub fn stoppable(alloc: Allocator, procs: []const Proc, pane: Pane) Allocator.Error![]u32 {
    var kids = try kidsOf(alloc, procs);
    defer freeKids(alloc, &kids);
    const claimed = try alloc.alloc(bool, procs.len);
    defer alloc.free(claimed);
    @memset(claimed, false);
    var mine: std.ArrayListUnmanaged(u32) = .empty;
    defer mine.deinit(alloc);
    try walk(alloc, procs, &kids, claimed, pane, &mine);

    var out: std.ArrayListUnmanaged(u32) = .empty;
    errdefer out.deinit(alloc);
    for (mine.items) |i| {
        const p = procs[i];
        if (p.pid == pane.root or p.ppid == pane.root) continue;
        try out.append(alloc, p.pid);
    }
    return out.toOwnedSlice(alloc);
}

const testing = std.testing;

fn P(pid: u32, ppid: u32, tdev: u32, mb: u64, nm: []const u8) Proc {
    var p: Proc = .{ .pid = pid, .ppid = ppid, .tdev = tdev, .footprint = mb << 20, .comm = @splat(0), .comm_len = @intCast(nm.len) };
    @memcpy(p.comm[0..nm.len], nm);
    return p;
}

test "1993: a pane is its child's tree, found through a parent this user cannot read" {
    // 10 is login (root, not in the reading); 11 its shell; 12 the agent
    // CLI; 13–15 three OCR workers under it. 20 is another pane's.
    const procs = [_]Proc{
        P(11, 10, 3, 4, "zsh"),            P(12, 11, 3, 300, "claude"),
        P(13, 12, 3, 23000, "python3.13"), P(14, 12, 3, 23000, "python3.13"),
        P(15, 12, 3, 23000, "python3.13"), P(21, 20, 4, 5, "zsh"),
    };
    // No terminal given: the tree alone has to find them.
    const panes = [_]Pane{ .{ .id = 0xa, .root = 10, .tty = null }, .{ .id = 0xb, .root = 20, .tty = null } };
    const us = try account(testing.allocator, &procs, &panes);
    defer testing.allocator.free(us);
    try testing.expectEqual(@as(u32, 5), us[0].procs);
    try testing.expectEqual(@as(u64, (4 + 300 + 3 * 23000) << 20), us[0].mem);
    try testing.expectEqualStrings("python3.13", us[0].topName());
    try testing.expectEqual(@as(u32, 3), us[0].top_count);
    try testing.expectEqual(@as(u64, (3 * 23000) << 20), us[0].top_mem);
    // The other pane has its own shell and nothing of the first.
    try testing.expectEqual(@as(u32, 1), us[1].procs);
    try testing.expectEqual(@as(u64, 5 << 20), us[1].mem);
}

test "1993: a process that left its parent is still its terminal's, unless it has no terminal" {
    // 30 double-forked: its parent is launchd now, but it kept tty 3.
    // 31 is its child. 40 detached with setsid: no terminal, not counted.
    const procs = [_]Proc{
        P(11, 10, 3, 4, "zsh"),
        P(30, 1, 3, 800, "node"),
        P(31, 30, procscan.no_tty, 200, "node"),
        P(40, 1, procscan.no_tty, 900, "daemon"),
    };
    const panes = [_]Pane{.{ .id = 0xa, .root = 10, .tty = 3 }};
    const us = try account(testing.allocator, &procs, &panes);
    defer testing.allocator.free(us);
    // zsh, the orphan by its terminal, and the orphan's child by its parent.
    try testing.expectEqual(@as(u32, 3), us[0].procs);
    try testing.expectEqual(@as(u64, (4 + 800 + 200) << 20), us[0].mem);

    // With no terminal known, only the tree.
    const blind = [_]Pane{.{ .id = 0xa, .root = 10, .tty = null }};
    const ub = try account(testing.allocator, &procs, &blind);
    defer testing.allocator.free(ub);
    try testing.expectEqual(@as(u32, 1), ub[0].procs);
}

test "1993: a process is counted in one pane only, and a pane with nothing is zero" {
    // Two panes name the same tree (a stale root): the first claims it.
    const procs = [_]Proc{ P(11, 10, 3, 4, "zsh"), P(12, 11, 3, 100, "vim") };
    const panes = [_]Pane{ .{ .id = 0xa, .root = 10, .tty = 3 }, .{ .id = 0xb, .root = 10, .tty = 3 }, .{ .id = 0xc, .root = 99, .tty = null } };
    const us = try account(testing.allocator, &procs, &panes);
    defer testing.allocator.free(us);
    try testing.expectEqual(@as(u32, 2), us[0].procs);
    try testing.expectEqual(@as(u32, 0), us[1].procs);
    try testing.expectEqual(@as(u64, 0), us[2].mem);
    try testing.expectEqual(@as(usize, 0), us[2].topName().len);
}

test "1993: a kill stops the agent and everything under it, and leaves login and the shell" {
    // 10 login (unreadable); 11 zsh; 12 claude; 13–14 its workers; 30 a
    // double-forked node on the terminal; 21 another pane's.
    const procs = [_]Proc{
        P(11, 10, 3, 4, "zsh"),            P(12, 11, 3, 300, "claude"),
        P(13, 12, 3, 23000, "python3.13"), P(14, 13, 3, 100, "python3.13"),
        P(30, 1, 3, 800, "node"),          P(21, 20, 4, 5, "zsh"),
    };
    const got = try stoppable(testing.allocator, &procs, .{ .id = 0xa, .root = 10, .tty = 3 });
    defer testing.allocator.free(got);
    std.mem.sort(u32, got, {}, std.sort.asc(u32));
    try testing.expectEqualSlices(u32, &.{ 12, 13, 14, 30 }, got);
}
