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
//! off. That is a hard constraint and lives only in `Bus.WorkMode`. Skill
//! files are user-editable, and a constraint readable from one would be a
//! constraint a user could weaken by accident while editing prose.
//!
//! Pure: text in, values out. See `docs/poltergeist/mcp.md`.

const std = @import("std");

const Bus = @import("Bus.zig");

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

    /// Which work mode this skill is for, if it is a mode skill. Null for
    /// the two skills every supervisor reads.
    mode: ?Bus.WorkMode = null,

    /// How many rounds of being told a terminal is quiet should pass before
    /// the supervisor considers clocking it off. Zero when it does not
    /// apply.
    ///
    /// Counted by the program and reported in `terminal_list`, because a
    /// count is the first thing a long session forgets. The judgement of
    /// whether there is anything left to do stays with the supervisor.
    max_rounds: u16 = 0,

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
        } else if (std.mem.eql(u8, key, "mode")) {
            meta.mode = std.meta.stringToEnum(Bus.WorkMode, value) orelse
                return error.BadField;
        } else if (std.mem.eql(u8, key, "max_rounds")) {
            meta.max_rounds = std.fmt.parseUnsigned(u16, value, 10) catch
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
    "mode-clock-out",
    "mode-infinite-directed",
    "mode-infinite-sequential",
};

/// Which mode skill goes with a work mode.
pub fn modeSkill(mode: Bus.WorkMode) []const u8 {
    return switch (mode) {
        .clock_off => "mode-clock-out",
        .infinite_directed => "mode-infinite-directed",
        .infinite_sequential => "mode-infinite-sequential",
    };
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const sample =
    \\---
    \\name: mode-clock-out
    \\version: 2
    \\mode: clock_off
    \\max_rounds: 5
    \\description: 下班模式
    \\---
    \\First line of prose.
    \\
    \\Second paragraph.
;

test "a skill parses into its fields and its prose" {
    const s = try parse(sample);
    try testing.expectEqualStrings("mode-clock-out", s.meta.name);
    try testing.expectEqual(@as(u32, 2), s.meta.version);
    try testing.expectEqual(Bus.WorkMode.clock_off, s.meta.mode.?);
    try testing.expectEqual(@as(u16, 5), s.meta.max_rounds);
    try testing.expectEqualStrings("下班模式", s.meta.description);
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
    try testing.expect(s.meta.mode == null);
    try testing.expectEqual(@as(u16, 0), s.meta.max_rounds);
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
        \\name: mode-infinite-directed
        \\mode: infinite_directed
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
    try testing.expectError(error.BadField, parse(
        \\---
        \\name: x
        \\mode: sideways
        \\---
        \\body
    ));
    try testing.expectError(error.BadField, parse(
        \\---
        \\name: x
        \\max_rounds: lots
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
    try testing.expect(isValidName("mode-clock-out"));
    try testing.expect(isValidName("reading-a-terminal"));
}

test "a BOM and leading blank lines do not stop it loading" {
    const s = try parse("\xef\xbb\xbf\n\n---\nname: x\n---\nbody");
    try testing.expectEqualStrings("x", s.meta.name);
    try testing.expectEqualStrings("body", s.body);
}

test "every work mode has a skill and every mode skill is builtin" {
    for (std.enums.values(Bus.WorkMode)) |m| {
        const name = modeSkill(m);
        try testing.expect(isValidName(name));

        var found = false;
        for (builtin_names) |b| {
            if (std.mem.eql(u8, b, name)) found = true;
        }
        try testing.expect(found);
    }
}

test "the two general skills are not mode skills" {
    // If one of these ever gained a mode it would start being loaded per
    // terminal rather than once, which is not what they are for.
    for ([_][]const u8{ "supervising", "reading-a-terminal" }) |name| {
        for (std.enums.values(Bus.WorkMode)) |m| {
            try testing.expect(!std.mem.eql(u8, modeSkill(m), name));
        }
    }
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
    @embedFile("skills/mode-clock-out.md"),
    @embedFile("skills/mode-infinite-directed.md"),
    @embedFile("skills/mode-infinite-sequential.md"),
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

test "each mode skill declares the mode it is for" {
    for (builtin_sources, builtin_names) |source, name| {
        const s = try parse(source);

        if (std.mem.startsWith(u8, name, "mode-")) {
            const mode = s.meta.mode orelse {
                std.debug.print("\n{s} is a mode skill with no mode\n", .{name});
                return error.TestUnexpectedResult;
            };
            try testing.expectEqualStrings(name, modeSkill(mode));
        } else {
            // The two general skills are read once, not per terminal.
            try testing.expect(s.meta.mode == null);
        }
    }
}

test "the shipped skills do not promise what the tools cannot do" {
    // A skill that tells a supervisor to approve something on another
    // agent's behalf would be describing a tool that does not exist, and
    // the AI would go looking for it.
    for (builtin_sources, builtin_names) |source, name| {
        for ([_][]const u8{ "set_work_mode", "approve(", "grant_permission" }) |forbidden| {
            if (std.mem.indexOf(u8, source, forbidden) != null) {
                std.debug.print("\n{s} mentions {s}\n", .{ name, forbidden });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "the clock-out skill is the only one that sets max_rounds" {
    for (builtin_sources, builtin_names) |source, name| {
        const s = try parse(source);
        const expects_rounds = std.mem.eql(u8, name, "mode-clock-out");
        try testing.expectEqual(expects_rounds, s.meta.max_rounds > 0);
    }
}

test "a path is built from a name, or refused" {
    const p = try userPath(testing.allocator, "/home/u/.config/ghostty", "supervising");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings(
        "/home/u/.config/ghostty/polter/skills/supervising.md",
        p,
    );

    const r = try resourcePath(testing.allocator, "/usr/share/ghostty", "mode-clock-out");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("/usr/share/ghostty/poltergeist/mode-clock-out.md", r);
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
