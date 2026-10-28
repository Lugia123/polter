//! `squads.json`: where it is, reading it, and the one way of writing it
//! (task 2449, squads slice S3; plan `2433/PLAN.md` §2.4-2.6, §4.3).
//!
//! The path is `PersonaStore.pathBeside`, so a test instance whose library
//! is isolated by `GHOSTTY_CONFIG_PATH` has its squads isolated with it.
//!
//! **A file that does not parse changes nothing except `load_error`**, as
//! with `PersonaStore`: no part of a template table looks like a whole one.
//! A missing file is an empty list, and the ordinary state; no template is
//! shipped.
//!
//! **Members are removed only by the act of deleting a role** (`dropRole`)
//! and by a later write that is told the library is readable. Loading never
//! prunes: a `personas.json` that cannot be read right now makes every role
//! look absent, and pruning on that would empty every squad.

const SquadStore = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const squad = @import("squad.zig");
const persona = @import("persona.zig");
const PersonaStore = @import("PersonaStore.zig");
const Bus = @import("Bus.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.poltergeist);

alloc: Allocator,

/// Owns the strings of `set`. Replaced whole by a good read.
arena: ?std.heap.ArenaAllocator = null,

set: squad.Set = .empty,

loaded: bool = false,

/// Why the file was not taken, with where in it; null when it was.
load_error: ?[]const u8 = null,

/// The reader's reason for the last refused `put`, owned. Says which squad
/// and member, because `WriteError` alone cannot.
last_refusal: ?[]const u8 = null,

pub const max_bytes = 256 * 1024;

pub fn deinit(self: *SquadStore) void {
    if (self.arena) |*a| a.deinit();
    self.arena = null;
    self.setError(null);
    self.setRefusal(null);
}

pub fn defaultPath(alloc: Allocator) ![]const u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    return try pathIn(alloc, &environ_map);
}

/// `squads.json` beside `personas.json`.
pub fn pathIn(alloc: Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    return try PersonaStore.pathBeside(alloc, environ_map, "squads.json");
}

/// Read the file and install it if it parses.
pub fn load(self: *SquadStore, io: std.Io, path: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    const aa = arena.allocator();

    const bytes: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(max_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            arena.deinit();
            self.setErrorFmt("could not read {s}: {t}", .{ path, err });
            return;
        },
    };

    var diag: squad.Diag = .{ .where = "" };
    const set: squad.Set = if (bytes) |b|
        squad.parseLeaky(aa, b, null, &diag) catch |err| {
            const text = std.fmt.allocPrint(self.alloc, "{s} was not loaded: {t} at {s}", .{ path, err, diag.where }) catch null;
            arena.deinit();
            self.setError(text);
            if (text) |t| log.warn("poltergeist: {s}", .{t});
            return;
        }
    else
        .empty;

    if (self.arena) |*old| old.deinit();
    self.arena = arena;
    self.set = set;
    self.loaded = true;
    self.setError(null);
}

pub const WriteError = error{
    /// The file on disk does not parse right now; writing would replace
    /// what the person was halfway through (as `PersonaStore`).
    FileUnreadable,
    /// The squad sent does not pass the reader. `last_refusal` says where.
    BadSquad,
    NoSuchSquad,
    /// A supervisor tried to change or delete a squad the user made, or to
    /// make one that says it is the user's.
    NotPermitted,
    /// A supervisor's squad has no reason, or one that is too short.
    ReasonRequired,
    TooManySupervisorSquads,
    /// A member is a supervisor role (v3, item 12).
    SupervisorNotAllowed,
    /// Written, and reading it back failed. Should not happen.
    WriteNotLoaded,
    CouldNotWrite,
    OutOfMemory,
};

/// Add a squad, or replace the one with the same key where it stands.
///
/// `roles` is the library, or null when it cannot be read; with it the
/// the squad sent must name only roles that exist (`BadSquad`, with
/// `last_refusal` saying which member and role), and members of the
/// **other** squads whose role is gone are taken out in the same write (the
/// sweep a crash between deleting a role and `dropRole` leaves for the next
/// write). `who` is who is
/// writing: the user may make anything; a supervisor's squad is always
/// `origin: supervisor`, needs a `reason`, may not exceed
/// `squad.max_supervisor_squads` and may not replace the user's.
pub fn put(
    self: *SquadStore,
    io: std.Io,
    path: []const u8,
    json: []const u8,
    roles: ?persona.Set,
    who: Bus.Authority,
) WriteError!void {
    if (self.load_error != null) return error.FileUnreadable;
    self.setRefusal(null);

    var scratch: std.heap.ArenaAllocator = .init(self.alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var diag: squad.Diag = .{ .where = "" };
    var s = squad.parseSquadLeaky(sa, json, if (who == .supervisor) .supervisor else .user, roles, &diag) catch |err| {
        self.setRefusal(std.fmt.allocPrint(self.alloc, "{t} at {s}", .{ err, diag.where }) catch null);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SupervisorNotAllowed => error.SupervisorNotAllowed,
            error.ReasonRequired => error.ReasonRequired,
            else => error.BadSquad,
        };
    };

    // The squad sent is held to the library as it is now: a member whose
    // role is not there is refused and named, not quietly dropped. (With
    // the library unreadable, `roles` is null and this cannot be asked.)
    if (roles) |r| for (s.members) |m| {
        if (r.find(m.role) != null) continue;
        self.setRefusal(std.fmt.allocPrint(self.alloc, "member {s}: there is no role {s}", .{ m.alias, m.role }) catch null);
        return error.BadSquad;
    };

    const existing = self.set.find(s.key);
    if (who == .supervisor) {
        // What a supervisor sends is the supervisor's, whatever it says.
        if (s.origin == .user) return error.NotPermitted;
        if (existing) |e| if (e.origin == .user) return error.NotPermitted;
        s.origin = .supervisor;
        if (std.mem.trim(u8, s.reason, " \t\r\n").len < squad.min_reason_len) return error.ReasonRequired;
        const others = self.set.supervisorMade() - @as(usize, if (existing != null) 1 else 0);
        if (others >= squad.max_supervisor_squads) return error.TooManySupervisorSquads;
    }

    var set = try squad.withSquad(sa, self.set, s);
    if (roles) |r| set = (try squad.withoutMembers(sa, set, squad.MissingRoles{ .roles = r })).set;
    try self.commit(io, path, set);
}

/// Delete a template. A supervisor may delete only its own.
pub fn remove(self: *SquadStore, io: std.Io, path: []const u8, key: []const u8, who: Bus.Authority) WriteError!void {
    if (self.load_error != null) return error.FileUnreadable;
    const existing = self.set.find(key) orelse return error.NoSuchSquad;
    if (who == .supervisor and existing.origin == .user) return error.NotPermitted;

    var scratch: std.heap.ArenaAllocator = .init(self.alloc);
    defer scratch.deinit();
    const set = (try squad.withoutSquad(scratch.allocator(), self.set, key)) orelse return error.NoSuchSquad;
    try self.commit(io, path, set);
}

/// After a role was deleted (`PersonaStore.remove`, which comes first): take
/// every member that refers to it out of every squad. Returns what was
/// taken, allocated in `alloc`.
///
/// **Only the role named, unless `roles` says the library is readable**, in
/// which case members of other roles that are gone are taken as well.
pub fn dropRole(
    self: *SquadStore,
    io: std.Io,
    path: []const u8,
    alloc: Allocator,
    role_key: []const u8,
    roles: ?persona.Set,
) WriteError![]const squad.Removed {
    if (self.load_error != null) return error.FileUnreadable;

    var scratch: std.heap.ArenaAllocator = .init(self.alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var dropped = try squad.withoutMembers(sa, self.set, squad.OneRole{ .key = role_key });
    if (roles) |r| {
        const more = try squad.withoutMembers(sa, dropped.set, squad.MissingRoles{ .roles = r });
        dropped.set = more.set;
        dropped.removed = try std.mem.concat(sa, squad.Removed, &.{ dropped.removed, more.removed });
    }
    if (dropped.removed.len == 0) return &.{};

    // Copy out before the commit reloads, and before the scratch goes.
    const out = try alloc.alloc(squad.Removed, dropped.removed.len);
    for (dropped.removed, 0..) |r, i| out[i] = .{
        .squad = try alloc.dupe(u8, r.squad),
        .alias = try alloc.dupe(u8, r.alias),
    };
    try self.commit(io, path, dropped.set);
    return out;
}

/// Who refers to `role_key`, for the delete-role dialog: read only.
pub fn usage(self: *const SquadStore, alloc: Allocator, role_key: []const u8) Allocator.Error![]const squad.Removed {
    var out: std.ArrayList(squad.Removed) = .empty;
    errdefer out.deinit(alloc);
    for (self.set.squads) |s| for (s.members) |m| {
        if (std.mem.eql(u8, m.role, role_key)) try out.append(alloc, .{ .squad = s.key, .alias = m.alias });
    };
    return try out.toOwnedSlice(alloc);
}

fn commit(self: *SquadStore, io: std.Io, path: []const u8, set: squad.Set) WriteError!void {
    var out: std.Io.Writer.Allocating = .init(self.alloc);
    defer out.deinit();
    squad.writeSet(&out.writer, set) catch return error.OutOfMemory;

    // Read back by the reader before the file is touched: a squad the
    // reader would refuse never reaches the disk.
    {
        var check: std.heap.ArenaAllocator = .init(self.alloc);
        defer check.deinit();
        var diag: squad.Diag = .{ .where = "" };
        _ = squad.parseLeaky(check.allocator(), out.written(), null, &diag) catch |err| {
            self.setRefusal(std.fmt.allocPrint(self.alloc, "{t} at {s}", .{ err, diag.where }) catch null);
            return error.BadSquad;
        };
    }

    PersonaStore.writeReplacing(self.alloc, io, path, out.written()) catch |err| {
        log.warn("poltergeist: could not write {s}: {t}", .{ path, err });
        return error.CouldNotWrite;
    };

    self.load(io, path);
    if (self.load_error != null) return error.WriteNotLoaded;
}

/// The library window's document: every squad, each member with whether its
/// role is still in the library. `roles` null (not readable) marks no
/// member missing -- an absent library says nothing about the roles.
pub fn writeCatalogJson(self: *const SquadStore, w: *std.Io.Writer, roles: ?persona.Set) !void {
    try w.print("{{\"loaded\":{},\"error\":", .{self.loaded});
    if (self.load_error) |e| try w.print("{f}", .{std.json.fmt(e, .{})}) else try w.writeAll("null");
    try w.writeAll(",\"squads\":[");
    for (self.set.squads, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"key\":{f},\"name\":{f},\"description\":{f},\"origin\":\"{t}\",\"reason\":{f},\"empty\":{},\"members\":[", .{
            std.json.fmt(s.key, .{}),
            std.json.fmt(s.name, .{}),
            std.json.fmt(s.description, .{}),
            s.origin,
            std.json.fmt(s.reason, .{}),
            s.members.len == 0,
        });
        for (s.members, 0..) |m, j| {
            if (j > 0) try w.writeAll(",");
            const status: squad.Status = if (roles) |r| squad.statusOf(m, r) else .ok;
            try w.print("{{\"alias\":{f},\"role\":{f},\"required\":{},\"lead\":{},\"role_missing\":{},\"supervisor_role\":{},\"override\":", .{
                std.json.fmt(m.alias, .{}),
                std.json.fmt(m.role, .{}),
                m.required,
                m.lead,
                status == .role_missing,
                status == .supervisor_role,
            });
            try squad.writeOverride(w, m.override);
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
}

fn setError(self: *SquadStore, text: ?[]const u8) void {
    if (self.load_error) |e| self.alloc.free(e);
    self.load_error = text;
}

fn setErrorFmt(self: *SquadStore, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(self.alloc, fmt, args) catch null;
    self.setError(text);
    if (text) |t| log.warn("poltergeist: {s}", .{t});
}

fn setRefusal(self: *SquadStore, text: ?[]const u8) void {
    if (self.last_refusal) |e| self.alloc.free(e);
    self.last_refusal = text;
}

// --------------------------------------------------------------------- tests

const testing = std.testing;

fn tmpDir(alloc: Allocator, io: std.Io) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-squads-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

fn readFile(aa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(max_bytes));
}

const squad_json =
    \\{"key":"trio","name":"Trio","description":"d","origin":"user","members":[
    \\ {"alias":"dev","role":"worker-dev","required":true,"lead":true,"override":{"instructions":"x"}},
    \\ {"alias":"test","role":"worker-test"}]}
;

const supervisor_json =
    \\{"key":"mine","name":"Mine","origin":"supervisor","reason":"no existing template has a reviewer who also builds","members":[
    \\ {"alias":"dev","role":"worker-dev","required":true}]}
;

const roles_ok: persona.Set = .{ .personas = &.{
    .{ .key = "worker-dev", .name = "Dev" },
    .{ .key = "worker-test", .name = "Test" },
} };

test "SquadStore: put 经读取器读回，写坏的写不进去；缺文件 = 空列表" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try std.fmt.allocPrint(aa, "{s}/squads.json", .{dir});

    var store: SquadStore = .{ .alloc = testing.allocator };
    defer store.deinit();

    // No file: loaded, empty, and no error.
    store.load(io, path);
    try testing.expect(store.loaded);
    try testing.expectEqual(@as(?[]const u8, null), store.load_error);
    try testing.expectEqual(@as(usize, 0), store.set.squads.len);

    try store.put(io, path, squad_json, roles_ok, .user);
    try testing.expectEqual(@as(usize, 1), store.set.squads.len);
    try testing.expectEqualStrings("x", store.set.squads[0].members[0].override.instructions.?);
    // What is on disk is what the reader takes.
    var fresh: SquadStore = .{ .alloc = testing.allocator };
    defer fresh.deinit();
    fresh.load(io, path);
    try testing.expectEqual(@as(usize, 1), fresh.set.squads.len);
    try testing.expectEqualStrings("trio", fresh.set.squads[0].key);

    // A squad the reader refuses (two members under one alias) is not written.
    const before = try readFile(aa, io, path);
    try testing.expectError(error.BadSquad, store.put(io, path,
        \\{"key":"bad","name":"B","members":[{"alias":"a","role":"worker-dev","required":true},{"alias":"a","role":"worker-test"}]}
    , roles_ok, .user));
    try testing.expect(store.last_refusal != null);
    try testing.expect(std.mem.indexOf(u8, store.last_refusal.?, "DuplicateAlias") != null);
    try testing.expectEqualStrings(before, try readFile(aa, io, path));
    try testing.expectEqual(@as(usize, 1), store.set.squads.len);
}

test "SquadStore: GHOSTTY_CONFIG_PATH 旁的路径与 personas.json 同目录" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const alloc = testing.allocator;
    var environ_map = try std.testing.environ.createMap(alloc);
    defer environ_map.deinit();
    try environ_map.put("GHOSTTY_CONFIG_PATH", "/tmp/polter-test.X/config/polter/isolated-test.polter");

    const squads = try pathIn(alloc, &environ_map);
    defer alloc.free(squads);
    const personas = try PersonaStore.pathIn(alloc, &environ_map);
    defer alloc.free(personas);
    try testing.expectEqualStrings("/tmp/polter-test.X/config/polter/squads.json", squads);
    try testing.expectEqualStrings(std.fs.path.dirname(personas).?, std.fs.path.dirname(squads).?);
    try testing.expectEqualStrings("personas.json", std.fs.path.basename(personas));
}

test "squad: 载入时 personas.json 读不出来只标 role_missing，不改 squads.json" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try std.fmt.allocPrint(aa, "{s}/squads.json", .{dir});

    var store: SquadStore = .{ .alloc = testing.allocator };
    defer store.deinit();
    store.load(io, path);
    try store.put(io, path, squad_json, roles_ok, .user);
    const before = try readFile(aa, io, path);

    // The library reads as empty (its file is broken): every role is
    // missing. Loading again marks them so, and prunes nothing.
    const no_roles: persona.Set = .{};
    store.load(io, path);
    // squads.json 字节不变
    try testing.expectEqualStrings(before, try readFile(aa, io, path));
    try testing.expectEqual(@as(usize, 2), store.set.squads[0].members.len);
    try testing.expectEqual(squad.Status.role_missing, squad.statusOf(store.set.squads[0].members[0], no_roles));
    try testing.expectEqual(squad.Status.role_missing, squad.statusOf(store.set.squads[0].members[1], no_roles));
    var out: std.Io.Writer.Allocating = .init(aa);
    try store.writeCatalogJson(&out.writer, no_roles);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"role_missing\":true") != null);

    // And a write told the library is unreadable (null) sweeps nothing.
    try store.put(io, path,
        \\{"key":"other","name":"O","members":[{"alias":"x","role":"worker-dev","required":true}]}
    , null, .user);
    try testing.expectEqual(@as(usize, 2), store.set.find("trio").?.members.len);
}

test "squad: 先删角色后改 squads.json；模拟崩在两步之间，成员按 role_missing 处理、下次写入被清掉" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const squads_path = try std.fmt.allocPrint(aa, "{s}/squads.json", .{dir});
    const personas_path = try std.fmt.allocPrint(aa, "{s}/personas.json", .{dir});

    var personas: PersonaStore = .{ .alloc = testing.allocator };
    defer personas.deinit();
    var store: SquadStore = .{ .alloc = testing.allocator };
    defer store.deinit();

    try writeFile(io, personas_path,
        \\{"version":3,"personas":[{"key":"worker-dev","name":"Dev"},{"key":"worker-test","name":"Test"}]}
    );
    personas.load(io, personas_path);
    store.load(io, squads_path);
    try store.put(io, squads_path, squad_json, personas.set, .user);

    // Step one: the role goes. Step two never happens (the crash).
    try personas.remove(io, personas_path, "worker-dev");
    try testing.expect(personas.set.find("worker-dev") == null);
    try testing.expectEqual(@as(usize, 2), store.set.find("trio").?.members.len);
    try testing.expectEqual(squad.Status.role_missing, squad.statusOf(store.set.squads[0].members[0], personas.set));
    try testing.expectEqual(squad.Status.ok, squad.statusOf(store.set.squads[0].members[1], personas.set));

    // The next write, told the library is readable, clears the dangling seat.
    try store.put(io, squads_path,
        \\{"key":"another","name":"A","members":[{"alias":"t","role":"worker-test","required":true}]}
    , personas.set, .user);
    const trio = store.set.find("trio").?;
    try testing.expectEqual(@as(usize, 1), trio.members.len);
    try testing.expectEqualStrings("test", trio.members[0].alias);

    // The ordinary order, role first and members after, reports who went.
    try personas.remove(io, personas_path, "worker-test");
    const gone = try store.dropRole(io, squads_path, aa, "worker-test", personas.set);
    try testing.expectEqual(@as(usize, 2), gone.len);
    try testing.expectEqual(@as(usize, 0), store.set.find("trio").?.members.len);
    // usage reads without changing a thing.
    const who = try store.usage(aa, "worker-test");
    try testing.expectEqual(@as(usize, 0), who.len);
}

test "squad: 总管建的模版无 reason 被拒；超过 12 个被拒；不能改 origin=user 的" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try std.fmt.allocPrint(aa, "{s}/squads.json", .{dir});

    var store: SquadStore = .{ .alloc = testing.allocator };
    defer store.deinit();
    store.load(io, path);
    try store.put(io, path, squad_json, roles_ok, .user);

    // No reason (the field is absent), and one too short to say anything.
    try testing.expectError(error.ReasonRequired, store.put(io, path,
        \\{"key":"mine","name":"M","members":[{"alias":"dev","role":"worker-dev","required":true}]}
    , roles_ok, .supervisor));
    try testing.expectError(error.ReasonRequired, store.put(io, path,
        \\{"key":"mine","name":"M","reason":"short","members":[{"alias":"dev","role":"worker-dev","required":true}]}
    , roles_ok, .supervisor));
    try testing.expectEqual(@as(?squad.Squad, null), store.set.find("mine"));

    // One with a reason is the supervisor's, whatever origin it wrote.
    try store.put(io, path, supervisor_json, roles_ok, .supervisor);
    try testing.expectEqual(squad.Origin.supervisor, store.set.find("mine").?.origin);

    // The user's cannot be changed or deleted by it.
    try testing.expectError(error.NotPermitted, store.put(io, path,
        \\{"key":"trio","name":"Mine now","origin":"supervisor","reason":"a long enough reason to be accepted","members":[{"alias":"dev","role":"worker-dev","required":true}]}
    , roles_ok, .supervisor));
    try testing.expectError(error.NotPermitted, store.remove(io, path, "trio", .supervisor));
    // Nor claim to be the user's.
    try testing.expectError(error.NotPermitted, store.put(io, path,
        \\{"key":"sneaky","name":"S","origin":"user","reason":"a long enough reason to be accepted","members":[{"alias":"dev","role":"worker-dev","required":true}]}
    , roles_ok, .supervisor));
    try testing.expectEqualStrings("Trio", store.set.find("trio").?.name);

    // Twelve is the most it has at once; replacing one of its own is fine.
    var i: usize = 1; // "mine" is the first
    while (i < squad.max_supervisor_squads) : (i += 1) {
        const body = try std.fmt.allocPrint(aa,
            \\{{"key":"s{d}","name":"S","reason":"a long enough reason to be accepted","members":[{{"alias":"dev","role":"worker-dev","required":true}}]}}
        , .{i});
        try store.put(io, path, body, roles_ok, .supervisor);
    }
    try testing.expectEqual(@as(usize, squad.max_supervisor_squads), store.set.supervisorMade());
    try testing.expectError(error.TooManySupervisorSquads, store.put(io, path,
        \\{"key":"one-too-many","name":"S","reason":"a long enough reason to be accepted","members":[{"alias":"dev","role":"worker-dev","required":true}]}
    , roles_ok, .supervisor));
    try store.put(io, path, supervisor_json, roles_ok, .supervisor);
    // It may delete its own.
    try store.remove(io, path, "mine", .supervisor);
    try testing.expect(store.set.find("mine") == null);
}

test "squad: 提交的模版引用不存在的角色被拒并点名，不是静默摘掉" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try std.fmt.allocPrint(aa, "{s}/squads.json", .{dir});

    var store: SquadStore = .{ .alloc = testing.allocator };
    defer store.deinit();
    store.load(io, path);

    const with_ghost =
        \\{"key":"g","name":"G","members":[{"alias":"dev","role":"worker-dev","required":true},{"alias":"phantom","role":"no-such-role"}]}
    ;
    try testing.expectError(error.BadSquad, store.put(io, path, with_ghost, roles_ok, .user));
    try testing.expect(std.mem.indexOf(u8, store.last_refusal.?, "phantom") != null);
    try testing.expect(std.mem.indexOf(u8, store.last_refusal.?, "no-such-role") != null);
    try testing.expectEqual(@as(usize, 0), store.set.squads.len);

    // With the library unreadable nothing can be asked, and it goes in.
    try store.put(io, path, with_ghost, null, .user);
    try testing.expectEqual(@as(usize, 2), store.set.find("g").?.members.len);
}

test "squad: 总管角色不能入队，写入即拒绝 SupervisorNotAllowed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const path = try std.fmt.allocPrint(aa, "{s}/squads.json", .{dir});

    var store: SquadStore = .{ .alloc = testing.allocator };
    defer store.deinit();
    store.load(io, path);

    const roles: persona.Set = .{ .personas = &.{
        .{ .key = "worker-dev", .name = "Dev" },
        .{ .key = "my-boss", .name = "Boss", .polter = .{ .supervisor = true } },
    } };
    // The shipped one, with the library not even readable.
    try testing.expectError(error.SupervisorNotAllowed, store.put(io, path,
        \\{"key":"s","name":"S","members":[{"alias":"b","role":"polter-supervisor","required":true}]}
    , null, .user));
    // One of the person's own that makes its terminal a supervisor.
    try testing.expectError(error.SupervisorNotAllowed, store.put(io, path,
        \\{"key":"s","name":"S","members":[{"alias":"b","role":"my-boss","required":true}]}
    , roles, .user));
    try testing.expectEqual(@as(usize, 0), store.set.squads.len);
    // And the ordinary role still goes in.
    try store.put(io, path,
        \\{"key":"s","name":"S","members":[{"alias":"d","role":"worker-dev","required":true}]}
    , roles, .user);
    try testing.expectEqual(@as(usize, 1), store.set.squads.len);
}
