//! The `PATH` a plugin's child is started with.
//!
//! **The bug this exists for.** A Polter started from the Dock, from Finder,
//! from a `.desktop` file -- from anything that is not already a shell --
//! inherits the launcher's environment, and on macOS that `PATH` is
//! `/usr/bin:/bin:/usr/sbin:/sbin` and nothing else. The user's own
//! `~/.local/bin`, their `~/.cargo/bin`, whatever Homebrew put in
//! `/opt/homebrew/bin`: all of it lives in their shell profile, and a
//! launcher never reads a shell profile. So `claude`, installed by its own
//! installer into `~/.local/bin`, is simply not findable, and
//! `plugins/claude-code/provision.sh` -- whose first act is
//! `command -v claude` -- concluded that this machine does not use Claude
//! Code and did nothing, at every launch, in silence.
//!
//! It was never seen because every test launch was from a terminal, which
//! is the one way of starting Polter that already has the answer.
//!
//! **Why the host and not the plugin.** This is not one plugin's problem.
//! Any plugin that shells out to a tool a user installed hits it, and the
//! alternative -- each plugin guessing at install locations -- is each
//! plugin carrying its own hand-copied list of directories to drift out of
//! date. It is the same argument `Resident` makes about capturing a
//! plugin's standard error: the host is the only place that can do a thing
//! once for all of them.
//!
//! **Why a login shell and not a list of directories.** Ghostty already
//! solved this for the other kind of child it starts. `termio/Exec.zig`
//! does not compute a `PATH` for the pty; it runs the user's shell *as a
//! login shell* (`login(1)` on macOS, `-l` elsewhere) and lets the profile
//! that owns the answer produce it. That is why a terminal opened from a
//! Dock-launched Ghostty has the right `PATH` while the app around it does
//! not. `path_helper(8)` is not a substitute: it reads `/etc/paths` and
//! `/etc/paths.d`, which is exactly the part of the answer the launcher
//! already gave us, and never `~/.zprofile`.
//!
//! **Cost.** One `fork`/`exec` of the login shell, once per plugin child,
//! off the app thread. It is bounded by `timeout_ms` and every failure is
//! survivable: a plugin whose `PATH` could not be widened is started with
//! the one Polter has, which is exactly the old behaviour.
//!
//! **Windows.** There is no login shell to ask and no profile to read: a
//! GUI process on Windows inherits the user and machine `PATH` out of the
//! registry, so the bug above does not exist there and there is nothing to
//! fix. `resolve` is compiled away to "unsupported". See `supported`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.poltergeist);

/// How long the login shell has to answer.
///
/// A shell profile that talks to the network -- a version check, a prompt
/// that asks a package manager something -- can take seconds, and killing
/// it at one would make this feature work on developer laptops and nowhere
/// else. Five is long enough for a slow profile and short enough that a
/// hung one does not hold a plugin's first start open for a whole minute.
pub const timeout_ms: u64 = 5 * std.time.ms_per_s;

/// The most a login shell may print before we stop believing it.
///
/// A profile that writes a banner writes a few lines. A profile emitting
/// megabytes is one whose output we would be searching, not reading.
const max_output: usize = 64 * 1024;

/// Whether asking a login shell is a coherent question on this platform.
pub const supported: bool = builtin.os.tag != .windows;

/// What came of trying. Every value but `widened` leaves the environment
/// exactly as it was, which is the old behaviour.
pub const Result = enum {
    /// Windows. There is no login shell and no bug; see the module note.
    unsupported,

    /// No `SHELL` in the environment, or one that is not an absolute path.
    /// Nothing to run.
    no_shell,

    /// The shell could not be started at all, or was killed on
    /// `timeout_ms`, or exited non-zero.
    unavailable,

    /// It ran and said nothing that looks like a `PATH`.
    unusable,

    /// It ran, and told us nothing we did not already have.
    unchanged,

    /// The environment now carries a wider `PATH` than Polter was given.
    widened,
};

/// Widen `environ`'s `PATH` to the one the user's login shell computes.
///
/// Nothing is removed: the result is the login shell's `PATH` followed by
/// whatever entries the inherited one had and it did not. Polter may have
/// been started by a wrapper script that put something on the front, and a
/// launcher's `PATH` is a poor thing to widen with but a rude thing to
/// throw away.
///
/// The new value is duplicated into the map, so `gpa` need only outlive
/// this call.
pub fn widen(
    gpa: Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
) Result {
    if (!supported) return .unsupported;

    const inherited = environ.get("PATH") orelse "";

    const login = resolve(gpa, io, environ) catch |err| return switch (err) {
        error.NoShell => .no_shell,
        error.Unusable => .unusable,
        else => .unavailable,
    };
    defer gpa.free(login);

    const merged = merge(gpa, login, inherited) catch return .unavailable;
    defer gpa.free(merged);

    if (std.mem.eql(u8, merged, inherited)) return .unchanged;

    environ.put("PATH", merged) catch return .unavailable;
    return .widened;
}

pub const Error = error{
    /// No `SHELL`, or one that is not an absolute path.
    NoShell,

    /// It ran and printed nothing that reads as a `PATH`.
    Unusable,

    /// It could not be run, took too long, or failed.
    Unavailable,
};

/// Ask the user's login shell what `PATH` it ends up with.
///
/// The answer is allocated in `gpa` and owned by the caller.
pub fn resolve(
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) Error![]const u8 {
    if (!supported) return error.NoShell;

    const shell = environ.get("SHELL") orelse return error.NoShell;

    // An absolute path or nothing. `SHELL` is one of the few environment
    // variables a user is likely to have set by hand, and resolving a bare
    // word here would mean looking it up on the very `PATH` we are trying
    // to replace.
    if (shell.len == 0 or shell[0] != '/') return error.NoShell;

    // **`-i` as well as `-l`, and this is not belt and braces.** Measured
    // on the machine this was found on: `zsh -l -c` gives a `PATH` with no
    // `~/.local/bin` in it, and `zsh -l -i -c` gives one with it, because
    // the line that puts it there lives in `.zshrc` -- which a login shell
    // reads only when it is also interactive. `~/.local/bin` is where
    // Claude Code's own installer puts `claude`, so dropping `-i` would
    // leave this fixing the bug on paper and not on the machine. It is
    // also what Ghostty's pty child is (`termio/Exec.zig` runs an
    // interactive login shell), and "what the user's own terminal can run"
    // is exactly the question being asked.
    //
    // **The inner `/bin/sh` is not redundant.** `$PATH` is a colon-joined
    // string in every POSIX shell and a *list* in fish and nushell, where
    // `printf %s "$PATH"` prints it space-separated and we would build a
    // broken `PATH` out of a correct answer. Every shell exports it in the
    // colon form to its children, so asking a child is the one phrasing
    // that does not need a case per shell.
    const result = std.process.run(gpa, io, .{
        .argv = &.{ shell, "-l", "-i", "-c", "/bin/sh -c 'printf %s \"$PATH\"'" },
        .environ_map = environ,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .raw = .fromMilliseconds(@intCast(timeout_ms)),
            .clock = .awake,
        } },
    }) catch |err| {
        log.warn("login path: {s} would not answer err={}", .{ shell, err });
        return error.Unavailable;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            log.warn("login path: {s} exited {d}", .{ shell, code });
            return error.Unavailable;
        },
        else => {
            log.warn("login path: {s} did not exit normally", .{shell});
            return error.Unavailable;
        },
    }

    // **The last line, not the whole of stdout.** A login shell runs the
    // user's profile, and profiles print things -- a fortune, a version
    // banner, a warning from a version manager. Our `printf` writes no
    // newline, so whatever we asked for is the final line and everything
    // before it is somebody else's.
    const answer = lastLine(result.stdout);
    if (!looksLikePath(answer)) return error.Unusable;

    return gpa.dupe(u8, answer) catch return error.Unavailable;
}

/// Everything after the last newline, trimmed.
fn lastLine(out: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    const nl = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse
        return trimmed;
    return std.mem.trim(u8, trimmed[nl + 1 ..], " \t\r");
}

/// Whether a line is plausibly a `PATH` and not a profile's chatter.
///
/// Deliberately weak: the point is to reject "Welcome to your shell!", not
/// to validate directories. One absolute entry is the whole test, because
/// a `PATH` with no absolute entry in it is of no use to us either way.
fn looksLikePath(line: []const u8) bool {
    if (line.len == 0) return false;
    if (std.mem.indexOfScalar(u8, line, 0) != null) return false;

    var it = std.mem.splitScalar(u8, line, ':');
    while (it.next()) |entry| {
        if (entry.len > 0 and entry[0] == '/') return true;
    }
    return false;
}

/// `first`, then every entry of `second` that `first` does not already
/// have. Order within each is kept; empty entries are dropped, because an
/// empty entry in a `PATH` means the current directory and neither side
/// meant to say that.
fn merge(gpa: Allocator, first: []const u8, second: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    for ([_][]const u8{ first, second }) |list| {
        var it = std.mem.splitScalar(u8, list, ':');
        entry: while (it.next()) |entry| {
            if (entry.len == 0) continue;

            var have = std.mem.splitScalar(u8, out.items, ':');
            while (have.next()) |seen| {
                if (std.mem.eql(u8, seen, entry)) continue :entry;
            }

            if (out.items.len > 0) try out.append(gpa, ':');
            try out.appendSlice(gpa, entry);
        }
    }

    return out.toOwnedSlice(gpa);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "merge: the login path comes first and nothing is lost" {
    const got = try merge(
        testing.allocator,
        "/Users/x/.local/bin:/opt/homebrew/bin:/usr/bin:/bin",
        "/usr/bin:/bin:/usr/sbin:/sbin",
    );
    defer testing.allocator.free(got);

    try testing.expectEqualStrings(
        "/Users/x/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        got,
    );
}

test "merge: an entry only the inherited path had survives" {
    const got = try merge(testing.allocator, "/usr/bin", "/opt/wrapper/bin:/usr/bin");
    defer testing.allocator.free(got);

    try testing.expectEqualStrings("/usr/bin:/opt/wrapper/bin", got);
}

test "merge: empty entries are dropped rather than meaning the cwd" {
    const got = try merge(testing.allocator, "/usr/bin::", ":/bin");
    defer testing.allocator.free(got);

    try testing.expectEqualStrings("/usr/bin:/bin", got);
}

test "lastLine: a chatty profile does not become the PATH" {
    try testing.expectEqualStrings(
        "/usr/bin:/bin",
        lastLine("nvm: using v20\nWelcome!\n/usr/bin:/bin"),
    );
    try testing.expectEqualStrings("/usr/bin", lastLine("  /usr/bin \n"));
}

test "looksLikePath: chatter is refused, a path is not" {
    try testing.expect(looksLikePath("/usr/bin:/bin"));
    try testing.expect(looksLikePath("relative:/usr/bin"));
    try testing.expect(!looksLikePath(""));
    try testing.expect(!looksLikePath("Welcome to your shell!"));
    try testing.expect(!looksLikePath("/usr/bin\x00"));
}

test "widen: no SHELL is not a failure, it is a no-op" {
    if (!supported) return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");

    try testing.expectEqual(Result.no_shell, widen(testing.allocator, threaded.io(), &env));
    try testing.expectEqualStrings("/usr/bin:/bin", env.get("PATH").?);
}

test "widen: a relative SHELL is refused rather than looked up on PATH" {
    if (!supported) return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("SHELL", "sh");

    try testing.expectEqual(Result.no_shell, widen(testing.allocator, threaded.io(), &env));
}

test "widen: a real login shell answers, and the launcher's PATH survives it" {
    if (!supported) return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.Io.Dir.cwd().access(io, "/bin/sh", .{}) catch return error.SkipZigTest;

    // The launcher's, near enough: this process's environment with its
    // `PATH` replaced by a marker directory only this map knows about.
    var env = try std.testing.environ.createMap(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/zzz-only-the-launcher-had-this:/usr/bin:/bin");
    try env.put("SHELL", "/bin/sh");

    switch (widen(testing.allocator, io, &env)) {
        // A machine whose `/bin/sh -l` prints nothing usable is not a
        // machine this test can say anything about.
        .unusable, .unavailable => return error.SkipZigTest,

        .widened, .unchanged => {},
        else => |r| {
            std.debug.print("unexpected result: {t}\n", .{r});
            return error.TestUnexpectedResult;
        },
    }

    const got = env.get("PATH").?;
    try testing.expect(std.mem.indexOf(u8, got, "/zzz-only-the-launcher-had-this") != null);
    try testing.expect(std.mem.indexOf(u8, got, "/usr/bin") != null);
}

test "the login shell's own PATH is what the child ends up with" {
    // A stand-in shell rather than the machine's, so the assertion is
    // about this file's plumbing -- run `SHELL`, take the last line, merge
    // it in front of the launcher's -- and not about whatever the profile
    // on the build machine happens to say. The banner is there because
    // real profiles print one, and taking the whole of stdout as a `PATH`
    // is the mistake this is guarding.
    if (!supported) return error.SkipZigTest;

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-loginpath-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    {
        var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
        defer d.close(io);
        var f = try d.createFile(io, "shell", .{ .permissions = .fromMode(0o755) });
        try f.writeStreamingAll(io,
            \\#!/bin/sh
            \\echo "nvm: now using node v20"
            \\printf '%s' "/home/u/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
            \\
        );
        f.close(io);
    }

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/zzz-only-the-launcher-had-this:/usr/bin:/bin");
    try env.put("SHELL", try std.fmt.allocPrint(alloc, "{s}/shell", .{dir}));

    try testing.expectEqual(Result.widened, widen(testing.allocator, io, &env));

    // The login shell's answer, in its own order, and then the entry only
    // the launcher had. Nothing is dropped and the banner is nowhere in
    // it.
    try testing.expectEqualStrings(
        "/home/u/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/zzz-only-the-launcher-had-this",
        env.get("PATH").?,
    );
}

test "a login shell that only prints chatter leaves the PATH alone" {
    if (!supported) return error.SkipZigTest;

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-loginpath-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    {
        var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
        defer d.close(io);
        var f = try d.createFile(io, "shell", .{ .permissions = .fromMode(0o755) });
        try f.writeStreamingAll(io, "#!/bin/sh\necho 'Welcome!'\n");
        f.close(io);
    }

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("SHELL", try std.fmt.allocPrint(alloc, "{s}/shell", .{dir}));

    try testing.expectEqual(Result.unusable, widen(testing.allocator, io, &env));
    try testing.expectEqualStrings("/usr/bin:/bin", env.get("PATH").?);
}
