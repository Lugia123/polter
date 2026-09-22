//! Where the personas the user wrote live, and what each terminal is
//! currently wearing.
//!
//! `persona.zig` is the pure half -- the file format, the rules, the
//! effective set. This is the half that touches a disk and a clock: it
//! reads `personas.json`, keeps the parsed result, and holds one
//! `persona.State` per terminal.
//!
//! **One writer.** `put` and `remove` are the only code in Polter that
//! writes `personas.json`, and both go the same way: build the new set,
//! write it whole to a temporary file, rename it into place, then read it
//! back through `load` -- the same parser a hand-edited file goes through.
//! So nothing can reach the file that the reader would refuse, and what the
//! terminals are wearing afterwards is what the file says, not what the
//! writer meant.
//!
//! This file used to have no write path at all, on purpose: roles.md §7
//! kept roles a closed set only the user could define. The user decided
//! the supervisor gets the same powers over roles as they have (roles.md
//! part eleven), so the window and the `role_*` tools both come here.

const PersonaStore = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const persona = @import("persona.zig");
const Bus = @import("Bus.zig");
const global = @import("../global.zig");
const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.poltergeist);

alloc: Allocator,

/// Owns everything `set` points at. Replaced wholesale on a successful
/// load, so a half-parsed file can never be half-installed.
arena: ?std.heap.ArenaAllocator = null,

/// What the file said, last time it said something we could use.
set: persona.Set = .{},

/// Whether a load has ever succeeded.
///
/// ⚠️ **Not derivable from `set.personas.len == 0`.** "The user has no
/// personas" and "nobody has read the file yet" are different answers and
/// the interface has to tell them apart -- one is a finished question, the
/// other is a spinner. Collapsing them is the same mistake as drawing an
/// empty list for a scan that has not run.
loaded: bool = false,

/// Why the last load failed, in words for the person, or null.
///
/// Kept alongside `set` rather than instead of it: a file that stops
/// parsing leaves the previous personas working, and the user is told. The
/// alternative -- dropping to zero personas on a typo -- looks exactly like
/// "you have not defined any", which is a sentence the menu already has.
load_error: ?[]const u8 = null,

/// The keys and names again, NUL-terminated, for the C surface.
///
/// A second copy rather than a conversion at call time, and the reason is
/// ownership: the parsed strings point into the JSON text, which is not
/// NUL-terminated, and a caller reading a `const char*` has no length to
/// stop at. These live in the same arena as the set, so they are replaced
/// and freed together and cannot outlive what they describe.
names: []const NamePair = &.{},

/// One entry per terminal that has ever been given a persona or amended.
///
/// **Keyed by `Bus.Id`**, which is a fresh random `u64` per surface and
/// never recycled, so an entry cannot come to describe a different terminal
/// than the one it was made for.
states: std.AutoHashMapUnmanaged(Bus.Id, persona.State) = .empty,

/// Which role and CLI each terminal was started in (`persona.Launch`).
///
/// **Separate from `states`**, because the two move independently: a role
/// put on hot changes `states` and not this, and a relaunch changes this.
/// Each entry owns its copy in an arena of its own, so a library edit that
/// replaces `arena` cannot pull the strings out from under it.
launches: std.AutoHashMapUnmanaged(Bus.Id, Launched) = .empty,

/// A role's Polter half (`persona.Polter`) waiting for the agent it was
/// started for, one per terminal. See `holdStanding`.
///
/// Plain values, nothing borrowed, so a library edit cannot pull anything
/// out from under it. Cleared by `forget` with the rest.
standings: std.AutoHashMapUnmanaged(Bus.Id, PendingStanding) = .empty,

pub const NamePair = struct {
    key: [:0]const u8,
    name: [:0]const u8,
};

const Launched = struct {
    arena: std.heap.ArenaAllocator,
    launch: persona.Launch,
};

pub const PendingStanding = struct {
    want: persona.Polter,
    /// The terminal the launch was asked from (`App.startRoleIn`).
    by: Bus.Id,
    /// Past this, whatever connects from that terminal is not the agent the
    /// launch started, and nothing is applied.
    deadline_ms: u64,
};

/// How long a launched agent has to connect before its standing is dropped.
///
/// Starting a CLI and its MCP sidecar takes seconds, more on a cold Windows
/// machine; a `claude` somebody types into the same terminal by hand minutes
/// later must not inherit a supervisor's standing. A minute sits between the
/// two. `pending_launch_ms` in `App.zig` is the same idea for the tab.
pub const standing_wait_ms: u64 = 60_000;

pub fn deinit(self: *PersonaStore) void {
    if (self.arena) |*a| a.deinit();
    if (self.load_error) |e| self.alloc.free(e);
    self.states.deinit(self.alloc);
    var it = self.launches.valueIterator();
    while (it.next()) |l| l.arena.deinit();
    self.launches.deinit(self.alloc);
    self.standings.deinit(self.alloc);
    self.* = undefined;
}

/// Where `personas.json` lives. Caller frees.
///
/// Beside `config.polter`, because that is the directory the user already
/// knows as Polter's. On macOS the config file is looked for in Application
/// Support first and then XDG, and this follows it rather than inventing a
/// second rule -- two files that are meant to sit together and are looked
/// for in different places is a support question nobody can answer from the
/// outside.
pub fn defaultPath(alloc: Allocator) ![]const u8 {
    if (comptime builtin.os.tag == .macos) {
        if (internal_os.macos.appSupportDir(alloc, "personas.json")) |p| {
            return p;
        } else |_| {}
    }

    var environ_map = try global.environMap();
    defer environ_map.deinit();
    return try internal_os.xdg.config(
        global.io(),
        alloc,
        &environ_map,
        .{ .subdir = "polter/personas.json" },
    );
}

/// Longest `personas.json` we will read. A persona file is a handful of
/// declarations; anything past this is a mistake or a different file, and
/// reading it into memory helps nobody.
pub const max_bytes = 256 * 1024;

/// Read the file at `path` and install it if it parses.
///
/// **A file that does not parse changes nothing except `load_error`.** Not
/// tidiness: a partially loaded persona table looks exactly like a complete
/// one, so there is no safe amount of it to keep.
///
/// A missing file is not an error. It is the ordinary state for somebody
/// who has never written one, and reporting it would put a red message in
/// front of every user who does not use personas.
pub fn load(self: *PersonaStore, io: std.Io, path: []const u8) void {
    const bytes = readAll(self.alloc, io, path) catch |err| switch (err) {
        error.FileNotFound => {
            // Nothing there, and nothing wrong. What is left is the roles
            // Polter ships, which every reader adds whether or not there is
            // a file -- `+launch` in its own process included.
            var arena: std.heap.ArenaAllocator = .init(self.alloc);
            self.install(&arena, persona.builtinSet(), path) catch arena.deinit();
            return;
        },
        else => {
            self.keepBuiltinsOnly(path);
            self.setErrorFmt("could not read {s}: {t}", .{ path, err });
            return;
        },
    };
    defer self.alloc.free(bytes);

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    errdefer arena.deinit();

    const set = persona.parseLeaky(arena.allocator(), bytes) catch |err| {
        // The sentence names the file and what was wrong with it, because
        // the person reading it is looking at a menu that did not change
        // and has to be told where to go.
        arena.deinit();
        self.keepBuiltinsOnly(path);
        self.setErrorFmt("{s} was not loaded: {t}", .{ path, err });
        return;
    };

    self.install(&arena, set, path) catch {
        arena.deinit();
        return;
    };

    if (set.ignored_denies.len > 0) {
        // Not an error -- the file loaded -- but the user asked for
        // something that did not happen, and an instruction silently
        // ignored is indistinguishable from one that was honoured.
        log.warn(
            "poltergeist: {d} tool(s) in personas.json cannot be denied and were kept",
            .{set.ignored_denies.len},
        );
    }
}

/// After a read that failed: when there is no earlier good set to keep, the
/// roles Polter ships, so they are there however the file is broken.
///
/// **Only when there is nothing to keep.** A later bad file leaves the last
/// good set in place, and that set has the built-ins in it already. It is
/// the *first* read failing that used to leave nothing at all -- measured
/// on the Windows machine: the list came up empty, "Polter Supervisor"
/// included, because the file the user was halfway through did not parse.
/// Called before the error is set, because installing clears it.
fn keepBuiltinsOnly(self: *PersonaStore, path: []const u8) void {
    if (self.loaded) return;
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    self.install(&arena, persona.builtinSet(), path) catch arena.deinit();
}

/// Make `set`, which lives in `arena`, the one in use. On failure nothing
/// changed and the arena is still the caller's.
fn install(self: *PersonaStore, arena: *std.heap.ArenaAllocator, set: persona.Set, path: []const u8) error{OutOfMemory}!void {
    // The C-facing copies, built while the arena is still ours to fail in.
    const aa = arena.allocator();
    const names = aa.alloc(NamePair, set.personas.len) catch {
        self.setErrorFmt("out of memory reading {s}", .{path});
        return error.OutOfMemory;
    };
    for (set.personas, 0..) |p, i| {
        names[i] = .{
            .key = aa.dupeZ(u8, p.key) catch {
                self.setErrorFmt("out of memory reading {s}", .{path});
                return error.OutOfMemory;
            },
            .name = aa.dupeZ(u8, p.name) catch {
                self.setErrorFmt("out of memory reading {s}", .{path});
                return error.OutOfMemory;
            },
        };
    }

    // Only now, with a whole good set in hand, is the old one dropped.
    var old = self.arena;
    self.arena = arena.*;
    self.set = set;
    self.names = names;
    self.loaded = true;
    self.setError(null);

    // ⚠️ **Before the old arena goes.** Every terminal's state borrows its
    // key and its face from the set it was given, so freeing the arena
    // under them leaves each one pointing at freed memory -- silently,
    // until the next tab refresh reads a key. That could not happen while
    // the file was read once per run; it happens on every edit now.
    self.rebindStates();
    if (old) |*a| a.deinit();
}

/// Point every terminal's state at the set that was just installed.
///
/// A terminal wearing a role that still exists is put back into it -- the
/// role was edited, and what it is wearing should be the edit, which also
/// bumps its roster so a waiting agent hears about it. One wearing a role
/// that is gone is taken out of it, rather than left claiming a name the
/// menu no longer has.
fn rebindStates(self: *PersonaStore) void {
    var it = self.states.valueIterator();
    while (it.next()) |state| {
        const key = state.key orelse {
            state.effective = .{};
            continue;
        };
        if (self.set.find(key)) |p| state.setPersona(p) else state.clear();
    }
}

pub const WriteError = error{
    /// The file on disk does not parse right now. Writing would replace
    /// whatever the user was halfway through with our copy of the last
    /// good one, so it is refused until they fix it or delete it.
    FileUnreadable,

    /// The role sent does not pass the same rules as the file.
    BadPersona,

    NoSuchPersona,

    /// The key is a role Polter ships (`persona.builtins`). Those are
    /// neither replaced nor deleted; a copy under another key can be.
    BuiltinPersona,

    /// A supervisor tried to change what only the user may set in a role
    /// (`persona.Polter.userOnlyEql`).
    NotPermitted,

    /// Written, and then reading it back failed. Should not happen -- the
    /// writer and the reader are one pair -- and is said rather than
    /// assumed because it is the one outcome that means a bug here.
    WriteNotLoaded,

    CouldNotWrite,
    OutOfMemory,
};

/// Add a role, or replace the one with the same key where it stands.
///
/// `json` is one persona object, in the shape the file uses for one.
///
/// `who` is who is writing. The user -- the library window -- may set
/// anything. A supervisor may not change the three settings that grant a
/// terminal something (`persona.Polter`): its write has to leave them as
/// they are, which for a new role is off. Refused whole rather than quietly
/// kept, so that what the supervisor reads back is what it sent.
pub fn put(self: *PersonaStore, io: std.Io, path: []const u8, json: []const u8, who: Bus.Authority) WriteError!void {
    if (self.load_error != null) return error.FileUnreadable;

    var scratch: std.heap.ArenaAllocator = .init(self.alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const p = persona.parsePersonaLeaky(sa, json) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ReservedKey => error.BuiltinPersona,
        else => error.BadPersona,
    };
    if (who != .user) {
        const before: persona.Polter = if (self.set.find(p.key)) |q| q.polter else .{};
        if (!persona.Polter.userOnlyEql(before, p.polter)) return error.NotPermitted;
    }
    const set = try persona.withPersona(sa, self.set, p);
    try self.commit(io, path, set);
}

/// Delete a role. Terminals wearing it are taken out of it.
pub fn remove(self: *PersonaStore, io: std.Io, path: []const u8, key: []const u8) WriteError!void {
    if (self.load_error != null) return error.FileUnreadable;
    if (persona.isBuiltinKey(key)) return error.BuiltinPersona;

    var scratch: std.heap.ArenaAllocator = .init(self.alloc);
    defer scratch.deinit();
    const set = (try persona.withoutPersona(scratch.allocator(), self.set, key)) orelse
        return error.NoSuchPersona;
    try self.commit(io, path, set);
}

fn commit(self: *PersonaStore, io: std.Io, path: []const u8, set: persona.Set) WriteError!void {
    var out: std.Io.Writer.Allocating = .init(self.alloc);
    defer out.deinit();
    persona.writeSet(&out.writer, set) catch return error.OutOfMemory;

    writeReplacing(self.alloc, io, path, out.written()) catch |err| {
        log.warn("poltergeist: could not write {s}: {t}", .{ path, err });
        return error.CouldNotWrite;
    };

    self.load(io, path);
    if (self.load_error != null) return error.WriteNotLoaded;
}

/// Write `bytes` to `path` by way of a temporary file beside it, so a
/// reader -- or a crash -- never sees half a file.
fn writeReplacing(alloc: Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const tmp = try std.fmt.allocPrint(alloc, "{s}.{x}.tmp", .{ path, &raw });
    defer alloc.free(tmp);

    {
        var f = try cwd.createFile(io, tmp, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
    }
    cwd.rename(tmp, cwd, path, io) catch |err| {
        cwd.deleteFile(io, tmp) catch {};
        return err;
    };
}

/// Every role in full, as the library window and `role_list` read them.
///
/// `loaded` and `error` ride along for the reason `writeFaceJson` gives
/// them: an empty list, a file nobody has read yet and a file that did not
/// parse are three different things to tell a person.
pub fn writeCatalogJson(self: *const PersonaStore, w: *std.Io.Writer, path: ?[]const u8) !void {
    try w.print("{{\"loaded\":{},\"error\":", .{self.loaded});
    if (self.load_error) |e| try w.print("{f}", .{std.json.fmt(e, .{})}) else try w.writeAll("null");
    try w.writeAll(",\"path\":");
    if (path) |p| try w.print("{f}", .{std.json.fmt(p, .{})}) else try w.writeAll("null");
    try w.writeAll(",\"personas\":[");
    for (self.set.personas, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try persona.writePersona(w, p);
    }
    try w.writeAll("]}");
}

fn readAll(alloc: Allocator, io: std.Io, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_bytes));
}

fn setError(self: *PersonaStore, text: ?[]const u8) void {
    if (self.load_error) |e| self.alloc.free(e);
    self.load_error = text;
}

fn setErrorFmt(self: *PersonaStore, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(self.alloc, fmt, args) catch null;
    self.setError(text);
    if (text) |t| log.warn("poltergeist: {s}", .{t});
}

/// This terminal's state, or the default one. Never fails: a terminal that
/// has never been given a persona is wearing the default face, which is
/// everything -- what Polter does with no personas at all.
pub fn stateOf(self: *const PersonaStore, id: Bus.Id) persona.State {
    return self.states.get(id) orelse .{};
}

/// Put a terminal into a persona.
pub fn setPersona(self: *PersonaStore, id: Bus.Id, key: []const u8) !void {
    const p = self.set.find(key) orelse return error.NoSuchPersona;
    const gop = try self.states.getOrPut(self.alloc, id);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    gop.value_ptr.setPersona(p);
}

/// Take a terminal out of any persona.
pub fn clearPersona(self: *PersonaStore, id: Bus.Id) !void {
    const gop = try self.states.getOrPut(self.alloc, id);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    gop.value_ptr.clear();
}

/// Forget a terminal. Called when a surface goes.
pub fn forget(self: *PersonaStore, id: Bus.Id) void {
    _ = self.states.remove(id);
    _ = self.standings.remove(id);
    if (self.launches.fetchRemove(id)) |kv| {
        var a = kv.value.arena;
        a.deinit();
    }
}

/// Whether a role's Polter half gives the terminal anything. `open` is
/// about where the role starts, not what the terminal becomes.
fn grantsStanding(want: persona.Polter) bool {
    return want.supervisor or want.may_authorise or want.shielded or
        want.watch or want.quiet_ms != null;
}

/// Hold `want` for the agent a launch is about to start in `id`.
///
/// **Held, not applied.** It used to be applied here, before the launch
/// line was even typed -- and measured on the Windows machine, a `+launch`
/// whose adapter would not start left a terminal that was a supervisor
/// with no agent in it. The standing is for the agent, so it waits for the
/// agent: `claimStanding`, on the first request from that terminal.
///
/// Replaces whatever was held for `id` before; a role with nothing to give
/// clears it, so an older launch's standing cannot outlive a newer launch.
pub fn holdStanding(
    self: *PersonaStore,
    id: Bus.Id,
    by: Bus.Id,
    want: persona.Polter,
    now_ms: u64,
) Allocator.Error!void {
    if (!grantsStanding(want)) {
        _ = self.standings.remove(id);
        return;
    }
    try self.standings.put(self.alloc, id, .{
        .want = want,
        .by = by,
        .deadline_ms = now_ms + standing_wait_ms,
    });
}

/// What is held for `id` and still able to be claimed, or null.
pub fn heldStanding(self: *const PersonaStore, id: Bus.Id, now_ms: u64) ?PendingStanding {
    const s = self.standings.get(id) orelse return null;
    if (now_ms > s.deadline_ms) return null;
    return s;
}

/// What `claimStanding` did, for the parts of it that are the app's to
/// show: the tab's watching mark and its quiet threshold live on the
/// surface, not on the bus.
pub const Applied = struct {
    want: persona.Polter,
    /// Who it was handed to, when `watch` found somebody.
    watched_by: ?Bus.Id,
};

/// A request has arrived from `id`: if a launch is holding a standing for
/// it, apply it to `bus` now, once, and say what was applied.
///
/// **Called before that request is answered** (`rpc.arrived`), so the
/// agent's first `me` already reads the standing it was started with.
/// Taken either way -- an expired one is dropped rather than left for the
/// next thing that connects.
///
/// As the user: the role is theirs, and a supervisor cannot have written
/// the three settings that grant something (`put`).
pub fn claimStanding(self: *PersonaStore, bus: *Bus, id: Bus.Id, now_ms: u64) ?Applied {
    const held = self.standings.fetchRemove(id) orelse return null;
    const s = held.value;
    if (now_ms > s.deadline_ms) {
        log.info("poltergeist: a role's standing for this terminal ran out before its agent connected; not applying it", .{});
        return null;
    }
    const want = s.want;

    if (want.supervisor) {
        bus.addSupervisor(id) catch |err| {
            log.warn("poltergeist: role could not make terminal a supervisor err={}", .{err});
        };
        log.info("poltergeist: the agent started in a supervisor role connected, so this terminal is a supervisor", .{});
    }

    bus.register(id) catch {};
    if (want.may_authorise) bus.setMayAuthorise(id, true, .user) catch {};
    if (want.shielded) bus.setShielded(id, true, .user) catch {};

    // Shielded wins: a terminal nothing may reach is not one to be told
    // about (`Bus.setShielded`). And a supervisor is not watched.
    var watched_by: ?Bus.Id = null;
    if (want.watch and !want.shielded and !want.supervisor) {
        if (roleWatcher(bus, s.by, id)) |boss| {
            if (bus.watch(id, boss)) {
                watched_by = boss;
            } else |err| {
                log.warn("poltergeist: role could not hand terminal to its supervisor err={}", .{err});
            }
        } else {
            log.info("poltergeist: role asked to be watched but there is no one supervisor to watch it", .{});
        }
    }
    return .{ .want = want, .watched_by = watched_by };
}

/// Who minds a terminal a role says should be watched: the supervisor that
/// started it, or -- when a person started it from a terminal that is not
/// one -- the only supervisor there is. Null with none, or with several:
/// which of two supervisors a terminal belongs to is not the program's to
/// guess (the same reason `Bus.removeSupervisor` releases rather than
/// hands on).
fn roleWatcher(bus: *const Bus, by: Bus.Id, id: Bus.Id) ?Bus.Id {
    if (by != id and bus.isSupervisor(by)) return by;
    var found: ?Bus.Id = null;
    var it = bus.entries.iterator();
    while (it.next()) |kv| {
        if (kv.key_ptr.* == id or kv.value_ptr.role != .supervisor) continue;
        if (found != null) return null;
        found = kv.key_ptr.*;
    }
    return found;
}

/// Record that `id` was started in role `key` with the CLI `choice`, and
/// forget whatever it was started in before. Copies both.
pub fn noteLaunch(self: *PersonaStore, id: Bus.Id, key: []const u8, choice: persona.CliChoice) Allocator.Error!void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const launch: persona.Launch = .{
        .role = try aa.dupe(u8, key),
        .choice = .{
            .cli = try aa.dupe(u8, choice.cli),
            .skills = try dupeSelection(aa, choice.skills),
            .mcp = try dupeSelection(aa, choice.mcp),
            .model = if (choice.model) |m| try aa.dupe(u8, m) else null,
            .args = try dupeList(aa, choice.args),
        },
    };

    const gop = try self.launches.getOrPut(self.alloc, id);
    if (gop.found_existing) gop.value_ptr.arena.deinit();
    gop.value_ptr.* = .{ .arena = arena, .launch = launch };
}

/// What `id` was started in, or null when it was not started from a role.
pub fn launchOf(self: *const PersonaStore, id: Bus.Id) ?persona.Launch {
    const l = self.launches.getPtr(id) orelse return null;
    return l.launch;
}

fn dupeSelection(aa: Allocator, s: persona.Selection) Allocator.Error!persona.Selection {
    return .{ .default = s.default, .except = try dupeList(aa, s.except) };
}

fn dupeList(aa: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try aa.alloc([]const u8, list.len);
    for (list, 0..) |s, i| out[i] = try aa.dupe(u8, s);
    return out;
}

/// The role half of `terminal_capabilities` for `id`, in `aa`.
///
/// `clis_json` is `agent_cli.Cache.snapshot`'s document. The split of a
/// CLI's skills and servers into kept and off is worked out against it
/// **now**, with the selection recorded **at launch** -- the same rule the
/// adapter applied when it built the command line (`enabled` in
/// `adapter.py`, `locked` always kept). A cache nobody has read yet is said
/// to be `stale`; it is never answered as an empty split.
pub fn capabilities(
    self: *const PersonaStore,
    aa: Allocator,
    id: Bus.Id,
    clis_json: []const u8,
    now_ms: u64,
) Allocator.Error!persona.Capabilities {
    const state = self.stateOf(id);
    const role: ?persona.Capabilities.Role = if (state.key) |k| blk: {
        const p = self.set.find(k);
        break :blk .{
            .key = k,
            .name = if (p) |q| q.name else null,
            .deviated = state.deviated(self.set),
            .builtin = if (p) |q| q.builtin else false,
        };
    } else null;

    const launch = self.launchOf(id);
    const started: persona.Capabilities.Started = if (launch != null)
        .launched
    else if (state.key != null)
        .worn_hot
    else
        .none;

    return .{
        .role = role,
        .started = started,
        .cli = if (launch) |l| try cliView(aa, l, clis_json) else null,
        .unfiltered = state.key == null,
        .skills = state.effective.skills,
        .slots = state.effective.slots,
        .epoch = state.epoch,
        .pending_standing = if (self.heldStanding(id, now_ms)) |s| .{
            .want = s.want,
            .expires_in_ms = s.deadline_ms - now_ms,
        } else null,
    };
}

fn cliView(aa: Allocator, l: persona.Launch, clis_json: []const u8) Allocator.Error!persona.Capabilities.Cli {
    var out: persona.Capabilities.Cli = .{
        .key = l.choice.cli,
        .role = l.role,
        .model = l.choice.model,
        .args = l.choice.args,
        .inventory = .failed,
        .refreshing = false,
        .@"error" = "the list of agent CLIs could not be read",
        .skills = null,
        .mcp = null,
    };

    const doc = std.json.parseFromSliceLeaky(std.json.Value, aa, clis_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return out,
    };
    if (doc != .object) return out;
    if (doc.object.get("refreshing")) |r| out.refreshing = r == .bool and r.bool;
    if (doc.object.get("stale")) |s| if (s == .bool and s.bool) {
        out.inventory = .stale;
        out.@"error" = null;
        return out;
    };

    const clis = doc.object.get("clis") orelse return out;
    if (clis != .array) return out;
    const entry = for (clis.array.items) |c| {
        if (c != .object) continue;
        const k = c.object.get("key") orelse continue;
        if (k == .string and std.mem.eql(u8, k.string, l.choice.cli)) break c.object;
    } else {
        out.inventory = .absent;
        out.@"error" = null;
        return out;
    };

    if (entry.get("error")) |e| if (e == .string) {
        out.@"error" = e.string;
        return out;
    };
    const inv = entry.get("inventory") orelse return out;
    if (inv != .object) return out;
    const items = inv.object.get("items") orelse return out;
    if (items != .array) return out;

    var skills_kept: std.ArrayListUnmanaged([]const u8) = .empty;
    var skills_off: std.ArrayListUnmanaged([]const u8) = .empty;
    var mcp_kept: std.ArrayListUnmanaged([]const u8) = .empty;
    var mcp_off: std.ArrayListUnmanaged([]const u8) = .empty;
    for (items.array.items) |item| {
        if (item != .object) continue;
        const item_id = switch (item.object.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const kind = switch (item.object.get("kind") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const locked = if (item.object.get("locked")) |v| v == .bool and v.bool else false;

        const is_skill = std.mem.eql(u8, kind, "skill");
        if (!is_skill and !std.mem.eql(u8, kind, "mcp")) continue;
        const sel = if (is_skill) l.choice.skills else l.choice.mcp;
        const kept = locked or sel.enabled(item_id);
        const list = if (is_skill)
            (if (kept) &skills_kept else &skills_off)
        else
            (if (kept) &mcp_kept else &mcp_off);
        try list.append(aa, item_id);
    }

    out.inventory = .ok;
    out.@"error" = null;
    out.skills = .{ .kept = skills_kept.items, .off = skills_off.items };
    out.mcp = .{ .kept = mcp_kept.items, .off = mcp_off.items };
    return out;
}

/// The NUL-terminated key and name for a persona, for the C surface.
///
/// Null when no such key is defined -- which happens when `personas.json`
/// was edited to remove one a terminal is still wearing. The terminal keeps
/// the key it was given; what it loses is a name to show, and the interface
/// is told that by getting nothing rather than by getting an empty string.
pub fn cName(self: *const PersonaStore, key: []const u8) ?NamePair {
    for (self.names) |pair| {
        if (std.mem.eql(u8, pair.key, key)) return pair;
    }
    return null;
}

/// Write this terminal's effective set as the JSON the interface reads.
///
/// **One writer, one shape.** The C query and the MCP method both come
/// through here, so an apprt and an agent cannot be told two different
/// stories about the same terminal -- which is the failure mode the whole
/// "two readers, two sets of rules" argument in the contract is about.
///
/// `tools` is deliberately absent: this version of the editor does not edit
/// the tool face, and a field nothing reads is a field that goes stale
/// without anybody noticing. The MCP side asks for the tool names with its
/// own method, where they are the whole point.
pub fn writeFaceJson(
    self: *const PersonaStore,
    w: *std.Io.Writer,
    id: Bus.Id,
    agent_present: bool,
) !void {
    const state = self.stateOf(id);
    const chosen: ?persona.Persona = if (state.key) |k| self.set.find(k) else null;

    try w.writeAll("{\"key\":");
    if (state.key) |k| try w.print("{f}", .{std.json.fmt(k, .{})}) else try w.writeAll("null");
    try w.writeAll(",\"name\":");
    if (chosen) |p| try w.print("{f}", .{std.json.fmt(p.name, .{})}) else try w.writeAll("null");

    try w.print(
        ",\"deviated\":{},\"epoch\":{d},\"roster\":{d},\"agent_present\":{}",
        .{ state.deviated(self.set), state.epoch, state.roster, agent_present },
    );

    // `host_class` is `unknown` until `clientInfo.name` is read off the
    // agent's `initialize` and mapped. Reporting anything else would be an
    // inference formatted as a reading, and the one it would be mistaken
    // for -- `hot` -- is the one that makes "not yet in effect" look like
    // "already in effect".
    try w.writeAll(",\"host_class\":\"unknown\"");

    try w.writeAll(",\"prompt\":");
    if (state.effective.prompt) |p| {
        try w.print("{f}", .{std.json.fmt(p, .{})});
    } else try w.writeAll("null");

    try w.writeAll(",\"skills\":[");
    for (state.effective.skills, 0..) |name, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(
            "{{\"id\":\"{d}-{d}\",\"name\":{f},\"enabled\":true,\"in_persona\":{}}}",
            .{ state.roster, i, std.json.fmt(name, .{}), inList(chosen, .skill, name) },
        );
    }

    try w.writeAll("],\"mcp\":[");
    for (state.effective.slots, 0..) |name, i| {
        if (i > 0) try w.writeAll(",");
        // `slot` is `withheld` here because nothing has started a slot
        // process yet. It is a real state, not a placeholder -- and it is
        // the one that must never be confused with `broken`, which is why
        // it is written out rather than left to a default on the far side.
        try w.print(
            "{{\"id\":\"{d}-{d}\",\"name\":{f},\"enabled\":true," ++
                "\"in_persona\":{},\"slot\":\"withheld\"}}",
            .{ state.roster, i, std.json.fmt(name, .{}), inList(chosen, .mcp, name) },
        );
    }
    try w.writeAll("]");

    try w.writeAll(",\"error\":");
    if (self.load_error) |e| try w.print("{f}", .{std.json.fmt(e, .{})}) else try w.writeAll("null");
    try w.writeAll(",\"error_kind\":");
    if (self.load_error != null) try w.writeAll("\"parse\"") else try w.writeAll("null");

    // Whether anybody has read the file at all. An interface that draws an
    // empty list for this is telling the user they have no personas, when
    // the truth is that nothing has looked yet.
    try w.print(",\"stale\":{}", .{!self.loaded});

    try w.writeAll("}");
}

const Which = enum { skill, mcp };

fn inList(chosen: ?persona.Persona, which: Which, name: []const u8) bool {
    const p = chosen orelse return false;
    const list = switch (which) {
        .skill => p.skills,
        .mcp => p.mcp,
    };
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Whether this terminal may see the tool called `name`.
pub fn toolVisible(self: *const PersonaStore, id: Bus.Id, name: []const u8) bool {
    return persona.toolVisible(self.stateOf(id).effective.tools, name);
}

// ----------------------------------------------------------------- tests

const testing = std.testing;

fn tmpDir(alloc: Allocator, io: std.Io) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-personas-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

test "personas: a bad file on the first read still leaves the built-in roles" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try std.fmt.allocPrint(aa, "{s}/personas.json", .{dir});

    var store: PersonaStore = .{ .alloc = testing.allocator };
    defer store.deinit();

    // The first thing this process ever reads does not parse. There is no
    // earlier set to keep -- and the roles Polter ships are there anyway,
    // with the error said.
    try write(io, path, "{\"version\":1,\"personas\":[{\"key\":\"a\"");
    store.load(io, path);
    try testing.expect(store.loaded);
    try testing.expect(store.load_error != null);
    try testing.expect(store.set.find(persona.supervisor_key) != null);
    try testing.expectEqual(persona.builtins.len, store.set.personas.len);

    // Still refused as a write target: the file on disk is the user's
    // half-finished one, and writing would replace it.
    try testing.expectError(error.FileUnreadable, store.remove(io, path, "a"));
}

test "personas: a good file loads, and a later bad one does not take it away" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try std.fmt.allocPrint(aa, "{s}/personas.json", .{dir});

    var store: PersonaStore = .{ .alloc = testing.allocator };
    defer store.deinit();

    // Nothing there yet: looked, found nothing, and that is not an error.
    store.load(io, path);
    try testing.expect(store.loaded);
    try testing.expectEqual(@as(?[]const u8, null), store.load_error);
    try testing.expectEqual(persona.builtins.len + 0, store.set.personas.len);

    try write(io, path,
        \\{"version":1,"personas":[{"key":"archer","name":"Archer",
        \\  "tools":{"deny":["notify_user"]}}]}
    );
    store.load(io, path);
    try testing.expectEqual(persona.builtins.len + 1, store.set.personas.len);
    try testing.expectEqual(@as(?[]const u8, null), store.load_error);

    // **The assertion this test exists for.** A typo must not silently
    // empty the menu: dropping to zero personas is indistinguishable from
    // "you have not defined any", which is a sentence the interface already
    // uses for something else.
    try write(io, path, "{\"version\":1,\"personas\":[{\"key\":\"a\"");
    store.load(io, path);
    try testing.expectEqual(persona.builtins.len + 1, store.set.personas.len);
    try testing.expectEqualStrings("Archer", store.set.personas[persona.builtins.len + 0].name);
    try testing.expect(store.load_error != null);
    try testing.expect(std.mem.indexOf(u8, store.load_error.?, "personas.json") != null);
}

fn write(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

test "personas: a terminal that was never given one is wearing everything" {
    var store: PersonaStore = .{ .alloc = testing.allocator };
    defer store.deinit();

    const id: Bus.Id = 0xabc;
    try testing.expect(store.toolVisible(id, "notify_user"));
    try testing.expect(store.toolVisible(id, "terminal_read"));
    try testing.expectEqual(@as(?[]const u8, null), store.stateOf(id).key);
}

test "personas: setting one changes that terminal and no other" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try std.fmt.allocPrint(aa, "{s}/personas.json", .{dir});
    try write(io, path,
        \\{"version":1,"personas":[{"key":"archer","name":"Archer",
        \\  "tools":{"deny":["notify_user"]}}]}
    );

    var store: PersonaStore = .{ .alloc = testing.allocator };
    defer store.deinit();
    store.load(io, path);

    const wearing: Bus.Id = 0x111;
    const bare: Bus.Id = 0x222;
    try store.setPersona(wearing, "archer");

    // **Per terminal, which is the whole claim of the feature.** The tool
    // surface is the one thing Polter can vary per terminal -- skills are
    // files and files are global -- so if this ever became global the
    // feature would be answering a different question than the one asked.
    try testing.expect(!store.toolVisible(wearing, "notify_user"));
    try testing.expect(store.toolVisible(bare, "notify_user"));

    try testing.expectEqualStrings("archer", store.stateOf(wearing).key.?);
    try testing.expectEqual(@as(?[]const u8, null), store.stateOf(bare).key);

    try testing.expectError(error.NoSuchPersona, store.setPersona(wearing, "nobody"));

    try store.clearPersona(wearing);
    try testing.expect(store.toolVisible(wearing, "notify_user"));

    // Forgetting a terminal is not the same as clearing it, but from the
    // outside a forgotten terminal is a terminal wearing nothing -- which
    // is correct, because the id is never reused.
    store.forget(wearing);
    try testing.expectEqual(@as(?[]const u8, null), store.stateOf(wearing).key);
}

test "personas: the face says which rows came from the persona and which were added by hand" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try std.fmt.allocPrint(aa, "{s}/personas.json", .{dir});
    try write(io, path,
        \\{"version":1,"personas":[{"key":"archer","name":"Archer",
        \\  "skills":["reading-a-terminal"],"mcp":["argus"]}]}
    );

    var store: PersonaStore = .{ .alloc = testing.allocator };
    defer store.deinit();
    store.load(io, path);

    const id: Bus.Id = 0x77;
    try store.setPersona(id, "archer");

    var out: std.Io.Writer.Allocating = .init(aa);
    defer out.deinit();
    try store.writeFaceJson(&out.writer, id, true);

    const parsed = try std.json.parseFromSlice(std.json.Value, aa, out.written(), .{});
    defer parsed.deinit();
    const o = parsed.value.object;

    try testing.expectEqualStrings("archer", o.get("key").?.string);
    try testing.expectEqualStrings("Archer", o.get("name").?.string);
    try testing.expect(!o.get("deviated").?.bool);
    try testing.expect(o.get("agent_present").?.bool);
    try testing.expect(!o.get("stale").?.bool);
    try testing.expectEqual(std.json.Value{ .null = {} }, o.get("error").?);

    // **The two rows the editor has to draw differently.** `in_persona`
    // tells "switched off by hand" from "added by hand"; the contract keeps
    // them apart because undoing one is not the same action as undoing the
    // other.
    const skills = o.get("skills").?.array;
    try testing.expectEqual(@as(usize, 1), skills.items.len);
    try testing.expectEqualStrings("reading-a-terminal", skills.items[0].object.get("name").?.string);
    try testing.expect(skills.items[0].object.get("in_persona").?.bool);

    // The id is the one the action string carries, built here so the apprt
    // never has to know its shape.
    const state = store.stateOf(id);
    const want = try std.fmt.allocPrint(aa, "{d}-0", .{state.roster});
    try testing.expectEqualStrings(want, skills.items[0].object.get("id").?.string);

    // A slot the persona asked for, with nothing started yet. `withheld`
    // and `broken` are different answers and this is the honest one.
    const mcp = o.get("mcp").?.array;
    try testing.expectEqualStrings("argus", mcp.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("withheld", mcp.items[0].object.get("slot").?.string);

    // Now take the skill away by hand: the key stays, the face deviates,
    // and the row is gone rather than being marked off.
    var s2 = store.states.getPtr(id).?;
    s2.effective.skills = &.{};
    s2.touch();

    var out2: std.Io.Writer.Allocating = .init(aa);
    defer out2.deinit();
    try store.writeFaceJson(&out2.writer, id, true);
    const parsed2 = try std.json.parseFromSlice(std.json.Value, aa, out2.written(), .{});
    defer parsed2.deinit();
    try testing.expect(parsed2.value.object.get("deviated").?.bool);
}

test "personas: a face with nothing chosen is still valid JSON and says it is not stale" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var store: PersonaStore = .{ .alloc = testing.allocator };
    defer store.deinit();

    var out: std.Io.Writer.Allocating = .init(aa);
    defer out.deinit();
    try store.writeFaceJson(&out.writer, 0x99, false);

    const parsed = try std.json.parseFromSlice(std.json.Value, aa, out.written(), .{});
    defer parsed.deinit();
    const o = parsed.value.object;

    try testing.expectEqual(std.json.Value{ .null = {} }, o.get("key").?);
    try testing.expect(!o.get("agent_present").?.bool);

    // **Nothing has read the file, and the interface must be able to say
    // so.** Drawn as an empty list this is "you have no personas", which is
    // a different sentence and sends the user somewhere else.
    try testing.expect(o.get("stale").?.bool);
}

test "personas: a worn persona has a name to show, and a deleted one still has its key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try std.fmt.allocPrint(aa, "{s}/personas.json", .{dir});
    try write(io, path,
        \\{"version":1,"personas":[{"key":"archer","name":"射手"}]}
    );

    var store: PersonaStore = .{ .alloc = testing.allocator };
    defer store.deinit();
    store.load(io, path);

    // **What the tab mark is built from.** The pair is NUL-terminated
    // because the apprt is handed `const char*`; the parsed strings point
    // into the JSON text and have no terminator to stop at.
    const pair = store.cName("archer") orelse return error.NoName;
    try testing.expectEqualStrings("archer", pair.key);
    try testing.expectEqualStrings("射手", pair.name);
    try testing.expectEqual(@as(u8, 0), pair.key.ptr[pair.key.len]);
    try testing.expectEqual(@as(u8, 0), pair.name.ptr[pair.name.len]);

    // A key the file no longer defines: the terminal keeps wearing it, and
    // what it loses is a name to show. The interface is told that by
    // getting nothing rather than by getting an empty string, which would
    // draw as a persona with a blank label.
    try testing.expectEqual(@as(?NamePair, null), store.cName("scribe"));
}

test "personas: a role put through the writer is in the file and in the set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    // A directory that does not exist yet: the first role anybody makes is
    // also the first time the file exists.
    const path = try std.fmt.allocPrint(aa, "{s}/sub/personas.json", .{dir});

    var store: PersonaStore = .{ .alloc = testing.allocator };
    defer store.deinit();
    store.load(io, path);

    try store.put(io, path,
        \\{"key":"archer","name":"射手","clis":{"claude-code":{"skills":{"default":false}}}}
    , .user);
    try store.put(io, path,
        \\{"key":"scribe","name":"书记"}
    , .user);
    // The two written, after the built-ins every set starts with.
    try testing.expectEqual(persona.builtins.len + 2, store.set.personas.len);
    try testing.expectEqualStrings("射手", store.cName("archer").?.name);

    // The file is what the next start reads, so it is checked, not the
    // memory.
    var fresh: PersonaStore = .{ .alloc = testing.allocator };
    defer fresh.deinit();
    fresh.load(io, path);
    try testing.expectEqual(persona.builtins.len + 2, fresh.set.personas.len);
    try testing.expect(!fresh.set.find("archer").?.clis[0].skills.default);

    try testing.expectError(error.BadPersona, store.put(io, path,
        \\{"key":"Bad Key","name":"x"}
    , .user));
    try testing.expectError(error.NoSuchPersona, store.remove(io, path, "nobody"));
    try store.remove(io, path, "archer");
    try testing.expectEqual(persona.builtins.len + 1, store.set.personas.len);
}

test "personas: a file that does not parse is not overwritten" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try std.fmt.allocPrint(aa, "{s}/personas.json", .{dir});

    // Somebody is halfway through editing it by hand.
    const half = "{\"version\":2,\"personas\":[{\"key\":\"mine\",\"name\":";
    try write(io, path, half);

    var store: PersonaStore = .{ .alloc = testing.allocator };
    defer store.deinit();
    store.load(io, path);
    try testing.expect(store.load_error != null);

    try testing.expectError(error.FileUnreadable, store.put(io, path,
        \\{"key":"archer","name":"a"}
    , .user));
    try testing.expectError(error.FileUnreadable, store.remove(io, path, "mine"));

    const after = try std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(max_bytes));
    try testing.expectEqualStrings(half, after);
}

test "personas: after an edit a terminal wears the edit, and a deleted role comes off" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try std.fmt.allocPrint(aa, "{s}/personas.json", .{dir});

    var store: PersonaStore = .{ .alloc = testing.allocator };
    defer store.deinit();
    store.load(io, path);
    try store.put(io, path,
        \\{"key":"archer","name":"a","skills":["one"]}
    , .user);
    try store.put(io, path,
        \\{"key":"scribe","name":"s"}
    , .user);

    const a: Bus.Id = 0x1111;
    const b: Bus.Id = 0x2222;
    try store.setPersona(a, "archer");
    try store.setPersona(b, "scribe");
    const roster_before = store.stateOf(a).roster;

    // Edit archer. Its old strings are freed by this; the state has to be
    // reading the new ones.
    try store.put(io, path,
        \\{"key":"archer","name":"a","skills":["two","three"]}
    , .user);
    const sa = store.stateOf(a);
    try testing.expectEqualStrings("archer", sa.key.?);
    try testing.expectEqual(@as(usize, 2), sa.effective.skills.len);
    try testing.expectEqualStrings("two", sa.effective.skills[0]);
    try testing.expect(sa.roster > roster_before);
    try testing.expect(!sa.deviated(store.set));

    try store.remove(io, path, "scribe");
    try testing.expectEqual(@as(?[]const u8, null), store.stateOf(b).key);
    try testing.expectEqualStrings("archer", store.stateOf(a).key.?);
}

test "personas: no file is the built-ins, and they can be neither replaced nor deleted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try std.fmt.allocPrint(aa, "{s}/personas.json", .{dir});

    var store: PersonaStore = .{ .alloc = testing.allocator };
    defer store.deinit();
    store.load(io, path);
    try testing.expect(store.loaded);
    try testing.expect(store.set.find(persona.supervisor_key) != null);
    try testing.expect(store.cName(persona.supervisor_key) != null);

    try testing.expectError(error.BuiltinPersona, store.put(io, path,
        \\{"key":"polter-supervisor","name":"mine"}
    , .user));
    try testing.expectError(error.BuiltinPersona, store.remove(io, path, persona.supervisor_key));

    // Refused before anything was written.
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, path, .{}));
}

test "personas: a supervisor may not set what grants a terminal something" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try std.fmt.allocPrint(aa, "{s}/personas.json", .{dir});

    var store: PersonaStore = .{ .alloc = testing.allocator };
    defer store.deinit();
    store.load(io, path);

    // A new role that grants anything: refused, one setting at a time.
    for ([_][]const u8{ "supervisor", "may_authorise", "shielded" }) |field| {
        const json = try std.fmt.allocPrint(aa, "{{\"key\":\"x\",\"name\":\"x\",\"polter\":{{\"{s}\":true}}}}", .{field});
        try testing.expectError(error.NotPermitted, store.put(io, path, json, .supervisor));
        try testing.expect(store.set.find("x") == null);
    }

    // What does not grant anything is the supervisor's to set.
    try store.put(io, path,
        \\{"key":"x","name":"x","polter":{"watch":true,"open":"tab"}}
    , .supervisor);

    // The user grants it ...
    try store.put(io, path,
        \\{"key":"x","name":"x","polter":{"watch":true,"may_authorise":true}}
    , .user);

    // ... after which a supervisor's edit that carries it as it is goes
    // through, and one that takes it away is refused like one that adds it.
    try store.put(io, path,
        \\{"key":"x","name":"renamed","polter":{"may_authorise":true,"open":"tab"}}
    , .supervisor);
    try testing.expectEqualStrings("renamed", store.set.find("x").?.name);
    try testing.expectError(error.NotPermitted, store.put(io, path,
        \\{"key":"x","name":"x"}
    , .supervisor));
    try testing.expect(store.set.find("x").?.polter.may_authorise);
}
