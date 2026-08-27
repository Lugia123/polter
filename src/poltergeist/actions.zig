//! The terminal's own actions, as a thing an agent can ask for by name.
//!
//! Every item on the menu bar ends up in the same place. On macOS the menu
//! items call into `ghostty_surface_binding_action(surface, "toggle_fullscreen")`
//! and friends, which is `input.Binding.Action.parse` followed by
//! `Surface.performBindingAction`. The keybinding vocabulary is therefore a
//! superset of the menu: everything a person can click, plus everything they
//! could bind a key to.
//!
//! So this exposes that vocabulary rather than transcribing the menu into
//! fifty hand-written tools. Three things follow from doing it this way, and
//! the third is the one that matters:
//!
//!   * No apprt work. The dispatcher is in the core, and so are we.
//!   * New upstream actions arrive for free, with nobody to remember to
//!     mirror them.
//!   * **An agent and a person take the same code path.** A separate
//!     "for agents" implementation of the same button is two things that
//!     drift, and the drift is where the bugs live.
//!
//! The action strings are the ones from the config file -- `new_tab`,
//! `increase_font_size:1`, `goto_split:left` -- deliberately, because a
//! second vocabulary meaning the same things is a second vocabulary to keep
//! in step.

const std = @import("std");
const inputpkg = @import("../input.zig");

/// One action an agent may ask for.
pub const Entry = struct {
    name: []const u8,

    /// Whether it wants a `:value` after the name. `new_tab` does not,
    /// `goto_split` does, and asking for one without the other is the
    /// commonest way to get it wrong.
    takes_value: bool,
};

/// Every action, worked out at compile time from the union itself.
///
/// From the type rather than from a list somebody maintains: a list would be
/// wrong the first time upstream added an action, and wrong silently -- the
/// action would work when asked for by name and simply not be mentioned by
/// `terminal_actions`, which is the worst of both.
pub const all: []const Entry = blk: {
    const fields = @typeInfo(inputpkg.Binding.Action).@"union".fields;
    var out: [fields.len]Entry = undefined;
    for (fields, 0..) |field, i| {
        out[i] = .{
            .name = field.name,
            .takes_value = field.type != void,
        };
    }
    const frozen = out;
    break :blk &frozen;
};

/// Whether `name` is an action at all, ignoring any `:value`.
///
/// Cheaper than parsing and, more to the point, answerable without an
/// allocator -- the listing and the "did you mean" both want it.
pub fn known(name: []const u8) bool {
    for (all) |e| if (std.mem.eql(u8, e.name, name)) return true;
    return false;
}

/// The action name out of a request, which may or may not carry a value.
pub fn nameOf(action: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, action, ':') orelse return action;
    return action[0..colon];
}

test "every action in the union is listed" {
    const testing = std.testing;

    // The count comes from the same place the list does, so this is not
    // checking arithmetic -- it is checking that the list is built from the
    // type at all, and would catch somebody replacing it with a literal.
    const fields = @typeInfo(inputpkg.Binding.Action).@"union".fields;
    try testing.expectEqual(fields.len, all.len);

    // Ninety-two at the time of writing. Not pinned exactly, because
    // upstream adds actions and a test that fails for that reason teaches
    // nobody anything -- but pinned enough to catch the list becoming a
    // hand-typed handful.
    try testing.expect(all.len > 50);

    // A few by name, chosen because they are the ones the menu bar uses.
    try testing.expect(known("new_tab"));
    try testing.expect(known("toggle_fullscreen"));
    try testing.expect(known("copy_to_clipboard"));
    try testing.expect(!known("definitely_not_an_action"));
}

test "an action name is what comes before the colon" {
    const testing = std.testing;
    try testing.expectEqualStrings("goto_split", nameOf("goto_split:left"));
    try testing.expectEqualStrings("new_tab", nameOf("new_tab"));

    // A trailing colon with nothing after it still names the action; whether
    // the empty value is acceptable is the parser's business, not ours.
    try testing.expectEqualStrings("increase_font_size", nameOf("increase_font_size:"));
}

test "whether an action wants a value is read off its type" {
    const testing = std.testing;

    for (all) |e| {
        if (std.mem.eql(u8, e.name, "new_tab")) try testing.expect(!e.takes_value);
        if (std.mem.eql(u8, e.name, "goto_split")) try testing.expect(e.takes_value);
    }
}
