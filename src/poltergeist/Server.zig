//! The local socket Poltergeist listens on, and the tokens that identify
//! who is calling.
//!
//! Each surface gets its own token when its pty environment is built. The
//! server keeps the token-to-terminal mapping, so a caller proves which
//! terminal it is by holding that terminal's token and never by claiming an
//! id. An agent that talks its way into another agent's socket session
//! still cannot claim to be it.
//!
//! Unix socket only, never a network port: otherwise any process on the
//! machine could type into every terminal the user has open.
//!
//! Threading. The listener and each connection run on their own threads,
//! but no request is *executed* there -- the bus and the surfaces belong to
//! the app thread. A connection thread hands the app a `Pending`, waits on
//! its semaphore, and writes whatever came back. That wait is bounded: a
//! request that the app never gets to must not wedge a connection forever.
//!
//! See `docs/poltergeist/mcp.md`.

const Server = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.Io.net;

const Bus = @import("Bus.zig");
const rpc = @import("rpc.zig");
const wire = @import("wire.zig");

const log = std.log.scoped(.poltergeist);

/// Longest request we will read. A request carries an id, a short string
/// and a couple of numbers; anything larger is a mistake or an attack.
const max_request_bytes = 64 * 1024;

/// How many agents may be connected at once. One per terminal running an
/// agent is the shape of the real thing, so this is generous.
const max_connections = 16;

/// One connection's thread and socket, kept so shutdown can close the
/// socket -- which is what unblocks a thread parked in read -- and then
/// join the thread.
const Slot = struct {
    thread: ?std.Thread = null,
    stream: ?net.Stream = null,

    /// Set by the connection thread on its way out, so the accept loop can
    /// reap it without blocking.
    finished: std.atomic.Value(bool) = .init(false),
};

/// Tokens are 32 random bytes, rendered as hex.
const token_bytes = 32;
pub const token_len = token_bytes * 2;

/// One in-flight request, owned by the connection thread that made it.
///
/// The app thread fills `response`, allocating any payload from `arena`,
/// then posts `done`. The connection thread writes the response and frees
/// the arena. Nothing else touches it.
pub const Pending = struct {
    alloc: Allocator,
    caller: Bus.Id,
    request: rpc.Request,

    /// Owns everything the request points at, so it stays valid for as long
    /// as either side still holds a reference.
    arena: std.heap.ArenaAllocator,

    response: ?wire.Response = null,
    done: std.Io.Semaphore = .{},

    /// Guards against being answered twice. The app thread answers in the
    /// normal case and the server answers on shutdown, and both can happen
    /// at once; whichever gets here first is the one that counts.
    settled: std.atomic.Value(bool) = .init(false),

    /// Starts at one, for the connection thread that made it. A second is
    /// taken when it is handed to the app, and the app drops that one when
    /// it is done.
    ///
    /// Heap allocated and counted rather than left on the connection
    /// thread's stack: shutdown can answer a request early, and the
    /// connection thread would then return -- taking the stack frame with
    /// it -- while the app's mailbox still held a pointer to it.
    refs: std.atomic.Value(u8) = .init(1),

    /// Take a reference before handing this to another thread.
    pub fn retain(self: *Pending) void {
        _ = self.refs.fetchAdd(1, .acq_rel);
    }

    /// Answer this request and wake whoever is waiting on it. Safe to call
    /// from either thread, and safe to call more than once.
    pub fn complete(self: *Pending, io: std.Io, response: wire.Response) void {
        if (self.settled.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
        self.response = response;
        self.done.post(io);
    }

    /// Drop one reference. The last one out frees it.
    pub fn release(self: *Pending) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const alloc = self.alloc;
        self.arena.deinit();
        alloc.destroy(self);
    }
};

/// How a request reaches the app thread. A callback rather than a direct
/// dependency on `App`, so this file stays testable and the import graph
/// stays one-way.
pub const Submit = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, pending: *Pending) void,

    fn call(self: Submit, pending: *Pending) void {
        self.func(self.ctx, pending);
    }
};

alloc: Allocator,
io: std.Io,
submit: Submit,

/// Filesystem path of the socket, owned here.
path: []u8,
listener: net.Server,

/// Token to terminal. Written by the app thread when a surface starts,
/// read by connection threads, hence the lock.
tokens: std.StringHashMapUnmanaged(Bus.Id) = .empty,
tokens_mutex: std.Io.Mutex = .init,

/// Requests handed to the app thread and not yet answered.
///
/// The wait for an answer is unbounded on purpose -- a timeout would mean
/// racing the app thread and sometimes reporting a failure for work that
/// then succeeds anyway. Instead every waiter is reachable from here, so
/// shutdown can answer them all and nothing is left blocked.
inflight: std.ArrayListUnmanaged(*Pending) = .empty,
inflight_mutex: std.Io.Mutex = .init,

listen_thread: ?std.Thread = null,
running: std.atomic.Value(bool) = .init(false),

/// Live connections, so shutdown can reach them.
///
/// A detached thread would outlive the server and go on dereferencing it
/// after `deinit` had freed everything. These are joined instead, and the
/// fixed size doubles as a cap: without one, anything that can reach the
/// socket could spawn threads until the process ran out.
slots: [max_connections]Slot = @splat(.{}),
slots_mutex: std.Io.Mutex = .init,

/// Whether the listening socket has been closed. `stop` closes it to
/// unblock accept, and `deinit` closes it when the server never started;
/// without this flag the two paths close it twice.
listener_closed: bool = false,

pub const InitError = error{
    UnixSocketsUnavailable,
    PathTooLong,
} || Allocator.Error || net.UnixAddress.ListenError;

/// Start listening. The socket is created with owner-only permissions.
pub fn init(
    alloc: Allocator,
    io: std.Io,
    path: []const u8,
    submit: Submit,
) InitError!Server {
    if (!net.has_unix_sockets) return error.UnixSocketsUnavailable;

    const owned = try alloc.dupe(u8, path);
    errdefer alloc.free(owned);

    // A socket left behind by a previous run would make listen fail. It is
    // ours by construction -- the path carries our pid -- so removing it is
    // safe and saves the user a puzzling failure after a crash.
    std.Io.Dir.cwd().deleteFile(io, owned) catch {};

    const addr = net.UnixAddress.init(owned) catch return error.PathTooLong;
    var listener = try addr.listen(io, .{});
    errdefer listener.deinit(io);

    // Note there is no chmod here. Socket file permissions are not
    // enforced uniformly across the systems Ghostty runs on, so treating
    // them as the boundary would be a false comfort. The token is the
    // boundary: 32 bytes of fresh entropy per terminal, compared in
    // constant time, and never guessable from anything the caller can see.

    return .{
        .alloc = alloc,
        .io = io,
        .submit = submit,
        .path = owned,
        .listener = listener,
    };
}

pub fn deinit(self: *Server) void {
    self.stop();

    var it = self.tokens.keyIterator();
    while (it.next()) |k| self.alloc.free(k.*);
    self.tokens.deinit(self.alloc);
    self.inflight.deinit(self.alloc);

    self.closeListener();
    std.Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
    self.alloc.free(self.path);
    self.* = undefined;
}

pub fn start(self: *Server) std.Thread.SpawnError!void {
    std.debug.assert(self.listen_thread == null);
    self.running.store(true, .release);
    self.listen_thread = try std.Thread.spawn(.{}, listenMain, .{self});
}

pub fn stop(self: *Server) void {
    self.running.store(false, .release);

    if (self.listen_thread) |t| {
        // Closing the listener is what unblocks accept.
        self.closeListener();
        t.join();
        self.listen_thread = null;
    }

    // Answer everything still waiting, then close and join every
    // connection. Both are needed: answering releases a thread parked on a
    // semaphore, and closing the socket releases one parked in read.
    self.failInflight();
    self.stopConnections();
}

fn closeListener(self: *Server) void {
    if (self.listener_closed) return;
    self.listener_closed = true;
    self.listener.deinit(self.io);
}

fn failInflight(self: *Server) void {
    self.inflight_mutex.lockUncancelable(self.io);
    defer self.inflight_mutex.unlock(self.io);

    for (self.inflight.items) |p| p.complete(self.io, .{ .failed = .{
        .code = "ShuttingDown",
        .message = "the terminal is going away",
    } });
    self.inflight.clearRetainingCapacity();
}

fn trackInflight(self: *Server, p: *Pending) Allocator.Error!void {
    self.inflight_mutex.lockUncancelable(self.io);
    defer self.inflight_mutex.unlock(self.io);
    try self.inflight.append(self.alloc, p);
}

fn untrackInflight(self: *Server, p: *Pending) void {
    self.inflight_mutex.lockUncancelable(self.io);
    defer self.inflight_mutex.unlock(self.io);

    for (self.inflight.items, 0..) |item, i| {
        if (item == p) {
            _ = self.inflight.swapRemove(i);
            return;
        }
    }
}

/// Mint a token for a terminal, to be put in its pty environment.
///
/// Called on the app thread as a surface starts. The returned slice is
/// owned by the server and stays valid until the server is torn down.
pub fn issueToken(self: *Server, id: Bus.Id) Allocator.Error![]const u8 {
    var raw: [token_bytes]u8 = undefined;

    // Fresh entropy from the OS. Falling back to the process-local
    // generator is better than refusing to start, and it is still a
    // cryptographic generator -- just one seeded earlier.
    self.io.randomSecure(&raw) catch |err| {
        log.warn("poltergeist: no fresh entropy for a token, falling back err={}", .{err});
        self.io.random(&raw);
    };

    const hex = try self.alloc.alloc(u8, token_len);
    errdefer self.alloc.free(hex);
    _ = std.fmt.bufPrint(hex, "{x}", .{&raw}) catch unreachable;

    self.tokens_mutex.lockUncancelable(self.io);
    defer self.tokens_mutex.unlock(self.io);
    try self.tokens.put(self.alloc, hex, id);

    return hex;
}

/// Forget a terminal's token, so a socket held open past the terminal's
/// life cannot go on acting as it.
pub fn revokeTokens(self: *Server, id: Bus.Id) void {
    self.tokens_mutex.lockUncancelable(self.io);
    defer self.tokens_mutex.unlock(self.io);

    var stale: std.ArrayListUnmanaged([]const u8) = .empty;
    defer stale.deinit(self.alloc);

    var it = self.tokens.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* == id) stale.append(self.alloc, kv.key_ptr.*) catch {};
    }

    for (stale.items) |k| {
        _ = self.tokens.remove(k);
        self.alloc.free(k);
    }
}

/// Which terminal a token belongs to, if any.
fn authenticate(self: *Server, token: []const u8) ?Bus.Id {
    if (token.len != token_len) return null;

    self.tokens_mutex.lockUncancelable(self.io);
    defer self.tokens_mutex.unlock(self.io);

    // Constant time against every issued token. The threat here is small --
    // a local socket with owner-only permissions -- but comparing in
    // constant time costs nothing at this scale.
    var found: ?Bus.Id = null;
    var it = self.tokens.iterator();
    while (it.next()) |kv| {
        const match = std.crypto.timing_safe.eql(
            [token_len]u8,
            kv.key_ptr.*[0..token_len].*,
            token[0..token_len].*,
        );
        if (match) found = kv.value_ptr.*;
    }
    return found;
}

fn listenMain(self: *Server) void {
    while (self.running.load(.acquire)) {
        const stream = self.listener.accept(self.io) catch |err| {
            if (!self.running.load(.acquire)) return;

            // Running out of descriptors or memory is temporary. Returning
            // here would end the accept loop for good while the socket file
            // and the tokens stayed in place, so every later connection
            // would hang with nothing in the log to explain it.
            switch (err) {
                error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded,
                error.SystemResources,
                error.ConnectionAborted,
                => {
                    log.warn("poltergeist: accept failed, retrying err={}", .{err});
                    self.reapFinished();
                    continue;
                },
                else => {
                    log.warn("poltergeist: accept failed, stopping err={}", .{err});
                    return;
                },
            }
        };

        self.reapFinished();

        const index = self.claimSlot(stream) orelse {
            log.warn("poltergeist: too many agent connections, refusing one", .{});
            stream.close(self.io);
            continue;
        };

        const thread = std.Thread.spawn(
            .{},
            connectionMain,
            .{ self, index },
        ) catch |err| {
            log.warn("poltergeist: could not serve connection err={}", .{err});
            self.releaseSlot(index);
            stream.close(self.io);
            continue;
        };

        self.slots_mutex.lockUncancelable(self.io);
        self.slots[index].thread = thread;
        self.slots_mutex.unlock(self.io);
    }
}

/// Join and clear any connection whose thread has finished.
fn reapFinished(self: *Server) void {
    for (0..max_connections) |i| {
        self.slots_mutex.lockUncancelable(self.io);
        const done = self.slots[i].thread != null and
            self.slots[i].finished.load(.acquire);
        const thread = if (done) self.slots[i].thread else null;
        if (done) self.slots[i] = .{};
        self.slots_mutex.unlock(self.io);

        if (thread) |t| t.join();
    }
}

fn claimSlot(self: *Server, stream: net.Stream) ?usize {
    self.slots_mutex.lockUncancelable(self.io);
    defer self.slots_mutex.unlock(self.io);

    for (0..max_connections) |i| {
        if (self.slots[i].stream == null) {
            self.slots[i] = .{ .stream = stream };
            return i;
        }
    }
    return null;
}

fn releaseSlot(self: *Server, index: usize) void {
    self.slots_mutex.lockUncancelable(self.io);
    defer self.slots_mutex.unlock(self.io);
    self.slots[index] = .{};
}

/// Close every live connection and join its thread.
///
/// Closing the socket is what unblocks a thread parked in read; without it
/// a join here would wait forever on a connection that is simply idle.
fn stopConnections(self: *Server) void {
    var threads: [max_connections]?std.Thread = @splat(null);

    self.slots_mutex.lockUncancelable(self.io);
    for (0..max_connections) |i| {
        if (self.slots[i].stream) |stream| stream.close(self.io);
        threads[i] = self.slots[i].thread;
        self.slots[i] = .{};
    }
    self.slots_mutex.unlock(self.io);

    for (threads) |t| if (t) |thread| thread.join();
}

fn connectionMain(self: *Server, index: usize) void {
    // The socket belongs to the slot, and shutdown closes it there. This
    // thread only marks itself finished so the accept loop can reap it.
    defer self.slots[index].finished.store(true, .release);

    const stream = stream: {
        self.slots_mutex.lockUncancelable(self.io);
        defer self.slots_mutex.unlock(self.io);
        break :stream self.slots[index].stream orelse return;
    };

    var read_buf: [max_request_bytes]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(self.io, &read_buf);
    var writer = stream.writer(self.io, &write_buf);

    // A connection says who it is once, before anything else.
    const caller = self.handshake(&reader, &writer) orelse return;

    while (self.running.load(.acquire)) {
        // `takeDelimiter`, not `takeDelimiterExclusive`: the latter leaves
        // the newline in the buffer, so every call after the first returns
        // an empty slice without advancing and this loop spins forever.
        const line = (reader.interface.takeDelimiter('\n') catch return) orelse return;
        if (line.len == 0) continue;
        self.serveOne(&writer, caller, line) catch return;
    }
}

/// Read the opening line and check its token.
fn handshake(
    self: *Server,
    reader: *net.Stream.Reader,
    writer: *net.Stream.Writer,
) ?Bus.Id {
    const line = (reader.interface.takeDelimiter('\n') catch return null) orelse return null;

    const token = parseAuthToken(self.alloc, line) orelse {
        self.refuse(writer, "BadHandshake", "first line must be an auth request");
        return null;
    };
    defer self.alloc.free(token);

    const caller = self.authenticate(token) orelse {
        self.refuse(writer, "BadToken", "token not recognised");
        return null;
    };

    wire.writeResponse(&writer.interface, .ok) catch return null;
    writer.interface.flush() catch return null;
    return caller;
}

/// Pull `params.token` out of an `auth` request without going through the
/// rpc surface, which deliberately has no idea tokens exist.
fn parseAuthToken(alloc: Allocator, line: []const u8) ?[]const u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const v = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        line,
        .{},
    ) catch return null;

    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };

    const method = switch (obj.get("method") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (!std.mem.eql(u8, method, "auth")) return null;

    const params = switch (obj.get("params") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const token = switch (params.get("token") orelse return null) {
        .string => |s| s,
        else => return null,
    };

    return alloc.dupe(u8, token) catch null;
}

fn serveOne(
    self: *Server,
    writer: *net.Stream.Writer,
    caller: Bus.Id,
    line: []const u8,
) !void {
    // The request is parsed straight into the pending's arena, so anything
    // it points at lives exactly as long as the pending does. Parsing into
    // a local arena instead would leave the app holding slices into memory
    // this function had already freed.
    const pending = try self.alloc.create(Pending);
    pending.* = .{
        .alloc = self.alloc,
        .caller = caller,
        .request = undefined,
        .arena = .init(self.alloc),
    };

    // Ours to release however this goes; the app takes its own before the
    // request is handed over.
    defer pending.release();

    pending.request = wire.parseRequestLeaky(
        pending.arena.allocator(),
        line,
    ) catch |err| {
        const code, const message = switch (err) {
            error.Malformed => .{ "Malformed", "could not read that as a request" },
            error.UnknownMethod => .{ "UnknownMethod", "no such method" },
            error.BadParams => .{ "BadParams", "a parameter is missing or the wrong type" },
            error.OutOfMemory => .{ "OutOfMemory", "out of memory" },
        };

        self.refuse(writer, code, message);
        return;
    };

    try self.trackInflight(pending);

    pending.retain();
    self.submit.call(pending);
    pending.done.waitUncancelable(self.io);
    self.untrackInflight(pending);

    const response = pending.response orelse {
        self.refuse(writer, "NoResponse", "the terminal produced no answer");
        return;
    };

    try wire.writeResponse(&writer.interface, response);
    try writer.interface.flush();
}

fn refuse(
    self: *Server,
    writer: *net.Stream.Writer,
    code: []const u8,
    message: []const u8,
) void {
    _ = self;
    wire.writeResponse(&writer.interface, .{ .failed = .{
        .code = code,
        .message = message,
    } }) catch return;
    writer.interface.flush() catch return;
}

/// Where this process's socket lives.
///
/// The name carries random bytes rather than the pid. It is one fewer thing
/// leaked into a path other processes can list, and two Ghostty processes
/// -- or one restarted after a crash that left its socket behind -- cannot
/// collide.
pub fn defaultPath(alloc: Allocator, io: std.Io, state_dir: []const u8) Allocator.Error![]u8 {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    return std.fmt.allocPrint(alloc, "{s}/polter-{x}.sock", .{ state_dir, &raw });
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    // Zig only analyses what is referenced, and almost everything here is
    // reached from a thread rather than from a test. Without this the
    // socket and threading code would never be type-checked at all.
    testing.refAllDecls(@This());
}

test "an auth line yields its token" {
    const token = parseAuthToken(testing.allocator,
        \\{"method":"auth","params":{"token":"abc"}}
    ) orelse return error.TestExpectedToken;
    defer testing.allocator.free(token);
    try testing.expectEqualStrings("abc", token);
}

test "anything but an auth line is refused" {
    try testing.expect(parseAuthToken(testing.allocator, "not json") == null);
    try testing.expect(parseAuthToken(testing.allocator,
        \\{"method":"me"}
    ) == null);
    try testing.expect(parseAuthToken(testing.allocator,
        \\{"method":"auth"}
    ) == null);
    try testing.expect(parseAuthToken(testing.allocator,
        \\{"method":"auth","params":{}}
    ) == null);
    try testing.expect(parseAuthToken(testing.allocator,
        \\{"method":"auth","params":{"token":42}}
    ) == null);
}

test "a token is long enough to be worth having" {
    // 32 random bytes. Short enough tokens invite guessing even on a
    // socket only the owner can open.
    try testing.expectEqual(@as(usize, 64), token_len);
    try testing.expect(token_bytes >= 16);
}

test "two socket paths in the same directory do not collide" {
    const io = std.Io.Threaded.global_single_threaded.io();

    const a = try defaultPath(testing.allocator, io, "/run/user/1000/ghostty");
    defer testing.allocator.free(a);
    const b = try defaultPath(testing.allocator, io, "/run/user/1000/ghostty");
    defer testing.allocator.free(b);

    try testing.expect(std.mem.startsWith(u8, a, "/run/user/1000/ghostty/polter-"));
    try testing.expect(std.mem.endsWith(u8, a, ".sock"));
    try testing.expect(!std.mem.eql(u8, a, b));
}
