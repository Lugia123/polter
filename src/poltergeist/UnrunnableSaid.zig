//! The plugins whose "nothing here can start it" line has already been put
//! in the log (task 3241).
//!
//! **The sentence is a fact about the install, not about the scan.** A
//! resident plugin that names a file this system cannot start is skipped
//! every time `scanPlugins` runs -- at startup, on every `plugin_list`, and
//! therefore on every five-second tick of the Windows settings window. The
//! line was written on all of them, which is a log that says the same news
//! forever; `dev-docs/poltergeist/provisioning.md` §9.4 already describes it
//! as said once.
//!
//! **Per key, and not one flag for the process.** Two plugins with nothing to
//! run here are two facts, and one flag would report the first and hide the
//! second. `forget` is the other half: a plugin that can run after an update
//! is no longer being reported, so if it stops being startable again that is
//! news.

const UnrunnableSaid = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Plugin keys whose line has been said. The keys are owned.
keys: std.StringHashMapUnmanaged(void) = .empty,

/// True the first time `key` is offered and false every time after -- what
/// `scanPlugins` logs on.
///
/// **A failed allocation says the line rather than swallowing it.** The map
/// is only there to stop a repeat; losing the one useful line to a failed
/// `dupe` would trade a noisy log for a silent one.
pub fn first(self: *UnrunnableSaid, alloc: Allocator, key: []const u8) bool {
    if (self.keys.contains(key)) return false;
    const owned = alloc.dupe(u8, key) catch return true;
    self.keys.put(alloc, owned, {}) catch {
        alloc.free(owned);
        return true;
    };
    return true;
}

/// This plugin can run now. The next time it cannot, say so again.
pub fn forget(self: *UnrunnableSaid, alloc: Allocator, key: []const u8) void {
    const entry = self.keys.fetchRemove(key) orelse return;
    alloc.free(entry.key);
}

pub fn deinit(self: *UnrunnableSaid, alloc: Allocator) void {
    var it = self.keys.keyIterator();
    while (it.next()) |key| alloc.free(key.*);
    self.keys.deinit(alloc);
}

const testing = std.testing;

test "3241: a plugin's line is said once, and another plugin still has its own" {
    const alloc = testing.allocator;
    var said: UnrunnableSaid = .{};
    defer said.deinit(alloc);

    // The scan that runs again -- `plugin_list` reads the directories afresh,
    // and the settings window asks it every five seconds -- must not repeat
    // the first plugin's line...
    try testing.expect(said.first(alloc, "archive"));
    try testing.expect(!said.first(alloc, "archive"));
    try testing.expect(!said.first(alloc, "archive"));

    // ...and must not let it hide a second plugin's, which is the whole
    // reason this is keyed rather than one flag.
    try testing.expect(said.first(alloc, "feishu"));
    try testing.expect(!said.first(alloc, "feishu"));
}

test "3241: a plugin that can run again is reported again if it stops being startable" {
    const alloc = testing.allocator;
    var said: UnrunnableSaid = .{};
    defer said.deinit(alloc);

    try testing.expect(said.first(alloc, "archive"));
    try testing.expect(!said.first(alloc, "archive"));

    // Updated, and now startable: `scanPlugins` forgets it. Forgetting a key
    // nobody said is a no-op, not a trap.
    said.forget(alloc, "archive");
    said.forget(alloc, "never-said");

    // The next release takes the ability away again: news, not silence.
    try testing.expect(said.first(alloc, "archive"));
    try testing.expect(!said.first(alloc, "archive"));
}
