//! Who is watching whom, and what each watched terminal is allowed to do.
//!
//! One bus per app. It holds the role and the duty state of every terminal
//! Poltergeist knows about, and whether the user is holding one to its
//! work, and it decides whether a quiescence report is worth putting in
//! front of the supervisor.
//!
//! What it does *not* do is decide what a quiet terminal means. That is the
//! supervisor AI's job, and this file exists partly to keep that boundary
//! from eroding: everything here is bookkeeping and rate limiting, with no
//! reading of screen contents anywhere.
//!
//! Poltergeist also never holds tasks. There is no queue here, no task list,
//! and no scheduling -- work comes from whatever system the agents already
//! read from. See `dev-docs/poltergeist/mcp.md`.
//!
//! Pure: no allocation beyond the registry, time arrives as a parameter.

const Bus = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Sampler = @import("Sampler.zig");
const Attention = @import("Attention.zig");
const AgentEvent = @import("agent_event.zig");

/// A terminal's identity. This is `Surface.id`, which Ghostty already
/// assigns and already exports to child processes as `GHOSTTY_SURFACE_ID`,
/// so agents and the bus agree on names without inventing a second scheme.
pub const Id = u64;

/// The id a surface goes by: what `terminal_list` reports for it, and what
/// `ghostty_surface_poltergeist_id` gives a host that holds only the
/// surface. **Both go through here**, so that a sidecar file written by a
/// host and a row read by an agent cannot name the same terminal two ways.
///
/// A host has a second number for every surface -- its own handle, the
/// pointer -- and that one is *not* this: it changes from run to run and no
/// tool accepts it.
pub fn idOf(surface: anytype) Id {
    return surface.id;
}

test "a surface's terminal id is its id, not its handle" {
    // The two numbers a host could confuse, on one value.
    const Fake = struct { handle: u64, id: u64 };
    const fake: Fake = .{ .handle = 0x1111_2222_3333_4444, .id = 0x9382_ac53_5955_05a6 };
    const reported: Id = idOf(&fake);
    try std.testing.expectEqual(@as(Id, 0x9382_ac53_5955_05a6), reported);

    // And as `terminal_list` writes it.
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "0x{x:0>16}", .{reported});
    try std.testing.expectEqualStrings("0x9382ac53595505a6", text);
}

/// An id no terminal has.
///
/// Used where a `Bus.Id` has to be produced for a caller that is not a
/// terminal -- a plugin -- so that a mistake reads as "nobody" rather than
/// as somebody. It is deliberately **not** zero: zero is the user
/// (`Chat.user_id`), and a plugin that slipped into a branch expecting a
/// terminal would then be acting as the person at the keyboard, which is
/// the single worst thing it could be mistaken for.
///
/// `Surface` refuses to mint this value, the same way and for the same
/// reason it refuses to mint zero.
pub const not_a_terminal: Id = std.math.maxInt(Id);

/// Who is making a call.
///
/// A terminal proves which one it is by holding that terminal's token; a
/// plugin proves it is that plugin the same way, on the same socket, with a
/// token of its own. What it cannot do is *be* a terminal, and that is the
/// whole reason this is a union rather than a reserved range of `Id`: there
/// is no `Bus.Id` a plugin holds, so there is nothing for it to claim. An
/// impersonation is not refused here; it has no shape to be written in.
///
/// **The adopted default is that a plugin is never a supervisor.** Every
/// method that changes the supervision arrangement is a supervisor's, so
/// every one of them is closed to a plugin without a second list saying so;
/// and under the reachability rule a plugin may touch only terminals that
/// carry no mark. The direction is deliberate -- widening is easy, and
/// narrowing after somebody has built on the wider rule is not. The route
/// to a plugin that *is* trusted further is the same one `held` and
/// `shielded` already take: the user sets it, in the settings, and nothing
/// the plugin says has a vote.
///
/// `shielded` is absolute against this the same way it is absolute against
/// a supervisor. That is worth saying separately because the last time a
/// second door was opened -- `terminal_action` -- it went in with no
/// permission check at all, and could walk around `set_watch`'s supervisor
/// gate and lift a `held` the user had set. Every door reopens every
/// question.
pub const Caller = union(enum) {
    /// A terminal, by the id `Surface` already assigns and already exports
    /// as `GHOSTTY_SURFACE_ID`.
    terminal: Id,

    /// A plugin, by its manifest key and what that manifest declared it
    /// calls. Borrowed for the life of the call.
    plugin: Plugin,

    /// A plugin as the tool surface sees it.
    ///
    /// The declared calls travel with the identity rather than being looked
    /// up: the manifest arena is rebuilt every time the plugin directories
    /// are read, and a check that went and re-read a file mid-request could
    /// answer differently for two calls on one connection.
    pub const Plugin = struct {
        key: []const u8,

        /// Exactly `wants.calls` from the manifest, in the order it was
        /// written. Empty refuses everything.
        calls: []const []const u8 = &.{},

        /// Whether the manifest declared this method by name. Exact
        /// strings, no wildcard: the declaration is what a user reads
        /// before installing, and `"*"` would make that reading worthless
        /// exactly where it matters most.
        pub fn mayCall(self: Plugin, method: []const u8) bool {
            for (self.calls) |c| if (std.mem.eql(u8, c, method)) return true;
            return false;
        }
    };

    /// The terminal this is, or null when it is not one.
    ///
    /// Null is what every caller that needs to name a terminal has to
    /// handle, and handling it is the refusal: a plugin has no terminal to
    /// post as, to open a tab in, to be watched, or to be handed a
    /// supervisor's box of notices.
    pub fn terminalId(self: Caller) ?Id {
        return switch (self) {
            .terminal => |id| id,
            .plugin => null,
        };
    }

    /// Whether this is the terminal `id`.
    pub fn isTerminal(self: Caller, id: Id) bool {
        return switch (self) {
            .terminal => |mine| mine == id,
            .plugin => false,
        };
    }

    /// The plugin this is, or null when it is a terminal.
    pub fn pluginKey(self: Caller) ?[]const u8 {
        return switch (self) {
            .terminal => null,
            .plugin => |p| p.key,
        };
    }
};

pub const Role = enum {
    /// Known to the bus but neither supervising nor supervised.
    none,

    /// The terminal whose agent is minding the others.
    supervisor,

    /// Watched by the supervisor.
    watched,
};

/// An agent that is no longer in its terminal.
pub const Left = struct {
    why: Why,
    at_ms: u64,

    pub const Why = enum {
        /// It ended on its own, with an error.
        failed,
        /// It is gone and nothing says whether it failed or was closed.
        unknown,
    };
};

/// The program an agent's connection came from: its pid, and when that
/// process started, so that the same number on a later process is not
/// taken for it (#1669 c1669-12). `started` is null where it could not be
/// read; it is only ever compared with another reading of the host's.
pub const Program = struct {
    pid: u64,
    started: ?u64,
};

/// An agent's connection to Polter, gone (`Entry.link_lost`).
pub const LinkLost = struct {
    at_ms: u64,
    /// The program it had come from; null when that was not known.
    program: ?Program,
};

/// How long a connection may be gone before its loss is a fact: the
/// sidecar of an agent that is starting again, or a CLI that restarts its
/// server, connects within this.
pub const link_grace_ms: u64 = 5 * std.time.ms_per_s;

/// Whether a terminal is still expected to be working.
pub const Duty = enum {
    /// On duty. Quiescence here is worth telling the supervisor about.
    on,

    /// Clocked off. The supervisor decided there was no more to do, so
    /// going quiet is expected and is not reported again.
    off,
};

/// Who is asking for a change. Some changes are the user's alone.
pub const Authority = enum { user, supervisor };

pub const ClockOffError = error{
    /// The user is holding this terminal to its work.
    TerminalHeld,

    /// The bus has never heard of this terminal.
    UnknownTerminal,

    /// Only the supervisor clocks terminals off.
    NotPermitted,
};

pub const SetHeldError = error{
    UnknownTerminal,

    /// The hold is the user's alone. Otherwise it would be worth nothing:
    /// the supervisor would simply lift it and then clock the terminal
    /// off a moment later, which is the thing the hold exists to prevent.
    NotPermitted,
};

/// What a report says happened, and all that is kept of one.
///
/// No screen contents anywhere -- the supervisor reads the other terminal
/// itself if it wants to know what is on it, which keeps the judgement (and
/// the reading) on the AI's side of the line. Durations are not stored
/// either: `quietMs` computes the true figure on demand, so a report that
/// sat in the box says how long the terminal has been quiet now rather than
/// how long it had been when it arrived.
pub const NoticeKind = enum { quiescent, still_quiescent, resumed };

/// Whether this terminal's agent CLI reports on itself through hooks, and
/// so whether its silence means anything. See `dev-docs/poltergeist/adapters.md`
/// 3.4.
///
/// **Three values because "no events" is three different answers.** With
/// `none`, nothing was ever going to arrive and the absence says nothing.
/// With `expected`, the hooks were configured and have not been heard from
/// -- past `hooks_expected_timeout_ms` that is a fault (a CLI that changed
/// its payloads, a wrong `+hook` path) and goes in the box. With `live`,
/// they have been heard, and from then on no event does mean no event.
pub const Hooks = enum { none, expected, live };

/// What the agent last said it was doing.
pub const AgentState = enum {
    /// Started, and no turn yet.
    idle,
    in_turn,
    ended,
    failed,
    awaiting_approval,
    awaiting_input,
};

/// How long `expected` may wait for `session_started` before it is a fault.
pub const hooks_expected_timeout_ms: u64 = 30 * std.time.ms_per_s;

/// How long after a launch an agent has to connect from its terminal before
/// the launch is said to have come to nothing (`launchWithNoAgent`, task
/// 1712). The same minute a role's standing is held for
/// (`PersonaStore.standing_wait_ms`): past it, nothing that connects is
/// taken for the launch's agent anyway, so this only says out loud what
/// already lapsed in silence.
pub const launch_agent_wait_ms: u64 = 60 * std.time.ms_per_s;

/// How long after an event the screen may still be drawing that event --
/// the permission box, the last lines of an answer -- and have that count as
/// the event's own redraw rather than as the screen moving on.
///
/// Measured with claude 2.1.283 in a pty (#879): the permission box was
/// still being drawn 1.45 s and 1.82 s after the PermissionRequest hook
/// fired. Three seconds is that, plus the sampler's one-second grain.
///
/// ⚠️ The cost, stated: a person who declines within this much of the box
/// appearing moves the screen inside the window, and that one stillness
/// is still read as explained. The next redraw after it is not.
pub const event_redraw_grace_ms: u64 = 3 * std.time.ms_per_s;

/// A permission box's own content, captured after it was drawn: the screen
/// with its volatile rows taken out (`boxPrint`), and the event it was
/// drawn for.
pub const BoxPrint = struct { event_ms: u64, hash: u64 };

const box_seed: u64 = 0x706f_6c74_6572_1655;

/// The screen as a box is identified by: every line of `screen` but those
/// holding one of `volatile_rows`, hashed in order (task 1655). **Null when
/// no line holds one** -- that is, when the box those rows belong to is not
/// on the screen -- and when the CLI declares none, so nothing is ever
/// matched on a screen nobody said how to read.
///
/// Pure, and the only interpretation of a screen the guard does: one
/// substring per row, given by the CLI's adapter (`AgentEvent.volatileRows`).
pub fn boxPrint(screen: []const u8, volatile_rows: []const []const u8) ?u64 {
    if (volatile_rows.len == 0) return null;
    var h: std.hash.Wyhash = .init(box_seed);
    var seen = false;
    var it = std.mem.splitScalar(u8, screen, '\n');
    while (it.next()) |line| {
        const moving = for (volatile_rows) |v| {
            if (std.mem.indexOf(u8, line, v) != null) break true;
        } else false;
        if (moving) {
            seen = true;
            continue;
        }
        h.update(line);
        h.update("\n");
    }
    return if (seen) h.final() else null;
}

/// What an agent said that is waiting in the box. One slot, like
/// `NoticeKind`: a later thing it said replaces an earlier one.
pub const AgentNotice = enum {
    turn_ended,
    turn_failed,
    awaiting_approval,
    awaiting_input,
    /// Hooks were expected and nothing has come.
    hooks_silent,
    /// `+launch` started nothing (task 1667): the adapter could not be run
    /// or built no command, or the CLI was not there. Said once, to whoever
    /// watches the terminal; `detail` has the reason `+launch` gave.
    launch_failed,
    /// Its CLI is asking the person a question before it starts -- a folder
    /// trust box, as its plugin declares (`noteStartupQuestion`, task
    /// 1746). Said to whoever watches it, or else to the supervisor that
    /// launched it; `note` is the question's text.
    startup_question,
};

/// A short string held inside the entry, so an `Entry` stays a value that
/// can be copied out of the map without anything to free.
pub fn Small(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: u8 = 0,

        const Self = @This();

        comptime {
            assert(n <= std.math.maxInt(u8));
        }

        /// Cut on a UTF-8 boundary when it does not fit.
        pub fn set(self: *Self, s: ?[]const u8) void {
            const src = AgentEvent.cutBytes(s orelse "", n);
            @memcpy(self.buf[0..src.len], src);
            self.len = @intCast(src.len);
        }

        pub fn get(self: *const Self) ?[]const u8 {
            if (self.len == 0) return null;
            return self.buf[0..self.len];
        }
    };
}

/// What put an agent's `state` there.
///
/// **Three answers, because "the hooks said so" and "the title (or the
/// screen) says so" are held to different rules.** A hook event is something that happened, and
/// `state` stands until the next one; a title is something being shown,
/// and `state` stands only while it is (task 1656). Rules that ask whether
/// a state is known at all -- `known` -- take either; rules about what a
/// hook did or did not fire take only `hooks`.
pub const SaidBy = enum {
    /// The agent's own hooks, or nothing: the state a terminal starts in.
    hooks,
    /// Its terminal's title matches one its plugin declared
    /// (`Plugin.TitleSays`). The CLI has no hooks to say it with.
    title,
    /// Its screen shows a box its plugin declared (`Plugin.ScreenSays`),
    /// read while its hooks are live because they have no event for an
    /// approval (`Plugin.Manifest.hooks_report_approval`, task 1682). Like
    /// `title`, the state stands only while the screen shows it
    /// (`noteScreenApproval`), and any hook event takes it back.
    screen,
};

/// Everything the bus knows about a terminal's agent from its hooks.
pub const Agent = struct {
    hooks: Hooks,
    state: AgentState,
    /// Whether `state` came from the hooks or from the title. See `SaidBy`.
    said_by: SaidBy,

    /// When `state` last changed, on the bus's clock.
    since_ms: u64,

    /// When a hook event last arrived, or null if none ever has. Not the
    /// same as `since_ms`: an event that repeats the state it is already in
    /// moves this and not that, and the age of what is known is read here.
    last_event_ms: ?u64,

    /// When the wait for the hooks began, for the timeout. **A moment that
    /// happened, always** -- see `expected_said` -- or null while it has
    /// not begun: a CLI whose first hook comes with its first turn
    /// (Codex's `SessionStart`, task 1668) says nothing until somebody
    /// gives it a line, however long it sits at its prompt, so its wait
    /// starts at the first line submitted in the terminal
    /// (`noteLineSubmitted`), not at the launch.
    expected_ms: ?u64,

    /// That the hooks did not come has been put in the box for this wait.
    ///
    /// This used to be said by moving `expected_ms` to the end of time,
    /// "out of reach" of the comparison in `considerAgents`. It was not out
    /// of reach of anything else that reads it: the control room took it as
    /// when the hooks were due, asked to be woken then, and the wake
    /// thread's `@intCast` of the distance took the application down
    /// (2026-10-13, after a supervisor was started whose CLI never spoke).
    /// It also un-said the fault -- "expected thirty seconds ago and
    /// nothing came" stopped being true of a terminal whose hooks were now
    /// expected in the year five hundred million. Two facts, two fields.
    expected_said: bool,

    /// When `+launch` said hooks were coming (`hooks_expected`), or null for
    /// a terminal no launch is waiting on (task 1712). Unlike `expected_ms`
    /// it is always the launch: what `launchWithNoAgent` counts from, for a
    /// CLI that speaks at once and one that waits for its first turn alike.
    launched_ms: ?u64,

    /// An agent has connected from this terminal since `launched_ms`
    /// (`noteAgentHere`). **What tells a launch that came to nothing from an
    /// agent that came and went**: a Codex whose hooks wait for a first
    /// turn is still `expected` after `/exit`, and its exit is not a failed
    /// launch (`launchExitIsFailure`).
    connected: bool,

    session_id: Small(96),
    /// The subagent the last event came from; empty for the main agent
    /// (`AgentEvent.Event.agent_id`). What a finished tool call is paired
    /// with a standing approval by (`resumes`).
    agent_id: Small(64),
    cli: Small(32),
    detail: Small(64),
    note: Small(160),
    /// How long what `note` is the start of was: the whole command, the
    /// whole question (task 1651). More than `note`'s length means the
    /// note stops short, and the line that quotes it has to say so -- a
    /// command cut at a `;` reads as a whole command that ends there.
    note_bytes: u64,
    waiting_on_background: bool,

    /// How many tool calls are running in this agent's turn, by its own
    /// `PreToolUse` and `PostToolUse`/`PostToolUseFailure` (task 1625), or
    /// null when nothing has said: a CLI with no such hooks, a launch made
    /// before they were written, a session that has not started a tool yet.
    ///
    /// **Null and zero are different answers** and are said differently
    /// (`writeTurn`): zero is "a turn with nothing running in it", which is
    /// what a stuck turn looks like; null is "this agent does not tell us",
    /// and saying "nothing running" about it would be a claim (#62).
    tools: ?u8,
    /// The tool started last, while `tools` is not null.
    tool: Small(32),
    /// When `tools` last went from zero to one or from one to zero: how long
    /// something has been running, or how long nothing has.
    tool_ms: u64,

    /// The permission box as it was once drawn, for one whose screen keeps
    /// moving while it stands (task 1655). Null until `noteBoxPrint`, and
    /// again after any event that changes the state.
    box: ?BoxPrint,

    /// The terminal's title is one its CLI's plugin declares as waiting
    /// on an approval (`Plugin.TitleSays`), as of the last title it set.
    /// Kept whoever owns `state`: with hooks live the title does not set
    /// the state (`noteTitle`), but it is still the CLI saying its box is
    /// up -- which is what `promptStanding` asks, and what the screen
    /// cannot answer for a CLI that keeps redrawing under its box (Codex,
    /// task 1668).
    title_waits: bool,

    pending: ?AgentNotice,
    handed: u8,

    /// When `pending` was last handed over, on the bus's clock. Read only
    /// while `handed` is not zero. It is what keeps a notice that went out
    /// on its own a moment ago from riding out again in the next scheduled
    /// box (`takeSome`).
    handed_ms: u64,

    /// No hooks, nothing known. Written out rather than defaulted field by
    /// field, so a field added here has to be given a value in this one
    /// place and every entry starts from it.
    /// When the last event arrived. The notices that say "N seconds ago"
    /// and the rule about a screen drawing an event mean this, not how long
    /// the state has lasted.
    pub fn eventMs(self: Agent) u64 {
        return self.last_event_ms orelse self.since_ms;
    }

    /// Whether `state` is something this terminal's agent said -- through
    /// its hooks, or through a title its plugin declared -- rather than
    /// the default of a terminal nothing has spoken for.
    pub fn known(self: Agent) bool {
        return spoke(self.hooks, self.said_by);
    }

    /// `known` for a terminal described by these two alone -- what
    /// `Attention`'s facts carry -- so the rule has one place.
    pub fn spoke(hooks: Hooks, said_by: SaidBy) bool {
        return switch (said_by) {
            .hooks => hooks == .live,
            .title, .screen => true,
        };
    }

    pub const none: Agent = .{
        .hooks = .none,
        .state = .idle,
        .said_by = .hooks,
        .since_ms = 0,
        .expected_ms = null,
        .expected_said = false,
        .launched_ms = null,
        .connected = false,
        .last_event_ms = null,
        .session_id = .{},
        .agent_id = .{},
        .cli = .{},
        .detail = .{},
        .note = .{},
        .note_bytes = 0,
        .waiting_on_background = false,
        .tools = null,
        .tool = .{},
        .tool_ms = 0,
        .box = null,
        .title_waits = false,
        .pending = null,
        .handed = 0,
        .handed_ms = 0,
    };
};

/// The last finished turn's answer, kept for `terminal_turn`. Owned by the
/// bus, and outside `Entry` so that an entry stays a plain value.
pub const Turn = struct {
    text: []u8,
    /// How long the answer was before `+hook` cut it.
    text_bytes: u64,
    at_ms: u64,
    session_id: Small(96),
};

pub const Entry = struct {
    role: Role = .none,
    duty: Duty = .on,

    /// When the person last looked at this terminal's own row in the
    /// control room, on the bus's clock; null for never (`markSeen`).
    ///
    /// For a terminal in no group: a group's row is looked at through the
    /// group (`Chat.markSeen`), and that had nowhere to go for a row that
    /// is about one terminal -- so what it had finished stayed "not looked
    /// at", and what it had raised could not be withdrawn. **Not written
    /// down**: a terminal's id is new at every start, so a mark kept
    /// against one would name nothing afterwards; it lasts as long as the
    /// terminal does.
    seen_ms: ?u64 = null,

    /// The user is holding this terminal to its work: it may not be
    /// clocked off.
    ///
    /// Enforced here rather than written into the supervisor's prompt on
    /// purpose: a prompt gets pushed out of a long session's context, and
    /// running unattended overnight is exactly when that happens. Code
    /// does not forget.
    ///
    /// Only the user sets this, and a held terminal wears a ring in its
    /// tab for as long as the hold lasts -- a guarantee stated once and
    /// never shown again feels the same as no guarantee at all.
    held: bool = false,

    /// The user has put this terminal out of reach: nothing may read it or
    /// type into it through the tool surface, whoever is asking.
    ///
    /// **Absolute on purpose, and that is the whole design.** Reach is
    /// otherwise decided by what the *target* is marked as -- a supervisor
    /// may touch anything, and anyone may touch a terminal carrying no
    /// mark at all. But `become_supervisor` lets any unmarked terminal
    /// promote itself with no gate whatsoever, so a shield that only held
    /// off non-supervisors would be one tool call from being walked
    /// around. A protection with a published bypass is worse than none: it
    /// is the same exposure, plus somebody believing otherwise.
    ///
    /// Only the user sets it, like `held`, and for the same reason -- a
    /// guarantee the watched party can lift is not a guarantee. The two
    /// are not the same thing and neither implies the other: `held` says
    /// "you may not stop working", this says "nobody may touch you".
    shielded: bool = false,

    /// The colour the user gave this pane (task 1699): a mark the person
    /// makes for themselves, so the user alone sets it. What is kept is
    /// what was *set*; a supervisor with none set is shown in purple, and
    /// `shownColor` is where that is decided.
    color: PaneColor = .none,

    /// The user keeps this terminal for their own commands: no agent is
    /// started in it or beside it (task 1699). Unlike `shielded` it takes
    /// nothing out of reach -- an agent may still read it and type into it
    /// -- so it is a word about what the pane is for, not who may touch it.
    /// The user alone sets it, for the reason written on `shielded`.
    workers: Workers = .allowed,

    /// An agent opened this terminal: `terminal_open`, `role_launch`, or a
    /// new pane in `terminal_layout` (task #989).
    ///
    /// **Where it came from, not what it is now**, and that is why it is not
    /// `role`. A supervisor that lets go of a worker (`set_watch` false,
    /// `unwatch`) makes it `.none` -- and before this bit, closing it then
    /// was closing a terminal the program knew nothing about, which put
    /// "Close Terminal?" in front of the person at the keyboard for a pane
    /// they never opened. So this survives `unwatch` and every other change
    /// of standing, and goes only with the entry (`unregister`, when the
    /// terminal closes).
    ///
    /// Read by `actions.confirmsClose`: an agent may close what an agent
    /// opened without asking anybody.
    opened_by_agent: bool = false,

    /// The terminal whose agent opened this one; null when none did, and
    /// kept as long as `opened_by_agent` is. A tab its supervisor opened
    /// goes into that supervisor's group's project (`Projects`).
    opened_by: ?Id = null,

    /// The supervisor this terminal was opened for as one of its workers --
    /// placed by `role_launch` or `terminal_open` (`App.poltergeist_workers`)
    /// -- whoever is in it now; null otherwise.
    ///
    /// **Not `opened_by`, which says more** (#1498). A supervisor's own
    /// `terminal_action new_split` or `terminal_layout` opens a terminal too,
    /// and for closing it and for which project its tab is in that is the
    /// right answer. But it is not a worker's pane: kept with the project as
    /// one, it came back after a restart as a worker, and the next worker
    /// was placed under it instead of beside the supervisor.
    worker_of: ?Id = null,

    /// Whether a supervisor may answer a permission prompt in this terminal
    /// on its behalf. `null` is "the person has not said for this terminal",
    /// and then the answer is the bus's default (`Config.may_authorise`),
    /// which is **on**.
    ///
    /// **On by default, for every terminal** -- the user's decision of
    /// 2026-10-12 ("所有worker的等待/授权/应该全部丢给总管 ... 首先是这个改成
    /// 默认开"), confirmed the next day for all terminals and not only the
    /// minded ones ("对所有终端"). The arrangement it serves: a worker that
    /// stops on a prompt is the supervisor's to deal with, the supervisor
    /// answers what is plainly within the work and brings the rest to the
    /// person, and the person is seldom sent to a worker's terminal at all.
    ///
    /// It was off by default from 2026-09-08, when the switch was made, and
    /// on only in a terminal a supervisor had opened (2026-10-04). Both of
    /// those are history; `markOpenedByAgent` grants nothing now, because
    /// there is nothing left to grant.
    ///
    /// **How the person says no.** Three ways, from narrowest to widest:
    /// this switch, off, on the terminal's own menu (kept for the life of
    /// that terminal); the shield, which keeps every tool out of the
    /// terminal altogether; and `poltergeist-may-authorise = false` in the
    /// configuration, which makes off the default again for every terminal
    /// and is the one of the three that outlasts a restart -- a terminal's
    /// identity does not, so a choice kept on one has nothing to come back
    /// to.
    ///
    /// **What it opens, in full.** With this on, a supervisor may answer
    /// *either* option -- the one-off `Yes` and the persistent
    /// `Yes, and don't ask again`. The second writes a standing permission
    /// into that directory's configuration, so **every worker that runs
    /// there afterwards stops being asked**. That is what the user is
    /// agreeing to, and it is written here as well as on the menu item
    /// because a switch whose consequence lives only in a comment is a
    /// switch nobody consented to.
    ///
    /// ⚠️ **Polter cannot tell which of the two a supervisor pressed.** It
    /// sends keys; the box is drawn by the program in the terminal. So
    /// "open the one-off but not the persistent one" is not a narrowing
    /// that can be added later by inspecting anything -- it would have to
    /// be a tool that only ever sends the first option's keys. Whoever
    /// comes to narrow this will meet that.
    ///
    /// **Only the user sets it**, like `held` and `shielded`, and for the
    /// reason written on `shielded`: a guarantee the supervised party can
    /// lift is not a guarantee. **It has no keybinding and no
    /// command-palette entry**, deliberately -- `terminal_key` can press any
    /// chord and drive the palette, so either one would be a door an agent
    /// could open for itself and then walk through.
    ///
    /// ⚠️ **What it does not do**, stated here because the menu item says it
    /// too: with this off, `terminal_send` can still put `1` and a return
    /// into that terminal and answer the box that way. That path cannot be
    /// closed without taking away the supervisor's ability to say anything
    /// at all -- assigning a task *is* text plus a return. So this switch
    /// stops the dedicated tool and the casual keypress, and **leaves a
    /// published, logged bypass rather than a silent one**. See the note on
    /// `rpc.authorize`.
    ///
    /// ⚠️ **What the default opens**, in the words used above: any
    /// supervisor can take `Yes, and don't ask again` in any terminal that
    /// is not shielded, which is a standing permission for every agent that
    /// runs in that directory afterwards.
    may_authorise: ?bool = null,

    /// Whether the workers this supervisor minds may name each other in a
    /// group post and be typed into directly (`dev-docs/poltergeist/mentions.md`
    /// part six). Only meaningful on a supervisor's own entry.
    ///
    /// **Off means rewritten, not refused**: a worker naming a worker has the
    /// mention redirected to this supervisor, with the original target said
    /// in the text, so the supervisor decides whether to pass it on. Workers
    /// cannot reach each other otherwise (`rpc.authorize`), and a mention that
    /// typed into a worker would be a way round that.
    ///
    /// **The user's alone**, like `may_authorise` and for the same reason: it
    /// widens what one agent may do to another, so an agent must not be able
    /// to grant it -- no keybinding, no palette entry.
    ///
    /// ⚠️ **In memory, and as long-lived as the supervisor role it sits on.**
    /// `removeSupervisor` clears it and nothing writes it to disk, so a
    /// supervisor stood up again after a restart starts with it off.
    worker_mentions: bool = false,

    /// Which supervisor is minding this terminal -- that is, **which one
    /// gets told when it goes quiet**.
    ///
    /// Routing, and nothing else. This used to be the reach rule as well:
    /// a terminal you watch was a terminal you could read and type into,
    /// and the comment here said that without an owner every supervisor
    /// could steer every other's workers, "which is the thing the star
    /// topology exists to prevent".
    ///
    /// That rule is gone, deliberately. Reach is now decided by what the
    /// *target* is marked as, not by who is minding it: a supervisor may
    /// reach any Polter terminal, and anyone may reach a terminal carrying
    /// no mark. Two supervisors interrupting each other and restarting each
    /// other -- to reload a plugin, say -- is a thing the user asked for,
    /// and the old rule made it impossible. See `rpc.authorize`.
    ///
    /// What is still true is that a terminal has at most one minder, so its
    /// notices go to one box rather than being duplicated into several.
    /// `Entry.shielded` is the mark that takes a terminal out of reach, and
    /// it is the user's alone.
    ///
    /// Null for a terminal nobody is minding, and for the supervisors
    /// themselves.
    ///
    /// ⚠️ **Null with `role == .watched` is a real state, not a gap**: the
    /// user watched it from the tab's menu and no supervisor has claimed
    /// it. Any supervisor may claim it or let it go (`rpc` `set_watch`),
    /// and `hears` says whose box it is in meanwhile.
    watched_by: ?Id = null,

    /// The supervisor that started a role in this terminal, while what is
    /// in the box is that the launch failed (`tellLaunchFailed`). It is
    /// that supervisor's to hear about even when no watch is in force: a
    /// role whose watch waits for its agent never gets one when the agent
    /// never comes (task 1667, measured: `role_launch` answered
    /// `watch: later`, the CLI was not there, and nobody was told).
    launched_by: ?Id = null,

    /// When this supervisor was last handed its box. Only meaningful on a
    /// supervisor's own entry.
    ///
    /// Per supervisor rather than one clock for the bus: two supervisors
    /// minding separate work are interrupted on their own schedules, and a
    /// shared clock would have one of them swallow the other's turn.
    last_delivery_ms: ?u64 = null,

    /// How many scheduled hand-overs have carried this notice already.
    ///
    /// A hand-over is typed into the supervisor's terminal, and typing is
    /// not proof of arrival: if the agent was mid-turn the text lands in
    /// its input box and the return that should submit it does not take.
    /// Clearing the box on the way out made that a silent loss -- the
    /// notice was gone and nothing would say it again.
    ///
    /// So a hand-over holds the notice rather than consuming it, and only
    /// the supervisor reading the box on its own account clears it. This
    /// counts the repeats so a notice nobody ever reads does not repeat
    /// for ever.
    handed_over: u8 = 0,

    /// When this terminal last produced a notice, for rate limiting.
    last_notice_ms: ?u64 = null,

    /// A line the host has asked to put in *this supervisor's* box.
    ///
    /// **Text rather than a kind, and that is the whole design.** Every
    /// other notice is about a terminal, and the bus knows what a terminal
    /// is. This one is about a group -- a task nothing has happened to in
    /// two days, a conversation that stopped at two in the morning -- and
    /// the bus knows nothing about groups, tasks or panels, which is why
    /// it has stayed the size it is. So the host works out the sentence
    /// and the bus does what it is actually for: holding it until the
    /// supervisor may be interrupted, and handing it over exactly once.
    ///
    /// One slot, overwritten rather than queued, the same as `pending`.
    /// The host recomputes the whole sentence each time it looks, so the
    /// newer one is the true one and an older one that had not been
    /// delivered yet is not worth keeping.
    ///
    /// Only ever set on a supervisor's own entry; `leaveNote` refuses
    /// anybody else.
    memo: [memo_bytes]u8 = undefined,
    memo_len: usize = 0,

    /// Hand-overs this memo has already ridden along on, counted the way
    /// `handed_over` counts a terminal's.
    memo_handed: u8 = 0,

    /// How long the screen had been unchanged as of the last report, and
    /// when that report arrived. Together these give the current figure
    /// exactly; see `Bus.quietMs`.
    ///
    /// `last_event_ms` is null until the first report arrives, and that
    /// distinction matters more than it looks. It used to default to zero,
    /// which made `now - 0` -- the whole time the program had been running
    /// -- the answer for a terminal nothing had ever sampled. A terminal
    /// opened a minute ago and working flat out was reported as still for
    /// half a day, and the supervisor's entire judgement is built on this
    /// number: it would go and interrupt a terminal that was fine, or
    /// write it off as dead. Never measured and measured-as-very-quiet
    /// call for opposite actions, so they must not share a value.
    last_quiet_ms: u64 = 0,
    last_event_ms: ?u64 = null,

    /// Whether the sampling a watch asked for is known to be running; see
    /// `Sampling`. Only meaningful while the terminal is watched, and only
    /// read through `samplingOf`, which says so.
    sampling: ?Sampling = null,

    /// When the sampling was found to have failed, while `sampling` says
    /// `failed`.
    sampling_failed_ms: ?u64 = null,

    /// That this terminal's agent went away, when, and whether anything
    /// said why; see `noteLeft`. Null while nothing says it has.
    left: ?Left = null,

    /// When this terminal's agent last called a Polter tool, or null if it
    /// never has; see `noteCall`.
    ///
    /// **A second clock, because the first one cannot see this.** Everything
    /// else here is measured off the screen, and a screen that keeps
    /// changing reads as work. An agent stuck in a retry loop -- a CLI that
    /// hit `ENOTFOUND` and prints its retry countdown for ever -- has a
    /// screen that keeps changing and has stopped working: on the night
    /// this was written, a supervisor read "not quiet" off one of those for
    /// the better part of an hour and waited on a dead worker. An agent
    /// that is working calls tools; one in a loop calls none.
    ///
    /// Null and "a long time ago" are different answers and stay different:
    /// a plain shell, or an agent that has not started yet, has never
    /// spoken to Polter, and nothing about that says it stopped.
    last_call_ms: ?u64 = null,

    /// Whether an agent is connected from this terminal, as the host last
    /// said (`noteAgentHere`, from `Server.agentPresent`); null when it has
    /// not said (#63).
    ///
    /// **Three answers, because the notices need all three.** An agent that
    /// exits leaves its hooks' last state behind -- `awaiting input`, say --
    /// and every other field here as it was, so a terminal that is now a
    /// bare shell read exactly like a worker waiting for its next
    /// instruction. `false` is the one fact that tells them apart, and the
    /// quiet and `no tool call` lines say it (`writeAgentWords`). Null is
    /// "nobody asked", which is not the same as "nobody there".
    agent_here: ?bool = null,

    /// This terminal's own `no tool call` threshold, set by its supervisor
    /// (`setCallsSilentAfter`, `set_quiescence_threshold`'s
    /// `no_tool_call_ms`); null for the configured one (#62). Zero switches
    /// the line off for this terminal. Never turns it on when the
    /// configured one is zero: that is the person switching it off.
    calls_silent_after_ms: ?u64 = null,

    /// How long the calls had been silent when that was last put in the
    /// box, rounded down to a whole threshold, so the next entry comes one
    /// threshold later rather than on every tick. Zero when nothing has
    /// been said since the last call.
    silent_raised_ms: u64 = 0,

    /// Whether the supervisor has a call-silence line about this terminal
    /// it has not been shown; the `pending` of the second clock, and
    /// counted the way `handed_over` counts the first.
    ///
    /// **Its own slot rather than another `NoticeKind`.** A kind overwrites
    /// the kind before it, and the two things said here are not successive
    /// states of one fact: "quiet 900s" and "no tool call 15m" can both be
    /// true, and when only the second is, that difference is the news.
    silent_pending: bool = false,
    silent_handed: u8 = 0,

    /// The program the agent's connection came from, as its sidecar said
    /// when it connected (`agent_cli.Sighting.pid`: the sidecar's parent,
    /// the agent CLI). Null while nobody is connected, and where it is not
    /// read (Windows, today).
    agent_program: ?Program = null,

    /// The agent's connection to Polter went, and when, and which program
    /// it had come from (task 1668, #83). A CLI whose MCP server dies does
    /// not start it again -- Codex 0.163 answers every later tool call with
    /// `Transport closed` -- so an agent can be left running with no way
    /// to report anything, which reads to its supervisor like an agent
    /// that has nothing to say. Null when the connection is there, or its
    /// loss has been looked at (`considerLinks`).
    link_lost: ?LinkLost = null,

    /// That loss, said: its own slot, counted like `silent_pending`. A lost
    /// connection is not a state of the agent's -- it is true alongside
    /// any of them -- so it does not take `agent.pending`'s place.
    link_pending: ?LinkLost = null,
    link_handed: u8 = 0,

    /// How many times the supervisor has been told this terminal is quiet
    /// since it last came back to work.
    ///
    /// Kept here because a count is the first thing a long session forgets,
    /// and the clock-out skill needs one. The judgement of whether there is
    /// anything left to do stays with the supervisor; this is only the
    /// number it counts against.
    rounds: u16 = 0,

    /// What the supervisor has not been shown about this terminal yet.
    ///
    /// One slot, not a queue. A terminal that has been still for an hour
    /// has one thing to say -- that it has been still for an hour -- not
    /// four copies of it a repeat interval apart. Merging as they arrive is
    /// what keeps what the supervisor receives proportional to how many
    /// terminals there are, rather than to how long they have been quiet or
    /// how often anyone looked.
    ///
    /// A later kind overwrites an earlier one, so a terminal that went
    /// quiet and came back before anybody read the box reads as back at
    /// work. That is the true state, and the excursion in between is
    /// precisely the case where nobody needed to do anything.
    pending: ?NoticeKind = null,

    /// What the agent CLI in this terminal has said about itself through
    /// its hooks; see `Agent` and `agentEvent`.
    agent: Agent = .none,
};

pub const Config = struct {
    /// Least time between two interruptions of the supervisor.
    ///
    /// Nothing is put in front of the supervisor as it happens. Reports go
    /// into the box and are handed over on this interval, all of them at
    /// once. So this bounds how often the supervisor is interrupted no
    /// matter how many terminals are watched or how often they report --
    /// the per-terminal gap above cannot do that, because every terminal
    /// keeps its own clock and ten of them make ten times the noise.
    ///
    /// A minute by default, on the grounds that a terminal which has been
    /// still long enough to be worth mentioning is not going to become
    /// urgent in the next sixty seconds. The supervisor can always look
    /// sooner: reading the box itself is not on this schedule.
    notice_interval_ms: u64 = std.time.ms_per_min,

    /// Whether a supervisor may take itself off duty.
    ///
    /// Off means the standing is the user's alone to give and to take
    /// back, the way a hold on a terminal is. On means a supervisor that
    /// has finished can stop being one -- and stop being woken every
    /// interval for a box that will now always be empty.
    stand_down_allowed: bool = true,

    /// How long a terminal may go without calling a Polter tool before
    /// that is worth a line; `poltergeist-calls-silent-after`. Zero says
    /// nothing about it at all. See `Entry.last_call_ms`.
    calls_silent_after_ms: u64 = 15 * std.time.ms_per_min,

    /// What `Entry.may_authorise` is for a terminal whose person has not
    /// said: whether a supervisor may answer its permission prompts.
    /// `poltergeist-may-authorise`. On, by the user's decision of
    /// 2026-10-12; see `Entry.may_authorise`.
    may_authorise: bool = true,
};

alloc: Allocator,
config: Config,
entries: std.AutoHashMapUnmanaged(Id, Entry) = .empty,

/// The last finished turn of each terminal that has had one; see `Turn`.
turns: std.AutoHashMapUnmanaged(Id, Turn) = .empty,

/// The whole of what each terminal is waiting on, while it is waiting:
/// what is to be approved, or the question a dialog asks. Owned; outside
/// `Entry` for the reason `turns` is.
asks: std.AutoHashMapUnmanaged(Id, []u8) = .empty,

/// The tool call each terminal is waiting to have approved, every field of
/// it, while it waits (task 1651): `asks` has only its command or its
/// file. Owned; kept and dropped by the same rule as `asks`. In memory
/// only -- nothing writes it down.
pending_tools: std.AutoHashMapUnmanaged(Id, PendingToolKept) = .empty,

/// What a supervisor has put in front of the person and not yet had looked
/// at: `notify_user` with `authorisation`, by the terminal that called it.
/// The sentence is owned; outside `Entry` for the reason `turns` is.
raises: std.AutoHashMapUnmanaged(Id, RaiseKept) = .empty,

const RaiseKept = struct { at_ms: u64, text: []u8 };

const PendingToolKept = struct { input: []u8, input_bytes: u64, at_ms: u64 };

/// A tool call waiting for approval, as `pendingToolOf` lends it.
pub const PendingTool = struct {
    /// The tool's name: `Agent.detail` while the approval stands.
    name: []const u8,
    /// Its `tool_input` as JSON, as much of it as `+hook` could carry.
    input: []const u8,
    /// How long `input` was before it was cut; more than `input.len`
    /// when it was, and then `input` is no longer whole JSON.
    input_bytes: u64,
    /// When the approval was asked for, on the bus's clock.
    at_ms: u64,
};

/// A supervisor saying "this needs the person": when, and in what words.
pub const Raise = struct { at_ms: u64, text: []const u8 };

/// There may be several supervisors, each minding its own piece of work.
/// What is one at a time is the other direction: a watched terminal has at
/// most one minder, because two of them nudging one input box is, to the
/// agent in it, being given orders by two people who cannot see each
/// other.
pub fn init(alloc: Allocator, config: Config) Bus {
    return .{ .alloc = alloc, .config = config };
}

pub fn deinit(self: *Bus) void {
    var it = self.turns.valueIterator();
    while (it.next()) |t| self.alloc.free(t.text);
    self.turns.deinit(self.alloc);
    var asks = self.asks.valueIterator();
    while (asks.next()) |a| self.alloc.free(a.*);
    self.asks.deinit(self.alloc);
    var tools = self.pending_tools.valueIterator();
    while (tools.next()) |t| self.alloc.free(t.input);
    self.pending_tools.deinit(self.alloc);
    var raises = self.raises.valueIterator();
    while (raises.next()) |r| self.alloc.free(r.text);
    self.raises.deinit(self.alloc);
    self.entries.deinit(self.alloc);
    self.* = undefined;
}

/// Start tracking a terminal. Idempotent.
pub fn register(self: *Bus, id: Id) Allocator.Error!void {
    const gop = try self.entries.getOrPut(self.alloc, id);
    if (!gop.found_existing) gop.value_ptr.* = .{};
}

/// Stop tracking a terminal, for example because it closed.
pub fn unregister(self: *Bus, id: Id) void {
    // A supervisor whose terminal closed releases what it was minding,
    // rather than leaving those terminals pointing at an id that is gone
    // and their notices piling up for nobody.
    self.removeSupervisor(id);
    _ = self.entries.remove(id);
    if (self.turns.fetchRemove(id)) |kv| self.alloc.free(kv.value.text);
    if (self.asks.fetchRemove(id)) |kv| self.alloc.free(kv.value);
    if (self.pending_tools.fetchRemove(id)) |kv| self.alloc.free(kv.value.input);
    if (self.raises.fetchRemove(id)) |kv| self.alloc.free(kv.value.text);
}

/// Record that the supervisor in `id` has put something in front of the
/// person (`notify_user`, `authorisation`): its group is one that is
/// waiting for them from this moment, in these words, without the minute a
/// worker's prompt otherwise spends being the supervisor's.
///
/// **One at a time, and the newest.** A second call replaces the first: the
/// supervisor is one terminal and the person answers it in one place.
///
/// **It stands until the person has looked** -- `raisedOf` is asked with
/// when they last did. Not until the supervisor's next turn: the notice
/// Polter types into a supervisor starts a turn of its own, and a raise
/// that lapsed on that would be gone before anybody had read it. Also
/// gone when the terminal is (`unregister`).
///
/// A terminal the bus has not registered raises nothing: there is no row
/// for it to be on.
pub fn raise(self: *Bus, id: Id, at_ms: u64, text: []const u8) Allocator.Error!bool {
    if (!self.entries.contains(id)) return false;
    const kept = try self.alloc.dupe(u8, text);
    errdefer self.alloc.free(kept);
    const gop = try self.raises.getOrPut(self.alloc, id);
    if (gop.found_existing) self.alloc.free(gop.value_ptr.text);
    gop.value_ptr.* = .{ .at_ms = at_ms, .text = kept };
    return true;
}

/// The person looked at this terminal's own row. False for a terminal the
/// bus does not know: there is no row to have looked at.
pub fn markSeen(self: *Bus, id: Id, now_ms: u64) bool {
    const e = self.entries.getPtr(id) orelse return false;
    e.seen_ms = now_ms;
    return true;
}

/// When the person last looked at this terminal's own row; null for never
/// and for a terminal the bus does not know.
pub fn seenOf(self: *const Bus, id: Id) ?u64 {
    const e = self.entries.get(id) orelse return null;
    return e.seen_ms;
}

/// What this terminal has raised and the person has not looked at since:
/// `seen_ms` is when they last looked at it, null for never. Borrowed:
/// valid until the next `raise` or `unregister` for it.
pub fn raisedOf(self: *const Bus, id: Id, seen_ms: ?u64) ?Raise {
    const r = self.raises.get(id) orelse return null;
    if (seen_ms) |seen| if (seen > r.at_ms) return null;
    return .{ .at_ms = r.at_ms, .text = r.text };
}

/// Record that the agent in `by` opened this terminal
/// (`Entry.opened_by_agent`). Registers it if the bus has not heard of it
/// yet: a terminal the tool surface has just made is usually exactly that.
///
/// **It grants nothing.** From 2026-10-04 a terminal a supervisor opened
/// started with `Entry.may_authorise` on while every other terminal started
/// with it off; since 2026-10-12 it is on for every terminal that has not
/// been told otherwise, so who opened one no longer comes into it -- and
/// with `poltergeist-may-authorise = false` it is off here as everywhere,
/// which is what somebody who set that asked for. `by` is still taken: it
/// is who the record says opened it.
pub fn markOpenedByAgent(self: *Bus, id: Id, by: Id) Allocator.Error!void {
    try self.register(id);
    const e = self.entries.getPtr(id).?;
    e.opened_by_agent = true;
    e.opened_by = by;
}

/// Record that `id` was opened for `by` as one of its workers
/// (`Entry.worker_of`).
pub fn markWorkerOf(self: *Bus, id: Id, by: Id) Allocator.Error!void {
    try self.register(id);
    self.entries.getPtr(id).?.worker_of = by;
}

/// The supervisor `id` was opened for as a worker, or null.
pub fn workerOf(self: *const Bus, id: Id) ?Id {
    const e = self.entries.get(id) orelse return null;
    return e.worker_of;
}

/// The terminal whose agent opened this one, or null.
pub fn openedBy(self: *const Bus, id: Id) ?Id {
    const e = self.entries.get(id) orelse return null;
    return e.opened_by;
}

/// Whether an agent opened this terminal. False for one the bus has never
/// heard of -- that is a terminal nothing recorded opening, which is the
/// user's.
pub fn openedByAgent(self: *const Bus, id: Id) bool {
    const e = self.entries.get(id) orelse return false;
    return e.opened_by_agent;
}

pub fn get(self: *const Bus, id: Id) ?Entry {
    return self.entries.get(id);
}

/// How long this terminal's screen has been unchanged, as of now.
///
/// Extrapolated rather than stale, and that is exact **only because
/// something says so whenever the screen is moving.** The old reasoning
/// here was that a screen that changed would have produced a `resumed`
/// report, so the absence of one meant it had not changed. Half true:
/// `resumed` is emitted once, when a *reported* quiescence ends, and a
/// terminal that has been working ever since produces nothing further. The
/// figure then counted up through the whole of that work, and two
/// terminals whose screens were plainly changing were shown as still for
/// half an hour -- the reading a supervisor interrupts somebody over.
///
/// What closes it is `Sampler.heartbeat`, which restates the live figure
/// while the screen is moving; `noteQuiet` is where it lands. So the
/// invariant this relies on is now stated rather than assumed: **between
/// two things we are told, the screen did not change.**
///
/// Zero for a terminal nothing has sampled yet, which is the honest
/// direction to be wrong in: zero moves the supervisor to do nothing, and
/// a large number moves it to act on evidence it does not have.
pub fn quietMs(self: *const Bus, id: Id, now_ms: u64) u64 {
    const e = self.entries.get(id) orelse return 0;
    const since = e.last_event_ms orelse return 0;
    return e.last_quiet_ms + (now_ms -| since);
}

/// Record how long this terminal's screen has been unchanged, as measured
/// just now by whatever is sampling it.
///
/// Not a report: it makes no notice, counts no round, and wakes nobody. It
/// exists so that `quietMs` has something recent to extrapolate from while
/// the screen is moving, which is the window the event stream says nothing
/// about. See `Sampler.heartbeat`.
///
/// A terminal the bus has never registered is ignored rather than
/// registered here: this arrives once every few seconds from a surface that
/// may never be put under watch, and registering on it would fill the table
/// with entries nobody asked for.
pub fn noteQuiet(self: *Bus, id: Id, quiet_ms: u64, now_ms: u64) void {
    const e = self.entries.getPtr(id) orelse return;

    // A heartbeat the sampler sent before it heard it was stopped arrives
    // after `unwatch` has forgotten the figure. Taken, it would put a
    // measurement back on a terminal nothing measures any more, and
    // `quietMs` would extend it by the wall clock from then on (task 550).
    if (e.role != .watched) return;

    // Only a running sampler sends these, so one arriving confirms it even
    // if the IO thread's own answer was dropped on the way (task 731).
    e.sampling = .running;
    e.last_quiet_ms = quiet_ms;
    e.last_event_ms = now_ms;
}

/// Whether anything has ever sampled this terminal. A caller that can say
/// "not known" should say that rather than pass `quietMs`'s zero on as a
/// measurement.
pub fn observed(self: *const Bus, id: Id) bool {
    const e = self.entries.get(id) orelse return false;
    return e.last_event_ms != null;
}

/// Record that this terminal's agent has just called a Polter tool.
///
/// Only the calls an agent makes: the sidecar's own traffic is sorted out
/// before this, by `rpc.noteCall`, because some of it carries on however
/// dead the agent is. A terminal the bus has never registered is ignored,
/// on the terms `noteQuiet` gives -- nobody is minding it, so there is
/// nobody to tell.
///
/// A call ends the silence, so whatever was waiting in the box about it is
/// no longer true and goes, the way `resumed` replaces a quiet report.
pub fn noteCall(self: *Bus, id: Id, now_ms: u64) void {
    const e = self.entries.getPtr(id) orelse return;
    e.last_call_ms = now_ms;
    e.silent_raised_ms = 0;
    e.silent_pending = false;
    e.silent_handed = 0;
}

/// Whether the agent's own hooks account for it calling nothing: it ended
/// its turn, failed, or is waiting on somebody (task 1503). Only with hooks
/// `live`; a terminal with none is measured as before.
///
/// **Never for an agent that is not there** (#63): an exited worker's last
/// word is usually `turn ended` or `awaiting input`, and taking that as the
/// reason it is silent kept both clocks quiet about a terminal that had
/// become a bare shell.
fn silenceExplained(e: Entry) bool {
    if (e.agent_here == false) return false;
    return e.agent.known() and stateExplains(e.agent.state);
}

/// How long this terminal's calls have been silent, as the `no tool call`
/// notice counts it: since the last call, or since the turn it is in
/// started when that is later -- an agent that waited two hours for an
/// instruction and has just been given one has not been silent for two
/// hours of work (task 1503). Null when it has never called.
fn silenceMs(e: Entry, now_ms: u64) ?u64 {
    const last = e.last_call_ms orelse return null;
    const from = if (e.agent.hooks == .live and e.agent.state == .in_turn) @max(last, e.agent.since_ms) else last;
    return now_ms -| from;
}

/// How long it has been since this terminal last called a Polter tool, or
/// null if it never has. See `Entry.last_call_ms` for why those differ.
pub fn callSilentMs(self: *const Bus, id: Id, now_ms: u64) ?u64 {
    const e = self.entries.get(id) orelse return null;
    const last = e.last_call_ms orelse return null;
    return now_ms -| last;
}

/// The `no tool call` threshold that applies to this terminal: its own
/// when its supervisor set one, the configured one otherwise (#62). Zero
/// means never, and a configured zero stays zero whatever was set here --
/// the person switched the line off, and a supervisor does not switch it
/// back on.
fn callsSilentAfter(self: *const Bus, e: Entry) u64 {
    const configured = self.config.calls_silent_after_ms;
    if (configured == 0) return 0;
    return e.calls_silent_after_ms orelse configured;
}

/// Whether this terminal's calls have been silent for at least its
/// threshold (`callsSilentAfter`). Never, when that is zero.
fn callsSilent(self: *const Bus, id: Id, now_ms: u64) bool {
    const e = self.entries.get(id) orelse return false;
    const after = self.callsSilentAfter(e);
    if (after == 0) return false;
    const silent = self.callSilentMs(id, now_ms) orelse return false;
    return silent >= after;
}

/// Give one terminal its own `no tool call` threshold, or null to go back
/// to the configured one (#62). The quiet threshold has always been per
/// terminal (`set_quiescence_threshold`); this one was the configuration's
/// alone, so a worker told to stand by kept being reported every quarter
/// of an hour after its quiet reports had been turned down.
///
/// A line already in the box that the new threshold would not have raised
/// goes, the way `withdrawQuiet` takes back a quiet report: it is about a
/// rule the supervisor has just changed.
pub fn setCallsSilentAfter(self: *Bus, id: Id, ms: ?u64, now_ms: u64) Allocator.Error!void {
    try self.register(id);
    const e = self.entries.getPtr(id).?;
    e.calls_silent_after_ms = ms;
    const after = self.callsSilentAfter(e.*);
    const silent = silenceMs(e.*, now_ms) orelse 0;
    if (after == 0 or silent < after) {
        e.silent_pending = false;
        e.silent_handed = 0;
        e.silent_raised_ms = 0;
    } else {
        e.silent_raised_ms = @min(e.silent_raised_ms, silent - silent % after);
    }
}

/// Record whether an agent is connected from this terminal, as the host
/// sees it now (#63). The bus cannot see connections; the host asks
/// `Server.agentPresent` and says what it found. See `Entry.agent_here`.
pub fn noteAgentHere(self: *Bus, id: Id, here: bool, program: ?Program, now_ms: u64) void {
    const e = self.entries.getPtr(id) orelse return;
    const was = e.agent_here;
    e.agent_here = here;
    if (here) {
        if (program) |p| e.agent_program = p;
        // The launch being waited on got its agent (task 1712).
        if (e.agent.hooks == .expected) e.agent.connected = true;
        // Back: whatever was about to be said, or was said and not yet
        // read, about it being gone is no longer true.
        e.link_lost = null;
        e.link_pending = null;
        e.link_handed = 0;
        return;
    }
    // Gone, this time: from here, whether its program is still running
    // decides whether that is news (`considerLinks`).
    if (was == true) e.link_lost = .{ .at_ms = now_ms, .program = e.agent_program };
    e.agent_program = null;
    // An agent whose hooks were still awaited has gone (c1669-04: `/exit`
    // before a first turn): nothing more is due from it, and a wait left
    // running would report an agent that is not there.
    if (was == true and e.agent.hooks == .expected) e.agent = .none;
}

/// Put a line in the box for every watched terminal whose agent's
/// connection has been gone `link_grace_ms` while the program it came from
/// is still running in it (`runs`, asked by the host: the bus does not look
/// at processes or screens). Once per loss. A program that has gone is an
/// agent that exited, which the screen and the quiet report already say; a
/// loss with no program known is not said, because it cannot be told from
/// that.
///
/// **And taken back while it waits to be read**, as soon as `runs` says
/// otherwise: a program that was still shutting down when it was looked
/// at, and is gone a moment later, was an agent that exited (#1669
/// c1669-12: a Codex that had quit with `/exit`, reported 40 s later as
/// still running).
///
/// Answers whether anything new went in.
pub fn considerLinks(
    self: *Bus,
    now_ms: u64,
    ctx: *anyopaque,
    runs: *const fn (ctx: *anyopaque, id: Id, program: Program) bool,
) bool {
    var raised = false;
    var it = self.entries.iterator();
    while (it.next()) |kv| {
        const e = kv.value_ptr;
        const id = kv.key_ptr.*;
        if (e.link_pending) |said| {
            const still = if (said.program) |p| runs(ctx, id, p) else false;
            if (!still) {
                e.link_pending = null;
                e.link_handed = 0;
            }
        }
        const lost = e.link_lost orelse continue;
        if (now_ms -| lost.at_ms < link_grace_ms) continue;
        // Looked at once, whatever comes of it.
        e.link_lost = null;
        if (e.role != .watched or e.duty == .off) continue;
        const program = lost.program orelse continue;
        if (!runs(ctx, id, program)) continue;
        e.link_pending = lost;
        e.link_handed = 0;
        raised = true;
    }
    return raised;
}

/// Put a line in the box for every watched terminal whose calls have gone
/// silent for another whole `calls_silent_after_ms`: once at the
/// threshold, again at twice it, and so on, until a call arrives.
///
/// **Arithmetic, not a verdict**, on the terms `report` keeps about a
/// screen. An agent waiting on a permission prompt, or sitting through a
/// forty-minute build, calls nothing and is fine; one stuck retrying a
/// network error calls nothing and is not. The line says how long, and the
/// supervisor goes and reads the terminal.
///
/// **Not driven by the screen, and not gated on it.** The case this exists
/// for is the one where the screen keeps changing, so asking whether the
/// screen is quiet first would be asking the question that already gave
/// the wrong answer.
///
/// Watched terminals only, and not one that has clocked off: the same
/// terminals the quiet reports are about, for the same reasons. A
/// supervisor's own silence cannot go in its own box -- if it is stuck,
/// nobody reads it -- and is shown on its tab instead; see `tabMark`.
///
/// Answers whether anything new went in.
pub fn considerCalls(self: *Bus, now_ms: u64) bool {
    if (self.config.calls_silent_after_ms == 0) return false;

    var raised = false;
    var it = self.entries.iterator();
    while (it.next()) |kv| {
        const e = kv.value_ptr;
        if (e.role != .watched) continue;
        if (e.duty == .off) continue;
        // Its own threshold, when its supervisor gave it one (#62).
        const after = self.callsSilentAfter(e.*);
        if (after == 0) continue;
        // **Not while the agent has said why it is not calling** (task
        // 1503): a turn that ended, failed, or is waiting on somebody has
        // its own notice, and a worker sitting at its prompt waiting for
        // the next instruction is not stuck. The clock is for a turn in
        // progress, and for terminals with no hooks to say anything.
        if (silenceExplained(e.*)) continue;
        const silent = silenceMs(e.*, now_ms) orelse continue;
        if (silent < e.silent_raised_ms + after) continue;

        e.silent_raised_ms = silent - silent % after;
        e.silent_pending = true;
        e.silent_handed = 0;
        raised = true;
    }
    return raised;
}

/// Name the supervisor. Naming a new one steps the previous one down.
/// Make a terminal a supervisor, alongside any others.
///
/// There used to be exactly one, and naming a new one stood the old one
/// down. That made a window hold one job: a single supervisor minding two
/// unrelated pieces of work has to keep both in its head at once, and the
/// notices from both arrive interleaved in one box.
///
/// A terminal already minding others keeps them.
pub fn addSupervisor(self: *Bus, id: Id) Allocator.Error!void {
    try self.register(id);
    const e = self.entries.getPtr(id).?;

    // A supervisor is not watched, by anyone including itself. If it was,
    // that watch ends here the way any other does: what was waiting in a
    // box about it is not carried into its being in charge.
    if (e.role == .watched) release(e);
    e.role = .supervisor;
    e.watched_by = null;
}

/// Stand a supervisor down, releasing the terminals it was minding.
///
/// Released rather than handed on: which supervisor should inherit them is
/// a judgement, and the program guessing would attach somebody's terminals
/// to an agent the user never put in charge of them.
pub fn removeSupervisor(self: *Bus, id: Id) void {
    const e = self.entries.getPtr(id) orelse return;
    if (e.role != .supervisor) return;
    e.role = .none;
    e.last_delivery_ms = null;
    e.worker_mentions = false;

    var it = self.entries.iterator();
    while (it.next()) |kv| {
        const other = kv.value_ptr;
        if (other.watched_by == id) release(other);
    }
}

/// How many terminals `id` is minding.
pub fn mindCount(self: *const Bus, id: Id) usize {
    var n: usize = 0;
    var it = self.entries.iterator();
    while (it.next()) |kv| {
        const w = kv.value_ptr.watched_by orelse continue;
        if (w == id) n += 1;
    }
    return n;
}

pub const StandDownError = error{
    NotASupervisor,
    NotPermitted,
    StillMinding,
};

/// Take a supervisor off duty at its own request.
///
/// Separate from `removeSupervisor`, which is the user's route through the
/// keybind and asks nobody's permission. This one is the agent's, and it
/// is refused in two cases that route is not:
///
/// **While it still minds terminals.** `removeSupervisor` releases them,
/// which is right when a person does it -- they can see the window. Doing
/// it for an agent would turn one call into a silent release of every
/// terminal it was responsible for, and the terminals themselves are never
/// told. So each one has to be let go first, deliberately and one at a
/// time, and standing down is only ever the last step of a wind-down
/// rather than a shortcut past it.
///
/// **When the user has said not to.** Being a supervisor is a standing
/// instruction in the same sense a hold on a terminal is, and for the same
/// reason it lives here: the program holds the line rather than a prompt,
/// because a prompt is what gets compacted out of context at 4am.
pub fn standDown(self: *Bus, id: Id) StandDownError!void {
    const e = self.entries.getPtr(id) orelse return error.NotASupervisor;
    if (e.role != .supervisor) return error.NotASupervisor;
    if (!self.config.stand_down_allowed) return error.NotPermitted;
    if (self.mindCount(id) > 0) return error.StillMinding;

    self.removeSupervisor(id);
}

/// What standing a terminal has. A terminal the bus has never heard of is
/// unclaimed, which is what it is: nobody is minding it.
pub fn roleOf(self: *const Bus, id: Id) Role {
    const e = self.entries.get(id) orelse return .none;
    return e.role;
}

/// Whether this terminal is minding others.
pub fn isSupervisor(self: *const Bus, id: Id) bool {
    const e = self.entries.get(id) orelse return false;
    return e.role == .supervisor;
}

/// Whether `caller` is the supervisor minding `id` -- the one its notices
/// go to.
///
/// **Not a reach test.** It used to be one, and `rpc.authorize` used to
/// call it to decide whether a request could touch a terminal at all. Reach
/// is now decided by the target's own mark; this answers a narrower
/// question, and the places that still ask it -- letting a terminal go,
/// reporting whether a freshly opened tab was claimed -- want that narrower
/// question.
pub fn minds(self: *const Bus, caller: Id, id: Id) bool {
    const e = self.entries.get(id) orelse return false;
    return e.watched_by != null and e.watched_by.? == caller;
}

/// Put a terminal under a supervisor's eye.
///
/// `by` is null when the user did it from the tab's menu or the keyboard
/// and no supervisor has claimed it -- the terminal is watched, and where
/// its notices go until one does is `hears`'s to say.
///
/// **A watch the user made is not a lock** (#1064): a supervisor's `by`
/// on a terminal with no minder takes it, and from then on it is that
/// supervisor's like any other. Only another supervisor's claim refuses.
pub fn watch(self: *Bus, id: Id, by: ?Id) WatchError!void {
    try self.register(id);
    const e = self.entries.getPtr(id).?;
    if (e.role == .supervisor) return;

    // One minder per terminal, so its notices land in one box rather than
    // being duplicated into several. Refused rather than silently taken
    // over: a supervisor that quietly lost a terminal it thought it was
    // minding would go on waiting for reports that now go elsewhere.
    //
    // This is no longer what stops two supervisors typing into the same
    // input box -- reach does not come from here any more. It is about who
    // hears about it.
    if (by) |claimant| {
        if (e.watched_by) |owner| {
            if (owner != claimant) return error.AlreadyWatched;
        }
        e.watched_by = claimant;
    }

    e.role = .watched;
    e.duty = .on;

    // Every watch goes with a request to the terminal's IO thread to
    // sample (`Host.setWatching`, `Surface.setPoltergeistWatching`), and
    // the answer comes back later -- or never. Unconfirmed until it does.
    e.sampling = .starting;
    e.sampling_failed_ms = null;
}

/// What is known of the sampling behind a watch (task 731).
///
/// **Three states, not a failure flag.** The IO thread's answer is sent
/// `.instant` and dropped when the app's mailbox is full, and a thread that
/// has wedged sends nothing at all. With only a "failed" flag, either of
/// those would read as fine. Here they read as `starting` -- not confirmed
/// -- which is what they are.
pub const Sampling = enum {
    /// Asked for, not yet confirmed. Not a fault: it is what every watch is
    /// for the moment after it is made.
    starting,

    /// The IO thread said it started, or something it measured has arrived
    /// -- a heartbeat or a report, which only a running sampler sends.
    running,

    /// The IO thread said it could not: nothing is measuring this terminal,
    /// and no quiet notice will come from it.
    failed,
};

/// Record the IO thread's answer to a request to sample this terminal.
///
/// Recorded whatever the terminal's role, and read only through
/// `samplingOf`, which is the one place that asks whether it is watched:
/// an answer arriving after the watch it belonged to has ended is never
/// shown, and the next watch starts from `starting` again (`watch`).
pub fn noteSampling(self: *Bus, id: Id, started: bool, now_ms: u64) void {
    const e = self.entries.getPtr(id) orelse return;
    e.sampling = if (started) .running else .failed;
    e.sampling_failed_ms = if (started) null else now_ms;
}

/// Record that this terminal's agent is no longer there.
///
/// `failed` only when something said so -- the process ended on its own
/// with an error. Everything else is `unknown`, and stays unknown: an agent
/// the person quit and one that died quietly look the same from here.
/// Undone by the next hook event, which only an agent that is there sends.
pub fn noteLeft(self: *Bus, id: Id, why: Left.Why, now_ms: u64) void {
    const e = self.entries.getPtr(id) orelse return;
    // The first word on it stands: a failure is not downgraded to unknown
    // by the connection closing a moment later.
    if (e.left) |l| if (l.why == .failed or why == .unknown) return;
    e.left = .{ .why = why, .at_ms = now_ms };
    // Its program is gone: so is the wait for its hooks (`noteAgentHere`).
    if (e.agent.hooks == .expected) e.agent = .none;
}

/// Everything the bus knows that decides what this terminal wants from the
/// person, taken at one moment. A terminal the bus has never heard of is a
/// plain one that is not there.
pub fn facts(self: *const Bus, id: Id, now_ms: u64, outside: Attention.Facts.Outside) Attention.Facts {
    const e = self.entries.get(id) orelse {
        var f: Attention.Facts = .none;
        f.id = id;
        f.process = .gone;
        return f;
    };
    return .{
        .id = id,
        .hooks = e.agent.hooks,
        .state = e.agent.state,
        .said_by = e.agent.said_by,
        .state_since_ms = e.agent.since_ms,
        .expected_ms = e.agent.expected_ms,
        .last_event_ms = e.agent.last_event_ms,
        .waiting_on_background = e.agent.waiting_on_background,
        .screen = .of(
            self.samplingOf(id),
            self.quietMs(id, now_ms),
            e.sampling_failed_ms orelse now_ms,
        ),
        .call_silent_ms = self.callSilentMs(id, now_ms),
        // What the caller saw of the process outranks what was noted here:
        // it is looking at the terminal now.
        .process = switch (outside.process) {
            .running => if (e.left) |l| switch (l.why) {
                .failed => .{ .agent_exited = l.at_ms },
                .unknown => .{ .agent_left = l.at_ms },
            } else .running,
            .agent_exited, .agent_left, .gone => outside.process,
        },
        .duty = e.duty,
        .seen_ms = outside.seen_ms,
        .raised_ms = outside.raised_ms,
        .answer = self.answer(id),
        .held = e.held,
        .shielded = e.shielded,
    };
}

/// What is known of the sampling behind this terminal's watch, or null
/// when it is not watched -- whatever is left over from an earlier watch.
pub fn samplingOf(self: *const Bus, id: Id) ?Sampling {
    const e = self.entries.get(id) orelse return null;
    if (e.role != .watched) return null;
    return e.sampling;
}

pub const WatchError = error{
    /// Another supervisor is already minding this terminal.
    AlreadyWatched,
} || Allocator.Error;

/// Stop watching a terminal, without forgetting it.
pub fn unwatch(self: *Bus, id: Id) void {
    if (self.entries.getPtr(id)) |e| release(e);
}

/// End a watch: the one place a terminal stops being watched, whoever
/// ended it -- `unwatch`, a supervisor standing down or closing
/// (`removeSupervisor`), or the terminal being made a supervisor itself
/// (`addSupervisor`).
///
/// One function because the three used to differ, and each difference was
/// something left behind: only `unwatch` forgot the quiet figure, and none
/// of them emptied the box (#1067).
fn release(e: *Entry) void {
    if (e.role == .watched) e.role = .none;
    e.watched_by = null;

    // Letting go stops the sampling (`Host.setWatching`), so the last
    // figure stops being extrapolated from and starts being extended
    // by time nobody measured. Forgetting it is what makes the
    // terminal read as "not measured" again, which is what it is --
    // and what `TerminalInfo.quiet_ms` already promised for a terminal
    // nobody is minding. A released terminal used to keep counting up
    // for as long as the window stayed open.
    e.last_event_ms = null;
    e.last_quiet_ms = 0;

    // The count belongs to the watch that has just ended. Carried
    // across, it would start the next one partway through a tally of
    // reports nobody in it had been given.
    e.rounds = 0;

    // **What was already in the box goes with the watch** (#1067).
    // Measured 2026-10-02: a supervisor let a terminal go, was told "no
    // notices", and a minute later was handed `no tool call 16m` about
    // it. Nothing makes a new notice for a terminal that is not watched
    // -- `report`, `considerCalls`, `agentEvent` and `considerAgents` all
    // ask -- but the one made a minute earlier was still in its slot, and
    // `take` does not ask: with no minder left it fell to whichever
    // supervisor `hears` picked, until its three hand-overs ran out.
    //
    // All three slots, and their counts: left in place they would also
    // come back to life under the next watch, as news about a stretch of
    // time nobody in that watch was responsible for.
    e.pending = null;
    e.handed_over = 0;
    e.silent_pending = false;
    e.silent_handed = 0;
    e.agent.pending = null;
    e.agent.handed = 0;
    e.link_pending = null;
    e.link_handed = 0;
}

/// Hold a terminal to its work, or let it go. The user only -- see
/// `SetHeldError`.
pub fn setHeld(
    self: *Bus,
    id: Id,
    held: bool,
    who: Authority,
) SetHeldError!void {
    if (who != .user) return error.NotPermitted;
    const e = self.entries.getPtr(id) orelse return error.UnknownTerminal;
    e.held = held;
}

/// Put a terminal out of reach of the tool surface, or bring it back. The
/// user only, for the reason written on `Entry.shielded`.
pub fn setShielded(
    self: *Bus,
    id: Id,
    shielded: bool,
    who: Authority,
) SetHeldError!void {
    if (who != .user) return error.NotPermitted;
    const e = self.entries.getPtr(id) orelse return error.UnknownTerminal;
    e.shielded = shielded;

    // **Shielding takes a terminal out of being watched, and leaves a
    // supervisor supervising.** The two look symmetrical and are not.
    //
    // Being watched is being reachable: the arrangement exists so that a
    // supervisor is told this terminal has gone quiet and can then go and
    // look at it. Shield it and the second half is gone, so what is left
    // is a supervisor being woken about a terminal it may not touch --
    // an interruption with no move behind it. Better to say plainly that
    // it is no longer being minded.
    //
    // Supervising is the other direction. A supervisor is the party that
    // reaches, and the shield is about being reached; the two do not meet.
    // A shielded supervisor still minds everything it minded a moment ago
    // and simply cannot be typed into itself -- which is the whole reason
    // somebody would shield the terminal they are running the night from.
    // Clearing the role here would not protect it, it would stop it.
    if (shielded and e.role == .watched) self.unwatch(id);
}

/// The colours a pane may be given. The order is the one the menus lay
/// them out in, and it is also the C enum's
/// (`ghostty_poltergeist_pane_color_e`) and the order the Windows host's
/// palette is indexed by, so a value is never renumbered.
///
/// Blue and red are the status colours' neighbours (`attention`,
/// `problem`); a pane's colour is drawn as a dot or a badge and a status
/// as its glyph, so the shape tells them apart, and the look table keeps
/// their hues apart as far as it can.
pub const PaneColor = enum(u8) {
    none = 0,
    blue = 1,
    purple = 2,
    pink = 3,
    red = 4,
    orange = 5,
    yellow = 6,
    green = 7,
    teal = 8,
    graphite = 9,

    /// The word a project file, a tool reply and a binding action write.
    pub fn name(self: PaneColor) [:0]const u8 {
        return @tagName(self);
    }

    pub fn parse(text: []const u8) ?PaneColor {
        return std.meta.stringToEnum(PaneColor, text);
    }
};

/// Whether workers may be started in a terminal. Two words rather than a
/// bool so that "not said" and "said: allowed" stay apart wherever it is
/// written down.
pub const Workers = enum(u8) {
    allowed = 0,
    refused = 1,
};

/// Give a pane a colour, or take it away (`.none`). The user only, for
/// the reason written on `Entry.color`.
pub fn setPaneColor(
    self: *Bus,
    id: Id,
    color: PaneColor,
    who: Authority,
) SetHeldError!void {
    if (who != .user) return error.NotPermitted;
    const e = self.entries.getPtr(id) orelse return error.UnknownTerminal;
    e.color = color;
}

/// Keep workers out of a terminal, or let them in again. The user only,
/// for the reason written on `Entry.workers`.
pub fn setWorkers(
    self: *Bus,
    id: Id,
    workers: Workers,
    who: Authority,
) SetHeldError!void {
    if (who != .user) return error.NotPermitted;
    const e = self.entries.getPtr(id) orelse return error.UnknownTerminal;
    e.workers = workers;
}

/// The colour a pane was given, `.none` for one the bus has never heard of.
pub fn paneColor(self: *const Bus, id: Id) PaneColor {
    const e = self.entries.get(id) orelse return .none;
    return e.color;
}

/// The colour a pane is shown in: what the user gave it, and for a
/// supervisor given none, the purple of the app's icon. **The one place
/// the core decides it**; the hosts decide the same thing at their own
/// single point (`PaneFrame.badgeGround`, `pane::badge_ground`).
pub fn shownColor(self: *const Bus, id: Id) PaneColor {
    const e = self.entries.get(id) orelse return .none;
    if (e.color == .none and e.role == .supervisor) return .purple;
    return e.color;
}

/// Whether the user keeps workers out of this terminal. A terminal the bus
/// never registered carries no marks, so workers are not refused there.
pub fn workersOf(self: *const Bus, id: Id) Workers {
    const e = self.entries.get(id) orelse return .allowed;
    return e.workers;
}

/// Let a supervisor answer this terminal's permission prompts, or stop it.
/// The user only, for the reason written on `Entry.shielded`.
pub fn setMayAuthorise(
    self: *Bus,
    id: Id,
    may: bool,
    who: Authority,
) SetHeldError!void {
    if (who != .user) return error.NotPermitted;
    const e = self.entries.getPtr(id) orelse return error.UnknownTerminal;
    e.may_authorise = may;
}

/// Let the workers this supervisor minds name each other directly, or go
/// back to having those mentions redirected to it. The user only; see
/// `Entry.worker_mentions`.
pub fn setWorkerMentions(
    self: *Bus,
    id: Id,
    on: bool,
    who: Authority,
) SetWorkerMentionsError!void {
    if (who != .user) return error.NotPermitted;
    const e = self.entries.getPtr(id) orelse return error.UnknownTerminal;
    if (e.role != .supervisor) return error.NotASupervisor;
    e.worker_mentions = on;
}

pub const SetWorkerMentionsError = error{
    UnknownTerminal,
    NotPermitted,

    /// The switch belongs to a supervisor: it says what that supervisor's
    /// workers may do to each other. On anybody else it would mean nothing,
    /// and a "yes" stored there would come back to life if the terminal
    /// were made a supervisor later.
    NotASupervisor,
};

/// Whether this supervisor's workers may name each other directly. False
/// for anything that is not a supervisor.
pub fn workerMentions(self: *const Bus, id: Id) bool {
    const e = self.entries.get(id) orelse return false;
    return e.role == .supervisor and e.worker_mentions;
}

/// The supervisor minding `id`, if one has claimed it.
pub fn minderOf(self: *const Bus, id: Id) ?Id {
    const e = self.entries.get(id) orelse return null;
    return e.watched_by;
}

/// Whether a supervisor may answer a permission prompt in this terminal.
///
/// The person's own choice for this terminal when they have made one, and
/// otherwise the default (`Config.may_authorise`, on). **A terminal the bus
/// has never registered gets the default too**: it used to answer `false`,
/// on the grounds that answering somebody's prompt is not something a
/// terminal falls into by not being registered -- but the default is now a
/// thing the user chose for every terminal, and an unregistered one is a
/// terminal nobody has said otherwise about.
pub fn mayAuthorise(self: *const Bus, id: Id) bool {
    const e = self.entries.get(id) orelse return self.config.may_authorise;
    return e.may_authorise orelse self.config.may_authorise;
}

/// Why a supervisor may or may not answer this terminal's prompt, as the
/// notice about that prompt says it.
pub const Answer = enum {
    allowed,
    /// The person switched it off, here or in the configuration.
    off,
    /// Nothing reaches a shielded terminal, this included.
    shielded,

    pub fn word(self: Answer) []const u8 {
        return switch (self) {
            .allowed => "allowed",
            .off => "off",
            .shielded => "shielded",
        };
    }
};

pub fn answer(self: *const Bus, id: Id) Answer {
    if (self.isShielded(id)) return .shielded;
    return if (self.mayAuthorise(id)) .allowed else .off;
}

/// Whether the tool surface may reach this terminal at all.
///
/// Asked of the target alone. A terminal the bus has never registered is
/// not shielded -- it carries no marks of any kind, which is exactly the
/// case the reach rule treats as open.
pub fn isShielded(self: *const Bus, id: Id) bool {
    const e = self.entries.get(id) orelse return false;
    return e.shielded;
}

/// Clock a terminal off. The supervisor only, and never one the user is
/// holding to its work.
pub fn clockOff(self: *Bus, id: Id, who: Authority) ClockOffError!void {
    if (who != .supervisor) return error.NotPermitted;
    const e = self.entries.getPtr(id) orelse return error.UnknownTerminal;
    if (e.held) return error.TerminalHeld;
    e.duty = .off;
}

/// Put a terminal back on duty. Either the user or the supervisor may do
/// this: coming back to work is not the dangerous direction.
pub fn clockOn(self: *Bus, id: Id) ClockOffError!void {
    const e = self.entries.getPtr(id) orelse return error.UnknownTerminal;
    e.duty = .on;
}

/// Turn a sampler event into a notice for the supervisor, or decide there
/// is nothing worth saying.
///
/// Returns null when there is no supervisor, when the terminal is not
/// watched, when it has clocked off, when it is the supervisor itself, or
/// when it spoke too recently.
pub fn report(
    self: *Bus,
    about: Id,
    event: Sampler.Event,
    now_ms: u64,
) bool {
    // Recorded on the terminal it is about, and sorted out at delivery by
    // who is minding it. Deciding here would mean a terminal watched
    // before any supervisor claimed it had nowhere to put its report.
    const e = self.entries.getPtr(about) orelse return false;
    if (e.role == .supervisor) return false;

    const kind: NoticeKind, const report_data = switch (event) {
        .quiescent => |r| .{ NoticeKind.quiescent, r },
        .still_quiescent => |r| .{ NoticeKind.still_quiescent, r },
        .resumed => |r| .{ NoticeKind.resumed, r },
    };

    // Not watched is not measured: a report that lands after `unwatch` is
    // one the sampler sent before it was told to stop, and recording it
    // would give a released terminal a quiet time again -- one `quietMs`
    // then extends for as long as the window is open (task 550).
    if (e.role != .watched) return false;

    // Evidence the sampler is running, on the same terms as a heartbeat.
    e.sampling = .running;

    // Track the duration whatever we decide to do about telling anyone.
    // `terminal_list` reads this, and a terminal that is not being reported
    // -- clocked off, or rate limited -- is still worth answering about
    // when the supervisor asks directly.
    e.last_event_ms = now_ms;
    e.last_quiet_ms = switch (kind) {
        .quiescent, .still_quiescent => report_data.quiet_ms,
        // Just came back to work: the clock starts again from here.
        .resumed => 0,
    };
    e.rounds = switch (kind) {
        .quiescent, .still_quiescent => e.rounds +| 1,
        .resumed => 0,
    };

    // A terminal that has clocked off is supposed to be quiet. Saying so
    // again every quarter of an hour is exactly the kind of nagging that
    // makes someone turn the whole thing off.
    if (e.duty == .off) return false;

    // **The screen moving is not the agent going back to work when its
    // hooks say it is not** (task 1503): an agent that ended its turn, or
    // is waiting, redraws its prompt without starting anything, and a new
    // turn says so itself (`turn_started`). The quiet report it replaces
    // goes too: it was about a stillness the agent had already explained.
    if (kind == .resumed and self.quietExplained(about, now_ms)) {
        e.pending = null;
        e.handed_over = 0;
        return false;
    }

    // Into the box. One slot per terminal, so a later report replaces an
    // earlier one rather than stacking behind it.
    //
    // There is no rate limit here any more, and there should not be one: a
    // limit at this end would decide what the supervisor is allowed to find
    // out, and a terminal that went quiet during a busy moment would stay
    // unmentioned for good. How often the supervisor is *interrupted* is a
    // separate question, answered by `notice_interval_ms` at the other end.
    e.pending = kind;
    e.last_notice_ms = now_ms;
    return true;
}

/// Take back a quiet report the terminal's new threshold says is not yet
/// worth making (task 873).
///
/// **The sampler is not where the repeats came from.** A new threshold does
/// reach it (`termio.Thread`, `.poltergeist_threshold`), and from then on it
/// says nothing until the screen has been still that long. But the report
/// it made under the old threshold is already in the box, and a hand-over
/// holds a notice rather than consuming it (`take`, `.hand_over`), so it
/// went on being typed into the supervisor once a notice interval, with a
/// freshly extrapolated figure each time -- three terminals raised to an
/// hour were still reported "quiet 241s", "301s", "375s". The bus does not
/// own the threshold, so it is told the new one here and drops a report
/// that no longer clears it.
///
/// Only quiet reports, and only while the figure is under the threshold: a
/// `resumed` is news whatever the threshold, and a terminal already still
/// for longer than the new one would be reported again at once anyway.
pub fn withdrawQuiet(self: *Bus, id: Id, threshold_ms: u64, now_ms: u64) void {
    const e = self.entries.getPtr(id) orelse return;
    const kind = e.pending orelse return;
    if (kind == .resumed) return;
    if (self.quietMs(id, now_ms) >= threshold_ms) return;
    e.pending = null;
    e.handed_over = 0;
}

/// Record something a terminal's agent CLI said about itself through its
/// hooks (`rpc` method `agent_event`, sent by `polter +hook`).
///
/// **Not a tool call.** `rpc.isAgentCall` keeps these away from `noteCall`,
/// because a hook that refreshed the call clock would hide the very silence
/// that clock exists to find.
///
/// Registers the terminal if the bus has never seen it: unlike a screen
/// heartbeat this is rare, it comes from the terminal itself, and an agent
/// state nobody can list is no use to anybody. What goes in the box follows
/// `report`: watched terminals only, and not one that has clocked off.
///
/// Answers whether anything went in the box.
pub fn agentEvent(
    self: *Bus,
    id: Id,
    ev: AgentEvent.Event,
    now_ms: u64,
) Allocator.Error!bool {
    // **The launch started nothing**: whatever it said to expect is taken
    // back, and the terminal is what it was before the launch line -- a
    // shell with no agent in it. Before `register`, because a failure that
    // came before anything else was said (no adapter, no such role) is not
    // a reason for the bus to start keeping an entry for a plain terminal.
    //
    // Only an expectation is taken back. An agent that has spoken is
    // there, whatever a launch line typed at it afterwards came to.
    if (ev.event == .launch_failed) {
        const e = self.entries.getPtr(id) orelse return false;
        // An agent that has spoken is there; a launch line typed at it
        // came to nothing, and that is not news about it.
        if (e.agent.hooks == .live) return false;
        if (e.agent.hooks == .expected) e.agent = .none;
        // **And whoever watches it is told** (task 1667). The line on the
        // screen said why to whoever looks at the tab; a supervisor that
        // ran `role_launch` is not looking at it, and used to hear nothing
        // at all -- measured: a Codex role whose adapter could not be run
        // left its supervisor's notices empty for a minute and more, with
        // the terminal back at a shell prompt.
        if (e.role != .watched or e.duty == .off) return false;
        e.agent.pending = .launch_failed;
        e.agent.handed = 0;
        e.agent.detail.set(ev.detail);
        e.agent.note.set(ev.note);
        e.agent.since_ms = now_ms;
        return true;
    }

    // About a file, not about the agent: nothing here is touched, not even
    // "when it was last heard from" -- that clock is what says a prompt on
    // screen is still the one that was asked about.
    if (ev.event == .allowance_written) return false;

    // **A tool call started, or one ended: counted, and nothing else
    // moves** (task 1625). Both are said around every tool call in a turn;
    // what they add is whether something is running now, which the `no
    // tool call` line needs and nothing else does (`writeTurn`). Not the
    // state, not the clocks, not the box, not a terminal the bus has never
    // seen.
    if (ev.event == .tool_started) {
        const e = self.entries.getPtr(id) orelse return false;
        toolStarted(&e.agent, ev.detail, now_ms);
        return false;
    }

    // **A tool call finished: only a terminal that was waiting moves**
    // (task 1561). Said after every tool call in a turn, so in any other
    // state it is not news and touches nothing more than the count above.
    if (ev.event == .turn_resumed) {
        const e = self.entries.getPtr(id) orelse return false;
        toolEnded(&e.agent, now_ms);
        if (!resumes(e.agent, ev)) return false;
    }

    try self.register(id);
    const e = self.entries.getPtr(id).?;
    const a = &e.agent;

    if (ev.cli.len > 0) a.cli.set(ev.cli);
    if (ev.session_id) |sid| a.session_id.set(sid);

    const state: AgentState, const notice: ?AgentNotice = switch (ev.event) {
        .launch_failed, .tool_started => unreachable,
        .hooks_expected => {
            // A second launch in the same terminal starts the wait again;
            // a terminal already live stays live -- it has proved its
            // hooks, and a later launch line typed into it is not the
            // agent that proved them, but it will say `session_started`
            // soon enough if it is.
            a.* = .none;
            a.hooks = .expected;
            a.expected_ms = if (AgentEvent.heardAtFirstTurn(ev.detail)) null else now_ms;
            a.launched_ms = now_ms;
            a.since_ms = now_ms;
            e.left = null;
            if (ev.cli.len > 0) a.cli.set(ev.cli);
            return false;
        },
        .allowance_written => return false,
        .session_started => .{ .idle, null },
        .turn_started, .turn_resumed => .{ .in_turn, null },
        .turn_ended => .{ .ended, .turn_ended },
        .turn_failed => .{ .failed, .turn_failed },
        .awaiting_approval => .{ .awaiting_approval, .awaiting_approval },
        .awaiting_input => .{ .awaiting_input, .awaiting_input },
    };

    // Any event is the hooks working, so `expected` resolves. A
    // `hooks_silent` line still in the box goes below with everything
    // else: each event either clears the slot or replaces it.
    const before = a.*;
    a.hooks = .live;
    // A hook outranks a title: whatever the title was saying, this is the
    // agent's own word, and from here on only its hooks set the state.
    a.said_by = .hooks;

    a.state = state;
    a.last_event_ms = now_ms;

    // An agent that speaks is there, whatever was concluded when it went
    // quiet.
    e.left = null;
    a.agent_id.set(ev.agent_id);
    a.detail.set(ev.detail);
    a.note.set(ev.note);
    // Whatever box was captured was for the last thing said.
    a.box = null;
    a.note_bytes = if (ev.note) |n| @max(n.len, ev.text_bytes) else 0;

    // **`since_ms` moves when the state does, and not when it is said
    // again.** A supervisor pressing a working agent starts another turn
    // inside the one it is in, and an agent left waiting is announced more
    // than once; resetting the clock on each would make the one that has
    // waited longest look like the newest. Waiting on a *different* thing
    // is a change -- a second permission box is not the first one still
    // open -- so for the two waiting states what is waited on is part of
    // the state. When an event arrived at all is `last_event_ms`.
    if (!sameState(before, a.*)) a.since_ms = now_ms;
    a.waiting_on_background = ev.event == .turn_ended and ev.waiting_on_background;

    // A turn's edges end whatever tool count it had: a command declined
    // without feedback ends the turn with no hook (#879), and its start was
    // counted. A new session has not said yet whether it reports tools.
    switch (ev.event) {
        .turn_started, .turn_ended, .turn_failed => if (a.tools) |n| {
            if (n != 0) a.tool_ms = now_ms;
            a.tools = 0;
        },
        .session_started => {
            a.tools = null;
            a.tool.set(null);
        },
        else => {},
    }

    if (ev.event == .turn_ended) try self.keepTurn(id, ev, now_ms);
    try self.keepAsk(id, ev);
    try self.keepPendingTool(id, ev, now_ms);

    // A new turn makes whatever was waiting about the last one stale, the
    // way `resumed` replaces a quiet report. The `no tool call` clock
    // starts again with it too (`silenceMs`): what was said about the wait
    // before it is not about this turn.
    // What was waiting has been answered: an `awaiting` line still in the
    // box would send the supervisor to a prompt that is gone.
    if (ev.event == .turn_resumed) {
        if (a.pending) |kind| if (isWaiting(kind)) {
            a.pending = null;
            a.handed = 0;
        };
    }
    if (ev.event == .turn_started or ev.event == .session_started) {
        a.pending = null;
        a.handed = 0;
        e.silent_pending = false;
        e.silent_handed = 0;
        e.silent_raised_ms = 0;
    }

    const kind = notice orelse return false;
    if (e.role != .watched or e.duty == .off) return false;
    if (!saysSomethingNew(before, a.*, kind)) return false;
    a.pending = kind;
    a.handed = 0;
    return true;
}

/// What the terminal's title says now, as its plugin declared it (task
/// 1656): `waits_for` is the key of the plugin whose `title_says` matched
/// -- the CLI is waiting on an approval -- or null when none did.
///
/// **For a CLI that has no hooks.** Codex's approval box keeps its screen
/// moving, so no quiet report comes and nothing else would ever say it is
/// stuck; it says so in its title instead. A terminal whose hooks are live
/// is left to them: they say more, and two voices for one state would
/// disagree.
///
/// **The state lasts as long as the title.** Entering puts
/// `awaiting_approval` in place with the title as its note, and the same
/// line in the box a hook's would; another title that still matches --
/// Codex alternates `[ ! ]` and `[ . ]` once a second -- is the same wait.
/// A title that no longer matches ends it, and takes back a line still
/// waiting to be read, as an answered prompt does.
///
/// Answers whether anything went in the box.
pub fn noteTitle(self: *Bus, id: Id, waits_for: ?[]const u8, title: []const u8, now_ms: u64) Allocator.Error!bool {
    if (self.entries.getPtr(id)) |e| {
        e.agent.title_waits = waits_for != null;
        if (e.agent.hooks == .live) return false;
    }

    const cli = waits_for orelse {
        const e = self.entries.getPtr(id) orelse return false;
        const a = &e.agent;
        switch (a.said_by) {
            .title => {},
            // Not the title's to take back.
            .hooks, .screen => return false,
        }
        a.said_by = .hooks;
        a.state = .idle;
        a.since_ms = now_ms;
        a.last_event_ms = now_ms;
        a.detail.set(null);
        a.note.set(null);
        if (a.pending) |kind| if (isWaiting(kind)) {
            a.pending = null;
            a.handed = 0;
        };
        return false;
    };

    try self.register(id);
    const e = self.entries.getPtr(id).?;
    const a = &e.agent;
    a.title_waits = true;
    if (a.said_by == .title and a.state == .awaiting_approval) return false;

    a.said_by = .title;
    a.state = .awaiting_approval;
    a.since_ms = now_ms;
    a.last_event_ms = now_ms;
    a.detail.set("title");
    a.note.set(title);
    if (a.cli.get() == null) a.cli.set(cli);

    if (e.role != .watched or e.duty == .off) return false;
    a.pending = .awaiting_approval;
    a.handed = 0;
    return true;
}

/// Whether an agent event is news for the supervisor (task 1503).
///
/// **Once per state, not once per event.** An agent left waiting says so
/// again: Claude Code sends its idle notification over and over while it
/// sits at the prompt, and each one used to put the same `awaiting input`
/// line back in the box -- a supervisor got it every minute until it
/// switched watching off. A waiting state said again, waiting on the same
/// thing (`sameState`), is not news; waiting on something else is.
///
/// **And an idle prompt after a turn that ended is the same news again.**
/// The supervisor has just been told the turn ended; Claude Code's
/// `idle_prompt` a minute later only says it is still sitting there.
/// A question it actually asks (`elicitation_dialog`) is news.
fn saysSomethingNew(was: Agent, is: Agent, kind: AgentNotice) bool {
    if (isWaiting(kind) and sameState(was, is)) return false;
    if (kind == .awaiting_input and was.hooks == .live and
        (was.state == .ended or was.state == .failed) and
        sameText(is.detail.get(), idle_prompt)) return false;
    return true;
}

/// Whether a finished tool call takes this agent back to work: it was
/// stopped on an approval and the agent that asked has finished a tool
/// call since, or on a question asked inside its turn.
///
/// **Paired by who asked, not by which tool.** Claude Code's `PostToolUse`
/// fires for every tool call, a subagent's included, and its
/// `PermissionRequest` carries no `tool_use_id`; both carry `agent_id`
/// inside a subagent and neither does on the main thread (measured in the
/// 2.1.300 binary: both inputs take `tool_name` from the tool's own
/// `name`, and the common fields describe `agent_id` that way). So a
/// subagent's `Read` finishing while the main agent waits on `Bash` leaves
/// the prompt standing. The tool's name would have paired them too, but
/// not the case that matters next: an approval **declined with feedback**
/// does not end the turn (only one declined without any does), the agent
/// goes on with some other tool, and only `Stop` would have moved it. A
/// question has no tool of its own (an MCP dialog's tool is not named in
/// it), so any tool call ends it.
///
/// **Not an idle prompt.** That is `awaiting_input` too, but it comes after
/// the turn ended, with nothing left to resume; a tool call heard then (a
/// subagent's, a late one) does not start a turn -- `turn_started` does.
fn resumes(a: Agent, ev: AgentEvent.Event) bool {
    if (a.hooks != .live) return false;
    return switch (a.state) {
        .awaiting_approval => sameText(a.agent_id.get(), ev.agent_id),
        .awaiting_input => !sameText(a.detail.get(), idle_prompt),
        .idle, .in_turn, .ended, .failed => false,
    };
}

/// A tool call started (task 1625): one more running, and it is the one
/// named from now on.
fn toolStarted(a: *Agent, tool: ?[]const u8, now_ms: u64) void {
    const n = a.tools orelse 0;
    if (n == 0) a.tool_ms = now_ms;
    a.tools = n +| 1;
    a.tool.set(tool);
}

/// A tool call ended. Counted only for an agent that has said its tools
/// start: an end with no start heard is a launch made without
/// `PreToolUse`, and taking it as "nothing running" would be a guess.
fn toolEnded(a: *Agent, now_ms: u64) void {
    const n = a.tools orelse return;
    if (n == 0) return;
    a.tools = n - 1;
    if (n == 1) a.tool_ms = now_ms;
}

/// What Claude Code's adapter writes as the detail of an idle notification
/// (`plugins/claude-code/adapter.py`, the `Notification` hook's
/// `idle_prompt`).
const idle_prompt = "idle_prompt";

/// Whether an event left the agent in the state it was already in.
fn sameState(was: Agent, is: Agent) bool {
    if (was.hooks != .live or was.state != is.state) return false;
    return switch (is.state) {
        .awaiting_approval, .awaiting_input => sameText(was.detail.get(), is.detail.get()) and
            sameText(was.note.get(), is.note.get()),
        .idle, .in_turn, .ended, .failed => true,
    };
}

fn sameText(a: ?[]const u8, b: ?[]const u8) bool {
    return std.mem.eql(u8, a orelse "", b orelse "");
}

/// Whether the prompt a caller saw is the one still standing in this
/// terminal: the agent is waiting on an approval, it has been since
/// `since_ms`, nothing has been heard from it after `event_ms`, and -- where
/// the screen is measured -- the screen has not moved since the box was
/// drawn. The last is what catches a box the person dismissed at the
/// terminal, which fires no hook at all (#879).
///
/// Everything that types an answer into a prompt on the person's behalf
/// asks this first, and sends nothing when it says no.
///
/// `screen` is the terminal's screen as it is now, read only when
/// `promptNeedsScreen` says it would be looked at; null otherwise.
///
/// **A box whose own rows keep redrawing is the same box while the rest of
/// it is** (task 1655). Claude Code's auto-mode countdown redraws every
/// second, so the screen never stops moving and the rule above -- it has
/// not moved since the box was drawn -- refused every answer to such a box
/// for as long as it stood. For one, the box's content was captured after
/// it was drawn (`noteBoxPrint`), without the rows its CLI says redraw;
/// the screen now, read the same way, has to match it. Not looser than
/// that: the event is still this one, so a second box -- which says a
/// `PermissionRequest` of its own -- is not it; the volatile row has to be
/// on screen now, so a box that was declined (no hook) is not it; and
/// every other row has to be as it was, so a screen that moved on is not.
pub fn promptStanding(self: *const Bus, id: Id, since_ms: u64, event_ms: u64, now_ms: u64, screen: ?[]const u8) bool {
    const e = self.entries.get(id) orelse return false;
    const a = e.agent;
    // **A title's wait stands while the title does** (task 1656), and
    // `noteTitle` ends it the moment the title changes. The screen is no
    // help here: Codex keeps redrawing under its box, which is the reason
    // the title is read at all.
    switch (a.said_by) {
        // A screen's wait is the same: `noteScreenApproval` ends it the
        // moment the box is no longer on the screen.
        .title, .screen => return a.state == .awaiting_approval and a.since_ms == since_ms and
            a.last_event_ms != null and a.last_event_ms.? == event_ms,
        .hooks => {},
    }
    if (a.hooks != .live or a.state != .awaiting_approval) return false;
    if (a.since_ms != since_ms) return false;
    if (a.last_event_ms == null or a.last_event_ms.? != event_ms) return false;
    if (self.quietExplained(id, now_ms)) return true;
    // The CLI's own title says its box is up. A box answered and another
    // asked has another event; a box gone takes the title with it.
    if (a.title_waits) return true;
    const box = a.box orelse return false;
    if (box.event_ms != event_ms) return false;
    const now = boxPrint(screen orelse return false, AgentEvent.volatileRows(a.cli.get() orelse "")) orelse return false;
    return now == box.hash;
}

/// Whether `promptStanding` would read the screen for this terminal: a box
/// was captured for its approval (`noteBoxPrint`). The callers read it only
/// then, so an answer to an ordinary box costs no read.
pub fn promptNeedsScreen(self: *const Bus, id: Id) bool {
    const e = self.entries.get(id) orelse return false;
    return e.agent.state == .awaiting_approval and e.agent.box != null;
}

/// Whether this terminal's permission box should be captured now: it is
/// waiting on an approval whose box has had `event_redraw_grace_ms` to be
/// drawn, none was captured for it yet, and its CLI says which of the box's
/// rows redraw (task 1655). Asked on each heartbeat -- which is the only
/// thing that runs while a screen keeps moving, and so exactly while it
/// matters.
/// Whether this terminal's screen is to be read for an approval box, for
/// a CLI whose hooks are live and say nothing about approvals (task 1682,
/// `Plugin.screenApprovalFor` is the caller's half). Only while a tool is
/// running -- a box is asked for a tool, and between tools there is none to
/// look for -- or while the screen is already what says it waits, so that
/// its going is seen.
pub fn wantsScreenApproval(self: *const Bus, id: Id) bool {
    const e = self.entries.get(id) orelse return false;
    const a = e.agent;
    if (a.hooks != .live) return false;
    return switch (a.said_by) {
        .screen => a.state == .awaiting_approval,
        .hooks => a.state == .in_turn and (a.tools orelse 0) > 0,
        .title => false,
    };
}

/// What the screen of a terminal `wantsScreenApproval` picked shows now:
/// `said` is the declared text of a box that is up (`ScreenSays.approvalSaid`),
/// or null when none is (task 1682).
///
/// **The state lasts as long as the screen shows the box**, as a title's
/// does (`noteTitle`): entering puts `awaiting_approval` in place with the
/// text as its note and the same line in the box a hook's would; a box
/// still there is the same wait; a screen without it ends it -- back to the
/// turn, with a line still waiting to be read taken back. Any hook event
/// ends it too, since it puts `said_by` back to `hooks` (`agentEvent`).
///
/// Answers whether anything went in the box.
pub fn noteScreenApproval(self: *Bus, id: Id, said: ?[]const u8, now_ms: u64) bool {
    const e = self.entries.getPtr(id) orelse return false;
    const a = &e.agent;
    if (a.hooks != .live) return false;

    const text = said orelse {
        switch (a.said_by) {
            .screen => {},
            .hooks, .title => return false,
        }
        a.said_by = .hooks;
        a.state = .in_turn;
        a.since_ms = now_ms;
        a.last_event_ms = now_ms;
        a.detail.set(null);
        a.note.set(null);
        if (a.pending) |kind| if (isWaiting(kind)) {
            a.pending = null;
            a.handed = 0;
        };
        return false;
    };

    switch (a.said_by) {
        .screen => return false,
        .title => return false,
        .hooks => if (a.state != .in_turn or (a.tools orelse 0) == 0) return false,
    }
    a.said_by = .screen;
    a.state = .awaiting_approval;
    a.since_ms = now_ms;
    a.last_event_ms = now_ms;
    a.detail.set("screen");
    a.note.set(text);
    a.box = null;

    if (e.role != .watched or e.duty == .off) return false;
    a.pending = .awaiting_approval;
    a.handed = 0;
    return true;
}

pub fn wantsBoxPrint(self: *const Bus, id: Id, now_ms: u64) bool {
    const e = self.entries.get(id) orelse return false;
    const a = e.agent;
    if (a.hooks != .live or a.state != .awaiting_approval) return false;
    if (a.box) |b| if (b.event_ms == a.eventMs()) return false;
    if (AgentEvent.volatileRows(a.cli.get() orelse "").len == 0) return false;
    return now_ms >= a.eventMs() + event_redraw_grace_ms;
}

/// Keep the box captured for the approval asked at `event_ms`, if that is
/// still the one waiting. `screen` is the terminal's screen as read now;
/// nothing is kept when the box's volatile rows are not on it -- not drawn
/// yet, or already gone -- and the next heartbeat asks again.
pub fn noteBoxPrint(self: *Bus, id: Id, event_ms: u64, screen: []const u8) bool {
    const e = self.entries.getPtr(id) orelse return false;
    const a = &e.agent;
    if (a.hooks != .live or a.state != .awaiting_approval) return false;
    if (a.last_event_ms == null or a.last_event_ms.? != event_ms) return false;
    const hash = boxPrint(screen, AgentEvent.volatileRows(a.cli.get() orelse "")) orelse return false;
    a.box = .{ .event_ms = event_ms, .hash = hash };
    return true;
}

/// The whole of what this terminal is waiting to have approved, or null
/// when it is not waiting on an approval or its hook sent only the summary.
/// Borrowed: valid until the next `agentEvent` or `unregister` for it.
pub fn askOf(self: *const Bus, id: Id) ?[]const u8 {
    return self.asks.get(id);
}

/// An approval's whole text is kept while the approval stands; any other
/// event means it no longer does.
fn keepAsk(self: *Bus, id: Id, ev: AgentEvent.Event) Allocator.Error!void {
    // What is to be approved, or the question a dialog asks.
    const whole: ?[]const u8 = switch (ev.event) {
        .awaiting_approval, .awaiting_input => ev.text,
        else => null,
    };
    const text = whole orelse {
        if (self.asks.fetchRemove(id)) |kv| self.alloc.free(kv.value);
        return;
    };
    const kept = try self.alloc.dupe(u8, text);
    errdefer self.alloc.free(kept);
    const gop = try self.asks.getOrPut(self.alloc, id);
    if (gop.found_existing) self.alloc.free(gop.value_ptr.*);
    gop.value_ptr.* = kept;
}

/// The tool call waiting for approval in this terminal, or null when it is
/// not waiting on one or its hook did not send it. Borrowed: valid until
/// the next `agentEvent` or `unregister` for it.
pub fn pendingToolOf(self: *const Bus, id: Id) ?PendingTool {
    const t = self.pending_tools.get(id) orelse return null;
    // The entry itself, not a copy: the name is lent out of it.
    const e = self.entries.getPtr(id) orelse return null;
    return .{
        .name = e.agent.detail.get() orelse "",
        .input = t.input,
        .input_bytes = t.input_bytes,
        .at_ms = t.at_ms,
    };
}

/// `keepAsk`'s rule for the whole tool call: kept while the approval it
/// came with stands, gone with any other event.
fn keepPendingTool(self: *Bus, id: Id, ev: AgentEvent.Event, now_ms: u64) Allocator.Error!void {
    const input = if (ev.event == .awaiting_approval) ev.input else null;
    const whole = input orelse {
        if (self.pending_tools.fetchRemove(id)) |kv| self.alloc.free(kv.value.input);
        return;
    };
    const kept = try self.alloc.dupe(u8, whole);
    errdefer self.alloc.free(kept);
    const gop = try self.pending_tools.getOrPut(self.alloc, id);
    if (gop.found_existing) self.alloc.free(gop.value_ptr.input);
    gop.value_ptr.* = .{
        .input = kept,
        .input_bytes = @max(whole.len, ev.input_bytes),
        .at_ms = now_ms,
    };
}

fn keepTurn(self: *Bus, id: Id, ev: AgentEvent.Event, now_ms: u64) Allocator.Error!void {
    const text = try self.alloc.dupe(u8, ev.text orelse "");
    errdefer self.alloc.free(text);
    const gop = try self.turns.getOrPut(self.alloc, id);
    if (gop.found_existing) self.alloc.free(gop.value_ptr.text);
    var sid: Small(96) = .{};
    sid.set(ev.session_id);
    gop.value_ptr.* = .{
        .text = text,
        .text_bytes = if (ev.text == null) 0 else ev.text_bytes,
        .at_ms = now_ms,
        .session_id = sid,
    };
}

/// The last finished turn of this terminal, or null if it has had none.
/// Borrowed: valid until the next `agentEvent` or `unregister` for it.
pub fn turnOf(self: *const Bus, id: Id) ?Turn {
    return self.turns.get(id);
}

/// What the bus knows of this terminal's agent. `none` for one it has
/// never heard of.
/// The bus's own record of `id`'s agent, **by pointer, not a copy**
/// (task 1732). Its strings are `Small`s, held inside the record: a copy's
/// `.cli.get()` is a slice into the copy, and a copy made inside a function
/// dies with it -- which is how a session log came to write a terminal's
/// CLI as eleven bytes of somebody's stack. Valid until the bus next
/// changes; read what is needed from it before then.
pub fn agentOf(self: *const Bus, id: Id) *const Agent {
    const e = self.entries.getPtr(id) orelse return &Agent.none;
    return &e.agent;
}

/// A line was submitted in this terminal -- a return, typed by anybody.
/// Starts the wait of a terminal whose hooks come with its first turn
/// (`Agent.expected_ms`); anything else is left as it was, and a second
/// line does not start the wait again.
pub fn noteLineSubmitted(self: *Bus, id: Id, now_ms: u64) void {
    const e = self.entries.getPtr(id) orelse return;
    const a = &e.agent;
    if (a.hooks != .expected or a.expected_ms != null) return;
    a.expected_ms = now_ms;
}

/// Whether a line submitted in this terminal now would start its wait for
/// the hooks (`noteLineSubmitted`): what the host asks before it reads the
/// line to see whether it is a command (`slashCommandLine`), so that no
/// other return costs a read.
pub fn waitsForFirstLine(self: *const Bus, id: Id) bool {
    const e = self.entries.get(id) orelse return false;
    return e.agent.hooks == .expected and e.agent.expected_ms == null;
}

/// Whether the row a return is about to submit is one of the CLI's own
/// commands -- `/exit`, `/model`, `/clear` -- rather than something said to
/// it (c1669-04: the return of `/exit` started the wait, and thirty seconds
/// later a Codex that had already gone was reported as hooks never heard).
/// A command starts no turn, so no hook is due.
///
/// The row is the screen's: a prompt glyph and spaces before the text are
/// skipped. A word with a second slash in it is a path, said to the agent.
pub fn slashCommandLine(row: []const u8) bool {
    var s = std.mem.trimStart(u8, row, " \t");
    for ([_][]const u8{ "›", "❯", ">", "$", "%", "#" }) |glyph| {
        if (std.mem.startsWith(u8, s, glyph)) {
            s = std.mem.trimStart(u8, s[glyph.len..], " \t");
            break;
        }
    }
    if (s.len < 2 or s[0] != '/' or !std.ascii.isAlphabetic(s[1])) return false;
    const word_end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
    return std.mem.indexOfScalar(u8, s[1..word_end], '/') == null;
}

/// `+launch` in `id` started nothing, and `launcher` is who ran the launch
/// (`PersonaStore.launcherOf`): when that is a supervisor, the failure is
/// put in the box for it, whether or not a watch is in force (task 1667).
/// `agentEvent` has already done it for a terminal somebody watches; this
/// is the launch nobody was watching yet, which is the one its launcher
/// most needs to hear about.
///
/// Answers whether anything went in the box.
pub fn tellLaunchFailed(self: *Bus, id: Id, launcher: Id, detail: ?[]const u8, note: ?[]const u8, now_ms: u64) Allocator.Error!bool {
    if (launcher == id) return false;
    const minder = self.entries.get(launcher) orelse return false;
    if (minder.role != .supervisor) return false;
    try self.register(id);
    const e = self.entries.getPtr(id).?;
    if (e.agent.hooks == .live) return false;
    if (e.agent.pending == .launch_failed) return false;
    e.launched_by = launcher;
    e.agent.pending = .launch_failed;
    e.agent.handed = 0;
    e.agent.detail.set(detail);
    e.agent.note.set(note);
    e.agent.since_ms = now_ms;
    return true;
}

/// Whether a CLI in `id` that exited at once (`LaunchFailure.exited`) was
/// the launch failing (task 1712): its hooks are still awaited, and no
/// agent has connected since the launch. **Not when one did** -- that is
/// an agent that came and left, and its going is said the way any agent's
/// is; and not in a terminal no launch is waiting on.
pub fn launchExitIsFailure(self: *const Bus, id: Id) bool {
    const e = self.entries.get(id) orelse return false;
    if (e.agent.hooks != .expected) return false;
    if (e.agent.launched_ms == null) return false;
    return !e.agent.connected;
}

/// What the screen of a terminal with no agent's hooks speaking shows of a
/// question its CLI asks before it starts (task 1746, round two): `said` is
/// the declared text of the one that is up, or null when none is.
///
/// **Its state says so for as long as the screen does**, the way a title's
/// approval does (`noteTitle`): `awaiting_input` with `detail`
/// `startup_question`, said by `screen`, which `terminal_list` and the
/// control room read as somebody waiting on the person. Once, when it comes
/// up, a line goes in the box -- to whoever watches the terminal, or else
/// to the supervisor that launched it (`launcher`), who otherwise sees a
/// worker that is neither working nor reporting. Its going puts the state
/// back and takes an unread line back. Any hook event ends it too.
///
/// Answers whether anything went in the box.
pub fn noteStartupQuestion(self: *Bus, id: Id, said: ?[]const u8, launcher: ?Id, now_ms: u64) bool {
    const e = self.entries.getPtr(id) orelse return false;
    const a = &e.agent;
    if (a.hooks == .live) return false;
    const asking = a.said_by == .screen and a.state == .awaiting_input;
    const text = said orelse {
        if (!asking) return false;
        a.said_by = .hooks;
        a.state = .idle;
        a.since_ms = now_ms;
        a.detail.set(null);
        a.note.set(null);
        if (a.pending == .startup_question) {
            a.pending = null;
            a.handed = 0;
        }
        return false;
    };
    if (asking) return false;
    a.said_by = .screen;
    a.state = .awaiting_input;
    a.since_ms = now_ms;
    a.last_event_ms = now_ms;
    a.detail.set("startup_question");
    a.note.set(text);

    const watched = e.role == .watched and e.duty != .off;
    const by: ?Id = if (launcher) |l| (if (l != id and l != 0 and self.isSupervisor(l)) l else null) else null;
    if (!watched and by == null) return false;
    if (!watched) e.launched_by = by;
    a.pending = .startup_question;
    a.handed = 0;
    return true;
}

/// The CLI a launch started in `id` is asking the person something before
/// it will start -- Antigravity's folder trust box (`Plugin.StartupSays`,
/// task 1746) -- so the launch's wait for its agent is counted from
/// `now_ms` instead: the answer is the person's to give, in their own time,
/// and an agent that connects after it is still the launch's. Answers
/// whether there was a launch here still waiting for its agent.
pub fn holdLaunch(self: *Bus, id: Id, now_ms: u64) bool {
    const e = self.entries.getPtr(id) orelse return false;
    if (e.agent.hooks != .expected or e.agent.connected) return false;
    const began = e.agent.launched_ms orelse return false;
    e.agent.launched_ms = @max(began, now_ms);
    return true;
}

/// A terminal whose launch has waited `launch_agent_wait_ms` with no agent
/// connecting from it, or null (task 1712). The caller says so the way
/// `+launch` says a failure (`LaunchFailure.no_agent`), which takes the
/// expectation back -- so each launch is answered once, and the next one
/// is a new wait. One at a time; the caller asks until there is none.
///
/// **It is what covers every way a launch can come to nothing**, including
/// the ones `+launch` cannot see: on POSIX it becomes the CLI, so a CLI
/// that exits at once, or one that hangs before Polter hears from it,
/// used to leave `hooks: expected` standing with nobody told.
///
/// `present` is asked, for every launch still waiting, whether an agent is
/// listening in it now (`Server.agentPresent`), and a yes is remembered as
/// `connected`. Asked here and not only in `noteAgentHere` because that
/// runs for watched terminals alone, and a launch nobody watches whose
/// agent is sitting at its prompt would otherwise be said to have failed.
pub fn launchWithNoAgent(
    self: *Bus,
    now_ms: u64,
    ctx: *anyopaque,
    present: *const fn (ctx: *anyopaque, id: Id) bool,
) ?Id {
    var it = self.entries.iterator();
    while (it.next()) |kv| {
        const a = &kv.value_ptr.agent;
        if (a.hooks != .expected or a.connected) continue;
        const began = a.launched_ms orelse continue;
        if (present(ctx, kv.key_ptr.*)) {
            a.connected = true;
            continue;
        }
        if (now_ms -| began < launch_agent_wait_ms) continue;
        return kv.key_ptr.*;
    }
    return null;
}

/// Put a line in the box for every watched terminal whose hooks were
/// expected `hooks_expected_timeout_ms` ago and have said nothing. Once per
/// wait: the next launch starts a new one.
///
/// Answers whether anything new went in.
pub fn considerAgents(self: *Bus, now_ms: u64) bool {
    var raised = false;
    var it = self.entries.iterator();
    while (it.next()) |kv| {
        const e = kv.value_ptr;
        const a = &e.agent;
        if (a.hooks != .expected or a.expected_said) continue;
        const began = a.expected_ms orelse continue;
        if (now_ms -| began < hooks_expected_timeout_ms) continue;

        // Said once. The state is still `expected`, which is the truth, and
        // so is when it began.
        a.expected_said = true;
        if (e.role != .watched or e.duty == .off) continue;
        a.pending = .hooks_silent;
        a.handed = 0;
        raised = true;
    }
    return raised;
}

/// What a tab should say about a terminal beyond its own title.
///
/// A short marker rather than a sentence: it sits in front of whatever the
/// program running there called itself, and that title is the part somebody
/// is actually reading.
pub const TabMark = enum {
    /// Nothing to say. The tab shows only the program's own title.
    none,

    /// Watched and working.
    on_duty,

    /// Watched, and the screen has stopped moving.
    quiet,

    /// Done for the day.
    off_duty,

    /// Held to its work by the user, and working.
    held_on_duty,

    /// Held to its work by the user, and the screen has stopped moving.
    held_quiet,

    /// The terminal minding the others.
    supervisor,

    /// The terminal minding the others, which has not called a Polter tool
    /// for `calls_silent_after_ms`.
    ///
    /// **On the tab, because there is nowhere else it can go.** A worker's
    /// silence goes in its supervisor's box; a supervisor's would go in its
    /// own, and a supervisor that is stuck is the one terminal guaranteed
    /// not to read it. The tab is read by the person, without asking
    /// anybody. The hollow flag is the filled one the way the hollow disc
    /// is the filled disc: the same terminal, not moving. Arithmetic like
    /// every other mark here -- a supervisor waiting on a long build is
    /// silent too.
    supervisor_silent,

    /// The ring is the hold. It is the same shape family as the plain
    /// marks on purpose: a held terminal is still doing one of the two
    /// things any watched terminal does, and the ring says the hold is on
    /// top of that rather than instead of it.
    ///
    /// There is no held-and-off-duty mark because there is no such state:
    /// `clockOff` refuses a held terminal, so a hold and a clock-off
    /// cannot both be true at once.
    pub fn prefix(self: TabMark) []const u8 {
        return switch (self) {
            .none => "",
            .on_duty => "\u{25CF} ",
            .quiet => "\u{25CB} ",
            .off_duty => "\u{1F4A4} ",
            .held_on_duty => "\u{25C9} ",
            .held_quiet => "\u{25CE} ",
            .supervisor => "\u{2691} ",
            .supervisor_silent => "\u{2690} ",
        };
    }

    /// The flag this mark puts among a tab's dots (task 1699): the
    /// supervisor's, raised or lowered, and nothing for any other mark.
    pub fn flag(self: TabMark) Flag {
        return switch (self) {
            .supervisor => .raised,
            .supervisor_silent => .lowered,
            .none, .on_duty, .quiet, .off_duty, .held_on_duty, .held_quiet => .none,
        };
    }
};

/// The flag a tab's dots lead with: ⚑ for a supervisor at its post, ⚐ for
/// one that has gone quiet (`TabMark.supervisor_silent`), none otherwise.
pub const Flag = enum(u8) {
    none = 0,
    raised = 1,
    lowered = 2,
};

/// What a shielded terminal's tab wears, in front of whatever `TabMark`
/// says about it.
///
/// **A second prefix rather than more `TabMark` values, and that is a
/// decision, not a shortcut.** The ring is folded into `TabMark` because a
/// hold is not independent of what it is put on: it only applies to a
/// watched terminal, `clockOff` refuses a held one so held-and-off-duty
/// cannot happen, and the ring is the disc with its middle changed --
/// same glyph family, saying "still doing one of those two things, and
/// now pinned to it".
///
/// The shield is none of that. It is orthogonal to all seven values,
/// `none` included -- and `none` is the case it matters most for, because
/// the terminal a user most wants out of reach is their own shell, which
/// nobody has watched and which therefore carries no mark at all. Folding
/// it in would mean fourteen values with none of them unreachable, a
/// `none` that no longer means "nothing to say", and seven new glyphs for
/// a family that has two. Composing two prefixes says the true thing
/// instead: one mark for what the terminal is doing, one for who may
/// touch it, and they are read separately because they are separate.
///
/// It leads rather than trails: it is a fact about the whole terminal
/// regardless of what that terminal is up to, and a column of tabs is
/// scanned down its left edge.
pub const shield_prefix = "\u{1F512} ";

/// How this terminal's tab should be marked, given how long it has been
/// quiet.
///
/// Takes the quiescence threshold rather than reading one: the bus does not
/// own that number, and passing it in keeps this decidable without a
/// terminal.
pub fn tabMark(self: *const Bus, id: Id, now_ms: u64, quiet_after_ms: u64) TabMark {
    const e = self.entries.get(id) orelse return .none;
    return switch (e.role) {
        .none => .none,
        .supervisor => if (self.callsSilent(id, now_ms))
            .supervisor_silent
        else
            .supervisor,
        .watched => switch (e.duty) {
            .off => .off_duty,
            .on => if (self.quietMs(id, now_ms) >= quiet_after_ms)
                if (e.held) .held_quiet else .quiet
            else if (e.held) .held_on_duty else .on_duty,
        },
    };
}

/// Most terminals named individually in one summary. Beyond this the rest
/// are counted rather than listed: a line long enough to need scrolling is
/// not a line anybody reads, and `terminal_list` gives the full picture to
/// a supervisor that wants it.
const max_listed = 5;

/// The most one memo may say.
///
/// Short because it shares a line with the terminal reports and that line
/// shares a fixed buffer with everything else -- and short for the better
/// reason too: a memo is a pointer at something to go and look at, not the
/// looking. Anything longer belongs in the statistics tab, which is where
/// the person reading it can see the whole picture rather than one
/// sentence of it.
pub const memo_bytes = 160;

/// Everything the supervisor has not been shown, written into `buf`, and
/// cleared as it goes.
///
/// **Reading is consuming.** What comes back here does not come back again;
/// a terminal that is still quiet will make a fresh entry on its next
/// report. This is the whole point of the box: the supervisor is
/// interrupted on a schedule the user sets, not once per event per
/// terminal, and it never sees the same thing twice.
///
/// Returns null when the box is empty, which is most of the time. Nothing
/// is put in front of the supervisor to say that all is well -- an
/// interruption that carries no information is still an interruption.
///
/// Durations are recomputed here rather than stored at report time, so a
/// notice that waited in the box says how long the terminal has been quiet
/// *now*, not how long it had been when it first came up.
/// How a caller is taking the box.
pub const Take = enum {
    /// The supervisor asked. It has the notices now, and they are gone.
    consume,

    /// The scheduled hand-over, typed into a terminal that may or may not
    /// be in a state to receive it. Held for another round unless it has
    /// been offered too many times already.
    hand_over,
};

/// How many hand-overs a notice gets before it is dropped.
///
/// Bounded because each one pastes the same line into the supervisor's
/// input box again: a notice nobody reads would otherwise stack up copies
/// of itself for as long as the terminal is quiet. Three is enough to
/// cover an agent busy through a couple of intervals.
const max_hand_overs = 3;

/// Put a line in one supervisor's box, to ride out with its next hand-over.
///
/// **The same box and the same clock as the quiet reports**, on purpose.
/// `notice_interval_ms` exists to bound how often a supervisor is
/// interrupted at all; a second channel with its own schedule would be a
/// way round the one number the user set to answer that question, however
/// good the reason for the interruption was.
///
/// Refused for anybody who is not a supervisor -- there is no box to put
/// it in -- and for a line too long to hold, rather than a line cut in
/// half at whatever byte the buffer ended on. Answers whether it was
/// taken.
///
/// An empty `text` clears the slot, which is how the host says "what I
/// told you before is no longer true": the sentence is recomputed from
/// scratch each time, so a memo that has stopped applying has to be able
/// to go away before it is ever read.
pub fn leaveNote(self: *Bus, to: Id, text: []const u8) bool {
    const e = self.entries.getPtr(to) orelse return false;
    if (e.role != .supervisor) return false;

    if (text.len == 0) {
        e.memo_len = 0;
        e.memo_handed = 0;
        return true;
    }

    if (text.len > e.memo.len) return false;
    @memcpy(e.memo[0..text.len], text);
    e.memo_len = text.len;
    e.memo_handed = 0;
    return true;
}

/// Which terminals a supervisor is working with, asked of whoever knows.
///
/// **The bus does not know what a group is, and this is how it stays that
/// way** (#1064). A terminal the user watched by hand has no minder, and
/// with two supervisors in a window "whoever is asking" hands its notices
/// to both -- including the one whose work it has nothing to do with. What
/// tells them apart is which supervisor is in a group with it, and groups
/// belong to `Chat`. So the question is put through this, the host answers
/// it from the chat (`Chat.peers`), and the bus keeps only the rule about
/// when to ask.
///
/// A parameter to `take` rather than something stored on the bus, and with
/// no default: a host that forgot to supply it would otherwise fall back to
/// one of the two answers without saying which.
pub const Peers = struct {
    ctx: ?*const anyopaque,
    shareFn: *const fn (ctx: ?*const anyopaque, supervisor: Id, terminal: Id) bool,

    /// Nobody is in a group with anybody. What a caller with no chat behind
    /// it passes; with a single supervisor the question is never asked.
    pub const none: Peers = .{ .ctx = null, .shareFn = never };

    fn never(_: ?*const anyopaque, _: Id, _: Id) bool {
        return false;
    }

    fn share(self: Peers, supervisor: Id, terminal: Id) bool {
        return self.shareFn(self.ctx, supervisor, terminal);
    }
};

/// How many terminals are supervising.
pub fn supervisorCount(self: *const Bus) usize {
    var n: usize = 0;
    var it = self.entries.valueIterator();
    while (it.next()) |e| {
        if (e.role == .supervisor) n += 1;
    }
    return n;
}

/// Whether `to`'s box is where this terminal's notices belong.
///
/// Claimed: its minder's, and nobody else's. Unclaimed -- the user watched
/// it from the tab's menu and no supervisor has taken it -- depends on how
/// many supervisors there are. One: that one, because there is nobody else
/// it could be meant for. Several: only those in a group with it, because
/// "every supervisor" was two unrelated pieces of work being interrupted
/// about each other's terminals (#1064).
///
/// ⚠️ Several supervisors and a terminal in a group with none of them is
/// in nobody's box. That is deliberate rather than overlooked: the two
/// ways out are both one call -- `set_watch` to claim it, or `group_add`.
fn hears(to: Id, id: Id, e: *const Entry, alone: bool, peers: Peers) bool {
    if (e.watched_by) |owner| return owner == to;
    if (e.launched_by) |by| if (e.agent.pending == .launch_failed or e.agent.pending == .startup_question) return by == to;
    if (alone) return true;
    return peers.share(to, id);
}

pub fn drain(self: *Bus, to: Id, now_ms: u64, buf: []u8, peers: Peers) ?[]u8 {
    return self.take(to, now_ms, buf, .consume, peers);
}

/// The box belonging to one supervisor.
///
/// Filtered by who is minding each terminal: with two supervisors on two
/// pieces of work, a shared box would hand each of them the other's
/// reports -- twice the interruption and half of it about terminals they
/// cannot even read. `peers` settles the terminals nobody has claimed; see
/// `hears`.
pub fn take(self: *Bus, to: Id, now_ms: u64, buf: []u8, how: Take, peers: Peers) ?[]u8 {
    return self.takeSome(to, now_ms, buf, how, peers, false);
}

/// Whether an agent's notice is about somebody stopped on a question: an
/// approval or an answer it is waiting for.
fn isWaiting(kind: AgentNotice) bool {
    return switch (kind) {
        .awaiting_approval, .awaiting_input, .startup_question => true,
        .turn_ended, .turn_failed, .hooks_silent, .launch_failed => false,
    };
}

/// A waiting notice nobody has been handed yet.
fn freshlyWaiting(e: *const Entry) bool {
    // An agent that can no longer reach Polter cannot say it is stuck
    // either: that goes out at once, like a wait (task 1668).
    if (e.link_pending != null and e.link_handed == 0) return true;
    const kind = e.agent.pending orelse return false;
    return isWaiting(kind) and e.agent.handed == 0;
}

/// Whether `to`'s box holds a waiting notice it has not been handed.
pub fn hasFreshWaiting(self: *const Bus, to: Id, peers: Peers) bool {
    const minder = self.entries.get(to) orelse return false;
    if (minder.role != .supervisor) return false;
    const alone = self.supervisorCount() <= 1;
    var it = self.entries.iterator();
    while (it.next()) |kv| {
        if (!freshlyWaiting(kv.value_ptr)) continue;
        if (hears(to, kv.key_ptr.*, kv.value_ptr, alone, peers)) return true;
    }
    return false;
}

/// A notice typed into `to` was refused -- the person was typing there, or
/// had an unsent line. Whatever waiting notices were in it are made fresh
/// again, so the next thing that drives a delivery offers them at once
/// rather than an interval later.
///
/// Only the waiting ones: a quiet report that was refused comes round
/// again on the interval, as it always has, and is not worth interrupting
/// somebody the moment they stop typing.
pub fn deliveryRefused(self: *Bus, to: Id, peers: Peers) void {
    const minder = self.entries.get(to) orelse return;
    if (minder.role != .supervisor) return;
    const alone = self.supervisorCount() <= 1;
    var it = self.entries.iterator();
    while (it.next()) |kv| {
        const e = kv.value_ptr;
        const kind = e.agent.pending orelse continue;
        if (!isWaiting(kind)) continue;
        if (!hears(to, kv.key_ptr.*, e, alone, peers)) continue;
        e.agent.handed -|= 1;
    }
}

/// The scheduled hand-over to `to` was typed and its return reached the
/// program: what it carried has arrived, and is not handed over again
/// (task 1503).
///
/// **Why this is now the rule.** A hand-over used to be held for up to
/// `max_hand_overs` rounds whatever became of it, because typing was not
/// arrival: a return the agent's input box swallowed left the notice lost
/// (see "a scheduled hand-over holds the notice, because typing is not
/// arrival"). Typing now says which it was -- a refusal, or a return that
/// never reached the program (`NotSubmitted`), comes back as one, and the
/// pause before the return is what made it take -- so a line that went in
/// is one the supervisor has. Holding it anyway is what typed `no tool
/// call 15m` and then `no tool call 16m` a minute later, and `turn ended
/// 0s ago` then `turn ended 60s ago`, into a supervisor that had read the
/// first.
///
/// Only what a hand-over has carried (its counters above zero): something
/// that came into the box after the line was made is still to come.
pub fn delivered(self: *Bus, to: Id, peers: Peers) void {
    const minder = self.entries.getPtr(to) orelse return;
    if (minder.role != .supervisor) return;
    if (minder.memo_handed > 0) {
        minder.memo_len = 0;
        minder.memo_handed = 0;
    }
    const alone = self.supervisorCount() <= 1;
    var it = self.entries.iterator();
    while (it.next()) |kv| {
        const e = kv.value_ptr;
        if (!hears(to, kv.key_ptr.*, e, alone, peers)) continue;
        if (e.pending != null and e.handed_over > 0) {
            e.pending = null;
            e.handed_over = 0;
        }
        if (e.silent_pending and e.silent_handed > 0) {
            e.silent_pending = false;
            e.silent_handed = 0;
        }
        if (e.agent.pending != null and e.agent.handed > 0) {
            e.agent.pending = null;
            e.agent.handed = 0;
        }
        if (e.link_pending != null and e.link_handed > 0) {
            e.link_pending = null;
            e.link_handed = 0;
        }
    }
}

/// `take`, or -- with `only_waiting` -- just the waiting notices nobody has
/// been handed, leaving everything else in the box exactly as it was.
fn takeSome(self: *Bus, to: Id, now_ms: u64, buf: []u8, how: Take, peers: Peers, only_waiting: bool) ?[]u8 {
    // Only a supervisor has a box. Said here rather than left to the
    // caller, because the rule below hands an unclaimed terminal's report
    // to a lone supervisor that asks -- so a terminal that has just stood
    // down would otherwise keep being handed exactly the reports it stopped
    // being responsible for, which is the one thing standing down is for.
    const minder = self.entries.get(to) orelse return null;
    if (minder.role != .supervisor) return null;

    // Counted once, before the walk: `to` is one of them, so one means
    // there is nobody else an unclaimed terminal could belong to.
    const alone = self.supervisorCount() <= 1;

    var listed: usize = 0;
    var total: usize = 0;

    // Written into a fixed buffer with a running end, because the whole
    // point is to produce one line for one injection.
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("[poltergeist]") catch return null;

    var it = self.entries.iterator();
    while (it.next()) |kv| {
        const e = kv.value_ptr;
        if (e.pending == null and !e.silent_pending and e.agent.pending == null and e.link_pending == null) continue;
        if (only_waiting and !freshlyWaiting(e)) continue;

        // Not this supervisor's terminal. Left in the box for whoever is
        // minding it, rather than dropped.
        const id = kv.key_ptr.*;
        if (!hears(to, id, e, alone, peers)) continue;

        // adapters.md 3.4: with hooks live, a still screen the agent has
        // already explained -- a turn that ended, failed, or is waiting on
        // somebody -- is not said again as "quiet". The event says why.
        // Taken out of the box rather than left: nothing more will be
        // said about this stillness, and a quiet report that comes after
        // the agent moves on is a new one.
        //
        // **Only the stillness that followed the event**: see
        // `quietExplained`. One that began after the screen moved again is
        // reported, with the event it outlived beside it.
        if (!only_waiting) if (e.pending) |kind| if (kind != .resumed and self.quietExplained(id, now_ms)) {
            e.pending = null;
            e.handed_over = 0;
        };

        if (!only_waiting) if (e.pending) |kind| {
            total += 1;

            switch (how) {
                .consume => {
                    e.pending = null;
                    e.handed_over = 0;
                },
                .hand_over => {
                    e.handed_over +|= 1;
                    if (e.handed_over >= max_hand_overs) {
                        e.pending = null;
                        e.handed_over = 0;
                    }
                },
            }

            if (listed < max_listed) {
                const sep = if (listed == 0) " " else ", ";
                const mark = w.end;
                const in_turn = e.agent.hooks == .live and e.agent.state == .in_turn;
                // Still here with the agent in a state that would explain a
                // still screen: the screen moved after that event.
                const outlived = e.agent.known() and stateExplains(e.agent.state);
                const written = switch (kind) {
                    // **No agent in it** (#63): whatever its hooks last
                    // said is about an agent that has gone, and a worker
                    // waiting for its next instruction reads exactly like
                    // that. Said first, because it is the one fact that
                    // changes what the supervisor should do.
                    .quiescent, .still_quiescent => if (e.agent_here == false) w.print(
                        "{s}0x{x:0>16} quiet {d}s (no agent in it)",
                        .{ sep, id, self.quietMs(id, now_ms) / std.time.ms_per_s },
                    ) else if (outlived) w.print(
                        "{s}0x{x:0>16} quiet {d}s (last event: {s} {d}s ago)",
                        .{
                            sep,
                            id,
                            self.quietMs(id, now_ms) / std.time.ms_per_s,
                            stateWords(e.agent.state),
                            (now_ms -| e.agent.eventMs()) / std.time.ms_per_s,
                        },
                    ) else if (in_turn) quietInTurn(
                        &w,
                        sep,
                        id,
                        self.quietMs(id, now_ms),
                        e.agent,
                        now_ms,
                    ) else w.print(
                        "{s}0x{x:0>16} quiet {d}s",
                        .{ sep, id, self.quietMs(id, now_ms) / std.time.ms_per_s },
                    ),
                    .resumed => w.print(
                        "{s}0x{x:0>16} back at work",
                        .{ sep, id },
                    ),
                };

                // Out of room. What is written already stands -- wound back
                // to the end of the last whole entry, because a failed
                // `print` fills the buffer before it reports, and half of
                // `0x2222 quiet 90s` is an id nobody can look up. The rest
                // is covered by the count below.
                written catch {
                    w.end = mark;
                    break;
                };
                listed += 1;
            }
        };

        // The second clock, as its own entry: see `considerCalls`. The
        // screen's figure rides along in brackets when there is one,
        // because "no tool call, and the screen changed three seconds ago"
        // is the case this exists for and should read as that without the
        // supervisor having to go and compare two entries.
        if (!only_waiting and e.silent_pending) {
            total += 1;

            switch (how) {
                .consume => {
                    e.silent_pending = false;
                    e.silent_handed = 0;
                },
                .hand_over => {
                    e.silent_handed +|= 1;
                    if (e.silent_handed >= max_hand_overs) {
                        e.silent_pending = false;
                        e.silent_handed = 0;
                    }
                },
            }

            if (listed < max_listed) {
                const sep = if (listed == 0) " " else ", ";
                const mark = w.end;
                const written = noToolCall(
                    &w,
                    sep,
                    id,
                    e.*,
                    if (self.observed(id)) self.quietMs(id, now_ms) else null,
                    now_ms,
                );
                written catch {
                    w.end = mark;
                    break;
                };
                listed += 1;
            }
        }

        // What the agent said about itself: see `agentEvent`. Its own slot
        // for `silent_pending`'s reason -- it can be true alongside either
        // of the others.
        if (e.agent.pending) |kind| said: {
            // **A repeat is an interval after the hand-over it repeats.** A
            // waiting notice goes out at once, on its own, without touching
            // the schedule -- so the scheduled box could come due a second
            // later and say the same sentence again. It did: the same line
            // twice in a supervisor's terminal twenty seconds apart
            // (2026-10-13). Left in the box, it rides the next one.
            if (how == .hand_over and !only_waiting and isWaiting(kind) and e.agent.handed > 0 and
                now_ms -| e.agent.handed_ms < self.config.notice_interval_ms) break :said;

            total += 1;

            switch (how) {
                .consume => {
                    e.agent.pending = null;
                    e.agent.handed = 0;
                },
                .hand_over => {
                    e.agent.handed_ms = now_ms;
                    e.agent.handed +|= 1;
                    if (e.agent.handed >= max_hand_overs) {
                        e.agent.pending = null;
                        e.agent.handed = 0;
                    }
                },
            }

            if (listed < max_listed) {
                const sep = if (listed == 0) " " else ", ";
                const mark = w.end;
                writeAgent(&w, sep, id, kind, e.agent, self.turns.get(id), now_ms, self.answer(id)) catch {
                    w.end = mark;
                    break;
                };
                listed += 1;
            }
        }

        // Its connection to Polter is gone while its program runs: see
        // `considerLinks`.
        if (!only_waiting or e.link_handed == 0) if (e.link_pending) |lost| {
            total += 1;

            switch (how) {
                .consume => {
                    e.link_pending = null;
                    e.link_handed = 0;
                },
                .hand_over => {
                    e.link_handed +|= 1;
                    if (e.link_handed >= max_hand_overs) {
                        e.link_pending = null;
                        e.link_handed = 0;
                    }
                },
            }

            if (listed < max_listed) {
                const sep = if (listed == 0) " " else ", ";
                const mark = w.end;
                w.print(
                    "{s}0x{x:0>16} lost its Polter connection {d}s ago while its program (pid {d}) still runs: it cannot call Polter tools until it is restarted",
                    .{ sep, id, (now_ms -| lost.at_ms) / std.time.ms_per_s, if (lost.program) |p| p.pid else 0 },
                ) catch {
                    w.end = mark;
                    break;
                };
                listed += 1;
            }
        };
    }

    // The supervisor's own line, after the terminals and before the count
    // of what would not fit. Written last because it is the one part that
    // is about the work rather than about a screen, and a reader scanning
    // for an id should not have to step over it.
    //
    // Fetched again rather than reusing `minder`: `take` walks the map,
    // and a map that grew moved every pointer into it.
    if (self.entries.getPtr(to)) |box| {
        if (!only_waiting and box.memo_len > 0) {
            total += 1;

            // Wound back if it did not fit whole: a failed `print` fills
            // the buffer and *then* reports the failure, so without this
            // the line ends halfway through a sentence.
            const sep = if (listed == 0) " " else " · ";
            const mark = w.end;
            if (w.print("{s}{s}", .{ sep, box.memo[0..box.memo_len] })) |_| {
                listed += 1;
            } else |_| {
                w.end = mark;
            }

            switch (how) {
                .consume => {
                    box.memo_len = 0;
                    box.memo_handed = 0;
                },
                .hand_over => {
                    box.memo_handed +|= 1;
                    if (box.memo_handed >= max_hand_overs) {
                        box.memo_len = 0;
                        box.memo_handed = 0;
                    }
                },
            }
        }
    }

    if (total == 0) return null;
    if (total > listed) {
        w.print(" (+{d} more)", .{total - listed}) catch {};
    }

    return w.buffered();
}

/// Whether an agent's own hooks already account for its screen being
/// still (adapters.md 3.4). Only with hooks `live`: before that, no event
/// explains anything.
///
/// **And only the stillness that followed the event** (#879). An event
/// says why the screen stopped *then*; it says nothing about a screen that
/// moved again afterwards and stopped a second time. Measured: declining a
/// permission box -- Esc or No -- fires no hook at all, so the last word is
/// still "awaiting approval" while Claude sits at an empty prompt, and a
/// rule keyed on the state alone kept that terminal out of the box for as
/// long as it stayed there. So the question is when the present stillness
/// began: no later than `event_redraw_grace_ms` after the event, and the
/// event explains it; later, and it does not.
///
/// A terminal nothing samples has no quiet reports to hold back, so the
/// screen's figure is only read where there is one.
fn quietExplained(self: *const Bus, id: Id, now_ms: u64) bool {
    const e = self.entries.get(id) orelse return false;
    // What an agent that has gone last said explains nothing (#63).
    if (e.agent_here == false) return false;
    const a = e.agent;
    // A title saying it waits explains the stillness for as long as it says
    // so; it stops saying so the moment the box goes (`noteTitle`).
    switch (a.said_by) {
        .title, .screen => return a.state == .awaiting_approval,
        .hooks => {},
    }
    if (a.hooks != .live or !stateExplains(a.state)) return false;
    if (!self.observed(id)) return true;
    // **A turn that ended or failed, or a question being waited on, holds
    // for any stillness after it** (task 1503). The screen of an agent
    // sitting at its prompt still redraws -- a status line, a cursor --
    // and every redraw was a `back at work` followed by another `quiet`
    // with the same `turn ended` beside it. Nothing the agent does next
    // goes unsaid: a new turn is `turn_started`. #879's rule below stays
    // for the one state it was measured on: declining a permission box
    // fires no hook, so the agent can be at its prompt while the last
    // word is still `awaiting approval`.
    if (a.state != .awaiting_approval) return true;
    const still_since = now_ms -| self.quietMs(id, now_ms);
    return still_since <= a.eventMs() + event_redraw_grace_ms;
}

/// Whether being in this state is a reason for the screen to be still.
/// `quiet Ns (in turn …)`: see `writeTurn`.
fn quietInTurn(
    w: *std.Io.Writer,
    sep: []const u8,
    id: Id,
    quiet_ms: u64,
    a: Agent,
    now_ms: u64,
) std.Io.Writer.Error!void {
    try w.print("{s}0x{x:0>16} quiet {d}s (", .{ sep, id, quiet_ms / std.time.ms_per_s });
    try writeTurn(w, a, now_ms);
    try w.writeAll(")");
}

/// The `no tool call` line (`considerCalls`), with what is known of why in
/// brackets.
///
/// **What used to read the same now reads differently** (#62, #63):
///
/// - `(no agent in it)` -- the agent has gone; nothing will call again.
/// - `(in turn 20m, Bash running 16m; …)` -- a command is running.
/// - `(in turn 20m, no tool running for 16m; …)` -- a turn with nothing
///   running in it, which is what a stuck one looks like.
/// - `(in turn 20m; …)` -- in a turn, and its CLI does not say whether a
///   tool is running.
///
/// The screen's figure rides along last when there is one, because "no
/// tool call, and the screen changed three seconds ago" is the case the
/// line was made for.
fn noToolCall(
    w: *std.Io.Writer,
    sep: []const u8,
    id: Id,
    e: Entry,
    quiet_ms: ?u64,
    now_ms: u64,
) std.Io.Writer.Error!void {
    const silent_min = (silenceMs(e, now_ms) orelse 0) / std.time.ms_per_min;
    try w.print("{s}0x{x:0>16} no tool call {d}m", .{ sep, id, silent_min });
    if (e.agent_here == false) return w.writeAll(" (no agent in it)");

    const in_turn = e.agent.hooks == .live and e.agent.state == .in_turn;
    if (!in_turn and quiet_ms == null) return;
    try w.writeAll(" (");
    if (in_turn) try writeTurn(w, e.agent, now_ms);
    if (quiet_ms) |q| {
        if (in_turn) try w.writeAll("; ");
        try w.print("screen changed {d}s ago", .{q / std.time.ms_per_s});
    }
    try w.writeAll(")");
}

/// `in turn 20m`, and what is running in it when the agent says (task
/// 1625): `, Bash running 16m`, `, 2 tools running 3m, last Read`, or
/// `, no tool running for 16m`. Nothing about tools when `tools` is null:
/// "no tool running" about an agent that does not report its tools would
/// be a claim.
fn writeTurn(w: *std.Io.Writer, a: Agent, now_ms: u64) std.Io.Writer.Error!void {
    try w.print("in turn {d}m", .{(now_ms -| a.since_ms) / std.time.ms_per_min});
    const n = a.tools orelse return;
    const for_min = (now_ms -| a.tool_ms) / std.time.ms_per_min;
    const name = a.tool.get() orelse "a tool";
    switch (n) {
        0 => try w.print(", no tool running for {d}m", .{for_min}),
        1 => try w.print(", {s} running {d}m", .{ name, for_min }),
        else => try w.print(", {d} tools running {d}m, last {s}", .{ n, for_min, name }),
    }
}

fn stateExplains(state: AgentState) bool {
    return switch (state) {
        .ended, .failed, .awaiting_approval, .awaiting_input => true,
        .idle, .in_turn => false,
    };
}

/// The state as the notices name the event that put it there.
fn stateWords(state: AgentState) []const u8 {
    return switch (state) {
        .idle => "session started",
        .in_turn => "turn started",
        .ended => "turn ended",
        .failed => "turn failed",
        .awaiting_approval => "awaiting approval",
        .awaiting_input => "awaiting input",
    };
}

/// Most characters of a final answer quoted in the box. The rest is for
/// `terminal_turn`.
pub const excerpt_chars = 120;

/// One agent entry. Fails when even a shortened one does not fit, so the
/// caller can wind back to the last whole entry.
fn writeAgent(
    w: *std.Io.Writer,
    sep: []const u8,
    id: Id,
    kind: AgentNotice,
    a: Agent,
    turn: ?Turn,
    now_ms: u64,
    may: Answer,
) std.Io.Writer.Error!void {
    const ago_s = (now_ms -| a.eventMs()) / std.time.ms_per_s;
    switch (kind) {
        .turn_ended => {
            try w.print("{s}0x{x:0>16} turn ended {d}s ago", .{ sep, id, ago_s });
            if (a.waiting_on_background) try w.writeAll(" (background tasks running)");
            const text = if (turn) |t| t.text else "";
            if (text.len > 0) {
                try w.writeAll(": \"");
                _ = try fitTail(w, AgentEvent.prefixChars(text, excerpt_chars), text.len, 1);
                try w.writeAll("\"");
            }
        },
        .turn_failed => try w.print(
            "{s}0x{x:0>16} failed {s}",
            .{ sep, id, a.detail.get() orelse "(no error type)" },
        ),
        .awaiting_approval => {
            // **The two moments and the switch, before the note.** They are
            // what `terminal_answer_prompt` takes as its guard, written with
            // its own parameter names so they can be copied across, and
            // whether answering is open at all -- so a supervisor reading
            // this line knows both without a `terminal_list` in between.
            // Before the note because the note is what gets cut when the
            // line is full.
            // A title names no tool: what it says is that the CLI waits,
            // and the title itself goes where a hook's note would.
            switch (a.said_by) {
                .title => try w.print(
                    "{s}0x{x:0>16} awaiting approval (title says so) [state_at_ms={d} event_at_ms={d} answer={s}]",
                    .{ sep, id, a.since_ms, a.eventMs(), may.word() },
                ),
                // A screen names no tool either; what it showed is the note.
                .screen => try w.print(
                    "{s}0x{x:0>16} awaiting approval (screen says so) [state_at_ms={d} event_at_ms={d} answer={s}]",
                    .{ sep, id, a.since_ms, a.eventMs(), may.word() },
                ),
                .hooks => try w.print(
                    "{s}0x{x:0>16} awaiting approval {s} [state_at_ms={d} event_at_ms={d} answer={s}]",
                    .{ sep, id, a.detail.get() orelse "(no tool name)", a.since_ms, a.eventMs(), may.word() },
                ),
            }
            // **A cut note says it was cut, and by how much** (task 1651):
            // a command stopped at `; S` read as a command that ended
            // there. The rest is terminal_turn's `pending_tool`.
            if (a.note.get()) |note| {
                try w.writeAll(": ");
                var more_buf: [64]u8 = undefined;
                const more = std.fmt.bufPrint(
                    &more_buf,
                    " [{d} bytes; terminal_turn has all]",
                    .{@max(note.len, a.note_bytes)},
                ) catch unreachable;
                if (try fitTail(w, note, @max(note.len, a.note_bytes), more.len)) {
                    try w.writeAll(more);
                }
            }
        },
        .awaiting_input => try w.print(
            "{s}0x{x:0>16} awaiting input {s}",
            .{ sep, id, a.detail.get() orelse "" },
        ),
        // Task 1746: not the agent's question and not one for an agent to
        // answer -- the keys that would are refused while it is up.
        .startup_question => try w.print(
            "{s}0x{x:0>16} waiting for the person: its CLI asks \"{s}\" before it starts. Nothing can be typed or pressed there until they answer it in that tab -- ask them to",
            .{ sep, id, a.note.get() orelse "a question" },
        ),
        .hooks_silent => try w.print(
            "{s}0x{x:0>16} hooks expected {d}s ago and nothing heard (no session_started)",
            .{ sep, id, (now_ms -| (a.expected_ms orelse a.eventMs())) / std.time.ms_per_s },
        ),
        .launch_failed => switch (AgentEvent.LaunchFailure.parse(a.detail.get())) {
            .not_found, .failed => try w.print(
                "{s}0x{x:0>16} launch failed {d}s ago ({s}); the terminal is at its shell, terminal_read has the reason",
                .{ sep, id, ago_s, a.detail.get() orelse "failed" },
            ),
            // The CLI ran and was gone at once: its code says it failed,
            // and its last line on the screen says why (task 1712).
            .exited => try w.print(
                "{s}0x{x:0>16} launch failed {d}s ago (exited: {s}); the CLI started and exited at once, terminal_read has its last words",
                .{ sep, id, ago_s, a.note.get() orelse "a failing code" },
            ),
            // Not "at its shell": what is in the terminal is not known,
            // only that nothing connected from it (task 1712).
            .no_agent => try w.print(
                "{s}0x{x:0>16} launch failed {d}s ago (no_agent): no agent connected within {d}s of the launch; terminal_read shows what is there",
                .{ sep, id, ago_s, launch_agent_wait_ms / std.time.ms_per_s },
            ),
        },
    }
}

/// Write `s` in what is left of `w`, less `reserve` bytes for whatever
/// follows it, cut on a character boundary with an ellipsis when it does
/// not fit whole or when `full_len` says it was already a prefix. Control
/// characters become spaces: this line is typed into a terminal, where a
/// newline submits it. True when it was cut.
fn fitTail(w: *std.Io.Writer, s: []const u8, full_len: usize, reserve: usize) std.Io.Writer.Error!bool {
    const ellipsis = "\u{2026}";
    const room = w.buffer.len -| w.end -| reserve;
    const cut = s.len < full_len or s.len > room;
    const body = if (!cut) s else if (room < ellipsis.len + 1)
        return error.WriteFailed
    else
        AgentEvent.cutBytes(s, @min(s.len, room - ellipsis.len));
    for (body) |c| try w.writeByte(if (c < 0x20 or c == 0x7f) ' ' else c);
    if (cut) try w.writeAll(ellipsis);
    return cut;
}

/// The box, but only if enough time has passed to interrupt the supervisor
/// again. Null when it is too soon, or when there is nothing to say.
///
/// This is the scheduled hand-over. `drain` is the other way in, for a
/// supervisor that asks of its own accord -- that one is never held back,
/// because somebody choosing to look is not an interruption.
///
/// The clock only advances on a delivery that actually happened. An empty
/// box does not count as having been shown anything, so a terminal going
/// quiet a second after a silent tick is not made to wait another full
/// interval.
///
/// **A worker stopped on a question does not wait for the interval.** The
/// interval answers "how often may a supervisor be interrupted about
/// terminals that have gone still", and a terminal that is still because
/// it is asking for an approval is not that: every minute it waits is a
/// minute of work not done, and the person's rule (2026-10-12) is that
/// these go to the supervisor at once. So a waiting notice nobody has been
/// handed is handed over now, on its own, and neither spends nor resets
/// the interval: whatever else is in the box comes round when it would
/// have. Its repeats, if the supervisor does nothing, are on the interval
/// like anything else.
pub fn drainIfDue(self: *Bus, to: Id, now_ms: u64, buf: []u8, peers: Peers) ?[]u8 {
    const minder = self.entries.getPtr(to) orelse return null;
    if (minder.last_delivery_ms) |last| {
        if (now_ms -| last < self.config.notice_interval_ms) {
            if (!self.hasFreshWaiting(to, peers)) return null;
            return self.takeSome(to, now_ms, buf, .hand_over, peers, true);
        }
    }

    const line = self.take(to, now_ms, buf, .hand_over, peers) orelse return null;

    // Re-fetched: `take` may have grown the map and moved the entry.
    if (self.entries.getPtr(to)) |b| b.last_delivery_ms = now_ms;
    return line;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const boss: Id = 0x1111;
const worker: Id = 0x2222;

fn quiet(quiet_ms: u64) Sampler.Event {
    return .{ .quiescent = .{
        .quiet_ms = quiet_ms,
        .silent_ms = quiet_ms,
        .changed_rows = 0,
        .total_rows = 24,
    } };
}

fn testBus() Bus {
    return .init(testing.allocator, .{});
}

test "who opened a terminal outlives its being let go, and goes with it" {
    // #989: a supervisor lets go of a worker it opened, then closes it. The
    // close asked the user because the mark was gone; the provenance must
    // not go with the mark.
    var b: Bus = .init(testing.allocator, .{});
    defer b.deinit();
    try b.addSupervisor(1);
    try b.markOpenedByAgent(2, 1);
    try b.watch(2, 1);
    b.unwatch(2);
    try testing.expectEqual(Role.none, b.roleOf(2));
    try testing.expect(b.openedByAgent(2));

    // A terminal nobody recorded opening is the user's.
    try b.register(3);
    try testing.expect(!b.openedByAgent(3));
    try testing.expect(!b.openedByAgent(99));

    // Closed: forgotten, so an id reused later starts as nobody's.
    b.unregister(2);
    try testing.expect(!b.openedByAgent(2));
}

test "an unclaimed terminal reports to the only supervisor there is" {
    // Watching from the keyboard leaves the terminal with no owner: which
    // supervisor should mind it is not something a keybind can say. With
    // one supervisor there is nobody else it could be meant for, whatever
    // groups it is or is not in -- `Peers.none` says it shares none.
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, null);
    _ = b.report(worker, quiet(60_000), 0);

    var buf: [255]u8 = undefined;
    const line = b.drain(boss, 1_000, &buf, .none) orelse return error.ExpectedANotice;
    try testing.expect(std.mem.indexOf(u8, line, "quiet") != null);
}

/// A stand-in for the chat: one supervisor is in a group with one terminal.
const OnePair = struct {
    supervisor: Id,
    terminal: Id,

    fn peers(self: *const OnePair) Peers {
        return .{ .ctx = self, .shareFn = share };
    }

    fn share(ctx: ?*const anyopaque, supervisor: Id, terminal: Id) bool {
        const self: *const OnePair = @ptrCast(@alignCast(ctx.?));
        return supervisor == self.supervisor and terminal == self.terminal;
    }
};

test "#1064: with two supervisors an unclaimed terminal reports only to the one it works with" {
    // Measured 2026-10-02: two terminals the user had watched from the tab
    // menu sent their `no tool call` notices to every supervisor in the
    // window, including one minding unrelated work, and the hand-over
    // count that drops a notice after three was being used up by both.
    var b = testBus();
    defer b.deinit();

    const second: Id = 0x4444;
    try b.addSupervisor(boss);
    try b.addSupervisor(second);
    try b.watch(worker, null);
    _ = b.report(worker, quiet(60_000), 0);

    const pair: OnePair = .{ .supervisor = boss, .terminal = worker };

    // The scheduled hand-over to the other one carries nothing, and does
    // not spend one of the three the notice gets.
    var buf: [255]u8 = undefined;
    const stray = b.drainIfDue(second, 1_000, &buf, pair.peers());
    try testing.expect(stray == null);
    const spent = b.get(worker).?.handed_over;
    try testing.expectEqual(@as(u8, 0), spent);

    // Reading its box does not take it either.
    const read = b.drain(second, 1_000, &buf, pair.peers());
    try testing.expect(read == null);

    // Still there for the one in a group with it.
    const line = b.drain(boss, 1_000, &buf, pair.peers()) orelse return error.ExpectedANotice;
    try testing.expect(std.mem.indexOf(u8, line, "0x0000000000002222 quiet") != null);
}

test "#1064: with two supervisors an unclaimed terminal in a group with neither is in no box" {
    // Not handed to both, which is the bug, and not to an arbitrary one.
    // Claiming it is one call and so is adding it to a group.
    var b = testBus();
    defer b.deinit();

    const second: Id = 0x4444;
    try b.addSupervisor(boss);
    try b.addSupervisor(second);
    try b.watch(worker, null);
    _ = b.report(worker, quiet(60_000), 0);

    var buf: [255]u8 = undefined;
    const first = b.drain(boss, 1_000, &buf, .none);
    try testing.expect(first == null);
    const other = b.drain(second, 1_000, &buf, .none);
    try testing.expect(other == null);

    // Kept rather than dropped: the supervisor that claims it is told.
    try b.watch(worker, second);
    const claimed = b.drain(second, 1_000, &buf, .none);
    try testing.expect(claimed != null);
}

test "#1064: a claim outranks the group an unclaimed terminal was in" {
    // The user's watch is not a lock. Once a supervisor claims the
    // terminal its notices go to that box alone, even though the other
    // supervisor is the one in a group with it.
    var b = testBus();
    defer b.deinit();

    const second: Id = 0x4444;
    try b.addSupervisor(boss);
    try b.addSupervisor(second);
    try b.watch(worker, null);
    try b.watch(worker, second);
    try testing.expectEqual(@as(?Id, second), b.minderOf(worker));
    _ = b.report(worker, quiet(60_000), 0);

    const pair: OnePair = .{ .supervisor = boss, .terminal = worker };

    var buf: [255]u8 = undefined;
    const grouped = b.drain(boss, 1_000, &buf, pair.peers());
    try testing.expect(grouped == null);
    const owner = b.drain(second, 1_000, &buf, pair.peers());
    try testing.expect(owner != null);
}

test "#1067: a quiet report already in the box is not handed over after the terminal is let go" {
    var b = testBus();
    defer b.deinit();
    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    _ = b.report(worker, quiet(60_000), 0);

    // Handed over once and held, which is what a hand-over does.
    var buf: [255]u8 = undefined;
    const before = b.drainIfDue(boss, 1_000, &buf, .none);
    try testing.expect(before != null);

    b.unwatch(worker);
    const due = 1_000 + std.time.ms_per_min + 1;
    const handed = b.drainIfDue(boss, due, &buf, .none);
    try testing.expect(handed == null);
    const read = b.drain(boss, due, &buf, .none);
    try testing.expect(read == null);
    const count = b.get(worker).?.handed_over;
    try testing.expectEqual(@as(u8, 0), count);

    // Watched again: a clean start, not the old report come back.
    try b.watch(worker, boss);
    const revived = b.drain(boss, due, &buf, .none);
    try testing.expect(revived == null);
}

test "#1067: a `no tool call` notice already in the box is not handed over after the terminal is let go" {
    // The measured one: `no tool call 15m` handed over, the terminal let
    // go with "no notices" said back, and `no tool call 16m` a minute on.
    var b = testBus();
    defer b.deinit();
    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    const at = 15 * std.time.ms_per_min;
    b.noteCall(worker, 0);
    try testing.expect(b.considerCalls(at));

    var buf: [255]u8 = undefined;
    const before = b.drainIfDue(boss, at, &buf, .none);
    try testing.expect(before != null);

    b.unwatch(worker);
    const due = at + std.time.ms_per_min + 1;
    const handed = b.drainIfDue(boss, due, &buf, .none);
    try testing.expect(handed == null);
    const read = b.drain(boss, due, &buf, .none);
    try testing.expect(read == null);
    const count = b.get(worker).?.silent_handed;
    try testing.expectEqual(@as(u8, 0), count);

    try b.watch(worker, boss);
    const revived = b.drain(boss, due, &buf, .none);
    try testing.expect(revived == null);
}

test "#1067: what the agent said, already in the box, is not handed over after the terminal is let go" {
    var b = testBus();
    defer b.deinit();
    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    try testing.expect(try b.agentEvent(worker, hookEv(.turn_ended), 1_000));

    var buf: [255]u8 = undefined;
    const before = b.drainIfDue(boss, 1_000, &buf, .none);
    try testing.expect(before != null);

    b.unwatch(worker);
    const due = 1_000 + std.time.ms_per_min + 1;
    const handed = b.drainIfDue(boss, due, &buf, .none);
    try testing.expect(handed == null);
    const read = b.drain(boss, due, &buf, .none);
    try testing.expect(read == null);
    const count = b.agentOf(worker).handed;
    try testing.expectEqual(@as(u8, 0), count);

    try b.watch(worker, boss);
    const revived = b.drain(boss, due, &buf, .none);
    try testing.expect(revived == null);
}

test "#1067: nothing new is put in the box about a terminal that was let go" {
    // Each of the four makers asks whether the terminal is watched. This
    // is what holds them to it: emptying the box on the way out would be
    // undone a moment later by any one of them that did not.
    var b = testBus();
    defer b.deinit();
    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    b.unwatch(worker);

    const went_quiet = b.report(worker, quiet(60_000), 1_000);
    try testing.expect(!went_quiet);
    try testing.expect(b.get(worker).?.pending == null);

    b.noteCall(worker, 0);
    const went_silent = b.considerCalls(16 * std.time.ms_per_min);
    try testing.expect(!went_silent);
    try testing.expect(!b.get(worker).?.silent_pending);

    const said = try b.agentEvent(worker, hookEv(.turn_ended), 2_000);
    try testing.expect(!said);
    try testing.expect(b.agentOf(worker).pending == null);

    _ = try b.agentEvent(worker, hookEv(.hooks_expected), 3_000);
    const unheard = b.considerAgents(3_000 + hooks_expected_timeout_ms);
    try testing.expect(!unheard);
    try testing.expect(b.agentOf(worker).pending == null);

    var buf: [255]u8 = undefined;
    const line = b.drain(boss, 20 * std.time.ms_per_min, &buf, .none);
    try testing.expect(line == null);
}

test "#1067: a supervisor standing down or closing takes its terminals' notices with it" {
    // Neither goes through `unwatch`. The terminals end up with no minder,
    // which with one supervisor left is exactly whom `hears` hands an
    // unclaimed terminal to -- so the survivor would inherit, as news,
    // reports about terminals it was never minding.
    var b = testBus();
    defer b.deinit();

    const survivor: Id = 0x4444;
    const closing: Id = 0x5555;
    const its_worker: Id = 0x6666;
    try b.addSupervisor(boss);
    try b.addSupervisor(survivor);
    try b.addSupervisor(closing);
    try b.watch(worker, boss);
    try b.watch(its_worker, closing);
    _ = b.report(worker, quiet(60_000), 0);
    _ = b.report(its_worker, quiet(60_000), 0);

    var buf: [255]u8 = undefined;
    b.unregister(closing);
    b.removeSupervisor(boss);
    try testing.expectEqual(@as(usize, 1), b.supervisorCount());

    const inherited = b.drain(survivor, 1_000, &buf, .none);
    try testing.expect(inherited == null);
    try testing.expect(b.get(worker).?.last_event_ms == null);
}

test "#1067: a watched terminal made a supervisor does not carry its notices into the job" {
    var b = testBus();
    defer b.deinit();
    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    _ = b.report(worker, quiet(60_000), 0);

    try b.addSupervisor(worker);
    const left = b.get(worker).?.pending;
    try testing.expect(left == null);
}

test "a note rides out in the same line as the quiet reports" {
    // The point of putting it in this box rather than sending it: one
    // interruption, on the one clock the user set, whatever there is to
    // say.
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    _ = b.report(worker, quiet(60_000), 0);
    try testing.expect(b.leaveNote(boss, "build: #93 untouched 49h"));

    var buf: [255]u8 = undefined;
    const line = b.drain(boss, 1_000, &buf, .none) orelse return error.ExpectedANotice;

    try testing.expect(std.mem.indexOf(u8, line, "quiet") != null);
    try testing.expect(std.mem.indexOf(u8, line, "#93 untouched 49h") != null);

    // Read once, gone -- the same rule the terminal reports keep.
    try testing.expect(b.drain(boss, 2_000, &buf, .none) == null);
}

test "a note on its own is worth an interruption" {
    // Nothing quiet, nothing resumed, and still something to say: a night
    // where every screen is moving can be a night where a task has been
    // sitting untouched since yesterday.
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try testing.expect(b.leaveNote(boss, "build: quiet 3h40m"));

    var buf: [255]u8 = undefined;
    const line = b.drain(boss, 1_000, &buf, .none) orelse return error.ExpectedANotice;
    try testing.expect(std.mem.indexOf(u8, line, "quiet 3h40m") != null);
}

test "a note waits for the interval the same as everything else" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try testing.expect(b.leaveNote(boss, "build: #93 untouched 49h"));

    // Delivered once...
    var buf: [255]u8 = undefined;
    try testing.expect(b.drainIfDue(boss, 0, &buf, .none) != null);

    // ...and the next one waits out `notice_interval_ms`, which is the one
    // number the user set to say how often this may happen at all.
    try testing.expect(b.leaveNote(boss, "build: #71 untouched 40h"));
    try testing.expect(b.drainIfDue(boss, 1_000, &buf, .none) == null);
    try testing.expect(b.drainIfDue(boss, std.time.ms_per_min + 1, &buf, .none) != null);
}

test "a note nobody reads stops repeating itself" {
    // A hand-over is typed into an input box and typing is not arrival, so
    // it is held rather than consumed -- and bounded, or an unread note
    // pastes itself in for ever.
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try testing.expect(b.leaveNote(boss, "build: #93 untouched 49h"));

    var buf: [255]u8 = undefined;
    var at: u64 = 0;
    for (0..3) |_| {
        try testing.expect(b.drainIfDue(boss, at, &buf, .none) != null);
        at += std.time.ms_per_min + 1;
    }
    try testing.expect(b.drainIfDue(boss, at, &buf, .none) == null);
}

test "a note that has stopped being true can be taken back" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try testing.expect(b.leaveNote(boss, "build: #93 untouched 49h"));
    try testing.expect(b.leaveNote(boss, ""));

    var buf: [255]u8 = undefined;
    try testing.expect(b.drain(boss, 1_000, &buf, .none) == null);
}

test "only a supervisor has a box to leave a note in" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    try testing.expect(!b.leaveNote(worker, "not yours"));
    try testing.expect(!b.leaveNote(0x9999, "nobody at all"));

    // And a line too long is refused whole rather than cut in half.
    const long = "x" ** (memo_bytes + 1);
    try testing.expect(!b.leaveNote(boss, long));
}

test "one supervisor's note does not turn up in another's box" {
    var b = testBus();
    defer b.deinit();

    const second: Id = 0x4444;
    try b.addSupervisor(boss);
    try b.addSupervisor(second);
    try testing.expect(b.leaveNote(boss, "build: #93 untouched 49h"));

    var buf: [255]u8 = undefined;
    try testing.expect(b.drain(second, 1_000, &buf, .none) == null);
    try testing.expect(b.drain(boss, 1_000, &buf, .none) != null);
}

test "a claimed terminal reports only to the supervisor minding it" {
    var b = testBus();
    defer b.deinit();

    const second: Id = 0x4444;
    try b.addSupervisor(boss);
    try b.addSupervisor(second);
    try b.watch(worker, boss);
    _ = b.report(worker, quiet(60_000), 0);

    // Not the other one's business, and not in its box.
    var buf: [255]u8 = undefined;
    try testing.expect(b.drain(second, 1_000, &buf, .none) == null);

    // Still waiting for the one whose terminal it is.
    var buf2: [255]u8 = undefined;
    try testing.expect(b.drain(boss, 1_000, &buf2, .none) != null);
}

test "a watched terminal going quiet reaches the supervisor" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    try testing.expect(b.report(worker, quiet(180_000), 0));
    try testing.expectEqual(NoticeKind.quiescent, b.get(worker).?.pending.?);

    // And it is the supervisor that would be handed it.
    try testing.expect(b.isSupervisor(boss));
}

test "the supervisor is not reported to itself" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try testing.expect(b.report(boss, quiet(180_000), 0) == false);
}

test "an unwatched terminal is not reported" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.register(worker); // known, but not watched
    try testing.expect(b.report(worker, quiet(180_000), 0) == false);
}

test "quiet duration is extrapolated, not left stale" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    // Reported still for 180s at t=180_000.
    _ = b.report(worker, quiet(180_000), 180_000);

    // A minute later with no further report. The screen cannot have moved
    // in between -- that would have produced a `resumed` -- so the true
    // figure is 240s, not the 180s that was last announced.
    try testing.expectEqual(@as(u64, 240_000), b.quietMs(worker, 240_000));
}

test "coming back to work restarts the quiet clock" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    _ = b.report(worker, quiet(180_000), 180_000);
    _ = b.report(worker, .{ .resumed = .{
        .quiet_ms = 180_000,
        .silent_ms = 0,
        .changed_rows = 4,
        .total_rows = 24,
    } }, 200_000);

    try testing.expectEqual(@as(u64, 0), b.quietMs(worker, 200_000));
    try testing.expectEqual(@as(u64, 5_000), b.quietMs(worker, 205_000));
}

test "a clocked off terminal still answers how long it has been quiet" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    try b.clockOff(worker, .supervisor);

    // No notice is produced -- that is the point of clocking off -- but the
    // supervisor asking directly still gets a real answer.
    try testing.expect(b.report(worker, quiet(180_000), 180_000) == false);
    try testing.expectEqual(@as(u64, 200_000), b.quietMs(worker, 200_000));
}

test "an unknown terminal reports no quiet time rather than misleading" {
    var b = testBus();
    defer b.deinit();
    try testing.expectEqual(@as(u64, 0), b.quietMs(0xdead, 999_999));
}

test "rounds count up while quiet and reset on coming back" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    try testing.expectEqual(@as(u16, 0), b.get(worker).?.rounds);

    _ = b.report(worker, quiet(180_000), 0);
    try testing.expectEqual(@as(u16, 1), b.get(worker).?.rounds);

    _ = b.report(worker, quiet(190_000), 10_000);
    try testing.expectEqual(@as(u16, 2), b.get(worker).?.rounds);

    _ = b.report(worker, .{ .resumed = .{
        .quiet_ms = 190_000,
        .silent_ms = 0,
        .changed_rows = 2,
        .total_rows = 24,
    } }, 20_000);
    try testing.expectEqual(@as(u16, 0), b.get(worker).?.rounds);
}

test "rounds count every report, not every interruption" {
    // The supervisor is interrupted far less often than the terminals
    // report, but the count is what the clock-out skill reasons about, so
    // it has to follow the terminal rather than the hand-overs.
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    try testing.expect(b.report(worker, quiet(180_000), 0));
    try testing.expect(b.report(worker, quiet(181_000), 100));
    try testing.expectEqual(@as(u16, 2), b.get(worker).?.rounds);

    // Both of them are one entry in the box, not two.
    var buf: [255]u8 = undefined;
    const line = b.drain(boss, 100, &buf, .none) orelse return error.ExpectedANotice;
    const first = std.mem.indexOf(u8, line, "0x0000000000002222").?;
    try testing.expect(std.mem.indexOfPos(u8, line, first + 1, "0x0000000000002222") == null);
}

test "a clocked off terminal stops being reported" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    try b.clockOff(worker, .supervisor);
    try testing.expect(b.report(worker, quiet(180_000), 10_000) == false);

    // Back on duty, reported again.
    try b.clockOn(worker);
    try testing.expect(b.report(worker, quiet(180_000), 20_000));
}

test "a held terminal cannot be clocked off" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    try b.setHeld(worker, true, .user);
    try testing.expectError(
        error.TerminalHeld,
        b.clockOff(worker, .supervisor),
    );
    try testing.expectEqual(Duty.on, b.get(worker).?.duty);

    // Released, it clocks off like any other.
    try b.setHeld(worker, false, .user);
    try b.clockOff(worker, .supervisor);
    try testing.expectEqual(Duty.off, b.get(worker).?.duty);
}

test "the supervisor cannot lift a hold to get around the ban" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    try b.setHeld(worker, true, .user);

    // The obvious way around the rule: lift the hold, then clock off.
    try testing.expectError(
        error.NotPermitted,
        b.setHeld(worker, false, .supervisor),
    );
    try testing.expect(b.get(worker).?.held);
    try testing.expectError(
        error.TerminalHeld,
        b.clockOff(worker, .supervisor),
    );

    // Nor may it put one on: the hold is the user's word about this
    // terminal, in either direction.
    try b.setHeld(worker, false, .user);
    try testing.expectError(
        error.NotPermitted,
        b.setHeld(worker, true, .supervisor),
    );
    try testing.expect(!b.get(worker).?.held);
}

test "only the supervisor clocks terminals off" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    try testing.expectError(error.NotPermitted, b.clockOff(worker, .user));
}

test "naming a second supervisor leaves the first one standing" {
    var b = testBus();
    defer b.deinit();

    // There used to be exactly one, and this named the second to prove the
    // first was stood down. That made a window hold one piece of work.
    const second: Id = 0x4444;
    try b.addSupervisor(boss);
    try b.addSupervisor(second);

    try testing.expect(b.isSupervisor(boss));
    try testing.expect(b.isSupervisor(second));

    // Standing one down is now its own act, and touches only that one.
    b.removeSupervisor(second);
    try testing.expect(b.isSupervisor(boss));
    try testing.expect(!b.isSupervisor(second));
}

test "watching the supervisor does not demote it" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(boss, boss);
    try testing.expectEqual(Role.supervisor, b.get(boss).?.role);
    try testing.expect(b.isSupervisor(boss));
}

test "closing the supervisor's terminal leaves nobody supervising" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    b.unregister(boss);
    try testing.expect(!b.isSupervisor(boss));
    try testing.expect(b.report(worker, quiet(180_000), 0) == false);
}

test "register is idempotent and keeps existing state" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    try b.setHeld(worker, true, .user);

    try b.register(worker);
    try testing.expect(b.get(worker).?.held);
    try testing.expectEqual(Role.watched, b.get(worker).?.role);
}

test "unknown terminals are rejected rather than silently created" {
    var b = testBus();
    defer b.deinit();

    try testing.expectError(
        error.UnknownTerminal,
        b.setHeld(0xdead, true, .user),
    );
    try b.addSupervisor(boss);
    try testing.expectError(
        error.UnknownTerminal,
        b.clockOff(0xdead, .supervisor),
    );
}

test "a terminal nothing has sampled is not reported as quiet for ever" {
    // The bug: `last_event_ms` defaulted to zero, so the answer for a
    // terminal nothing had sampled was `now - 0` -- how long the program
    // had been up. A terminal opened a minute ago came back as still for
    // half a day, and the supervisor acts on this number.
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    try testing.expect(!b.observed(worker));
    try testing.expectEqual(@as(u64, 0), b.quietMs(worker, 46_292_971));

    // And its tab says it is working, not that it has stopped.
    try testing.expectEqual(TabMark.on_duty, b.tabMark(worker, 46_292_971, 120_000));

    // One report in, and it counts from there rather than from zero.
    _ = b.report(worker, quiet(60_000), 100_000);
    try testing.expect(b.observed(worker));
    try testing.expectEqual(@as(u64, 60_000), b.quietMs(worker, 100_000));
    try testing.expectEqual(@as(u64, 90_000), b.quietMs(worker, 130_000));
}

test "an unwatched terminal's tab says nothing" {
    var b = testBus();
    defer b.deinit();

    try testing.expectEqual(TabMark.none, b.tabMark(worker, 0, 1000));
    try b.register(worker);
    try testing.expectEqual(TabMark.none, b.tabMark(worker, 0, 1000));
}

test "a tab mark follows the terminal's role and duty" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    try testing.expectEqual(TabMark.supervisor, b.tabMark(boss, 0, 1000));
    try testing.expectEqual(TabMark.on_duty, b.tabMark(worker, 0, 1000));

    try b.clockOff(worker, .supervisor);
    try testing.expectEqual(TabMark.off_duty, b.tabMark(worker, 0, 1000));
}

test "a tab says quiet once the screen has been still long enough" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    _ = b.report(worker, quiet(60_000), 60_000);

    try testing.expectEqual(TabMark.on_duty, b.tabMark(worker, 60_000, 120_000));
    try testing.expectEqual(TabMark.quiet, b.tabMark(worker, 180_000, 120_000));
}

test "a clocked off terminal reads as off duty even while quiet" {
    // Off duty is the more useful thing to say: it is quiet because it was
    // told to stop, not because it got stuck.
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    _ = b.report(worker, quiet(600_000), 600_000);
    try b.clockOff(worker, .supervisor);

    try testing.expectEqual(TabMark.off_duty, b.tabMark(worker, 600_000, 1000));
}

test "a held terminal wears a ring, moving or still" {
    // The whole reason the hold is a mark and not a one-off message: the
    // user has to be able to see, at any moment, which terminals the
    // program is holding to their work.
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    _ = b.report(worker, quiet(60_000), 60_000);

    // Not held: the plain pair.
    try testing.expectEqual(TabMark.on_duty, b.tabMark(worker, 60_000, 120_000));
    try testing.expectEqual(TabMark.quiet, b.tabMark(worker, 180_000, 120_000));

    // Held: the same two states, ringed.
    try b.setHeld(worker, true, .user);
    try testing.expectEqual(TabMark.held_on_duty, b.tabMark(worker, 60_000, 120_000));
    try testing.expectEqual(TabMark.held_quiet, b.tabMark(worker, 180_000, 120_000));

    // Releasing it puts the plain pair back.
    try b.setHeld(worker, false, .user);
    try testing.expectEqual(TabMark.on_duty, b.tabMark(worker, 60_000, 120_000));
    try testing.expectEqual(TabMark.quiet, b.tabMark(worker, 180_000, 120_000));
}

test "there is no held-and-off-duty mark, because there is no such state" {
    // The fourth combination the ring might have needed does not exist:
    // the hold is exactly what stops a terminal being clocked off, so a
    // held terminal can only ever be moving or still.
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    // Clocked off first, then held: the hold does not resurrect it, and
    // the mark stays honest about the duty.
    try b.clockOff(worker, .supervisor);
    try b.setHeld(worker, true, .user);
    try testing.expectEqual(TabMark.off_duty, b.tabMark(worker, 0, 1000));

    // Back on duty, the ring shows.
    try b.clockOn(worker);
    try testing.expectEqual(TabMark.held_on_duty, b.tabMark(worker, 0, 1000));

    // And from here it cannot go off duty again while the hold stands.
    try testing.expectError(error.TerminalHeld, b.clockOff(worker, .supervisor));
}

test "every mark but none has a marker, and none has nothing" {
    try testing.expectEqualStrings("", TabMark.none.prefix());
    for ([_]TabMark{
        .on_duty,
        .quiet,
        .off_duty,
        .held_on_duty,
        .held_quiet,
        .supervisor,
        .supervisor_silent,
    }) |m| {
        try testing.expect(m.prefix().len > 0);
        // Trailing space, because it sits in front of a title.
        try testing.expect(m.prefix()[m.prefix().len - 1] == ' ');
    }

    // Every marker is distinct: two terminals in different states must not
    // look the same in the tab bar.
    const all = std.enums.values(TabMark);
    for (all, 0..) |a, i| for (all[i + 1 ..]) |c| {
        try testing.expect(!std.mem.eql(u8, a.prefix(), c.prefix()));
    };
}

test "the shield marker is its own, and reads in front of any other" {
    // It is composed with a `TabMark` rather than being one, so the thing
    // to prove is that the composition stays readable: it must not be
    // mistakable for a state marker, and it must not vanish when there is
    // no state marker to sit in front of.
    try testing.expect(shield_prefix.len > 0);
    try testing.expect(shield_prefix[shield_prefix.len - 1] == ' ');

    for (std.enums.values(TabMark)) |m| {
        try testing.expect(!std.mem.eql(u8, shield_prefix, m.prefix()));
    }

    // Shield plus the unmarked case is still a visible mark. This is the
    // case the whole feature is for -- a shell nobody watches -- and if
    // the composition collapsed to nothing here it would be invisible
    // exactly where it is needed.
    var buf: [64]u8 = undefined;
    const composed = try std.fmt.bufPrint(
        &buf,
        "{s}{s}",
        .{ shield_prefix, TabMark.none.prefix() },
    );
    try testing.expect(composed.len > 0);
    try testing.expectEqualStrings(shield_prefix, composed);
}

test "reading the box clears it" {
    // The point of the box: what has been shown once is not shown again.
    var bus = testBus();
    defer bus.deinit();

    try bus.addSupervisor(boss);
    try bus.watch(worker, boss);
    _ = bus.report(worker, quiet(60_000), 1000);

    var buf: [255]u8 = undefined;
    const first = bus.drain(boss, 1000, &buf, .none) orelse return error.ExpectedANotice;
    try testing.expect(std.mem.indexOf(u8, first, "0x0000000000002222") != null);
    try testing.expect(std.mem.indexOf(u8, first, "quiet") != null);

    // Nothing new has happened, so there is nothing to say.
    try testing.expect(bus.drain(boss, 2000, &buf, .none) == null);
}

test "many reports about one terminal read as one line" {
    // Fifteen repeats of "still quiet" are one fact, not fifteen. This is
    // what keeps the supervisor's screen proportional to how many terminals
    // exist rather than to how long they have been idle.
    var bus = testBus();
    defer bus.deinit();

    try bus.addSupervisor(boss);
    try bus.watch(worker, boss);

    var t: u64 = 1000;
    for (0..15) |_| {
        _ = bus.report(worker, quiet(60_000), t);
        t += 20_000;
    }

    var buf: [255]u8 = undefined;
    const line = bus.drain(boss, t, &buf, .none) orelse return error.ExpectedANotice;

    // One mention of the terminal, and no "+N more".
    const first = std.mem.indexOf(u8, line, "0x0000000000002222").?;
    try testing.expect(std.mem.indexOfPos(u8, line, first + 1, "0x0000000000002222") == null);
    try testing.expect(std.mem.indexOf(u8, line, "more") == null);
}

test "coming back to work replaces the quiet it is waiting on" {
    // Quiet then busy again before anybody read the box: the terminal is
    // working, and that is all worth saying. The excursion in between is
    // exactly the case that needed nobody.
    var bus = testBus();
    defer bus.deinit();

    try bus.addSupervisor(boss);
    try bus.watch(worker, boss);

    _ = bus.report(worker, quiet(60_000), 1000);
    _ = bus.report(worker, .{ .resumed = .{
        .quiet_ms = 0,
        .silent_ms = 0,
        .changed_rows = 3,
        .total_rows = 24,
    } }, 3000);

    var buf: [255]u8 = undefined;
    const line = bus.drain(boss, 3000, &buf, .none) orelse return error.ExpectedANotice;
    try testing.expect(std.mem.indexOf(u8, line, "back at work") != null);
    try testing.expect(std.mem.indexOf(u8, line, "quiet") == null);
}

test "an empty box says nothing rather than saying all is well" {
    // An interruption carrying no information is still an interruption.
    var bus = testBus();
    defer bus.deinit();

    try bus.addSupervisor(boss);
    try bus.watch(worker, boss);

    var buf: [255]u8 = undefined;
    try testing.expect(bus.drain(boss, 1000, &buf, .none) == null);
}

test "more terminals than fit are counted rather than listed" {
    var bus = testBus();
    defer bus.deinit();

    try bus.addSupervisor(boss);

    var id: Id = 0x100;
    for (0..max_listed + 3) |_| {
        try bus.watch(id, boss);
        _ = bus.report(id, quiet(60_000), 1000);
        id += 1;
    }

    var buf: [255]u8 = undefined;
    const line = bus.drain(boss, 1000, &buf, .none) orelse return error.ExpectedANotice;
    try testing.expect(std.mem.indexOf(u8, line, "(+3 more)") != null);

    // Counted or listed, every one of them was consumed.
    try testing.expect(bus.drain(boss, 1000, &buf, .none) == null);
}

test "a notice that waited says how long it has been quiet now" {
    // The figure is recomputed on reading, not frozen at report time, so a
    // supervisor reading a minute later is not told a minute-old number.
    var bus = testBus();
    defer bus.deinit();

    try bus.addSupervisor(boss);
    try bus.watch(worker, boss);
    _ = bus.report(worker, quiet(60_000), 1000);

    var buf: [255]u8 = undefined;
    const line = bus.drain(boss, 1000 + 30_000, &buf, .none) orelse return error.ExpectedANotice;
    try testing.expect(std.mem.indexOf(u8, line, "quiet 90s") != null);
}

test "a terminal the supervisor never watched is not in the box" {
    var bus = testBus();
    defer bus.deinit();

    try bus.addSupervisor(boss);
    try bus.register(worker);
    _ = bus.report(worker, quiet(60_000), 1000);

    var buf: [255]u8 = undefined;
    try testing.expect(bus.drain(boss, 1000, &buf, .none) == null);
}

test "the hold is the user's alone -- the supervisor cannot touch it" {
    // Arranging work is the supervisor's job, but the hold is not work
    // arrangement: it is the user's standing word that this terminal does
    // not stop. If the supervisor could set it, it could clear it, and the
    // one thing the hold exists to prevent would be back.
    //
    // Nothing is lost by refusing it either way -- the supervisor decides
    // afresh on every wake-up whether there is more worth doing, which is
    // what a mode switch used to say and then forget.
    var b = testBus();
    defer b.deinit();

    const hand: Id = 0xbeef;
    try b.watch(hand, boss);

    try testing.expectError(
        error.NotPermitted,
        b.setHeld(hand, true, .supervisor),
    );
    try testing.expect(!b.get(hand).?.held);

    try b.setHeld(hand, true, .user);
    try testing.expectError(
        error.NotPermitted,
        b.setHeld(hand, false, .supervisor),
    );
    try testing.expect(b.get(hand).?.held);

    // And the terminal still cannot be clocked off, which is what the
    // hold was for.
    try testing.expectError(error.TerminalHeld, b.clockOff(hand, .supervisor));

    // The user can always lift their own.
    try b.setHeld(hand, false, .user);
    try b.clockOff(hand, .supervisor);
}

test "a scheduled hand-over holds the notice, because typing is not arrival" {
    // The failure this fixes: the hand-over is typed into the supervisor's
    // terminal, and if that agent was mid-turn the text lands in its input
    // box while the return that should submit it does not take. Clearing
    // the box on the way out made that a silent loss -- the notice was
    // gone and nothing would ever say it again.
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    _ = b.report(worker, quiet(200_000), 1_000);

    var buf: [512]u8 = undefined;

    // Handed over, and still there to hand over again.
    const first = b.take(boss, 1_000, &buf, .hand_over, .none) orelse return error.NothingToSay;
    try testing.expect(std.mem.indexOf(u8, first, "quiet") != null);

    var buf2: [512]u8 = undefined;
    const second = b.take(boss, 2_000, &buf2, .hand_over, .none) orelse return error.NothingToSay;
    try testing.expect(std.mem.indexOf(u8, second, "quiet") != null);
}

test "the supervisor reading the box clears it, because that is arrival" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    _ = b.report(worker, quiet(200_000), 1_000);

    var buf: [512]u8 = undefined;
    _ = b.take(boss, 1_000, &buf, .consume, .none) orelse return error.NothingToSay;

    // Nothing left: what it read, it has.
    var buf2: [512]u8 = undefined;
    try testing.expect(b.take(boss, 2_000, &buf2, .consume, .none) == null);
}

test "a notice nobody reads stops repeating rather than stacking up" {
    // Each hand-over pastes the same line into the supervisor's input box
    // again, so an unread notice would otherwise pile copies of itself up
    // for as long as the terminal stays quiet.
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    _ = b.report(worker, quiet(200_000), 1_000);

    var buf: [512]u8 = undefined;
    var handed: usize = 0;
    var at: u64 = 1_000;
    while (b.take(boss, at, &buf, .hand_over, .none) != null) : (at += 1_000) {
        handed += 1;
        if (handed > 10) break;
    }

    try testing.expectEqual(@as(usize, 3), handed);
}

test "a supervisor that has let everybody go may stand itself down" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.register(worker);
    try b.watch(worker, boss);

    // Not while it is still responsible for somebody. Standing down
    // releases nothing, so the release has to have happened already.
    try testing.expectError(error.StillMinding, b.standDown(boss));
    try testing.expect(b.isSupervisor(boss));

    b.unwatch(worker);
    try b.standDown(boss);

    try testing.expect(!b.isSupervisor(boss));
}

test "standing down stops the interval it was being woken on" {
    // The whole point of the tool: an empty box handed over every minute
    // for the rest of the night is what a finished supervisor is left with.
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.register(worker);
    try b.watch(worker, boss);
    _ = b.report(worker, quiet(200_000), 1000);

    var buf: [512]u8 = undefined;
    try testing.expect(b.drainIfDue(boss, 1000, &buf, .none) != null);

    b.unwatch(worker);
    try b.standDown(boss);

    // Nothing is delivered to a terminal that is no longer minding anyone,
    // whatever is in the box.
    _ = b.report(worker, quiet(300_000), 200_000);
    try testing.expect(b.drainIfDue(boss, 200_000, &buf, .none) == null);
}

test "a user who says a supervisor may not stand down is obeyed" {
    var b: Bus = .init(testing.allocator, .{ .stand_down_allowed = false });
    defer b.deinit();

    try b.addSupervisor(boss);
    try testing.expectError(error.NotPermitted, b.standDown(boss));
    try testing.expect(b.isSupervisor(boss));

    // And the keybind is unaffected: the setting binds the agent, not the
    // person at the keyboard.
    b.removeSupervisor(boss);
    try testing.expect(!b.isSupervisor(boss));
}

test "a terminal that was never a supervisor cannot stand down from it" {
    var b = testBus();
    defer b.deinit();

    try b.register(worker);
    try testing.expectError(error.NotASupervisor, b.standDown(worker));
    try testing.expectError(error.NotASupervisor, b.standDown(0xdead));
}

test "only the user colours a pane or keeps workers out of it, and it starts with neither (#1699)" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    try testing.expectEqual(PaneColor.none, b.paneColor(worker));
    try testing.expectEqual(Workers.allowed, b.workersOf(worker));

    // A supervisor is refused both: they are marks the person makes for
    // themselves.
    try testing.expectError(error.NotPermitted, b.setPaneColor(worker, .orange, .supervisor));
    try testing.expectError(error.NotPermitted, b.setWorkers(worker, .refused, .supervisor));
    try testing.expectEqual(PaneColor.none, b.paneColor(worker));
    try testing.expectEqual(Workers.allowed, b.workersOf(worker));

    try b.setPaneColor(worker, .orange, .user);
    try b.setWorkers(worker, .refused, .user);
    try testing.expectEqual(PaneColor.orange, b.paneColor(worker));
    try testing.expectEqual(Workers.refused, b.workersOf(worker));

    // Keeping workers out takes nothing out of reach, and leaves the watch.
    try testing.expect(!b.isShielded(worker));
    try testing.expectEqual(Role.watched, b.roleOf(worker));

    // A terminal the bus never heard of carries neither.
    try testing.expectEqual(Workers.allowed, b.workersOf(0xdead));
    try testing.expectError(error.UnknownTerminal, b.setPaneColor(0xdead, .blue, .user));
}

test "a supervisor given no colour is shown purple, and given one is shown in it (#1699)" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    try testing.expectEqual(PaneColor.purple, b.shownColor(boss));
    try testing.expectEqual(PaneColor.none, b.paneColor(boss));
    try testing.expectEqual(PaneColor.none, b.shownColor(worker));

    try b.setPaneColor(boss, .teal, .user);
    try testing.expectEqual(PaneColor.teal, b.shownColor(boss));
    try b.setPaneColor(worker, .purple, .user);
    try testing.expectEqual(PaneColor.purple, b.shownColor(worker));
}

test "the flag among a tab's dots is the supervisor's, raised or lowered" {
    for (std.enums.values(TabMark)) |m| {
        const want: Flag = switch (m) {
            .supervisor => .raised,
            .supervisor_silent => .lowered,
            else => .none,
        };
        try testing.expectEqual(want, m.flag());
    }
}

test "only the user may shield a terminal, and it starts unshielded" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    // A terminal carries no marks until somebody puts one on it, and the
    // reach rule reads an unmarked terminal as open.
    try testing.expect(!b.isShielded(worker));

    // The supervisor is refused, which is the point: reach is decided by
    // what the target is marked as, and a party that could clear the mark
    // would be deciding its own reach.
    try testing.expectError(
        error.NotPermitted,
        b.setShielded(worker, true, .supervisor),
    );
    try testing.expect(!b.isShielded(worker));

    try b.setShielded(worker, true, .user);
    try testing.expect(b.isShielded(worker));

    try b.setShielded(worker, false, .user);
    try testing.expect(!b.isShielded(worker));
}

test "shielding a supervisor is allowed, and says nothing about holding it" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);

    // Supervisors are terminals too. One left running overnight is exactly
    // the thing a user might want nobody else typing into.
    try b.setShielded(boss, true, .user);
    try testing.expect(b.isShielded(boss));

    // The two marks are independent. `held` says "you may not stop", this
    // says "nobody may touch you", and neither implies the other -- a test
    // rather than a comment because the pair is easy to conflate.
    try testing.expect(!b.get(boss).?.held);
    try b.setHeld(boss, true, .user);
    try testing.expect(b.isShielded(boss) and b.get(boss).?.held);

    try b.setShielded(boss, false, .user);
    try testing.expect(!b.isShielded(boss) and b.get(boss).?.held);
}

test "a supervisor may answer prompts in every terminal until the person says otherwise, and only the person can say" {
    var b = testBus();
    defer b.deinit();
    try b.register(worker);

    // **On to begin with**, for a terminal nobody has said anything about
    // (the user's decision, 2026-10-12, for every terminal).
    try testing.expect(b.mayAuthorise(worker));
    try testing.expectEqual(Answer.allowed, b.answer(worker));

    // The person switches it off, and it is off.
    try b.setMayAuthorise(worker, false, .user);
    try testing.expect(!b.mayAuthorise(worker));
    try testing.expectEqual(Answer.off, b.answer(worker));

    // A supervisor cannot switch it back on. This is the whole of the
    // protection: without it, the first move of any supervisor that met a
    // terminal the person had closed to it would be to open it again.
    try testing.expectError(
        error.NotPermitted,
        b.setMayAuthorise(worker, true, .supervisor),
    );
    try testing.expect(!b.mayAuthorise(worker));

    // Nor can it switch one off, for that matter: the switch is the
    // person's in both directions.
    try b.setMayAuthorise(worker, true, .user);
    try testing.expectError(
        error.NotPermitted,
        b.setMayAuthorise(worker, false, .supervisor),
    );
    try testing.expect(b.mayAuthorise(worker));
}

test "who opened a terminal does not come into whether its prompts may be answered" {
    var b = testBus();
    defer b.deinit();
    try b.addSupervisor(boss);
    const plain: Id = 0x7001;
    const opened: Id = 0x7002;
    try b.register(plain);

    // Opened by a supervisor, opened by a plain worker, started by the
    // person: all three are the default.
    try b.markOpenedByAgent(worker, boss);
    try b.markOpenedByAgent(opened, plain);
    try testing.expect(b.openedByAgent(worker) and b.openedByAgent(opened));
    try testing.expect(b.mayAuthorise(worker) and b.mayAuthorise(opened) and b.mayAuthorise(plain));

    // And being opened by a supervisor does not undo the person's no: it
    // used to be the one thing that put the switch on, and marking a
    // terminal again must not put it back.
    try b.setMayAuthorise(worker, false, .user);
    try b.markOpenedByAgent(worker, boss);
    try testing.expect(!b.mayAuthorise(worker));
}

test "an unregistered terminal gets the default, and has no switch to set" {
    var b = testBus();
    defer b.deinit();

    try testing.expect(b.mayAuthorise(0xDEAD));
    try testing.expectError(
        error.UnknownTerminal,
        b.setMayAuthorise(0xDEAD, false, .user),
    );
}

test "with the default set to off in the configuration every terminal starts closed, and the person opens one" {
    // What outlasts a restart: a bus is made new each time and a terminal's
    // id with it, so the one place a "no" can be kept is the configuration.
    // A new bus given that configuration must not come up open.
    var b: Bus = .init(testing.allocator, .{ .may_authorise = false });
    defer b.deinit();
    try b.addSupervisor(boss);
    try b.register(worker);

    try testing.expect(!b.mayAuthorise(worker));
    try testing.expect(!b.mayAuthorise(0xDEAD));
    try testing.expectEqual(Answer.off, b.answer(worker));

    // Not opened by a supervisor opening it, either: somebody who set the
    // default to off said so about every terminal.
    try b.markOpenedByAgent(0x7002, boss);
    try testing.expect(!b.mayAuthorise(0x7002));

    // The person's own choice for one terminal still stands over it.
    try b.setMayAuthorise(worker, true, .user);
    try testing.expect(b.mayAuthorise(worker));

    // And the other way round: a "no" on one terminal is not lifted by the
    // default being on, when the configuration is read again.
    try b.setMayAuthorise(worker, false, .user);
    b.config.may_authorise = true;
    try testing.expect(!b.mayAuthorise(worker));
    try testing.expect(b.mayAuthorise(0x7002));
}

test "a shielded terminal's notice says shielded, whatever the switch says" {
    var b = testBus();
    defer b.deinit();
    try b.register(worker);
    try b.setShielded(worker, true, .user);
    try testing.expect(b.mayAuthorise(worker));
    try testing.expectEqual(Answer.shielded, b.answer(worker));
}

test "the two switches are independent" {
    var b = testBus();
    defer b.deinit();
    try b.register(worker);

    // Shielding is "nobody may touch you"; this is "a supervisor may answer
    // your prompts". Neither implies the other, and a terminal can sensibly
    // be both -- out of reach of the tools, with the switch left on from
    // before. The combination is not a contradiction to resolve here.
    try b.setMayAuthorise(worker, true, .user);
    try b.setShielded(worker, true, .user);
    try testing.expect(b.mayAuthorise(worker) and b.isShielded(worker));

    try b.setShielded(worker, false, .user);
    try testing.expect(b.mayAuthorise(worker) and !b.isShielded(worker));
}

test "a terminal the bus never registered is not shielded" {
    var b = testBus();
    defer b.deinit();

    // Not an error and not shielded: it carries no marks at all, which is
    // the open case. Reporting it as shielded would make every unknown id
    // unreachable and turn a typo into a permission failure.
    try testing.expect(!b.isShielded(0xDEAD));

    // Setting it is still an error, because there is nothing to set it on.
    try testing.expectError(
        error.UnknownTerminal,
        b.setShielded(0xDEAD, true, .user),
    );
}

test "shielding a watched terminal stops it being watched" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    try testing.expectEqual(Role.watched, b.roleOf(worker));

    try b.setShielded(worker, true, .user);

    // Not merely unreachable -- no longer minded. A supervisor woken about
    // a terminal it may not touch is being interrupted with no move behind
    // the interruption.
    try testing.expectEqual(Role.none, b.roleOf(worker));
    try testing.expect(b.isShielded(worker));
    try testing.expect(b.get(worker).?.watched_by == null);
}

test "shielding a supervisor leaves it supervising" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    try b.setShielded(boss, true, .user);

    // The shield is about being reached; supervising is reaching. Clearing
    // the role would not protect this terminal, it would stop it -- and
    // the terminal somebody shields is the one running the night.
    try testing.expectEqual(Role.supervisor, b.roleOf(boss));
    try testing.expect(b.isShielded(boss));
    try testing.expectEqual(Role.watched, b.roleOf(worker));
    try testing.expect(b.minds(boss, worker));
}

test "unshielding does not put a terminal back under supervision" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    try b.setShielded(worker, true, .user);
    try b.setShielded(worker, false, .user);

    // Coming out from behind the shield is not an instruction to resume
    // anything. Who minds what is the supervisor's arrangement to make,
    // and guessing it back would be this code deciding on its behalf.
    try testing.expectEqual(Role.none, b.roleOf(worker));
}

/// Drive a real sampler and a real bus together for `ms` milliseconds of
/// simulated time, one sample a second, and return the largest figure
/// `quietMs` ever gave while it ran.
///
/// `moving` says whether the screen changes between samples. Everything
/// else is the production path: the sampler decides what is an event and
/// what is a heartbeat, and the bus is told each the way the app tells it.
fn runSampler(b: *Bus, s: *Sampler, id: Id, from_ms: u64, ms: u64, moving: bool) struct { u64, u64 } {
    var now = from_ms;
    var peak: u64 = 0;
    var screen: u64 = from_ms;

    while (now < from_ms + ms) : (now += 1000) {
        if (moving) screen += 1;

        const obs: Sampler.Observation = .{
            .now_ms = now,
            .bytes = if (moving) 10 else 0,
            .fingerprint = .{ .screen = screen, .changed_rows = 1, .total_rows = 24 },
        };
        if (s.observe(obs)) |event| _ = b.report(id, event, now);
        if (s.heartbeat(now)) |quiet_ms| b.noteQuiet(id, quiet_ms, now);

        peak = @max(peak, b.quietMs(id, now));
    }
    return .{ peak, now };
}

test "a terminal whose screen keeps changing is not reported as quiet" {
    // The defect this is here for. `quietMs` extrapolates from the last
    // thing it was told, and the sampler used to tell it nothing at all
    // while a screen was moving -- so a terminal that went quiet once and
    // then worked for half an hour was reported as still for half an hour,
    // climbing. A supervisor reading that goes and interrupts somebody who
    // is in the middle of the job.
    //
    // Constructed rather than observed: the screen below provably changes
    // between every pair of samples, so any figure above one sample
    // interval plus one heartbeat interval is wrong by construction.
    var b = testBus();
    defer b.deinit();
    try b.addSupervisor(boss);
    try b.watch(worker, null);

    var s: Sampler = .init(.{
        .quiescence_ms = 3 * std.time.ms_per_min,
        .repeat_ms = 15 * std.time.ms_per_min,
        .sample_interval_ms = 1000,
        .heartbeat_ms = 5000,
    });

    // Four minutes of a still screen first, because the wrong number was
    // extrapolated from a quiescence that had been reported and then ended.
    const still = runSampler(&b, &s, worker, 0, 4 * std.time.ms_per_min, false);
    try testing.expect(still[0] >= 3 * std.time.ms_per_min);
    try testing.expect(b.quietMs(worker, still[1]) >= 3 * std.time.ms_per_min);

    // Half an hour of work, one screen change a second.
    const working = runSampler(&b, &s, worker, still[1], 30 * std.time.ms_per_min, true);

    // One sample interval, one heartbeat interval, and a second of slack.
    try testing.expect(working[0] <= 7000);

    // And it is not merely small at the end: the figure stopped climbing.
    // A number sampled once cannot tell a healthy terminal from a stuck
    // one -- it is whether it keeps growing that says which.
    try testing.expect(b.quietMs(worker, working[1]) <= 7000);
}

test "letting a terminal go stops measuring it rather than extrapolating" {
    // Nothing samples a terminal nobody is minding, so the last figure it
    // had stops being a measurement the moment it is released. It used to
    // go on being extended by the time since, which is time nobody looked.
    var b = testBus();
    defer b.deinit();
    try b.addSupervisor(boss);
    try b.watch(worker, boss);

    _ = b.report(worker, quiet(180_000), 180_000);
    try testing.expect(b.observed(worker));
    try testing.expectEqual(@as(u64, 240_000), b.quietMs(worker, 240_000));

    b.unwatch(worker);
    try testing.expect(!b.observed(worker));
    try testing.expectEqual(@as(u64, 0), b.quietMs(worker, 10 * std.time.ms_per_hour));
}

test "the worker-mentions switch is the user's, a supervisor's, and dies with the role" {
    var b: Bus = .init(testing.allocator, .{});
    defer b.deinit();
    try b.addSupervisor(0x1);
    try b.watch(0x2, 0x1);

    // Off until somebody says otherwise.
    try testing.expect(!b.workerMentions(0x1));

    // Not an agent's to grant: it widens what one worker may do to another.
    try testing.expectError(error.NotPermitted, b.setWorkerMentions(0x1, true, .supervisor));
    // Not a worker's switch at all.
    try testing.expectError(error.NotASupervisor, b.setWorkerMentions(0x2, true, .user));

    try b.setWorkerMentions(0x1, true, .user);
    try testing.expect(b.workerMentions(0x1));
    try testing.expectEqual(@as(?Id, 0x1), b.minderOf(0x2));

    // Standing down takes it with it: a terminal made supervisor again
    // starts with it off rather than inheriting a "yes" from last time.
    b.removeSupervisor(0x1);
    try testing.expect(!b.workerMentions(0x1));
    try b.addSupervisor(0x1);
    try testing.expect(!b.workerMentions(0x1));
}

// -- the call-silence clock ---------------------------------------------------

/// A third terminal beside `worker`, for the control that must stay quiet.
const busy: Id = 0x3333;

/// Run the bus from `from_ms` to `to_ms` the way the app does while screens
/// are moving: every five seconds each of `moving` restates a small quiet
/// time (`noteQuiet`, the heartbeat), and the call clock is looked at.
/// `busy`, if it is among them, also calls a tool every five minutes.
fn runMoving(b: *Bus, moving: []const Id, from_ms: u64, to_ms: u64) void {
    var t = from_ms;
    while (t <= to_ms) : (t += 5 * std.time.ms_per_s) {
        for (moving) |id| {
            b.noteQuiet(id, 3 * std.time.ms_per_s, t);
            if (id == busy and t % (5 * std.time.ms_per_min) == 0) b.noteCall(id, t);
        }
        _ = b.considerCalls(t);
    }
}

test "a moving screen with no tool call reaches the supervisor; one that keeps calling does not" {
    // The night this was written: a worker's CLI hit ENOTFOUND and sat
    // retrying, its screen never still, and the supervisor was told nothing
    // for most of an hour. Both terminals here have screens that never stop
    // -- neither is ever reported quiet -- and only the calls differ.
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    try b.watch(busy, boss);
    b.noteCall(worker, 0);
    b.noteCall(busy, 0);

    runMoving(&b, &.{ worker, busy }, 0, 16 * std.time.ms_per_min);

    var buf: [255]u8 = undefined;
    const line = b.drain(boss, 16 * std.time.ms_per_min, &buf, .none) orelse
        return error.TestExpectedNotice;

    // The positive control, as the words the supervisor reads.
    try testing.expect(std.mem.indexOf(
        u8,
        line,
        "0x0000000000002222 no tool call 16m (screen changed 3s ago)",
    ) != null);

    // The negative control: the terminal that kept calling is not named.
    // Without this, "reports everybody" and "reports the right one" read
    // the same.
    try testing.expect(std.mem.indexOf(u8, line, "3333") == null);

    // And it came from the calls, not the screen: nothing here was ever
    // still long enough to be a quiet report.
    try testing.expect(std.mem.indexOf(u8, line, " quiet ") == null);
}

test "a terminal that has never called a tool is not reported as silent" {
    // A plain shell under watch, or an agent that never started. Never
    // having called is "not known", not "a long time ago".
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    try b.watch(busy, boss);
    b.noteCall(busy, 0);

    // `busy` called once and then stopped, so the box has something true
    // in it and the assertion about `worker` is not about an empty box.
    runMoving(&b, &.{worker}, 0, 60 * std.time.ms_per_min);

    try testing.expect(b.callSilentMs(worker, 60 * std.time.ms_per_min) == null);
    var buf: [255]u8 = undefined;
    const line = b.drain(boss, 60 * std.time.ms_per_min, &buf, .none) orelse
        return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, line, "3333 no tool call 60m") != null);
    try testing.expect(std.mem.indexOf(u8, line, "2222") == null);
}

test "a threshold of zero says nothing about calls, in the box or on the tab" {
    var b: Bus = .init(testing.allocator, .{ .calls_silent_after_ms = 0 });
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    b.noteCall(worker, 0);
    b.noteCall(boss, 0);

    runMoving(&b, &.{worker}, 0, 3 * 60 * std.time.ms_per_min);

    var buf: [255]u8 = undefined;
    try testing.expect(b.drain(boss, 3 * 60 * std.time.ms_per_min, &buf, .none) == null);
    try testing.expectEqual(
        TabMark.supervisor,
        b.tabMark(boss, 3 * 60 * std.time.ms_per_min, 1000),
    );
}

test "the silence is said again a threshold later, and a call ends it" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    b.noteCall(worker, 0);

    var buf: [255]u8 = undefined;

    runMoving(&b, &.{worker}, 0, 15 * std.time.ms_per_min);
    const first = b.drain(boss, 15 * std.time.ms_per_min, &buf, .none) orelse
        return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, first, "2222 no tool call 15m") != null);

    // Read, and nothing new until another whole threshold has passed.
    runMoving(&b, &.{worker}, 15 * std.time.ms_per_min + 5000, 29 * std.time.ms_per_min);
    try testing.expect(b.drain(boss, 29 * std.time.ms_per_min, &buf, .none) == null);

    runMoving(&b, &.{worker}, 29 * std.time.ms_per_min + 5000, 30 * std.time.ms_per_min);
    const second = b.drain(boss, 30 * std.time.ms_per_min, &buf, .none) orelse
        return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, second, "2222 no tool call 30m") != null);

    // A line that is waiting when a call arrives is no longer true, and
    // goes; the clock starts from the call.
    runMoving(&b, &.{worker}, 30 * std.time.ms_per_min + 5000, 45 * std.time.ms_per_min);
    b.noteCall(worker, 45 * std.time.ms_per_min);
    try testing.expect(b.drain(boss, 45 * std.time.ms_per_min, &buf, .none) == null);

    runMoving(&b, &.{worker}, 45 * std.time.ms_per_min, 60 * std.time.ms_per_min);
    const third = b.drain(boss, 60 * std.time.ms_per_min, &buf, .none) orelse
        return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, third, "2222 no tool call 15m") != null);
}

test "a clocked off terminal is not reported for not calling" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    try b.watch(busy, boss);
    b.noteCall(worker, 0);
    b.noteCall(busy, 0);
    try b.clockOff(worker, .supervisor);

    runMoving(&b, &.{}, 0, 20 * std.time.ms_per_min);

    var buf: [255]u8 = undefined;
    const line = b.drain(boss, 20 * std.time.ms_per_min, &buf, .none) orelse
        return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, line, "3333 no tool call 20m") != null);
    try testing.expect(std.mem.indexOf(u8, line, "2222") == null);
}

test "a silent supervisor's flag goes hollow, and a call fills it again" {
    // Its own box is the one place this cannot go: a stuck supervisor is
    // the one terminal that would not read it.
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    b.noteCall(boss, 0);

    const t15 = 15 * std.time.ms_per_min;
    try testing.expectEqual(TabMark.supervisor, b.tabMark(boss, t15 - 1, 1000));
    try testing.expectEqual(TabMark.supervisor_silent, b.tabMark(boss, t15, 1000));

    // And not in its own box, where nobody would see it.
    _ = b.considerCalls(t15);
    var buf: [255]u8 = undefined;
    try testing.expect(b.drain(boss, t15, &buf, .none) == null);

    b.noteCall(boss, t15 + 1000);
    try testing.expectEqual(TabMark.supervisor, b.tabMark(boss, t15 + 1000, 1000));
}

test "a supervisor that has never called keeps its flag" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try testing.expectEqual(
        TabMark.supervisor,
        b.tabMark(boss, 10 * 60 * std.time.ms_per_min, 1000),
    );
}

// -- agent hooks (adapters.md 3.4) ------------------------------------------

fn hookEv(kind: AgentEvent.Kind) AgentEvent.Event {
    var ev: AgentEvent.Event = .none;
    ev.event = kind;
    ev.cli = "claude-code";
    ev.session_id = "sess-1";
    return ev;
}

fn hookedBus() !Bus {
    var b = testBus();
    errdefer b.deinit();
    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    return b;
}

test "hooks: a launcher that says its CLI did not start takes back what it said to expect, and says so (task 1667)" {
    var b = try hookedBus();
    defer b.deinit();

    // `+launch` said hooks were coming, then could not start the CLI.
    _ = try b.agentEvent(worker, hookEv(.hooks_expected), 0);
    try testing.expectEqual(Hooks.expected, b.agentOf(worker).hooks);
    var failed = hookEv(.launch_failed);
    failed.detail = "not_found";
    const boxed = try b.agentEvent(worker, failed, 500);
    const after = b.agentOf(worker).hooks;
    try testing.expectEqual(Hooks.none, after);

    // So the thirty seconds never run out on it: nothing is said about
    // hooks that did not come, because none were promised any more.
    const said = b.considerAgents(10 * hooks_expected_timeout_ms);
    try testing.expect(!said);

    // **What is said is that the launch failed, once, to whoever watches
    // it** (task 1667). It used to be nothing at all.
    try testing.expect(boxed);
    var buf: [255]u8 = undefined;
    const line = b.drain(boss, 10 * hooks_expected_timeout_ms, &buf, .none) orelse return error.TestUnexpectedResult;
    const told = std.mem.indexOf(u8, line, "launch failed") != null;
    try testing.expect(told);
    const why = std.mem.indexOf(u8, line, "(not_found)") != null;
    try testing.expect(why);
    const no_silence = std.mem.indexOf(u8, line, "hooks expected") == null;
    try testing.expect(no_silence);
    const again = b.drain(boss, 11 * hooks_expected_timeout_ms, &buf, .none);
    try testing.expect(again == null);

    // A terminal the bus has never heard of is not given an entry for
    // having failed to start something.
    const unknown: Id = 0xdead;
    _ = try b.agentEvent(unknown, hookEv(.launch_failed), 600);
    const listed = b.entries.contains(unknown);
    try testing.expect(!listed);

    // And an agent that has spoken is there, whatever a launch line typed
    // at it afterwards came to.
    _ = try b.agentEvent(worker, hookEv(.session_started), 700);
    const on_live = try b.agentEvent(worker, hookEv(.launch_failed), 800);
    const live = b.agentOf(worker).hooks;
    try testing.expectEqual(Hooks.live, live);
    try testing.expect(!on_live);
}

test "hooks: a launch that failed is told to the supervisor that ran it, watched or not (task 1667)" {
    var b = try hookedBus();
    defer b.deinit();
    const second: Id = 0xb0552;
    try b.addSupervisor(second);
    // Started by `boss` through `role_launch`; the role's watch waits for an
    // agent that never comes, so nobody watches it.
    const fresh: Id = 0xf2e5;
    var failed = hookEv(.launch_failed);
    failed.detail = "not_found";
    const by_watch = try b.agentEvent(fresh, failed, 100);
    try testing.expect(!by_watch);
    const told = try b.tellLaunchFailed(fresh, boss, "not_found", null, 100);
    try testing.expect(told);

    var buf: [255]u8 = undefined;
    // The other supervisor does not hear about a launch it did not run.
    const not_theirs = b.drain(second, 200, &buf, .none);
    const second_heard = not_theirs != null and std.mem.indexOf(u8, not_theirs.?, "launch failed") != null;
    try testing.expect(!second_heard);
    const line = b.drain(boss, 200, &buf, .none) orelse return error.TestUnexpectedResult;
    const boss_heard = std.mem.indexOf(u8, line, "launch failed") != null;
    try testing.expect(boss_heard);

    // A later launch that fails is said again once what was said has gone
    // out; while it is still in the box it is not said twice. A launch the
    // person ran is not a supervisor's to hear about.
    const again = try b.tellLaunchFailed(fresh, boss, "not_found", null, 300);
    try testing.expect(again);
    try testing.expect(!(try b.tellLaunchFailed(fresh, boss, "not_found", null, 301)));
    const by_person = try b.tellLaunchFailed(0xf2e6, 0x1, "failed", null, 400);
    try testing.expect(!by_person);
}

test "hooks: a launch that failed in a terminal nobody watches is not put in the box (task 1667)" {
    var b = try hookedBus();
    defer b.deinit();
    // Known to the bus, watched by nobody.
    const loose: Id = 0x10ce;
    _ = try b.agentEvent(loose, hookEv(.hooks_expected), 0);
    const boxed = try b.agentEvent(loose, hookEv(.launch_failed), 10);
    try testing.expect(!boxed);
}

/// `present` for `launchWithNoAgent`, as the two answers a test needs.
const Presence = struct {
    var ctx: u8 = 0;
    fn yes(_: *anyopaque, _: Id) bool {
        return true;
    }
    fn no(_: *anyopaque, _: Id) bool {
        return false;
    }
};

/// A `hooks_expected` from a CLI whose hooks wait for its first turn
/// (Codex): the case with no thirty seconds running behind it.
fn firstTurnExpected() AgentEvent.Event {
    var ev = hookEv(.hooks_expected);
    ev.detail = AgentEvent.hooksExpectedDetail(true);
    return ev;
}

test "hooks: a CLI gone at once says its exit code to whoever watches it (task 1712)" {
    var b = try hookedBus();
    defer b.deinit();

    _ = try b.agentEvent(worker, firstTurnExpected(), 0);
    // Nothing has connected: its going is the launch failing.
    const counts = b.launchExitIsFailure(worker);
    try testing.expect(counts);

    var exited = hookEv(.launch_failed);
    exited.detail = "exited";
    exited.note = "exit code 2 after 0.3 s";
    const boxed = try b.agentEvent(worker, exited, 400);
    try testing.expect(boxed);
    const hooks = b.agentOf(worker).hooks;
    try testing.expectEqual(Hooks.none, hooks);

    var buf: [255]u8 = undefined;
    const line = b.drain(boss, 1_000, &buf, .none) orelse return error.TestUnexpectedResult;
    const failed = std.mem.indexOf(u8, line, "launch failed") != null;
    try testing.expect(failed);
    const code = std.mem.indexOf(u8, line, "(exited: exit code 2 after 0.3 s)") != null;
    try testing.expect(code);

    // And to the supervisor that ran it, when nobody watches it.
    const loose: Id = 0x10cf;
    _ = try b.agentEvent(loose, firstTurnExpected(), 0);
    _ = try b.agentEvent(loose, exited, 400);
    const told = try b.tellLaunchFailed(loose, boss, "exited", "exit code 2 after 0.3 s", 400);
    try testing.expect(told);
    const line2 = b.drain(boss, 1_000, &buf, .none) orelse return error.TestUnexpectedResult;
    const code2 = std.mem.indexOf(u8, line2, "exit code 2") != null;
    try testing.expect(code2);
}

test "hooks: a launch no agent came from is said to have failed at the minute, once (task 1712)" {
    var b = try hookedBus();
    defer b.deinit();

    // Started, and nothing ever connects -- a CLI that hangs before Polter
    // hears from it, or one that exited where `+launch` could not see.
    _ = try b.agentEvent(worker, firstTurnExpected(), 0);
    const early = b.launchWithNoAgent(launch_agent_wait_ms - 1, &Presence.ctx, Presence.no);
    try testing.expect(early == null);
    const due = b.launchWithNoAgent(launch_agent_wait_ms, &Presence.ctx, Presence.no);
    try testing.expectEqual(@as(?Id, worker), due);

    // Said the way `+launch` says a failure, it is answered: once.
    var none = hookEv(.launch_failed);
    none.detail = "no_agent";
    const boxed = try b.agentEvent(worker, none, launch_agent_wait_ms);
    try testing.expect(boxed);
    const again = b.launchWithNoAgent(2 * launch_agent_wait_ms, &Presence.ctx, Presence.no);
    try testing.expect(again == null);

    var buf: [255]u8 = undefined;
    const line = b.drain(boss, launch_agent_wait_ms + 1, &buf, .none) orelse return error.TestUnexpectedResult;
    const said = std.mem.indexOf(u8, line, "no agent connected within 60s of the launch") != null;
    try testing.expect(said);
    // Not "at its shell": that is not known of a CLI that may still run.
    const no_shell_claim = std.mem.indexOf(u8, line, "at its shell") == null;
    try testing.expect(no_shell_claim);
}

test "hooks: a launch whose CLI is asking the person something is not said to have failed (task 1746)" {
    var b = try hookedBus();
    defer b.deinit();

    _ = try b.agentEvent(worker, firstTurnExpected(), 0);
    // The trust box is seen up at 50 s and at 100 s: the minute runs from
    // the last sighting.
    const held = b.holdLaunch(worker, 50_000);
    try testing.expect(held);
    _ = b.holdLaunch(worker, 100_000);
    const at_old_minute = b.launchWithNoAgent(launch_agent_wait_ms, &Presence.ctx, Presence.no);
    try testing.expect(at_old_minute == null);
    const before = b.launchWithNoAgent(100_000 + launch_agent_wait_ms - 1, &Presence.ctx, Presence.no);
    try testing.expect(before == null);
    const due = b.launchWithNoAgent(100_000 + launch_agent_wait_ms, &Presence.ctx, Presence.no);
    try testing.expectEqual(@as(?Id, worker), due);

    // No launch waiting: nothing to hold.
    const loose: Id = 0x10d0;
    try testing.expect(!b.holdLaunch(loose, 1_000));
}

test "hooks: a launch whose CLI asks the person a question says so, to the supervisor that launched it (task 1746)" {
    var b = try hookedBus();
    defer b.deinit();
    // Launched by `boss` (role_launch), not watched yet: its agent has not
    // connected, so its standing is still held.
    const fresh_one: Id = 0x10d1;
    _ = try b.agentEvent(fresh_one, firstTurnExpected(), 0);
    const boxed = b.noteStartupQuestion(fresh_one, "Do you trust the contents of this project?", boss, 1_000);
    try testing.expect(boxed);
    const a = b.agentOf(fresh_one);
    try testing.expectEqual(AgentState.awaiting_input, a.state);
    try testing.expectEqual(SaidBy.screen, a.said_by);
    try testing.expectEqualStrings("startup_question", a.detail.get().?);
    const known = a.known();
    try testing.expect(known);
    // Said once.
    const again = b.noteStartupQuestion(fresh_one, "Do you trust the contents of this project?", boss, 2_000);
    try testing.expect(!again);

    var buf: [255]u8 = undefined;
    const line = b.drain(boss, 2_000, &buf, .none) orelse return error.TestUnexpectedResult;
    const said = std.mem.indexOf(u8, line, "waiting for the person") != null and
        std.mem.indexOf(u8, line, "Do you trust") != null;
    try testing.expect(said);

    // Answered: the state goes back.
    _ = b.noteStartupQuestion(fresh_one, null, boss, 3_000);
    const after = b.agentOf(fresh_one);
    try testing.expectEqual(AgentState.idle, after.state);
    try testing.expectEqual(SaidBy.hooks, after.said_by);

    // An agent whose hooks speak says for itself.
    var live = hookEv(.session_started);
    live.session_id = "s";
    _ = try b.agentEvent(worker, live, 4_000);
    const spoke = b.noteStartupQuestion(worker, "Do you trust the contents of this project?", boss, 5_000);
    try testing.expect(!spoke);
}

test "hooks: an agent that connected is never a launch with no agent, watched or not (task 1712)" {
    var b = try hookedBus();
    defer b.deinit();

    // Nobody watches it, so `noteAgentHere` never runs for it: its agent
    // is seen by being asked about.
    const loose: Id = 0x10d0;
    _ = try b.agentEvent(loose, firstTurnExpected(), 0);
    const seen = b.launchWithNoAgent(10_000, &Presence.ctx, Presence.yes);
    try testing.expect(seen == null);
    // Gone again (`/exit` before a first turn): it still came.
    const later = b.launchWithNoAgent(2 * launch_agent_wait_ms, &Presence.ctx, Presence.no);
    try testing.expect(later == null);
    const exit_counts = b.launchExitIsFailure(loose);
    try testing.expect(!exit_counts);

    // A watched one, seen by `noteAgentHere`, the same.
    _ = try b.agentEvent(worker, firstTurnExpected(), 0);
    b.noteAgentHere(worker, true, null, 5_000);
    const watched = b.launchWithNoAgent(2 * launch_agent_wait_ms, &Presence.ctx, Presence.no);
    try testing.expect(watched == null);
}

test "hooks: expected with no session_started for 30s is put in the box" {
    var b = try hookedBus();
    defer b.deinit();

    _ = try b.agentEvent(worker, hookEv(.hooks_expected), 0);
    try testing.expectEqual(Hooks.expected, b.agentOf(worker).hooks);

    try testing.expect(!b.considerAgents(hooks_expected_timeout_ms - 1));
    var buf: [255]u8 = undefined;
    try testing.expect(b.drain(boss, hooks_expected_timeout_ms - 1, &buf, .none) == null);

    try testing.expect(b.considerAgents(hooks_expected_timeout_ms));
    const line = b.drain(boss, hooks_expected_timeout_ms, &buf, .none) orelse
        return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, line, "0x0000000000002222 hooks expected 30s ago") != null);

    // Said once per wait, not every tick after.
    try testing.expect(!b.considerAgents(10 * hooks_expected_timeout_ms));
}

test "1668: hooks heard at the first turn wait for a line, then for 30s from it" {
    var b = try hookedBus();
    defer b.deinit();

    var ev = hookEv(.hooks_expected);
    ev.cli = "codex";
    ev.detail = AgentEvent.hooksExpectedDetail(true);
    _ = try b.agentEvent(worker, ev, 0);
    try testing.expectEqual(Hooks.expected, b.agentOf(worker).hooks);
    try testing.expect(b.agentOf(worker).expected_ms == null);

    // Sitting at its prompt with nobody typing is not hooks gone missing,
    // however long it lasts.
    try testing.expect(!b.considerAgents(10 * hooks_expected_timeout_ms));

    // The first line starts the wait; a second does not start it again.
    const typed: u64 = 10 * hooks_expected_timeout_ms;
    b.noteLineSubmitted(worker, typed);
    b.noteLineSubmitted(worker, typed + 5_000);
    try testing.expectEqual(@as(?u64, typed), b.agentOf(worker).expected_ms);

    try testing.expect(!b.considerAgents(typed + hooks_expected_timeout_ms - 1));
    try testing.expect(b.considerAgents(typed + hooks_expected_timeout_ms));
    var buf: [255]u8 = undefined;
    const line = b.drain(boss, typed + hooks_expected_timeout_ms, &buf, .none) orelse
        return error.TestExpectedNotice;
    // Counted from the line, not from the launch five minutes before it.
    try testing.expect(std.mem.indexOf(u8, line, "0x0000000000002222 hooks expected 30s ago") != null);
}

test "1668: a command to the CLI is not a line that starts a turn" {
    try testing.expect(slashCommandLine("› /exit"));
    try testing.expect(slashCommandLine("  ❯ /clear"));
    try testing.expect(slashCommandLine("/model gpt-5.6-luna"));
    try testing.expect(!slashCommandLine("› Call the polter MCP tool named me"));
    // A path is said to the agent, not to the CLI.
    try testing.expect(!slashCommandLine("› /Users/me/notes.md summarise this"));
    try testing.expect(!slashCommandLine(""));
    try testing.expect(!slashCommandLine("› /"));
    try testing.expect(!slashCommandLine("› / exit"));
}

test "1668: the wait for a first turn ends when the agent goes, before or after a line" {
    var b = try hookedBus();
    defer b.deinit();
    var ev = hookEv(.hooks_expected);
    ev.cli = "codex";
    ev.detail = AgentEvent.hooksExpectedDetail(true);

    // Its connection came and went: it exited (`/exit`) with nothing said.
    _ = try b.agentEvent(worker, ev, 0);
    try testing.expect(b.waitsForFirstLine(worker));
    b.noteAgentHere(worker, true, .{ .pid = 77, .started = 500 }, 1_000);
    b.noteLineSubmitted(worker, 2_000);
    b.noteAgentHere(worker, false, null, 3_000);
    try testing.expectEqual(Hooks.none, b.agentOf(worker).hooks);
    try testing.expect(!b.considerAgents(10 * hooks_expected_timeout_ms));

    // Its program ended.
    _ = try b.agentEvent(worker, ev, 20_000);
    b.noteLeft(worker, .failed, 21_000);
    try testing.expectEqual(Hooks.none, b.agentOf(worker).hooks);
    try testing.expect(!b.waitsForFirstLine(worker));

    // A live agent's connection going says nothing about its hooks.
    _ = try b.agentEvent(worker, hookEv(.session_started), 30_000);
    b.noteAgentHere(worker, true, .{ .pid = 77, .started = 500 }, 31_000);
    b.noteAgentHere(worker, false, null, 32_000);
    try testing.expectEqual(Hooks.live, b.agentOf(worker).hooks);
}

test "1668: a line in a terminal whose hooks are heard at startup, or are live, changes nothing" {
    var b = try hookedBus();
    defer b.deinit();

    _ = try b.agentEvent(worker, hookEv(.hooks_expected), 1_000);
    b.noteLineSubmitted(worker, 20_000);
    try testing.expectEqual(@as(?u64, 1_000), b.agentOf(worker).expected_ms);

    _ = try b.agentEvent(worker, hookEv(.session_started), 21_000);
    const live = b.agentOf(worker).*;
    b.noteLineSubmitted(worker, 22_000);
    try testing.expectEqual(live.expected_ms, b.agentOf(worker).expected_ms);
    try testing.expectEqual(Hooks.live, b.agentOf(worker).hooks);

    // And a terminal the bus has never heard of is not made one.
    b.noteLineSubmitted(0x9999, 22_000);
    try testing.expect(b.get(0x9999) == null);
}

test "hooks: session_started in time means nothing is ever said about the wait" {
    var b = try hookedBus();
    defer b.deinit();

    _ = try b.agentEvent(worker, hookEv(.hooks_expected), 0);
    _ = try b.agentEvent(worker, hookEv(.session_started), 5_000);
    try testing.expectEqual(Hooks.live, b.agentOf(worker).hooks);

    try testing.expect(!b.considerAgents(10 * hooks_expected_timeout_ms));
    var buf: [255]u8 = undefined;
    try testing.expect(b.drain(boss, 10 * hooks_expected_timeout_ms, &buf, .none) == null);
}

test "hooks: a wait reported and then answered before anyone read it is taken back" {
    var b = try hookedBus();
    defer b.deinit();

    _ = try b.agentEvent(worker, hookEv(.hooks_expected), 0);
    try testing.expect(b.considerAgents(hooks_expected_timeout_ms));
    _ = try b.agentEvent(worker, hookEv(.session_started), hooks_expected_timeout_ms + 1);

    var buf: [255]u8 = undefined;
    try testing.expect(b.drain(boss, hooks_expected_timeout_ms + 2, &buf, .none) == null);
}

test "hooks: turn ended goes in the box with the start of the answer" {
    var b = try hookedBus();
    defer b.deinit();

    var ev = hookEv(.turn_ended);
    ev.text = "已修好 #845，全量 104/104\nsecond line";
    ev.text_bytes = ev.text.?.len;
    try testing.expect(try b.agentEvent(worker, ev, 1_000));

    var buf: [255]u8 = undefined;
    const line = b.drain(boss, 13_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expectEqualStrings(
        "[poltergeist] 0x0000000000002222 turn ended 12s ago: \"已修好 #845，全量 104/104 second line\"",
        line,
    );
}

test "hooks: an answer longer than the line is cut on a character boundary and says so" {
    var b = try hookedBus();
    defer b.deinit();

    // 120 characters of three bytes each: far more than a 255-byte line
    // has room for after the id.
    var text: [360]u8 = undefined;
    for (0..120) |i| @memcpy(text[i * 3 ..][0..3], "中");
    var ev = hookEv(.turn_ended);
    ev.text = &text;
    ev.text_bytes = text.len;
    _ = try b.agentEvent(worker, ev, 0);

    var buf: [255]u8 = undefined;
    const line = b.drain(boss, 0, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(line.len <= buf.len);
    try testing.expect(std.unicode.utf8ValidateSlice(line));
    try testing.expect(std.mem.endsWith(u8, line, "\u{2026}\""));
    try testing.expect(std.mem.indexOf(u8, line, "turn ended 0s ago: \"中中") != null);
}

test "hooks: failed and awaiting approval read as themselves" {
    var b = try hookedBus();
    defer b.deinit();

    var failed = hookEv(.turn_failed);
    failed.detail = "rate_limit";
    _ = try b.agentEvent(worker, failed, 0);
    var buf: [255]u8 = undefined;
    const one = b.drain(boss, 0, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expectEqualStrings("[poltergeist] 0x0000000000002222 failed rate_limit", one);

    var ask = hookEv(.awaiting_approval);
    ask.detail = "Bash";
    ask.note = "zig build test";
    _ = try b.agentEvent(worker, ask, 0);
    const two = b.drain(boss, 0, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expectEqualStrings(
        "[poltergeist] 0x0000000000002222 awaiting approval Bash [state_at_ms=0 event_at_ms=0 answer=allowed]: zig build test",
        two,
    );
}

test "hooks: a worker stopped on a question is handed over at once, inside the interval, and on its own" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;

    // The supervisor has just been handed something, so the interval has a
    // minute to run.
    _ = b.report(worker, quiet(60_000), 0);
    _ = b.drainIfDue(boss, 0, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(b.drainIfDue(boss, 1_000, &buf, .none) == null);

    // Another quiet report, five seconds in: held for the interval, as ever.
    _ = b.report(worker, quiet(65_000), 5_000);
    try testing.expect(b.drainIfDue(boss, 5_000, &buf, .none) == null);

    // Then the worker stops on an approval, ten seconds in.
    var ask = hookEv(.awaiting_approval);
    ask.detail = "Bash";
    ask.note = "rm -rf dist";
    _ = try b.agentEvent(worker, ask, 10_000);
    try testing.expect(b.hasFreshWaiting(boss, .none));
    const line = b.drainIfDue(boss, 10_000, &buf, .none) orelse return error.TestExpectedNotice;
    // The two moments are the ones `promptStanding` holds a later answer
    // to, under the names `terminal_answer_prompt` takes them by.
    try testing.expectEqualStrings(
        "[poltergeist] 0x0000000000002222 awaiting approval Bash [state_at_ms=10000 event_at_ms=10000 answer=allowed]: rm -rf dist",
        line,
    );
    try testing.expect(b.promptStanding(worker, 10_000, 10_000, 10_000, null));

    // Handed once: it does not come again a second later.
    try testing.expect(!b.hasFreshWaiting(boss, .none));
    try testing.expect(b.drainIfDue(boss, 11_000, &buf, .none) == null);

    // And it neither spent nor reset the interval: the scheduled box comes
    // due a minute after the first hand-over, as it would have. **The
    // approval is not in it**: that went out fifty seconds ago, and saying
    // it again now would be the same sentence twice inside one interval.
    // (The quiet report is not in it either -- the prompt explains the
    // stillness -- so there is nothing to hand over and nobody is
    // interrupted.)
    try testing.expect(b.drainIfDue(boss, 59_000, &buf, .none) == null);
    try testing.expect(b.drainIfDue(boss, 60_000, &buf, .none) == null);

    // Its repeat comes a whole interval after it was first said: still
    // waiting, still nobody has answered.
    try testing.expect(b.drainIfDue(boss, 69_000, &buf, .none) == null);
    const repeat = b.drainIfDue(boss, 70_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, repeat, "awaiting approval") != null);
}

test "notice delivery: a waiting notice handed over a moment ago is not said again by the box that comes due right after" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;

    // The interval has all but run out when the worker stops on a prompt.
    _ = b.report(worker, quiet(60_000), 0);
    _ = b.drainIfDue(boss, 0, &buf, .none) orelse return error.TestExpectedNotice;
    var ask = hookEv(.awaiting_approval);
    ask.detail = "Bash";
    _ = try b.agentEvent(worker, ask, 58_000);
    const first = b.drainIfDue(boss, 58_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, first, "awaiting approval Bash") != null);

    // Two seconds later the scheduled box is due. There is nothing else in
    // it, so nothing is typed at all -- not the same line a second time.
    try testing.expect(b.drainIfDue(boss, 60_000, &buf, .none) == null);
    try testing.expect(b.drainIfDue(boss, 61_000, &buf, .none) == null);

    // It is not lost: an interval after it was said, it is said again.
    const again = b.drainIfDue(boss, 118_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, again, "awaiting approval Bash") != null);

    // A supervisor that asks for its box is never held back by this. (A
    // second prompt: the same one said again is not news, task 1503.)
    var next = hookEv(.awaiting_approval);
    next.detail = "Write";
    _ = try b.agentEvent(worker, next, 200_000);
    _ = b.drainIfDue(boss, 200_000, &buf, .none) orelse return error.TestExpectedNotice;
    const asked = b.drain(boss, 200_500, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, asked, "awaiting approval Write") != null);
}

test "hooks: waiting for an answer is urgent too, and a turn that merely ended is not" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;
    _ = b.report(worker, quiet(60_000), 0);
    _ = b.drainIfDue(boss, 0, &buf, .none) orelse return error.TestExpectedNotice;

    _ = try b.agentEvent(worker, hookEv(.turn_started), 1_000);
    var done = hookEv(.turn_ended);
    done.text = "done";
    done.text_bytes = 4;
    _ = try b.agentEvent(worker, done, 2_000);
    try testing.expect(!b.hasFreshWaiting(boss, .none));
    try testing.expect(b.drainIfDue(boss, 2_000, &buf, .none) == null);

    var asks = hookEv(.awaiting_input);
    asks.detail = "which branch?";
    _ = try b.agentEvent(worker, asks, 3_000);
    const line = b.drainIfDue(boss, 3_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expectEqualStrings("[poltergeist] 0x0000000000002222 awaiting input which branch?", line);
}

fn toolDone(tool: []const u8) AgentEvent.Event {
    var ev = hookEv(.turn_resumed);
    ev.detail = tool;
    return ev;
}

test "hooks: an approval answered, then the tool finishing, is back in the turn and off the board (task 1561)" {
    var b = try hookedBus();
    defer b.deinit();
    _ = try b.agentEvent(worker, hookEv(.turn_started), 1_000);
    var ask = hookEv(.awaiting_approval);
    ask.detail = "Bash";
    ask.note = "zig build test";
    ask.text = "zig build test";
    ask.text_bytes = 14;
    _ = try b.agentEvent(worker, ask, 2_000);
    try testing.expect(b.askOf(worker) != null);
    try testing.expectEqual(AgentNotice.awaiting_approval, b.agentOf(worker).pending.?);

    // Approved; the command ran and its `PostToolUse` is heard.
    const boxed = try b.agentEvent(worker, toolDone("Bash"), 900_000);
    try testing.expect(!boxed);
    const a = b.agentOf(worker).*;
    try testing.expectEqual(AgentState.in_turn, a.state);
    try testing.expectEqual(@as(u64, 900_000), a.since_ms);
    // What was to be approved, and the line saying so, are gone with it.
    try testing.expect(b.askOf(worker) == null);
    try testing.expect(a.pending == null);
    try testing.expect(!b.promptStanding(worker, 2_000, 2_000, 900_000, null));

    // And the next tool call inside the same turn is not a new state.
    _ = try b.agentEvent(worker, toolDone("Read"), 950_000);
    try testing.expectEqual(@as(u64, 900_000), b.agentOf(worker).since_ms);
}

test "hooks: a question answered inside the turn resumes it on the next tool call, whichever tool" {
    var b = try hookedBus();
    defer b.deinit();
    _ = try b.agentEvent(worker, hookEv(.turn_started), 1_000);
    var asks = hookEv(.awaiting_input);
    asks.detail = "elicitation_dialog";
    asks.text = "which branch?";
    asks.text_bytes = 13;
    _ = try b.agentEvent(worker, asks, 2_000);
    try testing.expectEqual(AgentState.awaiting_input, b.agentOf(worker).state);

    _ = try b.agentEvent(worker, toolDone("mcp__tracker__create_issue"), 60_000);
    const a = b.agentOf(worker).*;
    try testing.expectEqual(AgentState.in_turn, a.state);
    try testing.expect(a.pending == null);
    try testing.expect(b.askOf(worker) == null);
}

test "hooks: a tool call finishing moves nobody who was not waiting" {
    var b = try hookedBus();
    defer b.deinit();

    // Never heard from: not even registered by it.
    const stranger: Id = 0x7777;
    try testing.expect(!try b.agentEvent(stranger, toolDone("Read"), 500));
    try testing.expect(b.get(stranger) == null);

    // Idle (a session, no turn yet), ended, failed, and sitting at the
    // prompt after a turn (`idle_prompt` is `awaiting_input` too): each
    // stays exactly as it was, clocks and all.
    const Case = struct { setup: []const AgentEvent.Kind, detail: ?[]const u8 };
    const cases = [_]Case{
        .{ .setup = &.{.session_started}, .detail = null },
        .{ .setup = &.{ .turn_started, .turn_ended }, .detail = null },
        .{ .setup = &.{ .turn_started, .turn_failed }, .detail = "rate_limit" },
        .{ .setup = &.{ .turn_started, .turn_ended, .awaiting_input }, .detail = idle_prompt },
    };
    for (cases) |c| {
        var t = try hookedBus();
        defer t.deinit();
        for (c.setup, 0..) |kind, i| {
            var ev = hookEv(kind);
            ev.detail = c.detail;
            _ = try t.agentEvent(worker, ev, 1_000 * (i + 1));
        }
        const before = t.agentOf(worker).*;
        const pending = t.get(worker).?.agent.pending;
        try testing.expect(!try t.agentEvent(worker, toolDone("Read"), 500_000));
        const after = t.agentOf(worker).*;
        try testing.expectEqual(before.state, after.state);
        try testing.expectEqual(before.since_ms, after.since_ms);
        try testing.expectEqual(before.last_event_ms, after.last_event_ms);
        try testing.expectEqualStrings(before.detail.get() orelse "", after.detail.get() orelse "");
        try testing.expectEqual(pending, t.get(worker).?.agent.pending);
    }
}

test "hooks: a subagent's tool finishing does not take the main agent's approval off the board" {
    // `PostToolUse` fires inside subagents too, and one running in the
    // background goes on while the main agent waits on its prompt.
    var b = try hookedBus();
    defer b.deinit();
    _ = try b.agentEvent(worker, hookEv(.turn_started), 1_000);
    var ask = hookEv(.awaiting_approval);
    ask.detail = "Bash";
    _ = try b.agentEvent(worker, ask, 2_000);

    var sub = toolDone("Bash");
    sub.agent_id = "a36a9e16d5b37235e";
    try testing.expect(!try b.agentEvent(worker, sub, 3_000));
    const a = b.agentOf(worker).*;
    try testing.expectEqual(AgentState.awaiting_approval, a.state);
    try testing.expectEqual(@as(?u64, 2_000), a.last_event_ms);
    try testing.expect(b.promptStanding(worker, 2_000, 2_000, 3_000, null));

    // The main agent's own next tool call is what ends it.
    _ = try b.agentEvent(worker, toolDone("Bash"), 4_000);
    try testing.expectEqual(AgentState.in_turn, b.agentOf(worker).state);
}

test "hooks: an approval declined with feedback is over at the agent's next tool call, whichever tool" {
    // Declined with something typed, Claude Code does not end the turn: it
    // hands the agent the feedback and the agent goes on -- with another
    // tool, as often as not. No hook marks the decline itself.
    var b = try hookedBus();
    defer b.deinit();
    _ = try b.agentEvent(worker, hookEv(.turn_started), 1_000);
    var ask = hookEv(.awaiting_approval);
    ask.detail = "Bash";
    ask.note = "rm -rf dist";
    _ = try b.agentEvent(worker, ask, 2_000);

    _ = try b.agentEvent(worker, toolDone("Edit"), 30_000);
    try testing.expectEqual(AgentState.in_turn, b.agentOf(worker).state);
}

test "hooks: a subagent's approval is ended by that subagent's tool call, not the main agent's" {
    var b = try hookedBus();
    defer b.deinit();
    _ = try b.agentEvent(worker, hookEv(.turn_started), 1_000);
    var ask = hookEv(.awaiting_approval);
    ask.detail = "AskUserQuestion";
    ask.agent_id = "sub-1";
    _ = try b.agentEvent(worker, ask, 2_000);

    _ = try b.agentEvent(worker, toolDone("Read"), 3_000);
    var other = toolDone("AskUserQuestion");
    other.agent_id = "sub-2";
    _ = try b.agentEvent(worker, other, 4_000);
    try testing.expectEqual(AgentState.awaiting_approval, b.agentOf(worker).state);

    var own = toolDone("AskUserQuestion");
    own.agent_id = "sub-1";
    _ = try b.agentEvent(worker, own, 5_000);
    try testing.expectEqual(AgentState.in_turn, b.agentOf(worker).state);
}

test "hooks: a waiting notice the supervisor's terminal refused is offered again at once, not an interval later" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;
    _ = b.report(worker, quiet(60_000), 0);
    _ = b.drainIfDue(boss, 0, &buf, .none) orelse return error.TestExpectedNotice;

    var ask = hookEv(.awaiting_approval);
    ask.detail = "Bash";
    _ = try b.agentEvent(worker, ask, 10_000);
    _ = b.drainIfDue(boss, 10_000, &buf, .none) orelse return error.TestExpectedNotice;

    // The person was typing in the supervisor's terminal: the line was
    // never typed. Without being told, the bus believes it was delivered.
    try testing.expect(b.drainIfDue(boss, 15_000, &buf, .none) == null);
    b.deliveryRefused(boss, .none);
    const again = b.drainIfDue(boss, 15_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, again, "awaiting approval Bash") != null);

    // Refused as many times as it takes, it is never dropped for having
    // been "handed over" too often: a refusal is not a hand-over.
    for (0..10) |n| {
        b.deliveryRefused(boss, .none);
        const t = 20_000 + @as(u64, @intCast(n)) * 5_000;
        _ = b.drainIfDue(boss, t, &buf, .none) orelse return error.TestExpectedNotice;
    }
    try testing.expectEqual(AgentNotice.awaiting_approval, b.get(worker).?.agent.pending.?);
}

test "hooks: the notice about a prompt says when answering it is not open" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;
    try b.setMayAuthorise(worker, false, .user);

    var ask = hookEv(.awaiting_approval);
    ask.detail = "Edit";
    _ = try b.agentEvent(worker, ask, 7);
    const line = b.drain(boss, 7, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expectEqualStrings(
        "[poltergeist] 0x0000000000002222 awaiting approval Edit [state_at_ms=7 event_at_ms=7 answer=off]",
        line,
    );
}

test "hooks: a long note is what gets cut, never the guard" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;
    var ask = hookEv(.awaiting_approval);
    ask.detail = "Bash";
    ask.note = "x" ** 400;
    _ = try b.agentEvent(worker, ask, 123_456);
    const line = b.drain(boss, 123_456, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, line, "[state_at_ms=123456 event_at_ms=123456 answer=allowed]") != null);
    // Cut, and says so: how long it was and where the rest is (task 1651).
    try testing.expect(std.mem.endsWith(u8, line, "\u{2026} [400 bytes; terminal_turn has all]"));
    try testing.expect(line.len <= buf.len);
}

test "hooks: a note cut by +hook says so on the line even when it would fit (task 1651)" {
    // The instance: the hook kept the first 120 characters of a longer
    // command, the line had room for all 120, and it went out without a
    // mark -- a command that seemed to end at `; S`.
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;
    var ask = hookEv(.awaiting_approval);
    ask.detail = "Bash";
    ask.note = "D=/tmp/issue-fix; S";
    ask.text = "D=/tmp/issue-fix; S=$D/x; rm -rf \"$S\"";
    ask.text_bytes = 812;
    _ = try b.agentEvent(worker, ask, 5);
    const line = b.drain(boss, 5, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.endsWith(u8, line, ": D=/tmp/issue-fix; S\u{2026} [812 bytes; terminal_turn has all]"));

    // And one that is whole carries no mark.
    var b2 = try hookedBus();
    defer b2.deinit();
    ask.text = ask.note;
    ask.text_bytes = ask.note.?.len;
    _ = try b2.agentEvent(worker, ask, 5);
    const whole = b2.drain(boss, 5, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.endsWith(u8, whole, ": D=/tmp/issue-fix; S"));
}

test "hooks: the tool call waiting for approval is kept whole while it waits, and only then (task 1651)" {
    var b = try hookedBus();
    defer b.deinit();
    try testing.expect(b.pendingToolOf(worker) == null);

    var ask = hookEv(.awaiting_approval);
    ask.detail = "Edit";
    ask.note = "/w/a.zig";
    ask.input = "{\"file_path\":\"/w/a.zig\",\"old_string\":\"a\",\"new_string\":\"b\"}";
    ask.input_bytes = 9000;
    _ = try b.agentEvent(worker, ask, 70);
    const t = b.pendingToolOf(worker) orelse return error.TestExpectedPendingTool;
    try testing.expectEqualStrings("Edit", t.name);
    // Lent out of the entry itself. A copy's bytes still read "Edit" for a
    // moment after it is gone, which is how a name came back as four bytes
    // of rubbish in terminal_turn and nowhere here.
    const held = &b.entries.getPtr(worker).?.agent.detail.buf;
    try testing.expectEqual(@intFromPtr(held), @intFromPtr(t.name.ptr));
    try testing.expectEqualStrings(ask.input.?, t.input);
    try testing.expectEqual(@as(u64, 9000), t.input_bytes);
    try testing.expectEqual(@as(u64, 70), t.at_ms);

    // Started tools inside the wait move nothing (task 1625's rule)...
    var started = hookEv(.tool_started);
    started.detail = "Read";
    _ = try b.agentEvent(worker, started, 71);
    try testing.expect(b.pendingToolOf(worker) != null);

    // ...an answered approval ends it.
    var resumed = hookEv(.turn_resumed);
    resumed.detail = "Edit";
    _ = try b.agentEvent(worker, resumed, 72);
    try testing.expect(b.pendingToolOf(worker) == null);

    // A question is not a tool call.
    _ = try b.agentEvent(worker, ask, 73);
    var q = hookEv(.awaiting_input);
    q.detail = "elicitation_dialog";
    q.input = "{}";
    q.input_bytes = 2;
    _ = try b.agentEvent(worker, q, 74);
    try testing.expect(b.pendingToolOf(worker) == null);

    // Gone with the terminal.
    _ = try b.agentEvent(worker, ask, 75);
    b.unregister(worker);
    try testing.expect(b.pendingToolOf(worker) == null);
}

test "1668: with hooks live, a title that says it waits keeps the box standing while the screen moves" {
    var b = try hookedBus();
    defer b.deinit();
    var ask = hookEv(.awaiting_approval);
    ask.cli = "codex";
    ask.detail = "mcp__polter__me";
    _ = try b.agentEvent(worker, ask, 1_000);
    // The title says nothing to the state of a hooked agent ...
    try testing.expect(!try b.noteTitle(worker, "codex", codex_wait, 1_200));
    try testing.expectEqual(SaidBy.hooks, b.agentOf(worker).said_by);
    try testing.expectEqualStrings("mcp__polter__me", b.agentOf(worker).detail.get().?);

    // ... but while it says the box is up, the box stands, however much
    // the screen under it has moved.
    b.noteQuiet(worker, 0, 14_000);
    try testing.expect(b.promptStanding(worker, 1_000, 1_000, 14_000, null));
    // Not another box's moments.
    try testing.expect(!b.promptStanding(worker, 1_000, 999, 14_000, null));

    // The title leaves: the box went with it.
    _ = try b.noteTitle(worker, null, "w", 15_000);
    try testing.expect(!b.promptStanding(worker, 1_000, 1_000, 15_000, null));
}

test "1668: a title that never said it waits does not keep a moving box standing" {
    var b = try hookedBus();
    defer b.deinit();
    var ask = hookEv(.awaiting_approval);
    ask.detail = "Bash";
    _ = try b.agentEvent(worker, ask, 1_000);
    _ = try b.noteTitle(worker, null, "✳ Claude Code", 1_200);
    b.noteQuiet(worker, 0, 14_000);
    try testing.expect(!b.promptStanding(worker, 1_000, 1_000, 14_000, null));
}

fn aliveYes(_: *anyopaque, _: Id, _: Program) bool {
    return true;
}
fn aliveNo(_: *anyopaque, _: Id, _: Program) bool {
    return false;
}
var alive_ctx: u8 = 0;

/// A program that runs until it is told not to, and remembers what it was
/// asked about.
const Runner = struct {
    runs: bool = true,
    asked: ?Program = null,
    fn ask(ctx: *anyopaque, _: Id, p: Program) bool {
        const self: *Runner = @ptrCast(@alignCast(ctx));
        self.asked = p;
        return self.runs;
    }
};

test "1668: a lost connection goes out at once, not at the next scheduled box" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;
    // A delivery a moment ago: the next scheduled one is an interval away.
    _ = try b.agentEvent(worker, hookEv(.turn_ended), 500);
    try testing.expect(b.drainIfDue(boss, 1_000, &buf, .none) != null);

    b.noteAgentHere(worker, true, .{ .pid = 77, .started = 500 }, 1_000);
    b.noteAgentHere(worker, false, null, 2_000);
    try testing.expect(b.considerLinks(2_000 + link_grace_ms, &alive_ctx, aliveYes));
    try testing.expect(b.hasFreshWaiting(boss, .none));
    const line = b.drainIfDue(boss, 2_000 + link_grace_ms, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, line, "lost its Polter connection") != null);
}

test "1668: a lost connection said while its program ran is taken back once the program has gone" {
    var b = try hookedBus();
    defer b.deinit();
    var r: Runner = .{};
    b.noteAgentHere(worker, true, .{ .pid = 53324, .started = 123 }, 1_000);
    b.noteAgentHere(worker, false, null, 2_000);
    try testing.expect(b.considerLinks(2_000 + link_grace_ms, &r, Runner.ask));
    // What the host is asked about is the program as it was seen, start
    // time and all: the same pid on a later process is not it.
    try testing.expectEqual(@as(u64, 53324), r.asked.?.pid);
    try testing.expectEqual(@as(?u64, 123), r.asked.?.started);

    // Still shutting down when it was looked at; gone before anybody read
    // the line (#1669 c1669-12).
    r.runs = false;
    _ = b.considerLinks(2_000 + 2 * link_grace_ms, &r, Runner.ask);
    var buf: [255]u8 = undefined;
    try testing.expect(b.drain(boss, 2_000 + 2 * link_grace_ms, &buf, .none) == null);
}

test "1668: a connection gone while its program runs is said once, after the grace" {
    var b = try hookedBus();
    defer b.deinit();
    b.noteAgentHere(worker, true, .{ .pid = 77, .started = 500 }, 1_000);
    b.noteAgentHere(worker, false, null, 2_000);

    try testing.expect(!b.considerLinks(2_000 + link_grace_ms - 1, &alive_ctx, aliveYes));
    try testing.expect(b.considerLinks(2_000 + link_grace_ms, &alive_ctx, aliveYes));
    var buf: [255]u8 = undefined;
    const line = b.drain(boss, 2_000 + link_grace_ms, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, line, "0x0000000000002222 lost its Polter connection 5s ago while its program (pid 77) still runs") != null);

    // Once per loss.
    try testing.expect(!b.considerLinks(10 * link_grace_ms, &alive_ctx, aliveYes));
}

test "1668: a connection gone with its program, or back in time, or from nobody known, is not news" {
    var b = try hookedBus();
    defer b.deinit();

    // The program went too: an agent that exited.
    b.noteAgentHere(worker, true, .{ .pid = 77, .started = 500 }, 1_000);
    b.noteAgentHere(worker, false, null, 2_000);
    try testing.expect(!b.considerLinks(2_000 + link_grace_ms, &alive_ctx, aliveNo));

    // Back within the grace: a restart, not a loss.
    b.noteAgentHere(worker, true, .{ .pid = 78, .started = 500 }, 10_000);
    b.noteAgentHere(worker, false, null, 11_000);
    b.noteAgentHere(worker, true, .{ .pid = 78, .started = 500 }, 12_000);
    try testing.expect(!b.considerLinks(11_000 + link_grace_ms, &alive_ctx, aliveYes));

    // Said, then back before anybody read it: taken back.
    b.noteAgentHere(worker, false, null, 20_000);
    try testing.expect(b.considerLinks(20_000 + link_grace_ms, &alive_ctx, aliveYes));
    b.noteAgentHere(worker, true, .{ .pid = 78, .started = 500 }, 26_000);
    var buf: [255]u8 = undefined;
    try testing.expect(b.drain(boss, 26_000, &buf, .none) == null);

    // A first look that finds nobody is not a loss; nor is one from a
    // program nobody named.
    var c = try hookedBus();
    defer c.deinit();
    c.noteAgentHere(worker, false, null, 1_000);
    try testing.expect(!c.considerLinks(1_000 + link_grace_ms, &alive_ctx, aliveYes));
    c.noteAgentHere(worker, true, null, 2_000);
    c.noteAgentHere(worker, false, null, 3_000);
    try testing.expect(!c.considerLinks(3_000 + link_grace_ms, &alive_ctx, aliveYes));
}

test "boxPrint: the same box whatever its countdown says, and nothing without one (task 1655)" {
    const rows: []const []const u8 = &.{"will automatically deny this request in"};
    const a = " Bash command\n   rm -rf dist/\n ⚠ Claude Code will automatically deny this request in 1:54, to avoid blocking\n Do you want to proceed?\n";
    const b = " Bash command\n   rm -rf dist/\n ⚠ Claude Code will automatically deny this request in about 9 seconds, to avoid blocking\n Do you want to proceed?\n";
    const other = " Bash command\n   git push --force\n ⚠ Claude Code will automatically deny this request in 1:54, to avoid blocking\n Do you want to proceed?\n";
    const gone = " Bash command\n   rm -rf dist/\n Do you want to proceed?\n";
    try testing.expect(boxPrint(a, rows) != null);
    try testing.expectEqual(boxPrint(a, rows).?, boxPrint(b, rows).?);
    try testing.expect(boxPrint(a, rows).? != boxPrint(other, rows).?);
    // No countdown row: not this kind of box, or not on screen.
    try testing.expect(boxPrint(gone, rows) == null);
    // A CLI that declares no rows matches nothing.
    try testing.expect(boxPrint(a, &.{}) == null);
}

test "hooks: a box whose own rows redraw stands while the rest of it does, and no longer (task 1655)" {
    var b = try hookedBus();
    defer b.deinit();
    const box = " rm -rf dist/\n ⚠ Claude Code will automatically deny this request in 1:54, to avoid\n ❯ 1. Yes\n";
    const later = " rm -rf dist/\n ⚠ Claude Code will automatically deny this request in 1:41, to avoid\n ❯ 1. Yes\n";
    var ask = hookEv(.awaiting_approval);
    ask.detail = "Bash";
    _ = try b.agentEvent(worker, ask, 1_000);

    // Not before the box has had its grace to be drawn.
    b.noteQuiet(worker, 0, 2_000);
    try testing.expect(!b.wantsBoxPrint(worker, 2_000));
    // Not kept from a screen without the countdown on it.
    try testing.expect(!b.noteBoxPrint(worker, 1_000, " rm -rf dist/\n"));
    try testing.expect(b.wantsBoxPrint(worker, 4_000));
    // Not for an event that is not the one waiting.
    try testing.expect(!b.noteBoxPrint(worker, 999, box));
    try testing.expect(b.noteBoxPrint(worker, 1_000, box));
    try testing.expect(!b.wantsBoxPrint(worker, 5_000));
    try testing.expect(b.promptNeedsScreen(worker));

    // The screen keeps moving: by the old rule alone, gone.
    b.noteQuiet(worker, 0, 14_000);
    try testing.expect(!b.promptStanding(worker, 1_000, 1_000, 14_000, null));
    // With the screen as it is now, the same box.
    try testing.expect(b.promptStanding(worker, 1_000, 1_000, 14_000, later));
    // Still the moments of this box, and no other.
    try testing.expect(!b.promptStanding(worker, 1_000, 999, 14_000, later));
    // The rest of the box changed, or the countdown is gone: not it.
    try testing.expect(!b.promptStanding(worker, 1_000, 1_000, 14_000, " git push\n ⚠ Claude Code will automatically deny this request in 1:41, to avoid\n ❯ 1. Yes\n"));
    try testing.expect(!b.promptStanding(worker, 1_000, 1_000, 14_000, " rm -rf dist/\n ❯ 1. Yes\n"));

    // A second box is a new event, and what was captured goes with the first.
    _ = try b.agentEvent(worker, ask, 15_000);
    try testing.expect(!b.promptNeedsScreen(worker));
    b.noteQuiet(worker, 0, 30_000);
    try testing.expect(!b.promptStanding(worker, 15_000, 15_000, 30_000, later));

    // A CLI that declares no redrawing rows is asked nothing.
    var other = hookEv(.awaiting_approval);
    other.cli = "codex";
    _ = try b.agentEvent(worker, other, 40_000);
    try testing.expect(!b.wantsBoxPrint(worker, 60_000));
}

test "hooks: a new turn makes the last one's notice stale" {
    var b = try hookedBus();
    defer b.deinit();

    var ev = hookEv(.turn_ended);
    ev.text = "done";
    ev.text_bytes = 4;
    _ = try b.agentEvent(worker, ev, 0);
    _ = try b.agentEvent(worker, hookEv(.turn_started), 1_000);

    var buf: [255]u8 = undefined;
    try testing.expect(b.drain(boss, 2_000, &buf, .none) == null);
    // The answer is still there for `terminal_turn`.
    try testing.expectEqualStrings("done", b.turnOf(worker).?.text);
}

test "hooks: live and ended, a still screen is not reported again as quiet" {
    var b = try hookedBus();
    defer b.deinit();

    _ = try b.agentEvent(worker, hookEv(.session_started), 0);
    var ev = hookEv(.turn_ended);
    ev.text = "done";
    ev.text_bytes = 4;
    _ = try b.agentEvent(worker, ev, 0);
    var buf: [255]u8 = undefined;
    _ = b.drain(boss, 0, &buf, .none);

    _ = b.report(worker, quiet(60_000), 60_000);
    try testing.expect(b.drain(boss, 60_000, &buf, .none) == null);
}

test "hooks: live and in a turn, a still screen is reported with how long the turn has run" {
    var b = try hookedBus();
    defer b.deinit();

    _ = try b.agentEvent(worker, hookEv(.session_started), 0);
    _ = try b.agentEvent(worker, hookEv(.turn_started), 0);

    _ = b.report(worker, quiet(60_000), 3 * std.time.ms_per_min);
    var buf: [255]u8 = undefined;
    const line = b.drain(boss, 3 * std.time.ms_per_min, &buf, .none) orelse
        return error.TestExpectedNotice;
    try testing.expectEqualStrings(
        "[poltergeist] 0x0000000000002222 quiet 60s (in turn 3m)",
        line,
    );
}

test "hooks: live and idle, or no hooks at all, a still screen is reported as before" {
    var b = try hookedBus();
    defer b.deinit();

    _ = try b.agentEvent(worker, hookEv(.session_started), 0);
    _ = b.report(worker, quiet(60_000), 60_000);
    var buf: [255]u8 = undefined;
    const idle = b.drain(boss, 60_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expectEqualStrings("[poltergeist] 0x0000000000002222 quiet 60s", idle);

    // `expected` is not `live`: until the hooks have spoken, nothing they
    // did not say explains anything.
    var c = try hookedBus();
    defer c.deinit();
    _ = try c.agentEvent(worker, hookEv(.hooks_expected), 0);
    c.entries.getPtr(worker).?.agent.state = .ended;
    _ = c.report(worker, quiet(60_000), 1_000);
    const expected = c.drain(boss, 1_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, expected, "quiet 60s") != null);
}

test "hooks: an unwatched terminal's events are kept but go in nobody's box" {
    var b = testBus();
    defer b.deinit();
    try b.addSupervisor(boss);

    var ev = hookEv(.turn_ended);
    ev.text = "done";
    ev.text_bytes = 4;
    try testing.expect(!try b.agentEvent(worker, ev, 0));
    try testing.expectEqual(AgentState.ended, b.agentOf(worker).state);
    var buf: [255]u8 = undefined;
    try testing.expect(b.drain(boss, 0, &buf, .none) == null);
}

test "hooks 879: a screen that moved after awaiting approval, and then went still, is reported quiet" {
    // Measured on the test Mac, then with a bare claude 2.1.283 in a pty:
    // declining a permission box -- Esc, or choosing No -- fires **no hook
    // at all**. No Stop, no PostToolUseFailure, no PermissionDenied, no
    // Notification in the 75 s after. Claude is back at an empty prompt and
    // the last thing it said is still "awaiting approval". Before this, that
    // state kept every quiet report out of the box: the supervisor was told
    // nothing by either clock.
    var b = try hookedBus();
    defer b.deinit();

    _ = try b.agentEvent(worker, hookEv(.session_started), 0);
    var ask = hookEv(.awaiting_approval);
    ask.detail = "Bash";
    _ = try b.agentEvent(worker, ask, 1_000);
    var buf: [255]u8 = undefined;
    _ = b.drain(boss, 1_000, &buf, .none);

    // The person declines at 30s: the screen redraws, then stays still.
    b.noteQuiet(worker, 0, 30_000);
    _ = b.report(worker, quiet(60_000), 90_000);

    const line = b.drain(boss, 90_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expectEqualStrings(
        "[poltergeist] 0x0000000000002222 quiet 60s (last event: awaiting approval 89s ago)",
        line,
    );
}

test "hooks 879: the screen drawing the event itself does not count as moving after it" {
    // Measured: the permission box is still being drawn up to 1.8 s after
    // the PermissionRequest hook fires. That redraw is the event's own, and
    // the stillness after it is the one the event explains.
    var b = try hookedBus();
    defer b.deinit();

    _ = try b.agentEvent(worker, hookEv(.session_started), 0);
    _ = try b.agentEvent(worker, hookEv(.awaiting_approval), 10_000);
    var buf: [255]u8 = undefined;
    _ = b.drain(boss, 10_000, &buf, .none);

    b.noteQuiet(worker, 0, 10_000 + event_redraw_grace_ms);
    _ = b.report(worker, quiet(60_000), 10_000 + event_redraw_grace_ms + 60_000);
    try testing.expect(b.drain(boss, 10_000 + event_redraw_grace_ms + 60_000, &buf, .none) == null);
}

test "hooks 1503: a turn that ended and then saw the screen move is neither back at work nor quiet again" {
    // This used to be #879's "reported quiet too". An agent sitting at its
    // prompt after a turn redraws it -- a status line, the cursor -- and
    // every redraw was a `back at work` and then another `quiet` with the
    // same `turn ended` beside it, all night (task 1503). A new turn says
    // so itself: `turn_started`.
    var b = try hookedBus();
    defer b.deinit();

    _ = try b.agentEvent(worker, hookEv(.session_started), 0);
    var ev = hookEv(.turn_ended);
    ev.text = "done";
    ev.text_bytes = 4;
    _ = try b.agentEvent(worker, ev, 0);
    var buf: [255]u8 = undefined;
    _ = b.drain(boss, 0, &buf, .none);

    // Something drew on the screen long after the turn ended, and no hook
    // said a word.
    try testing.expect(!b.report(worker, .{ .resumed = .{ .quiet_ms = 0, .silent_ms = 0, .changed_rows = 3, .total_rows = 24 } }, 20_000));
    try testing.expect(b.drain(boss, 20_000, &buf, .none) == null);
    b.noteQuiet(worker, 0, 20_000);
    _ = b.report(worker, quiet(40_000), 60_000);
    try testing.expect(b.drain(boss, 60_000, &buf, .none) == null);

    // The floor: a turn that really starts, and stops, is said.
    _ = try b.agentEvent(worker, hookEv(.turn_started), 61_000);
    _ = b.report(worker, quiet(200_000), 300_000);
    const line = b.drain(boss, 300_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, line, "quiet 200s (in turn") != null);
}

test "ControlRoom facts: everything the bus knows of a terminal, at one moment" {
    var b = try hookedBus();
    defer b.deinit();

    _ = try b.agentEvent(worker, hookEv(.turn_started), 1_000);
    b.noteQuiet(worker, 500, 2_000);
    b.noteCall(worker, 1_500);
    try b.setHeld(worker, true, .user);

    const f = b.facts(worker, 3_000, .none);
    try testing.expectEqual(worker, f.id);
    try testing.expectEqual(Hooks.live, f.hooks);
    try testing.expectEqual(AgentState.in_turn, f.state);
    try testing.expectEqual(@as(u64, 1_000), f.state_since_ms);
    try testing.expectEqual(@as(?u64, 1_000), f.last_event_ms);
    try testing.expectEqual(Attention.Screen{ .still_ms = 1_500 }, f.screen);
    try testing.expectEqual(@as(?u64, 1_500), f.call_silent_ms);
    try testing.expectEqual(Duty.on, f.duty);
    try testing.expect(f.held);
    try testing.expect(!f.shielded);
    try testing.expectEqual(Attention.Process.running, f.process);

    // What the caller supplies is passed through untouched.
    const seen = b.facts(worker, 3_000, .{ .process = .running, .seen_ms = 7, .raised_ms = 9 });
    try testing.expectEqual(@as(?u64, 7), seen.seen_ms);
    try testing.expectEqual(@as(?u64, 9), seen.raised_ms);
}

test "ControlRoom facts: a sampler that failed is a failure with a time, not a still screen" {
    var b = try hookedBus();
    defer b.deinit();

    // Asked for and not yet answered: not measured, and not a fault.
    try testing.expectEqual(Attention.Screen.unmeasured, b.facts(worker, 10, .none).screen);

    b.noteSampling(worker, false, 4_000);
    try testing.expectEqual(Attention.Screen{ .unreadable = 4_000 }, b.facts(worker, 9_000, .none).screen);

    b.noteSampling(worker, true, 5_000);
    try testing.expectEqual(Attention.Screen{ .still_ms = 0 }, b.facts(worker, 9_000, .none).screen);

    // The supervisor is not sampled at all.
    try testing.expectEqual(Attention.Screen.unmeasured, b.facts(boss, 9_000, .none).screen);
}

test "ControlRoom facts: an agent that left is a failure only when something said so" {
    var b = try hookedBus();
    defer b.deinit();
    _ = try b.agentEvent(worker, hookEv(.turn_started), 1_000);

    b.noteLeft(worker, .unknown, 2_000);
    try testing.expectEqual(Attention.Process{ .agent_left = 2_000 }, b.facts(worker, 3_000, .none).process);

    // Said to have failed: that stands, and a later "gone" does not soften it.
    b.noteLeft(worker, .failed, 2_500);
    b.noteLeft(worker, .unknown, 2_700);
    try testing.expectEqual(Attention.Process{ .agent_exited = 2_500 }, b.facts(worker, 3_000, .none).process);

    // The caller is looking at the terminal now, and outranks the note.
    const gone = b.facts(worker, 3_000, .{ .process = .gone, .seen_ms = null, .raised_ms = null });
    try testing.expectEqual(Attention.Process.gone, gone.process);

    // An agent that speaks again is there.
    _ = try b.agentEvent(worker, hookEv(.turn_started), 4_000);
    try testing.expectEqual(Attention.Process.running, b.facts(worker, 5_000, .none).process);
}

test "ControlRoom facts: a terminal the bus never heard of is not there" {
    var b = try hookedBus();
    defer b.deinit();
    const f = b.facts(0xdead, 1_000, .none);
    try testing.expectEqual(@as(Id, 0xdead), f.id);
    try testing.expectEqual(Attention.Process.gone, f.process);
    try testing.expectEqual(Hooks.none, f.hooks);
}

test "ControlRoom since: a state said again does not start its clock again" {
    var b = try hookedBus();
    defer b.deinit();

    // Pressed twice while it works: one turn, as far as waiting goes.
    _ = try b.agentEvent(worker, hookEv(.turn_started), 1_000);
    _ = try b.agentEvent(worker, hookEv(.turn_started), 9_000);
    try testing.expectEqual(@as(u64, 1_000), b.agentOf(worker).since_ms);
    try testing.expectEqual(@as(?u64, 9_000), b.agentOf(worker).last_event_ms);

    // Announced again, waiting on the same thing: it has waited since the
    // first time.
    var ask = hookEv(.awaiting_input);
    ask.note = "which format?";
    _ = try b.agentEvent(worker, ask, 20_000);
    _ = try b.agentEvent(worker, ask, 80_000);
    try testing.expectEqual(@as(u64, 20_000), b.agentOf(worker).since_ms);
    try testing.expectEqual(@as(u64, 20_000), b.facts(worker, 90_000, .none).state_since_ms);
    try testing.expectEqual(@as(?u64, 80_000), b.facts(worker, 90_000, .none).last_event_ms);

    // A different state does.
    _ = try b.agentEvent(worker, hookEv(.turn_started), 95_000);
    try testing.expectEqual(@as(u64, 95_000), b.agentOf(worker).since_ms);
}

test "ControlRoom since: waiting on a different thing is a different wait" {
    var b = try hookedBus();
    defer b.deinit();

    var first = hookEv(.awaiting_approval);
    first.detail = "Bash";
    first.note = "rm -rf dist/";
    var second = hookEv(.awaiting_approval);
    second.detail = "Bash";
    second.note = "git push";

    _ = try b.agentEvent(worker, first, 1_000);
    _ = try b.agentEvent(worker, second, 5_000);
    try testing.expectEqual(@as(u64, 5_000), b.agentOf(worker).since_ms);
}

test "ControlRoom since: the notices still count from when the event arrived" {
    var b = try hookedBus();
    defer b.deinit();
    _ = try b.agentEvent(worker, hookEv(.turn_started), 1_000);
    _ = try b.agentEvent(worker, hookEv(.turn_ended), 10_000);
    _ = try b.agentEvent(worker, hookEv(.turn_ended), 50_000);

    var buf: [512]u8 = undefined;
    const line = b.drain(boss, 53_000, &buf, .none) orelse return error.TestNothingInTheBox;
    // Three seconds since it was last said, not forty-three since the first.
    try testing.expect(std.mem.indexOf(u8, line, "turn ended 3s ago") != null);
}

test "ControlRoom prompt: the one a caller saw, and no other" {
    var b = try hookedBus();
    defer b.deinit();

    var first = hookEv(.awaiting_approval);
    first.note = "rm -rf dist/";
    _ = try b.agentEvent(worker, first, 1_000);
    try testing.expect(b.promptStanding(worker, 1_000, 1_000, 2_000, null));

    // Not the time it was seen at.
    try testing.expect(!b.promptStanding(worker, 999, 1_000, 2_000, null));
    try testing.expect(!b.promptStanding(worker, 1_000, 999, 2_000, null));
    // Not a terminal nobody knows.
    try testing.expect(!b.promptStanding(0xdead, 1_000, 1_000, 2_000, null));

    // Announced again: the same wait, and a later event than the one seen.
    _ = try b.agentEvent(worker, first, 3_000);
    try testing.expect(!b.promptStanding(worker, 1_000, 1_000, 4_000, null));
    try testing.expect(b.promptStanding(worker, 1_000, 3_000, 4_000, null));

    // Answered at the terminal, which no hook reports: the screen moved
    // after the box was drawn, and that is all there is to go on.
    b.noteSampling(worker, true, 3_000);
    b.noteQuiet(worker, 0, 20_000);
    try testing.expect(!b.promptStanding(worker, 1_000, 3_000, 21_000, null));

    // No longer waiting on an approval at all.
    _ = try b.agentEvent(worker, hookEv(.turn_started), 30_000);
    try testing.expect(!b.promptStanding(worker, 30_000, 30_000, 31_000, null));
}

test "hooks: the status line saying it wrote the allowance changes nothing the bus keeps" {
    var b = try hookedBus();
    defer b.deinit();

    // A worker stopped on a prompt, as the control room and the guard on
    // answering it both read it.
    var ask = hookEv(.awaiting_approval);
    ask.detail = "Bash";
    _ = try b.agentEvent(worker, ask, 10_000);
    const before = b.agentOf(worker).*;
    try testing.expect(b.promptStanding(worker, 10_000, 10_000, 11_000, null));

    // Its status line refreshes a second later and says a file was written.
    try testing.expect(!try b.agentEvent(worker, hookEv(.allowance_written), 11_000));
    const after = b.agentOf(worker).*;
    try testing.expectEqual(before.state, after.state);
    try testing.expectEqual(before.since_ms, after.since_ms);
    // Not "heard from": the prompt on screen is still the one asked about.
    try testing.expectEqual(before.last_event_ms, after.last_event_ms);
    try testing.expectEqual(before.pending, after.pending);
    try testing.expect(b.promptStanding(worker, 10_000, 10_000, 12_000, null));

    // And from a terminal the bus has never heard of, it makes no entry:
    // a status line is not an agent's hook.
    const stranger: Id = 0x7777;
    try testing.expect(!try b.agentEvent(stranger, hookEv(.allowance_written), 12_000));
    try testing.expect(b.get(stranger) == null);
}

test "may-authorise off in the configuration: every terminal starts shut, and one opened by hand is the only one open" {
    // The gate a person shuts for good: `poltergeist-may-authorise = false`.
    var b: Bus = .init(testing.allocator, .{ .may_authorise = false });
    defer b.deinit();
    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    const other: Id = 0x3333;
    try b.watch(other, boss);
    var buf: [255]u8 = undefined;

    // A terminal nobody has said anything about: shut -- registered or not.
    try testing.expect(!b.mayAuthorise(worker));
    try testing.expect(!b.mayAuthorise(0x9999));
    try testing.expectEqual(Answer.off, b.answer(worker));

    // The notice about its prompt tells the supervisor so.
    var ask = hookEv(.awaiting_approval);
    ask.detail = "Edit";
    _ = try b.agentEvent(worker, ask, 7);
    const line = b.drain(boss, 7, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, line, "answer=off") != null);
    try testing.expect(std.mem.indexOf(u8, line, "answer=allowed") == null);

    // The person opens it for one terminal, from that terminal's menu.
    // Only a person can; and only that terminal is open.
    try testing.expectError(error.NotPermitted, b.setMayAuthorise(other, true, .supervisor));
    try b.setMayAuthorise(other, true, .user);
    try testing.expect(b.mayAuthorise(other));
    try testing.expectEqual(Answer.allowed, b.answer(other));
    try testing.expect(!b.mayAuthorise(worker));

    // The configuration is read again -- a reload, or the next terminal
    // starting -- and says the same, or the opposite: what the person said
    // about one terminal stands either way.
    b.config.may_authorise = false;
    try testing.expect(b.mayAuthorise(other));
    b.config.may_authorise = true;
    try testing.expect(b.mayAuthorise(worker));
    try b.setMayAuthorise(worker, false, .user);
    b.config.may_authorise = true;
    try testing.expect(!b.mayAuthorise(worker));
    try testing.expect(b.mayAuthorise(other));
}

// -- task 1503: one notice per thing ------------------------------------------

test "notices 1503: the same wait said again is not news, a different one is" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;
    _ = try b.agentEvent(worker, hookEv(.turn_started), 0);

    var idle = hookEv(.awaiting_input);
    idle.detail = "idle_prompt";
    try testing.expect(try b.agentEvent(worker, idle, 1_000));
    _ = b.drain(boss, 1_000, &buf, .none) orelse return error.TestExpectedNotice;

    // Claude Code says it again a minute later, and again: nothing new.
    try testing.expect(!try b.agentEvent(worker, idle, 61_000));
    try testing.expect(!try b.agentEvent(worker, idle, 121_000));
    try testing.expect(b.drain(boss, 121_000, &buf, .none) == null);

    // Waiting on something else is.
    var asks = hookEv(.awaiting_input);
    asks.detail = "which branch?";
    try testing.expect(try b.agentEvent(worker, asks, 130_000));
    const line = b.drain(boss, 130_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, line, "awaiting input which branch?") != null);
}

test "notices 1503: an idle prompt after a turn ended is the same news, a question is not" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;
    _ = try b.agentEvent(worker, hookEv(.turn_started), 0);
    var done = hookEv(.turn_ended);
    done.text = "done";
    done.text_bytes = 4;
    try testing.expect(try b.agentEvent(worker, done, 1_000));
    _ = b.drain(boss, 1_000, &buf, .none) orelse return error.TestExpectedNotice;

    var idle = hookEv(.awaiting_input);
    idle.detail = "idle_prompt";
    try testing.expect(!try b.agentEvent(worker, idle, 61_000));
    try testing.expect(b.drain(boss, 61_000, &buf, .none) == null);
    // The state is still what the agent said: waiting for input.
    try testing.expectEqual(AgentState.awaiting_input, b.agentOf(worker).state);

    // After a turn that ended, a form it puts up is a question.
    var b2 = try hookedBus();
    defer b2.deinit();
    _ = try b2.agentEvent(worker, hookEv(.turn_started), 0);
    _ = try b2.agentEvent(worker, done, 1_000);
    var form = hookEv(.awaiting_input);
    form.detail = "elicitation_dialog";
    try testing.expect(try b2.agentEvent(worker, form, 2_000));
}

test "notices 1503: no tool call is not said while the agent has said why it is not calling" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;
    const t = b.config.calls_silent_after_ms;

    _ = try b.agentEvent(worker, hookEv(.turn_started), 0);
    b.noteCall(worker, 1_000);
    var done = hookEv(.turn_ended);
    done.text = "done";
    done.text_bytes = 4;
    _ = try b.agentEvent(worker, done, 2_000);
    _ = b.drain(boss, 2_000, &buf, .none);

    // Ended, waiting for its next instruction: an hour of no calls is not
    // a stuck worker.
    try testing.expect(!b.considerCalls(1_000 + 4 * t));
    try testing.expect(b.drain(boss, 1_000 + 4 * t, &buf, .none) == null);

    // Given its instruction, it is counted from the turn's start, not from
    // its last call an hour ago.
    const start = 1_000 + 4 * t;
    _ = try b.agentEvent(worker, hookEv(.turn_started), start);
    try testing.expect(!b.considerCalls(start + t - 1));
    try testing.expect(b.considerCalls(start + t));
    const line = b.drain(boss, start + t, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, line, "no tool call 15m") != null);
}

test "notices 1503: a hand-over that went in is not typed again with a new figure" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;
    const t = b.config.calls_silent_after_ms;
    _ = try b.agentEvent(worker, hookEv(.turn_started), 0);
    b.noteCall(worker, 0);

    try testing.expect(b.considerCalls(t));
    const first = b.drainIfDue(boss, t, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, first, "no tool call 15m") != null);
    // It was typed and submitted.
    b.delivered(boss, .none);

    // A minute on there is nothing to type: not `no tool call 16m`.
    try testing.expect(b.drainIfDue(boss, t + std.time.ms_per_min, &buf, .none) == null);
    // The next whole threshold is a new thing, and is said.
    try testing.expect(b.considerCalls(2 * t));
    const second = b.drainIfDue(boss, 2 * t, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, second, "no tool call 30m") != null);
}

test "notices 1503: a hand-over that did not go in comes round again, and what came after it waits its turn" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;
    _ = try b.agentEvent(worker, hookEv(.turn_started), 0);
    var done = hookEv(.turn_ended);
    done.text = "done";
    done.text_bytes = 4;
    _ = try b.agentEvent(worker, done, 1_000);

    // Typed and refused (or never submitted): no `delivered`. It comes
    // round on the interval, as it always did.
    _ = b.drainIfDue(boss, 1_000, &buf, .none) orelse return error.TestExpectedNotice;
    const again = b.drainIfDue(boss, 61_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, again, "turn ended") != null);

    // That one went in -- and what was put in the box after it was made is
    // not taken with it.
    try testing.expect(b.leaveNote(boss, "a note for later"));
    b.delivered(boss, .none);
    const after = b.drain(boss, 62_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, after, "turn ended") == null);
    try testing.expect(std.mem.indexOf(u8, after, "a note for later") != null);
}

test "#62: a turn running a tool and a turn with nothing running read differently on the no tool call line" {
    const min = std.time.ms_per_min;
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;
    const t = b.config.calls_silent_after_ms;

    _ = try b.agentEvent(worker, hookEv(.session_started), 0);
    _ = try b.agentEvent(worker, hookEv(.turn_started), 0);
    b.noteCall(worker, 0);
    var bash = hookEv(.tool_started);
    bash.detail = "Bash";
    // Counting a tool moves nothing else: no notice, no state.
    try testing.expect(!try b.agentEvent(worker, bash, 1 * min));
    try testing.expectEqual(AgentState.in_turn, b.agentOf(worker).state);

    try testing.expect(b.considerCalls(t));
    const running = b.drain(boss, t, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expectEqualStrings(
        "[poltergeist] 0x0000000000002222 no tool call 15m (in turn 15m, Bash running 14m)",
        running,
    );

    // The command ends and the turn goes on with nothing running in it:
    // what a stuck turn looks like, and it reads as that.
    var ended = hookEv(.turn_resumed);
    ended.detail = "Bash";
    _ = try b.agentEvent(worker, ended, 16 * min);
    try testing.expect(b.considerCalls(2 * t));
    const idle = b.drain(boss, 2 * t, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expectEqualStrings(
        "[poltergeist] 0x0000000000002222 no tool call 30m (in turn 30m, no tool running for 14m)",
        idle,
    );
}

test "#62: an agent that does not report its tools is not said to have none running" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;
    const t = b.config.calls_silent_after_ms;

    _ = try b.agentEvent(worker, hookEv(.session_started), 0);
    _ = try b.agentEvent(worker, hookEv(.turn_started), 0);
    b.noteCall(worker, 0);
    // A tool's end with no start heard: a launch made without PreToolUse.
    var ended = hookEv(.turn_resumed);
    ended.detail = "Read";
    _ = try b.agentEvent(worker, ended, 1_000);
    try testing.expect(b.agentOf(worker).tools == null);

    try testing.expect(b.considerCalls(t));
    const line = b.drain(boss, t, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expectEqualStrings(
        "[poltergeist] 0x0000000000002222 no tool call 15m (in turn 15m)",
        line,
    );
}

test "#62: a turn's edges and a new session reset the tool count" {
    var b = try hookedBus();
    defer b.deinit();
    _ = try b.agentEvent(worker, hookEv(.session_started), 0);
    _ = try b.agentEvent(worker, hookEv(.turn_started), 0);
    var bash = hookEv(.tool_started);
    bash.detail = "Bash";
    _ = try b.agentEvent(worker, bash, 1_000);
    _ = try b.agentEvent(worker, bash, 2_000);
    try testing.expectEqual(@as(?u8, 2), b.agentOf(worker).tools);
    // Declined without feedback: no end is heard, and the turn ends.
    _ = try b.agentEvent(worker, hookEv(.turn_ended), 3_000);
    try testing.expectEqual(@as(?u8, 0), b.agentOf(worker).tools);
    _ = try b.agentEvent(worker, hookEv(.session_started), 4_000);
    try testing.expect(b.agentOf(worker).tools == null);
}

test "#62: one terminal's own no tool call threshold, off, and back to the configured one" {
    const min = std.time.ms_per_min;
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;
    const t = b.config.calls_silent_after_ms;
    _ = try b.agentEvent(worker, hookEv(.turn_started), 0);
    b.noteCall(worker, 0);

    // Raised past the configured fifteen minutes: nothing at fifteen.
    try b.setCallsSilentAfter(worker, 45 * min, 0);
    try testing.expect(!b.considerCalls(t));
    try testing.expect(!b.considerCalls(45 * min - 1));
    try testing.expect(b.considerCalls(45 * min));
    _ = b.drain(boss, 45 * min, &buf, .none) orelse return error.TestExpectedNotice;

    // Off for this terminal.
    try b.setCallsSilentAfter(worker, 0, 45 * min);
    try testing.expect(!b.considerCalls(10 * t));

    // Back to the configured one; a line it would have raised is raised.
    try b.setCallsSilentAfter(worker, null, 10 * t);
    try testing.expect(b.considerCalls(10 * t));
}

test "#62: raising a terminal's threshold takes back the line it would not have raised" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;
    const t = b.config.calls_silent_after_ms;
    _ = try b.agentEvent(worker, hookEv(.turn_started), 0);
    b.noteCall(worker, 0);
    try testing.expect(b.considerCalls(t));
    try b.setCallsSilentAfter(worker, 3 * t, t);
    try testing.expect(b.drain(boss, t, &buf, .none) == null);
}

test "#62: a configured zero stays off whatever a terminal was given" {
    var b: Bus = .init(testing.allocator, .{ .calls_silent_after_ms = 0 });
    defer b.deinit();
    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    b.noteCall(worker, 0);
    try b.setCallsSilentAfter(worker, 1_000, 0);
    try testing.expect(!b.considerCalls(std.time.ms_per_hour));
}

test "#63: a terminal with no agent in it says so on the quiet and no tool call lines" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;
    const t = b.config.calls_silent_after_ms;

    // The measured shape: a worker whose last word was a finished turn, and
    // which then exited -- the hooks still say `ended`.
    _ = try b.agentEvent(worker, hookEv(.turn_started), 0);
    b.noteCall(worker, 0);
    var done = hookEv(.turn_ended);
    done.text = "done";
    done.text_bytes = 4;
    _ = try b.agentEvent(worker, done, 1_000);
    _ = b.drain(boss, 1_000, &buf, .none);

    // Asked, and there: a turn that ended explains a still screen, and
    // nothing is said (task 1503). This is also all that was said about it
    // once it had exited -- the bug.
    b.noteAgentHere(worker, true, null, 0);
    b.noteQuiet(worker, 0, 90_000);
    _ = b.report(worker, quiet(30_000), 120_000);
    try testing.expect(b.drain(boss, 120_000, &buf, .none) == null);
    try testing.expect(!b.considerCalls(t));

    // Gone: its last word explains nothing, and the line says why.
    b.noteAgentHere(worker, false, null, 0);
    b.noteQuiet(worker, 0, 120_000);
    _ = b.report(worker, quiet(60_000), 180_000);
    const gone = b.drain(boss, 180_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expectEqualStrings(
        "[poltergeist] 0x0000000000002222 quiet 60s (no agent in it)",
        gone,
    );

    // And the other clock, for one that left inside a turn.
    var b2 = try hookedBus();
    defer b2.deinit();
    _ = try b2.agentEvent(worker, hookEv(.turn_started), 0);
    b2.noteCall(worker, 0);
    b2.noteAgentHere(worker, false, null, 0);
    try testing.expect(b2.considerCalls(t));
    const silent = b2.drain(boss, t, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expectEqualStrings(
        "[poltergeist] 0x0000000000002222 no tool call 15m (no agent in it)",
        silent,
    );
}

const codex_wait = "[ ! ] Action Required | t1653-w";
const codex_blink = "[ . ] Action Required | t1653-w";

test "1656: a title that says it waits puts awaiting approval in the box, said as the title's" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;

    try testing.expect(try b.noteTitle(worker, "codex", codex_wait, 4_000));
    const a = b.agentOf(worker).*;
    try testing.expectEqual(SaidBy.title, a.said_by);
    try testing.expectEqual(AgentState.awaiting_approval, a.state);
    try testing.expectEqual(Hooks.none, a.hooks);
    try testing.expectEqualStrings("title", a.detail.get().?);
    try testing.expectEqualStrings("codex", a.cli.get().?);
    try testing.expect(b.hasFreshWaiting(boss, .none));

    const line = b.drain(boss, 5_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expectEqualStrings(
        "[poltergeist] 0x0000000000002222 awaiting approval (title says so) [state_at_ms=4000 event_at_ms=4000 answer=allowed]: " ++ codex_wait,
        line,
    );
}

test "1656: the title blinking is one wait, not one a second" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;

    try testing.expect(try b.noteTitle(worker, "codex", codex_wait, 4_000));
    _ = b.drain(boss, 4_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expect(!try b.noteTitle(worker, "codex", codex_blink, 5_000));
    try testing.expect(!try b.noteTitle(worker, "codex", codex_wait, 6_000));
    try testing.expectEqual(@as(u64, 4_000), b.agentOf(worker).since_ms);
    try testing.expect(b.drain(boss, 6_000, &buf, .none) == null);
}

test "1656: a title that stops saying it ends the wait, and takes back a line nobody read" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;

    try testing.expect(try b.noteTitle(worker, "codex", codex_wait, 4_000));
    try testing.expect(!try b.noteTitle(worker, null, "\u{2827} t1653-w", 7_000));
    const a = b.agentOf(worker).*;
    try testing.expectEqual(AgentState.idle, a.state);
    try testing.expectEqual(SaidBy.hooks, a.said_by);
    try testing.expect(a.detail.get() == null);
    try testing.expect(b.drain(boss, 7_000, &buf, .none) == null);

    // And a new box is a new wait.
    try testing.expect(try b.noteTitle(worker, "codex", codex_wait, 9_000));
    try testing.expectEqual(@as(u64, 9_000), b.agentOf(worker).since_ms);
}

fn agyEv(kind: AgentEvent.Kind) AgentEvent.Event {
    var ev = hookEv(kind);
    ev.cli = "antigravity";
    return ev;
}

const agy_box = "Requesting permission for:";

test "1682: a box on the screen, read while a tool runs, is a wait said as the screen's" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;

    // Not read until a tool is running: between tools there is no box.
    _ = try b.agentEvent(worker, agyEv(.turn_started), 1_000);
    try testing.expect(!b.wantsScreenApproval(worker));
    try testing.expect(!b.noteScreenApproval(worker, agy_box, 1_500));
    try testing.expectEqual(AgentState.in_turn, b.agentOf(worker).state);

    var tool = agyEv(.tool_started);
    tool.detail = "run_command";
    _ = try b.agentEvent(worker, tool, 2_000);
    try testing.expect(b.wantsScreenApproval(worker));
    // No box yet: nothing moves.
    try testing.expect(!b.noteScreenApproval(worker, null, 3_000));
    try testing.expectEqual(AgentState.in_turn, b.agentOf(worker).state);

    try testing.expect(b.noteScreenApproval(worker, agy_box, 4_000));
    const a = b.agentOf(worker);
    try testing.expectEqual(SaidBy.screen, a.said_by);
    try testing.expectEqual(AgentState.awaiting_approval, a.state);
    try testing.expectEqual(Hooks.live, a.hooks);
    try testing.expectEqualStrings("screen", a.detail.get().?);
    try testing.expect(a.known());
    // Still read, so that its going is seen.
    try testing.expect(b.wantsScreenApproval(worker));

    const line = b.drain(boss, 5_000, &buf, .none) orelse return error.TestExpectedNotice;
    try testing.expectEqualStrings(
        "[poltergeist] 0x0000000000002222 awaiting approval (screen says so) [state_at_ms=4000 event_at_ms=4000 answer=allowed]: " ++ agy_box,
        line,
    );

    // The same box a heartbeat later is the same wait.
    try testing.expect(!b.noteScreenApproval(worker, agy_box, 9_000));
    try testing.expectEqual(@as(u64, 4_000), b.agentOf(worker).since_ms);
    try testing.expect(b.drain(boss, 9_000, &buf, .none) == null);
}

test "1682: a box gone from the screen ends the wait, and takes back a line nobody read" {
    var b = try hookedBus();
    defer b.deinit();
    var buf: [255]u8 = undefined;

    _ = try b.agentEvent(worker, agyEv(.turn_started), 1_000);
    _ = try b.agentEvent(worker, agyEv(.tool_started), 2_000);
    try testing.expect(b.noteScreenApproval(worker, agy_box, 4_000));
    try testing.expect(!b.noteScreenApproval(worker, null, 7_000));
    const a = b.agentOf(worker);
    try testing.expectEqual(AgentState.in_turn, a.state);
    try testing.expectEqual(SaidBy.hooks, a.said_by);
    try testing.expect(a.detail.get() == null);
    try testing.expect(b.drain(boss, 7_000, &buf, .none) == null);

    // The tool still running, a new box is a new wait.
    try testing.expect(b.noteScreenApproval(worker, agy_box, 9_000));
    try testing.expectEqual(@as(u64, 9_000), b.agentOf(worker).since_ms);
}

test "1682: a hook after a box the screen said ends that wait in the hook's word" {
    var b = try hookedBus();
    defer b.deinit();

    _ = try b.agentEvent(worker, agyEv(.turn_started), 1_000);
    _ = try b.agentEvent(worker, agyEv(.tool_started), 2_000);
    try testing.expect(b.noteScreenApproval(worker, agy_box, 4_000));
    // Approved: the tool's `PostToolUse`.
    _ = try b.agentEvent(worker, agyEv(.turn_resumed), 6_000);
    var a = b.agentOf(worker);
    try testing.expectEqual(AgentState.in_turn, a.state);
    try testing.expectEqual(SaidBy.hooks, a.said_by);
    try testing.expect(!b.wantsScreenApproval(worker));

    // Or the turn ending while it was up.
    _ = try b.agentEvent(worker, agyEv(.tool_started), 7_000);
    try testing.expect(b.noteScreenApproval(worker, agy_box, 8_000));
    _ = try b.agentEvent(worker, agyEv(.turn_ended), 9_000);
    a = b.agentOf(worker);
    try testing.expectEqual(AgentState.ended, a.state);
    try testing.expectEqual(SaidBy.hooks, a.said_by);
}

test "1682: the screen is not read for a terminal whose hooks are not live, or whose title speaks" {
    var b = try hookedBus();
    defer b.deinit();
    // Nothing heard at all.
    try testing.expect(!b.wantsScreenApproval(worker));
    try testing.expect(!b.noteScreenApproval(worker, agy_box, 1_000));
    // A title's wait is the title's.
    try testing.expect(try b.noteTitle(worker, "codex", codex_wait, 2_000));
    try testing.expect(!b.wantsScreenApproval(worker));
    try testing.expect(!b.noteScreenApproval(worker, null, 3_000));
    try testing.expectEqual(SaidBy.title, b.agentOf(worker).said_by);
}

test "1656: live hooks outrank the title, both ways" {
    var b = try hookedBus();
    defer b.deinit();

    // Hooks speaking first: a matching title is not a second voice.
    _ = try b.agentEvent(worker, hookEv(.session_started), 1_000);
    try testing.expect(!try b.noteTitle(worker, "codex", codex_wait, 2_000));
    try testing.expectEqual(AgentState.idle, b.agentOf(worker).state);
    try testing.expectEqual(SaidBy.hooks, b.agentOf(worker).said_by);

    // The title first, then a hook: the hook's word stands.
    var c = try hookedBus();
    defer c.deinit();
    try testing.expect(try c.noteTitle(worker, "codex", codex_wait, 1_000));
    _ = try c.agentEvent(worker, hookEv(.turn_started), 2_000);
    try testing.expectEqual(SaidBy.hooks, c.agentOf(worker).said_by);
    try testing.expectEqual(AgentState.in_turn, c.agentOf(worker).state);
    // A title leaving after that changes nothing the hook said.
    try testing.expect(!try c.noteTitle(worker, null, "zsh", 3_000));
    try testing.expectEqual(AgentState.in_turn, c.agentOf(worker).state);
}

test "1656: a title's wait stands for an answer while the title does, whatever the screen does" {
    var b = try hookedBus();
    defer b.deinit();

    try testing.expect(try b.noteTitle(worker, "codex", codex_wait, 4_000));
    // The screen keeps moving under Codex's box: reports of it change nothing.
    _ = b.report(worker, .{ .resumed = .{ .quiet_ms = 0, .silent_ms = 0, .changed_rows = 1, .total_rows = 24 } }, 5_000);
    try testing.expect(b.promptStanding(worker, 4_000, 4_000, 9_000, null));
    try testing.expect(!b.promptStanding(worker, 3_000, 4_000, 9_000, null));

    _ = try b.noteTitle(worker, null, "zsh", 10_000);
    try testing.expect(!b.promptStanding(worker, 4_000, 4_000, 11_000, null));
}

test "1656: an unwatched terminal's title is noted, and put in nobody's box" {
    var b = testBus();
    defer b.deinit();
    try b.addSupervisor(boss);
    try testing.expect(!try b.noteTitle(worker, "codex", codex_wait, 1_000));
    try testing.expectEqual(AgentState.awaiting_approval, b.agentOf(worker).state);
    var buf: [255]u8 = undefined;
    try testing.expect(b.drain(boss, 1_000, &buf, .none) == null);
    // And a title nobody declared is no reason to keep an entry.
    try testing.expect(!try b.noteTitle(0x3333, null, "zsh", 1_000));
    try testing.expect(b.entries.get(0x3333) == null);
}

/// Fill this much stack with something else: what a dangling slice into a
/// returned frame would then be reading.
fn scribbleStack() void {
    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xA5);
    std.mem.doNotOptimizeAway(&junk);
}

/// `cli` as a caller reads it: through `agentOf`, inside a function of its
/// own that returns what it read -- `App.memberOf`'s shape.
fn cliReadIn(b: *const Bus, id: Id) []const u8 {
    const a = b.agentOf(id);
    return a.cli.get() orelse "";
}

test "1732: a CLI read through agentOf is still its name after the function that read it returns" {
    var b = try hookedBus();
    defer b.deinit();
    b.entries.getPtr(worker).?.agent.cli.set("claude-code");

    const cli = cliReadIn(&b, worker);
    scribbleStack();
    try testing.expectEqualStrings("claude-code", cli);
}
