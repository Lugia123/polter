//! Every sentence the three plugin tools hand back.
//!
//! Pure functions over plain arguments: no `App`, no `*Resident`, nothing but
//! the allocator that ends up owning the result. The wording **is** the whole
//! of what this file does -- an agent reads these sentences and acts on what
//! they say -- so it has to be comparable against the two tables in
//! `dev-docs/poltergeist/mcp.md` that write the wording down.
//!
//! Which is why it is a file of its own rather than a few private functions
//! in `App.zig`: that file has no test block, and nothing in it is reachable
//! without an app to hang it off. A sentence written there could not be
//! proved, and an untested sentence drifts from the table it was copied out
//! of on the first edit that touches either one.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Plugin = @import("Plugin.zig");
const Resident = @import("Resident.zig");
const scrub = @import("scrub.zig");
const i18n = @import("../os/i18n.zig");
const ControlRoom = @import("ControlRoom.zig");

/// Everything about a resident plugin that decides what to say about it.
///
/// Flattened out of the app on purpose: the caller is the only thing that
/// can look these up, and the answer must be checkable without one.
pub const ResidentFacts = struct {
    key: []const u8,

    enabled: bool,

    /// Whether its manifest subscribed to anything at all. A plugin that
    /// subscribed to nothing has nothing to be handed and is never started.
    declares_events: bool,

    /// Whether it subscribed to `chat` and named no groups, which is a
    /// manifest that will be fed nothing it is waiting for. Not a reason to
    /// refuse it -- the same plugin may be subscribed to something else
    /// that works -- so it is said rather than enforced.
    groupless: bool = false,

    /// Whether the chat log has been opened, which happens on the first
    /// terminal. Before that nothing is recorded, so nothing is published
    /// to a plugin either: the seq a message is stored under is the one
    /// the record stamped on it.
    log_open: bool,

    /// The running copy, when there is one.
    status: ?Resident.Status = null,

    /// Its directory, when it sits in the bundle's plugin directory and the
    /// release's `SHIPPED` does not name it (task 1683): left over from
    /// another release. Null otherwise -- including when the bundle has no
    /// list, which is "cannot tell", not "shipped". **No default**: every
    /// caller says which, so a listing cannot leave it out by not knowing.
    stray: ?[]const u8,
};

/// Said after every branch of `residentStatus`, and after none of
/// `residentNote`'s -- a listing is not the place to re-argue the design.
const nothing_started =
    " Nothing was started for this: every plugin is resident, a second copy " ++
    "would subscribe and be handed every event all over again, and the protocol has " ++
    "no dry run for it to use instead.";

/// What `plugin_test` says about a plugin -- see `mcp.md` §2.5.
///
/// Nothing is started to produce this, and the sentence says so. Every
/// plugin is resident now; a second copy would be a second subscriber
/// handed everything twice, and the protocol has no dry run to offer
/// instead. So the answer to "does it work" is the running copy's own
/// account of itself.
pub fn residentStatus(alloc: Allocator, facts: ResidentFacts) Allocator.Error![]const u8 {
    return strayFirst(alloc, facts, try sentence(alloc, facts, nothing_started));
}

/// `why`, with what is said of a plugin this release did not ship put in
/// front of it when it is one (task 1683): that holds however the plugin is
/// doing, and it is loaded all the same. Takes `why` over: it is freed here
/// when a longer sentence takes its place.
fn strayFirst(alloc: Allocator, facts: ResidentFacts, why: []const u8) Allocator.Error![]const u8 {
    const path = facts.stray orelse return why;
    defer alloc.free(why);
    return std.fmt.allocPrint(
        alloc,
        "{s} is in the bundled plugins directory but is not part of this release " ++
            "-- probably left over from an older one unpacked over it. It is loaded " ++
            "all the same; delete {s} to remove it.{s}{s}",
        .{ facts.key, path, if (why.len > 0) " " else "", why },
    );
}

/// The short form of the same, for `plugin_list`'s `note`.
///
/// Empty when a copy is running and nothing is wrong, and the reason
/// otherwise. Same branches in the same order as `residentStatus`, so the
/// listing and the test can never disagree about why nothing is happening.
pub fn residentNote(alloc: Allocator, facts: ResidentFacts) Allocator.Error![]const u8 {
    const running = if (facts.status) |st| switch (st.state) {
        // Nothing is wrong in these two, and a note saying so would be a
        // line of noise on every plugin that is working.
        .feeding, .starting => true,
        .backing_off, .dormant, .stopped => false,
    } else false;
    const why = if (running) try alloc.dupe(u8, "") else try sentence(alloc, facts, "");

    // A plugin this release did not ship is said first, whether or not it is
    // working: it is loaded, and the person did not choose that (task 1683).
    return strayFirst(alloc, facts, why);
}

/// `residentNote` for a person rather than an agent (#1644): the settings
/// window's hover over a plugin's row.
///
/// **The note itself stays as it is**, English and addressed to an agent
/// ("plugin_configure with enabled: true switches it on") -- it is
/// `plugin_list`'s answer, and an agent must read the same words on every
/// machine. This is a second rendering of the same branch: a template the
/// host says in the person's language (`Localizable.strings`, `po/`), with
/// `{N}` filled by the same `fill` as the control room's `Say`. It is only
/// written into the document the settings window reads (`for_person`), so
/// `plugin_list` never carries it.
///
/// Null exactly where `residentNote` is empty, and the same branches in the
/// same order, so the hover and the listing cannot disagree about why.
pub const NoteSay = struct {
    key: Key,
    template: []const u8,
    /// Numbers in decimal; nothing here is translated.
    args: []const []const u8,

    pub const Key = enum {
        stray,
        switched_off,
        subscribes_to_nothing,
        no_groups,
        waiting_for_a_terminal,
        would_not_start,
        backing_off,
        dormant,
        stopped,
    };

    /// Said to the person looking at the plugin's row, so it names the
    /// switch on the page rather than a tool, and leaves out the design
    /// argument the agent's sentence carries.
    pub fn templateOf(key: Key) [:0]const u8 {
        return switch (key) {
            .stray => i18n.N_("Not part of this release: probably left over from an older one unpacked over it. It is loaded all the same; delete {1} to remove it."),
            .switched_off => i18n.N_("Switched off, so nothing is handed to it. Turn it on with the switch on its page."),
            .subscribes_to_nothing => i18n.N_("Its plugin.json subscribes to nothing, so it was not started. That is the plugin's own file to change."),
            .no_groups => i18n.N_("It subscribes to chat but names no groups, so it is running and will be handed nothing."),
            .waiting_for_a_terminal => i18n.N_("Switched on, but nothing runs it until a terminal is open."),
            .would_not_start => i18n.N_("Switched on, but it would not start. Polter's log says why."),
            .backing_off => i18n.N_("It failed to start {1} time(s) and will be tried again shortly. Polter's log has what it said."),
            .dormant => i18n.N_("It failed to start {1} time(s) and is now tried every fifteen minutes. Polter's log says why."),
            .stopped => i18n.N_("Stopped. It starts again when Polter does."),
        };
    }
};

pub fn residentNoteSay(alloc: Allocator, facts: ResidentFacts) Allocator.Error!?NoteSay {
    const say = struct {
        fn of(a: Allocator, key: NoteSay.Key, args: []const []const u8) Allocator.Error!NoteSay {
            const owned = try a.alloc([]const u8, args.len);
            for (args, owned) |src, *dst| dst.* = try a.dupe(u8, src);
            return .{ .key = key, .template = NoteSay.templateOf(key), .args = owned };
        }
    }.of;

    // First, as in `residentNote`: the one reason that holds however the
    // plugin is doing. The person's note says one thing; the agent's says
    // the rest after it.
    if (facts.stray) |path| return try say(alloc, .stray, &.{path});
    if (!facts.enabled) return try say(alloc, .switched_off, &.{});
    if (!facts.declares_events) return try say(alloc, .subscribes_to_nothing, &.{});
    if (facts.groupless) return try say(alloc, .no_groups, &.{});
    const st = facts.status orelse {
        if (!facts.log_open) return try say(alloc, .waiting_for_a_terminal, &.{});
        return try say(alloc, .would_not_start, &.{});
    };
    var buf: [20]u8 = undefined;
    const failures = std.fmt.bufPrint(&buf, "{d}", .{st.failures}) catch unreachable;
    return switch (st.state) {
        .feeding, .starting => null,
        .backing_off => try say(alloc, .backing_off, &.{failures}),
        .dormant => try say(alloc, .dormant, &.{failures}),
        .stopped => try say(alloc, .stopped, &.{}),
    };
}

/// The one body of branches both of the above read out of.
fn sentence(
    alloc: Allocator,
    facts: ResidentFacts,
    tail: []const u8,
) Allocator.Error![]const u8 {
    if (!facts.enabled) return std.fmt.allocPrint(
        alloc,
        "{s} is installed but switched off, so nothing is being handed to it. " ++
            "plugin_configure with enabled: true switches it on.{s}",
        .{ facts.key, tail },
    );

    if (!facts.declares_events) return std.fmt.allocPrint(
        alloc,
        "{s} subscribes to nothing in its plugin.json, so it was not started. " ++
            "It needs \"wants\": {{\"events\": [\"chat\"]}} or whichever events it " ++
            "is for -- that is the plugin's own file, not a setting, so it is the " ++
            "user's to edit.{s}",
        .{ facts.key, tail },
    );

    if (facts.groupless) return std.fmt.allocPrint(
        alloc,
        "{s} subscribes to chat but names no groups, so it is running and will be " ++
            "handed nothing. It needs \"wants\": {{\"groups\": [\"*\"]}} beside its " ++
            "events -- the plugin's own file, so it is the user's to edit.{s}",
        .{ facts.key, tail },
    );

    const st = facts.status orelse {
        if (!facts.log_open) return std.fmt.allocPrint(
            alloc,
            "{s} is switched on but nothing is running it yet: the chat log has not " ++
                "been opened, which happens once a terminal exists.{s}",
            .{ facts.key, tail },
        );

        // Not in the spec's table, and reachable: `Resident.start` fails on
        // a subscription or a thread it cannot make, and until now that
        // produced a `log.warn` nobody reads and a plugin that looked
        // switched on and did nothing.
        return std.fmt.allocPrint(
            alloc,
            "{s} is switched on and the log is open, but no copy of it is running: " ++
                "it would not start, and Polter's log says why.{s}",
            .{ facts.key, tail },
        );
    };

    // Exhaustive over `Resident.State` on purpose: a sixth state added there
    // stops this compiling, rather than shipping a plugin that reports
    // nothing about itself.
    return switch (st.state) {
        .feeding => std.fmt.allocPrint(
            alloc,
            "{s} is feeding, has confirmed up to seq {d}, and has been restarted " ++
                "{d} time(s) since the last child that settled.{s}",
            .{ facts.key, st.cursor, st.failures, tail },
        ),

        .starting => std.fmt.allocPrint(
            alloc,
            "{s} is starting: a child has been spawned and has not answered the " ++
                "handshake yet.{s}",
            .{ facts.key, tail },
        ),

        .backing_off => std.fmt.allocPrint(
            alloc,
            "{s} is backing off after {d} failed start(s); it has confirmed up to " ++
                "seq {d}. Its stderr is in Polter's log; that is where it says why.{s}",
            .{ facts.key, st.failures, st.cursor, tail },
        ),

        .dormant => std.fmt.allocPrint(
            alloc,
            "{s} is dormant: it failed to start {d} time(s) and is now retried every " ++
                "fifteen minutes. Whatever it complained about is in Polter's log.{s}",
            .{ facts.key, st.failures, tail },
        ),

        .stopped => std.fmt.allocPrint(
            alloc,
            "{s} has stopped and will not be started again until Polter is.{s}",
            .{ facts.key, tail },
        ),
    };
}

/// What became of a plugin over the course of a configure.
///
/// Decided by the caller rather than worked out here, because only the app
/// can start one and only the app knows whether it did.
pub const Started = enum {
    /// It subscribes to nothing, so there was never anything to start.
    subscribes_to_nothing,

    /// A copy was already resident, and a second one is exactly what must
    /// not happen.
    already_running,

    /// This call started one.
    started_now,

    /// It should be running and is not. The caller appends `residentNote`,
    /// so the reason is never written out twice.
    not_started,
};

/// Whether a provisioning plugin this call started was told what Polter is
/// (#1673). It subscribes after the run's one `provision` event went by,
/// so "being fed the events as they happen" was true of the feed and false
/// of the outcome: nothing would happen until the next restart.
pub const Provision = enum {
    /// Not a provisioning plugin, or this call did not start it.
    none,

    /// Switched on now and handed the event at once: it registers now.
    handed,

    /// Running with changed settings, so it was restarted and handed the
    /// event again: the change is applied now, not at the next start.
    restarted,

    /// Polter has not registered its tools in this run, so there was
    /// nothing to hand it -- the same thing every provisioning plugin gets.
    withheld,

    /// It was meant to be handed and could not be; Polter's log says why.
    failed,
};

/// What a configure has to do about provisioning, once it knows how the
/// plugin stands. Pulled out of `App.configurePlugin` so the decision can be
/// tested without an `App`: the wiring around it is one call each way.
pub const ProvisionStep = enum {
    /// Nothing: not a provisioning plugin, or this call did not start it.
    none,
    /// Hand it this run's event, to it alone.
    hand,
    /// Started, but Polter has not registered in this run, so there is no
    /// event to hand anybody yet; `ensureMcpRegistered` will hand it one
    /// with everybody else's.
    withhold,
};

pub fn provisionStep(provisions: bool, started: Started, registered: bool) ProvisionStep {
    if (!provisions or started != .started_now) return .none;
    return if (registered) .hand else .withhold;
}

/// Whether a configure restarts a running plugin so that it acts on what
/// was just written (#1673). Only a provisioning plugin: its one event of
/// the run has gone by, so the running copy will never act on the new
/// settings, and restarting costs it nothing it keeps. An archive would
/// lose its queue, and keeps the "next time Polter starts" answer.
///
/// `same_params` rather than "parameters were sent": the settings window
/// sends its whole form on every save.
pub fn restartsForSettings(provisions: bool, enabled: bool, same_params: bool) bool {
    return provisions and enabled and !same_params;
}

/// Whether a plugin waits for Polter to restart: a copy is running, and
/// what is saved now is not what it was started with -- switched off since,
/// or a parameter other than it was (#1697).
///
/// `running` is the running copy's own parameters (`Resident.params`), null
/// when no copy runs. **Asked of the core because only the core knows.**
/// Each host used to keep its own copy of "the settings at launch", and
/// learned of a save only when it made the save itself: a plugin switched
/// on through `plugin_configure` was started with what was saved and still
/// showed "restart to apply" on Windows until the window saved it again,
/// and a change an agent made under a running copy never showed on macOS.
///
/// A value left empty and a value never written are the same thing --
/// `merge` writes neither, and a hand-written file may hold either.
pub fn restartPending(running: ?[]const Plugin.Param, now: Plugin.Settings) bool {
    const started_with = running orelse return false;
    if (!now.enabled) return true;
    return !sameValues(started_with, now.params) or !sameValues(now.params, started_with);
}

/// Every non-empty value in `a` is in `b` with the same value.
fn sameValues(a: []const Plugin.Param, b: []const Plugin.Param) bool {
    outer: for (a) |mine| {
        if (mine.value.len == 0) continue;
        for (b) |theirs| {
            if (!std.mem.eql(u8, mine.name, theirs.name)) continue;
            if (!std.mem.eql(u8, mine.value, theirs.value)) return false;
            continue :outer;
        }
        return false;
    }
    return true;
}

/// What `plugin_configure` says about when a change takes hold -- §2.6.
///
/// There is no `kind` to branch on any more, and the three sentences it
/// used to pick between were three ways of saying one thing: **a plugin
/// reads its settings when its child starts, and its child starts once.**
/// The old `notify` branch was the only one that could honestly say "live
/// now", and it could say it because a notification forked a fresh process
/// every time. Nothing does that any more, so nothing says it any more.
pub fn configured(
    alloc: Allocator,
    key: []const u8,
    /// Whether this call switched it on.
    switched_on: bool,
    /// Whether any parameter was written.
    params_written: bool,
    started: Started,
    provision: Provision,
) Allocator.Error![]const u8 {
    const what = if (switched_on and params_written)
        try std.fmt.allocPrint(alloc, "{s} is switched on and its settings are written", .{key})
    else if (switched_on)
        try std.fmt.allocPrint(alloc, "{s} is switched on", .{key})
    else if (params_written)
        try std.fmt.allocPrint(alloc, "{s}'s settings are written", .{key})
    else
        // The dispatch layer refuses a call that asks for nothing, so this
        // is unreachable from the tool surface -- but a sentence that says
        // nothing changed is still better than an empty reply.
        try std.fmt.allocPrint(alloc, "nothing about {s} was changed", .{key});
    defer alloc.free(what);

    // Exhaustive over `Started`, so a fifth outcome has to be given a
    // sentence rather than falling into whichever one an `else` named.
    return switch (started) {
        .already_running => std.fmt.allocPrint(
            alloc,
            "{s}. {s} is already running with the settings it started with. " ++
                "Nothing was restarted -- a second copy would be handed every event " ++
                "twice -- so this takes effect the next time Polter starts.",
            .{ what, key },
        ),

        // Exhaustive over `Provision` too: "being fed" is the one sentence
        // a provisioning plugin must not get, because its only event has
        // already happened.
        .started_now => switch (provision) {
            .none => std.fmt.allocPrint(
                alloc,
                "{s}. {s} is now being fed the events it subscribed to, as they happen.",
                .{ what, key },
            ),
            .handed => std.fmt.allocPrint(
                alloc,
                "{s}. {s} is running and has just been handed what Polter is, so it " ++
                    "registers Polter with its CLI now; its own log says what it did.",
                .{ what, key },
            ),
            .restarted => std.fmt.allocPrint(
                alloc,
                "{s}. {s} was restarted with these settings and handed what Polter is " ++
                    "again, so the change is applied now; its own log says what it did.",
                .{ what, key },
            ),
            .withheld => std.fmt.allocPrint(
                alloc,
                "{s}. {s} is running, but Polter has not registered its tools in this " ++
                    "run (poltergeist-register-mcp is off, or no terminal has opened yet), " ++
                    "so it has been handed nothing and has registered nothing.",
                .{ what, key },
            ),
            .failed => std.fmt.allocPrint(
                alloc,
                "{s}. {s} is running, but it could not be handed what Polter is, so it " ++
                    "has registered nothing; Polter's log says why.",
                .{ what, key },
            ),
        },

        .subscribes_to_nothing => std.fmt.allocPrint(
            alloc,
            "{s}. It subscribes to no events, so nothing was started for it and " ++
                "nothing will be: what a plugin is handed comes from \"wants\": " ++
                "{{\"events\": [...]}} in its own plugin.json.",
            .{what},
        ),

        // The caller appends `residentNote`, so why it is not running is
        // said in one place and never written out twice.
        .not_started => std.fmt.allocPrint(alloc, "{s}.", .{what}),
    };
}

/// The longest a message put on somebody's screen may be.
///
/// `apprt.surface.Message.poltergeist_alert` is a fixed 255 bytes plus a
/// NUL, and a sentence that gets chopped is worse than a shorter one that
/// was written to fit.
pub const max_alert = 254;

/// Why a plugin is being reported to the person at the keyboard.
pub const Trouble = enum {
    /// It has just stopped working, having either never started or been
    /// running until now. **This is the startup failure**, and it is the
    /// one the user asked for by name.
    stopped,

    /// It has failed so many times in a row that it is now only retried
    /// every quarter of an hour. Strictly worse news than `stopped`, and a
    /// different fact: it is not coming back on its own any time soon.
    dormant,
};

/// What a plugin's failure costs the user, said on their own screen.
///
/// **This has to reach the person, not the agent.** What fails when a
/// plugin fails is, depending on what it subscribed to, the agent's tool
/// surface or the user's own channel of being told anything -- and in the
/// first case the agent is precisely the party that cannot be told about
/// it. `plugin_list` carries the same facts for an agent that thinks to
/// ask; this is the half that arrives without being asked for.
///
/// **Says the consequence, not only the fault.** "chat-archive failed"
/// leaves the reader to work out that the missing notifications they will
/// not get tonight are this. The consequence comes out of `wants.events`,
/// which is the only thing that says what a plugin is for.
///
/// Truncated to fit the message that carries it. The variable parts are a
/// key (at most 64 plain characters) and a count, so it is close to
/// constant-length by construction; the clamp is the belt.
pub fn alert(
    alloc: Allocator,
    key: []const u8,
    wants: Plugin.Wants,
    why: Trouble,
    /// How many times in a row it has failed.
    failures: u32,
) Allocator.Error![]const u8 {
    return alertIn(alloc, english, key, wants, why, failures);
}

/// Looks a msgid up. `interface` for the line that goes on a screen,
/// `english` where the words are compared or read by an agent.
pub const Tr = *const fn (msgid: [:0]const u8) []const u8;

/// The msgid itself: the English every template is written in.
pub fn english(msgid: [:0]const u8) []const u8 {
    return msgid;
}

/// The msgid in the interface's language -- the one the core was started
/// in (`LANG`, which both apps set from their own language choice), as
/// every other word the core prints into a terminal (`ControlFix`).
pub fn interface(msgid: [:0]const u8) []const u8 {
    return std.mem.span(i18n._(msgid.ptr));
}

/// `alert` in the language `tr` gives.
///
/// **The line is printed on the person's screen, so it is in their
/// language** (task 1663: an English line in a Chinese window, on the
/// Windows test machine; the macOS app prints the same line). Every piece
/// is a whole template with `{N}` for what varies, so a translator sees a
/// sentence and can move the key and the count wherever their grammar puts
/// them; `fitMiddle` still gets the same three parts and still gives up the
/// middle first.
pub fn alertIn(
    alloc: Allocator,
    tr: Tr,
    key: []const u8,
    wants: Plugin.Wants,
    why: Trouble,
    failures: u32,
) Allocator.Error![]const u8 {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fill = ControlRoom.Say.fill;

    // Every subscription this build knows, so a fourth one added to
    // `Plugin.Event` has to be given a consequence here rather than
    // silently producing a sentence that names no cost at all.
    var cost: ?[]const u8 = null;
    for (std.enums.values(Plugin.Event)) |e| {
        if (!wants.subscribes(e)) continue;
        const this = tr(switch (e) {
            .provision => i18n.N_("an agent started here has no Polter tools"),
            .terminal_quiet => i18n.N_("nothing will tell you when a terminal needs you"),
            .chat => i18n.N_("the extra copy of the chat is not being written"),
        });
        cost = if (cost) |before|
            try fill(arena, tr(i18n.N_("{1}, and {2}")), &.{ before, this })
        else
            this;
    }

    // A plugin that subscribes to nothing is never started, so this cannot
    // be reached from the resident loop -- but a sentence that names no
    // consequence at all is still better than an empty screen.
    const said_cost = cost orelse tr(i18n.N_("it is not doing what it was installed to do"));

    var count_buf: [10]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d}", .{failures}) catch unreachable;

    // Which plugin, what it costs, and what to do or where to look: the
    // three parts, so a sentence too long for the screen loses the middle
    // and keeps the end.
    const head = switch (why) {
        .stopped => try fill(arena, tr(i18n.N_("polter: the \"{1}\" plugin is not running")), &.{key}),
        .dormant => try fill(
            arena,
            tr(i18n.N_("polter: the \"{1}\" plugin has failed {2} times and is now only retried every fifteen minutes")),
            &.{ key, count },
        ),
    };
    const so_cost = try fill(arena, tr(i18n.N_(", so {1}")), &.{said_cost});
    const tail = switch (why) {
        .stopped => tr(i18n.N_(". It is being retried; what it complained about is in Polter's log.")),
        .dormant => try fill(arena, tr(i18n.N_(". Its settings are in $XDG_CONFIG_HOME/polter/plugins/{1}.json")), &.{key}),
    };

    return fitMiddle(alloc, head, so_cost, tail);
}

const ellipsis = "…";

/// `head ++ middle ++ tail`, in at most `max_alert` bytes, by shortening
/// **the middle** at a word.
///
/// The clamp used to take the end off the whole sentence, and the end is
/// where it says what to do -- "what it complained about is in Polter's
/// log", "its settings are in …" -- so the one plugin whose consequences
/// ran long lost exactly that half, mid-word (task 1541, the test machine).
/// When the head and tail leave the middle less than `min_middle` --
/// `dormant` names a long key twice -- the middle keeps that much, at a
/// word, and the head gives way after it at a word of its own: the plugin's
/// name is at the head's start, the consequence begins in the middle, and
/// the end is still whole. Only a tail with no room beside it is cut itself.
fn fitMiddle(alloc: Allocator, head: []const u8, middle: []const u8, tail: []const u8) Allocator.Error![]const u8 {
    const min_middle = 32;
    if (head.len + middle.len + tail.len <= max_alert)
        return std.mem.concat(alloc, u8, &.{ head, middle, tail });
    const fixed = head.len + tail.len + ellipsis.len;
    if (fixed + @min(middle.len, min_middle) > max_alert) {
        const mid = middle[0..cutAtWord(middle, min_middle)];
        const rest = tail.len + mid.len + 2 * ellipsis.len;
        if (rest < max_alert) {
            const kept = head[0..cutAtWord(head, max_alert - rest)];
            return std.mem.concat(alloc, u8, &.{ kept, ellipsis, mid, ellipsis, tail });
        }
        const whole = try std.mem.concat(alloc, u8, &.{ head, middle, tail });
        defer alloc.free(whole);
        return clampAtWord(alloc, whole);
    }
    const kept = middle[0..cutAtWord(middle, max_alert - fixed)];
    return std.mem.concat(alloc, u8, &.{ head, kept, ellipsis, tail });
}

/// `text` in at most `max_alert` bytes: whole, or cut at a word with `…`.
fn clampAtWord(alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (text.len <= max_alert) return alloc.dupe(u8, text);
    const kept = text[0..cutAtWord(text, max_alert - ellipsis.len)];
    return std.mem.concat(alloc, u8, &.{ kept, ellipsis });
}

/// Where to cut `text` to at most `max` bytes: before the last space that
/// fits, with the spaces before it dropped, so no word is left in half.
/// Text with no space to cut at -- a long word, a language written without
/// them -- is cut on a codepoint boundary, as `scrub.cut` does: half a UTF-8
/// sequence on a screen is a replacement character where a word should be.
fn cutAtWord(text: []const u8, max: usize) usize {
    if (text.len <= max) return text.len;
    const at = scrub.cut(text, max);
    // `text[at]` is the first byte left out: a space there means the cut
    // already falls between words.
    if (text[at] == ' ') return std.mem.trimEnd(u8, text[0..at], " ").len;
    const space = std.mem.lastIndexOfScalar(u8, text[0..at], ' ') orelse return at;
    const before = std.mem.trimEnd(u8, text[0..space], " ").len;
    return if (before == 0) at else before;
}

/// What the plugin itself asked to have said, on the user's own screen.
///
/// The plugin wrote `{"tell":"..."}` on the same standard output it answers
/// on, and this is the sentence that carries it. It arrives by the path
/// `alert` above arrives by, because it is the same fact from the other
/// side: "the claude-code plugin could not write the skill file" and "the
/// claude-code plugin will not start" are both things the person at the
/// keyboard has to know and neither is something an agent can be told.
///
/// **Three things happen to the plugin's words, and all three are the
/// host's doing rather than the plugin's:**
///
/// 1. They are scrubbed. This text is about to be *printed onto a
///    terminal*, and a terminal is an interpreter: unfiltered, a plugin
///    could move the cursor, repaint the screen, or draw something that
///    reads as Polter itself asking for a password. `scrub.zig` holds the
///    table and the argument, which is `src/input/paste.zig`'s.
/// 2. They are clamped, on a codepoint boundary, by the same rule and to
///    the same 254 bytes as everything else that goes on a screen.
/// 3. They are **attributed**. The frame is written here and cannot be
///    written by the plugin, so a line can say what it likes and still
///    cannot claim to be Polter speaking.
///
/// **On wording: the plugin is asked to name the consequence and is not
/// made to.** `alert` above forces the consequence because the host
/// *computes* it, out of `wants.events`, and can therefore be exhaustive
/// about it -- it is Polter's own sentence. Here the sentence is the
/// plugin's, and the host has no way to check that a string names a
/// consequence: any check would be a heuristic over English, it would pass
/// "failed" and reject "could not write the skill, so the agent will have
/// no memory of this", and a heuristic that is wrong in both directions is
/// worse than no check because it would be trusted. So the obligation is
/// written down for plugin authors -- who know their own consequences far
/// better than the host does, and are likelier than the host to report only
/// the fault -- and is documented as unenforced rather than pretended at.
/// What the host does supply without guessing is the half it does know: who
/// said this.
pub fn told(
    alloc: Allocator,
    key: []const u8,
    /// The plugin's own words. Anything at all: this is untrusted.
    text: []const u8,
) Allocator.Error![]const u8 {
    const clean = try scrub.clean(alloc, text);
    defer alloc.free(clean);

    const whole = try std.fmt.allocPrint(
        alloc,
        "polter: the \"{s}\" plugin says: {s}",
        .{ key, clean },
    );
    if (whole.len <= max_alert) return whole;

    defer alloc.free(whole);
    // At a word, and said to be cut: the plugin's sentence is the plugin's,
    // and the end it lost is not ours to guess at.
    return clampAtWord(alloc, whole);
}

/// What `plugin_test` says about a plugin subscribed to `terminal.quiet`.
///
/// A switched-off plugin is tested all the same and told about: refusing
/// would block the obvious order of operations -- prove it works, then
/// switch it on -- and a passing test on a channel nobody will call is a
/// fact the supervisor needs said rather than implied.
///
/// **This no longer reports a delivery**, and the sentence has to be honest
/// about that rather than sounding like the old one. A notification used to
/// be a fork whose exit code was the answer; it is an event on a stream
/// now, picked up by a resident plugin on its own thread. What can be said
/// at the moment of the call is: it went out, how many channels asked for
/// it, and whether this particular plugin has a child up to receive it.
/// The last of those is the one the old test could not answer at all -- it
/// proved a fork worked at that instant and said nothing about the night it
/// was needed.
pub fn tested(
    alloc: Allocator,
    key: []const u8,
    enabled: bool,
    /// How many plugins subscribed to `terminal.quiet`.
    channels: usize,
    /// This plugin's own resident, when one is running.
    status: ?Resident.Status,
) Allocator.Error![]const u8 {
    const off = if (enabled)
        ""
    else
        " It is switched off, so nothing else will be sent through it.";

    const st = status orelse return std.fmt.allocPrint(
        alloc,
        "a test notification was published to {d} channel(s), but no copy of {s} is " ++
            "running to receive it, so it did not go out through this one. " ++
            "plugin_list says why.{s}",
        .{ channels, key, off },
    );

    // Exhaustive over `Resident.State`: a state added there has to be given
    // a sentence rather than shipping a test that reports nothing.
    return switch (st.state) {
        .feeding, .starting => std.fmt.allocPrint(
            alloc,
            "a test notification was published to {d} channel(s), and {s} is running " ++
                "and being fed. It delivers on its own thread, so this is not a " ++
                "delivery receipt: if it does not reach you, the plugin is where to " ++
                "look, and its stderr is in Polter's log.{s}",
            .{ channels, key, off },
        ),

        .backing_off, .dormant => std.fmt.allocPrint(
            alloc,
            "a test notification was published to {d} channel(s), but {s} is {t}: it " ++
                "has failed to start {d} time(s) and is not receiving anything. Do not " ++
                "expect this one to arrive.{s}",
            .{ channels, key, st.state, st.failures, off },
        ),

        .stopped => std.fmt.allocPrint(
            alloc,
            "a test notification was published to {d} channel(s), but {s} has stopped " ++
                "and will not be started again until Polter is.{s}",
            .{ channels, key, off },
        ),
    };
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "the hover says the same branch as the note, in a person's words, and only when the note does" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base: ResidentFacts = .{ .key = "codex", .enabled = true, .declares_events = true, .log_open = true, .stray = null };

    // Off: a sentence for the switch, and no tool in it.
    var facts = base;
    facts.enabled = false;
    const off = (try residentNoteSay(a, facts)).?;
    try testing.expectEqual(NoteSay.Key.switched_off, off.key);
    try testing.expect(std.mem.indexOf(u8, off.template, "plugin_configure") == null);
    try testing.expect((try residentNote(a, facts)).len > 0);

    // Running and well: no note, so no hover.
    facts = base;
    facts.status = .{ .state = .feeding, .cursor = 4, .failures = 0 };
    try testing.expect(try residentNoteSay(a, facts) == null);
    try testing.expectEqualStrings("", try residentNote(a, facts));

    // A count goes in as an argument, said in decimal.
    facts.status = .{ .state = .dormant, .cursor = 4, .failures = 7 };
    const dormant = (try residentNoteSay(a, facts)).?;
    try testing.expectEqual(NoteSay.Key.dormant, dormant.key);
    try testing.expectEqual(@as(usize, 1), dormant.args.len);
    try testing.expectEqualStrings("7", dormant.args[0]);

    // Every branch the note has, the hover has, in the same order.
    facts = base;
    facts.declares_events = false;
    try testing.expectEqual(NoteSay.Key.subscribes_to_nothing, (try residentNoteSay(a, facts)).?.key);
    facts = base;
    facts.groupless = true;
    try testing.expectEqual(NoteSay.Key.no_groups, (try residentNoteSay(a, facts)).?.key);
    facts = base;
    facts.log_open = false;
    try testing.expectEqual(NoteSay.Key.waiting_for_a_terminal, (try residentNoteSay(a, facts)).?.key);
    facts = base;
    try testing.expectEqual(NoteSay.Key.would_not_start, (try residentNoteSay(a, facts)).?.key);
    facts.status = .{ .state = .backing_off, .cursor = 0, .failures = 2 };
    try testing.expectEqual(NoteSay.Key.backing_off, (try residentNoteSay(a, facts)).?.key);
    facts.status = .{ .state = .stopped, .cursor = 0, .failures = 0 };
    try testing.expectEqual(NoteSay.Key.stopped, (try residentNoteSay(a, facts)).?.key);
}

test "a plugin this release did not ship is said first, working or not, with its path" {
    const alloc = testing.allocator;
    const path = "/Applications/Polter.app/Contents/Resources/ghostty/polter/plugins/gemini";

    // Running and well, yet stray: the note is not empty, and says where.
    var facts: ResidentFacts = .{
        .key = "gemini",
        .enabled = true,
        .declares_events = true,
        .log_open = true,
        .status = .{ .state = .feeding, .cursor = 4, .failures = 0 },
        .stray = path,
    };
    const running = try residentNote(alloc, facts);
    defer alloc.free(running);
    try testing.expect(std.mem.startsWith(u8, running, "gemini is in the bundled plugins directory but is not part of this release"));
    try testing.expect(std.mem.indexOf(u8, running, path) != null);
    try testing.expect(std.mem.indexOf(u8, running, "loaded all the same") != null);

    // Off as well: both reasons, the stray first.
    facts.enabled = false;
    facts.status = null;
    const off = try residentNote(alloc, facts);
    defer alloc.free(off);
    const stray_at = std.mem.indexOf(u8, off, "not part of this release").?;
    const off_at = std.mem.indexOf(u8, off, "switched off").?;
    try testing.expect(stray_at < off_at);

    // The person's hover says the stray, with the path as its argument.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const say = (try residentNoteSay(arena.allocator(), facts)).?;
    try testing.expectEqual(NoteSay.Key.stray, say.key);
    try testing.expectEqual(@as(usize, 1), say.args.len);
    try testing.expectEqualStrings(path, say.args[0]);

    // `plugin_test` says it first too: the listing and the test cannot
    // disagree about it.
    const test_said = try residentStatus(alloc, facts);
    defer alloc.free(test_said);
    try testing.expect(std.mem.startsWith(u8, test_said, "gemini is in the bundled plugins directory but is not part of this release"));

    // Not stray: nothing of the kind is said.
    facts.stray = null;
    const plain = try residentNote(alloc, facts);
    defer alloc.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "not part of this release") == null);
}

test "a plugin is never started to test it" {
    const alloc = testing.allocator;

    // Every shape an archive can be in produces a sentence, and every one of
    // them says that nothing was started to produce it. That clause is the
    // whole answer to "why did you not just run it": it has to survive an
    // edit to any single branch.
    const shapes = [_]ResidentFacts{
        .{ .key = "chat-archive", .enabled = false, .declares_events = true, .log_open = true, .stray = null },
        .{ .key = "chat-archive", .enabled = true, .declares_events = false, .log_open = true, .stray = null },
        .{ .key = "chat-archive", .enabled = true, .declares_events = true, .log_open = false, .stray = null },
        .{ .key = "chat-archive", .enabled = true, .declares_events = true, .log_open = true, .stray = null },
        .{
            .key = "chat-archive",
            .enabled = true,
            .declares_events = true,
            .log_open = true,
            .stray = null,
            .status = .{ .state = .feeding, .cursor = 1049, .failures = 0 },
        },
        .{
            .key = "chat-archive",
            .enabled = true,
            .declares_events = true,
            .log_open = true,
            .stray = null,
            .status = .{ .state = .starting, .cursor = 0, .failures = 0 },
        },
        .{
            .key = "chat-archive",
            .enabled = true,
            .declares_events = true,
            .log_open = true,
            .stray = null,
            .status = .{ .state = .backing_off, .cursor = 12, .failures = 2 },
        },
        .{
            .key = "chat-archive",
            .enabled = true,
            .declares_events = true,
            .log_open = true,
            .stray = null,
            .status = .{ .state = .dormant, .cursor = 0, .failures = 9 },
        },
        .{
            .key = "chat-archive",
            .enabled = true,
            .declares_events = true,
            .log_open = true,
            .stray = null,
            .status = .{ .state = .stopped, .cursor = 5, .failures = 0 },
        },
    };

    for (shapes) |facts| {
        const said = try residentStatus(alloc, facts);
        defer alloc.free(said);

        try testing.expect(said.len > 0);
        try testing.expect(std.mem.indexOf(u8, said, "chat-archive") != null);
        try testing.expect(std.mem.indexOf(u8, said, "Nothing was started for this") != null);
        try testing.expect(std.mem.indexOf(u8, said, "second copy would subscribe and be handed every event") != null);
    }

    // The running copy's own account of itself is the answer, so the numbers
    // it keeps have to be in it.
    const feeding = try residentStatus(alloc, shapes[4]);
    defer alloc.free(feeding);
    try testing.expect(std.mem.indexOf(u8, feeding, "1049") != null);
}

test "a plugin that is switched off is reported as switched off" {
    const alloc = testing.allocator;

    // Switched off comes first, before anything about groups or a running
    // copy: a plugin that is off has no running copy by construction, and
    // saying "it is not running" without saying why would send the reader
    // looking in Polter's log for something that is not there.
    const facts: ResidentFacts = .{
        .key = "chat-archive",
        .enabled = false,
        .declares_events = false,
        .log_open = false,
        .stray = null,
    };

    const said = try residentStatus(alloc, facts);
    defer alloc.free(said);
    try testing.expect(std.mem.indexOf(u8, said, "switched off") != null);
    try testing.expect(std.mem.indexOf(u8, said, "plugin_configure with enabled: true") != null);

    // And a listing says the same thing, because a plugin that is off is
    // exactly what somebody reading a listing is asking about.
    const note = try residentNote(alloc, facts);
    defer alloc.free(note);
    try testing.expect(std.mem.indexOf(u8, note, "switched off") != null);

    // The listing does not re-argue the design; the test does.
    try testing.expect(std.mem.indexOf(u8, note, "Nothing was started") == null);
}

test "a plugin that would not start is not reported as running" {
    const alloc = testing.allocator;

    // Switched on, groups declared, log open, and still no copy: `start`
    // failed. This used to be a warning nobody reads, and the listing said
    // nothing at all -- which reads as "fine".
    const stuck: ResidentFacts = .{
        .key = "chat-archive",
        .enabled = true,
        .declares_events = true,
        .log_open = true,
        .stray = null,
        .status = null,
    };

    const note = try residentNote(alloc, stuck);
    defer alloc.free(note);
    try testing.expect(note.len > 0);
    try testing.expect(std.mem.indexOf(u8, note, "no copy of it is running") != null);

    // A healthy copy gets no note: the listing already carries its state,
    // and a sentence repeating it on every plugin that works is noise.
    for ([_]Resident.State{ .feeding, .starting }) |state| {
        const quiet = try residentNote(alloc, .{
            .key = "chat-archive",
            .enabled = true,
            .declares_events = true,
            .log_open = true,
            .stray = null,
            .status = .{ .state = state, .cursor = 3, .failures = 0 },
        });
        defer alloc.free(quiet);
        try testing.expectEqualStrings("", quiet);
    }

    // The three that are not fine do carry one, because a listing where
    // `state` is the only clue makes the reader look up what `dormant` means.
    for ([_]Resident.State{ .backing_off, .dormant, .stopped }) |state| {
        const said = try residentNote(alloc, .{
            .key = "chat-archive",
            .enabled = true,
            .declares_events = true,
            .log_open = true,
            .stray = null,
            .status = .{ .state = state, .cursor = 3, .failures = 4 },
        });
        defer alloc.free(said);
        try testing.expect(said.len > 0);
    }
}

test "a provisioning plugin started by a configure is handed the event, once Polter has registered" {
    try testing.expectEqual(ProvisionStep.hand, provisionStep(true, .started_now, true));
    try testing.expectEqual(ProvisionStep.withhold, provisionStep(true, .started_now, false));

    // Not started by this call: whatever is running already had its event,
    // or will be told why it is not running.
    for ([_]Started{ .already_running, .not_started, .subscribes_to_nothing }) |st| {
        try testing.expectEqual(ProvisionStep.none, provisionStep(true, st, true));
    }
    // Not a provisioning plugin: handed nothing extra, ever.
    try testing.expectEqual(ProvisionStep.none, provisionStep(false, .started_now, true));
}

test "only a provisioning plugin whose parameters changed is restarted" {
    try testing.expect(restartsForSettings(true, true, false));
    // The settings window re-sends an unchanged form: no restart.
    try testing.expect(!restartsForSettings(true, true, true));
    // Switched off: nothing to restart into.
    try testing.expect(!restartsForSettings(true, false, false));
    // An archive keeps its queue and its "next time Polter starts".
    try testing.expect(!restartsForSettings(false, true, false));
}

test "a restart is pending only when the running copy has other settings than are saved" {
    const x: []const Plugin.Param = &.{.{ .name = "url", .value = "x" }};
    const y: []const Plugin.Param = &.{.{ .name = "url", .value = "y" }};

    // #1697: switched on through `plugin_configure` and started with what
    // was saved -- the running copy has exactly that, nothing waits.
    try testing.expect(!restartPending(x, .{ .enabled = true, .params = x }));
    // No copy running: whatever starts next reads what is saved.
    try testing.expect(!restartPending(null, .{ .enabled = true, .params = y }));
    try testing.expect(!restartPending(null, .{ .enabled = false, .params = x }));

    // Changed under a running copy, by anybody: it waits.
    try testing.expect(restartPending(x, .{ .enabled = true, .params = y }));
    // Switched off under a running copy: it is still running.
    try testing.expect(restartPending(x, .{ .enabled = false, .params = x }));
    // A parameter added or removed is a change, in either direction.
    const xz: []const Plugin.Param = &.{ .{ .name = "url", .value = "x" }, .{ .name = "z", .value = "1" } };
    try testing.expect(restartPending(x, .{ .enabled = true, .params = xz }));
    try testing.expect(restartPending(xz, .{ .enabled = true, .params = x }));

    // Order does not matter, and blank is the same as absent.
    const zx: []const Plugin.Param = &.{ .{ .name = "z", .value = "1" }, .{ .name = "url", .value = "x" } };
    try testing.expect(!restartPending(xz, .{ .enabled = true, .params = zx }));
    const x_blank: []const Plugin.Param = &.{ .{ .name = "url", .value = "x" }, .{ .name = "z", .value = "" } };
    try testing.expect(!restartPending(x, .{ .enabled = true, .params = x_blank }));
    try testing.expect(!restartPending(x_blank, .{ .enabled = true, .params = x }));
}

test "a provisioning plugin started now is never told it is being fed as things happen" {
    // #1673: its one event happened before it existed, so that sentence
    // promised a registration that would only come at the next restart.
    const alloc = testing.allocator;
    for ([_]Provision{ .handed, .restarted, .withheld, .failed }) |p| {
        const said = try configured(alloc, "codex", true, false, .started_now, p);
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "as they happen") == null);
    }

    const handed = try configured(alloc, "codex", true, false, .started_now, .handed);
    defer alloc.free(handed);
    try testing.expect(std.mem.indexOf(u8, handed, "registers Polter with its CLI now") != null);

    const restarted = try configured(alloc, "codex", false, true, .started_now, .restarted);
    defer alloc.free(restarted);
    try testing.expect(std.mem.indexOf(u8, restarted, "applied now") != null);

    const withheld = try configured(alloc, "codex", true, false, .started_now, .withheld);
    defer alloc.free(withheld);
    try testing.expect(std.mem.indexOf(u8, withheld, "registered nothing") != null);
}

test "what a configure changes now and what waits for a restart" {
    const alloc = testing.allocator;

    // A plugin that subscribes to nothing was never going to run, and the
    // reply has to say that rather than "switched on" and nothing else --
    // that is the sentence a user reads after switching on a plugin whose
    // manifest still says `"kind"` and nothing about events.
    {
        const said = try configured(alloc, "webhook", true, true, .subscribes_to_nothing, .none);
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "subscribes to no events") != null);
        try testing.expect(std.mem.indexOf(u8, said, "wants") != null);
    }

    // One that is already running is not restarted, and the reply has to
    // say so: an agent that believed the new dsn was in effect would report
    // a database that is not being written to.
    {
        const said = try configured(alloc, "chat-archive", false, true, .already_running, .none);
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "next time Polter starts") != null);
        try testing.expect(std.mem.indexOf(u8, said, "handed every event twice") != null);
    }

    // Switching one on when no copy exists does start one, and that is live.
    {
        const said = try configured(alloc, "chat-archive", true, false, .started_now, .none);
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "now being fed") != null);
    }

    // When it did not start, this says only what was written: the caller
    // appends `residentNote`, so the reason is written once, in one place.
    {
        const said = try configured(alloc, "chat-archive", true, false, .not_started, .none);
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "switched on") != null);
        try testing.expect(std.mem.indexOf(u8, said, "now being fed") == null);
        try testing.expect(std.mem.indexOf(u8, said, "next time Polter starts") == null);
    }
}

test "a test that could not have arrived says so rather than saying nothing" {
    const alloc = testing.allocator;

    // Exhaustive over the states: a test whose answer is silence is worse
    // than no test at all, because silence reads as success.
    for (std.enums.values(Resident.State)) |state| {
        const said = try tested(alloc, "webhook", true, 2, .{
            .state = state,
            .cursor = 0,
            .failures = 3,
        });
        defer alloc.free(said);

        try testing.expect(said.len > 0);
        try testing.expect(std.mem.indexOf(u8, said, "webhook") != null);

        // None of them may read as a delivery. That is the whole change:
        // the host hands the event over and the plugin delivers later, so
        // there is no receipt to report and nothing here may imply one.
        try testing.expect(std.mem.indexOf(u8, said, "delivered it") == null);
    }

    // No copy running at all is the case the old fork-based test could not
    // even express -- the fork had already exited, so there was nothing to
    // ask about. It has to be said plainly: this one did not go out.
    {
        const said = try tested(alloc, "webhook", true, 1, null);
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "did not go out") != null);
    }

    // A plugin that is running but switched off is a fact the supervisor has
    // to be told, or it will wait for a notification that will never come.
    {
        const said = try tested(alloc, "webhook", false, 1, .{
            .state = .feeding,
            .cursor = 12,
            .failures = 0,
        });
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "switched off") != null);
    }
}

test "a plugin failure reaches the user, and says what it costs them" {
    const alloc = testing.allocator;

    // The whole point of this sentence: the consequence, not only the
    // fault. And the consequence comes out of what the plugin subscribed
    // to, which is the only thing that says what it is for.
    {
        const said = try alert(alloc, "claude-code", .{
            .events = &.{.provision},
        }, .stopped, 1);
        defer alloc.free(said);

        try testing.expect(std.mem.indexOf(u8, said, "claude-code") != null);
        try testing.expect(std.mem.indexOf(u8, said, "no Polter tools") != null);

        // It is being retried, and saying so is what stops the reader
        // going and restarting Polter for no reason.
        try testing.expect(std.mem.indexOf(u8, said, "retried") != null);
    }

    {
        const said = try alert(alloc, "feishu", .{
            .events = &.{.terminal_quiet},
        }, .stopped, 1);
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "when a terminal needs you") != null);
    }

    // Dormant is a different fact and has to read as one: it is not coming
    // back on its own any time soon, and here is the file to look in.
    {
        const said = try alert(alloc, "chat-archive", .{
            .events = &.{.chat},
            .groups = &.{"*"},
        }, .dormant, 11);
        defer alloc.free(said);

        try testing.expect(std.mem.indexOf(u8, said, "fifteen minutes") != null);
        try testing.expect(std.mem.indexOf(u8, said, "11") != null);
        try testing.expect(std.mem.indexOf(u8, said, "chat-archive.json") != null);
    }

    // Two subscriptions, two consequences. Under `Kind` a plugin had one
    // and only one thing it could be, so this sentence could not exist.
    {
        const said = try alert(alloc, "both", .{
            .events = &.{ .chat, .terminal_quiet },
            .groups = &.{"*"},
        }, .stopped, 1);
        defer alloc.free(said);

        try testing.expect(std.mem.indexOf(u8, said, "extra copy of the chat") != null);
        try testing.expect(std.mem.indexOf(u8, said, "when a terminal needs you") != null);
    }

    // Every subscription this build has must produce a consequence, and
    // every sentence must fit the message that carries it to the screen --
    // one that gets chopped is worse than a shorter one written to fit.
    for (std.enums.values(Plugin.Event)) |e| {
        for ([_]Trouble{ .stopped, .dormant }) |why| {
            const events = [_]Plugin.Event{e};
            const said = try alert(
                alloc,
                "a-plugin-with-a-name-of-exactly-sixty-four-characters-aaaaaaaaaaa",
                .{ .events = &events },
                why,
                999,
            );
            defer alloc.free(said);

            try testing.expect(said.len > 0);
            try testing.expect(said.len <= max_alert);

            // Never only the fault. Every one of them has to leave the
            // reader knowing what they lose by it.
            try testing.expect(std.mem.indexOf(u8, said, " so ") != null);
        }
    }
}

/// A catalogue for the test below: what `po/zh_CN.po` says for some of
/// `alertIn`'s msgids, and the msgid for the rest.
fn chineseForTest(msgid: [:0]const u8) []const u8 {
    const table = [_][2][]const u8{
        .{ "polter: the \"{1}\" plugin is not running", "polter：插件「{1}」没在跑" },
        .{ "an agent started here has no Polter tools", "在这里起的 agent 拿不到 Polter 的工具" },
        .{ ", so {1}", "，所以{1}" },
        .{ ". It is being retried; what it complained about is in Polter's log.", "。正在重试；它报了什么错见 Polter 的日志。" },
        .{ "polter: the \"{1}\" plugin has failed {2} times and is now only retried every fifteen minutes", "polter：插件「{1}」已经失败 {2} 次，现在每 15 分钟才试一次" },
    };
    for (table) |row| if (std.mem.eql(u8, row[0], msgid)) return row[1];
    return msgid;
}

test "a plugin failure is said in the interface's language, key and count filled in" {
    // Task 1663: the line printed into a terminal when a plugin stops was
    // English in a Chinese window. Every word comes through `tr`.
    const alloc = testing.allocator;
    {
        const said = try alertIn(alloc, chineseForTest, "claude-code", .{
            .events = &.{.provision},
        }, .stopped, 1);
        defer alloc.free(said);
        try testing.expectEqualStrings(
            "polter：插件「claude-code」没在跑，所以在这里起的 agent 拿不到 Polter 的工具。正在重试；它报了什么错见 Polter 的日志。",
            said,
        );
    }
    {
        const said = try alertIn(alloc, chineseForTest, "kimi", .{
            .events = &.{.provision},
        }, .dormant, 11);
        defer alloc.free(said);
        try testing.expect(std.mem.startsWith(u8, said, "polter：插件「kimi」已经失败 11 次"));
    }
    // And the English path is the msgids, unchanged: `alert` is `english`.
    {
        const a = try alert(alloc, "x", .{ .events = &.{.chat}, .groups = &.{"*"} }, .stopped, 1);
        defer alloc.free(a);
        const b = try alertIn(alloc, english, "x", .{ .events = &.{.chat}, .groups = &.{"*"} }, .stopped, 1);
        defer alloc.free(b);
        try testing.expectEqualStrings(a, b);
    }
    // A long key and every consequence, in Chinese: still fits, still
    // whole characters.
    {
        const key = "a-plugin-with-a-name-of-exactly-sixty-four-characters-aaaaaaaaaaa";
        const said = try alertIn(alloc, chineseForTest, key, .{
            .events = std.enums.values(Plugin.Event),
        }, .stopped, 999);
        defer alloc.free(said);
        try testing.expect(said.len <= max_alert);
        try testing.expect(std.unicode.utf8ValidateSlice(said));
        try testing.expect(std.mem.endsWith(u8, said, "它报了什么错见 Polter 的日志。"));
    }
}

test "a sentence too long for the screen loses its middle, never its end" {
    // Task 1541: every subscription at once and a long key run past 254
    // bytes, and the clamp took the end off -- the half that says where to
    // look. Each `Trouble` must keep its end whole and cut only at a word.
    const alloc = testing.allocator;
    const key = "a-plugin-with-a-name-of-exactly-sixty-four-characters-aaaaaaaaaaa";
    const all = std.enums.values(Plugin.Event);
    for ([_]Trouble{ .stopped, .dormant }) |why| {
        const said = try alert(alloc, key, .{ .events = all }, why, 999);
        defer alloc.free(said);

        try testing.expect(said.len <= max_alert);
        try testing.expect(std.unicode.utf8ValidateSlice(said));
        const end = switch (why) {
            .stopped => ". It is being retried; what it complained about is in Polter's log.",
            .dormant => ". Its settings are in $XDG_CONFIG_HOME/polter/plugins/" ++ key ++ ".json",
        };
        try testing.expect(std.mem.endsWith(u8, said, end));
        // Whose it is, and what it costs, both still said.
        try testing.expect(std.mem.startsWith(u8, said, "polter: the \"" ++ key ++ "\" plugin"));
        try testing.expect(std.mem.indexOf(u8, said, ", so ") != null);
        // The middle was what gave way, at a word: what comes before the
        // ellipsis is a whole word of the consequence.
        const dots = std.mem.lastIndexOf(u8, said, "…") orelse return error.TestExpectedEqual;
        try testing.expect(said[dots - 1] != ' ');
        const word_start = std.mem.lastIndexOfScalar(u8, said[0..dots], ' ').? + 1;
        const word = said[word_start..dots];
        var whole = false;
        for ([_][]const u8{
            "an agent started here has no Polter tools",
            "nothing will tell you when a terminal needs you",
            "the extra copy of the chat is not being written",
        }) |cost| {
            var it = std.mem.tokenizeScalar(u8, cost, ' ');
            while (it.next()) |w| whole = whole or std.mem.eql(u8, w, std.mem.trimEnd(u8, word, ","));
        }
        try testing.expect(whole);
    }
}

test "a plugin's own words are cut at a word, and say they were" {
    const alloc = testing.allocator;
    const long = "could not write the skill file " ** 12;
    const line = try told(alloc, "talkative", long);
    defer alloc.free(line);
    try testing.expect(line.len <= max_alert);
    try testing.expect(std.mem.endsWith(u8, line, "…"));
    const kept = line[0 .. line.len - "…".len];
    // Ends on a whole word of the sentence, not in one.
    var ok = false;
    for ([_][]const u8{ "could", "not", "write", "the", "skill", "file" }) |w| {
        ok = ok or (std.mem.endsWith(u8, kept, w) and kept[kept.len - w.len - 1] == ' ');
    }
    try testing.expect(ok);
}

test "what a plugin says reaches the user, attributed and defanged" {
    const alloc = testing.allocator;

    {
        const line = try told(alloc, "claude-code", "could not write the skill file");
        defer alloc.free(line);

        // Whose words these are is the host's to state, and it states it in
        // front of them: a plugin cannot write this frame for itself, so it
        // cannot present its line as Polter's.
        try testing.expect(std.mem.startsWith(u8, line, "polter: the \"claude-code\" plugin says: "));
        try testing.expect(std.mem.endsWith(u8, line, "could not write the skill file"));
    }

    // The negative control for the whole reason this is filtered: the text
    // is a plugin's, and it is about to be printed onto a terminal, which
    // is an interpreter. None of this may survive.
    {
        const line = try told(
            alloc,
            "rude",
            "\x1b[2J\x1b]0;polter\x07\u{9b}31mPolter: enter your password:",
        );
        defer alloc.free(line);

        try testing.expect(std.mem.indexOfScalar(u8, line, 0x1b) == null);
        try testing.expect(std.mem.indexOfScalar(u8, line, 0x07) == null);
        try testing.expect(std.mem.indexOf(u8, line, "\u{9b}") == null);

        // The words are still there. Filtering is not censoring: what a
        // plugin meant to say still arrives, it simply cannot draw.
        try testing.expect(std.mem.indexOf(u8, line, "enter your password") != null);
    }

    // The clamp, on a codepoint boundary, and the same 254 bytes as every
    // other thing that goes on a screen. A plugin decides this length, so
    // it is not a length anybody may assume anything about.
    {
        const long = "日" ** 400;
        const line = try told(alloc, "greedy", long);
        defer alloc.free(line);

        try testing.expect(line.len <= max_alert);
        try testing.expect(std.unicode.utf8ValidateSlice(line));
    }

    // A plugin that says nothing at all still produces a line somebody can
    // read, rather than a frame with a hole in it.
    {
        const line = try told(alloc, "quiet", "");
        defer alloc.free(line);
        try testing.expect(std.mem.indexOf(u8, line, "quiet") != null);
    }
}
