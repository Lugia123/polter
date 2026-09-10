//! Ghostty private OSC 60: command capture.
//!
//! `ESC ] 60 ; <token> ; <command text> ST`
//!
//! Emitted by shell integration's preexec hook, carrying the command line
//! the shell is about to run, verbatim, so core can append it to that
//! surface's command-history file (see `src/Project.zig` for the file
//! this feeds -- a saved project's pane remembers the name of that file,
//! not the commands themselves, so pressing up-arrow in a reloaded pane
//! reaches the same history).
//!
//! **The token is the whole reason this isn't just `text`.** OSC is bytes
//! written to the terminal, and anything with a file descriptor pointed at
//! this pane can write bytes to it -- `cat` on a file that happens to
//! contain the right escape sequence, a build log, the far end of an `ssh`
//! session. Without something the shell knows and a hostile write doesn't,
//! any of those could plant a command in this pane's history that the user
//! never typed, one up-arrow and an Enter away from running. The token is a
//! random value Ghostty puts in the child process's own environment at
//! spawn (`GHOSTTY_HISTORY_TOKEN`, alongside `GHOSTTY_SHELL_FEATURES`);
//! shell integration reads it back out of its own environment and echoes
//! it here. This parser only checks the token is present and well-formed
//! -- comparing it against what this surface actually issued happens where
//! that value lives, in `termio/stream_handler.zig`, using
//! `std.crypto.timing_safe.eql`.
//!
//! **What this does not defend against**: code already running as the
//! user, in this pane, can read its own environment and forge a
//! perfectly-tokened OSC 60 -- there is no boundary between "the shell"
//! and "a program the shell ran" from the terminal's point of view. The
//! boundary this draws is narrower and still worth having: it separates
//! *content the terminal is merely displaying* (untrusted, can't read the
//! token) from *code running as you* (already trusted with everything
//! else your account can do).
//!
//! Past the token there is exactly one field and no further sub-delimiters:
//! everything after the second `;` is the command, including any `;` it
//! contains.
const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const encoding = @import("../encoding.zig");

const log = std.log.scoped(.osc_command_capture);

pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    assert(parser.state == .@"60");

    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };

    // Write a NUL byte to ensure the whole capture, and so `text`, ends up
    // NUL-terminated.
    cap.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    const body = data[0 .. data.len - 1];

    const sep = std.mem.indexOfScalar(u8, body, ';') orelse {
        log.warn("OSC 60: missing token separator", .{});
        parser.state = .invalid;
        return null;
    };

    // Turn the separator into the NUL that terminates `token`, in place.
    // This buffer is otherwise unused after `parse` returns (the caller
    // copies out whatever it wants to keep), so mutating it here doesn't
    // step on anyone.
    data[sep] = 0;
    const token = data[0..sep :0];
    const text = data[sep + 1 .. data.len - 1 :0];

    if (token.len == 0) {
        log.warn("OSC 60: empty token", .{});
        parser.state = .invalid;
        return null;
    }

    // A command containing an ESC or BEL could otherwise smuggle a second
    // escape sequence into what looks like one history entry, and a
    // control character breaks the one-line-per-record shape the history
    // file assumes. Reject the whole thing rather than sanitize it: a
    // silently-mangled command is worse than a dropped one, since it would
    // be replayed on up-arrow as something the user never typed.
    if (!encoding.isSafeUtf8(text)) {
        log.warn("OSC 60: command text is not escape code safe UTF-8", .{});
        parser.state = .invalid;
        return null;
    }

    parser.command = .{ .command_capture = .{ .token = token, .text = text } };
    return &parser.command;
}

test "OSC 60: a plain command" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "60;abc123;echo hello";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .command_capture);
    try testing.expectEqualStrings("abc123", cmd.command_capture.token);
    try testing.expectEqualStrings("echo hello", cmd.command_capture.text);
}

test "OSC 60: semicolons in the command are not a delimiter" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "60;abc123;ls; pwd";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expectEqualStrings("abc123", cmd.command_capture.token);
    try testing.expectEqualStrings("ls; pwd", cmd.command_capture.text);
}

test "OSC 60: an empty command still parses" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "60;abc123;";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .command_capture);
    try testing.expectEqualStrings("abc123", cmd.command_capture.token);
    try testing.expectEqualStrings("", cmd.command_capture.text);
}

test "OSC 60: a missing token separator is rejected" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // No second ';' at all -- looks like the old, pre-token wire shape.
    const input = "60;echo hello";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end(null) == null);
}

test "OSC 60: an empty token is rejected" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "60;;echo hello";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end(null) == null);
}

test "OSC 60: an embedded ESC is rejected rather than smuggled" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "60;abc123;echo \x1b]2;hijack\x07";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end(null) == null);
}

test "OSC 60: without an allocator, falls back to the fixed buffer" {
    const testing = std.testing;

    var p: Parser = .init(null);
    defer p.deinit();

    const input = "60;abc123;printf %s hi";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expectEqualStrings("abc123", cmd.command_capture.token);
    try testing.expectEqualStrings("printf %s hi", cmd.command_capture.text);
}
