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

/// Baseline for the monotonic clock the bus is given. Taken on the first
/// report rather than at startup so it costs nothing when unused.
poltergeist_epoch: ?std.Io.Timestamp = null,

/// The socket agents reach Poltergeist through. Null unless
/// `poltergeist-mcp` is on, so the default build opens nothing.
poltergeist_server: ?poltergeistpkg.Server = null,

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
        .chat = .init(alloc, .{}),
    };
}

pub fn deinit(self: *App) void {
    // Clean up all our surfaces
    for (self.surfaces.items) |surface| surface.deinit();
    self.surfaces.deinit(self.alloc);

    if (self.poltergeist_server) |*srv| srv.deinit();
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
    self.syncPoltergeistServer(config.@"poltergeist-mcp") catch |err| {
        log.warn("poltergeist: could not open the agent socket err={}", .{err});
    };

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
    const notice = self.poltergeist.report(from, event, self.poltergeistNow()) orelse
        return;

    const supervisor = self.findSurfaceByID(notice.to) orelse {
        // The supervisor's terminal went away between the report and here.
        self.poltergeist.unregister(notice.to);
        return;
    };

    var msg: apprt.surface.Message = .{ .poltergeist_notice = undefined };
    const line = poltergeistpkg.Bus.formatNotice(notice, &msg.poltergeist_notice) catch {
        log.warn("poltergeist: notice did not fit, dropping it", .{});
        return;
    };
    msg.poltergeist_notice[line.len] = 0;

    self.surfaceMessage(supervisor, msg) catch |err| {
        log.warn("poltergeist: could not deliver notice err={}", .{err});
    };
}

/// Open the agent socket if the config wants it and it is not open yet.
///
/// Called as a surface starts, because `updateConfig` runs only on a config
/// *reload* -- neither apprt calls it at launch. Without this a user who
/// set `poltergeist-mcp` in their config file would find no socket until
/// they reloaded by hand, which reads as the feature being broken.
pub fn ensurePoltergeistServer(self: *App, want: bool) void {
    if (!want or self.poltergeist_server != null) return;
    self.syncPoltergeistServer(true) catch |err| {
        log.warn("poltergeist: could not open the agent socket err={}", .{err});
    };
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
        .{ .subdir = "ghostty" },
    );
    defer self.alloc.free(state_dir);

    // Nothing else creates this on a fresh machine, and a missing
    // directory would make listen fail with a single warning that reads
    // like the feature is broken.
    std.Io.Dir.cwd().createDirPath(io, state_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

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
    }
}

/// Answer one agent request. Runs on the app thread, which is the only
/// thread that may touch the bus or a surface.
fn poltergeistRequest(self: *App, pending: *poltergeistpkg.Server.Pending) void {
    // The reference taken when this was handed over. Releasing it here is
    // what lets the connection thread's frame go away safely even if
    // shutdown answered the request before we got to it.
    defer pending.release();

    const response = poltergeistpkg.rpc.dispatch(
        pending.arena.allocator(),
        &self.poltergeist,
        self.poltergeistHost(),
        pending.caller,
        pending.request,
    ) catch |err| switch (err) {
        error.OutOfMemory => poltergeistpkg.wire.Response{ .failed = .{
            .code = "OutOfMemory",
            .message = "out of memory",
        } },
    };

    pending.complete(global.io(), response);
}

fn poltergeistHost(self: *App) poltergeistpkg.rpc.Host {
    return .{ .ctx = self, .vtable = &.{
        .readTerminal = poltergeistRead,
        .sendText = poltergeistSend,
        .quietMs = poltergeistQuiet,
        .setThreshold = poltergeistThreshold,
        .readSkill = poltergeistSkill,
        .chatCreate = chatCreate,
        .chatDestroy = chatDestroy,
        .chatAdd = chatAdd,
        .chatRemove = chatRemove,
        .chatCompact = chatCompact,
        .chatPost = chatPost,
        .chatGroups = chatGroups,
        .chatRead = chatRead,
    } };
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

fn poltergeistQuiet(ctx: *anyopaque, id: poltergeistpkg.Bus.Id) u64 {
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.poltergeist.quietMs(id, self.poltergeistNow());
}

fn chatCreate(ctx: *anyopaque, group: []const u8, by: poltergeistpkg.Bus.Id) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    try self.chat.create(group, by);

    // The person at the keyboard is in every group. These are
    // conversations happening on their machine; a window they could read
    // but not answer in would be a strange thing to build.
    try self.chat.add(group, poltergeistpkg.Chat.user_id, .all);
}

/// Everything the chat window needs, in one call.
///
/// Runs on the app thread, which owns the chat, so it reads directly. The
/// caller owns what comes back.
pub fn chatSnapshot(self: *App, alloc: Allocator) Allocator.Error!ChatSnapshot {
    const names = try self.chat.groupsFor(alloc, poltergeistpkg.Chat.user_id);
    defer alloc.free(names);

    var groups: std.ArrayListUnmanaged(ChatSnapshot.Group) = .empty;
    errdefer groups.deinit(alloc);

    for (names) |name| {
        const messages = self.chat.read(
            alloc,
            name,
            poltergeistpkg.Chat.user_id,
            0,
        ) catch continue;
        defer alloc.free(messages);

        const lines = try alloc.alloc(ChatSnapshot.Line, messages.len);
        for (messages, 0..) |m, i| lines[i] = .{
            .seq = m.seq,
            .from = m.from,
            .at_ms = m.at_ms,
            .summary = m.summary,
            .text = try alloc.dupeZ(u8, m.text),
        };

        try groups.append(alloc, .{
            .name = try alloc.dupeZ(u8, name),
            .lines = lines,
        });
    }

    return .{ .groups = try groups.toOwnedSlice(alloc) };
}

pub const ChatSnapshot = struct {
    groups: []const Group,

    pub const Group = struct {
        name: [:0]const u8,
        lines: []const Line,
    };

    pub const Line = struct {
        seq: u64,
        from: poltergeistpkg.Bus.Id,
        at_ms: u64,
        summary: bool,
        text: [:0]const u8,
    };

    pub fn deinit(self: ChatSnapshot, alloc: Allocator) void {
        for (self.groups) |g| {
            for (g.lines) |l| alloc.free(l.text);
            alloc.free(g.lines);
            alloc.free(g.name);
        }
        alloc.free(self.groups);
    }
};

/// Say something as the person at the keyboard.
pub fn chatPostAsUser(self: *App, group: []const u8, text: []const u8) !void {
    _ = try self.chat.post(
        group,
        poltergeistpkg.Chat.user_id,
        text,
        self.poltergeistNow(),
    );
    self.tellTerminalsAboutMessages();
}

fn chatDestroy(ctx: *anyopaque, group: []const u8) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    try self.chat.destroy(group);
}

fn chatAdd(
    ctx: *anyopaque,
    group: []const u8,
    id: poltergeistpkg.Bus.Id,
    history: poltergeistpkg.Chat.History,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    try self.chat.add(group, id, history);
}

fn chatRemove(
    ctx: *anyopaque,
    group: []const u8,
    id: poltergeistpkg.Bus.Id,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    try self.chat.remove(group, id);
}

fn chatCompact(
    ctx: *anyopaque,
    group: []const u8,
    through: u64,
    summary: []const u8,
    by: poltergeistpkg.Bus.Id,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    _ = try self.chat.compact(group, through, summary, by, self.poltergeistNow());
}

fn chatPost(
    ctx: *anyopaque,
    group: []const u8,
    from: poltergeistpkg.Bus.Id,
    text: []const u8,
) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx));
    _ = try self.chat.post(group, from, text, self.poltergeistNow());
    self.tellTerminalsAboutMessages();
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
            .from = m.from,
            .at_ms = m.at_ms,
            .summary = m.summary,
            .text = try alloc.dupe(u8, m.text),
        };
    }

    return out;
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

/// Monotonic milliseconds for the bus and the chat log alike.
fn poltergeistNow(self: *App) u64 {
    const epoch = self.poltergeist_epoch orelse epoch: {
        const t: std.Io.Timestamp = .now(global.io(), .awake);
        self.poltergeist_epoch = t;
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
            .{ .subdir = "ghostty" },
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
