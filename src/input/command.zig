const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const Action = @import("Binding.zig").Action;
const i18n = @import("../os/i18n.zig");

/// A command is a named binding action that can be executed from
/// something like a command palette.
///
/// A command must be associated with a binding; all commands can be
/// mapped to traditional `keybind` configurations. This restriction
/// makes it so that there is nothing special about commands and likewise
/// it makes it trivial and consistent to define custom commands.
///
/// For apprt implementers: a command palette doesn't have to make use
/// of all the fields here. We try to provide as much information as
/// possible to make it easier to implement a command palette in the way
/// that makes the most sense for the application.
pub const Command = struct {
    action: Action,
    title: [:0]const u8,
    description: [:0]const u8 = "",

    /// ghostty_command_s
    pub const C = extern struct {
        action_key: [*:0]const u8,
        action: [*:0]const u8,
        title: [*:0]const u8,
        description: [*:0]const u8,
    };

    pub fn clone(self: *const Command, alloc: Allocator) Allocator.Error!Command {
        return .{
            .action = try self.action.clone(alloc),
            .title = try alloc.dupeZ(u8, self.title),
            .description = try alloc.dupeZ(u8, self.description),
        };
    }

    pub fn equal(self: Command, other: Command) bool {
        if (self.action.hash() != other.action.hash()) return false;
        if (!std.mem.eql(u8, self.title, other.title)) return false;
        if (!std.mem.eql(u8, self.description, other.description)) return false;
        return true;
    }

    /// Convert this command to a C struct at comptime.
    pub fn comptimeCval(self: Command) C {
        assert(@inComptime());

        return .{
            .action_key = @tagName(self.action),
            .action = std.fmt.comptimePrint("{f}", .{self.action}),
            .title = self.title,
            .description = self.description,
        };
    }

    /// Convert this command to a C struct at runtime.
    ///
    /// This shares memory with the original command.
    ///
    /// The action string is allocated using the provided allocator. You can
    /// free the slice directly if you need to but we recommend an arena
    /// for this.
    pub fn cval(self: Command, alloc: Allocator) Allocator.Error!C {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        self.action.format(&buf.writer) catch return error.OutOfMemory;
        const action = try buf.toOwnedSliceSentinel(0);

        return .{
            .action_key = @tagName(self.action),
            .action = action.ptr,
            .title = self.title,
            .description = self.description,
        };
    }

    pub fn translated(self: Command) Command {
        return .{
            .action = self.action,
            .title = std.mem.span(i18n._(self.title)),
            .description = std.mem.span(i18n._(self.description)),
        };
    }

    /// Implements a comparison function for std.mem.sortUnstable
    /// and similar functions. The sorting is defined by Ghostty
    /// to be what we prefer. If a caller wants some other sorting,
    /// they should do it themselves.
    pub fn lessThan(_: void, lhs: Command, rhs: Command) bool {
        return std.ascii.orderIgnoreCase(lhs.title, rhs.title) == .lt;
    }
};

pub const defaults: []const Command = defaults: {
    @setEvalBranchQuota(100_000);

    var count: usize = 0;
    for (@typeInfo(Action.Key).@"enum".fields) |field| {
        const action = @field(Action.Key, field.name);
        count += actionCommands(action).len;
    }

    var result: [count]Command = undefined;
    var i: usize = 0;
    for (@typeInfo(Action.Key).@"enum".fields) |field| {
        const action = @field(Action.Key, field.name);
        const commands = actionCommands(action);
        for (commands) |cmd| {
            result[i] = cmd;
            i += 1;
        }
    }

    std.mem.sortUnstable(Command, &result, {}, Command.lessThan);

    assert(i == count);
    const final = result;
    break :defaults &final;
};

/// Defaults in C-compatible form.
pub const defaultsC: []const Command.C = defaults: {
    @setEvalBranchQuota(100_000);
    var result: [defaults.len]Command.C = undefined;
    for (defaults, 0..) |cmd, i| result[i] = cmd.comptimeCval();
    const final = result;
    break :defaults &final;
};

/// Returns the set of commands associated with this action key by
/// default. Not all actions should have commands. As a general guideline,
/// an action should have a command only if it is useful and reasonable
/// to appear in a command palette.
fn actionCommands(action: Action.Key) []const Command {
    // This is implemented as a function and switch rather than a
    // flat comptime const because we want to ensure we get a compiler
    // error when a new binding is added so that the contributor has
    // to consider whether that new binding should have commands or not.
    const result: []const Command = switch (action) {
        // Note: the use of `comptime` prefix on the return values
        // ensures that the data returned is all in the binary and
        // and not pointing to the stack.

        .reset => comptime &.{.{
            .action = .reset,
            .title = i18n.N_("Reset Terminal"),
            .description = i18n.N_("Reset the terminal to a clean state."),
        }},

        .copy_to_clipboard => comptime &.{ .{
            .action = .{ .copy_to_clipboard = .mixed },
            .title = i18n.N_("Copy to Clipboard"),
            .description = i18n.N_("Copy the selected text to the clipboard in both plain and styled formats."),
        }, .{
            .action = .{ .copy_to_clipboard = .plain },
            .title = i18n.N_("Copy Selection as Plain Text to Clipboard"),
            .description = i18n.N_("Copy the selected text as plain text to the clipboard."),
        }, .{
            .action = .{ .copy_to_clipboard = .vt },
            .title = i18n.N_("Copy Selection as ANSI Sequences to Clipboard"),
            .description = i18n.N_("Copy the selected text as ANSI escape sequences to the clipboard."),
        }, .{
            .action = .{ .copy_to_clipboard = .html },
            .title = i18n.N_("Copy Selection as HTML to Clipboard"),
            .description = i18n.N_("Copy the selected text as HTML to the clipboard."),
        } },

        .copy_url_to_clipboard => comptime &.{.{
            .action = .copy_url_to_clipboard,
            .title = i18n.N_("Copy URL to Clipboard"),
            .description = i18n.N_("Copy the URL under the cursor to the clipboard."),
        }},

        .copy_title_to_clipboard => comptime &.{.{
            .action = .copy_title_to_clipboard,
            .title = i18n.N_("Copy Terminal Title to Clipboard"),
            .description = i18n.N_("Copy the terminal title to the clipboard. If the terminal title is not set this has no effect."),
        }},

        .paste_from_clipboard => comptime &.{.{
            .action = .paste_from_clipboard,
            .title = i18n.N_("Paste from Clipboard"),
            .description = i18n.N_("Paste the contents of the main clipboard."),
        }},

        .paste_from_selection => comptime &.{.{
            .action = .paste_from_selection,
            .title = i18n.N_("Paste from Selection"),
            .description = i18n.N_("Paste the contents of the selection clipboard."),
        }},

        .start_search => comptime &.{.{
            .action = .start_search,
            .title = i18n.N_("Start Search"),
            .description = i18n.N_("Start a search if one isn't already active."),
        }},

        .search_selection => comptime &.{.{
            .action = .search_selection,
            .title = i18n.N_("Search Selection"),
            .description = i18n.N_("Start a search for the current text selection."),
        }},

        .end_search => comptime &.{.{
            .action = .end_search,
            .title = i18n.N_("End Search"),
            .description = i18n.N_("End the current search if any and hide any GUI elements."),
        }},

        .navigate_search => comptime &.{ .{
            .action = .{ .navigate_search = .next },
            .title = i18n.N_("Next Search Result"),
            .description = i18n.N_("Navigate to the next search result, if any."),
        }, .{
            .action = .{ .navigate_search = .previous },
            .title = i18n.N_("Previous Search Result"),
            .description = i18n.N_("Navigate to the previous search result, if any."),
        } },

        .increase_font_size => comptime &.{.{
            .action = .{ .increase_font_size = 1 },
            .title = i18n.N_("Increase Font Size"),
            .description = i18n.N_("Increase the font size by 1 point."),
        }},

        .decrease_font_size => comptime &.{.{
            .action = .{ .decrease_font_size = 1 },
            .title = i18n.N_("Decrease Font Size"),
            .description = i18n.N_("Decrease the font size by 1 point."),
        }},

        .reset_font_size => comptime &.{.{
            .action = .reset_font_size,
            .title = i18n.N_("Reset Font Size"),
            .description = i18n.N_("Reset the font size to the default."),
        }},

        .clear_screen => comptime &.{.{
            .action = .clear_screen,
            .title = i18n.N_("Clear Screen"),
            .description = i18n.N_("Clear the screen and scrollback."),
        }},

        .select_all => comptime &.{.{
            .action = .select_all,
            .title = i18n.N_("Select All"),
            .description = i18n.N_("Select all text on the screen."),
        }},

        .scroll_to_top => comptime &.{.{
            .action = .scroll_to_top,
            .title = i18n.N_("Scroll to Top"),
            .description = i18n.N_("Scroll to the top of the screen."),
        }},

        .scroll_to_bottom => comptime &.{.{
            .action = .scroll_to_bottom,
            .title = i18n.N_("Scroll to Bottom"),
            .description = i18n.N_("Scroll to the bottom of the screen."),
        }},

        .scroll_to_selection => comptime &.{.{
            .action = .scroll_to_selection,
            .title = i18n.N_("Scroll to Selection"),
            .description = i18n.N_("Scroll to the selected text."),
        }},

        .scroll_page_up => comptime &.{.{
            .action = .scroll_page_up,
            .title = i18n.N_("Scroll Page Up"),
            .description = i18n.N_("Scroll the screen up by a page."),
        }},

        .scroll_page_down => comptime &.{.{
            .action = .scroll_page_down,
            .title = i18n.N_("Scroll Page Down"),
            .description = i18n.N_("Scroll the screen down by a page."),
        }},

        .write_screen_file => comptime &.{
            .{
                .action = .{ .write_screen_file = .copy },
                .title = i18n.N_("Copy Screen to Temporary File and Copy Path"),
                .description = i18n.N_("Copy the screen contents to a temporary file and copy the path to the clipboard."),
            },
            .{
                .action = .{ .write_screen_file = .paste },
                .title = i18n.N_("Copy Screen to Temporary File and Paste Path"),
                .description = i18n.N_("Copy the screen contents to a temporary file and paste the path to the file."),
            },
            .{
                .action = .{ .write_screen_file = .open },
                .title = i18n.N_("Copy Screen to Temporary File and Open"),
                .description = i18n.N_("Copy the screen contents to a temporary file and open it."),
            },

            .{
                .action = .{ .write_screen_file = .{
                    .action = .copy,
                    .emit = .html,
                } },
                .title = i18n.N_("Copy Screen as HTML to Temporary File and Copy Path"),
                .description = i18n.N_("Copy the screen contents as HTML to a temporary file and copy the path to the clipboard."),
            },
            .{
                .action = .{ .write_screen_file = .{
                    .action = .paste,
                    .emit = .html,
                } },
                .title = i18n.N_("Copy Screen as HTML to Temporary File and Paste Path"),
                .description = i18n.N_("Copy the screen contents as HTML to a temporary file and paste the path to the file."),
            },
            .{
                .action = .{ .write_screen_file = .{
                    .action = .open,
                    .emit = .html,
                } },
                .title = i18n.N_("Copy Screen as HTML to Temporary File and Open"),
                .description = i18n.N_("Copy the screen contents as HTML to a temporary file and open it."),
            },

            .{
                .action = .{ .write_screen_file = .{
                    .action = .copy,
                    .emit = .vt,
                } },
                .title = i18n.N_("Copy Screen as ANSI Sequences to Temporary File and Copy Path"),
                .description = i18n.N_("Copy the screen contents as ANSI escape sequences to a temporary file and copy the path to the clipboard."),
            },
            .{
                .action = .{ .write_screen_file = .{
                    .action = .paste,
                    .emit = .vt,
                } },
                .title = i18n.N_("Copy Screen as ANSI Sequences to Temporary File and Paste Path"),
                .description = i18n.N_("Copy the screen contents as ANSI escape sequences to a temporary file and paste the path to the file."),
            },
            .{
                .action = .{ .write_screen_file = .{
                    .action = .open,
                    .emit = .vt,
                } },
                .title = i18n.N_("Copy Screen as ANSI Sequences to Temporary File and Open"),
                .description = i18n.N_("Copy the screen contents as ANSI escape sequences to a temporary file and open it."),
            },
        },

        .write_selection_file => comptime &.{
            .{
                .action = .{ .write_selection_file = .copy },
                .title = i18n.N_("Copy Selection to Temporary File and Copy Path"),
                .description = i18n.N_("Copy the selection contents to a temporary file and copy the path to the clipboard."),
            },
            .{
                .action = .{ .write_selection_file = .paste },
                .title = i18n.N_("Copy Selection to Temporary File and Paste Path"),
                .description = i18n.N_("Copy the selection contents to a temporary file and paste the path to the file."),
            },
            .{
                .action = .{ .write_selection_file = .open },
                .title = i18n.N_("Copy Selection to Temporary File and Open"),
                .description = i18n.N_("Copy the selection contents to a temporary file and open it."),
            },

            .{
                .action = .{ .write_selection_file = .{
                    .action = .copy,
                    .emit = .html,
                } },
                .title = i18n.N_("Copy Selection as HTML to Temporary File and Copy Path"),
                .description = i18n.N_("Copy the selection contents as HTML to a temporary file and copy the path to the clipboard."),
            },
            .{
                .action = .{ .write_selection_file = .{
                    .action = .paste,
                    .emit = .html,
                } },
                .title = i18n.N_("Copy Selection as HTML to Temporary File and Paste Path"),
                .description = i18n.N_("Copy the selection contents as HTML to a temporary file and paste the path to the file."),
            },
            .{
                .action = .{ .write_selection_file = .{
                    .action = .open,
                    .emit = .html,
                } },
                .title = i18n.N_("Copy Selection as HTML to Temporary File and Open"),
                .description = i18n.N_("Copy the selection contents as HTML to a temporary file and open it."),
            },

            .{
                .action = .{ .write_selection_file = .{
                    .action = .copy,
                    .emit = .vt,
                } },
                .title = i18n.N_("Copy Selection as ANSI Sequences to Temporary File and Copy Path"),
                .description = i18n.N_("Copy the selection contents as ANSI escape sequences to a temporary file and copy the path to the clipboard."),
            },
            .{
                .action = .{ .write_selection_file = .{
                    .action = .paste,
                    .emit = .vt,
                } },
                .title = i18n.N_("Copy Selection as ANSI Sequences to Temporary File and Paste Path"),
                .description = i18n.N_("Copy the selection contents as ANSI escape sequences to a temporary file and paste the path to the file."),
            },
            .{
                .action = .{ .write_selection_file = .{
                    .action = .open,
                    .emit = .vt,
                } },
                .title = i18n.N_("Copy Selection as ANSI Sequences to Temporary File and Open"),
                .description = i18n.N_("Copy the selection contents as ANSI escape sequences to a temporary file and open it."),
            },
        },

        .new_window => comptime &.{.{
            .action = .new_window,
            .title = i18n.N_("New Window"),
            .description = i18n.N_("Open a new window."),
        }},

        .new_tab => comptime &.{.{
            .action = .new_tab,
            .title = i18n.N_("New Tab"),
            .description = i18n.N_("Open a new tab."),
        }},

        .move_tab => comptime &.{
            .{
                .action = .{ .move_tab = -1 },
                .title = i18n.N_("Move Tab Left"),
                .description = i18n.N_("Move the current tab to the left."),
            },
            .{
                .action = .{ .move_tab = 1 },
                .title = i18n.N_("Move Tab Right"),
                .description = i18n.N_("Move the current tab to the right."),
            },
        },

        .move_tab_to_new_window => comptime &.{.{
            .action = .move_tab_to_new_window,
            .title = i18n.N_("Move Tab to New Window"),
            .description = i18n.N_("Move the current tab to a new window."),
        }},

        .toggle_tab_overview => comptime &.{.{
            .action = .toggle_tab_overview,
            .title = i18n.N_("Toggle Tab Overview"),
            .description = i18n.N_("Toggle the tab overview."),
        }},

        .prompt_surface_title => comptime &.{.{
            .action = .prompt_surface_title,
            .title = i18n.N_("Change Terminal Title…"),
            .description = i18n.N_("Prompt for a new title for the current terminal."),
        }},

        .prompt_tab_title => comptime &.{.{
            .action = .prompt_tab_title,
            .title = i18n.N_("Change Tab Title…"),
            .description = i18n.N_("Prompt for a new title for the current tab."),
        }},

        .prompt_window_title => comptime &.{.{
            .action = .prompt_window_title,
            .title = "Change Window Title…",
            .description = "Prompt for a new title for the current window.",
        }},

        .new_split => comptime &.{
            .{
                .action = .{ .new_split = .left },
                .title = i18n.N_("Split Left"),
                .description = i18n.N_("Split the terminal to the left."),
            },
            .{
                .action = .{ .new_split = .right },
                .title = i18n.N_("Split Right"),
                .description = i18n.N_("Split the terminal to the right."),
            },
            .{
                .action = .{ .new_split = .up },
                .title = i18n.N_("Split Up"),
                .description = i18n.N_("Split the terminal up."),
            },
            .{
                .action = .{ .new_split = .down },
                .title = i18n.N_("Split Down"),
                .description = i18n.N_("Split the terminal down."),
            },
        },

        .goto_split => comptime &.{
            .{
                .action = .{ .goto_split = .previous },
                .title = i18n.N_("Focus Split: Previous"),
                .description = i18n.N_("Focus the previous split, if any."),
            },
            .{
                .action = .{ .goto_split = .next },
                .title = i18n.N_("Focus Split: Next"),
                .description = i18n.N_("Focus the next split, if any."),
            },
            .{
                .action = .{ .goto_split = .left },
                .title = i18n.N_("Focus Split: Left"),
                .description = i18n.N_("Focus the split to the left, if it exists."),
            },
            .{
                .action = .{ .goto_split = .right },
                .title = i18n.N_("Focus Split: Right"),
                .description = i18n.N_("Focus the split to the right, if it exists."),
            },
            .{
                .action = .{ .goto_split = .up },
                .title = i18n.N_("Focus Split: Up"),
                .description = i18n.N_("Focus the split above, if it exists."),
            },
            .{
                .action = .{ .goto_split = .down },
                .title = i18n.N_("Focus Split: Down"),
                .description = i18n.N_("Focus the split below, if it exists."),
            },
        },

        .goto_window => comptime &.{
            .{
                .action = .{ .goto_window = .previous },
                .title = i18n.N_("Focus Window: Previous"),
                .description = i18n.N_("Focus the previous window, if any."),
            },
            .{
                .action = .{ .goto_window = .next },
                .title = i18n.N_("Focus Window: Next"),
                .description = i18n.N_("Focus the next window, if any."),
            },
        },

        .toggle_split_zoom => comptime &.{.{
            .action = .toggle_split_zoom,
            .title = i18n.N_("Toggle Split Zoom"),
            .description = i18n.N_("Toggle the zoom state of the current split."),
        }},

        .toggle_readonly => comptime &.{.{
            .action = .toggle_readonly,
            .title = i18n.N_("Toggle Read-Only Mode"),
            .description = i18n.N_("Toggle read-only mode for the current surface."),
        }},

        .poltergeist_supervisor => comptime &.{.{
            .action = .poltergeist_supervisor,
            .title = i18n.N_("Make This Terminal a Supervisor"),
            .description = i18n.N_("Let this terminal's agent mind terminals it claims. There may be several supervisors; each reaches only its own."),
        }},

        .poltergeist_toggle_watch => comptime &.{.{
            .action = .poltergeist_toggle_watch,
            .title = i18n.N_("Toggle Supervision of This Terminal"),
            .description = i18n.N_("Report this terminal to the supervisor when its screen goes quiet."),
        }},

        .poltergeist_toggle_held => comptime &.{.{
            .action = .poltergeist_toggle_held,
            .title = i18n.N_("Keep This Terminal Working"),
            .description = i18n.N_("Do not let a supervisor clock this terminal off. Its tab wears a ring while the hold lasts. Only you can set this; a supervisor cannot."),
        }},

        .poltergeist_toggle_shielded => comptime &.{.{
            .action = .poltergeist_toggle_shielded,
            .title = i18n.N_("Keep Agents Out of This Terminal"),
            .description = i18n.N_("Stop every agent, supervisors included, from reading this terminal or typing into it. Its tab wears a lock while the shield stands. Only you can set this."),
        }},

        .poltergeist_toggle_chat => comptime &.{.{
            .action = .poltergeist_toggle_chat,
            .title = i18n.N_("Terminal Conversations"),
            .description = i18n.N_("Open a terminal showing what the terminals have said to each other."),
        }},

        .equalize_splits => comptime &.{.{
            .action = .equalize_splits,
            .title = i18n.N_("Equalize Splits"),
            .description = i18n.N_("Equalize the size of all splits."),
        }},

        .reset_window_size => comptime &.{.{
            .action = .reset_window_size,
            .title = i18n.N_("Reset Window Size"),
            .description = i18n.N_("Reset the window size to the default."),
        }},

        .inspector => comptime &.{.{
            .action = .{ .inspector = .toggle },
            .title = i18n.N_("Toggle Inspector"),
            .description = i18n.N_("Toggle the inspector."),
        }},

        .show_gtk_inspector => comptime &.{.{
            .action = .show_gtk_inspector,
            .title = i18n.N_("Show the GTK Inspector"),
            .description = i18n.N_("Show the GTK inspector."),
        }},

        .show_on_screen_keyboard => comptime &.{.{
            .action = .show_on_screen_keyboard,
            .title = i18n.N_("Show On-Screen Keyboard"),
            .description = i18n.N_("Show the on-screen keyboard if present."),
        }},

        .open_config => comptime &.{
            .{
                .action = .{ .open_config = .os_open },
                .title = i18n.N_("Open Config Using OS editor"),
                .description = i18n.N_("Open the config file with the OS's default editor."),
            },
            .{
                .action = .{ .open_config = .new_window },
                .title = i18n.N_("Open Config in New Terminal Window"),
                .description = i18n.N_("Open the config file in a new window using $EDITOR or $VISUAL."),
            },
        },

        .reload_config => comptime &.{.{
            .action = .reload_config,
            .title = i18n.N_("Reload Config"),
            .description = i18n.N_("Reload the config file."),
        }},

        .close_surface => comptime &.{.{
            .action = .close_surface,
            .title = i18n.N_("Close Terminal"),
            .description = i18n.N_("Close the current terminal."),
        }},

        .close_tab => comptime &.{
            .{
                .action = .{ .close_tab = .this },
                .title = i18n.N_("Close Tab"),
                .description = i18n.N_("Close the current tab."),
            },
            .{
                .action = .{ .close_tab = .other },
                .title = i18n.N_("Close Other Tabs"),
                .description = i18n.N_("Close all tabs in this window except the current one."),
            },
            .{
                .action = .{ .close_tab = .right },
                .title = i18n.N_("Close Tabs to the Right"),
                .description = i18n.N_("Close all tabs to the right of the current one."),
            },
        },

        .close_window => comptime &.{.{
            .action = .close_window,
            .title = i18n.N_("Close Window"),
            .description = i18n.N_("Close the current window."),
        }},

        .close_all_windows => comptime &.{.{
            .action = .close_all_windows,
            .title = i18n.N_("Close All Windows"),
            .description = i18n.N_("Close all windows."),
        }},

        .toggle_maximize => comptime &.{.{
            .action = .toggle_maximize,
            .title = i18n.N_("Toggle Maximize"),
            .description = i18n.N_("Toggle the maximized state of the current window."),
        }},

        .toggle_fullscreen => comptime &.{.{
            .action = .toggle_fullscreen,
            .title = i18n.N_("Toggle Fullscreen"),
            .description = i18n.N_("Toggle the fullscreen state of the current window."),
        }},

        .toggle_window_decorations => comptime &.{.{
            .action = .toggle_window_decorations,
            .title = i18n.N_("Toggle Window Decorations"),
            .description = i18n.N_("Toggle the window decorations."),
        }},

        .toggle_window_float_on_top => comptime &.{.{
            .action = .toggle_window_float_on_top,
            .title = i18n.N_("Toggle Float on Top"),
            .description = i18n.N_("Toggle the float on top state of the current window."),
        }},

        .toggle_secure_input => comptime &.{.{
            .action = .toggle_secure_input,
            .title = i18n.N_("Toggle Secure Input"),
            .description = i18n.N_("Toggle secure input mode."),
        }},

        .toggle_mouse_reporting => comptime &.{.{
            .action = .toggle_mouse_reporting,
            .title = i18n.N_("Toggle Mouse Reporting"),
            .description = i18n.N_("Toggle whether mouse events are reported to terminal applications."),
        }},

        .toggle_background_opacity => comptime &.{.{
            .action = .toggle_background_opacity,
            .title = i18n.N_("Toggle Background Opacity"),
            .description = i18n.N_("Toggle the background opacity of a window that started transparent."),
        }},

        .check_for_updates => comptime &.{.{
            .action = .check_for_updates,
            .title = i18n.N_("Check for Updates"),
            .description = i18n.N_("Check for updates to the application."),
        }},

        .undo => comptime &.{.{
            .action = .undo,
            .title = i18n.N_("Undo"),
            .description = i18n.N_("Undo the last action."),
        }},

        .redo => comptime &.{.{
            .action = .redo,
            .title = i18n.N_("Redo"),
            .description = i18n.N_("Redo the last undone action."),
        }},

        .quit => comptime &.{.{
            .action = .quit,
            .title = i18n.N_("Quit"),
            .description = i18n.N_("Quit the application."),
        }},

        .text => comptime &.{.{
            .action = .{ .text = "👻" },
            .title = i18n.N_("Ghostty"),
            .description = i18n.N_("Put a little Ghostty in your terminal."),
        }},

        // No commands because they're parameterized and there
        // aren't obvious values users would use. It is possible that
        // these may have commands in the future if there are very
        // common values that users tend to use.
        .csi,
        .esc,
        .cursor_key,
        .set_font_size,
        .set_surface_title,
        .set_tab_title,
        .set_window_title,
        .search,
        .scroll_to_row,
        .scroll_page_fractional,
        .scroll_page_lines,
        .adjust_selection,
        .jump_to_prompt,
        .write_scrollback_file,
        .goto_tab,
        .resize_split,
        .activate_key_table,
        .activate_key_table_once,
        .deactivate_key_table,
        .deactivate_all_key_tables,
        .end_key_sequence,
        .crash,
        => comptime &.{},

        // No commands because I'm not sure they make sense in a command
        // palette context.
        .toggle_command_palette,
        .toggle_quick_terminal,
        .toggle_visibility,
        .previous_tab,
        .next_tab,
        .last_tab,
        => comptime &.{},

        // No commands for obvious reasons
        .ignore,
        .unbind,
        => comptime &.{},
    };

    // All generated commands should have the same action as the
    // action passed in.
    for (result) |cmd| assert(cmd.action == action);

    return result;
}

test "palette synonyms name real commands" {
    // **The floor for `windows/host/src/synonyms.txt`.** That file maps words
    // a person is likely to type onto the commands this list publishes -- 20
    // of macOS's 69 menu commands are the same action under a different word,
    // so somebody typing `Find` into the command palette gets nothing because
    // the core calls it `Start Search`.
    //
    // The risk in such a table is not that it breaks anything: a line naming a
    // command that does not exist simply stops matching. The risk is that it
    // is **invisible when stale**, and an index nobody can tell is out of date
    // is one people stop trusting. This test is the only place that can see
    // both sides -- the table is data, and the command list is right here.
    //
    // It deliberately checks the direction that can go wrong. A word nobody
    // types is harmless; a command name that no longer exists is the failure.
    // Read rather than `@embedFile`d: the table lives in the Windows host's
    // crate, which is outside this package, and Zig will not embed across that
    // boundary. The path is relative to the repository root, which is where
    // `zig build test` runs from.
    //
    // **A missing file fails the test rather than skipping it.** A skip here
    // would mean the floor quietly stops existing the first time someone runs
    // the suite from another directory, and nothing would say so.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const table = std.Io.Dir.cwd().readFileAlloc(
        io,
        "windows/host/src/synonyms.txt",
        alloc,
        .limited(64 * 1024),
    ) catch |err| {
        std.debug.print(
            "cannot read windows/host/src/synonyms.txt ({t}). " ++
                "Run `zig build test` from the repository root.\n",
            .{err},
        );
        return error.SynonymTableUnreadable;
    };

    var lines = std.mem.splitScalar(u8, table, '\n');
    var checked: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const title = std.mem.trim(u8, line[eq + 1 ..], " \t\r");

        var found = false;
        for (defaults) |cmd| {
            if (std.mem.eql(u8, cmd.title, title)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print(
                "synonyms.txt names a command this list does not publish: \"{s}\"\n",
                .{title},
            );
            return error.UnknownCommandTitle;
        }
        checked += 1;
    }

    // A table that parsed to nothing would pass every assertion above. **The
    // one number that says the test did any work at all.**
    try std.testing.expect(checked >= 20);
}

test "command defaults" {
    // This just ensures that defaults is analyzed and works.
    const testing = std.testing;
    try testing.expect(defaults.len > 0);
    try testing.expectEqual(defaults.len, defaultsC.len);
}

test "menu labels reach the palette" {
    // **The other half of `synonyms.txt`, and the half a person actually
    // hits.** The test above checks that every synonym names a command that
    // exists. It says nothing about the words that are missing -- and the
    // words most likely to be missing are the ones this host prints on its own
    // menus, because the menu is where somebody learned the word. Measured on
    // the real machine: the menu says «关闭窗口», and typing those four
    // characters into the palette returned nothing, while `close` returned
    // five commands the person had no way to name.
    //
    // **The menu table is the list, and it is read rather than restated.** A
    // second copy of the rows here would be the third hand-written second list
    // this port has been bitten by (`ffi.rs`'s tag constants and
    // `Config.ShellIntegration` were the first two), and it would go stale in
    // exactly the direction that hides the defect: a row added to the menu and
    // forgotten here would be unsearchable and unreported.
    //
    // **Which rows are exempt is computed, not declared.** A row whose action
    // the core publishes no palette command for cannot be searched -- there is
    // nothing to find -- and that is a fact about `defaults` right here, not an
    // exemption list somebody has to maintain.
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const H = struct {
        fn read(i: std.Io, a: Allocator, path: []const u8) ![]const u8 {
            return std.Io.Dir.cwd().readFileAlloc(i, path, a, .limited(256 * 1024)) catch |err| {
                std.debug.print(
                    "cannot read {s} ({t}). Run `zig build test` from the repository root.\n",
                    .{ path, err },
                );
                return error.SourceUnreadable;
            };
        }

        /// Everything a row is allowed to have between its label and its
        /// action: the constructor's comma, whitespace, and the spelled-out
        /// form's `action: Some(`.
        fn gapIsRowPunctuation(gap: []const u8) bool {
            var rest = gap;
            if (std.mem.indexOf(u8, rest, "action: Some(")) |at| {
                for (rest[0..at]) |c| switch (c) {
                    ' ', '\t', '\r', '\n', ',' => {},
                    else => return false,
                };
                rest = rest[at + "action: Some(".len ..];
            }
            for (rest) |c| switch (c) {
                ' ', '\t', '\r', '\n', ',' => {},
                else => return false,
            };
            return true;
        }

        /// Does this look like a binding string rather than prose?
        fn actionShaped(s: []const u8) bool {
            if (s.len == 0) return false;
            for (s) |c| switch (c) {
                'a'...'z', '0'...'9', '_', ':', ',' => {},
                else => return false,
            };
            return true;
        }

        /// The palette's own rule, in one place: a typed word matches when the
        /// table maps it to this title.
        fn synonymNames(table: []const u8, typed: []const u8, title: []const u8) bool {
            var lines = std.mem.splitScalar(u8, table, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0 or line[0] == '#') continue;
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                const left = std.mem.trim(u8, line[0..eq], " \t\r");
                const right = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
                if (std.mem.eql(u8, left, typed) and std.mem.eql(u8, right, title)) return true;
            }
            return false;
        }

        /// Anything the table maps this word to, whatever it is.
        fn synonymHasWord(table: []const u8, typed: []const u8) bool {
            var lines = std.mem.splitScalar(u8, table, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0 or line[0] == '#') continue;
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t\r"), typed)) return true;
            }
            return false;
        }

        /// The title the core publishes for a binding string, or null when it
        /// publishes no command for it.
        ///
        /// **Parsed with the core's own parser and compared by the action's
        /// hash**, not by string. The menu writes some actions in their bare
        /// form -- `copy_to_clipboard` is the core's `copy_to_clipboard:mixed`
        /// -- and matching those by name picked whichever variant happened to
        /// come first in the list: the first version of this test demanded a
        /// synonym for "Copy Selection as ANSI Sequences to Clipboard" because
        /// `copy_to_clipboard:vt` sorted earlier. Parsing resolves the default
        /// the same way the running host does.
        fn titleFor(action: []const u8) ?[]const u8 {
            const parsed = Action.parse(action) catch return null;
            for (defaults) |cmd| {
                if (cmd.action.hash() == parsed.hash()) return cmd.title;
            }
            return null;
        }
    };

    const menu_all = try H.read(io, alloc, "windows/host/src/menu.rs");
    // **The table only.** Below `#[cfg(test)]` are that file's own tests,
    // whose assertion messages are string literals too -- the first version of
    // this test demanded a palette entry for "only {} actions parsed".
    const menu = menu_all[0 .. std.mem.indexOf(u8, menu_all, "#[cfg(test)]") orelse menu_all.len];
    const table = try H.read(io, alloc, "windows/host/src/synonyms.txt");

    // Walk `menu.rs` for `"label", "action"` pairs: two string literals with
    // nothing but the constructor's punctuation between them. That covers
    // `act(...)`, `act_state(...)`, `act_gap(...)`, `toggle(...)` and the
    // spelled-out `Row { label: "...", action: Some("...") }` alike, which is
    // why it is written this way rather than as four patterns to keep in step.
    var rows: usize = 0;
    var required: usize = 0;
    var covered: usize = 0;
    var no_command: usize = 0;

    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, menu, i, '"')) |open1| {
        const close1 = std.mem.indexOfScalarPos(u8, menu, open1 + 1, '"') orelse break;
        const label = menu[open1 + 1 .. close1];
        i = close1 + 1;

        const open2 = std.mem.indexOfScalarPos(u8, menu, i, '"') orelse break;
        // **Only a row's own punctuation may sit between the two strings.**
        // A gap measured in characters alone let a prose string and a nearby
        // action literal pair up; this says what is allowed instead of how far.
        if (!H.gapIsRowPunctuation(menu[close1 + 1 .. open2])) continue;
        const close2 = std.mem.indexOfScalarPos(u8, menu, open2 + 1, '"') orelse break;
        const action = menu[open2 + 1 .. close2];
        if (!H.actionShaped(action)) continue;
        if (label.len == 0 or H.actionShaped(label)) continue; // not a label
        if (std.mem.startsWith(u8, action, "__polter_")) continue; // the host's own

        rows += 1;
        const title = H.titleFor(action) orelse {
            // **Not searchable, and not a defect**: the core publishes no
            // palette command for this action, so there is nothing for a
            // search to land on. Counted so the number is visible.
            no_command += 1;
            continue;
        };
        required += 1;
        if (H.synonymNames(table, label, title)) {
            covered += 1;
        } else {
            std.debug.print(
                "the menu says \"{s}\", and typing it into the palette finds nothing: " ++
                    "synonyms.txt has no `{s} = {s}` line for action `{s}`\n",
                .{ label, label, title, action },
            );
            return error.MenuLabelUnsearchable;
        }
    }

    // **Anchors, because every assertion above is of the form "nothing was
    // missing".** A lookup that always said yes would satisfy all of them.
    try testing.expect(!H.synonymHasWord(table, "not_on_any_menu_zz"));
    try testing.expect(H.synonymHasWord(table, "关闭窗口"));
    try testing.expect(H.synonymNames(table, "关闭窗口", "Close Window"));
    // And the word must be matched to *its own* command, not to any command.
    try testing.expect(!H.synonymNames(table, "关闭窗口", "New Tab"));

    // The counts. A menu table that stopped parsing would report zero rows and
    // satisfy every branch above while reading exactly like a clean run.
    try testing.expect(rows >= 40);
    try testing.expectEqual(required, covered);
    try testing.expect(required >= 35);
    // Six rows name actions the core publishes no command for
    // (`toggle_command_palette`, `toggle_quick_terminal`, and the four
    // `resize_split:<dir>,10`). Pinned so that a seventh has to come here and
    // say why rather than joining them quietly.
    try testing.expectEqual(@as(usize, 6), no_command);
}
