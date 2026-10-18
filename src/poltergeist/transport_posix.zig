//! The agent socket on POSIX: a unix domain socket, exactly as it always
//! was. Split into a file of its own only so that the Windows half can have
//! one too; nothing here changed when it arrived.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");
const process_info = @import("process_info.zig");

const log = std.log.scoped(.poltergeist);

const net = std.Io.net;

pub const available = net.has_unix_sockets;
pub const Conn = net.Stream;
pub const Reader = net.Stream.Reader;
pub const Writer = net.Stream.Writer;

/// The other end of a connection, as the kernel said when it was first
/// asked (task 1727).
pub const Peer = union(enum) {
    /// A process, and when it started -- so that its number given to a
    /// later process is not mistaken for it. `started` is null when the
    /// process could not be read: it had already exited.
    process: struct { pid: u64, started: ?u64 },
    /// Already disconnected when asked: the kernel no longer had anybody
    /// on the other end to name (`ENOTCONN`, measured on macOS for a
    /// client that had exited; a half-closed one still answers).
    disconnected,
};

/// Who connected, or null when this system will not say who. Null is
/// "cannot tell", and `peerGone` then never calls a connection gone on the
/// strength of its read side ending.
pub fn peerOf(conn: Conn) ?Peer {
    const fd = conn.socket.handle;
    const pid: u64 = switch (builtin.os.tag) {
        .macos => pid: {
            // `SOL_LOCAL`, `LOCAL_PEERPID` from <sys/un.h>.
            var pid: c_int = 0;
            var len: std.c.socklen_t = @sizeOf(c_int);
            const rc = std.c.getsockopt(fd, 0, 0x002, &pid, &len);
            if (rc != 0) return if (std.c.errno(rc) == .NOTCONN) .disconnected else null;
            if (pid <= 0) return null;
            break :pid @intCast(pid);
        },
        .linux => pid: {
            const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };
            var cred: Ucred = undefined;
            var len: std.c.socklen_t = @sizeOf(Ucred);
            const rc = std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.PEERCRED, &cred, &len);
            if (rc != 0) return if (std.c.errno(rc) == .NOTCONN) .disconnected else null;
            if (cred.pid <= 0) return null;
            break :pid @intCast(cred.pid);
        },
        else => return null,
    };
    const info = process_info.of(pid);
    return .{ .process = .{
        .pid = pid,
        .started = if (info) |i| (if (i.zombie) null else i.started) else null,
    } };
}

/// Whether the client is gone, asked without reading anything it sent
/// (task 1727).
///
/// **The read side ending is not enough, and that was measured.** A shell
/// plugin calls through `{ auth; request; } | nc -U`, and macOS's `nc`
/// shuts down its writing half the moment its input ends -- so the request
/// arrives followed at once by end-of-file -- and then waits and reads the
/// answer. A half-closed and a closed socket look the same from here (a
/// peek reads nothing, `poll` says `POLLIN|POLLHUP`, on both). So the end
/// of the read side only opens the question, and the process answers it:
/// gone when it has exited (no such process, a zombie, or the number now
/// belongs to a later one). A reset is gone outright.
pub fn peerGone(conn: Conn, peer: ?Peer) bool {
    var byte: [1]u8 = undefined;
    const n = std.c.recv(conn.socket.handle, &byte, 1, std.c.MSG.PEEK | std.c.MSG.DONTWAIT);
    if (n > 0) return false;
    if (n < 0) return switch (std.c.errno(n)) {
        .AGAIN, .INTR => false,
        .CONNRESET, .NOTCONN, .PIPE => true,
        else => false,
    };
    const p = switch (peer orelse return false) {
        .disconnected => return true,
        .process => |p| p,
    };
    const info = process_info.of(p.pid) orelse return true;
    if (info.zombie) return true;
    // Running now. Under the number it had when it connected: still there.
    // Under a later process's, or one that was already gone when it
    // connected and whose number was given out again since: the number is
    // somebody else's, and the client is gone.
    const started = p.started orelse return false;
    return info.started != started;
}

pub const BindError = error{PathTooLong} || net.UnixAddress.ListenError;
pub const ConnectError = error{PathTooLong} || net.UnixAddress.ConnectError;

pub const Listener = struct {
    server: net.Server,

    pub fn accept(self: *Listener, io: std.Io) std.Io.net.Server.AcceptError!Conn {
        return self.server.accept(io);
    }

    /// Break a thread blocked in `accept`.
    ///
    /// Closing the listener is what does it here, and the socket is not
    /// needed again afterwards. Windows cannot do this; see `knock`
    /// there.
    pub fn wake(self: *Listener, io: std.Io) void {
        self.server.deinit(io);
    }

    /// Only ever reached when `wake` was not: a server that never
    /// started still has to give the descriptor back.
    pub fn deinit(self: *Listener, io: std.Io) void {
        self.server.deinit(io);
    }

    /// Whether `wake` already gave the listener back, so that the two
    /// paths do not release it twice.
    pub const wake_releases = true;
};

pub fn bind(alloc: Allocator, io: std.Io, name: []const u8) BindError!Listener {
    _ = alloc;

    // A socket left behind by a previous run would make listen fail.
    // The name is freshly random per run, so a collision means the file
    // is a leftover rather than someone else's live socket, and
    // removing it saves the user a puzzling failure after a crash.
    std.Io.Dir.cwd().deleteFile(io, name) catch {};

    const addr = net.UnixAddress.init(name) catch return error.PathTooLong;
    return .{ .server = try addr.listen(io, .{}) };
}

pub fn connect(io: std.Io, name: []const u8) ConnectError!Conn {
    const addr = net.UnixAddress.init(name) catch return error.PathTooLong;
    return addr.connect(io);
}

/// Removed on the way out, because it is a real file.
pub fn unlink(io: std.Io, name: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, name) catch {};
}

pub fn defaultName(alloc: Allocator, io: std.Io, state_dir: []const u8) Allocator.Error![]u8 {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    return std.fmt.allocPrint(alloc, "{s}/polter-{x}.sock", .{ state_dir, &raw });
}
