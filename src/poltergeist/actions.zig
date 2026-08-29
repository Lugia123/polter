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

/// The prefix on every action that operates Poltergeist itself.
///
/// Matched rather than listed, for the reason the catalogue is generated
/// rather than typed: a hand-kept list of these would be missing the next
/// one somebody adds, and missing it silently.
const governed_prefix = "poltergeist_";

/// Whether this action is one of Poltergeist's own controls.
///
/// **These are the user's switches, and this surface will not press them.**
/// Each has an equivalent on the tool surface that carries the rules --
/// `set_watch` is the supervisor's, `become_supervisor` refuses a terminal
/// that is already watched, and the hold and the shield are the user's
/// alone. Reaching the same state through a keybinding action would be a
/// second road to all of it with no rules on it at all.
///
/// This was not hypothetical. With the family open, an agent could run
/// `poltergeist_toggle_held` on a terminal the user was holding and then
/// clock it off a moment later -- which is, word for word, the thing the
/// hold's own documentation says it exists to prevent. Verified on a real
/// machine before it was closed: the refusal said "only the user can
/// release it" one call before the release went through.
///
/// The general shape is worth keeping in view. "An agent and a person take
/// the same code path" is why one tool can open the whole menu, and it is
/// right for a menu item. It is exactly wrong for a control whose meaning
/// **is** who pressed it: sharing the path is what erases the distinction
/// that defines it.
pub fn governed(name: []const u8) bool {
    return std.mem.startsWith(u8, name, governed_prefix);
}

/// Every action an agent may ask for, worked out at compile time from the
/// union itself, minus the ones it may not.
///
/// From the type rather than from a list somebody maintains: a list would be
/// wrong the first time upstream added an action, and wrong silently -- the
/// action would work when asked for by name and simply not be mentioned by
/// `terminal_actions`, which is the worst of both.
///
/// The governed ones are left out rather than listed-and-refused. A
/// catalogue is what an agent picks from, and an entry that is always
/// refused is an invitation to spend a turn finding that out.
pub const all: []const Entry = blk: {
    const fields = @typeInfo(inputpkg.Binding.Action).@"union".fields;
    var out: [fields.len]Entry = undefined;
    var n: usize = 0;
    for (fields) |field| {
        if (governed(field.name)) continue;
        out[n] = .{
            .name = field.name,
            .takes_value = field.type != void,
        };
        n += 1;
    }
    const frozen = out;
    break :blk frozen[0..n];
};

/// Whether `name` is an action at all, ignoring any `:value`.
///
/// Cheaper than parsing and, more to the point, answerable without an
/// allocator -- the listing and the "did you mean" both want it.
///
/// Asked of the whole union, **including the governed ones**, and that is
/// the point: `poltergeist_toggle_held` is a real action that this surface
/// will not perform, which is a different answer from "there is no such
/// thing". Told the wrong one, a caller goes looking for the typo it did
/// not make. The handler asks `governed` separately and says which it is.
pub fn known(name: []const u8) bool {
    const fields = @typeInfo(inputpkg.Binding.Action).@"union".fields;
    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
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
    //
    // Every field except Polter's own controls, which are deliberately not
    // offered; `governed` says why.
    const fields = @typeInfo(inputpkg.Binding.Action).@"union".fields;
    var family: usize = 0;
    inline for (fields) |field| {
        if (governed(field.name)) family += 1;
    }
    try testing.expectEqual(fields.len - family, all.len);

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

test "Polter's own controls are governed, and the family is found by shape" {
    const testing = std.testing;

    // Every one of them, and named individually so this fails loudly if a
    // rename quietly takes one out of the family.
    try testing.expect(governed("poltergeist_supervisor"));
    try testing.expect(governed("poltergeist_toggle_watch"));
    try testing.expect(governed("poltergeist_toggle_held"));
    try testing.expect(governed("poltergeist_toggle_shielded"));
    try testing.expect(governed("poltergeist_toggle_chat"));

    // Ordinary menu items are not.
    try testing.expect(!governed("new_tab"));
    try testing.expect(!governed("copy_to_clipboard"));
    try testing.expect(!governed("toggle_fullscreen"));

    // And the union itself is the authority on who is in the family, so a
    // sixth one added upstream is governed on arrival rather than when
    // somebody remembers. Counted from the type, not from a literal.
    const fields = @typeInfo(inputpkg.Binding.Action).@"union".fields;
    var family: usize = 0;
    inline for (fields) |field| {
        if (governed(field.name)) family += 1;
    }
    try testing.expect(family >= 5);
    try testing.expectEqual(fields.len - family, all.len);
}

test "a governed action is real, but is not in the catalogue" {
    const testing = std.testing;

    // Both halves matter and they say different things. It exists -- so
    // the refusal can say "not this one" instead of "no such thing", and
    // send nobody hunting for a typo they did not make.
    try testing.expect(known("poltergeist_toggle_held"));

    // And it is not offered, because a catalogue entry that is always
    // refused costs a turn to discover.
    for (all) |e| try testing.expect(!governed(e.name));
}
