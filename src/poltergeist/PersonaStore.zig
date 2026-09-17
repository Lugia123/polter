//! Where the personas the user wrote live, and what each terminal is
//! currently wearing.
//!
//! `persona.zig` is the pure half -- the file format, the rules, the
//! effective set. This is the half that touches a disk and a clock: it
//! reads `personas.json`, keeps the parsed result, and holds one
//! `persona.State` per terminal.
//!
//! **Read only, and that is the enforcement rather than a habit.** There is
//! no path in this file that opens `personas.json` for writing, because
//! `dev-docs/poltergeist/roles.md` §7 requires a persona to be a closed set
//! the user defines: a tool that could edit one would be a tool that grants
//! a terminal capabilities the user never agreed to. The constraint is
//! "there is nothing here that writes", which cannot be forgotten, rather
//! than "nothing calls the writer", which can.

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

pub const NamePair = struct {
    key: [:0]const u8,
    name: [:0]const u8,
};

pub fn deinit(self: *PersonaStore) void {
    if (self.arena) |*a| a.deinit();
    if (self.load_error) |e| self.alloc.free(e);
    self.states.deinit(self.alloc);
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
            // Nothing there, and nothing wrong. Note that we looked.
            self.setError(null);
            self.loaded = true;
            return;
        },
        else => {
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
        self.setErrorFmt("{s} was not loaded: {t}", .{ path, err });
        arena.deinit();
        return;
    };

    // The C-facing copies, built while the arena is still ours to fail in.
    const aa = arena.allocator();
    const names = aa.alloc(NamePair, set.personas.len) catch {
        self.setErrorFmt("out of memory reading {s}", .{path});
        arena.deinit();
        return;
    };
    for (set.personas, 0..) |p, i| {
        names[i] = .{
            .key = aa.dupeZ(u8, p.key) catch {
                self.setErrorFmt("out of memory reading {s}", .{path});
                arena.deinit();
                return;
            },
            .name = aa.dupeZ(u8, p.name) catch {
                self.setErrorFmt("out of memory reading {s}", .{path});
                arena.deinit();
                return;
            },
        };
    }

    // Only now, with a whole good set in hand, is the old one dropped.
    if (self.arena) |*a| a.deinit();
    self.arena = arena;
    self.set = set;
    self.names = names;
    self.loaded = true;
    self.setError(null);

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
    try testing.expectEqual(@as(usize, 0), store.set.personas.len);

    try write(io, path,
        \\{"version":1,"personas":[{"key":"archer","name":"Archer",
        \\  "tools":{"deny":["notify_user"]}}]}
    );
    store.load(io, path);
    try testing.expectEqual(@as(usize, 1), store.set.personas.len);
    try testing.expectEqual(@as(?[]const u8, null), store.load_error);

    // **The assertion this test exists for.** A typo must not silently
    // empty the menu: dropping to zero personas is indistinguishable from
    // "you have not defined any", which is a sentence the interface already
    // uses for something else.
    try write(io, path, "{\"version\":1,\"personas\":[{\"key\":\"a\"");
    store.load(io, path);
    try testing.expectEqual(@as(usize, 1), store.set.personas.len);
    try testing.expectEqualStrings("Archer", store.set.personas[0].name);
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
