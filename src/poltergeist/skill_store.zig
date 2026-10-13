//! Where a skill's text comes from, and a person's own copy of one.
//!
//! `skill.zig` is the format; this is the files. A skill Polter ships is
//! `<resources>/poltergeist/<name>.md`. A person's copy of it is
//! `<config>/polter/skills/<name>.md`, and wins.
//!
//! **One function decides which copy is in use, and everything asks it**
//! (`resolve`). There used to be two answers: `skill_read` looked in
//! `<config>/polter/polter/skills/` -- a directory joined twice -- and the
//! copy handed to the agent CLIs came from `<config>/polter/skills/`. A
//! person who put a file where the documentation said got a CLI reading
//! their text and a `skill_read` still answering with the shipped one, and
//! nothing anywhere said so.
//!
//! The copy a person saves from the role library is recorded in
//! `official-overrides.json` with the hash of the shipped file it was made
//! from (`official.skillBase`), which is what tells "you changed this" from
//! "you changed this, and the official text has moved since" -- and a copy
//! with no record, which somebody put there by hand, from both.

const std = @import("std");
const Allocator = std.mem.Allocator;
const skill = @import("skill.zig");
const official = @import("official.zig");
const persona = @import("persona.zig");
const PersonaStore = @import("PersonaStore.zig");

const log = std.log.scoped(.poltergeist);

/// Longest skill file read. The same megabyte the loader always allowed.
pub const max_bytes = 1024 * 1024;

pub const Origin = enum {
    /// `<config>/polter/skills/`.
    user,
    /// `<config>/polter/polter/skills/`, where `skill_read` alone used to
    /// look (`skill.legacyUserPath`).
    legacy_user,
    shipped,
};

pub const Source = struct {
    path: []const u8,
    origin: Origin,
};

/// A person's own copy of the skill `name`.
pub const UserCopy = union(enum) {
    none,
    /// A file is there and does not read as a skill. It is not used: a
    /// broken file reads as missing rather than as instructions.
    broken: []const u8,
    ok: struct { path: []const u8, origin: Origin, bytes: []const u8 },
};

fn readSkill(aa: Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(max_bytes)) catch null;
}

/// `config_root` is the configuration root (`~/.config`), not Polter's
/// directory in it; null when it could not be found.
pub fn userCopy(aa: Allocator, io: std.Io, name: []const u8, config_root: ?[]const u8) Allocator.Error!UserCopy {
    const root = config_root orelse return .none;
    var broken: ?[]const u8 = null;
    for ([_]Origin{ .user, .legacy_user }) |origin| {
        const path = (switch (origin) {
            .user => skill.userPath(aa, root, name),
            .legacy_user => skill.legacyUserPath(aa, root, name),
            .shipped => unreachable,
        }) catch |err| switch (err) {
            error.BadName => return .none,
            error.OutOfMemory => return error.OutOfMemory,
        };
        const bytes = readSkill(aa, io, path) orelse continue;
        const parsed = skill.parse(bytes) catch |err| {
            log.warn("poltergeist: skill at {s} does not parse err={}", .{ path, err });
            if (broken == null) broken = path;
            continue;
        };
        // A file that names another skill is that other skill's text under
        // this one's name.
        if (!std.mem.eql(u8, parsed.meta.name, name)) {
            log.warn("poltergeist: skill at {s} names itself {s}; not used", .{ path, parsed.meta.name });
            if (broken == null) broken = path;
            continue;
        }
        if (origin == .legacy_user) log.warn(
            "poltergeist: using the skill at {s}; its place is one directory up, in polter/skills/",
            .{path},
        );
        return .{ .ok = .{ .path = path, .origin = origin, .bytes = bytes } };
    }
    return if (broken) |path| .{ .broken = path } else .none;
}

/// The file the skill `name` is read from: the person's copy when there is
/// one that reads, else the shipped one. Null when there is neither.
///
/// `skill_read` and the copy handed to the agent CLIs both come from here.
pub fn resolve(
    aa: Allocator,
    io: std.Io,
    name: []const u8,
    config_root: ?[]const u8,
    resources_dir: ?[]const u8,
) Allocator.Error!?Source {
    switch (try userCopy(aa, io, name, config_root)) {
        .ok => |c| return .{ .path = c.path, .origin = c.origin },
        .none, .broken => {},
    }
    const dir = resources_dir orelse return null;
    const path = skill.resourcePath(aa, dir, name) catch |err| switch (err) {
        error.BadName => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return .{ .path = path, .origin = .shipped };
}

/// The prose of the skill `name`, from whichever copy is in use.
pub fn readBody(
    alloc: Allocator,
    io: std.Io,
    name: []const u8,
    config_root: ?[]const u8,
    resources_dir: ?[]const u8,
) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const source = (try resolve(aa, io, name, config_root, resources_dir)) orelse return error.NoSuchSkill;
    const bytes = readSkill(aa, io, source.path) orelse return error.NoSuchSkill;
    const parsed = skill.parse(bytes) catch |err| {
        log.warn("poltergeist: skill at {s} does not parse err={}", .{ source.path, err });
        return error.NoSuchSkill;
    };
    return try alloc.dupe(u8, parsed.body);
}

/// The skills this install ships.
///
/// **Two answers that both have no names in them, kept apart.** A list of
/// what ships is also a list of what does not, and something acts on that:
/// the provisioning plugins remove a `polter-*` skill they installed once
/// it stops being shipped. "The directory could not be read" must never
/// arrive there looking like "nothing ships any more".
pub const Shipped = union(enum) {
    /// Not known: no resources directory, or it could not be listed.
    unreadable: anyerror,
    /// Known, sorted. May be empty, and then it really is empty.
    names: []const []const u8,
};

pub fn shipped(aa: Allocator, io: std.Io, resources_dir: ?[]const u8) Shipped {
    const res = resources_dir orelse return .{ .unreadable = error.NoResourcesDir };
    const path = std.fs.path.join(aa, &.{ res, "poltergeist" }) catch |err| return .{ .unreadable = err };
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| return .{ .unreadable = err };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |err| return .{ .unreadable = err }) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const stem = entry.name[0 .. entry.name.len - ".md".len];
        // By file name, without reading: the build already read every one
        // of these (`PolterOfficial.zig`), and a file dropped from this
        // list for being unreadable here would be a skill the plugins then
        // take away.
        if (!skill.isValidName(stem)) continue;
        names.append(aa, aa.dupe(u8, stem) catch |err| return .{ .unreadable = err }) catch |err|
            return .{ .unreadable = err };
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return .{ .names = names.items };
}

pub const Provisioned = struct { name: []const u8, path: []const u8 };

/// What the provisioning plugins are handed: every shipped skill, each
/// resolved to the copy in use. **Null when what ships is not known** -- the
/// caller then says nothing about skills at all, rather than sending a list
/// that reads as "none of them".
pub fn provisioned(
    aa: Allocator,
    io: std.Io,
    config_root: ?[]const u8,
    resources_dir: ?[]const u8,
) Allocator.Error!?[]const Provisioned {
    const names = switch (shipped(aa, io, resources_dir)) {
        .unreadable => |err| {
            log.warn("poltergeist: the shipped skills could not be listed ({t}); none handed out", .{err});
            return null;
        },
        .names => |n| n,
    };
    var out: std.ArrayList(Provisioned) = .empty;
    for (names) |name| {
        const source = (try resolve(aa, io, name, config_root, resources_dir)) orelse {
            log.warn("poltergeist: no source for skill {s}", .{name});
            // Listed a moment ago and gone now. The list is no longer
            // whole, and a partial list is the dangerous one.
            return null;
        };
        try out.append(aa, .{ .name = name, .path = source.path });
    }
    return try out.toOwnedSlice(aa);
}

fn sha256Hex(aa: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return try std.fmt.allocPrint(aa, "{x}", .{&digest});
}

pub const Status = struct {
    state: persona.Official.Status,
    reason: ?[]const u8,
};

/// Where a shipped skill stands against the person's copy of it. The same
/// four states an official role has, for the same reasons.
pub fn status(aa: Allocator, copy: UserCopy, shipped_bytes: []const u8, read: official.Read, name: []const u8) Allocator.Error!Status {
    switch (copy) {
        .none => return .{ .state = .pristine, .reason = null },
        .broken => |path| return .{
            .state = .unknown,
            .reason = try std.fmt.allocPrint(aa, "your copy at {s} does not read as this skill; the shipped one is in use", .{path}),
        },
        .ok => {},
    }
    return switch (official.skillBase(aa, read, name)) {
        .hash => |h| if (std.mem.eql(u8, h, try sha256Hex(aa, shipped_bytes)))
            .{ .state = .modified, .reason = null }
        else
            .{ .state = .modified_stale, .reason = null },
        .none => .{
            .state = .unknown,
            .reason = "this copy was not saved from Polter, so whether the official text has changed since is not known",
        },
        .unknown => |why| .{ .state = .unknown, .reason = why },
    };
}

/// Every shipped skill with its text and where it stands, as JSON for the
/// role library.
pub fn writeCatalogJson(
    w: *std.Io.Writer,
    aa: Allocator,
    io: std.Io,
    config_root: ?[]const u8,
    resources_dir: ?[]const u8,
    read: official.Read,
) !void {
    const names = switch (shipped(aa, io, resources_dir)) {
        .unreadable => |err| {
            // `skills` is null, not empty: nobody knows what ships.
            try w.print("{{\"error\":\"the shipped skills could not be listed ({t})\",\"skills\":null}}", .{err});
            return;
        },
        .names => |n| n,
    };
    try w.writeAll("{\"error\":null,\"skills\":[");
    var first = true;
    for (names) |name| {
        const path = try skill.resourcePath(aa, resources_dir.?, name);
        const shipped_bytes = readSkill(aa, io, path) orelse continue;
        const meta = if (skill.parse(shipped_bytes)) |s| s.meta else |_| continue;
        const copy = try userCopy(aa, io, name, config_root);
        const st = try status(aa, copy, shipped_bytes, read, name);
        const text = switch (copy) {
            .ok => |c| c.bytes,
            .none, .broken => shipped_bytes,
        };
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"name\":{f},\"description\":{f},\"state\":\"{t}\",\"reason\":", .{
            std.json.fmt(name, .{}),
            std.json.fmt(meta.description, .{}),
            st.state,
        });
        if (st.reason) |r| try w.print("{f}", .{std.json.fmt(r, .{})}) else try w.writeAll("null");
        try w.print(",\"source\":{f},\"shipped\":{f}}}", .{
            std.json.fmt(text, .{}),
            std.json.fmt(shipped_bytes, .{}),
        });
    }
    try w.writeAll("]}");
}

pub const WriteError = error{
    /// Not a skill Polter ships. Only those are edited here.
    NoSuchSkill,
    /// The text does not read as a skill, or names another one.
    BadSkill,
    /// `official-overrides.json` cannot be read, so what this copy was made
    /// from cannot be recorded in it.
    OverridesUnreadable,
    NoConfigDir,
    CouldNotWrite,
    OutOfMemory,
};

/// Save a person's copy of the shipped skill `name`. Text equal to the
/// shipped file is not a copy: it puts the skill back.
///
/// Not reachable by an agent: only the role library calls this.
pub fn put(
    alloc: Allocator,
    io: std.Io,
    name: []const u8,
    text: []const u8,
    config_root: ?[]const u8,
    resources_dir: ?[]const u8,
    personas_path: []const u8,
) WriteError!void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const root = config_root orelse return error.NoConfigDir;
    const res = resources_dir orelse return error.NoSuchSkill;
    const shipped_path = skill.resourcePath(aa, res, name) catch |err| return switch (err) {
        error.BadName => error.NoSuchSkill,
        error.OutOfMemory => error.OutOfMemory,
    };
    const shipped_bytes = readSkill(aa, io, shipped_path) orelse return error.NoSuchSkill;

    const parsed = skill.parse(text) catch return error.BadSkill;
    if (!std.mem.eql(u8, parsed.meta.name, name)) return error.BadSkill;

    if (std.mem.eql(u8, text, shipped_bytes)) return restore(alloc, io, name, config_root, personas_path);

    const read = PersonaStore.readOverrides(aa, io, personas_path);
    const doc = official.withSkillBase(aa, read, name, try sha256Hex(aa, shipped_bytes)) catch |err| return switch (err) {
        error.Unreadable => error.OverridesUnreadable,
        error.OutOfMemory => error.OutOfMemory,
    };

    // The text first, then the record of what it was made from: if the
    // second write fails, what is left is a copy with no record, which
    // reads as "not known" -- and that is true.
    const path = skill.userPath(aa, root, name) catch return error.NoSuchSkill;
    PersonaStore.writeReplacing(aa, io, path, text) catch |err| {
        log.warn("poltergeist: could not write {s}: {t}", .{ path, err });
        return error.CouldNotWrite;
    };
    const opath = try PersonaStore.overridesPath(aa, personas_path);
    PersonaStore.writeReplacing(aa, io, opath, doc) catch |err| {
        log.warn("poltergeist: could not write {s}: {t}", .{ opath, err });
        return error.CouldNotWrite;
    };
}

/// "I know the official text has changed; keep mine": the person's copy
/// stays as it is and is recorded as made from the shipped text as it is
/// today, so it reads as changed and no longer as behind. A copy somebody
/// put there by hand, which had no record at all, gets one the same way.
/// With no copy there is nothing to keep, and nothing is written.
pub fn acknowledge(
    alloc: Allocator,
    io: std.Io,
    name: []const u8,
    config_root: ?[]const u8,
    resources_dir: ?[]const u8,
    personas_path: []const u8,
) WriteError!void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const res = resources_dir orelse return error.NoSuchSkill;
    const shipped_path = skill.resourcePath(aa, res, name) catch |err| return switch (err) {
        error.BadName => error.NoSuchSkill,
        error.OutOfMemory => error.OutOfMemory,
    };
    const shipped_bytes = readSkill(aa, io, shipped_path) orelse return error.NoSuchSkill;
    switch (try userCopy(aa, io, name, config_root)) {
        .ok => {},
        // A copy that does not read is not in use; there is nothing of the
        // person's to keep until it is fixed or put back.
        .none, .broken => return,
    }

    const read = PersonaStore.readOverrides(aa, io, personas_path);
    const doc = official.withSkillBase(aa, read, name, try sha256Hex(aa, shipped_bytes)) catch |err| return switch (err) {
        error.Unreadable => error.OverridesUnreadable,
        error.OutOfMemory => error.OutOfMemory,
    };
    const opath = try PersonaStore.overridesPath(aa, personas_path);
    PersonaStore.writeReplacing(aa, io, opath, doc) catch |err| {
        log.warn("poltergeist: could not write {s}: {t}", .{ opath, err });
        return error.CouldNotWrite;
    };
}

/// Put the skill `name` back to the shipped one: the person's copy is
/// deleted, from both places one can be, and its record with it.
///
/// **Works whatever state the overrides file is in.** The copy is what
/// overrides the skill; the record only describes it. When the file cannot
/// be read the record stays where it is, describing nothing, and is
/// replaced the next time a copy is saved.
pub fn restore(
    alloc: Allocator,
    io: std.Io,
    name: []const u8,
    config_root: ?[]const u8,
    personas_path: []const u8,
) WriteError!void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const root = config_root orelse return error.NoConfigDir;
    const cwd = std.Io.Dir.cwd();
    for ([_]bool{ false, true }) |legacy| {
        const path = (if (legacy) skill.legacyUserPath(aa, root, name) else skill.userPath(aa, root, name)) catch |err| return switch (err) {
            error.BadName => error.NoSuchSkill,
            error.OutOfMemory => error.OutOfMemory,
        };
        cwd.deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                log.warn("poltergeist: could not delete {s}: {t}", .{ path, err });
                return error.CouldNotWrite;
            },
        };
    }

    const read = PersonaStore.readOverrides(aa, io, personas_path);
    if (read == .absent) return;
    if (official.skillBase(aa, read, name) == .none) return;
    const doc = official.withSkillBase(aa, read, name, null) catch |err| switch (err) {
        error.Unreadable => return,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const opath = try PersonaStore.overridesPath(aa, personas_path);
    PersonaStore.writeReplacing(aa, io, opath, doc) catch |err| {
        log.warn("poltergeist: could not write {s}: {t}", .{ opath, err });
        return error.CouldNotWrite;
    };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    dir: []const u8 = "",
    config: []const u8 = "",
    res: []const u8 = "",
    personas: []const u8 = "",

    const shipped_text = "---\nname: supervising\ndescription: d\n---\nshipped prose\n";

    /// In place: the arena and the io are pointed at from inside.
    fn init(f: *Fixture) !void {
        f.* = .{ .arena = .init(testing.allocator), .threaded = .init(testing.allocator, .{}) };
        const aa = f.arena.allocator();
        const tio = f.threaded.io();
        var raw: [6]u8 = undefined;
        tio.random(&raw);
        f.dir = try std.fmt.allocPrint(aa, "/tmp/polter-skills-{x}", .{&raw});
        f.config = try std.fmt.allocPrint(aa, "{s}/config", .{f.dir});
        f.res = try std.fmt.allocPrint(aa, "{s}/res", .{f.dir});
        f.personas = try std.fmt.allocPrint(aa, "{s}/lib/personas.json", .{f.dir});
        try f.write(try skill.resourcePath(aa, f.res, "supervising"), shipped_text);
        try f.write(
            try skill.resourcePath(aa, f.res, "reading-a-terminal"),
            "---\nname: reading-a-terminal\n---\nread\n",
        );
    }

    fn deinit(f: *Fixture) void {
        std.Io.Dir.cwd().deleteTree(f.threaded.io(), f.dir) catch {};
        f.threaded.deinit();
        f.arena.deinit();
    }

    fn write(f: *Fixture, path: []const u8, text: []const u8) !void {
        try PersonaStore.writeReplacing(f.arena.allocator(), f.threaded.io(), path, text);
    }

    fn mine(comptime prose: []const u8) []const u8 {
        return "---\nname: supervising\n---\n" ++ prose ++ "\n";
    }

    fn overrides(f: *Fixture) official.Read {
        return PersonaStore.readOverrides(f.arena.allocator(), f.threaded.io(), f.personas);
    }

    fn state(f: *Fixture) !Status {
        const aa = f.arena.allocator();
        const copy = try userCopy(aa, f.threaded.io(), "supervising", f.config);
        const res_path = try skill.resourcePath(aa, f.res, "supervising");
        const bytes = readSkill(aa, f.threaded.io(), res_path).?;
        return try status(aa, copy, bytes, f.overrides(), "supervising");
    }
};

test "skills: both ways in read the one copy, and the person's wins" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const aa = f.arena.allocator();
    const io = f.threaded.io();

    // Nothing of the person's: both get the shipped one.
    try testing.expectEqualStrings("shipped prose\n", try readBody(aa, io, "supervising", f.config, f.res));
    try testing.expectEqual(Origin.shipped, (try resolve(aa, io, "supervising", f.config, f.res)).?.origin);

    // A copy where the documentation says to put one. `skill_read`
    // (`readBody`) and the copy handed to the CLIs (`provisioned`) used to
    // disagree about this file; now what one reads is the file the other
    // names.
    const user_path = try skill.userPath(aa, f.config, "supervising");
    try f.write(user_path, Fixture.mine("mine"));
    try testing.expectEqualStrings("mine\n", try readBody(aa, io, "supervising", f.config, f.res));
    const handed = (try provisioned(aa, io, f.config, f.res)).?;
    const sup = for (handed) |h| {
        if (std.mem.eql(u8, h.name, "supervising")) break h;
    } else return error.TestExpectedEqual;
    try testing.expectEqualStrings(user_path, sup.path);
    try testing.expectEqual(@as(usize, 2), handed.len);
}

test "skills: a copy in the old doubled directory is still read, after the real one" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const aa = f.arena.allocator();
    const io = f.threaded.io();

    const old_path = try skill.legacyUserPath(aa, f.config, "supervising");
    try f.write(old_path, Fixture.mine("old place"));
    const got = (try resolve(aa, io, "supervising", f.config, f.res)).?;
    try testing.expectEqual(Origin.legacy_user, got.origin);
    try testing.expectEqualStrings(old_path, got.path);
    try testing.expectEqualStrings("old place\n", try readBody(aa, io, "supervising", f.config, f.res));
    try testing.expectEqualStrings(old_path, (try provisioned(aa, io, f.config, f.res)).?[1].path);

    try f.write(try skill.userPath(aa, f.config, "supervising"), Fixture.mine("real place"));
    try testing.expectEqual(Origin.user, (try resolve(aa, io, "supervising", f.config, f.res)).?.origin);
    try testing.expectEqualStrings("real place\n", try readBody(aa, io, "supervising", f.config, f.res));
}

test "skills: a copy that does not read is not used, and is said to be there" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const aa = f.arena.allocator();
    const io = f.threaded.io();

    try f.write(try skill.userPath(aa, f.config, "supervising"), "no frontmatter at all");
    try testing.expectEqual(Origin.shipped, (try resolve(aa, io, "supervising", f.config, f.res)).?.origin);
    try testing.expect((try userCopy(aa, io, "supervising", f.config)) == .broken);
    try testing.expectEqual(persona.Official.Status.unknown, (try f.state()).state);

    // And one that reads as a different skill is not this one's text.
    try f.write(try skill.userPath(aa, f.config, "supervising"), "---\nname: reading-a-terminal\n---\nx\n");
    try testing.expect((try userCopy(aa, io, "supervising", f.config)) == .broken);
}

test "skills: what ships is listed from the directory, and not knowing is not an empty list" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const aa = f.arena.allocator();
    const io = f.threaded.io();

    // Things that are not skills sit beside them and are not listed.
    try f.write(try std.fmt.allocPrint(aa, "{s}/poltergeist/README.txt", .{f.res}), "x");
    try f.write(try std.fmt.allocPrint(aa, "{s}/poltergeist/Not A Name.md", .{f.res}), "x");
    const names = shipped(aa, io, f.res).names;
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("reading-a-terminal", names[0]);
    try testing.expectEqualStrings("supervising", names[1]);

    // No directory, and no resources at all: not known, which is not the
    // same answer as a directory with nothing in it.
    const missing = try std.fmt.allocPrint(aa, "{s}/nowhere", .{f.dir});
    try testing.expect(shipped(aa, io, missing) == .unreadable);
    try testing.expect(shipped(aa, io, null) == .unreadable);
    const empty = try std.fmt.allocPrint(aa, "{s}/empty", .{f.dir});
    try std.Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(aa, "{s}/poltergeist", .{empty}));
    try testing.expectEqual(@as(usize, 0), shipped(aa, io, empty).names.len);

    // ⚠️ What the plugins are handed. They take away a `polter-*` skill
    // that is no longer in the list, so an unreadable directory must hand
    // them no list -- never an empty one.
    try testing.expect((try provisioned(aa, io, f.config, missing)) == null);
    try testing.expect((try provisioned(aa, io, f.config, null)) == null);
    try testing.expectEqual(@as(usize, 0), (try provisioned(aa, io, f.config, empty)).?.len);
}

test "skills: a saved copy is changed, then behind once the shipped text moves, and a hand-made one is not known" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const aa = f.arena.allocator();
    const io = f.threaded.io();
    const S = persona.Official.Status;

    try testing.expectEqual(S.pristine, (try f.state()).state);

    try put(testing.allocator, io, "supervising", Fixture.mine("mine"), f.config, f.res, f.personas);
    try testing.expectEqual(S.modified, (try f.state()).state);
    try testing.expectEqualStrings("mine\n", try readBody(aa, io, "supervising", f.config, f.res));

    // A new release changes the shipped text under it.
    try f.write(try skill.resourcePath(aa, f.res, "supervising"), "---\nname: supervising\n---\nnew shipped prose\n");
    try testing.expectEqual(S.modified_stale, (try f.state()).state);
    try testing.expectEqualStrings("mine\n", try readBody(aa, io, "supervising", f.config, f.res));

    // Back to the shipped one: the copy and its record both go.
    try restore(testing.allocator, io, "supervising", f.config, f.personas);
    try testing.expectEqual(S.pristine, (try f.state()).state);
    try testing.expectEqualStrings("new shipped prose\n", try readBody(aa, io, "supervising", f.config, f.res));
    try testing.expect(official.skillBase(aa, f.overrides(), "supervising") == .none);

    // A file somebody put there by hand has no record of what it was made
    // from: changed, and whether the official text moved since is unknown.
    try f.write(try skill.userPath(aa, f.config, "supervising"), Fixture.mine("by hand"));
    const st = try f.state();
    try testing.expectEqual(S.unknown, st.state);
    try testing.expect(st.reason != null);
}

test "skills: keeping mine clears behind and not-known, and leaves the copy alone" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const aa = f.arena.allocator();
    const io = f.threaded.io();
    const a = testing.allocator;
    const S = persona.Official.Status;

    // Nothing of the person's: nothing to keep, and no file is made.
    try acknowledge(a, io, "supervising", f.config, f.res, f.personas);
    try testing.expectEqual(S.pristine, (try f.state()).state);
    try testing.expect(f.overrides() == .absent);

    // Saved, then the shipped text moves: behind. Kept: changed, same text.
    try put(a, io, "supervising", Fixture.mine("mine"), f.config, f.res, f.personas);
    try f.write(try skill.resourcePath(aa, f.res, "supervising"), "---\nname: supervising\n---\nnew shipped prose\n");
    try testing.expectEqual(S.modified_stale, (try f.state()).state);
    try acknowledge(a, io, "supervising", f.config, f.res, f.personas);
    try testing.expectEqual(S.modified, (try f.state()).state);
    try testing.expectEqualStrings("mine\n", try readBody(aa, io, "supervising", f.config, f.res));

    // A copy put there by hand has no record; keeping it gives it one.
    try restore(a, io, "supervising", f.config, f.personas);
    try f.write(try skill.userPath(aa, f.config, "supervising"), Fixture.mine("by hand"));
    try testing.expectEqual(S.unknown, (try f.state()).state);
    try acknowledge(a, io, "supervising", f.config, f.res, f.personas);
    try testing.expectEqual(S.modified, (try f.state()).state);

    // With the record file unreadable it cannot be written, and is not replaced.
    const opath = try PersonaStore.overridesPath(aa, f.personas);
    try f.write(opath, "{{{");
    try testing.expectError(error.OverridesUnreadable, acknowledge(a, io, "supervising", f.config, f.res, f.personas));
    try testing.expectEqualStrings("{{{", readSkill(aa, io, opath).?);
    try testing.expectError(error.NoSuchSkill, acknowledge(a, io, "invented", f.config, f.res, f.personas));
}

test "skills: only a shipped skill is saved, under its own name, and the shipped text is not a copy" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const aa = f.arena.allocator();
    const io = f.threaded.io();
    const a = testing.allocator;

    try testing.expectError(error.NoSuchSkill, put(a, io, "invented", "---\nname: invented\n---\nx\n", f.config, f.res, f.personas));
    try testing.expectError(error.NoSuchSkill, put(a, io, "../x", "---\nname: x\n---\nx\n", f.config, f.res, f.personas));
    try testing.expectError(error.BadSkill, put(a, io, "supervising", "no frontmatter", f.config, f.res, f.personas));
    try testing.expectError(error.BadSkill, put(a, io, "supervising", "---\nname: reading-a-terminal\n---\nx\n", f.config, f.res, f.personas));
    try testing.expect((try userCopy(aa, io, "supervising", f.config)) == .none);

    // Saving the shipped text over a copy puts the skill back.
    try put(a, io, "supervising", Fixture.mine("mine"), f.config, f.res, f.personas);
    try put(a, io, "supervising", Fixture.shipped_text, f.config, f.res, f.personas);
    try testing.expect((try userCopy(aa, io, "supervising", f.config)) == .none);
    try testing.expectEqual(persona.Official.Status.pristine, (try f.state()).state);
}

test "skills: with the overrides file unreadable a copy is not saved, and restoring still works" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const aa = f.arena.allocator();
    const io = f.threaded.io();
    const a = testing.allocator;

    const opath = try PersonaStore.overridesPath(aa, f.personas);
    try f.write(opath, "{{{ not json");
    try testing.expectError(error.OverridesUnreadable, put(a, io, "supervising", Fixture.mine("mine"), f.config, f.res, f.personas));
    try testing.expect((try userCopy(aa, io, "supervising", f.config)) == .none);

    // A copy that is already there is taken away all the same, and the
    // file nobody can read is left exactly as it was.
    try f.write(try skill.userPath(aa, f.config, "supervising"), Fixture.mine("by hand"));
    try f.write(try skill.legacyUserPath(aa, f.config, "supervising"), Fixture.mine("old place"));
    try restore(a, io, "supervising", f.config, f.personas);
    try testing.expect((try userCopy(aa, io, "supervising", f.config)) == .none);
    try testing.expectEqualStrings("{{{ not json", readSkill(aa, io, opath).?);
}

test "skills: the catalog says what ships, whose text is in use, and null when it cannot know" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const aa = f.arena.allocator();
    const io = f.threaded.io();

    try put(testing.allocator, io, "supervising", Fixture.mine("mine"), f.config, f.res, f.personas);
    var out: std.Io.Writer.Allocating = .init(aa);
    try writeCatalogJson(&out.writer, aa, io, f.config, f.res, f.overrides());
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, aa, out.written(), .{});
    const skills = parsed.object.get("skills").?.array.items;
    try testing.expectEqual(@as(usize, 2), skills.len);
    try testing.expectEqualStrings("reading-a-terminal", skills[0].object.get("name").?.string);
    try testing.expectEqualStrings("pristine", skills[0].object.get("state").?.string);
    try testing.expectEqualStrings("supervising", skills[1].object.get("name").?.string);
    try testing.expectEqualStrings("modified", skills[1].object.get("state").?.string);
    try testing.expectEqualStrings(Fixture.mine("mine"), skills[1].object.get("source").?.string);
    try testing.expectEqualStrings(Fixture.shipped_text, skills[1].object.get("shipped").?.string);

    var none: std.Io.Writer.Allocating = .init(aa);
    try writeCatalogJson(&none.writer, aa, io, f.config, null, .absent);
    const unknown = try std.json.parseFromSliceLeaky(std.json.Value, aa, none.written(), .{});
    try testing.expect(unknown.object.get("skills").? == .null);
    try testing.expect(unknown.object.get("error").? == .string);
}
