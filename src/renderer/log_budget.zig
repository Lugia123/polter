//! A bounded budget for instrumentation lines.
//!
//! Diagnostic logging that fires per frame has to be capped or it drowns the
//! log, but a cap that is a file-level `var` is shared by every renderer in
//! the process: the first surface to draw spends the whole budget and every
//! later surface is silent from birth. That is not a smaller log, it is a
//! log about the wrong object -- and a reader who filters for the surface
//! they care about sees an empty result that is indistinguishable from "that
//! code never ran".
//!
//! So the budget lives on the renderer, one per instance.

const std = @import("std");

/// A counter that permits the first `max` calls and refuses the rest.
///
/// Zero-initialized, so a renderer gets its own full budget simply by
/// having one of these as a field.
pub const LogBudget = struct {
    /// How many times `take` has returned true.
    spent: usize = 0,

    /// How many are allowed. Zero means "never log".
    max: usize,

    /// Consume one unit of budget. Returns true if the caller should log.
    ///
    /// Once exhausted this always returns false and `spent` stops growing,
    /// so it cannot wrap however long the process runs.
    pub fn take(self: *LogBudget) bool {
        if (self.spent >= self.max) return false;
        self.spent += 1;
        return true;
    }

    /// True if there is budget left, without consuming any.
    pub fn hasRoom(self: *const LogBudget) bool {
        return self.spent < self.max;
    }
};

/// Whether a running count of dropped/failed events should produce a line.
///
/// The first one always speaks -- the transition from "fine" to "not fine"
/// is the event worth seeing -- and after that one line per `every`, so a
/// sustained failure keeps saying so without becoming the log.
pub fn shouldReport(count: u64, every: u64) bool {
    if (count == 0) return false;
    if (count == 1) return true;
    return count % every == 0;
}

test "LogBudget permits exactly max" {
    const testing = std.testing;
    var b: LogBudget = .{ .max = 3 };
    try testing.expect(b.take());
    try testing.expect(b.take());
    try testing.expect(b.take());
    try testing.expect(!b.take());
    try testing.expect(!b.take());
    try testing.expectEqual(@as(usize, 3), b.spent);
}

test "LogBudget instances do not share" {
    const testing = std.testing;
    var a: LogBudget = .{ .max = 1 };
    var b: LogBudget = .{ .max = 1 };
    try testing.expect(a.take());
    try testing.expect(!a.take());

    // The whole point: `a` exhausting its budget must not silence `b`.
    try testing.expect(b.hasRoom());
    try testing.expect(b.take());
}

test "LogBudget with a zero max never speaks" {
    const testing = std.testing;
    var b: LogBudget = .{ .max = 0 };
    try testing.expect(!b.hasRoom());
    try testing.expect(!b.take());
}

test "shouldReport speaks on the first and then every nth" {
    const testing = std.testing;

    // Nothing has failed yet, so there is nothing to say.
    try testing.expect(!shouldReport(0, 64));

    // The transition into failure always speaks.
    try testing.expect(shouldReport(1, 64));

    // The ones in between do not.
    try testing.expect(!shouldReport(2, 64));
    try testing.expect(!shouldReport(63, 64));

    // And then one line per period, indefinitely.
    try testing.expect(shouldReport(64, 64));
    try testing.expect(!shouldReport(65, 64));
    try testing.expect(shouldReport(128, 64));
}
