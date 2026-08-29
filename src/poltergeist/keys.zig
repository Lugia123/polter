//! Control keys, as a thing an agent can ask for by name.
//!
//! `terminal_send` types text, and text is all it will ever do: it goes
//! down the paste path, and `src/input/paste.zig` replaces `0x03`, ESC,
//! `0x1A` and the rest of the control bytes with spaces before they reach
//! the child. That stripping is xterm's, it is a safety measure against
//! commands hidden inside pasted text, and it is not going to be relaxed --
//! the moment "send text" could also press Ctrl-C, every call site of
//! `terminal_send` in the whole surface would have to be re-argued.
//!
//! So pressing a key is a second, separately authorised verb. It goes
//! through `Surface.keyCallback`, which is the same door a person's
//! keyboard comes in by -- the same door `typePoltergeistText` already uses
//! for the return at the end of a notice.
//!
//! **The vocabulary is the keybinding vocabulary**, for the same reason
//! `actions.zig` uses the action vocabulary: `ctrl+c`, `escape`,
//! `ctrl+shift+k`, `alt+f4`. It is what the config file writes, what every
//! Ghostty user has read, and what an AI has already seen a thousand times
//! in other people's documentation. Inventing a second spelling for the
//! same key would be a second spelling to keep in step, and the day it
//! drifts nobody will notice.
//!
//! And, again like `actions.zig`, **the catalogue is computed from the
//! types themselves** -- the modifier names off `input.Mods`, the key names
//! off `input.Key`. A hand-written list would be wrong the first time
//! upstream added a key, and wrong silently: the key would work when asked
//! for and simply not be mentioned by `terminal_keys`.

const std = @import("std");
const inputpkg = @import("../input.zig");
const key_mods = @import("../input/key_mods.zig");

pub const Error = error{
    /// Not a trigger the keybinding parser recognises.
    Invalid,

    /// Modifiers with no key after them: `ctrl` on its own.
    NoKey,

    /// `catch_all`, which is a binding pattern rather than a key. There is
    /// no such physical key to press.
    CatchAll,

    /// A plain printable character with no ctrl/alt/super on it. That is
    /// text, and text has its own tool. Refused rather than sent, because
    /// an unmodified letter with no `utf8` on the event encodes to nothing
    /// at all -- the call would look like it worked and do nothing.
    PlainText,
};

/// Parse a key the way a keybinding trigger is parsed, and refuse the
/// shapes that would not do what the caller meant.
pub fn parse(spec: []const u8) Error!inputpkg.Trigger {
    if (spec.len == 0) return error.NoKey;

    const trigger = inputpkg.Trigger.parse(spec) catch return error.Invalid;

    switch (trigger.key) {
        .catch_all => return error.CatchAll,
        .physical => |k| {
            if (k == .unidentified) return error.NoKey;
            if (k.printable() and !hasChord(trigger.mods)) return error.PlainText;
        },
        .unicode => {
            if (!hasChord(trigger.mods)) return error.PlainText;
        },
    }

    return trigger;
}

/// Whether this is a chord rather than a character.
///
/// Shift is deliberately not in here: `shift+a` is a capital A, which is
/// text. Ctrl, alt and super are the three that turn a letter into
/// something the program on the other end reads as a command.
fn hasChord(mods: inputpkg.Mods) bool {
    return mods.ctrl or mods.alt or mods.super;
}

/// The key event a person pressing this trigger would produce.
///
/// `utf8` is left empty on purpose. The encoder's `ctrlSeq` wants exactly
/// that: with no committed text it falls back to the logical key's
/// codepoint, which is how `ctrl+c` becomes `0x03`. Handing it a `utf8` we
/// synthesised would be this file guessing at the keyboard layout, which is
/// the apprt's job and not ours.
pub fn event(trigger: inputpkg.Trigger) inputpkg.KeyEvent {
    var ev: inputpkg.KeyEvent = .{
        .action = .press,
        .mods = trigger.mods,
    };

    switch (trigger.key) {
        .physical => |k| {
            ev.key = k;
            ev.unshifted_codepoint = k.codepoint() orelse 0;
        },

        // A codepoint the config file wrote as a literal character. The
        // physical key is looked up so that the encoder has one; for
        // anything outside ASCII there is no such key and the codepoint
        // alone has to carry it.
        .unicode => |cp| {
            ev.unshifted_codepoint = cp;
            if (std.math.cast(u8, cp)) |byte| {
                if (std.ascii.isAscii(byte)) {
                    ev.key = inputpkg.Key.fromASCII(byte) orelse .unidentified;
                }
            }
        },

        .catch_all => {},
    }

    return ev;
}

/// Every modifier name the parser accepts, worked out from `input.Mods`
/// and the alias table rather than typed out.
pub const modifiers: []const []const u8 = blk: {
    const fields = @typeInfo(inputpkg.Mods).@"struct".fields;

    var count: usize = 0;
    for (fields) |f| {
        if (f.type == bool) count += 1;
    }
    count += key_mods.alias.len;

    var out: [count]([]const u8) = undefined;
    var i: usize = 0;
    for (fields) |f| {
        if (f.type != bool) continue;
        out[i] = f.name;
        i += 1;
    }
    for (key_mods.alias) |pair| {
        out[i] = pair[0];
        i += 1;
    }

    const frozen = out;
    break :blk &frozen;
};

/// Every key name the parser accepts, worked out from `input.Key`.
///
/// `unidentified` is left out because it is the absence of a key rather
/// than one of them, and asking for it is `NoKey`.
pub const names: []const []const u8 = blk: {
    const fields = @typeInfo(inputpkg.Key).@"enum".fields;

    var count: usize = 0;
    for (fields) |f| {
        if (!std.mem.eql(u8, f.name, "unidentified")) count += 1;
    }

    var out: [count]([]const u8) = undefined;
    var i: usize = 0;
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "unidentified")) continue;
        out[i] = f.name;
        i += 1;
    }

    const frozen = out;
    break :blk &frozen;
};

/// What to tell the agent when a spec will not do.
pub fn refusal(err: Error) []const u8 {
    return switch (err) {
        error.Invalid => "that is not a key. Write it the way a keybinding is written -- " ++
            "`ctrl+c`, `escape`, `ctrl+shift+k` -- and call terminal_keys for the names.",
        error.NoKey => "modifiers on their own are not a key press; name the key too, as in `ctrl+c`.",
        error.CatchAll => "`catch_all` is a binding pattern, not a key anybody can press.",
        error.PlainText => "that is a character, not a chord. Ordinary text goes through " ++
            "terminal_send; this tool is for keys a program reads as a command, which " ++
            "means one of ctrl, alt or super, or a named key such as `escape` or `f2`.",
    };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test "ctrl+c parses to the chord a person would press" {
    const t = try parse("ctrl+c");
    try testing.expect(t.mods.ctrl);
    try testing.expect(!t.mods.shift);

    const ev = event(t);
    try testing.expectEqual(inputpkg.Key.key_c, ev.key);
    try testing.expectEqual(@as(u21, 'c'), ev.unshifted_codepoint);

    // Empty on purpose -- see `event`. This is what lets the encoder take
    // the ctrl-sequence path and produce 0x03.
    try testing.expectEqual(@as(usize, 0), ev.utf8.len);
    try testing.expectEqual(inputpkg.Action.press, ev.action);
}

test "a ctrl chord encodes to the C0 byte it is supposed to" {
    // The whole reason this tool exists: `terminal_send` cannot carry
    // 0x03, because the paste path replaces it with a space. This asserts
    // the key path really does produce it, rather than trusting that it
    // does because the parse looked right.
    const cases = [_]struct { []const u8, u8 }{
        .{ "ctrl+c", 0x03 },
        .{ "ctrl+d", 0x04 },
        .{ "ctrl+z", 0x1A },
    };

    for (cases) |c| {
        var buf: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try inputpkg.key_encode.encode(&writer, event(try parse(c[0])), .{});
        try testing.expectEqual(@as(usize, 1), writer.buffered().len);
        try testing.expectEqual(c[1], writer.buffered()[0]);
    }
}

test "escape is a key on its own, and needs no modifier" {
    const t = try parse("escape");
    try testing.expectEqual(inputpkg.Key.escape, t.key.physical);

    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try inputpkg.key_encode.encode(&writer, event(t), .{});
    try testing.expectEqualStrings("\x1b", writer.buffered());
}

test "a bare character is refused and pointed at terminal_send" {
    // Not a failure of nerve: an unmodified letter with no `utf8` on the
    // event encodes to nothing, so accepting it would mean a call that
    // reports success and does not press anything.
    try testing.expectError(error.PlainText, parse("a"));
    try testing.expectError(error.PlainText, parse("shift+a"));
    try testing.expectError(error.PlainText, parse("1"));

    // But the same letter with a chord on it is exactly the point.
    _ = try parse("ctrl+a");
    _ = try parse("alt+a");
}

test "the shapes that are not a key press say which shape they are" {
    try testing.expectError(error.NoKey, parse(""));
    try testing.expectError(error.NoKey, parse("ctrl"));
    try testing.expectError(error.NoKey, parse("ctrl+shift"));
    try testing.expectError(error.CatchAll, parse("catch_all"));
    try testing.expectError(error.Invalid, parse("ctrl+definitely_not_a_key"));
    try testing.expectError(error.Invalid, parse("ctrl+ctrl+c"));

    inline for (@typeInfo(Error).error_set.?) |e| {
        const msg = refusal(@field(Error, e.name));
        try testing.expect(msg.len > 20);
    }
}

test "the catalogue is built from the types, not typed out" {
    // Same guard `actions.zig` keeps: the count comes from the same place
    // the list does, so this checks that the list is derived at all and
    // would catch somebody replacing it with a literal handful.
    const key_fields = @typeInfo(inputpkg.Key).@"enum".fields;
    try testing.expectEqual(key_fields.len - 1, names.len);
    try testing.expect(names.len > 100);

    var found_escape = false;
    var found_f1 = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "escape")) found_escape = true;
        if (std.mem.eql(u8, n, "f1")) found_f1 = true;
        try testing.expect(!std.mem.eql(u8, n, "unidentified"));
    }
    try testing.expect(found_escape);
    try testing.expect(found_f1);

    // Every name the catalogue offers has to be one the parser takes, or
    // the listing is sending agents at keys that come back `Invalid`.
    for (names) |n| {
        _ = inputpkg.Trigger.parse(n) catch |err| {
            std.debug.print("catalogue lists an unparseable key: {s}\n", .{n});
            return err;
        };
    }

    // And every modifier, checked the same way by putting a key after it.
    for (modifiers) |m| {
        var buf: [64]u8 = undefined;
        const spec = try std.fmt.bufPrint(&buf, "{s}+escape", .{m});
        _ = inputpkg.Trigger.parse(spec) catch |err| {
            std.debug.print("catalogue lists an unparseable modifier: {s}\n", .{m});
            return err;
        };
    }

    for ([_][]const u8{ "ctrl", "shift", "alt", "super", "cmd", "opt" }) |want| {
        var found = false;
        for (modifiers) |m| {
            if (std.mem.eql(u8, m, want)) found = true;
        }
        try testing.expect(found);
    }
}
