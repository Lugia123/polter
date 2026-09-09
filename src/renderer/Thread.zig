//! Represents the renderer thread logic. The renderer thread is able to
//! be woken up to render.
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");
const xev = global.xev;
const crash = @import("../crash/main.zig");
const internal_os = @import("../os/main.zig");
const rendererpkg = @import("../renderer.zig");
const build_config = @import("../build_config.zig");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const terminalpkg = @import("../terminal/main.zig");
const BlockingQueue = @import("../datastruct/main.zig").BlockingQueue;
const Waker = @import("../datastruct/main.zig").Waker;
const App = @import("../App.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.renderer_thread);

const DRAW_INTERVAL = 8; // 120 FPS

/// One heartbeat line per this many wakeups (plus the very first). A pane
/// under ordinary output wakes a couple of times a second, so this is a line
/// every few seconds: dense enough to place a stall to within a handful of
/// wakeups, sparse enough not to become the log.
const heartbeat_interval = 8;
const CURSOR_BLINK_INTERVAL = 600;

/// Whether calls to `drawFrame` must be done from the app thread.
///
/// If this is `true` then we send a `redraw_surface` message to the apprt
/// whenever we need to draw instead of calling `drawFrame` directly.
const must_draw_from_app_thread =
    if (@hasDecl(apprt.App, "must_draw_from_app_thread"))
        apprt.App.must_draw_from_app_thread
    else
        false;

/// The type used for sending messages to the IO thread. For now this is
/// hardcoded with a capacity. We can make this a comptime parameter in
/// the future if we want it configurable.
pub const Mailbox = BlockingQueue(rendererpkg.Message, 64);

/// How long a caller will wait for room in the mailbox before giving up.
///
/// **Where the number comes from.** `CURSOR_BLINK_INTERVAL` above is 600ms,
/// and the cursor timer is what guarantees this thread wakes and drains even
/// when nothing else is happening -- so 600ms is the longest a healthy
/// renderer leaves the mailbox untouched. This is that with 1.67x of room.
///
/// **And where its ceiling comes from**: Windows marks a window "not
/// responding" after five seconds without the message pump answering. A
/// second is far enough under that a caller which does time out costs the
/// user one hitch, not a greyed-out title bar.
///
/// ⚠️ **One known exception, recorded rather than designed around**:
/// `cursorBlinkInterval()` returns `CURSOR_BLINK_INTERVAL * 5` under
/// Valgrind, where a second would be short enough to fire spuriously.
/// Valgrind is not a shipping path for this port.
pub const send_timeout_ns: u64 = 1000 * std.time.ns_per_ms;

/// A [`Waker`] for an async handle.
///
/// ⚠️ **The pointer has to be the handle the loop actually waits on.** On
/// Windows `xev.Async` keeps its waiter inside the struct, so a copy of it
/// notifies nothing -- that was task 508. Taking a pointer here rather than a
/// value makes the mistake unspellable at this end.
pub fn wakerFor(handle: *xev.Async) Waker {
    return .{ .ctx = handle, .func = &wakeAsync };
}

fn wakeAsync(ctx: *anyopaque) void {
    const handle: *xev.Async = @ptrCast(@alignCast(ctx));
    handle.notify() catch |err| {
        // Said out loud: a wake-up that failed leaves a producer waiting out
        // its whole timeout for no reason, and the timeout alone does not say
        // which of the two happened.
        log.warn("renderer wake-up failed err={}", .{err});
    };
}

/// Put a message in the renderer's mailbox and wake it up.
///
/// **The one way in, so that two rules hold by construction rather than by
/// everybody remembering them.**
///
///   1. **A caller never waits without a bound.** The UI thread reaches this
///      through half a dozen callbacks; a mailbox that only the renderer can
///      drain, waited on forever, is a deadlock whenever the renderer stops
///      for any reason at all -- and it stays one after the reason we know
///      about today is fixed.
///   2. **A delivery is always followed by a wake-up.** Pushing does not wake
///      anybody; a message that fits and is never announced sits there until
///      something else happens to wake the thread. Two call sites had exactly
///      that shape before this function existed.
///
/// ⚠️ **The order is the whole point and it is the opposite of the queue's
/// own.** Here the wake-up comes *after* a successful push, because its job
/// is to say "there is something new to read". The queue's internal one comes
/// *before* it waits, because its job is "make room for me". Swap either and
/// it stops doing its job while still looking like it is doing it.
///
/// Returns whether the message was delivered.
pub fn send(mailbox: *Mailbox, waker: Waker, msg: rendererpkg.Message) bool {
    if (mailbox.push(global.io(), msg, .{ .ns = send_timeout_ns }) == 0) {
        // absence: depends -- on whether the mailbox was ever made full.
        //
        // A healthy renderer drains this queue at least every 600ms, and a
        // push that finds it full wakes the renderer *before* it waits -- so
        // the round trip is milliseconds and **nobody ever reaches the whole
        // timeout**. This line therefore does not appear on a working
        // machine, and its silence on its own says nothing at all.
        //
        // 🔴 **It becomes a reading only next to two others.** With the
        // mailbox capacity lowered on purpose (see the setting of that name)
        // the queue does fill, and Termio's instant-drop line appears to
        // prove it did. *Then* the absence of this line means the wake-up is
        // connected and no caller waited out its bound -- which is the whole
        // claim this work makes. Without that other line first, "never
        // filled" and "handled correctly" are the same observation.
        //
        // ⚠️ **Worded so it cannot be confused with the other one.** Termio
        // already prints a full-mailbox line, and that one is an instant push
        // that gave up immediately. This one waited first. Two very different
        // facts -- "the queue was momentarily full" and "the renderer did not
        // drain for a whole second" -- and a reader grepping one phrase would
        // have got both.
        log.warn("[mbox] renderer mailbox STILL full after {d}ms; message dropped kind={s}", .{
            send_timeout_ns / std.time.ns_per_ms,
            @tagName(msg),
        });
        return false;
    }
    waker.wake();
    return true;
}

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The main event loop for the application. The user data of this loop
/// is always the allocator used to create the loop. This is a convenience
/// so that users of the loop always have an allocator.
loop: xev.Loop,

/// This can be used to wake up the renderer and force a render safely from
/// any thread.
/// Handle other threads use to wake this one.
///
/// ⚠️ **Hand out a pointer to this, never a copy.** `xev.Async` keeps its
/// state in different places depending on the backend: on an eventfd the
/// struct holds only the descriptor, so a copy still refers to the same
/// kernel object, but the IOCP implementation keeps everything in the struct
/// -- including the field `wait()` fills in with where to post. A copy taken
/// before `wait()` runs has nowhere to post for ever, and `notify()` on it
/// **returns success and wakes nobody**, on Windows only, in silence.
///
/// A copy of this handle was given to the terminal's IO side once. Output
/// arriving from the program could then not wake this thread at all; only
/// keyboard and mouse could, because those use this field directly. A pane
/// whose program wrote while nobody touched the window simply stopped
/// repainting, and caught up the moment the window was touched.
wakeup: xev.Async,
wakeup_c: xev.Completion = .{},

/// This can be used to stop the renderer on the next loop iteration.
stop: xev.Async,
stop_c: xev.Completion = .{},

/// The timer used for rendering
render_h: xev.Timer,
render_c: xev.Completion = .{},

/// The timer used for draw calls. Draw calls don't update from the
/// terminal state so they're much cheaper. They're used for animation
/// and are paused when the terminal is not focused.
draw_h: xev.Timer,
draw_c: xev.Completion = .{},
draw_active: bool = false,

/// This async is used to force a draw immediately. This does not
/// coalesce like the wakeup does.
draw_now: xev.Async,
draw_now_c: xev.Completion = .{},

/// The timer used for cursor blinking
cursor_h: xev.Timer,
cursor_c: xev.Completion = .{},
cursor_c_cancel: xev.Completion = .{},

/// Incremental scrollback compression scheduling.
compression: Compression = undefined,

/// The surface we're rendering to.
surface: *apprt.Surface,

/// The underlying renderer implementation.
renderer: *rendererpkg.Renderer,

/// Pointer to the shared state that is used to generate the final render.
state: *rendererpkg.State,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: *Mailbox,

/// How many times this thread has entered `wakeupCallback`, and how many of
/// those it came back out of.
///
/// **These exist to tell "alive but rendering nothing" apart from "stopped".**
/// Both look identical from outside -- the pane holds its last frame either
/// way -- and every other signal we have (the surface still answers, the
/// locks are still gettable, frames are still presented) is produced by other
/// threads and stays true in both. A wakeup count that keeps climbing says
/// the loop is running; a count that stops says it is not; and a final line
/// whose `wakeup` is one past its `completed` says where it stopped: inside
/// the callback, not waiting for one.
wakeups: u64 = 0,
wakeups_completed: u64 = 0,

/// How many redraw requests were lost to a full app mailbox. See the send
/// site in `drawFrame` for why losing one is not free.
app_mailbox_drops: u64 = 0,

/// Mailbox to send messages to the app thread
app_mailbox: App.Mailbox,

/// Configuration we need derived from the main config.
config: DerivedConfig,

flags: packed struct {
    /// This is true when a blinking cursor should be visible and false
    /// when it should not be visible. This is toggled on a timer by the
    /// thread automatically.
    cursor_blink_visible: bool = false,

    /// This is true when the inspector is active.
    has_inspector: bool = false,

    /// This is true when the view is visible. This is used to determine
    /// if we should be rendering or not.
    visible: bool = true,

    /// This is true when the view is focused. This defaults to true
    /// and it is up to the apprt to set the correct value.
    focused: bool = true,
} = .{},

pub const DerivedConfig = struct {
    custom_shader_animation: configpkg.CustomShaderAnimation,
    scrollback_compression: bool,

    pub fn init(config: *const configpkg.Config) DerivedConfig {
        return .{
            .custom_shader_animation = config.@"custom-shader-animation",
            .scrollback_compression = config.@"scrollback-compression",
        };
    }
};

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(
    alloc: Allocator,
    config: *const configpkg.Config,
    surface: *apprt.Surface,
    renderer_impl: *rendererpkg.Renderer,
    state: *rendererpkg.State,
    app_mailbox: App.Mailbox,
) !Thread {
    // Create our event loop.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    // This async handle is used to "wake up" the renderer and force a render.
    var wakeup_h = try xev.Async.init();
    errdefer wakeup_h.deinit();

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    // The primary timer for rendering.
    var render_h = try xev.Timer.init();
    errdefer render_h.deinit();

    // Draw timer, see comments.
    var draw_h = try xev.Timer.init();
    errdefer draw_h.deinit();

    // Draw now async, see comments.
    var draw_now = try xev.Async.init();
    errdefer draw_now.deinit();

    // Setup a timer for blinking the cursor
    var cursor_timer = try xev.Timer.init();
    errdefer cursor_timer.deinit();

    // The mailbox for messaging this thread
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    // **The deliberate ceiling, applied once, here.** Zero leaves the queue
    // comparing against its compile-time bound, which is what every build
    // that does not set it does.
    if (config.@"poltergeist-render-mailbox-capacity" > 0) {
        mailbox.capacity_limit = @intCast(@min(
            config.@"poltergeist-render-mailbox-capacity",
            64,
        ));
        log.warn(
            "renderer mailbox capacity lowered to {d} by configuration; " ++
                "messages to the renderer will be dropped once that many are unread",
            .{mailbox.capacity_limit},
        );
    }

    var result: Thread = .{
        .alloc = alloc,
        .config = .init(config),
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .render_h = render_h,
        .draw_h = draw_h,
        .draw_now = draw_now,
        .cursor_h = cursor_timer,
        .surface = surface,
        .renderer = renderer_impl,
        .state = state,
        .mailbox = mailbox,
        .app_mailbox = app_mailbox,
    };

    // Only enable compression if we have it enabled... save some
    // minor resources.
    if (comptime terminalpkg.compression_enabled) {
        result.compression = try .init();
    }

    return result;
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    self.stop.deinit();
    self.wakeup.deinit();
    self.render_h.deinit();
    self.draw_h.deinit();
    self.draw_now.deinit();
    self.cursor_h.deinit();
    if (comptime terminalpkg.compression_enabled)
        self.compression.deinit();
    self.loop.deinit();

    // Nothing can possibly access the mailbox anymore, destroy it.
    self.mailbox.destroy(self.alloc);
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread) void {
    // Call child function so we can use errors...
    self.threadMain_() catch |err| {
        // In the future, we should expose this on the thread struct.
        log.warn("error in renderer err={}", .{err});
    };
}

fn threadMain_(self: *Thread) !void {
    defer log.debug("renderer thread exited", .{});

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    if (builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"renderer".*);
    }

    // Setup our crash metadata
    crash.sentry.thread_state = .{
        .type = .renderer,
        .surface = self.renderer.surface_mailbox.surface,
    };
    defer crash.sentry.thread_state = null;

    // Setup our thread QoS
    self.setQosClass();

    // Run our loop start/end callbacks if the renderer cares.
    const has_loop = @hasDecl(rendererpkg.Renderer, "loopEnter");
    if (has_loop) try self.renderer.loopEnter(self);
    defer if (has_loop) self.renderer.loopExit();

    // Run our thread start/end callbacks. This is important because some
    // renderers have to do per-thread setup. For example, OpenGL has to set
    // some thread-local state since that is how it works.
    try self.renderer.threadEnter(self.surface);
    defer self.renderer.threadExit();

    // Start the async handlers
    // **Set here, not in `init`, and that is load-bearing twice over.**
    // `init` builds a `Thread` that is then copied into the surface, so a
    // waker made there would point at a struct nobody waits on. By this line
    // `self` is the copy the thread actually runs, and the handle below is
    // the one `wait` is about to fill in.
    self.mailbox.waker = wakerFor(&self.wakeup);
    self.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);
    self.draw_now.wait(&self.loop, &self.draw_now_c, Thread, self, drawNowCallback);

    // Send an initial wakeup message so that we render right away.
    try self.wakeup.notify();

    // Start blinking the cursor.
    self.cursor_h.run(
        &self.loop,
        &self.cursor_c,
        cursorBlinkInterval(),
        Thread,
        self,
        cursorTimerCallback,
    );

    // Start the draw timer
    self.syncDrawTimer();

    // Run
    log.debug("starting renderer thread", .{});
    defer log.debug("starting renderer thread shutdown", .{});
    _ = try self.loop.run(.until_done);
}

fn setQosClass(self: *const Thread) void {
    // Thread QoS classes are only relevant on macOS.
    if (comptime !builtin.target.os.tag.isDarwin()) return;

    const class: internal_os.macos.QosClass = class: {
        // If we aren't visible (our view is fully occluded) then we
        // always drop our rendering priority down because it's just
        // mostly wasted work.
        //
        // The renderer itself should be doing this as well (for example
        // Metal will stop our DisplayLink) but this also helps with
        // general forced updates and CPU usage i.e. a rebuild cells call.
        if (!self.flags.visible) break :class .utility;

        // If we're not focused, but we're visible, then we set a higher
        // than default priority because framerates still matter but it isn't
        // as important as when we're focused.
        if (!self.flags.focused) break :class .user_initiated;

        // We are focused and visible, we are the definition of user interactive.
        break :class .user_interactive;
    };

    if (internal_os.macos.setQosClass(class)) {
        log.debug("thread QoS class set class={}", .{class});
    } else |err| {
        log.warn("error setting QoS class err={}", .{err});
    }
}

fn syncDrawTimer(self: *Thread) void {
    skip: {
        // If our renderer supports animations and has them, then we
        // can apply draw timer based on custom shader animation configuration.
        if (@hasDecl(rendererpkg.Renderer, "hasAnimations") and
            self.renderer.hasAnimations())
        {
            // If our config says to always animate, we do so.
            switch (self.config.custom_shader_animation) {
                // Always animate
                .always => break :skip,
                // Only when focused
                .true => if (self.flags.focused) break :skip,
                // Never animate
                .false => {},
            }
        }

        // We're skipping the draw timer. Stop it on the next iteration.
        self.draw_active = false;
        return;
    }

    // Set our active state so it knows we're running. We set this before
    // even checking the active state in case we have a pending shutdown.
    self.draw_active = true;

    // If our draw timer is already active, then we don't have to do anything.
    if (self.draw_c.state() == .active) return;

    // Start the timer which loops
    self.draw_h.run(
        &self.loop,
        &self.draw_c,
        DRAW_INTERVAL,
        Thread,
        self,
        drawCallback,
    );
}

/// Drain the mailbox.
fn drainMailbox(self: *Thread) !void {
    // There's probably a more elegant way to do this...
    //
    // This is effectively an @autoreleasepool{} block, which we need in
    // order to ensure that autoreleased objects are properly released.
    const pool = if (builtin.os.tag.isDarwin())
        @import("objc").AutoreleasePool.init()
    else
        void;
    defer if (builtin.os.tag.isDarwin()) pool.deinit();

    while (self.mailbox.pop(global.io())) |message| {
        log.debug("mailbox message={}", .{message});
        switch (message) {
            .crash => @panic("crash request, crashing intentionally"),

            .visible => |v| visible: {
                // If our state didn't change we do nothing.
                if (self.flags.visible == v) break :visible;

                // Set our visible state
                self.flags.visible = v;

                // Visibility affects our QoS class
                self.setQosClass();

                // If we became visible then we immediately rebuild cells
                // (renderCallback skips updateFrame while invisible) and draw.
                if (v) {
                    self.renderer.updateFrame(
                        self.state,
                        self.flags.cursor_blink_visible,
                    ) catch |err|
                        log.warn("error rendering on visibility regain err={}", .{err});
                    self.drawFrame(false);
                }

                // Notify the renderer so it can update any state.
                self.renderer.setVisible(v);

                // Note that we're explicitly today not stopping any
                // cursor timers, draw timers, etc. These things have very
                // little resource cost and properly maintaining their active
                // state across different transitions is going to be bug-prone,
                // so its easier to just let them keep firing and have them
                // check the visible state themselves to control their behavior.
            },

            .focus => |v| focus: {
                // If our state didn't change we do nothing.
                if (self.flags.focused == v) break :focus;

                // Set our state
                self.flags.focused = v;

                // Focus affects our QoS class
                self.setQosClass();

                // Set it on the renderer
                try self.renderer.setFocus(v);

                // We always resync our draw timer (may disable it)
                self.syncDrawTimer();

                if (!v) {
                    // If we're not focused, then we stop the cursor blink
                    if (self.cursor_c.state() == .active and
                        self.cursor_c_cancel.state() == .dead)
                    {
                        self.cursor_h.cancel(
                            &self.loop,
                            &self.cursor_c,
                            &self.cursor_c_cancel,
                            void,
                            null,
                            cursorCancelCallback,
                        );
                    }
                } else {
                    // If we're focused, we immediately show the cursor again
                    // and then restart the timer.
                    if (self.cursor_c.state() != .active) {
                        self.flags.cursor_blink_visible = true;
                        self.cursor_h.run(
                            &self.loop,
                            &self.cursor_c,
                            cursorBlinkInterval(),
                            Thread,
                            self,
                            cursorTimerCallback,
                        );
                    }
                }
            },

            .reset_cursor_blink => {
                self.flags.cursor_blink_visible = true;
                if (self.cursor_c.state() == .active) {
                    self.cursor_h.reset(
                        &self.loop,
                        &self.cursor_c,
                        &self.cursor_c_cancel,
                        cursorBlinkInterval(),
                        Thread,
                        self,
                        cursorTimerCallback,
                    );
                }
            },

            .font_grid => |grid| {
                self.renderer.setFontGrid(grid.grid);
                grid.set.deref(grid.old_key);
            },

            .resize => |v| self.renderer.setScreenSize(v),

            .change_config => |config| {
                defer config.alloc.destroy(config.thread);
                defer config.alloc.destroy(config.impl);
                try self.changeConfig(config.thread);
                try self.renderer.changeConfig(config.impl);

                // Stop and start the draw timer to capture the new
                // hasAnimations value.
                self.syncDrawTimer();
            },

            .search_viewport_matches => |v| {
                // Note we don't free the new value because we expect our
                // allocators to match.
                if (self.renderer.search_matches) |*m| m.arena.deinit();
                self.renderer.search_matches = v;
                self.renderer.search_matches_dirty = true;
            },

            .search_selected_match => |v| {
                // Note we don't free the new value because we expect our
                // allocators to match.
                if (self.renderer.search_selected_match) |*m| m.arena.deinit();
                self.renderer.search_selected_match = v;
                self.renderer.search_matches_dirty = true;
            },

            .inspector => |v| {
                self.flags.has_inspector = v;
            },

            .macos_display_id => |v| {
                if (@hasDecl(rendererpkg.Renderer, "setMacOSDisplayID")) {
                    try self.renderer.setMacOSDisplayID(v, &self.draw_now);
                }
            },
        }
    }
}

fn changeConfig(self: *Thread, config: *const DerivedConfig) !void {
    // A newly enabled scheduler must reconsider existing history even when no
    // terminal activity occurred while compression was disabled.
    if (comptime terminalpkg.compression_enabled) {
        if (!self.config.scrollback_compression and
            config.scrollback_compression)
        {
            self.compression.activity = null;
        }
    }

    self.config = config.*;
}

/// Trigger a draw. This will not update frame data or anything, it will
/// just trigger a draw/paint.
fn drawFrame(self: *Thread, now: bool) void {
    // If we're invisible, we do not draw.
    if (!self.flags.visible) return;

    // If the renderer is managing a vsync on its own, we only draw
    // when we're forced to via `now`.
    if (!now and self.renderer.hasVsync()) return;

    if (must_draw_from_app_thread) {
        // **A lost redraw request is not free.** If the draw timer is idle
        // -- which it is unless a custom shader wants animation -- the next
        // frame is drawn only when something else wakes this thread. Losing
        // this one can therefore leave the pane holding a stale frame with
        // nothing scheduled to replace it, so at minimum it has to be
        // countable.
        if (self.app_mailbox.push(
            .{ .redraw_surface = self.surface },
            .{ .instant = {} },
        ) == 0) {
            self.app_mailbox_drops += 1;
            // absence: means it was not reached -- the first drop always speaks,
            // so no line at all means no message was ever dropped here. Only the
            // count of the later ones is sampled.
            //
            // This arm is compiled only where the app thread must draw, which
            // today is GTK alone; on Windows the branch above does not exist, so
            // silence here is also what a build without it looks like.
            if (rendererpkg.shouldReport(self.app_mailbox_drops, 64)) {
                log.warn(
                    "[mbox] app mailbox full, message dropped kind=redraw_surface drops={d}",
                    .{self.app_mailbox_drops},
                );
            }
        }
    } else {
        self.renderer.drawFrame(false) catch |err|
            log.warn("error drawing err={}", .{err});
    }
}

fn wakeupCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };

    const t = self_.?;

    // Heartbeat. Deliberately reported before the work rather than after, so
    // that a callback which never returns still leaves the line that says it
    // started: `wakeup` one ahead of `completed` is the signature of a
    // renderer thread stuck inside its own callback.
    t.wakeups += 1;

    // ⚠️ **The sampled line cannot catch the stall it was built for.** The
    // signature of a renderer thread stuck inside its callback is a *final*
    // line whose `wakeup` is one ahead of its `completed` -- but with a
    // sampling interval of `heartbeat_interval`, the wakeup that never
    // returns only prints its own line one time in `heartbeat_interval`. The
    // other times, the last line in the log belongs to an earlier wakeup
    // that did finish, so it reads `wakeup == completed` and looks perfectly
    // healthy. Against the default build the criterion is therefore not the
    // content of the last line but whether `wakeup` is still climbing; with
    // the phase log on, every wakeup reports and the final-line reading
    // works.
    // NOTE: no `comptime` keyword on this `if` -- it would force the whole
    // expression, including the runtime `shouldReport` call, to be evaluated
    // at comptime. The left operand is comptime-known on its own, which is
    // all that is needed for the switch to cost nothing when it is off.
    // absence: depends -- with the phase log off, one line per
    // `heartbeat_interval` wakeups, so the line stopping means the thread
    // stopped waking, but only after that many more would have happened;
    // and a stall beginning between two heartbeats leaves a last line whose
    // two counters agree, which is what a healthy one looks like. With the
    // log on, every wakeup speaks and absence is immediate. Either way the
    // reading is the counter advancing, not its last value -- see above.
    if (build_config.log_render_phase or
        rendererpkg.shouldReport(t.wakeups, heartbeat_interval))
    {
        log.info("[rthread] r={x} wakeup={d} completed={d}", .{
            @intFromPtr(t.renderer),
            t.wakeups,
            t.wakeups_completed,
        });
    }

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    t.drainMailbox() catch |err|
        log.err("error draining mailbox err={}", .{err});

    // Render immediately
    _ = renderCallback(t, undefined, undefined, {});

    // PageList mutations maintain their own compression dirty state. Checking
    // it here covers output, resize, and viewport scrolling uniformly.
    t.compression.wake(t);

    // The below is not used anymore but if we ever want to introduce
    // a configuration to introduce a delay to coalesce renders, we can
    // use this.
    //
    // // If the timer is already active then we don't have to do anything.
    // if (t.render_c.state() == .active) return .rearm;
    //
    // // Timer is not active, let's start it
    // t.render_h.run(
    //     &t.loop,
    //     &t.render_c,
    //     10,
    //     Thread,
    //     t,
    //     renderCallback,
    // );

    t.wakeups_completed += 1;
    return .rearm;
}

fn drawNowCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in draw now err={}", .{err});
        return .rearm;
    };

    // Draw immediately
    const t = self_.?;
    t.drawFrame(true);

    return .rearm;
}

fn drawCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    const t: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };

    // Draw
    t.drawFrame(false);

    // Only continue if we're still active
    if (t.draw_active) {
        t.draw_h.run(&t.loop, &t.draw_c, DRAW_INTERVAL, Thread, t, drawCallback);
    }

    return .disarm;
}

fn renderCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    const t: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };

    // If we're not visible there's no point spending CPU rebuilding cells —
    // we'll catch up when the .visible mailbox message flips us back on.
    if (!t.flags.visible) return .disarm;

    // Update our frame data
    t.renderer.updateFrame(
        t.state,
        t.flags.cursor_blink_visible,
    ) catch |err|
        log.warn("error rendering err={}", .{err});

    // Draw
    t.drawFrame(false);

    return .disarm;
}

fn cursorTimerCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        // This is sent when our timer is canceled. That's fine.
        error.Canceled => return .disarm,

        else => {
            log.warn("error in cursor timer callback err={}", .{err});
            unreachable;
        },
    };

    const t: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };

    t.flags.cursor_blink_visible = !t.flags.cursor_blink_visible;
    t.wakeup.notify() catch {};

    t.cursor_h.run(
        &t.loop,
        &t.cursor_c,
        cursorBlinkInterval(),
        Thread,
        t,
        cursorTimerCallback,
    );
    return .disarm;
}

fn cursorCancelCallback(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.CancelError!void,
) xev.CallbackAction {
    // This makes it easier to work across platforms where different platforms
    // support different sets of errors, so we just unify it.
    const CancelError = xev.Timer.CancelError || error{
        Canceled,
        NotFound,
        Unexpected,
    };

    _ = r catch |err| switch (@as(CancelError, @errorCast(err))) {
        error.Canceled => {}, // success
        error.NotFound => {}, // completed before it could cancel
        else => {
            log.warn("error in cursor cancel callback err={}", .{err});
            unreachable;
        },
    };

    return .disarm;
}

// fn prepFrameCallback(h: *libuv.Prepare) void {
//     _ = h;
//
//     tracy.frameMark();
// }

fn stopCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    self_.?.loop.stop();
    return .disarm;
}

/// Returns the interval for the blinking cursor in milliseconds.
fn cursorBlinkInterval() u64 {
    if (std.valgrind.runningOnValgrind() > 0) {
        // If we're running under Valgrind, the cursor blink adds enough
        // churn that it makes some stalls annoying unless you're on a
        // super powerful computer, so we delay it.
        //
        // This is a hack, we should change some of our cursor timer
        // logic to be more efficient:
        // https://github.com/ghostty-org/ghostty/issues/8003
        return CURSOR_BLINK_INTERVAL * 5;
    }

    return CURSOR_BLINK_INTERVAL;
}

/// Schedules incremental terminal compression after renderer activity stops.
///
/// This owns all renderer-specific compression state. The terminal decides
/// when compression-relevant activity changes and performs the actual work;
/// the renderer only provides idle scheduling and avoids waiting for the
/// terminal lock.
const Compression = struct {
    const idle_interval = 250;
    const step_interval = 1;

    timer: xev.Timer,
    completion: xev.Completion = .{},
    reset_completion: xev.Completion = .{},
    activity: ?u64 = null,

    fn init() !Compression {
        return .{ .timer = try xev.Timer.init() };
    }

    fn deinit(self: *Compression) void {
        self.timer.deinit();
    }

    /// Start or postpone compression after a renderer wake.
    fn wake(self: *Compression, thread: *Thread) void {
        // If we have no compression then don't do anything.
        if (comptime !terminalpkg.compression_enabled) return;
        if (!thread.config.scrollback_compression) return;

        // PageList activity, rather than a generic renderer wake, restarts the
        // idle interval. In particular, the inspector wakes the renderer every
        // frame without changing terminal contents and must not starve this
        // timer indefinitely.
        if (thread.state.mutex.tryLock()) {
            defer thread.state.mutex.unlock(global.io());
            const activity = thread.state.terminal.compressionActivity();
            if (self.activity == activity) return;
            self.activity = activity;
        } else if (self.completion.state() == .active) {
            // Contention doesn't prove that compression-relevant activity
            // changed. Keep an existing deadline so frequent inspector frames
            // cannot postpone compression forever. The timer rechecks both the
            // activity token and lock availability before doing any work.
            return;
        }

        // Contention may mean parsing is active. Scheduling is a harmless
        // false positive when no compression work is actually pending, but is
        // necessary when no timer is already active.
        self.schedule(thread, idle_interval);
    }

    /// Start the one-shot timer, or move its deadline if it is already active.
    fn schedule(self: *Compression, thread: *Thread, delay_ms: u64) void {
        self.timer.reset(
            &thread.loop,
            &self.completion,
            &self.reset_completion,
            delay_ms,
            Thread,
            thread,
            timerCallback,
        );
    }

    fn timerCallback(
        thread_: ?*Thread,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        _ = result catch |err| switch (err) {
            error.Canceled => return .disarm,
            else => {
                log.warn("error in compression timer err={}", .{err});
                return .disarm;
            },
        };

        const thread = thread_ orelse return .disarm;
        const self = &thread.compression;

        if (self.step(thread)) |delay| self.schedule(thread, delay);
        return .disarm;
    }

    /// Try one bounded step without waiting for the terminal lock. The return
    /// value is the delay before another attempt, or null when work is done.
    fn step(self: *Compression, thread: *Thread) ?u64 {
        if (!thread.config.scrollback_compression) return null;

        const state = thread.state;
        if (!state.mutex.tryLock()) return idle_interval;
        defer state.mutex.unlock(global.io());

        const activity = state.terminal.compressionActivity();
        if (self.activity != activity) {
            self.activity = activity;
            return idle_interval;
        }

        return switch (state.terminal.compress(.incremental)) {
            .pending => step_interval,
            .unsupported,
            .complete,
            => null,
        };
    }
};

test "a full mailbox does not hold its caller forever" {
    // ⚠️ **Red as an assertion, not as a hang.** The obvious way to write
    // this -- push on a full mailbox and see -- makes the failing case block
    // the test process, and a build that times out reads like broken CI
    // rather than like a failing check. So the push happens on a thread that
    // is detached rather than joined, and this thread asserts on a flag it
    // polls with a bound of its own.
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const q = try Mailbox.create(alloc);
    defer q.destroy(alloc);

    // Fill it to the brim.
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        try testing.expect(q.push(io, .{ .focus = true }, .{ .instant = {} }) != 0);
    }

    const Ctx = struct {
        q: *Mailbox,
        returned: std.atomic.Value(bool) = .init(false),
        delivered: bool = true,

        fn wakeNoop(_: *anyopaque) void {}

        fn run(self: *@This()) void {
            self.delivered = send(
                self.q,
                .{ .ctx = self, .func = &@This().wakeNoop },
                .{ .focus = false },
            );
            self.returned.store(true, .release);
        }
    };
    var ctx: Ctx = .{ .q = q };

    const th = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    // **Detached on purpose**: if `send` never returns, joining would hang
    // exactly the way this test exists to avoid.
    th.detach();

    // Generous against the bound `send` is supposed to honour, so that a slow
    // machine cannot fail this on timing alone.
    const deadline_ms: usize = 4_000;
    var waited: usize = 0;
    while (waited < deadline_ms and !ctx.returned.load(.acquire)) : (waited += 10) {
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    const returned_in_time = ctx.returned.load(.acquire);

    // **Let a still-blocked pusher finish before the queue goes away.**
    // Done whether or not the assertion below is going to fail: a detached
    // thread parked on a destroyed queue is a second, unrelated failure, and
    // it would land on whoever runs the suite next.
    _ = q.pop(io);
    var drain_wait: usize = 0;
    while (drain_wait < 1_000 and !ctx.returned.load(.acquire)) : (drain_wait += 10) {
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }

    try testing.expect(returned_in_time);
    try testing.expect(!ctx.delivered);
}

test "a delivered message wakes the renderer, and not before it is in the queue" {
    // ⚠️ **Found by mutation.** Deleting the wake-up after a successful
    // delivery left every other check green -- the queue's own tests are
    // about the *full* case, and the bounded-return test is about giving up.
    // Nothing was watching the ordinary path, which is the one that runs
    // every time.
    //
    // ⭐ **And the assertion is the ordering, not the presence.** The probe
    // records the queue's length at the moment it is called. Woken after the
    // push, that is one; woken before, it is zero -- which is exactly the
    // mistake of waking a consumer to look at something that is not there
    // yet, and then going back to sleep.
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const q = try Mailbox.create(alloc);
    defer q.destroy(alloc);

    const Probe = struct {
        q: *Mailbox,
        calls: usize = 0,
        len_at_call: usize = 999,

        fn wake(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            self.len_at_call = self.q.len;
        }
    };
    var probe: Probe = .{ .q = q };

    try testing.expect(send(q, .{ .ctx = &probe, .func = &Probe.wake }, .{ .focus = true }));
    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(@as(usize, 1), probe.len_at_call);

    _ = q.pop(io);
}

test "a lowered ceiling makes a delivery fail the way a real full mailbox would" {
    // ⚠️ **What this does and does not establish.** It shows that with the
    // ceiling on, `send` reaches the branch that gives up and reports -- the
    // branch whose only other way of being reached was the fault that has
    // since been fixed. It does **not** show that the line reaches a log
    // file on a real machine; that is a reading somebody has to take there,
    // and the criterion for that run is that the line appears at all.
    // **Without it, "the mailbox never filled" and "the switch did nothing"
    // are the same observation.**
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const q = try Mailbox.create(alloc);
    defer q.destroy(alloc);
    q.capacity_limit = 1;

    const Probe = struct {
        calls: usize = 0,
        fn wake(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
        }
    };
    var probe: Probe = .{};
    const w: Waker = .{ .ctx = &probe, .func = &Probe.wake };
    // ⚠️ **The queue needs its own waker, and it is not the same act as
    // handing one to `send`.** `start` installs this on the real mailbox; a
    // test that only passes a waker to `send` is exercising half the
    // mechanism and would read the other half's absence as working.
    q.waker = w;

    // One fits.
    try testing.expect(send(q, w, .{ .focus = true }));
    try testing.expectEqual(@as(usize, 1), probe.calls);

    // 🔴 **The second send goes on a detached thread, and that is not
    // caution -- it is the difference between this cell failing and this cell
    // hanging.** What it asserts is that `send` comes back; if it does not,
    // calling it here would park the test process for ever. A mutation that
    // puts the unbounded wait back did exactly that: three processes at 0%
    // CPU for ninety-three minutes, which reads as *progress* rather than as
    // a failure and is worse than either.
    //
    // ⭐ **The general form**: a test whose own termination depends on the
    // thing under test being correct cannot report that thing being wrong.
    const Runner = struct {
        q: *Mailbox,
        w: Waker,
        returned: std.atomic.Value(bool) = .init(false),
        delivered: bool = true,
        waited_ms: i64 = -1,

        fn run(self: *@This(), iio: std.Io) void {
            const began: std.Io.Timestamp = .now(iio, .awake);
            self.delivered = send(self.q, self.w, .{ .focus = false });
            self.waited_ms = began.durationTo(.now(iio, .awake)).toMilliseconds();
            self.returned.store(true, .release);
        }
    };
    var runner: Runner = .{ .q = q, .w = w };
    const th = try std.Thread.spawn(.{}, Runner.run, .{ &runner, io });
    th.detach();

    // Generously past the bound `send` must honour.
    var waited: usize = 0;
    while (waited < 4_000 and !runner.returned.load(.acquire)) : (waited += 10) {
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    const came_back = runner.returned.load(.acquire);

    // Release it before the queue goes away, whatever the verdict below.
    _ = q.pop(io);
    var drain: usize = 0;
    while (drain < 1_000 and !runner.returned.load(.acquire)) : (drain += 10) {
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }

    try testing.expect(came_back);
    try testing.expect(!runner.delivered);
    // It waited rather than failing instantly: the bound is real. Half of it,
    // so a loaded machine cannot fail this on timing alone -- the fact being
    // asserted is "it waited", not "it waited precisely".
    try testing.expect(runner.waited_ms >= @as(i64, @intCast(send_timeout_ns / std.time.ns_per_ms / 2)));
    // And it woke the consumer on the way in, which is the queue's own rule.
    try testing.expectEqual(@as(usize, 2), probe.calls);
}
