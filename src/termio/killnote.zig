//! What a pane is left looking like after Polter stopped its agent at its
//! kill line (task 1993, #1985 §3.2).
//!
//! **The modes first.** A TUI agent killed with `SIGKILL` -- or one that
//! did not tidy up on `SIGTERM` -- leaves the terminal the way it had it:
//! on the alternate screen, reporting the mouse, bracketing pastes, the
//! cursor hidden, the kitty keyboard protocol pushed. The shell that gets
//! the pane back is then drawn on a screen it did not ask for and sent
//! input it cannot read. `reset` puts back each of those, which is what
//! the shell assumes when it prints its prompt.
//!
//! **Then one line**, faint like a `^C`, on a row of its own: what was
//! stopped and why. Written into the terminal's screen, not into the pty:
//! the shell never reads it. The text is plain -- no control bytes -- so it
//! cannot change a mode itself (`isPlain`, the rule #1970 set for titles).
//!
//! Both are done by the caller under the terminal's lock.

const std = @import("std");
const terminalpkg = @import("../terminal/main.zig");
const Terminal = terminalpkg.Terminal;

/// The modes a stopped agent may have left on, back to what a shell
/// expects.
pub fn reset(t: *Terminal) void {
    if (t.screens.active_key == .alternate) {
        t.switchScreenMode(.@"1049", false) catch {};
    }
    t.modes.set(.alt_screen_save_cursor_clear_enter, false);
    t.modes.set(.alt_screen, false);
    t.modes.set(.alt_screen_legacy, false);
    inline for (.{ .mouse_event_x10, .mouse_event_normal, .mouse_event_button, .mouse_event_any }) |m| {
        t.modes.set(m, false);
    }
    t.flags.mouse_event = .none;
    t.modes.set(.bracketed_paste, false);
    t.modes.set(.cursor_visible, true);
    inline for (.{ .primary, .alternate }) |key| {
        if (t.screens.get(key)) |s| s.kitty_keyboard = .{};
    }
}

/// Write `text` on a row of its own: a new line first unless the cursor
/// is already at the start of one, and a new line after.
pub fn write(t: *Terminal, text: []const u8) void {
    if (t.screens.active.cursor.x != 0) {
        t.carriageReturn();
        t.index() catch return;
    }
    t.setAttribute(.faint) catch {};
    t.printString(text) catch {};
    t.setAttribute(.unset) catch {};
    t.carriageReturn();
    t.index() catch {};
}

/// No control bytes: nothing in it can change the terminal.
pub fn isPlain(text: []const u8) bool {
    for (text) |c| if (c < 0x20 or c == 0x7f) return false;
    return std.unicode.utf8ValidateSlice(text);
}

const testing = std.testing;

test "1993: after a kill the terminal is a shell's again, and the note is on a row of its own" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 10, .max_scrollback_bytes = null });
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("$ claude\r\n");
    // What a TUI agent puts on: the alternate screen, mouse reporting, pastes
    // bracketed, the cursor hidden, the kitty keyboard protocol.
    // The kitty flags on both screens: a TUI may push them before it
    // switches, and the primary screen is the one the shell gets back.
    s.nextSlice("\x1b[>1u\x1b[?1049h\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[?25l\x1b[>5u");
    s.nextSlice("agent screen");
    try testing.expectEqual(.alternate, t.screens.active_key);
    try testing.expect(t.flags.mouse_event != .none);
    try testing.expect(t.modes.get(.bracketed_paste));
    try testing.expect(!t.modes.get(.cursor_visible));
    try testing.expect(t.screens.active.kitty_keyboard.current().int() != 0);
    try testing.expect(t.screens.get(.primary).?.kitty_keyboard.current().int() != 0);

    reset(&t);
    try testing.expectEqual(.primary, t.screens.active_key);
    try testing.expectEqual(.none, t.flags.mouse_event);
    try testing.expect(!t.modes.get(.mouse_event_any));
    try testing.expect(!t.modes.get(.bracketed_paste));
    try testing.expect(t.modes.get(.cursor_visible));
    try testing.expectEqual(@as(u5, 0), t.screens.get(.primary).?.kitty_keyboard.current().int());
    try testing.expectEqual(@as(u5, 0), t.screens.get(.alternate).?.kitty_keyboard.current().int());

    // The shell had printed half a prompt when the note came.
    s.nextSlice("$ ");
    write(&t, "── Polter stopped this pane ──");
    s.nextSlice("$ ");
    const text = try t.screens.get(.primary).?.dumpStringAlloc(testing.allocator, .{ .active = .{} });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("$ claude\n$ \n── Polter stopped this pane ──\n$ ", text);
}

test "1993: the note may not carry a control byte" {
    try testing.expect(isPlain("── Polter 中断了这一格：内存 19.4 GB ──"));
    try testing.expect(!isPlain("bad\x1b[?1049h"));
    try testing.expect(!isPlain("two\nlines"));
    try testing.expect(!isPlain("\xff"));
}
