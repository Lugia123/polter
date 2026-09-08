//! Whether the person at a terminal has something half-written in front of
//! them.
//!
//! # The gap this fills, and it is a gap in a guard that already exists
//!
//! `Surface.typePoltergeistText` has refused to type into a terminal
//! somebody is using for as long as there has been anything to type. What
//! it asks is **how long ago a key reached this surface**, and the refusal
//! says so in the words of the measurement:
//!
//!     UserPresent: a key reached that terminal within the last ten
//!     seconds, so nothing was typed into it ... This says a key arrived
//!     and nothing more -- not who sent it, not that anyone is there, and
//!     **nothing about what is in the input line, which this never reads.**
//!
//! That last clause is the defect, reported by the user, who meets it
//! daily: **type half a sentence, stop to think for eleven seconds, and the
//! window has passed.** The guard lets the notice through, it lands inside
//! the half-sentence, and the return at the end of it submits the lot.
//!
//! # Why this does not read the input line, which is what it is named after
//!
//! Three reasons, and none of them is squeamishness about reading somebody's
//! text -- the first two are written on the guard itself:
//!
//!   1. **The prompt is indistinguishable from a draft.** An agent CLI draws
//!      its own prompt, so the cursor sits past column zero with nothing
//!      typed. A cursor test would defer every notice forever.
//!   2. **The lock.** The guard runs on a thread that does not hold the
//!      renderer lock, and reading screen state from there is not safe.
//!   3. **Semantic prompts are empty exactly where they are needed.** The
//!      terminal does track OSC 133 (`Screen.semantic_prompt`), which would
//!      say where the input begins -- but only if the program emits it, and
//!      the agent CLIs this defect was reported against do not. `seen` is
//!      false in precisely the case that matters.
//!
//! So the question is answered where the answer already passes by: **the key
//! events themselves**, in `Surface.keyCallback`, a few lines from where the
//! clock the old guard reads is stamped.
//!
//! # What it costs, and why that is the acceptable direction
//!
//! It errs towards believing there is a draft. Backspacing a line empty
//! leaves this set, because nothing here counts characters; so does typing
//! into a full-screen program that has no input line at all.
//!
//! **The cost of a wrong `true` is a late message. The cost of a wrong
//! `false` is the defect the user reported.** And a wrong `true` does not
//! lose anything, because of what the two senders do with the refusal:
//!
//!   * A **timer notice** is dropped and said again on the next sample, so
//!     a terminal left overnight with half a line in it is told the moment
//!     somebody presses return -- not never.
//!   * A **caller's text** (`terminal_send`, and the task-panel
//!     notifications built on it) is refused synchronously with
//!     `UserPresent`, and the panel is left unchanged. **The supervisor is
//!     told, at the call, that nothing was said.**
//!
//! So the residue is one thing only: a terminal whose input line holds an
//! abandoned half-line refuses every `task_assign` until somebody presses
//! return or ctrl+c at it. **That is visible rather than silent** -- the
//! supervisor sees the refusal every time -- which is what makes it
//! acceptable rather than merely cheap.

const std = @import("std");
const inputpkg = @import("../input.zig");

/// One terminal's answer to "is there something half-written here".
pub const Draft = struct {
    /// Whether text has been typed that has not been submitted or abandoned.
    outstanding: bool = false,

    /// Fold one key event into the answer.
    ///
    /// **Only presses.** A release is not somebody typing, and the burst of
    /// synthetic releases a window sends when it loses focus is the exact
    /// noise the ten-second guard admits and complains about in its own
    /// comment. Nothing here is set by a modifier on its own either: this
    /// signal is narrower than the clock beside it, not another copy of it.
    pub fn note(self: *Draft, event: inputpkg.KeyEvent) void {
        if (event.action != .press) return;

        // Submitted. Whatever was in the line has been handed to the
        // program, and the line is the program's business again.
        switch (event.key) {
            .enter, .numpad_enter => {
                self.outstanding = false;
                return;
            },
            else => {},
        }

        // Abandoned. These three are what a person actually presses to get
        // rid of a line they have decided against: interrupt, kill-line,
        // end-of-input.
        //
        // **Escape is deliberately not here.** In an agent CLI it discards
        // the draft, and in an editor it leaves insert mode with every
        // word still on the screen -- and this cannot tell the two apart.
        // Guessing wrong costs a late message in one direction and the
        // reported defect in the other, so it does not guess.
        if (event.mods.ctrl) switch (event.key) {
            .key_c, .key_u, .key_d => {
                self.outstanding = false;
                return;
            },
            else => {},
        };

        // Something was typed. `utf8` is what the key generated, so this is
        // the same fact the program itself received -- and it is checked for
        // a printable byte rather than merely being non-empty, because
        // return arrives carrying "\r" and arrow keys carry escape
        // sequences. Continuation bytes of a multi-byte character are
        // >= 0x80 and count, which is the point: a character is a character
        // whatever alphabet it is in.
        if (printable(event.utf8)) self.outstanding = true;
    }

    fn printable(utf8: []const u8) bool {
        // **An escape sequence is not typed text, and it is full of
        // printable bytes.** `\x1b[D` ends in `[` and `D`, so a scan for a
        // printable byte says yes to an arrow key -- which is somebody
        // moving around a line, not adding to one. The test below caught
        // this, and it is kept as a guard rather than deleted: Ghostty hands
        // an arrow key an empty `utf8` today, so nothing in the tree
        // currently arrives in this shape, and that is exactly the kind of
        // thing that changes without anyone thinking about this function.
        if (utf8.len > 0 and utf8[0] == 0x1b) return false;

        for (utf8) |b| if (b >= 0x20 and b != 0x7f) return true;
        return false;
    }
};

// -- tests -------------------------------------------------------------------

fn typed(comptime utf8: []const u8) inputpkg.KeyEvent {
    return .{ .action = .press, .key = .unidentified, .utf8 = utf8 };
}

test "text typed and not submitted is outstanding" {
    var d: Draft = .{};
    try std.testing.expect(!d.outstanding);
    d.note(typed("h"));
    d.note(typed("a"));
    d.note(typed("l"));

    // **No clock anywhere in this type**, which is the whole point: eleven
    // seconds after the last of those three, the ten-second guard beside
    // this one has stopped objecting and this one has not. That gap is the
    // defect this was written for.
    try std.testing.expect(d.outstanding);
}

test "return clears it, because the line went to the program" {
    var d: Draft = .{};
    d.note(typed("h"));
    try std.testing.expect(d.outstanding);
    d.note(.{ .action = .press, .key = .enter, .utf8 = "\r" });
    try std.testing.expect(!d.outstanding);
}

test "the three abandon chords clear it" {
    for ([_]inputpkg.Key{ .key_c, .key_u, .key_d }) |k| {
        var d: Draft = .{};
        d.note(typed("h"));
        try std.testing.expect(d.outstanding);
        d.note(.{ .action = .press, .key = k, .mods = .{ .ctrl = true } });
        try std.testing.expect(!d.outstanding);
    }

    // Without the modifier they are letters, and letters are a draft.
    var d: Draft = .{};
    d.note(typed("c"));
    try std.testing.expect(d.outstanding);
}

test "what the clock beside it counts and this does not" {
    // **This is the test that says the new signal is not the old one with a
    // longer window.** Every event here marks the surface as far as
    // `last_key_time` is concerned -- its own comment lists them as the
    // reason the measurement is narrower than its name. None of them is
    // somebody writing a sentence.
    var d: Draft = .{};

    // A modifier held on its own, pressed and released.
    d.note(.{ .action = .press, .key = .shift_left, .mods = .{ .shift = true } });
    d.note(.{ .action = .release, .key = .shift_left });
    try std.testing.expect(!d.outstanding);

    // Letting go of a key that was typed before this terminal was watched.
    d.note(.{ .action = .release, .key = .key_a, .utf8 = "a" });
    try std.testing.expect(!d.outstanding);

    // The burst of synthetic releases a window sends when it loses focus --
    // which is how holding cmd to switch *away* marks the terminal you left.
    for ([_]inputpkg.Key{ .meta_left, .shift_left, .key_a, .enter }) |k| {
        d.note(.{ .action = .release, .key = k });
    }
    try std.testing.expect(!d.outstanding);

    // And the keys that move around a line without adding to it. Ghostty
    // gives an arrow key no text at all, so the first form is the real one;
    // the second is the same key wearing the sequence it turns into further
    // down, and it is here because a scan for "any printable byte" says yes
    // to it -- `[` and `D` are printable. That is what this test found.
    d.note(.{ .action = .press, .key = .arrow_left });
    d.note(.{ .action = .press, .key = .arrow_left, .utf8 = "\x1b[D" });
    d.note(.{ .action = .press, .key = .backspace, .utf8 = "\x7f" });
    try std.testing.expect(!d.outstanding);
}
