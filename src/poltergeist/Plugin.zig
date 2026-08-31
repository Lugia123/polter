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

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");

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

/// One kind of thing that happens, as a manifest may subscribe to it.
///
/// **This is not `Kind`.** What a plugin *is* used to be one of three
/// values that each decided a lifetime and a contract at once, so every
/// place that switched on it had three branches and a fourth would be
/// forgotten -- which happened twice, the second time in the comment left
/// by the first. There is one lifetime and one contract now, and what
/// separates two plugins is only which of these they asked for. A plugin
/// that asks for two gets both on one stream; a plugin that asks for none
/// is not started, because there would be nothing to hand it.
///
/// The names here are the wire names, spelled with a dot where the Zig
/// identifier cannot have one. Every member has to exist as something
/// `Feed` can actually publish: a name a manifest may write and nothing
/// will ever send is a subscription that looks live and is not.
pub const Event = enum {
    /// Something was said in a chat group. This is what `archive` was.
    chat,

    /// A terminal has gone quiet and somebody should be told. This is what
    /// `notify` was.
    terminal_quiet,

    /// Here is what Polter is; make an agent runtime able to see it. This
    /// is what `provision` was.
    provision,

    /// The name a manifest writes.
    pub fn wireName(self: Event) []const u8 {
        return switch (self) {
            .chat => "chat",
            .terminal_quiet => "terminal.quiet",
            .provision => "provision",
        };
    }

    /// The event that name refers to, or null when it is not one of ours.
    ///
    /// Null rather than an error: a manifest written for a later build may
    /// name an event this one has never heard of, and the safe reading of
    /// that is "this build will not send it" -- not "this plugin does not
    /// load".
    pub fn parse(text: []const u8) ?Event {
        inline for (@typeInfo(Event).@"enum".fields) |f| {
            const e: Event = @enumFromInt(f.value);
            if (std.mem.eql(u8, e.wireName(), text)) return e;
        }
        return null;
    }
};

/// What a plugin says it needs.
///
/// **Declared so the host has something to refuse against**, not as a
/// certificate of good behaviour. That stance is unchanged; what changed is
/// how many of these are refusals rather than disclosures.
///
/// `events`, `groups` and `calls` are **enforced**, completely:
///
///   - `events` decides what the plugin is handed. It is not fed a kind it
///     did not ask for, so a chat archive never sees a notification and a
///     notifier never sees the chat log.
///   - `groups` decides which chat groups may appear in what it is handed,
///     and a plugin has no second channel to the log.
///   - `calls` decides which tool methods it may call. See `mayCall`.
///
/// `network` and `exec` are declaration and disclosure only -- they are
/// what a user reads before installing, and what an audit has to go on.
/// They are **not** a sandbox and nothing here stops a plugin doing either.
/// Saying that plainly is the point: `"network": false` must never be read
/// as "it cannot reach the network". Real isolation has to be designed
/// together with signing; see `docs/poltergeist/plugins.md`.
///
/// The line between the two halves is not how dangerous the thing is. It is
/// **whether the host stands on the path**. Every event goes through
/// `Feed`, every group through the batch writer, every tool call through
/// the socket this process is listening on -- those are chokepoints, and a
/// declaration at a chokepoint that is not enforced is a decision to hold a
/// gate open. A plugin's own `connect(2)` passes through nothing of ours,
/// so there is no gate there to hold either way.
///
/// Everything borrowed here comes from the arena the manifest was loaded
/// into. Anything that outlives one pass over the plugin directory has to
/// copy it: the arena is rebuilt whole every time the plugin list is.
pub const Wants = struct {
    /// Which kinds of event this plugin is handed. Empty means none, which
    /// is what a manifest that declares nothing gets -- and a plugin with
    /// nothing to be handed is not started at all.
    events: []const Event = &.{},

    /// Which tool methods this plugin may call over the socket, by name.
    ///
    /// Empty means none: a plugin that declares no calls gets a token and a
    /// socket path all the same, and every method it tries is refused. That
    /// is the direction a missing declaration has to fail in.
    calls: []const []const u8 = &.{},

    /// Which chat groups may appear in what this plugin is given. A single
    /// element `"*"` means all of them. Empty means none.
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

    /// Whether this plugin asked to be handed `e`.
    ///
    /// **No `"*"` here, deliberately**, and this is the one place the two
    /// enforced lists differ. A group is a name the user made up and there
    /// is no way to enumerate the ones that do not exist yet, so `"*"` is
    /// the only way to say "whatever I am in". The events are a closed set
    /// written down in this file: a plugin can name every one it wants, and
    /// a `"*"` would mean "and every one added after I was written", which
    /// is a subscription to code that does not exist.
    pub fn subscribes(self: Wants, e: Event) bool {
        for (self.events) |w| if (w == e) return true;
        return false;
    }

    /// Whether this plugin declared that it calls `method`.
    ///
    /// **Checked, not merely listed**, and it is checked *before* the
    /// ordinary authorisation. The two cannot conflict, because this one
    /// never grants: a call has to pass this list **and** the reachability
    /// rule, so what a plugin declares can only ever narrow what it may do.
    /// A method nobody has heard of is refused here, which is also the
    /// answer for a method name that is simply misspelled in the manifest.
    ///
    /// Exact names, no wildcard. The declaration is what a user reads
    /// before installing, and `"*"` would make that reading worthless
    /// exactly where it matters most.
    pub fn mayCall(self: Wants, method: []const u8) bool {
        for (self.calls) |c| if (std.mem.eql(u8, c, method)) return true;
        return false;
    }

    /// True when nothing was asked for, so there is nothing to hand over.
    /// The host says so rather than running a plugin it would then feed
    /// silence for ever.
    pub fn empty(self: Wants) bool {
        return self.events.len == 0;
    }

    /// True when this plugin subscribes to something group-shaped and named
    /// no groups, which is a manifest that will be fed nothing it is
    /// waiting for. Worth saying out loud, and not worth refusing over: the
    /// same plugin may be subscribed to `provision` as well, and that half
    /// works.
    pub fn groupless(self: Wants) bool {
        return self.subscribes(.chat) and self.groups.len == 0;
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

    // There is no `kind` any more. A manifest that still carries one is not
    // refused over it -- it is simply a field nothing reads -- but it is
    // said out loud once, because a plugin whose author believes `kind` is
    // still what starts it will otherwise sit there declaring nothing and
    // never being fed.
    if (stringField(obj, "kind")) |stale| log.warn(
        "plugin {s}: \"kind\": \"{s}\" is not read any more; what a plugin is " ++
            "handed comes from \"wants\": {{\"events\": [...]}}",
        .{ key, stale },
    );

    const exec_rel = stringField(obj, "exec") orelse {
        log.warn("plugin {s}: no exec", .{key});
        return error.BadManifest;
    };

    return .{
        .key = key,
        .name = stringField(obj, "name") orelse key,
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
/// A key is not just an identifier: it is spelled straight into four file
/// paths -- `<config>/polter/plugins/<key>.json` on both the reading and the
/// writing side, `<base>/polter/plugins/<key>/settings.json` for the copy a
/// release ships, and `<state>/polter/plugins/<key>.cursor`. A key holding a
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
        .events = eventsOf(arena, key, w),
        .calls = stringsOf(arena, key, w, "calls", "wants.calls"),
        .groups = stringsOf(arena, key, w, "groups", "wants.groups"),
        .network = switch (w.get("network") orelse .null) {
            .bool => |b| b,
            else => false,
        },
        .exec = stringsOf(arena, key, w, "exec", "wants.exec"),
    };
}

/// What the manifest declares under `wants.events`.
///
/// A name this build does not know is passed over with a warning rather
/// than voiding the list, for the same reason a malformed `wants` reads as
/// asking for nothing: the direction that cannot hand somebody events they
/// never asked for. A manifest written against a later build therefore
/// keeps whichever of its subscriptions this build can honour, and is told
/// about the rest.
fn eventsOf(arena: Allocator, key: []const u8, w: std.json.ObjectMap) []const Event {
    const names = stringsOf(arena, key, w, "events", "wants.events");

    var out: std.ArrayListUnmanaged(Event) = .empty;
    for (names) |name| {
        const e = Event.parse(name) orelse {
            log.warn(
                "plugin {s}: wants.events names {s}, which this build never sends, " ++
                    "so nothing is subscribed for it",
                .{ key, name },
            );
            continue;
        };

        // Named twice is asked for once. Nothing downstream would break on
        // a duplicate -- `subscribes` stops at the first match -- but the
        // list is read back out to the user and to `plugin_list`, and a
        // listing that says `chat, chat` reads as a bug in the host.
        if (contains2(out.items, e)) continue;

        out.append(arena, e) catch {
            log.warn(
                "plugin {s}: ran out of memory reading wants.events, so only the " ++
                    "first {d} are subscribed",
                .{ key, out.items.len },
            );
            break;
        };
    }
    return out.items;
}

fn contains2(haystack: []const Event, needle: Event) bool {
    for (haystack) |h| if (h == needle) return true;
    return false;
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
///
/// **Read from two places, written to one.** A plugin a release ships may
/// carry a `settings.json` inside its own directory, and that file is
/// consulted only when the user has no file of their own; see `readFirst`
/// for why the fallback is chosen by which files exist rather than by
/// merging their contents. Nothing ever writes the shipped copy -- `write`
/// knows one path, the user's.
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
        return readMaybe(arena, io, path) orelse .{};
    }

    /// Read the first of `paths` that has a file, nearest first.
    ///
    /// The user's own file is expected first and whatever a release ships
    /// with the plugin after it, so a plugin can arrive with sensible
    /// defaults without those defaults ever getting a vote once somebody has
    /// written the file that is theirs.
    ///
    /// **A file that is there wins even when it says the plugin is off.**
    /// That is the whole reason this is a search over files rather than a
    /// merge of two `Settings`: a `Settings` cannot tell "switched off" from
    /// "never configured" -- both are `enabled = false` -- so folding the two
    /// values together would let an upgrade switch a plugin back on for
    /// somebody who had deliberately switched it off. Only the file's
    /// existence carries that difference, and it is only readable here.
    ///
    /// A file that is there but will not parse also wins, for the same
    /// reason and in the same direction: it reads as "not configured", which
    /// reads as off. Falling through to a shipped default because the user's
    /// file has a typo in it is the one outcome that turns something on
    /// behind their back.
    pub fn readFirst(
        arena: Allocator,
        io: std.Io,
        paths: []const []const u8,
    ) Settings {
        for (paths) |path| {
            if (readMaybe(arena, io, path)) |settings| return settings;
        }
        return .{};
    }

    /// The read behind `read` and `readFirst`, which says whether there was
    /// a file at all: `null` means nothing could be read from `path`, and
    /// everything else -- including a file that will not parse -- is a
    /// settings value.
    fn readMaybe(
        arena: Allocator,
        io: std.Io,
        path: []const u8,
    ) ?Settings {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            arena,
            .limited(256 * 1024),
        ) catch return null;

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
            // The parameters here are references far more often than they
            // are secrets, but not always -- a hand-written file may hold a
            // literal, and this rewrites such a file. So the narrow
            // permissions are not incidental strictness; they are the whole
            // reason this does not just call `createFile` and write.
            //
            // POSIX says that in the one word it has for it. Windows has no
            // mode, so `restrict` below says the same thing in the words it
            // does have -- a DACL naming this user and nobody else. Either
            // way it is applied to an **empty** file, before a byte of the
            // rendered settings exists on disk, so there is no moment at
            // which a literal sits in a file the machine's other accounts
            // can open.
            var f = try std.Io.Dir.cwd().createFile(io, tmp, switch (builtin.os.tag) {
                .windows => .{},
                else => .{ .permissions = .fromMode(0o600) },
            });
            defer f.close(io);
            restrict(alloc, tmp);
            try f.writeStreamingAll(io, bytes);
        }

        const cwd = std.Io.Dir.cwd();
        try cwd.rename(tmp, cwd, path, io);
    }

    /// Cut a just-created file down to this user alone, where the platform
    /// needs telling separately from `createFile`.
    ///
    /// A no-op everywhere but Windows, which has no mode to pass: the
    /// equivalent is a DACL, and the equivalent of `0o600` is a *protected*
    /// DACL -- `D:P` -- holding one allow-everything entry for the SID this
    /// process is running as. Protected is the load-bearing half: without
    /// it the entries the parent directory hands down are kept, and the
    /// point of the exercise was to stop inheriting them.
    ///
    /// **A failure here is logged, not fatal.** Refusing to write the file
    /// would leave a user unable to configure a plugin at all on whatever
    /// unusual machine tripped it, which is a worse trade than a file whose
    /// only protection is the one the profile directory already gives it.
    /// But it is said out loud, at `warn`, naming the file: the thing this
    /// comment is really guarding against is the protection disappearing
    /// with nothing anywhere to show that it did.
    fn restrict(alloc: Allocator, path: []const u8) void {
        if (comptime builtin.os.tag != .windows) return;

        const w = internal_os.windows;
        const advapi32 = w.exp.advapi32;

        // The error is carried out of the block rather than asked for
        // after it, and that is not a style choice: `break` evaluates its
        // operand *before* the scope unwinds, while `GetLastError` reads a
        // per-thread slot that the `defer`s below -- `CloseHandle`,
        // `LocalFree` -- overwrite on their way out. Asking afterwards
        // reports whichever cleanup call ran last, very often `0`, which
        // reads as "nothing went wrong" in the one message whose entire
        // job is to say what did. A plausible wrong answer is worse than
        // no answer.
        const err: w.Win32Error = failed: {
            var token: w.HANDLE = undefined;
            if (advapi32.OpenProcessToken(
                w.exp.kernel32.GetCurrentProcess(),
                w.TOKEN_QUERY,
                &token,
            ) == w.FALSE) break :failed w.GetLastError();
            defer _ = w.exp.kernel32.CloseHandle(token);

            // `TOKEN_USER` is a header; the SID it points at lives past the
            // end of it in the same buffer. A SID is at most 68 bytes, so
            // one buffer with room to spare is simpler than the two-call
            // sizing dance and cannot come up short.
            var buf: [256]u8 align(@alignOf(w.TOKEN_USER)) = undefined;
            var len: w.DWORD = 0;
            if (advapi32.GetTokenInformation(
                token,
                .User,
                &buf,
                buf.len,
                &len,
            ) == w.FALSE) break :failed w.GetLastError();
            const user: *const w.TOKEN_USER = @ptrCast(&buf);

            var sid_str: w.LPWSTR = undefined;
            if (advapi32.ConvertSidToStringSidW(
                user.User.Sid,
                &sid_str,
            ) == w.FALSE) break :failed w.GetLastError();
            defer _ = w.exp.kernel32.LocalFree(sid_str);

            // Built as SDDL rather than by hand: an ACL assembled out of
            // `InitializeAcl`/`AddAccessAllowedAce` is a dozen more calls
            // and a dozen more ways to get a byte count wrong, for a string
            // the system parses the same either way.
            const sid_len = std.mem.len(sid_str);
            const sddl = std.fmt.allocPrintSentinel(
                alloc,
                "D:P(A;;FA;;;{f})",
                .{std.unicode.fmtUtf16Le(sid_str[0..sid_len])},
                0,
            ) catch break :failed w.GetLastError();
            defer alloc.free(sddl);

            const sddl_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, sddl) catch break :failed w.GetLastError();
            defer alloc.free(sddl_w);

            var sd: w.PSECURITY_DESCRIPTOR = undefined;
            if (advapi32.ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl_w,
                w.SDDL_REVISION_1,
                &sd,
                null,
            ) == w.FALSE) break :failed w.GetLastError();
            defer _ = w.exp.kernel32.LocalFree(sd);

            // By path rather than on the open handle: `SetSecurityInfo`
            // wants `WRITE_DAC` on the handle, and the handle `createFile`
            // gave us was not asked for with it. `SetFileSecurityW` opens
            // the file itself, with the access it needs.
            const path_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, path) catch break :failed w.GetLastError();
            defer alloc.free(path_w);

            if (advapi32.SetFileSecurityW(
                path_w,
                w.DACL_SECURITY_INFORMATION | w.PROTECTED_DACL_SECURITY_INFORMATION,
                sd,
            ) == w.FALSE) break :failed w.GetLastError();

            return;
        };

        log.warn(
            "could not restrict {s} to this user (err={}); it keeps whatever " ++
                "permissions its directory hands down, so treat any literal " ++
                "secret in it as readable by this machine's other accounts",
            .{ path, err },
        );
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

/// Whether `key` is a name and nothing more; see `isPlainName`.
///
/// Exposed because the resident host writes the key into a log line and a
/// hello line, and because the tool surface checks a key before it goes
/// looking for a directory.
pub fn plainName(key: []const u8) bool {
    return isPlainName(key);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
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
        \\{"key":"feishu","name":"飞书","exec":"send.sh","timeout_ms":5000}
    );
    f.close(io);

    const m = try load(alloc, io, dir);
    try testing.expectEqualStrings("feishu", m.key);
    try testing.expectEqualStrings("飞书", m.name);
    try testing.expectEqual(@as(u64, 5000), m.timeout_ms);

    // Absolute, so running it never depends on where Polter happens to be.
    const want = try std.fmt.allocPrint(alloc, "{s}/send.sh", .{dir});
    try testing.expectEqualStrings(want, m.exec);
}

test "an event this build never sends is passed over, not fatal" {
    // A manifest written against a later build should keep whichever of its
    // subscriptions this build can honour. Refusing to load the whole plugin
    // because one name is from the future would be worse, and the direction
    // is the safe one: it is fed less than it asked for, never more.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"future","exec":"x","wants":{"events":["chat","weather"]}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expectEqual(@as(usize, 1), m.wants.events.len);
    try testing.expect(m.wants.subscribes(.chat));
}

test "a manifest that still carries a kind loads, and kind decides nothing" {
    // The whole point of taking `Kind` out: a plugin is what it subscribes
    // to. A manifest left over from the three-kind world is not refused --
    // it is simply one that subscribes to nothing and is therefore not run.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"old","exec":"x"}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expect(m.wants.empty());
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

/// Lay out the two places one plugin's settings are looked for: the user's
/// `<root>/webhook.json` first and the `<root>/webhook/settings.json` a
/// release ships second.
///
/// A `null` writes no file there at all, which is the distinction every one
/// of these tests turns on -- an absent file and a file saying `enabled:
/// false` are the same `Settings` value and must not behave the same way.
fn twoLayers(
    arena: Allocator,
    io: std.Io,
    user: ?[]const u8,
    shipped: ?[]const u8,
) !struct { root: []const u8, paths: []const []const u8 } {
    var raw: [6]u8 = undefined;
    io.random(&raw);

    const root = try std.fmt.allocPrint(arena, "/tmp/polter-two-{x}", .{&raw});
    const ship_dir = try std.fmt.allocPrint(arena, "{s}/webhook", .{root});
    try std.Io.Dir.cwd().createDirPath(io, ship_dir);

    const paths = try arena.alloc([]const u8, 2);
    paths[0] = try std.fmt.allocPrint(arena, "{s}/webhook.json", .{root});
    paths[1] = try std.fmt.allocPrint(arena, "{s}/settings.json", .{ship_dir});

    if (user) |bytes| try putFile(io, paths[0], bytes);
    if (shipped) |bytes| try putFile(io, paths[1], bytes);

    return .{ .root = root, .paths = paths };
}

fn putFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

test "a plugin a release ships may bring its own settings" {
    // Nothing in the config directory, so the copy installed beside the
    // plugin is what there is. Without this a shipped plugin is off and
    // unconfigured until somebody writes a file by hand.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const laid = try twoLayers(alloc, io, null,
        \\{"enabled":true,"params":{"url":"https://example.com/shipped"}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, laid.root) catch {};

    const settings = Settings.readFirst(alloc, io, laid.paths);
    try testing.expect(settings.enabled);
    try testing.expectEqualStrings(
        "https://example.com/shipped",
        valueOf(settings, "url").?,
    );
}

test "switching a shipped plugin off survives the release that ships it on" {
    // The one this whole lookup exists to get right. The user's file says
    // off; the copy beside the plugin says on. Reading these as two
    // `Settings` and preferring the enabled one -- or merging them -- would
    // switch the plugin back on at every upgrade for exactly the person who
    // took the trouble to switch it off.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const laid = try twoLayers(alloc, io,
        \\{"enabled":false,"params":{}}
    ,
        \\{"enabled":true,"params":{"url":"https://example.com/shipped"}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, laid.root) catch {};

    const settings = Settings.readFirst(alloc, io, laid.paths);
    try testing.expect(!settings.enabled);

    // And the shipped parameters do not leak through either: the file that
    // wins is the whole answer, not a base to fill gaps from.
    try testing.expectEqual(@as(usize, 0), settings.params.len);
}

test "the user's parameters are not topped up from the shipped ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const laid = try twoLayers(alloc, io,
        \\{"enabled":true,"params":{"url":"https://example.com/mine"}}
    ,
        \\{"enabled":true,"params":{"url":"https://example.com/shipped","token":"t"}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, laid.root) catch {};

    const settings = Settings.readFirst(alloc, io, laid.paths);
    try testing.expect(settings.enabled);
    try testing.expectEqual(@as(usize, 1), settings.params.len);
    try testing.expectEqualStrings(
        "https://example.com/mine",
        valueOf(settings, "url").?,
    );
}

test "a settings file that will not parse still keeps the shipped one out" {
    // A typo in the user's file reads as "not configured", which reads as
    // off. Falling through to the shipped default here is the one outcome
    // that starts sending things on somebody's behalf because of a syntax
    // error.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const laid = try twoLayers(alloc, io, "{not json",
        \\{"enabled":true,"params":{"url":"https://example.com/shipped"}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, laid.root) catch {};

    const settings = Settings.readFirst(alloc, io, laid.paths);
    try testing.expect(!settings.enabled);
    try testing.expectEqual(@as(usize, 0), settings.params.len);
}

test "no settings anywhere is still not enabled" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const laid = try twoLayers(alloc, io, null, null);
    defer std.Io.Dir.cwd().deleteTree(io, laid.root) catch {};

    const settings = Settings.readFirst(alloc, io, laid.paths);
    try testing.expect(!settings.enabled);
    try testing.expectEqual(@as(usize, 0), settings.params.len);

    // An empty search path is a caller with nowhere to look, not a crash.
    try testing.expect(!Settings.readFirst(alloc, io, &.{}).enabled);
}

test "a manifest declares what it is by what it subscribes to" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"chat-archive","exec":"archive.sh","wants":{"events":["chat"]}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expect(m.wants.subscribes(.chat));
    try testing.expect(!m.wants.subscribes(.terminal_quiet));
    try testing.expect(!m.wants.empty());

    // Subscribed to chat and naming no groups: it will be fed nothing.
    try testing.expect(m.wants.groupless());
}

test "what a manifest wants is read back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"chat-archive","exec":"a.sh",
        \\ "wants":{"events":["chat"],"calls":["group_post"],
        \\          "groups":["build","ops"],"network":true,"exec":["psql"]}}
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

    try testing.expect(m.wants.subscribes(.chat));
    try testing.expect(m.wants.mayCall("group_post"));

    // Declared exactly, and nothing near it. A plugin that may post is not
    // thereby a plugin that may read.
    try testing.expect(!m.wants.mayCall("group_read"));
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
        \\{"key":"chat-archive","exec":"a.sh"}
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
        \\{"key":"chat-archive","exec":"a.sh","wants":{"events":["chat"],"groups":["*"]}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expect(m.wants.allows("build"));
    try testing.expect(m.wants.allows("anything at all"));
    try testing.expect(!m.wants.empty());
    try testing.expect(!m.wants.groupless());
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
        \\{"key":"chat-archive","exec":"a.sh","wants":7}
    );
    defer std.Io.Dir.cwd().deleteTree(io, not_object) catch {};

    const m = try load(alloc, io, not_object);
    try testing.expect(m.wants.empty());

    const bare_string = try manifestFor(alloc, io,
        \\{"key":"chat-archive","exec":"a.sh","wants":{"groups":"build"}}
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
        \\{"key":"chat-archive","exec":"a.sh","wants":{"groups":["build"]}}
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
        \\{"key":"chat-archive","exec":"a.sh",
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
        \\{"key":"chat-archive","exec":"a.sh",
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
            \\{"key":"many","exec":"a.sh",
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
            "{{\"key\":\"{s}\",\"exec\":\"a.sh\"}}",
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
            "{{\"key\":\"{s}\",\"exec\":\"a.sh\"}}",
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
        \\{"key":"webhook","exec":"send.sh",
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
            \\{"key":"webhook","exec":"send.sh"}
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
            \\{"key":"webhook","exec":"send.sh","params":"oops"}
        );
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

        const m = try load(alloc, io, dir);
        try testing.expectEqualStrings("webhook", m.key);
        try testing.expectEqual(@as(usize, 0), m.params.len);
    }

    {
        const dir = try manifestFor(alloc, io,
            \\{"key":"webhook","exec":"send.sh",
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
