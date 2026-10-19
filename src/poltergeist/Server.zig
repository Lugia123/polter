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
//! See `dev-docs/poltergeist/mcp.md`.

const Server = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const net = std.Io.net;
const posix = std.posix;

const Bus = @import("Bus.zig");
const transport = @import("transport.zig");
const rpc = @import("rpc.zig");
const wire = @import("wire.zig");
const agent_cli = @import("agent_cli.zig");
const Plugin = @import("Plugin.zig");

const log = std.log.scoped(.poltergeist);

/// Longest request we will read. A request carries an id, a short string
/// and a couple of numbers; anything larger is a mistake or an attack.
/// The line and its newline both count. `pub` for `+hook`, whose approvals
/// carry a whole tool call and so are the one request that can reach it.
pub const max_request_bytes = 64 * 1024;

/// The cap when nobody says otherwise, and the bounds a setting is held to.
///
/// **This used to be `const max_connections = 16` with a comment calling it
/// generous.** It was generous for the shape the author had in mind -- one
/// person, a handful of terminals -- and it was measured full on an ordinary
/// working day: fifteen agent CLIs alive at once, every one with a running
/// parent, so nothing had leaked and nothing could be reclaimed. Past that
/// point every new terminal is refused for as long as the others live, and
/// the refusal does not heal on its own.
///
/// So the number is a setting now (`poltergeist-max-agents`). These bounds
/// are here because a connection is a thread and two buffers, and because
/// the array is allocated once at startup: zero would refuse everything and
/// a very large value would reserve memory for connections that will never
/// arrive.
pub const default_max_connections = 64;

/// Room for a slot's sighting: every adapter's names and their values,
/// checked to be short (`Plugin.AgentCli`, `agent_cli.Sighting`).
const max_sighting = 2048;
/// Most variables a sighting carries, across all adapters.
const max_sighting_env = 16;
pub const min_max_connections = 1;
pub const limit_max_connections = 256;

/// How many connections `init` makes room for when asked for
/// `max_connections` (`poltergeist-max-agents`): clamped rather than
/// rejected. **The most agents' requests that can be in flight at once**,
/// since each connection is lock-step -- which is what the app's queue for
/// them is sized by (task 1730, `App.poltergeist_requests`).
pub fn slotCount(max_connections: usize) usize {
    return std.math.clamp(max_connections, min_max_connections, limit_max_connections);
}

/// One connection's thread and socket, kept so shutdown can close the
/// socket -- which is what unblocks a thread parked in read -- and then
/// join the thread.
const Slot = struct {
    thread: ?std.Thread = null,
    stream: ?transport.Conn = null,

    /// Who this connection proved itself to be, once its handshake is
    /// through. `null` until then, and `null` again the moment the
    /// connection is over.
    ///
    /// **This is what makes "is an agent listening in that terminal" a
    /// question anything can ask.** The handshake already resolves a token
    /// to a `Caller` (see `connectionMain`), but it used to resolve it into
    /// a local and nothing outside that thread could see it. Notices are
    /// typed into a terminal as if a person had typed them, and typed into
    /// one running a bare shell they are *executed* -- so the party doing
    /// the typing has to be able to ask this.
    ///
    /// **Cleared where `stream` is cleared, not in `releaseSlot`.** The slot
    /// is only wiped when the accept loop reaps the finished thread, which
    /// is later -- and in between, this would still name a terminal whose
    /// agent has already gone.
    caller: ?Bus.Caller = null,

    /// The connection said, when it authenticated, that it only waits to be
    /// told things (`Kind.listens`). Cleared with `caller`.
    listens: bool = false,

    /// Which time an agent has been connected from its terminal, for an
    /// agent's connection (`agentRound`); 0 for one that listens. Cleared
    /// with `caller`.
    round: u64 = 0,

    /// What the connection said about the program that started it
    /// (`agent_cli.Sighting`), checked and written back compactly as
    /// `{"pid":…,"env":{…}}`; empty when it said nothing. **In the slot
    /// itself, not allocated**, because a slot is wiped by assigning `.{}`
    /// in four places and an allocation would leak at each. Cleared with
    /// `caller`.
    sighting: [max_sighting]u8 = undefined,
    sighting_len: u16 = 0,

    /// Set by the connection thread on its way out, so the accept loop can
    /// reap it without blocking.
    finished: std.atomic.Value(bool) = .init(false),
};

/// What a connection says it is, beside its token in `auth`.
///
/// **Accounting, never authority** (the rule `cli/mcp_slot.zig` set down
/// for this field before anything sent it): the token decides who a
/// connection is and what it may reach, and nothing here grants or takes
/// away a request it may make. What it changes is one answer --
/// `agentPresent` -- and why is #1498.
///
/// # The defect
///
/// `+mcp` holds two connections: the one an agent's tool calls go over,
/// and a notifier that parks a `persona_wait` here for up to
/// `PersonaWaits.timeout_ms` (30 s). A thread serving a parked request is
/// waiting on its answer, not reading its socket, so it learns its client
/// has gone only when the wait comes back. Until then that slot still named
/// the terminal, and `agentPresent` said an agent was there for up to half
/// a minute after the CLI had exited. Measured on a Mac (round seven): a
/// worker's pane stopped with ctrl+c was not used again 3 s later and was
/// at 34 s. Worse, and the reason this is not a matter of speed: a notice
/// in that half minute is *typed* into what is by then a bare shell
/// (`App.noticeFor`), which runs it.
///
/// So a connection that only listens says so, and is not counted. Whether
/// an agent is there is answered by the connection its tool calls use,
/// which `+mcp` opens first and holds until it exits.
///
/// **No `kind`, or one this build does not know, is an agent.** An older
/// `+mcp` connects to a newer Polter saying nothing -- the host's MCP config
/// records a path, and the binary behind it can be replaced -- and today
/// that is what every connection is. Reading silence as "listens" would
/// make every agent of an older build look absent, and notices to it would
/// be printed where it never reads them.
pub const Kind = enum {
    /// Carries an agent's tool calls. Sends no `kind`, as every client did
    /// before there was one.
    agent,
    /// `+mcp`'s second connection, which parks `persona_wait`.
    notifier,
    /// A `+mcp-slot` process, which asks about its slot and waits.
    slot,
    /// `+hook`, `+launch` and `+statusline` saying one thing and going
    /// (task 1747). Not an agent: `+launch` says `hooks_expected` this way
    /// before its CLI has started, and counted, that one request made the
    /// launch it announced "connected" from its first millisecond -- the
    /// minute with no agent (`Bus.launchWithNoAgent`) then never ran out.
    hook,

    /// Not counted by `agentPresent`.
    pub fn listens(self: Kind) bool {
        return switch (self) {
            .agent => false,
            .notifier, .slot, .hook => true,
        };
    }

    /// What goes after the token in `auth`: nothing for an agent.
    pub fn authField(self: Kind) []const u8 {
        return switch (self) {
            .agent => "",
            .notifier => ",\"kind\":\"notifier\"",
            .slot => ",\"kind\":\"slot\"",
            .hook => ",\"kind\":\"hook\"",
        };
    }
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
    caller: Bus.Caller,
    request: rpc.Request,

    /// Owns everything the request points at, so it stays valid for as long
    /// as either side still holds a reference.
    arena: std.heap.ArenaAllocator,

    response: ?wire.Response = null,

    /// Set once, by whichever `complete` counts. An event rather than a
    /// semaphore so that it can be waited on with a timeout: the
    /// connection thread looks up between waits to see whether its client
    /// is still there (task 1727, `awaitAnswer`).
    done: std.Io.Event = .unset,

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
        _ = self.settle(io, response);
    }

    /// `complete`, saying whether this call was the one that counted: false
    /// when the request had already been answered, and then nothing here
    /// changed.
    pub fn settle(self: *Pending, io: std.Io, response: wire.Response) bool {
        if (self.settled.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return false;
        self.response = response;
        self.done.set(io);
        return true;
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
///
/// The callback is handed one reference and owns it. Whoever ends up
/// answering the request -- the callback itself, or whatever it passes the
/// pointer along to -- must call `Pending.release` exactly once when it is
/// finished. Answering it is not enough: the connection thread may still be
/// reading from it.
pub const Submit = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, pending: *Pending) void,

    /// Tell the person that an agent was turned away because every slot is
    /// taken.
    ///
    /// **Separate from `func` because there is no `Pending` to carry it.** A
    /// refused connection never handshakes, so it has no `Caller`, no
    /// terminal and no session -- everything `Pending` is built out of. The
    /// one thing left is to say it to the person, and the person is not in
    /// any particular terminal from this side of the socket.
    ///
    /// Optional so tests and any other embedder can leave it out.
    full: ?*const fn (ctx: *anyopaque, in_use: usize) void = null,

    /// An agent's connection from a terminal has closed (task 1668). Called
    /// on the connection's own thread, after the slot no longer names the
    /// terminal, so `agentPresent` already answers without it. **Nothing
    /// else would notice**: who is connected is otherwise looked at only
    /// when a watched screen reports, and an agent whose MCP server died
    /// while its screen stayed still would never be looked at again.
    ///
    /// Optional so tests and any other embedder can leave it out.
    agent_gone: ?*const fn (ctx: *anyopaque) void = null,

    fn call(self: Submit, pending: *Pending) void {
        self.func(self.ctx, pending);
    }

    fn callFull(self: Submit, in_use: usize) void {
        if (self.full) |f| f(self.ctx, in_use);
    }

    fn callAgentGone(self: Submit) void {
        if (self.agent_gone) |f| f(self.ctx);
    }
};

alloc: Allocator,
io: std.Io,
submit: Submit,

/// How to reach this server, owned here. A filesystem path on POSIX and a
/// `\\.\pipe\` name on Windows; the string is passed around and handed to
/// clients through `GHOSTTY_POLTER_SOCKET` without either side needing to
/// know which of the two it is holding. See `transport.zig`.
path: []u8,
listener: transport.Listener,

/// Token to caller. Written by the app thread when a surface starts or a
/// plugin is spawned, read by connection threads, hence the lock.
///
/// **Both kinds of caller live in one map on purpose.** A token is a token;
/// what it stands for is the value, and there is exactly one place that
/// turns bytes on a socket into an identity. Two maps would be two
/// handshake paths, and the second one is where the check gets forgotten.
///
/// The key is owned here. So is everything inside a plugin value -- its key
/// and its declared calls -- because the manifest arena those came out of
/// is rebuilt every time the plugin directories are read.
tokens: std.StringHashMapUnmanaged(Bus.Caller) = .empty,
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
/// Allocated once at `init` and never resized: a connection thread holds an
/// index into it, so growing it under them would move the memory they are
/// using. Changing the setting takes effect the next time the socket opens.
slots: []Slot,
slots_mutex: std.Io.Mutex = .init,

/// The last round handed out (`agentRound`), under `slots_mutex`. One
/// count for every terminal, so a round is never anybody else's.
rounds: u64 = 0,

/// Whether the person has been told this time that every slot is taken,
/// and how often it has happened since (task 1731). The accept loop's alone:
/// a refusal and a slot claimed both happen there.
full: FullGate = .{},

/// Whether the listening socket has been closed. `stop` closes it to
/// unblock accept, and `deinit` closes it when the server never started;
/// without this flag the two paths close it twice.
listener_closed: bool = false,

pub const InitError = error{
    UnixSocketsUnavailable,
} || Allocator.Error || transport.impl.BindError;

/// Start listening.
pub fn init(
    alloc: Allocator,
    io: std.Io,
    path: []const u8,
    submit: Submit,
    max_connections: usize,
) InitError!Server {
    if (!transport.available) return error.UnixSocketsUnavailable;

    // Clamped rather than rejected: a config value out of range should not
    // be the difference between "the agent socket is open" and "it is not",
    // and a user who wrote 0 meant something, but not "refuse everything".
    const slot_count = slotCount(max_connections);

    const owned = try alloc.dupe(u8, path);
    errdefer alloc.free(owned);

    const slots = try alloc.alloc(Slot, slot_count);
    errdefer alloc.free(slots);
    @memset(slots, .{});

    var listener = try transport.bind(alloc, io, owned);
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
        .slots = slots,
    };
}

pub fn deinit(self: *Server) void {
    self.stop();

    var it = self.tokens.iterator();
    while (it.next()) |kv| {
        self.alloc.free(kv.key_ptr.*);
        freeCaller(self.alloc, kv.value_ptr.*);
    }
    self.tokens.deinit(self.alloc);
    self.inflight.deinit(self.alloc);

    self.closeListener();
    transport.unlink(self.io, self.path);
    self.alloc.free(self.path);
    self.alloc.free(self.slots);
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
        // **Waking is not the same as closing, and only one platform can
        // treat it as such.** On POSIX closing the listener is what breaks
        // `accept`, and `wake` does exactly that. On Windows a close under
        // a pending accept is the very pattern that panics inside the
        // standard library, so `wake` knocks on the pipe as an ordinary
        // client instead and leaves the listener alive for `deinit`.
        // `wake_releases` says which of the two happened, so neither path
        // gives the listener back twice.
        self.listener.wake(self.io);
        if (transport.Listener.wake_releases) self.listener_closed = true;
        t.join();
        self.listen_thread = null;
    }

    // Answer everything still waiting, then close and join every
    // connection. Both are needed: answering releases a thread waiting for
    // an answer, and closing the socket releases one parked in read.
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
/// owned by the server and is freed by `revokeTokens` or `deinit`, so a
/// caller that needs to keep it must copy it first.
pub fn issueToken(self: *Server, id: Bus.Id) Allocator.Error![]const u8 {
    return self.mint(.{ .terminal = id });
}

/// Mint a token for a plugin, to be put in the hello line it is greeted
/// with.
///
/// The plugin gets the same socket, the same first line and the same
/// vocabulary an agent gets. That is the whole design: there is no
/// plugin-shaped tool surface to keep in step with the agent-shaped one,
/// because there is only one surface. What differs is what the *identity*
/// can do, and that is decided by `rpc.authorize`, not here.
///
/// `calls` is `wants.calls` from the manifest. It is copied, because the
/// arena it came from is thrown away and rebuilt whenever the plugin
/// directories are read -- which happens while plugins are running.
pub fn issuePluginToken(
    self: *Server,
    key: []const u8,
    calls: []const []const u8,
) Allocator.Error![]const u8 {
    const owned_key = try self.alloc.dupe(u8, key);
    errdefer self.alloc.free(owned_key);

    const owned_calls = try self.alloc.alloc([]const u8, calls.len);
    var made: usize = 0;
    errdefer {
        for (owned_calls[0..made]) |c| self.alloc.free(c);
        self.alloc.free(owned_calls);
    }
    for (calls, owned_calls) |src, *dst| {
        dst.* = try self.alloc.dupe(u8, src);
        made += 1;
    }

    return self.mint(.{ .plugin = .{ .key = owned_key, .calls = owned_calls } });
}

/// Forget a plugin's tokens, so a socket held open past the plugin's life
/// cannot go on acting as it.
pub fn revokePluginTokens(self: *Server, key: []const u8) void {
    self.tokens_mutex.lockUncancelable(self.io);
    defer self.tokens_mutex.unlock(self.io);

    var stale: std.ArrayListUnmanaged([]const u8) = .empty;
    defer stale.deinit(self.alloc);

    var it = self.tokens.iterator();
    while (it.next()) |kv| {
        const p = switch (kv.value_ptr.*) {
            .plugin => |p| p,
            .terminal => continue,
        };
        if (std.mem.eql(u8, p.key, key)) stale.append(self.alloc, kv.key_ptr.*) catch {};
    }

    for (stale.items) |k| {
        if (self.tokens.fetchRemove(k)) |kv| {
            self.alloc.free(kv.key);
            freeCaller(self.alloc, kv.value);
        }
    }
}

fn freeCaller(alloc: Allocator, caller: Bus.Caller) void {
    switch (caller) {
        .terminal => {},
        .plugin => |p| {
            alloc.free(p.key);
            for (p.calls) |c| alloc.free(c);
            alloc.free(p.calls);
        },
    }
}

/// The shared half of both token paths: fresh entropy, hex, and one entry
/// in the one map.
///
/// **`caller` is taken over.** Whatever it owns is freed by
/// `revokePluginTokens` or `deinit`, including on the failure path here --
/// a caller that hands over a heap-allocated identity must never write a
/// `defer` for it.
fn mint(self: *Server, caller: Bus.Caller) Allocator.Error![]const u8 {
    errdefer freeCaller(self.alloc, caller);
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
    try self.tokens.put(self.alloc, hex, caller);

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
        if (kv.value_ptr.isTerminal(id)) stale.append(self.alloc, kv.key_ptr.*) catch {};
    }

    for (stale.items) |k| {
        if (self.tokens.fetchRemove(k)) |kv| {
            self.alloc.free(kv.key);
            freeCaller(self.alloc, kv.value);
        }
    }
}

/// Which caller a token belongs to, if any.
///
/// A terminal or a plugin. What it will never be is a *claim*: the caller
/// does not say who it is, it holds a secret this process issued, and this
/// is where the secret is turned into an identity. A plugin therefore
/// cannot name a terminal, because there is nowhere in the protocol for it
/// to name one.
fn authenticate(self: *Server, token: []const u8) ?Bus.Caller {
    if (token.len != token_len) return null;

    self.tokens_mutex.lockUncancelable(self.io);
    defer self.tokens_mutex.unlock(self.io);

    // Constant time against every issued token. The threat here is small --
    // a local socket with owner-only permissions -- but comparing in
    // constant time costs nothing at this scale.
    var found: ?Bus.Caller = null;
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
            // # Why this writes a line before closing
            //
            // This used to be `log.warn` and a close, and `GHOSTTY_LOG` is
            // unset for almost everybody who will ever hit it -- so the
            // measured result was an agent CLI showing `CONNECTION_CLOSED`
            // and nothing anywhere saying why. It took reading this
            // constant out of the source to find out, and until then the
            // only visible fact was "every terminal opened from now on has
            // no tools".
            //
            // `cli/mcp.zig::complain` already made this argument for the
            // other refusal on this path -- *"a diagnostic that was written
            // and then thrown away costs more than none, because its author
            // believes the user has been told"* -- and fixed only its own
            // half. **This is the same path and the same lesson, one file
            // over, and this half did not get it.**
            //
            // The client cannot be told by any other means: it has no slot,
            // so it has no session to be answered in. One line on the socket
            // before it goes is the whole of the channel.
            self.refuseFull(stream);
            stream.close(self.io);

            // Said once while the slots stay full, and logged at most once a
            // minute with how many were turned away (task 1731). Every
            // short-lived client -- a hook event, a status line refresh --
            // connects afresh, so a full table turns away dozens a minute,
            // and a line for each filled a terminal and the log with the
            // same sentence.
            const said = self.full.refused(self.monotonicMs());
            if (said.log) |n| log.warn(
                "poltergeist: refusing an agent, all {d} slots are in use ({d} turned away since the last line)",
                .{ self.slots.len, n },
            );

            // The person who just started an agent is looking at a terminal
            // that quietly has no tools, and the line above goes to a log
            // almost nobody has turned on.
            if (said.alert) self.submit.callFull(self.slots.len);
            continue;
        };

        // A slot was free: whatever ran out before has ended, and running
        // out again is news again.
        if (self.full.room()) |n| log.info(
            "poltergeist: a slot is free again; {d} connection(s) were turned away while all were in use",
            .{n},
        );

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
    for (0..self.slots.len) |i| {
        self.slots_mutex.lockUncancelable(self.io);
        const done = self.slots[i].thread != null and
            self.slots[i].finished.load(.acquire);
        const thread = if (done) self.slots[i].thread else null;

        // Cleared before the join so nothing else can find the socket the
        // finishing thread has already closed.
        if (done) self.slots[i] = .{};
        self.slots_mutex.unlock(self.io);

        if (thread) |t| t.join();
    }
}

fn monotonicMs(self: *Server) i64 {
    return std.Io.Clock.Timestamp.now(self.io, .awake).raw.toMilliseconds();
}

/// What to do about a connection turned away because every slot is taken
/// (task 1731): tell the person once per time it fills, and log at most
/// once a minute with how many were turned away.
///
/// **Once per time it fills, not once a minute.** The person can do the
/// same thing about the first refusal as about the hundredth -- close a
/// terminal, raise the setting -- and the hundredth line hides everything
/// else in the terminal it lands in. It is said again only after a slot
/// has been free in between (`room`), which is a new time of running out.
pub const FullGate = struct {
    said: bool = false,
    /// Turned away since the last log line.
    unlogged: u64 = 0,
    /// Turned away since it last filled, for the line when it empties.
    since_full: u64 = 0,
    last_log_ms: ?i64 = null,

    pub const log_every_ms = 60 * 1000;

    pub const Verdict = struct {
        /// Tell the person: the first refusal since a slot was last free.
        alert: bool,
        /// Write the log line, with this many turned away since the last.
        log: ?u64,
    };

    pub fn refused(self: *FullGate, now_ms: i64) Verdict {
        self.unlogged += 1;
        self.since_full += 1;
        const alert = !self.said;
        self.said = true;
        const due = if (self.last_log_ms) |last| now_ms - last >= log_every_ms else true;
        if (!due) return .{ .alert = alert, .log = null };
        const n = self.unlogged;
        self.unlogged = 0;
        self.last_log_ms = now_ms;
        return .{ .alert = alert, .log = n };
    }

    /// A connection got a slot. How many were turned away while none was
    /// free, when any were; null when the slots had not filled.
    pub fn room(self: *FullGate) ?u64 {
        if (!self.said) return null;
        const n = self.since_full;
        self.* = .{};
        return n;
    }
};

fn claimSlot(self: *Server, stream: transport.Conn) ?usize {
    self.slots_mutex.lockUncancelable(self.io);
    defer self.slots_mutex.unlock(self.io);

    for (0..self.slots.len) |i| {
        if (self.slots[i].stream == null) {
            self.slots[i] = .{ .stream = stream };
            return i;
        }
    }
    return null;
}

/// Whether a terminal has an agent listening in it right now.
///
/// **A live connection, not a connection that once happened.** An agent's
/// sidecar connects when the agent CLI starts it and the connection lasts
/// as long as the agent does, so this goes false by itself when the agent
/// exits -- there is no mark for anybody to remember to clear, and a shell
/// left behind in that terminal cannot inherit one.
///
/// **What it is evidence of.** A bare shell has no way to be here: reaching
/// this requires having connected to the socket and passed the handshake
/// with the token issued to that surface. It is the one signal about who is
/// on the other end that the other end cannot fake. The alternatives were
/// checked and each fails: the bus registers a terminal on a *keypress*, so
/// an entry proves nothing; every surface gets the socket and token in its
/// environment, shells included; and bracketed-paste mode is a mode a shell
/// may well set.
///
/// ⚠️ **There is a window.** An agent whose sidecar has not finished its
/// handshake answers false, and looks exactly like a bare shell. Whoever
/// acts on a false has to say so -- see the wording in `rpc.zig`.
pub fn agentPresent(self: *Server, id: Bus.Id) bool {
    self.slots_mutex.lockUncancelable(self.io);
    defer self.slots_mutex.unlock(self.io);

    for (0..self.slots.len) |i| {
        // A plugin connection carries no surface, so there is nothing here
        // it could be mistaken for.
        const caller = self.slots[i].caller orelse continue;
        // A connection that only waits to be told things may outlive its
        // client by a whole wait (`Kind`).
        if (self.slots[i].listens) continue;
        switch (caller) {
            .terminal => |tid| if (tid == id) return true,
            .plugin => {},
        }
    }
    return false;
}

/// Which time an agent has been connected from terminal `id`: a number
/// that stays the same for as long as an agent's connection is open there,
/// and is a new one when an agent connects to a terminal none is connected
/// from (task 1829). 0 when none is connected.
///
/// **What tells one agent from the next when nothing else does.** An agent
/// the bus does not watch -- one refused a project's supervisor's pane --
/// leaves no `left` behind when it exits, and a CLI resumed into the same
/// session says the same session id: the next agent there read exactly like
/// the one before, and was never judged (`Projects.SeatJudged`). An agent
/// holds the connection its tool calls use from start to exit; one that
/// listens, or a hook saying one thing, is not counted, as in `agentPresent`.
pub fn agentRound(self: *Server, id: Bus.Id) u64 {
    self.slots_mutex.lockUncancelable(self.io);
    defer self.slots_mutex.unlock(self.io);
    return self.liveRound(id);
}

/// `agentRound`'s answer, under `slots_mutex`.
fn liveRound(self: *const Server, id: Bus.Id) u64 {
    for (self.slots) |s| {
        if (s.round == 0) continue;
        const caller = s.caller orelse continue;
        switch (caller) {
            .terminal => |tid| if (tid == id) return s.round,
            .plugin => {},
        }
    }
    return 0;
}

/// The round for an agent's connection from `id` just made, under
/// `slots_mutex`: the one already open there, or a new one.
fn roundFor(self: *Server, id: Bus.Id) u64 {
    const open = self.liveRound(id);
    if (open != 0) return open;
    self.rounds += 1;
    return self.rounds;
}

fn releaseSlot(self: *Server, index: usize) void {
    self.slots_mutex.lockUncancelable(self.io);
    defer self.slots_mutex.unlock(self.io);
    self.slots[index] = .{};
}

/// Wake every live connection and join its thread.
///
/// `shutdown`, not `close`. Shutting a socket down unblocks a thread parked
/// in read without invalidating the descriptor, so a thread that was also
/// about to write its answer gets an ordinary error instead of using a
/// closed descriptor. Each thread closes its own socket on the way out.
fn stopConnections(self: *Server) void {
    // Sized to the hard limit rather than to `self.slots.len`, and left on
    // the stack: this runs on the shutdown path, where an allocation that
    // fails would leave threads unjoined and the server freed under them.
    var threads: [limit_max_connections]?std.Thread = @splat(null);

    // **The shutdown happens under the lock, and that is deliberate.**
    // `connectionMain` clears its slot under this same lock *before* it
    // closes the handle, so anything found here while holding it is still
    // open. Moving the wake outside the lock -- which looks like the
    // ordinary "no syscalls under a mutex" tidy-up, and which I did once --
    // reintroduces exactly the use-after-close this lock exists to prevent.
    // The join below is outside it because a join is not touching a handle.
    self.slots_mutex.lockUncancelable(self.io);
    for (0..self.slots.len) |i| {
        if (self.slots[i].stream) |stream| transport.shutdownConn(stream, self.io);
        threads[i] = self.slots[i].thread;
    }
    self.slots_mutex.unlock(self.io);

    for (threads) |t| if (t) |thread| thread.join();

    // Only now that every thread has finished is it safe to forget them.
    self.slots_mutex.lockUncancelable(self.io);
    for (0..self.slots.len) |i| self.slots[i] = .{};
    self.slots_mutex.unlock(self.io);
}

fn connectionMain(self: *Server, index: usize) void {
    // This thread owns the socket and closes it, so no other thread can
    // close a descriptor while this one is still writing to it. Shutdown
    // only wakes it; the close happens here.
    const stream = stream: {
        self.slots_mutex.lockUncancelable(self.io);
        defer self.slots_mutex.unlock(self.io);
        break :stream self.slots[index].stream orelse return;
    };

    defer {
        // Take the socket out of the slot before closing it, under the same
        // lock shutdown uses. After this nobody else can find the
        // descriptor, so nobody can act on one this thread has closed.
        self.slots_mutex.lockUncancelable(self.io);
        // Whether this was an agent `agentPresent` counted, for the
        // `agent_gone` call below.
        const was_agent = !self.slots[index].listens and
            if (self.slots[index].caller) |c| c == .terminal else false;
        // The moment `agentPresent` stops counting it (#1534): set against
        // the moment the agent was seen to exit, this is how long a bare
        // shell was still answered as an agent.
        if (self.slots[index].caller) |c| switch (c) {
            .terminal => |tid| log.info("poltergeist: connection slot={d} for terminal={x} closed, listens={}", .{
                index, tid, self.slots[index].listens,
            }),
            .plugin => {},
        };
        self.slots[index].stream = null;
        // Same moment, same lock: the connection is over, so it no longer
        // speaks for anybody.
        self.slots[index].caller = null;
        self.slots[index].listens = false;
        self.slots[index].round = 0;
        self.slots[index].sighting_len = 0;
        self.slots_mutex.unlock(self.io);
        // Outside the lock: the host's answer is to wake its own thread,
        // which asks `agentPresent`, which takes this lock.
        if (was_agent) self.submit.callAgentGone();

        stream.close(self.io);
        self.slots[index].finished.store(true, .release);
    }

    var read_buf: [max_request_bytes]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(self.io, &read_buf);
    var writer = stream.writer(self.io, &write_buf);

    // A connection says who it is once, before anything else.
    const shook = self.handshake(&reader, &writer) orelse return;
    const caller = shook.caller;

    // Recorded, not just held: `agentPresent` is answered off this.
    {
        self.slots_mutex.lockUncancelable(self.io);
        defer self.slots_mutex.unlock(self.io);
        self.slots[index].round = if (shook.kind.listens()) 0 else switch (caller) {
            .terminal => |tid| self.roundFor(tid),
            .plugin => 0,
        };
        self.slots[index].caller = caller;
        self.slots[index].listens = shook.kind.listens();
        self.slots[index].sighting_len = shook.sighting_len;
        @memcpy(self.slots[index].sighting[0..shook.sighting_len], shook.sighting[0..shook.sighting_len]);
    }
    switch (caller) {
        .terminal => |tid| log.info("poltergeist: connection slot={d} for terminal={x} kind={t}", .{
            index, tid, shook.kind,
        }),
        .plugin => {},
    }

    // Who connected, read once: what lets a request's wait tell a client
    // that has gone from one that only stopped sending (`awaitAnswer`).
    const peer = transport.peerOf(stream);

    while (self.running.load(.acquire)) {
        // `takeDelimiter`, not `takeDelimiterExclusive`: the latter leaves
        // the newline in the buffer, so every call after the first returns
        // an empty slice without advancing and this loop spins forever.
        const line = (reader.interface.takeDelimiter('\n') catch return) orelse return;
        if (line.len == 0) continue;
        self.serveOne(stream, peer, &writer, caller, line) catch return;
    }
}

/// Read the opening line and check its token.
fn handshake(
    self: *Server,
    reader: *transport.Reader,
    writer: *transport.Writer,
) ?Shook {
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
    var shook: Shook = .{ .caller = caller, .kind = parseAuthKind(self.alloc, line) };
    shook.sighting_len = parseAuthSighting(self.alloc, line, &shook.sighting);
    return shook;
}

const Shook = struct {
    caller: Bus.Caller,
    kind: Kind,
    sighting: [max_sighting]u8 = undefined,
    sighting_len: u16 = 0,
};

/// `params.identity` of an `auth` request -- `{"pid":N,"env":{name:value}}`,
/// what a sidecar says of the program that started it (task 1635) --
/// checked and written back compactly into `out`. Returns how much was
/// written; 0 when there was none, or when any part of it is not what a
/// sidecar sends: a name that is not `[A-Z0-9_]`, a value that is not short
/// printable ASCII, too many of them. **All or nothing**, and never logged:
/// the values are only for the adapters that asked for them.
fn parseAuthSighting(alloc: Allocator, line: []const u8, out: *[max_sighting]u8) u16 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch return 0;
    const params = switch (v) {
        .object => |o| switch (o.get("params") orelse return 0) {
            .object => |p| p,
            else => return 0,
        },
        else => return 0,
    };
    const identity = switch (params.get("identity") orelse return 0) {
        .object => |o| o,
        else => return 0,
    };
    var w: std.Io.Writer = .fixed(out);
    w.writeAll("{\"pid\":") catch return 0;
    switch (identity.get("pid") orelse .null) {
        .integer => |pid| if (pid > 0) w.print("{d}", .{pid}) catch return 0 else w.writeAll("null") catch return 0,
        else => w.writeAll("null") catch return 0,
    }
    // The sidecar's own pid (task 1667): when it started is what tells two
    // sessions of one CLI in one directory apart.
    w.writeAll(",\"self\":") catch return 0;
    switch (identity.get("self") orelse .null) {
        .integer => |pid| if (pid > 0) w.print("{d}", .{pid}) catch return 0 else w.writeAll("null") catch return 0,
        else => w.writeAll("null") catch return 0,
    }
    w.writeAll(",\"env\":{") catch return 0;
    if (identity.get("env")) |ev| {
        const env = switch (ev) {
            .object => |o| o,
            else => return 0,
        };
        if (env.count() > max_sighting_env) return 0;
        var it = env.iterator();
        var first = true;
        while (it.next()) |kv| {
            const value = switch (kv.value_ptr.*) {
                .string => |sv| sv,
                else => return 0,
            };
            if (!Plugin.AgentCli.validEnvName(kv.key_ptr.*) or !agent_cli.Sighting.validValue(value)) return 0;
            if (!first) w.writeAll(",") catch return 0;
            first = false;
            w.print("\"{s}\":\"{s}\"", .{ kv.key_ptr.*, value }) catch return 0;
        }
    }
    w.writeAll("}}") catch return 0;
    return @intCast(w.end);
}

/// What the agent connection from terminal `id` said about the program that
/// started it, in `arena`; `Sighting.none` when it said nothing or none is
/// connected.
pub fn sightingOf(self: *Server, arena: Allocator, id: Bus.Id) Allocator.Error!agent_cli.Sighting {
    var copy: [max_sighting]u8 = undefined;
    const len = len: {
        self.slots_mutex.lockUncancelable(self.io);
        defer self.slots_mutex.unlock(self.io);
        for (self.slots) |*slot| {
            const caller = slot.caller orelse continue;
            if (slot.listens) continue;
            switch (caller) {
                .terminal => |tid| if (tid == id and slot.sighting_len > 0) {
                    @memcpy(copy[0..slot.sighting_len], slot.sighting[0..slot.sighting_len]);
                    break :len slot.sighting_len;
                },
                .plugin => {},
            }
        }
        return .none;
    };
    return parseSighting(arena, copy[0..len]);
}

/// The program the agent connected from in this terminal said it was --
/// its sidecar's parent -- or null when no agent is connected there or it
/// said nothing (task 1668). Allocates nothing: asked on every heartbeat.
pub fn agentPid(self: *Server, id: Bus.Id) ?u64 {
    var buf: [4 * max_sighting]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const s = self.sightingOf(fba.allocator(), id) catch return null;
    return s.pid;
}

/// Read back what `parseAuthSighting` wrote.
fn parseSighting(arena: Allocator, text: []const u8) Allocator.Error!agent_cli.Sighting {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, try arena.dupe(u8, text), .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .none,
    };
    const obj = switch (v) {
        .object => |o| o,
        else => return .none,
    };
    const pid: ?u64 = switch (obj.get("pid") orelse .null) {
        .integer => |p| if (p > 0) @intCast(p) else null,
        else => null,
    };
    const self_pid: ?u64 = switch (obj.get("self") orelse .null) {
        .integer => |p| if (p > 0) @intCast(p) else null,
        else => null,
    };
    var env: std.ArrayList([2][]const u8) = .empty;
    if (obj.get("env")) |ev| if (ev == .object) {
        var it = ev.object.iterator();
        while (it.next()) |kv| if (kv.value_ptr.* == .string) {
            try env.append(arena, .{ kv.key_ptr.*, kv.value_ptr.string });
        };
    };
    return .{ .pid = pid, .sidecar = self_pid, .env = try env.toOwnedSlice(arena) };
}

/// `params.kind` of an `auth` request, read the way `Kind` says: absent,
/// not a string, or not a word this build knows, it is an agent.
fn parseAuthKind(alloc: Allocator, line: []const u8) Kind {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch return .agent;
    const obj = switch (v) {
        .object => |o| o,
        else => return .agent,
    };
    const params = switch (obj.get("params") orelse return .agent) {
        .object => |o| o,
        else => return .agent,
    };
    const word = switch (params.get("kind") orelse return .agent) {
        .string => |s| s,
        else => return .agent,
    };
    return std.meta.stringToEnum(Kind, word) orelse .agent;
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
    stream: transport.Conn,
    peer: ?transport.Peer,
    writer: *transport.Writer,
    caller: Bus.Caller,
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
    const gone = struct {
        conn: transport.Conn,
        peer: ?transport.Peer,
        pub fn ask(g: @This()) bool {
            return transport.peerGone(g.conn, g.peer);
        }
    }{ .conn = stream, .peer = peer };
    if (awaitAnswer(self.io, pending, peer_check_ms, gone) == .peer_gone) {
        switch (caller) {
            .terminal => |tid| log.info("poltergeist: terminal={x} went away while its request was unanswered; its slot is let go", .{tid}),
            .plugin => |pl| log.info("poltergeist: plugin {s} went away while its request was unanswered; its slot is let go", .{pl.key}),
        }
    }
    self.untrackInflight(pending);

    const response = pending.response orelse {
        self.refuse(writer, "NoResponse", "the terminal produced no answer");
        return;
    };

    try wire.writeResponse(&writer.interface, response);
    try writer.interface.flush();
}

/// How often a thread waiting for the app's answer looks to see whether its
/// client is still there. A second: nothing it answers is in a hurry once
/// the client has gone, and a client that is still there is never kept
/// waiting by it -- the answer wakes the wait at once.
const peer_check_ms = 1000;

/// How a wait for the app's answer ended.
const Waited = enum { answered, peer_gone };

/// Wait for `pending` to be answered, looking every `interval_ms` to see
/// whether the client is still there (task 1727).
///
/// **Before this the wait had no end but the answer**, and an app that
/// never answered held the connection's slot for good: on the person's own
/// Polter all 64 were found held, about half by clients long gone (#1685).
/// A client that has gone is answered here instead -- `complete` with
/// `PeerGone`, the same early answer `Server.stop` gives -- which ends the
/// wait and so lets the slot go; the app's answer, when it comes, finds the
/// request settled and changes nothing (`complete` counts once).
///
/// **A client that is there is never cut short, however long the app
/// takes**: some answers are meant to be slow (`persona_wait`, a
/// screenshot, `task_assign`), and what decides is the client, never the
/// clock. `gone.ask()` is `transport.peerGone`, which says yes only when it
/// is sure.
fn awaitAnswer(io: std.Io, pending: *Pending, interval_ms: i64, gone: anytype) Waited {
    var cut = false;
    while (true) {
        pending.done.waitTimeout(io, .{ .duration = .{
            .raw = .fromMilliseconds(interval_ms),
            .clock = .awake,
        } }) catch {
            // Timed out, woken for nothing, or asked to cancel: none of
            // them is an answer. Look at the client, and wait again -- if
            // it has gone, answer it here, which sets `done` and so ends
            // the next wait at once. Whether this answer is the one that
            // counted is `settle`'s to say: the app may have answered in
            // between.
            if (gone.ask() and pending.settle(io, .{ .failed = .{
                .code = "PeerGone",
                .message = "the client went away before the answer came",
            } })) cut = true;
            continue;
        };
        return if (cut) .peer_gone else .answered;
    }
}

fn refuse(
    self: *Server,
    writer: *transport.Writer,
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

/// Say why, on a connection that will never get a slot.
///
/// **`refuse` needs a `transport.Writer`, and the accept loop only has the
/// raw stream** -- which is why this path skipped it and closed in silence
/// for as long as it existed. The buffer is a local because the connection
/// is over the moment this returns: nothing on the other side is going to
/// send anything else, and nothing here is going to read it.
///
/// The code is what the client matches on, so it is a fixed string and not
/// a sentence. The sentence is in `cli/mcp.zig`, where it can be written for
/// somebody who is not reading this file.
fn refuseFull(self: *Server, stream: transport.Conn) void {
    var buf: [512]u8 = undefined;
    var writer = stream.writer(self.io, &buf);
    self.refuse(
        &writer,
        full_refusal_code,
        "every agent slot on this socket is in use",
    );
}

/// What `+mcp` matches on to know it was turned away for this reason and
/// not another. Changing it changes a protocol, so both ends are named
/// here: `cli/mcp.zig` reads it, `a-refusal-says-which-one.py` holds them
/// together.
pub const full_refusal_code = "AgentsFull";

/// Where this process's socket lives.
///
/// The name carries random bytes rather than the pid. It is one fewer thing
/// leaked into a path other processes can list, and two Ghostty processes
/// -- or one restarted after a crash that left its socket behind -- cannot
/// collide.
/// The names this sweep will consider. `defaultPath` writes them, and
/// nothing else in the state directory looks like this.
const socket_prefix = "polter-";
const socket_suffix = ".sock";

fn isSocketName(name: []const u8) bool {
    return name.len > socket_prefix.len + socket_suffix.len and
        std.mem.startsWith(u8, name, socket_prefix) and
        std.mem.endsWith(u8, name, socket_suffix);
}

/// What a probe of a socket path found.
const Liveness = enum {
    /// The kernel refused the connection: the file is a socket and there is
    /// no listener behind it. This is the only answer that permits deleting.
    dead,

    /// Someone answered, or the answer was not one we understand. Either
    /// way the file stays.
    keep,
};

/// Ask the kernel whether anything is listening on `path`.
///
/// The judgement has to be "nobody answers", never "the file is old". A
/// running Polter's socket is an ordinary zero-byte file with an ordinary
/// mtime, indistinguishable on disk from a socket left by a process that
/// died in August. The only thing that tells them apart is connecting.
///
/// The default is to keep. Deleting a live instance's socket would cut
/// every agent it hosts off from the app mid-sentence, while keeping a dead
/// file costs nothing but a line in a directory listing -- so anything we
/// do not positively understand counts as alive.
///
/// This connects and immediately closes, which a live server sees as a
/// client that hung up before the handshake: `handshake` reads no line,
/// returns null, and the connection thread exits without logging or
/// answering. No request is submitted and nothing is left held.
fn probe(path: []const u8) Liveness {
    // Windows has unix sockets but not this syscall surface. It has also
    // never accumulated the sockets this sweep exists to remove, since a
    // socket file there is not left behind the same way.
    if (builtin.os.tag == .windows) return .keep;
    if (!net.has_unix_sockets) return .keep;

    var addr: posix.sockaddr.un = std.mem.zeroes(posix.sockaddr.un);
    addr.family = posix.AF.UNIX;

    // No room for the path and its terminator means this cannot be an
    // address anyone bound, so there is nothing to ask about.
    if (path.len + 1 > addr.path.len) return .keep;
    @memcpy(addr.path[0..path.len], path);
    const addr_len: posix.socklen_t =
        @intCast(@offsetOf(posix.sockaddr.un, "path") + path.len + 1);

    const fd = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (posix.errno(fd) != .SUCCESS) return .keep;
    const sock: posix.socket_t = @intCast(fd);
    defer _ = posix.system.close(sock);

    while (true) {
        const rc = posix.system.connect(sock, @ptrCast(&addr), addr_len);
        switch (posix.errno(rc)) {
            .SUCCESS => return .keep,
            .INTR => continue,

            // Nobody is behind the path. Note `NOENT` is not in this list:
            // the file went away between the listing and the probe, so
            // there is nothing left to delete and no reason to try.
            .CONNREFUSED => return .dead,

            // Everything else -- a permission error, a socket type we did
            // not expect, an errno this platform spells differently -- is
            // an answer we cannot read, and an unreadable answer is not
            // evidence that the far end is gone.
            else => return .keep,
        }
    }
}

/// Remove the sockets in `dir_path` that nothing is listening on.
///
/// Run once at startup, before this process binds its own path. A socket
/// file does not disappear when the process that bound it dies, so a
/// machine that has run Polter a few dozen times accumulates a few dozen
/// of them, and the state directory stops being somewhere a person can
/// find `chat/` or `session.json`.
///
/// Failures are logged and skipped rather than reported: a state directory
/// that could not be tidied is not a reason to refuse to open the socket.
pub fn sweepStale(alloc: Allocator, io: std.Io, dir_path: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        log.debug("poltergeist: no state directory to sweep err={}", .{err});
        return;
    };
    defer dir.close(io);

    // Names are collected first and deleted after. Removing entries while
    // the directory cursor is still walking them is not defined to be
    // safe, and the cost of being wrong is skipping a name -- which here
    // would mean skipping the live one's neighbours, silently.
    var stale: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (stale.items) |name| alloc.free(name);
        stale.deinit(alloc);
    }

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!isSocketName(entry.name)) continue;

        // `readdir` can report `unknown` on some filesystems, so confirm
        // with a stat. Symlinks are not followed: a link that happens to
        // point at a live socket is still not a file we put here.
        const kind = if (entry.kind != .unknown) entry.kind else k: {
            const st = dir.statFile(io, entry.name, .{
                .follow_symlinks = false,
            }) catch continue;
            break :k st.kind;
        };
        if (kind != .unix_domain_socket) continue;

        var buf: [net.UnixAddress.max_len]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{
            dir_path,
            entry.name,
        }) catch continue;
        if (probe(full) != .dead) continue;

        const owned = alloc.dupe(u8, entry.name) catch continue;
        stale.append(alloc, owned) catch {
            alloc.free(owned);
            continue;
        };
    }

    for (stale.items) |name| {
        dir.deleteFile(io, name) catch |err| {
            log.warn("poltergeist: could not remove a dead socket name={s} err={}", .{ name, err });
            continue;
        };
        log.info("poltergeist: removed a dead socket name={s}", .{name});
    }
}

pub fn defaultPath(alloc: Allocator, io: std.Io, state_dir: []const u8) Allocator.Error![]u8 {
    return transport.defaultName(alloc, io, state_dir);
}

/// Connect to a server, for the clients that are not this process.
pub fn connect(io: std.Io, path: []const u8) !transport.Conn {
    return transport.connect(io, path);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    // Zig only analyses what is referenced, and almost everything here is
    // reached from a thread rather than from a test. Without this the
    // socket and threading code would never be type-checked at all.
    testing.refAllDecls(@This());
}

test "Server sighting: only plain names and short printable values come through, all or nothing (task 1635)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [max_sighting]u8 = undefined;

    const good =
        \\{"method":"auth","params":{"token":"t","identity":{"pid":77,"env":{"CLAUDECODE":"1","CLAUDE_CODE_SESSION_ID":"0b1d1c35-5e33-4b5e-9f8c-1a2b3c4d5e6f"}}}}
    ;
    const n = parseAuthSighting(testing.allocator, good, &buf);
    try testing.expect(n > 0);
    const s = try parseSighting(arena.allocator(), buf[0..n]);
    try testing.expectEqual(@as(?u64, 77), s.pid);
    try testing.expectEqualStrings("1", s.get("CLAUDECODE").?);
    try testing.expectEqualStrings("0b1d1c35-5e33-4b5e-9f8c-1a2b3c4d5e6f", s.get("CLAUDE_CODE_SESSION_ID").?);

    for ([_][]const u8{
        // None.
        \\{"method":"auth","params":{"token":"t"}}
        ,
        // A name that is not one.
        \\{"method":"auth","params":{"token":"t","identity":{"pid":1,"env":{"path":"x"}}}}
        ,
        // A value with a control character, or a quote.
        \\{"method":"auth","params":{"token":"t","identity":{"pid":1,"env":{"A":"x\ny"}}}}
        ,
        \\{"method":"auth","params":{"token":"t","identity":{"pid":1,"env":{"A":"x\"y"}}}}
        ,
        // Not text.
        \\{"method":"auth","params":{"token":"t","identity":{"pid":1,"env":{"A":3}}}}
        ,
    }) |line| try testing.expectEqual(@as(u16, 0), parseAuthSighting(testing.allocator, line, &buf));
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

    // **The test was wrong here, not the product.** It asserted a Unix
    // socket path on every system, and on Windows `defaultName` ignores the
    // directory it is handed and answers `\\.\pipe\polter-<hex>`. That is
    // deliberate and is written down next to it: a pipe name lives in a
    // kernel namespace, so there is no directory for it to be in and nothing
    // to unlink afterwards.
    //
    // The shapes are asserted separately rather than dropped, because on
    // each system the shape is a real property -- "it is in the directory it
    // was given" is what stops two Ghostty users colliding on POSIX, and it
    // is not a claim that can even be made on Windows. **Both arms run**;
    // this is not a guard that skips one platform and quietly never retires.
    switch (builtin.os.tag) {
        .windows => try testing.expect(std.mem.startsWith(u8, a, "\\\\.\\pipe\\polter-")),
        else => {
            try testing.expect(std.mem.startsWith(u8, a, "/run/user/1000/ghostty/polter-"));
            try testing.expect(std.mem.endsWith(u8, a, ".sock"));
        },
    }

    // The one thing both systems owe, and the thing the test is named for.
    try testing.expect(!std.mem.eql(u8, a, b));
}

// Task 1727: a request's wait lets the slot go when its client has gone,
// and only then. A real unix socket and a real child process on the other
// end, so `peerOf` and `peerGone` are the system's answers and not a
// stand-in's.
const PeerTest = struct {
    const Mode = enum {
        /// Send the request and exit when told: the client has gone.
        exits,
        /// Send the request and exit at once, before its connection is
        /// looked at.
        exits_at_once,
        /// Send the request, shut down the writing half as macOS's
        /// `nc -U` does when its input ends, and wait for the answer.
        half_closes,
        /// Send the request and wait for the answer, connection open.
        waits,
    };

    listener: transport.Listener,
    path: [:0]const u8,
    conn: transport.Conn,
    child: std.c.pid_t,
    /// The answer the child read, sent back over this pipe.
    from_child: std.c.fd_t,
    /// Closed to let an `.exits` child go: it is alive when its connection
    /// is looked at, as a client that dies later is.
    to_child: std.c.fd_t,

    fn start(alloc: Allocator, io: std.Io, mode: Mode) !PeerTest {
        var raw: [4]u8 = undefined;
        io.random(&raw);
        const path = try std.fmt.allocPrintSentinel(alloc, "/tmp/p1727-{x}.sock", .{&raw}, 0);
        errdefer alloc.free(path);
        var listener = try transport.bind(alloc, io, path);
        errdefer listener.deinit(io);

        // Everything the child needs is made before the fork: after it the
        // child may only make system calls.
        var addr: std.c.sockaddr.un = .{ .family = std.c.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..path.len], path);
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.Pipe;
        var go: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&go) != 0) return error.Pipe;

        const pid = std.c.fork();
        if (pid == 0) {
            _ = std.c.close(fds[0]);
            _ = std.c.close(go[1]);
            const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
            if (fd < 0) std.c._exit(2);
            if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un)) != 0) std.c._exit(3);
            const req = "{\"method\":\"me\"}\n";
            _ = std.c.write(fd, req, req.len);
            switch (mode) {
                .exits_at_once => std.c._exit(0),
                .exits => {
                    var b: [1]u8 = undefined;
                    _ = std.c.read(go[0], &b, 1);
                    std.c._exit(0);
                },
                .half_closes => _ = std.c.shutdown(fd, std.c.SHUT.WR),
                .waits => {},
            }
            var buf: [256]u8 = undefined;
            var got: usize = 0;
            while (got < buf.len) {
                const n = std.c.read(fd, buf[got..].ptr, buf.len - got);
                if (n <= 0) break;
                got += @intCast(n);
                if (std.mem.indexOfScalar(u8, buf[0..got], '\n') != null) break;
            }
            _ = std.c.write(fds[1], &buf, got);
            std.c._exit(0);
        }
        _ = std.c.close(fds[1]);
        _ = std.c.close(go[0]);
        if (pid < 0) return error.Fork;

        const conn = try listener.accept(io);
        // The request, read off the socket as the connection loop would:
        // what is left to peek at is whatever comes after it.
        var line: [64]u8 = undefined;
        var got: usize = 0;
        while (std.mem.indexOfScalar(u8, line[0..got], '\n') == null) {
            const n = std.c.recv(conn.socket.handle, line[got..].ptr, line.len - got, 0);
            if (n <= 0) return error.NoRequest;
            got += @intCast(n);
        }
        return .{ .listener = listener, .path = path, .conn = conn, .child = pid, .from_child = fds[0], .to_child = go[1] };
    }

    fn stop(t: *PeerTest, alloc: Allocator, io: std.Io) void {
        t.conn.close(io);
        t.listener.deinit(io);
        transport.unlink(io, t.path);
        alloc.free(t.path);
        _ = std.c.close(t.from_child);
        if (t.to_child >= 0) _ = std.c.close(t.to_child);
        // Never `waitpid(-1)`: that would wait for any child of the test
        // process at all.
        if (t.child > 0) _ = std.c.waitpid(t.child, null, 0);
    }

    fn gone(t: *const PeerTest, peer: ?transport.Peer, io: std.Io, p: *Pending, asks: *usize) Gone {
        return .{ .conn = t.conn, .peer = peer, .io = io, .pending = p, .asks = asks };
    }

    /// `transport.peerGone`, and a limit: a wait that has looked 200 times
    /// (about four seconds at 20 ms) is ended by the test itself, with an
    /// answer no assertion accepts -- so a wait that would never end is a
    /// red test and not a hung one.
    const Gone = struct {
        conn: transport.Conn,
        peer: ?transport.Peer,
        io: std.Io,
        pending: *Pending,
        asks: *usize,
        pub fn ask(g: @This()) bool {
            g.asks.* += 1;
            if (g.asks.* > 200) {
                _ = g.pending.settle(g.io, .{ .failed = .{ .code = "TestGaveUp", .message = "waited too long" } });
                return false;
            }
            return transport.peerGone(g.conn, g.peer);
        }
    };

    fn newPending(alloc: Allocator) !*Pending {
        const p = try alloc.create(Pending);
        p.* = .{ .alloc = alloc, .caller = .{ .terminal = 1 }, .request = undefined, .arena = .init(alloc) };
        return p;
    }

    /// The app's side: answer after `ms`, once, and drop its reference.
    fn answerLater(io: std.Io, p: *Pending, ms: i64, counted: *std.atomic.Value(bool)) void {
        std.Io.sleep(io, .fromMilliseconds(ms), .awake) catch {};
        counted.store(p.settle(io, .{ .failed = .{ .code = "FromApp", .message = "the app's answer" } }), .release);
        p.release();
    }

    /// Run `awaitAnswer` on a thread of its own and give it `limit_ms`:
    /// null when it had not returned by then. A wait that never ends is then
    /// a red assertion, not a hung test -- it is ended here, with an answer
    /// no assertion accepts, so its thread can be joined.
    fn waitAtMost(io: std.Io, p: *Pending, looks: Gone, limit_ms: i64) ?Waited {
        // 0 while it waits; then 1 + the `Waited` it returned.
        const Run = struct {
            fn main(i: std.Io, pend: *Pending, g: Gone, out: *std.atomic.Value(u8)) void {
                out.store(1 + @as(u8, @intFromEnum(awaitAnswer(i, pend, 20, g))), .release);
            }
        };
        var out: std.atomic.Value(u8) = .init(0);
        const t = std.Thread.spawn(.{}, Run.main, .{ io, p, looks, &out }) catch return null;
        var waited_ms: i64 = 0;
        while (out.load(.acquire) == 0 and waited_ms < limit_ms) : (waited_ms += 10) {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
        }
        const ended = out.load(.acquire) != 0;
        if (!ended) _ = p.settle(io, .{ .failed = .{ .code = "TestGaveUp", .message = "the wait did not end" } });
        t.join();
        return if (ended) @enumFromInt(out.load(.acquire) - 1) else null;
    }

    fn appAnswer(p: *const Pending) ?[]const u8 {
        const r = p.response orelse return null;
        return switch (r) {
            .failed => |f| f.code,
            else => null,
        };
    }
};

test "1727: a client that has exited lets its slot go, and its request is answered once" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try PeerTest.start(alloc, io, .exits);
    defer t.stop(alloc, io);
    const peer = transport.peerOf(t.conn);
    try testing.expect(peer.? == .process and peer.?.process.started != null);
    // Now it exits, and is collected: gone from the process table.
    _ = std.c.close(t.to_child);
    t.to_child = -1;
    _ = std.c.waitpid(t.child, null, 0);
    t.child = -1;

    const p = try PeerTest.newPending(alloc);
    defer p.release();
    p.retain();
    var asks: usize = 0; // the app's, which never answers until after

    // Its client has gone: the wait must end, and soon. Five seconds is
    // two hundred and fifty looks at 20 ms.
    const waited = PeerTest.waitAtMost(io, p, t.gone(peer, io, p, &asks), 5000);
    try testing.expectEqual(@as(?Waited, .peer_gone), waited);
    try testing.expectEqualStrings("PeerGone", PeerTest.appAnswer(p).?);

    // The app answers late: it does not count, and changes nothing.
    try testing.expect(!p.settle(io, .{ .failed = .{ .code = "FromApp", .message = "late" } }));
    try testing.expectEqualStrings("PeerGone", PeerTest.appAnswer(p).?);
    p.release();
}

test "1727: a client that only shut down its writing half is waited for, and gets the answer" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try PeerTest.start(alloc, io, .half_closes);
    defer t.stop(alloc, io);
    const peer = transport.peerOf(t.conn);

    const p = try PeerTest.newPending(alloc);
    defer p.release();
    p.retain();
    var asks: usize = 0;
    var counted: std.atomic.Value(bool) = .init(false);
    // Long enough for the wait to look at a client whose read side has
    // ended, several times over.
    const app = try std.Thread.spawn(.{}, PeerTest.answerLater, .{ io, p, 200, &counted });
    const waited = awaitAnswer(io, p, 20, t.gone(peer, io, p, &asks));
    app.join();
    try testing.expectEqual(Waited.answered, waited);
    try testing.expect(counted.load(.acquire));
    try testing.expectEqualStrings("FromApp", PeerTest.appAnswer(p).?);

    // And it still reaches the client.
    const reply = "{\"ok\":true}\n";
    try testing.expectEqual(@as(isize, reply.len), std.c.write(t.conn.socket.handle, reply, reply.len));
    var buf: [64]u8 = undefined;
    const n = std.c.read(t.from_child, &buf, buf.len);
    try testing.expectEqualStrings(reply, buf[0..@intCast(@max(n, 0))]);
}

test "1727: a client that is still there is not cut short by a slow answer" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try PeerTest.start(alloc, io, .waits);
    defer t.stop(alloc, io);
    const peer = transport.peerOf(t.conn);

    const p = try PeerTest.newPending(alloc);
    defer p.release();
    p.retain();
    var asks: usize = 0;
    var counted: std.atomic.Value(bool) = .init(false);
    const app = try std.Thread.spawn(.{}, PeerTest.answerLater, .{ io, p, 200, &counted });
    const waited = awaitAnswer(io, p, 20, t.gone(peer, io, p, &asks));
    app.join();
    try testing.expectEqual(Waited.answered, waited);
    try testing.expect(counted.load(.acquire));
    try testing.expectEqualStrings("FromApp", PeerTest.appAnswer(p).?);

    const reply = "{\"ok\":true}\n";
    _ = std.c.write(t.conn.socket.handle, reply, reply.len);
    var buf: [64]u8 = undefined;
    const n = std.c.read(t.from_child, &buf, buf.len);
    try testing.expectEqualStrings(reply, buf[0..@intCast(@max(n, 0))]);
}

test "1727: a client that exited before its connection was looked at is gone too" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try PeerTest.start(alloc, io, .exits_at_once);
    defer t.stop(alloc, io);
    _ = std.c.waitpid(t.child, null, 0);
    t.child = -1;
    // That it had already gone by then is all there is to know of it, and
    // that is an answer, not "cannot tell".
    const peer = transport.peerOf(t.conn);
    try testing.expect(peer != null);
    try testing.expect(peer.? == .disconnected);

    const p = try PeerTest.newPending(alloc);
    defer p.release();
    p.retain();
    var asks: usize = 0;
    try testing.expectEqual(@as(?Waited, .peer_gone), PeerTest.waitAtMost(io, p, t.gone(peer, io, p, &asks), 5000));
    try testing.expect(!p.settle(io, .{ .failed = .{ .code = "FromApp", .message = "late" } }));
    p.release();
}

test "1731: the slots running out is said once, however many are turned away, and again only after one was free" {
    var g: FullGate = .{};
    const first = g.refused(1_000);
    try testing.expect(first.alert);
    try testing.expectEqual(@as(?u64, 1), first.log);
    // Fifty more inside the minute: nothing said, nothing logged.
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const v = g.refused(1_000 + @as(i64, @intCast(i)) * 100);
        try testing.expect(!v.alert);
        try testing.expectEqual(@as(?u64, null), v.log);
    }
    // A minute on: one line, counting what was turned away since -- and
    // still nothing said to the person.
    const later = g.refused(61_000);
    try testing.expect(!later.alert);
    try testing.expectEqual(@as(?u64, 51), later.log);
    // A slot comes free: how many were turned away in all, and the next
    // time it fills is said again.
    try testing.expectEqual(@as(?u64, 52), g.room());
    try testing.expectEqual(@as(?u64, null), g.room());
    const again = g.refused(62_000);
    try testing.expect(again.alert);
    try testing.expectEqual(@as(?u64, 1), again.log);
}
