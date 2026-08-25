//! Every sentence the three plugin tools hand back.
//!
//! Pure functions over plain arguments: no `App`, no `*Archive`, nothing but
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

const Archive = @import("Archive.zig");
const Plugin = @import("Plugin.zig");

/// Everything about a resident plugin that decides what to say about it.
///
/// Flattened out of the app on purpose: the caller is the only thing that
/// can look these up, and the answer must be checkable without one.
pub const ArchiveFacts = struct {
    key: []const u8,

    enabled: bool,

    /// Whether its manifest asked for any groups at all. A plugin that asked
    /// for none has nothing to be given and is never started.
    declares_groups: bool,

    /// Whether the chat log has been opened, which happens on the first
    /// terminal. Before that there is nothing for an archive to follow.
    log_open: bool,

    /// The running copy, when there is one.
    status: ?Archive.Status = null,
};

/// Said after every branch of `archiveStatus`, and after none of
/// `archiveNote`'s -- a listing is not the place to re-argue the design.
const nothing_started =
    " Nothing was started for this: an archive plugin is resident, a second copy " ++
    "would push the same cursor, and the protocol has no dry run for it to use instead.";

/// What `plugin_test` says about an archive plugin -- see `mcp.md` §2.5.
///
/// Nothing is started to produce this, and the sentence says so. An archive
/// plugin is resident and holds the cursor; a second copy would confirm into
/// the same file, and the protocol has no dry run to offer instead. So the
/// answer to "does it work" is the running copy's own account of itself.
pub fn archiveStatus(alloc: Allocator, facts: ArchiveFacts) Allocator.Error![]const u8 {
    return sentence(alloc, facts, nothing_started);
}

/// The short form of the same, for `plugin_list`'s `note`.
///
/// Empty when a copy is running and nothing is wrong, and the reason
/// otherwise. Same branches in the same order as `archiveStatus`, so the
/// listing and the test can never disagree about why nothing is happening.
pub fn archiveNote(alloc: Allocator, facts: ArchiveFacts) Allocator.Error![]const u8 {
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
    facts: ArchiveFacts,
    tail: []const u8,
) Allocator.Error![]const u8 {
    if (!facts.enabled) return std.fmt.allocPrint(
        alloc,
        "{s} is installed but switched off, so nothing is following the log. " ++
            "plugin_configure with enabled: true switches it on.{s}",
        .{ facts.key, tail },
    );

    if (!facts.declares_groups) return std.fmt.allocPrint(
        alloc,
        "{s} declares no groups in its plugin.json, so it was not started. " ++
            "It needs \"wants\": {{\"groups\": [\"*\"]}} -- that is the plugin's own " ++
            "file, not a setting, so it is the user's to edit.{s}",
        .{ facts.key, tail },
    );

    const st = facts.status orelse {
        if (!facts.log_open) return std.fmt.allocPrint(
            alloc,
            "{s} is switched on but nothing is running it yet: the chat log has not " ++
                "been opened, which happens once a terminal exists.{s}",
            .{ facts.key, tail },
        );

        // Not in the spec's table, and reachable: `Archive.start` fails on a
        // cursor file it cannot make, a log it cannot read, or a thread that
        // will not start, and until now that produced a `log.warn` nobody
        // reads and a plugin that looked switched on and did nothing.
        return std.fmt.allocPrint(
            alloc,
            "{s} is switched on and the log is open, but no copy of it is running: " ++
                "it would not start, and Polter's log says why.{s}",
            .{ facts.key, tail },
        );
    };

    // Exhaustive over `Archive.State` on purpose: a sixth state added there
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

/// What became of an archive plugin over the course of a configure.
///
/// Decided by the caller rather than worked out here, because only the app
/// can start one and only the app knows whether it did.
pub const Started = enum {
    /// Not an archive plugin at all, so there was never anything to start.
    not_an_archive,

    /// A copy was already resident, and a second one is exactly what must
    /// not happen.
    already_running,

    /// This call started one.
    started_now,

    /// It should be running and is not. The caller appends `archiveNote`,
    /// so the reason is never written out twice.
    not_started,
};

/// What `plugin_configure` says about when a change takes hold -- §2.6.
pub fn configured(
    alloc: Allocator,
    key: []const u8,
    kind: Plugin.Kind,
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

    return switch (kind) {
        .notify => std.fmt.allocPrint(
            alloc,
            "{s}. Notification plugins read their settings each time they send, " ++
                "so this is live now.",
            .{what},
        ),

        .archive => switch (started) {
            .already_running => std.fmt.allocPrint(
                alloc,
                "{s}. {s} is already running with the settings it started with. " ++
                    "Nothing was restarted -- a second copy would push the same cursor " ++
                    "-- so this takes effect the next time Polter starts.",
                .{ what, key },
            ),

            .started_now => std.fmt.allocPrint(
                alloc,
                "{s}. {s} is now following the log.",
                .{ what, key },
            ),

            // `not_an_archive` cannot be reached for an archive plugin; it
            // is answered the same way as a plugin that would not start,
            // because in both cases nothing is running and the caller's
            // note is what explains that.
            .not_started, .not_an_archive => std.fmt.allocPrint(alloc, "{s}.", .{what}),
        },
    };
}

/// What `plugin_test` says about a notification plugin it really sent
/// through.
///
/// A switched-off plugin is tested all the same and told about: refusing
/// would block the obvious order of operations -- prove it works, then
/// switch it on -- and a passing test on a channel nobody will call is a
/// fact the supervisor needs said rather than implied.
pub fn notified(
    alloc: Allocator,
    key: []const u8,
    enabled: bool,
    outcome: Plugin.Outcome,
) Allocator.Error![]const u8 {
    const off = if (enabled)
        ""
    else
        " It is switched off, so nothing else will be sent through it.";

    // Exhaustive over `Plugin.Outcome`: every way a send can end has to have
    // something said about it, and a new one must not silently report as
    // whatever the `else` branch happened to be.
    return switch (outcome) {
        .done => std.fmt.allocPrint(
            alloc,
            "{s} took the test notification and said it delivered it. If it did not " ++
                "reach you, the plugin is where to look, not Polter.{s}",
            .{ key, off },
        ),

        .refused => std.fmt.allocPrint(
            alloc,
            "{s} ran and exited non-zero: it says it did not deliver. What it " ++
                "complained about is on stderr, which is in Polter's log.{s}",
            .{ key, off },
        ),

        .timed_out => std.fmt.allocPrint(
            alloc,
            "{s} was killed for taking longer than its timeout_ms. That is what " ++
                "would happen on the night it was needed too.{s}",
            .{ key, off },
        ),

        .unstartable => std.fmt.allocPrint(
            alloc,
            "{s} could not be started at all. Check that its exec is there and " ++
                "executable.{s}",
            .{ key, off },
        ),

        .unresolved => std.fmt.allocPrint(
            alloc,
            "{s} names a credential that could not be fetched -- a locked vault, a " ++
                "missing file, a variable that is not set -- so it was not run and " ++
                "nothing was sent. Nothing about the value is in the log, on purpose.{s}",
            .{ key, off },
        ),
    };
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "an archive plugin is never started to test it" {
    const alloc = testing.allocator;

    // Every shape an archive can be in produces a sentence, and every one of
    // them says that nothing was started to produce it. That clause is the
    // whole answer to "why did you not just run it": it has to survive an
    // edit to any single branch.
    const shapes = [_]ArchiveFacts{
        .{ .key = "chat-archive", .enabled = false, .declares_groups = true, .log_open = true },
        .{ .key = "chat-archive", .enabled = true, .declares_groups = false, .log_open = true },
        .{ .key = "chat-archive", .enabled = true, .declares_groups = true, .log_open = false },
        .{ .key = "chat-archive", .enabled = true, .declares_groups = true, .log_open = true },
        .{
            .key = "chat-archive",
            .enabled = true,
            .declares_groups = true,
            .log_open = true,
            .status = .{ .state = .feeding, .cursor = 1049, .failures = 0 },
        },
        .{
            .key = "chat-archive",
            .enabled = true,
            .declares_groups = true,
            .log_open = true,
            .status = .{ .state = .starting, .cursor = 0, .failures = 0 },
        },
        .{
            .key = "chat-archive",
            .enabled = true,
            .declares_groups = true,
            .log_open = true,
            .status = .{ .state = .backing_off, .cursor = 12, .failures = 2 },
        },
        .{
            .key = "chat-archive",
            .enabled = true,
            .declares_groups = true,
            .log_open = true,
            .status = .{ .state = .dormant, .cursor = 0, .failures = 9 },
        },
        .{
            .key = "chat-archive",
            .enabled = true,
            .declares_groups = true,
            .log_open = true,
            .status = .{ .state = .stopped, .cursor = 5, .failures = 0 },
        },
    };

    for (shapes) |facts| {
        const said = try archiveStatus(alloc, facts);
        defer alloc.free(said);

        try testing.expect(said.len > 0);
        try testing.expect(std.mem.indexOf(u8, said, "chat-archive") != null);
        try testing.expect(std.mem.indexOf(u8, said, "Nothing was started for this") != null);
        try testing.expect(std.mem.indexOf(u8, said, "second copy would push the same cursor") != null);
    }

    // The running copy's own account of itself is the answer, so the numbers
    // it keeps have to be in it.
    const feeding = try archiveStatus(alloc, shapes[4]);
    defer alloc.free(feeding);
    try testing.expect(std.mem.indexOf(u8, feeding, "1049") != null);
}

test "a plugin that is switched off is reported as switched off" {
    const alloc = testing.allocator;

    // Switched off comes first, before anything about groups or a running
    // copy: a plugin that is off has no running copy by construction, and
    // saying "it is not running" without saying why would send the reader
    // looking in Polter's log for something that is not there.
    const facts: ArchiveFacts = .{
        .key = "chat-archive",
        .enabled = false,
        .declares_groups = false,
        .log_open = false,
    };

    const said = try archiveStatus(alloc, facts);
    defer alloc.free(said);
    try testing.expect(std.mem.indexOf(u8, said, "switched off") != null);
    try testing.expect(std.mem.indexOf(u8, said, "plugin_configure with enabled: true") != null);

    // And a listing says the same thing, because a plugin that is off is
    // exactly what somebody reading a listing is asking about.
    const note = try archiveNote(alloc, facts);
    defer alloc.free(note);
    try testing.expect(std.mem.indexOf(u8, note, "switched off") != null);

    // The listing does not re-argue the design; the test does.
    try testing.expect(std.mem.indexOf(u8, note, "Nothing was started") == null);
}

test "an archive that would not start is not reported as running" {
    const alloc = testing.allocator;

    // Switched on, groups declared, log open, and still no copy: `start`
    // failed. This used to be a warning nobody reads, and the listing said
    // nothing at all -- which reads as "fine".
    const stuck: ArchiveFacts = .{
        .key = "chat-archive",
        .enabled = true,
        .declares_groups = true,
        .log_open = true,
        .status = null,
    };

    const note = try archiveNote(alloc, stuck);
    defer alloc.free(note);
    try testing.expect(note.len > 0);
    try testing.expect(std.mem.indexOf(u8, note, "no copy of it is running") != null);

    // A healthy copy gets no note: the listing already carries its state,
    // and a sentence repeating it on every plugin that works is noise.
    for ([_]Archive.State{ .feeding, .starting }) |state| {
        const quiet = try archiveNote(alloc, .{
            .key = "chat-archive",
            .enabled = true,
            .declares_groups = true,
            .log_open = true,
            .status = .{ .state = state, .cursor = 3, .failures = 0 },
        });
        defer alloc.free(quiet);
        try testing.expectEqualStrings("", quiet);
    }

    // The three that are not fine do carry one, because a listing where
    // `state` is the only clue makes the reader look up what `dormant` means.
    for ([_]Archive.State{ .backing_off, .dormant, .stopped }) |state| {
        const said = try archiveNote(alloc, .{
            .key = "chat-archive",
            .enabled = true,
            .declares_groups = true,
            .log_open = true,
            .status = .{ .state = state, .cursor = 3, .failures = 4 },
        });
        defer alloc.free(said);
        try testing.expect(said.len > 0);
    }
}

test "what a configure changes now and what waits for a restart" {
    const alloc = testing.allocator;

    // A notification plugin reads its settings on every send, so there is
    // nothing to restart and nothing to wait for.
    {
        const said = try configured(alloc, "webhook", .notify, true, true, .not_an_archive);
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "live now") != null);
        try testing.expect(std.mem.indexOf(u8, said, "switched on") != null);
    }

    // A resident one that is already running is not restarted, and the reply
    // has to say so: an agent that believed the new dsn was in effect would
    // report a database that is not being written to.
    {
        const said = try configured(alloc, "chat-archive", .archive, false, true, .already_running);
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "next time Polter starts") != null);
        try testing.expect(std.mem.indexOf(u8, said, "same cursor") != null);
        try testing.expect(std.mem.indexOf(u8, said, "live now") == null);
    }

    // Switching one on when no copy exists does start one, and that is live.
    {
        const said = try configured(alloc, "chat-archive", .archive, true, false, .started_now);
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "now following the log") != null);
    }

    // When it did not start, this says only what was written: the caller
    // appends `archiveNote`, so the reason is written once, in one place.
    {
        const said = try configured(alloc, "chat-archive", .archive, true, false, .not_started);
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "switched on") != null);
        try testing.expect(std.mem.indexOf(u8, said, "following the log") == null);
        try testing.expect(std.mem.indexOf(u8, said, "next time Polter starts") == null);
    }
}

test "a test that did not send says so rather than saying nothing" {
    const alloc = testing.allocator;

    // Exhaustive over the outcomes: a test whose answer is silence is worse
    // than no test at all, because silence reads as success.
    for (std.enums.values(Plugin.Outcome)) |outcome| {
        const said = try notified(alloc, "webhook", true, outcome);
        defer alloc.free(said);

        try testing.expect(said.len > 0);
        try testing.expect(std.mem.indexOf(u8, said, "webhook") != null);

        // Only the one that really delivered may read as success.
        if (outcome != .done) {
            try testing.expect(std.mem.indexOf(u8, said, "delivered it") == null);
        }
    }

    // A credential that would not resolve says nothing about the value, and
    // the reply says that it says nothing -- otherwise the obvious next move
    // is to go looking in the log for a value that was never put there.
    {
        const said = try notified(alloc, "webhook", true, .unresolved);
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "on purpose") != null);
    }

    // A plugin that works but is switched off is a fact the supervisor has
    // to be told, or it will wait for a notification that will never come.
    {
        const said = try notified(alloc, "webhook", false, .done);
        defer alloc.free(said);
        try testing.expect(std.mem.indexOf(u8, said, "switched off") != null);
    }
}
