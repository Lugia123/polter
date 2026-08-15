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
const max_bytes: u64 = 8 * 1024 * 1024;

alloc: Allocator,
io: std.Io,

/// Where the current log lives. Owned.
path: []const u8,

file: std.Io.File,
written: u64,

pub const Error = Allocator.Error || error{
    XdgLookupFailed,
    OpenFailed,
};

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

    const path = std.fs.path.join(alloc, &.{ dir, "chat.jsonl" }) catch
        return error.OutOfMemory;
    errdefer alloc.free(path);

    const file = openAppend(io, path) catch return error.OpenFailed;

    // Where the end is. Tracked from here on rather than asked for again:
    // every write goes at this offset and advances it, so appending costs
    // no extra syscall and two Polters cannot interleave into one line.
    const written = if (file.stat(io)) |st| st.size else |_| 0;

    return .{
        .alloc = alloc,
        .io = io,
        .path = path,
        .file = file,
        .written = written,
    };
}

pub fn deinit(self: *ChatLog) void {
    self.file.close(self.io);
    self.alloc.free(self.path);
    self.* = undefined;
}

/// Open for writing, creating with 0600 if it is not there.
///
/// Owner-only because the contents are code, file paths and stack traces
/// out of the user's own work -- a real privacy surface rather than a
/// formality. Same reasoning, and the same mode, as the ssh cache.
fn openAppend(io: std.Io, path: []const u8) !std.Io.File {
    const file = std.Io.Dir.createFileAbsolute(io, path, .{
        .read = false,
        .truncate = false,
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => try std.Io.Dir.openFileAbsolute(
            io,
            path,
            .{ .mode = .write_only },
        ),
        else => return err,
    };
    return file;
}

/// Write one message down.
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
) void {
    self.rotateIfFull();

    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    var s: std.json.Stringify = .{ .writer = &w, .options = .{} };
    s.beginObject() catch return;
    s.objectField("at_ms") catch return;
    s.write(at_ms) catch return;
    s.objectField("group") catch return;
    s.write(group) catch return;
    s.objectField("from") catch return;
    s.print("\"0x{x:0>16}\"", .{from}) catch return;
    s.objectField("author") catch return;
    s.write(author) catch return;
    if (summary) {
        s.objectField("summary") catch return;
        s.write(true) catch return;
    }
    s.objectField("text") catch return;

    // Truncated rather than dropped: a very long paste should leave a
    // record that it happened, even a partial one.
    const room = buf.len -| w.buffered().len -| 64;
    s.write(text[0..@min(text.len, room)]) catch return;
    s.endObject() catch return;
    w.writeByte('\n') catch return;

    const line = w.buffered();
    self.file.writePositionalAll(self.io, line, self.written) catch |err| {
        log.warn("chat log: could not write err={}", .{err});
        return;
    };
    self.written += line.len;
}

/// Move the current log aside once it gets large, keeping one generation.
fn rotateIfFull(self: *ChatLog) void {
    if (self.written < max_bytes) return;

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
