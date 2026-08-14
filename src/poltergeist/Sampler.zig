//! Decides when a terminal has gone quiescent.
//!
//! One sampler per surface. It is fed a `Fingerprint` on every sample tick
//! and answers a single question: has the visible screen stopped changing
//! for long enough to be worth telling the supervisor about?
//!
//! It deliberately does not decide *why* the screen stopped -- thinking,
//! waiting for input, crashed, finished -- because that is a semantic
//! judgement about content, and content judgement belongs to the supervisor
//! AI. See `docs/poltergeist/sensing.md`.
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
};

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

pub fn init(config: Config) Sampler {
    return .{ .config = config };
}

/// Whether the sampler currently considers this terminal quiescent. Useful
/// for status display; the event stream is the authoritative signal.
pub fn isQuiescent(self: *const Sampler) bool {
    return self.last_report_ms != null;
}

/// Feed one sample. Returns an event only on a transition worth reporting,
/// so the caller can log or forward unconditionally.
pub fn observe(self: *Sampler, obs: Observation) ?Event {
    if (obs.bytes > 0) self.last_byte_ms = obs.now_ms;

    // First observation just arms the sampler. We cannot know how long the
    // screen was already still before we started looking, and guessing
    // would let a freshly attached terminal report quiescence immediately.
    const last = self.last_screen orelse {
        self.last_screen = obs.fingerprint.screen;
        self.last_change_ms = obs.now_ms;
        self.last_byte_ms = obs.now_ms;
        return null;
    };

    if (obs.fingerprint.screen != last) {
        // Build the report before moving `last_change_ms`, so `quiet_ms`
        // says how long it had been still *before* it moved again. That is
        // the number the supervisor wants ("it sat for 12 minutes and has
        // just come back"); measuring after the update would always be 0.
        const resumed: Report = self.report(obs);

        self.last_screen = obs.fingerprint.screen;
        self.last_change_ms = obs.now_ms;

        // Only worth an event if we had previously said it was quiescent.
        if (self.last_report_ms != null) {
            self.last_report_ms = null;
            return .{ .resumed = resumed };
        }
        return null;
    }

    // Saturating so a clock that jumps backwards reads as "no time passed"
    // instead of wrapping to an enormous duration and firing instantly.
    const quiet_ms = obs.now_ms -| self.last_change_ms;
    if (quiet_ms < self.config.quiescence_ms) return null;

    const reported = self.last_report_ms orelse {
        self.last_report_ms = obs.now_ms;
        return .{ .quiescent = self.report(obs) };
    };

    if (obs.now_ms -| reported >= self.config.repeat_ms) {
        self.last_report_ms = obs.now_ms;
        return .{ .still_quiescent = self.report(obs) };
    }

    return null;
}

fn report(self: *const Sampler, obs: Observation) Report {
    return .{
        .quiet_ms = obs.now_ms -| self.last_change_ms,
        .silent_ms = obs.now_ms -| self.last_byte_ms,
        .changed_rows = obs.fingerprint.changed_rows,
        .total_rows = obs.fingerprint.total_rows,
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

test "report carries the fingerprint row counts through" {
    var s: Sampler = .init(fast);
    _ = s.observe(sample(0, 7, 0));

    const e = s.observe(.{
        .now_ms = 1000,
        .bytes = 0,
        .fingerprint = .{ .screen = 7, .changed_rows = 3, .total_rows = 40 },
    }) orelse return error.TestExpectedEvent;

    try testing.expectEqual(@as(u16, 3), e.quiescent.changed_rows);
    try testing.expectEqual(@as(u16, 40), e.quiescent.total_rows);
}

test "default config uses minutes, not milliseconds" {
    // Guards against a units slip in Config: a 3 ms threshold would make
    // every terminal look quiescent instantly.
    const d: Config = .{};
    try testing.expectEqual(@as(u64, 180_000), d.quiescence_ms);
    try testing.expectEqual(@as(u64, 900_000), d.repeat_ms);
}
