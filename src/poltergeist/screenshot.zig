//! The seven `screenshot_*` tools, as far as the core carries them.
//!
//! The contract with the two hosts is `dev-docs/poltergeist/screenshot.md`,
//! section 10.1, and this file is the core's half of it:
//!
//!   * what an agent sent is turned into the request a host receives --
//!     checked first, so that a host never has to decide what a missing
//!     field means;
//!   * annotations are validated and written back out with every field
//!     present (`normalizeAnnotations`);
//!   * every path, the agent's and the host's, has to be a file this
//!     feature wrote, in the directory the host says it writes to
//!     (`nameInDirectory`);
//!   * `screenshot_info` and `screenshot_list` are answered here, from the
//!     files, without a host.
//!
//! **Nothing here knows how to capture a screen.** That, the composition
//! and the files are the host's; the core is a careful conduit, the same
//! shape `poltergeist_layout` has.
//!
//! Everything allocates from an arena the caller owns and frees whole, so
//! nothing below frees anything.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");

/// The request an agent made. One per tool that carries arguments.
///
/// ⚠️ **Every field is the raw JSON text of that parameter**, empty when it
/// was not given. `wire.zig` checks parameter *names* against these structs
/// and does nothing else; what a value may be is decided here, where the
/// rule and its test are in one file.
pub const CaptureArgs = struct {
    target: []const u8 = "",
    display: []const u8 = "",
    window_id: []const u8 = "",
    rect: []const u8 = "",
    terminal: []const u8 = "",
    annotations: []const u8 = "",
};

pub const AnnotateArgs = struct {
    path: []const u8 = "",
    annotations: []const u8 = "",
};

pub const LongArgs = struct {
    window_id: []const u8 = "",
    display: []const u8 = "",
    rect: []const u8 = "",
    pages: []const u8 = "",
};

pub const InfoArgs = struct {
    path: []const u8 = "",
    latest: []const u8 = "",
};

pub const ListArgs = struct {
    limit: []const u8 = "",
};

/// What a host is asked to do.
pub const Op = enum {
    directory,
    windows,
    capture,
    annotate,
    long,
};

/// One request to a host.
pub const HostRequest = struct {
    op: Op,
    /// The `spec` of the action, as JSON.
    spec: [:0]const u8,
    /// Set for a `capture` of a terminal's window: the action's target is
    /// that terminal's surface rather than the app.
    surface: ?Bus.Id = null,
    /// How long a host that answers `pending` is waited for.
    timeout_ms: u64 = 0,
};

/// What a host answered. Mirrors
/// `apprt.action.PoltergeistScreenshot.Result`.
pub const HostReply = union(enum) {
    /// The host wrote nothing: this platform has no such thing.
    unsupported,
    done: []const u8,
    refused: []const u8,
    /// The answer will come later. Whoever carried the request has parked
    /// it; nothing is to be answered now.
    pending,
};

pub const Failure = struct {
    code: []const u8,
    message: []const u8,
};

/// Who is asking, for the `meta` a host writes into the sidecar and its log.
pub const Meta = struct {
    by: Bus.Id,
    /// The caller's working directory, when it is known.
    cwd: ?[]const u8 = null,
};

pub const Prepared = union(enum) {
    failed: Failure,
    request: HostRequest,
};

pub const Answer = union(enum) {
    failed: Failure,
    /// A JSON document for the agent.
    json: []const u8,
};

/// The buffer a host's synchronous answer is written into.
pub const host_buffer_bytes: usize = 64 * 1024;

pub const directory_spec: [:0]const u8 = "{\"op\":\"directory\"}";
pub const windows_spec: [:0]const u8 = "{\"op\":\"windows\"}";

/// How long a `pending` answer is waited for.
pub fn timeoutMs(op: Op, pages: u32) u64 {
    return switch (op) {
        .directory, .windows => 0,
        .capture, .annotate => 15 * std.time.ms_per_s,
        .long => (10 + 3 * @as(u64, pages)) * std.time.ms_per_s,
    };
}

pub const max_pages: u32 = 20;
pub const max_annotations: usize = 200;
pub const max_text_bytes: usize = 2000;
pub const max_points: usize = 5000;
pub const max_list: u32 = 50;
pub const default_list: u32 = 10;

/// The steps a stroke may be, a text may be, and a mosaic's blocks may be:
/// sections 9.1 and 9.5. In points.
pub const widths = [_]i64{ 1, 2, 4, 6, 10 };
pub const font_sizes = [_]i64{ 14, 18, 24, 32, 44 };
pub const blocks = [_]i64{ 8, 12, 16, 24, 32 };

const default_color = "#E62828";

// -- names and paths --------------------------------------------------------

/// What a file this feature wrote is called.
pub const Name = struct {
    /// `YYYYMMDD-HHMMSS-mmm`.
    stem: []const u8,
    /// The `-N` of a long screenshot's tile, when there is one.
    tile: ?u16,
    kind: enum { png, json },
};

/// `YYYYMMDD-HHMMSS-mmm`, then optionally `-` and one to three digits, then
/// `.png` or `.json`. Nothing else.
///
/// **This is the whole of what keeps these tools from reading an arbitrary
/// file**, together with `nameInDirectory`: a path is accepted only when its
/// last component parses here.
pub fn parseName(name: []const u8) ?Name {
    const stem_len = 8 + 1 + 6 + 1 + 3;
    const Kind_ = @FieldType(Name, "kind");
    const kind: Kind_ = if (std.mem.endsWith(u8, name, ".png"))
        .png
    else if (std.mem.endsWith(u8, name, ".json"))
        .json
    else
        return null;
    const body = name[0 .. name.len - @as(usize, if (kind == .png) 4 else 5)];

    if (body.len < stem_len) return null;
    for (body[0..stem_len], 0..) |c, i| {
        if (i == 8 or i == 15) {
            if (c != '-') return null;
        } else if (!std.ascii.isDigit(c)) return null;
    }

    const rest = body[stem_len..];
    if (rest.len == 0) return .{ .stem = body[0..stem_len], .tile = null, .kind = kind };

    // `-N`, one to three digits. A tile has no sidecar of its own.
    if (rest[0] != '-' or rest.len < 2 or rest.len > 4) return null;
    if (kind != .png) return null;
    var n: u16 = 0;
    for (rest[1..]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        n = n * 10 + (c - '0');
    }
    return .{ .stem = body[0..stem_len], .tile = n, .kind = kind };
}

/// The file name of `path`, if `path` is a file of ours sitting directly in
/// `directory`.
///
/// Lexical, on purpose: `path` must be exactly the directory, one
/// separator, and a name with no separator in it. Nothing is normalised, so
/// `dir/../dir/x.png` and `dir/sub/x.png` are refused rather than
/// understood -- an agent that got the path from one of these tools has it
/// in exactly this form already.
///
/// ⚠️ **Not checked here: that the name is not a link to somewhere else.**
/// That needs the filesystem; `readOurs` does it before reading.
pub fn nameInDirectory(directory: []const u8, path: []const u8) ?[]const u8 {
    const dir = std.mem.trimEnd(u8, directory, "/\\");
    if (dir.len == 0) return null;
    if (path.len <= dir.len + 1) return null;
    if (!std.mem.eql(u8, path[0..dir.len], dir)) return null;
    if (path[dir.len] != '/' and path[dir.len] != '\\') return null;
    const name = path[dir.len + 1 ..];
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return null;
    if (parseName(name) == null) return null;
    return name;
}

fn badPath(alloc: Allocator, path: []const u8) Failure {
    return .{
        .code = "BadPath",
        .message = std.fmt.allocPrint(
            alloc,
            "`{s}` is not a screenshot: these tools only take a file directly inside the " ++
                "screenshot directory, named the way a screenshot is named " ++
                "(YYYYMMDD-HHMMSS-mmm.png). Use a path screenshot_list or screenshot_capture " ++
                "gave you, unchanged.",
            .{path},
        ) catch "that path is not a screenshot",
    };
}

// -- reading arguments ------------------------------------------------------

const Value = std.json.Value;

fn parse(alloc: Allocator, raw: []const u8) ?Value {
    if (raw.len == 0) return null;
    return std.json.parseFromSliceLeaky(Value, alloc, raw, .{}) catch null;
}

/// A whole number, from a JSON integer or a float that is one.
fn asInt(v: Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (@floor(f) == f and @abs(f) < 1e12) @intFromFloat(f) else null,
        else => null,
    };
}

/// A coordinate: any finite number, rounded to the pixel.
fn asCoord(v: Value) ?i64 {
    return switch (v) {
        .integer => |i| if (@abs(i) <= 1_000_000) i else null,
        .float => |f| if (std.math.isFinite(f) and @abs(f) <= 1e6) @intFromFloat(@round(f)) else null,
        else => null,
    };
}

fn asPoint(v: Value) ?[2]i64 {
    const a = switch (v) {
        .array => |a| a.items,
        else => return null,
    };
    if (a.len != 2) return null;
    return .{ asCoord(a[0]) orelse return null, asCoord(a[1]) orelse return null };
}

/// `[x, y, w, h]` with a width and a height of at least one.
fn asRect(v: Value) ?[4]i64 {
    const a = switch (v) {
        .array => |a| a.items,
        else => return null,
    };
    if (a.len != 4) return null;
    var out: [4]i64 = undefined;
    for (a, &out) |item, *o| o.* = asCoord(item) orelse return null;
    if (out[2] < 1 or out[3] < 1) return null;
    return out;
}

fn fail(alloc: Allocator, code: []const u8, comptime fmt: []const u8, args: anytype) Failure {
    return .{ .code = code, .message = std.fmt.allocPrint(alloc, fmt, args) catch code };
}

// -- annotations ------------------------------------------------------------

pub const Normalized = union(enum) {
    failed: Failure,
    /// A JSON array, every item complete. `"[]"` when there were none.
    json: []const u8,
};

const Kind = enum { rect, ellipse, line, arrow, pen, highlighter, text, number, mosaic };

fn allowedKeys(kind: Kind) []const []const u8 {
    return switch (kind) {
        .rect, .ellipse => &.{ "type", "rect", "color", "width" },
        .line, .arrow => &.{ "type", "from", "to", "color", "width" },
        .pen, .highlighter => &.{ "type", "points", "color", "width" },
        .text => &.{ "type", "at", "text", "color", "font_size" },
        .number => &.{ "type", "n", "at", "text", "color", "font_size" },
        .mosaic => &.{ "type", "rect", "block" },
    };
}

fn oneOf(steps: []const i64, v: i64) bool {
    for (steps) |s| if (s == v) return true;
    return false;
}

/// `#RRGGBB`, upper-cased. Nothing shorter, no names, no alpha.
fn asColor(alloc: Allocator, v: Value) ?[]const u8 {
    const s = switch (v) {
        .string => |s| s,
        else => return null,
    };
    if (s.len != 7 or s[0] != '#') return null;
    const out = alloc.alloc(u8, 7) catch return null;
    out[0] = '#';
    for (s[1..], out[1..]) |c, *o| {
        if (!std.ascii.isHex(c)) return null;
        o.* = std.ascii.toUpper(c);
    }
    return out;
}

/// Check what an agent sent and write it back with every field present, so
/// that a host parses one shape and never decides what a default is.
///
/// **A value that is not allowed is refused, not repaired.** A width of 3
/// is not rounded to 2 or 4: the picture that comes back would differ from
/// the one asked for and the reply would say it worked.
pub fn normalizeAnnotations(alloc: Allocator, raw: []const u8) Normalized {
    if (raw.len == 0) return .{ .json = "[]" };
    const root = parse(alloc, raw) orelse
        return .{ .failed = fail(alloc, "BadAnnotations", "`annotations` is not JSON", .{}) };
    const entries = switch (root) {
        .array => |a| a.items,
        .null => return .{ .json = "[]" },
        else => return .{ .failed = fail(alloc, "BadAnnotations", "`annotations` must be an array", .{}) },
    };
    if (entries.len > max_annotations) return .{ .failed = fail(
        alloc,
        "BadAnnotations",
        "{d} annotations; at most {d} are drawn in one call",
        .{ entries.len, max_annotations },
    ) };

    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    var next_number: i64 = 1;

    writeAll(w, "[");
    for (entries, 0..) |item, i| {
        const bad = struct {
            fn f(a: Allocator, index: usize, comptime what: []const u8) Normalized {
                return .{ .failed = fail(a, "BadAnnotations", "annotations[{d}]" ++ what, .{index}) };
            }
        }.f;

        const obj = switch (item) {
            .object => |o| o,
            else => return bad(alloc, i, " must be an object"),
        };
        const kind_name = switch (obj.get("type") orelse return bad(alloc, i, ".type is missing")) {
            .string => |s| s,
            else => return bad(alloc, i, ".type must be a string"),
        };
        const kind = std.meta.stringToEnum(Kind, kind_name) orelse return bad(
            alloc,
            i,
            ".type must be one of rect, ellipse, line, arrow, pen, highlighter, text, number, mosaic",
        );

        // A key this type does not take is a mistake rather than something
        // to skip: `width` on a text was meant to be `font_size`.
        var keys = obj.iterator();
        keys: while (keys.next()) |entry| {
            for (allowedKeys(kind)) |allowed| {
                if (std.mem.eql(u8, allowed, entry.key_ptr.*)) continue :keys;
            }
            return .{ .failed = fail(
                alloc,
                "BadAnnotations",
                "annotations[{d}] has `{s}`, which a {s} does not take",
                .{ i, entry.key_ptr.*, kind_name },
            ) };
        }

        if (i > 0) writeAll(w, ",");
        w.print("{{\"type\":\"{s}\"", .{kind_name}) catch {};

        switch (kind) {
            .rect, .ellipse, .mosaic => {
                const r = asRect(obj.get("rect") orelse return bad(alloc, i, ".rect is missing")) orelse
                    return bad(alloc, i, ".rect must be [x, y, w, h] with w and h of at least 1");
                w.print(",\"rect\":[{d},{d},{d},{d}]", .{ r[0], r[1], r[2], r[3] }) catch {};
            },
            .line, .arrow => {
                const from = asPoint(obj.get("from") orelse return bad(alloc, i, ".from is missing")) orelse
                    return bad(alloc, i, ".from must be [x, y]");
                const to = asPoint(obj.get("to") orelse return bad(alloc, i, ".to is missing")) orelse
                    return bad(alloc, i, ".to must be [x, y]");
                if (from[0] == to[0] and from[1] == to[1])
                    return bad(alloc, i, " has the same `from` and `to`: a line of no length");
                w.print(",\"from\":[{d},{d}],\"to\":[{d},{d}]", .{ from[0], from[1], to[0], to[1] }) catch {};
            },
            .pen, .highlighter => {
                const points = switch (obj.get("points") orelse return bad(alloc, i, ".points is missing")) {
                    .array => |a| a.items,
                    else => return bad(alloc, i, ".points must be an array of [x, y]"),
                };
                if (points.len < 2) return bad(alloc, i, ".points needs at least two points");
                if (points.len > max_points) return bad(alloc, i, ".points has too many points");
                writeAll(w, ",\"points\":[");
                for (points, 0..) |p, j| {
                    const xy = asPoint(p) orelse return bad(alloc, i, ".points must be an array of [x, y]");
                    if (j > 0) writeAll(w, ",");
                    w.print("[{d},{d}]", .{ xy[0], xy[1] }) catch {};
                }
                writeAll(w, "]");
            },
            .text, .number => {
                if (kind == .number) {
                    const n = if (obj.get("n")) |v|
                        (asInt(v) orelse return bad(alloc, i, ".n must be a whole number"))
                    else
                        next_number;
                    if (n < 1 or n > 999) return bad(alloc, i, ".n must be between 1 and 999");
                    next_number = n + 1;
                    w.print(",\"n\":{d}", .{n}) catch {};
                }
                const at = asPoint(obj.get("at") orelse return bad(alloc, i, ".at is missing")) orelse
                    return bad(alloc, i, ".at must be [x, y]");
                w.print(",\"at\":[{d},{d}]", .{ at[0], at[1] }) catch {};

                const text: []const u8 = if (obj.get("text")) |v| switch (v) {
                    .string => |s| s,
                    else => return bad(alloc, i, ".text must be a string"),
                } else "";
                if (kind == .text and text.len == 0) return bad(alloc, i, ".text is empty");
                if (text.len > max_text_bytes) return bad(alloc, i, ".text is too long");
                writeAll(w, ",\"text\":");
                std.json.Stringify.value(text, .{}, w) catch {};
            },
        }

        switch (kind) {
            .mosaic => {
                const block = if (obj.get("block")) |v|
                    (asInt(v) orelse return bad(alloc, i, ".block must be one of 8, 12, 16, 24, 32"))
                else
                    blocks[1];
                if (!oneOf(&blocks, block)) return bad(alloc, i, ".block must be one of 8, 12, 16, 24, 32");
                w.print(",\"block\":{d}", .{block}) catch {};
            },
            else => {
                const color = if (obj.get("color")) |v|
                    (asColor(alloc, v) orelse return bad(alloc, i, ".color must be \"#RRGGBB\""))
                else
                    default_color;
                w.print(",\"color\":\"{s}\"", .{color}) catch {};

                if (kind == .text or kind == .number) {
                    const size = if (obj.get("font_size")) |v|
                        (asInt(v) orelse return bad(alloc, i, ".font_size must be one of 14, 18, 24, 32, 44"))
                    else
                        font_sizes[1];
                    if (!oneOf(&font_sizes, size))
                        return bad(alloc, i, ".font_size must be one of 14, 18, 24, 32, 44");
                    w.print(",\"font_size\":{d}", .{size}) catch {};
                } else {
                    const width = if (obj.get("width")) |v|
                        (asInt(v) orelse return bad(alloc, i, ".width must be one of 1, 2, 4, 6, 10"))
                    else
                        widths[1];
                    if (!oneOf(&widths, width)) return bad(alloc, i, ".width must be one of 1, 2, 4, 6, 10");
                    w.print(",\"width\":{d}", .{width}) catch {};
                }
            },
        }
        writeAll(w, "}");
    }
    writeAll(w, "]");
    return .{ .json = out.written() };
}

fn writeAll(w: *std.Io.Writer, bytes: []const u8) void {
    w.writeAll(bytes) catch {};
}

// -- building a host's request ----------------------------------------------

fn writeMeta(w: *std.Io.Writer, meta: Meta) void {
    w.print(
        ",\"meta\":{{\"by\":\"agent\",\"agent_terminal\":\"0x{x:0>16}\",\"terminal\":{{\"id\":\"0x{x:0>16}\"",
        .{ meta.by, meta.by },
    ) catch {};
    if (meta.cwd) |cwd| {
        writeAll(w, ",\"cwd\":");
        std.json.Stringify.value(cwd, .{}, w) catch {};
    }
    writeAll(w, "}}");
}

fn finishSpec(alloc: Allocator, out: *std.Io.Writer.Allocating) ?[:0]const u8 {
    return alloc.dupeZ(u8, out.written()) catch null;
}

const oom: Failure = .{ .code = "OutOfMemory", .message = "out of memory" };

/// A terminal id, in either form the other tools take.
fn asTerminal(v: Value) ?Bus.Id {
    return switch (v) {
        .integer => |i| if (i < 0) null else @intCast(i),
        .string => |s| std.fmt.parseUnsigned(Bus.Id, s, 0) catch null,
        else => null,
    };
}

pub fn prepareCapture(alloc: Allocator, args: CaptureArgs, meta: Meta) Prepared {
    const target = switch (parse(alloc, args.target) orelse .null) {
        .string => |s| s,
        else => return .{ .failed = fail(
            alloc,
            "BadParams",
            "`target` must be \"display\", \"window\", \"region\" or \"terminal\"",
            .{},
        ) },
    };

    const annotations = switch (normalizeAnnotations(alloc, args.annotations)) {
        .failed => |f| return .{ .failed = f },
        .json => |j| j,
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    writeAll(w, "{\"op\":\"capture\",\"target\":");
    var surface: ?Bus.Id = null;

    const display: i64 = if (parse(alloc, args.display)) |v|
        (asInt(v) orelse return .{ .failed = fail(alloc, "BadParams", "`display` must be a whole number", .{}) })
    else
        0;
    if (display < 0 or display > 63)
        return .{ .failed = fail(alloc, "BadParams", "`display` is an index from screenshot_windows", .{}) };

    // Each target takes its own parameters and no others: a `window_id`
    // beside `target: "display"` is a call that meant something else.
    const given = .{
        .window_id = args.window_id.len > 0,
        .rect = args.rect.len > 0,
        .terminal = args.terminal.len > 0,
        .display = args.display.len > 0,
    };

    if (std.mem.eql(u8, target, "display")) {
        if (given.window_id or given.rect or given.terminal) return .{ .failed = fail(
            alloc,
            "BadParams",
            "target \"display\" takes `display` and nothing else",
            .{},
        ) };
        w.print("{{\"kind\":\"display\",\"index\":{d}}}", .{display}) catch {};
    } else if (std.mem.eql(u8, target, "window")) {
        if (given.rect or given.terminal or given.display) return .{ .failed = fail(
            alloc,
            "BadParams",
            "target \"window\" takes `window_id` and nothing else",
            .{},
        ) };
        const id = asInt(parse(alloc, args.window_id) orelse .null) orelse return .{ .failed = fail(
            alloc,
            "BadParams",
            "target \"window\" needs `window_id`, a number from screenshot_windows",
            .{},
        ) };
        if (id < 0) return .{ .failed = fail(alloc, "BadParams", "`window_id` is not negative", .{}) };
        w.print("{{\"kind\":\"window\",\"window_id\":{d}}}", .{id}) catch {};
    } else if (std.mem.eql(u8, target, "region")) {
        if (given.window_id or given.terminal) return .{ .failed = fail(
            alloc,
            "BadParams",
            "target \"region\" takes `display` and `rect` and nothing else",
            .{},
        ) };
        const r = asRect(parse(alloc, args.rect) orelse .null) orelse return .{ .failed = fail(
            alloc,
            "BadParams",
            "target \"region\" needs `rect`: [x, y, w, h] in that display's pixels, w and h at least 1",
            .{},
        ) };
        w.print(
            "{{\"kind\":\"region\",\"display\":{d},\"rect\":[{d},{d},{d},{d}]}}",
            .{ display, r[0], r[1], r[2], r[3] },
        ) catch {};
    } else if (std.mem.eql(u8, target, "terminal")) {
        if (given.window_id or given.rect or given.display) return .{ .failed = fail(
            alloc,
            "BadParams",
            "target \"terminal\" takes `terminal` and nothing else",
            .{},
        ) };
        surface = if (parse(alloc, args.terminal)) |v|
            (asTerminal(v) orelse return .{ .failed = fail(
                alloc,
                "BadParams",
                "`terminal` must be a terminal id, as terminal_list gives them",
                .{},
            ) })
        else
            meta.by;
        writeAll(w, "{\"kind\":\"terminal\"}");
    } else return .{ .failed = fail(
        alloc,
        "BadParams",
        "`target` must be \"display\", \"window\", \"region\" or \"terminal\", not \"{s}\"",
        .{target},
    ) };

    w.print(",\"annotations\":{s}", .{annotations}) catch {};
    writeMeta(w, meta);
    writeAll(w, "}");

    return .{ .request = .{
        .op = .capture,
        .spec = finishSpec(alloc, &out) orelse return .{ .failed = oom },
        .surface = surface,
        .timeout_ms = timeoutMs(.capture, 0),
    } };
}

/// `directory` is the one the host reported; the path has to be in it.
pub fn prepareAnnotate(
    alloc: Allocator,
    args: AnnotateArgs,
    meta: Meta,
    directory: []const u8,
) Prepared {
    const path = switch (parse(alloc, args.path) orelse .null) {
        .string => |s| s,
        else => return .{ .failed = fail(alloc, "BadParams", "`path` must be a string", .{}) },
    };
    const name = nameInDirectory(directory, path) orelse return .{ .failed = badPath(alloc, path) };
    const parsed = parseName(name) orelse return .{ .failed = badPath(alloc, path) };
    if (parsed.kind != .png) return .{ .failed = badPath(alloc, path) };

    const annotations = switch (normalizeAnnotations(alloc, args.annotations)) {
        .failed => |f| return .{ .failed = f },
        .json => |j| j,
    };
    if (std.mem.eql(u8, annotations, "[]")) return .{ .failed = fail(
        alloc,
        "BadAnnotations",
        "`annotations` is empty: there is nothing to draw, so no new file would differ from the old one",
        .{},
    ) };

    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    writeAll(w, "{\"op\":\"annotate\",\"path\":");
    std.json.Stringify.value(path, .{}, w) catch {};
    w.print(",\"annotations\":{s}", .{annotations}) catch {};
    writeMeta(w, meta);
    writeAll(w, "}");

    return .{ .request = .{
        .op = .annotate,
        .spec = finishSpec(alloc, &out) orelse return .{ .failed = oom },
        .timeout_ms = timeoutMs(.annotate, 0),
    } };
}

pub fn prepareLong(alloc: Allocator, args: LongArgs, meta: Meta) Prepared {
    const pages = asInt(parse(alloc, args.pages) orelse .null) orelse return .{ .failed = fail(
        alloc,
        "BadParams",
        "`pages` is how many screens to scroll: a whole number from 1 to {d}",
        .{max_pages},
    ) };
    if (pages < 1 or pages > max_pages) return .{ .failed = fail(
        alloc,
        "BadParams",
        "`pages` must be from 1 to {d}",
        .{max_pages},
    ) };

    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    writeAll(w, "{\"op\":\"long\",\"target\":");

    const has_window = args.window_id.len > 0;
    const has_rect = args.rect.len > 0;
    if (has_window == has_rect) return .{ .failed = fail(
        alloc,
        "BadParams",
        "give `window_id`, or `display` and `rect` -- one of the two, not both and not neither",
        .{},
    ) };

    if (has_window) {
        if (args.display.len > 0) return .{ .failed = fail(
            alloc,
            "BadParams",
            "`display` goes with `rect`, not with `window_id`",
            .{},
        ) };
        const id = asInt(parse(alloc, args.window_id) orelse .null) orelse return .{ .failed = fail(
            alloc,
            "BadParams",
            "`window_id` must be a number from screenshot_windows",
            .{},
        ) };
        if (id < 0) return .{ .failed = fail(alloc, "BadParams", "`window_id` is not negative", .{}) };
        w.print("{{\"kind\":\"window\",\"window_id\":{d}}}", .{id}) catch {};
    } else {
        const display: i64 = if (parse(alloc, args.display)) |v|
            (asInt(v) orelse return .{ .failed = fail(alloc, "BadParams", "`display` must be a whole number", .{}) })
        else
            0;
        if (display < 0 or display > 63)
            return .{ .failed = fail(alloc, "BadParams", "`display` is an index from screenshot_windows", .{}) };
        const r = asRect(parse(alloc, args.rect) orelse .null) orelse return .{ .failed = fail(
            alloc,
            "BadParams",
            "`rect` must be [x, y, w, h] in that display's pixels, w and h at least 1",
            .{},
        ) };
        w.print(
            "{{\"kind\":\"region\",\"display\":{d},\"rect\":[{d},{d},{d},{d}]}}",
            .{ display, r[0], r[1], r[2], r[3] },
        ) catch {};
    }

    w.print(",\"pages\":{d}", .{pages}) catch {};
    writeMeta(w, meta);
    writeAll(w, "}");

    return .{ .request = .{
        .op = .long,
        .spec = finishSpec(alloc, &out) orelse return .{ .failed = oom },
        .timeout_ms = timeoutMs(.long, @intCast(pages)),
    } };
}

// -- reading a host's answer ------------------------------------------------

/// What a host said when it refused: `{"code", "message"}`.
///
/// A refusal that cannot be read is the host's fault and is reported as
/// that, rather than passed on as though it were about the agent's call.
pub fn refusal(alloc: Allocator, json: []const u8) Failure {
    const fault: Failure = .{
        .code = "HostFault",
        .message = "the screenshot was refused and the reason could not be read. " ++
            "This is a defect in Polter, not in the call.",
    };
    const obj = switch (parse(alloc, json) orelse return fault) {
        .object => |o| o,
        else => return fault,
    };
    const code = switch (obj.get("code") orelse return fault) {
        .string => |s| s,
        else => return fault,
    };
    if (code.len == 0) return fault;
    const message = switch (obj.get("message") orelse Value{ .string = "" }) {
        .string => |s| s,
        else => "",
    };
    return .{ .code = code, .message = if (message.len > 0) message else code };
}

/// The directory in a host's answer to `directory`.
pub fn directoryOf(alloc: Allocator, json: []const u8) ?[]const u8 {
    const obj = switch (parse(alloc, json) orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const dir = switch (obj.get("directory") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (dir.len == 0) return null;
    return dir;
}

const host_fault_paths: Failure = .{
    .code = "HostFault",
    .message = "the screenshot was taken, but the answer about where it is could not be trusted: " ++
        "it names a file outside the screenshot directory. This is a defect in Polter, not in the call.",
};

const host_fault_json: Failure = .{
    .code = "HostFault",
    .message = "the screenshot answer could not be read. This is a defect in Polter, not in the call.",
};

/// A host's `done` for `op`, checked, as the answer the agent gets.
///
/// **Every path a host hands back goes through the same gate an agent's
/// does.** A host that wrote somewhere else has a bug, and passing that
/// path on would teach the agent a path the other tools then refuse.
pub fn finish(alloc: Allocator, op: Op, directory: []const u8, json: []const u8) Answer {
    switch (op) {
        .directory => unreachable,
        .windows => {
            _ = parse(alloc, json) orelse return .{ .failed = host_fault_json };
            return .{ .json = json };
        },
        .capture, .annotate, .long => {},
    }

    const obj = switch (parse(alloc, json) orelse return .{ .failed = host_fault_json }) {
        .object => |o| o,
        else => return .{ .failed = host_fault_json },
    };

    inline for (.{ "path", "json" }) |key| {
        const p = switch (obj.get(key) orelse return .{ .failed = host_fault_json }) {
            .string => |s| s,
            else => return .{ .failed = host_fault_json },
        };
        if (nameInDirectory(directory, p) == null) return .{ .failed = host_fault_paths };
    }

    if (obj.get("tiles")) |tiles| {
        const items = switch (tiles) {
            .array => |a| a.items,
            else => return .{ .failed = host_fault_json },
        };
        for (items) |tile| {
            const t = switch (tile) {
                .object => |o| o,
                else => return .{ .failed = host_fault_json },
            };
            // A tile is named by file name alone, beside the whole image.
            const image = switch (t.get("image") orelse return .{ .failed = host_fault_json }) {
                .string => |s| s,
                else => return .{ .failed = host_fault_json },
            };
            if (std.mem.indexOfAny(u8, image, "/\\") != null) return .{ .failed = host_fault_paths };
            const name = parseName(image) orelse return .{ .failed = host_fault_paths };
            if (name.tile == null) return .{ .failed = host_fault_paths };
        }
    } else if (op == .long) return .{ .failed = host_fault_json };

    return .{ .json = json };
}

// -- info and list ----------------------------------------------------------

/// Read a file of ours out of `directory`, refusing a link.
fn readOurs(
    io: std.Io,
    alloc: Allocator,
    directory: []const u8,
    name: []const u8,
    limit: usize,
) ?[]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{}) catch return null;
    defer dir.close(io);
    // The name passed the pattern; what it must not be is a link somebody
    // put there to point these tools at another file.
    const st = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return null;
    if (st.kind != .file) return null;
    return dir.readFileAlloc(io, name, alloc, .limited(limit)) catch null;
}

const max_sidecar_bytes: usize = 4 * 1024 * 1024;

fn sidecarNameOf(alloc: Allocator, name: []const u8) ?[]const u8 {
    const parsed = parseName(name) orelse return null;
    return std.fmt.allocPrint(alloc, "{s}.json", .{parsed.stem}) catch null;
}

/// The newest screenshots in `directory`, newest first: whole images only,
/// not tiles and not sidecars. The name is the time, so sorting names sorts
/// by time.
fn newest(io: std.Io, alloc: Allocator, directory: []const u8, limit: usize) [][]const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const parsed = parseName(entry.name) orelse continue;
        if (parsed.kind != .png or parsed.tile != null) continue;
        names.append(alloc, alloc.dupe(u8, entry.name) catch continue) catch continue;
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn newerFirst(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .gt;
        }
    }.newerFirst);
    return names.items[0..@min(limit, names.items.len)];
}

/// `screenshot_info`: the sidecar of one screenshot, whole.
pub fn info(io: std.Io, alloc: Allocator, directory: []const u8, args: InfoArgs) Answer {
    const latest = switch (parse(alloc, args.latest) orelse Value{ .bool = false }) {
        .bool => |b| b,
        else => return .{ .failed = fail(alloc, "BadParams", "`latest` must be true or false", .{}) },
    };
    const has_path = args.path.len > 0;
    if (has_path == latest) return .{ .failed = fail(
        alloc,
        "BadParams",
        "give `path`, or `latest: true` -- one of the two",
        .{},
    ) };

    const name: []const u8 = if (latest) name: {
        const found = newest(io, alloc, directory, 1);
        if (found.len == 0) return .{ .failed = .{
            .code = "NotFound",
            .message = "there are no screenshots yet",
        } };
        break :name found[0];
    } else name: {
        const path = switch (parse(alloc, args.path) orelse .null) {
            .string => |s| s,
            else => return .{ .failed = fail(alloc, "BadParams", "`path` must be a string", .{}) },
        };
        break :name nameInDirectory(directory, path) orelse return .{ .failed = badPath(alloc, path) };
    };

    const sidecar = sidecarNameOf(alloc, name) orelse return .{ .failed = oom };
    const text = readOurs(io, alloc, directory, sidecar, max_sidecar_bytes) orelse return .{ .failed = fail(
        alloc,
        "NotFound",
        "`{s}` has no metadata beside it. An image pasted from the clipboard is saved without " ++
            "any; only a screenshot taken here has it.",
        .{name},
    ) };
    // Handed on only if it is JSON: a sidecar somebody truncated would
    // otherwise break the reply it is embedded in.
    _ = parse(alloc, text) orelse return .{ .failed = fail(
        alloc,
        "NotFound",
        "the metadata beside `{s}` cannot be read",
        .{name},
    ) };
    return .{ .json = text };
}

/// The width and height in a PNG's header, without decoding it.
fn pngSize(bytes: []const u8) ?[2]u32 {
    const signature = "\x89PNG\r\n\x1a\n";
    if (bytes.len < 24) return null;
    if (!std.mem.eql(u8, bytes[0..8], signature)) return null;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    return .{
        std.mem.readInt(u32, bytes[16..20], .big),
        std.mem.readInt(u32, bytes[20..24], .big),
    };
}

/// `20261006-153012-123` as `2026-10-06T15:30:12.123`: the local time the
/// name was made from, with no zone, because the name has none.
fn timeOfStem(alloc: Allocator, stem: []const u8) []const u8 {
    return std.fmt.allocPrint(alloc, "{s}-{s}-{s}T{s}:{s}:{s}.{s}", .{
        stem[0..4],   stem[4..6],   stem[6..8],
        stem[9..11],  stem[11..13], stem[13..15],
        stem[16..19],
    }) catch stem;
}

/// `screenshot_list`: the newest few, with what their sidecars say.
pub fn list(io: std.Io, alloc: Allocator, directory: []const u8, args: ListArgs) Answer {
    const limit: i64 = if (parse(alloc, args.limit)) |v|
        (asInt(v) orelse return .{ .failed = fail(alloc, "BadParams", "`limit` must be a whole number", .{}) })
    else
        default_list;
    if (limit < 1 or limit > max_list) return .{ .failed = fail(
        alloc,
        "BadParams",
        "`limit` must be from 1 to {d}",
        .{max_list},
    ) };

    const dir = std.mem.trimEnd(u8, directory, "/\\");
    const sep: u8 = if (std.mem.indexOfScalar(u8, directory, '\\') != null) '\\' else '/';

    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    writeAll(w, "{\"directory\":");
    std.json.Stringify.value(dir, .{}, w) catch {};
    writeAll(w, ",\"screenshots\":[");

    for (newest(io, alloc, directory, @intCast(limit)), 0..) |name, i| {
        if (i > 0) writeAll(w, ",");
        const stem = parseName(name).?.stem;
        const path = std.fmt.allocPrint(alloc, "{s}{c}{s}", .{ dir, sep, name }) catch continue;
        writeAll(w, "{\"path\":");
        std.json.Stringify.value(path, .{}, w) catch {};
        writeAll(w, ",\"time\":");
        std.json.Stringify.value(timeOfStem(alloc, stem), .{}, w) catch {};

        const sidecar_name = sidecarNameOf(alloc, name) orelse "";
        const sidecar: ?std.json.ObjectMap = sidecar: {
            const text = readOurs(io, alloc, directory, sidecar_name, max_sidecar_bytes) orelse break :sidecar null;
            break :sidecar switch (parse(alloc, text) orelse break :sidecar null) {
                .object => |o| o,
                else => null,
            };
        };

        if (sidecar) |meta| {
            // The sidecar's own values, re-serialised: never the file's
            // bytes spliced in.
            inline for (.{ "size", "source", "by" }) |key| {
                if (meta.get(key)) |v| {
                    writeAll(w, ",\"" ++ key ++ "\":");
                    std.json.Stringify.value(v, .{}, w) catch {};
                }
            }
            const count: usize = if (meta.get("annotations")) |v| switch (v) {
                .array => |a| a.items.len,
                else => 0,
            } else 0;
            w.print(",\"annotations\":{d}", .{count}) catch {};
            if (meta.get("tiles")) |v| switch (v) {
                .array => |a| w.print(",\"tiles\":{d}", .{a.items.len}) catch {},
                else => {},
            };
        } else if (readOurs(io, alloc, directory, name, 64)) |head| {
            if (pngSize(head)) |size| w.print(",\"size\":[{d},{d}]", .{ size[0], size[1] }) catch {};
        }
        writeAll(w, "}");
    }
    writeAll(w, "]}");
    return .{ .json = out.written() };
}

// -- requests a host has not answered yet -----------------------------------

/// The requests a host answered `pending` to, held until it calls back.
///
/// Generic over what is held so that it can be tested with something that
/// is not a live `Server.Pending`.
///
/// ⚠️ **Swept when something else happens, not by a timer** -- the
/// limitation `PersonaWaits` states, for the same reason and with the same
/// cost: on an idle app a request whose host never calls back can overstay
/// its deadline, and is answered `Timeout` at the next request of any kind.
pub fn Waits(comptime Held: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            token: u64,
            held: Held,
            op: Op,
            /// The directory the host reported, for checking its answer.
            directory: []const u8,
            deadline_ms: u64,
        };

        entries: std.ArrayListUnmanaged(Entry) = .empty,
        /// Tokens start at one: zero is what an out cell nobody filled in
        /// carries.
        next_token: u64 = 1,

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.entries.deinit(alloc);
            self.* = undefined;
        }

        /// The token the next request will carry.
        pub fn issue(self: *Self) u64 {
            const token = self.next_token;
            self.next_token += 1;
            return token;
        }

        pub fn park(self: *Self, alloc: Allocator, entry: Entry) Allocator.Error!void {
            try self.entries.append(alloc, entry);
        }

        /// The request with this token, taken out. Null when there is none:
        /// it was never parked, was answered already, or ran out of time.
        pub fn take(self: *Self, token: u64) ?Entry {
            for (self.entries.items, 0..) |e, i| {
                if (e.token == token) return self.entries.swapRemove(i);
            }
            return null;
        }

        /// One request whose deadline has passed, taken out. Call until null.
        pub fn takeExpired(self: *Self, now_ms: u64) ?Entry {
            for (self.entries.items, 0..) |e, i| {
                if (now_ms >= e.deadline_ms) return self.entries.swapRemove(i);
            }
            return null;
        }
    };
}

pub const timeout: Failure = .{
    .code = "Timeout",
    .message = "the screenshot did not finish in time and its result, if one arrives, is discarded. " ++
        "Nothing is known about whether a file was written; screenshot_list will show it if one was.",
};

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// The code of a refusal, or a word no test expects: so that an answer
/// that was not a refusal fails the comparison instead of the test runner.
fn codeOf(a: anytype) []const u8 {
    return switch (a) {
        .failed => |f| f.code,
        else => "(not refused)",
    };
}

fn jsonOf(a: Answer) []const u8 {
    return switch (a) {
        .json => |j| j,
        .failed => |f| f.code,
    };
}

test "screenshot: a name we write parses, and says what it is" {
    const whole = parseName("20261006-153012-123.png").?;
    try testing.expectEqualStrings("20261006-153012-123", whole.stem);
    try testing.expectEqual(@as(?u16, null), whole.tile);
    try testing.expect(whole.kind == .png);

    const sidecar = parseName("20261006-153012-123.json").?;
    try testing.expect(sidecar.kind == .json);

    const tile = parseName("20261006-153012-123-12.png").?;
    try testing.expectEqualStrings("20261006-153012-123", tile.stem);
    try testing.expectEqual(@as(?u16, 12), tile.tile);

    const tile_max = parseName("20261006-153012-123-999.png").?;
    try testing.expectEqual(@as(?u16, 999), tile_max.tile);
}

test "screenshot: a name that only looks like ours does not parse" {
    for ([_][]const u8{
        "",
        ".png",
        "holiday.png",
        "20261006-153012-123",
        "20261006-153012-123.jpg",
        "20261006-153012-123.PNG",
        "20261006-153012-12.png",
        "20261006_153012_123.png",
        "2026100a-153012-123.png",
        "x20261006-153012-123.png",
        "20261006-153012-123.png.bak",
        "20261006-153012-123 .png",
        // A tile suffix that is not one to three digits.
        "20261006-153012-123-.png",
        "20261006-153012-123-1234.png",
        "20261006-153012-123-a.png",
        "20261006-153012-123_1.png",
        "20261006-153012-1234.png",
        // A tile has no sidecar of its own.
        "20261006-153012-123-1.json",
    }) |name| {
        const parsed = parseName(name);
        if (parsed != null) std.debug.print("`{s}` was taken for one of ours\n", .{name});
        try testing.expect(parsed == null);
    }
}

test "screenshot: only a file directly inside the directory is accepted" {
    const dir = "/state/polter/shots";
    const direct = nameInDirectory(dir, "/state/polter/shots/20261006-153012-123.png");
    try testing.expectEqualStrings("20261006-153012-123.png", direct.?);

    // A trailing separator on the directory is the same directory.
    const trailing = nameInDirectory("/state/polter/shots/", "/state/polter/shots/20261006-153012-123.png");
    try testing.expect(trailing != null);

    // Windows, both separators.
    const windows = nameInDirectory("C:\\Users\\u\\shots", "C:\\Users\\u\\shots\\20261006-153012-123.png");
    try testing.expect(windows != null);

    for ([_][]const u8{
        // Somewhere else entirely.
        "/etc/passwd",
        "/tmp/20261006-153012-123.png",
        // A sibling whose name starts the same.
        "/state/polter/shots-other/20261006-153012-123.png",
        "/state/polter/shots20261006-153012-123.png",
        "/state/polter/shotsX20261006-153012-123.png",
        // Another directory whose path is exactly as long.
        "/state/polter/shotz/20261006-153012-123.png",
        // Not a direct child.
        "/state/polter/shots/sub/20261006-153012-123.png",
        // Out and back in: refused rather than understood.
        "/state/polter/shots/../shots/20261006-153012-123.png",
        "/state/polter/shots/../../../etc/passwd",
        // In the directory, not named like ours.
        "/state/polter/shots/notes.json",
        "/state/polter/shots/",
        "/state/polter/shots",
        // Relative.
        "20261006-153012-123.png",
        "shots/20261006-153012-123.png",
    }) |path| {
        const accepted = nameInDirectory(dir, path);
        if (accepted != null) std.debug.print("`{s}` was accepted\n", .{path});
        try testing.expect(accepted == null);
    }

    // No directory is no directory, not the root.
    const no_dir = nameInDirectory("", "/20261006-153012-123.png");
    try testing.expect(no_dir == null);
}

fn expectNormalized(raw: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    switch (normalizeAnnotations(arena.allocator(), raw)) {
        .json => |j| try testing.expectEqualStrings(expected, j),
        .failed => |f| {
            std.debug.print("refused: {s}\n", .{f.message});
            return error.UnexpectedRefusal;
        },
    }
}

fn expectRefused(raw: []const u8, needle: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    switch (normalizeAnnotations(arena.allocator(), raw)) {
        .json => |j| {
            std.debug.print("accepted: {s}\n", .{j});
            return error.UnexpectedlyAccepted;
        },
        .failed => |f| {
            try testing.expectEqualStrings("BadAnnotations", f.code);
            const names_it = std.mem.indexOf(u8, f.message, needle) != null;
            if (!names_it) std.debug.print("`{s}` does not mention `{s}`\n", .{ f.message, needle });
            try testing.expect(names_it);
        },
    }
}

test "screenshot: annotations come back with every field filled in" {
    try expectNormalized("", "[]");
    try expectNormalized("null", "[]");
    try expectNormalized("[]", "[]");

    // Defaults: red, the second width, the second size, the second block.
    try expectNormalized(
        \\[{"type":"rect","rect":[1,2,3,4]}]
    ,
        \\[{"type":"rect","rect":[1,2,3,4],"color":"#E62828","width":2}]
    );
    try expectNormalized(
        \\[{"type":"text","at":[5,6],"text":"间距 \"太大\""}]
    ,
        \\[{"type":"text","at":[5,6],"text":"间距 \"太大\"","color":"#E62828","font_size":18}]
    );
    try expectNormalized(
        \\[{"type":"mosaic","rect":[0,0,10,10]}]
    ,
        \\[{"type":"mosaic","rect":[0,0,10,10],"block":12}]
    );

    // What was given is kept; a colour is upper-cased; a float is rounded.
    try expectNormalized(
        \\[{"type":"arrow","from":[0.4,0.6],"to":[10,20],"color":"#2f6fed","width":10},
        \\ {"type":"ellipse","rect":[1,1,2,2],"width":1},
        \\ {"type":"highlighter","points":[[0,0],[5,5],[9,1]],"color":"#FFD400","width":6},
        \\ {"type":"mosaic","rect":[0,0,10,10],"block":32}]
    ,
        \\[{"type":"arrow","from":[0,1],"to":[10,20],"color":"#2F6FED","width":10},
    ++
        \\{"type":"ellipse","rect":[1,1,2,2],"color":"#E62828","width":1},
    ++
        \\{"type":"highlighter","points":[[0,0],[5,5],[9,1]],"color":"#FFD400","width":6},
    ++
        \\{"type":"mosaic","rect":[0,0,10,10],"block":32}]
    );
}

test "screenshot: numbers count from one, and carry on from one that was given" {
    try expectNormalized(
        \\[{"type":"number","at":[1,1]},
        \\ {"type":"number","at":[2,2],"text":"here"},
        \\ {"type":"number","at":[3,3],"n":7},
        \\ {"type":"number","at":[4,4]}]
    ,
        \\[{"type":"number","n":1,"at":[1,1],"text":"","color":"#E62828","font_size":18},
    ++
        \\{"type":"number","n":2,"at":[2,2],"text":"here","color":"#E62828","font_size":18},
    ++
        \\{"type":"number","n":7,"at":[3,3],"text":"","color":"#E62828","font_size":18},
    ++
        \\{"type":"number","n":8,"at":[4,4],"text":"","color":"#E62828","font_size":18}]
    );
}

test "screenshot: an annotation that is not allowed is refused, and the refusal says which" {
    try expectRefused("{}", "must be an array");
    try expectRefused("[1]", "annotations[0] must be an object");
    try expectRefused("[{}]", "annotations[0].type is missing");
    try expectRefused(
        \\[{"type":"rect","rect":[1,2,3,4]},{"type":"circle"}]
    , "annotations[1].type must be one of");

    // A step that is not a step is refused, not rounded to a neighbour.
    try expectRefused(
        \\[{"type":"rect","rect":[1,2,3,4],"width":3}]
    , "annotations[0].width must be one of 1, 2, 4, 6, 10");
    try expectRefused(
        \\[{"type":"text","at":[1,2],"text":"x","font_size":16}]
    , "annotations[0].font_size must be one of");
    try expectRefused(
        \\[{"type":"mosaic","rect":[1,2,3,4],"block":10}]
    , "annotations[0].block must be one of");

    // A key the type does not take.
    try expectRefused(
        \\[{"type":"text","at":[1,2],"text":"x","width":2}]
    , "has `width`, which a text does not take");
    try expectRefused(
        \\[{"type":"mosaic","rect":[1,2,3,4],"color":"#FFFFFF"}]
    , "has `color`, which a mosaic does not take");
    try expectRefused(
        \\[{"type":"pen","bbox":[1,2,3,4]}]
    , "has `bbox`, which a pen does not take");

    // Shapes that are not shapes.
    try expectRefused(
        \\[{"type":"rect","rect":[1,2,0,4]}]
    , "annotations[0].rect must be");
    try expectRefused(
        \\[{"type":"rect","rect":[1,2,3]}]
    , "annotations[0].rect must be");
    try expectRefused(
        \\[{"type":"line","from":[1,2],"to":[1,2]}]
    , "a line of no length");
    try expectRefused(
        \\[{"type":"pen","points":[[1,2]]}]
    , "at least two points");
    try expectRefused(
        \\[{"type":"text","at":[1,2],"text":""}]
    , "annotations[0].text is empty");
    try expectRefused(
        \\[{"type":"text","at":[1,2]}]
    , "annotations[0].text is empty");

    // Colours.
    for ([_][]const u8{ "red", "#FFF", "#GGGGGG", "#E62828FF", "E62828", "0E62828" }) |color| {
        var buf: [128]u8 = undefined;
        const raw = try std.fmt.bufPrint(&buf, "[{{\"type\":\"rect\",\"rect\":[1,2,3,4],\"color\":\"{s}\"}}]", .{color});
        try expectRefused(raw, "annotations[0].color must be");
    }

    try expectRefused(
        \\[{"type":"number","at":[1,2],"n":0}]
    , "annotations[0].n must be between");
}

test "screenshot: there is a limit to how much one call draws" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var many: std.Io.Writer.Allocating = .init(alloc);
    try many.writer.writeAll("[");
    for (0..max_annotations + 1) |i| {
        if (i > 0) try many.writer.writeAll(",");
        try many.writer.writeAll("{\"type\":\"rect\",\"rect\":[1,2,3,4]}");
    }
    try many.writer.writeAll("]");
    try expectRefused(many.written(), "at most 200");

    const long_text = try alloc.alloc(u8, max_text_bytes + 1);
    @memset(long_text, 'a');
    const raw = try std.fmt.allocPrint(alloc, "[{{\"type\":\"text\",\"at\":[1,2],\"text\":\"{s}\"}}]", .{long_text});
    try expectRefused(raw, "annotations[0].text is too long");
}

const test_meta: Meta = .{ .by = 0x2a, .cwd = "/work/proj" };
const test_meta_json = ",\"meta\":{\"by\":\"agent\",\"agent_terminal\":\"0x000000000000002a\"," ++
    "\"terminal\":{\"id\":\"0x000000000000002a\",\"cwd\":\"/work/proj\"}}}";

fn expectCapture(args: CaptureArgs, target_json: []const u8, surface: ?Bus.Id) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    switch (prepareCapture(alloc, args, test_meta)) {
        .failed => |f| {
            std.debug.print("refused: {s}\n", .{f.message});
            return error.UnexpectedRefusal;
        },
        .request => |r| {
            const expected = try std.fmt.allocPrint(
                alloc,
                "{{\"op\":\"capture\",\"target\":{s},\"annotations\":[]{s}",
                .{ target_json, test_meta_json },
            );
            try testing.expectEqualStrings(expected, r.spec);
            try testing.expectEqual(surface, r.surface);
            try testing.expect(r.op == .capture);
            try testing.expectEqual(@as(u64, 15_000), r.timeout_ms);
        },
    }
}

fn expectCaptureRefused(args: CaptureArgs, needle: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    switch (prepareCapture(arena.allocator(), args, test_meta)) {
        .request => |r| {
            std.debug.print("accepted: {s}\n", .{r.spec});
            return error.UnexpectedlyAccepted;
        },
        .failed => |f| {
            const names_it = std.mem.indexOf(u8, f.message, needle) != null;
            if (!names_it) std.debug.print("`{s}` does not mention `{s}`\n", .{ f.message, needle });
            try testing.expect(names_it);
        },
    }
}

test "screenshot: each capture target becomes the request a host is promised" {
    try expectCapture(.{ .target = "\"display\"" }, "{\"kind\":\"display\",\"index\":0}", null);
    try expectCapture(
        .{ .target = "\"display\"", .display = "2" },
        "{\"kind\":\"display\",\"index\":2}",
        null,
    );
    try expectCapture(
        .{ .target = "\"window\"", .window_id = "4242" },
        "{\"kind\":\"window\",\"window_id\":4242}",
        null,
    );
    try expectCapture(
        .{ .target = "\"region\"", .display = "1", .rect = "[10, 20, 300, 400]" },
        "{\"kind\":\"region\",\"display\":1,\"rect\":[10,20,300,400]}",
        null,
    );

    // A terminal is the action's target, not a field: the caller's own when
    // none is named.
    try expectCapture(.{ .target = "\"terminal\"" }, "{\"kind\":\"terminal\"}", 0x2a);
    try expectCapture(
        .{ .target = "\"terminal\"", .terminal = "\"0x0000000000000007\"" },
        "{\"kind\":\"terminal\"}",
        7,
    );
}

test "screenshot: a capture that does not say what it means is refused" {
    try expectCaptureRefused(.{}, "`target` must be");
    try expectCaptureRefused(.{ .target = "\"screen\"" }, "not \"screen\"");
    try expectCaptureRefused(.{ .target = "3" }, "`target` must be");

    try expectCaptureRefused(.{ .target = "\"window\"" }, "needs `window_id`");
    try expectCaptureRefused(.{ .target = "\"window\"", .window_id = "\"12\"" }, "needs `window_id`");
    try expectCaptureRefused(.{ .target = "\"window\"", .window_id = "-1" }, "not negative");
    try expectCaptureRefused(.{ .target = "\"region\"" }, "needs `rect`");
    try expectCaptureRefused(.{ .target = "\"region\"", .rect = "[1,2,0,4]" }, "needs `rect`");
    try expectCaptureRefused(.{ .target = "\"display\"", .display = "-1" }, "`display` is an index");
    try expectCaptureRefused(.{ .target = "\"terminal\"", .terminal = "\"nope\"" }, "must be a terminal id");

    // A parameter that belongs to another target is a different call.
    try expectCaptureRefused(
        .{ .target = "\"display\"", .window_id = "1" },
        "takes `display` and nothing else",
    );
    try expectCaptureRefused(
        .{ .target = "\"window\"", .window_id = "1", .rect = "[1,2,3,4]" },
        "takes `window_id` and nothing else",
    );
    try expectCaptureRefused(
        .{ .target = "\"terminal\"", .display = "0" },
        "takes `terminal` and nothing else",
    );

    // Bad annotations stop the capture before a host is asked.
    try expectCaptureRefused(
        .{ .target = "\"display\"", .annotations = "[{\"type\":\"rect\",\"rect\":[1,2,3,4],\"width\":3}]" },
        "annotations[0].width",
    );
}

test "screenshot: the annotations travel in the request, normalised" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = prepareCapture(arena.allocator(), .{
        .target = "\"display\"",
        .annotations = "[{\"type\":\"mosaic\",\"rect\":[1,2,3,4]}]",
    }, .{ .by = 1 }).request;
    try testing.expectEqualStrings(
        "{\"op\":\"capture\",\"target\":{\"kind\":\"display\",\"index\":0}," ++
            "\"annotations\":[{\"type\":\"mosaic\",\"rect\":[1,2,3,4],\"block\":12}]," ++
            "\"meta\":{\"by\":\"agent\",\"agent_terminal\":\"0x0000000000000001\"," ++
            "\"terminal\":{\"id\":\"0x0000000000000001\"}}}",
        r.spec,
    );
}

test "screenshot: annotate takes one of our images and something to draw" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const dir = "/s";
    const rect = "[{\"type\":\"rect\",\"rect\":[1,2,3,4]}]";

    const ok = prepareAnnotate(alloc, .{
        .path = "\"/s/20261006-153012-123.png\"",
        .annotations = rect,
    }, .{ .by = 1 }, dir).request;
    try testing.expect(ok.op == .annotate);
    try testing.expect(std.mem.startsWith(
        u8,
        ok.spec,
        "{\"op\":\"annotate\",\"path\":\"/s/20261006-153012-123.png\",\"annotations\":[{\"type\":\"rect\"",
    ));

    const outside = prepareAnnotate(alloc, .{ .path = "\"/etc/passwd\"", .annotations = rect }, .{ .by = 1 }, dir);
    try testing.expectEqualStrings("BadPath", codeOf(outside));

    // The sidecar is one of ours, and is not an image.
    const sidecar = prepareAnnotate(alloc, .{
        .path = "\"/s/20261006-153012-123.json\"",
        .annotations = rect,
    }, .{ .by = 1 }, dir);
    try testing.expectEqualStrings("BadPath", codeOf(sidecar));

    const nothing = prepareAnnotate(alloc, .{ .path = "\"/s/20261006-153012-123.png\"" }, .{ .by = 1 }, dir);
    try testing.expectEqualStrings("BadAnnotations", codeOf(nothing));

    const no_path = prepareAnnotate(alloc, .{ .annotations = rect }, .{ .by = 1 }, dir);
    try testing.expectEqualStrings("BadParams", codeOf(no_path));
}

test "screenshot: a long screenshot names a window or a region, and how far" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const window = prepareLong(alloc, .{ .window_id = "9", .pages = "4" }, .{ .by = 1 }).request;
    try testing.expect(std.mem.startsWith(
        u8,
        window.spec,
        "{\"op\":\"long\",\"target\":{\"kind\":\"window\",\"window_id\":9},\"pages\":4,\"meta\":",
    ));
    // Ten seconds, and three for each screen.
    try testing.expectEqual(@as(u64, 22_000), window.timeout_ms);

    const region = prepareLong(alloc, .{ .rect = "[0,0,800,600]", .pages = "1" }, .{ .by = 1 }).request;
    try testing.expect(std.mem.startsWith(
        u8,
        region.spec,
        "{\"op\":\"long\",\"target\":{\"kind\":\"region\",\"display\":0,\"rect\":[0,0,800,600]},\"pages\":1,",
    ));

    for ([_]LongArgs{
        .{ .window_id = "9" },
        .{ .window_id = "9", .pages = "0" },
        .{ .window_id = "9", .pages = "21" },
        .{ .window_id = "9", .pages = "\"3\"" },
        .{ .pages = "3" },
        .{ .window_id = "9", .rect = "[0,0,8,6]", .pages = "3" },
        .{ .window_id = "9", .display = "1", .pages = "3" },
        .{ .rect = "[0,0,0,6]", .pages = "3" },
    }) |args| {
        const refused = prepareLong(alloc, args, .{ .by = 1 });
        try testing.expect(refused == .failed);
        try testing.expectEqualStrings("BadParams", codeOf(refused));
    }
}

test "screenshot: a host's refusal is passed on, and one that cannot be read is the host's fault" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const said = refusal(alloc, "{\"code\":\"NoSuchWindow\",\"message\":\"window 9 has closed\"}");
    try testing.expectEqualStrings("NoSuchWindow", said.code);
    try testing.expectEqualStrings("window 9 has closed", said.message);

    // A code with no sentence still says something.
    const bare = refusal(alloc, "{\"code\":\"Busy\"}");
    try testing.expectEqualStrings("Busy", bare.code);
    try testing.expectEqualStrings("Busy", bare.message);

    for ([_][]const u8{ "", "not json", "[]", "{}", "{\"code\":7}", "{\"code\":\"\"}" }) |json| {
        const fault = refusal(alloc, json);
        try testing.expectEqualStrings("HostFault", fault.code);
    }
}

test "screenshot: the directory is whatever the host says it is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const dir = directoryOf(alloc, "{\"directory\":\"/state/polter/shots\"}");
    try testing.expectEqualStrings("/state/polter/shots", dir.?);

    for ([_][]const u8{ "", "{}", "{\"directory\":\"\"}", "{\"directory\":3}", "[]" }) |json| {
        const none = directoryOf(alloc, json);
        try testing.expect(none == null);
    }
}

test "screenshot: a host's paths go through the gate an agent's do" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const dir = "/s";

    const good = "{\"path\":\"/s/20261006-153012-123.png\",\"json\":\"/s/20261006-153012-123.json\",\"size\":[10,20]}";
    const passed = finish(alloc, .capture, dir, good);
    try testing.expectEqualStrings(good, jsonOf(passed));

    // Written somewhere else: a host bug, and not a path to hand on.
    const elsewhere = finish(
        alloc,
        .capture,
        dir,
        "{\"path\":\"/tmp/20261006-153012-123.png\",\"json\":\"/s/20261006-153012-123.json\"}",
    );
    try testing.expectEqualStrings("HostFault", codeOf(elsewhere));

    const sidecar_elsewhere = finish(
        alloc,
        .annotate,
        dir,
        "{\"path\":\"/s/20261006-153012-123.png\",\"json\":\"/etc/passwd\"}",
    );
    try testing.expectEqualStrings("HostFault", codeOf(sidecar_elsewhere));

    for ([_][]const u8{ "", "nope", "[]", "{}", "{\"path\":3,\"json\":\"/s/20261006-153012-123.json\"}" }) |json| {
        const unreadable = finish(alloc, .capture, dir, json);
        try testing.expectEqualStrings("HostFault", codeOf(unreadable));
    }

    // A long screenshot lists its tiles, by file name.
    const long_good = "{\"path\":\"/s/20261006-153012-123.png\",\"json\":\"/s/20261006-153012-123.json\"," ++
        "\"tiles\":[{\"image\":\"20261006-153012-123-1.png\",\"y\":0,\"height\":1800}]}";
    const long_passed = finish(alloc, .long, dir, long_good);
    try testing.expectEqualStrings(long_good, jsonOf(long_passed));

    const tile_path = finish(alloc, .long, dir, "{\"path\":\"/s/20261006-153012-123.png\"," ++
        "\"json\":\"/s/20261006-153012-123.json\",\"tiles\":[{\"image\":\"/tmp/20261006-153012-123-1.png\"}]}");
    try testing.expectEqualStrings("HostFault", codeOf(tile_path));

    const tile_not_tile = finish(alloc, .long, dir, "{\"path\":\"/s/20261006-153012-123.png\"," ++
        "\"json\":\"/s/20261006-153012-123.json\",\"tiles\":[{\"image\":\"20261006-153012-123.png\"}]}");
    try testing.expectEqualStrings("HostFault", codeOf(tile_not_tile));

    const long_without_tiles = finish(alloc, .long, dir, good);
    try testing.expectEqualStrings("HostFault", codeOf(long_without_tiles));

    // The window list is the host's document; it only has to be JSON.
    const windows = finish(alloc, .windows, dir, "{\"displays\":[],\"windows\":[]}");
    try testing.expect(windows == .json);
    const windows_bad = finish(alloc, .windows, dir, "{\"displays\":[");
    try testing.expectEqualStrings("HostFault", codeOf(windows_bad));
}

test "screenshot: how long a host is waited for" {
    try testing.expectEqual(@as(u64, 15_000), timeoutMs(.capture, 0));
    try testing.expectEqual(@as(u64, 15_000), timeoutMs(.annotate, 0));
    try testing.expectEqual(@as(u64, 13_000), timeoutMs(.long, 1));
    try testing.expectEqual(@as(u64, 70_000), timeoutMs(.long, 20));
}

test "screenshot: a PNG's size is read from its header" {
    const head = "\x89PNG\r\n\x1a\n" ++ "\x00\x00\x00\x0dIHDR" ++ "\x00\x00\x05\x00" ++ "\x00\x00\x03\x20";
    const size = pngSize(head).?;
    try testing.expectEqual(@as(u32, 1280), size[0]);
    try testing.expectEqual(@as(u32, 800), size[1]);

    const not_png = pngSize("GIF89a" ++ "\x00" ** 30);
    try testing.expect(not_png == null);
    const short = pngSize("\x89PNG\r\n\x1a\n");
    try testing.expect(short == null);
}

test "screenshot: the time in a name is written as a time" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        "2026-10-06T15:30:12.123",
        timeOfStem(arena.allocator(), "20261006-153012-123"),
    );
}

/// A directory of our own under the system's temporary one.
fn tmpShots(alloc: Allocator, io: std.Io) ![]const u8 {
    var seed: [6]u8 = undefined;
    io.random(&seed);
    const path = try std.fmt.allocPrint(alloc, "/tmp/polter-shots-{x}", .{&seed});
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}

fn put(io: std.Io, dir: []const u8, name: []const u8, bytes: []const u8) !void {
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    try d.writeFile(io, .{ .sub_path = name, .data = bytes });
}

test "screenshot: list gives the newest first, with what their sidecars say" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpShots(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const png = "\x89PNG\r\n\x1a\n" ++ "\x00\x00\x00\x0dIHDR" ++ "\x00\x00\x00\x40" ++ "\x00\x00\x00\x20" ++ "rest";

    // The oldest: a pasted image, no sidecar.
    try put(io, dir, "20261001-090000-000.png", png);
    // A screenshot with a sidecar.
    try put(io, dir, "20261005-120000-000.png", png);
    try put(io, dir, "20261005-120000-000.json",
        \\{"version":2,"by":"user","size":[1280,800],"source":{"kind":"window","app":"Finder"},
        \\ "annotations":[{"type":"rect"},{"type":"text"}]}
    );
    // The newest: a long one, with tiles that must not be listed themselves.
    try put(io, dir, "20261006-153012-123.png", png);
    try put(io, dir, "20261006-153012-123-1.png", png);
    try put(io, dir, "20261006-153012-123-2.png", png);
    try put(io, dir, "20261006-153012-123.json",
        \\{"version":2,"by":"agent","size":[800,3000],"source":{"kind":"region"},"annotations":[],
        \\ "tiles":[{"image":"20261006-153012-123-1.png"},{"image":"20261006-153012-123-2.png"}]}
    );
    // Not ours: never listed.
    try put(io, dir, "holiday.png", png);
    try put(io, dir, "notes.json", "{}");

    const all = jsonOf(list(io, alloc, dir, .{}));
    const parsed = try std.json.parseFromSliceLeaky(Value, alloc, all, .{});
    try testing.expectEqualStrings(dir, parsed.object.get("directory").?.string);
    const shots = parsed.object.get("screenshots").?.array.items;
    try testing.expectEqual(@as(usize, 3), shots.len);

    const newest_one = shots[0].object;
    const newest_path = try std.fmt.allocPrint(alloc, "{s}/20261006-153012-123.png", .{dir});
    try testing.expectEqualStrings(newest_path, newest_one.get("path").?.string);
    try testing.expectEqualStrings("2026-10-06T15:30:12.123", newest_one.get("time").?.string);
    try testing.expectEqualStrings("agent", newest_one.get("by").?.string);
    try testing.expectEqual(@as(i64, 0), newest_one.get("annotations").?.integer);
    try testing.expectEqual(@as(i64, 2), newest_one.get("tiles").?.integer);
    try testing.expectEqual(@as(i64, 3000), newest_one.get("size").?.array.items[1].integer);

    const middle = shots[1].object;
    try testing.expectEqual(@as(i64, 2), middle.get("annotations").?.integer);
    try testing.expectEqualStrings("Finder", middle.get("source").?.object.get("app").?.string);
    try testing.expect(middle.get("tiles") == null);

    // No sidecar: the size comes from the image itself, and nothing else is claimed.
    const pasted = shots[2].object;
    try testing.expectEqual(@as(i64, 64), pasted.get("size").?.array.items[0].integer);
    try testing.expectEqual(@as(i64, 32), pasted.get("size").?.array.items[1].integer);
    try testing.expect(pasted.get("by") == null);
    try testing.expect(pasted.get("annotations") == null);

    // The limit takes from the newest end.
    const one = jsonOf(list(io, alloc, dir, .{ .limit = "1" }));
    const one_parsed = try std.json.parseFromSliceLeaky(Value, alloc, one, .{});
    const one_shots = one_parsed.object.get("screenshots").?.array.items;
    try testing.expectEqual(@as(usize, 1), one_shots.len);
    try testing.expectEqualStrings(newest_path, one_shots[0].object.get("path").?.string);

    for ([_][]const u8{ "0", "51", "\"3\"", "-1" }) |limit| {
        const refused = list(io, alloc, dir, .{ .limit = limit });
        try testing.expectEqualStrings("BadParams", codeOf(refused));
    }
}

test "screenshot: list of a directory that is not there is an empty list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const answer = list(threaded.io(), arena.allocator(), "/nonexistent/polter/shots", .{});
    try testing.expectEqualStrings(
        "{\"directory\":\"/nonexistent/polter/shots\",\"screenshots\":[]}",
        jsonOf(answer),
    );
}

test "screenshot: info reads the sidecar of a path, or of the latest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpShots(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const nothing = info(io, alloc, dir, .{ .latest = "true" });
    try testing.expectEqualStrings("NotFound", codeOf(nothing));

    const old = "{\"version\":2,\"image\":\"20261005-120000-000.png\"}";
    const new = "{\"version\":2,\"image\":\"20261006-153012-123.png\"}";
    try put(io, dir, "20261005-120000-000.png", "x");
    try put(io, dir, "20261005-120000-000.json", old);
    try put(io, dir, "20261006-153012-123.png", "x");
    try put(io, dir, "20261006-153012-123.json", new);
    try put(io, dir, "20261007-000000-000.png", "x"); // pasted, no sidecar
    try put(io, dir, "secret.json", "{\"secret\":true}");

    const by_path = info(io, alloc, dir, .{
        .path = try std.fmt.allocPrint(alloc, "\"{s}/20261005-120000-000.png\"", .{dir}),
    });
    try testing.expectEqualStrings(old, jsonOf(by_path));

    // The sidecar's own path names the same screenshot.
    const by_sidecar = info(io, alloc, dir, .{
        .path = try std.fmt.allocPrint(alloc, "\"{s}/20261006-153012-123.json\"", .{dir}),
    });
    try testing.expectEqualStrings(new, jsonOf(by_sidecar));

    // The latest image has no sidecar, and that is said rather than
    // answered with the one before it.
    const latest = info(io, alloc, dir, .{ .latest = "true" });
    try testing.expectEqualStrings("NotFound", codeOf(latest));

    // **The point of the gate.** A file in the directory that is not ours,
    // and a file that is not in the directory.
    const not_ours = info(io, alloc, dir, .{
        .path = try std.fmt.allocPrint(alloc, "\"{s}/secret.json\"", .{dir}),
    });
    try testing.expectEqualStrings("BadPath", codeOf(not_ours));
    const outside = info(io, alloc, dir, .{ .path = "\"/etc/passwd\"" });
    try testing.expectEqualStrings("BadPath", codeOf(outside));
    const climbing = info(io, alloc, dir, .{
        .path = try std.fmt.allocPrint(alloc, "\"{s}/../secret.json\"", .{dir}),
    });
    try testing.expectEqualStrings("BadPath", codeOf(climbing));

    const both = info(io, alloc, dir, .{ .path = "\"x\"", .latest = "true" });
    try testing.expectEqualStrings("BadParams", codeOf(both));
    const neither = info(io, alloc, dir, .{});
    try testing.expectEqualStrings("BadParams", codeOf(neither));
}

test "screenshot: a link named like a screenshot is not followed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpShots(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // Something outside the directory, and a link to it wearing one of our
    // names.
    try put(io, dir, "outside.txt", "{\"secret\":true}");
    try put(io, dir, "20261006-153012-123.png", "x");
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    try d.symLink(io, "outside.txt", "20261006-153012-123.json", .{});

    const answer = info(io, alloc, dir, .{
        .path = try std.fmt.allocPrint(alloc, "\"{s}/20261006-153012-123.png\"", .{dir}),
    });
    try testing.expectEqualStrings("NotFound", codeOf(answer));
}

test "screenshot: a parked request is answered once, by its token or by its deadline" {
    const W = Waits(u32);
    var waits: W = .{};
    defer waits.deinit(testing.allocator);

    const first = waits.issue();
    const second = waits.issue();
    try testing.expect(first != 0);
    try testing.expect(first != second);

    try waits.park(testing.allocator, .{ .token = first, .held = 11, .op = .capture, .directory = "/s", .deadline_ms = 1000 });
    try waits.park(testing.allocator, .{ .token = second, .held = 22, .op = .long, .directory = "/s", .deadline_ms = 5000 });

    // A token nobody holds is nobody's.
    const unknown = waits.take(999);
    try testing.expect(unknown == null);

    const taken = waits.take(second).?;
    try testing.expectEqual(@as(u32, 22), taken.held);
    // And it is gone: a host that calls back twice finds nothing.
    const again = waits.take(second);
    try testing.expect(again == null);

    // Not yet due.
    const early = waits.takeExpired(999);
    try testing.expect(early == null);
    const due = waits.takeExpired(1000).?;
    try testing.expectEqual(@as(u32, 11), due.held);
    const none_left = waits.takeExpired(100_000);
    try testing.expect(none_left == null);
}
