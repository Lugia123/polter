//! Personas: what the agent in one terminal has in its hands.
//!
//! A persona is "which tools, which skills, which upstream MCP slots, and
//! what opening prompt this terminal's agent gets". The user defines them in
//! a file; Polter honours them per terminal. See
//! `dev-docs/poltergeist/personas-contract.md` for the contract this
//! implements and `dev-docs/poltergeist/roles.md` for the design behind it.
//!
//! Two things live here and they are not the same thing:
//!
//!   * **The set** -- what is in `personas.json`. Since version 2 Polter
//!     writes it as well as reading it: the role library window and the
//!     supervisor's `role_put` / `role_delete` both go through
//!     `PersonaStore.put`, which is the one writer. `roles.md` §7 used to
//!     forbid any write path, on the grounds that editing a role grants a
//!     terminal capabilities; the user decided the supervisor gets the same
//!     powers as they have (roles.md part eleven), so the rule is now "one
//!     writer, every edit validated by the same parser that reads".
//!   * **The effective set** (`Face`) -- what a given terminal is actually
//!     handing out right now. Choosing a persona resets it; switching one
//!     skill on or off moves it alone. The two drifting apart is the state
//!     the interface has to show as "archer (modified)", so it is computed
//!     from the two rather than remembered, because a remembered flag is a
//!     flag that can disagree with what it describes.
//!
//! Pure: text and values in, values out. No file system, no sockets, no
//! knowledge of `rpc.Method` -- visibility is answered about a *name*, so
//! the module that owns the method list asks this one rather than the other
//! way round. That is also what keeps the import graph acyclic.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Longest a persona key may be. Keys go into keybinding action strings
/// (`poltergeist_persona_set:archer`), which is also why the charset below
/// is what it is.
pub const max_key_len = 32;

/// The file format version this understands.
///
/// It is not decoration. `personas.json` is hand-written, and without a
/// version there is nothing that tells "a file from an older Polter" apart
/// from "a file with a mistake in it" -- and those two want opposite
/// answers.
pub const supported_version: u32 = 2;

/// Whether a file of this version can be read. Version 1 is version 2
/// without `description`, `instructions` and `clis`, so it reads as a
/// version 2 file with those empty; it is written back as version 2.
pub fn versionKnown(n: i64) bool {
    return n == 1 or n == supported_version;
}

pub const ParseError = error{
    /// Not JSON, or not an object at the top.
    Malformed,

    /// `version` missing, or a number this build does not know.
    BadVersion,

    /// A persona is missing something it cannot do without.
    Incomplete,

    /// A field is present and its value makes no sense.
    BadField,

    /// Two personas claim the same key.
    DuplicateKey,

    OutOfMemory,
};

/// The tools a persona hands out.
///
/// `allow` absent means every tool; `deny` is applied afterwards. A pattern
/// is either a whole name or a prefix written with a trailing `*`, and
/// nothing else -- a fuller glob would be a second little language for the
/// user to get wrong, in the one file where getting it wrong quietly is
/// worst.
pub const Tools = struct {
    /// `null` is "all of them", which is not the same as an empty list.
    allow: ?[]const []const u8 = null,
    deny: []const []const u8 = &.{},
};

/// The tools no persona may take away, however it is written.
///
/// A worker that cannot say it finished is a worker that looks exactly like
/// a worker that died, and `me` / `skill_read` are how an agent finds out
/// what it is and what it may do at all. Denying one of these is always a
/// mistake, so it is ignored and reported rather than honoured -- the
/// alternative is a persona that produces a silently useless terminal.
pub const floor_tools = [_][]const u8{
    "me",
    "skill_read",
    "group_post",
    "task_progress",
    "task_list",
};

pub const Persona = struct {
    key: []const u8,
    name: []const u8,

    /// File name, relative to the personas directory. Delivered through the
    /// tool surface, never placed on disk as a skill -- skill directories
    /// are global or per project, so they cannot be made per terminal.
    prompt: ?[]const u8 = null,

    /// Polter's own skills, by name.
    skills: []const []const u8 = &.{},

    /// Slot names, without the `polter:` prefix.
    mcp: []const []const u8 = &.{},

    tools: Tools = .{},

    /// The half that only a restart can honour. Carried through as written
    /// and never acted on here.
    hint_disable_host_plugins: []const []const u8 = &.{},
    hint_model: ?[]const u8 = null,

    /// One line for a person choosing between roles. Shown, never sent to
    /// an agent.
    description: ?[]const u8 = null,

    /// Text the agent is started with, on top of its own system prompt.
    /// Handed to the adapter at launch, which decides the flag
    /// (`--append-system-prompt` for Claude Code).
    instructions: ?[]const u8 = null,

    /// What this role picks from each agent CLI it can be started in, in
    /// the order written. A CLI with no entry here is not offered for this
    /// role.
    clis: []const CliChoice = &.{},

    pub fn cli(self: Persona, key: []const u8) ?CliChoice {
        for (self.clis) |c| {
            if (std.mem.eql(u8, c.cli, key)) return c;
        }
        return null;
    }
};

/// Which of a CLI's own skills or MCP servers a role leaves on.
///
/// **A default plus exceptions, not a list of what is on.** A list of
/// what is on cannot tell "the user unticked this" from "this did not exist
/// when the role was written" -- and both happen all the time: a project's
/// skills only exist in that project, and the user installs things. The
/// person picks which of the two a new arrival should get, once, as
/// `default`; `except` is what they ticked the other way.
///
/// Ids are the adapter's (`skill:pdf`, `mcp:argus`) and opaque here.
pub const Selection = struct {
    default: bool = true,
    except: []const []const u8 = &.{},

    pub fn enabled(self: Selection, id: []const u8) bool {
        for (self.except) |e| {
            if (std.mem.eql(u8, e, id)) return !self.default;
        }
        return self.default;
    }
};

/// A role's choices for one agent CLI.
pub const CliChoice = struct {
    /// The adapter plugin's `agent_cli` key, e.g. `claude-code`.
    cli: []const u8,
    skills: Selection = .{},
    mcp: Selection = .{},
    /// Passed to the adapter, which knows the flag.
    model: ?[]const u8 = null,
    /// Appended to the command line as written.
    args: []const []const u8 = &.{},
};

/// Everything `personas.json` declared, in the order it declared it.
///
/// Order is the user's: it is what the menu is built from, so an array
/// rather than a map is the difference between the user being able to
/// arrange their own menu and not.
pub const Set = struct {
    version: u32 = supported_version,
    personas: []const Persona = &.{},

    /// Names a persona asked to deny that are on the floor. Kept so the
    /// interface can say so; an ignored instruction that says nothing is
    /// indistinguishable from an instruction that was honoured.
    ignored_denies: []const []const u8 = &.{},

    pub fn find(self: Set, key: []const u8) ?Persona {
        for (self.personas) |p| {
            if (std.mem.eql(u8, p.key, key)) return p;
        }
        return null;
    }
};

/// Keys are ours to constrain, because we invented them.
///
/// They go into keybinding action strings, and the Windows host asserts
/// every action string matches `[a-z0-9_:,-]`
/// (`windows/host/src/menu.rs`, `action_strings_have_a_binding_shape`). So
/// a key of `Archer` builds a string that gate reddens on.
///
/// ⚠️ **The same reasoning does not reach skill and slot names, and an
/// earlier draft of this applied it to them anyway.** Those names are other
/// people's -- this machine really has `claude_ai_Claude_Docs` and
/// `kanban:task-review` -- so constraining them would refuse legitimate
/// upstreams at the door. Names never enter an action string; a minted id
/// does. See the contract, §0.5.
pub fn isValidKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key_len) return false;
    for (key) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

pub fn isFloorTool(name: []const u8) bool {
    for (floor_tools) |f| {
        if (std.mem.eql(u8, f, name)) return true;
    }
    return false;
}

/// Whether `pattern` names `tool`. Whole name, or a prefix with a trailing
/// `*`.
fn patternMatches(pattern: []const u8, tool: []const u8) bool {
    if (pattern.len > 0 and pattern[pattern.len - 1] == '*') {
        return std.mem.startsWith(u8, tool, pattern[0 .. pattern.len - 1]);
    }
    return std.mem.eql(u8, pattern, tool);
}

/// Whether a terminal wearing `tools` may see the tool called `name`.
///
/// Answered about a name rather than about an enum value on purpose: the
/// list of tools lives with the request surface, and having that module ask
/// this one keeps the dependency pointing one way.
pub fn toolVisible(tools: Tools, name: []const u8) bool {
    if (isFloorTool(name)) return true;

    if (tools.allow) |allow| {
        var permitted = false;
        for (allow) |p| {
            if (patternMatches(p, name)) {
                permitted = true;
                break;
            }
        }
        if (!permitted) return false;
    }

    for (tools.deny) |p| {
        if (patternMatches(p, name)) return false;
    }

    return true;
}

// -------------------------------------------------------------- the file

fn requireString(obj: std.json.ObjectMap, field: []const u8) ParseError![]const u8 {
    const v = obj.get(field) orelse return error.Incomplete;
    return switch (v) {
        .string => |s| s,
        else => error.BadField,
    };
}

fn optionalString(obj: std.json.ObjectMap, field: []const u8) ParseError!?[]const u8 {
    const v = obj.get(field) orelse return null;
    return switch (v) {
        .string => |s| s,
        .null => null,
        else => error.BadField,
    };
}

fn stringArray(
    aa: Allocator,
    obj: std.json.ObjectMap,
    field: []const u8,
) ParseError![]const []const u8 {
    const v = obj.get(field) orelse return &.{};
    const arr = switch (v) {
        .array => |a| a,
        .null => return &.{},
        else => return error.BadField,
    };
    const out = try aa.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, i| {
        out[i] = switch (item) {
            .string => |s| s,
            else => return error.BadField,
        };
    }
    return out;
}

/// Read `personas.json`.
///
/// Everything returned borrows `aa`, including the strings, so the caller
/// holds one arena for the whole file.
///
/// **A file that does not parse produces an error and nothing else.** The
/// caller keeps the previous set and shows the message: loading the
/// personas that happened to be well formed would hand back a set that
/// looks exactly like a complete one.
pub fn parseLeaky(aa: Allocator, bytes: []const u8) ParseError!Set {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, bytes, .{}) catch
        return error.Malformed;

    const root = switch (parsed) {
        .object => |o| o,
        else => return error.Malformed,
    };

    const version: u32 = switch (root.get("version") orelse return error.BadVersion) {
        .integer => |n| if (versionKnown(n))
            @intCast(n)
        else
            return error.BadVersion,
        else => return error.BadVersion,
    };

    const list = switch (root.get("personas") orelse return error.Incomplete) {
        .array => |a| a,
        else => return error.BadField,
    };

    var personas: std.ArrayList(Persona) = .empty;
    var ignored: std.ArrayList([]const u8) = .empty;

    for (list.items) |entry| {
        const p = try personaOf(aa, entry, &ignored);
        for (personas.items) |q| {
            if (std.mem.eql(u8, q.key, p.key)) return error.DuplicateKey;
        }
        try personas.append(aa, p);
    }

    return .{
        .version = version,
        .personas = try personas.toOwnedSlice(aa),
        .ignored_denies = try ignored.toOwnedSlice(aa),
    };
}

/// Read one persona on its own, as `role_put` and the library window send
/// it.
///
/// **The same rules as the file, because it is the same function.** A
/// second validator for "one role arriving by itself" would be the second
/// reader the contract warns about: the looser of the two decides what can
/// get into the file.
pub fn parsePersonaLeaky(aa: Allocator, bytes: []const u8) ParseError!Persona {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, bytes, .{}) catch
        return error.Malformed;
    var ignored: std.ArrayList([]const u8) = .empty;
    return personaOf(aa, parsed, &ignored);
}

fn personaOf(
    aa: Allocator,
    entry: std.json.Value,
    ignored: *std.ArrayList([]const u8),
) ParseError!Persona {
    const obj = switch (entry) {
        .object => |o| o,
        else => return error.BadField,
    };

    const key = try requireString(obj, "key");
    if (!isValidKey(key)) return error.BadField;

    var tools: Tools = .{};
    if (obj.get("tools")) |tv| switch (tv) {
        .object => |t| {
            if (t.get("allow") != null) tools.allow = try stringArray(aa, t, "allow");
            const deny = try stringArray(aa, t, "deny");

            // The floor is applied here rather than at lookup time so
            // that the interface has something to show. A deny that is
            // quietly ignored and a deny that was honoured look the
            // same from outside.
            var kept: std.ArrayList([]const u8) = .empty;
            for (deny) |d| {
                if (isFloorTool(d)) {
                    try ignored.append(aa, d);
                } else {
                    try kept.append(aa, d);
                }
            }
            tools.deny = try kept.toOwnedSlice(aa);
        },
        .null => {},
        else => return error.BadField,
    };

    const name = try requireString(obj, "name");
    // A role with no name is a blank row in a menu. Refused here rather
    // than drawn, because the editor that would draw it is also the thing
    // that sent it.
    if (std.mem.trim(u8, name, " \t\r\n").len == 0) return error.BadField;

    var p: Persona = .{
        .key = key,
        .name = name,
        .prompt = try optionalString(obj, "prompt"),
        .skills = try stringArray(aa, obj, "skills"),
        .mcp = try stringArray(aa, obj, "mcp"),
        .tools = tools,
        .description = try optionalString(obj, "description"),
        .instructions = try optionalString(obj, "instructions"),
    };

    if (obj.get("hint")) |hv| switch (hv) {
        .object => |h| {
            p.hint_disable_host_plugins = try stringArray(aa, h, "disable_host_plugins");
            p.hint_model = try optionalString(h, "model");
        },
        .null => {},
        else => return error.BadField,
    };

    if (obj.get("clis")) |cv| switch (cv) {
        .object => |m| {
            const clis = try aa.alloc(CliChoice, m.count());
            var it = m.iterator();
            var i: usize = 0;
            while (it.next()) |kv| : (i += 1) {
                // The same charset as a role key, and for a similar reason:
                // it names a plugin, and plugin keys are plain names.
                if (!isValidKey(kv.key_ptr.*)) return error.BadField;
                clis[i] = try cliChoiceOf(aa, kv.key_ptr.*, kv.value_ptr.*);
            }
            p.clis = clis;
        },
        .null => {},
        else => return error.BadField,
    };

    return p;
}

fn cliChoiceOf(aa: Allocator, key: []const u8, v: std.json.Value) ParseError!CliChoice {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.BadField,
    };
    return .{
        .cli = key,
        .skills = try selectionOf(aa, obj, "skills"),
        .mcp = try selectionOf(aa, obj, "mcp"),
        .model = try optionalString(obj, "model"),
        .args = try stringArray(aa, obj, "args"),
    };
}

fn selectionOf(aa: Allocator, obj: std.json.ObjectMap, field: []const u8) ParseError!Selection {
    const v = obj.get(field) orelse return .{};
    const sel = switch (v) {
        .object => |o| o,
        .null => return .{},
        else => return error.BadField,
    };
    const default: bool = switch (sel.get("default") orelse std.json.Value{ .bool = true }) {
        .bool => |b| b,
        else => return error.BadField,
    };
    return .{ .default = default, .except = try stringArray(aa, sel, "except") };
}

// ---------------------------------------------------------- writing it back

/// Write a whole set as `personas.json`, always at the current version.
///
/// One persona per line group, keys in a fixed order, so the file stays
/// something a person can read and diff -- it is still theirs to edit by
/// hand.
///
/// ⚠️ A floor tool that a hand-written file tried to deny was dropped when
/// it was read (`ignored_denies`) and is not written back. It never had
/// any effect, so the file loses a line that was not doing anything.
pub fn writeSet(w: *std.Io.Writer, set: Set) std.Io.Writer.Error!void {
    try w.print("{{\n  \"version\": {d},\n  \"personas\": [", .{supported_version});
    for (set.personas, 0..) |p, i| {
        try w.writeAll(if (i == 0) "\n    " else ",\n    ");
        try writePersona(w, p);
    }
    try w.writeAll(if (set.personas.len == 0) "]\n}\n" else "\n  ]\n}\n");
}

/// One persona as a JSON object. Also what `role_list` answers with, so an
/// agent reads exactly the shape it would write.
pub fn writePersona(w: *std.Io.Writer, p: Persona) std.Io.Writer.Error!void {
    try w.print("{{\"key\":{f},\"name\":{f}", .{ jstr(p.key), jstr(p.name) });
    if (p.description) |d| try w.print(",\"description\":{f}", .{jstr(d)});
    if (p.instructions) |t| try w.print(",\"instructions\":{f}", .{jstr(t)});
    if (p.prompt) |t| try w.print(",\"prompt\":{f}", .{jstr(t)});
    if (p.skills.len > 0) {
        try w.writeAll(",\"skills\":");
        try writeStrings(w, p.skills);
    }
    if (p.mcp.len > 0) {
        try w.writeAll(",\"mcp\":");
        try writeStrings(w, p.mcp);
    }
    if (p.tools.allow != null or p.tools.deny.len > 0) {
        try w.writeAll(",\"tools\":{");
        var first = true;
        if (p.tools.allow) |a| {
            try w.writeAll("\"allow\":");
            try writeStrings(w, a);
            first = false;
        }
        if (p.tools.deny.len > 0) {
            if (!first) try w.writeAll(",");
            try w.writeAll("\"deny\":");
            try writeStrings(w, p.tools.deny);
        }
        try w.writeAll("}");
    }
    if (p.hint_disable_host_plugins.len > 0 or p.hint_model != null) {
        try w.writeAll(",\"hint\":{\"disable_host_plugins\":");
        try writeStrings(w, p.hint_disable_host_plugins);
        if (p.hint_model) |m| try w.print(",\"model\":{f}", .{jstr(m)});
        try w.writeAll("}");
    }
    if (p.clis.len > 0) {
        try w.writeAll(",\"clis\":{");
        for (p.clis, 0..) |c, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{f}:{{\"skills\":", .{jstr(c.cli)});
            try writeSelection(w, c.skills);
            try w.writeAll(",\"mcp\":");
            try writeSelection(w, c.mcp);
            if (c.model) |m| try w.print(",\"model\":{f}", .{jstr(m)});
            if (c.args.len > 0) {
                try w.writeAll(",\"args\":");
                try writeStrings(w, c.args);
            }
            try w.writeAll("}");
        }
        try w.writeAll("}");
    }
    try w.writeAll("}");
}

fn writeSelection(w: *std.Io.Writer, s: Selection) std.Io.Writer.Error!void {
    try w.print("{{\"default\":{},\"except\":", .{s.default});
    try writeStrings(w, s.except);
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

/// `set` with `p` in it: replacing the persona with the same key where it
/// stands, or appended at the end. Order is the user's menu order, so an
/// edit must not move a role.
pub fn withPersona(aa: Allocator, set: Set, p: Persona) Allocator.Error!Set {
    var out: std.ArrayList(Persona) = .empty;
    var replaced = false;
    for (set.personas) |q| {
        if (std.mem.eql(u8, q.key, p.key)) {
            try out.append(aa, p);
            replaced = true;
        } else try out.append(aa, q);
    }
    if (!replaced) try out.append(aa, p);
    return .{ .version = supported_version, .personas = try out.toOwnedSlice(aa) };
}

/// `set` without the persona called `key`, or null when there was none.
pub fn withoutPersona(aa: Allocator, set: Set, key: []const u8) Allocator.Error!?Set {
    var out: std.ArrayList(Persona) = .empty;
    var found = false;
    for (set.personas) |q| {
        if (std.mem.eql(u8, q.key, key)) {
            found = true;
        } else try out.append(aa, q);
    }
    if (!found) return null;
    return .{ .version = supported_version, .personas = try out.toOwnedSlice(aa) };
}

// ------------------------------------------------------- the effective set

/// What one terminal is handing out right now.
///
/// Slices borrow whatever arena the state holds; nothing here owns memory.
pub const Face = struct {
    tools: Tools = .{},
    skills: []const []const u8 = &.{},
    slots: []const []const u8 = &.{},
    prompt: ?[]const u8 = null,

    pub fn ofPersona(p: Persona) Face {
        return .{
            .tools = p.tools,
            .skills = p.skills,
            .slots = p.mcp,
            .prompt = p.prompt,
        };
    }

    pub fn eql(a: Face, b: Face) bool {
        if (!stringListEql(a.skills, b.skills)) return false;
        if (!stringListEql(a.slots, b.slots)) return false;
        if ((a.prompt == null) != (b.prompt == null)) return false;
        if (a.prompt) |ap| if (!std.mem.eql(u8, ap, b.prompt.?)) return false;

        if ((a.tools.allow == null) != (b.tools.allow == null)) return false;
        if (a.tools.allow) |aa_| if (!stringListEql(aa_, b.tools.allow.?)) return false;
        return stringListEql(a.tools.deny, b.tools.deny);
    }
};

fn stringListEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// A terminal's persona state. Lives and dies with the surface; nothing
/// here is written to disk.
///
/// **Keyed by `Bus.Id` by whoever holds it**, which is safe because that id
/// is a fresh random `u64` per surface (`Surface.zig`, where 0 and
/// `not_a_terminal` are drawn again) and is never reused. Keying it by a
/// small index would alias one terminal onto another the moment ids were
/// recycled.
pub const State = struct {
    /// Which preset the user chose. `null` means they never chose one.
    key: ?[]const u8 = null,

    /// What is actually handed out. When `key` is null this is the default:
    /// everything, which is what Polter does today.
    effective: Face = .{},

    /// Version of *anything* about this terminal's persona, including an
    /// upstream's health. Every change bumps it, and `persona_wait` wakes on
    /// it.
    ///
    /// ⚠️ **This is not the number the ids are built on.** See `roster`.
    epoch: u64 = 0,

    /// Version of the **composition** of the lists an id indexes into:
    /// which skills and which slots are there, and in what order. Bumped
    /// only when a row appears, disappears or moves.
    ///
    /// # Why this is a second number
    ///
    /// An id is `<roster>-<index>`, and the question it has to answer is
    /// "does this index still denote the row the user was looking at". That
    /// depends on the composition of the list and on nothing else.
    ///
    /// Keying ids off `epoch` instead looks tidier and is wrong in a way
    /// that is hard to argue with afterwards: an unrelated upstream dying
    /// bumps `epoch`, so the switch the user is clicking **right now** --
    /// which has not moved, changed or gone anywhere -- is refused, and
    /// refused correctly, with a reason that has nothing to do with what
    /// they did. A refusal that is both accurate and irrelevant is worse
    /// than a wrong one, because there is nothing for the user to fix.
    ///
    /// Not bumping `epoch` for health instead is the other half of the same
    /// trap: then the editor, which reads the face when it opens, never
    /// finds out that a slot has broken.
    ///
    /// So: `epoch` moves for everything, `roster` moves for composition.
    ///
    /// **What makes a composition-valid but stale click safe** is that the
    /// actions are absolute, not toggles: `on,<id>` and `off,<id>` say
    /// which state to end in. A click sent against a list whose *contents*
    /// moved while its *shape* did not still lands on the row the user
    /// pointed at and leaves it in the state they asked for.
    roster: u64 = 0,

    /// Whether the effective set has moved away from what the chosen
    /// persona declared.
    ///
    /// **Computed, never stored.** A stored flag is a second copy that can
    /// disagree with the thing it describes, and the disagreement shows up
    /// as "archer" where the truth is "archer (modified)" -- the interface
    /// lying quietly, which is the one failure this whole state exists to
    /// prevent.
    pub fn deviated(self: State, set: Set) bool {
        const key = self.key orelse return false;
        const p = set.find(key) orelse return false;
        return !self.effective.eql(.ofPersona(p));
    }

    /// Note a change that leaves the rows where they are -- a switch
    /// flipped, an upstream that has died or come back.
    pub fn touch(self: *State) void {
        self.epoch += 1;
    }

    /// Note a change to which rows exist. Always a change of both, because
    /// every composition change is also a change.
    fn touchRoster(self: *State) void {
        self.epoch += 1;
        self.roster += 1;
    }

    pub fn setPersona(self: *State, p: Persona) void {
        self.key = p.key;
        self.effective = .ofPersona(p);
        self.touchRoster();
    }

    pub fn clear(self: *State) void {
        self.key = null;
        self.effective = .{};
        self.touchRoster();
    }
};

/// What a slot is doing, which is not the same question as whether the
/// persona asked for it.
///
/// ⚠️ **`withheld` and `broken` must never be drawn alike.** Both leave the
/// agent with no tools from that upstream, so without this field the
/// interface can only say "off" -- and a user who reads "the persona gave
/// me argus but the agent has not got it" as "off" goes and edits the
/// persona, when what they needed was to look at why that server will not
/// start. `roles.md` §10 lists this as the thing not to let happen and this
/// field is how the editor avoids it.
pub const SlotStatus = enum {
    /// No answer was ever obtained, so the upstream is passed through whole.
    transparent,
    /// Wanted, running.
    granted,
    /// Not wanted. The upstream process is not started at all.
    withheld,
    /// Wanted, and it will not start or has died.
    broken,
};

/// An id handed to the interface and handed back by it.
///
/// The menu is built now and clicked later, so a bare index is not an
/// identity: take an entry out and put it back and the numbering is reused,
/// and the click lands on something else. Pairing the index with the epoch
/// fixes that without a table of stable ids to maintain -- `8-3` means "row
/// 3 of version 8", and version 8 is immutable, so version 9 must refuse it
/// rather than accept a number that happens to still be in range.
pub const Id = struct {
    roster: u64,
    index: usize,

    pub fn format(self: Id, writer: *std.Io.Writer) !void {
        try writer.print("{d}-{d}", .{ self.roster, self.index });
    }

    pub fn parse(text: []const u8) ?Id {
        const dash = std.mem.indexOfScalar(u8, text, '-') orelse return null;
        const roster = std.fmt.parseInt(u64, text[0..dash], 10) catch return null;
        const index = std.fmt.parseInt(usize, text[dash + 1 ..], 10) catch return null;
        return .{ .roster = roster, .index = index };
    }
};

/// Why an id was refused. There is no "silently ignored": a stale id and a
/// click that did nothing are the same thing from where the user sits, so
/// the reason has to come back.
pub const IdError = error{
    /// Not `<epoch>-<index>`.
    Unreadable,

    /// Built against a list whose composition has since changed, so this
    /// index no longer denotes the row the user was pointing at.
    Stale,

    /// Right version, no such row.
    OutOfRange,
};

pub fn resolveId(state: State, text: []const u8, len: usize) IdError!usize {
    const id = Id.parse(text) orelse return error.Unreadable;
    // `roster`, not `epoch`: the question is whether this index still means
    // the row it meant, and that turns on the shape of the list, not on
    // anything that has happened to the things in it.
    if (id.roster != state.roster) return error.Stale;
    if (id.index >= len) return error.OutOfRange;
    return id.index;
}

// ----------------------------------------------------------------- tests

const testing = std.testing;

/// A file with one of everything, used by several tests below.
const sample =
    \\{"version":1,"personas":[
    \\  {"key":"archer","name":"射手",
    \\   "prompt":"archer.md",
    \\   "skills":["reading-a-terminal"],
    \\   "mcp":["argus"],
    \\   "tools":{"allow":["terminal_*","group_*","task_*"],"deny":["notify_user"]},
    \\   "hint":{"disable_host_plugins":["kanban@x"],"model":"sonnet"}},
    \\  {"key":"scribe","name":"书记"}
    \\]}
;

test "persona: the sample file loads with every field where it was put" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const set = try parseLeaky(aa, sample);
    try testing.expectEqual(@as(usize, 2), set.personas.len);

    const archer = set.find("archer").?;
    try testing.expectEqualStrings("射手", archer.name);
    try testing.expectEqualStrings("archer.md", archer.prompt.?);
    try testing.expectEqualStrings("reading-a-terminal", archer.skills[0]);
    try testing.expectEqualStrings("argus", archer.mcp[0]);
    try testing.expectEqualStrings("sonnet", archer.hint_model.?);
    try testing.expectEqualStrings("kanban@x", archer.hint_disable_host_plugins[0]);

    // Order is the user's, and the menu is built from it.
    try testing.expectEqualStrings("archer", set.personas[0].key);
    try testing.expectEqualStrings("scribe", set.personas[1].key);

    // Absent lists are empty, not missing.
    const scribe = set.find("scribe").?;
    try testing.expectEqual(@as(usize, 0), scribe.skills.len);
    try testing.expectEqual(@as(?[]const []const u8, null), scribe.tools.allow);
}

test "persona: a tool the persona denied is not visible, and one it allowed is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const set = try parseLeaky(aa, sample);
    const archer = set.find("archer").?;

    // **This is the assertion the whole filter exists for.** `notify_user`
    // is denied by name; `plugin_list` is outside the allow list and so
    // never reached; `terminal_read` is inside it.
    try testing.expect(!toolVisible(archer.tools, "notify_user"));
    try testing.expect(!toolVisible(archer.tools, "plugin_list"));
    try testing.expect(toolVisible(archer.tools, "terminal_read"));
    try testing.expect(toolVisible(archer.tools, "group_read"));

    // A persona that says nothing about tools hands out all of them.
    const scribe = set.find("scribe").?;
    try testing.expect(toolVisible(scribe.tools, "plugin_list"));
}

test "persona: denying a floor tool is ignored and said out loud" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const set = try parseLeaky(aa,
        \\{"version":1,"personas":[{"key":"mute","name":"m",
        \\  "tools":{"deny":["task_progress","notify_user"]}}]}
    );

    const mute = set.find("mute").?;

    // The one that matters: a worker that cannot report is a worker that
    // looks exactly like a worker that died.
    try testing.expect(toolVisible(mute.tools, "task_progress"));
    try testing.expect(!toolVisible(mute.tools, "notify_user"));

    // Ignored is not the same as honoured, so it has to be reportable.
    try testing.expectEqual(@as(usize, 1), set.ignored_denies.len);
    try testing.expectEqualStrings("task_progress", set.ignored_denies[0]);

    // A wildcard that sweeps the floor up does not take it either.
    const swept: Tools = .{ .deny = &.{"task_*"} };
    try testing.expect(toolVisible(swept, "task_progress"));
    try testing.expect(toolVisible(swept, "task_list"));
    try testing.expect(!toolVisible(swept, "task_create"));
}

test "persona: a file that does not parse yields nothing at all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Partially loading would hand back a set that looks complete.
    try testing.expectError(error.Malformed, parseLeaky(aa, "not json"));
    try testing.expectError(error.BadVersion, parseLeaky(aa,
        \\{"personas":[]}
    ));
    try testing.expectError(error.BadVersion, parseLeaky(aa,
        \\{"version":99,"personas":[]}
    ));
    try testing.expectError(error.BadField, parseLeaky(aa,
        \\{"version":1,"personas":[{"key":"Archer","name":"n"}]}
    ));
    try testing.expectError(error.Incomplete, parseLeaky(aa,
        \\{"version":1,"personas":[{"key":"a"}]}
    ));
    try testing.expectError(error.DuplicateKey, parseLeaky(aa,
        \\{"version":1,"personas":[{"key":"a","name":"1"},{"key":"a","name":"2"}]}
    ));
}

test "persona: keys are constrained, names are not" {
    try testing.expect(isValidKey("archer"));
    try testing.expect(isValidKey("archer-2"));
    try testing.expect(!isValidKey("Archer"));
    try testing.expect(!isValidKey("my role"));
    try testing.expect(!isValidKey(""));
    try testing.expect(!isValidKey("a" ** (max_key_len + 1)));

    // ⚠️ The names really on this machine, which an earlier draft would
    // have refused at the door. They never enter an action string, so
    // nothing here has an opinion about them.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const set = try parseLeaky(arena.allocator(),
        \\{"version":1,"personas":[{"key":"wide","name":"w",
        \\  "skills":["kanban:task-review"],
        \\  "mcp":["claude_ai_Claude_Docs"]}]}
    );
    const wide = set.find("wide").?;
    try testing.expectEqualStrings("kanban:task-review", wide.skills[0]);
    try testing.expectEqualStrings("claude_ai_Claude_Docs", wide.mcp[0]);
}

test "persona: choosing resets, amending deviates, and the epoch moves either way" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const set = try parseLeaky(aa, sample);
    var state: State = .{};
    try testing.expect(!state.deviated(set));

    state.setPersona(set.find("archer").?);
    try testing.expectEqual(@as(u64, 1), state.epoch);
    try testing.expectEqual(@as(u64, 1), state.roster);
    try testing.expect(!state.deviated(set));

    // Switch one skill off by hand: the key stays, the effective set moves,
    // and the interface must now say "archer (modified)".
    state.effective.skills = &.{};
    state.touch();
    try testing.expect(state.deviated(set));
    try testing.expectEqualStrings("archer", state.key.?);

    // Choosing the persona again resets it rather than merging.
    state.setPersona(set.find("archer").?);
    try testing.expect(!state.deviated(set));

    state.clear();
    try testing.expect(state.key == null);
    try testing.expect(!state.deviated(set));
}

test "persona: an id built against an older list is refused, not reused" {
    var state: State = .{ .epoch = 8, .roster = 8 };

    try testing.expectEqual(@as(usize, 3), try resolveId(state, "8-3", 5));

    // The failure a bare index would have produced silently: the row is
    // still in range, and without a version this would have been accepted
    // and landed on whatever is at index 3 now.
    state.roster = 9;
    state.epoch = 9;
    try testing.expectError(error.Stale, resolveId(state, "8-3", 5));

    try testing.expectError(error.OutOfRange, resolveId(state, "9-5", 5));
    try testing.expectError(error.Unreadable, resolveId(state, "nine-five", 5));
    try testing.expectError(error.Unreadable, resolveId(state, "93", 5));
}

test "persona: an unrelated upstream dying does not invalidate a click" {
    // **The whole reason there are two numbers.** A slot somewhere else on
    // this terminal breaking is a change -- the editor has to see it, and
    // `persona_wait` has to wake for it -- but it moves no row, so the id
    // the user is clicking right now still means what it meant.
    //
    // Keyed off `epoch` this would be `error.Stale`: a refusal that is
    // accurate, and about something the user did not do and cannot fix.
    var state: State = .{ .epoch = 8, .roster = 8 };

    state.touch(); // an upstream died

    try testing.expectEqual(@as(u64, 9), state.epoch);
    try testing.expectEqual(@as(u64, 8), state.roster);
    try testing.expectEqual(@as(usize, 3), try resolveId(state, "8-3", 5));

    // And the other half: when the rows really do move, the id goes.
    var moved: State = .{ .epoch = 8, .roster = 8 };
    moved.setPersona(.{ .key = "archer", .name = "n" });
    try testing.expectError(error.Stale, resolveId(moved, "8-3", 5));
}

test "persona: a version 1 file still reads, as a role with no CLI choices" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const set = try parseLeaky(arena.allocator(), sample);
    try testing.expectEqual(@as(u32, 1), set.version);
    try testing.expectEqual(@as(usize, 0), set.personas[0].clis.len);
    try testing.expectEqual(@as(?[]const u8, null), set.personas[0].instructions);

    // And a version that is neither is still refused, so an older Polter
    // reading a newer file says so instead of guessing.
    try testing.expectError(error.BadVersion, parseLeaky(
        arena.allocator(),
        "{\"version\":3,\"personas\":[]}",
    ));
}

test "persona: what is written reads back as the same roles" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const text =
        \\{"version":2,"personas":[
        \\  {"key":"archer","name":"射手","description":"只读调研",
        \\   "instructions":"Say \"hi\" first.\nThen work.",
        \\   "skills":["reading-a-terminal"],"mcp":["argus"],
        \\   "tools":{"deny":["notify_user"]},
        \\   "hint":{"disable_host_plugins":["k@x"],"model":"sonnet"},
        \\   "clis":{"claude-code":{"skills":{"default":false,"except":["skill:pdf"]},
        \\                          "mcp":{"default":true,"except":["mcp:argus"]},
        \\                          "model":"opus","args":["--verbose"]},
        \\           "codex":{}}},
        \\  {"key":"scribe","name":"书记"}
        \\]}
    ;
    const first = try parseLeaky(aa, text);

    var out: std.Io.Writer.Allocating = .init(aa);
    try writeSet(&out.writer, first);
    const again = try parseLeaky(aa, out.written());

    try testing.expectEqual(supported_version, again.version);
    try testing.expectEqual(@as(usize, 2), again.personas.len);
    const a = again.personas[0];
    try testing.expectEqualStrings("只读调研", a.description.?);
    try testing.expectEqualStrings("Say \"hi\" first.\nThen work.", a.instructions.?);
    try testing.expectEqualStrings("notify_user", a.tools.deny[0]);
    try testing.expectEqualStrings("sonnet", a.hint_model.?);
    try testing.expectEqual(@as(usize, 2), a.clis.len);

    // Order of the CLIs is the order written: it is the order they are
    // offered in.
    const cc = a.clis[0];
    try testing.expectEqualStrings("claude-code", cc.cli);
    try testing.expect(!cc.skills.default);
    try testing.expectEqualStrings("skill:pdf", cc.skills.except[0]);
    try testing.expectEqualStrings("opus", cc.model.?);
    try testing.expectEqualStrings("--verbose", cc.args[0]);
    try testing.expectEqualStrings("codex", a.clis[1].cli);
    try testing.expect(a.clis[1].skills.default);

    try testing.expectEqualStrings("书记", again.personas[1].name);
}

test "persona: a default and its exceptions decide what is on" {
    const keep_all: Selection = .{ .default = true, .except = &.{"mcp:argus"} };
    try testing.expect(keep_all.enabled("mcp:kanban"));
    try testing.expect(!keep_all.enabled("mcp:argus"));

    // The case a list-of-what-is-on could not express: something installed
    // after the role was written gets the default, not "off because nobody
    // ticked it".
    const keep_none: Selection = .{ .default = false, .except = &.{"skill:pdf"} };
    try testing.expect(keep_none.enabled("skill:pdf"));
    try testing.expect(!keep_none.enabled("skill:installed-yesterday"));
}

test "persona: one role arriving by itself obeys the file's rules" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const p = try parsePersonaLeaky(aa,
        \\{"key":"new-one","name":"新角色","clis":{"claude-code":{}}}
    );
    try testing.expectEqualStrings("new-one", p.key);
    try testing.expectEqualStrings("claude-code", p.clis[0].cli);

    try testing.expectError(error.BadField, parsePersonaLeaky(aa,
        \\{"key":"Archer","name":"x"}
    ));
    try testing.expectError(error.BadField, parsePersonaLeaky(aa,
        \\{"key":"a","name":"   "}
    ));
    try testing.expectError(error.Incomplete, parsePersonaLeaky(aa,
        \\{"key":"a"}
    ));
    try testing.expectError(error.BadField, parsePersonaLeaky(aa,
        \\{"key":"a","name":"n","clis":{"Claude Code":{}}}
    ));
}

test "persona: an edit keeps the role where it was, a new one goes last" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const set = try parseLeaky(aa, sample);

    const edited = try withPersona(aa, set, .{ .key = "archer", .name = "新名字" });
    try testing.expectEqualStrings("archer", edited.personas[0].key);
    try testing.expectEqualStrings("新名字", edited.personas[0].name);
    try testing.expectEqual(@as(usize, 2), edited.personas.len);

    const added = try withPersona(aa, set, .{ .key = "zz", .name = "z" });
    try testing.expectEqualStrings("zz", added.personas[2].key);

    const gone = (try withoutPersona(aa, set, "archer")).?;
    try testing.expectEqual(@as(usize, 1), gone.personas.len);
    try testing.expectEqualStrings("scribe", gone.personas[0].key);
    try testing.expectEqual(@as(?Set, null), try withoutPersona(aa, set, "nobody"));
}
