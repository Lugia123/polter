//! What a host holds to read and edit one file of a workdir: a ticket (task
//! 2573 C7, `polter-artifacts/2145/PLAN.md` §1.2 "宿主怎么拿字节" and "写只有一条路").
//!
//! **The host reads the bytes itself** (a video wants ranges, a big file is
//! streamed), so the core hands out a *capability* instead: `open` checks the
//! file with `Access`, and answers a `token` that nobody can guess. The token
//! is bound to one workdir and one scope. Every time the host is about to read
//! it comes back to `resolve`, which judges the path against **this ticket's**
//! scope again and answers the real path -- or a refusal. The host reads only
//! the path it was given.
//!
//! **Writing is `propose` then `commit`**, on `Write`. A proposal is kept here
//! (the core's, not the host's) and is named by an id that is as unguessable
//! as the token, because it is what a write is done with.
//!
//! **Outside, missing, a token that never was, and a token that was closed are
//! all one answer**, `refused`, for the reason `Access` gives: whether
//! something exists is not the asker's business. The reason is in the log.
//!
//! **A ticket does not live for ever.** `close` ends one; and there are never
//! more than `max_tickets` -- a host that forgot to close loses the oldest,
//! which is then a ticket that was closed. A ticket keeps at most
//! `max_proposals` proposals, the oldest dropped the same way.
//!
//! Not an agent's tool and not for plugins: only a host asks (see `rpc.zig`).

const Tickets = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Access = @import("Access.zig");
const Text = @import("Text.zig");
const Write = @import("Write.zig");
const Merge = @import("Merge.zig");

const log = std.log.scoped(.poltergeist);

pub const max_tickets: usize = 64;
pub const max_proposals: usize = 4;

/// The workdir a ticket is made for, as the app knows it.
pub const Workdir = struct {
    /// Real.
    path: []const u8,
    /// `Workdirs.Dir.readable` was false.
    too_wide: bool,
};

pub const Refusal = enum {
    /// A token or a proposal id that is not (or no longer) held.
    no_ticket,
    /// The workdir id names nothing.
    no_workdir,
    /// `Access` said no; the reason is `Access.Refusal`.
    access,
    /// The ticket is not for a file that can be edited.
    not_editable,
    /// `base_version` is not the version the ticket was opened on.
    stale_base,
};

const Entry = struct {
    arena: std.heap.ArenaAllocator,
    token: [32]u8,
    workdir: []const u8,
    too_wide: bool,
    scope: Access.Scope,
    /// Real: the file the ticket was made for.
    anchor: []const u8,
    /// Set for a text file that may be edited.
    base: ?Write.Disk,
    proposals: std.ArrayListUnmanaged(Held) = .empty,
};

const Held = struct {
    id: [32]u8,
    arena: std.heap.ArenaAllocator,
    proposal: Write.Proposal,
};

gpa: Allocator,
io: Io,
entries: std.ArrayListUnmanaged(*Entry) = .empty,

pub fn init(gpa: Allocator, io: Io) Tickets {
    return .{ .gpa = gpa, .io = io };
}

pub fn deinit(self: *Tickets) void {
    while (self.entries.items.len > 0) self.drop(0);
    self.entries.deinit(self.gpa);
}

/// How many tickets are held.
pub fn count(self: *const Tickets) usize {
    return self.entries.items.len;
}

fn drop(self: *Tickets, i: usize) void {
    const e = self.entries.orderedRemove(i);
    for (e.proposals.items) |*h| h.arena.deinit();
    e.proposals.deinit(self.gpa);
    var arena = e.arena;
    arena.deinit();
    self.gpa.destroy(e);
}

fn newId(self: *Tickets) [32]u8 {
    var raw: [16]u8 = undefined;
    self.io.random(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

fn find(self: *Tickets, token: []const u8) ?*Entry {
    for (self.entries.items) |e| if (std.mem.eql(u8, &e.token, token)) return e;
    return null;
}

// -------------------------------------------------------------- the answers

/// An answer is JSON text in the caller's arena. A success has no `refused`
/// key; a refusal has nothing but `refused` and `why`.
fn refused(arena: Allocator, r: Refusal, why: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"refused\":\"{s}\",\"why\":{f}}}", .{ @tagName(r), std.json.fmt(why, .{}) });
}

fn refusedAccess(arena: Allocator, a: Access.Refusal) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"refused\":\"access\",\"reason\":\"{s}\",\"why\":{f}}}", .{
        @tagName(a), std.json.fmt(a.say(), .{}),
    });
}

fn noTicket(arena: Allocator) Allocator.Error![]const u8 {
    return refused(arena, .no_ticket, "there is no such ticket");
}

fn versionText(arena: Allocator, v: Write.Version) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{d}:{d}:{x}", .{ v.size, v.mtime_ns, &v.sha256 });
}

fn sameVersion(arena: Allocator, v: Write.Version, text: []const u8) Allocator.Error!bool {
    return std.mem.eql(u8, try versionText(arena, v), text);
}

// -------------------------------------------------------------------- open

/// `path`: absolute, or relative to the workdir. `scope` is what *later*
/// `resolve` calls on this ticket may reach; the file itself is always
/// checked against the whole workdir.
pub fn open(
    self: *Tickets,
    arena: Allocator,
    wd: Workdir,
    path: []const u8,
    scope: Access.Scope,
) Allocator.Error![]const u8 {
    const verdict = try Access.resolve(arena, self.io, .{
        .workdir = wd.path,
        .path = path,
        .scope = .workdir,
        .too_wide = wd.too_wide,
    });
    const real = switch (verdict) {
        .ok => |r| r,
        .refuse => |a| return refusedAccess(arena, a),
    };

    const e = try self.gpa.create(Entry);
    e.* = .{
        .arena = .init(self.gpa),
        .token = self.newId(),
        .workdir = undefined,
        .too_wide = wd.too_wide,
        .scope = scope,
        .anchor = undefined,
        .base = null,
    };
    errdefer {
        e.arena.deinit();
        self.gpa.destroy(e);
    }
    const ea = e.arena.allocator();
    e.workdir = try ea.dupe(u8, wd.path);
    e.anchor = try ea.dupe(u8, real.path);

    // What the file is: a sample, as `Text` takes it.
    var info: ?Text.Info = null;
    var not_editable: ?[]const u8 = null;
    if (real.kind == .file) {
        const sample = readSample(arena, self.io, real.path) catch null;
        if (sample) |bytes| {
            const i = Text.sniff(bytes, real.size);
            info = i;
            if (Text.notEditable(std.fs.path.basename(real.path), real.size, i)) |why| {
                not_editable = why.say();
            } else switch (try Write.begin(ea, self.io, .{ .workdir = e.workdir, .too_wide = wd.too_wide }, real.path)) {
                .ok => |d| e.base = d,
                .failed => |f| not_editable = f.say(),
            }
        } else not_editable = "it could not be read";
    } else not_editable = "it is a directory";

    try self.entries.append(self.gpa, e);
    errdefer _ = self.entries.pop();
    // The cap: the oldest goes, and is then a ticket that was closed.
    while (self.entries.items.len > max_tickets) self.drop(0);

    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print("{{\"token\":\"{s}\",\"info\":{{\"name\":{f},\"kind\":\"{s}\",\"size\":{d},\"mtime_ns\":\"{d}\",", .{
        &e.token,
        std.json.fmt(std.fs.path.basename(real.path), .{}),
        @tagName(real.kind),
        real.size,
        real.mtime_ns,
    }) catch return error.OutOfMemory;
    if (info) |i| {
        w.print("\"encoding\":\"{s}\",\"eol\":\"{s}\",", .{ @tagName(i.encoding), @tagName(i.eol) }) catch return error.OutOfMemory;
    } else w.writeAll("\"encoding\":null,\"eol\":null,") catch return error.OutOfMemory;
    w.print("\"editable\":{},\"not_editable\":", .{e.base != null}) catch return error.OutOfMemory;
    if (not_editable) |n| w.print("{f}", .{std.json.fmt(n, .{})}) catch return error.OutOfMemory else w.writeAll("null") catch return error.OutOfMemory;
    w.writeAll(",\"version\":") catch return error.OutOfMemory;
    if (e.base) |b| w.print("{f}", .{std.json.fmt(try versionText(arena, b.version), .{})}) catch return error.OutOfMemory else w.writeAll("null") catch return error.OutOfMemory;
    w.writeAll("}}") catch return error.OutOfMemory;
    return out.written();
}

fn readSample(arena: Allocator, io: Io, path: []const u8) !?[]const u8 {
    var f = try Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const buf = try arena.alloc(u8, Text.sample_len);
    const n = try f.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

// ----------------------------------------------------------------- resolve

/// `rel`: relative to the directory of the ticket's file (an `<img src>` in a
/// markdown file), or absolute; empty is the file itself. Judged against this
/// ticket's scope **every time**.
pub fn resolve(self: *Tickets, arena: Allocator, token: []const u8, rel: []const u8) Allocator.Error![]const u8 {
    const e = self.find(token) orelse {
        log.debug("files: resolve on a ticket not held", .{});
        return noTicket(arena);
    };
    const path = if (rel.len == 0)
        e.anchor
    else if (std.fs.path.isAbsolute(rel))
        rel
    else
        try std.fs.path.join(arena, &.{ std.fs.path.dirname(e.anchor) orelse e.workdir, rel });
    const verdict = try Access.resolve(arena, self.io, .{
        .workdir = e.workdir,
        .path = path,
        .scope = e.scope,
        .anchor = e.anchor,
        .too_wide = e.too_wide,
    });
    switch (verdict) {
        .refuse => |a| return refusedAccess(arena, a),
        .ok => |r| return std.fmt.allocPrint(arena, "{{\"path\":{f},\"kind\":\"{s}\",\"size\":{d},\"mtime_ns\":\"{d}\"}}", .{
            std.json.fmt(r.path, .{}), @tagName(r.kind), r.size, r.mtime_ns,
        }),
    }
}

// ------------------------------------------------------------------- close

/// Ends the ticket and every proposal made on it. Closing one that is not
/// held is not an error: the answer is the same.
pub fn close(self: *Tickets, arena: Allocator, token: []const u8) Allocator.Error![]const u8 {
    for (self.entries.items, 0..) |e, i| if (std.mem.eql(u8, &e.token, token)) {
        self.drop(i);
        break;
    };
    return arena.dupe(u8, "{\"closed\":true}");
}

// ----------------------------------------------------------------- propose

pub fn propose(
    self: *Tickets,
    arena: Allocator,
    token: []const u8,
    full_text: []const u8,
    base_version: []const u8,
) Allocator.Error![]const u8 {
    const e = self.find(token) orelse return noTicket(arena);
    const base = e.base orelse return refused(arena, .not_editable, "this file cannot be edited");
    if (!try sameVersion(arena, base.version, base_version))
        return refused(arena, .stale_base, "the file was opened on another version than this one");

    var pa: std.heap.ArenaAllocator = .init(self.gpa);
    errdefer pa.deinit();
    const a = pa.allocator();
    // Kept past this call, so it is the proposal's own memory.
    const mine = try a.dupe(u8, full_text);
    const target: Write.Target = .{ .workdir = e.workdir, .too_wide = e.too_wide };
    switch (try Write.propose(a, self.io, target, base, mine)) {
        .failed => |f| {
            pa.deinit();
            return failedJson(arena, f);
        },
        .ok => |p| return self.keep(arena, e, pa, p),
    }
}

fn keep(self: *Tickets, arena: Allocator, e: *Entry, pa: std.heap.ArenaAllocator, p: Write.Proposal) Allocator.Error![]const u8 {
    const id = self.newId();
    try e.proposals.append(self.gpa, .{ .id = id, .arena = pa, .proposal = p });
    while (e.proposals.items.len > max_proposals) {
        var old = e.proposals.orderedRemove(0);
        old.arena.deinit();
    }
    return proposalJson(arena, &id, p);
}

fn proposalJson(arena: Allocator, id: []const u8, p: Write.Proposal) Allocator.Error![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    proposalWrite(w, id, p) catch return error.OutOfMemory;
    return out.written();
}

fn proposalWrite(w: *Io.Writer, id: []const u8, p: Write.Proposal) Io.Writer.Error!void {
    try w.print("{{\"proposal_id\":\"{s}\",\"disk_changed\":{},\"conflicts\":{d},\"whole_file\":{},\"segments\":[", .{
        id, p.disk_changed, p.merged.conflicts, p.merged.whole_file,
    });
    for (p.merged.segments, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"kind\":\"{s}\"", .{@tagName(s.kind)});
        inline for (.{ "base", "mine", "theirs" }) |side| {
            try w.print(",\"{s}\":[", .{side});
            for (@field(s, side), 0..) |line, j| {
                if (j > 0) try w.writeAll(",");
                try w.print("{f}", .{std.json.fmt(line, .{})});
            }
            try w.writeAll("]");
        }
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

fn failedJson(arena: Allocator, f: Write.Failure) Allocator.Error![]const u8 {
    const kind: []const u8 = switch (f) {
        .gone => "gone",
        .refuse => "refuse",
        .not_editable => "not_editable",
        .mixed_eol => "mixed_eol",
        .unreadable => "unreadable",
        .write_failed => "write_failed",
    };
    return std.fmt.allocPrint(arena, "{{\"status\":\"failed\",\"failure\":\"{s}\",\"why\":{f}}}", .{
        kind, std.json.fmt(f.say(), .{}),
    });
}

// ------------------------------------------------------------------ commit

/// `choices`: one per conflict, as `Merge.assemble` wants them.
/// `restore_gone`: the user chose to put back a file that has gone.
pub fn commit(
    self: *Tickets,
    arena: Allocator,
    proposal_id: []const u8,
    choices: []const Merge.Choice,
    restore_gone: bool,
) Allocator.Error![]const u8 {
    var found: ?struct { e: *Entry, i: usize } = null;
    for (self.entries.items) |e| for (e.proposals.items, 0..) |h, i| {
        if (std.mem.eql(u8, &h.id, proposal_id)) found = .{ .e = e, .i = i };
    };
    const at = found orelse return noTicket(arena);
    const e = at.e;
    const held = &e.proposals.items[at.i];
    const target: Write.Target = .{ .workdir = e.workdir, .too_wide = e.too_wide };

    // **The work is done in the proposal's own arena.** What comes back when
    // the disk has moved is a new proposal built from this one's `base` and
    // `mine`, which are slices of it: the arena cannot be freed until the
    // new proposal is. It is kept for the new one, and grows by what one more
    // round of merging costs.
    const outcome = Write.commit(held.arena.allocator(), self.io, target, held.proposal, choices, .{ .restore_gone = restore_gone }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The choices do not fit the conflicts: the proposal is as it was.
        else => return std.fmt.allocPrint(arena, "{{\"status\":\"bad_choices\",\"why\":{f}}}", .{std.json.fmt(@errorName(err), .{})}),
    };
    switch (outcome) {
        .failed => |f| return failedJson(arena, f),
        .ok => |c| switch (c) {
            .written => |v| {
                // The proposal is spent. What the file is now is the new base.
                var spent = e.proposals.orderedRemove(at.i);
                spent.arena.deinit();
                self.rebase(e);
                return std.fmt.allocPrint(arena, "{{\"status\":\"written\",\"version\":{f}}}", .{
                    std.json.fmt(try versionText(arena, v), .{}),
                });
            },
            .changed => |p| {
                // Nothing was written: the proposal now stands against the
                // disk as it is, under another id (the old one is spent).
                held.proposal = p;
                held.id = self.newId();
                const body = try proposalJson(arena, &held.id, p);
                return std.fmt.allocPrint(arena, "{{\"status\":\"changed\",\"proposal\":{s}}}", .{body});
            },
        },
    }
}

/// After a write the ticket's base is the file as it now is, so the next
/// `propose` is against it. If it cannot be read the ticket is no longer
/// editable and the host opens the file again.
fn rebase(self: *Tickets, e: *Entry) void {
    const target: Write.Target = .{ .workdir = e.workdir, .too_wide = e.too_wide };
    const old = e.base orelse return;
    const ea = e.arena.allocator();
    e.base = switch (Write.begin(ea, self.io, target, old.path) catch null orelse return) {
        .ok => |d| d,
        .failed => null,
    };
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

fn tokenOf(v: std.json.Value) []const u8 {
    return v.object.get("token").?.string;
}

const Fixture = struct {
    tmp: testing.TmpDir,
    /// `<tmp>/w`, real.
    work: [:0]u8,
    arena: std.heap.ArenaAllocator,
    t: Tickets,

    fn init() !Fixture {
        var f: Fixture = .{
            .tmp = testing.tmpDir(.{}),
            .work = undefined,
            .arena = .init(testing.allocator),
            .t = .init(testing.allocator, testing.io),
        };
        errdefer f.tmp.cleanup();
        try f.tmp.dir.createDirPath(testing.io, "w/sub");
        try f.tmp.dir.createDirPath(testing.io, "other");
        f.work = try f.tmp.dir.realPathFileAlloc(testing.io, "w", testing.allocator);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
        testing.allocator.free(f.work);
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn a(f: *Fixture) Allocator {
        return f.arena.allocator();
    }

    fn wd(f: *Fixture) Workdir {
        return .{ .path = f.work, .too_wide = false };
    }

    fn put(f: *Fixture, sub: []const u8, data: []const u8) !void {
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = data });
    }

    fn get(f: *Fixture, sub: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(testing.io, sub, f.a(), .limited(1 << 24));
    }

    fn parse(f: *Fixture, text: []const u8) !std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, f.a(), text, .{});
    }

    /// Opens and returns the parsed answer.
    fn open(f: *Fixture, path: []const u8, scope: Access.Scope) !std.json.Value {
        return f.parse(try f.t.open(f.a(), f.wd(), path, scope));
    }

    fn isRefused(f: *Fixture, text: []const u8) !bool {
        const v = try f.parse(text);
        return v.object.get("refused") != null;
    }
};

test "2573 C7: a ticket for a text file says what it is, and that it can be edited" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/a.md", "one\ntwo\n");
    const v = try f.open("a.md", .file);
    const info = v.object.get("info").?.object;
    try testing.expectEqualStrings("a.md", info.get("name").?.string);
    try testing.expectEqualStrings("file", info.get("kind").?.string);
    try testing.expectEqual(@as(i64, 8), info.get("size").?.integer);
    try testing.expectEqualStrings("utf8", info.get("encoding").?.string);
    try testing.expectEqualStrings("lf", info.get("eol").?.string);
    try testing.expect(info.get("editable").?.bool);
    try testing.expect(info.get("not_editable").? == .null);
    try testing.expectEqual(@as(usize, 32), tokenOf(v).len);
    try testing.expectEqual(@as(usize, 1), f.t.count());
}

test "2573 C7: a file that cannot be edited says why, and has no version to propose against" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/bin.dat", "ab\x00cd");
    try f.put("w/sheet.xlsx", "PK");
    for ([_]struct { name: []const u8, why: []const u8 }{
        .{ .name = "bin.dat", .why = "it is not text" },
        .{ .name = "sheet.xlsx", .why = "it is a document format that is not safe to edit as text" },
    }) |c| {
        const v = try f.open(c.name, .file);
        const info = v.object.get("info").?.object;
        try testing.expect(!info.get("editable").?.bool);
        try testing.expectEqualStrings(c.why, info.get("not_editable").?.string);
        try testing.expect(info.get("version").? == .null);
        const p = try f.t.propose(f.a(), tokenOf(v), "x", "whatever");
        try testing.expect(try f.isRefused(p));
    }
}

test "2573 C7: opening a path outside the workdir, or one that is not there, is refused alike" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("other/secret.txt", "s");
    try f.put("w/real.txt", "r");
    try f.tmp.dir.symLink(testing.io, "../other/secret.txt", "w/leak.txt", .{});
    const cases = [_][]const u8{
        "../other/secret.txt", "nothing-here.txt", "leak.txt", "sub/../../other/secret.txt", "",
    };
    var first: ?[]const u8 = null;
    for (cases) |c| {
        const text = try f.t.open(f.a(), f.wd(), c, .file);
        const v = try f.parse(text);
        try testing.expect(v.object.get("refused") != null);
        try testing.expect(v.object.get("token") == null);
        if (first == null) first = v.object.get("reason").?.string else if (c.len > 0)
            try testing.expectEqualStrings(first.?, v.object.get("reason").?.string);
    }
    try testing.expectEqual(@as(usize, 0), f.t.count());
}

test "2573 C7: a workdir that is too wide to read refuses every open" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/a.txt", "a");
    const text = try f.t.open(f.a(), .{ .path = f.work, .too_wide = true }, "a.txt", .workdir);
    try testing.expect(try f.isRefused(text));
    try testing.expectEqual(@as(usize, 0), f.t.count());
}

test "2573 C7: resolve with scope file reaches the file and nothing beside it" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/a.md", "a");
    try f.put("w/b.md", "b");
    try f.put("w/sub/c.md", "c");
    const v = try f.open("a.md", .file);
    const t = tokenOf(v);
    // The file itself: empty, its own name, its absolute spelling.
    for ([_][]const u8{ "", "a.md", "./a.md", "sub/../a.md" }) |rel| {
        const r = try f.parse(try f.t.resolve(f.a(), t, rel));
        try testing.expect(r.object.get("refused") == null);
        try testing.expect(std.mem.endsWith(u8, r.object.get("path").?.string, "a.md"));
    }
    // A sibling, one down, one up, outside, absent: all refused.
    for ([_][]const u8{ "b.md", "sub/c.md", "../w/b.md", "../other", "nothing.md", "/etc/passwd" }) |rel| {
        try testing.expect(try f.isRefused(try f.t.resolve(f.a(), t, rel)));
    }
}

test "2573 C7: resolve with scope siblings reaches the directory of the file and not the next one" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/a.md", "a");
    try f.put("w/b.png", "b");
    try f.put("w/sub/c.md", "c");
    const t = tokenOf(try f.open("a.md", .siblings));
    const ok = try f.parse(try f.t.resolve(f.a(), t, "b.png"));
    try testing.expect(ok.object.get("refused") == null);
    for ([_][]const u8{ "sub/c.md", "../other/x", "../w/sub/c.md" }) |rel| {
        try testing.expect(try f.isRefused(try f.t.resolve(f.a(), t, rel)));
    }
}

test "2573 C7: resolve with scope workdir reaches the workdir and not what is above it" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/a.md", "a");
    try f.put("w/sub/c.md", "c");
    try f.put("other/x.md", "x");
    const t = tokenOf(try f.open("a.md", .workdir));
    const ok = try f.parse(try f.t.resolve(f.a(), t, "sub/c.md"));
    try testing.expect(ok.object.get("refused") == null);
    try testing.expect(try f.isRefused(try f.t.resolve(f.a(), t, "../other/x.md")));
}

test "2573 C7: a link inside the workdir that leads out of it is refused by resolve" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/a.md", "a");
    try f.put("other/secret.txt", "s");
    try f.tmp.dir.symLink(testing.io, "../other/secret.txt", "w/leak.txt", .{});
    const t = tokenOf(try f.open("a.md", .workdir));
    try testing.expect(try f.isRefused(try f.t.resolve(f.a(), t, "leak.txt")));
}

test "2573 C7: a token that was never issued, and one that was closed, are refused" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/a.md", "a");
    const t = tokenOf(try f.open("a.md", .file));
    try testing.expect(!try f.isRefused(try f.t.resolve(f.a(), t, "")));
    try testing.expect(try f.isRefused(try f.t.resolve(f.a(), "0" ** 32, "")));
    try testing.expect(try f.isRefused(try f.t.resolve(f.a(), "", "")));

    _ = try f.t.close(f.a(), t);
    try testing.expectEqual(@as(usize, 0), f.t.count());
    try testing.expect(try f.isRefused(try f.t.resolve(f.a(), t, "")));
    try testing.expect(try f.isRefused(try f.t.propose(f.a(), t, "x", "v")));
    // Closing again, or closing a token that never was, changes nothing.
    _ = try f.t.close(f.a(), t);
    _ = try f.t.close(f.a(), "nope");
}

test "2573 C7: two tickets for one file are two tokens, and closing one leaves the other" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/a.md", "a");
    const t1 = tokenOf(try f.open("a.md", .file));
    const t2 = tokenOf(try f.open("a.md", .file));
    try testing.expect(!std.mem.eql(u8, t1, t2));
    _ = try f.t.close(f.a(), t1);
    try testing.expect(!try f.isRefused(try f.t.resolve(f.a(), t2, "")));
}

test "2573 C7: a host that never closes loses its oldest tickets, not the machine's memory" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/a.md", "a");
    const first = tokenOf(try f.open("a.md", .file));
    var i: usize = 0;
    while (i < max_tickets + 10) : (i += 1) _ = try f.t.open(f.a(), f.wd(), "a.md", .file);
    try testing.expectEqual(max_tickets, f.t.count());
    try testing.expect(try f.isRefused(try f.t.resolve(f.a(), first, "")));
}

test "2573 C7: propose then commit writes the file, and the next propose is against what was written" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/a.md", "one\ntwo\nthree\n");
    const v = try f.open("a.md", .file);
    const t = tokenOf(v);
    const ver = v.object.get("info").?.object.get("version").?.string;

    const p = try f.parse(try f.t.propose(f.a(), t, "one\n2\nthree\n", ver));
    try testing.expect(p.object.get("refused") == null);
    try testing.expect(!p.object.get("disk_changed").?.bool);
    try testing.expectEqual(@as(i64, 0), p.object.get("conflicts").?.integer);
    // Nothing is written by proposing.
    try testing.expectEqualStrings("one\ntwo\nthree\n", try f.get("w/a.md"));

    const c = try f.parse(try f.t.commit(f.a(), p.object.get("proposal_id").?.string, &.{}, false));
    try testing.expectEqualStrings("written", c.object.get("status").?.string);
    try testing.expectEqualStrings("one\n2\nthree\n", try f.get("w/a.md"));

    // The old version is no longer the base; the one written is.
    try testing.expect(try f.isRefused(try f.t.propose(f.a(), t, "x\n", ver)));
    const now = c.object.get("version").?.string;
    const p2 = try f.parse(try f.t.propose(f.a(), t, "one\n2\n3\n", now));
    try testing.expect(p2.object.get("refused") == null);
}

test "2573 C7: a proposal id is spent by its commit" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/a.md", "a\n");
    const v = try f.open("a.md", .file);
    const ver = v.object.get("info").?.object.get("version").?.string;
    const p = try f.parse(try f.t.propose(f.a(), tokenOf(v), "b\n", ver));
    const id = p.object.get("proposal_id").?.string;
    _ = try f.t.commit(f.a(), id, &.{}, false);
    try testing.expect(try f.isRefused(try f.t.commit(f.a(), id, &.{}, false)));
    try testing.expect(try f.isRefused(try f.t.commit(f.a(), "0" ** 32, &.{}, false)));
}

test "2573 C7: closing the ticket drops its proposals, so they can no longer write" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/a.md", "a\n");
    const v = try f.open("a.md", .file);
    const ver = v.object.get("info").?.object.get("version").?.string;
    const p = try f.parse(try f.t.propose(f.a(), tokenOf(v), "b\n", ver));
    _ = try f.t.close(f.a(), tokenOf(v));
    try testing.expect(try f.isRefused(try f.t.commit(f.a(), p.object.get("proposal_id").?.string, &.{}, false)));
    try testing.expectEqualStrings("a\n", try f.get("w/a.md"));
}

test "2573 C7: the disk changing before commit comes back as a new proposal, and nothing is written" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/a.md", "one\ntwo\nthree\n");
    const v = try f.open("a.md", .file);
    const ver = v.object.get("info").?.object.get("version").?.string;
    const p = try f.parse(try f.t.propose(f.a(), tokenOf(v), "ONE\ntwo\nthree\n", ver));
    try f.put("w/a.md", "one\ntwo\nTHREE!\n");
    const c = try f.parse(try f.t.commit(f.a(), p.object.get("proposal_id").?.string, &.{}, false));
    try testing.expectEqualStrings("changed", c.object.get("status").?.string);
    try testing.expectEqualStrings("one\ntwo\nTHREE!\n", try f.get("w/a.md"));
    const np = c.object.get("proposal").?.object;
    try testing.expect(np.get("disk_changed").?.bool);
    // The new one commits, and is another id.
    const id2 = np.get("proposal_id").?.string;
    try testing.expect(!std.mem.eql(u8, id2, p.object.get("proposal_id").?.string));
    const c2 = try f.parse(try f.t.commit(f.a(), id2, &.{}, false));
    try testing.expectEqualStrings("written", c2.object.get("status").?.string);
    try testing.expectEqualStrings("ONE\ntwo\nTHREE!\n", try f.get("w/a.md"));
}

test "2573 C7: a file that has gone is not put back unless the user chose to" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/a.md", "a\n");
    const v = try f.open("a.md", .file);
    const ver = v.object.get("info").?.object.get("version").?.string;
    const p = try f.parse(try f.t.propose(f.a(), tokenOf(v), "b\n", ver));
    const id = p.object.get("proposal_id").?.string;
    try f.tmp.dir.deleteFile(testing.io, "w/a.md");
    const gone = try f.parse(try f.t.commit(f.a(), id, &.{}, false));
    try testing.expectEqualStrings("gone", gone.object.get("failure").?.string);
    try testing.expectError(error.FileNotFound, f.get("w/a.md"));
    const back = try f.parse(try f.t.commit(f.a(), id, &.{}, true));
    try testing.expectEqualStrings("written", back.object.get("status").?.string);
    try testing.expectEqualStrings("b\n", try f.get("w/a.md"));
}

test "2573 C7: choices that do not fit the conflicts leave the proposal where it was" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/a.md", "one\ntwo\nthree\n");
    const v = try f.open("a.md", .file);
    const ver = v.object.get("info").?.object.get("version").?.string;
    const p = try f.parse(try f.t.propose(f.a(), tokenOf(v), "ONE\ntwo\nthree\n", ver));
    try f.put("w/a.md", "uno\ntwo\nthree\n");
    // Both sides moved line one: the table has one conflict, and none is given.
    const c = try f.parse(try f.t.commit(f.a(), p.object.get("proposal_id").?.string, &.{}, false));
    try testing.expectEqualStrings("changed", c.object.get("status").?.string);
    const id2 = c.object.get("proposal").?.object.get("proposal_id").?.string;
    try testing.expectEqual(@as(i64, 1), c.object.get("proposal").?.object.get("conflicts").?.integer);
    const bad = try f.parse(try f.t.commit(f.a(), id2, &.{}, false));
    try testing.expectEqualStrings("bad_choices", bad.object.get("status").?.string);
    try testing.expectEqualStrings("uno\ntwo\nthree\n", try f.get("w/a.md"));
    const good = try f.parse(try f.t.commit(f.a(), id2, &.{.use_mine}, false));
    try testing.expectEqualStrings("written", good.object.get("status").?.string);
    try testing.expectEqualStrings("ONE\ntwo\nthree\n", try f.get("w/a.md"));
}

test "2573 C7: a ticket keeps a few proposals, and the oldest stops working" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.put("w/a.md", "a\n");
    const v = try f.open("a.md", .file);
    const ver = v.object.get("info").?.object.get("version").?.string;
    var first: []const u8 = "";
    var i: usize = 0;
    while (i < max_proposals + 2) : (i += 1) {
        const p = try f.parse(try f.t.propose(f.a(), tokenOf(v), "b\n", ver));
        if (i == 0) first = p.object.get("proposal_id").?.string;
    }
    try testing.expect(try f.isRefused(try f.t.commit(f.a(), first, &.{}, false)));
    try testing.expectEqualStrings("a\n", try f.get("w/a.md"));
}
