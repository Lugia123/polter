//! Everything that is filed under a group's name, in one place.
//!
//! **A group's name is its identity** -- there is no id behind it -- so
//! renaming a group means finding every place that used the old name and
//! putting the new one there, on disk as well as in memory. The failure that
//! costs is the one nobody sees: a place that goes on using the old name
//! raises no error, and shows up months later as a group's history that
//! has quietly split in two.
//!
//! So the places are listed here, once, as four enums, and
//! `group_rename` (`App.chatRename` and `GroupRename.zig`) does its work by
//! `switch`ing over them **with no `else`**. Adding a value without saying
//! what renaming does to it does not compile.
//!
//! What stops a new place being added without being listed:
//!
//!   * a `daylog.GroupTree` has a required `owner: Root` field and no
//!     default, so a tree of groups' records cannot be made without naming
//!     one of the `Root`s;
//!   * what the type cannot see -- a new map keyed by a group's name, say --
//!     is caught by `tools/group-names-are-registered.py`, which lists every
//!     file allowed to hold a group's name as a key or a field, with a
//!     reason.

const std = @import("std");
const ChatLog = @import("ChatLog.zig");

/// A directory of per-group directories under the state directory:
/// `<state>/<tag>/<group>/<day>.jsonl`.
pub const Root = enum {
    /// What was said. Also holds each group's `group.json`.
    chat,

    /// Task events.
    tasks,

    /// Hourly snapshots.
    stats,

    /// Who was in the group, when, as what, and which agent session they
    /// ran (`SessionLog`, task 1511). What ties a terminal's transcript to
    /// the group, so it has to go wherever the group's name goes.
    sessions,

    pub fn subdir(self: Root) []const u8 {
        return @tagName(self);
    }
};

/// A file shared by every group, with one line per event and the group
/// named on each line. Renaming rewrites the lines that are this group's
/// and leaves every other line byte for byte as it was.
pub const Stream = enum {
    /// The current generation of the chat stream.
    chat_jsonl,

    /// The previous generation.
    chat_jsonl_1,

    /// Where it lives, relative to the state directory.
    pub fn path(self: Stream) []const u8 {
        return switch (self) {
            .chat_jsonl => "chat/chat.jsonl",
            .chat_jsonl_1 => "chat/chat.jsonl.1",
        };
    }
};

/// A table in memory that is keyed by, or holds, a group's name.
pub const Table = enum {
    /// `Chat.groups`.
    chat_groups,

    /// Every task's `group` field.
    task_group_field,

    /// `StatsLog.last`.
    stats_last,

    /// `MentionRetry.items`: a mention waiting to be typed again names its
    /// group, for marking the reader told and for the line that says it
    /// gave up (#60).
    mention_retries,
};

/// An open file or directory handle that points into a place a rename
/// replaces. Left open across the swap it would go on writing into the file
/// that was moved to the backup -- silently, because the write succeeds.
pub const Handle = enum {
    /// `ChatLog`'s open stream file.
    chat_log_stream,

    /// `ChatLog`'s open day file.
    chat_log_tree,

    /// `TaskLog`'s open day file.
    task_log_tree,

    /// `StatsLog`'s open day file.
    stats_log_tree,

    /// `SessionLog`'s open day file.
    session_log_tree,
};

/// Delete a group's directory under every `Root` of `state_dir` (task 1659):
/// the disk half of the control room's "Delete group", the only delete that
/// removes a record. Nothing else is touched -- not another group's
/// directory, not the streams every group shares.
///
/// **`chat` last.** It holds `group.json`, which is what makes a group come
/// back at the next start. Stopped part way, this leaves a group that is
/// still listed, with less in it, for the person to delete again -- never
/// directories that no listed group owns. A directory that is not there is
/// already deleted.
///
/// Every handle into these must have been let go first (`Handle`): Windows
/// will not delete a file that is open.
///
/// **The record's floor is held first** (`ChatLog.holdFloor`, task 1665).
/// The stream every group shares still has this group's lines, and the next
/// start fills the record in from the stream above the highest seq the
/// record holds -- which, with this group's directory gone, can be lower
/// than this group's last line. Without the held floor the group is written
/// back and listed again. Here rather than in the caller so that no way of
/// deleting a group can do the one without the other.
pub fn deleteGroupDirs(alloc: std.mem.Allocator, io: std.Io, state_dir: []const u8, group: []const u8) !void {
    // An empty or dotted name would be a path to something that is not this
    // group's: refused rather than joined. Names are checked long before
    // here (`Chat.isValidName`); this is the last place to be wrong.
    if (group.len == 0 or std.mem.indexOfAny(u8, group, "/\\") != null or
        std.mem.eql(u8, group, ".") or std.mem.eql(u8, group, "..")) return error.BadName;
    try ChatLog.holdFloor(alloc, io, state_dir);
    inline for (.{ false, true }) |chat_pass| inline for (comptime std.enums.values(Root)) |root| {
        if ((root == .chat) == chat_pass) {
            const path = try std.fs.path.join(alloc, &.{ state_dir, root.subdir(), group });
            defer alloc.free(path);
            try std.Io.Dir.cwd().deleteTree(io, path);
        }
    };
}

test "deleteGroupDirs: the group's directory under every root, and nothing else (task 1659)" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const state = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(state);

    inline for (comptime std.enums.values(Root)) |root| {
        for ([_][]const u8{ "doomed", "kept" }) |g| {
            const sub = try std.fs.path.join(testing.allocator, &.{ root.subdir(), g });
            defer testing.allocator.free(sub);
            try tmp.dir.createDirPath(io, sub);
            const file = try std.fs.path.join(testing.allocator, &.{ sub, "2026-10-17.jsonl" });
            defer testing.allocator.free(file);
            try tmp.dir.writeFile(io, .{ .sub_path = file, .data = "{\"group\":\"x\"}\n" });
        }
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "chat/chat.jsonl", .data = "{\"group\":\"doomed\"}\n" });

    try deleteGroupDirs(testing.allocator, io, state, "doomed");

    inline for (comptime std.enums.values(Root)) |root| {
        const gone = try std.fs.path.join(testing.allocator, &.{ root.subdir(), "doomed" });
        defer testing.allocator.free(gone);
        try testing.expectError(error.FileNotFound, tmp.dir.access(io, gone, .{}));
        const kept = try std.fs.path.join(testing.allocator, &.{ root.subdir(), "kept", "2026-10-17.jsonl" });
        defer testing.allocator.free(kept);
        try tmp.dir.access(io, kept, .{});
    }
    // The stream every group shares is not this one's to rewrite.
    try tmp.dir.access(io, "chat/chat.jsonl", .{});

    // Again: nothing there is nothing to do.
    try deleteGroupDirs(testing.allocator, io, state, "doomed");
    // And never a path that is not a group's.
    try testing.expectError(error.BadName, deleteGroupDirs(testing.allocator, io, state, ".."));
    try testing.expectError(error.BadName, deleteGroupDirs(testing.allocator, io, state, ""));
}
