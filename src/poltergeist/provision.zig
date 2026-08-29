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
pub const Skill = struct {
    name: []const u8,
    path: []const u8,
};

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

/// What came of a whole pass.
pub const Result = struct {
    /// How many plugins said they did the job.
    provisioned: usize = 0,

    /// One sentence per plugin that did not, in the order they were tried.
    ///
    /// **One line each, not one summary.** Two provisioning plugins that
    /// fail are two runtimes with no tool surface, each fixed in a
    /// different place; a single "2 plugins failed" would tell the user
    /// neither which nor where. A plugin that worked says nothing at all --
    /// a terminal that greets its owner with a report every launch is one
    /// whose reports stop being read.
    ///
    /// Owned by the allocator passed to `run`.
    failures: []const []const u8 = &.{},
};

/// Render the line of JSON a provisioning plugin is handed on stdin.
///
/// The caller owns the bytes. `Plugin.call` adds `params` beside these
/// fields, the same as it does for a notification.
pub fn body(alloc: Allocator, input: Input) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    s.beginObject() catch return error.OutOfMemory;

    s.objectField("event") catch return error.OutOfMemory;
    s.write("provision") catch return error.OutOfMemory;

    s.objectField("exe") catch return error.OutOfMemory;
    s.write(input.exe) catch return error.OutOfMemory;

    s.objectField("version") catch return error.OutOfMemory;
    s.write(input.version) catch return error.OutOfMemory;

    s.objectField("version_key") catch return error.OutOfMemory;
    s.write(version_key) catch return error.OutOfMemory;

    s.objectField("home") catch return error.OutOfMemory;
    s.write(input.home) catch return error.OutOfMemory;

    s.objectField("skills") catch return error.OutOfMemory;
    s.beginArray() catch return error.OutOfMemory;
    for (input.skills) |skill| {
        s.beginObject() catch return error.OutOfMemory;
        s.objectField("name") catch return error.OutOfMemory;
        s.write(skill.name) catch return error.OutOfMemory;
        s.objectField("path") catch return error.OutOfMemory;
        s.write(skill.path) catch return error.OutOfMemory;
        s.endObject() catch return error.OutOfMemory;
    }
    s.endArray() catch return error.OutOfMemory;

    s.endObject() catch return error.OutOfMemory;

    return out.toOwnedSlice();
}

/// Run every provisioning plugin that is switched on.
///
/// **All of them, not the first that works.** Two of them installed means
/// two agent runtimes on this machine, and stopping after the first would
/// leave the second without tools for no stated reason.
///
/// Never returns an error: a terminal has to open whether or not any of
/// this worked. What went wrong comes back in `Result.failures` instead of
/// being thrown away into the log, which is the whole difference between
/// this and what it replaced.
pub fn run(
    alloc: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    plugins: []const Plugin.Manifest,
    params_for: *const fn (
        ctx: *anyopaque,
        alloc: Allocator,
        key: []const u8,
    ) anyerror![]const Plugin.Param,
    ctx: *anyopaque,
    input: Input,
) Result {
    var failures: std.ArrayListUnmanaged([]const u8) = .empty;

    const rendered = body(alloc, input) catch return .{};
    defer alloc.free(rendered);

    var provisioned: usize = 0;

    for (plugins) |manifest| {
        if (manifest.kind != .provision) continue;

        const params = params_for(ctx, alloc, manifest.key) catch &.{};

        const outcome = Plugin.call(manifest, alloc, io, env, rendered, params);
        if (outcome == .done) {
            provisioned += 1;
            log.info("poltergeist: {s} provisioned its runtime", .{manifest.key});
            continue;
        }

        log.warn(
            "poltergeist: provisioning plugin {s} failed ({t})",
            .{ manifest.key, outcome },
        );

        const line = message(alloc, manifest.key, outcome) catch continue;
        failures.append(alloc, line) catch {
            alloc.free(line);
            continue;
        };
    }

    return .{
        .provisioned = provisioned,
        .failures = failures.toOwnedSlice(alloc) catch &.{},
    };
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

/// A plugin directory holding a script with `body` in it, returned as the
/// path to the directory. Everything belongs to `arena`.
fn pluginDir(
    arena: Allocator,
    io: std.Io,
    key: []const u8,
    kind: []const u8,
    script: []const u8,
) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);

    const dir = try std.fmt.allocPrint(arena, "/tmp/polter-provision-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);

    {
        var f = try d.createFile(io, "run.sh", .{ .permissions = .fromMode(0o755) });
        defer f.close(io);
        try f.writeStreamingAll(io, script);
    }

    {
        var f = try d.createFile(io, "plugin.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, try std.fmt.allocPrint(
            arena,
            \\{{"key":"{s}","kind":"{s}","exec":"run.sh","timeout_ms":5000}}
        ,
            .{ key, kind },
        ));
    }

    return dir;
}

fn noParams(
    ctx: *anyopaque,
    alloc: Allocator,
    key: []const u8,
) anyerror![]const Plugin.Param {
    _ = ctx;
    _ = alloc;
    _ = key;
    return &.{};
}

const sample: Input = .{
    .exe = "/Applications/Polter.app/Contents/MacOS/ghostty",
    .version = "1.2.3-test",
    .home = "/Users/nobody",
    .skills = &.{
        .{ .name = "supervising", .path = "/res/poltergeist/supervising.md" },
    },
};

test "the data a runtime needs is all in the line the plugin reads" {
    // Written against the two things the old hard-coded version actually
    // did: register `<exe> +mcp` with a build marker, and install the
    // skills from wherever they really live.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rendered = try body(alloc, sample);

    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        rendered,
        .{},
    );
    const obj = parsed.object;

    try testing.expectEqualStrings("provision", obj.get("event").?.string);
    try testing.expectEqualStrings(sample.exe, obj.get("exe").?.string);
    try testing.expectEqualStrings(sample.version, obj.get("version").?.string);
    try testing.expectEqualStrings(version_key, obj.get("version_key").?.string);
    try testing.expectEqualStrings(sample.home, obj.get("home").?.string);

    const skills = obj.get("skills").?.array;
    try testing.expectEqual(@as(usize, 1), skills.items.len);
    try testing.expectEqualStrings("supervising", skills.items[0].object.get("name").?.string);
    try testing.expectEqualStrings(
        "/res/poltergeist/supervising.md",
        skills.items[0].object.get("path").?.string,
    );

    // One line: the host writes it and closes stdin, and a plugin reading
    // a line at a time must not see two.
    try testing.expect(std.mem.indexOfAny(u8, rendered, "\r\n") == null);
}

test "a provisioning plugin that works says nothing to the user" {
    // The screen belongs to the user. A terminal that greets its owner
    // with a report every launch is one whose reports stop being read.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try pluginDir(alloc, io, "ok", "provision", "#!/bin/sh\ncat >/dev/null\nexit 0\n");
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const manifest = try Plugin.load(alloc, io, dir);

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    var ctx: usize = 0;
    const result = run(alloc, io, &env, &.{manifest}, noParams, &ctx, sample);

    try testing.expectEqual(@as(usize, 1), result.provisioned);
    try testing.expectEqual(@as(usize, 0), result.failures.len);
}

test "a provisioning plugin that fails comes back as a sentence for the user" {
    // The point of the whole file. What fails here is the agent's tool
    // surface, so the agent is the one party that cannot be told -- this
    // has to reach the person, which means it has to leave this function
    // as text and not as a log line.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try pluginDir(alloc, io, "broken", "provision", "#!/bin/sh\ncat >/dev/null\nexit 3\n");
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const manifest = try Plugin.load(alloc, io, dir);

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    var ctx: usize = 0;
    const result = run(alloc, io, &env, &.{manifest}, noParams, &ctx, sample);

    try testing.expectEqual(@as(usize, 0), result.provisioned);
    try testing.expectEqual(@as(usize, 1), result.failures.len);

    const line = result.failures[0];

    // Which plugin, and what the user loses by it. Both, or the reader
    // has to guess at one of them.
    try testing.expect(std.mem.indexOf(u8, line, "broken") != null);
    try testing.expect(std.mem.indexOf(u8, line, "no Polter tools") != null);

    // It has to fit the message that carries it to the screen.
    try testing.expect(line.len <= max_message);
}

test "each failing plugin is its own line" {
    // Two runtimes with no tool surface are fixed in two places. A single
    // "2 failed" would name neither.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const one = try pluginDir(alloc, io, "first", "provision", "#!/bin/sh\ncat >/dev/null\nexit 1\n");
    defer std.Io.Dir.cwd().deleteTree(io, one) catch {};
    const two = try pluginDir(alloc, io, "second", "provision", "#!/bin/sh\ncat >/dev/null\nexit 1\n");
    defer std.Io.Dir.cwd().deleteTree(io, two) catch {};

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    var ctx: usize = 0;
    const result = run(alloc, io, &env, &.{
        try Plugin.load(alloc, io, one),
        try Plugin.load(alloc, io, two),
    }, noParams, &ctx, sample);

    try testing.expectEqual(@as(usize, 2), result.failures.len);
    try testing.expect(std.mem.indexOf(u8, result.failures[0], "first") != null);
    try testing.expect(std.mem.indexOf(u8, result.failures[1], "second") != null);
}

test "one plugin failing does not silence the one that worked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bad = try pluginDir(alloc, io, "bad", "provision", "#!/bin/sh\ncat >/dev/null\nexit 1\n");
    defer std.Io.Dir.cwd().deleteTree(io, bad) catch {};
    const good = try pluginDir(alloc, io, "good", "provision", "#!/bin/sh\ncat >/dev/null\nexit 0\n");
    defer std.Io.Dir.cwd().deleteTree(io, good) catch {};

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    var ctx: usize = 0;
    const result = run(alloc, io, &env, &.{
        try Plugin.load(alloc, io, bad),
        try Plugin.load(alloc, io, good),
    }, noParams, &ctx, sample);

    try testing.expectEqual(@as(usize, 1), result.provisioned);
    try testing.expectEqual(@as(usize, 1), result.failures.len);
}

test "a notification plugin is not run as provisioning" {
    // Same host, different contract. A `notify` plugin handed this line
    // would read an event it does not know and be judged on an exit code
    // that means something else.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try pluginDir(alloc, io, "chatty", "notify", "#!/bin/sh\ncat >/dev/null\nexit 1\n");
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const manifest = try Plugin.load(alloc, io, dir);

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    var ctx: usize = 0;
    const result = run(alloc, io, &env, &.{manifest}, noParams, &ctx, sample);

    try testing.expectEqual(@as(usize, 0), result.provisioned);
    try testing.expectEqual(@as(usize, 0), result.failures.len);
}

test "the plugin is handed the line, params and all" {
    // The host adds `params` beside these fields rather than under them,
    // and a plugin author reads one flat object. Proven by having the
    // plugin itself refuse anything else.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try pluginDir(alloc, io, "reader", "provision",
        \\#!/bin/sh
        \\line=$(cat)
        \\echo "$line" | grep -q '"event":"provision"' || exit 1
        \\echo "$line" | grep -q '"skills":\[{"name":"supervising"' || exit 1
        \\echo "$line" | grep -q '"params":{}' || exit 1
        \\exit 0
        \\
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const manifest = try Plugin.load(alloc, io, dir);

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    var ctx: usize = 0;
    const result = run(alloc, io, &env, &.{manifest}, noParams, &ctx, sample);

    try testing.expectEqual(@as(usize, 1), result.provisioned);
}
