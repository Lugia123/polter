//! Who the agent in a terminal is, when it was started by hand (task 1635).
//!
//! An agent CLI started through Polter (`+launch`, a role, the control
//! room) has hooks, and through them says what it is and which session it
//! is in. One a person started by typing `claude` has none: the bus knows
//! an agent is connected (its MCP sidecar is) and nothing else, and the
//! control room had nothing to show for it.
//!
//! **The core does not decide what that agent is; the adapters do.** The
//! sidecar sends, at its handshake, the values of the environment variables
//! the adapters declared (`Plugin.AgentCli.identify_env`) and its parent's
//! pid (`agent_cli.Sighting`). This asks each adapter that could recognise
//! the CLI from those (`agent_cli.recognise`), on a thread of its own --
//! asking runs a process, and the app thread is every terminal's thread --
//! and keeps the answer per terminal until the agent goes.
//!
//! Three answers, and the third is not the absence of the other two:
//! `asking`, `known` (an adapter said "mine"), and `unknown` (none did:
//! no adapter could recognise it, or every one said no or failed). A CLI
//! with no adapter is `unknown`, which the control room says, rather than
//! nothing, which would read as "fine".

const Identities = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const agent_cli = @import("agent_cli.zig");
const login_path = @import("login_path.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.poltergeist);

alloc: Allocator,
mutex: Io.Mutex = .init,
entries: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
next_gen: u64 = 1,

/// Threads still asking. `deinit` waits for none.
running: std.atomic.Value(u32) = .init(0),

/// Called from an asking thread when an answer has been kept, so that the
/// control room is worked out again. Never under the lock.
changed: ?*const fn (ctx: *anyopaque) void = null,
ctx: ?*anyopaque = null,

/// How a test runs the adapters instead of discovering them. Null in the
/// app.
adapters_for_test: ?[]const agent_cli.Adapter = null,

pub const State = enum { asking, known, unknown };

const Entry = struct {
    /// Which ask this entry belongs to: an answer from an ask that was
    /// since forgotten and asked again is not this one's.
    gen: u64,
    state: State,
    /// When it was last asked, on the caller's clock (`refresh`).
    asked_ms: u64 = 0,
    /// A second ask is under way; what is kept stands meanwhile.
    refreshing: bool = false,
    /// The adapter's key and label, and its whole `identify` answer, owned;
    /// empty unless `known`.
    key: []u8 = &.{},
    label: []u8 = &.{},
    answer: []u8 = &.{},

    fn deinit(self: *Entry, alloc: Allocator) void {
        alloc.free(self.key);
        alloc.free(self.label);
        alloc.free(self.answer);
    }
};

/// What is known of one terminal, copied into the caller's arena.
pub const View = struct {
    state: State,
    key: []const u8,
    label: []const u8,
    /// The adapter's answer, read. `.no` unless `known`.
    identified: agent_cli.Identified,
};

pub fn init(alloc: Allocator) Identities {
    return .{ .alloc = alloc };
}

/// Wait for every asking thread, then free everything. An adapter is given
/// `agent_cli.timeout_ms` at most, so this waits that long at most.
pub fn deinit(self: *Identities, io: Io) void {
    while (self.running.load(.acquire) > 0) {
        Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    var it = self.entries.valueIterator();
    while (it.next()) |e| e.deinit(self.alloc);
    self.entries.deinit(self.alloc);
}

/// Start finding out who the agent in `id` is, unless that is known or
/// being found out. **App thread only.** `sighting` and `cwd` are copied.
pub fn ask(self: *Identities, io: Io, id: u64, sighting: agent_cli.Sighting, cwd: ?[]const u8, now_ms: u64) void {
    const gen = gen: {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.entries.contains(id)) return;
        const gen = self.next_gen;
        self.next_gen += 1;
        self.entries.put(self.alloc, id, .{ .gen = gen, .state = .asking, .asked_ms = now_ms }) catch return;
        break :gen gen;
    };
    self.start(io, id, gen, sighting, cwd);
}

/// Ask again about `id` when what is known is older than `every_ms`: a
/// session's record goes on being written, and when it was last written is
/// part of the answer (`TakeOver.sure`). What is known stands until the new
/// answer comes. **App thread only.**
pub fn refresh(self: *Identities, io: Io, id: u64, sighting: agent_cli.Sighting, cwd: ?[]const u8, now_ms: u64, every_ms: u64) void {
    const gen = gen: {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const e = self.entries.getPtr(id) orelse return;
        if (e.state != .known or e.refreshing or now_ms -| e.asked_ms < every_ms) return;
        e.refreshing = true;
        e.asked_ms = now_ms;
        break :gen e.gen;
    };
    self.start(io, id, gen, sighting, cwd);
}

fn start(self: *Identities, io: Io, id: u64, gen: u64, sighting: agent_cli.Sighting, cwd: ?[]const u8) void {
    const job = Job.create(self, id, gen, sighting, cwd) catch {
        self.settle(io, id, gen, .unknown);
        return;
    };
    _ = self.running.fetchAdd(1, .acq_rel);
    const t = std.Thread.spawn(.{}, Job.run, .{ job, io }) catch |err| {
        log.warn("identify: could not start a thread err={}", .{err});
        _ = self.running.fetchSub(1, .acq_rel);
        job.destroy();
        self.settle(io, id, gen, .unknown);
        return;
    };
    t.detach();
}

/// The agent in `id` has gone: what was known of it no longer holds.
pub fn forget(self: *Identities, io: Io, id: u64) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    if (self.entries.fetchRemove(id)) |kv| {
        var e = kv.value;
        e.deinit(self.alloc);
    }
}

/// What is known of `id`, in `arena`; null when nothing was ever asked.
pub fn view(self: *Identities, io: Io, arena: Allocator, id: u64) Allocator.Error!?View {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const e = self.entries.get(id) orelse return null;
    return .{
        .state = e.state,
        .key = try arena.dupe(u8, e.key),
        .label = try arena.dupe(u8, e.label),
        .identified = if (e.state == .known) try agent_cli.parseIdentify(arena, try arena.dupe(u8, e.answer)) else .no,
    };
}

fn settle(self: *Identities, io: Io, id: u64, gen: u64, state: State) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const e = self.entries.getPtr(id) orelse return;
    if (e.gen != gen) return;
    // A second ask that failed leaves the first answer standing.
    if (e.refreshing) {
        e.refreshing = false;
        return;
    }
    e.state = state;
}

fn keep(self: *Identities, io: Io, id: u64, gen: u64, found: agent_cli.Recognised, answer: []const u8) void {
    {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const e = self.entries.getPtr(id) orelse return;
        if (e.gen != gen) return;
        const asked_ms = e.asked_ms;
        switch (found) {
            .unknown => {
                e.refreshing = false;
                e.state = .unknown;
            },
            .known => |k| {
                const key = self.alloc.dupe(u8, k.key) catch return;
                const label = self.alloc.dupe(u8, k.label) catch {
                    self.alloc.free(key);
                    return;
                };
                const kept = self.alloc.dupe(u8, answer) catch {
                    self.alloc.free(key);
                    self.alloc.free(label);
                    return;
                };
                e.deinit(self.alloc);
                e.* = .{ .gen = gen, .state = .known, .asked_ms = asked_ms, .key = key, .label = label, .answer = kept };
            },
        }
    }
    if (self.changed) |f| f(self.ctx.?);
}

/// One ask, owning copies of what it was given.
const Job = struct {
    owner: *Identities,
    id: u64,
    gen: u64,
    arena: std.heap.ArenaAllocator,
    sighting: agent_cli.Sighting,
    cwd: ?[]const u8,

    fn create(owner: *Identities, id: u64, gen: u64, sighting: agent_cli.Sighting, cwd: ?[]const u8) !*Job {
        const job = try owner.alloc.create(Job);
        errdefer owner.alloc.destroy(job);
        job.* = .{ .owner = owner, .id = id, .gen = gen, .arena = .init(owner.alloc), .sighting = .none, .cwd = null };
        errdefer job.arena.deinit();
        const a = job.arena.allocator();
        const env = try a.alloc([2][]const u8, sighting.env.len);
        for (sighting.env, env) |kv, *o| o.* = .{ try a.dupe(u8, kv[0]), try a.dupe(u8, kv[1]) };
        // The whole sighting, and only what it points into copied: picking
        // fields out once dropped `sidecar` (task 1749), and on Windows,
        // where `pid` is never read, that left nothing to tell two Codex
        // in one directory apart.
        job.sighting = sighting;
        job.sighting.env = env;
        job.cwd = if (cwd) |c| try a.dupe(u8, c) else null;
        return job;
    }

    fn destroy(job: *Job) void {
        const alloc = job.owner.alloc;
        job.arena.deinit();
        alloc.destroy(job);
    }

    fn run(job: *Job, io: Io) void {
        const owner = job.owner;
        defer _ = owner.running.fetchSub(1, .acq_rel);
        defer job.destroy();
        job.work(io) catch |err| {
            log.warn("identify: gave up err={}", .{err});
            owner.settle(io, job.id, job.gen, .unknown);
            if (owner.changed) |f| f(owner.ctx.?);
        };
    }

    fn work(job: *Job, io: Io) !void {
        const a = job.arena.allocator();
        var environ_map = try global.environMap();
        defer environ_map.deinit();
        _ = login_path.widen(a, io, &environ_map);

        const adapters = job.owner.adapters_for_test orelse agent_cli.discover(a, io, &environ_map);
        const found = try agent_cli.recognise(a, io, &environ_map, adapters, job.sighting, job.cwd);
        var answer: std.Io.Writer.Allocating = .init(a);
        switch (found) {
            .known => |k| try writeAnswer(&answer.writer, k.identified),
            .unknown => {},
        }
        job.owner.keep(io, job.id, job.gen, found, answer.written());
    }
};

/// An `Identified` written back as an `identify` answer, so that what is
/// kept is read again by `parseIdentify` and by nothing else.
fn writeAnswer(w: *std.Io.Writer, i: agent_cli.Identified) std.Io.Writer.Error!void {
    try w.writeAll("{\"me\":true,\"session\":");
    if (i.session) |s| try w.print("{f}", .{std.json.fmt(s, .{})}) else try w.writeAll("null");
    try w.writeAll(",\"session_written_ms\":");
    if (i.session_written_ms) |ms| try w.print("{d}", .{ms}) else try w.writeAll("null");
    if (i.quit) |q| {
        try w.print(",\"quit\":{{\"text\":{f},\"ready\":{{\"line\":{f},\"none_of\":{f}}}}}", .{
            std.json.fmt(q.text, .{}),
            std.json.fmt(q.ready_lines, .{}),
            std.json.fmt(q.ready_none, .{}),
        });
    }
    try w.writeAll("}");
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "Identities: what an ask sends identify carries the sidecar's pid it was given (task 1749)" {
    var ids: Identities = .init(testing.allocator);
    defer ids.deinit(testing.io);
    // Windows: no parent pid, only the sidecar's own.
    const given: agent_cli.Sighting = .{ .pid = null, .sidecar = 5544, .env = &.{.{ "POLTER_AGENT_CLI", "codex" }} };
    const job = try Job.create(&ids, 1, 1, given, "D:\\polter\\w5");
    defer job.destroy();

    const codex: agent_cli.Adapter = .{ .key = "codex", .label = "Codex", .bin = "codex", .adapter = "adapter", .identify_env = &.{"POLTER_AGENT_CLI"} };
    var line: std.Io.Writer.Allocating = .init(testing.allocator);
    defer line.deinit();
    try agent_cli.writeIdentifyRequest(&line.writer, codex, job.sighting, job.cwd, null);
    const carries_sidecar = std.mem.indexOf(u8, line.written(), "\"sidecar_pid\":5544") != null;
    try testing.expect(carries_sidecar);
}

test "Identities: an answer is kept, round-trips, and a forgotten ask is not overwritten" {
    var ids: Identities = .init(testing.allocator);
    defer ids.deinit(testing.io);

    // `keep` without a thread: the part that decides what is kept.
    {
        ids.mutex.lockUncancelable(testing.io);
        defer ids.mutex.unlock(testing.io);
        try ids.entries.put(testing.allocator, 7, .{ .gen = 3, .state = .asking });
    }
    const said: agent_cli.Identified = .{
        .me = true,
        .session = "0b1d1c35-5e33-4b5e-9f8c-1a2b3c4d5e6f",
        .session_written_ms = 1_792_000_000_000,
        .quit = .{ .text = "/exit", .ready_lines = &.{"❯"}, .ready_none = &.{"Do you want"} },
    };
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeAnswer(&buf.writer, said);
    ids.keep(testing.io, 7, 3, .{ .known = .{ .key = "claude-code", .label = "Claude Code", .identified = said } }, buf.written());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = (try ids.view(testing.io, arena.allocator(), 7)).?;
    try testing.expectEqual(State.known, v.state);
    try testing.expectEqualStrings("Claude Code", v.label);
    try testing.expectEqualStrings(said.session.?, v.identified.session.?);
    try testing.expectEqual(said.session_written_ms, v.identified.session_written_ms);
    try testing.expectEqualStrings("/exit", v.identified.quit.?.text);
    try testing.expectEqualStrings("Do you want", v.identified.quit.?.ready_none[0]);

    // Forgotten and asked again: the old ask's answer does not land.
    ids.forget(testing.io, 7);
    {
        ids.mutex.lockUncancelable(testing.io);
        defer ids.mutex.unlock(testing.io);
        try ids.entries.put(testing.allocator, 7, .{ .gen = 4, .state = .asking });
    }
    ids.keep(testing.io, 7, 3, .unknown, "");
    try testing.expectEqual(State.asking, (try ids.view(testing.io, arena.allocator(), 7)).?.state);
    try testing.expect((try ids.view(testing.io, arena.allocator(), 8)) == null);
}
