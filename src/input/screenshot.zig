//! The words of the screenshot feature that both hosts show, named once so
//! the two cannot drift apart on them: the toolbar and its hover text, the
//! property bar, the long screenshot's prompts, the sentence for a hotkey
//! another program holds, and the one line of text a screenshot's
//! annotations are pasted as. (The settings rows are `config/form.zig`'s.)
//!
//! About that line:
//!
//! The line itself (`dev-docs/poltergeist/screenshot.md`, 4.2) is assembled
//! by the host that took the screenshot -- it is the one holding the
//! annotations -- and reads, in English:
//!
//!     [Screenshot annotations 1280x800] #1 (412,96) misaligned; Text (60,500)
//!     too wide; Box (380,80,240,44); Arrow (100,300)->(220,340). See <json>
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
    tool_select,
    tool_rect,
    tool_ellipse,
    tool_line,
    tool_highlighter,
    tool_number,
    tool_mosaic,
    tool_long,
    done,
    prop_color,
    prop_width,
    prop_block,
    color_red,
    color_orange,
    color_yellow,
    color_green,
    color_cyan,
    color_blue,
    color_purple,
    color_black,
    color_white,
    word_ellipse,
    word_line,
    screenshot,
    header,
    text,
    rect,
    arrow,
    pen,
    separator,
    see,
    palette_description,
    font_missing,
    long_hint,
    long_slower,
    long_limit,
    long_tiles,
    long_whole,
    hotkey_failed,
    hotkey_taken,
    search_empty,

    pub fn msgid(self: Msgid) [:0]const u8 {
        return switch (self) {
            .tool_select => i18n.N_("Select"),
            .tool_rect => i18n.N_("Rectangle"),
            .tool_ellipse => i18n.N_("Ellipse"),
            .tool_line => i18n.N_("Straight Line"),
            .tool_highlighter => i18n.N_("Highlighter"),
            .tool_number => i18n.N_("Number"),
            .tool_mosaic => i18n.N_("Mosaic"),
            .tool_long => i18n.N_("Long Screenshot"),
            .done => i18n.N_("Done"),
            .prop_color => i18n.N_("Color"),
            .prop_width => i18n.N_("Thickness"),
            .prop_block => i18n.N_("Block Size"),
            .color_red => i18n.N_("Red"),
            .color_orange => i18n.N_("Orange"),
            .color_yellow => i18n.N_("Yellow"),
            .color_green => i18n.N_("Green"),
            .color_cyan => i18n.N_("Cyan"),
            .color_blue => i18n.N_("Blue"),
            .color_purple => i18n.N_("Purple"),
            .color_black => i18n.N_("Black"),
            .color_white => i18n.N_("White"),
            .word_ellipse => i18n.N_("Circle"),
            .word_line => i18n.N_("Line"),
            .screenshot => i18n.N_("Screenshot"),
            .header => i18n.N_("Screenshot annotations"),
            .text => i18n.N_("Text"),
            .rect => i18n.N_("Box"),
            .arrow => i18n.N_("Arrow"),
            .pen => i18n.N_("Pen"),
            .separator => i18n.N_("; "),
            .see => i18n.N_(". See "),
            .palette_description => i18n.N_("Freeze the screen, pick a window or drag a region, annotate it, and put the result on the clipboard."),
            .font_missing => i18n.N_("The annotation font is missing, so the system font is used."),
            .long_hint => i18n.N_("Scroll down slowly. What comes into view is added at the bottom."),
            .long_slower => i18n.N_("Scroll slower"),
            .long_limit => i18n.N_("The height limit was reached."),
            .long_tiles => i18n.N_("{n} tiles, first {m} pasted"),
            .long_whole => i18n.N_("whole image"),
            .hotkey_failed => i18n.N_("The screenshot shortcut could not be registered"),
            .hotkey_taken => i18n.N_("Another application is already using it. Choose a different one with a `screenshot` keybind in the configuration."),
            .search_empty => i18n.N_("No settings match."),
        };
    }
};

/// Whether `text` has a live catalogue entry for `msgid`, and its
/// translation when it has one. The generator writes these entries on one
/// line each, which is the only form looked for; an entry `msgmerge` has
/// re-wrapped would read as missing, and that is a failure worth having.
fn catalogueEntry(alloc: std.mem.Allocator, text: []const u8, msgid: []const u8) !?[]const u8 {
    const needle = try std.fmt.allocPrint(alloc, "\nmsgid \"{s}\"\nmsgstr \"", .{msgid});
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    const rest = text[at + needle.len ..];
    const end = std.mem.indexOf(u8, rest, "\"\n") orelse return null;
    return rest[0..end];
}

/// The value a macOS `.strings` table gives `key`.
fn stringsValue(alloc: std.mem.Allocator, text: []const u8, key: []const u8) !?[]const u8 {
    const needle = try std.fmt.allocPrint(alloc, "\n\"{s}\" = \"", .{key});
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    const rest = text[at + needle.len ..];
    const end = std.mem.indexOf(u8, rest, "\";\n") orelse return null;
    return rest[0..end];
}

fn readRepoFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    // **A missing file fails rather than skips**, as every floor that reads
    // the tree does here.
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 * 1024 * 1024)) catch |err| {
        std.debug.print("cannot read {s} ({t}). Run `zig build test` from the repository root.\n", .{ path, err });
        return error.RepoFileUnreadable;
    };
}

/// **The floor under both hosts' copies of a screenshot string.** A host
/// passes the English text to its own lookup, so a msgid reworded in the
/// core and not in a table does not fail anywhere: the lookup misses, the
/// English comes back, and a Chinese screen has one English word on it.
///
/// For each msgid: it is in the template; **every** catalogue under `po/`
/// translates it; the macOS tables have it as a key; and the two Chinese
/// tables -- `po/zh_CN.po` for Windows, `zh-Hans.lproj` for macOS -- say
/// the same thing, so the two hosts do not show different words for one
/// button.
pub fn expectEverywhere(msgids: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const template = try readRepoFile(io, alloc, "po/" ++ build_config.bundle_id ++ ".pot");
    for (msgids) |msgid| {
        const entry = try catalogueEntry(alloc, template, msgid);
        if (entry == null) std.debug.print("the template has no msgid \"{s}\"\n", .{msgid});
        try std.testing.expect(entry != null);
    }

    var chinese: []const u8 = "";
    var catalogues: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(io, "po", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |file| {
        if (!std.mem.endsWith(u8, file.name, ".po")) continue;
        catalogues += 1;
        const path = try std.fmt.allocPrint(alloc, "po/{s}", .{file.name});
        const text = try readRepoFile(io, alloc, path);
        if (std.mem.eql(u8, file.name, "zh_CN.po")) chinese = text;
        for (msgids) |msgid| {
            const translated = if (try catalogueEntry(alloc, text, msgid)) |t| t.len > 0 else false;
            if (!translated) std.debug.print("{s} has no translation of \"{s}\"\n", .{ path, msgid });
            try std.testing.expect(translated);
        }
    }
    // Thirty-four when this was written. A walk that found none would have
    // passed everything above without reading a single translation.
    try std.testing.expect(catalogues >= 30);
    try std.testing.expect(chinese.len > 0);

    const base = try readRepoFile(io, alloc, "macos/Sources/App/Base.lproj/Localizable.strings");
    const hans = try readRepoFile(io, alloc, "macos/Sources/App/zh-Hans.lproj/Localizable.strings");
    for (msgids) |msgid| {
        errdefer std.debug.print("msgid \"{s}\"\n", .{msgid});

        // The key is the English text, and the base table gives it back.
        const english = try stringsValue(alloc, base, msgid);
        if (english == null) std.debug.print("Base.lproj has no key \"{s}\"\n", .{msgid});
        try std.testing.expect(english != null);
        try std.testing.expectEqualStrings(msgid, english.?);

        const mac = try stringsValue(alloc, hans, msgid);
        if (mac == null) std.debug.print("zh-Hans.lproj has no key \"{s}\"\n", .{msgid});
        try std.testing.expect(mac != null);

        const windows = (try catalogueEntry(alloc, chinese, msgid)).?;
        try std.testing.expectEqualStrings(windows, mac.?);
    }
}

test "every screenshot msgid is in the template, in every language, and in the macOS tables" {
    var msgids: [std.enums.values(Msgid).len][]const u8 = undefined;
    for (std.enums.values(Msgid), &msgids) |m, *out| out.* = m.msgid();
    try expectEverywhere(&msgids);
}

test "no two screenshot msgids are the same text" {
    // One text is one catalogue entry and so one translation: two buttons
    // sharing a msgid cannot be called different things in any language.
    const all = std.enums.values(Msgid);
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| {
            const same = std.mem.eql(u8, a.msgid(), b.msgid());
            if (same) std.debug.print("{t} and {t} are both \"{s}\"\n", .{ a, b, a.msgid() });
            try std.testing.expect(!same);
        }
    }
}
