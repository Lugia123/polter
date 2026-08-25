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

alloc: Allocator,
io: std.Io,

/// Where the current log lives. Owned.
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
    defer alloc.free(dir);

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
        .path = path,
        .file = file,
        .written = written,
        .next_seq = 1,
    };

    // In that order: the tail has to be whole before anything tries to
    // read a line out of it.
    self.patchTornTail();
    self.next_seq = self.recoverSeq() + 1;
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
    self.file.close(self.io);
    self.alloc.free(self.path);
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
/// Reading fails the way writing does -- quietly. A page that stops
/// short says `exhausted = false`, and the caller asks again later.
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

    // This generation first, then the one rotation moved aside. `written`
    // rather than a fresh stat: it is where this process's last line ended,
    // and it is the offset the next append will use.
    var exhausted = true;
    var stop = try w.generation(self.file, self.written);
    if (stop != .enough) {
        if (stop == .gave_up) exhausted = false;
        stop = try self.walkRotated(&w);
    }
    if (stop != .start_of_file) exhausted = false;

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

/// The generation rotation moved aside, if it is still there.
///
/// Not being there is the ordinary case rather than a failure -- most
/// logs never grow enough to rotate at all -- so it counts as having
/// walked off the front, not as having given up.
fn walkRotated(self: *ChatLog, w: *Walk) Allocator.Error!Stop {
    const old = try std.fmt.allocPrint(w.alloc, "{s}.1", .{self.path});
    defer w.alloc.free(old);

    const file = std.Io.Dir.openFileAbsolute(self.io, old, .{}) catch |err| switch (err) {
        error.FileNotFound => return .start_of_file,
        else => return .gave_up,
    };
    defer file.close(self.io);

    const end = if (file.stat(self.io)) |st| st.size else |_| return .gave_up;
    return w.generation(file, end);
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

test "history walks out of the current file and into the rotated one" {
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
        _ = l.append("build", 1, "worker", 1000, false, "one");
        _ = l.append("build", 1, "worker", 1001, false, "two");
    }

    try std.Io.Dir.renameAbsolute(path, rotated, io);

    var l = try ChatLog.open(testing.allocator, io, dir);
    defer l.deinit();
    try testing.expectEqual(@as(u64, 3), l.append("build", 1, "worker", 1002, false, "three"));

    const page = try l.history(testing.allocator, "build", 0, 10);
    defer ChatLog.freePage(testing.allocator, page);

    try testing.expectEqual(@as(usize, 3), page.entries.len);
    try testing.expectEqual(@as(u64, 1), page.entries[0].seq);
    try testing.expectEqual(@as(u64, 2), page.entries[1].seq);
    try testing.expectEqual(@as(u64, 3), page.entries[2].seq);
    try testing.expectEqualStrings("one", page.entries[0].text);

    // Both generations were walked all the way to their front.
    try testing.expect(page.exhausted);
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
    try l.file.writePositionalAll(io, legacy, l.written);
    l.written += legacy.len;

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

test "an empty current file is walked through rather than stopped at" {
    // Restarting in the moment after a rotation: everything that was said
    // is in the generation moved aside and the file being appended to is
    // still zero bytes long. A walk that took that for the beginning would
    // report the whole night as gone.
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
    try testing.expectEqual(@as(u64, 0), l.written);

    const page = try l.history(testing.allocator, "build", 0, 10);
    defer ChatLog.freePage(testing.allocator, page);

    try testing.expectEqual(@as(usize, 3), page.entries.len);
    try testing.expectEqualStrings("one", page.entries[0].text);
    try testing.expectEqualStrings("three", page.entries[2].text);
    try testing.expect(page.exhausted);
}

test "a line longer than the window stops the walk instead of spinning on it" {
    // The seam is where a backwards walk can fail to move, and a walk that
    // does not move never returns. A line the window cannot see both ends
    // of is the one way that happens -- `append` cannot write one, but a
    // foreign hand editing the file can. It has to end the generation, and
    // it has to leave the caller told there is more rather than told it has
    // reached the beginning.
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
    try l.file.writePositionalAll(io, giant, l.written);
    l.written += giant.len;

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
