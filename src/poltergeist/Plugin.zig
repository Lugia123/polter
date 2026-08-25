//! Running somebody else's script on our behalf.
//!
//! A plugin is a directory with a `plugin.yaml` and an executable. Polter
//! writes one line of JSON to the executable's stdin and reads its exit
//! code. That is the whole contract.
//!
//! **Why a process and not a library.** These are scripts people copy off
//! the internet. They will hang, segfault, and flood stdout, and none of
//! that may take the terminal down with it -- a process boundary is the
//! only place that guarantee comes free. The rate makes it affordable: the
//! box already caps interruptions at one a minute, so a fork per
//! notification costs nothing that matters. And it means any language: a
//! twenty-line `curl` script is a complete plugin, where requiring Zig
//! would mean the extension point does not exist. See
//! `docs/poltergeist/plugins.md` for the routes that were rejected.
//!
//! This file is the **host**: it knows about manifests, processes, timeouts
//! and exit codes, and nothing about what any particular kind of plugin is
//! for. What goes in the JSON is decided a layer up. That split is what
//! lets `sensor` and `action` plugins arrive later without this file
//! learning about them -- and why there is no code for those two here now,
//! since an interface guessed before its first use is harder to change than
//! no interface at all.

const Plugin = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const reap = @import("reap.zig");
const secret = @import("secret.zig");

const log = std.log.scoped(.poltergeist);

/// Longest a plugin may take before it is killed.
///
/// Something has to bound this. A plugin that cannot reach the network
/// will sit there, and the scenario this feature exists for is one where
/// nobody is watching to notice.
const default_timeout_ms: u64 = 10 * std.time.ms_per_s;

/// What a plugin is for.
///
/// The kind decides the lifetime, and the lifetimes are not alike enough to
/// share one: what separates them is how dense the events are.
pub const Kind = enum {
    /// Sends a message somewhere the user will see it. One process per
    /// notification: a few an hour, so a fork each costs nothing that
    /// matters, and a plugin that hangs takes only its own notification
    /// down with it.
    notify,

    /// Follows the chat log and copies it somewhere else. **Resident**:
    /// the events are continuous, and rebuilding a database connection per
    /// message is not a thing that can be done. It is handed a stream of
    /// batches on stdin and answers each one, rather than being started and
    /// judged by an exit code. See `Archive.zig` and
    /// `docs/poltergeist/storage.md`.
    archive,
};

/// What a plugin says it needs.
///
/// **Declared so the host has something to refuse against**, not as a
/// certificate of good behaviour. Only `groups` is enforced, and it is
/// enforced completely: the batches a plugin is fed are built from this
/// list, and a plugin has no second channel to the log. `network` and
/// `exec` are declaration and disclosure only -- they are what a user reads
/// before installing, and what an audit has to go on. They are **not** a
/// sandbox and nothing here stops a plugin doing either. Saying that
/// plainly is the point: `"network": false` must never be read as "it
/// cannot reach the network". Real isolation has to be designed together
/// with signing; see `docs/poltergeist/plugins.md`.
pub const Wants = struct {
    /// Which chat groups may appear in what this plugin is given. A single
    /// element `"*"` means all of them. Empty means none, which is what a
    /// manifest that declares nothing gets.
    ///
    /// Borrowed from the arena the manifest was loaded into. Anything that
    /// outlives one pass over the plugin directory has to copy these: the
    /// arena is rebuilt whole every time the plugin list is.
    groups: []const []const u8 = &.{},

    network: bool = false,

    exec: []const []const u8 = &.{},

    /// Whether `name` is a group this plugin asked for.
    ///
    /// Whole-string equality, and `"*"` counts only as an entire element.
    /// No wildcard language, because one needs escaping rules and group
    /// names come out of a chat window and may hold anything.
    pub fn allows(self: Wants, name: []const u8) bool {
        for (self.groups) |g| {
            if (std.mem.eql(u8, g, "*")) return true;
            if (std.mem.eql(u8, g, name)) return true;
        }
        return false;
    }

    /// True when nothing was asked for. An archive that wants nothing has
    /// nothing to do, and the host says so rather than running it empty.
    pub fn empty(self: Wants) bool {
        return self.groups.len == 0;
    }
};

/// A plugin as declared by its manifest.
///
/// Everything is owned by `arena`, which the loader hands over whole.
pub const Manifest = struct {
    /// Unique, and the name the config refers to.
    key: []const u8,

    /// For a person reading a list of them.
    name: []const u8 = "",

    kind: Kind,

    /// Absolute path to the executable.
    exec: []const u8,

    timeout_ms: u64 = default_timeout_ms,

    /// Everything declared in `wants`. Absent from the manifest reads as
    /// wanting nothing; see `Wants`.
    wants: Wants = .{},
};

/// Load a plugin's manifest from a directory.
///
/// Everything returned belongs to `arena`, including `exec`, which is made
/// absolute here so that running it never depends on where Polter happens
/// to be.
///
/// The manifest is JSON rather than YAML: Zig has no YAML in its standard
/// library, and a hand-written subset parser gets indentation and
/// implicit typing wrong in ways that silently mean something else. See
/// `docs/poltergeist/plugins.md`.
pub fn load(
    arena: Allocator,
    io: std.Io,
    dir: []const u8,
) !Manifest {
    const path = try std.fmt.allocPrint(arena, "{s}/plugin.json", .{dir});

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        .limited(64 * 1024),
    ) catch |err| {
        log.warn("plugin: could not read {s} err={}", .{ path, err });
        return error.NoManifest;
    };

    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        bytes,
        .{},
    ) catch |err| {
        log.warn("plugin: {s} will not parse err={}", .{ path, err });
        return error.BadManifest;
    };

    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.BadManifest,
    };

    const key = stringField(obj, "key") orelse {
        log.warn("plugin: {s} has no key", .{path});
        return error.BadManifest;
    };

    const kind_text = stringField(obj, "kind") orelse "notify";
    const kind = std.meta.stringToEnum(Kind, kind_text) orelse {
        // Not an error worth failing the whole load over -- a newer plugin
        // for a kind this build does not know about should be skipped,
        // not fatal.
        log.warn("plugin {s}: unknown kind {s}", .{ key, kind_text });
        return error.UnknownKind;
    };

    const exec_rel = stringField(obj, "exec") orelse {
        log.warn("plugin {s}: no exec", .{key});
        return error.BadManifest;
    };

    return .{
        .key = key,
        .name = stringField(obj, "name") orelse key,
        .kind = kind,
        .exec = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, exec_rel }),
        .timeout_ms = switch (obj.get("timeout_ms") orelse std.json.Value{ .null = {} }) {
            .integer => |n| if (n > 0) @intCast(n) else default_timeout_ms,
            else => default_timeout_ms,
        },
        .wants = wantsOf(arena, key, obj),
    };
}

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |v| v,
        else => null,
    };
}

/// What the manifest declares under `wants`.
///
/// A `wants` that will not read is not worth failing the load over: one
/// typo would make a whole plugin vanish, which is harder for its author to
/// notice than a plugin being handed nothing. It reads as asking for
/// nothing instead -- the direction that cannot give somebody messages they
/// never asked for.
fn wantsOf(arena: Allocator, key: []const u8, obj: std.json.ObjectMap) Wants {
    const w = switch (obj.get("wants") orelse return .{}) {
        .object => |o| o,
        else => {
            log.warn(
                "plugin {s}: wants is not an object, so it is read as asking for nothing",
                .{key},
            );
            return .{};
        },
    };
    return .{
        .groups = stringsOf(arena, key, w, "groups"),
        .network = switch (w.get("network") orelse .null) {
            .bool => |b| b,
            else => false,
        },
        .exec = stringsOf(arena, key, w, "exec"),
    };
}

/// The strings in one array field, passing over whatever is not one.
///
/// An entry of the wrong type does not void the rest: a declaration that can
/// be read in part is still a declaration, and the part that reads is what
/// its author meant. Running out of memory ends the list early for the same
/// reason that is safe -- a list cut short asks for less than was written
/// down, never for more.
fn stringsOf(
    arena: Allocator,
    key: []const u8,
    obj: std.json.ObjectMap,
    name: []const u8,
) []const []const u8 {
    const items = switch (obj.get(name) orelse return &.{}) {
        .array => |a| a.items,
        else => {
            log.warn(
                "plugin {s}: wants.{s} is not a list, so it is read as naming nothing",
                .{ key, name },
            );
            return &.{};
        },
    };

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var skipped: usize = 0;
    for (items) |item| {
        const s = switch (item) {
            .string => |v| v,
            else => {
                skipped += 1;
                continue;
            },
        };
        out.append(arena, s) catch {
            // Cut short rather than voided, because a shorter list asks for
            // less than was written down and never for more. Said out loud
            // all the same: a declaration that quietly means something
            // narrower than its author wrote is the one kind of narrowing
            // nobody can debug.
            log.warn(
                "plugin {s}: ran out of memory reading wants.{s}, so only the first {d} of {d} are honoured",
                .{ key, name, out.items.len, items.len },
            );
            break;
        };
    }
    if (skipped > 0) log.warn(
        "plugin {s}: passed over {d} entries in wants.{s} that are not text",
        .{ key, skipped, name },
    );
    return out.items;
}

/// One parameter as configured. The value may be a reference; see
/// `secret.zig`.
pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

/// Everything the user has said about one plugin, in one file.
///
/// Lives at `$XDG_CONFIG_HOME/polter/plugins/<key>.json`, beside the plugin's
/// own directory:
///
///     {"enabled": true, "params": {"url": "cmd:op read op://…"}}
///
/// **One plugin, one file, one source of truth.** Whether it is switched on
/// used to live in the main config and its parameters here, which meant the
/// two could disagree and that a GUI could not own either without fighting a
/// file the user hand-writes. This file is structured, ours, and safe to
/// rewrite.
pub const Settings = struct {
    enabled: bool = false,
    params: []const Param = &.{},

    /// Read one. Missing or unparseable reads as "not configured", which is
    /// the same as not enabled -- a plugin nobody has set up should not be
    /// sending anything.
    ///
    /// Everything borrowed comes from `arena`.
    pub fn read(
        arena: Allocator,
        io: std.Io,
        path: []const u8,
    ) Settings {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            arena,
            .limited(256 * 1024),
        ) catch return .{};

        const parsed = std.json.parseFromSliceLeaky(
            std.json.Value,
            arena,
            bytes,
            .{},
        ) catch {
            log.warn("plugin: {s} will not parse", .{path});
            return .{};
        };

        const obj = switch (parsed) {
            .object => |o| o,
            else => return .{},
        };

        // The older shape was the parameters alone, with whether the plugin
        // was on kept in the main config. Such a file was only ever written
        // to make a plugin work, so it reads as enabled -- the alternative
        // silently stops delivering for somebody who changed nothing.
        const modern = obj.get("params") != null or obj.get("enabled") != null;
        if (!modern) return .{
            .enabled = true,
            .params = paramsOf(arena, obj),
        };

        const enabled = switch (obj.get("enabled") orelse .null) {
            .bool => |b| b,
            else => false,
        };
        const params = switch (obj.get("params") orelse .null) {
            .object => |o| paramsOf(arena, o),
            else => &.{},
        };
        return .{ .enabled = enabled, .params = params };
    }

    /// Render back out. The caller owns the bytes.
    ///
    /// Written whole: this file is small and the app is the only thing that
    /// writes it, so there is nothing to merge.
    pub fn render(self: Settings, alloc: Allocator) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();

        var s: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{ .whitespace = .indent_2 },
        };

        s.beginObject() catch return error.OutOfMemory;
        s.objectField("enabled") catch return error.OutOfMemory;
        s.write(self.enabled) catch return error.OutOfMemory;
        s.objectField("params") catch return error.OutOfMemory;
        s.beginObject() catch return error.OutOfMemory;
        for (self.params) |param| {
            s.objectField(param.name) catch return error.OutOfMemory;
            s.write(param.value) catch return error.OutOfMemory;
        }
        s.endObject() catch return error.OutOfMemory;
        s.endObject() catch return error.OutOfMemory;

        return out.toOwnedSlice();
    }

    fn paramsOf(arena: Allocator, obj: std.json.ObjectMap) []const Param {
        var out: std.ArrayListUnmanaged(Param) = .empty;
        var it = obj.iterator();
        while (it.next()) |kv| {
            // Strings only. A parameter reaches a plugin as an environment
            // variable, and there is no sensible rendering of a nested
            // object as one -- guessing at it would put something arbitrary
            // where the user expected their value.
            const value = switch (kv.value_ptr.*) {
                .string => |v| v,
                else => continue,
            };
            out.append(arena, .{
                .name = kv.key_ptr.*,
                .value = value,
            }) catch return out.items;
        }
        return out.items;
    }
};

/// What came of running one.
pub const Outcome = enum {
    /// Exit code zero. The plugin says it did the job.
    done,

    /// Exit code non-zero: the plugin says it failed.
    refused,

    /// Killed for taking too long.
    timed_out,

    /// Could not be started at all.
    unstartable,

    /// A parameter names something that could not be fetched -- a locked
    /// vault, a missing file. The plugin was not run: handing it a
    /// half-resolved set of parameters would have it send the reference
    /// itself somewhere.
    unresolved,
};

/// Resolve `params` and run the plugin with them.
///
/// `body` is the part of the JSON that is the same whatever the plugin --
/// the event, the message, which terminal. This wraps it with a `params`
/// object built by resolving each configured value, and hands the whole
/// thing over on stdin.
///
/// Resolution happens **here, once, at the moment of the call**. Nothing
/// is cached: a vault that has locked since this morning must fail, and a
/// cache would hide that it locked at all.
pub fn call(
    manifest: Manifest,
    alloc: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    body: []const u8,
    params: []const Param,
) Outcome {
    // The params object is rendered on its own, so the JSON writer owns a
    // complete value and its state machine stays honest. Splicing into a
    // half-written object is what it asserts against, and rightly.
    var rendered: std.Io.Writer.Allocating = .init(alloc);
    defer rendered.deinit();

    {
        var s: std.json.Stringify = .{ .writer = &rendered.writer, .options = .{} };
        s.beginObject() catch return .unstartable;
        for (params) |p| {
            const value = secret.resolve(alloc, io, env, p.value) catch {
                log.warn(
                    "plugin {s}: could not resolve {s}, not running it",
                    .{ manifest.key, p.name },
                );
                return .unresolved;
            };
            defer alloc.free(value);

            s.objectField(p.name) catch return .unstartable;
            s.write(value) catch return .unstartable;
        }
        s.endObject() catch return .unstartable;
    }

    // `body` is already an object; params go in beside its fields rather
    // than under them, so a plugin author reads one flat thing.
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    const inner = if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}')
        std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n")
    else
        "";

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    out.writer.writeAll("{") catch return .unstartable;
    if (inner.len > 0) {
        out.writer.writeAll(inner) catch return .unstartable;
        out.writer.writeAll(",") catch return .unstartable;
    }
    out.writer.writeAll("\"params\":") catch return .unstartable;
    out.writer.writeAll(rendered.written()) catch return .unstartable;
    out.writer.writeAll("}") catch return .unstartable;

    return run(manifest, alloc, io, out.written());
}

/// Run a plugin, giving it `input` on stdin.
///
/// Never returns an error. Every way this can go wrong is a way a
/// *notification* fails, and a failed notification must not propagate into
/// whatever was being reported -- the terminals go on talking either way.
///
/// `input` normally holds resolved credentials, which is why it goes on
/// stdin rather than into the environment or the argument list: both of
/// those are readable by any process the plugin itself starts, and by
/// anyone running `ps`.
pub fn run(
    manifest: Manifest,
    alloc: Allocator,
    io: std.Io,
    input: []const u8,
) Outcome {
    var child = std.process.spawn(io, .{
        .argv = &.{manifest.exec},
        .stdin = .pipe,

        // Ignored rather than captured: a plugin has nothing to tell us
        // that the exit code does not already say, and reading a pipe we
        // do not care about is one more thing that can block.
        .stdout = .ignore,

        // Inherited so that whatever a plugin complains about lands
        // wherever Polter's own output goes. Its author put it there to be
        // read.
        .stderr = .inherit,
    }) catch |err| {
        log.warn("plugin {s}: could not start err={}", .{ manifest.key, err });
        return .unstartable;
    };

    // Write, then close: a plugin reading to end-of-input has to see one.
    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(io, input) catch |err| {
            log.warn("plugin {s}: could not write err={}", .{ manifest.key, err });
        };
        stdin.close(io);
        child.stdin = null;
    }

    _ = alloc;

    // Waiting has no timeout of its own, so the clock runs on another
    // thread. It signals the child; the wait below then returns on its own
    // because the process is gone. Why a signal and not `Child.kill`, and
    // why the reaper holds a lock, are both in `reap.zig` -- the same
    // machinery keeps the resident archive plugin in line.
    var reaper: reap.Reaper = .init(io, manifest.key, child.id, manifest.timeout_ms);
    const thread = std.Thread.spawn(.{}, reap.Reaper.run, .{&reaper}) catch null;

    const term = child.wait(io) catch |err| {
        log.warn("plugin {s}: could not wait err={}", .{ manifest.key, err });
        reaper.retire();
        if (thread) |t| t.join();
        return .unstartable;
    };

    reaper.retire();
    if (thread) |t| t.join();

    if (reaper.killed()) return .timed_out;

    return switch (term) {
        .exited => |code| if (code == 0) .done else .refused,
        else => .refused,
    };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

/// Write a throwaway script and give back its path, owned by `arena`.
fn scriptFor(arena: Allocator, io: std.Io, body: []const u8) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);

    const dir = try std.fmt.allocPrint(arena, "/tmp/polter-plug-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);

    var f = try d.createFile(io, "run.sh", .{ .permissions = .fromMode(0o755) });
    try f.writeStreamingAll(io, body);
    f.close(io);

    return std.fmt.allocPrint(arena, "{s}/run.sh", .{dir});
}

/// Write a throwaway `plugin.json` and give back its directory, owned by
/// `arena`. The caller deletes it.
fn manifestFor(arena: Allocator, io: std.Io, json: []const u8) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);

    const dir = try std.fmt.allocPrint(arena, "/tmp/polter-man-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);

    var f = try d.createFile(io, "plugin.json", .{});
    try f.writeStreamingAll(io, json);
    f.close(io);

    return dir;
}

test "a plugin that exits zero has done the job" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = try scriptFor(alloc, io, "#!/bin/sh\nexit 0\n");
    const outcome = run(
        .{ .key = "ok", .kind = .notify, .exec = path },
        alloc,
        io,
        "{}",
    );
    try testing.expectEqual(Outcome.done, outcome);
}

test "a plugin that exits non-zero has refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = try scriptFor(alloc, io, "#!/bin/sh\nexit 3\n");
    const outcome = run(
        .{ .key = "nope", .kind = .notify, .exec = path },
        alloc,
        io,
        "{}",
    );
    try testing.expectEqual(Outcome.refused, outcome);
}

test "what goes in on stdin is what the plugin reads" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const out = try std.fmt.allocPrint(alloc, "/tmp/polter-in-{x}", .{&raw});

    const body = try std.fmt.allocPrint(
        alloc,
        "#!/bin/sh\ncat > {s}\nexit 0\n",
        .{out},
    );
    const path = try scriptFor(alloc, io, body);

    const outcome = run(
        .{ .key = "echo", .kind = .notify, .exec = path },
        alloc,
        io,
        "{\"event\":\"confirmation_needed\"}",
    );
    try testing.expectEqual(Outcome.done, outcome);

    const got = try std.Io.Dir.cwd().readFileAlloc(io, out, alloc, .limited(4096));
    try testing.expectEqualStrings("{\"event\":\"confirmation_needed\"}", got);
}

test "a plugin that hangs is killed rather than waited on" {
    // The case this matters for: nobody is watching. A plugin that cannot
    // reach the network would otherwise sit there until morning.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = try scriptFor(alloc, io, "#!/bin/sh\nsleep 30\n");
    const outcome = run(
        .{ .key = "hang", .kind = .notify, .exec = path, .timeout_ms = 300 },
        alloc,
        io,
        "{}",
    );
    try testing.expectEqual(Outcome.timed_out, outcome);
}

test "a plugin that is not there is not a crash" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const outcome = run(
        .{ .key = "ghost", .kind = .notify, .exec = "/nonexistent/plugin" },
        alloc,
        threaded.io(),
        "{}",
    );
    try testing.expectEqual(Outcome.unstartable, outcome);
}

test "resolved parameters arrive as plain values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("POLTER_TEST_KEY", "s3cret");

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const out = try std.fmt.allocPrint(alloc, "/tmp/polter-call-{x}", .{&raw});

    const body = try std.fmt.allocPrint(alloc, "#!/bin/sh\ncat > {s}\n", .{out});
    const path = try scriptFor(alloc, io, body);

    const outcome = call(
        .{ .key = "feishu", .kind = .notify, .exec = path },
        alloc,
        io,
        &env,
        "{\"event\":\"confirmation_needed\"}",
        &.{
            .{ .name = "webhook", .value = "https://example/hook" },
            .{ .name = "signing_key", .value = "env:POLTER_TEST_KEY" },
        },
    );
    try testing.expectEqual(Outcome.done, outcome);

    const got = try std.Io.Dir.cwd().readFileAlloc(io, out, alloc, .limited(4096));

    // The event survives, the literal survives, and the reference has
    // become the value it points at -- not the reference.
    try testing.expect(std.mem.indexOf(u8, got, "\"event\":\"confirmation_needed\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"webhook\":\"https://example/hook\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"signing_key\":\"s3cret\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "env:") == null);
}

test "a parameter that will not resolve stops the call" {
    // The plugin must not run at all. Running it with the reference in
    // place would send `cmd:...` to Feishu as though it were the key.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const marker = try std.fmt.allocPrint(alloc, "/tmp/polter-ran-{x}", .{&raw});

    const body = try std.fmt.allocPrint(alloc, "#!/bin/sh\ntouch {s}\n", .{marker});
    const path = try scriptFor(alloc, io, body);

    const outcome = call(
        .{ .key = "feishu", .kind = .notify, .exec = path },
        alloc,
        io,
        &env,
        "{}",
        &.{.{ .name = "signing_key", .value = "env:POLTER_TEST_ABSENT" }},
    );
    try testing.expectEqual(Outcome.unresolved, outcome);

    // Nothing ran: the plugin would have created this if it had.
    try testing.expect(std.Io.Dir.cwd().readFileAlloc(
        io,
        marker,
        alloc,
        .limited(16),
    ) == error.FileNotFound);
}

test "a manifest is read, and its exec made absolute" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-man-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);

    var f = try d.createFile(io, "plugin.json", .{});
    try f.writeStreamingAll(io,
        \\{"key":"feishu","name":"飞书","kind":"notify","exec":"send.sh","timeout_ms":5000}
    );
    f.close(io);

    const m = try load(alloc, io, dir);
    try testing.expectEqualStrings("feishu", m.key);
    try testing.expectEqualStrings("飞书", m.name);
    try testing.expectEqual(Kind.notify, m.kind);
    try testing.expectEqual(@as(u64, 5000), m.timeout_ms);

    // Absolute, so running it never depends on where Polter happens to be.
    const want = try std.fmt.allocPrint(alloc, "{s}/send.sh", .{dir});
    try testing.expectEqualStrings(want, m.exec);
}

test "a manifest for a kind this build does not know is skipped, not fatal" {
    // A newer plugin should be passed over quietly. Refusing to start
    // because one directory mentions a future feature would be worse.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-man-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    var f = try d.createFile(io, "plugin.json", .{});
    try f.writeStreamingAll(io, "{\"key\":\"future\",\"kind\":\"sensor\",\"exec\":\"x\"}");
    f.close(io);

    try testing.expectError(error.UnknownKind, load(alloc, io, dir));
}

test "a manifest missing what it needs is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-man-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    var f = try d.createFile(io, "plugin.json", .{});
    try f.writeStreamingAll(io, "{\"name\":\"nameless\"}");
    f.close(io);

    try testing.expectError(error.BadManifest, load(alloc, io, dir));
    try testing.expectError(error.NoManifest, load(alloc, io, "/tmp/polter-no-dir-9c1f"));
}

test "settings round-trip through the file format" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const params = [_]Param{
        .{ .name = "url", .value = "cmd:op read op://Private/hook" },
    };
    const rendered = try (Settings{ .enabled = true, .params = &params }).render(alloc);

    // The secret stayed a reference. Rendering a resolved value into the
    // file is the whole thing `secret.zig` exists to avoid.
    try testing.expect(std.mem.indexOf(u8, rendered, "cmd:op read") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\"enabled\": true") != null);
}

test "the older flat file still delivers" {
    // Before this, the file held parameters alone and the main config said
    // which plugins were on. Reading such a file as "not enabled" would stop
    // delivering notifications for somebody who changed nothing.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-set-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    var f = try d.createFile(io, "webhook.json", .{});
    try f.writeStreamingAll(io,
        \\{"url":"https://example.com/hook"}
    );
    f.close(io);

    const path = try std.fmt.allocPrint(alloc, "{s}/webhook.json", .{dir});
    const settings = Settings.read(alloc, io, path);

    try testing.expect(settings.enabled);
    try testing.expectEqual(@as(usize, 1), settings.params.len);
    try testing.expectEqualStrings("url", settings.params[0].name);
}

test "a plugin nobody has configured is not enabled" {
    // Missing and unreadable both mean "not set up", and something not set
    // up must not be sending anything anywhere.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const settings = Settings.read(
        arena.allocator(),
        threaded.io(),
        "/tmp/polter-no-such-plugin-7f31.json",
    );
    try testing.expect(!settings.enabled);
    try testing.expectEqual(@as(usize, 0), settings.params.len);
}

test "switched off means off, however many parameters are set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-off-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    var f = try d.createFile(io, "webhook.json", .{});
    try f.writeStreamingAll(io,
        \\{"enabled":false,"params":{"url":"https://example.com/hook"}}
    );
    f.close(io);

    const path = try std.fmt.allocPrint(alloc, "{s}/webhook.json", .{dir});
    const settings = Settings.read(alloc, io, path);

    try testing.expect(!settings.enabled);
    try testing.expectEqual(@as(usize, 1), settings.params.len);
}

test "a manifest may declare an archive" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"chat-archive","kind":"archive","exec":"archive.sh"}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expectEqual(Kind.archive, m.kind);
    try testing.expect(m.wants.empty());
}

test "what a manifest wants is read back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"chat-archive","kind":"archive","exec":"a.sh",
        \\ "wants":{"groups":["build","ops"],"network":true,"exec":["psql"]}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expectEqual(@as(usize, 2), m.wants.groups.len);
    try testing.expectEqualStrings("build", m.wants.groups[0]);
    try testing.expectEqualStrings("ops", m.wants.groups[1]);
    try testing.expect(m.wants.network);
    try testing.expectEqual(@as(usize, 1), m.wants.exec.len);
    try testing.expectEqualStrings("psql", m.wants.exec[0]);

    try testing.expect(m.wants.allows("build"));
    try testing.expect(m.wants.allows("ops"));
    try testing.expect(!m.wants.allows("secrets"));
    try testing.expect(!m.wants.empty());
}

test "a manifest that declares nothing wants nothing" {
    // The one change that would quietly void the whole feature is reading
    // silence as `["*"]` because an archive "is not getting anything". That
    // hands every group to the one manifest that never asked for a single
    // one, which is the entire thing the declaration exists to stop. A
    // plugin that is fed nothing is loud about it -- `Archive.start`
    // refuses and the user is told which line to add.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"chat-archive","kind":"archive","exec":"a.sh"}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expect(m.wants.empty());
    try testing.expect(!m.wants.allows("build"));
    try testing.expect(!m.wants.allows("*"));
    try testing.expect(!m.wants.network);
    try testing.expectEqual(@as(usize, 0), m.wants.exec.len);
}

test "a star means every group" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"chat-archive","kind":"archive","exec":"a.sh","wants":{"groups":["*"]}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expect(m.wants.allows("build"));
    try testing.expect(m.wants.allows("anything at all"));
    try testing.expect(!m.wants.empty());
}

test "a wants that will not parse wants nothing" {
    // Both of these load. A typo in one field may not delete a plugin: its
    // author would find a plugin that vanished harder to explain than a
    // plugin that is handed nothing and says so in the log.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const not_object = try manifestFor(alloc, io,
        \\{"key":"chat-archive","kind":"archive","exec":"a.sh","wants":7}
    );
    defer std.Io.Dir.cwd().deleteTree(io, not_object) catch {};

    const m = try load(alloc, io, not_object);
    try testing.expect(m.wants.empty());

    const bare_string = try manifestFor(alloc, io,
        \\{"key":"chat-archive","kind":"archive","exec":"a.sh","wants":{"groups":"build"}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, bare_string) catch {};

    // A bare string is not a list of one group. Somebody who got the type
    // wrong has not said which groups they want, and reading it as `build`
    // is the same widening as reading silence as `*`, only smaller.
    const b = try load(alloc, io, bare_string);
    try testing.expect(b.wants.empty());
    try testing.expect(!b.wants.allows("build"));
}

test "a group not asked for is not allowed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"chat-archive","kind":"archive","exec":"a.sh","wants":{"groups":["build"]}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expect(m.wants.allows("build"));
    try testing.expect(!m.wants.allows("ops"));

    // Whole names, never prefixes: a group called `build` must not drag in
    // one called `build2`, and matching by prefix would.
    try testing.expect(!m.wants.allows("bui"));
    try testing.expect(!m.wants.allows("build2"));
    try testing.expect(!m.wants.allows(""));
}

test "junk in the groups list is skipped, not fatal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"chat-archive","kind":"archive","exec":"a.sh",
        \\ "wants":{"groups":["build",7,"ops"]}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expectEqual(@as(usize, 2), m.wants.groups.len);
    try testing.expectEqualStrings("build", m.wants.groups[0]);
    try testing.expectEqualStrings("ops", m.wants.groups[1]);
    try testing.expect(m.wants.allows("build"));
    try testing.expect(m.wants.allows("ops"));
    try testing.expect(!m.wants.allows("7"));
}
