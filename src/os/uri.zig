const std = @import("std");

pub const ParseOptions = struct {
    /// Parse MAC addresses in the host component.
    ///
    /// This is useful when the "Private Wi-Fi address" is enabled on macOS,
    /// which sets the hostname to a rotating MAC address (12:34:56:ab:cd:ef).
    mac_address: bool = false,

    /// Return the full, raw, unencoded path string. Any query and fragment
    /// values will be return as part of the path instead of as distinct
    /// fields.
    raw_path: bool = false,
};

pub const ParseError = std.Uri.ParseError || error{InvalidMacAddress};

/// Parses a URI from the given string.
///
/// This extends std.Uri.parse with some additional ParseOptions.
pub fn parse(text: []const u8, options: ParseOptions) ParseError!std.Uri {
    var uri = std.Uri.parse(text) catch |err| uri: {
        // We can attempt to re-parse the text as a URI that has a MAC address
        // in its host field (which tripped up std.Uri.parse's port parsing):
        //
        //      file://12:34:56:78:90:aa/path/to/file
        //                            ^^ InvalidPort
        //
        if (err != error.InvalidPort or !options.mac_address) return err;

        // We can assume that the initial Uri.parse already validated the
        // scheme, so we only need to find its bounds within the string.
        const scheme_end = std.mem.indexOf(u8, text, "://") orelse {
            return error.InvalidFormat;
        };
        const scheme = text[0..scheme_end];

        // We similarly find the bounds of the host component by looking
        // for the first slash (/) after the scheme. This is all we need
        // for this case because the resulting slice can be unambiguously
        // determined to be a MAC address (or not).
        const host_start = scheme_end + "://".len;
        const host_end = std.mem.indexOfScalarPos(u8, text, host_start, '/') orelse text.len;
        const mac_address = text[host_start..host_end];
        if (!isValidMacAddress(mac_address)) return error.InvalidMacAddress;

        // Parse the rest of the text (starting with the path component) as a
        // partial URI and then add our MAC address as its host component.
        var uri = try std.Uri.parseAfterScheme(scheme, text[host_end..]);
        uri.host = .{ .percent_encoded = mac_address };
        break :uri uri;
    };

    // When MAC address parsing is enabled, we need to handle the case where
    // std.Uri.parse parsed the address's last octet as a numeric port number.
    // We use a few heuristics to identify this case (14 characters, 4 colons)
    // and then "repair" the result by reassign the .host component to the full
    // MAC address and clearing the .port component.
    //
    //    12:34:56:78:90:99 -> [12:34:56:78:90, 99] -> 12:34:56:78:90:99
    //    (original host)      (parsed host + port)    (restored host)
    //
    if (options.mac_address and uri.host != null) mac: {
        const host = uri.host.?.percent_encoded;
        if (host.len != 14 or std.mem.count(u8, host, ":") != 4) break :mac;

        const port = uri.port orelse break :mac;
        if (port > 99) break :mac;

        // std.Uri.parse returns slices pointing into the original text string.
        const host_start = @intFromPtr(host.ptr) - @intFromPtr(text.ptr);
        const path_start = @intFromPtr(uri.path.percent_encoded.ptr) - @intFromPtr(text.ptr);
        const mac_address = text[host_start..path_start];
        if (!isValidMacAddress(mac_address)) return error.InvalidMacAddress;

        uri.host = .{ .percent_encoded = mac_address };
        uri.port = null;
    }

    // When the raw_path option is active, return everything after the authority
    // (host) in the .path component, including any query and fragment values.
    if (options.raw_path) {
        // std.Uri.parse returns slices pointing into the original text string.
        const path_start = @intFromPtr(uri.path.percent_encoded.ptr) - @intFromPtr(text.ptr);
        uri.path = .{ .raw = text[path_start..] };
        uri.query = null;
        uri.fragment = null;
    }

    return uri;
}

test "parse: mac_address" {
    const testing = @import("std").testing;

    // Numeric MAC address without a port
    const uri1 = try parse("file://00:12:34:56:78:90/path", .{ .mac_address = true });
    try testing.expectEqualStrings("file", uri1.scheme);
    try testing.expectEqualStrings("00:12:34:56:78:90", uri1.host.?.percent_encoded);
    try testing.expectEqualStrings("/path", uri1.path.percent_encoded);
    try testing.expectEqual(null, uri1.port);

    // Numeric MAC address with a port
    const uri2 = try parse("file://00:12:34:56:78:90:999/path", .{ .mac_address = true });
    try testing.expectEqualStrings("file", uri2.scheme);
    try testing.expectEqualStrings("00:12:34:56:78:90", uri2.host.?.percent_encoded);
    try testing.expectEqualStrings("/path", uri2.path.percent_encoded);
    try testing.expectEqual(999, uri2.port);

    // Alphabetic MAC address without a port
    const uri3 = try parse("file://ab:cd:ef:ab:cd:ef/path", .{ .mac_address = true });
    try testing.expectEqualStrings("file", uri3.scheme);
    try testing.expectEqualStrings("ab:cd:ef:ab:cd:ef", uri3.host.?.percent_encoded);
    try testing.expectEqualStrings("/path", uri3.path.percent_encoded);
    try testing.expectEqual(null, uri3.port);

    // Alphabetic MAC address with a port
    const uri4 = try parse("file://ab:cd:ef:ab:cd:ef:999/path", .{ .mac_address = true });
    try testing.expectEqualStrings("file", uri4.scheme);
    try testing.expectEqualStrings("ab:cd:ef:ab:cd:ef", uri4.host.?.percent_encoded);
    try testing.expectEqualStrings("/path", uri4.path.percent_encoded);
    try testing.expectEqual(999, uri4.port);

    // Numeric MAC address without a path component
    const uri5 = try parse("file://00:12:34:56:78:90", .{ .mac_address = true });
    try testing.expectEqualStrings("file", uri5.scheme);
    try testing.expectEqualStrings("00:12:34:56:78:90", uri5.host.?.percent_encoded);
    try testing.expect(uri5.path.isEmpty());

    // Alphabetic MAC address without a path component
    const uri6 = try parse("file://ab:cd:ef:ab:cd:ef", .{ .mac_address = true });
    try testing.expectEqualStrings("file", uri6.scheme);
    try testing.expectEqualStrings("ab:cd:ef:ab:cd:ef", uri6.host.?.percent_encoded);
    try testing.expect(uri6.path.isEmpty());

    // Invalid MAC addresses
    try testing.expectError(error.InvalidMacAddress, parse(
        "file://zz:zz:zz:zz:zz:00/path",
        .{ .mac_address = true },
    ));
    try testing.expectError(error.InvalidMacAddress, parse(
        "file://zz:zz:zz:zz:zz:zz/path",
        .{ .mac_address = true },
    ));
}

test "parse: raw_path" {
    const testing = @import("std").testing;

    const text = "file://localhost/path??#fragment";
    var buf: [256]u8 = undefined;

    const uri1 = try parse(text, .{ .raw_path = false });
    try testing.expectEqualStrings("file", uri1.scheme);
    try testing.expectEqualStrings("localhost", uri1.host.?.percent_encoded);
    try testing.expectEqualStrings("/path", try uri1.path.toRaw(&buf));
    try testing.expectEqualStrings("?", uri1.query.?.percent_encoded);
    try testing.expectEqualStrings("fragment", uri1.fragment.?.percent_encoded);

    const uri2 = try parse(text, .{ .raw_path = true });
    try testing.expectEqualStrings("file", uri2.scheme);
    try testing.expectEqualStrings("localhost", uri2.host.?.percent_encoded);
    try testing.expectEqualStrings("/path??#fragment", try uri2.path.toRaw(&buf));
    try testing.expectEqual(null, uri2.query);
    try testing.expectEqual(null, uri2.fragment);

    const uri3 = try parse("file://localhost", .{ .raw_path = true });
    try testing.expectEqualStrings("file", uri3.scheme);
    try testing.expectEqualStrings("localhost", uri3.host.?.percent_encoded);
    try testing.expect(uri3.path.isEmpty());
    try testing.expectEqual(null, uri3.query);
    try testing.expectEqual(null, uri3.fragment);
}

/// Checks if a string represents a valid MAC address, e.g. 12:34:56:ab:cd:ef.
fn isValidMacAddress(s: []const u8) bool {
    if (s.len != 17) return false;

    for (s, 0..) |c, i| {
        if (i % 3 == 2) {
            if (c != ':') return false;
        } else {
            switch (c) {
                '0'...'9', 'A'...'F', 'a'...'f' => {},
                else => return false,
            }
        }
    }

    return true;
}

test isValidMacAddress {
    const testing = @import("std").testing;

    try testing.expect(isValidMacAddress("01:23:45:67:89:Aa"));
    try testing.expect(isValidMacAddress("Aa:Bb:Cc:Dd:Ee:Ff"));

    try testing.expect(!isValidMacAddress(""));
    try testing.expect(!isValidMacAddress("00:23:45"));
    try testing.expect(!isValidMacAddress("00:23:45:Xx:Yy:Zz"));
    try testing.expect(!isValidMacAddress("01-23-45-67-89-Aa"));
    try testing.expect(!isValidMacAddress("01:23:45:67:89:Aa:Bb"));
}

/// Turn the path component of an OSC 7 URI into a native Windows path.
///
/// `std.Uri` hands back `/C:/Users/ghostty` for `file:///C:/Users/ghostty`, and
/// every consumer of the terminal's pwd -- `std.fs.path.resolve`, the host's
/// `working_directory` for a new tab, the shell it spawns -- wants
/// `C:\Users\ghostty`. This is that one step.
///
/// **Not gated on the target OS.** The conversion is a property of the path
/// syntax being produced, not of the machine doing the producing, so it
/// compiles and is tested everywhere. A function that only existed on Windows
/// could only be tested on Windows, and the rules here are exactly the kind
/// that are wrong quietly.
///
/// # What it accepts
///
///   - `/C:/Users/x` and `C:/Users/x` alike. **Both, on purpose**: our own
///     shell integrations build the URI by concatenating the hostname and
///     `$PWD` (`kitty-shell-cwd://$HOSTNAME$PWD`), which on a POSIX system
///     gains its separator from `$PWD`'s leading `/`. A Windows `$PWD` starts
///     `C:\`, so a script that does the same concatenation produces
///     `kitty-shell-cwd://MYPCC:\Users\x` -- hostname and path fused. Taking
///     both forms means a script written either way lands somewhere real
///     instead of silently landing nowhere.
///   - Separators either way round, because `raw_path` URIs pass backslashes
///     through untouched.
///   - `//server/share/x` as the UNC `\\server\share\x`. **The UNC has to
///     arrive inside the path, not as the URI's host.** `file://server/...`
///     is refused earlier by the hostname check, and that refusal is right:
///     nothing can distinguish "my working directory is on \\server\share"
///     from "an SSH session claims to be on the host `server`". Keeping the
///     local machine as the host and the UNC in the path is the only form
///     that is both expressible and safe. This is not hypothetical --
///     `Get-Location` on a mapped share returns exactly `\\server\share\x`.
///
/// # What it refuses, and why refusing matters
///
/// A path with no drive and no UNC prefix (`/`, `/share/dir`) returns null.
/// **An implementation that merely flipped the slashes would turn
/// `/share/dir` into `\share\dir`, which looks entirely normal and is a
/// string no Windows API can use** -- the pwd would be set, every consumer
/// would fail, and nothing would say why. A cwd is always absolute, so
/// refusing costs nothing real.
///
/// Returns a slice of `buf`, or null. `buf` must be at least one byte longer
/// than `path` (a bare `C:` grows to `C:\`).
pub fn windowsPath(buf: []u8, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;

    const isSep = struct {
        fn f(c: u8) bool {
            return c == '/' or c == '\\';
        }
    }.f;

    // `\\?\...` (extended length) and `\\.\...` (device namespace) are
    // passed through untouched. They have the same shape as a UNC and would
    // otherwise be accepted by accident; a shell reporting a path longer than
    // MAX_PATH really does produce the first of them, so this is deliberate
    // rather than tolerated.
    const extended = path.len >= 4 and
        isSep(path[0]) and isSep(path[1]) and
        (path[2] == '?' or path[2] == '.') and
        isSep(path[3]);

    // A UNC needs two leading separators, a server, and a share. `//server`
    // on its own names a machine, not a directory, so it is not a cwd.
    const unc = unc: {
        if (extended) break :unc false;
        if (path.len < 3) break :unc false;
        if (!isSep(path[0]) or !isSep(path[1]) or isSep(path[2])) break :unc false;
        // There must be a separator after the server name, with something
        // after it: `//server/share`, not `//server` or `//server/`.
        const rest = path[2..];
        const i = std.mem.indexOfAny(u8, rest, "/\\") orelse break :unc false;
        // **The server segment has to look like a host, not a drive.**
        // `//C:/x` is a single stray leading separator away from `/C:/x` --
        // and concatenating a URI prefix onto a path is exactly where that
        // stray separator comes from. Read as a UNC it produces `\\C:\x`,
        // a string no Windows API can use: the same class of result the
        // no-drive rule below exists to prevent, arriving through another
        // door.
        if (std.mem.indexOfScalar(u8, rest[0..i], ':') != null) break :unc false;
        break :unc i + 1 < rest.len;
    };

    const src = if (unc or extended)
        path
    else if (isSep(path[0]))
        path[1..]
    else
        path;

    if (!unc and !extended) {
        // A drive letter, a colon, and then either nothing or a separator.
        if (src.len < 2) return null;
        if (!std.ascii.isAlphabetic(src[0])) return null;
        if (src[1] != ':') return null;
        // **`C:foo` is not an absolute path.** It names `foo` relative to
        // whatever the current directory on drive C happens to be -- state
        // this terminal does not hold and the shell did not send. A bare
        // `C:` is allowed just below because it has no relative part left to
        // resolve: the only absolute reading of it is the drive root.
        if (src.len > 2 and !isSep(src[2])) return null;
    }

    if (src.len + 1 > buf.len) return null;
    for (src, 0..) |c, i| buf[i] = if (c == '/') '\\' else c;
    var out = buf[0..src.len];

    // `C:` alone is *the drive's current directory* in Windows path syntax,
    // which is a relative path wearing an absolute one's clothes. A reported
    // cwd is absolute, so it means the root.
    if (out.len == 2 and out[1] == ':') {
        buf[2] = '\\';
        out = buf[0..3];
    }

    // A trailing separator belongs to a drive root (`C:\`) and to nothing
    // else. Leaving it on `C:\a\` would make two spellings of one directory,
    // and the pwd is compared against itself to decide whether it changed.
    const drive_root = out.len == 3 and out[1] == ':' and out[2] == '\\';
    if (!drive_root and out.len > 1 and out[out.len - 1] == '\\') {
        out = out[0 .. out.len - 1];
    }

    return out;
}

test "winpwd: a drive path with a leading slash" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "C:\\Users\\ghostty",
        windowsPath(&buf, "/C:/Users/ghostty").?,
    );
}

// The form our own shell integrations produce when `$PWD` is concatenated
// straight onto the hostname, which on Windows has no separator to donate.
test "winpwd: a drive path with no leading slash" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "C:\\Users\\ghostty",
        windowsPath(&buf, "C:/Users/ghostty").?,
    );
}

// `raw_path` URIs are handed over unescaped and unaltered, so backslashes
// arrive as backslashes.
test "winpwd: separators may already be backslashes" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "C:\\Users\\ghostty",
        windowsPath(&buf, "/C:\\Users\\ghostty").?,
    );
}

test "winpwd: a drive root keeps its trailing separator" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("C:\\", windowsPath(&buf, "/C:/").?);
}

// A bare `C:` is the drive's *current* directory in Windows syntax -- a
// relative path that looks absolute. A reported cwd is absolute.
test "winpwd: a bare drive letter becomes the drive root" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("C:\\", windowsPath(&buf, "/C:").?);
}

// Anywhere but a drive root, a trailing separator is dropped: the pwd is
// compared against itself to decide whether it changed, and two spellings of
// one directory would report a change that did not happen.
test "winpwd: a trailing separator elsewhere is dropped" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("C:\\a", windowsPath(&buf, "/C:/a/").?);
}

test "winpwd: a UNC path arrives inside the path component" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "\\\\server\\share\\x",
        windowsPath(&buf, "//server/share/x").?,
    );
    // And with backslashes, which is what `Get-Location` gives verbatim.
    try testing.expectEqualStrings(
        "\\\\server\\share\\x",
        windowsPath(&buf, "\\\\server\\share\\x").?,
    );
}

// A server with no share names a machine, not a directory.
test "winpwd: a UNC needs a share, not just a server" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expect(windowsPath(&buf, "//server") == null);
    try testing.expect(windowsPath(&buf, "//server/") == null);
}

// Spaces and non-ASCII are already decoded by the URI parser and must pass
// through untouched -- they are ordinary characters in a Windows path.
test "winpwd: spaces and non-ascii pass through" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "C:\\a b\\\u{9879}\u{76ee}",
        windowsPath(&buf, "/C:/a b/\u{9879}\u{76ee}").?,
    );
}

// **The floor for every test above.**
//
// An implementation that only flipped the slashes would pass all of them and
// would turn `/share/dir` into `\share\dir`: a string that looks entirely
// normal, that no Windows API can use, and that would be stored as the pwd
// with nothing anywhere reporting a problem. Refusing is the whole point.
test "winpwd: a path with no drive and no UNC is refused" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expect(windowsPath(&buf, "/") == null);
    try testing.expect(windowsPath(&buf, "/share/dir") == null);
    try testing.expect(windowsPath(&buf, "/Users/ghostty") == null);
    try testing.expect(windowsPath(&buf, "") == null);
    // A digit is not a drive letter.
    try testing.expect(windowsPath(&buf, "/1:/x") == null);
    // A drive letter with no colon is a directory name.
    try testing.expect(windowsPath(&buf, "/C/x") == null);
}

// A buffer too small returns null rather than writing past it. The `+1` is
// the room a bare `C:` needs to become `C:\`.
test "winpwd: a short buffer is refused, not overrun" {
    const testing = std.testing;
    var small: [4]u8 = undefined;
    try testing.expect(windowsPath(&small, "/C:/Users") == null);
    // Two bytes cannot hold `C:\`, so the growth is refused rather than
    // silently truncated to `C:` -- which would be a *relative* path.
    var too_small: [2]u8 = undefined;
    try testing.expect(windowsPath(&too_small, "/C:") == null);
    // Three is exactly enough, and the guard must not be off by one in the
    // other direction either: a correct path refused is as wrong as a wrong
    // path returned, and both are silent.
    var exact: [3]u8 = undefined;
    try testing.expectEqualStrings("C:\\", windowsPath(&exact, "/C:").?);
}

// **A drive letter is not enough; the colon must be followed by a separator.**
//
// `C:foo` is Windows syntax for "foo, relative to whatever the current
// directory on drive C happens to be" -- a relative path wearing an absolute
// one's clothes, the same disease as the bare `C:` above with three more
// letters on the end. Resolving it needs per-drive state this terminal does
// not have and the shell did not send.
test "winpwd: a drive-relative path is refused" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expect(windowsPath(&buf, "C:foo") == null);
    try testing.expect(windowsPath(&buf, "/C:foo") == null);
    try testing.expect(windowsPath(&buf, "/C:foo/bar") == null);
}

// **One stray leading separator must not turn a drive path into a UNC.**
//
// The extra slash is the likeliest typo in the whole scheme: our own
// integrations build the URI by concatenation, so `.../` plus `/C:/x` is one
// keystroke away in the shell script. Accepted as a UNC it yields
// `\\C:\x` -- a string no Windows API can use, which is the exact class of
// result the `/share/dir` test exists to prevent, arriving through a
// different door. A server segment holding a colon is not a host name.
test "winpwd: a doubled leading separator is not a UNC server" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expect(windowsPath(&buf, "//C:/x") == null);
    try testing.expect(windowsPath(&buf, "\\\\C:\\x") == null);
}

// The extended-length prefix, pinned deliberately rather than left working by
// accident. `\\?\C:\very\long\path` is how Windows escapes MAX_PATH, it is a
// real thing a shell can report, and it happens to satisfy the UNC shape --
// so without this test the next person to tighten the UNC rule would break it
// and no test would say so.
test "winpwd: the extended-length prefix passes through" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "\\\\?\\C:\\x",
        windowsPath(&buf, "\\\\?\\C:\\x").?,
    );
    // The device namespace has the same shape.
    try testing.expectEqualStrings(
        "\\\\.\\pipe\\x",
        windowsPath(&buf, "\\\\.\\pipe\\x").?,
    );
}
