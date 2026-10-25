//! What a file's bytes are, and whether they may be edited (task 2145 C2,
//! PLAN §1.2 and `2140/v2/EDITING.md` §1, §7). Pure: bytes in, facts out.
//!
//! **The size is the file's, and how much was read is the sample's.** `sniff`
//! is given both and works out for itself whether the sample is the whole
//! file; it does not take a caller's word for it. A flag would be one more
//! thing a caller can get wrong in the direction that reads too much as
//! read-enough, and the size is already known by whoever read the bytes.
//!
//! **Looked at in the first 64 KB**, which is what a preview reads to choose
//! its page.
//!
//! **"It is UTF-8" and "the whole of it is UTF-8" are two different facts**
//! (`Info.whole`). The sample is the whole file only when the file is no
//! longer than `sample_len`; a file of 64 KB to 1 MB whose non-UTF-8 byte --
//! or whose NUL -- comes after the 64 KB mark was otherwise called editable
//! text and saved back in another encoding, which is the one thing EDITING §7
//! exists to prevent. `notEditable` refuses anything it has not read all of.

const Text = @This();

const std = @import("std");

/// What the sniffer reads of a file.
pub const sample_len: usize = 64 * 1024;

/// The most an editor may be handed (EDITING §7).
pub const edit_limit: u64 = 1024 * 1024;

pub const Encoding = enum {
    /// Valid UTF-8 without a byte order mark.
    utf8,
    /// Valid UTF-8 that starts with EF BB BF; saved back the same way.
    utf8_bom,
    /// Not UTF-8, and not binary: shown as it is guessed, never edited.
    other,
    /// Has a NUL byte.
    binary,
};

pub const Eol = enum { none, lf, crlf, mixed };

pub const Info = struct {
    encoding: Encoding,
    eol: Eol,
    /// The sample ends in a newline (of the whole file only when the sample
    /// was the whole file).
    final_newline: bool,
    /// How many bytes were actually looked at.
    read: usize,
    /// **The bytes given were the whole file** (`read == size`), which is the
    /// only thing that makes `encoding` a fact about the file rather than
    /// about its beginning. Worked out here from the two numbers, never taken
    /// from a caller's flag.
    whole: bool,
};

/// `bytes`: what was read of the file. `size`: how long the file is. The two
/// are compared here, so a sample that is the whole file is not a matter of
/// anyone's opinion; a multibyte character cut off at the end of a sample is
/// not a fault, and one in a file that was read whole is.
pub fn sniff(bytes: []const u8, size: u64) Info {
    const whole = bytes.len == size;
    const truncated = !whole;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) {
        return .{ .encoding = .binary, .eol = .none, .final_newline = false, .read = bytes.len, .whole = whole };
    }
    const bom = std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF");
    const body = if (bom) bytes[3..] else bytes;
    const encoding: Encoding = if (validUtf8(body, truncated)) (if (bom) .utf8_bom else .utf8) else .other;
    return .{
        .encoding = encoding,
        .eol = eolOf(body),
        .final_newline = body.len > 0 and body[body.len - 1] == '\n',
        .read = bytes.len,
        .whole = whole,
    };
}

/// How many bytes a leading byte wants, or null when it is not a leading byte
/// at all. **Stricter than `utf8ByteSequenceLength`**: `C0`, `C1`, `F5`-`F7`
/// and `E0 80` cannot begin a character in UTF-8 (they could only spell an
/// overlong form or a code point above U+10FFFF), so bytes that begin with
/// them are broken text, not a character that got cut.
fn leadLen(c: u8) ?u3 {
    return switch (c) {
        0x00...0x7F => 1,
        0xC2...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF4 => 4,
        else => null,
    };
}

/// Whether these bytes are UTF-8, allowing for the one thing a sample can
/// hide: **a character cut by the end of the sample**, which is a valid
/// leading byte followed by fewer continuation bytes than it wants, and
/// nothing else. A broken byte anywhere -- including the last one, when it is
/// not part of such a sequence -- makes the whole thing not UTF-8.
fn validUtf8(bytes: []const u8, truncated: bool) bool {
    if (std.unicode.utf8ValidateSlice(bytes)) return true;
    if (!truncated or bytes.len == 0) return false;
    // At most 3 bytes of one character can be missing (the longest sequence
    // is 4 bytes), so only the last three bytes can be the cut one's lead.
    const first = bytes.len -| 3;
    var lead = bytes.len;
    while (lead > first) {
        lead -= 1;
        const need = leadLen(bytes[lead]) orelse continue;
        const have = bytes.len - lead;
        // The sequence is all there, and the whole-slice check above already
        // said it is not valid: this is a broken byte, not a cut one.
        if (have >= need) return false;
        if (!std.unicode.utf8ValidateSlice(bytes[0..lead])) continue;
        for (bytes[lead + 1 ..]) |c| {
            if (c & 0xC0 != 0x80) return false;
        }
        return true;
    }
    return false;
}

fn eolOf(bytes: []const u8) Eol {
    var lf: usize = 0;
    var crlf: usize = 0;
    for (bytes, 0..) |c, i| {
        if (c != '\n') continue;
        if (i > 0 and bytes[i - 1] == '\r') crlf += 1 else lf += 1;
    }
    if (lf == 0 and crlf == 0) return .none;
    if (crlf == 0) return .lf;
    if (lf == 0) return .crlf;
    return .mixed;
}

pub const NotEditable = enum {
    too_big,
    binary,
    /// Not read to the end, so what its encoding is cannot be said: a byte
    /// after the sample could make it a file that saving would rewrite.
    not_whole,
    not_utf8,
    container,

    pub fn say(self: NotEditable) []const u8 {
        return switch (self) {
            .too_big => "it is over 1 MB, which is more than the editor takes",
            .binary => "it is not text",
            .not_whole => "it is too long for the whole of it to be read before it is edited",
            .not_utf8 => "it is not UTF-8, and saving it would change its encoding",
            .container => "it is a document format that is not safe to edit as text",
        };
    }
};

/// Formats whose bytes are a container: text inside them is not the file.
const containers = [_][]const u8{
    ".xlsx", ".xls",  ".xlsm",  ".xlsb",    ".docx", ".doc", ".docm",
    ".pptx", ".ppt",  ".odt",   ".ods",     ".odp",  ".pdf", ".zip",
    ".jar",  ".epub", ".pages", ".numbers", ".key",
};

/// Null when the file may be edited; the reason when it may not.
/// **Everything else about editing** (the file is in the workdir, nothing
/// else is writing it) is `Access` and the lock.
pub fn notEditable(name: []const u8, size: u64, info: Info) ?NotEditable {
    const ext = std.fs.path.extension(name);
    for (containers) |c| if (std.ascii.eqlIgnoreCase(ext, c)) return .container;
    if (size > edit_limit) return .too_big;
    if (info.encoding == .binary) return .binary;
    // **The sample is not the file.** A file of 64 KB to 1 MB is refused
    // outright rather than judged on its first 64 KB: a GBK byte or a NUL
    // past that mark would be saved back as UTF-8 and the file rewritten,
    // which is what EDITING §7 forbids. Reading all of it and judging that
    // would be the other way; refusing is the one that cannot be wrong.
    if (!info.whole) return .not_whole;
    if (info.encoding == .other) return .not_utf8;
    return null;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// A sample that was the whole file.
fn wholeSniff(bytes: []const u8) Info {
    return sniff(bytes, bytes.len);
}

/// A sample of a file that goes on: 4 KB more of it than was read.
fn partSniff(bytes: []const u8) Info {
    return sniff(bytes, bytes.len + 4096);
}

test "2145 C2: text, a byte order mark, another encoding and binary are told apart" {
    try testing.expectEqual(Encoding.utf8, wholeSniff("hello 中文\n").encoding);
    try testing.expectEqual(Encoding.utf8, wholeSniff("").encoding);
    try testing.expectEqual(Encoding.utf8_bom, wholeSniff("\xEF\xBB\xBFhello").encoding);
    // GBK for 中文: valid bytes, not UTF-8.
    try testing.expectEqual(Encoding.other, wholeSniff("\xD6\xD0\xCE\xC4").encoding);
    try testing.expectEqual(Encoding.binary, wholeSniff("a\x00b").encoding);
    try testing.expectEqual(Encoding.binary, wholeSniff("\x89PNG\r\n\x1a\n\x00\x00").encoding);
}

test "2145 C2: a character cut by the end of a sample is not a fault, one in the middle is" {
    // 中 is E4 B8 AD. Cut after two bytes at the end of a longer file.
    const cut = "ab\xE4\xB8";
    try testing.expectEqual(Encoding.utf8, partSniff(cut).encoding);
    // The same bytes as a whole file are broken.
    try testing.expectEqual(Encoding.other, wholeSniff(cut).encoding);
    // A bad byte in the middle is bad whether or not the file goes on.
    try testing.expectEqual(Encoding.other, partSniff("ab\xE4\xB8cd").encoding);
}

test "2145 C2: only a valid lead with its continuation bytes missing is forgiven at the end" {
    // A 3-byte lead with one of the two continuations: forgiven.
    try testing.expectEqual(Encoding.utf8, partSniff("ok\xE4\xB8").encoding);
    // ...with none of them: forgiven too.
    try testing.expectEqual(Encoding.utf8, partSniff("ok\xE4").encoding);
    // A 4-byte lead with three missing: forgiven.
    try testing.expectEqual(Encoding.utf8, partSniff("ok\xF0\x9F\x98").encoding);
    // **Two arbitrary broken bytes are not a cut character.** The old rule
    // dropped up to three trailing bytes and called whatever was left valid,
    // so this passed as UTF-8.
    try testing.expectEqual(Encoding.other, partSniff("ab\xFF\xFE").encoding);
    try testing.expectEqual(Encoding.other, partSniff("ab\x80\x80").encoding);
    // A continuation byte that is not a continuation: not a cut character.
    try testing.expectEqual(Encoding.other, partSniff("ok\xE4\x41").encoding);
    // The lead byte is complete already, so nothing is missing: broken.
    try testing.expectEqual(Encoding.other, partSniff("a\xFF").encoding);
    // A lone 2-byte lead at the very end is a cut character; the same byte
    // one place earlier is not at the end, so it is broken.
    try testing.expectEqual(Encoding.utf8, partSniff("ok\xC3").encoding);
    try testing.expectEqual(Encoding.other, partSniff("ok\xC3\x41").encoding);
    // **A byte that cannot begin a character is broken, not cut.** `F5` is
    // not a lead byte at all (it would spell a code point above U+10FFFF),
    // and only two bytes follow it -- a rule that asked just "how many are
    // missing" would forgive this one. It sits where the cut can reach it
    // (the last three bytes), which is the only place that decides anything.
    try testing.expectEqual(Encoding.other, partSniff("ok\xF5\x8F\x8F").encoding);
    // `C0` and `C1` would be an overlong form, and are not lead bytes either.
    try testing.expectEqual(Encoding.other, partSniff("ok\xC0").encoding);
    try testing.expectEqual(Encoding.other, partSniff("ok\xC1").encoding);
    // A non-UTF-8 byte further back than the cut can reach is broken.
    try testing.expectEqual(Encoding.other, partSniff("a\xFFb\xE4\xB8").encoding);
}

test "2145 C2: whether the bytes were the whole file is said out loud" {
    try testing.expect(wholeSniff("hello").whole);
    try testing.expect(!partSniff("hello").whole);
    // A sample that happens to end cleanly is still not the whole file.
    try testing.expect(!partSniff("hello\n").whole);
    // A NUL found in a sample says binary, and says the sample was partial.
    try testing.expect(!partSniff("a\x00").whole);
}

test "2145 C2: the line ending and the final newline are read off the bytes" {
    try testing.expectEqual(Eol.none, wholeSniff("one line").eol);
    try testing.expectEqual(Eol.lf, wholeSniff("a\nb\n").eol);
    try testing.expectEqual(Eol.crlf, wholeSniff("a\r\nb\r\n").eol);
    try testing.expectEqual(Eol.mixed, wholeSniff("a\r\nb\n").eol);
    try testing.expect(wholeSniff("a\n").final_newline);
    try testing.expect(!wholeSniff("a").final_newline);
    try testing.expect(!wholeSniff("").final_newline);
    // The BOM is not part of the text.
    try testing.expectEqual(Eol.lf, wholeSniff("\xEF\xBB\xBFa\n").eol);
}

test "2145 C2: what may not be edited, and why" {
    const text = wholeSniff("fine\n");
    try testing.expect(notEditable("a.md", 5, text) == null);
    try testing.expect(notEditable("Makefile", 5, text) == null);
    try testing.expect(notEditable("a.csv", 5, text) == null);
    // The limit is on the size of the file, and 1 MB itself is allowed.
    try testing.expect(notEditable("a.txt", edit_limit, text) == null);
    try testing.expectEqual(NotEditable.too_big, notEditable("a.txt", edit_limit + 1, text).?);
    try testing.expectEqual(NotEditable.binary, notEditable("a.dat", 5, wholeSniff("a\x00")).?);
    try testing.expectEqual(NotEditable.not_utf8, notEditable("a.txt", 5, wholeSniff("\xD6\xD0")).?);
    // A container is refused by its name even when its bytes would pass.
    try testing.expectEqual(NotEditable.container, notEditable("sheet.xlsx", 5, text).?);
    try testing.expectEqual(NotEditable.container, notEditable("Report.DOCX", 5, text).?);
    inline for (@typeInfo(NotEditable).@"enum".fields) |f| {
        const r: NotEditable = @enumFromInt(f.value);
        try testing.expect(r.say().len > 0);
    }
}

test "2145 C2: what comes after the 64 KB mark decides, and only the whole file may be edited" {
    // A file of 200 KB whose first 64 KB are clean UTF-8 and whose GBK bytes
    // are past the mark: the sample alone calls it editable text, and saving
    // it would rewrite the file's encoding. It must not be editable.
    const clean = "a" ** (Text.sample_len + 4096);
    const sample = try testing.allocator.dupe(u8, clean[0..Text.sample_len]);
    defer testing.allocator.free(sample);
    const partial = partSniff(sample);
    try testing.expectEqual(Encoding.utf8, partial.encoding);
    try testing.expect(!partial.whole);
    try testing.expectEqual(NotEditable.not_whole, notEditable("big.txt", clean.len, partial).?);

    // The same for a NUL past the mark.
    const nul_late = try testing.allocator.dupe(u8, clean[0..Text.sample_len]);
    defer testing.allocator.free(nul_late);
    const late_nul = partSniff(nul_late);
    try testing.expectEqual(Encoding.utf8, late_nul.encoding);
    try testing.expectEqual(NotEditable.not_whole, notEditable("big.bin", clean.len, late_nul).?);

    // The same file read whole is judged on all of it, and is not editable
    // for the right reason.
    const gbk_tail = "\xD6\xD0\xCE\xC4";
    const whole = try std.mem.concat(testing.allocator, u8, &.{ clean[0..Text.sample_len], gbk_tail });
    defer testing.allocator.free(whole);
    const read_all = wholeSniff(whole);
    try testing.expect(read_all.whole);
    try testing.expectEqual(Encoding.other, read_all.encoding);
    try testing.expectEqual(NotEditable.not_utf8, notEditable("big.txt", whole.len, read_all).?);

    // A file under the mark is the sample and is judged normally.
    const small = wholeSniff("hello\n");
    try testing.expect(small.whole);
    try testing.expect(notEditable("small.txt", 6, small) == null);
}
