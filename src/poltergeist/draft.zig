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
//! It errs towards believing there is a draft: typing into a full-screen
//! program that has no input line at all leaves this set.
//!
//! **Backspacing a line empty clears it, but only when that can be known.**
//! It used to leave it set "because nothing here counts characters", and
//! the cost was measured on the Windows machine (2026-10-13): one `x`, one
//! backspace, an empty line on screen, and a notice about a worker stopped
//! on an approval held back for four minutes and fourteen seconds -- until
//! somebody happened to press return there. So characters are counted, for
//! as long as counting is sound: nothing but characters typed at the end
//! of the line and plain backspaces. The first key that could have put
//! text in the line unseen, or moved where a backspace lands -- tab, an
//! arrow, a history chord, a pasted line break -- ends the counting until
//! a return, and from then on it is the old rule (`Draft.exact`).
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

    /// How many characters the line is known to hold at most. Only read
    /// while `exact`.
    ///
    /// **At most, and that is the direction it may be wrong in.** It counts
    /// code points, and one backspace takes off one: a character made of
    /// several is deleted by a single backspace and leaves the count high,
    /// which says "still a draft" about an empty line -- a late message. A
    /// count that ran low would say "empty" about a line with text in it,
    /// which is the defect this file exists for.
    typed: u32 = 0,

    /// Whether `typed` can be believed: since the line was last empty,
    /// nothing has reached it but characters and plain backspaces. False
    /// from the first key that could have changed the line in a way this
    /// cannot count, until the line is submitted or abandoned.
    exact: bool = true,

    /// The line is the program's again: submitted, or abandoned.
    fn empty(self: *Draft) void {
        self.* = .{};
    }

    /// Text went into the line.
    fn added(self: *Draft, utf8: []const u8) void {
        self.outstanding = true;
        self.typed +|= characters(utf8);
    }

    /// Something happened to the line that cannot be counted. It says
    /// nothing about whether there is a draft, only that a run of
    /// backspaces can no longer prove there is none.
    fn uncounted(self: *Draft) void {
        self.exact = false;
    }

    /// There is text in the line and nothing is known about how much: what
    /// a caller says when it put the text there itself and the return that
    /// should have submitted it did not arrive.
    pub fn left(self: *Draft) void {
        self.outstanding = true;
        self.exact = false;
    }

    /// Fold one key event into the answer.
    ///
    /// **Only presses.** A release is not somebody typing, and the burst of
    /// synthetic releases a window sends when it loses focus is the exact
    /// noise the ten-second guard admits and complains about in its own
    /// comment. Nothing here is set by a modifier on its own either: this
    /// signal is narrower than the clock beside it, not another copy of it.
    pub fn note(self: *Draft, event: inputpkg.KeyEvent) void {
        // **A held key counts.** This asked for presses only, and a held
        // letter is one press and then repeats: four characters in the line
        // and one in the count would let a single backspace say "empty".
        if (event.action == .release) return;

        // Submitted. Whatever was in the line has been handed to the
        // program, and the line is the program's business again.
        switch (event.key) {
            .enter, .numpad_enter => {
                self.empty();
                return;
            },
            else => {},
        }

        // A modifier on its own puts nothing in the line and moves nothing.
        if (event.key.modifier()) return;

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
                self.empty();
                return;
            },
            else => {},
        };

        // **A chord is a command to the line, not text in it.** macOS hands
        // ctrl+l, ctrl+r, ctrl+a ... an `utf8` of the plain letter (the
        // control character is stripped on purpose, see `ghosttyCharacters`),
        // so without this line each of them marked the terminal as holding
        // an unsubmitted draft -- and since only return, ctrl+c, ctrl+u or
        // ctrl+d clear it, a tab where somebody pressed ctrl+l once refused
        // every role picked from its menu for good (#1202). Moving around a
        // line, searching history or clearing the screen adds nothing to it.
        // ctrl with alt is AltGr on Windows, and that types real text.
        //
        // **But it may have changed the line all the same** -- ctrl+y puts
        // back what was killed, ctrl+r brings a line out of history, ctrl+w
        // takes a word -- so the count stops being something to believe.
        if ((event.mods.ctrl and !event.mods.alt) or event.mods.super) {
            self.uncounted();
            return;
        }

        // A key that is being composed with belongs to the input method:
        // its backspace takes a letter out of the candidate, not out of the
        // line. What the composition commits arrives through `noteText` and
        // is counted there; until then the candidate is text in front of
        // the person all the same, and says so as it always has.
        if (event.composing) {
            if (printable(event.utf8)) self.outstanding = true;
            return;
        }

        // One character off the end -- if the end is where it lands and the
        // count is the line. Alt makes it a word; that is not one.
        if (event.key == .backspace) {
            if (event.mods.alt) {
                self.uncounted();
                return;
            }
            if (!self.outstanding or !self.exact) return;
            self.typed -|= 1;
            if (self.typed == 0) self.empty();
            return;
        }

        // Something was typed. `utf8` is what the key generated, so this is
        // the same fact the program itself received -- and it is checked for
        // a printable byte rather than merely being non-empty, because
        // return arrives carrying "\r" and arrow keys carry escape
        // sequences. Continuation bytes of a multi-byte character are
        // >= 0x80 and count, which is the point: a character is a character
        // whatever alphabet it is in.
        if (printable(event.utf8)) {
            self.added(event.utf8);
            return;
        }

        // A key the layout could not name and that typed nothing: what an
        // input method's own keystrokes look like on the way past. Nothing
        // is known and nothing is concluded.
        if (event.key == .unidentified) return;

        // **Everything else may have changed the line unseen, or moved
        // where the next backspace lands**: tab completes, the arrows walk
        // through history and along the line, delete takes the character
        // ahead. None of them says there is a draft -- that would be #1202
        // again -- only that backspaces can no longer prove there is none.
        self.uncounted();
    }

    /// Text put into the line without a key event: a paste, an input
    /// method's committed text, dictation, the emoji picker.
    ///
    /// **These never reached `note`**, so a line written entirely through
    /// an input method -- every line of Chinese -- was no draft at all as
    /// far as this could tell, and a notice was typed onto the end of it
    /// (measured on the Windows machine, 2026-10-13: `echo half-a-line`
    /// went in through the input method, and the log has no "unsubmitted
    /// text" line for it).
    ///
    /// Text that ends in a line break is taken as submitted: a shell with
    /// bracketed paste off runs it on arrival. Anything else printable is
    /// sitting in the line.
    pub fn noteText(self: *Draft, text: []const u8) void {
        if (text.len == 0) return;
        const last = text[text.len - 1];
        if (last == '\r' or last == '\n') {
            self.empty();
            return;
        }
        if (!printable(text)) return;
        self.added(text);
        // Several lines, a tab, an escape: what the program makes of those
        // is its own business, and it is not "one character each".
        for (text) |b| if (b < 0x20 or b == 0x7f) {
            self.uncounted();
            break;
        };
    }

    /// How many characters a backspace each would be needed for, at most:
    /// code points, leaving out what is not text.
    fn characters(utf8: []const u8) u32 {
        var n: u32 = 0;
        for (utf8) |b| {
            if (b < 0x20 or b == 0x7f) continue;
            // A continuation byte is part of the character before it.
            if (b & 0xc0 == 0x80) continue;
            n +|= 1;
        }
        return n;
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

test "a control chord is a command to the line, not text in it (#1202)" {
    var d: Draft = .{};
    // ctrl+l, ctrl+r, ctrl+a as macOS delivers them: the plain letter.
    for ([_]inputpkg.Key{ .key_l, .key_r, .key_a, .key_e, .key_w }) |k| {
        d.note(.{ .action = .press, .key = k, .mods = .{ .ctrl = true }, .utf8 = "x" });
    }
    try std.testing.expect(!d.outstanding);
    // AltGr arrives as ctrl+alt and types a character.
    d.note(.{ .action = .press, .key = .key_q, .mods = .{ .ctrl = true, .alt = true }, .utf8 = "@" });
    try std.testing.expect(d.outstanding);
    d = .{};
    // Typed text on top of them is still a draft.
    d.note(typed("h"));
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

test "notice delivery: text that did not come through a key is a draft too" {
    // An input method's committed text, a paste: no key event carries it.
    var d: Draft = .{};
    d.noteText("echo half-a-line");
    try std.testing.expect(d.outstanding);
    // The return that submits it is a key, and clears it as ever.
    d.note(.{ .action = .press, .key = .enter, .utf8 = "\r" });
    try std.testing.expect(!d.outstanding);

    // Chinese, which only ever arrives this way.
    d.noteText("\xe4\xbd\xa0\xe5\xa5\xbd");
    try std.testing.expect(d.outstanding);

    // Pasted with its line break: the shell ran it.
    d.noteText("ls -la\n");
    try std.testing.expect(!d.outstanding);

    // Nothing, and nothing printable, is not a draft.
    d.noteText("");
    d.noteText("\x1b[A");
    try std.testing.expect(!d.outstanding);
}

fn pressed(key: inputpkg.Key, mods: inputpkg.Mods) inputpkg.KeyEvent {
    return .{ .action = .press, .key = key, .mods = mods };
}

test "a line typed and backspaced empty is no draft" {
    // The Windows machine, 2026-10-13: one `x`, one backspace, and a notice
    // held back for four minutes behind an empty line.
    var d: Draft = .{};
    d.note(typed("x"));
    try std.testing.expect(d.outstanding);
    d.note(pressed(.backspace, .{}));
    try std.testing.expect(!d.outstanding);

    // As many backspaces as characters, and not one fewer.
    d.note(typed("a"));
    d.note(typed("b"));
    d.note(typed("c"));
    d.note(pressed(.backspace, .{}));
    d.note(pressed(.backspace, .{}));
    try std.testing.expect(d.outstanding);
    d.note(pressed(.backspace, .{}));
    try std.testing.expect(!d.outstanding);

    // A backspace at an empty line is nothing, and leaves the next line
    // countable.
    d.note(pressed(.backspace, .{}));
    d.note(typed("y"));
    d.note(pressed(.backspace, .{}));
    try std.testing.expect(!d.outstanding);
}

test "a held key is as many characters as it repeated" {
    var d: Draft = .{};
    d.note(typed("a"));
    var again = typed("a");
    again.action = .repeat;
    d.note(again);
    d.note(again);
    d.note(pressed(.backspace, .{}));
    try std.testing.expect(d.outstanding);
    var held = pressed(.backspace, .{});
    held.action = .repeat;
    d.note(held);
    try std.testing.expect(d.outstanding);
    d.note(held);
    try std.testing.expect(!d.outstanding);
}

test "text that came without keys is counted by its characters" {
    var d: Draft = .{};
    // Two characters, six bytes: an input method's commit.
    d.noteText("\u{4f60}\u{597d}");
    d.note(pressed(.backspace, .{}));
    try std.testing.expect(d.outstanding);
    d.note(pressed(.backspace, .{}));
    try std.testing.expect(!d.outstanding);

    // A paste and a typed character after it.
    d.noteText("ab");
    d.note(typed("c"));
    d.note(pressed(.backspace, .{}));
    d.note(pressed(.backspace, .{}));
    try std.testing.expect(d.outstanding);
    d.note(pressed(.backspace, .{}));
    try std.testing.expect(!d.outstanding);
}

test "backspaces prove nothing once the line could have changed unseen" {
    // Each of these can put text in the line, take an unknown amount out,
    // or move where a backspace lands. After one, only a return clears.
    const unseen = [_]inputpkg.KeyEvent{
        pressed(.tab, .{}), // completion
        pressed(.arrow_up, .{}), // history
        pressed(.arrow_left, .{}), // the backspace lands elsewhere
        pressed(.arrow_right, .{}), // accepts a suggestion
        pressed(.delete, .{}),
        pressed(.home, .{}),
        pressed(.key_y, .{ .ctrl = true }), // yank
        pressed(.key_r, .{ .ctrl = true }), // history search
        pressed(.backspace, .{ .alt = true }), // a word
    };
    for (unseen) |key| {
        var d: Draft = .{};
        d.note(typed("g"));
        d.note(typed("i"));
        d.note(key);
        d.note(pressed(.backspace, .{}));
        d.note(pressed(.backspace, .{}));
        d.note(pressed(.backspace, .{}));
        try std.testing.expect(d.outstanding);
        // And before anything was typed, the same: a line recalled from
        // history is not emptied by deleting the one character typed after.
        var e: Draft = .{};
        e.note(key);
        try std.testing.expect(!e.outstanding);
        e.note(typed("x"));
        e.note(pressed(.backspace, .{}));
        try std.testing.expect(e.outstanding);
        // A return is still what clears it, and counting starts over.
        e.note(pressed(.enter, .{}));
        try std.testing.expect(!e.outstanding);
        e.note(typed("x"));
        e.note(pressed(.backspace, .{}));
        try std.testing.expect(!e.outstanding);
    }

    // A paste with a line break inside it.
    var d: Draft = .{};
    d.noteText("one\ntwo");
    for (0..16) |_| d.note(pressed(.backspace, .{}));
    try std.testing.expect(d.outstanding);

    // Text a caller left there itself.
    var l: Draft = .{};
    l.left();
    l.note(typed("x"));
    l.note(pressed(.backspace, .{}));
    try std.testing.expect(l.outstanding);
}

test "a modifier, a key being composed with, and a key that typed nothing leave the count alone" {
    var d: Draft = .{};
    d.note(typed("a"));
    // Shift going down before the next letter is not "something unseen".
    d.note(pressed(.shift_left, .{ .shift = true }));
    d.note(typed("B"));
    // The input method's own backspace takes a letter out of the candidate.
    var composing = pressed(.backspace, .{});
    composing.composing = true;
    d.note(composing);
    d.note(composing);
    try std.testing.expect(d.outstanding);
    // The candidate itself is something half-written, and is not counted.
    var candidate = typed("ni");
    candidate.composing = true;
    d.note(candidate);
    d.note(.{ .action = .press, .key = .unidentified });
    d.note(pressed(.backspace, .{}));
    try std.testing.expect(d.outstanding);
    d.note(pressed(.backspace, .{}));
    try std.testing.expect(!d.outstanding);
}
