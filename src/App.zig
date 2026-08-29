//! App is the primary GUI application for ghostty. This builds the window,
//! sets up the renderer, etc. The primary run loop is started by calling
//! the "run" function.
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const apprt = @import("apprt.zig");
const Surface = @import("Surface.zig");
const input = @import("input.zig");
const configpkg = @import("config.zig");
const Config = configpkg.Config;
const BlockingQueue = @import("datastruct/main.zig").BlockingQueue;
const renderer = @import("renderer.zig");
const font = @import("font/main.zig");
const build_config = @import("build_config.zig");
const global = @import("global.zig");

const log = std.log.scoped(.app);

const poltergeistpkg = @import("poltergeist/main.zig");

/// Least time between telling one terminal it has messages. Agents talking
/// to each other can produce a burst; being told once about all of it is
/// what a person would want too.
const chat_notice_gap_ms = 30 * std.time.ms_per_s;
const terminal = @import("terminal/main.zig");
const internal_os = @import("os/main.zig");

const SurfaceList = std.ArrayListUnmanaged(*apprt.Surface);

/// General purpose allocator
alloc: Allocator,

/// The list of surfaces that are currently active.
surfaces: SurfaceList,

/// Who is supervising whom. Lives on the app because supervision spans
/// surfaces; a surface only ever reports into it.
poltergeist: poltergeistpkg.Bus,

/// What the terminals have said to each other. Separate from the bus
/// because talking is not steering, and mixing them would blur that.
chat: poltergeistpkg.Chat,

/// When it is acceptable to disturb the user. Null means any hour.
///
/// Only scheduling questions respect it; an authorisation prompt goes out
/// whatever the hour, because holding one back protects nobody's sleep --
/// it just leaves a terminal stopped until morning.
poltergeist_notify_window: ?poltergeistpkg.notify.Window = null,

/// The whole configuration, rendered the way `+show-config` renders it, so
/// that an agent can be told what it is working under.
///
/// A snapshot rather than a pointer to the live config. The apprt owns that
/// config and replaces it on reload; holding the pointer across one would be
/// a dangling read at the worst moment, and copying the struct means owning
/// every string inside it. Text costs a few tens of kilobytes once per
/// reload and cannot dangle.
poltergeist_config_text: []const u8 = "",

/// When the last plugin test went out, on `poltergeistNow`'s clock.
///
/// Optional rather than a zero sentinel: that clock starts at zero, so a
/// test in the app's first millisecond would stamp a 0 that reads back as
/// "never tested", and the limit would not apply to the very first call.
poltergeist_plugin_tested_ms: ?u64 = null,

/// The notification plugins the config asked for, loaded once at startup.
///
/// Everything they own lives in `plugin_arena`, which is why they are a
/// pair: manifests are strings all the way down and are read once.
poltergeist_plugins: []const poltergeistpkg.Plugin.Manifest = &.{},
poltergeist_plugin_arena: ?std.heap.ArenaAllocator = null,

/// Where last night's arrangement is written down. Null until the state
/// directory is known. Owned.
poltergeist_session_path: ?[]const u8 = null,

/// Whether the MCP registration has been checked this run. Once is enough:
/// it cannot go stale while we are the thing it points at.
poltergeist_registered: bool = false,

/// What the previous run left behind. See `Session.Recall`, which reads
/// the file as it is constructed so that this run cannot overwrite the
/// material before anybody asks for it.
poltergeist_recall: poltergeistpkg.Session.Recall = .{},

/// The same conversation, written down. Null when logging is off.
///
/// The chat in memory is a working set: it trims as it grows and the
/// supervisor compacts it on purpose. This is the record, and nothing
/// removes anything from it -- otherwise the morning after an unattended
/// night has nothing to read, which is the case the whole feature is for.
chat_log: ?poltergeistpkg.ChatLog = null,

/// What happened, handed to plugins as it happens.
///
/// Deliberately not the chat log. The log is a core feature -- it is
/// complete on its own and nothing about it changes because a plugin
/// exists or does not -- and it is never a plugin's data source. A plugin
/// subscribes here and keeps an extra copy of what it is handed. See
/// `poltergeist/Feed.zig`.
poltergeist_feed: poltergeistpkg.Feed,

/// The resident archive plugins, one thread each. Empty unless one is
/// installed and switched on, which is the ordinary case.
poltergeist_archives: std.ArrayListUnmanaged(*poltergeistpkg.Archive) = .empty,

/// Whether the archives have been looked for. Testing the list instead
/// would not do: with no archive plugin installed it stays empty for ever,
/// and every config reload would re-read every plugin's settings file to
/// find that out again.
poltergeist_archives_started: bool = false,

/// Baseline for the monotonic clock the bus is given. Taken on the first
/// report rather than at startup so it costs nothing when unused.
poltergeist_epoch: ?std.Io.Timestamp = null,

/// What the wall clock read at that same instant, in Unix milliseconds.
///
/// The bus and the chat log run on a monotonic clock, which is the right
/// choice for measuring how long something has been still: it does not
/// jump when the system clock is corrected. But somebody reading the chat
/// wants to know what time a thing was said, and an offset from an
/// arbitrary baseline cannot answer that. Pairing the two clocks once, at
/// the single instant both were read, lets either be recovered from the
/// other.
poltergeist_epoch_wall_ms: i64 = 0,

/// The socket agents reach Poltergeist through. Null unless
/// `poltergeist-mcp` is on, so the default build opens nothing.
poltergeist_server: ?poltergeistpkg.Server = null,

/// Surfaces this app opened to run the chat interface.
///
/// A request arriving from one of these counts as coming from the person
/// at the keyboard (`Chat.user_id`) rather than from the terminal it
/// happens to be running in. That terminal is usually in no group at all,
/// and the user is a member of every one.
///
/// Kept as a list of ids the host itself put there, so identity still
/// comes from the host rather than from anything a client says about
/// itself. A watched agent's surface is not on it, so an agent cannot
/// reach user identity by any route.
chat_surfaces: std.ArrayListUnmanaged(poltergeistpkg.Bus.Id) = .empty,

/// The apprt, kept so that a connection thread can wake the app loop after
/// putting a request in the mailbox.
///
/// Set before the socket is opened and never changed after, so the
/// connection threads that read it cannot race the write: they do not exist
/// until `start` has been called, which happens later in the same function.
poltergeist_rt_app: ?*apprt.App = null,

/// This is true if the app that Ghostty is in is focused. This may
/// mean that no surfaces (terminals) are focused but the app is still
/// focused, i.e. may an about window. On macOS, this concept is known
/// as the "active" app while focused windows are known as the
/// "main" window.
///
/// This is used to determine if keyboard shortcuts that are non-global
/// should be processed. If the app is not focused, then we don't want
/// to process keyboard shortcuts that are not global.
///
/// This defaults to true since we assume that the app is focused when
/// Ghostty is initialized but a well behaved apprt should call
/// focusEvent to set this to the correct value right away.
focused: bool = true,

/// The last focused surface. This surface may not be valid;
/// you must always call hasSurface to validate it.
focused_surface: ?*Surface = null,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: Mailbox.Queue,

/// The set of font GroupCache instances shared by surfaces with the
/// same font configuration.
font_grid_set: font.SharedGridSet,

// Used to rate limit desktop notifications. Some platforms (notably macOS) will
// run out of resources if desktop notifications are sent too fast and the OS
// will kill Ghostty.
last_notification_time: ?std.Io.Timestamp = null,
last_notification_digest: u64 = 0,

/// The conditional state of the configuration. See the equivalent field
/// in the Surface struct for more information. In this case, this applies
/// to the app-level config and as a default for new surfaces.
config_conditional_state: configpkg.ConditionalState,

/// Set to false once we've created at least one surface. This
/// never goes true again. This can be used by surfaces to determine
/// if they are the first surface.
first: bool = true,

pub const CreateError = Allocator.Error || font.SharedGridSet.InitError;

/// Create a new app instance. This returns a stable pointer to the app
/// instance which is required for callbacks.
pub fn create(alloc: Allocator) CreateError!*App {
    var app = try alloc.create(App);
    errdefer alloc.destroy(app);
    try app.init(alloc);

    // If font discovery supports warmup, then we call it. Some font
    // mechanisms (e.g. CoreText) have a multi-millisecond one-time cost
    // on startup.
    if (comptime @hasDecl(font.Discover, "warmup")) {
        if (std.Thread.spawn(
            .{},
            font.Discover.warmup,
            .{},
        )) |thr| thr.detach() else |err| {
            log.warn("font warmup thread spawn failed err={}", .{err});
        }
    }

    // Same for the renderer's graphics API (e.g. Metal), which pays
    // one-time framework initialization costs on first use.
    if (comptime @hasDecl(renderer.Renderer.API, "warmup")) {
        if (std.Thread.spawn(
            .{},
            renderer.Renderer.API.warmup,
            .{},
        )) |thr| thr.detach() else |err| {
            log.warn("renderer warmup thread spawn failed err={}", .{err});
        }
    }

    return app;
}

/// Initialize the main app instance. This creates the main window, sets
/// up the renderer state, compiles the shaders, etc. This is the primary
/// "startup" logic.
///
/// After calling this function, well behaved apprts should then call
/// `focusEvent` to set the initial focus state of the app.
pub fn init(
    self: *App,
    alloc: Allocator,
) CreateError!void {
    var font_grid_set = try font.SharedGridSet.init(alloc);
    errdefer font_grid_set.deinit();

    self.* = .{
        .alloc = alloc,
        .surfaces = .empty,
        .mailbox = .{},
        .font_grid_set = font_grid_set,
        .config_conditional_state = .{},
        .poltergeist = .init(alloc, .{}),
        .poltergeist_feed = .init(alloc, global.io()),
        .chat = .init(alloc, .{}),
    };
}

pub fn deinit(self: *App) void {
    // Clean up all our surfaces
    for (self.surfaces.items) |surface| surface.deinit();
    self.surfaces.deinit(self.alloc);

    if (self.poltergeist_server) |*srv| srv.deinit();

    // First, and joined before anything else is freed. Strictly each of
    // these borrows nothing from the app -- it copied what it needed and
    // opened its own handle on the log -- but the order says plainly who
    // has to have stopped before the rest of this runs.
    for (self.poltergeist_archives.items) |archive| archive.destroy();
    self.poltergeist_archives.deinit(self.alloc);

    // After them, and that order is the whole of it: each archive gives
    // its subscription back as it is destroyed.
    self.poltergeist_feed.deinit();

    if (self.poltergeist_config_text.len > 0) self.alloc.free(self.poltergeist_config_text);
    if (self.chat_log) |*l| l.deinit();
    if (self.poltergeist_session_path) |p| self.alloc.free(p);
    self.poltergeist_recall.deinit(self.alloc);
    if (self.poltergeist_plugin_arena) |*a| a.deinit();
    self.chat_surfaces.deinit(self.alloc);
    self.chat.deinit();
    self.poltergeist.deinit();

    // Clean up our font group cache
    // We should have zero items in the grid set at this point because
    // destroy only gets called when the app is shutting down and this
    // should gracefully close all surfaces.
    assert(self.font_grid_set.count() == 0);
    self.font_grid_set.deinit();
}

pub fn destroy(self: *App) void {
    // Deinitialize the app
    self.deinit();

    // Free the app memory
    self.alloc.destroy(self);
}

/// Tick ticks the app loop. This will drain our mailbox and process those
/// events. This should be called by the application runtime on every loop
/// tick.
pub fn tick(self: *App, rt_app: *apprt.App) !void {
    // Drain our mailbox
    try self.drainMailbox(rt_app);
}

/// Update the configuration associated with the app. This can only be
/// called from the main thread. The caller owns the config memory. The
/// memory can be freed immediately when this returns.
pub fn updateConfig(self: *App, rt_app: *apprt.App, config: *const Config) !void {
    // Bring the agent socket in line with the config. Failing to open it
    // must never take the app down with it: the terminal has to keep
    // working whether or not agents can reach it.
    self.poltergeist_rt_app = rt_app;
    self.syncPoltergeistServer(config.@"poltergeist-mcp") catch |err| {
        log.warn("poltergeist: could not open the agent socket err={}", .{err});
    };

    self.poltergeist.config.notice_interval_ms =
        config.@"poltergeist-notice-interval".duration / std.time.ns_per_ms;
    self.poltergeist.config.stand_down_allowed =
        config.@"poltergeist-supervisor-stand-down";

    self.poltergeist_notify_window =
        poltergeistpkg.notify.Window.parse(config.@"poltergeist-notify-window");
    self.refreshPoltergeistConfigText(config);
    self.ensurePlugins();

    // Here for the ordering, not for the reload. The archives are looked
    // for exactly once, and the two things that have to have happened
    // first -- the log opening and the plugin list being read -- arrive in
    // whichever order the apprt happens to produce; this is the second of
    // the two places that notices they both have. Once they have been
    // looked for it does nothing, so a plugin installed while Polter is
    // running still waits for a restart, the same as a notification one.
    self.ensureArchive();

    // Moved into each plugin's own file, so that one plugin's state lives in
    // one place and a settings UI can own it. Said plainly rather than
    // ignored in silence: somebody who set this expects it to do something.
    if (config.@"poltergeist-notify".list.items.len > 0) {
        log.warn(
            "poltergeist-notify no longer does anything; a plugin is switched " ++
                "on by \"enabled\" in $XDG_CONFIG_HOME/polter/plugins/<name>.json",
            .{},
        );
    }

    // Go through and update all of the surface configurations.
    for (self.surfaces.items) |surface| {
        try surface.core().handleMessage(.{ .change_config = config });
    }

    // Apply our conditional state. If we fail to apply the conditional state
    // then we log and attempt to move forward with the old config.
    // We only apply this to the app-level config because the surface
    // config applies its own conditional state.
    var applied_: ?configpkg.Config = config.changeConditionalState(
        self.config_conditional_state,
    ) catch |err| err: {
        log.warn("failed to apply conditional state to config err={}", .{err});
        break :err null;
    };
    defer if (applied_) |*c| c.deinit();
    const applied: *const configpkg.Config = if (applied_) |*c| c else config;

    // Notify the apprt that the app has changed configuration.
    _ = try rt_app.performAction(
        .app,
        .config_change,
        .{ .config = applied },
    );
}

/// Add an initialized surface. This is really only for the runtime
/// implementations to call and should NOT be called by general app users.
/// The surface must be from the pool.
/// Handle a quiescence report from one surface.
///
/// The bus decides whether this is worth saying at all -- it knows who is
/// supervising, who has clocked off, and how recently this terminal last
/// spoke. If it is, the notice is typed into the supervisor's terminal as
/// if the user had typed it.
///
/// The notice carries an id and two durations, never screen contents. The
/// supervisor reads the other terminal itself if it wants to know what is
/// on it, which keeps the judgement on the AI's side and keeps a whole
/// screen out of its context.
fn poltergeistReport(
    self: *App,
    from: poltergeistpkg.Bus.Id,
    event: poltergeistpkg.Sampler.Event,
) void {
    // Whatever comes of the report, the tabs should say what is true now.
    defer self.refreshPoltergeistTabs();

    const now_ms = self.poltergeistNow();

    // Into the box. Nothing goes to the supervisor at this instant: a
    // report is a change of state, not an errand, and interrupting somebody
    // once per event per terminal is how a helpful signal turns into noise
    // that gets ignored or switched off.
    _ = self.poltergeist.report(from, event, now_ms);

    self.deliverPoltergeistNotices(now_ms);
}

/// Hand the box to the supervisor, if it is time and there is anything in
/// it.
///
/// Driven by reports arriving rather than by a timer of its own. A terminal
/// that is still quiet keeps reporting on the sampler's repeat interval, so
/// there is always something to drive the next hand-over while anything is
/// waiting; and when every terminal is busy there is nothing to hand over.
/// The supervisor can also read the box itself at any time, which is what
/// covers the gap after the last report of all.
fn deliverPoltergeistNotices(self: *App, now_ms: u64) void {
    // Each supervisor gets its own box, on its own clock. A shared one
    // would hand each of them the other's reports: twice the interruption,
    // and half of it about terminals they cannot read anyway.
    var supervisors: std.ArrayListUnmanaged(poltergeistpkg.Bus.Id) = .empty;
    defer supervisors.deinit(self.alloc);

    var it = self.poltergeist.entries.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.role != .supervisor) continue;
        supervisors.append(self.alloc, kv.key_ptr.*) catch return;
    }

    for (supervisors.items) |to| {
        const surface = self.findSurfaceByID(to) orelse {
            // That supervisor's terminal went away. Releasing it here also
            // releases the terminals it was minding, which then belong to
            // nobody until somebody claims them -- better than reporting
            // into a terminal that is gone.
            self.poltergeist.unregister(to);
            continue;
        };

        var msg: apprt.surface.Message = .{ .poltergeist_notice = undefined };
        const line = self.poltergeist.drainIfDue(
            to,
            now_ms,
            &msg.poltergeist_notice,
        ) orelse continue;
        msg.poltergeist_notice[line.len] = 0;

        self.surfaceMessage(surface, msg) catch |err| {
            log.warn("poltergeist: could not deliver notices err={}", .{err});
        };
    }
}

/// Find every plugin that is installed and switched on.
///
/// Once, at startup, and again whenever `reloadPlugins` throws the arena
/// away. A plugin that will not load is skipped with a warning rather than
/// taken as fatal: the terminal has to work whether or not a notification
/// channel does.
///
/// Enumerated rather than named in the config: a plugin's own file says
/// whether it is on (`Plugin.Settings`), so there is nothing for the main
/// config to list, and a settings UI can switch one on without editing a
/// file the user hand-writes.
///
/// Both places are read, the user's first. A plugin shipped with Polter and
/// one written by hand are the same thing to everything downstream; only the
/// user's copy wins when the names collide, so a shipped plugin can be
/// replaced without touching the bundle.
pub fn ensurePlugins(self: *App) void {
    if (self.poltergeist_plugin_arena != null) return;

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    const alloc = arena.allocator();

    const io = global.io();

    var environ_map = global.environMap() catch {
        arena.deinit();
        return;
    };
    defer environ_map.deinit();

    const found = self.scanPlugins(alloc, io, &environ_map, false);

    // The manifests alone are kept. The settings are read again where they
    // are used -- `ensureArchive` at the moment it starts a child, the
    // notification path on every send -- because a parameter changed while
    // Polter runs must take effect without a restart.
    const manifests = alloc.alloc(poltergeistpkg.Plugin.Manifest, found.len) catch {
        arena.deinit();
        return;
    };
    for (found, 0..) |f, i| manifests[i] = f.manifest;

    self.poltergeist_plugins = manifests;
    self.poltergeist_plugin_arena = arena;

    log.info("poltergeist: {d} notification and {d} archive plugin(s) ready", .{
        poltergeistpkg.notify.count(manifests, .notify),
        poltergeistpkg.notify.count(manifests, .archive),
    });
}

/// One plugin as found on disk, together with what the user configured for
/// it.
///
/// Kept as one thing because everything that walks the plugin directories
/// wants both, and reading the settings a second time somewhere else is how
/// the two come to disagree about what is switched on.
const Installed = struct {
    manifest: poltergeistpkg.Plugin.Manifest,
    settings: poltergeistpkg.Plugin.Settings,
};

/// Every plugin in the search path, nearest first.
///
/// `keep_disabled` is the whole reason this is separate from
/// `ensurePlugins`: what *runs* is only the plugins that are switched on,
/// but the question `plugin_list` answers is "what is here and is it on",
/// and a plugin that is off is exactly what somebody is asking about.
///
/// Everything returned belongs to `arena`.
fn scanPlugins(
    self: *App,
    arena: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    keep_disabled: bool,
) []const Installed {
    var found: std.ArrayListUnmanaged(Installed) = .empty;

    // Two dedupes, and they are not the same one twice. `dirs` is what makes
    // a user's copy of a shipped plugin win: the search path is nearest
    // first, so the second directory of a name is the one to drop.
    var dirs: std.StringHashMapUnmanaged(void) = .empty;

    // `keys` is the one that matters. Everything downstream keys on
    // `manifest.key` and not on the directory: `pluginSettings` reads
    // `<key>.json` and `archiveFor` looks one up by key. Two directories
    // whose manifests claim one key would therefore share a settings file
    // and start two resident copies of one plugin, each subscribing and
    // each storing every message -- see `docs/poltergeist/storage.md`.
    var keys: std.StringHashMapUnmanaged([]const u8) = .empty;

    for (self.pluginSearchPath(arena, io, environ_map)) |base| {
        var dir = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (dirs.contains(entry.name)) continue;

            const name = arena.dupe(u8, entry.name) catch continue;
            dirs.put(arena, name, {}) catch {};

            const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ base, name }) catch continue;
            const manifest = poltergeistpkg.Plugin.load(arena, io, path) catch |err| {
                log.warn("poltergeist: plugin {s} would not load err={}", .{ name, err });
                continue;
            };

            if (keys.get(manifest.key)) |first| {
                log.warn(
                    "poltergeist: {s} and {s} both claim the key {s}; the second is " ++
                        "passed over, because two copies of one plugin would share " ++
                        "its settings and its cursor",
                    .{ first, path, manifest.key },
                );
                continue;
            }
            keys.put(arena, manifest.key, path) catch {};

            const settings = self.pluginSettings(arena, io, environ_map, manifest.key);
            if (!keep_disabled and !settings.enabled) {
                log.debug("poltergeist: plugin {s} is installed but off", .{manifest.key});
                continue;
            }

            found.append(arena, .{
                .manifest = manifest,
                .settings = settings,
            }) catch continue;
        }
    }

    return found.items;
}

/// Read the plugin directories again, because something about them changed.
///
/// Safe to do while archives are running, and that rests on two facts rather
/// than on hope: `Archive.Options` says every field is copied, so a resident
/// plugin borrows nothing from the arena being thrown away; and both readers
/// of `poltergeist_plugins` -- `notifyUser` and `ensureArchive` -- run on the
/// app thread, which is the thread this is called on.
pub fn reloadPlugins(self: *App) void {
    // Cleared before the arena goes, not after. `ensurePlugins` has early
    // returns -- no environment, no memory -- and none of them assigns a new
    // list; the other order would leave this slice pointing into freed
    // memory for whichever notification came next.
    self.poltergeist_plugins = &.{};
    if (self.poltergeist_plugin_arena) |*a| a.deinit();
    self.poltergeist_plugin_arena = null;

    self.ensurePlugins();
}

/// Where plugins live, nearest first.
fn pluginSearchPath(
    self: *App,
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) []const []const u8 {
    _ = self;

    var out: std.ArrayListUnmanaged([]const u8) = .empty;

    if (internal_os.xdg.config(
        io,
        alloc,
        environ_map,
        .{ .subdir = "polter/plugins" },
    )) |base| {
        out.append(alloc, base) catch {};
    } else |_| {}

    if (internal_os.resourcesDir(alloc)) |resources| {
        if (resources.app_path) |app_path| {
            if (std.fmt.allocPrint(
                alloc,
                "{s}/polter/plugins",
                .{app_path},
            )) |base| {
                out.append(alloc, base) catch {};
            } else |_| {}
        }
    } else |_| {}

    return out.items;
}

/// One plugin's own settings file, nearest first.
///
/// The user's `<config>/polter/plugins/<key>.json` is looked at first, and a
/// `settings.json` sitting inside the plugin's own directory after it -- so a
/// plugin a release ships can arrive already configured, while anything the
/// user has said about it wins for good. Only the first file found is read;
/// `Plugin.Settings.readFirst` says why the two are not merged, and the short
/// version is that merging cannot tell "switched off" from "never
/// configured", which would let an upgrade switch a plugin back on.
///
/// The fallback walks the whole search path rather than the bundle alone,
/// because a plugin directory dropped into the config directory by hand is
/// installed the same way and may carry the same file.
///
/// Nothing here writes: the settings file `plugin_configure` writes is still
/// the one in the config directory and only that one.
fn pluginSettings(
    self: *App,
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    key: []const u8,
) poltergeistpkg.Plugin.Settings {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;

    if (internal_os.xdg.config(
        io,
        alloc,
        environ_map,
        .{ .subdir = "polter/plugins" },
    )) |base| {
        if (std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ base, key })) |path| {
            paths.append(alloc, path) catch {};
        } else |_| {}
    } else |_| {}

    for (self.pluginSearchPath(alloc, io, environ_map)) |base| {
        if (std.fmt.allocPrint(
            alloc,
            "{s}/{s}/settings.json",
            .{ base, key },
        )) |path| {
            paths.append(alloc, path) catch {};
        } else |_| {}
    }

    return poltergeistpkg.Plugin.Settings.readFirst(alloc, io, paths.items);
}

fn findPluginDir(
    self: *App,
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    key: []const u8,
) ?[]const u8 {
    _ = self;

    if (internal_os.xdg.config(
        io,
        alloc,
        environ_map,
        .{ .subdir = "polter/plugins" },
    )) |base| {
        const dir = std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, key }) catch return null;
        if (std.Io.Dir.cwd().openDir(io, dir, .{})) |*d| {
            var handle = d.*;
            handle.close(io);
            return dir;
        } else |_| {}
    } else |_| {}

    const resources = internal_os.resourcesDir(alloc) catch return null;
    const app_path = resources.app_path orelse return null;

    const dir = std.fmt.allocPrint(alloc, "{s}/polter/plugins/{s}", .{ app_path, key }) catch
        return null;
    if (std.Io.Dir.cwd().openDir(io, dir, .{})) |*d| {
        var handle = d.*;
        handle.close(io);
        return dir;
    } else |_| {}

    return null;
}

/// Write down what tomorrow needs, now.
///
/// Called after anything that changes the arrangement -- a group made, a
/// member added or removed, a brief written, a role changed, a terminal
/// held to its work or let go.
/// Not at exit: the cases this exists for are the machine shutting down
/// and Polter being killed, and neither of those runs an exit path.
///
/// Cheap enough to do eagerly: a few hundred bytes, and these events are
/// rare. Skipped entirely when there is nowhere to write.
pub fn saveSession(self: *App) void {
    const path = self.poltergeist_session_path orelse return;

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const snapshot = self.sessionSnapshot(alloc) catch |err| {
        log.warn("poltergeist: could not gather the session err={}", .{err});
        return;
    };

    poltergeistpkg.Session.write(alloc, global.io(), path, snapshot);
}

/// Everything worth writing down, borrowed from `alloc`.
fn sessionSnapshot(
    self: *App,
    alloc: Allocator,
) Allocator.Error!poltergeistpkg.Session.Snapshot {
    const names = try self.chat.groupsFor(alloc, poltergeistpkg.Chat.user_id);

    var groups: std.ArrayListUnmanaged(poltergeistpkg.Session.Group) = .empty;
    for (names) |name| {
        const ids = self.chat.membersOf(alloc, name) catch continue;

        var members: std.ArrayListUnmanaged(poltergeistpkg.Session.Member) = .empty;
        for (ids) |id| {
            // The user is in every group and has no terminal of their own,
            // so there is nothing about them to write down.
            if (id == poltergeistpkg.Chat.user_id) continue;

            // Asked again here, not only when the member was added and
            // when it last spoke. A terminal added in the second before
            // its shell reported a working directory had nothing to
            // record, and a supervisor -- which mostly reads -- may never
            // post at all, so it would keep that blank for good. This is
            // the moment the record is being written down, which makes it
            // the moment to make it as true as we can.
            self.refreshFooting(name, id);

            const footing = self.chat.footingOf(name, id) orelse continue;
            const entry = self.poltergeist.get(id);

            try members.append(alloc, .{
                .cwd = footing.cwd,
                .title = footing.title,
                .role = if (entry) |e| e.role else .none,
                .held = if (entry) |e| e.held else false,
            });
        }

        try groups.append(alloc, .{
            .name = name,
            .brief = self.chat.briefOf(name) catch "",
            .members = members.items,
        });
    }

    // Every terminal on screen, not only the ones in a group. A terminal
    // nobody put under watch has no other record anywhere, so leaving it
    // out means it simply vanishes at the restart -- and it may be the
    // shell somebody had a build running in, which is worth as much to
    // them as any agent.
    var terminals: std.ArrayListUnmanaged(poltergeistpkg.Session.Terminal) = .empty;
    if (poltergeistOpenTerminals(self, alloc)) |places| {
        for (places) |place| {
            if (place.cwd.len == 0 and place.title.len == 0) continue;
            try terminals.append(alloc, .{
                .cwd = place.cwd,
                .title = place.title,
            });
        }
    } else |err| {
        log.warn("poltergeist: could not list terminals to save err={}", .{err});
    }

    return .{ .groups = groups.items, .terminals = terminals.items };
}

/// Open the chat log if the config wants it and it is not open yet.
///
/// Same reasoning as the socket: `updateConfig` runs only on a config
/// *reload*, which neither apprt does at launch, so waiting for it would
/// mean nothing was written down until somebody reloaded by hand.
pub fn ensureChatLog(self: *App, want: bool) void {
    if (!want or self.chat_log != null) return;

    const io = global.io();
    var environ_map = global.environMap() catch return;
    defer environ_map.deinit();

    const state_dir = internal_os.xdg.state(
        io,
        self.alloc,
        &environ_map,
        .{ .subdir = "polter" },
    ) catch |err| {
        log.warn("poltergeist: no state directory for the chat log err={}", .{err});
        return;
    };
    defer self.alloc.free(state_dir);

    self.chat_log = poltergeistpkg.ChatLog.open(self.alloc, io, state_dir) catch |err| {
        log.warn("poltergeist: could not open the chat log err={}", .{err});
        return;
    };

    // Same directory, and the log having opened means it exists.
    if (self.poltergeist_session_path == null) {
        self.poltergeist_session_path = poltergeistpkg.Session.defaultPath(
            self.alloc,
            state_dir,
        ) catch null;

        if (self.poltergeist_session_path) |p| {
            self.poltergeist_recall = .open(self.alloc, io, p);
        }
    }

    // The log has just opened, which is the earliest moment there is
    // anything for an archive plugin to follow.
    self.ensureArchive();
}

/// Start the resident archive plugins, if any are installed and switched on.
///
/// One thread and one child process each, for as long as the app is up.
/// They copy the chat log somewhere that outlives it; the log stays the
/// only source of truth and a plugin that dies loses nothing, because the
/// cursor it wrote down does not move. See `poltergeist/Archive.zig` and
/// `docs/poltergeist/storage.md`.
///
/// Nothing here fails quietly. A plugin that will not start, or that
/// declares no groups and so has nothing to be given, is named in a
/// warning -- an archive that silently does not run is the one failure the
/// whole feature is supposed to be proof against.
pub fn ensureArchive(self: *App) void {
    if (self.poltergeist_archives_started) return;

    // Nothing is being written down, so there is nothing to copy.
    if (self.chat_log == null) return;

    // Asked for rather than assumed, and this matters: on the first surface
    // `ensureChatLog` runs *before* `ensurePlugins`, so the plugin list
    // would still be empty here and every archive would silently never
    // start. Loading is guarded on its own arena and costs nothing the
    // second time, which is cheaper than depending on somebody else's call
    // order.
    self.ensurePlugins();
    if (self.poltergeist_plugin_arena == null) return;

    // Set before the loop, not after: a failure part way through must not
    // leave this to be tried again and start a second copy of everything
    // that did work.
    self.poltergeist_archives_started = true;

    const io = global.io();

    var environ_map = global.environMap() catch |err| {
        log.warn("poltergeist: no environment for the archive err={}", .{err});
        return;
    };
    defer environ_map.deinit();

    var scratch: std.heap.ArenaAllocator = .init(self.alloc);
    defer scratch.deinit();
    const alloc = scratch.allocator();

    for (self.poltergeist_plugins) |manifest| {
        // Read again rather than remembered: `ensurePlugins` looks only at
        // whether a plugin is switched on and throws its parameters away.
        // A resident plugin's database lives in those.
        const settings = self.pluginSettings(alloc, io, &environ_map, manifest.key);
        _ = self.startArchive(manifest, settings);
    }

    // Only when there is something to say, so the ordinary install -- which
    // has no archive plugin at all -- stays quiet.
    if (self.poltergeist_archives.items.len > 0) log.info(
        "poltergeist: {d} archive plugin(s) running",
        .{self.poltergeist_archives.items.len},
    );
}

/// Start one resident archive plugin, unless there is a reason not to.
///
/// Returns whether this call started one. Everything that says no says so in
/// the log first, except the two that are ordinary and quiet: a plugin that
/// is not an archive, and a copy that is already running.
///
/// The duplicate check is not tidiness. Two copies of one plugin confirm
/// into the same cursor file, and the cursor can then go backwards or skip
/// -- the one failure `docs/poltergeist/storage.md` spends a section ruling
/// out. This is the only path that starts one, so it is where the guarantee
/// belongs.
fn startArchive(
    self: *App,
    manifest: poltergeistpkg.Plugin.Manifest,
    settings: poltergeistpkg.Plugin.Settings,
) bool {
    if (manifest.kind != .archive) return false;

    if (manifest.wants.empty()) {
        log.warn(
            "poltergeist: plugin {s} declares no groups, so it is not " ++
                "started; add \"wants\": {{\"groups\": [\"*\"]}} to its plugin.json",
            .{manifest.key},
        );
        return false;
    }

    // Nothing is being written down, so there is nothing to follow. Not a
    // warning: this is the ordinary state before the first terminal exists.
    if (self.chat_log == null) return false;

    if (self.archiveFor(manifest.key) != null) return false;

    // A fresh map each, and deliberately no `defer`: `start` takes the
    // environment over the moment it is called, on its failure paths too.
    const env = global.environMap() catch return false;

    const archive = poltergeistpkg.Archive.start(self.alloc, global.io(), .{
        .key = manifest.key,
        .exec = manifest.exec,
        .timeout_ms = manifest.timeout_ms,
        .groups = manifest.wants.groups,
        .params = settings.params,
        .feed = &self.poltergeist_feed,
        .environ = env,
    }) catch |err| {
        log.warn(
            "poltergeist: plugin {s} would not start err={}",
            .{ manifest.key, err },
        );
        return false;
    };

    self.poltergeist_archives.append(self.alloc, archive) catch {
        // Never orphan a running thread over a failed append.
        archive.destroy();
        return false;
    };

    return true;
}

/// The running copy of one archive plugin, if there is one.
///
/// Walked rather than mapped: there are single digits of these, and
/// `Archive.key` is written once in `start` and never again, so reading it
/// from here needs no lock.
fn archiveFor(self: *App, key: []const u8) ?*poltergeistpkg.Archive {
    for (self.poltergeist_archives.items) |archive| {
        if (std.mem.eql(u8, archive.key, key)) return archive;
    }
    return null;
}

/// Open the agent socket if the config wants it and it is not open yet.
///
/// Called as a surface starts, because `updateConfig` runs only on a config
/// *reload* -- neither apprt calls it at launch. Without this a user who
/// set `poltergeist-mcp` in their config file would find no socket until
/// they reloaded by hand, which reads as the feature being broken.
pub fn ensurePoltergeistServer(self: *App, rt_app: *apprt.App, want: bool) void {
    if (!want or self.poltergeist_server != null) return;
    self.poltergeist_rt_app = rt_app;
    self.syncPoltergeistServer(true) catch |err| {
        log.warn("poltergeist: could not open the agent socket err={}", .{err});
    };
}

/// Make sure an agent's runtime knows these tools exist.
///
/// The socket and the token are in every terminal's environment already;
/// this is what makes the tools appear in a session at all. See
/// `poltergeist/register.zig` for why it goes through `claude mcp` rather
/// than editing the file.
pub fn ensureMcpRegistered(self: *App, want: bool) void {
    if (!want or self.poltergeist_registered) return;
    self.poltergeist_registered = true;

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const io = global.io();

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0 .. std.process.executablePath(io, &exe_buf) catch |err| {
        log.warn("poltergeist: could not find my own path err={}", .{err});
        return;
    }];

    const outcome = poltergeistpkg.register.ensure(
        alloc,
        io,
        exe,
        build_config.version_string,
    );

    log.info("poltergeist: mcp registration {t}", .{outcome});

    // The tools are only half of it. A skill the runtime has never heard
    // of is one it cannot match against what the user asked for, which is
    // how a supervisor ends up reaching for its own subagent tool instead.
    var environ_map = global.environMap() catch return;
    defer environ_map.deinit();

    const home = environ_map.get("HOME") orelse return;

    const config_dir = internal_os.xdg.config(io, alloc, &environ_map, .{}) catch null;
    const resources = internal_os.resourcesDir(alloc) catch null;

    poltergeistpkg.register.ensureSkills(
        alloc,
        io,
        &poltergeistpkg.skill.builtin_names,
        config_dir,
        if (resources) |r| r.app_path else null,
        home,
    );
}

/// Open or close the agent socket to match the config.
///
/// Turning it off tears the socket down rather than leaving it listening,
/// since the point of turning it off is that nothing should be able to
/// reach in any more.
fn syncPoltergeistServer(self: *App, want: bool) !void {
    if (!want) {
        if (self.poltergeist_server) |*srv| {
            srv.deinit();
            self.poltergeist_server = null;
            log.info("poltergeist: agent socket closed", .{});
        }
        return;
    }

    if (self.poltergeist_server != null) return;

    const io = global.io();
    var environ_map = try global.environMap();
    defer environ_map.deinit();

    const state_dir = try internal_os.xdg.state(
        io,
        self.alloc,
        &environ_map,
        .{ .subdir = "polter" },
    );
    defer self.alloc.free(state_dir);

    // Nothing else creates this on a fresh machine, and a missing
    // directory would make listen fail with a single warning that reads
    // like the feature is broken.
    std.Io.Dir.cwd().createDirPath(io, state_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // A socket file outlives the process that bound it, so a machine that has
    // run Polter a few dozen times has a few dozen of them. Sweeping before we
    // bind our own means we never probe ourselves, and only sockets nothing is
    // listening on are removed -- a live instance's is left alone.
    poltergeistpkg.Server.sweepStale(self.alloc, io, state_dir);

    const path = try poltergeistpkg.Server.defaultPath(self.alloc, io, state_dir);
    defer self.alloc.free(path);

    self.poltergeist_server = try .init(self.alloc, io, path, .{
        .ctx = self,
        .func = submitPoltergeistRequest,
    });
    errdefer {
        self.poltergeist_server.?.deinit();
        self.poltergeist_server = null;
    }

    try self.poltergeist_server.?.start();
    log.info("poltergeist: agent socket open at {s}", .{path});
}

/// Hand a request from a connection thread to the app thread.
///
/// Pushed with a blocking timeout rather than dropped: the connection
/// thread is already waiting on this, and losing it would leave the agent
/// waiting for an answer that is never coming.
fn submitPoltergeistRequest(
    ctx: *anyopaque,
    pending: *poltergeistpkg.Server.Pending,
) void {
    const self: *App = @ptrCast(@alignCast(ctx));

    // A zero return means the push failed, in which case nothing will ever
    // take the reference off our hands.
    if (self.mailbox.push(
        global.io(),
        .{ .poltergeist_request = pending },
        .{ .forever = {} },
    ) == 0) {
        log.warn("poltergeist: could not queue an agent request", .{});
        pending.release();
        return;
    }

    // Queuing is not delivering. The app loop sleeps until something wakes
    // it, so without this the request sits in the mailbox until some
    // unrelated event -- a keystroke, a redraw, the next quiescence sample
    // -- happens to wake the loop for its own reasons. Measured on a real
    // machine that meant replies arriving between 50ms and never: the agent
    // saw an occasional fast answer and an occasional timeout, with no
    // pattern to it.
    if (self.poltergeist_rt_app) |rt| rt.wakeup();
}

/// Answer one agent request. Runs on the app thread, which is the only
/// thread that may touch the bus or a surface.
fn poltergeistRequest(self: *App, pending: *poltergeistpkg.Server.Pending) void {
    // The reference taken when this was handed over. Releasing it here is
    // what lets the connection thread's frame go away safely even if
    // shutdown answered the request before we got to it.
    defer pending.release();

    // A request can clock a terminal off or on, which is exactly the sort
    // of thing the tabs are there to show. Cheap enough to do after every
    // request: each surface compares its own mark and does nothing when it
    // has not moved.
    defer self.refreshPoltergeistTabs();

    // Duty changes are part of the arrangement, so they go in the notes
    // for tomorrow. The group calls save themselves; these do not pass
    // through the chat at all.
    defer switch (pending.request) {
        .clock_out, .clock_in => self.saveSession(),
        else => {},
    };

    // The server resolved the token to a surface, exactly as it does for
    // an agent's sidecar. One more question decides whose request this is:
    // a surface this app opened for the chat speaks for the person at the
    // keyboard, and nothing else does.
    const caller = if (self.isChatSurface(pending.caller))
        poltergeistpkg.Chat.user_id
    else
        pending.caller;

    const response = poltergeistpkg.rpc.dispatch(
        pending.arena.allocator(),
        &self.poltergeist,
        self.poltergeistHost(),
        caller,
        pending.request,
    ) catch |err| switch (err) {
        error.OutOfMemory => poltergeistpkg.wire.Response{ .failed = .{
            .code = "OutOfMemory",
            .message = "out of memory",
        } },
    };

    pending.complete(global.io(), response);
}

/// Whether this surface is one the app opened to run the chat interface.
fn isChatSurface(self: *const App, id: poltergeistpkg.Bus.Id) bool {
    for (self.chat_surfaces.items) |v| if (v == id) return true;
    return false;
}

/// Record that a surface is running the chat, so its requests count as the
/// user's. Called by the apprt after it has opened one.
pub fn addChatSurface(self: *App, id: poltergeistpkg.Bus.Id) Allocator.Error!void {
    if (self.isChatSurface(id)) return;
    try self.chat_surfaces.append(self.alloc, id);
}

/// Forget one, because the terminal running it has gone.
pub fn removeChatSurface(self: *App, id: poltergeistpkg.Bus.Id) void {
    for (self.chat_surfaces.items, 0..) |v, i| {
        if (v == id) {
            _ = self.chat_surfaces.swapRemove(i);
            return;
        }
    }
}

fn poltergeistHost(self: *App) poltergeistpkg.rpc.Host {
    return .{ .ctx = self, .vtable = &.{
        .readTerminal = poltergeistRead,
        .sendText = poltergeistSend,
        .performAction = poltergeistPerformAction,
        .quietMs = poltergeistQuiet,
        .openTerminals = poltergeistOpenTerminals,
        .openTerminal = poltergeistOpenTerminal,
        .configText = poltergeistConfigText,
        .setWatching = poltergeistSetWatching,
        .stoodDown = poltergeistStoodDown,
        .drainNotices = poltergeistDrainNotices,
        .setThreshold = poltergeistThreshold,
        .readSkill = poltergeistSkill,
        .chatCreate = chatCreate,
        .chatDestroy = chatDestroy,
        .chatAdd = chatAdd,
        .chatRemove = chatRemove,
        .chatCompact = chatCompact,
        .chatPost = chatPost,
        .notifyUser = notifyUser,
        .sessionRecall = sessionRecall,
        .chatSetBrief = chatSetBrief,
        .chatGroupInfo = chatGroupInfo,
        .chatOwner = chatOwner,
        .chatMembers = chatMembers,
        .chatGroups = chatGroups,
        .chatRead = chatRead,
        .chatHistory = chatHistory,
        .pluginList = pluginList,
        .pluginRoots = pluginRoots,
        .pluginConfigure = pluginConfigure,
        .pluginTest = pluginTest,
    } };
}

// -- the plugin tools' side of the host -------------------------------------
//
// All four run on the app thread: `poltergeistRequest` dispatches there, and
// so do `notifyUser` and `ensureArchive`. That is what makes it safe for a
// configure to throw the plugin arena away and read the directories again
// while archives are running.
//
// The allocator handed in is the request's own arena, so everything scanned
// can go straight into it and nothing has to be duplicated afterwards.

/// Every plugin installed, switched on or not.
///
/// Off is not a reason to leave one out: "what is here and is it on" is the
/// question this answers, and the plugin somebody is asking about is usually
/// the one that is not doing anything.
fn pluginList(
    ctx: *anyopaque,
    alloc: Allocator,
    key: []const u8,
) anyerror![]const poltergeistpkg.rpc.PluginView {
    const self: *App = @ptrCast(@alignCast(ctx));

    const io = global.io();
    var environ_map = try global.environMap();
    defer environ_map.deinit();

    var out: std.ArrayListUnmanaged(poltergeistpkg.rpc.PluginView) = .empty;

    for (self.scanPlugins(alloc, io, &environ_map, true)) |installed| {
        const manifest = installed.manifest;
        if (key.len > 0 and !std.mem.eql(u8, key, manifest.key)) continue;

        var params: std.ArrayListUnmanaged(poltergeistpkg.rpc.PluginParamView) = .empty;

        // Every declared parameter, whether or not it has a value -- and the
        // ones with no value matter more than the ones with. They are the
        // only way `rpc.dispatch` learns that a parameter is `secret`, or
        // what its `enum` allows, *before* an agent writes it for the first
        // time. A listing that walked the configured values instead would
        // drop that rule on exactly the write that most needs it.
        for (manifest.params) |spec| {
            try params.append(alloc, poltergeistpkg.rpc.viewOf(
                spec,
                configuredValue(installed.settings.params, spec.name),
            ));
        }

        // Then whatever is in the file that the manifest does not declare.
        // Shown rather than hidden, because an audit has to see the whole
        // file. What these are **not** is a schema: their `secret: false`
        // and empty `choices` are the absence of a declaration, not a
        // declaration of absence, and nothing may read one as permission to
        // write. `pluginConfigure` refuses every undeclared name outright.
        for (installed.settings.params) |configured| {
            if (manifest.param(configured.name) != null) continue;

            try params.append(alloc, poltergeistpkg.rpc.undeclaredView(
                configured.name,
                configured.value,
            ));
        }

        // Handed over exactly as the manifest declared them, unread: an
        // agent has to be able to tell the user what it is about to switch
        // on.
        var view: poltergeistpkg.rpc.PluginView = .{
            .key = manifest.key,
            .name = manifest.name,
            .kind = @tagName(manifest.kind),
            .enabled = installed.settings.enabled,
            .groups = manifest.wants.groups,
            .network = manifest.wants.network,
            .exec = manifest.wants.exec,
            .params = params.items,
        };

        if (manifest.kind == .archive) {
            // Left empty when no copy is running, rather than reported as
            // zero. `wire.writePlugin` leaves the whole group out then, and
            // an absent `cursor` reads as "not being measured" where a `0`
            // would read as "measured, and it is nothing".
            const status = if (self.archiveFor(manifest.key)) |a| a.status() else null;
            if (status) |st| {
                view.state = @tagName(st.state);
                view.cursor = st.cursor;
                view.failures = st.failures;
            }

            view.note = try poltergeistpkg.report.archiveNote(alloc, .{
                .key = manifest.key,
                .enabled = installed.settings.enabled,
                .declares_groups = !manifest.wants.empty(),
                .log_open = self.chat_log != null,
                .status = status,
            });
        }

        try out.append(alloc, view);
    }

    // A key that matched nothing comes back as an empty listing rather than
    // an error: a listing that found nothing is still a listing, and
    // `UnknownPlugin`'s "plugin_list shows what is" would be pointing this
    // reply back at itself.
    return out.items;
}

/// The value configured for a name, or empty when there is none.
fn configuredValue(
    params: []const poltergeistpkg.Plugin.Param,
    name: []const u8,
) []const u8 {
    for (params) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
    return "";
}

/// Where a `file:` reference written through the tool surface may point.
///
/// The user's polter config and state directories. Both come back absolute
/// with `~` already resolved, because `xdg` builds them out of `HOME` --
/// which is the precondition `rpc.Guard.roots` documents for itself.
///
/// The subdirectory is `polter`, not `polter/plugins`: a credential file
/// dropped beside the settings is the case this exists for.
///
/// **The state directory is the wide half of this, and knowingly so.**
/// `$XDG_STATE_HOME/polter` is where `chat/chat.jsonl` and the per-plugin
/// cursors live, so a `file:` reference naming the chat log would hand its
/// first line to a notification plugin as a parameter value. That is what a
/// `file:` reference *is* -- it moves a file's contents into a parameter --
/// and `roots` is the only thing deciding which files. It is written this
/// way because `docs/poltergeist/mcp.md` names both directories twice; if
/// that is revisited, the two narrowings on the table are dropping the state
/// root entirely, or replacing it with a `secrets` subdirectory meant only
/// for credentials.
///
/// An allocation failure or a missing environment returns an **empty slice,
/// not an error**: empty makes `Guard.underRoot` refuse every `file:`
/// reference, and refusing is the right direction when containment could not
/// be worked out.
fn pluginRoots(_: *anyopaque, alloc: Allocator) anyerror![]const []const u8 {
    const io = global.io();

    var environ_map = global.environMap() catch return &.{};
    defer environ_map.deinit();

    var out: std.ArrayListUnmanaged([]const u8) = .empty;

    if (internal_os.xdg.config(io, alloc, &environ_map, .{ .subdir = "polter" })) |base| {
        out.append(alloc, base) catch return &.{};
    } else |_| {}

    if (internal_os.xdg.state(io, alloc, &environ_map, .{ .subdir = "polter" })) |base| {
        out.append(alloc, base) catch return &.{};
    } else |_| {}

    return out.items;
}

/// Write a plugin's settings file, and say what that does and does not take
/// effect on.
///
/// The order below is the design, not an implementation detail: the plugin
/// is resolved first so an unknown name costs nothing, the two refusals come
/// before anything is written, and the write happens before anything is
/// started so that what starts is what is on disk.
fn pluginConfigure(
    ctx: *anyopaque,
    alloc: Allocator,
    key: []const u8,
    enable: ?bool,
    params: []const poltergeistpkg.Plugin.Param,
) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));

    const io = global.io();
    var environ_map = try global.environMap();
    defer environ_map.deinit();

    const installed = self.installedPlugin(alloc, io, &environ_map, key) orelse
        return error.NoSuchPlugin;
    const manifest = installed.manifest;

    // `rpc.Guard.enabling` already refuses this with the sentence an agent
    // reads. This is the second lock, on the thing that actually writes: a
    // plugin is the channel the person hears about things on, and no path
    // through this file may quiet it.
    if (enable) |e| if (!e) return error.WillNotDisable;

    for (params) |change| {
        // Independent of whatever dispatch checked, and it is this check
        // that closes the undeclared-name hole for good: a name the schema
        // does not carry cannot be judged secret, so it cannot be written.
        _ = manifest.param(change.name) orelse return error.UnknownParameter;

        // Over the requested changes **only**, never over the merged result.
        // A user who hand-wrote `"dsn": "cmd:op read ..."` -- the form the
        // documentation recommends -- must still be able to have `backend`
        // set; `merge` carries their line through untouched, and carrying an
        // existing line through is not writing a new one. Checking the merge
        // instead would make every properly configured plugin permanently
        // unconfigurable, and it would look like a refusal rather than a bug.
        if (poltergeistpkg.secret.classify(change.value)) |prefix| {
            if (prefix == .cmd) return error.WillNotWriteCmd;
        }
    }

    var next = try installed.settings.merge(alloc, params);

    // `merge` deliberately leaves this alone; deciding it is the caller's.
    next.enabled = installed.settings.enabled or (enable orelse false);
    const switched_on = next.enabled and !installed.settings.enabled;

    // Keyed on `manifest.key` rather than the directory name, and written
    // into the user's config: that is where `pluginSettings` reads from, so
    // a shipped plugin's settings land beside the user's own.
    const base = internal_os.xdg.config(
        io,
        alloc,
        &environ_map,
        .{ .subdir = "polter/plugins" },
    ) catch return error.NoConfigDir;

    const path = try std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ base, manifest.key });
    try next.write(alloc, io, path);

    self.reloadPlugins();

    var started: poltergeistpkg.report.Started = .not_an_archive;
    if (manifest.kind == .archive) {
        started = if (self.archiveFor(manifest.key) != null)
            .already_running
        else if (switched_on and self.startArchiveNow(alloc, io, &environ_map, manifest.key))
            .started_now
        else
            .not_started;
    }

    const said = try poltergeistpkg.report.configured(
        alloc,
        manifest.key,
        manifest.kind,
        switched_on,
        params.len > 0,
        started,
    );
    if (started != .not_started) return said;

    // Why it is not running is `archiveNote`'s to say, so it is said in one
    // place and never written out twice.
    const note = try poltergeistpkg.report.archiveNote(alloc, .{
        .key = manifest.key,
        .enabled = next.enabled,
        .declares_groups = !manifest.wants.empty(),
        .log_open = self.chat_log != null,
        .status = null,
    });
    if (note.len == 0) return said;

    return std.fmt.allocPrint(alloc, "{s} {s}", .{ said, note });
}

/// Start the archive plugin called `key`, taking the manifest out of the
/// list as it stands **now**.
///
/// After a reload, so what gets started is what was just written rather than
/// what was read before the write.
fn startArchiveNow(
    self: *App,
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    key: []const u8,
) bool {
    for (self.poltergeist_plugins) |manifest| {
        if (!std.mem.eql(u8, manifest.key, key)) continue;
        const settings = self.pluginSettings(alloc, io, environ_map, manifest.key);
        return self.startArchive(manifest, settings);
    }
    return false;
}

/// The installed plugin with this key, switched on or not.
fn installedPlugin(
    self: *App,
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    key: []const u8,
) ?Installed {
    for (self.scanPlugins(alloc, io, environ_map, true)) |installed| {
        if (std.mem.eql(u8, installed.manifest.key, key)) return installed;
    }
    return null;
}

/// Prove a plugin works before the night it is needed.
///
/// A notification plugin is really sent through, going round `notify.decide`
/// on purpose: quiet hours do not apply, because the point of a test is that
/// it goes out, and the tool's own description says so. Every word of what
/// goes out is written here -- the schema has no free-text field, and that
/// is what keeps this from being an unconstrained outbound channel with the
/// constrained one (`notify_user`) sitting next to it as the long way round.
///
/// An archive plugin has **nothing started for it**. See
/// `poltergeist/report.zig` for why, and for the sentence that says so.
fn pluginTest(
    ctx: *anyopaque,
    alloc: Allocator,
    key: []const u8,
    by: poltergeistpkg.Bus.Id,
) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));

    const io = global.io();
    var environ_map = try global.environMap();
    defer environ_map.deinit();

    // Resolved first, so an unknown name does not spend the budget below.
    const installed = self.installedPlugin(alloc, io, &environ_map, key) orelse
        return error.NoSuchPlugin;

    // Global rather than per key: this protects the person, not the plugin,
    // and a person with four channels configured is one person. The archive
    // branch spends it too, as specified.
    const now = self.poltergeistNow();
    if (self.poltergeist_plugin_tested_ms) |last| {
        if (now -| last < std.time.ms_per_min) return error.TooSoon;
    }
    self.poltergeist_plugin_tested_ms = now;

    if (installed.manifest.kind == .archive) {
        return poltergeistpkg.report.archiveStatus(alloc, .{
            .key = installed.manifest.key,
            .enabled = installed.settings.enabled,
            .declares_groups = !installed.manifest.wants.empty(),
            .log_open = self.chat_log != null,
            .status = if (self.archiveFor(installed.manifest.key)) |a| a.status() else null,
        });
    }

    // The terminal's name goes in the field `notifyUser` already puts it in,
    // and nowhere else. A tab title is something the agent in that terminal
    // can set, so splicing it into the body would open a path from an agent
    // to the wording of a notification -- and this tool exists precisely
    // because its wording is not the agent's.
    var name_buf: [256]u8 = undefined;
    var name_fixed: std.heap.FixedBufferAllocator = .init(&name_buf);
    const terminal_name = if (by != 0)
        self.chatMemberTitle(name_fixed.allocator(), by) catch ""
    else
        "";

    const event: poltergeistpkg.notify.Event = .{
        .reason = .scheduling,
        .title = "Polter test",
        .body = "A test of this notification channel, asked for through Polter's " ++
            "plugin_test tool. Nothing is wrong. If this reached you, the channel works.",
        .terminal = by,
        .terminal_name = terminal_name,
        .at_ms = self.poltergeist_epoch_wall_ms + @as(i64, @intCast(now)),
    };

    // The one plugin that was named, not `notify.send`, which would fan the
    // test out to every channel the user has.
    const rendered = try poltergeistpkg.notify.body(alloc, event);
    const outcome = poltergeistpkg.Plugin.call(
        installed.manifest,
        alloc,
        io,
        &environ_map,
        rendered,
        installed.settings.params,
    );

    return poltergeistpkg.report.notified(
        alloc,
        installed.manifest.key,
        installed.settings.enabled,
        outcome,
    );
}

fn poltergeistRead(
    ctx: *anyopaque,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
    lines: u16,
) anyerror![]const u8 {
    _ = lines;
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return error.NoSuchTerminal;

    // The pins have to be taken under the same lock that the read happens
    // under. The terminal belongs to the IO thread, and building a
    // selection first would let it scroll or reclaim a page in between --
    // leaving the pins pointing at freed nodes by the time they are used.
    surface.renderer_state.mutex.lockUncancelable(global.io());
    defer surface.renderer_state.mutex.unlock(global.io());

    // The visible screen. `lines` is not honoured yet: selecting further
    // back needs a pin walk into the scrollback, and handing back the wrong
    // rows would be worse than not offering it.
    const screen = surface.io.terminal.screens.active;
    const tl = screen.pages.getTopLeft(.viewport);
    const br = screen.pages.getBottomRight(.viewport) orelse tl;
    const sel: terminal.Selection = .init(tl, br, false);

    const text = try surface.dumpTextLocked(alloc, sel);
    return text.text;
}

fn poltergeistSend(
    ctx: *anyopaque,
    id: poltergeistpkg.Bus.Id,
    text: []const u8,
    submit: bool,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return error.NoSuchTerminal;
    try surface.typePoltergeistText(text, submit);
}

/// Do one of the terminal's own keybinding actions to it.
///
/// The same two calls the menu bar makes -- parse the string, hand it to
/// `performBindingAction` -- so an agent asking for `new_tab` and a person
/// pressing the key for it end up in exactly the same place. There is no
/// second implementation to drift.
///
/// The surface must be found before the action is parsed: an id that names
/// nothing is a different mistake from an action that does not parse, and
/// the two want different answers from the agent that made them.
fn poltergeistPerformAction(
    ctx: *anyopaque,
    id: poltergeistpkg.Bus.Id,
    action: []const u8,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return error.UnknownTerminal;

    const parsed = input.Binding.Action.parse(action) catch |err| {
        log.warn("poltergeist: action {s} would not parse err={}", .{ action, err });
        return error.InvalidAction;
    };

    // The return says whether the terminal took it. False is not a failure
    // of ours -- `toggle_split_zoom` on a window with no splits does
    // nothing, and rightly -- but the agent asked for something to happen,
    // so it is told that nothing did.
    if (!(try surface.performBindingAction(parsed))) return error.ActionIgnored;
}

fn poltergeistSetWatching(
    ctx: *anyopaque,
    id: poltergeistpkg.Bus.Id,
    watching: bool,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return error.UnknownTerminal;
    surface.setPoltergeistWatching(watching);

    // Being put under supervision changes what may happen to this terminal,
    // so the terminal is told -- the same reason the keybind path tells it.
    if (watching) {
        self.tellSurface(id, "[Polter] A supervisor is now watching this " ++
            "terminal and will be told when your screen has been still for a " ++
            "while. It may read your screen and write to you. Nothing is " ++
            "watching what you type.");
    }

    self.saveSession();
}

/// A supervisor has just taken itself off duty.
///
/// The bus has already forgotten the standing; what is left is everything
/// outside it. The tab mark is refreshed for the same reason the keybind
/// refreshes it -- a terminal that is no longer in charge should stop
/// saying it is at once, not whenever something else happens to redraw.
/// And the arrangement is written down, because a supervisor that stood
/// down last night is not one tomorrow's recall should describe as still
/// minding anybody.
fn poltergeistStoodDown(ctx: *anyopaque, id: poltergeistpkg.Bus.Id) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    _ = id;
    self.refreshPoltergeistTabs();
    self.saveSession();
}

fn poltergeistQuiet(ctx: *anyopaque, id: poltergeistpkg.Bus.Id) u64 {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.poltergeist.quietMs(id, self.poltergeistNow());
}

/// Every terminal on screen, with where it is and what it is called.
///
/// The chat interface is left out: it is a window onto the conversation,
/// not a terminal anybody could resume, and listing it would put a thing
/// the supervisor cannot act on into the list it uses to decide.
/// Open a terminal in the same window, starting in `cwd`.
///
/// The tab is opened from the caller's own terminal, so it lands in the
/// caller's window -- which is the only window Poltergeist has any view of.
///
/// **The id comes back by looking, not by being told.** Creating a surface
/// goes out through the apprt and comes back in when the runtime gets round
/// to it; on macOS that is a notification, delivered synchronously today and
/// under no obligation to stay that way. So the surfaces are counted before
/// and after, and if a new one has appeared by the time the action returns it
/// is named. If none has, that is not a failure -- the tab is still opening
/// -- and the caller is told to go and look. Waiting on it here would park
/// the socket thread on something the UI thread has to finish.
/// Re-render the configuration as text.
///
/// Failure leaves the previous text in place rather than clearing it: an
/// agent reading a slightly stale value is better off than one told there is
/// no configuration at all, and the next reload will try again.
fn refreshPoltergeistConfigText(self: *App, config: *const Config) void {
    const fmt: configpkg.FileFormatter = .{ .alloc = self.alloc, .config = config };

    var out: std.Io.Writer.Allocating = .init(self.alloc);
    defer out.deinit();
    fmt.format(&out.writer) catch |err| {
        log.warn("poltergeist: could not render the config err={}", .{err});
        return;
    };

    const text = out.toOwnedSlice() catch return;
    if (self.poltergeist_config_text.len > 0) self.alloc.free(self.poltergeist_config_text);
    self.poltergeist_config_text = text;
}

/// The configuration, or the lines of it that begin with `key`.
///
/// Lines rather than a value, because a key may appear more than once --
/// `poltergeist-notify` is written once per channel -- and handing back the
/// first would quietly lose the rest.
fn poltergeistConfigText(
    ctx: *anyopaque,
    alloc: Allocator,
    key: []const u8,
) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    if (self.poltergeist_config_text.len == 0) return error.NoConfig;
    if (key.len == 0) return alloc.dupe(u8, self.poltergeist_config_text);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    var it = std.mem.splitScalar(u8, self.poltergeist_config_text, '\n');
    while (it.next()) |line| {
        // The whole key, not a prefix of it: `poltergeist-watch` must not
        // match `poltergeist-watch-something` that upstream adds later.
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = line[key.len..];
        if (!std.mem.startsWith(u8, rest, " =")) continue;

        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }

    if (out.items.len == 0) return error.NoSuchKey;
    return out.items;
}

fn poltergeistOpenTerminal(
    ctx: *anyopaque,
    alloc: Allocator,
    cwd: []const u8,
    by: poltergeistpkg.Bus.Id,
) anyerror!?poltergeistpkg.Bus.Id {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(by) orelse return error.UnknownTerminal;

    // Checked here so a directory that is not there is refused rather than
    // quietly ignored. The apprt logs and carries on -- which is right for a
    // config file read at startup and wrong for a request somebody is
    // waiting on an answer to.
    var dir_z: [:0]const u8 = "";
    if (cwd.len > 0) {
        if (!std.fs.path.isAbsolute(cwd)) return error.NotAbsolute;

        var dir = std.Io.Dir.openDirAbsolute(global.io(), cwd, .{}) catch
            return error.NoSuchDirectory;
        defer dir.close(global.io());

        const stat = dir.stat(global.io()) catch return error.NoSuchDirectory;
        if (stat.kind != .directory) return error.NotADirectory;

        dir_z = try alloc.dupeZ(u8, cwd);
    }

    var before: std.AutoHashMapUnmanaged(poltergeistpkg.Bus.Id, void) = .empty;
    defer before.deinit(alloc);
    for (self.surfaces.items) |v| try before.put(alloc, v.core().id, {});

    const rt_app = self.poltergeist_rt_app orelse return error.NoRuntime;
    _ = rt_app.performAction(
        .{ .surface = surface },
        .new_tab,
        .{ .working_directory = dir_z },
    ) catch return error.OpenFailed;

    for (self.surfaces.items) |v| {
        const id = v.core().id;
        if (before.contains(id)) continue;
        if (self.isChatSurface(id)) continue;
        return id;
    }
    return null;
}

fn poltergeistOpenTerminals(
    ctx: *anyopaque,
    alloc: Allocator,
) anyerror![]const poltergeistpkg.rpc.Place {
    const self: *App = @ptrCast(@alignCast(ctx));

    var out: std.ArrayListUnmanaged(poltergeistpkg.rpc.Place) = .empty;
    errdefer out.deinit(alloc);

    for (self.surfaces.items) |v| {
        const surface: *Surface = v.core();
        if (self.isChatSurface(surface.id)) continue;

        const footing = self.footingOf(alloc, surface.id);
        try out.append(alloc, .{
            .id = surface.id,
            .cwd = footing.cwd,
            .title = footing.title,
        });
    }

    return out.toOwnedSlice(alloc);
}

/// The supervisor reading its own box, which is not the scheduled
/// hand-over and so is never held back for it. Consuming, like the
/// hand-over: what is read here will not arrive again on the interval.
fn poltergeistDrainNotices(
    ctx: *anyopaque,
    alloc: Allocator,
    to: poltergeistpkg.Bus.Id,
) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));

    var buf: [255]u8 = undefined;
    const line = self.poltergeist.drain(to, self.poltergeistNow(), &buf) orelse
        return "";
    return alloc.dupe(u8, line);
}

fn chatCreate(ctx: *anyopaque, group: []const u8, by: poltergeistpkg.Bus.Id) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    try self.chat.create(group, by);

    // The person at the keyboard is in every group. These are
    // conversations happening on their machine; a window they could read
    // but not answer in would be a strange thing to build.
    // The person at the keyboard has no terminal of their own, so there
    // is nothing to record about where they are working.
    try self.chat.add(group, poltergeistpkg.Chat.user_id, .all, .{});
    self.saveSession();
}

/// Bring every tab's Poltergeist mark in line with the state behind it.
///
/// Cheap: each surface compares the mark it last set and does nothing when
/// it has not moved, so this can be called whenever anything happens.
pub fn refreshPoltergeistTabs(self: *App) void {
    for (self.surfaces.items) |rt_surface| {
        rt_surface.core().updatePoltergeistTabMark();
    }
}

fn chatDestroy(ctx: *anyopaque, group: []const u8) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    try self.chat.destroy(group);
    self.saveSession();
}

fn chatAdd(
    ctx: *anyopaque,
    group: []const u8,
    id: poltergeistpkg.Bus.Id,
    history: poltergeistpkg.Chat.History,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));

    // Recorded here, by us, because these are facts we already hold.
    // Asking the supervisor to tell us where a terminal is working would
    // only add a chance for it to be told wrong.
    var buf: [2048]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buf);
    const footing = self.footingOf(fixed.allocator(), id);

    try self.chat.add(group, id, history, footing);

    // `history: none` means nothing from before now, and "before now"
    // includes the file. The group in memory cannot say where that reaches
    // -- after a restart it is empty while `chat.jsonl` still holds last
    // night under the same name -- so the one thing holding the log says
    // it. Without this the terminal is kept out by `group_read` and handed
    // all of it by `group_history`.
    if (history == .none) {
        if (self.chat_log) |*l| self.chat.setLogFloor(group, id, l.head());
    }

    self.saveSession();
}

/// Bring a member's recorded footing up to date, if we learned anything.
///
/// **Only overwrites with something.** When a terminal has closed there
/// is no surface to ask, and that is exactly when the old record matters
/// most -- it is what tomorrow's restart has to go on. Blanking it here
/// would throw away the answer at the moment the question gets asked.
fn refreshFooting(
    self: *App,
    group: []const u8,
    id: poltergeistpkg.Bus.Id,
) void {
    if (id == poltergeistpkg.Chat.user_id) return;

    var buf: [2048]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buf);
    const now = self.footingOf(fixed.allocator(), id);
    if (now.cwd.len == 0 and now.title.len == 0) return;

    self.chat.setFooting(group, id, now) catch |err| {
        log.debug("poltergeist: could not update footing err={}", .{err});
    };
}

/// Where a terminal is working, for finding it again after a restart.
///
/// Best effort throughout: a bare shell may have no title, and the
/// working directory is only known once the shell has reported one. An
/// empty field is an honest "we do not know", which beats refusing to
/// record the member at all.
fn footingOf(
    self: *App,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
) poltergeistpkg.Chat.Footing {
    const surface = self.findSurfaceByID(id) orelse return .{};

    var out: poltergeistpkg.Chat.Footing = .{};

    if (surface.pwd(alloc) catch null) |dir| out.cwd = dir;

    if (surface.rt_surface.getTitle()) |title| {
        if (title.len > 0) out.title = alloc.dupe(u8, title) catch "";
    }

    return out;
}

fn chatOwner(ctx: *anyopaque, group: []const u8) anyerror!poltergeistpkg.Bus.Id {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.chat.createdBy(group);
}

fn chatRemove(
    ctx: *anyopaque,
    group: []const u8,
    id: poltergeistpkg.Bus.Id,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    try self.chat.remove(group, id);
    self.saveSession();
}

fn chatCompact(
    ctx: *anyopaque,
    group: []const u8,
    through: u64,
    summary: []const u8,
    by: poltergeistpkg.Bus.Id,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const at = self.poltergeistNow();
    const seq = try self.chat.compact(group, through, summary, by, at);

    // Written after the messages it replaced, not over them. Compaction
    // frees the agents' context; it is not an instruction to forget, and
    // the record of a night is worth more than the shape it was in when
    // the supervisor tidied up.
    self.logChat(group, seq, by, at, true, summary);
}

fn chatPost(
    ctx: *anyopaque,
    group: []const u8,
    from: poltergeistpkg.Bus.Id,
    text: []const u8,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const at = self.poltergeistNow();
    const seq = try self.chat.post(group, from, text, at);

    // A terminal's title moves with its work, so the record follows it.
    // Speaking is the right moment: it is infrequent, and a terminal that
    // just spoke is one whose title means something.
    self.refreshFooting(group, from);

    // Written down after the model accepted it, so the record holds what
    // was actually said rather than what somebody tried to say.
    self.logChat(group, seq, from, at, false, text);

    self.tellTerminalsAboutMessages();
}

/// Put one message in the log on disk, if there is one.
///
/// The author's name is resolved here rather than at read time because a
/// terminal's title changes, and worse, the terminal goes away: a record
/// written tonight has to still say who spoke when it is read tomorrow.
///
/// `seq` is the group's own count for the message, carried in only so the
/// line it became on disk can be tied back to it. With no log, or with a
/// write that failed, the message keeps `log_seq = 0` -- which is what a
/// reader paging backwards has to see to know the trail stops there.
fn logChat(
    self: *App,
    group: []const u8,
    seq: u64,
    from: poltergeistpkg.Bus.Id,
    at_ms: u64,
    summary: bool,
    text: []const u8,
) void {
    const l = if (self.chat_log) |*v| v else return;

    var buf: [256]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buf);
    const author = self.chatMemberTitle(fixed.allocator(), from) catch "";

    const at_wall_ms = self.poltergeist_epoch_wall_ms + @as(i64, @intCast(at_ms));

    const log_seq = l.append(
        group,
        from,
        author,
        at_wall_ms,
        summary,
        text,
    );
    if (log_seq != 0) self.chat.setLogSeq(group, seq, log_seq);

    // Handed to whoever is listening, after the record and never instead
    // of it: the record is what is read back, and a plugin keeps an extra
    // copy of what it is told. `publish` cannot fail and does not wait, so
    // nothing a plugin does is felt on this path.
    //
    // The seq is the one the record stamped on the message. It is an
    // identity and not a position in any file -- it is what lets a plugin
    // store the same message twice and end up with one row -- so with no
    // record there is no identity to hand out, and nothing is published.
    if (log_seq != 0) self.poltergeist_feed.publish(.{ .chat = .{
        .seq = log_seq,
        .at_ms = at_wall_ms,
        .group = group,
        .author = author,
        .summary = summary,
        .text = text,
    } });
}

fn chatGroups(
    ctx: *anyopaque,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
) anyerror![]const []const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));

    const names = try self.chat.groupsFor(alloc, id);
    errdefer alloc.free(names);

    // Copied, not borrowed: the reply is written by the connection thread
    // after this returns, and a group can be destroyed in between.
    const owned = try alloc.alloc([]const u8, names.len);
    for (names, 0..) |n, i| owned[i] = try alloc.dupe(u8, n);
    alloc.free(names);
    return owned;
}

/// Tell the person something, and say plainly what came of it.
///
/// The supervisor asked for this because it looked at a screen and decided
/// a human was needed; the program never makes that call itself. What it
/// does decide is the hour: a scheduling question inside quiet hours is
/// handed back to the supervisor, while an authorisation prompt goes out
/// regardless -- nobody may answer those for somebody else, so holding one
/// back does not protect anyone's sleep, it just wastes the night.
///
/// The reply is a sentence rather than a code because the supervisor has
/// to act on it: if nothing was sent, waiting for an answer is waiting for
/// nothing.
fn notifyUser(
    ctx: *anyopaque,
    alloc: Allocator,
    reason_text: []const u8,
    title: []const u8,
    body: []const u8,
    id: poltergeistpkg.Bus.Id,
) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));

    const reason: poltergeistpkg.notify.Reason =
        if (std.mem.eql(u8, reason_text, "authorisation"))
            .authorisation
        else
            .scheduling;

    var name_buf: [256]u8 = undefined;
    var name_fixed: std.heap.FixedBufferAllocator = .init(&name_buf);
    const terminal_name = if (id != 0)
        self.chatMemberTitle(name_fixed.allocator(), id) catch ""
    else
        "";

    const event: poltergeistpkg.notify.Event = .{
        .reason = reason,
        .title = title,
        .body = body,
        .terminal = id,
        .terminal_name = terminal_name,
        .at_ms = self.poltergeist_epoch_wall_ms +
            @as(i64, @intCast(self.poltergeistNow())),
    };

    switch (poltergeistpkg.notify.decide(
        event,
        self.poltergeist_notify_window,
        localMinuteNow(),

        // The notification channels alone. The list holds every kind now,
        // and an installed archive plugin counted here would have this say
        // a message went somewhere it did not.
        poltergeistpkg.notify.count(self.poltergeist_plugins, .notify),
    )) {
        .nowhere_to_send => return alloc.dupe(
            u8,
            "nobody was told: no notification plugin is switched on. " ++
                "Set \"enabled\" in a plugin's file under " ++
                "$XDG_CONFIG_HOME/polter/plugins/, or handle this yourself.",
        ),

        .leave_to_supervisor => return alloc.dupe(
            u8,
            "not sent: outside the hours the user allows for questions " ++
                "like this. Decide it yourself and say so in the group.",
        ),

        .tell => {},
    }

    var environ_map = try global.environMap();
    defer environ_map.deinit();

    const result = poltergeistpkg.notify.send(
        alloc,
        global.io(),
        &environ_map,
        self.poltergeist_plugins,
        pluginParams,
        self,
        event,
    );

    if (result.delivered == 0) {
        return std.fmt.allocPrint(
            alloc,
            "nobody was told: all {d} channel(s) failed. Do not wait for an answer.",
            .{result.failed},
        );
    }

    return std.fmt.allocPrint(
        alloc,
        "sent through {d} of {d} channel(s)",
        .{ result.delivered, result.delivered + result.failed },
    );
}

/// Minutes since local midnight.
fn localMinuteNow() u16 {
    const wall: std.Io.Timestamp = .now(global.io(), .real);
    const secs: i64 = @intCast(@divTrunc(wall.nanoseconds, std.time.ns_per_s));

    var tm: internal_os.Tm = undefined;
    if (internal_os.localtime_r(&secs, &tm) == null) return 0;

    const h: u16 = @intCast(@mod(tm.hour, 24));
    const m: u16 = @intCast(@mod(tm.min, 60));
    return h * 60 + m;
}

/// A plugin's configured parameters, from its own JSON file.
fn pluginParams(
    ctx: *anyopaque,
    alloc: Allocator,
    key: []const u8,
) anyerror![]const poltergeistpkg.Plugin.Param {
    const self: *App = @ptrCast(@alignCast(ctx));

    const io = global.io();
    var environ_map = try global.environMap();
    defer environ_map.deinit();

    return self.pluginSettings(alloc, io, &environ_map, key).params;
}

/// Hand back last night's arrangement, as it was written down.
///
/// Verbatim, unparsed. The program has no use for it -- it is material for
/// the supervisor to read and act on, and re-encoding it here would only
/// add a place for the two shapes to drift apart.
fn sessionRecall(ctx: *anyopaque, alloc: Allocator) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));

    return alloc.dupe(u8, self.poltergeist_recall.text());
}

/// Say what a group is for.
fn chatSetBrief(
    ctx: *anyopaque,
    group: []const u8,
    text: []const u8,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    try self.chat.setBrief(group, text);
    self.saveSession();
}

/// The groups a terminal is in, with each group's note when it is asked
/// for. Not asked for means not read -- see the vtable for why that is
/// better than reading and discarding.
fn chatGroupInfo(
    ctx: *anyopaque,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
    want_brief: bool,
) anyerror![]poltergeistpkg.rpc.ChatGroupInfo {
    const self: *App = @ptrCast(@alignCast(ctx));

    const names = try self.chat.groupsFor(alloc, id);
    defer alloc.free(names);

    const out = try alloc.alloc(poltergeistpkg.rpc.ChatGroupInfo, names.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |g| {
            alloc.free(g.name);
            if (g.brief.len > 0) alloc.free(g.brief);
        }
        alloc.free(out);
    }

    for (names, 0..) |n, i| {
        // Copied for the same reason as above: the reply is written after
        // this returns, and the chat can move underneath it.
        const brief = if (want_brief) brief: {
            const b = self.chat.briefOf(n) catch "";
            break :brief if (b.len > 0) try alloc.dupe(u8, b) else "";
        } else "";

        out[i] = .{ .name = try alloc.dupe(u8, n), .brief = brief };
        filled += 1;
    }
    return out;
}

/// Who is in a group, each named the way a person can find them.
fn chatMembers(
    ctx: *anyopaque,
    alloc: Allocator,
    group: []const u8,
) anyerror![]const poltergeistpkg.rpc.ChatMember {
    const self: *App = @ptrCast(@alignCast(ctx));

    const ids = try self.chat.membersOf(alloc, group);
    defer alloc.free(ids);

    const out = try alloc.alloc(poltergeistpkg.rpc.ChatMember, ids.len);
    var named: usize = 0;
    errdefer {
        for (out[0..named]) |m| alloc.free(m.title);
        alloc.free(out);
    }

    for (ids, 0..) |id, i| {
        out[i] = .{ .id = id, .title = try self.chatMemberTitle(alloc, id) };
        named += 1;
    }
    return out;
}

/// What to call a terminal where a person will read it.
///
/// Its tab title first, so the name in the chat and the name on the tab are
/// the same string and a reader can tell which window a message came from.
/// An id cannot be matched against anything on screen, so it is the last
/// resort rather than the obvious answer.
///
/// A terminal only has a title once the program in it sets one. Agent CLIs
/// do; a bare shell sitting at a prompt may not, and then the directory it
/// is in says far more about which window it is than sixteen hex digits.
fn chatMemberTitle(
    self: *App,
    alloc: Allocator,
    id: poltergeistpkg.Bus.Id,
) Allocator.Error![]const u8 {
    if (id == poltergeistpkg.Chat.user_id) return alloc.dupe(u8, "you");

    const surface = self.findSurfaceByID(id) orelse
        return std.fmt.allocPrint(alloc, "0x{x:0>16}", .{id});

    if (surface.rt_surface.getTitle()) |title| {
        if (title.len > 0) return alloc.dupe(u8, title);
    }

    if (surface.pwd(alloc) catch null) |dir| {
        defer alloc.free(dir);
        if (dir.len > 0) {
            const base = std.fs.path.basename(dir);
            return alloc.dupe(u8, if (base.len > 0) base else dir);
        }
    }

    return std.fmt.allocPrint(alloc, "0x{x:0>16}", .{id});
}

fn chatRead(
    ctx: *anyopaque,
    alloc: Allocator,
    group: []const u8,
    id: poltergeistpkg.Bus.Id,
    since: u64,
) anyerror![]const poltergeistpkg.rpc.ChatLine {
    const self: *App = @ptrCast(@alignCast(ctx));

    const messages = try self.chat.read(alloc, group, id, since);
    defer alloc.free(messages);

    const out = try alloc.alloc(poltergeistpkg.rpc.ChatLine, messages.len);
    errdefer alloc.free(out);

    for (messages, 0..) |m, i| {
        // Copied for the same reason: the log trims itself as it grows.
        out[i] = .{
            .seq = m.seq,
            .log_seq = m.log_seq,
            .from = m.from,
            .author = try self.chatMemberTitle(alloc, m.from),

            // Back onto the wall clock. The log runs on a monotonic one,
            // which is right for measuring stillness and useless for
            // saying what time somebody spoke.
            .at_ms = self.poltergeist_epoch_wall_ms + @as(i64, @intCast(m.at_ms)),

            .summary = m.summary,
            .text = try alloc.dupe(u8, m.text),
        };
    }

    return out;
}

/// Read further back than the group still holds, out of the log on disk.
fn chatHistory(
    ctx: *anyopaque,
    alloc: Allocator,
    group: []const u8,
    id: poltergeistpkg.Bus.Id,
    before_seq: u64,
    limit: usize,
) anyerror!poltergeistpkg.rpc.ChatPage {
    const self: *App = @ptrCast(@alignCast(ctx));

    // One question, not two. Whether this terminal is in the group and how
    // far back it may look are the same fact, and asking only the first
    // would hand a terminal added with `history: none` exactly what it was
    // added not to see. `NoSuchGroup` and `NotAMember` travel up as they
    // are; the tool surface turns them into sentences an agent can act on.
    const floor = try self.chat.floorOf(group, id);

    // No log on disk, so there is nothing behind the group to page back
    // into.
    const l = if (self.chat_log) |*v| v else return .{ .lines = &.{}, .more = false };

    // This member's view has a floor, but nothing says which line on disk
    // that floor sits at -- the messages it was barred from predate the
    // log, or were never written down. Since the bound cannot be proved,
    // give less rather than risk giving more.
    if (floor.seq > 0 and floor.log_seq == 0) return .{ .lines = &.{}, .more = false };

    const page = try l.history(alloc, group, before_seq, limit);

    // Entries come back oldest first, so anything barred is a prefix.
    var k: usize = 0;
    while (k < page.entries.len and page.entries[k].seq <= floor.log_seq) k += 1;
    const visible = page.entries[k..];

    const out = try alloc.alloc(poltergeistpkg.rpc.ChatLine, visible.len);
    for (visible, 0..) |e, i| {
        out[i] = .{
            // The log never recorded the group's own count. Inventing one
            // would be handed straight back as `group_compact`'s `through`,
            // which counts something else entirely.
            .seq = 0,
            .log_seq = e.seq,
            .from = e.from,

            // The name the log recorded, not what the tab says now: the
            // terminal that spoke is very likely closed, and the record is
            // the only place that name still exists.
            .author = e.author,

            // Already wall-clock. Adding the epoch here -- as `chatRead`
            // must, because the in-memory log is monotonic -- would put
            // these messages decades into the future.
            .at_ms = e.at_ms,

            .summary = e.summary,
            .text = e.text,
        };
    }

    // Once anything was filtered out, everything older is barred too, so
    // there is nothing further to offer this member.
    return .{ .lines = out, .more = if (k > 0) false else !page.exhausted };
}

/// Tell every terminal that has messages waiting that it has them.
///
/// A count and how to fetch, never the messages themselves. What an agent
/// does about it is its own decision, and one it can decline.
fn tellTerminalsAboutMessages(self: *App) void {
    const now_ms = self.poltergeistNow();

    for (self.surfaces.items) |rt_surface| {
        const surface = rt_surface.core();

        const names = self.chat.groupsFor(self.alloc, surface.id) catch continue;
        defer self.alloc.free(names);

        for (names) |name| {
            const count = self.chat.unread(name, surface.id);
            if (count == 0) continue;
            if (!self.chat.shouldNotify(name, surface.id, now_ms, chat_notice_gap_ms)) {
                continue;
            }

            var buf: [255:0]u8 = undefined;
            const line = poltergeistpkg.Chat.formatNotice(name, count, &buf) catch
                continue;
            buf[line.len] = 0;

            self.surfaceMessage(surface, .{
                .poltergeist_notice = buf,
            }) catch |err| {
                log.warn("poltergeist: could not deliver a message notice err={}", .{err});
            };
        }
    }
}

/// Tell a terminal something about its own standing.
///
/// **Because a role nobody is told about is a role nobody plays.** Making a
/// terminal the supervisor used to set a flag in the bus and nothing else:
/// the agent inside it was never told, so it had no reason to look for the
/// `supervising` skill or the group tools, and it reached for whatever
/// messaging its own runtime advertised instead. Watched in one place,
/// working in another, and no record either would survive a restart.
///
/// Delivered through the ordinary notice path, so it inherits the guard
/// against interrupting somebody mid-sentence and simply does not arrive
/// if the person is typing.
pub fn tellSurface(self: *App, id: poltergeistpkg.Bus.Id, text: []const u8) void {
    const surface = self.findSurfaceByID(id) orelse return;

    var buf: [255:0]u8 = undefined;
    if (text.len >= buf.len) return;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;

    self.surfaceMessage(surface, .{
        .poltergeist_notice = buf,
    }) catch |err| {
        log.warn("poltergeist: could not tell a terminal its standing err={}", .{err});
    };
}

/// Monotonic milliseconds for the bus and the chat log alike.
pub fn poltergeistNow(self: *App) u64 {
    const epoch = self.poltergeist_epoch orelse epoch: {
        const t: std.Io.Timestamp = .now(global.io(), .awake);
        self.poltergeist_epoch = t;

        const wall: std.Io.Timestamp = .now(global.io(), .real);
        self.poltergeist_epoch_wall_ms = @intCast(@divTrunc(
            wall.nanoseconds,
            std.time.ns_per_ms,
        ));

        break :epoch t;
    };
    const now: std.Io.Timestamp = .now(global.io(), .awake);
    return @intCast(std.math.clamp(
        epoch.durationTo(now).toMilliseconds(),
        0,
        std.math.maxInt(i64),
    ));
}

/// Load a skill, preferring the user's copy.
///
/// The user layer is checked first so that editing a file is how you change
/// what a supervisor does, without touching the install and without the
/// change being undone by the next upgrade.
fn poltergeistSkill(
    ctx: *anyopaque,
    alloc: Allocator,
    name: []const u8,
) anyerror![]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx));
    const io = global.io();

    user: {
        var environ_map = global.environMap() catch break :user;
        defer environ_map.deinit();

        const config_dir = internal_os.xdg.config(
            io,
            self.alloc,
            &environ_map,
            .{ .subdir = "polter" },
        ) catch break :user;
        defer self.alloc.free(config_dir);

        const path = poltergeistpkg.skill.userPath(self.alloc, config_dir, name) catch
            break :user;
        defer self.alloc.free(path);

        if (readSkillFile(io, alloc, path)) |body| return body else |_| {}
    }

    // The app-visible copy: this runs inside Ghostty, not in a sandboxed
    // host.
    const dir = global.resourcesDir();
    const resources = dir.app() orelse return error.NoSuchSkill;
    const path = try poltergeistpkg.skill.resourcePath(self.alloc, resources, name);
    defer self.alloc.free(path);

    return readSkillFile(io, alloc, path) catch error.NoSuchSkill;
}

/// Read a skill file and hand back its prose, checking that it parses so
/// that a broken file reads as missing rather than as instructions.
fn readSkillFile(io: std.Io, alloc: Allocator, path: []const u8) ![]const u8 {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1024 * 1024));
    defer alloc.free(source);

    const parsed = poltergeistpkg.skill.parse(source) catch |err| {
        log.warn("poltergeist: skill at {s} does not parse err={}", .{ path, err });
        return err;
    };

    return alloc.dupe(u8, parsed.body);
}

fn poltergeistThreshold(
    ctx: *anyopaque,
    id: poltergeistpkg.Bus.Id,
    ms: u64,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    const surface = self.findSurfaceByID(id) orelse return error.NoSuchTerminal;
    surface.setPoltergeistThreshold(ms);
}

pub fn addSurface(
    self: *App,
    rt_surface: *apprt.Surface,
) Allocator.Error!void {
    try self.surfaces.append(self.alloc, rt_surface);

    // Deliberately not registering with the Poltergeist bus here. Both
    // apprts call this *before* the core surface exists -- GTK's `core()`
    // unwraps a null and embedded's is still `undefined` -- so there is no
    // id to read yet. The bus registers a terminal the first time it is
    // named as supervisor or put under watch, which is the only point at
    // which it needs to know about it anyway.

    // Since we have non-zero surfaces, we can cancel the quit timer.
    // It is up to the apprt if there is a quit timer at all and if it
    // should be canceled.
    _ = rt_surface.rtApp().performAction(
        .app,
        .quit_timer,
        .stop,
    ) catch |err| {
        log.warn("error stopping quit timer err={}", .{err});
    };
}

/// Delete the surface from the known surface list. This will NOT call the
/// destructor or free the memory.
pub fn deleteSurface(self: *App, rt_surface: *apprt.Surface) void {
    // If this surface is the focused surface then we need to clear it.
    // There was a bug where we relied on hasSurface to return false and
    // just let focused surface be but the allocator was reusing addresses
    // after free and giving false positives, so we must clear it.
    if (self.focused_surface) |focused| {
        if (focused == rt_surface.core()) {
            self.focused_surface = null;
        }
    }

    var i: usize = 0;
    while (i < self.surfaces.items.len) {
        if (self.surfaces.items[i] == rt_surface) {
            _ = self.surfaces.swapRemove(i);
            continue;
        }

        i += 1;
    }

    // If we have no surfaces, we can start the quit timer. It is up to the
    // apprt to determine if this is necessary.
    if (self.surfaces.items.len == 0) _ = rt_surface.rtApp().performAction(
        .app,
        .quit_timer,
        .start,
    ) catch |err| {
        log.warn("error starting quit timer err={}", .{err});
    };
}

/// The last focused surface. This is only valid while on the main thread
/// before tick is called.
pub fn focusedSurface(self: *const App) ?*Surface {
    const surface = self.focused_surface orelse return null;
    if (!self.hasSurface(surface)) return null;
    return surface;
}

/// Returns true if confirmation is needed to quit the app. It is up to
/// the apprt to call this.
pub fn needsConfirmQuit(self: *const App) bool {
    for (self.surfaces.items) |v| {
        if (v.core().needsConfirmQuit()) return true;
    }

    return false;
}

/// Drain the mailbox.
fn drainMailbox(self: *App, rt_app: *apprt.App) !void {
    while (self.mailbox.pop(global.io())) |message| {
        if (comptime std.log.logEnabled(.debug, .app)) {
            switch (message) {
                // these tend to be way too verbose for normal debugging
                .redraw_surface => {},
                else => log.debug("mailbox message={t}", .{message}),
            }
        }
        switch (message) {
            .open_config => |v| try self.performAction(
                rt_app,
                .{
                    .open_config = switch (v) {
                        .os_open => .os_open,
                        .new_window => .new_window,
                    },
                },
            ),
            .new_window => |msg| try self.newWindow(rt_app, msg),
            .close => |surface| self.closeSurface(surface),
            .surface_message => |msg| try self.surfaceMessage(msg.surface, msg.message),
            .poltergeist_report => |msg| self.poltergeistReport(msg.from, msg.event),
            .poltergeist_request => |p| self.poltergeistRequest(p),
            .redraw_surface => |surface| try self.redrawSurface(rt_app, surface),

            // If we're quitting, then we set the quit flag and stop
            // draining the mailbox immediately. This lets us defer
            // mailbox processing to the next tick so that the apprt
            // can try to quit as quickly as possible.
            .quit => {
                log.info("quit message received, short circuiting mailbox drain", .{});
                try self.performAction(rt_app, .quit);
                return;
            },
        }
    }
}

pub fn closeSurface(self: *App, surface: *Surface) void {
    if (!self.hasSurface(surface)) return;
    surface.close();
}

pub fn focusSurface(self: *App, surface: *Surface) void {
    if (!self.hasSurface(surface)) return;
    self.focused_surface = surface;
}

fn redrawSurface(
    self: *App,
    rt_app: *apprt.App,
    surface: *apprt.Surface,
) !void {
    if (!self.hasRtSurface(surface)) return;

    _ = try rt_app.performAction(
        .{ .surface = surface.core() },
        .render,
        {},
    );
}

/// Create a new window
pub fn newWindow(self: *App, rt_app: *apprt.App, msg: Message.NewWindow) !void {
    const target: apprt.Target = target: {
        const parent = msg.parent orelse break :target .app;
        if (self.hasSurface(parent)) break :target .{ .surface = parent };
        break :target .app;
    };

    _ = try rt_app.performAction(
        target,
        .new_window,
        {},
    );
}

/// Handle an app-level focus event. This should be called whenever
/// the focus state of the entire app containing Ghostty changes.
/// This is separate from surface focus events. See the `focused`
/// field for more information.
pub fn focusEvent(self: *App, focused: bool) void {
    // Prevent redundant focus events
    if (self.focused == focused) return;

    log.debug("focus event focused={}", .{focused});
    self.focused = focused;
}

/// Handle a key event at the app-scope. If this key event is used,
/// this will return true and the caller shouldn't continue processing
/// the event. If the event is not used, this will return false.
///
/// If the app currently has focus then all key events are processed.
/// If the app does not have focus then only global key events are
/// processed.
pub fn keyEvent(
    self: *App,
    rt_app: *apprt.App,
    event: input.KeyEvent,
) bool {
    switch (event.action) {
        // We don't care about key release events.
        .release => return false,

        // Continue processing key press events.
        .press, .repeat => {},
    }

    // Get the keybind entry for this event. We don't support key sequences
    // so we can look directly in the top-level set.
    const entry = rt_app.config.keybind.set.getEvent(event) orelse return false;
    const leaf: input.Binding.Set.GenericLeaf = switch (entry.value_ptr.*) {
        // Sequences aren't supported. Our configuration parser verifies
        // this for global keybinds but we may still get an entry for
        // a non-global keybind.
        .leader => return false,

        // Leaf entries are good
        inline .leaf, .leaf_chained => |leaf| leaf.generic(),
    };
    const actions: []const input.Binding.Action = leaf.actionsSlice();
    assert(actions.len > 0);

    // If we aren't focused, then we only process global keybinds.
    if (!self.focused and !leaf.flags.global) return false;

    // Global keybinds are done using performAll so that they
    // can target all surfaces too.
    if (leaf.flags.global) {
        self.performAllChainedAction(rt_app, actions);
        return true;
    }

    // Must be focused to process non-global keybinds
    assert(self.focused);
    assert(!leaf.flags.global);

    // If we are focused, then we process keybinds only if they are
    // app-scoped. Otherwise, we do nothing. Surface-scoped should
    // be processed by Surface.keyEvent. For chained actions, all
    // actions must be app-scoped.
    for (actions) |action| if (action.scoped(.app) == null) return false;
    for (actions) |action| {
        self.performAction(
            rt_app,
            action.scoped(.app).?,
        ) catch |err| {
            log.warn("error performing app keybind action action={s} err={}", .{
                @tagName(action),
                err,
            });
        };
    }

    return true;
}

/// Call to notify Ghostty that the color scheme for the app has changed.
/// "Color scheme" in this case refers to system themes such as "light/dark".
pub fn colorSchemeEvent(
    self: *App,
    rt_app: *apprt.App,
    scheme: apprt.ColorScheme,
) !void {
    const new_scheme: configpkg.ConditionalState.Theme = switch (scheme) {
        .light => .light,
        .dark => .dark,
    };

    // If our scheme didn't change, then we don't do anything.
    if (self.config_conditional_state.theme == new_scheme) return;

    // Setup our conditional state which has the current color theme.
    self.config_conditional_state.theme = new_scheme;

    // Request our configuration be reloaded because the new scheme may
    // impact the colors of the app.
    _ = try rt_app.performAction(
        .app,
        .reload_config,
        .{ .soft = true },
    );
}

/// Perform a binding action. This only accepts actions that are scoped
/// to the app. Callers can use performAllAction to perform any action
/// and any non-app-scoped actions will be performed on all surfaces.
pub fn performAction(
    self: *App,
    rt_app: *apprt.App,
    action: input.Binding.Action.Scoped(.app),
) !void {
    switch (action) {
        .unbind => unreachable,
        .ignore => {},
        .quit => _ = try rt_app.performAction(.app, .quit, {}),
        .new_window => _ = try self.newWindow(rt_app, .{ .parent = null }),
        .open_config => |v| _ = try rt_app.performAction(
            .app,
            .open_config,
            switch (v) {
                .os_open => .os_open,
                .new_window => .new_window,
            },
        ),
        .reload_config => _ = try rt_app.performAction(.app, .reload_config, .{}),
        .close_all_windows => _ = try rt_app.performAction(.app, .close_all_windows, {}),
        .toggle_quick_terminal => _ = try rt_app.performAction(.app, .toggle_quick_terminal, {}),
        .toggle_visibility => _ = try rt_app.performAction(.app, .toggle_visibility, {}),
        .check_for_updates => _ = try rt_app.performAction(.app, .check_for_updates, {}),
        .show_gtk_inspector => _ = try rt_app.performAction(.app, .show_gtk_inspector, {}),
        .undo => _ = try rt_app.performAction(.app, .undo, {}),

        .redo => _ = try rt_app.performAction(.app, .redo, {}),
    }
}

/// Performs a chained action. We will continue executing each action
/// even if there is a failure in a prior action.
pub fn performAllChainedAction(
    self: *App,
    rt_app: *apprt.App,
    actions: []const input.Binding.Action,
) void {
    for (actions) |action| {
        self.performAllAction(rt_app, action) catch |err| {
            log.warn("error performing chained action action={s} err={}", .{
                @tagName(action),
                err,
            });
        };
    }
}

/// Perform an app-wide binding action. If the action is surface-specific
/// then it will be performed on all surfaces. To perform only app-scoped
/// actions, use performAction.
pub fn performAllAction(
    self: *App,
    rt_app: *apprt.App,
    action: input.Binding.Action,
) !void {
    switch (action.scope()) {
        // App-scoped actions are handled by the app so that they aren't
        // repeated for each surface (since each surface forwards
        // app-scoped actions back up).
        .app => try self.performAction(
            rt_app,
            action.scoped(.app).?, // asserted through the scope match
        ),

        // Surface-scoped actions are performed on all surfaces. Errors
        // are logged but processing continues.
        .surface => for (self.surfaces.items) |surface| {
            _ = surface.core().performBindingAction(action) catch |err| {
                log.warn("error performing binding action on surface id={x} err={}", .{
                    surface.core().id,
                    err,
                });
            };
        },
    }
}

/// Handle a window message
fn surfaceMessage(self: *App, surface: *Surface, msg: apprt.surface.Message) !void {
    // We want to ensure our window is still active. Window messages
    // are quite rare and we normally don't have many windows so we do
    // a simple linear search here.
    if (self.hasSurface(surface)) {
        try surface.handleMessage(msg);
    }

    // Window was not found, it probably quit before we handled the message.
    // Not a problem.
}

fn hasSurface(self: *const App, surface: *const Surface) bool {
    for (self.surfaces.items) |v| {
        if (v.core() == surface) return true;
    }

    return false;
}

/// Search for a surface by a 64 bit unique ID.
pub fn findSurfaceByID(self: *const App, id: u64) ?*Surface {
    for (self.surfaces.items) |v| {
        const surface: *Surface = v.core();
        if (surface.id == id) return surface;
    }

    return null;
}

fn hasRtSurface(self: *const App, surface: *apprt.Surface) bool {
    for (self.surfaces.items) |v| {
        if (v == surface) return true;
    }

    return false;
}

/// The message types that can be sent to the app thread.
pub const Message = union(enum) {
    // Open the configuration file
    open_config: OpenConfig,

    /// Create a new terminal window.
    new_window: NewWindow,

    /// Close a surface. This notifies the runtime that a surface
    /// should close.
    close: *Surface,

    /// Quit
    quit: void,

    /// A message for a specific surface.
    surface_message: struct {
        surface: *Surface,
        message: apprt.surface.Message,
    },

    /// A surface reporting that its screen has gone quiet, or come back.
    ///
    /// Routed through the app rather than sent surface to surface because
    /// only the app knows who is supervising whom, and because the sending
    /// surface must not learn anything about the receiving one.
    poltergeist_report: struct {
        from: poltergeistpkg.Bus.Id,
        event: poltergeistpkg.Sampler.Event,
    },

    /// A request from an agent, waiting on its connection thread for an
    /// answer. Carrying the pointer is safe because that thread blocks
    /// until this is answered and the server answers any that are left
    /// when it shuts down.
    poltergeist_request: *poltergeistpkg.Server.Pending,

    /// Redraw a surface. This only has an effect for runtimes that
    /// use single-threaded draws. To redraw a surface for all runtimes,
    /// wake up the renderer thread. The renderer thread will send this
    /// message if it needs to.
    redraw_surface: *apprt.Surface,

    const NewWindow = struct {
        /// The parent surface
        parent: ?*Surface = null,
    };

    pub const OpenConfig = enum {
        /// Open the config in the OS default editor.
        os_open,
        /// Open the config in a new window using $EDITOR or $VISUAL
        new_window,
    };
};

/// Mailbox is the way that other threads send the app thread messages.
pub const Mailbox = struct {
    /// The type used for sending messages to the app thread.
    pub const Queue = BlockingQueue(Message, 64);

    rt_app: *apprt.App,
    mailbox: *Queue,

    /// Send a message to the surface.
    pub fn push(self: Mailbox, msg: Message, timeout: Queue.Timeout) Queue.Size {
        const result = self.mailbox.push(global.io(), msg, timeout);

        // Wake up our app loop
        self.rt_app.wakeup();

        return result;
    }
};

// Wasm API.
pub const Wasm = if (!builtin.target.isWasm()) struct {} else struct {
    const wasm = @import("os/wasm.zig");
    const alloc = wasm.alloc;

    // export fn app_new(config: *Config) ?*App {
    //     return app_new_(config) catch |err| { log.err("error initializing app err={}", .{err});
    //         return null;
    //     };
    // }
    //
    // fn app_new_(config: *Config) !*App {
    //     const app = try App.create(alloc, config);
    //     errdefer app.destroy();
    //
    //     const result = try alloc.create(App);
    //     result.* = app;
    //     return result;
    // }
    //
    // export fn app_free(ptr: ?*App) void {
    //     if (ptr) |v| {
    //         v.destroy();
    //         alloc.destroy(v);
    //     }
    // }
};
