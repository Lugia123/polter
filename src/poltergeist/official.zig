//! Official roles: the ones Polter ships, and what a person changed in them.
//!
//! An official role is two files under `roles/` -- `<key>.json`, one persona
//! object in the shape `personas.json` uses, and `<key>.md`, the text its
//! agent is started with. The build lists that directory, checks every file
//! with the parser below, and embeds them (`src/build/PolterOfficial.zig`),
//! so **the official version is the one this binary carries**: the app and
//! `polter +launch` are two processes and cannot be handed two different
//! copies, and there is no installed file that could go missing.
//!
//! What a person changes in one is kept as an **override**, in
//! `official-overrides.json` beside `personas.json`, one field at a time:
//!
//!     {"version":1,
//!      "roles":{"polter-supervisor":{
//!        "instructions":{"value":"...","base":"..."},
//!        "clis.claude-code.model":{"value":"opus","base":null}}},
//!      "skills":{"supervising":{"base":"<sha256 of the shipped file>"}}}
//!
//! `value` is theirs; `base` is what the official role said in that field
//! when they changed it. The role in effect is the official one with each
//! overridden field replaced, so a field nobody touched follows the next
//! release by itself, and a field somebody did touch stays theirs. Comparing
//! `base` with today's official value is what tells "changed by you" from
//! "changed by you, and the official text has moved since".
//!
//! Not in `personas.json`, where it would be simpler: an older Polter refuses
//! that whole file when it meets an official key, so one downgrade would
//! have emptied the person's own library.
//!
//! Pure: text and values in, values out. The file is read and written by
//! `PersonaStore` and `SkillStore`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const persona = @import("persona.zig");
const Persona = persona.Persona;
const Polter = persona.Polter;
const Selection = persona.Selection;
const CliChoice = persona.CliChoice;
const ParseError = persona.ParseError;

/// The version of `official-overrides.json` this reads and writes.
pub const overrides_version: u32 = 1;

/// One official role as shipped.
pub const Source = struct {
    /// The file stem, which the JSON's own `key` has to equal.
    key: []const u8,
    json: []const u8,
    /// The instructions. Kept out of the JSON so the prose can be read and
    /// reviewed as prose.
    md: []const u8,
};

const shipped = @import("polter_official");

/// Every official role this build carries, in the order the menu shows them.
pub const sources: [shipped.roles.len]Source = blk: {
    var out: [shipped.roles.len]Source = undefined;
    for (shipped.roles, 0..) |r, i| out[i] = .{ .key = r.key, .json = r.json, .md = r.md };
    break :blk out;
};

pub fn isKey(key: []const u8) bool {
    return isKeyIn(&sources, key);
}

pub fn isKeyIn(list: []const Source, key: []const u8) bool {
    for (list) |s| {
        if (std.mem.eql(u8, s.key, key)) return true;
    }
    return false;
}

/// Read one shipped role. The build runs this over every file in `roles/`,
/// so a file this refuses is a build that fails.
pub fn parseSource(aa: Allocator, src: Source) ParseError!Persona {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, src.json, .{}) catch
        return error.Malformed;
    // The instructions are the `.md`; a second copy in the JSON would be
    // two texts with nothing saying which one is in use.
    switch (parsed) {
        .object => |o| if (o.get("instructions") != null) return error.BadField,
        else => return error.BadField,
    }
    var ignored: std.ArrayList([]const u8) = .empty;
    var p = try persona.personaOf(aa, parsed, &ignored);
    if (!std.mem.eql(u8, p.key, src.key)) return error.BadField;
    // An official role that asks to deny a floor tool is a mistake in the
    // file, and here there is nobody to show `ignored_denies` to.
    if (ignored.items.len > 0) return error.BadField;

    const text = std.mem.trim(u8, src.md, " \t\r\n");
    if (text.len == 0) return error.Incomplete;
    p.instructions = text;
    p.official = .pristine;
    return p;
}

// ------------------------------------------------------------- the fields

/// A field of an official role a person may change.
pub const Target = union(enum) {
    instructions,
    watch,
    open,
    quiet_ms,
    cli: struct { key: []const u8, part: Part },

    pub const Part = enum { present, skills, mcp, model, args };
};

/// A field's value. Which arm a field has is decided by its path, never by
/// what the file happens to hold there.
pub const Value = union(enum) {
    text: ?[]const u8,
    flag: bool,
    open: Polter.Open,
    ms: ?u64,
    selection: Selection,
    strings: []const []const u8,

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            // No text and empty text are one thing to the person typing.
            .text => |t| std.mem.eql(u8, t orelse "", b.text orelse ""),
            .flag => |f| f == b.flag,
            .open => |o| o == b.open,
            .ms => |m| m == b.ms,
            .selection => |s| s.default == b.selection.default and
                sameSet(s.except, b.selection.except),
            .strings => |l| sameList(l, b.strings),
        };
    }
};

fn sameList(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// Exceptions are a set: the order they were ticked in says nothing.
fn sameSet(a: []const []const u8, b: []const []const u8) bool {
    for (a) |x| if (!has(b, x)) return false;
    for (b) |x| if (!has(a, x)) return false;
    return true;
}

fn has(list: []const []const u8, item: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, item)) return true;
    }
    return false;
}

pub const Field = struct {
    path: []const u8,
    value: Value,
    /// The official value when this was changed.
    base: Value,
};

/// What a path names, or null when it names nothing this build knows.
pub fn targetOf(path: []const u8) ?Target {
    if (std.mem.eql(u8, path, "instructions")) return .instructions;
    if (std.mem.eql(u8, path, "polter.watch")) return .watch;
    if (std.mem.eql(u8, path, "polter.open")) return .open;
    if (std.mem.eql(u8, path, "polter.quiet_ms")) return .quiet_ms;

    const rest = if (std.mem.startsWith(u8, path, "clis.")) path["clis.".len..] else return null;
    // A CLI key has no dot in it (`persona.isValidKey`), so the first dot,
    // if there is one, ends it.
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse {
        if (!persona.isValidKey(rest)) return null;
        return .{ .cli = .{ .key = rest, .part = .present } };
    };
    const key = rest[0..dot];
    if (!persona.isValidKey(key)) return null;
    const part = std.meta.stringToEnum(Target.Part, rest[dot + 1 ..]) orelse return null;
    // Presence is the bare `clis.<key>`; `clis.<key>.present` is not a path.
    if (part == .present) return null;
    return .{ .cli = .{ .key = key, .part = part } };
}

fn pathOf(aa: Allocator, t: Target) Allocator.Error![]const u8 {
    return switch (t) {
        .instructions => "instructions",
        .watch => "polter.watch",
        .open => "polter.open",
        .quiet_ms => "polter.quiet_ms",
        .cli => |c| if (c.part == .present)
            try std.fmt.allocPrint(aa, "clis.{s}", .{c.key})
        else
            try std.fmt.allocPrint(aa, "clis.{s}.{t}", .{ c.key, c.part }),
    };
}

/// What `p` holds in the field `t`. A CLI the role does not have answers
/// with what a new one would start with.
pub fn get(p: Persona, t: Target) Value {
    return switch (t) {
        .instructions => .{ .text = p.instructions },
        .watch => .{ .flag = p.polter.watch },
        .open => .{ .open = p.polter.open },
        .quiet_ms => .{ .ms = p.polter.quiet_ms },
        .cli => |c| blk: {
            const choice: CliChoice = p.cli(c.key) orelse .{ .cli = c.key };
            break :blk switch (c.part) {
                .present => .{ .flag = p.cli(c.key) != null },
                .skills => .{ .selection = choice.skills },
                .mcp => .{ .selection = choice.mcp },
                .model => .{ .text = choice.model },
                .args => .{ .strings = choice.args },
            };
        },
    };
}

/// `p` with `fields` laid over it.
fn apply(aa: Allocator, p: Persona, fields: []const Field) Allocator.Error!Persona {
    var out = p;
    var clis: std.ArrayList(CliChoice) = .empty;
    try clis.appendSlice(aa, p.clis);

    // Which CLIs there are first, so that a setting for one that was added
    // has somewhere to go and one for a CLI that was taken out goes nowhere.
    for (fields) |f| {
        const c = switch (targetOf(f.path) orelse continue) {
            .cli => |c| c,
            else => continue,
        };
        if (c.part != .present) continue;
        const at = indexOfCli(clis.items, c.key);
        if (f.value.flag) {
            if (at == null) try clis.append(aa, .{ .cli = c.key });
        } else if (at) |i| {
            _ = clis.orderedRemove(i);
        }
    }

    for (fields) |f| switch (targetOf(f.path) orelse continue) {
        .instructions => out.instructions = f.value.text,
        .watch => out.polter.watch = f.value.flag,
        .open => out.polter.open = f.value.open,
        .quiet_ms => out.polter.quiet_ms = f.value.ms,
        .cli => |c| {
            const i = indexOfCli(clis.items, c.key) orelse continue;
            switch (c.part) {
                .present => {},
                .skills => clis.items[i].skills = f.value.selection,
                .mcp => clis.items[i].mcp = f.value.selection,
                .model => clis.items[i].model = f.value.text,
                .args => clis.items[i].args = f.value.strings,
            }
        },
    };

    out.clis = try clis.toOwnedSlice(aa);
    return out;
}

fn indexOfCli(list: []const CliChoice, key: []const u8) ?usize {
    for (list, 0..) |c, i| {
        if (std.mem.eql(u8, c.cli, key)) return i;
    }
    return null;
}

/// Whether the official role has moved under `f` since it was written.
fn isStale(official_role: Persona, f: Field) bool {
    const t = targetOf(f.path) orelse return true;
    return !f.base.eql(get(official_role, t));
}

/// `fields` as if each had been written against today's official role:
/// what the person says when told the official text has moved and they
/// answer "I know, keep mine". The values are theirs and do not move.
pub fn rebased(aa: Allocator, official_role: Persona, fields: []const Field) Allocator.Error![]const Field {
    const out = try aa.alloc(Field, fields.len);
    for (fields, out) |f, *dst| {
        dst.* = f;
        if (targetOf(f.path)) |t| dst.base = get(official_role, t);
    }
    return out;
}

/// What only Polter decides about an official role, in the order checked.
pub const Locked = enum { name, description, standing, legacy };

/// The first thing `edited` changes that an official role does not let
/// anybody change, or null when it changes none.
pub fn lockedChange(official_role: Persona, edited: Persona) ?Locked {
    if (!std.mem.eql(u8, official_role.name, edited.name)) return .name;
    if (!(Value{ .text = official_role.description }).eql(.{ .text = edited.description })) return .description;
    if (!Polter.userOnlyEql(official_role.polter, edited.polter)) return .standing;

    const a = official_role;
    const b = edited;
    if (!(Value{ .text = a.prompt }).eql(.{ .text = b.prompt })) return .legacy;
    if (!sameList(a.skills, b.skills) or !sameList(a.mcp, b.mcp)) return .legacy;
    if ((a.tools.allow == null) != (b.tools.allow == null)) return .legacy;
    if (a.tools.allow) |x| if (!sameList(x, b.tools.allow.?)) return .legacy;
    if (!sameList(a.tools.deny, b.tools.deny)) return .legacy;
    if (!sameList(a.hint_disable_host_plugins, b.hint_disable_host_plugins)) return .legacy;
    if (!(Value{ .text = a.hint_model }).eql(.{ .text = b.hint_model })) return .legacy;
    return null;
}

/// The overrides that turn `official_role` into `edited`.
///
/// A field the person had already changed, and has left as it was, keeps
/// the `base` it was written with: saying again what they said before does
/// not make it any newer, and the notice that the official text has moved
/// under it should not go away because they saved something else.
pub fn diff(
    aa: Allocator,
    official_role: Persona,
    edited: Persona,
    existing: []const Field,
) Allocator.Error![]const Field {
    var out: std.ArrayList(Field) = .empty;

    var targets: std.ArrayList(Target) = .empty;
    try targets.appendSlice(aa, &.{ .instructions, .watch, .open, .quiet_ms });
    for (official_role.clis) |c| try targets.append(aa, .{ .cli = .{ .key = c.cli, .part = .present } });
    for (edited.clis) |c| {
        if (official_role.cli(c.cli) == null)
            try targets.append(aa, .{ .cli = .{ .key = c.cli, .part = .present } });
        // Only for a CLI the edit keeps: one it took out has no settings to
        // remember.
        for ([_]Target.Part{ .skills, .mcp, .model, .args }) |part|
            try targets.append(aa, .{ .cli = .{ .key = c.cli, .part = part } });
    }

    for (targets.items) |t| {
        const theirs = get(edited, t);
        const ours = get(official_role, t);
        if (theirs.eql(ours)) continue;
        const path = try pathOf(aa, t);
        const base: Value = for (existing) |e| {
            if (std.mem.eql(u8, e.path, path) and e.value.eql(theirs)) break e.base;
        } else ours;
        try out.append(aa, .{ .path = path, .value = theirs, .base = base });
    }
    return try out.toOwnedSlice(aa);
}

// --------------------------------------------------------------- the file

/// What reading `official-overrides.json` came to.
///
/// Three answers, because they want three different things done: no file is
/// the ordinary state and means nothing was changed; a file that could not
/// be read means something may have been changed and nobody here knows
/// what.
pub const Read = union(enum) {
    absent,
    /// Why not, in words for the person.
    unreadable: []const u8,
    bytes: []const u8,
};

const Doc = struct {
    roles: ?std.json.ObjectMap,
    skills: ?std.json.ObjectMap,
};

const DocError = error{Unreadable};

fn docOf(aa: Allocator, bytes: []const u8) DocError!std.json.ObjectMap {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, bytes, .{}) catch
        return error.Unreadable;
    const root = switch (parsed) {
        .object => |o| o,
        else => return error.Unreadable,
    };
    switch (root.get("version") orelse return error.Unreadable) {
        .integer => |n| if (n != overrides_version) return error.Unreadable,
        else => return error.Unreadable,
    }
    for ([_][]const u8{ "roles", "skills" }) |section| {
        if (root.get(section)) |v| switch (v) {
            .object => {},
            else => return error.Unreadable,
        };
    }
    return root;
}

fn sectionOf(root: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    return switch (root.get(name) orelse return null) {
        .object => |o| o,
        else => null,
    };
}

pub const not_json = "official-overrides.json could not be read as an overrides file";

/// Why the file as a whole could not be used, or null when it could (or is
/// not there). One entry in it being wrong is not this: that is said on the
/// role it belongs to.
pub fn readError(aa: Allocator, read: Read) ?[]const u8 {
    return switch (read) {
        .absent => null,
        .unreadable => |why| why,
        .bytes => |b| if (docOf(aa, b)) |_| null else |_| not_json,
    };
}

/// The fields a person changed in the role `key`.
pub const RoleRead = union(enum) {
    /// Nothing changed.
    none,
    /// Something is written for this role and it could not be read.
    unknown: []const u8,
    fields: []const Field,
};

pub fn roleFields(aa: Allocator, read: Read, key: []const u8) Allocator.Error!RoleRead {
    const bytes = switch (read) {
        .absent => return .none,
        .unreadable => |why| return .{ .unknown = why },
        .bytes => |b| b,
    };
    const root = docOf(aa, bytes) catch return .{ .unknown = not_json };
    const roles = sectionOf(root, "roles") orelse return .none;
    const entry = switch (roles.get(key) orelse return .none) {
        .object => |o| o,
        else => return .{ .unknown = "what is written for this role is not an object" },
    };

    var out: std.ArrayList(Field) = .empty;
    var it = entry.iterator();
    while (it.next()) |kv| {
        const path = kv.key_ptr.*;
        const t = targetOf(path) orelse
            return .{ .unknown = try std.fmt.allocPrint(aa, "\"{s}\" is not a field this version of Polter knows", .{path}) };
        const pair = switch (kv.value_ptr.*) {
            .object => |o| o,
            else => return .{ .unknown = try std.fmt.allocPrint(aa, "\"{s}\" is not written as a value and its base", .{path}) },
        };
        const value = valueOf(aa, t, pair.get("value") orelse
            return .{ .unknown = try std.fmt.allocPrint(aa, "\"{s}\" has no value", .{path}) }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadField => return .{ .unknown = try std.fmt.allocPrint(aa, "the value of \"{s}\" does not read", .{path}) },
        };
        // Without a base there is no telling whether the official text has
        // moved since, and that is said rather than guessed.
        const base = valueOf(aa, t, pair.get("base") orelse
            return .{ .unknown = try std.fmt.allocPrint(aa, "\"{s}\" has no base, so it cannot be compared with the official version", .{path}) }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadField => return .{ .unknown = try std.fmt.allocPrint(aa, "the base of \"{s}\" does not read", .{path}) },
        };
        try out.append(aa, .{ .path = path, .value = value, .base = base });
    }
    if (out.items.len == 0) return .none;
    return .{ .fields = try out.toOwnedSlice(aa) };
}

const ValueError = error{ BadField, OutOfMemory };

fn valueOf(aa: Allocator, t: Target, v: std.json.Value) ValueError!Value {
    const kind: std.meta.Tag(Value) = std.meta.activeTag(get(.{ .key = "", .name = "" }, t));
    return switch (kind) {
        .text => .{ .text = switch (v) {
            .string => |s| s,
            .null => null,
            else => return error.BadField,
        } },
        .flag => .{ .flag = switch (v) {
            .bool => |b| b,
            else => return error.BadField,
        } },
        .open => .{ .open = switch (v) {
            .string => |s| std.meta.stringToEnum(Polter.Open, s) orelse return error.BadField,
            else => return error.BadField,
        } },
        .ms => .{
            .ms = switch (v) {
                // The floor `persona.polterOf` holds a role in the file to.
                .integer => |n| if (n >= 1000) @intCast(n) else return error.BadField,
                .null => null,
                else => return error.BadField,
            },
        },
        .selection => .{ .selection = switch (v) {
            .object => |o| .{
                .default = switch (o.get("default") orelse return error.BadField) {
                    .bool => |b| b,
                    else => return error.BadField,
                },
                .except = try stringsOf(aa, o.get("except") orelse return error.BadField),
            },
            else => return error.BadField,
        } },
        .strings => .{ .strings = try stringsOf(aa, v) },
    };
}

fn stringsOf(aa: Allocator, v: std.json.Value) ValueError![]const []const u8 {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadField,
    };
    const out = try aa.alloc([]const u8, arr.items.len);
    for (arr.items, out) |item, *dst| dst.* = switch (item) {
        .string => |s| s,
        else => return error.BadField,
    };
    return out;
}

fn jsonOf(aa: Allocator, v: Value) Allocator.Error!std.json.Value {
    return switch (v) {
        .text => |t| if (t) |s| .{ .string = s } else .null,
        .flag => |f| .{ .bool = f },
        .open => |o| .{ .string = @tagName(o) },
        .ms => |m| if (m) |n| .{ .integer = @intCast(n) } else .null,
        .selection => |s| blk: {
            var o: std.json.ObjectMap = .empty;
            try o.put(aa, "default", .{ .bool = s.default });
            try o.put(aa, "except", try jsonStrings(aa, s.except));
            break :blk .{ .object = o };
        },
        .strings => |l| try jsonStrings(aa, l),
    };
}

fn jsonStrings(aa: Allocator, list: []const []const u8) Allocator.Error!std.json.Value {
    var arr: std.json.Array = .init(aa);
    for (list) |s| try arr.append(.{ .string = s });
    return .{ .array = arr };
}

/// Every official role as it is in effect: the shipped one with what the
/// person changed laid over it, and `official` saying which of those it is.
pub fn effective(aa: Allocator, list: []const Source, read: Read) ParseError![]const Persona {
    const out = try aa.alloc(Persona, list.len);
    for (list, out) |src, *dst| {
        const shipped_role = try parseSource(aa, src);
        dst.* = shipped_role;
        switch (try roleFields(aa, read, src.key)) {
            .none => {},
            // What they changed is not known, so what is in effect is the
            // one thing that is: the official role. A half-applied override
            // would look exactly like a whole one.
            .unknown => |why| dst.official = .{
                .state = .unknown,
                .overridden = &.{},
                .stale = &.{},
                .reason = why,
            },
            .fields => |fields| {
                dst.* = try apply(aa, shipped_role, fields);
                var overridden: std.ArrayList([]const u8) = .empty;
                var stale: std.ArrayList([]const u8) = .empty;
                for (fields) |f| {
                    try overridden.append(aa, f.path);
                    if (isStale(shipped_role, f)) try stale.append(aa, f.path);
                }
                dst.official = .{
                    .state = if (stale.items.len > 0) .modified_stale else .modified,
                    .overridden = try overridden.toOwnedSlice(aa),
                    .stale = try stale.toOwnedSlice(aa),
                    .reason = null,
                };
            },
        }
    }
    return out;
}

/// The whole library: the official roles in effect, then the person's own.
/// `file` is `personas.json`, or null when there is none.
pub fn assemble(aa: Allocator, file: ?[]const u8, list: []const Source, read: Read) ParseError!persona.Set {
    const roles = try effective(aa, list, read);
    const bytes = file orelse return .{ .personas = roles };
    return try persona.parseFileLeaky(aa, bytes, roles);
}

// ----------------------------------------------------- changing the file

pub const EditError = error{
    /// The file is there and does not read. Nothing is written over it:
    /// taking one entry out of a file nobody can read is not possible, and
    /// replacing it would drop every other change in it without a word.
    Unreadable,
    OutOfMemory,
};

fn rootFor(aa: Allocator, read: Read) EditError!std.json.ObjectMap {
    switch (read) {
        .absent => {
            var root: std.json.ObjectMap = .empty;
            try root.put(aa, "version", .{ .integer = overrides_version });
            return root;
        },
        .unreadable => return error.Unreadable,
        .bytes => |b| return docOf(aa, b) catch error.Unreadable,
    }
}

fn sectionFor(aa: Allocator, root: *std.json.ObjectMap, name: []const u8) Allocator.Error!*std.json.ObjectMap {
    const gop = try root.getOrPut(aa, name);
    if (!gop.found_existing or gop.value_ptr.* != .object)
        gop.value_ptr.* = .{ .object = .empty };
    return &gop.value_ptr.object;
}

fn render(aa: Allocator, root: std.json.ObjectMap) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(aa);
    out.writer.print("{f}\n", .{std.json.fmt(std.json.Value{ .object = root }, .{ .whitespace = .indent_2 })}) catch
        return error.OutOfMemory;
    return out.written();
}

/// The file with `key`'s overrides set to `fields`; none takes the entry
/// out. Every other entry is carried through as it was written, including
/// ones this build cannot read.
pub fn withRole(aa: Allocator, read: Read, key: []const u8, fields: []const Field) EditError![]const u8 {
    var root = try rootFor(aa, read);
    const roles = try sectionFor(aa, &root, "roles");
    if (fields.len == 0) {
        _ = roles.orderedRemove(key);
    } else {
        var entry: std.json.ObjectMap = .empty;
        for (fields) |f| {
            var pair: std.json.ObjectMap = .empty;
            try pair.put(aa, "value", try jsonOf(aa, f.value));
            try pair.put(aa, "base", try jsonOf(aa, f.base));
            try entry.put(aa, f.path, .{ .object = pair });
        }
        try roles.put(aa, key, .{ .object = entry });
    }
    return try render(aa, root);
}

/// Whether anything at all is written for `key` -- readable or not. What
/// "restore" is offered on.
pub fn hasRole(aa: Allocator, read: Read, key: []const u8) bool {
    const bytes = switch (read) {
        .absent => return false,
        // Not known, and "restore" is how a person gets out of that.
        .unreadable => return true,
        .bytes => |b| b,
    };
    const root = docOf(aa, bytes) catch return true;
    const roles = sectionOf(root, "roles") orelse return false;
    return roles.get(key) != null;
}

/// What the shipped skill `name` hashed to when the person's copy of it was
/// saved.
pub const SkillBase = union(enum) {
    /// Nothing recorded: a copy with no record is one the person put there
    /// by hand, and whether the official text has moved since is not known.
    none,
    unknown: []const u8,
    hash: []const u8,
};

pub fn skillBase(aa: Allocator, read: Read, name: []const u8) SkillBase {
    const bytes = switch (read) {
        .absent => return .none,
        .unreadable => |why| return .{ .unknown = why },
        .bytes => |b| b,
    };
    const root = docOf(aa, bytes) catch return .{ .unknown = not_json };
    const skills = sectionOf(root, "skills") orelse return .none;
    const entry = switch (skills.get(name) orelse return .none) {
        .object => |o| o,
        else => return .{ .unknown = "what is written for this skill is not an object" },
    };
    return switch (entry.get("base") orelse return .{ .unknown = "the record for this skill has no base" }) {
        .string => |s| .{ .hash = s },
        else => .{ .unknown = "the base recorded for this skill is not text" },
    };
}

/// The file with the record for the skill `name` set to `base`, or taken
/// out when `base` is null.
pub fn withSkillBase(aa: Allocator, read: Read, name: []const u8, base: ?[]const u8) EditError![]const u8 {
    var root = try rootFor(aa, read);
    const skills = try sectionFor(aa, &root, "skills");
    if (base) |hash| {
        var entry: std.json.ObjectMap = .empty;
        try entry.put(aa, "base", .{ .string = hash });
        try skills.put(aa, name, .{ .object = entry });
    } else {
        _ = skills.orderedRemove(name);
    }
    return try render(aa, root);
}

/// A key for a role the person's file holds under an official key, so they
/// can keep it as their own: `<key>-mine`, then `-mine-2` and up, cut to fit.
pub fn adoptedKey(aa: Allocator, key: []const u8, taken: []const Persona) Allocator.Error![]const u8 {
    var n: usize = 1;
    while (true) : (n += 1) {
        const suffix = if (n == 1) try aa.dupe(u8, "-mine") else try std.fmt.allocPrint(aa, "-mine-{d}", .{n});
        const room = persona.max_key_len - suffix.len;
        const candidate = try std.mem.concat(aa, u8, &.{ key[0..@min(key.len, room)], suffix });
        const clash = for (taken) |p| {
            if (std.mem.eql(u8, p.key, candidate)) break true;
        } else false;
        if (!clash) return candidate;
    }
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// A made-up official role, so a test can change "the official version"
/// under an override without touching what ships.
fn fakeSource(comptime md: []const u8, comptime model: []const u8) Source {
    return .{
        .key = "polter-supervisor",
        .json = "{\"key\":\"polter-supervisor\",\"name\":\"Polter Supervisor\",\"description\":\"d\"," ++
            "\"clis\":{\"claude-code\":{\"skills\":{\"default\":false,\"except\":[\"skill:a\"]}," ++
            "\"mcp\":{\"default\":false,\"except\":[]}" ++ model ++ "}},\"polter\":{\"supervisor\":true}}",
        .md = md,
    };
}

test "official: every shipped role reads, under its own file name, with its prose" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try testing.expect(sources.len >= 2);
    for (sources) |src| {
        const p = parseSource(aa, src) catch |err| {
            std.debug.print("\nroles/{s}.json failed to parse: {}\n", .{ src.key, err });
            return err;
        };
        try testing.expectEqualStrings(src.key, p.key);
        try testing.expect(p.official != null);
        try testing.expectEqual(persona.Official.Status.pristine, p.official.?.state);
        try testing.expect(p.instructions.?.len > 0);
        try testing.expect(p.description != null);
        // No official role grants anything but the supervisor's own standing.
        try testing.expect(!p.polter.may_authorise and !p.polter.shielded);
        try testing.expectEqual(std.mem.eql(u8, p.key, persona.supervisor_key), p.polter.supervisor);
    }
    try testing.expect(isKey(persona.supervisor_key));
    try testing.expect(isKey(persona.tester_key));
    try testing.expect(!isKey("archer"));
}

test "official: the tester is a watched worker with one skill and no MCP" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const roles = try effective(aa, &sources, .absent);
    const t = for (roles) |p| {
        if (std.mem.eql(u8, p.key, persona.tester_key)) break p;
    } else return error.TestExpectedEqual;
    try testing.expectEqualStrings("Polter Tester", t.name);
    try testing.expect(t.polter.watch and !t.polter.supervisor);
    try testing.expectEqual(Polter.Open.auto, t.polter.open);
    const c = t.cli("claude-code").?;
    try testing.expect(!c.skills.default and !c.mcp.default);
    try testing.expectEqual(@as(usize, 1), c.skills.except.len);
    try testing.expectEqualStrings("skill:polter-operating-a-terminal", c.skills.except[0]);
    try testing.expectEqual(@as(usize, 0), c.mcp.except.len);
    try testing.expect(std.mem.indexOf(u8, t.instructions.?, "You test; you do not fix") != null);
    try testing.expect(std.mem.indexOf(u8, t.instructions.?, "task_progress") != null);
}

test "official: a shipped file that is wrong is refused, each way it can be" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const good: Source = .{ .key = "a", .json = "{\"key\":\"a\",\"name\":\"A\"}", .md = "text" };
    _ = try parseSource(aa, good);

    var s = good;
    s.json = "{\"key\":\"a\",\"name\":";
    try testing.expectError(error.Malformed, parseSource(aa, s));
    s = good;
    s.key = "b";
    try testing.expectError(error.BadField, parseSource(aa, s));
    s = good;
    s.json = "{\"key\":\"a\",\"name\":\"A\",\"instructions\":\"x\"}";
    try testing.expectError(error.BadField, parseSource(aa, s));
    s = good;
    s.md = " \n\n";
    try testing.expectError(error.Incomplete, parseSource(aa, s));
    s = good;
    s.json = "{\"key\":\"a\",\"name\":\"A\",\"tools\":{\"deny\":[\"me\"]}}";
    try testing.expectError(error.BadField, parseSource(aa, s));
}

test "official: an untouched field follows the new version, a changed one stays the person's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const v1 = [_]Source{fakeSource("old prose", "")};
    const shipped_v1 = (try effective(aa, &v1, .absent))[0];

    // The person changes the model and nothing else.
    var edited = shipped_v1;
    var clis = [_]CliChoice{shipped_v1.clis[0]};
    clis[0].model = "opus";
    edited.clis = &clis;
    const fields = try diff(aa, shipped_v1, edited, &.{});
    try testing.expectEqual(@as(usize, 1), fields.len);
    try testing.expectEqualStrings("clis.claude-code.model", fields[0].path);
    const file = try withRole(aa, .absent, "polter-supervisor", fields);

    const now = (try effective(aa, &v1, .{ .bytes = file }))[0];
    try testing.expectEqual(persona.Official.Status.modified, now.official.?.state);
    try testing.expectEqualStrings("opus", now.cli("claude-code").?.model.?);
    try testing.expectEqualStrings("old prose", now.instructions.?);

    // The next release rewrites the prose: theirs keeps the model, and takes
    // the new prose, and nothing they changed has moved under them.
    const v2 = [_]Source{fakeSource("new prose", "")};
    const later = (try effective(aa, &v2, .{ .bytes = file }))[0];
    try testing.expectEqualStrings("new prose", later.instructions.?);
    try testing.expectEqualStrings("opus", later.cli("claude-code").?.model.?);
    try testing.expectEqual(persona.Official.Status.modified, later.official.?.state);
    try testing.expectEqual(@as(usize, 0), later.official.?.stale.len);

    // A release that changes the very field they changed: still theirs, and
    // said to be behind.
    const v3 = [_]Source{fakeSource("new prose", ",\"model\":\"sonnet\"")};
    const behind = (try effective(aa, &v3, .{ .bytes = file }))[0];
    try testing.expectEqualStrings("opus", behind.cli("claude-code").?.model.?);
    try testing.expectEqual(persona.Official.Status.modified_stale, behind.official.?.state);
    try testing.expectEqual(@as(usize, 1), behind.official.?.stale.len);
    try testing.expectEqualStrings("clis.claude-code.model", behind.official.?.stale[0]);
}

test "official: the four states are four, and not knowing is not the same as nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const list = [_]Source{fakeSource("prose", "")};
    const S = persona.Official.Status;

    try testing.expectEqual(S.pristine, (try effective(aa, &list, .absent))[0].official.?.state);
    // A file with nothing for this role is also nothing.
    try testing.expectEqual(S.pristine, (try effective(aa, &list, .{ .bytes = "{\"version\":1,\"roles\":{}}" }))[0].official.?.state);

    const unknowns = [_]Read{
        .{ .unreadable = "permission denied" },
        .{ .bytes = "not json" },
        .{ .bytes = "{\"version\":99,\"roles\":{}}" },
        .{ .bytes = "{\"version\":1,\"roles\":{\"polter-supervisor\":7}}" },
        // A value with no base: applied or not, nobody could say whether
        // the official text has moved since.
        .{ .bytes = "{\"version\":1,\"roles\":{\"polter-supervisor\":{\"instructions\":{\"value\":\"x\"}}}}" },
        .{ .bytes = "{\"version\":1,\"roles\":{\"polter-supervisor\":{\"name\":{\"value\":\"x\",\"base\":\"y\"}}}}" },
        .{ .bytes = "{\"version\":1,\"roles\":{\"polter-supervisor\":{\"polter.watch\":{\"value\":\"yes\",\"base\":false}}}}" },
    };
    for (unknowns) |read| {
        const p = (try effective(aa, &list, read))[0];
        try testing.expectEqual(S.unknown, p.official.?.state);
        try testing.expect(p.official.?.reason != null);
        // And what is in effect is the official role, whole.
        try testing.expectEqualStrings("prose", p.instructions.?);
        try testing.expect(!p.polter.watch);
    }
}

test "official: no path reaches a name, a key, or what grants a terminal something" {
    for ([_][]const u8{
        "name",                 "key",                "description", "polter.supervisor",
        "polter.may_authorise", "polter.shielded",    "official",    "builtin",
        "clis.claude-code.cli", "clis.Bad Key.model", "clis..model", "clis.claude-code.present",
        "tools",                "prompt",             "skills",      "",
    }) |path| {
        try testing.expect(targetOf(path) == null);
    }
    try testing.expect(targetOf("clis.claude-code") != null);
    try testing.expect(targetOf("clis.claude-code.args") != null);
}

test "official: a locked field changed is named, an open one is not locked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const base = (try effective(aa, &.{fakeSource("prose", "")}, .absent))[0];

    try testing.expectEqual(@as(?Locked, null), lockedChange(base, base));
    var e = base;
    e.instructions = "mine";
    e.polter.watch = true;
    e.polter.open = .tab;
    e.polter.quiet_ms = 5000;
    e.clis = &.{};
    try testing.expectEqual(@as(?Locked, null), lockedChange(base, e));

    e = base;
    e.name = "Mine";
    try testing.expectEqual(@as(?Locked, .name), lockedChange(base, e));
    e = base;
    e.description = "other";
    try testing.expectEqual(@as(?Locked, .description), lockedChange(base, e));
    for ([_][]const u8{ "supervisor", "may_authorise", "shielded" }) |field| {
        e = base;
        inline for (.{ "supervisor", "may_authorise", "shielded" }) |name| {
            if (std.mem.eql(u8, name, field)) @field(e.polter, name) = !@field(e.polter, name);
        }
        try testing.expectEqual(@as(?Locked, .standing), lockedChange(base, e));
    }
    e = base;
    e.tools.deny = &.{"terminal_send"};
    try testing.expectEqual(@as(?Locked, .legacy), lockedChange(base, e));
}

test "official: adding and removing a CLI is an override like any other" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const list = [_]Source{fakeSource("prose", "")};
    const base = (try effective(aa, &list, .absent))[0];

    var e = base;
    e.clis = &.{.{ .cli = "codex", .model = "gpt", .args = &.{"--x"} }};
    const fields = try diff(aa, base, e, &.{});
    const file = try withRole(aa, .absent, base.key, fields);
    const now = (try effective(aa, &list, .{ .bytes = file }))[0];
    try testing.expect(now.cli("claude-code") == null);
    try testing.expectEqualStrings("gpt", now.cli("codex").?.model.?);
    try testing.expectEqualStrings("--x", now.cli("codex").?.args[0]);

    // Saved again as it now stands: the same overrides, not more of them.
    const again = try diff(aa, base, now, fields);
    try testing.expectEqual(fields.len, again.len);

    // Put back the way it shipped: nothing left to remember.
    try testing.expectEqual(@as(usize, 0), (try diff(aa, base, base, fields)).len);
}

test "official: saying the same thing again keeps the base it was first said against" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const v1 = (try effective(aa, &.{fakeSource("one", "")}, .absent))[0];
    var e = v1;
    e.instructions = "mine";
    const first = try diff(aa, v1, e, &.{});
    try testing.expectEqualStrings("one", first[0].base.text.?);

    // The official prose moves; the person saves a change to something else.
    const v2 = (try effective(aa, &.{fakeSource("two", "")}, .absent))[0];
    e.polter.watch = true;
    const second = try diff(aa, v2, e, first);
    const kept = for (second) |f| {
        if (std.mem.eql(u8, f.path, "instructions")) break f;
    } else return error.TestExpectedEqual;
    try testing.expectEqualStrings("one", kept.base.text.?);
    try testing.expect(isStale(v2, kept));

    // Rewriting the prose itself is a new statement, against today's text.
    e.instructions = "mine, again";
    const third = try diff(aa, v2, e, first);
    for (third) |f| {
        if (std.mem.eql(u8, f.path, "instructions")) try testing.expectEqualStrings("two", f.base.text.?);
    }
}

test "official: keeping mine after the official text moved is changed, and no longer behind" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const v1 = (try effective(aa, &.{fakeSource("one", "")}, .absent))[0];
    var e = v1;
    e.instructions = "mine";
    const file = try withRole(aa, .absent, v1.key, try diff(aa, v1, e, &.{}));

    const v2 = [_]Source{fakeSource("two", "")};
    const shipped_v2 = (try effective(aa, &v2, .absent))[0];
    const behind = (try effective(aa, &v2, .{ .bytes = file }))[0];
    try testing.expectEqual(persona.Official.Status.modified_stale, behind.official.?.state);

    const fields = (try roleFields(aa, .{ .bytes = file }, v1.key)).fields;
    const kept = try withRole(aa, .{ .bytes = file }, v1.key, try rebased(aa, shipped_v2, fields));
    const now = (try effective(aa, &v2, .{ .bytes = kept }))[0];
    try testing.expectEqual(persona.Official.Status.modified, now.official.?.state);
    try testing.expectEqualStrings("mine", now.instructions.?);

    // And it is only today's text that was accepted: the next move is said
    // again.
    const v3 = [_]Source{fakeSource("three", "")};
    try testing.expectEqual(persona.Official.Status.modified_stale, (try effective(aa, &v3, .{ .bytes = kept }))[0].official.?.state);
}

test "official: taking one role's overrides out leaves every other entry as written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // One readable entry, one this build cannot read, and a skill record.
    const file =
        \\{"version":1,
        \\ "roles":{"polter-supervisor":{"polter.watch":{"value":true,"base":false}},
        \\          "polter-tester":{"from.the.future":{"value":1,"base":2}}},
        \\ "skills":{"supervising":{"base":"abc"}}}
    ;
    const read: Read = .{ .bytes = file };
    try testing.expect(hasRole(aa, read, "polter-supervisor"));
    try testing.expect(hasRole(aa, read, "polter-tester"));
    try testing.expect(!hasRole(aa, read, "nobody"));

    const after = try withRole(aa, read, "polter-tester", &.{});
    const next: Read = .{ .bytes = after };
    try testing.expect(!hasRole(aa, next, "polter-tester"));
    try testing.expect(hasRole(aa, next, "polter-supervisor"));
    try testing.expect((try roleFields(aa, next, "polter-supervisor")) == .fields);
    try testing.expectEqualStrings("abc", skillBase(aa, next, "supervising").hash);

    // A file nobody can read is not edited, and not replaced.
    try testing.expectError(error.Unreadable, withRole(aa, .{ .bytes = "{{{" }, "polter-tester", &.{}));
    try testing.expectError(error.Unreadable, withRole(aa, .{ .unreadable = "x" }, "polter-tester", &.{}));
    try testing.expectError(error.Unreadable, withSkillBase(aa, .{ .bytes = "[]" }, "supervising", null));
    try testing.expect(hasRole(aa, .{ .bytes = "{{{" }, "polter-tester"));
}

test "official: a skill's base is recorded, read back, and not known when it was never written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try testing.expect(skillBase(aa, .absent, "supervising") == .none);
    const file = try withSkillBase(aa, .absent, "supervising", "abc");
    const read: Read = .{ .bytes = file };
    try testing.expectEqualStrings("abc", skillBase(aa, read, "supervising").hash);
    try testing.expect(skillBase(aa, read, "reading-a-terminal") == .none);
    try testing.expect(skillBase(aa, .{ .bytes = "nope" }, "supervising") == .unknown);
    try testing.expect(skillBase(aa, .{ .unreadable = "x" }, "supervising") == .unknown);

    const gone = try withSkillBase(aa, read, "supervising", null);
    try testing.expect(skillBase(aa, .{ .bytes = gone }, "supervising") == .none);
}

test "official: a key to keep a shadowed role under fits, and steps past what is taken" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try testing.expectEqualStrings("polter-tester-mine", try adoptedKey(aa, "polter-tester", &.{}));
    const taken = [_]Persona{.{ .key = "polter-tester-mine", .name = "x" }};
    try testing.expectEqualStrings("polter-tester-mine-2", try adoptedKey(aa, "polter-tester", &taken));
    const long = try adoptedKey(aa, "a" ** persona.max_key_len, &.{});
    try testing.expect(persona.isValidKey(long));
}
