//! Decides when a terminal has gone quiescent.
//!
//! One sampler per surface. It is fed a `Fingerprint` on every sample tick
//! and answers a single question: has the visible screen stopped changing
//! for long enough to be worth telling the supervisor about?
//!
//! It deliberately does not decide *why* the screen stopped -- thinking,
//! waiting for input, crashed, finished -- because that is a semantic
//! judgement about content, and content judgement belongs to the supervisor
//! AI. See `dev-docs/poltergeist/sensing.md`.
//!
//! This file is pure: time arrives as a parameter and no allocation happens,
//! so the whole state machine is testable without a terminal or a clock.

const Sampler = @This();

const std = @import("std");
const Fingerprint = @import("Fingerprint.zig");

pub const Config = struct {
    /// How long the visible screen must stay unchanged before the terminal
    /// is reported quiescent.
    quiescence_ms: u64 = 3 * std.time.ms_per_min,

    /// Once reported, how long to wait before saying so again. Without this
    /// a terminal parked overnight would produce one report per sample tick.
    repeat_ms: u64 = 15 * std.time.ms_per_min,

    /// How often the caller intends to sample, so the sampler can tell a
    /// late tick from a window it was not running for at all.
    ///
    /// **It has to be told; it cannot infer it.** Every interval it could
    /// measure is one that already happened, so a sampler that guessed from
    /// history would learn the sleep gap as normal and stop noticing.
    /// `termio.Thread` passes its own `quiescence_sample_ms` here, and the
    /// default matches it so a caller that forgets is no worse off.
    sample_interval_ms: u64 = 1000,

    /// How often the live quiet figure is restated to whoever is keeping
    /// it, on ticks that produce no event. See `heartbeat`.
    ///
    /// It bounds how far the supervisor's figure may drift from the truth,
    /// and nothing else: every tick would be correct too, only chattier.
    /// Five seconds is short against the three minutes that makes a screen
    /// worth mentioning, and long against the one second a tick takes.
    heartbeat_ms: u64 = 5 * std.time.ms_per_s,

    /// The gap, in sample intervals, above which a window counts as one the
    /// machine was not running for. See `gap_intervals`.
    fn sleepGapMs(self: Config) u64 {
        return self.sample_interval_ms *| gap_intervals;
    }
};

/// How many missed sample intervals it takes before a gap stops being a late
/// tick and starts being a window we were not running for.
///
/// **Ten, and the reason it is not smaller is not the one you would guess.**
///
/// *The lower bound is the tests, not the jitter.* The largest jump any
/// existing test makes between two observations is 5000 ms (`setConfig
/// applies without restarting the quiet clock`, and the same shape in
/// `Watcher.zig`). Those jumps model a slow sampler, not a sleeping machine.
/// Set this to 2 and three tests that were here before this constant was --
/// that one, `a still quiescent terminal repeats only after repeat_ms`, and
/// `noteActivity on a quiescent terminal reports it resumed` -- go red,
/// which is how that bound was established rather than assumed.
///
/// *The jitter is nowhere near it.* Measured on the machine this was written
/// on, sampling once a second the way `termio.Thread` does and reading the
/// same clock (`CLOCK_UPTIME_RAW`, which is what `.awake` resolves to on
/// macOS): **718 ticks over 12 minutes, largest gap 1011 ms, none at or
/// above 2000 ms.** Under a deliberate 12-spinner load on 10 cores -- load
/// average 30 -- 179 ticks over 3 minutes gave largest gap 1010 ms, again
/// none at or above 2000 ms. The tail did not move, so the jitter is not
/// load-sensitive and 11 ms is the whole of it.
///
/// ⚠️ *What that measurement does not cover.* The probe did not run on a
/// thread that was also parsing pty output, and it waited with `nanosleep`
/// rather than through `xev`. So it bounds scheduling and timer jitter and
/// **not** the delay a long parse can add to the callback. That component is
/// unmeasured here; 10 s is chosen with room for it, not with knowledge of
/// it.
///
/// *The upper bound* is the shortest window this has to catch: macOS's
/// DarkWake cadence with the lid shut, which `pmset -g log` shows as a wake
/// roughly every 15 minutes. 10 s is about a ninetieth of that. It also has
/// to stay well under `quiescence_ms` (three minutes by default), or a wake
/// would accumulate a fresh report before the gap that caused it was noticed.
const gap_intervals: u64 = 10;

pub const Observation = struct {
    /// Monotonic milliseconds. Must not go backwards; if it does, the
    /// sampler degrades to "no time has passed" rather than underflowing.
    now_ms: u64,

    fingerprint: Fingerprint,

    /// pty bytes seen since the previous observation. This is reported to
    /// the supervisor as extra context, never used to decide quiescence.
    ///
    /// Byte silence is not a substitute for a fingerprint: scrolling, making
    /// a selection, or IME preedit all change the screen without a single
    /// pty byte. Treating "no bytes" as "no change" would keep the
    /// quiescence timer running while a human is visibly working in the
    /// terminal, which is the one direction of error we cannot accept.
    bytes: u64 = 0,
};

/// What the supervisor is told. Durations only -- no interpretation.
pub const Report = struct {
    /// How long the visible screen has been unchanged.
    quiet_ms: u64,

    /// How long since the pty produced a byte. May be far shorter than
    /// `quiet_ms` when a program is redrawing without changing anything --
    /// a spinner, for instance. Both numbers go to the supervisor precisely
    /// so it can tell those cases apart itself.
    silent_ms: u64,

    /// How many rows moved the last time the screen actually changed.
    ///
    /// Not "how many rows changed in this sample": on a quiescent report
    /// that is zero by definition, which says nothing. What is worth
    /// knowing is whether the thing that happened last was a whole screen
    /// repainting or a single line ticking over.
    changed_rows: u16,

    total_rows: u16,
};

pub const Event = union(enum) {
    /// The screen has now been unchanged for at least `quiescence_ms`.
    quiescent: Report,

    /// Still unchanged. Emitted at most once per `repeat_ms`.
    still_quiescent: Report,

    /// The screen changed after having been reported quiescent.
    resumed: Report,
};

config: Config,

/// The last screen hash seen. Null until the first observation.
last_screen: ?u64 = null,

/// When the screen last changed.
last_change_ms: u64 = 0,

/// When the pty last produced a byte.
last_byte_ms: u64 = 0,

/// When we last reported quiescence. Null while active.
last_report_ms: ?u64 = null,

/// Row counts carried forward from the last sample that changed, so a
/// quiescent report can say what the last thing to happen looked like.
last_change_rows: u16 = 0,
last_total_rows: u16 = 0,

/// Set when a sample was missed, so `last_screen` no longer describes what
/// is on screen now. The next successful sample is treated as a change
/// whatever it hashes to.
///
/// Two things set it now -- a sample the caller could not take, and a window
/// the machine was not running for. They mean the same thing to everything
/// downstream ("the stored fingerprint is not what is on screen"), and
/// nothing outside this file reads the flag, so one flag is right. If a
/// reader ever needs to tell the two apart, that is the moment to split it,
/// not before.
stale: bool = false,

/// When the sampler was last touched at all -- by a real sample or by a
/// missed one. Null until the first touch.
///
/// **Not "when we last sampled successfully".** The caller touches this
/// object on every tick whether or not it could read the screen, so a busy
/// terminal that fails to take the lock for a minute still ticks once a
/// second. Measuring across successful samples only would read that busy
/// minute as a sleeping machine, which is the opposite of the truth.
last_sample_ms: ?u64 = null,

/// When the live quiet figure was last restated. Null until the first one.
last_heartbeat_ms: ?u64 = null,

pub fn init(config: Config) Sampler {
    return .{ .config = config };
}

/// Whether the sampler currently considers this terminal quiescent. Useful
/// for status display; the event stream is the authoritative signal.
pub fn isQuiescent(self: *const Sampler) bool {
    return self.last_report_ms != null;
}

/// Apply new thresholds without losing what has been observed so far.
///
/// Config reload has to reach a terminal that is already being watched;
/// rebuilding the sampler instead would silently restart its quiet clock,
/// so a terminal that had been still for an hour would look brand new.
pub fn setConfig(self: *Sampler, config: Config) void {
    self.config = config;
}

/// The live quiet figure, when it is time to state it again.
///
/// **The number this exists to stop.** Whoever keeps the figure for the
/// supervisor -- `Bus.quietMs` -- does not store a duration, it stores the
/// last one it was told and adds the time since. That is exact while the
/// screen is still, because a screen that moved would have produced a
/// `resumed`. It is false the moment the screen is moving: this file only
/// speaks on transitions, so a terminal working flat out for half an hour
/// produces no event at all, and half an hour is exactly what the
/// supervisor is then shown. Two terminals whose screens were visibly
/// changing were reported quiet for 29 and 31 minutes and climbing, which
/// is the reading a supervisor interrupts somebody over.
///
/// So the moving case gets the one thing the still case gets for free: a
/// statement, often enough that nobody's figure can drift past
/// `heartbeat_ms`. It is not a report and never becomes a notice -- the
/// screen moving is not news -- it only keeps the arithmetic honest.
///
/// Silent in two cases, both because the figure is already right without
/// it: before the first observation there is nothing measured to state,
/// and while quiescence stands the extrapolation is exact.
pub fn heartbeat(self: *Sampler, now_ms: u64) ?u64 {
    if (self.last_screen == null) return null;
    if (self.last_report_ms != null) return null;

    if (self.last_heartbeat_ms) |last| {
        if (now_ms -| last < self.config.heartbeat_ms) return null;
    }

    self.last_heartbeat_ms = now_ms;
    return now_ms -| self.last_change_ms;
}

/// Feed one sample. Returns an event only on a transition worth reporting,
/// so the caller can log or forward unconditionally.
pub fn observe(self: *Sampler, obs: Observation) ?Event {
    const gap = self.noteTouched(obs.now_ms);

    if (obs.bytes > 0) self.last_byte_ms = obs.now_ms;
    self.last_total_rows = obs.fingerprint.total_rows;

    // First observation just arms the sampler. We cannot know how long the
    // screen was already still before we started looking, and guessing
    // would let a freshly attached terminal report quiescence immediately.
    const last = self.last_screen orelse {
        self.last_screen = obs.fingerprint.screen;
        self.last_change_ms = obs.now_ms;
        self.last_byte_ms = obs.now_ms;
        return null;
    };

    if (gap) {
        self.enterUnknownWindow(obs.now_ms);
        return null;
    }

    if (self.stale or obs.fingerprint.screen != last) {
        self.stale = false;
        self.last_screen = obs.fingerprint.screen;
        self.last_change_rows = obs.fingerprint.changed_rows;
        return self.markChanged(obs.now_ms);
    }

    // Saturating so a clock that jumps backwards reads as "no time passed"
    // instead of wrapping to an enormous duration and firing instantly.
    const quiet_ms = obs.now_ms -| self.last_change_ms;
    if (quiet_ms < self.config.quiescence_ms) return null;

    const reported = self.last_report_ms orelse {
        self.last_report_ms = obs.now_ms;
        return .{ .quiescent = self.report(obs.now_ms) };
    };

    if (obs.now_ms -| reported >= self.config.repeat_ms) {
        self.last_report_ms = obs.now_ms;
        return .{ .still_quiescent = self.report(obs.now_ms) };
    }

    return null;
}

/// Record that a sample could not be taken, and that we therefore do not
/// know whether the screen changed during that window.
///
/// The caller reaches this when it could not take the terminal lock. Under
/// sustained output the parse loop holds that lock almost continuously, so
/// this is not a rare case -- it is precisely what a busy terminal looks
/// like from here.
///
/// An unknown window is treated as activity, not as stillness. Doing the
/// opposite would let a terminal that changed and changed back across a run
/// of skipped samples be reported as having been still the whole time,
/// which is the one direction of error this design cannot accept. The cost
/// of guessing this way is only that a genuinely idle terminal takes
/// another sample or two to be reported.
pub fn noteActivity(self: *Sampler, now_ms: u64) ?Event {
    const gap = self.noteTouched(now_ms);

    // Nothing to do before the first real sample: there is no baseline to
    // invalidate and nothing has been reported.
    if (self.last_screen == null) return null;

    // The same window `observe` refuses to speak about. A tick that arrives
    // after a sleep can just as easily find the lock busy as find it free,
    // and the two paths must not disagree about what the night meant.
    if (gap) {
        self.enterUnknownWindow(now_ms);
        return null;
    }

    // We do not know what the screen looks like now, so the stored
    // fingerprint can no longer be trusted as "what we last saw". Marking
    // it stale forces the next successful sample to count as a change even
    // if the screen happens to hash back to the same value.
    //
    // Note this deliberately does not touch `last_byte_ms`: the reader
    // thread keeps counting pty output whether or not we can sample, so
    // silence remains measured correctly across a skipped window.
    self.stale = true;
    return self.markChanged(now_ms);
}

/// Record that the sampler was touched, and say whether the touch follows a
/// window it was not running for.
///
/// Every entry point calls this first, which is what makes the gap mean
/// "nothing ran", rather than "nothing succeeded".
fn noteTouched(self: *Sampler, now_ms: u64) bool {
    const previous = self.last_sample_ms;
    self.last_sample_ms = now_ms;
    const last = previous orelse return false;
    return (now_ms -| last) >= self.config.sleepGapMs();
}

/// A window the machine was not running for: a closed lid, a suspended VM, a
/// process stopped at a debugger prompt.
///
/// **Treated as activity, and reported as nothing.** The activity half is
/// this file's existing rule -- see `noteActivity` -- and it applies here for
/// the same reason: nobody was watching the screen, so nothing can be said
/// about whether it was still. The silence is the other half, and it is the
/// defect this was written for.
///
/// Routing the window through `markChanged` would have been the small change,
/// and it would have emitted `resumed`: one per wake window, all night, in
/// place of the `still_quiescent` it was meant to stop. And `resumed` is a
/// worse thing to say than `still_quiescent` was -- it asserts the worker
/// came back, which is not something a maintenance wake tells us. So the
/// state moves and no claim is made.
///
/// What the supervisor loses is the overnight `quiet_ms`. That number was
/// already not what it looked like: `.awake` is `CLOCK_UPTIME_RAW` on macOS,
/// so deep sleep was never counted in it either.
fn enterUnknownWindow(self: *Sampler, now_ms: u64) void {
    // Same three effects `markChanged` + `noteActivity` would have had,
    // minus the event.
    self.stale = true;
    self.last_change_ms = now_ms;
    self.last_report_ms = null;
}

/// Common tail for "the screen is not still": restart the quiet clock and,
/// if we had already reported quiescence, say that it is over.
fn markChanged(self: *Sampler, now_ms: u64) ?Event {
    // Build the report before moving `last_change_ms`, so `quiet_ms` says
    // how long it had been still *before* it moved again. That is the
    // number the supervisor wants ("it sat for 12 minutes and has just come
    // back"); measuring after the update would always be 0.
    const resumed: Report = self.report(now_ms);
    self.last_change_ms = now_ms;

    // Only worth an event if we had previously said it was quiescent.
    if (self.last_report_ms != null) {
        self.last_report_ms = null;
        return .{ .resumed = resumed };
    }
    return null;
}

fn report(self: *const Sampler, now_ms: u64) Report {
    return .{
        .quiet_ms = now_ms -| self.last_change_ms,
        .silent_ms = now_ms -| self.last_byte_ms,
        .changed_rows = self.last_change_rows,
        .total_rows = self.last_total_rows,
    };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// Build an observation with a screen hash chosen by the caller. Row counts
/// are arbitrary; nothing in the state machine reads them.
fn sample(now_ms: u64, screen: u64, bytes: u64) Observation {
    return .{
        .now_ms = now_ms,
        .bytes = bytes,
        .fingerprint = .{ .screen = screen, .changed_rows = 0, .total_rows = 24 },
    };
}

const fast: Config = .{ .quiescence_ms = 1000, .repeat_ms = 5000 };

test "the first observation only arms the sampler" {
    var s: Sampler = .init(fast);
    try testing.expect(s.observe(sample(0, 1, 0)) == null);
    try testing.expect(!s.isQuiescent());
}

test "a changing screen never goes quiescent" {
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 1, 10));
    var now: u64 = 0;
    var screen: u64 = 1;
    while (now < 10_000) : (now += 500) {
        screen += 1;
        try testing.expect(s.observe(sample(now, screen, 10)) == null);
    }
    try testing.expect(!s.isQuiescent());
}

test "an unchanged screen stays silent below the threshold" {
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 0));
    try testing.expect(s.observe(sample(500, 7, 0)) == null);
    try testing.expect(s.observe(sample(999, 7, 0)) == null);
    try testing.expect(!s.isQuiescent());
}

test "crossing the threshold reports quiescent exactly once" {
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 0));

    const e = s.observe(sample(1000, 7, 0)) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, 1000), e.quiescent.quiet_ms);
    try testing.expect(s.isQuiescent());

    // Same state, well before repeat_ms: nothing more to say.
    try testing.expect(s.observe(sample(1500, 7, 0)) == null);
    try testing.expect(s.observe(sample(2000, 7, 0)) == null);
}

test "a still quiescent terminal repeats only after repeat_ms" {
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 0));
    _ = s.observe(sample(1000, 7, 0));

    try testing.expect(s.observe(sample(5999, 7, 0)) == null);

    const e = s.observe(sample(6000, 7, 0)) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, 6000), e.still_quiescent.quiet_ms);
}

test "a change after quiescence reports resumed" {
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 0));
    _ = s.observe(sample(1000, 7, 0));
    try testing.expect(s.isQuiescent());

    const e = s.observe(sample(1200, 8, 4)) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, 1200), e.resumed.quiet_ms);
    try testing.expect(!s.isQuiescent());

    // And it can go quiescent again from the new content.
    try testing.expect(s.observe(sample(2199, 8, 0)) == null);
    const again = s.observe(sample(2200, 8, 0)) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, 1000), again.quiescent.quiet_ms);
}

test "a change while already active produces no event" {
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 0));
    try testing.expect(s.observe(sample(100, 8, 1)) == null);
    try testing.expect(s.observe(sample(200, 9, 1)) == null);
}

test "silent_ms tracks pty bytes independently of screen changes" {
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 1));

    // A program redrawing itself without changing anything: bytes keep
    // arriving, the screen hash does not move. The screen is quiescent but
    // the pty is not silent, and both numbers reach the supervisor.
    try testing.expect(s.observe(sample(500, 7, 100)) == null);
    const e = s.observe(sample(1000, 7, 100)) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, 1000), e.quiescent.quiet_ms);
    try testing.expectEqual(@as(u64, 0), e.quiescent.silent_ms);
}

test "silent_ms grows when the pty produces nothing" {
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 1));
    const e = s.observe(sample(1000, 7, 0)) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, 1000), e.quiescent.silent_ms);
}

test "a clock that jumps backwards does not fire early" {
    var s: Sampler = .init(fast);
    _ = s.observe(sample(10_000, 7, 0));

    // Earlier than the arming observation. Saturating subtraction reads this
    // as zero elapsed rather than wrapping to ~u64 max and firing at once.
    try testing.expect(s.observe(sample(5_000, 7, 0)) == null);
    try testing.expect(!s.isQuiescent());
}

test "a quiet sample reports its own row count but not its own changed rows" {
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 0));

    // changed_rows on this sample is noise: the screen did not move, so
    // whatever the builder counted against the previous buffer says nothing
    // about what the terminal last did. total_rows is still current.
    const e = s.observe(.{
        .now_ms = 1000,
        .bytes = 0,
        .fingerprint = .{ .screen = 7, .changed_rows = 3, .total_rows = 40 },
    }) orelse return error.TestExpectedEvent;

    try testing.expectEqual(@as(u16, 0), e.quiescent.changed_rows);
    try testing.expectEqual(@as(u16, 40), e.quiescent.total_rows);
}

test "a skipped sample is treated as activity, not as stillness" {
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 0));

    // The screen really did change and change back while we could not look.
    // Counting that window as quiet is the failure this guards against.
    for (1..180) |i| _ = s.noteActivity(@intCast(i * 10));

    // Same fingerprint as before the gap. Without staleness this would read
    // as "unchanged for 1800ms" and report quiescent immediately.
    try testing.expect(s.observe(sample(1800, 7, 0)) == null);
    try testing.expect(!s.isQuiescent());

    // The quiet clock restarts from the end of the gap, so quiescence is
    // still a full threshold away.
    try testing.expect(s.observe(sample(2799, 7, 0)) == null);
    const e = s.observe(sample(2800, 7, 0)) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, 1000), e.quiescent.quiet_ms);
}

test "noteActivity on a quiescent terminal reports it resumed" {
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 0));
    _ = s.observe(sample(1000, 7, 0));
    try testing.expect(s.isQuiescent());

    const e = s.noteActivity(5000) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, 5000), e.resumed.quiet_ms);
    try testing.expect(!s.isQuiescent());
}

test "noteActivity before the first sample does nothing" {
    var s: Sampler = .init(fast);
    try testing.expect(s.noteActivity(1000) == null);
    try testing.expect(!s.isQuiescent());
}

test "noteActivity does not disturb pty silence tracking" {
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 1));

    // Samples missed, but the reader thread kept seeing nothing.
    _ = s.noteActivity(1000);
    _ = s.noteActivity(2000);

    // The first sample after the gap counts as a change, so it is quiet from
    // t=3000 onwards and reports one threshold later.
    try testing.expect(s.observe(sample(3000, 7, 0)) == null);

    const e = s.observe(sample(4000, 7, 0)) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, 1000), e.quiescent.quiet_ms);

    // Silence is measured from the last pty byte at t=0, straight through
    // the skipped window -- it is not reset by noteActivity.
    try testing.expectEqual(@as(u64, 4000), e.quiescent.silent_ms);
}

test "changed_rows reports the last real change, not the quiet sample" {
    var s: Sampler = .init(fast);
    _ = s.observe(.{
        .now_ms = 0,
        .fingerprint = .{ .screen = 1, .changed_rows = 0, .total_rows = 24 },
    });

    // A change that moved 9 rows.
    _ = s.observe(.{
        .now_ms = 100,
        .fingerprint = .{ .screen = 2, .changed_rows = 9, .total_rows = 24 },
    });

    // Now it goes still. The sample itself has 0 changed rows, but what the
    // supervisor wants to know is that the last thing to happen moved 9.
    const e = s.observe(.{
        .now_ms = 1100,
        .fingerprint = .{ .screen = 2, .changed_rows = 0, .total_rows = 24 },
    }) orelse return error.TestExpectedEvent;

    try testing.expectEqual(@as(u16, 9), e.quiescent.changed_rows);
    try testing.expectEqual(@as(u16, 24), e.quiescent.total_rows);
}

test "setConfig applies without restarting the quiet clock" {
    var s: Sampler = .init(.{ .quiescence_ms = 60_000, .repeat_ms = 60_000 });
    _ = s.observe(sample(0, 7, 0));
    try testing.expect(s.observe(sample(5000, 7, 0)) == null);

    // Shorten the threshold below the time already elapsed. The next sample
    // should report at once rather than starting the count again.
    s.setConfig(.{ .quiescence_ms = 1000, .repeat_ms = 60_000 });
    const e = s.observe(sample(5001, 7, 0)) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, 5001), e.quiescent.quiet_ms);
}

test "default config uses minutes, not milliseconds" {
    // Guards against a units slip in Config: a 3 ms threshold would make
    // every terminal look quiescent instantly.
    const d: Config = .{};
    try testing.expectEqual(@as(u64, 180_000), d.quiescence_ms);
    try testing.expectEqual(@as(u64, 900_000), d.repeat_ms);
}

// -- the closed lid ---------------------------------------------------------

/// One sample interval, as `fast` and the default `Config` both use it.
const tick = 1000;

test "a lid closed overnight says nothing at all" {
    // **The reported defect, as a sequence.** A laptop is shut overnight.
    // macOS wakes it for a few seconds of maintenance roughly every quarter
    // of an hour -- DarkWake -- and `.awake` is `CLOCK_UPTIME_RAW`, which
    // runs during those windows. So this code does run, sees the screen
    // nobody has touched, and finds that `repeat_ms` has gone by since it
    // last spoke. `repeat_ms` defaults to 15 minutes and the wake cadence is
    // about 15 minutes: the two resonate, and the supervisor gets one line
    // per wake, all night.
    //
    // Before the gap check, this test failed here with:
    //
    //     .{ .still_quiescent = .{ .quiet_ms = 901000, .silent_ms = 901000,
    //        .changed_rows = 0, .total_rows = 24 } }
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 0));
    _ = s.observe(sample(tick, 7, 0));
    try testing.expect(s.isQuiescent());

    const woken = tick + 15 * std.time.ms_per_min;
    try testing.expect(s.observe(sample(woken, 7, 0)) == null);

    // And it is no longer claiming to know: the night is not stillness it
    // observed, so the terminal reads as active again.
    try testing.expect(!s.isQuiescent());
}

test "a whole night of wake windows produces nothing" {
    // The first wake is the interesting one; the point of this test is all
    // the ones after it. It runs on the **default** config rather than
    // `fast`, because the thing being modelled has two real durations in it
    // and their ratio is the whole question: a maintenance wake is tens of
    // seconds and `quiescence_ms` is three minutes, so no wake window is
    // long enough to earn a fresh `quiescent` on its own.
    //
    // ⚠️ That ratio is a real limit, not an artefact of the test. Configure
    // `poltergeist_quiescence_ms` shorter than a wake window and each wake
    // becomes long enough to report quiescent from scratch -- one line per
    // wake again, for a different reason. Nothing here can prevent that; it
    // is the setting asking for it.
    const config: Config = .{};
    var s: Sampler = .init(config);

    // Three minutes of ordinary once-a-second ticks, ending in the report
    // the supervisor legitimately gets before the lid comes down.
    var now: u64 = 0;
    _ = s.observe(sample(now, 7, 0));
    while (now < config.quiescence_ms) {
        now += tick;
        if (s.observe(sample(now, 7, 0))) |e| {
            try testing.expectEqual(@as(u64, config.quiescence_ms), e.quiescent.quiet_ms);
        }
    }
    try testing.expect(s.isQuiescent());

    // The lid comes down. Eight hours of it, at the cadence `pmset -g log`
    // shows: a wake roughly every quarter of an hour, awake for about
    // three quarters of a minute each time.
    for (0..32) |_| {
        now += 15 * std.time.ms_per_min;
        try testing.expect(s.observe(sample(now, 7, 0)) == null);

        for (0..45) |_| {
            now += tick;
            try testing.expect(s.observe(sample(now, 7, 0)) == null);
        }
    }
}

test "a busy terminal is not mistaken for a sleeping one" {
    // **The negative control, and the one that decides whether the gap is
    // measured over the right thing.** Under sustained output the caller
    // cannot take the terminal lock, so every tick arrives through
    // `noteActivity` and no sample succeeds for a minute at a time.
    //
    // If the gap were measured between *successful samples*, that minute
    // would read as a sleeping machine and this terminal would stop being
    // reported. It is measured between *touches* instead, and the ticks keep
    // coming once a second, so nothing here is a gap.
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 0));
    _ = s.observe(sample(tick, 7, 0));
    try testing.expect(s.isQuiescent());

    // A minute of ticks that could not read the screen. The first one ends
    // quiescence the way it always did -- as activity, out loud.
    const e = s.noteActivity(2 * tick) orelse return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, 2 * tick), e.resumed.quiet_ms);

    var now: u64 = 2 * tick;
    for (0..60) |_| {
        now += tick;
        try testing.expect(s.noteActivity(now) == null);
    }

    // Still able to go quiescent afterwards: a busy spell is not a poisoned
    // sampler.
    try testing.expect(s.observe(sample(now + tick, 7, 0)) == null);
    const q = s.observe(sample(now + tick + fast.quiescence_ms, 7, 0)) orelse
        return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, fast.quiescence_ms), q.quiescent.quiet_ms);
}

test "the gap threshold is where the config says it is" {
    // Two runs that differ only in how far the clock jumps, either side of
    // `gap_intervals` sample intervals. Without this, a threshold of
    // effectively infinity would pass every other test in this file.
    const just_under = fast.sample_interval_ms * gap_intervals - 1;
    const just_over = fast.sample_interval_ms * gap_intervals;

    {
        var s: Sampler = .init(fast);
        _ = s.observe(sample(0, 7, 0));
        _ = s.observe(sample(tick, 7, 0));
        const e = s.observe(sample(tick + just_under, 7, 0)) orelse
            return error.TestExpectedEvent;
        // A slow sampler, not a sleeping machine: it still speaks.
        try testing.expectEqual(@as(u64, tick + just_under), e.still_quiescent.quiet_ms);
    }
    {
        var s: Sampler = .init(fast);
        _ = s.observe(sample(0, 7, 0));
        _ = s.observe(sample(tick, 7, 0));
        try testing.expect(s.observe(sample(tick + just_over, 7, 0)) == null);
    }
}

test "the gap scales with the configured sample interval" {
    // **The reason the threshold is not a constant in this file.** A caller
    // that samples once a minute is not late when a minute goes by, and a
    // jump that is a sleeping machine for one caller is an ordinary tick for
    // another. The same 30s jump has to read both ways.
    const jump = 30 * std.time.ms_per_s;

    {
        // Sampling once a second: 30s is thirty missed ticks. Asleep.
        var s: Sampler = .init(.{ .quiescence_ms = 1000, .repeat_ms = 5000, .sample_interval_ms = 1000 });
        _ = s.observe(sample(0, 7, 0));
        _ = s.observe(sample(tick, 7, 0));
        try testing.expect(s.observe(sample(tick + jump, 7, 0)) == null);
    }
    {
        // Sampling once a minute: 30s is half of one interval. Early, even.
        var s: Sampler = .init(.{
            .quiescence_ms = 1000,
            .repeat_ms = 5000,
            .sample_interval_ms = std.time.ms_per_min,
        });
        _ = s.observe(sample(0, 7, 0));
        _ = s.observe(sample(tick, 7, 0));
        const e = s.observe(sample(tick + jump, 7, 0)) orelse
            return error.TestExpectedEvent;
        try testing.expectEqual(@as(u64, tick + jump), e.still_quiescent.quiet_ms);
    }
}

test "a wake that cannot take the lock is just as silent" {
    // The first tick after a sleep is as likely to find the lock busy as
    // free, so `noteActivity` has to refuse to speak about the window too.
    // Through `markChanged` this would emit `resumed` -- which is a worse
    // claim than the one being suppressed, because it says the worker came
    // back, and a maintenance wake says nothing of the kind.
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 0));
    _ = s.observe(sample(tick, 7, 0));
    try testing.expect(s.isQuiescent());

    try testing.expect(s.noteActivity(tick + 15 * std.time.ms_per_min) == null);
    try testing.expect(!s.isQuiescent());
}

test "the lid opening starts the clock again from the wake" {
    // The accepted cost, pinned so it is a decision and not a surprise: the
    // morning's report says "still for three minutes", not "still all
    // night". The overnight number was never what it looked like anyway --
    // `.awake` excludes deep sleep, so most of the night was never in it.
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 0));
    _ = s.observe(sample(tick, 7, 0));

    const morning = tick + 8 * std.time.ms_per_hour;
    try testing.expect(s.observe(sample(morning, 7, 0)) == null);

    // The sample after the gap is the one that re-establishes what is on
    // screen; quiet is measured from there.
    try testing.expect(s.observe(sample(morning + tick, 7, 0)) == null);
    const e = s.observe(sample(morning + tick + fast.quiescence_ms, 7, 0)) orelse
        return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, fast.quiescence_ms), e.quiescent.quiet_ms);
}

test "a gap before the first sample is not a gap" {
    // A sampler switched on while the machine was already asleep, or simply
    // one whose first tick is late. There is nothing to be stale about and
    // nothing to stay silent about yet, so the arming sample must still arm
    // -- and the terminal must be able to go quiescent normally afterwards
    // rather than being stuck behind a gap that was never observed.
    var s: Sampler = .init(fast);
    _ = s.noteActivity(0);

    const late = 10 * std.time.ms_per_min;
    try testing.expect(s.observe(sample(late, 7, 0)) == null);

    const e = s.observe(sample(late + fast.quiescence_ms, 7, 0)) orelse
        return error.TestExpectedEvent;
    try testing.expectEqual(@as(u64, fast.quiescence_ms), e.quiescent.quiet_ms);
}

test "sample_interval_ms defaults to the value termio.Thread ticks at" {
    // `Thread.quiescence_sample_ms` is 1000. A default that disagreed would
    // make the gap threshold wrong by exactly the ratio, on every terminal
    // whose caller did not pass the field -- silently, because every test
    // that builds a Config by hand would go on passing.
    const d: Config = .{};
    try testing.expectEqual(@as(u64, 1000), d.sample_interval_ms);
    try testing.expectEqual(@as(u64, 10_000), d.sleepGapMs());
}

test "the heartbeat says nothing before the first observation" {
    var s: Sampler = .init(fast);
    try testing.expect(s.heartbeat(0) == null);
    try testing.expect(s.heartbeat(60_000) == null);
}

test "a moving screen restates its quiet time at the heartbeat interval" {
    var s: Sampler = .init(.{ .quiescence_ms = 1000, .repeat_ms = 5000, .heartbeat_ms = 5000 });

    // The first observation arms it, and the first heartbeat states what it
    // has: nothing has been still for any time at all yet.
    _ = s.observe(sample(0, 1, 10));
    try testing.expectEqual(@as(u64, 0), s.heartbeat(0) orelse return error.TestExpectedHeartbeat);

    // Too soon: the figure whoever holds it already has is good to within
    // the interval, so there is nothing to say.
    try testing.expect(s.heartbeat(1000) == null);
    try testing.expect(s.heartbeat(4999) == null);

    // A screen changing once a second, restated every five.
    var now: u64 = 1000;
    var screen: u64 = 1;
    var heard: usize = 0;
    while (now <= 30_000) : (now += 1000) {
        screen += 1;
        _ = s.observe(sample(now, screen, 10));
        if (s.heartbeat(now)) |quiet_ms| {
            heard += 1;

            // The screen moved on this very tick, so the whole of what it
            // has been still for is nothing.
            try testing.expectEqual(@as(u64, 0), quiet_ms);
        }
    }
    try testing.expectEqual(@as(usize, 6), heard);
}

test "a screen that has stopped is restated until it is reported" {
    var s: Sampler = .init(.{ .quiescence_ms = 60_000, .repeat_ms = 5000, .heartbeat_ms = 5000 });
    _ = s.observe(sample(0, 7, 0));
    _ = s.heartbeat(0);

    // Below the threshold there is no event, and the figure still has to be
    // right: a terminal still for forty seconds is forty seconds quiet, not
    // "nothing has been said about it".
    //
    // Sampled every second the way `termio.Thread` does, because jumping
    // straight to forty would be a gap the sampler reads as a window it was
    // not running for -- which is a different case with a different answer.
    var now: u64 = 1000;
    var last: u64 = 0;
    while (now <= 40_000) : (now += 1000) {
        try testing.expect(s.observe(sample(now, 7, 0)) == null);
        if (s.heartbeat(now)) |quiet_ms| {
            try testing.expectEqual(now, quiet_ms);
            last = quiet_ms;
        }
    }
    try testing.expectEqual(@as(u64, 40_000), last);
}

test "a reported quiescence needs no heartbeat" {
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 0));
    _ = s.heartbeat(0);

    _ = s.observe(sample(1000, 7, 0)) orelse return error.TestExpectedEvent;
    try testing.expect(s.isQuiescent());

    // The report said how long it had been still, and nothing has moved
    // since, so adding the elapsed time to it is exact. Restating it would
    // be the same number arrived at twice.
    try testing.expect(s.heartbeat(6000) == null);
    try testing.expect(s.heartbeat(9000) == null);

    // Back at work: the figure is live again, and so is the heartbeat.
    const e = s.observe(sample(9000, 8, 10)) orelse return error.TestExpectedEvent;
    try testing.expect(e == .resumed);
    try testing.expectEqual(
        @as(u64, 0),
        s.heartbeat(9000) orelse return error.TestExpectedHeartbeat,
    );
}
