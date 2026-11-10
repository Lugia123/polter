//! One reading of Polter's own processes (task 2149, handoff §1): which of a
//! terminal's processes are the agent's own, which are an `polter +mcp`
//! sidecar serving it, and which terminal is an embedded group chat.
//!
//! Three things are being told apart, and only the process arguments say
//! which is which (`procargs.zig`): every one of them is called `polter` in
//! the process table.
//!
//!  * **an embedded group chat** -- `polter +chat --group=<g> --embedded`,
//!    run in a surface the control room opened. The pane's *whole tree* is
//!    the group's own, and the group's name is the one it was started with.
//!  * **an MCP sidecar** -- `polter +mcp`, `polter +mcp-slot`, an agent
//!    CLI's child. It is inside the worker pane's tree today, so it is
//!    *subtracted* from the worker's row: counted twice is counted wrong.
//!  * **the main process** -- this program. Not any pane's. It is not in
//!    any pane's tree, so the caller hands it in separately
//!    (`Overall.In.main`); this file only ever sees panes.
//!
//! A pane whose arguments said it is a chat **is** the group's own row even
//! when the group's name could not be read: the two facts are separate
//! fields (`Overall.PaneKind`), because reading an empty name as "not a
//! chat" would put a whole chat's memory on a worker's row.
//!
//! **This file is pure.** The classification is handed in as `Classify`, so
//! the rules above are tested with processes that were never started, and
//! the one thing a test cannot make is a `sysctl` call.

const OverallRead = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const procscan = @import("procscan.zig");
const ledger = @import("ledger.zig");
const procargs = @import("procargs.zig");
const Overall = @import("Overall.zig");

/// What a process's arguments said it is, and the group a chat is for.
pub const Seen = procargs.Seen;

/// Reads one process's arguments. `pid` is what to read and `comm` is the
/// name the process table has for it, so an implementation can skip
/// everything that is not a `polter` without a system call.
pub const Classify = *const fn (ctx: ?*anyopaque, pid: u32, comm: []const u8) Seen;

/// What the process table says a Polter process is called. macOS truncates
/// `p_comm` to 16, which `polter` is well inside.
pub const polter_comm = "polter";

/// The reading, in `alloc`.
///
/// `procs` is one `procscan.scan`; `panes` is what it is split by. **The
/// chat surfaces belong in `panes`**: a chat's pane is the group's own row,
/// and it is left out of the per-terminal reading on purpose, so a caller
/// that wants both passes both lists to this with the chats in it.
///
/// Which pane is a chat is answered by the arguments, not by the caller --
/// that is the whole reason `class` is here rather than a flag on `Pane`.
pub fn build(
    alloc: Allocator,
    procs: []const procscan.Proc,
    panes: []const ledger.Pane,
    class: Classify,
    ctx: ?*anyopaque,
) Allocator.Error![]Overall.PaneReading {
    const out = try alloc.alloc(Overall.PaneReading, panes.len);
    errdefer alloc.free(out);

    // The usage first, with the same rule the rest of the resource feature
    // uses: a process is counted in one pane at most.
    const usage = try ledger.account(alloc, procs, panes);
    defer alloc.free(usage);

    for (panes, out, 0..) |pane, *r, i| {
        r.* = .{
            .id = pane.id,
            .root_pid = pane.root,
            .mem = usage[i].mem,
            .procs = usage[i].procs,
            .cpu_ns = usage[i].cpu_ns,
        };
        // When the pane's own process started: what tells a replaced
        // process from the same one (handoff §4 rule 7).
        for (procs) |p| if (p.pid == pane.root) {
            r.start_ms = p.start_ms;
        };

        // The pane's own processes, so the sidecars can be told out of them.
        const mine = try ledger.members(alloc, procs, panes, i);
        defer alloc.free(mine);

        var is_chat = false;
        var sidecar_mem: u64 = 0;
        var sidecar_procs: u32 = 0;
        var sidecar_cpu_ns: u64 = 0;
        for (mine) |k| {
            const p = procs[k];
            if (!std.mem.eql(u8, p.name(), polter_comm)) continue;
            const seen = class(ctx, p.pid, p.name());
            switch (seen.kind) {
                .chat => {
                    is_chat = true;
                    const g = seen.groupName();
                    const n = @min(g.len, r.group.len);
                    @memcpy(r.group[0..n], g[0..n]);
                    r.group_len = @intCast(n);
                },
                .sidecar => {
                    sidecar_mem += p.footprint;
                    sidecar_procs += 1;
                    // **The sidecar's own CPU is kept apart as well**, so
                    // that the terminal's row can count the two halves back
                    // together and the split costs nothing (task 3113: the
                    // row is the whole tree). Taken apart in this one loop,
                    // so the two cannot drift.
                    sidecar_cpu_ns += p.cpu_ns;
                },
                .other => {},
            }
        }

        // An embedded chat's pane is the group's own, whole -- and it says
        // so even when the group's name could not be read: a chat is a
        // chat, whatever its arguments turned out to be. Everything else
        // keeps its tree, less the sidecars, which get a row of their own
        // rather than being counted inside the worker's.
        r.kind = if (is_chat) .chat else .worker;
        if (!is_chat) {
            r.sidecar_mem = sidecar_mem;
            r.sidecar_procs = sidecar_procs;
            r.sidecar_cpu_ns = sidecar_cpu_ns;
            r.mem -|= sidecar_mem;
            r.procs -|= sidecar_procs;
            r.cpu_ns -|= sidecar_cpu_ns;
        }

        // **The terminal's processes, heaviest first** (task 3113, second
        // round): the table draws them under the terminal's own line, so
        // that a row says what a terminal is *for* rather than what shape
        // of process the core split out of it. The heaviest
        // `Overall.max_children` are kept -- a busy tree can hold dozens --
        // and the row's tree total is summed over all of them, so a short
        // list is a list that left the tail out, never a total that did.
        var kept: [Overall.max_children]Overall.Child = @splat(.{});
        var kept_n: usize = 0;
        for (mine) |k| {
            const p = procs[k];
            const mem_mib: u32 = @intCast(@min(p.footprint >> 20, std.math.maxInt(u32)));
            kept_n = keepHeaviest(&kept, kept_n, Overall.Child.init(p.pid, mem_mib, p.name()));
        }
        r.children = kept;
        r.children_len = @intCast(kept_n);
    }
    return out;
}

/// Put `c` into `buf[0..n]`, which is ordered heaviest first, and answer how
/// many are kept: at most `buf.len`, so a tree with more processes than the
/// row has room for keeps its heaviest ones. Ties go to the older process
/// (the smaller pid), so the order is the same on every reading.
fn keepHeaviest(buf: []Overall.Child, n: usize, c: Overall.Child) usize {
    var at: usize = 0;
    while (at < n) : (at += 1) {
        const held = buf[at];
        if (held.mem_mib > c.mem_mib) continue;
        if (held.mem_mib == c.mem_mib and held.pid <= c.pid) continue;
        break;
    }
    const len = @min(n + 1, buf.len);
    // Smaller than everything kept, and the row is full: not carried.
    if (at >= len) return n;
    var k = len - 1;
    while (k > at) : (k -= 1) buf[k] = buf[k - 1];
    buf[at] = c;
    return len;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn P(pid: u32, ppid: u32, mb: u64, nm: []const u8) procscan.Proc {
    var p: procscan.Proc = .{
        .pid = pid,
        .ppid = ppid,
        .tdev = procscan.no_tty,
        .footprint = mb << 20,
        .comm = @splat(0),
        .comm_len = @intCast(nm.len),
    };
    @memcpy(p.comm[0..nm.len], nm);
    return p;
}

/// Says what each pid is, as `procargs` would have found in its arguments.
/// A `polter` process is a sidecar unless this table names it otherwise.
const Fake = struct {
    chats: []const struct { pid: u32, group: []const u8 } = &.{},

    fn of(ctx: ?*anyopaque, pid: u32, comm: []const u8) Seen {
        const self: *const Fake = @ptrCast(@alignCast(ctx.?));
        if (!std.mem.eql(u8, comm, polter_comm)) return .{ .kind = .other };
        for (self.chats) |c| if (c.pid == pid) {
            var s: Seen = .{ .kind = .chat };
            const n = @min(c.group.len, s.group.len);
            @memcpy(s.group[0..n], c.group[0..n]);
            s.group_len = @intCast(n);
            return s;
        };
        return .{ .kind = .sidecar };
    }
};

test "2149: a chat's pane is the group's own, and a worker's tree loses its sidecar" {
    // 10 login -> 11 zsh -> 12 claude -> {13 polter +mcp, 14 python};
    // 20 login -> 21 zsh -> 22 polter +chat --group=web-app --embedded -> 23 node
    var procs = [_]procscan.Proc{
        P(11, 10, 4, "zsh"),      P(12, 11, 300, "claude"),
        P(13, 12, 200, "polter"), P(14, 12, 1000, "python3.13"),
        P(21, 20, 4, "zsh"),      P(22, 21, 20000, "polter"),
        P(23, 22, 500, "node"),
    };
    // **CPU comes apart with the memory, in the same loop.** The sidecar's
    // own CPU is its own row's; the worker's row keeps its tree less that
    // (task 2149's review, r3 ①). 100 ns per pid, so every sum below can
    // be added up by eye off the pids.
    for (&procs) |*p| p.cpu_ns = p.pid * 100;
    const panes = [_]ledger.Pane{
        .{ .id = 0xa, .root = 10, .tty = null },
        .{ .id = 0xb, .root = 20, .tty = null },
    };
    var fake: Fake = .{ .chats = &.{.{ .pid = 22, .group = "web-app" }} };

    const out = try build(testing.allocator, &procs, &panes, Fake.of, &fake);
    defer testing.allocator.free(out);

    // The chat's pane: the whole tree, and it is the group's own.
    try testing.expectEqualStrings("web-app", out[1].groupName());
    try testing.expectEqual(@as(u64, (4 + 20000 + 500) << 20), out[1].mem);
    try testing.expectEqual(@as(u32, 3), out[1].procs);
    try testing.expectEqual(@as(u32, 0), out[1].sidecar_procs);

    // The worker's: what it holds, less the sidecar, which is its own row.
    try testing.expectEqualStrings("", out[0].groupName());
    try testing.expectEqual(@as(u32, 1), out[0].sidecar_procs);
    try testing.expectEqual(@as(u64, 200 << 20), out[0].sidecar_mem);
    try testing.expectEqual(@as(u64, (4 + 300 + 1000) << 20), out[0].mem);
    try testing.expectEqual(@as(u32, 3), out[0].procs);
    // The sidecar (pid 13, 1300 ns) is taken out of the tree's CPU here, so
    // that the terminal's row can add it back (task 3113); what is left is
    // the rest of the tree (1100 + 1200 + 1400).
    try testing.expectEqual(@as(u64, 1300), out[0].sidecar_cpu_ns);
    try testing.expectEqual(@as(u64, 3700), out[0].cpu_ns);

    // The chat's pane is whole, so nothing is taken off its CPU either --
    // a chat's own MCP server is inside the group's own row, not another's.
    try testing.expectEqual(@as(u64, 0), out[1].sidecar_cpu_ns);
    try testing.expectEqual(@as(u64, 2100 + 2200 + 2300), out[1].cpu_ns);
}

test "2149: a `polter` that is neither a chat nor a sidecar is left where it is" {
    // A `polter` terminal of the person's own: `+chat` without `--embedded`,
    // which is a terminal like any other.
    const procs = [_]procscan.Proc{
        P(11, 10, 4, "zsh"),
        P(12, 11, 900, "claude"),
    };
    const panes = [_]ledger.Pane{.{ .id = 0xa, .root = 10, .tty = null }};
    const None = struct {
        fn of(_: ?*anyopaque, _: u32, _: []const u8) Seen {
            return .{ .kind = .other };
        }
    };
    const out = try build(testing.allocator, &procs, &panes, None.of, null);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out[0].groupName());
    try testing.expectEqual(@as(u32, 0), out[0].sidecar_procs);
    try testing.expectEqual(@as(u64, (4 + 900) << 20), out[0].mem);
}

test "2149: a sidecar with no pane of its own is not taken off the wrong tree" {
    // The sidecar is inside the chat's tree here -- the control room ran the
    // chat, and the chat's own MCP server is a child of it. The chat's row
    // is the whole pane, so nothing is subtracted from it.
    const procs = [_]procscan.Proc{
        P(21, 20, 4, "zsh"),
        P(22, 21, 20000, "polter"),
        P(23, 22, 200, "polter"),
    };
    const panes = [_]ledger.Pane{.{ .id = 0xb, .root = 20, .tty = null }};
    var fake: Fake = .{ .chats = &.{.{ .pid = 22, .group = "docs" }} };
    const out = try build(testing.allocator, &procs, &panes, Fake.of, &fake);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("docs", out[0].groupName());
    try testing.expectEqual(@as(u64, (4 + 20000 + 200) << 20), out[0].mem);
    try testing.expectEqual(@as(u32, 3), out[0].procs);
}

// **The processes under a terminal's line** (task 3113, second round): the
// table draws a terminal as a group with these under it, heaviest first, so
// that a row says what the terminal is *for* -- the agent, the MCP servers
// it started, the build -- rather than one word for a shape of process.
test "3113: a terminal's row carries its processes, heaviest first" {
    // 11 zsh -> 12 claude -> {13 polter +mcp, 14 python3.13}
    const procs = [_]procscan.Proc{
        P(11, 10, 4, "zsh"),
        P(12, 11, 300, "claude"),
        P(13, 12, 200, "polter"),
        P(14, 12, 1000, "python3.13"),
    };
    const panes = [_]ledger.Pane{.{ .id = 0xa, .root = 11, .tty = null }};
    const None = struct {
        fn of(_: ?*anyopaque, _: u32, _: []const u8) Seen {
            return .{ .kind = .other };
        }
    };
    const out = try build(testing.allocator, &procs, &panes, None.of, null);
    defer testing.allocator.free(out);

    const kids = out[0].childrenOf();
    try testing.expectEqual(@as(usize, 4), kids.len);
    // Heaviest first, and the names are the process table's own.
    try testing.expectEqual(@as(u32, 14), kids[0].pid);
    try testing.expectEqualStrings("python3.13", kids[0].nameOf());
    try testing.expectEqual(@as(u32, 1000), kids[0].mem_mib);
    try testing.expectEqual(@as(u32, 12), kids[1].pid);
    try testing.expectEqualStrings("claude", kids[1].nameOf());
    try testing.expectEqual(@as(u32, 13), kids[2].pid);
    try testing.expectEqual(@as(u32, 11), kids[3].pid);
    // The tree's own numbers are still whole: the list is what is drawn
    // under the row, not what the row adds up.
    try testing.expectEqual(@as(u32, 4), out[0].procs);
    try testing.expectEqual(@as(u64, (4 + 300 + 200 + 1000) << 20), out[0].mem);
}

test "3113: a tree with more processes than the row holds keeps its heaviest" {
    // Sixteen processes of 1 MiB to 16 MiB: the twelve heaviest are kept,
    // and the row's own count still says sixteen. A list that silently kept
    // the first twelve would keep the *lightest* ones here, so the two are
    // told apart by which pids came out.
    var procs: [16]procscan.Proc = undefined;
    for (&procs, 0..) |*p, i| p.* = P(@intCast(100 + i), 99, @intCast(i + 1), "proc");
    const panes: [1]ledger.Pane = .{.{ .id = 0xa, .root = 99, .tty = null }};
    // The pane's root is a process too, and the lightest of the seventeen.
    var all: [17]procscan.Proc = undefined;
    all[0] = P(99, 1, 0, "zsh");
    @memcpy(all[1..], &procs);
    const None = struct {
        fn of(_: ?*anyopaque, _: u32, _: []const u8) Seen {
            return .{ .kind = .other };
        }
    };
    const out = try build(testing.allocator, &all, &panes, None.of, null);
    defer testing.allocator.free(out);

    const kids = out[0].childrenOf();
    try testing.expectEqual(Overall.max_children, kids.len);
    // The heaviest is pid 115 (16 MiB) and the twelfth is pid 104 (5 MiB);
    // the four lightest -- pids 100..103 -- did not fit.
    try testing.expectEqual(@as(u32, 115), kids[0].pid);
    try testing.expectEqual(@as(u32, 104), kids[kids.len - 1].pid);
    // The row's count is the tree's own, not the list's length.
    try testing.expectEqual(@as(u32, 17), out[0].procs);
}
