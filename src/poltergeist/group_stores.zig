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

/// A directory of per-group directories under the state directory:
/// `<state>/<tag>/<group>/<day>.jsonl`.
pub const Root = enum {
    /// What was said. Also holds each group's `group.json`.
    chat,

    /// Task events.
    tasks,

    /// Hourly snapshots.
    stats,

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
};
