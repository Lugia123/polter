const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");

pub const ResourcesDir = struct {
    /// Avoid accessing these directly, use the app() and host() methods instead.
    app_path: ?[]const u8 = null,
    host_path: ?[]const u8 = null,

    /// Free resources held. Requires the same allocator as when resourcesDir()
    /// is called.
    pub fn deinit(self: *ResourcesDir, alloc: Allocator) void {
        if (self.app_path) |p| alloc.free(p);
        if (self.host_path) |p| alloc.free(p);
    }

    /// Get the directory to the bundled resources directory accessible
    /// by the application.
    pub fn app(self: *const ResourcesDir) ?[]const u8 {
        return self.app_path;
    }

    /// Get the directory to the bundled resources directory accessible
    /// by the host environment (i.e. for sandboxed applications). The
    /// returned directory might not be accessible from the application
    /// itself.
    ///
    /// In non-sandboxed environment, this should be the same as app().
    pub fn host(self: *const ResourcesDir) ?[]const u8 {
        return self.host_path orelse self.app_path;
    }
};

/// Whether a directory actually holds our resources.
///
/// One marker is enough, and the skills are the right one: they ship with
/// every build, they are ours alone, and their absence is exactly the
/// failure this is here to catch.
fn looksLikeOurs(alloc: Allocator, dir: []const u8) bool {
    const probe = std.fs.path.join(alloc, &.{ dir, "poltergeist" }) catch return false;
    defer alloc.free(probe);

    var d = std.Io.Dir.cwd().openDir(global.io(), probe, .{}) catch return false;
    d.close(global.io());
    return true;
}

/// Gets the directory to the bundled resources directory, if it
/// exists (not all platforms or packages have it). The output is
/// owned by the caller.
///
/// This is highly Ghostty-specific and can likely be generalized at
/// some point but we can cross that bridge if we ever need to.
pub fn resourcesDir(alloc: Allocator) !ResourcesDir {
    // Use the POLTER_RESOURCES_DIR environment variable in release builds.
    //
    // **Our own name, not Ghostty's.** Both can be installed on one
    // machine, and both set this for the terminals they spawn -- so
    // launching Polter from a Ghostty terminal had Polter reading
    // Ghostty's skills, plugins and terminfo. It found none of ours and
    // said nothing, because an empty resources directory is not an error.
    //
    // In debug builds we try using terminfo detection first instead, since
    // if debug Ghostty is launched by an older version of Ghostty, it
    // would inherit the old, stale resources of older Ghostty instead of the
    // freshly built ones under zig-out/share/ghostty.
    //
    // Note: we ALWAYS want to allocate here because the result is always
    // freed, do not try to use internal_os.getenv or posix getenv.
    if (comptime builtin.mode != .Debug) env: {
        const dir = global.environ().getAlloc(alloc, "POLTER_RESOURCES_DIR") catch |err| switch (err) {
            error.EnvironmentVariableMissing => break :env,
            else => return err,
        };

        // Checked, not merely taken. A stale value left in the
        // environment by an older install points at a directory that no
        // longer holds anything of ours, and an empty resources directory
        // fails silently: skills that do not load, plugins that are not
        // there, and nothing anywhere saying why.
        if (dir.len > 0 and looksLikeOurs(alloc, dir)) return .{ .app_path = dir };
    }

    // This is the sentinel value we look for in the path to know
    // we've found the resources directory.
    const sentinels = switch (comptime builtin.target.os.tag) {
        .windows => .{"terminfo/ghostty.terminfo"},
        .macos => .{"terminfo/78/xterm-ghostty"},
        .freebsd => .{ "site-terminfo/g/ghostty", "site-terminfo/x/xterm-ghostty" },
        else => .{ "terminfo/g/ghostty", "terminfo/x/xterm-ghostty" },
    };

    // Get the path to our running binary
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    var exe: []const u8 = exe_buf[0 .. std.process.executablePath(
        global.io(),
        &exe_buf,
    ) catch return .{}];

    // We have an exe path! Climb the tree looking for the terminfo
    // bundle as we expect it.
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (std.fs.path.dirname(exe)) |dir| {
        exe = dir;

        // On MacOS, we look for the app bundle path.
        if (comptime builtin.target.os.tag.isDarwin()) {
            inline for (sentinels) |sentinel| {
                if (try maybeDir(
                    &dir_buf,
                    dir,
                    "Contents/Resources",
                    sentinel,
                )) |v| {
                    return .{ .app_path = try std.fs.path.join(alloc, &.{ v, "ghostty" }) };
                }
            }
        }

        // On all platforms (except BSD), we look for a /usr/share style path. This
        // is valid even on Mac since there is nothing that requires
        // Ghostty to be in an app bundle.
        inline for (sentinels) |sentinel| {
            if (try maybeDir(
                &dir_buf,
                dir,
                if (builtin.target.os.tag == .freebsd) "local/share" else "share",
                sentinel,
            )) |v| {
                return .{ .app_path = try std.fs.path.join(alloc, &.{ v, "ghostty" }) };
            }
        }
    }

    // If terminfo detection failed in debug builds (somehow),
    // fallback and use the provided resources dir.
    if (comptime builtin.mode == .Debug) {
        if (global.environ().getAlloc(alloc, "POLTER_RESOURCES_DIR")) |dir| {
            if (dir.len > 0) return .{ .app_path = dir };
        } else |err| switch (err) {
            error.InvalidWtf8, error.EnvironmentVariableMissing => {},
            else => return err,
        }
    }

    return .{};
}

/// Little helper to check if the "base/sub/suffix" directory exists and
/// if so return true. The "suffix" is just used as a way to verify a directory
/// seems roughly right.
///
/// "buf" must be large enough to fit base + sub + suffix. This is generally
/// max_path_bytes so its not a big deal.
pub fn maybeDir(
    buf: []u8,
    base: []const u8,
    sub: []const u8,
    suffix: []const u8,
) !?[]const u8 {
    const path = try std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ base, sub, suffix });

    if (std.Io.Dir.accessAbsolute(global.io(), path, .{})) {
        const len = path.len - suffix.len - 1;
        return buf[0..len];
    } else |_| {
        // Folder doesn't exist. If a different error happens its okay
        // we just ignore it and move on.
    }

    return null;
}

const testing = std.testing;

test "a resources dir belonging to something else is not ours" {
    // Both Polter and Ghostty can be installed on one machine, and each
    // sets a resources directory for the terminals it spawns. Taking a
    // path on faith had Polter reading the other one's skills and plugins,
    // finding none of its own, and saying nothing -- an empty resources
    // directory is not an error, it is just empty.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const io = global.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const root = try std.fmt.allocPrint(alloc, "/tmp/polter-res-{x}", .{&raw});
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // Somebody else's: a directory with no skills of ours in it.
    const theirs = try std.fmt.allocPrint(alloc, "{s}/theirs", .{root});
    try std.Io.Dir.cwd().createDirPath(io, theirs);
    try testing.expect(!looksLikeOurs(alloc, theirs));

    // Ours.
    const ours = try std.fmt.allocPrint(alloc, "{s}/ours", .{root});
    const skills = try std.fmt.allocPrint(alloc, "{s}/poltergeist", .{ours});
    try std.Io.Dir.cwd().createDirPath(io, skills);
    try testing.expect(looksLikeOurs(alloc, ours));

    // And a path that is not there at all.
    try testing.expect(!looksLikeOurs(alloc, "/tmp/polter-no-such-resources-7f31"));
}
