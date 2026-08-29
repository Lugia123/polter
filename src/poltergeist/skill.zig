//! Skills: the text a supervisor reads to know how to do its job.
//!
//! Poltergeist splits supervision in two. Judgement -- is this terminal
//! stuck or thinking, is there anything left for it to do -- is written as
//! prose and handed to the supervisor AI, because judging that from code
//! means writing rules that rot the moment an agent CLI changes its
//! interface. Constraints are in code, because prose gets pushed out of a
//! long session's context and running unattended overnight is exactly when
//! that happens.
//!
//! A skill file is YAML frontmatter plus Markdown. The program reads only
//! the frontmatter; the body is handed to the AI untouched.
//!
//! Note what the frontmatter does *not* carry: whether a terminal may clock
//! off. That is a hard constraint and lives only in `Bus.Entry.held`. Skill
//! files are user-editable, and a constraint readable from one would be a
//! constraint a user could weaken by accident while editing prose.
//!
//! Pure: text in, values out. See `docs/poltergeist/mcp.md`.

const std = @import("std");

pub const ParseError = error{
    /// No frontmatter, or it is not closed.
    NoFrontmatter,

    /// A required field is missing.
    Incomplete,

    /// A field is present but its value makes no sense.
    BadField,

    /// A field that would look like it controls a hard constraint.
    ConstraintInFrontmatter,
};

/// What the program reads. Everything else in the frontmatter is ignored,
/// so a newer skill file still loads in an older build.
pub const Meta = struct {
    name: []const u8,
    version: u32 = 1,

    description: []const u8 = "",
};

pub const Skill = struct {
    meta: Meta,

    /// The prose, borrowed from the source text.
    body: []const u8,
};

/// Names are used to build file paths, so they are restricted rather than
/// sanitised: lowercase, digits and dashes. A name that could contain a
/// path separator or a `..` would let `skill_read` walk out of the skills
/// directory and read whatever it liked.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// Read one skill file.
pub fn parse(source: []const u8) ParseError!Skill {
    var rest = source;

    // Tolerate a BOM and leading blank lines: these files are edited by
    // hand, sometimes on Windows.
    if (std.mem.startsWith(u8, rest, "\xef\xbb\xbf")) rest = rest[3..];
    while (rest.len > 0 and (rest[0] == '\n' or rest[0] == '\r')) rest = rest[1..];

    if (!std.mem.startsWith(u8, rest, "---")) return error.NoFrontmatter;
    const after_open = std.mem.indexOfScalar(u8, rest, '\n') orelse
        return error.NoFrontmatter;
    rest = rest[after_open + 1 ..];

    const close = std.mem.indexOf(u8, rest, "\n---") orelse
        return error.NoFrontmatter;
    const front = rest[0..close];

    var body = rest[close + 1 ..];
    const body_start = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
    body = if (body_start < body.len) body[body_start + 1 ..] else "";

    var meta: Meta = .{ .name = "" };
    var saw_name = false;

    var lines = std.mem.splitScalar(u8, front, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse
            return error.BadField;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\"'");

        // Refuse loudly rather than ignoring. A user who wrote this
        // believes they changed whether a terminal can clock off, and
        // silently carrying on would leave them believing it.
        if (std.mem.eql(u8, key, "allow_clock_out") or
            std.mem.eql(u8, key, "allow-clock-out"))
        {
            return error.ConstraintInFrontmatter;
        }

        if (std.mem.eql(u8, key, "name")) {
            if (!isValidName(value)) return error.BadField;
            meta.name = value;
            saw_name = true;
        } else if (std.mem.eql(u8, key, "version")) {
            meta.version = std.fmt.parseUnsigned(u32, value, 10) catch
                return error.BadField;
        } else if (std.mem.eql(u8, key, "description")) {
            meta.description = value;
        }
        // Anything else is ignored, so a file written for a newer build
        // still loads here.
    }

    if (!saw_name) return error.Incomplete;
    return .{ .meta = meta, .body = body };
}

/// The skills shipped with Ghostty, in load order.
pub const builtin_names = [_][]const u8{
    "supervising",
    "reading-a-terminal",
    "operating-a-terminal",
};

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const sample =
    \\---
    \\name: reading-a-terminal
    \\version: 2
    \\description: 读一个终端
    \\---
    \\First line of prose.
    \\
    \\Second paragraph.
;

test "a skill parses into its fields and its prose" {
    const s = try parse(sample);
    try testing.expectEqualStrings("reading-a-terminal", s.meta.name);
    try testing.expectEqual(@as(u32, 2), s.meta.version);
    try testing.expectEqualStrings("读一个终端", s.meta.description);
    try testing.expectEqualStrings(
        "First line of prose.\n\nSecond paragraph.",
        s.body,
    );
}

test "the body is handed over untouched" {
    const src = "---\nname: x\n---\n  indented\n\n\ttabbed";
    const s = try parse(src);
    try testing.expectEqualStrings("  indented\n\n\ttabbed", s.body);
}

test "defaults apply to everything but the name" {
    const s = try parse(
        \\---
        \\name: supervising
        \\---
        \\body
    );
    try testing.expectEqual(@as(u32, 1), s.meta.version);
    try testing.expectEqualStrings("", s.meta.description);
}

test "a file without a name is incomplete" {
    try testing.expectError(error.Incomplete, parse(
        \\---
        \\version: 1
        \\---
        \\body
    ));
}

test "frontmatter must be there and must close" {
    try testing.expectError(error.NoFrontmatter, parse("just prose"));
    try testing.expectError(error.NoFrontmatter, parse(
        \\---
        \\name: x
        \\body with no close
    ));
}

test "allow_clock_out is refused rather than ignored" {
    // Whether a terminal can clock off is a hard constraint and lives in
    // code. A user who put it here believes they changed something; loading
    // the file anyway would leave them believing it.
    const written_by_a_hopeful_user =
        \\---
        \\name: supervising
        \\allow_clock_out: true
        \\---
        \\body
    ;
    try testing.expectError(
        error.ConstraintInFrontmatter,
        parse(written_by_a_hopeful_user),
    );

    // And the dashed spelling, since YAML users write both.
    try testing.expectError(error.ConstraintInFrontmatter, parse(
        \\---
        \\name: x
        \\allow-clock-out: false
        \\---
        \\body
    ));
}

test "unknown fields are ignored so newer files still load" {
    const s = try parse(
        \\---
        \\name: x
        \\some_future_field: whatever
        \\---
        \\body
    );
    try testing.expectEqualStrings("x", s.meta.name);
}

test "a bad value is refused rather than guessed at" {
    // A number that is not one. `version` is the only numeric field left;
    // this used to be `max_rounds`, which was removed because nothing read
    // it. The path being guarded is the parse failure, not the field.
    try testing.expectError(error.BadField, parse(
        \\---
        \\name: x
        \\version: lots
        \\---
        \\body
    ));
    try testing.expectError(error.BadField, parse(
        \\---
        \\name: Not A Valid Name
        \\---
        \\body
    ));
}

test "a name cannot walk out of the skills directory" {
    // `skill_read` builds a path from this. A name that could hold a
    // separator or a `..` would read whatever the caller liked.
    try testing.expect(!isValidName("../../etc/passwd"));
    try testing.expect(!isValidName("a/b"));
    try testing.expect(!isValidName(".."));
    try testing.expect(!isValidName("a\\b"));
    try testing.expect(!isValidName("a.b"));
    try testing.expect(!isValidName(""));
    try testing.expect(!isValidName("UPPER"));

    try testing.expect(isValidName("supervising"));
    try testing.expect(isValidName("reading-a-terminal"));
}

test "a BOM and leading blank lines do not stop it loading" {
    const s = try parse("\xef\xbb\xbf\n\n---\nname: x\n---\nbody");
    try testing.expectEqualStrings("x", s.meta.name);
    try testing.expectEqualStrings("body", s.body);
}

test "the mode skills are gone, and nothing still names one" {
    // Work modes were a ceremony: switching one said a sentence to the
    // terminal and then that sentence was pushed out of context. The
    // supervisor decides afresh on every wake-up whether there is more
    // worth doing, which was the same judgement. What survived is the
    // hold, and it is a boolean in code with a mark in the tab -- not a
    // skill anybody has to read.
    try testing.expectEqual(@as(usize, 3), builtin_names.len);
    for (builtin_names) |name| {
        try testing.expect(!std.mem.startsWith(u8, name, "mode-"));
    }

    // The prose is guarded too, by the test below that lists the tools no
    // skill may name -- `set_work_mode` and `get_work_mode` are on it.
}

pub const PathError = error{BadName} || std.mem.Allocator.Error;

/// Where a user's own copy of a skill lives. Checked first, so editing one
/// is how you change Poltergeist's behaviour without touching the install.
pub fn userPath(
    alloc: std.mem.Allocator,
    config_dir: []const u8,
    name: []const u8,
) PathError![]u8 {
    if (!isValidName(name)) return error.BadName;
    return std.fmt.allocPrint(alloc, "{s}/polter/skills/{s}.md", .{ config_dir, name });
}

/// Where the shipped copy lives.
pub fn resourcePath(
    alloc: std.mem.Allocator,
    resources_dir: []const u8,
    name: []const u8,
) PathError![]u8 {
    if (!isValidName(name)) return error.BadName;
    return std.fmt.allocPrint(alloc, "{s}/poltergeist/{s}.md", .{ resources_dir, name });
}

/// The shipped files, embedded for the tests only.
///
/// A test block is not compiled into a normal build, so these do not end up
/// in the binary -- the loader reads them from the resources directory,
/// which is what makes them editable. Embedding them here is only so that a
/// broken shipped file fails the build rather than a user's night.
const builtin_sources = if (@import("builtin").is_test) [_][]const u8{
    @embedFile("skills/supervising.md"),
    @embedFile("skills/reading-a-terminal.md"),
    @embedFile("skills/operating-a-terminal.md"),
} else {};

test "every shipped skill parses" {
    for (builtin_sources, builtin_names) |source, expected_name| {
        const s = parse(source) catch |err| {
            std.debug.print("\n{s} failed to parse: {}\n", .{ expected_name, err });
            return err;
        };

        // The name inside the file has to match the file it is in, or
        // `skill_read` would hand back something other than what was asked
        // for.
        try testing.expectEqualStrings(expected_name, s.meta.name);
        try testing.expect(s.body.len > 100);
        try testing.expect(s.meta.description.len > 0);
    }
}

test "the shipped skills do not promise what the tools cannot do" {
    // A skill that tells a supervisor to approve something on another
    // agent's behalf would be describing a tool that does not exist, and
    // the AI would go looking for it.
    //
    // The work mode tools are on the list for the same reason even though
    // they were removed rather than never built: prose outlives the code
    // it describes, and a skill still naming one would send the AI looking
    // for a tool that is not there. The hold that replaced them is the
    // user's from the menu, so there is nothing here to offer either.
    for (builtin_sources, builtin_names) |source, name| {
        for ([_][]const u8{
            "approve(",
            "grant_permission",
            "answer_prompt",
            "set_work_mode",
            "get_work_mode",
        }) |forbidden| {
            if (std.mem.indexOf(u8, source, forbidden) != null) {
                std.debug.print("\n{s} mentions {s}\n", .{ name, forbidden });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "the supervising skill names the tools it tells you to use" {
    // The skill's whole job here is to be the thing that gets a supervisor
    // to set the work up. If it names a tool that is not on the surface,
    // the AI goes looking for something that is not there; if it stops
    // naming one, nothing points at it at all.
    const supervising = for (builtin_sources, builtin_names) |source, name| {
        if (std.mem.eql(u8, name, "supervising")) break source;
    } else return error.TestUnexpectedResult;

    for ([_][]const u8{
        "group_create",
        "group_set_brief",
        "group_add",
        "set_watch",
        "become_supervisor",
        "session_recall",
        "terminal_list",

        // Added with the tool. An interrupt is the one thing
        // `terminal_send` cannot do -- the paste path strips the control
        // bytes -- so a skill that never names this leaves a supervisor
        // trying to spell Ctrl-C into a text field.
        "terminal_key",
        "terminal_keys",
    }) |tool| {
        if (std.mem.indexOf(u8, supervising, tool) == null) {
            std.debug.print("\nsupervising never mentions {s}\n", .{tool});
            return error.TestUnexpectedResult;
        }
    }
}

/// Whether a shipped skill's prose names this tool.
///
/// Backtick-anchored, and that is not fussiness. `me` is a real method name
/// and also an English word: a plain substring search would count every
/// sentence in every file as a mention of it, and the check below would
/// pass for a tool nothing had ever written down. The skills already write
/// a tool exactly one way -- `` `terminal_list` ``, `` `terminal_keys()` ``,
/// `` `group_post(group, text)` `` -- so requiring the opening backtick, and
/// refusing a longer identifier running on after the name, matches the prose
/// as it stands rather than asking anyone to write it differently.
fn namesTool(source: []const u8, tool: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, tool)) |at| {
        i = at + 1;
        if (at == 0 or source[at - 1] != '`') continue;

        // `terminal_action` must not be satisfied by `terminal_actions`.
        const after = at + tool.len;
        if (after < source.len) switch (source[after]) {
            'a'...'z', '0'...'9', '_' => continue,
            else => {},
        };
        return true;
    }
    return false;
}

test "every tool an unmarked terminal may call is named in some skill" {
    // The other direction from the test above, and the one that was
    // missing. That one stops a skill promising a tool that does not exist.
    // Nothing stopped the reverse: opening a tool to ordinary terminals and
    // shipping no prose about it, which is how `terminal_send`,
    // `terminal_key` and the rest came to be reachable by an agent that had
    // been handed only a skill addressed to supervisors.
    //
    // **The list is derived, not typed.** `requiresSupervisor` is an
    // exhaustive switch over `Method` with no `else`, so a method added
    // later does not compile until somebody has put it on one side or the
    // other -- and if they put it on the open side, this test is what asks
    // where it is written down. A hand-kept mirror of the open set would
    // be missing the next one silently, which is the failure this
    // repository has already shipped twice: the Swift `Plugin.Kind` list
    // that missed `archive`, and then missed `provision`.
    //
    // `requiresSupervisor(m) == false` is exactly "a terminal carrying no
    // mark may call this". Whether it may be *pointed* at a given terminal
    // is the reach rule and is the target's business, not the method's.
    const rpc = @import("rpc.zig");

    inline for (@typeInfo(rpc.Method).@"enum".fields) |f| {
        const method = @field(rpc.Method, f.name);
        if (!rpc.requiresSupervisor(method)) {
            const named = for (builtin_sources) |source| {
                if (namesTool(source, f.name)) break true;
            } else false;

            if (!named) {
                std.debug.print(
                    "\n{s} is callable by an unmarked terminal and no shipped " ++
                        "skill names it\n",
                    .{f.name},
                );
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "naming a tool means naming it, not containing its letters" {
    // The guard on the check above. Without the backtick anchor, `me`
    // would be found in "some" and the whole thing would be green for
    // prose that never mentioned a tool at all.
    try testing.expect(namesTool("read it with `terminal_read`.", "terminal_read"));
    try testing.expect(namesTool("`terminal_keys()` lists them", "terminal_keys"));
    try testing.expect(namesTool("`group_post(group, text)` says", "group_post"));

    try testing.expect(!namesTool("some sentences mention me somewhere", "me"));
    try testing.expect(!namesTool("call terminal_read first", "terminal_read"));

    // And the longer-name case: a file that only ever writes
    // `terminal_actions` has not named `terminal_action`.
    try testing.expect(!namesTool("`terminal_actions` lists them", "terminal_action"));
    try testing.expect(namesTool("`terminal_actions` lists them", "terminal_actions"));
}

test "every field the frontmatter carries has somewhere it goes" {
    // There used to be a `max_rounds`, and a test named "the clock-out
    // skill is the only one that sets max_rounds" watching over it. When
    // that skill was deleted the test kept passing -- its condition simply
    // became false for every remaining name, and the assertion quietly
    // turned into "none of them set it". A check that stops checking is
    // worse than no check: the green light reads the same either way.
    //
    // Chasing that turned up the real problem. `max_rounds` had no
    // consumer anywhere: parsed, range-checked, then dropped. That is
    // worse than refusing it the way `allow_clock_out` is refused, because
    // a user writing `max_rounds: 5` in their own skill would be told
    // nothing and would believe they had configured something.
    //
    // The three that remain each go somewhere, and the somewhere differs:
    //
    //   name         checked against the file it is in, and rewritten when
    //                the skill is installed for an agent runtime
    //   description  travels out in the installed frontmatter; it is what
    //                makes a runtime pick the skill up
    //   version      likewise; it is the file's own, not something this
    //                program branches on
    //
    // This is a list, not a derivation -- nothing can prove a field is
    // read. It is here so that adding a fourth field is a deliberate act:
    // the build stops, and whoever is adding it has to say where theirs
    // goes before it can ship.
    const accounted_for = [_][]const u8{ "name", "version", "description" };
    inline for (@typeInfo(Meta).@"struct".fields) |f| {
        comptime var found = false;
        inline for (accounted_for) |known| {
            if (comptime std.mem.eql(u8, f.name, known)) found = true;
        }
        if (!found) @compileError("Meta." ++ f.name ++ " is not accounted for: " ++
            "say where it goes, or take it out -- a field that is parsed " ++
            "and dropped tells the user it did something");
    }

    // And the other half of the same rule: nothing named here has been
    // removed from the struct while its name was left behind.
    try testing.expectEqual(
        accounted_for.len,
        @typeInfo(Meta).@"struct".fields.len,
    );
}

test "a path is built from a name, or refused" {
    const p = try userPath(testing.allocator, "/home/u/.config/ghostty", "supervising");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings(
        "/home/u/.config/ghostty/polter/skills/supervising.md",
        p,
    );

    const r = try resourcePath(testing.allocator, "/usr/share/ghostty", "reading-a-terminal");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("/usr/share/ghostty/poltergeist/reading-a-terminal.md", r);
}

test "a name that could escape the directory never becomes a path" {
    // The whole reason `isValidName` exists. If this ever regressed,
    // `skill_read("../../../etc/passwd")` would read whatever it liked.
    for ([_][]const u8{ "../../etc/passwd", "a/b", "..", "" }) |bad| {
        try testing.expectError(
            error.BadName,
            userPath(testing.allocator, "/cfg", bad),
        );
        try testing.expectError(
            error.BadName,
            resourcePath(testing.allocator, "/res", bad),
        );
    }
}
