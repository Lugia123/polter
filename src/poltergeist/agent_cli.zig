//! Agent CLIs, as plugins describe them.
//!
//! The role system does not know what Claude Code is. It knows that a
//! plugin's manifest may carry an `agent_cli` section (`Plugin.AgentCli`),
//! and that the adapter it names answers two questions:
//!
//!   * `inventory` -- which skills and MCP servers this CLI has on this
//!     machine, each with what a person needs to decide about it; and
//!     whether this adapter can start the CLI in a session it is handed
//!     (`"resume": true`).
//!   * `launch` -- the command line that starts this CLI wearing a role,
//!     going on with the session the request names when it names one.
//!   * `identify` -- whether the CLI a terminal's agent is running, started
//!     by hand and so without hooks, is this one, and which session it is
//!     in (task 1635; `Identities`). Optional: an adapter that does not
//!     answer it recognises nothing, and says so by failing.
//!
//! Adding a CLI is adding a plugin that answers both. Nothing here changes.
//! The contract is in `dev-docs/poltergeist/roles.md` part eleven; the
//! Claude Code side is `plugins/claude-code/adapter.py`.
//!
//! # Why a one-shot adapter and not the resident process
//!
//! Every other plugin conversation is the resident protocol: events in,
//! acknowledgements out. That protocol has no way to ask one plugin a
//! question and wait for its answer -- the feed is a broadcast -- and these
//! two are questions. They are also pure: the same files in, the same
//! answer out, nothing kept between calls. So the adapter is a separate
//! executable named by the manifest, run once per question with the
//! request as its second argument, and it is not the plugin's resident
//! process. A plugin can have both (the Claude Code one does).
//!
//! # Where each question is asked
//!
//! Never on the app thread, which is every terminal's thread:
//!
//!   * `inventory` is kept in a `Cache`, refreshed on a thread of its own.
//!     The window and `role_clis` read the cache, which is a copy.
//!   * `launch` is asked by `polter +launch`, inside the new terminal, just
//!     before that process becomes the CLI. See `cli/launch.zig`.

const std = @import("std");
const internal_os = @import("../os/main.zig");
const Allocator = std.mem.Allocator;

const Plugin = @import("Plugin.zig");
const persona = @import("persona.zig");
const login_path = @import("login_path.zig");
const reap = @import("reap.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.poltergeist);

/// The contract version both sides speak. In every request and every
/// answer, so that an adapter written for a later Polter can say so.
pub const contract_version = 1;

/// Longest answer read from an adapter. A machine with every plugin under
/// the sun is a few hundred items of a few hundred bytes.
pub const max_answer = 4 * 1024 * 1024;

/// How long an adapter gets. It reads a handful of files; this is generous
/// so that a cold disk is not a failure, and short enough that a hung one
/// does not keep a window saying "reading" for a minute.
pub const timeout_ms = 15_000;

/// One adapter, found.
pub const Adapter = struct {
    /// The plugin's key, which is also the CLI's key in `personas.json`.
    key: []const u8,
    label: []const u8,
    bin: []const u8,
    adapter: []const u8,
    /// `Plugin.AgentCli.identify_env`: the only variables of a sidecar's
    /// environment this adapter is ever shown.
    identify_env: []const []const u8,
};

/// Where one agent CLI stands on this machine, for the question "can it be
/// started here, and if not, what would the person do about it" (task
/// 1677). **Two of these used to be one answer** ("no adapter"), and the
/// person can do something about one of them and not the other: a plugin
/// that is off is a switch in Plugins, an adapter nothing here can run is
/// not fixed by any switch.
pub const Standing = enum {
    /// Plugin on, adapter runnable: it can be started.
    ok,
    /// Plugin installed and switched off.
    off,
    /// Plugin on, but nothing on this system can run its adapter
    /// (`Plugin.Manifest.runnable`).
    cannot_run,
};

/// A plugin that manages an agent CLI, found, and where it stands.
pub const Found = struct {
    adapter: Adapter,
    standing: Standing,
};

/// Every plugin on the search path that manages an agent CLI, switched on
/// or not, sorted by key. A CLI no plugin manages is not here: that is the
/// third answer, "absent".
///
/// The same rules as the app's own plugin scan, which is the point of
/// `Plugin.searchPath`: the user's copy of a plugin wins over the shipped
/// one, a leading `_` is not a plugin, and two directories claiming one key
/// keep the first.
///
/// Everything returned belongs to `arena`.
pub fn survey(
    arena: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) []const Found {
    var found: std.ArrayListUnmanaged(Found) = .empty;
    var dirs: std.StringHashMapUnmanaged(void) = .empty;
    var keys: std.StringHashMapUnmanaged(void) = .empty;

    for (Plugin.searchPath(arena, io, environ_map)) |base| {
        var dir = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len > 0 and entry.name[0] == '_') continue;
            if (dirs.contains(entry.name)) continue;

            const name = arena.dupe(u8, entry.name) catch continue;
            dirs.put(arena, name, {}) catch {};

            const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ base, name }) catch continue;
            const manifest = Plugin.load(arena, io, path) catch continue;
            const cli = manifest.agent_cli orelse continue;

            if (keys.contains(manifest.key)) continue;
            keys.put(arena, manifest.key, {}) catch {};

            const standing: Standing = if (!Plugin.settingsFor(arena, io, environ_map, manifest.key).enabled)
                .off
            else if (!cli.runnable) cannot: {
                log.info(
                    "agent cli {s}: nothing on this system can run {s}",
                    .{ manifest.key, cli.adapter },
                );
                break :cannot .cannot_run;
            } else .ok;

            found.append(arena, .{ .standing = standing, .adapter = .{
                .key = manifest.key,
                .label = cli.label,
                .bin = cli.bin,
                .adapter = cli.adapter,
                .identify_env = cli.identify_env,
            } }) catch continue;
        }
    }

    std.mem.sortUnstable(Found, found.items, {}, struct {
        fn lt(_: void, a: Found, b: Found) bool {
            return std.mem.lessThan(u8, a.adapter.key, b.adapter.key);
        }
    }.lt);
    return found.items;
}

/// Every plugin on the search path that manages an agent CLI and can run
/// here, sorted by key: `survey`'s `ok` ones. A plugin the user switched
/// off offers no CLI.
///
/// Everything returned belongs to `arena`.
pub fn discover(
    arena: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) []const Adapter {
    var out: std.ArrayListUnmanaged(Adapter) = .empty;
    for (survey(arena, io, environ_map)) |f| {
        if (f.standing == .ok) out.append(arena, f.adapter) catch continue;
    }
    return out.items;
}

pub fn find(adapters: []const Adapter, key: []const u8) ?Adapter {
    for (adapters) |a| {
        if (std.mem.eql(u8, a.key, key)) return a;
    }
    return null;
}

pub const Question = enum { inventory, launch, identify };

/// What an adapter said.
pub const Answer = union(enum) {
    /// Its stdout, checked to be one JSON object.
    ok: []const u8,

    /// Why there is no answer, in words for a person: the adapter's own
    /// stderr when it gave one, otherwise what happened to it.
    failed: []const u8,
};

/// Ask an adapter one question. Everything returned belongs to `arena`.
///
/// `environ_map` is handed to the child whole. From the app that is a map
/// whose `PATH` was widened to the login shell's (`login_path`), because
/// the adapter is a script and its interpreter is found on `PATH`; from
/// `+launch` it is the terminal's own environment, which already is.
pub fn ask(
    arena: Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    adapter: Adapter,
    question: Question,
    request: []const u8,
) Allocator.Error!Answer {
    const base = (try Plugin.launchArgv(arena, adapter.adapter)) orelse
        return .{ .failed = try std.fmt.allocPrint(
            arena,
            "nothing on this system can run {s}",
            .{adapter.adapter},
        ) };

    const argv = try std.mem.concat(arena, []const u8, &.{ base, &.{ @tagName(question), request } });

    internal_os.windows.spawnTrace("agent_cli run", .begin, 0);
    const ran = try run(arena, io, environ_map, argv, timeout_ms);
    internal_os.windows.spawnTrace("agent_cli run", .end, 0);
    const result = switch (ran) {
        .finished => |f| f,
        .could_not => |err| return .{ .failed = try std.fmt.allocPrint(
            arena,
            "{s} could not be run ({t})",
            .{ adapter.adapter, err },
        ) },
        .out_of_time => return .{ .failed = try std.fmt.allocPrint(
            arena,
            "{s} did not answer within {d}s, so it was stopped",
            .{ adapter.key, timeout_ms / std.time.ms_per_s },
        ) },
        .too_long => return .{ .failed = try std.fmt.allocPrint(
            arena,
            "{s} answered more than this build reads",
            .{adapter.key},
        ) },
    };

    const said = std.mem.trim(u8, result.stderr, " \t\r\n");
    switch (result.term) {
        .exited => |code| if (code != 0) return .{ .failed = if (said.len > 0)
            said
        else
            try std.fmt.allocPrint(arena, "{s} exited {d}", .{ adapter.key, code }) },
        else => return .{ .failed = try std.fmt.allocPrint(
            arena,
            "{s} did not finish",
            .{adapter.key},
        ) },
    }

    const out = std.mem.trim(u8, result.stdout, " \t\r\n");
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{}) catch
        return .{ .failed = try std.fmt.allocPrint(
            arena,
            "{s} answered something that is not JSON",
            .{adapter.key},
        ) };
    if (parsed != .object) return .{ .failed = try std.fmt.allocPrint(
        arena,
        "{s} answered something that is not a JSON object",
        .{adapter.key},
    ) };
    return .{ .ok = out };
}

/// Longest complaint read from an adapter's stderr.
const max_complaint = 64 * 1024;

/// What running an adapter came to, before what it said is looked at.
const Ran = union(enum) {
    finished: struct {
        stdout: []const u8,
        stderr: []const u8,
        term: std.process.Child.Term,
    },

    /// It could not be started, or what it wrote could not be read.
    could_not: anyerror,

    /// `ms` went by before both its pipes had closed. It has been stopped
    /// and the pipes cut.
    out_of_time,

    /// It wrote more than `max_answer` or `max_complaint`. Stopped and cut,
    /// like `out_of_time`.
    too_long,
};

/// Run `argv` and read its stdout and stderr to their ends, for no longer
/// than `ms` in all. Not `std.process.run`, for three reasons, all #1745:
///
/// **It takes `spawn_lock`.** `std.process.spawn` makes the child's ends of
/// its pipes inheritable and calls `CreateProcessW` with
/// `bInheritHandles = TRUE`. An inventory refreshed while a plugin was being
/// started (the plugin spawn holds the lock; this did not) handed the
/// plugin's `provision.ps1` a copy of the adapter's stdout, the adapter
/// exited in under a second, and its pipe stayed open for as long as the
/// provision lived. Measured on Windows: `agent_cli run begin` 64 µs before
/// `plugin spawn begin`, `run end` 241.8 s later, at the moment the
/// provision was ended by hand.
///
/// **What runs out of time is stopped and its pipes are cut before anything
/// waits on them.** `run` returns `Timeout` through its `defer`s, and in
/// 0.16 those wait in the wrong order for this: the reader's `deinit`
/// (`Threaded.batchCancel`) first sleeps alertably with no deadline until
/// some read completes, and only after that does `child.kill` run. A read
/// whose far end somebody else holds completes when that somebody exits.
/// So the timeout is what reported the hang, not what ended it -- read out
/// of the 0.16 source, not measured on its own. Here the child is killed
/// and both pipes are disconnected from our side (`reap.sever`) first, so
/// every read in flight completes at once whoever holds the far end.
///
/// **One deadline for the whole run.** `run` gives each wait for more
/// output the full timeout again, so an adapter that writes a byte now and
/// then is never out of time at all.
fn run(
    arena: Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
    argv: []const []const u8,
    ms: u64,
) Allocator.Error!Ran {
    internal_os.windows.lockSpawn(io);
    internal_os.windows.spawnTrace("agent_cli spawn", .begin, 0);
    const spawned = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    internal_os.windows.spawnTrace("agent_cli spawn", .end, 0);
    internal_os.windows.unlockSpawn(io);
    var child = spawned catch |err| return .{ .could_not = err };

    // Reaps, and closes what is still open. Last, after the reader is gone.
    defer child.kill(io);

    const deadline = (std.Io.Timeout{ .duration = .{
        .raw = .fromMilliseconds(@intCast(ms)),
        .clock = .awake,
    } }).toDeadline(io);

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(arena, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });

    const cut_short: ?Ran = while (reader.fill(4096, deadline)) |_| {
        if (reader.reader(0).buffered().len > max_answer or
            reader.reader(1).buffered().len > max_complaint) break .too_long;
    } else |err| switch (err) {
        error.EndOfStream => null,
        error.Timeout => .out_of_time,
        else => |e| .{ .could_not = e },
    };

    if (cut_short) |why| {
        // Not `child.kill`: on Windows that also closes the pipes, under
        // reads still in flight. Stop it, then end those reads from our
        // side, and only then let the reader wait for them to finish.
        if (child.id) |id| reap.kill(id) catch {};
        reap.sever(.{ .read = child.stdout.?.handle });
        reap.sever(.{ .read = child.stderr.?.handle });
        reader.deinit();
        return why;
    }
    defer reader.deinit();

    reader.checkAnyError() catch |err| return .{ .could_not = err };
    const term = child.wait(io) catch |err| return .{ .could_not = err };
    return .{ .finished = .{
        .stdout = try reader.toOwnedSlice(0),
        .stderr = try reader.toOwnedSlice(1),
        .term = term,
    } };
}

// ------------------------------------------------------------------ launch

/// The request `launch` is sent: the role, and its choices for this CLI.
pub fn writeLaunchRequest(
    w: *std.Io.Writer,
    p: persona.Persona,
    choice: persona.CliChoice,
    cwd: ?[]const u8,
    home: ?[]const u8,
    polter: ?[]const u8,
    session: ?[]const u8,
) std.Io.Writer.Error!void {
    try w.print("{{\"version\":{d},\"cwd\":", .{contract_version});
    try writeOptional(w, cwd);
    try w.writeAll(",\"home\":");
    try writeOptional(w, home);
    // The executable a CLI's hooks run as `<polter> +hook ...` -- the same
    // one provisioning registers for `+mcp` (adapters.md 3.2). Null when it
    // could not be worked out; an adapter then configures no hooks.
    try w.writeAll(",\"polter\":");
    try writeOptional(w, polter);
    // The session to go on with, as the CLI itself named it through its
    // hooks; null for a new one. **Always written**, so an adapter reads
    // "new session" as a null it was sent rather than as a key it may or
    // may not have been sent. An adapter that cannot go on with a session
    // (it did not say `"resume": true` in its inventory) is never sent
    // anything but null, and one that can and finds the session gone
    // starts a new one and says so in `notes`: a launch must start.
    try w.writeAll(",\"session\":");
    try writeOptional(w, session);
    try w.print(",\"role\":{{\"key\":{f},\"name\":{f},\"instructions\":", .{
        std.json.fmt(p.key, .{}),
        std.json.fmt(p.name, .{}),
    });
    try writeOptional(w, p.instructions);
    try w.writeAll("},\"cli\":");

    // The role's choices for this CLI, in the selection shape the file
    // uses (`persona.writeSelection`). `skills` and `mcp` are the role's
    // one set (`Persona.cli_skills`, task 1677) -- put where each CLI's
    // own used to be, so an adapter reads them where it always has.
    try w.writeAll("{\"skills\":");
    try persona.writeSelection(w, p.cli_skills);
    try w.writeAll(",\"mcp\":");
    try persona.writeSelection(w, p.cli_mcp);
    try w.writeAll(",\"model\":");
    try writeOptional(w, choice.model);
    try w.writeAll(",\"args\":");
    try writeList(w, choice.args);
    // The adapter's own launch options (its inventory's `options`), as the
    // role picked them. Always written, `{}` for none.
    try w.writeAll(",\"options\":");
    try persona.writeOptions(w, choice.options);
    try w.writeAll("}}");
}

fn writeOptional(w: *std.Io.Writer, v: ?[]const u8) std.Io.Writer.Error!void {
    if (v) |s| try w.print("{f}", .{std.json.fmt(s, .{})}) else try w.writeAll("null");
}

fn writeList(w: *std.Io.Writer, list: []const []const u8) std.Io.Writer.Error!void {
    try w.writeAll("[");
    for (list, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{f}", .{std.json.fmt(s, .{})});
    }
    try w.writeAll("]");
}

/// What `launch` answered, read.
pub const Launch = struct {
    argv: []const []const u8,
    env: []const [2][]const u8,
    summary: ?[]const u8,
    notes: []const []const u8,

    /// The adapter configured the CLI's hooks to call `polter +hook`, so
    /// `+launch` tells Polter to expect them (`Bus.Hooks.expected`). Only a
    /// JSON `true` says so: an adapter that did not say it did not do it.
    hooks: bool,

    /// When the CLI's first hook comes (task 1668). Read only with `hooks`.
    hooks_heard: HooksHeard,
};

/// When a CLI whose hooks were configured says its first word, as a
/// launch answer's `hooks_heard` gives it.
pub const HooksHeard = enum {
    /// As soon as it has started: Claude Code's `SessionStart`. The wait
    /// for it starts with the launch. Also what any other word, or none,
    /// is read as -- the wait that has always been.
    startup,
    /// With its first turn: Codex's `SessionStart` is held until a turn
    /// begins (`run_pending_session_start_hooks`), so a Codex nobody has
    /// typed at says nothing however long it sits there. The wait starts
    /// at the first line submitted (`Bus.noteLineSubmitted`).
    first_turn,
    /// With its first turn, **and Polter is to type the first prompt**
    /// (task 1746): Antigravity started in a folder it does not trust yet,
    /// without `-i`, so that its trust box is drawn and answered by the
    /// person. Once it is and the CLI's input box shows, Polter types the
    /// role's instructions (`App.payFirstPrompts`).
    first_prompt,

    fn of(v: ?std.json.Value) HooksHeard {
        const s = switch (v orelse return .startup) {
            .string => |s| s,
            else => return .startup,
        };
        return std.meta.stringToEnum(HooksHeard, s) orelse .startup;
    }
};

pub const LaunchError = error{
    /// No `argv`, an empty one, or something in it that is not a string.
    NoCommand,
    OutOfMemory,
};

/// Read a `launch` answer. Everything borrows `arena`.
///
/// Strict about the one thing that will be executed: `argv` is a non-empty
/// array of strings or the answer is refused. Anything optional that does
/// not read is dropped, because a note or a summary is not worth failing a
/// start over.
pub fn parseLaunch(arena: Allocator, answer: []const u8) LaunchError!Launch {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, answer, .{}) catch
        return error.NoCommand;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.NoCommand,
    };

    const arr = switch (obj.get("argv") orelse return error.NoCommand) {
        .array => |a| a,
        else => return error.NoCommand,
    };
    if (arr.items.len == 0) return error.NoCommand;
    const argv = try arena.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |v, i| argv[i] = switch (v) {
        .string => |s| s,
        else => return error.NoCommand,
    };
    if (argv[0].len == 0) return error.NoCommand;

    var env: std.ArrayList([2][]const u8) = .empty;
    if (obj.get("env")) |ev| if (ev == .object) {
        var it = ev.object.iterator();
        while (it.next()) |kv| if (kv.value_ptr.* == .string) {
            try env.append(arena, .{ kv.key_ptr.*, kv.value_ptr.string });
        };
    };

    var notes: std.ArrayList([]const u8) = .empty;
    if (obj.get("notes")) |nv| if (nv == .array) {
        for (nv.array.items) |n| if (n == .string) try notes.append(arena, n.string);
    };

    return .{
        .argv = argv,
        .env = try env.toOwnedSlice(arena),
        .summary = if (obj.get("summary")) |s| (if (s == .string) s.string else null) else null,
        .notes = try notes.toOwnedSlice(arena),
        .hooks = if (obj.get("hooks")) |h| h == .bool and h.bool else false,
        .hooks_heard = HooksHeard.of(obj.get("hooks_heard")),
    };
}

// ------------------------------------------------------------------- cache

/// What every agent CLI on this machine offers, kept so that asking is a
/// copy.
///
/// **Refreshed on its own thread.** Asking an adapter runs a process, and
/// the app thread is every terminal's thread; a window opening, or a
/// supervisor asking `role_clis`, must not stall them all while a script
/// reads a few hundred files.
///
/// The answer it keeps is one JSON document:
///
/// ```json
/// {"stale":false,"refreshing":false,"clis":[
///   {"key":"claude-code","label":"Claude Code","bin":"claude",
///    "error":null,"inventory":{…what the adapter said…}}]}
/// ```
///
/// `stale` is "nothing has ever been read", which is a different sentence
/// from "there are no CLIs" -- the first is a spinner, the second is a
/// message. `refreshing` is "a newer answer is on its way".
pub const Cache = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,

    /// The `clis` array as last read, owned by `alloc`. Null until the
    /// first refresh finishes.
    clis: ?[]u8 = null,
    /// The keys of the CLIs whose adapter said `"resume": true` in the
    /// inventory `clis` was made from, each owned by `alloc`. Null exactly
    /// when `clis` is.
    resume_keys: ?[][]u8 = null,
    /// The keys of the CLIs whose adapter said `"installed": false` -- its
    /// program is not on the PATH the read had, the login shell's (task
    /// 1744). Null exactly when `clis` is: nothing read is not "all there".
    /// An adapter that did not say, or failed, is not here: not known is
    /// not "missing".
    missing_keys: ?[][]u8 = null,
    refreshing: bool = false,
    thread: ?std.Thread = null,

    pub fn init(alloc: Allocator) Cache {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Cache, io: std.Io) void {
        if (self.thread) |t| t.join();
        self.thread = null;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.clis) |c| self.alloc.free(c);
        self.clis = null;
        if (self.resume_keys) |keys| freeKeys(self.alloc, keys);
        self.resume_keys = null;
        if (self.missing_keys) |keys| freeKeys(self.alloc, keys);
        self.missing_keys = null;
    }

    fn freeKeys(alloc: Allocator, keys: [][]u8) void {
        for (keys) |k| alloc.free(k);
        alloc.free(keys);
    }

    /// Which CLIs can go on with a session they are handed, as last read:
    /// null when nothing has been read yet -- which is not "none can" --
    /// and otherwise their keys, copied into `alloc`.
    ///
    /// Does not start a read. A caller that wants one calls `refresh`.
    pub fn resumable(self: *Cache, io: std.Io, alloc: Allocator) Allocator.Error!?[]const []const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const keys = self.resume_keys orelse return null;
        const out = try alloc.alloc([]const u8, keys.len);
        for (keys, out) |k, *o| o.* = try alloc.dupe(u8, k);
        return out;
    }

    /// Which CLIs' programs are not on this machine, as last read (task
    /// 1744): null when nothing has been read yet -- which is not "all are
    /// here" -- and otherwise their keys, copied into `alloc`.
    ///
    /// Does not start a read.
    pub fn notInstalled(self: *Cache, io: std.Io, alloc: Allocator) Allocator.Error!?[]const []const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const keys = self.missing_keys orelse return null;
        const out = try alloc.alloc([]const u8, keys.len);
        for (keys, out) |k, *o| o.* = try alloc.dupe(u8, k);
        return out;
    }

    /// What each CLI is called to a person, as last read: its key and its
    /// adapter's `label`, copied into `alloc`. Empty when nothing has been
    /// read yet. Read out of `clis`, which is what a read leaves.
    ///
    /// Does not start a read.
    pub fn names(self: *Cache, io: std.Io, alloc: Allocator) Allocator.Error![]const Named {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return namesIn(alloc, self.clis orelse return &.{});
    }

    pub const Named = struct { key: []const u8, label: []const u8 };

    /// The key and the label of every entry of a `clis` array. One that
    /// does not read -- which a read never leaves -- is no names.
    pub fn namesIn(alloc: Allocator, clis: []const u8) Allocator.Error![]const Named {
        const parsed = std.json.parseFromSlice([]const Named, alloc, clis, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return &.{},
        };
        defer parsed.deinit();
        const out = try alloc.alloc(Named, parsed.value.len);
        for (parsed.value, out) |n, *o| o.* = .{ .key = try alloc.dupe(u8, n.key), .label = try alloc.dupe(u8, n.label) };
        return out;
    }

    /// Whether a read has finished or is under way.
    pub fn askedFor(self: *Cache, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.clis != null or self.refreshing;
    }

    /// Start reading again, unless a read is already under way.
    ///
    /// Returns immediately. The thread from a finished read is joined here,
    /// which is the only place one can be: a thread cannot join itself.
    ///
    /// ⚠️ **Called from one thread only** -- the app thread, which is where
    /// both the C query and the request dispatch run. Two callers racing
    /// here could each see `refreshing` false and the first thread's handle
    /// not yet stored, and one thread would never be joined. The worker
    /// thread only ever touches `clis` and `refreshing`.
    pub fn refresh(self: *Cache, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        if (self.refreshing) {
            self.mutex.unlock(io);
            return;
        }
        self.refreshing = true;
        const previous = self.thread;
        self.thread = null;
        self.mutex.unlock(io);

        if (previous) |t| t.join();

        const t = std.Thread.spawn(.{}, work, .{ self, io }) catch |err| {
            log.warn("agent cli: could not start the inventory thread err={}", .{err});
            self.mutex.lockUncancelable(io);
            self.refreshing = false;
            self.mutex.unlock(io);
            return;
        };
        self.mutex.lockUncancelable(io);
        self.thread = t;
        self.mutex.unlock(io);
    }

    /// The whole document, in `alloc`. Starts a first refresh when nothing
    /// has been read yet, so the first caller does not have to know to.
    pub fn snapshot(self: *Cache, io: std.Io, alloc: Allocator) Allocator.Error![]u8 {
        var first = false;
        const out = blk: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            first = self.clis == null and !self.refreshing;
            break :blk try std.fmt.allocPrint(
                alloc,
                "{{\"stale\":{},\"refreshing\":{},\"clis\":{s}}}",
                .{ self.clis == null, self.refreshing or first, self.clis orelse "[]" },
            );
        };
        if (first) self.refresh(io);
        return out;
    }

    fn work(self: *Cache, io: std.Io) void {
        const fresh = read(self.alloc, io) catch |err| blk: {
            log.warn("agent cli: inventory failed err={}", .{err});
            break :blk null;
        };

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (fresh) |f| {
            if (self.clis) |old| self.alloc.free(old);
            self.clis = f.clis;
            if (self.resume_keys) |old| freeKeys(self.alloc, old);
            self.resume_keys = f.resume_keys;
            if (self.missing_keys) |old| freeKeys(self.alloc, old);
            self.missing_keys = f.missing_keys;
        }
        self.refreshing = false;
    }

    const Read = struct { clis: []u8, resume_keys: [][]u8, missing_keys: [][]u8 };

    /// Ask every adapter for its inventory. The `clis` array and the keys
    /// of those that can go on with a session, owned by `alloc`.
    fn read(alloc: Allocator, io: std.Io) !Read {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const aa = arena.allocator();

        var environ_map = try global.environMap();
        defer environ_map.deinit();
        _ = login_path.widen(aa, io, &environ_map);

        // `USERPROFILE` on Windows, where there is no `HOME` -- measured:
        // the Windows test machine's adapter was asked with `"home":null`.
        const home = environ_map.get("HOME") orelse environ_map.get("USERPROFILE");
        var request: std.Io.Writer.Allocating = .init(aa);
        try request.writer.print("{{\"version\":{d},\"cwd\":null,\"home\":", .{contract_version});
        try writeOptional(&request.writer, home);
        try request.writer.writeAll("}");

        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        const w = &out.writer;

        var can: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (can.items) |k| alloc.free(k);
            can.deinit(alloc);
        }
        var gone: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (gone.items) |k| alloc.free(k);
            gone.deinit(alloc);
        }

        try w.writeAll("[");
        for (discover(aa, io, &environ_map), 0..) |a, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"key\":{f},\"label\":{f},\"bin\":{f},", .{
                std.json.fmt(a.key, .{}),
                std.json.fmt(a.label, .{}),
                std.json.fmt(a.bin, .{}),
            });
            switch (try ask(aa, io, &environ_map, a, .inventory, request.written())) {
                .ok => |json| {
                    try w.print("\"error\":null,\"inventory\":{s}}}", .{json});
                    if (saysResume(aa, json)) {
                        const key = try alloc.dupe(u8, a.key);
                        errdefer alloc.free(key);
                        try can.append(alloc, key);
                    }
                    if (saysNotInstalled(aa, json)) {
                        const key = try alloc.dupe(u8, a.key);
                        errdefer alloc.free(key);
                        try gone.append(alloc, key);
                    }
                },
                .failed => |why| {
                    log.warn("agent cli {s}: inventory failed: {s}", .{ a.key, why });
                    try w.print("\"error\":{f},\"inventory\":null}}", .{std.json.fmt(why, .{})});
                },
            }
        }
        try w.writeAll("]");
        const clis = try out.toOwnedSlice();
        errdefer alloc.free(clis);
        const resume_keys = try can.toOwnedSlice(alloc);
        errdefer freeKeys(alloc, resume_keys);
        return .{ .clis = clis, .resume_keys = resume_keys, .missing_keys = try gone.toOwnedSlice(alloc) };
    }
};

// ---------------------------------------------------------------- identify

/// What a sidecar (`polter +mcp`) told Polter about the program that
/// started it, at its handshake (task 1635). Everything is optional and
/// nothing here is trusted beyond "this is what that process said".
pub const Sighting = struct {
    /// The sidecar's parent: the agent CLI, when the CLI started it
    /// directly. Null where it is not read (Windows, today).
    pid: ?u64,
    /// The sidecar's own pid, when it said (task 1667). When it started is
    /// when the CLI's session started Polter's server, which is what tells
    /// two sessions in one directory apart (`plugins/codex/adapter.py`,
    /// `by_directory`). Null where it is not said.
    sidecar: ?u64 = null,
    /// Name and value, for the names some adapter declared in
    /// `identify_env` and nothing else. See `Plugin.AgentCli.identify_env`.
    env: []const [2][]const u8,

    pub const none: Sighting = .{ .pid = null, .env = &.{} };

    /// Longest value carried. A session id is a UUID; anything longer is
    /// not what any adapter asked for.
    pub const max_value = 256;

    /// A value worth carrying: printable ASCII, no quotes or backslashes to
    /// get wrong, not too long.
    pub fn validValue(v: []const u8) bool {
        if (v.len == 0 or v.len > max_value) return false;
        for (v) |c| if (c < 0x20 or c >= 0x7f or c == '"' or c == '\\') return false;
        return true;
    }

    pub fn get(self: Sighting, name: []const u8) ?[]const u8 {
        for (self.env) |kv| if (std.mem.eql(u8, kv[0], name)) return kv[1];
        return null;
    }
};

/// The request `identify` is sent: where the terminal is, the home
/// directory, and the sighting -- **only the variables this adapter
/// declared**, never another adapter's.
pub fn writeIdentifyRequest(
    w: *std.Io.Writer,
    adapter: Adapter,
    sighting: Sighting,
    cwd: ?[]const u8,
    home: ?[]const u8,
) std.Io.Writer.Error!void {
    try w.print("{{\"version\":{d},\"cwd\":", .{contract_version});
    try writeOptional(w, cwd);
    try w.writeAll(",\"home\":");
    try writeOptional(w, home);
    try w.writeAll(",\"pid\":");
    if (sighting.pid) |p| try w.print("{d}", .{p}) else try w.writeAll("null");
    try w.writeAll(",\"sidecar_pid\":");
    if (sighting.sidecar) |p| try w.print("{d}", .{p}) else try w.writeAll("null");
    try w.writeAll(",\"env\":{");
    var first = true;
    for (adapter.identify_env) |name| {
        const v = sighting.get(name) orelse continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{f}:{f}", .{ std.json.fmt(name, .{}), std.json.fmt(v, .{}) });
    }
    try w.writeAll("}}");
}

/// Whether `sighting` carries anything `adapter` could recognise its CLI
/// by. An adapter with nothing to go on is not asked: running it would
/// cost a process for an answer that can only be no.
pub fn couldRecognise(adapter: Adapter, sighting: Sighting) bool {
    for (adapter.identify_env) |name| if (sighting.get(name) != null) return true;
    return false;
}

/// What `identify` answered, read.
pub const Identified = struct {
    /// It is this adapter's CLI. Only a JSON `true` says so.
    me: bool,
    /// The session it is in, when the adapter found one it could hand to
    /// `launch`; null otherwise. Only a valid `isSessionToken` is kept.
    session: ?[]const u8,
    /// When that session's record was last written, real-clock ms; null
    /// when not known. How sure "this is the session" is depends on it
    /// (`Identities`), and the adapter only reports it.
    session_written_ms: ?i64,
    /// How to make the CLI quit, and how its screen looks when typing that
    /// is safe; null when the adapter gave none, and then nothing types it.
    quit: ?Quit,

    pub const Quit = struct {
        /// Typed, followed by a return.
        text: []const u8,
        /// Typing it is safe only when one of the screen's last rows,
        /// trimmed of spaces, **is** one of these -- an empty input line,
        /// typically, which is also "nothing half-typed"...
        ready_lines: []const []const u8,
        /// ...and no row contains any of these: a turn going on, a question
        /// waiting for an answer, a menu.
        ready_none: []const []const u8,
    };

    pub const no: Identified = .{ .me = false, .session = null, .session_written_ms = null, .quit = null };
};

/// Read an `identify` answer. Lenient everywhere except `me`: an answer
/// that does not read is "not mine", which is the safe side -- a terminal
/// nobody recognises is said to be one, and nothing is typed into it.
pub fn parseIdentify(arena: Allocator, answer: []const u8) Allocator.Error!Identified {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, answer, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .no,
    };
    const obj = switch (root) {
        .object => |o| o,
        else => return .no,
    };
    const me = if (obj.get("me")) |m| m == .bool and m.bool else false;
    if (!me) return .no;

    const session: ?[]const u8 = if (obj.get("session")) |v| switch (v) {
        .string => |sv| if (isSessionToken(sv)) sv else null,
        else => null,
    } else null;
    const written: ?i64 = if (obj.get("session_written_ms")) |v| switch (v) {
        .integer => |i| i,
        else => null,
    } else null;

    const quit: ?Identified.Quit = quit: {
        const q = switch (obj.get("quit") orelse break :quit null) {
            .object => |o| o,
            else => break :quit null,
        };
        const text = switch (q.get("text") orelse break :quit null) {
            .string => |t| t,
            else => break :quit null,
        };
        // Something typed into a terminal: one line, printable, short.
        if (text.len == 0 or text.len > 64) break :quit null;
        for (text) |c| if (c < 0x20 or c == 0x7f) break :quit null;
        const ready = switch (q.get("ready") orelse break :quit null) {
            .object => |o| o,
            else => break :quit null,
        };
        const lines = try stringsOf(arena, ready.get("line"));
        // **No screen rule, no quitting**: without one, "safe to type" is
        // a guess, and the guess that goes wrong presses return in a
        // permission box.
        if (lines.len == 0) break :quit null;
        break :quit .{
            .text = text,
            .ready_lines = lines,
            .ready_none = try stringsOf(arena, ready.get("none_of")),
        };
    };

    return .{ .me = true, .session = session, .session_written_ms = written, .quit = quit };
}

fn stringsOf(arena: Allocator, v: ?std.json.Value) Allocator.Error![]const []const u8 {
    const arr = switch (v orelse return &.{}) {
        .array => |a| a,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (arr.items) |item| if (item == .string and item.string.len > 0) try out.append(arena, item.string);
    return out.toOwnedSlice(arena);
}

/// Who the agent in a terminal is, as far as the adapters can tell.
pub const Recognised = union(enum) {
    /// An adapter said it is its CLI.
    known: struct { key: []const u8, label: []const u8, identified: Identified },
    /// No adapter said so: none could recognise it, or every one that
    /// could said no or failed. **Not "fine"**: Polter does not know what
    /// it is, and so does not know its state.
    unknown,
};

/// Ask every adapter that could recognise the CLI, in key order, until one
/// says it is its own. Everything returned belongs to `arena`. Runs
/// processes: never on the app thread (`Identities`).
pub fn recognise(
    arena: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    adapters: []const Adapter,
    sighting: Sighting,
    cwd: ?[]const u8,
) Allocator.Error!Recognised {
    const home = environ_map.get("HOME") orelse environ_map.get("USERPROFILE");
    for (adapters) |a| {
        if (!couldRecognise(a, sighting)) continue;
        var request: std.Io.Writer.Allocating = .init(arena);
        writeIdentifyRequest(&request.writer, a, sighting, cwd, home) catch return error.OutOfMemory;
        switch (try ask(arena, io, environ_map, a, .identify, request.written())) {
            .ok => |json| {
                const said = try parseIdentify(arena, json);
                if (said.me) return .{ .known = .{ .key = a.key, .label = a.label, .identified = said } };
            },
            // The values it was shown are not in this line: an adapter's
            // stderr is its own words, and a session id is not a secret,
            // but nothing here needs it.
            .failed => |why| log.info("agent cli {s}: identify gave no answer: {s}", .{ a.key, why }),
        }
    }
    return .unknown;
}

/// What only the control room adds to a launch line: the group a
/// supervisor is started for, and the session it goes on with.
pub const LaunchFor = struct {
    group: ?[]const u8,
    session: ?[]const u8,

    pub const none: LaunchFor = .{ .group = null, .session = null };
};

/// ` +launch <role> <cli>[ --group=<name>][ --resume=<session>]` -- what
/// follows the executable on the line typed to start a role
/// (`App.launchLine`); `cli/launch.zig` reads it back.
///
/// **Nothing here needs quoting, and that is checked rather than assumed
/// for the one part that comes from outside**: the keys and a group's name
/// are `[a-z0-9-]` by construction, and a session's id is whatever a CLI
/// called it, so one that is not `isSessionToken` is left off the line.
/// The role then starts in a new session, which is what a launch does
/// with no id at all.
pub fn writeLaunchWords(
    w: *std.Io.Writer,
    role: []const u8,
    cli: []const u8,
    extra: LaunchFor,
) std.Io.Writer.Error!void {
    try w.print(" +launch {s} {s}", .{ role, cli });
    if (extra.group) |g| try w.print(" --group={s}", .{g});
    if (extra.session) |id| {
        if (isSessionToken(id)) try w.print(" --resume={s}", .{id});
    }
}

/// Whether `s` can be a session's id on a launch line and in a launch
/// request: 1 to 96 of `[A-Za-z0-9._-]`, not starting with `-`.
///
/// **Narrower than what a CLI may call a session, on purpose.** The id is
/// typed into a shell on the launch line and ends up as an argument to the
/// CLI, so it is held to characters neither reads as anything else. A CLI
/// whose ids do not fit is one whose sessions are not gone on with -- the
/// supervisor starts in a new one -- rather than one whose id is quoted by
/// a rule somebody has to get right for every shell. 96 is what the bus
/// keeps of one (`Bus.Agent.session_id`).
pub fn isSessionToken(s: []const u8) bool {
    if (s.len == 0 or s.len > 96 or s[0] == '-') return false;
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// Whether an inventory answer says its adapter can start the CLI in a
/// session it is handed. **Only a JSON `true` says so**, the way only one
/// says `hooks` in a launch answer: an adapter that did not say it cannot,
/// and is never sent a session.
pub fn saysResume(arena: Allocator, inventory_json: []const u8) bool {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, inventory_json, .{}) catch
        return false;
    if (root != .object) return false;
    const v = root.object.get("resume") orelse return false;
    return v == .bool and v.bool;
}

/// Whether an inventory answer says its CLI's program is not here: the
/// JSON `false` and nothing else (task 1744). A key not there, or not a
/// bool, is an adapter that did not say -- not known, and offered as before.
pub fn saysNotInstalled(arena: Allocator, inventory_json: []const u8) bool {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, inventory_json, .{}) catch
        return false;
    if (root != .object) return false;
    const v = root.object.get("installed") orelse return false;
    return v == .bool and !v.bool;
}

// ------------------------------------------------------------------- tests

test "1744: an inventory says its program is missing with false and nothing else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const missing = saysNotInstalled(aa, "{\"version\":1,\"installed\":false}");
    try testing.expect(missing);
    const there = saysNotInstalled(aa, "{\"version\":1,\"installed\":true}");
    try testing.expect(!there);
    // Not said, said some other way, or no answer at all: not known.
    const unsaid = saysNotInstalled(aa, "{\"version\":1}");
    try testing.expect(!unsaid);
    const word = saysNotInstalled(aa, "{\"installed\":\"false\"}");
    try testing.expect(!word);
    const garbled = saysNotInstalled(aa, "not json");
    try testing.expect(!garbled);
}

const testing = std.testing;

test "agent_cli: the launch request carries the role and one CLI's choices" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const p: persona.Persona = .{
        .key = "archer",
        .name = "射手",
        .instructions = "Only read.\n\"Never\" write.",
        .cli_skills = .{ .default = false, .except = &.{"skill:pdf"} },
        .cli_mcp = .{ .except = &.{"mcp:argus"} },
    };
    const choice: persona.CliChoice = .{
        .cli = "claude-code",
        .model = "sonnet",
        .args = &.{"--verbose"},
    };

    var out: std.Io.Writer.Allocating = .init(aa);
    try writeLaunchRequest(&out.writer, p, choice, "/tmp/x", null, "/Applications/Polter.app/Contents/MacOS/polter", null);

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, out.written(), .{});
    const o = v.object;
    try testing.expectEqual(@as(i64, contract_version), o.get("version").?.integer);
    try testing.expectEqualStrings("/tmp/x", o.get("cwd").?.string);
    try testing.expect(o.get("home").? == .null);
    // A new session is a null that was sent, not a key left out.
    try testing.expect(o.get("session").? == .null);
    try testing.expectEqualStrings("/Applications/Polter.app/Contents/MacOS/polter", o.get("polter").?.string);
    const role = o.get("role").?.object;
    try testing.expectEqualStrings("射手", role.get("name").?.string);
    try testing.expectEqualStrings(p.instructions.?, role.get("instructions").?.string);
    const cli = o.get("cli").?.object;
    try testing.expect(!cli.get("skills").?.object.get("default").?.bool);
    try testing.expectEqualStrings("skill:pdf", cli.get("skills").?.object.get("except").?.array.items[0].string);
    try testing.expectEqualStrings("mcp:argus", cli.get("mcp").?.object.get("except").?.array.items[0].string);
    try testing.expectEqualStrings("sonnet", cli.get("model").?.string);
    try testing.expectEqualStrings("--verbose", cli.get("args").?.array.items[0].string);
}

test "1746: a launch answer can say Polter is to type the first prompt, and the event says so on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const agy = try parseLaunch(aa, "{\"argv\":[\"agy\"],\"hooks\":true,\"hooks_heard\":\"first_prompt\"}");
    try testing.expectEqual(HooksHeard.first_prompt, agy.hooks_heard);
    // What `+launch` sends for it: owed, and heard with the first turn.
    const AgentEvent = @import("agent_event.zig");
    try testing.expect(AgentEvent.firstPromptOwed(AgentEvent.first_prompt));
    try testing.expect(AgentEvent.heardAtFirstTurn(AgentEvent.first_prompt));
    const first_turn = AgentEvent.hooksExpectedDetail(true);
    try testing.expect(!AgentEvent.firstPromptOwed(first_turn));
    try testing.expect(!AgentEvent.firstPromptOwed(null));
}

test "1668: a launch answer says when the first hook comes, and the wait from the launch is the default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const plain = try parseLaunch(aa, "{\"argv\":[\"claude\"],\"hooks\":true}");
    try testing.expectEqual(HooksHeard.startup, plain.hooks_heard);
    const codex = try parseLaunch(aa, "{\"argv\":[\"codex\"],\"hooks\":true,\"hooks_heard\":\"first_turn\"}");
    try testing.expectEqual(HooksHeard.first_turn, codex.hooks_heard);
    const newer = try parseLaunch(aa, "{\"argv\":[\"codex\"],\"hooks\":true,\"hooks_heard\":\"later\"}");
    try testing.expectEqual(HooksHeard.startup, newer.hooks_heard);
    const stringly = try parseLaunch(aa, "{\"argv\":[\"codex\"],\"hooks\":true,\"hooks_heard\":1}");
    try testing.expectEqual(HooksHeard.startup, stringly.hooks_heard);
}

test "agent_cli: a launch answer is strict about the command and lenient about the rest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const l = try parseLaunch(aa,
        \\{"version":1,"argv":["claude","--settings","{}"],"env":{"A":"1","B":2},
        \\ "summary":"2 off","notes":["n",3]}
    );
    try testing.expectEqual(@as(usize, 3), l.argv.len);
    try testing.expectEqualStrings("claude", l.argv[0]);
    try testing.expectEqual(@as(usize, 1), l.env.len);
    try testing.expectEqualStrings("2 off", l.summary.?);
    try testing.expectEqual(@as(usize, 1), l.notes.len);
    // Not said, not done.
    try testing.expect(!l.hooks);

    const with = try parseLaunch(aa, "{\"argv\":[\"claude\"],\"hooks\":true}");
    try testing.expect(with.hooks);
    // Only a real `true`: a string that says so is not the adapter saying so.
    const stringly = try parseLaunch(aa, "{\"argv\":[\"claude\"],\"hooks\":\"true\"}");
    try testing.expect(!stringly.hooks);

    // Anything that would put something other than a command in argv[0]
    // is not a command.
    const bad = [_][]const u8{
        "not json",
        "[]",
        "{}",
        "{\"argv\":[]}",
        "{\"argv\":[\"\"]}",
        "{\"argv\":[\"claude\",7]}",
        "{\"argv\":\"claude\"}",
    };
    for (bad) |b| try testing.expectError(error.NoCommand, parseLaunch(aa, b));
}

test "agent_cli: the shipped Claude Code adapter lists what is there and switches off what the role says" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const root = try std.fmt.allocPrint(aa, "/tmp/polter-adapter-{x}", .{&raw});
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteTree(io, root) catch {};

    // A home with one of each kind of thing a role can switch.
    const home = try std.fmt.allocPrint(aa, "{s}/home", .{root});
    const plugin_dir = try std.fmt.allocPrint(aa, "{s}/.claude/plugins/cache/m/ops/1.0", .{home});
    const files = [_][2][]const u8{
        .{ ".claude/skills/pdf/SKILL.md", "---\nname: pdf\ndescription: Read PDFs.\n---\nbody" },
        .{ ".claude/skills/folded/SKILL.md", "---\nname: folded\ndescription: >\n  One line\n  and another.\n---\n" },
        // What claude.ai syncs down sits a folder deeper: under `synced`, and
        // then one folder per signed-in account. A walk that stops at
        // `skills/<skill>` steps over it -- and what the inventory never sees,
        // a role can never switch off.
        .{ ".claude/skills/synced/acct/theme/SKILL.md", "---\nname: theme\ndescription: Synced.\n---\n" },
        // A synced plugin, which `installed_plugins.json` below does not
        // mention and `enabledPlugins` does not switch on. Those two are for
        // plugins installed from a marketplace; a synced one is in the session
        // regardless, so it is listed regardless.
        .{
            ".claude/plugins/synced/acct/design/.claude-plugin/plugin.json",
            \\{"name":"design","description":"Design work."}
        },
        .{ ".claude/plugins/synced/acct/design/skills/ux-copy/SKILL.md", "---\nname: ux-copy\ndescription: Words.\n---\n" },
        .{
            ".claude.json",
            \\{"mcpServers":{"polter":{"command":"/x/polter","args":["+mcp"]},
            \\ "pencil":{"command":"/opt/pencil/bin/mcp-server","env":{"SECRET":"hunter2"}}}}
        },
        .{
            ".claude/settings.json",
            \\{"enabledPlugins":{"ops@m":true,"off@m":false}}
        },
        .{ ".claude/plugins/installed_plugins.json", "" },
    };
    for (files) |f| {
        const path = try std.fmt.allocPrint(aa, "{s}/{s}", .{ home, f[0] });
        try cwd.createDirPath(io, std.fs.path.dirname(path).?);
        var file = try cwd.createFile(io, path, .{});
        defer file.close(io);
        const body = if (std.mem.endsWith(u8, f[0], "installed_plugins.json"))
            try std.fmt.allocPrint(aa,
                \\{{"version":2,"plugins":{{"ops@m":[{{"scope":"user","installPath":"{s}"}}],
                \\ "off@m":[{{"scope":"user","installPath":"/nowhere"}}]}}}}
            , .{plugin_dir})
        else
            f[1];
        try file.writeStreamingAll(io, body);
    }
    const plugin_files = [_][2][]const u8{
        .{
            ".claude-plugin/plugin.json",
            \\{"name":"ops","description":"Operations toolkit.",
            \\ "mcpServers":{"ops":{"type":"http","url":"https://user:pw@ops.example.com/mcp?k=1"}}}
        },
        .{ "skills/terminal/SKILL.md", "---\nname: terminal\ndescription: \"Run commands.\"\n---\n" },
    };
    for (plugin_files) |f| {
        const path = try std.fmt.allocPrint(aa, "{s}/{s}", .{ plugin_dir, f[0] });
        try cwd.createDirPath(io, std.fs.path.dirname(path).?);
        var file = try cwd.createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, f[1]);
    }

    const exec = try std.fmt.allocPrint(aa, "{s}/adapter.py", .{root});
    {
        var f = try cwd.createFile(io, exec, .{ .permissions = .fromMode(0o755) });
        defer f.close(io);
        try f.writeStreamingAll(io, @embedFile("plugin_claude_code_adapter_py"));
    }
    const adapter: Adapter = .{ .key = "claude-code", .label = "Claude Code", .bin = "claude", .adapter = exec, .identify_env = &.{} };

    var env = try global.environMap();
    defer env.deinit();
    try standInClis(aa, io, &env, root);

    const inv_req = try std.fmt.allocPrint(aa, "{{\"version\":1,\"cwd\":null,\"home\":\"{s}\"}}", .{home});
    const inv = switch (try ask(aa, io, &env, adapter, .inventory, inv_req)) {
        .ok => |j| j,
        .failed => |why| {
            // No python3 is the one reason this may not run; anything else
            // is the adapter being wrong.
            if (std.mem.indexOf(u8, why, "could not be run") != null) return error.SkipZigTest;
            std.debug.print("adapter failed: {s}\n", .{why});
            return error.TestUnexpectedResult;
        },
    };

    // The secret in an env block and the password in a URL never leave.
    try testing.expect(std.mem.indexOf(u8, inv, "hunter2") == null);
    try testing.expect(std.mem.indexOf(u8, inv, "user:pw") == null);

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, inv, .{});
    var ids: std.StringHashMapUnmanaged(std.json.ObjectMap) = .empty;
    for (v.object.get("items").?.array.items) |item| {
        try ids.put(aa, item.object.get("id").?.string, item.object);
    }

    // The launch options are read from the stand-in's `--help`, not from
    // whatever `claude` this machine has (`standInClis`, task 1677).
    const modes = v.object.get("options").?.array.items;
    try testing.expectEqual(@as(usize, 1), modes.len);
    const mode = modes[0].object;
    try testing.expectEqualStrings("permission_mode", mode.get("key").?.string);
    try testing.expectEqualStrings("stand-in", mode.get("values").?.array.items[0].object.get("value").?.string);
    try testing.expectEqual(@as(usize, 1), mode.get("values").?.array.items.len);
    const want = [_][]const u8{
        "skill:pdf",          "skill:folded",         "skill:ops:terminal",
        "skill:theme",        "mcp:polter",           "mcp:pencil",
        "mcp:plugin_ops_ops", "skill:design:ux-copy",
        // Claude Code's own skills: one row, and not on disk at all.
        "skill:.bundled",
    };
    for (want) |id| if (!ids.contains(id)) {
        std.debug.print("missing {s} in {s}\n", .{ id, inv });
        return error.TestUnexpectedResult;
    };
    // A plugin that is switched off is already off; nothing to decide.
    try testing.expectEqual(@as(usize, want.len), ids.count());
    try testing.expectEqualStrings("One line and another.", ids.get("skill:folded").?.get("description").?.string);
    try testing.expectEqualStrings("Operations toolkit.", ids.get("mcp:plugin_ops_ops").?.get("description").?.string);
    try testing.expect(ids.get("mcp:polter").?.get("locked").?.bool);

    // Now a role that turns off one of each, and tries to turn off Polter.
    const p: persona.Persona = .{
        .key = "r",
        .name = "r",
        .instructions = "be brief",
        .cli_skills = .{ .except = &.{ "skill:pdf", "skill:ops:terminal", "skill:theme", "skill:design:ux-copy", "skill:.bundled" } },
        .cli_mcp = .{ .except = &.{ "mcp:pencil", "mcp:plugin_ops_ops", "mcp:polter" } },
    };
    const choice: persona.CliChoice = .{
        .cli = "claude-code",
        .args = &.{ "--settings", "{\"theme\":\"dark\"}" },
    };
    var req: std.Io.Writer.Allocating = .init(aa);
    try writeLaunchRequest(&req.writer, p, choice, null, home, null, null);
    const answer = switch (try ask(aa, io, &env, adapter, .launch, req.written())) {
        .ok => |j| j,
        .failed => |why| {
            std.debug.print("adapter failed: {s}\n", .{why});
            return error.TestUnexpectedResult;
        },
    };
    const l = try parseLaunch(aa, answer);
    const argv = try std.mem.join(aa, "\x00", l.argv);

    try testing.expectEqualStrings("claude", l.argv[0]);
    // Measured: a personal skill goes through skillOverrides, an MCP server
    // through mcp__<name>. A synced skill takes the same switch as the user's
    // own, and Claude Code's own skills their one boolean.
    try testing.expect(std.mem.indexOf(u8, argv, "\"pdf\": \"off\"") != null);
    try testing.expect(std.mem.indexOf(u8, argv, "\"theme\": \"off\"") != null);
    try testing.expect(std.mem.indexOf(u8, argv, "\"disableBundledSkills\": true") != null);
    try testing.expect(std.mem.indexOf(u8, argv, "\x00mcp__pencil") != null);
    // `ops` loses its only skill and its only server, so it goes off whole --
    // which is the off that also takes it out of the listing Claude is given.
    // Neither of its two items is named on its own.
    try testing.expect(std.mem.indexOf(u8, argv, "\"ops@m\": false") != null);
    try testing.expect(std.mem.indexOf(u8, argv, "Skill(ops:terminal)") == null);
    try testing.expect(std.mem.indexOf(u8, argv, "mcp__plugin_ops_ops") == null);
    // A synced plugin has no such switch -- `enabledPlugins` does not reach
    // it -- so it stays item by item.
    try testing.expect(std.mem.indexOf(u8, argv, "Skill(design:ux-copy)") != null);
    // Polter's own server is not the role's to take away.
    try testing.expect(std.mem.indexOf(u8, argv, "mcp__polter") == null);
    // Measured: two --settings do not merge, the second wins. So there is
    // exactly one, and the user's key is in it next to the role's.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, argv, "--settings"));
    try testing.expect(std.mem.indexOf(u8, argv, "\"theme\": \"dark\"") != null);
    try testing.expect(std.mem.indexOf(u8, argv, "--append-system-prompt\x00be brief") != null);
}

test "agent_cli: a role never switches off what belongs to the directory it is launched in" {
    // A role is written in the settings window, which has no directory, so
    // a project's skills and servers can never be in its `except`. A role
    // whose default is off would otherwise take all of them away in every
    // project it is started in (the supervisor lost the repository's
    // `/提交` that way). Everything of the person's own still goes.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const root = try std.fmt.allocPrint(aa, "/tmp/polter-adapter-proj-{x}", .{&raw});
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteTree(io, root) catch {};

    const home = try std.fmt.allocPrint(aa, "{s}/home", .{root});
    const project = try std.fmt.allocPrint(aa, "{s}/project", .{root});
    const files = [_][2][]const u8{
        // The person's own: a skill only they have, one the project has
        // too, and a server.
        .{ "home/.claude/skills/writer/SKILL.md", "---\nname: writer\ndescription: Mine.\n---\n" },
        .{ "home/.claude/skills/pdf/SKILL.md", "---\nname: pdf\ndescription: Mine too.\n---\n" },
        .{ "home/.claude.json", "" },
        // The project's: a skill of its own, the same name as the person's
        // `pdf` (in this directory it is the project's that answers), and
        // a shared server.
        .{ "project/.claude/skills/提交/SKILL.md", "---\nname: 提交\ndescription: Commit.\n---\n" },
        .{ "project/.claude/skills/pdf/SKILL.md", "---\nname: pdf\ndescription: Ours.\n---\n" },
        .{
            "project/.mcp.json",
            \\{"mcpServers":{"shared":{"type":"http","url":"https://shared.example.com/x"}}}
        },
    };
    for (files) |f| {
        const path = try std.fmt.allocPrint(aa, "{s}/{s}", .{ root, f[0] });
        try cwd.createDirPath(io, std.fs.path.dirname(path).?);
        var file = try cwd.createFile(io, path, .{});
        defer file.close(io);
        // `projects[<cwd>]` is keyed by the directory, so it is written here.
        const body = if (std.mem.endsWith(u8, f[0], ".claude.json"))
            try std.fmt.allocPrint(aa,
                \\{{"mcpServers":{{"pencil":{{"command":"/opt/pencil"}}}},
                \\ "projects":{{"{s}":{{"mcpServers":{{"localsrv":{{"command":"/bin/local"}}}}}}}}}}
            , .{project})
        else
            f[1];
        try file.writeStreamingAll(io, body);
    }

    const exec = try std.fmt.allocPrint(aa, "{s}/adapter.py", .{root});
    {
        var f = try cwd.createFile(io, exec, .{ .permissions = .fromMode(0o755) });
        defer f.close(io);
        try f.writeStreamingAll(io, @embedFile("plugin_claude_code_adapter_py"));
    }
    const adapter: Adapter = .{ .key = "claude-code", .label = "Claude Code", .bin = "claude", .adapter = exec, .identify_env = &.{} };

    var env = try global.environMap();
    defer env.deinit();
    try standInClis(aa, io, &env, root);

    // A supervisor's shape: everything off by default, nothing excepted.
    const p: persona.Persona = .{
        .key = "s",
        .name = "s",
        .cli_skills = .{ .default = false },
        .cli_mcp = .{ .default = false },
    };
    const choice: persona.CliChoice = .{
        .cli = "claude-code",
    };
    var req: std.Io.Writer.Allocating = .init(aa);
    try writeLaunchRequest(&req.writer, p, choice, project, home, null, null);
    const answer = switch (try ask(aa, io, &env, adapter, .launch, req.written())) {
        .ok => |j| j,
        .failed => |why| {
            if (std.mem.indexOf(u8, why, "could not be run") != null) return error.SkipZigTest;
            std.debug.print("adapter failed: {s}\n", .{why});
            return error.TestUnexpectedResult;
        },
    };
    const l = try parseLaunch(aa, answer);
    const argv = try std.mem.join(aa, "\x00", l.argv);

    // The control: the person's own still go.
    const writer_off = std.mem.indexOf(u8, argv, "\"writer\": \"off\"") != null;
    try testing.expect(writer_off);
    const pencil_off = std.mem.indexOf(u8, argv, "\x00mcp__pencil") != null;
    try testing.expect(pencil_off);
    // The project's stay.
    const commit_off = std.mem.indexOf(u8, argv, "\"提交\": \"off\"") != null;
    try testing.expect(!commit_off);
    const shared_off = std.mem.indexOf(u8, argv, "mcp__shared") != null;
    try testing.expect(!shared_off);
    const local_off = std.mem.indexOf(u8, argv, "mcp__localsrv") != null;
    try testing.expect(!local_off);
    // One name, both the person's and the project's: the project's.
    const pdf_off = std.mem.indexOf(u8, argv, "\"pdf\": \"off\"") != null;
    try testing.expect(!pdf_off);
}

// -- hooks (adapters.md 3.1-3.2) ----------------------------------------------
//
// The shipped `adapter.py`, run the way `+launch` runs it, against a stand-in
// `claude` first on PATH that prints whichever version a cell needs -- so the
// threshold is decided here and not by the Claude Code this machine has.
// `adapter.ps1` gives byte-for-byte the same answers to the same cells:
// `test/claude-code-adapter/compare.py`.

const HookCell = struct {
    /// What the stand-in `claude --version` prints.
    version: []const u8,
    args: []const []const u8 = &.{},
    polter: ?[]const u8 = "/Applications/It's Polter/polter",
    /// The session the launch is asked to go on with.
    session: ?[]const u8 = null,
};

const HookAnswer = struct {
    launch: Launch,
    /// How many `--settings` the command line carries.
    settings_count: usize,
    /// The one `--settings` object, parsed, when there is one that parses.
    settings: ?std.json.ObjectMap,
    notes: []const u8,
};

const HookRig = struct {
    root: []const u8,
    home: []const u8,
    exec: []const u8,
};

fn hookRig(aa: Allocator, io: std.Io) !HookRig {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const root = try std.fmt.allocPrint(aa, "/tmp/polter-hooks-{x}", .{&raw});
    const cwd = std.Io.Dir.cwd();
    const home = try std.fmt.allocPrint(aa, "{s}/home", .{root});
    // One personal skill, so a role that switches it off puts a
    // `skillOverrides` in the same `--settings` the hooks go into.
    const skill = try std.fmt.allocPrint(aa, "{s}/.claude/skills/pdf/SKILL.md", .{home});
    try cwd.createDirPath(io, std.fs.path.dirname(skill).?);
    {
        var f = try cwd.createFile(io, skill, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "---\nname: pdf\ndescription: Read PDFs.\n---\n");
    }
    const exec = try std.fmt.allocPrint(aa, "{s}/adapter.py", .{root});
    {
        var f = try cwd.createFile(io, exec, .{ .permissions = .fromMode(0o755) });
        defer f.close(io);
        try f.writeStreamingAll(io, @embedFile("plugin_claude_code_adapter_py"));
    }
    return .{ .root = root, .home = home, .exec = exec };
}

fn askHooks(aa: Allocator, io: std.Io, rig: HookRig, cell: HookCell) !?HookAnswer {
    const cwd = std.Io.Dir.cwd();
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const bin = try std.fmt.allocPrint(aa, "{s}/bin-{x}", .{ rig.root, &raw });
    try cwd.createDirPath(io, bin);
    {
        const path = try std.fmt.allocPrint(aa, "{s}/claude", .{bin});
        var f = try cwd.createFile(io, path, .{ .permissions = .fromMode(0o755) });
        defer f.close(io);
        try f.writeStreamingAll(io, try std.fmt.allocPrint(aa, "#!/bin/sh\necho '{s}'\n", .{cell.version}));
    }

    var env = try global.environMap();
    defer env.deinit();
    try standInClis(aa, io, &env, rig.root);
    try env.put("PATH", try std.fmt.allocPrint(aa, "{s}:{s}", .{ bin, env.get("PATH") orelse "" }));

    const p: persona.Persona = .{
        .key = "r",
        .name = "r",
        .cli_skills = .{ .except = &.{"skill:pdf"} },
    };
    const choice: persona.CliChoice = .{
        .cli = "claude-code",
        .args = cell.args,
    };
    var req: std.Io.Writer.Allocating = .init(aa);
    try writeLaunchRequest(&req.writer, p, choice, null, rig.home, cell.polter, cell.session);
    const adapter: Adapter = .{ .key = "claude-code", .label = "Claude Code", .bin = "claude", .adapter = rig.exec, .identify_env = &.{} };
    const answer = switch (try ask(aa, io, &env, adapter, .launch, req.written())) {
        .ok => |j| j,
        .failed => |why| {
            if (std.mem.indexOf(u8, why, "could not be run") != null) return null;
            std.debug.print("adapter failed: {s}\n", .{why});
            return error.TestUnexpectedResult;
        },
    };
    const l = try parseLaunch(aa, answer);

    var count: usize = 0;
    var settings: ?std.json.ObjectMap = null;
    for (l.argv, 0..) |a, i| {
        if (!std.mem.eql(u8, a, "--settings")) continue;
        count += 1;
        if (i + 1 < l.argv.len) {
            if (std.json.parseFromSliceLeaky(std.json.Value, aa, l.argv[i + 1], .{})) |v| {
                if (v == .object) settings = v.object;
            } else |_| {}
        }
    }
    return .{
        .launch = l,
        .settings_count = count,
        .settings = settings,
        .notes = try std.mem.join(aa, "\n", l.notes),
    };
}

/// The nine hooks, each running `<polter> +hook --cli claude-code <event>` in
/// exec form: `command` is the executable itself and `args` the rest, so no
/// shell reads it (#888 -- on Windows without Git Bash that shell is
/// PowerShell, and the sh-quoted string was a parse error there).
fn expectAllHooks(settings: std.json.ObjectMap, polter: []const u8) !void {
    const hooks = (settings.get("hooks") orelse return error.TestExpectedHooks).object;
    for ([_][]const u8{ "SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "PermissionRequest", "Notification", "PostToolUse", "PreToolUse", "PostToolUseFailure" }) |event| {
        const entries = (hooks.get(event) orelse {
            std.debug.print("no {s} hook\n", .{event});
            return error.TestExpectedHooks;
        }).array.items;
        const ours = entries[entries.len - 1].object;
        const hook = ours.get("hooks").?.array.items[0].object;
        try testing.expectEqualStrings("command", hook.get("type").?.string);
        try testing.expectEqual(@as(i64, 5), hook.get("timeout").?.integer);
        try testing.expectEqualStrings(polter, hook.get("command").?.string);
        const args = (hook.get("args") orelse return error.TestExpectedExecForm).array.items;
        const want = [_][]const u8{ "+hook", "--cli", "claude-code", event };
        try testing.expectEqual(want.len, args.len);
        for (want, args) |w, a| try testing.expectEqualStrings(w, a.string);
        // Exec form ignores `shell`; one written anyway would say a shell
        // is involved.
        try testing.expect(hook.get("shell") == null);
        if (std.mem.eql(u8, event, "Notification")) {
            try testing.expectEqualStrings("idle_prompt|elicitation_dialog", ours.get("matcher").?.string);
        } else {
            try testing.expect(ours.get("matcher") == null);
        }
    }
    try expectContextHooks(hooks, polter);
}

/// The two around a compaction (task 1779), running `+hook-context`:
/// `PreCompact` for every trigger, and `SessionStart` only for `source:
/// compact` -- just before the `+hook` entry, which stays the last.
fn expectContextHooks(hooks: std.json.ObjectMap, polter: []const u8) !void {
    const Want = struct { event: []const u8, matcher: ?[]const u8, from_end: usize };
    for ([_]Want{
        .{ .event = "PreCompact", .matcher = null, .from_end = 1 },
        .{ .event = "SessionStart", .matcher = "compact", .from_end = 2 },
    }) |want| {
        const entries = (hooks.get(want.event) orelse {
            std.debug.print("no {s} hook\n", .{want.event});
            return error.TestExpectedHooks;
        }).array.items;
        try testing.expect(entries.len >= want.from_end);
        const entry = entries[entries.len - want.from_end].object;
        if (want.matcher) |m| {
            const got = entry.get("matcher") orelse return error.TestExpectedMatcher;
            try testing.expectEqualStrings(m, got.string);
        } else {
            try testing.expect(entry.get("matcher") == null);
        }
        const hook = entry.get("hooks").?.array.items[0].object;
        try testing.expectEqualStrings("command", hook.get("type").?.string);
        try testing.expectEqualStrings(polter, hook.get("command").?.string);
        const args = (hook.get("args") orelse return error.TestExpectedExecForm).array.items;
        const argv = [_][]const u8{ "+hook-context", "--cli", "claude-code", want.event };
        try testing.expectEqual(argv.len, args.len);
        for (argv, args) |w, a| try testing.expectEqualStrings(w, a.string);
    }
}

/// Unquoted: exec form hands it over as one argument, apostrophe and space
/// and all.
const polter_path = "/Applications/It's Polter/polter";

test "agent_cli hooks: 2.1.144 gets no hooks, and a note that says why" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const rig = try hookRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    const a = (try askHooks(aa, io, rig, .{ .version = "2.1.144 (Claude Code)" })) orelse return error.SkipZigTest;
    try testing.expect(!a.launch.hooks);
    try testing.expect(a.settings.?.get("hooks") == null);
    try testing.expect(std.mem.indexOf(u8, a.notes, "Claude Code 2.1.144 is older than 2.1.145") != null);
}

test "agent_cli hooks: 2.1.145 gets all nine in the one --settings, beside the skill switch" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const rig = try hookRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    const a = (try askHooks(aa, io, rig, .{ .version = "2.1.145 (Claude Code)" })) orelse return error.SkipZigTest;
    try testing.expect(a.launch.hooks);
    try testing.expectEqual(@as(usize, 1), a.settings_count);
    const s = a.settings.?;
    try testing.expectEqualStrings("off", s.get("skillOverrides").?.object.get("pdf").?.string);
    try expectAllHooks(s, polter_path);
    try testing.expect(std.mem.indexOf(u8, a.notes, "Hooks are not configured") == null);
}

test "agent_cli hooks: a role's own inline --settings, the skill switch and the hooks are one object" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const rig = try hookRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    const a = (try askHooks(aa, io, rig, .{
        .version = "2.1.283 (Claude Code)",
        .args = &.{
            "--settings",
            \\{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}
            ,
        },
    })) orelse return error.SkipZigTest;
    try testing.expect(a.launch.hooks);
    try testing.expectEqual(@as(usize, 1), a.settings_count);
    const s = a.settings.?;
    try testing.expectEqualStrings("dark", s.get("theme").?.string);
    try testing.expectEqualStrings("off", s.get("skillOverrides").?.object.get("pdf").?.string);
    try expectAllHooks(s, polter_path);
    // The role's own Stop hook is kept, ahead of Polter's.
    const stop = s.get("hooks").?.object.get("Stop").?.array.items;
    try testing.expectEqual(@as(usize, 2), stop.len);
    try testing.expectEqualStrings("say done", stop[0].object.get("hooks").?.array.items[0].object.get("command").?.string);
}

test "agent_cli hooks: a role whose --settings is a file gets no hooks, and a note" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const rig = try hookRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    const a = (try askHooks(aa, io, rig, .{
        .version = "2.1.283 (Claude Code)",
        .args = &.{ "--settings", "/etc/claude/role.json" },
    })) orelse return error.SkipZigTest;
    try testing.expect(!a.launch.hooks);
    // The file is still passed as it was written, and nothing Polter adds
    // carries any hooks.
    const joined = try std.mem.join(aa, "\x00", a.launch.argv);
    try testing.expect(std.mem.indexOf(u8, joined, "--settings\x00/etc/claude/role.json") != null);
    try testing.expect(std.mem.indexOf(u8, joined, "+hook") == null);
    try testing.expect(std.mem.indexOf(u8, a.notes, "Hooks are not configured: the role's --settings is a file") != null);
}

test "agent_cli hooks: an unreadable version, or no Polter path, gets no hooks and says which" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const rig = try hookRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    const garbled = (try askHooks(aa, io, rig, .{ .version = "Claude Code, some version" })) orelse return error.SkipZigTest;
    try testing.expect(!garbled.launch.hooks);
    try testing.expect(std.mem.indexOf(u8, garbled.notes, "claude --version did not say a version") != null);

    const nowhere = (try askHooks(aa, io, rig, .{ .version = "2.1.283 (Claude Code)", .polter = null })) orelse return error.SkipZigTest;
    try testing.expect(!nowhere.launch.hooks);
    try testing.expect(std.mem.indexOf(u8, nowhere.notes, "did not say where Polter is") != null);
}

// -- the status line (control-room.md 3.6) -------------------------------------

/// The value of one variable in a `launch` answer's environment.
fn launchEnv(l: Launch, name: []const u8) ?[]const u8 {
    for (l.env) |kv| if (std.mem.eql(u8, kv[0], name)) return kv[1];
    return null;
}

fn writeHomeSettings(aa: Allocator, io: std.Io, rig: HookRig, json: []const u8) !void {
    const path = try std.fmt.allocPrint(aa, "{s}/.claude/settings.json", .{rig.home});
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, json);
}

test "agent_cli status line: with the hooks goes Polter's status line, and with nobody's to stand in for, nothing is chained" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const rig = try hookRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    const a = (try askHooks(aa, io, rig, .{ .version = "2.1.296 (Claude Code)" })) orelse return error.SkipZigTest;
    const line = (a.settings.?.get("statusLine") orelse return error.TestExpectedStatusLine).object;
    try testing.expectEqualStrings("command", line.get("type").?.string);
    // One line of `sh`, the apostrophe in the path closed and reopened.
    try testing.expectEqualStrings(
        "'/Applications/It'\\''s Polter/polter' +statusline --cli claude-code",
        line.get("command").?.string,
    );
    const chained = launchEnv(a.launch, "POLTER_STATUSLINE_CHAIN");
    try testing.expect(chained == null);
}

test "agent_cli status line: the person's own is handed on whole, and its other fields stay on the line" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const rig = try hookRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    const theirs = "~/.claude/statusline.sh --who '我' \"$HOME\" | cut -c1-80";
    try writeHomeSettings(aa, io, rig, try std.fmt.allocPrint(
        aa,
        "{{\"statusLine\":{{\"type\":\"command\",\"command\":{f},\"padding\":0,\"refreshInterval\":5}}}}",
        .{std.json.fmt(theirs, .{})},
    ));

    const a = (try askHooks(aa, io, rig, .{ .version = "2.1.296 (Claude Code)" })) orelse return error.SkipZigTest;
    const line = a.settings.?.get("statusLine").?.object;
    try testing.expect(std.mem.endsWith(u8, line.get("command").?.string, " +statusline --cli claude-code"));
    const padding = line.get("padding").?.integer;
    try testing.expectEqual(@as(i64, 0), padding);
    try testing.expectEqual(@as(i64, 5), line.get("refreshInterval").?.integer);
    const chained = launchEnv(a.launch, "POLTER_STATUSLINE_CHAIN") orelse return error.TestExpectedChain;
    try testing.expectEqualStrings(theirs, chained);

    // The role's own, given inline, comes before the file.
    const role = (try askHooks(aa, io, rig, .{
        .version = "2.1.296 (Claude Code)",
        .args = &.{ "--settings", "{\"statusLine\":{\"type\":\"command\",\"command\":\"echo role\"}}" },
    })) orelse return error.SkipZigTest;
    const from_role = launchEnv(role.launch, "POLTER_STATUSLINE_CHAIN") orelse return error.TestExpectedChain;
    try testing.expectEqualStrings("echo role", from_role);
    try testing.expectEqual(@as(usize, 1), role.settings_count);
}

test "agent_cli status line: where there are no hooks there is no status line either, and the person's is left alone" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const rig = try hookRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};
    try writeHomeSettings(aa, io, rig, "{\"statusLine\":{\"type\":\"command\",\"command\":\"echo mine\"}}");

    const old = (try askHooks(aa, io, rig, .{ .version = "2.1.144 (Claude Code)" })) orelse return error.SkipZigTest;
    const set = old.settings.?.get("statusLine") != null;
    try testing.expect(!set);
    try testing.expect(launchEnv(old.launch, "POLTER_STATUSLINE_CHAIN") == null);
}

test "agent_cli status line: the line it writes is one sh reads back as the Polter it was given, apostrophe and space and all" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const rig = try hookRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    // A stand-in Polter at a path a shell would cut in three, that says what
    // it was run with.
    const dir = try std.fmt.allocPrint(aa, "{s}/It's Polter", .{rig.root});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const polter = try std.fmt.allocPrint(aa, "{s}/polter", .{dir});
    {
        var f = try std.Io.Dir.cwd().createFile(io, polter, .{ .permissions = .fromMode(0o755) });
        defer f.close(io);
        try f.writeStreamingAll(io, "#!/bin/sh\nprintf '%s|' \"$@\"\n");
    }

    const a = (try askHooks(aa, io, rig, .{ .version = "2.1.296 (Claude Code)", .polter = polter })) orelse return error.SkipZigTest;
    const command = a.settings.?.get("statusLine").?.object.get("command").?.string;
    const ran = try std.process.run(aa, io, .{ .argv = &.{ "/bin/sh", "-c", command } });
    try testing.expectEqualStrings("+statusline|--cli|claude-code|", ran.stdout);
}

test "agent_cli resume: only a JSON true in the inventory says an adapter can go on with a session" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try testing.expect(saysResume(aa, "{\"version\":1,\"resume\":true,\"items\":[]}"));
    for ([_][]const u8{
        "{\"version\":1,\"items\":[]}",
        "{\"resume\":false}",
        "{\"resume\":\"true\"}",
        "{\"resume\":1}",
        "{\"resume\":null}",
        "[true]",
        "not json",
    }) |no| try testing.expect(!saysResume(aa, no));
}

test "agent_cli resume: the launch line carries the group and a session that is plain, and leaves off one that is not" {
    var buf: [512]u8 = undefined;

    var w: std.Io.Writer = .fixed(&buf);
    try writeLaunchWords(&w, "polter-supervisor", "claude-code", .none);
    try testing.expectEqualStrings(" +launch polter-supervisor claude-code", w.buffered());

    w = .fixed(&buf);
    try writeLaunchWords(&w, "polter-supervisor", "claude-code", .{
        .group = "web-app",
        .session = "eed9173b-c1fc-4493-aa00-187bacdc94cf",
    });
    try testing.expectEqualStrings(
        " +launch polter-supervisor claude-code --group=web-app --resume=eed9173b-c1fc-4493-aa00-187bacdc94cf",
        w.buffered(),
    );

    // An id a shell would read as something else never reaches the line:
    // the group still does, and the role starts in a new session.
    for ([_][]const u8{ "a b", "x;rm -rf ~", "$(id)", "it's", "-rf", "", "a\"b", "a/b" }) |bad| {
        try testing.expect(!isSessionToken(bad));
        w = .fixed(&buf);
        try writeLaunchWords(&w, "r", "c", .{ .group = "g", .session = bad });
        try testing.expectEqualStrings(" +launch r c --group=g", w.buffered());
    }
    try testing.expect(isSessionToken("a" ** 96));
    try testing.expect(!isSessionToken("a" ** 97));
    try testing.expect(isSessionToken("rollout-2026.10.13_x"));
}

/// Put a transcript for `session` under some project of the rig's home.
fn writeTranscript(aa: Allocator, io: std.Io, rig: HookRig, session: []const u8) !void {
    const path = try std.fmt.allocPrint(aa, "{s}/.claude/projects/-some-other-place/{s}.jsonl", .{ rig.home, session });
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, "{\"type\":\"user\"}\n");
}

/// Where `--resume` is in a command line, and what follows it.
fn resumeIn(argv: []const []const u8) ?[]const u8 {
    for (argv, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--resume")) return if (i + 1 < argv.len) argv[i + 1] else "";
    }
    return null;
}

test "agent_cli resume: the shipped Claude Code adapter says it can, and goes on with a session whose transcript is there" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const rig = try hookRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    // What it says of itself, asked the way the cache asks.
    var env = try global.environMap();
    defer env.deinit();
    try standInClis(aa, io, &env, rig.root);
    const adapter: Adapter = .{ .key = "claude-code", .label = "Claude Code", .bin = "claude", .adapter = rig.exec, .identify_env = &.{} };
    const request = try std.fmt.allocPrint(aa, "{{\"version\":1,\"cwd\":null,\"home\":{f}}}", .{std.json.fmt(rig.home, .{})});
    const inv = switch (try ask(aa, io, &env, adapter, .inventory, request)) {
        .ok => |j| j,
        .failed => |why| {
            if (std.mem.indexOf(u8, why, "could not be run") != null) return error.SkipZigTest;
            std.debug.print("adapter failed: {s}\n", .{why});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expect(saysResume(aa, inv));

    const session = "0a1b2c3d-1111-4222-8333-444455556666";
    try writeTranscript(aa, io, rig, session);

    const a = (try askHooks(aa, io, rig, .{
        .version = "2.1.296 (Claude Code)",
        .session = session,
        .args = &.{"--verbose"},
    })) orelse return error.SkipZigTest;
    try testing.expectEqualStrings(session, resumeIn(a.launch.argv).?);
    try testing.expect(std.mem.indexOf(u8, a.notes, "Going on with the last session") != null);
    // Beside everything else the launch carries, not in place of it: the
    // hooks are still there, and so are the role's own arguments.
    try testing.expect(a.launch.hooks);
    try testing.expectEqualStrings("--verbose", a.launch.argv[a.launch.argv.len - 1]);
    try testing.expectEqualStrings("claude", a.launch.argv[0]);

    // No session asked for: no `--resume`, and no note about one.
    const fresh = (try askHooks(aa, io, rig, .{ .version = "2.1.296 (Claude Code)" })) orelse return error.SkipZigTest;
    try testing.expect(resumeIn(fresh.launch.argv) == null);
    try testing.expect(std.mem.indexOf(u8, fresh.notes, "session") == null);
}

test "agent_cli resume: a session that is gone, or is not one, starts a new session and a note says so" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const rig = try hookRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    const there = "0a1b2c3d-1111-4222-8333-444455556666";
    try writeTranscript(aa, io, rig, there);

    const Cell = struct { session: []const u8, args: []const []const u8 = &.{}, says: []const u8 };
    const cells = [_]Cell{
        // Its transcript is not on this machine. Measured: `claude --resume`
        // of one prints "No conversation found" and exits 1 by itself.
        .{ .session = "99999999-1111-4222-8333-444455556666", .says = "is no longer on this machine, so this starts a new session." },
        // Not an id Claude Code gives: `--resume <words>` is a search.
        .{ .session = "last-tuesday", .says = "is not one Claude Code gives a session, so this starts a new session." },
        // The role has its own say, even for a session that is there.
        .{ .session = there, .args = &.{ "-r", "mine" }, .says = "already choose a session (-r)" },
        .{ .session = there, .args = &.{"--continue"}, .says = "already choose a session (--continue)" },
        .{ .session = there, .args = &.{"--session-id=77777777-1111-4222-8333-444455556666"}, .says = "already choose a session (--session-id)" },
    };
    for (cells) |c| {
        const a = (try askHooks(aa, io, rig, .{
            .version = "2.1.296 (Claude Code)",
            .session = c.session,
            .args = c.args,
        })) orelse return error.SkipZigTest;
        // Never ours on the line -- and there is still a command to run.
        for (a.launch.argv) |arg| try testing.expect(!std.mem.eql(u8, arg, "--resume"));
        try testing.expectEqualStrings("claude", a.launch.argv[0]);
        if (std.mem.indexOf(u8, a.notes, c.says) == null) {
            std.debug.print("no note saying {s} in:\n{s}\n", .{ c.says, a.notes });
            return error.TestExpectedEqual;
        }
    }
}

test "agent_cli identify: an adapter is shown only the variables it declared, and asked only when it has one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const claude: Adapter = .{ .key = "claude-code", .label = "Claude Code", .bin = "claude", .adapter = "a.py", .identify_env = &.{ "CLAUDECODE", "CLAUDE_CODE_SESSION_ID" } };
    const other: Adapter = .{ .key = "other", .label = "Other", .bin = "o", .adapter = "o.py", .identify_env = &.{"OTHER_ID"} };
    const sighting: Sighting = .{ .pid = 4242, .env = &.{
        .{ "CLAUDECODE", "1" },
        .{ "CLAUDE_CODE_SESSION_ID", "0b1d1c35-5e33-4b5e-9f8c-1a2b3c4d5e6f" },
        .{ "OTHER_ID", "x" },
    } };
    var w: std.Io.Writer.Allocating = .init(aa);
    try writeIdentifyRequest(&w.writer, claude, sighting, "/w", "/h");
    try testing.expectEqualStrings(
        \\{"version":1,"cwd":"/w","home":"/h","pid":4242,"sidecar_pid":null,"env":{"CLAUDECODE":"1","CLAUDE_CODE_SESSION_ID":"0b1d1c35-5e33-4b5e-9f8c-1a2b3c4d5e6f"}}
    , w.written());

    try testing.expect(couldRecognise(claude, sighting));
    try testing.expect(!couldRecognise(claude, .{ .pid = 1, .env = &.{.{ "OTHER_ID", "x" }} }));
    try testing.expect(!couldRecognise(other, .none));
}

test "agent_cli identify: only a JSON true is mine, and a quit needs a screen rule" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const full = try parseIdentify(aa,
        \\{"me":true,"session":"0b1d1c35-5e33-4b5e-9f8c-1a2b3c4d5e6f","session_written_ms":5,
        \\ "quit":{"text":"/exit","ready":{"line":["❯"],"none_of":["Do you want"]}}}
    );
    try testing.expect(full.me);
    try testing.expectEqualStrings("/exit", full.quit.?.text);
    try testing.expectEqual(@as(?i64, 5), full.session_written_ms);

    for ([_][]const u8{
        \\{"me":"true"}
        ,
        \\{"me":1}
        ,
        \\{}
        ,
        \\not json
        ,
    }) |answer| try testing.expect(!(try parseIdentify(aa, answer)).me);

    // Mine, and nothing that can be typed: no rule for the screen, a rule
    // that names no line, a line with a return in it.
    for ([_][]const u8{
        \\{"me":true,"quit":{"text":"/exit"}}
        ,
        \\{"me":true,"quit":{"text":"/exit","ready":{"line":[],"none_of":["x"]}}}
        ,
        \\{"me":true,"quit":{"text":"/exit\r","ready":{"line":["❯"]}}}
        ,
    }) |answer| {
        const said = try parseIdentify(aa, answer);
        try testing.expect(said.me);
        try testing.expect(said.quit == null);
    }
    // A session id that is not one is not kept.
    try testing.expect((try parseIdentify(aa,
        \\{"me":true,"session":"--resume x"}
    )).session == null);
}

test "agent_cli identify: the shipped Claude Code adapter knows its own, finds the session, and leaves the rest" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const rig = try hookRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};
    const session = "0a1b2c3d-1111-4222-8333-444455556666";
    try writeTranscript(aa, io, rig, session);

    var env = try global.environMap();
    defer env.deinit();
    try standInClis(aa, io, &env, rig.root);
    try env.put("HOME", rig.home);
    // The names plugins/claude-code/plugin.json declares.
    const adapter: Adapter = .{ .key = "claude-code", .label = "Claude Code", .bin = "claude", .adapter = rig.exec, .identify_env = &.{ "CLAUDECODE", "AI_AGENT", "CLAUDE_CODE_SESSION_ID" } };

    const found = try recognise(aa, io, &env, &.{adapter}, .{ .pid = 1, .env = &.{
        .{ "CLAUDECODE", "1" },
        .{ "AI_AGENT", "claude-code_2-1-301_harness" },
        .{ "CLAUDE_CODE_SESSION_ID", session },
    } }, null);
    const k = switch (found) {
        .known => |k| k,
        .unknown => return error.SkipZigTest, // no python3 to run it
    };
    try testing.expectEqualStrings("claude-code", k.key);
    try testing.expectEqualStrings(session, k.identified.session.?);
    try testing.expect(k.identified.session_written_ms != null);
    try testing.expectEqualStrings("/exit", k.identified.quit.?.text);

    // Its session gone from this machine: still Claude Code, no session.
    const gone = try recognise(aa, io, &env, &.{adapter}, .{ .pid = 1, .env = &.{
        .{ "CLAUDECODE", "1" },
        .{ "CLAUDE_CODE_SESSION_ID", "99999999-1111-4222-8333-444455556666" },
    } }, null);
    try testing.expect(gone.known.identified.session == null);

    // Something else's sidecar: nothing to recognise, so it is not asked.
    try testing.expectEqual(Recognised.unknown, try recognise(aa, io, &env, &.{adapter}, .{ .pid = 1, .env = &.{} }, null));
    // Asked and not its own.
    try testing.expectEqual(Recognised.unknown, try recognise(aa, io, &env, &.{adapter}, .{ .pid = 1, .env = &.{.{ "AI_AGENT", "codex_1" }} }, null));
}

test "agent_cli names: what each CLI is called is read out of what a read leaves, and nothing out of what does not read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const clis =
        \\[{"key":"claude-code","label":"Claude Code","bin":"claude","error":null,"inventory":{"resume":true}},
        \\ {"key":"codex","label":"","bin":"codex","error":"no such file","inventory":null}]
    ;
    const read = try Cache.namesIn(a, clis);
    try std.testing.expectEqual(@as(usize, 2), read.len);
    try std.testing.expectEqualStrings("claude-code", read[0].key);
    try std.testing.expectEqualStrings("Claude Code", read[0].label);
    // One that failed still has its key, and the label it was given.
    try std.testing.expectEqualStrings("codex", read[1].key);
    try std.testing.expectEqualStrings("", read[1].label);
    try std.testing.expectEqual(@as(usize, 0), (try Cache.namesIn(a, "[]")).len);
    try std.testing.expectEqual(@as(usize, 0), (try Cache.namesIn(a, "not json")).len);
}

// -- the Codex adapter (task 1667) -------------------------------------------
//
// The shipped `plugins/codex/adapter.py`, run the way `+launch` and
// `Identities` run it, against a made-up home. Every `-c` it is held to here
// was first measured against a real codex 0.163 (the file's header says
// how); these keep the file saying what was measured.

const codex_session = "01a14638-8e88-7993-b863-bd9d4c1a0ba8";

const CodexRig = struct {
    root: []const u8,
    home: []const u8,
    project: []const u8,
    rollout: []const u8,
    adapter: Adapter,
};

/// Stand-ins for `claude` and `codex`, first on `env`'s PATH, so that no test
/// here starts the real one -- an adapter's inventory asks `<bin> --help`
/// for its launch options (task 1677), and what this machine has installed
/// must not decide a reading. `--version` answers a Claude Code that takes
/// hooks; `--help` lists one value per option, `stand-in`, which a test
/// can look for to know the stand-in is what answered. Anything else
/// fails. In `<root>/stand-in-bin`, which goes with the test's `root`.
fn standInClis(aa: Allocator, io: std.Io, env: *std.process.Environ.Map, root: []const u8) !void {
    const bin = try std.fmt.allocPrint(aa, "{s}/stand-in-bin", .{root});
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, bin);
    for ([_][2][]const u8{
        .{
            "claude",
            \\#!/bin/sh
            \\case "$1" in
            \\  --version) echo '2.1.302 (Claude Code)' ;;
            \\  --help) printf '%s\n' 'Options:' '  --permission-mode <mode>  Permission mode (choices: "stand-in")' ;;
            \\  *) exit 1 ;;
            \\esac
            \\
        },
        .{
            "codex",
            \\#!/bin/sh
            \\case "$1" in
            \\  --help) printf '%s\n' 'Options:' '  -s, --sandbox <MODE>' '          [possible values: stand-in]' '      --no-daemon' ;;
            \\  *) exit 1 ;;
            \\esac
            \\
        },
    }) |stub| {
        const path = try std.fmt.allocPrint(aa, "{s}/{s}", .{ bin, stub[0] });
        var f = try cwd.createFile(io, path, .{ .permissions = .fromMode(0o755) });
        defer f.close(io);
        try f.writeStreamingAll(io, stub[1]);
    }
    try env.put("PATH", try std.fmt.allocPrint(aa, "{s}:{s}", .{ bin, env.get("PATH") orelse "" }));
}

fn codexRig(aa: Allocator, io: std.Io) !CodexRig {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const root = try std.fmt.allocPrint(aa, "/tmp/polter-codex-{x}", .{&raw});
    const cwd = std.Io.Dir.cwd();
    const files = [_][2][]const u8{
        .{
            "home/.codex/config.toml",
            \\model = "gpt-5.6-luna"
            \\developer_instructions = "mine"
            \\
            \\[mcp_servers.polter]
            \\command = "/Applications/Polter.app/Contents/MacOS/polter"
            \\args = ["+mcp"]
            \\
            \\[mcp_servers.polter.env]
            \\POLTER_AGENT_CLI = "codex"
            \\
            \\[mcp_servers.pencil]
            \\command = "/opt/pencil/bin/pencil-mcp"
            \\args = ["--api-key", "hunter2"]
            \\
            \\[mcp_servers.docs]
            \\url = "https://user:pw@docs.example.com/mcp"
            \\
            \\[mcp_servers.gone]
            \\command = "/bin/gone"
            \\enabled = false
            \\
        },
        // The person's: in Codex's own directory, in the Agent Skills one,
        // and what Codex ships with.
        .{ "home/.codex/skills/pdf/SKILL.md", "---\nname: pdf\ndescription: Mine.\n---\n" },
        .{ "home/.agents/skills/writer/SKILL.md", "---\nname: writer\ndescription: Write.\n---\n" },
        .{ "home/.codex/skills/.system/imagegen/SKILL.md", "---\nname: imagegen\ndescription: Images.\n---\n" },
        // The project's, in both places Codex reads a project's from: one of
        // its own, and one with the person's `pdf`'s name.
        .{ "project/.agents/skills/提交/SKILL.md", "---\nname: 提交\ndescription: Commit.\n---\n" },
        .{ "project/.codex/skills/pdf/SKILL.md", "---\nname: pdf\ndescription: Ours.\n---\n" },
        .{ "home/.codex/sessions/2026/10/17/rollout-2026-10-17T01-00-00-" ++ codex_session ++ ".jsonl", "" },
    };
    for (files) |f| {
        const path = try std.fmt.allocPrint(aa, "{s}/{s}", .{ root, f[0] });
        try cwd.createDirPath(io, std.fs.path.dirname(path).?);
        var file = try cwd.createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, f[1]);
    }
    // The rollout's first line, as Codex writes it: which directory the
    // session is in is what `identify` matches when no process names it.
    {
        const path = try std.fmt.allocPrint(aa, "{s}/{s}", .{ root, files[files.len - 1][0] });
        var f = try cwd.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, try std.fmt.allocPrint(aa,
            \\{{"type":"session_meta","payload":{{"session_id":"{s}","cwd":"{s}/project","originator":"codex-tui"}}}}
            \\
        , .{ codex_session, root }));
    }
    const exec = try std.fmt.allocPrint(aa, "{s}/adapter.py", .{root});
    {
        var f = try cwd.createFile(io, exec, .{ .permissions = .fromMode(0o755) });
        defer f.close(io);
        try f.writeStreamingAll(io, @embedFile("plugin_codex_adapter_py"));
    }
    return .{
        .root = root,
        .home = try std.fmt.allocPrint(aa, "{s}/home", .{root}),
        .project = try std.fmt.allocPrint(aa, "{s}/project", .{root}),
        .rollout = try std.fmt.allocPrint(aa, "{s}/{s}", .{ root, files[files.len - 1][0] }),
        .adapter = .{
            .key = "codex",
            .label = "Codex",
            .bin = "codex",
            .adapter = exec,
            .identify_env = &.{ "POLTER_AGENT_CLI", "POLTER_REGISTERED" },
        },
    };
}

/// This process's environment without `CODEX_HOME`, which would point the
/// adapter away from the made-up home.
fn codexEnv() !std.process.Environ.Map {
    var env = try global.environMap();
    _ = env.swapRemove("CODEX_HOME");
    return env;
}

/// The adapter's answer, or a skip when this machine cannot run Python.
fn askCodex(aa: Allocator, io: std.Io, rig: CodexRig, question: Question, request: []const u8) ![]const u8 {
    var env = try codexEnv();
    defer env.deinit();
    try standInClis(aa, io, &env, rig.root);
    return switch (try ask(aa, io, &env, rig.adapter, question, request)) {
        .ok => |j| j,
        .failed => |why| {
            if (std.mem.indexOf(u8, why, "could not be run") != null) return error.SkipZigTest;
            std.debug.print("adapter failed: {s}\n", .{why});
            return error.TestUnexpectedResult;
        },
    };
}

fn codexLaunch(aa: Allocator, io: std.Io, rig: CodexRig, p: persona.Persona, choice: persona.CliChoice, session: ?[]const u8) !Launch {
    var req: std.Io.Writer.Allocating = .init(aa);
    try writeLaunchRequest(&req.writer, p, choice, rig.project, rig.home, null, session);
    return try parseLaunch(aa, try askCodex(aa, io, rig, .launch, req.written()));
}

test "codex adapter: what a role can pick from, with nothing secret and nothing switched off already (task 1667)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rig = try codexRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    const req = try std.fmt.allocPrint(aa, "{{\"version\":1,\"cwd\":\"{s}\",\"home\":\"{s}\"}}", .{ rig.project, rig.home });
    const inv = try askCodex(aa, io, rig, .inventory, req);

    // The key passed as an argument and the password in a URL never leave,
    // and neither does where anything lives.
    try testing.expect(std.mem.indexOf(u8, inv, "hunter2") == null);
    try testing.expect(std.mem.indexOf(u8, inv, "user:pw") == null);
    try testing.expect(std.mem.indexOf(u8, inv, rig.root) == null);

    const v = try std.json.parseFromSliceLeaky(std.json.Value, aa, inv, .{});
    try testing.expect(v.object.get("resume").?.bool);
    // The launch options come from the stand-in's `--help`, never from a
    // real `codex` on this machine (`standInClis`, task 1677): only the
    // sandbox, with its one value and its short spelling.
    const opts = v.object.get("options").?.array.items;
    try testing.expectEqual(@as(usize, 1), opts.len);
    try testing.expectEqualStrings("sandbox", opts[0].object.get("key").?.string);
    try testing.expectEqualStrings("stand-in", opts[0].object.get("values").?.array.items[0].object.get("value").?.string);
    try testing.expectEqualStrings("-s", opts[0].object.get("aliases").?.array.items[0].string);
    var ids: std.StringHashMapUnmanaged(std.json.ObjectMap) = .empty;
    for (v.object.get("items").?.array.items) |item| try ids.put(aa, item.object.get("id").?.string, item.object);
    const want = [_][]const u8{
        "skill:pdf",  "skill:writer", "skill:imagegen",
        "skill:提交",
        "mcp:polter", "mcp:pencil",   "mcp:docs",
    };
    for (want) |id| if (!ids.contains(id)) {
        std.debug.print("missing {s} in {s}\n", .{ id, inv });
        return error.TestUnexpectedResult;
    };
    // `gone` is switched off in the person's own config: nothing to decide.
    try testing.expectEqual(@as(usize, want.len), ids.count());
    try testing.expect(ids.get("mcp:polter").?.get("locked").?.bool);
    try testing.expectEqualStrings("stdio · pencil-mcp", ids.get("mcp:pencil").?.get("detail").?.string);
    try testing.expectEqualStrings("http · docs.example.com", ids.get("mcp:docs").?.get("detail").?.string);
    // One name, the person's and the project's: the project's row.
    try testing.expectEqualStrings("project", ids.get("skill:pdf").?.get("source").?.string);
    try testing.expectEqualStrings("codex", ids.get("skill:imagegen").?.get("source").?.string);
}

test "codex adapter: a role is the -c overrides Codex was measured to take, and never the project's (task 1667)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rig = try codexRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    // A supervisor's shape, keeping one skill, taking one server and trying
    // to take Polter's.
    const p: persona.Persona = .{
        .key = "r",
        .name = "r",
        .instructions = "say \"hi\"\nthen stop\x7f",
        .cli_skills = .{ .default = false, .except = &.{"skill:writer"} },
        .cli_mcp = .{ .except = &.{ "mcp:pencil", "mcp:polter" } },
    };
    const choice: persona.CliChoice = .{
        .cli = "codex",
        .model = "gpt-5.6-luna",
    };
    const l = try codexLaunch(aa, io, rig, p, choice, null);
    const argv = try std.mem.join(aa, "\x00", l.argv);

    try testing.expectEqualStrings("codex", l.argv[0]);
    try testing.expectEqualStrings("--no-daemon", l.argv[1]);
    // Exactly one skill goes, by its file: what Codex ships with. The
    // person's `pdf` shares its name with the project's, so in this
    // directory it is the project's and stays; `writer` was kept; `提交`
    // is the project's.
    const skills = try std.fmt.allocPrint(aa, "\x00-c\x00skills.config=[{{path=\"{s}/.codex/skills/.system/imagegen/SKILL.md\",enabled=false}}]\x00", .{rig.home});
    const one_skill_off = std.mem.indexOf(u8, argv, skills) != null;
    try testing.expect(one_skill_off);
    const project_kept = std.mem.indexOf(u8, argv, "/project/") == null;
    try testing.expect(project_kept);
    // A server is not started at all; Polter's is never the role's to take.
    const pencil_off = std.mem.indexOf(u8, argv, "\x00-c\x00mcp_servers.pencil.enabled=false") != null;
    try testing.expect(pencil_off);
    const polter_kept = std.mem.indexOf(u8, argv, "mcp_servers.polter") == null;
    try testing.expect(polter_kept);
    const docs_kept = std.mem.indexOf(u8, argv, "mcp_servers.docs") == null;
    try testing.expect(docs_kept);
    // The instructions as one TOML basic string: quotes and newlines
    // escaped as JSON does, and DEL, which TOML wants escaped and JSON
    // leaves alone.
    const instructions = std.mem.indexOf(u8, argv, "\x00-c\x00developer_instructions=\"say \\\"hi\\\"\\nthen stop\\u007f\"") != null;
    try testing.expect(instructions);
    const model = std.mem.indexOf(u8, argv, "\x00-m\x00gpt-5.6-luna") != null;
    try testing.expect(model);
    // The person's own `developer_instructions` is stood in for, and said.
    const said = std.mem.indexOf(u8, try std.mem.join(aa, "\n", l.notes), "developer_instructions in config.toml") != null;
    try testing.expect(said);
    const fresh = std.mem.indexOf(u8, argv, "resume") == null;
    try testing.expect(fresh);
}

test "codex adapter: a session is gone on with only when its rollout is on this machine (task 1667)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rig = try codexRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    const p: persona.Persona = .{ .key = "r", .name = "r" };
    const choice: persona.CliChoice = .{ .cli = "codex", .model = "m" };

    // Here: `codex resume <id>`, and the options after it -- `resume` takes
    // every option the bare command does.
    const here = try codexLaunch(aa, io, rig, p, choice, codex_session);
    try testing.expect(here.argv.len >= 5);
    try testing.expectEqualStrings("resume", here.argv[1]);
    try testing.expectEqualStrings(codex_session, here.argv[2]);
    // Never in the shared app-server daemon, resumed or new (task 1667).
    try testing.expectEqualStrings("--no-daemon", here.argv[3]);
    try testing.expectEqualStrings("-m", here.argv[4]);

    // Not here, or not a session id at all (a word would be a session
    // *name* to Codex): a new session, and a note that says why.
    const cases = [_][]const u8{ "99999999-1111-4222-8333-444455556666", "latest" };
    for (cases) |s| {
        const l = try codexLaunch(aa, io, rig, p, choice, s);
        const argv = try std.mem.join(aa, "\x00", l.argv);
        const resumed = std.mem.indexOf(u8, argv, "resume") != null;
        try testing.expect(!resumed);
        const noted = std.mem.indexOf(u8, try std.mem.join(aa, "\n", l.notes), "starting a new session") != null;
        try testing.expect(noted);
    }

    // A role that already chose keeps its choice.
    var own = choice;
    own.args = &.{ "resume", "--last" };
    const l = try codexLaunch(aa, io, rig, p, own, codex_session);
    const argv = try std.mem.join(aa, "\x00", l.argv);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, argv, "resume"));
    try testing.expect(std.mem.indexOf(u8, argv, codex_session) == null);
}

test "codex adapter: identify knows Codex by the provision's marker or by its process, and quits only at rest (task 1667)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rig = try codexRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    const asked = struct {
        fn f(a: Allocator, i: std.Io, r: CodexRig, sighting: Sighting) !Identified {
            var req: std.Io.Writer.Allocating = .init(a);
            try writeIdentifyRequest(&req.writer, r.adapter, sighting, null, r.home);
            return try parseIdentify(a, try askCodex(a, i, r, .identify, req.written()));
        }
    }.f;

    // The marker alone (Windows, where there is no pid): Codex, with no
    // session to name rather than a guessed one.
    const marked = try asked(aa, io, rig, .{ .pid = null, .env = &.{.{ "POLTER_AGENT_CLI", "codex" }} });
    try testing.expect(marked.me);
    try testing.expect(marked.session == null);
    const quit = marked.quit orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("/exit", quit.text);

    // Only the version marker every host's entry carries, and a parent that
    // is not Codex (this test): not Codex.
    const other = try asked(aa, io, rig, .{ .pid = @intCast(std.c.getpid()), .env = &.{.{ "POLTER_REGISTERED", "1.2.3" }} });
    try testing.expect(!other.me);

    // The screens, as read off real Codex 0.163 terminals (tasks 1640, 1656).
    const TakeOver = @import("TakeOver.zig");
    const idle =
        \\  /review - review any changes and find issues
        \\
        \\› Ask Codex to do anything
        \\
        \\  GPT-5.6-Luna low · /Users/Shared/polter-test/out/t1640-w
        \\  ? for shortcuts                                    ⚠ 1 warning · f2 to view
        \\
    ;
    try testing.expect(TakeOver.ready(idle, quit));
    const turn =
        \\• Working (7s • esc to interrupt)
        \\
        \\› Ask Codex to do anything
        \\
        \\  ? for shortcuts
    ;
    try testing.expect(!TakeOver.ready(turn, quit));
    const approval =
        \\• Calling polter.me
        \\  Allow the polter MCP server to run tool "me"?
        \\  › 1. Allow                   Run the tool and continue
        \\  enter to submit | esc to cancel
    ;
    try testing.expect(!TakeOver.ready(approval, quit));
    const draft =
        \\› fix the failing test
        \\
        \\  ? for shortcuts
    ;
    try testing.expect(!TakeOver.ready(draft, quit));
}

test "codex adapter: identify names the session whose rollout the Codex process holds open (task 1667)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rig = try codexRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    // A stand-in for the native Codex: a program called `codex` that holds
    // a rollout open, as the real one was measured to (lsof, codex 0.163).
    // It is `/bin/sh` under that name, so the process's executable is what
    // the adapter reads, not a script's interpreter.
    const cwd = std.Io.Dir.cwd();
    const bin = try std.fmt.allocPrint(aa, "{s}/bin/codex", .{rig.root});
    try cwd.createDirPath(io, std.fs.path.dirname(bin).?);
    {
        const sh = cwd.readFileAlloc(io, "/bin/sh", aa, .limited(16 * 1024 * 1024)) catch return error.SkipZigTest;
        var f = try cwd.createFile(io, bin, .{ .permissions = .fromMode(0o755) });
        defer f.close(io);
        try f.writeStreamingAll(io, sh);
    }
    const script = try std.fmt.allocPrint(aa, "exec 3>>'{s}'; sleep 30", .{rig.rollout});
    var child = std.process.spawn(io, .{
        .argv = &.{ bin, "-c", script },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    defer {
        child.kill(io);
    }
    const pid: u64 = @intCast(child.id.?);

    var req: std.Io.Writer.Allocating = .init(aa);
    // Nothing in the environment: an entry written before the marker. The
    // process is what says Codex.
    try writeIdentifyRequest(&req.writer, rig.adapter, .{ .pid = pid, .env = &.{.{ "POLTER_REGISTERED", "1.2.3" }} }, null, rig.home);
    var found: Identified = .no;
    for (0..40) |_| {
        found = try parseIdentify(aa, try askCodex(aa, io, rig, .identify, req.written()));
        if (found.session != null) break;
        try io.sleep(.fromMilliseconds(50), .awake);
    }
    try testing.expect(found.me);
    try testing.expectEqualStrings(codex_session, found.session orelse "(none)");
    try testing.expect(found.session_written_ms != null);
}

test "codex adapter: a session no process holds open is not named by its directory without the sidecar's start (tasks 1667, 1749)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rig = try codexRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    // Codex in its app-server daemon: nothing names the session but the
    // marker and the terminal's directory, and no sidecar to time. The one
    // record in the directory is not named (task 1749): before this
    // session's first turn its own record does not exist yet, so the one
    // there may be another Codex's. Naming by start is the next test's.
    const sighting: Sighting = .{ .pid = null, .env = &.{.{ "POLTER_AGENT_CLI", "codex" }} };
    var req: std.Io.Writer.Allocating = .init(aa);
    try writeIdentifyRequest(&req.writer, rig.adapter, sighting, rig.project, rig.home);
    const one = try parseIdentify(aa, try askCodex(aa, io, rig, .identify, req.written()));
    try testing.expect(one.me);
    const unnamed = one.session == null;
    try testing.expect(unnamed);

    // Another directory has none of it.
    var elsewhere: std.Io.Writer.Allocating = .init(aa);
    try writeIdentifyRequest(&elsewhere.writer, rig.adapter, sighting, rig.home, rig.home);
    const none = try parseIdentify(aa, try askCodex(aa, io, rig, .identify, elsewhere.written()));
    try testing.expect(none.session == null);

    // A second session at work in the same directory, written just now as
    // well: which one this terminal has is not known, and it is not guessed.
    const second = try std.fmt.allocPrint(aa, "{s}/home/.codex/sessions/2026/10/17/rollout-2026-10-17T02-00-00-01a1468a-e0d0-7471-be34-4b7c25283f13.jsonl", .{rig.root});
    {
        var f = try std.Io.Dir.cwd().createFile(io, second, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, try std.fmt.allocPrint(aa,
            \\{{"type":"session_meta","payload":{{"session_id":"01a1468a-e0d0-7471-be34-4b7c25283f13","cwd":"{s}","originator":"codex-tui"}}}}
            \\
        , .{rig.project}));
    }
    const two = try parseIdentify(aa, try askCodex(aa, io, rig, .identify, req.written()));
    try testing.expect(two.me);
    const unsure = two.session == null;
    try testing.expect(unsure);
}

/// A UUIDv7 whose time is `ms`, as Codex's session ids are.
fn v7(aa: Allocator, ms: u64, tail: u32) ![]const u8 {
    const hex = try std.fmt.allocPrint(aa, "{x:0>12}", .{ms});
    return std.fmt.allocPrint(aa, "{s}-{s}-7000-8000-{x:0>12}", .{ hex[0..8], hex[8..12], tail });
}

test "codex adapter: two Codex in one directory are told apart by when each started, and not guessed (task 1667)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rig = try codexRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};
    const cwd = std.Io.Dir.cwd();
    const day = try std.fmt.allocPrint(aa, "{s}/home/.codex/sessions/2026/10/18", .{rig.root});
    try cwd.createDirPath(io, day);

    // The sidecar of the Codex being asked about: started now.
    var sidecar = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    defer sidecar.kill(io);
    const now_ms: u64 = @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));

    // Measured in the test session: a role's Codex and one started by hand,
    // both in `/`, both written in the same minute. The hand-started one's
    // session started with its sidecar; the other five minutes before.
    const mine = try v7(aa, now_ms, 1);
    const other = try v7(aa, now_ms - 5 * std.time.ms_per_min, 2);
    for ([_][]const u8{ mine, other }) |sid| {
        const path = try std.fmt.allocPrint(aa, "{s}/rollout-2026-10-18T06-00-00-{s}.jsonl", .{ day, sid });
        var f = try cwd.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, try std.fmt.allocPrint(aa,
            \\{{"type":"session_meta","payload":{{"session_id":"{s}","cwd":"{s}"}}}}
            \\
        , .{ sid, rig.project }));
    }

    const sighting: Sighting = .{
        .pid = null,
        .sidecar = @intCast(sidecar.id.?),
        .env = &.{.{ "POLTER_AGENT_CLI", "codex" }},
    };
    var req: std.Io.Writer.Allocating = .init(aa);
    try writeIdentifyRequest(&req.writer, rig.adapter, sighting, rig.project, rig.home);
    const found = try parseIdentify(aa, try askCodex(aa, io, rig, .identify, req.written()));
    try testing.expect(found.me);
    try testing.expectEqualStrings(mine, found.session orelse "(none)");

    // A third that started at the same moment: no telling, so none.
    const twin = try v7(aa, now_ms + 1000, 3);
    {
        const path = try std.fmt.allocPrint(aa, "{s}/rollout-2026-10-18T06-00-01-{s}.jsonl", .{ day, twin });
        var f = try cwd.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, try std.fmt.allocPrint(aa,
            \\{{"type":"session_meta","payload":{{"session_id":"{s}","cwd":"{s}"}}}}
            \\
        , .{ twin, rig.project }));
    }
    const two = try parseIdentify(aa, try askCodex(aa, io, rig, .identify, req.written()));
    const not_guessed = two.session == null;
    try testing.expect(not_guessed);
}

test "codex adapter: what Codex's app-server daemon has open is not taken for this terminal's session (task 1667)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rig = try codexRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};

    // A stand-in for `codex app-server --listen …`: a program called
    // `codex`, `app-server` on its command line, holding open the record of
    // a session that is some other terminal's. Measured in the test session:
    // a take-over went on with exactly that.
    const cwd = std.Io.Dir.cwd();
    const bin = try std.fmt.allocPrint(aa, "{s}/bin/codex", .{rig.root});
    try cwd.createDirPath(io, std.fs.path.dirname(bin).?);
    {
        const sh = cwd.readFileAlloc(io, "/bin/sh", aa, .limited(16 * 1024 * 1024)) catch return error.SkipZigTest;
        var f = try cwd.createFile(io, bin, .{ .permissions = .fromMode(0o755) });
        defer f.close(io);
        try f.writeStreamingAll(io, sh);
    }
    const script = try std.fmt.allocPrint(aa, "exec 3>>'{s}'; sleep 30", .{rig.rollout});
    var daemon = std.process.spawn(io, .{
        .argv = &.{ bin, "-c", script, "app-server" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    defer daemon.kill(io);
    const pid: u64 = @intCast(daemon.id.?);

    var req: std.Io.Writer.Allocating = .init(aa);
    try writeIdentifyRequest(&req.writer, rig.adapter, .{ .pid = pid, .env = &.{.{ "POLTER_REGISTERED", "1.2.3" }} }, null, rig.home);
    var found: Identified = .no;
    for (0..20) |_| {
        found = try parseIdentify(aa, try askCodex(aa, io, rig, .identify, req.written()));
        if (found.me) break;
        try io.sleep(.fromMilliseconds(50), .awake);
    }
    try testing.expect(found.me);
    const not_taken = found.session == null;
    try testing.expect(not_taken);
}

/// `ms` as Codex writes `session_meta.timestamp`: `2026-10-17T07:01:38.123Z`.
fn isoOf(aa: Allocator, ms: u64) ![]const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = ms / std.time.ms_per_s };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(aa, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        day.year,               md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(),   ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        ms % std.time.ms_per_s,
    });
}

test "codex adapter: a single Codex started by hand in its own directory is recognised, by the file it holds and by its directory (task 1674)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rig = try codexRig(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, rig.root) catch {};
    const cwd = std.Io.Dir.cwd();

    // The shape measured in the test session (c1669-18): its own directory,
    // one record in it, `session_meta` written as Codex writes it, the
    // session started with the TUI and with its sidecar. The id is the one
    // measured, whose own time is hours from now: only the ISO timestamp can
    // match, which is the field Codex fills.
    const alone = try std.fmt.allocPrint(aa, "{s}/alone", .{rig.root});
    try cwd.createDirPath(io, alone);
    const sid = "01a146f3-15ea-7cf0-a720-46df485d608c";
    const now_ms: u64 = @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
    const day = try std.fmt.allocPrint(aa, "{s}/home/.codex/sessions/2026/10/17", .{rig.root});
    const rollout = try std.fmt.allocPrint(aa, "{s}/rollout-2026-10-17T07-01-38-{s}.jsonl", .{ day, sid });
    {
        var f = try cwd.createFile(io, rollout, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, try std.fmt.allocPrint(aa,
            \\{{"timestamp":"{s}","type":"session_meta","payload":{{"session_id":"{s}","id":"{s}","timestamp":"{s}","cwd":"{s}","originator":"codex-tui","cli_version":"0.163.0"}}}}
            \\{{"type":"event_msg","payload":{{"type":"task_started"}}}}
            \\
        , .{ try isoOf(aa, now_ms), sid, sid, try isoOf(aa, now_ms), alone }));
    }

    // Its sidecar, started with it.
    var sidecar = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    defer sidecar.kill(io);

    // By its directory and start alone -- no process to read, as when the
    // TUI's open files cannot be read, and as on Windows.
    {
        var req: std.Io.Writer.Allocating = .init(aa);
        try writeIdentifyRequest(&req.writer, rig.adapter, .{
            .pid = null,
            .sidecar = @intCast(sidecar.id.?),
            .env = &.{.{ "POLTER_AGENT_CLI", "codex" }},
        }, alone, rig.home);
        const found = try parseIdentify(aa, try askCodex(aa, io, rig, .identify, req.written()));
        try testing.expectEqualStrings(sid, found.session orelse "(none)");
    }

    // By the file it holds: a stand-in TUI, the program called `codex`.
    const bin = try std.fmt.allocPrint(aa, "{s}/bin/codex", .{rig.root});
    try cwd.createDirPath(io, std.fs.path.dirname(bin).?);
    {
        const sh = cwd.readFileAlloc(io, "/bin/sh", aa, .limited(16 * 1024 * 1024)) catch return error.SkipZigTest;
        var f = try cwd.createFile(io, bin, .{ .permissions = .fromMode(0o755) });
        defer f.close(io);
        try f.writeStreamingAll(io, sh);
    }
    var tui = std.process.spawn(io, .{
        .argv = &.{ bin, "-c", try std.fmt.allocPrint(aa, "exec 3>>'{s}'; sleep 30", .{rollout}), "--no-daemon" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    defer tui.kill(io);
    var req: std.Io.Writer.Allocating = .init(aa);
    try writeIdentifyRequest(&req.writer, rig.adapter, .{
        .pid = @intCast(tui.id.?),
        .sidecar = @intCast(sidecar.id.?),
        .env = &.{.{ "POLTER_AGENT_CLI", "codex" }},
    }, alone, rig.home);
    var held: Identified = .no;
    for (0..40) |_| {
        held = try parseIdentify(aa, try askCodex(aa, io, rig, .identify, req.written()));
        if (held.session != null) break;
        try io.sleep(.fromMilliseconds(50), .awake);
    }
    try testing.expectEqualStrings(sid, held.session orelse "(none)");
}

test "agent_cli survey: a plugin switched off and one nothing here can run are two answers (task 1677)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const root = try std.fmt.allocPrint(aa, "/tmp/polter-survey-{x}", .{&raw});
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const plugins = try std.fmt.allocPrint(aa, "{s}/polter/plugins", .{root});

    // An adapter this system cannot start: a `.ps1` off Windows, a `.sh`
    // on it (`Plugin.launchKindFor`).
    const foreign = if (@import("builtin").os.tag == .windows) "adapter.sh" else "adapter.ps1";
    const native = if (@import("builtin").os.tag == .windows) "adapter.ps1" else "adapter.py";
    for ([_]struct { key: []const u8, adapter: []const u8, enabled: bool }{
        .{ .key = "zz-on-cli", .adapter = native, .enabled = true },
        .{ .key = "zz-off-cli", .adapter = native, .enabled = false },
        .{ .key = "zz-odd-cli", .adapter = foreign, .enabled = true },
    }) |p| {
        const dir = try std.fmt.allocPrint(aa, "{s}/{s}", .{ plugins, p.key });
        try std.Io.Dir.cwd().createDirPath(io, dir);
        var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
        defer d.close(io);
        var m = try d.createFile(io, "plugin.json", .{});
        try m.writeStreamingAll(io, try std.fmt.allocPrint(aa,
            \\{{"key":"{s}","name":"{s}","exec":"provision.sh","agent_cli":{{"label":"L-{s}","bin":"x","adapter":"{s}"}}}}
        , .{ p.key, p.key, p.key, p.adapter }));
        m.close(io);
        var a = try d.createFile(io, p.adapter, .{});
        a.close(io);
        var pd = try std.Io.Dir.cwd().openDir(io, plugins, .{});
        defer pd.close(io);
        var s = try pd.createFile(io, try std.fmt.allocPrint(aa, "{s}.json", .{p.key}), .{});
        try s.writeStreamingAll(io, if (p.enabled) "{\"enabled\":true}" else "{\"enabled\":false}");
        s.close(io);
    }

    var env: std.process.Environ.Map = .init(aa);
    try env.put("XDG_CONFIG_HOME", root);
    try env.put("HOME", root);

    var seen: usize = 0;
    for (survey(aa, io, &env)) |f| {
        const want: Standing = if (std.mem.eql(u8, f.adapter.key, "zz-on-cli"))
            .ok
        else if (std.mem.eql(u8, f.adapter.key, "zz-off-cli"))
            .off
        else if (std.mem.eql(u8, f.adapter.key, "zz-odd-cli"))
            .cannot_run
        else
            continue;
        try testing.expectEqual(want, f.standing);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen);

    // `discover` is the ones that can start, and nothing else.
    var on: usize = 0;
    for (discover(aa, io, &env)) |a| {
        if (std.mem.startsWith(u8, a.key, "zz-")) {
            try testing.expectEqualStrings("zz-on-cli", a.key);
            on += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), on);
}

/// Milliseconds since `since`, for the tests below.
fn tookMs(io: std.Io, since: std.Io.Timestamp) i64 {
    return since.durationTo(.now(io, .awake)).toMilliseconds();
}

test "agent_cli run (1745): an adapter that writes now and then is still out of time when the time is up" {
    // `std.process.run` gave every wait for more output the whole timeout
    // again, so this one -- a byte every 100ms for four seconds -- was
    // never out of time and held the refresh for all four.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const started: std.Io.Timestamp = .now(io, .awake);
    const ran = try run(arena.allocator(), io, null, &.{
        "/bin/sh", "-c", "i=0; while [ $i -lt 40 ]; do printf x; sleep 0.1; i=$((i+1)); done",
    }, 500);
    const took = tookMs(io, started);

    try testing.expectEqual(std.meta.Tag(Ran).out_of_time, std.meta.activeTag(ran));
    try testing.expect(took < 2500);
}

/// A child that will not end by itself for half a minute.
fn neverEnds() []const []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => &.{ "ping.exe", "-n", "31", "127.0.0.1" },
        else => &.{ "/bin/sh", "-c", "sleep 30" },
    };
}

test "agent_cli run (1745): an adapter that never ends is stopped at its time, not when it ends" {
    // **The Windows half is the one that matters, and it has not been run.**
    // There 0.16's `std.process.run` waited in its reader's `deinit` for a
    // read to complete before it killed the child, so this took the full
    // thirty seconds. On POSIX the reader polls and has nothing in flight,
    // so this is green either way here.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const started: std.Io.Timestamp = .now(io, .awake);
    const ran = try run(arena.allocator(), io, null, neverEnds(), 500);
    const took = tookMs(io, started);

    try testing.expectEqual(std.meta.Tag(Ran).out_of_time, std.meta.activeTag(ran));
    try testing.expect(took < 5000);
}

test "agent_cli run (1745): a pipe somebody else still holds is cut at the time" {
    // The shape that was measured: the adapter is done in no time, and
    // something else -- there a plugin's provision, here a child of its own
    // -- keeps a copy of its stdout open for a long while after.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const argv: []const []const u8 = switch (@import("builtin").os.tag) {
        .windows => &.{ "cmd.exe", "/c", "start /b ping -n 31 127.0.0.1 & echo {}" },
        else => &.{ "/bin/sh", "-c", "sleep 10 & echo {}" },
    };

    const started: std.Io.Timestamp = .now(io, .awake);
    const ran = try run(arena.allocator(), io, null, argv, 500);
    const took = tookMs(io, started);

    try testing.expectEqual(std.meta.Tag(Ran).out_of_time, std.meta.activeTag(ran));
    try testing.expect(took < 5000);
}

test "agent_cli run (1745): an adapter is not started while another spawn holds the lock" {
    // Windows only: off it the lock is a no-op, because there `spawn` makes
    // its pipes close-on-exec. Not run on a Windows machine.
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Asker = struct {
        arena: Allocator,
        io: std.Io,
        done: std.atomic.Value(bool) = .init(false),
        ran: ?Ran = null,

        fn go(self: *@This()) void {
            self.ran = run(self.arena, self.io, null, &.{ "cmd.exe", "/c", "echo {}" }, 10_000) catch null;
            self.done.store(true, .release);
        }
    };

    internal_os.windows.lockSpawn(io);
    var asker: Asker = .{ .arena = arena.allocator(), .io = io };
    const thread = try std.Thread.spawn(.{}, Asker.go, .{&asker});

    try std.Io.sleep(io, .fromMilliseconds(500), .awake);
    const went_ahead = asker.done.load(.acquire);
    internal_os.windows.unlockSpawn(io);
    thread.join();

    try testing.expect(!went_ahead);
    try testing.expectEqual(std.meta.Tag(Ran).finished, std.meta.activeTag(asker.ran.?));
}
