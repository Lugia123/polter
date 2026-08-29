//! One plugin's log: everything it printed, and everything the host saw
//! happen to it, in one file in the order it happened.
//!
//! **The host captures the plugin's stderr; the plugin does not write a
//! file.** This is the whole design and it is easy to build backwards, so
//! the reason is here rather than in a commit message.
//!
//! The plugin contract says, in as many words, that any language will do
//! and that a twenty-line `curl` script is a complete plugin. If logging
//! lived in the shipped SDK, then a log would exist for the plugins that
//! happened to use the SDK and for no others -- which is not a log, it is
//! luck. The same argument is already written down in this repository as
//! red line 3 of `docs/poltergeist/gaps.md`, about the terminal transcript:
//!
//! > Recording is the terminal's job, not the hosted program's. Leave it to
//! > the agent and the record exists only for the programs that happen to
//! > keep one, in whatever format each of them picked -- that is not a
//! > record, it is luck.
//!
//! A plugin is a hosted program by the same definition, and Polter is
//! likewise the only place that can produce one record for all of them. So
//! stderr comes back through a socket the host reads, and every plugin has
//! a log whether or not its author ever thought about one.
//!
//! **The host's own events go in the same file.** Started, greeted,
//! refused, killed for misconduct, backing off, dormant, what it said out
//! loud -- all of it, interleaved with the plugin's own output under the
//! same clock. The question a person actually has is "what happened to this
//! plugin", and an answer split between the plugin's noise in one place and
//! the host's verdict in another is an answer they have to assemble
//! themselves, in the right order, from two files with different clocks.
//!
//! **It is bounded.** A plugin that has gone mad writes a hundred thousand
//! lines a second, and the size of this file is therefore decided by
//! somebody who is not us -- which is red line 4 of the same document, "do
//! not write a source whose volume is somebody else's decision". So: two
//! generations of `max_bytes`, which is the shape `ChatLog`'s stream
//! already uses for the same reason and gives a hard ceiling per plugin.
//! The machine this was written on has been bitten once by a cache that
//! only ever grew.

const PluginLog = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const daylog = @import("daylog.zig");
const scrub = @import("scrub.zig");

const log = std.log.scoped(.poltergeist);

/// Rotate once the file passes this; one older generation is kept beside
/// it, so a plugin costs at most twice this on disk.
///
/// Smaller than the chat stream's 8MB, and the reason is what is in it:
/// chat is the thing somebody pages back through for a fortnight, while
/// this is a diagnostic read when something is wrong, which means it is
/// read from the end. Two megabytes is tens of thousands of lines, which is
/// far past what anybody scrolls through and far short of what anybody
/// notices on a disk.
pub const max_bytes: u64 = 2 * 1024 * 1024;

/// The longest single line kept whole.
///
/// A line is what a plugin decides it is: nothing stops one writing a
/// megabyte with no newline in it, and a rotation ceiling does not help
/// with the buffer that has to hold it first. Past this the line is written
/// out in pieces, which keeps the file readable and costs nothing but a
/// wrapped stack trace.
pub const max_line: usize = 4096;

/// Who wrote a line.
///
/// A column and not a prefix inside the text: the whole point of one file
/// is being able to see, at a glance down the left, which of these lines
/// are the plugin talking and which are Polter's verdict on it.
pub const Source = enum {
    /// Polter's own account of what it did to this plugin.
    host,

    /// A line the plugin wrote to its standard error.
    plugin,

    /// A line the plugin asked to have told to the user, whether or not it
    /// was shown. Kept apart from `plugin` because it is the plugin
    /// speaking *to somebody*, and because a line that was throttled off
    /// the screen has to still be somewhere.
    said,

    /// Padded to one width here rather than by a format specifier, so that
    /// the column is a property of the list and a fourth source cannot be
    /// added without lining it up.
    fn tag(self: Source) []const u8 {
        return switch (self) {
            .host => "polter",
            .plugin => "stderr",
            .said => "said  ",
        };
    }
};

alloc: Allocator,
io: std.Io,

/// `<state>/polter/plugins/<key>.log`. Owned.
path: []const u8,

file: std.Io.File,
written: u64,

/// Two threads write here: the resident's own, for the host's events, and
/// the one draining the child's standard error. Without this a stack trace
/// and a verdict interleave inside a line rather than between two.
mutex: std.Io.Mutex = .init,

/// Failures are said once and then swallowed, the same rule the chat log
/// keeps: a full disk must not turn "the log is worse off" into "the
/// plugin stopped running".
warned: bool = false,

pub const Error = error{OpenFailed} || Allocator.Error;

/// What the directory holding these is called, under the state root.
///
/// The same last component as the *config* directory a plugin's settings
/// live in (`<config>/polter/plugins/<key>.json`), and deliberately so:
/// that is the XDG split said out loud rather than worked around. What the
/// user wrote is configuration, what Polter observed is state, and the one
/// name under two roots makes the pair obvious in a way that inventing a
/// third word for one of them would not.
pub const dir_name = "plugins";

pub fn dirIn(alloc: Allocator, state_dir: []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(alloc, &.{ state_dir, dir_name });
}

/// Open (or make) one plugin's log.
///
/// `dir` is the directory the logs live in, not the state root: the caller
/// makes it once for every plugin rather than each plugin racing to make
/// the same directory.
pub fn open(alloc: Allocator, io: std.Io, dir: []const u8, key: []const u8) Error!PluginLog {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}.log", .{ dir, key });
    errdefer alloc.free(path);

    // 0600 through `daylog.openAppend`, and for its reason: what ends up in
    // here is a plugin's own output, which means file paths, tracebacks and
    // occasionally whatever it printed while holding a credential.
    const file = daylog.openAppend(io, path) catch |err| {
        log.warn("plugin {s}: no log at {s} err={}", .{ key, path, err });
        return error.OpenFailed;
    };

    return .{
        .alloc = alloc,
        .io = io,
        .path = path,
        .file = file,
        .written = if (file.stat(io)) |st| st.size else |_| 0,
    };
}

pub fn deinit(self: *PluginLog) void {
    self.file.close(self.io);
    self.alloc.free(self.path);
    self.* = undefined;
}

/// Write one line, from either side.
///
/// `text` is scrubbed rather than trusted, which is the same call
/// `report.told` makes before putting a plugin's words on a screen, and it
/// is one table in `scrub.zig` rather than two. It applies to the host's
/// own lines too: they are formatted from a plugin's key and a plugin's
/// error, so "this side is ours" is not true of the bytes.
pub fn say(self: *PluginLog, from: Source, text: []const u8) void {
    const at_ms: i64 = @intCast(@divTrunc(
        std.Io.Timestamp.now(self.io, .real).nanoseconds,
        std.time.ns_per_ms,
    ));

    const clean = scrub.clean(self.alloc, text) catch return;
    defer self.alloc.free(clean);

    var stamp_buf: [19]u8 = undefined;
    const stamp = daylog.stamp(&stamp_buf, at_ms);

    const line = std.fmt.allocPrint(
        self.alloc,
        "{s}  {s}  {s}\n",
        .{ stamp, from.tag(), clean[0..scrub.cut(clean, max_line)] },
    ) catch return;
    defer self.alloc.free(line);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    self.file.writePositionalAll(self.io, line, self.written) catch |err| {
        // Nothing is propagated. A full disk means this file is worse off;
        // it must not mean the plugin stops running, which is the same rule
        // the chat record keeps for the same reason.
        self.warnOnce(err);
        return;
    };
    self.written += line.len;

    self.rotateIfFull();
}

/// The host's own account of something, formatted.
pub fn note(self: *PluginLog, comptime fmt: []const u8, args: anytype) void {
    var buf: [max_line]u8 = undefined;
    const text: []const u8 = std.fmt.bufPrint(&buf, fmt, args) catch
        "(a line of Polter's own was too long to write down)";
    self.say(.host, text);
}

/// Move the log aside once it gets large, keeping one generation.
///
/// Called with the mutex held. Nothing here can fail in a way worth
/// propagating: a rotation that does not happen costs disk, and a rotation
/// that half happens is recovered by the next one.
fn rotateIfFull(self: *PluginLog) void {
    if (self.written < max_bytes) return;

    const old = std.fmt.allocPrint(self.alloc, "{s}.1", .{self.path}) catch return;
    defer self.alloc.free(old);

    self.file.close(self.io);

    std.Io.Dir.renameAbsolute(self.path, old, self.io) catch |err| {
        self.warnOnce(err);
    };

    self.file = daylog.openAppend(self.io, self.path) catch |err| {
        // Nothing left to write into. The counter is reset all the same, so
        // that a log which comes back later is not rotated on its first
        // line for a length it no longer has.
        self.warnOnce(err);
        self.written = 0;
        return;
    };
    self.written = 0;
}

fn warnOnce(self: *PluginLog, err: anyerror) void {
    if (self.warned) return;
    self.warned = true;
    log.warn("plugin log {s}: err={}", .{ self.path, err });
}

// -- the drain --------------------------------------------------------------

/// Everything one child's standard error needs to end up in the log.
///
/// A thread of its own, and it has to be: the resident's thread spends most
/// of its life blocked on a write into the child or a read back out of it,
/// and a child that filled a 64KB pipe with stderr while nobody was
/// draining it would block *inside* its own write and then be killed for
/// missing its deadline -- that is, a plugin killed for being noisy, which
/// is exactly the plugin whose noise somebody wants to read.
pub const Drain = struct {
    plog: *PluginLog,
    file: std.Io.File,
    io: std.Io,

    pub fn run(self: *Drain) void {
        var buf: [16 * 1024]u8 = undefined;
        var line: [max_line]u8 = undefined;
        var n: usize = 0;

        while (true) {
            const got = self.file.readStreaming(self.io, &.{&buf}) catch break;
            if (got == 0) break;

            for (buf[0..got]) |b| {
                if (b == '\n') {
                    self.plog.say(.plugin, line[0..n]);
                    n = 0;
                    continue;
                }

                // A line longer than the buffer is written out in pieces
                // rather than dropped or truncated: the interesting part of
                // a runaway line is as likely to be at the end as at the
                // start, and nothing here can tell which.
                if (n == line.len) {
                    self.plog.say(.plugin, line[0..n]);
                    n = 0;
                }

                line[n] = b;
                n += 1;
            }
        }

        // What the child wrote without a newline after it. It said it, so
        // it is written down.
        if (n > 0) self.plog.say(.plugin, line[0..n]);
    }
};

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn scratch(arena: Allocator, io: std.Io) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(arena, "/tmp/polter-plog-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn read(alloc: Allocator, io: std.Io, path: []const u8) []const u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        alloc,
        .limited(64 * 1024 * 1024),
    ) catch "";
}

test "both sides land in one file, in the order they happened" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratch(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var plog = try open(testing.allocator, io, dir, "say");
    defer plog.deinit();

    plog.note("started {s}", .{"/opt/say/say.py"});
    plog.say(.plugin, "Traceback (most recent call last):");
    plog.note("it would not answer, so it is being stopped", .{});

    const body = read(alloc, io, plog.path);
    try testing.expect(body.len > 0);

    // The point of one file: the plugin's own noise and the host's verdict
    // on it, in one place, in one order. Read separately they are two
    // stories somebody has to interleave by hand off two clocks.
    const started = std.mem.indexOf(u8, body, "started /opt/say/say.py").?;
    const traceback = std.mem.indexOf(u8, body, "Traceback").?;
    const stopped = std.mem.indexOf(u8, body, "would not answer").?;
    try testing.expect(started < traceback);
    try testing.expect(traceback < stopped);

    // And which side said which.
    try testing.expect(std.mem.indexOf(u8, body, "polter") != null);
    try testing.expect(std.mem.indexOf(u8, body, "stderr") != null);
}

test "a plugin flooding stderr cannot fill the disk" {
    // The requirement, in the words it was given in: a plugin that has gone
    // mad writes a hundred thousand lines a second, and this file may not
    // grow without an end. Two generations of `max_bytes` is the ceiling,
    // and this is the test that would notice it being removed.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratch(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var plog = try open(testing.allocator, io, dir, "mad");
    defer plog.deinit();

    // Comfortably past two full generations, so this is measuring a
    // ceiling rather than a file that simply has not filled yet.
    const noise = "x" ** 1024;
    var wrote: u64 = 0;
    while (wrote < 5 * max_bytes) : (wrote += noise.len) plog.say(.plugin, noise);

    const live = read(alloc, io, plog.path);
    const old_path = try std.fmt.allocPrint(alloc, "{s}.1", .{plog.path});
    const old = read(alloc, io, old_path);

    try testing.expect(live.len + old.len <= 2 * max_bytes + max_line);
    try testing.expect(wrote > live.len + old.len);

    // And nothing else was left lying about: exactly two files, not one per
    // rotation.
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var count: usize = 0;
    var it = d.iterate();
    while (try it.next(io)) |_| count += 1;
    try testing.expectEqual(@as(usize, 2), count);
}

test "what a plugin printed cannot repaint the screen of whoever cats the log" {
    // The file is read by a person, and `cat` is an interpreter. The bytes
    // came from a script somebody copied off the internet, so they get the
    // same table the screen path gets -- one table, applied on both sides,
    // because a rule kept in two places is a rule one of them stops
    // keeping.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratch(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var plog = try open(testing.allocator, io, dir, "rude");
    defer plog.deinit();

    plog.say(.plugin, "before\x1b[2Jafter\u{9b}31m");

    const body = read(alloc, io, plog.path);
    try testing.expect(std.mem.indexOfScalar(u8, body, 0x1b) == null);
    try testing.expect(std.mem.indexOf(u8, body, "\u{9b}") == null);
    try testing.expect(std.mem.indexOf(u8, body, "before") != null);
    try testing.expect(std.mem.indexOf(u8, body, "after") != null);

    // One line in, one line out: a newline the plugin never wrote must not
    // appear, or a plugin could forge a line that looks like Polter's.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "\n"));
}

test "a line with no end to it is written down in pieces rather than held for ever" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratch(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var plog = try open(testing.allocator, io, dir, "endless");
    defer plog.deinit();

    // The drain reads from a file rather than from a pipe here, which is
    // the same shape as far as it is concerned: bytes with no newline in
    // them until there are no more bytes.
    const raw = try std.fmt.allocPrint(alloc, "{s}", .{"y" ** (3 * max_line + 7)});
    const path = try std.fmt.allocPrint(alloc, "{s}/raw", .{dir});
    {
        var f = try daylog.openAppend(io, path);
        defer f.close(io);
        try f.writeStreamingAll(io, raw);
    }

    var f = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer f.close(io);

    var drain: Drain = .{ .plog = &plog, .file = f, .io = io };
    drain.run();

    const body = read(alloc, io, plog.path);

    // Four pieces: three full ones and the remainder. Nothing waiting in a
    // buffer for a newline that is never coming.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, body, "\n"));
    try testing.expectEqual(
        @as(usize, raw.len),
        std.mem.count(u8, body, "y"),
    );
}
