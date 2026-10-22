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
        // Where a row may end short of `cut`: before a space, or beside a
        // wide character -- CJK text breaks between any two of its
        // characters, and has no spaces to break at (task 2105).
        var last_break: ?usize = null;
        var prev_wide = false;
        // Nor after an opening bracket (避尾): 「（」 goes down with what it
        // opens.
        var prev_opens = false;
        var it = std.unicode.Utf8Iterator{ .bytes = rest, .i = 0 };
        while (it.nextCodepointSlice()) |slice| {
            const start = it.i - slice.len;
            const next = it.i;
            const wide = measure(slice) >= 2;
            // Before the fit test: the character that does not fit may be
            // the wide one, and the row may end right before it.
            if (start > 0 and !prev_opens and (wide or prev_wide)) last_break = start;
            if (measure(rest[0..next]) > width) break;
            cut = next;
            prev_wide = wide;
            prev_opens = noLineEnd(slice);

            // Recorded *before* the space, not after: breaking after it
            // leaves a trailing space on the row, which shows up as a
            // ragged right edge nobody typed.
            if (slice.len == 1 and slice[0] == ' ') {
                last_space = start;
                last_break = start;
            }
        }

        // Nothing fit, which means one character is wider than the pane.
        // Take it anyway: looping forever is worse than one ragged row.
        if (cut == 0) {
            var one = std.unicode.Utf8Iterator{ .bytes = rest, .i = 0 };
            cut = if (one.nextCodepointSlice()) |s| s.len else rest.len;
        }

        // Where the row runs out is a break when a wide character is on
        // either side of it. Otherwise it is inside a word: go back to the
        // last break, but only when it is not so far back that the row
        // would be mostly empty. **Only a space was a break before task
        // 2105**, so a Chinese line with one stray space in it ended at
        // that space -- "第 6" and then the rest.
        var at = if (last_break) |b|
            (if (b * 3 >= cut * 2) b else cut)
        else
            cut;

        // **No row starts with a full stop** (task 2060): a mark that closes
        // what came before it takes the character before it down to the next
        // row, the way CJK text is set -- "在。" goes down together rather
        // than leaving "。" at the head of a row of its own. Back, not
        // forward: the row it would hang off is already full. Never back to
        // an empty row, which would loop. A space in the row is the better
        // place to go back to: "defgh." goes down whole rather than as "h.".
        // Only inside a word: before a wide character, one character back
        // is the break, and a space further back would empty the row for
        // nothing ("第 6 轮……在。").
        if (noLineStart(std.mem.trimStart(u8, rest[at..], " ")) and !wideBefore(rest, at, measure)) {
            if (last_space) |sp| if (sp > 0 and sp < at) {
                at = sp;
            };
        }
        while (noLineStart(std.mem.trimStart(u8, rest[at..], " "))) {
            const back = prevChar(rest, at);
            if (back == 0) break;
            at = back;
        }

        try out.append(alloc, rest[0..at]);
        rest = std.mem.trimStart(u8, rest[at..], " ");
    }
}

/// Marks that close what came before them and so may not open a row.
const no_line_start = "。，、；：？！）】」』》〉〕］｝”’…．％～·.,;:?!)]}%";

/// Marks that open what comes after them and so may not end a row.
const no_line_end = "（【「『《〈〔［｛“‘([{";

/// Whether `char` is one a row may not end with.
fn noLineEnd(char: []const u8) bool {
    var it = std.unicode.Utf8Iterator{ .bytes = no_line_end, .i = 0 };
    while (it.nextCodepointSlice()) |mark| if (std.mem.eql(u8, mark, char)) return true;
    return false;
}

/// Whether `text` starts with a mark no row may start with.
fn noLineStart(text: []const u8) bool {
    if (text.len == 0) return false;
    const n = std.unicode.utf8ByteSequenceLength(text[0]) catch return false;
    if (n > text.len) return false;
    var it = std.unicode.Utf8Iterator{ .bytes = no_line_start, .i = 0 };
    while (it.nextCodepointSlice()) |mark| if (std.mem.eql(u8, mark, text[0..n])) return true;
    return false;
}

/// Whether the character before `at` is a wide one.
fn wideBefore(text: []const u8, at: usize, measure: Measure) bool {
    if (at == 0) return false;
    return measure(text[prevChar(text, at)..at]) >= 2;
}

/// Where the character before `at` starts.
fn prevChar(text: []const u8, at: usize) usize {
    var i = at;
    while (i > 0) {
        i -= 1;
        if (text[i] & 0xC0 != 0x80) break;
    }
    return i;
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

test "2060: a full stop does not open a row; the character before it goes down with it" {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(testing.allocator);

    // Ten columns hold five characters, and the sixth is the full stop: the
    // break falls just before it. Seen on Windows, where "在" stayed and "。"
    // opened the next row.
    try wrap(testing.allocator, &rows, "一二三四在。返回", 10, measureTest);
    try testing.expectEqual(@as(usize, 2), rows.items.len);
    try testing.expectEqualStrings("一二三四", rows.items[0]);
    try testing.expectEqualStrings("在。返回", rows.items[1]);

    // A comma and a closing bracket as well.
    rows.clearRetainingCapacity();
    try wrap(testing.allocator, &rows, "一二三四五，六七", 10, measureTest);
    try testing.expectEqualStrings("五，六七", rows.items[1]);
    rows.clearRetainingCapacity();
    try wrap(testing.allocator, &rows, "（一二三四五）六", 12, measureTest);
    try testing.expectEqualStrings("五）六", rows.items[1]);

    // A line that fits is not touched.
    rows.clearRetainingCapacity();
    try wrap(testing.allocator, &rows, "一二三四。", 10, measureTest);
    try testing.expectEqual(@as(usize, 1), rows.items.len);
}

test "2060: going back for a mark prefers a space, and never empties a row" {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(testing.allocator);

    // The word goes down whole, not "abc defg" and "h.".
    try wrap(testing.allocator, &rows, "abc defgh.", 9, measureTest);
    try testing.expectEqualStrings("abc", rows.items[0]);
    try testing.expectEqualStrings("defgh.", rows.items[1]);

    // Nothing but marks: each row still takes at least one, and it ends.
    rows.clearRetainingCapacity();
    try wrap(testing.allocator, &rows, "。。。。。。", 4, measureTest);
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (rows.items) |r| {
        try testing.expect(r.len > 0);
        try testing.expect(measureTest(r) <= 4);
        try joined.appendSlice(testing.allocator, r);
    }
    try testing.expectEqualStrings("。。。。。。", joined.items);
}

test "2105: Chinese with a stray space breaks where the row is full, not at the space" {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(testing.allocator);

    // The goal 0x8d10 read on Windows: one space, after "6". Sixteen columns
    // hold up to the comma; the space is no reason to stop at "第 6".
    try wrap(testing.allocator, &rows, "第 6 轮进行中，收尾文案和用例", 16, measureTest);
    try testing.expectEqualStrings("第 6 轮进行中，", rows.items[0]);
    try testing.expectEqualStrings("收尾文案和用例", rows.items[1]);
}

test "2105: a space near the end of a Chinese row is not where it ends either" {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(testing.allocator);

    // The chat's body as round six read it: the second row stopped at a
    // space well short of the width. The space is in the row's last third,
    // so the old rule took it; the row holds one more character.
    try wrap(testing.allocator, &rows, "进行中进行中 收尾文案", 16, measureTest);
    try testing.expectEqualStrings("进行中进行中 收", rows.items[0]);
    try testing.expectEqualStrings("尾文案", rows.items[1]);
}

test "2105: between Chinese and a word, the break is at their edge, and the word stays whole" {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(testing.allocator);

    // Twelve columns run out inside "hello": not cut there, but where the
    // Chinese ends.
    try wrap(testing.allocator, &rows, "中文中文hello world", 12, measureTest);
    try testing.expectEqualStrings("中文中文", rows.items[0]);
    try testing.expectEqualStrings("hello world", rows.items[1]);
}

test "2105: an opening bracket goes down with what it opens" {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(testing.allocator);

    // The goal of round five, twenty columns: the hosts' goal tests have
    // the same two rows.
    try wrap(testing.allocator, &rows, "第 5 轮进行中（2026-10-22）：", 20, measureTest);
    try testing.expectEqualStrings("第 5 轮进行中", rows.items[0]);
    try testing.expectEqualStrings("（2026-10-22）：", rows.items[1]);
}

test "2105: a full stop's character goes down with it, and a space further back is not where the row ends" {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(testing.allocator);

    try wrap(testing.allocator, &rows, "第 6 轮进行中在。返回", 16, measureTest);
    try testing.expectEqualStrings("第 6 轮进行中", rows.items[0]);
    try testing.expectEqualStrings("在。返回", rows.items[1]);
}

test "a pane with no width asks for no rows" {
    var rows: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rows.deinit(testing.allocator);

    try wrap(testing.allocator, &rows, "anything", 0, measureTest);
    try testing.expectEqual(@as(usize, 0), rows.items.len);
}
