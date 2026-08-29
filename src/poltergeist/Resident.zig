//! One plugin, one process, one protocol.
//!
//! Every plugin lives here. There used to be three shapes -- a fork per
//! notification, a resident stream for the chat archive, one run at startup
//! for provisioning -- picked by a `kind` field that decided the lifetime
//! and the contract together. Three contracts meant three places to
//! remember, and the thing that was forgotten was never the code that ran:
//! it was one of the *lists*, twice, in the same file, the second time in
//! the comment left by the first. There is one shape now:
//!
//!     spawn -> hello -> a line of events -> a line of acknowledgement
//!
//! and what separates one plugin from another is only `wants.events`.
//!
//! **A plugin is handed what happens, not the core's own files.** What it
//! keeps is an extra copy, made from a live subscription (`Feed.zig`);
//! the core's stream, record and rotation are a core feature that stands
//! complete whether or not any plugin exists, and are never a plugin's
//! data source. This file therefore names no path, opens no log and keeps
//! no cursor file: change how the core stores things and nothing here has
//! to move. See `docs/poltergeist/plugins.md`.
//!
//! What that costs, said plainly: a plugin that is away for an hour misses
//! the hour. Its subscription is bounded, so past the bound the oldest
//! events are dropped and counted, and the count is said out loud. The
//! core's own record is untouched by any of it -- the thing a person or an
//! agent reads back is complete either way, which is the half that
//! matters. The old design bought "a plugin loses nothing" by making the
//! plugin a reader of the core's log file, and that price turned out to be
//! the design itself.
//!
//! **Why a process and not a library.** These are scripts people copy off
//! the internet. They will hang, segfault, and flood stdout, and none of
//! that may take the terminal down with it -- a process boundary is the
//! only place that guarantee comes free. And it means any language: a
//! twenty-line `curl` script is a complete plugin, where requiring Zig
//! would mean the extension point does not exist. Both of those reasons
//! survived the merge intact; what did not survive is the third one, "the
//! rate makes a fork per occasion affordable", which was an argument for
//! the *one-shot* lifetime rather than for the process boundary.
//!
//! **What being resident costs, now that everything is.** A one-shot
//! plugin self-heals: the occasion ends, the process ends with it, and a
//! plugin that hung took only its own notification down. A resident one
//! that hangs stays hung. That is a real loss and it is paid for here
//! rather than waved at:
//!
//!   - The reaper bounds **one exchange**, not the life of the process, so
//!     a plugin that stops answering is killed at the next batch rather
//!     than at some deadline it has already outlived.
//!   - A killed child is restarted, with backoff, then dormancy, then
//!     retried anyway -- machinery the one-shot path never had at all. A
//!     one-shot notifier that failed simply failed.
//!   - The heartbeat is what makes a silent corpse visible: without traffic
//!     to write into, a dead child would not be noticed until the next
//!     thing happened, which on a quiet night is the morning.
//!
//! Two costs are not paid for and are stated instead. **Credentials are
//! resolved once per child**, at the spawn, and held until it dies: a vault
//! that locks at noon is not noticed until the next restart, where a
//! one-shot plugin re-asked on every occasion. And **an idle plugin is now
//! a process**, where a notifier used to cost nothing between notifications.
//! One idle process per installed plugin is the price of the crash boundary
//! being the same boundary for everybody.
//!
//! **Polled, never woken.** The side that produced the event is the side
//! that must not be made to wait for anything, and the cheapest way to
//! guarantee that is for it to have nothing here to wait on: it drops a
//! copy into a queue and returns. Half a second of latency on a database
//! write is not a thing anybody can perceive; a millisecond added to the
//! keystroke that produced the message is.
//!
//! **Taking a batch is not removing it.** Events stay in the subscription
//! until the plugin says it stored them, so a refusal, a hang or a death
//! mid-batch is answered by handing over the same batch again. There is
//! still no second buffer anywhere -- the subscription is the queue, the
//! way the log used to be.

const Resident = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Feed = @import("Feed.zig");
const Plugin = @import("Plugin.zig");
const PluginLog = @import("PluginLog.zig");
const reap = @import("reap.zig");
const report = @import("report.zig");
const secret = @import("secret.zig");

const log = std.log.scoped(.poltergeist);

/// How long a quiet minute waits before looking for events again.
const poll_idle_ms_default: u64 = 500;

/// Silence after which the plugin is given an empty batch anyway.
///
/// The one weakness of polling: a child that died while nothing was being
/// said would not be noticed until something was. A heartbeat turns that
/// into an immediate `EPIPE` or end-of-input, and gives the plugin a chance
/// to keep its own connection warm.
const heartbeat_ms_default: u64 = 30 * std.time.ms_per_s;

const max_batch: usize = 256;
const max_batch_bytes: usize = 256 * 1024;
const ack_max_bytes: usize = 64 * 1024;

const backoff_start_ms_default: u64 = 1000;
const backoff_max_ms: u64 = 60 * std.time.ms_per_s;

/// How long a child has to stay up before it counts as having worked.
///
/// Not "the handshake succeeded": a plugin that greets us and then dies
/// could otherwise reset the backoff to one second for ever.
const settle_ms_default: u64 = 60 * std.time.ms_per_s;

/// Restarts in a row before the resident goes dormant.
const max_failures: u32 = 10;

/// How long dormant lasts. Never forever: the usual reasons a resident
/// plugin cannot start -- the database is down, the laptop is off the
/// network, the vault is locked -- all fix themselves, and requiring the
/// user to restart Polter to pick that up would mean the resident is broken
/// for exactly as long as nobody is watching. The log holds everything
/// meanwhile, so a quarter of an hour costs one fork and nothing else.
const dormant_retry_ms_default: u64 = 15 * 60 * std.time.ms_per_s;

/// Slices a wait is broken into, so shutdown is never long behind it.
const wait_slice_ms: u64 = 100;

/// Soft refusals in a row before the loop stops asking at full speed.
///
/// A plugin answering `{"ok":false}` has said "not now", which is its
/// right; re-offering the same batch twice a second while it says so is
/// not reading, it is nagging.
const max_soft: u32 = 3;

/// How patient the loop is.
///
/// The defaults are the constants above and are what everything but a test
/// uses. Tests set them small, because a restart that takes a minute of
/// wall clock to observe is a restart nobody observes: the choice is
/// between this field and having no test of the restart path at all.
pub const Timing = struct {
    poll_idle_ms: u64 = poll_idle_ms_default,
    heartbeat_ms: u64 = heartbeat_ms_default,
    backoff_start_ms: u64 = backoff_start_ms_default,
    settle_ms: u64 = settle_ms_default,
    dormant_retry_ms: u64 = dormant_retry_ms_default,
};

pub const Options = struct {
    /// All of these are copied. After `start` the resident borrows nothing
    /// from the caller, so a config reload that rebuilds the plugin arena
    /// cannot pull the ground out from under the thread.
    key: []const u8,
    exec: []const u8,
    timeout_ms: u64,

    /// Everything the manifest declared. What is enforced here is
    /// `events` and `groups`; `calls` travels with the hello so the plugin
    /// can read back what it will be allowed to ask for, and is enforced at
    /// the socket. See `Plugin.Wants`.
    wants: Plugin.Wants,

    params: []const Plugin.Param,

    /// Where the plugin reaches the tool surface: the same unix socket and
    /// the same line protocol an agent uses, and a token of its own.
    ///
    /// **The same door, not a second one.** A plugin that wants to post in
    /// a group speaks the method an agent speaks; there is no plugin-shaped
    /// vocabulary to keep in step with the agent-shaped one, because there
    /// is only one. Empty when the server is not up, in which case the
    /// hello says so by leaving both fields out and the plugin is fed
    /// events all the same.
    socket: []const u8 = "",
    token: []const u8 = "",

    /// Where the events come from. Borrowed, and it has to outlive the
    /// resident: `destroy` unsubscribes from it.
    feed: *Feed,

    /// Taken over whole, on the failure paths too. See `start`.
    environ: std.process.Environ.Map,

    /// Where this plugin's log file goes -- the directory, not the file;
    /// the name inside it is `PluginLog`'s to decide.
    ///
    /// **Empty means there is nowhere to write**, which is a state
    /// directory that could not be worked out and nothing else. Then, and
    /// only then, the child's standard error is inherited the way it was
    /// before there was a log: into Polter's own, where in a packaged app
    /// it is visible to nobody. That is the old behaviour kept as the
    /// fallback rather than as the design.
    log_dir: []const u8 = "",

    /// Where a failure goes so that the **person** hears about it.
    ///
    /// Null in tests and wherever there is no app to tell. See `Alert`.
    alert: ?Alert = null,

    timing: Timing = .{},
};

/// How a failure reaches the user's screen.
///
/// **A plugin failing is not only a log line**, and this is the whole
/// reason this hook exists. What fails when a plugin fails is either the
/// agent's tool surface or the user's own channel of being told anything --
/// and in the first case the agent is precisely the party that cannot be
/// told about it. So it has to go to the person, and the person is at a
/// terminal, and terminals belong to the app thread.
///
/// **This is called on the resident's own thread.** The implementation must
/// therefore do one thing only: copy the line and hand it to the app
/// thread's mailbox. It must not touch a surface, the bus, or anything else
/// the app thread owns, and it must not block -- this thread is the one
/// keeping a child's deadline honest, and a resident parked behind the app
/// loop is a plugin nobody is holding to time.
///
/// The line is borrowed for the duration of the call.
pub const Alert = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, line: []const u8) void,

    fn say(self: Alert, line: []const u8) void {
        self.func(self.ctx, line);
    }
};

pub const Error = Allocator.Error || error{
    /// The manifest subscribed to nothing, so there is nothing to feed it.
    WantsNothing,

    /// The feed would not take another subscriber.
    NoSubscription,

    /// The thread would not start.
    NoThread,
};

/// Sized rather than inferred, because it is read out of an atomic and
/// those want a type with a width.
pub const State = enum(u8) { starting, feeding, backing_off, dormant, stopped };

pub const Status = struct {
    state: State,

    /// The seq everything up to which the plugin has confirmed.
    cursor: u64,

    /// Restarts since the last child that settled.
    failures: u32,

    /// Events this plugin was never handed, because it was too far behind
    /// when they arrived. Zero is the ordinary reading; anything else is
    /// this plugin's copy having a hole in it, and the core's record not.
    dropped: u64 = 0,
};

alloc: Allocator,
io: std.Io,

/// Everything copied out of `Options`. Owned by `arena`.
arena: std.heap.ArenaAllocator,
key: []const u8,
exec: []const u8,
timeout_ms: u64,
wants: Plugin.Wants,
params: []const Plugin.Param,
socket: []const u8,
token: []const u8,
environ: std.process.Environ.Map,
alert: ?Alert,

timing: Timing,

/// One window of the child's stdout, reused across children. Owned by
/// `arena`, `ack_max_bytes` long: a longer line is a protocol violation, so
/// the buffer is the limit rather than a hint.
ack_buf: []u8,

/// Where events come from, and this plugin's own place in them. The feed
/// is borrowed; the subscription belongs to it and is given back in
/// `destroy`.
feed: *Feed,
sub: *Feed.Subscription,

/// Set false by `stop`. The only thing the thread reads from outside.
running: std.atomic.Value(bool) = .init(true),

/// Shared with `stop` so shutdown can reach a live child without taking a
/// lock the feeding loop might be holding across a blocking write.
reaper: reap.Reaper,

thread: ?std.Thread = null,

/// When this plugin last put a `stopped` line on somebody's screen. Read
/// and written only by the resident's own thread, which is the only thing
/// that calls `tell`.
told_at: ?std.Io.Timestamp = null,

/// This plugin's own log: its standard error and Polter's account of it,
/// in one file. Null when there was nowhere to put one.
///
/// Written from two threads and it knows: see `PluginLog.mutex`.
plog: ?PluginLog = null,

/// Read by `status` from the main thread, written by the thread. Coarse on
/// purpose: it is for a log line and a future MCP tool, not for deciding
/// anything.
state: std.atomic.Value(State) = .init(.starting),
confirmed: std.atomic.Value(u64) = .init(0),
failures: std.atomic.Value(u32) = .init(0),
dropped: std.atomic.Value(u64) = .init(0),

/// Start feeding one resident plugin.
///
/// **`opts.environ` is taken over the moment this is called, on the failure
/// paths too.** There is no way for a caller to tell from the outside which
/// error paths freed it and which did not, so the rule is that all of them
/// do: hand the map over and never write a `defer` for it. A resident that
/// was refused has therefore been cleaned up after completely, and
/// `destroy` must not be called on one.
///
/// The resident is heap-allocated because the thread holds a pointer to it.
/// A caller that gets one back must `destroy` it, which stops the thread
/// first.
pub fn start(alloc: Allocator, io: std.Io, opts: Options) Error!*Resident {
    var environ = opts.environ;
    errdefer environ.deinit();

    // First, before anything is allocated. The caller checks this too, to
    // say something better about which plugin it was, but refusing here is
    // what makes "a plugin that wants nothing does not run" true rather
    // than merely observed.
    if (opts.wants.empty()) return error.WantsNothing;

    const self = try alloc.create(Resident);
    errdefer alloc.destroy(self);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    const key = try a.dupe(u8, opts.key);
    const exec = try a.dupe(u8, opts.exec);

    // The whole `Wants` is copied, list by list, because the manifest arena
    // it came out of is rebuilt every time the plugin directories are read
    // and this thread outlives that.
    const events = try a.dupe(Plugin.Event, opts.wants.events);

    const calls = try a.alloc([]const u8, opts.wants.calls.len);
    for (opts.wants.calls, calls) |src, *dst| dst.* = try a.dupe(u8, src);

    const groups = try a.alloc([]const u8, opts.wants.groups.len);
    for (opts.wants.groups, groups) |src, *dst| dst.* = try a.dupe(u8, src);

    const exec_wanted = try a.alloc([]const u8, opts.wants.exec.len);
    for (opts.wants.exec, exec_wanted) |src, *dst| dst.* = try a.dupe(u8, src);

    const wants: Plugin.Wants = .{
        .events = events,
        .calls = calls,
        .groups = groups,
        .network = opts.wants.network,
        .exec = exec_wanted,
    };

    const params = try a.alloc(Plugin.Param, opts.params.len);
    for (opts.params, params) |src, *dst| dst.* = .{
        .name = try a.dupe(u8, src.name),
        .value = try a.dupe(u8, src.value),
    };

    const ack_buf = try a.alloc(u8, ack_max_bytes);

    // Before the thread, so that the events of the very first message a
    // plugin could possibly be shown are already being kept for it. A
    // subscription starts empty by definition: what came before it is in
    // the core's record, and reading that is not a plugin's job.
    const sub = opts.feed.subscribe(.{}) catch return error.NoSubscription;
    errdefer opts.feed.unsubscribe(sub);

    self.* = .{
        .alloc = alloc,
        .io = io,
        .arena = arena,
        .key = key,
        .exec = exec,
        .timeout_ms = opts.timeout_ms,
        .wants = wants,
        .params = params,
        .socket = try a.dupe(u8, opts.socket),
        .token = try a.dupe(u8, opts.token),
        .alert = opts.alert,
        .environ = environ,
        .timing = opts.timing,
        .ack_buf = ack_buf,
        .feed = opts.feed,
        .sub = sub,

        // The arena's copy of the key, never the caller's: the reaper logs
        // from another thread, long after the manifest it came from has
        // been rebuilt.
        .reaper = .init(io, key, null, 0),
    };

    // Before the thread, because the thread writes into it from its first
    // line. A log that cannot be opened is a warning and nothing more: a
    // plugin that runs without one is worse off than a plugin that does not
    // run at all is.
    if (opts.log_dir.len > 0) {
        self.plog = PluginLog.open(alloc, io, opts.log_dir, key) catch null;
    }

    // Last. The thread dereferences `self` immediately, so nothing may
    // still be being written when it starts.
    self.thread = std.Thread.spawn(.{}, main, .{self}) catch {
        return error.NoThread;
    };

    return self;
}

/// Ask the thread to finish, take the child's stdin away, and join.
/// Idempotent.
pub fn stop(self: *Resident) void {
    if (self.thread == null) return;
    self.running.store(false, .release);

    // The reaper rather than the child: shutdown must not take a lock the
    // feeding loop could be holding across a write to a pipe nobody is
    // reading. `hurry` takes only the reaper's own lock, which is never
    // held across anything that blocks.
    self.reaper.hurry();

    self.thread.?.join();
    self.thread = null;
}

/// Free everything. `stop` first.
pub fn destroy(self: *Resident) void {
    // The thread first, and only then the subscription: giving it back
    // frees the queue the thread reads from.
    self.stop();
    self.feed.unsubscribe(self.sub);
    if (self.plog) |*p| p.deinit();
    self.environ.deinit();
    self.arena.deinit();
    self.alloc.destroy(self);
}

pub fn status(self: *const Resident) Status {
    return .{
        .state = self.state.load(.acquire),
        .cursor = self.confirmed.load(.acquire),
        .failures = self.failures.load(.acquire),
        .dropped = self.dropped.load(.acquire),
    };
}

/// What a plugin said back.
pub const Ack = struct {
    ok: bool = false,
    cursor: ?u64 = null,
};

/// Read one acknowledgement line, or null when it is not one.
///
/// Unknown fields are ignored by construction -- the object is read by
/// name -- which is what lets the protocol grow a field without breaking a
/// plugin that has never heard of it.
pub fn parseAck(alloc: Allocator, line: []const u8) ?Ack {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Scanned by hand rather than through `parseFromSliceLeaky`, which
    // *asserts* that the input ends after the value it read. Two objects on
    // one line is something a plugin can write by accident and must be a
    // violation, not a panic in the terminal that hosts it.
    var scanner: std.json.Scanner = .initCompleteInput(a, line);
    defer scanner.deinit();

    // The two options `parseFromSliceLeaky` would have filled in for us,
    // and which `jsonParse` reads without checking.
    const opts: std.json.ParseOptions = .{
        .max_value_len = @max(line.len, 1),
        .allocate = .alloc_if_needed,
    };

    const parsed = std.json.Value.jsonParse(a, &scanner, opts) catch return null;
    if ((scanner.next() catch return null) != .end_of_document) return null;

    const obj = switch (parsed) {
        .object => |o| o,
        else => return null,
    };

    return .{
        // Absent reads as false, the same rule as a one-shot plugin's exit
        // code: not saying it worked is not saying it worked.
        .ok = switch (obj.get("ok") orelse .null) {
            .bool => |b| b,
            else => false,
        },

        .cursor = switch (obj.get("cursor") orelse .null) {
            .integer => |i| if (i < 0) null else @as(u64, @intCast(i)),
            else => null,
        },
    };
}

/// What an acknowledgement means for the cursor.
pub const Advance = union(enum) {
    /// Move the cursor here.
    to: u64,

    /// Leave it where it is and send the batch again.
    stay,

    /// The plugin said something it cannot know. Kill it.
    violation,
};

/// The rule the whole design rests on, on its own so it can be read.
///
/// A cursor is a promise made to everybody: everything at or below it has
/// been stored. The plugin has no channel to these events but this one, so
/// it cannot have stored something it was never given -- and accepting a
/// number larger than what was sent would mean the events in between are
/// dropped from the queue with nobody having stored them, and nothing
/// anywhere to show for it.
/// That silent hole is the exact failure the whole design exists to
/// prevent, so it is not ignored: the child is killed and restarted,
/// because a plugin that reports doing what it cannot do has no
/// acknowledgement worth trusting afterwards.
///
/// A missing `ok` counts as false, the same rule as a one-shot plugin's
/// exit code: not saying it worked is not saying it worked. A missing
/// `cursor` under `ok` means the whole batch, which is what lets the
/// simplest possible plugin stay simple -- read a line, answer
/// `{"ok":true}`.
pub fn advance(before: u64, through: u64, ack: Ack) Advance {
    if (!ack.ok) return .stay;
    const at = ack.cursor orelse return .{ .to = through };
    if (at > through) return .violation;
    if (at < before) return .violation;

    // Saying it worked and naming the place it was already standing says
    // exactly what not saying it worked says: nothing new was stored. It
    // has to come back as `stay` rather than as a move onto the cursor's
    // own position, because the loop reads any move as progress -- it
    // clears the soft-failure count and goes straight round again with no
    // wait at all, since the wait lives on the path where there was
    // nothing to send. A plugin that echoes back the `cursor` it was
    // handed, which is the easiest of all the ways to write one wrong,
    // would otherwise hold this thread at full speed re-reading and
    // re-sending one batch for as long as Polter is up.
    if (at == before) return .stay;

    return .{ .to = at };
}

/// Render one batch line, `\n` included, filtering by `groups`.
///
/// `through` is the last seq examined, which is not the last seq sent when
/// groups were filtered out. Without it a plugin that wants one group could
/// never confirm past a stretch of somebody else's traffic, and its cursor
/// would stick there for good.
pub fn renderBatch(
    alloc: Allocator,
    cursor: u64,
    through: u64,
    events: []const Feed.Event,
    wants: Plugin.Wants,
) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    // The writer allocates, so the only way any of this fails is running
    // out of memory; saying that once beats saying it at every field.
    writeBatch(&s, cursor, through, events, wants) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;

    return out.toOwnedSlice();
}

fn writeBatch(
    s: *std.json.Stringify,
    cursor: u64,
    through: u64,
    events: []const Feed.Event,
    wants: Plugin.Wants,
) std.Io.Writer.Error!void {
    try s.beginObject();
    try s.objectField("cursor");
    try s.write(cursor);
    try s.objectField("through");
    try s.write(through);

    // `events`, not `messages`. The array holds more than one kind now, and
    // a field named for the only kind there used to be would have to be
    // re-read by every plugin author the first time it carried something
    // else.
    try s.objectField("events");
    try s.beginArray();

    for (events) |ev| {
        if (!forThisPlugin(ev, wants)) continue;

        try s.beginObject();

        // Two numbers, and they are not the same number. `n` is this
        // event's place in the one stream, which is what `cursor` and
        // `through` count in and what an acknowledgement names. Anything
        // else an event carries is its own kind's identity.
        try s.objectField("n");
        try s.write(ev.n());
        try s.objectField("kind");
        try s.write(ev.kind().wireName());

        // Switched over rather than assumed, so that a new kind is a branch
        // somebody has to write here rather than a field silently rendered
        // as though it were something else.
        switch (ev) {
            .chat => |e| {
                try s.objectField("seq");
                try s.write(e.seq);
                try s.objectField("at_ms");
                try s.write(e.at_ms);
                try s.objectField("group");
                try s.write(e.group);
                try s.objectField("author");
                try s.write(e.author);

                // There is no `from` to leave out any more: a `Bus.Id` is a
                // handle valid for one run of one process, and `Feed.Chat`
                // does not carry one at all.

                if (e.summary) {
                    try s.objectField("summary");
                    try s.write(true);
                }

                try s.objectField("text");
                try s.write(e.text);
            },

            .terminal_quiet => |e| {
                try s.objectField("at_ms");
                try s.write(e.at_ms);
                try s.objectField("reason");
                try s.write(e.reason);
                try s.objectField("title");
                try s.write(e.title);
                try s.objectField("body");
                try s.write(e.body);

                // The same `0x…` text the host puts in the environment, so
                // what a plugin reads here and what an agent reads from
                // `GHOSTTY_SURFACE_ID` are one string.
                try s.objectField("terminal");
                try s.print("\"0x{x:0>16}\"", .{e.terminal});
                try s.objectField("terminal_name");
                try s.write(e.terminal_name);
            },

            .provision => |e| {
                try s.objectField("at_ms");
                try s.write(e.at_ms);
                try s.objectField("exe");
                try s.write(e.exe);
                try s.objectField("version");
                try s.write(e.version);
                try s.objectField("version_key");
                try s.write(e.version_key);
                try s.objectField("home");
                try s.write(e.home);

                try s.objectField("skills");
                try s.beginArray();
                for (e.skills) |skill| {
                    try s.beginObject();
                    try s.objectField("name");
                    try s.write(skill.name);
                    try s.objectField("path");
                    try s.write(skill.path);
                    try s.endObject();
                }
                try s.endArray();
            },
        }

        try s.endObject();
    }

    try s.endArray();
    try s.endObject();
}

/// Whether one event is this plugin's to see.
///
/// **The whole of the `events` guarantee, in one function.** Two gates, and
/// they are asked in this order because the second one only makes sense for
/// the kinds that have a group:
///
///   1. Did the manifest subscribe to this kind? If not, nothing else is
///      considered. This is what makes "subscribe to what you want" a rule
///      the host keeps rather than a note in a manifest.
///   2. If the event has a group, is that group one the manifest asked for?
///      An event with no group is not refused for having none -- a
///      notification is in no group, and requiring `"groups": ["*"]` from
///      every notifier would be a rule nobody could explain.
///
/// There is exactly one of these, and both the "is there anything to send"
/// check and the renderer go through it. Two copies of a filter is how the
/// header of a batch comes to disagree with its body.
pub fn forThisPlugin(ev: Feed.Event, wants: Plugin.Wants) bool {
    if (!wants.subscribes(ev.kind())) return false;
    const g = ev.group() orelse return true;
    return wants.allows(g);
}

/// Render the opening line, `\n` included. `params` must already be
/// resolved.
pub const Hello = struct {
    key: []const u8,
    cursor: u64,
    wants: Plugin.Wants,

    /// Where the tool surface is, and the plugin's own token for it. Both
    /// empty when there is no server, and then neither is written.
    socket: []const u8 = "",
    token: []const u8 = "",

    params: []const Plugin.Param,

    /// Resolved, one per entry in `params` and in the same order.
    values: []const []const u8,
};

pub fn renderHello(alloc: Allocator, h: Hello) Allocator.Error![]u8 {
    // The caller resolves in a loop, and a mismatch there would quietly
    // pair one parameter's name with another's secret.
    std.debug.assert(h.params.len == h.values.len);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    writeHello(&s, h) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;

    return out.toOwnedSlice();
}

fn writeHello(s: *std.json.Stringify, h: Hello) std.Io.Writer.Error!void {
    try s.beginObject();

    // The protocol version, and the only reason it is a number rather than
    // a marker: a plugin that does not know this one can say so by exiting
    // instead of guessing at the rest of the line.
    try s.objectField("hello");
    try s.write(1);

    try s.objectField("plugin");
    try s.write(h.key);
    try s.objectField("cursor");
    try s.write(h.cursor);

    // Copied over so a plugin can check for itself what it is going to be
    // shown and what it will be allowed to ask for, rather than inferring
    // either from what turns up and what gets refused.
    try s.objectField("events");
    try s.beginArray();
    for (h.wants.events) |e| try s.write(e.wireName());
    try s.endArray();

    try s.objectField("groups");
    try s.write(h.wants.groups);

    try s.objectField("calls");
    try s.beginArray();
    for (h.wants.calls) |c| try s.write(c);
    try s.endArray();

    // The same socket and the same line protocol an agent gets, with a
    // token of the plugin's own. Left out entirely rather than written
    // empty when there is no server: a plugin that tests for the field gets
    // a clean "there is nowhere to call", where an empty string is a path
    // it would go and try to connect to.
    if (h.socket.len > 0 and h.token.len > 0) {
        try s.objectField("socket");
        try s.write(h.socket);
        try s.objectField("token");
        try s.write(h.token);
    }

    // Resolved values, in plain text, exactly once in the whole
    // conversation. Nothing repeats them per batch.
    try s.objectField("params");
    try s.beginObject();
    for (h.params, h.values) |p, v| {
        try s.objectField(p.name);
        try s.write(v);
    }
    try s.endObject();

    try s.endObject();
}

/// Whether anything in this window is this plugin's to see.
///
/// Asked before a line is rendered, so that a window belonging entirely to
/// somebody else costs no pipe at all.
fn anyAllowed(events: []const Feed.Event, wants: Plugin.Wants) bool {
    for (events) |ev| if (forThisPlugin(ev, wants)) return true;
    return false;
}

/// How long to wait before the next attempt, and whether to keep trying.
///
/// Neither of the two easy answers. Retrying for ever is a fork loop;
/// giving up for good means the resident is broken for precisely as long as
/// nobody is watching, which is the whole scenario this exists for.
pub const Backoff = struct {
    /// Where `settled` puts `ms` back to. Carried rather than read off the
    /// constant so that a test can watch a restart happen instead of
    /// waiting one out.
    start_ms: u64 = backoff_start_ms_default,

    ms: u64 = backoff_start_ms_default,
    failures: u32 = 0,

    /// Record a child that did not work out, and say how long to wait.
    /// Null once the resident should go dormant.
    pub fn failed(self: *Backoff) ?u64 {
        self.failures += 1;
        if (self.failures > max_failures) return null;

        const wait = self.ms;
        self.ms = @min(self.ms * 2, backoff_max_ms);
        return wait;
    }

    /// Record a child that stayed up long enough to count.
    pub fn settled(self: *Backoff) void {
        self.* = .{ .start_ms = self.start_ms, .ms = self.start_ms };
    }
};

// -- the thread -------------------------------------------------------------

/// How one turn of the loop ended.
const Step = enum {
    /// Round again. Either something was done or the wait has already been
    /// taken.
    carry_on,

    /// This child is no good any more: collect it and back off.
    failure,
};

/// What came back on the child's stdout.
const Line = union(enum) {
    got: []const u8,

    /// End of input. The child has gone, whether it meant to or not.
    gone,

    /// Longer than the buffer, which is the protocol's limit.
    too_long,
};

/// The two ends of the child's standard error.
///
/// **A socket pair rather than a pipe, and the whole reason is that a pipe
/// cannot be told to stop.** The thread draining this blocks in a read, and
/// the ordinary way to end such a thread is end of input -- which arrives
/// when every writer has closed. But a plugin's own subprocesses inherit
/// this descriptor, which is the point of it: a subcommand's errors are the
/// plugin's errors and belong in the plugin's log. So a plugin that leaves
/// a long-lived grandchild behind holds the writing end open after the
/// plugin itself has been killed, and a `join` here would then never
/// return: Polter would not quit, on a machine where somebody's plugin
/// spawns a daemon. `shutdown(SHUT_RD)` on a socket ends the read from
/// **our** side, so the drain stops when we say it stops and never when
/// somebody else's process decides.
///
/// It also rules out the other way to unblock such a thread -- closing the
/// descriptor under it -- which is the same shape as the pid-reuse window
/// `collect` goes out of its way to close: the number is freed and handed
/// to whatever asks next.
const Stderr = struct {
    /// Ours to read. Closed here, after the drain has stopped.
    ours: std.Io.File,

    /// The child's. `spawn` dups it onto the child's descriptor 2; this
    /// copy is closed the moment that has happened.
    theirs: std.Io.File,

    fn make() ?Stderr {
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.socketpair(
            @intCast(std.c.AF.UNIX),
            @intCast(std.c.SOCK.STREAM),
            0,
            &fds,
        ) != 0) return null;

        // Blocking, which is what everything downstream assumes: the drain
        // wants to sit in a read until there is something, and the child
        // inherits this as its standard error, where a nonblocking
        // descriptor makes ordinary programs misbehave.
        return .{
            .ours = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
            .theirs = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
        };
    }
};

/// Take the deadline off the child, now that nothing is waiting on it.
///
/// The reaper bounds **one exchange** -- a write into a pipe nobody is
/// draining, a read from a plugin that has stopped answering -- and not the
/// life of the process. Between exchanges the host is the one taking the
/// time: it naps for `poll_idle_ms`, it drains windows this plugin is not
/// allowed to see, it waits out a whole `heartbeat_ms` of nobody saying
/// anything. Every real manifest carries a timeout far shorter than that
/// gap, so a deadline left running would kill a well behaved plugin for the
/// host's own patience -- and, because the loop is asleep, would not even
/// notice the corpse until the next heartbeat.
///
/// So: armed by `allow` immediately before each write, and taken off again
/// the moment an answer is in hand. `hurry` still wins, because it is
/// sticky and `allow` honours it, which is what keeps shutdown prompt.
fn unhurried(self: *Resident) void {
    self.reaper.allow(std.math.maxInt(u64));
}

/// Take one line of the child's answer.
///
/// The reader is made once per child and lives across batches, because it
/// buffers: a fresh one per exchange would throw away whatever of the next
/// line had already arrived.
fn readLine(reader: *std.Io.File.Reader) Line {
    // `takeDelimiter` hands back a final unterminated fragment at end of
    // input as though it were a line, and answers null only on the call
    // after. So a plugin that answers and then exits without a newline
    // looks, once, like it answered; the corpse is collected at the next
    // exchange, which is soon enough and cannot skip a message -- the
    // cursor moved only on what it actually said.
    const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        // Nothing was consumed, so asking again would read the same full
        // buffer for ever. It has to end this child, never be retried.
        error.StreamTooLong => return .too_long,
        error.ReadFailed => return .gone,
    } orelse return .gone;

    return .{ .got = line };
}

/// Say something about this plugin in both of the places it belongs.
///
/// Polter's own log is where somebody debugging Polter looks. The plugin's
/// log is where the **user** looks, and it is the only one of the two that
/// has the plugin's own output sitting beside the verdict. Anything worth
/// one is worth the other, and saying it once here is what stops the two
/// accounts drifting into disagreement about the same night.
fn note(
    self: *Resident,
    comptime level: enum { info, warn },
    comptime fmt: []const u8,
    args: anytype,
) void {
    // The key is in Polter's log because that one holds every plugin; it is
    // left out of the plugin's own, where it would be on every line and
    // say nothing.
    switch (level) {
        .info => log.info("plugin {s}: " ++ fmt, .{self.key} ++ args),
        .warn => log.warn("plugin {s}: " ++ fmt, .{self.key} ++ args),
    }

    if (self.plog) |*p| p.note(fmt, args);
}

/// One line a plugin wrote in front of its answer.
const Told = struct {
    text: []const u8,

    /// Whether the same line also carries an `ok`, and is therefore the
    /// answer as well as a report.
    ///
    /// **Forgiving on purpose.** The design is that a report is a line of
    /// its own; but a plugin author who puts both on one line has written
    /// something whose intent is not in doubt, and refusing it would mean a
    /// silent restart loop -- the host waiting for an answer that was in
    /// the line it just read. The narrow reading buys nothing and costs a
    /// support question.
    answers: bool,
};

/// What a plugin said on the way to answering, if it said anything.
///
/// **A kind of line, not a tool call, and that is the design.** Reporting
/// its own state is not a capability a plugin has to be granted -- it is
/// part of the protocol, in the same way that Polter saying "this plugin
/// will not start" is. A plugin saying "I could not write that file" is the
/// same fact arriving on the same channel from the side that knows it
/// first, so it does not go through `notify_user`: that is a supervisor's
/// method, it is closed to plugins for a reason that has not changed, and
/// it answers with a string to an agent rather than putting anything on
/// anybody's screen.
///
/// Null for every line that carries no `tell` string, which is every line
/// of every plugin written before this existed.
fn tellIn(a: Allocator, line: []const u8) ?Told {
    var scanner: std.json.Scanner = .initCompleteInput(a, line);
    defer scanner.deinit();

    const opts: std.json.ParseOptions = .{
        .max_value_len = @max(line.len, 1),
        .allocate = .alloc_if_needed,
    };

    const parsed = std.json.Value.jsonParse(a, &scanner, opts) catch return null;
    if ((scanner.next() catch return null) != .end_of_document) return null;

    const obj = switch (parsed) {
        .object => |o| o,
        else => return null,
    };

    const text = switch (obj.get("tell") orelse .null) {
        .string => |t| t,

        // A `tell` that is a number or an object is not a thing to guess
        // at, and it is not misconduct either: the line is read as an
        // ordinary acknowledgement, which is what it looks like.
        else => return null,
    };

    return .{ .text = text, .answers = obj.get("ok") != null };
}

/// Read the child's next answer, dealing with whatever it says first.
///
/// The loop is not unbounded, and nothing extra was added to bound it: the
/// reaper's deadline is armed before the write and taken off only once an
/// answer is in hand, so a plugin that writes reports for ever is killed on
/// `timeout_ms` exactly as one that writes nothing is. What each report
/// costs on the way is bounded on both of its two destinations already --
/// the log rotates, and the screen is rate limited.
fn answer(self: *Resident, reader: *std.Io.File.Reader) Line {
    while (true) {
        const line = switch (readLine(reader)) {
            .got => |l| l,
            .gone => return .gone,
            .too_long => return .too_long,
        };

        // Its own arena, freed before the next line is read: the parser
        // hands back slices that may point into the reader's buffer, and
        // that buffer is what `readLine` is about to overwrite.
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();

        const told = tellIn(arena.allocator(), line) orelse return .{ .got = line };
        self.wasTold(told.text);
        if (told.answers) return .{ .got = line };
    }
}

/// Put what a plugin said where the person will see it -- and, either way,
/// where it can be read back.
///
/// **The log is unconditional and the screen is rationed**, and the
/// asymmetry is the point: a plugin failing in a loop must not be able to
/// bury the second plugin's failure under its own, and it must equally not
/// be able to make the record of its own failures disappear by repeating
/// them. So every line is written down, and the throttle decides only which
/// of them is also printed.
fn wasTold(self: *Resident, text: []const u8) void {
    if (self.plog) |*p| p.say(.said, text);

    const alert = self.alert orelse return;
    if (!self.allowedToSay()) return;

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();

    const line = report.told(arena.allocator(), self.key, text) catch return;
    alert.say(line);
}

/// Say why a child is being killed for what it said.
///
/// Killing rather than ignoring: a plugin that reports doing what it cannot
/// do has no later acknowledgement worth believing, and restarting is
/// cheap because everything it never confirmed is still queued for it.
fn violation(self: *Resident, why: []const u8, line: []const u8) void {
    self.note(
        .warn,
        "{s}, so it is being stopped; it said: {s}",
        .{ why, line[0..@min(200, line.len)] },
    );
}

/// Stop the child we have and be sure it is really gone.
///
/// **The reaper is taken out of the picture first**, which is a deliberate
/// departure from the order `Plugin.run` uses. `hurry` cannot be used here
/// at all: it is sticky, so a restart branch that called it would hand
/// every later child a deadline of zero and the resident would never keep a
/// plugin alive again. And leaving the reaper armed while this thread
/// reaps is the pid-reuse window itself -- `wait` frees the number, and a
/// signal a microsecond later lands on whatever got it next. Retiring and
/// joining before anything else closes both.
///
/// The signal is then sent from here, where the pid is provably still
/// ours: nothing has reaped it, and this thread is the only thing that ever
/// does. It is sent unconditionally, to a child that may already have
/// exited -- an unreaped process is still there to be signalled, so that
/// costs nothing.
///
/// **No grace period, on purpose.** An acknowledgement means the plugin has
/// already stored what it acknowledged; anything it had not written down is
/// something it never confirmed, and that is still in the subscription to
/// be handed to its replacement. There is nothing here worth flushing.
fn collect(
    self: *Resident,
    child: *?std.process.Child,
    keeper: *?std.Thread,
    drain: *?std.Thread,
    errs: *?std.Io.File,
) void {
    self.reaper.retire();
    if (keeper.*) |t| t.join();
    keeper.* = null;

    if (child.*) |*c| {
        if (c.id) |pid| std.posix.kill(pid, std.posix.SIG.KILL) catch {};

        // Closed *and* nulled, in that order: `wait` closes and nulls these
        // itself, so a close without the null is a second close of a
        // descriptor number the kernel may already have handed to another
        // thread. Stdout goes too, or a chatty child blocks writing into a
        // full pipe while we block in `wait`.
        if (c.stdin) |f| {
            f.close(self.io);
            c.stdin = null;
        }
        if (c.stdout) |f| {
            f.close(self.io);
            c.stdout = null;
        }

        // Standard error before the wait, so that nothing is still
        // reading a descriptor when `wait` gets to it.
        self.hush(drain, errs);

        _ = c.wait(self.io) catch {};
        child.* = null;
    }

    // Again, for the child that was never born: the pair can outlive a
    // spawn that failed, and it is ours either way.
    self.hush(drain, errs);
}

/// End the drain and give the descriptor back, in the only order that is
/// safe.
///
/// Tell our own side of the socket to stop reading, wait for the thread
/// doing the reading to notice, and only then close. Closing first would
/// free the number while a thread is still blocked on it, and the kernel
/// hands that number to whatever asks next -- the same window `collect`
/// goes out of its way to close around a pid.
///
/// Idempotent, because `collect` calls it on both of its paths and only one
/// of them has anything to do.
fn hush(self: *Resident, drain: *?std.Thread, errs: *?std.Io.File) void {
    if (errs.*) |f| _ = std.c.shutdown(f.handle, std.c.SHUT.RD);

    if (drain.*) |t| t.join();
    drain.* = null;

    if (errs.*) |f| {
        f.close(self.io);
        errs.* = null;
    }
}

/// Sleep in slices, giving up the moment `stop` has been called.
///
/// Checked before each slice rather than after, so that a dormant quarter
/// of an hour costs shutdown one slice and not one wait.
fn sleepSliced(self: *Resident, total_ms: u64) void {
    var left = total_ms;
    while (left > 0) {
        if (!self.running.load(.acquire)) return;
        const slice = @min(left, wait_slice_ms);
        std.Io.sleep(self.io, .fromMilliseconds(slice), .awake) catch return;
        left -= slice;
    }
}

/// Whether this plugin may put a line on somebody's screen right now.
///
/// **One budget per plugin, not one per kind of line.** A plugin that
/// cannot start and a plugin that reports its own trouble are, from the
/// reader's side, the same plugin filling the same screen -- and the screen
/// that one plugin fills is the screen on which a second plugin's failure
/// is never read. Two counters would let a plugin that does both spend
/// twice as much of it, which is exactly the plugin that has the most to
/// say and the least worth hearing.
///
/// The interval is `dormant_retry_ms` rather than a number of its own,
/// because "how often is this worth saying again" already has an answer in
/// this file, and two answers to one question drift.
///
/// Called only from the resident's own thread, which is the only thing that
/// reads or writes `told_at`.
fn allowedToSay(self: *Resident) bool {
    const now: std.Io.Timestamp = .now(self.io, .awake);
    if (self.told_at) |last| {
        const since = last.durationTo(now).toMilliseconds();
        if (since < self.timing.dormant_retry_ms) return false;
    }
    self.told_at = now;
    return true;
}

/// Put one failure on the user's screen, if it is one they have not just
/// been shown.
///
/// **Not every failure earns a line, and there is exactly one rule.** A
/// resident that cannot start is retried with backoff, so "it failed"
/// arrives again a second later, and again two seconds after that; and a
/// plugin that flaps -- settle, die, settle, die -- produces one failure
/// per `settle_ms` all night. Telling somebody the same thing forty times
/// is telling them once, badly, and a screen filled by one plugin is a
/// screen where the second plugin's failure is never read.
///
/// So a `stopped` line is written **at most once per `dormant_retry_ms`
/// per plugin**, and everything in between is the same line repeated. The
/// rule itself is `allowedToSay`, which is also what rations the lines a
/// plugin asks for itself: one budget, one plugin, one screen.
///
/// **One rule and not two.** An earlier draft also gated on "is this the
/// first failure since the plugin last worked", on the grounds that a
/// startup failure and a plugin dying after a good night are different
/// facts. They are -- but a child has to stay up a whole minute *and*
/// acknowledge a batch before `Backoff.settled` clears the count, so that
/// gate can never fire more often than this one already allows, and it
/// changed no observable behaviour. A negative control proved it: breaking
/// it made no test fail. Two mechanisms where one suffices is how the
/// weaker one comes to be believed in.
///
/// **Dormancy is exempt.** It can only happen once per `dormant_retry_ms`
/// by construction, and it is different news: not "it is being retried"
/// but "it has given up for a quarter of an hour".
fn tell(self: *Resident, why: report.Trouble, failures: u32) void {
    const alert = self.alert orelse return;

    if (why == .stopped and !self.allowedToSay()) return;

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();

    const line = report.alert(
        arena.allocator(),
        self.key,
        self.wants,
        why,
        failures,
    ) catch return;

    alert.say(line);
}

/// The thread body.
fn main(self: *Resident) void {
    const io = self.io;
    const a = self.alloc;

    var child: ?std.process.Child = null;
    var keeper: ?std.Thread = null;
    var reader: ?std.Io.File.Reader = null;

    // The child's standard error, and the thread emptying it into this
    // plugin's log. The context outlives every child because this frame
    // does; the thread holding a pointer to it is joined in `collect`
    // before another child is ever started.
    var drain_ctx: PluginLog.Drain = undefined;
    var drain: ?std.Thread = null;
    var errs: ?std.Io.File = null;

    var backoff: Backoff = .{
        .start_ms = self.timing.backoff_start_ms,
        .ms = self.timing.backoff_start_ms,
    };

    // Nothing is confirmed at the start of a run, and there is no file
    // anywhere that says otherwise. A subscription begins at the moment it
    // is made, so "where did the last run get to" is not a question this
    // has an answer to or needs one: what came before is in the core's
    // record, and the plugin's own store already holds whatever it stored
    // last time -- by seq, so a message it sees twice is one it writes
    // once.
    var confirmed: u64 = 0;
    var dropped_said: u64 = 0;

    var soft: u32 = 0;
    var spawned_at: std.Io.Timestamp = .now(io, .awake);
    var last_send: std.Io.Timestamp = spawned_at;

    outer: while (self.running.load(.acquire)) {
        const step: Step = step: {
            // -- 1. a child, if there is not one already --------------------
            if (child == null) {
                self.state.store(.starting, .release);

                var attempt: std.heap.ArenaAllocator = .init(a);
                defer attempt.deinit();
                const scratch = attempt.allocator();

                // Resolved here, at the moment of the spawn, and never
                // cached beyond the life of this child. A vault that has
                // locked since this morning has to fail, and it is every
                // restart re-asking that keeps that true -- the resident
                // process holding its resolved values until it dies is the
                // price of being resident.
                var values: std.ArrayListUnmanaged([]const u8) = .empty;
                for (self.params) |p| {
                    const v = secret.resolve(scratch, io, &self.environ, p.value) catch {
                        self.note(
                            .warn,
                            "could not resolve {s}, not starting it",
                            .{p.name},
                        );
                        break :step .failure;
                    };
                    values.append(scratch, v) catch break :step .failure;
                }

                // **The host captures the plugin's standard error**, and
                // does not ask the plugin to write a file. A plugin is any
                // executable in any language -- a twenty-line `curl`
                // script is a complete one -- so a log that came from a
                // library would exist for the plugins that happened to use
                // the library and for no others. That is not a log, it is
                // luck. It is red line 3 of `gaps.md` about the terminal
                // transcript, said again about plugins: recording is the
                // host's job, not the hosted program's, because the host is
                // the only place that can do it for all of them.
                //
                // Inherited only when there is nowhere to write, which is
                // the old behaviour kept as the fallback: in a packaged app
                // Polter's own standard error goes nowhere a user can read.
                const pair: ?Stderr = if (self.plog != null) Stderr.make() else null;

                child = std.process.spawn(io, .{
                    .argv = &.{self.exec},
                    .stdin = .pipe,

                    // The one shape difference from a one-shot plugin: it
                    // answers, so we have to be able to hear it.
                    .stdout = .pipe,

                    .stderr = if (pair) |p| .{ .file = p.theirs } else .inherit,
                }) catch |err| {
                    if (pair) |p| {
                        p.ours.close(io);
                        p.theirs.close(io);
                    }
                    self.note(.warn, "could not start err={}", .{err});
                    break :step .failure;
                };

                if (pair) |p| {
                    // Our copy of the child's end, now that the child has
                    // its own. Left open it would keep the socket alive for
                    // ever, which is only harmless because we no longer
                    // rely on end-of-input -- and relying on nothing is not
                    // a reason to leak a descriptor per restart.
                    p.theirs.close(io);
                    errs = p.ours;

                    drain_ctx = .{ .plog = &self.plog.?, .file = p.ours, .io = io };
                    drain = std.Thread.spawn(.{}, PluginLog.Drain.run, .{&drain_ctx}) catch {
                        // The same call the missing reaper thread gets, and
                        // for a version of the same reason: with nothing
                        // emptying this socket, a child that writes more
                        // than a buffer of standard error blocks inside its
                        // own write and is then killed for missing a
                        // deadline it was never given a chance to meet.
                        // Better to fail the start, which is retried, than
                        // to run a plugin that dies the moment it gets
                        // chatty.
                        self.note(
                            .warn,
                            "nothing to keep its log for it, so it is stopped again",
                            .{},
                        );
                        break :step .failure;
                    };
                }

                if (child.?.id) |pid| self.note(
                    .info,
                    "started {s} as pid {d}",
                    .{ self.exec, pid },
                );

                self.reaper.rearm(child.?.id, self.timeout_ms);
                keeper = std.Thread.spawn(.{}, reap.Reaper.run, .{&self.reaper}) catch null;

                // The one place a missing thread is not survivable. An
                // unwatched child means a write into a full pipe or a read
                // from a silent one with nothing to bound it, and that is a
                // `stop` that never returns and a window the user cannot
                // close.
                if (keeper == null) {
                    self.note(
                        .warn,
                        "nothing to keep time for it, so it is stopped again",
                        .{},
                    );
                    break :step .failure;
                }

                // `stop` can land between the spawn and the rearm. The
                // child born in that window gets no grace, because `hurry`
                // is sticky and `rearm` honours it, but the loop still has
                // to notice and go and tidy up.
                if (!self.running.load(.acquire)) break :outer;

                spawned_at = .now(io, .awake);

                const stdin = child.?.stdin orelse break :step .failure;
                const stdout = child.?.stdout orelse break :step .failure;
                reader = stdout.readerStreaming(io, self.ack_buf);

                const hello = renderHello(scratch, .{
                    .key = self.key,
                    .cursor = confirmed,
                    .wants = self.wants,
                    .socket = self.socket,
                    .token = self.token,
                    .params = self.params,
                    .values = values.items,
                }) catch break :step .failure;

                self.reaper.allow(self.timeout_ms);
                stdin.writeStreamingAll(io, hello) catch |err| {
                    self.note(.warn, "could not greet it err={}", .{err});
                    break :step .failure;
                };

                const line = switch (self.answer(&reader.?)) {
                    .got => |l| l,
                    .gone => break :step .failure,
                    .too_long => {
                        self.violation("its greeting ran past the size of a line", "");
                        break :step .failure;
                    },
                };
                self.unhurried();

                const ack = parseAck(scratch, line) orelse {
                    self.violation("its greeting was not an acknowledgement", line);
                    break :step .failure;
                };

                // Not misconduct: a resident plugin that cannot reach its
                // database says so here, and gets the same patient retry as
                // one that would not start at all.
                if (!ack.ok) {
                    self.note(
                        .warn,
                        "it will not take events yet, trying again later",
                        .{},
                    );
                    break :step .failure;
                }

                // A cursor in the greeting is the plugin stating its own
                // state -- "my database already has up to 5000" -- and it
                // is taken as information and nothing else. It used to
                // mean "rewind and send me that again", which only made
                // sense while the host was reading a file it could seek
                // in. Nothing is replayed now: the host holds exactly the
                // events this subscription has not been given credit for
                // and not one more, in either direction. Neither is it
                // misconduct in any direction -- a plugin whose store runs
                // further than this run's cursor is the ordinary state of
                // every restart.
                if (ack.cursor) |at| {
                    if (at != confirmed) self.note(
                        .info,
                        "it says it has up to seq {d}; " ++
                            "it will be sent what happens from now on",
                        .{at},
                    );
                }

                last_send = .now(io, .awake);
                self.state.store(.feeding, .release);
            }

            // -- 2. one batch ----------------------------------------------
            //
            // Taken, not removed: everything here stays in the
            // subscription until `commit`, which is what makes a refusal
            // or a death mid-batch cost nothing but the same batch again.
            const batch = self.sub.take(a, max_batch, max_batch_bytes) catch
                break :step .failure;
            defer Feed.freeBatch(a, batch);

            // Said out loud, once per new hole rather than once per event:
            // this plugin's copy is missing something the core's record is
            // not, and an extra copy quietly missing things is the one
            // thing worse than one that says so.
            const st = self.sub.stats();
            if (st.dropped > dropped_said) {
                self.note(
                    .warn,
                    "{d} event(s) went by while it was behind and " ++
                        "were not kept for it; Polter's own record has them",
                    .{st.dropped - dropped_said},
                );
                dropped_said = st.dropped;
                self.dropped.store(st.dropped, .release);
            }

            if (batch.len == 0) {
                const idle = last_send.durationTo(.now(io, .awake)).toMilliseconds();
                if (idle >= self.timing.heartbeat_ms) {
                    const beat = renderBatch(
                        a,
                        confirmed,
                        confirmed,
                        &.{},
                        self.wants,
                    ) catch break :step .failure;
                    defer a.free(beat);

                    const stdin = child.?.stdin orelse break :step .failure;
                    self.reaper.allow(self.timeout_ms);
                    stdin.writeStreamingAll(io, beat) catch break :step .failure;

                    const line = switch (self.answer(&reader.?)) {
                        .got => |l| l,
                        .gone => break :step .failure,
                        .too_long => {
                            self.violation("its answer ran past the size of a line", "");
                            break :step .failure;
                        },
                    };
                    self.unhurried();

                    // Nothing was asked of it, so there is nothing it can
                    // refuse: what a heartbeat wants is proof that a
                    // process is there and listening, and one parseable
                    // object is that proof.
                    if (parseAck(a, line) == null) {
                        self.violation("it answered a heartbeat with something else", line);
                        break :step .failure;
                    }

                    last_send = .now(io, .awake);
                }

                self.sleepSliced(self.timing.poll_idle_ms);
                break :step .carry_on;
            }

            const through = batch[batch.len - 1].n();

            if (!anyAllowed(batch, self.wants)) {
                // Not a breach of "the cursor moves only on what was
                // acknowledged": that rule is about never stepping over a
                // message the plugin has not stored, and a message it is
                // not allowed to see is not one it has anything to store.
                // The loop does not sleep here, which looks like a spin --
                // it is bounded by what is queued, and ends the moment the
                // queue is empty.
                confirmed = through;
                self.confirmed.store(through, .release);
                self.sub.commit(through);
                break :step .carry_on;
            }

            const line = renderBatch(
                a,
                confirmed,
                through,
                batch,
                self.wants,
            ) catch break :step .failure;
            defer a.free(line);

            // Before the write, never after. A batch can be a quarter of a
            // megabyte and the pipe holds 64KB, so a child that is not
            // reading blocks us in the middle of the write; the deadline
            // already running is the only thing that ends that. `SIGPIPE`
            // is ignored process-wide, so the kill surfaces here as a write
            // error rather than as a terminal that vanished.
            self.reaper.allow(self.timeout_ms);

            const stdin = child.?.stdin orelse break :step .failure;
            stdin.writeStreamingAll(io, line) catch |err| {
                self.note(.warn, "could not feed it err={}", .{err});
                break :step .failure;
            };

            const said = switch (self.answer(&reader.?)) {
                .got => |l| l,
                .gone => break :step .failure,
                .too_long => {
                    self.violation("its answer ran past the size of a line", "");
                    break :step .failure;
                },
            };
            self.unhurried();
            last_send = .now(io, .awake);

            const ack = parseAck(a, said) orelse {
                self.violation("its answer was not an acknowledgement", said);
                break :step .failure;
            };

            switch (advance(confirmed, through, ack)) {
                .violation => {
                    self.violation("it confirmed a cursor it cannot have reached", said);
                    break :step .failure;
                },

                .stay => {
                    // It said "not now", which it is allowed to say.
                    // Nothing is committed, so the same events are still
                    // queued and the next turn offers them again -- there
                    // is no retry queue and no second copy, because the
                    // subscription never let go of them.
                    soft += 1;
                    if (soft >= max_soft) {
                        soft = 0;
                        self.sleepSliced(backoff.ms);
                    }
                },

                .to => |at| {
                    confirmed = at;
                    self.confirmed.store(at, .release);
                    soft = 0;

                    // Whether it stored the batch or half of it, the
                    // arithmetic is the same one line: forget what it
                    // confirmed, keep the rest. What is kept is offered
                    // again on the next turn, from memory, with nothing
                    // read back off a disk.
                    self.sub.commit(at);

                    const up = spawned_at.durationTo(.now(io, .awake)).toMilliseconds();
                    if (up >= self.timing.settle_ms) backoff.settled();
                },
            }

            break :step .carry_on;
        };

        switch (step) {
            .carry_on => continue,
            .failure => {},
        }

        reader = null;
        self.collect(&child, &keeper, &drain, &errs);

        // Nothing to put back. A child that died between being handed a
        // batch and acknowledging it confirmed nothing, so nothing was
        // committed, so the whole batch is still queued exactly where it
        // was -- the replacement is offered it as though the first child
        // had never existed. The old design had to notice this case and
        // rewind a file position; here there is no position to rewind.
        if (!self.running.load(.acquire)) break;

        self.failures.store(backoff.failures + 1, .release);

        // The one funnel every failure passes through, which is why the
        // person is told from here rather than from each of the dozen
        // places a child can go wrong. **Every** failure is offered to
        // `tell`; deciding which of them is worth a line is `tell`'s job
        // and is in one place, with one rule.
        if (backoff.failed()) |wait| {
            self.state.store(.backing_off, .release);
            self.note(
                .info,
                "it has stopped {d} time(s) in a row; starting it again in {d}ms",
                .{ backoff.failures, wait },
            );
            self.tell(.stopped, backoff.failures + 1);
            self.sleepSliced(wait);
        } else {
            // Dormant, not finished. Said out loud every time it comes
            // round, because a resident that has been down for a quarter of
            // an hour is worth saying again.
            self.state.store(.dormant, .release);
            self.note(
                .warn,
                "giving it a rest after {d} failed starts; trying again later",
                .{backoff.failures},
            );

            // Not rate limited, and it does not need to be: going dormant
            // can only happen once per `dormant_retry_ms` by construction,
            // and it is the strictly worse news -- "it is not coming back
            // on its own any time soon" rather than "it is being retried".
            self.tell(.dormant, backoff.failures);
            self.sleepSliced(self.timing.dormant_retry_ms);
        }
    }

    reader = null;
    self.collect(&child, &keeper, &drain, &errs);

    self.note(.info, "Polter is stopping, so it is stopped too", .{});

    // Nothing is written down on the way out. There is no file that says
    // where this plugin got to, because there is nothing for such a file
    // to point into: the next run subscribes afresh and is handed what
    // happens then. Whatever was queued and unconfirmed goes with the
    // subscription -- it is an extra copy that was never made, and the
    // core's record has all of it.
    self.state.store(.stopped, .release);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

fn expectStay(got: Advance) !void {
    switch (got) {
        .stay => {},
        else => return error.TestUnexpectedResult,
    }
}

fn expectTo(want: u64, got: Advance) !void {
    switch (got) {
        .to => |at| try testing.expectEqual(want, at),
        else => return error.TestUnexpectedResult,
    }
}

fn expectViolation(got: Advance) !void {
    switch (got) {
        .violation => {},
        else => return error.TestUnexpectedResult,
    }
}

test "an acknowledgement that does not say it worked moves nothing" {
    // Absent and false are the same answer, and a cursor alongside either
    // of them changes nothing: the batch is offered again.
    try expectStay(advance(10, 20, .{}));
    try expectStay(advance(10, 20, .{ .ok = false }));
    try expectStay(advance(10, 20, .{ .ok = false, .cursor = 20 }));
}

test "an acknowledgement with no cursor takes the whole batch" {
    try expectTo(20, advance(10, 20, .{ .ok = true }));
}

test "an acknowledgement may confirm part of a batch" {
    try expectTo(15, advance(10, 20, .{ .ok = true, .cursor = 15 }));

    // The far end of the range it is allowed to name. The near end is not
    // a confirmation at all; see below.
    try expectTo(20, advance(10, 20, .{ .ok = true, .cursor = 20 }));
}

test "confirming the place it already stood is not progress" {
    // The likeliest way to write a plugin wrong: the batch arrives
    // carrying `"cursor":10`, and the answer echoes it back instead of
    // naming where the write actually reached. Read as a move, it clears
    // the soft-failure count and sends the same batch again with nothing
    // to slow it down -- one thread at full speed for as long as Polter is
    // up. Read as `stay`, it is the same patient retry as an honest "not
    // now".
    try expectStay(advance(10, 20, .{ .ok = true, .cursor = 10 }));
    try expectStay(advance(0, 5, .{ .ok = true, .cursor = 0 }));
}

test "a cursor past what was sent is refused" {
    try expectViolation(advance(10, 20, .{ .ok = true, .cursor = 21 }));
    try expectViolation(advance(10, 20, .{ .ok = true, .cursor = 1200 }));
}

test "a cursor behind what was already confirmed is refused too" {
    // Only the greeting may ask to be sent old messages again. Here it is
    // a position the plugin confirmed once already, and taking it would
    // have the two of us stepping back and forth for ever.
    try expectViolation(advance(10, 20, .{ .ok = true, .cursor = 9 }));
    try expectViolation(advance(10, 20, .{ .ok = true, .cursor = 0 }));
}

test "a backoff doubles until it stops doubling" {
    var b: Backoff = .{};
    try testing.expectEqual(@as(u64, 1000), b.failed().?);
    try testing.expectEqual(@as(u64, 2000), b.failed().?);
    try testing.expectEqual(@as(u64, 4000), b.failed().?);
    try testing.expectEqual(@as(u64, 8000), b.failed().?);
    try testing.expectEqual(@as(u64, 16000), b.failed().?);
    try testing.expectEqual(@as(u64, 32000), b.failed().?);

    // Capped rather than doubled again: an hour between attempts would
    // mean the resident stays broken long after the reason went away.
    try testing.expectEqual(backoff_max_ms, b.failed().?);
    try testing.expectEqual(backoff_max_ms, b.failed().?);
}

test "a backoff gives up after ten tries, and a child that settles clears it" {
    var b: Backoff = .{};
    for (0..max_failures) |_| try testing.expect(b.failed() != null);

    // Not "gives up for good": the caller reads null as "go dormant", and
    // dormant is a quarter of an hour, not for ever.
    try testing.expect(b.failed() == null);

    b.settled();
    try testing.expectEqual(@as(u64, 1000), b.failed().?);

    // The configured start, not the constant, so that a test can watch a
    // restart rather than wait one out.
    var quick: Backoff = .{ .start_ms = 20, .ms = 20 };
    _ = quick.failed();
    _ = quick.failed();
    quick.settled();
    try testing.expectEqual(@as(u64, 20), quick.failed().?);
}

/// A window with two groups in it, the last message belonging to the group
/// nobody in these tests asked for.
const mixed: []const Feed.Event = &.{
    .{ .chat = .{ .n = 3, .seq = 30, .at_ms = 1000, .group = "build", .author = "worker-core", .text = "one" } },
    .{ .chat = .{ .n = 4, .seq = 40, .at_ms = 1001, .group = "ops", .author = "worker-ops", .text = "two" } },
    .{ .chat = .{ .n = 5, .seq = 50, .at_ms = 1002, .group = "build", .author = "worker-core", .summary = true, .text = "three" } },
    .{ .chat = .{ .n = 6, .seq = 60, .at_ms = 1003, .group = "ops", .author = "worker-ops", .text = "four" } },
};

/// A window holding one of each kind, for the tests about what a
/// subscription does and does not let through.
const every_kind: []const Feed.Event = &.{
    .{ .chat = .{ .n = 1, .seq = 10, .at_ms = 1000, .group = "build", .author = "worker-core", .text = "said" } },
    .{ .terminal_quiet = .{
        .n = 2,
        .at_ms = 1001,
        .reason = "authorisation",
        .title = "worker-core needs you",
        .body = "it is stopped on a tool prompt",
        .terminal = 0x9491465653644ed0,
        .terminal_name = "worker-core",
    } },
    .{ .provision = .{
        .n = 3,
        .at_ms = 1002,
        .exe = "/Applications/Polter.app/Contents/MacOS/polter",
        .version = "0.3.0",
        .version_key = "POLTER_REGISTERED",
        .home = "/home/somebody",
        .skills = &.{.{ .name = "supervising", .path = "/res/supervising.md" }},
    } },
};

test "a batch reaches through the messages that were filtered out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const line = try renderBatch(alloc, 2, 6, mixed, .{
        .events = &.{.chat},
        .groups = &.{"build"},
    });

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{});
    const obj = parsed.object;

    try testing.expectEqual(@as(i64, 2), obj.get("cursor").?.integer);

    // The whole point of the field: the window ended on somebody else's
    // message, and without this the plugin could never confirm past it.
    try testing.expectEqual(@as(i64, 6), obj.get("through").?.integer);

    const messages = obj.get("events").?.array;
    try testing.expectEqual(@as(usize, 2), messages.items.len);
    try testing.expectEqual(@as(i64, 3), messages.items[0].object.get("n").?.integer);
    try testing.expectEqual(@as(i64, 5), messages.items[1].object.get("n").?.integer);

    // The chat log's own identity travels beside the cursor's number and is
    // not it. A plugin stores against `seq`; it confirms against `n`.
    try testing.expectEqual(@as(i64, 30), messages.items[0].object.get("seq").?.integer);
    try testing.expectEqualStrings("chat", messages.items[0].object.get("kind").?.string);
    try testing.expect(std.mem.indexOf(u8, line, "\"ops\"") == null);
}

test "a star takes every group, and no message carries a terminal handle" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const line = try renderBatch(alloc, 2, 6, mixed, .{
        .events = &.{.chat},
        .groups = &.{"*"},
    });
    try testing.expect(line[line.len - 1] == '\n');

    // A `Bus.Id` means something for one run of one process. A column of
    // them in somebody's database is a foreign key to nothing.
    try testing.expect(std.mem.indexOf(u8, line, "\"from\"") == null);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{});
    const messages = parsed.object.get("events").?.array;
    try testing.expectEqual(@as(usize, 4), messages.items.len);

    // Said only when true, so that a plugin storing the night can tell a
    // summary the supervisor wrote from something a person said.
    try testing.expect(messages.items[0].object.get("summary") == null);
    try testing.expectEqual(true, messages.items[2].object.get("summary").?.bool);

    try testing.expectEqual(@as(i64, 1000), messages.items[0].object.get("at_ms").?.integer);
    try testing.expectEqualStrings("worker-core", messages.items[0].object.get("author").?.string);
    try testing.expectEqualStrings("one", messages.items[0].object.get("text").?.string);
}

test "an acknowledgement that is not an object is not an acknowledgement" {
    const alloc = testing.allocator;

    try testing.expect(parseAck(alloc, "[]") == null);
    try testing.expect(parseAck(alloc, "7") == null);
    try testing.expect(parseAck(alloc, "\"yes\"") == null);
    try testing.expect(parseAck(alloc, "") == null);
    try testing.expect(parseAck(alloc, "{") == null);
    try testing.expect(parseAck(alloc, "not json at all") == null);

    // Two answers on one line is a plugin bug, and it has to read as a
    // violation rather than take the terminal down with an assertion.
    try testing.expect(parseAck(alloc, "{\"ok\":true} {\"ok\":false}") == null);

    // An object, whatever else is in it: a field this build has never
    // heard of is how the protocol grows without breaking anybody.
    const ack = parseAck(alloc, "{\"ok\":true,\"cursor\":42,\"stored\":9}").?;
    try testing.expectEqual(true, ack.ok);
    try testing.expectEqual(@as(?u64, 42), ack.cursor);

    // Anything that is not what the field is supposed to be reads as
    // absent, and absent `ok` reads as no.
    try testing.expectEqual(false, parseAck(alloc, "{}").?.ok);
    try testing.expectEqual(false, parseAck(alloc, "{\"ok\":\"yes\"}").?.ok);
    try testing.expect(parseAck(alloc, "{\"ok\":true,\"cursor\":\"9\"}").?.cursor == null);
    try testing.expect(parseAck(alloc, "{\"ok\":true,\"cursor\":1.5}").?.cursor == null);
    try testing.expect(parseAck(alloc, "{\"ok\":true,\"cursor\":-1}").?.cursor == null);
}

test "the archive plugin we ship answers the greeting the host really writes" {
    // The regression this file exists to keep: `Resident` arms a deadline,
    // writes `renderHello`, and **waits for a line back**. A plugin that
    // reads the greeting and then waits for a batch never answers, is
    // killed on `timeout_ms`, restarted, and killed again -- from the
    // outside, a restart loop every `timeout_ms` + backoff, and from
    // inside the plugin, indistinguishable from sitting idle. The shipped
    // `plugins/archive/archive.py` did exactly that for one revision.
    //
    // So this runs **the script we ship** against **the bytes we send**.
    // Neither half can be stubbed: a hand-written handshake proves the
    // plugin agrees with whoever wrote the test, and a fake plugin proves
    // the host agrees with itself. Embedded rather than read off disk,
    // for the reason the manifest is: a test that goes to the filesystem
    // passes once the file is gone.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-shipped-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const store = try std.fmt.allocPrint(alloc, "{s}/store", .{dir});

    {
        var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
        defer d.close(io);
        var f = try d.createFile(io, "archive.py", .{ .permissions = .fromMode(0o755) });
        try f.writeStreamingAll(io, @embedFile("plugin_archive_py"));
        f.close(io);
    }

    const exec = try std.fmt.allocPrint(alloc, "{s}/archive.py", .{dir});

    var child = std.process.spawn(io, .{
        .argv = &.{exec},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch return error.SkipZigTest; // no python3 on this machine

    // The clock is the assertion's other half: without it, a plugin that
    // never answers hangs this test instead of failing it, and a test that
    // hangs is a test nobody keeps.
    var reaper: reap.Reaper = .init(io, "archive", child.id, 15 * std.time.ms_per_s);
    const keeper = std.Thread.spawn(.{}, reap.Reaper.run, .{&reaper}) catch null;
    defer {
        reaper.retire();
        if (keeper) |t| t.join();
    }

    const params: []const Plugin.Param = &.{.{ .name = "dir", .value = store }};
    const hello = try renderHello(alloc, .{
        .key = "archive",
        .cursor = 0,
        .wants = .{ .events = &.{.chat}, .groups = &.{"*"} },
        .params = params,
        .values = &.{store},
    });

    const stdin = child.stdin.?;
    var reader = child.stdout.?.readerStreaming(io, try alloc.alloc(u8, 64 * 1024));

    try stdin.writeStreamingAll(io, hello);

    const greeting = switch (readLine(&reader)) {
        .got => |l| l,
        else => {
            _ = child.wait(io) catch {};
            return error.PluginNeverAnsweredTheGreeting;
        },
    };
    const ack = parseAck(alloc, greeting) orelse {
        _ = child.wait(io) catch {};
        return error.GreetingWasNotAnAcknowledgement;
    };
    try testing.expect(ack.ok);

    // And one real batch, because an answer to the greeting alone would
    // still leave "it acknowledges but stores nothing" possible.
    const events: []const Feed.Event = &.{.{ .chat = .{
        .n = 11,
        .seq = 110,
        .at_ms = 1786819271275,
        .group = "build",
        .author = "worker-core",
        .text = "hello",
    } }};
    const batch = try renderBatch(alloc, 0, 11, events, .{
        .events = &.{.chat},
        .groups = &.{"*"},
    });
    try stdin.writeStreamingAll(io, batch);

    const answered = switch (readLine(&reader)) {
        .got => |l| l,
        else => {
            _ = child.wait(io) catch {};
            return error.PluginNeverAnsweredTheBatch;
        },
    };
    try testing.expect(parseAck(alloc, answered).?.ok);

    stdin.close(io);
    child.stdin = null;
    _ = child.wait(io) catch {};

    try testing.expect(!reaper.killed());

    // It said yes, so something must be on disk under the directory the
    // greeting named.
    var d = try std.Io.Dir.cwd().openDir(io, store, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    var files: usize = 0;
    while (try it.next(io)) |_| files += 1;
    try testing.expectEqual(@as(usize, 1), files);
}

test "the opening line carries the subscription, the socket and the resolved values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const params: []const Plugin.Param = &.{
        .{ .name = "backend", .value = "postgres" },
        .{ .name = "dsn", .value = "op://vault/dsn" },
    };
    const values: []const []const u8 = &.{ "postgres", "postgres://real" };

    const line = try renderHello(alloc, .{
        .key = "chat-archive",
        .cursor = 900,
        .wants = .{
            .events = &.{ .chat, .terminal_quiet },
            .calls = &.{"terminal_read"},
            .groups = &.{ "build", "ops" },
        },
        .socket = "/tmp/polter-abc.sock",
        .token = "f" ** 64,
        .params = params,
        .values = values,
    });
    try testing.expect(line[line.len - 1] == '\n');

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{});
    const obj = parsed.object;

    try testing.expectEqual(@as(i64, 1), obj.get("hello").?.integer);
    try testing.expectEqualStrings("chat-archive", obj.get("plugin").?.string);
    try testing.expectEqual(@as(i64, 900), obj.get("cursor").?.integer);

    const groups = obj.get("groups").?.array;
    try testing.expectEqual(@as(usize, 2), groups.items.len);
    try testing.expectEqualStrings("build", groups.items[0].string);

    // What it will be handed, and what it will be allowed to ask for, said
    // in the greeting rather than left to be inferred from what turns up
    // and what gets refused.
    const events = obj.get("events").?.array;
    try testing.expectEqual(@as(usize, 2), events.items.len);
    try testing.expectEqualStrings("chat", events.items[0].string);
    try testing.expectEqualStrings("terminal.quiet", events.items[1].string);

    const calls = obj.get("calls").?.array;
    try testing.expectEqual(@as(usize, 1), calls.items.len);
    try testing.expectEqualStrings("terminal_read", calls.items[0].string);

    // The same socket and the same kind of token an agent gets. This is
    // what "a plugin and an agent are two doors onto one surface" is, in
    // the only place it can be checked.
    try testing.expectEqualStrings("/tmp/polter-abc.sock", obj.get("socket").?.string);
    try testing.expectEqual(@as(usize, 64), obj.get("token").?.string.len);

    // The resolved value, never the reference: a plugin handed
    // `op://vault/dsn` would have to fetch it itself, which is the whole
    // thing `secret.zig` exists to stop.
    const got = obj.get("params").?.object;
    try testing.expectEqualStrings("postgres://real", got.get("dsn").?.string);
    try testing.expectEqualStrings("postgres", got.get("backend").?.string);
}

/// Write a throwaway script and give back its path, owned by `arena`.
fn scriptFor(arena: Allocator, io: std.Io, body: []const u8) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);

    const dir = try std.fmt.allocPrint(arena, "/tmp/polter-arch-plug-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);

    var f = try d.createFile(io, "run.sh", .{ .permissions = .fromMode(0o755) });
    try f.writeStreamingAll(io, body);
    f.close(io);

    return std.fmt.allocPrint(arena, "{s}/run.sh", .{dir});
}

/// A throwaway directory for a test plugin to write into, owned by
/// `arena`. Nothing of Polter's lives in it any more: a resident opens no
/// file of its own.
fn scratchDir(arena: Allocator, io: std.Io) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);

    const dir = try std.fmt.allocPrint(arena, "/tmp/polter-arch-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

/// The three messages every feeding test uses, published live.
///
/// Published *after* `start`, which is not a detail: a subscription begins
/// when it is made, so anything said before there was a plugin is not the
/// plugin's to see. That is the whole shape of the change -- there is no
/// backlog in a file for it to be caught up from.
fn saySomething(feed: *Feed) void {
    feed.publish(.{ .chat = .{
        .seq = 1,
        .at_ms = 1000,
        .group = "build",
        .author = "worker-core",
        .text = "one",
    } });
    feed.publish(.{ .chat = .{
        .seq = 2,
        .at_ms = 1001,
        .group = "ops",
        .author = "worker-ops",
        .text = "two",
    } });
    feed.publish(.{ .chat = .{
        .seq = 3,
        .at_ms = 1002,
        .group = "build",
        .author = "worker-core",
        .summary = true,
        .text = "three",
    } });
}

/// How many lines a file the plugin wrote holds, treating "not there yet"
/// as none.
fn linesIn(alloc: Allocator, io: std.Io, path: []const u8) usize {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        alloc,
        .limited(1024 * 1024),
    ) catch return 0;
    defer alloc.free(bytes);
    return std.mem.count(u8, bytes, "\n");
}

/// Everything a plugin wrote down, or nothing if it has written nothing.
fn contentsOf(alloc: Allocator, io: std.Io, path: []const u8) []const u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        alloc,
        .limited(1024 * 1024),
    ) catch "";
}

/// Wait for a plugin to have written `want` lines, and say whether it did.
fn waitForLines(
    alloc: Allocator,
    io: std.Io,
    path: []const u8,
    want: usize,
    limit_ms: u64,
) bool {
    var waited: u64 = 0;
    while (waited < limit_ms) : (waited += 25) {
        if (linesIn(alloc, io, path) >= want) return true;
        std.Io.sleep(io, .fromMilliseconds(25), .awake) catch return false;
    }
    return linesIn(alloc, io, path) >= want;
}

test "a resident that subscribes to nothing is not started" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Handed over without a `defer`, exactly as `App` does it. If `start`
    // did not free it on the way out, the leak turns up here.
    var feed: Feed = .init(testing.allocator, io);
    defer feed.deinit();

    var env: std.process.Environ.Map = .init(testing.allocator);
    try env.put("POLTER_TEST", "1");

    try testing.expectError(error.WantsNothing, start(testing.allocator, io, .{
        .key = "empty",
        .exec = "/nonexistent",
        .timeout_ms = 1000,
        .wants = .{},
        .params = &.{},
        .feed = &feed,
        .environ = env,
    }));
}

test "stopping a resident twice is stopping it once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratchDir(alloc, io);

    var feed: Feed = .init(testing.allocator, io);
    defer feed.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const exec = try scriptFor(alloc, io,
        \\#!/bin/sh
        \\while IFS= read -r line; do
        \\  echo '{"ok":true}'
        \\done
    );

    const env: std.process.Environ.Map = .init(testing.allocator);

    const a = try start(testing.allocator, io, .{
        .key = "twice",
        .exec = exec,
        .timeout_ms = 5 * std.time.ms_per_s,
        .wants = .{ .events = &.{.chat}, .groups = &.{"*"} },
        .params = &.{},
        .feed = &feed,
        .environ = env,
        .timing = .{ .poll_idle_ms = 20 },
    });
    defer a.destroy();

    a.stop();
    try testing.expectEqual(State.stopped, a.status().state);

    // Twice, and from `destroy` a third time. Shutdown runs from more than
    // one place -- the app's own teardown and a config reload that drops a
    // plugin -- and joining a thread that has already been joined is not
    // something to find out about in the field.
    a.stop();
    try testing.expectEqual(State.stopped, a.status().state);
}

test "a plugin is fed what happens and the cursor follows it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratchDir(alloc, io);

    var feed: Feed = .init(testing.allocator, io);
    defer feed.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const got = try std.fmt.allocPrint(alloc, "{s}/got.jsonl", .{dir});
    const exec = try scriptFor(alloc, io, try std.fmt.allocPrint(alloc,
        \\#!/bin/sh
        \\while IFS= read -r line; do
        \\  case "$line" in *'"hello"'*) echo '{{"ok":true}}'; continue;; esac
        \\  printf '%s\n' "$line" >> {s}
        \\  echo '{{"ok":true}}'
        \\done
    , .{got}));

    const env: std.process.Environ.Map = .init(testing.allocator);

    const a = try start(testing.allocator, io, .{
        .key = "fed",
        .exec = exec,
        .timeout_ms = 5 * std.time.ms_per_s,
        .wants = .{ .events = &.{.chat}, .groups = &.{"*"} },
        .params = &.{},
        .feed = &feed,
        .environ = env,
        .timing = .{ .poll_idle_ms = 20, .heartbeat_ms = 10 * std.time.ms_per_s },
    });
    defer a.destroy();

    // After the plugin exists, never before: a subscription starts empty,
    // and there is no file for it to be caught up from.
    saySomething(&feed);

    try testing.expect(waitForLines(alloc, io, got, 1, 5000));

    const batch = contentsOf(alloc, io, got);
    try testing.expect(std.mem.indexOf(u8, batch, "\"text\":\"one\"") != null);
    try testing.expect(std.mem.indexOf(u8, batch, "\"text\":\"three\"") != null);

    // The cursor is a promise about what has been stored, and the plugin
    // has just said it stored all three.
    var waited: u64 = 0;
    while (waited < 2000 and a.status().cursor < 3) : (waited += 25) {
        std.Io.sleep(io, .fromMilliseconds(25), .awake) catch break;
    }
    try testing.expectEqual(@as(u64, 3), a.status().cursor);
}

test "a plugin that confirms half a batch is sent the rest again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratchDir(alloc, io);

    var feed: Feed = .init(testing.allocator, io);
    defer feed.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // Never gets past the first message, whatever it is sent. Everything
    // after it is unconfirmed and must keep coming back -- nothing is
    // committed, so what comes back can only be the subscription still
    // holding what nobody stored.
    const got = try std.fmt.allocPrint(alloc, "{s}/got.jsonl", .{dir});
    const exec = try scriptFor(alloc, io, try std.fmt.allocPrint(alloc,
        \\#!/bin/sh
        \\while IFS= read -r line; do
        \\  case "$line" in *'"hello"'*) echo '{{"ok":true}}'; continue;; esac
        \\  printf '%s\n' "$line" >> {s}
        \\  echo '{{"ok":true,"cursor":1}}'
        \\done
    , .{got}));

    const env: std.process.Environ.Map = .init(testing.allocator);

    const a = try start(testing.allocator, io, .{
        .key = "half",
        .exec = exec,
        .timeout_ms = 5 * std.time.ms_per_s,
        .wants = .{ .events = &.{.chat}, .groups = &.{"*"} },
        .params = &.{},
        .feed = &feed,
        .environ = env,
        .timing = .{ .poll_idle_ms = 20, .heartbeat_ms = 10 * std.time.ms_per_s },
    });
    defer a.destroy();

    // After the plugin exists, never before: a subscription starts empty,
    // and there is no file for it to be caught up from.
    saySomething(&feed);

    try testing.expect(waitForLines(alloc, io, got, 2, 5000));

    const batches = contentsOf(alloc, io, got);
    try testing.expect(std.mem.count(u8, batches, "\"seq\":2") >= 2);
    try testing.expect(std.mem.count(u8, batches, "\"seq\":3") >= 2);

    // Exactly where it said it had got to, and not one message further.
    try testing.expectEqual(@as(u64, 1), a.status().cursor);
}

test "a plugin that answers with nonsense is stopped and started again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratchDir(alloc, io);

    var feed: Feed = .init(testing.allocator, io);
    defer feed.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // One line per start, so that "it was started again" is something the
    // test can see rather than infer. The nonsense comes back on a
    // heartbeat, which is why this one needs no messages at all.
    const starts = try std.fmt.allocPrint(alloc, "{s}/starts", .{dir});
    const exec = try scriptFor(alloc, io, try std.fmt.allocPrint(alloc,
        \\#!/bin/sh
        \\echo started >> {s}
        \\while IFS= read -r line; do
        \\  case "$line" in *'"hello"'*) echo '{{"ok":true}}'; continue;; esac
        \\  echo 'not an acknowledgement'
        \\done
    , .{starts}));

    const env: std.process.Environ.Map = .init(testing.allocator);

    const a = try start(testing.allocator, io, .{
        .key = "nonsense",
        .exec = exec,
        .timeout_ms = 5 * std.time.ms_per_s,
        .wants = .{ .events = &.{.chat}, .groups = &.{"*"} },
        .params = &.{},
        .feed = &feed,
        .environ = env,
        .timing = .{
            .poll_idle_ms = 10,
            .heartbeat_ms = 30,
            .backoff_start_ms = 10,
            .settle_ms = 60 * std.time.ms_per_s,
            .dormant_retry_ms = 500,
        },
    });
    defer a.destroy();

    try testing.expect(waitForLines(alloc, io, starts, 2, 10_000));
    try testing.expect(a.status().failures >= 1);
}

test "a plugin that dies before answering is sent the same batch again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratchDir(alloc, io);

    var feed: Feed = .init(testing.allocator, io);
    defer feed.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // Takes a batch and dies holding it, which is the case a queue has to
    // get right: the events were handed over, and nobody stored them.
    const got = try std.fmt.allocPrint(alloc, "{s}/got.jsonl", .{dir});
    const exec = try scriptFor(alloc, io, try std.fmt.allocPrint(alloc,
        \\#!/bin/sh
        \\read -r hello
        \\echo '{{"ok":true}}'
        \\read -r batch
        \\printf '%s\n' "$batch" >> {s}
        \\exit 0
    , .{got}));

    const env: std.process.Environ.Map = .init(testing.allocator);

    const a = try start(testing.allocator, io, .{
        .key = "dies",
        .exec = exec,
        .timeout_ms = 5 * std.time.ms_per_s,
        .wants = .{ .events = &.{.chat}, .groups = &.{"*"} },
        .params = &.{},
        .feed = &feed,
        .environ = env,
        .timing = .{
            .poll_idle_ms = 20,
            .heartbeat_ms = 10 * std.time.ms_per_s,
            .backoff_start_ms = 20,
        },
    });
    defer a.destroy();

    // After the plugin exists, never before: a subscription starts empty,
    // and there is no file for it to be caught up from.
    saySomething(&feed);

    try testing.expect(waitForLines(alloc, io, got, 2, 10_000));

    // Every one of them the same batch, from the same cursor. A queue that
    // dropped what it handed over would have sent the next batch instead,
    // and the three messages nobody stored would be gone with nothing to
    // show it.
    const batches = contentsOf(alloc, io, got);
    var it = std.mem.tokenizeScalar(u8, batches, '\n');
    var seen: usize = 0;
    while (it.next()) |line| {
        seen += 1;
        try testing.expect(std.mem.indexOf(u8, line, "\"cursor\":0") != null);
        try testing.expect(std.mem.indexOf(u8, line, "\"seq\":1") != null);
    }
    try testing.expect(seen >= 2);

    try testing.expectEqual(@as(u64, 0), a.status().cursor);
}

test "a plugin with nothing to do is not killed for having nothing to do" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratchDir(alloc, io);

    var feed: Feed = .init(testing.allocator, io);
    defer feed.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // One line per start. A well behaved plugin that answers everything it
    // is given must write exactly one, however long the quiet stretch
    // between batches is.
    const starts = try std.fmt.allocPrint(alloc, "{s}/starts", .{dir});
    const exec = try scriptFor(alloc, io, try std.fmt.allocPrint(alloc,
        \\#!/bin/sh
        \\echo started >> {s}
        \\while IFS= read -r line; do
        \\  echo '{{"ok":true}}'
        \\done
    , .{starts}));

    const env: std.process.Environ.Map = .init(testing.allocator);

    // The shape every real manifest has: a timeout shorter than the gap
    // between heartbeats. The deadline bounds one exchange, and a plugin
    // sitting through several of these gaps has done nothing wrong.
    const a = try start(testing.allocator, io, .{
        .key = "idle",
        .exec = exec,
        .timeout_ms = 200,
        .wants = .{ .events = &.{.chat}, .groups = &.{"*"} },
        .params = &.{},
        .feed = &feed,
        .environ = env,
        .timing = .{ .poll_idle_ms = 20, .heartbeat_ms = 400 },
    });
    defer a.destroy();

    // After the plugin exists, never before: a subscription starts empty,
    // and there is no file for it to be caught up from.
    saySomething(&feed);

    try testing.expect(waitForLines(alloc, io, starts, 1, 5000));

    // Long enough for several heartbeats to come and go.
    std.Io.sleep(io, .fromMilliseconds(2000), .awake) catch {};

    try testing.expectEqual(@as(usize, 1), linesIn(alloc, io, starts));
    try testing.expectEqual(@as(u32, 0), a.status().failures);
    try testing.expectEqual(State.feeding, a.status().state);
}

// -- what a subscription is worth -------------------------------------------
//
// `wants.events` is the whole of what `Kind` used to decide, so it is the one
// declaration that has to be *enforced* rather than disclosed. These are
// about the enforcement and nothing else: given a window holding one of each
// kind, a plugin sees the ones it asked for and none of the others.

test "a plugin subscribed to one kind is not handed another" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // What `archive` was.
    {
        const line = try renderBatch(alloc, 0, 3, every_kind, .{
            .events = &.{.chat},
            .groups = &.{"*"},
        });
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{});
        const events = parsed.object.get("events").?.array;

        try testing.expectEqual(@as(usize, 1), events.items.len);
        try testing.expectEqualStrings("chat", events.items[0].object.get("kind").?.string);

        // Not merely absent from the array: absent from the bytes. A plugin
        // that never asked for notifications must not be able to read one
        // out of a field somebody added later.
        try testing.expect(std.mem.indexOf(u8, line, "authorisation") == null);
        try testing.expect(std.mem.indexOf(u8, line, "POLTER_REGISTERED") == null);

        // `through` still reaches past what was filtered out, or a plugin
        // could never confirm past somebody else's traffic.
        try testing.expectEqual(@as(i64, 3), parsed.object.get("through").?.integer);
    }

    // What `notify` was.
    {
        const line = try renderBatch(alloc, 0, 3, every_kind, .{
            .events = &.{.terminal_quiet},
        });
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{});
        const events = parsed.object.get("events").?.array;

        try testing.expectEqual(@as(usize, 1), events.items.len);
        try testing.expectEqualStrings(
            "terminal.quiet",
            events.items[0].object.get("kind").?.string,
        );

        // It named no groups and is handed its notification all the same:
        // a notification is in no group, and requiring `"groups": ["*"]`
        // from every notifier would be a rule with no reason behind it.
        try testing.expect(std.mem.indexOf(u8, line, "\"said\"") == null);
    }

    // What `provision` was.
    {
        const line = try renderBatch(alloc, 0, 3, every_kind, .{
            .events = &.{.provision},
        });
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{});
        const events = parsed.object.get("events").?.array;

        try testing.expectEqual(@as(usize, 1), events.items.len);
        try testing.expectEqualStrings(
            "provision",
            events.items[0].object.get("kind").?.string,
        );
        try testing.expectEqualStrings(
            "POLTER_REGISTERED",
            events.items[0].object.get("version_key").?.string,
        );
    }

    // Two at once, on one stream, in the one order there is. Under `Kind`
    // this took two plugins; the numbers are the point -- a cursor counts
    // across kinds, so `n` is 1 and 2 and not 1 and 1.
    {
        const line = try renderBatch(alloc, 0, 3, every_kind, .{
            .events = &.{ .chat, .terminal_quiet },
            .groups = &.{"*"},
        });
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{});
        const events = parsed.object.get("events").?.array;

        try testing.expectEqual(@as(usize, 2), events.items.len);
        try testing.expectEqual(@as(i64, 1), events.items[0].object.get("n").?.integer);
        try testing.expectEqual(@as(i64, 2), events.items[1].object.get("n").?.integer);
    }

    // And a plugin that subscribed to nothing is handed nothing, which is
    // why `start` refuses one rather than running it empty for ever.
    {
        const line = try renderBatch(alloc, 0, 3, every_kind, .{ .groups = &.{"*"} });
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{});
        try testing.expectEqual(@as(usize, 0), parsed.object.get("events").?.array.items.len);
    }
}

test "the two gates are asked in the order that makes both mean something" {
    // `forThisPlugin` is the one filter, and both the "is there anything to
    // send" check and the renderer go through it. Two copies of a filter is
    // how the header of a batch comes to disagree with its body.
    const chat_only: Plugin.Wants = .{ .events = &.{.chat}, .groups = &.{"build"} };

    try testing.expect(forThisPlugin(every_kind[0], chat_only));
    try testing.expect(!forThisPlugin(every_kind[1], chat_only));
    try testing.expect(!forThisPlugin(every_kind[2], chat_only));

    // Subscribed to chat, wrong group: refused by the second gate.
    const elsewhere: Plugin.Wants = .{ .events = &.{.chat}, .groups = &.{"ops"} };
    try testing.expect(!forThisPlugin(every_kind[0], elsewhere));

    // Subscribed to notifications and naming no groups: let through, because
    // the group gate only applies to events that have a group.
    const notifier: Plugin.Wants = .{ .events = &.{.terminal_quiet} };
    try testing.expect(forThisPlugin(every_kind[1], notifier));
    try testing.expect(!forThisPlugin(every_kind[0], notifier));

    // The group gate is not skipped for a chat event just because the
    // plugin also subscribes to something groupless.
    const mixed_wants: Plugin.Wants = .{
        .events = &.{ .chat, .terminal_quiet },
        .groups = &.{},
    };
    try testing.expect(!forThisPlugin(every_kind[0], mixed_wants));
    try testing.expect(forThisPlugin(every_kind[1], mixed_wants));

    // And `anyAllowed` agrees with it, window by window, which is what
    // stops a window belonging entirely to somebody else costing a pipe.
    try testing.expect(!anyAllowed(every_kind[0..1], notifier));
    try testing.expect(anyAllowed(every_kind, notifier));
    try testing.expect(!anyAllowed(every_kind, .{}));
}

// -- telling the person -----------------------------------------------------
//
// A plugin failing is not only a log line. What fails when one fails is
// either the agent's tool surface or the user's own channel of being told
// anything -- and in the first case the agent is the one party that cannot
// be told. So the failure has to leave this thread and reach a screen, and
// these are about which failures do and how often.

/// Collects what a resident says, the way `App` collects it: on whatever
/// thread the resident calls from, under a lock, copying as it goes.
const Heard = struct {
    alloc: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    lines: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Heard) void {
        for (self.lines.items) |l| self.alloc.free(l);
        self.lines.deinit(self.alloc);
    }

    fn say(ctx: *anyopaque, line: []const u8) void {
        const self: *Heard = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const owned = self.alloc.dupe(u8, line) catch return;
        self.lines.append(self.alloc, owned) catch self.alloc.free(owned);
    }

    fn count(self: *Heard) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.lines.items.len;
    }

    /// Whether any line so far holds `needle`.
    fn heard(self: *Heard, needle: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (self.lines.items) |l| {
            if (std.mem.indexOf(u8, l, needle) != null) return true;
        }
        return false;
    }

    fn hook(self: *Heard) Alert {
        return .{ .ctx = self, .func = say };
    }
};

/// Everything in a plugin's log file, or nothing when there is not one yet.
fn logOf(alloc: Allocator, io: std.Io, dir: []const u8, key: []const u8) []const u8 {
    const path = std.fmt.allocPrint(alloc, "{s}/{s}.log", .{ dir, key }) catch return "";
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        alloc,
        .limited(4 * 1024 * 1024),
    ) catch "";
}

/// Wait until `want` is true, or give up. Polled rather than signalled,
/// like everything else that watches a resident from outside.
fn waitFor(
    io: std.Io,
    ctx: anytype,
    comptime want: fn (@TypeOf(ctx)) bool,
    ms: u64,
) bool {
    var waited: u64 = 0;
    while (waited < ms) {
        if (want(ctx)) return true;
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch return false;
        waited += 20;
    }
    return want(ctx);
}

test "a plugin that will not start is put on the user's screen, once" {
    // The requirement in the user's own words: if a plugin fails at
    // startup, **tell them**. A log line is not telling them, and
    // `plugin_list` is telling the agent -- which for a provisioning
    // plugin is precisely the party that did not get the tools.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var feed: Feed = .init(testing.allocator, io);
    defer feed.deinit();

    var heard: Heard = .{ .alloc = testing.allocator, .io = io };
    defer heard.deinit();

    const env: std.process.Environ.Map = .init(testing.allocator);

    const a = try start(testing.allocator, io, .{
        .key = "claude-code",
        .exec = "/nonexistent/plugin",
        .timeout_ms = 500,
        .wants = .{ .events = &.{.provision} },
        .params = &.{},
        .feed = &feed,
        .environ = env,
        .alert = heard.hook(),
        .timing = .{
            .poll_idle_ms = 10,
            .heartbeat_ms = 30,
            .backoff_start_ms = 5,
            .settle_ms = 60 * std.time.ms_per_s,

            // Short, so the dormant line arrives inside a test rather than
            // a quarter of an hour later. It doubles as the floor under
            // repeated `stopped` lines, which is what the count below is
            // measuring.
            .dormant_retry_ms = 5 * std.time.ms_per_s,
        },
    });
    defer a.destroy();

    const seen = struct {
        fn one(h: *Heard) bool {
            return h.count() >= 1;
        }
    };
    try testing.expect(waitFor(io, &heard, seen.one, 5_000));

    // The consequence, not only the fault. A user reading "claude-code
    // failed" has to work out for themselves that the agent they are about
    // to start has no tools.
    try testing.expect(heard.heard("claude-code"));
    try testing.expect(heard.heard("no Polter tools"));

    // **Once, not once per retry.** This plugin cannot start at all, so it
    // is failing every few milliseconds; by the time it has failed ten
    // times and gone dormant there must still be exactly one `stopped`
    // line. Telling somebody the same thing ten times is telling them once,
    // badly, and it buries the second plugin's failure.
    const dormant = struct {
        fn yet(h: *Heard) bool {
            return h.heard("fifteen minutes");
        }
    };
    try testing.expect(waitFor(io, &heard, dormant.yet, 10_000));

    // Two lines and no more: the first failure, and giving up. Those are
    // two different facts. Everything in between is the first line said
    // again.
    try testing.expectEqual(@as(usize, 2), heard.count());
}

test "a plugin that never fails never says anything" {
    // The other half, and the one that decides whether the count above is
    // measuring anything: a working plugin must put nothing on the user's
    // screen. A terminal that greets its owner with a report every launch
    // is one whose reports stop being read.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratchDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var feed: Feed = .init(testing.allocator, io);
    defer feed.deinit();

    var heard: Heard = .{ .alloc = testing.allocator, .io = io };
    defer heard.deinit();

    const beats = try std.fmt.allocPrint(alloc, "{s}/beats", .{dir});
    const exec = try scriptFor(alloc, io, try std.fmt.allocPrint(alloc,
        \\#!/bin/sh
        \\while IFS= read -r line; do
        \\  echo beat >> {s}
        \\  echo '{{"ok":true}}'
        \\done
    , .{beats}));

    const env: std.process.Environ.Map = .init(testing.allocator);

    const a = try start(testing.allocator, io, .{
        .key = "fine",
        .exec = exec,
        .timeout_ms = 5 * std.time.ms_per_s,
        .wants = .{ .events = &.{.chat}, .groups = &.{"*"} },
        .params = &.{},
        .feed = &feed,
        .environ = env,
        .alert = heard.hook(),
        .timing = .{
            .poll_idle_ms = 10,
            .heartbeat_ms = 30,
            .backoff_start_ms = 10,
            .settle_ms = 60 * std.time.ms_per_s,
            .dormant_retry_ms = 500,
        },
    });
    defer a.destroy();

    // Several exchanges, so this has really run rather than merely not
    // crashed yet.
    try testing.expect(waitForLines(alloc, io, beats, 3, 10_000));
    try testing.expectEqual(@as(usize, 0), heard.count());
    try testing.expectEqual(@as(u32, 0), a.status().failures);
}

test "what a plugin printed, and what Polter did to it, are in one file" {
    // The request in the user's own words: "check the plugin's log and the
    // errors". Before this, a plugin's standard error was inherited --
    // which inside a packaged app means it went nowhere anybody could read
    // -- and there was no plugin log anywhere in the repository. Both
    // halves are here because the question is "what happened to this
    // plugin", and an answer split across two files with two clocks is one
    // the reader has to assemble.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratchDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var feed: Feed = .init(testing.allocator, io);
    defer feed.deinit();

    const beats = try std.fmt.allocPrint(alloc, "{s}/beats", .{dir});
    const exec = try scriptFor(alloc, io, try std.fmt.allocPrint(alloc,
        \\#!/bin/sh
        \\echo "could not reach the database" >&2
        \\while IFS= read -r line; do
        \\  echo beat >> {s}
        \\  echo '{{"ok":true}}'
        \\done
    , .{beats}));

    const env: std.process.Environ.Map = .init(testing.allocator);

    const a = try start(testing.allocator, io, .{
        .key = "noisy",
        .exec = exec,
        .timeout_ms = 5 * std.time.ms_per_s,
        .wants = .{ .events = &.{.chat}, .groups = &.{"*"} },
        .params = &.{},
        .feed = &feed,
        .environ = env,
        .log_dir = dir,
        .timing = .{
            .poll_idle_ms = 10,
            .heartbeat_ms = 30,
            .backoff_start_ms = 10,
            .settle_ms = 60 * std.time.ms_per_s,
            .dormant_retry_ms = 5 * std.time.ms_per_s,
        },
    });
    defer a.destroy();

    try testing.expect(waitForLines(alloc, io, beats, 2, 10_000));

    const body = logOf(alloc, io, dir, "noisy");

    // The plugin's own words, which nothing in this repository used to
    // keep anywhere.
    try testing.expect(std.mem.indexOf(u8, body, "could not reach the database") != null);

    // And the host's account of it beside them, so the file answers the
    // question on its own.
    try testing.expect(std.mem.indexOf(u8, body, "started") != null);
    try testing.expect(std.mem.indexOf(u8, body, "stderr") != null);
    try testing.expect(std.mem.indexOf(u8, body, "polter") != null);
}

test "a plugin can say something to the user, once, and it cannot draw with it" {
    // Three requirements in one, because they are one path: a plugin's own
    // report reaches the person; it is filtered, because that text is about
    // to be printed onto a terminal and a terminal is an interpreter; and
    // it is rationed, because a plugin failing in a loop must not fill the
    // screen a second plugin's failure has to be read on.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try scratchDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var feed: Feed = .init(testing.allocator, io);
    defer feed.deinit();

    var heard: Heard = .{ .alloc = testing.allocator, .io = io };
    defer heard.deinit();

    const beats = try std.fmt.allocPrint(alloc, "{s}/beats", .{dir});

    // It reports on every single exchange, which is the plugin this has to
    // survive: the one whose backend is down and which therefore has the
    // same thing to say for ever. The escape sequence is what it would
    // take to repaint somebody's screen and retitle their window.
    const exec = try scriptFor(alloc, io, try std.fmt.allocPrint(alloc,
        \\#!/bin/sh
        \\while IFS= read -r line; do
        \\  echo beat >> {s}
        \\  printf '%s\n' '{{"tell":"\u001b[2Jcould not write the skill file"}}'
        \\  printf '%s\n' '{{"ok":true}}'
        \\done
    , .{beats}));

    const env: std.process.Environ.Map = .init(testing.allocator);

    const a = try start(testing.allocator, io, .{
        .key = "claude-code",
        .exec = exec,
        .timeout_ms = 5 * std.time.ms_per_s,
        .wants = .{ .events = &.{.provision} },
        .params = &.{},
        .feed = &feed,
        .environ = env,
        .alert = heard.hook(),
        .log_dir = dir,
        .timing = .{
            .poll_idle_ms = 10,
            .heartbeat_ms = 30,
            .backoff_start_ms = 10,
            .settle_ms = 60 * std.time.ms_per_s,

            // The floor under repeated lines, and long enough that every
            // exchange below falls inside one window of it.
            .dormant_retry_ms = 60 * std.time.ms_per_s,
        },
    });
    defer a.destroy();

    // Four exchanges, so this is measuring a rule rather than a plugin that
    // has only had one chance to speak.
    try testing.expect(waitForLines(alloc, io, beats, 4, 10_000));

    // It arrived, attributed, in the plugin's own words.
    try testing.expect(heard.heard("could not write the skill file"));
    try testing.expect(heard.heard("claude-code"));
    try testing.expect(heard.heard("plugin says"));

    // It could not draw. This is the negative control for the filter: the
    // plugin really wrote an escape sequence, it really travelled the whole
    // path, and none of it reached the screen.
    try testing.expect(!heard.heard("\x1b"));

    // Once, not once per exchange.
    try testing.expectEqual(@as(usize, 1), heard.count());

    // **And nothing was lost by rationing the screen.** Every one of them
    // is in the log, which is the half that makes the throttle safe: a
    // plugin cannot make the record of its own failures disappear by
    // repeating them.
    const body = logOf(alloc, io, dir, "claude-code");
    try testing.expect(std.mem.count(u8, body, "could not write the skill file") >= 4);
    try testing.expect(std.mem.indexOfScalar(u8, body, 0x1b) == null);
}
