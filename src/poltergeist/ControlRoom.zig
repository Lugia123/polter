//! The control room's snapshot: everything it shows, worked out in one
//! place, and the bookkeeping that says when it changed.
//!
//! **Everything in a snapshot is already decided.** The order of the rows,
//! which need the person, the number in "N waiting", the glyph on each tab,
//! the words beside it, how many minutes -- a host draws what it is given.
//! A host that compares a `kind` or counts rows is a defect
//! (dev-docs/poltergeist/control-room.md, 5.4).
//!
//! ## The JSON
//!
//! `write` gives one object. `testdata/control_snapshot.json` is a whole
//! one, built by the test at the bottom of this file, and is what a host
//! can start from.
//!
//! ```
//! { "rev": 3,                 changes exactly when anything below, other
//!                             than the two ages, changes
//!   "now_ms": 6000000,        the clock every *_ms below is on, except
//!                             last_ms / seen_ms / snooze, which are wall
//!   "needs_me": 4,            rows that wait and are drawn: the groups'.
//!                             The same number as groups_needing_me, since
//!                             no host draws a row for a terminal in no
//!                             group (below). The Dock's number
//!   "groups_needing_me": 4,   rows in `groups` with needs_me, in a row
//!                             from the top. The list's header
//!   "groups_other": 3,        the rest of `groups`
//!   "header_waiting": {"count": 4, "of": "groups", "number": "other",
//!                      "groups": 4, "alone": 0},
//!   "header_quiet":   {"count": 3, "of": "groups", "number": "other",
//!                      "groups": 3, "alone": 0},
//!                             what the list's two headings say. **The
//!                             terminals in no group are in neither**: the
//!                             control room does not show them (the user,
//!                             2026-10-13 -- their rows read as groups
//!                             nobody had made), so `alone` is 0 and `of`
//!                             is groups until a host draws them again.
//!                             `ungrouped` still lists them, each with its
//!                             own needs_me; they are in no count.
//!                             count: the rows under that heading
//!                             -- for header_waiting the same number as
//!                             needs_me. of: groups (every one of them is a
//!                             group: "N groups …") | rows (a lone terminal
//!                             is among them: "N waiting …", no word for
//!                             what they are). number: none | one | other,
//!                             so that "1 group" and "3 groups" are the
//!                             host's two sentences and not its arithmetic.
//!                             groups / alone: the two that count is the
//!                             sum of, for a host that says them apart.
//!                             A host that draws only the groups' rows goes
//!                             by groups_needing_me / groups_other instead,
//!                             and is as true to what it draws
//!   "open_on": "web-app" | null,
//!                             the group a control room that opens with
//!                             nothing selected selects: the first row
//!                             with an agent in it, or the first row when
//!                             none has one. Null with no groups
//!   "groups": [ {             already in the order to draw them
//!       "name": "web-app", "brief": "", "last_ms": 0,
//!       "seen_ms": null,
//!       "snooze": {"until":"none","at_ms":null,"until_ms":null},
//!                             until: none | next_event | time
//!       "steward": "0x00000000000000a1" | null,
//!       "supervisor": {
//!         "state": "present",     present | absent | starting | failed.
//!                                 starting and failed are a supervisor
//!                                 the person asked for from the control
//!                                 room (ControlAct.zig, start_supervisor)
//!         "can_start": false,     whether the control room offers to
//!                                 start one: there is none, none is on
//!                                 its way, and there is a role to start
//!                                 it in. A host shows the button on this
//!                                 and on nothing else
//!         "terminal": "0x…"|null, the terminal one is being started in
//!         "asking": false,        starting, and the CLI in its tab is
//!                                 waiting for the person to answer a
//!                                 question there (Antigravity's folder
//!                                 trust box). The wait does not run out
//!                                 while it is up, and Polter never
//!                                 answers it: a host says so and offers
//!                                 to go to that tab
//!         "failed": "none",       none | terminal_never_opened |
//!                                 project_never_opened |
//!                                 agent_never_connected | terminal_closed |
//!                                 cli_not_found | cli_did_not_start
//!                                 the last two are `+launch` saying so
//!                                 itself, at once: its CLI is not there
//!                                 to run, or something else stopped it
//!                                 before the CLI ran
//!         "role": "polter-supervisor" | null,
//!                                 the role it is started in unless the
//!                                 person picks another; null with no
//!                                 supervisor role at all. The role the
//!                                 group's last supervisor wore when that
//!                                 is still one to start in, else the first
//!         "cli": "claude-code" | null,
//!                                 the agent CLI that role is started in:
//!                                 the last supervisor's when the role is
//!                                 set up for it, else the role's first
//!         "cli_label": "Claude Code" | null,
//!                                 what that CLI is called to a person: its
//!                                 adapter's own `agent_cli.label`. Null
//!                                 when there is no CLI, or no name for it
//!                                 is known -- no adapter by that key, one
//!                                 that gives none, or none read yet -- and
//!                                 a host then writes the key
//!         "cwd": "/Users/me/work",
//!         "cwd_from": "last_supervisor",
//!                                 where it is started unless the person
//!                                 picks elsewhere, and how that was
//!                                 arrived at: last_supervisor (where this
//!                                 group's supervisor last worked, kept
//!                                 across restarts) | session_snapshot (no
//!                                 supervisor's directory was ever kept for
//!                                 this group; this is where the one in the
//!                                 last run's session snapshot stood -- a
//!                                 guess about an old group, and said to be
//!                                 one) | members (what most of its
//!                                 terminals are in) | home | none
//!         "last": { "role": "polter-supervisor" | null,
//!                   "cli": "claude-code" | null,
//!                   "cli_label": "Claude Code" | null,
//!                   "heard_ms": 1700000000000 | null },
//!                                 what is written down of the supervisor
//!                                 this group last had (`Chat.LastSupervisor`).
//!                                 Each is null when nobody wrote it down;
//!                                 heard_ms (the real clock) is null when
//!                                 no supervisor was ever recorded at all
//!         "resume": { "can": true, "why": "none" },
//!                                 whether starting one now goes on with
//!                                 the last one's session, for `role` and
//!                                 `cli` above. A host offers "go on with
//!                                 the last session" on `can` and on nothing
//!                                 else, and says `why` when it cannot:
//!                                 none (it can) | no_record (no supervisor
//!                                 was ever recorded) | no_session (there
//!                                 was one; its CLI never said which
//!                                 session it was in) | last_try_failed (a
//!                                 start that went on with it made no
//!                                 supervisor) | cli_differs (it would be
//!                                 started in another CLI than that
//!                                 session's) | clis_unread (what the CLIs
//!                                 can do has not been read yet -- it will
//!                                 be, and this changes by itself) |
//!                                 cli_cannot_resume (that CLI's adapter
//!                                 does not say it can go on with a
//!                                 session) | session_in_use (an open
//!                                 terminal is in that session now)
//!         "clis_read": true,
//!                                 whether the agent CLIs' adapters have
//!                                 been read (task 1741). Until they are,
//!                                 a CLI's name is not known -- `cli_label`
//!                                 is null -- and whether a session can be
//!                                 gone on with is `clis_unread`; a host
//!                                 says it is looking rather than write a
//!                                 key in place of a name
//!         "hookless": { "state": "none", "cli_label": null, "session": false,
//!                       "note": null | {"key":"started_by_hand","template":"…","args":[]},
//!                       "take_over": { "state": "none", "confirm": null, "status": null } } },
//!                                 whether the supervisor that is there was
//!                                 started by hand -- no hooks, no role
//!                                 launch -- so that nothing of its state
//!                                 reaches the control room (task 1635):
//!                                 none (it was not, or there is none) |
//!                                 asking (it was; its adapter is being
//!                                 asked who it is) | known (its adapter
//!                                 said; cli_label names the CLI and
//!                                 session says whether its session was
//!                                 found) | unknown (no adapter recognised
//!                                 it). A host says so on the supervisor
//!                                 frame's title bar for asking, known and
//!                                 unknown. take_over is "Let the control room
//!                                 take over?" on that bar (TakeOver.zig):
//!                                 state none (not offered) | offer (a host
//!                                 shows the button) | running | failed
//!                                 (stopped; offered again). confirm is the
//!                                 question a host asks before sending
//!                                 take_over, with Take Over as its yes;
//!                                 status what is happening or why the last
//!                                 try stopped. Both are Says, like note
//!       "project": {
//!         "tie": "bound",         bound | undecided | declined. Whether
//!                                 this group has a project (`Projects.zig`):
//!                                 undecided is nobody having said -- every
//!                                 group from before there were ties --
//!                                 declined is its supervisor saying none
//!         "name": "web-app" | null,
//!                                 the project, by the name the host has
//!                                 it under; null unless bound
//!         "pages": 3 | null,      how many pages it has. Null unless
//!                                 bound, **and null when the host has not
//!                                 said**: not known is not zero
//!         "open": true | null,    whether it is open now; null likewise
//!         "start": "project",     project | directory. What starting a
//!                                 supervisor for this group does: opens
//!                                 its project (all its pages; the
//!                                 supervisor is started in its own pane),
//!                                 or opens one tab in `supervisor.cwd`.
//!                                 A host words its button on this
//!         "why": "none",          why the tie is as it is, in one word
//!                                 (`Projects.Why`): none | projects_unknown
//!                                 | not_taken_up | declined | pending |
//!                                 no_supervisor | other_supervisor |
//!                                 supervisor_of_several |
//!                                 supervisor_has_project |
//!                                 project_has_group | project_name_taken |
//!                                 several_projects
//!         "ask": false },         put the question "join the project of
//!                                 the group's name?" to the person now
//!                                 (task 1713, `askFor`): only for
//!                                 project_name_taken, undecided, and not
//!                                 after "Not Now" this run or twice ever
//!       "attention": {
//!         "kind": "needs_approval",     Attention.Kind
//!         "under": "needs_approval",    what it is when not snoozed
//!         "since_ms": 5760000,
//!         "source": "hook",             Attention.Source
//!         "age_ms": 240000 | null,      not compared
//!         "terminal": "0x…" | null,     whose state this is
//!         "worker": "0x…" | null,       set when it bubbled up from one
//!         "event_ms": 5760000 | null }, when that terminal's agent was
//!                                       last heard from; with since_ms,
//!                                       what an act on this row hands
//!                                       back (ControlAct.zig)
//!       "needs_me": true, "unseen": false,
//!                             unseen: looking at the row changes it -- it
//!                             stopped and has not been looked at, or its
//!                             supervisor raised it (`notify_user`) and the
//!                             person has not looked since. What a host
//!                             starts its "seen" clock on; a row can be
//!                             both needs_me and unseen
//!       "shown": "needs_you",   needs_you | trouble | done_unseen |
//!                               working | none
//!       "word": "needs_approval", "text": "Awaiting approval",
//!       "waiter": {"is":"supervisor","name":""},
//!                             who the row is about. is: none | supervisor
//!                             | worker_via_supervisor | worker | terminal.
//!                             `name` is the worker's when it is one
//!       "reason": {"from":"hook_note","text":"rm -rf dist/ && npm ci",
//!                  "missing":null, "say":null},
//!                             from: hook_note | hook_detail | process |
//!                             clocks | hooks | last_turn | task | raised |
//!                             none. `raised` is the supervisor's own
//!                             sentence from `notify_user`.
//!                             When the line could not be had, text is
//!                             empty and `missing` says which kind of
//!                             missing: empty_note | empty_detail |
//!                             no_turn_kept | self_report_text.
//!                             say: as in `what`
//!       "what": {"form":"command",
//!                "lines":["rm -rf dist/","&& npm ci"],
//!                "cut":"none", "say":null},
//!                             the same thing in the pieces it is drawn
//!                             in. form: none | command | code | words. A
//!                             command is one step to a line; a host shows
//!                             as many lines as it has room for.
//!                             cut says whether lines is all of it: none |
//!                             tail (the start of something longer: a
//!                             summary, the whole not sent) | head (the end
//!                             of something longer: the last paragraph of
//!                             a turn). A host marks where the rest is and
//!                             never shows a part as the whole.
//!                             say: null, or when lines is one of the
//!                             core's own sentences (`Say`, task 1525)
//!                             {"key":"still","template":"Screen still for
//!                             {1} min","args":["4"]} -- lines then holds
//!                             it in English, and a host draws the
//!                             template translated, {N} filled from args,
//!                             in its place. key: process_exited |
//!                             hooks_missing | failed | still |
//!                             still_and_silent
//!       "more": 1,            other terminals in the group also waiting
//!       "same_as": "billing" | null,
//!                             same supervisor as that group's row, which
//!                             is the one that carries the reason
//!       "members": [ { "id":"0x…", "role":"steward"|"worker",
//!           "title":"…", "kind":…, "since_ms":…, "source":…,
//!           "age_ms":…, "shown":…, "word":…, "text":…,
//!           "screen":"unmeasured"|"unreadable"|"measured",
//!           "alive":true, "duty":"on"|"off",
//!           "held":false, "shielded":false } ] } ],
//!                             (a row of `ungrouped` is marked seen by its
//!                             terminal: {"act":"seen","terminal":"0x…"})
//!   "ungrouped": [ { "id", "title", "attention", "needs_me", "unseen",
//!       "shown", "word", "text", "waiter", "reason", "what" } ],
//!   "terminals": [ { the member fields but `role`, and "event_ms",
//!       "who":{"is":"agent","role":"dev-worker","cli":"claude-code",
//!              "session":"…","worker_of":"0x…"|null},
//!                             who is working in it (`WhoOut`). is:
//!                             agent | none (nobody: no agent, and the
//!                             shell is at its prompt) | unknown (the core
//!                             cannot tell -- not "nobody"). role, cli and
//!                             session are the words a group's record and
//!                             a project's pane use; for an agent, "" is
//!                             that part not known, and for the other two
//!                             all three are null. worker_of is the
//!                             supervisor this one was opened for as a
//!                             worker, in this run, whoever is in it now
//!       "window":"0x…"|null, "tab":"0x…"|null,
//!       "pane":"supervisor"|"worker"|"plain",
//!       "bar":{"shown":"held","text":"Held"} } ],
//!                             `pane` is which of the three frames this
//!                             terminal's pane wears in its own tab: the
//!                             terminal minding others, one being minded,
//!                             or neither. A host draws the frame it is
//!                             told and asks no role.
//!                             `bar` is what the right end of that
//!                             frame's title draws: the glyph and the
//!                             words. `shown` is one of the five above or
//!                             `held`, which is only ever here. A host
//!                             draws this pair in a pane's title and never
//!                             makes one of `shown`, `text` and `held`.
//!                             Rows and window tabs still draw `shown`
//!   "tabs": [ { "window":"0x…"|null, "tab":"0x…",
//!       "shown":…, "terminal":"0x…"|null } ],
//!   "projects_known": false,  whether the host has stated what projects
//!                             there are (ControlAct.zig, `projects`).
//!                             Until it has, no group is tied or untied
//!                             and the only order is `open`
//!   "project_orders": [ {"order":"create","project":"web-app",
//!       "group":"web-app","to":null,"terminal":"0x…"} ],
//!                             what the host is to do for its half of the
//!                             ties to match (`Projects.Order`): open |
//!                             create | bind | set_group | rename |
//!                             add_tab. Worked out afresh each time: an
//!                             order is there until the host has done it
//!                             and stated the result, and gone when it has.
//!                             Carrying one out twice changes nothing
//!   "supervisor_roles": [ {"key":"polter-supervisor",
//!       "name":"Polter Supervisor",
//!       "clis":[{"key":"claude-code","label":"Claude Code"|null}]} ],
//!                             the roles a supervisor can be started in,
//!                             in the order to offer them. `clis` are the
//!                             ones it can be started in here: set up in
//!                             the role, plugin on (task 1677), in the
//!                             role's order; all it is set up for while the
//!                             adapters have not been read. May be empty --
//!                             the start is then refused, with the reason.
//!                             More than one is the "Agent CLI" row.
//!       "held_back":[{"key":"other-cli","label":…|null,
//!         "why":"plugin_off"|"cannot_run"|"no_plugin"|"not_installed"}]
//!                             set up in the role and not in `clis`, and
//!                             why: a switch in Plugins, an adapter nothing
//!                             here can run, no plugin at all, or its
//!                             adapter says the program is not on this
//!                             machine (task 1744)
//!   "choose_supervisor_role": false,
//!                             whether there is a choice to offer: more
//!                             than one. A host does not count them
//!   "pulses": [ { "terminal":"0x…", "window":"0x…"|null,
//!       "tab":"0x…"|null, "group":"billing"|null } ],
//!                             every terminal waiting for the person,
//!                             longest first. The one glyph that breathes
//!                             in a window is the first of these not in
//!                             the tab that window is showing (and, for a
//!                             glyph in a tab bar or a pane, in that
//!                             window). `group` is the row that is about
//!                             it. A host tests equality and nothing else.
//!   "quota": { … }            how much of each account's allowance is
//!                             used: the block at the bottom of the list.
//!                             `quota.zig` has the shape. Its moments are
//!                             wall clock
//!   "retention_waiting_bytes": N|null
//!                             the first sweep of old records is waiting
//!                             for the person to agree, and would delete
//!                             this much; null when nothing is waiting.
//!                             Shown once, as a notice with "OK"
//!                             (`{"act":"retention_agree"}`) (task 1511) }
//! ```
//!
//! **Nothing here says how long anything has waited**, and nothing draws
//! the day's waiting: both were on screen once and told the person nothing
//! they could act on (the user, 2026-10-13). The order of the rows is still
//! longest-waiting first; that is this file's business and not a number.
//!
//! `since_ms` is when the state began and does not move when the agent
//! says the same thing again; `event_ms` moves on every word from it.
//!
//! Ids are strings, `0x` and sixteen hex digits, the way every other export
//! writes a terminal: they use all 64 bits and a JSON number does not.

const ControlRoom = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Attention = @import("Attention.zig");
const i18n = @import("../os/i18n.zig");
const Bus = @import("Bus.zig");
const ControlNotify = @import("ControlNotify.zig");
const Chat = @import("Chat.zig");
const Projects = @import("Projects.zig");
const AgentEvent = @import("agent_event.zig");
const ShellSteps = @import("ShellSteps.zig");
const quota = @import("quota.zig");
const Tasks = @import("Tasks.zig");
const ControlFix = @import("ControlFix.zig");
const ControlAsk = @import("ControlAsk.zig");
const TakeOver = @import("TakeOver.zig");

pub const Id = Bus.Id;

/// The least time between two change notices: four a second.
pub const notice_gap_ms: u64 = 250;

alloc: Allocator,

/// Goes up by one each time the snapshot differs from the one before.
rev: u64,

/// The latest snapshot as JSON, and the part of it that is compared. Owned.
json: []u8,
stable: []u8,

/// The last `rev` a notice went out for, and when.
sent_rev: u64,
sent_ms: ?u64,

/// When to look again if nothing happens first, or null for never.
wake_ms: ?u64,

/// How many times the snapshot has been worked out.
recomputes: u64,

/// The groups' rows as of the last time the snapshot was worked out, in
/// what the notifications need of them (`ControlNotify.Row`), in the
/// snapshot's order. Lives in `notify_arena`; replaced on every working-out
/// and left alone when a timer finds nothing to work out.
notify_rows: []const ControlNotify.Row,
/// The same rows, in what a click on a notification needs of them
/// (`groupToShow`). Lives beside them, in `notify_arena`.
route_rows: []const RouteRow,
/// The cards that read "Failed", with who failed under each: what the
/// "Fix" button acts on (`ControlFix`). Lives beside them, in
/// `notify_arena`: what was on screen when the button was pressed.
fix_cards: []const ControlFix.Card,
notify_arena: std.heap.ArenaAllocator,

pub fn init(alloc: Allocator) ControlRoom {
    return .{
        .alloc = alloc,
        .rev = 0,
        .json = &.{},
        .stable = &.{},
        .sent_rev = 0,
        .sent_ms = null,
        .wake_ms = null,
        .recomputes = 0,
        .notify_rows = &.{},
        .route_rows = &.{},
        .fix_cards = &.{},
        .notify_arena = .init(alloc),
    };
}

pub fn deinit(self: *ControlRoom) void {
    self.notify_arena.deinit();
    self.alloc.free(self.json);
    self.alloc.free(self.stable);
    self.* = undefined;
}

pub const Cause = enum {
    /// Something happened: a hook, a report, a mark, a terminal coming or
    /// going.
    event,
    /// Only time passed.
    timer,
};

pub const Outcome = struct {
    /// Tell the host now, with this `rev`.
    notify: ?u64,
    /// Call again with `.timer` at this time, on the bus's clock, if
    /// nothing has happened by then. Null: nothing will change on its own,
    /// and nothing should wake to check.
    wake_ms: ?u64,
};

/// Bring the snapshot up to date.
///
/// On `.timer` before `wake_ms`, nothing is worked out at all: time passing
/// short of a threshold changes nothing that is compared.
pub fn refresh(self: *ControlRoom, in: Input, cause: Cause) Allocator.Error!Outcome {
    if (cause == .timer) {
        const due = self.wake_ms orelse return .{ .notify = null, .wake_ms = null };
        if (in.now_ms < due) return .{ .notify = null, .wake_ms = due };
    }

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();

    var built = try self.compute(arena.allocator(), in);

    _ = self.notify_arena.reset(.retain_capacity);
    self.notify_rows = try notifyRows(self.notify_arena.allocator(), built.snapshot.groups);
    self.route_rows = try routeRows(self.notify_arena.allocator(), built.snapshot.groups);
    self.fix_cards = try copyCards(self.notify_arena.allocator(), built.fix_cards);

    const stable = try writeAlloc(self.alloc, try stripped(arena.allocator(), built.snapshot), .{});
    if (std.mem.eql(u8, stable, self.stable)) {
        self.alloc.free(stable);
    } else {
        self.alloc.free(self.stable);
        self.stable = stable;
        self.rev += 1;
    }

    built.snapshot.rev = self.rev;
    const json = try writeAlloc(self.alloc, built.snapshot, .{});
    self.alloc.free(self.json);
    self.json = json;

    // At most one notice per gap; a change inside the gap waits for its end
    // and goes out with whatever else changed meanwhile.
    var wake = built.wake_ms;
    var notify: ?u64 = null;
    if (self.rev != self.sent_rev) {
        const open_ms = if (self.sent_ms) |at| at +| notice_gap_ms else in.now_ms;
        if (in.now_ms >= open_ms) {
            notify = self.rev;
            self.sent_rev = self.rev;
            self.sent_ms = in.now_ms;
        } else {
            wake = earlier(wake, open_ms);
        }
    }

    self.wake_ms = wake;
    return .{ .notify = notify, .wake_ms = wake };
}

/// The whole snapshot as of now. Everything in the result lives in `arena`.
fn compute(self: *ControlRoom, arena: Allocator, in: Input) Allocator.Error!Built {
    const built = try build(arena, in);
    self.recomputes += 1;
    return built;
}

fn earlier(a: ?u64, b: u64) u64 {
    return if (a) |x| @min(x, b) else b;
}

/// The groups' rows as the notifications need them. Copied into `arena`:
/// the snapshot they come from does not outlive `refresh`.
pub fn notifyRows(arena: Allocator, groups: []const GroupRow) Allocator.Error![]const ControlNotify.Row {
    const out = try arena.alloc(ControlNotify.Row, groups.len);
    for (groups, out) |g, *r| {
        // The supervisor's own wait: its member row, when it is there and
        // on duty. Off duty it waits for nobody (`Attention.ofTerminal`).
        var own: ?ControlNotify.Need = null;
        for (g.members) |m| {
            if (m.role != .steward or !m.alive or m.duty != .on) continue;
            own = .{ .kind = m.kind, .since_ms = m.since_ms, .terminal = m.id.id };
        }
        const text = if (g.reason.text.len > 0)
            g.reason.text
        else if (g.what.lines.len > 0) g.what.lines[0] else "";
        r.* = .{
            .group = try arena.dupe(u8, g.name),
            .steward = if (g.steward) |h| h.id else null,
            .top = .{
                .kind = g.attention.under,
                .since_ms = g.attention.since_ms,
                .terminal = if (g.attention.terminal) |h| h.id else null,
            },
            .snoozed = g.attention.kind == .snoozed,
            .muted = g.muted != null,
            .own = own,
            .who = try arena.dupe(u8, g.waiter.name),
            .text = try arena.dupe(u8, text),
        };
    }
    return out;
}

/// A group's row in what a click on a notification needs of it: who
/// supervises it and who is in it (task 1538).
pub const RouteRow = struct {
    group: []const u8,
    steward: ?Id,
    members: []const Id,
};

pub fn routeRows(arena: Allocator, groups: []const GroupRow) Allocator.Error![]const RouteRow {
    const out = try arena.alloc(RouteRow, groups.len);
    for (groups, out) |g, *r| {
        const members = try arena.alloc(Id, g.members.len);
        for (g.members, members) |m, *id| id.* = m.id.id;
        r.* = .{
            .group = try arena.dupe(u8, g.name),
            .steward = if (g.steward) |h| h.id else null,
            .members = members,
        };
    }
    return out;
}

/// Which group a click on a notification from terminal `id` opens the
/// control room at (task 1538); null when it belongs to none, and the click
/// goes to the terminal's own tab and pane instead.
///
/// **The group it supervises first**, then the first it is in, in the
/// control room's own order: a supervisor that is also a member somewhere
/// else is called to the group it minds, and two hosts that walk the same
/// rows land on the same one.
pub fn groupToShow(rows: []const RouteRow, id: Id) ?[]const u8 {
    for (rows) |r| {
        if (r.steward == id) return r.group;
    }
    for (rows) |r| {
        if (std.mem.indexOfScalar(Id, r.members, id) != null) return r.group;
    }
    return null;
}

// -- what goes in -----------------------------------------------------------

/// A terminal on screen, as the app sees it.
pub const Terminal = struct {
    id: Id,
    title: []const u8,
    /// Null when the apprt did not say.
    window: ?u64,
    tab: ?u64,
    process: Attention.Process,
    /// An agent is connected to Polter from this terminal.
    agent_present: bool,
    /// Its shell is at its prompt, by shell integration's word: nothing
    /// is running in it. False also when there is no integration to say.
    at_prompt: bool,
    /// The key of the role it wears or was started in; empty for none.
    role: []const u8,
    /// The agent CLI a role launch started in it; empty when none did.
    /// What its hooks say of the CLI is the bus's and comes first.
    launched_cli: []const u8,
    /// This terminal's own T1, when it was given one; null for the common
    /// one.
    still_ms: ?u64,
    /// Whether its agent was started by hand, and who the adapters say it
    /// is (task 1635). No default: a caller that forgot it would say "no"
    /// for every terminal, which is the silence this exists to end.
    hookless: Hookless,
};

/// An agent talking to Polter with no hooks and no role launch behind it:
/// one a person started by typing its command (task 1635,
/// `Identities.zig`). Polter hears nothing of its state, so the control
/// room has nothing to show for it, and says why.
pub const Hookless = union(enum) {
    pub const Known = struct {
        label: []const u8,
        /// The adapter found the session it is in.
        session: bool,
        /// That session's id, for a person to recognise: its first eight
        /// characters. Empty with no session.
        session_short: []const u8,
        /// Whether that is still the session it is in (`TakeOver.sure`).
        sure: bool,
        /// Minutes since the session's record was last written; null when
        /// not known.
        written_min: ?u64,
        /// The adapter said how to make it quit and when that is safe: a
        /// take-over can be offered.
        can_quit: bool,
    };

    /// Not that: there are hooks, or a role launch started it, or there is
    /// no agent.
    no,
    /// It is; the adapters are being asked who it is.
    asking,
    /// It is, and an adapter said it is its CLI.
    known: Known,
    /// It is, and no adapter recognised it: Polter does not know what it
    /// is. Not "fine".
    unknown,
};

pub const Input = struct {
    bus: *const Bus,
    chat: *const Chat,
    /// Every terminal that is open. A group member not in here is gone.
    terminals: []const Terminal,
    thresholds: Attention.Thresholds,
    /// The task panel: what a group that is working says it is doing.
    tasks: *const Tasks,
    /// What was last read of each account's allowance (`QuotaWatch`). No
    /// default: a caller that forgot it would show "no number yet" for
    /// ever, which is also what a machine with no agent on it shows.
    quota: []const quota.Reading,
    /// How much the first sweep of old records would delete, while it waits
    /// for the person (`Sweeper.waiting`); null when it is not waiting. No
    /// default, for the reason `quota` has none.
    retention_waiting: ?u64,
    /// The roles a supervisor can be started in from the control room, in
    /// the order to offer them; the first is the one used unless the person
    /// picks. Empty when there is none, and then nothing can be started.
    supervisor_roles: []const StartRole,
    /// Which agent CLIs can go on with a session they are handed, by their
    /// adapters' own word. No default: a caller that forgot it would have
    /// every group say "not read yet" for ever.
    cli_resume: CliResume,
    /// Every agent CLI a plugin here manages, and whether it can be
    /// started (`agent_cli.survey`); null when that could not be read, and
    /// then every CLI a role is set up for is offered. No default: a caller
    /// that forgot it would offer CLIs whose plugin is off.
    cli_standings: ?[]const CliStanding,
    /// Where every group stands with a project, and what the host is to
    /// do about it. No default: a caller that forgot it would have every
    /// group read "the host has not said" for ever.
    projects: ProjectsIn,
    /// What each agent CLI is called to a person, by its adapter's own
    /// word. Empty when none has been read; a key that is not here has no
    /// name, and the snapshot says so. No default, for the reason above.
    cli_names: []const CliName,
    /// The person's home directory, where a supervisor is started when
    /// nothing says better. Empty when it is not known.
    home: []const u8,
    /// Where groups' records are, `<state>/chat`: a group's own is this and
    /// its name (`GroupRow.record_dir`). Empty when there is no record.
    record_root: []const u8,
    /// The cards the person has pressed "Fix" on, and as of which moment
    /// (`ControlFix.Sent`). No default: a caller that forgot it would offer
    /// the button again the moment it was pressed.
    fix_sent: *const ControlFix.Sent,
    /// How the control room's last ask of each group's supervisor went
    /// (task 1671). No default: a caller that forgot it would leave a line
    /// that says "will try again" under a row for ever.
    asks: *const ControlAsk,
    /// The take-over under way or last stopped (task 1635); null for none.
    /// No default: a caller that forgot it would show a take-over that is
    /// under way as one that can be started.
    take_over: ?TakeOverIn,
    /// The bus's clock, and the real one.
    now_ms: u64,
    wall_ms: u64,
};

/// What `Projects.reconcile` came to, and the table it came from.
pub const ProjectsIn = struct {
    /// What the host stated; null when it has stated nothing.
    table: ?*const Projects,
    standings: []const Projects.Standing,
    orders: []const Projects.Order,

    /// Nothing stated and nothing worked out.
    pub const unknown: ProjectsIn = .{ .table = null, .standings = &.{}, .orders = &.{} };
};

/// A role that makes the terminal it starts in a supervisor, as the
/// snapshot lists it.
pub const SupervisorRole = struct {
    key: []const u8,
    name: []const u8,
    /// The CLIs it can be started in here (`startClisOf`), each with what
    /// its adapter calls it -- null when nobody has said, and a host writes
    /// the key.
    clis: []const CliOut,
    /// The ones it is set up for that are not in `clis`, in its order, and
    /// why each is not.
    held_back: []const HeldBackOut,
};

pub const CliOut = struct {
    key: []const u8,
    label: ?[]const u8,
};

/// One agent CLI a plugin manages, and whether it can be started here.
pub const CliStanding = struct {
    key: []const u8,
    standing: Standing,

    pub const Standing = enum {
        ok,
        /// Installed, switched off: a switch in Plugins starts it.
        plugin_off,
        /// Switched on, and nothing here can run its adapter: no switch
        /// does.
        cannot_run,
        /// Switched on, its adapter runs, and its adapter says the CLI's
        /// program is not on the login shell's PATH (`"installed": false`,
        /// task 1744): installing it does. Only ever from an inventory
        /// read (`installedHere`); before one, nobody knows, and it is `ok`.
        not_installed,
    };
};

/// A CLI a role is set up for and that is not offered, and why -- three
/// reasons, because the person does three different things about them.
pub const HeldBackOut = struct {
    key: []const u8,
    label: ?[]const u8,
    why: Why,

    pub const Why = enum { plugin_off, cannot_run, no_plugin, not_installed };
};

/// Whether a start in this CLI goes on with the last session: `resumeOf`,
/// asked once per CLI so that a host whose person picks another CLI reads
/// the answer rather than works it out (task 1677).
pub const CliResumeOut = struct {
    cli: []const u8,
    can: bool,
    why: ResumeOut.Why,
};

/// The same role as it is handed in: with the CLIs it is set up for, in
/// the role's own order. Never empty -- a role with no CLI is not one a
/// supervisor can be started in.
pub const StartRole = struct {
    key: []const u8,
    name: []const u8,
    clis: []const []const u8,
};

/// Which agent CLIs can go on with a session, as far as that has been
/// read. **Not read and read-and-none are two answers**: the first is
/// about to change by itself, the second is not.
pub const CliResume = union(enum) {
    /// No adapter has been asked yet (`agent_cli.Cache`).
    unread,
    /// The keys of the CLIs whose adapter says it can.
    read: []const []const u8,
};

/// What an agent CLI is called to a person (`agent_cli.Adapter.label`).
pub const CliName = struct {
    key: []const u8,
    label: []const u8,
};

/// The name `key` goes by; null when there is no key, nobody names it, or
/// the name it was given is empty. **Never the key standing in for a
/// name**: a host that is handed null writes the key and knows it did.
pub fn cliLabelOf(names: []const CliName, key: ?[]const u8) ?[]const u8 {
    const k = key orelse return null;
    if (k.len == 0) return null;
    for (names) |n| {
        if (std.mem.eql(u8, n.key, k)) return if (n.label.len > 0) n.label else null;
    }
    return null;
}

/// The role a supervisor is started in for a group unless one is named:
/// the one its last supervisor wore when that is still a role to start
/// in, else the first. Null with no role at all.
pub fn startRoleOf(roles: []const StartRole, last: Chat.LastSupervisor) ?StartRole {
    if (last.role.len > 0) for (roles) |r| {
        if (std.mem.eql(u8, r.key, last.role)) return r;
    };
    return if (roles.len > 0) roles[0] else null;
}

/// The CLIs `role` can be started in here: the ones it is set up for
/// that stand `ok`, in its order -- or all of them while that has not been
/// read (null). In `arena` unless nothing is taken out.
pub fn startClisOf(arena: Allocator, role: StartRole, standings: ?[]const CliStanding) Allocator.Error![]const []const u8 {
    const here = standings orelse return role.clis;
    var out: std.ArrayList([]const u8) = .empty;
    for (role.clis) |c| if (standingOf(here, c) == null) try out.append(arena, c);
    return out.items;
}

/// Why `cli` is not offered, or null when it is.
pub fn standingOf(standings: []const CliStanding, cli: []const u8) ?HeldBackOut.Why {
    for (standings) |s| if (std.mem.eql(u8, s.key, cli)) return switch (s.standing) {
        .ok => null,
        .plugin_off => .plugin_off,
        .cannot_run => .cannot_run,
        .not_installed => .not_installed,
    };
    return .no_plugin;
}

/// `standings` with what an inventory read found missing (task 1744): a
/// CLI that stands `ok` and whose adapter said its program is not here
/// stands `not_installed`. `missing` null -- nothing read yet -- changes
/// nothing: not known is not "missing", and the CLI is offered as before.
/// Null standings stay null. In `arena` when anything changes.
pub fn installedHere(
    arena: Allocator,
    standings: ?[]const CliStanding,
    missing: ?[]const []const u8,
) Allocator.Error!?[]const CliStanding {
    const all = standings orelse return null;
    const gone = missing orelse return all;
    if (gone.len == 0) return all;
    const out = try arena.dupe(CliStanding, all);
    for (out) |*o| {
        if (o.standing != .ok) continue;
        for (gone) |g| if (std.mem.eql(u8, g, o.key)) {
            o.standing = .not_installed;
            break;
        };
    }
    return out;
}

/// The CLI a role is started in, of those it can be here (`startClisOf`):
/// the last supervisor's when it is one of them, else the first. Null for
/// none.
pub fn startCliOf(clis: []const []const u8, last: Chat.LastSupervisor) ?[]const u8 {
    if (last.cli.len > 0) for (clis) |c| {
        if (std.mem.eql(u8, c, last.cli)) return c;
    };
    return if (clis.len > 0) clis[0] else null;
}

/// Whether an open terminal's agent last said it is in `session`.
///
/// "Last said", not "is": an agent that has left a terminal still open
/// says nothing on the way out that Polter hears, so this can be true of
/// a session nobody is in. That errs towards a new session, which starts;
/// the other way round would start a second agent in a live one.
pub fn sessionHeld(bus: *const Bus, open: []const Id, session: []const u8) bool {
    if (session.len == 0) return false;
    for (open) |id| {
        const a = bus.agentOf(id);
        if (a.hooks != .live) continue;
        if (std.mem.eql(u8, a.session_id.get() orelse "", session)) return true;
    }
    return false;
}

/// Whether a start goes on with the last supervisor's session.
///
/// One function, asked by the snapshot and by the start itself
/// (`App.controlActStartSupervisor`), so that what the control room
/// offered and what the launch line then carries cannot be two answers.
pub fn resumeOf(q: struct {
    last: Chat.LastSupervisor,
    /// The CLI it would be started in; null when there is none.
    cli: ?[]const u8,
    cli_resume: CliResume,
    /// `sessionHeld` of the last session.
    held: bool,
    /// The last try went on with this session and made no supervisor.
    last_try_failed: bool,
}) ResumeOut {
    const why: ResumeOut.Why = why: {
        if (q.last.heard_ms == null) break :why .no_record;
        if (q.last.session.len == 0) break :why .no_session;
        if (q.last_try_failed) break :why .last_try_failed;
        const cli = q.cli orelse break :why .cli_differs;
        if (!std.mem.eql(u8, cli, q.last.cli)) break :why .cli_differs;
        switch (q.cli_resume) {
            .unread => break :why .clis_unread,
            .read => |keys| for (keys) |k| {
                if (std.mem.eql(u8, k, cli)) break;
            } else break :why .cli_cannot_resume,
        }
        if (q.held) break :why .session_in_use;
        break :why .none;
    };
    return .{ .can = why == .none, .why = why };
}

// -- what comes out ---------------------------------------------------------

/// A 64-bit id, written as `"0x%016x"`.
pub const Hex = struct {
    id: u64,

    pub fn jsonStringify(self: Hex, jw: anytype) !void {
        try jw.print("\"0x{x:0>16}\"", .{self.id});
    }

    pub fn jsonParse(alloc: Allocator, source: anytype, options: std.json.ParseOptions) !Hex {
        _ = options;
        const s = switch (try source.nextAlloc(alloc, .alloc_if_needed)) {
            .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        if (s.len != 18 or !std.mem.startsWith(u8, s, "0x")) return error.UnexpectedToken;
        return .{ .id = std.fmt.parseInt(u64, s[2..], 16) catch return error.UnexpectedToken };
    }

    fn opt(id: ?u64) ?Hex {
        return if (id) |v| .{ .id = v } else null;
    }
};

pub const AttentionOut = struct {
    kind: Attention.Kind,
    under: Attention.Kind,
    since_ms: u64,
    source: Attention.Source,
    age_ms: ?u64,
    terminal: ?Hex,
    worker: ?Hex,
    /// When that terminal's agent was last heard from. With `since_ms`,
    /// what an action on this row has to hand back (`ControlAct`).
    event_ms: ?u64,

    fn of(a: Attention, bus: *const Bus) AttentionOut {
        return .{
            .kind = a.kind,
            .under = a.under,
            .since_ms = a.since_ms,
            .source = a.source,
            .age_ms = a.age_ms,
            .event_ms = if (a.terminal) |id| bus.agentOf(id).last_event_ms else null,
            .terminal = .opt(a.terminal),
            .worker = switch (a.what) {
                .worker => |id| .{ .id = id },
                .own, .nobody => null,
            },
        };
    }
};

/// A group's mute as the snapshot says it: until a moment on the wall
/// clock, or `null` for until the person lifts it.
pub const MuteOut = struct {
    until_ms: ?u64,

    fn of(m: Chat.Marks.Mute) ?MuteOut {
        return switch (m) {
            .none => null,
            .until => |until| .{ .until_ms = until },
            .forever => .{ .until_ms = null },
        };
    }
};

/// What deleting a group takes with it: the terminals in it besides the
/// person -- taken out of it, not closed -- and its tasks nobody has closed
/// or cancelled. `delete_group` is refused unless these are what the
/// dialog showed.
pub const DeleteCost = struct {
    members: usize,
    open_tasks: usize,
};

/// An archived group, off the list (task 1659).
pub const ArchivedRow = struct {
    name: []const u8,
    brief: []const u8,
    /// When it was archived, on the wall clock.
    archived_ms: u64,
    record_dir: []const u8,
    delete_cost: DeleteCost,
};

pub const SnoozeOut = struct {
    until: enum { none, next_event, time },
    at_ms: ?u64,
    until_ms: ?u64,

    fn of(s: Chat.Marks.Snooze) SnoozeOut {
        return switch (s) {
            .none => .{ .until = .none, .at_ms = null, .until_ms = null },
            .next_event => |at| .{ .until = .next_event, .at_ms = at, .until_ms = null },
            .until => |u| .{ .until = .time, .at_ms = u.at_ms, .until_ms = u.until_ms },
        };
    }
};

/// The line that says what it is waiting on (3.2).
pub const Reason = struct {
    from: From,
    /// The line. When it is one of the core's own sentences (`say`), this
    /// is that sentence in English, filled in.
    text: []const u8,
    /// Why there is no text, when there should have been.
    missing: ?Missing,
    /// Set when `text` is a sentence of the core's own rather than one an
    /// agent or a supervisor wrote: which one, and what goes in it, for a
    /// host to say in the person's language (task 1525).
    say: ?Say = null,

    /// `raised`: what the supervisor said when it put this in front of the
    /// person (`notify_user`, `authorisation`; `Bus.raise`).
    pub const From = enum { hook_note, hook_detail, process, clocks, hooks, last_turn, task, raised, title, none };
    pub const Missing = enum { empty_note, empty_detail, no_turn_kept, self_report_text };

    pub const none: Reason = .{ .from = .none, .text = "", .missing = null };

    fn lacking(from: From, missing: Missing) Reason {
        return .{ .from = from, .text = "", .missing = missing };
    }

    /// One of the core's own sentences, filled in: in English in `text`,
    /// and as its template and arguments in `say`.
    fn saying(arena: Allocator, from: From, key: Say.Key, args: []const []const u8) Allocator.Error!Reason {
        const owned = try arena.alloc([]const u8, args.len);
        for (args, owned) |a, *o| o.* = try arena.dupe(u8, a);
        const template = Say.templateOf(key);
        return .{
            .from = from,
            .text = try Say.fill(arena, template, owned),
            .missing = null,
            .say = .{ .key = key, .template = template, .args = owned },
        };
    }
};

/// A sentence of the core's own (task 1525). **The core does not know the
/// person's language**, so it says which sentence and what goes in it, and
/// each host says it: the mac app from `Localizable.strings`, Windows from
/// `po/`. They were Chinese literals, and so Chinese in an English window.
///
/// `template` is the English msgid, with `{1}`, `{2}` where the arguments
/// go -- not `%@`: a Zig file is read as C by `xgettext`, which can mark a
/// `%` msgid `c-format` for `msgfmt --check` to reject, and a host filling
/// with `String(format:)` dies on a translation whose placeholders do not
/// match its arguments. `{N}` is filled by the same few lines on every side
/// (`fill`), and one with no argument is left as it is.
/// `tools/control-room-words-are-translated.py` checks that each template
/// is translated on both hosts.
pub const Say = struct {
    key: Key,
    template: []const u8,
    /// As they go in: numbers in decimal, an agent's own words as it wrote
    /// them. None of them is translated.
    args: []const []const u8,

    pub const Key = enum {
        process_exited,
        hooks_missing,
        failed,
        still,
        still_and_silent,
        started_by_hand,
        cli_not_recognised,
        take_over_confirm_sure,
        take_over_confirm_unsure,
        take_over_confirm_new,
        take_over_running,
        take_over_busy,
        take_over_typing,
        take_over_did_not_quit,
        take_over_did_not_start,
        take_over_cannot_start,
    };

    pub fn templateOf(key: Key) [:0]const u8 {
        return switch (key) {
            .process_exited => i18n.N_("The process exited"), // 暂定
            .hooks_missing => i18n.N_("The hooks it was set up with never came"), // 暂定
            // Error type, then what the agent said about it.
            .failed => i18n.N_("{1}: {2}"),
            .still => i18n.N_("Screen still for {1} min"), // 暂定
            .still_and_silent => i18n.N_("Screen still for {1} min, no tool call for {2} min"), // 暂定
            // A supervisor somebody started by typing its command: none of
            // its state reaches Polter (task 1635).
            .started_by_hand => i18n.N_("Started by hand: no status"),
            .cli_not_recognised => i18n.N_("Unknown CLI: no status"),
            // The question asked before a take-over (task 1635): CLI,
            // session (its first characters), minutes since it was written.
            .take_over_confirm_sure => i18n.N_("This ends the {1} running in this terminal and starts it again through Polter, with its status hooks, going on with session {2} (last written {3} min ago)."),
            .take_over_confirm_unsure => i18n.N_("This ends the {1} running in this terminal and starts it again through Polter, with its status hooks, going on with session {2}. That session was last written {3} min ago, well before its last tool call: if it was cleared since, what comes back is the conversation from before that."),
            .take_over_confirm_new => i18n.N_("This ends the {1} running in this terminal and starts it again through Polter, with its status hooks. Its session was not found, so it starts a new one."),
            .take_over_running => i18n.N_("Taking over…"),
            .take_over_busy => i18n.N_("Not taken over: it is busy. Try again when it is idle"),
            .take_over_typing => i18n.N_("Not taken over: somebody is typing in it"),
            .take_over_did_not_quit => i18n.N_("Not taken over: it did not quit"),
            .take_over_did_not_start => i18n.N_("It quit, and the one started in its place did not come"),
            .take_over_cannot_start => i18n.N_("Not taken over: there is no role or CLI to start it in"),
        };
    }

    /// `template` with `{1}`..`{9}` replaced by `args`; a placeholder with no
    /// argument is left as written.
    pub fn fill(arena: Allocator, template: []const u8, args: []const []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < template.len) {
            if (template[i] == '{' and i + 2 < template.len and template[i + 2] == '}' and
                template[i + 1] >= '1' and template[i + 1] <= '9')
            {
                const n = template[i + 1] - '1';
                if (n < args.len) {
                    try out.appendSlice(arena, args[n]);
                    i += 3;
                    continue;
                }
            }
            try out.append(arena, template[i]);
            i += 1;
        }
        return out.toOwnedSlice(arena);
    }
};

/// What a row says under its name, already in the pieces it is drawn in.
///
/// For a row that is waiting, this is what it is waiting for; for one that
/// is not, what it is doing or has just done. **`form` says what kind of
/// text it is, so that no host guesses from where it came**: a command is
/// set in the terminal's face, one step to a line; words are set as words.
/// `lines` is all of it -- nothing is cut here. How many lines are shown is
/// a host's own matter.
pub const What = struct {
    form: Form,
    lines: []const []const u8,
    /// Whether `lines` is all of it. A host must not show a part as the
    /// whole: it marks where the rest would be.
    cut: Cut,
    /// Set when `lines` is one of the core's own sentences (`Reason.say`):
    /// `lines` holds it in English, and a host draws this, said in the
    /// person's language, in its place.
    say: ?Say = null,

    pub const Cut = enum {
        /// `lines` is everything that was said.
        none,
        /// `lines` is the start of something longer, or may be: a summary
        /// that reached its limit, with the whole not sent.
        tail,
        /// `lines` is the end of something longer: the last paragraph of a
        /// turn, where a question asked in prose is.
        head,
    };

    pub const Form = enum {
        /// Nothing to say: `lines` is empty and a host draws no line.
        none,
        /// A shell command, cut into steps (`ShellSteps`): one step per
        /// line, each after the first starting with its `&&`, `|`, `;`.
        command,
        /// Something literal that is not a command to cut -- the file a
        /// tool wants to write, a command in a shell whose rules are not
        /// the ones `ShellSteps` knows. One line, set like a command.
        code,
        /// A sentence: a question, why it failed, what it is doing.
        words,
    };

    pub const none: What = .{ .form = .none, .lines = &.{}, .cut = .none };
};

/// Who is waiting: the terminal a waiting row is about, as one of the things
/// a host can say without working anything out.
///
/// **Only a row that needs the person has one.** A row about a group that is
/// working, or idle, is about a terminal too, but nobody is waiting there,
/// and `supervisor` on such a row would be one word for "the supervisor
/// waits" and "the supervisor is who this is about".
pub const Waiter = struct {
    is: Is,
    /// The worker's name when it is a worker; empty otherwise. 暂定: its
    /// terminal's title, the only name the control room is given.
    name: []const u8,

    pub const Is = enum {
        /// The row is about no terminal.
        none,
        /// The group's supervisor itself.
        supervisor,
        /// A worker of the group, whose wait has come up through its
        /// supervisor.
        worker_via_supervisor,
        /// A worker of a group that has no supervisor.
        worker,
        /// A terminal on its own, in no group.
        terminal,
    };

    pub const none: Waiter = .{ .is = .none, .name = "" };
};

pub const ScreenOut = enum { unmeasured, unreadable, measured };

pub const Member = struct {
    id: Hex,
    role: enum { steward, worker },
    title: []const u8,
    kind: Attention.Kind,
    since_ms: u64,
    source: Attention.Source,
    age_ms: ?u64,
    shown: Attention.Shown,
    word: Attention.Word,
    text: []const u8,
    screen: ScreenOut,
    alive: bool,
    duty: Bus.Duty,
    held: bool,
    shielded: bool,
};

/// Whether a group has a supervisor, and what starting one would use.
/// Everything a host needs to offer "start a supervisor" and nothing it
/// has to work out.
pub const SupervisorOut = struct {
    state: State,
    can_start: bool,
    terminal: ?Hex,
    failed: Chat.StartFailure,
    /// The CLI being started is waiting for the person to answer a question
    /// in its tab (`Chat.Start.asking`); only ever with `starting`.
    asking: bool,
    role: ?[]const u8,
    cli: ?[]const u8,
    cli_label: ?[]const u8,
    cwd: []const u8,
    cwd_from: CwdFrom,
    last: LastOut,
    /// For `cli`, the one a start uses when none is picked.
    @"resume": ResumeOut,
    /// The same for every CLI any supervisor role can be started in here,
    /// in the order they first appear in `supervisor_roles`.
    resume_by_cli: []const CliResumeOut,
    /// The adapters have been read (task 1741): what the CLIs are called
    /// and which go on with a session are known. Before, a host draws a
    /// place where a CLI's name will be, and says it is looking.
    clis_read: bool,
    hookless: HooklessOut,

    pub const State = enum { present, absent, starting, failed };
    pub const CwdFrom = enum { none, last_supervisor, session_snapshot, members, home };
};

/// What is written down of the supervisor a group last had. Null is
/// "nobody wrote it down", for each on its own.
pub const LastOut = struct {
    role: ?[]const u8,
    cli: ?[]const u8,
    cli_label: ?[]const u8,
    heard_ms: ?u64,
};

/// Whether the supervisor that is there was started by hand (`Hookless`).
pub const HooklessOut = struct {
    state: State,
    /// What the adapter calls the CLI; null unless `known`.
    cli_label: ?[]const u8,
    /// Its session was found; false unless `known`.
    session: bool,
    /// What the supervisor frame's title says of it, in English with its
    /// key; null for `none`. A host says it in the person's language, as it
    /// does a row's `what.say`.
    note: ?Say,
    take_over: TakeOverOut,

    pub const State = enum { none, asking, known, unknown };
    pub const none: HooklessOut = .{ .state = .none, .cli_label = null, .session = false, .note = null, .take_over = .none };
};

/// "Let the control room take over?" on the supervisor's frame (task 1635,
/// `TakeOver.zig`).
pub const TakeOverOut = struct {
    /// none (not offered) | offer (a host shows the button) | running |
    /// failed (the last try stopped; the button is offered again).
    state: State,
    /// What the confirmation says before anything is done, in English with
    /// its key; null unless offered. A host asks it as the question of a
    /// dialog whose yes is "Take Over".
    confirm: ?Say,
    /// What is happening, or why the last try stopped; null otherwise.
    status: ?Say,

    pub const State = enum { none, offer, running, failed };
    pub const none: TakeOverOut = .{ .state = .none, .confirm = null, .status = null };
};

/// A take-over the app is carrying out, or the last that stopped.
pub const TakeOverIn = struct {
    group: []const u8,
    state: union(enum) {
        running: TakeOver.Phase,
        failed: TakeOver.Why,
    },
};

/// Whether a start goes on with the last session, and when not, why not.
pub const ResumeOut = struct {
    can: bool,
    why: Why,

    pub const Why = enum {
        none,
        no_record,
        no_session,
        last_try_failed,
        cli_differs,
        clis_unread,
        cli_cannot_resume,
        session_in_use,
    };
};

/// A group's tie to a project, and what starting its supervisor does.
pub const ProjectOut = struct {
    tie: enum { undecided, declined, bound },
    name: ?[]const u8,
    pages: ?usize,
    open: ?bool,
    start: Chat.StartBy,
    why: Projects.Why,
    /// Put the question to the person now: join the group to the project
    /// of its name that is in the way (task 1713). The host still waits
    /// until the person is there to answer it. See `askFor`.
    ask: bool,
};

/// Whether the person is to be asked to join a group to the project of its
/// name (`project-link-interface.md` §2): only while that is what is in the
/// way, only while nobody has said yes or no, and only while "Not Now" has
/// not been said in this run nor said twice ever (`Chat.projectAsk`).
pub fn askFor(why: Projects.Why, tie: Chat.ProjectTie, asked: bool) bool {
    return why == .project_name_taken and tie == .undecided and asked;
}

/// One thing the host is to do; `Projects.Order`, with the terminal as
/// the snapshot writes one.
pub const OrderOut = struct {
    order: Projects.Order.Kind,
    project: []const u8,
    group: ?[]const u8,
    to: ?[]const u8,
    terminal: ?Hex,
};

pub const GroupRow = struct {
    name: []const u8,
    brief: []const u8,
    last_ms: u64,
    seen_ms: ?u64,
    snooze: SnoozeOut,
    steward: ?Hex,
    supervisor: SupervisorOut,
    project: ProjectOut,
    attention: AttentionOut,
    needs_me: bool,
    unseen: bool,
    shown: Attention.Shown,
    word: Attention.Word,
    text: []const u8,
    waiter: Waiter,
    reason: Reason,
    what: What,
    more: usize,
    same_as: ?[]const u8,
    members: []const Member,
    /// Kept at the front of its section (task 1659): `build` sorts it there,
    /// so a host draws `groups` in the order given.
    pinned: bool,
    /// Muted, and until when; null when it is not (task 1659). A mute whose
    /// moment has passed is already null here.
    muted: ?MuteOut,
    /// What the delete dialog says it takes with it (task 1659).
    delete_cost: DeleteCost,
    /// The group's record directory, for "show in Finder"; empty when there
    /// is no record.
    record_dir: []const u8,
    /// The "Fix" button (`ControlFix`): none, offered, or pressed and
    /// standing until the card changes.
    fix: ControlFix.State,
    /// What became of the control room's last ask of its supervisor (task
    /// 1671): still being tried, typed in, or given up on, and as which
    /// message. Null when none was made since the start.
    ask: ?ControlAsk.Ask,
};

pub const LoneRow = struct {
    id: Hex,
    title: []const u8,
    attention: AttentionOut,
    needs_me: bool,
    unseen: bool,
    shown: Attention.Shown,
    word: Attention.Word,
    text: []const u8,
    waiter: Waiter,
    reason: Reason,
    what: What,
    /// As a group's row has it.
    fix: ControlFix.State,
};

/// Which of the three frames a terminal's pane wears in its own tab
/// (dev-docs/poltergeist/control-room.md, 12.6).
pub const Pane = enum {
    /// It is minding others.
    supervisor,
    /// Somebody is minding it.
    worker,
    /// Neither: a shell, or an agent nobody minds.
    plain,

    pub fn of(role: Bus.Role) Pane {
        return switch (role) {
            .supervisor => .supervisor,
            .watched => .worker,
            .none => .plain,
        };
    }
};

/// What the right end of a pane's title draws: a glyph and the words
/// beside it (the design's `06-panes`).
///
/// **It is the terminal's status, unless the terminal is held and nobody is
/// waiting on it.** A held terminal that is working, has finished unseen or
/// has nothing to say reads "held": that is why nothing will come of it.
/// One that is waiting for an approval or an answer, or is in trouble,
/// still says so -- the control room exists so that who is waiting can be
/// seen at a glance, and "held" over a prompt would hide exactly that.
/// 暂定 (the supervisor's ruling, 2026-10-13).
///
/// Only a pane's title draws this. A group's row and a window tab's glyph
/// are `shown`, which has no "held" in it.
pub const Bar = struct {
    shown: Shown,
    text: []const u8,

    /// The five a row draws, and the one only a title does.
    pub const Shown = enum { needs_you, trouble, done_unseen, working, none, held };

    pub fn of(d: Attention.Display, held: bool) Bar {
        const covered = switch (d.shown) {
            .needs_you, .trouble => false,
            .done_unseen, .working, .none => held,
        };
        if (covered) return .{ .shown = .held, .text = Attention.held_text };
        return .{
            .shown = switch (d.shown) {
                .needs_you => .needs_you,
                .trouble => .trouble,
                .done_unseen => .done_unseen,
                .working => .working,
                .none => .none,
            },
            .text = d.word.text(),
        };
    }
};

/// Who is working in a terminal, as far as the core can tell: what a host
/// writes into a project's pane (`Project.zig`, `agent`) and into nothing
/// else. `role`, `cli` and `session` are the same three words a group's
/// record keeps of its supervisor (`Chat.LastSupervisor`) and a project
/// file keeps of a pane.
///
/// **Three answers, and two of them are not the same "nobody".**
///
///   * `agent` -- one is there: connected to Polter from it, or its hooks
///     have been heard from (or are expected) and its shell is not back
///     at the prompt. Each of the three is what is known of it and an
///     empty string where nothing is: a role it never wore, a CLI that
///     never named itself, a session it never said.
///   * `none` -- nobody: no agent is connected and the shell is at its
///     prompt. An agent that was there and has left reads this way too,
///     which is what makes a pane it left one that can be used again.
///   * `unknown` -- the core cannot tell: something is running in it that
///     says nothing to Polter, or the shell has no integration to say it
///     is idle. Not "nobody". A host that saves this keeps what the file
///     already said of the pane.
///
/// For `none` and `unknown` the three are null: there is nobody for them
/// to be about.
pub const WhoOut = struct {
    /// Which of the three. Written `is`, as `waiter.is` is: a host is
    /// kept from reading anything the snapshot calls `kind`
    /// (`tools/control-room-hosts-do-not-decide.py`), because the one
    /// that was there first is the status a host must not compare.
    is: Is,
    role: ?[]const u8,
    cli: ?[]const u8,
    session: ?[]const u8,
    /// The supervisor this one was opened for as a worker in this run
    /// (`Bus.Entry.worker_of`), whoever is in it now; null when it was not.
    /// It says which panes are a supervisor's workers', so a host can keep
    /// that with the project and say it back (`Projects`, `workers`).
    ///
    /// It was `opened_by` until #1498, and that also named the panes a
    /// supervisor split off for itself: a restart made them workers.
    worker_of: ?Hex,

    pub const Is = enum { unknown, none, agent };
};

/// `WhoOut` for one open terminal, its strings copied into `arena`: what
/// the bus hands back of an agent is a copy that is gone when this returns.
pub fn whoOf(arena: Allocator, bus: *const Bus, t: Terminal) Allocator.Error!WhoOut {
    const a = bus.agentOf(t.id);
    const kind: WhoOut.Is = if (t.agent_present)
        .agent
    else if (t.at_prompt)
        // Whatever its hooks last said: the shell has the terminal back.
        .none
    else if (a.hooks != .none)
        .agent
    else
        .unknown;
    const worker_of: ?Hex = .opt(bus.workerOf(t.id));
    return switch (kind) {
        .unknown, .none => .{ .is = kind, .role = null, .cli = null, .session = null, .worker_of = worker_of },
        .agent => .{
            .is = .agent,
            .role = try arena.dupe(u8, t.role),
            .cli = try arena.dupe(u8, a.cli.get() orelse t.launched_cli),
            .session = try arena.dupe(u8, a.session_id.get() orelse ""),
            .worker_of = worker_of,
        },
    };
}

pub const TerminalOut = struct {
    id: Hex,
    title: []const u8,
    window: ?Hex,
    tab: ?Hex,
    pane: Pane,
    who: WhoOut,
    bar: Bar,
    kind: Attention.Kind,
    since_ms: u64,
    event_ms: ?u64,
    source: Attention.Source,
    age_ms: ?u64,
    shown: Attention.Shown,
    word: Attention.Word,
    text: []const u8,
    screen: ScreenOut,
    alive: bool,
    duty: Bus.Duty,
    held: bool,
    shielded: bool,
};

pub const Tab = struct {
    window: ?Hex,
    tab: Hex,
    shown: Attention.Shown,
    /// The terminal the glyph is about, when there is one.
    terminal: ?Hex,
};

/// One "waiting for you" glyph that may be the one that breathes.
pub const Pulse = struct {
    terminal: Hex,
    window: ?Hex,
    tab: ?Hex,
    /// The row in `groups` that is about this terminal, when there is one.
    group: ?[]const u8,
};

/// What one of the list's two headings says: how many rows are under it,
/// whether they are all groups, and which grammatical number that is.
///
/// **Here because a host was writing it from half the facts.** The heading
/// said "1 group waiting for you" over three rows with a 3 on the Dock: the
/// host had begun to draw lone terminals' rows and went on counting groups
/// (2026-10-13). A count a host can only get right by adding two fields
/// and comparing the sum with one is a count the core should have said.
pub const HeaderOut = struct {
    count: usize,
    of: Of,
    number: Number,
    /// The two that `count` is the sum of: the rows that are groups, and
    /// the rows that are lone terminals. For a host that wants to say them
    /// apart; `count`, `of` and `number` are for one that does not.
    groups: usize,
    alone: usize,

    pub const Of = enum { groups, rows };
    pub const Number = enum { none, one, other };

    fn over(groups: usize, alone: usize) HeaderOut {
        const count = groups + alone;
        return .{
            .count = count,
            .of = if (alone == 0) .groups else .rows,
            .number = switch (count) {
                0 => .none,
                1 => .one,
                else => .other,
            },
            .groups = groups,
            .alone = alone,
        };
    }
};

pub const Snapshot = struct {
    rev: u64,
    now_ms: u64,
    needs_me: usize,
    groups_needing_me: usize,
    groups_other: usize,
    header_waiting: HeaderOut,
    header_quiet: HeaderOut,
    /// The row a control room opening with nothing selected starts on.
    /// The first, in the order below, of the groups that have an agent in
    /// them (`hasAgent`); the first group when every one is empty; null
    /// when there are none. Here and not in a host because "first" is an
    /// order and "has an agent" is a judgement.
    open_on: ?[]const u8,
    groups: []const GroupRow,
    /// Archived groups, newest archived first: in none of the counts above
    /// and raising no notification (task 1659).
    archived: []const ArchivedRow,
    ungrouped: []const LoneRow,
    terminals: []const TerminalOut,
    tabs: []const Tab,
    projects_known: bool,
    project_orders: []const OrderOut,
    supervisor_roles: []const SupervisorRole,
    choose_supervisor_role: bool,
    /// Every "waiting for you" terminal, longest-waiting first. **The one
    /// glyph that breathes in a window is the first of these that is not
    /// in the tab that window is showing** -- and, for a glyph that stands
    /// in a tab bar or a pane, that is in that window at all. A host finds
    /// it by asking "is this the tab I am showing" and "is this my window",
    /// which are equalities; the order, which is a comparison, is here.
    pulses: []const Pulse,
    /// The allowance block at the bottom of the list (`quota.zig`).
    quota: quota.Out,
    /// See `Input.retention_waiting`.
    retention_waiting_bytes: ?u64,
};

pub fn writeAlloc(alloc: Allocator, snapshot: Snapshot, options: std.json.Stringify.Options) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, snapshot, options);
}

/// The snapshot with everything that moves on its own taken out: what two
/// snapshots are compared by. An age grows every millisecond and says
/// nothing has happened; `since_ms` is a moment and stays put.
fn stripped(arena: Allocator, s: Snapshot) Allocator.Error!Snapshot {
    var out = s;
    out.rev = 0;
    out.now_ms = 0;

    const groups = try arena.dupe(GroupRow, s.groups);
    for (groups) |*g| {
        g.attention.age_ms = null;
        const members = try arena.dupe(Member, g.members);
        for (members) |*m| m.age_ms = null;
        g.members = members;
    }
    out.groups = groups;

    const lone = try arena.dupe(LoneRow, s.ungrouped);
    for (lone) |*r| r.attention.age_ms = null;
    out.ungrouped = lone;

    const terminals = try arena.dupe(TerminalOut, s.terminals);
    for (terminals) |*t| t.age_ms = null;
    out.terminals = terminals;

    out.quota = try quota.stripped(arena, s.quota);

    return out;
}

// -- working it out ---------------------------------------------------------

const Built = struct {
    snapshot: Snapshot,
    wake_ms: ?u64,
    /// Every card that offers "Fix" or has had it pressed.
    fix_cards: []const ControlFix.Card,
};

/// The earliest of the moments offered that is still ahead.
const Wake = struct {
    now_ms: u64,
    at: ?u64,

    fn consider(self: *Wake, at: ?u64) void {
        const v = at orelse return;
        if (v <= self.now_ms) return;
        self.at = earlier(self.at, v);
    }
};

const min_ms = std.time.ms_per_min;

fn find(terminals: []const Terminal, id: Id) ?Terminal {
    for (terminals) |t| if (t.id == id) return t;
    return null;
}

fn statusOf(in: Input, id: Id, seen_ms: ?u64, wake: *Wake) Attention.Status {
    const open = find(in.terminals, id);
    // A terminal given its own idea of "still" is judged by it.
    var thresholds = in.thresholds;
    if (open) |t| if (t.still_ms) |ms| {
        thresholds.screen_still_ms = ms;
    };
    // What this terminal has put in front of the person and they have not
    // looked at since (`Bus.raise`). Said from the later of that moment and
    // the start of the state it is in now: `classify` lets a raise stand
    // only for the state it was made in, and a supervisor that raises and
    // then ends its turn has not taken it back.
    const raised_ms: ?u64 = if (in.bus.raisedOf(id, seen_ms)) |r|
        @max(r.at_ms, in.bus.agentOf(id).since_ms)
    else
        null;
    const f = in.bus.facts(id, in.now_ms, .{
        .process = if (open) |t| t.process else .gone,
        .seen_ms = seen_ms,
        .raised_ms = raised_ms,
    });
    wake.consider(Attention.nextChange(f, thresholds, in.now_ms));
    return Attention.classify(f, thresholds, in.now_ms);
}

fn screenOut(s: Attention.Screen) ScreenOut {
    return switch (s) {
        .unmeasured => .unmeasured,
        .unreadable => .unreadable,
        .still_ms => .measured,
    };
}

/// The last line of what the agent said, which is where a question asked
/// in prose ends up.
fn lastLine(text: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, text, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0) return cut(t, 240);
    }
    return "";
}

/// The last paragraph of what the agent said, on one line: where a question
/// asked in prose is, all of it. `rest` says whether anything came before.
fn lastParagraph(arena: Allocator, text: []const u8) Allocator.Error!struct { text: []const u8, rest: bool } {
    const all = std.mem.trimEnd(u8, text, " \t\r\n");
    var start: usize = 0;
    var i: usize = all.len;
    // Back to the last line that is empty or only spaces.
    var line_end = all.len;
    while (i > 0) : (i -= 1) {
        if (all[i - 1] != '\n') continue;
        if (std.mem.trim(u8, all[i..line_end], " \t\r").len == 0) {
            start = line_end;
            break;
        }
        line_end = i - 1;
    }
    const para = std.mem.trim(u8, all[start..], " \t\r\n");
    const out = try arena.dupe(u8, para);
    for (out) |*c| if (c.* == '\n' or c.* == '\r' or c.* == '\t') {
        c.* = ' ';
    };
    return .{ .text = out, .rest = std.mem.trim(u8, all[0..start], " \t\r\n").len > 0 };
}

/// Whether a hook's one-line note may be less than what was said: it is as
/// long as the bus keeps one (`Bus.Agent.note`), or as the summary `+hook`
/// makes (`AgentEvent.summary_chars`). A note shorter than both is whole.
fn noteMayBeCut(note: []const u8) bool {
    if (note.len + 4 > note_bytes) return true;
    return (std.unicode.utf8CountCodepoints(note) catch note.len) >= AgentEvent.summary_chars;
}

/// How many bytes of a note the bus keeps.
const note_bytes = @typeInfo(@FieldType(@FieldType(Bus.Agent, "note"), "buf")).array.len;

fn cut(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var n = limit;
    while (n > 0 and (text[n] & 0xc0) == 0x80) n -= 1;
    return text[0..n];
}

/// The reason line for the terminal a row is about. The sentences are 暂定,
/// like the words in `Attention.Word`.
fn reasonOf(
    arena: Allocator,
    in: Input,
    s: Attention.Status,
    group: ?[]const u8,
    wake: *Wake,
) Allocator.Error!Reason {
    const agent = in.bus.agentOf(s.id);
    switch (s.kind) {
        .needs_approval => {
            // What the title said, as the CLI wrote it (task 1656).
            if (s.source == .title) {
                const title = agent.note.get() orelse return .lacking(.title, .empty_note);
                return .{ .from = .title, .text = try arena.dupe(u8, title), .missing = null };
            }
            const note = agent.note.get() orelse return .lacking(.hook_note, .empty_note);
            return .{ .from = .hook_note, .text = try arena.dupe(u8, note), .missing = null };
        },
        .needs_answer => {
            if (s.source == .self_report) {
                // The supervisor's own sentence. Asked for whatever the
                // person has seen: this row is a self-report because the
                // raise stands, and `statusOf` is what decided that.
                const r = in.bus.raisedOf(s.id, null) orelse return .lacking(.none, .self_report_text);
                if (r.text.len == 0) return .lacking(.raised, .self_report_text);
                return .{ .from = .raised, .text = try arena.dupe(u8, r.text), .missing = null };
            }
            if (agent.note.get()) |note| return .{ .from = .hook_note, .text = try arena.dupe(u8, note), .missing = null };
            // No note: the hook said only that it is waiting. What it asked
            // is how its last turn ended.
            const turn = in.bus.turnOf(s.id) orelse return .lacking(.hook_note, .empty_note);
            const line = lastLine(turn.text);
            if (line.len == 0) return .lacking(.hook_note, .empty_note);
            return .{ .from = .last_turn, .text = try arena.dupe(u8, line), .missing = null };
        },
        .failed => {
            if (s.source == .process) return Reason.saying(arena, .process, .process_exited, &.{});
            const detail = agent.detail.get();
            const note = agent.note.get();
            if (detail != null and note != null) return Reason.saying(arena, .hook_detail, .failed, &.{ detail.?, note.? });
            const text = try arena.dupe(u8, detail orelse note orelse return .lacking(.hook_detail, .empty_detail));
            return .{ .from = .hook_detail, .text = text, .missing = null };
        },
        .suspect_stuck => {
            if (s.source == .hook_missing) return Reason.saying(arena, .hooks, .hooks_missing, &.{});
            return clocks(arena, in, s, wake);
        },
        .quiet_unknown => {
            if (s.source == .screen_unreadable) return .none;
            // The word says it (task 1762); how long a shell's screen has
            // been still says nothing about the agent that left it.
            if (s.source == .agent_left) return .none;
            return clocks(arena, in, s, wake);
        },
        .done_unseen => {
            const turn = in.bus.turnOf(s.id) orelse return .lacking(.last_turn, .no_turn_kept);
            const line = lastLine(turn.text);
            if (line.len == 0) return .lacking(.last_turn, .no_turn_kept);
            return .{ .from = .last_turn, .text = try arena.dupe(u8, line), .missing = null };
        },
        .working => {
            // What the panel says is being worked on. The agent is working
            // now (that is this row's kind) and the title is what its
            // supervisor wrote the work down as; neither half is a guess.
            const title = workingOn(arena, in, s.id, group) orelse return .none;
            return .{ .from = .task, .text = title, .missing = null };
        },
        .idle, .unattended, .snoozed => return .none,
    }
}

/// The title of the task `id` is working on in `group`: its own open task
/// marked `working`, the newest when it has several. Null when it has none
/// -- then nothing is said, rather than another terminal's task or a task
/// nobody has started.
fn workingOn(arena: Allocator, in: Input, id: Id, group: ?[]const u8) ?[]const u8 {
    const name = group orelse return null;
    const mine = in.tasks.forWorker(arena, name, id) catch return null;
    var found: ?Tasks.Task = null;
    for (mine) |t| {
        if (t.progress != .working) continue;
        if (found == null or t.id > found.?.id) found = t;
    }
    const t = found orelse return null;
    return arena.dupe(u8, t.title) catch null;
}

/// A row's `what`: its reason, in the pieces it is drawn in.
fn whatOf(arena: Allocator, in: Input, s: Attention.Status, reason: Reason) Allocator.Error!What {
    // All of what the hook sent, when it sent all of it. One that reached
    // the limit `+hook` cuts at may have had more.
    const asked = in.bus.askOf(s.id);
    const asked_cut: What.Cut = if (asked) |a| (if (a.len + 4 > AgentEvent.max_text_bytes) .tail else .none) else .none;
    const note_cut: What.Cut = if (reason.from == .hook_note and noteMayBeCut(reason.text)) .tail else .none;

    if (s.kind == .needs_approval) {
        const agent = in.bus.agentOf(s.id);
        const text = asked orelse reason.text;
        if (text.len == 0) return .none;
        const how: What.Cut = if (asked != null) asked_cut else note_cut;
        switch (AgentEvent.toolKind(agent.detail.get())) {
            .shell => return .{ .form = .command, .lines = try ShellSteps.split(arena, try arena.dupe(u8, text)), .cut = how },
            .literal => return .{ .form = .code, .lines = try one(arena, text), .cut = how },
        }
    }
    if (s.kind == .needs_answer and reason.from == .raised) {
        // What the supervisor said the person is needed for, whole.
        return .{ .form = .words, .lines = try one(arena, reason.text), .cut = .none };
    }
    if (s.kind == .needs_answer) {
        // A dialog's question, whole.
        if (asked) |a| {
            if (a.len > 0) return .{ .form = .words, .lines = try one(arena, a), .cut = asked_cut };
        }
        // A question asked in prose: the paragraph its last turn ended on,
        // all of that paragraph, and said to be the end of something when
        // there was more before it.
        if (reason.from == .last_turn) {
            if (in.bus.turnOf(s.id)) |turn| {
                const para = try lastParagraph(arena, turn.text);
                if (para.text.len > 0) {
                    const shortened = turn.text_bytes > turn.text.len;
                    return .{ .form = .words, .lines = try one(arena, para.text), .cut = if (para.rest or shortened) .head else .none };
                }
            }
        }
    }
    if (reason.text.len == 0) return .none;
    // Everything else is the reason line. A last line is the end of a turn;
    // a hook's note may have been cut.
    const how: What.Cut = switch (reason.from) {
        // A title is kept where a hook's note is, and cut the same way.
        .hook_note, .title => note_cut,
        .hook_detail => if (noteMayBeCut(in.bus.agentOf(s.id).note.get() orelse "")) .tail else .none,
        .last_turn => how: {
            const turn = in.bus.turnOf(s.id) orelse break :how .none;
            const whole = std.mem.trim(u8, turn.text, " \t\r\n");
            break :how if (whole.len > reason.text.len) .head else .none;
        },
        .process, .clocks, .hooks, .task, .raised, .none => .none,
    };
    return .{ .form = .words, .lines = try one(arena, reason.text), .cut = how, .say = reason.say };
}

fn one(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    const lines = try arena.alloc([]const u8, 1);
    lines[0] = try arena.dupe(u8, text);
    return lines;
}

/// How long the screen has been still and the calls silent, in whole
/// minutes -- so the line changes once a minute and not otherwise.
fn clocks(arena: Allocator, in: Input, s: Attention.Status, wake: *Wake) Allocator.Error!Reason {
    const still = switch (s.screen) {
        .still_ms => |ms| ms,
        .unmeasured, .unreadable => return .none,
    };
    wake.consider(in.now_ms + (min_ms - still % min_ms));

    const silent = in.bus.callSilentMs(s.id, in.now_ms);
    const still_min = try std.fmt.allocPrint(arena, "{d}", .{still / min_ms});
    if (silent) |ms| {
        wake.consider(in.now_ms + (min_ms - ms % min_ms));
        const silent_min = try std.fmt.allocPrint(arena, "{d}", .{ms / min_ms});
        return Reason.saying(arena, .clocks, .still_and_silent, &.{ still_min, silent_min });
    }
    return Reason.saying(arena, .clocks, .still, &.{still_min});
}

const RowDisplay = struct { shown: Attention.Shown, word: Attention.Word };

/// What a row draws: the attention's kind, in the words of the terminal it
/// is about when that terminal has something more exact to say.
fn rowDisplay(a: Attention, about: ?Attention.Status) RowDisplay {
    var d = Attention.displayOf(a.kind);
    if (about) |s| if (a.kind == s.kind) {
        d = Attention.display(s);
    };
    return .{ .shown = d.shown, .word = d.word };
}

fn stewardOf(in: Input, name: []const u8, members: []const Id) ?Id {
    return stewardAmong(in.bus, in.chat, name, members);
}

fn stewardAmong(bus: *const Bus, chat: *const Chat, name: []const u8, members: []const Id) ?Id {
    const by = chat.createdBy(name) catch Chat.user_id;
    if (by != Chat.user_id and minds(bus, by) and
        std.mem.indexOfScalar(Id, members, by) != null) return by;
    // Nobody who made it is minding it: whoever in it is a supervisor.
    for (members) |id| {
        if (id != Chat.user_id and minds(bus, id)) return id;
    }
    return null;
}

/// A supervisor whose agent is still there (task 1762). One whose agent
/// has left keeps its standing -- an agent started in that terminal again
/// is its supervisor again at its first hook (`Bus.agentHasLeft`) -- but
/// minds nothing meanwhile: the group shows no supervisor, so one can be
/// started for it and its last session gone on with, which
/// `start_supervisor` used to refuse as `HasSupervisor`.
fn minds(bus: *const Bus, id: Id) bool {
    return bus.isSupervisor(id) and !bus.agentHasLeft(id);
}

/// The terminal that is `name`'s supervisor, by the rule the snapshot
/// uses, for whoever has to answer between two snapshots: an act that is
/// refused when a group already has one. Null when it has none, and when
/// it could not be worked out.
pub fn stewardOfGroup(arena: Allocator, bus: *const Bus, chat: *const Chat, name: []const u8) ?Id {
    const members = chat.membersOf(arena, name) catch return null;
    return stewardAmong(bus, chat, name, members);
}

/// What the control room says of `name`'s supervisor: there is one, one is
/// on its way, the last try failed, or there is none -- and what starting
/// one would use. `steward` is the answer `stewardOf` gave.
/// What the snapshot says of `name`'s project: the tie as `Chat` holds
/// it, what the host said of that project, and the one word
/// `Projects.reconcile` came to.
fn projectOf(arena: Allocator, in: Input, name: []const u8) Allocator.Error!ProjectOut {
    const tie = in.chat.projectOf(name);
    const why: Projects.Why = for (in.projects.standings) |s| {
        if (std.mem.eql(u8, s.group, name)) break s.why;
    } else switch (tie) {
        // Nothing was worked out for it: only what the tie itself says.
        .bound => .none,
        .declined => .declined,
        .undecided => .projects_unknown,
    };
    const ask = askFor(why, tie, in.chat.projectAsk(name));
    return switch (tie) {
        .undecided => .{ .tie = .undecided, .name = null, .pages = null, .open = null, .start = .directory, .why = why, .ask = ask },
        .declined => .{ .tie = .declined, .name = null, .pages = null, .open = null, .start = .directory, .why = why, .ask = ask },
        .bound => |project| bound: {
            const stated = if (in.projects.table) |t| t.find(project) else null;
            break :bound .{
                .tie = .bound,
                .name = try arena.dupe(u8, project),
                .pages = if (stated) |p| p.pages else null,
                .open = if (stated) |p| p.open != null else null,
                .start = .project,
                .why = why,
                .ask = ask,
            };
        },
    };
}

/// How often the tab of a start waiting for its agent is looked at, to see
/// a question its CLI asks the person come up or go (task 1746).
pub const asking_look_ms: u64 = 2 * std.time.ms_per_s;

fn supervisorOf(arena: Allocator, in: Input, name: []const u8, steward: ?Id, wake: *Wake) Allocator.Error!SupervisorOut {
    const start = in.chat.startOf(name, in.now_ms);
    // Past its deadline a start reads as failed, and nothing else happens
    // at that moment to say so.
    if (start.deadline_ms) |at| wake.consider(at +| 1);
    // A question on a screen says nothing when it comes up or when it is
    // answered: while its agent is waited for, the tab is looked at this
    // often (`App.holdStartupQuestions`), for a minute at most when nothing
    // asks.
    if (start.state == .starting and start.terminal != null) wake.consider(in.now_ms + asking_look_ms);

    const state: SupervisorOut.State = if (steward != null) .present else switch (start.state) {
        .none => .absent,
        .starting => .starting,
        .failed => .failed,
    };

    const last = in.chat.lastSupervisorOf(name);
    const common = in.chat.commonDirOf(name);
    // A directory made up out of the old session snapshot says so; it is
    // still better than where most members are, which a group back from
    // last night has none of.
    const cwd: struct { dir: []const u8, from: SupervisorOut.CwdFrom } = if (last.dir.len > 0)
        .{ .dir = last.dir, .from = switch (last.dir_from) {
            .supervisor, .none => .last_supervisor,
            .session_snapshot => .session_snapshot,
        } }
    else if (common.len > 0)
        .{ .dir = common, .from = .members }
    else if (in.home.len > 0)
        .{ .dir = in.home, .from = .home }
    else
        .{ .dir = "", .from = .none };

    const role = startRoleOf(in.supervisor_roles, last);
    const cli = if (role) |r| startCliOf(try startClisOf(arena, r, in.cli_standings), last) else null;

    const open = try arena.alloc(Id, in.terminals.len);
    for (in.terminals, open) |t, *o| o.* = t.id;
    const go_on = resumeOf(.{
        .last = last,
        .cli = cli,
        .cli_resume = in.cli_resume,
        .held = sessionHeld(in.bus, open, last.session),
        .last_try_failed = start.state == .failed and start.resuming,
    });
    // Reading the adapters is under way and nothing happens here when it
    // ends, so the snapshot asks to be made again shortly.
    if (go_on.why == .clis_unread) wake.consider(in.now_ms + 1_000);

    var by_cli: std.ArrayList(CliResumeOut) = .empty;
    for (in.supervisor_roles) |r| for (try startClisOf(arena, r, in.cli_standings)) |c| {
        const seen = for (by_cli.items) |b| {
            if (std.mem.eql(u8, b.cli, c)) break true;
        } else false;
        if (seen) continue;
        const this_one = resumeOf(.{
            .last = last,
            .cli = c,
            .cli_resume = in.cli_resume,
            .held = sessionHeld(in.bus, open, last.session),
            .last_try_failed = start.state == .failed and start.resuming,
        });
        try by_cli.append(arena, .{ .cli = try arena.dupe(u8, c), .can = this_one.can, .why = this_one.why });
    };

    return .{
        .state = state,
        .can_start = (state == .absent or state == .failed) and in.supervisor_roles.len > 0,
        .terminal = if (state == .starting or state == .failed) .opt(start.terminal) else null,
        .failed = if (state == .failed) start.failed else .none,
        .asking = state == .starting and start.asking,
        .role = if (role) |r| try arena.dupe(u8, r.key) else null,
        .cli = if (cli) |c| try arena.dupe(u8, c) else null,
        .cli_label = if (cliLabelOf(in.cli_names, cli)) |l| try arena.dupe(u8, l) else null,
        .cwd = try arena.dupe(u8, cwd.dir),
        .cwd_from = cwd.from,
        .last = .{
            .role = if (last.role.len > 0) try arena.dupe(u8, last.role) else null,
            .cli = if (last.cli.len > 0) try arena.dupe(u8, last.cli) else null,
            .cli_label = if (cliLabelOf(in.cli_names, last.cli)) |l| try arena.dupe(u8, l) else null,
            .heard_ms = last.heard_ms,
        },
        .@"resume" = go_on,
        .resume_by_cli = by_cli.items,
        .clis_read = in.cli_resume != .unread,
        .hookless = if (steward) |id| try hooklessOf(arena, in, name, id) else .none,
    };
}

fn sayOf(key: Say.Key) Say {
    return .{ .key = key, .template = Say.templateOf(key), .args = &.{} };
}

fn hooklessOf(arena: Allocator, in: Input, group: []const u8, id: Id) Allocator.Error!HooklessOut {
    // A take-over under way outlives what it is taking over: the agent has
    // quit, and the frame still says what is being done about it.
    const run: ?TakeOverIn = if (in.take_over) |t| (if (std.mem.eql(u8, t.group, group)) t else null) else null;
    for (in.terminals) |t| if (t.id == id) return switch (t.hookless) {
        .no => if (run) |r| .{ .state = .none, .cli_label = null, .session = false, .note = null, .take_over = takeOverRun(r) } else .none,
        .asking => .{ .state = .asking, .cli_label = null, .session = false, .note = sayOf(.started_by_hand), .take_over = if (run) |r| takeOverRun(r) else .none },
        .unknown => .{ .state = .unknown, .cli_label = null, .session = false, .note = sayOf(.cli_not_recognised), .take_over = if (run) |r| takeOverRun(r) else .none },
        .known => |k| .{
            .state = .known,
            .cli_label = try arena.dupe(u8, k.label),
            .session = k.session,
            .note = sayOf(.started_by_hand),
            .take_over = try takeOverOf(arena, k, run),
        },
    };
    return .none;
}

fn takeOverRun(r: TakeOverIn) TakeOverOut {
    return switch (r.state) {
        .running => .{ .state = .running, .confirm = null, .status = sayOf(.take_over_running) },
        .failed => |why| .{ .state = .failed, .confirm = null, .status = sayOf(switch (why) {
            .busy => .take_over_busy,
            .typing => .take_over_typing,
            .did_not_quit => .take_over_did_not_quit,
            .did_not_start => .take_over_did_not_start,
            .cannot_start => .take_over_cannot_start,
        }) },
    };
}

/// What the supervisor's frame offers for one an adapter recognised.
fn takeOverOf(arena: Allocator, k: Hookless.Known, run: ?TakeOverIn) Allocator.Error!TakeOverOut {
    if (run) |r| if (r.state == .running) return takeOverRun(r);
    if (!k.can_quit) return .none;
    const label = try arena.dupe(u8, k.label);
    const confirm: Say = if (!k.session)
        .{ .key = .take_over_confirm_new, .template = Say.templateOf(.take_over_confirm_new), .args = try arena.dupe([]const u8, &.{label}) }
    else confirm: {
        const short = try arena.dupe(u8, k.session_short);
        const age = if (k.written_min) |m| try std.fmt.allocPrint(arena, "{d}", .{m}) else "?";
        const key: Say.Key = if (k.sure) .take_over_confirm_sure else .take_over_confirm_unsure;
        break :confirm .{ .key = key, .template = Say.templateOf(key), .args = try arena.dupe([]const u8, &.{ label, short, age }) };
    };
    const failed = if (run) |r| takeOverRun(r).status else null;
    return .{ .state = if (failed != null) .failed else .offer, .confirm = confirm, .status = failed };
}

const Pending = struct {
    row: GroupRow,
    attention: Attention,
    /// A terminal that is open and has an agent in it is a member.
    has_agent: bool,
};

/// Whether an open terminal is somebody's agent: a supervisor, a worker
/// somebody minds, or one whose agent has been heard from or is connected.
/// A plain shell that was added to a group is none of these.
fn hasAgent(in: Input, t: Terminal) bool {
    return switch (in.bus.roleOf(t.id)) {
        .supervisor, .watched => true,
        .none => in.bus.agentOf(t.id).hooks != .none or t.agent_present,
    };
}

fn pendingBefore(_: void, a: Pending, b: Pending) bool {
    // **A pinned group leads its section, and only its section** (task
    // 1659): the groups waiting for the person stay above every other,
    // pinned or not, and inside each half the order is what it was.
    if (a.row.needs_me != b.row.needs_me) return a.row.needs_me;
    if (a.row.pinned != b.row.pinned) return a.row.pinned;
    if (Attention.before(a.attention, b.attention)) return true;
    if (Attention.before(b.attention, a.attention)) return false;
    return std.mem.lessThan(u8, a.row.name, b.row.name);
}

fn archivedBefore(_: void, a: ArchivedRow, b: ArchivedRow) bool {
    if (a.archived_ms != b.archived_ms) return a.archived_ms > b.archived_ms;
    return std.mem.lessThan(u8, a.name, b.name);
}

const Lone = struct {
    row: LoneRow,
    attention: Attention,
};

fn loneBefore(_: void, a: Lone, b: Lone) bool {
    return Attention.before(a.attention, b.attention);
}

fn tabBefore(_: void, a: Tab, b: Tab) bool {
    const aw = if (a.window) |w| w.id else 0;
    const bw = if (b.window) |w| w.id else 0;
    if (aw != bw) return aw < bw;
    return a.tab.id < b.tab.id;
}

fn terminalBefore(_: void, a: Terminal, b: Terminal) bool {
    return a.id < b.id;
}

/// Work the whole snapshot out. Everything in the result lives in `arena`.
fn build(arena: Allocator, in: Input) Allocator.Error!Built {
    var wake: Wake = .{ .now_ms = in.now_ms, .at = null };
    // The adapters not read yet: which CLIs can start here is still the
    // plugins' word alone, and a read changes it (task 1744) -- with
    // nothing else happening when it ends, the snapshot asks to be made
    // again shortly, as `clis_unread` does for a group's session.
    if (in.cli_resume == .unread) wake.consider(in.now_ms + 1_000);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = in.chat.groups.keyIterator();
    while (it.next()) |k| try names.append(arena, k.*);

    var grouped: std.AutoHashMapUnmanaged(Id, ?u64) = .empty;
    var rows: std.ArrayListUnmanaged(Pending) = .empty;
    var archived: std.ArrayListUnmanaged(ArchivedRow) = .empty;
    var fix_cards: std.ArrayListUnmanaged(ControlFix.Card) = .empty;

    for (names.items) |name| {
        const all = in.chat.membersOf(arena, name) catch continue;
        const steward_id = stewardOf(in, name, all);
        const seen = in.chat.seenRunMs(name);
        const marks = in.chat.marksOf(name) catch Chat.Marks.none;
        const snooze = in.chat.snoozeOf(name, in.now_ms, in.wall_ms);
        const cost: DeleteCost = .{
            .members = members: {
                var n: usize = 0;
                for (all) |id| {
                    if (id != Chat.user_id) n += 1;
                }
                break :members n;
            },
            .open_tasks = in.tasks.openInGroup(name),
        };
        const record_dir: []const u8 = if (in.record_root.len == 0)
            ""
        else
            try std.fs.path.join(arena, &.{ in.record_root, name });

        // **Off the list, and nothing else** (task 1659). Its terminals are
        // still its own -- counted as in a group, so a supervisor that goes
        // on working in an archived group is not drawn as one in none --
        // but it has no row, no count and no notification.
        if (marks.archived_ms) |at| {
            for (all) |id| {
                if (id == Chat.user_id) continue;
                const gop = try grouped.getOrPut(arena, id);
                if (!gop.found_existing) gop.value_ptr.* = null;
            }
            try archived.append(arena, .{
                .name = try arena.dupe(u8, name),
                .brief = try arena.dupe(u8, in.chat.briefOf(name) catch ""),
                .archived_ms = at,
                .record_dir = record_dir,
                .delete_cost = cost,
            });
            continue;
        }

        // A mute that ends has to be redrawn as ended when it does.
        const mute = in.chat.muteOf(name, in.wall_ms);
        switch (mute) {
            .until => |until| wake.consider(in.now_ms +| (until -| in.wall_ms)),
            .none, .forever => {},
        }

        var steward: ?Attention.Status = null;
        var workers: std.ArrayListUnmanaged(Attention.Status) = .empty;
        var members: std.ArrayListUnmanaged(Member) = .empty;
        var failing: std.ArrayListUnmanaged(ControlFix.Failing) = .empty;
        var has_agent = false;

        for (all) |id| {
            if (id == Chat.user_id) continue;
            if (find(in.terminals, id)) |t| {
                if (hasAgent(in, t)) has_agent = true;
            }

            // Seen in any of its groups is seen, for the glyph on its tab.
            const gop = try grouped.getOrPut(arena, id);
            if (!gop.found_existing) gop.value_ptr.* = null;
            if (seen) |ms| gop.value_ptr.* = @max(gop.value_ptr.* orelse 0, ms);

            const s = statusOf(in, id, seen, &wake);
            const is_steward = steward_id != null and steward_id.? == id;
            if (is_steward) steward = s else try workers.append(arena, s);
            if (s.alive and s.kind == .failed) try failing.append(arena, try failingOf(arena, in, s));

            // A worker's first minute is its supervisor's; the row changes
            // when that minute is up.
            // (A prompt its supervisor may not answer never had that
            // minute, so there is nothing to wake for.)
            if (!is_steward and s.alive and s.duty == .on and Attention.firstMinuteIsTheSupervisors(s)) switch (s.kind) {
                .needs_approval, .failed => wake.consider(s.since_ms +| in.thresholds.bubble_after_ms +| 1),
                else => {},
            };

            const d = Attention.display(s);
            try members.append(arena, .{
                .id = .{ .id = id },
                .role = if (is_steward) .steward else .worker,
                .title = if (find(in.terminals, id)) |t| try arena.dupe(u8, t.title) else "",
                .kind = s.kind,
                .since_ms = s.since_ms,
                .source = s.source,
                .age_ms = s.age_ms,
                .shown = d.shown,
                .word = d.word,
                .text = d.word.text(),
                .screen = screenOut(s.screen),
                .alive = s.alive,
                .duty = s.duty,
                .held = s.held,
                .shielded = s.shielded,
            });
        }

        const last_ms = in.chat.lastMsOf(name);
        const a = Attention.ofGroup(.{
            .steward = steward,
            .workers = workers.items,
            .snooze = snooze,
            .last_ms = last_ms,
        }, in.thresholds, in.now_ms);
        switch (snooze) {
            .until_ms => |until| wake.consider(until),
            .none, .until_change => {},
        }

        // The terminal the row is about, and the others also waiting.
        var about: ?Attention.Status = null;
        var more: usize = 0;
        if (steward) |s| {
            if (a.terminal != null and a.terminal.? == s.id) about = s;
        }
        for (workers.items) |w| {
            if (a.terminal != null and a.terminal.? == w.id) about = w;
        }
        if (steward) |s| {
            if (waiting(s) and (about == null or about.?.id != s.id)) more += 1;
        }
        for (workers.items) |w| {
            if (waiting(w) and (about == null or about.?.id != w.id)) more += 1;
        }

        const d = rowDisplay(a, about);
        const fix_key: ControlFix.Key = .{ .group = try arena.dupe(u8, name) };
        const fix = ControlFix.stateOf(d.word, in.fix_sent, steward_id, failing.items);
        if (fix != .none) try fix_cards.append(arena, .{
            .key = fix_key,
            .steward = steward_id,
            .failing = failing.items,
            .state = fix,
        });
        const reason: Reason = if (about != null and a.kind == about.?.kind)
            try reasonOf(arena, in, about.?, name, &wake)
        else
            .none;
        // Who is waiting: the supervisor, or one of its workers. Nobody,
        // on a row that needs nothing.
        const waiter: Waiter = if (!Attention.needsMe(a)) .none else if (about) |who| waiter: {
            if (steward_id != null and steward_id.? == who.id) break :waiter .{ .is = .supervisor, .name = "" };
            const title = if (find(in.terminals, who.id)) |t| try arena.dupe(u8, t.title) else "";
            break :waiter .{ .is = if (steward_id != null) .worker_via_supervisor else .worker, .name = title };
        } else .none;
        try rows.append(arena, .{
            .attention = a,
            .has_agent = has_agent,
            .row = .{
                .name = try arena.dupe(u8, name),
                .brief = try arena.dupe(u8, in.chat.briefOf(name) catch ""),
                .last_ms = last_ms,
                .seen_ms = marks.seen_ms,
                .snooze = .of(marks.snooze),
                .steward = .opt(steward_id),
                .supervisor = try supervisorOf(arena, in, name, steward_id, &wake),
                .project = try projectOf(arena, in, name),
                .attention = .of(a, in.bus),
                .needs_me = Attention.needsMe(a),
                // **Looking at this row changes it**: it stopped and nobody has
                // looked, or its supervisor raised it "until they have looked".
                // A host starts its "seen" clock on this and on nothing else, so
                // a raise that did not say so here could never be withdrawn --
                // which is what it was (the Windows machine, 2026-10-13: five
                // seconds on the row, in front, and no `seen` was ever sent).
                //
                // **Wherever in the row the raise is.** This asked whether
                // the raise was the row's reason, so one standing behind a
                // worker's prompt -- "1 more" -- was never looked at however
                // long the person looked (the same machine, the same day:
                // eight seconds, in front, and it stayed until the end).
                .unseen = Attention.unseen(a) or raiseStandsIn(in, steward, workers.items),
                .shown = d.shown,
                .word = d.word,
                .text = d.word.text(),
                .waiter = waiter,
                .reason = reason,
                .what = if (about) |who| try whatOf(arena, in, who, reason) else .none,
                .more = more,
                .same_as = null,
                .members = members.items,
                .pinned = marks.pinned,
                .muted = MuteOut.of(mute),
                .delete_cost = cost,
                .record_dir = record_dir,
                .fix = fix,
                .ask = in.asks.of(name),
            },
        });
    }

    std.mem.sort(Pending, rows.items, {}, pendingBefore);
    std.mem.sort(ArchivedRow, archived.items, {}, archivedBefore);

    // One supervisor, several groups: the one spoken in last carries the
    // reason, the others point at it (4.4). 暂定: "spoken in last" is the
    // group's last message, not that supervisor's own.
    for (rows.items, 0..) |*r, i| {
        if (r.attention.what != .own) continue;
        const t = r.attention.terminal orelse continue;
        // The first of them in the list leads unless a later one was
        // spoken in more recently. Starting from this row instead would
        // leave two groups nobody has spoken in each leading itself, and
        // neither pointing at the other.
        var lead: ?usize = null;
        for (rows.items, 0..) |o, j| {
            if (o.attention.what != .own or o.attention.terminal == null) continue;
            if (o.attention.terminal.? != t) continue;
            if (lead == null or o.row.last_ms > rows.items[lead.?].row.last_ms) lead = j;
        }
        if (lead.? != i) r.row.same_as = rows.items[lead.?].row.name;
    }

    // Terminals on their own (4.6): a supervisor with no group, and an
    // agent nobody is minding.
    var lone: std.ArrayListUnmanaged(Lone) = .empty;
    const sorted = try arena.dupe(Terminal, in.terminals);
    std.mem.sort(Terminal, sorted, {}, terminalBefore);

    var terminals: std.ArrayListUnmanaged(TerminalOut) = .empty;
    var statuses: std.ArrayListUnmanaged(Attention.Status) = .empty;
    for (sorted) |t| {
        const in_group = grouped.get(t.id);
        // In a group: looked at through its group. On its own: through its
        // own row (`Bus.markSeen`).
        const s = statusOf(in, t.id, if (in_group) |seen| seen else in.bus.seenOf(t.id), &wake);
        try statuses.append(arena, s);

        const d = Attention.display(s);
        try terminals.append(arena, .{
            .id = .{ .id = t.id },
            .title = try arena.dupe(u8, t.title),
            .window = .opt(t.window),
            .tab = .opt(t.tab),
            .pane = .of(in.bus.roleOf(t.id)),
            .who = try whoOf(arena, in.bus, t),
            .bar = .of(d, s.held),
            .kind = s.kind,
            .since_ms = s.since_ms,
            .event_ms = in.bus.agentOf(t.id).last_event_ms,
            .source = s.source,
            .age_ms = s.age_ms,
            .shown = d.shown,
            .word = d.word,
            .text = d.word.text(),
            .screen = screenOut(s.screen),
            .alive = s.alive,
            .duty = s.duty,
            .held = s.held,
            .shielded = s.shielded,
        });

        if (in_group != null) continue;
        // A supervisor with no group, a worker somebody minds outside any
        // group, and an agent nobody minds at all.
        const alone = hasAgent(in, t);
        if (!alone) continue;

        const a = Attention.ofTerminal(s);
        const rd = rowDisplay(a, s);
        const lone_key: ControlFix.Key = .{ .terminal = t.id };
        const lone_failing: []const ControlFix.Failing = if (s.alive and s.kind == .failed)
            try arena.dupe(ControlFix.Failing, &.{try failingOf(arena, in, s)})
        else
            &.{};
        const lone_fix = ControlFix.stateOf(rd.word, in.fix_sent, null, lone_failing);
        if (lone_fix != .none) try fix_cards.append(arena, .{
            .key = lone_key,
            .steward = null,
            .failing = lone_failing,
            .state = lone_fix,
        });
        const reason: Reason = if (a.kind == s.kind) try reasonOf(arena, in, s, null, &wake) else .none;
        try lone.append(arena, .{
            .attention = a,
            .row = .{
                .id = .{ .id = t.id },
                .title = try arena.dupe(u8, t.title),
                .attention = .of(a, in.bus),
                .needs_me = Attention.needsMe(a),
                // As for a group's row: looking at it changes it.
                .unseen = Attention.unseen(a) or reason.from == .raised,
                .shown = rd.shown,
                .word = rd.word,
                .text = rd.word.text(),
                .waiter = if (Attention.needsMe(a)) .{ .is = .terminal, .name = "" } else .none,
                .reason = reason,
                .what = try whatOf(arena, in, s, reason),
                .fix = lone_fix,
            },
        });
    }
    std.mem.sort(Lone, lone.items, {}, loneBefore);

    // One glyph per window tab: the highest of what is in it.
    var tabs: std.ArrayListUnmanaged(Tab) = .empty;
    for (sorted) |t| {
        const tab = t.tab orelse continue;
        const known = for (tabs.items) |have| {
            if (have.tab.id == tab and (if (have.window) |w| w.id else null) == t.window) break true;
        } else false;
        if (known) continue;

        var inside: std.ArrayListUnmanaged(Attention.Status) = .empty;
        for (sorted, statuses.items) |o, s| {
            if (o.tab != null and o.tab.? == tab and o.window == t.window) try inside.append(arena, s);
        }
        const top = Attention.top(inside.items, .window_tab);
        try tabs.append(arena, .{
            .window = .opt(t.window),
            .tab = .{ .id = tab },
            .shown = top.shown,
            .terminal = if (top.index) |i| .{ .id = inside.items[i].id } else null,
        });
    }
    std.mem.sort(Tab, tabs.items, {}, tabBefore);

    // Which waiting glyph breathes: the order to pick it from.
    var waiting_now: std.ArrayListUnmanaged(usize) = .empty;
    for (statuses.items, 0..) |s, i| {
        if (Attention.display(s).shown == .needs_you) try waiting_now.append(arena, i);
    }
    std.mem.sort(usize, waiting_now.items, statuses.items, struct {
        fn lt(all: []const Attention.Status, a: usize, b: usize) bool {
            if (all[a].since_ms != all[b].since_ms) return all[a].since_ms < all[b].since_ms;
            return all[a].id < all[b].id;
        }
    }.lt);
    const pulses = try arena.alloc(Pulse, waiting_now.items.len);
    for (waiting_now.items, pulses) |i, *p| {
        const t = sorted[i];
        p.* = .{
            .terminal = .{ .id = t.id },
            .window = .opt(t.window),
            .tab = .opt(t.tab),
            .group = for (rows.items) |r| {
                if (r.row.same_as != null) continue;
                if (r.attention.terminal != null and r.attention.terminal.? == t.id) break r.row.name;
            } else null,
        };
    }

    // Where a control room opens: the first group with an agent in it,
    // and the first group at all when they are all empty.
    const open_on: ?[]const u8 = for (rows.items) |r| {
        if (r.has_agent) break r.row.name;
    } else if (rows.items.len > 0) rows.items[0].row.name else null;

    // The counts. **One meaning for every number the person is shown**:
    // a row that waits and is drawn is one. `needs_me` -- the Dock, the
    // taskbar, a title -- and the list's heading are the same number.
    //
    // **A terminal in no group is in none of them.** It was, while the
    // hosts drew a row for it (task 1469); the rows read as groups nobody
    // had made, and the hosts stopped drawing them (the user, 2026-10-13,
    // task 1485). A number that counted them would again say more than
    // the list shows, which is what counting them was for. They are still
    // listed, in `ungrouped`, with what each would say.
    //
    // It used to count the terminals behind the rows, each once, so that
    // one supervisor minding three groups was 1. On a real window that
    // read as four rows under "4 groups waiting for you" and a 3 on the
    // Dock, with no way to tell which was right (verify-cr-03). 暂定.
    var needing: usize = 0;
    const group_rows = try arena.alloc(GroupRow, rows.items.len);
    for (rows.items, group_rows) |r, *out| {
        out.* = r.row;
        if (r.row.needs_me) needing += 1;
    }
    const lone_rows = try arena.alloc(LoneRow, lone.items.len);
    for (lone.items, lone_rows) |r, *out| out.* = r.row;

    // The allowance counts on the wall clock, since that is the clock its
    // resets are on; the wake is on the bus's. A machine that slept wakes
    // late for these, and catches up on the next thing that happens.
    const allowance = try quota.build(arena, in.quota, in.wall_ms);
    if (allowance.wake_ms) |at| wake.consider(in.now_ms +| (at -| in.wall_ms));

    return .{
        .snapshot = .{
            .rev = 0,
            .now_ms = in.now_ms,
            .needs_me = needing,
            .groups_needing_me = needing,
            .groups_other = group_rows.len - needing,
            .header_waiting = .over(needing, 0),
            .header_quiet = .over(group_rows.len - needing, 0),
            .open_on = open_on,
            .groups = group_rows,
            .archived = archived.items,
            .ungrouped = lone_rows,
            .terminals = terminals.items,
            .tabs = tabs.items,
            .projects_known = if (in.projects.table) |t| t.stated != null else false,
            .project_orders = orders: {
                const out = try arena.alloc(OrderOut, in.projects.orders.len);
                for (in.projects.orders, out) |o, *made| made.* = .{
                    .order = o.order,
                    .project = try arena.dupe(u8, o.project),
                    .group = if (o.group) |g| try arena.dupe(u8, g) else null,
                    .to = if (o.to) |t| try arena.dupe(u8, t) else null,
                    .terminal = .opt(o.terminal),
                };
                break :orders out;
            },
            .supervisor_roles = roles: {
                const out = try arena.alloc(SupervisorRole, in.supervisor_roles.len);
                for (in.supervisor_roles, out) |r, *o| {
                    const here = try startClisOf(arena, r, in.cli_standings);
                    const clis = try arena.alloc(CliOut, here.len);
                    for (here, clis) |c, *d| d.* = .{
                        .key = try arena.dupe(u8, c),
                        .label = if (cliLabelOf(in.cli_names, c)) |l| try arena.dupe(u8, l) else null,
                    };
                    var held: std.ArrayList(HeldBackOut) = .empty;
                    if (in.cli_standings) |all| for (r.clis) |c| {
                        const why = standingOf(all, c) orelse continue;
                        try held.append(arena, .{
                            .key = try arena.dupe(u8, c),
                            .label = if (cliLabelOf(in.cli_names, c)) |l| try arena.dupe(u8, l) else null,
                            .why = why,
                        });
                    };
                    o.* = .{
                        .key = try arena.dupe(u8, r.key),
                        .name = try arena.dupe(u8, r.name),
                        .clis = clis,
                        .held_back = held.items,
                    };
                }
                break :roles out;
            },
            .choose_supervisor_role = in.supervisor_roles.len > 1,
            .pulses = pulses,
            .quota = allowance.out,
            .retention_waiting_bytes = in.retention_waiting,
        },
        .wake_ms = wake.at,
        .fix_cards = fix_cards.items,
    };
}

/// One failed terminal, as the "Fix" button names it.
fn failingOf(arena: Allocator, in: Input, s: Attention.Status) Allocator.Error!ControlFix.Failing {
    // The error's name, as `reasonOf` reads it: the detail, else the note.
    const agent = in.bus.agentOf(s.id);
    const what: []const u8 = if (s.source == .process) "process_exited" else agent.detail.get() orelse agent.note.get() orelse "";
    return .{
        .id = s.id,
        .title = if (find(in.terminals, s.id)) |t| try arena.dupe(u8, t.title) else "",
        .what = try arena.dupe(u8, what),
        .since_ms = s.since_ms,
        .at_wall_ms = in.wall_ms -| (in.now_ms -| s.since_ms),
    };
}

/// The cards, copied into `arena`: the snapshot they come from does not
/// outlive `refresh`.
fn copyCards(arena: Allocator, cards: []const ControlFix.Card) Allocator.Error![]const ControlFix.Card {
    const out = try arena.alloc(ControlFix.Card, cards.len);
    for (cards, out) |c, *o| {
        const failing = try arena.alloc(ControlFix.Failing, c.failing.len);
        for (c.failing, failing) |f, *g| {
            g.* = f;
            g.title = try arena.dupe(u8, f.title);
            g.what = try arena.dupe(u8, f.what);
        }
        o.* = .{
            .key = switch (c.key) {
                .group => |name| .{ .group = try arena.dupe(u8, name) },
                .terminal => c.key,
            },
            .steward = c.steward,
            .failing = failing,
            .state = c.state,
        };
    }
    return out;
}

/// The card the "Fix" button on `key` acts on, as it was last drawn; null
/// when no such card offers it.
pub fn fixCard(self: *const ControlRoom, key: ControlFix.Key) ?ControlFix.Card {
    for (self.fix_cards) |c| {
        const same = switch (key) {
            .group => |name| c.key == .group and std.mem.eql(u8, c.key.group, name),
            .terminal => |id| c.key == .terminal and c.key.terminal == id,
        };
        if (same) return c;
    }
    return null;
}

/// A terminal that is itself waiting on the person.
fn waiting(s: Attention.Status) bool {
    return s.alive and s.duty == .on and s.kind.needsMe();
}

/// Whether this terminal is waiting on something it raised (`Bus.raise`)
/// and the person has not looked at since. The same question `reasonOf`
/// asks before it takes the raise's words, and `statusOf` is what decided
/// it: a status is a self-reported "needs an answer" because a raise
/// stands.
fn raiseStands(in: Input, s: Attention.Status) bool {
    if (!waiting(s)) return false;
    if (s.kind != .needs_answer or s.source != .self_report) return false;
    return in.bus.raisedOf(s.id, null) != null;
}

/// Whether anything in a group's row is: its supervisor or any worker,
/// whichever of them the row happens to be about.
fn raiseStandsIn(in: Input, steward: ?Attention.Status, workers: []const Attention.Status) bool {
    if (steward) |s| if (raiseStands(in, s)) return true;
    for (workers) |w| if (raiseStands(in, w)) return true;
    return false;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;
const T = Attention.Thresholds.defaults;

/// A bus and a chat with terminals in them, and the list of what is open.
const World = struct {
    bus: Bus,
    chat: Chat,
    tasks: Tasks,
    open: std.ArrayListUnmanaged(Terminal) = .empty,
    wall_ms: u64 = 1_700_000_000_000,
    quota: []const quota.Reading = &.{},
    retention_waiting: ?u64 = null,
    roles: []const StartRole = &.{.{ .key = "polter-supervisor", .name = "Polter Supervisor", .clis = &.{"claude-code"} }},
    cli_resume: CliResume = .{ .read = &.{"claude-code"} },
    cli_standings: ?[]const CliStanding = &.{.{ .key = "claude-code", .standing = .ok }},
    projects: ProjectsIn = .unknown,
    cli_names: []const CliName = &.{.{ .key = "claude-code", .label = "Claude Code" }},
    home: []const u8 = "/Users/me",
    fix_sent: ControlFix.Sent = .{},
    asks: ControlAsk = .{},
    take_over: ?TakeOverIn = null,

    fn init() World {
        return .{
            .bus = .init(testing.allocator, .{}),
            .chat = .init(testing.allocator, .{}),
            .tasks = .init(testing.allocator, .{}),
        };
    }

    fn deinit(self: *World) void {
        self.fix_sent.deinit(testing.allocator);
        self.asks.deinit(testing.allocator);
        self.open.deinit(testing.allocator);
        self.tasks.deinit();
        self.chat.deinit();
        self.bus.deinit();
    }

    /// An approval asked through a tool: the tool's name, the one-line
    /// summary a hook cuts, and the whole of what is to be approved.
    fn approval(self: *World, id: Id, tool: []const u8, asked: []const u8, at_ms: u64) !void {
        var ev: AgentEvent.Event = .none;
        ev.event = .awaiting_approval;
        ev.cli = "claude-code";
        ev.session_id = "s";
        ev.detail = tool;
        ev.note = AgentEvent.cutBytes(asked, 120);
        ev.text = asked;
        ev.text_bytes = asked.len;
        _ = try self.bus.agentEvent(id, ev, at_ms);
    }

    /// A task of `group` that `owner` has started.
    fn working(self: *World, group: []const u8, owner: Id, title: []const u8) !void {
        const id = try self.tasks.create(group, title, .feature);
        try self.tasks.assign(id, owner);
        try self.tasks.setProgress(id, owner, .working);
    }

    fn terminal(self: *World, id: Id, title: []const u8, tab: u64) !void {
        try self.bus.register(id);
        try self.open.append(testing.allocator, .{
            .id = id,
            .title = title,
            .window = 0x10,
            .tab = tab,
            .process = .running,
            .agent_present = false,
            .at_prompt = false,
            .role = "",
            .launched_cli = "",
            .still_ms = null,
            .hookless = .no,
        });
    }

    fn steward(self: *World, id: Id, title: []const u8, tab: u64, group: []const u8) !void {
        try self.terminal(id, title, tab);
        try self.bus.addSupervisor(id);
        try self.chat.create(group, id);
    }

    fn worker(self: *World, id: Id, title: []const u8, tab: u64, boss: Id, group: []const u8) !void {
        try self.terminal(id, title, tab);
        try self.bus.watch(id, boss);
        try self.chat.add(group, id, .all, .{});
    }

    fn hook(self: *World, id: Id, kind: AgentEvent.Kind, note: ?[]const u8, at_ms: u64) !void {
        var ev: AgentEvent.Event = .none;
        ev.event = kind;
        ev.cli = "claude-code";
        ev.session_id = "s";
        ev.note = note;
        if (kind == .turn_ended) {
            ev.text = note;
            ev.text_bytes = if (note) |n| n.len else 0;
            ev.note = null;
        }
        _ = try self.bus.agentEvent(id, ev, at_ms);
    }

    fn input(self: *const World, now_ms: u64) Input {
        return .{
            .bus = &self.bus,
            .chat = &self.chat,
            .terminals = self.open.items,
            .thresholds = T,
            .tasks = &self.tasks,
            .quota = self.quota,
            .retention_waiting = self.retention_waiting,
            .supervisor_roles = self.roles,
            .cli_resume = self.cli_resume,
            .cli_standings = self.cli_standings,
            .projects = self.projects,
            .cli_names = self.cli_names,
            .home = self.home,
            .record_root = "/state/chat",
            .fix_sent = &self.fix_sent,
            .asks = &self.asks,
            .take_over = self.take_over,
            .now_ms = now_ms,
            .wall_ms = self.wall_ms + now_ms,
        };
    }
};

const min = std.time.ms_per_min;

/// Seven groups, one of each thing a row can say, and an eighth that shares
/// its supervisor with the first.
fn fixtureWorld() !World {
    var w: World = .init();
    errdefer w.deinit();

    // Waiting on an approval of three steps; a worker also waiting.
    try w.steward(0xa1, "web-app", 0x21, "web-app");
    try w.approval(0xa1, "Bash", "rm -rf dist/ .cache/ node_modules/.vite && npm ci && npm run build -- --mode production", 96 * min);
    try w.worker(0xb1, "web-app worker", 0x21, 0xa1, "web-app");
    try w.approval(0xb1, "Edit", "src/app.ts", 99 * min + 30_000);

    // The same supervisor minds a second group, spoken in more recently.
    try w.chat.create("web-app-docs", 0xa1);
    _ = try w.chat.post("web-app-docs", 0xa1, "docs next", 1_700_000_000_000);

    // Waiting on an answer.
    try w.steward(0xa2, "billing", 0x22, "billing");
    try w.hook(0xa2, .awaiting_input, "发票编号要按租户分开，还是全局连续？分开的话，旧发票要不要一起改编号？", 89 * min);

    // Failed.
    try w.steward(0xa3, "docs-site", 0x23, "docs-site");
    var failed: AgentEvent.Event = .none;
    failed.event = .turn_failed;
    failed.detail = "rate_limit";
    failed.note = "resets 13:40";
    _ = try w.bus.agentEvent(0xa3, failed, 98 * min);

    // A worker waiting, and its supervisor not: the wait comes up through
    // the supervisor.
    try w.steward(0xa7, "mobile", 0x28, "mobile");
    try w.hook(0xa7, .session_started, null, 20 * min);
    try w.worker(0xb7, "ios-build", 0x28, 0xa7, "mobile");
    try w.approval(0xb7, "Bash", "git push --force-with-lease origin release/2.4", 97 * min);

    // Finished a turn nobody has looked at.
    try w.steward(0xa4, "infra", 0x24, "infra");
    try w.hook(0xa4, .turn_ended, "迁移脚本跑完了。\n要不要现在切流量？", 70 * min);

    // Working on a task of its own, with a worker that clocked off.
    try w.steward(0xa5, "design-system", 0x25, "design-system");
    try w.hook(0xa5, .turn_started, null, 95 * min);
    try w.working("design-system", 0xa5, "改按钮的三种尺寸");
    try w.worker(0xb5, "tokens", 0x25, 0xa5, "design-system");
    try w.bus.clockOff(0xb5, .supervisor);
    // And held by the person: what its pane's title says.
    try w.bus.setHeld(0xb5, true, .user);

    // Idle.
    try w.steward(0xa6, "notes", 0x26, "notes");
    try w.hook(0xa6, .session_started, null, 10 * min);

    // On its own: an agent with hooks that nobody minds, waiting.
    try w.terminal(0xc1, "zsh — ~/work", 0x27);
    try w.approval(0xc1, "Bash", "git push", 99 * min);
    // And a plain shell, which is in no list but `terminals`.
    try w.terminal(0xc2, "zsh", 0x27);

    // One account close to its limit and one with room.
    w.quota = &fixture_quota;

    // What is written down of two groups' supervisors. The one that is
    // there now, in the session its hooks name: nothing goes on with a
    // session a terminal is in. And one whose session is from before.
    // The other six have nothing written down.
    //
    // Who is in each terminal. The plain shell is at its prompt: nobody,
    // which is not the same answer as the worker whose hooks were never
    // heard and whose shell does not say (not known). The web-app worker
    // was started in a role, in a pane its supervisor opened.
    //
    // Two supervisors somebody started by typing their command (task
    // 1635): one its adapter recognised, in a session it found, and one no
    // adapter did.
    for (w.open.items) |*t| switch (t.id) {
        0xc2 => t.at_prompt = true,
        0xb1 => t.role = "dev-worker",
        0xa1 => t.role = "polter-supervisor",
        0xa3 => t.hookless = .{ .known = .{ .label = "Claude Code", .session = true, .session_short = "0b1d1c35", .sure = true, .written_min = 3, .can_quit = true } },
        0xa5 => t.hookless = .unknown,
        else => {},
    };
    try w.bus.markOpenedByAgent(0xb1, 0xa1);
    try w.bus.markWorkerOf(0xb1, 0xa1);

    // One group tied to a project, the host not having said anything yet:
    // it is started by opening it, and how many pages it has is not known.
    _ = try w.chat.setProject("infra", .{ .bound = "infra" });
    _ = try w.chat.setLastSupervisor("billing", .{
        .dir = "",
        .dir_from = .none,
        .role = "polter-supervisor",
        .cli = "claude-code",
        .session = "s",
        .heard_ms = 1_699_999_340_000,
    });
    // Its last supervisor was in a CLI that is not installed here (task
    // 1744): a host says so, and the start is in one that is.
    _ = try w.chat.setLastSupervisor("docs-site", .{
        .dir = "",
        .dir_from = .none,
        .role = "polter-supervisor",
        .cli = "kimi",
        .session = "s-kimi",
        .heard_ms = 1_699_900_000_000,
    });
    _ = try w.chat.setLastSupervisor("notes", .{
        .dir = "",
        .dir_from = .none,
        .role = "polter-supervisor",
        .cli = "codex",
        .session = "s-before",
        .heard_ms = 1_699_913_600_000,
    });

    // The supervisor role set up for two CLIs, both plugins on and both
    // able to go on with a session (task 1677): `notes` was last in Codex
    // and `billing` in Claude Code, so a host has a group to show picking
    // the other one for, each way round.
    // And a third the role is set up for whose plugin is off, which the
    // snapshot says rather than drops.
    // And a fourth whose adapter says its program is not on this machine
    // (task 1744), which `legacy`'s last supervisor was in.
    w.roles = &.{.{ .key = "polter-supervisor", .name = "Polter Supervisor", .clis = &.{ "claude-code", "codex", "other-cli", "kimi" } }};
    w.cli_standings = &.{
        .{ .key = "claude-code", .standing = .ok },
        .{ .key = "codex", .standing = .ok },
        .{ .key = "other-cli", .standing = .plugin_off },
        .{ .key = "kimi", .standing = .not_installed },
    };
    w.cli_resume = .{ .read = &.{ "claude-code", "codex", "kimi" } };
    w.cli_names = &.{ .{ .key = "claude-code", .label = "Claude Code" }, .{ .key = "codex", .label = "Codex" }, .{ .key = "kimi", .label = "Kimi" } };

    // The control room asked web-app's supervisor for a report, and the
    // input line had a draft in it: being tried again (task 1671).
    try w.asks.asked(testing.allocator, "web-app", 41, error.DraftInLine, true);

    return w;
}

const fixture_wall: u64 = 1_700_000_000_000 + fixture_now;
const fixture_quota = [_]quota.Reading{
    .{
        .family = .claude,
        .state = .have,
        .windows = .{
            .{ .span = .five_hour, .used = 92, .resets_ms = fixture_wall + 40 * min },
            .{ .span = .seven_day, .used = 30, .resets_ms = fixture_wall + 3 * std.time.ms_per_day },
        },
        .at_ms = fixture_wall - 2 * min,
    },
    .{
        .family = .codex,
        .state = .have,
        .windows = .{
            .{ .span = .five_hour, .used = 20, .resets_ms = fixture_wall + 2 * std.time.ms_per_hour },
            null,
        },
        .at_ms = fixture_wall - 5 * min,
    },
};

fn fixtureRoom(w: *const World) !ControlRoom {
    _ = w;
    return .init(testing.allocator);
}

const fixture_now: u64 = 100 * min;
const fixture_json = @embedFile("testdata/control_snapshot.json");
const pretty: std.json.Stringify.Options = .{ .whitespace = .indent_2 };

fn rowNamed(s: Snapshot, name: []const u8) !GroupRow {
    for (s.groups) |g| if (std.mem.eql(u8, g.name, name)) return g;
    return error.TestRowMissing;
}

test "ControlRoom snapshot: the fixture is what the fixture's world comes to" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var room = try fixtureRoom(&w);
    defer room.deinit();
    var built = try room.compute(arena.allocator(), w.input(fixture_now));
    built.snapshot.rev = 1;
    const json = try writeAlloc(arena.allocator(), built.snapshot, pretty);
    const want = std.mem.trimEnd(u8, fixture_json, "\n");
    if (!std.mem.eql(u8, want, json)) {
        std.debug.print("\n<<<control_snapshot.json\n{s}\n>>>control_snapshot.json\n", .{json});
        return error.TestFixtureOutOfDate;
    }
}

test "ControlRoom: the question of joining the project of the group's name is put only while that is what is in the way (#1713)" {
    try testing.expect(askFor(.project_name_taken, .undecided, true));
    // "Not Now" said this run, or twice ever.
    try testing.expect(!askFor(.project_name_taken, .undecided, false));
    // Said yes or no already.
    try testing.expect(!askFor(.project_name_taken, .declined, true));
    try testing.expect(!askFor(.project_name_taken, .{ .bound = "polter" }, true));
    // Anything else in the way is not this question.
    for (std.enums.values(Projects.Why)) |why| {
        if (why == .project_name_taken) continue;
        try testing.expect(!askFor(why, .undecided, true));
    }
}

test "ControlRoom snapshot: a supervisor started by hand is said to be, on its frame, and only its own" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var room = try fixtureRoom(&w);
    defer room.deinit();
    const s = (try room.compute(arena.allocator(), w.input(fixture_now))).snapshot;

    const known = (try rowNamed(s, "docs-site")).supervisor.hookless;
    try testing.expectEqual(HooklessOut.State.known, known.state);
    try testing.expectEqualStrings("Claude Code", known.cli_label.?);
    try testing.expect(known.session);
    try testing.expectEqual(Say.Key.started_by_hand, known.note.?.key);

    const unknown = (try rowNamed(s, "design-system")).supervisor.hookless;
    try testing.expectEqual(HooklessOut.State.unknown, unknown.state);
    try testing.expectEqual(Say.Key.cli_not_recognised, unknown.note.?.key);
    try testing.expect(unknown.cli_label == null);

    // Everyone else: nothing said, and no words.
    for (s.groups) |g| {
        if (std.mem.eql(u8, g.name, "docs-site") or std.mem.eql(u8, g.name, "design-system")) continue;
        try testing.expectEqual(HooklessOut.State.none, g.supervisor.hookless.state);
        try testing.expect(g.supervisor.hookless.note == null);
    }

    // Asked about, not yet answered: said already -- that much is known.
    for (w.open.items) |*t| if (t.id == 0xa3) {
        t.hookless = .asking;
    };
    var room2 = try fixtureRoom(&w);
    defer room2.deinit();
    const s2 = (try room2.compute(arena.allocator(), w.input(fixture_now))).snapshot;
    try testing.expectEqual(Say.Key.started_by_hand, (try rowNamed(s2, "docs-site")).supervisor.hookless.note.?.key);
}

test "ControlRoom snapshot: the take-over is offered with the question it asks, and says how it goes (task 1635)" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const Look = struct {
        fn of(world: *World, a: Allocator) !TakeOverOut {
            var room = try fixtureRoom(world);
            defer room.deinit();
            const s = (try room.compute(a, world.input(fixture_now))).snapshot;
            return (try rowNamed(s, "docs-site")).supervisor.hookless.take_over;
        }
        fn set(world: *World, k: Hookless) void {
            for (world.open.items) |*t| if (t.id == 0xa3) {
                t.hookless = k;
            };
        }
    };
    const base: Hookless.Known = .{ .label = "Claude Code", .session = true, .session_short = "0b1d1c35", .sure = true, .written_min = 3, .can_quit = true };

    // Offered, going on with the session it found.
    var t = try Look.of(&w, aa);
    try testing.expectEqual(TakeOverOut.State.offer, t.state);
    try testing.expectEqual(Say.Key.take_over_confirm_sure, t.confirm.?.key);
    try testing.expectEqualStrings("0b1d1c35", t.confirm.?.args[1]);
    try testing.expectEqualStrings("3", t.confirm.?.args[2]);
    try testing.expect(t.status == null);

    // Its record stopped while it went on: the question says what that means.
    var k = base;
    k.sure = false;
    Look.set(&w, .{ .known = k });
    try testing.expectEqual(Say.Key.take_over_confirm_unsure, (try Look.of(&w, aa)).confirm.?.key);
    // No session: says it starts a new one, and does not pretend.
    k = base;
    k.session = false;
    k.session_short = "";
    Look.set(&w, .{ .known = k });
    t = try Look.of(&w, aa);
    try testing.expectEqual(Say.Key.take_over_confirm_new, t.confirm.?.key);
    try testing.expectEqual(@as(usize, 1), t.confirm.?.args.len);
    // No way to make it quit: not offered at all.
    k = base;
    k.can_quit = false;
    Look.set(&w, .{ .known = k });
    try testing.expectEqual(TakeOverOut.State.none, (try Look.of(&w, aa)).state);

    // Under way: no question, and what is happening.
    Look.set(&w, .{ .known = base });
    w.take_over = .{ .group = "docs-site", .state = .{ .running = .quitting } };
    t = try Look.of(&w, aa);
    try testing.expectEqual(TakeOverOut.State.running, t.state);
    try testing.expect(t.confirm == null);
    try testing.expectEqual(Say.Key.take_over_running, t.status.?.key);
    // ...and still said once the CLI has quit and is not recognised any more.
    Look.set(&w, .no);
    try testing.expectEqual(TakeOverOut.State.running, (try Look.of(&w, aa)).state);

    // Stopped: why, and offered again.
    Look.set(&w, .{ .known = base });
    w.take_over = .{ .group = "docs-site", .state = .{ .failed = .busy } };
    t = try Look.of(&w, aa);
    try testing.expectEqual(TakeOverOut.State.failed, t.state);
    try testing.expectEqual(Say.Key.take_over_busy, t.status.?.key);
    try testing.expect(t.confirm != null);
    // Another group's take-over is not this one's.
    w.take_over = .{ .group = "billing", .state = .{ .running = .settling } };
    try testing.expectEqual(TakeOverOut.State.offer, (try Look.of(&w, aa)).state);
}

test "ControlRoom snapshot: Fix is on the cards that read Failed, names who failed, and stands until they change" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var room = try fixtureRoom(&w);
    defer room.deinit();

    _ = try room.refresh(w.input(fixture_now), .event);
    var s = (try room.compute(arena.allocator(), w.input(fixture_now))).snapshot;
    for (s.groups) |g| {
        try testing.expectEqual(g.word == .failed, g.fix == .offered);
        if (g.word != .failed) try testing.expectEqual(ControlFix.State.none, g.fix);
    }
    for (s.ungrouped) |r| try testing.expectEqual(r.word == .failed, r.fix == .offered);

    // The supervisor of docs-site failed: the card is its, and so is the
    // one failure under it.
    try testing.expectEqual(ControlFix.State.offered, (try rowNamed(s, "docs-site")).fix);
    const card = room.fixCard(.{ .group = "docs-site" }) orelse return error.TestCardMissing;
    try testing.expectEqual(@as(?Id, 0xa3), card.steward);
    try testing.expectEqual(@as(usize, 1), card.failing.len);
    try testing.expectEqual(@as(Id, 0xa3), card.failing[0].id);
    try testing.expectEqualStrings("rate_limit", card.failing[0].what);
    try testing.expectEqualStrings("docs-site", card.failing[0].title);
    try testing.expectEqual(w.wall_ms + 98 * min, card.failing[0].at_wall_ms);
    // A card that does not read Failed is not one to fix.
    try testing.expectEqual(@as(?ControlFix.Card, null), room.fixCard(.{ .group = "billing" }));

    // Pressed: notified, until the card changes.
    try w.fix_sent.mark(testing.allocator, ControlFix.stampOf(card.steward, card.failing));
    s = (try room.compute(arena.allocator(), w.input(fixture_now))).snapshot;
    try testing.expectEqual(ControlFix.State.sent, (try rowNamed(s, "docs-site")).fix);

    // Its next turn clears the failure, and the button with it.
    try w.hook(0xa3, .turn_started, null, fixture_now + 1_000);
    s = (try room.compute(arena.allocator(), w.input(fixture_now + 2_000))).snapshot;
    try testing.expectEqual(ControlFix.State.none, (try rowNamed(s, "docs-site")).fix);

    // That turn fails too: a new moment, and the button again.
    var again: AgentEvent.Event = .none;
    again.event = .turn_failed;
    again.detail = "server_error";
    _ = try w.bus.agentEvent(0xa3, again, fixture_now + 3_000);
    s = (try room.compute(arena.allocator(), w.input(fixture_now + 4_000))).snapshot;
    try testing.expectEqual(ControlFix.State.offered, (try rowNamed(s, "docs-site")).fix);
}

test "ControlRoom snapshot: a worker's failure is fixed through its supervisor" {
    var w = try fixtureWorld();
    defer w.deinit();
    var room = try fixtureRoom(&w);
    defer room.deinit();

    try w.worker(0xb6, "tokens-2", 0x25, 0xa5, "design-system");
    try w.hook(0xb6, .turn_failed, "boom", fixture_now);
    // Its first minute is its supervisor's: the card does not read Failed.
    _ = try room.refresh(w.input(fixture_now + 1_000), .event);
    try testing.expectEqual(@as(?ControlFix.Card, null), room.fixCard(.{ .group = "design-system" }));

    _ = try room.refresh(w.input(fixture_now + 60_001), .event);
    const card = room.fixCard(.{ .group = "design-system" }) orelse return error.TestCardMissing;
    try testing.expectEqual(@as(?Id, 0xa5), card.steward);
    try testing.expectEqual(@as(usize, 1), card.failing.len);
    try testing.expectEqual(@as(Id, 0xb6), card.failing[0].id);
    try testing.expectEqualStrings("boom", card.failing[0].what);
}

test "ControlRoom snapshot: the JSON reads back and writes out the same" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const want = std.mem.trimEnd(u8, fixture_json, "\n");
    const read = try std.json.parseFromSliceLeaky(Snapshot, arena.allocator(), want, .{});
    try testing.expectEqualStrings(want, try writeAlloc(arena.allocator(), read, pretty));

    // And it is the document a host would be handed, not an empty one.
    try testing.expectEqual(@as(usize, 8), read.groups.len);
    try testing.expectEqual(@as(u64, 0xa1), read.groups[0].steward.?.id);
}

test "ControlRoom snapshot: rows come sorted, counted, and with what they draw" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    const order = [_][]const u8{ "web-app", "web-app-docs", "mobile", "billing", "docs-site", "infra", "design-system", "notes" };
    try testing.expectEqual(order.len, s.groups.len);
    for (order, s.groups) |name, g| try testing.expectEqualStrings(name, g.name);

    const kinds = [_]Attention.Kind{ .needs_approval, .needs_approval, .needs_approval, .needs_answer, .failed, .done_unseen, .working, .idle };
    const shown = [_]Attention.Shown{ .needs_you, .needs_you, .needs_you, .needs_you, .trouble, .done_unseen, .working, .none };
    for (kinds, shown, s.groups) |k, sh, g| {
        try testing.expectEqual(k, g.attention.kind);
        try testing.expectEqual(sh, g.shown);
        try testing.expectEqualStrings(g.word.text(), g.text);
    }

    try testing.expectEqual(@as(usize, 5), s.groups_needing_me);
    try testing.expectEqual(@as(usize, 3), s.groups_other);
}

test "ControlRoom snapshot: one supervisor in two groups is two rows, and one of them points at the other" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    // Five groups wait: five rows, and five on the Dock. 0xa1 is behind
    // two of them and is counted with each. The lone terminal that waits
    // is listed and is not in the number: no host draws it a row.
    try testing.expectEqual(@as(usize, 5), s.groups_needing_me);
    try testing.expectEqual(@as(usize, 1), s.ungrouped.len);
    try testing.expect(s.ungrouped[0].needs_me);
    try testing.expectEqual(@as(usize, 5), s.needs_me);

    // The row spoken in last carries the reason; the other points at it.
    const main = try rowNamed(s, "web-app");
    const docs = try rowNamed(s, "web-app-docs");
    try testing.expectEqualStrings("web-app-docs", main.same_as.?);
    try testing.expectEqual(@as(?[]const u8, null), docs.same_as);
    try testing.expectEqual(main.attention.terminal.?.id, docs.attention.terminal.?.id);
}

test "ControlRoom snapshot: the number on the Dock is the number of rows that wait" {
    // What a real window showed (verify-cr-03): four rows under "4 groups
    // waiting for you" and a 3 on the Dock. One supervisor minds two groups
    // and has failed; another group's supervisor and its worker have both
    // failed; a fourth group's only member has.
    var w: World = .init();
    defer w.deinit();
    var failed: AgentEvent.Event = .none;
    failed.event = .turn_failed;
    failed.detail = "rate_limit";
    try w.steward(0xa1, "A", 0x21, "docs-site");
    try w.chat.create("web-app", 0xa1);
    try w.steward(0xa2, "B", 0x22, "billing");
    try w.worker(0xb3, "W3", 0x23, 0xa2, "billing");
    try w.chat.create("notes", Chat.user_id);
    try w.terminal(0xd1, "N1", 0x24);
    try w.bus.watch(0xd1, 0xa2);
    try w.chat.add("notes", 0xd1, .all, .{});
    for ([_]Id{ 0xa1, 0xa2, 0xb3, 0xd1 }) |id| _ = try w.bus.agentEvent(id, failed, 10 * min);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(100 * min))).snapshot;

    var rows: usize = 0;
    for (s.groups) |g| {
        if (g.needs_me) rows += 1;
    }
    try testing.expectEqual(@as(usize, 4), rows);
    try testing.expectEqual(@as(usize, 4), s.groups_needing_me);
    // **The one meaning**: every row the person is shown as waiting, a
    // group's or a lone terminal's, is one.
    try testing.expectEqual(@as(usize, 4), s.needs_me);

    // Two rows, one supervisor, neither group spoken in: one of the two
    // still points at the other.
    const docs = try rowNamed(s, "docs-site");
    const web = try rowNamed(s, "web-app");
    try testing.expectEqual(docs.attention.terminal.?.id, web.attention.terminal.?.id);
    try testing.expect((docs.same_as == null) != (web.same_as == null));
}

test "ControlRoom snapshot: the reason line, and which kind of missing when there is none" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // An approval whose hook said nothing about what for.
    try w.steward(0xaa, "quiet", 0x2a, "quiet");
    try w.hook(0xaa, .awaiting_approval, null, 99 * min);
    // A turn that ended with no text kept.
    try w.steward(0xab, "silent", 0x2b, "silent");
    try w.hook(0xab, .turn_ended, null, 99 * min);

    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    const approval = (try rowNamed(s, "web-app-docs")).reason;
    try testing.expectEqual(Reason.From.hook_note, approval.from);
    // The hook's one-line summary: the first 120 bytes of the command.
    try testing.expectEqualStrings("rm -rf dist/ .cache/ node_modules/.vite && npm ci && npm run build -- --mode production", approval.text);

    try testing.expectEqualStrings("发票编号要按租户分开，还是全局连续？分开的话，旧发票要不要一起改编号？", (try rowNamed(s, "billing")).reason.text);
    // The error and what the agent said, put in the core's sentence: which
    // sentence and what goes in it for a host to say, and in English here.
    const failed = (try rowNamed(s, "docs-site")).reason;
    try testing.expectEqual(Say.Key.failed, failed.say.?.key);
    try testing.expectEqual(@as(usize, 2), failed.say.?.args.len);
    try testing.expectEqualStrings("rate_limit", failed.say.?.args[0]);
    try testing.expectEqualStrings("resets 13:40", failed.say.?.args[1]);
    try testing.expectEqualStrings("rate_limit: resets 13:40", failed.text);
    // And the row's line is that sentence, with it.
    try testing.expectEqual(Say.Key.failed, (try rowNamed(s, "docs-site")).what.say.?.key);
    // An agent's or a supervisor's own words are not the core's.
    try testing.expect((try rowNamed(s, "billing")).reason.say == null);
    // The last thing it said, which is where a question in prose is.
    try testing.expectEqualStrings("要不要现在切流量？", (try rowNamed(s, "infra")).reason.text);
    // What a working group says it is doing is the panel's word for it.
    const doing = (try rowNamed(s, "design-system")).reason;
    try testing.expectEqual(Reason.From.task, doing.from);
    try testing.expectEqualStrings("改按钮的三种尺寸", doing.text);
    try testing.expectEqual(Reason.none, (try rowNamed(s, "notes")).reason);

    const quiet = (try rowNamed(s, "quiet")).reason;
    try testing.expectEqualStrings("", quiet.text);
    try testing.expectEqual(@as(?Reason.Missing, .empty_note), quiet.missing);
    try testing.expectEqual(@as(?Reason.Missing, .no_turn_kept), (try rowNamed(s, "silent")).reason.missing);
}

test "ControlRoom snapshot: how many more are waiting, and a worker bubbling up" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The supervisor and its worker are both waiting: one more.
    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;
    try testing.expectEqual(@as(usize, 1), (try rowNamed(s, "web-app")).more);
    try testing.expectEqual(@as(usize, 0), (try rowNamed(s, "billing")).more);

    // A worker of a busy supervisor fails; a minute later the row is its.
    try w.worker(0xb6, "tokens-2", 0x25, 0xa5, "design-system");
    try w.hook(0xb6, .turn_failed, "boom", fixture_now);
    var at: u64 = fixture_now + 1_000;
    const early = try build(arena.allocator(), w.input(at));
    try testing.expectEqual(Attention.Kind.working, (try rowNamed(early.snapshot, "design-system")).attention.kind);
    // And the core knows to look again exactly when the minute is up:
    // following its own wake times lands on that moment, not past it.
    var wake = early.wake_ms;
    while (wake != null and wake.? < fixture_now + 60_001) {
        at = wake.?;
        wake = (try build(arena.allocator(), w.input(at))).wake_ms;
    }
    try testing.expectEqual(@as(?u64, fixture_now + 60_001), wake);

    const late = (try build(arena.allocator(), w.input(fixture_now + 60_001))).snapshot;
    const row = try rowNamed(late, "design-system");
    try testing.expectEqual(Attention.Kind.failed, row.attention.kind);
    try testing.expectEqual(@as(u64, 0xb6), row.attention.worker.?.id);
    try testing.expectEqualStrings("boom", row.reason.text);
}

test "ControlRoom snapshot: each window tab gets the highest glyph of what is in it" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    const Want = struct { u64, Attention.Shown, ?u64 };
    const wants = [_]Want{
        .{ 0x21, .needs_you, 0xa1 }, // supervisor and worker both waiting: the longer
        .{ 0x22, .needs_you, 0xa2 },
        .{ 0x23, .trouble, 0xa3 },
        .{ 0x24, .done_unseen, 0xa4 },
        .{ 0x25, .none, null }, // working is not drawn on a window tab
        .{ 0x26, .none, null },
        .{ 0x27, .needs_you, 0xc1 },
        .{ 0x28, .needs_you, 0xb7 }, // the worker waits; its supervisor does not
    };
    try testing.expectEqual(wants.len, s.tabs.len);
    for (wants, s.tabs) |want, tab| {
        try testing.expectEqual(want[0], tab.tab.id);
        try testing.expectEqual(want[1], tab.shown);
        try testing.expectEqual(want[2], if (tab.terminal) |t| t.id else null);
    }
    try testing.expectEqual(w.open.items.len, s.terminals.len);
}

test "ControlRoom snapshot: what a supervisor raises is waiting for the person at once, in its words, until they look" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "api", 0x21, "api");
    try w.hook(0xa1, .turn_started, null, 10 * min);
    try w.worker(0xb1, "api worker", 0x21, 0xa1, "api");
    // The worker stops on a prompt; inside its first minute the group is
    // still the supervisor's business and the row says working.
    try w.approval(0xb1, "Bash", "git push --force", 20 * min);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const at = 20 * min + 5_000;
    {
        const row = try rowNamed((try build(arena.allocator(), w.input(at))).snapshot, "api");
        try testing.expect(!row.needs_me);
    }

    // The supervisor reads it, decides it is the person's, and says so.
    const said = "api worker wants to force-push main: yours to decide";
    try testing.expect(try w.bus.raise(0xa1, at, said));
    {
        const s = (try build(arena.allocator(), w.input(at + 1))).snapshot;
        const row = try rowNamed(s, "api");
        try testing.expect(row.needs_me);
        // And looking at it is what withdraws it, so the row says so: this
        // is what a host starts its "seen" clock on.
        try testing.expect(row.unseen);
        try testing.expectEqual(Attention.Kind.needs_answer, row.attention.kind);
        try testing.expectEqual(Waiter.Is.supervisor, row.waiter.is);
        try testing.expectEqual(Reason.From.raised, row.reason.from);
        try testing.expectEqualStrings(said, row.reason.text);
        try testing.expectEqual(What.Form.words, row.what.form);
        try testing.expectEqual(@as(usize, 1), row.what.lines.len);
        try testing.expectEqualStrings(said, row.what.lines[0]);
        try testing.expectEqual(@as(usize, 1), s.groups_needing_me);
    }

    // It does not lapse because the supervisor's turn ended after it spoke
    // -- which is what a supervisor does next.
    try w.hook(0xa1, .turn_ended, "told the person", at + 2_000);
    {
        const row = try rowNamed((try build(arena.allocator(), w.input(at + 3_000))).snapshot, "api");
        try testing.expect(row.needs_me);
        try testing.expectEqual(Reason.From.raised, row.reason.from);
    }

    // The person looks. What is left is what is actually so: the worker's
    // prompt, still inside its first minute, and a supervisor that is done.
    try w.chat.markSeen("api", at + 4_000, w.wall_ms + at + 4_000);
    {
        const row = try rowNamed((try build(arena.allocator(), w.input(at + 5_000))).snapshot, "api");
        try testing.expect(row.reason.from != .raised);
        try testing.expect(row.attention.kind != .needs_answer);
        // Nothing left for looking to change: a worker's prompt is not
        // withdrawn by being looked at.
        try testing.expect(!row.unseen);
    }

    // A terminal the bus does not know raises nothing.
    try testing.expect(!try w.bus.raise(0xdead, at, "x"));
}

test "ControlRoom notifyRows: a worker's prompt over a supervisor that also waits, as the notifications read it" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "api", 0x21, "api");
    try w.hook(0xa1, .turn_started, null, 10 * min);
    try w.worker(0xb1, "api worker", 0x21, 0xa1, "api");
    try w.approval(0xb1, "Bash", "git push --force", 20 * min);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const at = 21 * min + 5_000;
    try testing.expect(try w.bus.raise(0xa1, at, "the worker has waited a minute: yours"));
    const s = (try build(arena.allocator(), w.input(at + 1))).snapshot;
    const rows = try notifyRows(arena.allocator(), s.groups);
    try testing.expectEqual(s.groups.len, rows.len);
    const r = for (rows) |r| {
        if (std.mem.eql(u8, r.group, "api")) break r;
    } else return error.TestUnexpectedResult;
    // The row is about the worker's prompt...
    try testing.expectEqual(Attention.Kind.needs_approval, r.top.kind);
    try testing.expectEqual(@as(?Id, 0xb1), r.top.terminal);
    try testing.expectEqual(@as(?Id, 0xa1), r.steward);
    try testing.expectEqualStrings("api worker", r.who);
    try testing.expect(!r.snoozed);
    // ...and the supervisor's own wait is carried beside it: that is the
    // thing the notifications call about while it lasts.
    const own = r.own orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Attention.Kind.needs_answer, own.kind);
    try testing.expectEqual(@as(?Id, 0xa1), own.terminal);
}

test "ControlRoom groupToShow: a supervisor goes to the group it minds, a worker to its group, anyone else to no group" {
    // `web` comes first, and the supervisor of `api` is a member there too:
    // the group it minds still wins, in either order.
    const web: RouteRow = .{ .group = "web", .steward = 0xc1, .members = &.{ 0xc1, 0xa1, 0xd1 } };
    const api: RouteRow = .{ .group = "api", .steward = 0xa1, .members = &.{ 0xa1, 0xb1 } };
    const unminded: RouteRow = .{ .group = "loose", .steward = null, .members = &.{0xf1} };
    for ([_][]const RouteRow{ &.{ web, api, unminded }, &.{ unminded, api, web } }) |rows| {
        const a1 = groupToShow(rows, 0xa1);
        try testing.expectEqualStrings("api", a1 orelse return error.TestUnexpectedResult);
        const b1 = groupToShow(rows, 0xb1);
        try testing.expectEqualStrings("api", b1 orelse return error.TestUnexpectedResult);
        const d1 = groupToShow(rows, 0xd1);
        try testing.expectEqualStrings("web", d1 orelse return error.TestUnexpectedResult);
        // A group nobody supervises is still the control room's row.
        const f1 = groupToShow(rows, 0xf1);
        try testing.expectEqualStrings("loose", f1 orelse return error.TestUnexpectedResult);
        const lone = groupToShow(rows, 0xe1);
        try testing.expect(lone == null);
    }
    // In two groups and supervising neither: the first, in the room's order.
    const twice = groupToShow(&.{ web, .{ .group = "ops", .steward = 0xc2, .members = &.{ 0xc2, 0xd1 } } }, 0xd1);
    try testing.expectEqualStrings("web", twice orelse return error.TestUnexpectedResult);
    try testing.expect(groupToShow(&.{}, 0xa1) == null);
}

test "ControlRoom routeRows: what the snapshot says of its groups is what a click is routed by" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "api", 0x21, "api");
    try w.worker(0xb1, "api worker", 0x21, 0xa1, "api");
    try w.terminal(0xe1, "a shell", 0x22);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(min))).snapshot;
    const rows = try routeRows(arena.allocator(), s.groups);
    try testing.expectEqual(s.groups.len, rows.len);
    const r = for (rows) |r| {
        if (std.mem.eql(u8, r.group, "api")) break r;
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(@as(?Id, 0xa1), r.steward);
    try testing.expect(std.mem.indexOfScalar(Id, r.members, 0xb1) != null);
    const b1 = groupToShow(rows, 0xb1);
    try testing.expectEqualStrings("api", b1 orelse return error.TestUnexpectedResult);
    const a1 = groupToShow(rows, 0xa1);
    try testing.expectEqualStrings("api", a1 orelse return error.TestUnexpectedResult);
    try testing.expect(groupToShow(rows, 0xe1) == null);
}

test "ControlRoom snapshot: a raise standing behind a worker's prompt is still withdrawn by looking" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "api", 0x21, "api");
    try w.hook(0xa1, .turn_started, null, 10 * min);
    try w.worker(0xb1, "api worker", 0x21, 0xa1, "api");
    // The worker's prompt has had its minute: the row is about it.
    try w.approval(0xb1, "Bash", "git push --force", 20 * min);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const at = 21 * min + 5_000;
    {
        const row = try rowNamed((try build(arena.allocator(), w.input(at))).snapshot, "api");
        try testing.expect(row.needs_me);
        try testing.expectEqual(Attention.Kind.needs_approval, row.attention.kind);
        try testing.expectEqual(@as(usize, 0), row.more);
        // A prompt is not withdrawn by being looked at.
        try testing.expect(!row.unseen);
    }

    // Now the supervisor raises it as well. The row stays about the prompt;
    // the raise is the "1 more".
    try testing.expect(try w.bus.raise(0xa1, at, "the worker has waited a minute: yours"));
    {
        const row = try rowNamed((try build(arena.allocator(), w.input(at + 1))).snapshot, "api");
        try testing.expectEqual(Attention.Kind.needs_approval, row.attention.kind);
        try testing.expect(row.reason.from != .raised);
        try testing.expectEqual(@as(usize, 1), row.more);
        // Looking changes this row, and it says so.
        try testing.expect(row.unseen);
    }

    // The person looks: the raise goes, the prompt stays.
    try w.chat.markSeen("api", at + 4_000, w.wall_ms + at + 4_000);
    {
        const row = try rowNamed((try build(arena.allocator(), w.input(at + 5_000))).snapshot, "api");
        try testing.expectEqual(Attention.Kind.needs_approval, row.attention.kind);
        try testing.expect(row.needs_me);
        try testing.expectEqual(@as(usize, 0), row.more);
        try testing.expect(!row.unseen);
    }
}

test "ControlRoom snapshot: a prompt the supervisor may not answer is the person's without the minute" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "api", 0x21, "api");
    try w.hook(0xa1, .turn_started, null, 10 * min);
    try w.worker(0xb1, "api worker", 0x21, 0xa1, "api");
    try w.approval(0xb1, "Bash", "npm ci", 20 * min);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const at = 20 * min + 5_000;

    // Allowed, the default: the supervisor's minute, and the core asks to
    // be woken when it is up.
    {
        const b = try build(arena.allocator(), w.input(at));
        try testing.expect(!(try rowNamed(b.snapshot, "api")).needs_me);
        try testing.expectEqual(@as(?u64, 20 * min + T.bubble_after_ms + 1), b.wake_ms);
    }

    // The person switches it off for that terminal: it is theirs now.
    try w.bus.setMayAuthorise(0xb1, false, .user);
    {
        const b = try build(arena.allocator(), w.input(at));
        const row = try rowNamed(b.snapshot, "api");
        try testing.expect(row.needs_me);
        try testing.expectEqual(Attention.Kind.needs_approval, row.attention.kind);
        try testing.expectEqual(Waiter.Is.worker_via_supervisor, row.waiter.is);
        // And nothing is waited for: there was no minute.
        try testing.expect(b.wake_ms == null or b.wake_ms.? != 20 * min + T.bubble_after_ms + 1);
    }
}

test "ControlRoom snapshot: seen in a group takes its finished turn off the list" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try w.chat.markSeen("infra", fixture_now, w.wall_ms + fixture_now);
    const s = (try build(arena.allocator(), w.input(fixture_now + 1))).snapshot;
    const row = try rowNamed(s, "infra");
    try testing.expectEqual(Attention.Kind.idle, row.attention.kind);
    try testing.expectEqual(@as(?u64, w.wall_ms + fixture_now), row.seen_ms);
    // And the tab it is in stops carrying the dot.
    for (s.tabs) |tab| {
        if (tab.tab.id == 0x24) try testing.expectEqual(Attention.Shown.none, tab.shown);
    }
}

test "ControlRoom snapshot: a timed snooze ends on its own, and the core knows when" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const wall = w.wall_ms + fixture_now;
    try w.chat.setSnooze("billing", .{ .until = .{ .at_ms = wall, .until_ms = wall + 20_000 } }, fixture_now);

    const during = try build(arena.allocator(), w.input(fixture_now));
    const row = try rowNamed(during.snapshot, "billing");
    try testing.expectEqual(Attention.Kind.snoozed, row.attention.kind);
    try testing.expect(!row.needs_me);
    // Four groups still wait; the lone terminal that does is in no count.
    try testing.expectEqual(@as(usize, 4), during.snapshot.needs_me);
    try testing.expectEqual(@as(?u64, fixture_now + 20_000), during.wake_ms);

    const after = try build(arena.allocator(), w.input(fixture_now + 20_000));
    try testing.expectEqual(Attention.Kind.needs_answer, (try rowNamed(after.snapshot, "billing")).attention.kind);
}

test "ControlRoom snapshot: a pinned group leads its own section and no other (task 1659)" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const before = (try build(arena.allocator(), w.input(fixture_now))).snapshot;
    // The last of the quiet half, and the last of the waiting half.
    const quiet_last = before.groups[before.groups.len - 1];
    try testing.expect(!quiet_last.needs_me);
    var waiting_last: ?GroupRow = null;
    for (before.groups) |g| {
        if (g.needs_me) waiting_last = g;
    }
    try testing.expect(waiting_last != null);
    for (before.groups) |g| try testing.expect(!g.pinned);

    try w.chat.setPinned(quiet_last.name, true);
    try w.chat.setPinned(waiting_last.?.name, true);
    const after = (try build(arena.allocator(), w.input(fixture_now))).snapshot;
    try testing.expectEqual(before.groups.len, after.groups.len);
    // The waiting half is still all above the quiet one.
    const first_quiet = for (after.groups, 0..) |g, i| {
        if (!g.needs_me) break i;
    } else after.groups.len;
    for (after.groups[0..first_quiet]) |g| try testing.expect(g.needs_me);
    for (after.groups[first_quiet..]) |g| try testing.expect(!g.needs_me);
    // And each pinned one is first in its half.
    try testing.expectEqualStrings(waiting_last.?.name, after.groups[0].name);
    try testing.expect(after.groups[0].pinned);
    try testing.expectEqualStrings(quiet_last.name, after.groups[first_quiet].name);
    try testing.expect(after.groups[first_quiet].pinned);
    // Everything else in the order it was.
    var rest_before: std.ArrayListUnmanaged([]const u8) = .empty;
    for (before.groups) |g| {
        if (!std.mem.eql(u8, g.name, quiet_last.name) and !std.mem.eql(u8, g.name, waiting_last.?.name))
            try rest_before.append(arena.allocator(), g.name);
    }
    var k: usize = 0;
    for (after.groups) |g| {
        if (g.pinned) continue;
        try testing.expectEqualStrings(rest_before.items[k], g.name);
        k += 1;
    }
}

test "ControlRoom snapshot: an archived group is off the list, out of every count, and its terminals are still its own (task 1659)" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const before = (try build(arena.allocator(), w.input(fixture_now))).snapshot;
    const was = try rowNamed(before, "billing");
    try testing.expect(was.needs_me);
    try testing.expectEqual(@as(usize, 0), before.archived.len);

    try w.chat.setArchived("billing", w.wall_ms + 5);
    const after = (try build(arena.allocator(), w.input(fixture_now))).snapshot;
    try testing.expectError(error.TestRowMissing, rowNamed(after, "billing"));
    try testing.expectEqual(before.groups.len - 1, after.groups.len);
    try testing.expectEqual(before.needs_me - 1, after.needs_me);
    try testing.expectEqual(after.groups_needing_me + after.groups_other, after.groups.len);
    try testing.expectEqual(@as(usize, 1), after.archived.len);
    try testing.expectEqualStrings("billing", after.archived[0].name);
    try testing.expectEqual(w.wall_ms + 5, after.archived[0].archived_ms);
    try testing.expectEqualStrings("/state/chat/billing", after.archived[0].record_dir);
    // Its members do not turn into terminals in no group.
    try testing.expectEqual(before.ungrouped.len, after.ungrouped.len);
    // Nothing is raised for it.
    for (try notifyRows(arena.allocator(), after.groups)) |r| try testing.expect(!std.mem.eql(u8, r.group, "billing"));

    try w.chat.setArchived("billing", null);
    const back = (try build(arena.allocator(), w.input(fixture_now))).snapshot;
    try testing.expectEqual(before.groups.len, back.groups.len);
    try testing.expectEqual(@as(usize, 0), back.archived.len);
}

test "ControlRoom snapshot: a mute says until when, keeps the card, holds back the notification and ends on its own (task 1659)" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const wall = w.wall_ms + fixture_now;
    try w.chat.setMute("billing", .{ .until = wall + 30_000 });
    const during = try build(arena.allocator(), w.input(fixture_now));
    const row = try rowNamed(during.snapshot, "billing");
    try testing.expectEqual(@as(?u64, wall + 30_000), row.muted.?.until_ms);
    // The card is what it was: still waiting, still counted.
    try testing.expect(row.needs_me);
    for (try notifyRows(arena.allocator(), during.snapshot.groups)) |r| {
        try testing.expectEqual(std.mem.eql(u8, r.group, "billing"), r.muted);
    }
    // Woken no later than when it ends.
    try testing.expect(during.wake_ms.? <= fixture_now + 30_000);

    const after = try build(arena.allocator(), w.input(fixture_now + 30_000));
    try testing.expect((try rowNamed(after.snapshot, "billing")).muted == null);

    try w.chat.setMute("billing", .forever);
    const ever = try build(arena.allocator(), w.input(fixture_now + 99_000_000));
    try testing.expectEqual(@as(?u64, null), (try rowNamed(ever.snapshot, "billing")).muted.?.until_ms);
}

test "ControlRoom snapshot: what deleting a group would take is counted for its dialog (task 1659)" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const s0 = (try build(arena.allocator(), w.input(fixture_now))).snapshot;
    const row0 = try rowNamed(s0, "billing");
    try testing.expectEqual(try w.chat.othersIn("billing"), row0.delete_cost.members);
    try testing.expectEqualStrings("/state/chat/billing", row0.record_dir);

    const open = try w.tasks.create("billing", "still to do", .feature);
    const done = try w.tasks.create("billing", "finished", .feature);
    try w.tasks.close(done);
    _ = open;
    const s1 = (try build(arena.allocator(), w.input(fixture_now))).snapshot;
    try testing.expectEqual(row0.delete_cost.open_tasks + 1, (try rowNamed(s1, "billing")).delete_cost.open_tasks);
}

test "ControlRoom snapshot: an ask being tried again says so, and says when it went in (task 1671)" {
    var w = try fixtureWorld();
    defer w.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    _ = try room.refresh(w.input(fixture_now), .event);
    const rev = room.rev;
    try testing.expect(std.mem.indexOf(u8, room.json, "\"ask\":{\"seq\":41,\"state\":\"retrying\",\"code\":\"DraftInLine\"}") != null);
    // Only web-app was asked anything.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, room.json, "\"ask\":{"));

    // The retry is typed in: a new snapshot says so.
    try testing.expect(w.asks.settled("web-app", 41, null));
    _ = try room.refresh(w.input(fixture_now), .event);
    try testing.expect(room.rev > rev);
    try testing.expect(std.mem.indexOf(u8, room.json, "\"ask\":{\"seq\":41,\"state\":\"delivered\",\"code\":null}") != null);
}

test "ControlRoom rev: standing still does not change it" {
    var w = try fixtureWorld();
    defer w.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    const first = try room.refresh(w.input(fixture_now), .event);
    try testing.expectEqual(@as(?u64, 1), first.notify);
    try testing.expectEqual(@as(u64, 1), room.rev);

    // Later in the same minute: every age has grown and nothing happened.
    const again = try room.refresh(w.input(fixture_now + 20_000), .event);
    try testing.expectEqual(@as(u64, 1), room.rev);
    try testing.expectEqual(@as(?u64, null), again.notify);
    // The JSON a host would fetch is current all the same.
    try testing.expect(std.mem.indexOf(u8, room.json, "\"now_ms\":6020000") != null);

    // Something does happen.
    try w.hook(0xa5, .awaiting_approval, "Bash(ls)", fixture_now + 21_000);
    const changed = try room.refresh(w.input(fixture_now + 21_000), .event);
    try testing.expectEqual(@as(u64, 2), room.rev);
    try testing.expectEqual(@as(?u64, 2), changed.notify);
}

test "ControlRoom rev: ten changes in a second are at most four notices" {
    var w = try fixtureWorld();
    defer w.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    var notices: usize = 0;
    var last_rev: u64 = 0;
    var t: u64 = fixture_now;
    var changes: usize = 0;
    // One change every 100 ms, and the timer honoured in between.
    while (t < fixture_now + 1_000) : (t += 10) {
        var out: Outcome = .{ .notify = null, .wake_ms = room.wake_ms };
        if ((t - fixture_now) % 100 == 0) {
            const kind: AgentEvent.Kind = if (changes % 2 == 0) .awaiting_approval else .turn_started;
            try w.hook(0xa6, kind, "Bash(x)", t);
            changes += 1;
            out = try room.refresh(w.input(t), .event);
        } else if (room.wake_ms != null and t >= room.wake_ms.?) {
            out = try room.refresh(w.input(t), .timer);
        }
        if (out.notify) |rev| {
            notices += 1;
            last_rev = rev;
        }
    }
    try testing.expectEqual(@as(usize, 10), changes);
    try testing.expect(notices <= 4);
    try testing.expectEqual(@as(usize, 4), notices);

    // Nothing is lost by waiting: the last word goes out once the gap ends.
    const tail = try room.refresh(w.input(fixture_now + 1_000), .timer);
    try testing.expectEqual(@as(?u64, room.rev), tail.notify);
    try testing.expect(room.rev > last_rev);
}

test "ControlRoom wake: when nothing can change on its own, nothing wakes" {
    var w: World = .init();
    defer w.deinit();
    // An approval that is snoozed until it changes, a finished turn, an
    // idle agent, a plain shell: only an event moves any of them.
    try w.steward(0xa1, "one", 0x21, "one");
    try w.hook(0xa1, .awaiting_approval, "Bash(x)", 1 * min);
    try w.chat.setSnooze("one", .{ .next_event = w.wall_ms + 2 * min }, 2 * min);
    try w.steward(0xa2, "two", 0x22, "two");
    try w.hook(0xa2, .turn_ended, "done", 1 * min);
    try w.steward(0xa3, "three", 0x23, "three");
    try w.hook(0xa3, .session_started, null, 1 * min);
    try w.terminal(0xc1, "zsh", 0x24);

    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();
    const first = try room.refresh(w.input(3 * min), .event);
    try testing.expectEqual(@as(?u64, null), first.wake_ms);
    try testing.expectEqual(@as(u64, 1), room.recomputes);

    // An hour of timer calls, were anybody to make them: not one recompute.
    var t: u64 = 3 * min;
    while (t < 63 * min) : (t += 1_000) {
        const out = try room.refresh(w.input(t), .timer);
        try testing.expectEqual(@as(?u64, null), out.wake_ms);
        try testing.expectEqual(@as(?u64, null), out.notify);
    }
    try testing.expectEqual(@as(u64, 1), room.recomputes);
}

test "ControlRoom wake: a threshold is woken for once, at the moment it is crossed" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "one", 0x21, "one");
    try w.worker(0xb1, "w", 0x21, 0xa1, "one");
    try w.hook(0xb1, .turn_started, null, 1 * min);
    try w.hook(0xa1, .session_started, null, 1 * min);
    w.bus.noteSampling(0xb1, true, 1 * min);
    w.bus.noteQuiet(0xb1, 0, 2 * min);

    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();
    const first = try room.refresh(w.input(2 * min), .event);
    // Still since 2:00, so T1 is crossed at 5:00.
    try testing.expectEqual(@as(?u64, 5 * min), first.wake_ms);

    // Before it: asked, and nothing is worked out.
    _ = try room.refresh(w.input(4 * min), .timer);
    try testing.expectEqual(@as(u64, 1), room.recomputes);
    try testing.expectEqual(@as(u64, 1), room.rev);

    // At it: the worker is suspect, and that is a change.
    const crossed = try room.refresh(w.input(5 * min), .timer);
    try testing.expectEqual(@as(u64, 2), room.recomputes);
    try testing.expectEqual(@as(?u64, 2), crossed.notify);
    try testing.expect(std.mem.indexOf(u8, room.json, "\"kind\":\"suspect_stuck\"") != null);
}

test "ControlRoom Say: a still screen is the core's sentence, with its minutes" {
    var w: World = .init();
    defer w.deinit();
    // A worker in no group, minded by a supervisor, working by its hooks,
    // its screen still since 1:00.
    try w.terminal(0xa1, "boss", 0x21);
    try w.bus.addSupervisor(0xa1);
    try w.terminal(0xc1, "w", 0x22);
    try w.bus.watch(0xc1, 0xa1);
    try w.hook(0xa1, .session_started, null, 1 * min);
    try w.hook(0xc1, .turn_started, null, 1 * min);
    w.bus.noteSampling(0xc1, true, 1 * min);
    w.bus.noteQuiet(0xc1, 0, 1 * min);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // At 5:00 that is four minutes, past the common three.
    const s = (try build(arena.allocator(), w.input(5 * min))).snapshot;
    const row = for (s.ungrouped) |l| {
        if (l.attention.kind == .suspect_stuck) break l;
    } else return error.TestRowMissing;
    const said = row.what.say orelse return error.TestNoSentence;
    try testing.expectEqual(Say.Key.still, said.key);
    try testing.expectEqual(@as(usize, 1), said.args.len);
    try testing.expectEqualStrings("4", said.args[0]);
    // On the line, in English, filled in.
    try testing.expectEqualStrings("Screen still for 4 min", row.what.lines[0]);
    try testing.expectEqual(Say.Key.still, row.reason.say.?.key);
}

test "ControlRoom Say: a template is filled by position, and a placeholder with nothing for it is left" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Screen still for 3 min, no tool call for 7 min", try Say.fill(a, Say.templateOf(.still_and_silent), &.{ "3", "7" }));
    // A translation may put them the other way round.
    try testing.expectEqualStrings("7 then 3", try Say.fill(a, "{2} then {1}", &.{ "3", "7" }));
    // Missing an argument: shown as written, not a crash and not a blank.
    try testing.expectEqualStrings("still {1} and {2}", try Say.fill(a, "still {1} and {2}", &.{}));
    // An argument is put in as it is, braces and all.
    try testing.expectEqualStrings("x: {1}", try Say.fill(a, "x: {1}", &.{"{1}"}));
    try testing.expectEqualStrings("{0} {10}", try Say.fill(a, "{0} {10}", &.{"no"}));
}

test "ControlRoom pulses: one waiting glyph breathes, the longest-waiting, and the order is given" {
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    // Waiting for the person: 0xa2 since 89, 0xa1 since 96, 0xb7 since 97,
    // 0xc1 since 99, 0xb1 since 99:30. Failed (0xa3) is trouble, and is not
    // in this.
    const order = [_]u64{ 0xa2, 0xa1, 0xb7, 0xc1, 0xb1 };
    try testing.expectEqual(order.len, s.pulses.len);
    for (order, s.pulses) |id, p| try testing.expectEqual(id, p.terminal.id);

    // Each says where it is, which is all a host compares.
    try testing.expectEqual(@as(u64, 0x22), s.pulses[0].tab.?.id);
    try testing.expectEqual(@as(u64, 0x10), s.pulses[0].window.?.id);

    // And which row is about it: the one that carries the reason when its
    // supervisor has two, none for a terminal in no row.
    try testing.expectEqualStrings("billing", s.pulses[0].group.?);
    try testing.expectEqualStrings("web-app-docs", s.pulses[1].group.?);
    try testing.expectEqualStrings("mobile", s.pulses[2].group.?);
    try testing.expectEqual(@as(?[]const u8, null), s.pulses[3].group);
    try testing.expectEqual(@as(?[]const u8, null), s.pulses[4].group);
}

test "ControlRoom waiter: the supervisor itself, a worker through it, a worker with none, a terminal alone" {
    var w = try fixtureWorld();
    defer w.deinit();
    // A group with no supervisor in it, whose one worker -- minded by
    // somebody outside the group -- is waiting.
    try w.chat.create("orphans", Chat.user_id);
    try w.terminal(0xd1, "lint", 0x2c);
    try w.bus.watch(0xd1, 0xa1);
    try w.chat.add("orphans", 0xd1, .all, .{});
    // Long enough ago that the wait has come up to the row.
    try w.approval(0xd1, "Bash", "npm run lint", 90 * min);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    const own = (try rowNamed(s, "web-app")).waiter;
    try testing.expectEqual(Waiter.Is.supervisor, own.is);
    try testing.expectEqualStrings("", own.name);

    // The row is about the worker, and says whose wait it is by name.
    const through = try rowNamed(s, "mobile");
    try testing.expectEqual(@as(u64, 0xb7), through.attention.terminal.?.id);
    try testing.expectEqual(Waiter.Is.worker_via_supervisor, through.waiter.is);
    try testing.expectEqualStrings("ios-build", through.waiter.name);

    const alone = (try rowNamed(s, "orphans")).waiter;
    try testing.expectEqual(Waiter.Is.worker, alone.is);
    try testing.expectEqualStrings("lint", alone.name);

    try testing.expectEqual(Waiter.Is.terminal, s.ungrouped[0].waiter.is);
    // Nobody is waiting on a row that needs nothing, whoever it is about.
    for (s.groups) |g| {
        if (!g.needs_me) try testing.expectEqual(Waiter.Is.none, g.waiter.is);
        if (g.needs_me) try testing.expect(g.waiter.is != .none);
    }
}

test "ControlRoom what: a command is its steps, a file is one piece, words are words" {
    var w = try fixtureWorld();
    defer w.deinit();
    // A tool that is not a shell asks for a file whose name has a `;` in it.
    try w.steward(0xaa, "editor", 0x2a, "editing");
    try w.approval(0xaa, "Edit", "src/a;b && c.ts", 99 * min);
    // PowerShell's rules are not the ones the cutter knows: one piece.
    try w.steward(0xab, "win", 0x2b, "windows");
    try w.approval(0xab, "PowerShell", "Remove-Item dist; npm ci", 99 * min);
    // A command the hook sent only the summary of.
    try w.steward(0xac, "old", 0x2c, "summary-only");
    var ev: AgentEvent.Event = .none;
    ev.event = .awaiting_approval;
    ev.detail = "Bash";
    ev.note = "make clean && make";
    _ = try w.bus.agentEvent(0xac, ev, 99 * min);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(fixture_now))).snapshot;

    const command = (try rowNamed(s, "web-app")).what;
    try testing.expectEqual(What.Form.command, command.form);
    try testing.expectEqual(@as(usize, 3), command.lines.len);
    try testing.expectEqualStrings("rm -rf dist/ .cache/ node_modules/.vite", command.lines[0]);
    try testing.expectEqualStrings("&& npm ci", command.lines[1]);
    try testing.expectEqualStrings("&& npm run build -- --mode production", command.lines[2]);

    const file = (try rowNamed(s, "editing")).what;
    try testing.expectEqual(What.Form.code, file.form);
    try testing.expectEqual(@as(usize, 1), file.lines.len);
    try testing.expectEqualStrings("src/a;b && c.ts", file.lines[0]);

    const posh = (try rowNamed(s, "windows")).what;
    try testing.expectEqual(What.Form.code, posh.form);
    try testing.expectEqualStrings("Remove-Item dist; npm ci", posh.lines[0]);

    const summary = (try rowNamed(s, "summary-only")).what;
    try testing.expectEqual(What.Form.command, summary.form);
    try testing.expectEqual(@as(usize, 2), summary.lines.len);

    const question = (try rowNamed(s, "billing")).what;
    try testing.expectEqual(What.Form.words, question.form);
    try testing.expectEqual(@as(usize, 1), question.lines.len);

    try testing.expectEqual(What.Form.words, (try rowNamed(s, "docs-site")).what.form);
    try testing.expectEqual(What.none.form, (try rowNamed(s, "notes")).what.form);
    try testing.expectEqual(@as(usize, 0), (try rowNamed(s, "notes")).what.lines.len);
}

test "ControlRoom what: a command longer than the hook's summary is whole, every step of it" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "boss", 0x21, "long");
    // 31 steps; the summary a hook cuts stops inside the eighth.
    var command: std.ArrayListUnmanaged(u8) = .empty;
    defer command.deinit(testing.allocator);
    try command.appendSlice(testing.allocator, "echo step-00");
    for (1..30) |n| try command.print(testing.allocator, " && echo step-{d:0>2}", .{n});
    try command.appendSlice(testing.allocator, " && rm -rf /srv/data");
    try w.approval(0xa1, "Bash", command.items, 1 * min);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const row = try rowNamed((try build(arena.allocator(), w.input(2 * min))).snapshot, "long");
    try testing.expect(row.reason.text.len <= 120);
    try testing.expectEqual(@as(usize, 31), row.what.lines.len);
    // The last step is the one that matters, and it is there.
    try testing.expectEqualStrings("&& rm -rf /srv/data", row.what.lines[30]);

    // Once it is no longer waiting, what it was waiting for is not kept.
    try w.hook(0xa1, .turn_started, null, 3 * min);
    try testing.expectEqual(@as(?[]const u8, null), w.bus.askOf(0xa1));
}

test "ControlRoom what: a question is whole, and a part of one is never passed off as all of it" {
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A dialog: the hook sends a first line and all of it. Longer than the
    // 160 bytes the bus keeps of a note.
    var long: std.ArrayListUnmanaged(u8) = .empty;
    for (0..30) |_| try long.appendSlice(a, "发票编号要按租户分开吗？");
    try w.steward(0xa1, "one", 0x21, "dialog");
    var dialog: AgentEvent.Event = .none;
    dialog.event = .awaiting_input;
    dialog.note = AgentEvent.prefixChars(long.items, AgentEvent.summary_chars);
    dialog.text = long.items;
    dialog.text_bytes = long.items.len;
    _ = try w.bus.agentEvent(0xa1, dialog, 10 * min);

    // Asked in prose: the turn ends on a question and the hook then says
    // only that it is waiting.
    try w.steward(0xa2, "two", 0x22, "prose");
    try w.hook(0xa2, .turn_ended, "迁移脚本写完了，12 条测试全过。\n\n有两件事要你定：\n先切一半流量，还是一次切完？", 10 * min);
    try w.hook(0xa2, .awaiting_input, null, 11 * min);

    // The same, when the question is all there was.
    try w.steward(0xa3, "three", 0x23, "only");
    try w.hook(0xa3, .turn_ended, "先切一半流量，还是一次切完？\n", 10 * min);
    try w.hook(0xa3, .awaiting_input, null, 11 * min);

    // A note as long as the bus keeps one and nothing else: it may have
    // been cut, and the row says so.
    try w.steward(0xa4, "four", 0x24, "capped");
    try w.hook(0xa4, .awaiting_input, "x" ** 200, 10 * min);
    // A short note is all of it.
    try w.steward(0xa5, "five", 0x25, "short");
    try w.hook(0xa5, .awaiting_input, "用哪个分支？", 10 * min);

    const s = (try build(a, w.input(100 * min))).snapshot;

    const whole = (try rowNamed(s, "dialog")).what;
    try testing.expectEqual(What.Form.words, whole.form);
    try testing.expectEqualStrings(long.items, whole.lines[0]);
    try testing.expectEqual(What.Cut.none, whole.cut);
    try testing.expect(whole.lines[0].len > 160);

    const prose = try rowNamed(s, "prose");
    try testing.expectEqual(Reason.From.last_turn, prose.reason.from);
    try testing.expectEqualStrings("有两件事要你定： 先切一半流量，还是一次切完？", prose.what.lines[0]);
    try testing.expectEqual(What.Cut.head, prose.what.cut);

    const only = (try rowNamed(s, "only")).what;
    try testing.expectEqualStrings("先切一半流量，还是一次切完？", only.lines[0]);
    try testing.expectEqual(What.Cut.none, only.cut);

    const capped = (try rowNamed(s, "capped")).what;
    try testing.expectEqual(@as(usize, 160), capped.lines[0].len);
    try testing.expectEqual(What.Cut.tail, capped.cut);

    try testing.expectEqual(What.Cut.none, (try rowNamed(s, "short")).what.cut);

    // The question is forgotten with the wait: a new turn, and nothing of
    // it is left to show beside whatever comes next.
    try w.hook(0xa1, .turn_started, null, 101 * min);
    try testing.expect(w.bus.askOf(0xa1) == null);
}

test "ControlRoom what: a working group says its own started task, and nothing when it has none" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "boss", 0x21, "busy");
    try w.hook(0xa1, .turn_started, null, 1 * min);
    try w.worker(0xb1, "helper", 0x21, 0xa1, "busy");

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // No task of its own: nothing is said.
    const bare = try rowNamed((try build(arena.allocator(), w.input(2 * min))).snapshot, "busy");
    try testing.expectEqual(Attention.Kind.working, bare.attention.kind);
    try testing.expectEqual(What.Form.none, bare.what.form);

    // Somebody else's started task, and one of its own not started: still nothing.
    try w.working("busy", 0xb1, "the helper's task");
    const queued = try w.tasks.create("busy", "not started yet", .feature);
    try w.tasks.assign(queued, 0xa1);
    const other = try rowNamed((try build(arena.allocator(), w.input(2 * min))).snapshot, "busy");
    try testing.expectEqual(What.Form.none, other.what.form);

    // Its own, started: that title; and the newer of two.
    try w.working("busy", 0xa1, "first thing");
    try w.working("busy", 0xa1, "second thing");
    const doing = try rowNamed((try build(arena.allocator(), w.input(2 * min))).snapshot, "busy");
    try testing.expectEqual(Reason.From.task, doing.reason.from);
    try testing.expectEqualStrings("second thing", doing.what.lines[0]);
}

test "ControlRoom snapshot: nothing in it says how long, and nothing wakes it to count minutes" {
    var w = try fixtureWorld();
    defer w.deinit();
    // The one thing that does count down is an allowance close to its
    // limit, which has a test of its own below.
    w.quota = &.{};
    var room = try fixtureRoom(&w);
    defer room.deinit();

    const first = try room.refresh(w.input(fixture_now), .event);
    try testing.expect(first.notify != null);
    inline for (.{ "waited_min", "\"band\"", "total_min", "start_label", "lanes", "spans" }) |gone| {
        try testing.expect(std.mem.indexOf(u8, room.json, gone) == null);
    }

    // Five rows are waiting. An hour of looking again, were anybody to: the
    // snapshot is worked out only when something in it can have changed,
    // and never once a minute.
    const before = room.recomputes;
    var t: u64 = fixture_now;
    var notices: usize = 0;
    while (t < fixture_now + 60 * min) : (t += 1_000) {
        const out = try room.refresh(w.input(t), .timer);
        if (out.notify != null) notices += 1;
    }
    try testing.expect(room.recomputes - before < 10);
    try testing.expectEqual(@as(usize, 0), notices);
}

test "ControlRoom quota: an allowance close to its limit is woken for once a minute, and an ordinary one not at all" {
    var w = try fixtureWorld();
    defer w.deinit();
    var room = try fixtureRoom(&w);
    defer room.deinit();

    // Forty minutes to the reset: forty changes of the number, the reset
    // itself, and nothing between them.
    _ = try room.refresh(w.input(fixture_now), .event);
    try testing.expect(std.mem.indexOf(u8, room.json, "\"when\":{\"form\":\"minutes\",\"n\":40}") != null);
    var before = room.recomputes;
    var t: u64 = fixture_now;
    var notices: usize = 0;
    while (t < fixture_now + 39 * min + 30_000) : (t += 1_000) {
        const out = try room.refresh(w.input(t), .timer);
        if (out.notify != null) notices += 1;
    }
    const counted = notices;
    try testing.expectEqual(@as(usize, 39), counted);
    try testing.expect(room.recomputes - before < 50);
    try testing.expect(std.mem.indexOf(u8, room.json, "\"when\":{\"form\":\"minutes\",\"n\":1}") != null);

    // An account with room, its number just taken: most of an hour of
    // looking again finds nothing to say.
    const calm = [_]quota.Reading{
        .{
            .family = .claude,
            .state = .have,
            .windows = .{ .{ .span = .five_hour, .used = 30, .resets_ms = fixture_wall + 4 * std.time.ms_per_hour }, null },
            .at_ms = fixture_wall,
        },
    };
    w.quota = &calm;
    var again = try fixtureRoom(&w);
    defer again.deinit();
    _ = try again.refresh(w.input(fixture_now), .event);
    before = again.recomputes;
    t = fixture_now;
    notices = 0;
    while (t < fixture_now + 59 * min) : (t += 1_000) {
        const out = try again.refresh(w.input(t), .timer);
        if (out.notify != null) notices += 1;
    }
    const quiet = notices;
    try testing.expectEqual(@as(usize, 0), quiet);
    try testing.expect(again.recomputes - before < 10);
}

test "ControlRoom snapshot: a terminal with its own idea of still is judged by it" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "one", 0x21, "one");
    try w.worker(0xb1, "w", 0x21, 0xa1, "one");
    w.bus.noteSampling(0xb1, true, 0);
    w.bus.noteQuiet(0xb1, 0, 1 * min);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Still for one minute: under the common three, so it is working.
    const common = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    try testing.expectEqual(Attention.Kind.working, common.terminals[1].kind);

    // Given thirty seconds of its own, the same minute is past it.
    w.open.items[1].still_ms = 30_000;
    const own = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    try testing.expectEqual(Attention.Kind.quiet_unknown, own.terminals[1].kind);
}

test "ControlRoom open_on: the first group with an agent in it, not an empty one before it" {
    var w: World = .init();
    defer w.deinit();
    // Three idle groups. The first is the person's own with nobody in it,
    // the second holds a plain shell, and only the third has an agent.
    try w.chat.create("aaa-empty", Chat.user_id);
    try w.chat.create("bbb-shell", Chat.user_id);
    try w.terminal(0xc1, "zsh", 0x21);
    try w.chat.add("bbb-shell", 0xc1, .all, .{});
    try w.steward(0xa1, "boss", 0x22, "ccc-minded");
    // Heard from a minute in, so its row is younger than the empty ones
    // and sorts after them: an agent's group is not always first.
    try w.hook(0xa1, .session_started, null, 1 * min);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    // The first row is the shell's group, which has no agent in it.
    try testing.expectEqualStrings("bbb-shell", s.groups[0].name);
    try testing.expectEqualStrings("ccc-minded", s.open_on.?);
}

test "ControlRoom open_on: the first group when every one is empty, and none when there are none" {
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const none = (try build(arena.allocator(), w.input(1 * min))).snapshot;
    try testing.expectEqual(@as(?[]const u8, null), none.open_on);

    try w.chat.create("zzz-empty", Chat.user_id);
    try w.chat.create("mmm-empty", Chat.user_id);
    const empty = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    try testing.expectEqualStrings("mmm-empty", empty.groups[0].name);
    try testing.expectEqualStrings("mmm-empty", empty.open_on.?);
}

test "ControlRoom open_on: a group whose agent's terminal is closed counts as empty" {
    var w: World = .init();
    defer w.deinit();
    try w.steward(0xa1, "gone", 0x21, "aaa-closed");
    try w.steward(0xa2, "here", 0x22, "bbb-open");
    // Put off, so its row comes after the one nobody is minding.
    try w.chat.setSnooze("bbb-open", .{ .next_event = w.wall_ms + 1 * min }, 1 * min);
    // 0xa1's tab is closed: it is in the group still, and not open.
    for (w.open.items, 0..) |t, i| {
        if (t.id == 0xa1) {
            _ = w.open.orderedRemove(i);
            break;
        }
    }

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    try testing.expectEqualStrings("aaa-closed", s.groups[0].name);
    try testing.expectEqualStrings("bbb-open", s.open_on.?);
}

test "ControlRoom snapshot: a worker minded outside any group is listed on its own" {
    var w: World = .init();
    defer w.deinit();
    try w.terminal(0xa1, "boss", 0x21);
    try w.bus.addSupervisor(0xa1);
    try w.terminal(0xb1, "stray", 0x22);
    try w.bus.watch(0xb1, 0xa1);
    try w.hook(0xb1, .awaiting_approval, "Bash(x)", 1 * min);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    try testing.expectEqual(@as(usize, 2), s.ungrouped.len);
    try testing.expectEqual(@as(u64, 0xb1), s.ungrouped[0].id.id);
    try testing.expect(s.ungrouped[0].needs_me);
    // Listed, and in no count: it has no row (task 1485).
    try testing.expectEqual(@as(usize, 0), s.needs_me);
    try testing.expectEqual(@as(?u64, 1 * min), s.ungrouped[0].attention.event_ms);
}

test "ControlRoom bar: a held terminal's title says held, unless somebody is waiting on it" {
    // Every glyph a terminal can have, held and not.
    for (std.enums.values(Attention.Kind)) |kind| {
        const d = Attention.displayOf(kind);
        const free: Bar = .of(d, false);
        const held: Bar = .of(d, true);
        // Not held: the status, glyph and words, as a row would have it.
        try testing.expectEqualStrings(@tagName(d.shown), @tagName(free.shown));
        try testing.expectEqualStrings(d.word.text(), free.text);
        switch (d.shown) {
            // Waiting or in trouble: being held changes nothing.
            .needs_you, .trouble => {
                try testing.expectEqual(free.shown, held.shown);
                try testing.expectEqualStrings(free.text, held.text);
            },
            // Working, finished unseen, nothing to say: it says held.
            .done_unseen, .working, .none => {
                try testing.expectEqual(Bar.Shown.held, held.shown);
                try testing.expectEqualStrings(Attention.held_text, held.text);
            },
        }
    }
    // All four of the brief's, by name, so that a change of the table above
    // cannot quietly take one of them out of the loop.
    try testing.expectEqual(Bar.Shown.needs_you, Bar.of(Attention.displayOf(.needs_approval), true).shown);
    try testing.expectEqual(Bar.Shown.needs_you, Bar.of(Attention.displayOf(.needs_answer), true).shown);
    try testing.expectEqual(Bar.Shown.trouble, Bar.of(Attention.displayOf(.failed), true).shown);
    try testing.expectEqual(Bar.Shown.held, Bar.of(Attention.displayOf(.working), true).shown);
    try testing.expectEqual(Bar.Shown.held, Bar.of(Attention.displayOf(.done_unseen), true).shown);
    try testing.expectEqual(Bar.Shown.held, Bar.of(Attention.displayOf(.idle), true).shown);
    try testing.expectEqual(Bar.Shown.working, Bar.of(Attention.displayOf(.working), false).shown);
}

test "ControlRoom bar: the snapshot carries it for every terminal, and a row's glyph is not changed by it" {
    var w: World = .init();
    defer w.deinit();
    try w.terminal(0xa1, "boss", 0x21);
    try w.bus.addSupervisor(0xa1);
    // Two workers, both held: one working, one stopped on an approval.
    try w.terminal(0xb1, "busy", 0x21);
    try w.bus.watch(0xb1, 0xa1);
    try w.hook(0xb1, .turn_started, "", 1 * min);
    try w.bus.setHeld(0xb1, true, .user);
    try w.terminal(0xb2, "asking", 0x21);
    try w.bus.watch(0xb2, 0xa1);
    try w.hook(0xb2, .awaiting_approval, "Bash(x)", 1 * min);
    try w.bus.setHeld(0xb2, true, .user);
    // And one working that nobody holds.
    try w.terminal(0xb3, "free", 0x21);
    try w.bus.watch(0xb3, 0xa1);
    try w.hook(0xb3, .turn_started, "", 1 * min);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    const Want = struct { u64, Bar.Shown, []const u8, Attention.Shown };
    for ([_]Want{
        .{ 0xb1, .held, Attention.held_text, .working },
        .{ 0xb2, .needs_you, Attention.Word.needs_approval.text(), .needs_you },
        .{ 0xb3, .working, Attention.Word.working.text(), .working },
    }) |want| {
        const t = for (s.terminals) |t| {
            if (t.id.id == want[0]) break t;
        } else return error.TestTerminalMissing;
        try testing.expectEqual(want[1], t.bar.shown);
        try testing.expectEqualStrings(want[2], t.bar.text);
        // What a row and a window tab draw is the status, held or not.
        try testing.expectEqual(want[3], t.shown);
        try testing.expect(t.held == (want[0] != 0xb3));
    }
}

test "ControlRoom terminals: each says which frame its pane wears" {
    var w: World = .init();
    defer w.deinit();
    try w.terminal(0xa1, "boss", 0x21);
    try w.bus.addSupervisor(0xa1);
    try w.terminal(0xb1, "minded", 0x21);
    try w.bus.watch(0xb1, 0xa1);
    try w.terminal(0xc1, "zsh", 0x21);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    try testing.expectEqual(@as(usize, 3), s.terminals.len);
    const Want = struct { u64, Pane };
    for ([_]Want{ .{ 0xa1, .supervisor }, .{ 0xb1, .worker }, .{ 0xc1, .plain } }) |want| {
        const got: ?Pane = for (s.terminals) |t| {
            if (t.id.id == want[0]) break t.pane;
        } else null;
        try testing.expectEqual(@as(?Pane, want[1]), got);
    }
}

/// The size section 13.2 of the design names: 32 groups, 128 terminals, with
/// a bit of everything in them.
fn benchWorld() !World {
    var w: World = .init();
    errdefer w.deinit();

    const kinds = [_]AgentEvent.Kind{ .awaiting_approval, .awaiting_input, .turn_failed, .turn_ended, .turn_started, .session_started };
    var names: [32][16]u8 = undefined;
    for (0..32) |g| {
        const name = try std.fmt.bufPrint(&names[g], "group-{d:0>2}", .{g});
        const boss: Id = 0x1000 + g;
        try w.steward(boss, "supervisor", 0x100 + g, name);
        try w.hook(boss, kinds[g % kinds.len], "Bash(rm -rf dist/ && npm run build)", (40 + g) * min);
        for (0..3) |n| {
            const id: Id = 0x2000 + g * 4 + n;
            try w.worker(id, "worker", 0x100 + g, boss, name);
            try w.hook(id, kinds[(g + n + 1) % kinds.len], "Edit(src/app.ts)", (50 + n) * min);
            w.bus.noteSampling(id, true, 60 * min);
            w.bus.noteQuiet(id, (g % 5) * min, 90 * min);
            w.bus.noteCall(id, 80 * min);
        }
    }
    return w;
}

test "ControlRoom bench: 32 groups and 128 terminals, worked out and written" {
    // Not a gate: it asserts only that the world is the size it says, and
    // prints how long things took. The figure that means anything is the
    // release one:
    //
    //   zig build test -Doptimize=ReleaseFast -Dtest-filter="ControlRoom bench" \
    //     -Demit-macos-app=false -Demit-xcframework=false --summary all
    const builtin = @import("builtin");
    const rounds: usize = if (builtin.mode == .Debug) 20 else 2000;

    var w = try benchWorld();
    defer w.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const Lap = struct {
        fn ns(clock: std.Io, from: std.Io.Timestamp) u64 {
            const now: std.Io.Timestamp = .now(clock, .awake);
            return @intCast(from.durationTo(now).nanoseconds);
        }
    };

    var build_ns: u64 = 0;
    var write_ns: u64 = 0;
    var refresh_ns: u64 = 0;
    var bytes: usize = 0;
    for (0..rounds) |_| {
        _ = arena.reset(.retain_capacity);
        const t0: std.Io.Timestamp = .now(io, .awake);
        const built = try build(arena.allocator(), w.input(fixture_now));
        build_ns += Lap.ns(io, t0);

        const t1: std.Io.Timestamp = .now(io, .awake);
        const json = try writeAlloc(arena.allocator(), built.snapshot, .{});
        write_ns += Lap.ns(io, t1);
        bytes = json.len;

        try testing.expectEqual(@as(usize, 32), built.snapshot.groups.len);
        try testing.expectEqual(@as(usize, 128), built.snapshot.terminals.len);
    }

    // The whole of what one event costs: work it out, write the compared
    // form, compare, write the full form.
    //
    // On the allocator a release build runs on, not the testing one: that
    // one checks every allocation, and was most of the figure when this
    // was first measured on it.
    var room: ControlRoom = .init(std.heap.smp_allocator);
    defer room.deinit();
    for (0..rounds) |i| {
        const t0: std.Io.Timestamp = .now(io, .awake);
        _ = try room.refresh(w.input(fixture_now + i), .event);
        refresh_ns += Lap.ns(io, t0);
    }

    std.debug.print(
        "\nControlRoom bench ({t}, {d} rounds): build {d} us, write {d} us ({d} bytes), refresh {d} us\n",
        .{ builtin.mode, rounds, build_ns / rounds / 1000, write_ns / rounds / 1000, bytes, refresh_ns / rounds / 1000 },
    );
}

/// A record that knows a directory and nothing else.
fn lastIn(dir: []const u8, from: Chat.LastSupervisor.DirFrom) Chat.LastSupervisor {
    var last: Chat.LastSupervisor = .none;
    last.dir = dir;
    last.dir_from = from;
    return last;
}

fn noRuns(_: *anyopaque, _: Id, _: ?Bus.Program) bool {
    return false;
}

test "1762: a supervisor whose agent has left minds nothing, so one can be started; back with its next hook" {
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    try w.steward(0xa1, "web-app", 0x21, "web-app");
    // In the middle of a turn, its connection seen.
    try w.hook(0xa1, .turn_started, null, 100);
    w.bus.noteAgentHere(0xa1, true, .{ .pid = 91, .started = 50 }, 200);
    var s = (try room.compute(arena.allocator(), w.input(1_000))).snapshot;
    try testing.expectEqual(SupervisorOut.State.present, (try rowNamed(s, "web-app")).supervisor.state);
    try testing.expectEqual(@as(?Id, 0xa1), stewardOfGroup(arena.allocator(), &w.bus, &w.chat, "web-app"));

    // Ended: its connection and its program gone.
    w.bus.noteAgentHere(0xa1, false, null, 1_000);
    var ctx: u8 = 0;
    _ = w.bus.considerLinks(1_000 + Bus.link_grace_ms, &ctx, noRuns);
    s = (try room.compute(arena.allocator(), w.input(10_000))).snapshot;
    const absent = (try rowNamed(s, "web-app")).supervisor;
    try testing.expectEqual(SupervisorOut.State.absent, absent.state);
    try testing.expect(absent.can_start);
    // What `start_supervisor` asks before it opens anything.
    try testing.expectEqual(@as(?Id, null), stewardOfGroup(arena.allocator(), &w.bus, &w.chat, "web-app"));

    // An agent started again in it: its first hook makes it the supervisor again.
    try w.hook(0xa1, .session_started, null, 20_000);
    s = (try room.compute(arena.allocator(), w.input(21_000))).snapshot;
    try testing.expectEqual(SupervisorOut.State.present, (try rowNamed(s, "web-app")).supervisor.state);
    try testing.expectEqual(@as(?Id, 0xa1), stewardOfGroup(arena.allocator(), &w.bus, &w.chat, "web-app"));
}

test "ControlRoom start: a group with no supervisor says one can be started, in which role and where" {
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    // Back from last night: nobody in it. And one somebody minds.
    try w.chat.restoreShell("nightly", "", 0, .none);
    try w.steward(0xa1, "web-app", 0x21, "web-app");

    var s = (try room.compute(arena.allocator(), w.input(1_000))).snapshot;
    const absent = (try rowNamed(s, "nightly")).supervisor;
    try testing.expectEqual(SupervisorOut.State.absent, absent.state);
    try testing.expect(absent.can_start);
    try testing.expectEqualStrings("polter-supervisor", absent.role.?);
    // Nothing better is known than home.
    try testing.expectEqualStrings("/Users/me", absent.cwd);
    try testing.expectEqual(SupervisorOut.CwdFrom.home, absent.cwd_from);
    try testing.expectEqual(@as(?Hex, null), absent.terminal);

    const present = (try rowNamed(s, "web-app")).supervisor;
    try testing.expectEqual(SupervisorOut.State.present, present.state);
    try testing.expect(!present.can_start);

    try testing.expectEqual(@as(usize, 1), s.supervisor_roles.len);
    try testing.expect(!s.choose_supervisor_role);

    // What most of its terminals are in beats home; where its supervisor
    // last worked beats both.
    try w.terminal(0xb1, "one", 0x22);
    try w.chat.add("nightly", 0xb1, .all, .{ .cwd = "/work/api", .title = "" });
    s = (try room.compute(arena.allocator(), w.input(1_000))).snapshot;
    try testing.expectEqualStrings("/work/api", (try rowNamed(s, "nightly")).supervisor.cwd);
    try testing.expectEqual(SupervisorOut.CwdFrom.members, (try rowNamed(s, "nightly")).supervisor.cwd_from);
    // A worker in it is not a supervisor of it.
    try testing.expect((try rowNamed(s, "nightly")).supervisor.can_start);

    _ = try w.chat.setLastSupervisor("nightly", lastIn("/work/repo", .supervisor));
    s = (try room.compute(arena.allocator(), w.input(1_000))).snapshot;
    try testing.expectEqualStrings("/work/repo", (try rowNamed(s, "nightly")).supervisor.cwd);
    try testing.expectEqual(SupervisorOut.CwdFrom.last_supervisor, (try rowNamed(s, "nightly")).supervisor.cwd_from);

    // Two roles is a choice, in the order given; none is nothing to start.
    w.roles = &.{
        .{ .key = "polter-supervisor", .name = "Polter Supervisor", .clis = &.{"claude-code"} },
        .{ .key = "night-lead", .name = "Night Lead", .clis = &.{ "codex", "claude-code" } },
    };
    s = (try room.compute(arena.allocator(), w.input(1_000))).snapshot;
    try testing.expect(s.choose_supervisor_role);
    try testing.expectEqualStrings("night-lead", s.supervisor_roles[1].key);
    try testing.expectEqualStrings("polter-supervisor", (try rowNamed(s, "nightly")).supervisor.role.?);

    w.roles = &.{};
    w.home = "";
    _ = try w.chat.setLastSupervisor("web-app", lastIn("/x", .supervisor));
    try w.chat.restoreShell("empty", "", 0, .none);
    s = (try room.compute(arena.allocator(), w.input(1_000))).snapshot;
    const none = (try rowNamed(s, "empty")).supervisor;
    try testing.expectEqual(SupervisorOut.State.absent, none.state);
    try testing.expect(!none.can_start);
    try testing.expectEqual(@as(?[]const u8, null), none.role);
    try testing.expectEqualStrings("", none.cwd);
    try testing.expectEqual(SupervisorOut.CwdFrom.none, none.cwd_from);
}

test "ControlRoom start: a CLI asking the person something reads as asking, and is looked at again soon (task 1746)" {
    var w: World = .init();
    defer w.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    try w.chat.restoreShell("nightly", "", 0, .none);
    try w.chat.beginStart("nightly", 2_000, 11_000, false, .directory);
    try w.terminal(0xa9, "agy", 0x29);
    w.chat.startOpened("nightly", 0xa9, 61_000);
    var out = try room.refresh(w.input(3_000), .event);
    {
        const read = try std.json.parseFromSlice(Snapshot, testing.allocator, room.json, .{});
        defer read.deinit();
        const sup = (try rowNamed(read.value, "nightly")).supervisor;
        try testing.expect(!sup.asking);
    }

    // The trust box is up.
    _ = w.chat.startAsking("nightly", true, 4_000 + 60_000, 4_000);
    out = try room.refresh(w.input(4_000), .event);
    try testing.expect(out.notify != null);
    try testing.expectEqual(@as(?u64, 4_000 + asking_look_ms), out.wake_ms);
    {
        const read = try std.json.parseFromSlice(Snapshot, testing.allocator, room.json, .{});
        defer read.deinit();
        const sup = (try rowNamed(read.value, "nightly")).supervisor;
        try testing.expectEqual(SupervisorOut.State.starting, sup.state);
        try testing.expect(sup.asking);
        try testing.expect(!sup.can_start);
        try testing.expectEqual(@as(u64, 0xa9), sup.terminal.?.id);
    }

    // Answered: no longer asking; still looked at while the agent is
    // waited for.
    _ = w.chat.startAsking("nightly", false, 0, 5_000);
    out = try room.refresh(w.input(5_000), .event);
    try testing.expectEqual(@as(?u64, 5_000 + asking_look_ms), out.wake_ms);
    {
        const s = w.chat.startOf("nightly", 5_000);
        try testing.expectEqual(@as(?u64, 64_000), s.deadline_ms);
    }
    {
        const read = try std.json.parseFromSlice(Snapshot, testing.allocator, room.json, .{});
        defer read.deinit();
        const sup = (try rowNamed(read.value, "nightly")).supervisor;
        try testing.expect(!sup.asking);
    }
}

test "ControlRoom start: one on its way is not offered again, and the snapshot wakes itself to say it failed" {
    var w: World = .init();
    defer w.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    try w.chat.restoreShell("nightly", "", 0, .none);
    _ = try room.refresh(w.input(1_000), .event);

    try w.chat.beginStart("nightly", 2_000, 11_000, false, .directory);
    var out = try room.refresh(w.input(2_000), .event);
    try testing.expect(out.notify != null);
    {
        const read = try std.json.parseFromSlice(Snapshot, testing.allocator, room.json, .{});
        defer read.deinit();
        const sup = (try rowNamed(read.value, "nightly")).supervisor;
        try testing.expectEqual(SupervisorOut.State.starting, sup.state);
        try testing.expect(!sup.can_start);
        try testing.expectEqual(@as(?Hex, null), sup.terminal);
    }
    // Nothing will happen at the deadline but the deadline: woken for it.
    try testing.expectEqual(@as(?u64, 11_001), out.wake_ms);

    // The tab came; now the agent is waited for, and the tab is looked at
    // every little while for a question its CLI may ask (task 1746).
    try w.terminal(0xa9, "zsh", 0x29);
    w.chat.startOpened("nightly", 0xa9, 61_000);
    out = try room.refresh(w.input(3_000), .event);
    try testing.expectEqual(@as(?u64, 3_000 + asking_look_ms), out.wake_ms);
    {
        const read = try std.json.parseFromSlice(Snapshot, testing.allocator, room.json, .{});
        defer read.deinit();
        const sup = (try rowNamed(read.value, "nightly")).supervisor;
        try testing.expectEqual(SupervisorOut.State.starting, sup.state);
        try testing.expectEqual(@as(u64, 0xa9), sup.terminal.?.id);
    }

    // It never connected. The timer alone says so, and it is offered again.
    out = try room.refresh(w.input(61_001), .timer);
    try testing.expect(out.notify != null);
    try testing.expectEqual(@as(?u64, null), out.wake_ms);
    {
        const read = try std.json.parseFromSlice(Snapshot, testing.allocator, room.json, .{});
        defer read.deinit();
        const sup = (try rowNamed(read.value, "nightly")).supervisor;
        try testing.expectEqual(SupervisorOut.State.failed, sup.state);
        try testing.expectEqual(Chat.StartFailure.agent_never_connected, sup.failed);
        try testing.expect(sup.can_start);
        try testing.expectEqual(@as(u64, 0xa9), sup.terminal.?.id);
    }

    // It did connect, was made a supervisor and put in the group: present,
    // whatever is left of the start.
    try w.chat.beginStart("nightly", 62_000, 72_000, false, .directory);
    w.chat.startOpened("nightly", 0xa9, 122_000);
    try w.bus.addSupervisor(0xa9);
    try w.chat.add("nightly", 0xa9, .all, .{});
    out = try room.refresh(w.input(63_000), .event);
    {
        const read = try std.json.parseFromSlice(Snapshot, testing.allocator, room.json, .{});
        defer read.deinit();
        const row = try rowNamed(read.value, "nightly");
        try testing.expectEqual(SupervisorOut.State.present, row.supervisor.state);
        try testing.expect(!row.supervisor.can_start);
        try testing.expectEqual(@as(u64, 0xa9), row.steward.?.id);
        try testing.expectEqual(@as(?Hex, null), row.supervisor.terminal);
    }
}

test "ControlRoom start: a launcher that says its CLI did not start fails the start at once, with that reason" {
    var w: World = .init();
    defer w.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    try w.chat.restoreShell("nightly", "", 0, .none);
    try w.chat.beginStart("nightly", 2_000, 11_000, false, .directory);
    try w.terminal(0xa9, "zsh", 0x29);
    w.chat.startOpened("nightly", 0xa9, 61_000);
    var out = try room.refresh(w.input(3_000), .event);
    // Waiting for the agent: woken only to look at its tab for a question
    // (task 1746), not for anything about the start itself.
    try testing.expectEqual(@as(?u64, 3_000 + asking_look_ms), out.wake_ms);

    // One second in, `+launch` says the CLI is not there to run. What the
    // app does with that (`App.poltergeistLaunchFailed`): the group that
    // terminal was being started for fails, for the reason given.
    const group = w.chat.startingIn(0xa9, 4_000) orelse return error.NothingWasStartingThere;
    try testing.expectEqualStrings("nightly", group);
    w.chat.failStart(group, Chat.startFailureOf(.not_found));

    out = try room.refresh(w.input(4_000), .event);
    try testing.expect(out.notify != null);
    {
        const read = try std.json.parseFromSlice(Snapshot, testing.allocator, room.json, .{});
        defer read.deinit();
        const sup = (try rowNamed(read.value, "nightly")).supervisor;
        // Failed now, fifty-seven seconds before the timer could say so.
        try testing.expectEqual(SupervisorOut.State.failed, sup.state);
        try testing.expectEqual(Chat.StartFailure.cli_not_found, sup.failed);
        // Offered again, and the tab that says why is still named.
        try testing.expect(sup.can_start);
        try testing.expectEqual(@as(u64, 0xa9), sup.terminal.?.id);
    }
    // Nothing is left to wait for.
    try testing.expectEqual(@as(?u64, null), out.wake_ms);
    // The reason stands when the minute comes round: the timer's own
    // reason does not replace the one the launcher gave.
    _ = try room.refresh(w.input(61_001), .timer);
    try testing.expectEqual(Chat.StartFailure.cli_not_found, w.chat.startOf("nightly", 61_001).failed);

    // The other kind, on another try.
    try w.chat.beginStart("nightly", 70_000, 80_000, false, .directory);
    w.chat.startOpened("nightly", 0xa9, 130_000);
    w.chat.failStart("nightly", Chat.startFailureOf(.failed));
    try testing.expectEqual(Chat.StartFailure.cli_did_not_start, w.chat.startOf("nightly", 71_000).failed);
    // And a terminal nothing was being started in fails nothing.
    const nobody = w.chat.startingIn(0xb7, 71_000);
    try testing.expectEqual(@as(?[]const u8, null), nobody);
}

test "ControlRoom wake: hooks that never came are said once, and there is no moment left to wake for" {
    // The crash: a supervisor was started, its CLI never spoke, and thirty
    // seconds on the bus said so once -- by moving the moment the hooks
    // were expected to the end of time. That number came out of here as
    // the next thing to wake for, and the wake thread could not hold it.
    var w: World = .init();
    defer w.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    try w.terminal(0xa1, "zsh", 0x21);
    try w.hook(0xa1, .hooks_expected, null, 10_000);

    // While the thirty seconds run, their end is the moment to wake at.
    var out = try room.refresh(w.input(11_000), .event);
    try testing.expectEqual(@as(?u64, 10_000 + Bus.hooks_expected_timeout_ms), out.wake_ms);

    // They ran out. The bus says so, once.
    const late = 10_000 + Bus.hooks_expected_timeout_ms + 1_000;
    _ = w.bus.considerAgents(late);
    try testing.expect(!w.bus.considerAgents(late + 60_000));
    // When they were expected is still when they were expected.
    try testing.expectEqual(@as(u64, 10_000), w.bus.agentOf(0xa1).expected_ms);

    // Nothing will change on its own now: no wake, and above all not one
    // at the end of time.
    out = try room.refresh(w.input(late), .event);
    try testing.expectEqual(@as(?u64, null), out.wake_ms);

    // And it is still what it is: hooks that were promised and did not come.
    const read = try std.json.parseFromSlice(Snapshot, testing.allocator, room.json, .{});
    defer read.deinit();
    try testing.expectEqual(@as(usize, 1), read.value.ungrouped.len);
    try testing.expectEqual(Attention.Kind.suspect_stuck, read.value.ungrouped[0].attention.kind);
    try testing.expectEqual(Attention.Source.hook_missing, read.value.ungrouped[0].attention.source);
    // Said as the core's own sentence, for a host to say in the person's
    // language; in English on the line itself (task 1525).
    const what = read.value.ungrouped[0].what;
    try testing.expectEqual(Say.Key.hooks_missing, what.say.?.key);
    try testing.expectEqual(@as(usize, 0), what.say.?.args.len);
    try testing.expectEqualStrings(Say.templateOf(.hooks_missing), what.lines[0]);
}

test "ControlRoom header: terminals on their own are in no count, so the heading, the rows drawn and the Dock are one number" {
    // What was on a real window: "1 group waiting for you", three rows
    // under it, and 3 on the Dock. For a while the answer was to count the
    // lone terminals everywhere; now their rows are not drawn (task 1485)
    // and the answer is to count them nowhere.
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try w.steward(0xa1, "web-app", 0x21, "web-app");
    try w.approval(0xa1, "Bash", "npm ci", 1 * min);
    // Two agents nobody minds, in no group, each stopped on a prompt.
    try w.terminal(0xc1, "one", 0x22);
    try w.approval(0xc1, "Bash", "git push", 1 * min);
    try w.terminal(0xc2, "two", 0x23);
    try w.approval(0xc2, "Bash", "rm -rf dist", 1 * min);
    // And one that needs nothing, with a group that needs nothing.
    try w.terminal(0xc3, "three", 0x24);
    try w.hook(0xc3, .session_started, null, 1 * min);
    try w.steward(0xa2, "notes", 0x25, "notes");
    try w.hook(0xa2, .session_started, null, 1 * min);

    var s = (try build(arena.allocator(), w.input(2 * min))).snapshot;
    // The rows a host draws: the groups', and nothing else.
    var waiting_rows: usize = 0;
    var quiet_rows: usize = 0;
    for (s.groups) |g| {
        if (g.needs_me) waiting_rows += 1 else quiet_rows += 1;
    }
    try testing.expectEqual(@as(usize, 1), waiting_rows);
    // The lone terminals are still listed, two of them waiting.
    var lone_waiting: usize = 0;
    for (s.ungrouped) |t| {
        if (t.needs_me) lone_waiting += 1;
    }
    try testing.expectEqual(@as(usize, 3), s.ungrouped.len);
    try testing.expectEqual(@as(usize, 2), lone_waiting);

    // The three places, one number -- and it is the rows drawn.
    try testing.expectEqual(waiting_rows, s.header_waiting.count);
    try testing.expectEqual(s.needs_me, s.header_waiting.count);
    try testing.expectEqual(s.groups_needing_me, s.needs_me);
    // Every one of them is a group, and the heading says so.
    try testing.expectEqual(HeaderOut{ .count = 1, .of = .groups, .number = .one, .groups = 1, .alone = 0 }, s.header_waiting);

    // The second heading is held to the same.
    try testing.expectEqual(quiet_rows, s.header_quiet.count);
    try testing.expectEqual(HeaderOut{ .count = 1, .of = .groups, .number = .one, .groups = 1, .alone = 0 }, s.header_quiet);
    try testing.expectEqual(@as(usize, 1), s.groups_other);

    // Only groups under a heading: it says "groups", and one is "one".
    var only: World = .init();
    defer only.deinit();
    try only.steward(0xa1, "web-app", 0x21, "web-app");
    try only.approval(0xa1, "Bash", "npm ci", 1 * min);
    s = (try build(arena.allocator(), only.input(2 * min))).snapshot;
    try testing.expectEqual(HeaderOut{ .count = 1, .of = .groups, .number = .one, .groups = 1, .alone = 0 }, s.header_waiting);
    try testing.expectEqual(HeaderOut{ .count = 0, .of = .groups, .number = .none, .groups = 0, .alone = 0 }, s.header_quiet);

    // One lone terminal waiting and nothing else: listed, and nobody is
    // waiting as far as any number says.
    var lone: World = .init();
    defer lone.deinit();
    try lone.terminal(0xc1, "one", 0x22);
    try lone.approval(0xc1, "Bash", "git push", 1 * min);
    s = (try build(arena.allocator(), lone.input(2 * min))).snapshot;
    try testing.expect(s.ungrouped[0].needs_me);
    try testing.expectEqual(HeaderOut{ .count = 0, .of = .groups, .number = .none, .groups = 0, .alone = 0 }, s.header_waiting);
    try testing.expectEqual(@as(usize, 0), s.needs_me);
    try testing.expectEqual(@as(usize, 0), s.groups_needing_me);
}

test "ControlRoom seen: a terminal on its own is looked at through its own row" {
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // An agent nobody minds, in no group, finishes a turn.
    try w.terminal(0xc1, "stray", 0x21);
    try w.hook(0xc1, .turn_started, null, 1 * min);
    try w.hook(0xc1, .turn_ended, "done", 2 * min);
    {
        const s = (try build(arena.allocator(), w.input(3 * min))).snapshot;
        try testing.expectEqual(@as(usize, 1), s.ungrouped.len);
        try testing.expectEqual(Attention.Kind.done_unseen, s.ungrouped[0].attention.kind);
        try testing.expect(s.ungrouped[0].unseen);
    }

    // The person looks at its row. It is no longer something not looked at.
    try testing.expect(w.bus.markSeen(0xc1, 3 * min));
    {
        const s = (try build(arena.allocator(), w.input(4 * min))).snapshot;
        try testing.expect(!s.ungrouped[0].unseen);
        try testing.expect(s.ungrouped[0].attention.kind != .done_unseen);
    }

    // It finishes another turn afterwards: that one has not been looked at.
    try w.hook(0xc1, .turn_started, null, 5 * min);
    try w.hook(0xc1, .turn_ended, "done again", 6 * min);
    {
        const s = (try build(arena.allocator(), w.input(7 * min))).snapshot;
        try testing.expect(s.ungrouped[0].unseen);
    }

    // A terminal the bus does not know has no row to look at.
    try testing.expect(!w.bus.markSeen(0xdead, 7 * min));
}

test "ControlRoom seen: what a supervisor with no group raises is withdrawn by looking at its row" {
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // A supervisor minding a worker, neither in any group.
    try w.terminal(0xa1, "boss", 0x21);
    try w.bus.addSupervisor(0xa1);
    try w.hook(0xa1, .session_started, null, 1 * min);
    const said = "the worker wants to force-push: yours to decide";
    try testing.expect(try w.bus.raise(0xa1, 2 * min, said));

    const rowOf = struct {
        fn of(s: Snapshot, id: u64) !LoneRow {
            for (s.ungrouped) |r| if (r.id.id == id) return r;
            return error.TestRowMissing;
        }
    }.of;
    {
        const s = (try build(arena.allocator(), w.input(2 * min + 1))).snapshot;
        const row = try rowOf(s, 0xa1);
        try testing.expect(row.needs_me);
        try testing.expectEqual(Reason.From.raised, row.reason.from);
        try testing.expectEqualStrings(said, row.reason.text);
        // Looking at it is what withdraws it, and the row says so: this is
        // what a host starts its "seen" clock on.
        try testing.expect(row.unseen);
        // In no count: its row is not drawn.
        try testing.expectEqual(@as(usize, 0), s.header_waiting.count);
    }

    try testing.expect(w.bus.markSeen(0xa1, 3 * min));
    {
        const s = (try build(arena.allocator(), w.input(3 * min + 1))).snapshot;
        const row = try rowOf(s, 0xa1);
        try testing.expect(row.reason.from != .raised);
        try testing.expect(!row.needs_me);
        try testing.expect(!row.unseen);
        try testing.expectEqual(@as(usize, 0), s.needs_me);
    }

    // Raised again after that: there again.
    try testing.expect(try w.bus.raise(0xa1, 4 * min, "and now this"));
    {
        const s = (try build(arena.allocator(), w.input(4 * min + 1))).snapshot;
        try testing.expect((try rowOf(s, 0xa1)).needs_me);
    }
}

test "ControlRoom start: closing the tab fails the start in the very next snapshot, while the terminal is still there" {
    // A host that keeps a closed tab for undo does not destroy the
    // terminal, so nothing "forgets" it. The control room said "starting"
    // for fifteen to forty-odd seconds after the tab was gone.
    var w: World = .init();
    defer w.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    try w.chat.restoreShell("nightly", "", 0, .none);
    try w.terminal(0xa9, "zsh", 0x29);
    try w.chat.beginStart("nightly", 1_000, 11_000, false, .directory);
    w.chat.startOpened("nightly", 0xa9, 61_000);
    var out = try room.refresh(w.input(2_000), .event);
    try testing.expectEqual(@as(?u64, 2_000 + asking_look_ms), out.wake_ms);

    // The tab is closed three seconds in. The terminal is still open as
    // far as the core can tell -- it is in `terminals` below.
    try testing.expect(w.chat.startTerminalClosed(0xa9));
    out = try room.refresh(w.input(5_000), .event);
    try testing.expect(out.notify != null);
    {
        const read = try std.json.parseFromSlice(Snapshot, testing.allocator, room.json, .{});
        defer read.deinit();
        const sup = (try rowNamed(read.value, "nightly")).supervisor;
        try testing.expectEqual(SupervisorOut.State.failed, sup.state);
        try testing.expectEqual(Chat.StartFailure.terminal_closed, sup.failed);
        try testing.expect(sup.can_start);
        try testing.expectEqual(@as(usize, 1), read.value.terminals.len);
    }
    // Nothing is left to wait for.
    try testing.expectEqual(@as(?u64, null), out.wake_ms);

    // Said once; a terminal nothing was starting in says nothing.
    try testing.expect(!w.chat.startTerminalClosed(0xa9));
    try testing.expect(!w.chat.startTerminalClosed(0xb0));
}

test "may-authorise off in the configuration: a worker's prompt is the person's at once, not after its supervisor's minute" {
    var w: World = .init();
    defer w.deinit();
    w.bus.config.may_authorise = false;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try w.steward(0xa1, "api", 0x21, "api");
    try w.hook(0xa1, .turn_started, null, 10 * min);
    try w.worker(0xb1, "api worker", 0x21, 0xa1, "api");
    try w.approval(0xb1, "Bash", "git push --force", 20 * min);

    // Five seconds in. With the gate open this row would still be the
    // supervisor's business; shut, there is nobody who may answer it but
    // the person.
    const s = (try build(arena.allocator(), w.input(20 * min + 5_000))).snapshot;
    const row = try rowNamed(s, "api");
    try testing.expect(row.needs_me);
    try testing.expectEqual(Attention.Kind.needs_approval, row.attention.kind);
    try testing.expectEqual(@as(usize, 1), s.needs_me);

    // The same world with the gate open, so that this can fail.
    w.bus.config.may_authorise = true;
    const open = (try build(arena.allocator(), w.input(20 * min + 5_000))).snapshot;
    try testing.expect(!(try rowNamed(open, "api")).needs_me);
}

test "ControlRoom resume: whether a start goes on with the last session, one reason at a time" {
    const whole: Chat.LastSupervisor = .{
        .dir = "/work/repo",
        .dir_from = .supervisor,
        .role = "polter-supervisor",
        .cli = "claude-code",
        .session = "s-1",
        .heard_ms = 1,
    };
    const can_all: CliResume = .{ .read = &.{ "codex", "claude-code" } };

    // Everything in place: it can, and there is no reason.
    const yes = resumeOf(.{ .last = whole, .cli = "claude-code", .cli_resume = can_all, .held = false, .last_try_failed = false });
    try testing.expect(yes.can);
    try testing.expectEqual(ResumeOut.Why.none, yes.why);

    const Cell = struct {
        last: Chat.LastSupervisor = whole,
        cli: ?[]const u8 = "claude-code",
        cli_resume: CliResume = can_all,
        held: bool = false,
        last_try_failed: bool = false,
        why: ResumeOut.Why,
    };
    var never = whole;
    never.heard_ms = null;
    never.session = "";
    var guessed: Chat.LastSupervisor = .none;
    guessed.dir = "/old";
    guessed.dir_from = .session_snapshot;
    var silent = whole;
    silent.session = "";
    var no_cli = whole;
    no_cli.cli = "";

    const cells = [_]Cell{
        // No supervisor was ever recorded -- with nothing at all, and with
        // a directory made up afterwards.
        .{ .last = .none, .why = .no_record },
        .{ .last = never, .why = .no_record },
        .{ .last = guessed, .why = .no_record },
        // There was one, and its CLI never named a session: not the same
        // answer as there never having been one.
        .{ .last = silent, .why = .no_session },
        .{ .last_try_failed = true, .why = .last_try_failed },
        .{ .cli = "codex", .why = .cli_differs },
        .{ .cli = null, .why = .cli_differs },
        .{ .last = no_cli, .why = .cli_differs },
        // Not read yet is not "cannot".
        .{ .cli_resume = .unread, .why = .clis_unread },
        .{ .cli_resume = .{ .read = &.{} }, .why = .cli_cannot_resume },
        .{ .cli_resume = .{ .read = &.{"codex"} }, .why = .cli_cannot_resume },
        .{ .held = true, .why = .session_in_use },
    };
    for (cells) |c| {
        const got = resumeOf(.{ .last = c.last, .cli = c.cli, .cli_resume = c.cli_resume, .held = c.held, .last_try_failed = c.last_try_failed });
        try testing.expectEqual(c.why, got.why);
        try testing.expect(!got.can);
    }

    // The order, where two apply: what is missing is said before what
    // would not have mattered.
    const two = resumeOf(.{ .last = silent, .cli = "codex", .cli_resume = .unread, .held = true, .last_try_failed = true });
    try testing.expectEqual(ResumeOut.Why.no_session, two.why);
}

test "ControlRoom resume: a CLI is named by its adapter's word, and one nobody names is said to have no name" {
    const names: []const CliName = &.{
        .{ .key = "claude-code", .label = "Claude Code" },
        .{ .key = "bare", .label = "" },
    };
    try testing.expectEqualStrings("Claude Code", cliLabelOf(names, "claude-code").?);
    // No adapter by that key, one that gives no name, no key, none read:
    // each is "no name", never the key standing in for one.
    try testing.expectEqual(@as(?[]const u8, null), cliLabelOf(names, "codex"));
    try testing.expectEqual(@as(?[]const u8, null), cliLabelOf(names, "bare"));
    try testing.expectEqual(@as(?[]const u8, null), cliLabelOf(names, null));
    try testing.expectEqual(@as(?[]const u8, null), cliLabelOf(names, ""));
    try testing.expectEqual(@as(?[]const u8, null), cliLabelOf(&.{}, "claude-code"));

    // In the snapshot: beside the CLI a start uses and beside the one the
    // last supervisor was, each on its own.
    var w = try fixtureWorld();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const named = (try build(arena.allocator(), w.input(fixture_now))).snapshot;
    const billing = (try rowNamed(named, "billing")).supervisor;
    try testing.expectEqualStrings("claude-code", billing.cli.?);
    try testing.expectEqualStrings("Claude Code", billing.cli_label.?);
    try testing.expectEqualStrings("claude-code", billing.last.cli.?);
    try testing.expectEqualStrings("Claude Code", billing.last.cli_label.?);
    // A group with no CLI written down for its last supervisor has no
    // name for it either.
    const web = (try rowNamed(named, "web-app")).supervisor;
    try testing.expectEqual(@as(?[]const u8, null), web.last.cli);
    try testing.expectEqual(@as(?[]const u8, null), web.last.cli_label);
    try testing.expectEqualStrings("Claude Code", web.cli_label.?);

    // With no names read the keys are still there, and the names are not.
    w.cli_names = &.{};
    const unnamed = (try build(arena.allocator(), w.input(fixture_now))).snapshot;
    const b = (try rowNamed(unnamed, "billing")).supervisor;
    try testing.expectEqualStrings("claude-code", b.cli.?);
    try testing.expectEqual(@as(?[]const u8, null), b.cli_label);
    try testing.expectEqualStrings("claude-code", b.last.cli.?);
    try testing.expectEqual(@as(?[]const u8, null), b.last.cli_label);
}

test "ControlRoom resume: the role and the CLI a start uses are the last supervisor's while they are still there" {
    const roles = [_]StartRole{
        .{ .key = "polter-supervisor", .name = "Polter Supervisor", .clis = &.{"claude-code"} },
        .{ .key = "night-lead", .name = "Night Lead", .clis = &.{ "codex", "claude-code" } },
    };
    var last: Chat.LastSupervisor = .none;

    // Nothing written down: the first role, and its first CLI.
    try testing.expectEqualStrings("polter-supervisor", startRoleOf(&roles, last).?.key);
    try testing.expectEqualStrings("codex", startCliOf(roles[1].clis, last).?);

    // The role it wore, and the CLI it was -- not the role's first.
    last.role = "night-lead";
    last.cli = "claude-code";
    const role = startRoleOf(&roles, last).?;
    try testing.expectEqualStrings("night-lead", role.key);
    try testing.expectEqualStrings("claude-code", startCliOf(role.clis, last).?);

    // A role that is gone, or no longer one to start a supervisor in, and
    // a CLI the role is no longer set up for: the first of each again.
    last.role = "deleted";
    last.cli = "gemini";
    try testing.expectEqualStrings("polter-supervisor", startRoleOf(&roles, last).?.key);
    try testing.expectEqualStrings("codex", startCliOf(roles[1].clis, last).?);

    try testing.expectEqual(@as(?StartRole, null), startRoleOf(&.{}, last));
    try testing.expectEqual(@as(?[]const u8, null), startCliOf(&.{}, last));
}

test "ControlRoom resume: the snapshot says what a group's last supervisor was and whether a start goes on with its session" {
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    w.roles = &.{
        .{ .key = "polter-supervisor", .name = "Polter Supervisor", .clis = &.{"claude-code"} },
        .{ .key = "night-lead", .name = "Night Lead", .clis = &.{ "codex", "claude-code" } },
    };
    try w.chat.restoreShell("nightly", "", 0, .none);
    try w.chat.restoreShell("old", "", 0, .none);
    try w.chat.restoreShell("guessed", "", 0, .none);

    _ = try w.chat.setLastSupervisor("nightly", .{
        .dir = "/work/repo",
        .dir_from = .supervisor,
        .role = "night-lead",
        .cli = "claude-code",
        .session = "s-1",
        .heard_ms = 1_700_000_000_000,
    });
    _ = try w.chat.setLastSupervisor("guessed", lastIn("/old/place", .session_snapshot));

    var s = (try room.compute(arena.allocator(), w.input(1_000))).snapshot;

    // What was written down, and the start it makes the default: that
    // role, that CLI (the role's second), that directory, that session.
    const sup = (try rowNamed(s, "nightly")).supervisor;
    try testing.expectEqualStrings("night-lead", sup.last.role.?);
    try testing.expectEqualStrings("claude-code", sup.last.cli.?);
    try testing.expectEqual(@as(?u64, 1_700_000_000_000), sup.last.heard_ms);
    try testing.expectEqualStrings("night-lead", sup.role.?);
    try testing.expectEqualStrings("claude-code", sup.cli.?);
    try testing.expectEqualStrings("/work/repo", sup.cwd);
    try testing.expectEqual(SupervisorOut.CwdFrom.last_supervisor, sup.cwd_from);
    try testing.expect(sup.@"resume".can);
    try testing.expectEqual(ResumeOut.Why.none, sup.@"resume".why);

    // Nothing written down: every part is null, not an empty string, and
    // the reason is that there is no record.
    const old = (try rowNamed(s, "old")).supervisor;
    try testing.expectEqual(@as(?[]const u8, null), old.last.role);
    try testing.expectEqual(@as(?[]const u8, null), old.last.cli);
    try testing.expectEqual(@as(?u64, null), old.last.heard_ms);
    try testing.expectEqualStrings("polter-supervisor", old.role.?);
    try testing.expect(!old.@"resume".can);
    try testing.expectEqual(ResumeOut.Why.no_record, old.@"resume".why);

    // A directory made up out of the old session snapshot is offered, and
    // is not passed off as where a supervisor is known to have worked.
    const guessed = (try rowNamed(s, "guessed")).supervisor;
    try testing.expectEqualStrings("/old/place", guessed.cwd);
    try testing.expectEqual(SupervisorOut.CwdFrom.session_snapshot, guessed.cwd_from);
    try testing.expectEqual(ResumeOut.Why.no_record, guessed.@"resume".why);

    // The adapters not read yet: said as that, and the snapshot asks to be
    // made again for it.
    w.cli_resume = .unread;
    const unread = try room.compute(arena.allocator(), w.input(1_000));
    try testing.expectEqual(ResumeOut.Why.clis_unread, (try rowNamed(unread.snapshot, "nightly")).supervisor.@"resume".why);
    try testing.expectEqual(@as(?u64, 2_000), unread.wake_ms);
    w.cli_resume = .{ .read = &.{} };
    s = (try room.compute(arena.allocator(), w.input(1_000))).snapshot;
    try testing.expectEqual(ResumeOut.Why.cli_cannot_resume, (try rowNamed(s, "nightly")).supervisor.@"resume".why);
    w.cli_resume = .{ .read = &.{"claude-code"} };

    // An open terminal whose agent says it is in that session: not a
    // second agent in it.
    try w.terminal(0xc1, "elsewhere", 0x31);
    var ev: AgentEvent.Event = .none;
    ev.event = .session_started;
    ev.cli = "claude-code";
    ev.session_id = "s-1";
    _ = try w.bus.agentEvent(0xc1, ev, 500);
    s = (try room.compute(arena.allocator(), w.input(1_000))).snapshot;
    try testing.expectEqual(ResumeOut.Why.session_in_use, (try rowNamed(s, "nightly")).supervisor.@"resume".why);
    // It moved on to another session (`/clear`): free again.
    ev.session_id = "s-2";
    _ = try w.bus.agentEvent(0xc1, ev, 600);
    s = (try room.compute(arena.allocator(), w.input(1_000))).snapshot;
    try testing.expect((try rowNamed(s, "nightly")).supervisor.@"resume".can);

    // A start that went on with it and made no supervisor: the next one
    // does not, by default. One that started afresh and failed says
    // nothing against the session.
    try w.chat.beginStart("nightly", 2_000, 11_000, true, .directory);
    s = (try room.compute(arena.allocator(), w.input(11_001))).snapshot;
    const failed = (try rowNamed(s, "nightly")).supervisor;
    try testing.expectEqual(SupervisorOut.State.failed, failed.state);
    try testing.expect(failed.can_start);
    try testing.expectEqual(ResumeOut.Why.last_try_failed, failed.@"resume".why);
    try w.chat.beginStart("nightly", 12_000, 21_000, false, .directory);
    s = (try room.compute(arena.allocator(), w.input(21_001))).snapshot;
    try testing.expect((try rowNamed(s, "nightly")).supervisor.@"resume".can);
}

test "1744: a CLI whose program an inventory found missing stands not_installed, and nothing else changes it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const plugins = [_]CliStanding{
        .{ .key = "antigravity", .standing = .ok },
        .{ .key = "claude-code", .standing = .ok },
        .{ .key = "codex", .standing = .plugin_off },
    };
    const both_missing = [_][]const u8{ "claude-code", "codex" };
    const merged = (try installedHere(aa, &plugins, &both_missing)).?;
    const claude = standingOf(merged, "claude-code");
    try testing.expectEqual(@as(?HeldBackOut.Why, .not_installed), claude);
    // Here: still offered.
    const agy = standingOf(merged, "antigravity");
    try testing.expectEqual(@as(?HeldBackOut.Why, null), agy);
    // A plugin that is off keeps its own reason: its switch is still what
    // the person reaches for first.
    const codex = standingOf(merged, "codex");
    try testing.expectEqual(@as(?HeldBackOut.Why, .plugin_off), codex);
    // Nothing read yet is not "missing": the plugins' word stands.
    const unread = (try installedHere(aa, &plugins, null)).?;
    const claude_unread = standingOf(unread, "claude-code");
    try testing.expectEqual(@as(?HeldBackOut.Why, null), claude_unread);
    // The plugins not read: still nothing to say.
    const no_plugins = try installedHere(aa, null, &both_missing);
    try testing.expect(no_plugins == null);
}

test "1744: a machine with only agy: the start offers agy, says why Claude Code is not offered, and a failed start does not pick it again" {
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    // The shipped supervisor role, set up for both; both plugins on.
    w.roles = &.{.{ .key = "polter-supervisor", .name = "Polter Supervisor", .clis = &.{ "claude-code", "antigravity" } }};
    const plugins = [_]CliStanding{
        .{ .key = "antigravity", .standing = .ok },
        .{ .key = "claude-code", .standing = .ok },
    };
    try w.chat.restoreShell("t1740", "", 0, .none);
    // A start in Claude Code was tried and made no supervisor (0xe644,
    // #1740: "could not start claude (FileNotFound)").
    try w.chat.beginStart("t1740", 2_000, 11_000, false, .directory);

    // Before the adapters are read: the plugins' word alone, as before.
    w.cli_standings = try installedHere(aa, &plugins, null);
    const before = (try rowNamed((try room.compute(aa, w.input(11_001))).snapshot, "t1740")).supervisor;
    try testing.expectEqual(SupervisorOut.State.failed, before.state);
    try testing.expectEqualStrings("claude-code", before.cli.?);

    // Read: claude is not on this machine.
    w.cli_standings = try installedHere(aa, &plugins, &.{"claude-code"});
    const s = (try room.compute(aa, w.input(11_002))).snapshot;
    const after = (try rowNamed(s, "t1740")).supervisor;
    // The next start does not pick the CLI that failed for want of its
    // program: the one that is here.
    const picked = after.cli.?;
    try testing.expectEqualStrings("antigravity", picked);
    // Offered: agy alone. Held back: Claude Code, with its reason.
    const role = s.supervisor_roles[0];
    try testing.expectEqual(@as(usize, 1), role.clis.len);
    try testing.expectEqualStrings("antigravity", role.clis[0].key);
    try testing.expectEqual(@as(usize, 1), role.held_back.len);
    try testing.expectEqualStrings("claude-code", role.held_back[0].key);
    const why = role.held_back[0].why;
    try testing.expectEqual(HeldBackOut.Why.not_installed, why);
    // And no CLI that is not here is asked whether it goes on with a session.
    for (after.resume_by_cli) |r| try testing.expect(!std.mem.eql(u8, r.cli, "claude-code"));
}

test "Projects: the snapshot says which project each group has, what starting it does, and what the host is to do" {
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    try w.chat.restoreShell("tied", "", 0, .none);
    try w.chat.restoreShell("old", "", 0, .none);
    try w.chat.restoreShell("said-no", "", 0, .none);
    _ = try w.chat.setProject("tied", .{ .bound = "tied" });
    _ = try w.chat.setProject("said-no", .declined);

    // The host has said nothing: the tie is known, the project is not.
    var s = (try room.compute(aa, w.input(1_000))).snapshot;
    try testing.expect(!s.projects_known);
    try testing.expectEqual(@as(usize, 0), s.project_orders.len);
    const blind = (try rowNamed(s, "tied")).project;
    try testing.expect(blind.tie == .bound);
    try testing.expectEqualStrings("tied", blind.name.?);
    // Not known is not zero pages and not closed.
    try testing.expectEqual(@as(?usize, null), blind.pages);
    try testing.expectEqual(@as(?bool, null), blind.open);
    try testing.expectEqual(Chat.StartBy.project, blind.start);
    try testing.expectEqual(Projects.Why.projects_unknown, (try rowNamed(s, "old")).project.why);
    try testing.expectEqual(Chat.StartBy.directory, (try rowNamed(s, "old")).project.start);

    // Stated. One group tied to a project of three pages, closed; one old
    // group its supervisor has just taken up; one that said no.
    var table: Projects = .init(testing.allocator);
    defer table.deinit();
    {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, aa,
            \\[{"name":"tied","group":"tied","pages":3,"open":null,"supervisor":null,"workers":[]}]
        , .{});
        try table.state(try Projects.parse(aa, v));
    }
    const views = [_]Projects.GroupView{
        .{ .name = "tied", .tie = .{ .bound = "tied" }, .steward = null, .supervisors = 0, .claim = null, .awaiting_open = true, .seating = null },
        .{ .name = "old", .tie = .undecided, .steward = 0xa1, .supervisors = 1, .claim = .{ .terminal = 0xa1, .said = false }, .awaiting_open = false, .seating = null },
        .{ .name = "said-no", .tie = .declined, .steward = null, .supervisors = 0, .claim = null, .awaiting_open = false, .seating = null },
    };
    const out = try table.reconcile(aa, &views, &.{});
    w.projects = .{ .table = &table, .standings = out.standings, .orders = out.orders };

    s = (try room.compute(aa, w.input(1_000))).snapshot;
    try testing.expect(s.projects_known);
    const tied = (try rowNamed(s, "tied")).project;
    try testing.expectEqual(@as(?usize, 3), tied.pages);
    try testing.expectEqual(@as(?bool, false), tied.open);
    try testing.expectEqual(Projects.Why.none, tied.why);

    const old = (try rowNamed(s, "old")).project;
    try testing.expect(old.tie == .undecided);
    try testing.expectEqual(@as(?[]const u8, null), old.name);
    try testing.expectEqual(Projects.Why.pending, old.why);
    try testing.expectEqual(Chat.StartBy.directory, old.start);

    const no = (try rowNamed(s, "said-no")).project;
    try testing.expect(no.tie == .declined);
    try testing.expectEqual(Projects.Why.declined, no.why);

    // The two things asked of the host, as it reads them.
    try testing.expectEqual(@as(usize, 2), s.project_orders.len);
    try testing.expectEqual(Projects.Order.Kind.open, s.project_orders[0].order);
    try testing.expectEqualStrings("tied", s.project_orders[0].project);
    try testing.expectEqual(@as(?Hex, null), s.project_orders[0].terminal);
    try testing.expectEqual(Projects.Order.Kind.create, s.project_orders[1].order);
    try testing.expectEqualStrings("old", s.project_orders[1].group.?);
    try testing.expectEqual(@as(u64, 0xa1), s.project_orders[1].terminal.?.id);

    const json = try writeAlloc(aa, s, .{});
    try testing.expect(std.mem.indexOf(u8, json,
        \\{"order":"create","project":"old","group":"old","to":null,"terminal":"0x00000000000000a1"}
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"project":{"tie":"bound","name":"tied","pages":3,"open":false,"start":"project","why":"none","ask":false}
    ) != null);
}

test "Projects: who is in a terminal is an agent, nobody, or not known -- and nobody is not not-known" {
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();

    // 0xa1: hooks heard from, in a turn, started in a role.
    try w.terminal(0xa1, "boss", 0x21);
    try w.hook(0xa1, .turn_started, null, 500);
    // 0xa2: an agent connected, no hooks, no role: all three not known.
    try w.terminal(0xa2, "connected", 0x22);
    // 0xa3: its agent has gone -- the hooks said what they said, and the
    // shell has the terminal back.
    try w.terminal(0xa3, "left", 0x23);
    try w.hook(0xa3, .turn_ended, "bye", 500);
    // 0xa4: a shell at its prompt that never had one.
    try w.terminal(0xa4, "shell", 0x24);
    // 0xa5: something is running that says nothing to Polter.
    try w.terminal(0xa5, "vim, or an agent it cannot see", 0x25);
    // 0xa6: a launch line was typed and its hooks are expected.
    try w.terminal(0xa6, "starting", 0x26);
    {
        var ev: AgentEvent.Event = .none;
        ev.event = .hooks_expected;
        ev.cli = "codex";
        _ = try w.bus.agentEvent(0xa6, ev, 500);
    }
    for (w.open.items) |*t| switch (t.id) {
        0xa1 => {
            t.role = "polter-supervisor";
            t.launched_cli = "codex";
        },
        0xa2 => t.agent_present = true,
        0xa3 => {
            t.at_prompt = true;
            t.role = "dev-worker";
            t.launched_cli = "claude-code";
        },
        0xa4 => t.at_prompt = true,
        0xa6 => {
            t.role = "dev-worker";
            t.launched_cli = "codex";
        },
        else => {},
    };
    // The supervisor opened two of them for workers; nobody opened the
    // rest -- but for 0xa4, which it split off for itself (#1498): opened
    // by it, and not a worker.
    try w.bus.markOpenedByAgent(0xa3, 0xa1);
    try w.bus.markWorkerOf(0xa3, 0xa1);
    try w.bus.markOpenedByAgent(0xa5, 0xa1);
    try w.bus.markWorkerOf(0xa5, 0xa1);
    try w.bus.markOpenedByAgent(0xa4, 0xa1);

    const s = (try room.compute(aa, w.input(1_000))).snapshot;
    const who = struct {
        fn of(snap: Snapshot, id: u64) !WhoOut {
            for (snap.terminals) |t| {
                if (t.id.id == id) return t.who;
            }
            return error.NoSuchTerminal;
        }
    }.of;

    // What its hooks said beats what the launch said: the CLI is the one
    // that named itself.
    const boss = try who(s, 0xa1);
    try testing.expectEqual(WhoOut.Is.agent, boss.is);
    try testing.expectEqualStrings("polter-supervisor", boss.role.?);
    try testing.expectEqualStrings("claude-code", boss.cli.?);
    try testing.expectEqualStrings("s", boss.session.?);
    try testing.expectEqual(@as(?Hex, null), boss.worker_of);

    // There, and nothing known of it: empty strings, which is "an agent,
    // and that part is not known" -- not nulls.
    const connected = try who(s, 0xa2);
    try testing.expectEqual(WhoOut.Is.agent, connected.is);
    try testing.expectEqualStrings("", connected.role.?);
    try testing.expectEqualStrings("", connected.cli.?);
    try testing.expectEqualStrings("", connected.session.?);

    // Gone: nobody, whatever it was -- and still the supervisor's pane.
    const left = try who(s, 0xa3);
    try testing.expectEqual(WhoOut.Is.none, left.is);
    try testing.expectEqual(@as(?[]const u8, null), left.role);
    try testing.expectEqual(@as(?[]const u8, null), left.cli);
    try testing.expectEqual(@as(?[]const u8, null), left.session);
    try testing.expectEqual(@as(u64, 0xa1), left.worker_of.?.id);

    // The supervisor's own split: nobody's worker (#1498).
    const own = try who(s, 0xa4);
    try testing.expectEqual(WhoOut.Is.none, own.is);
    try testing.expectEqual(@as(?Hex, null), own.worker_of);

    // Not at a prompt, and nothing heard: the core cannot tell.
    const blind = try who(s, 0xa5);
    try testing.expectEqual(WhoOut.Is.unknown, blind.is);
    try testing.expectEqual(@as(?[]const u8, null), blind.role);
    try testing.expectEqual(@as(u64, 0xa1), blind.worker_of.?.id);

    // On its way: what the launch said is what is known so far.
    const starting = try who(s, 0xa6);
    try testing.expectEqual(WhoOut.Is.agent, starting.is);
    try testing.expectEqualStrings("dev-worker", starting.role.?);
    try testing.expectEqualStrings("codex", starting.cli.?);
    try testing.expectEqualStrings("", starting.session.?);

    const json = try writeAlloc(aa, s, .{});
    try testing.expect(std.mem.indexOf(u8, json,
        \\"who":{"is":"agent","role":"polter-supervisor","cli":"claude-code","session":"s","worker_of":null}
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"who":{"is":"none","role":null,"cli":null,"session":null,"worker_of":"0x00000000000000a1"}
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json,
        \\"who":{"is":"unknown","role":null,"cli":null,"session":null,"worker_of":"0x00000000000000a1"}
    ) != null);
}

test "1741: the snapshot says whether the adapters have been read, for a host to say it is looking" {
    var w: World = .init();
    defer w.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var room: ControlRoom = .init(testing.allocator);
    defer room.deinit();
    try w.chat.restoreShell("web", "", 0, .none);

    w.cli_resume = .unread;
    const before = (try rowNamed((try room.compute(arena.allocator(), w.input(1_000))).snapshot, "web")).supervisor;
    const read_before = before.clis_read;
    try testing.expect(!read_before);

    w.cli_resume = .{ .read = &.{"claude-code"} };
    const after = (try rowNamed((try room.compute(arena.allocator(), w.input(2_000))).snapshot, "web")).supervisor;
    const read_after = after.clis_read;
    try testing.expect(read_after);
}
