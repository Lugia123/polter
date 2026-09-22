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

/// The shortest a `persona_wait` round trip may take before the next one is
/// allowed to go out.
///
/// ⚠️ **This is not tuning, it is a guard against a busy loop.** A long
/// poll is only long if the far end parks it. 🔬 Today nothing does:
/// `rpc.zig` has an arm for "nobody parked it" that answers
/// `{"timeout":true}` at once, and its comment says a caller looping on it
/// "degrades to polling instead of breaking" -- but polling with no
/// interval is a spin, and there is one of these processes per slot per
/// terminal. Measured only by reading: nothing in `src/` intercepts
/// `persona_wait` at all.
///
/// So the floor lives on this side as well as on that one. It costs a
/// *change* nothing, because a change does not come back as a timeout.
const min_wait_ms = 250;

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

    const out_buf = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(out_buf);
    const in_buf = try alloc.alloc(u8, max_line);
    defer alloc.free(in_buf);

    var stdin: std.Io.File = .stdin();
    var stdout: std.Io.File = .stdout();
    var reader = stdin.reader(io, in_buf);
    // Streaming for the reason `cli/mcp.zig` gives: a positional writer
    // would overwrite whatever was already in the file when stdout is
    // redirected to one, which is how somebody reads the protocol back.
    var writer = stdout.writerStreaming(io, out_buf);

    return slot.serve(&reader.interface, &writer.interface);
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

    /// Counts how many times the `min_wait_ms` floor actually slept.
    ///
    /// **An instrument, not a switch.** It is `null` in the product, so no
    /// branch here runs differently because of it; all it does is record.
    /// It exists because the floor it counts spent its whole first life as
    /// dead code -- the stub it was tested against parked its own wait, so
    /// `took < min_wait_ms` was never true, and a floor that never executes
    /// is not a floor but a piece of code shaped like one.
    floor_hits: ?*std.atomic.Value(u32) = null,

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

    /// Run until the client closes its end.
    ///
    /// # Why the two streams are arguments
    ///
    /// In the product they are this process's stdin and stdout, and `run`
    /// hands them over. They are parameters so that a test can put a real
    /// socket there instead and drive the whole of this -- the state
    /// machine, the upstream child, the watcher thread, the notification --
    /// over a real connection rather than over a mock of one.
    ///
    /// **The seam changes where the bytes come from and nothing else.**
    /// Every line below runs identically either way; what the test does not
    /// cover is the two lines in `run` that name `.stdin()` and `.stdout()`,
    /// and that is stated here rather than left to be assumed.
    fn serve(self: *Slot, in: *std.Io.Reader, out: *std.Io.Writer) !u8 {
        self.out = out;

        // **The upstream is brought down here, not in `deinit`, and that
        // ordering is load-bearing.**
        //
        // The drain thread writes to `out`, and `out`'s buffer belongs to
        // the caller -- which frees it as its own `defer`s unwind. Those
        // run *before* a `defer slot.deinit()` registered earlier, so
        // leaving the join to `deinit` means the drain thread writes into
        // freed memory. 🔬 Measured: a segfault inside `writeAll`, reached
        // from `drain` -> `announceChange`, the first time this was run
        // over a real socket. Every unit test above passed while that was
        // true, because none of them had a second thread.
        //
        // Registered before the watcher's `defer` so that it runs after
        // it: the watcher is the thing that can start a *new* upstream.
        defer self.stopUpstream();

        const watcher = std.Thread.spawn(.{}, watch, .{self}) catch null;
        defer if (watcher) |t| {
            self.done.store(true, .release);
            t.join();
        };

        while (true) {
            const line = (try in.takeDelimiter('\n')) orelse break;
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

    /// Close the upstream down and wait for its drain thread.
    ///
    /// ⚠️ **Called without `state_mutex` held, and it takes the lock itself
    /// only to detach the upstream.** The drain thread takes that same lock
    /// on its way out, so joining it from inside the lock is a deadlock.
    /// 🔬 Measured rather than reasoned about: the first end-to-end run
    /// wedged here and only came back when the test's watchdog broke the
    /// connection. Under unit tests it could not happen, because nothing
    /// there ever started a second thread.
    fn stopUpstream(self: *Slot) void {
        self.state_mutex.lockUncancelable(self.io);
        var u = self.upstream orelse {
            self.state_mutex.unlock(self.io);
            return;
        };
        self.upstream = null;
        self.state_mutex.unlock(self.io);

        // Closing its stdin is how the upstream is told the conversation is
        // over; it ends, its stdout closes, and the drain thread falls out
        // of its read.
        if (u.child.stdin) |f| {
            f.close(self.io);
            u.child.stdin = null;
        }
        if (u.reader_thread) |t| t.join();
        _ = u.child.wait(self.io) catch {};
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
            const started: std.Io.Timestamp = .now(self.io, .awake);
            const v = self.link.wait(self.name, self.epoch);
            if (self.done.load(.acquire)) return;

            // A timeout that came back instantly means the far end did not
            // park it. Sleeping the difference turns that into the polling
            // its own comment claims it is, rather than a spin. A real
            // change never lands here: it is not a timeout.
            if (v.timed_out) {
                const took = started.durationTo(.now(self.io, .awake)).toMilliseconds();
                if (took < min_wait_ms) {
                    if (self.floor_hits) |c| _ = c.fetchAdd(1, .acq_rel);
                    const rest: u64 = @intCast(min_wait_ms - took);
                    self.io.sleep(
                        .fromNanoseconds(rest * std.time.ns_per_ms),
                        .awake,
                    ) catch {};
                    if (self.done.load(.acquire)) return;
                }
            }

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
                self.state_mutex.unlock(self.io);
            } else {
                // **The state moves first, and the teardown follows it.**
                // The drain thread wakes when the upstream's stdout closes
                // and asks "am I still meant to have one"; if the answer
                // were still `granted` at that moment it would announce a
                // `broken` upstream that nothing is wrong with -- and the
                // user would be told their server crashed at the exact
                // moment they took it away on purpose.
                self.state = .withheld;
                self.state_mutex.unlock(self.io);

                // Outside the lock: `stopUpstream` joins the drain thread,
                // and the drain thread wants this lock.
                self.stopUpstream();

                self.state_mutex.lockUncancelable(self.io);
                self.failOutstanding();
                self.state_mutex.unlock(self.io);
            }

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

// -- end to end, over a real socket ------------------------------------
//
// Everything above this line is tested as pure functions, and pure
// functions were never the risk here. `server_test.zig` states the reason
// in its own header and it applies word for word: *"the first version of
// this server compiled, type-checked against two targets, passed every unit
// test, and served exactly zero requests"*. What this section runs is the
// whole of it -- a real socket, a real handshake, a real child process, the
// watcher thread, and the notification arriving on the client's stream
// while the client is sitting idle.
//
// **The stub is deliberately only section six of the contract.** When
// Polter's own `persona_slot` / `persona_wait` land, the only thing that
// changes in this picture is which process is on the far end of that
// socket. Keeping the stub afterwards is what makes that a one-variable
// change rather than a two-variable one.

const builtin = @import("builtin");
const transport = @import("../poltergeist/transport.zig");
const Server = @import("../poltergeist/Server.zig");
const Bus = @import("../poltergeist/Bus.zig");
const rpc = @import("../poltergeist/rpc.zig");

/// Polter's real agent socket, with only the persona answer faked.
///
/// # What this replaced, and why the replacement is the point
///
/// This used to be a hand-written stub that spoke the two methods itself.
/// It was honest about being a stub and it still hid the thing most worth
/// checking: **the stub parked its own long poll, so a slot passing this
/// test proved nothing about whether Polter parks one.** Both produce the
/// same bytes when they work.
///
/// So the socket, the handshake, the framing and the dispatch are now the
/// product's own: `Server` accepts and authenticates, `wire` decodes,
/// `rpc.dispatch` runs the real `persona_slot` and `persona_wait` arms.
/// What is faked is one function -- what this terminal's persona says about
/// one slot -- because that is the only thing a test needs to move.
///
/// **What is still not covered, stated so it is not assumed:** parking a
/// wait lives in `App.zig`, and there is no app-level test host in this
/// tree. So `persona_wait` here takes `rpc.zig`'s "nobody parked it" arm
/// and answers at once. That is a real code path -- an embedder that has
/// not wired parking up gets exactly this -- but it is **not** the path a
/// running Polter takes, and the difference is the one thing a real-machine
/// run has to look at first.
///
/// One thing falls out of that and is worth having: because this answers
/// instantly, the `min_wait_ms` floor is **executed** here. Against the old
/// stub it was dead code, since a stub that holds for 1500 ms never lets
/// `took < min_wait_ms` be true.
const RealPolter = struct {
    alloc: Allocator,
    io: std.Io,
    path: [:0]u8,
    server: Server,
    bus: Bus,
    token: []const u8,

    mutex: std.Io.Mutex = .init,
    wanted: bool,
    epoch: u64 = 1,

    /// Counted so a test can tell "the slot never asked" apart from "the
    /// slot asked and acted on the answer". Those two produce the same
    /// empty tool list.
    asked: std.atomic.Value(u32) = .init(0),

    /// Only `personaSlot` is ever reached; see `submit`, which refuses
    /// everything else before `dispatch` can look at another entry.
    vtable: rpc.Host.VTable = undefined,

    /// The terminal this slot's token belongs to. Any id will do; it only
    /// has to be the same one throughout.
    const terminal: Bus.Id = 0x5151;

    fn start(alloc: Allocator, io: std.Io, wanted: bool) !*RealPolter {
        var raw: [6]u8 = undefined;
        io.random(&raw);
        const path = try std.fmt.allocPrintSentinel(
            alloc,
            "/tmp/pg-real-{x}.sock",
            .{&raw},
            0,
        );
        errdefer alloc.free(path);

        const self = try alloc.create(RealPolter);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .io = io,
            .path = path,
            .server = undefined,
            .bus = .init(alloc, .{}),
            .token = undefined,
            .wanted = wanted,
        };

        self.vtable = undefined;
        self.vtable.personaSlot = personaSlot;
        // `dispatch` tells the host about every caller before it judges
        // the request (`rpc.arrived`), so this entry is reached by every
        // call, not only by a persona one. Nothing is launched here, so
        // there is nothing to claim.
        self.vtable.agentArrived = agentArrived;

        self.server = try .init(alloc, io, path, .{
            .ctx = self,
            .func = submit,
        }, Server.default_max_connections);
        errdefer self.server.deinit();

        self.token = try self.server.issueToken(terminal);
        try self.server.start();
        return self;
    }

    fn deinit(self: *RealPolter) void {
        self.server.deinit();
        self.bus.deinit();
        self.alloc.free(self.path);
        self.alloc.destroy(self);
    }

    /// Move the answer, the way a user picking a persona off a menu would.
    ///
    /// `epoch` moves with it, and it has to: a waiting slot is parked on
    /// the epoch it last saw, so an answer that changed without the number
    /// changing would never reach it.
    fn setWanted(self: *RealPolter, w: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.wanted = w;
        self.epoch += 1;
    }

    fn agentArrived(_: *anyopaque, _: *Bus, _: Bus.Id) void {}

    fn host(self: *RealPolter) rpc.Host {
        return .{ .ctx = self, .vtable = &self.vtable };
    }

    /// The app thread's job, done here.
    ///
    /// ⚠️ **The gate above `dispatch` is what makes the half-filled vtable
    /// safe.** Only the two persona methods get through, and those reach
    /// exactly two entries: `personaSlot`, and `agentArrived`, which
    /// `dispatch` calls for every caller. Anything else is refused here rather than being
    /// allowed to call through a field that was never set -- which would
    /// not fail, it would jump somewhere.
    fn submit(ctx: *anyopaque, pending: *Server.Pending) void {
        const self: *RealPolter = @ptrCast(@alignCast(ctx));
        defer pending.release();

        switch (pending.request) {
            .persona_slot, .persona_wait => {},
            else => {
                pending.complete(self.io, .{ .failed = .{
                    .code = "NotInThisFixture",
                    .message = "this test host only answers the persona slot methods",
                } });
                return;
            },
        }

        const response = rpc.dispatch(
            pending.arena.allocator(),
            &self.bus,
            self.host(),
            pending.caller,
            pending.request,
        ) catch {
            pending.complete(self.io, .{ .failed = .{
                .code = "OutOfMemory",
                .message = "out of memory",
            } });
            return;
        };
        pending.complete(self.io, response);
    }

    fn personaSlot(
        ctx: *anyopaque,
        _: Bus.Id,
        _: []const u8,
    ) anyerror!rpc.Host.PersonaSlot {
        const self: *RealPolter = @ptrCast(@alignCast(ctx));
        _ = self.asked.fetchAdd(1, .acq_rel);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .wanted = self.wanted, .epoch = self.epoch };
    }
};

/// The slot, running on the far end of a socket the test holds.
const SlotSide = struct {
    alloc: Allocator,
    io: std.Io,
    listener: *transport.Listener,
    stub_path: []const u8,
    token: []const u8,
    name: []const u8,
    argv: []const []const u8,
    failed: std.atomic.Value(bool) = .init(false),
    floor_hits: std.atomic.Value(u32) = .init(0),

    fn run(self: *SlotSide) void {
        const conn = self.listener.accept(self.io) catch {
            self.failed.store(true, .release);
            return;
        };
        defer conn.close(self.io);

        var link = Link.open(self.alloc, self.io, self.stub_path, self.token) catch {
            self.failed.store(true, .release);
            return;
        };
        defer link.close();

        const first = link.ask(self.name);
        if (first.answer == .unknown) {
            // The stub answered nothing, so the product would go
            // transparent. In this fixture that is always a fault in the
            // test rather than the behaviour under test, so it is a
            // failure rather than a silent branch.
            self.failed.store(true, .release);
            return;
        }

        var slot: Slot = Slot.init(
            self.alloc,
            self.io,
            self.name,
            self.argv,
            &link,
            first,
        ) catch {
            self.failed.store(true, .release);
            return;
        };
        defer slot.deinit();
        slot.floor_hits = &self.floor_hits;

        const rbuf = self.alloc.alloc(u8, max_line) catch return;
        defer self.alloc.free(rbuf);
        const wbuf = self.alloc.alloc(u8, 64 * 1024) catch return;
        defer self.alloc.free(wbuf);

        var reader = conn.reader(self.io, rbuf);
        var writer = conn.writer(self.io, wbuf);
        _ = slot.serve(&reader.interface, &writer.interface) catch {};
    }
};

/// An upstream MCP server in six lines of shell.
///
/// It answers `initialize` and `tools/list` and touches a file on the way
/// in. That file is the assertion behind "上游进程根本不启动": an empty
/// tool list proves the client saw nothing, and only the sentinel proves
/// the process was never there to produce anything.
///
/// ⚠️ **The quotes in the patterns are load-bearing.** `*initialize*` also
/// matches `notifications/initialized`, which this is sent when a late
/// start replays the handshake -- so a looser pattern makes the stub answer
/// a notification, and that spurious line is then forwarded to the client
/// verbatim (correctly: a slot forwards whatever the upstream says) and
/// lands where the test expects the reply to its next request. It cost one
/// run to find and it would have been read as a forwarding bug.
const upstream_script =
    \\touch "$1"
    \\while IFS= read -r line; do
    \\  case "$line" in
    \\    *'"initialize"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"stub-upstream","version":"1"}}}' ;;
    \\    *'"tools/list"'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"argus_recon","description":"reconnoitre","inputSchema":{"type":"object"}}]}}' ;;
    \\  esac
    \\done
;

/// One end-to-end fixture: a stub Polter, a socket for the client, and a
/// thread with the slot on it.
const E2E = struct {
    alloc: Allocator,
    io: std.Io,
    stub: *RealPolter,
    listener: transport.Listener,
    client_path: []u8,
    side: *SlotSide,
    thread: std.Thread,
    conn: transport.Conn,
    reader: transport.Reader,
    writer: transport.Writer,
    rbuf: []u8,
    wbuf: []u8,
    watchdog: ?std.Thread = null,
    watchdog_stop: std.atomic.Value(bool) = .init(false),
    /// Set the moment the deadline thread cuts the connection.
    ///
    /// ⚠️ **Without this the two are the same error.** A read that ends
    /// because the watchdog broke the socket and a read that ends because
    /// the slot closed it both surface as "the stream is gone" -- so a
    /// machine that was merely busy (a concurrent rebuild is the ordinary
    /// cause) produces the same output as a protocol defect, and the first
    /// place anybody looks is their own stub. The flag is what makes the
    /// busy case say so about itself instead of being reconstructed later
    /// from what else was running.
    watchdog_fired: std.atomic.Value(bool) = .init(false),

    /// A test that hangs is a test nobody keeps, and every read below is a
    /// blocking read on a socket. So a thread waits, and if the whole
    /// exchange has not finished in time it breaks the connection -- which
    /// turns a freeze into a failed read with a line number.
    const deadline_ms = 20 * 1000;

    fn start(
        alloc: Allocator,
        io: std.Io,
        wanted: bool,
        argv: []const []const u8,
    ) !*E2E {
        const self = try alloc.create(E2E);
        errdefer alloc.destroy(self);

        var raw: [6]u8 = undefined;
        io.random(&raw);
        const client_path = try std.fmt.allocPrint(alloc, "/tmp/pg-cli-{x}.sock", .{&raw});

        const stub = try RealPolter.start(alloc, io, wanted);
        const listener = try transport.bind(alloc, io, client_path);

        const side = try alloc.create(SlotSide);
        side.* = .{
            .alloc = alloc,
            .io = io,
            .listener = undefined,
            .stub_path = stub.path,
            .token = stub.token,
            .name = "argus",
            .argv = argv,
        };

        self.* = .{
            .alloc = alloc,
            .io = io,
            .stub = stub,
            .listener = listener,
            .client_path = client_path,
            .side = side,
            .thread = undefined,
            .conn = undefined,
            .reader = undefined,
            .writer = undefined,
            .rbuf = try alloc.alloc(u8, max_line),
            .wbuf = try alloc.alloc(u8, 64 * 1024),
        };
        self.side.listener = &self.listener;
        self.thread = try std.Thread.spawn(.{}, SlotSide.run, .{self.side});

        self.conn = try transport.connect(io, client_path);
        self.reader = self.conn.reader(io, self.rbuf);
        self.writer = self.conn.writer(io, self.wbuf);
        self.watchdog = std.Thread.spawn(.{}, watch_deadline, .{self}) catch null;
        return self;
    }

    fn watch_deadline(self: *E2E) void {
        var waited: u64 = 0;
        while (waited < deadline_ms) {
            if (self.watchdog_stop.load(.acquire)) return;
            self.io.sleep(.fromNanoseconds(25 * std.time.ns_per_ms), .awake) catch {};
            waited += 25;
        }
        self.watchdog_fired.store(true, .release);
        transport.shutdownConn(self.conn, self.io);
    }

    fn deinit(self: *E2E) void {
        self.watchdog_stop.store(true, .release);
        if (self.watchdog) |t| t.join();
        transport.shutdownConn(self.conn, self.io);
        self.conn.close(self.io);
        self.thread.join();
        self.listener.deinit(self.io);
        transport.unlink(self.io, self.client_path);
        self.stub.deinit();
        self.alloc.free(self.rbuf);
        self.alloc.free(self.wbuf);
        self.alloc.free(self.client_path);
        self.alloc.destroy(self.side);
        self.alloc.destroy(self);
    }

    fn send(self: *E2E, line: []const u8) !void {
        try self.writer.interface.writeAll(line);
        try self.writer.interface.writeByte('\n');
        try self.writer.interface.flush();
    }

    /// One line from the slot, or an error that says which kind of silence
    /// this was.
    fn recv(self: *E2E) ![]const u8 {
        const line = self.reader.interface.takeDelimiter('\n') catch |err| {
            return self.blame(err);
        };
        return line orelse self.blame(error.ClientStreamClosed);
    }

    /// Turn "the stream ended" into one of the two things it can mean.
    ///
    /// `DeadlineExpired` is **not** a claim that the code under test is
    /// fine. It is a claim that this run does not know, which is the honest
    /// answer when the clock ran out -- and it is a different sentence from
    /// the one a genuine protocol failure prints, which is the entire point.
    fn blame(self: *E2E, err: anyerror) anyerror {
        if (!self.watchdog_fired.load(.acquire)) return err;
        std.debug.print(
            "\nmcp-slot e2e: the {d}s deadline expired and cut the " ++
                "connection. This run proves nothing either way -- check " ++
                "whether anything else was building at the time before " ++
                "reading it as a protocol failure.\n",
            .{deadline_ms / 1000},
        );
        return error.DeadlineExpired;
    }
};

/// Wait, briefly, for the busy-loop floor to have run at least once.
///
/// # Why this is a wait and not a read
///
/// 🔬 Written first as a plain `expect(floor_hits >= 1)` next to the first
/// tool list, it failed -- and then passed when debug printing was added,
/// which is the signature of a race rather than a defect. The watcher is a
/// separate thread; whether it has completed its first `persona_wait` by
/// the time the client has sent two requests is a question about
/// scheduling, and the answer changes with how busy the machine is.
///
/// **That is exactly the failure shape this round has been warning about**:
/// on a machine also running somebody's rebuild, a timing-dependent
/// assertion goes red and the red is indistinguishable from a real one. So
/// it is bounded-wait rather than instant-read, and the bound is generous
/// on purpose -- the thing being detected (a floor that never executes at
/// all) does not become true after three seconds.
fn expectFloorRan(fx: *E2E) !void {
    var waited: u64 = 0;
    while (waited < 3000) {
        if (fx.side.floor_hits.load(.acquire) >= 1) return;
        fx.io.sleep(.fromNanoseconds(20 * std.time.ns_per_ms), .awake) catch {};
        waited += 20;
    }
    std.debug.print(
        "\nthe min_wait_ms floor never ran: either it is dead code again, " ++
            "or nothing asked. Both are worth knowing; neither is this " ++
            "test being slow.\n",
        .{},
    );
    return error.FloorNeverRan;
}

fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

test "mcp-slot e2e: a withheld slot never starts its upstream, and a grant starts it without renaming a tool" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!transport.available) return error.SkipZigTest;

    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const sentinel = try std.fmt.allocPrint(alloc, "/tmp/pg-up-{x}.touched", .{&raw});
    defer {
        std.Io.Dir.cwd().deleteFile(io, sentinel) catch {};
        alloc.free(sentinel);
    }

    const argv: []const []const u8 = &.{ "/bin/sh", "-c", upstream_script, "upstream", sentinel };

    // Start withheld: the persona this terminal wears does not include
    // `argus`.
    var fx = E2E.start(alloc, io, false, argv) catch return error.SkipZigTest;
    defer fx.deinit();

    // -- withheld ------------------------------------------------------

    try fx.send(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}
    );
    const init_reply = try fx.recv();
    // Answered here, not by an upstream -- there is no upstream.
    try testing.expect(std.mem.indexOf(u8, init_reply, "polter:argus") != null);
    try testing.expect(std.mem.indexOf(u8, init_reply, "stub-upstream") == null);

    try fx.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    );
    const empty = try fx.recv();
    try testing.expect(std.mem.indexOf(u8, empty, "\"tools\":[]") != null);

    // **The assertion the empty list cannot make.** A tool list with
    // nothing in it is equally what a started-and-silent upstream
    // produces; only the sentinel says the process was never there.
    try testing.expect(!exists(io, sentinel));

    // And the control for it: the slot really did ask, over the real
    // socket, rather than defaulting to empty because nothing answered.
    try testing.expect(fx.stub.asked.load(.acquire) >= 1);

    // -- the user picks a persona that has argus ------------------------

    fx.stub.setWanted(true);

    // Arrives unprompted, on a stream the client is not writing to. This
    // is the whole mechanism of a hot change.
    const notice = try fx.recv();
    try testing.expect(
        std.mem.indexOf(u8, notice, "notifications/tools/list_changed") != null,
    );

    try fx.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    );
    const listed = try fx.recv();

    // **Unrenamed.** The name the upstream published is the name that
    // reaches the client -- no prefix, no namespace, nothing that would
    // make the upstream's own documentation wrong.
    try testing.expect(std.mem.indexOf(u8, listed, "\"argus_recon\"") != null);
    try testing.expect(std.mem.indexOf(u8, listed, "polter_argus_recon") == null);
    try testing.expect(std.mem.indexOf(u8, listed, "polter:argus_recon") == null);

    // Now it exists, which is the other half of the sentinel assertion:
    // without this, "never created" above would also pass for a script
    // that could not run at all.
    try testing.expect(exists(io, sentinel));

    // -- and taken away again ------------------------------------------

    fx.stub.setWanted(false);

    const notice2 = try fx.recv();
    try testing.expect(
        std.mem.indexOf(u8, notice2, "notifications/tools/list_changed") != null,
    );

    try fx.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    );
    const empty2 = try fx.recv();
    try testing.expect(std.mem.indexOf(u8, empty2, "\"tools\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, empty2, "argus_recon") == null);

    // **The busy-loop floor really ran**, and it could only be asserted
    // once the stub was replaced: `rpc.zig`'s unparked arm answers a
    // `persona_wait` at once, which is the case the floor exists for. The
    // hand-written stub held its wait for 1500 ms, so the branch was
    // unreachable and this assertion would have been false in the other
    // direction -- a floor nobody had ever executed, sitting in a test
    // that passed.
    try expectFloorRan(fx);
}

test "mcp-slot e2e: an upstream that will not start is not an empty tool list" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!transport.available) return error.SkipZigTest;

    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Granted by the persona, and there is no such program.
    const argv: []const []const u8 = &.{"/nonexistent/polter-upstream-that-is-not-there"};

    var fx = E2E.start(alloc, io, true, argv) catch return error.SkipZigTest;
    defer fx.deinit();

    try fx.send(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}
    );
    _ = try fx.recv();

    try fx.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    );
    const listed = try fx.recv();

    // The distinction roles.md's second open question asks for, asserted
    // on the bytes a client actually receives rather than on a state enum.
    try testing.expect(
        std.mem.indexOf(u8, listed, "polter_slot_unavailable") != null,
    );
    try testing.expect(std.mem.indexOf(u8, listed, "\"tools\":[]") == null);

    // A calling agent reads the description, so the description is what
    // has to carry the difference -- and it has to say which of the two
    // silences this is, in so many words.
    try testing.expect(std.mem.indexOf(u8, listed, "角色") != null);
}
