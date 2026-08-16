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
    if (prefixed(value, "env:")) |name| {
        const found = env.get(name) orelse {
            log.warn("secret: no environment variable {s}", .{name});
            return error.Unresolved;
        };
        return alloc.dupe(u8, found);
    }

    if (prefixed(value, "file:")) |path| {
        return firstLineOf(alloc, io, path);
    }

    if (prefixed(value, "keychain:")) |spec| {
        return fromKeychain(alloc, io, spec);
    }

    if (prefixed(value, "cmd:")) |command| {
        return fromCommand(alloc, io, command);
    }

    // No prefix: it is the value. Most parameters are not secret at all.
    return alloc.dupe(u8, value);
}

fn prefixed(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    return value[prefix.len..];
}

/// The first line of a file, whitespace trimmed.
///
/// First line rather than whole file because key files conventionally end
/// with a newline, and sending that newline along has broken more than one
/// integration in a way that is very hard to see.
fn firstLineOf(alloc: Allocator, io: std.Io, path: []const u8) Error![]const u8 {
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
        return error.Unresolved;
    };

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
    var f = try d.createFile(io, "key", .{ .permissions = .fromMode(0o600) });
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
