//! What was said, written down.
//!
//! The chat itself lives in memory and is deliberately small: it trims as it
//! grows, and the supervisor compacts it on purpose to keep the agents'
//! context free. That is the right shape for a working set and the wrong
//! shape for a record. Unattended overnight is the case this whole feature
//! exists for, and the morning after has to have something to read.
//!
//! So this is append-only and **nothing removes anything**. A message
//! trimmed out of memory is still here; a range the supervisor compacted
//! away is still here, with the summary written after it rather than over
//! it. The file says what happened, not what the agents currently hold.
//!
//! One line of JSON per message. That makes it greppable with the tools
//! anybody already has, recoverable if the tail is torn off by a crash, and
//! writable without reading anything back.
//!
//! It is written twice, into two shapes with different jobs. `chat.jsonl`
//! is the **stream**: one flat file, rotated by size, which the archive
//! follows by seq and which therefore has to stay boring. `<group>/<date>
//! .jsonl` is the **record**: what a person greps the next morning and what
//! `group_history` pages through, never rotated and never trimmed. The
//! record is the fuller of the two, because the stream forgets. See the
//! section beginning "the record" below, and `docs/poltergeist/storage.md`.
//!
//! Kept out of `Chat.zig` so that the model stays pure -- no allocation
//! beyond its registry, no clock, no filesystem. The host owns the side
//! effects, which is also why it can be turned off entirely.

const ChatLog = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");

const log = std.log.scoped(.poltergeist);

/// Rotate once the file passes this. Two generations are kept, so the disk
/// cost is bounded at roughly twice this.
///
/// Chat here is agents pasting code and logs at each other, so this is far
/// larger than the 512KB the ssh cache settles for. A night of it should
/// fit without rotating at all.
const rotate_bytes: u64 = 8 * 1024 * 1024;

/// Most messages one `history` call will ever hand back.
///
/// A wall against a caller that asks for the whole night in one go: the
/// page is built in memory, strings and all, before anybody sees it.
const max_history_limit: usize = 200;

/// How far back one `history` call will read before giving up.
///
/// A group that said little on a busy machine can sit behind megabytes of
/// other groups' traffic. Reading is quiet work happening while somebody
/// holds page-up, so it is bounded and allowed to come back short: the
/// caller simply asks again.
const history_scan_bytes: u64 = 2 * 1024 * 1024;

/// The window `history` walks backwards in, one step at a time.
///
/// Larger than the 64KB buffer `append` writes through, so a single line
/// can never be too long to fit in one chunk.
const scan_chunk_bytes: usize = 128 * 1024;

/// How much of the end of a file `recoverSeq` reads looking for a seq.
const tail_probe_bytes: usize = 64 * 1024;

/// The window a forward read pulls in at once.
///
/// Larger than the 64KB buffer `append` writes through, so a whole line
/// always fits and a window with no newline in it means bad data rather
/// than a line the reader is simply too small to see.
const tail_chunk_bytes: usize = 128 * 1024;

/// The most one day's file in the record holds before that day carries on
/// in a `.partN` file beside it.
///
/// The same number as `rotate_bytes` and for an unrelated reason: nothing
/// in the record is ever moved aside or overwritten, so this bounds how
/// large a single file somebody opens in `less` gets, not how much disk
/// the record takes. See "the record" below.
const day_bytes: u64 = 8 * 1024 * 1024;

/// Longest a group's directory name may get once encoded.
const max_segment: usize = 200;

alloc: Allocator,
io: std.Io,

/// `<state>/chat`. Owned. Both shapes live under it.
dir: []const u8,

/// Where the current stream generation lives. Owned.
path: []const u8,

file: std.Io.File,
written: u64,

/// The log's own sequence number: global, monotonic, shared by every
/// group, and recovered from the file rather than restarted.
///
/// `Chat.Message.seq` cannot serve here -- it counts from 1 per group
/// and per process, so two nights of one file hold two `build/seq=7`
/// and anything paging by it reads the wrong run.
next_seq: u64,

/// The record: `<group>/<YYYY-MM-DD>.jsonl` under `dir`.
tree: Tree,

pub const Error = Allocator.Error || error{
    XdgLookupFailed,
    OpenFailed,
};

/// A place in the log, as a reader that has to come back to it needs it.
///
/// `seq` is the only field that means anything: it survives rotation, it is
/// what the plugin confirms, and it is what a scan can always find again.
/// `offset` and `inode` are a shortcut and nothing more -- they are checked
/// before they are believed, and a mark whose shortcut does not check out
/// is still a perfectly good mark.
pub const Mark = struct {
    /// Everything up to and including this seq is behind the reader.
    seq: u64 = 0,

    /// A byte offset, in the file `inode` names, at or before the first
    /// unread line. Zero when there is no hint.
    ///
    /// At or *before*, deliberately. A plugin that confirms half a batch
    /// leaves the cursor in the middle of a window; recording the start of
    /// that window keeps the hint honest and costs one batch of skipping
    /// instead of a scan of the whole file.
    offset: u64 = 0,

    /// Which file `offset` was measured in. Zero when there is no hint.
    ///
    /// Without it an offset cannot be trusted at all: rotation renames the
    /// current generation aside and starts a new file at zero, so a bare
    /// offset afterwards points at an arbitrary byte of a different file
    /// while looking entirely legal.
    inode: u64 = 0,
};

/// Where the log lives under a state directory. Caller owns it.
///
/// Exported because the archive reads the same file from another thread and
/// must not learn the layout a second time.
pub fn defaultPath(alloc: Allocator, state_dir: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(alloc, &.{ state_dir, "chat", "chat.jsonl" });
}

/// The highest seq the log has handed out, or 0 for a log nothing has been
/// written into.
///
/// What a member joining a group with no history has to be barred from.
/// The group in memory cannot answer that: after a restart it is empty
/// while the file still holds last night, so the only honest bound is
/// where the file has got to.
pub fn head(self: *const ChatLog) u64 {
    return self.next_seq - 1;
}

/// Open, or reopen, the log under the state directory.
pub fn open(alloc: Allocator, io: std.Io, state_dir: []const u8) Error!ChatLog {
    const dir = std.fs.path.join(alloc, &.{ state_dir, "chat" }) catch
        return error.OutOfMemory;
    errdefer alloc.free(dir);

    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("chat log: could not make {s} err={}", .{ dir, err });
            return error.OpenFailed;
        },
    };

    const path = defaultPath(alloc, state_dir) catch return error.OutOfMemory;
    errdefer alloc.free(path);

    const file = openAppend(io, path) catch return error.OpenFailed;

    // Where the end is. Tracked from here on rather than asked for again:
    // every write goes at this offset and advances it, so appending costs
    // no extra syscall and two Polters cannot interleave into one line.
    const written = if (file.stat(io)) |st| st.size else |_| 0;

    var self: ChatLog = .{
        .alloc = alloc,
        .io = io,
        .dir = dir,
        .path = path,
        .file = file,
        .written = written,
        .next_seq = 1,
        .tree = .{ .alloc = alloc, .io = io, .dir = dir },
    };

    // In that order: the tail has to be whole before anything tries to
    // read a line out of it.
    self.patchTornTail();
    self.next_seq = self.recoverSeq() + 1;

    // Last, because it reads the stream back and writes into the record,
    // and both want the tail whole and the numbering settled first.
    self.backfill();
    return self;
}

/// Finish a line the last run died in the middle of.
///
/// A crash between two `writePositionalAll` calls leaves a half line with
/// no newline after it, and the next append would run straight into it --
/// one line holding the end of one message and all of another. Closing it
/// here costs one syscall at startup and lets every reader below assume
/// that a newline ends a line and nothing else does.
///
/// If the write fails there is nothing to be done: appending is about to
/// fail for the same reason.
fn patchTornTail(self: *ChatLog) void {
    if (self.written == 0) return;

    var last: [1]u8 = undefined;
    const n = self.file.readPositionalAll(self.io, &last, self.written - 1) catch return;
    if (n != 1 or last[0] == '\n') return;

    self.file.writePositionalAll(self.io, "\n", self.written) catch return;
    self.written += 1;
}

/// The highest seq the log already holds, or 0 for a log with none.
///
/// The rotated generation is the fallback rather than a nicety: a restart
/// just after a rotation finds the current file empty, and counting from 1
/// again would hand out numbers `.1` is already full of. Which generation
/// holds the larger numbers is never compared, because it never has to be
/// -- `rotateIfFull` clears `written` and leaves `next_seq` alone, so the
/// new file always continues where the old one stopped.
fn recoverSeq(self: *ChatLog) u64 {
    if (tailSeq(self.alloc, self.io, self.file, self.written)) |seq| return seq;

    const old = std.fmt.allocPrint(self.alloc, "{s}.1", .{self.path}) catch return 0;
    defer self.alloc.free(old);

    const file = std.Io.Dir.openFileAbsolute(self.io, old, .{}) catch return 0;
    defer file.close(self.io);

    const end = if (file.stat(self.io)) |st| st.size else |_| return 0;
    return tailSeq(self.alloc, self.io, file, end) orelse 0;
}

/// The seq of the last usable line in the first `tail_probe_bytes` back
/// from `end`, or null when there is none to be had.
fn tailSeq(alloc: Allocator, io: std.Io, file: std.Io.File, end: u64) ?u64 {
    if (end == 0) return null;

    var buf: [tail_probe_bytes]u8 = undefined;
    const want: usize = @intCast(@min(end, tail_probe_bytes));
    const n = file.readPositionalAll(io, buf[0..want], end - want) catch return null;

    // Anything after the last newline is not a line yet. The current file
    // has had its tail closed by now, but a rotated one is whatever it was
    // when it was renamed away.
    const complete = std.mem.lastIndexOfScalar(u8, buf[0..n], '\n') orelse return null;

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    var rest = buf[0..complete];
    while (rest.len > 0) {
        const nl = std.mem.lastIndexOfScalar(u8, rest, '\n');
        const line = if (nl) |i| rest[i + 1 ..] else rest;
        rest = if (nl) |i| rest[0..i] else rest[0..0];

        _ = arena.reset(.retain_capacity);
        if (parseLine(arena.allocator(), line)) |parsed| {
            if (parsed.seq != 0) return parsed.seq;
        }
    }
    return null;
}

/// One line of the file, read back.
///
/// Every field has a default because lines written by an older Polter have
/// no `seq` at all, and a reader that refused them would turn one upgrade
/// into a hole in the record.
const Line = struct {
    seq: u64 = 0,
    at_ms: i64 = 0,
    group: []const u8 = "",
    from: []const u8 = "",
    author: []const u8 = "",
    summary: bool = false,
    text: []const u8 = "",
};

/// Read one line back, or null if it is not one.
///
/// Everything it hands back points into `arena` or into `bytes`; the
/// caller is expected to be holding a scratch arena it resets per line.
fn parseLine(arena: Allocator, bytes: []const u8) ?Line {
    return std.json.parseFromSliceLeaky(Line, arena, bytes, .{
        .ignore_unknown_fields = true,
    }) catch null;
}

/// The same, except that an allocator which failed is not a line that will
/// not parse.
///
/// The backwards walk can afford to conflate those two: it drops the line
/// out of a page somebody is scrolling, and the same page is asked for
/// again a moment later. A forward read cannot. It moves the cursor past
/// every line it decides is unusable, so a line called unreadable because
/// memory was short for an instant is a message no archive is ever handed
/// and nothing anywhere says so -- the one failure this whole design is
/// built to make impossible.
fn parseLineStrict(arena: Allocator, bytes: []const u8) Allocator.Error!?Line {
    return std.json.parseFromSliceLeaky(Line, arena, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

pub fn deinit(self: *ChatLog) void {
    self.tree.deinit();
    self.file.close(self.io);
    self.alloc.free(self.path);
    self.alloc.free(self.dir);
    self.* = undefined;
}

/// Open for reading and writing, creating with 0600 if it is not there.
///
/// Owner-only because the contents are code, file paths and stack traces
/// out of the user's own work -- a real privacy surface rather than a
/// formality. Same reasoning, and the same mode, as the ssh cache.
///
/// Readable as well as writable because recovering the seq and paging
/// backwards both have to read the very file this handle is appending to.
/// A second read-only handle would work and would be worse: two views of
/// one file, one of them not knowing about `written`, and a page that
/// stops just short of the message somebody is scrolling up to find.
fn openAppend(io: std.Io, path: []const u8) !std.Io.File {
    const file = std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = false,
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => try std.Io.Dir.openFileAbsolute(
            io,
            path,
            .{ .mode = .read_write },
        ),
        else => return err,
    };
    return file;
}

/// Write one message down, and say where it landed.
///
/// Returns the seq it wrote, or 0 when nothing reached the disk. Zero
/// is the same answer the caller gets when there is no log at all, and
/// it means the same thing: this message cannot be paged back to.
///
/// Failure is logged once and otherwise swallowed: a full disk must not
/// stop the terminals talking to each other. The record is worth having,
/// and it is not worth more than the thing it records.
pub fn append(
    self: *ChatLog,
    group: []const u8,
    from: Bus.Id,
    author: []const u8,
    at_ms: i64,
    summary: bool,
    text: []const u8,
) u64 {
    self.rotateIfFull();

    // Taken before anything can go wrong, and never given back. A gap in
    // the numbering is harmless -- all anybody asks of it is that it only
    // goes up -- whereas handing the same number out twice would leave a
    // cursor pointing at two different lines.
    const seq = self.next_seq;
    self.next_seq += 1;

    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    var s: std.json.Stringify = .{ .writer = &w, .options = .{} };
    s.beginObject() catch return 0;

    // First, so that a walk backwards over the tail of the file finds it
    // without parsing much of anything else.
    s.objectField("seq") catch return 0;
    s.write(seq) catch return 0;

    s.objectField("at_ms") catch return 0;
    s.write(at_ms) catch return 0;
    s.objectField("group") catch return 0;
    s.write(group) catch return 0;
    s.objectField("from") catch return 0;
    s.print("\"0x{x:0>16}\"", .{from}) catch return 0;
    s.objectField("author") catch return 0;
    s.write(author) catch return 0;
    if (summary) {
        s.objectField("summary") catch return 0;
        s.write(true) catch return 0;
    }
    s.objectField("text") catch return 0;

    // Truncated rather than dropped: a very long paste should leave a
    // record that it happened, even a partial one.
    const room = buf.len -| w.buffered().len -| 64;
    s.write(text[0..@min(text.len, room)]) catch return 0;
    s.endObject() catch return 0;
    w.writeByte('\n') catch return 0;

    const line = w.buffered();
    self.file.writePositionalAll(self.io, line, self.written) catch |err| {
        log.warn("chat log: could not write err={}", .{err});
        return 0;
    };
    self.written += line.len;

    // The record second, and only once the stream has taken it. The stream
    // is what hands out seq and what the archive follows; the record is
    // what people read. Writing it the other way round would let a full
    // disk under `chat/<group>/` cost a message rather than cost legibility.
    self.tree.write(group, at_ms, line);
    return seq;
}

/// Move the current log aside once it gets large, keeping one generation.
///
/// `written` restarts and `next_seq` deliberately does not: the numbering
/// spans both generations, which is what lets a reader walk out of the new
/// file and into the old one without the numbers going backwards.
fn rotateIfFull(self: *ChatLog) void {
    if (self.written < rotate_bytes) return;

    const old = std.fmt.allocPrint(self.alloc, "{s}.1", .{self.path}) catch return;
    defer self.alloc.free(old);

    self.file.close(self.io);

    std.Io.Dir.renameAbsolute(self.path, old, self.io) catch |err| {
        log.warn("chat log: could not rotate err={}", .{err});
    };

    self.file = openAppend(self.io, self.path) catch |err| {
        // Nothing left to write to. Say so once; `append` will keep
        // failing quietly rather than taking the app down.
        log.warn("chat log: could not reopen after rotating err={}", .{err});
        self.written = 0;
        return;
    };
    self.written = 0;
}

/// One message as the log remembers it.
///
/// Everything here, strings included, belongs to the allocator passed
/// to `history`; free it with `freePage`.
pub const Entry = struct {
    seq: u64,
    at_ms: i64,
    group: []const u8,
    from: Bus.Id,
    author: []const u8,
    summary: bool,
    text: []const u8,
};

pub const Page = struct {
    /// Oldest first, the same order as the file and the same order
    /// `group_read` uses. Read backwards, handed back forwards.
    entries: []const Entry,

    /// True when the walk ran out of log rather than out of room: the
    /// caller has reached the beginning and can stop asking.
    exhausted: bool,
};

/// Messages in `group` older than `before_seq`, newest end first.
///
/// Read out of the record rather than out of the stream, for two reasons.
/// One group's days are its own files, so a quiet group buried under
/// another one's traffic costs nothing to page through -- the old walk had
/// to read past everybody else's megabytes to find it. And the record goes
/// back further than the stream's two generations do, so paging up does
/// not hit a wall at whatever the last rotation happened to cut.
///
/// Reading fails the way writing does -- quietly. A page that stops short
/// says `exhausted = false`, and the caller asks again later.
pub fn history(
    self: *ChatLog,
    alloc: Allocator,
    group: []const u8,
    before_seq: u64,
    limit: usize,
) Allocator.Error!Page {
    if (limit == 0) return .{ .entries = &.{}, .exhausted = false };

    var w: Walk = .{
        .alloc = alloc,
        .io = self.io,
        .group = group,
        .before_seq = before_seq,
        .want = @min(limit, max_history_limit),
        .arena = .init(alloc),
        .scratch = try alloc.alloc(u8, scan_chunk_bytes),
    };
    defer w.arena.deinit();
    defer alloc.free(w.scratch);
    errdefer {
        // Not `freePage`: the list's buffer is longer than its contents,
        // and handing the allocator the short slice is not a free it can
        // make sense of.
        for (w.found.items) |e| {
            alloc.free(e.group);
            alloc.free(e.author);
            alloc.free(e.text);
        }
        w.found.deinit(alloc);
    }

    var days = try self.tree.days(alloc, group);
    defer days.deinit(alloc);

    // Newest day first, and within a day its last part first: the same
    // direction the walk inside each file goes.
    var exhausted = true;
    for (days.items) |d| {
        const path = try self.tree.partPath(alloc, group, d.day, d.part);
        defer alloc.free(path);

        // A file that was listed a moment ago and will not open now is a
        // gap in the middle of the range, and a gap is the one thing the
        // caller must not be told is the beginning.
        const file = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch {
            exhausted = false;
            continue;
        };
        defer file.close(self.io);

        const st = file.stat(self.io) catch {
            exhausted = false;
            continue;
        };

        switch (try w.generation(file, st.size)) {
            .enough => {
                exhausted = false;
                break;
            },
            .gave_up => exhausted = false,
            .start_of_file => {},
        }
    }

    // Collected newest first because backwards is the only direction a
    // file can be walked; handed back oldest first because that is the
    // order `group_read` uses and the order a conversation is read in.
    std.mem.reverse(Entry, w.found.items);
    return .{ .entries = try w.found.toOwnedSlice(alloc), .exhausted = exhausted };
}

pub fn freePage(alloc: Allocator, page: Page) void {
    for (page.entries) |e| {
        alloc.free(e.group);
        alloc.free(e.author);
        alloc.free(e.text);
    }
    alloc.free(page.entries);
}

/// A forward read of the log, from a mark onwards.
///
/// **Its own file handle, deliberately.** The writer's handle is not safe
/// to share: `rotateIfFull` closes and replaces it, so a reader holding a
/// copy would read from a closed descriptor -- or, worse, from whatever the
/// kernel handed that number to next. The writer's `written` is not safe to
/// read either; it is a plain field on another thread. Neither is needed
/// here: positional reads carry their own offset, and the end of the file
/// is whatever the kernel says it is at the moment of the read.
///
/// What is shared is only the bytes, and POSIX makes a write on one
/// descriptor visible to a read on another. A line half written is still
/// possible, so nothing past the last newline is ever consumed -- the same
/// invariant `patchTornTail` keeps for the writer.
pub const Tail = struct {
    pub const Error = Allocator.Error || error{OpenFailed};

    alloc: Allocator,
    io: std.Io,

    /// The current generation's path -- `chat.jsonl`, never `.1`. Owned.
    path: []const u8,

    /// Open read-only on whichever generation is being drained.
    file: std.Io.File,

    /// `file`'s inode, so a rotation can be told from a quiet minute.
    inode: u64,

    /// Byte offset of the first unread line in `file`.
    offset: u64,

    /// The highest seq handed out, and by the same token the line below
    /// which nothing is handed out again.
    ///
    /// Every line whose seq is zero or is at or below this one is dropped
    /// while `offset` moves past it as usual. One rule doing three jobs:
    /// it skips the lines the mark had already been read past, it drops
    /// the lines an older Polter wrote with no seq at all, and -- the
    /// reason it is written as `<=` rather than as a separate cursor --
    /// it makes the numbers handed out strictly increasing. The archive
    /// needs that last one: `advance(before, through, ack)` treats an
    /// acknowledgement below `before` as a plugin claiming something it
    /// cannot know and kills the child for it, so a batch whose `through`
    /// came out lower than the last confirmed one would start a loop of
    /// killing and respawning that nothing breaks out of.
    ///
    /// The price is that a log whose numbering really does go backwards --
    /// hand-edited, or rebuilt from scratch under a cursor that outlived
    /// it -- has that stretch dropped in silence. That is the cheaper of
    /// the two, the other being a permanent spawn storm.
    seq: u64,

    /// One window of file, reused. Owned, `tail_chunk_bytes` long.
    buf: []u8,

    /// True once `file` is the current generation. False while draining the
    /// rotated one, which is the only time a switch is still ahead.
    current: bool,

    /// Reading fails the way writing does: once out loud, then quietly.
    warned: bool = false,

    /// Said at most once, because a reader that has fallen a whole
    /// generation behind will notice again on every batch.
    behind_warned: bool = false,

    /// The seq the first line of a freshly switched-into generation ought
    /// to carry. Set when a rotation is rolled through, cleared by the
    /// first line read out of the new file. Kept as a field rather than a
    /// local because the switch and the line that follows it can fall in
    /// two different `next` calls, whenever a batch fills up in between.
    behind_expect: ?u64 = null,

    pub fn deinit(self: *Tail) void {
        self.file.close(self.io);
        self.alloc.free(self.path);
        self.alloc.free(self.buf);
        self.* = undefined;
    }

    /// Where the read has got to, ready to be written down.
    pub fn mark(self: *const Tail) Mark {
        return .{
            .seq = self.seq,
            .offset = self.offset,
            .inode = self.inode,
        };
    }

    /// The next entries, oldest first.
    ///
    /// Stops at `limit` entries, at `max_bytes` of `text` accumulated, or
    /// at the end of what has been written -- whichever comes first. An
    /// empty page with `exhausted = true` is the ordinary answer for a
    /// quiet minute, not a failure.
    ///
    /// Entries belong to `alloc`; free the page with `ChatLog.freePage`.
    pub fn next(
        self: *Tail,
        alloc: Allocator,
        limit: usize,
        max_bytes: usize,
    ) Allocator.Error!Page {
        // The same answer `history` gives: a caller that asked for nothing
        // has been told nothing about where the end is.
        if (limit == 0) return .{ .entries = &.{}, .exhausted = false };

        var out: std.ArrayListUnmanaged(Entry) = .empty;
        errdefer {
            // Not `freePage`: the list's buffer is longer than its
            // contents, and handing the allocator the short slice is not a
            // free it can make sense of.
            for (out.items) |e| {
                alloc.free(e.group);
                alloc.free(e.author);
                alloc.free(e.text);
            }
            out.deinit(alloc);
        }

        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();

        var taken: usize = 0;

        while (true) {
            // Asked at the top of the loop rather than before each append,
            // so that every call consumes at least one line. Checking on
            // the way in would let one paste larger than `max_bytes` sit
            // there forever: empty page, cursor unmoved, no log line, and
            // an archive that is running and doing nothing.
            if (out.items.len >= limit or taken >= max_bytes)
                return .{ .entries = try out.toOwnedSlice(alloc), .exhausted = false };

            const n = self.file.readPositionalAll(self.io, self.buf, self.offset) catch |err| {
                // Reported as "nothing new" rather than as a failure, so a
                // transient error heals itself on the next poll. The warn
                // is the only sign a permanent one leaves, which is why it
                // names the file as well as the error.
                self.warnOnce(err);
                return .{ .entries = try out.toOwnedSlice(alloc), .exhausted = true };
            };

            if (n == 0) {
                if (!self.current) {
                    // Draining the generation rotation moved aside, and
                    // now drained. Roll into the one being appended to.
                    const f = std.Io.Dir.openFileAbsolute(self.io, self.path, .{}) catch |err| {
                        // `rotateIfFull` may not have managed to make the
                        // new file either. Leave every field where it is,
                        // which leaves the position where it is, and try
                        // again on the next call.
                        self.warnOnce(err);
                        return .{ .entries = try out.toOwnedSlice(alloc), .exhausted = true };
                    };
                    self.file.close(self.io);
                    self.file = f;
                    self.inode = inodeOf(self.io, f);
                    self.offset = 0;
                    self.current = true;
                    self.behind_expect = self.seq + 1;
                    continue;
                }

                const st = std.Io.Dir.cwd().statFile(self.io, self.path, .{}) catch
                    return .{ .entries = try out.toOwnedSlice(alloc), .exhausted = true };

                // A zero inode means we never managed to find out which
                // file we are reading. Every comparison then says "it
                // rotated", and that would re-read the whole generation
                // every time the end is reached -- the same messages sent
                // again twice a second. Not knowing means not concluding.
                if (self.inode == 0 or @as(u64, @intCast(st.inode)) == self.inode)
                    return .{ .entries = try out.toOwnedSlice(alloc), .exhausted = true };

                // It rotated. The handle we hold followed the bytes
                // through the rename, so it now names `.1`; finish it.
                self.current = false;
                continue;
            }

            const win = self.buf[0..n];
            const nl = std.mem.lastIndexOfScalar(u8, win, '\n') orelse {
                // A whole window and not one newline. `append` writes
                // through a buffer half this size, so it cannot have
                // written a line this long.
                if (n < self.buf.len) {
                    // Short of a window, so this is simply a line still
                    // being written. Wait for the rest of it.
                    return .{ .entries = try out.toOwnedSlice(alloc), .exhausted = true };
                }
                if (!self.warned) {
                    self.warned = true;
                    log.warn(
                        "chat log: {s} holds a line longer than a window; skipping past it",
                        .{self.path},
                    );
                }
                // Stepping over it rather than stopping: the next newline
                // in the file puts the read back on a line boundary by
                // itself, and stopping would wedge the archive for good.
                self.offset += n;
                continue;
            };

            // Everything after the last newline is left where it is, and
            // that single rule is what makes reading a file another thread
            // is appending to safe. A line's only bare '\n' is the one
            // that ends it, because `append` renders through
            // `std.json.Stringify` and so every newline inside a group, an
            // author or a message body has been escaped into two
            // characters. So a newline means that line was finished, and a
            // write torn in half can only ever leave a prefix behind. It
            // is the invariant `patchTornTail` keeps for the writer, and
            // it breaks the moment anybody puts unescaped bytes in a line.
            var rest = win[0 .. nl + 1];
            while (rest.len > 0) {
                const e = std.mem.indexOfScalar(u8, rest, '\n').?;
                const line = rest[0..e];
                rest = rest[e + 1 ..];
                const line_end = self.offset + e + 1;

                _ = arena.reset(.retain_capacity);
                const parsed = try parseLineStrict(arena.allocator(), line) orelse {
                    self.offset = line_end;
                    continue;
                };

                // No seq is no cursor, and a seq already handed out is a
                // message already sent. Either way the line is dropped and
                // the offset moves past it: standing still here is the one
                // failure that never recovers.
                if (parsed.seq == 0 or parsed.seq <= self.seq) {
                    self.offset = line_end;
                    continue;
                }

                if (self.behind_expect) |want| {
                    self.behind_expect = null;
                    if (parsed.seq > want and !self.behind_warned) {
                        self.behind_warned = true;
                        log.warn(
                            "chat log: the archive fell behind a rotation; " ++
                                "expected={d} got={d}",
                            .{ want, parsed.seq },
                        );
                    }
                }

                // A `from` that will not parse reads as zero rather than
                // dropping the line. `history` is right to drop it -- it
                // identifies a terminal by it -- but here dropping would
                // keep a real message out of the archive for good over a
                // field nothing downstream is even given.
                const from = std.fmt.parseUnsigned(Bus.Id, parsed.from, 0) catch 0;

                // Braced so that the three strings stop being this block's
                // business the moment the list has taken them on. Left in
                // the enclosing scope their `errdefer`s would still be
                // armed at the `toOwnedSlice` below, and an allocator that
                // failed there would free each string twice: once from
                // here, and once more from the page-wide `errdefer` that
                // by then owns the very same entry.
                {
                    const group = try alloc.dupe(u8, parsed.group);
                    errdefer alloc.free(group);
                    const author = try alloc.dupe(u8, parsed.author);
                    errdefer alloc.free(author);
                    const text = try alloc.dupe(u8, parsed.text);
                    errdefer alloc.free(text);

                    try out.append(alloc, .{
                        .seq = parsed.seq,
                        .at_ms = parsed.at_ms,
                        .group = group,
                        .from = from,
                        .author = author,
                        .summary = parsed.summary,
                        .text = text,
                    });
                }

                // The bytes are only counted as read once the whole entry
                // is in the page. Run out of memory at any step above and
                // the offset is still at the start of this line: the
                // errdefer clears the half-built page, the caller treats
                // it as a failure and comes back from the cursor, and not
                // one message is lost.
                self.offset = line_end;
                self.seq = @max(self.seq, parsed.seq);
                taken += parsed.text.len;

                if (out.items.len >= limit or taken >= max_bytes)
                    return .{ .entries = try out.toOwnedSlice(alloc), .exhausted = false };
            }
        }
    }

    /// Say it once. A quiet minute is asked about twice a second, and a
    /// line per attempt would be the only thing in the log.
    fn warnOnce(self: *Tail, err: anyerror) void {
        if (self.warned) return;
        self.warned = true;
        log.warn("chat log: could not follow {s} err={}", .{ self.path, err });
    }
};

/// A generation, opened and positioned, on its way into a `Tail`.
const Hit = struct {
    file: std.Io.File,
    inode: u64,
    offset: u64,
};

/// Which file this is, or zero for "we could not find out".
///
/// Zero is a real answer rather than a failure, and everything that
/// compares inodes is written to know it: an unknown inode must never let
/// a comparison conclude that a rotation happened.
fn inodeOf(io: std.Io, file: std.Io.File) u64 {
    return if (file.stat(io)) |st| @intCast(st.inode) else |_| 0;
}

/// Open `candidate` and check the hint against it, or nothing.
///
/// Opened first and asked about afterwards, rather than `statFile` then
/// open: two path lookups can have a rename between them, and then the
/// inode that was compared is not the inode that will be read.
fn openHinted(io: std.Io, candidate: []const u8, from: Mark) ?Hit {
    const file = std.Io.Dir.openFileAbsolute(io, candidate, .{}) catch return null;

    const st = file.stat(io) catch {
        file.close(io);
        return null;
    };
    if (@as(u64, @intCast(st.inode)) != from.inode or from.offset > st.size) {
        file.close(io);
        return null;
    }

    // The byte before the first unread line is the newline that ended the
    // one before it. Anything else means the offset was measured against
    // something this file no longer holds.
    var b: [1]u8 = undefined;
    const n = file.readPositionalAll(io, &b, from.offset - 1) catch {
        file.close(io);
        return null;
    };
    if (n != 1 or b[0] != '\n') {
        file.close(io);
        return null;
    }

    return .{ .file = file, .inode = from.inode, .offset = from.offset };
}

/// Open a forward read positioned just after `from`.
///
/// The hint in `from` is used only when it checks out: the file it names is
/// still one of the two generations, the offset is inside it, and the byte
/// before it ends a line. Otherwise the log is walked from the oldest
/// generation, skipping everything at or below `from.seq` -- always
/// correct, and paid once per start rather than once per batch.
pub fn tail(
    alloc: Allocator,
    io: std.Io,
    path: []const u8,
    from: Mark,
) Tail.Error!Tail {
    const owned = try alloc.dupe(u8, path);
    errdefer alloc.free(owned);

    const buf = try alloc.alloc(u8, tail_chunk_bytes);
    errdefer alloc.free(buf);

    const rotated = try std.fmt.allocPrint(alloc, "{s}.1", .{path});
    defer alloc.free(rotated);

    var hit: ?Hit = null;
    var current = true;

    // A hint, but only once it has been made to prove itself. Trying the
    // rotated generation as well is free and buys a real case: a Polter
    // that was down while the log rotated picks up where it left off
    // instead of walking the whole thing.
    if (from.inode != 0 and from.offset != 0) {
        if (openHinted(io, path, from)) |h| {
            hit = h;
            current = true;
        } else if (openHinted(io, rotated, from)) |h| {
            hit = h;
            current = false;
        }
    }

    // No hint worth having -- a first start, or one the log has moved on
    // from. Walk from the oldest generation there is and let `next` drop
    // everything at or below `from.seq` on the way past. Always right, and
    // paid once per start rather than once per batch.
    if (hit == null) {
        if (std.Io.Dir.openFileAbsolute(io, rotated, .{})) |f| {
            hit = .{ .file = f, .inode = inodeOf(io, f), .offset = 0 };
            current = false;
        } else |_| {}
    }
    if (hit == null) {
        if (std.Io.Dir.openFileAbsolute(io, path, .{})) |f| {
            hit = .{ .file = f, .inode = inodeOf(io, f), .offset = 0 };
            current = true;
        } else |err| {
            log.warn("chat log: could not follow {s} err={}", .{ path, err });
            return error.OpenFailed;
        }
    }

    const h = hit.?;
    return .{
        .alloc = alloc,
        .io = io,
        .path = owned,
        .file = h.file,
        .inode = h.inode,
        .offset = h.offset,
        .seq = from.seq,
        .buf = buf,
        .current = current,
        .behind_expect = null,
    };
}

/// Why a walk stopped, which is the same question as whether the caller
/// has anything left to ask for.
const Stop = enum {
    /// Off the front of this generation with room to spare. The older one
    /// is next, and if there is no older one the caller has reached the
    /// beginning of what was kept.
    start_of_file,

    /// This generation would not read, or holds a line longer than the
    /// window can see the ends of. Older generations are still worth
    /// trying; the caller has not reached the beginning.
    gave_up,

    /// Full, or out of scanning budget. Nothing older is looked at.
    enough,
};

/// What one `history` call carries from chunk to chunk and from one
/// generation into the next.
const Walk = struct {
    alloc: Allocator,
    io: std.Io,
    group: []const u8,
    before_seq: u64,
    want: usize,

    /// Newest first until the very last step of `history`.
    found: std.ArrayListUnmanaged(Entry) = .empty,

    /// Reset per line rather than freed: one line's worth of JSON is the
    /// most that is ever live at once.
    arena: std.heap.ArenaAllocator,

    /// One window of file, reused for every step back.
    scratch: []u8,

    scanned: u64 = 0,

    /// Reading fails the way writing does: once out loud, then quietly.
    warned: bool = false,

    /// Walk one file backwards from `size` to 0, or until there is no
    /// reason to keep going.
    fn generation(w: *Walk, file: std.Io.File, size: u64) Allocator.Error!Stop {
        var end = size;
        while (end > 0) {
            const start = end -| scan_chunk_bytes;
            const len: usize = @intCast(end - start);

            const n = file.readPositionalAll(w.io, w.scratch[0..len], start) catch |err| {
                w.warnOnce(err);
                return .gave_up;
            };
            // Short of what was asked for leaves a hole in the middle of
            // the range rather than at the end of it, and a hole is the one
            // thing a cursor cannot be walked across.
            if (n != len) return .gave_up;

            var bytes = w.scratch[0..len];
            if (start > 0) {
                // Whatever sits before the first newline began in the
                // window before this one. Give it back rather than parse
                // half of it: the next step reads it whole.
                const nl = std.mem.indexOfScalar(u8, bytes, '\n') orelse return .gave_up;
                const next_end = start + nl + 1;

                // A window that does not move is a window that never ends.
                // Both ways that happens -- no newline at all, or the only
                // one sitting on the last byte -- mean the same thing: a
                // line longer than the window, which `append` cannot even
                // write. Leave this generation to it.
                if (next_end >= end) return .gave_up;

                bytes = bytes[nl + 1 ..];
                end = next_end;
            } else {
                end = 0;
            }

            if (try w.chunk(bytes)) return .enough;
        }
        return .start_of_file;
    }

    /// Walk the whole lines in one window, newest first. True when the
    /// walk should stop here.
    fn chunk(w: *Walk, bytes: []const u8) Allocator.Error!bool {
        // Counted a window at a time rather than a line at a time: the
        // budget is a wall, not a measurement, and overshooting it by one
        // window is cheaper than checking it a thousand times.
        w.scanned += bytes.len;

        var rest = bytes;
        while (rest.len > 0) {
            const nl = std.mem.lastIndexOfScalar(u8, rest, '\n');
            const line = if (nl) |i| rest[i + 1 ..] else rest;
            rest = if (nl) |i| rest[0..i] else rest[0..0];

            _ = w.arena.reset(.retain_capacity);
            const parsed = parseLine(w.arena.allocator(), line) orelse continue;

            // No seq is no cursor. An older Polter wrote lines without one
            // and they are still worth keeping on disk, but handing one
            // back would break the rule the caller pages by -- ask again
            // from the oldest seq you were given -- because it has no seq
            // to be asked from.
            if (parsed.seq == 0) continue;
            if (w.before_seq != 0 and parsed.seq >= w.before_seq) continue;

            // Not redundant, even though the file being walked is one
            // group's own directory. A directory name is a filing decision
            // and `group` is what the line says about itself: two names
            // longer than `max_segment` share a directory when their
            // hashes collide, and a file put there by hand can say
            // anything at all. The line is what is believed.
            if (!std.mem.eql(u8, parsed.group, w.group)) continue;
            const from = std.fmt.parseUnsigned(Bus.Id, parsed.from, 0) catch continue;

            const group = try w.alloc.dupe(u8, parsed.group);
            errdefer w.alloc.free(group);
            const author = try w.alloc.dupe(u8, parsed.author);
            errdefer w.alloc.free(author);
            const text = try w.alloc.dupe(u8, parsed.text);
            errdefer w.alloc.free(text);

            try w.found.append(w.alloc, .{
                .seq = parsed.seq,
                .at_ms = parsed.at_ms,
                .group = group,
                .from = from,
                .author = author,
                .summary = parsed.summary,
                .text = text,
            });
            if (w.found.items.len >= w.want) return true;
        }

        // Out of budget stops the walk short on purpose. A quiet group
        // buried under megabytes of another one's traffic comes back as an
        // empty page with `exhausted = false`, the cursor where it was, and
        // the caller free to ask again -- which is the honest answer, and
        // the only one that does not either block or lie about the end.
        return w.scanned >= history_scan_bytes;
    }

    /// Say it once. A page that stops short is a page the caller will ask
    /// for again, and a log line per attempt would be the only thing in
    /// the log.
    fn warnOnce(w: *Walk, err: anyerror) void {
        if (w.warned) return;
        w.warned = true;
        log.warn("chat log: could not read back err={}", .{err});
    }
};

// -- the record -------------------------------------------------------------
//
// Two shapes, and the difference between them is the whole of this half of
// the file.
//
// `chat.jsonl` is the **stream**. One flat file, rotated by size, two
// generations. It is what the archive follows, and everything that makes
// following it cheap -- one file, one offset, one inode -- rests on it
// staying that shape. Being bounded, it forgets.
//
// `<group>/<YYYY-MM-DD>.jsonl` is the **record**. It is what a person greps
// at nine the next morning and what `group_history` pages through. Nothing
// in it is ever rotated, renamed or removed, so it reaches back further
// than the stream does: the record, not the stream, is the more complete of
// the two. Which is why "if the record breaks, replay the stream" is a
// promise made nowhere here -- it would only ever be true of the last 16MB.
//
// Why group and day, rather than size. A group is the unit a person already
// thinks in ("that Kairos business last night"), and a day is the only
// boundary that is naturally bounded -- a group can live for months, a day
// cannot. The boundaries size-based rotation produces mean nothing to
// anybody: no one has ever wanted to read the second generation.
//
// The record has no size ceiling, and that is what "nothing is ever
// removed" means when written out. The machine this was built on holds
// 2.8MB of chat from a fortnight, so the honest thing is to say the number
// rather than to build a mechanism for it.

/// The record: one directory per group, one file per day, under `dir`.
const Tree = struct {
    alloc: Allocator,
    io: std.Io,

    /// `<state>/chat`. Borrowed from the `ChatLog` that owns it.
    dir: []const u8,

    /// The day file being appended to, if any.
    ///
    /// One at a time rather than one per group: messages arrive one at a
    /// time, and the open a group switch costs is nothing beside the work
    /// that produced the message.
    cur: ?Cur = null,

    /// Reading and writing fail the way the stream's do: once out loud,
    /// then quietly.
    warned: bool = false,

    const Cur = struct {
        /// The raw group name, so that a switch is noticed without
        /// encoding every message's group a second time. Owned.
        group: []const u8,
        day: u32,
        part: u32,
        file: std.Io.File,
        written: u64,
    };

    /// One file in a group's directory, as its name says it is.
    const DayFile = struct {
        day: u32,
        part: u32,

        /// Newest first, which is the direction `history` walks.
        fn newestFirst(_: void, a: DayFile, b: DayFile) bool {
            if (a.day != b.day) return a.day > b.day;
            return a.part > b.part;
        }
    };

    const Days = std.ArrayListUnmanaged(DayFile);

    const Opened = struct { file: std.Io.File, written: u64 };

    /// A wall against a day that never stops. Eight gigabytes in one group
    /// on one day is not a case worth carrying code for; past it the last
    /// part simply keeps growing, which loses nothing.
    const max_parts: u32 = 1000;

    fn deinit(self: *Tree) void {
        self.close();
        self.* = undefined;
    }

    fn close(self: *Tree) void {
        if (self.cur) |*c| {
            c.file.close(self.io);
            self.alloc.free(c.group);
        }
        self.cur = null;
    }

    /// Put one already-rendered line into its group's file for the day.
    ///
    /// Handed the bytes `append` has just written to the stream rather than
    /// rendering them again: the two files then hold the same line byte for
    /// byte, and there is no second renderer to drift.
    ///
    /// **Every failure here is a warning and nothing else, deliberately.**
    /// The stream is what the archive follows and what hands out seq; a full
    /// disk or an unwritable directory must not turn "the record is worse
    /// off" into "the message is gone". It is also why a later reader should
    /// not "fix" this by propagating the error: a gap left here is found and
    /// filled by `backfill` on the next start, because how far the record
    /// goes is measured off the files rather than remembered.
    fn write(self: *Tree, group: []const u8, at_ms: i64, line: []const u8) void {
        self.ensure(group, dayOf(at_ms), line.len) catch |err| {
            self.warnOnce(err);
            return;
        };

        const c = &self.cur.?;
        c.file.writePositionalAll(self.io, line, c.written) catch |err| {
            self.warnOnce(err);
            // Closed rather than kept: reopening on the next message is
            // the cheapest thing that can recover a handle which has gone
            // bad underneath us.
            self.close();
            return;
        };
        c.written += line.len;
    }

    /// Leave `cur` open on the file this message belongs in.
    fn ensure(self: *Tree, group: []const u8, day: u32, want: usize) !void {
        if (self.cur) |*c| {
            if (c.day == day and std.mem.eql(u8, c.group, group)) {
                if (c.written + want <= day_bytes) return;

                // The day is not over, so the day does not end here. It
                // carries on in the part beside it, and nothing is moved
                // aside or dropped to make room.
                const opened = try self.openPart(group, day, c.part + 1);
                c.file.close(self.io);
                c.file = opened.file;
                c.part += 1;
                c.written = opened.written;
                return;
            }
        }

        self.close();

        // How far into the day the parts have got. Probed rather than
        // assumed, because a restart in the middle of a busy day has to
        // land on the end of it and not on top of its beginning.
        var part: u32 = 1;
        var opened = try self.openPart(group, day, part);
        while (opened.written + want > day_bytes and part < max_parts) {
            opened.file.close(self.io);
            part += 1;
            opened = try self.openPart(group, day, part);
        }
        errdefer opened.file.close(self.io);

        const owned = try self.alloc.dupe(u8, group);
        self.cur = .{
            .group = owned,
            .day = day,
            .part = part,
            .file = opened.file,
            .written = opened.written,
        };
    }

    /// Open one part for appending, making the group's directory if it is
    /// not there yet.
    fn openPart(self: *Tree, group: []const u8, day: u32, part: u32) !Opened {
        const path = try self.partPath(self.alloc, group, day, part);
        defer self.alloc.free(path);

        if (std.fs.path.dirname(path)) |parent| {
            std.Io.Dir.cwd().createDirPath(self.io, parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        const file = try openAppend(self.io, path);
        errdefer file.close(self.io);

        var written = if (file.stat(self.io)) |st| st.size else |_| 0;

        // The same invariant the stream keeps, for the same reason: a
        // newline ends a line and nothing else does, so a run that died
        // mid-write does not get its half line joined onto the next one.
        if (written > 0) {
            var last: [1]u8 = undefined;
            const n = file.readPositionalAll(self.io, &last, written - 1) catch 0;
            if (n == 1 and last[0] != '\n') {
                file.writePositionalAll(self.io, "\n", written) catch {};
                written += 1;
            }
        }

        return .{ .file = file, .written = written };
    }

    /// `<dir>/<encoded group>/<YYYY-MM-DD>.jsonl`, or `.partN.jsonl` past
    /// the first. Caller owns it.
    fn partPath(
        self: *const Tree,
        alloc: Allocator,
        group: []const u8,
        day: u32,
        part: u32,
    ) Allocator.Error![]u8 {
        const seg = try encodeGroup(alloc, group);
        defer alloc.free(seg);

        var buf: [64]u8 = undefined;
        return std.fs.path.join(alloc, &.{ self.dir, seg, nameOf(&buf, .{
            .day = day,
            .part = part,
        }) });
    }

    /// What a day file is called.
    fn nameOf(buf: *[64]u8, d: DayFile) []const u8 {
        var ymd: [16]u8 = undefined;
        return (if (d.part <= 1)
            std.fmt.bufPrint(buf, "{s}.jsonl", .{dayName(&ymd, d.day)})
        else
            std.fmt.bufPrint(buf, "{s}.part{d}.jsonl", .{ dayName(&ymd, d.day), d.part })) catch
            unreachable;
    }

    /// `YYYY-MM-DD` out of the packed `YYYYMMDD` a day is carried as.
    ///
    /// Packed as one integer rather than carried as a string because it is
    /// also the sort key `history` walks by, and comparing two `u32` needs
    /// nothing to own or free.
    fn dayName(buf: *[16]u8, day: u32) []const u8 {
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
            day / 10000,
            (day / 100) % 100,
            day % 100,
        }) catch unreachable;
    }

    /// The day file `name` is, or null when it is not one.
    fn parseDayFile(name: []const u8) ?DayFile {
        if (!std.mem.endsWith(u8, name, ".jsonl")) return null;
        const stem = name[0 .. name.len - ".jsonl".len];
        if (stem.len < 10) return null;

        const day = parseDay(stem[0..10]) orelse return null;
        const rest = stem[10..];
        if (rest.len == 0) return .{ .day = day, .part = 1 };

        if (!std.mem.startsWith(u8, rest, ".part")) return null;
        const n = std.fmt.parseUnsigned(u32, rest[".part".len..], 10) catch return null;

        // `.part1` is not a name this writes, so a file called that came
        // from somewhere else and would sort into the same place as the
        // day's first part.
        if (n < 2) return null;
        return .{ .day = day, .part = n };
    }

    /// `YYYY-MM-DD` back into the packed integer, or null.
    fn parseDay(s: []const u8) ?u32 {
        if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
        const y = std.fmt.parseUnsigned(u32, s[0..4], 10) catch return null;
        const m = std.fmt.parseUnsigned(u32, s[5..7], 10) catch return null;
        const d = std.fmt.parseUnsigned(u32, s[8..10], 10) catch return null;
        if (m < 1 or m > 12 or d < 1 or d > 31) return null;
        return y * 10000 + m * 100 + d;
    }

    /// Every day file a group has, newest first. Caller owns the list.
    fn days(self: *const Tree, alloc: Allocator, group: []const u8) Allocator.Error!Days {
        const seg = try encodeGroup(alloc, group);
        defer alloc.free(seg);
        return self.daysIn(alloc, seg);
    }

    /// The same, for a directory name that is already encoded.
    fn daysIn(self: *const Tree, alloc: Allocator, seg: []const u8) Allocator.Error!Days {
        var out: Days = .empty;
        errdefer out.deinit(alloc);

        const path = try std.fs.path.join(alloc, &.{ self.dir, seg });
        defer alloc.free(path);

        // A group nothing was ever said in has no directory, and that is
        // an answer rather than a failure: it has no days.
        var d = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return out;
        defer d.close(self.io);

        var it = d.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind == .directory) continue;
            const parsed = parseDayFile(entry.name) orelse continue;
            try out.append(alloc, parsed);
        }

        std.mem.sort(DayFile, out.items, {}, DayFile.newestFirst);
        return out;
    }

    /// The highest seq the record already holds, or null when that cannot
    /// be worked out.
    ///
    /// Null is a real answer and the callers are written to know it. The
    /// only thing that reads this is `backfill`, and filling in from a
    /// floor nobody is sure of would write a second copy of messages that
    /// are already there. A record short by a stretch is fixed by the next
    /// start; a record holding everything twice is fixed by nothing.
    fn head(self: *Tree) ?u64 {
        var d = std.Io.Dir.cwd().openDir(self.io, self.dir, .{ .iterate = true }) catch
            return null;
        defer d.close(self.io);

        var best: u64 = 0;
        var it = d.iterate();
        while (it.next(self.io) catch null) |entry| {
            // `readdir` reports `unknown` on some filesystems, and the flat
            // stream files live in this directory too.
            const kind = if (entry.kind != .unknown) entry.kind else k: {
                const st = d.statFile(self.io, entry.name, .{
                    .follow_symlinks = false,
                }) catch continue;
                break :k st.kind;
            };
            if (kind != .directory) continue;

            const got = self.groupHead(entry.name) orelse return null;
            best = @max(best, got);
        }
        return best;
    }

    /// The highest seq in one group's newest day file, or null when it
    /// holds lines but none that can be read.
    ///
    /// The newest file is enough: the record is written in seq order, so a
    /// group's largest number is always in its last file.
    fn groupHead(self: *Tree, seg: []const u8) ?u64 {
        var list = self.daysIn(self.alloc, seg) catch return null;
        defer list.deinit(self.alloc);

        // A directory with no day files in it is not part of the record.
        if (list.items.len == 0) return 0;

        var buf: [64]u8 = undefined;
        const path = std.fs.path.join(self.alloc, &.{
            self.dir,
            seg,
            nameOf(&buf, list.items[0]),
        }) catch return null;
        defer self.alloc.free(path);

        const file = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch return null;
        defer file.close(self.io);

        const end = if (file.stat(self.io)) |st| st.size else |_| return null;
        if (end == 0) return 0;
        return tailSeq(self.alloc, self.io, file, end);
    }

    fn warnOnce(self: *Tree, err: anyerror) void {
        if (self.warned) return;
        self.warned = true;
        log.warn("chat log: could not write the record under {s} err={}", .{ self.dir, err });
    }
};

/// A group name as one path segment, and nothing else.
///
/// Every byte outside `[A-Za-z0-9._-]` becomes `%XX`, and a leading `.` is
/// escaped as well -- which is what disposes of `.`, `..` and hidden
/// directories in one rule rather than three special cases.
///
/// **Injective, and that is the requirement.** Replacing the awkward bytes
/// with `_` would be shorter and would put `a/b` and `a_b` in the same
/// directory, silently interleaving two groups' records. Percent-encoding
/// keeps every distinct name distinct while leaving the ordinary ones
/// exactly as they were: `kairos-15r` stays `kairos-15r`.
///
/// `Chat.isValidName` already holds group names to 48 bytes of
/// `[a-z0-9-]`, so nothing arriving through the model needs any of this.
/// It is here for what does not arrive that way -- a line read back out of
/// a hand-edited file, or a caller that went around the model -- because a
/// path built out of somebody else's string is exactly the kind of thing
/// that should not depend on a check made in another file.
fn encodeGroup(alloc: Allocator, group: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, group.len + 24);

    var truncated = false;
    for (group, 0..) |c, i| {
        // Whole units only, so the cut below can never land inside a `%XX`
        // and turn one name into a prefix of another.
        if (out.items.len + 3 > max_segment - 20) {
            truncated = true;
            break;
        }

        const plain = switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => true,
            // A leading dot is the whole of what makes `.` and `..`, so it
            // is the one position where a dot is not plain.
            '.' => i != 0,
            else => false,
        };

        if (plain) {
            try out.append(alloc, c);
        } else {
            const hex = "0123456789ABCDEF";
            try out.appendSlice(alloc, &[_]u8{ '%', hex[c >> 4], hex[c & 0xf] });
        }
    }

    if (truncated) {
        // `%%` cannot come out of the loop above -- every `%` it writes is
        // followed by two hex digits -- so this marks a shortened name
        // unambiguously, and the hash keeps two long names apart.
        var buf: [20]u8 = undefined;
        const tag = std.fmt.bufPrint(&buf, "%%{x:0>16}", .{
            std.hash.Wyhash.hash(0, group),
        }) catch unreachable;
        try out.appendSlice(alloc, tag);
    }

    // An empty name would be no segment at all, which would put the file
    // straight into `chat/` beside the stream. One byte that the loop
    // cannot produce says "empty" without colliding with anything.
    if (out.items.len == 0) try out.append(alloc, '%');

    return out.toOwnedSlice(alloc);
}

/// `struct tm`, declared here because the standard library has no binding
/// for it and no timezone handling of its own.
///
/// Declared in full even though three fields are read: `localtime_r` writes
/// into whatever it is given, so a struct short by a field is a buffer
/// overrun. The first nine are POSIX; the last two are a BSD extension that
/// both macOS and glibc have.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timep: *const i64, result: *Tm) ?*Tm;

/// Which day a message belongs to, packed as `YYYYMMDD`.
///
/// The reader's own day rather than UTC, for the same reason the chat
/// window shows local times: somebody asking what happened last night means
/// their night. A file dated eight hours off is worse than no date at all,
/// because it looks right.
///
/// UTC is the fallback rather than the rule -- if libc will not say, a day
/// that may be off by one still beats no file to write into.
fn dayOf(at_ms: i64) u32 {
    const secs: i64 = @divFloor(at_ms, std.time.ms_per_s);

    var tm: Tm = undefined;
    if (localtime_r(&secs, &tm) != null) {
        const y: i64 = @as(i64, tm.year) + 1900;
        const m: i64 = @as(i64, tm.mon) + 1;
        const d: i64 = tm.mday;
        if (y >= 0 and y <= 9999 and m >= 1 and m <= 12 and d >= 1 and d <= 31)
            return @intCast(y * 10000 + m * 100 + d);
    }

    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(secs, 0)) };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return @as(u32, yd.year) * 10000 +
        @as(u32, md.month.numeric()) * 100 +
        md.day_index + 1;
}

/// Fill the record in from the stream, if it has fallen behind.
///
/// The record can only ever lag by a suffix: both are written in one call,
/// stream first, in seq order. So everything the record is missing is above
/// the highest seq it holds, which makes `Tree.head` an exact starting
/// point rather than an estimate -- and that in turn is what makes this
/// safe to run on every start. A marker file saying "already done" can be
/// wrong; a number measured off the files themselves cannot be.
///
/// Steady state is one 64KB read per group directory and nothing written.
///
/// What it cannot fill in is what the stream has already forgotten: the
/// stream rotates at 8MB and keeps two generations. That is not a hole this
/// can close, and it is the reason the record rather than the stream is the
/// fuller of the two.
fn backfill(self: *ChatLog) void {
    const floor = self.tree.head() orelse {
        log.warn(
            "chat log: could not tell how far the record goes; not filling it in",
            .{},
        );
        return;
    };
    if (floor >= self.head()) return;

    const old = std.fmt.allocPrint(self.alloc, "{s}.1", .{self.path}) catch return;
    defer self.alloc.free(old);

    // Oldest generation first, so the record is written in the same order a
    // live run writes it.
    self.replay(old, floor);
    self.replay(self.path, floor);
}

/// Copy every line of one stream generation above `floor` into the record.
///
/// A file that is not there is the ordinary case, not a failure: most logs
/// never rotate.
fn replay(self: *ChatLog, path: []const u8, floor: u64) void {
    const file = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch return;
    defer file.close(self.io);

    const buf = self.alloc.alloc(u8, tail_chunk_bytes) catch return;
    defer self.alloc.free(buf);

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();

    var offset: u64 = 0;
    while (true) {
        const n = file.readPositionalAll(self.io, buf, offset) catch return;
        if (n == 0) return;

        const win = buf[0..n];
        const nl = std.mem.lastIndexOfScalar(u8, win, '\n') orelse {
            // Short of a window with no newline is a torn tail, which is
            // not a line yet. A full window with none is a line longer
            // than `append` can write; step over it rather than spin.
            if (n < buf.len) return;
            offset += n;
            continue;
        };

        var rest = win[0 .. nl + 1];
        while (rest.len > 0) {
            const e = std.mem.indexOfScalar(u8, rest, '\n').?;
            const line = rest[0 .. e + 1];
            rest = rest[e + 1 ..];

            _ = arena.reset(.retain_capacity);
            const parsed = parseLine(arena.allocator(), line[0..e]) orelse continue;
            if (parsed.seq == 0 or parsed.seq <= floor) continue;

            // The line goes across as it was written, not re-rendered:
            // the record then holds the stream's own bytes.
            self.tree.write(parsed.group, parsed.at_ms, line);
        }

        offset += nl + 1;
    }
}

const testing = std.testing;

/// A scratch state directory, laid out the way `open` expects one.
fn testDir(alloc: Allocator, io: std.Io) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-chatlog-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

test "a fresh log starts counting at one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();

    try testing.expectEqual(@as(u64, 1), l.append("build", 7, "worker", 1000, false, "hi"));
    try testing.expectEqual(@as(u64, 2), l.append("build", 7, "worker", 1001, false, "again"));
}

test "reopening carries on from the file rather than from one" {
    // The whole point of the log's own numbering: a cursor handed out last
    // night has to still mean the same line this morning.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    {
        var l = try ChatLog.open(testing.allocator, io, dir);
        defer l.deinit();
        _ = l.append("build", 7, "worker", 1000, false, "one");
        _ = l.append("build", 7, "worker", 1001, false, "two");
        _ = l.append("build", 7, "worker", 1002, false, "three");
    }

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();
    try testing.expectEqual(@as(u64, 4), l.next_seq);
    try testing.expectEqual(@as(u64, 4), l.append("build", 7, "worker", 1003, false, "four"));
}

test "a torn last line neither loses the count nor swallows the next message" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const path = try std.fs.path.join(alloc, &.{ dir, "chat", "chat.jsonl" });
    const half = "{\"seq\":3,\"at_ms\":1002,\"gro";
    {
        var l = try ChatLog.open(testing.allocator, io, dir);
        defer l.deinit();
        _ = l.append("build", 7, "worker", 1000, false, "one");
        _ = l.append("build", 7, "worker", 1001, false, "two");

        // What a crash mid-write leaves behind.
        try l.file.writePositionalAll(io, half, l.written);
    }

    {
        var l = try ChatLog.open(testing.allocator, io, dir);
        defer l.deinit();

        // The wreckage is skipped, not counted.
        try testing.expectEqual(@as(u64, 3), l.next_seq);
        _ = l.append("build", 7, "worker", 1003, false, "three");
    }

    // And the new message is a line of its own.
    const f = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer f.close(io);
    const size: usize = @intCast((try f.stat(io)).size);
    const body = try alloc.alloc(u8, size);
    _ = try f.readPositionalAll(io, body, 0);

    var lines = std.mem.splitScalar(u8, body[0 .. body.len - 1], '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        // The wreckage stands alone; nothing was appended onto the end of
        // it, which is the failure the patch exists to prevent.
        if (n == 2) try testing.expectEqualStrings(half, line);
        if (n == 3) try testing.expect(std.mem.startsWith(u8, line, "{\"seq\":3,"));
    }
    try testing.expectEqual(@as(usize, 4), n);
}

test "an empty file recovers nothing rather than guessing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();

    try testing.expectEqual(@as(u64, 0), l.written);
    try testing.expectEqual(@as(u64, 1), l.next_seq);
}

test "the count survives a rotation it did not see" {
    // Restarting just after a rotation finds an empty current file. Only
    // the generation moved aside knows how far the numbering had got.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const path = try std.fs.path.join(alloc, &.{ dir, "chat", "chat.jsonl" });
    const rotated = try std.fmt.allocPrint(alloc, "{s}.1", .{path});

    {
        var l = try ChatLog.open(testing.allocator, io, dir);
        defer l.deinit();
        _ = l.append("build", 7, "worker", 1000, false, "one");
        _ = l.append("build", 7, "worker", 1001, false, "two");
    }

    // Rotation, done to the files rather than by filling 8MB.
    try std.Io.Dir.renameAbsolute(path, rotated, io);

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();
    try testing.expectEqual(@as(u64, 3), l.append("build", 7, "worker", 1002, false, "three"));
}

/// The five messages the paging tests below all read back, interleaved
/// with another group's so that filtering has something to fail at.
fn testSeed(l: *ChatLog) void {
    _ = l.append("build", 0xdeadbeef, "worker-core", 1000, false, "one");
    _ = l.append("research", 0xdeadbeef, "worker-core", 1001, false, "x");
    _ = l.append("build", 0xdeadbeef, "worker-core", 1002, false, "two");
    _ = l.append("build", 0xdeadbeef, "worker-core", 1003, true, "three");
    _ = l.append("research", 0xdeadbeef, "worker-core", 1004, false, "y");
}

test "history hands back one group's messages, oldest first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();
    testSeed(&l);

    // Read back through the same handle that just wrote it: what the log
    // holds is what is on the disk, not what is still in a buffer.
    const page = try l.history(testing.allocator, "build", 0, 10);
    defer ChatLog.freePage(testing.allocator, page);

    try testing.expectEqual(@as(usize, 3), page.entries.len);
    try testing.expect(page.exhausted);

    try testing.expectEqual(@as(u64, 1), page.entries[0].seq);
    try testing.expectEqual(@as(u64, 3), page.entries[1].seq);
    try testing.expectEqual(@as(u64, 4), page.entries[2].seq);

    try testing.expectEqualStrings("one", page.entries[0].text);
    try testing.expectEqualStrings("two", page.entries[1].text);
    try testing.expectEqualStrings("three", page.entries[2].text);

    try testing.expect(!page.entries[0].summary);
    try testing.expect(page.entries[2].summary);

    for (page.entries) |e| {
        try testing.expectEqualStrings("build", e.group);
        try testing.expectEqualStrings("worker-core", e.author);
        try testing.expectEqual(@as(Bus.Id, 0xdeadbeef), e.from);
    }
    try testing.expectEqual(@as(i64, 1000), page.entries[0].at_ms);
    try testing.expectEqual(@as(i64, 1003), page.entries[2].at_ms);
}

test "before_seq is a bound the page never touches" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();
    testSeed(&l);

    {
        const page = try l.history(testing.allocator, "build", 4, 10);
        defer ChatLog.freePage(testing.allocator, page);

        try testing.expectEqual(@as(usize, 2), page.entries.len);
        try testing.expectEqual(@as(u64, 1), page.entries[0].seq);
        try testing.expectEqual(@as(u64, 3), page.entries[1].seq);
    }

    // And the loop a caller actually runs: hand the oldest seq you were
    // given back as the next bound, and the two pages meet without an
    // overlap and without a gap.
    const first = try l.history(testing.allocator, "build", 0, 2);
    defer ChatLog.freePage(testing.allocator, first);
    try testing.expectEqual(@as(usize, 2), first.entries.len);
    try testing.expectEqual(@as(u64, 3), first.entries[0].seq);
    try testing.expectEqual(@as(u64, 4), first.entries[1].seq);

    const second = try l.history(testing.allocator, "build", first.entries[0].seq, 2);
    defer ChatLog.freePage(testing.allocator, second);
    try testing.expectEqual(@as(usize, 1), second.entries.len);
    try testing.expectEqual(@as(u64, 1), second.entries[0].seq);
    try testing.expect(second.exhausted);
}

test "a page that fills up says there may be more" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();
    for (0..5) |i| {
        _ = l.append("build", 1, "worker", @intCast(1000 + i), false, "hi");
    }

    {
        const page = try l.history(testing.allocator, "build", 0, 2);
        defer ChatLog.freePage(testing.allocator, page);
        try testing.expectEqual(@as(usize, 2), page.entries.len);
        try testing.expect(!page.exhausted);
    }
    {
        const page = try l.history(testing.allocator, "build", 0, 100);
        defer ChatLog.freePage(testing.allocator, page);
        try testing.expectEqual(@as(usize, 5), page.entries.len);
        try testing.expect(page.exhausted);
    }
}

test "asking for nothing reads nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();
    testSeed(&l);

    // Not `exhausted`: a caller that asked for nothing has not been told
    // anything about where the beginning is.
    const page = try l.history(testing.allocator, "build", 0, 0);
    try testing.expectEqual(@as(usize, 0), page.entries.len);
    try testing.expect(!page.exhausted);
}

test "a line with no seq is not a line a cursor can point at" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();

    _ = l.append("build", 1, "worker", 1000, false, "one");

    // What an older Polter left behind: a real message, in the right
    // group, with no number to page by.
    const legacy = "{\"at_ms\":1001,\"group\":\"build\",\"from\":\"0x0000000000000001\"," ++
        "\"author\":\"worker\",\"text\":\"legacy\"}\n";
    const day = try testDayPath(alloc, &l, "build", 1000);
    try testGraft(&l, io, day, legacy);

    _ = l.append("build", 1, "worker", 1002, false, "three");

    const page = try l.history(testing.allocator, "build", 0, 10);
    defer ChatLog.freePage(testing.allocator, page);

    try testing.expectEqual(@as(usize, 2), page.entries.len);
    try testing.expectEqualStrings("one", page.entries[0].text);
    try testing.expectEqualStrings("three", page.entries[1].text);
    try testing.expect(page.exhausted);
}

test "paging back over a file larger than one window loses nothing at the seams" {
    // The seam between two windows is where a backwards walk goes wrong,
    // and one window is 128KB, so the only way to test it is to write
    // more than that.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();

    const total: usize = 2500;
    const filler = "x" ** 200;
    for (1..total + 1) |i| {
        const text = try std.fmt.allocPrint(alloc, "{d}-{s}", .{ i, filler });
        try testing.expectEqual(@as(u64, i), l.append("build", 1, "worker", 1000, false, text));
    }

    // Every seq exactly once, and the pages abut.
    const seen = try alloc.alloc(bool, total + 1);
    @memset(seen, false);

    var before: u64 = 0;
    var count: usize = 0;
    while (true) {
        const page = try l.history(testing.allocator, "build", before, 200);
        defer ChatLog.freePage(testing.allocator, page);

        for (page.entries, 0..) |e, i| {
            if (i > 0) try testing.expectEqual(page.entries[i - 1].seq + 1, e.seq);
            try testing.expect(!seen[@intCast(e.seq)]);
            seen[@intCast(e.seq)] = true;
            count += 1;
        }

        if (page.entries.len > 0) {
            const newest = page.entries[page.entries.len - 1].seq;
            if (before != 0) try testing.expectEqual(before, newest + 1);
            before = page.entries[0].seq;
        }
        if (page.exhausted) break;
        try testing.expect(page.entries.len > 0);
    }

    try testing.expectEqual(total, count);
    for (seen[1..]) |s| try testing.expect(s);

    // And the wall a caller cannot argue with.
    const greedy = try l.history(testing.allocator, "build", 0, 1000);
    defer ChatLog.freePage(testing.allocator, greedy);
    try testing.expectEqual(@as(usize, 200), greedy.entries.len);
    try testing.expect(!greedy.exhausted);
}

test "a log nothing was ever said into is already at its beginning" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();

    // Nothing to read is not the same as could not read: the caller has
    // seen everything there is and must be told to stop asking.
    const page = try l.history(testing.allocator, "build", 0, 10);
    defer ChatLog.freePage(testing.allocator, page);
    try testing.expectEqual(@as(usize, 0), page.entries.len);
    try testing.expect(page.exhausted);

    // Same answer for a group that was never spoken in at all.
    const other = try l.history(testing.allocator, "never-mentioned", 0, 10);
    defer ChatLog.freePage(testing.allocator, other);
    try testing.expectEqual(@as(usize, 0), other.entries.len);
    try testing.expect(other.exhausted);
}

test "a line longer than the window stops the walk instead of spinning on it" {
    // The seam is where a backwards walk can fail to move, and a walk that
    // does not move never returns. A line the window cannot see both ends
    // of is the one way that happens -- `append` cannot write one, but a
    // foreign hand editing the file can. It has to end the walk of that day
    // file, and it has to leave the caller told there is more rather than
    // told it has reached the beginning.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();

    _ = l.append("build", 1, "worker", 1000, false, "buried");

    const giant = try alloc.alloc(u8, scan_chunk_bytes + 64 * 1024);
    @memset(giant, 'x');
    giant[giant.len - 1] = '\n';
    const day = try testDayPath(alloc, &l, "build", 1000);
    try testGraft(&l, io, day, giant);

    _ = l.append("build", 1, "worker", 1002, false, "reachable");

    const page = try l.history(testing.allocator, "build", 0, 10);
    defer ChatLog.freePage(testing.allocator, page);

    // Everything on the near side of the wall, and nothing beyond it.
    try testing.expectEqual(@as(usize, 1), page.entries.len);
    try testing.expectEqualStrings("reachable", page.entries[0].text);
    try testing.expect(!page.exhausted);
}

test "a tail reads forward from nothing and hands back what was written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();

    _ = l.append("build", 0xdeadbeef, "worker-core", 1000, false, "one");
    _ = l.append("research", 0xdeadbeef, "other", 1001, false, "two");
    _ = l.append("build", 0xdeadbeef, "worker-core", 1002, true, "three");

    var t = try ChatLog.tail(testing.allocator, io, l.path, .{});
    defer t.deinit();

    const page = try t.next(testing.allocator, 10, 1 << 20);
    defer ChatLog.freePage(testing.allocator, page);

    try testing.expectEqual(@as(usize, 3), page.entries.len);
    try testing.expect(page.exhausted);

    try testing.expectEqual(@as(u64, 1), page.entries[0].seq);
    try testing.expectEqual(@as(u64, 2), page.entries[1].seq);
    try testing.expectEqual(@as(u64, 3), page.entries[2].seq);

    try testing.expectEqualStrings("one", page.entries[0].text);
    try testing.expectEqualStrings("two", page.entries[1].text);
    try testing.expectEqualStrings("three", page.entries[2].text);

    // Every group, unfiltered: deciding who may see what is the archive's
    // job, and it cannot make that decision about lines it never sees.
    try testing.expectEqualStrings("build", page.entries[0].group);
    try testing.expectEqualStrings("research", page.entries[1].group);
    try testing.expectEqualStrings("other", page.entries[1].author);

    try testing.expectEqual(@as(i64, 1002), page.entries[2].at_ms);
    try testing.expectEqual(@as(Bus.Id, 0xdeadbeef), page.entries[0].from);
    try testing.expect(!page.entries[0].summary);
    try testing.expect(page.entries[2].summary);

    try testing.expectEqual(@as(u64, 3), t.seq);
}

test "a tail that has caught up says so and picks up the next line later" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();

    _ = l.append("build", 1, "worker", 1000, false, "one");
    _ = l.append("build", 1, "worker", 1001, false, "two");

    var t = try ChatLog.tail(testing.allocator, io, l.path, .{});
    defer t.deinit();

    {
        const page = try t.next(testing.allocator, 10, 1 << 20);
        defer ChatLog.freePage(testing.allocator, page);
        try testing.expectEqual(@as(usize, 2), page.entries.len);
        try testing.expect(page.exhausted);
    }

    // A quiet minute is an ordinary answer, not a failure.
    {
        const page = try t.next(testing.allocator, 10, 1 << 20);
        defer ChatLog.freePage(testing.allocator, page);
        try testing.expectEqual(@as(usize, 0), page.entries.len);
        try testing.expect(page.exhausted);
    }

    // And a read-only handle sees bytes another handle wrote after it was
    // opened, which is the whole basis for not sharing the writer's.
    _ = l.append("build", 1, "worker", 1002, false, "three");
    {
        const page = try t.next(testing.allocator, 10, 1 << 20);
        defer ChatLog.freePage(testing.allocator, page);
        try testing.expectEqual(@as(usize, 1), page.entries.len);
        try testing.expectEqual(@as(u64, 3), page.entries[0].seq);
        try testing.expectEqualStrings("three", page.entries[0].text);
    }
}

test "a tail stops at the limit and resumes exactly there" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();
    for (0..5) |i| {
        _ = l.append("build", 1, "worker", @intCast(1000 + i), false, "hi");
    }

    var t = try ChatLog.tail(testing.allocator, io, l.path, .{});
    defer t.deinit();

    for ([_]u64{ 1, 3 }) |first| {
        const page = try t.next(testing.allocator, 2, 1 << 20);
        defer ChatLog.freePage(testing.allocator, page);
        try testing.expectEqual(@as(usize, 2), page.entries.len);
        try testing.expectEqual(first, page.entries[0].seq);
        try testing.expectEqual(first + 1, page.entries[1].seq);
        try testing.expect(!page.exhausted);
    }
    {
        const page = try t.next(testing.allocator, 2, 1 << 20);
        defer ChatLog.freePage(testing.allocator, page);
        try testing.expectEqual(@as(usize, 1), page.entries.len);
        try testing.expectEqual(@as(u64, 5), page.entries[0].seq);
        try testing.expect(page.exhausted);
    }

    // A budget smaller than a single message still buys one message. The
    // alternative is an archive that returns an empty page forever the
    // first time somebody pastes something large.
    var t2 = try ChatLog.tail(testing.allocator, io, l.path, .{});
    defer t2.deinit();
    const page = try t2.next(testing.allocator, 100, 1);
    defer ChatLog.freePage(testing.allocator, page);
    try testing.expectEqual(@as(usize, 1), page.entries.len);
    try testing.expectEqual(@as(u64, 1), page.entries[0].seq);
}

test "a half written line is not a line yet" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();

    _ = l.append("build", 1, "worker", 1000, false, "one");
    _ = l.append("build", 1, "worker", 1001, false, "two");

    var t = try ChatLog.tail(testing.allocator, io, l.path, .{});
    defer t.deinit();

    {
        const page = try t.next(testing.allocator, 10, 1 << 20);
        defer ChatLog.freePage(testing.allocator, page);
        try testing.expectEqual(@as(usize, 2), page.entries.len);
    }

    // What a write torn in half leaves on the disk. `written` is not moved
    // on, because the writer has not finished either.
    const whole = "{\"seq\":3,\"at_ms\":1002,\"group\":\"build\"," ++
        "\"from\":\"0x0000000000000001\",\"author\":\"worker\",\"text\":\"three\"}\n";
    const half = whole[0..30];
    try l.file.writePositionalAll(io, half, l.written);

    {
        const page = try t.next(testing.allocator, 10, 1 << 20);
        defer ChatLog.freePage(testing.allocator, page);
        try testing.expectEqual(@as(usize, 0), page.entries.len);
        try testing.expect(page.exhausted);
    }

    try l.file.writePositionalAll(io, whole[30..], l.written + half.len);
    l.written += whole.len;

    {
        const page = try t.next(testing.allocator, 10, 1 << 20);
        defer ChatLog.freePage(testing.allocator, page);
        try testing.expectEqual(@as(usize, 1), page.entries.len);
        try testing.expectEqual(@as(u64, 3), page.entries[0].seq);
        try testing.expectEqualStrings("three", page.entries[0].text);
    }
}

test "a tail rolls out of the rotated generation into the new one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const path = try defaultPath(alloc, dir);
    const rotated = try std.fmt.allocPrint(alloc, "{s}.1", .{path});

    var t: Tail = undefined;
    var old_inode: u64 = 0;
    {
        var l = try ChatLog.open(testing.allocator, io, dir);
        defer l.deinit();
        _ = l.append("build", 1, "worker", 1000, false, "one");
        _ = l.append("build", 1, "worker", 1001, false, "two");

        t = try ChatLog.tail(testing.allocator, io, path, .{});
        old_inode = t.inode;

        const page = try t.next(testing.allocator, 10, 1 << 20);
        defer ChatLog.freePage(testing.allocator, page);
        try testing.expectEqual(@as(usize, 2), page.entries.len);

        // Written after the read caught up and before the rename: these
        // bytes are only reachable through the handle already open on
        // them, which is why the end of a generation has to be read before
        // anything is concluded from an inode.
        _ = l.append("build", 1, "worker", 1002, false, "three");
    }
    defer t.deinit();

    try std.Io.Dir.renameAbsolute(path, rotated, io);

    var l2 = try ChatLog.open(testing.allocator, io, dir);
    defer l2.deinit();
    try testing.expectEqual(@as(u64, 4), l2.append("build", 1, "worker", 1003, false, "four"));

    const page = try t.next(testing.allocator, 10, 1 << 20);
    defer ChatLog.freePage(testing.allocator, page);

    try testing.expectEqual(@as(usize, 2), page.entries.len);
    try testing.expectEqual(@as(u64, 3), page.entries[0].seq);
    try testing.expectEqualStrings("three", page.entries[0].text);
    try testing.expectEqual(@as(u64, 4), page.entries[1].seq);
    try testing.expectEqualStrings("four", page.entries[1].text);

    // The numbering did not go backwards over the switch, and the mark now
    // names the generation being appended to.
    try testing.expectEqual(@as(u64, 4), t.seq);
    try testing.expect(t.current);
    try testing.expect(t.mark().inode != old_inode);
    try testing.expect(t.mark().inode != 0);
}

test "a mark taken and reopened lands on the same line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();
    for (0..4) |i| {
        _ = l.append("build", 1, "worker", @intCast(1000 + i), false, "hi");
    }

    var m: Mark = undefined;
    {
        var t = try ChatLog.tail(testing.allocator, io, l.path, .{});
        defer t.deinit();

        const page = try t.next(testing.allocator, 2, 1 << 20);
        defer ChatLog.freePage(testing.allocator, page);
        try testing.expectEqual(@as(u64, 2), page.entries[1].seq);
        m = t.mark();
    }
    try testing.expect(m.offset != 0);

    var t = try ChatLog.tail(testing.allocator, io, l.path, m);
    defer t.deinit();

    // The hint was believed, rather than a scan happening to land right.
    try testing.expectEqual(m.offset, t.offset);
    try testing.expectEqual(m.inode, t.inode);

    const page = try t.next(testing.allocator, 10, 1 << 20);
    defer ChatLog.freePage(testing.allocator, page);
    try testing.expectEqual(@as(usize, 2), page.entries.len);
    try testing.expectEqual(@as(u64, 3), page.entries[0].seq);
    try testing.expectEqual(@as(u64, 4), page.entries[1].seq);
}

test "a mark whose offset points at nonsense still finds the place" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();
    for (0..4) |i| {
        _ = l.append("build", 1, "worker", @intCast(1000 + i), false, "hi");
    }

    var m: Mark = undefined;
    {
        var t = try ChatLog.tail(testing.allocator, io, l.path, .{});
        defer t.deinit();
        const page = try t.next(testing.allocator, 2, 1 << 20);
        defer ChatLog.freePage(testing.allocator, page);
        m = t.mark();
    }

    const spoiled = [_]Mark{
        // Inside a line rather than after one.
        .{ .seq = m.seq, .offset = m.offset - 3, .inode = m.inode },
        // Measured against some other file entirely.
        .{ .seq = m.seq, .offset = m.offset, .inode = 999_999 },
    };

    for (spoiled) |bad| {
        var t = try ChatLog.tail(testing.allocator, io, l.path, bad);
        defer t.deinit();

        // The hint was refused, so the walk starts at the front.
        try testing.expectEqual(@as(u64, 0), t.offset);

        // And being right never depended on the hint being right.
        const page = try t.next(testing.allocator, 10, 1 << 20);
        defer ChatLog.freePage(testing.allocator, page);
        try testing.expectEqual(@as(usize, 2), page.entries.len);
        try testing.expectEqual(@as(u64, 3), page.entries[0].seq);
        try testing.expectEqual(@as(u64, 4), page.entries[1].seq);
    }
}

test "a mark from a file that has since rotated is not believed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const path = try defaultPath(alloc, dir);
    const rotated = try std.fmt.allocPrint(alloc, "{s}.1", .{path});

    var m: Mark = undefined;
    {
        var l = try ChatLog.open(testing.allocator, io, dir);
        defer l.deinit();
        _ = l.append("build", 1, "worker", 1000, false, "one");
        _ = l.append("build", 1, "worker", 1001, false, "two");
        _ = l.append("build", 1, "worker", 1002, false, "three");

        var t = try ChatLog.tail(testing.allocator, io, path, .{});
        defer t.deinit();
        const page = try t.next(testing.allocator, 2, 1 << 20);
        defer ChatLog.freePage(testing.allocator, page);
        try testing.expectEqual(@as(u64, 2), page.entries[1].seq);
        m = t.mark();
    }

    // One rotation. The hint still names a file that is there, so it is
    // still worth having -- it just names the one moved aside.
    try std.Io.Dir.renameAbsolute(path, rotated, io);
    {
        var l = try ChatLog.open(testing.allocator, io, dir);
        defer l.deinit();
        _ = l.append("build", 1, "worker", 1003, false, "four");
        _ = l.append("build", 1, "worker", 1004, false, "five");

        var t = try ChatLog.tail(testing.allocator, io, path, m);
        defer t.deinit();
        try testing.expectEqual(m.offset, t.offset);
        try testing.expect(!t.current);

        const page = try t.next(testing.allocator, 10, 1 << 20);
        defer ChatLog.freePage(testing.allocator, page);
        try testing.expectEqual(@as(usize, 3), page.entries.len);
        try testing.expectEqual(@as(u64, 3), page.entries[0].seq);
        try testing.expectEqual(@as(u64, 4), page.entries[1].seq);
        try testing.expectEqual(@as(u64, 5), page.entries[2].seq);
    }

    // A second rotation writes over the generation the hint was measured
    // in. Now neither file matches, and the only honest thing left to do
    // is walk from the oldest generation there is.
    try std.Io.Dir.renameAbsolute(path, rotated, io);
    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();
    _ = l.append("build", 1, "worker", 1005, false, "six");

    var t = try ChatLog.tail(testing.allocator, io, path, m);
    defer t.deinit();
    try testing.expectEqual(@as(u64, 0), t.offset);

    const page = try t.next(testing.allocator, 10, 1 << 20);
    defer ChatLog.freePage(testing.allocator, page);

    // Four and five out of the rotated generation, six out of the current
    // one, and nothing at or below the mark repeated.
    try testing.expectEqual(@as(usize, 3), page.entries.len);
    try testing.expectEqual(@as(u64, 4), page.entries[0].seq);
    try testing.expectEqual(@as(u64, 5), page.entries[1].seq);
    try testing.expectEqual(@as(u64, 6), page.entries[2].seq);
}

test "a line with no seq is skipped without stalling the read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();

    _ = l.append("build", 1, "worker", 1000, false, "one");

    // What an older Polter left behind, and what a stray editor might.
    const legacy = "{\"at_ms\":1001,\"group\":\"build\",\"from\":\"0x0000000000000001\"," ++
        "\"author\":\"worker\",\"text\":\"legacy\"}\n";
    try l.file.writePositionalAll(io, legacy, l.written);
    l.written += legacy.len;

    const junk = "not json at all\n";
    try l.file.writePositionalAll(io, junk, l.written);
    l.written += junk.len;

    _ = l.append("build", 1, "worker", 1002, false, "three");

    var t = try ChatLog.tail(testing.allocator, io, l.path, .{});
    defer t.deinit();

    const page = try t.next(testing.allocator, 10, 1 << 20);
    defer ChatLog.freePage(testing.allocator, page);

    // Two, and the second of them is the proof that the offset moved past
    // the unusable lines rather than stopping on them.
    try testing.expectEqual(@as(usize, 2), page.entries.len);
    try testing.expectEqual(@as(u64, 1), page.entries[0].seq);
    try testing.expectEqual(@as(u64, 2), page.entries[1].seq);
    try testing.expectEqualStrings("three", page.entries[1].text);
    try testing.expect(page.exhausted);
}

test "defaultPath is where open puts the file" {
    // The archive works out the path itself, from another thread, so the
    // two ways of naming the file have to be the same one.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const path = try defaultPath(alloc, dir);

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();
    try testing.expectEqualStrings(path, l.path);

    _ = l.append("build", 1, "worker", 1000, false, "one");

    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    try testing.expect(st.size > 0);
}

test "a tail on a log that is not there says so" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // An archive can be switched on before anybody has said anything. It
    // has to be told that plainly, because the answer is "come back in a
    // moment", not "there is nothing to archive" -- and the two look the
    // same from an empty page.
    const path = try defaultPath(alloc, dir);
    try testing.expectError(
        error.OpenFailed,
        ChatLog.tail(testing.allocator, io, path, .{}),
    );

    // And once there is a log, the same call finds it.
    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();
    var t = try ChatLog.tail(testing.allocator, io, path, .{});
    t.deinit();
}

/// One forward read, start to finish, on whatever allocator it is handed.
fn tailOnePage(alloc: Allocator, io: std.Io, path: []const u8) !void {
    var t = try ChatLog.tail(alloc, io, path, .{});
    defer t.deinit();

    // A limit below what is there, so the page is finished by
    // `toOwnedSlice` rather than by running out of file: that is the one
    // exit where a half-built page and its strings are both still live.
    const page = try t.next(alloc, 3, 1 << 20);
    ChatLog.freePage(alloc, page);
}

test "a forward read that runs out of memory leaves nothing behind" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();
    for (0..5) |i| {
        _ = l.append("build", 1, "worker", @intCast(1000 + i), false, "hi");
    }

    // Every allocation in the path failed in turn. The page is built one
    // string at a time out of a file that is being appended to, so a leak
    // here would be a slow one that nothing else in the suite could see.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        tailOnePage,
        .{ io, l.path },
    );
}

/// The record file a message written at `at_ms` into `group` lands in.
fn testDayPath(
    alloc: Allocator,
    l: *ChatLog,
    group: []const u8,
    at_ms: i64,
) ![]u8 {
    return l.tree.partPath(alloc, group, dayOf(at_ms), 1);
}

/// Append bytes to a record file behind the log's back, the way a foreign
/// hand or an older Polter would have left them.
///
/// The tree's open handle is closed first: it carries its own idea of
/// where the end is, and the next `append` would write over anything put
/// there without telling it.
fn testGraft(l: *ChatLog, io: std.Io, path: []const u8, bytes: []const u8) !void {
    l.tree.close();

    const f = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
    defer f.close(io);

    const end = (try f.stat(io)).size;
    try f.writePositionalAll(io, bytes, end);
}

test "a group name is one path segment and cannot be anything else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Everything a group name could be that a path must not become.
    const nasty: []const []const u8 = &.{
        "..",
        ".",
        "../../etc/passwd",
        "a/b",
        "/absolute",
        "trailing/",
        "..\\windows",
        "with space",
        "with\nnewline",
        "with\x00nul",
        "",
        ".hidden",
    };

    for (nasty) |name| {
        const seg = try encodeGroup(alloc, name);

        // No separator of any kind, so it cannot be more than one segment.
        try testing.expect(std.mem.indexOfScalar(u8, seg, '/') == null);
        try testing.expect(std.mem.indexOfScalar(u8, seg, '\\') == null);

        // Not the two names that mean somewhere else, and never hidden.
        try testing.expect(!std.mem.eql(u8, seg, "."));
        try testing.expect(!std.mem.eql(u8, seg, ".."));
        try testing.expect(seg.len > 0 and seg[0] != '.');

        // Nothing a filesystem or a person has to guess at.
        for (seg) |c| try testing.expect(c > 0x20 and c < 0x7f);
    }

    // An ordinary name comes through untouched, which is the other half of
    // the requirement: the record is meant to be read by a person.
    const plain = try encodeGroup(alloc, "kairos-15r");
    try testing.expectEqualStrings("kairos-15r", plain);
}

test "two group names that differ end up in two directories" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The reason the encoding is percent and not "replace the awkward
    // bytes with an underscore": these two would land in one directory
    // under that rule, and two groups' records would interleave with
    // nothing anywhere saying so.
    const a = try encodeGroup(alloc, "a/b");
    const b = try encodeGroup(alloc, "a_b");
    try testing.expect(!std.mem.eql(u8, a, b));

    // Same for the pair that a "strip the dots" rule would collapse.
    const c = try encodeGroup(alloc, "..");
    const d = try encodeGroup(alloc, ".");
    try testing.expect(!std.mem.eql(u8, c, d));
}

test "a group name that means somewhere else writes here anyway" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();

    const escape = "../../pwned";
    _ = l.append(escape, 1, "worker", 1000, false, "hello");

    // The whole path, and it starts inside the record and stays there.
    const path = try testDayPath(alloc, &l, escape, 1000);
    const inside = try std.fs.path.join(alloc, &.{ dir, "chat" });
    try testing.expect(std.mem.startsWith(u8, path, inside));

    // Not one *component* below the record is `.` or `..`. Asked
    // component by component rather than by searching the whole string
    // for `..`: `../../pwned` encodes to `%2E.%2F..%2Fpwned`, which holds
    // two dots in a row and is nonetheless one perfectly ordinary
    // directory name. What matters is where the path goes, not what it
    // spells.
    var parts = std.mem.splitScalar(u8, path[inside.len..], '/');
    while (parts.next()) |part| {
        try testing.expect(!std.mem.eql(u8, part, "."));
        try testing.expect(!std.mem.eql(u8, part, ".."));
    }

    // And the message really went there rather than somewhere quieter.
    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    try testing.expect(st.size > 0);

    // Reading it back finds it under the name it was said in, not under
    // the mangled one: the directory is a filing decision, the `group`
    // field is what the message says about itself.
    const page = try l.history(testing.allocator, escape, 0, 10);
    defer ChatLog.freePage(testing.allocator, page);
    try testing.expectEqual(@as(usize, 1), page.entries.len);
    try testing.expectEqualStrings("hello", page.entries[0].text);
}

test "a day of its own gets a file of its own, and paging crosses the two" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();

    // Two days apart, so the boundary falls between them whatever the
    // machine's timezone happens to be.
    const day_ms: i64 = 24 * 60 * 60 * 1000;
    const first: i64 = 1_787_900_000_000;
    const second: i64 = first + 2 * day_ms;
    try testing.expect(dayOf(first) != dayOf(second));

    _ = l.append("build", 1, "worker", first, false, "yesterday");
    _ = l.append("build", 1, "worker", second, false, "today one");
    _ = l.append("build", 1, "worker", second, false, "today two");

    // Two files, named for the two days.
    var days = try l.tree.days(alloc, "build");
    defer days.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), days.items.len);
    try testing.expectEqual(dayOf(second), days.items[0].day);
    try testing.expectEqual(dayOf(first), days.items[1].day);

    // And a page walks out of the newer file and into the older one
    // without a seam: oldest first, nothing missing, nothing twice.
    const page = try l.history(testing.allocator, "build", 0, 10);
    defer ChatLog.freePage(testing.allocator, page);
    try testing.expectEqual(@as(usize, 3), page.entries.len);
    try testing.expectEqualStrings("yesterday", page.entries[0].text);
    try testing.expectEqualStrings("today one", page.entries[1].text);
    try testing.expectEqualStrings("today two", page.entries[2].text);
    try testing.expect(page.exhausted);

    // Paging by the cursor lands on the same seam from the other side.
    const older = try l.history(testing.allocator, "build", 2, 10);
    defer ChatLog.freePage(testing.allocator, older);
    try testing.expectEqual(@as(usize, 1), older.entries.len);
    try testing.expectEqualStrings("yesterday", older.entries[0].text);
    try testing.expect(older.exhausted);
}

test "compacting a group leaves the messages the summary stands for" {
    // The point of the record: the working set in memory is trimmed and
    // compacted on purpose, and none of that is allowed to reach here.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();

    _ = l.append("build", 1, "worker", 1000, false, "one");
    _ = l.append("build", 1, "worker", 1001, false, "two");
    _ = l.append("build", 1, "worker", 1002, false, "three");

    // What `group_compact` writes: a summary standing in for the three
    // above, which memory now holds instead of them.
    _ = l.append("build", 1, "supervisor", 1003, true, "three things happened");

    const page = try l.history(testing.allocator, "build", 0, 10);
    defer ChatLog.freePage(testing.allocator, page);

    // All four, in the order they were said. The summary was written
    // after the messages, not over them.
    try testing.expectEqual(@as(usize, 4), page.entries.len);
    try testing.expectEqualStrings("one", page.entries[0].text);
    try testing.expectEqualStrings("two", page.entries[1].text);
    try testing.expectEqualStrings("three", page.entries[2].text);
    try testing.expectEqualStrings("three things happened", page.entries[3].text);
    try testing.expect(!page.entries[2].summary);
    try testing.expect(page.entries[3].summary);
}

test "a record that has fallen behind the stream is filled in on the next start" {
    // The upgrade case, and the recovery case, are the same case: a stream
    // holding messages the record does not.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    {
        var l = try ChatLog.open(testing.allocator, io, dir);
        defer l.deinit();
        testSeed(&l);
    }

    // Everything the previous Polter wrote is in the stream, and the
    // record is not there at all -- which is exactly what an install that
    // predates the record looks like.
    const build_dir = try std.fs.path.join(alloc, &.{ dir, "chat", "build" });
    const research_dir = try std.fs.path.join(alloc, &.{ dir, "chat", "research" });
    try std.Io.Dir.cwd().deleteTree(io, build_dir);
    try std.Io.Dir.cwd().deleteTree(io, research_dir);

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();

    const page = try l.history(testing.allocator, "build", 0, 10);
    defer ChatLog.freePage(testing.allocator, page);
    try testing.expectEqual(@as(usize, 3), page.entries.len);
    try testing.expectEqualStrings("one", page.entries[0].text);
    try testing.expectEqualStrings("three", page.entries[2].text);
    try testing.expect(page.exhausted);

    // The other group came across too, and into its own directory.
    const other = try l.history(testing.allocator, "research", 0, 10);
    defer ChatLog.freePage(testing.allocator, other);
    try testing.expectEqual(@as(usize, 2), other.entries.len);
    try testing.expectEqualStrings("x", other.entries[0].text);
}

test "filling in twice does not write anything twice" {
    // The reason `backfill` measures rather than remembers: it runs on
    // every start, so running it against a record that is already up to
    // date has to be free of consequence.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    {
        var l = try ChatLog.open(testing.allocator, io, dir);
        defer l.deinit();
        testSeed(&l);
    }

    // Three more opens, each of which runs the fill-in against a record
    // that has nothing missing.
    for (0..3) |_| {
        var l = try ChatLog.open(testing.allocator, io, dir);
        defer l.deinit();

        const page = try l.history(testing.allocator, "build", 0, 20);
        defer ChatLog.freePage(testing.allocator, page);
        try testing.expectEqual(@as(usize, 3), page.entries.len);
    }
}

test "a day past the cap carries on in a part beside it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();

    const big = try alloc.alloc(u8, 60 * 1024);
    @memset(big, 'x');

    _ = l.append("build", 1, "worker", 1000, false, "first");

    // Past the day's cap, all inside one day.
    var written: u64 = 0;
    while (written < day_bytes + 64 * 1024) : (written += big.len) {
        _ = l.append("build", 1, "worker", 1000, false, big);
    }

    _ = l.append("build", 1, "worker", 1000, false, "last");

    // The day did not end and nothing was moved aside: it carried on in
    // the part beside it.
    var days = try l.tree.days(alloc, "build");
    defer days.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), days.items.len);
    try testing.expectEqual(dayOf(1000), days.items[0].day);
    try testing.expectEqual(@as(u32, 2), days.items[0].part);
    try testing.expectEqual(@as(u32, 1), days.items[1].part);

    // The newest part is read first, so the last thing said comes back
    // even though it is not in the file the day is named for.
    const page = try l.history(testing.allocator, "build", 0, 1);
    defer ChatLog.freePage(testing.allocator, page);
    try testing.expectEqual(@as(usize, 1), page.entries.len);
    try testing.expectEqualStrings("last", page.entries[0].text);

    // Paging back past the part boundary comes back empty and says there
    // is more, which is the honest answer rather than a loss: the first
    // part is four times one page's scanning budget, so reaching its
    // front takes several calls.
    const oldest = try l.history(testing.allocator, "build", 2, 1);
    defer ChatLog.freePage(testing.allocator, oldest);
    try testing.expectEqual(@as(usize, 0), oldest.entries.len);
    try testing.expect(!oldest.exhausted);

    // And the first thing said is still at the front of the first part.
    // Read off the file rather than through `history` for the reason
    // above -- what is being asserted here is that nothing was dropped to
    // make room, and the file is where that is visible.
    const first_path = try l.tree.partPath(alloc, "build", dayOf(1000), 1);
    const f = try std.Io.Dir.openFileAbsolute(io, first_path, .{});
    defer f.close(io);

    var head_buf: [512]u8 = undefined;
    const n = try f.readPositionalAll(io, &head_buf, 0);
    try testing.expect(std.mem.indexOf(u8, head_buf[0..n], "\"first\"") != null);
}

test "the record is not disturbed by the stream rotating" {
    // The two shapes are bounded differently on purpose: the stream keeps
    // two generations, the record keeps everything. A rotation must not
    // take anything out of the record's reach.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try testDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const path = try std.fs.path.join(alloc, &.{ dir, "chat", "chat.jsonl" });
    const rotated = try std.fmt.allocPrint(alloc, "{s}.1", .{path});

    {
        var l = try ChatLog.open(testing.allocator, io, dir);
        defer l.deinit();
        testSeed(&l);
    }
    try std.Io.Dir.renameAbsolute(path, rotated, io);

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();

    // The stream's current generation is empty, and the record does not
    // care: it was never reading the stream.
    try testing.expectEqual(@as(u64, 0), l.written);

    const page = try l.history(testing.allocator, "build", 0, 10);
    defer ChatLog.freePage(testing.allocator, page);
    try testing.expectEqual(@as(usize, 3), page.entries.len);
    try testing.expectEqualStrings("one", page.entries[0].text);
    try testing.expectEqualStrings("three", page.entries[2].text);
    try testing.expect(page.exhausted);
}
