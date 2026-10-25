//! One line off a stream, however long it is (task 2170).
//!
//! **Two programs read lines over the agent socket, and both had the same
//! ceiling.** `cli/chat.zig` reads the host's answers; `cli/mcp.zig` reads
//! them too, and reads the agent's JSON-RPC requests off stdin. Three call
//! sites, all using `Reader.takeDelimiter`, which reads only as far as the
//! reader's buffer and answers `StreamTooLong` past it. The buffer was 256 KiB
//! in every case -- a number nobody chose, being the size of a buffer that
//! exists for another reason.
//!
//! **What a full buffer costs is not one failed call.** `takeDelimiter`
//! leaves the rest of that line in the stream, so the next read starts in the
//! middle of it and fails the same way, for ever. Task 2150 was a chat window
//! that closed; task 2170 was an agent whose every Polter tool answered
//! "could not reach polter" while the process stayed up and the host answered
//! every request correctly.
//!
//! ## What this does instead
//!
//! `streamDelimiterLimit` streams *through* the reader into a writer that
//! grows, so the reader's buffer is a window rather than a ceiling. The cap
//! is a guard against a peer that has gone wrong -- finite, and far past
//! anything either protocol produces -- not a budget.
//!
//! Past the cap, three things happen and all three matter:
//!
//!   1. the rest of the line is **discarded to its newline**, so the stream
//!      is back on a line boundary and the next read is a real line again;
//!   2. the caller gets `error.LineTooLong`, which is about *this* line and
//!      nothing else;
//!   3. nothing else in the process changes -- no exit, no wedged connection.
//!
//! ## The cap is what it says
//!
//! `streamDelimiterLimit` counts the bytes it has *not* taken, so handing it
//! `cap` refuses a line of exactly `cap` bytes whose newline is the next
//! byte. This passes `cap + 1`, and so reads a line of exactly the cap. That
//! off-by-one was measured rather than reasoned about: with the cap at
//! 262,144, a reply of 262,143 bytes read and one of 262,144 bytes did not.

const std = @import("std");

/// Longest line a client will read where the line is an *answer*, and there
/// is no telling how long it needs to be.
///
/// 64 MiB is far past anything this protocol produces -- the largest thing
/// the host sends is a skill's text, and `skill_store` stops that at one
/// megabyte -- and still finite, so a peer that has gone wrong cannot make
/// the reader allocate without end.
pub const max_reply = 64 * 1024 * 1024;

/// Longest line a client will read where the line is a *request*, whose
/// length is its own side's business.
///
/// The number `Server.max_request_bytes` is, and for the same reason: the
/// host reads no longer request, so a longer one is a bug here rather than
/// something to pass on.
pub const max_request = 64 * 1024;

/// What can come out of `readLine`.
pub const Error = error{
    /// The stream ended before a newline. **A last line without one is this,
    /// not a short line:** there is no way to tell a prefix from a whole, and
    /// handing a prefix to a JSON parser would report a syntax error about a
    /// message that was fine as far as it went.
    EndOfStream,
    /// The read itself failed. Whatever is on the wire is still there.
    ReadFailed,
    /// The line was longer than the cap. It has been discarded -- the stream
    /// is on a line boundary -- and this says so.
    LineTooLong,
    /// The growing buffer could not grow.
    OutOfMemory,
};

/// Read one line, without its newline, into `out`.
///
/// The returned slice is `out.written()`: it lives until the next read into
/// the same `out`, and callers that keep it copy it. `out` is cleared first
/// and its capacity is kept, because every caller is a loop.
pub fn readLine(
    r: *std.Io.Reader,
    out: *std.Io.Writer.Allocating,
    cap: usize,
) Error![]const u8 {
    return readLineCounting(r, out, cap, null);
}

/// `readLine`, and **how big the line was when there was too much of it**
/// (task 2287).
///
/// A caller that answers `LineTooLong` with a log line cannot say anything
/// worth reading without this: "a line was too long" with no number is the
/// same sentence for a 70 KiB request and a 60 MiB one, and those are
/// different events. `dropped` is only written on `error.LineTooLong`.
///
/// **The number is a lower bound, and is one of two cases**:
///
///   * the line had a newline after it, and the count is exact -- the bytes
///     read into `out` before the cap was reached (`cap + 1`), plus
///     everything discarded to and including that newline;
///   * the stream ended first, so there is no newline to count to and the
///     count is only what was read. The caller says "at least" rather than
///     pretending otherwise, which is why this hands back a number and not
///     a sentence.
pub fn readLineCounting(
    r: *std.Io.Reader,
    out: *std.Io.Writer.Allocating,
    cap: usize,
    dropped: ?*usize,
) Error![]const u8 {
    out.clearRetainingCapacity();
    _ = r.streamDelimiterLimit(
        &out.writer,
        '\n',
        .limited(cap +| 1),
    ) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.WriteFailed => return error.OutOfMemory,
        error.StreamTooLong => {
            // Unbounded on purpose. Discarding to the newline is the whole
            // of "the next read does not start in the middle of a line", and
            // the only peer that can make this walk a long way is one that
            // has just sent more than `cap` in one line. Its own failure is
            // not reported on top of this one: a stream that ended here
            // leaves nothing to resynchronise.
            const rest = r.discardDelimiterInclusive('\n') catch 0;
            // **Measured, not assumed**: what is in `out` is what
            // `streamDelimiterLimit` managed to write before it stopped,
            // and `rest` is what the discard walked. Nothing here depends on
            // the reader's chunking or on the off-by-one above.
            if (dropped) |d| d.* = out.written().len +| rest;
            return error.LineTooLong;
        },
    };

    // **`streamDelimiter` leaves the delimiter in the stream, unlike
    // `takeDelimiter`, which consumed it.** Leaving it would make every later
    // read an empty line nobody asked for. It is also how the stream ending
    // is noticed: a stream that ended without its newline is reported as the
    // byte count it did read, so the missing delimiter is what says
    // `EndOfStream` here.
    _ = r.takeByte() catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        error.ReadFailed => return error.ReadFailed,
    };

    return out.written();
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "2170: a line is read whole, and the newline is consumed" {
    const alloc = testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    var r = std.Io.Reader.fixed("one\ntwo\n");
    try testing.expectEqualStrings("one", try readLine(&r, &buf, 1024));
    try testing.expectEqualStrings("two", try readLine(&r, &buf, 1024));
    // The third read is the end of the stream, not an empty line.
    try testing.expectError(error.EndOfStream, readLine(&r, &buf, 1024));
}

test "2170: a line exactly the cap long is read, and one byte more is not" {
    const alloc = testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    const cap = 64;

    var at_cap: [cap + 1]u8 = undefined;
    @memset(at_cap[0..cap], 'a');
    at_cap[cap] = '\n';
    var at_reader = std.Io.Reader.fixed(&at_cap);
    try testing.expectEqual(@as(usize, cap), (try readLine(&at_reader, &buf, cap)).len);

    var over: [cap + 2]u8 = undefined;
    @memset(over[0 .. cap + 1], 'b');
    over[cap + 1] = '\n';
    var over_reader = std.Io.Reader.fixed(&over);
    try testing.expectError(error.LineTooLong, readLine(&over_reader, &buf, cap));
}

test "2170: a line over the cap leaves the stream on the next line, not mid-sentence" {
    const alloc = testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    // The line that is too long, then a short one. The second read is the
    // whole point: without the discard it would be the tail of the first.
    const cap = 8;
    var r = std.Io.Reader.fixed("aaaaaaaaaaaaaaaaaaaa\nshort\n");
    try testing.expectError(error.LineTooLong, readLine(&r, &buf, cap));
    try testing.expectEqualStrings("short", try readLine(&r, &buf, cap));
}

test "2170: a stream that ends without its newline is the end, not a short line" {
    const alloc = testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    var r = std.Io.Reader.fixed("no newline at all");
    try testing.expectError(error.EndOfStream, readLine(&r, &buf, 1024));
}

test "2170: an empty line is a line, and is not the end of the stream" {
    const alloc = testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    var r = std.Io.Reader.fixed("\nsecond\n");
    try testing.expectEqualStrings("", try readLine(&r, &buf, 1024));
    try testing.expectEqualStrings("second", try readLine(&r, &buf, 1024));
}

test "2287: a line past the cap reports how long it was, and the number is the line's" {
    const alloc = testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    const cap = 8;
    // Exactly `cap + 1` is the smallest line that can be too long: the read
    // is allowed `cap + 1` bytes, and a line of that many without a newline
    // in it is past what it will take.
    {
        var d: usize = 0;
        var r = std.Io.Reader.fixed("aaaaaaaaa\nshort\n"); // 9 = cap + 1, then a newline
        try testing.expectError(error.LineTooLong, readLineCounting(&r, &buf, cap, &d));
        // **The whole line, including the newline that ended it.** The
        // number a log line needs is "how much did they send", not "how much
        // did we keep", so the discarded part is in it.
        try testing.expectEqual(@as(usize, 10), d);
        try testing.expectEqualStrings("short", try readLine(&r, &buf, cap));
    }

    // A long one, so that the count is not merely a restatement of the cap.
    {
        var d: usize = 0;
        var line: [500]u8 = undefined;
        @memset(line[0..499], 'z');
        line[499] = '\n';
        var r = std.Io.Reader.fixed(&line);
        try testing.expectError(error.LineTooLong, readLineCounting(&r, &buf, cap, &d));
        try testing.expectEqual(@as(usize, 500), d);
    }

    // **A stream that ends mid-line still reports what it saw**, and that is
    // a lower bound rather than the line's length: there is no newline to
    // count to. The caller's sentence has to say "at least" for this case,
    // which is why this is a number and not a phrase. Exactly `cap + 1` and
    // not one byte more, because the discard walked off the end of the
    // stream and had nothing to add.
    {
        var d: usize = 0;
        var line: [64]u8 = undefined;
        @memset(&line, 'y');
        var r = std.Io.Reader.fixed(&line);
        try testing.expectError(error.LineTooLong, readLineCounting(&r, &buf, cap, &d));
        try testing.expectEqual(@as(usize, cap + 1), d);
    }

    // And a line that fits writes nothing into it: the caller must not read
    // a stale count from a previous call.
    {
        var d: usize = 12345;
        var r = std.Io.Reader.fixed("ok\n");
        try testing.expectEqualStrings("ok", try readLineCounting(&r, &buf, cap, &d));
        try testing.expectEqual(@as(usize, 12345), d);
    }
}
