//! What the person does in the control room: one request, checked against
//! what is true now, and carried out or refused by name.
//!
//! **A click is aimed at what was on screen when it was made**, and that
//! may no longer be there. So a request that would press a key in somebody
//! else's terminal hands back the two moments the row was drawn from --
//! `since_ms` and `event_ms`, both in the snapshot -- and nothing is sent
//! unless they still hold (dev-docs/poltergeist/control-room.md, 7.1). A
//! refusal sends no key at all, not the first half of one.
//!
//! **Who is asking is not in the request.** This is reached through
//! `ghostty_app_control_act`, which only the host can call, from the window
//! the person is looking at; there is no field a caller could fill in to
//! claim to be them.
//!
//! ## The request
//!
//! ```
//! {"act":"seen",     "group":"web-app"}
//! {"act":"seen",     "terminal":"0x…"}                  a terminal in no group
//! {"act":"snooze",   "group":"web-app"}                 until it changes
//! {"act":"snooze",   "group":"web-app","until_ms":N}    until then (wall)
//! {"act":"unsnooze", "group":"web-app"}
//! {"act":"approve",  "terminal":"0x…","since_ms":N,"event_ms":N}
//! {"act":"refuse",   "terminal":"0x…","since_ms":N,"event_ms":N}
//! {"act":"reply",    "terminal":"0x…","since_ms":N,"text":"…"}
//! {"act":"new_group","name":"web-app"}
//! {"act":"fix",      "group":"web-app"}
//! {"act":"fix",      "terminal":"0x…"}                  a terminal in no group
//! {"act":"start_supervisor","group":"web-app"}          the snapshot's role
//!                                                       and directory
//! {"act":"start_supervisor","group":"web-app","role":"…","cwd":"/…"}
//! {"act":"start_supervisor","group":"web-app","session":"new"}
//!                                                       last | new
//! ```
//!
//! The group row's right-click menu (task 1659):
//!
//! ```
//! {"act":"pin",      "group":"web-app"}                 / "unpin"
//! {"act":"mute",     "group":"web-app","until_ms":N}    until then (wall)
//! {"act":"mute",     "group":"web-app"}                 until lifted
//! {"act":"unmute",   "group":"web-app"}
//! {"act":"archive",  "group":"web-app"}                 / "unarchive"
//! {"act":"rename_group","from":"web-app","to":"store"}
//! {"act":"set_brief","group":"web-app","brief":"…"}
//! {"act":"delete_group","group":"web-app","members":N,"open_tasks":N}
//!                                                       what the dialog said
//! {"act":"ask_supervisor","group":"web-app","ask":"report"}
//!                                                       report | close_idle
//! ```
//!
//! `pin`, `mute` and `archive` are the person's marks on the group and are
//! written down with the rest of them. A mute keeps the group's system
//! notifications back -- its card is shown as ever -- until its moment, or
//! until lifted; an archived group is off the list, out of every count and
//! raises nothing, while its terminals, its talk and its panel go on.
//!
//! **`delete_group` is the one delete that removes the record**, and it is
//! the person's alone. `group_destroy` -- what an agent can call -- takes a
//! group off the list and leaves every word of it on the disk, because an
//! agent asked to tidy up should never be able to destroy what the person
//! would read the next morning. A person who has read the dialog, which
//! says what goes and that it cannot be had back, may. So this takes the
//! terminals in it out of it (none is closed), drops its tasks, and deletes
//! the group's directory under each of `group_stores.Root`. It is aimed at
//! what the dialog said: the two numbers it showed come back in the request,
//! and it is `Stale` -- nothing deleted -- unless they are still so.
//!
//! `ask_supervisor` types a fixed line into the group's supervisor (`[Polter
//! ask]`, then the request in the person's language), kept in the group as
//! the person's, by the road a `group_post` mention takes. Done means it was
//! typed, not that the supervisor did it.
//!
//! `fix` is the "Fix" button on a card that reads "Failed"
//! (`ControlFix.zig`): a paragraph naming who failed, with what and when,
//! typed into the card's supervisor -- or, with none, into each failed
//! terminal -- and kept in the group, by the road a `group_post` mention
//! takes. It is aimed at the card as it was last drawn, and clears
//! nothing: the failure is cleared by that terminal's next event.
//!
//! `start_supervisor` opens a tab, starts the role's CLI in it, and holds
//! "this terminal is `group`'s supervisor" for the agent that connects from
//! it.
//!
//! `session` says whether it goes on with the session the group's last
//! supervisor was in. **`last` is what leaving it out means, and it is a
//! preference, not a condition**: the session is gone on with when the
//! snapshot's `supervisor.resume.can` holds at that moment *for the role
//! this start uses* -- there is a session written down, the role starts
//! the same CLI, that CLI's adapter says it can, and no open terminal is
//! in it -- and a new session is started otherwise. A supervisor that
//! cannot go on where the last one stopped is still a supervisor; a group
//! left without one because of it would be the worse answer. What the
//! control room offered is `resume` in the snapshot, with the reason when
//! it is no. `new` starts a new session whatever is written down.
//!
//! The start is the same act either way.
//!
//! **A group that has a project is started by opening the project**, not
//! by a tab in a directory: the start is recorded as waiting for it, the
//! snapshot's `project_orders` asks the host to `open` it, and when the
//! host states it open with a terminal in its supervisor's pane, the core
//! types the launch line there. `role` is still read; `cwd` is not -- the
//! pane has its own. A group with no project is started as before.
//!
//! ## What the host says about projects
//!
//! ```
//! {"act":"projects","list":[
//!    {"name":"web-app","group":"web-app"|null,"pages":3,
//!     "open":null | [["0x…","0x…"],["0x…"]],
//!     "supervisor":"0x…"|null,
//!     "workers":["0x…", …]}, … ]}
//! {"act":"project_failed","name":"web-app","why":"not_found"|"unreadable"}
//! {"act":"project_remove","terminal":"0x…"}
//! {"act":"project_rename","from":"web-app","to":"storefront"}
//! ```
//!
//! And one about old records (task 1511): `{"act":"retention_agree"}` -- the
//! person said OK to the notice that the first sweep would delete
//! `retention_waiting_bytes`.
//!
//! `projects` is **everything the host knows, every time** (`Projects.zig`
//! has the whole of it): each project, the group its file names, how many
//! pages it has, and for one that is open the terminals on each page, the
//! one in the supervisor's pane, and the ones in the panes its file marks
//! as opened by its supervisor (`workers`; empty when none). Every key is said in every entry. It
//! replaces what was said before; a list that does not read whole is
//! refused whole and the last one stands. The host says it at start, and
//! whenever a project is made, opened, closed, renamed, deleted, or gains
//! or loses a page or a pane.
//!
//! `project_failed` is the host saying it could not open a project it was
//! ordered to: the start waiting on it fails now rather than by its
//! deadline. `not_found` also unties the group -- the file is gone, and
//! the group is started by directory again.
//!
//! `project_remove` is asked **before** a page is taken out of its project
//! and answers whether it may be: the page with a group's supervisor on it
//! may not (`SupervisorPage`). Nothing is changed by asking; the host
//! takes the page out and states the result.
//!
//! `project_rename` is asked **before** a project is renamed. For a
//! project that is a group's, it renames the group -- that is the only
//! way such a project is renamed, and it may be refused as any rename of
//! a group may -- and the host then finds a `rename` order to carry out.
//! For a project that is no group's it changes nothing and says yes. **It returns when the tab has been asked for, not when there is a
//! supervisor**: what becomes of it is the group's `supervisor` in the
//! snapshot (`starting`, then `present` or `failed`). A refusal below means
//! nothing was started.
//!
//! ## The refusals
//!
//! | act | refused with | when |
//! |---|---|---|
//! | any | `BadRequest` | not JSON, no such `act`, a field missing or of the wrong type |
//! | seen, snooze, unsnooze | `NoSuchGroup` | the group is not there |
//! | seen (a terminal) | `UnknownTerminal` | the terminal is not there |
//! | snooze | `SnoozeInThePast` | `until_ms` is not after now |
//! | approve, refuse, reply | `UnknownTerminal` | the terminal is not there |
//! | approve, refuse | `PromptGone` | it is not waiting on an approval; or `since_ms` / `event_ms` are not the ones it has now; or its screen has moved since the box was drawn -- except, for a box with rows its CLI says redraw (Claude Code's auto-mode countdown, task 1655), where the rest of the box has to be as it was and those rows still on screen |
//! | reply | `NothingToReplyTo` | it is not waiting on an answer, finished, or failed -- a box or a turn in progress is not somewhere to type a sentence; or no agent is connected from it any more, so the line would go to a bare shell |
//! | reply | `Stale` | `since_ms` is not the one it has now |
//! | reply | `EmptyText` | nothing but whitespace |
//! | approve, refuse, reply | `UserPresent` | a key reached that terminal in the last ten seconds |
//! | approve, refuse, reply | `DraftInLine` | there is unsubmitted text in its input line |
//! | approve, refuse, reply | `ChildExited` | its process has ended |
//! | fix | `NothingToFix` | the card does not read "Failed" any more, or is not there |
//! | fix | `AlreadyNotified` | it was pressed, and the card has not changed since |
//! | fix | `NoAgent`, `UserPresent`, `DraftInLine`, ... | a mention's refusals: the paragraph is kept in the group, and was not typed |
//! | approve, refuse | `KeyFailed` | the key did not reach the program |
//! | new_group | `BadName` | the name is empty, longer than 48, or has anything but `a-z`, `0-9` and `-` in it |
//! | new_group | `GroupExists` | there is one by that name |
//! | new_group | `TooManyGroups` | the list is full |
//! | start_supervisor | `NoSuchGroup` | the group is not there |
//! | start_supervisor | `HasSupervisor` | it has one |
//! | start_supervisor | `AlreadyStarting` | one is on its way |
//! | start_supervisor | `NoSupervisorRole` | no role was named and there is none to default to |
//! | start_supervisor | `NoSuchPersona`, `NotASupervisorRole`, `NoCli` | the role named is not there, does not make a supervisor, or has no CLI to start |
//! | start_supervisor | `NotAbsolute`, `NoSuchDirectory`, `NotADirectory` | the directory |
//! | start_supervisor | `OpenFailed` | no tab could be opened |
//! | projects | `BadRequest` | an entry lacks a key, two projects have one name, a terminal is on the pages of two, or the supervisor's pane is on no page |
//! | project_failed | `NoSuchProject` | no group is tied to a project by that name |
//! | project_remove | `ProjectsUnknown` | the host has stated nothing yet |
//! | project_remove | `NotInAProject` | that terminal is on no page of an open project |
//! | project_remove | `SupervisorPage` | a group's supervisor is on that page, and the project is that group's |
//! | project_rename | `BadName`, `GroupExists`, and the rest of a group's rename | the project is a group's, and the group cannot take that name |
//! | pin, unpin, mute, unmute, archive, unarchive, set_brief, delete_group, ask_supervisor | `NoSuchGroup` | the group is not there |
//! | rename_group | `NoSuchGroup` | `from` is not there |
//! | mute | `MuteInThePast` | `until_ms` is not after now |
//! | rename_group | `EmptyName` | `to` is empty |
//! | rename_group | `BadName`, `GroupExists` | as for `new_group` |
//! | rename_group | `RenameBlocked`, `RenameBusy`, `RenameUnfinished`, `RenameDeferred`, `RenameFailed` | a rename's own refusals, as `group_rename` gives them (dev-docs/poltergeist/mcp.md); anything else the host fails with is `RenameFailed` |
//! | delete_group | `DeleteFailed` | a directory of its record could not be deleted: it is out of the list and out of memory, and what was not deleted is still on disk |
//! | delete_group | `Stale` | `members` or `open_tasks` are not what they are now |
//! | ask_supervisor | `NoSupervisor` | the group has none |
//! | ask_supervisor | `NoAgent`, `UserPresent`, `DraftInLine`, `ChildExited`, ... | a mention's refusals: kept in the group, not typed; the two that clear by themselves are tried again (#60) |
//!
//! The last four are the terminal's own, from the path every agent's text
//! takes; they are not decided here.

const ControlAct = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bus = @import("Bus.zig");
const Chat = @import("Chat.zig");
const Projects = @import("Projects.zig");
const ControlFix = @import("ControlFix.zig");
const i18n = @import("../os/i18n.zig");

pub const Id = Bus.Id;

pub const Prompt = struct {
    terminal: Id,
    since_ms: u64,
    event_ms: u64,
};

pub const Act = union(enum) {
    seen: []const u8,
    /// The person looked at the row of a terminal that is in no group.
    seen_terminal: Id,
    snooze: struct { group: []const u8, until_ms: ?u64 },
    unsnooze: []const u8,
    approve: Prompt,
    refuse: Prompt,
    reply: struct { terminal: Id, since_ms: u64, text: []const u8 },
    new_group: []const u8,
    /// The "Fix" button on a card that reads "Failed".
    fix: ControlFix.Key,
    /// Empty `role` and `cwd` are "the one the snapshot names".
    start_supervisor: struct { group: []const u8, role: []const u8, cwd: []const u8, session: Session },
    /// Everything the host knows about projects, replacing what it said.
    projects: []const Projects.Stated,
    project_failed: struct { name: []const u8, why: ProjectFailure },
    project_remove: Id,
    project_rename: struct { from: []const u8, to: []const u8 },
    /// The person agreed to the first sweep of old records the notice told
    /// them about (task 1511).
    retention_agree,
    pin: []const u8,
    unpin: []const u8,
    mute: struct { group: []const u8, until_ms: ?u64 },
    unmute: []const u8,
    archive: []const u8,
    unarchive: []const u8,
    rename_group: struct { from: []const u8, to: []const u8 },
    set_brief: struct { group: []const u8, brief: []const u8 },
    delete_group: struct { group: []const u8, members: u64, open_tasks: u64 },
    ask_supervisor: struct { group: []const u8, ask: Ask },
};

/// What the person asks a group's supervisor to do from the right-click
/// menu (task 1659).
pub const Ask = enum {
    /// Report on progress in the group.
    report,
    /// Close the workers that are idle.
    close_idle,

    /// The line, as an English msgid; `tag` goes before it untranslated.
    fn words(self: Ask) [:0]const u8 {
        return switch (self) {
            .report => ask_words.report,
            .close_idle => ask_words.close_idle,
        };
    }
};

/// What `ask_supervisor` starts with, in every language, as `[Polter fix]`
/// does for "Fix": one string the supervisor and its skill can look for.
pub const ask_tag = "[Polter ask]";

// One literal each: `xgettext` reads this file as C and does not follow `++`.
const ask_words = struct {
    const report = i18n.N_("The person asked from the control room: please report on this group's progress -- what is done, what is in progress and what is stuck -- in this group.");
    const close_idle = i18n.N_("The person asked from the control room: please close the workers in this group that are idle -- finished, or waiting with nothing to do -- and say in this group which ones you closed.");
};

/// Why the host could not open a project it was ordered to.
pub const ProjectFailure = enum {
    /// There is no such project file any more.
    not_found,
    /// It is there and does not read.
    unreadable,
};

/// Which session a supervisor is started in.
pub const Session = enum {
    /// The last supervisor's, when it can be gone on with; a new one
    /// otherwise.
    last,
    /// A new one, whatever is written down.
    new,
};

pub const Refusal = error{
    BadRequest,
    NoSuchGroup,
    SnoozeInThePast,
    UnknownTerminal,
    PromptGone,
    NothingToReplyTo,
    Stale,
    EmptyText,
    BadName,
    GroupExists,
    HasSupervisor,
    AlreadyStarting,
    NothingToFix,
    AlreadyNotified,
    MuteInThePast,
    EmptyName,
    RenameFailed,
    NoSupervisor,
};

/// The keys an approval and a refusal are. One key each, and neither
/// counts options: return takes the one highlighted, escape declines.
pub const approve_key = "enter";
pub const refuse_key = "escape";

/// What carrying an act out needs from outside this file.
pub const Host = struct {
    ctx: *anyopaque,
    /// Press one key in a terminal, through the guards an agent's key goes
    /// through, and fail unless it reached the program.
    sendKey: *const fn (ctx: *anyopaque, id: Id, key: []const u8) anyerror!void,
    /// Type a line into a terminal and submit it, through the same guards.
    sendText: *const fn (ctx: *anyopaque, id: Id, text: []const u8) anyerror!void,
    /// Whether an agent is connected from that terminal right now
    /// (`Server.agentPresent`): what the hooks last said is not that.
    agentPresent: *const fn (ctx: *anyopaque, id: Id) bool,
    /// That terminal's screen as it is now, in `alloc`, as terminal_read
    /// reads it: for a permission box whose own rows keep redrawing, the
    /// guard compares it with the box as it was drawn (task 1655).
    readScreen: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, id: Id) anyerror![]const u8,
    /// Rename a group, the way `group_rename` does: disk, panel, project.
    renameGroup: *const fn (ctx: *anyopaque, from: []const u8, to: []const u8) anyerror!void,
    /// Keep a group's brief, the way `group_set_brief` does.
    setBrief: *const fn (ctx: *anyopaque, group: []const u8, brief: []const u8) anyerror!void,
    /// How many of a group's tasks are still open.
    openTasks: *const fn (ctx: *anyopaque, group: []const u8) usize,
    /// Delete a group and its record (see `delete_group` above).
    deleteGroup: *const fn (ctx: *anyopaque, group: []const u8) anyerror!void,
    /// Write a group's marks down.
    persist: *const fn (ctx: *anyopaque, group: []const u8, marks: Chat.Marks) void,
    /// Make a group, the way the person makes one anywhere else: they are
    /// in it, and it is written down so it is there in the morning.
    createGroup: *const fn (ctx: *anyopaque, name: []const u8) anyerror!void,
    /// The terminal that is this group's supervisor, as the snapshot says
    /// it; null when it has none.
    stewardOf: *const fn (ctx: *anyopaque, group: []const u8) ?Id,
    /// Open a tab and start a supervisor for `group` in it. Empty `role`
    /// and `cwd` are the snapshot's.
    startSupervisor: *const fn (ctx: *anyopaque, group: []const u8, role: []const u8, cwd: []const u8, session: Session) anyerror!void,
    /// Take a statement of every project as what is now known.
    stateProjects: *const fn (ctx: *anyopaque, list: []const Projects.Stated) anyerror!void,
    /// A project the host was ordered to open did not open.
    projectFailed: *const fn (ctx: *anyopaque, name: []const u8, why: ProjectFailure) anyerror!void,
    /// Whether the page `terminal` is on may be taken out of its project;
    /// an error named in the table above when not.
    projectRemove: *const fn (ctx: *anyopaque, terminal: Id) anyerror!void,
    /// A project is about to be renamed: rename its group, if it has one.
    projectRename: *const fn (ctx: *anyopaque, from: []const u8, to: []const u8) anyerror!void,
    /// The person agreed to the first sweep of old records.
    retentionAgree: *const fn (ctx: *anyopaque) anyerror!void,
    /// The card the "Fix" button on `key` is on, as last drawn; null when
    /// none offers it (`ControlRoom.fixCard`).
    fixCard: *const fn (ctx: *anyopaque, key: ControlFix.Key) ?ControlFix.Card,
    /// `ControlFix.Port.post` and `.send`: a group post from the person
    /// naming `to`, typed into each; a line typed into a lone terminal.
    fixPost: *const fn (ctx: *anyopaque, group: []const u8, text: []const u8, to: []ControlFix.Target) anyerror!void,
    fixSend: *const fn (ctx: *anyopaque, id: Id, text: []const u8) anyerror!void,
    /// Remember the press (`ControlFix.Sent`, `ControlFix.stampOf`).
    fixSent: *const fn (ctx: *anyopaque, stamp: u64) anyerror!void,
    /// How the paragraph is written: its moments, and its language.
    voice: ControlFix.Voice,
};

fn fieldOf(obj: std.json.ObjectMap, name: []const u8) Refusal!std.json.Value {
    return obj.get(name) orelse error.BadRequest;
}

fn textOf(obj: std.json.ObjectMap, name: []const u8) Refusal![]const u8 {
    return switch (try fieldOf(obj, name)) {
        .string => |s| s,
        else => error.BadRequest,
    };
}

fn msOf(obj: std.json.ObjectMap, name: []const u8) Refusal!u64 {
    return switch (try fieldOf(obj, name)) {
        .integer => |n| if (n >= 0) @intCast(n) else error.BadRequest,
        else => error.BadRequest,
    };
}

fn idOf(obj: std.json.ObjectMap, name: []const u8) Refusal!Id {
    const s = try textOf(obj, name);
    if (s.len != 18 or !std.mem.startsWith(u8, s, "0x")) return error.BadRequest;
    return std.fmt.parseInt(u64, s[2..], 16) catch error.BadRequest;
}

/// Read a request. What it returns borrows from `arena`.
pub fn parse(arena: Allocator, json: []const u8) (Refusal || Allocator.Error)!Act {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadRequest,
    };
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.BadRequest,
    };

    const Name = enum {
        seen,
        snooze,
        unsnooze,
        approve,
        refuse,
        reply,
        new_group,
        fix,
        start_supervisor,
        projects,
        project_failed,
        project_remove,
        project_rename,
        retention_agree,
        pin,
        unpin,
        mute,
        unmute,
        archive,
        unarchive,
        rename_group,
        set_brief,
        delete_group,
        ask_supervisor,
    };
    const name = std.meta.stringToEnum(Name, try textOf(obj, "act")) orelse return error.BadRequest;
    return switch (name) {
        // One or the other: a row is a group's or a lone terminal's.
        .seen => if (obj.get("terminal")) |_|
            (if (obj.get("group")) |_| return error.BadRequest else .{ .seen_terminal = try idOf(obj, "terminal") })
        else
            .{ .seen = try textOf(obj, "group") },
        .unsnooze => .{ .unsnooze = try textOf(obj, "group") },
        .snooze => .{ .snooze = .{
            .group = try textOf(obj, "group"),
            .until_ms = if (obj.get("until_ms")) |v| switch (v) {
                .null => null,
                else => try msOf(obj, "until_ms"),
            } else null,
        } },
        .approve => .{ .approve = try promptOf(obj) },
        .refuse => .{ .refuse = try promptOf(obj) },
        .reply => .{ .reply = .{
            .terminal = try idOf(obj, "terminal"),
            .since_ms = try msOf(obj, "since_ms"),
            .text = try textOf(obj, "text"),
        } },
        .new_group => .{ .new_group = try textOf(obj, "name") },
        // One or the other, as for `seen`.
        .fix => if (obj.get("terminal")) |_|
            (if (obj.get("group")) |_| return error.BadRequest else .{ .fix = .{ .terminal = try idOf(obj, "terminal") } })
        else
            .{ .fix = .{ .group = try textOf(obj, "group") } },
        .start_supervisor => .{
            .start_supervisor = .{
                .group = try textOf(obj, "group"),
                .role = if (obj.get("role")) |_| try textOf(obj, "role") else "",
                .cwd = if (obj.get("cwd")) |_| try textOf(obj, "cwd") else "",
                // A word that is neither is not a request: guessing which was
                // meant would start the session the person did not ask for.
                .session = if (obj.get("session")) |_|
                    std.meta.stringToEnum(Session, try textOf(obj, "session")) orelse return error.BadRequest
                else
                    .last,
            },
        },
        .projects => .{ .projects = try Projects.parse(arena, try fieldOf(obj, "list")) },
        .project_failed => .{ .project_failed = .{
            .name = try textOf(obj, "name"),
            .why = std.meta.stringToEnum(ProjectFailure, try textOf(obj, "why")) orelse return error.BadRequest,
        } },
        .project_remove => .{ .project_remove = try idOf(obj, "terminal") },
        .project_rename => .{ .project_rename = .{
            .from = try textOf(obj, "from"),
            .to = try textOf(obj, "to"),
        } },
        .retention_agree => .retention_agree,
        .pin => .{ .pin = try textOf(obj, "group") },
        .unpin => .{ .unpin = try textOf(obj, "group") },
        .mute => .{ .mute = .{
            .group = try textOf(obj, "group"),
            .until_ms = if (obj.get("until_ms")) |v| switch (v) {
                .null => null,
                else => try msOf(obj, "until_ms"),
            } else null,
        } },
        .unmute => .{ .unmute = try textOf(obj, "group") },
        .archive => .{ .archive = try textOf(obj, "group") },
        .unarchive => .{ .unarchive = try textOf(obj, "group") },
        .rename_group => .{ .rename_group = .{
            .from = try textOf(obj, "from"),
            .to = try textOf(obj, "to"),
        } },
        .set_brief => .{ .set_brief = .{
            .group = try textOf(obj, "group"),
            .brief = try textOf(obj, "brief"),
        } },
        .delete_group => .{ .delete_group = .{
            .group = try textOf(obj, "group"),
            .members = try msOf(obj, "members"),
            .open_tasks = try msOf(obj, "open_tasks"),
        } },
        .ask_supervisor => .{ .ask_supervisor = .{
            .group = try textOf(obj, "group"),
            .ask = std.meta.stringToEnum(Ask, try textOf(obj, "ask")) orelse return error.BadRequest,
        } },
    };
}

fn promptOf(obj: std.json.ObjectMap) Refusal!Prompt {
    return .{
        .terminal = try idOf(obj, "terminal"),
        .since_ms = try msOf(obj, "since_ms"),
        .event_ms = try msOf(obj, "event_ms"),
    };
}

/// Carry one act out, or refuse it. `now_ms` is the bus's clock, `wall_ms`
/// the real one.
pub fn perform(
    act: Act,
    bus: *Bus,
    chat: *Chat,
    host: Host,
    now_ms: u64,
    wall_ms: u64,
) anyerror!void {
    switch (act) {
        .seen => |group| {
            chat.markSeen(group, now_ms, wall_ms) catch return error.NoSuchGroup;
            host.persist(host.ctx, group, try chat.marksOf(group));
        },
        // Nothing to write down: the mark is the terminal's, and a
        // terminal's id does not outlive the run (`Bus.Entry.seen_ms`).
        .seen_terminal => |id| if (!bus.markSeen(id, now_ms)) return error.UnknownTerminal,
        .snooze => |s| {
            if (!chat.exists(s.group)) return error.NoSuchGroup;
            const snooze: Chat.Marks.Snooze = if (s.until_ms) |until| until: {
                if (until <= wall_ms) return error.SnoozeInThePast;
                break :until .{ .until = .{ .at_ms = wall_ms, .until_ms = until } };
            } else .{ .next_event = wall_ms };
            try chat.setSnooze(s.group, snooze, now_ms);
            host.persist(host.ctx, s.group, try chat.marksOf(s.group));
        },
        .unsnooze => |group| {
            chat.setSnooze(group, .none, now_ms) catch return error.NoSuchGroup;
            host.persist(host.ctx, group, try chat.marksOf(group));
        },
        .approve => |p| {
            try standing(bus, host, p, now_ms);
            try host.sendKey(host.ctx, p.terminal, approve_key);
        },
        .refuse => |p| {
            try standing(bus, host, p, now_ms);
            try host.sendKey(host.ctx, p.terminal, refuse_key);
        },
        .reply => |r| {
            const text = std.mem.trim(u8, r.text, " \t\r\n");
            if (text.len == 0) return error.EmptyText;
            const e = bus.get(r.terminal) orelse return error.UnknownTerminal;
            const a = e.agent;
            const open = a.hooks == .live and switch (a.state) {
                .awaiting_input, .ended, .failed => true,
                // A permission box takes keys, not a sentence, and a turn
                // in progress is not waiting to be told anything.
                .awaiting_approval, .in_turn, .idle => false,
            };
            if (!open) return error.NothingToReplyTo;
            if (a.since_ms != r.since_ms) return error.Stale;
            // **And somebody still there to read it** (#1533). `ended` and
            // `failed` are what the hooks said last, and an agent that has
            // exited said nothing after that: the terminal is a bare shell,
            // and a sentence typed with a return is run as a command. The
            // person's next move is the same as for any other state that is
            // not waiting on them, so it is the same refusal.
            if (!host.agentPresent(host.ctx, r.terminal)) return error.NothingToReplyTo;
            try host.sendText(host.ctx, r.terminal, text);
        },
        .new_group => |raw| {
            // What was typed, less the space round it. Nothing else is
            // done to it: a name that is not allowed is refused and said,
            // not turned into one the person did not type.
            // Whether it is a name, and whether it is taken, are the chat's
            // to say when it makes the group (`Chat.create`).
            const name = std.mem.trim(u8, raw, " \t\r\n");
            try host.createGroup(host.ctx, name);
        },
        .fix => |key| {
            const card = host.fixCard(host.ctx, key) orelse return error.NothingToFix;
            if (card.state == .sent) return error.AlreadyNotified;
            var arena: std.heap.ArenaAllocator = .init(chat.alloc);
            defer arena.deinit();
            const deliveries = try ControlFix.plan(arena.allocator(), card, host.voice);
            try ControlFix.deliver(card.key, deliveries, .{
                .ctx = host.ctx,
                .agentPresent = host.agentPresent,
                .post = host.fixPost,
                .send = host.fixSend,
            });
            try host.fixSent(host.ctx, ControlFix.stampOf(card.steward, card.failing));
        },
        .start_supervisor => |s| {
            if (!chat.exists(s.group)) return error.NoSuchGroup;
            if (host.stewardOf(host.ctx, s.group) != null) return error.HasSupervisor;
            // Asked here as well as where the start is recorded, so that a
            // second press is refused before anything is opened for it.
            if (chat.startOf(s.group, now_ms).state == .starting) return error.AlreadyStarting;
            try host.startSupervisor(host.ctx, s.group, s.role, s.cwd, s.session);
        },
        .projects => |list| try host.stateProjects(host.ctx, list),
        .project_failed => |f| try host.projectFailed(host.ctx, f.name, f.why),
        .project_remove => |terminal| try host.projectRemove(host.ctx, terminal),
        .project_rename => |r| try host.projectRename(host.ctx, r.from, r.to),
        .retention_agree => try host.retentionAgree(host.ctx),
        .pin, .unpin => |group| {
            try chat.setPinned(group, act == .pin);
            host.persist(host.ctx, group, try chat.marksOf(group));
        },
        .mute => |m| {
            const mute: Chat.Marks.Mute = if (m.until_ms) |until| until: {
                if (until <= wall_ms) return error.MuteInThePast;
                break :until .{ .until = until };
            } else .forever;
            try chat.setMute(m.group, mute);
            host.persist(host.ctx, m.group, try chat.marksOf(m.group));
        },
        .unmute => |group| {
            try chat.setMute(group, .none);
            host.persist(host.ctx, group, try chat.marksOf(group));
        },
        .archive, .unarchive => |group| {
            try chat.setArchived(group, if (act == .archive) wall_ms else null);
            host.persist(host.ctx, group, try chat.marksOf(group));
        },
        .rename_group => |r| {
            if (!chat.exists(r.from)) return error.NoSuchGroup;
            if (r.to.len == 0) return error.EmptyName;
            if (!Chat.isValidName(r.to)) return error.BadName;
            if (std.mem.eql(u8, r.from, r.to)) return;
            if (chat.exists(r.to)) return error.GroupExists;
            // A rename's own refusals by their own names (`GroupRename
            // .refusal`): `RenameBlocked` -- the disk still has a record by
            // that name -- is a different thing to tell the person from
            // "could not be moved". Anything else is `RenameFailed`.
            host.renameGroup(host.ctx, r.from, r.to) catch |err| return switch (err) {
                error.NoSuchGroup,
                error.BadName,
                error.GroupExists,
                error.RenameBlocked,
                error.RenameBusy,
                error.RenameUnfinished,
                error.RenameDeferred,
                error.RenameFailed,
                => err,
                else => error.RenameFailed,
            };
        },
        .set_brief => |b| {
            if (!chat.exists(b.group)) return error.NoSuchGroup;
            try host.setBrief(host.ctx, b.group, b.brief);
        },
        .delete_group => |d| {
            const members = chat.othersIn(d.group) catch return error.NoSuchGroup;
            if (members != d.members or host.openTasks(host.ctx, d.group) != d.open_tasks) return error.Stale;
            try host.deleteGroup(host.ctx, d.group);
        },
        .ask_supervisor => |a| {
            if (!chat.exists(a.group)) return error.NoSuchGroup;
            const steward = host.stewardOf(host.ctx, a.group) orelse return error.NoSupervisor;
            var buf: [1024]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{s} {s}", .{ ask_tag, host.voice.tr(a.ask.words()) }) catch return error.BadRequest;
            var to = [_]ControlFix.Target{.{ .to = steward }};
            try host.fixPost(host.ctx, a.group, text, &to);
            if (to[0].err) |err| return err;
        },
    }
}

/// The guard on anything that answers a prompt: the one the person saw is
/// the one still there.
fn standing(bus: *const Bus, host: Host, p: Prompt, now_ms: u64) Refusal!void {
    if (bus.get(p.terminal) == null) return error.UnknownTerminal;
    // Read only for a box that needs it, as terminal_answer_prompt does.
    const alloc = std.heap.page_allocator;
    const screen: ?[]const u8 = if (bus.promptNeedsScreen(p.terminal))
        host.readScreen(host.ctx, alloc, p.terminal) catch null
    else
        null;
    defer if (screen) |s| alloc.free(s);
    if (!bus.promptStanding(p.terminal, p.since_ms, p.event_ms, now_ms, screen)) return error.PromptGone;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const AgentEvent = @import("agent_event.zig");

/// A host that only writes down what it was asked to do.
const Recorder = struct {
    keys: std.ArrayListUnmanaged([]const u8) = .empty,
    texts: std.ArrayListUnmanaged([]const u8) = .empty,
    persisted: std.ArrayListUnmanaged(Chat.Marks) = .empty,
    refuse_with: ?anyerror = null,
    /// The chat a made group goes into, as the real host's does.
    chat: ?*Chat = null,
    steward: ?Id = null,
    started: std.ArrayListUnmanaged(Started) = .empty,
    /// How many projects the last statement had, and how many open.
    stated: ?usize = null,
    stated_open: usize = 0,
    project_failed: ?ProjectFailure = null,
    asked_remove: ?Id = null,
    renames: usize = 0,
    agreed: usize = 0,
    /// The terminal's agent has exited and left its shell behind.
    agent_gone: bool = false,
    /// The card a "Fix" is aimed at, and what came of it.
    fix_card: ?ControlFix.Card = null,
    fix_posts: std.ArrayListUnmanaged([]const u8) = .empty,
    fix_typed: usize = 0,
    fix_marked: ?u64 = null,
    /// What `readScreen` answers.
    screen: []const u8 = "",
    /// What reached the host, copied: the request's strings are gone when
    /// `act` returns.
    renamed: ?[]const u8 = null,
    brief: ?[]const u8 = null,
    open_tasks: usize = 0,
    deleted: ?[]const u8 = null,

    const Started = struct { group: []const u8, role: []const u8, cwd: []const u8, session: Session };

    fn deinit(self: *Recorder) void {
        self.keys.deinit(testing.allocator);
        self.texts.deinit(testing.allocator);
        self.persisted.deinit(testing.allocator);
        for (self.started.items) |st| {
            testing.allocator.free(st.group);
            testing.allocator.free(st.role);
            testing.allocator.free(st.cwd);
        }
        self.started.deinit(testing.allocator);
        for (self.fix_posts.items) |t| testing.allocator.free(t);
        inline for (.{ "renamed", "brief", "deleted" }) |f| {
            if (@field(self, f)) |v| testing.allocator.free(v);
        }
        self.fix_posts.deinit(testing.allocator);
    }

    fn host(self: *Recorder) Host {
        return .{
            .ctx = self,
            .sendKey = sendKey,
            .sendText = sendText,
            .agentPresent = agentPresent,
            .readScreen = readScreen,
            .renameGroup = renameGroup,
            .setBrief = setBrief,
            .openTasks = openTasks,
            .deleteGroup = deleteGroup,
            .persist = persist,
            .createGroup = createGroup,
            .stewardOf = stewardOf,
            .startSupervisor = startSupervisor,
            .stateProjects = stateProjects,
            .projectFailed = projectFailed,
            .projectRemove = projectRemove,
            .projectRename = projectRename,
            .retentionAgree = retentionAgree,
            .fixCard = fixCard,
            .fixPost = fixPost,
            .fixSend = fixSend,
            .fixSent = fixSent,
            .voice = .{ .clock = clock, .tr = ControlFix.english },
        };
    }

    fn readScreen(ctx: *anyopaque, alloc: std.mem.Allocator, _: Id) anyerror![]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        return alloc.dupe(u8, self.screen);
    }

    fn keep(slot: *?[]const u8, s: []const u8) !void {
        if (slot.*) |old| testing.allocator.free(old);
        slot.* = try testing.allocator.dupe(u8, s);
    }

    fn renameGroup(ctx: *anyopaque, _: []const u8, to: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_with) |err| return err;
        try keep(&self.renamed, to);
    }

    fn setBrief(ctx: *anyopaque, _: []const u8, brief: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        try keep(&self.brief, brief);
    }

    fn openTasks(ctx: *anyopaque, _: []const u8) usize {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        return self.open_tasks;
    }

    fn deleteGroup(ctx: *anyopaque, group: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        try keep(&self.deleted, group);
    }

    fn fixCard(ctx: *anyopaque, _: ControlFix.Key) ?ControlFix.Card {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        return self.fix_card;
    }

    fn fixPost(ctx: *anyopaque, _: []const u8, text: []const u8, to: []ControlFix.Target) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        try self.fix_posts.append(testing.allocator, try testing.allocator.dupe(u8, text));
        for (to) |*t| {
            if (self.refuse_with) |err| t.err = err else self.fix_typed += 1;
        }
    }

    fn fixSend(ctx: *anyopaque, _: Id, _: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_with) |err| return err;
        self.fix_typed += 1;
    }

    fn fixSent(ctx: *anyopaque, stamp: u64) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.fix_marked = stamp;
    }

    fn clock(buf: *[19]u8, _: i64) []const u8 {
        @memcpy(buf[0..5], "12:00");
        return buf[0..5];
    }

    fn retentionAgree(ctx: *anyopaque) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_with) |err| return err;
        self.agreed += 1;
    }

    fn stateProjects(ctx: *anyopaque, list: []const Projects.Stated) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_with) |err| return err;
        self.stated = list.len;
        self.stated_open = 0;
        for (list) |p| {
            if (p.open != null) self.stated_open += 1;
        }
    }

    fn projectFailed(ctx: *anyopaque, _: []const u8, why: ProjectFailure) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_with) |err| return err;
        self.project_failed = why;
    }

    fn projectRemove(ctx: *anyopaque, terminal: Id) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_with) |err| return err;
        self.asked_remove = terminal;
    }

    fn projectRename(ctx: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_with) |err| return err;
        self.renames += 1;
    }

    fn createGroup(ctx: *anyopaque, name: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_with) |err| return err;
        try self.chat.?.create(name, Chat.user_id);
    }

    fn stewardOf(ctx: *anyopaque, _: []const u8) ?Id {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        return self.steward;
    }

    fn startSupervisor(ctx: *anyopaque, group: []const u8, role: []const u8, cwd: []const u8, session: Session) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_with) |err| return err;
        // Copied: the request they point into is gone when the act returns.
        const a = testing.allocator;
        try self.started.append(a, .{ .group = try a.dupe(u8, group), .role = try a.dupe(u8, role), .cwd = try a.dupe(u8, cwd), .session = session });
    }

    fn sendKey(ctx: *anyopaque, _: Id, key: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_with) |err| return err;
        try self.keys.append(testing.allocator, key);
    }

    fn sendText(ctx: *anyopaque, _: Id, text: []const u8) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.refuse_with) |err| return err;
        try self.texts.append(testing.allocator, text);
    }

    fn agentPresent(ctx: *anyopaque, _: Id) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        return !self.agent_gone;
    }

    fn persist(ctx: *anyopaque, _: []const u8, marks: Chat.Marks) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.persisted.append(testing.allocator, marks) catch {};
    }
};

const term: Id = 0xa1;
const wall: u64 = 1_700_000_000_000;

const Bench = struct {
    bus: Bus,
    chat: Chat,
    rec: Recorder = .{},

    fn init() !Bench {
        var b: Bench = .{ .bus = .init(testing.allocator, .{}), .chat = .init(testing.allocator, .{}) };
        errdefer b.deinit();
        try b.bus.addSupervisor(term);
        try b.chat.create("web-app", term);
        return b;
    }

    fn deinit(self: *Bench) void {
        self.rec.deinit();
        self.chat.deinit();
        self.bus.deinit();
    }

    fn hook(self: *Bench, kind: AgentEvent.Kind, note: ?[]const u8, at_ms: u64) !void {
        var ev: AgentEvent.Event = .none;
        ev.event = kind;
        ev.note = note;
        _ = try self.bus.agentEvent(term, ev, at_ms);
    }

    fn act(self: *Bench, json: []const u8, now_ms: u64) !void {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const parsed = try parse(arena.allocator(), json);
        self.rec.chat = &self.chat;
        try perform(parsed, &self.bus, &self.chat, self.rec.host(), now_ms, wall + now_ms);
    }
};

test "ControlRoom act: approving the prompt that is there presses return, once" {
    var b = try Bench.init();
    defer b.deinit();
    try b.hook(.awaiting_approval, "Bash(rm -rf dist/)", 1_000);

    try b.act(
        \\{"act":"approve","terminal":"0x00000000000000a1","since_ms":1000,"event_ms":1000}
    , 5_000);
    try testing.expectEqual(@as(usize, 1), b.rec.keys.items.len);
    try testing.expectEqualStrings("enter", b.rec.keys.items[0]);
    try testing.expectEqual(@as(usize, 0), b.rec.texts.items.len);
}

test "ControlRoom act: refusing presses escape" {
    var b = try Bench.init();
    defer b.deinit();
    try b.hook(.awaiting_approval, "Bash(rm -rf dist/)", 1_000);

    try b.act(
        \\{"act":"refuse","terminal":"0x00000000000000a1","since_ms":1000,"event_ms":1000}
    , 5_000);
    try testing.expectEqual(@as(usize, 1), b.rec.keys.items.len);
    try testing.expectEqualStrings("escape", b.rec.keys.items[0]);
}

test "ControlRoom act: the prompt has changed, so no key is sent" {
    var b = try Bench.init();
    defer b.deinit();
    try b.hook(.awaiting_approval, "Bash(rm -rf dist/)", 1_000);
    // The row was drawn. Then a different box took its place.
    try b.hook(.awaiting_approval, "Bash(git push --force)", 4_000);

    const seen_then =
        \\{"act":"approve","terminal":"0x00000000000000a1","since_ms":1000,"event_ms":1000}
    ;
    try testing.expectError(error.PromptGone, b.act(seen_then, 5_000));
    try testing.expectEqual(@as(usize, 0), b.rec.keys.items.len);

    // Refusing what is no longer there is refused the same way.
    try testing.expectError(error.PromptGone, b.act(
        \\{"act":"refuse","terminal":"0x00000000000000a1","since_ms":1000,"event_ms":1000}
    , 5_000));
    try testing.expectEqual(@as(usize, 0), b.rec.keys.items.len);
}

test "ControlRoom act: a prompt that was answered already takes no key" {
    var b = try Bench.init();
    defer b.deinit();
    try b.hook(.awaiting_approval, "Bash(x)", 1_000);
    // It went on with its turn.
    try b.hook(.turn_started, null, 2_000);

    try testing.expectError(error.PromptGone, b.act(
        \\{"act":"approve","terminal":"0x00000000000000a1","since_ms":1000,"event_ms":1000}
    , 5_000));
    // Not even with the moments it has now: it is not waiting on a box.
    try testing.expectError(error.PromptGone, b.act(
        \\{"act":"approve","terminal":"0x00000000000000a1","since_ms":2000,"event_ms":2000}
    , 5_000));
    try testing.expectEqual(@as(usize, 0), b.rec.keys.items.len);

    try testing.expectError(error.UnknownTerminal, b.act(
        \\{"act":"approve","terminal":"0x00000000000000ff","since_ms":1000,"event_ms":1000}
    , 5_000));
}

test "ControlRoom act: what the terminal refuses is the answer, by its own name" {
    var b = try Bench.init();
    defer b.deinit();
    try b.hook(.awaiting_approval, "Bash(x)", 1_000);

    b.rec.refuse_with = error.DraftInLine;
    try testing.expectError(error.DraftInLine, b.act(
        \\{"act":"approve","terminal":"0x00000000000000a1","since_ms":1000,"event_ms":1000}
    , 5_000));
    b.rec.refuse_with = error.UserPresent;
    try b.hook(.awaiting_input, "which?", 6_000);
    try testing.expectError(error.UserPresent, b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":6000,"text":"the second"}
    , 7_000));
}

test "ControlRoom act: a reply goes to an agent that is waiting to be told something" {
    var b = try Bench.init();
    defer b.deinit();
    try b.hook(.awaiting_input, "which format?", 1_000);

    try b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":1000,"text":"  the second one\n"}
    , 5_000);
    try testing.expectEqual(@as(usize, 1), b.rec.texts.items.len);
    try testing.expectEqual(@as(usize, 0), b.rec.keys.items.len);

    // Said again by the agent: the same wait, and still answerable.
    try b.hook(.awaiting_input, "which format?", 6_000);
    try b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":1000,"text":"the second"}
    , 7_000);
    try testing.expectEqual(@as(usize, 2), b.rec.texts.items.len);
}

test "ControlRoom act: a box whose countdown redraws can be refused from the control room (task 1655)" {
    var b = Bus.init(testing.allocator, .{});
    defer b.deinit();
    var chat: Chat = .init(testing.allocator, .{});
    defer chat.deinit();
    var rec: Recorder = .{};
    defer rec.deinit();
    try b.addSupervisor(0xb0);
    try b.watch(0xa1, 0xb0);
    var ev: AgentEvent.Event = .none;
    ev.event = .awaiting_approval;
    ev.cli = "claude-code";
    ev.session_id = "s";
    ev.detail = "Bash";
    _ = try b.agentEvent(0xa1, ev, 1_000);
    const box = " rm x\n ⚠ Claude Code will automatically deny this request in 1:54, to avoid\n";
    try testing.expect(b.noteBoxPrint(0xa1, 1_000, box));
    b.noteQuiet(0xa1, 0, 20_000);

    const p: Prompt = .{ .terminal = 0xa1, .since_ms = 1_000, .event_ms = 1_000 };
    rec.screen = " rm x\n ⚠ Claude Code will automatically deny this request in 1:35, to avoid\n";
    try perform(.{ .refuse = p }, &b, &chat, rec.host(), 20_000, 0);
    try testing.expectEqual(@as(usize, 1), rec.keys.items.len);

    rec.screen = " > \n";
    try testing.expectError(error.PromptGone, perform(.{ .refuse = p }, &b, &chat, rec.host(), 20_000, 0));
    try testing.expectEqual(@as(usize, 1), rec.keys.items.len);
}

test "ControlRoom act: a reply is not typed into a box, a turn, or a state that has moved on" {
    var b = try Bench.init();
    defer b.deinit();

    try b.hook(.awaiting_approval, "Bash(x)", 1_000);
    try testing.expectError(error.NothingToReplyTo, b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":1000,"text":"yes"}
    , 2_000));

    try b.hook(.turn_started, null, 3_000);
    try testing.expectError(error.NothingToReplyTo, b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":3000,"text":"hurry"}
    , 4_000));

    try b.hook(.turn_ended, null, 5_000);
    try testing.expectError(error.Stale, b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":1000,"text":"go on"}
    , 6_000));
    try testing.expectError(error.EmptyText, b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":5000,"text":"  \n"}
    , 6_000));
    try testing.expectEqual(@as(usize, 0), b.rec.texts.items.len);

    try b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":5000,"text":"go on"}
    , 6_000);
    try testing.expectEqual(@as(usize, 1), b.rec.texts.items.len);
}

test "ControlRoom act: a reply to an agent that has exited is not typed at its shell (#1533)" {
    var b = try Bench.init();
    defer b.deinit();

    // The last thing its hooks said was that it finished; then it exited.
    try b.hook(.turn_ended, null, 1_000);
    b.rec.agent_gone = true;
    try testing.expectError(error.NothingToReplyTo, b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":1000,"text":"done; rm -rf build"}
    , 2_000));
    try testing.expectEqual(@as(usize, 0), b.rec.texts.items.len);

    // The same reply with the agent still there is typed.
    b.rec.agent_gone = false;
    try b.act(
        \\{"act":"reply","terminal":"0x00000000000000a1","since_ms":1000,"text":"go on"}
    , 2_000);
    try testing.expectEqual(@as(usize, 1), b.rec.texts.items.len);
}

test "ControlRoom act: seen and snooze change the group's marks and are written down" {
    var b = try Bench.init();
    defer b.deinit();

    try b.act(
        \\{"act":"seen","group":"web-app"}
    , 5_000);
    try testing.expectEqual(@as(?u64, wall + 5_000), (try b.chat.marksOf("web-app")).seen_ms);
    try testing.expectEqual(@as(?u64, 5_000), b.chat.seenRunMs("web-app"));

    try b.act(
        \\{"act":"snooze","group":"web-app"}
    , 6_000);
    try testing.expectEqual(Chat.Marks.Snooze{ .next_event = wall + 6_000 }, (try b.chat.marksOf("web-app")).snooze);

    try b.act(
        \\{"act":"snooze","group":"web-app","until_ms":1700000090000}
    , 7_000);
    try testing.expectEqual(
        Chat.Marks.Snooze{ .until = .{ .at_ms = wall + 7_000, .until_ms = wall + 90_000 } },
        (try b.chat.marksOf("web-app")).snooze,
    );

    try b.act(
        \\{"act":"unsnooze","group":"web-app"}
    , 8_000);
    try testing.expectEqual(Chat.Marks.Snooze.none, (try b.chat.marksOf("web-app")).snooze);

    // Each of the four was handed on to be written, as it stood then.
    try testing.expectEqual(@as(usize, 4), b.rec.persisted.items.len);
    try testing.expectEqual(Chat.Marks.Snooze.none, b.rec.persisted.items[3].snooze);
    try testing.expectEqual(@as(?u64, wall + 5_000), b.rec.persisted.items[3].seen_ms);
    // And none of them touched a terminal.
    try testing.expectEqual(@as(usize, 0), b.rec.keys.items.len);
}

test "ControlRoom act: a mark on a group that is not there, or a snooze into the past, is refused" {
    var b = try Bench.init();
    defer b.deinit();

    try testing.expectError(error.NoSuchGroup, b.act(
        \\{"act":"seen","group":"nope"}
    , 1_000));
    try testing.expectError(error.NoSuchGroup, b.act(
        \\{"act":"snooze","group":"nope"}
    , 1_000));
    try testing.expectError(error.NoSuchGroup, b.act(
        \\{"act":"unsnooze","group":"nope"}
    , 1_000));
    try testing.expectError(error.SnoozeInThePast, b.act(
        \\{"act":"snooze","group":"web-app","until_ms":1700000000500}
    , 1_000));
    try testing.expectEqual(@as(usize, 0), b.rec.persisted.items.len);
}

test "ControlRoom act: a request that is not one is refused before anything is looked at" {
    var b = try Bench.init();
    defer b.deinit();
    const bad = [_][]const u8{
        "not json",
        "[]",
        "{}",
        "{\"act\":\"explode\",\"group\":\"web-app\"}",
        "{\"act\":\"seen\"}",
        "{\"act\":\"approve\",\"terminal\":\"161\",\"since_ms\":1,\"event_ms\":1}",
        "{\"act\":\"approve\",\"terminal\":\"0x00000000000000a1\",\"since_ms\":1}",
        "{\"act\":\"approve\",\"terminal\":\"0x00000000000000a1\",\"since_ms\":-1,\"event_ms\":1}",
        "{\"act\":\"reply\",\"terminal\":\"0x00000000000000a1\",\"since_ms\":1}",
    };
    for (bad) |json| try testing.expectError(error.BadRequest, b.act(json, 1_000));
    try testing.expectEqual(@as(usize, 0), b.rec.keys.items.len);
}

test "ControlRoom start: a new group is made by the name that was typed, or refused by name" {
    var b = try Bench.init();
    defer b.deinit();

    try b.act(
        \\{"act":"new_group","name":"  billing-2 \n"}
    , 1_000);
    try testing.expect(b.chat.exists("billing-2"));
    // The person made it, and is in it.
    try testing.expectEqual(Chat.user_id, try b.chat.createdBy("billing-2"));

    try testing.expectError(error.GroupExists, b.act(
        \\{"act":"new_group","name":"web-app"}
    , 1_000));
    // Not turned into a name nobody typed.
    for ([_][]const u8{ "", "   ", "Web App", "web_app", "群", "a" ** 49 }) |bad| {
        var buf: [128]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{{\"act\":\"new_group\",\"name\":\"{s}\"}}", .{bad});
        try testing.expectError(error.BadName, b.act(json, 1_000));
    }
    try testing.expectEqual(@as(usize, 2), b.chat.groups.count());

    b.rec.refuse_with = error.TooManyGroups;
    try testing.expectError(error.TooManyGroups, b.act(
        \\{"act":"new_group","name":"one-more"}
    , 1_000));
    try testing.expectError(error.BadRequest, b.act(
        \\{"act":"new_group"}
    , 1_000));
}

test "ControlRoom start: a supervisor is started for a group that has none, once" {
    var b = try Bench.init();
    defer b.deinit();
    try b.chat.restoreShell("nightly", "", 0, .none);

    // No such group, and one that is minded: nothing is opened for either.
    try testing.expectError(error.NoSuchGroup, b.act(
        \\{"act":"start_supervisor","group":"nope"}
    , 1_000));
    b.rec.steward = term;
    try testing.expectError(error.HasSupervisor, b.act(
        \\{"act":"start_supervisor","group":"web-app"}
    , 1_000));
    try testing.expectEqual(@as(usize, 0), b.rec.started.items.len);

    // With nothing named, the host is handed nothing to override with.
    b.rec.steward = null;
    try b.act(
        \\{"act":"start_supervisor","group":"nightly"}
    , 1_000);
    try testing.expectEqual(@as(usize, 1), b.rec.started.items.len);
    try testing.expectEqualStrings("", b.rec.started.items[0].role);
    try testing.expectEqualStrings("", b.rec.started.items[0].cwd);
    // Nor a session: left out is the last one, where it can be gone on with.
    try testing.expectEqual(Session.last, b.rec.started.items[0].session);

    // One is on its way (the real host records that as it opens the tab):
    // a second press opens nothing.
    try b.chat.beginStart("nightly", 1_000, 11_000, false, .directory);
    try testing.expectError(error.AlreadyStarting, b.act(
        \\{"act":"start_supervisor","group":"nightly","role":"night-lead","cwd":"/work"}
    , 2_000));
    try testing.expectEqual(@as(usize, 1), b.rec.started.items.len);

    // It failed: trying again is allowed, and what was picked is handed on.
    try b.act(
        \\{"act":"start_supervisor","group":"nightly","role":"night-lead","cwd":"/work"}
    , 11_001);
    try testing.expectEqual(@as(usize, 2), b.rec.started.items.len);

    // Which session is the person's to say, and is handed on as said.
    try b.act(
        \\{"act":"start_supervisor","group":"nightly","session":"new"}
    , 11_001);
    try b.act(
        \\{"act":"start_supervisor","group":"nightly","session":"last"}
    , 11_001);
    try testing.expectEqual(Session.new, b.rec.started.items[2].session);
    try testing.expectEqual(Session.last, b.rec.started.items[3].session);
    // A word that is neither starts nothing.
    for ([_][]const u8{
        \\{"act":"start_supervisor","group":"nightly","session":"resume"}
        ,
        \\{"act":"start_supervisor","group":"nightly","session":""}
        ,
        \\{"act":"start_supervisor","group":"nightly","session":true}
        ,
    }) |bad| try testing.expectError(error.BadRequest, b.act(bad, 11_001));
    try testing.expectEqual(@as(usize, 4), b.rec.started.items.len);

    // What the host refuses is the answer, by its own name.
    b.rec.refuse_with = error.NoSuchDirectory;
    try testing.expectError(error.NoSuchDirectory, b.act(
        \\{"act":"start_supervisor","group":"nightly","cwd":"/gone"}
    , 11_002));
    try testing.expectError(error.BadRequest, b.act(
        \\{"act":"start_supervisor","group":"nightly","role":7}
    , 11_002));
}

test "ControlRoom act: a terminal in no group is marked seen by its own id" {
    var b = try Bench.init();
    defer b.deinit();
    try testing.expectEqual(@as(?u64, null), b.bus.seenOf(term));

    try b.act(
        \\{"act":"seen","terminal":"0x00000000000000a1"}
    , 5_000);
    try testing.expectEqual(@as(?u64, 5_000), b.bus.seenOf(term));
    // Nothing is written down for it, and no key goes anywhere.
    try testing.expectEqual(@as(usize, 0), b.rec.persisted.items.len);
    try testing.expectEqual(@as(usize, 0), b.rec.keys.items.len);
    // A group's seen is still a group's.
    try testing.expectEqual(@as(?u64, null), b.chat.seenRunMs("web-app"));

    try testing.expectError(error.UnknownTerminal, b.act(
        \\{"act":"seen","terminal":"0x00000000000000ff"}
    , 6_000));
    // A row is one or the other; both, or a terminal that is not an id, is
    // not a request.
    try testing.expectError(error.BadRequest, b.act(
        \\{"act":"seen","group":"web-app","terminal":"0x00000000000000a1"}
    , 6_000));
    try testing.expectError(error.BadRequest, b.act(
        \\{"act":"seen","terminal":"161"}
    , 6_000));
    try testing.expectEqual(@as(?u64, 5_000), b.bus.seenOf(term));
}

test "Projects: what the host says about projects reaches the core whole, and what it asks is the core's to answer" {
    var b = try Bench.init();
    defer b.deinit();

    try b.act(
        \\{"act":"projects","list":[
        \\ {"name":"web-app","group":"web-app","pages":2,
        \\  "open":[["0x00000000000000a1"],["0x00000000000000b1"]],"supervisor":"0x00000000000000a1","workers":[]},
        \\ {"name":"notes","group":null,"pages":1,"open":null,"supervisor":null,"workers":[]}]}
    , 1_000);
    try testing.expectEqual(@as(?usize, 2), b.rec.stated);
    try testing.expectEqual(@as(usize, 1), b.rec.stated_open);
    // No projects is a statement too.
    try b.act(
        \\{"act":"projects","list":[]}
    , 1_000);
    try testing.expectEqual(@as(?usize, 0), b.rec.stated);

    // One that does not read whole changes nothing: the last one stands.
    b.rec.stated = 99;
    for ([_][]const u8{
        \\{"act":"projects"}
        ,
        \\{"act":"projects","list":{}}
        ,
        \\{"act":"projects","list":[{"name":"a"}]}
        ,
    }) |bad| try testing.expectError(error.BadRequest, b.act(bad, 1_000));
    try testing.expectEqual(@as(?usize, 99), b.rec.stated);

    try b.act(
        \\{"act":"project_failed","name":"web-app","why":"not_found"}
    , 1_000);
    try testing.expectEqual(@as(?ProjectFailure, .not_found), b.rec.project_failed);
    try testing.expectError(error.BadRequest, b.act(
        \\{"act":"project_failed","name":"web-app","why":"busy"}
    , 1_000));

    try b.act(
        \\{"act":"project_remove","terminal":"0x00000000000000b1"}
    , 1_000);
    try testing.expectEqual(@as(?Id, 0xb1), b.rec.asked_remove);
    // The core's refusal is the answer, by its own name.
    b.rec.refuse_with = error.SupervisorPage;
    try testing.expectError(error.SupervisorPage, b.act(
        \\{"act":"project_remove","terminal":"0x00000000000000a1"}
    , 1_000));
    b.rec.refuse_with = error.GroupExists;
    try testing.expectError(error.GroupExists, b.act(
        \\{"act":"project_rename","from":"web-app","to":"billing"}
    , 1_000));
    b.rec.refuse_with = null;
    try b.act(
        \\{"act":"project_rename","from":"notes","to":"scratch"}
    , 1_000);
    try testing.expectEqual(@as(usize, 1), b.rec.renames);
    try testing.expectError(error.BadRequest, b.act(
        \\{"act":"project_rename","from":"notes"}
    , 1_000));
}

// What a host says about projects, as the Windows host writes it: the lines
// of this file are the bytes `polter-projects` (windows/projects/src/stated.rs)
// produces, held to them by its own test, and this is the core taking each.
// A key the host stopped writing, or one the core started asking for, turns
// one of the two red.
test "Projects: the core takes what the Windows host writes, line for line" {
    var b = try Bench.init();
    defer b.deinit();

    var lines = std.mem.tokenizeScalar(u8, @embedFile("testdata/host_project_acts.jsonl"), '\n');
    // Two projects, one of them open.
    try b.act(lines.next().?, 1_000);
    try testing.expectEqual(@as(?usize, 2), b.rec.stated);
    try testing.expectEqual(@as(usize, 1), b.rec.stated_open);
    // None.
    try b.act(lines.next().?, 1_000);
    try testing.expectEqual(@as(?usize, 0), b.rec.stated);
    try b.act(lines.next().?, 1_000);
    try testing.expectEqual(@as(?ProjectFailure, .not_found), b.rec.project_failed);
    try b.act(lines.next().?, 1_000);
    try testing.expectEqual(@as(?ProjectFailure, .unreadable), b.rec.project_failed);
    try b.act(lines.next().?, 1_000);
    try testing.expectEqual(@as(?Id, 0xb2), b.rec.asked_remove);
    try b.act(lines.next().?, 1_000);
    try testing.expectEqual(@as(usize, 1), b.rec.renames);
    try testing.expectEqual(@as(?[]const u8, null), lines.next());
}

test "agreeing to the first sweep reaches the host" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const act = try parse(arena.allocator(), "{\"act\":\"retention_agree\"}");
    try testing.expect(act == .retention_agree);
}

test "ControlRoom act: Fix types the paragraph into the supervisor, keeps it in the group, and marks the card" {
    var b = try Bench.init();
    defer b.deinit();
    const failing = [_]ControlFix.Failing{.{ .id = 0xb1, .title = "api", .what = "server_error", .since_ms = 5, .at_wall_ms = 5 }};
    b.rec.fix_card = .{ .key = .{ .group = "web-app" }, .steward = term, .failing = &failing, .state = .offered };

    try b.act(
        \\{"act":"fix","group":"web-app"}
    , 1_000);
    try testing.expectEqual(@as(usize, 1), b.rec.fix_posts.items.len);
    try testing.expect(std.mem.startsWith(u8, b.rec.fix_posts.items[0], "[Polter fix] Terminal api (0x00000000000000b1) failed: server_error, 12:00. "));
    try testing.expectEqual(@as(usize, 1), b.rec.fix_typed);
    try testing.expectEqual(@as(?u64, ControlFix.stampOf(term, &failing)), b.rec.fix_marked);
}

test "ControlRoom act: Fix on a card that is not failing, or was fixed and has not changed, does nothing" {
    var b = try Bench.init();
    defer b.deinit();
    try testing.expectError(error.NothingToFix, b.act(
        \\{"act":"fix","group":"web-app"}
    , 1_000));
    const failing = [_]ControlFix.Failing{.{ .id = term, .title = "", .what = "", .since_ms = 5, .at_wall_ms = 5 }};
    b.rec.fix_card = .{ .key = .{ .group = "web-app" }, .steward = term, .failing = &failing, .state = .sent };
    try testing.expectError(error.AlreadyNotified, b.act(
        \\{"act":"fix","group":"web-app"}
    , 1_000));
    try testing.expectEqual(@as(usize, 0), b.rec.fix_posts.items.len);
    try testing.expectEqual(@as(?u64, null), b.rec.fix_marked);
    // Both or neither is not a request.
    try testing.expectError(error.BadRequest, b.act(
        \\{"act":"fix","group":"web-app","terminal":"0x00000000000000a1"}
    , 1_000));
}

test "ControlRoom act: a Fix that could not be typed is refused by the mention's name, kept, and not marked" {
    var b = try Bench.init();
    defer b.deinit();
    const failing = [_]ControlFix.Failing{.{ .id = term, .title = "", .what = "", .since_ms = 5, .at_wall_ms = 5 }};
    b.rec.fix_card = .{ .key = .{ .group = "web-app" }, .steward = term, .failing = &failing, .state = .offered };

    b.rec.refuse_with = error.DraftInLine;
    try testing.expectError(error.DraftInLine, b.act(
        \\{"act":"fix","group":"web-app"}
    , 1_000));
    try testing.expectEqual(@as(usize, 1), b.rec.fix_posts.items.len);
    try testing.expectEqual(@as(?u64, null), b.rec.fix_marked);

    b.rec.refuse_with = null;
    b.rec.agent_gone = true;
    try testing.expectError(error.NoAgent, b.act(
        \\{"act":"fix","group":"web-app"}
    , 1_000));
    try testing.expectEqual(@as(usize, 0), b.rec.fix_typed);
    try testing.expectEqual(@as(?u64, null), b.rec.fix_marked);

    // A terminal in no group: typed into it, nothing kept.
    b.rec.agent_gone = false;
    b.rec.fix_card = .{ .key = .{ .terminal = term }, .steward = null, .failing = &failing, .state = .offered };
    try b.act(
        \\{"act":"fix","terminal":"0x00000000000000a1"}
    , 1_000);
    try testing.expectEqual(@as(usize, 2), b.rec.fix_posts.items.len);
    try testing.expectEqual(@as(usize, 1), b.rec.fix_typed);
    try testing.expect(b.rec.fix_marked != null);
}

// -- the group row's right-click menu (task 1659) ----------------------------

test "ControlRoom act: pin, mute and archive are the person's marks, written down each time (task 1659)" {
    var b = try Bench.init();
    defer b.deinit();

    try b.act(
        \\{"act":"pin","group":"web-app"}
    , 1_000);
    try testing.expect((try b.chat.marksOf("web-app")).pinned);
    try b.act(
        \\{"act":"unpin","group":"web-app"}
    , 1_000);
    try testing.expect(!(try b.chat.marksOf("web-app")).pinned);

    // An hour from now, on the wall clock.
    try b.act(
        \\{"act":"mute","group":"web-app","until_ms":1700003601000}
    , 1_000);
    try testing.expectEqual(Chat.Marks.Mute{ .until = 1_700_003_601_000 }, (try b.chat.marksOf("web-app")).mute);
    try b.act(
        \\{"act":"mute","group":"web-app"}
    , 1_000);
    try testing.expectEqual(Chat.Marks.Mute.forever, (try b.chat.marksOf("web-app")).mute);
    try b.act(
        \\{"act":"unmute","group":"web-app"}
    , 1_000);
    try testing.expectEqual(Chat.Marks.Mute.none, (try b.chat.marksOf("web-app")).mute);

    try b.act(
        \\{"act":"archive","group":"web-app"}
    , 1_000);
    try testing.expectEqual(@as(?u64, wall + 1_000), (try b.chat.marksOf("web-app")).archived_ms);
    // Again: when it was archived does not move.
    try b.act(
        \\{"act":"archive","group":"web-app"}
    , 5_000);
    try testing.expectEqual(@as(?u64, wall + 1_000), (try b.chat.marksOf("web-app")).archived_ms);
    try b.act(
        \\{"act":"unarchive","group":"web-app"}
    , 6_000);
    try testing.expectEqual(@as(?u64, null), (try b.chat.marksOf("web-app")).archived_ms);

    // Every one of them written down, the last as it stands.
    try testing.expectEqual(@as(usize, 8), b.rec.persisted.items.len);
    try testing.expectEqual(Chat.Marks.none, b.rec.persisted.items[7]);
}

test "ControlRoom act: a mute that would already be over, or a group that is not there, is refused (task 1659)" {
    var b = try Bench.init();
    defer b.deinit();
    try testing.expectError(error.MuteInThePast, b.act(
        \\{"act":"mute","group":"web-app","until_ms":1700000001000}
    , 1_000));
    for ([_][]const u8{
        "{\"act\":\"pin\",\"group\":\"nope\"}",
        "{\"act\":\"unpin\",\"group\":\"nope\"}",
        "{\"act\":\"mute\",\"group\":\"nope\"}",
        "{\"act\":\"unmute\",\"group\":\"nope\"}",
        "{\"act\":\"archive\",\"group\":\"nope\"}",
        "{\"act\":\"unarchive\",\"group\":\"nope\"}",
        "{\"act\":\"set_brief\",\"group\":\"nope\",\"brief\":\"x\"}",
        "{\"act\":\"rename_group\",\"from\":\"nope\",\"to\":\"other\"}",
        "{\"act\":\"delete_group\",\"group\":\"nope\",\"members\":0,\"open_tasks\":0}",
        "{\"act\":\"ask_supervisor\",\"group\":\"nope\",\"ask\":\"report\"}",
    }) |json| try testing.expectError(error.NoSuchGroup, b.act(json, 1_000));
    try testing.expectEqual(@as(usize, 0), b.rec.persisted.items.len);
    // An ask that is neither is not a request.
    try testing.expectError(error.BadRequest, b.act(
        \\{"act":"ask_supervisor","group":"web-app","ask":"dance"}
    , 1_000));
}

test "ControlRoom act: rename says which of the three sentences, and nothing reaches the host for them (task 1659)" {
    var b = try Bench.init();
    defer b.deinit();
    try b.chat.create("billing", term);
    try testing.expectError(error.EmptyName, b.act(
        \\{"act":"rename_group","from":"web-app","to":""}
    , 1_000));
    try testing.expectError(error.BadName, b.act(
        \\{"act":"rename_group","from":"web-app","to":"Web App"}
    , 1_000));
    try testing.expectError(error.GroupExists, b.act(
        \\{"act":"rename_group","from":"web-app","to":"billing"}
    , 1_000));
    // To its own name: done, and nothing to do.
    try b.act(
        \\{"act":"rename_group","from":"web-app","to":"web-app"}
    , 1_000);
    try testing.expect(b.rec.renamed == null);

    try b.act(
        \\{"act":"rename_group","from":"web-app","to":"storefront"}
    , 1_000);
    try testing.expectEqualStrings("storefront", b.rec.renamed.?);

    // A rename's own refusal keeps its name; anything else is "failed".
    b.rec.refuse_with = error.RenameBlocked;
    try testing.expectError(error.RenameBlocked, b.act(
        \\{"act":"rename_group","from":"web-app","to":"shop"}
    , 1_000));
    b.rec.refuse_with = error.AccessDenied;
    try testing.expectError(error.RenameFailed, b.act(
        \\{"act":"rename_group","from":"web-app","to":"shop"}
    , 1_000));
}

test "ControlRoom act: the brief goes to the host as written (task 1659)" {
    var b = try Bench.init();
    defer b.deinit();
    try b.act(
        \\{"act":"set_brief","group":"web-app","brief":"the storefront rewrite"}
    , 1_000);
    try testing.expectEqualStrings("the storefront rewrite", b.rec.brief.?);
}

test "ControlRoom act: delete happens only for what the dialog said (task 1659)" {
    var b = try Bench.init();
    defer b.deinit();
    // `term` made the group and is in it; two tasks nobody has finished.
    b.rec.open_tasks = 2;
    try testing.expectError(error.Stale, b.act(
        \\{"act":"delete_group","group":"web-app","members":0,"open_tasks":2}
    , 1_000));
    try testing.expectError(error.Stale, b.act(
        \\{"act":"delete_group","group":"web-app","members":1,"open_tasks":1}
    , 1_000));
    try testing.expect(b.rec.deleted == null);
    try b.act(
        \\{"act":"delete_group","group":"web-app","members":1,"open_tasks":2}
    , 1_000);
    try testing.expectEqualStrings("web-app", b.rec.deleted.?);
}

test "ControlRoom act: asking the supervisor types the tagged line into it, and says when it was not typed (task 1659)" {
    var b = try Bench.init();
    defer b.deinit();
    try testing.expectError(error.NoSupervisor, b.act(
        \\{"act":"ask_supervisor","group":"web-app","ask":"report"}
    , 1_000));
    try testing.expectEqual(@as(usize, 0), b.rec.fix_posts.items.len);

    b.rec.steward = term;
    try b.act(
        \\{"act":"ask_supervisor","group":"web-app","ask":"report"}
    , 1_000);
    try b.act(
        \\{"act":"ask_supervisor","group":"web-app","ask":"close_idle"}
    , 1_000);
    try testing.expectEqual(@as(usize, 2), b.rec.fix_posts.items.len);
    try testing.expect(std.mem.startsWith(u8, b.rec.fix_posts.items[0], ask_tag ++ " The person asked from the control room: please report"));
    try testing.expect(std.mem.indexOf(u8, b.rec.fix_posts.items[1], "close the workers in this group that are idle") != null);

    // Kept in the group, and not typed: the mention's own refusal, by name.
    b.rec.refuse_with = error.DraftInLine;
    try testing.expectError(error.DraftInLine, b.act(
        \\{"act":"ask_supervisor","group":"web-app","ask":"report"}
    , 1_000));
}
