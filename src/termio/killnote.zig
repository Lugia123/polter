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
//! **Then one line**, faint like a `^C`: what was stopped and why. Written
//! into the terminal's screen, not into the pty: the shell never reads it.
//! The text is plain -- no control bytes -- so it cannot change a mode
//! itself (`isPlain`, the rule #1970 set for titles).
//!
//! **Above the shell's prompt** (P4b). The note comes after the stop has
//! finished, and by then the shell has usually reaped its child and drawn
//! its prompt already: on the alternate screen, which `reset` leaves, or
//! on the primary one, where a note written at the cursor lands under it.
//! Either way the last line was not the prompt, and `cursorIsAtPrompt`
//! said no, so `role_launch in=` refused the pane until somebody pressed
//! return. `put` finds what the shell has drawn of its prompt (`drawn`)
//! and keeps it last: the note goes in above it, and the prompt's rows
//! and the cursor move down together, so the shell's line editor -- which
//! moves the cursor relative to where it left it -- finds things as it
//! left them. Off the alternate screen the rows are copied across with
//! their prompt marks. No byte goes to the shell.
//!
//! What it cannot do: without shell integration it cannot tell how many
//! rows a prompt has, and takes it to be the cursor's row. A prompt of two
//! rows drawn on the alternate screen then loses its first.
//!
//! All of it is done by the caller under the terminal's lock.

const std = @import("std");
const terminalpkg = @import("../terminal/main.zig");
const unicode = @import("../unicode/main.zig");
const Terminal = terminalpkg.Terminal;
const Screen = terminalpkg.Screen;
const SemanticContent = terminalpkg.page.Cell.SemanticContent;

/// The modes put back, then `text` written above whatever the shell has
/// already drawn of its prompt. `text` is left out unless it `isPlain`.
pub fn put(t: *Terminal, text: []const u8) void {
    const from_alternate: ?Drawn = if (t.screens.active_key == .alternate) drawn(t.screens.active) else null;
    const was_alternate = t.screens.active_key == .alternate;
    reset(t);
    if (!isPlain(text)) return;
    if (was_alternate) {
        write(t, text);
        if (from_alternate) |d| copyFromAlternate(t, d);
        return;
    }
    if (drawn(t.screens.active)) |d| above(t, d, text) else write(t, text);
}

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
    // A full-screen program's scrolling region and origin mode: the rows
    // `above` moves are counted from the top of the screen.
    t.modes.set(.origin, false);
    t.modes.set(.enable_left_and_right_margin, false);
    t.scrolling_region = .{ .top = 0, .bottom = t.rows - 1, .left = 0, .right = t.cols - 1 };
}

/// Write `text` on a row of its own: a new line first unless the cursor
/// is already at the start of one, and a new line after.
pub fn write(t: *Terminal, text: []const u8) void {
    if (t.screens.active.cursor.x != 0) {
        t.carriageReturn();
        t.index() catch return;
    }
    faint(t, text);
    t.carriageReturn();
    t.index() catch {};
}

/// No control bytes: nothing in it can change the terminal.
pub fn isPlain(text: []const u8) bool {
    for (text) |c| if (c < 0x20 or c == 0x7f) return false;
    return std.unicode.utf8ValidateSlice(text);
}

/// What the shell has drawn of its prompt: from the prompt's first row
/// down to the cursor's, in the active area, and where in it the cursor is.
const Drawn = struct {
    top: usize,
    cursor_y: usize,
    cursor_x: usize,
    pending_wrap: bool,
    content: SemanticContent,
    clear_eol: bool,

    fn rows(self: Drawn) usize {
        return self.cursor_y - self.top + 1;
    }
};

/// Null when there is no prompt yet: the cursor on output at the start of
/// a row. With shell integration the prompt's first row is its mark, as
/// `Screen.clearPromptForRedraw` finds it for a resize; without it, a
/// cursor past the start of a row is taken to be on a one-row prompt.
fn drawn(s: *Screen) ?Drawn {
    const c = &s.cursor;
    const marked = c.semantic_content != .output or c.page_row.semantic_prompt != .none;
    if (!marked and c.x == 0) return null;
    const top: usize = top: {
        if (!marked) break :top c.y;
        var it = c.page_pin.promptIterator(.left_up, null);
        const start = it.next() orelse break :top c.y;
        // Taller than the screen: what is still on it.
        const pt = s.pages.pointFromPin(.active, start) orelse break :top 0;
        break :top @min(pt.active.y, c.y);
    };
    return .{
        .top = top,
        .cursor_y = c.y,
        .cursor_x = c.x,
        .pending_wrap = c.pending_wrap,
        .content = c.semantic_content,
        .clear_eol = c.semantic_content_clear_eol,
    };
}

/// The note in rows inserted above the prompt, the screen scrolled first
/// if the prompt is too near the bottom for them.
fn above(t: *Terminal, d: Drawn, text: []const u8) void {
    const n = rowsOf(text, t.cols);
    const room = t.rows - 1 - d.cursor_y;
    const up = n -| room;
    if (up > 0) {
        t.setCursorPos(t.rows, 1);
        for (0..up) |_| t.index() catch return;
    }
    const top = d.top -| up;
    t.setCursorPos(top + 1, 1);
    t.insertLines(n);
    faint(t, text);
    land(t, d, d.cursor_y - up + n);
}

/// The prompt's rows from the alternate screen, under the note `write`
/// has just put on the primary one, prompt marks and all.
fn copyFromAlternate(t: *Terminal, d: Drawn) void {
    const alt = t.screens.get(.alternate) orelse return;
    const s = t.screens.active;
    for (0..d.rows()) |i| {
        if (i > 0) {
            t.carriageReturn();
            t.index() catch return;
        }
        const from = alt.pages.pin(.{ .active = .{ .y = @intCast(d.top + i) } }) orelse return;
        _ = s.clonePartialRowGrowCapacity(s.cursor.page_pin.node, s.cursor.page_pin.y, from.node.page(), from.rowAndCell().row, 0, t.cols);
        s.cursorReload();
        s.cursor.page_row.dirty = true;
    }
    land(t, d, s.cursor.y);
}

/// The cursor back where the shell left it in its prompt, on row `y`.
fn land(t: *Terminal, d: Drawn, y: usize) void {
    t.setCursorPos(y + 1, d.cursor_x + 1);
    const c = &t.screens.active.cursor;
    c.pending_wrap = d.pending_wrap;
    c.semantic_content = d.content;
    c.semantic_content_clear_eol = d.clear_eol;
}

/// `text` at the cursor, faint, as output: no prompt mark on the note.
fn faint(t: *Terminal, text: []const u8) void {
    const c = &t.screens.active.cursor;
    const content = c.semantic_content;
    const clear_eol = c.semantic_content_clear_eol;
    c.semantic_content = .output;
    c.semantic_content_clear_eol = false;
    t.setAttribute(.faint) catch {};
    t.printString(text) catch {};
    t.setAttribute(.unset) catch {};
    c.semantic_content = content;
    c.semantic_content_clear_eol = clear_eol;
}

/// How many rows `text` takes in `cols` columns, a wide character that
/// does not fit at the end of a row going to the next, as `print` does.
fn rowsOf(text: []const u8, cols: usize) usize {
    var rows: usize = 1;
    var x: usize = 0;
    const view = std.unicode.Utf8View.init(text) catch return 1;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const w = unicode.codepointWidth(cp);
        if (w == 0) continue;
        if (x + w > cols) {
            rows += 1;
            x = 0;
        }
        x += w;
    }
    return rows;
}

const testing = std.testing;

fn activeText(t: *Terminal) ![]const u8 {
    return t.screens.active.dumpStringAlloc(testing.allocator, .{ .active = .{} });
}

test "1993: after a kill the terminal is a shell's again" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 10, .max_scrollback_bytes = null });
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("$ claude\r\n");
    // What a TUI agent puts on: the alternate screen, mouse reporting, pastes
    // bracketed, the cursor hidden, the kitty keyboard protocol, a
    // scrolling region.
    // The kitty flags on both screens: a TUI may push them before it
    // switches, and the primary screen is the one the shell gets back.
    s.nextSlice("\x1b[>1u\x1b[?1049h\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[?25l\x1b[>5u\x1b[2;8r");
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
    try testing.expectEqual(@as(usize, 9), t.scrolling_region.bottom);
}

// A shell with integration, as zsh is given it: prompt, input, output.
const prompt_mark = "\x1b]133;A\x07";
const input_mark = "\x1b]133;B\x07";
const output_mark = "\x1b]133;C\x07";

test "1993: a note on a prompt that is not there yet goes on its own row, the prompt under it" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 10, .max_scrollback_bytes = null });
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(prompt_mark ++ "web % " ++ input_mark ++ "claude\r\n" ++ output_mark ++ "working\r\n");
    put(&t, "── Polter stopped this pane ──");
    s.nextSlice("zsh: terminated\r\n" ++ prompt_mark ++ "web % " ++ input_mark);
    const text = try activeText(&t);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("web % claude\nworking\n── Polter stopped this pane ──\nzsh: terminated\nweb % ", text);
    try testing.expect(t.cursorIsAtPrompt());
}

test "1993: a note after the shell drew its prompt goes above it, the prompt last and still a prompt" {
    // Six rows: the prompt is on the bottom one, so the screen scrolls for
    // the note.
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 6, .max_scrollback_bytes = null });
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(prompt_mark ++ "web % " ++ input_mark ++ "claude\r\n" ++ output_mark ++ "a\r\nb\r\nc\r\n");
    s.nextSlice("zsh: terminated\r\n" ++ prompt_mark ++ "web % " ++ input_mark);
    put(&t, "── Polter stopped this pane ──");
    {
        const text = try activeText(&t);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings("a\nb\nc\nzsh: terminated\n── Polter stopped this pane ──\nweb % ", text);
    }
    // What `role_launch in=` asks (`Surface.isAtShellPrompt`).
    try testing.expect(t.cursorIsAtPrompt());
    // The shell carries on from where it left the cursor.
    s.nextSlice("x");
    const text = try activeText(&t);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("a\nb\nc\nzsh: terminated\n── Polter stopped this pane ──\nweb % x", text);
}

test "1993: a note of two rows goes above a prompt of two rows" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 10, .max_scrollback_bytes = null });
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(prompt_mark ++ "~/web\r\n% " ++ input_mark ++ "claude\r\n" ++ output_mark ++ "working\r\n");
    s.nextSlice(prompt_mark ++ "~/web\r\n% " ++ input_mark);
    // Eleven wide characters and an `x`: ten fill a row of twenty columns,
    // the rest is a second.
    put(&t, "中断了这一格中断了这一x");
    s.nextSlice("x");
    const text = try activeText(&t);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("~/web\n% claude\nworking\n中断了这一格中断了这\n一x\n~/web\n% x", text);
    try testing.expect(t.cursorIsAtPrompt());
}

test "1993: without shell integration the cursor's row is taken for the prompt" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 10, .max_scrollback_bytes = null });
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("$ claude\r\nworking\r\nzsh: terminated\r\n$ ");
    put(&t, "── Polter stopped this pane ──");
    s.nextSlice("x");
    const text = try activeText(&t);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("$ claude\nworking\nzsh: terminated\n── Polter stopped this pane ──\n$ x", text);
}

test "1993: a prompt drawn on the alternate screen is brought to the primary one under the note, marks and colour and all" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 10, .max_scrollback_bytes = null });
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(prompt_mark ++ "web % " ++ input_mark ++ "claude\r\n" ++ output_mark);
    s.nextSlice("\x1b[?1049h\x1b[Hagent screen\r\n\r\n");
    // The agent is gone; the shell draws on the screen it finds.
    s.nextSlice("zsh: terminated\r\n" ++ prompt_mark ++ "\x1b[32mweb %\x1b[0m " ++ input_mark);
    put(&t, "── Polter stopped this pane ──");
    try testing.expectEqual(.primary, t.screens.active_key);
    {
        const text = try activeText(&t);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings("web % claude\n── Polter stopped this pane ──\nweb % ", text);
    }
    try testing.expect(t.cursorIsAtPrompt());
    const prompt_row = t.screens.active.pages.pin(.{ .active = .{ .y = 2 } }).?;
    try testing.expectEqual(.prompt, prompt_row.rowAndCell().row.semantic_prompt);
    const first = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 2 } }).?;
    try testing.expect(first.style().fg_color == .palette);
    s.nextSlice("x");
    const text = try activeText(&t);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("web % claude\n── Polter stopped this pane ──\nweb % x", text);
}

test "1993: the note may not carry a control byte" {
    try testing.expect(isPlain("── Polter 中断了这一格：内存 19.4 GB ──"));
    try testing.expect(!isPlain("bad\x1b[?1049h"));
    try testing.expect(!isPlain("two\nlines"));
    try testing.expect(!isPlain("\xff"));
}
