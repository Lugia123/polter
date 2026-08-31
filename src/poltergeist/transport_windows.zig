//! The agent socket on Windows: a named pipe. See `transport.zig` for why
//! it is not a unix socket, which Windows does in fact support.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.poltergeist);

const w = internal_os.windows;
const k32 = w.exp.kernel32;

pub const available = true;
pub const Reader = std.Io.File.Reader;
pub const Writer = std.Io.File.Writer;

pub const BindError = error{ PathTooLong, Win32 } || Allocator.Error;
pub const ConnectError = error{ PathTooLong, Win32 };

/// Longest pipe name we will build, in UTF-16 units. `\\.\pipe\` plus a
/// name we generate ourselves, so this is generous rather than tight.
pub const max_name_w = 256;

/// One connected pipe instance.
///
/// A `std.Io.File` rather than a handle of its own, so that the reader
/// and writer the protocol wants come from the standard library and the
/// only thing this file adds is how they start and stop.
pub const Conn = struct {
    file: std.Io.File,

    pub fn reader(self: Conn, io: std.Io, buf: []u8) Reader {
        return self.file.reader(io, buf);
    }

    pub fn writer(self: Conn, io: std.Io, buf: []u8) Writer {
        return self.file.writer(io, buf);
    }

    /// Wake a thread parked in a read on this connection, from our side.
    ///
    /// **Disconnect only. Never cancel.**
    ///
    /// `CancelIoEx` looks like the right tool and is wrong twice over. On a
    /// synchronous handle it does nothing at all: it cancels *asynchronous*
    /// operations, and a blocking `ReadFile` issued by another thread is
    /// not one -- so the disconnect, an FSCTL on the same handle, queued
    /// behind that read and the two waited on each other. On an
    /// asynchronous handle it works, and that is worse: the read completes
    /// with `STATUS_CANCELLED`, which `ntReadFileResult` in the standard
    /// library answers with `unreachable`. Cancelling either achieves
    /// nothing or kills the process; there is no handle type where it helps.
    ///
    /// `DisconnectNamedPipe` alone covers both sides, which is what the
    /// sticky half was always for: a read already in flight ends with
    /// `STATUS_PIPE_DISCONNECTED`, and every read issued afterwards fails
    /// the same way immediately. That status *is* representable -- the
    /// standard library spells it `error.Unexpected`, a poor name for an
    /// ordinary error -- and the connection loop already treats any read
    /// error as this connection being over.
    ///
    /// Failure is ignored on purpose: a pipe already disconnected reports
    /// failure and means the job is done.
    pub fn shutdown(self: Conn, io: std.Io) void {
        _ = io;
        _ = k32.DisconnectNamedPipe(self.file.handle);
    }

    pub fn close(self: Conn, io: std.Io) void {
        self.file.close(io);
    }
};

pub const Listener = struct {
    /// The instance currently sitting in `ConnectNamedPipe`. Each accept
    /// hands this one out and puts a fresh instance here, because a
    /// connected instance *is* the connection -- there is no separate
    /// listening object the way there is with a socket.
    pending: w.HANDLE,

    /// The name, kept so that further instances can be made without
    /// going back to the caller's string.
    name_w: [max_name_w]u16,
    name_len: usize,

    /// Owned: every instance is created with this DACL.
    sd: w.OwnerOnly,

    /// Signalled by `ConnectNamedPipe` when a client arrives.
    connect_event: w.HANDLE,

    /// Signalled once by `wake`, and never reset. **Sticky by
    /// construction**, which is the property the knock was reaching for and
    /// could not guarantee: an event that has been set stays set, so it
    /// does not matter whether `accept` was already waiting.
    stop_event: w.HANDLE,

    overlapped: w.OVERLAPPED,

    fn nameZ(self: *const Listener) [*:0]const u16 {
        return @ptrCast(&self.name_w);
    }

    fn makeInstance(self: *const Listener, first: bool) ?w.HANDLE {
        var sa = self.sd.attributes();
        const h = k32.CreateNamedPipeW(
            self.nameZ(),
            w.PIPE_ACCESS_DUPLEX | w.FILE_FLAG_OVERLAPPED |
                @as(w.DWORD, if (first) w.FILE_FLAG_FIRST_PIPE_INSTANCE else 0),
            w.PIPE_TYPE_BYTE | w.PIPE_READMODE_BYTE | w.PIPE_WAIT,
            w.PIPE_UNLIMITED_INSTANCES,
            64 * 1024,
            64 * 1024,
            0,
            &sa,
        );
        return if (h == w.INVALID_HANDLE_VALUE) null else h;
    }

    pub fn accept(self: *Listener, io: std.Io) std.Io.net.Server.AcceptError!Conn {
        _ = io;

        const h = self.pending;

        self.overlapped = std.mem.zeroes(w.OVERLAPPED);
        self.overlapped.hEvent = self.connect_event;

        if (k32.ConnectNamedPipe(h, &self.overlapped) == w.FALSE) {
            switch (@intFromEnum(w.GetLastError())) {
                // Success spelled as failure: a client opened the pipe
                // between our creating the instance and our asking to wait,
                // so there is nothing left to wait for.
                w.ERROR_PIPE_CONNECTED => {},

                // The ordinary case for an overlapped connect. Wait for
                // either a client or the order to stop.
                w.ERROR_IO_PENDING => {
                    const handles = [_]w.HANDLE{ self.connect_event, self.stop_event };
                    if (k32.WaitForMultipleObjects(2, &handles, w.FALSE, w.INFINITE) !=
                        w.WAIT_OBJECT_0)
                    {
                        // Stopping. Take the connect request back first, or
                        // it stays queued against a handle `deinit` is
                        // about to close.
                        // Cancelling a *connect* is safe where cancelling
                        // a read is not: nothing in the standard library
                        // inspects this request's status. Reaped before
                        // returning, so the kernel has finished writing
                        // into `overlapped` before anything closes the
                        // handle it belongs to.
                        _ = k32.CancelIoEx(h, &self.overlapped);
                        var got: w.DWORD = 0;
                        _ = k32.GetOverlappedResult(h, &self.overlapped, &got, w.TRUE);
                        return error.SocketNotListening;
                    }
                },

                else => return error.ConnectionAborted,
            }
        }

        self.pending = self.makeInstance(false) orelse w.INVALID_HANDLE_VALUE;

        // **Asynchronous, and that is load-bearing rather than a
        // preference.** A synchronous handle serialises every operation on
        // the file object, so `DisconnectNamedPipe` from the shutdown
        // thread queues *behind* the reader's blocking `ReadFile` -- and
        // `CancelIoEx`, which cancels *asynchronous* operations, does
        // nothing at all for a synchronous read. Built that way first, and
        // it deadlocked every teardown that caught a connection actually
        // parked in a read. The standard library makes the same split for
        // its own pipes: server end asynchronous, client end synchronous.
        return .{ .file = .{ .handle = h, .flags = .{ .nonblocking = true } } };
    }

    /// Break a thread blocked in `accept`.
    ///
    /// **An event, not a knock, and not a close.** Closing the handle under
    /// a pending connect is the pattern that panics inside the standard
    /// library's own socket path. Knocking -- opening the pipe as a client
    /// so that `accept` returns an ordinary connection -- works, but it can
    /// fail (every instance busy, the name momentarily gone) and then
    /// silently does nothing; for a caller whose next statement is `join`,
    /// that is a process which never exits. An event has neither problem:
    /// `SetEvent` cannot meaningfully fail on a handle we own, and a
    /// manual-reset event that has been set **stays** set, so it does not
    /// matter whether `accept` was already waiting when this ran.
    pub fn wake(self: *Listener, io: std.Io) void {
        _ = io;
        if (k32.SetEvent(self.stop_event) == w.FALSE) {
            log.warn(
                "poltergeist: could not signal the agent listener to stop " ++
                    "(err={}); shutdown may block joining it",
                .{w.GetLastError()},
            );
        }
    }

    pub fn deinit(self: *Listener, io: std.Io) void {
        _ = io;
        if (self.pending != w.INVALID_HANDLE_VALUE) {
            _ = k32.CloseHandle(self.pending);
            self.pending = w.INVALID_HANDLE_VALUE;
        }
        _ = k32.CloseHandle(self.connect_event);
        _ = k32.CloseHandle(self.stop_event);
        self.sd.deinit();
    }

    /// Unlike POSIX, waking leaves the listener intact -- it only sets an
    /// event -- so `deinit` still has work to do afterwards.
    pub const wake_releases = false;
};

/// `\\.\pipe\` plus the name, as UTF-16 with a terminator.
pub fn toPipePath(name: []const u8, out: *[max_name_w]u16) error{PathTooLong}!usize {
    const prefix = "\\\\.\\pipe\\";

    // Already a pipe path (a client handed one straight back to us).
    const body = if (std.mem.startsWith(u8, name, prefix))
        name[prefix.len..]
    else
        name;

    var buf: [max_name_w]u8 = undefined;
    const utf8 = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, body }) catch
        return error.PathTooLong;

    const n = std.unicode.wtf8ToWtf16Le(out[0 .. out.len - 1], utf8) catch
        return error.PathTooLong;
    out[n] = 0;
    return n;
}

pub fn bind(alloc: Allocator, io: std.Io, name: []const u8) BindError!Listener {
    _ = io;

    var self: Listener = .{
        .pending = w.INVALID_HANDLE_VALUE,
        .name_w = undefined,
        .name_len = 0,
        .sd = undefined,
        .connect_event = undefined,
        .stop_event = undefined,
        .overlapped = std.mem.zeroes(w.OVERLAPPED),
    };

    // Manual reset for both: the stop event must stay set once set, and the
    // connect event is only ever waited on immediately after arming it.
    self.connect_event = k32.CreateEventW(null, w.TRUE, w.FALSE, null) orelse
        return error.Win32;
    errdefer _ = k32.CloseHandle(self.connect_event);
    self.stop_event = k32.CreateEventW(null, w.TRUE, w.FALSE, null) orelse
        return error.Win32;
    errdefer _ = k32.CloseHandle(self.stop_event);
    self.name_len = try toPipePath(name, &self.name_w);

    self.sd = w.ownerOnly(alloc, "GA") catch {
        // Loud, because the alternative is a pipe the whole machine can
        // reach over SMB and nothing anywhere saying so. Refusing to
        // listen is the right trade here and not the one `Plugin`
        // makes: a settings file with weak permissions is still a
        // working plugin, but a socket anybody can drive is the exact
        // thing this server exists to prevent.
        log.warn(
            "poltergeist: could not build the pipe's access control " ++
                "(err={}); refusing to listen rather than opening one " ++
                "this machine's other accounts could drive",
            .{w.lastError},
        );
        return error.Win32;
    };
    errdefer self.sd.deinit();

    // `FIRST_PIPE_INSTANCE` so that a name already in use is an error
    // here rather than a silent handover: without it another process
    // could have got to the name first and be handed the agent
    // connections.
    self.pending = self.makeInstance(true) orelse {
        log.warn(
            "poltergeist: could not create the agent pipe err={}",
            .{w.GetLastError()},
        );
        return error.Win32;
    };

    return self;
}

pub fn connect(io: std.Io, name: []const u8) ConnectError!Conn {
    _ = io;

    var name_w: [max_name_w]u16 = undefined;
    _ = try toPipePath(name, &name_w);

    const h = k32.CreateFileW(
        @ptrCast(&name_w),
        w.GENERIC_READ | w.GENERIC_WRITE,
        0,
        null,
        w.OPEN_EXISTING,
        w.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h == w.INVALID_HANDLE_VALUE) return error.Win32;

    return .{ .file = .{ .handle = h, .flags = .{ .nonblocking = false } } };
}

/// Nothing to remove: a pipe name lives in a kernel namespace and is
/// gone when its last handle closes. The counterpart of the sweep that
/// POSIX needs for the files it leaves behind.
pub fn unlink(io: std.Io, name: []const u8) void {
    _ = io;
    _ = name;
}

pub fn defaultName(alloc: Allocator, io: std.Io, state_dir: []const u8) Allocator.Error![]u8 {
    _ = state_dir;
    var raw: [8]u8 = undefined;
    io.random(&raw);
    return std.fmt.allocPrint(alloc, "\\\\.\\pipe\\polter-{x}", .{&raw});
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "a windows pipe path is built once, not twice" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    // The client is handed whatever `defaultName` produced, which is
    // already a full pipe path. Prefixing it a second time would name a
    // pipe nobody is listening on, and the failure would look like the
    // server never started.
    var out: [max_name_w]u16 = undefined;
    const n = try toPipePath("\\\\.\\pipe\\polter-abc", &out);

    var back: [max_name_w]u8 = undefined;
    const len = try std.unicode.wtf16LeToWtf8(&back, out[0..n]);
    try testing.expectEqualStrings("\\\\.\\pipe\\polter-abc", back[0..len]);
}
