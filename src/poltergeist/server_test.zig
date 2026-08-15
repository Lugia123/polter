//! End-to-end tests for the agent socket.
//!
//! These drive a real `Server` over a real unix socket with a real client,
//! because the unit tests around it could not have caught what actually
//! went wrong. The first version of this server compiled, type-checked
//! against two targets, passed every unit test, and served exactly zero
//! requests: the call it used to read a line did not consume the newline,
//! so the connection loop spun on an empty slice forever.
//!
//! Nothing short of running it would have found that. So: run it.

const std = @import("std");
const net = std.Io.net;
const testing = std.testing;

const Server = @import("Server.zig");
const wire = @import("wire.zig");

const worker: u64 = 0x2222;

/// A fixture holding everything one test needs, torn down in one call.
const Fixture = struct {
    threaded: std.Io.Threaded,
    io: std.Io,
    path: [:0]u8,
    server: Server,
    fake: *Fake,

    /// What the app would do with a request.
    const Fake = struct {
        io: std.Io,

        /// When false, requests are accepted and never answered -- which is
        /// how a wedged or shutting-down app looks from the socket.
        answer: bool = true,

        seen: std.atomic.Value(u32) = .init(0),

        fn submit(ctx: *anyopaque, pending: *Server.Pending) void {
            const self: *Fake = @ptrCast(@alignCast(ctx));

            // The reference handed over with the request. The real app
            // releases it after the app thread has dealt with the request;
            // here there is no other thread, so release on the way out.
            defer pending.release();

            _ = self.seen.fetchAdd(1, .acq_rel);
            if (!self.answer) return;
            pending.complete(self.io, .ok);
        }
    };

    /// Set up in place. Neither the `Io` instance nor the server may be
    /// moved after this: both hand their own address to threads, so a copy
    /// would leave those threads pointing at a dead frame. The first run of
    /// these tests crashed on exactly that.
    fn setup(self: *Fixture, answer: bool) !void {
        const alloc = testing.allocator;

        self.threaded = .init(alloc, .{});
        errdefer self.threaded.deinit();
        const io = self.threaded.io();
        self.io = io;

        // Short, because a unix socket path is far shorter than a file
        // path may be.
        var raw: [6]u8 = undefined;
        io.random(&raw);
        self.path = try std.fmt.allocPrintSentinel(
            alloc,
            "/tmp/pg-{x}.sock",
            .{&raw},
            0,
        );
        errdefer alloc.free(self.path);

        self.fake = try alloc.create(Fake);
        errdefer alloc.destroy(self.fake);
        self.fake.* = .{ .io = io, .answer = answer };

        self.server = try .init(alloc, io, self.path, .{
            .ctx = self.fake,
            .func = Fake.submit,
        });
        errdefer self.server.deinit();

        try self.server.start();
    }

    fn deinit(self: *Fixture) void {
        self.server.deinit();
        testing.allocator.destroy(self.fake);
        testing.allocator.free(self.path);
        self.threaded.deinit();
    }

    fn connect(self: *Fixture) !Client {
        const addr = try net.UnixAddress.init(self.path);
        const stream = try addr.connect(self.io);
        return .{ .io = self.io, .stream = stream };
    }
};

const Client = struct {
    io: std.Io,
    stream: net.Stream,
    read_buf: [64 * 1024]u8 = undefined,
    write_buf: [8 * 1024]u8 = undefined,

    fn close(self: *Client) void {
        self.stream.close(self.io);
    }

    fn send(self: *Client, line: []const u8) !void {
        var writer = self.stream.writer(self.io, &self.write_buf);
        try writer.interface.writeAll(line);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
    }

    /// Read one reply. A fresh reader each time so the test never depends
    /// on buffered state carrying over -- the server must be re-readable
    /// from a cold start on every call.
    fn recv(self: *Client) ![]const u8 {
        var reader = self.stream.reader(self.io, &self.read_buf);
        return (try reader.interface.takeDelimiter('\n')) orelse
            error.EndOfStream;
    }

    fn auth(self: *Client, token: []const u8) ![]const u8 {
        var buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "{{\"method\":\"auth\",\"params\":{{\"token\":\"{s}\"}}}}",
            .{token},
        );
        try self.send(line);
        return self.recv();
    }
};

fn expectOk(reply: []const u8) !void {
    testing.expect(std.mem.indexOf(u8, reply, "\"ok\":true") != null) catch |err| {
        std.debug.print("\nexpected ok, got: {s}\n", .{reply});
        return err;
    };
}

fn expectFailed(reply: []const u8, code: []const u8) !void {
    testing.expect(std.mem.indexOf(u8, reply, "\"ok\":false") != null) catch |err| {
        std.debug.print("\nexpected failure, got: {s}\n", .{reply});
        return err;
    };
    testing.expect(std.mem.indexOf(u8, reply, code) != null) catch |err| {
        std.debug.print("\nexpected code {s}, got: {s}\n", .{ code, reply });
        return err;
    };
}

test "a client with a valid token is let in" {
    var f: Fixture = undefined;
    try f.setup(true);
    defer f.deinit();

    const token = try f.server.issueToken(worker);

    var c = try f.connect();
    defer c.close();

    try expectOk(try c.auth(token));
}

test "a client with a bad token is refused" {
    var f: Fixture = undefined;
    try f.setup(true);
    defer f.deinit();

    _ = try f.server.issueToken(worker);

    var c = try f.connect();
    defer c.close();

    // Right shape, wrong value.
    const wrong = "0" ** Server.token_len;
    try expectFailed(try c.auth(wrong), "BadToken");
}

test "a client that does not authenticate first is refused" {
    var f: Fixture = undefined;
    try f.setup(true);
    defer f.deinit();

    var c = try f.connect();
    defer c.close();

    try c.send(
        \\{"method":"me"}
    );
    try expectFailed(try c.recv(), "BadHandshake");
}

test "several requests in a row on one connection all get answered" {
    // This is the case the first version of this server failed at. The
    // handshake worked, and then nothing ever did: the newline was left in
    // the buffer and every later read returned an empty slice without
    // advancing. One request would have looked fine. Three do not.
    var f: Fixture = undefined;
    try f.setup(true);
    defer f.deinit();

    const token = try f.server.issueToken(worker);

    var c = try f.connect();
    defer c.close();
    try expectOk(try c.auth(token));

    for (0..3) |i| {
        try c.send(
            \\{"method":"me"}
        );
        expectOk(try c.recv()) catch |err| {
            std.debug.print("\nrequest {d} went unanswered\n", .{i});
            return err;
        };
    }

    try testing.expectEqual(@as(u32, 3), f.fake.seen.load(.acquire));
}

test "a malformed request is refused without dropping the connection" {
    var f: Fixture = undefined;
    try f.setup(true);
    defer f.deinit();

    const token = try f.server.issueToken(worker);

    var c = try f.connect();
    defer c.close();
    try expectOk(try c.auth(token));

    try c.send("this is not json");
    try expectFailed(try c.recv(), "Malformed");

    try c.send(
        \\{"method":"no_such_method"}
    );
    try expectFailed(try c.recv(), "UnknownMethod");

    // Still usable afterwards, which is the point: a client that mistypes
    // one call should not have to reconnect.
    try c.send(
        \\{"method":"me"}
    );
    try expectOk(try c.recv());
}

test "a revoked token stops working" {
    var f: Fixture = undefined;
    try f.setup(true);
    defer f.deinit();

    // Copied, because revoking frees the server's own copy.
    const issued = try f.server.issueToken(worker);
    var token_buf: [Server.token_len]u8 = undefined;
    @memcpy(&token_buf, issued);
    const token: []const u8 = &token_buf;

    f.server.revokeTokens(worker);

    var c = try f.connect();
    defer c.close();

    try expectFailed(try c.auth(token), "BadToken");
}

test "two terminals get tokens that are not interchangeable" {
    var f: Fixture = undefined;
    try f.setup(true);
    defer f.deinit();

    const a = try f.server.issueToken(worker);
    const issued_b = try f.server.issueToken(0x3333);
    try testing.expect(!std.mem.eql(u8, a, issued_b));

    var b_buf: [Server.token_len]u8 = undefined;
    @memcpy(&b_buf, issued_b);
    const b: []const u8 = &b_buf;

    // Revoking one leaves the other alone.
    f.server.revokeTokens(worker);

    var c = try f.connect();
    defer c.close();
    try expectOk(try c.auth(b));
}

test "shutting down releases a request the app never answered" {
    // A connection thread waits without a timeout, so the only thing that
    // frees it is the server answering on the way down. If that ever
    // regressed, this test hangs rather than fails -- which is still a far
    // better signal than shipping it.
    var f: Fixture = undefined;
    try f.setup(false);
    defer f.deinit();

    const token = try f.server.issueToken(worker);

    var c = try f.connect();
    defer c.close();
    try expectOk(try c.auth(token));

    try c.send(
        \\{"method":"me"}
    );

    // Wait until the app has actually been handed the request, so we are
    // testing shutdown-with-work-in-flight rather than a race.
    while (f.fake.seen.load(.acquire) == 0) std.Thread.yield() catch {};

    // `deinit` runs in the fixture's defer. If it returns at all, the
    // connection thread was released and joined.
    f.server.stop();
}

test "the server can be torn down with a connection sitting idle" {
    var f: Fixture = undefined;
    try f.setup(true);
    defer f.deinit();

    const token = try f.server.issueToken(worker);

    var c = try f.connect();
    defer c.close();
    try expectOk(try c.auth(token));

    // No request in flight: the connection thread is parked in read.
    // Closing its socket is the only thing that will wake it, and if that
    // does not happen the join in `stop` never returns.
    f.server.stop();
}
