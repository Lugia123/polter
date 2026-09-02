const std = @import("std");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const global = @import("../global.zig");
const transport = @import("../poltergeist/transport.zig");

const log = std.log.scoped(.mcp);

/// MCP protocol revision this speaks. Sent back in `initialize`.
const protocol_version = "2024-11-05";

/// What every client is told at `initialize`, before it asks for anything.
///
/// MCP puts this in the connecting agent's system prompt, which is the one
/// place a compaction does not reach -- so unlike anything injected into the
/// conversation, it does not need replaying.
///
/// It is a map of the tool families and nothing else. It exists because of a
/// specific, observed failure: a supervisor opened its night by writing out a
/// tool list from memory of what it used yesterday, and `task_*` was not on
/// it. Every later decision was then made without the panel on the table --
/// not chosen against, never present. A skill cannot catch that, because the
/// narrowing happens before anything gets read. See docs/poltergeist/tasks.md.
const instructions =
    "Polter is the terminal multiplexer you are running inside. It gives you four\\n" ++
    "families of tools. tools/list has all of them, but narrowing your own tool set\\n" ++
    "down to the ones you used yesterday is the way they get missed, so this is the\\n" ++
    "whole map, stated before you choose.\\n" ++
    "\\n" ++
    "terminal_* -- see and drive any Polter terminal you may reach. terminal_list,\\n" ++
    "terminal_read, terminal_send, terminal_key, terminal_action, terminal_open.\\n" ++
    "terminal_keys and terminal_actions catalogue what can be sent.\\n" ++
    "\\n" ++
    "group_* -- the group chat. For talking and for the record, not for directing:\\n" ++
    "a terminal somebody is minding is never interrupted by a group post, so a post\\n" ++
    "on its own moves nobody. group_create, group_add, group_post, group_read.\\n" ++
    "\\n" ++
    "task_* -- the task panel. This is how work is handed out, and it is the part\\n" ++
    "that survives a restart, a compaction, and the night. A supervisor uses\\n" ++
    "task_create, task_assign, task_close, task_cancel. Anyone uses task_progress\\n" ++
    "on their own work and task_list to see it.\\n" ++
    "\\n" ++
    "Handing work out is four steps, and dropping the panel out of them is the\\n" ++
    "failure this note exists to prevent: task_create, then group_post the plan for\\n" ++
    "the record, then terminal_send each worker its own instruction, then\\n" ++
    "task_assign.\\n" ++
    "\\n" ++
    "me says who you are and what you may reach. skill_read has the full guidance.\\n";

/// The whole `initialize` result, kept as one literal so the test below
/// parses the bytes that actually go out rather than a copy of them.
const initialize_result =
    \\{"protocolVersion":"
++ protocol_version ++
    \\","capabilities":{"tools":{}},"serverInfo":{"name":"poltergeist","version":"0"},"instructions":"
++ instructions ++
    \\"}
;

/// Longest reply we will read from the host. Screen dumps are the large
/// case, and the host caps them below this.
const max_line = 256 * 1024;

/// Longest request the host will read. Kept in step with
/// `Server.max_request_bytes`; a mismatch means the host silently drops the
/// connection on a request the sidecar thought was fine.
const max_request_bytes = 64 * 1024;

pub const Options = struct {
    /// Socket to reach Ghostty on. Defaults to `GHOSTTY_POLTER_SOCKET`.
    socket: ?[]const u8 = null,

    /// Token identifying this terminal. Defaults to `GHOSTTY_POLTER_TOKEN`.
    token: ?[]const u8 = null,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `mcp` command runs an MCP server that lets an agent see and
/// steer the other terminals a Poltergeist supervisor is watching.
///
/// It is not run by hand. Point an MCP client at it:
///
///   {"command": "polter", "args": ["+mcp"]}
///
/// It finds the terminal it belongs to through `GHOSTTY_POLTER_SOCKET` and
/// `GHOSTTY_POLTER_TOKEN`, which Ghostty puts in every terminal's
/// environment when `poltergeist-mcp` is enabled. Identity comes from that
/// token alone -- an agent cannot ask to be treated as a different terminal.
///
/// Flags:
///
///   * `--socket`: override the socket path.
///   * `--token`: override the token.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const io = global.io();

    var env = try global.environMap();
    defer env.deinit();

    const socket_path = opts.socket orelse
        env.get("GHOSTTY_POLTER_SOCKET") orelse
        {
            log.err("no socket: is `poltergeist-mcp` enabled, and is this running inside Ghostty?", .{});
            return 1;
        };

    const token = opts.token orelse
        env.get("GHOSTTY_POLTER_TOKEN") orelse
        {
            log.err("no token: is `poltergeist-mcp` enabled, and is this running inside Ghostty?", .{});
            return 1;
        };

    var host: Host = try .connect(alloc, io, socket_path, token);
    defer host.deinit();

    return serve(alloc, io, &host);
}

/// The connection back to Ghostty.
const Host = struct {
    alloc: Allocator,
    io: std.Io,
    stream: transport.Conn,
    read_buf: []u8,
    write_buf: []u8,
    reader: transport.Reader,
    writer: transport.Writer,

    /// The pipe to Polter, **through `transport`**.
    ///
    /// **This used to be `net.UnixAddress.init(path)`, and on Windows that could
    /// not work.** `transport.zig` picks a named pipe for that platform on
    /// purpose -- it explains at length why, and the short version is that Zig
    /// 0.16's Windows AF_UNIX accept path answers a cancelled request with
    /// `unreachable`, so the supported way to stop a server panics. So
    /// `GHOSTTY_POLTER_SOCKET` carries `\\.\pipe\polter-<hex>` there, and
    /// opening that as a unix socket address fails every time.
    ///
    /// `transport.zig` already said this file used `connect`: "the client half,
    /// **shared by** the MCP client, the chat client and the tests". **That
    /// sentence was written as a statement of fact and was not one.** A comment
    /// that describes an arrangement nobody implemented is worse than none: it
    /// answers the question, so the next person stops looking.
    fn connect(
        alloc: Allocator,
        io: std.Io,
        path: []const u8,
        token: []const u8,
    ) !Host {
        const stream = try transport.connect(io, path);
        errdefer stream.close(io);

        const read_buf = try alloc.alloc(u8, max_line);
        errdefer alloc.free(read_buf);
        const write_buf = try alloc.alloc(u8, max_line);
        errdefer alloc.free(write_buf);

        var self: Host = .{
            .alloc = alloc,
            .io = io,
            .stream = stream,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .reader = stream.reader(io, read_buf),
            .writer = stream.writer(io, write_buf),
        };

        // Prove who we are before anything else. The host closes the
        // connection if this does not check out.
        try self.writer.interface.print(
            \\{{"method":"auth","params":{{"token":"{s}"}}}}
        ++ "\n", .{token});
        try self.writer.interface.flush();

        const reply = (try self.reader.interface.takeDelimiter('\n')) orelse
            return error.EndOfStream;
        if (std.mem.indexOf(u8, reply, "\"ok\":true") == null) {
            log.err("ghostty refused this token", .{});
            return error.AuthFailed;
        }

        return self;
    }

    fn deinit(self: *Host) void {
        self.stream.close(self.io);
        self.alloc.free(self.read_buf);
        self.alloc.free(self.write_buf);
        self.* = undefined;
    }

    /// Send one request line and return the reply line. The reply borrows
    /// the read buffer and is valid until the next call.
    fn call(self: *Host, line: []const u8) ![]const u8 {
        try self.writer.interface.writeAll(line);
        try self.writer.interface.writeByte('\n');
        try self.writer.interface.flush();
        // `takeDelimiter` consumes the newline; the exclusive form leaves it
        // and every later call returns an empty slice forever.
        return (try self.reader.interface.takeDelimiter('\n')) orelse
            error.EndOfStream;
    }
};

/// Every tool this exposes, with the request it maps to.
///
/// The list is deliberately short and matches `src/poltergeist/rpc.zig`
/// exactly. In particular there is no tool for holding a terminal to its
/// work or letting one go, and none for answering another agent's
/// permission prompt; see that file for why neither will be added.
const tools = [_]Tool{
    .{
        .name = "me",
        .description = "Which terminal this agent is running in, and whether it is supervising or supervised.",
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "terminal_list",
        .description = "Every terminal Poltergeist knows about: how long each screen has been unchanged, and whether it is on duty. Durations only -- call terminal_read to see what is actually on one.",
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "notices",
        .description = "What has happened that you have not been shown yet: which terminals went quiet and for how long, and which came back to work. Reading clears them, so what comes back will not come back again. You are also handed this on a timer; call it yourself whenever you finish something, rather than waiting to be interrupted. An empty answer means nothing is waiting. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "notify_user",
        .description = "Ask for the person to be told something. Use `reason: authorisation` when a terminal is stopped on a permission prompt -- nobody may answer those for it, so those go out at any hour. Use `reason: scheduling` for questions you could answer yourself (keep going, change tack, give up); those are held back during the hours the user set aside, and handed back to you to decide. **Read the reply**: it says whether the message actually went anywhere. If it did not, do not sit waiting for an answer. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"reason":{"type":"string","enum":["authorisation","scheduling"]},"title":{"type":"string"},"body":{"type":"string"},"id":{"type":"string","description":"The terminal this is about, if it is about one"}},"required":["reason","title"]}
        ,
    },
    .{
        .name = "session_recall",
        .description = "What last night's arrangement was, written down before the restart: the groups, what each was for, and for every terminal where it was working and what it was called. Read this first after a restart, then look at what is open now and decide for yourself which is which -- nothing here does that for you, and a wrong guess would attach one terminal's supervision to another without saying so. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "group_set_brief",
        .description = "Say what a group is for, in your own words. Write this right after creating a group, while you still know why you made it -- in eight hours group_list will show you a name you no longer recognise, and that is exactly when you have to decide whether it still needs watching. Only you and the person at the keyboard see it; the members do not. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"text":{"type":"string"}},"required":["group","text"]}
        ,
    },
    .{
        .name = "group_members",
        .description = "Who is in a group, and what each terminal is currently called. Useful before asking somebody to do something: a group where the terminal you want is not a member cannot reach it.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"}},"required":["group"]}
        ,
    },
    .{
        .name = "terminal_read",
        .description = "Read the visible screen of another terminal. Scrollback is not " ++
            "available. You may read any terminal that carries no Polter mark; a " ++
            "terminal that is a supervisor, or that somebody is watching, is only " ++
            "reachable by a supervisor. A terminal the user has shielded is reachable " ++
            "by nobody.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string","description":"Terminal id, as shown by terminal_list"}},"required":["id"]}
        ,
    },
    .{
        .name = "terminal_send",
        .description = "Type text into another terminal, exactly as the user would. " ++
            "Text only: control characters are stripped on the way in, so this cannot " ++
            "press ctrl+c or escape however they are spelled -- terminal_key does that. " ++
            "Same reach rule as terminal_read: unmarked terminals are open to anyone, " ++
            "marked ones to supervisors, shielded ones to nobody.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"},"text":{"type":"string"},"submit":{"type":"boolean","description":"Press return afterwards; defaults to true"}},"required":["id","text"]}
        ,
    },
    .{
        .name = "clock_out",
        .description = "Mark a terminal as done for the day, so its going quiet stops being reported. Refused for a terminal the user is holding to its work. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"},"reason":{"type":"string"}},"required":["id"]}
        ,
    },
    .{
        .name = "clock_in",
        .description = "Put a terminal back on duty. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}
        ,
    },
    .{
        .name = "skill_read",
        .description = "Read one of Poltergeist's skills: the text describing how to supervise, or how to read a terminal. Start with `supervising`.",
        .schema =
        \\{"type":"object","properties":{"name":{"type":"string","description":"supervising or reading-a-terminal"}},"required":["name"]}
        ,
    },
    .{
        .name = "group_create",
        .description = "Make a group for terminals to talk in. Supervisor only: who talks to whom is yours to arrange.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string","description":"Lowercase letters, digits and dashes"}},"required":["group"]}
        ,
    },
    .{
        .name = "group_destroy",
        .description = "Take a group off the list. The record is kept -- every day file stays on disk; what goes is the group, its members and its tasks. Refused with GroupActive while any terminal in it is still open: destroying it would drop them from a conversation they are working in, so take them out with group_remove first. Note that group_create puts you in the group you made, so you are one of the terminals to remove. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"}},"required":["group"]}
        ,
    },
    .{
        .name = "group_add",
        .description = "Put a terminal in a group. Choose whether it sees what was said before it arrived: `none` starts the conversation for it now, `all` hands it everything still in the log. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"id":{"type":"string"},"history":{"type":"string","enum":["none","all"],"description":"Defaults to none"}},"required":["group","id"]}
        ,
    },
    .{
        .name = "group_remove",
        .description = "Take a terminal out of a group. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"id":{"type":"string"}},"required":["group","id"]}
        ,
    },
    .{
        .name = "group_compact",
        .description = "Replace everything up to a given seq with one summary you write, the way /compact shortens a conversation. Use it when a group's history has grown longer than it is worth. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"through":{"type":"integer","description":"Replace messages up to and including this seq"},"summary":{"type":"string","description":"What those messages amounted to"}},"required":["group","through","summary"]}
        ,
    },
    .{
        .name = "group_list",
        .description = "Which groups you are in.",
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "group_post",
        .description = "Say something to a group you are in. The others are told they have a message; they read it when they choose to.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"text":{"type":"string"}},"required":["group","text"]}
        ,
    },
    .{
        .name = "group_read",
        .description = "Read messages you have not seen in a group. Pass the last seq you saw to pick up from there. A message marked `summary` stands in for older ones that were compacted away.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"since":{"type":"integer"}},"required":["group"]}
        ,
    },
    .{
        .name = "group_history",
        .description = "Read further back in a group than it still holds, out of the log on disk. `group_read` hands you what is current; this hands you what came before it. Page with `log_seq`: pass the smallest one you have seen as `before_seq` and you get the batch before that. `more: false` means you have reached the beginning of what was kept. The per-group `seq` is 0 here -- the log does not record it.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"before_seq":{"type":"integer"},"limit":{"type":"integer"}},"required":["group"]}
        ,
    },
    .{
        .name = "plugin_list",
        .description = "What plugins are installed, whether each is switched on, what parameters it takes, and -- for the chat archive, which runs all the time -- how far it has got and whether it is healthy. Configured values are not handed back in the clear: a reference (env:, file:, keychain:, cmd:) is shown as the user wrote it, because where a secret lives is not the secret; a value typed in plainly is reported as being set and nothing more. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"key":{"type":"string","description":"Just this one; omit for all of them"}},"additionalProperties":false}
        ,
    },
    .{
        .name = "plugin_configure",
        .description = "Set up a plugin for the user: switch it on, and set its parameters. Give a credential as a reference to somewhere the user has already put it -- env:NAME, keychain:service/account, or file: naming a file under their polter config directory -- never as the secret itself; a parameter the plugin marks secret will refuse a plaintext value and tell you so. A cmd: reference is refused outright: it is a command Polter would run later on its own, outside whatever authorises you now, so writing one is not yours to do -- describe the line and let the user write it. Switching a plugin off is refused for the same reason: it is the channel they hear about things on. Read the reply -- it says whether the change is live or waits for a restart. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"key":{"type":"string"},"enabled":{"type":"boolean","description":"Switch it on. Switching one off is refused."},"params":{"type":"object","description":"Parameter name to value. An empty string clears one.","additionalProperties":{"type":"string"}}},"required":["key"],"additionalProperties":false}
        ,
    },
    .{
        .name = "plugin_test",
        .description = "Prove a plugin works before the night it is needed. For a notification plugin this really sends one, with wording of Polter's own, at whatever hour it is -- so use it once, deliberately. For the chat archive nothing is started: it is already running and holding the cursor, a second copy would push the same cursor, and the protocol has no dry run to offer instead -- what comes back is how the running one is getting on, which is the answer to \"why is nothing being archived\". Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"key":{"type":"string"}},"required":["key"],"additionalProperties":false}
        ,
    },
    .{
        .name = "set_quiescence_threshold",
        .description = "How long a terminal must be still before it is reported. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"},"ms":{"type":"integer"}},"required":["id","ms"]}
        ,
    },
    .{
        .name = "set_watch",
        .description = "Put a terminal under your supervision, or take it out again. " ++
            "Watching it is what makes its quiet spells arrive in your notices, and it " ++
            "also marks the terminal: once watched, no terminal that is not a supervisor " ++
            "can reach it. It is not what lets *you* read it -- any supervisor may read " ++
            "and type into any terminal, watched or not. `watch` is required and must be " ++
            "spelled exactly that: a parameter this tool does not know is refused rather " ++
            "than ignored. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"},"watch":{"type":"boolean","description":"true takes hold of it, false lets it go. Required: there is no default, because the two are not equally easy to undo."}},"required":["id","watch"]}
        ,
    },
    .{
        .name = "config_get",
        .description = "What the user has configured. Give a key to see just that setting " ++
            "-- `poltergeist-notice-interval`, `poltergeist-notify-window`, " ++
            "`poltergeist-supervisor-stand-down` -- or no key at all to see everything " ++
            "(long, and cut off at the same budget a conversation gets). Read only; " ++
            "changing settings is the user's. Worth reading before you are refused " ++
            "something: the hours you may not disturb anybody, and whether you may take " ++
            "yourself off duty, are both in here. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"key":{"type":"string","description":"Omit for all of them"}}}
        ,
    },
    .{
        .name = "terminal_open",
        .description = "Open a terminal in this window, starting in a directory you " ++
            "choose. Use this rather than terminal_action(new_tab): a tab opened that way " ++
            "starts wherever the terminal that opened it is standing, so four pieces of " ++
            "work in four directories cannot be set up that way at all. `cwd` must be an " ++
            "absolute path that exists -- a directory that is not there is refused rather " ++
            "than opened somewhere else quietly. Pass watch: true to mind it from the " ++
            "moment it exists. The reply carries `id` when the terminal was ready before " ++
            "the call returned; when it is missing the tab is still opening and " ++
            "terminal_list will have it in a moment. **What you get is a shell " ++
            "in that directory with nothing running in it**, so whatever should " ++
            "run there is a separate terminal_send -- and it need not be an " ++
            "agent CLI: a build, a server, a log to tail are all ordinary uses. " ++
            "Until something is running, that terminal has no bracketed paste, " ++
            "so the first send must be a single line. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"cwd":{"type":"string"},"watch":{"type":"boolean","description":"Defaults to false"}},"required":["cwd"]}
        ,
    },
    .{
        .name = "terminal_action",
        .description = "Do to a terminal what the menu bar does. `action` is a Ghostty " ++
            "keybinding action, written exactly as a config file writes it: `new_tab`, " ++
            "`close_surface`, `toggle_fullscreen`, `copy_to_clipboard`, " ++
            "`increase_font_size:1`, `goto_split:left`, `new_split:right`, " ++
            "`inspector:toggle`. Everything on the menu bar is one of these, and so is " ++
            "everything else a key could be bound to. Call terminal_actions for the list " ++
            "-- guessing at a name gets you UnknownAction, which is a typo, not a refusal " ++
            "by the terminal. A new tab opens in the same directory as the terminal you " ++
            "asked from, which is worth thinking about before you ask. Same reach rule as " ++
            "terminal_read. `close_surface` is the one action that can answer " ++
            "AwaitingConfirmation: an unmarked terminal with something still running in " ++
            "it gets the same confirmation a person clicking close would get, the " ++
            "terminal stays open, and nothing here can press that button -- wait and " ++
            "check terminal_list, or ask the user. A terminal you are minding closes " ++
            "without asking.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"},"action":{"type":"string"}},"required":["id","action"]}
        ,
    },
    .{
        .name = "terminal_actions",
        .description = "Every action terminal_action will take, and which of them want a " ++
            "value after a colon. Read this before guessing at a name.",
        .schema =
        \\{"type":"object","properties":{}}
        ,
    },
    .{
        .name = "terminal_key",
        .description = "Press a key in another terminal, as if the person at the " ++
            "keyboard had. `key` is a Ghostty keybinding trigger, written exactly as a " ++
            "config file writes one: `ctrl+c`, `escape`, `ctrl+z`, `ctrl+shift+k`, " ++
            "`f2`, `arrow_down`. This is how you interrupt something -- terminal_send " ++
            "cannot, because the text it types has its control characters stripped on " ++
            "the way in. Ordinary characters are refused here for the same reason in " ++
            "reverse: `a` is text and belongs in terminal_send. Call terminal_keys for " ++
            "the vocabulary. Same reach rule as terminal_read.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"},"key":{"type":"string"}},"required":["id","key"]}
        ,
    },
    .{
        .name = "terminal_keys",
        .description = "The vocabulary terminal_key accepts: every modifier name and " ++
            "every key name, joined with `+`. Read this rather than guessing at a name.",
        .schema =
        \\{"type":"object","properties":{}}
        ,
    },
    .{
        .name = "stand_down",
        .description = "Stop being a supervisor, once the work you were minding is " ++
            "finished. Being one costs you an interruption every notice interval for as " ++
            "long as it lasts, and after the work is done that box is empty every time. " ++
            "Let each terminal go first with set_watch(id, false) -- this releases " ++
            "nobody, and is refused while you still mind any. Say in the group that you " ++
            "are finishing and why, before you do it: afterwards you cannot appoint " ++
            "yourself again, only the user can. The user may also have said the standing " ++
            "is theirs alone to withdraw, in which case this comes back as " ++
            "StandingInstruction and the answer is to say so, not to look for another " ++
            "way. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{}}
        ,
    },
    .{
        .name = "become_supervisor",
        .description = "Put yourself forward as a supervisor, when you can see work " ++
            "that needs somebody co-ordinating it and nobody is. Takes no arguments: " ++
            "it is about you. Allowed if nobody is minding you. Refused if you are " ++
            "being watched -- you already have a supervisor, it would not hear of " ++
            "this, and text arriving in a watched terminal must not be able to " ++
            "rearrange who may reach whom; ask your supervisor or the user instead.",
        .schema =
        \\{"type":"object","properties":{}}
        ,
    },
    .{
        .name = "task_create",
        .description = "Put a piece of work on a group's panel: one line saying what it is. It answers with a task number. The panel is what survives the night -- an instruction you typed into a terminal has scrolled out of that agent's context by 3am, and so has your memory of sending it. Keep the title to a line; the acceptance test and the detail go in the message you send the worker, not here. Supervisor only, and only in a group you made.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"title":{"type":"string","description":"One line. Not the requirement, just what it is."}},"required":["group","title"],"additionalProperties":false}
        ,
    },
    .{
        .name = "task_assign",
        .description = "Say which terminal is doing a task. **A line is typed into that terminal saying the task is theirs, and only then does the panel record it** -- an assignment nobody was told about is one only you can see, and the group cannot carry it because a terminal you are minding is not woken by a post. **Read the reply**: it says whether the terminal was actually told, and if it could not be, nothing was assigned. What the work *is* still goes in your own terminal_send: the line Polter types names the task and nothing more. Pass id 0 to take it back off somebody without cancelling it; there is nobody to tell, so nothing is typed. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"task":{"type":"integer"},"id":{"type":"string","description":"The terminal responsible, or 0 for nobody"}},"required":["task","id"],"additionalProperties":false}
        ,
    },
    .{
        .name = "task_close",
        .description = "The work is done and you have checked it. Nothing is sent to the worker: it finished, it reported, and this is you agreeing. A closed task stays on the panel for the person at the keyboard to read back in the morning, and disappears from the worker's own task_list. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"task":{"type":"integer"}},"required":["task"],"additionalProperties":false}
        ,
    },
    .{
        .name = "task_cancel",
        .description = "Call a task off. **A line is typed into the worker's terminal telling it to stop, and only then does the task leave its list.** A task that merely stopped being on the panel would leave the agent working on something nobody wants -- it has no reason to look at the panel again. **Read the reply**: it says whether the worker was actually told. If its terminal has gone, this refuses and the task stays open rather than pretending. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"task":{"type":"integer"}},"required":["task"],"additionalProperties":false}
        ,
    },
    .{
        .name = "task_progress",
        .description = "Move one of your own tasks along: queued, working, blocked, done. Yours only, and only while it is open -- a task that was closed or cancelled refuses, which is how you find out you missed a cancellation. Set `blocked` the moment it is true; that is the one a supervisor watches for. `done` says you believe it is finished, not that it is closed -- closing is the supervisor's word after it has checked. Report in the group as well, naming the task number.",
        .schema =
        \\{"type":"object","properties":{"task":{"type":"integer"},"progress":{"type":"string","enum":["queued","working","blocked","done"]}},"required":["task","progress"],"additionalProperties":false}
        ,
    },
    .{
        .name = "task_list",
        .description = "The tasks in a group. What you get depends on who you are, because the two questions are different: a supervisor is handed the group's whole panel, closed and cancelled work included, and anybody else is handed its own tasks that are still open and nothing else. Not a restriction so much as the point -- what your peers are doing is not yours to spend context on.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"}},"required":["group"],"additionalProperties":false}
        ,
    },
};

const Tool = struct {
    name: []const u8,
    description: []const u8,
    schema: []const u8,
};

fn serve(alloc: Allocator, io: std.Io, host: *Host) !u8 {
    var in_buf: [max_line]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;

    var stdin: std.Io.File = .stdin();
    var stdout: std.Io.File = .stdout();
    var reader = stdin.reader(io, &in_buf);
    var writer = stdout.writer(io, &out_buf);

    while (true) {
        // A null line is end of stdin: the client closed, so we are done.
        const line = (try reader.interface.takeDelimiter('\n')) orelse return 0;
        if (line.len == 0) continue;

        handleOne(alloc, host, &writer.interface, line) catch |err| {
            log.warn("mcp: could not handle a message err={}", .{err});
        };
    }
}

fn handleOne(
    alloc: Allocator,
    host: *Host,
    out: *std.Io.Writer,
    line: []const u8,
) !void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const msg = std.json.parseFromSliceLeaky(std.json.Value, aa, line, .{}) catch {
        // No id to answer against, so there is nobody to tell.
        return;
    };
    const obj = switch (msg) {
        .object => |o| o,
        else => return,
    };

    const method = switch (obj.get("method") orelse return) {
        .string => |s| s,
        else => return,
    };

    // A notification has no id and takes no reply. `notifications/initialized`
    // is the common one, and answering it is a protocol error.
    const id = obj.get("id") orelse return;

    if (std.mem.eql(u8, method, "initialize")) {
        try writeResult(out, id, aa, initialize_result);
        return;
    }

    // MCP requires a server to answer ping. Falling through to "method not
    // found" makes a client treat a healthy server as broken.
    if (std.mem.eql(u8, method, "ping")) {
        try writeResult(out, id, aa, "{}");
        return;
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        var body: std.Io.Writer.Allocating = .init(aa);
        defer body.deinit();
        const w = &body.writer;

        try w.writeAll("{\"tools\":[");
        for (tools, 0..) |t, i| {
            if (i > 0) try w.writeAll(",");
            try w.print(
                \\{{"name":"{s}","description":{f},"inputSchema":{s}}}
            , .{ t.name, std.json.fmt(t.description, .{}), t.schema });
        }
        try w.writeAll("]}");

        try writeResult(out, id, aa, body.written());
        return;
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        const params = switch (obj.get("params") orelse .null) {
            .object => |o| o,
            else => return writeToolError(out, id, aa, "call had no params"),
        };
        const name = switch (params.get("name") orelse .null) {
            .string => |s| s,
            else => return writeToolError(out, id, aa, "call had no tool name"),
        };

        var known = false;
        for (tools) |t| {
            if (std.mem.eql(u8, t.name, name)) known = true;
        }
        if (!known) return writeToolError(out, id, aa, "no such tool");

        // The host speaks the same method names, so the call is a rewrap
        // rather than a translation.
        const arguments: []const u8 = if (params.get("arguments")) |a|
            try std.fmt.allocPrint(aa, "{f}", .{std.json.fmt(a, .{})})
        else
            "{}";

        const request = try std.fmt.allocPrint(aa,
            \\{{"method":"{s}","params":{s}}}
        , .{ name, arguments });

        // The host reads a bounded line. Sending more would have it drop
        // the connection with nothing said, so refuse here where there is
        // still somebody to tell.
        if (request.len + 1 > max_request_bytes) {
            return writeToolError(out, id, aa, "that call is too large to send");
        }

        const reply = host.call(request) catch |err| {
            return writeToolError(out, id, aa, switch (err) {
                error.EndOfStream => "ghostty closed the connection",
                else => "could not reach ghostty",
            });
        };

        // Pass the host's answer through as text. Agents read this, and the
        // host already phrases its failures for them.
        try writeResult(out, id, aa, try std.fmt.allocPrint(aa,
            \\{{"content":[{{"type":"text","text":{f}}}],"isError":{}}}
        , .{
            std.json.fmt(reply, .{}),
            std.mem.indexOf(u8, reply, "\"ok\":false") != null,
        }));
        return;
    }

    try writeError(out, id, aa, -32601, "method not found");
}

fn writeResult(
    out: *std.Io.Writer,
    id: std.json.Value,
    aa: Allocator,
    result: []const u8,
) !void {
    _ = aa;
    try out.print(
        \\{{"jsonrpc":"2.0","id":{f},"result":{s}}}
    ++ "\n", .{ std.json.fmt(id, .{}), result });
    try out.flush();
}

fn writeError(
    out: *std.Io.Writer,
    id: std.json.Value,
    aa: Allocator,
    code: i32,
    message: []const u8,
) !void {
    _ = aa;
    try out.print(
        \\{{"jsonrpc":"2.0","id":{f},"error":{{"code":{d},"message":{f}}}}}
    ++ "\n", .{ std.json.fmt(id, .{}), code, std.json.fmt(message, .{}) });
    try out.flush();
}

/// A tool failure is a *successful* JSON-RPC reply carrying `isError`, not a
/// protocol error. Getting this backwards makes clients treat a refused
/// action as a broken server.
fn writeToolError(
    out: *std.Io.Writer,
    id: std.json.Value,
    aa: Allocator,
    message: []const u8,
) !void {
    const body = try std.fmt.allocPrint(aa,
        \\{{"content":[{{"type":"text","text":{f}}}],"isError":true}}
    , .{std.json.fmt(message, .{})});
    try writeResult(out, id, aa, body);
}

test {
    // Nothing here runs without a socket and an agent on the other end, so
    // without this the whole file would go unchecked.
    std.testing.refAllDecls(@This());
}

test "the tool list matches the host's method names" {
    const rpc = @import("../poltergeist/rpc.zig");

    // A tool the host does not know is a tool that fails at the worst
    // possible moment: after an agent has decided to use it.
    for (tools) |t| {
        try std.testing.expect(
            std.meta.stringToEnum(rpc.Method, t.name) != null,
        );
    }

    // And every host method is offered, so nothing is silently unreachable.
    for (std.enums.values(rpc.Method)) |m| {
        var found = false;
        for (tools) |t| {
            if (std.mem.eql(u8, t.name, @tagName(m))) found = true;
        }
        try std.testing.expect(found);
    }
}

test "every parameter a schema advertises is one the parser accepts" {
    const rpc = @import("../poltergeist/rpc.zig");

    // The parser now refuses a parameter the method does not know, which
    // is what makes a misspelled key an error instead of a different call.
    // That guard is only safe if the names it permits are the names the
    // schemas hand out -- otherwise every correct request looks misspelled.
    //
    // The mismatch this exists for was real: `plugin_configure` advertised
    // `enabled` while the payload field was `enable`, so switching a plugin
    // on became BadParams the moment the guard went in. One test happened
    // to cover it. This covers all of them, which is the difference between
    // finding out now and finding out from a user.
    for (tools) |t| {
        const method = std.meta.stringToEnum(rpc.Method, t.name).?;

        // Pull the property names out of the schema's `"properties":{...}`.
        // Reading the schema rather than a second list of names, because a
        // second list is the thing that drifts.
        const props_at = std.mem.indexOf(u8, t.schema, "\"properties\":{") orelse continue;
        var rest = t.schema[props_at + "\"properties\":{".len ..];

        while (std.mem.indexOfScalar(u8, rest, '"')) |open| {
            const after = rest[open + 1 ..];
            const close = std.mem.indexOfScalar(u8, after, '"') orelse break;
            const name = after[0..close];

            // Only the keys at the top of `properties`, which are followed
            // by `:{`. Anything else is inside one property's own object.
            const tail = after[close + 1 ..];
            if (tail.len >= 2 and tail[0] == ':' and tail[1] == '{') {
                try std.testing.expect(fieldOf(rpc.Request, method, name));

                // Skip that property's body so its own keys ("type",
                // "description") are not read as parameter names.
                const depth_end = std.mem.indexOfScalar(u8, tail, '}') orelse break;
                rest = tail[depth_end + 1 ..];
                continue;
            }
            rest = tail;
        }
    }
}

/// Whether `name` is a field of this method's payload.
fn fieldOf(comptime Req: type, method: anytype, name: []const u8) bool {
    switch (method) {
        inline else => |m| {
            const Payload = @FieldType(Req, @tagName(m));
            if (Payload == void) return false;
            inline for (@typeInfo(Payload).@"struct".fields) |f| {
                if (std.mem.eql(u8, f.name, name)) return true;
            }
            return false;
        },
    }
}

test "no tool offers to answer another agent's prompt" {
    // `terminal_send` is a general text primitive and that is all there is.
    // A dedicated approve/deny tool would make it one step to hand away
    // another agent's safety model (R2), so there is none -- and this is
    // the test that should object if one appears.
    //
    // Holding a terminal to its work is not offered at all: it is the
    // user's word, set from the menu, and the supervisor decides afresh on
    // every wake-up whether there is more worth doing. See `Bus.setHeld`.
    for (tools) |t| {
        try std.testing.expect(std.mem.indexOf(u8, t.name, "approve") == null);
        try std.testing.expect(std.mem.indexOf(u8, t.name, "permission") == null);
        try std.testing.expect(std.mem.indexOf(u8, t.name, "deny") == null);
    }
}

test "the tools that decide reach say so in their own description" {
    // Reach is the target's mark, not the relationship, and nobody should
    // have to infer that from being refused. Two things have to be said
    // out loud: that watching a terminal marks it (so `set_watch` is still
    // a reach decision, in the other direction -- it takes the terminal out
    // of everyone else's reach), and that the tools which touch another
    // terminal are governed by that mark.
    var seen_watch = false;
    var seen_reach = false;
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, "set_watch")) {
            seen_watch = true;
            try std.testing.expect(std.mem.indexOf(u8, t.description, "reach") != null);
        }
        for ([_][]const u8{
            "terminal_read",
            "terminal_send",
            "terminal_action",
            "terminal_key",
        }) |name| {
            if (!std.mem.eql(u8, t.name, name)) continue;
            seen_reach = true;
            try std.testing.expect(
                std.mem.indexOf(u8, t.description, "mark") != null or
                    std.mem.indexOf(u8, t.description, "reach") != null,
            );
        }
    }
    try std.testing.expect(seen_watch);
    try std.testing.expect(seen_reach);
}

test "every tool describes itself and carries a schema" {
    for (tools) |t| {
        try std.testing.expect(t.name.len > 0);
        try std.testing.expect(t.description.len > 20);
        try std.testing.expect(std.mem.startsWith(u8, t.schema, "{\"type\":\"object\""));
    }
}

test "the initialize result is valid JSON and puts the tool families in it" {
    // `instructions` is prose living inside a JSON string literal, so one
    // unescaped newline or quote costs the whole handshake -- and it would
    // cost it at runtime, on a client we do not control, with no compile
    // error anywhere. Parse the real bytes.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        initialize_result,
        .{},
    );
    defer parsed.deinit();

    const text = parsed.value.object.get("instructions").?.string;

    // The map is only worth having if every family is named. `task_` is the
    // one this exists for: it is the family that went missing.
    for ([_][]const u8{
        "terminal_send", "terminal_read", "group_post",
        "task_create",   "task_assign",   "task_list",
        "skill_read",
    }) |name| {
        std.testing.expect(std.mem.indexOf(u8, text, name) != null) catch |err| {
            std.debug.print("instructions never names {s}\n", .{name});
            return err;
        };
    }

    // Prose, not a bare list: the four steps are the part that failed.
    try std.testing.expect(std.mem.indexOf(u8, text, "\n") != null);
}
