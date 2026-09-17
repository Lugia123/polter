//! One upstream MCP server, behind one slot, exposed to one terminal.
//!
//! `dev-docs/poltergeist/roles.md` section three is the design this
//! implements, and section 3.1 is the design it deliberately is **not**: the
//! standard way to put several MCP servers behind one endpoint is to
//! aggregate them into a single virtual server and prefix the tool names to
//! avoid collisions. That was rejected on two grounds, the first decisive:
//!
//!  1. **Aggregation swallows the user's authorization in one gulp.** Every
//!     host scopes its permission rules by server (Claude Code by
//!     `mcp__<server>__*`, codex by
//!     `mcp_servers.<name>.default_tools_approval_mode`). Behind one server
//!     name, allowing Polter allows everything behind Polter. That is not a
//!     usability complaint; it flattens the user's security model.
//!  2. **Renaming makes the upstream's own documentation wrong.** Its
//!     prompts, its README and its skills all name its tools. Prefix them
//!     and every one of those sentences points at something that no longer
//!     exists.
//!
//! So: **one upstream, one slot, one server entry in the host's config.**
//! `polter:argus` is its own namespace, so nothing has to be renamed, and
//! the user still allows `argus` by itself.
//!
//! ```
//! host config                 what it reaches
//!   polter          ──────►   Polter's own tools           (`+mcp`)
//!   polter:argus    ──────►   this, then argus's server    (if the role wants it)
//!   polter:kanban   ──────►   this, and nothing else       (if it does not)
//! ```
//!
//! # The four states, and why none of them may look like another
//!
//! | state | when | what the client sees |
//! | --- | --- | --- |
//! | `transparent` | no Polter to ask, or Polter cannot answer | **everything**, byte for byte |
//! | `granted` | the role wants this slot | the upstream's tools, unrenamed |
//! | `withheld` | the role does not | an empty tool list |
//! | `broken` | the role wants it and the upstream will not run | **one tool that says so** |
//!
//! `transparent` is section 3.3, and it is required rather than nice:
//! *"用户在 Ghostty 之外直接跑 `claude`，槽位进程拿不到 socket 和 token。
//! 这时它必须原样透传上游的全部工具，否则「装了 Polter 之后我在别处的终端
//! 就少了工具」。"* It covers one more case than that sentence does -- a
//! Polter that is there and does not understand the question -- for the same
//! reason: **the failure mode of guessing wrong is taking away tools the
//! user never agreed to lose**, so anything short of a definite "no" from
//! Polter passes everything through.
//!
//! `broken` exists because of roles.md's second open question:
//! *"不要让「上游挂了」和「这个角色没有它」长得一样。"* Both would otherwise
//! be an empty tool list, and an agent meeting one would reason about the
//! other. It is the same shape as `provisioning.md` section seven's
//! `absent` / `provisioned` / `failed`: **"there is nothing to do here" and
//! "something went wrong here" must not be the same output.**
//!
//! # What is never modified
//!
//! Tool names, tool descriptions, schemas, and every byte of every result:
//! forwarded as they arrive. The **one** field this writes into is
//! `capabilities.tools.listChanged` in the upstream's `initialize` result,
//! and only while attached -- because while attached this really may send
//! that notification, and a client that was told the server does not is
//! entitled to ignore it. In `transparent` mode nothing is parsed at all,
//! let alone changed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const global = @import("../global.zig");
const mcp = @import("mcp.zig");

const log = std.log.scoped(.mcp_slot);

/// MCP protocol revision the locally-answered `initialize` claims. Same as
/// `+mcp`'s, and it is only ever used in the states where no upstream is
/// running to answer for itself.
const protocol_version = "2024-11-05";

/// Longest line either side may send. The host caps its own replies below
/// this; an upstream's tool list is the large case here.
const max_line = 1024 * 1024;

/// How long to wait before reconnecting to Polter, and the ceiling that
/// backoff climbs to.
///
/// **This is not a poll.** `persona_wait` is a long poll that Polter
/// answers when something changes, so the ordinary loop makes no timed
/// requests at all. These two numbers govern the other case: the
/// connection went away (Polter restarted, the socket went idle, every
/// agent slot filled up) and the slot has to get it back.
///
/// It backs off because `mcp.Host.connect` prints a paragraph on stderr
/// for two of its three refusals, and that paragraph is written to be read
/// once. Retrying every second turns a sentence the user needs into a wall
/// they scroll past.
const reconnect_delay_ms = 1000;
const reconnect_delay_max_ms = 30 * 1000;

/// The two methods of `personas-contract.md` section four.
///
/// `persona_slot` asks once; `persona_wait` is the long poll that answers
/// when this terminal's effective set moves. Both take the slot name as the
/// user's host config spells it after `polter:` -- **unnormalised**, for
/// the same reason a tool is not renamed: it is the word the user wrote in
/// their own authorization rule.
const method_slot = "persona_slot";
const method_wait = "persona_wait";

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// `polter +mcp-slot <slot> -- <command> [args...]`
///
/// `<slot>` is the name the role declares (roles.md 5.1: `"mcp": ["argus"]`,
/// without the `polter:` prefix). Everything after `--` is the upstream's
/// command line, carried over from the host config entry unchanged.
///
/// Like `+mcp`, this is not run by hand. The host config entry it belongs
/// in looks like:
///
///   "polter:argus": {"command": "polter",
///                    "args": ["+mcp-slot", "argus", "--", "npx", "-y", "…"]}
pub fn run(alloc: Allocator) !u8 {
    const io = global.io();

    const parsed = parseArgs(alloc) catch |err| switch (err) {
        error.NoSlotName, error.NoUpstream => return usage(io),
        else => |e| return e,
    };
    defer alloc.free(parsed.upstream);

    var env = try global.environMap();
    defer env.deinit();

    // No socket, no token, no Polter: transparent, and not a word about it
    // on stdout. See the module comment -- the user is running their agent
    // outside Ghostty and must not lose tools for having installed this.
    const socket_path = env.get("GHOSTTY_POLTER_SOCKET");
    const token = env.get("GHOSTTY_POLTER_TOKEN");

    if (socket_path == null or token == null) {
        log.info("mcp-slot: no polter in this terminal, passing {s} through", .{parsed.slot});
        return pump(alloc, io, parsed.upstream);
    }

    var link: Link = Link.open(alloc, io, socket_path.?, token.?) catch |err| {
        // **Reachable and not exceptional**: the agent slots can all be
        // taken, the token can be stale, Polter can be shutting down.
        // Every one of those is a reason to hand the upstream over whole,
        // not a reason to withhold it.
        log.warn(
            "mcp-slot: could not reach polter ({}), passing {s} through",
            .{ err, parsed.slot },
        );
        return pump(alloc, io, parsed.upstream);
    };
    defer link.close();

    // **The one question whose failure means "transparent".**
    //
    // roles.md 3.3 splits this in two, and the split is the whole guard:
    // never having had an answer is the case where passing everything
    // through is right, because nothing gives us leave to take a tool
    // away. Losing the connection *after* an answer is not that case, and
    // it is handled in `watch` -- there, the state stays put.
    const first = link.ask(parsed.slot);
    if (first.answer == .unknown) {
        log.info(
            "mcp-slot: polter did not answer persona_slot, passing {s} through",
            .{parsed.slot},
        );
        return pump(alloc, io, parsed.upstream);
    }

    var slot: Slot = try .init(alloc, io, parsed.slot, parsed.upstream, &link, first);
    defer slot.deinit();
    return slot.serve();
}

const Parsed = struct {
    slot: []const u8,
    upstream: []const []const u8,
};

/// Read `<slot> -- <command>…` out of the process arguments.
///
/// **Not `args.parse`, and not `ArgsIterator`.** The first does not take
/// positionals at all; the second silently drops any argument beginning
/// with `+`, which is how it skips the `+action` token -- and an upstream
/// command line is somebody else's argv that we have promised to carry
/// over unchanged. One `+something` in it and the upstream starts with an
/// argument missing, which is a failure that looks like the upstream being
/// broken.
fn parseArgs(alloc: Allocator) !Parsed {
    var iter: std.process.Args.Iterator = try .initAllocator(global.args(), alloc);
    defer iter.deinit();

    _ = iter.next(); // argv0

    // Skip forward to our own action token, so that this reads the same
    // whether or not anything precedes it.
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "+mcp-slot")) break;
    } else return error.NoSlotName;

    const slot = iter.next() orelse return error.NoSlotName;
    if (slot.len == 0 or slot[0] == '-') return error.NoSlotName;
    const slot_owned = try alloc.dupe(u8, slot);
    errdefer alloc.free(slot_owned);

    const sep = iter.next() orelse return error.NoUpstream;
    if (!std.mem.eql(u8, sep, "--")) return error.NoUpstream;

    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(alloc);
    while (iter.next()) |arg| try argv.append(alloc, try alloc.dupe(u8, arg));
    if (argv.items.len == 0) return error.NoUpstream;

    return .{ .slot = slot_owned, .upstream = try argv.toOwnedSlice(alloc) };
}

/// Say how to invoke this, on stderr.
///
/// **stderr and never stdout**, for the reason `cli/mcp.zig::complain`
/// gives at length: stdout is the JSON-RPC stream, and a diagnostic printed
/// there trades a silent failure for one that is harder to diagnose.
fn usage(io: std.Io) u8 {
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.File = .stderr();
    var writer = stderr.writerStreaming(io, &buffer);
    writer.interface.print(
        \\Polter: `+mcp-slot` needs a slot name and an upstream command.
        \\
        \\    polter +mcp-slot <slot> -- <command> [args...]
        \\
        \\It is not run by hand: it goes in an agent CLI's MCP config as its
        \\own server entry, one per upstream, so that the upstream keeps its
        \\own name and its own authorization.
        \\
    , .{}) catch return 1;
    writer.end() catch {};
    return 1;
}

// -- transparent -------------------------------------------------------

/// Start the upstream and copy bytes in both directions until one end
/// closes. Nothing is parsed, so nothing can be altered.
///
/// A line-oriented relay would have been the same code as the attached
/// path, and that is the argument against it: the guarantee wanted here is
/// *"装了 Polter 和没装一样"*, and a relay that reassembles frames has to be
/// read to be believed. A byte copy is the guarantee.
fn pump(alloc: Allocator, io: std.Io, argv: []const []const u8) !u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        // The upstream's own diagnostics go where the user's agent CLI puts
        // them, exactly as they would if it had been started directly.
        .stderr = .inherit,
    }) catch |err| {
        var buffer: [512]u8 = undefined;
        var stderr: std.Io.File = .stderr();
        var w = stderr.writerStreaming(io, &buffer);
        w.interface.print(
            \\Polter: could not start `{s}` ({}).
            \\
            \\That is this slot's upstream server, carried over from the MCP
            \\config entry. Polter is not involved in what it is or where it
            \\lives -- check the command in that entry.
            \\
        , .{ argv[0], err }) catch {};
        w.end() catch {};
        return 1;
    };

    var ctx: PumpCtx = .{
        .io = io,
        .from = child.stdout.?,
        .to = .stdout(),
        .alloc = alloc,
    };
    const down = std.Thread.spawn(.{}, PumpCtx.run, .{&ctx}) catch {
        _ = child.wait(io) catch {};
        return 1;
    };

    var up: PumpCtx = .{
        .io = io,
        .from = .stdin(),
        .to = child.stdin.?,
        .alloc = alloc,
    };
    up.run();

    // Our stdin closed: the agent CLI is done with this server. Closing the
    // upstream's stdin is how it is told the same thing.
    if (child.stdin) |f| {
        f.close(io);
        child.stdin = null;
    }
    down.join();
    const term = child.wait(io) catch return 0;
    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
}

const PumpCtx = struct {
    io: std.Io,
    from: std.Io.File,
    to: std.Io.File,
    alloc: Allocator,

    fn run(self: *PumpCtx) void {
        const buf = self.alloc.alloc(u8, 64 * 1024) catch return;
        defer self.alloc.free(buf);
        var reader = self.from.readerStreaming(self.io, buf);
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            const n = reader.interface.readSliceShort(&chunk) catch return;
            if (n == 0) return;
            self.to.writeStreamingAll(self.io, chunk[0..n]) catch return;
        }
    }
};

// -- the link back to Polter -------------------------------------------

/// Polter's answer to "does this terminal's role want me".
///
/// Three values and not a `bool`, because the third one is the whole point:
/// **not knowing is not the same as being told no**, and collapsing them is
/// how a slot ends up withholding an upstream on no evidence.
const Answer = enum { yes, no, unknown };

/// One reply from Polter.
const Verdict = struct {
    answer: Answer,
    /// This terminal's effective-set version. Carried even on a timeout,
    /// so that the next wait resumes from where this one left off.
    epoch: u64 = 0,
    /// The long poll ended without anything changing. **Not the same as
    /// `answer == .unknown`**: the link is healthy and the answer simply
    /// has not moved, so the caller waits again rather than reconnecting.
    timed_out: bool = false,
};

/// What Polter sends back. Parsed rather than string-matched, because
/// `epoch` is a number that has to come out as one.
const Reply = struct {
    ok: bool = false,
    wanted: ?bool = null,
    epoch: ?u64 = null,
    timeout: ?bool = null,
};

// -- what this process tells Polter it is ------------------------------
//
// **This half is not implemented yet**, and it is written down here because
// the server half is somebody else's and the two must agree. `auth` today
// is `{"method":"auth","params":{"token":"…"}}` and says nothing about who
// is calling. The proposal is a `kind` beside the token:
//
//     {"method":"auth","params":{"token":"…","kind":"slot","slot":"argus"}}
//
// Four things about it, in the order they bite.
//
// **1. `kind` is accounting, never authority.** The token decides who this
// connection is and what it may reach; `kind` decides only what Polter
// *calls* it when counting and when explaining a refusal. A slot that
// claimed `"agent"` must gain nothing by it and an agent that claimed
// `"slot"` must lose nothing. Stated because a field like this is exactly
// the sort that acquires a second job later -- and a handshake field that
// grants anything is a handshake field a caller can lie in.
//
// **2. A connection that sends no `kind` is an agent.** The slot binary and
// the host binary are normally the same build, but not always: the host
// config records an absolute path and Polter can be replaced underneath it.
// So an older `+mcp` will connect to a newer Polter saying nothing. Today
// every connection is an agent, so that is what silence has to mean --
// a third bucket called "unknown" would appear in the refusal message and
// would tell the user about our version skew instead of about their
// terminals.
//
// **3. The slot name belongs in the handshake as well as in the request.**
// It is already in argv, it costs one field, and it buys two things: the
// refusal message can name which upstreams are holding connections, and a
// later `persona_slot` asking about a *different* slot is then a detectable
// bug rather than an answered question.
//
// **4. What the reply does not need to carry.** It is tempting to fold
// `wanted` into the auth reply and save the first round trip. Not worth it:
// it is one round trip at startup, and it would couple the handshake's
// shape to the persona layer, so an older Polter's `auth` reply and a newer
// one's would differ in a place every client parses.
//
// # Two rules this file depends on that live on the server side
//
// Both are ways for the server half to be written plausibly and be wrong,
// and neither would raise anything.
//
// **A slot name no persona mentions must be answered `{"ok":true,
// "wanted":false}` -- never `{"ok":false}`.** `ok:false` is the only thing
// `interpret` reads as "no answer", and "no answer" is what turns this
// process transparent. So answering an unrecognised slot with `ok:false`
// does not withhold that upstream, it **hands the whole of it over**. The
// two replies are one word apart and opposite.
//
// **A terminal with no persona at all must be answered `wanted:true`.**
// Clearing a persona sets the effective set to the default -- which is
// today's behaviour, and today every upstream is reachable. The natural
// implementation is "is this slot in the persona's `mcp` list?", and with
// no persona that list is empty, so it answers false. That would strip
// every upstream from every terminal that has not picked a persona: on the
// day this ships, from **every** terminal. It is the single most expensive
// wrong default available here, and it is the one the obvious code writes.
//
// Related: a `shielded` terminal must be answered normally. Shielding means
// no tool may reach in and change that terminal; it does not mean the
// person sitting at it loses the servers they configured.

/// The connection to Polter, and the two questions asked over it.
///
/// **One connection, and the contract counts on that** -- 4.1 budgets each
/// slot process exactly one, on the grounds that after `persona_slot` it
/// has nothing else to ask. That holds here: nothing outside this struct
/// ever calls Polter, and the only caller is the watcher thread.
const Link = struct {
    alloc: Allocator,
    io: std.Io,
    /// Kept so the link can be rebuilt. A slot that has been told "no"
    /// must not become transparent because a socket dropped, so it has to
    /// be able to get back to the thing that told it.
    path: []const u8,
    token: []const u8,

    host: ?mcp.Host,
    /// Grows while reconnects keep failing; reset on a success.
    backoff_ms: u64 = reconnect_delay_ms,

    fn open(alloc: Allocator, io: std.Io, path: []const u8, token: []const u8) !Link {
        return .{
            .alloc = alloc,
            .io = io,
            .path = path,
            .token = token,
            .host = try .connect(alloc, io, path, token),
        };
    }

    fn close(self: *Link) void {
        if (self.host) |*h| h.deinit();
        self.host = null;
    }

    /// `persona_slot`: ask once.
    fn ask(self: *Link, slot: []const u8) Verdict {
        var buf: [512]u8 = undefined;
        const request = std.fmt.bufPrint(
            &buf,
            \\{{"method":"{s}","params":{{"slot":"{s}"}}}}
        ,
            .{ method_slot, slot },
        ) catch return .{ .answer = .unknown };
        return self.roundTrip(request);
    }

    /// `persona_wait`: block until the effective set moves, or until
    /// Polter's own timeout.
    ///
    /// An `epoch` already behind is answered immediately rather than held
    /// -- that is the contract's guard against "it changed while I was
    /// asleep", and it is why the caller must pass the epoch it last saw
    /// rather than zero.
    fn wait(self: *Link, slot: []const u8, epoch: u64) Verdict {
        var buf: [512]u8 = undefined;
        const request = std.fmt.bufPrint(
            &buf,
            \\{{"method":"{s}","params":{{"slot":"{s}","epoch":{d}}}}}
        ,
            .{ method_wait, slot, epoch },
        ) catch return .{ .answer = .unknown };
        return self.roundTrip(request);
    }

    fn roundTrip(self: *Link, request: []const u8) Verdict {
        var host = &(if (self.host) |*h| h else return .{ .answer = .unknown }).*;

        const reply = host.call(request) catch {
            // The connection is gone. **Report `unknown`, which the caller
            // turns into "keep doing what you were doing"** -- it must not
            // be read as a "no", and above all not as permission to hand
            // the upstream over.
            self.close();
            return .{ .answer = .unknown };
        };

        return interpret(self.alloc, reply);
    }

    /// Try to get the connection back, sleeping first.
    ///
    /// Returns once there is a connection again, or when `stop` goes true.
    fn reconnect(self: *Link, stop: *std.atomic.Value(bool)) void {
        while (!stop.load(.acquire)) {
            self.io.sleep(
                .fromNanoseconds(self.backoff_ms * std.time.ns_per_ms),
                .awake,
            ) catch {};
            if (stop.load(.acquire)) return;

            if (mcp.Host.connect(self.alloc, self.io, self.path, self.token)) |h| {
                self.host = h;
                self.backoff_ms = reconnect_delay_ms;
                log.info("mcp-slot: reconnected to polter", .{});
                return;
            } else |err| {
                log.warn("mcp-slot: reconnect to polter failed err={}", .{err});
                self.backoff_ms = @min(self.backoff_ms * 2, reconnect_delay_max_ms);
            }
        }
    }
};

/// Turn one line from Polter into a verdict.
///
/// **Separated from the socket so it can be tested**, because this is the
/// function where the distinction the whole file rests on would collapse:
/// `{"ok":false}` and `{"ok":true,"wanted":false}` are one character apart
/// in the source and opposite in effect. The first is Polter declining to
/// answer -- an older build, a refused request -- and must leave the slot
/// doing whatever it was doing. The second is Polter saying this
/// terminal's role does not include this upstream, and must withhold it.
///
/// A slot that read the first as the second would silently strip an
/// upstream. A slot that read the second as the first would silently hand
/// one over. Neither would log anything.
fn interpret(alloc: Allocator, reply: []const u8) Verdict {
    const parsed = std.json.parseFromSlice(Reply, alloc, reply, .{
        .ignore_unknown_fields = true,
    }) catch return .{ .answer = .unknown };
    defer parsed.deinit();
    const r = parsed.value;

    // `ok:false` is what a Polter without the persona layer answers an
    // unknown method with, and it is also what a real refusal looks like.
    // Both are "no answer", never "no".
    if (!r.ok) return .{ .answer = .unknown };

    const epoch = r.epoch orelse 0;
    if (r.timeout orelse false)
        return .{ .answer = .unknown, .epoch = epoch, .timed_out = true };

    // `ok` with neither `wanted` nor `timeout` is a reply this build does
    // not understand. Guessing either way here is the same mistake as
    // above, one level down.
    const wanted = r.wanted orelse return .{ .answer = .unknown, .epoch = epoch };
    return .{ .answer = if (wanted) .yes else .no, .epoch = epoch };
}

// -- attached ----------------------------------------------------------

const State = enum { granted, withheld, broken };

/// The upstream process and the thread draining it.
const Upstream = struct {
    child: std.process.Child,
    reader_thread: ?std.Thread = null,
};

const Slot = struct {
    alloc: Allocator,
    io: std.Io,
    name: []const u8,
    argv: []const []const u8,
    link: *Link,

    state: State,
    upstream: ?Upstream = null,

    /// Why, when `state == .broken`. Arena-free: it is a formatted string
    /// owned by `alloc` and replaced whenever the state changes.
    reason: []const u8 = "",

    /// The client's own `initialize` request, kept verbatim.
    ///
    /// A slot that starts `withheld` answers `initialize` itself, and an
    /// upstream started later still needs one before it will answer
    /// anything. Replaying the client's is what makes the late start
    /// indistinguishable from an early one -- it carries the client's
    /// protocol version and its declared capabilities, which a request
    /// invented here would not.
    init_request: ?[]u8 = null,

    /// Ids forwarded to the upstream and not yet answered.
    ///
    /// If the upstream is torn down between a request and its reply -- the
    /// role changing is exactly when that happens -- the client is left
    /// waiting on an answer that will never come. These get an error
    /// instead. Stored as the raw JSON of the id so that a string id, a
    /// number id and a negative one all come back as they went out.
    outstanding: std.ArrayList([]u8) = .empty,

    /// Everything written to the client goes through here. Two threads
    /// write: this one, and the upstream drain.
    out: *std.Io.Writer,
    out_mutex: std.Io.Mutex = .init,

    /// Held across a state change, so that a role flip and a client
    /// request cannot interleave halfway through a spawn.
    state_mutex: std.Io.Mutex = .init,

    /// The effective-set version this slot last saw, carried back into
    /// every `persona_wait`. Starting a wait from zero would make Polter
    /// answer immediately every time, turning the long poll into a spin.
    epoch: u64 = 0,

    /// Set once the client's stdin closes, to bring the watcher down.
    done: std.atomic.Value(bool) = .init(false),

    stdout_file: std.Io.File = undefined,
    out_storage: std.Io.File.Writer = undefined,
    out_buf: []u8 = undefined,

    fn init(
        alloc: Allocator,
        io: std.Io,
        name: []const u8,
        argv: []const []const u8,
        link: *Link,
        first: Verdict,
    ) !Slot {
        return .{
            .alloc = alloc,
            .io = io,
            .name = name,
            .argv = argv,
            .link = link,
            // **The answer `run` already got, not a second round trip.**
            // Asking twice would also open a window: the role could move
            // between the two calls, and the state would then disagree
            // with the epoch it is about to wait on.
            .state = if (first.answer == .yes) .granted else .withheld,
            .epoch = first.epoch,
            .out = undefined,
        };
    }

    fn deinit(self: *Slot) void {
        self.stopUpstream();
        if (self.init_request) |r| self.alloc.free(r);
        for (self.outstanding.items) |id| self.alloc.free(id);
        self.outstanding.deinit(self.alloc);
        if (self.reason.len > 0) self.alloc.free(self.reason);
    }

    fn serve(self: *Slot) !u8 {
        const io = self.io;

        self.out_buf = try self.alloc.alloc(u8, 64 * 1024);
        defer self.alloc.free(self.out_buf);
        self.stdout_file = .stdout();
        self.out_storage = self.stdout_file.writerStreaming(io, self.out_buf);
        self.out = &self.out_storage.interface;

        const watcher = std.Thread.spawn(.{}, watch, .{self}) catch null;
        defer if (watcher) |t| {
            self.done.store(true, .release);
            t.join();
        };

        const in_buf = try self.alloc.alloc(u8, max_line);
        defer self.alloc.free(in_buf);
        var stdin: std.Io.File = .stdin();
        var reader = stdin.reader(io, in_buf);

        while (true) {
            const line = (try reader.interface.takeDelimiter('\n')) orelse break;
            if (line.len == 0) continue;
            self.handle(line) catch |err| {
                log.warn("mcp-slot: could not handle a message err={}", .{err});
            };
        }
        return 0;
    }

    /// One message from the client.
    fn handle(self: *Slot, line: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        const aa = arena.allocator();

        const msg = std.json.parseFromSliceLeaky(std.json.Value, aa, line, .{}) catch {
            // Not JSON. In `granted` this is the upstream's problem to
            // report -- forwarding it keeps the error where the client
            // expects it, rather than inventing one here.
            return self.forwardRaw(line);
        };
        const obj = switch (msg) {
            .object => |o| o,
            else => return self.forwardRaw(line),
        };

        const method = switch (obj.get("method") orelse .null) {
            .string => |s| s,
            else => return self.forwardRaw(line),
        };

        if (std.mem.eql(u8, method, "initialize")) {
            if (self.init_request == null) {
                self.init_request = try self.alloc.dupe(u8, line);
            }

            self.state_mutex.lockUncancelable(self.io);
            defer self.state_mutex.unlock(self.io);

            if (self.state == .granted) {
                self.startUpstream(line) catch |err| {
                    self.becomeBroken(err);
                    // Fall through: with no upstream there is nobody to
                    // answer, so this answers, and the answer says why.
                };
            }
            if (self.state == .granted) return; // the upstream replied

            const id = obj.get("id") orelse return;
            return self.writeResult(aa, id, try self.localInitializeResult(aa));
        }

        const id_opt = obj.get("id");

        self.state_mutex.lockUncancelable(self.io);
        const state = self.state;
        self.state_mutex.unlock(self.io);

        if (state == .granted) {
            if (id_opt) |id| try self.rememberOutstanding(id);
            return self.forwardRaw(line);
        }

        // Withheld or broken: no upstream exists, so everything is answered
        // here. A notification has no id and takes no reply.
        const id = id_opt orelse return;

        if (std.mem.eql(u8, method, "ping"))
            return self.writeResult(aa, id, "{}");

        if (std.mem.eql(u8, method, "tools/list"))
            return self.writeResult(aa, id, try self.localToolsList(aa));

        if (std.mem.eql(u8, method, "tools/call"))
            return self.writeToolError(aa, id, try self.unavailableSentence(aa));

        // `resources/list` and friends. An empty result would be a claim
        // about the upstream that this cannot make while it is not running.
        try self.writeError(aa, id, -32601, "method not found");
    }

    /// `initialize` answered without an upstream.
    ///
    /// `listChanged` is declared true because it is true: the role can
    /// change under this connection and this will say so.
    fn localInitializeResult(self: *Slot, aa: Allocator) ![]const u8 {
        return std.fmt.allocPrint(aa,
            \\{{"protocolVersion":"{s}","capabilities":{{"tools":{{"listChanged":true}}}},
        ++
            \\"serverInfo":{{"name":"polter:{s}","version":"0"}},"instructions":{f}}}
        , .{
            protocol_version,
            self.name,
            std.json.fmt(try self.unavailableSentence(aa), .{}),
        });
    }

    /// The tool list in the states where there is no upstream.
    ///
    /// **`withheld` is empty and `broken` is not**, and that difference is
    /// the reason this function exists rather than a constant. An agent
    /// that sees nothing concludes the role did not give it this; an agent
    /// that sees the tool below knows the role did and the upstream did
    /// not start. Those are different situations with different next steps,
    /// and roles.md's second open question is exactly that they must not
    /// arrive looking alike.
    fn localToolsList(self: *Slot, aa: Allocator) ![]const u8 {
        if (self.state != .broken) return "{\"tools\":[]}";

        return std.fmt.allocPrint(aa,
            \\{{"tools":[{{"name":"polter_slot_unavailable","description":{f},
        ++
            \\"inputSchema":{{"type":"object","properties":{{}}}}}}]}}
        , .{std.json.fmt(try self.unavailableSentence(aa), .{})});
    }

    /// One sentence saying which of the two silences this is.
    ///
    /// Written for the agent that reads it, because that is who receives
    /// it: it is the text of a tool description, a tool error, and the
    /// `instructions` block, and in all three the reader is deciding what
    /// to do next.
    fn unavailableSentence(self: *Slot, aa: Allocator) ![]const u8 {
        return switch (self.state) {
            .broken => std.fmt.allocPrint(
                aa,
                "「{s}」这个上游起不来（{s}）。**这不是你的角色没有给你它** —— " ++
                    "角色里有它，是那个服务器本身没跑起来。可以告诉用户这一句。",
                .{ self.name, self.reason },
            ),
            else => std.fmt.allocPrint(
                aa,
                "这个终端的角色里没有「{s}」，所以它一个工具都不暴露。" ++
                    "**上游没有出问题，也没有在运行** —— 要用它，让用户给这个 " ++
                    "tab 换一个带它的角色。",
                .{self.name},
            ),
        };
    }

    // -- upstream ------------------------------------------------------

    /// Start the upstream and hand it `init_line` as its `initialize`.
    ///
    /// Caller holds `state_mutex`.
    ///
    /// The first reply is read here rather than by the drain thread,
    /// because it is the one message that is not forwarded verbatim and
    /// because it is the one that must not race anything. From the second
    /// message on, the drain thread copies lines through untouched.
    fn startUpstream(self: *Slot, init_line: []const u8) !void {
        std.debug.assert(self.upstream == null);

        // The upstream inherits this process's environment, which is what
        // "把命令行和环境原样搬过去" means: it gets exactly what it would
        // have got had the user pointed the host config straight at it.
        var child = try std.process.spawn(self.io, .{
            .argv = self.argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        errdefer _ = child.wait(self.io) catch {};

        const stdin = child.stdin.?;
        try stdin.writeStreamingAll(self.io, init_line);
        try stdin.writeStreamingAll(self.io, "\n");

        const buf = try self.alloc.alloc(u8, max_line);
        errdefer self.alloc.free(buf);
        var reader = child.stdout.?.readerStreaming(self.io, buf);
        const reply = (try reader.interface.takeDelimiter('\n')) orelse
            return error.UpstreamClosedAtInitialize;

        try self.writeLine(try self.patchInitialize(reply));
        self.alloc.free(buf);

        self.upstream = .{ .child = child };
        self.upstream.?.reader_thread = std.Thread.spawn(.{}, drain, .{self}) catch null;
    }

    /// Set `capabilities.tools.listChanged` on the upstream's `initialize`
    /// result, and change nothing else.
    ///
    /// **The only field this file ever writes into a forwarded message.**
    /// It is a claim about what *this process* will do -- the role can
    /// change under a live connection and this will send
    /// `notifications/tools/list_changed` when it does -- and an upstream
    /// that never sends one has no way to have declared it.
    ///
    /// Done as a targeted string edit rather than a reparse-and-reserialize
    /// so that every other byte, including field order and any extension
    /// the upstream carries, arrives as it left.
    fn patchInitialize(self: *Slot, reply: []const u8) ![]const u8 {
        // Already declared: nothing to do, and re-writing it would be a
        // change for its own sake.
        if (std.mem.indexOf(u8, reply, "\"listChanged\":true") != null)
            return reply;

        const needle = "\"tools\":{";
        const at = std.mem.indexOf(u8, reply, needle) orelse {
            // No tools capability at all. An upstream that declares no
            // tools is not one whose list we are going to change, so this
            // is left exactly as it came.
            return reply;
        };
        const cut = at + needle.len;
        const tail = reply[cut..];
        // `"tools":{}` -- an empty object takes the field without a comma.
        const sep: []const u8 = if (tail.len > 0 and tail[0] == '}') "" else ",";
        return std.fmt.allocPrint(self.alloc, "{s}\"listChanged\":true{s}{s}", .{
            reply[0..cut], sep, tail,
        }) catch reply;
    }

    /// Copy the upstream's output to the client, line by line, unchanged.
    fn drain(self: *Slot) void {
        const buf = self.alloc.alloc(u8, max_line) catch return;
        defer self.alloc.free(buf);

        const stdout = blk: {
            self.state_mutex.lockUncancelable(self.io);
            defer self.state_mutex.unlock(self.io);
            const u = self.upstream orelse return;
            break :blk u.child.stdout orelse return;
        };

        var reader = stdout.readerStreaming(self.io, buf);
        while (true) {
            const line = (reader.interface.takeDelimiter('\n') catch null) orelse break;
            if (line.len == 0) continue;
            self.forgetOutstanding(line);
            self.writeLine(line) catch break;
        }

        // The upstream's stdout closed. If we are still meant to have one,
        // it died -- which is `broken`, and the client is told so with the
        // same notification a role change uses.
        self.state_mutex.lockUncancelable(self.io);
        const still_wanted = self.state == .granted;
        if (still_wanted) {
            self.becomeBroken(error.UpstreamExited);
            self.failOutstanding();
        }
        self.state_mutex.unlock(self.io);

        if (still_wanted) self.announceChange();
    }

    /// Caller holds `state_mutex`.
    fn becomeBroken(self: *Slot, err: anyerror) void {
        if (self.reason.len > 0) self.alloc.free(self.reason);
        self.reason = std.fmt.allocPrint(self.alloc, "{t}", .{err}) catch "";
        self.state = .broken;
        log.warn("mcp-slot: upstream for {s} is not running: {}", .{ self.name, err });
    }

    fn stopUpstream(self: *Slot) void {
        const u = &(if (self.upstream) |*p| p else return).*;
        if (u.child.stdin) |f| {
            f.close(self.io);
            u.child.stdin = null;
        }
        if (u.reader_thread) |t| t.join();
        _ = u.child.wait(self.io) catch {};
        self.upstream = null;
    }

    // -- the role changing --------------------------------------------

    /// Hold a `persona_wait` open, and act when the answer moves.
    ///
    /// # Three ways this loop can be handed nothing, and why only one of
    /// them is a problem
    ///
    ///   * **The poll timed out.** Polter is fine and nothing changed.
    ///     Wait again, from the epoch it just confirmed.
    ///   * **The connection died.** Reconnect, and **change nothing while
    ///     doing so**. roles.md 3.3: a slot that has been told "no" does
    ///     not become transparent because a socket dropped.
    ///   * **Polter answered something unintelligible.** Same treatment:
    ///     the state stays where it is.
    ///
    /// # Waking up is not the same as changing
    ///
    /// `epoch` versions this terminal's **whole** effective set, so a user
    /// switching one unrelated skill wakes every slot's wait with its own
    /// `wanted` unmoved. Announcing on every wake would have one click in
    /// the editor make every agent re-fetch every tool list. So the answer
    /// is compared against the state before anything is sent -- and
    /// "announce on wake" and "announce on change" are the same shape in
    /// the source, which is why it is written down here.
    fn watch(self: *Slot) void {
        while (!self.done.load(.acquire)) {
            const v = self.link.wait(self.name, self.epoch);
            if (self.done.load(.acquire)) return;

            // Even a timeout carries the epoch, and taking it is what keeps
            // the next wait from starting behind and returning at once.
            if (v.epoch != 0) self.epoch = v.epoch;

            const now: State = switch (v.answer) {
                .yes => .granted,
                .no => .withheld,
                .unknown => {
                    if (!v.timed_out) self.link.reconnect(&self.done);
                    continue;
                },
            };

            self.state_mutex.lockUncancelable(self.io);
            const was = self.state;
            // `broken` is a `granted` that failed, so a `yes` that finds it
            // broken is not a change -- retrying the spawn on a timer would
            // be a restart policy, and roles.md leaves that open (its
            // second undecided question). Not deciding it here is on
            // purpose; what is decided is that it does not look like
            // `withheld`.
            const changed = switch (was) {
                .granted, .broken => now == .withheld,
                .withheld => now == .granted,
            };
            if (!changed) {
                self.state_mutex.unlock(self.io);
                continue;
            }

            if (now == .granted) {
                self.state = .granted;
                if (self.init_request) |req| {
                    self.startUpstreamLate(req) catch |err| self.becomeBroken(err);
                }
            } else {
                self.stopUpstream();
                self.failOutstanding();
                self.state = .withheld;
            }
            self.state_mutex.unlock(self.io);

            self.announceChange();
        }
    }

    /// Start the upstream for a client that was already told `initialize`
    /// by us.
    ///
    /// Caller holds `state_mutex`. The upstream still needs an
    /// `initialize` -- it will answer nothing before one -- but the client
    /// has had its reply, so this one's reply is read and dropped. Sending
    /// it on would be a second answer to a request the client considers
    /// settled.
    fn startUpstreamLate(self: *Slot, init_line: []const u8) !void {
        std.debug.assert(self.upstream == null);

        var child = try std.process.spawn(self.io, .{
            .argv = self.argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        errdefer _ = child.wait(self.io) catch {};

        const stdin = child.stdin.?;
        try stdin.writeStreamingAll(self.io, init_line);
        try stdin.writeStreamingAll(self.io, "\n");

        const buf = try self.alloc.alloc(u8, max_line);
        defer self.alloc.free(buf);
        var reader = child.stdout.?.readerStreaming(self.io, buf);
        _ = (try reader.interface.takeDelimiter('\n')) orelse
            return error.UpstreamClosedAtInitialize;

        // The handshake the client already completed with us, completed
        // again with the upstream on its behalf.
        try stdin.writeStreamingAll(
            self.io,
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n",
        );

        self.upstream = .{ .child = child };
        self.upstream.?.reader_thread = std.Thread.spawn(.{}, drain, .{self}) catch null;
    }

    /// Tell the client its tool list is not what it was.
    ///
    /// This is the whole mechanism of a hot change (roles.md 1.1): the
    /// client re-issues `tools/list` on receipt, and the agent inside it
    /// changes costume without restarting.
    fn announceChange(self: *Slot) void {
        self.writeLine(
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}",
        ) catch {};
    }

    // -- outstanding requests ------------------------------------------

    fn rememberOutstanding(self: *Slot, id: std.json.Value) !void {
        const text = try std.fmt.allocPrint(self.alloc, "{f}", .{std.json.fmt(id, .{})});
        errdefer self.alloc.free(text);
        try self.outstanding.append(self.alloc, text);
    }

    /// A reply went past carrying an id; that request is settled.
    fn forgetOutstanding(self: *Slot, line: []const u8) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        for (self.outstanding.items, 0..) |id, i| {
            const needle = std.fmt.allocPrint(self.alloc, "\"id\":{s}", .{id}) catch continue;
            defer self.alloc.free(needle);
            if (std.mem.indexOf(u8, line, needle) == null) continue;
            self.alloc.free(self.outstanding.swapRemove(i));
            return;
        }
    }

    /// Answer everything the upstream will now never answer.
    ///
    /// Caller holds `state_mutex`. **A client left waiting on a reply that
    /// cannot arrive is the failure this prevents**, and it is the ordinary
    /// case rather than a rare one: a role changing while a tool call is in
    /// flight is exactly when the upstream goes away.
    fn failOutstanding(self: *Slot) void {
        for (self.outstanding.items) |id| {
            var buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&buf,
                \\{{"jsonrpc":"2.0","id":{s},"result":{{"content":[{{"type":"text",
            ++
                \\"text":"这次调用没有结果：「{s}」的上游在调用途中停了。"}}],"isError":true}}}}
            , .{ id, self.name }) catch {
                self.alloc.free(id);
                continue;
            };
            self.writeLine(line) catch {};
            self.alloc.free(id);
        }
        self.outstanding.clearRetainingCapacity();
    }

    // -- writing -------------------------------------------------------

    fn forwardRaw(self: *Slot, line: []const u8) !void {
        self.state_mutex.lockUncancelable(self.io);
        const stdin = if (self.upstream) |u| u.child.stdin else null;
        self.state_mutex.unlock(self.io);
        const f = stdin orelse return;
        try f.writeStreamingAll(self.io, line);
        try f.writeStreamingAll(self.io, "\n");
    }

    fn writeLine(self: *Slot, line: []const u8) !void {
        self.out_mutex.lockUncancelable(self.io);
        defer self.out_mutex.unlock(self.io);
        try self.out.writeAll(line);
        try self.out.writeByte('\n');
        try self.out.flush();
    }

    fn writeResult(self: *Slot, aa: Allocator, id: std.json.Value, result: []const u8) !void {
        const line = try std.fmt.allocPrint(aa,
            \\{{"jsonrpc":"2.0","id":{f},"result":{s}}}
        , .{ std.json.fmt(id, .{}), result });
        try self.writeLine(line);
    }

    fn writeError(
        self: *Slot,
        aa: Allocator,
        id: std.json.Value,
        code: i32,
        message: []const u8,
    ) !void {
        const line = try std.fmt.allocPrint(aa,
            \\{{"jsonrpc":"2.0","id":{f},"error":{{"code":{d},"message":{f}}}}}
        , .{ std.json.fmt(id, .{}), code, std.json.fmt(message, .{}) });
        try self.writeLine(line);
    }

    /// A refused tool call is a *successful* JSON-RPC reply carrying
    /// `isError`, not a protocol error -- the same rule `cli/mcp.zig`
    /// states, and getting it backwards makes a client treat a withheld
    /// slot as a broken server.
    fn writeToolError(self: *Slot, aa: Allocator, id: std.json.Value, message: []const u8) !void {
        const body = try std.fmt.allocPrint(aa,
            \\{{"content":[{{"type":"text","text":{f}}}],"isError":true}}
        , .{std.json.fmt(message, .{})});
        try self.writeResult(aa, id, body);
    }
};

// -- tests -------------------------------------------------------------

const testing = std.testing;

/// A `Slot` with nothing behind it, for the parts that answer without an
/// upstream. Building one this way rather than through `init` is what lets
/// the state be set by hand -- which is the variable every test below is
/// about.
fn testSlot(state: State, reason: []const u8) Slot {
    return .{
        .alloc = testing.allocator,
        .io = undefined,
        .name = "argus",
        .argv = &.{},
        .link = undefined,
        .state = state,
        .reason = reason,
        .out = undefined,
    };
}

test "mcp-slot: withheld and broken do not look alike in tools/list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var withheld = testSlot(.withheld, "");
    const a = try withheld.localToolsList(aa);

    var broken = testSlot(.broken, "FileNotFound");
    const b = try broken.localToolsList(aa);

    // The assertion that matters is that they differ at all -- that is
    // roles.md's "不要让「上游挂了」和「这个角色没有它」长得一样" stated as a
    // comparison rather than as prose.
    try testing.expect(!std.mem.eql(u8, a, b));

    // And the direction of the difference: withheld is genuinely empty,
    // broken carries something that says why.
    try testing.expectEqualStrings("{\"tools\":[]}", a);
    try testing.expect(std.mem.indexOf(u8, b, "polter_slot_unavailable") != null);
    try testing.expect(std.mem.indexOf(u8, b, "FileNotFound") != null);

    // Both are JSON a client can read.
    for ([_][]const u8{ a, b }) |s| {
        const parsed = try std.json.parseFromSlice(std.json.Value, aa, s, .{});
        try testing.expect(parsed.value.object.get("tools") != null);
    }
}

test "mcp-slot: the two silences say different things to the agent" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var withheld = testSlot(.withheld, "");
    const a = try withheld.unavailableSentence(aa);
    var broken = testSlot(.broken, "AccessDenied");
    const b = try broken.unavailableSentence(aa);

    try testing.expect(!std.mem.eql(u8, a, b));
    // Each names the slot, because an agent holding several of these has
    // no other way to tell which one spoke.
    try testing.expect(std.mem.indexOf(u8, a, "argus") != null);
    try testing.expect(std.mem.indexOf(u8, b, "argus") != null);
}

test "mcp-slot: a local initialize is valid JSON and declares listChanged" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var s = testSlot(.withheld, "");
    const body = try s.localInitializeResult(aa);

    const parsed = try std.json.parseFromSlice(std.json.Value, aa, body, .{});
    const caps = parsed.value.object.get("capabilities").?.object;
    const tools = caps.get("tools").?.object;
    // Declared because it is true: this connection really can change its
    // tool list under the client.
    try testing.expectEqual(true, tools.get("listChanged").?.bool);
    try testing.expectEqualStrings(
        "polter:argus",
        parsed.value.object.get("serverInfo").?.object.get("name").?.string,
    );
}

test "mcp-slot: patching initialize touches listChanged and nothing else" {
    var s = testSlot(.granted, "");

    {
        const in =
            \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{"x":1}},"serverInfo":{"name":"argus"}}}
        ;
        const out = try s.patchInitialize(in);
        defer if (out.ptr != in.ptr) testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "\"listChanged\":true") != null);
        // Everything else survived, including the upstream's own name --
        // which is the thing a renaming proxy would have eaten.
        try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"argus\"") != null);
        try testing.expect(std.mem.indexOf(u8, out, "\"x\":1") != null);

        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
        defer parsed.deinit();
        const tools = parsed.value.object.get("result").?.object
            .get("capabilities").?.object.get("tools").?.object;
        try testing.expectEqual(true, tools.get("listChanged").?.bool);
        try testing.expectEqual(@as(i64, 1), tools.get("x").?.integer);
    }

    {
        // The empty-object case, where a comma would produce `{,"…"}`.
        const in =
            \\{"result":{"capabilities":{"tools":{}}}}
        ;
        const out = try s.patchInitialize(in);
        defer if (out.ptr != in.ptr) testing.allocator.free(out);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
        defer parsed.deinit();
        try testing.expectEqual(true, parsed.value.object.get("result").?.object
            .get("capabilities").?.object.get("tools").?.object.get("listChanged").?.bool);
    }

    {
        // An upstream with no tools capability is left byte for byte alone:
        // there is no list of its we are going to change.
        const in =
            \\{"result":{"capabilities":{"resources":{}}}}
        ;
        const out = try s.patchInitialize(in);
        try testing.expectEqualStrings(in, out);
    }

    {
        // Already declared. Rewriting it would be a change for its own sake,
        // and this is the floor for the branch above: without the early
        // return the field would appear twice.
        const in =
            \\{"result":{"capabilities":{"tools":{"listChanged":true}}}}
        ;
        const out = try s.patchInitialize(in);
        try testing.expectEqualStrings(in, out);
        try testing.expectEqual(
            @as(?usize, null),
            std.mem.indexOf(u8, out[std.mem.indexOf(u8, out, "listChanged").? + 1 ..], "listChanged"),
        );
    }
}

test "mcp-slot: a refusal and a no are not the same answer" {
    const a = testing.allocator;

    // The contract's two shapes.
    const yes = interpret(a,
        \\{"ok":true,"wanted":true,"epoch":7}
    );
    try testing.expectEqual(Answer.yes, yes.answer);
    try testing.expectEqual(@as(u64, 7), yes.epoch);
    try testing.expect(!yes.timed_out);

    const no = interpret(a,
        \\{"ok":true,"wanted":false,"epoch":8}
    );
    try testing.expectEqual(Answer.no, no.answer);
    try testing.expectEqual(@as(u64, 8), no.epoch);

    // A Polter that does not know the method. **This must not be `no`.**
    // Reading it as `no` would strip an upstream from every terminal the
    // moment somebody runs an older build.
    const refused = interpret(a,
        \\{"ok":false,"error":"unknown method"}
    );
    try testing.expectEqual(Answer.unknown, refused.answer);

    // And the other direction, which is the one with teeth: an explicit
    // `wanted:false` must never come back as `unknown`, because `unknown`
    // is what the caller treats as "carry on" -- and carrying on from a
    // withheld state would keep the upstream withheld, but carrying on
    // from a transparent one would hand it over.
    try testing.expect(no.answer != .unknown);
}

test "mcp-slot: a timeout is not an answer and not a failure" {
    const a = testing.allocator;

    const t = interpret(a,
        \\{"ok":true,"timeout":true,"epoch":7}
    );
    // Not an answer: nothing moved, so the state must not be touched.
    try testing.expectEqual(Answer.unknown, t.answer);
    // But distinguishable from a dead link, which is what decides whether
    // the caller reconnects or simply waits again.
    try testing.expect(t.timed_out);
    // The epoch still comes back, and it has to: waiting again from zero
    // would make Polter answer immediately every time and turn the long
    // poll into a spin.
    try testing.expectEqual(@as(u64, 7), t.epoch);

    const dead = interpret(a,
        \\{"ok":false}
    );
    try testing.expectEqual(Answer.unknown, dead.answer);
    try testing.expect(!dead.timed_out);
}

test "mcp-slot: garbage and half-understood replies fall to unknown" {
    const a = testing.allocator;

    for ([_][]const u8{
        "not json at all",
        "[]",
        \\{"ok":true}
        ,
        \\{"ok":true,"epoch":3}
        ,
    }) |line| {
        // Every one of these is a reply this build cannot act on. The
        // only safe reading is "no answer": it leaves the slot where it
        // is, which is wrong in no direction.
        try testing.expectEqual(Answer.unknown, interpret(a, line).answer);
    }

    // The control. Without it, the loop above would pass for an
    // `interpret` that returned `.unknown` unconditionally.
    try testing.expectEqual(Answer.yes, interpret(a,
        \\{"ok":true,"wanted":true,"epoch":1}
    ).answer);

    // Fields this build has never heard of do not spoil a good reply --
    // the contract is free to grow, and a slot that broke on a new field
    // would break on the next revision of it.
    try testing.expectEqual(Answer.no, interpret(a,
        \\{"ok":true,"wanted":false,"epoch":2,"reason":"not in this persona"}
    ).answer);
}
