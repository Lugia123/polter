//! Getting a password without keeping one.
//!
//! A plugin's parameters have to come from somewhere, and the obvious
//! place -- a config file -- means a plaintext password on disk. Owner-only
//! permissions narrow *who* can read it to this user; the file is still
//! plaintext. A backup takes it, a stray commit takes it, and one `cat`
//! puts it on a screen that another agent may be reading right now with
//! `terminal_read`.
//!
//! So a value may instead be a **reference**, resolved at the moment the
//! plugin is called:
//!
//!     env:FEISHU_TOKEN                     an environment variable
//!     file:~/.config/polter/feishu.key     the first line of a file
//!     keychain:polter/feishu               the system keychain
//!     cmd:op read op://Private/feishu      whatever this prints
//!
//! Anything without a known prefix is the value itself, so an ordinary
//! webhook URL needs no ceremony.
//!
//! **`cmd:` is the one that matters.** It covers every password manager at
//! once -- 1Password, pass, Bitwarden, gopass, and anything the user
//! writes -- with no adapter here for any of them, and nothing to update
//! when one changes its API. Without it we would be signing up to add one
//! integration after another, each with its own unlock flow, forever.
//! `keychain:` exists as the zero-dependency default and is itself just a
//! `cmd:` under the covers.
//!
//! Nothing is cached. A vault that has locked must fail, and a cache would
//! hide that it locked at all.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const reap = @import("reap.zig");

const log = std.log.scoped(.poltergeist);

/// Longest a resolver may take. Unlocking a vault can prompt the user, so
/// this is far more generous than a plugin's own timeout -- but it is not
/// unbounded, because nobody is watching at 3am.
const timeout_ms: u64 = 30 * std.time.ms_per_s;

pub const Error = error{
    /// The reference names something that is not there, or the command
    /// that would produce it failed.
    Unresolved,
} || Allocator.Error;

/// Resolve one value. The result belongs to `alloc`.
///
/// **Failure is failure, not fallback.** A reference that cannot be
/// resolved must not come back as itself: sending `cmd:op read …` to
/// Feishu as though it were the signing key is worse than sending nothing,
/// because it looks like it worked and puts the shape of your vault in
/// somebody's chat log.
pub fn resolve(
    alloc: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    value: []const u8,
) Error![]const u8 {
    // No prefix: it is the value. Most parameters are not secret at all.
    const prefix = classify(value) orelse return alloc.dupe(u8, value);
    const rest = body(value, prefix);

    return switch (prefix) {
        .env => blk: {
            const found = env.get(rest) orelse {
                log.warn("secret: no environment variable {s}", .{rest});
                break :blk error.Unresolved;
            };
            break :blk alloc.dupe(u8, found);
        },
        .file => firstLineOf(alloc, io, env, rest),
        .keychain => fromKeychain(alloc, io, rest),
        .cmd => fromCommand(alloc, io, rest),
    };
}

/// Every kind of reference there is. The list is closed on purpose: the
/// tool surface decides what it will write by matching against it, so a
/// prefix added here and nowhere else would be a hole that opens quietly.
pub const Prefix = enum { env, file, keychain, cmd };

pub fn text(p: Prefix) []const u8 {
    return switch (p) {
        .env => "env:",
        .file => "file:",
        .keychain => "keychain:",
        .cmd => "cmd:",
    };
}

/// Which reference this is, or null when the value is a literal.
///
/// Case-sensitive, because `resolve` is: `CMD:x` is a literal and gets
/// sent as the eight characters it is, never run.
pub fn classify(value: []const u8) ?Prefix {
    inline for (comptime std.enums.values(Prefix)) |p| {
        if (std.mem.startsWith(u8, value, text(p))) return p;
    }
    return null;
}

/// The part after the prefix.
pub fn body(value: []const u8, p: Prefix) []const u8 {
    return value[text(p).len..];
}

/// Expand a leading `~/` against HOME. Only leading, and only `~/`:
/// `~user/` needs a passwd lookup and nobody has asked for one.
///
/// A path with nothing to expand comes back as a copy rather than as
/// itself, so every caller frees on the same terms and none of them has to
/// know which case it got.
fn expandTilde(
    alloc: Allocator,
    env: *const std.process.Environ.Map,
    path: []const u8,
) Allocator.Error![]const u8 {
    if (!std.mem.startsWith(u8, path, "~/")) return alloc.dupe(u8, path);

    // No HOME is left alone rather than guessed at. A path that resolves to
    // something other than what was written is worse than one that plainly
    // does not resolve.
    const home = env.get("HOME") orelse return alloc.dupe(u8, path);
    if (home.len == 0) return alloc.dupe(u8, path);

    const trimmed = if (home[home.len - 1] == '/') home[0 .. home.len - 1] else home;
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ trimmed, path[1..] });
}

/// The first line of a file, whitespace trimmed.
///
/// First line rather than whole file because key files conventionally end
/// with a newline, and sending that newline along has broken more than one
/// integration in a way that is very hard to see.
fn firstLineOf(
    alloc: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    raw: []const u8,
) Error![]const u8 {
    // `~/` is how the documented examples are written, and a shell is not
    // involved to expand it for us.
    const path = try expandTilde(alloc, env, raw);
    defer alloc.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        alloc,
        .limited(64 * 1024),
    ) catch |err| {
        log.warn("secret: could not read {s} err={}", .{ path, err });
        return error.Unresolved;
    };
    defer alloc.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const first = lines.next() orelse return error.Unresolved;
    const trimmed = std.mem.trim(u8, first, " \t\r");
    if (trimmed.len == 0) return error.Unresolved;

    return alloc.dupe(u8, trimmed);
}

/// `service/account` out of the system keychain.
///
/// A special case of `cmd:` rather than a separate mechanism: it exists so
/// that somebody who has installed no password manager still has somewhere
/// better than a file to put a token.
fn fromKeychain(alloc: Allocator, io: std.Io, spec: []const u8) Error![]const u8 {
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse {
        log.warn("secret: keychain reference wants service/account", .{});
        return error.Unresolved;
    };
    const service = spec[0..slash];
    const account = spec[slash + 1 ..];

    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "security", "find-generic-password", "-w", "-s", service, "-a", account },
        else => &.{ "secret-tool", "lookup", "service", service, "account", account },
    };

    return runCapturing(alloc, io, argv);
}

/// Whatever a command prints, trimmed.
fn fromCommand(alloc: Allocator, io: std.Io, command: []const u8) Error![]const u8 {
    // Through a shell, so that a reference can be written the way it would
    // be typed -- pipes, quoting and all. These commands come from the
    // user's own config; there is no untrusted input here to be injected.
    const argv: []const []const u8 = &.{ "/bin/sh", "-c", command };
    return runCapturing(alloc, io, argv);
}

fn runCapturing(
    alloc: Allocator,
    io: std.Io,
    argv: []const []const u8,
) Error![]const u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,

        // Inherited, so that "vault is locked" or "op: not signed in"
        // reaches wherever Polter's output goes. A silent failure here is
        // the hardest kind to work out at 3am.
        .stderr = .inherit,
    }) catch |err| {
        log.warn("secret: could not run resolver err={}", .{err});
        return error.Unresolved;
    };

    // The bound this module promises, actually applied. Neither of the two
    // waits below has a clock of its own: `streamRemaining` returns when
    // the pipe closes and `wait` when the process ends, so a resolver that
    // simply never finishes -- a keychain dialog nobody is at the machine
    // to answer, an `op` blocked on a terminal that is not there -- holds
    // this thread for as long as the machine is up. That thread is not
    // always a one-shot notification any more: the resident archive
    // re-resolves on every restart, and its shutdown joins this.
    //
    // Armed before the read rather than after it, because the read is the
    // half that blocks first; killing the child is what closes the pipe and
    // ends it.
    var reaper: reap.Reaper = .init(io, "secret resolver", child.id, timeout_ms);
    const clock = std.Thread.spawn(.{}, reap.Reaper.run, .{&reaper}) catch null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    if (child.stdout) |stdout| {
        var buf: [4096]u8 = undefined;
        var reader = stdout.readerStreaming(io, &buf);
        _ = reader.interface.streamRemaining(&out.writer) catch {};
        stdout.close(io);
        child.stdout = null;
    }

    const term = child.wait(io) catch |err| {
        log.warn("secret: resolver would not finish err={}", .{err});
        reaper.retire();
        if (clock) |t| t.join();
        return error.Unresolved;
    };

    reaper.retire();
    if (clock) |t| t.join();

    // Said plainly rather than folded into "did not exit normally": a
    // resolver that ran out of time and one that crashed want different
    // things done about them.
    if (reaper.killed()) {
        log.warn("secret: resolver gave up after {d}ms", .{timeout_ms});
        return error.Unresolved;
    }

    switch (term) {
        .exited => |code| if (code != 0) {
            log.warn("secret: resolver failed with {d}", .{code});
            return error.Unresolved;
        },
        else => {
            log.warn("secret: resolver did not exit normally", .{});
            return error.Unresolved;
        },
    }

    const trimmed = std.mem.trim(u8, out.written(), " \t\r\n");
    if (trimmed.len == 0) {
        log.warn("secret: resolver produced nothing", .{});
        return error.Unresolved;
    }

    return alloc.dupe(u8, trimmed);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "a plain value is itself" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    const got = try resolve(
        arena.allocator(),
        threaded.io(),
        &env,
        "https://open.feishu.cn/hook/abc",
    );
    try testing.expectEqualStrings("https://open.feishu.cn/hook/abc", got);
}

test "env: reads the environment, and says so when it is not there" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("POLTER_TEST_TOKEN", "s3cret");

    try testing.expectEqualStrings(
        "s3cret",
        try resolve(arena.allocator(), io, &env, "env:POLTER_TEST_TOKEN"),
    );

    try testing.expectError(
        error.Unresolved,
        resolve(arena.allocator(), io, &env, "env:POLTER_TEST_MISSING"),
    );
}

test "cmd: is whatever it printed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    // The trailing newline `echo` adds has to go: sending it along is a
    // failure that is very hard to see from the other end.
    try testing.expectEqualStrings(
        "from-a-vault",
        try resolve(arena.allocator(), threaded.io(), &env, "cmd:echo from-a-vault"),
    );
}

test "a resolver that fails is a failure, not a fallback" {
    // The value must never come back as itself. Sending `cmd:op read ...`
    // to Feishu as though it were the key looks like it worked, and puts
    // the shape of somebody's vault in a chat log.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    try testing.expectError(
        error.Unresolved,
        resolve(arena.allocator(), threaded.io(), &env, "cmd:exit 1"),
    );
}

test "a resolver that prints nothing has not resolved anything" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    try testing.expectError(
        error.Unresolved,
        resolve(arena.allocator(), threaded.io(), &env, "cmd:true"),
    );
}

test "file: takes the first line without its newline" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-sec-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    var f = try d.createFile(io, "key", fixtureMode(0o600));
    try f.writeStreamingAll(io, "the-key\nand a comment nobody wants sent\n");
    f.close(io);

    const path = try std.fmt.allocPrint(alloc, "{s}/key", .{dir});
    try testing.expectEqualStrings(
        "the-key",
        try resolve(alloc, io, &env, try std.fmt.allocPrint(alloc, "file:{s}", .{path})),
    );
}

test "a file that is not there fails rather than yielding the path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    try testing.expectError(
        error.Unresolved,
        resolve(
            arena.allocator(),
            threaded.io(),
            &env,
            "file:/tmp/polter-no-such-key-9c1f",
        ),
    );
}

test "classify knows every prefix resolve does" {
    // The tool surface decides what it will write by matching against
    // `Prefix`. If `resolve` grew a fifth kind of reference and this list
    // did not, that surface would go on treating it as an inert literal and
    // write it without a word. So the two are checked against each other
    // here rather than trusted to stay in step.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    for (std.enums.values(Prefix)) |p| {
        const written = try std.fmt.allocPrint(
            alloc,
            "{s}polter-test-nothing-9c1f/none",
            .{text(p)},
        );

        try testing.expectEqual(p, classify(written).?);
        try testing.expectEqualStrings(
            "polter-test-nothing-9c1f/none",
            body(written, p),
        );

        // And `resolve` really does treat it as a reference: a prefix it
        // did not know would come back as the literal it is.
        try testing.expectError(
            error.Unresolved,
            resolve(alloc, io, &env, written),
        );
    }

    // A literal is a literal, and the match is case-sensitive -- `CMD:` is
    // four characters of somebody's password, not a command to run.
    try testing.expectEqual(@as(?Prefix, null), classify("https://example.com/hook"));
    try testing.expectEqual(@as(?Prefix, null), classify("CMD:echo hi"));
    try testing.expectEqual(@as(?Prefix, null), classify("cmd"));
}

test "a file: reference expands a leading tilde" {
    // `docs/poltergeist/plugins.md` writes the example as
    // `file:~/.config/polter/feishu.key`, and until this it did not work:
    // nothing expands `~` here, so the path was taken literally and the
    // reference failed for everybody who copied the documented line.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const home = try std.fmt.allocPrint(alloc, "/tmp/polter-home-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, home);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    var d = try std.Io.Dir.cwd().openDir(io, home, .{});
    defer d.close(io);
    var f = try d.createFile(io, "feishu.key", fixtureMode(0o600));
    try f.writeStreamingAll(io, "the-key\n");
    f.close(io);

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", home);

    try testing.expectEqualStrings(
        "the-key",
        try resolve(alloc, io, &env, "file:~/feishu.key"),
    );

    // With no HOME the path is left as written rather than guessed at, so
    // it fails plainly instead of resolving to something else.
    var homeless: std.process.Environ.Map = .init(testing.allocator);
    defer homeless.deinit();
    try testing.expectError(
        error.Unresolved,
        resolve(alloc, io, &homeless, "file:~/feishu.key"),
    );
}

/// Create flags for a test fixture that POSIX needs a mode on.
///
/// Windows has no mode to pass and no `Permissions.fromMode`, so a literal
/// `0o600` here is a compile error rather than a portability wart -- which
/// is why the Windows test suite could not be built at all before this.
///
/// The POSIX side is unchanged, and the mode is kept there because these
/// fixtures stand in for a real key file: `0o600` is the shape the thing
/// being tested has in the field. Dropping it on Windows costs nothing --
/// the file lives in a temp directory the test deletes on the way out, and
/// the key in it is the string "the-key".
fn fixtureMode(comptime mode: u32) std.Io.File.CreateFlags {
    return switch (builtin.os.tag) {
        .windows => .{},
        else => .{ .permissions = .fromMode(mode) },
    };
}
