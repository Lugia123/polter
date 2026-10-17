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
const official = @import("official.zig");

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
pub const supported_version: u32 = 3;

/// Whether a file of this version can be read. Version 1 is version 2
/// without `description`, `instructions` and `clis`, so it reads as a
/// version 2 file with those empty. Version 2 kept a CLI's own skills and
/// MCP servers once per CLI; version 3 keeps one set for the role
/// (`cli_skills`, `cli_mcp`) and a version 2 file's are merged into it
/// (`mergeLegacy`). Both are written back as version 3.
///
/// ⚠️ **3 and not 2 with two more fields** (task 1677): a Polter that
/// reads only version 2 would read a version 3 file, find no per-CLI
/// selection, and write every role back with all of the CLI's skills and
/// servers on. Refusing the file is what keeps an older build from doing
/// that.
pub fn versionKnown(n: i64) bool {
    return n >= 1 and n <= supported_version;
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

    /// Which of the CLI's own skills and MCP servers the role leaves on --
    /// **one set for every CLI the role is started in** (task 1677). Ids
    /// are the adapters' and the two adapters write them alike (`skill:pdf`,
    /// `mcp:github`), so an id that only one CLI has is a switch that only
    /// does anything there. Polter's own server and skills are never the
    /// role's to switch off; the adapter keeps them whatever this says.
    cli_skills: Selection = .{},
    cli_mcp: Selection = .{},

    /// What Polter does with the terminal it is started in. See `Polter`.
    polter: Polter = .{},

    /// Null for a role somebody wrote. For one Polter ships
    /// (`official.zig`), where it stands against what shipped. Never
    /// written to `personas.json`, and nothing read from a file sets it.
    official: ?Official = null,

    pub fn cli(self: Persona, key: []const u8) ?CliChoice {
        for (self.clis) |c| {
            if (std.mem.eql(u8, c.cli, key)) return c;
        }
        return null;
    }

    /// The CLI to start this role in when nobody said which (task 1677),
    /// in this order:
    ///
    ///   1. of the CLIs it is set up for, the only one this machine has an
    ///      adapter for (`available`, the keys `agent_cli.discover` found:
    ///      plugin on, adapter runnable);
    ///   2. of several here, the one the agent that asked is running in
    ///      (`by`) -- a supervisor in Codex opens Codex workers;
    ///   3. otherwise `ChooseCli`.
    ///
    /// A role set up for exactly one CLI is that one whatever `available`
    /// says: whether it can start is the launch's question, which answers
    /// it with the reason, not this one's.
    ///
    /// **Why `available` is asked at all** (task 1667): the official roles
    /// are set up for Claude Code and Codex both, and the Codex plugin is
    /// off until the person turns it on. Without it, every launch that
    /// names no CLI would have started answering `ChooseCli` on the day the
    /// second CLI was added, on machines with nothing to choose between.
    pub fn defaultCli(
        self: Persona,
        available: []const []const u8,
        by: ?[]const u8,
    ) error{ NoCli, ChooseCli }![]const u8 {
        switch (self.clis.len) {
            0 => return error.NoCli,
            1 => return self.clis[0].cli,
            else => {},
        }
        var found: ?[]const u8 = null;
        var several = false;
        for (self.clis) |c| {
            if (!has(available, c.cli)) continue;
            if (found != null) several = true else found = c.cli;
        }
        if (!several) return found orelse error.ChooseCli;
        if (by) |own| for (self.clis) |c| {
            if (std.mem.eql(u8, c.cli, own) and has(available, own)) return c.cli;
        };
        return error.ChooseCli;
    }

    fn has(list: []const []const u8, item: []const u8) bool {
        for (list) |x| if (std.mem.eql(u8, x, item)) return true;
        return false;
    }
};

/// Where an official role stands against the one this build ships.
///
/// **No field has a default, on purpose.** "Nothing was changed" and "what
/// was changed could not be read" are both a role that looks like the
/// shipped one, and the difference is the whole of what this says; a
/// default would let one of them be written by leaving a line out. The one
/// that needs no thought has a name instead: `pristine`.
pub const Official = struct {
    state: Status,
    /// The fields the person changed, as paths (`official.targetOf`).
    overridden: []const []const u8,
    /// Those among them the official role has changed since.
    stale: []const []const u8,
    /// Why, when `state` is `unknown`. Words for the person.
    reason: ?[]const u8,

    pub const Status = enum {
        /// As shipped.
        pristine,
        /// Changed by the person; the official fields under the changes are
        /// as they were when they changed them.
        modified,
        /// Changed by the person, and at least one of the fields they
        /// changed has since changed in the official role too.
        modified_stale,
        /// Something is written for this role and it could not be read.
        /// What is in effect is the shipped role.
        unknown,
    };

    pub const pristine: Official = .{
        .state = .pristine,
        .overridden = &.{},
        .stale = &.{},
        .reason = null,
    };
};

/// What Polter does with a terminal a role is **started** in.
///
/// The CLI half of a role (`clis`) says what the agent is given; this half
/// says what the terminal *is* in Polter -- the standing the user would
/// otherwise set by hand, one menu at a time, after every launch.
///
/// **Applied once, at the start, and never again.** After that the standing
/// is the terminal's own: the user can take it away and the role does not
/// put it back, and putting a role on a terminal that is already running
/// changes its tools, not who it is. A worker switched into the supervisor
/// role would otherwise start minding other terminals with nobody having
/// asked it to -- the one change here that is not visible where it happens.
///
/// ⚠️ **Three of these grant something, and only the user may set them**:
/// `supervisor`, `may_authorise`, `shielded`. A supervisor can write roles
/// (`role_put`) and start them (`role_launch`); if it could also tick
/// "may answer permission prompts" it could hand itself that power by
/// writing a role and starting it. `userOnlyEql` is what `PersonaStore.put`
/// holds a supervisor's write to.
pub const Polter = struct {
    /// Make the terminal a supervisor, as the menu's "Supervise" does.
    supervisor: bool = false,

    /// Let a supervisor answer this terminal's permission prompts.
    ///
    /// **It only ever adds.** `true` switches it on for the terminal the
    /// role is started in; `false` leaves the terminal as the person's
    /// default has it (`poltergeist-may-authorise`, on unless they turned
    /// it off) and is **not** a refusal. Every role saved before 2026-10-12
    /// carries an explicit `false`, written when off was the default and
    /// meaning nothing more than "not ticked"; reading those as "refuse"
    /// would switch the supervisor off in every terminal started from a
    /// saved role, on the strength of a tick nobody withheld. A terminal
    /// that must not be answered for is shielded, or switched off from its
    /// own menu.
    may_authorise: bool = false,

    /// Out of reach of every tool, a supervisor's included.
    shielded: bool = false,

    /// Put it under the eye of the supervisor that started it -- or, when
    /// the user started it, of the one supervisor there is. With none, or
    /// with several and the user starting it, nobody: which of two
    /// supervisors should mind a terminal is not the program's to guess.
    watch: bool = false,

    /// Where clicking the role starts it.
    open: Open = .auto,

    /// How long the screen may be still before it is reported, when it is
    /// watched. Null keeps the configured default.
    quiet_ms: ?u64 = null,

    pub const Open = enum {
        /// Polter decides from what is running there (`App.choosePersona`):
        /// this terminal if it is at a shell prompt, a new tab if not.
        auto,
        /// A new tab, whatever the terminal clicked in is doing.
        tab,
    };

    pub fn isDefault(self: Polter) bool {
        return std.meta.eql(self, Polter{});
    }

    /// Whether `a` and `b` agree on everything only the user may set.
    pub fn userOnlyEql(a: Polter, b: Polter) bool {
        return a.supervisor == b.supervisor and
            a.may_authorise == b.may_authorise and
            a.shielded == b.shielded;
    }
};

/// What an agent started in a supervisor role is told, before the role's
/// own instructions.
///
/// Part of the launch rather than of any one role's text: a role the user
/// writes with "make this terminal a supervisor" ticked and nothing typed
/// in the instructions would otherwise start an agent that is a supervisor
/// and does not know it. The notice the menu's "Supervise" sends
/// (`Surface.zig`, `.poltergeist_supervisor`) cannot do this job -- at
/// launch there is no agent yet, so it would be printed to the shell.
pub const supervisor_launch_note =
    "You were started in a Polter terminal that has been made the supervisor " ++
    "of this window's terminals. Before doing anything else, read the " ++
    "`supervising` skill with the polter MCP tool skill_read, and follow it -- " ++
    "including making a group for the work and keeping its brief current. " ++
    "Talk to the terminals you supervise through the group and task tools: " ++
    "only what goes through them is written down and survives a restart.";

/// What an agent started as the supervisor **of a group** is told instead:
/// the control room started it for that group (`ControlAct`,
/// `start_supervisor`), so the group is there already and is the first
/// thing to read. Telling it to make a group, as the note above does, is
/// how the morning after came to have two groups for one piece of work.
///
/// The group's name goes between the two halves.
pub const supervisor_of_group_note = [2][]const u8{
    "You were started in a Polter terminal as the supervisor of the group `",
    "`: the person started you for that group from the control room, and you " ++
        "are put in it as you connect. Before doing anything else, read the " ++
        "`supervising` skill with the polter MCP tool skill_read, and follow " ++
        "it. Do not make a group for this work -- that one is yours. Call `me` " ++
        "(its `started_for` names the group), then read what the group " ++
        "already holds before arranging anything: its brief (group_list), " ++
        "what was said in it (group_read, group_history) and its panel " ++
        "(task_list, task_history). If this is a session of yours from " ++
        "before, what you remember may be older than what the group holds: " ++
        "the group and the panel are the record. Keep the brief current, and " ++
        "talk to the terminals you supervise through the group and task " ++
        "tools: only what goes through them is written down and survives a " ++
        "restart.",
};

/// The instructions an agent started in `p` is given: the supervisor note
/// when the role makes it one -- the one that names `group` when it was
/// started for one -- then the role's own. Null when both are absent.
pub fn launchInstructions(aa: Allocator, p: Persona, group: ?[]const u8) Allocator.Error!?[]const u8 {
    if (!p.polter.supervisor) return p.instructions;
    const note: []const u8 = if (group) |g|
        try std.mem.concat(aa, u8, &.{ supervisor_of_group_note[0], g, supervisor_of_group_note[1] })
    else
        supervisor_launch_note;
    const own = p.instructions orelse return note;
    return try std.mem.concat(aa, u8, &.{ note, "\n\n", own });
}

// ------------------------------------------------------ the official roles

/// The roles Polter ships are data, not code: `official.zig` has where they
/// come from and how what a person changed in one is kept. Two keys are
/// named here because code asks for those roles by name.
pub const supervisor_key = "polter-supervisor";
pub const tester_key = "polter-tester";

/// How many official roles this build carries. They come first in every
/// set.
pub const official_count = official.sources.len;

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

    /// Everything on, which is what a role that says nothing gets.
    pub fn isAll(self: Selection) bool {
        return self.default and self.except.len == 0;
    }

    pub fn enabled(self: Selection, id: []const u8) bool {
        for (self.except) |e| {
            if (std.mem.eql(u8, e, id)) return !self.default;
        }
        return self.default;
    }
};

/// A role's choices for one agent CLI: what only that CLI has a word for.
/// Which of its skills and servers are on is the role's, not this
/// (`Persona.cli_skills`).
pub const CliChoice = struct {
    /// The adapter plugin's `agent_cli` key, e.g. `claude-code`.
    cli: []const u8,
    /// Passed to the adapter, which knows the flag.
    model: ?[]const u8 = null,
    /// Appended to the command line as written.
    args: []const []const u8 = &.{},
    /// The adapter's launch options (its inventory's `options`): which
    /// value of each the role picks. An option not here is the CLI's own
    /// default. Keys and values are the adapter's and opaque here; the
    /// adapter turns them into flags, and ignores, with a note, a value it
    /// does not offer.
    options: []const Option = &.{},
};

/// One launch option and the value picked for it.
pub const Option = struct {
    key: []const u8,
    value: []const u8,
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

    /// Roles in the file under a key that is an official role's. They are
    /// not in `personas` -- the official one is -- and they are **written
    /// back as they were read**, so that a key Polter starts shipping
    /// (`polter-tester` was anybody's to use until it did) does not cost a
    /// person the role they had under it the next time anything is saved.
    shadowed: []const Persona = &.{},

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
    return parseFileLeaky(aa, bytes, try official.effective(aa, &official.sources, .absent));
}

/// `parseLeaky` with the official roles handed in, already as they are in
/// effect (`official.effective`). They go first; a role in the file under
/// one of their keys goes to `shadowed`.
///
/// That used to refuse the whole file (`ReservedKey`). It was the right
/// answer while the only official key was one nobody could have used by
/// accident, and stopped being it the day a second key became official:
/// refusing the file would have emptied the library of anybody who already
/// had a role called that.
pub fn parseFileLeaky(aa: Allocator, bytes: []const u8, official_roles: []const Persona) ParseError!Set {
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
    var shadowed: std.ArrayList(Persona) = .empty;
    var ignored: std.ArrayList([]const u8) = .empty;
    try personas.appendSlice(aa, official_roles);

    for (list.items) |entry| {
        const p = try personaOf(aa, entry, &ignored);
        const is_official = for (official_roles) |q| {
            if (std.mem.eql(u8, q.key, p.key)) break true;
        } else false;
        const among: *std.ArrayList(Persona) = if (is_official) &shadowed else &personas;
        // Two under one key is refused among the shadowed ones as well:
        // which of the two the person would get back is not ours to pick.
        for (among.items) |q| {
            if (q.official == null and std.mem.eql(u8, q.key, p.key)) return error.DuplicateKey;
        }
        try among.append(aa, p);
    }

    return .{
        .version = version,
        .personas = try personas.toOwnedSlice(aa),
        .ignored_denies = try ignored.toOwnedSlice(aa),
        .shadowed = try shadowed.toOwnedSlice(aa),
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
    return try personaOf(aa, parsed, &ignored);
}

/// One persona object. Public for `official.parseSource`: a shipped role is
/// read by the same function as one in the file.
pub fn personaOf(
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

    // Version 2 kept the skills and servers once per CLI; they are read so
    // that a file written then is merged into the role's one set when it
    // has none of its own.
    var legacy_skills: std.ArrayList(Selection) = .empty;
    var legacy_mcp: std.ArrayList(Selection) = .empty;
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
                const cli_obj = kv.value_ptr.*.object;
                if (cli_obj.get("skills") != null) try legacy_skills.append(aa, try selectionOf(aa, cli_obj, "skills"));
                if (cli_obj.get("mcp") != null) try legacy_mcp.append(aa, try selectionOf(aa, cli_obj, "mcp"));
            }
            p.clis = clis;
        },
        .null => {},
        else => return error.BadField,
    };
    p.cli_skills = if (obj.get("cli_skills") != null)
        try selectionOf(aa, obj, "cli_skills")
    else
        try mergeLegacy(aa, legacy_skills.items);
    p.cli_mcp = if (obj.get("cli_mcp") != null)
        try selectionOf(aa, obj, "cli_mcp")
    else
        try mergeLegacy(aa, legacy_mcp.items);

    if (obj.get("polter")) |pv| switch (pv) {
        .object => |o| p.polter = try polterOf(o),
        .null => {},
        else => return error.BadField,
    };

    return p;
}

fn polterOf(obj: std.json.ObjectMap) ParseError!Polter {
    var out: Polter = .{};
    out.supervisor = try optionalBool(obj, "supervisor");
    out.may_authorise = try optionalBool(obj, "may_authorise");
    out.shielded = try optionalBool(obj, "shielded");
    out.watch = try optionalBool(obj, "watch");
    if (obj.get("open")) |v| switch (v) {
        .string => |s| out.open = std.meta.stringToEnum(Polter.Open, s) orelse return error.BadField,
        .null => {},
        else => return error.BadField,
    };
    if (obj.get("quiet_ms")) |v| switch (v) {
        // A floor of a second: anything shorter reports a terminal for
        // drawing its own prompt, and zero would report it continuously.
        .integer => |n| out.quiet_ms = if (n >= 1000) @intCast(n) else return error.BadField,
        .null => {},
        else => return error.BadField,
    };
    return out;
}

fn optionalBool(obj: std.json.ObjectMap, field: []const u8) ParseError!bool {
    return switch (obj.get(field) orelse return false) {
        .bool => |b| b,
        .null => false,
        else => error.BadField,
    };
}

fn cliChoiceOf(aa: Allocator, key: []const u8, v: std.json.Value) ParseError!CliChoice {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.BadField,
    };
    // Read here only to be refused when malformed; what they say is the
    // role's (`personaOf`, `mergeLegacy`).
    _ = try selectionOf(aa, obj, "skills");
    _ = try selectionOf(aa, obj, "mcp");
    return .{
        .cli = key,
        .model = try optionalString(obj, "model"),
        .args = try stringArray(aa, obj, "args"),
        .options = try optionsOf(aa, obj),
    };
}

fn optionsOf(aa: Allocator, obj: std.json.ObjectMap) ParseError![]const Option {
    const m = switch (obj.get("options") orelse return &.{}) {
        .object => |m| m,
        .null => return &.{},
        else => return error.BadField,
    };
    const out = try aa.alloc(Option, m.count());
    var it = m.iterator();
    var i: usize = 0;
    while (it.next()) |kv| : (i += 1) {
        // An option's key goes nowhere but back to its adapter; the charset
        // is a role key's so that a typo cannot look like a second one.
        if (!isValidOptionKey(kv.key_ptr.*)) return error.BadField;
        out[i] = .{ .key = kv.key_ptr.*, .value = switch (kv.value_ptr.*) {
            .string => |v| v,
            else => return error.BadField,
        } };
    }
    return out;
}

/// A role key's charset with `_` as well: `permission_mode`.
fn isValidOptionKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key_len) return false;
    for (key) |c| switch (c) {
        'a'...'z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// One set out of the per-CLI sets a version 2 file kept (task 1677).
///
/// The same in every CLI -- the official roles, and any role nobody
/// ticked differently -- is that set. Otherwise:
///
///   * `default` is the first CLI's, in the order written;
///   * an id ticked the other way in any CLI keeps that tick, because an
///     id is nearly always one only that CLI has: a union of what is on
///     would switch back on what the other CLI's tick switched off, and an
///     intersection would switch off what nobody touched;
///   * an id two CLIs ticked to opposite ends goes the first CLI's way.
///
/// None at all (a version 1 file, or a CLI with no entry) is the default
/// set: everything on.
pub fn mergeLegacy(aa: Allocator, sets: []const Selection) Allocator.Error!Selection {
    if (sets.len == 0) return .{};
    const default = sets[0].default;
    var except: std.ArrayList([]const u8) = .empty;
    var decided: std.ArrayList([]const u8) = .empty;
    for (sets) |sel| for (sel.except) |id| {
        if (Persona.has(decided.items, id)) continue;
        try decided.append(aa, id);
        // In this set it is ticked the other way from this set's default.
        if (!sel.default != default) try except.append(aa, id);
    };
    return .{ .default = default, .except = try except.toOwnedSlice(aa) };
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
    // The official roles are Polter's, not the user's: every reader puts
    // them back, and what a person changed in one is kept elsewhere
    // (`official.zig`).
    var n: usize = 0;
    for (set.personas) |p| {
        if (p.official != null) continue;
        try w.writeAll(if (n == 0) "\n    " else ",\n    ");
        try writePersona(w, p);
        n += 1;
    }
    // And the roles that were in the file under an official key, which are
    // the person's and not in use. Last, since they have no place in the
    // menu to keep.
    for (set.shadowed) |p| {
        try w.writeAll(if (n == 0) "\n    " else ",\n    ");
        try writePersona(w, p);
        n += 1;
    }
    try w.writeAll(if (n == 0) "]\n}\n" else "\n  ]\n}\n");
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
            try w.print("{f}:{{", .{jstr(c.cli)});
            var first = true;
            if (c.model) |m| {
                try w.print("\"model\":{f}", .{jstr(m)});
                first = false;
            }
            if (c.args.len > 0) {
                try w.writeAll(if (first) "\"args\":" else ",\"args\":");
                try writeStrings(w, c.args);
                first = false;
            }
            if (c.options.len > 0) {
                try w.writeAll(if (first) "\"options\":" else ",\"options\":");
                try writeOptions(w, c.options);
            }
            try w.writeAll("}");
        }
        try w.writeAll("}");
    }
    // Written for any role a CLI can be started in, everything on
    // included: a reader handed none would have to know that none means
    // all on.
    if (p.clis.len > 0 or !p.cli_skills.isAll() or !p.cli_mcp.isAll()) {
        try w.writeAll(",\"cli_skills\":");
        try writeSelection(w, p.cli_skills);
        try w.writeAll(",\"cli_mcp\":");
        try writeSelection(w, p.cli_mcp);
    }
    if (!p.polter.isDefault()) {
        const o = p.polter;
        try w.print(
            ",\"polter\":{{\"supervisor\":{},\"may_authorise\":{},\"shielded\":{},\"watch\":{},\"open\":\"{t}\"",
            .{ o.supervisor, o.may_authorise, o.shielded, o.watch, o.open },
        );
        if (o.quiet_ms) |ms| try w.print(",\"quiet_ms\":{d}", .{ms});
        try w.writeAll("}");
    }
    // Read by the window and `role_list`; ignored when read back, since a
    // file cannot make a role Polter's. `builtin` is the older word for it
    // and is what both hosts already look for.
    if (p.official) |o| {
        try w.print(",\"builtin\":true,\"official\":{{\"state\":\"{t}\",\"overridden\":", .{o.state});
        try writeStrings(w, o.overridden);
        try w.writeAll(",\"stale\":");
        try writeStrings(w, o.stale);
        try w.writeAll(",\"reason\":");
        if (o.reason) |r| try w.print("{f}", .{jstr(r)}) else try w.writeAll("null");
        try official.writeWhy(w, "reason", o.reason);
        try w.writeAll("}");
    }
    try w.writeAll("}");
}

pub fn writeOptions(w: *std.Io.Writer, options: []const Option) std.Io.Writer.Error!void {
    try w.writeAll("{");
    for (options, 0..) |o, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{f}:{f}", .{ jstr(o.key), jstr(o.value) });
    }
    try w.writeAll("}");
}

pub fn writeSelection(w: *std.Io.Writer, s: Selection) std.Io.Writer.Error!void {
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
    // A copy of the set with one thing changed, rather than a new one with
    // two fields filled in: what it does not mention has to survive.
    var next = set;
    next.version = supported_version;
    next.personas = try out.toOwnedSlice(aa);
    return next;
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
    var next = set;
    next.version = supported_version;
    next.personas = try out.toOwnedSlice(aa);
    return next;
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

/// Which role and CLI a terminal was **started** in, recorded when the
/// launch line is typed (`App.startRoleIn`).
///
/// ⚠️ **Not the same thing as `State.key`, and the difference is the
/// point.** A role put on a running terminal changes what Polter hands out
/// and nothing else: the CLI in there keeps the skills, servers, model and
/// arguments it was started with. Only a launch applies the CLI half, so
/// only a launch writes one of these -- and a terminal that was only ever
/// worn hot has none, which is the answer, not a gap.
///
/// The choice is copied at launch, not looked up later: an edit to the role
/// afterwards does not reach a CLI that is already running.
pub const Launch = struct {
    /// The role key the launch was for.
    role: []const u8,
    choice: CliChoice,
    /// The role's skills and servers as they were at the launch
    /// (`Persona.cli_skills`), copied for the same reason as `choice`.
    skills: Selection,
    mcp: Selection,
};

/// What `terminal_capabilities` knows about a terminal from the role side:
/// what it wears, how it came to wear it, and what its CLI was started
/// with. The Polter tool names and the standing are added by the caller
/// (`rpc.CapabilitiesView`).
///
/// Slices borrow from whatever the producer was given to allocate in.
pub const Capabilities = struct {
    /// Null when the terminal wears no role. Null, not an empty key:
    /// "wears nothing" and "wears a role called nothing" are different.
    role: ?Role,

    started: Started,

    /// Null unless `started` is `launched`.
    cli: ?Cli,

    /// No role: nothing is withheld, and `skills` / `slots` are empty
    /// because nothing had to be listed -- not because nothing is there.
    unfiltered: bool,

    /// Polter skills the role names.
    skills: []const []const u8,

    /// Upstream MCP slots the role wants. Meaningless when `unfiltered`,
    /// where every slot is wanted.
    slots: []const []const u8,

    /// `State.epoch`, so an answer can be compared with a later one.
    epoch: u64,

    /// A launch's Polter half still waiting for its agent to connect
    /// (`PersonaStore.holdStanding`). Null when nothing is waiting -- which
    /// includes one that ran out, because that one will never apply.
    pending_standing: ?PendingStanding,

    pub const PendingStanding = struct {
        want: Polter,
        /// How long the agent still has to connect.
        expires_in_ms: u64,
    };

    pub const Role = struct {
        key: []const u8,
        /// Null when the library no longer has the role.
        name: ?[]const u8,
        deviated: bool,
        builtin: bool,
    };

    pub const Started = enum {
        /// Started from a role: the CLI half was applied. `cli` says how.
        launched,
        /// Wearing a role that was put on it while running. Its CLI was not
        /// started from the role, so nothing of the role's CLI half is in
        /// effect, and `cli` is null for that reason.
        worn_hot,
        /// No role, no launch.
        none,
    };

    pub const Cli = struct {
        /// The CLI's key (`claude-code`).
        key: []const u8,
        /// The role it was started in -- which is not necessarily the one
        /// worn now: a role can be put on hot after the launch.
        role: []const u8,
        model: ?[]const u8,
        args: []const []const u8,

        /// Whether the per-item split below could be worked out.
        inventory: Inventory,
        /// A newer inventory is being read.
        refreshing: bool,
        /// Why the inventory is `failed`.
        @"error": ?[]const u8,

        /// Null unless `inventory` is `ok`. Never an empty split standing
        /// in for "could not tell".
        skills: ?Split,
        mcp: ?Split,
    };

    pub const Inventory = enum {
        ok,
        /// Nothing has been read yet. Not "nothing is installed".
        stale,
        /// The CLI's adapter could not answer.
        failed,
        /// This machine lists no such CLI -- its plugin is gone, or was
        /// never here.
        absent,
    };

    pub const Split = struct {
        kept: []const []const u8,
        off: []const []const u8,
    };
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
    try testing.expectEqual(official_count + 2, set.personas.len);

    const archer = set.find("archer").?;
    try testing.expectEqualStrings("射手", archer.name);
    try testing.expectEqualStrings("archer.md", archer.prompt.?);
    try testing.expectEqualStrings("reading-a-terminal", archer.skills[0]);
    try testing.expectEqualStrings("argus", archer.mcp[0]);
    try testing.expectEqualStrings("sonnet", archer.hint_model.?);
    try testing.expectEqualStrings("kanban@x", archer.hint_disable_host_plugins[0]);

    // Order is the user's, and the menu is built from it.
    try testing.expectEqualStrings("archer", set.personas[official_count + 0].key);
    try testing.expectEqualStrings("scribe", set.personas[official_count + 1].key);

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
    try testing.expectEqual(@as(usize, 0), set.personas[official_count + 0].clis.len);
    try testing.expectEqual(@as(?[]const u8, null), set.personas[official_count + 0].instructions);

    // And a version that is neither is still refused, so an older Polter
    // reading a newer file says so instead of guessing.
    try testing.expectError(error.BadVersion, parseLeaky(
        arena.allocator(),
        "{\"version\":4,\"personas\":[]}",
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
        \\                          "model":"opus","args":["--verbose"],
        \\                          "options":{"permission_mode":"auto"}},
        \\           "codex":{}}},
        \\  {"key":"scribe","name":"书记"}
        \\]}
    ;
    const first = try parseLeaky(aa, text);

    var out: std.Io.Writer.Allocating = .init(aa);
    try writeSet(&out.writer, first);
    const again = try parseLeaky(aa, out.written());

    try testing.expectEqual(supported_version, again.version);
    try testing.expectEqual(official_count + 2, again.personas.len);
    const a = again.personas[official_count + 0];
    try testing.expectEqualStrings("只读调研", a.description.?);
    try testing.expectEqualStrings("Say \"hi\" first.\nThen work.", a.instructions.?);
    try testing.expectEqualStrings("notify_user", a.tools.deny[0]);
    try testing.expectEqualStrings("sonnet", a.hint_model.?);
    try testing.expectEqual(@as(usize, 2), a.clis.len);

    // Order of the CLIs is the order written: it is the order they are
    // offered in.
    const cc = a.clis[0];
    try testing.expectEqualStrings("claude-code", cc.cli);
    try testing.expectEqualStrings("opus", cc.model.?);
    try testing.expectEqualStrings("--verbose", cc.args[0]);
    try testing.expectEqualStrings("permission_mode", cc.options[0].key);
    try testing.expectEqualStrings("auto", cc.options[0].value);
    try testing.expectEqualStrings("codex", a.clis[1].cli);
    try testing.expectEqual(@as(usize, 0), a.clis[1].options.len);
    // Written as version 2, once per CLI: one CLI said something, the
    // other nothing, so the role's one set is what the first said -- and
    // it came back through a version 3 write as that.
    try testing.expect(!a.cli_skills.default);
    try testing.expectEqualStrings("skill:pdf", a.cli_skills.except[0]);
    try testing.expect(a.cli_mcp.default);
    try testing.expectEqualStrings("mcp:argus", a.cli_mcp.except[0]);
    // And nothing per CLI is written any more.
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"cli_skills\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "{\"model\":\"opus\"") != null);

    try testing.expectEqualStrings("书记", again.personas[official_count + 1].name);
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
    try testing.expectEqualStrings("archer", edited.personas[official_count + 0].key);
    try testing.expectEqualStrings("新名字", edited.personas[official_count + 0].name);
    try testing.expectEqual(official_count + 2, edited.personas.len);

    const added = try withPersona(aa, set, .{ .key = "zz", .name = "z" });
    try testing.expectEqualStrings("zz", added.personas[official_count + 2].key);

    const gone = (try withoutPersona(aa, set, "archer")).?;
    try testing.expectEqual(official_count + 1, gone.personas.len);
    try testing.expectEqualStrings("scribe", gone.personas[official_count + 0].key);
    try testing.expectEqual(@as(?Set, null), try withoutPersona(aa, set, "nobody"));
}

test "persona: every set starts with the official roles" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const empty = try parseLeaky(aa, "{\"version\":2,\"personas\":[]}");
    try testing.expectEqual(official_count, empty.personas.len);
    const boss = empty.find(supervisor_key).?;
    try testing.expect(boss.official != null);
    try testing.expectEqual(Official.Status.pristine, boss.official.?.state);
    try testing.expectEqualStrings("Polter Supervisor", boss.name);
    try testing.expect(boss.polter.supervisor);
    try testing.expectEqual(Polter.Open.auto, boss.polter.open);
    try testing.expect(boss.instructions != null);
    // The three house rules of task 900 are in the text an agent is given.
    try testing.expect(std.mem.indexOf(u8, boss.instructions.?, "place: \"here\"") != null);
    try testing.expect(std.mem.indexOf(u8, boss.instructions.?, "Workers do not git commit, merge") != null);
    try testing.expect(std.mem.indexOf(u8, boss.instructions.?, "one dedicated test worker") != null);
    // Nothing of the CLI's own but Polter's skills: the polter server is
    // kept whatever this says.
    try testing.expect(!boss.cli_skills.default);
    try testing.expect(!boss.cli_mcp.default);
    try testing.expectEqual(@as(usize, 3), boss.cli_skills.except.len);
    try testing.expectEqual(@as(usize, 2), boss.clis.len);
    try testing.expect(empty.find(tester_key).?.official != null);
    // With no file at all, the same.
    const none = try official.assemble(aa, null, &official.sources, .absent);
    try testing.expect(none.find(supervisor_key) != null);
    try testing.expectEqual(official_count, none.personas.len);
}

test "persona: a role in the file under an official key is kept, unused, and written back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // `polter-tester` was anybody's key until Polter shipped a role under it.
    const file =
        \\{"version":2,"personas":[
        \\  {"key":"archer","name":"Archer"},
        \\  {"key":"polter-tester","name":"我的测试员","instructions":"只测不改"},
        \\  {"key":"scribe","name":"书记"}
        \\]}
    ;
    const set = try parseLeaky(aa, file);
    // The rest of the library is there: the file is not refused for it.
    try testing.expectEqual(official_count + 2, set.personas.len);
    try testing.expect(set.find("archer") != null and set.find("scribe") != null);
    // The official one is the one in use...
    try testing.expectEqualStrings("Polter Tester", set.find(tester_key).?.name);
    try testing.expect(set.find(tester_key).?.official != null);
    // ...and theirs is held, whole.
    try testing.expectEqual(@as(usize, 1), set.shadowed.len);
    try testing.expectEqualStrings("我的测试员", set.shadowed[0].name);
    try testing.expect(set.shadowed[0].official == null);

    // Saving anything else -- here, a new role -- does not lose it.
    const edited = try withPersona(aa, set, .{ .key = "zz", .name = "new" });
    const fewer = (try withoutPersona(aa, edited, "archer")).?;
    var out: std.Io.Writer.Allocating = .init(aa);
    try writeSet(&out.writer, fewer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "我的测试员") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "只测不改") != null);
    // The official role itself is still not written.
    try testing.expect(std.mem.indexOf(u8, out.written(), "Polter Tester") == null);

    const again = try parseLeaky(aa, out.written());
    try testing.expectEqual(@as(usize, 1), again.shadowed.len);
    try testing.expectEqualStrings("只测不改", again.shadowed[0].instructions.?);

    // Two of them under the one key is still two roles with one key.
    try testing.expectError(error.DuplicateKey, parseLeaky(aa,
        \\{"version":2,"personas":[{"key":"polter-tester","name":"a"},{"key":"polter-tester","name":"b"}]}
    ));

    // One role arriving by itself under an official key parses: whether it
    // may be written is the store's to say, which knows who is asking.
    const one = try parsePersonaLeaky(aa, "{\"key\":\"polter-supervisor\",\"name\":\"mine\"}");
    try testing.expect(one.official == null);
}

test "persona: the Polter half reads, writes back, and the official roles are not written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const first = try parseLeaky(aa,
        \\{"version":2,"personas":[
        \\  {"key":"w","name":"worker","polter":{"watch":true,"open":"tab","quiet_ms":600000,
        \\   "may_authorise":true}},
        \\  {"key":"plain","name":"p"}
        \\]}
    );
    var out: std.Io.Writer.Allocating = .init(aa);
    try writeSet(&out.writer, first);
    try testing.expect(std.mem.indexOf(u8, out.written(), supervisor_key) == null);

    const again = try parseLeaky(aa, out.written());
    try testing.expectEqual(official_count + 2, again.personas.len);
    const w = again.find("w").?.polter;
    try testing.expect(w.watch and w.may_authorise and !w.supervisor and !w.shielded);
    try testing.expectEqual(Polter.Open.tab, w.open);
    try testing.expectEqual(@as(?u64, 600000), w.quiet_ms);
    try testing.expect(again.find("plain").?.polter.isDefault());
    // A default Polter half is not written at all.
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"polter\"") ==
        std.mem.lastIndexOf(u8, out.written(), "\"polter\""));

    try testing.expectError(error.BadField, parsePersonaLeaky(aa,
        \\{"key":"a","name":"n","polter":{"open":"window"}}
    ));
    try testing.expectError(error.BadField, parsePersonaLeaky(aa,
        \\{"key":"a","name":"n","polter":{"quiet_ms":10}}
    ));
    try testing.expectError(error.BadField, parsePersonaLeaky(aa,
        \\{"key":"a","name":"n","polter":{"supervisor":"yes"}}
    ));
}

test "persona: only the user's three settings count for userOnlyEql" {
    const base: Polter = .{};
    try testing.expect(Polter.userOnlyEql(base, .{ .watch = true, .open = .tab, .quiet_ms = 5000 }));
    try testing.expect(!Polter.userOnlyEql(base, .{ .supervisor = true }));
    try testing.expect(!Polter.userOnlyEql(base, .{ .may_authorise = true }));
    try testing.expect(!Polter.userOnlyEql(base, .{ .shielded = true }));
}

test "persona: an agent started in a supervisor role is told it is one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const plain: Persona = .{ .key = "a", .name = "a", .instructions = "own" };
    try testing.expectEqualStrings("own", (try launchInstructions(aa, plain, null)).?);
    try testing.expectEqual(@as(?[]const u8, null), try launchInstructions(aa, .{ .key = "b", .name = "b" }, null));

    const bare: Persona = .{ .key = "c", .name = "c", .polter = .{ .supervisor = true } };
    try testing.expectEqualStrings(supervisor_launch_note, (try launchInstructions(aa, bare, null)).?);

    var with = bare;
    with.instructions = "own";
    const text = (try launchInstructions(aa, with, null)).?;
    try testing.expect(std.mem.startsWith(u8, text, supervisor_launch_note));
    try testing.expect(std.mem.endsWith(u8, text, "\n\nown"));
}

test "persona: a supervisor started for a group is told which, and to read it rather than make one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const bare: Persona = .{ .key = "c", .name = "c", .polter = .{ .supervisor = true } };
    const text = (try launchInstructions(aa, bare, "web-app")).?;
    try testing.expect(std.mem.indexOf(u8, text, "supervisor of the group `web-app`") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Do not make a group") != null);
    try testing.expect(std.mem.indexOf(u8, text, "started_for") != null);
    // The sentence that sends a supervisor off to make one is the other
    // note's, and is not said to this one.
    try testing.expect(std.mem.indexOf(u8, supervisor_launch_note, "making a group") != null);
    try testing.expect(std.mem.indexOf(u8, text, "making a group") == null);

    // Its own instructions still follow, and a role that makes no
    // supervisor is told nothing about any group.
    var with = bare;
    with.instructions = "own";
    try testing.expect(std.mem.endsWith(u8, (try launchInstructions(aa, with, "web-app")).?, "\n\nown"));
    const plain: Persona = .{ .key = "a", .name = "a", .instructions = "own" };
    try testing.expectEqualStrings("own", (try launchInstructions(aa, plain, "web-app")).?);
}

test "persona: a role set up for several CLIs starts in the one this machine has (task 1667)" {
    const both: Persona = .{ .key = "s", .name = "s", .clis = &.{
        .{ .cli = "claude-code" },
        .{ .cli = "codex" },
    } };
    // The Codex plugin is off, as it ships: Claude Code, as before codex
    // was added to the role -- whoever asks.
    try testing.expectEqualStrings("claude-code", try both.defaultCli(&.{ "claude-code", "other-cli" }, null));
    try testing.expectEqualStrings("claude-code", try both.defaultCli(&.{ "claude-code", "other-cli" }, "codex"));
    try testing.expectEqualStrings("codex", try both.defaultCli(&.{"codex"}, null));
    // Both here and nobody's CLI to go by is a real choice, and nothing
    // here is the old answer.
    try testing.expectError(error.ChooseCli, both.defaultCli(&.{ "codex", "claude-code" }, null));
    try testing.expectError(error.ChooseCli, both.defaultCli(&.{}, null));
    // One set up is that one whatever is here; none is none.
    const one: Persona = .{ .key = "o", .name = "o", .clis = &.{.{ .cli = "codex" }} };
    try testing.expectEqualStrings("codex", try one.defaultCli(&.{}, "claude-code"));
    const none: Persona = .{ .key = "n", .name = "n" };
    try testing.expectError(error.NoCli, none.defaultCli(&.{"codex"}, null));
}

test "persona: of several CLIs that are here, the one the asker runs in (task 1677)" {
    const both: Persona = .{ .key = "s", .name = "s", .clis = &.{
        .{ .cli = "claude-code" },
        .{ .cli = "codex" },
    } };
    const here: []const []const u8 = &.{ "claude-code", "codex" };
    // A supervisor in Codex opens Codex workers; one in Claude Code,
    // Claude Code ones.
    try testing.expectEqualStrings("codex", try both.defaultCli(here, "codex"));
    try testing.expectEqualStrings("claude-code", try both.defaultCli(here, "claude-code"));
    // The asker's CLI counts only when the role is set up for it and it is
    // here: a supervisor in some other CLI is no answer.
    try testing.expectError(error.ChooseCli, both.defaultCli(here, "other-cli"));
    const three: Persona = .{ .key = "t", .name = "t", .clis = &.{
        .{ .cli = "claude-code" },
        .{ .cli = "codex" },
        .{ .cli = "other-cli" },
    } };
    try testing.expectError(error.ChooseCli, three.defaultCli(here, "other-cli"));
}

test "persona: a version 2 file's per-CLI skills and servers become the role's one set (task 1677)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // The same in both -- every official role -- is that set.
    const same = try parsePersonaLeaky(aa,
        \\{"key":"a","name":"a","clis":{
        \\  "claude-code":{"skills":{"default":false,"except":["skill:x"]},"mcp":{"default":false,"except":[]}},
        \\  "codex":{"skills":{"default":false,"except":["skill:x"]},"mcp":{"default":false,"except":[]}}}}
    );
    try testing.expect(!same.cli_skills.default);
    try testing.expectEqual(@as(usize, 1), same.cli_skills.except.len);
    try testing.expect(!same.cli_mcp.default and same.cli_mcp.except.len == 0);

    // Different: the first CLI's default; every id either CLI ticked keeps
    // its tick; two ticks the opposite way go the first CLI's way.
    const differ = try parsePersonaLeaky(aa,
        \\{"key":"b","name":"b","clis":{
        \\  "claude-code":{"skills":{"default":true,"except":["skill:pdf","skill:both"]}},
        \\  "codex":{"skills":{"default":false,"except":["skill:imagegen","skill:both"]}}}}
    );
    const sel = differ.cli_skills;
    try testing.expect(sel.default);
    // Claude Code switched pdf off: still off, not switched back on by
    // Codex not mentioning it.
    try testing.expect(!sel.enabled("skill:pdf"));
    // Codex switched imagegen on while everything else was off: on, which
    // the merged default already says.
    try testing.expect(sel.enabled("skill:imagegen"));
    // Off in Claude Code, on in Codex: Claude Code's way.
    try testing.expect(!sel.enabled("skill:both"));
    try testing.expect(sel.enabled("skill:nobody-ticked"));

    // A version 3 role's own set wins over anything left per CLI.
    const v3 = try parsePersonaLeaky(aa,
        \\{"key":"c","name":"c","cli_skills":{"default":false,"except":[]},
        \\ "clis":{"codex":{"skills":{"default":true,"except":[]}}}}
    );
    try testing.expect(!v3.cli_skills.default);
    // Nothing said anywhere is everything on.
    const bare = try parsePersonaLeaky(aa,
        \\{"key":"d","name":"d","clis":{"codex":{}}}
    );
    try testing.expect(bare.cli_skills.isAll() and bare.cli_mcp.isAll());
}

test "persona: version 3 is read, and a version past it is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    _ = try parseLeaky(aa, "{\"version\":3,\"personas\":[]}");
    _ = try parseLeaky(aa, "{\"version\":2,\"personas\":[]}");
    try testing.expectError(error.BadVersion, parseLeaky(aa, "{\"version\":4,\"personas\":[]}"));
}

test "persona: a launch option is a key and a text value, and nothing else" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const p = try parsePersonaLeaky(aa,
        \\{"key":"a","name":"a","clis":{"codex":{"options":{"sandbox":"workspace-write","approval":"never"}}}}
    );
    try testing.expectEqual(@as(usize, 2), p.clis[0].options.len);
    try testing.expectError(error.BadField, parsePersonaLeaky(aa,
        \\{"key":"a","name":"a","clis":{"codex":{"options":{"sandbox":true}}}}
    ));
    try testing.expectError(error.BadField, parsePersonaLeaky(aa,
        \\{"key":"a","name":"a","clis":{"codex":{"options":{"Sand Box":"x"}}}}
    ));
    try testing.expectError(error.BadField, parsePersonaLeaky(aa,
        \\{"key":"a","name":"a","clis":{"codex":{"options":["x"]}}}
    ));
}
