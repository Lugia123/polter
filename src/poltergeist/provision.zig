//! Telling an agent's runtime that Polter is here.
//!
//! Polter puts a socket path and a token in every terminal's environment,
//! which is everything an agent needs to *reach* it. What that does not do
//! is make the tools appear: an MCP client only loads servers it has been
//! configured with, so an agent in a directory nobody registered has the
//! socket, the token, and no way to use either. The same goes for skills --
//! a runtime matches what the user asked for against the skills it knows
//! about, and one it has never heard of is one it cannot reach for.
//!
//! **Where the line is.** The core produces the *data*: which skills there
//! are and where their files live, which binary serves the MCP endpoint,
//! which build wrote it. A plugin turns that into the shape one particular
//! AI CLI reads. That split is the whole point: this used to be
//! `claude mcp add` and a copy into `~/.claude/skills/` written straight
//! into the core, which meant that swapping in another agent CLI left
//! nowhere for anybody to put the equivalent. See
//! `docs/poltergeist/boundary.md` section 3.
//!
//! **A failure here is never only a log line.** What this step fails at is
//! giving the agent a tool surface, so the agent is precisely the party
//! that cannot be told about it -- `notify_user` returns a string *to the
//! agent*. The failures come back from `run` as sentences meant for the
//! person, and `App` puts them on a terminal's screen.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Feed = @import("Feed.zig");
const Plugin = @import("Plugin.zig");

const log = std.log.scoped(.poltergeist);

/// The env key a plugin is expected to stamp its registration with.
///
/// A command path alone catches a move or a reinstall elsewhere, but not a
/// build whose arguments or protocol changed while living at the same path
/// -- which is every in-place upgrade. Handed to the plugin so that
/// "written by a different build" is a thing it can see.
pub const version_key = "POLTER_REGISTERED";

/// The longest a message put on somebody's screen may be.
///
/// `apprt.surface.Message.poltergeist_alert` is a fixed 255 bytes plus a
/// NUL, and a sentence that gets chopped is worse than a shorter one that
/// was written to fit.
pub const max_message = 254;

/// One skill, and the file it is actually in.
///
/// The path rather than the text: the file is the thing a plugin has to
/// copy or rewrite, it may be megabytes of prose, and a plugin that wants
/// only the name never has to read it.
///
/// The feed's own type, not a second copy of it. Two structs with the same
/// two fields is exactly the drift this round exists to stop.
pub const Skill = Feed.Skill;

/// Everything the core knows that a runtime might need to be told.
pub const Input = struct {
    /// Absolute path to the binary that serves the MCP endpoint. It is run
    /// as `<exe> +mcp`, speaking JSON-RPC on stdio.
    exe: []const u8,

    /// This build, for the staleness marker.
    version: []const u8,

    /// The user's home directory, because a runtime's own configuration
    /// almost always hangs off it and a plugin should not have to guess at
    /// the environment it was started with.
    home: []const u8,

    /// Every skill Polter ships, already resolved to whichever copy wins.
    skills: []const Skill = &.{},
};

/// This description as the feed publishes it.
///
/// One event on the one stream, handed to whichever plugins subscribed to
/// `provision`. There is no separate "run the provisioning plugins" pass
/// any more, and no exit code to read: the plugin acknowledges it the way
/// it acknowledges anything else.
///
/// **What that costs, said plainly.** The old pass ran while the first
/// terminal was being built and could put one sentence per failure straight
/// on that terminal's screen. A resident plugin answers whenever it
/// answers, so there is nothing synchronous left to put there. What a
/// failure now reaches the user through is the log, the plugin's own state
/// in `plugin_list` -- which an agent can read and which says `backing_off`
/// or `dormant` in so many words -- and `plugin_test`, which is
/// synchronous on purpose. The one thing that is gone is the unprompted
/// message on the screen, and the reason for accepting that is that the
/// alternative was a callback from a plugin's own thread into the surface
/// list, which is the app thread's alone.
pub fn published(input: Input, at_ms: i64) Feed.Event {
    return .{ .provision = .{
        .at_ms = at_ms,
        .exe = input.exe,
        .version = input.version,
        .version_key = version_key,
        .home = input.home,
        .skills = input.skills,
    } };
}

/// What one failure reads as on somebody's screen.
///
/// Says the consequence rather than only the fault: "it failed" leaves the
/// reader to work out that the missing tools they will notice in ten
/// minutes are this. Truncated to fit the message that carries it, and
/// truncated by construction rather than by chopping -- the plugin key is
/// the only variable-length part, and a key is at most 64 plain
/// characters.
pub fn message(
    alloc: Allocator,
    key: []const u8,
    outcome: Plugin.Outcome,
) Allocator.Error![]const u8 {
    const text = try std.fmt.allocPrint(
        alloc,
        "polter: the \"{s}\" provisioning plugin failed ({t}), so an agent " ++
            "started here has no Polter tools. Its settings are in " ++
            "$XDG_CONFIG_HOME/polter/plugins/{s}.json",
        .{ key, outcome, key },
    );
    if (text.len <= max_message) return text;

    defer alloc.free(text);
    return alloc.dupe(u8, text[0..max_message]);
}

/// What to say when the user asked for registration and nothing will do it.
///
/// A separate sentence because it is a different situation with a different
/// fix: nothing failed, there is simply no plugin switched on that turns
/// Polter into anything a runtime reads. Silence here would be the same
/// silent nothing-happened this whole file exists to end.
pub fn nothingInstalled(alloc: Allocator) Allocator.Error![]const u8 {
    return alloc.dupe(
        u8,
        "polter: poltergeist-register-mcp is on but no provisioning plugin " ++
            "is switched on, so no agent runtime is being told that Polter's " ++
            "tools exist. Switch one on under $XDG_CONFIG_HOME/polter/plugins/",
    );
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

const sample: Input = .{
    .exe = "/Applications/Polter.app/Contents/MacOS/ghostty",
    .version = "1.2.3-test",
    .home = "/Users/nobody",
    .skills = &.{
        .{ .name = "supervising", .path = "/res/poltergeist/supervising.md" },
    },
};

test "an unknown home is published rather than withheld" {
    // **The half of the seam that can be held still on any machine.**
    //
    // `App.ensureMcpRegistered` used to `return` when it could not find the
    // home directory, which on Windows was every time -- so the event below
    // was never built and every provisioning plugin waited on an empty queue
    // with nothing in any log to say why. The fix publishes anyway with an
    // empty home, because the plugin SDK reports that case itself
    // (`status=failed step=parse`) and a failure in the plugin's own log
    // beats a silence in ours.
    //
    // **What this test cannot reach, said plainly rather than implied:**
    //
    //   * it does not run `ensureMcpRegistered`. That function appears twice
    //     in the whole tree -- its definition and its one call site -- and no
    //     test touches it, which is exactly why the defect survived: the
    //     batch-rendering tests build their own event array, so "who produces
    //     an event" was never in the part being tested.
    //   * it cannot exercise the Windows lookup. `os/homedir.zig` dispatches
    //     on `builtin.os.tag`, so the `HOMEDRIVE`+`HOMEPATH` branch is not
    //     even analysed on this machine. **A green run here says nothing
    //     about the platform the bug was on.**
    //
    // What it does pin is the decision: an absent home must not become an
    // absent event.
    const ev = published(.{
        .exe = "C:\\app\\polter-host.exe",
        .version = "1.2.3-test",
        .home = "",
        .skills = &.{},
    }, 1786819271275);

    try testing.expectEqual(Plugin.Event.provision, ev.kind());
    try testing.expectEqualStrings("", ev.provision.home);
    try testing.expectEqualStrings("C:\\app\\polter-host.exe", ev.provision.exe);
}

test "the data a runtime needs is all in the event the plugin is handed" {
    // Written against the two things the old hard-coded version actually
    // did: register `<exe> +mcp` with a build marker, and install the
    // skills from wherever they really live.
    const ev = published(sample, 1786819271275);

    try testing.expectEqual(Plugin.Event.provision, ev.kind());
    try testing.expectEqualStrings(sample.exe, ev.provision.exe);
    try testing.expectEqualStrings(sample.version, ev.provision.version);
    try testing.expectEqualStrings(version_key, ev.provision.version_key);
    try testing.expectEqualStrings(sample.home, ev.provision.home);

    try testing.expectEqual(@as(usize, 1), ev.provision.skills.len);
    try testing.expectEqualStrings("supervising", ev.provision.skills[0].name);
    try testing.expectEqualStrings(
        "/res/poltergeist/supervising.md",
        ev.provision.skills[0].path,
    );

    // In no group. Requiring a provisioning plugin to declare
    // `"groups": ["*"]` would be a rule with no explanation behind it.
    try testing.expect(ev.group() == null);
}

test "one failure names the plugin and what the user loses by it" {
    // What fails here is the agent's tool surface, so the agent is the one
    // party that cannot be told. The sentence has to name both the plugin
    // and the consequence, or the reader has to guess at one of them.
    const line = try message(testing.allocator, "broken", .refused);
    defer testing.allocator.free(line);

    try testing.expect(std.mem.indexOf(u8, line, "broken") != null);
    try testing.expect(std.mem.indexOf(u8, line, "no Polter tools") != null);

    // It has to fit the message that carries it to the screen.
    try testing.expect(line.len <= max_message);
}

test "with nothing switched on the user is told that, not told nothing" {
    const line = try nothingInstalled(testing.allocator);
    defer testing.allocator.free(line);

    try testing.expect(std.mem.indexOf(u8, line, "poltergeist-register-mcp") != null);
    try testing.expect(line.len <= max_message);
}
