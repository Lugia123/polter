//! What Polter pins a terminal's name to when Polter is the one opening it.
//!
//! **A terminal nobody names is called whatever its program says.** An agent
//! CLI sets its own title (`Claude Code`) on every prompt, so a tab full of
//! workers reads `Claude Code` end to end -- in the tab strip and in
//! `terminal_list` alike -- and neither the person nor the supervisor can
//! tell which one is the developer and which the tester (issue #77).
//!
//! An explicit `set_surface_title` pins the stored title, and a title the
//! program reports afterwards is remembered but does not replace it
//! (`apprt/title.zig`). So opening a terminal with a name is all it takes,
//! and nothing here takes that pin back: a later `set_surface_title` from a
//! person or an agent still wins, and an empty one still unpins.
//!
//! The names, in one place:
//!   * a squad seat is `<seat alias>·<task number>` -- `开发·3087`;
//!   * a bare role is the role's own name, as `role_list` gives it;
//!   * a `terminal_open` terminal is the last part of the directory it
//!     opened in (`/Users/me/ghostty` -> `ghostty`), or `terminal` when
//!     there is no name to take.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Between a seat's alias and its task number.
pub const seat_separator = "·";

/// What a terminal is called when there is no directory name to take.
pub const fallback = "terminal";

/// A squad seat's name: the alias, the task it sits in. The task number is
/// what makes two seats of the same role in two tasks tell apart, and the
/// alias is what makes two seats of one task tell apart.
pub fn seatName(alloc: Allocator, alias: []const u8, task: u64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}" ++ seat_separator ++ "{d}", .{ alias, task });
}

/// The last part of `path`, which is what a terminal opened there is called.
///
/// Both separators are taken on every platform: the name is read from a
/// path the caller wrote, not from one this process resolved, and a
/// Windows-shaped path reaches here on a machine that is not Windows (a
/// `cwd` from a remote request, a worktree path in a record).
///
/// `terminal` when there is nothing to take: an empty path, a root, a
/// trailing `..`, or a bare drive (`C:`). A name of `.` would be worse than
/// no name, and a name is only ever a hint.
pub fn directoryName(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and isSeparator(path[end - 1])) end -= 1;
    if (end == 0) return fallback;

    var start = end;
    while (start > 0 and !isSeparator(path[start - 1])) start -= 1;
    const last = path[start..end];
    if (last.len == 0) return fallback;
    if (std.mem.eql(u8, last, ".") or std.mem.eql(u8, last, "..")) return fallback;
    // `C:` and the like: a drive, not a directory with a name.
    if (last.len == 2 and last[1] == ':') return fallback;
    return last;
}

fn isSeparator(c: u8) bool {
    return c == '/' or c == '\\';
}

const testing = std.testing;

test "a directory is called by its last part, whichever way the separator leans" {
    try testing.expectEqualStrings("ghostty", directoryName("/Users/me/ghostty"));
    try testing.expectEqualStrings("ghostty", directoryName("/Users/me/ghostty/"));
    try testing.expectEqualStrings("ghostty", directoryName("/Users/me/ghostty///"));
    try testing.expectEqualStrings("ghostty", directoryName("C:\\Users\\me\\ghostty"));
    try testing.expectEqualStrings("ghostty", directoryName("C:\\Users\\me\\ghostty\\"));
    try testing.expectEqualStrings("work", directoryName("work"));
    try testing.expectEqualStrings("my dir", directoryName("/tmp/my dir"));
}

test "nothing to take is `terminal`, never a root or a dot" {
    try testing.expectEqualStrings(fallback, directoryName(""));
    try testing.expectEqualStrings(fallback, directoryName("/"));
    try testing.expectEqualStrings(fallback, directoryName("///"));
    try testing.expectEqualStrings(fallback, directoryName("C:\\"));
    try testing.expectEqualStrings(fallback, directoryName("C:"));
    try testing.expectEqualStrings(fallback, directoryName("."));
    try testing.expectEqualStrings(fallback, directoryName(".."));
    try testing.expectEqualStrings(fallback, directoryName("/tmp/.."));
}

test "a seat is its alias, a middle dot, and the task it sits in" {
    const alloc = testing.allocator;
    const name = try seatName(alloc, "开发", 3087);
    defer alloc.free(name);
    try testing.expectEqualStrings("开发·3087", name);
}
