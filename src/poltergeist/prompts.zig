//! Whether a piece of text a caller handed us looks like an answer to a
//! permission prompt.
//!
//! # What this is for, and what it must never be used for
//!
//! **It labels a log line. It decides nothing.** The switch that governs
//! answering another terminal's prompt (`Bus.Entry.may_authorise`) stops the
//! dedicated tool and the keys that take an option in a box. It cannot stop
//! `terminal_send`, because text plus a return is also how a task is
//! assigned, and the two are the same act at this interface -- so that path
//! stays open and is **recorded** instead. This is the part of the record
//! that says which entries are worth reading first.
//!
//! ⚠️ **The distinction that makes a guess acceptable here.** This program
//! refuses to judge what is on another terminal's screen -- `App.notifyUser`
//! says the supervisor looked and decided, "the program never makes that
//! call itself" -- and `rpc.authorize` refuses to look at a screen before
//! letting a key through, because misjudging there takes ctrl+c away from a
//! supervisor trying to rescue a stuck worker.
//!
//! Neither objection applies to this function, for two separate reasons:
//!
//!   1. **It reads the caller's own request**, the text it just handed over,
//!      not the state of anything belonging to somebody else.
//!   2. **Being wrong costs a log line.** A missed answer is still recorded,
//!      just filed as ordinary; a false hit is one extra candidate to read.
//!      Nobody loses a capability either way.
//!
//! **Whether a guess is allowed depends on what happens when it is wrong**,
//! and that is the whole of the argument for this file existing next to a
//! feature that turned a guess down twice.

const std = @import("std");

/// How likely it is that this send was answering a box.
///
/// Three values, and the third is the one that has to exist: the same code
/// path carries `paste_from_clipboard`, where the text is the clipboard's and
/// this side never sees it. Reporting that as `no` would be a claim nobody
/// made.
pub const CouldAnswer = enum {
    yes,
    no,
    unknown,

    pub fn tag(self: CouldAnswer) []const u8 {
        return switch (self) {
            .yes => "yes",
            .no => "no",
            .unknown => "unknown",
        };
    }
};

/// Whether `text` is, on its own, one of the things a person types at a
/// prompt: a single option number, yes or no, or nothing at all.
///
/// **Deliberately narrow.** `1 -- we need the dependency` is filed as
/// ordinary, and that is the conservative direction: the send is still
/// recorded, it is simply not flagged as a candidate. Widening this to
/// "starts with a digit" would flag a good share of ordinary instructions
/// and turn the flag back into noise, which is the thing it exists to undo.
pub fn couldAnswer(text: []const u8) CouldAnswer {
    const t = std.mem.trim(u8, text, " \t\r\n");

    // Nothing but a return: at a box with an option highlighted, that takes
    // it. It is also what a caller sends to nudge a shell, so it is a
    // candidate rather than a finding -- which is all any of these are.
    if (t.len == 0) return .yes;

    if (t.len == 1 and t[0] >= '1' and t[0] <= '9') return .yes;

    for ([_][]const u8{ "y", "n", "yes", "no" }) |word| {
        if (std.ascii.eqlIgnoreCase(t, word)) return .yes;
    }

    return .no;
}

test "the things a person types at a box" {
    const testing = std.testing;
    for ([_][]const u8{ "1", "3", "9", "y", "n", "Y", "No", "YES", "", "  \n" }) |t| {
        try testing.expectEqual(CouldAnswer.yes, couldAnswer(t));
    }
}

test "an ordinary instruction is not flagged, and that is the safe direction" {
    const testing = std.testing;
    for ([_][]const u8{
        "1 -- we need the dependency",
        "run the tests and report",
        "yes, but check the log first",
        "10",
        "0",
        "task_progress(3, \"done\")",
    }) |t| {
        // ⚠️ **Not flagged is not "not recorded".** The line still goes in
        // the log for every send to a terminal whose switch is off; this
        // only decides whether it is marked as a candidate. Reading this
        // test as "these sends are invisible" is the mistake the module
        // comment is trying to prevent.
        try testing.expectEqual(CouldAnswer.no, couldAnswer(t));
    }
}

test "unknown is a value, because one path cannot see the text" {
    // `paste_from_clipboard` aimed at another terminal writes into its input
    // line exactly as `terminal_send` does, and what it will write is the
    // clipboard's. Filing that as `no` would be an answer nobody had.
    const testing = std.testing;
    try testing.expectEqualStrings("unknown", CouldAnswer.unknown.tag());
    try testing.expectEqualStrings("yes", CouldAnswer.yes.tag());
    try testing.expectEqualStrings("no", CouldAnswer.no.tag());
}
