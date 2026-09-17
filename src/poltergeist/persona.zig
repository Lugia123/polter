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
//!   * **The set** -- what the user wrote in `personas.json`. Read only,
//!     never written by Polter. That is not tidiness: `roles.md` §7 requires
//!     a persona to be a closed set the *user* defines, and the way that is
//!     enforced is that **no write path exists**. A tool that could edit one
//!     would be a tool that grants a terminal capabilities the user never
//!     agreed to.
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
pub const supported_version: u32 = 1;

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
        .integer => |n| if (n == supported_version)
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
        const obj = switch (entry) {
            .object => |o| o,
            else => return error.BadField,
        };

        const key = try requireString(obj, "key");
        if (!isValidKey(key)) return error.BadField;
        for (personas.items) |p| {
            if (std.mem.eql(u8, p.key, key)) return error.DuplicateKey;
        }

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

        var p: Persona = .{
            .key = key,
            .name = try requireString(obj, "name"),
            .prompt = try optionalString(obj, "prompt"),
            .skills = try stringArray(aa, obj, "skills"),
            .mcp = try stringArray(aa, obj, "mcp"),
            .tools = tools,
        };

        if (obj.get("hint")) |hv| switch (hv) {
            .object => |h| {
                p.hint_disable_host_plugins = try stringArray(aa, h, "disable_host_plugins");
                p.hint_model = try optionalString(h, "model");
            },
            .null => {},
            else => return error.BadField,
        };

        try personas.append(aa, p);
    }

    return .{
        .version = version,
        .personas = try personas.toOwnedSlice(aa),
        .ignored_denies = try ignored.toOwnedSlice(aa),
    };
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
        \\{"version":2,"personas":[]}
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
