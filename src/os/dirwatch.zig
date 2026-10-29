//! A recursive directory watch: the OS half of `poltergeist/files/Watch.zig`
//! (task 2145 C5, PLAN §1.3). macOS: FSEvents. Windows:
//! `ReadDirectoryChangesW` with the subtree flag. Nothing else is watched
//! for; on other systems `start` fails with `Unsupported`.
//!
//! **The callback runs on a thread this file owns**, once per changed path,
//! with the absolute path as the OS spells it (on macOS the real path, so
//! give `root` already real). It must not block and must not keep `path`.
//! Which paths matter, and how often to tell anyone, is `Watch.zig`'s.
//!
//! **A watch that lost events says so** (`Event.overflow`): the OS buffer
//! overflowed, FSEvents dropped events or asked for a rescan, the watched
//! root moved, or the Windows read failed and the thread is gone. Nothing
//! names a path then; the reader must look again.

const std = @import("std");
const builtin = @import("builtin");

/// What the callback is told: a changed path, or that events were lost.
pub const Event = union(enum) {
    path: []const u8,
    overflow,
};

pub const Callback = *const fn (ctx: ?*anyopaque, ev: Event) void;

/// FSEvents flags (`FSEventStreamEventFlags`) that mean events were lost or
/// the tree must be rescanned: MustScanSubDirs, UserDropped, KernelDropped,
/// RootChanged. Pure, so it is tested on every host.
pub const fsevents_overflow_flags: u32 = 0x1 | 0x2 | 0x4 | 0x20;

pub fn fseventsOverflow(flags: u32) bool {
    return flags & fsevents_overflow_flags != 0;
}

/// `ReadDirectoryChangesW` completing with zero bytes is the buffer having
/// overflowed (`ERROR_NOTIFY_ENUM_DIR`): changes happened that it cannot name.
pub fn windowsOverflow(got: u32) bool {
    return got == 0;
}

/// What `WaitForMultipleObjects(io, stop)` returned.
pub const Wait = enum { io, stop, failed };

pub fn windowsWait(r: u32) Wait {
    return switch (r) {
        0 => .io, // WAIT_OBJECT_0
        1 => .stop, // WAIT_OBJECT_0 + 1
        else => .failed, // WAIT_FAILED, abandoned, timeout
    };
}

pub const Error = error{ Unsupported, WatchFailed } || std.mem.Allocator.Error;

const Impl = switch (builtin.os.tag) {
    .macos => @import("dirwatch_mac.zig"),
    .windows => @import("dirwatch_windows.zig"),
    else => struct {
        pub fn start(_: std.mem.Allocator, _: []const u8, _: Callback, _: ?*anyopaque) Error!*@This() {
            return error.Unsupported;
        }
        pub fn stop(_: *@This()) void {}
    },
};

pub const Handle = Impl;

/// Begin watching `root` and everything under it. `stop` ends it, and the
/// callback is not called after `stop` returns.
pub fn start(alloc: std.mem.Allocator, root: []const u8, cb: Callback, ctx: ?*anyopaque) Error!*Handle {
    return Impl.start(alloc, root, cb, ctx);
}

pub fn stop(h: *Handle) void {
    h.stop();
}

const testing = std.testing;

test "2569 C5 v2: FSEvents flags that mean events were lost" {
    try testing.expect(fseventsOverflow(0x1)); // MustScanSubDirs
    try testing.expect(fseventsOverflow(0x2)); // UserDropped
    try testing.expect(fseventsOverflow(0x4)); // KernelDropped
    try testing.expect(fseventsOverflow(0x20)); // RootChanged
    try testing.expect(fseventsOverflow(0x10 | 0x1)); // together with ItemCreated-style flags
    // An ordinary file event (FileEvents|ItemModified) is not one.
    try testing.expect(!fseventsOverflow(0x10 | 0x1000));
    try testing.expect(!fseventsOverflow(0));
}

test "2569 C5 v2: Windows zero bytes is an overflow, and the wait result is told apart" {
    try testing.expect(windowsOverflow(0));
    try testing.expect(!windowsOverflow(12));
    try testing.expectEqual(Wait.io, windowsWait(0));
    try testing.expectEqual(Wait.stop, windowsWait(1));
    try testing.expectEqual(Wait.failed, windowsWait(0xFFFFFFFF)); // WAIT_FAILED
    try testing.expectEqual(Wait.failed, windowsWait(0x102)); // WAIT_TIMEOUT
}
