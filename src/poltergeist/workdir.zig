//! Whether a directory a terminal is asked to open in can be opened in.
//!
//! **The bug this exists for** (task 1667, measured in the test session).
//! `role_launch` was handed a directory whose mode had lost its `x` bit: it
//! was there, it was a directory, and the checks said yes. The shell could
//! not enter it, started in `/` instead, and Codex came up there -- with no
//! word to anybody. The apprt logs and carries on, which is right for a
//! config file read at startup and wrong for a request somebody is waiting
//! on an answer to.
//!
//! So "is it a directory" is not the question; "can a process be in it" is.
//! Entering a directory needs search permission on it, and so does looking
//! anything up inside it -- `.` included. Measured on macOS: with the mode
//! `rw-r--r--`, `openat(dirfd, ".")` and `chdir` both fail with
//! `Permission denied`; with `rwxr-xr-x` both succeed. That lookup is what
//! is asked here, because it needs no `chdir` of this process.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    NotAbsolute,
    NoSuchDirectory,
    NotADirectory,
    /// There, a directory, and not one a process may be in.
    CannotEnterDirectory,
    OutOfMemory,
};

/// `cwd` as a null-terminated copy in `alloc`, when a terminal can be
/// opened in it; otherwise which of the four it is.
pub fn check(alloc: Allocator, io: std.Io, cwd: []const u8) Error![:0]const u8 {
    if (!std.fs.path.isAbsolute(cwd)) return error.NotAbsolute;

    var dir = std.Io.Dir.openDirAbsolute(io, cwd, .{}) catch |err| return switch (err) {
        error.NotDir => error.NotADirectory,
        error.AccessDenied, error.PermissionDenied => error.CannotEnterDirectory,
        else => error.NoSuchDirectory,
    };
    defer dir.close(io);

    const stat = dir.stat(io) catch return error.NoSuchDirectory;
    if (stat.kind != .directory) return error.NotADirectory;

    var inside = dir.openDir(io, ".", .{}) catch |err| return switch (err) {
        error.AccessDenied, error.PermissionDenied => error.CannotEnterDirectory,
        else => error.NoSuchDirectory,
    };
    inside.close(io);

    return try alloc.dupeZ(u8, cwd);
}

test "workdir: a directory that is there but cannot be entered is said to be so (task 1667)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const root = try std.fmt.allocPrint(aa, "/tmp/polter-workdir-{x}", .{&raw});
    const cwd = std.Io.Dir.cwd();
    const open = try std.fmt.allocPrint(aa, "{s}/open", .{root});
    const shut = try std.fmt.allocPrint(aa, "{s}/shut", .{root});
    const file = try std.fmt.allocPrint(aa, "{s}/file", .{root});
    try cwd.createDirPath(io, open);
    try cwd.createDirPath(io, shut);
    {
        var f = try cwd.createFile(io, file, .{});
        f.close(io);
    }
    // The mode the test account's directory had lost its x bit to.
    try cwd.setFilePermissions(io, shut, .fromMode(0o644), .{});
    defer {
        cwd.setFilePermissions(io, shut, .fromMode(0o755), .{}) catch {};
        cwd.deleteTree(io, root) catch {};
    }

    try testing.expectEqualStrings(open, try check(aa, io, open));
    try testing.expectError(error.CannotEnterDirectory, check(aa, io, shut));
    try testing.expectError(error.NotADirectory, check(aa, io, file));
    try testing.expectError(error.NoSuchDirectory, check(aa, io, try std.fmt.allocPrint(aa, "{s}/gone", .{root})));
    try testing.expectError(error.NotAbsolute, check(aa, io, "relative/dir"));
}
