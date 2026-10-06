//! The settings window's General section, as the core hands it to both
//! hosts (dev-docs/poltergeist/settings.md §7.2): a table of settings to
//! draw, and one call that writes one of them into the config file.
//!
//! **Read.** Every config key, with its group, control, choices, default,
//! effective value, help text and -- the part no other code here knows --
//! where the effective value came from. That last one is worked out by
//! scanning the files the loader reads, line by line, in the order it reads
//! them: the default files, the command line, then the `config-file` chain.
//! The chain is followed with the loader's own `RepeatablePath`, so `?`,
//! quotes, `config-file =` clearing the list and relative paths meaning
//! "relative to the file that named it" all behave as they do in `Config`.
//!
//! **Write.** `set(key, value | null)`, §7.2 rules 1-7. The edit itself is
//! `editText`, text in and text out, and is where the tests are.
//!
//! **There is no end-of-line comment.** §7.2 asks for trailing comments to
//! survive an in-place edit, but the config grammar has none:
//! `cli.args.LineIterator` treats `#` as a comment only as the first
//! non-blank character of a line, so in `font-size = 12 # big` the value is
//! `12 # big`. What an in-place edit keeps is everything else on the line --
//! indentation, the spacing around `=`, the quotes, the CR of a CRLF file --
//! and every other byte of the file.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Config = @import("Config.zig");
const Key = @import("key.zig").Key;
const cli = @import("../cli.zig");
const edit = @import("edit.zig");
const file_load = @import("file_load.zig");
const formatter = @import("formatter.zig");
const global = @import("../global.zig");
const help_strings = @import("help_strings");
const i18n = @import("../os/i18n.zig");
const RepeatablePath = @import("path.zig").RepeatablePath;

const log = std.log.scoped(.config_form);

/// The groups of §7.1 that hold a chosen set of keys. "All options" is not
/// one of them: it is every key, and every item is in it.
pub const Group = enum { appearance, font, terminal, window, polter, screenshot };

/// What a host draws for a key. Derived from the field's type by
/// `controlOf` unless the table says otherwise.
pub const Control = enum {
    toggle,
    choice,
    number,
    text,
    font,
    color,
    theme,
    /// A directory: a path box, a button that picks one, and one that shows
    /// it in the file manager. Written like `text`.
    directory,
    /// A repeatable or compound key: shown, never written from the form
    /// (§7.4).
    readonly,
};

pub const Item = struct {
    /// A `Key`, so a misspelt name is a compile error, not an empty row.
    key: Key,
    group: Group,
    /// Only this OS shows it in its group; null is every OS. The one
    /// difference between the hosts §7.1 allows.
    os: ?std.Target.Os.Tag = null,
    control: ?Control = null,
    min: ?f64 = null,
    max: ?f64 = null,
    /// What the form calls it, in English -- a msgid both hosts translate
    /// (mac `Localizable.strings`, Windows `po/`), marked with `i18n.N_` so
    /// `zig build update-translations` puts it in the template. **No default on
    /// purpose**: a row added to the table without one does not compile,
    /// rather than showing a config key where a name should be (#973).
    label: []const u8,
    /// One sentence, at most 60 characters, also a msgid: what the setting
    /// does, shown under it in place of Ghostty's own help text (which the
    /// hosts keep one click away). No default, for the same reason.
    summary: []const u8,
    /// A display name for each value of an enum key, English msgids like
    /// `label` (#977); what is written to the file is still the value.
    /// Null for a key that is not an enum -- and required for one that is:
    /// the check below the table refuses to compile a table whose enum key
    /// leaves a value unnamed or names one the enum does not have.
    choices: ?[]const Choice = null,
    /// A msgid with one `%s` in it, for the choices whose `label` is empty:
    /// the host puts that value in, written the way it writes a shortcut's
    /// modifiers. Only `screenshot-mouse-trigger` has one, because the
    /// names of its values are the names of keys, and those are the host's
    /// to spell (`⌘⇧` on one, `Ctrl+Shift` on the other).
    choice_template: ?[]const u8 = null,
    /// For a `toggle` over a key that is not a bool: the values written for
    /// on and for off. Null for a bool, which is written `true` / `false`.
    on: ?[]const u8 = null,
    off: ?[]const u8 = null,
    /// Extra words the settings search finds this row by (screenshot.md
    /// §12.2): what somebody would type who does not know what the row is
    /// called. **Not msgids** -- they are matched as they are, in whatever
    /// language they are written in, under every interface language.
    aliases: []const []const u8 = &.{},
};

/// A row that shows what an action is bound to. It has no config key of its
/// own to write: the binding is a `keybind` line, and the row says so.
pub const Shortcut = struct {
    group: Group,
    /// The keybind action, as the config file writes it.
    action: []const u8,
    label: []const u8,
    summary: []const u8,
    aliases: []const []const u8 = &.{},
};

/// The shortcut rows, drawn after their group's settings.
pub const shortcuts = [_]Shortcut{
    .{
        .group = .screenshot,
        .action = "screenshot",
        .label = i18n.N_("Screenshot Shortcut"),
        .summary = i18n.N_("Change it with a keybind line in the config file."),
        .aliases = &.{ "screenshot", "hotkey", "keybind", "截图", "截屏", "快捷键", "热键" },
    },
};

/// One value of an enum key and what the form calls it.
pub const Choice = struct {
    value: []const u8,
    label: []const u8,
};

/// The longest `summary` may be: one line under the control at the
/// window's narrowest (settings.md §2.2).
pub const summary_max = 60;

/// The first five groups of §7.1, in the order they are drawn.
pub const table = [_]Item{
    // Appearance
    .{ .key = .theme, .group = .appearance, .label = i18n.N_("Theme"), .summary = i18n.N_("The color theme; light and dark mode can differ.") },
    .{ .key = .@"background-opacity", .group = .appearance, .min = 0, .max = 1, .label = i18n.N_("Background Opacity"), .summary = i18n.N_("1 is fully opaque; lower lets the desktop show through.") },
    .{ .key = .@"background-blur", .group = .appearance, .label = i18n.N_("Background Blur"), .summary = i18n.N_("true, false, a strength, or macos-glass-regular/-clear.") },
    .{ .key = .@"cursor-style", .group = .appearance, .label = i18n.N_("Cursor Style"), .summary = i18n.N_("The cursor's shape; programs in the terminal may change it."), .choices = &.{ .{ .value = "bar", .label = i18n.N_("Bar") }, .{ .value = "block", .label = i18n.N_("Block") }, .{ .value = "underline", .label = i18n.N_("Underline") }, .{ .value = "block_hollow", .label = i18n.N_("Hollow Block") } } },
    .{ .key = .@"cursor-style-blink", .group = .appearance, .label = i18n.N_("Blinking Cursor"), .summary = i18n.N_("Whether the cursor blinks by default.") },
    .{ .key = .@"window-padding-x", .group = .appearance, .label = i18n.N_("Horizontal Padding"), .summary = i18n.N_("Space between the text and the left and right edges.") },
    .{ .key = .@"window-padding-y", .group = .appearance, .label = i18n.N_("Vertical Padding"), .summary = i18n.N_("Space between the text and the top and bottom edges.") },
    .{ .key = .@"window-padding-balance", .group = .appearance, .label = i18n.N_("Balance Padding"), .summary = i18n.N_("Spread leftover space evenly around the text."), .choices = &.{ .{ .value = "false", .label = i18n.N_("No Balancing") }, .{ .value = "true", .label = i18n.N_("Balanced, Top Capped") }, .{ .value = "equal", .label = i18n.N_("Equal on All Sides") } } },
    .{ .key = .@"macos-titlebar-style", .group = .appearance, .os = .macos, .label = i18n.N_("Title Bar Style"), .summary = i18n.N_("Native, transparent, tabs, or hidden."), .choices = &.{ .{ .value = "native", .label = i18n.N_("Native") }, .{ .value = "transparent", .label = i18n.N_("Transparent") }, .{ .value = "tabs", .label = i18n.N_("Tabs in Title Bar") }, .{ .value = "hidden", .label = i18n.N_("Hidden") } } },

    // Font
    .{ .key = .@"font-family", .group = .font, .control = .font, .label = i18n.N_("Font"), .summary = i18n.N_("The font family to use; empty uses the default.") },
    .{ .key = .@"font-size", .group = .font, .min = 1, .label = i18n.N_("Font Size"), .summary = i18n.N_("In points; may be fractional."), .aliases = &.{ "size", "text size", "字号", "大小", "字体大小", "文字大小" } },
    .{ .key = .@"adjust-cell-height", .group = .font, .label = i18n.N_("Line Height"), .summary = i18n.N_("Extra height per line, in points or percent (e.g. 20%).") },

    // Terminal
    .{ .key = .@"scrollback-limit-lines", .group = .terminal, .label = i18n.N_("Scrollback Lines"), .summary = i18n.N_("How many lines of history each terminal keeps.") },
    .{ .key = .@"copy-on-select", .group = .terminal, .label = i18n.N_("Copy on Select"), .summary = i18n.N_("Copy selected text to the clipboard automatically."), .choices = &.{ .{ .value = "none", .label = i18n.N_("Don't Copy") }, .{ .value = "primary", .label = i18n.N_("Selection Pasteboard Only") }, .{ .value = "clipboard", .label = i18n.N_("Clipboard Only") }, .{ .value = "both", .label = i18n.N_("Both") } } },
    .{ .key = .@"clipboard-read", .group = .terminal, .label = i18n.N_("Clipboard Reading"), .summary = i18n.N_("Whether programs may read the clipboard: ask, allow or deny."), .choices = &.{ .{ .value = "ask", .label = i18n.N_("Ask") }, .{ .value = "allow", .label = i18n.N_("Allow") }, .{ .value = "deny", .label = i18n.N_("Deny") } } },
    .{ .key = .@"clipboard-write", .group = .terminal, .label = i18n.N_("Clipboard Writing"), .summary = i18n.N_("Whether programs may set the clipboard: ask, allow or deny."), .choices = &.{ .{ .value = "ask", .label = i18n.N_("Ask") }, .{ .value = "allow", .label = i18n.N_("Allow") }, .{ .value = "deny", .label = i18n.N_("Deny") } } },
    .{ .key = .@"mouse-hide-while-typing", .group = .terminal, .label = i18n.N_("Hide Pointer While Typing"), .summary = i18n.N_("Hide the mouse pointer while you type in a terminal.") },
    .{ .key = .@"confirm-close-surface", .group = .terminal, .label = i18n.N_("Confirm Before Closing"), .summary = i18n.N_("Ask before closing a terminal still running something."), .choices = &.{ .{ .value = "false", .label = i18n.N_("Don't Confirm") }, .{ .value = "true", .label = i18n.N_("When Something Is Running") }, .{ .value = "always", .label = i18n.N_("Always Confirm") } } },
    .{ .key = .@"shell-integration", .group = .terminal, .label = i18n.N_("Shell Integration"), .summary = i18n.N_("Lets the shell report its directory and prompt to Polter."), .choices = &.{ .{ .value = "detect", .label = i18n.N_("Detect Automatically") }, .{ .value = "none", .label = i18n.N_("No Integration") }, .{ .value = "bash", .label = i18n.N_("Bash") }, .{ .value = "elvish", .label = i18n.N_("Elvish") }, .{ .value = "fish", .label = i18n.N_("fish") }, .{ .value = "nushell", .label = i18n.N_("Nushell") }, .{ .value = "powershell", .label = i18n.N_("PowerShell") }, .{ .value = "zsh", .label = i18n.N_("Zsh") } } },

    // Windows and tabs
    .{ .key = .@"window-save-state", .group = .window, .label = i18n.N_("Restore Windows"), .summary = i18n.N_("Reopen windows, tabs and splits where they were."), .choices = &.{ .{ .value = "default", .label = i18n.N_("System Default") }, .{ .value = "never", .label = i18n.N_("Never") }, .{ .value = "always", .label = i18n.N_("Always") } } },
    .{ .key = .@"window-inherit-working-directory", .group = .window, .label = i18n.N_("New Windows Inherit Directory"), .summary = i18n.N_("New windows start in the focused window's directory.") },
    .{ .key = .@"quit-after-last-window-closed", .group = .window, .label = i18n.N_("Quit After Last Window Closes"), .summary = i18n.N_("Quit Polter when its last window is closed.") },
    .{ .key = .@"window-decoration", .group = .window, .label = i18n.N_("Window Decorations"), .summary = i18n.N_("Whether windows have a title bar and borders."), .choices = &.{ .{ .value = "auto", .label = i18n.N_("Automatic") }, .{ .value = "client", .label = i18n.N_("Drawn by Polter") }, .{ .value = "server", .label = i18n.N_("Drawn by the System") }, .{ .value = "none", .label = i18n.N_("No Decorations") } } },

    // Polter
    .{ .key = .@"poltergeist-notice-interval", .group = .polter, .label = i18n.N_("Notice Interval"), .summary = i18n.N_("How often the supervisor is handed what it has not seen.") },
    .{ .key = .@"poltergeist-quiescence-after", .group = .polter, .label = i18n.N_("Quiet After"), .summary = i18n.N_("How long a screen must stay unchanged to count as quiet.") },
    .{ .key = .@"poltergeist-quiescence-repeat", .group = .polter, .label = i18n.N_("Repeat Quiet Report"), .summary = i18n.N_("How long before a still-quiet terminal is reported again.") },
    .{ .key = .@"poltergeist-worker-nudge-after", .group = .polter, .label = i18n.N_("Nudge Workers After"), .summary = i18n.N_("How long a worker may sit still before it is told to report.") },
    .{ .key = .@"poltergeist-calls-silent-after", .group = .polter, .label = i18n.N_("Tool Silence Reminder"), .summary = i18n.N_("How long without a Polter tool call before it is mentioned.") },
    .{ .key = .@"poltergeist-task-idle-after", .group = .polter, .label = i18n.N_("Idle Task Reminder"), .summary = i18n.N_("How long a task may go untouched before it is mentioned.") },
    .{ .key = .@"poltergeist-group-quiet-after", .group = .polter, .label = i18n.N_("Quiet Group Reminder"), .summary = i18n.N_("How long a group may be silent before it is mentioned.") },
    .{ .key = .@"poltergeist-notify-window", .group = .polter, .label = i18n.N_("Hours I May Be Disturbed"), .summary = i18n.N_("When you may be asked, as HH:MM-HH:MM; empty is any time.") },
    .{ .key = .@"poltergeist-supervisor-stand-down", .group = .polter, .label = i18n.N_("Supervisor May Stand Down"), .summary = i18n.N_("Let a supervisor whose work is done take itself off duty.") },
    .{ .key = .@"poltergeist-chat-log", .group = .polter, .label = i18n.N_("Keep Chat Log"), .summary = i18n.N_("Write what the terminals say to each other to disk.") },
    .{ .key = .@"poltergeist-terminal-log", .group = .polter, .label = i18n.N_("Keep Terminal Transcripts"), .summary = i18n.N_("Keep a transcript of what ran in each terminal.") },
    .{ .key = .language, .group = .polter, .label = i18n.N_("Language"), .summary = i18n.N_("The interface language; empty follows the system.") },

    // Screenshot (screenshot.md §12.1)
    .{ .key = .@"clipboard-paste-image", .group = .screenshot, .label = i18n.N_("Paste Images as Files"), .summary = i18n.N_("Save a pasted image as a file and paste its path."), .aliases = &.{ "screenshot", "image", "picture", "paste", "clipboard", "截图", "截屏", "图片", "粘贴", "剪贴板" } },
    .{ .key = .@"screenshot-directory", .group = .screenshot, .control = .directory, .label = i18n.N_("Screenshot Folder"), .summary = i18n.N_("Where screenshots and pasted images are saved."), .aliases = &.{ "screenshot", "capture", "folder", "directory", "path", "save", "截图", "截屏", "保存", "目录", "文件夹", "位置" } },
    .{ .key = .@"screenshot-mouse-trigger", .group = .screenshot, .control = .choice, .label = i18n.N_("Mouse Trigger"), .summary = i18n.N_("Hold these keys and click to take a screenshot."), .choices = &.{
        .{ .value = "none", .label = i18n.N_("Off") },
        .{ .value = "super+shift", .label = "" },
        .{ .value = "ctrl+shift", .label = "" },
        .{ .value = "alt+shift", .label = "" },
        .{ .value = "super+alt", .label = "" },
        .{ .value = "ctrl+alt", .label = "" },
        .{ .value = "super+ctrl", .label = "" },
    }, .choice_template = i18n.N_("%s + Click"), .aliases = &.{ "screenshot", "capture", "mouse", "click", "double-click", "double click", "截图", "截屏", "鼠标", "单击", "点击", "双击" } },
    .{ .key = .@"screenshot-agent-access", .group = .screenshot, .control = .toggle, .on = "allow", .off = "deny", .label = i18n.N_("Let Agents Take Screenshots"), .summary = i18n.N_("Agents may capture the screen with the screenshot tools."), .choices = &.{
        .{ .value = "allow", .label = i18n.N_("Allow") },
        .{ .value = "deny", .label = i18n.N_("Deny") },
    }, .aliases = &.{ "screenshot", "capture", "agent", "mcp", "permission", "截图", "截屏", "权限", "允许" } },
};

comptime {
    // A key in two groups would be drawn twice and written from both.
    @setEvalBranchQuota(100_000);
    for (table, 0..) |a, i| for (table[i + 1 ..]) |b| {
        if (a.key == b.key) @compileError("config form: key in the table twice: " ++ @tagName(a.key));
    };
}

comptime {
    // Every enum key in the table names each of its values, and only
    // those (#977): a value without a name would be shown to the person
    // as the raw word, and a name for a value that no longer exists would
    // be a translation nothing uses.
    @setEvalBranchQuota(100_000);
    for (table) |item| {
        const T = @FieldType(Config, @tagName(item.key));
        const control = item.control orelse controlOf(T);
        const is_enum = @typeInfo(Unwrapped(T)) == .@"enum";

        // A toggle writes `true` / `false` unless the row says what on and
        // off are, and a row may only say so with both.
        if ((item.on == null) != (item.off == null))
            @compileError("config form: `on` without `off`, or the reverse: " ++ @tagName(item.key));
        if (item.on != null and control != .toggle)
            @compileError("config form: on/off values on a row that is not a toggle: " ++ @tagName(item.key));
        if (control == .toggle and @typeInfo(Unwrapped(T)) != .bool and item.on == null)
            @compileError("config form: a toggle over a key that is not a bool needs on/off values: " ++ @tagName(item.key));
        if (item.choice_template != null and control != .choice)
            @compileError("config form: a choice template on a row that is not a choice: " ++ @tagName(item.key));

        if (control != .choice and !(control == .toggle and is_enum)) {
            if (item.choices != null) @compileError("config form: choices named for a key that is not an enum: " ++ @tagName(item.key));
            continue;
        }
        const names = item.choices orelse
            @compileError("config form: enum key without choice names: " ++ @tagName(item.key));
        for (names) |c| {
            if (c.label.len == 0 and item.choice_template == null)
                @compileError("config form: " ++ @tagName(item.key) ++ " has a value with no name and no template: " ++ c.value);
        }
        // A choice over a key that is not an enum lists its own values;
        // there is no type to hold them against here. The test
        // "config form: every listed value of a free choice is one the key
        // accepts" parses each of them instead.
        if (!is_enum) continue;
        const fields = std.meta.fields(Unwrapped(T));
        for (fields) |f| {
            var found = false;
            for (names) |c| {
                if (std.mem.eql(u8, c.value, f.name)) found = true;
            }
            if (!found) @compileError("config form: " ++ @tagName(item.key) ++ " has no name for its value " ++ f.name);
        }
        for (names) |c| {
            var found = false;
            for (fields) |f| {
                if (std.mem.eql(u8, c.value, f.name)) found = true;
            }
            if (!found) @compileError("config form: " ++ @tagName(item.key) ++ " names a value it does not have: " ++ c.value);
        }
    }
}

/// The marker line of the block new keys are appended under (§7.2 rule 3).
pub const block_marker = "# --- 由 Polter 设置窗口写入，可以手改 ---";

/// Suffix of the one backup taken before the first write of each run.
pub const backup_suffix = ".polter-bak";

// ------------------------------------------------------------ types

/// Keys whose lines add up rather than replace one another. Replacing
/// "the effective line" of one of these changes one entry of a list, which
/// is not what a single text box says it does, so the form never writes
/// them (§7.4). `font-family` is the one exception, and only while it is a
/// single line; see `Reason.multiple`.
fn isRepeatable(comptime U: type) bool {
    const list = .{
        @FieldType(Config, "font-family"), // RepeatableString
        @FieldType(Config, "config-file"), // RepeatablePath
        @FieldType(Config, "font-variation"),
        @FieldType(Config, "font-codepoint-map"),
        @FieldType(Config, "clipboard-codepoint-map"),
        @FieldType(Config, "palette"),
        @FieldType(Config, "env"),
        @FieldType(Config, "input"),
        @FieldType(Config, "keybind"),
        @FieldType(Config, "key-remap"),
        @FieldType(Config, "link"),
        @FieldType(Config, "command-palette-entry"),
    };
    inline for (list) |T| if (U == T) return true;
    return false;
}

fn Unwrapped(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

pub fn controlOf(comptime T: type) Control {
    const U = Unwrapped(T);
    if (isRepeatable(U)) return .readonly;
    if (U == Config.Color) return .color;
    if (U == Config.Theme) return .theme;
    return switch (@typeInfo(U)) {
        .bool => .toggle,
        .@"enum" => .choice,
        .int, .float => .number,
        else => .text,
    };
}

fn itemFor(comptime key: Key) ?Item {
    inline for (table) |item| if (item.key == key) return item;
    return null;
}

// ------------------------------------------------------------ lines

/// One setting line of a config file, as `cli.args.LineIterator` reads it.
pub const Line = struct {
    /// 1-based, counting every line including blanks and comments.
    number: u32,
    /// The line's first byte and the index of its `\n` (or the text's end).
    start: usize,
    end: usize,
    key: []const u8,
    /// The value as written, trimmed, quotes included. Null when the line
    /// has no `=`.
    value: ?Span,

    pub const Span = struct { start: usize, end: usize };

    /// The value as the loader hands it to the parser: one pair of
    /// surrounding quotes removed.
    pub fn decoded(self: Line, text: []const u8) ?[]const u8 {
        const s = self.value orelse return null;
        const v = text[s.start..s.end];
        if (isQuoted(v)) return v[1 .. v.len - 1];
        return v;
    }
};

fn isQuoted(v: []const u8) bool {
    return v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"';
}

/// Setting lines only; blank lines and `#` lines are stepped over. The
/// trimming is `LineIterator`'s: whitespace and CR off both ends of the
/// line, whitespace off both sides of the `=`.
pub const LineIterator = struct {
    text: []const u8,
    pos: usize = 0,
    number: u32 = 0,

    const ws = cli.args.whitespace;

    pub fn next(self: *LineIterator) ?Line {
        while (self.pos < self.text.len) {
            const start = self.pos;
            const end = std.mem.indexOfScalarPos(u8, self.text, start, '\n') orelse self.text.len;
            self.pos = end + 1;
            self.number += 1;

            // A UTF-8 byte order mark is skipped by the loader.
            var from = start;
            if (start == 0 and std.mem.startsWith(u8, self.text, "\xef\xbb\xbf")) from = 3;

            const lead = std.mem.trimStart(u8, self.text[from..end], ws ++ "\r");
            const body_start = end - lead.len;
            const body = std.mem.trimEnd(u8, lead, ws ++ "\r");
            const body_end = body_start + body.len;
            if (body.len == 0 or body[0] == '#') continue;

            const eq = std.mem.indexOfScalar(u8, body, '=') orelse return .{
                .number = self.number,
                .start = start,
                .end = end,
                .key = body,
                .value = null,
            };
            const key = std.mem.trim(u8, body[0..eq], ws);
            const after = body[eq + 1 ..];
            const v = std.mem.trimStart(u8, after, ws);
            const v_start = body_start + eq + 1 + (after.len - v.len);
            return .{
                .number = self.number,
                .start = start,
                .end = end,
                .key = key,
                .value = .{ .start = v_start, .end = body_end },
            };
        }
        return null;
    }
};

// ------------------------------------------------------------ edit

pub const EditError = error{ValueSpansLines} || Allocator.Error;

/// The main file's text with `key` set to `value`, or with every line of
/// `key` removed when `value` is null (§7.2 rules 2, 3, 5). Only the bytes
/// of the value change on an in-place edit; the last line of the key is the
/// one edited, because it is the one the loader keeps.
///
/// `value` is the value as the parser should see it; it is quoted here
/// when writing it bare would read back differently.
pub fn editText(
    alloc: Allocator,
    text: []const u8,
    key: []const u8,
    value: ?[]const u8,
) EditError![]u8 {
    if (value) |v| if (std.mem.indexOfAny(u8, v, "\r\n") != null)
        return error.ValueSpansLines;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    const v = value orelse {
        // Restore the default: every line of the key goes, with its `\n`.
        var it: LineIterator = .{ .text = text };
        var copied: usize = 0;
        while (it.next()) |line| {
            if (!std.mem.eql(u8, line.key, key)) continue;
            try out.appendSlice(alloc, text[copied..line.start]);
            copied = @min(line.end + 1, text.len);
        }
        try out.appendSlice(alloc, text[copied..]);
        return try out.toOwnedSlice(alloc);
    };

    var last: ?Line = null;
    var it: LineIterator = .{ .text = text };
    while (it.next()) |line| {
        if (std.mem.eql(u8, line.key, key)) last = line;
    }

    if (last) |line| {
        if (line.value) |span| {
            const quote = isQuoted(text[span.start..span.end]);
            try out.appendSlice(alloc, text[0..span.start]);
            try appendValue(alloc, &out, v, quote);
            try out.appendSlice(alloc, text[span.end..]);
        } else {
            // A bare `key`: the value goes straight after the key.
            const key_at = std.mem.indexOfPos(u8, text, line.start, key).?;
            const key_end = key_at + key.len;
            try out.appendSlice(alloc, text[0..key_end]);
            try out.appendSlice(alloc, " = ");
            try appendValue(alloc, &out, v, false);
            try out.appendSlice(alloc, text[key_end..]);
        }
        return try out.toOwnedSlice(alloc);
    }

    // Not in the file: under the marker at the end, in the file's own line
    // ending.
    const eol: []const u8 = eol: {
        const nl = std.mem.indexOfScalar(u8, text, '\n') orelse break :eol "\n";
        break :eol if (nl > 0 and text[nl - 1] == '\r') "\r\n" else "\n";
    };
    try out.appendSlice(alloc, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out.appendSlice(alloc, eol);
    if (!hasMarker(text)) {
        if (text.len > 0) try out.appendSlice(alloc, eol);
        try out.appendSlice(alloc, block_marker);
        try out.appendSlice(alloc, eol);
    }
    try out.appendSlice(alloc, key);
    try out.appendSlice(alloc, " = ");
    try appendValue(alloc, &out, v, false);
    try out.appendSlice(alloc, eol);
    return try out.toOwnedSlice(alloc);
}

fn hasMarker(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (std.mem.eql(u8, std.mem.trim(u8, l, " \t\r"), block_marker)) return true;
    }
    return false;
}

/// Quote when the bare form would not read back as `v`: the loader trims
/// whitespace and removes one pair of surrounding quotes.
fn appendValue(alloc: Allocator, out: *std.ArrayList(u8), v: []const u8, quote_anyway: bool) !void {
    const trimmed = std.mem.trim(u8, v, cli.args.whitespace);
    const quote = quote_anyway or trimmed.len != v.len or isQuoted(v);
    if (quote) try out.append(alloc, '"');
    try out.appendSlice(alloc, v);
    if (quote) try out.append(alloc, '"');
}

// ------------------------------------------------------------ validate

/// Rule 1: the value through the loader's own parser, on a default config.
/// Null when it parses; otherwise the loader's message, which is what a
/// config-errors list would have said about the same line.
pub fn validate(alloc: Allocator, key: []const u8, value: []const u8) !?[]u8 {
    if (std.mem.indexOfAny(u8, value, "\r\n") != null)
        return try alloc.dupe(u8, "a value cannot span lines");

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    const arg = try std.fmt.allocPrint(alloc, "--{s}={s}", .{ key, value });
    defer alloc.free(arg);
    var it = cli.args.sliceIterator(&.{arg});
    try cfg.loadIter(alloc, &it);

    const diags = cfg._diagnostics.items();
    if (diags.len == 0) return null;
    var w: std.Io.Writer.Allocating = .init(alloc);
    errdefer w.deinit();
    diags[0].format(&w.writer) catch return error.OutOfMemory;
    return try w.toOwnedSlice();
}

// ------------------------------------------------------------ sources

/// One place the loader reads settings from, in the order it reads them.
pub const Layer = struct {
    /// The file; null for the command line.
    path: ?[]const u8,
    text: []const u8 = "",
    args: []const []const u8 = &.{},
};

/// Where the loader's last word on a key was said.
pub const Hit = struct {
    layer: usize,
    /// 1-based line in a file; 1-based argument index on the command line.
    line: u32,
};

pub const Scan = struct {
    layers: []const Layer,
    /// The layer that is the main file, if the loader reads it.
    main: ?usize,
    /// Every key's last hit and how many lines set it, across all layers.
    hits: std.StringHashMapUnmanaged(Tally),

    pub const Tally = struct { last: Hit, count: u32 };

    pub fn get(self: *const Scan, key: []const u8) ?Tally {
        return self.hits.get(key);
    }
};

/// What the loader reads, before anything is read: the main file, the
/// default files in loading order, the command line and the directory the
/// command line's relative paths are relative to.
pub const Context = struct {
    main_path: []const u8,
    defaults: []const []const u8,
    args: []const []const u8,
    cwd: []const u8,
    /// `defaults` is the one file the host loaded in their place, which
    /// `config-default-files = false` does not drop (`Config.discardDefaultFiles`).
    explicit: bool = false,

    /// The files the host that loaded `origin` reads, in this process.
    /// Everything is allocated in `arena`.
    pub fn current(arena: Allocator, origin: Config.Origin) !Context {
        var argv: std.ArrayList([]const u8) = .empty;
        if (origin.cli) {
            var iter = try cli.args.argsIterator(arena, global.args());
            defer iter.deinit();
            while (iter.next()) |arg| {
                // Everything after `-e` is the command, not config.
                if (std.mem.eql(u8, arg, "-e")) break;
                try argv.append(arena, try arena.dupe(u8, arg));
            }
        }

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.cwd().realPathFile(global.io(), ".", &buf);
        const cwd = try arena.dupe(u8, buf[0..n]);

        // A host that loaded one file of its own never reads the default
        // ones, so they are not even looked up.
        if (origin.file != null) return try fromOrigin(arena, origin, undefined, argv.items, cwd);

        var defaults: std.ArrayList([]const u8) = .empty;
        // `Config.loadDefaultFiles`' order.
        try defaults.append(arena, try file_load.legacyDefaultXdgPath(arena));
        try defaults.append(arena, try file_load.defaultXdgPath(arena));
        if (comptime builtin.os.tag == .macos) {
            try defaults.append(arena, try file_load.legacyDefaultAppSupportPath(arena));
            try defaults.append(arena, try file_load.preferredAppSupportPath(arena));
        }
        return try fromOrigin(arena, origin, .{
            .main = (try edit.configPath(arena)).name,
            .files = defaults.items,
        }, argv.items, cwd);
    }

    /// The default files and which of them the form writes: the answer
    /// when the host loaded the default files.
    pub const Defaults = struct {
        main: []const u8,
        files: []const []const u8,
    };

    /// `current` without the process: what `origin` means given where the
    /// default files are. `defaults` is not read when `origin.file` is set.
    pub fn fromOrigin(
        arena: Allocator,
        origin: Config.Origin,
        defaults: Defaults,
        argv: []const []const u8,
        cwd: []const u8,
    ) Allocator.Error!Context {
        const args = if (origin.cli) argv else &.{};
        if (origin.file) |f| {
            const files = try arena.alloc([]const u8, 1);
            files[0] = f;
            return .{ .main_path = f, .defaults = files, .args = args, .cwd = cwd, .explicit = true };
        }
        return .{ .main_path = defaults.main, .defaults = defaults.files, .args = args, .cwd = cwd };
    }
};

/// A config loaded the way the host that produced `origin` loaded its own
/// (the calls `Ghostty.Config.loadConfig` makes on the mac, and the Windows
/// host's), so the form's values are the ones that host would show.
pub fn loadLike(alloc: Allocator, origin: Config.Origin) !Config {
    return loadLikeWith(alloc, origin, null);
}

/// `loadLike` with the command line given; null reads the process's own.
fn loadLikeWith(alloc: Allocator, origin: Config.Origin, argv: ?[]const []const u8) !Config {
    var cfg = try Config.default(alloc);
    errdefer cfg.deinit();
    // **Before anything is loaded** (#984): reading the command line asks
    // it whether what came before was the host's own file
    // (`Config.discardDefaultFiles`). Set after, under
    // `--config-default-files=false` the override was thrown away and the
    // form showed the old values while writing the new ones -- the order
    // `ghostty_config_load_file` then `_load_cli_args` has on the host.
    cfg._origin = .{
        .file = if (origin.file) |f| try cfg.arenaAlloc().dupeZ(u8, f) else null,
        .cli = origin.cli,
    };
    if (origin.file) |f| {
        cfg.loadFile(alloc, f) catch |err| log.warn("config form: cannot load {s}: {t}", .{ f, err });
    } else try cfg.loadDefaultFiles(alloc);
    if (origin.cli) {
        if (argv) |a| {
            var it = cli.args.sliceIterator(a);
            try cfg.loadCliIter(alloc, &it);
        } else try cfg.loadCliArgs(alloc);
    }
    try cfg.loadRecursiveFiles(alloc);
    try cfg.finalize();
    // What `ghostty_config_finalize` adds after `finalize`.
    @import("../font/main.zig").family_check.diagnose(&cfg) catch |err|
        log.warn("config form: cannot check font-family: {t}", .{err});
    return cfg;
}

const max_file_bytes = 16 * 1024 * 1024;

/// Read every layer the loader would, following `config-file` the way
/// `Config.loadRecursiveFiles` does, and tally every key. All of it lives
/// in `arena`.
pub fn gather(arena: Allocator, io: std.Io, ctx: Context) !Scan {
    var layers: std.ArrayList(Layer) = .empty;
    var main: ?usize = null;
    var includes: RepeatablePath = .{};
    var diags: cli.DiagnosticList = .{};

    // `config-default-files = false` on the command line drops the default
    // files and what they asked for (`Config.loadCliArgs`).
    var use_defaults = true;
    if (!ctx.explicit) for (ctx.args) |arg| {
        const k, const v = splitArg(arg) orelse continue;
        if (!std.mem.eql(u8, k, "config-default-files")) continue;
        use_defaults = if (v) |s| cli.args.parseBool(s) catch use_defaults else true;
    };

    if (use_defaults) {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (ctx.defaults) |path| {
            if ((try seen.fetchPut(arena, path, {})) != null) continue;
            const text = readOptional(arena, io, path) orelse continue;
            if (main == null and std.mem.eql(u8, path, ctx.main_path)) main = layers.items.len;
            try layers.append(arena, .{ .path = path, .text = text });
            try feedIncludes(arena, &includes, &diags, text, std.fs.path.dirname(path) orelse "/");
        }
    }

    try layers.append(arena, .{ .path = null, .args = ctx.args });
    for (ctx.args) |arg| {
        const k, const v = splitArg(arg) orelse continue;
        if (!std.mem.eql(u8, k, "config-file")) continue;
        includes.parseCLI(arena, v) catch continue;
    }
    includes.expand(arena, ctx.cwd, &diags) catch {};

    var loaded: std.StringHashMapUnmanaged(void) = .empty;
    var i: usize = 0;
    while (i < includes.value.items.len) : (i += 1) {
        const path = switch (includes.value.items[i]) {
            .optional, .required => |p| p,
        };
        if (path.len == 0 or !std.fs.path.isAbsolute(path)) continue;
        if ((try loaded.fetchPut(arena, path, {})) != null) continue;
        const text = readOptional(arena, io, path) orelse continue;
        try layers.append(arena, .{ .path = path, .text = text });
        try feedIncludes(arena, &includes, &diags, text, std.fs.path.dirname(path) orelse "/");
    }

    var hits: std.StringHashMapUnmanaged(Scan.Tally) = .empty;
    for (layers.items, 0..) |layer, li| {
        if (layer.path == null) {
            for (layer.args, 0..) |arg, ai| {
                const k, _ = splitArg(arg) orelse continue;
                try tally(arena, &hits, k, .{ .layer = li, .line = @intCast(ai + 1) });
            }
            continue;
        }
        var it: LineIterator = .{ .text = layer.text };
        while (it.next()) |line| try tally(arena, &hits, line.key, .{ .layer = li, .line = line.number });
    }

    return .{ .layers = layers.items, .main = main, .hits = hits };
}

fn tally(arena: Allocator, hits: *std.StringHashMapUnmanaged(Scan.Tally), key: []const u8, hit: Hit) !void {
    const gop = try hits.getOrPut(arena, key);
    if (gop.found_existing) {
        gop.value_ptr.* = .{ .last = hit, .count = gop.value_ptr.count + 1 };
    } else {
        gop.value_ptr.* = .{ .last = hit, .count = 1 };
    }
}

fn feedIncludes(
    arena: Allocator,
    includes: *RepeatablePath,
    diags: *cli.DiagnosticList,
    text: []const u8,
    base: []const u8,
) !void {
    var it: LineIterator = .{ .text = text };
    while (it.next()) |line| {
        if (!std.mem.eql(u8, line.key, "config-file")) continue;
        includes.parseCLI(arena, line.decoded(text)) catch continue;
    }
    if (std.fs.path.isAbsolute(base)) includes.expand(arena, base, diags) catch {};
}

/// `--key=value` as the parser splits it; null for anything that is not a
/// flag.
fn splitArg(arg: []const u8) ?struct { []const u8, ?[]const u8 } {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const body = arg[2..];
    if (std.mem.indexOfScalar(u8, body, '=')) |eq| return .{ body[0..eq], body[eq + 1 ..] };
    return .{ body, null };
}

fn readOptional(arena: Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch |err| {
        if (err != error.FileNotFound) log.warn("config form: cannot read {s}: {t}", .{ path, err });
        return null;
    };
}

/// Why the form may not write a key. Null in `Resolved.readonly` is
/// "writable"; every non-null one is shown read-only with its source.
pub const Reason = enum {
    /// A list-like key (§7.4).
    repeatable,
    /// `font-family` on more than one line: one text box cannot say which.
    multiple,
    /// The command line has the last word; a file edit would change nothing.
    cli,
    /// A file other than the main one has the last word (rule 4).
    file,
};

pub const Resolved = struct {
    tally: ?Scan.Tally,
    readonly: ?Reason,
};

pub fn resolve(scan: *const Scan, comptime key: Key) Resolved {
    const name = @tagName(key);
    const control = comptime if (itemFor(key)) |it| it.control orelse controlOf(@FieldType(Config, name)) else controlOf(@FieldType(Config, name));
    const t = scan.get(name);
    const reason: ?Reason = reason: {
        if (control == .readonly) break :reason .repeatable;
        const tl = t orelse break :reason null;
        if (control == .font and tl.count > 1) break :reason .multiple;
        const layer = scan.layers[tl.last.layer];
        if (layer.path == null) break :reason .cli;
        if (scan.main == null or tl.last.layer != scan.main.?) break :reason .file;
        break :reason null;
    };
    return .{ .tally = t, .readonly = reason };
}

fn writeSource(w: *std.Io.Writer, scan: *const Scan, t: ?Scan.Tally) !void {
    const tl = t orelse return w.writeAll("{\"kind\":\"default\"}");
    const layer = scan.layers[tl.last.layer];
    if (layer.path) |p| {
        if (scan.main != null and tl.last.layer == scan.main.?) {
            try w.print("{{\"kind\":\"main\",\"path\":{f},\"line\":{d}}}", .{ std.json.fmt(p, .{}), tl.last.line });
        } else {
            try w.print("{{\"kind\":\"file\",\"path\":{f},\"line\":{d}}}", .{ std.json.fmt(p, .{}), tl.last.line });
        }
    } else {
        try w.print("{{\"kind\":\"cli\",\"arg\":{d}}}", .{tl.last.line});
    }
}

// ------------------------------------------------------------ read

/// The whole table as JSON (§7.2 "read"). `cfg` is the effective config,
/// loaded the way the host loads it (`loadLike`); `def` is the default one.
///
///     {"main": path, "backup": path|null, "errors": [string],
///      "sections": [{"group": g, "keys": [key],
///                    "shortcuts": [{"action", "label", "summary", "aliases": [s]}]}],
///      "items": [{"key", "group": g|null, "control", "choices": [s]|null,
///                 "choice_labels": [s|null]|null, "choice_template": s|null,
///                 "on": s|null, "off": s|null, "aliases": [s],
///                 "min"|null, "max"|null, "default", "value", "doc"|null,
///                 "source": {"kind": "default"|"main"|"file"|"cli", ...},
///                 "readonly": null|"repeatable"|"multiple"|"cli"|"file"}]}
///
/// `value` and `default` are written the way the config file writes them;
/// a repeatable key's lines are joined with `\n`. `items` is every key --
/// the "All options" group -- and `sections` orders the chosen ones.
pub fn writeJson(
    alloc: Allocator,
    w: *std.Io.Writer,
    scan: *const Scan,
    main_path: []const u8,
    backup: ?[]const u8,
    cfg: *const Config,
    def: *const Config,
) !void {
    @setEvalBranchQuota(100_000);
    try w.print("{{\"main\":{f},\"backup\":", .{std.json.fmt(main_path, .{})});
    if (backup) |b| try w.print("{f}", .{std.json.fmt(b, .{})}) else try w.writeAll("null");

    try w.writeAll(",\"errors\":[");
    for (cfg._diagnostics.items(), 0..) |*d, i| {
        if (i > 0) try w.writeAll(",");
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try d.format(&buf.writer);
        try w.print("{f}", .{std.json.fmt(buf.written(), .{})});
    }

    try w.writeAll("],\"sections\":[");
    var first_group = true;
    inline for (std.meta.fields(Group)) |g| {
        const group: Group = @enumFromInt(g.value);
        if (!first_group) try w.writeAll(",");
        first_group = false;
        try w.print("{{\"group\":\"{s}\",\"keys\":[", .{g.name});
        var first = true;
        inline for (table) |item| if (item.group == group and shownHere(item)) {
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("\"{s}\"", .{@tagName(item.key)});
        };
        // The rows of this group that show a binding rather than a setting.
        try w.writeAll("],\"shortcuts\":[");
        var first_shortcut = true;
        inline for (shortcuts) |s| if (s.group == group) {
            if (!first_shortcut) try w.writeAll(",");
            first_shortcut = false;
            try w.print("{{\"action\":\"{s}\",\"label\":{f},\"summary\":{f},\"aliases\":", .{
                s.action,
                std.json.fmt(s.label, .{}),
                std.json.fmt(s.summary, .{}),
            });
            try writeStrings(w, s.aliases);
            try w.writeAll("}");
        };
        try w.writeAll("]}");
    }

    try w.writeAll("],\"items\":[");
    var first_item = true;
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;
        if (!first_item) try w.writeAll(",");
        first_item = false;
        try writeItem(field.name, field.type, alloc, w, scan, cfg, def);
    }
    try w.writeAll("]}");
}

fn writeStrings(w: *std.Io.Writer, strings: []const []const u8) !void {
    try w.writeAll("[");
    for (strings, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{f}", .{std.json.fmt(s, .{})});
    }
    try w.writeAll("]");
}

fn choiceLabel(comptime item: Item, comptime value: []const u8) []const u8 {
    for (item.choices.?) |c| {
        if (std.mem.eql(u8, c.value, value)) return c.label;
    }
    unreachable; // the table check above
}

fn shownHere(comptime item: Item) bool {
    const os = item.os orelse return true;
    return os == builtin.os.tag;
}

/// One item. `noinline` for the reason `FileFormatter.emitField` gives:
/// inlined into the loop over ~220 fields, one Debug frame outgrows the
/// Windows stack.
noinline fn writeItem(
    comptime name: []const u8,
    comptime T: type,
    alloc: Allocator,
    w: *std.Io.Writer,
    scan: *const Scan,
    cfg: *const Config,
    def: *const Config,
) !void {
    const key = @field(Key, name);
    const item = comptime itemFor(key);
    const control: Control = comptime if (item) |it| it.control orelse controlOf(T) else controlOf(T);
    const U = Unwrapped(T);

    try w.print("{{\"key\":\"{s}\",\"group\":", .{name});
    if (item != null and comptime shownHere(item.?)) try w.print("\"{s}\"", .{@tagName(item.?.group)}) else try w.writeAll("null");
    // The name and sentence the form shows (#973); null for a key that is
    // only in "All options", which the hosts show by its key.
    try w.writeAll(",\"label\":");
    if (item) |it| try w.print("{f}", .{std.json.fmt(it.label, .{})}) else try w.writeAll("null");
    try w.writeAll(",\"summary\":");
    if (item) |it| try w.print("{f}", .{std.json.fmt(it.summary, .{})}) else try w.writeAll("null");
    try w.print(",\"control\":\"{s}\",\"choices\":", .{@tagName(control)});
    // A choice over a key that is not an enum lists its own values, in the
    // table's order; an enum's are its fields, in the type's.
    const free_choice = comptime control == .choice and @typeInfo(U) != .@"enum";
    if (free_choice) {
        try w.writeAll("[");
        inline for (item.?.choices.?, 0..) |c, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{f}", .{std.json.fmt(c.value, .{})});
        }
        try w.writeAll("]");
    } else if (control == .choice) {
        try w.writeAll("[");
        inline for (std.meta.fields(U), 0..) |f, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{f.name});
        }
        try w.writeAll("]");
    } else try w.writeAll("null");
    // The display name of each of `choices`, in the same order (#977); null
    // where the table names none (All Options' enums). One that is itself
    // null is spelled by the host, through `choice_template`.
    try w.writeAll(",\"choice_labels\":");
    if (free_choice) {
        try w.writeAll("[");
        inline for (item.?.choices.?, 0..) |c, i| {
            if (i > 0) try w.writeAll(",");
            if (c.label.len == 0) try w.writeAll("null") else try w.print("{f}", .{std.json.fmt(c.label, .{})});
        }
        try w.writeAll("]");
    } else if (comptime control == .choice and item != null and item.?.choices != null) {
        try w.writeAll("[");
        inline for (std.meta.fields(U), 0..) |f, i| {
            if (i > 0) try w.writeAll(",");
            const shown = comptime choiceLabel(item.?, f.name);
            try w.print("{f}", .{std.json.fmt(shown, .{})});
        }
        try w.writeAll("]");
    } else try w.writeAll("null");
    try w.writeAll(",\"choice_template\":");
    if (item != null and item.?.choice_template != null)
        try w.print("{f}", .{std.json.fmt(item.?.choice_template.?, .{})})
    else
        try w.writeAll("null");
    // What a toggle writes when it is not over a bool; null for a bool.
    try w.writeAll(",\"on\":");
    if (item != null and item.?.on != null) try w.print("{f}", .{std.json.fmt(item.?.on.?, .{})}) else try w.writeAll("null");
    try w.writeAll(",\"off\":");
    if (item != null and item.?.off != null) try w.print("{f}", .{std.json.fmt(item.?.off.?, .{})}) else try w.writeAll("null");
    // Extra words the search finds this row by. Empty outside the table.
    try w.writeAll(",\"aliases\":");
    try writeStrings(w, if (item) |it| it.aliases else &.{});

    const min: ?f64, const max: ?f64 = comptime bounds: {
        if (item) |it| if (it.min != null or it.max != null) break :bounds .{ it.min, it.max };
        if (control == .number and @typeInfo(U) == .int)
            break :bounds .{ @as(f64, @floatFromInt(std.math.minInt(U))), @as(f64, @floatFromInt(std.math.maxInt(U))) };
        break :bounds .{ null, null };
    };
    try w.writeAll(",\"min\":");
    if (min) |v| try w.print("{d}", .{v}) else try w.writeAll("null");
    try w.writeAll(",\"max\":");
    if (max) |v| try w.print("{d}", .{v}) else try w.writeAll("null");

    try w.writeAll(",\"default\":");
    try writeValue(T, name, alloc, w, @field(def, name));
    try w.writeAll(",\"value\":");
    try writeValue(T, name, alloc, w, @field(cfg, name));

    try w.writeAll(",\"doc\":");
    if (@hasDecl(help_strings.Config, name))
        try w.print("{f}", .{std.json.fmt(@field(help_strings.Config, name), .{})})
    else
        try w.writeAll("null");

    const r = resolve(scan, key);
    try w.writeAll(",\"source\":");
    try writeSource(w, scan, r.tally);
    try w.writeAll(",\"readonly\":");
    if (r.readonly) |reason| try w.print("\"{s}\"", .{@tagName(reason)}) else try w.writeAll("null");
    try w.writeAll("}");
}

/// The value as the config file writes it: `formatter.formatEntry`'s lines
/// with the `key = ` taken off each, joined with `\n`.
fn writeValue(comptime T: type, comptime name: []const u8, alloc: Allocator, w: *std.Io.Writer, value: T) !void {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    formatter.formatEntry(T, name, value, &buf.writer) catch return error.WriteFailed;

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    var lines = std.mem.splitScalar(u8, buf.written(), '\n');
    var first = true;
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        const prefix = name ++ " = ";
        const v = if (std.mem.startsWith(u8, l, prefix)) l[prefix.len..] else l;
        if (!first) try joined.append(alloc, '\n');
        first = false;
        try joined.appendSlice(alloc, v);
    }
    try w.print("{f}", .{std.json.fmt(joined.items, .{})});
}

/// The read, end to end, for the running process: load the config the way
/// the host that made `origin` loaded its own, scan the same files, render.
/// Caller owns the result.
pub fn formJson(alloc: Allocator, origin: Config.Origin) ![]u8 {
    var arena_state: ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = global.io();

    const ctx = try Context.current(arena, origin);
    const scan = try gather(arena, io, ctx);

    var cfg = try loadLike(alloc, origin);
    defer cfg.deinit();
    var def = try Config.default(alloc);
    defer def.deinit();
    def.finalize() catch {};

    const target = resolveTarget(arena, io, ctx.main_path);
    const backup = try std.fmt.allocPrint(arena, "{s}" ++ backup_suffix, .{target});
    const has_backup = if (std.Io.Dir.cwd().statFile(io, backup, .{})) |_| true else |_| false;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeJson(alloc, &out.writer, &scan, ctx.main_path, if (has_backup) backup else null, &cfg, &def);
    return try out.toOwnedSlice();
}

// ------------------------------------------------------------ search

/// One thing the settings search can find (screenshot.md §12.2): a setting
/// row, a role, a project, a plugin or one of its settings, an action on
/// the shortcuts page. **The search does not know which.** A host hands
/// over what each one is called and gets back which of them matched, by
/// position; what a match is and where clicking it goes stay the host's.
pub const SearchEntry = struct {
    /// What it is called, in the interface's language.
    name: []const u8 = "",
    /// Other words for it: the table's `aliases`, and anything else the
    /// host wants it found by (the English name under another language).
    aliases: []const []const u8 = &.{},
    /// The config key, or the action's name.
    key: []const u8 = "",
    /// The sentence under it; for an action, what it is bound to.
    summary: []const u8 = "",
    /// The names of an enum's values, in the interface's language.
    choices: []const []const u8 = &.{},
    /// The group it is drawn in, in the interface's language: what the
    /// breadcrumb over the result says. Somebody who types `font size` for
    /// a row called "Size" under "Font" has named it correctly.
    group: []const u8 = "",
};

/// Where a query matched, strongest first. An entry is ranked by the
/// weakest of its terms: `folder screenshot` against a row named
/// "Screenshot Folder" is a name match, but against a row that only
/// mentions folders in its summary it is a summary match.
pub const SearchRank = enum(u8) {
    name,
    alias,
    key,
    /// The summary, the name of one of the choices, or the group's name.
    summary,
};

pub const SearchHit = struct {
    index: usize,
    rank: SearchRank,
};

/// Lower-case `text` for comparing: ASCII, the accented Latin-1 letters,
/// Greek and Cyrillic. Everything else is left as it is, which for Chinese,
/// Japanese and Korean is all there is to do.
///
/// ⚠️ **Not full Unicode case folding.** Letters outside those blocks
/// (Latin Extended, Armenian, ...) match only in the case they were typed
/// in. Named here because a search that silently misses is the kind of
/// thing that gets reported as "the setting is not there".
fn foldAlloc(alloc: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, text.len);

    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (len == 1 or i + len > text.len) {
            try out.append(alloc, std.ascii.toLower(text[i]));
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch {
            try out.appendSlice(alloc, text[i..][0..len]);
            i += len;
            continue;
        };
        const lower: u21 = switch (cp) {
            // À..Þ, without the multiplication sign.
            0xC0...0xD6, 0xD8...0xDE => cp + 0x20,
            // Α..Ω (0x3A2 is unassigned).
            0x391...0x3A1, 0x3A3...0x3A9 => cp + 0x20,
            // Ѐ..Џ and А..Я.
            0x400...0x40F => cp + 0x50,
            0x410...0x42F => cp + 0x20,
            else => cp,
        };
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(lower, &buf) catch {
            try out.appendSlice(alloc, text[i..][0..len]);
            i += len;
            continue;
        };
        try out.appendSlice(alloc, buf[0..n]);
        i += len;
    }
    return out.toOwnedSlice(alloc);
}

/// The entries that match `query`, best first.
///
/// The query is split on whitespace into terms and **every term has to be
/// found** somewhere in the entry -- its name, an alias, its key, its
/// summary, the name of a choice or of its group -- as a substring,
/// ignoring case. An
/// empty query matches nothing: the host shows its ordinary page.
///
/// Sorted by rank, and within a rank in the order the entries were given,
/// which is the order they are drawn in.
pub fn search(alloc: Allocator, entries: []const SearchEntry, query: []const u8) Allocator.Error![]SearchHit {
    var arena_state: ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var terms: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, try foldAlloc(arena, query), " \t\r\n\u{3000}");
    while (words.next()) |word| try terms.append(arena, word);

    var hits: std.ArrayList(SearchHit) = .empty;
    errdefer hits.deinit(alloc);
    if (terms.items.len == 0) return hits.toOwnedSlice(alloc);

    entries: for (entries, 0..) |entry, index| {
        const name = try foldAlloc(arena, entry.name);
        const key = try foldAlloc(arena, entry.key);
        const summary = try foldAlloc(arena, entry.summary);
        const group = try foldAlloc(arena, entry.group);

        var weakest: SearchRank = .name;
        for (terms.items) |term| {
            const rank: SearchRank = rank: {
                if (std.mem.indexOf(u8, name, term) != null) break :rank .name;
                for (entry.aliases) |alias| {
                    if (std.mem.indexOf(u8, try foldAlloc(arena, alias), term) != null) break :rank .alias;
                }
                if (std.mem.indexOf(u8, key, term) != null) break :rank .key;
                if (std.mem.indexOf(u8, summary, term) != null) break :rank .summary;
                for (entry.choices) |choice| {
                    if (std.mem.indexOf(u8, try foldAlloc(arena, choice), term) != null) break :rank .summary;
                }
                if (std.mem.indexOf(u8, group, term) != null) break :rank .summary;
                // One term nowhere: the terms are an "and".
                continue :entries;
            };
            if (@intFromEnum(rank) > @intFromEnum(weakest)) weakest = rank;
        }
        try hits.append(alloc, .{ .index = index, .rank = weakest });
    }

    // Stable, so that equal ranks keep the order they were given in.
    std.mem.sort(SearchHit, hits.items, {}, struct {
        fn before(_: void, a: SearchHit, b: SearchHit) bool {
            if (a.rank != b.rank) return @intFromEnum(a.rank) < @intFromEnum(b.rank);
            return a.index < b.index;
        }
    }.before);
    return hits.toOwnedSlice(alloc);
}

/// `search` for a host: the entries as a JSON array of
/// `{"name", "aliases", "key", "summary", "choices", "group"}` -- every field
/// optional -- and the answer as `{"hits": [{"index", "rank"}]}`.
///
/// An entry that is not an object, or a field of the wrong type, counts as
/// empty rather than failing the search: one malformed plugin manifest
/// should not empty the results for everything else.
pub fn searchJson(alloc: Allocator, entries_json: []const u8, query: []const u8) ![]u8 {
    var arena_state: ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, entries_json, .{}) catch
        return error.InvalidEntries;
    const list = switch (root) {
        .array => |a| a.items,
        else => return error.InvalidEntries,
    };

    const H = struct {
        fn string(obj: std.json.ObjectMap, name: []const u8) []const u8 {
            return switch (obj.get(name) orelse return "") {
                .string => |s| s,
                else => "",
            };
        }

        fn strings(a: Allocator, obj: std.json.ObjectMap, name: []const u8) ![]const []const u8 {
            const items = switch (obj.get(name) orelse return &.{}) {
                .array => |arr| arr.items,
                else => return &.{},
            };
            var out: std.ArrayList([]const u8) = .empty;
            for (items) |item| switch (item) {
                .string => |s| try out.append(a, s),
                else => {},
            };
            return out.items;
        }
    };

    const entries = try arena.alloc(SearchEntry, list.len);
    for (list, entries) |value, *entry| {
        entry.* = switch (value) {
            .object => |obj| .{
                .name = H.string(obj, "name"),
                .aliases = try H.strings(arena, obj, "aliases"),
                .key = H.string(obj, "key"),
                .summary = H.string(obj, "summary"),
                .choices = try H.strings(arena, obj, "choices"),
                .group = H.string(obj, "group"),
            },
            else => .{},
        };
    }

    const hits = try search(arena, entries, query);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"hits\":[");
    for (hits, 0..) |hit, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.print("{{\"index\":{d},\"rank\":\"{s}\"}}", .{ hit.index, @tagName(hit.rank) });
    }
    try out.writer.writeAll("]}");
    return try out.toOwnedSlice();
}

// ------------------------------------------------------------ write

/// The file a write lands in: the main file, or what it links to (rule 6).
/// A path that does not exist is itself; a dangling link is its target.
fn resolveTarget(arena: Allocator, io: std.Io, path: []const u8) []const u8 {
    if (std.Io.Dir.realPathFileAbsoluteAlloc(io, path, arena)) |real| return real else |_| {}
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.readLinkAbsolute(io, path, &buf) catch return path;
    const link = buf[0..n];
    if (std.fs.path.isAbsolute(link)) return arena.dupe(u8, link) catch path;
    const dir = std.fs.path.dirname(path) orelse return path;
    return std.fs.path.join(arena, &.{ dir, link }) catch path;
}

/// What persists across writes in one run: whether the backup has been
/// taken (rule 6: once per run, before the first write) and the last
/// result, for a host whose buffer was too small for it.
pub const State = struct {
    mutex: std.Io.Mutex = .init,
    backed_up: bool = false,
    last_result: ?[]u8 = null,

    pub fn deinit(self: *State, alloc: Allocator) void {
        if (self.last_result) |r| alloc.free(r);
        self.* = undefined;
    }
};

/// The one the C API uses.
pub var state: State = .{};

const WriteOutcome = enum { written, changed };

/// Replace `target`'s contents with `new`, provided they are still
/// `expected` (null: the file did not exist). `.changed` means somebody
/// else wrote it in between and nothing was written; the caller redoes its
/// edit on what is there now.
fn writeTarget(
    st: *State,
    arena: Allocator,
    io: std.Io,
    target: []const u8,
    expected: ?[]const u8,
    new: []const u8,
) !WriteOutcome {
    const cwd = std.Io.Dir.cwd();
    if (!sameContent(arena, io, target, expected)) return .changed;

    const perms: std.Io.File.Permissions = if (expected != null) perms: {
        const s = try cwd.statFile(io, target, .{});
        if (!st.backed_up) {
            try cwd.copyFile(target, cwd, try std.fmt.allocPrint(arena, "{s}" ++ backup_suffix, .{target}), io, .{});
        }
        break :perms s.permissions;
    } else .default_file;
    // A missing file has nothing to back up, and the next write is not the
    // first of the run.
    st.backed_up = true;

    if (std.fs.path.dirname(target)) |dir| try cwd.createDirPath(io, dir);
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const tmp = try std.fmt.allocPrint(arena, "{s}.{x}.polter-tmp", .{ target, &raw });
    {
        var f = try cwd.createFile(io, tmp, .{ .permissions = perms });
        defer f.close(io);
        try f.writeStreamingAll(io, new);
    }
    // The last look before the rename: rule 6's "read again, redo if it
    // moved".
    if (!sameContent(arena, io, target, expected)) {
        cwd.deleteFile(io, tmp) catch {};
        return .changed;
    }
    cwd.rename(tmp, cwd, target, io) catch |err| {
        cwd.deleteFile(io, tmp) catch {};
        return err;
    };
    return .written;
}

fn sameContent(arena: Allocator, io: std.Io, path: []const u8, expected: ?[]const u8) bool {
    const now = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch |err|
        return err == error.FileNotFound and expected == null;
    const e = expected orelse return false;
    return std.mem.eql(u8, now, e);
}

pub const SetOutcome = union(enum) {
    /// Written to `path`; null when the file already said exactly this and
    /// nothing was written.
    ok: ?[]const u8,
    unknown_key,
    invalid_value: []const u8,
    read_only: struct { reason: Reason, tally: ?Scan.Tally, scan: Scan },
    /// The file kept changing under us.
    busy,
};

/// Rules 1-6 against the files `ctx` names. Everything in the outcome
/// lives in `arena`.
pub fn setIn(
    st: *State,
    arena: Allocator,
    io: std.Io,
    ctx: Context,
    key: []const u8,
    value: ?[]const u8,
) !SetOutcome {
    const k = std.meta.stringToEnum(Key, key) orelse return .unknown_key;

    if (value) |v| if (try validate(arena, key, v)) |msg| return .{ .invalid_value = msg };

    var attempt: u8 = 0;
    while (attempt < 5) : (attempt += 1) {
        const scan = try gather(arena, io, ctx);
        const r = switch (k) {
            inline else => |kk| resolve(&scan, kk),
        };
        if (r.readonly) |reason| {
            // Removing a line from the main file cannot restore the default
            // when another place has the last word either.
            return .{ .read_only = .{ .reason = reason, .tally = r.tally, .scan = scan } };
        }

        const target = resolveTarget(arena, io, ctx.main_path);
        const current: ?[]const u8 = std.Io.Dir.cwd().readFileAlloc(io, target, arena, .limited(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        const new = editText(arena, current orelse "", key, value) catch |err| switch (err) {
            error.ValueSpansLines => return .{ .invalid_value = "a value cannot span lines" },
            else => return err,
        };
        if (current) |c| if (std.mem.eql(u8, c, new)) return .{ .ok = null };
        if (current == null and new.len == 0) return .{ .ok = null };

        switch (try writeTarget(st, arena, io, target, current, new)) {
            .written => return .{ .ok = target },
            .changed => continue,
        }
    }
    return .busy;
}

/// `set` for the running process, as JSON:
///
///     {"ok": true, "key", "wrote": path|null, "errors": [string]}
///     {"ok": false, "key", "code": "unknown_key"|"invalid_value"|"read_only"|"busy"|"failed",
///      "message": string|null, "source": {...}|null}
///
/// `errors` is the configuration's errors after the write, loaded the way
/// the host loads it (`loadLike`); reloading the app is the host's (rule 7).
pub fn setJson(alloc: Allocator, st: *State, origin: Config.Origin, key: []const u8, value: ?[]const u8) ![]u8 {
    var arena_state: ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = global.io();

    st.mutex.lockUncancelable(io);
    defer st.mutex.unlock(io);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    const key_json = std.json.fmt(key, .{});

    const outcome = outcome: {
        const ctx = Context.current(arena, origin) catch |err| break :outcome err;
        break :outcome setIn(st, arena, io, ctx, key, value);
    } catch |err| {
        try w.print("{{\"ok\":false,\"key\":{f},\"code\":\"failed\",\"message\":\"{t}\",\"source\":null}}", .{ key_json, err });
        return try remember(alloc, st, &out);
    };

    switch (outcome) {
        .ok => |path| {
            try w.print("{{\"ok\":true,\"key\":{f},\"wrote\":", .{key_json});
            if (path) |p| try w.print("{f}", .{std.json.fmt(p, .{})}) else try w.writeAll("null");
            try w.writeAll(",\"errors\":[");
            if (loadLike(alloc, origin)) |loaded| {
                var cfg = loaded;
                defer cfg.deinit();
                for (cfg._diagnostics.items(), 0..) |*d, i| {
                    if (i > 0) try w.writeAll(",");
                    var buf: std.Io.Writer.Allocating = .init(alloc);
                    defer buf.deinit();
                    try d.format(&buf.writer);
                    try w.print("{f}", .{std.json.fmt(buf.written(), .{})});
                }
            } else |err| try w.print("\"the configuration could not be loaded: {t}\"", .{err});
            try w.writeAll("]}");
        },
        .unknown_key => try w.print("{{\"ok\":false,\"key\":{f},\"code\":\"unknown_key\",\"message\":null,\"source\":null}}", .{key_json}),
        .invalid_value => |msg| try w.print("{{\"ok\":false,\"key\":{f},\"code\":\"invalid_value\",\"message\":{f},\"source\":null}}", .{ key_json, std.json.fmt(msg, .{}) }),
        .read_only => |ro| {
            try w.print("{{\"ok\":false,\"key\":{f},\"code\":\"read_only\",\"message\":\"{s}\",\"source\":", .{ key_json, @tagName(ro.reason) });
            try writeSource(w, &ro.scan, ro.tally);
            try w.writeAll("}");
        },
        .busy => try w.print("{{\"ok\":false,\"key\":{f},\"code\":\"busy\",\"message\":null,\"source\":null}}", .{key_json}),
    }
    return try remember(alloc, st, &out);
}

fn remember(alloc: Allocator, st: *State, out: *std.Io.Writer.Allocating) ![]u8 {
    const result = try out.toOwnedSlice();
    if (st.last_result) |old| alloc.free(old);
    st.last_result = alloc.dupe(u8, result) catch null;
    return result;
}

// ------------------------------------------------------------ tests

const testing = std.testing;

fn expectEdit(before: []const u8, key: []const u8, value: ?[]const u8, after: []const u8) !void {
    const got = try editText(testing.allocator, before, key, value);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(after, got);
}

test "config form: an in-place edit changes the value's bytes and no others" {
    const before =
        "# my settings\n" ++
        "font-family = Menlo\n" ++
        "\n" ++
        "font-size = 12\n" ++
        "theme = dark:X,light:Y\n";
    const after =
        "# my settings\n" ++
        "font-family = Menlo\n" ++
        "\n" ++
        "font-size = 14.5\n" ++
        "theme = dark:X,light:Y\n";
    try expectEdit(before, "font-size", "14.5", after);

    // The claim itself: the byte ranges either side of the value are equal.
    const got = try editText(testing.allocator, before, "font-size", "14.5");
    defer testing.allocator.free(got);
    const at = std.mem.indexOf(u8, before, "12\n").?;
    try testing.expectEqualSlices(u8, before[0..at], got[0..at]);
    try testing.expectEqualSlices(u8, before[at + 2 ..], got[at + 4 ..]);
}

test "config form: indentation, spacing, CRLF and quotes stay as written" {
    try expectEdit("  font-size=12\r\nx = 1\r\n", "font-size", "13", "  font-size=13\r\nx = 1\r\n");
    try expectEdit("\tfont-size   =   12  \n", "font-size", "13", "\tfont-size   =   13  \n");
    try expectEdit("title = \"a b\"\n", "title", "c", "title = \"c\"\n");
    // A would-be trailing comment is part of the value to the loader, so
    // it is part of what gets replaced.
    try expectEdit("title = hi # note\n", "title", "bye", "title = bye\n");
}

test "config form: a key set twice is edited where the loader reads it" {
    try expectEdit(
        "font-size = 10\nfoo = 1\nfont-size = 11\nbar = 2\n",
        "font-size",
        "12",
        "font-size = 10\nfoo = 1\nfont-size = 12\nbar = 2\n",
    );
}

test "config form: a missing key is appended under the marker, once" {
    try expectEdit(
        "font-size = 10",
        "theme",
        "dark",
        "font-size = 10\n\n" ++ block_marker ++ "\ntheme = dark\n",
    );
    try expectEdit(
        "a = 1\r\n\r\n" ++ block_marker ++ "\r\ntheme = dark\r\n",
        "title",
        " x",
        "a = 1\r\n\r\n" ++ block_marker ++ "\r\ntheme = dark\r\ntitle = \" x\"\r\n",
    );
    try expectEdit("", "title", "x", block_marker ++ "\ntitle = x\n");
}

test "config form: null removes every line of the key and nothing else" {
    try expectEdit(
        "font-size = 10\n# keep\nfont-size=11\r\nbar = 2",
        "font-size",
        null,
        "# keep\nbar = 2",
    );
    try expectEdit("bar = 2\nfont-size = 1", "font-size", null, "bar = 2\n");
    try expectEdit("bar = 2\n", "font-size", null, "bar = 2\n");
}

test "config form: a bare key gets its value after the key" {
    try expectEdit("  window-save-state\n", "window-save-state", "always", "  window-save-state = always\n");
}

test "config form: a value is refused before anything is edited" {
    try testing.expectError(error.ValueSpansLines, editText(testing.allocator, "", "title", "a\nb"));

    const msg = (try validate(testing.allocator, "font-size", "big")).?;
    defer testing.allocator.free(msg);
    try testing.expect(msg.len > 0);
    try testing.expectEqual(@as(?[]u8, null), try validate(testing.allocator, "font-size", "13"));
    const unknown = (try validate(testing.allocator, "no-such-key", "1")).?;
    defer testing.allocator.free(unknown);
}

test "config form: the line iterator reads what the loader reads" {
    const text = "\xef\xbb\xbffont-size = 1\n  # c\n\n title = \"q\"\r\nbare\n";
    var it: LineIterator = .{ .text = text };
    const a = it.next().?;
    try testing.expectEqualStrings("font-size", a.key);
    try testing.expectEqual(@as(u32, 1), a.number);
    const b = it.next().?;
    try testing.expectEqualStrings("title", b.key);
    try testing.expectEqual(@as(u32, 4), b.number);
    try testing.expectEqualStrings("q", b.decoded(text).?);
    const c = it.next().?;
    try testing.expectEqualStrings("bare", c.key);
    try testing.expectEqual(@as(?Line.Span, null), c.value);
    try testing.expectEqual(@as(?Line, null), it.next());
}

test "config form: no scalar key formats to more than one line" {
    // What makes a key writable from one text box. A list-like type missing
    // from `isRepeatable` shows here as more than one line of its default.
    // (Zero is fine: an unset `quick-terminal-size` writes nothing.)
    @setEvalBranchQuota(100_000);
    var def = try Config.default(testing.allocator);
    defer def.deinit();
    var offenders: usize = 0;
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;
        if (comptime controlOf(field.type) == .readonly) continue;
        offenders += try linesOver1(field.name, field.type, @field(def, field.name));
    }
    try testing.expectEqual(@as(usize, 0), offenders);
}

noinline fn linesOver1(comptime name: []const u8, comptime T: type, value: T) !usize {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try formatter.formatEntry(T, name, value, &buf.writer);
    const n = std.mem.count(u8, buf.written(), "\n");
    if (n <= 1) return 0;
    std.debug.print("config form: {s} formats to {d} lines\n", .{ name, n });
    return 1;
}

/// A scratch directory with the files a test names; `ctx` points at them.
const Fixture = struct {
    tmp: testing.TmpDir,
    arena: ArenaAllocator,
    root: []const u8,

    fn init() !Fixture {
        var f: Fixture = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator), .root = "" };
        f.root = try f.tmp.dir.realPathFileAlloc(testing.io, ".", f.arena.allocator());
        return f;
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn path(self: *Fixture, name: []const u8) []const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.root, name }) catch unreachable;
    }

    fn write(self: *Fixture, name: []const u8, text: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = text });
    }

    fn read(self: *Fixture, name: []const u8) ![]const u8 {
        return try self.tmp.dir.readFileAlloc(testing.io, name, self.arena.allocator(), .limited(max_file_bytes));
    }

    fn ctx(self: *Fixture, args: []const []const u8) Context {
        const a = self.arena.allocator();
        const defaults = a.dupe([]const u8, &.{self.path("config")}) catch unreachable;
        return .{ .main_path = defaults[0], .defaults = defaults, .args = args, .cwd = self.root };
    }

    fn set(self: *Fixture, st: *State, args: []const []const u8, key: []const u8, value: ?[]const u8) !SetOutcome {
        return try setIn(st, self.arena.allocator(), testing.io, self.ctx(args), key, value);
    }
};

test "config form: sources follow the loader's order, and a key another file sets is not written" {
    var fx: Fixture = try .init();
    defer fx.deinit();
    try fx.write("config", "font-size = 10\nconfig-file = extra\ntitle = main\n");
    try fx.write("extra", "\n\ntitle = extra\n");

    const scan = try gather(fx.arena.allocator(), testing.io, fx.ctx(&.{}));
    try testing.expectEqual(@as(?usize, 0), scan.main);

    const size = resolve(&scan, .@"font-size");
    try testing.expectEqual(@as(?Reason, null), size.readonly);
    try testing.expectEqual(@as(u32, 1), size.tally.?.last.line);

    const title = resolve(&scan, .title);
    try testing.expectEqual(@as(?Reason, .file), title.readonly);
    try testing.expectEqualStrings(fx.path("extra"), scan.layers[title.tally.?.last.layer].path.?);
    try testing.expectEqual(@as(u32, 3), title.tally.?.last.line);

    try testing.expectEqual(@as(?Reason, .repeatable), resolve(&scan, .keybind).readonly);
    try testing.expectEqual(@as(?Scan.Tally, null), resolve(&scan, .theme).tally);

    var st: State = .{};
    const before = try fx.read("config");
    const out = try fx.set(&st, &.{}, "title", "x");
    try testing.expect(out == .read_only);
    try testing.expectEqualStrings(before, try fx.read("config"));
    const out2 = try fx.set(&st, &.{}, "title", null);
    try testing.expect(out2 == .read_only);
    try testing.expectEqualStrings(before, try fx.read("config"));
}

test "config form: the command line has the last word over the main file" {
    var fx: Fixture = try .init();
    defer fx.deinit();
    try fx.write("config", "font-size = 10\n");
    var st: State = .{};
    const out = try fx.set(&st, &.{"--font-size=20"}, "font-size", "11");
    try testing.expect(out == .read_only);
    try testing.expectEqual(Reason.cli, out.read_only.reason);
    try testing.expectEqualStrings("font-size = 10\n", try fx.read("config"));
}

test "config form: an invalid value writes nothing, not even the backup" {
    var fx: Fixture = try .init();
    defer fx.deinit();
    try fx.write("config", "font-size = 10\n");
    var st: State = .{};
    const out = try fx.set(&st, &.{}, "font-size", "huge");
    try testing.expect(out == .invalid_value);
    try testing.expectEqualStrings("font-size = 10\n", try fx.read("config"));
    try testing.expectError(error.FileNotFound, fx.tmp.dir.statFile(testing.io, "config" ++ backup_suffix, .{}));
    try testing.expect(!st.backed_up);
}

test "config form: the first write of a run backs the file up, and only the first" {
    var fx: Fixture = try .init();
    defer fx.deinit();
    try fx.write("config", "font-size = 10\n");
    var st: State = .{};

    const a = try fx.set(&st, &.{}, "font-size", "11");
    try testing.expectEqualStrings(fx.path("config"), a.ok.?);
    try testing.expectEqualStrings("font-size = 11\n", try fx.read("config"));
    try testing.expectEqualStrings("font-size = 10\n", try fx.read("config" ++ backup_suffix));

    _ = try fx.set(&st, &.{}, "font-size", "12");
    try testing.expectEqualStrings("font-size = 12\n", try fx.read("config"));
    try testing.expectEqualStrings("font-size = 10\n", try fx.read("config" ++ backup_suffix));

    // A new run takes a new one.
    var st2: State = .{};
    _ = try fx.set(&st2, &.{}, "font-size", "13");
    try testing.expectEqualStrings("font-size = 12\n", try fx.read("config" ++ backup_suffix));

    // Setting what is already there writes nothing.
    const same = try fx.set(&st2, &.{}, "font-size", "13");
    try testing.expectEqual(@as(?[]const u8, null), same.ok);
}

test "config form: a linked main file is written through the link" {
    // Creating a symlink on Windows needs a privilege a test runner may
    // not have.
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var fx: Fixture = try .init();
    defer fx.deinit();
    try fx.tmp.dir.createDirPath(testing.io, "dotfiles");
    try fx.write("dotfiles/real", "font-size = 10\n");
    try fx.tmp.dir.symLink(testing.io, "dotfiles/real", "config", .{});
    var st: State = .{};

    const out = try fx.set(&st, &.{}, "font-size", "11");
    try testing.expect(out == .ok);
    try testing.expectEqualStrings("font-size = 11\n", try fx.read("dotfiles/real"));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try fx.tmp.dir.readLink(testing.io, "config", &buf);
    try testing.expectEqualStrings("dotfiles/real", buf[0..n]);
    try testing.expectEqualStrings("font-size = 10\n", try fx.read("dotfiles/real" ++ backup_suffix));
}

test "config form: a missing main file is created with the block" {
    var fx: Fixture = try .init();
    defer fx.deinit();
    var st: State = .{};
    _ = try fx.set(&st, &.{}, "title", "hi");
    try testing.expectEqualStrings(block_marker ++ "\ntitle = hi\n", try fx.read("config"));
    // Removing a key the file does not have does not create or touch it.
    var fx2: Fixture = try .init();
    defer fx2.deinit();
    const out = try fx2.set(&st, &.{}, "title", null);
    try testing.expectEqual(@as(?[]const u8, null), out.ok);
    try testing.expectError(error.FileNotFound, fx2.tmp.dir.statFile(testing.io, "config", .{}));
}

test "config form: a file that moved since it was read is written from what is there now" {
    var fx: Fixture = try .init();
    defer fx.deinit();
    try fx.write("config", "font-size = 10\n");
    var st: State = .{};
    const a = fx.arena.allocator();
    const target = fx.path("config");
    // Somebody else wrote between our read and our write.
    try testing.expectEqual(WriteOutcome.changed, try writeTarget(&st, a, testing.io, target, "font-size = 9\n", "font-size = 11\n"));
    try testing.expectEqualStrings("font-size = 10\n", try fx.read("config"));
}

test "config form: font-family on two lines is read-only" {
    var fx: Fixture = try .init();
    defer fx.deinit();
    try fx.write("config", "font-family = A\nfont-family = B\n");
    const scan = try gather(fx.arena.allocator(), testing.io, fx.ctx(&.{}));
    try testing.expectEqual(@as(?Reason, .multiple), resolve(&scan, .@"font-family").readonly);
    try fx.write("config", "font-family = A\n");
    const scan2 = try gather(fx.arena.allocator(), testing.io, fx.ctx(&.{}));
    try testing.expectEqual(@as(?Reason, null), resolve(&scan2, .@"font-family").readonly);
}

test "config form: the JSON names every key and parses" {
    var fx: Fixture = try .init();
    defer fx.deinit();
    try fx.write("config", "font-size = 10\n");
    const scan = try gather(fx.arena.allocator(), testing.io, fx.ctx(&.{}));

    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    cfg.@"font-size" = 10;
    var def = try Config.default(testing.allocator);
    defer def.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeJson(testing.allocator, &out.writer, &scan, fx.path("config"), null, &cfg, &def);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("items").?.array.items;
    try testing.expectEqual(@as(usize, std.meta.fields(Key).len), items.len);
    for (items) |item| {
        if (!std.mem.eql(u8, item.object.get("key").?.string, "font-size")) continue;
        try testing.expectEqualStrings("10", item.object.get("value").?.string);
        try testing.expectEqualStrings("font", item.object.get("group").?.string);
        try testing.expectEqualStrings("Font Size", item.object.get("label").?.string);
        try testing.expectEqualStrings("In points; may be fractional.", item.object.get("summary").?.string);
        try testing.expectEqualStrings("main", item.object.get("source").?.object.get("kind").?.string);
        try testing.expectEqual(@as(i64, 1), item.object.get("source").?.object.get("line").?.integer);
    }
}

test "config form: a key only in All options has no label, and says so" {
    var fx: Fixture = try .init();
    defer fx.deinit();
    const scan = try gather(fx.arena.allocator(), testing.io, fx.ctx(&.{}));
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    var def = try Config.default(testing.allocator);
    defer def.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeJson(testing.allocator, &out.writer, &scan, fx.path("config"), null, &cfg, &def);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    var labelled: usize = 0;
    for (parsed.value.object.get("items").?.array.items) |item| {
        const label = item.object.get("label").?;
        if (std.mem.eql(u8, item.object.get("key").?.string, "keybind")) {
            try testing.expect(label == .null);
            try testing.expect(item.object.get("summary").? == .null);
        }
        if (label != .null) labelled += 1;
    }
    try testing.expectEqual(table.len, labelled);
}

test "config form: every value of a named enum key has a name, in the JSON too (#977)" {
    var named: usize = 0;
    for (table) |item| {
        const names = item.choices orelse continue;
        named += 1;
        for (names, 0..) |c, i| {
            errdefer std.debug.print("#977: {s}={s} is named \"{s}\"\n", .{ @tagName(item.key), c.value, c.label });
            // A value with no name of its own is one the host spells, and
            // the row has to carry the template it is spelled into.
            if (c.label.len == 0) {
                try testing.expect(item.choice_template != null);
                continue;
            }
            // Two values with one name could not be told apart in the list.
            for (names[i + 1 ..]) |other| try testing.expect(!std.mem.eql(u8, c.label, other.label));
        }
    }
    // The ten of #977, and the two the screenshot group added.
    try testing.expectEqual(@as(usize, 12), named);

    var fx: Fixture = try .init();
    defer fx.deinit();
    const scan = try gather(fx.arena.allocator(), testing.io, fx.ctx(&.{}));
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    var def = try Config.default(testing.allocator);
    defer def.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeJson(testing.allocator, &out.writer, &scan, fx.path("config"), null, &cfg, &def);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    for (parsed.value.object.get("items").?.array.items) |it| {
        if (!std.mem.eql(u8, it.object.get("key").?.string, "cursor-style")) continue;
        const values = it.object.get("choices").?.array.items;
        const shown = it.object.get("choice_labels").?;
        try testing.expect(shown == .array);
        const labels = shown.array.items;
        try testing.expectEqual(values.len, labels.len);
        for (values, labels) |v, l| {
            if (std.mem.eql(u8, v.string, "block")) try testing.expectEqualStrings("Block", l.string);
            if (std.mem.eql(u8, v.string, "block_hollow")) try testing.expectEqualStrings("Hollow Block", l.string);
        }
    }
}

test "config form: every row of the first five groups has a name and a one-line summary (#973)" {
    for (table) |item| {
        errdefer std.debug.print("#973: {s} has label \"{s}\", summary \"{s}\"\n", .{ @tagName(item.key), item.label, item.summary });
        try testing.expect(item.label.len > 0);
        try testing.expect(item.summary.len > 0);
        try testing.expect(item.summary.len <= summary_max);
        // One line: the hosts draw it under the control as it is.
        try testing.expect(std.mem.indexOfScalar(u8, item.summary, '\n') == null);
        // A name, not the key it names.
        try testing.expect(!std.mem.eql(u8, item.label, @tagName(item.key)));
    }
}

test "config form: under a host's own config file, that file is the main one and the default files stay as they were" {
    var fx: Fixture = try .init();
    defer fx.deinit();
    const a = fx.arena.allocator();
    try fx.write("config", "font-size = 10\n");
    try fx.write("override", "font-size = 20\n");
    const override = try a.dupeZ(u8, fx.path("override"));

    const ctx = try Context.fromOrigin(a, .{ .file = override, .cli = true }, .{
        .main = fx.path("config"),
        .files = &.{fx.path("config")},
    }, &.{}, fx.root);
    try testing.expectEqualStrings(override, ctx.main_path);

    const scan = try gather(a, testing.io, ctx);
    const size = resolve(&scan, .@"font-size");
    try testing.expectEqual(@as(?Reason, null), size.readonly);
    try testing.expectEqualStrings(override, scan.layers[size.tally.?.last.layer].path.?);

    var st: State = .{};
    const out = try setIn(&st, a, testing.io, ctx, "font-size", "21");
    try testing.expectEqualStrings(override, out.ok.?);
    _ = try setIn(&st, a, testing.io, ctx, "title", "t");
    try testing.expectEqualStrings("font-size = 21\n\n" ++ block_marker ++ "\ntitle = t\n", try fx.read("override"));

    try testing.expectEqualStrings("font-size = 10\n", try fx.read("config"));
    try testing.expectError(error.FileNotFound, fx.tmp.dir.statFile(testing.io, "config" ++ backup_suffix, .{}));
}

test "config form: without a file of the host's own, the default main file is written, and the command line only when it was read" {
    var fx: Fixture = try .init();
    defer fx.deinit();
    const a = fx.arena.allocator();
    try fx.write("config", "font-size = 10\n");
    const defaults: Context.Defaults = .{ .main = fx.path("config"), .files = &.{fx.path("config")} };
    const argv: []const []const u8 = &.{"--font-size=30"};

    // The mac app under Xcode does not read the command line.
    const no_cli = try Context.fromOrigin(a, .{}, defaults, argv, fx.root);
    try testing.expectEqualStrings(fx.path("config"), no_cli.main_path);
    try testing.expectEqual(@as(usize, 0), no_cli.args.len);
    var st: State = .{};
    _ = try setIn(&st, a, testing.io, no_cli, "font-size", "11");
    try testing.expectEqualStrings("font-size = 11\n", try fx.read("config"));

    const with_cli = try Context.fromOrigin(a, .{ .cli = true }, defaults, argv, fx.root);
    const out = try setIn(&st, a, testing.io, with_cli, "font-size", "12");
    try testing.expectEqual(Reason.cli, out.read_only.reason);
}

test "config form: the origin survives a clone and a conditional reload" {
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    cfg._origin = .{ .file = try cfg.arenaAlloc().dupeZ(u8, "/x/override"), .cli = true };

    var copy = try cfg.clone(testing.allocator);
    defer copy.deinit();
    try testing.expectEqualStrings("/x/override", copy._origin.file.?);
    try testing.expect(copy._origin.cli);

    // A theme switch rebuilds the config from its replay steps.
    cfg._conditional_set.insert(.theme);
    const other: @TypeOf(cfg._conditional_state.theme) = if (cfg._conditional_state.theme == .dark) .light else .dark;
    var flipped = (try cfg.changeConditionalState(.{ .theme = other })).?;
    defer flipped.deinit();
    try testing.expectEqualStrings("/x/override", flipped._origin.file.?);
}

test "config form: the values come from the host's own file, not the default ones" {
    var fx: Fixture = try .init();
    defer fx.deinit();
    try fx.write("override", "font-size = 23\n");
    const override = try fx.arena.allocator().dupeZ(u8, fx.path("override"));
    var cfg = try loadLike(testing.allocator, .{ .file = override });
    defer cfg.deinit();
    try testing.expectEqual(@as(f32, 23), cfg.@"font-size");
    try testing.expectEqualStrings(override, cfg._origin.file orelse "");
}

test "config form: config-default-files=false does not drop a file the host loaded instead of them" {
    var fx: Fixture = try .init();
    defer fx.deinit();
    const a = fx.arena.allocator();
    try fx.write("override", "font-size = 20\n");
    const override = try a.dupeZ(u8, fx.path("override"));
    const argv: []const []const u8 = &.{"--config-default-files=false"};

    const ctx = try Context.fromOrigin(a, .{ .file = override, .cli = true }, undefined, argv, fx.root);
    const scan = try gather(a, testing.io, ctx);
    try testing.expectEqual(@as(?usize, 0), scan.main);
    try testing.expectEqualStrings(override, scan.layers[resolve(&scan, .@"font-size").tally.?.last.layer].path.?);
    // And the value the form shows is that file's (#984: this was the half
    // that was missing, and it was wrong).
    var cfg = try loadLikeWith(testing.allocator, .{ .file = override, .cli = true }, argv);
    defer cfg.deinit();
    try testing.expectEqual(@as(f32, 20), cfg.@"font-size");

    // The default files are still dropped when they are what was loaded.
    try fx.write("config", "font-size = 10\n");
    const plain = try Context.fromOrigin(a, .{ .cli = true }, .{ .main = fx.path("config"), .files = &.{fx.path("config")} }, argv, fx.root);
    const scan2 = try gather(a, testing.io, plain);
    try testing.expectEqual(@as(?usize, null), scan2.main);
    try testing.expectEqual(@as(?Scan.Tally, null), resolve(&scan2, .@"font-size").tally);
}

test "config form: the value shown is the host's own file's, --config-default-files=false and all (#984)" {
    var fx: Fixture = try .init();
    defer fx.deinit();
    try fx.write("isolated-test.polter", "font-size = 17\n");
    const override = try fx.arena.allocator().dupeZ(u8, fx.path("isolated-test.polter"));

    // What `tools/mac-test-instance.sh` starts the instance with.
    var cfg = try loadLikeWith(testing.allocator, .{ .file = override, .cli = true }, &.{
        "--poltergeist-register-mcp=false",
        "--config-default-files=false",
        "--window-save-state=never",
    });
    defer cfg.deinit();
    try testing.expectEqual(@as(f32, 17), cfg.@"font-size");
    try testing.expectEqualStrings(override, cfg._origin.file.?);
    // The command line still counts.
    try testing.expectEqual(Config.WindowSaveState.never, cfg.@"window-save-state");
}

// ------------------------------------------------------------ screenshot group, search

fn renderForTest(alloc: Allocator) !std.json.Parsed(std.json.Value) {
    var fx: Fixture = try .init();
    defer fx.deinit();
    const scan = try gather(fx.arena.allocator(), testing.io, fx.ctx(&.{}));
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    var def = try Config.default(testing.allocator);
    defer def.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeJson(testing.allocator, &out.writer, &scan, fx.path("config"), null, &cfg, &def);
    return try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{ .allocate = .alloc_always });
}

fn itemNamed(root: std.json.Value, key: []const u8) ?std.json.ObjectMap {
    for (root.object.get("items").?.array.items) |item| {
        if (std.mem.eql(u8, item.object.get("key").?.string, key)) return item.object;
    }
    return null;
}

test "config form: the screenshot group lists its four settings and its shortcut row" {
    const parsed = try renderForTest(testing.allocator);
    defer parsed.deinit();

    const sections = parsed.value.object.get("sections").?.array.items;
    // After Polter, so the hosts draw it last of the table's groups.
    const last = sections[sections.len - 1].object;
    try testing.expectEqualStrings("screenshot", last.get("group").?.string);

    const keys = last.get("keys").?.array.items;
    try testing.expectEqual(@as(usize, 4), keys.len);
    try testing.expectEqualStrings("clipboard-paste-image", keys[0].string);
    try testing.expectEqualStrings("screenshot-directory", keys[1].string);
    try testing.expectEqualStrings("screenshot-mouse-trigger", keys[2].string);
    try testing.expectEqualStrings("screenshot-agent-access", keys[3].string);

    const rows = last.get("shortcuts").?.array.items;
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("screenshot", rows[0].object.get("action").?.string);
    try testing.expectEqualStrings("Screenshot Shortcut", rows[0].object.get("label").?.string);
    try testing.expect(rows[0].object.get("aliases").?.array.items.len > 0);

    // Every other group has the key and no rows in it.
    for (sections[0 .. sections.len - 1]) |section| {
        try testing.expectEqual(@as(usize, 0), section.object.get("shortcuts").?.array.items.len);
    }
}

test "config form: each screenshot row says how it is drawn and what it writes" {
    const parsed = try renderForTest(testing.allocator);
    defer parsed.deinit();
    const root = parsed.value;

    const paste = itemNamed(root, "clipboard-paste-image").?;
    try testing.expectEqualStrings("toggle", paste.get("control").?.string);
    // A bool writes true and false; nothing says otherwise.
    try testing.expect(paste.get("on").? == .null);
    try testing.expect(paste.get("off").? == .null);
    try testing.expectEqualStrings("true", paste.get("value").?.string);
    // The words the search finds it by travel with the row.
    var has_alias = false;
    for (paste.get("aliases").?.array.items) |alias| {
        if (std.mem.eql(u8, alias.string, "截屏")) has_alias = true;
    }
    try testing.expect(has_alias);

    const directory = itemNamed(root, "screenshot-directory").?;
    try testing.expectEqualStrings("directory", directory.get("control").?.string);
    try testing.expect(directory.get("readonly").? == .null);

    const mouse = itemNamed(root, "screenshot-mouse-trigger").?;
    try testing.expectEqualStrings("choice", mouse.get("control").?.string);
    const values = mouse.get("choices").?.array.items;
    const labels = mouse.get("choice_labels").?.array.items;
    try testing.expectEqual(@as(usize, 7), values.len);
    try testing.expectEqual(values.len, labels.len);
    // Off is a word; the rest are keys, which the host spells.
    try testing.expectEqualStrings("none", values[0].string);
    try testing.expectEqualStrings("Off", labels[0].string);
    for (labels[1..]) |label| try testing.expect(label == .null);
    const template = mouse.get("choice_template").?;
    try testing.expect(template == .string);
    try testing.expectEqualStrings("%s + Click", template.string);
    // What it is set to is one of the things it offers.
    const current = mouse.get("value").?.string;
    var offered = false;
    for (values) |v| {
        if (std.mem.eql(u8, v.string, current)) offered = true;
    }
    try testing.expect(offered);

    const agents = itemNamed(root, "screenshot-agent-access").?;
    try testing.expectEqualStrings("toggle", agents.get("control").?.string);
    try testing.expectEqualStrings("allow", agents.get("on").?.string);
    try testing.expectEqualStrings("deny", agents.get("off").?.string);
    try testing.expectEqualStrings("allow", agents.get("value").?.string);

    // A row outside the screenshot group has none of the new fields set.
    const family = itemNamed(root, "font-family").?;
    try testing.expect(family.get("choice_template").? == .null);
    try testing.expect(family.get("on").? == .null);
    try testing.expectEqual(@as(usize, 0), family.get("aliases").?.array.items.len);
}

test "config form: every listed value of a free choice is one the key accepts, as the file writes it" {
    // A dropdown value the parser refuses would be a row that fails every
    // time it is chosen; one the formatter writes differently would never
    // show as selected after being chosen.
    inline for (table) |item| {
        const T = @FieldType(Config, @tagName(item.key));
        const control = comptime item.control orelse controlOf(T);
        if (comptime control == .choice and @typeInfo(Unwrapped(T)) != .@"enum") {
            for (item.choices.?) |choice| {
                errdefer std.debug.print("{s}: `{s}`\n", .{ @tagName(item.key), choice.value });
                const bad = try validate(testing.allocator, @tagName(item.key), choice.value);
                defer if (bad) |b| testing.allocator.free(b);
                try testing.expect(bad == null);

                var v: T = undefined;
                try v.parseCLI(choice.value);
                var out: std.Io.Writer.Allocating = .init(testing.allocator);
                defer out.deinit();
                try v.formatEntry(formatter.entryFormatter("k", &out.writer));
                const expected = try std.fmt.allocPrint(testing.allocator, "k = {s}\n", .{choice.value});
                defer testing.allocator.free(expected);
                try testing.expectEqualStrings(expected, out.written());
            }
        }
    }
}

test "config form: a toggle's on and off are values of its key" {
    inline for (table) |item| {
        if (item.on) |on| {
            const T = Unwrapped(@FieldType(Config, @tagName(item.key)));
            const on_value = std.meta.stringToEnum(T, on);
            const off_value = std.meta.stringToEnum(T, item.off.?);
            try testing.expect(on_value != null);
            try testing.expect(off_value != null);
            try testing.expect(on_value.? != off_value.?);
        }
    }
}

test "config form: every screenshot row can be found by the word screenshot, in two languages" {
    // §12.2's own example: the rows carry `screenshot` and `截屏` so that
    // somebody who does not know a row's name still finds it.
    var seen: usize = 0;
    inline for (table) |item| {
        if (item.group == .screenshot) {
            seen += 1;
            inline for (.{ "screenshot", "截屏" }) |word| {
                var found = false;
                for (item.aliases) |alias| {
                    if (std.mem.eql(u8, alias, word)) found = true;
                }
                if (!found) std.debug.print("{s} has no alias `{s}`\n", .{ @tagName(item.key), word });
                try testing.expect(found);
            }
        }
    }
    try testing.expectEqual(@as(usize, 4), seen);
}

const search_fixture = [_]SearchEntry{
    // 0
    .{ .name = "Font Size", .key = "font-size", .summary = "In points; may be fractional." },
    // 1
    .{ .name = "截图保存位置", .aliases = &.{ "screenshot", "截屏", "capture", "folder" }, .key = "screenshot-directory", .summary = "截图和粘贴的图片存在哪里。" },
    // 2
    .{ .name = "鼠标触发", .aliases = &.{ "screenshot", "截屏", "double-click" }, .key = "screenshot-mouse-trigger", .summary = "按住这些键单击即可截图。", .choices = &.{ "关", "⌘⇧ + 单击" } },
    // 3: only its key says "screenshot".
    .{ .name = "允许 Agent 截屏", .key = "screenshot-agent-access", .summary = "Agent 可以用工具拍下屏幕。" },
    // 4: only its summary mentions it.
    .{ .name = "Clipboard Reading", .key = "clipboard-read", .summary = "Also governs a screenshot pasted by a program.", .choices = &.{ "Ask", "Allow", "Deny" } },
    // 5: a role, which has nothing but a name.
    .{ .name = "Screenshot Reviewer" },
};

fn expectHits(query: []const u8, expected: []const SearchHit) !void {
    const hits = try search(testing.allocator, &search_fixture, query);
    defer testing.allocator.free(hits);
    errdefer {
        std.debug.print("`{s}` gave:", .{query});
        for (hits) |h| std.debug.print(" {d}/{s}", .{ h.index, @tagName(h.rank) });
        std.debug.print("\n", .{});
    }
    try testing.expectEqual(expected.len, hits.len);
    for (expected, hits) |e, h| {
        try testing.expectEqual(e.index, h.index);
        try testing.expectEqual(e.rank, h.rank);
    }
}

test "config search: name, then alias, then key, then summary; ties keep their order" {
    // "screenshot": 5 by name; 1 and 2 by alias, in the order given; 3 by
    // key; 4 by its summary. Entry 0 not at all.
    try expectHits("screenshot", &.{
        .{ .index = 5, .rank = .name },
        .{ .index = 1, .rank = .alias },
        .{ .index = 2, .rank = .alias },
        .{ .index = 3, .rank = .key },
        .{ .index = 4, .rank = .summary },
    });
}

test "config search: case is ignored, and Chinese is matched as it is" {
    try expectHits("SCREENSHOT reviewer", &.{.{ .index = 5, .rank = .name }});
    try expectHits("截图", &.{
        .{ .index = 1, .rank = .name },
        .{ .index = 2, .rank = .summary },
    });
    try expectHits("截屏", &.{
        .{ .index = 3, .rank = .name },
        .{ .index = 1, .rank = .alias },
        .{ .index = 2, .rank = .alias },
    });
}

test "config search: every term has to be found, and the weakest one decides the rank" {
    // Both words in the name.
    try expectHits("size font", &.{.{ .index = 0, .rank = .name }});
    // One in the name, one only in the summary.
    try expectHits("font fractional", &.{.{ .index = 0, .rank = .summary }});
    // One of them nowhere.
    try expectHits("font screenshot", &.{});
    // Across fields of different entries is not a match for either.
    try expectHits("reviewer folder", &.{});
}

test "config search: the name of a choice finds the row, as weakly as its summary does" {
    try expectHits("deny", &.{.{ .index = 4, .rank = .summary }});
    try expectHits("单击", &.{.{ .index = 2, .rank = .summary }});
}

test "config search: a key is found by part of itself" {
    try expectHits("mouse-trigger", &.{.{ .index = 2, .rank = .key }});
    try expectHits("clipboard-read", &.{.{ .index = 4, .rank = .key }});
}

test "config search: nothing typed finds nothing" {
    try expectHits("", &.{});
    try expectHits("   \t ", &.{});
    // An ideographic space separates terms too.
    try expectHits("截图\u{3000}保存", &.{.{ .index = 1, .rank = .name }});
}

test "config search: accented Latin, Greek and Cyrillic fold; what does not is left alone" {
    const entries = [_]SearchEntry{
        .{ .name = "Größe Ändern" },
        .{ .name = "Размер шрифта" },
        .{ .name = "Μέγεθος" },
    };
    inline for (.{ .{ "ändern", 0 }, .{ "GRÖßE", 0 }, .{ "РАЗМЕР", 1 }, .{ "ΜΈΓΕΘΟΣ", 2 }, .{ "μέγεθος", 2 } }) |case| {
        const hits = try search(testing.allocator, &entries, case[0]);
        defer testing.allocator.free(hits);
        errdefer std.debug.print("`{s}`\n", .{case[0]});
        // "ΜΈΓΕΘΟΣ" has a tonos on its second letter, outside the folded
        // range: that one is the documented miss.
        if (comptime std.mem.eql(u8, case[0], "ΜΈΓΕΘΟΣ")) {
            try testing.expectEqual(@as(usize, 0), hits.len);
        } else {
            try testing.expectEqual(@as(usize, 1), hits.len);
            try testing.expectEqual(@as(usize, case[1]), hits[0].index);
        }
    }
}

test "config search: a term may name the group the row is in, as weakly as its summary" {
    const entries = [_]SearchEntry{
        .{ .name = "Family", .key = "font-family", .group = "Font" },
        .{ .name = "Size", .key = "x-size", .group = "Font" },
        .{ .name = "Font Rendering", .key = "x-render", .group = "Appearance" },
        .{ .name = "Scrollback", .key = "x-lines", .group = "Terminal" },
    };
    const E = struct {
        fn hits(query: []const u8, expected: []const SearchHit) !void {
            const got = try search(testing.allocator, &entries, query);
            defer testing.allocator.free(got);
            try testing.expectEqualSlices(SearchHit, expected, got);
        }
    };
    // The group alone: its rows, after the row that is called that.
    try E.hits("font", &.{
        .{ .index = 2, .rank = .name },
        .{ .index = 0, .rank = .key },
        .{ .index = 1, .rank = .summary },
    });
    // One term from the group and one from the name: the row, and only it.
    try E.hits("font size", &.{.{ .index = 1, .rank = .summary }});
    try E.hits("FONT  family", &.{.{ .index = 0, .rank = .key }});
    // A group nobody is in.
    try E.hits("terminal size", &.{});
}

/// What the Windows host handed the core on the test machine (task 1093,
/// S7), rebuilt: **the General rows are this file's own `table` and
/// `shortcuts`** -- their aliases, keys and groups, so that a change to
/// the table is a change to these readings -- under the Chinese interface
/// the machine ran. The names below are the Chinese catalogue's for the
/// rows the readings turn on; every other row keeps its English, which is
/// what a host shows for a string with no translation.
///
/// ⚠️ **The roles, plugins and shortcut-page actions are stand-ins.** A
/// host lists those itself and the core never sees where they came from;
/// they are here in the numbers the machine had, so that a row of the
/// table starting to match `总管` or `claude` shows up as a count that
/// moved.
const MachineEntries = struct {
    const zh = std.StaticStringMap([]const u8).initComptime(.{
        .{ "Font", "字体" },
        .{ "Font Size", "字号" },
        .{ "Line Height", "行高调整" },
        .{ "The font family to use; empty uses the default.", "使用的字体；留空用默认字体。" },
        .{ "In points; may be fractional.", "以点为单位，可以带小数。" },
        .{ "Extra height per line, in points or percent (e.g. 20%).", "每行额外加高，写点数或百分比（如 20%）。" },
        .{ "Paste Images as Files", "粘贴图片时存成文件并粘贴路径" },
        .{ "Save a pasted image as a file and paste its path.", "把粘贴的图片存成文件，再粘贴它的路径。" },
        .{ "Screenshot Folder", "截图保存位置" },
        .{ "Where screenshots and pasted images are saved.", "截图和粘贴的图片存在这里。" },
        .{ "Mouse Trigger", "鼠标触发" },
        .{ "Hold these keys and click to take a screenshot.", "按住这些键单击即可截图。" },
        .{ "Let Agents Take Screenshots", "允许 agent 截图" },
        .{ "Agents may capture the screen with the screenshot tools.", "agent 可以用截图工具拍下屏幕。" },
        .{ "Screenshot Shortcut", "截图快捷键" },
        .{ "Change it with a keybind line in the config file.", "在配置文件的 keybind 里修改。" },
        .{ "Off", "关" },
    });

    fn tr(msgid: []const u8) []const u8 {
        return zh.get(msgid) orelse msgid;
    }

    fn groupName(group: Group) []const u8 {
        return switch (group) {
            .appearance => "外观",
            .font => "字体",
            .terminal => "终端",
            .window => "窗口与标签页",
            .polter => "Polter",
            .screenshot => "截图",
        };
    }

    /// A translated name is also findable by its English (both hosts).
    fn withEnglish(arena: Allocator, aliases: []const []const u8, msgid: []const u8) ![]const []const u8 {
        if (std.mem.eql(u8, tr(msgid), msgid)) return aliases;
        var out: std.ArrayList([]const u8) = .empty;
        try out.appendSlice(arena, aliases);
        try out.append(arena, msgid);
        return out.items;
    }

    const stand_ins = [_]SearchEntry{
        // Roles.
        .{ .name = "Polter 总管", .key = "polter-supervisor" },
        .{ .name = "开发总管", .key = "dev-supervisor" },
        .{ .name = "测试总管", .key = "test-supervisor" },
        .{ .name = "文档总管", .key = "docs-supervisor" },
        .{ .name = "开发 worker", .key = "dev-worker" },
        // Plugins and their own settings.
        .{ .name = "Claude Code", .key = "claude" },
        .{ .name = "Model", .key = "claude.model", .summary = "Which model a new session starts with." },
        .{ .name = "Hooks", .key = "claude.hooks" },
        .{ .name = "Codex", .key = "codex" },
        // The Keyboard Shortcuts page.
        .{ .name = "截图", .key = "screenshot", .summary = "Ctrl+Shift+0" },
        .{ .name = "粘贴剪贴板内容", .key = "paste_from_clipboard", .summary = "Ctrl+Shift+V" },
        .{ .name = "粘贴主选区内容", .key = "paste_from_selection", .summary = "Shift+Insert" },
        .{ .name = "放大字号", .key = "increase_font_size", .summary = "Ctrl+=" },
    };

    fn build(arena: Allocator) ![]const SearchEntry {
        var out: std.ArrayList(SearchEntry) = .empty;
        inline for (table) |item| {
            if (item.os == null or item.os.? == .windows) {
                var choices: std.ArrayList([]const u8) = .empty;
                if (item.choices) |listed| for (listed) |choice| {
                    if (choice.label.len > 0) try choices.append(arena, tr(choice.label));
                };
                try out.append(arena, .{
                    .name = tr(item.label),
                    .aliases = try withEnglish(arena, item.aliases, item.label),
                    .key = @tagName(item.key),
                    .summary = tr(item.summary),
                    .choices = choices.items,
                    .group = groupName(item.group),
                });
            }
        }
        inline for (shortcuts) |row| {
            try out.append(arena, .{
                .name = tr(row.label),
                .aliases = try withEnglish(arena, row.aliases, row.label),
                .key = row.action,
                .summary = tr(row.summary),
                .group = groupName(row.group),
            });
        }
        try out.appendSlice(arena, &stand_ins);
        return out.items;
    }

    /// The names of what `query` finds, in order.
    fn names(arena: Allocator, query: []const u8) ![]const []const u8 {
        const entries = try build(arena);
        const hits = try search(arena, entries, query);
        const out = try arena.alloc([]const u8, hits.len);
        for (hits, out) |hit, *name| name.* = entries[hit.index].name;
        return out;
    }

    fn expectNames(query: []const u8, expected: []const []const u8) !void {
        var arena_state: ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const got = try names(arena_state.allocator(), query);
        errdefer {
            std.debug.print("`{s}` found {d}:", .{ query, got.len });
            for (got) |name| std.debug.print(" [{s}]", .{name});
            std.debug.print("\n", .{});
        }
        try testing.expectEqual(expected.len, got.len);
        for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
    }

    fn expectCount(query: []const u8, expected: usize) !void {
        var arena_state: ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const got = try names(arena_state.allocator(), query);
        errdefer {
            std.debug.print("`{s}` found {d}:", .{ query, got.len });
            for (got) |name| std.debug.print(" [{s}]", .{name});
            std.debug.print("\n", .{});
        }
        try testing.expectEqual(expected, got.len);
    }
};

test "config search: the readings the test machine took still hold (#1093 S7)" {
    const M = MachineEntries;
    // The four settings, the shortcut row, and the shortcut page's action.
    try M.expectCount("截图", 6);
    try M.expectCount("screenshot", 6);
    try M.expectCount("capture", 3);
    try M.expectNames("SCREENSHOT-DIR", &.{"截图保存位置"});
    try M.expectCount("总管", 4);
    try M.expectCount("claude", 3);
    // The three called it come before the one that only mentions it.
    try M.expectNames("粘贴", &.{
        "粘贴图片时存成文件并粘贴路径",
        "粘贴剪贴板内容",
        "粘贴主选区内容",
        "截图保存位置",
    });
    try M.expectCount("zzzz-nothing", 0);
}

test "config search: font size is found by what people call it (#1100)" {
    const M = MachineEntries;
    // The row is 字号 and its key is font-size: neither 字体 nor 大小 is in
    // either, and the machine read 0 for all three of these.
    try M.expectNames("字体 大小", &.{"字号"});
    try M.expectNames("字体 大", &.{"字号"});
    try M.expectNames("大小", &.{"字号"});
    try M.expectNames("字体大小", &.{"字号"});
    try M.expectNames("文字 size", &.{"字号"});
    // The group's name finds its rows, the one called that first.
    try M.expectNames("字体", &.{ "字体", "字号", "行高调整" });
    // Under the Chinese interface the English still works.
    try M.expectNames("font size", &.{ "字号", "放大字号" });
}

test "config search: the JSON form answers with positions and ranks" {
    const entries =
        \\[{"name":"Font Size","key":"font-size"},
        \\ {"name":"截图保存位置","aliases":["screenshot","截屏"],"key":"screenshot-directory","summary":"…"},
        \\ "not an object",
        \\ {"name":7,"aliases":"nope","choices":[1,"Deny"]},
        \\ {"name":"Screenshot Reviewer"}]
    ;
    const out = try searchJson(testing.allocator, entries, "screenshot");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "{\"hits\":[{\"index\":4,\"rank\":\"name\"},{\"index\":1,\"rank\":\"alias\"}]}",
        out,
    );

    // The malformed entries are empty, not fatal -- and still counted, so
    // the positions after them are the host's own.
    const deny = try searchJson(testing.allocator, entries, "deny");
    defer testing.allocator.free(deny);
    try testing.expectEqualStrings("{\"hits\":[{\"index\":3,\"rank\":\"summary\"}]}", deny);

    const none = try searchJson(testing.allocator, entries, "");
    defer testing.allocator.free(none);
    try testing.expectEqualStrings("{\"hits\":[]}", none);

    try testing.expectError(error.InvalidEntries, searchJson(testing.allocator, "{}", "x"));
    try testing.expectError(error.InvalidEntries, searchJson(testing.allocator, "[", "x"));
}

test "config form: the screenshot group's names are translated wherever the hosts look them up" {
    // The same floor `input/screenshot.zig` puts under its own strings: the
    // template, every catalogue, both macOS tables, one Chinese.
    var msgids: std.ArrayList([]const u8) = .empty;
    defer msgids.deinit(testing.allocator);
    inline for (table) |item| {
        if (item.group == .screenshot) {
            try msgids.append(testing.allocator, item.label);
            try msgids.append(testing.allocator, item.summary);
            if (item.choice_template) |template| try msgids.append(testing.allocator, template);
        }
    }
    inline for (shortcuts) |row| {
        try msgids.append(testing.allocator, row.label);
        try msgids.append(testing.allocator, row.summary);
    }
    // Four rows with a name and a sentence, one template, one shortcut row.
    try testing.expectEqual(@as(usize, 11), msgids.items.len);
    try @import("../input/screenshot.zig").expectEverywhere(msgids.items);
}
