const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const internal_os = @import("../os/main.zig");
const quota = @import("../poltergeist/quota.zig");
const QuotaWatch = @import("../poltergeist/QuotaWatch.zig");
const daylog = @import("../poltergeist/daylog.zig");

const log = std.log.scoped(.statusline);

/// The most of the status line's input that is read. What Claude Code
/// sends is a kilobyte or two.
const max_stdin_bytes = 1024 * 1024;

/// The person's own status line command, when they had one: put in the
/// CLI's environment by the adapter that configured this one in its place.
pub const chain_env = "POLTER_STATUSLINE_CHAIN";

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `statusline` command is what an agent CLI started with a role runs
/// as its status line. It is configured by the role's adapter and is not
/// run by hand.
///
///   polter +statusline --cli <cli>
///
/// The CLI hands a status line command a description of the session on
/// stdin, and in it how much of the account's allowance is used. This
/// keeps that for the control room and does nothing else of its own.
///
/// **The person's own status line is exactly what it was.** When they had
/// one, it is run with the same bytes on its stdin and its stdout and
/// stderr go straight to the CLI -- they are never read here, so they
/// cannot be changed here -- and its exit code is this command's. When
/// they had none, this writes nothing.
pub fn run(alloc: Allocator) !u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var env = global.environMap() catch |err| {
        log.warn("+statusline: could not read the environment err={t}", .{err});
        return 0;
    };
    defer env.deinit();
    const io = global.io();

    const dir = QuotaWatch.dropDir(aa, io, &env) catch null;
    return runWith(aa, io, env.get(chain_env), dir, @intCast(@max(0, daylog.nowMs(io))));
}

/// Everything `run` does once it has its environment, so a test can drive
/// the real path. Reads stdin; writes nothing to stdout itself.
pub fn runWith(
    aa: Allocator,
    io: std.Io,
    chain: ?[]const u8,
    drop_dir: ?[]const u8,
    now_ms: u64,
) u8 {
    // Read before anything else can fail, so the CLI's pipe is always
    // drained.
    var stdin: std.Io.File = .stdin();
    var in_buf: [16 * 1024]u8 = undefined;
    var reader = stdin.reader(io, &in_buf);
    const payload = reader.interface.allocRemaining(aa, .limited(max_stdin_bytes)) catch |err| {
        log.warn("+statusline: could not read stdin err={t}", .{err});
        return 0;
    };

    // Theirs first, so that it is not kept waiting on ours.
    var child: ?std.process.Child = if (chain) |command| start(io, command, payload) else null;

    if (drop_dir) |dir| keep(aa, io, dir, payload, now_ms) catch |err| {
        log.warn("+statusline: the allowance was not kept err={t}", .{err});
    };

    if (child) |*c| {
        const term = c.wait(io) catch return 1;
        return switch (term) {
            .exited => |code| code,
            else => 1,
        };
    }
    return 0;
}

/// Run the person's own status line with the bytes this one was given.
/// Its stdout and stderr are the CLI's, untouched.
fn start(io: std.Io, command: []const u8, payload: []const u8) ?std.process.Child {
    if (command.len == 0) return null;
    // Only configured where a status line is a line of `sh`; see the
    // adapter.
    if (builtin.os.tag == .windows) return null;

    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdin = .pipe,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        log.warn("+statusline: could not run the status line it stands in for err={t}", .{err});
        return null;
    };
    if (child.stdin) |in| {
        // A command that does not read its input closes the pipe early;
        // that is its business and not a failure.
        in.writeStreamingAll(io, payload) catch {};
        in.close(io);
        child.stdin = null;
    }
    return child;
}

/// Leave what the input says of the allowance where the app reads it.
/// Nothing is written when it says nothing -- before a session's first
/// answer, and always for an account that pays by the token -- so the last
/// number stays and grows old, which is what it is.
fn keep(aa: Allocator, io: std.Io, dir: []const u8, payload: []const u8, now_ms: u64) !void {
    const windows = quota.fromClaudeStatus(aa, payload) orelse return;
    try QuotaWatch.writeDrop(aa, io, dir, .claude, windows, now_ms);
}

// -- tests ------------------------------------------------------------------
//
// What matters here is a property of a process: what reaches the CLI on
// fd 1 is what the person's own command wrote, byte for byte, and what that
// command read on fd 0 is what the CLI sent. So it is measured on one, the
// way `+hook`'s is: the real `runWith` in a forked child whose fd 0 and fd 1
// are pipes.

const testing = std.testing;

const Ran = struct { code: u8, stdout: []u8 };

fn runChild(alloc: Allocator, chain: ?[]const u8, drop_dir: ?[]const u8, payload: []const u8) !Ran {
    const sys = std.posix.system;
    var in_pipe: [2]std.posix.fd_t = undefined;
    var out_pipe: [2]std.posix.fd_t = undefined;
    if (sys.pipe(&in_pipe) != 0) return error.Pipe;
    if (sys.pipe(&out_pipe) != 0) return error.Pipe;

    const pid = sys.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        _ = sys.dup2(in_pipe[0], 0);
        _ = sys.dup2(out_pipe[1], 1);
        _ = sys.close(in_pipe[0]);
        _ = sys.close(in_pipe[1]);
        _ = sys.close(out_pipe[0]);
        _ = sys.close(out_pipe[1]);
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        const code = runWith(arena.allocator(), threaded.io(), chain, drop_dir, 1_700_000_000_000);
        std.c._exit(code);
    }

    _ = sys.close(in_pipe[0]);
    _ = sys.close(out_pipe[1]);

    var off: usize = 0;
    while (off < payload.len) {
        const n = std.c.write(in_pipe[1], payload[off..].ptr, payload.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    _ = sys.close(in_pipe[1]);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(out_pipe[0], &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(alloc, buf[0..@intCast(n)]);
    }
    _ = sys.close(out_pipe[0]);

    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) != pid) return error.Wait;
    const s: u32 = @bitCast(status);
    if (!std.posix.W.IFEXITED(s)) return error.ChildDidNotExit;
    return .{ .code = std.posix.W.EXITSTATUS(s), .stdout = try out.toOwnedSlice(alloc) };
}

/// What Claude Code 2.1.296 sends, cut down, with the allowance in it.
const status_input =
    \\{"session_id":"s1","cwd":"/tmp/x","model":{"id":"m","display_name":"M"},"version":"2.1.296",
    \\ "rate_limits":{"five_hour":{"used_percentage":61,"resets_at":1700003600},
    \\                "seven_day":{"used_percentage":12,"resets_at":1700400000}}}
;

/// A status line that is hard to pass through by accident: colour, a byte
/// that is not UTF-8, a NUL, two lines, no newline at the end -- and then
/// every byte it was given on its stdin.
const awkward = "printf '\\033[31mred\\033[0m \\377\\000|\\n\\nlast'; cat";
const awkward_said = "\x1b[31mred\x1b[0m \xff\x00|\n\nlast";

fn tmpDir(alloc: Allocator, io: std.Io) ![]u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const path = try std.fmt.allocPrint(alloc, "/tmp/polter-statusline-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}

test "+statusline: the person's own status line comes out byte for byte, having read byte for byte what was sent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = try tmpDir(alloc, io);
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const ran = try runChild(alloc, awkward, dir, status_input);
    defer alloc.free(ran.stdout);
    try testing.expectEqual(@as(u8, 0), ran.code);

    const want = awkward_said ++ status_input;
    const same = std.mem.eql(u8, want, ran.stdout);
    try testing.expect(same);
    try testing.expectEqual(want.len, ran.stdout.len);

    // And the allowance was kept on the way past.
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const got = QuotaWatch.readClaude(arena.allocator(), io, dir).?;
    const used = got.windows[0].?.used;
    try testing.expectEqual(@as(u8, 61), used);
    try testing.expectEqual(@as(u64, 1_700_000_000_000), got.at_ms);
}

test "+statusline: its exit code is the person's command's" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    const ran = try runChild(alloc, "printf out; exit 7", null, status_input);
    defer alloc.free(ran.stdout);
    const code = ran.code;
    try testing.expectEqual(@as(u8, 7), code);
    try testing.expectEqualStrings("out", ran.stdout);
}

test "+statusline: with no status line to stand in for it writes nothing, and still keeps the allowance" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = try tmpDir(alloc, io);
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const ran = try runChild(alloc, null, dir, status_input);
    defer alloc.free(ran.stdout);
    try testing.expectEqual(@as(u8, 0), ran.code);
    const said = ran.stdout.len;
    try testing.expectEqual(@as(usize, 0), said);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const kept = QuotaWatch.readClaude(arena.allocator(), io, dir) != null;
    try testing.expect(kept);
}

test "+statusline: input that says nothing of the allowance leaves the last number alone" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = try tmpDir(alloc, io);
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const first = try runChild(alloc, null, dir, status_input);
    alloc.free(first.stdout);
    // A session before its first answer, and input that is not JSON.
    const second = try runChild(alloc, "cat", dir, "{\"session_id\":\"s2\"}");
    defer alloc.free(second.stdout);
    try testing.expectEqualStrings("{\"session_id\":\"s2\"}", second.stdout);
    const third = try runChild(alloc, null, dir, "not { json");
    alloc.free(third.stdout);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const got = QuotaWatch.readClaude(arena.allocator(), io, dir).?;
    const state = got.state;
    try testing.expectEqual(quota.Reading.State.have, state);
    const used = got.windows[0].?.used;
    try testing.expectEqual(@as(u8, 61), used);
}
