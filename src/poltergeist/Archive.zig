//! Feeding live events to a resident plugin, one batch at a time.
//!
//! **A plugin is handed what happens, not the core's own files.** What it
//! keeps is an extra copy, made from a live subscription (`Feed.zig`);
//! the core's stream, record and rotation are a core feature that stands
//! complete whether or not any plugin exists, and are never a plugin's
//! data source. This file therefore names no path, opens no log and keeps
//! no cursor file: change how the core stores things and nothing here has
//! to move. See `docs/poltergeist/storage.md`.
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
//! **Resident, unlike `notify`.** Chat is continuous, and rebuilding a
//! database connection per message is not a thing that can be done. The
//! price is a process to look after -- it will hang, it will die, it has to
//! be restarted and collected -- which is what most of this file is.
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
//!
//! There is no general "resident host" layer under this. That kind has
//! exactly one member today, and an interface guessed from one sample is
//! harder to change than no interface at all. What *was* pulled out is
//! `reap.zig`, because stopping a child is genuinely shared with the
//! one-shot lifetime.

const Archive = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Feed = @import("Feed.zig");
const Plugin = @import("Plugin.zig");
const reap = @import("reap.zig");
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

/// Restarts in a row before the archive goes dormant.
const max_failures: u32 = 10;

/// How long dormant lasts. Never forever: the usual reasons an archive
/// plugin cannot start -- the database is down, the laptop is off the
/// network, the vault is locked -- all fix themselves, and requiring the
/// user to restart Polter to pick that up would mean the archive is broken
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
    /// All of these are copied. After `start` the archive borrows nothing
    /// from the caller, so a config reload that rebuilds the plugin arena
    /// cannot pull the ground out from under the thread.
    key: []const u8,
    exec: []const u8,
    timeout_ms: u64,
    groups: []const []const u8,
    params: []const Plugin.Param,

    /// Where the events come from. Borrowed, and it has to outlive the
    /// archive: `destroy` unsubscribes from it.
    feed: *Feed,

    /// Taken over whole, on the failure paths too. See `start`.
    environ: std.process.Environ.Map,

    timing: Timing = .{},
};

pub const Error = Allocator.Error || error{
    /// The manifest asked for no groups, so there is nothing to feed it.
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
groups: []const []const u8,
params: []const Plugin.Param,
environ: std.process.Environ.Map,

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

/// Read by `status` from the main thread, written by the thread. Coarse on
/// purpose: it is for a log line and a future MCP tool, not for deciding
/// anything.
state: std.atomic.Value(State) = .init(.starting),
confirmed: std.atomic.Value(u64) = .init(0),
failures: std.atomic.Value(u32) = .init(0),
dropped: std.atomic.Value(u64) = .init(0),

/// Start feeding one archive plugin.
///
/// **`opts.environ` is taken over the moment this is called, on the failure
/// paths too.** There is no way for a caller to tell from the outside which
/// error paths freed it and which did not, so the rule is that all of them
/// do: hand the map over and never write a `defer` for it. An archive that
/// was refused has therefore been cleaned up after completely, and
/// `destroy` must not be called on one.
///
/// The archive is heap-allocated because the thread holds a pointer to it.
/// A caller that gets one back must `destroy` it, which stops the thread
/// first.
pub fn start(alloc: Allocator, io: std.Io, opts: Options) Error!*Archive {
    var environ = opts.environ;
    errdefer environ.deinit();

    // First, before anything is allocated. The caller checks this too, to
    // say something better about which plugin it was, but refusing here is
    // what makes "a plugin that wants nothing does not run" true rather
    // than merely observed.
    if (opts.groups.len == 0) return error.WantsNothing;

    const self = try alloc.create(Archive);
    errdefer alloc.destroy(self);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    const key = try a.dupe(u8, opts.key);
    const exec = try a.dupe(u8, opts.exec);

    const groups = try a.alloc([]const u8, opts.groups.len);
    for (opts.groups, groups) |src, *dst| dst.* = try a.dupe(u8, src);

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
        .groups = groups,
        .params = params,
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

    // Last. The thread dereferences `self` immediately, so nothing may
    // still be being written when it starts.
    self.thread = std.Thread.spawn(.{}, main, .{self}) catch {
        return error.NoThread;
    };

    return self;
}

/// Ask the thread to finish, take the child's stdin away, and join.
/// Idempotent.
pub fn stop(self: *Archive) void {
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
pub fn destroy(self: *Archive) void {
    // The thread first, and only then the subscription: giving it back
    // frees the queue the thread reads from.
    self.stop();
    self.feed.unsubscribe(self.sub);
    self.environ.deinit();
    self.arena.deinit();
    self.alloc.destroy(self);
}

pub fn status(self: *const Archive) Status {
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
    groups: []const []const u8,
) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    // The writer allocates, so the only way any of this fails is running
    // out of memory; saying that once beats saying it at every field.
    writeBatch(&s, cursor, through, events, groups) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;

    return out.toOwnedSlice();
}

fn writeBatch(
    s: *std.json.Stringify,
    cursor: u64,
    through: u64,
    events: []const Feed.Event,
    groups: []const []const u8,
) std.Io.Writer.Error!void {
    try s.beginObject();
    try s.objectField("cursor");
    try s.write(cursor);
    try s.objectField("through");
    try s.write(through);
    try s.objectField("messages");
    try s.beginArray();

    // The same matcher the host decides everything else with, rather than a
    // second copy of it: there is exactly one place where a group is
    // allowed or not.
    const wants: Plugin.Wants = .{ .groups = groups };

    // Switched over rather than assumed, so that the day a second kind of
    // event exists it is a branch that has to be written here rather than
    // a field silently rendered as though it were a message.
    for (events) |ev| switch (ev) {
        .chat => |e| {
            if (!wants.allows(e.group)) continue;

            try s.beginObject();
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
            try s.endObject();
        },
    };

    try s.endArray();
    try s.endObject();
}

/// Render the opening line, `\n` included. `params` must already be
/// resolved.
pub fn renderHello(
    alloc: Allocator,
    key: []const u8,
    cursor: u64,
    groups: []const []const u8,
    params: []const Plugin.Param,
    values: []const []const u8,
) Allocator.Error![]u8 {
    // The caller resolves in a loop, and a mismatch there would quietly
    // pair one parameter's name with another's secret.
    std.debug.assert(params.len == values.len);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    writeHello(&s, key, cursor, groups, params, values) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;

    return out.toOwnedSlice();
}

fn writeHello(
    s: *std.json.Stringify,
    key: []const u8,
    cursor: u64,
    groups: []const []const u8,
    params: []const Plugin.Param,
    values: []const []const u8,
) std.Io.Writer.Error!void {
    try s.beginObject();

    // The protocol version, and the only reason it is a number rather than
    // a marker: a plugin that does not know this one can say so by exiting
    // instead of guessing at the rest of the line.
    try s.objectField("hello");
    try s.write(1);

    try s.objectField("plugin");
    try s.write(key);
    try s.objectField("cursor");
    try s.write(cursor);

    // Copied over so a plugin can check for itself what it is going to be
    // shown, rather than inferring it from what turns up.
    try s.objectField("groups");
    try s.write(groups);

    // Resolved values, in plain text, exactly once in the whole
    // conversation. Nothing repeats them per batch.
    try s.objectField("params");
    try s.beginObject();
    for (params, values) |p, v| {
        try s.objectField(p.name);
        try s.write(v);
    }
    try s.endObject();

    try s.endObject();
}

/// Whether anything in this window is this plugin's to see.
///
/// Asked before a line is rendered, so that a window belonging entirely to
/// somebody else costs no pipe at all; see the empty-window rule in
/// `docs/poltergeist/storage.md`.
fn anyAllowed(events: []const Feed.Event, groups: []const []const u8) bool {
    const wants: Plugin.Wants = .{ .groups = groups };
    for (events) |ev| {
        // An event with no group of its own is nobody's by group, and the
        // null is here so that a future kind has to say what it is rather
        // than falling into everybody's batch by omission.
        const g = ev.group() orelse continue;
        if (wants.allows(g)) return true;
    }
    return false;
}

/// How long to wait before the next attempt, and whether to keep trying.
///
/// Neither of the two easy answers. Retrying for ever is a fork loop;
/// giving up for good means the archive is broken for precisely as long as
/// nobody is watching, which is the whole scenario this exists for.
pub const Backoff = struct {
    /// Where `settled` puts `ms` back to. Carried rather than read off the
    /// constant so that a test can watch a restart happen instead of
    /// waiting one out.
    start_ms: u64 = backoff_start_ms_default,

    ms: u64 = backoff_start_ms_default,
    failures: u32 = 0,

    /// Record a child that did not work out, and say how long to wait.
    /// Null once the archive should go dormant.
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
fn unhurried(self: *Archive) void {
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

/// Say why a child is being killed for what it said.
///
/// Killing rather than ignoring: a plugin that reports doing what it cannot
/// do has no later acknowledgement worth believing, and restarting is
/// cheap because everything it never confirmed is still queued for it.
fn violation(self: *Archive, why: []const u8, line: []const u8) void {
    log.warn(
        "plugin {s}: {s}, so it is being stopped; it said: {s}",
        .{ self.key, why, line[0..@min(200, line.len)] },
    );
}

/// Stop the child we have and be sure it is really gone.
///
/// **The reaper is taken out of the picture first**, which is a deliberate
/// departure from the order `Plugin.run` uses. `hurry` cannot be used here
/// at all: it is sticky, so a restart branch that called it would hand
/// every later child a deadline of zero and the archive would never keep a
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
    self: *Archive,
    child: *?std.process.Child,
    keeper: *?std.Thread,
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

        _ = c.wait(self.io) catch {};
        child.* = null;
    }
}

/// Sleep in slices, giving up the moment `stop` has been called.
///
/// Checked before each slice rather than after, so that a dormant quarter
/// of an hour costs shutdown one slice and not one wait.
fn sleepSliced(self: *Archive, total_ms: u64) void {
    var left = total_ms;
    while (left > 0) {
        if (!self.running.load(.acquire)) return;
        const slice = @min(left, wait_slice_ms);
        std.Io.sleep(self.io, .fromMilliseconds(slice), .awake) catch return;
        left -= slice;
    }
}

/// The thread body.
fn main(self: *Archive) void {
    const io = self.io;
    const a = self.alloc;

    var child: ?std.process.Child = null;
    var keeper: ?std.Thread = null;
    var reader: ?std.Io.File.Reader = null;

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
                        log.warn(
                            "plugin {s}: could not resolve {s}, not starting it",
                            .{ self.key, p.name },
                        );
                        break :step .failure;
                    };
                    values.append(scratch, v) catch break :step .failure;
                }

                child = std.process.spawn(io, .{
                    .argv = &.{self.exec},
                    .stdin = .pipe,

                    // The one shape difference from a one-shot plugin: it
                    // answers, so we have to be able to hear it.
                    .stdout = .pipe,

                    .stderr = .inherit,
                }) catch |err| {
                    log.warn("plugin {s}: could not start err={}", .{ self.key, err });
                    break :step .failure;
                };

                self.reaper.rearm(child.?.id, self.timeout_ms);
                keeper = std.Thread.spawn(.{}, reap.Reaper.run, .{&self.reaper}) catch null;

                // The one place a missing thread is not survivable. An
                // unwatched child means a write into a full pipe or a read
                // from a silent one with nothing to bound it, and that is a
                // `stop` that never returns and a window the user cannot
                // close.
                if (keeper == null) {
                    log.warn(
                        "plugin {s}: nothing to keep time for it, so it is stopped again",
                        .{self.key},
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

                const hello = renderHello(
                    scratch,
                    self.key,
                    confirmed,
                    self.groups,
                    self.params,
                    values.items,
                ) catch break :step .failure;

                self.reaper.allow(self.timeout_ms);
                stdin.writeStreamingAll(io, hello) catch |err| {
                    log.warn("plugin {s}: could not greet it err={}", .{ self.key, err });
                    break :step .failure;
                };

                const line = switch (readLine(&reader.?)) {
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

                // Not misconduct: an archive plugin that cannot reach its
                // database says so here, and gets the same patient retry as
                // one that would not start at all.
                if (!ack.ok) {
                    log.warn(
                        "plugin {s}: it will not take events yet, trying again later",
                        .{self.key},
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
                    if (at != confirmed) log.info(
                        "plugin {s}: it says it has up to seq {d}; " ++
                            "it will be sent what happens from now on",
                        .{ self.key, at },
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
                log.warn(
                    "plugin {s}: {d} event(s) went by while it was behind and " ++
                        "were not kept for it; Polter's own record has them",
                    .{ self.key, st.dropped - dropped_said },
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
                        self.groups,
                    ) catch break :step .failure;
                    defer a.free(beat);

                    const stdin = child.?.stdin orelse break :step .failure;
                    self.reaper.allow(self.timeout_ms);
                    stdin.writeStreamingAll(io, beat) catch break :step .failure;

                    const line = switch (readLine(&reader.?)) {
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

            const through = batch[batch.len - 1].seq();

            if (!anyAllowed(batch, self.groups)) {
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
                self.groups,
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
                log.warn("plugin {s}: could not feed it err={}", .{ self.key, err });
                break :step .failure;
            };

            const answer = switch (readLine(&reader.?)) {
                .got => |l| l,
                .gone => break :step .failure,
                .too_long => {
                    self.violation("its answer ran past the size of a line", "");
                    break :step .failure;
                },
            };
            self.unhurried();
            last_send = .now(io, .awake);

            const ack = parseAck(a, answer) orelse {
                self.violation("its answer was not an acknowledgement", answer);
                break :step .failure;
            };

            switch (advance(confirmed, through, ack)) {
                .violation => {
                    self.violation("it confirmed a cursor it cannot have reached", answer);
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
        self.collect(&child, &keeper);

        // Nothing to put back. A child that died between being handed a
        // batch and acknowledging it confirmed nothing, so nothing was
        // committed, so the whole batch is still queued exactly where it
        // was -- the replacement is offered it as though the first child
        // had never existed. The old design had to notice this case and
        // rewind a file position; here there is no position to rewind.
        if (!self.running.load(.acquire)) break;

        self.failures.store(backoff.failures + 1, .release);
        if (backoff.failed()) |wait| {
            self.state.store(.backing_off, .release);
            self.sleepSliced(wait);
        } else {
            // Dormant, not finished. Said out loud every time it comes
            // round, because an archive that has been down for a quarter of
            // an hour is worth saying again.
            self.state.store(.dormant, .release);
            log.warn(
                "plugin {s}: giving it a rest after {d} failed starts; trying again later",
                .{ self.key, backoff.failures },
            );
            self.sleepSliced(self.timing.dormant_retry_ms);
        }
    }

    reader = null;
    self.collect(&child, &keeper);

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
    // mean the archive stays broken long after the reason went away.
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
    .{ .chat = .{ .seq = 3, .at_ms = 1000, .group = "build", .author = "worker-core", .text = "one" } },
    .{ .chat = .{ .seq = 4, .at_ms = 1001, .group = "ops", .author = "worker-ops", .text = "two" } },
    .{ .chat = .{ .seq = 5, .at_ms = 1002, .group = "build", .author = "worker-core", .summary = true, .text = "three" } },
    .{ .chat = .{ .seq = 6, .at_ms = 1003, .group = "ops", .author = "worker-ops", .text = "four" } },
};

test "a batch reaches through the messages that were filtered out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const line = try renderBatch(alloc, 2, 6, mixed, &.{"build"});

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{});
    const obj = parsed.object;

    try testing.expectEqual(@as(i64, 2), obj.get("cursor").?.integer);

    // The whole point of the field: the window ended on somebody else's
    // message, and without this the plugin could never confirm past it.
    try testing.expectEqual(@as(i64, 6), obj.get("through").?.integer);

    const messages = obj.get("messages").?.array;
    try testing.expectEqual(@as(usize, 2), messages.items.len);
    try testing.expectEqual(@as(i64, 3), messages.items[0].object.get("seq").?.integer);
    try testing.expectEqual(@as(i64, 5), messages.items[1].object.get("seq").?.integer);
    try testing.expect(std.mem.indexOf(u8, line, "\"ops\"") == null);
}

test "a star takes every group, and no message carries a terminal handle" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const line = try renderBatch(alloc, 2, 6, mixed, &.{"*"});
    try testing.expect(line[line.len - 1] == '\n');

    // A `Bus.Id` means something for one run of one process. A column of
    // them in somebody's database is a foreign key to nothing.
    try testing.expect(std.mem.indexOf(u8, line, "\"from\"") == null);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{});
    const messages = parsed.object.get("messages").?.array;
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
    // The regression this file exists to keep: `Archive` arms a deadline,
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
    const hello = try renderHello(alloc, "archive", 0, &.{"*"}, params, &.{store});

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
        .seq = 11,
        .at_ms = 1786819271275,
        .group = "build",
        .author = "worker-core",
        .text = "hello",
    } }};
    const batch = try renderBatch(alloc, 0, 11, events, &.{"*"});
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

test "the opening line carries the cursor, the groups and the resolved values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const params: []const Plugin.Param = &.{
        .{ .name = "backend", .value = "postgres" },
        .{ .name = "dsn", .value = "op://vault/dsn" },
    };
    const values: []const []const u8 = &.{ "postgres", "postgres://real" };

    const line = try renderHello(alloc, "chat-archive", 900, &.{ "build", "ops" }, params, values);
    try testing.expect(line[line.len - 1] == '\n');

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{});
    const obj = parsed.object;

    try testing.expectEqual(@as(i64, 1), obj.get("hello").?.integer);
    try testing.expectEqualStrings("chat-archive", obj.get("plugin").?.string);
    try testing.expectEqual(@as(i64, 900), obj.get("cursor").?.integer);

    const groups = obj.get("groups").?.array;
    try testing.expectEqual(@as(usize, 2), groups.items.len);
    try testing.expectEqualStrings("build", groups.items[0].string);

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
/// `arena`. Nothing of Polter's lives in it any more: an archive opens no
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

test "an archive that was asked for no groups is not started" {
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
        .groups = &.{},
        .params = &.{},
        .feed = &feed,
        .environ = env,
    }));
}

test "stopping an archive twice is stopping it once" {
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
        .groups = &.{"*"},
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
        .groups = &.{"*"},
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
        .groups = &.{"*"},
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
        .groups = &.{"*"},
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
        .groups = &.{"*"},
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
        .groups = &.{"*"},
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
