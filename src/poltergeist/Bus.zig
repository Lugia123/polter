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
//! read from. See `docs/poltergeist/mcp.md`.
//!
//! Pure: no allocation beyond the registry, time arrives as a parameter.

const Bus = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Sampler = @import("Sampler.zig");

/// A terminal's identity. This is `Surface.id`, which Ghostty already
/// assigns and already exports to child processes as `GHOSTTY_SURFACE_ID`,
/// so agents and the bus agree on names without inventing a second scheme.
pub const Id = u64;

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

pub const Entry = struct {
    role: Role = .none,
    duty: Duty = .on,

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
    watched_by: ?Id = null,

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
};

alloc: Allocator,
config: Config,
entries: std.AutoHashMapUnmanaged(Id, Entry) = .empty,

/// There may be several supervisors, each minding its own piece of work.
/// What is one at a time is the other direction: a watched terminal has at
/// most one minder, because two of them nudging one input box is, to the
/// agent in it, being given orders by two people who cannot see each
/// other.
pub fn init(alloc: Allocator, config: Config) Bus {
    return .{ .alloc = alloc, .config = config };
}

pub fn deinit(self: *Bus) void {
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
}

pub fn get(self: *const Bus, id: Id) ?Entry {
    return self.entries.get(id);
}

/// How long this terminal's screen has been unchanged, as of now.
///
/// Extrapolated rather than stale, and exactly so: a screen that changed
/// would have produced a `resumed` report, so the absence of one since the
/// last report means it has not changed since either. Adding the elapsed
/// time is therefore the true figure, not an estimate.
///
/// Zero for a terminal nothing has sampled yet, which is the honest
/// direction to be wrong in: zero moves the supervisor to do nothing, and
/// a large number moves it to act on evidence it does not have.
pub fn quietMs(self: *const Bus, id: Id, now_ms: u64) u64 {
    const e = self.entries.get(id) orelse return 0;
    const since = e.last_event_ms orelse return 0;
    return e.last_quiet_ms + (now_ms -| since);
}

/// Whether anything has ever sampled this terminal. A caller that can say
/// "not known" should say that rather than pass `quietMs`'s zero on as a
/// measurement.
pub fn observed(self: *const Bus, id: Id) bool {
    const e = self.entries.get(id) orelse return false;
    return e.last_event_ms != null;
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

    // A supervisor is not watched, by anyone including itself.
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

    var it = self.entries.iterator();
    while (it.next()) |kv| {
        const other = kv.value_ptr;
        if (other.watched_by == id) {
            other.watched_by = null;
            if (other.role == .watched) other.role = .none;
        }
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
/// `by` is null when the user did it from the keyboard and no supervisor
/// has claimed it -- the terminal is watched and its notices go to
/// whoever claims it, which for one supervisor is the obvious answer and
/// for none is nobody.
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
}

pub const WatchError = error{
    /// Another supervisor is already minding this terminal.
    AlreadyWatched,
} || Allocator.Error;

/// Stop watching a terminal, without forgetting it.
pub fn unwatch(self: *Bus, id: Id) void {
    if (self.entries.getPtr(id)) |e| {
        if (e.role == .watched) e.role = .none;
        e.watched_by = null;
    }
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

    if (e.role != .watched) return false;

    // A terminal that has clocked off is supposed to be quiet. Saying so
    // again every quarter of an hour is exactly the kind of nagging that
    // makes someone turn the whole thing off.
    if (e.duty == .off) return false;

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
        };
    }
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
        .supervisor => .supervisor,
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

pub fn drain(self: *Bus, to: Id, now_ms: u64, buf: []u8) ?[]u8 {
    return self.take(to, now_ms, buf, .consume);
}

/// The box belonging to one supervisor.
///
/// Filtered by who is minding each terminal: with two supervisors on two
/// pieces of work, a shared box would hand each of them the other's
/// reports -- twice the interruption and half of it about terminals they
/// cannot even read.
pub fn take(self: *Bus, to: Id, now_ms: u64, buf: []u8, how: Take) ?[]u8 {
    // Only a supervisor has a box. Said here rather than left to the
    // caller, because the rule below hands an unclaimed terminal's report
    // to whoever is asking -- so a terminal that has just stood down would
    // otherwise keep being handed exactly the reports it stopped being
    // responsible for, which is the one thing standing down is for.
    const minder = self.entries.get(to) orelse return null;
    if (minder.role != .supervisor) return null;

    var listed: usize = 0;
    var total: usize = 0;

    // Written into a fixed buffer with a running end, because the whole
    // point is to produce one line for one injection.
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("[poltergeist]") catch return null;

    var it = self.entries.iterator();
    while (it.next()) |kv| {
        const e = kv.value_ptr;
        const kind = e.pending orelse continue;

        // Not this supervisor's terminal. Left in the box for whoever is
        // minding it, rather than dropped.
        const owner = e.watched_by orelse to;
        if (owner != to) continue;

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

        if (listed >= max_listed) continue;

        const sep = if (listed == 0) " " else ", ";
        const written = switch (kind) {
            .quiescent, .still_quiescent => w.print(
                "{s}0x{x:0>16} quiet {d}s",
                .{ sep, kv.key_ptr.*, self.quietMs(kv.key_ptr.*, now_ms) / std.time.ms_per_s },
            ),
            .resumed => w.print(
                "{s}0x{x:0>16} back at work",
                .{ sep, kv.key_ptr.* },
            ),
        };

        // Out of room. What is written already stands, and the rest is
        // covered by the count below. The `pending` flags are cleared
        // either way: they have been accounted for.
        written catch break;
        listed += 1;
    }

    if (total == 0) return null;
    if (total > listed) {
        w.print(" (+{d} more)", .{total - listed}) catch {};
    }

    return w.buffered();
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
pub fn drainIfDue(self: *Bus, to: Id, now_ms: u64, buf: []u8) ?[]u8 {
    const minder = self.entries.getPtr(to) orelse return null;
    if (minder.last_delivery_ms) |last| {
        if (now_ms -| last < self.config.notice_interval_ms) return null;
    }

    const line = self.take(to, now_ms, buf, .hand_over) orelse return null;

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

test "an unclaimed terminal reports to whoever is asking" {
    // Watching from the keyboard leaves the terminal with no owner: which
    // supervisor should mind it is not something a keybind can say. Its
    // reports go to whoever reads the box.
    //
    // With one supervisor that is simply right. With several it is
    // arbitrary -- but the alternative is a terminal the user explicitly
    // watched whose reports go nowhere at all, and silence that the user
    // asked for is worse than an answer given to the wrong reader.
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, null);
    _ = b.report(worker, quiet(60_000), 0);

    var buf: [255]u8 = undefined;
    const line = b.drain(boss, 1_000, &buf) orelse return error.ExpectedANotice;
    try testing.expect(std.mem.indexOf(u8, line, "quiet") != null);
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
    try testing.expect(b.drain(second, 1_000, &buf) == null);

    // Still waiting for the one whose terminal it is.
    var buf2: [255]u8 = undefined;
    try testing.expect(b.drain(boss, 1_000, &buf2) != null);
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
    const line = b.drain(boss, 100, &buf) orelse return error.ExpectedANotice;
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
    const first = bus.drain(boss, 1000, &buf) orelse return error.ExpectedANotice;
    try testing.expect(std.mem.indexOf(u8, first, "0x0000000000002222") != null);
    try testing.expect(std.mem.indexOf(u8, first, "quiet") != null);

    // Nothing new has happened, so there is nothing to say.
    try testing.expect(bus.drain(boss, 2000, &buf) == null);
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
    const line = bus.drain(boss, t, &buf) orelse return error.ExpectedANotice;

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
    const line = bus.drain(boss, 3000, &buf) orelse return error.ExpectedANotice;
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
    try testing.expect(bus.drain(boss, 1000, &buf) == null);
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
    const line = bus.drain(boss, 1000, &buf) orelse return error.ExpectedANotice;
    try testing.expect(std.mem.indexOf(u8, line, "(+3 more)") != null);

    // Counted or listed, every one of them was consumed.
    try testing.expect(bus.drain(boss, 1000, &buf) == null);
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
    const line = bus.drain(boss, 1000 + 30_000, &buf) orelse return error.ExpectedANotice;
    try testing.expect(std.mem.indexOf(u8, line, "quiet 90s") != null);
}

test "a terminal the supervisor never watched is not in the box" {
    var bus = testBus();
    defer bus.deinit();

    try bus.addSupervisor(boss);
    try bus.register(worker);
    _ = bus.report(worker, quiet(60_000), 1000);

    var buf: [255]u8 = undefined;
    try testing.expect(bus.drain(boss, 1000, &buf) == null);
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
    const first = b.take(boss, 1_000, &buf, .hand_over) orelse return error.NothingToSay;
    try testing.expect(std.mem.indexOf(u8, first, "quiet") != null);

    var buf2: [512]u8 = undefined;
    const second = b.take(boss, 2_000, &buf2, .hand_over) orelse return error.NothingToSay;
    try testing.expect(std.mem.indexOf(u8, second, "quiet") != null);
}

test "the supervisor reading the box clears it, because that is arrival" {
    var b = testBus();
    defer b.deinit();

    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    _ = b.report(worker, quiet(200_000), 1_000);

    var buf: [512]u8 = undefined;
    _ = b.take(boss, 1_000, &buf, .consume) orelse return error.NothingToSay;

    // Nothing left: what it read, it has.
    var buf2: [512]u8 = undefined;
    try testing.expect(b.take(boss, 2_000, &buf2, .consume) == null);
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
    while (b.take(boss, at, &buf, .hand_over) != null) : (at += 1_000) {
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
    try testing.expect(b.drainIfDue(boss, 1000, &buf) != null);

    b.unwatch(worker);
    try b.standDown(boss);

    // Nothing is delivered to a terminal that is no longer minding anyone,
    // whatever is in the box.
    _ = b.report(worker, quiet(300_000), 200_000);
    try testing.expect(b.drainIfDue(boss, 200_000, &buf) == null);
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
