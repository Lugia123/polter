const std = @import("std");
const Allocator = std.mem.Allocator;
const help_strings = @import("help_strings");
const actionpkg = @import("action.zig");
const SpecialCase = actionpkg.SpecialCase;

const list_fonts = @import("list_fonts.zig");
const help = @import("help.zig");
const version = @import("version.zig");
const list_keybinds = @import("list_keybinds.zig");
const list_themes = @import("list_themes.zig");
const list_colors = @import("list_colors.zig");
const list_actions = @import("list_actions.zig");
const ssh = @import("ssh.zig");
const ssh_cache = @import("ssh_cache.zig");
const edit_config = @import("edit_config.zig");
const show_config = @import("show_config.zig");
const explain_config = @import("explain_config.zig");
const validate_config = @import("validate_config.zig");
const crash_report = @import("crash_report.zig");
const show_face = @import("show_face.zig");
const boo = @import("boo.zig");
const new_window = @import("new_window.zig");
const new_tab = @import("new_tab.zig");
const toggle_quick_terminal = @import("toggle_quick_terminal.zig");
const chat = @import("chat.zig");
const mcp = @import("mcp.zig");
const global = @import("../global.zig");

/// Special commands that can be invoked via CLI flags. These are all
/// invoked by using `+<action>` as a CLI flag. The only exception is
/// "version" which can be invoked additionally with `--version`.
pub const Action = enum {
    /// Output the version and exit
    version,

    /// Output help information for the CLI or configuration
    help,

    /// List available fonts
    @"list-fonts",

    /// List available keybinds
    @"list-keybinds",

    /// List available themes
    @"list-themes",

    /// List named RGB colors
    @"list-colors",

    /// List keybind actions
    @"list-actions",

    /// Wrap `ssh` to configure Ghostty terminal integration on remote hosts
    ssh,

    /// Manage SSH terminfo cache for automatic remote host setup
    @"ssh-cache",

    /// Edit the config file in the configured terminal editor.
    @"edit-config",

    /// Dump the config to stdout
    @"show-config",

    /// Explain a single config option
    @"explain-config",

    // Validate passed config file
    @"validate-config",

    // Show which font face Ghostty loads a codepoint from.
    @"show-face",

    // List, (eventually) view, and (eventually) send crash reports.
    @"crash-report",

    // Boo!
    boo,

    // Use IPC to tell the running Ghostty to open a new window.
    @"new-window",

    // Use IPC to tell the running Ghostty to open a new tab.
    @"new-tab",

    // Use IPC to tell the running Ghostty to toggle the quick terminal.
    @"toggle-quick-terminal",

    // Run an MCP server so an agent can see and steer the terminals a
    // Poltergeist supervisor is watching.
    chat,
    mcp,

    pub fn detectSpecialCase(arg: []const u8) ?SpecialCase(Action) {
        // If we see a "-e" and we haven't seen a command yet, then
        // we are done looking for commands. This special case enables
        // `ghostty -e ghostty +command`. If we've seen a command we
        // still want to keep looking because
        // `ghostty +command -e +command` is invalid.
        if (std.mem.eql(u8, arg, "-e")) return .abort_if_no_action;

        // Special case, --version always outputs the version no
        // matter what, no matter what other args exist.
        if (std.mem.eql(u8, arg, "--version")) {
            return .{ .action = .version };
        }

        // --help matches "help" but if a subcommand is specified
        // then we match the subcommand.
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .{ .fallback = .help };
        }

        return null;
    }

    /// This should be returned by actions that want to print the help text.
    pub const help_error = error.ActionHelpRequested;

    /// Say on stderr that this action failed, because the log line beside
    /// every call to `run` cannot.
    ///
    /// # What this replaces
    ///
    /// Both callers of `run` follow it with `std.log.err("CLI action failed
    /// error={}")`, and that goes nowhere unless `GHOSTTY_LOG` is set -- which
    /// for anybody not developing Ghostty it is not. Measured on an ordinary
    /// action making an ordinary mistake:
    ///
    /// ```text
    /// $ polter +show-config --config-file=/nonexistent/nope.conf
    /// exit 1, stdout 0 bytes, stderr: four lines of unrelated sentry noise
    ///
    /// $ GHOSTTY_LOG=stderr polter +show-config --config-file=/nonexistent/nope.conf
    /// error: CLI action failed error=error.InvalidField
    /// ```
    ///
    /// **The same run knows exactly what went wrong and says it only to
    /// whoever already knew to ask.**
    ///
    /// # Why it lives here and not at either call site
    ///
    /// **This method exists because there are two entry points and the first
    /// attempt at the fix found only one of them.**
    ///
    /// `main_ghostty.zig` is the GTK executable's entry. macOS and Windows
    /// both arrive through `main_c.zig`'s `ghostty_cli_try_action` instead,
    /// because on those two the CLI is libghostty being called by a host. The
    /// fix went into the first, compiled, and was **not on the path it was
    /// written for**; it surfaced as the new string being absent from a
    /// freshly built binary while an older string from the same session was
    /// present -- which is what separates "changed the wrong place" from
    /// "ran the wrong binary", and only the second is cured by rebuilding.
    ///
    /// **The general shape, because it had already appeared once that day in
    /// another costume**: a sweep for one form of a defect finds none of the
    /// other form, and **"found one" and "found them all" are not distinguished
    /// by anything that happens on its own.** Both times the wrong answer
    /// arrived as *"I looked, there is nothing else"*.
    ///
    /// A method on `Action` cannot be added at one entry point and forgotten
    /// at the other, which is exactly the property the two `catch` blocks did
    /// not have. **That is the lesson put into the structure rather than into
    /// a comment**: a comment has to be read by whoever is about to need it.
    ///
    /// # stderr, never stdout
    ///
    /// ⚠️ **This sits above every action, so it changes what all of them
    /// print on failure.** Actions whose output *is* their result --
    /// `+version`, `+list-fonts`, `+show-config` -- speak on stdout, and
    /// `+mcp` speaks JSON-RPC there. A line added to stdout here would corrupt
    /// the output of a program that failed, which is worse than the silence it
    /// replaces. stderr is free on every one of these paths.
    ///
    /// # Deliberately terse
    ///
    /// One line: the action and the error, and nothing about what to do. An
    /// action that knows what to advise says so itself before returning -- see
    /// `cli/chat.zig::complain` and `cli/mcp.zig::complain`. **This is the
    /// floor under those, not a replacement**: it guarantees a failure is
    /// never silent, and leaves being helpful to the code with the context.
    pub fn reportFailure(self: Action, err: anyerror) void {
        var buffer: [256]u8 = undefined;
        var stderr: std.Io.File = .stderr();
        var writer = stderr.writerStreaming(global.io(), &buffer);
        writer.interface.print(
            "polter: +{s} failed: {t}\n",
            .{ @tagName(self), err },
        ) catch return;
        writer.end() catch {};
    }

    /// # How every action's output reaches a file, and how it used to destroy one
    ///
    /// **`polter +version >> log` run twice used to leave one copy in `log`,
    /// and appending to a file that already had anything in it destroyed
    /// what was there.** Measured: 319 bytes after the first run, 319 after
    /// the second; a file pre-loaded with a line came back holding only the
    /// action's own output.
    ///
    /// **`>` was always fine, and so was a pipe** -- `>` truncates before the
    /// program starts, so writing from position zero is correct, and a pipe
    /// cannot be written positionally at all. **So the defect was invisible
    /// in the two ordinary ways of running these commands and appeared only
    /// when somebody accumulated output**, which is to say only for the
    /// person collecting evidence.
    ///
    /// That is the same victim as task 182: **the extra thing done in order
    /// to keep a record is the thing that destroys it.**
    ///
    /// The cause was `std.Io.File.writer`, which is documented as *"defaults
    /// to positional... falls back to streaming"* -- its logical position
    /// starts at zero, so every writer over a seekable stdout or stderr began
    /// by overwriting the file. `writerStreaming` appends at the descriptor's
    /// own offset, which is what a standard stream is. **Forty call sites
    /// across this repository had the first one**; all forty were checked to
    /// be stdout or stderr rather than a random-access file, and the value of
    /// that check was proving there was no exception, not finding one.
    ///
    /// # Why nothing caught it, which is the part worth keeping
    ///
    /// Three fixes shipped the same morning to make failures speak --
    /// `cli/mcp.zig::complain`, `cli/chat.zig::complain` and
    /// `reportFailure` above -- and all three were verified through a pipe.
    ///
    /// > **A criterion exercised through a pipe says nothing at all about the
    /// > file path, and all three verifications happened to pick the channel
    /// > that could not expose this.**
    ///
    /// **That is not a criterion written loosely. It is a criterion and a
    /// defect sharing one blind spot** -- and the reading that looked most
    /// careful at the time (measuring that stderr was *not* empty, 196 bytes
    /// of unrelated noise) was taken through that same pipe.
    ///
    /// Run the action. This returns the exit code to exit with.
    pub fn run(self: Action, alloc: Allocator) !u8 {
        return self.runMain(alloc) catch |err| switch (err) {
            // If help is requested, then we use some comptime trickery
            // to find this action in the help strings and output that.
            help_error => err: {
                inline for (@typeInfo(Action).@"enum".fields) |field| {
                    // Future note: for now we just output the help text directly
                    // to stdout. In the future we can style this much prettier
                    // for all commands by just changing this one place.

                    if (std.mem.eql(u8, field.name, @tagName(self))) {
                        var buffer: [1024]u8 = undefined;
                        var stdout_writer = std.Io.File.stdout().writerStreaming(
                            global.io(),
                            &buffer,
                        );
                        const stdout = &stdout_writer.interface;
                        const text = @field(help_strings.Action, field.name) ++ "\n";
                        stdout.writeAll(text) catch |write_err| {
                            std.log.warn("failed to write help text: {}\n", .{write_err});
                            break :err 1;
                        };
                        stdout.flush() catch |flush_err| {
                            std.log.warn("failed to flush help text: {}\n", .{flush_err});
                            break :err 1;
                        };

                        break :err 0;
                    }
                }

                break :err err;
            },
            else => err,
        };
    }

    fn runMain(self: Action, alloc: Allocator) !u8 {
        return switch (self) {
            .version => try version.run(alloc),
            .help => try help.run(alloc),
            .@"list-fonts" => try list_fonts.run(alloc),
            .@"list-keybinds" => try list_keybinds.run(alloc),
            .@"list-themes" => try list_themes.run(alloc),
            .@"list-colors" => try list_colors.run(alloc),
            .@"list-actions" => try list_actions.run(alloc),
            .@"ssh-cache" => try ssh_cache.run(alloc),
            .ssh => try ssh.run(alloc),
            .@"edit-config" => try edit_config.run(alloc),
            .@"show-config" => try show_config.run(alloc),
            .@"explain-config" => try explain_config.run(alloc),
            .@"validate-config" => try validate_config.run(alloc),
            .@"crash-report" => try crash_report.run(alloc),
            .@"show-face" => try show_face.run(alloc),
            .boo => try boo.run(alloc),
            .@"new-window" => try new_window.run(alloc),
            .@"new-tab" => try new_tab.run(alloc),
            .@"toggle-quick-terminal" => try toggle_quick_terminal.run(alloc),
            .chat => try chat.run(alloc),
            .mcp => try mcp.run(alloc),
        };
    }

    /// Returns the filename associated with an action. This is a relative
    /// path from the root src/ directory.
    pub fn file(comptime self: Action) []const u8 {
        comptime {
            const filename = filename: {
                const tag = @tagName(self);
                var filename: [tag.len]u8 = undefined;
                _ = std.mem.replace(u8, tag, "-", "_", &filename);
                break :filename &filename;
            };

            return "cli/" ++ filename ++ ".zig";
        }
    }

    /// Returns the options of action. Supports generating shell completions
    /// without duplicating the mapping from Action to relevant Option
    /// @import(..) declaration.
    pub fn options(comptime self: Action) type {
        comptime {
            return switch (self) {
                .version => version.Options,
                .help => help.Options,
                .@"list-fonts" => list_fonts.Options,
                .@"list-keybinds" => list_keybinds.Options,
                .@"list-themes" => list_themes.Options,
                .@"list-colors" => list_colors.Options,
                .@"list-actions" => list_actions.Options,
                .@"ssh-cache" => ssh_cache.Options,
                .ssh => ssh.Options,
                .@"edit-config" => edit_config.Options,
                .@"show-config" => show_config.Options,
                .@"explain-config" => explain_config.Options,
                .@"validate-config" => validate_config.Options,
                .@"crash-report" => crash_report.Options,
                .@"show-face" => show_face.Options,
                .boo => boo.Options,
                .@"new-window" => new_window.Options,
                .@"new-tab" => new_tab.Options,
                .@"toggle-quick-terminal" => toggle_quick_terminal.Options,
                .chat => chat.Options,
                .mcp => mcp.Options,
            };
        }
    }
};

test "parse action none" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        alloc,
        "--a=42 --b --b-f=false",
    );
    defer iter.deinit();
    const action = try actionpkg.detectIter(Action, &iter);
    try testing.expect(action == null);
}

test "parse action version" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--a=42 --b --b-f=false --version",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--c=84 --d --version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }
}

test "parse action plus" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--a=42 --b --b-f=false +version",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--c=84 --d +version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }
}

test "parse action plus ignores -e" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--a=42 -e +version",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action == null);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+list-fonts --a=42 -e +version",
        );
        defer iter.deinit();
        try testing.expectError(
            actionpkg.DetectError.MultipleActions,
            actionpkg.detectIter(Action, &iter),
        );
    }
}

test "the Windows host's mirror of these special cases" {
    // **The half `windows/tools/one-rule-for-a-cli-action.py` says it cannot
    // reach.** That gate pins that the host has *one* rule for "does this
    // command line ask for a CLI action" and uses it in the right places. It
    // says nothing about whether that one rule is the same rule as this file's
    // -- and "one rule" and "the right rule" are different properties.
    //
    // Until now the second was carried by six tests in `windows/cliargs` that
    // were **written by hand from this function**. A mirror nobody checks is a
    // mirror that stops matching silently: add a special case here and
    // `--newthing` goes back to opening a resident window on Windows, which is
    // exactly what `--help` did before that crate existed.
    //
    // # One side is executed, the other is read, and that asymmetry is the point
    //
    // A test that read both sources and compared them would be two pieces of
    // text agreeing with each other, and text can go stale together. So the
    // core's answers below are **produced by calling `detectIter`**, not
    // transcribed: the spellings are enumerated out of `detectSpecialCase`,
    // each one is run through the real thing twice, and what comes back is
    // compared against what the Rust table *declares*.
    //
    // # What is deliberately not compared, and why not comparing is not enough
    //
    // `windows/cliargs`'s header records two divergences from this file, both
    // decided on purpose:
    //
    //   * **`argv[0]`.** This walks it; the host skips it, so that the host can
    //     never *invent* an action from a directory named `+something`. The
    //     probes below therefore hand this function the argument tail only --
    //     the part both sides look at. That is not stepping around the
    //     divergence, it is confining the comparison to where agreement is
    //     owed, and this comment is where that limit is written down.
    //   * **`+a +b` and `+nonsense`.** Here they are a `DetectError`; there
    //     they are reported as "an action was asked for", so that the failure
    //     lands as a fatal from `ghostty_init` rather than in the log file the
    //     GUI instance pinned.
    //
    // **The second is asserted to still be true rather than skipped.** A
    // divergence nobody checks can be "tidied up" by somebody who reads only
    // one side, and then the log of a GUI instance starts being deleted by a
    // failing `+nonsense`. Leaving it out of the comparison would let that
    // happen quietly; asserting it means the tidy-up turns red and points at
    // the paragraph explaining itself.
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Kind = enum { action, fallback, abort_if_no_action };

    const H = struct {
        /// A missing file fails rather than skips, for the reason the Windows
        /// action-tag floor in `apprt/action.zig` states: a skip lets a floor
        /// stop existing the first time somebody runs the suite from
        /// elsewhere, and nothing says so.
        fn read(i: std.Io, a: Allocator, path: []const u8) ![]const u8 {
            return std.Io.Dir.cwd().readFileAlloc(i, path, a, .limited(512 * 1024)) catch |err| {
                std.debug.print(
                    "cannot read {s} ({t}). Run `zig build test` from the repository root.\n",
                    .{ path, err },
                );
                return error.CliSourceUnreadable;
            };
        }

        /// The source with every `//` comment removed.
        ///
        /// **Not cosmetic.** Both files talk about these spellings in prose --
        /// the paragraph above `-e` in `detectSpecialCase` contains `"-e"` in
        /// quotes -- and a scan that reads comments collects whatever an
        /// author mentioned. This repository has had that defect three times in
        /// one round, in three different files, so the probe below plants a
        /// decoy spelling inside a comment and requires it not to be found.
        fn uncomment(src: []const u8, a: Allocator) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            var lines = std.mem.splitScalar(u8, src, '\n');
            while (lines.next()) |line| {
                const cut = std.mem.indexOf(u8, line, "//") orelse line.len;
                try out.appendSlice(a, line[0..cut]);
                try out.append(a, '\n');
            }
            return out.toOwnedSlice(a);
        }

        /// The body of the function whose signature contains `sig`.
        fn body(src: []const u8, sig: []const u8) ?[]const u8 {
            const at = std.mem.indexOf(u8, src, sig) orelse return null;
            const open = std.mem.indexOfScalarPos(u8, src, at, '{') orelse return null;
            var depth: usize = 0;
            var k = open;
            while (k < src.len) : (k += 1) {
                if (src[k] == '{') depth += 1;
                if (src[k] == '}') {
                    depth -= 1;
                    if (depth == 0) return src[open + 1 .. k];
                }
            }
            return null;
        }

        /// Every `"..."` in `hay` that follows `needle`.
        fn quotedAfter(
            hay: []const u8,
            needle: []const u8,
            out: *std.ArrayList([]const u8),
            a: Allocator,
        ) !void {
            var i: usize = 0;
            while (std.mem.indexOfPos(u8, hay, i, needle)) |p| {
                const q1 = std.mem.indexOfScalarPos(u8, hay, p + needle.len, '"') orelse return;
                const q2 = std.mem.indexOfScalarPos(u8, hay, q1 + 1, '"') orelse return;
                try out.append(a, hay[q1 + 1 .. q2]);
                i = q2 + 1;
            }
        }
    };

    // ---- the spellings this file itself treats specially -------------------
    //
    // Taken from the source rather than written out here: a list in this test
    // would be a third copy, and the copy that goes stale is always the one
    // nobody is looking at.
    const self_src = try H.uncomment(try H.read(io, alloc, "src/cli/ghostty.zig"), alloc);
    const self_body = H.body(self_src, "pub fn detectSpecialCase") orelse {
        std.debug.print("`detectSpecialCase` was not found in src/cli/ghostty.zig\n", .{});
        return error.SpecialCaseGone;
    };
    var spellings: std.ArrayList([]const u8) = .empty;
    try H.quotedAfter(self_body, "std.mem.eql(u8, arg,", &spellings, alloc);
    if (spellings.items.len < 3) {
        std.debug.print(
            "only {d} special spelling(s) read out of `detectSpecialCase`; a scan that has " ++
                "stopped matching finds none and reads exactly like a file with none.\n",
            .{spellings.items.len},
        );
        return error.SpecialCaseScanFailed;
    }

    // ---- probes for both scans, on planted text ----------------------------
    //
    // ⚠️ **The first version of this probe could not fail.** Its decoy comment
    // read `Mentioning a "--decoy" in prose`, and neither scan looks for a
    // quoted word on its own -- they look for a *code pattern* and take the
    // string after it. So the decoy was never a candidate, with or without the
    // stripping, and turning the stripping off left this green. **A probe that
    // passes when the thing it guards is removed is not a probe.** It was
    // caught by doing exactly that: disabling `uncomment` and expecting red.
    //
    // The decoys below therefore carry the **whole pattern** the scan matches,
    // which is the only shape a comment can be dangerous in.
    //
    // The stripping is defensive rather than load-bearing on today's files --
    // and the one comment in this tree that does carry a scanned pattern is
    // the one a few lines below, written by this very test. That is the reason
    // to keep it, not a reason to relax it.
    {
        const decoy =
            \\fn detectSpecialCase(arg: []const u8) void {
            \\    // like std.mem.eql(u8, arg, "--decoy") but only in prose
            \\    if (std.mem.eql(u8, arg, "--real")) return;
            \\}
        ;
        const stripped = try H.uncomment(decoy, alloc);
        const b = H.body(stripped, "fn detectSpecialCase") orelse return error.SpecialCaseGone;
        var got: std.ArrayList([]const u8) = .empty;
        try H.quotedAfter(b, "std.mem.eql(u8, arg,", &got, alloc);
        try testing.expectEqual(@as(usize, 1), got.items.len);
        try testing.expectEqualStrings("--real", got.items[0]);
    }
    {
        // The Rust side reads whole lines, so its decoy is a whole arm.
        const decoy =
            \\fn special_case(arg: &str) -> Option<Special> {
            \\    match arg {
            \\        // "--decoy" => Some(Special::Action), was considered
            \\        "--real" => Some(Special::Fallback),
            \\        _ => None,
            \\    }
            \\}
        ;
        const stripped = try H.uncomment(decoy, alloc);
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, stripped, '\n');
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, "Some(Special::") != null) n += 1;
        }
        try testing.expectEqual(@as(usize, 1), n);
    }

    // ---- what the core actually does with each of them ---------------------
    //
    // Two runs, because one cannot tell `action` from `fallback`: both answer
    // "yes, an action" when they are the only argument. With a `+list-fonts`
    // on the line the three kinds separate --
    //
    //   spelling first: action -> its own action; fallback -> list_fonts;
    //                   abort_if_no_action -> null (nothing pending yet)
    //   spelling last:  action -> its own action; the other two -> list_fonts
    //
    // -- so the kind is *derived from this file's behaviour*, not asserted
    // from its text.
    const Probe = struct {
        fn run(a: Allocator, line: []const u8) !?Action {
            var iter = try std.process.Args.IteratorGeneral(.{}).init(a, line);
            defer iter.deinit();
            return actionpkg.detectIter(Action, &iter);
        }
    };

    var kinds: std.StringHashMapUnmanaged(Kind) = .empty;
    for (spellings.items) |s| {
        const first = try std.fmt.allocPrint(alloc, "{s} +list-fonts", .{s});
        const last = try std.fmt.allocPrint(alloc, "+list-fonts {s}", .{s});
        const p1 = try Probe.run(alloc, first);
        const p2 = try Probe.run(alloc, last);
        const kind: Kind = if (p1 == null)
            .abort_if_no_action
        else if (p1.? == .@"list-fonts" and p2.? == .@"list-fonts")
            .fallback
        else if (p2 != null and p1.? == p2.?)
            .action
        else {
            std.debug.print(
                "`{s}` behaves in a way this test cannot classify: with it first the core " ++
                    "answers {?}, with it last {?}. The probe pair below has stopped " ++
                    "separating the three kinds.\n",
                .{ s, p1, p2 },
            );
            return error.SpecialCaseUnclassifiable;
        };
        try kinds.put(alloc, s, kind);
    }

    // ---- what the Windows host declares ------------------------------------
    const rust_src = try H.uncomment(
        try H.read(io, alloc, "windows/cliargs/src/lib.rs"),
        alloc,
    );
    const rust_body = H.body(rust_src, "fn special_case(") orelse {
        std.debug.print(
            "`fn special_case(` was not found in windows/cliargs/src/lib.rs -- either it " ++
                "was renamed, in which case this test is looking at nothing and says so, or " ++
                "the host no longer keeps its special cases in one table.\n",
            .{},
        );
        return error.HostTableGone;
    };

    // Each arm: one or more `"..."` patterns, then `Some(Special::Kind)`.
    var declared: std.StringHashMapUnmanaged(Kind) = .empty;
    var arms = std.mem.splitScalar(u8, rust_body, '\n');
    while (arms.next()) |line| {
        const at = std.mem.indexOf(u8, line, "Some(Special::") orelse continue;
        const kind_start = at + "Some(Special::".len;
        const kind_end = std.mem.indexOfScalarPos(u8, line, kind_start, ')') orelse continue;
        const kind_name = line[kind_start..kind_end];
        const kind: Kind = if (std.mem.eql(u8, kind_name, "Action"))
            .action
        else if (std.mem.eql(u8, kind_name, "Fallback"))
            .fallback
        else if (std.mem.eql(u8, kind_name, "AbortIfNoAction"))
            .abort_if_no_action
        else {
            std.debug.print("windows/cliargs names a kind this test does not know: {s}\n", .{kind_name});
            return error.HostKindUnknown;
        };
        var pats: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, line[0..at], i, '"')) |q1| {
            const q2 = std.mem.indexOfScalarPos(u8, line, q1 + 1, '"') orelse break;
            try pats.append(alloc, line[q1 + 1 .. q2]);
            i = q2 + 1;
        }
        for (pats.items) |p| try declared.put(alloc, p, kind);
    }

    // ---- the two directions ------------------------------------------------
    var missing: usize = 0;
    for (spellings.items) |s| {
        const want = kinds.get(s).?;
        const got = declared.get(s) orelse {
            std.debug.print(
                "this file treats `{s}` specially and `windows/cliargs` does not know it. " ++
                    "On Windows that argument goes back to opening a resident window instead " ++
                    "of running the action -- the `--help` defect, in a new spelling.\n",
                .{s},
            );
            missing += 1;
            continue;
        };
        if (got != want) {
            std.debug.print(
                "`{s}`: the core behaves as `{t}`, `windows/cliargs` declares `{t}`.\n",
                .{ s, want, got },
            );
            missing += 1;
        }
    }
    {
        var it = declared.iterator();
        while (it.next()) |e| {
            if (kinds.get(e.key_ptr.*) == null) {
                std.debug.print(
                    "`windows/cliargs` treats `{s}` specially and this file does not. The " ++
                        "host would decline to open a window for a line the core opens one " ++
                        "for.\n",
                    .{e.key_ptr.*},
                );
                missing += 1;
            }
        }
    }
    if (missing > 0) return error.HostMirrorDisagrees;

    // ---- the divergence that must stay a divergence -------------------------
    //
    // `+nonsense` is a `DetectError` here and "yes, an action" there. If this
    // ever stops being true, somebody has aligned the two sides by reading only
    // one of them, and the paragraph at the top of this test says what that
    // costs.
    try testing.expectError(
        actionpkg.DetectError.InvalidAction,
        Probe.run(alloc, "+nonsense"),
    );
    try testing.expectError(
        actionpkg.DetectError.MultipleActions,
        Probe.run(alloc, "+version +list-fonts"),
    );
}
