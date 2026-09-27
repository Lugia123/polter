//! What an agent CLI says about itself, in words that belong to no CLI.
//!
//! Each CLI's hooks have their own names and their own payloads. `polter
//! +hook --cli <name> <event>` reads one of those payloads and turns it into
//! an `Event` here; everything past that point -- the RPC, the bus, the
//! notices -- knows only this vocabulary. See
//! `dev-docs/poltergeist/adapters.md`, sections 3.3 and 3.4.
//!
//! Pure: bytes in, values out. The translation tables are the part that
//! has to follow somebody else's interface, so they are the part that is
//! tested against payloads of the shape that interface documents.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    /// Not a hook: `+launch` saying it has just configured hooks into the
    /// CLI it is about to start, so silence from here on means something.
    /// See `Bus.Hooks`.
    hooks_expected,
    session_started,
    turn_started,
    turn_ended,
    turn_failed,
    awaiting_approval,
    awaiting_input,
};

/// The most of a final answer that is carried. `terminal_turn` hands out
/// no more than this, and the request that carries it has to fit under
/// `Server.max_request_bytes` even after JSON escaping has doubled it.
pub const max_text_bytes = 16 * 1024;

/// How much of a command goes into an approval's one-line summary.
pub const summary_chars = 120;

/// One thing an agent CLI said about itself.
///
/// **No defaults, on purpose.** Every translation has to say what it put in
/// every field, so a table row that forgot one is a compile error naming
/// it rather than a field that silently reads as absent. The field names
/// are the RPC's parameter names (`wire.rejectUnknownParams` reads them).
pub const Event = struct {
    event: Kind,

    /// Which CLI said it: the `--cli` given to `+hook`.
    cli: []const u8,

    session_id: ?[]const u8,

    /// The short word for what happened: the session's `source`, the
    /// error type, the tool name, the notification type.
    detail: ?[]const u8,

    /// One line to go with `detail`: an approval's command, a failure's
    /// details.
    note: ?[]const u8,

    /// A finished turn's final answer, at most `max_text_bytes`.
    text: ?[]const u8,

    /// How long `text` was before it was cut; equal to its length when it
    /// was not. Zero with no text.
    text_bytes: u64,

    /// The turn ended with background work still running, so a still
    /// screen is waiting, not finished.
    waiting_on_background: bool,

    pub const none: Event = .{
        .event = .hooks_expected,
        .cli = "",
        .session_id = null,
        .detail = null,
        .note = null,
        .text = null,
        .text_bytes = 0,
        .waiting_on_background = false,
    };
};

pub const Error = error{
    /// The payload is not a JSON object.
    NotJson,

    /// No table for that `--cli`.
    UnknownCli,

    /// That CLI has no event by this name, or none this table takes.
    UnknownEvent,

    /// A field the table needs is missing or the wrong shape. The event is
    /// dropped: guessing at it would report something the CLI never said.
    MissingField,

    /// A known event this table deliberately does not pass on -- a
    /// `Notification` that is not about waiting for the person.
    Ignored,
} || Allocator.Error;

/// Translate one hook payload. Strings in the result are allocated from
/// `arena`.
pub fn translate(
    arena: Allocator,
    cli: []const u8,
    hook: []const u8,
    payload: []const u8,
) Error!Event {
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        payload,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJson,
    };
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.NotJson,
    };

    if (std.mem.eql(u8, cli, "claude-code")) return claudeCode(arena, hook, obj);
    return error.UnknownCli;
}

/// Claude Code, 2.1.145 and later (adapters.md 3.1). Field names are the
/// ones its hooks documentation gives.
fn claudeCode(arena: Allocator, hook: []const u8, obj: std.json.ObjectMap) Error!Event {
    // A payload for a different hook than the one we were started for is
    // a configuration mistake, and translating it by the name on our
    // command line would report the wrong thing.
    if (obj.get("hook_event_name")) |v| switch (v) {
        .string => |s| if (!std.mem.eql(u8, s, hook)) return error.UnknownEvent,
        else => return error.MissingField,
    };

    var ev: Event = .none;
    ev.cli = "claude-code";
    ev.session_id = try requireString(obj, "session_id");

    if (std.mem.eql(u8, hook, "SessionStart")) {
        ev.event = .session_started;
        ev.detail = try optionalString(obj, "source");
    } else if (std.mem.eql(u8, hook, "UserPromptSubmit")) {
        // The prompt is not taken: what the worker was told is the
        // supervisor's to know already, and it is not this signal's job.
        ev.event = .turn_started;
    } else if (std.mem.eql(u8, hook, "Stop")) {
        ev.event = .turn_ended;
        if (try optionalString(obj, "last_assistant_message")) |text| {
            const kept = cutBytes(text, max_text_bytes);
            ev.text = kept;
            ev.text_bytes = text.len;
        }
        ev.waiting_on_background = switch (obj.get("background_tasks") orelse .null) {
            .null => false,
            .array => |a| a.items.len > 0,
            else => return error.MissingField,
        };
    } else if (std.mem.eql(u8, hook, "StopFailure")) {
        ev.event = .turn_failed;
        ev.detail = try requireString(obj, "error");
        ev.note = try oneLine(arena, try optionalString(obj, "error_details"));
    } else if (std.mem.eql(u8, hook, "PermissionRequest")) {
        ev.event = .awaiting_approval;
        const tool = try requireString(obj, "tool_name");
        ev.detail = tool;
        ev.note = try oneLine(arena, try approvalSummary(obj, tool));
    } else if (std.mem.eql(u8, hook, "Notification")) {
        const kind = try requireString(obj, "notification_type");
        if (!std.mem.eql(u8, kind, "idle_prompt") and
            !std.mem.eql(u8, kind, "elicitation_dialog")) return error.Ignored;
        ev.event = .awaiting_input;
        ev.detail = kind;
    } else return error.UnknownEvent;

    return ev;
}

/// The one line that says what an approval is for. Bash's command is the
/// case that matters; other tools say which file when they have one.
fn approvalSummary(obj: std.json.ObjectMap, tool: []const u8) Error!?[]const u8 {
    const input = switch (obj.get("tool_input") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const key = if (std.mem.eql(u8, tool, "Bash")) "command" else "file_path";
    const s = (try optionalString(input, key)) orelse return null;
    return prefixChars(s, summary_chars);
}

fn requireString(obj: std.json.ObjectMap, key: []const u8) Error![]const u8 {
    return (try optionalString(obj, key)) orelse error.MissingField;
}

fn optionalString(obj: std.json.ObjectMap, key: []const u8) Error!?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        .null => null,
        else => error.MissingField,
    };
}

/// Control characters as spaces. What goes into `note` ends up in a line
/// that is typed into a supervisor's terminal, where a newline submits.
fn oneLine(arena: Allocator, s: ?[]const u8) Allocator.Error!?[]const u8 {
    const src = s orelse return null;
    const out = try arena.dupe(u8, src);
    for (out) |*c| if (c.* < 0x20 or c.* == 0x7f) {
        c.* = ' ';
    };
    return out;
}

/// The longest prefix of `s` that is at most `max` bytes and does not end
/// inside a UTF-8 sequence.
pub fn cutBytes(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    // Back off continuation bytes, then the lead byte they belong to if
    // its sequence would run past `max`.
    while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
    return s[0..end];
}

/// The first `n` characters of `s`, counted as UTF-8 code points. Bytes
/// that are not valid UTF-8 count one each rather than stopping the count.
pub fn prefixChars(s: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var count: usize = 0;
    while (i < s.len and count < n) : (count += 1) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i = @min(s.len, i + len);
    }
    return s[0..i];
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn tr(hook: []const u8, payload: []const u8) Error!Event {
    // Leaks into the testing allocator's arena on purpose: each test frees
    // the arena it made.
    return translate(test_arena.allocator(), "claude-code", hook, payload);
}

var test_arena: std.heap.ArenaAllocator = undefined;

fn setup() void {
    test_arena = .init(testing.allocator);
}

fn teardown() void {
    test_arena.deinit();
}

// Payloads below have the shape Claude Code's hooks documentation gives
// for each event (common fields first), not a minimal one: a table that
// only ever saw `{"session_id":"s"}` would not notice a field it ignored
// turning into one it tripped on.

test "claude-code SessionStart is session_started with its source" {
    setup();
    defer teardown();
    const ev = try tr("SessionStart",
        \\{"session_id":"abc123","transcript_path":"/x/abc123.jsonl","cwd":"/w",
        \\ "hook_event_name":"SessionStart","source":"resume","model":"claude-opus-5-5"}
    );
    try testing.expectEqual(Kind.session_started, ev.event);
    try testing.expectEqualStrings("abc123", ev.session_id.?);
    try testing.expectEqualStrings("resume", ev.detail.?);
    try testing.expectEqualStrings("claude-code", ev.cli);
}

test "claude-code UserPromptSubmit is turn_started and does not take the prompt" {
    setup();
    defer teardown();
    const ev = try tr("UserPromptSubmit",
        \\{"session_id":"abc123","transcript_path":"/x","cwd":"/w","permission_mode":"default",
        \\ "hook_event_name":"UserPromptSubmit","prompt":"fix #845 please"}
    );
    try testing.expectEqual(Kind.turn_started, ev.event);
    try testing.expect(ev.text == null);
    try testing.expect(ev.detail == null);
    try testing.expect(ev.note == null);
}

test "claude-code Stop is turn_ended carrying the answer and the background flag" {
    setup();
    defer teardown();
    const ev = try tr("Stop",
        \\{"session_id":"abc123","transcript_path":"/x","cwd":"/w","permission_mode":"auto",
        \\ "hook_event_name":"Stop","stop_hook_active":false,
        \\ "last_assistant_message":"已修好 #845，全量 104/104",
        \\ "background_tasks":[{"id":"b1","command":"zig build test"}],"session_crons":[]}
    );
    try testing.expectEqual(Kind.turn_ended, ev.event);
    try testing.expectEqualStrings("已修好 #845，全量 104/104", ev.text.?);
    try testing.expectEqual(@as(u64, ev.text.?.len), ev.text_bytes);
    try testing.expect(ev.waiting_on_background);
}

test "claude-code Stop with no background work is not waiting on any" {
    setup();
    defer teardown();
    const empty = try tr("Stop",
        \\{"session_id":"s","hook_event_name":"Stop","last_assistant_message":"done","background_tasks":[]}
    );
    try testing.expect(!empty.waiting_on_background);
    const absent = try tr("Stop",
        \\{"session_id":"s","hook_event_name":"Stop","last_assistant_message":"done"}
    );
    try testing.expect(!absent.waiting_on_background);
}

test "claude-code Stop cuts a long answer on a character boundary and says how long it was" {
    setup();
    defer teardown();
    const a = test_arena.allocator();
    // Three-byte characters, so a cut at exactly `max_text_bytes` would
    // land inside one unless it backs off.
    var body: std.ArrayListUnmanaged(u8) = .empty;
    try body.appendSlice(a, "{\"session_id\":\"s\",\"last_assistant_message\":\"x");
    for (0..max_text_bytes) |_| try body.appendSlice(a, "中");
    try body.appendSlice(a, "\"}");

    const ev = try tr("Stop", body.items);
    try testing.expect(ev.text.?.len <= max_text_bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(ev.text.?));
    try testing.expectEqual(@as(u64, 1 + 3 * max_text_bytes), ev.text_bytes);
}

test "claude-code StopFailure is turn_failed with the error type" {
    setup();
    defer teardown();
    const ev = try tr("StopFailure",
        \\{"session_id":"s","transcript_path":"/x","cwd":"/w","hook_event_name":"StopFailure",
        \\ "error":"rate_limit","error_details":"429 Too Many Requests\nretry after 30s"}
    );
    try testing.expectEqual(Kind.turn_failed, ev.event);
    try testing.expectEqualStrings("rate_limit", ev.detail.?);
    // One line: the newline would submit the notice it ends up in.
    try testing.expectEqualStrings("429 Too Many Requests retry after 30s", ev.note.?);
}

test "claude-code PermissionRequest names the tool and the first 120 characters of a command" {
    setup();
    defer teardown();
    const a = test_arena.allocator();
    var body: std.ArrayListUnmanaged(u8) = .empty;
    try body.appendSlice(a,
        \\{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash",
        \\ "tool_input":{"command":"
    );
    for (0..200) |_| try body.appendSlice(a, "é");
    try body.appendSlice(a, "\",\"description\":\"d\"},\"permission_suggestions\":[]}");

    const ev = try tr("PermissionRequest", body.items);
    try testing.expectEqual(Kind.awaiting_approval, ev.event);
    try testing.expectEqualStrings("Bash", ev.detail.?);
    try testing.expectEqual(@as(usize, 240), ev.note.?.len);
}

test "claude-code PermissionRequest for a file tool names the file" {
    setup();
    defer teardown();
    const ev = try tr("PermissionRequest",
        \\{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Edit",
        \\ "tool_input":{"file_path":"/w/src/App.zig","old_string":"a","new_string":"b"}}
    );
    try testing.expectEqualStrings("Edit", ev.detail.?);
    try testing.expectEqualStrings("/w/src/App.zig", ev.note.?);
}

test "claude-code Notification is awaiting_input only for the two waiting kinds" {
    setup();
    defer teardown();
    const idle = try tr("Notification",
        \\{"session_id":"s","hook_event_name":"Notification","message":"Claude is waiting for your input",
        \\ "notification_type":"idle_prompt"}
    );
    try testing.expectEqual(Kind.awaiting_input, idle.event);
    try testing.expectEqualStrings("idle_prompt", idle.detail.?);

    const dialog = try tr("Notification",
        \\{"session_id":"s","hook_event_name":"Notification","message":"m","notification_type":"elicitation_dialog"}
    );
    try testing.expectEqual(Kind.awaiting_input, dialog.event);

    try testing.expectError(error.Ignored, tr("Notification",
        \\{"session_id":"s","hook_event_name":"Notification","message":"m","notification_type":"auth_success"}
    ));
}

test "a payload missing a field the table needs is refused, not guessed at" {
    setup();
    defer teardown();
    // No session_id: every event needs one.
    try testing.expectError(error.MissingField, tr("SessionStart",
        \\{"hook_event_name":"SessionStart","source":"startup"}
    ));
    // StopFailure without its error type.
    try testing.expectError(error.MissingField, tr("StopFailure",
        \\{"session_id":"s","hook_event_name":"StopFailure","error_details":"x"}
    ));
    // PermissionRequest without the tool.
    try testing.expectError(error.MissingField, tr("PermissionRequest",
        \\{"session_id":"s","hook_event_name":"PermissionRequest","tool_input":{}}
    ));
    // A field of the wrong shape counts as missing.
    try testing.expectError(error.MissingField, tr("Stop",
        \\{"session_id":"s","hook_event_name":"Stop","background_tasks":"yes"}
    ));
}

test "not JSON, an unknown hook, a mismatched hook name and an unknown CLI are all refused" {
    setup();
    defer teardown();
    try testing.expectError(error.NotJson, tr("Stop", "not json"));
    try testing.expectError(error.NotJson, tr("Stop", "[1,2]"));
    try testing.expectError(error.UnknownEvent, tr("PreToolUse",
        \\{"session_id":"s","hook_event_name":"PreToolUse"}
    ));
    try testing.expectError(error.UnknownEvent, tr("Stop",
        \\{"session_id":"s","hook_event_name":"SessionStart"}
    ));
    try testing.expectError(error.UnknownCli, translate(
        test_arena.allocator(),
        "codex",
        "Stop",
        "{}",
    ));
}

test "prefixChars counts characters, not bytes" {
    try testing.expectEqualStrings("ab", prefixChars("abc", 2));
    try testing.expectEqualStrings("中文", prefixChars("中文字", 2));
    try testing.expectEqualStrings("", prefixChars("", 5));
}

test "cutBytes never ends inside a character" {
    try testing.expectEqualStrings("中", cutBytes("中文", 4));
    try testing.expectEqualStrings("中文", cutBytes("中文", 6));
    try testing.expectEqualStrings("", cutBytes("中", 2));
}
