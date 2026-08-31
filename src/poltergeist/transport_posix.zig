//! The agent socket on POSIX: a unix domain socket, exactly as it always
//! was. Split into a file of its own only so that the Windows half can have
//! one too; nothing here changed when it arrived.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.poltergeist);

const net = std.Io.net;

pub const available = net.has_unix_sockets;
pub const Conn = net.Stream;
pub const Reader = net.Stream.Reader;
pub const Writer = net.Stream.Writer;

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
