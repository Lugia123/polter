//! The pipe the agent socket actually runs on, and the one thing the two
//! platforms disagree about.
//!
//! **The protocol does not live here and does not know about this file.**
//! It is line-delimited JSON with the client speaking first, which is why
//! this split is affordable at all: `handshake`, `serveOne`, the tokens and
//! the bus are written against a reader and a writer and never against a
//! socket. Everything below is about how those two are obtained.
//!
//! **POSIX gets a unix domain socket, unchanged.** Windows gets a named
//! pipe, and the reason is not that Windows lacks unix sockets -- it has
//! had them since build 17063. It is that Zig 0.16's Windows AF_UNIX path
//! asserts, in twenty-seven places, that its AFD requests can never be
//! cancelled:
//!
//! ```zig
//! // std/Io/Threaded.zig, netAcceptWindows
//! .CANCELLED => unreachable,
//! ```
//!
//! and closing a listening handle to break a blocked `accept` -- which is
//! exactly what `Server.stop` does, and what `net.Server.AcceptError`'s own
//! documentation calls "a concurrent cancellation mechanism" -- makes the
//! kernel complete that pending request with `STATUS_CANCELLED`. So the
//! supported way to stop a server panics. It was measured doing so: the
//! first socket test killed the whole test process and took the 193 tests
//! after it with it.
//!
//! That is a bug in the standard library rather than in either of us, and
//! it is one line to fix upstream (`.CANCELLED => return
//! error.SocketNotListening`, an error that already exists and already
//! documents this case). But Ghostty pins its Zig, so waiting on upstream
//! would mean waiting to ship, and vendoring a patched standard library is
//! not a thing to do to a product. A named pipe is ours: we make the calls,
//! so we decide what a cancelled read means.
//!
//! **What the two platforms guarantee is not identical, and the difference
//! is worth writing down.** A unix socket is unreachable from off the
//! machine, full stop. A named pipe is *not*: `\\host\pipe\name` is served
//! over SMB to anyone the machine will authenticate. So the pipe is created
//! with a DACL naming this user and nobody else. That is not a translation
//! of the socket's file permissions -- `Server.init` says in as many words
//! that it does not rely on those -- it is closing a door that the unix
//! side never had open.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.poltergeist);

pub const Listener = impl.Listener;
pub const Conn = impl.Conn;
pub const Reader = impl.Reader;
pub const Writer = impl.Writer;

/// Whether this platform can run the agent socket at all.
pub const available = impl.available;

/// Bind and start listening on `name`.
pub const bind = impl.bind;

/// Connect to a server listening on `name`. The client half, shared by the
/// MCP client, the chat client and the tests, so that there is one place
/// that knows what a name means on each platform.
pub const connect = impl.connect;

/// The endpoint a fresh server should use, under `state_dir`.
///
/// On POSIX this is a filesystem path and the socket really appears there.
/// On Windows it is a pipe name, which lives in a kernel namespace and
/// leaves nothing on disk -- `state_dir` is still taken so the two have one
/// signature, and ignored. Callers pass this string around (it reaches
/// clients through `GHOSTTY_POLTER_SOCKET`) without needing to know which
/// of the two they are holding.
pub const defaultName = impl.defaultName;

pub const impl = switch (builtin.os.tag) {
    .windows => @import("transport_windows.zig"),
    else => @import("transport_posix.zig"),
};

/// Remove whatever the endpoint left on disk, if the platform leaves
/// anything.
pub const unlink = impl.unlink;

/// Wake a thread parked in a read on `conn`, from our side.
///
/// Spelled once here because the two platforms need different words for the
/// same idea and the caller should not have to know them: POSIX shuts the
/// socket down in both directions, Windows disconnects the pipe and cancels
/// whatever read was already in flight.
pub fn shutdownConn(conn: Conn, io: std.Io) void {
    switch (builtin.os.tag) {
        .windows => conn.shutdown(io),
        else => conn.shutdown(io, .both) catch {},
    }
}

/// The errors `accept` may answer with, identical on both platforms so that
/// the listen loop's handling of them is one piece of code rather than two.
/// Windows never produces most of them; sharing the set is what keeps the
/// POSIX side of that loop untouched.
pub const AcceptError = std.Io.net.Server.AcceptError;

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "a default name is unique per call" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const a = try defaultName(testing.allocator, io, "/tmp/state");
    defer testing.allocator.free(a);
    const b = try defaultName(testing.allocator, io, "/tmp/state");
    defer testing.allocator.free(b);

    try testing.expect(!std.mem.eql(u8, a, b));
}
