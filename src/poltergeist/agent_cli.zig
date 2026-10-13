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
};

/// Every plugin on the search path that manages an agent CLI and can run
/// here, sorted by key.
///
/// The same rules as the app's own plugin scan, which is the point of
/// `Plugin.searchPath`: the user's copy of a plugin wins over the shipped
/// one, a leading `_` is not a plugin, two directories claiming one key
/// keep the first, and a plugin the user switched off offers no CLI.
///
/// Everything returned belongs to `arena`.
pub fn discover(
    arena: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) []const Adapter {
    var found: std.ArrayListUnmanaged(Adapter) = .empty;
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

            if (!Plugin.settingsFor(arena, io, environ_map, manifest.key).enabled) continue;
            if (!cli.runnable) {
                log.info(
                    "agent cli {s}: nothing on this system can run {s}",
                    .{ manifest.key, cli.adapter },
                );
                continue;
            }

            found.append(arena, .{
                .key = manifest.key,
                .label = cli.label,
                .bin = cli.bin,
                .adapter = cli.adapter,
            }) catch continue;
        }
    }

    std.mem.sortUnstable(Adapter, found.items, {}, struct {
        fn lt(_: void, a: Adapter, b: Adapter) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lt);
    return found.items;
}

pub fn find(adapters: []const Adapter, key: []const u8) ?Adapter {
    for (adapters) |a| {
        if (std.mem.eql(u8, a.key, key)) return a;
    }
    return null;
}

pub const Question = enum { inventory, launch };

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
    const ran = std.process.run(arena, io, .{
        .argv = argv,
        .environ_map = environ_map,
        .stdout_limit = .limited(max_answer),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{
            .raw = .fromMilliseconds(timeout_ms),
            .clock = .awake,
        } },
    });
    internal_os.windows.spawnTrace("agent_cli run", .end, 0);
    const result = ran catch |err| return .{ .failed = try std.fmt.allocPrint(
        arena,
        "{s} could not be run ({t})",
        .{ adapter.adapter, err },
    ) };

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

    // The role's own shape for one CLI, so the adapter reads the same
    // field names the file has. `writePersona` is the authority on those;
    // this repeats one branch of it rather than inventing a second shape.
    try w.print("{{\"skills\":{{\"default\":{},\"except\":", .{choice.skills.default});
    try writeList(w, choice.skills.except);
    try w.print("}},\"mcp\":{{\"default\":{},\"except\":", .{choice.mcp.default});
    try writeList(w, choice.mcp.except);
    try w.writeAll("},\"model\":");
    try writeOptional(w, choice.model);
    try w.writeAll(",\"args\":");
    try writeList(w, choice.args);
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
        }
        self.refreshing = false;
    }

    const Read = struct { clis: []u8, resume_keys: [][]u8 };

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
        return .{ .clis = clis, .resume_keys = try can.toOwnedSlice(alloc) };
    }
};

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

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "agent_cli: the launch request carries the role and one CLI's choices" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const p: persona.Persona = .{
        .key = "archer",
        .name = "射手",
        .instructions = "Only read.\n\"Never\" write.",
    };
    const choice: persona.CliChoice = .{
        .cli = "claude-code",
        .skills = .{ .default = false, .except = &.{"skill:pdf"} },
        .mcp = .{ .except = &.{"mcp:argus"} },
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
    const adapter: Adapter = .{ .key = "claude-code", .label = "Claude Code", .bin = "claude", .adapter = exec };

    var env = try global.environMap();
    defer env.deinit();

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
    const p: persona.Persona = .{ .key = "r", .name = "r", .instructions = "be brief" };
    const choice: persona.CliChoice = .{
        .cli = "claude-code",
        .skills = .{ .except = &.{ "skill:pdf", "skill:ops:terminal", "skill:theme", "skill:design:ux-copy", "skill:.bundled" } },
        .mcp = .{ .except = &.{ "mcp:pencil", "mcp:plugin_ops_ops", "mcp:polter" } },
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
    const adapter: Adapter = .{ .key = "claude-code", .label = "Claude Code", .bin = "claude", .adapter = exec };

    var env = try global.environMap();
    defer env.deinit();

    // A supervisor's shape: everything off by default, nothing excepted.
    const p: persona.Persona = .{ .key = "s", .name = "s" };
    const choice: persona.CliChoice = .{
        .cli = "claude-code",
        .skills = .{ .default = false },
        .mcp = .{ .default = false },
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
    try env.put("PATH", try std.fmt.allocPrint(aa, "{s}:{s}", .{ bin, env.get("PATH") orelse "" }));

    const p: persona.Persona = .{ .key = "r", .name = "r" };
    const choice: persona.CliChoice = .{
        .cli = "claude-code",
        .skills = .{ .except = &.{"skill:pdf"} },
        .args = cell.args,
    };
    var req: std.Io.Writer.Allocating = .init(aa);
    try writeLaunchRequest(&req.writer, p, choice, null, rig.home, cell.polter, cell.session);
    const adapter: Adapter = .{ .key = "claude-code", .label = "Claude Code", .bin = "claude", .adapter = rig.exec };
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

/// The six hooks, each running `<polter> +hook --cli claude-code <event>` in
/// exec form: `command` is the executable itself and `args` the rest, so no
/// shell reads it (#888 -- on Windows without Git Bash that shell is
/// PowerShell, and the sh-quoted string was a parse error there).
fn expectAllHooks(settings: std.json.ObjectMap, polter: []const u8) !void {
    const hooks = (settings.get("hooks") orelse return error.TestExpectedHooks).object;
    for ([_][]const u8{ "SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "PermissionRequest", "Notification" }) |event| {
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

test "agent_cli hooks: 2.1.145 gets all six in the one --settings, beside the skill switch" {
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
    const adapter: Adapter = .{ .key = "claude-code", .label = "Claude Code", .bin = "claude", .adapter = rig.exec };
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
