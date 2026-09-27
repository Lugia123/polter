//! Why the last surface could not be created, in words an apprt can show.
//!
//! **Why this exists (#18).** On a Windows machine whose only GPU is a virtual
//! display adapter, the first tab's surface fails -- the driver refuses the
//! OpenGL 4.3 core profile the renderer needs -- and the host exits. The
//! person saw a window flash and vanish; the reason was only in the log.
//! `ghostty_surface_new` returns null and nothing else, so the host had
//! nothing it could put in front of them.
//!
//! **What it is not: a sentence about OpenGL 4.3.** The next failure may have
//! another cause entirely, and a box that always says the same thing would be
//! wrong the first time it is not that. So the text is built from what was
//! true at that moment: the error the surface failed with, and -- when the
//! code that failed knew more -- a detail it wrote here (for the WGL path,
//! the driver that was actually there and the version it offered).
//!
//! **Threading.** Surfaces are created on the app's thread, one at a time,
//! and the detail is read on the same thread right after the failure. It is
//! a plain buffer for that reason, not something shared.

const std = @import("std");

var detail_buf: [384]u8 = undefined;
var detail_len: usize = 0;

/// Forget any earlier detail. Called when a surface starts being created, so
/// a detail can only ever describe the failure that follows it.
pub fn clearDetail() void {
    detail_len = 0;
}

/// Record what the failing code knew, formatted. Truncated to the buffer.
pub fn noteDetail(comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&detail_buf, fmt, args) catch
        // Too long: keep what fits rather than nothing.
        detail_buf[0..];
    detail_len = written.len;
}

/// The detail recorded since the last `clearDetail`, or "".
pub fn detail() []const u8 {
    return detail_buf[0..detail_len];
}

/// The text for a failure: the error's name, then the detail if there is one.
/// Always null-terminated inside `buf`, truncated if it has to be.
pub fn describe(buf: []u8, err_name: []const u8, the_detail: []const u8) [:0]const u8 {
    std.debug.assert(buf.len > 0);
    const text = if (the_detail.len == 0)
        std.fmt.bufPrint(buf[0 .. buf.len - 1], "{s}", .{err_name})
    else
        std.fmt.bufPrint(buf[0 .. buf.len - 1], "{s}: {s}", .{ err_name, the_detail });
    const len = if (text) |t| t.len else |_| buf.len - 1;
    buf[len] = 0;
    return buf[0..len :0];
}

test "the text names the error and carries what the failing code knew" {
    var buf: [128]u8 = undefined;
    const t = describe(&buf, "VersionUnsupported", "the driver is \"D3D12 (Microsoft Basic Render Driver)\" (OpenGL 3.3)");
    try std.testing.expectEqualStrings(
        "VersionUnsupported: the driver is \"D3D12 (Microsoft Basic Render Driver)\" (OpenGL 3.3)",
        t,
    );
}

test "a failure with no detail still says which error it was" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("OutOfMemory", describe(&buf, "OutOfMemory", ""));
}

test "different failures give different text: nothing here is fixed wording" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    const one = describe(&a, "VersionUnsupported", "x");
    const two = describe(&b, "ContextFailed", "y");
    try std.testing.expect(!std.mem.eql(u8, one, two));
}

test "a detail is only the one noted since the last clear" {
    clearDetail();
    try std.testing.expectEqualStrings("", detail());
    noteDetail("refused {d}.{d}", .{ 4, 3 });
    try std.testing.expectEqualStrings("refused 4.3", detail());
    clearDetail();
    try std.testing.expectEqualStrings("", detail());
}

test "a text longer than the buffer is cut, not lost, and still terminated" {
    var buf: [8]u8 = undefined;
    const t = describe(&buf, "VersionUnsupported", "long");
    try std.testing.expectEqual(@as(usize, 7), t.len);
    try std.testing.expectEqual(@as(u8, 0), buf[7]);
}
