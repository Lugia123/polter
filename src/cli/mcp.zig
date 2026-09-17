const std = @import("std");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const args = @import("args.zig");
const global = @import("../global.zig");
const transport = @import("../poltergeist/transport.zig");
const poltergeist_server = @import("../poltergeist/Server.zig");

const log = std.log.scoped(.mcp);

/// MCP protocol revision this speaks. Sent back in `initialize`.
const protocol_version = "2024-11-05";

/// What every client is told at `initialize`, before it asks for anything.
///
/// MCP puts this in the connecting agent's system prompt, which is the one
/// place a compaction does not reach -- so unlike anything injected into the
/// conversation, it does not need replaying.
///
/// It is a map of the tool families, the two jobs they serve, and an index
/// from situation to tool. It exists because of two observed failures, and
/// carries a part for each.
///
/// The map is there because a supervisor opened its night by writing out a
/// tool list from memory of what it used yesterday, and `task_*` was not on
/// it. Every later decision was then made without the panel on the table --
/// not chosen against, never present. A skill cannot catch that, because the
/// narrowing happens before anything gets read. See dev-docs/poltergeist/tasks.md.
///
/// The index is there because knowing a tool exists is not the same as
/// noticing you are standing in the situation it is for. A list answers
/// "what is there"; every step an agent takes asks "what does this moment
/// want", and nothing here used to answer that question in those terms.
///
/// Running your own work in a tab is stated first because it was missing
/// entirely: every line here used to be about minding other agents, so an
/// agent with no one to supervise read the whole note as somebody else's
/// business and never learned it could put a dev server on the screen.
const instructions =
    "Polter is the terminal multiplexer you are running inside. It gives you four\\n" ++
    "families of tools. tools/list has all of them, but narrowing your own tool set\\n" ++
    "down to the ones you used yesterday is the way they get missed, so this is the\\n" ++
    "whole map, stated before you choose.\\n" ++
    "\\n" ++
    "terminal_* -- see and drive any Polter terminal you may reach. terminal_list,\\n" ++
    "terminal_read, terminal_send, terminal_key, terminal_action, terminal_open.\\n" ++
    "terminal_layout puts a tab's panes into a shape you say once, and is the\\n" ++
    "only one that tells you which panes it made -- splitting cannot.\\n" ++
    "terminal_keys and terminal_actions catalogue what can be sent.\\n" ++
    "\\n" ++
    "group_* -- the group chat. For talking and for the record, not for directing:\\n" ++
    "a terminal somebody is minding is never interrupted by a group post, so a post\\n" ++
    "on its own moves nobody. group_create, group_add, group_post, group_read.\\n" ++
    "\\n" ++
    "task_* -- the task panel. This is how work is handed out, and it is the part\\n" ++
    "that survives a restart, a compaction, and the night. A supervisor uses\\n" ++
    "task_create, task_edit, task_assign, task_close, task_cancel -- task_edit is\\n" ++
    "how a title that has stopped being true gets corrected without changing the\\n" ++
    "number every earlier message named. Anyone uses task_progress\\n" ++
    "on their own work, task_list to see where it stands, and task_history to see\\n" ++
    "when it got there -- which is the one that answers what happened overnight.\\n" ++
    "\\n" ++
    "me says who you are and what you may reach. skill_read has the full guidance,\\n" ++
    "in three parts: supervising, operating-a-terminal, reading-a-terminal.\\n" ++
    "\\n" ++
    "Those tools serve two jobs. The second is the one that gets forgotten.\\n" ++
    "\\n" ++
    "Running your own work in a terminal. A tab is somewhere you can put a command\\n" ++
    "where the person can see it. terminal_open makes one in a directory you name,\\n" ++
    "terminal_send types into it, terminal_read shows what came back. No other agent\\n" ++
    "is involved in any of that. It is how you run a dev server or a watcher that has\\n" ++
    "to keep running while you carry on working, tail a log, or drive a program that\\n" ++
    "will not go into the background because it wants a terminal. What it gets you\\n" ++
    "over a backgrounded process is that the output stays on screen: the user comes\\n" ++
    "back to it, sees what you saw, and can take it over by typing. A process you\\n" ++
    "backgrounded is invisible to them and dies with you.\\n" ++
    "\\n" ++
    "Minding other agents. Handing work out is four steps, and dropping the panel out\\n" ++
    "of them is the failure this note exists to prevent: task_create, then group_post\\n" ++
    "the plan for the record, then terminal_send each worker its own instruction,\\n" ++
    "then task_assign.\\n" ++
    "\\n" ++
    "Which situation you are in, and what it asks for:\\n" ++
    "\\n" ++
    "- something to run that outlives this reply -- terminal_open, then terminal_send\\n" ++
    "- a server or watcher in another tab to stop or restart -- terminal_read to see\\n" ++
    "  what it is doing, terminal_key for ctrl+c, terminal_send to start it again\\n" ++
    "- work handed to you that will take a while -- task_progress when you pick it up\\n" ++
    "- finished, or stuck -- task_progress, and group_post: what you print on your own\\n" ++
    "  screen reaches nobody, and a screen that stopped moving looks the same whether\\n" ++
    "  you finished or died\\n" ++
    "- wondering what another terminal is doing -- terminal_list, then terminal_read\\n" ++
    "- back after a restart or a compaction -- task_list, task_history\\n" ++
    "- unsure who you are or what you may touch -- me\\n" ++
    "\\n" ++
    "Operating a terminal nobody has claimed needs no standing: read, send, key and\\n" ++
    "action are open to every terminal. Arranging the work is the supervisor's --\\n" ++
    "terminal_open, the group and task tools, set_watch -- and become_supervisor is\\n" ++
    "the way in, open to any terminal that is not already being minded.\\n";

/// The whole `initialize` result, kept as one literal so the test below
/// parses the bytes that actually go out rather than a copy of them.
///
/// ⚠️ **`tools.listChanged` is a promise, and without it the notification is
/// never heard.** A persona change rewrites what this terminal may see, and
/// the way a running agent finds out is
/// `notifications/tools/list_changed`. A client that follows the spec
/// subscribes to that only for a server that advertised the capability --
/// so with `"tools":{}` here, Polter can send the notification perfectly
/// and a well-behaved client will ignore it. **"The client did not listen"
/// and "we never sent it" leave the same trace in a server log**, which is
/// why this is a literal with a test on it rather than a detail.
const initialize_result =
    \\{"protocolVersion":"
++ protocol_version ++
    \\","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"poltergeist","version":"0"},"instructions":"
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
/// steer the other terminals a Polter supervisor is watching.
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
        return complain(io, "GHOSTTY_POLTER_SOCKET");

    const token = opts.token orelse
        env.get("GHOSTTY_POLTER_TOKEN") orelse
        return complain(io, "GHOSTTY_POLTER_TOKEN");

    var host: Host = try .connect(alloc, io, socket_path, token);
    defer host.deinit();

    return serve(alloc, io, &host, socket_path, token);
}

/// Say why this will not start, where whoever ran it will see it.
///
/// # Why not `log.err`, which is what this was
///
/// Both lines below used to be `log.err`, and `GHOSTTY_LOG` is unset for
/// almost everybody who will ever hit them. The measured result of running
/// `+mcp` outside Polter was **exit 1, stdout 0 bytes, and not one word about
/// why** -- an MCP client shows its user `MCP server(s) failed to start` and
/// there is nothing anywhere to add to it.
///
/// **A diagnostic that was written and then thrown away costs more than none**,
/// because its author believes the user has been told.
///
/// # `chat.zig::complain` is the precedent, and it is a deliberate citation
///
/// The sibling action solved this first and wrote down the incident with it:
/// *"a `log.err` here is a terminal that closes after a tenth of a second
/// having said nothing at all, which is exactly how this was first reported."*
/// **Same path, same lesson, one file over, and this file did not get it.**
/// Naming it here is not courtesy: when somebody meets this a third time, two
/// call sites doing it the same way are what makes the answer findable.
///
/// # stderr, and never stdout
///
/// **`+mcp` speaks JSON-RPC over stdout.** A diagnostic printed there does not
/// help the user, it corrupts the protocol stream -- trading a silent failure
/// for one that is harder to diagnose. The host says the same thing about the
/// banner it removed: *"a banner printed onto the stdout that a `+mcp` server
/// speaks its protocol over"*. So this is stderr, and it stays stderr.
fn complain(io: std.Io, missing: []const u8) u8 {
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.File = .stderr();
    var writer = stderr.writerStreaming(io, &buffer);

    writer.interface.print(
        \\Polter: no {s} in this terminal, so there is nothing to steer.
        \\
        \\`+mcp` is not run by hand: it is started by an agent CLI from inside
        \\a Polter terminal, and it finds that terminal through the agent
        \\socket, which is off by default. Put this in
        \\$XDG_CONFIG_HOME/polter/config.polter and restart Polter:
        \\
        \\    poltergeist-mcp = true
        \\
    , .{missing}) catch return 1;
    writer.end() catch {};

    // **Still 1, and that half was never the defect.** It did fail, and an MCP
    // client reads a non-zero exit as "the server did not start". What is
    // being removed here is the silence, not the code.
    return 1;
}

/// The connection back to Ghostty.
///
/// **`pub` because `cli/mcp_slot.zig` connects the same way.** A slot needs
/// the identical handshake -- same socket, same token, same three refusals
/// spelled out on stderr -- and a second copy of it would be a second place
/// for those sentences to drift out of step with the server's constants.
pub const Host = struct {
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
    pub fn connect(
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
        // **The third one on this path, and the worst of them.** Before this
        // the server closed a refused connection without a word, so the
        // measured result was `CONNECTION_CLOSED` in the agent CLI and
        // `+mcp failed: EndOfStream` in a log file the user has no reason to
        // know about -- and then *every terminal opened afterwards* behaved
        // the same way, with nothing anywhere naming the cause. It took
        // reading a constant out of the source to find out.
        //
        // The code is matched, not the sentence: `server.full_refusal_code`
        // is the contract and the sentence for the person is written here,
        // where it can be about what to do rather than about a slot table.
        //
        // ⚠️ **It has two readers, and it used to be written for one.** This
        // file is the handshake for `+mcp` *and* for every `+mcp-slot`, so
        // the person reading this may be looking at a terminal whose agent
        // failed to start, or at one whose upstream never came up. The old
        // wording said "every slot is held by an agent CLI" and offered one
        // remedy, "close a terminal running an agent" -- and under
        // `K x (2 + M)` the connections that actually ran out are more
        // likely to be slot processes than agents, so for half its readers
        // that sentence **named the wrong thing and pointed at the wrong
        // action**.
        //
        // What it still cannot do is say *how many* of them are agents and
        // how many are slots: the server counts connections, and nothing in
        // the handshake says which kind a connection is. Printing a split we
        // have not got would be an inference formatted as a reading. The
        // arithmetic below is the honest version -- it tells the person how
        // to work the number out from what they can see.
        if (std.mem.indexOf(u8, reply, poltergeist_server.full_refusal_code) != null) {
            var buffer: [512]u8 = undefined;
            var stderr: std.Io.File = .stderr();
            var w = stderr.writerStreaming(io, &buffer);
            w.interface.print(
                \\Polter has no free connection on this socket, so this
                \\terminal gets no tools.
                \\
                \\Every connection is held by something that is still running,
                \\and there are two kinds of holder -- this message cannot say
                \\which one ran out, because both of them arrive through here.
                \\An agent CLI holds two: one to ask with, and one parked
                \\waiting to be told its tools changed. Each upstream MCP
                \\server you have handed to Polter holds one more, in every
                \\terminal -- so a terminal with N of them accounts for 2 + N.
                \\
                \\Nothing has leaked; there are simply that many. Any of three
                \\will do: close a terminal that is running an agent, hand
                \\fewer upstreams to Polter, or raise `poltergeist-max-agents`
                \\in $XDG_CONFIG_HOME/polter/config.polter and restart Polter.
                \\
            , .{}) catch {};
            w.end() catch {};
            return error.AgentsFull;
        }

        if (std.mem.indexOf(u8, reply, "\"ok\":true") == null) {
            // **The second one on this path, and it was just as invisible.**
            // Found by asking judgement 5 -- "how many more `log.err` can a
            // user reach while `GHOSTTY_LOG` is unset" -- rather than by
            // noticing it. A stale or mismatched token fails at startup
            // exactly like a missing one, and said nothing for the same
            // reason. stderr for `complain`'s reason: stdout is the protocol.
            var buffer: [256]u8 = undefined;
            var stderr: std.Io.File = .stderr();
            var w = stderr.writerStreaming(io, &buffer);
            w.interface.print(
                \\Polter refused this terminal's token.
                \\
                \\The token is issued per terminal and does not outlive it, so
                \\this is what a stale one looks like: start the agent CLI from
                \\the Polter terminal it should be steering.
                \\
            , .{}) catch {};
            w.end() catch {};
            return error.AuthFailed;
        }

        return self;
    }

    pub fn deinit(self: *Host) void {
        self.stream.close(self.io);
        self.alloc.free(self.read_buf);
        self.alloc.free(self.write_buf);
        self.* = undefined;
    }

    /// Send one request line and return the reply line. The reply borrows
    /// the read buffer and is valid until the next call.
    pub fn call(self: *Host, line: []const u8) ![]const u8 {
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
/// work or letting one go; see that file for why that one will not be added.
///
/// ⚠️ **The other half of that sentence used to say the same about answering
/// another agent's permission prompt, and it stopped being true.**
/// `terminal_answer_prompt` is eight lines below. `rpc.zig` keeps both halves
/// of the reversal on the request itself; what matters here is that a
/// description which states a permanent refusal goes on being read as one
/// long after the refusal is gone.
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
        .description = "Every terminal Polter knows about, and enough about each to tell them apart: `cwd` and `title` say which terminal this actually is, `role` and `shielded` say whether a call of yours will reach it, `held` says the user is holding it to its work. For a terminal somebody is watching there is also `quiet_ms` and `rounds` -- how long its screen has been unchanged, and how many times that has been reported. **`quiet_ms` is absent rather than zero for a terminal nobody is watching**: nothing samples it, and zero would read as busy this instant. `window` and `tab` say **where** it is: two terminals are in the same window when their `window` values are equal, and in the same tab when their `tab` values are. That is the only thing those numbers mean -- they are not handles, nothing can be looked up by them, and they change every restart. Use them instead of guessing from `cwd` and `title` which terminals the user split out of one tab. ⚠️ **Absent means nobody said, not \"they are apart\"**: the interface has to be asked this question and not every one answers it -- on Linux none of them do, so both are absent for every terminal there. Reading absence as separate windows invents an arrangement. Durations and bookkeeping only -- call terminal_read to see what is on a screen.",
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "notices",
        .description = "What has happened that you have not been shown yet: which terminals went quiet and for how long, and which came back to work. The same line can carry one clause about a group you supervise -- a task nothing has happened to for a long time, a conversation that has stopped, a task handed round three times -- each with its duration and no verdict attached, because none of those is by itself a problem. Reading clears them, so what comes back will not come back again. You are also handed this on a timer; call it yourself whenever you finish something, rather than waiting to be interrupted. An empty answer means nothing is waiting. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "notify_user",
        .description = "Ask for the person to be told something. Use `reason: authorisation` when a terminal is stopped on a permission prompt -- those go out at any hour, because the terminal is stopped until somebody answers and that somebody may have to be the user. (You may be able to answer it yourself with terminal_answer_prompt; that depends on a per-terminal switch only the user can set.) Use `reason: scheduling` for questions you could answer yourself (keep going, change tack, give up); those are held back during the hours the user set aside, and handed back to you to decide. **Read the reply**: it says whether the message actually went anywhere. If it did not, do not sit waiting for an answer. Supervisor only.",
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
        .description = "Say what a group is for, in your own words. Write this right after creating a group, while you still know why you made it -- in eight hours group_list will show you a name you no longer recognise, and that is exactly when you have to decide whether it still needs watching. **Everyone in the group reads this**, so it is also where a round's terms belong -- what the work is, what is off limits, where to put the artefacts. Writing to a group you are in is still yours alone. Supervisor only.",
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
        .description = "**Use this to find out what another terminal is doing** -- what " ++
            "your dev server last printed, whether a build finished, whether an agent is " ++
            "waiting on a prompt. It reads the visible screen. Scrollback is not " ++
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
        .description = "**Use this to start something running in another terminal, or " ++
            "to answer a prompt one is sitting on.** It types text into that terminal, " ++
            "exactly as the user would. " ++
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
        .name = "persona_face",
        .description = "Which of Polter's tools you may see right now, and the version of that answer. About **you**: there is no way to ask what some other terminal is allowed to do. Worth calling when a reply says a tool does not exist and you were sure it did -- the user can change what a terminal is holding while it runs, and what you were told at the start is not a promise about now.",
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "skill_read",
        .description = "Read one of Polter's skills: how to supervise, how to operate another terminal, or how to read one. Start with `supervising` if you are minding terminals and `operating-a-terminal` if you are not.",
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
        .description = "Which groups there are. A worker is shown the ones it is in. A supervisor is shown all of them, each with its note and with `joined: false` on any it is not a member of -- which is what a restart leaves: groups come back from disk with their names and notes intact and nobody in them, because deciding which terminal on screen now is which one from last night is a judgement and Polter does not make it. So an empty-looking list after a restart is not a lost night; a `joined: false` group is one to rejoin with group_add, not to rebuild with group_create -- its task panel is still behind it.",
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "group_post",
        .description = "**Use this when you have finished something, got stuck, or " ++
            "found something the others need** -- what you print on your own screen " ++
            "reaches nobody, so a result that was only printed was never delivered. " ++
            "It says something to a group you are in. The others are told they have a " ++
            "message; they read it when they choose to.",
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
        .description = "Read further back in a group than it still holds, out of the log on disk. `group_read` hands you what is current; this hands you what came before it -- including everything a `group_compact` replaced, which is gone from the group itself but never from the record. Page with `log_seq`: pass the smallest one you have seen as `before_seq` and you get the batch before that. `more: false` means you have reached the beginning of what was kept. The per-group `seq` is 0 here -- the log does not record it. **Prefer `match` and the two clocks to paging.** Reading a night back one screenful at a time to find one sentence spends exactly the context a compaction was meant to save: `match` is a substring of the message text with ASCII case ignored, `since_ms` and `until_ms` bound it by wall clock (since includes its instant, until excludes it). They compose, and a day outside the range is not even opened.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"before_seq":{"type":"integer"},"limit":{"type":"integer"},"since_ms":{"type":"integer","description":"Wall-clock ms; only messages at or after this"},"until_ms":{"type":"integer","description":"Wall-clock ms; only messages before this"},"match":{"type":"string","description":"Substring of the message text, ASCII case ignored"}},"required":["group"]}
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
        .description = "**Reach for this when you have something to run that outlives " ++
            "this reply** -- a dev server, a watcher, a build, a log to tail, or a " ++
            "program that will not go into the background because it wants a terminal. " ++
            "It opens a terminal in this window, starting in a directory you " ++
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
            "**When it is an agent, start it in a mode that can run unattended** " ++
            "-- an auto mode, off by default in most CLIs. A worker stopped on a " ++
            "permission prompt stays stopped until somebody answers it, and " ++
            "whether that somebody can be you is the user's call, one terminal at " ++
            "a time: terminal_answer_prompt is refused with `AuthoriseOff` until " ++
            "they switch it on from that terminal's own right-click menu, and nothing you " ++
            "can call switches it on. With it off, the keys that answer a box " ++
            "(return, the arrows, tab) are refused at that terminal too. " ++
            "terminal_send is not behind that switch -- but it types text and " ++
            "cannot press return, because the paste path it uses turns every " ++
            "control byte into a space, and it is an ordinary logged call like any " ++
            "other rather than a way round anything. So starting the worker in a " ++
            "mode that does not stop is still what saves a night. " ++
            "Until something is running, that terminal has no bracketed paste, " ++
            "so the first send must be a single line. Supervisor only.\n\n" ++
            "**`place` says what you want, never where.** There is no way to name a " ++
            "pane or a position here, and that is deliberate: where a worker lands is " ++
            "decided in one place rather than recomputed by every supervisor. " ++
            "`auto` is the default and is what you want unless you have a reason -- " ++
            "it puts the terminal beside you while there is room in your tab, and in " ++
            "a new tab once there is not. ⚠️ **Not passing `place` means `auto`, not " ++
            "`tab`**: if you need a terminal that is *not* in with the others -- a long " ++
            "build whose scrollback should not share a screen, something the person " ++
            "will want on its own -- you have to ask for `tab`, and asking for it is a " ++
            "guarantee rather than a preference. `here` is the opposite request: a " ++
            "split in your own tab, which falls back to a tab when there is no room " ++
            "and says so in the log.",
        .schema =
        \\{"type":"object","properties":{"cwd":{"type":"string"},"watch":{"type":"boolean","description":"Defaults to false"},"place":{"type":"string","enum":["auto","tab","here"],"description":"Defaults to auto: beside you while there is room, a new tab once there is not. tab is a guarantee of its own tab; here asks for a split in your tab."}},"required":["cwd"]}
        ,
    },
    .{
        .name = "terminal_action",
        .description = "Do to a terminal what the menu bar does. `action` is a Polter " ++
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
        .description = "**Use this to interrupt or stop something running in another " ++
            "terminal** -- ctrl+c the server you are about to restart. It presses a key " ++
            "there, as if the person at the " ++
            "keyboard had. `key` is a Polter keybinding trigger, written exactly as a " ++
            "config file writes one: `ctrl+c`, `escape`, `ctrl+z`, `ctrl+shift+k`, " ++
            "`f2`, `arrow_down`. This is how you interrupt something -- terminal_send " ++
            "cannot, because the text it types has its control characters stripped on " ++
            "the way in. Ordinary characters are refused here for the same reason in " ++
            "reverse: `a` is text and belongs in terminal_send. **`tab` and `shift+tab` " ++
            "are keys here, not text** -- they are how an agent CLI is put into " ++
            "unattended mode, and no amount of text can carry shift+tab, so if you " ++
            "started a worker without its unattended flag this is how you fix it " ++
            "afterwards. Call terminal_keys for " ++
            "the vocabulary. Same reach rule as terminal_read.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"},"key":{"type":"string"}},"required":["id","key"]}
        ,
    },
    .{
        .name = "terminal_answer_prompt",
        .description = "Answer a permission prompt that has stopped another terminal -- " ++
            "the `Do you want to proceed? 1. Yes / 2. Yes, and don't ask again / 3. No` " ++
            "box a worker sits on until somebody answers it. **Off for every terminal " ++
            "until the user switches it on for that one**, from that terminal's own " ++
            "right-click menu; nothing you can call switches it on, and asking again " ++
            "will not " ++
            "change it. With it off you get `AuthoriseOff`, and the right move is to " ++
            "say which terminal is stopped and let the person answer -- that is what " ++
            "this program did for every terminal before the switch existed. `choice` " ++
            "counts the options from the highlighted one, starting at 1, and defaults " ++
            "to 1: it walks down with the arrow keys and presses return, so **read the " ++
            "terminal first** -- a wrong count takes a different option and reports " ++
            "success. ⚠️ Note what the switch covers: with it off, this tool and the " ++
            "keys that answer a box (return, the arrows, tab) are refused at that " ++
            "terminal, while ctrl+c and escape still go through. Same reach rule as " ++
            "terminal_read. Never at your own terminal: your own prompt is yours.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"},"choice":{"type":"integer"}},"required":["id"]}
        ,
    },
    .{
        .name = "terminal_layout",
        .description = "Rearrange a tab's panes into a shape you give in one call. **Use this " ++
            "instead of splitting four times.** Each terminal_action split is a round trip " ++
            "against a layout that is still moving, and none of them tells you which pane it " ++
            "just made -- so splitting repeatedly gives you a chain, not the shape you wanted. " ++
            "`id` names any pane of the tab. `layout` is a tree: a cell is " ++
            "{\"pane\":\"0x…\"} for a terminal already in that tab, {\"new\":{\"cwd\":\"…\"}} " ++
            "for one to make, or {\"split\":\"h\"|\"v\",\"ratio\":0.5,\"left\":cell,\"right\":cell}. " ++
            "`ratio` is the fraction given to `left` and must be between 0 and 1; it is refused " ++
            "rather than rounded, because a layout you did not ask for reported as success is " ++
            "worse than a refusal. **The reply gives the resulting shape with every cell's terminal " ++
            "id**, including the ones that were just made -- the same ids you can hand " ++
            "straight to terminal_read and terminal_send, which is how you learn them. " ++
            "⚠️ Every pane already in the tab must appear in the layout: rearranging never " ++
            "closes a terminal. Leave one out and the whole call is refused and nothing moves; " ++
            "close it first with terminal_action close_surface, then send the layout for what " ++
            "is left. ⚠️ It is all-or-nothing: if any cell is wrong, no pane is touched. " ++
            "⚠️ On Linux this answers `Unsupported` and changes nothing. " ++
            "⚠️ It returns only after that window's queued work has run, so anything queued " ++
            "before it has happened too. Supervisor only. Same reach rule as terminal_read.",
        .schema =
        \\{"type":"object","properties":{"id":{"type":"string"},"layout":{"type":"object"}},"required":["id","layout"],"additionalProperties":false}
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
            "that needs somebody co-ordinating it and nobody is. **Also the way in when " ++
            "a tool you want is a supervisor's** -- terminal_open, the group and task " ++
            "tools, set_watch -- so if you were refused for standing rather than reach, " ++
            "this is the call that was missing, not a dead end. Takes no arguments: " ++
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
        .description = "Put a piece of work on a group's panel: one line saying what it is, and what kind of work it is. It answers with a task number. The panel is what survives the night -- an instruction you typed into a terminal has scrolled out of that agent's context by 3am, and so has your memory of sending it. Keep the title to a line; the acceptance test and the detail go in the message you send the worker, not here. `kind` is required and has no default: feature, bug, research or other. A default would make everything one value inside a fortnight and sort nothing, which is what a panel read by eye at 3am cannot afford. Tasks made before the field existed read as \"unset\" and cannot be asked for -- that value means \"older than the question\", which is how they stay findable. Got the title or the kind wrong? task_edit fixes either without changing the number. Supervisor only, and only in a group you made.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"title":{"type":"string","description":"One line. Not the requirement, just what it is."},"kind":{"type":"string","enum":["feature","bug","research","other"],"description":"Required. What kind of work this is."}},"required":["group","title","kind"],"additionalProperties":false}
        ,
    },
    .{
        .name = "task_edit",
        .description = "Correct a task that is already on the panel: its title, its kind, or both. **The number does not change**, which is the point -- every message that already named it still names the same piece of work. Use it when a title has stopped being true: a sentence written when something was so stays on the panel misleading everybody who reads it afterwards, and until this existed the only remedy was to cancel and re-create, which renumbers the thing every earlier message refers to. Give only what you are changing; the rest is left alone. **It is recorded**: task_history shows the change as `edited`, so the panel stays a written record rather than a whiteboard. ⚠️ What it cannot do is reach messages already sent quoting the old title -- those still say what they said, and the history is where the two are reconciled. Supervisor only.",
        .schema =
        \\{"type":"object","properties":{"task":{"type":"integer"},"title":{"type":"string","description":"The new one line. Omit to leave it alone."},"kind":{"type":"string","enum":["feature","bug","research","other"],"description":"Omit to leave it alone."}},"required":["task"],"additionalProperties":false}
        ,
    },
    .{
        .name = "task_assign",
        .description = "Say which terminal is doing a task. **A line is typed into that terminal saying the task is theirs, and only then does the panel record it** -- an assignment nobody was told about is one only you can see, and the group cannot carry it because a terminal you are minding is not woken by a post. **Read the reply**: it says whether the terminal was actually told, and if it could not be, nothing was assigned. The line names the task and tells the worker to report with task_progress when it finishes or gets stuck; **what the work is is still yours to send**, because the acceptance test is the part that cannot be generated. Pass id 0 to take it back off somebody without cancelling it; there is nobody to tell, so nothing is typed. Supervisor only.",
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
        .description = "**Call this when you pick a task up, when you get stuck, and " ++
            "when you are done** -- a screen that has stopped moving looks the same " ++
            "whether you finished or died, so a supervisor learns which one it was from " ++
            "here and nowhere else. It moves one of your own tasks along: queued, working, blocked, done. Yours only, and only while it is open -- a task that was closed or cancelled refuses, which is how you find out you missed a cancellation. Set `blocked` the moment it is true; that is the one a supervisor watches for. `done` says you believe it is finished, not that it is closed -- closing is the supervisor's word after it has checked. Report in the group as well, naming the task number.",
        .schema =
        \\{"type":"object","properties":{"task":{"type":"integer"},"progress":{"type":"string","enum":["queued","working","blocked","done"]}},"required":["task","progress"],"additionalProperties":false}
        ,
    },
    .{
        .name = "task_history",
        .description = "What happened to a group's panel, out of the record on disk. task_list says where each task stands now; this says when it got there -- created, assigned, progressed, closed, cancelled, each with a timestamp. This is what answers \"what happened last night\": how long a task has sat untouched, which ones were handed to a third terminal after two gave them back, how many were closed while you were asleep. Page it the way group_history is paged: pass the smallest `seq` you have seen as `before_seq` for the batch before it, and `more: false` means you have reached the beginning. Read the numbers; do not let them read you -- a task open for two days may be stalled or may be a standing lease that is *meant* to stay open, and nothing here can tell those apart.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"before_seq":{"type":"integer"},"limit":{"type":"integer"}},"required":["group"],"additionalProperties":false}
        ,
    },
    .{
        .name = "task_list",
        .description = "The tasks in a group, newest first. What you get depends on who you are, because the two questions are different: a supervisor is handed the group's whole panel, closed and cancelled work included, and anybody else is handed its own tasks that are still open and nothing else. Not a restriction so much as the point -- what your peers are doing is not yours to spend context on. **A page, not the whole panel.** Fifty rows unless you ask for fewer or more, and `more: true` means there are older ones; page with `before`, passing the `task` number of the last row you were given. A panel that has run a few nights is thousands of characters long, and an answer nobody can hold is worse than one that says there is more. **Narrow it rather than paging through it**: `state` (open / closed / cancelled), `owner` for one terminal's, `match` for a substring of the title with ASCII case ignored. `match` is what finds the one task you half remember without reading the night back; the filters compose. Asking for a state as a worker yields nothing rather than reaching past your own view -- closed work is not a narrower version of your question, it is somebody else's question.",
        .schema =
        \\{"type":"object","properties":{"group":{"type":"string"},"limit":{"type":"integer"},"before":{"type":"integer"},"state":{"type":"string","enum":["open","closed","cancelled"]},"owner":{"type":"integer"},"match":{"type":"string"}},"required":["group"],"additionalProperties":false}
        ,
    },
};

const Tool = struct {
    name: []const u8,
    description: []const u8,
    schema: []const u8,
};

/// Everything the notifier thread and the serve loop share.
///
/// **The mutex is over stdout, and it is the whole reason this struct
/// exists.** Until now one thread owned the protocol stream; a second one
/// writing a notification into the middle of a half-written reply would
/// corrupt the stream in a way that looks, from the agent's side, like
/// Polter talking nonsense.
const Shared = struct {
    out: *std.Io.Writer,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    fn notifyToolsChanged(self: *Shared) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.out.print(
            \\{{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}}
        ++ "\n", .{}) catch return;
        self.out.flush() catch return;
    }
};

/// Sit on `persona_wait` and say so when this terminal's tools change.
///
/// ⚠️ **A second connection, not the serve one.** `Host.call` is lock-step:
/// a long poll on that connection would hold every tool call behind it for
/// as long as nothing changed, which is most of the time.
///
/// ⚠️ **It compares before it speaks.** `epoch` belongs to the whole
/// terminal, so a wait wakes when *anything* about the persona moves --
/// including a change to some other slot. Sending a notification for every
/// wake would have every agent re-list its tools every time the user
/// touched anything; the contract says to compare first and this is where
/// that is done.
fn notifier(
    alloc: Allocator,
    io: std.Io,
    socket_path: []const u8,
    token: []const u8,
    shared: *Shared,
) void {
    var host: Host = Host.connect(alloc, io, socket_path, token) catch {
        // No second connection: the terminal keeps working, it just will
        // not hear about a change until it lists its tools for some other
        // reason. Quiet on purpose -- stdout is the protocol and stderr
        // here would be a line the user cannot act on.
        return;
    };
    defer host.deinit();

    var epoch: u64 = 0;
    var last: ?[]const u8 = null;
    defer if (last) |l| alloc.free(l);

    while (true) {
        const started: std.Io.Timestamp = .now(io, .awake);

        var buf: [256]u8 = undefined;
        const request = std.fmt.bufPrint(
            &buf,
            \\{{"method":"persona_wait","params":{{"slot":"","epoch":{d}}}}}
        ,
            .{epoch},
        ) catch return;

        const reply = host.call(request) catch return;

        // The reply borrows the host's read buffer, which the next call
        // reuses. Anything compared across iterations has to be copied.
        const next = alloc.dupe(u8, reply) catch return;
        var changed = true;
        if (last) |l| changed = !std.mem.eql(u8, l, next);
        if (last) |l| alloc.free(l);
        last = next;

        epoch = epochOf(alloc, next) orelse epoch;
        if (changed) shared.notifyToolsChanged();

        // ⚠️ **The floor, and it is permanent.** The host is supposed to
        // hold this request until something moves, but a host that does not
        // -- a test host, an embedder, any implementation that has not
        // wired the parking up -- answers at once, and then this loop is
        // not polling, it is spinning as fast as the socket allows. There
        // is one of these processes per terminal, so the cost is
        // multiplied by everything the user has open.
        //
        // **It is not something to remove once the server does park.** What
        // it guards against is the server *not* parking, which is a
        // condition that never stops being possible. A real change does not
        // come through here -- it wakes the parked request -- so this costs
        // nothing on the path that matters.
        const spent_ms: u64 = @intCast(std.math.clamp(
            started.durationTo(.now(io, .awake)).toMilliseconds(),
            0,
            std.math.maxInt(i64),
        ));
        if (spent_ms < min_wait_ms) {
            std.Io.sleep(
                io,
                .fromMilliseconds(@intCast(min_wait_ms - spent_ms)),
                .awake,
            ) catch return;
        }
    }
}

/// The shortest a `persona_wait` round trip may take before the next one is
/// sent. See the floor above.
const min_wait_ms: u64 = 250;

/// Pull `epoch` out of a reply, or null if it is not there.
fn epochOf(alloc: Allocator, reply: []const u8) ?u64 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const v = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        reply,
        .{},
    ) catch return null;
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get("epoch") orelse return null) {
        .integer => |i| if (i < 0) null else @intCast(i),
        else => null,
    };
}

fn serve(
    alloc: Allocator,
    io: std.Io,
    host: *Host,
    socket_path: []const u8,
    token: []const u8,
) !u8 {
    var in_buf: [max_line]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;

    var stdin: std.Io.File = .stdin();
    var stdout: std.Io.File = .stdout();
    var reader = stdin.reader(io, &in_buf);
    // **Streaming, and this one was checked rather than swept up.** It is the
    // JSON-RPC stream, and it is one long-lived writer over many replies: a
    // positional writer advances its own logical position, so it never
    // overwrote its own output. What it did overwrite was anything already in
    // the file when the process started, which only shows up when somebody
    // points `+mcp`'s stdout at a file to read the protocol back. Over a pipe
    // -- how an agent CLI actually runs it -- the two are byte for byte alike.
    var writer = stdout.writerStreaming(io, &out_buf);

    var shared: Shared = .{ .out = &writer.interface, .io = io };

    // Detached: it lives as long as this process does, and there is nothing
    // to join -- when stdin closes the process is on its way out anyway.
    if (std.Thread.spawn(.{}, notifier, .{ alloc, io, socket_path, token, &shared })) |t| {
        t.detach();
    } else |err| {
        // Same reasoning as a failed second connection: this terminal still
        // works, it just will not be told about a change as it happens.
        log.warn("mcp: could not start the persona notifier err={}", .{err});
    }

    while (true) {
        // A null line is end of stdin: the client closed, so we are done.
        const line = (try reader.interface.takeDelimiter('\n')) orelse return 0;
        if (line.len == 0) continue;

        {
            // The notifier may write between replies, never inside one.
            shared.mutex.lockUncancelable(io);
            defer shared.mutex.unlock(io);

            handleOne(alloc, host, &writer.interface, line) catch |err| {
                log.warn("mcp: could not handle a message err={}", .{err});
            };
        }
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
        // Ask the host which of them this terminal may see. The names come
        // back; the descriptions and schemas stay here, because they are
        // tens of kilobytes that never change and sending them over the
        // socket on every list would be paying for the same bytes forever.
        //
        // ⚠️ **A host that cannot answer means every tool stays visible,
        // and today that is the only door there is.**
        //
        // An earlier version of this comment said the real gate was on the
        // host, in `dispatch`, so that failing open here cost nothing.
        // **That was not true and was never true**: `toolVisible` has one
        // caller outside its own tests, and it is the loop a few lines from
        // here that builds this very list. `authorize` and `dispatch` do
        // not know what a persona is. A tool left in this list is a tool
        // that can be called.
        //
        // The direction is still deliberate, but the reason is smaller than
        // the one that was written down: a terminal that loses its tools
        // because one reply did not parse is a worse failure, and a more
        // common one, than a persona that goes unenforced for the length of
        // a hiccup. It is a judgement about which failure to have, **not**
        // a case of nothing being at stake.
        //
        // Enforcing on the call itself is written up as owed work in
        // `dev-docs/poltergeist/personas-contract.md`. Until it exists,
        // nothing here should be described as a convenience.
        const visible: ?[]const []const u8 = blk: {
            const reply = host.call(
                \\{"method":"persona_face"}
            ) catch break :blk null;
            break :blk parseFaceTools(aa, reply) catch break :blk null;
        };

        var body: std.Io.Writer.Allocating = .init(aa);
        defer body.deinit();
        const w = &body.writer;

        try w.writeAll("{\"tools\":[");
        var written: usize = 0;
        for (tools) |t| {
            if (visible) |names| if (!listHas(names, t.name)) continue;
            if (written > 0) try w.writeAll(",");
            written += 1;
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
                error.EndOfStream => "polter closed the connection",
                else => "could not reach polter",
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

/// Pull `tools` out of a `persona_face` reply.
///
/// Returns null rather than an error for a reply that is not what we
/// expected, because the caller treats "no answer" and "an answer I cannot
/// read" the same way: show everything. Telling them apart would be a
/// distinction with nothing behind it.
fn parseFaceTools(aa: Allocator, reply: []const u8) !?[]const []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, reply, .{}) catch
        return null;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return null,
    };
    if (obj.get("ok")) |v| switch (v) {
        .bool => |b| if (!b) return null,
        else => return null,
    };
    const arr = switch (obj.get("tools") orelse return null) {
        .array => |a| a,
        else => return null,
    };

    const out = try aa.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, i| {
        out[i] = switch (item) {
            .string => |str| str,
            else => return null,
        };
    }
    return out;
}

fn listHas(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
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
    //
    // ⚠️ **Except the ones that say they are not offered**, and the
    // exemption lives with the methods rather than here -- see
    // `rpc.offeredAsTool`. Written as a list in this file it would need a
    // second copy in `poltergeist/skill.zig`, which checks the same set
    // from the other side, and the two would drift.
    for (std.enums.values(rpc.Method)) |m| {
        var found = false;
        for (tools) |t| {
            if (std.mem.eql(u8, t.name, @tagName(m))) found = true;
        }

        if (!rpc.offeredAsTool(m)) {
            // **The exemption is checked, not trusted.** A method that
            // claims not to be offered and then appears in the table would
            // mean the two halves disagree about what an agent can reach,
            // and the table is the half that wins at runtime.
            if (found) {
                std.debug.print(
                    "{s} says it is not offered as a tool, but the table lists it\n",
                    .{@tagName(m)},
                );
                return error.ExemptButOffered;
            }
            continue;
        }

        if (!found) {
            std.debug.print("no tool is named {s}\n", .{@tagName(m)});
            return error.MethodNotOffered;
        }
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
            // Governed by the target's mark like the rest, **and by a
            // second thing of the target's**: the user's per-terminal
            // switch. A tool whose availability depends on the target has
            // to say so in its own description, because `tools/list` is
            // answered once, for the caller, with no target in the question
            // -- so the list can never carry it.
            "terminal_answer_prompt",
            "terminal_layout",
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
        "terminal_send", "terminal_read",   "group_post",
        "task_create",   "task_edit",       "task_assign",
        "task_list",     "terminal_layout", "skill_read",
    }) |name| {
        std.testing.expect(std.mem.indexOf(u8, text, name) != null) catch |err| {
            std.debug.print("instructions never names {s}\n", .{name});
            return err;
        };
    }

    // Prose, not a bare list: the four steps are the part that failed.
    try std.testing.expect(std.mem.indexOf(u8, text, "\n") != null);

    // Running your own work in a tab is the half that was missing for a
    // long time, and it is the half a rewrite drops first: everything else
    // here is about minding other agents, so prose drifts back towards
    // that on its own. `terminal_open` is how the work gets somewhere
    // visible and `become_supervisor` is the standing it needs -- an agent
    // told about the first and not the second tries it, is refused, and
    // reads a missing call as a closed door.
    for ([_][]const u8{
        "terminal_open", "become_supervisor",
    }) |name| {
        std.testing.expect(std.mem.indexOf(u8, text, name) != null) catch |err| {
            std.debug.print("instructions never names {s}\n", .{name});
            return err;
        };
    }
}

test "mcp: initialize promises listChanged, or the notification is never heard" {
    // **The assertion is on the parsed capability, not on the substring**,
    // because `"listChanged":true` appearing anywhere in the literal --
    // including inside `instructions` -- would satisfy a substring check
    // while the client reads `capabilities.tools` and finds nothing.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        initialize_result,
        .{},
    );
    defer parsed.deinit();

    const tools_cap = parsed.value.object
        .get("capabilities").?.object
        .get("tools").?.object;

    const advertised = tools_cap.get("listChanged") orelse {
        // A `.?` here would abort with "attempt to use null value", which
        // says nothing about what the terminal loses. Measured: that is
        // exactly what this printed before the sentence was added.
        std.debug.print(
            "initialize does not advertise tools.listChanged, so a " ++
                "spec-following client never subscribes and a persona " ++
                "change reaches a running agent not at all\n",
            .{},
        );
        return error.ListChangedNotAdvertised;
    };
    try std.testing.expectEqual(std.json.Value{ .bool = true }, advertised);
}
