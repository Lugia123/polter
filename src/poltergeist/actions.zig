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
const Bus = @import("Bus.zig");

/// One action an agent may ask for.
pub const Entry = struct {
    name: []const u8,

    /// Whether it wants a `:value` after the name. `new_tab` does not,
    /// `goto_split` does, and asking for one without the other is the
    /// commonest way to get it wrong.
    takes_value: bool,

    /// Whether an agent may point this at its own terminal. See
    /// `selfSafe`; it is the same answer, read off the same switch.
    ///
    /// Listed rather than left to be discovered, and the argument is the
    /// opposite of the one that keeps the governed family *out* of the
    /// catalogue. A governed action is refused to everyone, so an entry
    /// for it would only ever cost a turn. These are refused to nobody --
    /// `close_tab` on somebody else's terminal is an ordinary thing to
    /// ask -- so they belong in the catalogue, and what an agent needs is
    /// the one extra bit that says "not at yourself". Being told before
    /// trying is a turn saved; being told after is a turn spent.
    self_safe: bool,
};

/// Whether an agent may point this action at its own terminal.
///
/// **The line is: does the call come back to the caller.** Two ways it
/// can, and both are refused:
///
///   - **It writes into the caller's own input.** `text`, `csi`, `esc`,
///     `cursor_key` and the two pastes put bytes on the caller's stdin,
///     which its own harness then reads, which is `terminal_send` pointed
///     at yourself under another name. An agent that types and then reads
///     what it typed is a loop with no natural end. The `write_*_file`
///     three are here for the same reason and it is easy to miss: their
///     `paste` variant pastes the path in.
///   - **It takes the caller away mid-call.** `close_surface` and the
///     rest are not a loop at all -- they destroy the socket the reply was
///     going to go back down, so the caller learns nothing about a call
///     that did happen. `crash` is the whole app.
///
/// Everything else is a one-off with nothing to say back, and this is not
/// a grudging remainder: `new_split:right` on your own id is a terminal
/// giving itself a second pane to run a server in, which is the case this
/// function exists to allow.
///
/// **Exhaustive, with no `else`, and that is the expensive half of the
/// decision.** Ninety-three prongs is a wall, and a wall is what tempts
/// the next person to collapse it into `else => true`. It is worth the
/// wall anyway, for two reasons a shorter shape does not have:
///
///   - An action upstream adds does not compile until somebody has said
///     which side it is on, by name, in the error message. A deny-list
///     with `else => true` would default the new one to safe -- silently,
///     which is exactly how the Swift `Plugin.Kind` list missed `archive`
///     and then missed `provision`.
///   - The prongs are tags, not strings, so a rename upstream breaks the
///     build rather than quietly moving an action to the safe side.
///
/// The shape weighed against it was a small deny-list matched by name with
/// a comptime digest of the union's field names to catch drift. It is
/// fifteen lines instead of ninety-three, and it fails loudly -- but it
/// fails saying "something changed" rather than naming the action, and it
/// cannot tell an addition from a rename. That is the wrong kind of loud.
///
/// **If you are here to add a prong: that is the question this switch
/// exists to ask you.** Not "which list is longer", but: if an agent aims
/// this at its own terminal, does anything come back to it, and is it
/// still there to receive it?
pub fn selfSafeTag(tag: std.meta.Tag(inputpkg.Binding.Action)) bool {
    return switch (tag) {
        // Writes into the caller's own input.
        .text,
        .csi,
        .esc,
        .cursor_key,
        .paste_from_clipboard,
        .paste_from_selection,
        .write_scrollback_file,
        .write_screen_file,
        .write_selection_file,
        => false,

        // Takes the caller away before the reply can reach it.
        .close_surface,
        .close_tab,
        .close_window,
        .close_all_windows,
        .quit,
        .crash,
        => false,

        // Polter's own controls. Safe *here* only in the sense that this
        // is not the check that stops them: `governed` does, in the
        // handler, with an answer that says which of them to use instead.
        // Refusing them here as well would hand back `SelfTarget` and
        // send the caller looking at the wrong thing.
        .poltergeist_supervisor,
        .poltergeist_toggle_watch,
        .poltergeist_toggle_held,
        .poltergeist_toggle_shielded,
        .poltergeist_toggle_chat,

        // The splits, which are the point of all this.
        .new_split,
        .goto_split,
        .toggle_split_zoom,
        .resize_split,
        .equalize_splits,

        // And the rest: menu items that do a thing and say nothing back.
        .ignore,
        .unbind,
        .reset,
        .copy_to_clipboard,
        .copy_url_to_clipboard,
        .copy_title_to_clipboard,
        .increase_font_size,
        .decrease_font_size,
        .reset_font_size,
        .set_font_size,
        .search,
        .search_selection,
        .navigate_search,
        .start_search,
        .end_search,
        .clear_screen,
        .select_all,
        .scroll_to_top,
        .scroll_to_bottom,
        .scroll_to_selection,
        .scroll_to_row,
        .scroll_page_up,
        .scroll_page_down,
        .scroll_page_fractional,
        .scroll_page_lines,
        .adjust_selection,
        .jump_to_prompt,
        .new_window,
        .new_tab,
        .previous_tab,
        .next_tab,
        .last_tab,
        .goto_tab,
        .move_tab,
        .move_tab_to_new_window,
        .toggle_tab_overview,
        .prompt_surface_title,
        .prompt_tab_title,
        .prompt_window_title,
        .set_surface_title,
        .set_tab_title,
        .set_window_title,
        .goto_window,
        .toggle_readonly,
        .reset_window_size,
        .inspector,
        .show_gtk_inspector,
        .show_on_screen_keyboard,
        .open_config,
        .reload_config,
        .toggle_maximize,
        .toggle_fullscreen,
        .toggle_window_decorations,
        .toggle_window_float_on_top,
        .toggle_secure_input,
        .toggle_mouse_reporting,
        .toggle_command_palette,
        .toggle_quick_terminal,
        .toggle_visibility,
        .toggle_background_opacity,
        .check_for_updates,
        .undo,
        .redo,
        .end_key_sequence,
        .activate_key_table,
        .activate_key_table_once,
        .deactivate_key_table,
        .deactivate_all_key_tables,
        => true,
    };
}

/// `selfSafeTag` by name, for the caller that has a wire string rather
/// than a tag. Pass the bare name; `nameOf` strips any `:value`.
///
/// **A name that is not an action at all answers `true`**, which looks
/// like the wrong direction until you ask what the refusal would say. A
/// typo is not a self-target problem, and answering `SelfTarget` to one
/// sends the caller reading about loops instead of at its own spelling.
/// Let it through and the handler says "there is no action called ...",
/// which is the true answer. Nothing is performed either way.
pub fn selfSafe(name: []const u8) bool {
    const Tag = std.meta.Tag(inputpkg.Binding.Action);
    const fields = @typeInfo(inputpkg.Binding.Action).@"union".fields;
    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return selfSafeTag(@field(Tag, field.name));
        }
    }
    return true;
}

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
    const Tag = std.meta.Tag(inputpkg.Binding.Action);
    const fields = @typeInfo(inputpkg.Binding.Action).@"union".fields;
    var out: [fields.len]Entry = undefined;
    var n: usize = 0;
    for (fields) |field| {
        if (governed(field.name)) continue;
        out[n] = .{
            .name = field.name,
            .takes_value = field.type != void,
            .self_safe = selfSafeTag(@field(Tag, field.name)),
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

/// Who asked for a surface to close.
///
/// **This is the whole of the fix, and the union is the fix's shape.** The
/// close-confirmation used to be decided by `Surface.needsConfirmQuit`
/// alone, which knows what is running inside the terminal and nothing about
/// who is doing the closing. That was right while there was only one way to
/// close a terminal. There are two now, and they want different answers.
pub const CloseAsker = union(enum) {
    /// The person at the keyboard: a menu item, a keybinding, the tab's
    /// close button.
    user,

    /// The tool surface, aimed at a terminal carrying this mark.
    tool: Bus.Role,
};

/// Whether a close from `by` still puts the confirmation in front of the
/// user.
///
/// **The confirmation is a guard against the user's own misclick.** That is
/// the whole reason it exists, and it is why the answer for `.user` is
/// `true` with no second thought and no look at the mark. A rule phrased as
/// "watched terminals do not confirm" would read the same on this page and
/// be a different program: the user clicking close on a worker that is
/// mid-build would lose the one question that was there to catch them. That
/// is not moving the guard, it is deleting it.
///
/// **From the tool surface it is the target's mark that answers**, which is
/// the same judgement `rpc.authorize` already makes about reach and is
/// deliberately not a new idea:
///
///   - `.watched` and `.supervisor` are terminals somebody arranged. A
///     supervisor closing one is the arrangement working -- it is what it
///     was made a supervisor to do -- and there is nobody at that tab to
///     answer a dialog anyway. The dialog does not protect them, it strands
///     the caller behind a box it cannot see or press.
///
///   - `.none` is a terminal the program knows nothing about. It cannot
///     tell an agent from a person reading their mail, so it does not
///     guess: the confirmation is the only protection an unmarked terminal
///     has from a tool call, and it keeps it.
///
/// A `shielded` terminal never reaches here at all -- `rpc.authorize`
/// refuses the whole call before any of this -- so there is no prong for it
/// and there must not be one.
pub fn confirmsClose(by: CloseAsker) bool {
    return switch (by) {
        .user => true,

        .tool => |role| switch (role) {
            .watched, .supervisor => false,
            .none => true,
        },
    };
}

/// The same question again with the *target's* own protections folded back
/// in, and the second half of the rule: **the mark waives the dialog, the
/// user's lock puts it back.**
///
/// `asker` is `confirmsClose` already answered -- who is closing. `protected`
/// is one bit about what is being closed: whether the person at the keyboard
/// has put a lock on this terminal that a tool call has no business lifting.
/// Today that bit is `Surface.readonly`, which is the user reaching over and
/// saying "something is running in here, do not type into it". It belongs to
/// the same family as `held` and `shielded` -- all three are set by the user,
/// in the UI, about one terminal -- and that family has one rule: the tool
/// surface respects it. `shielded` is enforced in `rpc.authorize`, `held` in
/// the `governed` refusal, and this is `readonly`'s.
///
/// **It is `or`, and the asymmetry is the point.** A mark says "nobody is
/// sitting at this tab to press a button", which is a good reason to drop a
/// dialog. A lock says "the user decided this terminal is delicate", which is
/// not cancelled by the terminal also being supervised -- if anything the two
/// together are the exact case worth stopping for: a readonly terminal under
/// supervision is one the user locked *because* an agent can reach it. So the
/// two combine by keeping the dialog, never by dropping it.
///
/// **Two booleans rather than a `Surface`, on purpose.** `confirmsClose` above
/// is policy and nothing else: it takes who asked and answers, it imports
/// `Bus.Role` and no surface, and it is testable in this file without an
/// allocator or a running terminal. Handing it a `*Surface` -- or reading
/// `readonly` off one inside it -- would trade that for a function that can
/// only be exercised by standing up a terminal, which is how a rule stops
/// being checked. The bit comes in as a bit; the caller that owns the
/// surface is the one that reads it. See `Surface.toolCloseAsks`, which is
/// that caller.
///
/// The position rejected was folding this into `CloseAsker` -- a `protected`
/// field on the `.tool` prong. It cannot work and the reason is structural
/// rather than aesthetic: `CloseAsker` is built in `rpc.zig`, on the tool
/// surface's thread, from `Bus.roleOf`. The bus does not carry `readonly` and
/// should not start to -- it would be a second copy of a fact the surface
/// already owns, kept in step by hand, and the class of bug that produces is
/// the one where the copy is stale exactly when it matters.
pub fn confirmsCloseProtected(asker: bool, protected: bool) bool {
    return asker or protected;
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

test "the actions that come back to the caller are refused at its own id" {
    const testing = std.testing;

    // The two families, by name, so a rename that moved one to the safe
    // side is caught here as well as by the compiler.
    for ([_][]const u8{
        "text",              "csi",                   "esc",
        "cursor_key",        "paste_from_clipboard",  "paste_from_selection",
        "write_screen_file", "write_scrollback_file", "write_selection_file",
        "close_surface",     "close_tab",             "close_window",
        "close_all_windows", "quit",                  "crash",
    }) |name| {
        if (selfSafe(name)) {
            std.debug.print("\n{s} should not be self-safe\n", .{name});
            return error.TestUnexpectedResult;
        }
    }

    // And the ones this was opened for. `new_split` is the whole errand:
    // a terminal giving itself a pane to run something in.
    for ([_][]const u8{
        "new_split",         "goto_split",        "toggle_split_zoom",
        "resize_split",      "equalize_splits",   "new_tab",
        "new_window",        "set_surface_title", "reload_config",
        "toggle_fullscreen",
    }) |name| {
        if (!selfSafe(name)) {
            std.debug.print("\n{s} should be self-safe\n", .{name});
            return error.TestUnexpectedResult;
        }
    }

    // The value after the colon is not part of the answer; strip it the
    // way the caller does.
    try testing.expect(selfSafe(nameOf("new_split:right")));
    try testing.expect(!selfSafe(nameOf("write_screen_file:paste")));
}

test "a name that is no action at all is left for the handler to explain" {
    const testing = std.testing;

    // True, deliberately: a typo is not a self-target problem, and
    // answering `SelfTarget` to one sends the caller reading about loops
    // rather than at its own spelling. Nothing gets performed either way
    // -- `known` refuses it one step later.
    try testing.expect(selfSafe("new_splt"));
    try testing.expect(!known("new_splt"));
}

test "the catalogue carries the same answer the gate uses" {
    const testing = std.testing;

    // One source, not two. The failure this repository has shipped twice
    // is a second list that agreed with the first until it did not, so
    // the entry is built from `selfSafeTag` rather than restated.
    var refused: usize = 0;
    for (all) |e| {
        try testing.expectEqual(selfSafe(e.name), e.self_safe);
        if (!e.self_safe) refused += 1;
    }

    // Fifteen at the time of writing, and the shape that matters is that
    // it is a handful out of eighty-eight rather than the other way
    // round: the catalogue is mostly usable at one's own terminal.
    try testing.expect(refused > 0);
    try testing.expect(refused * 4 < all.len);

    // The governed family is not in the catalogue at all, so nothing here
    // depends on which side of `selfSafeTag` it sits.
    for (all) |e| try testing.expect(!governed(e.name));
}

test "the close confirmation follows who asked, and the user is always asked" {
    const testing = std.testing;

    // **The half easiest to write out of existence.** The user is asked,
    // full stop -- and `.user` carries no role for the answer to depend
    // on, which is the guarantee rather than a value this test happens to
    // check. A rule phrased as "watched terminals do not confirm" would
    // have taken a role here and quietly deleted the misclick guard.
    try testing.expect(confirmsClose(.user));
    try testing.expectEqual(void, @FieldType(CloseAsker, "user"));

    // From the tool surface, the mark answers -- exhaustively, so a role
    // added to `Bus.Role` has to be given a side here by name.
    for (std.enums.values(Bus.Role)) |role| {
        const want = switch (role) {
            .watched, .supervisor => false,
            .none => true,
        };
        if (confirmsClose(.{ .tool = role }) != want) {
            std.debug.print("\ntool close on {t}: wanted {}\n", .{ role, want });
            return error.ToolCloseConfirmWrong;
        }
    }
}

test "a lock on the target puts back the dialog the mark waived" {
    const testing = std.testing;

    // The case the mark rule got wrong on its own: a terminal that is both
    // supervised *and* readonly. The mark says nobody is at that tab; the
    // lock says the user made this one delicate on purpose. Closing it
    // silently is the readonly flag being spent on something it was never
    // for, so the lock wins.
    for (std.enums.values(Bus.Role)) |role| {
        const asked = confirmsClose(.{ .tool = role });
        try testing.expect(confirmsCloseProtected(asked, true));
    }

    // Unlocked, it is exactly `confirmsClose` again -- the fold adds
    // nothing when there is nothing to add, which is what makes it safe to
    // put on the path every tool close takes.
    for (std.enums.values(Bus.Role)) |role| {
        const asked = confirmsClose(.{ .tool = role });
        try testing.expectEqual(asked, confirmsCloseProtected(asked, false));
    }

    // And the user is unmoved either way: `.user` was already `true`, so
    // there is no combination of the two bits that takes the misclick guard
    // away from the person at the keyboard.
    for ([_]bool{ true, false }) |protected| {
        try testing.expect(confirmsCloseProtected(confirmsClose(.user), protected));
    }

    // Written out because `or` and `and` are one character apart and only
    // one of them is this rule. `and` would pass every assertion above that
    // uses a `true` asker; this is the pair that tells them apart.
    try testing.expect(confirmsCloseProtected(false, true));
    try testing.expect(!confirmsCloseProtected(false, false));
}

test "the user's close is the identity, so that path is unchanged by construction" {
    const testing = std.testing;

    // `Surface.close` reads `confirmsClose(.user) and needsConfirmQuit()`.
    // This is the claim that makes the `and` a no-op there: whatever
    // `needsConfirmQuit` says is what the user still gets. Written as a
    // test rather than as a comment because the comment cannot fail.
    for ([_]bool{ true, false }) |needs| {
        try testing.expectEqual(needs, confirmsClose(.user) and needs);
    }
}
