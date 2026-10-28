//! Squad templates: which roles work together on a task, under what
//! names, and what each does differently from the role it is built on
//! (task 2449, squads slice S3; the plan is `2433/PLAN.md` §2.4-2.6).
//!
//! **Pure.** Reading, writing and `resolve` take bytes and values and touch
//! no file; `SquadStore.zig` is the one that owns the file.
//!
//! A member refers to a role by key and stores only what differs from it
//! (`Override`). **A key that is there is an override, whatever its value;
//! a key that is not there follows the role.** Every field of `Override`
//! is an optional with no default, so "the squad did not say" (`null`) and
//! "the squad said: empty" (`""`, `[]`) cannot be written by leaving a
//! line out, and a field added later is a compile error at every place
//! that builds one. `Override.none` is the one spelled-out "says nothing".
//!
//! What may not be overridden is the role's name, key, description, its
//! `polter` block and its `tools`. The last two are the permission
//! boundary: a template a supervisor wrote must not grant by "override"
//! what `NotPermitted` stops it granting in a role.

const std = @import("std");
const Allocator = std.mem.Allocator;
const persona = @import("persona.zig");

pub const supported_version: u32 = 1;

/// How many templates a supervisor may have made at once (§4.3).
pub const max_supervisor_squads = 12;
pub const max_alias_len = 24;
pub const max_description_len = 200;
/// A supervisor's `reason`: which existing template does not fit, and why.
pub const min_reason_len = 20;

pub const Origin = enum { user, supervisor };

pub const ParseError = error{
    /// Not JSON, or not an object where one is wanted.
    Malformed,
    BadVersion,
    /// A required key is missing.
    Incomplete,
    /// A key is present and its value makes no sense.
    BadField,
    DuplicateKey,
    DuplicateAlias,
    TwoLeads,
    /// One id is in both `add` and `remove` of one set.
    AddRemoveConflict,
    InstructionsNotString,
    /// `override` names something that follows the role only.
    OverrideForbidden,
    /// A template a supervisor made has no (long enough) reason.
    ReasonRequired,
    /// A member is a supervisor role (v3, item 12).
    SupervisorNotAllowed,
    OutOfMemory,
};

/// Where a refused file went wrong, in words: the squad and member by
/// position and name. A reader that refuses the whole file owes the person
/// the line.
pub const Diag = struct {
    where: []const u8,
};

/// The ids a squad adds to, and takes from, what the role has.
pub const Delta = struct {
    add: []const []const u8,
    remove: []const []const u8,
};

/// What the squad says about one CLI's choices. Each field is the squad's
/// word when present and the role's when null.
pub const CliOverride = struct {
    model: ?[]const u8,
    args: ?[]const []const u8,
    options: ?[]const persona.Option,
};

pub const CliEntry = struct {
    cli: []const u8,
    over: CliOverride,
};

pub const Override = struct {
    cli: ?[]const u8,
    clis: []const CliEntry,
    /// Replaces the role's instructions whole. Present and empty is a
    /// replacement too: "this member gets none".
    instructions: ?[]const u8,
    cli_skills: ?Delta,
    cli_mcp: ?Delta,
    skills: ?Delta,
    mcp: ?Delta,

    pub const none: Override = .{
        .cli = null,
        .clis = &.{},
        .instructions = null,
        .cli_skills = null,
        .cli_mcp = null,
        .skills = null,
        .mcp = null,
    };

    pub fn isNone(self: Override) bool {
        return self.cli == null and self.clis.len == 0 and self.instructions == null and
            self.cli_skills == null and self.cli_mcp == null and self.skills == null and self.mcp == null;
    }
};

pub const Member = struct {
    /// What the task panel and the channel call this seat. Unique in the
    /// squad; the same role may sit in several seats under several aliases.
    alias: []const u8,
    role: []const u8,
    required: bool,
    lead: bool,
    override: Override,
};

pub const Squad = struct {
    key: []const u8,
    name: []const u8,
    description: []const u8,
    origin: Origin,
    reason: []const u8,
    members: []const Member,

    /// The member that leads: the one marked, else the first required, else
    /// the first member. Required and optional are only a hint for whoever
    /// opens the task (§2.6), so a squad of optional members has a lead too.
    pub fn leadOf(self: Squad) ?Member {
        for (self.members) |m| if (m.lead) return m;
        for (self.members) |m| if (m.required) return m;
        if (self.members.len > 0) return self.members[0];
        return null;
    }

    pub fn member(self: Squad, alias: []const u8) ?Member {
        for (self.members) |m| if (std.mem.eql(u8, m.alias, alias)) return m;
        return null;
    }
};

pub const Set = struct {
    version: u32,
    squads: []const Squad,

    pub const empty: Set = .{ .version = supported_version, .squads = &.{} };

    pub fn find(self: Set, key: []const u8) ?Squad {
        for (self.squads) |s| if (std.mem.eql(u8, s.key, key)) return s;
        return null;
    }

    pub fn supervisorMade(self: Set) usize {
        var n: usize = 0;
        for (self.squads) |s| {
            if (s.origin == .supervisor) n += 1;
        }
        return n;
    }
};

/// Whether `role` may not be a squad member: the supervisor Polter ships,
/// or any role that makes its terminal one. With `roles` null (the library
/// could not be read) only the shipped key is known.
pub fn isSupervisorRole(role: []const u8, roles: ?persona.Set) bool {
    if (std.mem.eql(u8, role, persona.supervisor_key)) return true;
    const set = roles orelse return false;
    const p = set.find(role) orelse return false;
    return p.polter.supervisor;
}

// ------------------------------------------------------------------- reading

/// Read a whole file. **A file that does not parse is refused whole**,
/// with `diag` saying where, like `personas.json`.
///
/// `roles` null reads without looking at them (the load path: a library
/// that is momentarily unreadable must not make every squad unreadable
/// with it). With the roles, a member that is a supervisor role and a
/// `clis` entry the role cannot have are refused as well.
pub fn parseLeaky(aa: Allocator, bytes: []const u8, roles: ?persona.Set, diag: *Diag) ParseError!Set {
    diag.where = "";
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, bytes, .{}) catch
        return error.Malformed;
    const root = switch (parsed) {
        .object => |o| o,
        else => return error.Malformed,
    };
    const version: u32 = switch (root.get("version") orelse return error.BadVersion) {
        .integer => |n| if (n == supported_version) @intCast(n) else return error.BadVersion,
        else => return error.BadVersion,
    };
    const list = switch (root.get("squads") orelse return error.Incomplete) {
        .array => |a| a,
        else => return error.BadField,
    };

    var out: std.ArrayList(Squad) = .empty;
    for (list.items, 0..) |entry, i| {
        const s = try squadOf(aa, entry, i, .user, roles, diag);
        for (out.items) |q| {
            if (std.mem.eql(u8, q.key, s.key)) {
                diag.where = try std.fmt.allocPrint(aa, "squads[{d}] ({s})", .{ i, s.key });
                return error.DuplicateKey;
            }
        }
        try out.append(aa, s);
    }
    return .{ .version = version, .squads = try out.toOwnedSlice(aa) };
}

/// One squad on its own, as `squad_put` and the library window send it.
/// The same function as the file's, for the reason `persona.parsePersonaLeaky`
/// gives.
///
/// `default_origin` is what a squad that does not say says: the user's for
/// the window, the supervisor's for `squad_put`.
pub fn parseSquadLeaky(aa: Allocator, bytes: []const u8, default_origin: Origin, roles: ?persona.Set, diag: *Diag) ParseError!Squad {
    diag.where = "";
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, bytes, .{}) catch
        return error.Malformed;
    return try squadOf(aa, parsed, 0, default_origin, roles, diag);
}

fn squadOf(aa: Allocator, entry: std.json.Value, index: usize, default_origin: Origin, roles: ?persona.Set, diag: *Diag) ParseError!Squad {
    const obj = switch (entry) {
        .object => |o| o,
        else => return error.BadField,
    };
    diag.where = try std.fmt.allocPrint(aa, "squads[{d}]", .{index});

    const key = try requireString(obj, "key");
    if (!persona.isValidKey(key)) return error.BadField;
    diag.where = try std.fmt.allocPrint(aa, "squads[{d}] ({s})", .{ index, key });

    const name = try requireString(obj, "name");
    if (std.mem.trim(u8, name, " \t\r\n").len == 0) return error.BadField;
    const description = (try optionalString(obj, "description")) orelse "";
    if (description.len > max_description_len) return error.BadField;
    const reason = (try optionalString(obj, "reason")) orelse "";

    const origin: Origin = if (try optionalString(obj, "origin")) |o|
        std.meta.stringToEnum(Origin, o) orelse return error.BadField
    else
        default_origin;
    if (origin == .supervisor and std.mem.trim(u8, reason, " \t\r\n").len < min_reason_len)
        return error.ReasonRequired;

    const items = switch (obj.get("members") orelse std.json.Value{ .array = .init(aa) }) {
        .array => |a| a.items,
        else => return error.BadField,
    };
    var members: std.ArrayList(Member) = .empty;
    var leads: usize = 0;
    for (items, 0..) |mv, i| {
        const m = try memberOf(aa, mv, index, key, i, roles, diag);
        for (members.items) |q| {
            if (std.mem.eql(u8, q.alias, m.alias)) return error.DuplicateAlias;
        }
        if (m.lead) leads += 1;
        try members.append(aa, m);
    }
    diag.where = try std.fmt.allocPrint(aa, "squads[{d}] ({s})", .{ index, key });
    if (leads > 1) return error.TwoLeads;

    return .{
        .key = key,
        .name = name,
        .description = description,
        .origin = origin,
        .reason = reason,
        .members = try members.toOwnedSlice(aa),
    };
}

fn memberOf(
    aa: Allocator,
    entry: std.json.Value,
    squad_index: usize,
    squad_key: []const u8,
    index: usize,
    roles: ?persona.Set,
    diag: *Diag,
) ParseError!Member {
    const obj = switch (entry) {
        .object => |o| o,
        else => return error.BadField,
    };
    diag.where = try std.fmt.allocPrint(aa, "squads[{d}] ({s}).members[{d}]", .{ squad_index, squad_key, index });

    const alias = try requireString(obj, "alias");
    if (std.mem.trim(u8, alias, " \t\r\n").len == 0 or alias.len > max_alias_len) return error.BadField;
    diag.where = try std.fmt.allocPrint(aa, "squads[{d}] ({s}).members[{d}] ({s})", .{ squad_index, squad_key, index, alias });

    const role = try requireString(obj, "role");
    if (!persona.isValidKey(role)) return error.BadField;
    if (isSupervisorRole(role, roles)) return error.SupervisorNotAllowed;

    const over = if (obj.get("override")) |ov| try overrideOf(aa, ov, roles, role) else Override.none;
    return .{
        .alias = alias,
        .role = role,
        .required = try optionalBool(obj, "required"),
        .lead = try optionalBool(obj, "lead"),
        .override = over,
    };
}

/// Keys of `override` that follow the role and nothing else.
const forbidden_override_keys = [_][]const u8{ "key", "name", "description", "prompt", "polter", "tools" };

fn overrideOf(aa: Allocator, v: std.json.Value, roles: ?persona.Set, role_key: []const u8) ParseError!Override {
    const obj = switch (v) {
        .object => |o| o,
        .null => return Override.none,
        else => return error.BadField,
    };
    for (forbidden_override_keys) |k| {
        if (obj.get(k) != null) return error.OverrideForbidden;
    }

    var out = Override.none;
    if (obj.get("cli")) |cv| {
        const c = switch (cv) {
            .string => |s| s,
            else => return error.BadField,
        };
        if (!persona.isValidKey(c)) return error.BadField;
        out.cli = c;
    }
    if (obj.get("instructions")) |iv| out.instructions = switch (iv) {
        .string => |s| s,
        else => return error.InstructionsNotString,
    };
    out.cli_skills = try deltaOf(aa, obj, "cli_skills");
    out.cli_mcp = try deltaOf(aa, obj, "cli_mcp");
    out.skills = try deltaOf(aa, obj, "skills");
    out.mcp = try deltaOf(aa, obj, "mcp");

    if (obj.get("clis")) |cv| {
        const m = switch (cv) {
            .object => |o| o,
            else => return error.BadField,
        };
        const entries = try aa.alloc(CliEntry, m.count());
        var it = m.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            const cli = kv.key_ptr.*;
            if (!persona.isValidKey(cli)) return error.BadField;
            // A CLI the squad can choose for the member: the one it names,
            // or one the role is already set up for.
            if (roles) |set| if (set.find(role_key)) |p| {
                const named = if (out.cli) |c| std.mem.eql(u8, c, cli) else false;
                if (!named and p.cli(cli) == null) return error.BadField;
            };
            entries[i] = .{ .cli = cli, .over = try cliOverrideOf(aa, kv.value_ptr.*) };
        }
        out.clis = entries;
    }
    return out;
}

fn cliOverrideOf(aa: Allocator, v: std.json.Value) ParseError!CliOverride {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.BadField,
    };
    var out: CliOverride = .{ .model = null, .args = null, .options = null };
    if (obj.get("model")) |mv| out.model = switch (mv) {
        .string => |s| s,
        else => return error.BadField,
    };
    if (obj.get("args") != null) out.args = try stringArray(aa, obj, "args");
    if (obj.get("options")) |ov| {
        const m = switch (ov) {
            .object => |o| o,
            else => return error.BadField,
        };
        const list = try aa.alloc(persona.Option, m.count());
        var it = m.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            list[i] = .{
                .key = kv.key_ptr.*,
                .value = switch (kv.value_ptr.*) {
                    .string => |s| s,
                    else => return error.BadField,
                },
            };
        }
        out.options = list;
    }
    return out;
}

fn deltaOf(aa: Allocator, obj: std.json.ObjectMap, comptime name: []const u8) ParseError!?Delta {
    const v = obj.get(name) orelse return null;
    const o = switch (v) {
        .object => |x| x,
        else => return error.BadField,
    };
    const d: Delta = .{
        .add = try stringArray(aa, o, "add"),
        .remove = try stringArray(aa, o, "remove"),
    };
    for (d.add) |a| for (d.remove) |r| {
        if (std.mem.eql(u8, a, r)) return error.AddRemoveConflict;
    };
    return d;
}

fn requireString(obj: std.json.ObjectMap, comptime name: []const u8) ParseError![]const u8 {
    const v = obj.get(name) orelse return error.Incomplete;
    return switch (v) {
        .string => |s| s,
        else => error.BadField,
    };
}

fn optionalString(obj: std.json.ObjectMap, comptime name: []const u8) ParseError!?[]const u8 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        .null => null,
        else => error.BadField,
    };
}

fn optionalBool(obj: std.json.ObjectMap, comptime name: []const u8) ParseError!bool {
    const v = obj.get(name) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => error.BadField,
    };
}

/// An absent array is an empty one; anything but an array of strings is
/// refused.
fn stringArray(aa: Allocator, obj: std.json.ObjectMap, comptime name: []const u8) ParseError![]const []const u8 {
    const v = obj.get(name) orelse return &.{};
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadField,
    };
    const out = try aa.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, i| out[i] = switch (item) {
        .string => |s| s,
        else => return error.BadField,
    };
    return out;
}

// ------------------------------------------------------------------- writing

pub fn writeSet(w: *std.Io.Writer, set: Set) std.Io.Writer.Error!void {
    try w.print("{{\n  \"version\": {d},\n  \"squads\": [", .{supported_version});
    for (set.squads, 0..) |s, i| {
        try w.writeAll(if (i == 0) "\n    " else ",\n    ");
        try writeSquad(w, s);
    }
    try w.writeAll(if (set.squads.len == 0) "]\n}\n" else "\n  ]\n}\n");
}

pub fn writeSquad(w: *std.Io.Writer, s: Squad) std.Io.Writer.Error!void {
    try w.print("{{\"key\":{f},\"name\":{f},\"description\":{f},\"origin\":\"{t}\",\"reason\":{f},\"members\":[", .{
        jstr(s.key), jstr(s.name), jstr(s.description), s.origin, jstr(s.reason),
    });
    for (s.members, 0..) |m, i| {
        if (i > 0) try w.writeAll(",");
        try writeMember(w, m);
    }
    try w.writeAll("]}");
}

pub fn writeMember(w: *std.Io.Writer, m: Member) std.Io.Writer.Error!void {
    try w.print("{{\"alias\":{f},\"role\":{f},\"required\":{},\"lead\":{}", .{
        jstr(m.alias), jstr(m.role), m.required, m.lead,
    });
    if (!m.override.isNone()) {
        try w.writeAll(",\"override\":");
        try writeOverride(w, m.override);
    }
    try w.writeAll("}");
}

/// Only the keys that are there. Writing a missing one as an empty value
/// would turn "follows the role" into "overrides it with nothing".
pub fn writeOverride(w: *std.Io.Writer, o: Override) std.Io.Writer.Error!void {
    try w.writeAll("{");
    var first = true;
    if (o.cli) |c| {
        try w.print("\"cli\":{f}", .{jstr(c)});
        first = false;
    }
    if (o.clis.len > 0) {
        try w.writeAll(if (first) "\"clis\":{" else ",\"clis\":{");
        first = false;
        for (o.clis, 0..) |e, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{f}:{{", .{jstr(e.cli)});
            var f2 = true;
            if (e.over.model) |m| {
                try w.print("\"model\":{f}", .{jstr(m)});
                f2 = false;
            }
            if (e.over.args) |a| {
                try w.writeAll(if (f2) "\"args\":" else ",\"args\":");
                try writeStrings(w, a);
                f2 = false;
            }
            if (e.over.options) |opts| {
                try w.writeAll(if (f2) "\"options\":" else ",\"options\":");
                try persona.writeOptions(w, opts);
            }
            try w.writeAll("}");
        }
        try w.writeAll("}");
    }
    if (o.instructions) |t| {
        try w.print("{s}\"instructions\":{f}", .{ if (first) "" else ",", jstr(t) });
        first = false;
    }
    inline for (.{ "cli_skills", "cli_mcp", "skills", "mcp" }) |name| {
        if (@field(o, name)) |d| {
            try w.print("{s}\"{s}\":{{\"add\":", .{ if (first) "" else ",", name });
            try writeStrings(w, d.add);
            try w.writeAll(",\"remove\":");
            try writeStrings(w, d.remove);
            try w.writeAll("}");
            first = false;
        }
    }
    try w.writeAll("}");
}

fn writeStrings(w: *std.Io.Writer, list: []const []const u8) std.Io.Writer.Error!void {
    try w.writeAll("[");
    for (list, 0..) |item, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{f}", .{jstr(item)});
    }
    try w.writeAll("]");
}

fn jstr(s: []const u8) std.json.Formatter([]const u8) {
    return std.json.fmt(s, .{});
}

// ------------------------------------------------------------- changing a set

/// `set` with `s` in it: replacing the squad with the same key where it
/// stands, or appended. The order is the person's.
pub fn withSquad(aa: Allocator, set: Set, s: Squad) Allocator.Error!Set {
    var out: std.ArrayList(Squad) = .empty;
    var replaced = false;
    for (set.squads) |q| {
        if (std.mem.eql(u8, q.key, s.key)) {
            try out.append(aa, s);
            replaced = true;
        } else try out.append(aa, q);
    }
    if (!replaced) try out.append(aa, s);
    return .{ .version = supported_version, .squads = try out.toOwnedSlice(aa) };
}

pub fn withoutSquad(aa: Allocator, set: Set, key: []const u8) Allocator.Error!?Set {
    var out: std.ArrayList(Squad) = .empty;
    var found = false;
    for (set.squads) |q| {
        if (std.mem.eql(u8, q.key, key)) found = true else try out.append(aa, q);
    }
    if (!found) return null;
    return .{ .version = supported_version, .squads = try out.toOwnedSlice(aa) };
}

pub const Removed = struct {
    squad: []const u8,
    alias: []const u8,
};

pub const Dropped = struct {
    set: Set,
    removed: []const Removed,
};

/// `set` without the members `gone` says are to go -- every seat that
/// refers to a role the caller names -- **and nothing else**.
///
/// The lead passes to the next required member when it was one of the
/// removed, else to the first remaining member. **No member's `required`
/// is changed**: that mark is the person's, and a squad of optional members
/// is a valid squad. A squad left with none stays, empty.
pub fn withoutMembers(aa: Allocator, set: Set, gone: anytype) Allocator.Error!Dropped {
    var removed: std.ArrayList(Removed) = .empty;
    var out: std.ArrayList(Squad) = .empty;
    for (set.squads) |s| {
        var kept: std.ArrayList(Member) = .empty;
        var lost_lead = false;
        var any = false;
        for (s.members) |m| {
            if (gone.contains(m.role)) {
                any = true;
                if (m.lead) lost_lead = true;
                try removed.append(aa, .{ .squad = s.key, .alias = m.alias });
            } else try kept.append(aa, m);
        }
        if (!any) {
            try out.append(aa, s);
            continue;
        }
        const members = try kept.toOwnedSlice(aa);
        if (lost_lead and members.len > 0) {
            var next_lead: usize = 0;
            for (members, 0..) |m, i| {
                if (m.required) {
                    next_lead = i;
                    break;
                }
            }
            members[next_lead].lead = true;
        }
        var next = s;
        next.members = members;
        try out.append(aa, next);
    }
    return .{
        .set = .{ .version = supported_version, .squads = try out.toOwnedSlice(aa) },
        .removed = try removed.toOwnedSlice(aa),
    };
}

/// Names a set of role keys for `withoutMembers`.
pub const OneRole = struct {
    key: []const u8,
    pub fn contains(self: OneRole, k: []const u8) bool {
        return std.mem.eql(u8, self.key, k);
    }
};

/// Every role key that the library does not have.
pub const MissingRoles = struct {
    roles: persona.Set,
    pub fn contains(self: MissingRoles, k: []const u8) bool {
        return self.roles.find(k) == null;
    }
};

pub const Status = enum { ok, role_missing, supervisor_role };

/// What a member stands on right now. Read, never written: a role the
/// library cannot show may be one that is only unreadable at the moment.
pub fn statusOf(m: Member, roles: persona.Set) Status {
    const p = roles.find(m.role) orelse return .role_missing;
    if (p.polter.supervisor or std.mem.eql(u8, m.role, persona.supervisor_key)) return .supervisor_role;
    return .ok;
}

// ------------------------------------------------------------------- resolve

pub const ResolveError = error{ NoCli, ChooseCli, OutOfMemory };

/// A member's role as it will be started: the role with the squad's
/// override laid over it.
pub const Resolved = struct {
    /// The role with its instructions, skills, MCP and CLI selections
    /// replaced by the squad's. `clis` holds the one entry started.
    persona: persona.Persona,
    cli: []const u8,
    choice: persona.CliChoice,
    /// Whether the squad replaced the role's instructions.
    instructions_replaced: bool,
    /// What the role said that this start does not use, and why. Said out
    /// loud: a changed CLI that quietly lost the role's arguments is the
    /// failure this list is for.
    dropped: []const []const u8,
    carried_over: []const []const u8,
    /// Which fields this start took from the squad rather than the role,
    /// by name (`model`, `args`, `options`, `instructions`, `skills`, `mcp`,
    /// `cli_skills`, `cli_mcp`). Not derivable from the values: a squad
    /// that says the model the role has today still said it.
    from_squad: []const []const u8,
};

/// The effective role of one member (§2.5).
///
/// The CLI: `asked` (the launch named it), else the squad's, else the
/// role's own default (`Persona.defaultCli`, with `available` and `by`).
/// Its model, arguments and options: the role's entry for **that** CLI
/// (empty when it has none), with every key the squad wrote replacing the
/// role's. The role's choices for other CLIs are not carried over -- a
/// model name means nothing to another CLI -- and are named in `dropped`.
pub fn resolve(
    aa: Allocator,
    role: persona.Persona,
    over: Override,
    asked: ?[]const u8,
    available: []const []const u8,
    by: ?[]const u8,
) ResolveError!Resolved {
    const cli: []const u8 = if (asked) |a|
        a
    else if (over.cli) |c|
        c
    else
        try role.defaultCli(available, by);

    var from_squad: std.ArrayList([]const u8) = .empty;
    var choice: persona.CliChoice = role.cli(cli) orelse .{ .cli = cli };
    for (over.clis) |e| {
        if (!std.mem.eql(u8, e.cli, cli)) continue;
        if (e.over.model) |m| {
            choice.model = if (m.len == 0) null else m;
            try from_squad.append(aa, "model");
        }
        if (e.over.args) |a| {
            choice.args = a;
            try from_squad.append(aa, "args");
        }
        if (e.over.options) |o| {
            choice.options = o;
            try from_squad.append(aa, "options");
        }
    }

    var dropped: std.ArrayList([]const u8) = .empty;
    var carried: std.ArrayList([]const u8) = .empty;
    if (over.cli != null) {
        for (role.clis) |c| {
            if (std.mem.eql(u8, c.cli, cli)) continue;
            if (c.model != null) try dropped.append(aa, try std.fmt.allocPrint(aa, "role.clis.{s}.model (CLI changed to {s})", .{ c.cli, cli }));
            if (c.args.len > 0) try dropped.append(aa, try std.fmt.allocPrint(aa, "role.clis.{s}.args (CLI changed to {s})", .{ c.cli, cli }));
            if (c.options.len > 0) try dropped.append(aa, try std.fmt.allocPrint(aa, "role.clis.{s}.options (CLI changed to {s})", .{ c.cli, cli }));
        }
        if (!role.cli_skills.isAll()) try carried.append(aa, "role.cli_skills");
        if (!role.cli_mcp.isAll()) try carried.append(aa, "role.cli_mcp");
    }

    var out = role;
    const entry = try aa.alloc(persona.CliChoice, 1);
    entry[0] = choice;
    out.clis = entry;
    if (over.instructions) |t| {
        out.instructions = if (t.len == 0) null else t;
        try from_squad.append(aa, "instructions");
    }
    if (over.skills) |d| {
        out.skills = try applyList(aa, role.skills, d);
        try from_squad.append(aa, "skills");
    }
    if (over.mcp) |d| {
        out.mcp = try applyList(aa, role.mcp, d);
        try from_squad.append(aa, "mcp");
    }
    if (over.cli_skills) |d| {
        out.cli_skills = try applySelection(aa, role.cli_skills, d);
        try from_squad.append(aa, "cli_skills");
    }
    if (over.cli_mcp) |d| {
        out.cli_mcp = try applySelection(aa, role.cli_mcp, d);
        try from_squad.append(aa, "cli_mcp");
    }

    return .{
        .persona = out,
        .cli = cli,
        .choice = choice,
        .instructions_replaced = over.instructions != null,
        .dropped = try dropped.toOwnedSlice(aa),
        .carried_over = try carried.toOwnedSlice(aa),
        .from_squad = try from_squad.toOwnedSlice(aa),
    };
}

/// The role's list, without `remove`, with `add` after it; no id twice.
fn applyList(aa: Allocator, base: []const []const u8, d: Delta) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (base) |id| {
        if (contains(d.remove, id) or contains(out.items, id)) continue;
        try out.append(aa, id);
    }
    for (d.add) |id| {
        if (!contains(out.items, id)) try out.append(aa, id);
    }
    return try out.toOwnedSlice(aa);
}

/// The role's selection with each `remove` turned off and then each `add`
/// turned on. A difference laid over whatever the role says now, so a role
/// that flips its `default` later is still honoured underneath.
fn applySelection(aa: Allocator, base: persona.Selection, d: Delta) Allocator.Error!persona.Selection {
    var sel = base;
    for (d.remove) |id| sel = try setSelection(aa, sel, id, false);
    for (d.add) |id| sel = try setSelection(aa, sel, id, true);
    return sel;
}

fn setSelection(aa: Allocator, sel: persona.Selection, id: []const u8, on: bool) Allocator.Error!persona.Selection {
    var except: std.ArrayList([]const u8) = .empty;
    for (sel.except) |e| {
        if (!std.mem.eql(u8, e, id)) try except.append(aa, e);
    }
    // `except` is what differs from `default`.
    if (on != sel.default) try except.append(aa, id);
    return .{ .default = sel.default, .except = try except.toOwnedSlice(aa) };
}

fn contains(list: []const []const u8, id: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, id)) return true;
    return false;
}

// ----------------------------------------------------------------- the seat

/// What the `+launch` line is handed to start a squad's seat: the member as
/// the squad has it, and the opening paragraph. `+launch` is another
/// process, and reading the role library again there is what would give
/// back the role's instructions (plan v3 item 14); this is how the squad's
/// word reaches it instead.
pub const Seat = struct {
    member: Member,
    brief: []const u8,
};

/// `Seat` as a word fit for a shell line: URL-safe base64 without padding,
/// which is `[A-Za-z0-9_-]` and so needs no quoting in any shell.
pub fn encodeSeat(aa: Allocator, m: Member, brief: []const u8) Allocator.Error![]const u8 {
    var seat = m;
    // The seat's own marks are the squad's business, not the CLI's.
    seat.lead = false;
    seat.required = false;
    const sq: Squad = .{
        .key = "seat",
        .name = "seat",
        .description = "",
        .origin = .user,
        .reason = "",
        .members = &.{seat},
    };
    var json: std.Io.Writer.Allocating = .init(aa);
    json.writer.print("{{\"brief\":{f},\"squad\":", .{jstr(brief)}) catch return error.OutOfMemory;
    writeSquad(&json.writer, sq) catch return error.OutOfMemory;
    json.writer.writeAll("}") catch return error.OutOfMemory;
    const raw = json.written();
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try aa.alloc(u8, enc.calcSize(raw.len));
    return enc.encode(out, raw);
}

/// Back from `encodeSeat`. Anything else is `Malformed`.
pub fn decodeSeatLeaky(aa: Allocator, word: []const u8) ParseError!Seat {
    const dec = std.base64.url_safe_no_pad.Decoder;
    const n = dec.calcSizeForSlice(word) catch return error.Malformed;
    const raw = try aa.alloc(u8, n);
    dec.decode(raw, word) catch return error.Malformed;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, raw, .{}) catch
        return error.Malformed;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.Malformed,
    };
    const brief = try requireString(obj, "brief");
    var diag: Diag = .{ .where = "" };
    const sq = try squadOf(aa, obj.get("squad") orelse return error.Incomplete, 0, .user, null, &diag);
    if (sq.members.len != 1) return error.BadField;
    return .{ .member = sq.members[0], .brief = brief };
}

// --------------------------------------------------------------------- tests

const testing = std.testing;

/// A role with a model for each of two CLIs, for most of the tests below.
const base_role: persona.Persona = .{
    .key = "worker-dev",
    .name = "Developer",
    .description = "writes code",
    .instructions = "role instructions",
    .skills = &.{ "review", "plan" },
    .mcp = &.{"kanban"},
    .clis = &.{
        .{ .cli = "claude-code", .model = "opus", .args = &.{"--verbose"}, .options = &.{.{ .key = "effort", .value = "high" }} },
        .{ .cli = "codex", .model = "gpt-5", .args = &.{"--full-auto"} },
    },
    .cli_skills = .{ .default = true, .except = &.{"skill:web"} },
    .cli_mcp = .{ .default = false, .except = &.{"mcp:argus"} },
};

fn parseOk(aa: Allocator, bytes: []const u8) !Set {
    var diag: Diag = .{ .where = "" };
    return parseLeaky(aa, bytes, null, &diag);
}

fn one(aa: Allocator, member_json: []const u8) !Member {
    const bytes = try std.fmt.allocPrint(aa,
        \\{{"version":1,"squads":[{{"key":"s","name":"S","members":[{{"alias":"zz-req","role":"r","required":true}},{s}]}}]}}
    , .{member_json});
    const set = try parseOk(aa, bytes);
    return set.squads[0].members[1];
}

fn arena() std.heap.ArenaAllocator {
    return .init(testing.allocator);
}

test "squad: resolve 只取覆盖里写了的键，没写的跟角色" {
    var a = arena();
    defer a.deinit();
    const aa = a.allocator();

    // The squad names a CLI and writes only its model; the args the role
    // has for that CLI are not written, so they stay the role's.
    const m = try one(aa,
        \\{"alias":"dev","role":"worker-dev","required":true,"override":{"clis":{"codex":{"model":"gpt-6"}}}}
    );
    const r = try resolve(aa, base_role, m.override, "codex", &.{}, null);
    try testing.expectEqualStrings("gpt-6", r.choice.model.?);
    // 未覆盖的 args 仍是角色的
    try testing.expectEqualStrings("--full-auto", r.choice.args[0]);
    // And the other CLI's entry was never the squad's business.
    const r2 = try resolve(aa, base_role, Override.none, "claude-code", &.{}, null);
    try testing.expectEqualStrings("opus", r2.choice.model.?);
    try testing.expectEqualStrings("high", r2.choice.options[0].value);
}

test "squad: 角色改了之后，被覆盖的字段仍是小队的，没覆盖的变成角色新值" {
    var a = arena();
    defer a.deinit();
    const aa = a.allocator();

    const m = try one(aa,
        \\{"alias":"dev","role":"worker-dev","override":{"cli":"codex","clis":{"codex":{"model":"squad-model"}}}}
        \\
    );
    const before = try resolve(aa, base_role, m.override, null, &.{}, null);
    try testing.expectEqualStrings("squad-model", before.choice.model.?);
    try testing.expectEqualStrings("--full-auto", before.choice.args[0]);

    // The role changes both fields; resolving again reads the new role.
    var changed = base_role;
    changed.clis = &.{
        .{ .cli = "codex", .model = "role-model-2", .args = &.{"--new-flag"} },
    };
    const after = try resolve(aa, changed, m.override, null, &.{}, null);
    try testing.expectEqualStrings("squad-model", after.choice.model.?);
    try testing.expectEqualStrings("--new-flag", after.choice.args[0]);
}

test "squad: skills/mcp 的 add/remove 叠在角色的 Selection 上；角色把 default 翻转后叠加仍成立" {
    var a = arena();
    defer a.deinit();
    const aa = a.allocator();

    const m = try one(aa,
        \\{"alias":"dev","role":"worker-dev","override":{
        \\  "cli_skills":{"add":["skill:web"],"remove":["skill:pdf"]},
        \\  "cli_mcp":{"add":["mcp:github"],"remove":["mcp:argus"]}}}
    );
    const r = try resolve(aa, base_role, m.override, "codex", &.{}, null);
    // default on, role switched web off: the squad turns web on and pdf off.
    try testing.expect(r.persona.cli_skills.enabled("skill:web"));
    try testing.expect(!r.persona.cli_skills.enabled("skill:pdf"));
    try testing.expect(r.persona.cli_skills.enabled("skill:other"));
    // default off, role switched argus on: the squad turns github on, argus off.
    try testing.expect(r.persona.cli_mcp.enabled("mcp:github"));
    try testing.expect(!r.persona.cli_mcp.enabled("mcp:argus"));
    try testing.expect(!r.persona.cli_mcp.enabled("mcp:other"));

    // The role flips both defaults. The squad's differences are laid on
    // the new base: github still on, pdf still off, and an id the squad
    // never mentioned follows the role's new default.
    var flipped = base_role;
    flipped.cli_skills = .{ .default = false, .except = &.{} };
    flipped.cli_mcp = .{ .default = true, .except = &.{} };
    const r2 = try resolve(aa, flipped, m.override, "codex", &.{}, null);
    try testing.expect(r2.persona.cli_skills.enabled("skill:web"));
    try testing.expect(!r2.persona.cli_skills.enabled("skill:pdf"));
    try testing.expect(!r2.persona.cli_skills.enabled("skill:other"));
    try testing.expect(r2.persona.cli_mcp.enabled("mcp:github"));
    try testing.expect(!r2.persona.cli_mcp.enabled("mcp:argus"));
    try testing.expect(r2.persona.cli_mcp.enabled("mcp:other"));
}

test "squad: 四类集合（cli_skills、cli_mcp、skills、mcp）的 add/remove 都叠在角色的底上" {
    var a = arena();
    defer a.deinit();
    const aa = a.allocator();

    const m = try one(aa,
        \\{"alias":"dev","role":"worker-dev","override":{
        \\  "skills":{"add":["extra","review"],"remove":["plan"]},
        \\  "mcp":{"add":["argus"],"remove":["kanban"]},
        \\  "cli_skills":{"add":["skill:x"],"remove":[]},
        \\  "cli_mcp":{"add":[],"remove":["mcp:y"]}}}
    );
    const r = try resolve(aa, base_role, m.override, "codex", &.{}, null);
    // The role's order first, the new ones after, nothing twice.
    try testing.expectEqual(@as(usize, 2), r.persona.skills.len);
    try testing.expectEqualStrings("review", r.persona.skills[0]);
    try testing.expectEqualStrings("extra", r.persona.skills[1]);
    try testing.expectEqual(@as(usize, 1), r.persona.mcp.len);
    try testing.expectEqualStrings("argus", r.persona.mcp[0]);
    try testing.expect(r.persona.cli_skills.enabled("skill:x"));
    try testing.expect(!r.persona.cli_skills.enabled("skill:web"));
    try testing.expect(!r.persona.cli_mcp.enabled("mcp:y"));
}

test "squad: 换 CLI 不带过来原 CLI 的 model/args/options，并在 dropped 里说出" {
    var a = arena();
    defer a.deinit();
    const aa = a.allocator();

    const m = try one(aa,
        \\{"alias":"dev","role":"worker-dev","override":{"cli":"codex"}}
    );
    const r = try resolve(aa, base_role, m.override, null, &.{}, null);
    try testing.expectEqualStrings("codex", r.cli);
    // codex's entry, not claude-code's.
    try testing.expectEqualStrings("gpt-5", r.choice.model.?);
    try testing.expectEqual(@as(usize, 0), r.choice.options.len);
    var said = false;
    for (r.dropped) |d| {
        if (std.mem.indexOf(u8, d, "role.clis.claude-code.model") != null) said = true;
    }
    try testing.expect(said);
    var said_args = false;
    var said_options = false;
    for (r.dropped) |d| {
        if (std.mem.indexOf(u8, d, "claude-code.args") != null) said_args = true;
        if (std.mem.indexOf(u8, d, "claude-code.options") != null) said_options = true;
    }
    try testing.expect(said_args and said_options);
    // The selections go on to the new CLI as they are.
    try testing.expect(!r.persona.cli_skills.enabled("skill:web"));
    try testing.expectEqual(@as(usize, 2), r.carried_over.len);

    // Naming no other CLI drops nothing.
    const r2 = try resolve(aa, base_role, Override.none, "claude-code", &.{}, null);
    try testing.expectEqual(@as(usize, 0), r2.dropped.len);
}

test "squad: 角色无该 CLI 条目时底为空，只用小队写的" {
    var a = arena();
    defer a.deinit();
    const aa = a.allocator();

    const m = try one(aa,
        \\{"alias":"dev","role":"worker-dev","override":{"cli":"gemini","clis":{"gemini":{"args":["--yolo"]}}}}
    );
    const r = try resolve(aa, base_role, m.override, null, &.{}, null);
    try testing.expectEqualStrings("gemini", r.cli);
    try testing.expectEqual(@as(?[]const u8, null), r.choice.model);
    try testing.expectEqualStrings("--yolo", r.choice.args[0]);
    try testing.expectEqual(@as(usize, 0), r.choice.options.len);

    // Both sides silent: the CLI's own defaults, and still not a refusal.
    const bare = try one(aa,
        \\{"alias":"dev2","role":"worker-dev","override":{"cli":"gemini"}}
    );
    const r2 = try resolve(aa, base_role, bare.override, null, &.{}, null);
    try testing.expectEqual(@as(usize, 0), r2.choice.args.len);
    try testing.expectEqual(@as(?[]const u8, null), r2.choice.model);
}

test "squad: 覆盖不能触碰 polter/tools，写入即拒" {
    var a = arena();
    defer a.deinit();
    const aa = a.allocator();

    const forbidden = [_][]const u8{
        \\"polter":{"supervisor":false}
        ,
        \\"tools":{"deny":["x"]}
        ,
        \\"name":"x"
        ,
        \\"key":"x"
        ,
        \\"description":"x"
    };
    for (forbidden) |frag| {
        const bytes = try std.fmt.allocPrint(aa,
            \\{{"version":1,"squads":[{{"key":"s","name":"S","members":[{{"alias":"a","role":"r","required":true,"override":{{{s}}}}}]}}]}}
        , .{frag});
        try testing.expectError(error.OverrideForbidden, parseOk(aa, bytes));
    }
}

test "squad: 解析整份拒绝并点名行：alias 重复、两个 lead、add/remove 冲突、instructions 不是字符串、key 字符集" {
    var a = arena();
    defer a.deinit();
    const aa = a.allocator();
    var diag: Diag = .{ .where = "" };

    const head = "{\"version\":1,\"squads\":[{\"key\":\"s\",\"name\":\"S\",\"members\":[";
    const tail = "]}]}";
    const cases = [_]struct { body: []const u8, err: ParseError, where: []const u8 }{
        .{
            .body = "{\"alias\":\"a\",\"role\":\"r\",\"required\":true},{\"alias\":\"a\",\"role\":\"r\"}",
            .err = error.DuplicateAlias,
            .where = "members[1]",
        },
        .{
            .body = "{\"alias\":\"a\",\"role\":\"r\",\"required\":true,\"lead\":true},{\"alias\":\"b\",\"role\":\"r\",\"lead\":true}",
            .err = error.TwoLeads,
            .where = "squads[0] (s)",
        },
        .{
            .body = "{\"alias\":\"a\",\"role\":\"r\",\"required\":true,\"override\":{\"skills\":{\"add\":[\"x\"],\"remove\":[\"x\"]}}}",
            .err = error.AddRemoveConflict,
            .where = "members[0] (a)",
        },
        .{
            .body = "{\"alias\":\"a\",\"role\":\"r\",\"required\":true,\"override\":{\"instructions\":5}}",
            .err = error.InstructionsNotString,
            .where = "members[0] (a)",
        },
        .{
            .body = "{\"alias\":\"a\",\"role\":\"Bad_Role\",\"required\":true}",
            .err = error.BadField,
            .where = "members[0] (a)",
        },
    };
    for (cases) |c| {
        const bytes = try std.fmt.allocPrint(aa, "{s}{s}{s}", .{ head, c.body, tail });
        try testing.expectError(c.err, parseLeaky(aa, bytes, null, &diag));
        try testing.expect(std.mem.indexOf(u8, diag.where, c.where) != null);
    }

    // A squad key outside [a-z0-9-] is refused too, with the squad named.
    try testing.expectError(error.BadField, parseLeaky(aa,
        \\{"version":1,"squads":[{"key":"Bad Key","name":"S","members":[]}]}
    , null, &diag));
    try testing.expectEqualStrings("squads[0]", diag.where);
}

test "squad: 同一角色以两个别名出现，各自的覆盖互不影响，任务里是两个独立的位" {
    var a = arena();
    defer a.deinit();
    const aa = a.allocator();

    const set = try parseOk(aa,
        \\{"version":1,"squads":[{"key":"s","name":"S","members":[
        \\  {"alias":"dev-a","role":"worker-dev","required":true,"override":{"instructions":"A"}},
        \\  {"alias":"dev-b","role":"worker-dev","override":{"cli":"codex","skills":{"add":["z"],"remove":[]}}}
        \\]}]}
    );
    const s = set.squads[0];
    try testing.expectEqual(@as(usize, 2), s.members.len);
    const a_member = s.member("dev-a").?;
    const b_member = s.member("dev-b").?;
    const ra = try resolve(aa, base_role, a_member.override, "claude-code", &.{}, null);
    const rb = try resolve(aa, base_role, b_member.override, null, &.{}, null);
    try testing.expectEqualStrings("A", ra.persona.instructions.?);
    try testing.expectEqualStrings("role instructions", rb.persona.instructions.?);
    try testing.expectEqualStrings("codex", rb.cli);
    try testing.expectEqualStrings("claude-code", ra.cli);
    try testing.expectEqual(@as(usize, 2), ra.persona.skills.len);
    try testing.expectEqual(@as(usize, 3), rb.persona.skills.len);
}

test "squad: override 键在场即覆盖（含空串与空数组），不在场即跟随；解析不给默认值" {
    var a = arena();
    defer a.deinit();
    const aa = a.allocator();

    const present = try one(aa,
        \\{"alias":"a","role":"worker-dev","override":{"instructions":"","clis":{"claude-code":{"model":"","args":[]}}}}
    );
    try testing.expect(present.override.instructions != null);
    try testing.expectEqual(@as(usize, 0), present.override.instructions.?.len);
    try testing.expect(present.override.clis[0].over.model != null);
    try testing.expect(present.override.clis[0].over.args != null);
    try testing.expectEqual(@as(?[]const persona.Option, null), present.override.clis[0].over.options);

    const r = try resolve(aa, base_role, present.override, "claude-code", &.{}, null);
    // 空串仍是覆盖：角色的指令不再使用，模型回到该 CLI 的默认，参数为空。
    try testing.expectEqual(@as(?[]const u8, null), r.persona.instructions);
    try testing.expect(r.instructions_replaced);
    try testing.expectEqual(@as(?[]const u8, null), r.choice.model);
    try testing.expectEqual(@as(usize, 0), r.choice.args.len);
    // The option the squad did not write still follows the role.
    try testing.expectEqualStrings("high", r.choice.options[0].value);

    // Not there: follows the role in every field.
    const absent = try one(aa,
        \\{"alias":"b","role":"worker-dev","override":{}}
    );
    try testing.expect(absent.override.isNone());
    const r2 = try resolve(aa, base_role, absent.override, "claude-code", &.{}, null);
    try testing.expectEqualStrings("role instructions", r2.persona.instructions.?);
    try testing.expect(!r2.instructions_replaced);
    try testing.expectEqualStrings("opus", r2.choice.model.?);

    // The writer keeps the difference: empty is written, missing is not.
    var out: std.Io.Writer.Allocating = .init(aa);
    try writeOverride(&out.writer, present.override);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"instructions\":\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"model\":\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"args\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "options") == null);
}

test "squad: 把字段设成与角色当前相同的值仍记为覆盖，角色改后小队的值不变" {
    var a = arena();
    defer a.deinit();
    const aa = a.allocator();

    // The squad writes the model the role has today.
    const m = try one(aa,
        \\{"alias":"a","role":"worker-dev","override":{"clis":{"codex":{"model":"gpt-5"}}}}
    );
    try testing.expect(m.override.clis[0].over.model != null);

    // Round-tripped through the writer and reader, it is still there.
    var out: std.Io.Writer.Allocating = .init(aa);
    try writeMember(&out.writer, m);
    const again = try one(aa, out.written());
    try testing.expectEqual(@as(usize, 1), again.override.clis.len);
    try testing.expectEqualStrings("gpt-5", again.override.clis[0].over.model.?);

    // Against the role as it is now -- the same value on both sides -- the
    // model is still the squad's: the value cannot say so, `from_squad`
    // does, and a resolve that took "same as the role" for "follow the
    // role" would drop it here.
    const same = try resolve(aa, base_role, again.override, "codex", &.{}, null);
    try testing.expectEqualStrings("gpt-5", same.choice.model.?);
    var named = false;
    for (same.from_squad) |f| {
        if (std.mem.eql(u8, f, "model")) named = true;
    }
    try testing.expect(named);

    var changed = base_role;
    changed.clis = &.{.{ .cli = "codex", .model = "gpt-6" }};
    const r = try resolve(aa, changed, again.override, "codex", &.{}, null);
    try testing.expectEqualStrings("gpt-5", r.choice.model.?);
}

test "squad: instructions 覆盖是整段替换；空串也是覆盖（角色的指令不再使用）；不在场则跟角色" {
    var a = arena();
    defer a.deinit();
    const aa = a.allocator();

    const replaced = try one(aa,
        \\{"alias":"a","role":"worker-dev","override":{"instructions":"squad text"}}
    );
    const r = try resolve(aa, base_role, replaced.override, "codex", &.{}, null);
    try testing.expectEqualStrings("squad text", r.persona.instructions.?);
    try testing.expect(std.mem.indexOf(u8, r.persona.instructions.?, "role instructions") == null);

    const emptied = try one(aa,
        \\{"alias":"b","role":"worker-dev","override":{"instructions":""}}
    );
    const r2 = try resolve(aa, base_role, emptied.override, "codex", &.{}, null);
    try testing.expectEqual(@as(?[]const u8, null), r2.persona.instructions);

    const follows = try one(aa,
        \\{"alias":"c","role":"worker-dev"}
    );
    const r3 = try resolve(aa, base_role, follows.override, "codex", &.{}, null);
    try testing.expectEqualStrings("role instructions", r3.persona.instructions.?);
}

test "squad: 总管角色不能入队，解析即拒绝 SupervisorNotAllowed" {
    var a = arena();
    defer a.deinit();
    const aa = a.allocator();
    var diag: Diag = .{ .where = "" };

    const shipped =
        \\{"version":1,"squads":[{"key":"s","name":"S","members":[{"alias":"boss","role":"polter-supervisor","required":true}]}]}
    ;
    try testing.expectError(error.SupervisorNotAllowed, parseLeaky(aa, shipped, null, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.where, "boss") != null);

    // A role of the person's own that makes its terminal a supervisor, once
    // the library is known.
    const own = [_]persona.Persona{
        .{ .key = "my-boss", .name = "Boss", .polter = .{ .supervisor = true } },
        base_role,
    };
    const roles: persona.Set = .{ .personas = &own };
    const bytes =
        \\{"version":1,"squads":[{"key":"s","name":"S","members":[{"alias":"b","role":"my-boss","required":true}]}]}
    ;
    try testing.expectError(error.SupervisorNotAllowed, parseLeaky(aa, bytes, roles, &diag));
    // Not knowing the library, the same file reads: a role is not refused
    // for being something the reader cannot see.
    _ = try parseLeaky(aa, bytes, null, &diag);
    try testing.expectEqual(Status.supervisor_role, statusOf((try parseOk(aa, bytes)).squads[0].members[0], roles));
}

test "squad: 删角色时引用它的成员从所有小队摘掉，同一角色的两个别名都摘；lead 顺延；摘空的模版保留为空壳" {
    var a = arena();
    defer a.deinit();
    const aa = a.allocator();

    const set = try parseOk(aa,
        \\{"version":1,"squads":[
        \\ {"key":"one","name":"One","members":[
        \\   {"alias":"dev-a","role":"worker-dev","required":true,"lead":true},
        \\   {"alias":"dev-b","role":"worker-dev"},
        \\   {"alias":"test","role":"worker-test","required":true}]},
        \\ {"key":"two","name":"Two","members":[
        \\   {"alias":"only","role":"worker-dev","required":true}]},
        \\ {"key":"three","name":"Three","members":[
        \\   {"alias":"rev","role":"worker-review","required":true}]}]}
    );
    const dropped = try withoutMembers(aa, set, OneRole{ .key = "worker-dev" });
    // Both aliases of one, and the only seat of two.
    try testing.expectEqual(@as(usize, 3), dropped.removed.len);
    const one_after = dropped.set.find("one").?;
    try testing.expectEqual(@as(usize, 1), one_after.members.len);
    // The lead passes to the next required member.
    try testing.expectEqualStrings("test", one_after.leadOf().?.alias);
    try testing.expect(one_after.members[0].lead);
    // two is kept, as a shell.
    const two_after = dropped.set.find("two").?;
    try testing.expectEqual(@as(usize, 0), two_after.members.len);
    try testing.expectEqual(@as(usize, 3), dropped.set.squads.len);
    // three was not touched.
    try testing.expectEqualStrings("rev", dropped.set.find("three").?.members[0].alias);

    // What is left passes its own reader.
    var out: std.Io.Writer.Allocating = .init(aa);
    try writeSet(&out.writer, dropped.set);
    _ = try parseOk(aa, out.written());
}

test "squad: 全是可选成员的模版能读、能写，牵头回退到第一个成员；摘掉 lead 后 required 标记不变" {
    var a = arena();
    defer a.deinit();
    const aa = a.allocator();

    const set = try parseOk(aa,
        \\{"version":1,"squads":[{"key":"s","name":"S","members":[
        \\  {"alias":"dev","role":"worker-dev","required":true,"lead":true},
        \\  {"alias":"opt","role":"worker-test"}]}]}
    );
    const dropped = try withoutMembers(aa, set, OneRole{ .key = "worker-dev" });
    const m = dropped.set.squads[0].members[0];
    // The lead passes to the first remaining member, and nobody's
    // `required` changes: the one left was optional and still is.
    try testing.expect(m.lead);
    try testing.expect(!m.required);
    var out: std.Io.Writer.Allocating = .init(aa);
    try writeSet(&out.writer, dropped.set);
    _ = try parseOk(aa, out.written());

    // A squad whose members are all optional is a squad.
    const optional = try parseOk(aa,
        \\{"version":1,"squads":[{"key":"s","name":"S","members":[
        \\  {"alias":"a","role":"worker-dev"},
        \\  {"alias":"b","role":"worker-test"}]}]}
    );
    try testing.expectEqualStrings("a", optional.squads[0].leadOf().?.alias);
    // With a required one, it leads before the first.
    const mixed = try parseOk(aa,
        \\{"version":1,"squads":[{"key":"s","name":"S","members":[
        \\  {"alias":"a","role":"worker-dev"},
        \\  {"alias":"b","role":"worker-test","required":true}]}]}
    );
    try testing.expectEqualStrings("b", mixed.squads[0].leadOf().?.alias);
}

test "squad: 席位字经 +launch 的一行往返，空串指令覆盖仍在" {
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const aa = scratch.allocator();
    const m: Member = .{
        .alias = "开发",
        .role = "worker-dev",
        .required = true,
        .lead = true,
        .override = .{
            .cli = "codex",
            .clis = &.{},
            .instructions = "",
            .cli_skills = null,
            .cli_mcp = null,
            .skills = null,
            .mcp = null,
        },
    };
    const word = try encodeSeat(aa, m, "You are dev.");
    // Fit for a shell line without quoting.
    for (word) |c| try testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');

    const seat = try decodeSeatLeaky(aa, word);
    try testing.expectEqualStrings("开发", seat.member.alias);
    try testing.expectEqualStrings("You are dev.", seat.brief);
    try testing.expectEqualStrings("codex", seat.member.override.cli.?);
    // Present and empty: the squad said "none", which is not "the role's".
    try testing.expectEqualStrings("", seat.member.override.instructions.?);
    try testing.expect(!seat.member.lead);

    // What `+launch` does with it: the role's words are gone.
    const role: persona.Persona = .{ .key = "worker-dev", .name = "Dev", .instructions = "ROLE-WORDS" };
    const r = try resolve(aa, role, seat.member.override, "codex", &.{"codex"}, null);
    try testing.expect(r.persona.instructions == null);

    try testing.expectError(error.Malformed, decodeSeatLeaky(aa, "not-a-seat"));
}
