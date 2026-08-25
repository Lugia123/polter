//! Turning messages into the rows a pane actually draws.
//!
//! Kept apart from the drawing so it can be tested without a terminal: the
//! bugs this file exists to fix were all invisible until somebody looked at
//! a screen, and a screen is the one thing a test cannot have.
//!
//! **Wrapping is ours, not the terminal's.** Letting the cell writer wrap a
//! long line means it silently occupies more rows than the caller counted,
//! and a pane drawn bottom-up then writes the next message on top of the
//! overflow. That is what put interleaved fragments of three messages on
//! one line in the first version.
//!
//! Width is measured in **display columns**, not bytes and not codepoints:
//! a CJK character occupies two columns, so a line of Chinese fits half as
//! many characters as its byte length suggests.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// What a row of the message pane holds.
pub const Row = struct {
    text: []const u8,
    kind: Kind,

    /// Which message this came from, so a click can be traced back.
    message: usize,

    pub const Kind = enum {
        /// The line naming who spoke and when.
        header,

        /// A line of what they said.
        body,

        /// The blank line between messages.
        gap,

        /// A line the view says itself, rather than one somebody said. It
        /// belongs to no message, so `message` means nothing on this row.
        notice,
    };
};

/// Anything that can measure a string in display columns.
///
/// A function rather than a hard dependency on vaxis so the tests can
/// measure without a terminal, and so a wrong measurement is a thing that
/// can be demonstrated rather than argued about.
pub const Measure = *const fn (text: []const u8) u16;

/// Break one line to fit, returning where each piece starts and ends.
///
/// Breaks at a space when there is one in reach and mid-character never:
/// a line cut inside a multi-byte character is not a narrower line, it is
/// a broken one, and the terminal will draw the replacement glyph.
pub fn wrap(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged([]const u8),
    text: []const u8,
    width: u16,
    measure: Measure,
) Allocator.Error!void {
    if (width == 0) return;

    // An empty line is still a line: it is the blank line somebody typed,
    // and dropping it would reflow their paragraphs into a wall.
    if (text.len == 0) {
        try out.append(alloc, text);
        return;
    }

    var rest = text;
    while (rest.len > 0) {
        if (measure(rest) <= width) {
            try out.append(alloc, rest);
            return;
        }

        // Walk forward one character at a time until the next one would not
        // fit. Character by character because that is the unit that has a
        // width; bytes do not.
        var cut: usize = 0;
        var last_space: ?usize = null;
        var it = std.unicode.Utf8Iterator{ .bytes = rest, .i = 0 };
        while (it.nextCodepointSlice()) |slice| {
            const next = it.i;
            if (measure(rest[0..next]) > width) break;
            cut = next;

            // Recorded *before* the space, not after: breaking after it
            // leaves a trailing space on the row, which shows up as a
            // ragged right edge nobody typed.
            if (slice.len == 1 and slice[0] == ' ') last_space = next - slice.len;
        }

        // Nothing fit, which means one character is wider than the pane.
        // Take it anyway: looping forever is worse than one ragged row.
        if (cut == 0) {
            var one = std.unicode.Utf8Iterator{ .bytes = rest, .i = 0 };
            cut = if (one.nextCodepointSlice()) |s| s.len else rest.len;
        }

        // Prefer a word break, but only when it is not so far back that the
        // row would be mostly empty.
        const at = if (last_space) |sp|
            (if (sp * 3 >= cut * 2) sp else cut)
        else
            cut;

        try out.append(alloc, rest[0..at]);
        rest = std.mem.trimStart(u8, rest[at..], " ");
    }
}

/// How many rows a body of text needs at this width.
pub fn height(
    alloc: Allocator,
    text: []const u8,
    width: u16,
    measure: Measure,
) Allocator.Error!usize {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(alloc);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try wrap(alloc, &rows, line, width, measure);
    return rows.items.len;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// A stand-in for the terminal's own measurement: one column per ASCII
/// character, two for anything else. Crude, and enough to show the
/// difference between counting bytes and counting columns.
fn measureTest(text: []const u8) u16 {
    var total: u16 = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepointSlice()) |slice| {
        total += if (slice.len == 1) 1 else 2;
    }
    return total;
}

test "a line that fits is left alone" {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(testing.allocator);

    try wrap(testing.allocator, &rows, "hello", 10, measureTest);
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("hello", rows.items[0]);
}

test "wrapping counts columns, not bytes" {
    // The bug this file exists for. Eight Chinese characters are 24 bytes
    // and 16 columns; measured as bytes they look like they need three
    // rows of ten, and the rows that were not accounted for landed on top
    // of the message above.
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(testing.allocator);

    const text = "群聊界面要改一改";
    try testing.expectEqual(@as(usize, 24), text.len);
    try testing.expectEqual(@as(u16, 16), measureTest(text));

    try wrap(testing.allocator, &rows, text, 10, measureTest);
    try testing.expectEqual(@as(usize, 2), rows.items.len);

    for (rows.items) |row| {
        try testing.expect(measureTest(row) <= 10);
    }
}

test "no row is ever cut inside a character" {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(testing.allocator);

    try wrap(testing.allocator, &rows, "主管在此报到，收到请回复", 7, measureTest);

    // Every piece has to be valid UTF-8 on its own. A cut mid-character
    // does not make a narrower row, it makes a replacement glyph.
    for (rows.items) |row| {
        try testing.expect(std.unicode.utf8ValidateSlice(row));
    }
}

test "words are kept whole when the break is close enough" {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(testing.allocator);

    try wrap(testing.allocator, &rows, "the quick brown fox", 10, measureTest);
    try testing.expectEqualStrings("the quick", rows.items[0]);
}

test "a word longer than the pane is broken rather than looped on" {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(testing.allocator);

    try wrap(testing.allocator, &rows, "supercalifragilistic", 6, measureTest);
    try testing.expect(rows.items.len >= 3);
    for (rows.items) |row| try testing.expect(measureTest(row) <= 6);
}

test "an empty line survives, because somebody put it there" {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(testing.allocator);

    try wrap(testing.allocator, &rows, "", 10, measureTest);
    try testing.expectEqual(@as(usize, 1), rows.items.len);
}

test "height counts the rows a message will actually take" {
    const text = "one\ntwo three four five six\n\nseven";
    const rows = try height(testing.allocator, text, 10, measureTest);

    // "one" | "two three" "four five" "six" | "" | "seven"
    try testing.expectEqual(@as(usize, 6), rows);
}

test "a pane with no width asks for no rows" {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(testing.allocator);

    try wrap(testing.allocator, &rows, "anything", 0, measureTest);
    try testing.expectEqual(@as(usize, 0), rows.items.len);
}
