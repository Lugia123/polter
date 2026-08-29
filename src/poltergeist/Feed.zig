//! What happened, handed to plugins as it happens.
//!
//! A plugin used to be fed by following the core's own log file with a
//! cursor. That made two things one: the core's storage -- the stream, the
//! record, the rotation -- and the plugins' data source. Every change to
//! how the core stores things became a change to how plugins are fed, and
//! a plugin's position was a byte offset into a file the core was free to
//! rename out from under it.
//!
//! The rule now is the other way round. **The core's storage is a core
//! feature: complete on its own, unchanged by whether a plugin exists, and
//! never a plugin's data source.** What a plugin keeps is *an extra copy*,
//! made from the events it was handed live. So:
//!
//!   - rotation, layout and retention are the core's business alone; this
//!     file names no path and opens no file
//!   - a plugin that is away misses what went by while it was away, and
//!     the core's own record is untouched by that -- which is the honest
//!     shape, because an extra copy that pretends to be complete is worse
//!     than one that says what it missed (`Stats.dropped`)
//!   - terminal output has no "one file, one offset" to follow at all, so
//!     following a file was never going to reach past chat
//!
//! **More than one kind of event.** `Event` is a union and today it has
//! one member. The shape is here so that terminal output can be a second
//! one without any of this being reworked; what a terminal event carries
//! is deliberately *not* guessed here. An interface invented from zero
//! samples is harder to change than no interface at all.
//!
//! **Nothing here blocks the publisher.** `publish` copies into each
//! subscriber's bounded queue and returns. It never waits on a plugin, it
//! never fails outward, and when a queue is full the *oldest* event is
//! dropped rather than the newest -- a slow plugin must not be able to
//! turn into latency on the keystroke that produced the message.
//!
//! **Read by polling, not by waking.** There is no condition variable
//! here on purpose: the reader (see `Resident.zig`) naps and looks again.
//! Half a second of latency into a database is not a thing anybody can
//! perceive; a scheduler round trip on the writer's thread is.

const Feed = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Plugin = @import("Plugin.zig");

const log = std.log.scoped(.poltergeist);

/// The kinds of event there are.
///
/// **The same list a manifest subscribes to**, not a second copy of it.
/// `Plugin.Event` is the vocabulary a user writes in `wants.events`; if
/// this file kept its own enum the two would drift, and the day they
/// drifted a plugin would subscribe to a name nothing publishes -- which
/// looks exactly like a plugin that works and is fed nothing. One list, and
/// adding a member is a compile error in every switch below.
pub const Kind = Plugin.Event;

/// One message that was said in a group.
///
/// `seq` is the identity the core stamped on the message when it recorded
/// it -- the same number `group_history` pages by. It is an *identity*,
/// not a position in a file: nothing downstream may use it to look
/// anything up, and a plugin wants it because it makes storing the same
/// message twice a no-op (`ON CONFLICT (stream, seq) DO NOTHING`).
///
/// It is **not** the cursor. `n` is; see `Event.n`. The two used to be one
/// number because chat was the only kind there was, and a second kind is
/// what pulled them apart: a notification has no chat-log identity at all.
///
/// There is no `from`. A `Bus.Id` is a handle valid for one run of one
/// process, and a column of those in somebody's database is a foreign key
/// to nothing; `author` was resolved to a name at the moment the message
/// was recorded and still means the same thing tomorrow.
pub const Chat = struct {
    n: u64 = 0,
    seq: u64,
    at_ms: i64,
    group: []const u8,
    author: []const u8,
    summary: bool = false,
    text: []const u8,
};

/// A terminal has gone quiet and somebody has to be told.
///
/// What used to be handed to a `notify` plugin as one process per
/// occasion. Nothing about the *decision* moved: `notify.decide` still says
/// whether there is anything to send and whether the hour permits it, and
/// only what it decided to send arrives here.
pub const Quiet = struct {
    n: u64 = 0,
    at_ms: i64,

    /// `scheduling` or `authorisation`; see `notify.Reason`.
    reason: []const u8,
    title: []const u8,
    body: []const u8,

    /// Which terminal this is about. Rendered as the same `0x…` text the
    /// host puts in the environment, so what a plugin reads here and what
    /// an agent reads from `GHOSTTY_SURFACE_ID` are the same string.
    terminal: u64 = 0,
    terminal_name: []const u8 = "",
};

/// One skill, and the file it is actually in.
pub const Skill = struct {
    name: []const u8,
    path: []const u8,
};

/// Here is what Polter is; make an agent runtime able to see it.
///
/// What used to be handed to a `provision` plugin once at startup. It is
/// still sent once, and it is still one line describing the program rather
/// than an occasion -- what changed is only that the plugin receiving it is
/// the same resident process that may also be subscribed to something else.
pub const Provision = struct {
    n: u64 = 0,
    at_ms: i64 = 0,

    /// Absolute path to the binary that serves the MCP endpoint. It is run
    /// as `<exe> +mcp`, speaking JSON-RPC on stdio.
    exe: []const u8,

    /// This build, for the staleness marker.
    version: []const u8,

    /// The env key a plugin is expected to stamp its registration with.
    version_key: []const u8,

    home: []const u8,
    skills: []const Skill = &.{},
};

pub const Event = union(Kind) {
    chat: Chat,
    terminal_quiet: Quiet,
    provision: Provision,

    /// This event's place in the one order there is.
    ///
    /// Stamped by `publish`, monotonic across a run, and **the only thing
    /// the batch protocol's cursor counts in**. It has to be the feed's own
    /// number rather than any kind's own identity: two kinds have no
    /// identity in common, and a plugin subscribed to both is handed them
    /// interleaved on one stdin. There is one stream and one order; a
    /// plugin that wants them apart looks at `kind`.
    pub fn n(self: Event) u64 {
        return switch (self) {
            inline else => |e| e.n,
        };
    }

    /// The kind, as the tag it already is. Named so callers read
    /// `ev.kind()` beside `ev.n()` rather than switching for one word.
    pub fn kind(self: Event) Kind {
        return self;
    }

    /// The group this belongs to, or null for a kind that has no group.
    ///
    /// Null is not "every group": a caller filtering by group has to make
    /// its own decision about a kind that has none. What that decision is
    /// has been settled since there was a second kind -- `wants.groups`
    /// filters the events that *have* a group and says nothing about the
    /// ones that do not, because a notification is not in a group and
    /// refusing it for not being in one would mean every notifier had to
    /// declare `"groups": ["*"]` for reasons nobody could explain.
    pub fn group(self: Event) ?[]const u8 {
        return switch (self) {
            .chat => |c| c.group,
            .terminal_quiet, .provision => null,
        };
    }

    /// Roughly what this costs to hold, for the queue's own bookkeeping.
    /// Approximate on purpose: it bounds memory, it is not reported.
    pub fn size(self: Event) usize {
        return switch (self) {
            .chat => |c| @sizeOf(Chat) + c.group.len + c.author.len + c.text.len,
            .terminal_quiet => |q| @sizeOf(Quiet) + q.reason.len + q.title.len +
                q.body.len + q.terminal_name.len,
            .provision => |p| size: {
                var total = @sizeOf(Provision) + p.exe.len + p.version.len +
                    p.version_key.len + p.home.len;
                for (p.skills) |sk| total += @sizeOf(Skill) + sk.name.len + sk.path.len;
                break :size total;
            },
        };
    }

    pub fn clone(self: Event, alloc: Allocator) Allocator.Error!Event {
        switch (self) {
            .chat => |c| {
                const g = try alloc.dupe(u8, c.group);
                errdefer alloc.free(g);
                const a = try alloc.dupe(u8, c.author);
                errdefer alloc.free(a);
                const t = try alloc.dupe(u8, c.text);
                return .{ .chat = .{
                    .n = c.n,
                    .seq = c.seq,
                    .at_ms = c.at_ms,
                    .group = g,
                    .author = a,
                    .summary = c.summary,
                    .text = t,
                } };
            },

            .terminal_quiet => |q| {
                // One arena-shaped hand cleanup rather than four nested
                // `errdefer`s: a partly built event is freed by the same
                // routine that frees a whole one, and there is exactly one
                // place that knows which fields there are.
                var out: Quiet = .{
                    .n = q.n,
                    .at_ms = q.at_ms,
                    .reason = "",
                    .title = "",
                    .body = "",
                    .terminal = q.terminal,
                    .terminal_name = "",
                };
                errdefer (Event{ .terminal_quiet = out }).free(alloc);

                out.reason = try alloc.dupe(u8, q.reason);
                out.title = try alloc.dupe(u8, q.title);
                out.body = try alloc.dupe(u8, q.body);
                out.terminal_name = try alloc.dupe(u8, q.terminal_name);
                return .{ .terminal_quiet = out };
            },

            .provision => |p| {
                var out: Provision = .{
                    .n = p.n,
                    .at_ms = p.at_ms,
                    .exe = "",
                    .version = "",
                    .version_key = "",
                    .home = "",
                    .skills = &.{},
                };
                errdefer (Event{ .provision = out }).free(alloc);

                out.exe = try alloc.dupe(u8, p.exe);
                out.version = try alloc.dupe(u8, p.version);
                out.version_key = try alloc.dupe(u8, p.version_key);
                out.home = try alloc.dupe(u8, p.home);

                const skills = try alloc.alloc(Skill, p.skills.len);
                // Blank first, so the free path below never reads a name
                // that was never written.
                for (skills) |*sk| sk.* = .{ .name = "", .path = "" };
                out.skills = skills;

                for (p.skills, skills) |src, *dst| {
                    dst.name = try alloc.dupe(u8, src.name);
                    dst.path = try alloc.dupe(u8, src.path);
                }
                return .{ .provision = out };
            },
        }
    }

    pub fn free(self: Event, alloc: Allocator) void {
        switch (self) {
            .chat => |c| {
                alloc.free(c.group);
                alloc.free(c.author);
                alloc.free(c.text);
            },
            .terminal_quiet => |q| {
                alloc.free(q.reason);
                alloc.free(q.title);
                alloc.free(q.body);
                alloc.free(q.terminal_name);
            },
            .provision => |p| {
                alloc.free(p.exe);
                alloc.free(p.version);
                alloc.free(p.version_key);
                alloc.free(p.home);
                for (p.skills) |sk| {
                    alloc.free(sk.name);
                    alloc.free(sk.path);
                }
                alloc.free(p.skills);
            },
        }
    }
};

/// Free a batch handed back by `Subscription.take`.
pub fn freeBatch(alloc: Allocator, batch: []const Event) void {
    for (batch) |e| e.free(alloc);
    alloc.free(batch);
}

/// One reader's own queue of events.
///
/// Bounded, and the bound is the whole point: a plugin is an extra copy,
/// so the queue behind it must never be allowed to grow into the reason
/// Polter ran out of memory. Past the bound the oldest goes and `dropped`
/// counts it, which is the only honest thing an extra copy can do.
pub const Subscription = struct {
    pub const Limits = struct {
        /// Enough for a long unattended night at conversational rates, and
        /// small enough that the worst case is megabytes, not gigabytes.
        max_events: usize = 4096,
        max_bytes: usize = 4 * 1024 * 1024,
    };

    pub const Stats = struct {
        /// Waiting to be taken.
        pending: usize,

        /// Never handed over, because the queue was full when they came.
        dropped: u64,
    };

    alloc: Allocator,
    io: std.Io,
    limits: Limits,

    /// Guards everything below it. Held only across memory operations --
    /// never across a write to a pipe or anything else that can block.
    mutex: std.Io.Mutex = .init,

    /// A FIFO: `head` is where the unread part starts, so committing a
    /// prefix costs an index rather than a shift of everything behind it.
    ring: std.ArrayListUnmanaged(Event) = .empty,
    head: usize = 0,

    bytes: usize = 0,
    dropped: u64 = 0,

    fn deinit(self: *Subscription) void {
        for (self.ring.items[self.head..]) |e| e.free(self.alloc);
        self.ring.deinit(self.alloc);
        self.* = undefined;
    }

    /// Take ownership of one already-cloned event.
    fn push(self: *Subscription, ev: Event) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.ring.append(self.alloc, ev) catch {
            ev.free(self.alloc);
            self.dropped += 1;
            return;
        };
        self.bytes += ev.size();

        // The oldest goes, never the newest. A plugin that has fallen a
        // long way behind is most useful being handed what is happening
        // now; and dropping the newest would mean the queue full once
        // stays full for ever.
        while (self.count() > self.limits.max_events or
            (self.bytes > self.limits.max_bytes and self.count() > 1))
        {
            const old = self.ring.items[self.head];
            self.bytes -= old.size();
            old.free(self.alloc);
            self.head += 1;
            self.dropped += 1;
        }

        self.compact();
    }

    fn countDrop(self: *Subscription) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.dropped += 1;
    }

    /// How many are unread. The caller holds the lock.
    fn count(self: *const Subscription) usize {
        return self.ring.items.len - self.head;
    }

    /// Move the unread part back to the front once the read part is worth
    /// reclaiming. The caller holds the lock.
    fn compact(self: *Subscription) void {
        if (self.head == 0) return;
        if (self.head < 64 and self.head < self.ring.items.len) return;

        const rest = self.count();
        std.mem.copyForwards(
            Event,
            self.ring.items[0..rest],
            self.ring.items[self.head..],
        );
        self.ring.shrinkRetainingCapacity(rest);
        self.head = 0;
    }

    /// Copy out up to `max` events, without removing them.
    ///
    /// Taking is not removing, and that is the whole retry story: an event
    /// stays queued until `commit` says a plugin has stored it, so a
    /// plugin that answers "not now", or dies holding a batch, is simply
    /// handed the same batch again. There is no second buffer anywhere --
    /// this queue *is* the buffer, the way the log used to be.
    ///
    /// The events are copied rather than lent, because the caller goes on
    /// to spend an unbounded time writing them into a pipe and the
    /// publisher must not be blocked behind that.
    pub fn take(
        self: *Subscription,
        alloc: Allocator,
        max: usize,
        max_bytes: usize,
    ) Allocator.Error![]Event {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var out: std.ArrayListUnmanaged(Event) = .empty;
        errdefer {
            for (out.items) |e| e.free(alloc);
            out.deinit(alloc);
        }

        var total: usize = 0;
        for (self.ring.items[self.head..]) |e| {
            if (out.items.len >= max) break;

            const sz = e.size();

            // Never zero events: one event larger than the whole budget
            // has to go on its own, or it wedges the queue for good.
            if (out.items.len > 0 and total + sz > max_bytes) break;

            const copy = try e.clone(alloc);
            errdefer copy.free(alloc);
            try out.append(alloc, copy);
            total += sz;
        }

        return out.toOwnedSlice(alloc);
    }

    /// Forget everything up to and including `through`, counted in `Event.n`.
    ///
    /// Idempotent, and safe to call with a number nothing matches: it drops
    /// a prefix, so a repeat drops nothing.
    pub fn commit(self: *Subscription, through: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.head < self.ring.items.len) {
            const e = self.ring.items[self.head];
            if (e.n() > through) break;
            self.bytes -= e.size();
            e.free(self.alloc);
            self.head += 1;
        }

        self.compact();
    }

    pub fn stats(self: *Subscription) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .pending = self.count(), .dropped = self.dropped };
    }
};

alloc: Allocator,
io: std.Io,

/// Guards the subscriber list. Taken before a subscriber's own lock and
/// never after one, which is the whole of the lock order here.
mutex: std.Io.Mutex = .init,

subs: std.ArrayListUnmanaged(*Subscription) = .empty,

/// The last number handed out by `publish`. Guarded by `mutex`, and never
/// reset: a plugin's cursor is only ever compared against numbers from this
/// run, and a counter that went backwards would let one confirm past events
/// it was never shown.
next_n: u64 = 0,

pub fn init(alloc: Allocator, io: std.Io) Feed {
    return .{ .alloc = alloc, .io = io };
}

/// Free the feed and every subscription still on it.
///
/// Subscribers are expected to have stopped first -- an `Archive` is
/// joined before this runs -- but freeing them here rather than asserting
/// there are none keeps a shutdown that skipped a step from leaking.
pub fn deinit(self: *Feed) void {
    for (self.subs.items) |s| {
        s.deinit();
        self.alloc.destroy(s);
    }
    self.subs.deinit(self.alloc);
    self.* = undefined;
}

/// Start receiving events from now on.
///
/// From *now*: there is no backlog to catch up on, because the feed keeps
/// no history. What went by before this call is in the core's own record,
/// and reading that is not a plugin's job.
pub fn subscribe(
    self: *Feed,
    limits: Subscription.Limits,
) Allocator.Error!*Subscription {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const sub = try self.alloc.create(Subscription);
    errdefer self.alloc.destroy(sub);
    sub.* = .{ .alloc = self.alloc, .io = self.io, .limits = limits };

    try self.subs.append(self.alloc, sub);
    return sub;
}

/// Stop receiving, and free the subscription. The subscriber's own thread
/// must have stopped before this is called.
pub fn unsubscribe(self: *Feed, sub: *Subscription) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    for (self.subs.items, 0..) |s, i| {
        if (s == sub) {
            _ = self.subs.orderedRemove(i);
            break;
        }
    }

    sub.deinit();
    self.alloc.destroy(sub);
}

/// Hand one event to everybody listening.
///
/// Cannot fail and does not wait. The caller is on the path that just
/// recorded something -- often the path a keystroke is still on -- so
/// there is nothing here it can be made to answer for: no error to
/// handle, no plugin to wait for, no queue to be pushed back by.
pub fn publish(self: *Feed, ev: Event) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    // Stamped here and nowhere else. The publisher does not get to choose
    // its own place in the order -- three different callers on three
    // different threads would otherwise each keep a counter, and the
    // cursor a plugin confirms would stop being a total order over
    // anything.
    self.next_n += 1;
    var stamped = ev;
    switch (stamped) {
        inline else => |*e| e.n = self.next_n,
    }

    for (self.subs.items) |s| {
        const copy = stamped.clone(self.alloc) catch {
            // Counted rather than logged: out of memory here would arrive
            // once per message and per subscriber, and the count is what
            // a reader is going to be told anyway.
            s.countDrop();
            continue;
        };
        s.push(copy);
    }
}

/// How many are listening. For tests and for a log line, nothing else.
pub fn subscribers(self: *Feed) usize {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.subs.items.len;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// A chat event whose strings live only as long as the caller's frame --
/// which is exactly the lifetime `publish` must not depend on.
fn chatEvent(seq: u64, group: []const u8, text: []const u8) Event {
    return .{ .chat = .{
        .seq = seq,
        .at_ms = 1000 + @as(i64, @intCast(seq)),
        .group = group,
        .author = "worker-core",
        .text = text,
    } };
}

test "an event published reaches a subscriber, and the publisher keeps nothing" {
    const alloc = testing.allocator;

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();

    var feed: Feed = .init(alloc, threaded.io());
    defer feed.deinit();

    const sub = try feed.subscribe(.{});
    try testing.expectEqual(@as(usize, 1), feed.subscribers());

    {
        // Deliberately scoped: the strings go out of scope before anything
        // is taken, so a feed that lent rather than copied would hand back
        // rubbish here.
        var buf: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "hello {d}", .{7});
        feed.publish(chatEvent(1, "build", text));
        @memset(&buf, 'x');
    }

    const batch = try sub.take(alloc, 16, 1 << 20);
    defer freeBatch(alloc, batch);

    try testing.expectEqual(@as(usize, 1), batch.len);
    try testing.expectEqual(@as(u64, 1), batch[0].n());
    try testing.expectEqualStrings("build", batch[0].group().?);
    try testing.expectEqualStrings("hello 7", batch[0].chat.text);
}

test "taking is not removing, and committing is" {
    const alloc = testing.allocator;

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();

    var feed: Feed = .init(alloc, threaded.io());
    defer feed.deinit();

    const sub = try feed.subscribe(.{});

    feed.publish(chatEvent(1, "build", "one"));
    feed.publish(chatEvent(2, "ops", "two"));
    feed.publish(chatEvent(3, "build", "three"));

    {
        // The whole retry story: a reader that does not commit is handed
        // the same events again, with no second buffer anywhere.
        const first = try sub.take(alloc, 16, 1 << 20);
        defer freeBatch(alloc, first);
        try testing.expectEqual(@as(usize, 3), first.len);
    }
    {
        const again = try sub.take(alloc, 16, 1 << 20);
        defer freeBatch(alloc, again);
        try testing.expectEqual(@as(usize, 3), again.len);
        try testing.expectEqual(@as(u64, 1), again[0].n());
    }

    // Half of it, which is what a plugin that stored half a batch says.
    sub.commit(2);

    const rest = try sub.take(alloc, 16, 1 << 20);
    defer freeBatch(alloc, rest);
    try testing.expectEqual(@as(usize, 1), rest.len);
    try testing.expectEqual(@as(u64, 3), rest[0].n());

    try testing.expectEqual(@as(usize, 1), sub.stats().pending);
    try testing.expectEqual(@as(u64, 0), sub.stats().dropped);

    // Committing the same place twice drops nothing more, and a number
    // nothing matches is not an error either.
    sub.commit(2);
    sub.commit(3);
    try testing.expectEqual(@as(usize, 0), sub.stats().pending);
}

test "a batch is bounded by count and by size" {
    const alloc = testing.allocator;

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();

    var feed: Feed = .init(alloc, threaded.io());
    defer feed.deinit();

    const sub = try feed.subscribe(.{});
    for (1..11) |i| feed.publish(chatEvent(@intCast(i), "build", "xxxxxxxx"));

    {
        const some = try sub.take(alloc, 4, 1 << 20);
        defer freeBatch(alloc, some);
        try testing.expectEqual(@as(usize, 4), some.len);
        try testing.expectEqual(@as(u64, 4), some[some.len - 1].n());
    }

    // One event never fits in nothing: a budget smaller than the first
    // event still hands it over, or the queue would wedge for good.
    const tiny = try sub.take(alloc, 16, 1);
    defer freeBatch(alloc, tiny);
    try testing.expectEqual(@as(usize, 1), tiny.len);
}

test "a subscriber that falls behind loses its own oldest, and says how many" {
    const alloc = testing.allocator;

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();

    var feed: Feed = .init(alloc, threaded.io());
    defer feed.deinit();

    // Small enough to overflow in a test, and the numbers are the point:
    // this is the failure the old design did not have and this one does,
    // so it has to be counted rather than merely survived.
    const sub = try feed.subscribe(.{ .max_events = 4 });
    for (1..9) |i| feed.publish(chatEvent(@intCast(i), "build", "x"));

    const st = sub.stats();
    try testing.expectEqual(@as(usize, 4), st.pending);
    try testing.expectEqual(@as(u64, 4), st.dropped);

    const batch = try sub.take(alloc, 16, 1 << 20);
    defer freeBatch(alloc, batch);

    // The newest four, not the oldest four.
    try testing.expectEqual(@as(usize, 4), batch.len);
    try testing.expectEqual(@as(u64, 5), batch[0].n());
    try testing.expectEqual(@as(u64, 8), batch[3].n());
}

test "two subscribers each get their own copy, and one leaving does not disturb the other" {
    const alloc = testing.allocator;

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();

    var feed: Feed = .init(alloc, threaded.io());
    defer feed.deinit();

    const a = try feed.subscribe(.{});
    const b = try feed.subscribe(.{});

    feed.publish(chatEvent(1, "build", "one"));

    // One reads and commits; the other has not read at all. The second
    // must still be holding the event -- there is no shared position.
    {
        const got = try a.take(alloc, 16, 1 << 20);
        defer freeBatch(alloc, got);
        try testing.expectEqual(@as(usize, 1), got.len);
    }
    a.commit(1);
    try testing.expectEqual(@as(usize, 0), a.stats().pending);
    try testing.expectEqual(@as(usize, 1), b.stats().pending);

    feed.unsubscribe(a);
    try testing.expectEqual(@as(usize, 1), feed.subscribers());

    feed.publish(chatEvent(2, "build", "two"));
    try testing.expectEqual(@as(usize, 2), b.stats().pending);
}

test "a subscription starts empty, whatever was published before it" {
    const alloc = testing.allocator;

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();

    var feed: Feed = .init(alloc, threaded.io());
    defer feed.deinit();

    // Published to nobody: the feed keeps no history, because history is
    // the core's record and reading that is not a plugin's job.
    feed.publish(chatEvent(1, "build", "before"));

    const sub = try feed.subscribe(.{});
    try testing.expectEqual(@as(usize, 0), sub.stats().pending);

    feed.publish(chatEvent(2, "build", "after"));

    const batch = try sub.take(alloc, 16, 1 << 20);
    defer freeBatch(alloc, batch);
    try testing.expectEqual(@as(usize, 1), batch.len);
    try testing.expectEqual(@as(u64, 2), batch[0].n());
}

test "publishing from another thread while one reads is safe" {
    const alloc = testing.allocator;

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();

    var feed: Feed = .init(alloc, threaded.io());
    defer feed.deinit();

    const sub = try feed.subscribe(.{});

    const Writer = struct {
        fn run(f: *Feed) void {
            for (1..201) |i| f.publish(chatEvent(@intCast(i), "build", "x"));
        }
    };

    const t = try std.Thread.spawn(.{}, Writer.run, .{&feed});

    var seen: usize = 0;
    while (seen < 200) {
        const batch = try sub.take(alloc, 32, 1 << 20);
        defer freeBatch(alloc, batch);
        if (batch.len == 0) continue;
        sub.commit(batch[batch.len - 1].n());
        seen += batch.len;
    }

    t.join();
    try testing.expectEqual(@as(usize, 200), seen);
    try testing.expectEqual(@as(u64, 0), sub.stats().dropped);
}

test "two kinds share one order, and each carries its own kind" {
    // The property the whole protocol rests on once there is more than one
    // kind: a plugin subscribed to both is handed them interleaved on one
    // stream, in one order, and `n` counts across both. A cursor that only
    // counted chat could never move past a notification.
    const alloc = testing.allocator;

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();

    var feed: Feed = .init(alloc, threaded.io());
    defer feed.deinit();

    const sub = try feed.subscribe(.{});

    feed.publish(chatEvent(41, "build", "one"));
    feed.publish(.{ .terminal_quiet = .{
        .at_ms = 1000,
        .reason = "authorisation",
        .title = "worker-core needs you",
        .body = "it is stopped on a tool prompt",
        .terminal = 0x9491465653644ed0,
        .terminal_name = "worker-core",
    } });
    feed.publish(chatEvent(42, "build", "two"));

    const batch = try sub.take(alloc, 16, 1 << 20);
    defer freeBatch(alloc, batch);

    try testing.expectEqual(@as(usize, 3), batch.len);
    try testing.expectEqual(@as(u64, 1), batch[0].n());
    try testing.expectEqual(@as(u64, 2), batch[1].n());
    try testing.expectEqual(@as(u64, 3), batch[2].n());

    try testing.expectEqual(Kind.chat, batch[0].kind());
    try testing.expectEqual(Kind.terminal_quiet, batch[1].kind());
    try testing.expectEqual(Kind.chat, batch[2].kind());

    // The chat log's own identity is untouched by any of this: it is what a
    // plugin stores against, and it is not the cursor.
    try testing.expectEqual(@as(u64, 41), batch[0].chat.seq);
    try testing.expectEqual(@as(u64, 42), batch[2].chat.seq);

    // A notification is in no group, and that is not "in every group".
    try testing.expect(batch[1].group() == null);

    // And the strings really were copied.
    try testing.expectEqualStrings("worker-core", batch[1].terminal_quiet.terminal_name);
}

test "a provisioning event copies its skill list" {
    const alloc = testing.allocator;

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();

    var feed: Feed = .init(alloc, threaded.io());
    defer feed.deinit();

    const sub = try feed.subscribe(.{});

    {
        var name_buf: [32]u8 = undefined;
        var path_buf: [64]u8 = undefined;
        const skills = [_]Skill{.{
            .name = try std.fmt.bufPrint(&name_buf, "polter-{s}", .{"supervising"}),
            .path = try std.fmt.bufPrint(&path_buf, "/tmp/{s}/SKILL.md", .{"skills"}),
        }};

        feed.publish(.{ .provision = .{
            .exe = "/Applications/Polter.app/Contents/MacOS/polter",
            .version = "0.3.0",
            .version_key = "POLTER_REGISTERED",
            .home = "/home/somebody",
            .skills = &skills,
        } });

        @memset(&name_buf, 'x');
        @memset(&path_buf, 'x');
    }

    const batch = try sub.take(alloc, 16, 1 << 20);
    defer freeBatch(alloc, batch);

    try testing.expectEqual(@as(usize, 1), batch.len);
    try testing.expectEqual(@as(usize, 1), batch[0].provision.skills.len);
    try testing.expectEqualStrings(
        "polter-supervising",
        batch[0].provision.skills[0].name,
    );
    try testing.expectEqualStrings(
        "/tmp/skills/SKILL.md",
        batch[0].provision.skills[0].path,
    );
}
