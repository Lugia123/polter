const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const build_config = @import("../build_config.zig");

/// The command a person types, and the product's name in prose. **Read from
/// the build, not written here**: see `src/build/exe_name.zig`.
const exe = build_config.exe_name;
const app = build_config.app_name;

// Note that this options struct doesn't implement the `help` decl like other
// actions. That is because the help command is special and wants to handle its
// own logic around help detection.
pub const Options = struct {
    /// This must be registered so that it isn't an error to pass `--help`
    help: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

/// **Built by concatenation rather than written out as one block.**
///
/// The name of the command is the name of the binary the build produced.
/// Spelling it here is how the two came to disagree -- this text said
/// `ghostty` while `GhosttyExe.zig` had been building `polter` -- and the
/// disagreement is invisible to whoever wrote it and fatal to whoever
/// reads it, because the only person who reads a usage line is the one who
/// does not already know what to type.
///
/// ⚠️ Costs the `\\` block style, which is why the whole message is one
/// chain rather than a mix: a block and a concatenation cannot be spliced
/// together, and half-and-half is worse to read than either.
const preamble =
    "Usage: " ++ exe ++ " [+action] [options]\n" ++
    "\n" ++
    "Run the " ++ app ++ " terminal emulator or a specific helper action.\n" ++
    "\n" ++
    "If no `+action` is specified, run the " ++ app ++ " terminal emulator.\n" ++
    "All configuration keys are available as command line options.\n" ++
    "To specify a configuration key, use the `--<key>=<value>` syntax\n" ++
    "where key and value are the same format you'd put into a configuration\n" ++
    "file. For example, `--font-size=12` or `--font-family=\"Fira Code\"`.\n" ++
    "\n" ++
    "To see a list of all available configuration options, please see\n" ++
    "the `src/config/Config.zig` file. A future update will allow seeing\n" ++
    "the list of configuration options from the command line.\n" ++
    "\n" ++
    "A special command line argument `-e <command>` can be used to run\n" ++
    "the specific command inside the terminal emulator. For example,\n" ++
    "`" ++ exe ++ " -e top` will run the `top` command inside the terminal.\n" ++
    "\n" ++
    "On macOS, launching the terminal emulator from the CLI is not\n" ++
    "supported and only actions are supported. Use `open -na " ++ app ++ ".app`\n" ++
    "instead, or `open -na " ++ app ++ ".app --args --foo=bar --baz=quz` to pass\n" ++
    "arguments.\n" ++
    "\n" ++
    "Available actions:\n" ++
    "\n\n";

/// The `help` command shows general help about Polter. Recognized as either
/// `-h, `--help`, or like other actions `+help`.
///
/// You can also specify `--help` or `-h` along with any action such as
/// `+list-themes` to see help for a specific action.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(global.io(), &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(preamble);

    inline for (@typeInfo(Action).@"enum".fields) |field| {
        try stdout.print("  +{s}\n", .{field.name});
    }

    try stdout.writeAll(
        \\
        \\Specify `+<action> --help` to see the help for a specific action,
        \\where `<action>` is one of actions listed above.
        \\
    );
    try stdout.flush();

    return 0;
}

test "help names the binary the build actually produces" {
    const testing = std.testing;

    // **The usage line is the one sentence read only by people who do not
    // know what to type.** It said `ghostty` while the build had been
    // producing `polter` since the fork, so the first thing a new user was
    // told was a command that does not exist.
    try testing.expect(std.mem.startsWith(
        u8,
        preamble,
        "Usage: " ++ build_config.exe_name,
    ));
}

test "the help text says nothing about Ghostty" {
    const testing = std.testing;

    // **A ratchet, not a spelling check.** `windows/AGENTS.md` states the
    // rule -- *user-visible strings are Polter; internal artifacts keep the
    // upstream Ghostty names* -- and this text is as user-visible as it gets.
    // Merging upstream brings the old wording back sentence by sentence, and
    // every one of those arrives looking like an improvement to the prose.
    //
    // ⚠️ **NOT COVERED: the rest of the CLI.** `+version`, `+ssh`,
    // `+explain-config`, `+list-themes`, `+show-face`, `+list-fonts`,
    // `+edit-config`, `+ssh-cache`, `mcp` and `main_ghostty.zig`'s no-action
    // message were all corrected in the same change, and **none of them has
    // an assertion like this one**: they write straight to a stream, so there
    // is nothing to look at without running the program.
    try testing.expect(std.mem.indexOf(u8, preamble, "ghostty") == null);
    try testing.expect(std.mem.indexOf(u8, preamble, "Ghostty") == null);
}
