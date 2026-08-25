//! Running somebody else's script on our behalf.
//!
//! A plugin is a directory with a `plugin.json` and an executable. Polter
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

/// Most parameters one manifest may declare.
///
/// The list is copied into every `plugin_list` reply, which an agent reads,
/// so a bound on it is a bound on that reply. The manifest itself is only
/// capped at 64KB, and that is room for hundreds of one-character property
/// names -- a broken generator or a hostile file should not be able to
/// spend somebody's context on them.
const max_specs: usize = 64;

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

/// One parameter as the plugin declares it.
///
/// Read out of the manifest's `params` JSON Schema, which is where a
/// plugin author already writes this down -- a second place to say it
/// would drift from the first.
pub const ParamSpec = struct {
    name: []const u8,
    title: []const u8 = "",
    description: []const u8 = "",
    required: bool = false,

    /// Declared `"secret": true`. This is the plugin author saying "this
    /// one is a credential", and it is the only thing that decides it --
    /// guessing from the name would get `url` wrong in both directions.
    /// The tool surface will not write a plaintext value into one.
    secret: bool = false,

    /// What a JSON Schema `enum` allows, empty when the value is open.
    /// A closed set is the one case where a configured value may be shown
    /// back to an agent: it cannot be holding a password.
    choices: []const []const u8 = &.{},

    /// Whether `value` is one this parameter takes. An open parameter
    /// takes anything, so a spec with no `enum` allows everything -- the
    /// alternative would have a missing annotation refuse every value.
    pub fn allows(self: ParamSpec, value: []const u8) bool {
        if (self.choices.len == 0) return true;
        for (self.choices) |c| if (std.mem.eql(u8, c, value)) return true;
        return false;
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

    /// Everything declared under `params.properties`. Empty when the
    /// manifest declares none, and that is meaningful: a plugin with no
    /// declared parameters has none that the tool surface may set.
    params: []const ParamSpec = &.{},

    /// The parameter by that name, if the manifest declares one.
    pub fn param(self: Manifest, name: []const u8) ?ParamSpec {
        for (self.params) |p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }
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
    if (!isPlainName(key)) {
        log.warn(
            "plugin: {s} has the key {s}, which is not a plain name, so it is not loaded",
            .{ path, key },
        );
        return error.BadKey;
    }

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
        .params = specsOf(arena, key, obj),
    };
}

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |v| v,
        else => null,
    };
}

/// Whether a key is a name and nothing more.
///
/// A key is not just an identifier: it is spelled straight into three file
/// paths -- `<config>/polter/plugins/<key>.json` on both the reading and the
/// writing side, and `<state>/polter/plugins/<key>.cursor`. A key holding a
/// separator or a `..` therefore names a file outside the polter directories,
/// and `Settings.write` creates the directories on the way to it. Checking it
/// here is the one place that knows a key becomes a filename; the callers see
/// a string and cannot tell.
///
/// The rule is deliberately narrower than "no traversal": a key is also what
/// a person types into `plugin_configure` and reads in a listing, so anything
/// that does not survive being written down plainly is refused too.
fn isPlainName(key: []const u8) bool {
    if (key.len == 0 or key.len > 64) return false;
    if (std.mem.eql(u8, key, ".") or std.mem.eql(u8, key, "..")) return false;

    for (key) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return false,
    };
    return true;
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
        .groups = stringsOf(arena, key, w, "groups", "wants.groups"),
        .network = switch (w.get("network") orelse .null) {
            .bool => |b| b,
            else => false,
        },
        .exec = stringsOf(arena, key, w, "exec", "wants.exec"),
    };
}

/// What the manifest declares under `params`.
///
/// The same rule as `wantsOf`: a schema that will not read leaves the
/// plugin with no declared parameters rather than making the whole plugin
/// vanish. The direction is safe here too -- an undeclared parameter is one
/// the tool surface refuses to set, because a name that is not in the
/// schema cannot be judged secret or not.
fn specsOf(arena: Allocator, key: []const u8, obj: std.json.ObjectMap) []const ParamSpec {
    const schema = switch (obj.get("params") orelse return &.{}) {
        .object => |o| o,
        else => {
            log.warn(
                "plugin {s}: params is not an object, so it is read as declaring none",
                .{key},
            );
            return &.{};
        },
    };

    const properties = switch (schema.get("properties") orelse return &.{}) {
        .object => |o| o,
        else => {
            log.warn(
                "plugin {s}: params.properties is not an object, so it is read as declaring none",
                .{key},
            );
            return &.{};
        },
    };

    const required = stringsOf(arena, key, schema, "required", "params.required");

    var out: std.ArrayListUnmanaged(ParamSpec) = .empty;
    var it = properties.iterator();
    while (it.next()) |kv| {
        if (out.items.len >= max_specs) {
            log.warn(
                "plugin {s}: declares more than {d} parameters, and the rest are passed over",
                .{ key, max_specs },
            );
            break;
        }

        const name = kv.key_ptr.*;

        // A property with no name at all would round-trip: `Manifest.param`
        // would match the empty string, `Settings.render` would write an
        // object field with an empty name, and `paramsOf` would read it back
        // as a real parameter nobody can refer to.
        if (name.len == 0) {
            log.warn(
                "plugin {s}: params.properties has an unnamed entry and it is passed over",
                .{key},
            );
            continue;
        }

        const field = switch (kv.value_ptr.*) {
            .object => |o| o,
            else => {
                log.warn(
                    "plugin {s}: params.properties.{s} is not an object and is passed over",
                    .{ key, name },
                );
                continue;
            },
        };

        out.append(arena, .{
            .name = name,
            .title = stringField(field, "title") orelse "",
            .description = stringField(field, "description") orelse "",
            .required = contains(required, name),

            // Anything that is not `true` is not a declaration that this
            // holds a credential. Missing is the common case and reads as
            // false -- which is safe only because the listing side never
            // shows a plaintext value whatever this says; see `rpc.Guard`.
            .secret = switch (field.get("secret") orelse .null) {
                .bool => |b| b,
                else => false,
            },
            .choices = choicesOf(arena, key, name, field),
        }) catch {
            // Cut short rather than voided, for the same reason `stringsOf`
            // does: a shorter list of declared parameters means fewer the
            // tool surface will set, never more.
            log.warn(
                "plugin {s}: ran out of memory reading params, so only the first {d} are declared",
                .{ key, out.items.len },
            );
            break;
        };
    }
    return out.items;
}

/// A parameter's `enum`, labelled with the parameter it belongs to.
///
/// Built here rather than in `specsOf` so a failure to name the path never
/// costs the declaration itself: a label that will not render leaves the
/// generic one, and the choices are read either way.
fn choicesOf(
    arena: Allocator,
    key: []const u8,
    name: []const u8,
    field: std.json.ObjectMap,
) []const []const u8 {
    var buf: [128]u8 = undefined;
    const where = std.fmt.bufPrint(
        &buf,
        "params.properties.{s}.enum",
        .{name},
    ) catch "params.properties.<name>.enum";
    return stringsOf(arena, key, field, "enum", where);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
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
    /// Where this field sits, for the warnings only. The lookup uses
    /// `name`; a reader chasing one of these needs the whole path.
    where: []const u8,
) []const []const u8 {
    const items = switch (obj.get(name) orelse return &.{}) {
        .array => |a| a.items,
        else => {
            log.warn(
                "plugin {s}: {s} is not a list, so it is read as naming nothing",
                .{ key, where },
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
                "plugin {s}: ran out of memory reading {s}, so only the first {d} of {d} are honoured",
                .{ key, where, out.items.len, items.len },
            );
            break;
        };
    }
    if (skipped > 0) log.warn(
        "plugin {s}: passed over {d} entries in {s} that are not text",
        .{ key, skipped, where },
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

    /// Fold `changes` into these settings.
    ///
    /// A name in `changes` replaces whatever was there; a name that is not
    /// mentioned is kept. **An empty value removes a parameter**, which is
    /// how one is unset -- a configured value is never legitimately empty,
    /// so there is nothing to confuse it with.
    ///
    /// Everything in the result belongs to `arena`, including the strings,
    /// so it outlives both the settings that were read and the request the
    /// changes came out of.
    ///
    /// `enabled` is carried over from `self` untouched. Whether a plugin is
    /// switched on is not something merging parameters decides, and a caller
    /// that forgets to set it on the result would write `enabled: false` back
    /// over the plugin it was just asked to switch on.
    pub fn merge(
        self: Settings,
        arena: Allocator,
        changes: []const Param,
    ) Allocator.Error!Settings {
        var out: std.ArrayListUnmanaged(Param) = .empty;

        for (self.params) |old| {
            // The last mention wins, so a caller that names one parameter
            // twice gets what it wrote last rather than an arbitrary one.
            var replacement: ?[]const u8 = null;
            for (changes) |c| {
                if (std.mem.eql(u8, c.name, old.name)) replacement = c.value;
            }

            const value = replacement orelse old.value;
            if (value.len == 0) continue;

            try out.append(arena, .{
                .name = try arena.dupe(u8, old.name),
                .value = try arena.dupe(u8, value),
            });
        }

        for (changes) |c| {
            // Clearing something that was not set is not an error; it is
            // already in the state that was asked for.
            if (c.value.len == 0) continue;
            if (hasParam(out.items, c.name)) continue;

            try out.append(arena, .{
                .name = try arena.dupe(u8, c.name),
                .value = try arena.dupe(u8, c.value),
            });
        }

        return .{ .enabled = self.enabled, .params = out.items };
    }

    /// Write these settings out, creating the directory if it is not there.
    ///
    /// Through a temporary file and a rename, and **the rename is the commit
    /// point**: a `<path>.new` found on disk is a write that never reached
    /// it. A settings file caught half written parses as nothing, and nothing
    /// reads as "not configured", which reads as "off" -- a crash mid-write
    /// would silently switch a plugin off and say nothing.
    ///
    /// **This rewrites the file whole, out of what `read` understood.** Only
    /// `enabled` and string-valued parameters survive a round trip: a
    /// hand-written file holding a number, a nested object, a comment-shaped
    /// key or anything else loses it the first time this runs. Nothing new --
    /// `read` and `render` have always been this pair -- but this is the
    /// first thing that lets an agent trigger it, so a user has to be told
    /// before they let one near a file they wrote.
    pub fn write(
        self: Settings,
        alloc: Allocator,
        io: std.Io,
        path: []const u8,
    ) !void {
        const bytes = try self.render(alloc);
        defer alloc.free(bytes);

        const dir = std.fs.path.dirname(path) orelse ".";
        try std.Io.Dir.cwd().createDirPath(io, dir);

        // Beside the real file, so the rename stays within one filesystem.
        // A rename across filesystems is a copy, and a copy is the thing
        // this is here to avoid.
        const tmp = try std.fmt.allocPrint(alloc, "{s}.new", .{path});
        defer alloc.free(tmp);

        // Armed before anything creates the file, not after: a failure to
        // create, write or close it would otherwise leave `<path>.new` lying
        // beside the real file for good, because the only thing that removed
        // it was declared after the block that could fail.
        errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

        {
            var f = try std.Io.Dir.cwd().createFile(io, tmp, .{
                // The parameters here are references far more often than
                // they are secrets, but not always -- a hand-written file
                // may hold a literal, and this rewrites such a file.
                .permissions = .fromMode(0o600),
            });
            defer f.close(io);
            try f.writeStreamingAll(io, bytes);
        }

        const cwd = std.Io.Dir.cwd();
        try cwd.rename(tmp, cwd, path, io);
    }

    /// Whether a name is already in this list.
    ///
    /// Walked rather than indexed: a plugin has a handful of parameters,
    /// and a map would be an allocation that can fail halfway through a
    /// merge for no gain anybody would measure.
    fn hasParam(params: []const Param, name: []const u8) bool {
        for (params) |p| if (std.mem.eql(u8, p.name, name)) return true;
        return false;
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

test "a manifest keeps the parameters it declares" {
    // The tool surface has to know what a plugin takes, and the plugin's
    // author already writes it down here. Reading it a second time from
    // somewhere else would be a second place to keep in step.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"chat-archive","kind":"archive","exec":"a.sh",
        \\ "params":{"type":"object",
        \\   "properties":{
        \\     "backend":{"type":"string","title":"Where to write",
        \\                "description":"postgres or file","enum":["postgres","file"]},
        \\     "dsn":{"type":"string","title":"Postgres connection URI","secret":true},
        \\     "schema":{"type":"string"}},
        \\   "required":["backend"]}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expectEqual(@as(usize, 3), m.params.len);

    const backend = m.param("backend").?;
    try testing.expectEqualStrings("Where to write", backend.title);
    try testing.expectEqualStrings("postgres or file", backend.description);
    try testing.expect(backend.required);
    try testing.expect(!backend.secret);
    try testing.expectEqual(@as(usize, 2), backend.choices.len);
    try testing.expect(backend.allows("postgres"));
    try testing.expect(backend.allows("file"));
    try testing.expect(!backend.allows("sqlite"));

    // Secret is the author's declaration and nothing else's guess: `dsn`
    // says so, `schema` does not, and neither name would have told anybody.
    const dsn = m.param("dsn").?;
    try testing.expect(dsn.secret);
    try testing.expect(!dsn.required);

    // An open parameter takes anything. A missing `enum` must not read as
    // an empty one, or every value would be refused.
    const schema = m.param("schema").?;
    try testing.expect(!schema.secret);
    try testing.expectEqual(@as(usize, 0), schema.choices.len);
    try testing.expect(schema.allows("public"));

    try testing.expectEqual(@as(?ParamSpec, null), m.param("nothing-like-this"));

    // And it keeps at most `max_specs` of them. Every declared parameter is
    // copied into every `plugin_list` reply an agent reads, and the only
    // other bound on that is the 64KB the manifest itself is read under --
    // which is room for hundreds of one-character names.
    {
        var json: std.Io.Writer.Allocating = .init(alloc);
        try json.writer.writeAll(
            \\{"key":"many","kind":"notify","exec":"a.sh",
            \\ "params":{"type":"object","properties":{
        );
        for (0..max_specs + 8) |i| {
            if (i > 0) try json.writer.writeAll(",");
            try json.writer.print("\"p{d}\":{{\"type\":\"string\"}}", .{i});
        }
        try json.writer.writeAll("}}}");

        const capped = try manifestFor(alloc, io, json.written());
        defer std.Io.Dir.cwd().deleteTree(io, capped) catch {};

        const many = try load(alloc, io, capped);
        try testing.expectEqual(max_specs, many.params.len);
    }
}

test "a key that is not a plain name is not a plugin" {
    // A key is spelled into three file paths, and one of them is now
    // written rather than only read. A key of `../../../x` therefore names
    // a settings file outside the polter directories, and `Settings.write`
    // makes the directories on the way to it. Nothing downstream can tell:
    // by then it is a string like any other.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bad = [_][]const u8{
        "../../../.ssh/authorized_keys",
        "a/b",
        "a\\\\b",
        "..",
        ".",
        "with space",
        "",
    };

    for (bad) |key| {
        const json = try std.fmt.allocPrint(
            alloc,
            "{{\"key\":\"{s}\",\"kind\":\"notify\",\"exec\":\"a.sh\"}}",
            .{key},
        );
        const dir = try manifestFor(alloc, io, json);
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

        // Refused at load, so nothing later has to remember to check: a
        // plugin that will not load is one nothing can configure, start, or
        // write a settings file for.
        try testing.expectError(error.BadKey, load(alloc, io, dir));
    }

    // What an ordinary key looks like, so the rule cannot quietly tighten
    // into refusing the plugins that ship with Polter.
    for ([_][]const u8{ "chat-archive", "webhook", "feishu_v2", "a.b" }) |key| {
        const json = try std.fmt.allocPrint(
            alloc,
            "{{\"key\":\"{s}\",\"kind\":\"notify\",\"exec\":\"a.sh\"}}",
            .{key},
        );
        const dir = try manifestFor(alloc, io, json);
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

        const m = try load(alloc, io, dir);
        try testing.expectEqualStrings(key, m.key);
    }
}

test "a parameter with no name is not a parameter" {
    // A property whose name is the empty string would round-trip as a real
    // one: `Manifest.param("")` matches it, `Settings.render` writes an
    // object field with an empty name, and `Settings.read` reads that back
    // as configured. Nothing could ever refer to it, and the tool surface
    // would be willing to set it.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"webhook","kind":"notify","exec":"send.sh",
        \\ "params":{"type":"object","properties":{
        \\   "":{"type":"string","secret":true},
        \\   "url":{"type":"string"}}}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);

    // Passed over, and the plugin still loads: one bad property is the same
    // sort of typo as a bad `wants`, and it must not make the whole plugin
    // vanish.
    try testing.expectEqual(@as(usize, 1), m.params.len);
    try testing.expectEqualStrings("url", m.params[0].name);
    try testing.expectEqual(@as(?ParamSpec, null), m.param(""));
}

test "a manifest with no params schema declares no parameters" {
    // Silence means none, and none means the tool surface may set none.
    // The alternative -- reading silence as "anything goes" -- would let an
    // agent write a name nobody can judge secret or not.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    {
        const dir = try manifestFor(alloc, io,
            \\{"key":"webhook","kind":"notify","exec":"send.sh"}
        );
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

        const m = try load(alloc, io, dir);
        try testing.expectEqual(@as(usize, 0), m.params.len);
        try testing.expectEqual(@as(?ParamSpec, null), m.param("url"));
    }

    // A schema that will not read leaves the plugin with no declared
    // parameters rather than making the whole plugin vanish -- the same
    // rule `wants` follows, and for the same reason.
    {
        const dir = try manifestFor(alloc, io,
            \\{"key":"webhook","kind":"notify","exec":"send.sh","params":"oops"}
        );
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

        const m = try load(alloc, io, dir);
        try testing.expectEqualStrings("webhook", m.key);
        try testing.expectEqual(@as(usize, 0), m.params.len);
    }

    {
        const dir = try manifestFor(alloc, io,
            \\{"key":"webhook","kind":"notify","exec":"send.sh",
            \\ "params":{"type":"object","properties":["url"]}}
        );
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

        const m = try load(alloc, io, dir);
        try testing.expectEqual(@as(usize, 0), m.params.len);
    }
}

test "settings merge keeps what was not named, and an empty value clears one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const before: Settings = .{ .enabled = true, .params = &.{
        .{ .name = "backend", .value = "file" },
        .{ .name = "dsn", .value = "env:OLD" },
        .{ .name = "stream", .value = "laptop" },
    } };

    const after = try before.merge(alloc, &.{
        .{ .name = "backend", .value = "postgres" },
        .{ .name = "dsn", .value = "" },
        .{ .name = "schema", .value = "public" },
    });

    // Whether it is switched on is not a parameter, and merging parameters
    // does not touch it.
    try testing.expect(after.enabled);

    try testing.expectEqualStrings("postgres", valueOf(after, "backend").?);

    // Cleared, not emptied: an unset parameter is absent from the file, so
    // the plugin sees nothing there rather than a value that is nothing.
    try testing.expectEqual(@as(?[]const u8, null), valueOf(after, "dsn"));

    // Untouched names survive, which is what makes a configure call able to
    // change one thing without knowing the rest.
    try testing.expectEqualStrings("laptop", valueOf(after, "stream").?);

    // A name that was not there is added rather than dropped.
    try testing.expectEqualStrings("public", valueOf(after, "schema").?);

    // And exactly once: a replaced parameter must not also be appended.
    try testing.expectEqual(@as(usize, 3), after.params.len);

    // Clearing something that was never set is not an error; it is already
    // the state that was asked for.
    const nothing = try after.merge(alloc, &.{.{ .name = "absent", .value = "" }});
    try testing.expectEqual(@as(usize, 3), nothing.params.len);

    // The result owns its strings, so it outlives whatever it was read out
    // of and whatever the changes came in on.
    const written = try after.render(alloc);
    try testing.expect(std.mem.indexOf(u8, written, "postgres") != null);
    try testing.expect(std.mem.indexOf(u8, written, "env:OLD") == null);
}

fn valueOf(s: Settings, name: []const u8) ?[]const u8 {
    for (s.params) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
    return null;
}

test "settings are written whole or not at all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const root = try std.fmt.allocPrint(alloc, "/tmp/polter-wr-{x}", .{&raw});
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // The directory does not exist yet, which is the ordinary case the
    // first time anybody configures anything.
    const path = try std.fmt.allocPrint(alloc, "{s}/plugins/chat-archive.json", .{root});

    const settings: Settings = .{ .enabled = true, .params = &.{
        .{ .name = "dsn", .value = "env:POLTER_PG" },
    } };
    try settings.write(alloc, io, path);

    const back = Settings.read(alloc, io, path);
    try testing.expect(back.enabled);
    try testing.expectEqualStrings("env:POLTER_PG", valueOf(back, "dsn").?);

    // Written again over itself, because that is what configuring twice
    // does and a rename onto an existing file has to be allowed.
    const second = try settings.merge(alloc, &.{.{ .name = "backend", .value = "postgres" }});
    try second.write(alloc, io, path);

    const again = Settings.read(alloc, io, path);
    try testing.expectEqual(@as(usize, 2), again.params.len);

    // Nothing half-written left behind.
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(io, try std.fmt.allocPrint(alloc, "{s}.new", .{path}), .{}),
    );
}
