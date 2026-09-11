const std = @import("std");
const build_config = @import("../build_config.zig");
const assert = @import("../quirks.zig").inlineAssert;
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const input = @import("../input.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const CoreSurface = @import("../Surface.zig");
const lib = @import("../lib/main.zig");
const compat_testing = @import("../lib/compat/testing.zig");

/// The target for an action. This is generally the thing that had focus
/// while the action was made but the concept of "focus" is not guaranteed
/// since actions can also be triggered by timers, scripts, etc.
pub const Target = union(Key) {
    app,
    surface: *CoreSurface,

    // Sync with: ghostty_target_tag_e
    pub const Key = enum(c_int) {
        app,
        surface,

        test "ghostty.h Target.Key" {
            try lib.checkGhosttyHEnum(Key, "GHOSTTY_TARGET_");
        }
    };

    // Sync with: ghostty_target_u
    pub const CValue = extern union {
        app: void,
        surface: *apprt.Surface,
    };

    // Sync with: ghostty_target_s
    pub const C = extern struct {
        key: Key,
        value: CValue,
    };

    /// Convert to ghostty_target_s.
    pub fn cval(self: Target) C {
        return .{
            .key = @as(Key, self),
            .value = switch (self) {
                .app => .{ .app = {} },
                .surface => |v| .{ .surface = v.rt_surface },
            },
        };
    }
};

/// The possible actions an apprt has to react to. Actions are one-way
/// messages that are sent to the app runtime to trigger some behavior.
///
/// Actions are very often key binding actions but can also be triggered
/// by lifecycle events. For example, the `quit_timer` action is not bindable.
///
/// Importantly, actions are generally OPTIONAL to implement by an apprt.
/// Required functionality is called directly on the runtime structure so
/// there is a compiler error if an action is not implemented.
pub const Action = union(Key) {
    // A GUIDE TO ADDING NEW ACTIONS:
    //
    // 1. Add the action to the `Key` enum. The order of the enum matters
    //    because it maps directly to the libghostty C enum. For ABI
    //    compatibility, new actions should be added to the end of the enum.
    //
    // 2. Add the action and optional value to the Action union.
    //
    // 3. If the value type is not void, ensure the value is C ABI
    //    compatible (extern). If it is not, add a `C` decl to the value
    //    and a `cval` function to convert to the C ABI compatible value.
    //
    // 4. Update `include/ghostty.h`: add the new key, value, and union
    //    entry. If the value type is void then only the key needs to be
    //    added. Ensure the order matches exactly with the Zig code.

    /// Quit the application.
    quit,

    /// Open a new window. The target determines whether properties such
    /// as font size should be inherited.
    new_window,

    /// Open a new tab. If the target is a surface it should be opened in
    /// the same window as the surface. If the target is the app then
    /// the tab should be opened in a new window.
    new_tab: NewTab,

    /// Closes the tab belonging to the currently focused split, or all other
    /// tabs, depending on the mode.
    close_tab: CloseTabMode,

    /// Create a new split. The value determines the location of the split
    /// relative to the target.
    new_split: NewSplit,

    /// Close all open windows.
    close_all_windows,

    /// Toggle maximized window state.
    toggle_maximize,

    /// Toggle fullscreen mode.
    toggle_fullscreen: Fullscreen,

    /// Toggle tab overview.
    toggle_tab_overview,

    /// Toggle whether window directions are shown.
    toggle_window_decorations,

    /// Toggle the quick terminal in or out.
    toggle_quick_terminal,

    /// Toggle the command palette.
    toggle_command_palette,

    /// Toggle the window showing what the terminals have said to each
    /// other. See `docs/poltergeist/chatui.md`.
    toggle_poltergeist_chat,

    /// Toggle the visibility of all Ghostty terminal windows.
    toggle_visibility,

    /// Toggle the window background opacity. This only has an effect
    /// if the window started as transparent (non-opaque), and toggles
    /// it between fully opaque and the configured background opacity.
    toggle_background_opacity,

    /// Moves a tab by a relative offset.
    ///
    /// Adjusts the tab position based on `offset` (e.g., -1 for left, +1
    /// for right). If the new position is out of bounds, it wraps around
    /// cyclically within the tab range.
    move_tab: MoveTab,

    /// Jump to a specific tab. Must handle the scenario that the tab
    /// value is invalid.
    goto_tab: GotoTab,

    /// Jump to a specific split.
    goto_split: GotoSplit,

    /// Jump to next/previous window.
    goto_window: GotoWindow,

    /// Resize the split in the given direction.
    resize_split: ResizeSplit,

    /// Equalize all the splits in the target window.
    equalize_splits,

    /// Toggle whether a split is zoomed or not. A zoomed split is resized
    /// to take up the entire window.
    toggle_split_zoom,

    /// Present the target terminal whether its a tab, split, or window.
    present_terminal,

    /// Sets a size limit (in pixels) for the target terminal.
    size_limit: SizeLimit,

    /// Resets the window size to the default size. See the
    /// `reset_window_size` keybinding for more information.
    reset_window_size,

    /// Specifies the initial size of the target terminal.
    ///
    /// This may be sent once during the initialization of a surface
    /// (as part of the init call) to indicate the initial size requested
    /// for the window if it is not maximized or fullscreen.
    ///
    /// This may also be sent at any time after the surface is initialized
    /// to note the new "default size" of the window. This should in general
    /// be ignored, but may be useful if the apprt wants to support
    /// a "return to default size" action.
    initial_size: InitialSize,

    /// The cell size has changed to the given dimensions in pixels.
    cell_size: CellSize,

    /// The scrollbar is updating.
    scrollbar: terminal.Scrollbar,

    /// The target should be re-rendered. This usually has a specific
    /// surface target but if the app is targeted then all active
    /// surfaces should be redrawn.
    render,

    /// Control whether the inspector is shown or hidden.
    inspector: Inspector,

    /// Show the GTK inspector.
    show_gtk_inspector,

    /// The inspector for the given target has changes and should be
    /// rendered at the next opportunity.
    render_inspector,

    /// Export the Terminal IO inspector event log.
    export_terminal_io: ExportTerminalIO,

    /// Show a desktop notification.
    desktop_notification: DesktopNotification,

    /// Set the title of the target to the requested value.
    set_title: SetTitle,

    /// Set the tab title override for the target's tab.
    set_tab_title: SetTitle,

    /// Set the window title override for the target's tab.
    set_window_title: SetTitle,

    /// Set the title of the target to a prompted value. It is up to
    /// the apprt to prompt. The value specifies whether to prompt for the
    /// surface title or the tab title.
    prompt_title: PromptTitle,

    /// The current working directory has changed for the target terminal.
    pwd: Pwd,

    /// Set the mouse cursor shape.
    mouse_shape: terminal.MouseShape,

    /// Set whether the mouse cursor is visible or not.
    mouse_visibility: MouseVisibility,

    /// Called when the mouse is over or recently left a link.
    mouse_over_link: MouseOverLink,

    /// The health of the renderer has changed.
    renderer_health: renderer.Health,

    /// Open the Ghostty configuration. This is platform-specific about
    /// what it means; it can mean opening a dedicated UI or just opening
    /// a file in a text editor.
    open_config: OpenConfig,

    /// Called when there are no more surfaces and the app should quit
    /// after the configured delay.
    ///
    /// Despite the name, this is the notification that libghostty sends
    /// when there are no more surfaces regardless of if the configuration
    /// wants to quit after close, has any delay set, etc. It's up to the
    /// apprt to implement the proper logic based on the config.
    ///
    /// This can be cancelled by sending another quit_timer action with "stop".
    /// Multiple "starts" shouldn't happen and can be ignored or cause a
    /// restart it isn't that important.
    quit_timer: QuitTimer,

    /// Set the window floating state. A floating window is one that is
    /// always on top of other windows even when not focused.
    float_window: FloatWindow,

    /// Set the secure input functionality on or off. "Secure input" means
    /// that the user is currently at some sort of prompt where they may be
    /// entering a password or other sensitive information. This can be used
    /// by the app runtime to change the appearance of the cursor, setup
    /// system APIs to not log the input, etc.
    secure_input: SecureInput,

    /// A sequenced key binding has started, continued, or stopped.
    /// The UI should show some indication that the user is in a sequenced
    /// key mode because other input may be ignored.
    key_sequence: KeySequence,

    /// A key table has been activated or deactivated.
    key_table: KeyTable,

    /// A terminal color was changed programmatically through things
    /// such as OSC 10/11.
    color_change: ColorChange,

    /// A request to reload the configuration. The reload request can be
    /// from a user or for some internal reason. The reload request may
    /// request it is a soft reload or a full reload. See the struct for
    /// more documentation.
    ///
    /// The configuration should be passed to updateConfig either at the
    /// app or surface level depending on the target.
    reload_config: ReloadConfig,

    /// The configuration has changed. The value is a pointer to the new
    /// configuration. The pointer is only valid for the duration of the
    /// action and should not be stored.
    ///
    /// This should be used by apprts to update any internal state that
    /// depends on configuration for the given target (i.e. headerbar colors).
    /// The apprt should copy any data it needs since the memory lifetime
    /// is only valid for the duration of the action.
    ///
    /// This allows an apprt to have config-dependent state reactively
    /// change without having to store the entire configuration or poll
    /// for changes.
    config_change: ConfigChange,

    /// Closes the currently focused window.
    close_window,

    /// Called when the bell character is seen. The apprt should do whatever
    /// it needs to ring the bell. This is usually a sound or visual effect.
    ring_bell,

    /// Called when the active selection changes. The apprt should read the
    /// current selection itself; this carries no payload.
    selection_changed,

    /// Undo the last action. See the "undo" keybinding for more
    /// details on what can and cannot be undone.
    undo,

    /// Redo the last undone action.
    redo,

    check_for_updates,

    /// Open a URL using the native OS mechanisms. On macOS this might be `open`
    /// or on Linux this might be `xdg-open`. The exact mechanism is up to the
    /// apprt.
    open_url: OpenUrl,

    /// Show a native GUI notification that the child process has exited.
    show_child_exited: apprt.surface.Message.ChildExited,

    /// Show a native GUI notification about the progress of some TUI operation.
    progress_report: terminal.osc.Command.ProgressReport,

    /// Show the on-screen keyboard.
    show_on_screen_keyboard,

    /// A command has finished,
    command_finished: CommandFinished,

    /// Start the search overlay with an optional initial needle. If the
    /// search is already active and the needle is non-empty, update the
    /// current search needle and focus the search input.
    start_search: StartSearch,

    /// End the search overlay, clearing the search state and hiding it.
    end_search,

    /// The total number of matches found by the search.
    search_total: SearchTotal,

    /// The currently selected search match index (1-based).
    search_selected: SearchSelected,

    /// The readonly state of the surface has changed.
    readonly: Readonly,

    /// Copy the effective title of the surface to the clipboard.
    /// The effective title is the user-overridden title if set,
    /// otherwise the terminal-set title.
    copy_title_to_clipboard,

    /// Move a tab to a new window.
    move_tab_to_new_window,

    /// What Poltergeist has to say about this surface has changed.
    ///
    /// A mark is not a title, and this action exists so that it stops
    /// being carried as one. The apprt is expected to keep the value in a
    /// per-surface field of its own and compose it in front of the title
    /// at the moment the title is rendered. Writing it into the tab title
    /// instead gives that one field two writers -- Poltergeist and the
    /// program in the terminal, through OSC 0/2 -- and the second writer
    /// erases the first, which is what this replaced.
    poltergeist_mark: PoltergeistMark,

    /// Close a tab or a window because Poltergeist's tool surface asked, and
    /// say which of the two things that did.
    ///
    /// **Separate from `close_tab` and `close_window` rather than a flag on
    /// them, and that separation is the guarantee.** The confirmation those
    /// two raise is a guard against the user's own misclick, and the way to
    /// be sure a change did not weaken it is for the user's action to be
    /// byte-for-byte the action it was. `close_tab` is untouched here; an
    /// apprt that handles this one is adding a path, not editing one.
    ///
    /// It exists because closing a tab is decided in the apprt and nowhere
    /// else. A surface knows whether *it* needs confirming; only the apprt
    /// knows which surfaces share a tab, and only the apprt owns the dialog.
    /// So both halves of the tool's problem have to be answered out here:
    ///
    ///   - `confirm` travels down. False means the target carries a mark and
    ///     there is nobody at that tab to press a button, so the apprt should
    ///     close without asking. See `poltergeist.actions.confirmsClose`.
    ///
    ///   - `result` travels back up, and it is the half that was missing.
    ///     `performAction` answers "did you handle this", which a close that
    ///     put a dialog up and a close that actually happened both answer
    ///     `true` to. That is how `terminal_action` came to reply `{"ok":
    ///     true}` for a tab still sitting there. The apprt writes the outcome
    ///     through this pointer before it returns.
    ///
    /// The pointer is valid for the duration of the call and no longer, the
    /// same rule `config_change` states for its payload. Every apprt that
    /// handles this must write it, because the caller cannot tell "left
    /// alone" from any answer it might have wanted.
    poltergeist_close: PoltergeistClose,

    /// How many terminals share a tab with the target surface.
    ///
    /// **A question, not an instruction.** The core cannot answer it: as
    /// `App.zig` says where it refuses to decide `close_tab`, *nothing in the
    /// core knows which surfaces share a tab*. The layout lives in the apprt
    /// -- a `SplitTree` in Swift, a `polter_split_tree` in Rust -- so the
    /// core asks and decides, rather than each apprt deciding for itself.
    ///
    /// **The budget that reads this answer lives in one place** (`App.zig`,
    /// where a supervisor's worker terminals are placed). An apprt that held
    /// its own copy would be a second copy to drift, and the shape of the
    /// drift is the worst kind: two platforms laying panes out differently
    /// while every log line and every reply reads the same.
    poltergeist_tab_panes: PoltergeistTabPanes,
    poltergeist_layout: PoltergeistLayout,

    /// The filename (or, for fish, the session name) this surface's
    /// command-history capture is using. Fired once, synchronously, at
    /// surface creation -- unlike `pwd`, this value is fixed at spawn and
    /// never changes, so there is no mailbox round-trip, just a direct
    /// call where `history_filename` is decided (see `Surface.zig`).
    /// The apprt stores it against this pane so a later "save as
    /// project" can fill in `Project.Leaf.history` without asking core.
    history_filename: HistoryFilename,

    /// Sync with: ghostty_action_tag_e
    pub const Key = enum(c_int) {
        quit,
        new_window,
        new_tab,
        close_tab,
        new_split,
        close_all_windows,
        toggle_maximize,
        toggle_fullscreen,
        toggle_tab_overview,
        toggle_window_decorations,
        toggle_quick_terminal,
        toggle_command_palette,
        toggle_poltergeist_chat,
        toggle_visibility,
        toggle_background_opacity,
        move_tab,
        goto_tab,
        goto_split,
        goto_window,
        resize_split,
        equalize_splits,
        toggle_split_zoom,
        present_terminal,
        size_limit,
        reset_window_size,
        initial_size,
        cell_size,
        scrollbar,
        render,
        inspector,
        show_gtk_inspector,
        render_inspector,
        export_terminal_io,
        desktop_notification,
        set_title,
        set_tab_title,
        set_window_title,
        prompt_title,
        pwd,
        mouse_shape,
        mouse_visibility,
        mouse_over_link,
        renderer_health,
        open_config,
        quit_timer,
        float_window,
        secure_input,
        key_sequence,
        key_table,
        color_change,
        reload_config,
        config_change,
        close_window,
        ring_bell,
        selection_changed,
        undo,
        redo,
        check_for_updates,
        open_url,
        show_child_exited,
        progress_report,
        show_on_screen_keyboard,
        command_finished,
        start_search,
        end_search,
        search_total,
        search_selected,
        readonly,
        copy_title_to_clipboard,
        move_tab_to_new_window,
        poltergeist_mark,
        poltergeist_close,
        // **Added at the end, and that is load-bearing.** These values are
        // the tags `windows/host/src/ffi.rs` redeclares by hand; inserting a
        // member anywhere else renumbers the ones after it and the host then
        // dispatches into a different action's arm, with no crash and no
        // wrong-looking log line. The test below is what catches it.
        poltergeist_tab_panes,
        poltergeist_layout,
        history_filename,

        test "ghostty.h Action.Key" {
            try lib.checkGhosttyHEnum(Key, "GHOSTTY_ACTION_");
        }

        test "the Windows host's action tags" {
            // **The floor for `windows/host/src/ffi.rs`.** That file redeclares
            // this enum's values as Rust constants, because the host reaches
            // libghostty through the C ABI and gets a bare `u32` tag back with
            // no name attached. The numbers are written out by hand, counted
            // off `ghostty_action_tag_e`.
            //
            // **The failure a wrong number produces is not a crash.** The host
            // matches the tag, finds some other action's arm, and runs it: a
            // `pwd` report becomes a mouse-shape change, or two arms quietly
            // take each other's messages. It compiles, it runs, and the only
            // symptom is behaviour attributed to the wrong feature.
            //
            // This test is the only place that can see both sides -- the
            // constants are data, and the enum is right here. The other
            // direction, ffi.rs against `ghostty.h`, is **not** checked here:
            // `checkGhosttyHEnum` above already pins this enum to the header,
            // so going the long way round would be the same fact stored twice.
            //
            // **Two constants sharing a tag is not checked separately, because
            // it cannot be reached.** It was, until the attempt to make it
            // fail showed why it never could: two different names holding one
            // value means at least one of them disagrees with its own name, so
            // the check below fires first and names the culprit; and the same
            // name twice is a Rust compile error (`E0428`), so it never gets
            // this far. A branch whose floor cannot be built is not coverage,
            // it is the appearance of coverage, so it is gone rather than
            // sitting here looking like a guarantee.
            //
            // **Only the tags the host declares are checked, not all of them.**
            // This enum has far more members than the host has arms, and a tag
            // the host has not wired is the normal state, not a defect. Making
            // that fail would need an exemption list on day one, and that list
            // would be the next thing nobody maintains. The claim is "every
            // number the host states is right", not "the host states them all".
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();

            // **A missing file fails rather than skips**, for the reason the
            // synonyms floor in `input/command.zig` states: a skip would let
            // the floor quietly stop existing the first time someone ran the
            // suite from elsewhere, and nothing would say so.
            const src = std.Io.Dir.cwd().readFileAlloc(
                io,
                "windows/host/src/ffi.rs",
                alloc,
                .limited(512 * 1024),
            ) catch |err| {
                std.debug.print(
                    "cannot read windows/host/src/ffi.rs ({t}). " ++
                        "Run `zig build test` from the repository root.\n",
                    .{err},
                );
                return error.HostFfiUnreadable;
            };

            const prefix = "pub const ACTION_";
            var checked: usize = 0;

            var lines = std.mem.splitScalar(u8, src, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (!std.mem.startsWith(u8, line, prefix)) continue;
                const rest = line[prefix.len..];
                const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
                const eq = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
                const semi = std.mem.indexOfScalar(u8, rest, ';') orelse continue;
                const name = rest[0..colon];
                const value = std.fmt.parseInt(
                    c_int,
                    std.mem.trim(u8, rest[eq + 1 .. semi], " \t"),
                    10,
                ) catch continue;

                const lower = try alloc.alloc(u8, name.len);
                for (lower, name) |*d, s| d.* = std.ascii.toLower(s);

                const key = std.meta.stringToEnum(Key, lower) orelse {
                    std.debug.print(
                        "ffi.rs declares ACTION_{s}, which is not a member of Action.Key\n",
                        .{name},
                    );
                    return error.UnknownActionTag;
                };

                if (@intFromEnum(key) != value) {
                    std.debug.print(
                        "ffi.rs says ACTION_{s} = {d}, but Action.Key.{s} = {d}\n",
                        .{ name, value, lower, @intFromEnum(key) },
                    );
                    // **And say what that number really is.** A wrong tag is
                    // not an absence: it names some other action, and that is
                    // the arm the host would run.
                    inline for (@typeInfo(Key).@"enum".fields) |f| {
                        if (f.value == value) std.debug.print(
                            "  {d} is Action.Key.{s} -- the host would dispatch that instead\n",
                            .{ value, f.name },
                        );
                    }
                    return error.ActionTagMismatch;
                }

                checked += 1;
            }

            // **The one number that says the test did any work.** A pattern
            // that stopped matching would pass every assertion above while
            // reading exactly like a clean run -- which is the failure this
            // whole file's neighbours keep being written to avoid.
            try std.testing.expect(checked >= 40);
        }
        test "the Windows palette hides only what it must" {
            // **The third door.** The two tests above and
            // `windows/tools/menu-actions-handled.py` between them cover the
            // menus: every row reaches an action `cb_action` has a branch for,
            // or is greyed with a written reason. **The command palette is a
            // fourth list of the same actions and none of them can see it**,
            // because its rows are not in the Rust source at all -- they come
            // from `input.command.defaults` at runtime, through
            // `command-palette-entry`, and `palette.rs` only copies them.
            //
            // The gap that left: `defaults` is built at comptime over every
            // member of `Binding.Action` with no platform branch anywhere, so
            // the Windows palette listed `Show the GTK Inspector`. Pressing
            // Enter on it produced `[action] tag=30 is not implemented by this
            // host` and nothing else. `palette.rs`'s `UNAVAILABLE` now hides
            // those rows; this test is what stops that table from being the
            // next thing that rots.
            //
            // **It is here rather than in `windows/tools/`.** A Python gate
            // over `windows/host/src/**` can see `palette.rs` copying the
            // list; it cannot see what is in the list. This side can: the
            // commands are a comptime constant in this binary, and the host's
            // source is a file it can read -- which is exactly the standing
            // this file's other two Windows floors have.
            //
            // # NOT CHECKED, and both halves matter
            //
            //  1. **This sees the comptime `defaults`, not the list the
            //     palette actually receives.** They are equal only while the
            //     user has not set `command-palette-entry` in their config;
            //     `RepeatableCommand.init` copies the whole of `defaults`, and
            //     a config that overrides it diverges from what is checked
            //     here. Nothing on either side reports that divergence.
            //  2. **The binding-to-action map is read out of the dispatch
            //     source as text, not executed.** Going from a palette command
            //     to the `apprt` action it raises is what
            //     `Surface.performBindingAction` and `App.performAction` do,
            //     and those need a live surface. So this parses those two
            //     switches instead. **It is deliberately not a name match**:
            //     `toggle_secure_input` raises `secure_input`, one concept
            //     with two spellings, and a name match would miss exactly that
            //     pair while looking like it covered everything. What text
            //     parsing can still miss is an arm whose shape it does not
            //     recognise -- so the map has a floor, and every row of
            //     `UNAVAILABLE` must be *derivable* from it, which means a
            //     parse that quietly stopped working takes the whole test
            //     down rather than passing.
            //
            // There is a third route these lists do not cover at all, and it
            // is not a palette question: `src/poltergeist/actions.zig`'s
            // `selfSafeTag` lets an agent aim these actions at a terminal
            // directly, with no row of any kind involved.
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();

            const H = struct {
                /// A missing file fails rather than skips, for the reason the
                /// action-tag floor above states.
                fn read(i: std.Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
                    return std.Io.Dir.cwd().readFileAlloc(i, path, a, .limited(512 * 1024)) catch |err| {
                        std.debug.print(
                            "cannot read {s} ({t}). Run `zig build test` from the repository root.\n",
                            .{ path, err },
                        );
                        return error.HostSourceUnreadable;
                    };
                }

                /// The contents of the next `"..."` at or after `from`, and
                /// where it ended. Rust string literals in this table have no
                /// escapes other than `\"` and line continuations, both of
                /// which only matter inside `why` -- which is not compared.
                fn str(src: []const u8, from: usize) ?struct { v: []const u8, end: usize } {
                    const open = std.mem.indexOfScalarPos(u8, src, from, '"') orelse return null;
                    var k = open + 1;
                    while (k < src.len) : (k += 1) {
                        if (src[k] == '\\') {
                            k += 1;
                            continue;
                        }
                        if (src[k] == '"') return .{ .v = src[open + 1 .. k], .end = k + 1 };
                    }
                    return null;
                }

                /// The identifier starting at `at`, if there is one.
                fn ident(src: []const u8, at: usize) ?[]const u8 {
                    var e = at;
                    while (e < src.len and (std.ascii.isAlphanumeric(src[e]) or src[e] == '_')) e += 1;
                    return if (e > at) src[at..e] else null;
                }

                /// The `apprt` action tags a slice of dispatch source asks for.
                ///
                /// `performAction(target, .tag, value)` in either of its two
                /// spellings -- `.app` or `.{ .surface = self }` -- so the
                /// target is skipped by walking to the first comma at the
                /// call's own paren depth rather than by matching its shape.
                fn actionsIn(
                    body: []const u8,
                    out: *std.ArrayList([]const u8),
                    a: std.mem.Allocator,
                ) !void {
                    var i: usize = 0;
                    while (std.mem.indexOfPos(u8, body, i, "performAction(")) |p| {
                        var k = p + "performAction(".len;
                        i = k;
                        var depth: usize = 0;
                        const comma = while (k < body.len) : (k += 1) {
                            switch (body[k]) {
                                '(', '{', '[' => depth += 1,
                                ')', ']' => {
                                    if (depth == 0) break null;
                                    depth -= 1;
                                },
                                '}' => {
                                    if (depth == 0) break null;
                                    depth -= 1;
                                },
                                ',' => if (depth == 0) break k,
                                else => {},
                            }
                        } else null;
                        const c = comma orelse continue;
                        var j = c + 1;
                        while (j < body.len and (body[j] == ' ' or body[j] == '\n' or
                            body[j] == '\t' or body[j] == '\r')) j += 1;
                        if (j >= body.len or body[j] != '.') continue;
                        const name = ident(body, j + 1) orelse continue;
                        try out.append(a, name);
                    }
                }

                /// `field: "value"` inside one `Unavailable { ... }` block.
                fn field(block: []const u8, name: []const u8) ?[]const u8 {
                    var buf: [64]u8 = undefined;
                    const needle = std.fmt.bufPrint(&buf, "{s}: ", .{name}) catch return null;
                    const at = std.mem.indexOf(u8, block, needle) orelse return null;
                    const s2 = str(block, at + needle.len) orelse return null;
                    return s2.v;
                }
            };

            const palette_src = try H.read(io, alloc, "windows/host/src/palette.rs");
            const main_src = try H.read(io, alloc, "windows/host/src/main.rs");

            // **What each palette command actually asks the host for.** Read
            // out of the two functions that decide it, rather than guessed
            // from the command's own name -- see NOT CHECKED 2 above for why
            // that distinction is the point and not pedantry.
            var raises: std.StringHashMapUnmanaged([]const []const u8) = .empty;
            {
                // **One `switch` at a time, brace-walked, rather than the
                // whole function scanned by indentation.** Two bugs came out
                // of the looser version and they are the same bug twice: an
                // "arm" whose body is bounded only by the next thing that
                // looks like an arm runs on past the end of its own switch.
                //
                //   * an argument on its own line inside a call --
                //     `performAction(\n  .app,\n  .open_config,\n ...)` --
                //     read as an arm, swallowing the eight real arms after it;
                //   * the *last* arm of the app-scoped switch nested inside
                //     `performBindingAction`, whose body then ran to the end of
                //     the enclosing function and collected every action the
                //     outer switch raises. That one had `redo` asking the host
                //     for `toggle_window_decorations`.
                //
                // Neither showed up as an error. The first was masked by
                // `getOrPut` keeping whichever pass happened to run first;
                // the second only appeared once the first was fixed. **A
                // correct answer that depends on which of two loops runs
                // first is a defect that has not gone off yet.**
                const Sw = struct {
                    path: []const u8,
                    /// The enclosing function, so the right `switch` is found
                    /// when the header appears more than once in the file.
                    anchor: []const u8,
                    header: []const u8,
                    /// Arms of this switch sit at exactly this indentation.
                    indent: usize,
                };
                const switches = [_]Sw{
                    .{
                        .path = "src/Surface.zig",
                        .anchor = "pub fn performBindingAction",
                        .header = "switch (app_action) {",
                        .indent = 12,
                    },
                    .{
                        .path = "src/Surface.zig",
                        .anchor = "pub fn performBindingAction",
                        .header = "switch (action.scoped(.surface).?) {",
                        .indent = 8,
                    },
                    .{
                        .path = "src/App.zig",
                        .anchor = "pub fn performAction(\n    self: *App,",
                        .header = "switch (action) {",
                        .indent = 8,
                    },
                };
                for (switches) |sw| {
                    const src = try H.read(io, alloc, sw.path);
                    const at = std.mem.indexOf(u8, src, sw.anchor) orelse {
                        std.debug.print("{s} no longer contains `{s}`\n", .{ sw.path, sw.anchor });
                        return error.DispatchAnchorGone;
                    };
                    const hdr = std.mem.indexOfPos(u8, src, at, sw.header) orelse {
                        std.debug.print(
                            "{s}: `{s}` no longer contains `{s}`\n",
                            .{ sw.path, sw.anchor, sw.header },
                        );
                        return error.DispatchSwitchGone;
                    };
                    const open = std.mem.indexOfScalarPos(u8, src, hdr, '{') orelse return error.DispatchSwitchGone;
                    var depth: usize = 0;
                    var k = open;
                    const close = while (k < src.len) : (k += 1) {
                        if (src[k] == '{') depth += 1;
                        if (src[k] == '}') {
                            depth -= 1;
                            if (depth == 0) break k;
                        }
                    } else src.len;
                    const body = src[open..close];

                    // Arm starts: a `.name` at exactly this indent and at
                    // paren depth zero, so an argument on its own line inside
                    // a call is not one.
                    var marker_buf: [24]u8 = undefined;
                    marker_buf[0] = '\n';
                    for (marker_buf[1 .. sw.indent + 1]) |*c| c.* = ' ';
                    marker_buf[sw.indent + 1] = '.';
                    const marker = marker_buf[0 .. sw.indent + 2];

                    var starts: std.ArrayList(usize) = .empty;
                    var names: std.ArrayList([]const u8) = .empty;
                    var paren: isize = 0;
                    var c: usize = 0;
                    while (c < body.len) : (c += 1) {
                        switch (body[c]) {
                            '(' => paren += 1,
                            ')' => paren -= 1,
                            '.' => {
                                if (paren != 0) continue;
                                if (c + 1 < marker.len) continue;
                                if (!std.mem.eql(u8, body[c + 1 - marker.len .. c + 1], marker)) continue;
                                const name = H.ident(body, c + 1) orelse continue;
                                try starts.append(alloc, c + 1 - marker.len);
                                try names.append(alloc, name);
                            },
                            else => {},
                        }
                    }
                    for (starts.items, names.items, 0..) |p, name, n| {
                        // **Bounded by this switch**, because `body` is this
                        // switch and nothing else. The last arm ends at its
                        // closing brace, not at the end of the file.
                        const next = if (n + 1 < starts.items.len) starts.items[n + 1] else body.len;
                        var found: std.ArrayList([]const u8) = .empty;
                        try H.actionsIn(body[p..next], &found, alloc);
                        if (found.items.len == 0) continue;
                        const gop = try raises.getOrPut(alloc, name);
                        if (!gop.found_existing) gop.value_ptr.* = try found.toOwnedSlice(alloc);
                    }
                }
            }
            // **The floor for that parse.** A marker that stopped matching
            // would leave this map empty, every check below would find nothing
            // to complain about, and the run would read as clean.
            try std.testing.expect(raises.count() >= 40);

            // Which `ACTION_*` the host **performs**, which it **refuses by
            // name**, and which it says it **owes**.
            //
            // **"Has an arm" is not the question, and getting that wrong was
            // this test's own first bug.** Arms exist precisely in order to
            // refuse by name -- `[action] show_gtk_inspector: this host is not
            // GTK` rather than `tag=30 is not implemented` -- and the first
            // version of this check counted them as implemented, then told the
            // palette to un-hide `Show the GTK Inspector` because "cb_action
            // handles it now". A finding made of real symbols with the
            // relation read backwards.
            //
            // **Two markers, not one, and the difference is load-bearing.**
            //
            //   `// refuses:` this platform has no such thing. Permanent.
            //   `// owed:`    not built yet, and the task number says by whom.
            //
            // Collapsing them would register work-not-done as
            // work-not-wanted, which is the reading that makes a deferred
            // decision look like an oversight and an oversight look decided.
            // Both mean "not performed"; only the sentence differs, and the
            // sentence is the whole point.
            //
            // **A comment mentioning `ACTION_X` is not an arm.** That is not a
            // hypothetical: two lines of prose here saying "`ACTION_INSPECTOR`
            // above has answered this way" put `inspector` into the performed
            // set, and this test therefore stopped reporting that the
            // palette's `Toggle Inspector` row reaches an action the host
            // refuses. A gate that reads source as text has to know which of
            // it is source.
            var performed: std.StringHashMapUnmanaged(void) = .empty;
            var marked: std.StringHashMapUnmanaged(void) = .empty;
            var refused: usize = 0;
            var owed: usize = 0;
            var commented_out: usize = 0;
            {
                const at = std.mem.indexOf(u8, main_src, "extern \"C\" fn cb_action") orelse
                    return error.NoCbAction;
                const stop = std.mem.indexOfPos(u8, main_src, at, "\n}\n") orelse main_src.len;
                var line_start = at;
                var prev_marker: enum { none, refuses, owed } = .none;
                while (line_start < stop) {
                    const nl = std.mem.indexOfScalarPos(u8, main_src, line_start, '\n') orelse stop;
                    const line = main_src[line_start..@min(nl, stop)];
                    const t = std.mem.trim(u8, line, " \t\r");

                    if (std.mem.startsWith(u8, t, "//")) {
                        if (std.mem.startsWith(u8, t, "// refuses:")) {
                            prev_marker = .refuses;
                        } else if (std.mem.startsWith(u8, t, "// owed:")) {
                            // **A task number, not the word alone.** "owed"
                            // with nobody named is an adjective: in six months
                            // nothing says who it is owed to, and the entry
                            // becomes permanent by default.
                            var has_number = false;
                            for (t) |c| {
                                if (std.ascii.isDigit(c)) {
                                    has_number = true;
                                    break;
                                }
                            }
                            if (!has_number) {
                                std.debug.print(
                                    "an `// owed:` marker names no task: {s}\n",
                                    .{t},
                                );
                                return error.OwedMarkerHasNoTask;
                            }
                            prev_marker = .owed;
                        } else {
                            // Prose. It may well name `ACTION_*`; that is what
                            // this branch exists to stop counting.
                            if (std.mem.indexOf(u8, t, "ACTION_") != null) commented_out += 1;
                            prev_marker = .none;
                        }
                        line_start = nl + 1;
                        continue;
                    }

                    var found = false;
                    var i = line_start;
                    while (std.mem.indexOfPos(u8, main_src, i, "ACTION_")) |p| {
                        if (p >= @min(nl, stop)) break;
                        var e = p + "ACTION_".len;
                        while (e < main_src.len and (std.ascii.isUpper(main_src[e]) or
                            std.ascii.isDigit(main_src[e]) or main_src[e] == '_')) e += 1;
                        const upper = main_src[p + "ACTION_".len .. e];
                        i = e;
                        found = true;
                        const lower = try alloc.alloc(u8, upper.len);
                        for (lower, upper) |*d, c| d.* = std.ascii.toLower(c);
                        switch (prev_marker) {
                            .none => try performed.put(alloc, lower, {}),
                            .refuses => {
                                refused += 1;
                                try marked.put(alloc, lower, {});
                            },
                            .owed => {
                                owed += 1;
                                try marked.put(alloc, lower, {});
                            },
                        }
                    }
                    if (found or t.len > 0) prev_marker = .none;
                    line_start = nl + 1;
                }
            }
            // **The floors, and one of them used to be a number somebody had
            // to maintain.**
            //
            // `refused >= 7` and `owed >= 4` were exactly that, and the count
            // collided four times in one round: two people each raised the
            // same floor from the value they had, and the merged answer was
            // neither. **A floor whose number moves every time the work moves
            // is a merge conflict wearing a check's clothes**, and worse, the
            // value it lands on after a bad merge is still green.
            //
            // So the floor asks the question it was always for -- *is the
            // marker still being recognised?* -- against a reading that does
            // not depend on the walk above: the raw text is searched for the
            // marker, and the two counts must agree. Nobody maintains a
            // number, and a walk that stopped matching fails immediately
            // because the raw count did not.
            {
                const cb_at = std.mem.indexOf(u8, main_src, "extern \"C\" fn cb_action").?;
                const cb_stop = std.mem.indexOfPos(u8, main_src, cb_at, "\n}\n") orelse main_src.len;
                const arms_src = main_src[cb_at..cb_stop];
                const raw_refuses = std.mem.count(u8, arms_src, "// refuses:");
                const raw_owed = std.mem.count(u8, arms_src, "// owed:");
                if (refused != raw_refuses or owed != raw_owed) {
                    std.debug.print(
                        "the marker walk and the raw text disagree: walk found {d} " ++
                            "`// refuses:` and {d} `// owed:`, the text has {d} and {d}. " ++
                            "A marker that is written but not recognised turns a refusal " ++
                            "into an implementation, and this test then asks the palette to " ++
                            "un-hide something it must not.\n",
                        .{ refused, owed, raw_refuses, raw_owed },
                    );
                    return error.MarkerWalkDisagreesWithSource;
                }
                // Both kinds must actually exist, or the agreement above is
                // 0 == 0 and proves nothing about either.
                try std.testing.expect(raw_refuses >= 1);
                try std.testing.expect(raw_owed >= 1);
            }
            // **The comment skip's floor is one line, not a tally.** The real
            // check on it is the `inspector` control below; this only makes
            // sure that control is not vacuous -- with no prose naming an
            // `ACTION_` anywhere, a broken skip would have nothing to trip on.
            try std.testing.expect(commented_out >= 1);
            try std.testing.expect(performed.count() >= 55);

            // **The positive control for the comment skip, and it is a real
            // one.** `inspector` is refused by name *and* named in two lines of
            // prose in the same function. If the skip regresses, the prose
            // wins and this fails -- which is what happened before the skip
            // existed, silently.
            if (performed.contains("inspector")) {
                std.debug.print(
                    "`inspector` is refused by name, but this test read it as performed. " ++
                        "It is mentioned in prose inside `cb_action`; the comment skip above " ++
                        "has stopped working, and every refusal named in a comment is now " ++
                        "being counted as an implementation.\n",
                    .{},
                );
                return error.CommentCountedAsArm;
            }

            // The `UNAVAILABLE` table, as written.
            const table_at = std.mem.indexOf(u8, palette_src, "const UNAVAILABLE: &[Unavailable] = &[") orelse
                return error.NoUnavailableTable;
            const table_end = std.mem.indexOfPos(u8, palette_src, table_at, "\n];") orelse palette_src.len;
            const table = palette_src[table_at..table_end];

            var listed: std.StringHashMapUnmanaged(void) = .empty;
            var rows: usize = 0;
            var i: usize = 0;
            while (std.mem.indexOfPos(u8, table, i, "Unavailable {")) |p| {
                const e = std.mem.indexOfPos(u8, table, p, "\n    },") orelse table.len;
                const block = table[p..e];
                i = e + 1;
                rows += 1;

                const key = H.field(block, "key") orelse {
                    std.debug.print("an `Unavailable` row has no `key`\n", .{});
                    return error.UnavailableRowMalformed;
                };
                const blocked = H.field(block, "blocked_on") orelse {
                    std.debug.print("`Unavailable` row {s} has no `blocked_on`\n", .{key});
                    return error.UnavailableRowMalformed;
                };
                // **A reason is required and not merely conventional.** The
                // row is hidden from the palette, so this sentence is the only
                // thing left that answers "where did it go".
                const why = H.field(block, "why") orelse {
                    std.debug.print("`Unavailable` row {s} has no `why`\n", .{key});
                    return error.UnavailableRowMalformed;
                };
                if (why.len < 20) {
                    std.debug.print("`Unavailable` row {s} has a `why` of {d} characters\n", .{ key, why.len });
                    return error.UnavailableReasonTooShort;
                }

                // The key names a real binding action, or it hides nothing and
                // will go on hiding nothing silently.
                if (std.meta.stringToEnum(std.meta.Tag(input.Binding.Action), key) == null) {
                    std.debug.print(
                        "palette.rs hides `{s}`, which is not a member of Binding.Action\n",
                        .{key},
                    );
                    return error.UnavailableKeyUnknown;
                }

                // ...and the core actually publishes a palette command for it.
                var published = false;
                for (input.command.defaults) |cmd| {
                    if (std.mem.eql(u8, @tagName(cmd.action), key)) {
                        published = true;
                        break;
                    }
                }
                if (!published) {
                    std.debug.print(
                        "palette.rs hides `{s}`, but the core publishes no palette command for " ++
                            "it -- the row hides nothing and can go\n",
                        .{key},
                    );
                    return error.UnavailableKeyNotInPalette;
                }

                if (std.meta.stringToEnum(Key, blocked) == null) {
                    std.debug.print(
                        "palette.rs says `{s}` is blocked on `{s}`, which is not a member of " ++
                            "Action.Key\n",
                        .{ key, blocked },
                    );
                    return error.UnavailableBlockerUnknown;
                }

                // **The hand-written `blocked_on`, checked against the
                // source that decides it.** This is the field the stale
                // alarm below rests on; if it is wrong, that alarm watches
                // the wrong action and nothing ever says so. It is also what
                // makes a broken parse fatal rather than quiet: a map that
                // stopped resolving this row fails here.
                const asks = raises.get(key) orelse {
                    std.debug.print(
                        "palette.rs hides `{s}`, but neither `performBindingAction` nor " ++
                            "`App.performAction` was read as asking the host for anything -- " ++
                            "either the row names a binding that dispatches nowhere, or this " ++
                            "test's reading of those two switches has stopped working.\n",
                        .{key},
                    );
                    return error.BindingRaisesNothing;
                };
                var agrees = false;
                for (asks) |a2| {
                    if (std.mem.eql(u8, a2, blocked)) agrees = true;
                }
                if (!agrees) {
                    std.debug.print(
                        "palette.rs says `{s}` is blocked on `{s}`, but the core dispatches " ++
                            "that binding to: ",
                        .{ key, blocked },
                    );
                    for (asks) |a2| std.debug.print("`{s}` ", .{a2});
                    std.debug.print(
                        "\n  The `blocked_on` field is what the staleness check watches, so a " ++
                            "wrong one means that check is watching the wrong action.\n",
                        .{},
                    );
                    return error.UnavailableBlockerWrong;
                }

                // **The stale direction -- and it runs after the check above
                // on purpose**: it watches `blocked_on`, so it is only worth
                // anything once that field has been agreed with the source that
                // decides it. The reason this table is safe to
                // keep.** The day `cb_action` grows the arm, this row starts
                // hiding a command that works -- silently, forever, unless
                // something says so here.
                if (performed.contains(blocked)) {
                    std.debug.print(
                        "palette.rs hides `{s}` because `{s}` was not implemented, but " ++
                            "`cb_action` handles `{s}` now. Delete that `Unavailable` row: it " ++
                            "is hiding a command this host can perform.\n",
                        .{ key, blocked, blocked },
                    );
                    return error.UnavailableRowStale;
                }

                try listed.put(alloc, key, {});
            }
            // The table has content and it was parsed. Zero rows and a table
            // this test could not read are the same reading otherwise.
            try std.testing.expect(rows >= 5);
            try std.testing.expectEqual(rows, listed.count());

            // **Every action is answered, one way or another.**
            //
            // This is the relation the two tables hang off, and it is stated
            // once here rather than implied by four separate checks: *an
            // action this host does not perform must say so by name.* Before
            // it, eleven actions were answered by `_ =>` with `tag=NN` -- and
            // from that line nobody can tell "this platform has no such thing"
            // from "nobody has built it yet", which are the two answers a
            // person filing a bug needs told apart.
            //
            // **It also makes the published capability count machine-read
            // rather than subtracted.** Three numbers -- performed, refused,
            // owed -- and the third was, until this, whatever was left over.
            // The number that came out of that subtraction was wrong for a
            // round without anything noticing.
            //
            // `_ =>` keeps its job: an action the *core* has grown that this
            // tree has never seen. That is the only thing it should ever
            // catch.
            {
                var missing: usize = 0;
                const fields = @typeInfo(Key).@"enum".fields;
                comptime var fi: usize = 0;
                inline while (fi < fields.len) : (fi += 1) {
                    const f = fields[fi];
                    if (!performed.contains(f.name) and !marked.contains(f.name)) {
                        std.debug.print(
                            "`cb_action` neither performs `{s}` nor answers it by name: it " ++
                                "falls through to `_ =>` and logs `tag={d}`. Give it an arm " ++
                                "with `// refuses: <why>` (this platform has no such thing) " ++
                                "or `// owed: <task> <why>` (not built yet).\n",
                            .{ f.name, f.value },
                        );
                        missing += 1;
                    }
                }
                if (missing > 0) return error.ActionAnsweredByNothing;
            }

            // **The open-door direction, down the same chain the action
            // itself travels.** Not "the command's name is an unhandled
            // `Action.Key`" -- that is the reading that would walk straight
            // past `toggle_secure_input`.
            for (input.command.defaults) |cmd| {
                const name = @tagName(cmd.action);
                const asks = raises.get(name) orelse continue;
                for (asks) |a3| {
                    if (std.meta.stringToEnum(Key, a3) == null) continue;
                    if (performed.contains(a3)) continue;
                    if (listed.contains(name)) continue;
                    // **Two different sentences, because they are two
                    // different bugs.** An action with no arm at all leaves a
                    // bare tag number; one that is refused or owed by name
                    // answers properly and the palette row is still a promise
                    // it cannot keep. The second is the one that hid here for
                    // a whole round: `inspector` had a named refusal, so
                    // everything looked handled from the log's side.
                    if (marked.contains(a3)) {
                        std.debug.print(
                            "the palette publishes `{s}`, which asks the host for `{s}`. " ++
                                "`cb_action` answers that by name -- it refuses or owes it -- " ++
                                "so the log looks healthy, and the palette row is still a row " ++
                                "that cannot do anything. Add `{s}` to `palette.rs`'s " ++
                                "UNAVAILABLE.\n",
                            .{ name, a3, name },
                        );
                    } else {
                        std.debug.print(
                            "the palette publishes `{s}`, which asks the host for `{s}`; " ++
                                "`cb_action` has no branch for that at all, so pressing Enter " ++
                                "on that row logs a bare tag number. Give it an arm (`// refuses:` " ++
                                "or `// owed: <task>`) and add `{s}` to `palette.rs`'s " ++
                                "UNAVAILABLE.\n",
                            .{ name, a3, name },
                        );
                    }
                    return error.PaletteOffersWhatTheHostCannotDo;
                }
            }
        }

        test "the Windows host's accelerator table" {
            // **The floor for `windows/host/src/keys.rs`'s `accelerator`.**
            // That table fires only for keys the core declined, so a row whose
            // chord the core binds is normally dead -- and "normally" is the
            // whole problem. A `performable` binding declines whenever its
            // action cannot be performed right now (`Config.zig` on
            // `performable`: "If there is no selection, Ghostty behaves as if
            // the keybind was not set"), and then the host's row runs instead.
            // That is how `ctrl+shift+c` with no selection came to put the
            // window *title* on the clipboard while the person was looking at
            // the text they had just selected.
            //
            // So the rule the table now follows is: **a chord the core binds
            // on Windows does not appear here, even when both name the same
            // action.** Agreeing today is a coincidence; the core changes one
            // default and a harmless dead row becomes that clipboard bug, and
            // until this test existed nothing anywhere reported the change.
            //
            // **Why this reads the file instead of building the real bind
            // set -- and the limit is this machine, not the technique.**
            // `Config.default()` takes no target and the platform branches are
            // `comptime builtin.target.os.tag.isDarwin()`, so a test compiled
            // *for this host* gets the macOS defaults: `super` chords that can
            // never collide with the host table's `ctrl+shift` rows. It would
            // pass unconditionally, including on the collision it exists to
            // catch.
            //
            // **Cross-compiled for Windows and run on the machine, it would
            // get the real thing** -- that is an existing pipeline here, not a
            // hypothetical: the Windows test executable is built and run every
            // round. When this test can go that way, the text parsing below
            // should be deleted outright and replaced by a query against the
            // real bind set, which cannot drift from the source because it *is*
            // the source. "Cannot be done" and "cannot be done on the machine
            // that happens to run `zig build test` today" are different
            // sentences, and only the second one is true.
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();

            const H = struct {
                const Chord = struct {
                    physical: bool,
                    key: []const u8,
                    ctrl: bool,
                    shift: bool,
                };

                /// Read a file or fail. **Not a skip**: a skip would let this
                /// floor quietly stop existing the first time the suite ran
                /// from another directory, and nothing would say so.
                fn read(io_: std.Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
                    return std.Io.Dir.cwd().readFileAlloc(
                        io_,
                        path,
                        a,
                        .limited(2 * 1024 * 1024),
                    ) catch |err| {
                        std.debug.print(
                            "cannot read {s} ({t}). Run `zig build test` from the repository root.\n",
                            .{ path, err },
                        );
                        return error.SourceUnreadable;
                    };
                }

                fn trim(s: []const u8) []const u8 {
                    return std.mem.trim(u8, s, " \t\r\n'");
                }
            };

            const cfg = try H.read(io, alloc, "src/config/Config.zig");
            const keys_rs = try H.read(io, alloc, "windows/host/src/keys.rs");

            // ---- the `mods` local, whose non-Darwin arm is what ships here.
            // `.{ .key = ... , .mods = mods }` is one of the three spellings,
            // and the one the clipboard binding uses.
            const mods_decl = std.mem.indexOf(u8, cfg, "const mods: inputpkg.Mods = if (builtin.target.os.tag.isDarwin())") orelse
                return error.ModsLocalNotFound;
            const after_else = std.mem.indexOfPos(u8, cfg, mods_decl, "else") orelse
                return error.ModsLocalNotFound;
            const mods_var_windows = cfg[after_else..@min(after_else + 80, cfg.len)];
            // **The window is cut on a `}` that has to be inside it.** If the
            // `else` arm is ever written longer than this, the brace falls
            // outside, every trigger using the `mods` local fails to parse and
            // the set quietly loses a batch -- including `ctrl+shift+c`, the
            // one this whole floor exists for.
            try std.testing.expect(std.mem.indexOf(u8, mods_var_windows, "}") != null);

            // ---- every default chord, evaluated for Windows.
            var chords: [512]H.Chord = undefined;
            var n_chords: usize = 0;
            var unparsed: usize = 0;
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, cfg, pos, ".key = .{ .")) |at| {
                pos = at + 11;
                const kind_end = std.mem.indexOfPos(u8, cfg, pos, " = ") orelse break;
                const kind = cfg[pos..kind_end];
                const val_end = std.mem.indexOfPos(u8, cfg, kind_end, "}") orelse break;
                const key = H.trim(cfg[kind_end + 3 .. val_end]);

                // **A trigger with no `.mods` is a chord with no modifiers,
                // not a trigger to skip.** The first version `continue`d here,
                // which dropped seven of them (`.copy`, `.paste`, `.escape`,
                // the `digit_N` run, `'n'`) without a word -- the same shape as
                // the regex in the scratch script that could not match a key
                // whose value *was* a comma, and reported a clean table.
                //
                // It was not only theoretical: `keys.rs` carried
                // `(_, _, VK_F11) => toggle_fullscreen` with both modifiers
                // false, and deciding whether the core already covered that
                // row needs exactly the triggers this used to drop.
                //
                // The window is still needed: `indexOfPos` finds the *next*
                // `.mods` anywhere in the file, so without a bound a trigger
                // that has none would borrow the next trigger's modifiers.
                var ctrl = false;
                var shift = false;
                if (std.mem.indexOfPos(u8, cfg, val_end, ".mods = ")) |mods_at| skip: {
                    if (mods_at > val_end + 40) break :skip; // this trigger has none
                    const mods_txt = cfg[mods_at + 8 .. @min(mods_at + 8 + 120, cfg.len)];

                    // The three spellings, and `ctrlOrSuper` is the one that
                    // has to be read as *ctrl* here rather than as super.
                    const ctrl_or_super = std.mem.startsWith(u8, mods_txt, "inputpkg.ctrlOrSuper(");
                    const is_var = !ctrl_or_super and !std.mem.startsWith(u8, mods_txt, ".{");
                    const effective = if (is_var) mods_var_windows else mods_txt;
                    // **Loud, not skipped.** Reaching here means the mods
                    // expression did not close inside the window, which is a
                    // parse this code does not understand -- and an
                    // unparsed trigger has to be a failure rather than one
                    // fewer chord in a set everything else is checked against.
                    const brace_end = std.mem.indexOf(u8, effective, "}") orelse {
                        unparsed += 1;
                        break :skip;
                    };
                    const m = effective[0..brace_end];

                    ctrl = std.mem.indexOf(u8, m, ".ctrl = true") != null or ctrl_or_super;
                    shift = std.mem.indexOf(u8, m, ".shift = true") != null;
                    // A `super`-only chord is the macOS arm and does not ship
                    // here. **A deliberate exclusion, and the `=` anchor below
                    // is what proves it still happens.**
                    if (std.mem.indexOf(u8, m, ".super = true") != null and !ctrl_or_super) continue;
                }

                if (n_chords == chords.len) return error.TooManyChords;
                chords[n_chords] = .{
                    .physical = std.mem.eql(u8, kind, "physical"),
                    .key = key,
                    .ctrl = ctrl,
                    .shift = shift,
                };
                n_chords += 1;
            }

            const bound = struct {
                fn f(list: []const H.Chord, physical: bool, key: []const u8, ctrl: bool, shift: bool) bool {
                    for (list) |c| {
                        if (c.physical == physical and
                            c.ctrl == ctrl and
                            c.shift == shift and
                            std.mem.eql(u8, std.mem.trimStart(u8, c.key, "."), key)) return true;
                    }
                    return false;
                }
            }.f;
            const found = chords[0..n_chords];

            // ---- **Anchors, inside the test rather than beside it.**
            //
            // The first version of this check, written in a scratch script,
            // reported "every surviving row is clean" -- and was wrong,
            // because its parser silently missed two of the three `mods`
            // spellings. What caught it was one hand-verified fact asserted
            // against the parser itself. Without these three lines this test
            // can go blind and stay green, which is the failure it is here to
            // prevent in someone else's code.
            //
            // One anchor per spelling:
            try std.testing.expect(bound(found, false, "t", true, true)); //  inline `.{ .ctrl, .shift }`
            try std.testing.expect(bound(found, false, "c", true, true)); //  the `mods` local
            try std.testing.expect(bound(found, false, "p", true, true)); //  `inputpkg.ctrlOrSuper(...)`

            // **The fourth anchor is the miss that actually happened.**
            // `ctrl+tab` -> `next_tab` (`.physical = .tab` with `.ctrl` alone)
            // was missed by the first enumeration written tonight, and on the
            // strength of that miss a host row was about to be kept as "not
            // verified" with a keypress requested on a real machine -- for an
            // answer that was in this file all along. It pins the physical-key
            // spelling and the ctrl-without-shift case at once.
            try std.testing.expect(bound(found, true, "tab", true, false));

            // **And one for the class that used to be dropped entirely.**
            // `escape` is bound with no modifiers at all; before the fix above
            // it and six others never entered the set, so any host row with
            // both modifiers false was being checked against a table that
            // could not contain its answer.
            try std.testing.expect(bound(found, true, "escape", false, false));

            // And the discrimination in the other direction: `equalize_splits`
            // is bound `super+ctrl+=`, a macOS-only chord, which is exactly
            // why `ctrl+shift+=` survives in the host table. A parser that
            // read `super` chords as shipping here would delete that row.
            try std.testing.expect(!bound(found, false, "=", true, true));

            // A parse that produced nothing would satisfy every "not bound"
            // assertion below. The one number that says work happened.
            // **The bound is deliberately loose, and the anchors above are
            // the real check.** A second parser of this same file, written
            // independently earlier tonight, keeps 55 where this one keeps 57:
            // the two draw the boundary differently around triggers carrying
            // no `.mods` at all. Neither number is load-bearing, and asserting
            // either would turn an irrelevant disagreement into a failure.
            // What has to hold is that specific known chords are found, which
            // is what the anchors above say.
            try std.testing.expect(n_chords >= 50);

            // **Nothing was skipped for a reason this code does not
            // understand.** The `super` arm is excluded on purpose and counted
            // nowhere; this counts only triggers whose modifiers could not be
            // read at all, and one of those is a hole in the set that every
            // "not bound" answer below is drawn from.
            try std.testing.expectEqual(@as(usize, 0), unparsed);

            // ---- the host's rows
            const Row = struct { vk: []const u8, physical: bool, key: []const u8 };
            const vks = [_]Row{
                .{ .vk = "VK_T", .physical = false, .key = "t" },
                .{ .vk = "VK_W", .physical = false, .key = "w" },
                .{ .vk = "VK_C", .physical = false, .key = "c" },
                .{ .vk = "VK_D", .physical = false, .key = "d" },
                .{ .vk = "VK_E", .physical = false, .key = "e" },
                .{ .vk = "VK_M", .physical = false, .key = "m" },
                .{ .vk = "VK_P", .physical = false, .key = "p" },
                .{ .vk = "VK_Z", .physical = false, .key = "z" },
                // Added for the two temporary project chords (task 549). The
                // point of adding them is not to silence this test -- it is
                // that until they were here, **nothing checked whether the
                // core already binds `ctrl+shift+u` or `ctrl+shift+r`**, and
                // the host would have lost that chord to the core without a
                // word. They go out with the chords.
                .{ .vk = "VK_U", .physical = false, .key = "u" },
                .{ .vk = "VK_R", .physical = false, .key = "r" },
                .{ .vk = "VK_OEM_COMMA", .physical = false, .key = "," },
                .{ .vk = "VK_OEM_PLUS", .physical = false, .key = "=" },
                .{ .vk = "VK_TAB", .physical = true, .key = "tab" },
                .{ .vk = "VK_LEFT", .physical = true, .key = "arrow_left" },
                .{ .vk = "VK_RIGHT", .physical = true, .key = "arrow_right" },
                .{ .vk = "VK_UP", .physical = true, .key = "arrow_up" },
                .{ .vk = "VK_DOWN", .physical = true, .key = "arrow_down" },
            };

            const table_at = std.mem.indexOf(u8, keys_rs, "fn accelerator(") orelse
                return error.AcceleratorTableNotFound;
            const table_end = std.mem.indexOfPos(u8, keys_rs, table_at, "\n}\n") orelse keys_rs.len;
            const table = keys_rs[table_at..table_end];

            // **`vks` is a second table that has to stay in step with
            // `accelerator()`, and nothing was keeping it there.** The loop
            // below `continue`s past an arm whose VK it does not know, so a
            // new row -- `(true, true, VK_B) => ...` -- would be waved through
            // and `rows >= 3` would still hold. Counting the arms and
            // requiring every one of them to have been checked is what turns
            // "I looked at every row" from a claim into an assertion. It is
            // the other half of what the neighbouring test says about the
            // host's tags: the claim is that every row *stated* is right.
            var arms: usize = 0;
            var rows: usize = 0;
            var rp: usize = 0;
            while (std.mem.indexOfPos(u8, table, rp, "=> Some(\"")) |hit| {
                const line_start = std.mem.lastIndexOfScalar(u8, table[0..hit], '(') orelse break;
                _ = line_start;
                // Walk back to the start of the match arm's tuple.
                var s = hit;
                while (s > 0 and table[s] != '\n') s -= 1;
                const arm = std.mem.trim(u8, table[s..hit], " \t\r\n");
                rp = hit + 9;
                const act_end = std.mem.indexOfPos(u8, table, rp, "\"") orelse break;
                const action = table[rp..act_end];

                arms += 1;
                var matched = false;
                if (!std.mem.startsWith(u8, arm, "(")) {
                    std.debug.print("unrecognised accelerator arm: {s}\n", .{arm});
                    continue;
                }
                const ctrl = std.mem.indexOf(u8, arm, "(true,") != null;
                const rest = arm[std.mem.indexOfScalar(u8, arm, ',').? + 1 ..];
                const shift = std.mem.startsWith(u8, std.mem.trimStart(u8, rest, " "), "true");

                for (vks) |r| {
                    if (std.mem.indexOf(u8, arm, r.vk) == null) continue;
                    // `VK_T` is a prefix of `VK_TAB`; require the boundary.
                    const at2 = std.mem.indexOf(u8, arm, r.vk).?;
                    const after = at2 + r.vk.len;
                    if (after < arm.len and (std.ascii.isAlphanumeric(arm[after]) or arm[after] == '_')) continue;

                    rows += 1;
                    matched = true;
                    if (bound(found, r.physical, r.key, ctrl, shift)) {
                        std.debug.print(
                            "keys.rs still has {s} -> \"{s}\", but the core binds that chord on Windows.\n" ++
                                "  A `performable` core binding declines when its action cannot be performed,\n" ++
                                "  and then this row runs instead -- doing whatever it names, not what the\n" ++
                                "  user pressed for. Delete the row; the core covers the chord.\n",
                            .{ r.vk, action },
                        );
                        return error.AcceleratorShadowsCoreBinding;
                    }
                    break;
                }
                if (!matched) std.debug.print(
                    "accelerator arm {s} -> \"{s}\" names a virtual key this test does not know;\n" ++
                        "  add it to `vks` -- until then nothing checks whether the core binds that chord.\n",
                    .{ arm, action },
                );
            }

            // The table is small and shrinking; if it parses to nothing this
            // test proves nothing.
            try std.testing.expect(rows >= 3);
            // And every arm in it was one of the rows checked above.
            try std.testing.expectEqual(arms, rows);
        }
    };

    /// Sync with: ghostty_action_u
    pub const CValue = cvalue: {
        const key_fields = @typeInfo(Key).@"enum".fields;
        var names: [key_fields.len][]const u8 = undefined;
        var types: [key_fields.len]type = undefined;
        var attrs: [key_fields.len]std.builtin.Type.UnionField.Attributes = undefined;

        for (key_fields, &names, &types, &attrs) |field, *name, *ty, *attr| {
            const action = @unionInit(Action, field.name, undefined);
            const Type = t: {
                const Type = @TypeOf(@field(action, field.name));
                // Types can provide custom types for their CValue.
                if (Type != void and @hasDecl(Type, "C")) break :t Type.C;
                break :t Type;
            };

            name.* = field.name;
            ty.* = Type;
            attr.* = .{ .@"align" = @alignOf(Type) };
        }

        break :cvalue @Union(.@"extern", null, &names, &types, &attrs);
    };

    /// Sync with: ghostty_action_s
    pub const C = extern struct {
        key: Key,
        value: CValue,
    };

    comptime {
        // For ABI compatibility, we expect that this is our union size.
        // At the time of writing, we don't promise ABI compatibility
        // so we can change this but I want to be aware of it.
        assert(@sizeOf(CValue) == switch (@sizeOf(usize)) {
            4 => 24,
            8 => 24,
            else => unreachable,
        });
    }

    /// Returns the value type for the given key.
    pub fn Value(comptime key: Key) type {
        inline for (@typeInfo(Action).@"union".fields) |field| {
            const field_key = @field(Key, field.name);
            if (field_key == key) return field.type;
        }

        unreachable;
    }

    /// Convert to ghostty_action_s.
    pub fn cval(self: Action) C {
        const value: CValue = switch (self) {
            inline else => |v, tag| @unionInit(
                CValue,
                @tagName(tag),
                if (@TypeOf(v) != void and @hasDecl(@TypeOf(v), "cval")) v.cval() else v,
            ),
        };

        return .{
            .key = @as(Key, self),
            .value = value,
        };
    }
};

// This is made extern (c_int) to make interop easier with our embedded
// runtime. The small size cost doesn't make a difference in our union.
pub const SplitDirection = enum(c_int) {
    right,
    down,
    left,
    up,

    test "ghostty.h SplitDirection" {
        try lib.checkGhosttyHEnum(SplitDirection, "GHOSTTY_SPLIT_DIRECTION_");
    }
};

// This is made extern (c_int) to make interop easier with our embedded
// runtime. The small size cost doesn't make a difference in our union.
pub const GotoSplit = enum(c_int) {
    previous,
    next,

    up,
    left,
    down,
    right,

    test "ghostty.h GotoSplit" {
        try lib.checkGhosttyHEnum(GotoSplit, "GHOSTTY_GOTO_SPLIT_");
    }
};

// This is made extern (c_int) to make interop easier with our embedded
// runtime. The small size cost doesn't make a difference in our union.
pub const GotoWindow = enum(c_int) {
    previous,
    next,

    test "ghostty.h GotoWindow" {
        try lib.checkGhosttyHEnum(GotoWindow, "GHOSTTY_GOTO_WINDOW_");
    }
};

/// The amount to resize the split by and the direction to resize it in.
pub const ResizeSplit = extern struct {
    amount: u16,
    direction: Direction,

    pub const Direction = enum(c_int) {
        up,
        down,
        left,
        right,

        test "ghostty.h ResizeSplit.Direction" {
            try lib.checkGhosttyHEnum(Direction, "GHOSTTY_RESIZE_SPLIT_");
        }
    };
};

pub const MoveTab = extern struct {
    amount: isize,
};

/// The tab to jump to. This is non-exhaustive so that integer values represent
/// the index (zero-based) of the tab to jump to. Negative values are special
/// values.
pub const GotoTab = enum(c_int) {
    previous = -1,
    next = -2,
    last = -3,
    _,

    // TODO: check non-exhaustive enums
    // test "ghostty.h GotoTab" {
    //     try lib.checkGhosttyHEnum(GotoTab, "GHOSTTY_GOTO_TAB_");
    // }
};

/// The fullscreen mode to toggle to if we're moving to fullscreen.
pub const Fullscreen = enum(c_int) {
    native,

    /// macOS has a non-native fullscreen mode that is more like a maximized
    /// window. This is much faster to enter and exit than the native mode.
    macos_non_native,
    macos_non_native_visible_menu,
    macos_non_native_padded_notch,

    test "ghostty.h Fullscreen" {
        try lib.checkGhosttyHEnum(Fullscreen, "GHOSTTY_FULLSCREEN_");
    }
};

pub const FloatWindow = enum(c_int) {
    on,
    off,
    toggle,

    test "ghostty.h FloatWindow" {
        try lib.checkGhosttyHEnum(FloatWindow, "GHOSTTY_FLOAT_WINDOW_");
    }
};

pub const SecureInput = enum(c_int) {
    on,
    off,
    toggle,

    test "ghostty.h SecureInput" {
        try lib.checkGhosttyHEnum(SecureInput, "GHOSTTY_SECURE_INPUT_");
    }
};

/// The inspector mode to toggle to if we're toggling the inspector.
pub const Inspector = enum(c_int) {
    toggle,
    show,
    hide,

    test "ghostty.h Inspector" {
        try lib.checkGhosttyHEnum(Inspector, "GHOSTTY_INSPECTOR_");
    }
};

/// Terminal IO inspector contents to export. The contents are only valid for
/// the duration of the action callback.
pub const ExportTerminalIO = struct {
    contents: []const u8,

    // Sync with: ghostty_action_export_terminal_io_s
    pub const C = extern struct {
        contents: [*]const u8,
        len: usize,
    };

    pub fn cval(self: ExportTerminalIO) C {
        return .{
            .contents = self.contents.ptr,
            .len = self.contents.len,
        };
    }

    pub fn format(
        value: @This(),
        comptime _: []const u8,
        _: std.fmt.Options,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print(
            "{s}{{ contents: {d} bytes }}",
            .{ @typeName(@This()), value.contents.len },
        );
    }
};

pub const QuitTimer = enum(c_int) {
    start,
    stop,

    test "ghostty.h QuitTimer" {
        try lib.checkGhosttyHEnum(QuitTimer, "GHOSTTY_QUIT_TIMER_");
    }
};

pub const Readonly = enum(c_int) {
    off,
    on,

    test "ghostty.h Readonly" {
        try lib.checkGhosttyHEnum(Readonly, "GHOSTTY_READONLY_");
    }
};

pub const MouseVisibility = enum(c_int) {
    visible,
    hidden,

    test "ghostty.h MouseVisibility" {
        try lib.checkGhosttyHEnum(MouseVisibility, "GHOSTTY_MOUSE_");
    }
};

/// Whether to prompt for the surface, tab, or window title.
pub const PromptTitle = enum(c_int) {
    surface,
    tab,
    window,

    test "ghostty.h PromptTitle" {
        try lib.checkGhosttyHEnum(PromptTitle, "GHOSTTY_PROMPT_TITLE_");
    }
};

pub const MouseOverLink = struct {
    url: [:0]const u8,

    // Sync with: ghostty_action_mouse_over_link_s
    pub const C = extern struct {
        url: [*]const u8,
        len: usize,
    };

    pub fn cval(self: MouseOverLink) C {
        return .{
            .url = self.url.ptr,
            .len = self.url.len,
        };
    }
};

pub const SizeLimit = extern struct {
    min_width: u32,
    min_height: u32,
    max_width: u32,
    max_height: u32,
};

pub const InitialSize = extern struct {
    width: u32,
    height: u32,

    /// Make this a valid gobject if we're in a GTK environment.
    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineBoxed(
            InitialSize,
            .{ .name = "GhosttyApprtInitialSize" },
        ),

        .none => void,
    };
};

pub const CellSize = extern struct {
    width: u32,
    height: u32,
};

pub const SetTitle = struct {
    title: [:0]const u8,

    /// True when this title was chosen on purpose -- a person renaming a
    /// tab, or an agent calling `set_surface_title` -- rather than reported
    /// by the program running in the surface (an OSC 0/2 escape sequence,
    /// or the title this surface started with). An apprt that remembers an
    /// explicit title uses this to keep it from being overwritten by the
    /// next thing the program says, the same protection a person's own
    /// rename already gets.
    ///
    /// Defaults to `false` so every existing call site -- the OSC-driven
    /// one in `handleMessage`, the `config.title` ones -- keeps behaving
    /// as it always has without having to name itself one by one.
    explicit: bool = false,

    // Sync with: ghostty_action_set_title_s
    pub const C = extern struct {
        title: [*:0]const u8,
        is_explicit: bool,
    };

    pub fn cval(self: SetTitle) C {
        return .{
            .title = self.title.ptr,
            .is_explicit = self.explicit,
        };
    }
};

/// What Poltergeist has to say about a surface, rendered, to be shown in
/// front of whatever the program running there called itself.
///
/// **A rendered prefix rather than the state behind it, and that is the
/// decision.** Two separate things are being said at once: what the
/// terminal is doing (`Bus.TabMark`, seven values) and who may touch it
/// (`Bus.isShielded`, a bool that is orthogonal to all seven, `none`
/// included). They stay two separate values in the core -- nothing is
/// folded into a fourteen-value enum -- and only their composition
/// crosses this boundary. That keeps the glyph vocabulary and the rule
/// that the shield leads in the one place their reasoning is written
/// (`src/poltergeist/Bus.zig`) instead of once per apprt, where two
/// copies of a seven-row table would drift.
///
/// The pointer is owned by the caller and is only valid for the duration
/// of the `performAction` call, same as `SetTitle`.
///
/// Empty means this tab has nothing to add.
pub const PoltergeistMark = struct {
    prefix: [:0]const u8,
    role: Role,
    shielded: bool,

    /// The user is holding this terminal to its work.
    ///
    /// **Sent for the same reason `role` and `shielded` are, and it is the
    /// same cost coming due a second time.** The note below says the first
    /// version sent the prefix alone and that an apprt could not see the
    /// meaning; `role` and `shielded` were added when a menu item needed to
    /// tick itself. The hold stayed behind in the glyphs -- `\u{25C9}` and
    /// `\u{25CE}` are the ring -- so the hold row was the one toggle in the
    /// menu that could not show its own state, on every apprt at once.
    ///
    /// ⚠️ **It is not derivable from `role` and the prefix out here.** A
    /// terminal with no role has no mark at all, held or not, so the prefix
    /// is empty in both states and there is nothing for an apprt to read. The
    /// only way the hold reaches a menu is as its own field.
    held: bool,

    /// The user has said a supervisor may answer this terminal's permission
    /// prompts.
    ///
    /// **The third time this cost has come due**, and the note above spells
    /// out why it comes due at all: an apprt cannot read meaning out of the
    /// rendered prefix, so a menu row that offers to change something cannot
    /// tick itself from a string. `role` and `shielded` were added when a
    /// menu item needed to; `held` when the hold row turned out to be the
    /// one toggle that could not show its own state on every apprt at once.
    /// This is a fourth toggle, and it would have been the same defect.
    ///
    /// ⚠️ **It has no glyph, unlike the other three.** The mark on a tab is
    /// a promise made to the person sitting at the terminal -- not clocked
    /// off, not reachable -- and this is a permission the user granted to
    /// somebody else. It is shown where it was granted, in the menu, and the
    /// prefix stays empty for it.
    may_authorise: bool,

    /// What this terminal is in the arrangement.
    ///
    /// Sent alongside the rendered prefix rather than instead of it. The
    /// glyphs stay the core's, because a table of them copied into each
    /// apprt is a table that drifts; but a menu item cannot tick itself
    /// from a string, and neither can a badge choose a colour from one.
    /// The first version sent the prefix alone and wrote the cost down --
    /// "an apprt cannot see the meaning" -- and this is that cost coming
    /// due, so the answer is to send both rather than to re-render the
    /// glyphs out here.
    ///
    /// Sync with: ghostty_action_poltergeist_role_e
    pub const Role = enum(c_int) {
        none = 0,
        supervisor = 1,
        watched = 2,
    };

    // Sync with: ghostty_action_poltergeist_mark_s
    pub const C = extern struct {
        prefix: [*:0]const u8,
        role: Role,
        shielded: bool,
        held: bool,
        may_authorise: bool,
    };

    pub fn cval(self: PoltergeistMark) C {
        return .{
            .prefix = self.prefix.ptr,
            .role = self.role,
            .shielded = self.shielded,
            .held = self.held,
            .may_authorise = self.may_authorise,
        };
    }

    pub fn format(
        value: @This(),
        comptime _: []const u8,
        _: std.fmt.Options,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("{s}{{ {s} }}", .{ @typeName(@This()), value.prefix });
    }
};

/// What Poltergeist's tool surface asked to close, and room for the answer.
///
/// `extern` rather than a plain struct with a `C` twin because there is
/// nothing to convert: a scope, a bool and a pointer are already what the
/// header says. A `cval` here would be a copy step whose only job is to
/// forget nothing, and the way it fails is by forgetting the pointer.
/// The answer to "how many terminals share a tab with this surface".
pub const PoltergeistTabPanes = extern struct {
    /// Written by the apprt before it returns. Never read by it.
    ///
    /// **Zero is the honest default**, and the core reads it as *this apprt
    /// did not answer*. A tab holding the target holds at least that one
    /// terminal, so no truthful answer is ever zero -- which makes zero free
    /// to mean "no answer" without a second field to say so. An apprt that
    /// does not implement this action, or implements it and writes nothing,
    /// is then reported as not knowing rather than as knowing that a tab is
    /// empty.
    ///
    /// ⚠️ **That branch is not hypothetical.** GTK does not implement this,
    /// so on Linux the answer is always "did not answer" and the caller has
    /// to fall back. It is a live path with a user, not a defensive one.
    count: *u32,
};

pub const PoltergeistClose = extern struct {
    scope: Scope,

    /// Whether the confirmation stays in front of the user. Already answered
    /// by `poltergeist.actions.confirmsCloseProtected` -- the target's mark
    /// says whether anybody is there to press it, the target's readonly lock
    /// says whether the user meant this terminal to be hard to close, and
    /// neither is a fact an apprt has.
    ///
    /// An apprt may only turn a confirmation *off* with this. It never adds
    /// one: false says "you may skip the question you were going to ask",
    /// and true says nothing at all beyond "carry on as usual".
    confirm: bool,

    /// Written by the apprt before it returns. Never read by it.
    result: *Result,

    /// Sync with: ghostty_action_poltergeist_close_scope_e
    pub const Scope = enum(c_int) {
        /// The tab holding the target surface. Falls back to the window when
        /// the tab is the only one, the same way the menu item does.
        this_tab,
        /// Every tab in the target's window except the target's own.
        other_tabs,
        /// The tabs after the target's, in tab order.
        tabs_to_the_right,
        /// The target's whole window, tab group and all.
        window,

        test "ghostty.h PoltergeistClose.Scope" {
            try lib.checkGhosttyHEnum(Scope, "GHOSTTY_ACTION_POLTERGEIST_CLOSE_SCOPE_");
        }
    };

    /// Sync with: ghostty_action_poltergeist_close_result_e
    ///
    /// `unsupported` is first so that zero is the honest answer. A caller
    /// initialises the cell to it and an apprt that quietly does nothing --
    /// or writes nothing -- is reported as having done nothing, rather than
    /// inheriting `closed` by accident. That accident is the exact bug this
    /// action exists to fix, and it would be sad to rebuild it in the
    /// enum's ordering.
    pub const Result = enum(c_int) {
        /// This apprt does not do this. Not a failure of the request.
        unsupported,
        /// It is closed, or on its way to closed with nothing left to ask.
        closed,
        /// The dialog is up and a person has to answer it. Nothing closed.
        awaiting_confirmation,

        /// The same three answers as the two the tool surface understands:
        /// it happened, or it did not and here is which sort of "did not".
        ///
        /// It lives here rather than in the caller because the caller is
        /// `App.poltergeistPerformAction`, and **nothing in `App.zig` is
        /// reached by any test in this repository** -- gutting that function
        /// leaves the whole suite green. A three-prong switch written there
        /// is a rule nobody can check; written here it is one line there and
        /// a test below. The tempting mistake is `.unsupported => {}`, which
        /// reports a close that never happened as done, and that is the bug
        /// this action was added to end.
        pub fn toolAnswer(self: Result) error{
            CloseAwaitingConfirm,
            ActionIgnored,
        }!void {
            return switch (self) {
                .closed => {},
                .awaiting_confirmation => error.CloseAwaitingConfirm,
                .unsupported => error.ActionIgnored,
            };
        }

        test "ghostty.h PoltergeistClose.Result" {
            try lib.checkGhosttyHEnum(Result, "GHOSTTY_ACTION_POLTERGEIST_CLOSE_RESULT_");
        }

        test "only a real close is reported as one" {
            const testing = std.testing;
            try Result.closed.toolAnswer();
            try testing.expectError(
                error.CloseAwaitingConfirm,
                Result.awaiting_confirmation.toolAnswer(),
            );
            try testing.expectError(
                error.ActionIgnored,
                Result.unsupported.toolAnswer(),
            );

            // Exhaustive from the type, so a fourth outcome added above has
            // to be given an answer here rather than defaulting to silence.
            for (std.enums.values(Result)) |r| {
                const ok = if (r.toolAnswer()) |_| true else |_| false;
                try testing.expectEqual(r == .closed, ok);
            }
        }
    };

    test "doing nothing is what a zeroed result says" {
        // The bug this action exists to fix is a close that reported success
        // without having closed anything. An apprt that handles this action
        // and forgets to write the cell, or one that leaves a zeroed struct
        // behind, must land on "nothing happened" -- so `unsupported` is
        // zero, and this is what stops a tidy-minded reordering from putting
        // `closed` there and rebuilding the bug in the enum's ordering.
        try std.testing.expectEqual(0, @intFromEnum(Result.unsupported));
        try std.testing.expect(@intFromEnum(Result.closed) != 0);
        try std.testing.expect(@intFromEnum(Result.awaiting_confirmation) != 0);

        // And the answer really does travel by pointer. An apprt writes it
        // after the value has been copied across the C boundary, so a
        // by-value field would be written into a copy and dropped -- silently,
        // which is the same failure wearing different clothes.
        try std.testing.expectEqual(
            *Result,
            @FieldType(PoltergeistClose, "result"),
        );
    }
};

/// Where a new tab should start.
///
/// Empty means "wherever a new tab would have started anyway", which is what
/// the keybinding and the menu item both pass: a tab opened by a person
/// inherits the directory of the terminal they opened it from, and that is
/// the behaviour to leave alone.
///
/// It is here because that inheritance is the only way a tab could get a
/// directory, and Poltergeist needs to put one somewhere the supervisor
/// chose rather than somewhere a terminal already happens to be.
/// A new split, and where it should start.
///
/// **`working_directory` is why this stopped being a bare direction.** A
/// supervisor's worker terminals are placed as splits, and each one is asked
/// for in a directory of its own -- that is the whole reason `terminal_open`
/// exists rather than `terminal_action(new_tab)`, whose new tab starts
/// wherever the terminal that opened it is standing. A split that quietly
/// ignored the directory would rebuild exactly the defect that tool was
/// built to avoid, and nothing on screen or in a log would say so.
pub const NewSplit = struct {
    direction: SplitDirection = .right,

    /// Empty means "wherever the split source is standing", which is what
    /// every split did before this field existed and what a keybinding still
    /// asks for.
    working_directory: [:0]const u8 = "",

    /// Written by the apprt before it returns; never read by it.
    ///
    /// **An apprt that cannot start a split in a named directory must not
    /// split at all.** Leaving this at `unsupported` and doing nothing is the
    /// answer; splitting anyway, in the parent's directory, is the one
    /// outcome that must not happen, because the caller would be told it got
    /// what it asked for. The core then opens a tab instead, which can carry
    /// a directory, and says in the log that it fell back and why.
    ///
    /// Null when nobody is asking -- a keybinding does not need an answer.
    result: ?*Result = null,

    /// Sync with: ghostty_action_new_split_result_e
    ///
    /// `unsupported` is first so that zero is the honest answer, the same
    /// reasoning as `PoltergeistClose.Result`: a cell nobody wrote reads as
    /// "not done" rather than inheriting "done" by accident.
    pub const Result = enum(c_int) {
        /// Nothing was split, and nothing will be. Either this apprt does
        /// not do splits at all, or it was asked for a directory it cannot
        /// honour.
        unsupported,

        /// **This apprt has taken the split on. It has not happened yet.**
        ///
        /// ⚠️ **The name says the tense, and it used to say the wrong one.**
        /// This was `split`, which reads as "a split was made" -- and on at
        /// least one apprt that is not what it means: the Windows host queues
        /// the work to the thread that owns windows and writes this cell
        /// *before* the op runs, because the call has to answer now. Its own
        /// comment says so ("Answered before the op runs"), so the comment
        /// and the name disagreed, and **a reader meets the name first**.
        ///
        /// What it claims is exactly this much: the request was accepted and
        /// the directory, if one was named, will be honoured. Whether a pane
        /// appeared is a different question and this cell does not answer it.
        will_split,
    };

    // Sync with: ghostty_action_new_split_s
    pub const C = extern struct {
        direction: SplitDirection,
        working_directory: [*:0]const u8,
        result: ?*Result,
    };

    pub fn cval(self: NewSplit) C {
        return .{
            .direction = self.direction,
            .working_directory = self.working_directory.ptr,
            .result = self.result,
        };
    }
};

/// Rearrange a tab's panes into a shape given from outside.
///
/// # Why a whole shape rather than one split at a time
///
/// A supervisor placing four workers used to have to say "split this pane"
/// four times, and **each call is a round trip against a layout that is
/// still moving**: the person can take focus, another agent can close a
/// pane, and a call that fails half way leaves half a layout with nothing
/// anywhere recording what was intended. Saying the shape once means it is
/// resolved against one snapshot and either happens or does not.
///
/// It is also the only way to learn which panes were made. `NewSplit`
/// answers before its work runs, so the pane it creates has no id to report
/// at the time it returns -- which is why splitting four times produced a
/// chain: nothing could name the panes it had just made.
///
/// # The spec, and why it is a string
///
/// JSON, parsed by the apprt. The tree is the apprt's -- the core does not
/// know which surfaces share a tab, and says so wherever it has to ask -- so
/// a structure marshalled across this boundary would be a second model of
/// something this side does not own. A string is a conduit; a struct would
/// be a claim.
pub const PoltergeistLayout = struct {
    /// The shape asked for. See `docs/poltergeist/` and the tool description.
    spec: [:0]const u8,

    /// Where the apprt writes its answer.
    ///
    /// ⚠️ **One pointer rather than four fields, because the action union is
    /// pinned to three words** by a `comptime` assertion a few hundred lines
    /// below -- and that assertion is a checkpoint, not an obstacle: it is
    /// there so that widening the ABI is a decision somebody makes rather
    /// than a side effect of adding a payload. This payload is two words and
    /// leaves it where it was.
    out: ?*Out = null,

    /// Sync with: ghostty_action_poltergeist_layout_result_e
    ///
    /// `unsupported` is first so zero is the honest answer, the same
    /// reasoning as `NewSplit.Result`.
    pub const Result = enum(c_int) {
        /// This apprt does not rearrange panes. **A first-class answer, not
        /// a fallback**: the tool says so plainly rather than pretending a
        /// layout was set.
        unsupported,
        /// The shape was accepted and applied.
        applied,
        /// The shape was understood and refused -- a pane it did not name, a
        /// ratio this platform cannot honour, a cell that parsed wrong. The
        /// reason is in `out`, and **nothing was changed**.
        refused,
    };

    /// The cell the caller hands over and reads back.
    ///
    /// **The buffer is the caller's**, not an allocation handed across:
    /// nothing else in this ABI passes memory back, and a rule with one
    /// exception is a rule somebody has to remember. `len` is what the apprt
    /// wrote; `cap` is how much room there was, and an apprt that needs more
    /// writes what fits and says so in the reason rather than truncating
    /// silently.
    ///
    /// Sync with: ghostty_action_poltergeist_layout_out_s
    pub const Out = extern struct {
        result: Result = .unsupported,
        buf: ?[*]u8 = null,
        cap: usize = 0,
        len: usize = 0,
    };

    // Sync with: ghostty_action_poltergeist_layout_s
    pub const C = extern struct {
        spec: [*:0]const u8,
        out: ?*Out,
    };

    pub fn cval(self: PoltergeistLayout) C {
        return .{ .spec = self.spec.ptr, .out = self.out };
    }
};

pub const NewTab = struct {
    working_directory: [:0]const u8 = "",

    // Sync with: ghostty_action_new_tab_s
    pub const C = extern struct {
        working_directory: [*:0]const u8,
    };

    pub fn cval(self: NewTab) C {
        return .{
            .working_directory = self.working_directory.ptr,
        };
    }

    pub fn format(
        value: @This(),
        comptime _: []const u8,
        _: std.fmt.Options,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("{s}{{ {s} }}", .{ @typeName(@This()), value.working_directory });
    }
};

pub const Pwd = struct {
    pwd: [:0]const u8,

    // Sync with: ghostty_action_set_pwd_s
    pub const C = extern struct {
        pwd: [*:0]const u8,
    };

    pub fn cval(self: Pwd) C {
        return .{
            .pwd = self.pwd.ptr,
        };
    }

    pub fn format(
        value: @This(),
        comptime _: []const u8,
        _: std.fmt.Options,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("{s}{{ {s} }}", .{ @typeName(@This()), value.pwd });
    }
};

/// See `Action.history_filename`'s doc comment.
pub const HistoryFilename = struct {
    filename: [:0]const u8,

    // Sync with: ghostty_action_history_filename_s
    pub const C = extern struct {
        filename: [*:0]const u8,
    };

    pub fn cval(self: HistoryFilename) C {
        return .{
            .filename = self.filename.ptr,
        };
    }

    pub fn format(
        value: @This(),
        comptime _: []const u8,
        _: std.fmt.Options,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("{s}{{ {s} }}", .{ @typeName(@This()), value.filename });
    }
};

/// The desktop notification to show.
pub const DesktopNotification = struct {
    title: [:0]const u8,
    body: [:0]const u8,

    // Sync with: ghostty_action_desktop_notification_s
    pub const C = extern struct {
        title: [*:0]const u8,
        body: [*:0]const u8,
    };

    pub fn cval(self: DesktopNotification) C {
        return .{
            .title = self.title.ptr,
            .body = self.body.ptr,
        };
    }

    pub fn format(
        value: @This(),
        comptime _: []const u8,
        _: std.fmt.Options,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("{s}{{ title: {s}, body: {s} }}", .{
            @typeName(@This()),
            value.title,
            value.body,
        });
    }
};

pub const KeySequence = union(enum) {
    trigger: input.Trigger,
    end,

    // Sync with: ghostty_action_key_sequence_s
    pub const C = extern struct {
        active: bool,
        trigger: input.Trigger.C,
    };

    pub fn cval(self: KeySequence) C {
        return switch (self) {
            .trigger => |t| .{ .active = true, .trigger = t.cval() },
            .end => .{ .active = false, .trigger = .{} },
        };
    }
};

pub const KeyTable = union(enum) {
    activate: []const u8,
    deactivate,
    deactivate_all,

    // Sync with: ghostty_action_key_table_tag_e
    pub const Tag = enum(c_int) {
        activate,
        deactivate,
        deactivate_all,
    };

    // Sync with: ghostty_action_key_table_u
    pub const CValue = extern union {
        activate: extern struct {
            name: [*]const u8,
            len: usize,
        },
    };

    // Sync with: ghostty_action_key_table_s
    pub const C = extern struct {
        tag: Tag,
        value: CValue,
    };

    pub fn cval(self: KeyTable) C {
        return switch (self) {
            .activate => |name| .{
                .tag = .activate,
                .value = .{ .activate = .{ .name = name.ptr, .len = name.len } },
            },
            .deactivate => .{
                .tag = .deactivate,
                .value = undefined,
            },
            .deactivate_all => .{
                .tag = .deactivate_all,
                .value = undefined,
            },
        };
    }
};

pub const ColorChange = extern struct {
    kind: ColorKind,
    r: u8,
    g: u8,
    b: u8,
};

pub const ColorKind = enum(c_int) {
    // Negative numbers indicate some named kind
    foreground = -1,
    background = -2,
    cursor = -3,

    // 0+ values indicate a palette index
    _,

    // TODO: check non-non-exhaustive enums
    // test "ghostty.h ColorKind" {
    //     try lib.checkGhosttyHEnum(ColorKind, "GHOSTTY_COLOR_KIND_");
    // }
};

pub const ReloadConfig = extern struct {
    /// A soft reload means that the configuration doesn't need to be
    /// read off disk, but libghostty needs the full config again so call
    /// updateConfig with it.
    soft: bool = false,
};

pub const ConfigChange = struct {
    config: *const configpkg.Config,

    // Sync with: ghostty_action_config_change_s
    pub const C = extern struct {
        config: *const configpkg.Config,
    };

    pub fn cval(self: ConfigChange) C {
        return .{
            .config = self.config,
        };
    }
};

/// Open a URL
pub const OpenUrl = struct {
    /// The type of data that the URL refers to.
    kind: Kind,

    /// The URL.
    url: []const u8,

    /// The type of the data at the URL to open. This is used as a hint to
    /// potentially open the URL in a different way.
    ///
    /// Sync with: ghostty_action_open_url_kind_e
    pub const Kind = enum(c_int) {
        /// The type is unknown. This is the default and apprts should
        /// open the URL in the most generic way possible. For example,
        /// on macOS this would be the equivalent of `open` or on Linux
        /// this would be `xdg-open`.
        unknown,

        /// The URL is known to be a text file. In this case, the apprt
        /// should try to open the URL in a text editor or viewer or
        /// some equivalent, if possible.
        text,

        /// The URL is known to contain HTML content.
        html,

        /// The URL came from an OSC 8 hyperlink. Application runtimes should
        /// treat this as untrusted terminal output and apply a platform-specific
        /// safe-opening policy.
        osc8,

        test "ghostty.h OpenUrl.Kind" {
            try lib.checkGhosttyHEnum(Kind, "GHOSTTY_ACTION_OPEN_URL_KIND_");
        }
    };

    // Sync with: ghostty_action_open_url_s
    pub const C = extern struct {
        kind: Kind,
        url: [*]const u8,
        len: usize,
    };

    pub fn cval(self: OpenUrl) C {
        return .{
            .kind = self.kind,
            .url = self.url.ptr,
            .len = self.url.len,
        };
    }
};

/// sync with ghostty_action_close_tab_mode_e in ghostty.h
pub const CloseTabMode = enum(c_int) {
    /// Close the current tab.
    this,
    /// Close all other tabs.
    other,
    /// Close all tabs to the right of the current tab.
    right,

    test "ghostty.h CloseTabMode" {
        try lib.checkGhosttyHEnum(CloseTabMode, "GHOSTTY_ACTION_CLOSE_TAB_MODE_");
    }
};

pub const CommandFinished = struct {
    exit_code: ?u8,
    duration: configpkg.Config.Duration,

    /// sync with ghostty_action_command_finished_s in ghostty.h
    pub const C = extern struct {
        exit_code: i16,
        duration: u64,
    };

    pub fn cval(self: CommandFinished) C {
        return .{
            .exit_code = self.exit_code orelse -1,
            .duration = self.duration.duration,
        };
    }
};

pub const StartSearch = struct {
    needle: [:0]const u8,

    // Sync with: ghostty_action_start_search_s
    pub const C = extern struct {
        needle: [*:0]const u8,
    };

    pub fn cval(self: StartSearch) C {
        return .{
            .needle = self.needle.ptr,
        };
    }
};

pub const SearchTotal = struct {
    total: ?usize,

    // Sync with: ghostty_action_search_total_s
    pub const C = extern struct {
        total: isize,
    };

    pub fn cval(self: SearchTotal) C {
        return .{
            .total = if (self.total) |t| @intCast(t) else -1,
        };
    }
};

pub const SearchSelected = struct {
    selected: ?usize,

    // Sync with: ghostty_action_search_selected_s
    pub const C = extern struct {
        selected: isize,
    };

    pub fn cval(self: SearchSelected) C {
        return .{
            .selected = if (self.selected) |s| @intCast(s) else -1,
        };
    }
};

/// sync with ghostty_action_close_tab_mode_e in ghostty.h
pub const OpenConfig = enum(c_int) {
    /// Open the config in the OS default editor.
    os_open,

    /// Open the config in a new window using $EDITOR or $VISUAL
    new_window,

    test "ghostty.h OpenConfig" {
        try lib.checkGhosttyHEnum(OpenConfig, "GHOSTTY_ACTION_OPEN_CONFIG_");
    }
};

test {
    _ = compat_testing.refAllDeclsRecursive(@This());
}
