//! The words of the one line of text a screenshot's annotations are pasted
//! as, named once so the two hosts cannot drift apart on them.
//!
//! The line itself (`dev-docs/poltergeist/screenshot.md`, 4.2) is assembled
//! by the host that took the screenshot -- it is the one holding the
//! annotations -- and reads, in English:
//!
//!     [Screenshot annotations 1280×800] ① (412,96) misaligned; Text (60,500)
//!     too wide; Box (380,80,240,44); Arrow (100,300)→(220,340). See <json>
//!
//! Numbers, coordinates and what the person typed are not words and are not
//! here. Everything else is, including the two separators: Chinese joins the
//! items with `；` and ends on `。`, so punctuation typed into a host would be
//! the one part of the line that stayed English.
//!
//! **Each host localises these through its own system** -- the Windows host
//! asks `ghostty_translate` with the msgid, the macOS app looks the same
//! English text up in `Localizable.strings` -- which is why this file holds
//! msgids and not a function that builds the line. The test at the bottom is
//! what keeps a msgid from being reworded here and left behind in the
//! catalogue, where it would fall back to English and say nothing.
const std = @import("std");
const i18n = @import("../os/i18n.zig");
const build_config = @import("../build_config.zig");

pub const Msgid = enum {
    /// Opens the line, inside the brackets, before the image's size.
    header,
    /// A text annotation.
    text,
    /// A rectangle.
    rect,
    /// An arrow.
    arrow,
    /// A freehand stroke.
    pen,
    /// Between two annotations.
    separator,
    /// After the last annotation and before the path of the `.json`.
    see,

    pub fn msgid(self: Msgid) [:0]const u8 {
        return switch (self) {
            .header => i18n.N_("Screenshot annotations"),
            .text => i18n.N_("Text"),
            .rect => i18n.N_("Box"),
            .arrow => i18n.N_("Arrow"),
            .pen => i18n.N_("Pen"),
            .separator => i18n.N_("; "),
            .see => i18n.N_(". See "),
        };
    }
};

test "every screenshot annotation msgid is in the template and has a Chinese half" {
    // **The floor for the hosts' copies of these strings.** A host passes the
    // English text to its own lookup, so a msgid reworded here and not in the
    // catalogue does not fail anywhere: the lookup misses, the English comes
    // back, and a Chinese line arrives with one English word in it.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // **A missing file fails rather than skips**, as every floor that reads
    // the tree does here.
    const paths = [_][]const u8{ "po/" ++ build_config.bundle_id ++ ".pot", "po/zh_CN.po" };
    var files: [paths.len][]const u8 = undefined;
    for (paths, &files) |path, *out| {
        out.* = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            alloc,
            .limited(8 * 1024 * 1024),
        ) catch |err| {
            std.debug.print(
                "cannot read {s} ({t}). Run `zig build test` from the repository root.\n",
                .{ path, err },
            );
            return error.CatalogueUnreadable;
        };
    }

    for (std.enums.values(Msgid)) |m| {
        const entry = try std.fmt.allocPrint(alloc, "\nmsgid \"{s}\"\nmsgstr \"", .{m.msgid()});

        const in_template = std.mem.indexOf(u8, files[0], entry) != null;
        if (!in_template) std.debug.print("{s} has no msgid \"{s}\"\n", .{ paths[0], m.msgid() });
        try std.testing.expect(in_template);

        // In the Chinese catalogue the entry has to be there *and* say
        // something: `msgstr ""` is what `msgmerge` leaves for a string
        // nobody has translated, and it reads back as English.
        const at = std.mem.indexOf(u8, files[1], entry);
        const translated = if (at) |i| files[1][i + entry.len] != '"' else false;
        if (!translated) std.debug.print("{s} has no translation of \"{s}\"\n", .{ paths[1], m.msgid() });
        try std.testing.expect(translated);
    }
}
