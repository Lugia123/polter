//! A pane's scrollback, kept on disk as it happens rather than captured at
//! the end. See `dev-docs/project-scrollback.md` §3.5.
//!
//! One file, append-only between restarts:
//!
//! ```text
//! +-----------------------------+
//! | header (24 bytes)           |
//! +-----------------------------+
//! | entry: PAGE                 |  oldest completed page
//! | entry: PAGE                 |
//! | entry: CHECKPOINT           |  covers every PAGE before it
//! | entry: PAGE                 |
//! | entry: CHECKPOINT           |  the one a reader uses: the last whole one
//! | (torn tail, if a write      |
//! |  was cut short)             |
//! +-----------------------------+
//! ```
//!
//! **Why one file and not a page log beside a snapshot.** A snapshot that is
//! rewritten and a log that is appended to cannot be updated together
//! atomically: a crash between the two leaves a snapshot that disagrees with
//! the log about which page came last, and the pane comes back with a page
//! twice or a page missing -- wrong, and looking right. Here a checkpoint
//! covers exactly the pages written before it, and a write cut short is a
//! tail whose CRC fails and is ignored.
//!
//! Header, all integers little-endian:
//!
//! | Offset | Size | Field                                  |
//! | -----: | ---: | :------------------------------------- |
//! |      0 |    8 | Magic `POLTJRNL`                       |
//! |      8 |    2 | Version (`u16`), 1                     |
//! |     10 |    2 | Reserved, 0                            |
//! |     12 |    8 | Journal id (`u64`), random per restart |
//! |     20 |    4 | CRC32C of bytes 0..20                  |
//!
//! The magic is not the snapshot's `GHOSTSNP`: this is a different grammar,
//! and one magic for two grammars only gives whoever reads the wrong one a
//! baffling error.
//!
//! Entry: kind (`u8`), payload length (`u32`), CRC32C over kind, length and
//! payload (`u32`), payload. The framing is this file's own because the
//! snapshot's record tags are part of the v1 wire format.
//!
//! * PAGE: the payload is one snapshot PAGE record exactly as
//!   `snapshot.page.encode` writes it, framing and all.
//! * CHECKPOINT: `head` (`u64`), the index of the oldest PAGE still part of
//!   the scrollback; `end` (`u64`), the number of PAGEs before this
//!   checkpoint; then a whole v1 snapshot written with
//!   `max_history_bytes = 0` -- the terminal, its screens and the page the
//!   active area starts in, and no history.
//!
//! **Which pages are "completed".** Those before the page the active area
//! starts in, the same split the snapshot's HISTORY makes. The rest goes in
//! each checkpoint.
//!
//! **How a page on disk is known to still be right: page serials, not hooks.**
//! A PageList node gets a new serial whenever it is allocated, reused, or has
//! its row layout changed in place (`PageList.invalidateNodeLayout`). The
//! writer remembers the serials it wrote, and at each checkpoint requires the
//! terminal's completed pages to continue that list: evicted pages may have
//! gone from the front, new pages may follow, and nothing else. Anything else
//! -- a reflow (every page is new), `ESC [ 3 J` (pages erased or cut), **or a
//! taller window pulling history back into the active area, where the
//! program can write to it without any serial changing** -- fails that test,
//! and the journal is rewritten from the terminal. One invariant rather than
//! a hook at each event, so an event nobody thought of is caught the same
//! way.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const snapshot = terminalpkg.snapshot;
const Terminal = terminalpkg.Terminal;
const Crc32c = snapshot.record.Crc32c;

const log = std.log.scoped(.scrollback);

pub const magic = "POLTJRNL";
pub const version: u16 = 1;
pub const header_len = 24;
const entry_header_len = 9;

const Kind = enum(u8) { page = 1, checkpoint = 2 };

/// Dead bytes below this are never worth a rewrite.
const compact_floor: u64 = 1024 * 1024;

// ------------------------------------------------------------------- write

/// What the IO thread keeps between checkpoints for one pane.
pub const Writer = struct {
    /// Pages in the file, oldest first, by absolute PAGE index. Those before
    /// `head` are dead: evicted, or pushed out by the byte budget.
    written: std.ArrayListUnmanaged(Written) = .empty,
    head: usize = 0,

    /// PAGE bytes from `head` on.
    live_bytes: u64 = 0,

    /// Bytes in the file that no reader will use: dead pages and every
    /// checkpoint but the last.
    dead_bytes: u64 = 0,
    last_checkpoint_bytes: u64 = 0,

    /// Where the next entry goes. Null until the file has been (re)written
    /// by this writer, which forces the next checkpoint to be a restart.
    end_offset: ?u64 = null,

    /// The primary PageList's `resize_count` at the last checkpoint. Any
    /// resize since then may have changed a completed page in place -- a
    /// taller window and back within one period leaves every serial where it
    /// was -- so it forces a rewrite.
    resize_count: u64 = 0,

    const Written = struct { serial: u64, bytes: u64 };

    pub fn deinit(self: *Writer, alloc: Allocator) void {
        self.written.deinit(alloc);
        self.* = undefined;
    }

    /// Forget the file: the next checkpoint rewrites it.
    pub fn invalidate(self: *Writer) void {
        self.end_offset = null;
    }
};

/// A checkpoint encoded under the terminal's lock, to be written after it
/// is released.
pub const Prepared = struct {
    mode: enum { append, restart },
    bytes: []u8,

    /// The writer's state if the write succeeds.
    written: []Writer.Written,
    resize_count: u64,
    head: usize,
    live_bytes: u64,
    dead_bytes: u64,
    last_checkpoint_bytes: u64,

    pub fn deinit(self: *Prepared, alloc: Allocator) void {
        alloc.free(self.bytes);
        alloc.free(self.written);
        self.* = undefined;
    }
};

pub const PrepareError = snapshot.EncodeError || Allocator.Error;

/// Encode the next checkpoint for `t` -- only new pages and a small
/// snapshot, or a whole new file when the one on disk no longer matches or
/// is more dead than alive. `max_history_bytes` is
/// `project-scrollback-limit-bytes`. The caller holds `t`'s lock.
pub fn prepare(
    alloc: Allocator,
    io: std.Io,
    w: *const Writer,
    t: *const Terminal,
    max_history_bytes: u64,
) PrepareError!Prepared {
    const screen = t.screens.get(.primary).?;

    // The completed pages, oldest first.
    var live: std.ArrayListUnmanaged(*const PageNode) = .empty;
    defer live.deinit(alloc);
    {
        const stop = screen.pages.getTopLeft(.active).node;
        var node = screen.pages.pages.first;
        while (node) |n| : (node = n.next) {
            if (n == stop) break;
            try live.append(alloc, n);
        }
    }

    if (w.end_offset != null and w.resize_count == screen.pages.resize_count) {
        if (try prepareAppend(alloc, w, t, live.items, max_history_bytes)) |p| return p;
    }
    return prepareRestart(alloc, io, t, live.items, max_history_bytes);
}

const PageNode = terminalpkg.PageList.List.Node;

/// The append path, or null when the file has to be rewritten.
fn prepareAppend(
    alloc: Allocator,
    w: *const Writer,
    t: *const Terminal,
    live: []const *const PageNode,
    max_history_bytes: u64,
) PrepareError!?Prepared {
    const journal = w.written.items[w.head..];

    // Where the journal's live pages sit in the terminal's completed pages.
    // `new_from` is the first terminal page the journal does not have yet;
    // `evicted` is how many journal pages have left the front.
    var evicted: usize = 0;
    var new_from: usize = 0;
    if (journal.len == 0) {
        // Nothing live to line up with: every completed page is new.
        new_from = 0;
    } else if (indexOfSerial(live, journal[0].serial)) |m| {
        // The terminal may hold older pages than the journal kept; those
        // stay out. Every journal page must follow in order.
        if (live.len - m < journal.len) return null;
        for (journal, 0..) |j, i| if (live[m + i].serial != j.serial) return null;
        new_from = m + journal.len;
    } else {
        // The oldest journal pages were evicted. What is left must be the
        // start of the terminal's completed pages.
        if (live.len == 0) return null;
        const x = indexOfWritten(journal, live[0].serial) orelse return null;
        if (live.len < journal.len - x) return null;
        for (journal[x..], 0..) |j, i| if (live[i].serial != j.serial) return null;
        evicted = x;
        new_from = journal.len - x;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var written: std.ArrayListUnmanaged(Writer.Written) = .empty;
    errdefer written.deinit(alloc);
    try written.appendSlice(alloc, w.written.items);

    var head = w.head;
    var live_bytes = w.live_bytes;
    var dead_bytes = w.dead_bytes + w.last_checkpoint_bytes;
    for (0..evicted) |_| {
        live_bytes -= written.items[head].bytes;
        dead_bytes += written.items[head].bytes;
        head += 1;
    }

    for (live[new_from..]) |node| {
        const before = out.writer.end;
        try writePageEntry(alloc, &out.writer, node, t.screens.get(.primary).?.alloc);
        const bytes: u64 = out.writer.end - before;
        try written.append(alloc, .{ .serial = node.serial, .bytes = bytes });
        live_bytes += bytes;
    }

    // Keep the newest `max_history_bytes`, page by page.
    while (live_bytes > max_history_bytes and head < written.items.len) {
        live_bytes -= written.items[head].bytes;
        dead_bytes += written.items[head].bytes;
        head += 1;
    }

    // More dead than alive, and enough of it to matter: rewrite instead.
    if (dead_bytes >= live_bytes and dead_bytes >= compact_floor) {
        out.deinit();
        written.deinit(alloc);
        return null;
    }

    const checkpoint_bytes = try writeCheckpointEntry(alloc, &out.writer, t, head, written.items.len);
    return .{
        .mode = .append,
        .bytes = try out.toOwnedSlice(),
        .written = try written.toOwnedSlice(alloc),
        .resize_count = t.screens.get(.primary).?.pages.resize_count,
        .head = head,
        .live_bytes = live_bytes,
        .dead_bytes = dead_bytes,
        .last_checkpoint_bytes = checkpoint_bytes,
    };
}

/// A whole new file: the newest completed pages that fit, then a checkpoint.
fn prepareRestart(
    alloc: Allocator,
    io: std.Io,
    t: *const Terminal,
    live: []const *const PageNode,
    max_history_bytes: u64,
) PrepareError!Prepared {
    const screen_alloc = t.screens.get(.primary).?.alloc;

    // Newest first, to stop where the budget does; each page staged alone.
    var staged: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (staged.items) |s| alloc.free(s);
        staged.deinit(alloc);
    }
    var live_bytes: u64 = 0;
    var i = live.len;
    while (i > 0) {
        i -= 1;
        var one: std.Io.Writer.Allocating = .init(alloc);
        errdefer one.deinit();
        try writePageEntry(alloc, &one.writer, live[i], screen_alloc);
        const bytes: u64 = one.writer.end;
        if (live_bytes + bytes > max_history_bytes) {
            one.deinit();
            break;
        }
        live_bytes += bytes;
        try staged.append(alloc, try one.toOwnedSlice());
    }
    const first = live.len - staged.items.len;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeHeader(&out.writer, randomId(io));

    var written: std.ArrayListUnmanaged(Writer.Written) = .empty;
    errdefer written.deinit(alloc);
    // Oldest first in the file.
    var k = staged.items.len;
    while (k > 0) {
        k -= 1;
        try out.writer.writeAll(staged.items[k]);
    }
    for (live[first..], 0..) |node, n| {
        try written.append(alloc, .{
            .serial = node.serial,
            .bytes = staged.items[staged.items.len - 1 - n].len,
        });
    }

    const checkpoint_bytes = try writeCheckpointEntry(alloc, &out.writer, t, 0, written.items.len);
    return .{
        .mode = .restart,
        .bytes = try out.toOwnedSlice(),
        .written = try written.toOwnedSlice(alloc),
        .resize_count = t.screens.get(.primary).?.pages.resize_count,
        .head = 0,
        .live_bytes = live_bytes,
        .dead_bytes = 0,
        .last_checkpoint_bytes = checkpoint_bytes,
    };
}

/// Write `p` to `path` and, only if that worked, make it the writer's state.
/// A failed write leaves the file unknown, so the next checkpoint rewrites
/// it rather than appending after bytes that may not be there.
///
/// `sync` flushes an append to the disk before returning; a rewrite is
/// always flushed before it replaces the old file (see `writeWhole`).
pub fn commit(
    alloc: Allocator,
    io: std.Io,
    w: *Writer,
    path: []const u8,
    p: *Prepared,
    sync: bool,
) !void {
    errdefer w.invalidate();
    const end: u64 = switch (p.mode) {
        .restart => end: {
            try writeWhole(io, path, p.bytes);
            break :end p.bytes.len;
        },
        .append => end: {
            const at = w.end_offset.?;
            var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
            defer file.close(io);
            // Somebody else's change to the file means our offsets are wrong.
            if (try file.length(io) < at) return error.JournalChanged;
            try file.writePositionalAll(io, p.bytes, at);
            if (sync) try file.sync(io);
            break :end at + p.bytes.len;
        },
    };

    w.written.deinit(alloc);
    w.written = std.ArrayListUnmanaged(Writer.Written).fromOwnedSlice(p.written);
    p.written = &.{};
    w.resize_count = p.resize_count;
    w.head = p.head;
    w.live_bytes = p.live_bytes;
    w.dead_bytes = p.dead_bytes;
    w.last_checkpoint_bytes = p.last_checkpoint_bytes;
    w.end_offset = end;
}

fn writeWhole(io: std.Io, path: []const u8, bytes: []const u8) !void {
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
    // **Flushed before the rename, not after.** A rename that reaches the
    // disk ahead of the data it names leaves, after a power cut, an empty or
    // partial file where a whole one used to be -- the old journal replaced
    // by nothing. Rewrites are rare (a restart or a compaction), so this is
    // cheap where it is paid; appends are not flushed, and a torn tail is
    // cut off by its CRC.
    try atomic.file.sync(io);
    try atomic.replace(io);
}

fn indexOfSerial(live: []const *const PageNode, serial: u64) ?usize {
    for (live, 0..) |n, i| if (n.serial == serial) return i;
    return null;
}

fn indexOfWritten(journal: []const Writer.Written, serial: u64) ?usize {
    for (journal, 0..) |j, i| if (j.serial == serial) return i;
    return null;
}

fn randomId(io: std.Io) u64 {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    return std.mem.readInt(u64, &raw, .little);
}

fn writeHeader(out: *std.Io.Writer, id: u64) !void {
    var h: [header_len]u8 = undefined;
    @memcpy(h[0..8], magic);
    std.mem.writeInt(u16, h[8..10], version, .little);
    std.mem.writeInt(u16, h[10..12], 0, .little);
    std.mem.writeInt(u64, h[12..20], id, .little);
    std.mem.writeInt(u32, h[20..24], Crc32c.hash(h[0..20]), .little);
    try out.writeAll(&h);
}

fn writeEntry(out: *std.Io.Writer, kind: Kind, payload: []const u8) !u64 {
    const len = std.math.cast(u32, payload.len) orelse return error.PayloadTooLarge;
    var head: [entry_header_len]u8 = undefined;
    head[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, head[1..5], len, .little);
    var crc: Crc32c = .init();
    crc.update(head[0..5]);
    crc.update(payload);
    std.mem.writeInt(u32, head[5..9], crc.final(), .little);
    try out.writeAll(&head);
    try out.writeAll(payload);
    return entry_header_len + payload.len;
}

fn writePageEntry(
    alloc: Allocator,
    out: *std.Io.Writer,
    node: *const PageNode,
    screen_alloc: Allocator,
) PrepareError!void {
    var record: std.Io.Writer.Allocating = .init(alloc);
    defer record.deinit();
    {
        var records: snapshot.record.Writer = .init(alloc, &record.writer);
        defer records.deinit();
        var preserved = try node.pagePreservingState(screen_alloc);
        defer preserved.deinit();
        try snapshot.page.encode(preserved.page(), &records);
    }
    _ = writeEntry(out, .page, record.written()) catch return error.OutOfMemory;
}

fn writeCheckpointEntry(
    alloc: Allocator,
    out: *std.Io.Writer,
    t: *const Terminal,
    head: usize,
    end: usize,
) PrepareError!u64 {
    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    var fixed: [16]u8 = undefined;
    std.mem.writeInt(u64, fixed[0..8], head, .little);
    std.mem.writeInt(u64, fixed[8..16], end, .little);
    payload.writer.writeAll(&fixed) catch return error.OutOfMemory;
    snapshot.encode(alloc, &payload.writer, t, .{
        // Never resumed; see `scrollback.capture`.
        .continuation = .ground,
        .max_history_bytes = 0,
    }) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return writeEntry(out, .checkpoint, payload.written()) catch error.OutOfMemory;
}

// -------------------------------------------------------------------- read

pub fn isJournal(bytes: []const u8) bool {
    return bytes.len >= magic.len and std.mem.eql(u8, bytes[0..magic.len], magic);
}

pub const LoadError = snapshot.DecodeError || Allocator.Error || error{
    InvalidHeader,
    UnsupportedVersion,
    NoCheckpoint,
};

/// The terminal a journal describes, before it is resized or moved anywhere.
pub const Loaded = struct {
    terminal: Terminal,

    /// PAGEs the checkpoint named that were not applied: the first one that
    /// did not fit and every older one after it.
    dropped_pages: usize,
};

/// Read a journal: the last whole checkpoint's snapshot, then its pages
/// newest first. A torn tail is ignored.
pub fn load(alloc: Allocator, io: std.Io, bytes: []const u8) LoadError!Loaded {
    if (bytes.len < header_len or !isJournal(bytes)) return error.InvalidHeader;
    if (std.mem.readInt(u32, bytes[20..24], .little) != Crc32c.hash(bytes[0..20])) return error.InvalidHeader;
    if (std.mem.readInt(u16, bytes[8..10], .little) != version) return error.UnsupportedVersion;

    var pages: std.ArrayListUnmanaged([]const u8) = .empty;
    defer pages.deinit(alloc);
    var checkpoint: ?struct { head: u64, end: u64, snapshot: []const u8 } = null;

    var at: usize = header_len;
    while (bytes.len - at >= entry_header_len) {
        const kind_raw = bytes[at];
        const len = std.mem.readInt(u32, bytes[at + 1 ..][0..4], .little);
        const crc = std.mem.readInt(u32, bytes[at + 5 ..][0..4], .little);
        if (bytes.len - at - entry_header_len < len) break; // torn
        const payload = bytes[at + entry_header_len ..][0..len];
        var check: Crc32c = .init();
        check.update(bytes[at..][0..5]);
        check.update(payload);
        if (check.final() != crc) break; // torn or damaged: stop here
        at += entry_header_len + len;

        switch (std.enums.fromInt(Kind, kind_raw) orelse break) {
            .page => try pages.append(alloc, payload),
            .checkpoint => {
                if (payload.len < 16) break;
                const head = std.mem.readInt(u64, payload[0..8], .little);
                const end = std.mem.readInt(u64, payload[8..16], .little);
                if (end != pages.items.len or head > end) break;
                checkpoint = .{ .head = head, .end = end, .snapshot = payload[16..] };
            },
        }
    }
    const cp = checkpoint orelse return error.NoCheckpoint;

    var source: std.Io.Reader = .fixed(cp.snapshot);
    var decoder: snapshot.Decoder = .init(&source);
    var decoded = try decoder.ready(alloc, io, .{ .max_continuation_bytes = 64 * 1024 });
    defer decoded.deinit(alloc);
    var t = decoded.toOwned();
    errdefer t.deinit(alloc);
    // Written with no history; this only reaches FINISH.
    while (try decoder.next(alloc, &t)) |_| {}

    // Newest first, prepending. **These two rules are `Decoder.nextPage`'s,
    // and `decodePage` does not apply them, so they are here:** a page of
    // another width is not applied, and neither is anything older than a
    // page that was not applied -- an older page above a gap would put the
    // scrollback out of order and still look like a successful restore.
    const primary = t.screens.get(.primary).?;

    // **No scrollback limit while the pages go in.** The checkpoint carries
    // the limits of the config it was written under, and a restored page can
    // account for more than the same page did live, so a pane that sat near
    // its limit would come back with its oldest pages refused. Which limit
    // applies is the new pane's to say: `scrollback.transplantPrimary` sets
    // the new config's limits, and those evict what they must.
    primary.pages.setMaxBytes(null);
    primary.pages.setMaxLines(null);

    var applied: usize = 0;
    var index = cp.end;
    while (index > cp.head) {
        index -= 1;
        const page_bytes = pages.items[@intCast(index)];
        if (pageColumns(page_bytes) != t.cols) break;
        var page_source: std.Io.Reader = .fixed(page_bytes);
        _ = snapshot.history.decodePage(&page_source, alloc, primary) catch break;
        applied += 1;
    }

    return .{
        .terminal = t,
        .dropped_pages = @intCast(cp.end - cp.head - applied),
    };
}

/// The column count in a PAGE record's header, or null if it is too short.
fn pageColumns(page_record: []const u8) ?u16 {
    const at = snapshot.record.Header.len;
    if (page_record.len < at + 2) return null;
    return std.mem.readInt(u16, page_record[at..][0..2], .little);
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// A live terminal with its own stream, a journal writer, and a file.
const Harness = struct {
    t: *Terminal,
    s: terminalpkg.TerminalStream,
    w: Writer = .{},
    path_buf: [128]u8 = undefined,
    path: []const u8 = "",

    fn create(cols: u16, rows: u16) !*Harness {
        const h = try testing.allocator.create(Harness);
        errdefer testing.allocator.destroy(h);
        h.* = .{ .t = undefined, .s = undefined };
        h.t = try testing.allocator.create(Terminal);
        errdefer testing.allocator.destroy(h.t);
        h.t.* = try Terminal.init(testing.io, testing.allocator, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback_bytes = null,
        });
        h.s = h.t.vtStream();
        var raw: [6]u8 = undefined;
        testing.io.random(&raw);
        h.path = try std.fmt.bufPrint(&h.path_buf, "/tmp/polter-journal-{x}/0.snap", .{&raw});
        return h;
    }

    fn destroy(h: *Harness) void {
        std.Io.Dir.cwd().deleteTree(testing.io, std.fs.path.dirname(h.path).?) catch {};
        h.w.deinit(testing.allocator);
        h.s.deinit();
        h.t.deinit(testing.allocator);
        testing.allocator.destroy(h.t);
        testing.allocator.destroy(h);
    }

    fn feed(h: *Harness, bytes: []const u8) void {
        h.s.nextSlice(bytes);
    }

    fn lines(h: *Harness, from: usize, n: usize) !void {
        var buf: [32]u8 = undefined;
        for (from..from + n) |i| h.feed(try std.fmt.bufPrint(&buf, "L{d:0>6}\r\n", .{i}));
    }

    /// Numbered lines until at least `pages` pages are complete, so a test
    /// has history pages to lose without writing more than it needs.
    /// Returns the next line number.
    fn fill(h: *Harness, from: usize, pages: usize) !usize {
        var line = from;
        while (completedPages(h.t) < pages) {
            try h.lines(line, 200);
            line += 200;
        }
        return line;
    }

    /// One checkpoint; returns whether it rewrote the file.
    fn tick(h: *Harness, max: u64) !enum { append, restart } {
        var p = try prepare(testing.allocator, testing.io, &h.w, h.t, max);
        defer p.deinit(testing.allocator);
        const mode = p.mode;
        try commit(testing.allocator, testing.io, &h.w, h.path, &p, false);
        return switch (mode) {
            .append => .append,
            .restart => .restart,
        };
    }

    fn file(h: *Harness) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, h.path, testing.allocator, .unlimited);
    }
};

fn dump(t: *Terminal) ![]const u8 {
    return t.screens.get(.primary).?.dumpStringAlloc(testing.allocator, .{ .screen = .{} });
}

/// The oracle: what the journal restores is exactly the live terminal's
/// primary screen, history and all.
fn expectRestoresLive(h: *Harness) !void {
    const bytes = try h.file();
    defer testing.allocator.free(bytes);
    var loaded = try load(testing.allocator, testing.io, bytes);
    defer loaded.terminal.deinit(testing.allocator);
    try testing.expectEqual(h.t.cols, loaded.terminal.cols);
    try testing.expectEqual(@as(usize, 0), loaded.dropped_pages);
    const want = try dump(h.t);
    defer testing.allocator.free(want);
    const got = try dump(&loaded.terminal);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

const unlimited: u64 = std.math.maxInt(u64);

fn completedPages(t: *Terminal) usize {
    const pages = &t.screens.get(.primary).?.pages;
    const stop = pages.getTopLeft(.active).node;
    var n: usize = 0;
    var node = pages.pages.first;
    while (node) |x| : (node = x.next) {
        if (x == stop) break;
        n += 1;
    }
    return n;
}

test "journal: appends new pages and restores the live terminal" {
    const h = try Harness.create(80, 24);
    defer h.destroy();
    _ = try h.fill(0, 4);
    try testing.expect(completedPages(h.t) >= 3);
    try testing.expectEqual(.restart, try h.tick(unlimited));
    try expectRestoresLive(h);

    const before = h.w.end_offset.?;
    _ = try h.fill(1_000_000, completedPages(h.t) + 2);
    try testing.expectEqual(.append, try h.tick(unlimited));
    try expectRestoresLive(h);
    try testing.expect(h.w.end_offset.? > before);
}

test "journal: a reflow rewrites the file (F-reflow)" {
    const h = try Harness.create(80, 24);
    defer h.destroy();
    _ = try h.fill(0, 4);
    _ = try h.tick(unlimited);
    try h.t.resize(testing.allocator, .{ .cols = 50, .rows = 24 });
    try h.lines(1_000_000, 2_000);
    // The oracle first: what a floor has to redden is the content.
    const mode = try h.tick(unlimited);
    try expectRestoresLive(h);
    try testing.expectEqual(.restart, mode);
}

test "journal: ESC [ 3 J rewrites the file (F-erase)" {
    const h = try Harness.create(80, 24);
    defer h.destroy();
    _ = try h.fill(0, 4);
    _ = try h.tick(unlimited);
    h.feed("\x1b[3J");
    try h.lines(1_000_000, 2_000);
    const mode = try h.tick(unlimited);
    try expectRestoresLive(h);
    try testing.expectEqual(.restart, mode);
}

test "journal: a checkpoint while history is pulled into a taller window (F-taller, during)" {
    const h = try Harness.create(80, 24);
    defer h.destroy();
    _ = try h.fill(0, 4);
    _ = try h.tick(unlimited);
    const completed = completedPages(h.t);

    // Taller by far more than a page: completed pages become active rows,
    // keeping their serials, and a program writes over them.
    try h.t.resize(testing.allocator, .{ .cols = 80, .rows = 1000 });
    try testing.expect(completedPages(h.t) < completed);
    h.feed("\x1b[1;1HOVERWRITTEN-IN-WHAT-WAS-HISTORY\x1b[1000;1H");
    _ = try h.tick(unlimited);
    try expectRestoresLive(h);
}

test "journal: taller and back within one period (F-taller, between)" {
    const h = try Harness.create(80, 24);
    defer h.destroy();
    _ = try h.fill(0, 4);
    _ = try h.tick(unlimited);

    // The same, but the window is back before the next checkpoint: every
    // serial is where it was, and one page's content is not.
    try h.t.resize(testing.allocator, .{ .cols = 80, .rows = 1000 });
    h.feed("\x1b[1;1HOVERWRITTEN-IN-WHAT-WAS-HISTORY\x1b[1000;1H");
    try h.t.resize(testing.allocator, .{ .cols = 80, .rows = 24 });
    _ = try h.tick(unlimited);
    try expectRestoresLive(h);
}

test "journal: the newest pages that fit the budget, exactly (F-cap)" {
    const h = try Harness.create(80, 24);
    defer h.destroy();
    _ = try h.fill(0, 4);
    _ = try h.tick(unlimited);
    const all = h.w.live_bytes;
    const n = h.w.written.items.len;
    try testing.expect(n >= 3);
    // The newest two pages' bytes exactly: two pages kept; one byte less, one.
    const two = h.w.written.items[n - 1].bytes + h.w.written.items[n - 2].bytes;
    try testing.expect(two < all);

    inline for (.{ .{ two, 2 }, .{ two - 1, 1 } }) |c| {
        h.w.invalidate();
        _ = try h.tick(c[0]);
        try testing.expectEqual(@as(usize, c[1]), h.w.written.items.len - h.w.head);
        const bytes = try h.file();
        defer testing.allocator.free(bytes);
        var loaded = try load(testing.allocator, testing.io, bytes);
        defer loaded.terminal.deinit(testing.allocator);
        const want = try dump(h.t);
        defer testing.allocator.free(want);
        const got = try dump(&loaded.terminal);
        defer testing.allocator.free(got);
        // What comes back is the live terminal's most recent part.
        try testing.expect(std.mem.endsWith(u8, want, got));
        try testing.expect(got.len < want.len);
    }
}

test "journal: a torn tail restores the checkpoint before it (F-torn)" {
    const h = try Harness.create(80, 24);
    defer h.destroy();
    _ = try h.fill(0, 4);
    _ = try h.tick(unlimited);
    const at_first = try dump(h.t);
    defer testing.allocator.free(at_first);

    try h.lines(1_000_000, 5_000);
    try testing.expectEqual(.append, try h.tick(unlimited));
    const whole = try h.file();
    defer testing.allocator.free(whole);

    // Two ways a crash leaves the last write: cut short, or whole in length
    // with a byte that never made it. The reader has one branch for each.
    const Tail = enum { short, damaged };
    for (std.enums.values(Tail)) |tail| {
        const bytes = try testing.allocator.dupe(u8, whole);
        defer testing.allocator.free(bytes);
        const torn: []const u8 = switch (tail) {
            .short => bytes[0 .. bytes.len - 7],
            .damaged => damaged: {
                bytes[bytes.len - 7] ^= 0xff;
                break :damaged bytes;
            },
        };
        // Each case says which one it was when it fails, so a floor that
        // reddens here does not have to be traced back by construction.
        errdefer std.debug.print("F-torn failed in the {s} case\n", .{@tagName(tail)});
        var loaded = try load(testing.allocator, testing.io, torn);
        defer loaded.terminal.deinit(testing.allocator);
        const got = try dump(&loaded.terminal);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(at_first, got);
    }
}

/// The entries of a journal file, for tests that take one apart.
const TestEntry = struct { kind: Kind, payload: []const u8 };

fn testEntries(bytes: []const u8, out: *std.ArrayListUnmanaged(TestEntry)) !void {
    var at: usize = header_len;
    while (at < bytes.len) {
        const kind: Kind = @enumFromInt(bytes[at]);
        const len = std.mem.readInt(u32, bytes[at + 1 ..][0..4], .little);
        try out.append(testing.allocator, .{ .kind = kind, .payload = bytes[at + entry_header_len ..][0..len] });
        at += entry_header_len + len;
    }
}

fn testCheckpoint(out: *std.Io.Writer, head: u64, end: u64, snapshot_bytes: []const u8) !void {
    var payload: std.Io.Writer.Allocating = .init(testing.allocator);
    defer payload.deinit();
    var fixed: [16]u8 = undefined;
    std.mem.writeInt(u64, fixed[0..8], head, .little);
    std.mem.writeInt(u64, fixed[8..16], end, .little);
    try payload.writer.writeAll(&fixed);
    try payload.writer.writeAll(snapshot_bytes);
    _ = try writeEntry(out, .checkpoint, payload.written());
}

test "journal: pages of another width end the walk (F-width)" {
    // 80-column pages, then 50-column pages and a 50-column checkpoint, as
    // one file. Only the 50-column pages may be applied.
    const wide = try Harness.create(80, 24);
    defer wide.destroy();
    _ = try wide.fill(0, 4);
    _ = try wide.tick(unlimited);
    const narrow = try Harness.create(50, 24);
    defer narrow.destroy();
    _ = try narrow.fill(0, 4);
    _ = try narrow.tick(unlimited);

    const wide_bytes = try wide.file();
    defer testing.allocator.free(wide_bytes);
    const narrow_bytes = try narrow.file();
    defer testing.allocator.free(narrow_bytes);
    var wide_entries: std.ArrayListUnmanaged(TestEntry) = .empty;
    defer wide_entries.deinit(testing.allocator);
    try testEntries(wide_bytes, &wide_entries);
    var narrow_entries: std.ArrayListUnmanaged(TestEntry) = .empty;
    defer narrow_entries.deinit(testing.allocator);
    try testEntries(narrow_bytes, &narrow_entries);

    var mixed: std.Io.Writer.Allocating = .init(testing.allocator);
    defer mixed.deinit();
    try mixed.writer.writeAll(narrow_bytes[0..header_len]);
    var n: u64 = 0;
    var narrow_pages: u64 = 0;
    for (wide_entries.items) |e| if (e.kind == .page) {
        _ = try writeEntry(&mixed.writer, .page, e.payload);
        n += 1;
    };
    var snap: []const u8 = "";
    for (narrow_entries.items) |e| switch (e.kind) {
        .page => {
            _ = try writeEntry(&mixed.writer, .page, e.payload);
            n += 1;
            narrow_pages += 1;
        },
        .checkpoint => snap = e.payload[16..],
    };
    try testing.expect(narrow_pages >= 2);
    try testCheckpoint(&mixed.writer, 0, n, snap);

    var loaded = try load(testing.allocator, testing.io, mixed.written());
    defer loaded.terminal.deinit(testing.allocator);
    const want = try dump(narrow.t);
    defer testing.allocator.free(want);
    const got = try dump(&loaded.terminal);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
    try testing.expectEqual(@as(usize, @intCast(n - narrow_pages)), loaded.dropped_pages);
}

test "journal: a page that will not decode ends the walk (F-gap)" {
    const h = try Harness.create(80, 24);
    defer h.destroy();
    _ = try h.fill(0, 4);
    _ = try h.tick(unlimited);
    const bytes = try h.file();
    defer testing.allocator.free(bytes);
    var entries: std.ArrayListUnmanaged(TestEntry) = .empty;
    defer entries.deinit(testing.allocator);
    try testEntries(bytes, &entries);

    // Rebuild the file with the second-newest page's inner record damaged,
    // under an outer CRC that is correct: whole on disk, useless inside.
    var pages: usize = 0;
    for (entries.items) |e| {
        if (e.kind == .page) pages += 1;
    }
    try testing.expect(pages >= 3);
    const damaged_index = pages - 2;
    var rebuilt: std.Io.Writer.Allocating = .init(testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.writer.writeAll(bytes[0..header_len]);
    var i: usize = 0;
    for (entries.items) |e| switch (e.kind) {
        .page => {
            if (i == damaged_index) {
                const copy = try testing.allocator.dupe(u8, e.payload);
                defer testing.allocator.free(copy);
                copy[copy.len - 1] ^= 0xff;
                _ = try writeEntry(&rebuilt.writer, .page, copy);
            } else _ = try writeEntry(&rebuilt.writer, .page, e.payload);
            i += 1;
        },
        .checkpoint => _ = try writeEntry(&rebuilt.writer, .checkpoint, e.payload),
    };

    var loaded = try load(testing.allocator, testing.io, rebuilt.written());
    defer loaded.terminal.deinit(testing.allocator);
    // Only the newest page is above the gap; everything older stays out.
    // Content first: an older page applied above the gap makes what comes
    // back something that is not the end of the live screen.
    const want = try dump(h.t);
    defer testing.allocator.free(want);
    const got = try dump(&loaded.terminal);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.endsWith(u8, want, got));
    try testing.expectEqual(pages - 1, loaded.dropped_pages);
}

test "journal: across a restore, and what the new shell sends next (F-after-restore)" {
    // Every way the first frame after a restore has been seen or suspected
    // to take the screen away, through the journal's restore path. The
    // restored screen goes straight into history (`scrollback.transplantPrimary`),
    // so only a full reset may take it; and journaling the pane afterwards
    // must give back exactly the pane as it then is.
    const Grid = enum {
        /// Restored into a pane of the saved size.
        same,
        /// What Windows did (#826): restored into 56x18, then resized to
        /// 42x20 by the host before the first pty byte.
        windows,
    };
    const Next = struct {
        marked: bool,
        grid: Grid = .same,
        bytes: []const u8,
        /// Whether the last saved line is still in the pane afterwards.
        keeps_old: bool,
    };
    const blank_screen = "\x1b[H" ++ (" " ** 80 ++ "\r\n") ** 23 ++ " " ** 80 ++ "\x1b[H";
    const erase_lines = "\x1b[H" ++ "\x1b[K\r\n" ** 23 ++ "\x1b[K\x1b[H";
    const cases = [_]Next{
        .{ .marked = false, .bytes = "\x1b[H\x1b[2J", .keeps_old = true }, // ED2, not at a prompt
        .{ .marked = true, .bytes = "\x1b[H\x1b[2J", .keeps_old = true }, // ED2 at a marked prompt
        .{ .marked = true, .grid = .windows, .bytes = "\x1b[2J", .keeps_old = true }, // as measured
        .{ .marked = true, .bytes = blank_screen, .keeps_old = true }, // spaces over the screen
        .{ .marked = true, .bytes = erase_lines, .keeps_old = true }, // EL on every line
        .{ .marked = true, .bytes = "\x1bc", .keeps_old = false }, // RIS clears history too
    };
    for (cases) |c| {
        const before = try Harness.create(80, 24);
        defer before.destroy();
        const next = try before.fill(0, 4);
        if (c.marked) before.feed("\x1b]133;A\x07$ ");
        _ = try before.tick(unlimited);
        var last_buf: [16]u8 = undefined;
        const last = try std.fmt.bufPrint(&last_buf, "L{d:0>6}", .{next - 1});

        // A new pane restored from that journal, through the product path.
        const after = switch (c.grid) {
            .same => try Harness.create(80, 24),
            .windows => try Harness.create(56, 18),
        };
        defer after.destroy();
        try testing.expect(@import("scrollback.zig").restore(
            testing.allocator,
            testing.io,
            before.path,
            after.t,
            &after.s,
        ) == .restored);
        if (c.grid == .windows) try after.t.resize(testing.allocator, .{ .cols = 42, .rows = 20 });

        // The fixture says which shape it built before anything else, or it
        // is a different experiment from the one it is named after: the old
        // output is all in history and none of it on screen.
        if (c.grid == .windows) {
            try testing.expectEqual(@as(u16, 42), after.t.cols);
            try testing.expectEqual(@as(u16, 20), after.t.rows);
        }
        {
            const primary = after.t.screens.get(.primary).?;
            const active = try primary.dumpStringAlloc(testing.allocator, .{ .active = .{} });
            defer testing.allocator.free(active);
            try testing.expect(std.mem.indexOf(u8, active, "L0") == null);
            const history = try primary.dumpStringAlloc(testing.allocator, .{ .history = .{} });
            defer testing.allocator.free(history);
            try testing.expect(std.mem.indexOf(u8, history, last) != null);
            // The old prompt's text came through the restore's resize.
            if (c.marked) try testing.expect(std.mem.indexOf(u8, history, "\n$") != null);
        }

        // The new side's first bytes, then some output.
        after.feed(c.bytes);
        try after.lines(1_000_000, 500);

        const live = try dump(after.t);
        defer testing.allocator.free(live);
        try testing.expectEqual(c.keeps_old, std.mem.indexOf(u8, live, last) != null);

        // Journaling the restored pane gives back exactly that pane, and
        // keeps doing so as it goes on.
        _ = try after.tick(unlimited);
        try expectRestoresLive(after);
        _ = try after.fill(2_000_000, completedPages(after.t) + 2);
        try testing.expectEqual(.append, try after.tick(unlimited));
        try expectRestoresLive(after);
    }
}

test "journal: random sequences restore exactly what was live" {
    // Seeds are fixed so a failure replays. Every operation a pane sees in
    // use, with a checkpoint every few, compared each time.
    for (0..4) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const r = prng.random();
        const h = try Harness.create(80, 24);
        defer h.destroy();
        // Half the runs with a small scrollback, so eviction happens.
        if (seed % 2 == 1) h.t.screens.get(.primary).?.pages.setMaxBytes(3 * 1024 * 1024);
        var line: usize = 0;
        for (0..30) |_| {
            switch (r.uintLessThan(u8, 10)) {
                0...3 => {
                    const n = r.uintLessThan(usize, 1000);
                    try h.lines(line, n);
                    line += n;
                },
                4 => {
                    h.feed("\x1b[999;1H");
                    try h.t.resize(testing.allocator, .{
                        .cols = r.intRangeAtMost(u16, 30, 140),
                        .rows = h.t.rows,
                    });
                },
                5 => {
                    h.feed("\x1b[999;1H");
                    try h.t.resize(testing.allocator, .{
                        .cols = h.t.cols,
                        .rows = r.intRangeAtMost(u16, 5, 400),
                    });
                    h.feed("\x1b[999;1H");
                },
                6 => h.feed(switch (r.uintLessThan(u8, 3)) {
                    0 => "\x1b[3J",
                    1 => "\x1b[H\x1b[2J",
                    else => "\x1b]133;A\x07$ \x1b[H\x1b[2J",
                }),
                7 => h.feed("\x1b[5;3HPOKED\x1b[999;1H"),
                8 => _ = h.t.screens.get(.primary).?.pages.compress(.full),
                else => {},
            }
            if (r.uintLessThan(u8, 3) == 0) {
                _ = try h.tick(unlimited);
                try expectRestoresLive(h);
            }
        }
        _ = try h.tick(unlimited);
        try expectRestoresLive(h);
    }
}

test "journal: cut short anywhere, a restore is whole or nothing" {
    // A write interrupted by a crash or a power cut is this feature's usual
    // case, not an edge one. Three places to be cut: right after the header,
    // in the middle of the first page, and just before a later checkpoint.
    const h = try Harness.create(80, 24);
    defer h.destroy();
    _ = try h.fill(0, 4);
    _ = try h.tick(unlimited);
    const first_len = h.w.end_offset.?;
    const at_first = try dump(h.t);
    defer testing.allocator.free(at_first);
    try h.lines(1_000_000, 3_000);
    try testing.expectEqual(.append, try h.tick(unlimited));
    const whole = try h.file();
    defer testing.allocator.free(whole);

    var entries: std.ArrayListUnmanaged(TestEntry) = .empty;
    defer entries.deinit(testing.allocator);
    try testEntries(whole, &entries);
    const first_page_len = entries.items[0].payload.len;
    try testing.expectEqual(Kind.page, entries.items[0].kind);

    const Cut = struct { name: []const u8, len: usize, restores_first: bool };
    const cuts = [_]Cut{
        .{ .name = "after the header", .len = header_len, .restores_first = false },
        .{ .name = "in the first page", .len = header_len + entry_header_len + first_page_len / 2, .restores_first = false },
        .{ .name = "before the last checkpoint", .len = whole.len - 1, .restores_first = true },
        .{ .name = "just after the first checkpoint", .len = first_len + 3, .restores_first = true },
    };
    for (cuts) |cut| {
        errdefer std.debug.print("cut {s} failed\n", .{cut.name});
        var buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}.cut.snap", .{h.path});
        try writeWhole(testing.io, path, whole[0..cut.len]);
        defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};

        var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = null });
        defer t.deinit(testing.allocator);
        var s = t.vtStream();
        defer s.deinit();
        const outcome = @import("scrollback.zig").restore(testing.allocator, testing.io, path, &t, &s);
        if (cut.restores_first) {
            try testing.expect(outcome == .restored);
            // Exactly the first checkpoint: every one of its lines, and
            // nothing from the write that was cut.
            const got = try dump(&t);
            defer testing.allocator.free(got);
            try testing.expect(std.mem.indexOf(u8, got, "L1000000") == null);
            const lastline = std.mem.trimEnd(u8, at_first, "\n ");
            const tail = lastline[std.mem.lastIndexOfScalar(u8, lastline, '\n').? + 1 ..];
            try testing.expect(std.mem.indexOf(u8, got, tail) != null);
        } else {
            // No whole checkpoint: nothing restored, the pane is empty, and
            // the file is gone rather than tried again.
            try testing.expect(outcome == .unreadable);
            try testing.expectEqual(t.rows, t.screens.get(.primary).?.pages.total_rows);
        }
    }
}

test "journal: a journal cut short where a v1 snapshot used to be" {
    // The path held a whole v1 snapshot (from before journals, or an old
    // capture); then journaling took it over, and its last append was cut.
    const h = try Harness.create(80, 24);
    defer h.destroy();
    _ = try h.fill(0, 4);
    {
        const v1 = try @import("scrollback.zig").capture(testing.allocator, h.t, unlimited);
        defer testing.allocator.free(v1);
        try writeWhole(testing.io, h.path, v1);
    }
    h.feed("AFTER-V1\r\n");
    _ = try h.tick(unlimited); // restart: replaces the v1 file whole
    const at_journal = try dump(h.t);
    defer testing.allocator.free(at_journal);
    try h.lines(1_000_000, 3_000);
    _ = try h.tick(unlimited); // append
    const whole = try h.file();
    defer testing.allocator.free(whole);
    try writeWhole(testing.io, h.path, whole[0 .. whole.len - 5]);

    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = null });
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    try testing.expect(@import("scrollback.zig").restore(testing.allocator, testing.io, h.path, &t, &s) == .restored);
    const got = try dump(&t);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "AFTER-V1") != null);
    try testing.expect(std.mem.indexOf(u8, got, "L1000000") == null);
}
