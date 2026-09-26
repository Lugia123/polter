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
const journal = @import("scrollback_journal.zig");

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
    // Whole, because a journal is read from its end back (the last whole
    // checkpoint, then its pages newest first). Bounded by the journal's own
    // compaction at about twice `project-scrollback-limit-bytes`.
    const file_bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return unreadable(io, path, err),
    };
    defer alloc.free(file_bytes);

    // A journal (`scrollback_journal.zig`) or, from before it existed or from
    // an explicit capture, one v1 snapshot.
    if (journal.isJournal(file_bytes)) return restoreJournal(alloc, io, path, file_bytes, t);

    var source: std.Io.Reader = .fixed(file_bytes);
    const reader = &source;

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

    resizeRestored(alloc, &old, t.cols, t.rows) catch |err|
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

/// The journal half of `restore`. `load` has already applied the pages to the
/// terminal it returns, before any resize -- order 2 above, for the same
/// reason -- so what is left is the resize and the transplant. A journal's
/// checkpoint is written with a ground continuation, so there is none to
/// drop.
fn restoreJournal(
    alloc: Allocator,
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
    t: *Terminal,
) Outcome {
    var loaded = journal.load(alloc, io, bytes) catch |err| return unreadable(io, path, err);
    defer loaded.terminal.deinit(alloc);
    if (loaded.dropped_pages > 0) log.warn(
        "scrollback journal: {} older pages not applied path={s}",
        .{ loaded.dropped_pages, path },
    );

    resizeRestored(alloc, &loaded.terminal, t.cols, t.rows) catch |err|
        return unreadable(io, path, err);
    transplantPrimary(&loaded.terminal, t);
    return .{ .restored = .{
        .history_rows = t.screens.get(.primary).?.pages.total_rows - t.rows,
        .dropped_continuation = 0,
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

    // What a new pane's cursor is, before the old one takes its place.
    const fresh = dst.cursor;

    std.mem.swap(@TypeOf(src.pages), &src.pages, &dst.pages);
    std.mem.swap(@TypeOf(src.cursor), &src.cursor, &dst.cursor);
    dst.semantic_prompt.seen = src.semantic_prompt.seen;

    dst.pages.setMaxBytes(explicit(limits.bytes.explicit));
    dst.pages.setMaxLines(explicit(limits.lines.explicit));

    restoreFreshCursor(to, dst, fresh);

    // **What was on screen goes into history, and the new shell starts on a
    // clean screen.** Restored content left in the active area belongs to
    // whatever happens there next, and on Windows that destroyed it: a
    // resize after the restore clears the old prompt's rows (they still
    // carry prompt marks, and the pane's own terminal redraws prompts), and
    // ConPTY's opening `ESC [ 2 J`, finding no prompt, discards the screen
    // rather than scrolling it (#826). In history nothing after the restore
    // can reach it -- no resize, no erase, no heuristic, no timing. The cost
    // is visible: the last screenful is one scroll up rather than on screen.
    // If this fails the restored screen stays where it was, exposed to
    // exactly what this is here to prevent -- so the log says what that
    // means for the user, not just that a call failed.
    dst.scrollClear() catch |err| log.warn(
        "restored screen could not be moved into history and stayed on screen, " ++
            "where the new shell's first clear may erase it for good err={}",
        .{err},
    );
    to.setCursorPos(1, 1);
}

/// Give the transplanted cursor back everything but its place in the pages.
///
/// **The cursor comes over with the pages only because its `page_pin` is a
/// tracked pin in their list.** The rest of it describes the old shell at the
/// moment of the snapshot, and none of that is true of the new one:
///
/// * `semantic_content` said "at a prompt, in its input". A resize acts on
///   that (`Screen.clearPromptForRedraw` walks up from the cursor to the
///   nearest prompt and clears from there down), so the host's resize after
///   a restore blanked the old prompt, already in history (#844).
/// * `protected` (DECSCA) and an OSC 8 `hyperlink` left open would be put on
///   every character the new shell prints, for the rest of the session;
///   `cursor_style` (DECSCUSR) would keep the old program's shape (#36).
///
/// So the invariant: every field is what `fresh` -- the new pane's own
/// cursor -- had, except the three pointers into the pages and
/// `hyperlink_implicit_id`, which numbers links already *in* those pages and
/// has to keep counting past them. Fields holding references are released
/// the way their owners release them: `endHyperlink` for the link,
/// `setAttribute(.unset)` for the pen. The position is set by the caller.
///
/// A field added to `Screen.Cursor` and not listed below does not compile,
/// so a new piece of shell state cannot come over silently.
fn restoreFreshCursor(to: *Terminal, dst: *terminalpkg.Screen, fresh: terminalpkg.Screen.Cursor) void {
    comptime {
        const handled = [_][]const u8{
            // Set by the caller (`setCursorPos`).
            "x",                          "y",
            // Released through their owners, below.
            "hyperlink_id",               "hyperlink",
            "style",                      "style_id",
            // Copied from `fresh`, below.
            "cursor_style",               "pending_wrap",
            "protected",                  "semantic_content",
            "semantic_content_clear_eol",
            // Kept: they belong to the pages, not to the old shell.
            "hyperlink_implicit_id",
            "page_pin",                   "page_row",
            "page_cell",
        };
        const fields = @typeInfo(terminalpkg.Screen.Cursor).@"struct".fields;
        for (fields) |f| {
            for (handled) |h| {
                if (std.mem.eql(u8, f.name, h)) break;
            } else @compileError("Screen.Cursor." ++ f.name ++
                " is not handled by restoreFreshCursor: say whether a restored pane takes it from the new pane or keeps it");
        }
        // And no name in the list that is not a field: a misspelled entry
        // would leave the real field unhandled.
        if (fields.len != handled.len) @compileError("restoreFreshCursor's field list names something Screen.Cursor does not have");
    }

    dst.endHyperlink();
    to.setAttribute(.unset) catch {};
    dst.cursor.cursor_style = fresh.cursor_style;
    dst.cursor.pending_wrap = fresh.pending_wrap;
    dst.cursor.protected = fresh.protected;
    dst.cursor.semantic_content = fresh.semantic_content;
    dst.cursor.semantic_content_clear_eol = fresh.semantic_content_clear_eol;
}

/// Resize a terminal decoded from a snapshot to the pane it is going into,
/// **without clearing its prompt for a redraw.**
///
/// `shell_redraws_prompt` records that the shell at the time would redraw its
/// prompt after a resize, and `Terminal.resize` acts on it by clearing the
/// prompt rows (`Screen.clearPromptForRedraw`). That was true when the
/// snapshot was taken and is false now: the shell it describes is gone, and
/// the new one prints its own prompt below the restored content. Left as
/// recorded, the resize erases the old prompt's text and keeps its marks,
/// and the next `ESC [ 2 J` -- ConPTY sends one to every new pane -- finds
/// no prompt to keep the screen for, and discards it (#826).
///
/// This is the only reader of the flag (`Terminal.resize`), so setting it
/// here changes nothing else. It is set on the decoded terminal only; the
/// pane's own terminal keeps its own value, because its shell is alive.
fn resizeRestored(
    alloc: Allocator,
    old: *Terminal,
    cols: terminalpkg.size.CellCountInt,
    rows: terminalpkg.size.CellCountInt,
) !void {
    old.flags.shell_redraws_prompt = .false;
    try old.resize(alloc, .{ .cols = cols, .rows = rows });
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

/// The text of the first row marked as a prompt in the active area, or null.
fn testPromptRowText(t: *Terminal, buf: []u8) ?[]const u8 {
    return testPromptRowTextIn(t, .active, buf);
}

/// The text of the last row marked as a prompt in history, or null. After a
/// restore the old prompt is there, with everything else that was on screen.
fn testHistoryPromptText(t: *Terminal, buf: []u8) ?[]const u8 {
    return testPromptRowTextIn(t, .history, buf);
}

fn testPromptRowTextIn(t: *Terminal, comptime area: enum { active, history }, buf: []u8) ?[]const u8 {
    const screen = t.screens.get(.primary).?;
    var it = switch (area) {
        .active => screen.pages.getTopLeft(.active).rowIterator(.right_down, null),
        .history => (screen.pages.getBottomRight(.history) orelse return null)
            .rowIterator(.left_up, screen.pages.getTopLeft(.history)),
    };
    while (it.next()) |p| {
        const rac = p.rowAndCell();
        if (rac.row.semantic_prompt != .prompt) continue;
        const cells = p.node.page().getCells(rac.row);
        var n: usize = 0;
        for (cells) |cell| {
            if (n == buf.len) break;
            const cp = cell.codepoint();
            buf[n] = if (cp >= 0x20 and cp < 0x7f) @intCast(cp) else ' ';
            n += 1;
        }
        return std.mem.trimEnd(u8, buf[0..n], " ");
    }
    return null;
}

/// A snapshot at 80x24 of output ending at a marked prompt.
fn testSavePrompted(path: []const u8, redraw: ?@TypeOf(@as(Terminal, undefined).flags.shell_redraws_prompt)) !void {
    var source = try testSource(80, 24, 200);
    defer source.deinit(testing.allocator);
    {
        var s = source.vtStream();
        defer s.deinit();
        s.nextSlice("\x1b]133;A\x07$ ");
    }
    if (redraw) |r| source.flags.shell_redraws_prompt = r;
    try testSave(&source, path);
}

test "restore keeps the old prompt's text, and an ED2 after it keeps the screen" {
    // The resize into the pane used to clear the prompt for a redraw by a
    // shell that no longer exists (#826).
    inline for (.{ 80, 42 }) |cols| {
        var buf: [128]u8 = undefined;
        const path = try testPath(&buf);
        defer testCleanup(path);
        try testSavePrompted(path, null);

        var t = try testFresh(cols, 20);
        defer t.deinit(testing.allocator);
        var s = t.vtStream();
        defer s.deinit();
        try testing.expect(restore(testing.allocator, testing.io, path, &t, &s) == .restored);

        // The old prompt went into history with the rest of the screen, and
        // its text came through the resize (without the fix, it is empty).
        var text: [128]u8 = undefined;
        const old_prompt = testHistoryPromptText(&t, &text);
        try testing.expect(old_prompt != null);
        try testing.expectEqualStrings("$", old_prompt.?);

        // The first thing a new pane gets on Windows.
        s.nextSlice("\x1b[H\x1b[2J");
        const dump = try testDump(&t);
        defer testing.allocator.free(dump);
        try testing.expect(std.mem.indexOf(u8, dump, "L000199") != null);
    }
}

test "a snapshot taken with shell_redraws_prompt false restores the same way" {
    var buf: [128]u8 = undefined;
    const path = try testPath(&buf);
    defer testCleanup(path);
    try testSavePrompted(path, .false);

    var t = try testFresh(80, 20);
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    try testing.expect(restore(testing.allocator, testing.io, path, &t, &s) == .restored);
    var text: [128]u8 = undefined;
    const old_prompt = testHistoryPromptText(&t, &text);
    try testing.expect(old_prompt != null);
    try testing.expectEqualStrings("$", old_prompt.?);
}

test "a decoded terminal is resized with no prompt redraw" {
    // The invariant itself, apart from any snapshot shape: whatever the
    // decoded terminal recorded, `resizeRestored` resizes it as a terminal
    // whose shell will not redraw.
    var t = try testSource(80, 24, 200);
    defer t.deinit(testing.allocator);
    {
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("\x1b]133;A\x07$ ");
    }
    try testing.expectEqual(.true, t.flags.shell_redraws_prompt);
    try resizeRestored(testing.allocator, &t, 80, 20);
    try testing.expectEqual(.false, t.flags.shell_redraws_prompt);
    var text: [128]u8 = undefined;
    const prompt = testPromptRowText(&t, &text);
    try testing.expect(prompt != null);
    try testing.expectEqualStrings("$", prompt.?);
}

test "restore leaves the pane's own prompt redraw setting alone" {
    // The new shell is alive and does redraw; only the decoded terminal's
    // record is overridden.
    var buf: [128]u8 = undefined;
    const path = try testPath(&buf);
    defer testCleanup(path);
    try testSavePrompted(path, null);

    var t = try testFresh(80, 20);
    defer t.deinit(testing.allocator);
    const own = t.flags.shell_redraws_prompt;
    var s = t.vtStream();
    defer s.deinit();
    try testing.expect(restore(testing.allocator, testing.io, path, &t, &s) == .restored);
    try testing.expectEqual(own, t.flags.shell_redraws_prompt);
}

/// How many rows up from the bottom of the active area the first row with a
/// prompt mark is, or null -- the number the #826 probes read on Windows.
fn testFirstMarkedFromBottom(t: *Terminal) ?usize {
    const pages = &t.screens.get(.primary).?.pages;
    var it = pages.getBottomRight(.active).?.rowIterator(.left_up, pages.getTopLeft(.active));
    var i: usize = 0;
    while (it.next()) |p| : (i += 1) {
        if (p.rowAndCell().row.semantic_prompt != .none) return i;
    }
    return null;
}

test "the Windows sequence: restore, a second resize, then ConPTY's ED2 (#826)" {
    // Measured on the machine: a snapshot taken at 80x24, restored into a
    // 56x18 grid, then the grid became 42x20 before the first pty byte,
    // which was `ESC [ 2 J`. Before the restored screen went straight into
    // history, that sequence lost the last screenful: `history 184 -> 184`.
    var buf: [128]u8 = undefined;
    const path = try testPath(&buf);
    defer testCleanup(path);
    try testSavePrompted(path, null);

    var t = try testFresh(56, 18);
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    try testing.expect(restore(testing.allocator, testing.io, path, &t, &s) == .restored);
    try t.resize(testing.allocator, .{ .cols = 42, .rows = 20 });

    // The fixture is the reading, or it is a different experiment.
    try testing.expectEqual(@as(u16, 42), t.cols);
    try testing.expectEqual(@as(u16, 20), t.rows);

    s.nextSlice("\x1b[2J");

    // The last screenful is in history -- every line of it.
    const history = try t.screens.get(.primary).?.dumpStringAlloc(testing.allocator, .{ .history = .{} });
    defer testing.allocator.free(history);
    var line: [16]u8 = undefined;
    for (184..200) |i| {
        const want = try std.fmt.bufPrint(&line, "L{d:0>6}", .{i});
        try testing.expect(std.mem.indexOf(u8, history, want) != null);
    }
    // A screenful more than the 184 rows that used to be all that survived.
    try testing.expect(t.screens.get(.primary).?.pages.total_rows - t.rows >= 184 + 16);
    // And the old prompt with it: the second resize must not reach into
    // history to clear it for a shell that is not there.
    var text: [128]u8 = undefined;
    const old_prompt = testHistoryPromptText(&t, &text);
    try testing.expect(old_prompt != null);
    try testing.expectEqualStrings("$", old_prompt.?);

    // And the screen is the new shell's: none of the old output is on it.
    const active = try t.screens.get(.primary).?.dumpStringAlloc(testing.allocator, .{ .active = .{} });
    defer testing.allocator.free(active);
    try testing.expect(std.mem.indexOf(u8, active, "L0") == null);
}

test "a restored pane's cursor carries none of the old shell's state (#36)" {
    // The old session left a bar cursor (DECSCUSR), protected mode on
    // (DECSCA), an OSC 8 link open, and the cursor in a prompt's input.
    var buf: [128]u8 = undefined;
    const path = try testPath(&buf);
    defer testCleanup(path);
    {
        var source = try testSource(80, 24, 30);
        defer source.deinit(testing.allocator);
        var s0 = source.vtStream();
        defer s0.deinit();
        s0.nextSlice("\x1b[5 q\x1b[1\"q\x1b]8;;https://old.example\x1b\\\x1b]133;A\x07$ \x1b]133;B\x07typing");
        const c = source.screens.get(.primary).?.cursor;
        // The fixture is what it says, or the test proves nothing.
        try testing.expectEqual(.bar, c.cursor_style);
        try testing.expect(c.protected);
        try testing.expect(c.hyperlink != null);
        try testing.expect(c.semantic_content != .output);
        try testSave(&source, path);
    }

    var t = try testFresh(80, 24);
    defer t.deinit(testing.allocator);
    const fresh = t.screens.get(.primary).?.cursor;
    var s = t.vtStream();
    defer s.deinit();
    try testing.expect(restore(testing.allocator, testing.io, path, &t, &s) == .restored);

    const c = t.screens.get(.primary).?.cursor;
    try testing.expectEqual(fresh.cursor_style, c.cursor_style);
    try testing.expectEqual(fresh.protected, c.protected);
    try testing.expectEqual(fresh.hyperlink_id, c.hyperlink_id);
    try testing.expect(c.hyperlink == null);
    try testing.expectEqual(fresh.semantic_content, c.semantic_content);

    // What the user would see: the new shell's first character is plain.
    s.nextSlice("N");
    const first = t.screens.get(.primary).?.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
    try testing.expect(!first.cell.protected);
    try testing.expect(!first.cell.hyperlink);
}
