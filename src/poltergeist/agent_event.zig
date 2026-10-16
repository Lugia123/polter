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
    /// Not a hook either: `+launch` saying the CLI it was to start did not
    /// start, so nothing it said before stands -- no hooks are coming, and
    /// no agent will connect from this terminal on this launch's account.
    /// `detail` is which kind of failure (`LaunchFailure`).
    launch_failed,
    session_started,
    turn_started,
    turn_ended,
    turn_failed,
    awaiting_approval,
    awaiting_input,
    /// A tool call finished: the agent is working, whatever it was waiting
    /// on before. Claude Code's `PostToolUse`, which fires after every
    /// tool call -- and so is the one hook that says a turn went on after
    /// an approval or an answer; the next one otherwise is that turn's
    /// `Stop` (task 1561). **Not `turn_started`**: that one says a turn
    /// began, from any state, and drops what was waiting about the last
    /// one; this one is said a hundred times inside one turn and moves
    /// only a terminal that was waiting (`Bus.agentEvent`).
    turn_resumed,
    /// A tool call is starting: Claude Code's `PreToolUse` (task 1625).
    /// Paired with the `turn_resumed` its `PostToolUse` or
    /// `PostToolUseFailure` says when it ends, so the bus can tell a turn
    /// that is running a long command from a turn with nothing running in
    /// it -- the two read the same on the `no tool call` clock (#62).
    /// Moves nothing else: not the state, not the clocks, not the box.
    tool_started,
    /// Not a hook either: `polter +statusline` saying it has just written
    /// the allowance it was handed (`QuotaWatch`). It says nothing about
    /// what the agent is doing and changes nothing the bus keeps -- it is
    /// here because it comes from the same place by the same road, and a
    /// request of its own would be that road built twice.
    allowance_written,
};

/// The `detail` of a `hooks_expected` whose CLI says nothing until its first
/// turn (`agent_cli.HooksHeard.first_turn`), or null for one that speaks
/// when it starts.
pub fn hooksExpectedDetail(at_first_turn: bool) ?[]const u8 {
    return if (at_first_turn) first_turn else null;
}

/// Whether a `hooks_expected` said its CLI's first hook comes with its
/// first turn. Any other word, or none, is the wait from the launch.
pub fn heardAtFirstTurn(detail: ?[]const u8) bool {
    const d = detail orelse return false;
    return std.mem.eql(u8, d, first_turn);
}

const first_turn = "first_turn";

/// Why a launch started no CLI, as `+launch` says it in `detail`.
pub const LaunchFailure = enum {
    /// The CLI's program is not there to run: not installed, or not on the
    /// path this terminal has.
    not_found,
    /// Anything else that stopped it before the CLI ran: no adapter for
    /// it, the adapter gave no command, the role is not there, the program
    /// is there and could not be run.
    failed,

    /// What `detail` says; `failed` for a word this build does not know,
    /// so that a newer `+launch` is still heard as a failure.
    pub fn parse(detail: ?[]const u8) LaunchFailure {
        const d = detail orelse return .failed;
        return std.meta.stringToEnum(LaunchFailure, d) orelse .failed;
    }
};

/// The most of a final answer that is carried. `terminal_turn` hands out
/// no more than this, and the request that carries it has to fit under
/// `Server.max_request_bytes` even after JSON escaping has doubled it.
pub const max_text_bytes = 16 * 1024;

/// How much of a command goes into an approval's one-line summary.
pub const summary_chars = 120;

/// The most of a tool call's input that is carried while it waits for
/// approval (task 1651). Less than `max_text_bytes` would allow alone,
/// because an approval carries both: its command in `text` for the
/// control room, and the whole input here for a supervisor deciding.
/// `+hook` cuts this further if the request would not fit
/// (`hook.fitRequest`); `input_bytes` still says how long it was.
pub const max_input_bytes = 24 * 1024;

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

    /// Which of the session's agents said it, when it was not the main one:
    /// Claude Code's `agent_id`, present only inside a subagent (task 1561).
    /// It is what pairs a finished tool call with the approval it ends --
    /// a subagent's tool finishing says nothing about the main agent's
    /// prompt, or the other way round.
    agent_id: ?[]const u8,

    /// Where the CLI keeps its own record of this session, when it says:
    /// Claude Code's `transcript_path`. Not read by Polter -- the file is
    /// the CLI's -- only remembered beside the session, so that whoever
    /// looks back through a group can be pointed at it (task 1511).
    transcript_path: ?[]const u8,

    /// The short word for what happened: the session's `source`, the
    /// error type, the tool name, the notification type.
    detail: ?[]const u8,

    /// One line to go with `detail`: an approval's command, a failure's
    /// details.
    note: ?[]const u8,

    /// The long text an event carries, at most `max_text_bytes`: a finished
    /// turn's final answer; for an approval, the whole of what is to be
    /// approved -- the command, every step of it -- where `note` has only
    /// its first line's worth.
    text: ?[]const u8,

    /// How long `text` was before it was cut; equal to its length when it
    /// was not. Zero with no text.
    text_bytes: u64,

    /// For an approval, the whole of the tool call that waits on it: its
    /// `tool_input`, as compact JSON, at most `max_input_bytes` (task
    /// 1651). `text` is one field of it -- the command, or the file -- and
    /// a supervisor asked to approve an `Edit` has to see what the edit
    /// is. Not JSON any more when it was cut; `input_bytes` says so.
    ///
    /// **Not scrubbed**, on `Transcript`'s terms: it is what the
    /// permission box on that terminal's screen shows, kept in memory
    /// only while the approval stands, and handed only to whoever may
    /// read that screen.
    input: ?[]const u8,

    /// How long `input` was before it was cut. Zero with no input.
    input_bytes: u64,

    /// The turn ended with background work still running, so a still
    /// screen is waiting, not finished.
    waiting_on_background: bool,

    pub const none: Event = .{
        .event = .hooks_expected,
        .cli = "",
        .session_id = null,
        .agent_id = null,
        .transcript_path = null,
        .detail = null,
        .note = null,
        .text = null,
        .text_bytes = 0,
        .input = null,
        .input_bytes = 0,
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
    if (std.mem.eql(u8, cli, "codex")) return codex(arena, hook, obj);
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
    ev.transcript_path = try optionalString(obj, "transcript_path");
    ev.agent_id = try optionalString(obj, "agent_id");

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
        try approval(arena, &ev, obj);
    } else if (std.mem.eql(u8, hook, "PostToolUse") or
        std.mem.eql(u8, hook, "PostToolUseFailure"))
    {
        // Only the tool's name: its input and its response are the
        // agent's work, and this signal says only that work goes on.
        // A tool that failed has ended as surely as one that worked, and
        // without this a failed command would be counted as running until
        // the turn ends (task 1625).
        ev.event = .turn_resumed;
        ev.detail = try requireString(obj, "tool_name");
    } else if (std.mem.eql(u8, hook, "PreToolUse")) {
        // The name and nothing else, on the same terms as `PostToolUse`.
        ev.event = .tool_started;
        ev.detail = try requireString(obj, "tool_name");
    } else if (std.mem.eql(u8, hook, "Notification")) {
        const kind = try requireString(obj, "notification_type");
        if (!std.mem.eql(u8, kind, "idle_prompt") and
            !std.mem.eql(u8, kind, "elicitation_dialog")) return error.Ignored;
        ev.event = .awaiting_input;
        ev.detail = kind;
        // A dialog's message is the question itself, so it is carried: a
        // first line of it, and all of it. `idle_prompt` says only that
        // the agent is waiting ("Claude is waiting for your input"); what
        // it asked is the end of its last turn, which `Stop` already sent.
        if (std.mem.eql(u8, kind, "elicitation_dialog")) {
            if (try optionalString(obj, "message")) |message| {
                if (message.len > 0) {
                    ev.note = try oneLine(arena, prefixChars(message, summary_chars));
                    ev.text = cutBytes(message, max_text_bytes);
                    ev.text_bytes = message.len;
                }
            }
        }
    } else return error.UnknownEvent;

    return ev;
}

/// An approval: the tool, one line of what it is for, all of it, and the
/// call itself. The same for every CLI whose `PermissionRequest` carries
/// `tool_name` and `tool_input`.
fn approval(arena: Allocator, ev: *Event, obj: std.json.ObjectMap) Error!void {
    ev.event = .awaiting_approval;
    const tool = try requireString(obj, "tool_name");
    ev.detail = tool;
    ev.note = try oneLine(arena, try approvalSummary(obj, tool));
    // And all of it, as it was written: the control room cuts a
    // command into its steps, which a first 120 characters cannot be.
    if (try approvalWhole(obj, tool)) |whole| {
        ev.text = cutBytes(whole, max_text_bytes);
        ev.text_bytes = whole.len;
    }
    // And the call itself, every field of it: what the box asks about
    // is more than its first line (task 1651).
    if (obj.get("tool_input")) |input| {
        const json = try std.json.Stringify.valueAlloc(arena, input, .{});
        ev.input = cutBytes(json, max_input_bytes);
        ev.input_bytes = json.len;
    }
}

/// Codex, 0.163 and later (task 1668). Its hooks are Claude Code's in
/// shape -- the same event names, the same `session_id`, `tool_name`,
/// `tool_input`, `last_assistant_message` -- and the field names here are
/// the ones in its own input schemas (`codex-rs/hooks/src/schema.rs`).
///
/// What it does not have, and so what still falls to the screen: no
/// `StopFailure` (an API error ends a turn without a word), and no
/// notification for waiting on the person. What it has that Claude Code
/// does not: `Interrupt`, said when a turn is stopped part way -- the case
/// Claude Code's `Stop` stays silent on (adapters.md part 5).
///
/// ⚠️ Its `SessionStart` comes with the first turn, not when the program
/// starts (`run_pending_session_start_hooks`). That is the launch's to know
/// (`agent_cli.Launch.hooks_heard`); nothing here depends on it.
fn codex(arena: Allocator, hook: []const u8, obj: std.json.ObjectMap) Error!Event {
    if (obj.get("hook_event_name")) |v| switch (v) {
        .string => |s| if (!std.mem.eql(u8, s, hook)) return error.UnknownEvent,
        else => return error.MissingField,
    };

    var ev: Event = .none;
    ev.cli = "codex";
    ev.session_id = try requireString(obj, "session_id");
    ev.transcript_path = try optionalString(obj, "transcript_path");
    ev.agent_id = try optionalString(obj, "agent_id");

    if (std.mem.eql(u8, hook, "SessionStart")) {
        ev.event = .session_started;
        ev.detail = try optionalString(obj, "source");
    } else if (std.mem.eql(u8, hook, "UserPromptSubmit")) {
        ev.event = .turn_started;
    } else if (std.mem.eql(u8, hook, "Stop")) {
        ev.event = .turn_ended;
        if (try optionalString(obj, "last_assistant_message")) |text| {
            ev.text = cutBytes(text, max_text_bytes);
            ev.text_bytes = text.len;
        }
        // Codex has no background work that outlives a turn to report.
        ev.waiting_on_background = false;
    } else if (std.mem.eql(u8, hook, "Interrupt")) {
        // Stopped part way, by the person or by a supervisor's ctrl+c:
        // the turn is over and did not finish, which is what `failed`
        // says. The word says why, so it is not read as an API error.
        ev.event = .turn_failed;
        ev.detail = "interrupted";
    } else if (std.mem.eql(u8, hook, "PermissionRequest")) {
        try approval(arena, &ev, obj);
    } else if (std.mem.eql(u8, hook, "PostToolUse")) {
        ev.event = .turn_resumed;
        ev.detail = try requireString(obj, "tool_name");
    } else if (std.mem.eql(u8, hook, "PreToolUse")) {
        ev.event = .tool_started;
        ev.detail = try requireString(obj, "tool_name");
    } else return error.UnknownEvent;

    return ev;
}

/// The one line that says what an approval is for. A shell tool's command is
/// the case that matters -- `Bash`, or `PowerShell` on Windows (#888); other
/// tools say which file when they have one.
fn approvalSummary(obj: std.json.ObjectMap, tool: []const u8) Error!?[]const u8 {
    const input = switch (obj.get("tool_input") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    if (isPatchTool(tool)) {
        const patch = (try optionalString(input, "command")) orelse return null;
        return prefixChars(patchFile(patch) orelse return null, summary_chars);
    }
    const key = if (isShellTool(tool)) "command" else "file_path";
    const s = (try optionalString(input, key)) orelse return null;
    return prefixChars(s, summary_chars);
}

/// Codex's file edits: one tool, `apply_patch`, whose input is the whole
/// patch under `command` (`ApplyPatch` in `codex-rs/core/src/tools/approvals.rs`).
fn isPatchTool(tool: []const u8) bool {
    return std.mem.eql(u8, tool, "apply_patch");
}

/// The first file a patch touches, as its header line names it -- `***
/// Update File: src/a.zig` -- or null when it names none. The patch's first
/// line is `*** Begin Patch`, which says nothing about what is asked.
fn patchFile(patch: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, patch, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        for ([_][]const u8{ "*** Update File: ", "*** Add File: ", "*** Delete File: " }) |head| {
            if (std.mem.startsWith(u8, line, head)) return line;
        }
    }
    return null;
}

/// All of what an approval is for: the command, or the file.
fn approvalWhole(obj: std.json.ObjectMap, tool: []const u8) Error!?[]const u8 {
    const input = switch (obj.get("tool_input") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const key = if (isShellTool(tool) or isPatchTool(tool)) "command" else "file_path";
    return try optionalString(input, key);
}

/// The tools whose input is a command line.
fn isShellTool(tool: []const u8) bool {
    return std.mem.eql(u8, tool, "Bash") or std.mem.eql(u8, tool, "PowerShell");
}

/// The rows of this CLI's permission box that redraw while the box stands,
/// by a piece of text each contains (task 1655): a row with one of these in
/// it is not part of what makes a box the same box.
///
/// Claude Code in auto mode puts a countdown in the box -- "⚠ Claude Code
/// will automatically deny this request in 1:54, to avoid blocking
/// progress on an unattended session" (2.1.301), redrawn every second --
/// so the screen never stops moving while the box is up, and "has the
/// screen moved since the box was drawn" (`Bus.promptStanding`) said yes
/// for as long as it stood. The text is the CLI's own, read out of its
/// binary; the number in it is the only part that changes.
///
/// **Also what says such a box is up**: `Bus.boxPrint` gives nothing for a
/// screen with none of these rows on it, so the allowance never reaches a
/// screen whose box has gone.
pub fn volatileRows(cli: []const u8) []const []const u8 {
    if (std.mem.eql(u8, cli, "claude-code")) return &.{
        "will automatically deny this request in",
    };
    return &.{};
}

/// What kind of thing a tool asks approval for, by the tool's name as an
/// event's `detail` carries it.
pub const ToolKind = enum {
    /// A command in a POSIX shell, which can be cut into steps.
    shell,
    /// Anything else: a file, or a command in a shell with other rules
    /// (PowerShell's quoting is not the one `ShellSteps` knows). Shown as
    /// it is, in one piece.
    literal,
};

pub fn toolKind(tool: ?[]const u8) ToolKind {
    const name = tool orelse return .literal;
    return if (std.mem.eql(u8, name, "Bash")) .shell else .literal;
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

test "launch failure: the word a launcher gives, and any other word is still a failure" {
    try testing.expectEqual(LaunchFailure.not_found, LaunchFailure.parse("not_found"));
    try testing.expectEqual(LaunchFailure.failed, LaunchFailure.parse("failed"));
    try testing.expectEqual(LaunchFailure.failed, LaunchFailure.parse("something_newer"));
    try testing.expectEqual(LaunchFailure.failed, LaunchFailure.parse(null));
}

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

test "claude-code PermissionRequest carries the whole tool input, and says when it was cut (task 1651)" {
    setup();
    defer teardown();
    const ev = try tr("PermissionRequest",
        \\{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Edit",
        \\ "tool_input":{"file_path":"/w/a.zig","old_string":"x\n","new_string":"rm -rf /"}}
    );
    try testing.expectEqualStrings(
        \\{"file_path":"/w/a.zig","old_string":"x\n","new_string":"rm -rf /"}
    , ev.input.?);
    try testing.expectEqual(@as(u64, ev.input.?.len), ev.input_bytes);

    const a = test_arena.allocator();
    var body: std.ArrayListUnmanaged(u8) = .empty;
    try body.appendSlice(a,
        \\{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Write",
        \\ "tool_input":{"file_path":"/w/b","content":"
    );
    for (0..max_input_bytes) |_| try body.appendSlice(a, "é");
    try body.appendSlice(a, "\"}}");
    const big = try tr("PermissionRequest", body.items);
    try testing.expect(big.input.?.len <= max_input_bytes);
    try testing.expect(big.input_bytes > max_input_bytes * 2);
    try testing.expect(std.unicode.utf8ValidateSlice(big.input.?));

    // Nothing but an approval carries it.
    const done = try tr("PostToolUse",
        \\{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"a":1}}
    );
    try testing.expect(done.input == null);
}

test "claude-code PermissionRequest for the PowerShell tool names its command (#888)" {
    // Windows' shell tool is `PowerShell`, not `Bash`, and carries the same
    // `command`. Read as a file tool it had no `file_path`, so the approval
    // said nothing about what it was for.
    setup();
    defer teardown();
    const ev = try tr("PermissionRequest",
        \\{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"PowerShell",
        \\ "tool_input":{"command":"Remove-Item -Recurse C:\\w\\build","description":"d"}}
    );
    try testing.expectEqualStrings("PowerShell", ev.detail.?);
    const note = ev.note orelse return error.TestExpectedNote;
    try testing.expectEqualStrings("Remove-Item -Recurse C:\\w\\build", note);
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

test "claude-code PostToolUse is turn_resumed naming the tool, and nothing of its work" {
    setup();
    defer teardown();
    const ev = try tr("PostToolUse",
        \\{"session_id":"s","transcript_path":"/x","cwd":"/w","permission_mode":"default",
        \\ "hook_event_name":"PostToolUse","tool_name":"Bash",
        \\ "tool_input":{"command":"zig build test","description":"d"},
        \\ "tool_response":{"stdout":"ok","stderr":"","interrupted":false},
        \\ "tool_use_id":"toolu_01","duration_ms":812}
    );
    try testing.expectEqual(Kind.turn_resumed, ev.event);
    try testing.expectEqualStrings("Bash", ev.detail.?);
    try testing.expect(ev.note == null);
    try testing.expect(ev.text == null);

    // Inside a subagent both this and the approval say which one.
    try testing.expect(ev.agent_id == null);
    const sub = try tr("PostToolUse",
        \\{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion",
        \\ "agent_id":"a36a9e16d5b37235e","agent_type":"general-purpose","tool_input":{}}
    );
    try testing.expectEqualStrings("a36a9e16d5b37235e", sub.agent_id.?);
    const ask = try tr("PermissionRequest",
        \\{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion",
        \\ "agent_id":"a36a9e16d5b37235e","tool_input":{"questions":[]}}
    );
    try testing.expectEqualStrings("a36a9e16d5b37235e", ask.agent_id.?);
    try testing.expectEqualStrings(sub.detail.?, ask.detail.?);

    // No tool name: refused like any event missing what it is about.
    try testing.expectError(error.MissingField, tr("PostToolUse",
        \\{"session_id":"s","hook_event_name":"PostToolUse","tool_input":{}}
    ));
}

test "claude-code PreToolUse starts a tool and PostToolUseFailure ends one, naming it" {
    setup();
    defer teardown();
    const start = try tr("PreToolUse",
        \\{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash",
        \\ "tool_input":{"command":"zig build test"},"tool_use_id":"toolu_01"}
    );
    try testing.expectEqual(Kind.tool_started, start.event);
    try testing.expectEqualStrings("Bash", start.detail.?);
    try testing.expect(start.note == null);
    try testing.expect(start.text == null);

    const failed = try tr("PostToolUseFailure",
        \\{"session_id":"s","hook_event_name":"PostToolUseFailure","tool_name":"Bash",
        \\ "tool_input":{"command":"false"},"error":"exit 1","tool_use_id":"toolu_01"}
    );
    try testing.expectEqual(Kind.turn_resumed, failed.event);
    try testing.expectEqualStrings("Bash", failed.detail.?);

    try testing.expectError(error.MissingField, tr("PreToolUse",
        \\{"session_id":"s","hook_event_name":"PreToolUse","tool_input":{}}
    ));
}

fn trCodex(hook: []const u8, payload: []const u8) Error!Event {
    return translate(test_arena.allocator(), "codex", hook, payload);
}

// Codex payloads below have every field its input schemas
// (`codex-rs/hooks/src/schema.rs`, rust-v0.163.0) give the event.

test "1668: codex SessionStart, UserPromptSubmit and Stop are a session and a turn, with the answer" {
    setup();
    defer teardown();
    const started = try trCodex("SessionStart",
        \\{"session_id":"019a-c0de","transcript_path":"/h/.codex/sessions/r.jsonl","cwd":"/w",
        \\ "hook_event_name":"SessionStart","model":"gpt-5.6-luna","permission_mode":"default","source":"clear"}
    );
    try testing.expectEqual(Kind.session_started, started.event);
    try testing.expectEqualStrings("codex", started.cli);
    try testing.expectEqualStrings("019a-c0de", started.session_id.?);
    try testing.expectEqualStrings("clear", started.detail.?);
    try testing.expectEqualStrings("/h/.codex/sessions/r.jsonl", started.transcript_path.?);

    const turn = try trCodex("UserPromptSubmit",
        \\{"session_id":"019a-c0de","turn_id":"t1","transcript_path":null,"cwd":"/w",
        \\ "hook_event_name":"UserPromptSubmit","model":"gpt-5.6-luna","permission_mode":"default","prompt":"say hi"}
    );
    try testing.expectEqual(Kind.turn_started, turn.event);
    try testing.expect(turn.text == null);

    const ended = try trCodex("Stop",
        \\{"session_id":"019a-c0de","turn_id":"t1","transcript_path":null,"cwd":"/w",
        \\ "hook_event_name":"Stop","model":"gpt-5.6-luna","permission_mode":"default",
        \\ "stop_hook_active":false,"last_assistant_message":"hi，做完了"}
    );
    try testing.expectEqual(Kind.turn_ended, ended.event);
    try testing.expectEqualStrings("hi，做完了", ended.text.?);
    try testing.expectEqual(@as(u64, ended.text.?.len), ended.text_bytes);
    try testing.expect(!ended.waiting_on_background);

    // A turn that ended with nothing said: null, not a refusal.
    const silent = try trCodex("Stop",
        \\{"session_id":"s","turn_id":"t","transcript_path":null,"cwd":"/w","hook_event_name":"Stop",
        \\ "model":"m","permission_mode":"default","stop_hook_active":false,"last_assistant_message":null}
    );
    try testing.expectEqual(Kind.turn_ended, silent.event);
    try testing.expect(silent.text == null);
}

test "1668: codex Interrupt is a turn that failed because it was stopped" {
    setup();
    defer teardown();
    const ev = try trCodex("Interrupt",
        \\{"session_id":"s","turn_id":"t","transcript_path":null,"cwd":"/w",
        \\ "hook_event_name":"Interrupt","model":"m","permission_mode":"default"}
    );
    try testing.expectEqual(Kind.turn_failed, ev.event);
    try testing.expectEqualStrings("interrupted", ev.detail.?);
}

test "1668: codex PermissionRequest names a shell command, a patch's file and an MCP tool" {
    setup();
    defer teardown();
    const bash = try trCodex("PermissionRequest",
        \\{"session_id":"s","turn_id":"t","transcript_path":null,"cwd":"/w","hook_event_name":"PermissionRequest",
        \\ "model":"m","permission_mode":"default","tool_name":"Bash",
        \\ "tool_input":{"command":"zig build test","description":"run the tests"}}
    );
    try testing.expectEqual(Kind.awaiting_approval, bash.event);
    try testing.expectEqualStrings("Bash", bash.detail.?);
    try testing.expectEqualStrings("zig build test", bash.note.?);
    try testing.expectEqualStrings("zig build test", bash.text.?);
    try testing.expect(bash.input != null);

    const patch = try trCodex("PermissionRequest",
        \\{"session_id":"s","turn_id":"t","transcript_path":null,"cwd":"/w","hook_event_name":"PermissionRequest",
        \\ "model":"m","permission_mode":"default","tool_name":"apply_patch",
        \\ "tool_input":{"command":"*** Begin Patch\n*** Update File: src/a.zig\n@@\n-x\n+y\n*** End Patch"}}
    );
    try testing.expectEqualStrings("apply_patch", patch.detail.?);
    try testing.expectEqualStrings("*** Update File: src/a.zig", patch.note.?);
    try testing.expect(std.mem.startsWith(u8, patch.text.?, "*** Begin Patch"));

    const mcp = try trCodex("PermissionRequest",
        \\{"session_id":"s","turn_id":"t","transcript_path":null,"cwd":"/w","hook_event_name":"PermissionRequest",
        \\ "model":"m","permission_mode":"default","tool_name":"mcp__polter__me","tool_input":{}}
    );
    try testing.expectEqualStrings("mcp__polter__me", mcp.detail.?);
    try testing.expect(mcp.note == null);
    try testing.expectEqualStrings("{}", mcp.input.?);
}

test "1668: codex PreToolUse and PostToolUse start and end a tool; what it lacks is refused" {
    setup();
    defer teardown();
    const pre = try trCodex("PreToolUse",
        \\{"session_id":"s","turn_id":"t","transcript_path":null,"cwd":"/w","hook_event_name":"PreToolUse",
        \\ "model":"m","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"c1"}
    );
    try testing.expectEqual(Kind.tool_started, pre.event);
    try testing.expectEqualStrings("Bash", pre.detail.?);
    const post = try trCodex("PostToolUse",
        \\{"session_id":"s","turn_id":"t","transcript_path":null,"cwd":"/w","hook_event_name":"PostToolUse",
        \\ "model":"m","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"ls"},
        \\ "tool_response":"a\nb","tool_use_id":"c1"}
    );
    try testing.expectEqual(Kind.turn_resumed, post.event);
    try testing.expectEqualStrings("Bash", post.detail.?);

    // Claude Code's words that Codex never says are not taken from it.
    try testing.expectError(error.UnknownEvent, trCodex("StopFailure",
        \\{"session_id":"s","hook_event_name":"StopFailure","error":"rate_limit"}
    ));
    try testing.expectError(error.UnknownEvent, trCodex("SessionEnd",
        \\{"session_id":"s","transcript_path":null,"cwd":"/w","hook_event_name":"SessionEnd","reason":"exit"}
    ));
    // Without a session, nothing it says can be put anywhere.
    try testing.expectError(error.MissingField, trCodex("Stop",
        \\{"turn_id":"t","hook_event_name":"Stop","last_assistant_message":"x"}
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
    try testing.expectError(error.UnknownEvent, tr("SubagentStart",
        \\{"session_id":"s","hook_event_name":"SubagentStart"}
    ));
    try testing.expectError(error.UnknownEvent, tr("Stop",
        \\{"session_id":"s","hook_event_name":"SessionStart"}
    ));
    try testing.expectError(error.UnknownCli, translate(
        test_arena.allocator(),
        "gemini",
        "Stop",
        "{}",
    ));
}

test "prefixChars counts characters, not bytes" {
    try testing.expectEqualStrings("ab", prefixChars("abc", 2));
    try testing.expectEqualStrings("中文", prefixChars("中文字", 2));
    try testing.expectEqualStrings("", prefixChars("", 5));
}

test "claude-code Notification: a dialog's question is carried whole, an idle prompt's boilerplate is not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Longer than the summary and than the 160 bytes the bus keeps of a note.
    var question: std.ArrayListUnmanaged(u8) = .empty;
    for (0..40) |_| try question.appendSlice(a, "发票编号要按租户分开吗？");
    const payload = try std.fmt.allocPrint(a,
        \\{{"session_id":"s","hook_event_name":"Notification","message":"{s}","notification_type":"elicitation_dialog"}}
    , .{question.items});
    const ev = try translate(a, "claude-code", "Notification", payload);
    try testing.expectEqual(Kind.awaiting_input, ev.event);
    try testing.expect(ev.text != null);
    try testing.expect(ev.note != null);
    try testing.expectEqualStrings(question.items, ev.text.?);
    try testing.expectEqual(@as(u64, question.items.len), ev.text_bytes);
    try testing.expect(ev.note.?.len < question.items.len);
    try testing.expect(std.mem.startsWith(u8, question.items, ev.note.?));

    const idle = try translate(a, "claude-code", "Notification",
        \\{"session_id":"s","hook_event_name":"Notification","message":"Claude is waiting for your input",
        \\ "notification_type":"idle_prompt"}
    );
    try testing.expectEqual(Kind.awaiting_input, idle.event);
    try testing.expect(idle.note == null);
    try testing.expect(idle.text == null);
}

test "cutBytes never ends inside a character" {
    try testing.expectEqualStrings("中", cutBytes("中文", 4));
    try testing.expectEqualStrings("中文", cutBytes("中文", 6));
    try testing.expectEqualStrings("", cutBytes("中", 2));
}
