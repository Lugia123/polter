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

/// Which PowerShell `systemShell` found.
pub const Kind = enum {
    /// PowerShell 7, from either place in `pwsh_locations`.
    pwsh,
    /// Windows PowerShell 5.1, the operating system component.
    windows_powershell,
};

pub const Found = struct {
    path: []const u8,
    kind: Kind,
};

/// Where PowerShell 7 lives when it is installed, **in the order they are
/// tried**: the MSI (which is also what `winget` installs) under
/// `%ProgramFiles%`, then the Microsoft Store's app execution alias.
///
/// Absolute for the reason `powershell_relative` gives. A `pwsh` that is only
/// on `PATH` -- Scoop's shim, a zip unpacked somewhere -- is not found here;
/// `command = pwsh` names it.
pub const pwsh_locations = [_]struct { variable: []const u8, relative: []const u8 }{
    .{ .variable = "ProgramFiles", .relative = "\\PowerShell\\7\\pwsh.exe" },
    .{ .variable = "LOCALAPPDATA", .relative = "\\Microsoft\\WindowsApps\\pwsh.exe" },
};

/// The shell to start: **PowerShell 7 when it is installed, Windows
/// PowerShell otherwise** (task 1778), or Windows PowerShell's own reason
/// for not being there.
///
/// PowerShell 7 is preferred because its pipeline is UTF-8 where 5.1's is
/// ASCII, and it is what somebody who installed it expects to get. Its
/// absence is the ordinary case and is not an error: a location whose
/// variable is unset, or whose path does not fit, is passed over the same
/// way as one where nothing is installed.
///
/// `exists` answers "is this file there" -- `systemShell` passes the real
/// check, a test passes its own, so the order is testable anywhere. The
/// returned path points into `buf`.
pub fn pick(
    environ_map: *const std.process.Environ.Map,
    buf: []u8,
    exists: anytype,
) Error!Found {
    for (pwsh_locations) |loc| {
        const root = environ_map.get(loc.variable) orelse continue;
        var writer: std.Io.Writer = .fixed(buf);
        writer.writeAll(root) catch continue;
        writer.writeAll(loc.relative) catch continue;
        const path = writer.buffered();
        if (exists.check(path)) return .{ .path = path, .kind = .pwsh };
    }

    const path = try powershellPath(environ_map, buf);
    if (!exists.check(path)) return error.NotPresent;
    return .{ .path = path, .kind = .windows_powershell };
}

/// `pick` against the filesystem. **Windows only**, for the reason
/// `systemPowerShell` gives.
pub fn systemShell(
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    buf: []u8,
) Error!Found {
    comptime std.debug.assert(builtin.os.tag == .windows);
    const Fs = struct {
        io: std.Io,
        fn check(self: @This(), path: []const u8) bool {
            std.Io.Dir.accessAbsolute(self.io, path, .{}) catch return false;
            return true;
        }
    };
    return pick(environ_map, buf, Fs{ .io = io });
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
    // **Windows only, and both directions from one map on purpose.**
    //
    // A probe that only ever answers "present" is indistinguishable from a
    // correct one on every machine we would normally run it on, so the cell
    // that matters is the one where the answer has to be "not present".
    //
    // **Both halves start from the real environment, and the present half
    // runs first.** An empty map would make the "not present" half pass for a
    // reason that has nothing to do with the probe -- the mirror image of the
    // failure this test exists to catch. If the map were empty, the assertion
    // below and then the present half would both fail before the negative
    // half is ever reached.
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var environ_map = try std.testing.environ.createMap(testing.allocator);
    defer environ_map.deinit();

    // The map is the machine's, not an empty one.
    try testing.expect(environ_map.get("SystemRoot") != null);

    // Present.
    const path = try systemPowerShell(testing.io, &environ_map, &buf);
    try testing.expect(std.mem.endsWith(u8, path, "powershell.exe"));

    // Not present: the same map, with a root that cannot be there.
    //
    // Derived from the real root rather than invented, so this half is still
    // reading the machine's own environment -- and it is absolute for the
    // same reason the real one is, which `accessAbsolute` requires.
    var fake_buf: [std.fs.max_path_bytes]u8 = undefined;
    var fake: std.Io.Writer = .fixed(&fake_buf);
    try fake.writeAll(environ_map.get("SystemRoot").?);
    try fake.writeAll("\\__no_such_directory__");
    try environ_map.put("SystemRoot", fake.buffered());

    try testing.expectError(
        Error.NotPresent,
        systemPowerShell(testing.io, &environ_map, &buf),
    );
}

/// A filesystem for `pick` that has exactly the paths it is given.
const FakeFs = struct {
    present: []const []const u8,
    fn check(self: FakeFs, path: []const u8) bool {
        for (self.present) |p| if (std.mem.eql(u8, p, path)) return true;
        return false;
    }
};

fn testMap() !std.process.Environ.Map {
    var m: std.process.Environ.Map = .init(testing.allocator);
    errdefer m.deinit();
    try m.put("SystemRoot", "C:\\Windows");
    try m.put("ProgramFiles", "C:\\Program Files");
    try m.put("LOCALAPPDATA", "C:\\Users\\u\\AppData\\Local");
    return m;
}

const msi_pwsh = "C:\\Program Files\\PowerShell\\7\\pwsh.exe";
const store_pwsh = "C:\\Users\\u\\AppData\\Local\\Microsoft\\WindowsApps\\pwsh.exe";
const winps = "C:\\Windows" ++ powershell_relative;

test "pick (1778): PowerShell 7 wins over Windows PowerShell when both are there" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var m = try testMap();
    defer m.deinit();
    const found = try pick(&m, &buf, FakeFs{ .present = &.{ winps, msi_pwsh } });
    try testing.expectEqual(Kind.pwsh, found.kind);
    try testing.expectEqualStrings(msi_pwsh, found.path);
}

test "pick (1778): the Store's pwsh is found when the MSI's is not" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var m = try testMap();
    defer m.deinit();
    const found = try pick(&m, &buf, FakeFs{ .present = &.{ winps, store_pwsh } });
    try testing.expectEqual(Kind.pwsh, found.kind);
    try testing.expectEqualStrings(store_pwsh, found.path);
}

test "pick (1778): no PowerShell 7 is the ordinary case, and gives Windows PowerShell" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var m = try testMap();
    defer m.deinit();
    // Not even the variables: a location that cannot be built is passed over.
    _ = m.swapRemove("ProgramFiles");
    _ = m.swapRemove("LOCALAPPDATA");
    const found = try pick(&m, &buf, FakeFs{ .present = &.{winps} });
    try testing.expectEqual(Kind.windows_powershell, found.kind);
    try testing.expectEqualStrings(winps, found.path);
}

test "pick (1778): nothing at all keeps Windows PowerShell's own reason" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var m = try testMap();
    defer m.deinit();
    try testing.expectError(error.NotPresent, pick(&m, &buf, FakeFs{ .present = &.{} }));
    _ = m.swapRemove("SystemRoot");
    try testing.expectError(error.NoSystemRoot, pick(&m, &buf, FakeFs{ .present = &.{} }));
}
