//! Represents the "writer" thread for terminal IO. The reader side is
//! handled by the Termio struct itself and dependent on the underlying
//! implementation (i.e. if its a pty, manual, etc.).
//!
//! The writer thread does handle writing bytes to the pty but also handles
//! different events such as starting synchronized output, changing some
//! modes (like linefeed), etc. The goal is to offload as much from the
//! reader thread as possible since it is the hot path in parsing VT
//! sequences and updating terminal state.
//!
//! This thread state can only be used by one thread at a time.
pub const Thread = @This();

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const builtin = @import("builtin");
const global = @import("../global.zig");
const xev = global.xev;
const crash = @import("../crash/main.zig");
const internal_os = @import("../os/main.zig");
const termio = @import("../termio.zig");
const renderer = @import("../renderer.zig");
const poltergeist = @import("../poltergeist/main.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.io_thread);

/// This stores the information that is coalesced.
const Coalesce = struct {
    /// The number of milliseconds to coalesce certain messages like resize for.
    /// Not all message types are coalesced.
    const min_ms = 25;

    resize: ?renderer.Size = null,
};

/// The number of milliseconds before we reset the synchronized output flag
/// if the running program hasn't already.
const sync_reset_ms = 1000;

/// How often Poltergeist samples the screen. A sample is one pass over the
/// visible rows hashing raw cell bytes, so this is cheap; the interval is
/// about how promptly we notice a terminal has gone still, not about cost.
const quiescence_sample_ms = 1000;

/// Poltergeist's sampling state. Grouped so that the whole feature is one
/// optional field on the thread and costs nothing when disabled.
const Quiescence = struct {
    timer: xev.Timer,
    c: xev.Completion = .{},
    watcher: poltergeist.Watcher,

    /// Whether sampling is currently wanted. Config reload flips this
    /// rather than tearing the sampler down, so that turning watching off
    /// and on again does not lose how long a terminal has been still.
    enabled: bool,

    /// Whether a timer completion is outstanding. Guards against arming
    /// twice, which would leave two callbacks sharing one completion.
    armed: bool = false,

    fn deinit(self: *Quiescence) void {
        self.timer.deinit();
        self.watcher.deinit();
    }
};

/// A threshold in milliseconds, never less than one sample interval.
///
/// The value arrives already in milliseconds: `Termio.DerivedConfig` does
/// the conversion from the configured nanoseconds. This only applies the
/// floor, because a threshold shorter than the gap between two samples
/// cannot mean anything -- there is no stillness to observe below the rate
/// at which we look.
///
/// It used to divide by `ns_per_ms` a second time, on the strength of its
/// own parameter being named `ns`. Every caller passes a `_ms` field, so a
/// 15s threshold became 15000/1000000 = 0 and got floored to one sample
/// interval; so did the repeat. Both settings silently collapsed to one
/// second, and a supervisor watching three terminals took three lines a
/// second. Unit tests never saw it: they build a `Sampler.Config` directly
/// and never make this trip.
fn quiescenceFloor(ms: u64) u64 {
    return @max(quiescence_sample_ms, ms);
}

/// The number of milliseconds between each movement during selection scrolling.
const selection_scroll_ms = 15;

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The main event loop for the thread. The user data of this loop
/// is always the allocator used to create the loop. This is a convenience
/// so that users of the loop always have an allocator.
loop: xev.Loop,

/// The completion to use for the wakeup async handle that is present
/// on the termio.Writer.
wakeup_c: xev.Completion = .{},

/// This can be used to stop the thread on the next loop iteration.
stop: xev.Async,
stop_c: xev.Completion = .{},

/// This is used for timer-based selection scrolling.
scroll: xev.Timer,
scroll_c: xev.Completion = .{},
scroll_active: bool = false,

/// This is used to coalesce resize events.
coalesce: xev.Timer,
coalesce_c: xev.Completion = .{},
coalesce_cancel_c: xev.Completion = .{},
coalesce_data: Coalesce = .{},

/// This timer is used to reset synchronized output modes so that
/// the terminal doesn't freeze with a bad actor.
sync_reset: xev.Timer,
sync_reset_c: xev.Completion = .{},
sync_reset_cancel_c: xev.Completion = .{},

/// Holds the mailbox drain for a `write_delay` message.
///
/// **A pause, not a sleep.** Sleeping in the drain would stop this
/// terminal's whole event loop -- the process watcher, the termios timer and
/// Poltergeist's sampler all live on it -- for as long as the gap lasts.
/// Pausing the drain instead leaves the loop free and costs only what the
/// gap is for: the messages queued behind it wait.
write_delay: xev.Timer,
write_delay_c: xev.Completion = .{},

/// True from the moment a `write_delay` is taken until its timer fires.
/// While it is set, `drainMailbox` returns without popping anything, so a
/// wakeup arriving during the gap does not step over it.
write_delay_active: bool = false,

/// Poltergeist's quiescence sampler. This lives on the IO thread rather
/// than the renderer thread on purpose: the renderer stops rebuilding
/// frames entirely while a surface is not visible (see the visibility
/// check in `renderer/Thread.zig`), and watching a terminal that has been
/// left running in a background window overnight is the main thing
/// Poltergeist exists to do. This thread runs regardless of visibility.
///
/// Null when Poltergeist is disabled, which is the default.
quiescence: ?Quiescence = null,

/// What a supervisor or the keybind last asked of this terminal's sampling
/// (`poltergeist_watch`), when anything has. Null means nobody has, and the
/// configured `poltergeist-watch` decides. Kept apart from the config
/// because a reload replaces the config: read from there, a reload undid
/// every watch -- `poltergeist-watch` defaults to off, so it stopped the
/// sampling of every terminal a supervisor was minding without a word, and
/// with it on it restarted the sampling of every one it had let go (task
/// 550). See `wantsSampling`.
quiescence_asked: ?bool = null,

/// Baseline for the monotonic millisecond clock handed to the sampler.
/// Taken once when sampling starts so the numbers are small and monotonic.
quiescence_epoch: std.Io.Timestamp = undefined,

flags: packed struct {
    /// This is set to true only when an abnormal exit is detected. It
    /// tells our mailbox system to drain and ignore all messages.
    drain: bool = false,

    /// True if linefeed mode is enabled. This is duplicated here so that the
    /// write thread doesn't need to grab a lock to check this on every write.
    linefeed_mode: bool = false,

    /// This is true when the inspector is active.
    has_inspector: bool = false,
} = .{},

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(
    alloc: Allocator,
) !Thread {
    // Create our event loop.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    // This timer is used for selection scrolling.
    var scroll_h = try xev.Timer.init();
    errdefer scroll_h.deinit();

    // This timer is used to coalesce resize events.
    var coalesce_h = try xev.Timer.init();
    errdefer coalesce_h.deinit();

    // This timer is used to reset synchronized output modes.
    var sync_reset_h = try xev.Timer.init();
    errdefer sync_reset_h.deinit();

    // This timer holds the drain for a `write_delay` message.
    var write_delay_h = try xev.Timer.init();
    errdefer write_delay_h.deinit();

    return Thread{
        .alloc = alloc,
        .loop = loop,
        .stop = stop_h,
        .scroll = scroll_h,
        .coalesce = coalesce_h,
        .sync_reset = sync_reset_h,
        .write_delay = write_delay_h,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    if (self.quiescence) |*q| q.deinit();
    self.scroll.deinit();
    self.coalesce.deinit();
    self.sync_reset.deinit();
    self.write_delay.deinit();
    self.stop.deinit();
    self.loop.deinit();
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread, io: *termio.Termio) void {
    // Call child function so we can use errors...
    self.threadMain_(io) catch |err| {
        log.warn("error in io thread err={}", .{err});

        // Use an arena to simplify memory management below
        var arena = ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        // If there is an error, we replace our terminal screen with
        // the error message. It might be better in the future to send
        // the error to the surface thread and let the apprt deal with it
        // in some way but this works for now. Without this, the user would
        // just see a blank terminal window.
        io.renderer_state.mutex.lockUncancelable(global.io());
        defer io.renderer_state.mutex.unlock(global.io());
        const t = io.renderer_state.terminal;

        // Hide the cursor
        t.modes.set(.cursor_visible, false);

        // This is weird but just ensures that no matter what our underlying
        // implementation we have the errors below. For example, Windows doesn't
        // have "OpenptyFailed".
        const Err = @TypeOf(err) || error{
            OpenptyFailed,
            InputNotFound,
            InputFailed,
            // Named by `Command.spawnError` on Windows. Listed here for the
            // same reason the three above are: this switch has to be able to
            // mention them on every target, or the arm that says something
            // useful would only compile on one.
            FileNotFound,
            AccessDenied,
            InvalidExe,
            IsDir,
            BadPathName,
            SystemResources,
        };

        // The command that would not start, when there is one to name.
        //
        // **A message that says what failed is worth more than one that
        // guesses why.** "polter: not found" is a sentence somebody can act
        // on; "usually due to exhausting a system resource" is one they can
        // only obey, and it sends them to the wrong place.
        const cmd: ?[]const u8 = switch (io.backend) {
            .exec => |*exec| if (exec.subprocess.args.len > 0)
                exec.subprocess.args[0]
            else
                null,
        };

        switch (@as(Err, @errorCast(err))) {
            error.OpenptyFailed => {
                const str =
                    \\Your system cannot allocate any more pty devices.
                    \\
                    \\Ghostty requires a pty device to launch a new terminal.
                    \\This error is usually due to having too many terminal
                    \\windows open or having another program that is using too
                    \\many pty devices.
                    \\
                    \\Please free up some pty devices and try again.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },

            error.InputNotFound,
            error.InputFailed,
            => {
                const str =
                    \\A configured `input` path was not found, was not readable,
                    \\was too large, or the underlying pty failed to accept
                    \\the write.
                    \\
                    \\Ghostty can't continue since it can't guarantee that
                    \\initial terminal state will be as desired. Please review
                    \\the value of `input` in your configuration file and
                    \\ensure that all the path values exist and are readable.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },

            // The command is not where the search looked. On Windows that
            // means it is not in the application's directory, the working
            // directory, the system directories or `PATH`; on POSIX, not on
            // `PATH`. **This is the arm that used to fall through and be
            // reported as a resource shortage**, which sent people to close
            // programs and check memory for a command that was simply not
            // installed or not on the path.
            error.FileNotFound => {
                const str = std.fmt.allocPrint(
                    alloc,
                    \\Could not start `{s}`: no such command.
                    \\
                    \\The program was not found in any of the places the system
                    \\looks, which includes the directories on PATH. Nothing is
                    \\wrong with this computer's memory or resources.
                    \\
                    \\Check that the program is installed and that its directory
                    \\is on PATH, or give its full path instead.
                    \\
                    \\This terminal is non-functional. Please close it and try again.
                ,
                    .{cmd orelse "the configured command"},
                ) catch
                    \\Out of memory. This terminal is non-functional. Please close it and try again.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },

            error.AccessDenied, error.IsDir, error.InvalidExe, error.BadPathName => {
                const str = std.fmt.allocPrint(
                    alloc,
                    \\Could not start `{s}`: {t}
                    \\
                    \\The command was found but could not be run: it may not be
                    \\executable by this user, may be a directory, or may not be
                    \\a program this system can run.
                    \\
                    \\This terminal is non-functional. Please close it and try again.
                ,
                    .{ cmd orelse "the configured command", err },
                ) catch
                    \\Out of memory. This terminal is non-functional. Please close it and try again.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },

            // **The only arm allowed to say "system resource"**, and it says
            // it because something below actually reported one -- out of
            // memory, out of handles. The sentence used to be in the
            // catch-all, where it was said about every failure and was true
            // of almost none.
            error.SystemResources => {
                const str =
                    \\Your system is out of a resource this terminal needs
                    \\(memory, handles, or processes).
                    \\
                    \\Closing some windows or programs and trying again is the
                    \\usual remedy.
                    \\
                    \\This terminal is non-functional. Please close it and try again.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },

            // **Says what happened and stops.** The sentence that used to be
            // here -- "this error is usually due to exhausting a system
            // resource" -- was a guess printed as a finding, for every
            // startup failure this switch had not enumerated, on every
            // platform. It was wrong in the one case anybody hit, and being
            // wrong sent people to look somewhere there was nothing to find.
            // If a cause belongs on the screen it belongs in an arm above,
            // where something has actually established it.
            else => {
                const str = std.fmt.allocPrint(
                    alloc,
                    \\Could not start `{s}`: {t}
                    \\
                    \\That is what the system reported; this terminal has nothing
                    \\further to add about why. If it looks like a bug, please
                    \\report it with the error above.
                    \\
                    \\This terminal is non-functional. Please close it and try again.
                ,
                    .{ cmd orelse "the configured command", err },
                ) catch
                    \\Out of memory. This terminal is non-functional. Please close it and try again.
                ;

                t.eraseDisplay(.complete, false);
                t.printString(str) catch {};
            },
        }
    };

    // If our loop is not stopped, then we need to keep running so that
    // messages are drained and we can wait for the surface to send a stop
    // message.
    if (!self.loop.stopped()) {
        log.warn("abrupt io thread exit detected, starting xev to drain mailbox", .{});
        defer log.debug("io thread fully exiting after abnormal failure", .{});
        self.flags.drain = true;
        self.loop.run(.until_done) catch |err| {
            log.err("failed to start xev loop for draining err={}", .{err});
        };
    }
}

fn threadMain_(self: *Thread, io: *termio.Termio) !void {
    defer log.debug("IO thread exited", .{});

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    if (builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"io".*);
    }

    // Setup our crash metadata
    crash.sentry.thread_state = .{
        .type = .io,
        .surface = io.surface_mailbox.surface,
    };
    defer crash.sentry.thread_state = null;

    // Get the mailbox. This must be an SPSC mailbox for threading.
    const mailbox = switch (io.mailbox) {
        .spsc => |*v| v,
        // else => return error.TermioUnsupportedMailbox,
    };

    // This is the data sent to xev callbacks. We want a pointer to both
    // ourselves and the thread data so we can thread that through (pun intended).
    var cb: CallbackData = .{ .self = self, .io = io };

    // Run our thread start/end callbacks. This allows the implementation
    // to hook into the event loop as needed. The thread data is created
    // on the stack here so that it has a stable pointer throughout the
    // lifetime of the thread.
    try io.threadEnter(self, &cb.data);
    defer cb.data.deinit();
    defer io.threadExit(&cb.data);

    // Start the async handlers.
    mailbox.wakeup.wait(&self.loop, &self.wakeup_c, CallbackData, &cb, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, CallbackData, &cb, stopCallback);

    // Start Poltergeist's quiescence sampling if this surface is watched.
    // Failing to set it up must never take the terminal down with it: a
    // monitoring feature is not worth a dead pty.
    if (io.config.poltergeist_watch) {
        self.startQuiescence(io, &cb) catch |err| {
            log.warn("poltergeist: could not start quiescence sampling err={}", .{err});
        };
    }

    // Run
    log.debug("starting IO thread", .{});
    defer log.debug("starting IO thread shutdown", .{});
    try self.loop.run(.until_done);
}

/// This is the data passed to xev callbacks on the thread.
const CallbackData = struct {
    self: *Thread,
    io: *termio.Termio,
    data: termio.Termio.ThreadData = undefined,
};

/// Drain the mailbox, handling all the messages in our terminal implementation.
fn drainMailbox(
    self: *Thread,
    cb: *CallbackData,
) !void {
    // We assert when starting the thread that this is the state
    const mailbox = cb.io.mailbox.spsc.queue;
    const io = cb.io;
    const data = &cb.data;

    // If we're draining, we just drain the mailbox and return.
    //
    // ⚠️ **Draining discards, and a discarded request is one nobody is
    // told was refused.** A watch is the one that matters: dropped here it
    // left the bus marking a terminal watched with nothing sampling it, and
    // no trace of it anywhere (task 731). So it is answered on the way out.
    // Any request added to `termio.Message` whose sender waits on an
    // answer has the same shape.
    if (self.flags.drain) {
        while (mailbox.pop(global.io())) |msg| {
            switch (msg) {
                .poltergeist_watch => |want| if (want) answerSampling(cb.io, false),
                else => {},
            }
            msg.deinit();
        }
        return;
    }

    // A gap is running. Everything still queued belongs behind it -- the
    // return that submits a `terminal_send` is the message this exists for
    // -- so we pop nothing and let the timer call us back.
    if (self.write_delay_active) return;

    // This holds the mailbox lock for the duration of the drain. The
    // expectation is that all our message handlers will be non-blocking
    // ENOUGH to not mess up throughput on producers.
    var redraw: bool = false;
    while (mailbox.pop(global.io())) |message| {
        // If we have a message we always redraw
        redraw = true;

        log.debug("mailbox message={s}", .{@tagName(message)});
        switch (message) {
            .color_scheme_report => |v| try io.colorSchemeReport(data, v.force),
            .visibility_report => |v| try io.visibilityReport(
                data,
                v.visible,
                v.force,
            ),
            .crash => @panic("crash request, crashing intentionally"),
            .change_config => |config| {
                defer config.alloc.destroy(config.ptr);
                try io.changeConfig(data, config.ptr);

                // Reach terminals that are already open, not just new ones:
                // turning `poltergeist-watch` on or off, or changing a
                // threshold, has to apply here or the setting looks broken.
                self.syncQuiescence(io, cb);
            },
            .poltergeist_watch => |v| self.setQuiescenceWatch(io, cb, v),
            .poltergeist_threshold => |ms| {
                // **Built from `samplerConfig`, not beside it.** This used to
                // list the fields again, and a second list of the same
                // fields is how one of them goes missing: a field added for
                // new terminals would simply not reach a terminal whose
                // threshold was changed at runtime, and nothing would say
                // so. The only field this site knows better is the one the
                // message carries.
                if (self.quiescence) |*q| {
                    var config = samplerConfig(io);
                    config.quiescence_ms = quiescenceFloor(ms);
                    q.watcher.setConfig(config);
                }
            },
            .inspector => |v| self.flags.has_inspector = v,
            .resize => |v| self.handleResize(cb, v),
            .size_report => |v| try io.sizeReport(data, v),
            .clear_screen => |v| try io.clearScreen(data, v.history),
            .scroll_viewport => |v| io.scrollViewport(v),
            .selection_scroll => |v| {
                if (v) {
                    self.startScrollTimer(cb);
                } else {
                    self.stopScrollTimer();
                }
            },
            .jump_to_prompt => |v| try io.jumpToPrompt(v),
            .start_synchronized_output => self.startSynchronizedOutput(cb),
            .linefeed_mode => |v| self.flags.linefeed_mode = v,
            .focused => |v| try io.focusGained(data, v),
            .write_delay => |ms| {
                // Stop draining here. `write_delay_active` keeps a wakeup
                // from stepping over the gap, and the callback resumes from
                // exactly this point -- the queue is where the remaining
                // messages have been all along.
                self.write_delay_active = true;
                self.write_delay.run(
                    &self.loop,
                    &self.write_delay_c,
                    ms,
                    CallbackData,
                    cb,
                    writeDelayCallback,
                );

                // The messages already handled in this pass are worth a
                // frame, and the gap is long enough that waiting for the
                // rest would be visible.
                if (redraw) try io.renderer_wakeup.notify();
                return;
            },
            .write_small => |v| try io.queueWrite(
                data,
                v.data[0..v.len],
                self.flags.linefeed_mode,
            ),
            .write_stable => |v| try io.queueWrite(
                data,
                v,
                self.flags.linefeed_mode,
            ),
            .write_alloc => |v| {
                defer v.alloc.free(v.data);
                try io.queueWrite(
                    data,
                    v.data,
                    self.flags.linefeed_mode,
                );
            },
        }
    }

    // Trigger a redraw after we've drained so we don't waste cyces
    // messaging a redraw.
    if (redraw) {
        try io.renderer_wakeup.notify();
    }
}

fn startSynchronizedOutput(self: *Thread, cb: *CallbackData) void {
    self.sync_reset.reset(
        &self.loop,
        &self.sync_reset_c,
        &self.sync_reset_cancel_c,
        sync_reset_ms,
        CallbackData,
        cb,
        syncResetCallback,
    );
}

fn handleResize(self: *Thread, cb: *CallbackData, resize: renderer.Size) void {
    self.coalesce_data.resize = resize;

    // If the timer is already active we just return. In the future we want
    // to reset the timer up to a maximum wait time but for now this ensures
    // relatively smooth resizing.
    if (self.coalesce_c.state() == .active) return;

    self.coalesce.reset(
        &self.loop,
        &self.coalesce_c,
        &self.coalesce_cancel_c,
        Coalesce.min_ms,
        CallbackData,
        cb,
        coalesceCallback,
    );
}

/// Set up and arm Poltergeist's quiescence sampling.
fn startQuiescence(
    self: *Thread,
    io: *termio.Termio,
    cb: *CallbackData,
) !void {
    assert(self.quiescence == null);

    var timer = try xev.Timer.init();
    errdefer timer.deinit();

    self.quiescence = .{
        .timer = timer,
        .enabled = true,
        .watcher = .init(self.alloc, samplerConfig(io)),
    };
    self.quiescence_epoch = .now(global.io(), .awake);

    log.info("poltergeist: watching for quiescence after {d}ms", .{
        samplerConfig(io).quiescence_ms,
    });

    self.armQuiescence(cb);
}

fn samplerConfig(io: *termio.Termio) poltergeist.Sampler.Config {
    return .{
        .quiescence_ms = quiescenceFloor(io.config.poltergeist_quiescence_ms),
        .repeat_ms = quiescenceFloor(io.config.poltergeist_repeat_ms),

        // **How often we intend to tick, told rather than inferred.** The
        // sampler uses it to tell a late tick from a window nothing ran in
        // at all -- a closed lid, most of all. It cannot work this out for
        // itself: every interval it could measure has already happened, so
        // it would learn the sleep gap as normal and stop noticing.
        .sample_interval_ms = quiescence_sample_ms,
    };
}

/// Turn sampling on or off for this terminal at runtime, independently of
/// the config. This is what the `poltergeist_toggle_watch` keybind reaches.
fn setQuiescenceWatch(
    self: *Thread,
    io: *termio.Termio,
    cb: *CallbackData,
    want: bool,
) void {
    self.quiescence_asked = want;
    const q = if (self.quiescence) |*p| p else {
        if (!want) return;
        self.startQuiescence(io, cb) catch |err| {
            log.warn("poltergeist: could not start quiescence sampling err={}", .{err});
            answerSampling(io, false);
            return;
        };
        answerSampling(io, true);
        return;
    };

    // Answered even when nothing changes: the watch that asked has just
    // been marked unconfirmed (`Bus.watch`), and saying nothing would
    // leave it that way until the next heartbeat.
    if (want) answerSampling(io, true);

    if (q.enabled == want) return;
    q.enabled = want;
    if (want) self.armQuiescence(cb);
    log.info("poltergeist: sampling {s}", .{if (want) "on" else "off"});
}

/// Tell the app whether the sampling it asked for is running (task 731).
///
/// Instant, like every other message this thread sends the app. One lost
/// to a full mailbox leaves the watch reading `starting` -- unconfirmed --
/// and the first heartbeat corrects it; it never reads as running when it
/// is not (`Bus.Sampling`).
fn answerSampling(io: *termio.Termio, started: bool) void {
    // Dropped when the mailbox is full, and the loss is one the bus can
    // carry: the watch stays `starting`, which is unconfirmed rather than
    // wrong -- a running sampler's heartbeat confirms it, and a failed one
    // is never read as running.
    _ = io.surface_mailbox.app.push(.{
        .poltergeist_sampling = .{
            .from = io.surface_mailbox.surface.id,
            .started = started,
        },
    }, .{ .instant = {} });
}

/// Whether a terminal should be sampled: what was last asked of this one,
/// and the configured default only when nothing has been. The config is
/// the default for terminals nobody has said anything about -- not an
/// order that overrides the ones somebody has.
fn wantsSampling(configured: bool, asked: ?bool) bool {
    return asked orelse configured;
}

/// Bring sampling in line with the current config. Called after a config
/// reload so that turning `poltergeist-watch` on or off, or changing a
/// threshold, reaches terminals that are already open rather than only new
/// ones.
fn syncQuiescence(self: *Thread, io: *termio.Termio, cb: *CallbackData) void {
    const want = wantsSampling(io.config.poltergeist_watch, self.quiescence_asked);

    const q = if (self.quiescence) |*p| p else {
        if (!want) return;
        self.startQuiescence(io, cb) catch |err| {
            log.warn("poltergeist: could not start quiescence sampling err={}", .{err});
        };
        return;
    };

    q.watcher.setConfig(samplerConfig(io));

    if (q.enabled == want) return;
    q.enabled = want;

    if (want) {
        log.info("poltergeist: watching resumed by config reload", .{});
        self.armQuiescence(cb);
    } else {
        // Left to lapse rather than cancelled: an outstanding completion
        // fires at most once more, sees `enabled` false, and stops there.
        log.info("poltergeist: watching stopped by config reload", .{});
    }
}

fn armQuiescence(self: *Thread, cb: *CallbackData) void {
    // `if (opt) |*p|` rather than `&(opt orelse ...)`: the completion we
    // hand the loop must point at the field itself, and this form says so
    // without leaning on result-location semantics to get there.
    const q = if (self.quiescence) |*p| p else return;
    if (!q.enabled or q.armed) return;
    q.armed = true;
    q.timer.run(
        &self.loop,
        &q.c,
        quiescence_sample_ms,
        CallbackData,
        cb,
        quiescenceCallback,
    );
}

fn quiescenceCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => return .disarm,
        else => {
            log.warn("poltergeist: sample timer error err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;

    if (cb.self.quiescence) |*q| {
        q.armed = false;
        // Config reload may have turned watching off while this completion
        // was outstanding. Stop here rather than sampling one last time.
        if (!q.enabled) return .disarm;
    }

    cb.self.sampleQuiescence(cb.io);

    // Re-arm by hand, the way the selection scroll timer does, rather than
    // returning `.rearm`: the interval is fixed and this keeps the arming in
    // one place.
    cb.self.armQuiescence(cb);
    return .disarm;
}

/// Take one quiescence sample. Never blocks and never fails loudly: this is
/// a passive observer and must not be able to disturb the terminal.
fn sampleQuiescence(self: *Thread, io: *termio.Termio) void {
    const q = if (self.quiescence) |*p| p else return;

    const now: std.Io.Timestamp = .now(global.io(), .awake);
    const now_ms: u64 = @intCast(std.math.clamp(
        self.quiescence_epoch.durationTo(now).toMilliseconds(),
        0,
        std.math.maxInt(i64),
    ));

    // Never wait on the terminal lock: a monitoring feature has no business
    // adding contention to the parse hot path.
    //
    // But a skipped sample is not a quiet sample. Under sustained output
    // the parse loop holds this lock almost continuously, so failing to
    // take it is exactly what a busy terminal looks like from here. If we
    // just returned, a screen that changed and changed back across a run of
    // skipped ticks would later be reported as having been still the whole
    // time. Hand the gap to the sampler as activity instead.
    if (!io.renderer_state.mutex.tryLock()) {
        if (q.watcher.noteMissedSample(now_ms)) |event| self.reportQuiescence(io, event);
        self.noteQuiescence(io, now_ms);
        return;
    }
    defer io.renderer_state.mutex.unlock(global.io());

    // Drain the reader thread's byte counter into this sample.
    q.watcher.noteBytes(io.poltergeist_bytes.swap(0, .monotonic));

    // The active screen, so that a program on the alternate screen (a TUI,
    // which is exactly what an agent CLI is) is what gets watched.
    const event = poltergeist.screen.sample(
        &q.watcher,
        io.renderer_state.terminal.screens.active,
        now_ms,
    ) catch |err| {
        log.warn("poltergeist: sample failed err={}", .{err});
        return;
    };

    if (event) |e| self.reportQuiescence(io, e);

    // Unconditionally, and after the event rather than instead of it: the
    // ticks that say nothing are exactly the ones the supervisor's figure
    // is extrapolated across, and a screen that is moving produces nothing
    // but those. `heartbeat` decides when there is anything to say.
    self.noteQuiescence(io, now_ms);
}

/// Restate how long this terminal's screen has been unchanged, if the
/// sampler thinks it is time to.
///
/// Separate from `reportQuiescence` because it is not a report: it makes no
/// notice, wakes nobody, and is not worth a log line every few seconds. It
/// only keeps `Bus.quietMs` from counting a working terminal's work as
/// stillness -- see `Sampler.heartbeat`.
fn noteQuiescence(self: *Thread, io: *termio.Termio, now_ms: u64) void {
    const q = if (self.quiescence) |*p| p else return;
    const quiet_ms = q.watcher.heartbeat(now_ms) orelse return;

    // Instant, and dropped without complaint if the mailbox is full: the
    // next tick restates the same thing a moment later.
    _ = io.surface_mailbox.app.push(.{
        .poltergeist_quiet = .{
            .from = io.surface_mailbox.surface.id,
            .quiet_ms = quiet_ms,
        },
    }, .{ .instant = {} });
}

/// Log the event, then hand it to the app so it can decide whether the
/// supervisor should hear about it.
///
/// The decision is not made here. This thread knows one terminal; who is
/// supervising whom, who has clocked off, and how recently anyone spoke are
/// all app-level facts, so the event is simply forwarded and the bus sorts
/// it out.
fn reportQuiescence(
    self: *Thread,
    io: *termio.Termio,
    event: poltergeist.Sampler.Event,
) void {
    _ = self;

    switch (event) {
        .quiescent => |r| log.info(
            "poltergeist: quiescent quiet_ms={d} silent_ms={d} changed_rows={d}/{d}",
            .{ r.quiet_ms, r.silent_ms, r.changed_rows, r.total_rows },
        ),
        .still_quiescent => |r| log.info(
            "poltergeist: still quiescent quiet_ms={d} silent_ms={d}",
            .{ r.quiet_ms, r.silent_ms },
        ),
        .resumed => |r| log.info(
            "poltergeist: resumed after quiet_ms={d}",
            .{r.quiet_ms},
        ),
    }

    // `Surface.id` is assigned once at creation and never written again, so
    // reading it from this thread needs no lock. It is also the id child
    // processes already see as GHOSTTY_SURFACE_ID, so the bus, the agents
    // and the logs all name terminals the same way.
    const id = io.surface_mailbox.surface.id;

    // Instant: a monitoring event is not worth blocking the IO thread for.
    // Losing one to a full mailbox costs nothing -- the sampler will say the
    // same thing again on its repeat interval.
    _ = io.surface_mailbox.app.push(.{
        .poltergeist_report = .{ .from = id, .event = event },
    }, .{ .instant = {} });
}

fn syncResetCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during sync reset callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;
    cb.io.resetSynchronizedOutput();
    return .disarm;
}

fn coalesceCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during coalesce callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;

    if (cb.self.coalesce_data.resize) |v| {
        cb.self.coalesce_data.resize = null;
        cb.io.resize(&cb.data, v) catch |err| {
            log.warn("error during resize err={}", .{err});
        };
    }

    return .disarm;
}

fn wakeupCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    const cb = cb_ orelse return .rearm;
    cb.self.drainMailbox(cb) catch |err|
        log.err("error draining mailbox err={}", .{err});

    return .rearm;
}

fn stopCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    cb_.?.self.loop.stop();
    return .disarm;
}

fn writeDelayCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    const cb = cb_ orelse return .disarm;

    // **Cleared before anything can fail.** A gap that never lifts would
    // leave this terminal unable to write anything again, which is a far
    // worse outcome than a gap that came out the wrong length.
    cb.self.write_delay_active = false;

    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => log.warn("error during write delay callback err={}", .{err}),
    };

    cb.self.drainMailbox(cb) catch |err|
        log.err("error draining mailbox after write delay err={}", .{err});

    return .disarm;
}

fn startScrollTimer(self: *Thread, cb: *CallbackData) void {
    self.scroll_active = true;

    switch (self.scroll_c.state()) {
        // If it is already active, e.g. startScrollTimer is called multiple
        // times, then we just return. We can't simply check `scroll_active`
        // because its possible that `stopScrollTimer` was called but there
        // was no loop tick between then and now to halt out completion.
        .active => return,

        // If the completion is not active then we need to start it.
        .dead => self.scroll.run(
            &self.loop,
            &self.scroll_c,
            selection_scroll_ms,
            CallbackData,
            cb,
            selectionScrollCallback,
        ),
    }
}

fn stopScrollTimer(self: *Thread) void {
    // This will stop the scrolling on the next iteration.
    self.scroll_active = false;
}

fn selectionScrollCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        error.Canceled => {},
        else => {
            log.warn("error during selection scroll callback err={}", .{err});
            return .disarm;
        },
    };

    const cb = cb_ orelse return .disarm;
    const self = cb.self;

    // Send the tick to the main surface. Instant, and losing one is safe
    // *here specifically*: the timer below re-arms while the scroll is
    // active, so a dropped tick costs one step of scrolling and the next
    // one says the same thing.
    _ = cb.io.surface_mailbox.push(
        .{ .selection_scroll_tick = self.scroll_active },
        .{ .instant = {} },
    );

    if (self.scroll_active) self.scroll.run(
        &self.loop,
        &self.scroll_c,
        selection_scroll_ms,
        CallbackData,
        cb,
        selectionScrollCallback,
    );

    return .disarm;
}

test "a config reload does not undo a watch that was asked for (task 550)" {
    const testing = std.testing;

    // Nothing asked: the config decides, either way.
    try testing.expect(!wantsSampling(false, null));
    try testing.expect(wantsSampling(true, null));

    // Minded by a supervisor under the default config. A reload used to
    // stop this one's sampling -- still marked watched, nothing measuring.
    try testing.expect(wantsSampling(false, true));

    // Let go under `poltergeist-watch = true`. A reload used to start this
    // one sampling again.
    try testing.expect(!wantsSampling(true, false));

    // ⚠️ What this does not catch: `syncQuiescence` going back to reading
    // `io.config.poltergeist_watch` directly instead of asking this. Found by
    // reading the code, not reproduced on a running terminal; the thread's
    // loop is not something a test here can drive.
}

test "a configured threshold reaches the sampler in the unit it left in" {
    const testing = std.testing;

    // The value handed to `quiescenceFloor` has already been converted to
    // milliseconds by `Termio.DerivedConfig`, so it must come out unchanged.
    // A second conversion here is not a rounding error: it collapses every
    // realistic threshold to the floor, and the terminals then report
    // themselves once per sample forever. Caught on a real machine rather
    // than here, because the sampler's own tests never make this trip.
    try testing.expectEqual(
        @as(u64, 15 * std.time.ms_per_s),
        quiescenceFloor(15 * std.time.ms_per_s),
    );
    try testing.expectEqual(
        @as(u64, 3 * std.time.ms_per_min),
        quiescenceFloor(3 * std.time.ms_per_min),
    );

    // Below one sample interval there is nothing to observe, so the floor
    // applies -- but only there.
    try testing.expectEqual(@as(u64, quiescence_sample_ms), quiescenceFloor(0));
    try testing.expectEqual(@as(u64, quiescence_sample_ms), quiescenceFloor(1));
}

test "a write delay pauses the drain, so the return is not written with the text" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // `Termio` is far too big to stand up here, so only the fields this
    // drain actually reads are set -- the same shape the two `Surface`
    // tests use. If somebody makes the drain read a third field this test
    // crashes rather than passing, which is the right way round.
    const io = try alloc.create(termio.Termio);
    defer alloc.destroy(io);
    io.* = undefined;
    io.alloc = alloc;

    var wakeup = try xev.Async.init();
    defer wakeup.deinit();
    io.renderer_wakeup = &wakeup;

    io.mailbox = try .initSPSC(alloc);
    defer io.mailbox.deinit(alloc);

    var thread: Thread = try .init(alloc);
    defer thread.deinit();

    var cb: CallbackData = .{ .self = &thread, .io = io };
    cb.data = undefined;
    cb.data.backend = .{ .exec = undefined };

    // The child having gone is what stops `Exec.queueWrite` before it
    // reaches a pty we do not have. The writes still travel the whole drain;
    // only the final syscall is skipped.
    cb.data.backend.exec.exited = true;

    const write = struct {
        fn f(bytes: []const u8) termio.Message {
            var small: termio.Message.WriteReq.Small = .{};
            @memcpy(small.data[0..bytes.len], bytes);
            small.len = @intCast(bytes.len);
            return .{ .write_small = small };
        }
    }.f;

    // The shape a submitting `terminal_send` puts in the mailbox: the text,
    // the gap, and the return that submits it.
    io.mailbox.send(write("abc"), null);
    io.mailbox.send(.{ .write_delay = 5 }, null);
    io.mailbox.send(write("\r"), null);

    try thread.drainMailbox(&cb);

    // ⭐ **The point of the whole change.** Without the pause the drain pops
    // all three in one pass and the return goes out against the text; the
    // receiving program then reads the return as part of a paste and does
    // not submit. Here the drain stops at the gap.
    try testing.expect(thread.write_delay_active);

    const left = io.mailbox.spsc.queue.pop(global.io());
    try testing.expect(left != null);
    try testing.expectEqualStrings("\r", left.?.write_small.data[0..left.?.write_small.len]);

    // And a wakeup arriving inside the gap must not step over it. Put the
    // return back and drain again: nothing may move.
    io.mailbox.send(left.?, null);
    try thread.drainMailbox(&cb);
    try testing.expect(thread.write_delay_active);
    try testing.expectEqual(@as(usize, 1), io.mailbox.spsc.queue.len);
}

test "a watch asked of a terminal whose IO thread has failed is answered, not dropped (task 731)" {
    // When the IO thread fails to start -- a command that could not be run
    // is the everyday case -- it stays up only to drain its mailbox, and it
    // used to drain by discarding. A `poltergeist_watch` swallowed there is
    // a terminal the bus has marked watched with nothing sampling it, and
    // no word of it anywhere, not even a log line.
    const testing = std.testing;
    const alloc = testing.allocator;
    const App = @import("../App.zig");
    const apprt = @import("../apprt.zig");

    const io = try alloc.create(termio.Termio);
    defer alloc.destroy(io);
    io.* = undefined;
    io.alloc = alloc;
    io.mailbox = try .initSPSC(alloc);
    defer io.mailbox.deinit(alloc);

    // Only the id is read of the surface.
    const surface = try alloc.create(@import("../Surface.zig"));
    defer alloc.destroy(surface);
    surface.* = undefined;
    surface.id = 0x7310;

    var rt_app: apprt.App = .{};
    const queue = try App.Mailbox.Queue.create(alloc);
    defer queue.destroy(alloc);
    io.surface_mailbox = .{ .surface = surface, .app = .{ .rt_app = &rt_app, .mailbox = queue } };

    var thread: Thread = try .init(alloc);
    defer thread.deinit();
    thread.flags.drain = true;

    var cb: CallbackData = .{ .self = &thread, .io = io };
    cb.data = undefined;

    io.mailbox.send(.{ .poltergeist_watch = true }, null);
    try thread.drainMailbox(&cb);

    // Said back to the app, where `terminal_list` can say it.
    try testing.expectEqual(@as(usize, 1), queue.len);
    const said = queue.pop(global.io()).?;
    try testing.expectEqual(@as(u64, 0x7310), said.poltergeist_sampling.from);
    try testing.expect(!said.poltergeist_sampling.started);

    // A request to stop needs no answer: nothing is waiting on one.
    io.mailbox.send(.{ .poltergeist_watch = false }, null);
    try thread.drainMailbox(&cb);
    try testing.expectEqual(@as(usize, 0), queue.len);
}

test "a watch asked of a working IO thread is confirmed, every time it is asked (task 731)" {
    // The ordinary case the answer has to cover as well: the bus marks every
    // watch unconfirmed (`Bus.watch`), so a thread that answered only when
    // sampling was newly started would leave a second watch -- a supervisor
    // claiming a terminal the keybind had already put under watch -- reading
    // `starting` until a heartbeat came.
    const testing = std.testing;
    const alloc = testing.allocator;
    const App = @import("../App.zig");
    const apprt = @import("../apprt.zig");

    const io = try alloc.create(termio.Termio);
    defer alloc.destroy(io);
    io.* = undefined;
    io.alloc = alloc;
    io.config.poltergeist_quiescence_ms = 180_000;
    io.config.poltergeist_repeat_ms = 900_000;

    const surface = try alloc.create(@import("../Surface.zig"));
    defer alloc.destroy(surface);
    surface.* = undefined;
    surface.id = 0x7311;

    var rt_app: apprt.App = .{};
    const queue = try App.Mailbox.Queue.create(alloc);
    defer queue.destroy(alloc);
    io.surface_mailbox = .{ .surface = surface, .app = .{ .rt_app = &rt_app, .mailbox = queue } };

    var thread: Thread = try .init(alloc);
    defer thread.deinit();
    var cb: CallbackData = .{ .self = &thread, .io = io };
    cb.data = undefined;

    thread.setQuiescenceWatch(io, &cb, true);
    try testing.expectEqual(@as(usize, 1), queue.len);
    try testing.expect(queue.pop(global.io()).?.poltergeist_sampling.started);

    // Already sampling: asked again, answered again.
    thread.setQuiescenceWatch(io, &cb, true);
    try testing.expectEqual(@as(usize, 1), queue.len);
    try testing.expect(queue.pop(global.io()).?.poltergeist_sampling.started);

    // Stopping is not answered.
    thread.setQuiescenceWatch(io, &cb, false);
    try testing.expectEqual(@as(usize, 0), queue.len);
}
