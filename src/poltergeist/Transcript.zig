//! What actually ran in a terminal, written down by the terminal.
//!
//! `ChatLog` records what the agents *said to each other*. Nothing recorded
//! what any of them *did*: the next morning, "why did this thing start
//! looping at two in the morning" could only be answered out of the agent's
//! own account of itself.
//!
//! It has to be Polter that keeps this. Claude Code has a transcript of its
//! own, Codex has a different one, and an `npm run build`, a `cargo test` or
//! a hand-typed `ssh` has none at all -- so a record assembled out of what
//! the hosted programs happen to save is a record that exists for the
//! programs that happen to save one. Polter is the terminal: every byte
//! passes through it, which makes it the only place on the machine where one
//! record can be true of everything.
//!
//! ## What is recorded, and what that costs
//!
//! **The lines that have scrolled out of the active screen**, not the raw
//! pty byte stream.
//!
//! The raw stream is complete and replayable, and its size is set by the
//! hosted program's refresh rate rather than by its content: a spinner at
//! 10fps for eight hours is hundreds of megabytes carrying no information.
//! A committed line has already had the redraws taken out of it -- a spinner
//! that turned a hundred thousand times leaves one line -- so what lands
//! here is what was actually *output*, not what the screen did.
//!
//! Two consequences worth stating plainly rather than discovering later:
//!
//!   * **A full-screen program leaves almost nothing.** `vim`, `htop`, and
//!     anything else on the alternate screen do not write to scrollback, so
//!     they are nearly blank in the transcript. That is the intended
//!     behaviour -- nobody wants every frame of `htop` -- but it looks like
//!     a gap unless it is written down, so here it is written down.
//!
//!   * **The last screenful arrives late.** A line is recorded once it has
//!     scrolled out; what is still on the active screen is written when the
//!     terminal closes. `record` takes the boundary as an argument precisely
//!     so the shutdown path can ask for the wider one.
//!
//! ## Secrets
//!
//! There is no redaction, deliberately. A scrubber that catches nine keys
//! in ten is worse than none: it creates the belief that the file is safe to
//! pass around, and the tenth key gets passed around with it. This is a
//! local file about local work -- `0600`, on by default, and possible to
//! turn off (`poltergeist-terminal-log`). Treat it the way you would treat
//! your shell history.
//!
//! The layout is the chat record's, through the same `daylog` code:
//! `~/.local/state/polter/terminals/<terminal>/<YYYY-MM-DD>.jsonl`, one JSON
//! object per line. Sharing that code is not tidiness -- a second encoding
//! of names into directories would mean two rules disagreeing about where a
//! given terminal's files live.

const Transcript = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const terminal = @import("../terminal/main.zig");
const daylog = @import("daylog.zig");

const log = std.log.scoped(.poltergeist);

/// How long a run of output may go on before the lines it has already
/// committed are put on disk.
///
/// This is not a deadline for anything; it only bounds how much is held in
/// the scrollback and not yet in the file while output keeps arriving. Small
/// enough that a crash loses a fraction of a second, large enough that a
/// program printing a megabyte does not turn into a write per read.
pub const flush_ms: i64 = 250;

/// Most of one line that reaches the file.
///
/// A line longer than this is cut rather than dropped: that something very
/// long was printed is itself worth knowing, and a record that silently
/// omits the one enormous line is a record that lies about what happened.
const max_line: usize = 16 * 1024;

/// How many rows are turned into text at a time.
///
/// The work is bounded per batch so that a terminal which has been
/// scrolling for a while does not become one enormous allocation the first
/// time it is drained.
const batch_rows: usize = 256;

alloc: Allocator,
io: std.Io,

/// `<state>/terminals`. Owned.
dir: []const u8,

/// This terminal's own name, before encoding. Owned.
name: []const u8,

/// The identity half of the name, kept so the readable half can be added
/// later. See `rename`.
id: u64,

/// Whether anything has been written under `name` yet.
///
/// A name is a directory, so it may only be settled once: renaming after
/// the first line would leave one night's work split across two places with
/// nothing saying they belong together.
settled: bool = false,

tree: daylog.Tree,

/// The first row not yet written down.
///
/// Tracked by the page list rather than held as a plain position, so that
/// trimming the scrollback moves it forward instead of leaving it pointing
/// into a page that has been freed. Null until the first `record`: there is
/// no screen to put it in before then.
///
/// A pin that gets moved by trimming is a transcript missing the lines that
/// were trimmed -- which is the truthful outcome, because those lines are
/// gone from the terminal too.
pin: ?*terminal.Pin = null,

/// When the last drain happened, on the caller's monotonic clock, so that a
/// burst does not turn into one write per read.
///
/// Monotonic rather than wall: the throttle is asking "how long since", and
/// a clock that can be set backwards would answer that wrong. The wall clock
/// is read only when a drain actually happens, which is at most once every
/// `flush_ms` -- so the syscall is not on the hot path either.
last_mono_ms: i64 = 0,

/// Scratch for turning rows into text. Kept across drains so that a busy
/// terminal is not reallocating on every one.
scratch: std.ArrayListUnmanaged(u8) = .empty,

/// Whether the record has been closed by `finish`.
///
/// The last screenful can only be written once. Recording it twice would
/// not be harmless: at the very bottom of the page list there is no row
/// below the last one, so `record` leaves the pin *on* it rather than past
/// it, and a second pass repeats that row. Two ends can both plausibly
/// arrive -- the pty hangs up and then the surface is torn down -- so
/// whichever gets here first is the one that closes the record.
closed: bool = false,

/// Read and write failures are said once and then swallowed, like the chat
/// log's: a full disk must not be allowed to disturb the terminal it is
/// only supposed to be watching.
warned: bool = false,

pub const Error = Allocator.Error || error{XdgLookupFailed};

/// Where a terminal's transcript lives. Caller owns it.
pub fn defaultDir(alloc: Allocator, state_dir: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(alloc, &.{ state_dir, "terminals" });
}

/// The wall clock in Unix milliseconds, which is what a record is dated by.
///
/// Wall rather than monotonic because the question this file answers is
/// "what was happening at two in the morning", and a monotonic clock cannot
/// be asked that. The implementation is `daylog`'s, beside the `dayOf` that
/// turns this into a filename -- one clock, one answer.
const nowMs = daylog.nowMs;

/// The directory name one terminal gets.
///
/// The id first because it is what stays the same -- a title is whatever
/// the shell last set it to, and a directory keyed on that would split one
/// terminal's night across a directory per `cd`. The title comes after it
/// anyway, taken once at startup, because `ls` on a directory of bare hex
/// is not something anybody can use at nine the next morning.
///
/// Two terminals therefore never share a directory, and one terminal never
/// gets a second one while it lives. Across a restart the id is new, so
/// last night and this morning are two directories -- which is honest:
/// they were two terminals.
pub fn nameOf(
    alloc: Allocator,
    id: u64,
    title: []const u8,
) Allocator.Error![]const u8 {
    if (title.len == 0) return std.fmt.allocPrint(alloc, "{x:0>16}", .{id});
    return std.fmt.allocPrint(alloc, "{x:0>16}-{s}", .{ id, title });
}

/// Put a readable half on the name, if it does not have one and nothing
/// has been written yet.
///
/// A terminal has no title when it starts -- the shell sets one a moment
/// later -- so a name taken at startup would be bare hex for almost every
/// terminal there is. Taking it at the first line written gets the title
/// that exists by then, and refusing to take a second one keeps a
/// directory from moving out from under a night's work when the shell
/// retitles itself on every `cd`.
pub fn rename(self: *Transcript, title: []const u8) void {
    if (self.settled or title.len == 0) return;

    const next = nameOf(self.alloc, self.id, title) catch return;
    self.alloc.free(self.name);
    self.name = next;
}

pub fn open(
    alloc: Allocator,
    io: std.Io,
    state_dir: []const u8,
    id: u64,
    title: []const u8,
) Error!Transcript {
    const dir = try defaultDir(alloc, state_dir);
    errdefer alloc.free(dir);

    const name = try nameOf(alloc, id, title);
    errdefer alloc.free(name);

    return .{
        .alloc = alloc,
        .io = io,
        .dir = dir,
        .name = name,
        .id = id,
        .tree = .{
            .alloc = alloc,
            .io = io,
            .dir = dir,
            .label = "terminal log",
            // Nothing here carries a sequence number, so there is nothing
            // for `Tree.head` to find and nothing that would want it: the
            // transcript is never filled in after the fact from somewhere
            // else, because there is nowhere else.
            .probe = null,
        },
    };
}

/// Write down whatever is left, let go of the pin, and free everything.
///
/// `screen` is optional because a terminal being torn down may already have
/// gone; when it is there this is the one chance to record the last
/// screenful, which by definition has never scrolled out.
pub fn deinit(self: *Transcript, screen: ?*const terminal.Screen) void {
    if (screen) |s| {
        // The other order: a surface torn down while its child is still
        // running never reaches `finish`, and here the teardown really is
        // the last chance. When the pty already hung up this does nothing,
        // which is the point of the flag it goes through.
        self.finish(s, "");
        if (self.pin) |p| {
            // Casting away const: untracking mutates the page list's own
            // bookkeeping, not the screen's contents, and the caller has
            // the lock either way.
            const pages: *terminal.PageList = @constCast(&s.pages);
            pages.untrackPin(p);
        }
    }
    self.pin = null;

    self.tree.deinit();
    self.scratch.deinit(self.alloc);
    self.alloc.free(self.name);
    self.alloc.free(self.dir);
    self.* = undefined;
}

/// The hot path's entry point: record if enough time has gone by.
///
/// Called from `Termio.processOutputLocked`, which is on the IO thread and
/// is the one piece of this design that must not get slower. Everything
/// costly is behind the clock comparison, so an ordinary read that is not
/// due pays one subtract and one branch.
///
/// The work that does happen is proportional to output actually committed,
/// never to bytes seen -- a program redrawing itself forever commits
/// nothing and so costs nothing here.
///
/// This is only the leading edge of the rate limit, and on its own it is
/// not enough: see `flush` for why, and for what closes the window this
/// opens.
pub fn note(
    self: *Transcript,
    screen: *const terminal.Screen,
    title: []const u8,
    mono_ms: i64,
) void {
    if (mono_ms -| self.last_mono_ms < flush_ms) return;
    self.last_mono_ms = mono_ms;

    // Here rather than on every read: until the first line is written this
    // allocates, and the hot path should not pay for that once per pty
    // read just to be told the name has not changed.
    self.rename(title);

    self.record(screen, nowMs(self.io), .history);
}

/// The trailing edge of the same throttle: write down whatever `note`
/// held back, now that no more output is coming.
///
/// `note` is the *leading* edge of a rate limit and it is only ever called
/// from a pty read, which together make a hole big enough to swallow the
/// whole feature: a terminal that prints in one burst and then goes quiet
/// gets one `note` at the start of the burst -- when nothing has scrolled
/// yet and there is nothing to record -- and every later read inside the
/// 250ms window is turned away. Output then stops, so no further read ever
/// arrives, so nothing calls `note` again, and every committed line sits in
/// the scrollback unwritten until the terminal closes. `seq 1 400` at a
/// shell prompt is exactly that shape, and it produced a transcript
/// directory that was never even created.
///
/// So the reader stage calls this when it runs out of batches, which is the
/// one moment that means "the burst is over". Unthrottled deliberately:
/// being called at all already says there is nothing left to coalesce with,
/// and the whole point is to close the window `note` opened. Idle costs
/// nothing -- a terminal with no output has no batches to run out of, and a
/// flush with nothing committed since the last one walks no rows and writes
/// no bytes.
pub fn flush(
    self: *Transcript,
    screen: *const terminal.Screen,
    title: []const u8,
    mono_ms: i64,
) void {
    self.last_mono_ms = mono_ms;
    self.rename(title);
    self.record(screen, nowMs(self.io), .history);
}

/// This terminal will never print again: write down the last screenful.
///
/// The rows still on the active screen have never scrolled out, so nothing
/// in the ordinary path will ever reach them. `deinit` was meant to be
/// their one chance, and on a real machine it is not one: the process
/// exits before anything unwinds. `ghostty -e` sets
/// `quit-after-last-window-closed` with no delay, so the window closing and
/// the process ending are the same instant; Cmd-Q, a crash and a kill are
/// the same story. Every terminal was losing its last screenful.
///
/// So the record is closed at the moment that actually means the terminal
/// is finished -- the pty hanging up, which is a thing that happens to a
/// live program rather than a thing that happens while one is being torn
/// down. `deinit` comes through here too, for the other order: a surface
/// closed while its child is still running never sees a hangup, and there
/// the teardown really is the last chance. Whichever arrives first closes
/// the record and the other does nothing -- see `closed` for why that has
/// to be a flag rather than something the pin can decide.
pub fn finish(self: *Transcript, screen: *const terminal.Screen, title: []const u8) void {
    if (self.closed) return;
    self.closed = true;

    self.rename(title);

    // `.screen` and not `.history`: there is no later moment in which
    // these rows would scroll out, so this is where they are recorded or
    // nowhere.
    self.record(screen, nowMs(self.io), .screen);
}

/// Write every row from the pin up to the bottom of `upto` into the file.
///
/// `.history` is the ordinary boundary: the rows that have scrolled off the
/// active screen and can no longer be rewritten. `.screen` includes what is
/// still on the active screen, and is only right at shutdown -- used any
/// earlier it would record rows that a program is still editing, and record
/// them again once they scrolled.
pub fn record(
    self: *Transcript,
    screen: *const terminal.Screen,
    at_ms: i64,
    upto: terminal.point.Tag,
) void {
    // Everything below works a row at a time, so both ends are pinned to
    // column zero. `getBottomRight` hands back the *last cell* of the last
    // row, and comparing pins compares x as well as y -- so a boundary left
    // as it arrived would read as "after" the very row it names, and the
    // walk would step past the end of the region it was given.
    var end = screen.pages.getBottomRight(upto) orelse return;
    end.x = 0;

    // First time through, start where the screen currently starts. Anything
    // older than the moment recording was switched on is not this file's to
    // claim.
    const start: terminal.Pin = if (self.pin) |p| p.* else start: {
        const top = screen.pages.getTopLeft(.screen);
        const pages: *terminal.PageList = @constCast(&screen.pages);
        self.pin = pages.trackPin(top) catch |err| {
            self.warnOnce(err);
            return;
        };
        break :start top;
    };

    // Nothing has scrolled since last time.
    if (end.before(start)) return;

    var cursor = start;
    while (true) {
        const batch = batchEnd(cursor, end);
        self.emit(screen, at_ms, cursor, batch);

        const next = batch.down(1) orelse {
            // The bottom of the page list. Leave the pin where it is; the
            // next row written will be below it.
            self.pin.?.* = batch;
            return;
        };
        self.pin.?.* = next;
        if (!batch.before(end)) return;
        cursor = next;
    }
}

/// The last row of a batch: `batch_rows` on from `from`, but never past
/// `end`, and never in the middle of a soft-wrapped line.
///
/// Stopping mid-wrap would split one logical line into two records, which
/// is exactly the seam a person greps across and does not find.
fn batchEnd(from: terminal.Pin, end: terminal.Pin) terminal.Pin {
    var last = from;
    var n: usize = 0;
    var it = from.rowIterator(.right_down, end);
    while (it.next()) |p| {
        last = p;
        n += 1;
        if (n < batch_rows) continue;

        // Past the budget, so stop -- unless this row continues onto the
        // next one, in which case keep going until it does not.
        if (!p.rowAndCell().row.wrap) break;
    }
    return last;
}

/// Turn the rows `tl..br` into text and write one record per line.
fn emit(
    self: *Transcript,
    screen: *const terminal.Screen,
    at_ms: i64,
    tl: terminal.Pin,
    br: terminal.Pin,
) void {
    self.scratch.clearRetainingCapacity();

    var w: std.Io.Writer.Allocating = .fromArrayList(self.alloc, &self.scratch);
    defer self.scratch = w.toArrayList();

    // Unwrapped, so that a line the terminal soft-wrapped over three rows
    // comes back as the one line it was printed as. Somebody grepping the
    // transcript is looking for what was printed, not for where this
    // window happened to be cut.
    // The region is given a row at a time, but a selection ends at a cell:
    // left at column zero the last row would come back as one character.
    var last = br;
    last.x = last.node.cols() - 1;

    screen.dumpString(&w.writer, .{
        .tl = tl,
        .br = last,
        .unwrap = true,
    }) catch |err| {
        self.warnOnce(err);
        return;
    };

    var rest = w.writer.buffered();
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const raw = if (nl) |i| rest[0..i] else rest;
        rest = if (nl) |i| rest[i + 1 ..] else rest[0..0];

        // Rows are padded out to the full width, so nearly every line
        // arrives with trailing blanks that were never printed.
        const text = std.mem.trimEnd(u8, raw, " \t\r");

        // A blank row carries nothing and there are a great many of them --
        // every `clear` pushes a screenful into the scrollback. Dropping
        // them is what keeps the file something a person can read.
        if (text.len == 0) continue;

        self.line(at_ms, text);
    }
}

/// One record, as one line of JSON.
///
/// The same shape and the same reading as `chat.jsonl`, on purpose: `less`,
/// `grep` and `jq` all work on both, and nobody has to learn a second
/// format to answer a question about the same night.
pub fn line(self: *Transcript, at_ms: i64, text: []const u8) void {
    var buf: [max_line + 256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    var s: std.json.Stringify = .{ .writer = &w, .options = .{} };
    s.beginObject() catch return;
    s.objectField("at_ms") catch return;
    s.write(at_ms) catch return;
    s.objectField("text") catch return;
    s.write(text[0..@min(text.len, max_line)]) catch return;
    s.endObject() catch return;
    w.writeByte('\n') catch return;

    self.settled = true;
    self.tree.write(self.name, at_ms, w.buffered());
}

fn warnOnce(self: *Transcript, err: anyerror) void {
    if (self.warned) return;
    self.warned = true;
    log.warn("terminal log: could not record {s} err={}", .{ self.name, err });
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn testDir(alloc: Allocator, io: std.Io) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-transcript-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

/// Everything one terminal's directory holds for a day, as one string.
fn readDay(alloc: Allocator, io: std.Io, t: *Transcript, at_ms: i64) ![]u8 {
    const path = try t.tree.partPath(alloc, t.name, daylog.dayOf(at_ms), 1);
    defer alloc.free(path);

    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    const end = (try file.stat(io)).size;
    const out = try alloc.alloc(u8, @intCast(end));
    errdefer alloc.free(out);
    _ = try file.readPositionalAll(io, out, 0);
    return out;
}

test "a line lands in the terminal's own directory for the day" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var t = try Transcript.open(alloc, io, dir, 0x7f3a, "kairos");
    defer t.deinit(null);

    const at: i64 = 1_724_800_000_000;
    t.line(at, "cargo test");
    t.line(at, "test result: ok");

    const got = try readDay(alloc, io, &t, at);
    defer alloc.free(got);

    try testing.expect(std.mem.indexOf(u8, got, "\"text\":\"cargo test\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"text\":\"test result: ok\"") != null);

    // One object per line, the same as the chat record, so the same tools
    // read both.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, got, "\n"));
}

test "a terminal is one directory, named for the id first and the title after" {
    const alloc = testing.allocator;

    const named = try nameOf(alloc, 0x7f3a, "kairos");
    defer alloc.free(named);
    try testing.expectEqualStrings("0000000000007f3a-kairos", named);

    // A terminal with nothing in its tab still gets a directory, because
    // the id is the part that identifies it.
    const bare = try nameOf(alloc, 0x7f3a, "");
    defer alloc.free(bare);
    try testing.expectEqualStrings("0000000000007f3a", bare);

    // Two terminals never share one, whatever their tabs say.
    const other = try nameOf(alloc, 0x7f3b, "kairos");
    defer alloc.free(other);
    try testing.expect(!std.mem.eql(u8, named, other));
}

test "a title that would escape the directory is one segment anyway" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // A shell sets its own title, so this is not a hypothetical string.
    var t = try Transcript.open(alloc, io, dir, 1, "../../etc/passwd");
    defer t.deinit(null);

    const at: i64 = 1_724_800_000_000;
    t.line(at, "hello");

    const path = try t.tree.partPath(alloc, t.name, daylog.dayOf(at), 1);
    defer alloc.free(path);

    // The whole title became *one* directory component under our own tree,
    // through the same encoding the chat record uses: directory, then day
    // file, and no third level for the separators the title was carrying.
    //
    // Counted in the separator this platform actually builds paths with.
    // `partPath` goes through `std.fs.path.join`, so on Windows the two
    // separators are `\` and a test that counted `/` would find none and
    // read that as "the title escaped" -- the exact opposite of the truth.
    const rel = path[t.dir.len..];
    const sep = std.fs.path.sep;
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, rel, &.{sep}));
    try testing.expect(std.mem.startsWith(u8, path, t.dir));

    // And neither separator survives *inside* the segment, which is the
    // property the title was threatening. Checked for both spellings on
    // both platforms: `/` means nothing to a POSIX name either way, but
    // `\` is a separator on Windows and must not be sitting in a segment.
    const seg = rel[1 .. std.mem.indexOfScalarPos(u8, rel, 1, sep) orelse rel.len];
    try testing.expect(std.mem.indexOfScalar(u8, seg, '/') == null);
    try testing.expect(std.mem.indexOfScalar(u8, seg, '\\') == null);

    const got = try readDay(alloc, io, &t, at);
    defer alloc.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "hello") != null);
}

test "a very long line is cut rather than dropped" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var t = try Transcript.open(alloc, io, dir, 1, "big");
    defer t.deinit(null);

    const huge = try alloc.alloc(u8, max_line * 2);
    defer alloc.free(huge);
    @memset(huge, 'x');

    const at: i64 = 1_724_800_000_000;
    t.line(at, huge);

    const got = try readDay(alloc, io, &t, at);
    defer alloc.free(got);

    // Something was written, and it did not run away with the buffer.
    try testing.expect(got.len > 1000);
    try testing.expect(got.len < max_line + 512);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got, "\n"));
}

test "only the lines that have scrolled out are recorded" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var s = try terminal.Screen.init(io, alloc, .{
        .cols = 40,
        .rows = 3,
        .max_scrollback_bytes = 1 << 20,
    });
    defer s.deinit();

    var t = try Transcript.open(alloc, io, dir, 1, "scroll");
    defer t.deinit(null);

    const at: i64 = 1_724_800_000_000;

    // Nothing has scrolled yet, so there is nothing committed to record --
    // those three rows can still be rewritten by the program.
    try s.testWriteString("one\ntwo\nthree");
    t.record(&s, at, .history);
    try testing.expectError(
        error.FileNotFound,
        readDay(alloc, io, &t, at),
    );

    // Now two more lines push the first two off the active screen.
    try s.testWriteString("\nfour\nfive");
    t.record(&s, at, .history);

    const got = try readDay(alloc, io, &t, at);
    defer alloc.free(got);

    try testing.expect(std.mem.indexOf(u8, got, "\"one\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"two\"") != null);

    // Still on the active screen, so not yet the transcript's business.
    try testing.expect(std.mem.indexOf(u8, got, "\"four\"") == null);
    try testing.expect(std.mem.indexOf(u8, got, "\"five\"") == null);

    // And the pin does not go back over what it has already written.
    t.record(&s, at, .history);
    const again = try readDay(alloc, io, &t, at);
    defer alloc.free(again);
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, again, "\"one\""),
    );
}

test "the last screenful is written down when the terminal goes" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var s = try terminal.Screen.init(io, alloc, .{
        .cols = 40,
        .rows = 3,
        .max_scrollback_bytes = 1 << 20,
    });
    defer s.deinit();

    var t = try Transcript.open(alloc, io, dir, 1, "tail");
    const at: i64 = 1_724_800_000_000;

    try s.testWriteString("alpha\nbeta");
    t.record(&s, at, .history);

    // Nothing scrolled, so nothing was recorded. Closing is the last
    // chance those rows get.
    t.record(&s, at, .screen);
    const got = try readDay(alloc, io, &t, at);
    defer alloc.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "\"alpha\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"beta\"") != null);

    t.deinit(&s);
}

test "a soft-wrapped line comes back as the one line it was printed as" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var s = try terminal.Screen.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback_bytes = 1 << 20,
    });
    defer s.deinit();

    var t = try Transcript.open(alloc, io, dir, 1, "wrap");
    defer t.deinit(null);

    const at: i64 = 1_724_800_000_000;

    // 25 characters over a 10-column screen: three rows, one line.
    try s.testWriteString("abcdefghijklmnopqrstuvwxy\nb\nc\nd\ne");
    t.record(&s, at, .history);

    const got = try readDay(alloc, io, &t, at);
    defer alloc.free(got);
    try testing.expect(
        std.mem.indexOf(u8, got, "\"abcdefghijklmnopqrstuvwxy\"") != null,
    );
}

test "blank rows are not lines and do not reach the file" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var s = try terminal.Screen.init(io, alloc, .{
        .cols = 20,
        .rows = 3,
        .max_scrollback_bytes = 1 << 20,
    });
    defer s.deinit();

    var t = try Transcript.open(alloc, io, dir, 1, "blank");
    defer t.deinit(null);

    const at: i64 = 1_724_800_000_000;

    // Two lines with four blank rows between them, so the region really
    // spans the blanks -- a trailing run of them would simply be outside
    // the last written row and never reach the code being tested.
    try s.testWriteString("x\n\n\n\n\ny");
    t.record(&s, at, .screen);

    const got = try readDay(alloc, io, &t, at);
    defer alloc.free(got);

    // Two records, not six: the empty rows carried nothing, and every
    // `clear` pushes a screenful of them past here.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, got, "\n"));
    try testing.expect(std.mem.indexOf(u8, got, "\"x\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"y\"") != null);
}

test "the throttle keeps a burst off the disk but never loses the line" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var s = try terminal.Screen.init(io, alloc, .{
        .cols = 20,
        .rows = 3,
        .max_scrollback_bytes = 1 << 20,
    });
    defer s.deinit();

    var t = try Transcript.open(alloc, io, dir, 1, "burst");
    defer t.deinit(null);

    // `note` dates its records off the wall clock, so read them back off it
    // too rather than off a number this test made up.
    const at = nowMs(io);

    try s.testWriteString("one\ntwo\nthree\nfour\nfive");

    // The first note is due -- the throttle starts at zero -- so it records.
    t.note(&s, "burst", 10_000);
    const first = try readDay(alloc, io, &t, at);
    defer alloc.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "\"one\"") != null);

    // More output arrives inside the window: nothing is written.
    try s.testWriteString("\nsix\nseven");
    t.note(&s, "burst", 10_000 + flush_ms - 1);
    const during = try readDay(alloc, io, &t, at);
    defer alloc.free(during);
    try testing.expectEqualStrings(first, during);

    // Once the window is up it catches up, and nothing went missing in
    // between: the pin never moved past a line that was not written.
    t.note(&s, "burst", 10_000 + flush_ms);
    const after = try readDay(alloc, io, &t, at);
    defer alloc.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "\"three\"") != null);
    try testing.expect(std.mem.indexOf(u8, after, "\"four\"") != null);
}

test "a burst that ends and goes quiet still reaches the file" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var s = try terminal.Screen.init(io, alloc, .{
        .cols = 20,
        .rows = 3,
        .max_scrollback_bytes = 1 << 20,
    });
    defer s.deinit();

    var t = try Transcript.open(alloc, io, dir, 1, "quiet");
    defer t.deinit(null);

    const at = nowMs(io);

    // The shape a real terminal actually has, and the one that recorded a
    // grand total of zero bytes on a real machine: the first read arrives
    // before anything has scrolled, so the one `note` the throttle lets
    // through has nothing to write. Every read of the burst that follows
    // lands inside the same 250ms window and is turned away.
    t.note(&s, "quiet", 10_000);
    try testing.expectError(error.FileNotFound, readDay(alloc, io, &t, at));

    try s.testWriteString("one\ntwo\nthree\nfour\nfive");
    t.note(&s, "quiet", 10_000 + 1);
    try testing.expectError(error.FileNotFound, readDay(alloc, io, &t, at));

    // And then the output stops. Nothing will ever call `note` again --
    // only a pty read does, and there are no more -- so without a trailing
    // edge those lines sit in the scrollback until the terminal closes.
    t.flush(&s, "quiet", 10_000 + 2);

    const got = try readDay(alloc, io, &t, at);
    defer alloc.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "\"one\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"two\"") != null);

    // A second flush with nothing new does not write the same lines again:
    // the pin is where the first one left it.
    t.flush(&s, "quiet", 10_000 + 3);
    const again = try readDay(alloc, io, &t, at);
    defer alloc.free(again);
    try testing.expectEqualStrings(got, again);
}

test "the last screenful lands when the pty hangs up, not at teardown" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var s = try terminal.Screen.init(io, alloc, .{
        .cols = 20,
        .rows = 3,
        .max_scrollback_bytes = 1 << 20,
    });
    defer s.deinit();

    var t = try Transcript.open(alloc, io, dir, 1, "hangup");
    defer t.deinit(null);

    const at = nowMs(io);

    try s.testWriteString("one\ntwo\nthree\nfour\nfive");
    t.flush(&s, "hangup", 10_000);

    // The ordinary path can only ever have the rows that scrolled out.
    const during = try readDay(alloc, io, &t, at);
    defer alloc.free(during);
    try testing.expect(std.mem.indexOf(u8, during, "\"one\"") != null);
    try testing.expect(std.mem.indexOf(u8, during, "\"five\"") == null);

    // The pty hangs up. Nothing is being torn down -- the terminal is
    // still perfectly alive -- and the last screenful has to be on disk
    // anyway, because on this machine the process ends before teardown
    // ever runs.
    t.finish(&s, "hangup");

    const got = try readDay(alloc, io, &t, at);
    defer alloc.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "\"four\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"five\"") != null);

    // And the teardown that may or may not follow writes nothing twice --
    // at the bottom of the page list the pin stops *on* the last row, so
    // without the flag a second pass would repeat it.
    t.finish(&s, "hangup");
    const again = try readDay(alloc, io, &t, at);
    defer alloc.free(again);
    try testing.expectEqualStrings(got, again);
}

test "a program on the alternate screen leaves the transcript alone" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var term = try terminal.Terminal.init(io, alloc, .{
        .cols = 40,
        .rows = 3,
        .max_scrollback_bytes = 1 << 20,
    });
    defer term.deinit(alloc);

    var t = try Transcript.open(alloc, io, dir, 1, "alt");
    defer t.deinit(null);

    const at: i64 = 1_724_800_000_000;

    const primary = term.screens.get(.primary).?;
    for ([_][]const u8{ "shell one", "shell two", "shell three", "shell four" }) |s| {
        try term.printString(s);
        try term.linefeed();
        term.carriageReturn();
    }
    t.record(primary, at, .history);

    const before = try readDay(alloc, io, &t, at);
    defer alloc.free(before);
    const lines_before = std.mem.count(u8, before, "\n");
    try testing.expect(lines_before > 0);

    // Now a full-screen program takes over and paints a great deal.
    _ = try term.switchScreen(.alternate);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        term.setCursorPos(1, 1);
        try term.printString("htop frame");
    }
    t.record(primary, at, .history);

    // Not one line of it: the alternate screen does not commit to
    // scrollback, which is the documented cost of recording what was
    // output rather than what the screen did.
    const after = try readDay(alloc, io, &t, at);
    defer alloc.free(after);
    try testing.expectEqual(lines_before, std.mem.count(u8, after, "\n"));
}

test "the readable half of the name is taken once and then left alone" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // A terminal has no title at the instant it starts, so it opens bare.
    var t = try Transcript.open(alloc, io, dir, 0x7f3a, "");
    defer t.deinit(null);
    try testing.expectEqualStrings("0000000000007f3a", t.name);

    // The shell sets one a moment later, before anything is written.
    t.rename("kairos");
    try testing.expectEqualStrings("0000000000007f3a-kairos", t.name);

    const at: i64 = 1_724_800_000_000;
    t.line(at, "hello");

    // And every retitle after that is ignored: a directory that moved
    // would leave the night's work in two places with nothing joining them.
    t.rename("~/some/other/dir");
    try testing.expectEqualStrings("0000000000007f3a-kairos", t.name);

    const got = try readDay(alloc, io, &t, at);
    defer alloc.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "hello") != null);
}
