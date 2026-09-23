//! Whether the font families a configuration names are installed, said
//! where the user will see it (task 728).
//!
//! **A fork addition, not upstream Ghostty.** Upstream only logs a family it
//! cannot find (`log.warn("font-family {s} not found")` in `SharedGridSet`)
//! and carries on with the built-in font, so a misspelt family looks, from
//! the window, exactly like a font that was never asked for. This file puts
//! the miss into the configuration's diagnostics instead, which every
//! runtime already shows. It is kept in a file of its own so that merging
//! upstream touches nothing here; the lines that call it are marked where
//! they sit in upstream's files.
//!
//! **Visibility only: matching is not changed.** The question asked is the
//! one `SharedGridSet` asks -- `Discover.discover` with the family as
//! written -- so whatever that treats as a match (case ignored, spaces
//! significant, on every backend today) is what this treats as one. A
//! looser comparison here would report a font as present that the grid
//! then fails to load, which is the silence this exists to end.
//!
//! What it does not see: a family that is installed but has no face in the
//! style asked for. `SharedGridSet` searches with the style, size and
//! variations as well, and logs the same line when that narrower search
//! misses; this asks about the family alone.
//!
//! No "did you mean" either. Finding the nearest real name means listing
//! every installed font, and that was measured at 410ms for 940 faces on
//! macOS (Debug) -- on the thread loading the configuration, every load.
//! A suggestion that cheap to get wrong and that dear to get is not given.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("../config/Config.zig");
const discovery = @import("discovery.zig");
const Library = @import("library.zig").Library;

const log = std.log.scoped(.font_family_check);

/// The configuration keys that name a family, and the lists they hold.
const keys = [_][:0]const u8{
    "font-family",
    "font-family-bold",
    "font-family-italic",
    "font-family-bold-italic",
};

/// Add a diagnostic to `config` for every family it names that the
/// system's font discovery does not find. Nothing at all when this build
/// has no discovery (`Discover == void`), which cannot tell "missing" from
/// "not looked for".
pub fn diagnose(config: *Config) Allocator.Error!void {
    if (comptime discovery.Discover == void) return;

    // Discovery's own allocations are freed as it goes; the configuration's
    // arena is for what the configuration keeps.
    const alloc = config._arena.?.child_allocator;
    var lib = Library.init(alloc) catch |err| {
        log.warn("could not start font discovery to check font-family err={}", .{err});
        return;
    };
    defer lib.deinit();
    var disco: discovery.Discover = .init(lib);
    defer disco.deinit();

    var probe: Probe = .{ .alloc = alloc, .disco = &disco };
    try diagnoseWith(config, &probe, Probe.present);
}

/// The same, asking `present` instead of the system. Separate so the rules
/// -- which keys, and what is said -- can be tested without
/// depending on which fonts the test machine has.
pub fn diagnoseWith(
    config: *Config,
    ctx: anytype,
    comptime present: fn (@TypeOf(ctx), [:0]const u8) bool,
) Allocator.Error!void {
    const alloc = config._arena.?.allocator();
    inline for (keys) |key| {
        for (@field(config, key).list.items) |family| {
            if (present(ctx, family)) continue;
            try config._diagnostics.append(alloc, .{
                .key = key,
                .message = try std.fmt.allocPrintSentinel(
                    alloc,
                    "\"{s}\" is not an installed font family, so the built-in font " ++
                        "is used instead. Family names are matched as written with case " ++
                        "ignored -- spaces count, so \"JetBrainsMonoNerdFont\" does not " ++
                        "find \"JetBrainsMono Nerd Font\". `+list-fonts` lists the names.",
                    .{family},
                    0,
                ),
            });
        }
    }
}

const Probe = struct {
    alloc: Allocator,
    disco: *discovery.Discover,

    fn present(self: *Probe, family: [:0]const u8) bool {
        var it = self.disco.discover(self.alloc, .{ .family = family }) catch |err| {
            // Not known, so not reported: a diagnostic saying a font is
            // missing because discovery broke would send the user to fix
            // a configuration that is right.
            log.warn("could not check font-family {s} err={}", .{ family, err });
            return true;
        };
        defer it.deinit();
        const face = (it.next() catch return true) orelse return false;
        var f = face;
        f.deinit();
        return true;
    }
};

test "a family that is not there is said, with the name as written" {
    const testing = std.testing;
    var config: Config = try .default(testing.allocator);
    defer config.deinit();
    const alloc = config._arena.?.allocator();

    try config.@"font-family".parseCLI(alloc, "JetBrainsMonoNerdFont");
    try config.@"font-family-bold".parseCLI(alloc, "Here");

    const Fake = struct {
        fn present(_: void, family: [:0]const u8) bool {
            return std.mem.eql(u8, family, "Here");
        }
    };
    const before = config._diagnostics.items().len;
    try diagnoseWith(&config, {}, Fake.present);

    const diags = config._diagnostics.items()[before..];
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("font-family", diags[0].key);
    try testing.expect(std.mem.startsWith(u8, diags[0].message, "\"JetBrainsMonoNerdFont\""));
}

test "the system's answer: a real family is quiet, a made-up one is not" {
    // Against the discovery the grid uses, on the one backend this machine
    // can say something certain about: Monaco ships with every macOS.
    const options = @import("main.zig").options;
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;

    const testing = std.testing;
    var config: Config = try .default(testing.allocator);
    defer config.deinit();
    const alloc = config._arena.?.allocator();

    try config.@"font-family".parseCLI(alloc, "Monaco");
    try config.@"font-family".parseCLI(alloc, "NoSuchFontFamilyB1Xyz");

    const before = config._diagnostics.items().len;
    try diagnose(&config);

    const diags = config._diagnostics.items()[before..];
    try testing.expectEqual(@as(usize, 1), diags.len);
    const msg = diags[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "\"NoSuchFontFamilyB1Xyz\"") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "Monaco") == null);
}
