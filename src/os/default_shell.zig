//! Which shell to start when the configuration does not name one.
//!
//! Only Windows needs this. Everywhere else the answer comes from the passwd
//! entry, and when that fails there is a single well-known name (`sh`) that
//! is present by definition. Windows has neither: nothing hands us the user's
//! shell, and the two candidates differ in whether they are there at all.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// Why there is no system PowerShell to start.
///
/// **Three causes, kept apart on purpose.** The caller logs the one it got,
/// and a reader of that log can act on it: a missing `SystemRoot` is a broken
/// environment, a path that did not fit is our bug, and a path that is simply
/// not there is a machine without the component. Collapsing them into one
/// "could not find a shell" would put a fourth silent cause next to the three
/// that were just pulled apart in the shell-detection log.
pub const Error = error{
    /// `SystemRoot` is not in the environment, so there is nothing to build
    /// the path from.
    NoSystemRoot,

    /// The path did not fit in the caller's buffer. Ours, not the machine's.
    PathTooLong,

    /// The path was built and nothing is at it.
    NotPresent,
};

/// Where Windows PowerShell lives, relative to `%SystemRoot%`.
///
/// **An absolute path rather than the bare name `powershell.exe`, and that
/// is the whole reason this file can be sure of its answer.** A bare name
/// makes "will this start" a question about `CreateProcessW`'s search order,
/// `PATH`, `PATHEXT` and the application directory -- a question that can
/// only be answered by trying it, and by then a surface already exists. An
/// absolute path turns the same question into "is this file there", which is
/// one call and cannot be subtly wrong.
///
/// Windows PowerShell 5.1 is an operating system component, not an
/// application: it ships in this location on every supported Windows. The
/// thing that is *not* guaranteed is `pwsh.exe` (PowerShell 7), which is a
/// separate install and absent on a normal machine -- defaulting to it would
/// trade today's "starts, but without shell integration" for "does not
/// start", which is not a repair.
pub const powershell_relative = "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";

/// Build the path. **No filesystem, and callable anywhere.**
///
/// Split out from the probe below so that the half that can be wrong in an
/// interesting way -- which string do we build -- is testable on the machine
/// the port is written on. The other half is one `access` call whose answer
/// comes from the operating system.
pub fn powershellPath(
    environ_map: *const std.process.Environ.Map,
    buf: []u8,
) error{ NoSystemRoot, PathTooLong }![]const u8 {
    const root = environ_map.get("SystemRoot") orelse return error.NoSystemRoot;

    var writer: std.Io.Writer = .fixed(buf);
    writer.writeAll(root) catch return error.PathTooLong;
    writer.writeAll(powershell_relative) catch return error.PathTooLong;
    return writer.buffered();
}

/// The absolute path of Windows PowerShell, or the reason there is none.
///
/// **Windows only**, and the guard is a compile error rather than a runtime
/// one: the path this builds is absolute on Windows and is not a path at all
/// anywhere else, and `accessAbsolute` asserts rather than returning an error
/// when handed something that is not absolute. A version of this that
/// "worked" off Windows would only be returning `NotPresent` for a machine
/// that was never asked the question.
///
/// The returned slice points into `buf`.
pub fn systemPowerShell(
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    buf: []u8,
) Error![]const u8 {
    comptime std.debug.assert(builtin.os.tag == .windows);

    const path = try powershellPath(environ_map, buf);
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return error.NotPresent;
    return path;
}

test "the path is built from SystemRoot" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var environ_map: std.process.Environ.Map = .init(testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("SystemRoot", "C:\\Windows");

    try testing.expectEqualStrings(
        "C:\\Windows" ++ powershell_relative,
        try powershellPath(&environ_map, &buf),
    );
}

test "no SystemRoot is its own answer" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var environ_map: std.process.Environ.Map = .init(testing.allocator);
    defer environ_map.deinit();
    try testing.expectError(
        error.NoSystemRoot,
        powershellPath(&environ_map, &buf),
    );
}

test "a buffer that cannot hold the path is our fault, not the machine's" {
    var buf: [4]u8 = undefined;
    var environ_map: std.process.Environ.Map = .init(testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("SystemRoot", "C:\\Windows");
    try testing.expectError(
        error.PathTooLong,
        powershellPath(&environ_map, &buf),
    );
}

test "the probe answers both ways" {
    // **Windows only, and both directions in one test on purpose.** A probe
    // that only ever answers "present" is indistinguishable from a correct
    // one on every machine we would normally run it on, so the cell that
    // matters is the one where the answer has to be "not present".
    //
    // Skipped rather than faked elsewhere: `systemPowerShell` cannot be
    // called off Windows at all (see its guard), and a version of this test
    // that asserted something about a fixture would be a green cell that
    // means nothing.
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    var buf: [std.fs.max_path_bytes]u8 = undefined;

    {
        // Present: the real environment, the real component.
        var environ_map = try std.process.Environ.Map.initFromEnviron(testing.allocator);
        defer environ_map.deinit();
        const path = try systemPowerShell(testing.io, &environ_map, &buf);
        try testing.expect(std.mem.endsWith(u8, path, "powershell.exe"));
    }

    {
        // Not present: a root that exists and has nothing under it.
        var td = try @import("TempDir.zig").init();
        defer td.deinit();
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs = try td.dir.realpath(testing.io, ".", &abs_buf);

        var environ_map: std.process.Environ.Map = .init(testing.allocator);
        defer environ_map.deinit();
        try environ_map.put("SystemRoot", abs);

        try testing.expectError(
            Error.NotPresent,
            systemPowerShell(testing.io, &environ_map, &buf),
        );
    }
}
