//! The one way a file in a workdir is written (task 2562 C3, PLAN §1.2
//! "写只有一条路"): `begin` notes what the file was when editing started,
//! `propose` works out what saving would do, `commit` does it. **No host and
//! no plugin has a write of its own**; they draw `Proposal.merged` and hand
//! the user's `Choice`s back.
//!
//! **The disk is looked at again, by `commit`, immediately before the write.**
//! `propose` having seen it unchanged is no answer: the user reads the
//! changes for as long as they like, and an agent may write the file in the
//! meantime. If what is there now is not the version `propose` compared
//! against, nothing is written and the answer is a new `Proposal` (the
//! merge, PLAN §1.6) for the user to look at again.
//!
//! **What the write keeps.** The editor deals in LF text with no BOM; the
//! file on disk may be neither. The write gives back what the file *now on
//! disk* has: its line ends (LF or CRLF), its byte order mark, whether it
//! ends in a newline, and its permissions. A file with mixed line ends is not
//! editable (`Failure.mixed_eol`): normalising it would rewrite every line,
//! and keeping each line's own end cannot be told apart from an edit.
//! An empty file has no habits to keep; it ends in a newline if the text does.
//! A file whose text is deleted entirely becomes empty, not a lone newline.
//!
//! **No new files, no removals, no renames.** The path is the real path of
//! a file that `Access` found in the workdir, asked again at `commit`. A file
//! that has gone is `Failure.gone`; only `Options.restore_gone`, which the
//! user chooses ("save back in place"), writes it again, in a directory that
//! `Access` still finds in the workdir.
//!
//! **Atomic.** The bytes go to a temporary file in the same directory
//! (**it has a name**: 16 hex digits, made by `std.Io.Dir.createFileAtomic`),
//! are synced, and are renamed over the file, so a reader sees the old file or
//! the new one. A process that dies after the temporary file is made and
//! before the rename leaves it behind in the workdir, where the file watch
//! (C5) will see it too. The gap between the version check and the rename is
//! not closed (no lock is taken here); it is narrowed by looking at the
//! file's size and mtime once more just before the rename, and what is caught
//! there comes back as a new `Proposal` like any other change. An agent that
//! writes inside what is left loses its write, which is the same as it having
//! written just before. A file with several hard links is replaced, not edited
//! in place; the other names keep the old bytes. Owner, ACLs and extended
//! attributes (Finder tags, quarantine) are not carried over; the permission
//! bits are.
//!
//! **Putting a file back** (`restore_gone`) links the temporary file into
//! place instead of renaming over it, so a file that appeared at that path in
//! the meantime is not overwritten: the answer is a `Proposal` against it.
//! It ignores `choices`: there is no disk to conflict with, and the text is
//! the editor's.

const Write = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const Access = @import("Access.zig");
const Text = @import("Text.zig");
const Merge = @import("Merge.zig");
const Diff = @import("Diff.zig");

const log = std.log.scoped(.poltergeist);

/// What "the file has not changed" means (PLAN §1.2): all three.
pub const Version = struct {
    size: u64,
    /// Nanoseconds since the epoch.
    mtime_ns: i128,
    sha256: [32]u8,

    pub fn eql(a: Version, b: Version) bool {
        return a.size == b.size and a.mtime_ns == b.mtime_ns and std.mem.eql(u8, &a.sha256, &b.sha256);
    }
};

/// The file as it was read: where it really is, which version, its bytes.
pub const Disk = struct {
    /// Real (`Access`): the path that is written.
    path: []const u8,
    version: Version,
    /// The bytes as read, BOM and line ends included.
    text: []const u8,
    info: Text.Info,
    permissions: Io.File.Permissions,
};

pub const Target = struct {
    /// The workdir the file belongs to, real.
    workdir: []const u8,
    /// `Workdirs.Dir.readable` said no (see `Access.Request.too_wide`).
    /// **No default**, as there: forgetting it must not compile.
    too_wide: bool,
};

pub const Failure = union(enum) {
    /// The file is not there (any more).
    gone,
    refuse: Access.Refusal,
    not_editable: Text.NotEditable,
    mixed_eol,
    unreadable,
    /// The temporary file or the rename failed; the file is as it was.
    write_failed: []const u8,

    pub fn say(self: Failure) []const u8 {
        return switch (self) {
            .gone => "the file is not there any more",
            .refuse => |r| r.say(),
            .not_editable => |n| n.say(),
            .mixed_eol => "its lines end in both LF and CRLF, and saving would change some of them",
            .unreadable => "it could not be read",
            .write_failed => "it could not be written; the file is as it was",
        };
    }
};

pub fn Outcome(comptime T: type) type {
    return union(enum) { ok: T, failed: Failure };
}

pub const Options = struct {
    /// Write the file again if it has gone (the user chose to).
    restore_gone: bool = false,
};

/// What saving would do, for the host to draw (06, and 08 when the disk has
/// changed).
pub const Proposal = struct {
    /// What the editor was opened on.
    base: Disk,
    /// What the disk held when this was worked out; `commit` checks it is
    /// still so.
    disk: Disk,
    /// The editor's text as handed over.
    mine: []const u8,
    /// `disk` is not `base`: somebody wrote the file while it was open.
    disk_changed: bool,
    /// Lines of base against mine against the disk; with the disk
    /// unchanged this has no `theirs_only` and no `conflict`.
    merged: Merge.Merged,
};

pub const Committed = union(enum) {
    written: Version,
    /// The disk is not what `proposal.disk` was: nothing written.
    changed: Proposal,
};

/// Read the file for editing. Path is relative to the workdir or absolute.
pub fn begin(arena: Allocator, io: Io, target: Target, path: []const u8) Allocator.Error!Outcome(Disk) {
    return load(arena, io, target, path, false);
}

/// `base_version` is `base.version` (PLAN §1.2). The disk is read again here.
pub fn propose(arena: Allocator, io: Io, target: Target, base: Disk, mine: []const u8) Allocator.Error!Outcome(Proposal) {
    const disk = switch (try load(arena, io, target, base.path, true)) {
        .ok => |d| d,
        .failed => |f| return .{ .failed = f },
    };
    return .{ .ok = try build(arena, base, disk, mine) };
}

pub const CommitError = Allocator.Error || Merge.AssembleError;

pub fn commit(
    arena: Allocator,
    io: Io,
    target: Target,
    proposal: Proposal,
    choices: []const Merge.Choice,
    options: Options,
) CommitError!Outcome(Committed) {
    // **The check, immediately before the write.**
    const now = switch (try load(arena, io, target, proposal.base.path, true)) {
        .ok => |d| d,
        .failed => |f| switch (f) {
            .gone => if (options.restore_gone) return restore(arena, io, target, proposal) else return .{ .failed = .gone },
            else => return .{ .failed = f },
        },
    };
    if (!now.version.eql(proposal.disk.version)) {
        return .{ .ok = .{ .changed = try build(arena, proposal.base, now, proposal.mine) } };
    }

    const body = try Merge.assemble(arena, proposal.merged, try lfEdits(arena, choices, now.info.eol == .crlf));
    const bytes = try render(arena, body, habits(now, proposal.mine));
    writeAtomic(io, now.path, bytes, now.permissions, .replace, now.version) catch |e| switch (e) {
        // It moved after the check above: nothing was written.
        error.ChangedUnderneath => return changedAgain(arena, io, target, proposal),
        else => return failedWrite(now.path, e),
    };
    return .{ .ok = .{ .written = (after(io, now.path, bytes)) orelse return .{ .failed = .unreadable } } };
}

/// The file has gone and the user said to put it back: their own text, in
/// the habits the file had when editing began.
fn restore(arena: Allocator, io: Io, target: Target, proposal: Proposal) CommitError!Outcome(Committed) {
    const path = proposal.base.path;
    const dir = std.fs.path.dirname(path) orelse return .{ .failed = .{ .refuse = .bad_path } };
    const v = try Access.resolve(arena, io, .{
        .workdir = target.workdir,
        .path = dir,
        .too_wide = target.too_wide,
    });
    switch (v) {
        .refuse => |r| return .{ .failed = .{ .refuse = r } },
        .ok => |r| if (r.kind != .directory) return .{ .failed = .{ .refuse = .not_a_file } },
    }
    const bytes = try render(arena, try bodyOfMine(arena, proposal.mine, proposal.base.info.eol == .crlf), habits(proposal.base, proposal.mine));
    writeAtomic(io, path, bytes, null, .create_new, null) catch |e| switch (e) {
        // Somebody made the file after it was found gone: theirs stays.
        error.PathAlreadyExists => return changedAgain(arena, io, target, proposal),
        else => return failedWrite(path, e),
    };
    return .{ .ok = .{ .written = (after(io, path, bytes)) orelse return .{ .failed = .unreadable } } };
}

/// The disk is not what the proposal was made against (it moved after the
/// check, or a file appeared where it had gone): read it again and hand back
/// the merge. Nothing has been written.
fn changedAgain(arena: Allocator, io: Io, target: Target, proposal: Proposal) CommitError!Outcome(Committed) {
    return switch (try load(arena, io, target, proposal.base.path, true)) {
        .ok => |d| .{ .ok = .{ .changed = try build(arena, proposal.base, d, proposal.mine) } },
        .failed => |f| .{ .failed = f },
    };
}

/// `.edit` texts as LF, for a CRLF file (an editor may hand back `\r\n`).
fn lfEdits(arena: Allocator, choices: []const Merge.Choice, crlf: bool) Allocator.Error![]const Merge.Choice {
    if (!crlf) return choices;
    const out = try arena.dupe(Merge.Choice, choices);
    for (out) |*c| switch (c.*) {
        .edit => |t| c.* = .{ .edit = try std.mem.replaceOwned(u8, arena, t, "\r\n", "\n") },
        else => {},
    };
    return out;
}

fn failedWrite(path: []const u8, e: anyerror) Outcome(Committed) {
    log.warn("files: write failed path={s} err={s}", .{ path, @errorName(e) });
    return .{ .failed = .{ .write_failed = @errorName(e) } };
}

// ------------------------------------------------------------ reading

fn load(arena: Allocator, io: Io, target: Target, path: []const u8, reopen: bool) Allocator.Error!Outcome(Disk) {
    const v = try Access.resolve(arena, io, .{
        .workdir = target.workdir,
        .path = path,
        // On a reopen the path is the real one already read, so the ticket
        // is that file alone.
        .scope = if (reopen) .file else .workdir,
        .anchor = if (reopen) path else null,
        .too_wide = target.too_wide,
    });
    const real = switch (v) {
        .ok => |r| r,
        .refuse => |why| {
            // Access calls a path that is not there "outside" on purpose.
            // This path was inside when it was first read, so its not being
            // there is a fact about this workdir, and the file's own to tell.
            if (reopen and why == .outside) {
                if (Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false })) |_| {} else |e| {
                    if (e == error.FileNotFound) return .{ .failed = .gone };
                }
            }
            return .{ .failed = .{ .refuse = why } };
        },
    };
    if (real.kind != .file) return .{ .failed = .{ .refuse = .not_a_file } };

    const st = Io.Dir.cwd().statFile(io, real.path, .{}) catch |e| {
        if (e == error.FileNotFound) return .{ .failed = .gone };
        return .{ .failed = .unreadable };
    };
    const name = std.fs.path.basename(real.path);
    if (st.size > Text.edit_limit) return .{ .failed = .{ .not_editable = .too_big } };
    const bytes = Io.Dir.cwd().readFileAlloc(io, real.path, arena, .limited(Text.edit_limit + 1)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return .{ .failed = .gone },
        error.StreamTooLong => return .{ .failed = .{ .not_editable = .too_big } },
        else => return .{ .failed = .unreadable },
    };
    // Changed while it was being read: neither the stat nor the bytes can be
    // called the version.
    if (bytes.len != st.size) return .{ .failed = .unreadable };

    const info = Text.sniff(bytes, bytes.len);
    if (Text.notEditable(name, bytes.len, info)) |n| return .{ .failed = .{ .not_editable = n } };
    if (info.eol == .mixed) return .{ .failed = .mixed_eol };

    return .{ .ok = .{
        .path = real.path,
        .version = .{ .size = bytes.len, .mtime_ns = @as(i128, st.mtime.nanoseconds), .sha256 = hash(bytes) },
        .text = bytes,
        .info = info,
        .permissions = st.permissions,
    } };
}

fn hash(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Sha256.hash(bytes, &out, .{});
    return out;
}

/// The version of what was just written; null if it cannot be stat'ed.
fn after(io: Io, path: []const u8, bytes: []const u8) ?Version {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return .{ .size = bytes.len, .mtime_ns = @as(i128, st.mtime.nanoseconds), .sha256 = hash(bytes) };
}

// ------------------------------------------------------------ the text

/// The text the merge works on: no BOM, LF line ends, and **one trailing
/// newline taken off** -- `Diff.lines` would otherwise count it as a last
/// empty line that every edit at the end of the file would touch. The
/// newline is put back by `render` from the file's habit.
fn bodyOf(arena: Allocator, text: []const u8, info: Text.Info) Allocator.Error![]const u8 {
    var s = text;
    if (info.encoding == .utf8_bom) s = s[3..];
    if (info.eol == .crlf) s = try std.mem.replaceOwned(u8, arena, s, "\r\n", "\n");
    return dropFinalNewline(s);
}

/// The editor's text in the same form. `crlf`: the file on disk is CRLF, so
/// an editor that handed back `\r\n` is normalised too.
fn bodyOfMine(arena: Allocator, text: []const u8, crlf: bool) Allocator.Error![]const u8 {
    var s = text;
    if (std.mem.startsWith(u8, s, "\xEF\xBB\xBF")) s = s[3..];
    if (crlf) s = try std.mem.replaceOwned(u8, arena, s, "\r\n", "\n");
    return dropFinalNewline(s);
}

fn dropFinalNewline(s: []const u8) []const u8 {
    return if (s.len > 0 and s[s.len - 1] == '\n') s[0 .. s.len - 1] else s;
}

fn build(arena: Allocator, base: Disk, disk: Disk, mine: []const u8) Allocator.Error!Proposal {
    const b = try bodyOf(arena, base.text, base.info);
    const m = try bodyOfMine(arena, mine, disk.info.eol == .crlf);
    const changed = !disk.version.eql(base.version);
    // Unchanged disk: theirs is base itself, so the table is only mine's
    // changes and no hunk of the disk's can be in it.
    const t = if (changed) try bodyOf(arena, disk.text, disk.info) else b;
    return .{
        .base = base,
        .disk = disk,
        .mine = mine,
        .disk_changed = changed,
        .merged = try Merge.merge(arena, b, m, t),
    };
}

const Habits = struct {
    bom: bool,
    crlf: bool,
    final_newline: bool,
    /// The editor's text is empty: the user deleted everything, and a file
    /// that used to end in a newline is then empty, not a lone `\n`.
    mine_empty: bool,
};

/// What the file does, or for an empty file what the text asks for.
fn habits(d: Disk, mine: []const u8) Habits {
    return .{
        .bom = d.info.encoding == .utf8_bom,
        .crlf = d.info.eol == .crlf,
        .final_newline = if (d.text.len == 0) std.mem.endsWith(u8, mine, "\n") else d.info.final_newline,
        .mine_empty = mine.len == 0 or std.mem.eql(u8, mine, "\xEF\xBB\xBF"),
    };
}

fn render(arena: Allocator, body: []const u8, h: Habits) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (h.bom) try out.appendSlice(arena, "\xEF\xBB\xBF");
    const text = if (h.crlf) try std.mem.replaceOwned(u8, arena, body, "\n", "\r\n") else body;
    try out.appendSlice(arena, text);
    if (h.final_newline and !(body.len == 0 and h.mine_empty)) try out.appendSlice(arena, if (h.crlf) "\r\n" else "\n");
    return out.items;
}

// ------------------------------------------------------------ writing

const Mode = enum { replace, create_new };

/// `permissions` null: the default for a new file. Otherwise the temporary
/// file is given exactly the old file's permissions (a umask does not apply
/// to `chmod`).
///
/// `.replace`: rename over the file. `.create_new`: link into place, failing
/// with `PathAlreadyExists` rather than overwriting.
///
/// `guard`: the version the file had when it was read; if its size or mtime
/// is not that when the rename is about to happen, `error.ChangedUnderneath`
/// and nothing is replaced. The temporary file is synced first, so a crash
/// after the rename cannot leave an empty file.
fn writeAtomic(io: Io, path: []const u8, bytes: []const u8, permissions: ?Io.File.Permissions, mode: Mode, guard: ?Version) !void {
    const dir_path = std.fs.path.dirname(path) orelse return error.BadPath;
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    var af = try dir.createFileAtomic(io, std.fs.path.basename(path), .{
        .permissions = permissions orelse .default_file,
        .replace = mode == .replace,
    });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    if (permissions) |p| try af.file.setPermissions(io, p);
    try af.file.sync(io);
    if (guard) |v| if (!unchanged(io, path, v)) return error.ChangedUnderneath;
    switch (mode) {
        .replace => try af.replace(io),
        .create_new => try af.link(io),
    }
}

/// Size and mtime still those of `v` (the content is not read again here:
/// that is the narrowing, not the check -- `commit` already compared the hash).
fn unchanged(io: Io, path: []const u8, v: Version) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.size == v.size and @as(i128, st.mtime.nanoseconds) == v.mtime_ns;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const builtin = @import("builtin");

const Fixture = struct {
    tmp: testing.TmpDir,
    /// Real: `<tmp>/w`, the workdir.
    work: [:0]u8,
    arena: std.heap.ArenaAllocator,

    fn init() !Fixture {
        var f: Fixture = .{ .tmp = testing.tmpDir(.{}), .work = undefined, .arena = .init(testing.allocator) };
        errdefer f.tmp.cleanup();
        try f.tmp.dir.createDirPath(testing.io, "w/sub");
        try f.tmp.dir.createDirPath(testing.io, "other");
        f.work = try f.tmp.dir.realPathFileAlloc(testing.io, "w", testing.allocator);
        return f;
    }

    fn deinit(f: *Fixture) void {
        testing.allocator.free(f.work);
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn a(f: *Fixture) Allocator {
        return f.arena.allocator();
    }

    fn target(f: *Fixture) Target {
        return .{ .workdir = f.work, .too_wide = false };
    }

    fn put(f: *Fixture, sub: []const u8, data: []const u8) !void {
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = data });
    }

    fn get(f: *Fixture, sub: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(testing.io, sub, f.a(), .limited(1 << 24));
    }

    fn open(f: *Fixture, rel: []const u8) !Disk {
        return switch (try begin(f.a(), testing.io, f.target(), rel)) {
            .ok => |d| d,
            .failed => |x| {
                std.debug.print("begin {s}: {s}\n", .{ rel, @tagName(x) });
                return error.TestUnexpectedFailure;
            },
        };
    }

    fn propose(f: *Fixture, base: Disk, mine: []const u8) !Proposal {
        return switch (try Write.propose(f.a(), testing.io, f.target(), base, mine)) {
            .ok => |p| p,
            .failed => |x| {
                std.debug.print("propose: {s}\n", .{@tagName(x)});
                return error.TestUnexpectedFailure;
            },
        };
    }

    fn commit(f: *Fixture, p: Proposal, choices: []const Merge.Choice) !Outcome(Committed) {
        return Write.commit(f.a(), testing.io, f.target(), p, choices, .{});
    }

    /// How many names there are in the workdir's `sub` directory.
    fn count(f: *Fixture, sub: []const u8) !usize {
        var d = try f.tmp.dir.openDir(testing.io, sub, .{ .iterate = true });
        defer d.close(testing.io);
        var it = d.iterate();
        var n: usize = 0;
        while (try it.next(testing.io)) |_| n += 1;
        return n;
    }
};

fn expectWritten(o: Outcome(Committed)) !Version {
    switch (o) {
        .ok => |c| switch (c) {
            .written => |v| return v,
            .changed => return error.TestExpectedWritten,
        },
        .failed => |x| {
            std.debug.print("expected a write, got {s}\n", .{@tagName(x)});
            return error.TestExpectedWritten;
        },
    }
}

fn expectFailed(comptime tag: std.meta.Tag(Failure), got: anytype) !void {
    switch (got) {
        .ok => return error.TestExpectedFailure,
        .failed => |x| try testing.expectEqual(tag, std.meta.activeTag(x)),
    }
}

test "2562 C3: begin notes the version, and the bytes as they are" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.put("w/a.txt", "hello\n");
    const d = try fx.open("a.txt");
    try testing.expectEqual(@as(u64, 6), d.version.size);
    try testing.expect(d.version.mtime_ns > 0);
    try testing.expectEqualSlices(u8, &hash("hello\n"), &d.version.sha256);
    try testing.expectEqualStrings("hello\n", d.text);
    try testing.expect(d.version.eql(d.version));
    var other = d.version;
    other.sha256[0] ^= 1;
    try testing.expect(!d.version.eql(other));
}

test "2562 C3: an unchanged disk saves what the editor holds, through a temporary file that is gone after" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.put("w/a.txt", "one\ntwo\nthree\n");
    const base = try fx.open("a.txt");
    const p = try fx.propose(base, "one\nTWO\nthree\n");
    try testing.expect(!p.disk_changed);
    try testing.expectEqual(@as(usize, 0), p.merged.conflicts);
    const v = try expectWritten(try fx.commit(p, &.{}));
    try testing.expectEqualStrings("one\nTWO\nthree\n", try fx.get("w/a.txt"));
    try testing.expectEqual(@as(u64, 14), v.size);
    // The version handed back is the file's.
    try testing.expect(v.eql((try fx.open("a.txt")).version));
    // Only the file itself is in the directory.
    try testing.expectEqual(@as(usize, 2), try fx.count("w")); // a.txt, sub
}

test "2562 C3: line ends, BOM and the final newline are the file's, not the editor's" {
    var fx = try Fixture.init();
    defer fx.deinit();

    // CRLF stays CRLF, the editor having given LF.
    try fx.put("w/crlf.txt", "a\r\nb\r\n");
    var p = try fx.propose(try fx.open("crlf.txt"), "a\nB\n");
    _ = try expectWritten(try fx.commit(p, &.{}));
    try testing.expectEqualStrings("a\r\nB\r\n", try fx.get("w/crlf.txt"));

    // ... and an editor that handed CRLF back does not make it CRLF twice.
    try fx.put("w/crlf2.txt", "a\r\nb\r\n");
    p = try fx.propose(try fx.open("crlf2.txt"), "a\r\nB\r\n");
    _ = try expectWritten(try fx.commit(p, &.{}));
    try testing.expectEqualStrings("a\r\nB\r\n", try fx.get("w/crlf2.txt"));

    // BOM stays.
    try fx.put("w/bom.txt", "\xEF\xBB\xBFa\nb\n");
    p = try fx.propose(try fx.open("bom.txt"), "a\nB\n");
    _ = try expectWritten(try fx.commit(p, &.{}));
    try testing.expectEqualStrings("\xEF\xBB\xBFa\nB\n", try fx.get("w/bom.txt"));

    // No newline at the end stays none, even if the editor added one.
    try fx.put("w/nonl.txt", "a\nb");
    p = try fx.propose(try fx.open("nonl.txt"), "a\nB\n");
    _ = try expectWritten(try fx.commit(p, &.{}));
    try testing.expectEqualStrings("a\nB", try fx.get("w/nonl.txt"));

    // A newline at the end stays, even if the editor dropped it.
    try fx.put("w/nl.txt", "a\nb\n");
    p = try fx.propose(try fx.open("nl.txt"), "a\nB");
    _ = try expectWritten(try fx.commit(p, &.{}));
    try testing.expectEqualStrings("a\nB\n", try fx.get("w/nl.txt"));

    // A blank line the user put at the end survives the round trip.
    try fx.put("w/blank.txt", "a\n");
    p = try fx.propose(try fx.open("blank.txt"), "a\n\n");
    _ = try expectWritten(try fx.commit(p, &.{}));
    try testing.expectEqualStrings("a\n\n", try fx.get("w/blank.txt"));

    // An empty file takes the text as it comes.
    try fx.put("w/empty.txt", "");
    p = try fx.propose(try fx.open("empty.txt"), "new\n");
    _ = try expectWritten(try fx.commit(p, &.{}));
    try testing.expectEqualStrings("new\n", try fx.get("w/empty.txt"));
}

test "2562 C3: permissions are the file's" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.put("w/x.sh", "echo a\n");
    {
        var f = try fx.tmp.dir.openFile(testing.io, "w/x.sh", .{});
        defer f.close(testing.io);
        try f.setPermissions(testing.io, .fromMode(0o750));
    }
    const p = try fx.propose(try fx.open("x.sh"), "echo b\n");
    _ = try expectWritten(try fx.commit(p, &.{}));
    try testing.expectEqualStrings("echo b\n", try fx.get("w/x.sh"));
    const st = try fx.tmp.dir.statFile(testing.io, "w/x.sh", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o750), st.permissions.toMode() & 0o777);
}

test "2562 C3: the disk changing between propose and commit writes nothing and goes back to the merge" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.put("w/a.txt", "1\n2\n3\n4\n5\n");
    const base = try fx.open("a.txt");
    const p = try fx.propose(base, "1\nTWO\n3\n4\n5\n");
    try testing.expect(!p.disk_changed);

    // An agent writes line 5 while the user is reading the changes.
    try fx.put("w/a.txt", "1\n2\n3\n4\nFIVE\n");
    const out = try fx.commit(p, &.{});
    const again = switch (out) {
        .ok => |c| switch (c) {
            .changed => |n| n,
            .written => return error.TestWroteOverAChangedFile,
        },
        .failed => return error.TestExpectedMerge,
    };
    // Nothing was written: the agent's text is what is there.
    try testing.expectEqualStrings("1\n2\n3\n4\nFIVE\n", try fx.get("w/a.txt"));
    try testing.expect(again.disk_changed);
    // Different places: merged by itself, and committing that keeps both.
    try testing.expectEqual(@as(usize, 0), again.merged.conflicts);
    _ = try expectWritten(try fx.commit(again, &.{}));
    try testing.expectEqualStrings("1\nTWO\n3\n4\nFIVE\n", try fx.get("w/a.txt"));
}

test "2562 C3: a disk that changed before propose is the merge at once, and a conflict wants a choice" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.put("w/a.txt", "1\n2\n3\n");
    const base = try fx.open("a.txt");
    try fx.put("w/a.txt", "1\nAGENT\n3\n");
    const p = try fx.propose(base, "1\nMINE\n3\n");
    try testing.expect(p.disk_changed);
    try testing.expectEqual(@as(usize, 1), p.merged.conflicts);
    try testing.expectError(error.Unresolved, fx.commit(p, &.{}));
    try testing.expectEqualStrings("1\nAGENT\n3\n", try fx.get("w/a.txt"));
    _ = try expectWritten(try fx.commit(p, &.{.use_mine}));
    try testing.expectEqualStrings("1\nMINE\n3\n", try fx.get("w/a.txt"));
}

test "2562 C3: a file that has gone is gone, and nothing makes it again unless asked" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.put("w/a.txt", "x\ny\n");
    const base = try fx.open("a.txt");
    const p = try fx.propose(base, "x\nY\n");
    try fx.tmp.dir.deleteFile(testing.io, "w/a.txt");

    try expectFailed(.gone, try Write.propose(fx.a(), testing.io, fx.target(), base, "x\nY\n"));
    try expectFailed(.gone, try fx.commit(p, &.{}));
    try testing.expectError(error.FileNotFound, fx.tmp.dir.statFile(testing.io, "w/a.txt", .{}));

    // The user chose "save back in place".
    _ = try expectWritten(try Write.commit(fx.a(), testing.io, fx.target(), p, &.{}, .{ .restore_gone = true }));
    try testing.expectEqualStrings("x\nY\n", try fx.get("w/a.txt"));
}

test "2562 C3: a file is never made where its directory is gone" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.put("w/sub/a.txt", "x\n");
    const base = try fx.open("sub/a.txt");
    const p = try fx.propose(base, "y\n");
    try fx.tmp.dir.deleteFile(testing.io, "w/sub/a.txt");
    try fx.tmp.dir.deleteDir(testing.io, "w/sub");
    try expectFailed(.refuse, try Write.commit(fx.a(), testing.io, fx.target(), p, &.{}, .{ .restore_gone = true }));
    try testing.expectError(error.FileNotFound, fx.tmp.dir.statFile(testing.io, "w/sub", .{}));
}

test "2562 C3: there is no way to make, remove or move a file, or to write outside the workdir" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.put("other/secret.txt", "s\n");
    try fx.put("w/a.txt", "a\n");
    // Not there: begin does not make it.
    try expectFailed(.refuse, try begin(fx.a(), testing.io, fx.target(), "new.txt"));
    try testing.expectError(error.FileNotFound, fx.tmp.dir.statFile(testing.io, "w/new.txt", .{}));
    // Outside, by spelling and by absolute path.
    try expectFailed(.refuse, try begin(fx.a(), testing.io, fx.target(), "../other/secret.txt"));
    const abs = try std.fs.path.join(fx.a(), &.{ fx.work, "..", "other", "secret.txt" });
    try expectFailed(.refuse, try begin(fx.a(), testing.io, fx.target(), abs));
    // A link inside that leads out.
    if (builtin.os.tag != .windows) {
        try fx.tmp.dir.symLink(testing.io, "../other/secret.txt", "w/link.txt", .{});
        try expectFailed(.refuse, try begin(fx.a(), testing.io, fx.target(), "link.txt"));
    }
    // A directory is not a file.
    try expectFailed(.refuse, try begin(fx.a(), testing.io, fx.target(), "sub"));
    // The workdir page said it is too wide.
    try expectFailed(.refuse, try begin(fx.a(), testing.io, .{ .workdir = fx.work, .too_wide = true }, "a.txt"));
    try testing.expectEqualStrings("s\n", try fx.get("other/secret.txt"));
}

test "2562 C3: what the editor may not hold is not opened, and not written if it became so" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.put("w/bin.dat", "a\x00b");
    try expectFailed(.not_editable, try begin(fx.a(), testing.io, fx.target(), "bin.dat"));
    try fx.put("w/gbk.txt", "a\xFFb\n");
    try expectFailed(.not_editable, try begin(fx.a(), testing.io, fx.target(), "gbk.txt"));
    try fx.put("w/doc.docx", "text");
    try expectFailed(.not_editable, try begin(fx.a(), testing.io, fx.target(), "doc.docx"));
    const big = try fx.a().alloc(u8, Text.edit_limit + 1);
    @memset(big, 'a');
    try fx.put("w/big.txt", big);
    try expectFailed(.not_editable, try begin(fx.a(), testing.io, fx.target(), "big.txt"));
    try fx.put("w/mixed.txt", "a\r\nb\nc\r\n");
    try expectFailed(.mixed_eol, try begin(fx.a(), testing.io, fx.target(), "mixed.txt"));

    // Opened as text, became binary while the editor was open.
    try fx.put("w/t.txt", "a\nb\n");
    const p = try fx.propose(try fx.open("t.txt"), "a\nB\n");
    try fx.put("w/t.txt", "a\x00b\n");
    try expectFailed(.not_editable, try fx.commit(p, &.{}));
    try testing.expectEqualStrings("a\x00b\n", try fx.get("w/t.txt"));
}

test "2562 C3: a large edit over a disk that did not move can be saved" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var src: std.ArrayList(u8) = .empty;
    var dst: std.ArrayList(u8) = .empty;
    for (0..Diff.max_edits) |i| {
        try src.print(fx.a(), "a{d}\n", .{i});
        try dst.print(fx.a(), "b{d}\n", .{i});
    }
    try fx.put("w/big.txt", src.items);
    const p = try fx.propose(try fx.open("big.txt"), dst.items);
    try testing.expect(p.merged.whole_file);
    try testing.expectEqual(@as(usize, 0), p.merged.conflicts);
    _ = try expectWritten(try fx.commit(p, &.{}));
    try testing.expectEqualStrings(dst.items, try fx.get("w/big.txt"));
}

test "2562 C3: putting a gone file back never overwrites one that has appeared" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.put("w/a.txt", "x\n");
    const p = try fx.propose(try fx.open("a.txt"), "mine\n");
    try fx.tmp.dir.deleteFile(testing.io, "w/a.txt");
    // An agent makes it again before the user's "save back in place".
    try fx.put("w/a.txt", "agent\n");
    const out = try Write.commit(fx.a(), testing.io, fx.target(), p, &.{}, .{ .restore_gone = true });
    // That is not "gone" any more: an ordinary commit, which sees the change.
    switch (out) {
        .ok => |c| try testing.expect(c == .changed),
        .failed => return error.TestExpectedMerge,
    }
    try testing.expectEqualStrings("agent\n", try fx.get("w/a.txt"));
}

test "2562 C3: restore, reached after the file was found gone, does not overwrite one made since" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.put("w/a.txt", "x\n");
    const p = try fx.propose(try fx.open("a.txt"), "mine\n");
    try fx.tmp.dir.deleteFile(testing.io, "w/a.txt");
    // `commit` has seen the file gone and chosen `restore`; before that
    // writes, somebody makes the file. `commit` cannot be stopped between the
    // two, so this is the second half on its own: which write mode it picks.
    try fx.put("w/a.txt", "agent\n");
    const out = try restore(fx.a(), testing.io, fx.target(), p);
    switch (out) {
        .ok => |c| switch (c) {
            .changed => |n| try testing.expect(n.disk_changed),
            .written => return error.TestRestoreOverwroteANewFile,
        },
        .failed => return error.TestExpectedMerge,
    }
    try testing.expectEqualStrings("agent\n", try fx.get("w/a.txt"));
    try testing.expectEqual(@as(usize, 2), try fx.count("w")); // a.txt, sub: no temporary left
}

test "2562 C3: the link-into-place write refuses a name that is taken" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.put("w/a.txt", "agent\n");
    const path = try std.fs.path.join(fx.a(), &.{ fx.work, "a.txt" });
    try testing.expectError(error.PathAlreadyExists, writeAtomic(testing.io, path, "mine\n", null, .create_new, null));
    try testing.expectEqualStrings("agent\n", try fx.get("w/a.txt"));
    try testing.expectEqual(@as(usize, 2), try fx.count("w")); // a.txt, sub: no temporary left
}

test "2562 C3: just before the rename the file is looked at once more" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.put("w/a.txt", "one\n");
    const d = try fx.open("a.txt");
    try testing.expect(unchanged(testing.io, d.path, d.version));
    // The guard in `writeAtomic` is this function; a changed file stops it.
    try fx.put("w/a.txt", "one more\n");
    try testing.expect(!unchanged(testing.io, d.path, d.version));
    try testing.expectError(error.ChangedUnderneath, writeAtomic(testing.io, d.path, "x\n", d.permissions, .replace, d.version));
    try testing.expectEqualStrings("one more\n", try fx.get("w/a.txt"));
    try testing.expectEqual(@as(usize, 2), try fx.count("w"));
}

test "2562 C3: an edit chosen for a CRLF file is written CRLF, once" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.put("w/a.txt", "1\r\n2\r\n3\r\n");
    const base = try fx.open("a.txt");
    try fx.put("w/a.txt", "1\r\nAGENT\r\n3\r\n");
    const p = try fx.propose(base, "1\nMINE\n3\n");
    try testing.expectEqual(@as(usize, 1), p.merged.conflicts);
    _ = try expectWritten(try fx.commit(p, &.{.{ .edit = "x\r\ny\r\n" }}));
    try testing.expectEqualStrings("1\r\nx\r\ny\r\n3\r\n", try fx.get("w/a.txt"));
}

test "2562 C3: deleting everything writes an empty file, not a lone newline" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.put("w/a.txt", "a\nb\n");
    const p = try fx.propose(try fx.open("a.txt"), "");
    _ = try expectWritten(try fx.commit(p, &.{}));
    try testing.expectEqualStrings("", try fx.get("w/a.txt"));
    // A blank line that is really there stays.
    try fx.put("w/b.txt", "\n");
    const q = try fx.propose(try fx.open("b.txt"), "\n");
    _ = try expectWritten(try fx.commit(q, &.{}));
    try testing.expectEqualStrings("\n", try fx.get("w/b.txt"));
}
