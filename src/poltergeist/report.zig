//! Every sentence the three plugin tools hand back.
//!
//! Pure functions over plain arguments: no `App`, no `*Resident`, nothing but
//! the allocator that ends up owning the result. The wording **is** the whole
//! of what this file does -- an agent reads these sentences and acts on what
//! they say -- so it has to be comparable against the two tables in
//! `docs/poltergeist/mcp.md` that write the wording down.
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
    return sentence(alloc, facts, nothing_started);
}

/// The short form of the same, for `plugin_list`'s `note`.
///
/// Empty when a copy is running and nothing is wrong, and the reason
/// otherwise. Same branches in the same order as `residentStatus`, so the
/// listing and the test can never disagree about why nothing is happening.
pub fn residentNote(alloc: Allocator, facts: ResidentFacts) Allocator.Error![]const u8 {
    if (facts.status) |st| switch (st.state) {
        // Nothing is wrong in these two, and a note saying so would be a
        // line of noise on every plugin that is working.
        .feeding, .starting => return alloc.dupe(u8, ""),
        .backing_off, .dormant, .stopped => {},
    };

    return sentence(alloc, facts, "");
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

        .started_now => std.fmt.allocPrint(
            alloc,
            "{s}. {s} is now being fed the events it subscribed to, as they happen.",
            .{ what, key },
        ),

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
    // Every subscription this build knows, so a fourth one added to
    // `Plugin.Event` has to be given a consequence here rather than
    // silently producing a sentence that names no cost at all.
    var costs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer costs.deinit(alloc);

    for (std.enums.values(Plugin.Event)) |e| {
        if (!wants.subscribes(e)) continue;
        try costs.append(alloc, switch (e) {
            .provision => "an agent started here has no Polter tools",
            .terminal_quiet => "nothing will tell you when a terminal needs you",
            .chat => "the extra copy of the chat is not being written",
        });
    }

    // A plugin that subscribes to nothing is never started, so this cannot
    // be reached from the resident loop -- but a sentence that names no
    // consequence at all is still better than an empty screen.
    const cost = if (costs.items.len == 0)
        try alloc.dupe(u8, "it is not doing what it was installed to do")
    else
        try std.mem.join(alloc, ", and ", costs.items);
    defer alloc.free(cost);

    const text = switch (why) {
        .stopped => try std.fmt.allocPrint(
            alloc,
            "polter: the \"{s}\" plugin is not running, so {s}. It is being " ++
                "retried; what it complained about is in Polter's log.",
            .{ key, cost },
        ),

        .dormant => try std.fmt.allocPrint(
            alloc,
            "polter: the \"{s}\" plugin has failed {d} times and is now only " ++
                "retried every fifteen minutes, so {s}. Its settings are in " ++
                "$XDG_CONFIG_HOME/polter/plugins/{s}.json",
            .{ key, failures, cost, key },
        ),
    };
    if (text.len <= max_alert) return text;

    defer alloc.free(text);

    // Cut on a codepoint boundary. A key is plain ASCII but `cost` is not
    // necessarily, and half a UTF-8 sequence on somebody's screen is a
    // replacement character where a word should be.
    return alloc.dupe(u8, text[0..scrub.cut(text, max_alert)]);
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
    return alloc.dupe(u8, whole[0..scrub.cut(whole, max_alert)]);
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

test "a plugin is never started to test it" {
    const alloc = testing.allocator;

    // Every shape an archive can be in produces a sentence, and every one of
    // them says that nothing was started to produce it. That clause is the
    // whole answer to "why did you not just run it": it has to survive an
    // edit to any single branch.
    const shapes = [_]ResidentFacts{
        .{ .key = "chat-archive", .enabled = false, .declares_events = true, .log_open = true },
        .{ .key = "chat-archive", .enabled = true, .declares_events = false, .log_open = true },
        .{ .key = "chat-archive", .enabled = true, .declares_events = true, .log_open = false },
        .{ .key = "chat-archive", .enabled = true, .declares_events = true, .log_open = true },
        .{
            .key = "chat-archive",
            .enabled = true,
            .declares_events = true,
            .log_open = true,
            .status = .{ .state = .feeding, .cursor = 1049, .failures = 0 },
        },
        .{
            .key = "chat-archive",
            .enabled = true,
            .declares_events = true,
            .log_open = true,
            .status = .{ .state = .starting, .cursor = 0, .failures = 0 },
        },
        .{
            .key = "chat-archive",
            .enabled = true,
            .declares_events = true,
            .log_open = true,
            .status = .{ .state = .backing_off, .cursor = 12, .failures = 2 },
        },
        .{
            .key = "chat-archive",
            .enabled = true,
            .declares_events = true,
            .log_open = true,
            .status = .{ .state = .dormant, .cursor = 0, .failures = 9 },
        },
        .{
            .key = "chat-archive",
            .enabled = true,
            .declares_events = true,
            .log_open = true,
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
            .status = .{ .state = state, .cursor = 3, .failures = 4 },
        });
        defer alloc.free(said);
        try testing.expect(said.len > 0);
    }
}

test "what a configure changes now and what waits for a restart" {
    const alloc = testing.allocator;

    // A plugin that subscribes to nothing was never going to run, and the
    // reply has to say that rather than "switched on" and nothing else --
    // that is the sentence a user reads after switching on a plugin whose
    // manifest still says `"kind"` and nothing about events.
    {
        const said = try configured(alloc, "webhook", true, true, .subscribes_to_nothing);
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "subscribes to no events") != null);
        try testing.expect(std.mem.indexOf(u8, said, "wants") != null);
    }

    // One that is already running is not restarted, and the reply has to
    // say so: an agent that believed the new dsn was in effect would report
    // a database that is not being written to.
    {
        const said = try configured(alloc, "chat-archive", false, true, .already_running);
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "next time Polter starts") != null);
        try testing.expect(std.mem.indexOf(u8, said, "handed every event twice") != null);
    }

    // Switching one on when no copy exists does start one, and that is live.
    {
        const said = try configured(alloc, "chat-archive", true, false, .started_now);
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "now being fed") != null);
    }

    // When it did not start, this says only what was written: the caller
    // appends `residentNote`, so the reason is written once, in one place.
    {
        const said = try configured(alloc, "chat-archive", true, false, .not_started);
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
