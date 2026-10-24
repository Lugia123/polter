//! A process's arguments, for telling Polter's own processes apart (task
//! 2149): an embedded group chat (`polter +chat --group=<g> --embedded`) and
//! an MCP sidecar (`polter +mcp`, `+mcp-slot`) both show up as `polter` in
//! the process table, and only their arguments say which is which.
//!
//! macOS: `sysctl({CTL_KERN, KERN_PROCARGS2, pid})`, whose buffer is
//! `argc` (an `int`), the executable's path, NULs up to the first argument,
//! then `argc` NUL-terminated arguments, then the environment. Only a
//! process of this user can be read; another's answers `EPERM`, which is
//! nothing here. Elsewhere nothing is read (Windows reads a job member's
//! command line on its own side).
//!
//! What is wanted of the arguments is small, so nothing is kept: `classify`
//! reads them into a buffer on the stack and answers with a kind and, for a
//! chat, the group's name.

const std = @import("std");
const builtin = @import("builtin");

/// What one of Polter's processes is, by its arguments.
pub const Kind = enum { chat, sidecar, other };

pub const Seen = struct {
    kind: Kind,
    /// The chat's `--group=`, cut to `group_buf`'s size; empty otherwise.
    group: [64]u8 = @splat(0),
    group_len: u8 = 0,

    pub fn groupName(self: *const Seen) []const u8 {
        return self.group[0..self.group_len];
    }
};

/// The most of a process's argument area read. A chat's or a sidecar's
/// arguments are well under this; the environment after them is not read
/// past it, and is not needed.
pub const max_bytes: usize = 16 * 1024;

const CTL_KERN = 1;
const KERN_PROCARGS2 = 49;

/// What `KERN_PROCARGS2` gave back: the count, and the arguments as one
/// NUL-separated run. A named type rather than an anonymous one written
/// twice, which Zig reads as two different types -- the file did not
/// compile until this was here.
pub const Args = struct { argc: usize, args: []const u8 };

/// The arguments of `pid` into `buf`, as one NUL-separated run with `argc`,
/// or null when they cannot be read.
pub fn read(pid: u32, buf: []u8) ?Args {
    if (builtin.os.tag != .macos) return null;
    var mib = [_]c_int{ CTL_KERN, KERN_PROCARGS2, @intCast(pid) };
    var len: usize = buf.len;
    if (std.c.sysctl(&mib, mib.len, buf.ptr, &len, null, 0) != 0) return null;
    return parse(buf[0..len]);
}

/// `KERN_PROCARGS2`'s buffer, read: `argc`, then past the executable's path
/// and its padding, the arguments. Pure, for the test.
pub fn parse(raw: []const u8) ?Args {
    if (raw.len < @sizeOf(c_int)) return null;
    const argc: usize = @intCast(@max(std.mem.readInt(i32, raw[0..4], builtin.cpu.arch.endian()), 0));
    var i: usize = @sizeOf(c_int);
    // The executable's path, then NULs up to the first argument.
    while (i < raw.len and raw[i] != 0) i += 1;
    while (i < raw.len and raw[i] == 0) i += 1;
    const start = i;
    var n: usize = 0;
    while (i < raw.len and n < argc) : (i += 1) {
        if (raw[i] == 0) n += 1;
    }
    return .{ .argc = n, .args = raw[start..i] };
}

/// What the arguments `args` (NUL-separated, as `parse` gives them) say a
/// `polter` process is.
pub fn classifyArgs(args: []const u8) Seen {
    var out: Seen = .{ .kind = .other };
    var chat = false;
    var embedded = false;
    var it = std.mem.splitScalar(u8, args, 0);
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "+mcp") or std.mem.eql(u8, a, "+mcp-slot")) return .{ .kind = .sidecar };
        if (std.mem.eql(u8, a, "+chat")) chat = true;
        if (std.mem.eql(u8, a, "--embedded")) embedded = true;
        if (std.mem.startsWith(u8, a, "--group=")) {
            const g = a["--group=".len..];
            const n = @min(g.len, out.group.len);
            @memcpy(out.group[0..n], g[0..n]);
            out.group_len = @intCast(n);
        }
    }
    if (chat and embedded) out.kind = .chat;
    if (out.kind != .chat) out.group_len = 0;
    return out;
}

/// Read and classify `pid`; `other` when it cannot be read.
pub fn classify(pid: u32) Seen {
    var buf: [max_bytes]u8 = undefined;
    const got = read(pid, &buf) orelse return .{ .kind = .other };
    return classifyArgs(got.args);
}

const testing = std.testing;

test "2149: the arguments say a chat from a sidecar from anything else" {
    const chat = classifyArgs("/Applications/Polter.app/Contents/MacOS/polter\x00+chat\x00--group=web-app\x00--embedded");
    try testing.expectEqual(Kind.chat, chat.kind);
    try testing.expectEqualStrings("web-app", chat.groupName());
    const side = classifyArgs("polter\x00+mcp");
    try testing.expectEqual(Kind.sidecar, side.kind);
    const slot = classifyArgs("polter\x00+mcp-slot\x00--slot=x");
    try testing.expectEqual(Kind.sidecar, slot.kind);
    // A chat in a terminal of its own is not the embedded one.
    const own = classifyArgs("polter\x00+chat\x00--group=web-app");
    try testing.expectEqual(Kind.other, own.kind);
}

test "2149: KERN_PROCARGS2 is read past the path and its padding" {
    var raw: [64]u8 = @splat(0);
    std.mem.writeInt(i32, raw[0..4], 2, builtin.cpu.arch.endian());
    const tail = "/bin/x\x00\x00\x00x\x00-y\x00HOME=/z\x00";
    @memcpy(raw[4..][0..tail.len], tail);
    const got = parse(raw[0 .. 4 + tail.len]).?;
    try testing.expectEqual(@as(usize, 2), got.argc);
    try testing.expectEqualStrings("x\x00-y\x00", got.args);
}

test "2149: on macOS this process's own arguments read back" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var buf: [max_bytes]u8 = undefined;
    const got = read(@intCast(std.c.getpid()), &buf) orelse return error.NotRead;
    try testing.expect(got.argc >= 1);
    // A process of another user (launchd, pid 1) is refused, not misread.
    try testing.expect(read(1, &buf) == null);
}
