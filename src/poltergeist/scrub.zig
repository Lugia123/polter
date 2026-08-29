//! Making text somebody else wrote safe to put in front of a person.
//!
//! Two destinations need this and they must not disagree, which is why it
//! is a file rather than a private function in either of them:
//!
//!   - `report.told` builds a line that is **printed onto a terminal
//!     screen**. The text in it came from a plugin -- a script the user
//!     copied off the internet -- and a terminal is an interpreter. Left
//!     alone, a plugin could move the cursor, repaint the screen, set the
//!     window title, or draw something that reads as Polter itself asking
//!     for a password.
//!   - `PluginLog` writes the plugin's own stderr into a file. That file
//!     is opened by a person, and `cat` on it is the same interpreter with
//!     the same problem.
//!
//! The two differ in whether anybody asked to see the bytes, and not in
//! where the bytes came from -- so they get one table, applied once, in one
//! place. A rule kept in two places is a rule one of them stops keeping.
//!
//! **The table is xterm's, and the reason is `src/input/paste.zig`.** That
//! file strips a set of bytes out of every paste "regardless of bracketed
//! paste mode ... a security measure to prevent pastes from containing
//! bytes that could be used to inject commands", and a plugin's line is a
//! paste by another name: text of unknown provenance heading for a
//! terminal. This table is wider than that one, because it can afford to
//! be: a paste has to keep working as input to a program, so xterm can only
//! take out what is dangerous. Nothing here is input to anything. So
//! everything below `0x20`, `DEL`, and the C1 range go, without asking
//! which of them some program might have wanted.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// What a stripped byte becomes.
///
/// A space and not nothing, which is xterm's choice as well: deleting the
/// byte joins the words on either side of it, and a report that reads
/// `couldnot write` has been made harder to read in the course of being
/// made safe. A space keeps the line the shape its author gave it.
pub const replacement: u8 = ' ';

/// What an undecodable byte becomes.
///
/// Not the Unicode replacement character, which is three bytes: the output
/// of this function is never longer than its input, and every caller has a
/// length budget it has already reasoned about.
pub const unreadable: u8 = '?';

/// Take out everything a terminal would act on rather than draw.
///
/// The result is valid UTF-8 whatever the input was, holds no control
/// character in any encoding, and is **never longer than the input** --
/// which is what lets a caller clamp before or after this without the two
/// steps having to know about each other.
pub fn clean(alloc: Allocator, in: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    // The output cannot be longer than the input: every branch below emits
    // either one byte for one byte, or the same sequence it read. So one
    // reservation covers the whole loop and nothing after this can fail.
    try out.ensureTotalCapacityPrecise(alloc, in.len);

    var i: usize = 0;
    while (i < in.len) {
        const b = in[i];

        if (b < 0x80) {
            out.appendAssumeCapacity(if (b < 0x20 or b == 0x7F) replacement else b);
            i += 1;
            continue;
        }

        // Past ASCII the byte is part of a sequence, and a sequence that
        // does not decode is not something to guess at: one `?` per byte,
        // so a run of rubbish stays as long as it was and the bytes after
        // it are still read from the right place.
        const len = std.unicode.utf8ByteSequenceLength(b) catch {
            out.appendAssumeCapacity(unreadable);
            i += 1;
            continue;
        };

        if (i + len > in.len) {
            out.appendAssumeCapacity(unreadable);
            i += 1;
            continue;
        }

        const cp = std.unicode.utf8Decode(in[i..][0..len]) catch {
            out.appendAssumeCapacity(unreadable);
            i += 1;
            continue;
        };

        // The C1 controls. They are two bytes in UTF-8 rather than one, so
        // a strip table written over bytes misses every one of them -- and
        // `0x9B` is CSI, which is to say the whole of the escape vocabulary
        // reached by a second door.
        out.appendSliceAssumeCapacity(if (cp >= 0x80 and cp <= 0x9F)
            &[_]u8{replacement}
        else
            in[i..][0..len]);

        i += len;
    }

    return out.toOwnedSlice(alloc);
}

/// How much of `text` fits in `max` bytes without cutting a character in
/// half.
///
/// Returns a length, not a slice, so a caller can use it on the way in or
/// on the way out. Half a UTF-8 sequence on somebody's screen is a
/// replacement character where a word should be, and the fixed-size
/// messages Polter puts on a screen make a cut a real possibility rather
/// than a theoretical one.
pub fn cut(text: []const u8, max: usize) usize {
    if (text.len <= max) return text.len;

    var at = max;
    while (at > 0 and text[at] & 0xC0 == 0x80) at -= 1;
    return at;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "an ordinary sentence comes through unchanged" {
    const alloc = testing.allocator;

    const said = try clean(alloc, "could not write the skill file: permission denied");
    defer alloc.free(said);
    try testing.expectEqualStrings(
        "could not write the skill file: permission denied",
        said,
    );
}

test "an escape sequence cannot reach the screen" {
    const alloc = testing.allocator;

    // What this is for, spelled out: a plugin that could send this would be
    // able to clear the screen, colour its own line, move the cursor over
    // somebody else's output, and set the window title -- and the last of
    // those is how a line stops looking like a plugin's and starts looking
    // like Polter's.
    const said = try clean(alloc, "ok\x1b[2J\x1b]0;polter: password?\x07 done");
    defer alloc.free(said);

    try testing.expect(std.mem.indexOfScalar(u8, said, 0x1b) == null);
    try testing.expect(std.mem.indexOfScalar(u8, said, 0x07) == null);
    try testing.expectEqualStrings("ok [2J ]0;polter: password?  done", said);
}

test "every C0 byte and DEL becomes a space" {
    const alloc = testing.allocator;

    var raw: [0x21]u8 = undefined;
    for (0..0x20) |i| raw[i] = @intCast(i);
    raw[0x20] = 0x7F;

    const said = try clean(alloc, &raw);
    defer alloc.free(said);

    try testing.expectEqual(@as(usize, 0x21), said.len);
    for (said) |b| try testing.expectEqual(replacement, b);
}

test "the C1 controls go too, and they are two bytes each" {
    const alloc = testing.allocator;

    // `\u{9b}` is CSI. A table written over bytes rather than codepoints
    // lets this through, because neither `0xC2` nor `0x9B` is a control
    // byte on its own.
    const said = try clean(alloc, "a\u{9b}31mb\u{85}c");
    defer alloc.free(said);
    try testing.expectEqualStrings("a 31mb c", said);
}

test "text that is not UTF-8 does not become text that is not UTF-8" {
    const alloc = testing.allocator;

    const said = try clean(alloc, "a\xff\xfeb\xe4\xb8c");
    defer alloc.free(said);

    try testing.expect(std.unicode.utf8ValidateSlice(said));
    try testing.expectEqualStrings("a??b??c", said);
}

test "what comes out is never longer than what went in" {
    const alloc = testing.allocator;

    for ([_][]const u8{
        "",
        "\x00\x00\x00",
        "\u{9b}\u{9b}\u{9b}",
        "\xff\xff\xff",
        "日本語のテキスト",
        "mixed \x1b\xff 日本",
    }) |raw| {
        const said = try clean(alloc, raw);
        defer alloc.free(said);
        try testing.expect(said.len <= raw.len);
    }
}

test "a cut lands on a character boundary, never inside one" {
    // Three bytes each, so a naive cut at 4 or 5 splits one.
    const text = "日本語";
    try testing.expectEqual(@as(usize, 9), cut(text, 100));
    try testing.expectEqual(@as(usize, 3), cut(text, 4));
    try testing.expectEqual(@as(usize, 3), cut(text, 5));
    try testing.expectEqual(@as(usize, 6), cut(text, 6));
    try testing.expectEqual(@as(usize, 0), cut(text, 2));

    // And what it must not do to plain text, where every byte is a
    // boundary: take less than it was asked for.
    try testing.expectEqual(@as(usize, 4), cut("abcdefgh", 4));
}
