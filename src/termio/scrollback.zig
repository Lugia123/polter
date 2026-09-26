//! Saving a pane's scrollback with a project, and putting it back when the
//! project is reopened. See `dev-docs/project-scrollback.md`.
//!
//! The codec is `terminal/snapshot`; this file is only the product wiring
//! around it. Two halves:
//!
//!   * `capture` encodes a live terminal into bytes (on the IO thread, under
//!     the renderer lock) and `writeFile` puts them on disk atomically,
//!     outside the lock.
//!   * `restore` reads such a file into the fresh terminal a new pane has
//!     just made, before its shell has written anything.
//!
//! **What comes back is the primary screen's content and nothing else.** The
//! pane is running a new shell, so terminal-wide state from the old session
//! -- modes, the alternate screen, colors, charset, a program's kitty
//! keyboard flags -- would describe a program that is not there. The fresh
//! terminal keeps all of that from the config; only the primary screen's
//! pages and cursor are carried over.
//!
//! Anything that cannot be read -- a missing file, another snapshot version,
//! a bad CRC, any decode error -- leaves the fresh terminal exactly as it
//! was, which is what a pane got before this existed, and a file that is
//! there but unreadable is deleted so it is not tried again.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const snapshot = terminalpkg.snapshot;
const Terminal = terminalpkg.Terminal;

const log = std.log.scoped(.scrollback);

/// Encode `t` for a project, keeping at most `max_history_bytes` of history
/// (see `snapshot.EncodeOptions.max_history_bytes`). The caller holds
/// whatever lock guards `t`, and owns the returned bytes.
pub fn capture(
    alloc: Allocator,
    t: *const Terminal,
    max_history_bytes: u64,
) (snapshot.EncodeError || Allocator.Error)![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    snapshot.encode(alloc, &out.writer, t, .{
        // **Ground, whatever the parser is in the middle of.** A
        // continuation exists to resume *this* stream after the cut, and a
        // project snapshot is never resumed -- `restore` discards it
        // unread. Termio's stream does not track one anyway.
        .continuation = .ground,
        .max_history_bytes = max_history_bytes,
    }) catch |err| switch (err) {
        // The writer is an allocating one: its only failure is memory.
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return try out.toOwnedSlice();
}

/// Write `bytes` to `path` so that a reader sees either the old file or the
/// whole new one, never a prefix.
pub fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);

    var atomic = try dir.createFileAtomic(io, std.fs.path.basename(path), .{
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

/// The only files core will delete. See `deleteFile`.
pub const extension = ".snap";

/// Remove `path` if it is there and is named like a snapshot. Used when a
/// snapshot cannot be read, and when capture is switched off so a snapshot
/// from before is not restored later as if it were current.
///
/// **The path comes from the host, and core deletes it** -- so core, not
/// each of three hosts separately, is where "only ever a snapshot" is
/// enforced. Anything not ending in `.snap` is left alone and logged.
pub fn deleteFile(io: std.Io, path: []const u8) void {
    if (!std.mem.endsWith(u8, path, extension)) {
        log.warn("not removing a file that is not a {s} snapshot path={s}", .{ extension, path });
        return;
    }
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("could not remove scrollback snapshot path={s} err={}", .{ path, err }),
    };
}

/// What `restore` did. Returned for the log line and for tests; nothing in
/// the product branches on it.
pub const Outcome = union(enum) {
    /// No file at the path. The ordinary case for a pane saved before this
    /// existed, or with capture switched off.
    missing,

    /// The file could not be decoded, and was deleted.
    unreadable: anyerror,

    /// The primary screen now holds the saved content.
    restored: struct {
        /// History rows above the active area after restoring.
        history_rows: usize,

        /// Continuation bytes the snapshot carried and `restore` threw away.
        dropped_continuation: usize,
    },
};

/// Restore the snapshot at `path` into `t`.
///
/// `t` is the fresh terminal of a pane whose shell has not started, already
/// at its final size and at its final address. `stream` is the stream that
/// will parse that shell's output; it is taken only so that the decision
/// below about the continuation is made in view of it.
pub fn restore(
    alloc: Allocator,
    io: std.Io,
    path: []const u8,
    t: *Terminal,
    stream: anytype,
) Outcome {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return unreadable(io, path, err),
    };
    defer file.close(io);

    var read_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const reader = &file_reader.interface;

    var decoder: snapshot.Decoder = .init(reader);
    var decoded = decoder.ready(alloc, io, .{
        // Read so the snapshot validates; never replayed (see below).
        .max_continuation_bytes = 64 * 1024,
    }) catch |err| return unreadable(io, path, err);
    defer decoded.deinit(alloc);

    var old = decoded.toOwned();
    defer old.deinit(alloc);

    // **Order matters from here to the transplant, and each mistake is
    // silent: the pane comes back with less history and nothing says so.**
    //
    // 1. All history goes into `old` -- the terminal the decoder built --
    //    before `old`'s screen is moved into `t`. Draining after the move
    //    would prepend every page to whatever `old` holds by then, which is
    //    `t`'s empty screen on its way to being freed.
    //
    // 2. All history goes in before the resize. The decoder drops a page
    //    whose width no longer matches (`Decoder.nextPage`), **and every
    //    older page after it**, so resizing first to a narrower window
    //    would keep one screenful and lose the rest.
    while (decoder.next(alloc, &old) catch |err| return unreadable(io, path, err)) |_| {}

    old.resize(alloc, .{ .cols = t.cols, .rows = t.rows }) catch |err|
        return unreadable(io, path, err);

    // 3. **The continuation is dropped, not fed to `stream`.** This is the
    //    opposite of what the snapshot format intends, and deliberately so.
    //    A continuation is the unfinished escape sequence at the cut, kept so
    //    the *same* byte stream can carry on. Here the bytes that come next
    //    are from a new shell, which knows nothing of a half-written
    //    sequence: replaying it would make the new shell's first bytes the
    //    tail of the old one's escape.
    const dropped_continuation: usize = switch (decoded.continuation) {
        .ground => 0,
        .bytes => |bytes| bytes.len,
    };
    _ = stream;

    // Everything fallible is done. The transplant cannot fail, so `t` is
    // either untouched or complete.
    transplantPrimary(&old, t);

    return .{ .restored = .{
        .history_rows = t.screens.get(.primary).?.pages.total_rows - t.rows,
        .dropped_continuation = dropped_continuation,
    } };
}

/// Move `from`'s primary screen content into `to`, whose own empty content
/// goes back to `from` to be freed with it.
///
/// Only the pages and the cursor that lives in them move. Everything else
/// on the screen -- charset, protected mode, kitty keyboard flags, saved
/// cursor, image storage and its limits -- stays `to`'s, which is to say
/// fresh from the config.
fn transplantPrimary(from: *Terminal, to: *Terminal) void {
    const src = from.screens.get(.primary).?;
    const dst = to.screens.get(.primary).?;
    std.debug.assert(from.cols == to.cols and from.rows == to.rows);

    // The scrollback limits belong to the config the new pane runs under,
    // not to the one the snapshot was taken under.
    const limits = dst.pages.limits;

    std.mem.swap(@TypeOf(src.pages), &src.pages, &dst.pages);
    std.mem.swap(@TypeOf(src.cursor), &src.cursor, &dst.cursor);
    dst.semantic_prompt.seen = src.semantic_prompt.seen;

    dst.pages.setMaxBytes(explicit(limits.bytes.explicit));
    dst.pages.setMaxLines(explicit(limits.lines.explicit));

    // The old session's pen is not the new shell's.
    to.setAttribute(.unset) catch {};

    // The new shell's prompt goes below what was there, not over the last
    // line of it -- that line is usually the old prompt.
    to.carriageReturn();
    to.index() catch |err| log.warn("could not move below restored content err={}", .{err});
}

fn explicit(v: usize) ?usize {
    return if (v == std.math.maxInt(usize)) null else v;
}

fn unreadable(io: std.Io, path: []const u8, err: anyerror) Outcome {
    log.warn("scrollback snapshot unreadable, starting empty path={s} err={}", .{ path, err });
    deleteFile(io, path);
    return .{ .unreadable = err };
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// A terminal with `lines` numbered lines of output. `L000000` is the oldest.
fn testSource(cols: u16, rows: u16, lines: usize) !Terminal {
    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback_bytes = null,
    });
    errdefer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    var buf: [16]u8 = undefined;
    for (0..lines) |i| {
        s.nextSlice(try std.fmt.bufPrint(&buf, "L{d:0>6}\r\n", .{i}));
    }
    return t;
}

/// Enough numbered lines that the primary screen has several complete
/// pages above the one SCREEN carries, so the snapshot has HISTORY pages to
/// drain. **Without this the order tests cannot fail**: a few hundred lines
/// fit in one page, SCREEN carries all of them, and the drain has nothing to
/// get wrong.
const long_lines = 20_000;

fn testLongSource(cols: u16, rows: u16) !Terminal {
    var t = try testSource(cols, rows, long_lines);
    errdefer t.deinit(testing.allocator);
    try testing.expect(t.screens.get(.primary).?.pages.totalPages() >= 3);
    return t;
}

/// How many HISTORY pages `bytes` carries for the primary screen.
fn testHistoryPages(bytes: []const u8) !u32 {
    var source: std.Io.Reader = .fixed(bytes);
    var decoder: snapshot.Decoder = .init(&source);
    var decoded = try decoder.ready(testing.allocator, testing.io, .{
        .max_continuation_bytes = 0,
    });
    defer decoded.deinit(testing.allocator);
    var pages: u32 = 0;
    while (try decoder.next(testing.allocator, &decoded.terminal.?)) |progress| {
        if (progress.key == .primary) pages += 1;
    }
    return pages;
}

fn testFresh(cols: u16, rows: u16) !Terminal {
    return Terminal.init(testing.io, testing.allocator, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback_bytes = null,
    });
}

fn testPath(buf: []u8) ![]const u8 {
    var raw: [6]u8 = undefined;
    testing.io.random(&raw);
    return std.fmt.bufPrint(buf, "/tmp/polter-scrollback-{x}/pane.snap", .{&raw});
}

fn testCleanup(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(testing.io, std.fs.path.dirname(path).?) catch {};
}

fn testSave(t: *const Terminal, path: []const u8) !void {
    const bytes = try capture(testing.allocator, t, std.math.maxInt(u64));
    defer testing.allocator.free(bytes);
    try writeFile(testing.io, path, bytes);
}

/// The whole of `t`'s primary screen, history included, as text.
fn testDump(t: *Terminal) ![]const u8 {
    return t.screens.get(.primary).?.dumpStringAlloc(testing.allocator, .{ .screen = .{} });
}

fn testHistoryPagesAt(path: []const u8) !u32 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    return testHistoryPages(bytes);
}

fn testExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return false;
    return true;
}

test "restore at the same size brings all the history back" {
    var buf: [128]u8 = undefined;
    const path = try testPath(&buf);
    defer testCleanup(path);

    var source = try testLongSource(20, 5);
    defer source.deinit(testing.allocator);
    try testSave(&source, path);
    try testing.expect(try testHistoryPagesAt(path) >= 2);
    const saved_history = source.screens.get(.primary).?.pages.total_rows - source.rows;

    var t = try testFresh(20, 5);
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    const outcome = restore(testing.allocator, testing.io, path, &t, &s);

    // Order 1 (drain before transplant) is what this reddens on: drained
    // afterwards, the pages land in the terminal being thrown away.
    try testing.expect(outcome == .restored);
    try testing.expect(outcome.restored.history_rows >= saved_history);
    const dump = try testDump(&t);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.startsWith(u8, dump, "L000000\n"));
    try testing.expect(std.mem.indexOf(u8, dump, "L019999") != null);
}

test "restore into a narrower window keeps every line of history" {
    var buf: [128]u8 = undefined;
    const path = try testPath(&buf);
    defer testCleanup(path);

    // Saved 40 wide, reopened 12 wide. Every line is shorter than 12, so
    // reflow changes no line count: the history the saved terminal had is
    // a floor for what must come back.
    var source = try testLongSource(40, 5);
    defer source.deinit(testing.allocator);
    try testSave(&source, path);
    try testing.expect(try testHistoryPagesAt(path) >= 2);
    const saved_history = source.screens.get(.primary).?.pages.total_rows - source.rows;

    var t = try testFresh(12, 5);
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    const outcome = restore(testing.allocator, testing.io, path, &t, &s);

    // Order 2 (drain before resize) is what this reddens on: resized first,
    // the decoder drops every history page for the width mismatch.
    try testing.expect(outcome == .restored);
    try testing.expect(outcome.restored.history_rows >= saved_history);
    const dump = try testDump(&t);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.startsWith(u8, dump, "L000000\n"));
}

test "a continuation in the snapshot does not reach the new shell" {
    var buf: [128]u8 = undefined;
    const path = try testPath(&buf);
    defer testCleanup(path);

    // A snapshot cut in the middle of a CSI.
    var source = try testSource(20, 5, 3);
    defer source.deinit(testing.allocator);
    {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try snapshot.encode(testing.allocator, &out.writer, &source, .{
            .continuation = .{ .bytes = "\x1b[" },
        });
        try writeFile(testing.io, path, out.written());
    }

    var t = try testFresh(20, 5);
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    const outcome = restore(testing.allocator, testing.io, path, &t, &s);
    try testing.expect(outcome == .restored);
    try testing.expectEqual(2, outcome.restored.dropped_continuation);

    // The new shell's first bytes. Had `ESC [` been replayed, `h` would end
    // it as a CSI and only "ello" would print.
    s.nextSlice("hello");
    const dump = try testDump(&t);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "hello") != null);
}

test "restore keeps the fresh terminal's own state, not the old session's" {
    var buf: [128]u8 = undefined;
    const path = try testPath(&buf);
    defer testCleanup(path);

    // The old session was in a full-screen program on the alternate screen,
    // with bracketed paste on.
    var source = try testSource(20, 5, 50);
    defer source.deinit(testing.allocator);
    {
        var s = source.vtStream();
        defer s.deinit();
        s.nextSlice("\x1b[?2004h\x1b[?1049hFULLSCREEN");
    }
    try testing.expect(source.screens.active_key == .alternate);
    try testSave(&source, path);

    var t = try testFresh(20, 5);
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    try testing.expect(restore(testing.allocator, testing.io, path, &t, &s) == .restored);

    try testing.expect(t.screens.active_key == .primary);
    try testing.expect(!t.modes.get(.bracketed_paste));
    const dump = try testDump(&t);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "L000049") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "FULLSCREEN") == null);
}

test "an unreadable file that is not a .snap is left where it is" {
    // Core deletes what the host names, so a host passing the wrong path
    // must not cost the user a file.
    var buf: [128]u8 = undefined;
    const snap = try testPath(&buf);
    defer testCleanup(snap);
    var other_buf: [128]u8 = undefined;
    const other = try std.fmt.bufPrint(&other_buf, "{s}/project.json", .{std.fs.path.dirname(snap).?});
    try writeFile(testing.io, other, "{\"name\":\"not a snapshot\"}");

    var t = try testFresh(20, 5);
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    try testing.expect(restore(testing.allocator, testing.io, other, &t, &s) == .unreadable);
    try testing.expect(testExists(other));
}

test "a missing snapshot leaves the terminal as it was" {
    var buf: [128]u8 = undefined;
    const path = try testPath(&buf);
    defer testCleanup(path);

    var t = try testFresh(20, 5);
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    try testing.expect(restore(testing.allocator, testing.io, path, &t, &s) == .missing);
    try testing.expectEqual(t.rows, t.screens.get(.primary).?.pages.total_rows);
}

test "an unreadable snapshot starts empty and is deleted" {
    // Each case is a real snapshot file with bytes changed on disk, not a
    // null or an empty path.
    const Damage = enum { crc, version, truncated };
    for (std.enums.values(Damage)) |damage| {
        var buf: [128]u8 = undefined;
        const path = try testPath(&buf);
        defer testCleanup(path);

        var source = try testLongSource(20, 5);
        defer source.deinit(testing.allocator);
        const bytes = try capture(testing.allocator, &source, std.math.maxInt(u64));
        defer testing.allocator.free(bytes);

        const damaged: []const u8 = switch (damage) {
            // One byte deep in the last history page's payload: the envelope
            // and everything through READY still validate, so this is only
            // caught by that record's CRC, after pages were applied.
            .crc => crc: {
                bytes[bytes.len - 20] ^= 0xff;
                break :crc bytes;
            },
            // The envelope's version field (after the 8-byte magic).
            .version => version: {
                bytes[8] +%= 1;
                break :version bytes;
            },
            .truncated => bytes[0 .. bytes.len / 2],
        };
        try writeFile(testing.io, path, damaged);
        try testing.expect(testExists(path));

        var t = try testFresh(20, 5);
        defer t.deinit(testing.allocator);
        var s = t.vtStream();
        defer s.deinit();
        const outcome = restore(testing.allocator, testing.io, path, &t, &s);

        try testing.expect(outcome == .unreadable);
        try testing.expectEqual(@as(anyerror, switch (damage) {
            .crc => error.InvalidChecksum,
            .version => error.UnsupportedVersion,
            .truncated => error.EndOfStream,
        }), outcome.unreadable);
        try testing.expectEqual(t.rows, t.screens.get(.primary).?.pages.total_rows);
        const dump = try testDump(&t);
        defer testing.allocator.free(dump);
        try testing.expect(std.mem.indexOf(u8, dump, "L0") == null);
        try testing.expect(!testExists(path));
    }
}
