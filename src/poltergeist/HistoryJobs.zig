//! The core's bounded, asynchronous history jobs (task 2835, contract §2–§4,
//! §7, §8).
//!
//! **This file is the state machine and nothing else.** It knows a job is a
//! `pending` thing that becomes `ready`, `cancelled`, `failed` or `expired`;
//! it knows how many may run at once, which finished page is evicted first,
//! and when a result or a resume token goes stale. It does **not** know what
//! a reply looks like: every byte it hands on was written by a caller's
//! builder, and is returned unchanged until it expires. That keeps the wire
//! shape in one place (`rpc` and `App`) rather than in two that can drift.
//!
//! **Nothing here touches the app.** A job's work is a `Work`: an opaque
//! context and two functions. The app copies everything the scanner may
//! read before starting it (contract §7: a private state directory, group,
//! scope, cursors; never `App.chat_log`, `Chat` or the bus). A test supplies
//! its own work, so the rules below are reachable from `test {` without a
//! running app or a log on disk.
//!
//! **Why a thread at all.** A history scan walks day files on disk and may
//! read megabytes. Doing it in `poll` would stall the app thread, which is
//! where every terminal's events and the person's window go. `begin`
//! therefore does no I/O of its own: it copies what the scan needs,
//! registers the job and starts the thread.
//!
//! **Cancellation is a flag, not a kill.** The scanner checks it between
//! bounded steps (`Work.run` decides where), and a thread is always joined
//! before the job's memory is freed -- no detached worker can outlive the
//! app (`deinit` cancels and joins every job first). A cancelled job keeps
//! its thread object until it is joined for the same reason.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How many jobs may be scanning at once. `begin` says `Busy` past this and
/// only past this: a finished or cancelled job that has been joined does
/// not use one of these.
pub const max_running: usize = 2;

/// Finished pages kept for `poll`. Past this the oldest is expired, and a
/// job that was already delivered is evicted before one that was not --
/// continuous paging must not be blocked by a page the host already read.
pub const max_finished: usize = 8;

/// Resume tokens kept. A token is the core's own continuation state; a
/// client never builds one, so a bounded table that forgets is safe: using
/// a forgotten token answers `CursorExpired` and the host reloads a page.
pub const max_tokens: usize = 16;

/// How long a finished result may be polled, from when the thread said it
/// was done.
pub const result_ttl_ms: u64 = 60_000;

/// How long a resume token may be used, from when it was issued.
pub const token_ttl_ms: u64 = 300_000;

/// How long an expired job's identity is still recognised. `poll` on one
/// answers `Expired` rather than `NoSuchJob`, which is what the contract
/// asks: "被淘汰/过期的旧job随后poll明确返回Expired". The entry goes away
/// after this, so the table is not one that never releases anything.
pub const tombstone_ttl_ms: u64 = 300_000;

/// How many expired/cancelled job identities are remembered at once. TTL
/// alone is not a bound: a host that pages quickly evicts finished pages
/// many times a minute, and five minutes of that would be an unbounded
/// list. Past this the oldest tombstone is forgotten, and `poll` on it says
/// `NoSuchJob` -- only an id still in the table gets the precise `Expired`.
pub const max_tombstones: usize = 32;

/// Longer than this and a client's `request_id` is refused rather than
/// stored: it is a key in the table, and unbounded keys are unbounded
/// memory.
pub const max_request_id: usize = 128;

/// "Not stamped yet" for a job that has not reached a terminal state.
/// Max, not zero: a real monotonic reading is legitimately zero in the
/// first millisecond, and a sentinel that can be produced is not one.
const unset_ms = std.math.maxInt(u64);

/// Job ids and tokens are 128 random bits, written as 32 lowercase hex
/// characters. Long enough that a client cannot guess one, and both are
/// opaque by contract: a client may only hand back what it was given.
pub const id_len: usize = 32;

/// The states a job can be in, exactly the set contract §3 names.
pub const State = enum(u8) { pending, ready, cancelled, expired, failed };

/// Why a scan failed. The bytes the runner published carry the code the
/// host reads; this is only what the manager must know about the state.
pub const Failure = enum { too_large, scan_failed };

/// Where a continued scan starts, copied out of `ChatLog.ScanCursor` so
/// that this file does not depend on the log's module. The app converts.
pub const Cursor = struct {
    day: u32,
    part: u32,
    offset: u64,
    end: u64,
    inode: u64,
    question: u64,
};

/// A monotonic clock the caller supplies. Required, with no default: tests
/// inject one, and the app passes its own process-elapsed reading. The
/// worker thread reads it too, so its context must be immutable once the
/// clock is handed over.
pub const Clock = struct {
    ctx: ?*const anyopaque,
    now: *const fn (?*const anyopaque) u64,

    pub fn read(self: Clock) u64 {
        return self.now(self.ctx);
    }
};

/// A monotonic clock measured from a timestamp taken once. `start` is
/// immutable after construction, so both threads can read it.
pub const Elapsed = struct {
    io: std.Io,
    start: std.Io.Timestamp,

    pub fn init(io: std.Io) Elapsed {
        return .{ .io = io, .start = .now(io, .awake) };
    }

    pub fn clock(self: *const Elapsed) Clock {
        return .{ .ctx = self, .now = read };
    }

    fn read(ctx: ?*const anyopaque) u64 {
        const self: *const Elapsed = @ptrCast(@alignCast(ctx orelse return 0));
        const now: std.Io.Timestamp = .now(self.io, .awake);
        return @intCast(std.math.clamp(
            self.start.durationTo(now).toMilliseconds(),
            0,
            std.math.maxInt(i64),
        ));
    }
};

/// What a job's thread runs.
///
/// `run` runs on the worker and must not touch the manager. It reads the
/// job's copied request, does the scan, and ends with exactly one of
/// `completeReady`, `completeFailed` or `completeCancelled` -- or with
/// nothing at all when `job.cancelledByOwner()` is true, which the complete
/// functions also honour. `release` runs on whichever thread drops the job,
/// after the worker has been joined.
pub const Work = struct {
    ctx: ?*anyopaque = null,
    run: *const fn (ctx: ?*anyopaque, job: *Job) void,
    release: *const fn (alloc: Allocator, ctx: ?*anyopaque) void,
};

/// What `begin` was asked for, after the caller has validated it.
pub const Begin = struct {
    request_id: []const u8,
    group: []const u8,
    limit: usize,

    /// A token from an earlier page, or null for the first page.
    resume_token: ?[id_len]u8 = null,

    /// The persisted-log head at the first `begin` (contract §7). Ignored
    /// when `resume` names a token: the token carries its own, so a page
    /// that took a while does not drift forward.
    history_upper: u64,

    work: Work,
    build: Builder,
};

/// Fills in the original, immutable `begin` response. Runs on the app
/// thread inside `begin`, before the worker starts, with the job's id and
/// token already chosen; the slice it returns is owned by the job.
pub const Builder = struct {
    ctx: ?*anyopaque = null,
    build: *const fn (ctx: ?*anyopaque, job: *Job) (Allocator.Error || error{ReplyExceedsBudget})![]const u8,
};

pub const BeginOutcome = struct {
    job: *Job,

    /// True when this call found the original and did not start anything.
    reused: bool,
};

pub const BeginError = Allocator.Error || error{
    Busy,
    RequestIdConflict,
    CursorExpired,
    CursorMismatch,
    Expired,
    Entropy,
    ThreadFailed,
    ReplyExceedsBudget,
};

/// What an existing `request_id` means for a new request (task 2835,
/// contract §7): the original begin response must be handed back before
/// anything is rebuilt, so a snapshot that has grown since cannot turn a
/// retry into `TooLarge` or a different answer.
pub const Reuse = union(enum) {
    none,
    reused: *Job,
    conflict,
    expired,
};

pub const PollOutcome = union(enum) {
    pending: *Job,
    ready: *Job,
    cancelled: *Job,
    failed: *Job,
    expired,
};

pub const PollError = error{NoSuchJob};

pub const CancelError = error{NoSuchJob};

pub const Job = struct {
    alloc: Allocator,
    clock: Clock,

    /// Written once by `begin` on the app thread, then immutable.
    id: [id_len]u8,
    request_id: []const u8,
    group: []const u8,
    limit: usize,

    /// The token this job's next page will be named by, chosen at `begin`.
    /// The runner writes it into the page; `poll` registers the cursor it
    /// stood for, once, the first time the page is handed over.
    token: [id_len]u8,

    /// Where the scan starts and the question it answers.
    cursor: ?Cursor,

    /// The token this job was started from, if any. Kept as the client gave
    /// it so that a retried `begin` hashes the same as the first one did.
    resume_id: ?[id_len]u8 = null,

    history_upper: u64,
    before_seq: u64,

    /// Filled by the runner before the state is published.
    bytes: ?[]const u8 = null,
    next: ?Cursor = null,
    token_used: bool = false,
    failure: ?Failure = null,

    /// Kept by `begin`; returned unchanged every time the same request is
    /// asked for (`BeginOutcome.reused`).
    begin_bytes: []const u8,

    /// Set by the runner before the state store; read after `state`.
    state: std.atomic.Value(State) = .init(.pending),
    cancelled: std.atomic.Value(bool) = .init(false),

    /// The app thread's, once the state is terminal.
    delivered: bool = false,
    token_registered: bool = false,
    finished_ms: u64 = unset_ms,

    work: Work,
    thread: ?std.Thread = null,

    /// The runner's own allocations, freed when the job is dropped.
    arena: std.heap.ArenaAllocator,

    /// Publish a page. **The cancel check is inside this function on
    /// purpose**: a publisher that only looked at the flag would still race
    /// a cancel that landed between the look and the store.
    pub fn completeReady(self: *Job, bytes: []const u8, next: ?Cursor, token_used: bool) void {
        self.complete(.ready, bytes, next, token_used, null);
    }

    /// A failed scan still has a body -- the contract wants an explicit
    /// error code, and TooLarge carries the token that resumes at the
    /// record which did not fit.
    pub fn completeFailed(self: *Job, why: Failure, bytes: []const u8, next: ?Cursor, token_used: bool) void {
        self.complete(.failed, bytes, next, token_used, why);
    }

    /// The runner stopped because somebody cancelled. Nothing a host will
    /// read came out of it.
    pub fn completeCancelled(self: *Job) void {
        if (self.finished_ms == unset_ms) self.finished_ms = self.clock.read();
        self.state.store(.cancelled, .release);
    }

    fn complete(
        self: *Job,
        want: State,
        bytes: []const u8,
        next: ?Cursor,
        token_used: bool,
        why: ?Failure,
    ) void {
        if (self.cancelled.load(.acquire)) {
            // **The runner's bytes are the job's from the moment they are
            // passed here**, so the cancelled path has to let them go: the
            // page will never be stored, and the publisher must not free
            // them as well. Non-empty only, matching `drop`.
            if (bytes.len > 0) self.alloc.free(bytes);
            if (self.finished_ms == unset_ms) self.finished_ms = self.clock.read();
            self.state.store(.cancelled, .release);
            return;
        }
        self.bytes = bytes;
        self.next = next;
        self.token_used = token_used;
        self.failure = why;
        self.finished_ms = self.clock.read();
        self.state.store(want, .release);
    }

    pub fn cancelledByOwner(self: *Job) bool {
        return self.cancelled.load(.acquire);
    }

    /// The state as the app thread may read it: after this load, everything
    /// the runner stored before its release store is visible.
    pub fn loadState(self: *const Job) State {
        return self.state.load(.acquire);
    }
};

const HistoryJobs = @This();

alloc: Allocator,
io: std.Io,
clock: Clock,

/// Every job this manager still recognises, tombstones included.
jobs: std.ArrayListUnmanaged(*Job) = .empty,

/// Every resume token that has not expired.
tokens: std.ArrayListUnmanaged(Token) = .empty,

/// Started threads not yet joined. Maintained only on the app thread;
/// read by `begin` to enforce `max_running`.
running: usize = 0,

/// Threads in production; `immediate` runs the work inside `begin`, which
/// is what the state-machine tests use. It is not a debug switch: a
/// caller that has no thread for a reason may use it.
mode: Mode = .thread,

pub const Mode = enum { thread, immediate };

const Token = struct {
    id: [id_len]u8,
    group: []u8,
    cursor: Cursor,
    history_upper: u64,
    expires_ms: u64,
};

pub fn init(alloc: Allocator, io: std.Io, clock: Clock) HistoryJobs {
    return .{ .alloc = alloc, .io = io, .clock = clock };
}

/// Stop every worker and free everything. **Joins, never detaches**:
/// after this returns, no thread can write into memory this manager
/// owned.
pub fn deinit(self: *HistoryJobs) void {
    for (self.jobs.items) |job| job.cancelled.store(true, .release);
    for (self.jobs.items) |job| self.drop(job);
    self.jobs.deinit(self.alloc);
    for (self.tokens.items) |t| self.alloc.free(t.group);
    self.tokens.deinit(self.alloc);
    self.* = undefined;
}

/// The original job for a request that was already made, if there is
/// one. **`begin` repeats this check itself**; the app calls it first
/// so that a retry never rebuilds a snapshot or reports `TooLarge`
/// before the fixed original is found.
pub fn reuseRequest(
    self: *HistoryJobs,
    request_id: []const u8,
    group: []const u8,
    limit: usize,
    resume_token: ?[id_len]u8,
) Reuse {
    self.sweep();
    const job = self.findByRequest(request_id) orelse return .none;
    if (!sameParams(job, group, limit, resume_token)) return .conflict;
    return switch (job.loadState()) {
        .expired => .expired,
        else => .{ .reused = job },
    };
}

/// Register a job and start it. `begin` does no I/O of its own: the
/// builder copies what the response needs, and `work` carries what the
/// scan needs.
pub fn begin(self: *HistoryJobs, req: Begin) BeginError!BeginOutcome {
    // **`begin` takes the work, whatever happens.** A caller that
    // started building the scan for a request that was then refused
    // must not have to know which side releases it; the manager does,
    // on every path. Once the job exists its `drop` is what releases.
    var work_owned = true;
    defer if (work_owned) req.work.release(self.alloc, req.work.ctx);

    if (req.request_id.len == 0 or req.request_id.len > max_request_id) return error.RequestIdConflict;

    self.sweep();

    // **Same request_id means the same request.** A retry after the
    // host lost its length probe must find the original job, not start
    // a second scan; a different request under the same id is a caller
    // bug and is refused rather than silently answered as the other.
    if (self.findByRequest(req.request_id)) |found| {
        // **Structural, not a hash.** The table is a linear scan, so
        // there is no hash to collide: every field the request id is
        // bound to is compared as itself.
        if (!sameRequest(found, req)) return error.RequestIdConflict;
        return switch (found.loadState()) {
            .expired => error.Expired,
            else => .{ .job = found, .reused = true },
        };
    }

    // A resume token names the physical position; the manager resolves
    // it here so the worker never reads the token table.
    var cursor: ?Cursor = null;
    var history_upper = req.history_upper;
    if (req.resume_token) |id| {
        const token = self.lookupToken(id) orelse return error.CursorExpired;
        if (!std.mem.eql(u8, token.group, req.group)) return error.CursorMismatch;
        cursor = token.cursor;
        history_upper = token.history_upper;
    }

    if (self.running >= max_running) return error.Busy;

    // Everything the job owns is made before the job exists, so a
    // failure here frees it and nothing half-built is left behind.
    const parts = blk: {
        const request_id = try self.alloc.dupe(u8, req.request_id);
        errdefer self.alloc.free(request_id);
        const group = try self.alloc.dupe(u8, req.group);
        errdefer self.alloc.free(group);
        const id = try newOpaqueId(self.io);
        const token = try newOpaqueId(self.io);
        break :blk .{
            .request_id = request_id,
            .group = group,
            .id = id,
            .token = token,
        };
    };

    const job = try self.alloc.create(Job);
    // Anything that fails below returns through this, so the work's
    // context is released exactly once and nothing half-made leaks.
    // Cleared only once the job is in the table and started.
    var owned = false;
    defer if (!owned) self.drop(job);

    job.* = .{
        .alloc = self.alloc,
        .clock = self.clock,
        .id = parts.id,
        .request_id = parts.request_id,
        .group = parts.group,
        .limit = req.limit,
        .token = parts.token,
        .cursor = cursor,
        .resume_id = req.resume_token,
        .history_upper = history_upper,
        .before_seq = beforeSeq(history_upper),
        .begin_bytes = &.{},
        .work = req.work,
        .arena = .init(self.alloc),
    };
    work_owned = false;

    job.begin_bytes = req.build.build(req.build.ctx, job) catch |err| return err;

    try self.jobs.append(self.alloc, job);
    self.running += 1;

    switch (self.mode) {
        .immediate => {
            req.work.run(req.work.ctx, job);
            if (job.loadState() != .pending) self.running -= 1;
        },
        .thread => {
            job.thread = std.Thread.spawn(.{}, runWork, .{job}) catch |err| {
                _ = self.remove(job);
                self.running -= 1;
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.ThreadFailed,
                };
            };
        },
    }
    owned = true;

    return .{ .job = job, .reused = false };
}

/// The state of one job, never blocking on the scan.
///
/// A `ready` poll is a delivery: the page is marked so that a later
/// eviction prefers finishing off pages nobody has read. The first
/// ready poll also registers the continuation token, if the page has
/// one -- a token for a page the host never receives is never needed.
pub fn poll(self: *HistoryJobs, id: [id_len]u8) PollError!PollOutcome {
    self.sweep();

    const job = self.findById(id) orelse return error.NoSuchJob;
    self.observe(job);

    // **Cancel wins over whatever the thread published.** A page that
    // arrived at the same moment as the cancel must not be handed over:
    // the host has said it is done with this load.
    if (job.cancelled.load(.acquire)) return .{ .cancelled = job };

    return switch (job.loadState()) {
        .pending => .{ .pending = job },
        .ready => blk: {
            job.delivered = true;
            self.registerToken(job);
            break :blk .{ .ready = job };
        },
        // **A failed page is still a delivery.** TooLarge carries the
        // token that resumes at the record which did not fit, and a token
        // never registered is one the next `begin` refuses as
        // `CursorExpired` -- the JSON would name a position the manager
        // has forgotten. `registerToken` registers only when `next` is
        // there, so an ordinary failure with no continuation is unchanged.
        .failed => blk: {
            job.delivered = true;
            self.registerToken(job);
            break :blk .{ .failed = job };
        },
        .cancelled => .{ .cancelled = job },
        .expired => .expired,
    };
}

/// Idempotent: cancelling a job twice, or after it finished, succeeds
/// and frees what the page held. The thread is not killed; the flag and
/// the scan's own checks are what stop it, and the next `sweep` joins.
pub fn cancel(self: *HistoryJobs, id: [id_len]u8) CancelError!*Job {
    self.sweep();
    const job = self.findById(id) orelse return error.NoSuchJob;
    job.cancelled.store(true, .release);
    switch (job.loadState()) {
        // The runner owns the transition while it is running: it will
        // see the flag and publish `cancelled` itself. Writing the
        // state here would not stop it, and joining here would park
        // the app thread for however long the current step takes.
        .pending => {},
        else => {
            if (job.finished_ms == unset_ms) job.finished_ms = self.clock.read();
            job.state.store(.cancelled, .release);
            self.observe(job);
            self.freeResult(job);
        },
    }
    return job;
}

/// Give the app thread a view of the whole table, for its own summary
/// (there is no such thing as a free late thread: see `sweep`).
pub fn sweepNow(self: *HistoryJobs) void {
    self.sweep();
}

fn runWork(job: *Job) void {
    job.work.run(job.work.ctx, job);
}

fn findByRequest(self: *HistoryJobs, request_id: []const u8) ?*Job {
    for (self.jobs.items) |job| {
        if (std.mem.eql(u8, job.request_id, request_id)) return job;
    }
    return null;
}

fn findById(self: *HistoryJobs, id: [id_len]u8) ?*Job {
    for (self.jobs.items) |job| {
        if (std.mem.eql(u8, &job.id, &id)) return job;
    }
    return null;
}

/// A token still in the table, borrowed. **Not consumed**: a host that
/// retried a lost `begin` must be able to ask again with the token it
/// holds; the token's TTL is what bounds the table.
fn lookupToken(self: *HistoryJobs, id: [id_len]u8) ?Token {
    var i: usize = 0;
    while (i < self.tokens.items.len) {
        const t = self.tokens.items[i];
        if (self.clock.read() >= t.expires_ms) {
            self.alloc.free(t.group);
            _ = self.tokens.swapRemove(i);
            continue;
        }
        if (std.mem.eql(u8, &t.id, &id)) return t;
        i += 1;
    }
    return null;
}

fn registerToken(self: *HistoryJobs, job: *Job) void {
    const next = job.next orelse return;
    if (!job.token_used or job.token_registered) return;
    job.token_registered = true;

    const group = self.alloc.dupe(u8, job.group) catch return;
    if (self.tokens.items.len >= max_tokens) {
        // The oldest deadline goes: every token has the same lifetime,
        // so that is the one issued first. Forgetting it answers
        // `CursorExpired`, which the host handles by reloading a page.
        var oldest: usize = 0;
        for (self.tokens.items, 0..) |t, i| {
            if (t.expires_ms < self.tokens.items[oldest].expires_ms) oldest = i;
        }
        self.alloc.free(self.tokens.items[oldest].group);
        _ = self.tokens.orderedRemove(oldest);
    }
    self.tokens.append(self.alloc, .{
        .id = job.token,
        .group = group,
        .cursor = next,
        .history_upper = job.history_upper,
        .expires_ms = self.clock.read() + token_ttl_ms,
    }) catch {
        self.alloc.free(group);
    };
}

/// Join a job whose thread has finished and give its running slot back.
/// The worker stores the state and then returns, so a join here waits
/// for at most the return itself.
fn observe(self: *HistoryJobs, job: *Job) void {
    if (job.loadState() == .pending) return;
    if (job.thread) |t| {
        t.join();
        job.thread = null;
        if (self.running > 0) self.running -= 1;
    }
}

/// Expire finished results past their TTL, evict the oldest finished
/// result past the ceiling, and forget tombstones that are past theirs.
/// Swept by calls rather than by a timer, like the screenshot waits --
/// there is no work to do on an idle app, and a callback would be one
/// more thing running at quit.
fn sweep(self: *HistoryJobs) void {
    const now = self.clock.read();
    var i: usize = 0;
    while (i < self.jobs.items.len) {
        const job = self.jobs.items[i];
        self.observe(job);
        switch (job.loadState()) {
            .ready, .failed => {
                if (job.finished_ms != unset_ms and now -| job.finished_ms >= result_ttl_ms) {
                    self.expire(job);
                }
            },
            .expired, .cancelled => {
                if (job.finished_ms != unset_ms and now -| job.finished_ms >= tombstone_ttl_ms) {
                    _ = self.remove(job);
                    self.drop(job);
                    continue;
                }
            },
            .pending => {},
        }
        i += 1;
    }

    // The result ceiling is about pages the host could still read.
    while (self.finishedCount() > max_finished) {
        const victim = self.evictionVictim() orelse break;
        self.expire(victim);
    }

    // **TTL is not a bound.** A paging host can evict many finished
    // pages a minute, and five minutes of tombstones is still a list
    // that grows with the traffic. Past the ceiling the oldest is
    // forgotten, and `poll` on it answers `NoSuchJob`: only an id still
    // in the table gets the precise `Expired`.
    while (self.tombstoneCount() > max_tombstones) {
        const victim = self.oldestTombstone() orelse break;
        _ = self.remove(victim);
        self.drop(victim);
    }

    // Tokens that ran out are dropped here too, so `begin` with one is
    // answered `CursorExpired` by `lookupToken` rather than by luck.
    var k: usize = 0;
    while (k < self.tokens.items.len) {
        const t = self.tokens.items[k];
        if (now >= t.expires_ms) {
            self.alloc.free(t.group);
            _ = self.tokens.swapRemove(k);
            continue;
        }
        k += 1;
    }
}

fn tombstoneCount(self: *const HistoryJobs) usize {
    var n: usize = 0;
    for (self.jobs.items) |job| {
        switch (job.loadState()) {
            .expired, .cancelled => n += 1,
            else => {},
        }
    }
    return n;
}

fn oldestTombstone(self: *HistoryJobs) ?*Job {
    var best: ?*Job = null;
    for (self.jobs.items) |job| {
        switch (job.loadState()) {
            .expired, .cancelled => {},
            else => continue,
        }
        const b = best orelse {
            best = job;
            continue;
        };
        if (job.finished_ms < b.finished_ms) best = job;
    }
    return best;
}

fn finishedCount(self: *const HistoryJobs) usize {
    var n: usize = 0;
    for (self.jobs.items) |job| {
        switch (job.loadState()) {
            .ready, .failed => n += 1,
            else => {},
        }
    }
    return n;
}

fn evictionVictim(self: *HistoryJobs) ?*Job {
    var best: ?*Job = null;
    for (self.jobs.items) |job| {
        switch (job.loadState()) {
            .ready, .failed => {},
            else => continue,
        }
        const b = best orelse {
            best = job;
            continue;
        };
        // Delivered first, then the oldest finish.
        if (job.delivered != b.delivered) {
            if (job.delivered) best = job;
            continue;
        }
        if (job.finished_ms < b.finished_ms) best = job;
    }
    return best;
}

fn expire(self: *HistoryJobs, job: *Job) void {
    if (job.loadState() == .expired) return;
    if (job.finished_ms == unset_ms) job.finished_ms = self.clock.read();
    job.state.store(.expired, .release);
    job.token_used = false;
    self.freeResult(job);
}

/// Free the page bytes. Called only after `observe`, so the thread that
/// published them has returned.
fn freeResult(self: *HistoryJobs, job: *Job) void {
    if (job.bytes) |b| {
        if (b.len > 0) self.alloc.free(b);
        job.bytes = null;
    }
}

fn remove(self: *HistoryJobs, job: *Job) bool {
    for (self.jobs.items, 0..) |j, i| {
        if (j == job) {
            _ = self.jobs.swapRemove(i);
            return true;
        }
    }
    return false;
}

/// Free a job after joining its thread. The one place that knows what a
/// job owns.
fn drop(self: *HistoryJobs, job: *Job) void {
    job.cancelled.store(true, .release);
    if (job.thread) |t| {
        t.join();
        job.thread = null;
    }
    self.alloc.free(job.request_id);
    self.alloc.free(job.group);
    if (job.begin_bytes.len > 0) self.alloc.free(job.begin_bytes);
    if (job.bytes) |b| if (b.len > 0) self.alloc.free(b);
    job.work.release(self.alloc, job.work.ctx);
    job.arena.deinit();
    self.alloc.destroy(job);
}

/// The client's parameters, compared as themselves.
fn sameRequest(job: *const Job, req: Begin) bool {
    return sameParams(job, req.group, req.limit, req.resume_token);
}

fn sameParams(job: *const Job, group: []const u8, limit: usize, resume_token: ?[id_len]u8) bool {
    if (!std.mem.eql(u8, job.group, group)) return false;
    if (job.limit != limit) return false;
    const held = job.resume_id;
    if (held == null and resume_token == null) return true;
    if (held == null or resume_token == null) return false;
    return std.mem.eql(u8, &held.?, &resume_token.?);
}

fn beforeSeq(upper: u64) u64 {
    return if (upper == std.math.maxInt(u64)) 0 else upper + 1;
}

pub fn newOpaqueId(io: std.Io) error{Entropy}![id_len]u8 {
    var raw: [16]u8 = undefined;
    io.randomSecure(&raw) catch return error.Entropy;
    var out: [id_len]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{&raw}) catch unreachable;
    return out;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const TestClock = struct {
    now_ms: u64 = 0,

    fn clock(self: *TestClock) Clock {
        return .{ .ctx = self, .now = read };
    }

    fn read(ctx: ?*const anyopaque) u64 {
        const self: *const TestClock = @ptrCast(@alignCast(ctx orelse return 0));
        return self.now_ms;
    }
};

const Fake = struct {
    body: []const u8 = "READY",
    next: ?Cursor = null,
    token_used: bool = false,
    /// When set, the runner waits until it is true, looking at the cancel
    /// flag between sleeps. For the running tests.
    gate: ?*std.atomic.Value(bool) = null,

    /// Publish a TooLarge failure instead of a ready page.
    fail: bool = false,

    /// What the runner saw, for the resume tests.
    seen_cursor: ?Cursor = null,
    seen_before_seq: u64 = 0,
};

fn fakeRun(ctx: ?*anyopaque, job: *Job) void {
    const f: *Fake = @ptrCast(@alignCast(ctx orelse return));
    f.seen_cursor = job.cursor;
    f.seen_before_seq = job.before_seq;

    if (f.gate) |gate| {
        while (!gate.load(.acquire)) {
            if (job.cancelledByOwner()) {
                job.completeCancelled();
                return;
            }
            std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }
    if (job.cancelledByOwner()) {
        job.completeCancelled();
        return;
    }
    const bytes = job.alloc.dupe(u8, f.body) catch return;
    if (f.fail) {
        job.completeFailed(.too_large, bytes, f.next, f.token_used);
    } else {
        job.completeReady(bytes, f.next, f.token_used);
    }
}

fn fakeRelease(alloc: Allocator, ctx: ?*anyopaque) void {
    if (ctx) |c| alloc.destroy(@as(*Fake, @ptrCast(@alignCast(c))));
}

fn fakeWork(alloc: Allocator) Work {
    const f = alloc.create(Fake) catch unreachable;
    f.* = .{};
    return .{ .ctx = f, .run = fakeRun, .release = fakeRelease };
}

fn fakeBuild(_: ?*anyopaque, job: *Job) (Allocator.Error || error{ReplyExceedsBudget})![]const u8 {
    return job.alloc.dupe(u8, "BEGIN");
}

fn immediateManager(alloc: Allocator, io: std.Io, clock: Clock) HistoryJobs {
    var m = HistoryJobs.init(alloc, io, clock);
    m.mode = .immediate;
    return m;
}

test "2835: the same request is one job; other parameters under the same id are refused" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var m = immediateManager(alloc, testing.io, clock.clock());
    defer m.deinit();

    const first = try m.begin(.{
        .request_id = "probe-1",
        .group = "build",
        .limit = 50,
        .history_upper = 10,
        .work = fakeWork(alloc),
        .build = .{ .build = fakeBuild },
    });
    try testing.expect(!first.reused);

    // A retry with the same parameters must not start a second scan and
    // must hand back the original begin response, not a ready page.
    const again = try m.begin(.{
        .request_id = "probe-1",
        .group = "build",
        .limit = 50,
        .history_upper = 10,
        .work = .{ .run = fakeRun, .release = fakeRelease },
        .build = .{ .build = fakeBuild },
    });
    try testing.expect(again.reused);
    try testing.expect(again.job == first.job);
    try testing.expectEqualStrings("BEGIN", again.job.begin_bytes);

    // Same id, different limit: a caller bug, said so plainly.
    try testing.expectError(error.RequestIdConflict, m.begin(.{
        .request_id = "probe-1",
        .group = "build",
        .limit = 20,
        .history_upper = 10,
        .work = .{ .run = fakeRun, .release = fakeRelease },
        .build = .{ .build = fakeBuild },
    }));

    // Longer than the key ceiling.
    const long = "x" ** (max_request_id + 1);
    try testing.expectError(error.RequestIdConflict, m.begin(.{
        .request_id = long,
        .group = "build",
        .limit = 50,
        .history_upper = 10,
        .work = .{ .run = fakeRun, .release = fakeRelease },
        .build = .{ .build = fakeBuild },
    }));
}

test "2835: pending is not an empty page, and a ready page is handed over unchanged" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var m = immediateManager(alloc, testing.io, clock.clock());
    defer m.deinit();

    // A runner that stops without publishing: the state is `pending`, not
    // `ready` with an empty page.
    const still = try m.begin(.{
        .request_id = "pending-1",
        .group = "build",
        .limit = 50,
        .history_upper = 10,
        .work = .{ .run = fakeRun, .release = fakeRelease },
        .build = .{ .build = fakeBuild },
    });
    switch (try m.poll(still.job.id)) {
        .pending => {},
        else => return error.ExpectedPending,
    }

    const done = try m.begin(.{
        .request_id = "ready-1",
        .group = "build",
        .limit = 50,
        .history_upper = 10,
        .work = fakeWork(alloc),
        .build = .{ .build = fakeBuild },
    });

    // Two polls, same bytes, and the second asks the scan for nothing.
    const one = try m.poll(done.job.id);
    try testing.expect(one == .ready);
    try testing.expectEqualStrings("READY", one.ready.bytes.?);
    try testing.expect(one.ready.delivered);

    const two = try m.poll(done.job.id);
    try testing.expect(two == .ready);
    try testing.expectEqualStrings("READY", two.ready.bytes.?);
    try testing.expect(two.ready == one.ready);
}

test "2835: two running jobs are the ceiling, and finishing frees a slot" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var m = HistoryJobs.init(alloc, testing.io, clock.clock());
    defer m.deinit();
    try testing.expectEqual(HistoryJobs.Mode.thread, m.mode);

    var gate: std.atomic.Value(bool) = .init(false);

    _ = try m.begin(.{
        .request_id = "run-1",
        .group = "build",
        .limit = 10,
        .history_upper = 1,
        .work = gatedWork(alloc, &gate),
        .build = .{ .build = fakeBuild },
    });
    _ = try m.begin(.{
        .request_id = "run-2",
        .group = "build",
        .limit = 10,
        .history_upper = 1,
        .work = gatedWork(alloc, &gate),
        .build = .{ .build = fakeBuild },
    });
    try testing.expectError(error.Busy, m.begin(.{
        .request_id = "run-3",
        .group = "build",
        .limit = 10,
        .history_upper = 1,
        .work = gatedWork(alloc, &gate),
        .build = .{ .build = fakeBuild },
    }));

    gate.store(true, .release);
    // Wait for both pages, then one more `begin` sweeps the finished
    // threads and finds a free slot.
    var waited: usize = 0;
    while (waited < 2000) : (waited += 1) {
        const a = try m.poll(m.jobs.items[0].id);
        const b = try m.poll(m.jobs.items[1].id);
        if (a == .ready and b == .ready) break;
        testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(waited < 2000);

    _ = try m.begin(.{
        .request_id = "run-3",
        .group = "build",
        .limit = 10,
        .history_upper = 1,
        .work = gatedWork(alloc, &gate),
        .build = .{ .build = fakeBuild },
    });
}

fn gatedWork(alloc: Allocator, gate: *std.atomic.Value(bool)) Work {
    const f = alloc.create(Fake) catch unreachable;
    f.* = .{ .gate = gate };
    return .{ .ctx = f, .run = fakeRun, .release = fakeRelease };
}

test "2835: a delivered page is evicted before an undelivered one" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var m = immediateManager(alloc, testing.io, clock.clock());
    defer m.deinit();

    var jobs: [max_finished]*Job = undefined;
    for (&jobs, 0..) |*slot, i| {
        const name = try std.fmt.allocPrint(alloc, "page-{d}", .{i});
        defer alloc.free(name);
        const out = try m.begin(.{
            .request_id = name,
            .group = "build",
            .limit = 10,
            .history_upper = 1,
            .work = fakeWork(alloc),
            .build = .{ .build = fakeBuild },
        });
        slot.* = out.job;
    }

    // Everybody but the newest page has been read.
    for (jobs[0 .. max_finished - 1]) |job| {
        switch (try m.poll(job.id)) {
            .ready => {},
            else => return error.ExpectedReady,
        }
    }

    // One more finished result than the ceiling allows. Its own poll sweeps
    // first, and the rule says the already-delivered oldest goes -- not
    // the page nobody has read.
    const last = try m.begin(.{
        .request_id = "page-last",
        .group = "build",
        .limit = 10,
        .history_upper = 1,
        .work = fakeWork(alloc),
        .build = .{ .build = fakeBuild },
    });
    switch (try m.poll(last.job.id)) {
        .ready => {},
        else => return error.ExpectedReady,
    }
    m.sweepNow();

    switch (try m.poll(jobs[0].id)) {
        .expired => {},
        else => return error.ExpectedExpired,
    }
    // The one that had not been delivered survives.
    switch (try m.poll(jobs[max_finished - 1].id)) {
        .ready => {},
        else => return error.ExpectedReady,
    }
}

test "2835: a result expires at its deadline and is forgotten later" {
    const alloc = testing.allocator;
    var clock: TestClock = .{ .now_ms = 1000 };
    var m = immediateManager(alloc, testing.io, clock.clock());
    defer m.deinit();

    const out = try m.begin(.{
        .request_id = "ttl-1",
        .group = "build",
        .limit = 10,
        .history_upper = 1,
        .work = fakeWork(alloc),
        .build = .{ .build = fakeBuild },
    });

    clock.now_ms += result_ttl_ms - 1;
    switch (try m.poll(out.job.id)) {
        .ready => {},
        else => return error.ExpectedReady,
    }

    clock.now_ms += 2;
    switch (try m.poll(out.job.id)) {
        .expired => {},
        else => return error.ExpectedExpired,
    }

    // The tombstone itself goes, so the table does not keep every job for
    // ever. `Expired` first, `NoSuchJob` after.
    clock.now_ms += tombstone_ttl_ms;
    try testing.expectError(error.NoSuchJob, m.poll(out.job.id));
}

test "2835: cancelling is idempotent and the page is never handed over" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var m = immediateManager(alloc, testing.io, clock.clock());
    defer m.deinit();

    const ready = try m.begin(.{
        .request_id = "cancel-1",
        .group = "build",
        .limit = 10,
        .history_upper = 1,
        .work = fakeWork(alloc),
        .build = .{ .build = fakeBuild },
    });
    switch (try m.poll(ready.job.id)) {
        .ready => {},
        else => return error.ExpectedReady,
    }

    _ = try m.cancel(ready.job.id);
    _ = try m.cancel(ready.job.id);
    switch (try m.poll(ready.job.id)) {
        .cancelled => {},
        else => return error.ExpectedCancelled,
    }

    // A job whose runner never published is cancelled through the flag,
    // without waiting for the scan.
    const pending = try m.begin(.{
        .request_id = "cancel-2",
        .group = "build",
        .limit = 10,
        .history_upper = 1,
        .work = .{ .run = fakeRun, .release = fakeRelease },
        .build = .{ .build = fakeBuild },
    });
    _ = try m.cancel(pending.job.id);
    switch (try m.poll(pending.job.id)) {
        .cancelled => {},
        else => return error.ExpectedCancelled,
    }

    try testing.expectError(error.NoSuchJob, m.cancel("00000000000000000000000000000000".*));
}

test "2835: a token resumes at its cursor and expires after five minutes" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var m = immediateManager(alloc, testing.io, clock.clock());
    defer m.deinit();

    const where: Cursor = .{
        .day = 20261104,
        .part = 2,
        .offset = 128,
        .end = 4096,
        .inode = 99,
        .question = 0x1234,
    };

    const first = try m.begin(.{
        .request_id = "tok-1",
        .group = "build",
        .limit = 10,
        .history_upper = 77,
        .work = blk: {
            const f = alloc.create(Fake) catch unreachable;
            f.* = .{ .next = where, .token_used = true };
            break :blk .{ .ctx = f, .run = fakeRun, .release = fakeRelease };
        },
        .build = .{ .build = fakeBuild },
    });
    switch (try m.poll(first.job.id)) {
        .ready => {},
        else => return error.ExpectedReady,
    }
    const token = first.job.token;

    // The next begin starts where the page stopped, carries the round's
    // own history head, and reports the same question.
    const resumed = try m.begin(.{
        .request_id = "tok-2",
        .group = "build",
        .limit = 10,
        .history_upper = 0,
        .resume_token = token,
        .work = fakeWork(alloc),
        .build = .{ .build = fakeBuild },
    });
    try testing.expectEqual(where, resumed.job.cursor.?);
    try testing.expectEqual(@as(u64, 77), resumed.job.history_upper);
    try testing.expectEqual(@as(u64, 78), resumed.job.before_seq);

    // A token is bound to its group.
    try testing.expectError(error.CursorMismatch, m.begin(.{
        .request_id = "tok-3",
        .group = "other",
        .limit = 10,
        .history_upper = 77,
        .resume_token = token,
        .work = fakeWork(alloc),
        .build = .{ .build = fakeBuild },
    }));

    // Unknown tokens are refused, not turned into a fresh first page.
    try testing.expectError(error.CursorExpired, m.begin(.{
        .request_id = "tok-4",
        .group = "build",
        .limit = 10,
        .history_upper = 77,
        .resume_token = "ffffffffffffffffffffffffffffffff".*,
        .work = fakeWork(alloc),
        .build = .{ .build = fakeBuild },
    }));

    clock.now_ms += token_ttl_ms;
    try testing.expectError(error.CursorExpired, m.begin(.{
        .request_id = "tok-5",
        .group = "build",
        .limit = 10,
        .history_upper = 77,
        .resume_token = token,
        .work = fakeWork(alloc),
        .build = .{ .build = fakeBuild },
    }));
}

test "2835: a running job cancelled by the app stops as cancelled" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var m = HistoryJobs.init(alloc, testing.io, clock.clock());
    defer m.deinit();

    var gate: std.atomic.Value(bool) = .init(false);
    const out = try m.begin(.{
        .request_id = "running-cancel",
        .group = "build",
        .limit = 10,
        .history_upper = 1,
        .work = gatedWork(alloc, &gate),
        .build = .{ .build = fakeBuild },
    });

    _ = try m.cancel(out.job.id);
    gate.store(true, .release);

    var waited: usize = 0;
    while (waited < 2000) : (waited += 1) {
        switch (try m.poll(out.job.id)) {
            .cancelled => break,
            .pending => testing.io.sleep(.fromMilliseconds(1), .awake) catch {},
            else => return error.ExpectedCancelled,
        }
    }
    try testing.expect(waited < 2000);
}

test "2835: every refused begin releases the work exactly once" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var m = HistoryJobs.init(alloc, testing.io, clock.clock());
    defer m.deinit();

    const Counter = struct {
        released: usize = 0,
    };
    var counter: Counter = .{};

    const countedRun = struct {
        fn run(_: ?*anyopaque, _: *Job) void {}
        fn release(_: Allocator, ctx: ?*anyopaque) void {
            const c: *Counter = @ptrCast(@alignCast(ctx orelse return));
            c.released += 1;
        }
    };

    // A builder that fails after the job exists: `drop` is the release.
    const failingBuild = struct {
        fn build(_: ?*anyopaque, _: *Job) (Allocator.Error || error{ReplyExceedsBudget})![]const u8 {
            return error.ReplyExceedsBudget;
        }
    };
    try testing.expectError(error.ReplyExceedsBudget, m.begin(.{
        .request_id = "own-0",
        .group = "build",
        .limit = 10,
        .history_upper = 1,
        .work = .{ .ctx = &counter, .run = countedRun.run, .release = countedRun.release },
        .build = .{ .build = failingBuild.build },
    }));
    try testing.expectEqual(@as(usize, 1), counter.released);

    // Fill both running slots, then a third request is Busy: the work never
    // starts, and the manager still lets it go exactly once.
    var gate: std.atomic.Value(bool) = .init(false);
    _ = try m.begin(.{
        .request_id = "own-1",
        .group = "build",
        .limit = 10,
        .history_upper = 1,
        .work = gatedWork(alloc, &gate),
        .build = .{ .build = fakeBuild },
    });
    _ = try m.begin(.{
        .request_id = "own-1b",
        .group = "build",
        .limit = 10,
        .history_upper = 1,
        .work = gatedWork(alloc, &gate),
        .build = .{ .build = fakeBuild },
    });

    try testing.expectError(error.Busy, m.begin(.{
        .request_id = "own-2",
        .group = "build",
        .limit = 10,
        .history_upper = 1,
        .work = .{ .ctx = &counter, .run = countedRun.run, .release = countedRun.release },
        .build = .{ .build = fakeBuild },
    }));
    try testing.expectEqual(@as(usize, 2), counter.released);

    gate.store(true, .release);
    var waited: usize = 0;
    while (waited < 2000) : (waited += 1) {
        switch (try m.poll(m.jobs.items[0].id)) {
            .ready => break,
            .pending => testing.io.sleep(.fromMilliseconds(1), .awake) catch {},
            else => return error.ExpectedReady,
        }
    }
    try testing.expect(waited < 2000);
}

test "2835: a TooLarge page registers its token for the next begin" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var m = immediateManager(alloc, testing.io, clock.clock());
    defer m.deinit();

    const where: Cursor = .{
        .day = 20261104,
        .part = 1,
        .offset = 64,
        .end = 8192,
        .inode = 7,
        .question = 0x99,
    };

    const out = try m.begin(.{
        .request_id = "too-large-1",
        .group = "build",
        .limit = 10,
        .history_upper = 77,
        .work = blk: {
            const f = alloc.create(Fake) catch unreachable;
            f.* = .{ .fail = true, .next = where, .token_used = true };
            break :blk .{ .ctx = f, .run = fakeRun, .release = fakeRelease };
        },
        .build = .{ .build = fakeBuild },
    });

    switch (try m.poll(out.job.id)) {
        .failed => |j| try testing.expectEqual(where, j.next.?),
        else => return error.ExpectedFailed,
    }

    // The JSON named this token; it must now name a position the manager
    // still knows. Without the registration this is `CursorExpired`.
    const resumed = try m.begin(.{
        .request_id = "too-large-2",
        .group = "build",
        .limit = 10,
        .history_upper = 0,
        .resume_token = out.job.token,
        .work = fakeWork(alloc),
        .build = .{ .build = fakeBuild },
    });
    try testing.expectEqual(where, resumed.job.cursor.?);
    try testing.expectEqual(@as(u64, 77), resumed.job.history_upper);
    try testing.expectEqual(@as(u64, 78), resumed.job.before_seq);
}

test "2835: a result that arrives after cancel is freed exactly once" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var m = immediateManager(alloc, testing.io, clock.clock());
    defer m.deinit();

    // A job whose runner never published, then cancelled: the flag is set
    // while the thread is still at `pending`, exactly the race the worker's
    // publish is written for.
    const out = try m.begin(.{
        .request_id = "late-cancel",
        .group = "build",
        .limit = 10,
        .history_upper = 1,
        .work = .{ .run = fakeRun, .release = fakeRelease },
        .build = .{ .build = fakeBuild },
    });
    _ = try m.cancel(out.job.id);

    // Both publishers hand over a freshly allocated body; the cancelled
    // path must free it and store nothing. `testing.allocator` catches a
    // leak or a second free at the end of the test.
    const ready_bytes = try alloc.dupe(u8, "LATE-READY");
    out.job.completeReady(ready_bytes, null, false);
    try testing.expect(out.job.bytes == null);
    try testing.expectEqual(State.cancelled, out.job.loadState());

    const failed_bytes = try alloc.dupe(u8, "LATE-FAIL");
    out.job.completeFailed(.too_large, failed_bytes, null, true);
    try testing.expect(out.job.bytes == null);
    try testing.expectEqual(State.cancelled, out.job.loadState());
}
