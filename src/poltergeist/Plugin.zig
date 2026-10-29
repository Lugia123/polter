//! Running somebody else's script on our behalf.
//!
//! A plugin is a directory with a `plugin.json` and an executable. **This
//! file is the declaration side of one**: it reads that manifest, works out
//! which file this system would run and what to start it with, and holds
//! what the user has said about the plugin. It never starts a process and
//! never talks to one -- `Resident.zig` owns the running plugin and the
//! protocol it speaks.
//!
//! What is here:
//!
//!   * **The manifest.** `load` parses `plugin.json` into a `Manifest`,
//!     taking `exec_<os>` ahead of `exec` and making the path absolute, so
//!     that running it never depends on where Polter happens to be.
//!   * **What starts a file of that kind.** `LaunchKind` and `launchArgv`
//!     answer "what does this system run a `.ps1` with". A plugin that
//!     declares only a file nothing here can start is `runnable = false`,
//!     which is settled at load rather than discovered at spawn.
//!   * **The vocabulary a manifest declares in**: `Event`, `Wants`,
//!     `ParamSpec`.
//!   * **The user's side.** `Settings` is the one file that says whether a
//!     plugin is on and what its parameters are; a `Param`'s value may be a
//!     reference for `secret.zig` to resolve rather than the secret itself.
//!
//! **Why a process and not a library.** These are scripts people copy off
//! the internet. They will hang, segfault, and flood stdout, and none of
//! that may take the terminal down with it -- a process boundary is the
//! only place that guarantee comes free. And it means any language: a
//! twenty-line `curl` script is a complete plugin, where requiring Zig
//! would mean the extension point does not exist. See
//! `dev-docs/poltergeist/plugins.md` for the routes that were rejected.
//!
//! **Nothing here knows what a plugin is for.** Which events one asked for
//! is a name this file parses and stores; what those events mean, and what
//! travels on the wire, is decided a layer up. That split is what lets a
//! new kind of event be added without this file learning what it is for --
//! and it is why `timeout_ms` is a number declared here and enforced by
//! whoever does the running.

const Plugin = @This();

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");
const token_says = @import("token_says.zig");

const log = std.log.scoped(.poltergeist);

/// Longest a plugin may take before it is killed.
///
/// Something has to bound this. A plugin that cannot reach the network
/// will sit there, and the scenario this feature exists for is one where
/// nobody is watching to notice.
const default_timeout_ms: u64 = 10 * std.time.ms_per_s;

/// Most parameters one manifest may declare.
///
/// The list is copied into every `plugin_list` reply, which an agent reads,
/// so a bound on it is a bound on that reply. The manifest itself is only
/// capped at 64KB, and that is room for hundreds of one-character property
/// names -- a broken generator or a hostile file should not be able to
/// spend somebody's context on them.
const max_specs: usize = 64;

/// One kind of thing that happens, as a manifest may subscribe to it.
///
/// **This is not `Kind`.** What a plugin *is* used to be one of three
/// values that each decided a lifetime and a contract at once, so every
/// place that switched on it had three branches and a fourth would be
/// forgotten -- which happened twice, the second time in the comment left
/// by the first. There is one lifetime and one contract now, and what
/// separates two plugins is only which of these they asked for. A plugin
/// that asks for two gets both on one stream; a plugin that asks for none
/// is not started, because there would be nothing to hand it.
///
/// The names here are the wire names, spelled with a dot where the Zig
/// identifier cannot have one. Every member has to exist as something
/// `Feed` can actually publish: a name a manifest may write and nothing
/// will ever send is a subscription that looks live and is not.
pub const Event = enum {
    /// Something was said in a chat group. This is what `archive` was.
    chat,

    /// A terminal has gone quiet and somebody should be told. This is what
    /// `notify` was.
    terminal_quiet,

    /// Here is what Polter is; make an agent runtime able to see it. This
    /// is what `provision` was.
    provision,

    /// The name a manifest writes.
    pub fn wireName(self: Event) []const u8 {
        return switch (self) {
            .chat => "chat",
            .terminal_quiet => "terminal.quiet",
            .provision => "provision",
        };
    }

    /// The event that name refers to, or null when it is not one of ours.
    ///
    /// Null rather than an error: a manifest written for a later build may
    /// name an event this one has never heard of, and the safe reading of
    /// that is "this build will not send it" -- not "this plugin does not
    /// load".
    pub fn parse(text: []const u8) ?Event {
        inline for (@typeInfo(Event).@"enum".fields) |f| {
            const e: Event = @enumFromInt(f.value);
            if (std.mem.eql(u8, e.wireName(), text)) return e;
        }
        return null;
    }

    /// The event whose Zig identifier is `text` (`terminal_quiet`), when
    /// that is not also its wire name. Only for saying what was meant: a
    /// manifest is never subscribed by this spelling.
    pub fn parseZigName(text: []const u8) ?Event {
        inline for (@typeInfo(Event).@"enum".fields) |f| {
            const e: Event = @enumFromInt(f.value);
            if (!std.mem.eql(u8, f.name, e.wireName()) and std.mem.eql(u8, f.name, text)) return e;
        }
        return null;
    }
};

/// What a plugin says it needs.
///
/// **Declared so the host has something to refuse against**, not as a
/// certificate of good behaviour. That stance is unchanged; what changed is
/// how many of these are refusals rather than disclosures.
///
/// `events`, `groups` and `calls` are **enforced**, completely:
///
///   - `events` decides what the plugin is handed. It is not fed a kind it
///     did not ask for, so a chat archive never sees a notification and a
///     notifier never sees the chat log.
///   - `groups` decides which chat groups may appear in what it is handed,
///     and a plugin has no second channel to the log.
///   - `calls` decides which tool methods it may call. See `mayCall`.
///
/// `network` and `exec` are declaration and disclosure only -- they are
/// what a user reads before installing, and what an audit has to go on.
/// They are **not** a sandbox and nothing here stops a plugin doing either.
/// Saying that plainly is the point: `"network": false` must never be read
/// as "it cannot reach the network". Real isolation has to be designed
/// together with signing; see `dev-docs/poltergeist/plugins.md`.
///
/// The line between the two halves is not how dangerous the thing is. It is
/// **whether the host stands on the path**. Every event goes through
/// `Feed`, every group through the batch writer, every tool call through
/// the socket this process is listening on -- those are chokepoints, and a
/// declaration at a chokepoint that is not enforced is a decision to hold a
/// gate open. A plugin's own `connect(2)` passes through nothing of ours,
/// so there is no gate there to hold either way.
///
/// Everything borrowed here comes from the arena the manifest was loaded
/// into. Anything that outlives one pass over the plugin directory has to
/// copy it: the arena is rebuilt whole every time the plugin list is.
pub const Wants = struct {
    /// Which kinds of event this plugin is handed. Empty means none, which
    /// is what a manifest that declares nothing gets -- and a plugin with
    /// nothing to be handed is not started at all.
    events: []const Event = &.{},

    /// Which tool methods this plugin may call over the socket, by name.
    ///
    /// Empty means none: a plugin that declares no calls gets a token and a
    /// socket path all the same, and every method it tries is refused. That
    /// is the direction a missing declaration has to fail in.
    calls: []const []const u8 = &.{},

    /// Which chat groups may appear in what this plugin is given. A single
    /// element `"*"` means all of them. Empty means none.
    groups: []const []const u8 = &.{},

    network: bool = false,

    exec: []const []const u8 = &.{},

    /// Whether `name` is a group this plugin asked for.
    ///
    /// Whole-string equality, and `"*"` counts only as an entire element.
    /// No wildcard language, because one needs escaping rules and group
    /// names come out of a chat window and may hold anything.
    pub fn allows(self: Wants, name: []const u8) bool {
        for (self.groups) |g| {
            if (std.mem.eql(u8, g, "*")) return true;
            if (std.mem.eql(u8, g, name)) return true;
        }
        return false;
    }

    /// Whether this plugin asked to be handed `e`.
    ///
    /// **No `"*"` here, deliberately**, and this is the one place the two
    /// enforced lists differ. A group is a name the user made up and there
    /// is no way to enumerate the ones that do not exist yet, so `"*"` is
    /// the only way to say "whatever I am in". The events are a closed set
    /// written down in this file: a plugin can name every one it wants, and
    /// a `"*"` would mean "and every one added after I was written", which
    /// is a subscription to code that does not exist.
    pub fn subscribes(self: Wants, e: Event) bool {
        for (self.events) |w| if (w == e) return true;
        return false;
    }

    /// Whether this plugin declared that it calls `method`.
    ///
    /// **Checked, not merely listed**, and it is checked *before* the
    /// ordinary authorisation. The two cannot conflict, because this one
    /// never grants: a call has to pass this list **and** the reachability
    /// rule, so what a plugin declares can only ever narrow what it may do.
    /// A method nobody has heard of is refused here, which is also the
    /// answer for a method name that is simply misspelled in the manifest.
    ///
    /// Exact names, no wildcard. The declaration is what a user reads
    /// before installing, and `"*"` would make that reading worthless
    /// exactly where it matters most.
    pub fn mayCall(self: Wants, method: []const u8) bool {
        for (self.calls) |c| if (std.mem.eql(u8, c, method)) return true;
        return false;
    }

    /// True when nothing was asked for, so there is nothing to hand over.
    /// The host says so rather than running a plugin it would then feed
    /// silence for ever.
    pub fn empty(self: Wants) bool {
        return self.events.len == 0;
    }

    /// True when this plugin subscribes to something group-shaped and named
    /// no groups, which is a manifest that will be fed nothing it is
    /// waiting for. Worth saying out loud, and not worth refusing over: the
    /// same plugin may be subscribed to `provision` as well, and that half
    /// works.
    pub fn groupless(self: Wants) bool {
        return self.subscribes(.chat) and self.groups.len == 0;
    }
};

/// One parameter as the plugin declares it.
///
/// Read out of the manifest's `params` JSON Schema, which is where a
/// plugin author already writes this down -- a second place to say it
/// would drift from the first.
pub const ParamSpec = struct {
    name: []const u8,
    title: []const u8 = "",
    description: []const u8 = "",
    required: bool = false,

    /// Declared `"secret": true`. This is the plugin author saying "this
    /// one is a credential", and it is the only thing that decides it --
    /// guessing from the name would get `url` wrong in both directions.
    /// The tool surface will not write a plaintext value into one.
    secret: bool = false,

    /// Declared `"to_session": true`: a value that belongs to a **session
    /// this plugin starts**, not to the plugin's own resident half
    /// (task 2235).
    ///
    /// **The author's declaration, and the reason there is one.** These are
    /// the only parameters `agent_cli.launchParams` puts into a `launch`
    /// request, and that request travels in an adapter's **argv** -- where
    /// `ps` can read it and a crash report will keep it. Sending every
    /// parameter of every plugin down that road is how a resident plugin's
    /// API key ends up on a process list; sending only the ones whose
    /// author said "this one is for a session" is how it does not.
    ///
    /// A value that is a `secret.zig` reference (`env:`, `keychain:`,
    /// `cmd:`, `file:`) is **skipped there rather than resolved**: a
    /// reference resolved into an argv is the plaintext it was avoiding.
    /// A parameter read from a file as a literal is one whose author meant
    /// a literal -- this annotation is not a way to smuggle a secret into
    /// a command line, and a plugin that needs one has to fetch it itself.
    to_session: bool = false,

    /// What a JSON Schema `enum` allows, empty when the value is open.
    /// A closed set is the one case where a configured value may be shown
    /// back to an agent: it cannot be holding a password.
    choices: []const []const u8 = &.{},

    /// Whether `value` is one this parameter takes. An open parameter
    /// takes anything, so a spec with no `enum` allows everything -- the
    /// alternative would have a missing annotation refuse every value.
    pub fn allows(self: ParamSpec, value: []const u8) bool {
        if (self.choices.len == 0) return true;
        for (self.choices) |c| if (std.mem.eql(u8, c, value)) return true;
        return false;
    }
};

/// A plugin as declared by its manifest.
///
/// Everything is owned by `arena`, which the loader hands over whole.
pub const Manifest = struct {
    /// Unique, and the name the config refers to.
    key: []const u8,

    /// For a person reading a list of them.
    name: []const u8 = "",

    /// Absolute path to the executable this system would run.
    ///
    /// Resolved from `exec_<os>` when the manifest declares one for this
    /// system, and from `exec` otherwise. See `launchKindFor`.
    exec: []const u8,

    /// Whether this system can start `exec` at all.
    ///
    /// **A third state, and it belongs at load rather than at spawn.** A
    /// plugin that declares only a `.sh` is not broken and its manifest is
    /// not malformed -- it simply has nothing to run here, which is a static
    /// fact known while the manifest is being read. Discovering it at spawn
    /// instead turns it into a restart loop, and `error.BadManifest` would
    /// file it next to "somebody typed the JSON wrong". Same reasoning as the
    /// `absent` / `provisioned` / `failed` split the provisioning plugins
    /// use: **"nothing to do here" and "something went wrong" must not look
    /// alike.**
    runnable: bool = true,

    timeout_ms: u64 = default_timeout_ms,

    /// Everything declared in `wants`. Absent from the manifest reads as
    /// wanting nothing; see `Wants`.
    wants: Wants = .{},

    /// Everything declared under `params.properties`. Empty when the
    /// manifest declares none, and that is meaningful: a plugin with no
    /// declared parameters has none that the tool surface may set.
    params: []const ParamSpec = &.{},

    /// Present when this plugin says it manages an agent CLI -- see
    /// `AgentCli`. Absent for every other plugin, and for one whose section
    /// did not read, which is logged.
    agent_cli: ?AgentCli = null,

    /// What this plugin's CLI says about itself in its terminal's title --
    /// see `TitleSays`. Empty for a plugin that declares nothing, which is
    /// every plugin but the ones for CLIs that have no hooks to say it with.
    title_says: TitleSays = .none,

    /// What this plugin's CLI shows on its screen while a permission box is
    /// up -- see `ScreenSays`. Empty for a plugin that declares nothing.
    screen_says: ScreenSays = .none,

    /// Whether this plugin's CLI says through its hooks that it is waiting
    /// on an approval (task 1682). `"hooks_report_approval": false` is a
    /// CLI whose hooks are live and have no event for it -- Antigravity's
    /// six have none -- so its `screen_says` is read while its hooks are
    /// live, which for every other CLI it is not (`screenApprovalFor`).
    /// True when the manifest says nothing: a CLI with an approval hook
    /// (Claude Code's `PermissionRequest`, Codex's) or with no hooks at all.
    hooks_report_approval: bool = true,

    /// What this plugin's CLI shows before an agent is reachable in it --
    /// see `StartupSays`. Empty for a plugin that declares nothing.
    startup_says: StartupSays = .none,

    /// What this plugin's CLI leaves on its screen when a permission box
    /// was declined without a word -- see `DeclinedSays`. Empty for a
    /// plugin that declares nothing.
    declined_says: DeclinedSays = .none,

    /// Where this plugin's CLI says how many tokens a session spent, and
    /// what those numbers are -- see `token_says.TokenSays` and that file's
    /// header for why the kind matters. Null for a plugin that declares
    /// nothing, which is every CLI whose usage Polter cannot read.
    token_says: ?token_says.TokenSays = null,

    /// The parameter by that name, if the manifest declares one.
    pub fn param(self: Manifest, name: []const u8) ?ParamSpec {
        for (self.params) |p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }
};

/// What a CLI says about itself in its terminal's title (task 1656).
///
/// ```json
/// "title_says": { "awaiting_approval": { "starts_with": ["[ ! ] Action Required"] } }
/// ```
///
/// **For a CLI with no hooks, and for the one state its screen cannot
/// tell.** Codex 0.163 waiting on an approval box keeps re-colouring the
/// bullet in front of the call it is asking about (measured: 270 redraws in
/// 55s, six greys on a two-second cycle), so its screen never goes still and
/// no quiet report ever comes -- but it also writes `[ ! ] Action Required
/// | ...` into the title, alternating with `[ . ] ...` once a second, for as
/// long as the box is up. The plugin declares that, the core reads it, and
/// nothing about any one CLI is written into the core.
///
/// A prefix, not a pattern: what a CLI writes there is a fixed string
/// followed by its own context, and a prefix is the whole of what has been
/// measured.
pub const TitleSays = struct {
    /// A title beginning with any of these: the CLI is waiting for a
    /// person to approve something.
    awaiting_approval: []const []const u8,

    pub const none: TitleSays = .{ .awaiting_approval = &.{} };

    /// Most prefixes one plugin may declare, and the most bytes in one.
    pub const max_prefixes = 8;
    pub const max_prefix_bytes = 64;

    pub fn awaitsApproval(self: TitleSays, title: []const u8) bool {
        for (self.awaiting_approval) |prefix| {
            if (std.mem.startsWith(u8, title, prefix)) return true;
        }
        return false;
    }
};

/// The key of the first plugin whose declared title says this one is
/// waiting on an approval, or null when none does.
pub fn titleAwaitsApproval(manifests: []const Manifest, title: []const u8) ?[]const u8 {
    for (manifests) |m| {
        if (m.title_says.awaitsApproval(title)) return m.key;
    }
    return null;
}

/// What a CLI shows on its screen while it waits for a person to approve
/// something (task 1668).
///
/// ```json
/// "screen_says": { "awaiting_approval": { "contains": ["Would you like to run the following command?"] } }
/// ```
///
/// **For the one question nothing else answers**: `terminal_answer_prompt`
/// asked without the moments of the prompt it is answering, about a
/// terminal whose agent has said nothing -- no hooks, no title. It used to
/// press its keys anyway, and a return pressed at no box at all is a
/// return into whatever is there: it once chose the default of an upgrade
/// dialog (on the test machine). Now it presses only when the screen
/// shows a box its CLI's plugin declares; with no declaration it refuses.
///
/// Text, fixed, from the CLI's own source or measured on its screen; looked
/// for only in the bottom `rows` rows, where a box is drawn -- the same
/// words higher up are scrollback, a box already answered.
pub const ScreenSays = struct {
    /// A screen whose bottom rows contain any of these: a box is up.
    awaiting_approval: []const []const u8,

    /// The key that moves a box's highlight to the next option
    /// (`next_option`, task 1777): `terminal_answer_prompt` walks to the
    /// option it is asked for with it. Claude Code's, Codex's and
    /// Antigravity's boxes list their options one under another, so down;
    /// opencode's puts them in a row (`Allow once  Allow always  Reject`,
    /// `routes/session/permission.tsx` at v1.2.10: left and right move it),
    /// and a down there moves nothing -- the return then takes the first
    /// option whatever was asked for, and says it took that one.
    next_option: NextOption,

    pub const none: ScreenSays = .{ .awaiting_approval = &.{}, .next_option = .arrow_down };

    pub const max_texts = 8;
    pub const max_text_bytes = 64;

    /// How many rows from the bottom, after trailing empty ones, are
    /// looked at.
    pub const rows = 16;

    pub fn declared(self: ScreenSays) bool {
        return self.awaiting_approval.len > 0;
    }

    pub fn awaitsApproval(self: ScreenSays, screen: []const u8) bool {
        return self.approvalSaid(screen) != null;
    }

    /// The declared text that says a box is up on `screen`, or null.
    pub fn approvalSaid(self: ScreenSays, screen: []const u8) ?[]const u8 {
        const tail = bottomRows(screen, rows);
        for (self.awaiting_approval) |text| {
            if (std.mem.indexOf(u8, tail, text) != null) return text;
        }
        return null;
    }
};

/// What `ScreenSays.next_option` may name: the two arrows a list of
/// options is walked with. Each is a key `terminal_key` takes by the same
/// name.
pub const NextOption = enum {
    arrow_down,
    arrow_right,

    pub fn key(self: NextOption) []const u8 {
        return @tagName(self);
    }
};

/// The key that walks a box to its next option in a terminal whose CLI is
/// `cli`: what its plugin declares, and down for a CLI that declares none
/// or is not known -- which is what every box was walked with before
/// (task 1777).
pub fn nextOptionKey(manifests: []const Manifest, cli: ?[]const u8) []const u8 {
    const c = cli orelse return NextOption.arrow_down.key();
    for (manifests) |m| {
        if (std.mem.eql(u8, m.key, c)) return m.screen_says.next_option.key();
    }
    return NextOption.arrow_down.key();
}

/// What a CLI shows on its screen between being started and an agent
/// being reachable in it (task 1682).
///
/// ```json
/// "startup_says": { "blocks": ["Do you trust the contents of this project?"],
///                   "ready_says": ["? for shortcuts"], "ready_without_agent": true }
/// ```
///
/// **For a CLI that connects to Polter only once it is asked something.**
/// A line is typed into a terminal only when an agent is connected from it
/// (`agentPresent`), because at a bare shell the shell would run it.
/// Antigravity starts its MCP servers -- Polter's among them -- with the
/// first prompt, not before (measured on agy 1.4.0), so by that rule the
/// first line it is sent can never be typed. `ready_without_agent` says
/// so, and `ready_says` is how its input box is known on the screen: the
/// two together let the first line in.
///
/// `blocks` is a question the CLI asks before anything else -- the folder
/// trust box -- whose answer is a security decision that belongs to the
/// person: **a line is never typed while it is up**, since its return would
/// choose the box's default. Any CLI may declare its own (task 1746): while
/// one is up, a launch's wait for its agent does not run out, and the
/// control room and `terminal_list` say the person has a question to answer.
///
/// `tools_from_second_turn` says the CLI's first turn has none of Polter's
/// tools: Antigravity starts its MCP servers with the first prompt and lists
/// their tools from the turn after (measured on agy 1.4.2, task 1740). So
/// what a supervisor started from the control room is to do first is typed
/// as a second message, once the first turn is over (`firstTurnOver`).
pub const StartupSays = struct {
    blocks: []const []const u8,
    ready_says: []const []const u8,
    ready_without_agent: bool,
    tools_from_second_turn: bool,

    pub const none: StartupSays = .{ .blocks = &.{}, .ready_says = &.{}, .ready_without_agent = false, .tools_from_second_turn = false };

    pub fn declared(self: StartupSays) bool {
        return self.blocks.len > 0 or self.ready_says.len > 0;
    }

    pub const Verdict = enum {
        /// A box that must not be typed into is up.
        blocked,
        /// The CLI's input box is showing and nothing blocks it.
        ready,
        /// Neither: starting, or not this CLI any more.
        neither,
    };

    /// The declared text of the question that is up, or null when none is.
    pub fn blockSaid(self: StartupSays, screen: []const u8) ?[]const u8 {
        const tail = bottomRows(screen, ScreenSays.rows);
        for (self.blocks) |text| {
            if (containsWrapped(tail, text)) return text;
        }
        return null;
    }

    pub fn verdict(self: StartupSays, screen: []const u8) Verdict {
        const tail = bottomRows(screen, ScreenSays.rows);
        for (self.blocks) |text| {
            if (containsWrapped(tail, text)) return .blocked;
        }
        for (self.ready_says) |text| {
            if (containsWrapped(tail, text)) return .ready;
        }
        return .neither;
    }

    /// Whether the CLI's first turn is over, so a line meant for its second
    /// may be typed. `said` is its hooks' word when they speak (the turn
    /// ended), null when they do not. **Its input box must show as well,
    /// with nothing blocking it, whatever the hooks say** (task 1746, round
    /// two): the turn's end was heard and the line typed at once, and once
    /// in three agy took none of it -- its box was not back yet.
    pub fn firstTurnOver(self: StartupSays, said: ?bool, screen: []const u8) bool {
        if (said) |over| if (!over) return false;
        return self.verdict(screen) == .ready;
    }
};

/// What a CLI leaves on its screen when its permission box was declined
/// and no hook said so (task 2021).
///
/// ```json
/// "declined_says": { "contains": ["Interrupted · What should Claude do instead?", "User rejected update to"],
///                    "turn_from": "❯ ", "box": ["Esc to cancel"],
///                    "turn_done_starts": "✻ ", "turn_done_has": " · done " }
/// ```
///
/// **For the one way out of a box no hook reports.** Claude Code's box
/// declined with Esc, or with No and nothing typed, ends the turn and fires
/// nothing (#879): the state stays `awaiting_approval`, the column and the
/// pane say "awaiting approval" for as long as the terminal is open, and
/// every line typed into it is refused with `ApprovalOnScreen` although the
/// person is long out of the box. Declined with something typed, the turn
/// goes on and its hooks say so; approved, likewise.
///
/// Read only after the last prompt line (`turn_from` and something after
/// it): a turn's marks stay on the screen under the next one, and a box
/// declined two turns ago is not this one. When no prompt line is on the
/// screen at all, the prompt has scrolled off above it and the whole screen
/// is after it. Within that, all three: one of `contains`, none of `box`
/// (a box still up -- the next one in the same turn), and the line the CLI
/// draws when a turn is over (`turn_done_starts` at its start and
/// `turn_done_has` in it). That line comes after every turn, declined or
/// not, so on its own it says nothing; it is what says the decline is the
/// end and not something the agent is about to go on from.
///
/// Measured with Claude Code 2.1.304 on the mac test account, 2026-10-22:
/// six declines and one approval, the screen text in each (task 2021).
pub const DeclinedSays = struct {
    contains: []const []const u8,
    turn_from: []const u8,
    box: []const []const u8,
    turn_done_starts: []const u8,
    turn_done_has: []const u8,

    pub const none: DeclinedSays = .{ .contains = &.{}, .turn_from = "", .box = &.{}, .turn_done_starts = "", .turn_done_has = "" };

    pub fn declared(self: DeclinedSays) bool {
        return self.contains.len > 0 and self.turn_from.len > 0 and
            self.turn_done_starts.len > 0 and self.turn_done_has.len > 0;
    }

    /// The declared text that says the box on `screen` was declined and
    /// the turn is over, or null.
    pub fn declinedSaid(self: DeclinedSays, screen: []const u8) ?[]const u8 {
        if (!self.declared()) return null;
        const turn = self.lastTurn(screen);
        var done = false;
        var it = std.mem.splitScalar(u8, turn, '\n');
        while (it.next()) |line| {
            for (self.box) |b| if (std.mem.indexOf(u8, line, b) != null) return null;
            const lead = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, lead, self.turn_done_starts) and
                std.mem.indexOf(u8, lead, self.turn_done_has) != null) done = true;
        }
        if (!done) return null;
        for (self.contains) |text| if (std.mem.indexOf(u8, turn, text) != null) return text;
        return null;
    }

    /// What follows the last line that is a prompt: `turn_from` at its
    /// start and something after it. The input box at the bottom is the
    /// same mark with nothing after it, and is not one.
    fn lastTurn(self: DeclinedSays, screen: []const u8) []const u8 {
        var from: usize = 0;
        var at: usize = 0;
        var it = std.mem.splitScalar(u8, screen, '\n');
        while (it.next()) |line| {
            const end = at + line.len;
            defer at = end + 1;
            // At the start of the row: the same mark indented is a box's
            // highlighted option, not a prompt.
            if (!std.mem.startsWith(u8, line, self.turn_from)) continue;
            // NBSP is what some prompts draw where a space would be.
            const rest = std.mem.trim(u8, line[self.turn_from.len..], " \t\r\xc2\xa0");
            if (rest.len > 0) from = @min(end + 1, screen.len);
        }
        return screen[from..];
    }
};

/// What says a box was declined on the screen of a terminal whose CLI is
/// `cli`, or null when it declares nothing to go by.
pub fn declinedFor(manifests: []const Manifest, cli: []const u8) ?DeclinedSays {
    for (manifests) |m| {
        if (!std.mem.eql(u8, m.key, cli)) continue;
        if (!m.declined_says.declared()) return null;
        return m.declined_says;
    }
    return null;
}

/// What `cli` shows on its way up, for a terminal with no agent connected
/// yet, or null when it declares nothing to go by -- in which case such a
/// terminal is not typed into, as before.
pub fn startupFor(manifests: []const Manifest, cli: []const u8) ?StartupSays {
    for (manifests) |m| {
        if (!std.mem.eql(u8, m.key, cli)) continue;
        if (!m.startup_says.declared()) return null;
        return m.startup_says;
    }
    return null;
}

/// Whether `needle` is in `hay` once neither has any white space: a
/// sentence a narrow terminal broke over two rows is still that sentence
/// (task 1787). agy wraps its own text at a word, so the space becomes a
/// line break -- "Do you trust the contents of this" over "project?" in a
/// narrow split, read off one -- and a terminal wraps a long word inside
/// it, so the break can fall anywhere. Both match. A declared text is a
/// whole sentence of eight bytes or more (`startupSaysOf`), and the run of
/// characters it comes to with its spaces taken out does not turn up by
/// accident; only the sentence itself, broken, makes it.
///
/// Only for `StartupSays`: an approval box wraps too, but whether Codex's
/// and Claude Code's do in a narrow split is to be measured first.
fn containsWrapped(hay: []const u8, needle: []const u8) bool {
    var n_len: usize = 0;
    for (needle) |c| {
        if (!isBlank(c)) n_len += 1;
    }
    if (n_len == 0) return false;
    var start: usize = 0;
    while (start < hay.len) : (start += 1) {
        if (isBlank(hay[start])) continue;
        var h = start;
        var n: usize = 0;
        var matched: usize = 0;
        while (matched < n_len) {
            while (n < needle.len and isBlank(needle[n])) n += 1;
            while (h < hay.len and isBlank(hay[h])) h += 1;
            if (h == hay.len or hay[h] != needle[n]) break;
            h += 1;
            n += 1;
            matched += 1;
        }
        if (matched == n_len) return true;
    }
    return false;
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// The last `n` rows of `screen` that end at its last row with anything
/// on it.
fn bottomRows(screen: []const u8, n: usize) []const u8 {
    const end = std.mem.trimEnd(u8, screen, " \t\r\n").len;
    var start = end;
    var seen: usize = 0;
    while (start > 0) : (start -= 1) {
        if (screen[start - 1] == '\n') {
            seen += 1;
            if (seen == n) break;
        }
    }
    return screen[start..end];
}

/// Whether a box is up on `screen`, by what the plugins declare, for a
/// terminal whose CLI is `cli` when that is known.
pub const ScreenVerdict = enum {
    /// A declared box is on the screen.
    box,
    /// The CLI declares its boxes and none is on the screen.
    no_box,
    /// Nothing declared can say: the CLI is not known and no declared box
    /// is showing, or the CLI is known and declares nothing.
    unknown,
};

/// What says a box is up on the screen of a terminal whose CLI is `cli`
/// and whose hooks are live, or null when the screen is not to be read for
/// it: its hooks say so themselves, or it declares nothing to look for.
/// **Only a CLI that declares `hooks_report_approval: false`** -- so a
/// Claude Code or Codex terminal is never read for this (task 1682).
pub fn screenApprovalFor(manifests: []const Manifest, cli: []const u8) ?ScreenSays {
    for (manifests) |m| {
        if (!std.mem.eql(u8, m.key, cli)) continue;
        if (m.hooks_report_approval or !m.screen_says.declared()) return null;
        return m.screen_says;
    }
    return null;
}

pub fn screenVerdict(manifests: []const Manifest, cli: ?[]const u8, screen: []const u8) ScreenVerdict {
    if (cli) |c| {
        for (manifests) |m| {
            if (!std.mem.eql(u8, m.key, c)) continue;
            if (!m.screen_says.declared()) return .unknown;
            return if (m.screen_says.awaitsApproval(screen)) .box else .no_box;
        }
        return .unknown;
    }
    // Not known which CLI it is: a box some plugin declares, showing, is a
    // box; its absence says nothing about a CLI that declares none.
    for (manifests) |m| {
        if (m.screen_says.awaitsApproval(screen)) return .box;
    }
    return .unknown;
}

fn screenSaysOf(arena: Allocator, key: []const u8, obj: std.json.ObjectMap) Allocator.Error!ScreenSays {
    const section = switch (obj.get("screen_says") orelse return .none) {
        .object => |o| o,
        else => {
            log.warn("plugin {s}: screen_says is not an object; ignored", .{key});
            return .none;
        },
    };
    const approval = switch (section.get("awaiting_approval") orelse return .none) {
        .object => |o| o,
        else => {
            log.warn("plugin {s}: screen_says.awaiting_approval is not an object; ignored", .{key});
            return .none;
        },
    };
    const list = switch (approval.get("contains") orelse return .none) {
        .array => |a| a.items,
        else => {
            log.warn("plugin {s}: screen_says.awaiting_approval.contains is not a list; ignored", .{key});
            return .none;
        },
    };
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (list) |item| {
        const text = switch (item) {
            .string => |v| v,
            else => {
                log.warn("plugin {s}: a screen text that is not a string; skipped", .{key});
                continue;
            },
        };
        // Short texts match too much: an empty one, everything. A box's
        // own sentence is what is wanted, so fewer than 8 bytes is refused.
        if (text.len < 8 or text.len > ScreenSays.max_text_bytes or !printable(text)) {
            log.warn("plugin {s}: screen text {s} skipped -- 8 to {d} printable bytes", .{ key, text, ScreenSays.max_text_bytes });
            continue;
        }
        if (out.items.len == ScreenSays.max_texts) {
            log.warn("plugin {s}: more than {d} screen texts; the rest are ignored", .{ key, ScreenSays.max_texts });
            break;
        }
        try out.append(arena, text);
    }
    const next: NextOption = switch (approval.get("next_option") orelse .null) {
        .null => .arrow_down,
        .string => |v| std.meta.stringToEnum(NextOption, v) orelse blk: {
            log.warn("plugin {s}: screen_says.awaiting_approval.next_option {s} is neither arrow_down nor arrow_right; arrow_down", .{ key, v });
            break :blk .arrow_down;
        },
        else => blk: {
            log.warn("plugin {s}: screen_says.awaiting_approval.next_option is not a string; arrow_down", .{key});
            break :blk .arrow_down;
        },
    };
    return .{ .awaiting_approval = out.items, .next_option = next };
}

/// What the manifest declares under `title_says`. Like `agent_cli`, a
/// section that does not read costs the section and is logged: a prefix
/// that matched nothing it should, or everything, would be worse than none.
fn titleSaysOf(arena: Allocator, key: []const u8, obj: std.json.ObjectMap) Allocator.Error!TitleSays {
    const section = switch (obj.get("title_says") orelse return .none) {
        .object => |o| o,
        else => {
            log.warn("plugin {s}: title_says is not an object; ignored", .{key});
            return .none;
        },
    };
    const approval = switch (section.get("awaiting_approval") orelse return .none) {
        .object => |o| o,
        else => {
            log.warn("plugin {s}: title_says.awaiting_approval is not an object; ignored", .{key});
            return .none;
        },
    };
    const list = switch (approval.get("starts_with") orelse return .none) {
        .array => |a| a.items,
        else => {
            log.warn("plugin {s}: title_says.awaiting_approval.starts_with is not a list; ignored", .{key});
            return .none;
        },
    };

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (list) |item| {
        const prefix = switch (item) {
            .string => |v| v,
            else => {
                log.warn("plugin {s}: a title prefix that is not a string; skipped", .{key});
                continue;
            },
        };
        // An empty prefix would match every title there is, and one with a
        // control character can never be a title a terminal shows.
        if (prefix.len == 0 or prefix.len > TitleSays.max_prefix_bytes or !printable(prefix)) {
            log.warn("plugin {s}: title prefix {s} skipped -- 1 to {d} printable bytes", .{ key, prefix, TitleSays.max_prefix_bytes });
            continue;
        }
        if (out.items.len == TitleSays.max_prefixes) {
            log.warn("plugin {s}: more than {d} title prefixes; the rest are ignored", .{ key, TitleSays.max_prefixes });
            break;
        }
        try out.append(arena, prefix);
    }
    return .{ .awaiting_approval = out.items };
}

fn printable(s: []const u8) bool {
    for (s) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// A plugin that manages an agent CLI.
///
/// ```json
/// "agent_cli": { "label": "Claude Code", "bin": "claude",
///                "adapter": "adapter.py", "adapter_windows": "adapter.ps1" }
/// ```
///
/// **This is what makes the role system plugin-driven.** The core does not
/// know what Claude Code is: it knows that some plugin said "I can list a
/// CLI's skills and MCP servers, and I can turn a role into its command
/// line", and it asks that plugin. A new CLI is a new plugin with the same
/// two answers. The protocol is in `agent_cli.zig` and roles.md part
/// eleven.
///
/// The CLI's key is the plugin's key. It has to be a valid persona key as
/// well (`[a-z0-9-]`), because it is written into `personas.json` as the
/// key of that CLI's choices; a plugin whose key is not gets no
/// `agent_cli`, and says so in the log.
pub const AgentCli = struct {
    /// What a person calls the CLI: "Claude Code".
    label: []const u8,

    /// The program it starts, for "is it installed" and nothing else.
    bin: []const u8,

    /// Absolute path of the adapter this system would run, resolved the
    /// same way as `exec`: `adapter_<os>` first, then `adapter`.
    adapter: []const u8,

    /// Whether this system can start `adapter`. Same meaning, and the same
    /// reason for existing, as `Manifest.runnable`.
    runnable: bool,

    /// The environment variables this CLI gives the programs it starts --
    /// Polter's MCP sidecar among them -- by which a CLI started by hand can
    /// be told apart from another (task 1635): `"identify_env":
    /// ["CLAUDE_CODE_SESSION_ID", …]`. **Only these names are ever read
    /// out of a sidecar's environment and sent to Polter**, and only to this
    /// plugin's adapter; an environment also holds keys and tokens, and a
    /// list of names is how none of them can come along. Empty when the
    /// manifest names none, which is also when a name is not
    /// `[A-Z0-9_]`, or there are more than `max_identify_env`.
    identify_env: []const []const u8,

    pub const max_identify_env = 8;
    pub const max_identify_name = 64;

    /// A name `identify_env` may carry: upper-case letters, digits and
    /// `_`, not starting with a digit.
    pub fn validEnvName(name: []const u8) bool {
        if (name.len == 0 or name.len > max_identify_name) return false;
        if (std.ascii.isDigit(name[0])) return false;
        for (name) |c| switch (c) {
            'A'...'Z', '0'...'9', '_' => {},
            else => return false,
        };
        return true;
    }
};

/// How this system starts a file of that kind.
///
/// **Which file to run is the plugin's to say; how to start that kind of file
/// is this host's.** Those are two different questions and only the first one
/// was ever settled -- see `dev-docs/poltergeist/provisioning.md` section 9. The
/// plugin answers the first with `exec_<os>`; this table answers the second,
/// and it is deliberately short.
///
/// **Short because every row is the host deciding what to run somebody's file
/// with.** A general "find an interpreter by extension" mechanism would turn
/// dropping a `.py` or a `.jar` into `<config>/polter/plugins/` into a request
/// this host would honour. Three rows, and everything else runs as itself,
/// exactly as it does today.
const LaunchKind = enum {
    /// Run the file. This is what every plugin got before this table existed
    /// and what every POSIX plugin still gets.
    direct,
    /// Windows will not execute a `.ps1`, and its default execution policy
    /// refuses script files besides. `-NoProfile` is not decoration: a user
    /// profile that prints anything puts it on the plugin's standard output,
    /// where anything that is not an acknowledgement is judged misconduct.
    powershell,
    /// Windows will not execute a `.cmd` or `.bat` directly either.
    command_shell,
    /// Nothing on this system starts a file of that kind. **Said at load,
    /// not discovered at spawn** -- see `Manifest.runnable`.
    unsupported,
};

fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - needle.len ..], needle);
}

/// **The table, with the system as an argument rather than as `builtin`.**
///
/// Written this way for one reason: with the target baked in, the Windows
/// rows are unreachable from a test running on macOS, and "the Windows row is
/// wrong" would be a thing no test on the build machine could ever go red
/// for. A table nothing can contradict is not a table, it is a hope.
fn launchKindFor(tag: std.Target.Os.Tag, exec: []const u8) LaunchKind {
    const windows_only = endsWithIgnoreCase(exec, ".ps1") or
        endsWithIgnoreCase(exec, ".cmd") or
        endsWithIgnoreCase(exec, ".bat");

    return switch (tag) {
        .windows => if (endsWithIgnoreCase(exec, ".ps1"))
            .powershell
        else if (endsWithIgnoreCase(exec, ".cmd") or endsWithIgnoreCase(exec, ".bat"))
            .command_shell
        else if (endsWithIgnoreCase(exec, ".sh") or endsWithIgnoreCase(exec, ".py"))
            // A shebang means nothing to `CreateProcess`. This is the case
            // the whole mechanism exists for: seven shipped plugins declare
            // a `.sh`, and on Windows they used to fail at spawn, back off,
            // restart and fail again -- a loop that looks, from the plugin's
            // side, exactly like idling.
            .unsupported
        else
            .direct,

        else => if (windows_only) .unsupported else .direct,
    };
}

/// Whether this system can start it at all. No allocation, so a caller
/// deciding whether to bother does not have to.
pub fn launchable(exec: []const u8) bool {
    return launchKindFor(builtin.os.tag, exec) != .unsupported;
}

/// The command line, or `null` when this system cannot start it.
///
/// **Every spawn of a plugin goes through here, tests included.** A test that
/// built its own argv would be asserting over its own idea of the command
/// line: get this function wrong and that test stays green while nothing
/// starts. Running the thing we ship, the way we ship it, is the whole point
/// of the end-to-end tests below.
pub fn launchArgv(
    alloc: Allocator,
    exec: []const u8,
) Allocator.Error!?[]const []const u8 {
    return launchArgvFor(alloc, builtin.os.tag, exec);
}

pub fn launchArgvFor(
    alloc: Allocator,
    tag: std.Target.Os.Tag,
    exec: []const u8,
) Allocator.Error!?[]const []const u8 {
    return switch (launchKindFor(tag, exec)) {
        .direct => try alloc.dupe([]const u8, &.{exec}),
        .powershell => try alloc.dupe([]const u8, &.{
            "powershell",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            exec,
        }),
        .command_shell => try alloc.dupe([]const u8, &.{ "cmd", "/c", exec }),
        .unsupported => null,
    };
}

/// Load a plugin's manifest from a directory.
///
/// Everything returned belongs to `arena`, including `exec`, which is made
/// absolute here so that running it never depends on where Polter happens
/// to be.
///
/// The manifest is JSON rather than YAML: Zig has no YAML in its standard
/// library, and a hand-written subset parser gets indentation and
/// implicit typing wrong in ways that silently mean something else. See
/// `dev-docs/poltergeist/plugins.md`.
pub fn load(
    arena: Allocator,
    io: std.Io,
    dir: []const u8,
) !Manifest {
    const path = try std.fmt.allocPrint(arena, "{s}/plugin.json", .{dir});

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        .limited(64 * 1024),
    ) catch |err| {
        log.warn("plugin: could not read {s} err={}", .{ path, err });
        return error.NoManifest;
    };

    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        bytes,
        .{},
    ) catch |err| {
        log.warn("plugin: {s} will not parse err={}", .{ path, err });
        return error.BadManifest;
    };

    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.BadManifest,
    };

    const key = stringField(obj, "key") orelse {
        log.warn("plugin: {s} has no key", .{path});
        return error.BadManifest;
    };
    if (!isPlainName(key)) {
        log.warn(
            "plugin: {s} has the key {s}, which is not a plain name, so it is not loaded",
            .{ path, key },
        );
        return error.BadKey;
    }

    // There is no `kind` any more. A manifest that still carries one is not
    // refused over it -- it is simply a field nothing reads -- but it is
    // said out loud once, because a plugin whose author believes `kind` is
    // still what starts it will otherwise sit there declaring nothing and
    // never being fed.
    if (stringField(obj, "kind")) |stale| log.warn(
        "plugin {s}: \"kind\": \"{s}\" is not read any more; what a plugin is " ++
            "handed comes from \"wants\": {{\"events\": [...]}}",
        .{ key, stale },
    );

    // **`exec_<os>` first, `exec` as the fallback.** Purely additive: a
    // manifest that names only `exec` means exactly what it meant before,
    // and a reader that has never heard of the new key is still right on
    // POSIX. The alternatives -- `exec` becoming an object, an array of
    // `{os, path}` -- would have made every existing manifest and every
    // example ambiguous to save a few flat keys. See
    // `dev-docs/poltergeist/provisioning.md` 9.2.
    //
    // The name is `builtin.os.tag`'s own: `exec_windows`, `exec_macos`,
    // `exec_linux`.
    //
    // ⚠️ **Not `wants.exec`.** That one is the list of binaries a plugin says
    // it will look for on `PATH`, and it is disclosure only. This one is the
    // file to start. The two have collided in readers' heads before.
    const os_key = "exec_" ++ @tagName(builtin.os.tag);
    const exec_rel = stringField(obj, os_key) orelse
        stringField(obj, "exec") orelse
        {
            log.warn("plugin {s}: no exec", .{key});
            return error.BadManifest;
        };

    const exec_abs = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, exec_rel });

    return .{
        .key = key,
        .name = stringField(obj, "name") orelse key,
        .exec = exec_abs,
        .runnable = launchable(exec_abs),
        .timeout_ms = switch (obj.get("timeout_ms") orelse std.json.Value{ .null = {} }) {
            .integer => |n| if (n > 0) @intCast(n) else default_timeout_ms,
            else => default_timeout_ms,
        },
        .wants = wantsOf(arena, key, obj),
        .params = specsOf(arena, key, obj),
        .agent_cli = try agentCliOf(arena, key, dir, obj),
        .title_says = try titleSaysOf(arena, key, obj),
        .screen_says = try screenSaysOf(arena, key, obj),
        .hooks_report_approval = hooksReportApprovalOf(key, obj),
        .startup_says = try startupSaysOf(arena, key, obj),
        .declined_says = try declinedSaysOf(arena, key, obj),
        .token_says = try tokenSaysOf(arena, key, obj),
    };
}

/// `token_says`, or null with a warning for a section that does not read.
///
/// Like every other optional section, a section that does not read costs
/// the section and not the plugin -- and here that is the safer of the two
/// failures by a distance: a declaration somebody half-meant would be a
/// number attributed to a task's seats by a rule nobody wrote, and a wrong
/// attribution is much harder to notice than an absent one.
fn tokenSaysOf(arena: Allocator, key: []const u8, obj: std.json.ObjectMap) Allocator.Error!?token_says.TokenSays {
    const section = switch (obj.get("token_says") orelse return null) {
        .object => |o| o,
        else => {
            log.warn("plugin {s}: token_says is not an object; ignored", .{key});
            return null;
        },
    };
    return token_says.parse(arena, key, section);
}

/// `declined_says`, or `.none` with a warning for a section that does not
/// read: every key is needed, since a decline read with one of them missing
/// would be read off a screen nobody said how to read.
fn declinedSaysOf(arena: Allocator, key: []const u8, obj: std.json.ObjectMap) Allocator.Error!DeclinedSays {
    const section = switch (obj.get("declined_says") orelse return .none) {
        .object => |o| o,
        else => {
            log.warn("plugin {s}: declined_says is not an object; ignored", .{key});
            return .none;
        },
    };
    const out: DeclinedSays = .{
        .contains = try sectionTexts(arena, key, "declined_says", section, "contains"),
        .turn_from = try sectionText(arena, key, section, "turn_from"),
        .box = try sectionTexts(arena, key, "declined_says", section, "box"),
        .turn_done_starts = try sectionText(arena, key, section, "turn_done_starts"),
        .turn_done_has = try sectionText(arena, key, section, "turn_done_has"),
    };
    if (!out.declared() or out.box.len == 0) {
        log.warn("plugin {s}: declined_says needs contains, turn_from, box, turn_done_starts and turn_done_has; ignored", .{key});
        return .none;
    }
    return out;
}

fn sectionText(arena: Allocator, key: []const u8, section: std.json.ObjectMap, name: []const u8) Allocator.Error![]const u8 {
    const t = switch (section.get(name) orelse return "") {
        .string => |t| t,
        else => "",
    };
    if (t.len == 0 or t.len > ScreenSays.max_text_bytes) {
        log.warn("plugin {s}: declined_says.{s} is not a short text; ignored", .{ key, name });
        return "";
    }
    return arena.dupe(u8, t);
}

/// `startup_says`, or `.none` with a warning for a section that does not
/// read. A list whose items are not all short strings costs the list.
fn startupSaysOf(arena: Allocator, key: []const u8, obj: std.json.ObjectMap) Allocator.Error!StartupSays {
    const section = switch (obj.get("startup_says") orelse return .none) {
        .object => |o| o,
        else => {
            log.warn("plugin {s}: startup_says is not an object; ignored", .{key});
            return .none;
        },
    };
    return .{
        .blocks = try startupTexts(arena, key, section, "blocks"),
        .ready_says = try startupTexts(arena, key, section, "ready_says"),
        .ready_without_agent = startupFlag(key, section, "ready_without_agent"),
        .tools_from_second_turn = startupFlag(key, section, "tools_from_second_turn"),
    };
}

fn startupFlag(key: []const u8, section: std.json.ObjectMap, name: []const u8) bool {
    return switch (section.get(name) orelse return false) {
        .bool => |b| b,
        else => {
            log.warn("plugin {s}: startup_says.{s} is not true or false; taken as false", .{ key, name });
            return false;
        },
    };
}

fn startupTexts(arena: Allocator, key: []const u8, section: std.json.ObjectMap, name: []const u8) Allocator.Error![]const []const u8 {
    return sectionTexts(arena, key, "startup_says", section, name);
}

fn sectionTexts(arena: Allocator, key: []const u8, what: []const u8, section: std.json.ObjectMap, name: []const u8) Allocator.Error![]const []const u8 {
    const list = switch (section.get(name) orelse return &.{}) {
        .array => |a| a.items,
        else => {
            log.warn("plugin {s}: {s}.{s} is not a list; ignored", .{ key, what, name });
            return &.{};
        },
    };
    if (list.len > ScreenSays.max_texts) {
        log.warn("plugin {s}: {s}.{s} has more than {d}; ignored", .{ key, what, name, ScreenSays.max_texts });
        return &.{};
    }
    const out = try arena.alloc([]const u8, list.len);
    for (list, out) |v, *o| {
        const t = switch (v) {
            .string => |t| t,
            else => "",
        };
        if (t.len == 0 or t.len > ScreenSays.max_text_bytes) {
            log.warn("plugin {s}: {s}.{s} has an empty, long or non-text item; ignored", .{ key, what, name });
            return &.{};
        }
        o.* = try arena.dupe(u8, t);
    }
    return out;
}

/// `hooks_report_approval`, true when the manifest says nothing -- or says
/// something that is not true or false, which is logged.
fn hooksReportApprovalOf(key: []const u8, obj: std.json.ObjectMap) bool {
    return switch (obj.get("hooks_report_approval") orelse return true) {
        .bool => |b| b,
        else => {
            log.warn("plugin {s}: hooks_report_approval is not true or false; taken as true", .{key});
            return true;
        },
    };
}

/// What the manifest declares under `agent_cli`, or null.
///
/// Like `wants`, a section that does not read costs the section and not the
/// plugin: the plugin may well do something else too (the Claude Code one
/// also registers Polter with the CLI), and that half should keep working.
fn agentCliOf(
    arena: Allocator,
    key: []const u8,
    dir: []const u8,
    obj: std.json.ObjectMap,
) Allocator.Error!?AgentCli {
    return agentCliFor(arena, builtin.os.tag, key, dir, obj);
}

/// `agentCliOf` with the system as an argument, **for the reason
/// `launchKindFor` takes one**: with the target baked in, "Windows is given
/// `adapter_windows` and can start it" is a claim no test on the build
/// machine could ever see fail. The Claude Code plugin shipped only a `.py`
/// for as long as that was true, and Windows found out at the first launch.
fn agentCliFor(
    arena: Allocator,
    tag: std.Target.Os.Tag,
    key: []const u8,
    dir: []const u8,
    obj: std.json.ObjectMap,
) Allocator.Error!?AgentCli {
    const a = switch (obj.get("agent_cli") orelse return null) {
        .object => |o| o,
        else => {
            log.warn("plugin {s}: agent_cli is not an object; ignored", .{key});
            return null;
        },
    };

    if (!validCliKey(key)) {
        log.warn(
            "plugin {s}: agent_cli ignored -- a CLI's key must be lowercase " ++
                "letters, digits and dashes, because it is written into personas.json",
            .{key},
        );
        return null;
    }

    const os_key = try std.fmt.allocPrint(arena, "adapter_{s}", .{@tagName(tag)});
    const rel = stringField(a, os_key) orelse stringField(a, "adapter") orelse {
        log.warn("plugin {s}: agent_cli has no adapter; ignored", .{key});
        return null;
    };
    const abs = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, rel });

    return .{
        .label = stringField(a, "label") orelse stringField(obj, "name") orelse key,
        .bin = stringField(a, "bin") orelse key,
        .adapter = abs,
        .runnable = launchKindFor(tag, abs) != .unsupported,
        .identify_env = try identifyEnvOf(arena, key, a),
    };
}

/// `agent_cli.identify_env`, or empty. All or nothing: one name that is
/// not a name, or too many, and none are taken -- a list that is half used
/// is a CLI that is recognised on some machines and not others.
fn identifyEnvOf(arena: Allocator, key: []const u8, a: std.json.ObjectMap) Allocator.Error![]const []const u8 {
    const list = switch (a.get("identify_env") orelse return &.{}) {
        .array => |l| l,
        else => {
            log.warn("plugin {s}: agent_cli.identify_env is not a list; ignored", .{key});
            return &.{};
        },
    };
    if (list.items.len > AgentCli.max_identify_env) {
        log.warn("plugin {s}: agent_cli.identify_env names more than {d}; ignored", .{ key, AgentCli.max_identify_env });
        return &.{};
    }
    const out = try arena.alloc([]const u8, list.items.len);
    for (list.items, out) |v, *o| {
        const name = switch (v) {
            .string => |n| n,
            else => "",
        };
        if (!AgentCli.validEnvName(name)) {
            log.warn("plugin {s}: agent_cli.identify_env has a name that is not [A-Z0-9_]; ignored", .{key});
            return &.{};
        }
        o.* = try arena.dupe(u8, name);
    }
    return out;
}

/// `persona.isValidKey`, repeated rather than imported so that this file
/// keeps its import list; the test beside it holds the two together.
fn validCliKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 32) return false;
    for (key) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// Where plugins are looked for, nearest first: the user's
/// `<config>/polter/plugins`, then the ones shipped with the app.
///
/// **One function for the app and for `+launch`.** A second copy of the
/// search path in the command-line half would be a second answer to "which
/// adapter is this", and the first time they differed a role would start
/// with one plugin's idea of Claude Code and be edited with another's.
pub fn searchPath(
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) []const []const u8 {
    const bases = searchBases(alloc, io, environ_map);
    const out = alloc.alloc([]const u8, bases.len) catch return &.{};
    for (bases, out) |b, *o| o.* = b.path;
    return out;
}

/// One directory of the search path, and whether it is the one a release
/// installs into (task 1683). Only that one has a `SHIPPED` list to be
/// held to; a directory the user put a plugin into by hand is theirs, and
/// nothing in it is ever called a stray.
pub const Base = struct {
    path: []const u8,
    bundled: bool,
};

/// `searchPath`, saying which entry is the bundle's. **The one place the
/// two directories are worked out**: `searchPath` is this with the flags
/// dropped, so the two cannot come to name different directories.
pub fn searchBases(
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) []const Base {
    var out: std.ArrayListUnmanaged(Base) = .empty;

    if (internal_os.xdg.config(
        io,
        alloc,
        environ_map,
        .{ .subdir = "polter/plugins" },
    )) |base| {
        out.append(alloc, .{ .path = base, .bundled = false }) catch {};
    } else |_| {}

    if (internal_os.resourcesDir(alloc)) |resources| {
        if (resources.app_path) |app_path| {
            if (std.fmt.allocPrint(
                alloc,
                "{s}/polter/plugins",
                .{app_path},
            )) |base| {
                out.append(alloc, .{ .path = base, .bundled = true }) catch {};
            } else |_| {}
        }
    } else |_| {}

    return out.items;
}

/// The file in the bundle's plugin directory that names, one per line,
/// every directory this release installs there (task 1683). Written by the
/// build from the same list that installs them
/// (`src/build/GhosttyResources.zig`, `shipped`).
///
/// **Why it exists.** A Windows release is a zip, and unpacking a new one
/// over an old one adds and replaces files but never removes any: a plugin
/// an older release shipped and this one dropped stays in the directory,
/// and is found and loaded as if this release had shipped it
/// (`D:\polter\t1686`, a `gemini` left behind by 0.9). Nothing on disk said
/// which directories a release put there, so nothing could tell.
pub const shipped_list = "SHIPPED";

/// What the bundle's `SHIPPED` says, read once per scan.
///
/// **Two answers that must not look alike** (CLAUDE.md, 验证 5): no list at
/// all -- an older release, or a build tree that never installed one -- is
/// "cannot tell", and nothing is called a stray; a list that does not name
/// a directory is "this release did not ship it". `names == null` is the
/// first and only the first.
pub const Shipped = struct {
    names: ?[]const []const u8,

    /// No list was found: nothing is held against it.
    pub const unknown: Shipped = .{ .names = null };

    /// Where one plugin directory stands.
    pub const Verdict = enum {
        /// In the user's own directory: theirs, whatever it is called.
        user,
        /// The bundle has no list to hold it to.
        unknown,
        /// The list names it.
        shipped,
        /// The list is there and does not name it: left over from another
        /// release, most likely one unpacked over this one.
        stray,
    };

    /// The list, a name per line; blank lines and surrounding blanks are
    /// not names. `\r` is a blank, so a file that went through a Windows
    /// tool still reads.
    pub fn parse(arena: Allocator, bytes: []const u8) Allocator.Error!Shipped {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const name = std.mem.trim(u8, line, " \t\r");
            if (name.len == 0) continue;
            try names.append(arena, try arena.dupe(u8, name));
        }
        return .{ .names = names.items };
    }

    /// `<dir>/SHIPPED`, or `unknown` when there is none. A list that is
    /// there and will not read is said and taken as unknown: calling every
    /// plugin a stray because one file is unreadable would be the loud
    /// mistake in the wrong direction.
    pub fn read(arena: Allocator, io: std.Io, dir: []const u8) Shipped {
        const path = std.fmt.allocPrint(arena, "{s}/" ++ shipped_list, .{dir}) catch return unknown;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| {
            if (err != error.FileNotFound) log.warn("plugin: could not read {s} err={}", .{ path, err });
            return unknown;
        };
        return parse(arena, bytes) catch unknown;
    }

    /// Where the directory `name` stands, found in a directory that is or
    /// is not the bundle's.
    pub fn of(self: Shipped, bundled: bool, name: []const u8) Verdict {
        if (!bundled) return .user;
        const names = self.names orelse return .unknown;
        for (names) |n| if (std.mem.eql(u8, n, name)) return .shipped;
        return .stray;
    }
};

/// One plugin's settings, nearest first: the user's
/// `<config>/polter/plugins/<key>.json`, then a `settings.json` inside the
/// plugin's own directory anywhere on the search path. See
/// `Settings.readFirst` for why only the first one found is read.
pub fn settingsFor(
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    key: []const u8,
) Settings {
    return Settings.readFirst(alloc, io, settingsPaths(alloc, io, environ_map, key));
}

/// Every file `settingsFor` searches, the user's own first. **The one place
/// that list is worked out**, so "which file wins" and "what this release
/// ships" cannot come to be two different searches.
fn settingsPaths(
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    key: []const u8,
) []const []const u8 {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;

    if (internal_os.xdg.config(
        io,
        alloc,
        environ_map,
        .{ .subdir = "polter/plugins" },
    )) |base| {
        if (std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ base, key })) |path| {
            paths.append(alloc, path) catch {};
        } else |_| {}
    } else |_| {}

    for (releasedSettingsPaths(alloc, io, environ_map, key)) |path| {
        paths.append(alloc, path) catch {};
    }

    return paths.items;
}

/// The `settings.json` a release ships, one per directory on the search
/// path, in `searchPath`'s order.
fn releasedSettingsPaths(
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    key: []const u8,
) []const []const u8 {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;

    for (searchPath(alloc, io, environ_map)) |base| {
        if (std.fmt.allocPrint(
            alloc,
            "{s}/{s}/settings.json",
            .{ base, key },
        )) |path| {
            paths.append(alloc, path) catch {};
        } else |_| {}
    }

    return paths.items;
}

/// What a release ships for one plugin, on its own: the `settings.json`
/// inside the plugin's own directory, first one on the search path that has
/// one.
///
/// **The second file `settingsFor` would have read, read by itself.** A
/// caller wanting "the value this release ships, whether or not the user's
/// own file is in the way" cannot get it out of `settingsFor`, because a
/// user file that exists wins outright and is never merged with it
/// (`readFirst`). That is right for "which settings are in force" and wrong
/// for one narrow question `agent_cli.launchParams` asks: a user who has a
/// file written before this release added a parameter has no value for it
/// at all, and a parameter of a kind that may only come from a declaration
/// (`ParamSpec.to_session`) has no other place to get one.
pub fn shippedSettingsFor(
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    key: []const u8,
) Settings {
    return Settings.readFirst(alloc, io, releasedSettingsPaths(alloc, io, environ_map, key));
}

/// The manifest of the plugin `key` names, from the first directory on the
/// search path that has one, or `null`.
///
/// The directory is `<base>/<key>` -- **the same spelling `settingsFor`
/// reads a shipped `settings.json` from.** The two have to agree about
/// where a plugin's own directory is, or one launch reads defaults out of
/// one plugin and takes its declarations from another.
///
/// `null` covers both "no directory" and "a directory whose manifest will
/// not load", because both read the same way to a caller: nothing is
/// declared, so nothing is declared to be for a session.
pub fn manifestOf(
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    key: []const u8,
) ?Manifest {
    for (searchPath(alloc, io, environ_map)) |base| {
        const dir = std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, key }) catch continue;
        return load(alloc, io, dir) catch continue;
    }
    return null;
}

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |v| v,
        else => null,
    };
}

/// Whether a key is a name and nothing more.
///
/// A key is not just an identifier: it is spelled straight into four file
/// paths -- `<config>/polter/plugins/<key>.json` on both the reading and the
/// writing side, `<base>/polter/plugins/<key>/settings.json` for the copy a
/// release ships, and `<state>/polter/plugins/<key>.cursor`. A key holding a
/// separator or a `..` therefore names a file outside the polter directories,
/// and `Settings.write` creates the directories on the way to it. Checking it
/// here is the one place that knows a key becomes a filename; the callers see
/// a string and cannot tell.
///
/// The rule is deliberately narrower than "no traversal": a key is also what
/// a person types into `plugin_configure` and reads in a listing, so anything
/// that does not survive being written down plainly is refused too.
fn isPlainName(key: []const u8) bool {
    if (key.len == 0 or key.len > 64) return false;
    if (std.mem.eql(u8, key, ".") or std.mem.eql(u8, key, "..")) return false;

    for (key) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return false,
    };
    return true;
}

/// What the manifest declares under `wants`.
///
/// A `wants` that will not read is not worth failing the load over: one
/// typo would make a whole plugin vanish, which is harder for its author to
/// notice than a plugin being handed nothing. It reads as asking for
/// nothing instead -- the direction that cannot give somebody messages they
/// never asked for.
fn wantsOf(arena: Allocator, key: []const u8, obj: std.json.ObjectMap) Wants {
    const w = switch (obj.get("wants") orelse return .{}) {
        .object => |o| o,
        else => {
            log.warn(
                "plugin {s}: wants is not an object, so it is read as asking for nothing",
                .{key},
            );
            return .{};
        },
    };
    return .{
        .events = eventsOf(arena, key, w),
        .calls = stringsOf(arena, key, w, "calls", "wants.calls"),
        .groups = stringsOf(arena, key, w, "groups", "wants.groups"),
        .network = switch (w.get("network") orelse .null) {
            .bool => |b| b,
            else => false,
        },
        .exec = stringsOf(arena, key, w, "exec", "wants.exec"),
    };
}

/// What the manifest declares under `wants.events`.
///
/// A name this build does not know is passed over with a warning rather
/// than voiding the list, for the same reason a malformed `wants` reads as
/// asking for nothing: the direction that cannot hand somebody events they
/// never asked for. A manifest written against a later build therefore
/// keeps whichever of its subscriptions this build can honour, and is told
/// about the rest.
fn eventsOf(arena: Allocator, key: []const u8, w: std.json.ObjectMap) []const Event {
    const names = stringsOf(arena, key, w, "events", "wants.events");

    var out: std.ArrayListUnmanaged(Event) = .empty;
    for (names) |name| {
        const e = Event.parse(name) orelse {
            // The Zig spelling is the one mistake worth naming: it is what
            // the code, `plugin_list`'s neighbours and a checklist written
            // from the code all show, and it reads as right (#1672).
            if (Event.parseZigName(name)) |meant| {
                log.warn(
                    "plugin {s}: wants.events names {s}, which this build never sends " ++
                        "-- the event is spelled {s} -- so nothing is subscribed for it",
                    .{ key, name, meant.wireName() },
                );
            } else log.warn(
                "plugin {s}: wants.events names {s}, which this build never sends, " ++
                    "so nothing is subscribed for it",
                .{ key, name },
            );
            continue;
        };

        // Named twice is asked for once. Nothing downstream would break on
        // a duplicate -- `subscribes` stops at the first match -- but the
        // list is read back out to the user and to `plugin_list`, and a
        // listing that says `chat, chat` reads as a bug in the host.
        if (contains2(out.items, e)) continue;

        out.append(arena, e) catch {
            log.warn(
                "plugin {s}: ran out of memory reading wants.events, so only the " ++
                    "first {d} are subscribed",
                .{ key, out.items.len },
            );
            break;
        };
    }
    return out.items;
}

fn contains2(haystack: []const Event, needle: Event) bool {
    for (haystack) |h| if (h == needle) return true;
    return false;
}

/// What the manifest declares under `params`.
///
/// The same rule as `wantsOf`: a schema that will not read leaves the
/// plugin with no declared parameters rather than making the whole plugin
/// vanish. The direction is safe here too -- an undeclared parameter is one
/// the tool surface refuses to set, because a name that is not in the
/// schema cannot be judged secret or not.
fn specsOf(arena: Allocator, key: []const u8, obj: std.json.ObjectMap) []const ParamSpec {
    const schema = switch (obj.get("params") orelse return &.{}) {
        .object => |o| o,
        else => {
            log.warn(
                "plugin {s}: params is not an object, so it is read as declaring none",
                .{key},
            );
            return &.{};
        },
    };

    const properties = switch (schema.get("properties") orelse return &.{}) {
        .object => |o| o,
        else => {
            log.warn(
                "plugin {s}: params.properties is not an object, so it is read as declaring none",
                .{key},
            );
            return &.{};
        },
    };

    const required = stringsOf(arena, key, schema, "required", "params.required");

    var out: std.ArrayListUnmanaged(ParamSpec) = .empty;
    var it = properties.iterator();
    while (it.next()) |kv| {
        if (out.items.len >= max_specs) {
            log.warn(
                "plugin {s}: declares more than {d} parameters, and the rest are passed over",
                .{ key, max_specs },
            );
            break;
        }

        const name = kv.key_ptr.*;

        // A property with no name at all would round-trip: `Manifest.param`
        // would match the empty string, `Settings.render` would write an
        // object field with an empty name, and `paramsOf` would read it back
        // as a real parameter nobody can refer to.
        if (name.len == 0) {
            log.warn(
                "plugin {s}: params.properties has an unnamed entry and it is passed over",
                .{key},
            );
            continue;
        }

        const field = switch (kv.value_ptr.*) {
            .object => |o| o,
            else => {
                log.warn(
                    "plugin {s}: params.properties.{s} is not an object and is passed over",
                    .{ key, name },
                );
                continue;
            },
        };

        out.append(arena, .{
            .name = name,
            .title = stringField(field, "title") orelse "",
            .description = stringField(field, "description") orelse "",
            .required = contains(required, name),

            // Anything that is not `true` is not a declaration that this
            // holds a credential. Missing is the common case and reads as
            // false -- which is safe only because the listing side never
            // shows a plaintext value whatever this says; see `rpc.Guard`.
            .secret = switch (field.get("secret") orelse .null) {
                .bool => |b| b,
                else => false,
            },

            // Whether this value belongs to a session the plugin starts,
            // so that `agent_cli.launchParams` may put it in a `launch`
            // request. **Not `true` for a value that is a
            // `secret.zig` reference** -- see `ParamSpec.to_session`: the
            // caller skips those rather than resolving them into an argv.
            .to_session = switch (field.get("to_session") orelse .null) {
                .bool => |b| b,
                else => false,
            },
            .choices = choicesOf(arena, key, name, field),
        }) catch {
            // Cut short rather than voided, for the same reason `stringsOf`
            // does: a shorter list of declared parameters means fewer the
            // tool surface will set, never more.
            log.warn(
                "plugin {s}: ran out of memory reading params, so only the first {d} are declared",
                .{ key, out.items.len },
            );
            break;
        };
    }
    return out.items;
}

/// A parameter's `enum`, labelled with the parameter it belongs to.
///
/// Built here rather than in `specsOf` so a failure to name the path never
/// costs the declaration itself: a label that will not render leaves the
/// generic one, and the choices are read either way.
fn choicesOf(
    arena: Allocator,
    key: []const u8,
    name: []const u8,
    field: std.json.ObjectMap,
) []const []const u8 {
    var buf: [128]u8 = undefined;
    const where = std.fmt.bufPrint(
        &buf,
        "params.properties.{s}.enum",
        .{name},
    ) catch "params.properties.<name>.enum";
    return stringsOf(arena, key, field, "enum", where);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

/// The strings in one array field, passing over whatever is not one.
///
/// An entry of the wrong type does not void the rest: a declaration that can
/// be read in part is still a declaration, and the part that reads is what
/// its author meant. Running out of memory ends the list early for the same
/// reason that is safe -- a list cut short asks for less than was written
/// down, never for more.
fn stringsOf(
    arena: Allocator,
    key: []const u8,
    obj: std.json.ObjectMap,
    name: []const u8,
    /// Where this field sits, for the warnings only. The lookup uses
    /// `name`; a reader chasing one of these needs the whole path.
    where: []const u8,
) []const []const u8 {
    const items = switch (obj.get(name) orelse return &.{}) {
        .array => |a| a.items,
        else => {
            log.warn(
                "plugin {s}: {s} is not a list, so it is read as naming nothing",
                .{ key, where },
            );
            return &.{};
        },
    };

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var skipped: usize = 0;
    for (items) |item| {
        const s = switch (item) {
            .string => |v| v,
            else => {
                skipped += 1;
                continue;
            },
        };
        out.append(arena, s) catch {
            // Cut short rather than voided, because a shorter list asks for
            // less than was written down and never for more. Said out loud
            // all the same: a declaration that quietly means something
            // narrower than its author wrote is the one kind of narrowing
            // nobody can debug.
            log.warn(
                "plugin {s}: ran out of memory reading {s}, so only the first {d} of {d} are honoured",
                .{ key, where, out.items.len, items.len },
            );
            break;
        };
    }
    if (skipped > 0) log.warn(
        "plugin {s}: passed over {d} entries in {s} that are not text",
        .{ key, skipped, where },
    );
    return out.items;
}

/// One parameter as configured. The value may be a reference; see
/// `secret.zig`.
pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

/// Everything the user has said about one plugin, in one file.
///
/// Lives at `$XDG_CONFIG_HOME/polter/plugins/<key>.json`, beside the plugin's
/// own directory:
///
///     {"enabled": true, "params": {"url": "cmd:op read op://…"}}
///
/// **One plugin, one file, one source of truth.** Whether it is switched on
/// used to live in the main config and its parameters here, which meant the
/// two could disagree and that a GUI could not own either without fighting a
/// file the user hand-writes. This file is structured, ours, and safe to
/// rewrite.
///
/// **Read from two places, written to one.** A plugin a release ships may
/// carry a `settings.json` inside its own directory, and that file is
/// consulted only when the user has no file of their own; see `readFirst`
/// for why the fallback is chosen by which files exist rather than by
/// merging their contents. Nothing ever writes the shipped copy -- `write`
/// knows one path, the user's.
pub const Settings = struct {
    enabled: bool = false,
    params: []const Param = &.{},

    /// Whether the two hand a plugin the same parameters, whatever order
    /// they were written in. `merge` keeps each name once, so this compares
    /// name for name.
    ///
    /// For deciding whether a running plugin has to be restarted to see a
    /// change (#1673): the settings window sends its whole form on every
    /// save, so "parameters were sent" is not "parameters changed".
    pub fn sameParams(self: Settings, other: Settings) bool {
        if (self.params.len != other.params.len) return false;
        outer: for (self.params) |mine| {
            for (other.params) |theirs| {
                if (!std.mem.eql(u8, mine.name, theirs.name)) continue;
                if (!std.mem.eql(u8, mine.value, theirs.value)) return false;
                continue :outer;
            }
            return false;
        }
        return true;
    }

    /// Read one. Missing or unparseable reads as "not configured", which is
    /// the same as not enabled -- a plugin nobody has set up should not be
    /// sending anything.
    ///
    /// Everything borrowed comes from `arena`.
    pub fn read(
        arena: Allocator,
        io: std.Io,
        path: []const u8,
    ) Settings {
        return readMaybe(arena, io, path) orelse .{};
    }

    /// Read the first of `paths` that has a file, nearest first.
    ///
    /// The user's own file is expected first and whatever a release ships
    /// with the plugin after it, so a plugin can arrive with sensible
    /// defaults without those defaults ever getting a vote once somebody has
    /// written the file that is theirs.
    ///
    /// **A file that is there wins even when it says the plugin is off.**
    /// That is the whole reason this is a search over files rather than a
    /// merge of two `Settings`: a `Settings` cannot tell "switched off" from
    /// "never configured" -- both are `enabled = false` -- so folding the two
    /// values together would let an upgrade switch a plugin back on for
    /// somebody who had deliberately switched it off. Only the file's
    /// existence carries that difference, and it is only readable here.
    ///
    /// A file that is there but will not parse also wins, for the same
    /// reason and in the same direction: it reads as "not configured", which
    /// reads as off. Falling through to a shipped default because the user's
    /// file has a typo in it is the one outcome that turns something on
    /// behind their back.
    pub fn readFirst(
        arena: Allocator,
        io: std.Io,
        paths: []const []const u8,
    ) Settings {
        for (paths) |path| {
            if (readMaybe(arena, io, path)) |settings| return settings;
        }
        return .{};
    }

    /// The read behind `read` and `readFirst`, which says whether there was
    /// a file at all: `null` means nothing could be read from `path`, and
    /// everything else -- including a file that will not parse -- is a
    /// settings value.
    fn readMaybe(
        arena: Allocator,
        io: std.Io,
        path: []const u8,
    ) ?Settings {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            arena,
            .limited(256 * 1024),
        ) catch return null;

        const parsed = std.json.parseFromSliceLeaky(
            std.json.Value,
            arena,
            bytes,
            .{},
        ) catch {
            log.warn("plugin: {s} will not parse", .{path});
            return .{};
        };

        const obj = switch (parsed) {
            .object => |o| o,
            else => return .{},
        };

        // The older shape was the parameters alone, with whether the plugin
        // was on kept in the main config. Such a file was only ever written
        // to make a plugin work, so it reads as enabled -- the alternative
        // silently stops delivering for somebody who changed nothing.
        const modern = obj.get("params") != null or obj.get("enabled") != null;
        if (!modern) return .{
            .enabled = true,
            .params = paramsOf(arena, obj),
        };

        const enabled = switch (obj.get("enabled") orelse .null) {
            .bool => |b| b,
            else => false,
        };
        const params = switch (obj.get("params") orelse .null) {
            .object => |o| paramsOf(arena, o),
            else => &.{},
        };
        return .{ .enabled = enabled, .params = params };
    }

    /// Render back out. The caller owns the bytes.
    ///
    /// Written whole: this file is small and the app is the only thing that
    /// writes it, so there is nothing to merge.
    pub fn render(self: Settings, alloc: Allocator) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();

        var s: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{ .whitespace = .indent_2 },
        };

        s.beginObject() catch return error.OutOfMemory;
        s.objectField("enabled") catch return error.OutOfMemory;
        s.write(self.enabled) catch return error.OutOfMemory;
        s.objectField("params") catch return error.OutOfMemory;
        s.beginObject() catch return error.OutOfMemory;
        for (self.params) |param| {
            s.objectField(param.name) catch return error.OutOfMemory;
            s.write(param.value) catch return error.OutOfMemory;
        }
        s.endObject() catch return error.OutOfMemory;
        s.endObject() catch return error.OutOfMemory;

        return out.toOwnedSlice();
    }

    /// Fold `changes` into these settings.
    ///
    /// A name in `changes` replaces whatever was there; a name that is not
    /// mentioned is kept. **An empty value removes a parameter**, which is
    /// how one is unset -- a configured value is never legitimately empty,
    /// so there is nothing to confuse it with.
    ///
    /// Everything in the result belongs to `arena`, including the strings,
    /// so it outlives both the settings that were read and the request the
    /// changes came out of.
    ///
    /// `enabled` is carried over from `self` untouched. Whether a plugin is
    /// switched on is not something merging parameters decides, and a caller
    /// that forgets to set it on the result would write `enabled: false` back
    /// over the plugin it was just asked to switch on.
    pub fn merge(
        self: Settings,
        arena: Allocator,
        changes: []const Param,
    ) Allocator.Error!Settings {
        var out: std.ArrayListUnmanaged(Param) = .empty;

        for (self.params) |old| {
            // The last mention wins, so a caller that names one parameter
            // twice gets what it wrote last rather than an arbitrary one.
            var replacement: ?[]const u8 = null;
            for (changes) |c| {
                if (std.mem.eql(u8, c.name, old.name)) replacement = c.value;
            }

            const value = replacement orelse old.value;
            if (value.len == 0) continue;

            try out.append(arena, .{
                .name = try arena.dupe(u8, old.name),
                .value = try arena.dupe(u8, value),
            });
        }

        for (changes) |c| {
            // Clearing something that was not set is not an error; it is
            // already in the state that was asked for.
            if (c.value.len == 0) continue;
            if (hasParam(out.items, c.name)) continue;

            try out.append(arena, .{
                .name = try arena.dupe(u8, c.name),
                .value = try arena.dupe(u8, c.value),
            });
        }

        return .{ .enabled = self.enabled, .params = out.items };
    }

    /// Write these settings out, creating the directory if it is not there.
    ///
    /// Through a temporary file and a rename, and **the rename is the commit
    /// point**: a `<path>.new` found on disk is a write that never reached
    /// it. A settings file caught half written parses as nothing, and nothing
    /// reads as "not configured", which reads as "off" -- a crash mid-write
    /// would silently switch a plugin off and say nothing.
    ///
    /// **This rewrites the file whole, out of what `read` understood.** Only
    /// `enabled` and string-valued parameters survive a round trip: a
    /// hand-written file holding a number, a nested object, a comment-shaped
    /// key or anything else loses it the first time this runs. Nothing new --
    /// `read` and `render` have always been this pair -- but this is the
    /// first thing that lets an agent trigger it, so a user has to be told
    /// before they let one near a file they wrote.
    pub fn write(
        self: Settings,
        alloc: Allocator,
        io: std.Io,
        path: []const u8,
    ) !void {
        const bytes = try self.render(alloc);
        defer alloc.free(bytes);

        const dir = std.fs.path.dirname(path) orelse ".";
        try std.Io.Dir.cwd().createDirPath(io, dir);

        // Beside the real file, so the rename stays within one filesystem.
        // A rename across filesystems is a copy, and a copy is the thing
        // this is here to avoid.
        const tmp = try std.fmt.allocPrint(alloc, "{s}.new", .{path});
        defer alloc.free(tmp);

        // Armed before anything creates the file, not after: a failure to
        // create, write or close it would otherwise leave `<path>.new` lying
        // beside the real file for good, because the only thing that removed
        // it was declared after the block that could fail.
        errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

        {
            // The parameters here are references far more often than they
            // are secrets, but not always -- a hand-written file may hold a
            // literal, and this rewrites such a file. So the narrow
            // permissions are not incidental strictness; they are the whole
            // reason this does not just call `createFile` and write.
            //
            // POSIX says that in the one word it has for it. Windows has no
            // mode, so `restrict` below says the same thing in the words it
            // does have -- a DACL naming this user and nobody else. Either
            // way it is applied to an **empty** file, before a byte of the
            // rendered settings exists on disk, so there is no moment at
            // which a literal sits in a file the machine's other accounts
            // can open.
            var f = try std.Io.Dir.cwd().createFile(io, tmp, switch (builtin.os.tag) {
                .windows => .{},
                else => .{ .permissions = .fromMode(0o600) },
            });
            defer f.close(io);
            restrict(alloc, tmp);
            try f.writeStreamingAll(io, bytes);
        }

        const cwd = std.Io.Dir.cwd();
        try cwd.rename(tmp, cwd, path, io);
    }

    /// Cut a just-created file down to this user alone, where the platform
    /// needs telling separately from `createFile`.
    ///
    /// A no-op everywhere but Windows, which has no mode to pass: the
    /// equivalent is a DACL, and the equivalent of `0o600` is a *protected*
    /// DACL -- `D:P` -- holding one allow-everything entry for the SID this
    /// process is running as. Protected is the load-bearing half: without
    /// it the entries the parent directory hands down are kept, and the
    /// point of the exercise was to stop inheriting them.
    ///
    /// **A failure here is logged, not fatal.** Refusing to write the file
    /// would leave a user unable to configure a plugin at all on whatever
    /// unusual machine tripped it, which is a worse trade than a file whose
    /// only protection is the one the profile directory already gives it.
    /// But it is said out loud, at `warn`, naming the file: the thing this
    /// comment is really guarding against is the protection disappearing
    /// with nothing anywhere to show that it did.
    fn restrict(alloc: Allocator, path: []const u8) void {
        if (comptime builtin.os.tag != .windows) return;

        const w = internal_os.windows;
        const advapi32 = w.exp.advapi32;

        // The error is carried out of the block rather than asked for
        // after it, and that is not a style choice: `break` evaluates its
        // operand *before* the scope unwinds, while `GetLastError` reads a
        // per-thread slot that the `defer`s below -- `CloseHandle`,
        // `LocalFree` -- overwrite on their way out. Asking afterwards
        // reports whichever cleanup call ran last, very often `0`, which
        // reads as "nothing went wrong" in the one message whose entire
        // job is to say what did. A plausible wrong answer is worse than
        // no answer.
        const err: w.Win32Error = failed: {
            var token: w.HANDLE = undefined;
            if (advapi32.OpenProcessToken(
                w.exp.kernel32.GetCurrentProcess(),
                w.TOKEN_QUERY,
                &token,
            ) == w.FALSE) break :failed w.GetLastError();
            defer _ = w.exp.kernel32.CloseHandle(token);

            // `TOKEN_USER` is a header; the SID it points at lives past the
            // end of it in the same buffer. A SID is at most 68 bytes, so
            // one buffer with room to spare is simpler than the two-call
            // sizing dance and cannot come up short.
            var buf: [256]u8 align(@alignOf(w.TOKEN_USER)) = undefined;
            var len: w.DWORD = 0;
            if (advapi32.GetTokenInformation(
                token,
                .User,
                &buf,
                buf.len,
                &len,
            ) == w.FALSE) break :failed w.GetLastError();
            const user: *const w.TOKEN_USER = @ptrCast(&buf);

            var sid_str: w.LPWSTR = undefined;
            if (advapi32.ConvertSidToStringSidW(
                user.User.Sid,
                &sid_str,
            ) == w.FALSE) break :failed w.GetLastError();
            defer _ = w.exp.kernel32.LocalFree(sid_str);

            // Built as SDDL rather than by hand: an ACL assembled out of
            // `InitializeAcl`/`AddAccessAllowedAce` is a dozen more calls
            // and a dozen more ways to get a byte count wrong, for a string
            // the system parses the same either way.
            const sid_len = std.mem.len(sid_str);
            const sddl = std.fmt.allocPrintSentinel(
                alloc,
                "D:P(A;;FA;;;{f})",
                .{std.unicode.fmtUtf16Le(sid_str[0..sid_len])},
                0,
            ) catch break :failed w.GetLastError();
            defer alloc.free(sddl);

            const sddl_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, sddl) catch break :failed w.GetLastError();
            defer alloc.free(sddl_w);

            var sd: w.PSECURITY_DESCRIPTOR = undefined;
            if (advapi32.ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl_w,
                w.SDDL_REVISION_1,
                &sd,
                null,
            ) == w.FALSE) break :failed w.GetLastError();
            defer _ = w.exp.kernel32.LocalFree(sd);

            // By path rather than on the open handle: `SetSecurityInfo`
            // wants `WRITE_DAC` on the handle, and the handle `createFile`
            // gave us was not asked for with it. `SetFileSecurityW` opens
            // the file itself, with the access it needs.
            const path_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, path) catch break :failed w.GetLastError();
            defer alloc.free(path_w);

            if (advapi32.SetFileSecurityW(
                path_w,
                w.DACL_SECURITY_INFORMATION | w.PROTECTED_DACL_SECURITY_INFORMATION,
                sd,
            ) == w.FALSE) break :failed w.GetLastError();

            return;
        };

        log.warn(
            "could not restrict {s} to this user (err={}); it keeps whatever " ++
                "permissions its directory hands down, so treat any literal " ++
                "secret in it as readable by this machine's other accounts",
            .{ path, err },
        );
    }

    /// Whether a name is already in this list.
    ///
    /// Walked rather than indexed: a plugin has a handful of parameters,
    /// and a map would be an allocation that can fail halfway through a
    /// merge for no gain anybody would measure.
    fn hasParam(params: []const Param, name: []const u8) bool {
        for (params) |p| if (std.mem.eql(u8, p.name, name)) return true;
        return false;
    }

    /// What the settings window asks a configure to do, in the file's own
    /// shape: `{"enabled": bool, "params": {"name": "value"}}`, both
    /// optional. An empty value unsets, as in `merge`.
    pub const Change = struct {
        enable: ?bool = null,
        params: []const Param = &.{},
    };

    /// Read a `Change`. **Strict where `readMaybe` is forgiving**: that one
    /// reads a file a person may have hand-written and must not refuse it,
    /// while this reads a request, and a value it would drop -- a number, a
    /// nested object -- is a value the window thought it was saving. So
    /// anything but a string parameter, a boolean `enabled`, or an object at
    /// the top is `error.BadSettings`, and nothing is written.
    pub fn parseChange(arena: Allocator, bytes: []const u8) error{ BadSettings, OutOfMemory }!Change {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err|
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.BadSettings,
            };
        const obj = switch (parsed) {
            .object => |o| o,
            else => return error.BadSettings,
        };

        var change: Change = .{};
        var it = obj.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.key_ptr.*, "enabled")) {
                change.enable = switch (kv.value_ptr.*) {
                    .bool => |b| b,
                    else => return error.BadSettings,
                };
            } else if (std.mem.eql(u8, kv.key_ptr.*, "params")) {
                const params = switch (kv.value_ptr.*) {
                    .object => |o| o,
                    else => return error.BadSettings,
                };
                var out: std.ArrayListUnmanaged(Param) = .empty;
                var pit = params.iterator();
                while (pit.next()) |p| {
                    const value = switch (p.value_ptr.*) {
                        .string => |v| v,
                        else => return error.BadSettings,
                    };
                    try out.append(arena, .{ .name = p.key_ptr.*, .value = value });
                }
                change.params = out.items;
            } else return error.BadSettings;
        }
        return change;
    }

    fn paramsOf(arena: Allocator, obj: std.json.ObjectMap) []const Param {
        var out: std.ArrayListUnmanaged(Param) = .empty;
        var it = obj.iterator();
        while (it.next()) |kv| {
            // Strings only. A parameter reaches a plugin as an environment
            // variable, and there is no sensible rendering of a nested
            // object as one -- guessing at it would put something arbitrary
            // where the user expected their value.
            const value = switch (kv.value_ptr.*) {
                .string => |v| v,
                else => continue,
            };
            out.append(arena, .{
                .name = kv.key_ptr.*,
                .value = value,
            }) catch return out.items;
        }
        return out.items;
    }
};

/// What came of running one.
pub const Outcome = enum {
    /// The plugin says it did the job.
    done,

    /// The plugin says it failed.
    refused,

    /// Killed for taking too long.
    timed_out,

    /// Could not be started at all.
    unstartable,

    /// A parameter names something that could not be fetched -- a locked
    /// vault, a missing file. The plugin was not run: handing it a
    /// half-resolved set of parameters would have it send the reference
    /// itself somewhere.
    unresolved,
};

/// Whether `key` is a name and nothing more; see `isPlainName`.
///
/// Exposed because the resident host writes the key into a log line and a
/// hello line, and because the tool surface checks a key before it goes
/// looking for a directory.
pub fn plainName(key: []const u8) bool {
    return isPlainName(key);
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

/// Write a throwaway `plugin.json` and give back its directory, owned by
/// `arena`. The caller deletes it.
fn manifestFor(arena: Allocator, io: std.Io, json: []const u8) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);

    const dir = try std.fmt.allocPrint(arena, "/tmp/polter-man-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);

    var f = try d.createFile(io, "plugin.json", .{});
    try f.writeStreamingAll(io, json);
    f.close(io);

    return dir;
}

test "a manifest is read, and its exec made absolute" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-man-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);

    var f = try d.createFile(io, "plugin.json", .{});
    try f.writeStreamingAll(io,
        \\{"key":"feishu","name":"飞书","exec":"send.sh","timeout_ms":5000}
    );
    f.close(io);

    const m = try load(alloc, io, dir);
    try testing.expectEqualStrings("feishu", m.key);
    try testing.expectEqualStrings("飞书", m.name);
    try testing.expectEqual(@as(u64, 5000), m.timeout_ms);

    // Absolute, so running it never depends on where Polter happens to be.
    const want = try std.fmt.allocPrint(alloc, "{s}/send.sh", .{dir});
    try testing.expectEqualStrings(want, m.exec);
}

// The four cells of task 1683: no list, named in the list, not named in it,
// and a user's directory of the same name as a stray.
test "a bundled plugin directory with no SHIPPED list is not called anything" {
    try testing.expectEqual(Shipped.Verdict.unknown, Shipped.unknown.of(true, "antigravity"));
    try testing.expectEqual(Shipped.Verdict.unknown, Shipped.unknown.of(true, "codex"));
}

test "a bundled plugin directory the SHIPPED list names was shipped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = try Shipped.parse(arena.allocator(), "_sdk\narchive\r\ncodex\n\n  opencode  \n");
    try testing.expectEqual(@as(usize, 4), list.names.?.len);
    for ([_][]const u8{ "_sdk", "archive", "codex", "opencode" }) |name| {
        try testing.expectEqual(Shipped.Verdict.shipped, list.of(true, name));
    }
}

test "a bundled plugin directory the SHIPPED list does not name is a stray" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = try Shipped.parse(arena.allocator(), "archive\ncodex\n");
    try testing.expectEqual(Shipped.Verdict.stray, list.of(true, "gemini"));
    // A prefix of a name is not the name.
    try testing.expectEqual(Shipped.Verdict.stray, list.of(true, "code"));
    // An empty list is a list: everything in the bundle is then a stray,
    // which is not the same answer as no list at all.
    const empty = try Shipped.parse(arena.allocator(), "");
    try testing.expectEqual(Shipped.Verdict.stray, empty.of(true, "codex"));
    try testing.expectEqual(Shipped.Verdict.unknown, Shipped.unknown.of(true, "codex"));
}

test "a plugin in the user's own directory is never a stray, whatever its name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = try Shipped.parse(arena.allocator(), "archive\ncodex\n");
    try testing.expectEqual(Shipped.Verdict.user, list.of(false, "gemini"));
    try testing.expectEqual(Shipped.Verdict.user, list.of(false, "codex"));
    try testing.expectEqual(Shipped.Verdict.user, Shipped.unknown.of(false, "gemini"));
}

test "SHIPPED is read from the directory, and its absence is not an empty list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-shipped-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try testing.expectEqual(@as(?[]const []const u8, null), Shipped.read(alloc, io, dir).names);

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    var f = try d.createFile(io, shipped_list, .{});
    try f.writeStreamingAll(io, "codex\n");
    f.close(io);

    const read = Shipped.read(alloc, io, dir);
    try testing.expectEqual(Shipped.Verdict.shipped, read.of(true, "codex"));
    try testing.expectEqual(Shipped.Verdict.stray, read.of(true, "gemini"));
}

test "settings with the same parameters in another order are the same" {
    const a: Settings = .{ .params = &.{
        .{ .name = "scope", .value = "user" },
        .{ .name = "skills", .value = "yes" },
    } };
    const b: Settings = .{ .params = &.{
        .{ .name = "skills", .value = "yes" },
        .{ .name = "scope", .value = "user" },
    } };
    try testing.expect(a.sameParams(b));

    // One value changed, one name missing: both are a change.
    const c: Settings = .{ .params = &.{
        .{ .name = "skills", .value = "no" },
        .{ .name = "scope", .value = "user" },
    } };
    try testing.expect(!a.sameParams(c));
    const d: Settings = .{ .params = &.{.{ .name = "scope", .value = "user" }} };
    try testing.expect(!a.sameParams(d));
    try testing.expect(!d.sameParams(a));
}

test "an event this build never sends is passed over, not fatal" {
    // A manifest written against a later build should keep whichever of its
    // subscriptions this build can honour. Refusing to load the whole plugin
    // because one name is from the future would be worse, and the direction
    // is the safe one: it is fed less than it asked for, never more.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"future","exec":"x","wants":{"events":["chat","weather"]}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expectEqual(@as(usize, 1), m.wants.events.len);
    try testing.expect(m.wants.subscribes(.chat));
}

test "the Zig spelling of an event is named as a mistake, never subscribed" {
    // #1672: a checklist written from the code said `terminal_quiet`, the
    // plugin was never started, and the log line did not say why the name
    // was wrong.
    try testing.expectEqual(Event.terminal_quiet, Event.parseZigName("terminal_quiet").?);
    try testing.expect(Event.parse("terminal_quiet") == null);

    // A name that is the same both ways is not a mistake to point at, and a
    // name that is neither is just unknown.
    try testing.expect(Event.parseZigName("chat") == null);
    try testing.expect(Event.parseZigName("weather") == null);
}

test "a manifest that still carries a kind loads, and kind decides nothing" {
    // The whole point of taking `Kind` out: a plugin is what it subscribes
    // to. A manifest left over from the three-kind world is not refused --
    // it is simply one that subscribes to nothing and is therefore not run.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"old","exec":"x"}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expect(m.wants.empty());
}

test "a manifest missing what it needs is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-man-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    var f = try d.createFile(io, "plugin.json", .{});
    try f.writeStreamingAll(io, "{\"name\":\"nameless\"}");
    f.close(io);

    try testing.expectError(error.BadManifest, load(alloc, io, dir));
    try testing.expectError(error.NoManifest, load(alloc, io, "/tmp/polter-no-dir-9c1f"));
}

test "settings round-trip through the file format" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const params = [_]Param{
        .{ .name = "url", .value = "cmd:op read op://Private/hook" },
    };
    const rendered = try (Settings{ .enabled = true, .params = &params }).render(alloc);

    // The secret stayed a reference. Rendering a resolved value into the
    // file is the whole thing `secret.zig` exists to avoid.
    try testing.expect(std.mem.indexOf(u8, rendered, "cmd:op read") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\"enabled\": true") != null);
}

test "settings written by the Windows host" {
    // **The cross-implementation check.** The Rust host writes this file and
    // this parser reads it; a unit test on either side alone proves only that
    // an implementation agrees with itself, and the failure that matters is
    // the two disagreeing. The symptom in the field is silent: a plugin the
    // user configured simply stops being configured.
    //
    // The fixture comes out of the host's own `render_settings`
    // (`windows/host/src/plugins.rs`), regenerated with
    // `polter-host.exe --polter-host-write-settings-fixture=<path>`. It carries a quote,
    // a backslash and non-ASCII on purpose -- escaping is where two JSON
    // implementations actually diverge.
    //
    // `@embedFile` rather than reading a path: a deleted fixture then fails
    // the build instead of quietly testing nothing.
    const fixture = @embedFile("testdata/windows_host_settings.json");

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-winfix-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    var f = try d.createFile(io, "winhost.json", .{});
    try f.writeStreamingAll(io, fixture);
    f.close(io);

    const path = try std.fs.path.join(alloc, &.{ dir, "winhost.json" });
    const settings = Settings.read(alloc, io, path);

    try testing.expect(settings.enabled);
    try testing.expectEqual(@as(usize, 3), settings.params.len);

    var seen_url = false;
    var seen_flag = false;
    var seen_escapes = false;
    for (settings.params) |p| {
        if (std.mem.eql(u8, p.name, "url")) {
            seen_url = true;
            try testing.expectEqualStrings("cmd:op read op://Private/hook", p.value);
        } else if (std.mem.eql(u8, p.name, "verbose")) {
            // A boolean parameter is the *text* true, because `Param.value`
            // is a string on both sides of the wire.
            seen_flag = true;
            try testing.expectEqualStrings("true", p.value);
        } else if (std.mem.eql(u8, p.name, "quote")) {
            seen_escapes = true;
            try testing.expectEqualStrings(
                "a \"quoted\" value, a backslash \\, and 中文",
                p.value,
            );
        }
    }
    try testing.expect(seen_url);
    try testing.expect(seen_flag);
    try testing.expect(seen_escapes);
}

test "the older flat file still delivers" {
    // Before this, the file held parameters alone and the main config said
    // which plugins were on. Reading such a file as "not enabled" would stop
    // delivering notifications for somebody who changed nothing.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-set-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    var f = try d.createFile(io, "webhook.json", .{});
    try f.writeStreamingAll(io,
        \\{"url":"https://example.com/hook"}
    );
    f.close(io);

    const path = try std.fmt.allocPrint(alloc, "{s}/webhook.json", .{dir});
    const settings = Settings.read(alloc, io, path);

    try testing.expect(settings.enabled);
    try testing.expectEqual(@as(usize, 1), settings.params.len);
    try testing.expectEqualStrings("url", settings.params[0].name);
}

test "a plugin nobody has configured is not enabled" {
    // Missing and unreadable both mean "not set up", and something not set
    // up must not be sending anything anywhere.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const settings = Settings.read(
        arena.allocator(),
        threaded.io(),
        "/tmp/polter-no-such-plugin-7f31.json",
    );
    try testing.expect(!settings.enabled);
    try testing.expectEqual(@as(usize, 0), settings.params.len);
}

test "switched off means off, however many parameters are set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-off-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    var f = try d.createFile(io, "webhook.json", .{});
    try f.writeStreamingAll(io,
        \\{"enabled":false,"params":{"url":"https://example.com/hook"}}
    );
    f.close(io);

    const path = try std.fmt.allocPrint(alloc, "{s}/webhook.json", .{dir});
    const settings = Settings.read(alloc, io, path);

    try testing.expect(!settings.enabled);
    try testing.expectEqual(@as(usize, 1), settings.params.len);
}

/// Lay out the two places one plugin's settings are looked for: the user's
/// `<root>/webhook.json` first and the `<root>/webhook/settings.json` a
/// release ships second.
///
/// A `null` writes no file there at all, which is the distinction every one
/// of these tests turns on -- an absent file and a file saying `enabled:
/// false` are the same `Settings` value and must not behave the same way.
fn twoLayers(
    arena: Allocator,
    io: std.Io,
    user: ?[]const u8,
    shipped: ?[]const u8,
) !struct { root: []const u8, paths: []const []const u8 } {
    var raw: [6]u8 = undefined;
    io.random(&raw);

    const root = try std.fmt.allocPrint(arena, "/tmp/polter-two-{x}", .{&raw});
    const ship_dir = try std.fmt.allocPrint(arena, "{s}/webhook", .{root});
    try std.Io.Dir.cwd().createDirPath(io, ship_dir);

    const paths = try arena.alloc([]const u8, 2);
    paths[0] = try std.fmt.allocPrint(arena, "{s}/webhook.json", .{root});
    paths[1] = try std.fmt.allocPrint(arena, "{s}/settings.json", .{ship_dir});

    if (user) |bytes| try putFile(io, paths[0], bytes);
    if (shipped) |bytes| try putFile(io, paths[1], bytes);

    return .{ .root = root, .paths = paths };
}

fn putFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

test "a plugin a release ships may bring its own settings" {
    // Nothing in the config directory, so the copy installed beside the
    // plugin is what there is. Without this a shipped plugin is off and
    // unconfigured until somebody writes a file by hand.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const laid = try twoLayers(alloc, io, null,
        \\{"enabled":true,"params":{"url":"https://example.com/shipped"}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, laid.root) catch {};

    const settings = Settings.readFirst(alloc, io, laid.paths);
    try testing.expect(settings.enabled);
    try testing.expectEqualStrings(
        "https://example.com/shipped",
        valueOf(settings, "url").?,
    );
}

test "switching a shipped plugin off survives the release that ships it on" {
    // The one this whole lookup exists to get right. The user's file says
    // off; the copy beside the plugin says on. Reading these as two
    // `Settings` and preferring the enabled one -- or merging them -- would
    // switch the plugin back on at every upgrade for exactly the person who
    // took the trouble to switch it off.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const laid = try twoLayers(alloc, io,
        \\{"enabled":false,"params":{}}
    ,
        \\{"enabled":true,"params":{"url":"https://example.com/shipped"}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, laid.root) catch {};

    const settings = Settings.readFirst(alloc, io, laid.paths);
    try testing.expect(!settings.enabled);

    // And the shipped parameters do not leak through either: the file that
    // wins is the whole answer, not a base to fill gaps from.
    try testing.expectEqual(@as(usize, 0), settings.params.len);
}

test "the user's parameters are not topped up from the shipped ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const laid = try twoLayers(alloc, io,
        \\{"enabled":true,"params":{"url":"https://example.com/mine"}}
    ,
        \\{"enabled":true,"params":{"url":"https://example.com/shipped","token":"t"}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, laid.root) catch {};

    const settings = Settings.readFirst(alloc, io, laid.paths);
    try testing.expect(settings.enabled);
    try testing.expectEqual(@as(usize, 1), settings.params.len);
    try testing.expectEqualStrings(
        "https://example.com/mine",
        valueOf(settings, "url").?,
    );
}

test "a settings file that will not parse still keeps the shipped one out" {
    // A typo in the user's file reads as "not configured", which reads as
    // off. Falling through to the shipped default here is the one outcome
    // that starts sending things on somebody's behalf because of a syntax
    // error.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const laid = try twoLayers(alloc, io, "{not json",
        \\{"enabled":true,"params":{"url":"https://example.com/shipped"}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, laid.root) catch {};

    const settings = Settings.readFirst(alloc, io, laid.paths);
    try testing.expect(!settings.enabled);
    try testing.expectEqual(@as(usize, 0), settings.params.len);
}

test "no settings anywhere is still not enabled" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const laid = try twoLayers(alloc, io, null, null);
    defer std.Io.Dir.cwd().deleteTree(io, laid.root) catch {};

    const settings = Settings.readFirst(alloc, io, laid.paths);
    try testing.expect(!settings.enabled);
    try testing.expectEqual(@as(usize, 0), settings.params.len);

    // An empty search path is a caller with nowhere to look, not a crash.
    try testing.expect(!Settings.readFirst(alloc, io, &.{}).enabled);
}

test "a manifest declares what it is by what it subscribes to" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"chat-archive","exec":"archive.sh","wants":{"events":["chat"]}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expect(m.wants.subscribes(.chat));
    try testing.expect(!m.wants.subscribes(.terminal_quiet));
    try testing.expect(!m.wants.empty());

    // Subscribed to chat and naming no groups: it will be fed nothing.
    try testing.expect(m.wants.groupless());
}

test "what a manifest wants is read back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"chat-archive","exec":"a.sh",
        \\ "wants":{"events":["chat"],"calls":["group_post"],
        \\          "groups":["build","ops"],"network":true,"exec":["psql"]}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expectEqual(@as(usize, 2), m.wants.groups.len);
    try testing.expectEqualStrings("build", m.wants.groups[0]);
    try testing.expectEqualStrings("ops", m.wants.groups[1]);
    try testing.expect(m.wants.network);
    try testing.expectEqual(@as(usize, 1), m.wants.exec.len);
    try testing.expectEqualStrings("psql", m.wants.exec[0]);

    try testing.expect(m.wants.allows("build"));
    try testing.expect(m.wants.allows("ops"));
    try testing.expect(!m.wants.allows("secrets"));
    try testing.expect(!m.wants.empty());

    try testing.expect(m.wants.subscribes(.chat));
    try testing.expect(m.wants.mayCall("group_post"));

    // Declared exactly, and nothing near it. A plugin that may post is not
    // thereby a plugin that may read.
    try testing.expect(!m.wants.mayCall("group_read"));
}

test "a manifest that declares nothing wants nothing" {
    // The one change that would quietly void the whole feature is reading
    // silence as `["*"]` because an archive "is not getting anything". That
    // hands every group to the one manifest that never asked for a single
    // one, which is the entire thing the declaration exists to stop. A
    // plugin that is fed nothing is loud about it -- `Archive.start`
    // refuses and the user is told which line to add.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"chat-archive","exec":"a.sh"}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expect(m.wants.empty());
    try testing.expect(!m.wants.allows("build"));
    try testing.expect(!m.wants.allows("*"));
    try testing.expect(!m.wants.network);
    try testing.expectEqual(@as(usize, 0), m.wants.exec.len);
}

test "a star means every group" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"chat-archive","exec":"a.sh","wants":{"events":["chat"],"groups":["*"]}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expect(m.wants.allows("build"));
    try testing.expect(m.wants.allows("anything at all"));
    try testing.expect(!m.wants.empty());
    try testing.expect(!m.wants.groupless());
}

test "a wants that will not parse wants nothing" {
    // Both of these load. A typo in one field may not delete a plugin: its
    // author would find a plugin that vanished harder to explain than a
    // plugin that is handed nothing and says so in the log.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const not_object = try manifestFor(alloc, io,
        \\{"key":"chat-archive","exec":"a.sh","wants":7}
    );
    defer std.Io.Dir.cwd().deleteTree(io, not_object) catch {};

    const m = try load(alloc, io, not_object);
    try testing.expect(m.wants.empty());

    const bare_string = try manifestFor(alloc, io,
        \\{"key":"chat-archive","exec":"a.sh","wants":{"groups":"build"}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, bare_string) catch {};

    // A bare string is not a list of one group. Somebody who got the type
    // wrong has not said which groups they want, and reading it as `build`
    // is the same widening as reading silence as `*`, only smaller.
    const b = try load(alloc, io, bare_string);
    try testing.expect(b.wants.empty());
    try testing.expect(!b.wants.allows("build"));
}

test "a group not asked for is not allowed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"chat-archive","exec":"a.sh","wants":{"groups":["build"]}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expect(m.wants.allows("build"));
    try testing.expect(!m.wants.allows("ops"));

    // Whole names, never prefixes: a group called `build` must not drag in
    // one called `build2`, and matching by prefix would.
    try testing.expect(!m.wants.allows("bui"));
    try testing.expect(!m.wants.allows("build2"));
    try testing.expect(!m.wants.allows(""));
}

test "junk in the groups list is skipped, not fatal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"chat-archive","exec":"a.sh",
        \\ "wants":{"groups":["build",7,"ops"]}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expectEqual(@as(usize, 2), m.wants.groups.len);
    try testing.expectEqualStrings("build", m.wants.groups[0]);
    try testing.expectEqualStrings("ops", m.wants.groups[1]);
    try testing.expect(m.wants.allows("build"));
    try testing.expect(m.wants.allows("ops"));
    try testing.expect(!m.wants.allows("7"));
}

test "a manifest keeps the parameters it declares" {
    // The tool surface has to know what a plugin takes, and the plugin's
    // author already writes it down here. Reading it a second time from
    // somewhere else would be a second place to keep in step.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"chat-archive","exec":"a.sh",
        \\ "params":{"type":"object",
        \\   "properties":{
        \\     "backend":{"type":"string","title":"Where to write",
        \\                "description":"postgres or file","enum":["postgres","file"]},
        \\     "dsn":{"type":"string","title":"Postgres connection URI","secret":true},
        \\     "schema":{"type":"string"}},
        \\   "required":["backend"]}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);
    try testing.expectEqual(@as(usize, 3), m.params.len);

    const backend = m.param("backend").?;
    try testing.expectEqualStrings("Where to write", backend.title);
    try testing.expectEqualStrings("postgres or file", backend.description);
    try testing.expect(backend.required);
    try testing.expect(!backend.secret);
    try testing.expectEqual(@as(usize, 2), backend.choices.len);
    try testing.expect(backend.allows("postgres"));
    try testing.expect(backend.allows("file"));
    try testing.expect(!backend.allows("sqlite"));

    // Secret is the author's declaration and nothing else's guess: `dsn`
    // says so, `schema` does not, and neither name would have told anybody.
    const dsn = m.param("dsn").?;
    try testing.expect(dsn.secret);
    try testing.expect(!dsn.required);

    // An open parameter takes anything. A missing `enum` must not read as
    // an empty one, or every value would be refused.
    const schema = m.param("schema").?;
    try testing.expect(!schema.secret);
    try testing.expectEqual(@as(usize, 0), schema.choices.len);
    try testing.expect(schema.allows("public"));

    try testing.expectEqual(@as(?ParamSpec, null), m.param("nothing-like-this"));

    // And it keeps at most `max_specs` of them. Every declared parameter is
    // copied into every `plugin_list` reply an agent reads, and the only
    // other bound on that is the 64KB the manifest itself is read under --
    // which is room for hundreds of one-character names.
    {
        var json: std.Io.Writer.Allocating = .init(alloc);
        try json.writer.writeAll(
            \\{"key":"many","exec":"a.sh",
            \\ "params":{"type":"object","properties":{
        );
        for (0..max_specs + 8) |i| {
            if (i > 0) try json.writer.writeAll(",");
            try json.writer.print("\"p{d}\":{{\"type\":\"string\"}}", .{i});
        }
        try json.writer.writeAll("}}}");

        const capped = try manifestFor(alloc, io, json.written());
        defer std.Io.Dir.cwd().deleteTree(io, capped) catch {};

        const many = try load(alloc, io, capped);
        try testing.expectEqual(max_specs, many.params.len);
    }
}

test "a key that is not a plain name is not a plugin" {
    // A key is spelled into three file paths, and one of them is now
    // written rather than only read. A key of `../../../x` therefore names
    // a settings file outside the polter directories, and `Settings.write`
    // makes the directories on the way to it. Nothing downstream can tell:
    // by then it is a string like any other.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bad = [_][]const u8{
        "../../../.ssh/authorized_keys",
        "a/b",
        "a\\\\b",
        "..",
        ".",
        "with space",
        "",
    };

    for (bad) |key| {
        const json = try std.fmt.allocPrint(
            alloc,
            "{{\"key\":\"{s}\",\"exec\":\"a.sh\"}}",
            .{key},
        );
        const dir = try manifestFor(alloc, io, json);
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

        // Refused at load, so nothing later has to remember to check: a
        // plugin that will not load is one nothing can configure, start, or
        // write a settings file for.
        try testing.expectError(error.BadKey, load(alloc, io, dir));
    }

    // What an ordinary key looks like, so the rule cannot quietly tighten
    // into refusing the plugins that ship with Polter.
    for ([_][]const u8{ "chat-archive", "webhook", "feishu_v2", "a.b" }) |key| {
        const json = try std.fmt.allocPrint(
            alloc,
            "{{\"key\":\"{s}\",\"exec\":\"a.sh\"}}",
            .{key},
        );
        const dir = try manifestFor(alloc, io, json);
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

        const m = try load(alloc, io, dir);
        try testing.expectEqualStrings(key, m.key);
    }
}

test "a parameter with no name is not a parameter" {
    // A property whose name is the empty string would round-trip as a real
    // one: `Manifest.param("")` matches it, `Settings.render` writes an
    // object field with an empty name, and `Settings.read` reads that back
    // as configured. Nothing could ever refer to it, and the tool surface
    // would be willing to set it.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try manifestFor(alloc, io,
        \\{"key":"webhook","exec":"send.sh",
        \\ "params":{"type":"object","properties":{
        \\   "":{"type":"string","secret":true},
        \\   "url":{"type":"string"}}}}
    );
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const m = try load(alloc, io, dir);

    // Passed over, and the plugin still loads: one bad property is the same
    // sort of typo as a bad `wants`, and it must not make the whole plugin
    // vanish.
    try testing.expectEqual(@as(usize, 1), m.params.len);
    try testing.expectEqualStrings("url", m.params[0].name);
    try testing.expectEqual(@as(?ParamSpec, null), m.param(""));
}

test "a manifest with no params schema declares no parameters" {
    // Silence means none, and none means the tool surface may set none.
    // The alternative -- reading silence as "anything goes" -- would let an
    // agent write a name nobody can judge secret or not.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    {
        const dir = try manifestFor(alloc, io,
            \\{"key":"webhook","exec":"send.sh"}
        );
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

        const m = try load(alloc, io, dir);
        try testing.expectEqual(@as(usize, 0), m.params.len);
        try testing.expectEqual(@as(?ParamSpec, null), m.param("url"));
    }

    // A schema that will not read leaves the plugin with no declared
    // parameters rather than making the whole plugin vanish -- the same
    // rule `wants` follows, and for the same reason.
    {
        const dir = try manifestFor(alloc, io,
            \\{"key":"webhook","exec":"send.sh","params":"oops"}
        );
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

        const m = try load(alloc, io, dir);
        try testing.expectEqualStrings("webhook", m.key);
        try testing.expectEqual(@as(usize, 0), m.params.len);
    }

    {
        const dir = try manifestFor(alloc, io,
            \\{"key":"webhook","exec":"send.sh",
            \\ "params":{"type":"object","properties":["url"]}}
        );
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

        const m = try load(alloc, io, dir);
        try testing.expectEqual(@as(usize, 0), m.params.len);
    }
}

test "settings merge keeps what was not named, and an empty value clears one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const before: Settings = .{ .enabled = true, .params = &.{
        .{ .name = "backend", .value = "file" },
        .{ .name = "dsn", .value = "env:OLD" },
        .{ .name = "stream", .value = "laptop" },
    } };

    const after = try before.merge(alloc, &.{
        .{ .name = "backend", .value = "postgres" },
        .{ .name = "dsn", .value = "" },
        .{ .name = "schema", .value = "public" },
    });

    // Whether it is switched on is not a parameter, and merging parameters
    // does not touch it.
    try testing.expect(after.enabled);

    try testing.expectEqualStrings("postgres", valueOf(after, "backend").?);

    // Cleared, not emptied: an unset parameter is absent from the file, so
    // the plugin sees nothing there rather than a value that is nothing.
    try testing.expectEqual(@as(?[]const u8, null), valueOf(after, "dsn"));

    // Untouched names survive, which is what makes a configure call able to
    // change one thing without knowing the rest.
    try testing.expectEqualStrings("laptop", valueOf(after, "stream").?);

    // A name that was not there is added rather than dropped.
    try testing.expectEqualStrings("public", valueOf(after, "schema").?);

    // And exactly once: a replaced parameter must not also be appended.
    try testing.expectEqual(@as(usize, 3), after.params.len);

    // Clearing something that was never set is not an error; it is already
    // the state that was asked for.
    const nothing = try after.merge(alloc, &.{.{ .name = "absent", .value = "" }});
    try testing.expectEqual(@as(usize, 3), nothing.params.len);

    // The result owns its strings, so it outlives whatever it was read out
    // of and whatever the changes came in on.
    const written = try after.render(alloc);
    try testing.expect(std.mem.indexOf(u8, written, "postgres") != null);
    try testing.expect(std.mem.indexOf(u8, written, "env:OLD") == null);
}

fn valueOf(s: Settings, name: []const u8) ?[]const u8 {
    for (s.params) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
    return null;
}

test "settings are written whole or not at all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const root = try std.fmt.allocPrint(alloc, "/tmp/polter-wr-{x}", .{&raw});
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // The directory does not exist yet, which is the ordinary case the
    // first time anybody configures anything.
    const path = try std.fmt.allocPrint(alloc, "{s}/plugins/chat-archive.json", .{root});

    const settings: Settings = .{ .enabled = true, .params = &.{
        .{ .name = "dsn", .value = "env:POLTER_PG" },
    } };
    try settings.write(alloc, io, path);

    const back = Settings.read(alloc, io, path);
    try testing.expect(back.enabled);
    try testing.expectEqualStrings("env:POLTER_PG", valueOf(back, "dsn").?);

    // Written again over itself, because that is what configuring twice
    // does and a rename onto an existing file has to be allowed.
    const second = try settings.merge(alloc, &.{.{ .name = "backend", .value = "postgres" }});
    try second.write(alloc, io, path);

    const again = Settings.read(alloc, io, path);
    try testing.expectEqual(@as(usize, 2), again.params.len);

    // Nothing half-written left behind.
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(io, try std.fmt.allocPrint(alloc, "{s}.new", .{path}), .{}),
    );
}

test "the launch table, read from both sides of the system it switches on" {
    // **The table is asserted with the target as an argument, on purpose.**
    // Baked to `builtin.os.tag`, the Windows rows would be unreachable from a
    // test on the build machine: "the `.ps1` row is wrong" would be something
    // no test here could ever go red for, and the row would be carried on
    // nothing but the care of whoever wrote it. Both sides are read here.
    const alloc = testing.allocator;

    // --- POSIX: unchanged, and that is the load-bearing claim -------------
    //
    // Seven plugins in this repository ship a `.sh` that runs today. The
    // command line for them must come out of this function **exactly** as it
    // went in: one element, the path, nothing added. Anything else is a
    // regression in the thing that already works, bought to fix the thing
    // that does not.
    for ([_]std.Target.Os.Tag{ .macos, .linux, .freebsd }) |tag| {
        const argv = (try launchArgvFor(alloc, tag, "/x/claude-code/provision.sh")).?;
        defer alloc.free(argv);
        try testing.expectEqual(@as(usize, 1), argv.len);
        try testing.expectEqualStrings("/x/claude-code/provision.sh", argv[0]);

        // A plugin with no extension at all -- a compiled binary -- is the
        // same story.
        const bare = (try launchArgvFor(alloc, tag, "/x/thing/plugin")).?;
        defer alloc.free(bare);
        try testing.expectEqual(@as(usize, 1), bare.len);
        try testing.expectEqualStrings("/x/thing/plugin", bare[0]);

        // And `archive.py`, which is shipped and must keep working: a
        // shebang is all POSIX needs.
        const py = (try launchArgvFor(alloc, tag, "/x/archive/archive.py")).?;
        defer alloc.free(py);
        try testing.expectEqual(@as(usize, 1), py.len);

        // What POSIX cannot start.
        try testing.expect((try launchArgvFor(alloc, tag, "/x/p/provision.ps1")) == null);
        try testing.expect((try launchArgvFor(alloc, tag, "/x/p/run.cmd")) == null);
    }

    // --- Windows ----------------------------------------------------------
    {
        const argv = (try launchArgvFor(alloc, .windows, "C:\\p\\antigravity\\provision.ps1")).?;
        defer alloc.free(argv);

        try testing.expectEqual(@as(usize, 7), argv.len);
        try testing.expectEqualStrings("powershell", argv[0]);
        try testing.expectEqualStrings("-NoProfile", argv[1]);
        try testing.expectEqualStrings("-NonInteractive", argv[2]);
        try testing.expectEqualStrings("-ExecutionPolicy", argv[3]);
        try testing.expectEqualStrings("Bypass", argv[4]);

        // `-File` and not `-Command`: measured on the Windows test machine,
        // `powershell -Command "..."` echoes the command instead of running
        // it. And the path comes last, as `-File`'s argument.
        try testing.expectEqualStrings("-File", argv[5]);
        try testing.expectEqualStrings("C:\\p\\antigravity\\provision.ps1", argv[6]);
    }

    {
        const argv = (try launchArgvFor(alloc, .windows, "C:\\p\\x\\go.CMD")).?;
        defer alloc.free(argv);
        // Extensions are case-insensitive on Windows, so the table is too.
        try testing.expectEqual(@as(usize, 3), argv.len);
        try testing.expectEqualStrings("cmd", argv[0]);
        try testing.expectEqualStrings("/c", argv[1]);
    }

    // **The case the whole mechanism exists for.** Seven shipped plugins
    // declare a `.sh`; on Windows that used to be `error.InvalidExe` at
    // spawn, then a back-off, then the same failure again.
    try testing.expect((try launchArgvFor(alloc, .windows, "C:\\p\\c\\provision.sh")) == null);
    try testing.expect((try launchArgvFor(alloc, .windows, "C:\\p\\a\\archive.py")) == null);

    // A native binary is still just run.
    {
        const argv = (try launchArgvFor(alloc, .windows, "C:\\p\\x\\tool.exe")).?;
        defer alloc.free(argv);
        try testing.expectEqual(@as(usize, 1), argv.len);
    }
}

/// A directory holding one `plugin.json`, for the manifest tests.
fn manifestDir(alloc: Allocator, io: std.Io, json: []const u8) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-execos-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);

    var f = try d.createFile(io, "plugin.json", .{});
    defer f.close(io);
    try f.writeStreamingAll(io, json);

    return dir;
}

test "a manifest names the file for this system, and says so when there is none" {
    // `exec_<os>` is purely additive: a manifest that names only `exec` means
    // what it always meant. The key is spelled with `builtin.os.tag`'s own
    // name so this test reads the same row the product will.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const os_key = "exec_" ++ @tagName(builtin.os.tag);

    // 1. Only `exec`. Unchanged behaviour, and on this system it runs.
    {
        const dir = try manifestDir(alloc, io,
            \\{"key":"only-exec","exec":"provision.sh"}
        );
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        const m = try load(alloc, io, dir);
        try testing.expectEqualStrings(
            try std.fmt.allocPrint(alloc, "{s}/provision.sh", .{dir}),
            m.exec,
        );
        try testing.expect(m.runnable != (builtin.os.tag == .windows));
    }

    // 2. Both, and the one for this system wins.
    {
        const json = try std.fmt.allocPrint(
            alloc,
            "{{\"key\":\"both\",\"exec\":\"provision.sh\",\"{s}\":\"chosen.bin\"}}",
            .{os_key},
        );
        const dir = try manifestDir(alloc, io, json);
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        const m = try load(alloc, io, dir);
        try testing.expectEqualStrings(
            try std.fmt.allocPrint(alloc, "{s}/chosen.bin", .{dir}),
            m.exec,
        );
        try testing.expect(m.runnable);
    }

    // 3. A key for some other system is not this system's, and the fallback
    //    still applies. Picking it up would be worse than ignoring it: the
    //    plugin would run a file written for somebody else's OS.
    {
        const other = if (builtin.os.tag == .windows) "exec_linux" else "exec_windows";
        const json = try std.fmt.allocPrint(
            alloc,
            "{{\"key\":\"other\",\"exec\":\"provision.sh\",\"{s}\":\"not-ours.x\"}}",
            .{other},
        );
        const dir = try manifestDir(alloc, io, json);
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        const m = try load(alloc, io, dir);
        try testing.expectEqualStrings(
            try std.fmt.allocPrint(alloc, "{s}/provision.sh", .{dir}),
            m.exec,
        );
    }

    // 4. **The third state.** A manifest naming only something this system
    //    cannot start is not malformed -- `load` succeeds, and says so on
    //    `runnable`. Reported once at load rather than discovered at every
    //    spawn; see `Manifest.runnable`.
    {
        const foreign = if (builtin.os.tag == .windows) "provision.sh" else "provision.ps1";
        const json = try std.fmt.allocPrint(
            alloc,
            "{{\"key\":\"foreign\",\"exec\":\"{s}\"}}",
            .{foreign},
        );
        const dir = try manifestDir(alloc, io, json);
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        const m = try load(alloc, io, dir);
        try testing.expect(!m.runnable);
        try testing.expectEqualStrings("foreign", m.key);
    }
}

test "agent_cli: a plugin that manages a CLI says so, and one that does not is untouched" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-cli-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);

    const cases = [_]struct { json: []const u8, has: bool }{
        .{ .json =
        \\{"key":"claude-code","exec":"p.sh","agent_cli":{"label":"Claude Code","bin":"claude","adapter":"adapter.py"}}
        , .has = true },
        // No section: nothing, and the plugin still loads.
        .{ .json =
        \\{"key":"archive","exec":"a.py"}
        , .has = false },
        // A key that could not go into personas.json: the section goes,
        // the plugin stays.
        .{ .json =
        \\{"key":"Claude_Code","exec":"p.sh","agent_cli":{"adapter":"adapter.py"}}
        , .has = false },
        // No adapter to run.
        .{ .json =
        \\{"key":"x","exec":"p.sh","agent_cli":{"label":"X"}}
        , .has = false },
    };

    for (cases) |c| {
        var f = try d.createFile(io, "plugin.json", .{});
        try f.writeStreamingAll(io, c.json);
        f.close(io);

        const m = try load(alloc, io, dir);
        try testing.expectEqual(c.has, m.agent_cli != null);
    }

    var f = try d.createFile(io, "plugin.json", .{});
    try f.writeStreamingAll(io, cases[0].json);
    f.close(io);
    const m = try load(alloc, io, dir);
    const cli = m.agent_cli.?;
    try testing.expectEqualStrings("Claude Code", cli.label);
    try testing.expectEqualStrings("claude", cli.bin);
    const want = try std.fmt.allocPrint(alloc, "{s}/adapter.py", .{dir});
    try testing.expectEqualStrings(want, cli.adapter);
}

test "agent_cli: identify_env is a list of plain names, taken whole or not at all (task 1635)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Case = struct { json: []const u8, names: []const []const u8 };
    const cases = [_]Case{
        .{ .json =
        \\{"adapter":"a.py","identify_env":["CLAUDECODE","AI_AGENT","CLAUDE_CODE_SESSION_ID"]}
        , .names = &.{ "CLAUDECODE", "AI_AGENT", "CLAUDE_CODE_SESSION_ID" } },
        // None named: none.
        .{ .json =
        \\{"adapter":"a.py"}
        , .names = &.{} },
        // One that is not a name -- lower case, a space, `=` -- and none
        // are taken.
        .{ .json =
        \\{"adapter":"a.py","identify_env":["CLAUDECODE","path"]}
        , .names = &.{} },
        .{ .json =
        \\{"adapter":"a.py","identify_env":["CLAUDECODE","A=B"]}
        , .names = &.{} },
        .{ .json =
        \\{"adapter":"a.py","identify_env":["1ABC"]}
        , .names = &.{} },
        // Not a list, or too many.
        .{ .json =
        \\{"adapter":"a.py","identify_env":"CLAUDECODE"}
        , .names = &.{} },
        .{ .json =
        \\{"adapter":"a.py","identify_env":["A","B","C","D","E","F","G","H","I"]}
        , .names = &.{} },
    };
    for (cases) |c| {
        const a = (try std.json.parseFromSliceLeaky(std.json.Value, alloc, c.json, .{})).object;
        const got = try identifyEnvOf(alloc, "claude-code", a);
        try testing.expectEqual(c.names.len, got.len);
        for (c.names, got) |want, have| try testing.expectEqualStrings(want, have);
    }
}

test "agent_cli: each system is given the adapter it can start" {
    // **The shipped manifest, read from the repository**, not a copy of it
    // written here: the defect this is for was in that file (an `adapter`
    // and no `adapter_windows`), and a fixture would have been right while
    // the file was wrong.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const read = struct {
        fn f(i: std.Io, a: Allocator, path: []const u8) ![]u8 {
            return std.Io.Dir.cwd().readFileAlloc(i, path, a, .limited(1024 * 1024)) catch |err| {
                std.debug.print(
                    "cannot read {s} ({t}). Run `zig build test` from the repository root.\n",
                    .{ path, err },
                );
                return error.ShippedPluginUnreadable;
            };
        }
    }.f;

    const text = try read(io, alloc, "plugins/claude-code/plugin.json");
    const shipped = (try std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{})).object;

    // Windows: the PowerShell port, started the way every `.ps1` is.
    const win = (try agentCliFor(alloc, .windows, "claude-code", "C:\\p\\claude-code", shipped)).?;
    try testing.expect(endsWithIgnoreCase(win.adapter, "/adapter.ps1"));
    try testing.expect(win.runnable);
    const argv = (try launchArgvFor(alloc, .windows, win.adapter)).?;
    try testing.expectEqualStrings("powershell", argv[0]);
    try testing.expectEqualStrings(win.adapter, argv[argv.len - 1]);

    // Everywhere else: exactly what it was -- `adapter.py`, run as itself.
    for ([_]std.Target.Os.Tag{ .macos, .linux, .freebsd }) |tag| {
        const cli = (try agentCliFor(alloc, tag, "claude-code", "/p/claude-code", shipped)).?;
        try testing.expectEqualStrings("/p/claude-code/adapter.py", cli.adapter);
        try testing.expect(cli.runnable);
        const a = (try launchArgvFor(alloc, tag, cli.adapter)).?;
        try testing.expectEqual(@as(usize, 1), a.len);
        try testing.expectEqualStrings(cli.adapter, a[0]);
    }

    // **A plugin without `adapter_windows` is unchanged on Windows**: it is
    // given its `adapter`, and a `.py` there is said at load to be one this
    // system cannot start -- which is what `launch.zig` reports, rather than
    // a spawn that fails later.
    const bare = (try std.json.parseFromSliceLeaky(std.json.Value, alloc,
        \\{"key":"claude-code","exec":"p.sh","agent_cli":{"label":"Claude Code","bin":"claude","adapter":"adapter.py"}}
    , .{})).object;
    const old = (try agentCliFor(alloc, .windows, "claude-code", "C:\\p", bare)).?;
    try testing.expect(endsWithIgnoreCase(old.adapter, "/adapter.py"));
    try testing.expect(!old.runnable);
    try testing.expect((try launchArgvFor(alloc, .windows, old.adapter)) == null);
    const posix = (try agentCliFor(alloc, .macos, "claude-code", "/p", bare)).?;
    try testing.expect(posix.runnable);

    // And the files the manifest names are there. A name for a file that
    // does not ship is a Windows launch that fails exactly as before.
    _ = try read(io, alloc, "plugins/claude-code/adapter.py");
    _ = try read(io, alloc, "plugins/claude-code/adapter.ps1");
}

test "agent_cli: a CLI key is exactly a key personas.json accepts" {
    const persona = @import("persona.zig");
    const samples = [_][]const u8{
        "claude-code", "codex",   "opencode",    "a",
        "",            "Claude",  "claude_code", "claude.code",
        "x" ** 32,     "x" ** 33,
    };
    for (samples) |k| {
        try testing.expectEqual(persona.isValidKey(k), validCliKey(k));
    }
}

test "Settings.parseChange reads enabled and string params" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const c = try Settings.parseChange(arena.allocator(),
        \\{"enabled": false, "params": {"webhook": "env:HOOK", "mode": ""}}
    );
    try std.testing.expectEqual(@as(?bool, false), c.enable);
    try std.testing.expectEqual(@as(usize, 2), c.params.len);
    try std.testing.expectEqualStrings("webhook", c.params[0].name);
    try std.testing.expectEqualStrings("env:HOOK", c.params[0].value);
    try std.testing.expectEqualStrings("", c.params[1].value);
}

test "Settings.parseChange leaves out what was not said" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const c = try Settings.parseChange(arena.allocator(), "{}");
    try std.testing.expectEqual(@as(?bool, null), c.enable);
    try std.testing.expectEqual(@as(usize, 0), c.params.len);
}

test "Settings.parseChange refuses what it would drop" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.BadSettings, Settings.parseChange(a, "[]"));
    try std.testing.expectError(error.BadSettings, Settings.parseChange(a, "{"));
    try std.testing.expectError(error.BadSettings, Settings.parseChange(a,
        \\{"enabled": "yes"}
    ));
    try std.testing.expectError(error.BadSettings, Settings.parseChange(a,
        \\{"params": {"port": 8080}}
    ));
    try std.testing.expectError(error.BadSettings, Settings.parseChange(a,
        \\{"params": []}
    ));
    try std.testing.expectError(error.BadSettings, Settings.parseChange(a,
        \\{"enable": true}
    ));
}

test "1656: a declared title prefix says awaiting approval, and only a prefix" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"title_says":{"awaiting_approval":{"starts_with":["[ ! ] Action Required","[ . ] Action Required"]}}}
    , .{});
    const says = try titleSaysOf(a, "codex", parsed.object);
    try testing.expectEqual(@as(usize, 2), says.awaiting_approval.len);
    try testing.expect(says.awaitsApproval("[ ! ] Action Required | t1653-w"));
    try testing.expect(says.awaitsApproval("[ . ] Action Required | t1653-w"));
    // Somewhere other than the start is not what was declared.
    try testing.expect(!says.awaitsApproval("zsh: [ ! ] Action Required"));
    try testing.expect(!says.awaitsApproval("[ ! ] Action"));
    try testing.expect(!says.awaitsApproval(""));
    try testing.expect(!TitleSays.none.awaitsApproval("[ ! ] Action Required"));
}

test "1656: a title prefix that would match everything, or nothing, is not taken" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"title_says":{"awaiting_approval":{"starts_with":["", 7, "ok", "tab\there", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"]}}}
    , .{});
    const says = try titleSaysOf(a, "x", parsed.object);
    try testing.expectEqual(@as(usize, 1), says.awaiting_approval.len);
    try testing.expectEqualStrings("ok", says.awaiting_approval[0]);
    // The empty one would have made every title a wait.
    try testing.expect(!says.awaitsApproval("zsh"));

    const wrong = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"title_says":{"awaiting_approval":["[ ! ]"]}}
    , .{});
    try testing.expectEqual(@as(usize, 0), (try titleSaysOf(a, "x", wrong.object)).awaiting_approval.len);
}

test "1656: the first plugin whose title matches is the one named" {
    const ms = [_]Manifest{
        .{ .key = "plain", .exec = "/p" },
        .{ .key = "codex", .exec = "/c", .title_says = .{ .awaiting_approval = &.{"[ ! ] Action Required"} } },
    };
    try testing.expectEqualStrings("codex", titleAwaitsApproval(&ms, "[ ! ] Action Required | w").?);
    try testing.expect(titleAwaitsApproval(&ms, "zsh") == null);
}

test "1656: the shipped Codex manifest declares the titles Codex 0.163 was measured writing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("plugin_codex_json"), .{});
    const says = try titleSaysOf(a, "codex", parsed.object);
    // Both phases of the blink, byte for byte as recorded with `script -r`
    // (issue-fix/1653-evidence/t1653-R.rec): `ESC ] 0 ; [ ! ] Action
    // Required | t1653-w BEL`, then `[ . ]` a second later.
    try testing.expect(says.awaitsApproval("[ ! ] Action Required | t1653-w"));
    try testing.expect(says.awaitsApproval("[ . ] Action Required | t1653-w"));
    // What it writes while working is not a wait.
    try testing.expect(!says.awaitsApproval("\u{2827} t1653-w"));
}

fn shippedSays(a: Allocator, key: []const u8, json: []const u8) !Manifest {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    return .{
        .key = key,
        .exec = "p",
        .screen_says = try screenSaysOf(a, key, parsed.object),
        .hooks_report_approval = hooksReportApprovalOf(key, parsed.object),
    };
}

// The `token_says` two shipped manifests declare (task 2584), read out of
// their own files.
//
// **Both halves have to be asserted, and either one alone is worthless.**
// That the file declares the section at all is what a person reading the
// plugin directory sees; that the core reads it back to the same fields is
// what makes the declaration mean anything. A `keys` path that no longer
// matches what the CLI writes -- a renamed field, a level of nesting
// gained -- reads as `null` for every stretch, which in the product looks
// exactly like a CLI whose usage Polter cannot read, and no test of the
// arithmetic inside `token_says.zig` can see it.
test "usage: the shipped Claude Code and Codex manifests declare where their token numbers are" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const claude = (try tokenSaysOf(a, "claude-code", (try std.json.parseFromSliceLeaky(
        std.json.Value,
        a,
        @embedFile("plugin_claude_code_json"),
        .{},
    )).object)).?;
    // The status line hands over **how full the window is**, not what the
    // session has spent: `current_usage` is the last API call. Read as a
    // total it would be subtracted, and the difference of two levels is a
    // number nobody spent.
    try testing.expectEqual(token_says.Source.statusline, claude.source);
    try testing.expectEqual(token_says.Counts.window, claude.counts);
    // The four fields of `current_usage`, as Claude Code 2.1.312's own
    // schema describes them ("Token usage from last API call ... input
    // tokens for current context, output tokens generated, cache ...").
    try testing.expectEqual(@as(usize, 4), claude.keys.len);
    try testing.expectEqualStrings("context_window.current_usage.input_tokens", claude.keys[0]);
    try testing.expectEqualStrings("context_window.current_usage.output_tokens", claude.keys[1]);
    try testing.expectEqualStrings("context_window.current_usage.cache_creation_input_tokens", claude.keys[2]);
    try testing.expectEqualStrings("context_window.current_usage.cache_read_input_tokens", claude.keys[3]);
    // A status line's input carries no timestamp: the moment is the reading.
    try testing.expectEqual(@as(?[]const u8, null), claude.at_key);

    const codex = (try tokenSaysOf(a, "codex", (try std.json.parseFromSliceLeaky(
        std.json.Value,
        a,
        @embedFile("plugin_codex_json"),
        .{},
    )).object)).?;
    // A session's running spend, which is what a difference means
    // something of.
    try testing.expectEqual(token_says.Source.session_record, codex.source);
    try testing.expectEqual(token_says.Counts.total, codex.counts);
    try testing.expectEqual(@as(usize, 1), codex.keys.len);
    try testing.expectEqualStrings("payload.info.total_token_usage.total_tokens", codex.keys[0]);
    try testing.expectEqualStrings("timestamp", codex.at_key.?);

    // **And the two halves meet**: each declaration reads the payload its
    // own CLI writes. The Claude Code one is the shape measured on 2.1.312
    // (its schema's own words), the Codex one is a line out of a real
    // rollout record in `$CODEX_HOME/sessions/`.
    const claude_line =
        \\{"session_id":"s","context_window":{"total_input_tokens":15234,
        \\ "current_usage":{"input_tokens":19113,"output_tokens":250,
        \\   "cache_creation_input_tokens":100,"cache_read_input_tokens":40}}}
    ;
    const got = (try token_says.readingOf(a, "claude-code", "s", 7, try std.json.parseFromSliceLeaky(
        std.json.Value,
        a,
        claude_line,
        .{},
    ), claude)).?;
    try testing.expectEqual(@as(u64, 19_503), got.tokens);

    const codex_line =
        \\{"timestamp":"2026-10-24T13:30:48.093Z","type":"event_msg","payload":{"type":"token_count",
        \\ "info":{"total_token_usage":{"input_tokens":49384495,"output_tokens":460060,
        \\          "total_tokens":49844555}}}}
    ;
    const got_codex = (try token_says.readingOf(a, "codex", "s", 7, try std.json.parseFromSliceLeaky(
        std.json.Value,
        a,
        codex_line,
        .{},
    ), codex)).?;
    try testing.expectEqual(@as(u64, 49_844_555), got_codex.tokens);

    // The two CLIs Polter starts that do **not** declare one: an opencode
    // whose event is not forwarded to Polter, and an agy whose status line
    // is Antigravity's own. A manifest that declares nothing reads as
    // "nothing to read", which is the honest answer and not an error.
    for ([_][]const u8{
        @embedFile("plugin_opencode_json"),
        @embedFile("plugin_opencode_v2_json"),
        @embedFile("plugin_antigravity_json"),
    }) |json| {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
        try testing.expect((try tokenSaysOf(a, "x", parsed.object)) == null);
    }

    // A manifest whose section is there and does not read costs the section
    // and nothing else: its other jobs keep working.
    const broken = (try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"source":"statusline","counts":"windowish","keys":["a"]}
    , .{})).object;
    try testing.expect((try tokenSaysOf(a, "x", broken)) == null);
    const not_an_object = (try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"token_says\":3}", .{})).object;
    try testing.expect((try tokenSaysOf(a, "x", not_an_object)) == null);
}

test "1682: only a CLI whose hooks report no approval has its screen read while they are live" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The three shipped manifests. Codex declares screen texts too -- for
    // `terminal_answer_prompt` -- and its hooks say approvals, so they are
    // never read for this.
    const all = [_]Manifest{
        try shippedSays(a, "claude-code", @embedFile("plugin_claude_code_json")),
        try shippedSays(a, "codex", @embedFile("plugin_codex_json")),
        try shippedSays(a, "antigravity", @embedFile("plugin_antigravity_json")),
    };
    try testing.expect(all[1].screen_says.declared());
    try testing.expect(screenApprovalFor(&all, "codex") == null);
    try testing.expect(screenApprovalFor(&all, "claude-code") == null);
    try testing.expect(screenApprovalFor(&all, "nobody") == null);

    // Antigravity's box, as agy 1.4.0 drew it (task 1682).
    const says = screenApprovalFor(&all, "antigravity").?;
    const box =
        \\● Ran
        \\
        \\Requesting permission for:
        \\   echo agy-probe
        \\
        \\Run this command?
        \\> 1. Yes, run command
        \\  2. Yes, and always allow in this conversation for commands that start with 'echo'
        \\  4. No, cancel
        \\
    ;
    try testing.expectEqualStrings("Requesting permission for:", says.approvalSaid(box).?);
    try testing.expect(says.approvalSaid("> Run the shell command: echo agy-probe\n  Generating...\n") == null);
    // An MCP tool's box words it differently (agy 1.4.2).
    const mcp_box =
        \\polter_polter/me
        \\
        \\Allow calling this tool?
        \\> 1. Yes, allow tool call
        \\  2. Yes, and always allow tool 'polter_polter/me' in this conversation
        \\
    ;
    try testing.expectEqualStrings("Allow calling this tool?", says.approvalSaid(mcp_box).?);

    // Anything but true or false is the default.
    const odd = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"hooks_report_approval\":\"no\"}", .{});
    try testing.expect(hooksReportApprovalOf("x", odd.object));
    const off = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"hooks_report_approval\":false}", .{});
    try testing.expect(!hooksReportApprovalOf("x", off.object));
}

test "1777: each shipped CLI's box is walked with its own key, and down unless it says otherwise" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = [_]Manifest{
        try shippedSays(a, "claude-code", @embedFile("plugin_claude_code_json")),
        try shippedSays(a, "codex", @embedFile("plugin_codex_json")),
        try shippedSays(a, "antigravity", @embedFile("plugin_antigravity_json")),
        try shippedSays(a, "opencode", @embedFile("plugin_opencode_json")),
    };
    // The three whose boxes list options one under another: what every box
    // was walked with before.
    try testing.expectEqualStrings("arrow_down", nextOptionKey(&all, "claude-code"));
    try testing.expectEqualStrings("arrow_down", nextOptionKey(&all, "codex"));
    try testing.expectEqualStrings("arrow_down", nextOptionKey(&all, "antigravity"));
    // opencode's is a row.
    try testing.expectEqualStrings("arrow_right", nextOptionKey(&all, "opencode"));
    // A CLI nobody knows, or no CLI at all: down, as before.
    try testing.expectEqualStrings("arrow_down", nextOptionKey(&all, "nobody"));
    try testing.expectEqualStrings("arrow_down", nextOptionKey(&all, null));

    // A word it does not know is down, not a key nobody declared.
    const odd = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"screen_says":{"awaiting_approval":{"contains":["Permission required"],"next_option":"tab"}}}
    , .{});
    try testing.expectEqual(NextOption.arrow_down, (try screenSaysOf(a, "x", odd.object)).next_option);
    const wrong = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"screen_says":{"awaiting_approval":{"contains":["Permission required"],"next_option":1}}}
    , .{});
    try testing.expectEqual(NextOption.arrow_down, (try screenSaysOf(a, "x", wrong.object)).next_option);
}

test "1777: the shipped opencode manifest declares the box opencode 1.2.10 draws" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = [_]Manifest{try shippedSays(a, "opencode", @embedFile("plugin_opencode_json"))};
    // Its hooks will say approvals (`permission.asked`), so its screen is
    // not read for one while they are live -- only for a blind answer.
    try testing.expect(screenApprovalFor(&all, "opencode") == null);

    // Put together from `routes/session/permission.tsx` at v1.2.10 -- a
    // header row `△ Permission required`, the request, and the three
    // options in one row -- **not read off a screen**: no opencode here has
    // a model to ask for a command with.
    const box =
        \\△ Permission required
        \\  # Shell command
        \\  $ echo oc-probe
        \\
        \\  Allow once   Allow always   Reject
        \\  ⇆ select  enter confirm
        \\
    ;
    try testing.expectEqualStrings("Permission required", all[0].screen_says.approvalSaid(box).?);
    try testing.expect(all[0].screen_says.approvalSaid("┃  Ask anything...\n  Build  local-vllm\n") == null);
}

test "1787: agy's trust question broken over two rows in a narrow split is still the question" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const agy = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("plugin_antigravity_json"), .{});
    const says = try startupSaysOf(a, "antigravity", agy.object);

    // Read off a narrow split by the test session (t1746b-20, agy 1.4.2):
    // agy wraps at a word.
    const narrow =
        \\Accessing workspace:
        \\/h/t1746b-repo-wt/w1
        \\Do you trust the contents of this
        \\project?
        \\Antigravity CLI requires permission
        \\to read, edit, and execute files
        \\here.
        \\> Yes, I trust this folder
        \\  No, exit
        \\  ↑/↓ Navigate · enter Confirm
    ;
    try testing.expectEqual(StartupSays.Verdict.blocked, says.verdict(narrow));
    try testing.expectEqualStrings("Do you trust the contents of this project?", says.blockSaid(narrow).?);

    // A terminal breaking a word inside it, and spaces doubled.
    try testing.expectEqual(StartupSays.Verdict.blocked, says.verdict(
        \\Do you trust the contents of this proj
        \\ect?
        \\> Yes, I trust this folder
    ));
    try testing.expectEqual(StartupSays.Verdict.blocked, says.verdict("Do  you trust   the contents of this\r\n project?\n"));

    // Not the question: half of it, its words scattered, or talk about it.
    try testing.expectEqual(StartupSays.Verdict.neither, says.verdict(
        \\Do you trust the contents of this
        \\repository's README before running it?
    ));
    try testing.expectEqual(StartupSays.Verdict.neither, says.verdict(
        \\project? trust the contents of this, do you
    ));
    try testing.expect(says.blockSaid("I asked: do you trust the contents of this project?\n") == null);

    // The input box's own words, broken over two rows, are its input box.
    try testing.expectEqual(StartupSays.Verdict.ready, says.verdict(
        \\>
        \\? for
        \\shortcuts
    ));
    try testing.expectEqual(StartupSays.Verdict.neither, says.verdict("? for help, or shortcuts\n"));
}

test "1682: what agy shows before it connects: the trust box blocks, its input box lets the first line in" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const agy = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("plugin_antigravity_json"), .{});
    const all = [_]Manifest{
        .{ .key = "antigravity", .exec = "p", .startup_says = try startupSaysOf(a, "antigravity", agy.object) },
        .{ .key = "codex", .exec = "p" },
    };
    try testing.expect(startupFor(&all, "codex") == null);
    try testing.expect(startupFor(&all, "claude-code") == null);
    const says = startupFor(&all, "antigravity").?;
    try testing.expect(says.ready_without_agent);
    try testing.expect(says.tools_from_second_turn);

    // The three screens agy 1.4.0 showed on the way up (task 1682).
    try testing.expectEqual(StartupSays.Verdict.blocked, says.verdict(
        \\Accessing workspace:
        \\
        \\/h/project
        \\
        \\Do you trust the contents of this project?
        \\
        \\Antigravity CLI requires permission to read, edit, and execute files here.
        \\
        \\> Yes, I trust this folder
        \\  No, exit
        \\
        \\  ↑/↓ Navigate · enter Confirm
    ));
    try testing.expectEqual(StartupSays.Verdict.ready, says.verdict(
        \\            Antigravity CLI 1.4.0
        \\              Gemini 3.8 Flash (Low)
        \\────────────────────────────────
        \\>
        \\────────────────────────────────
        \\? for shortcuts
    ));
    try testing.expectEqual(StartupSays.Verdict.neither, says.verdict(
        \\ Welcome to the Antigravity CLI. You are currently not signed in.
        \\
        \\ Select login method:
        \\ > 1. Google OAuth
        \\2. Use a Google Cloud project
    ));
    // A shell is neither, whatever it printed long ago.
    try testing.expectEqual(StartupSays.Verdict.neither, says.verdict("$ ls\nREADME.md\n$ "));

    // Malformed sections are nothing, not half of something.
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"startup_says":{"blocks":["", "x"],"ready_says":"? for shortcuts","ready_without_agent":"yes"}}
    , .{});
    const got = try startupSaysOf(a, "x", bad.object);
    try testing.expect(!got.declared());
    try testing.expect(!got.ready_without_agent);
}

test "1746: the shipped Codex manifest knows the boxes codex 0.154 asks before it starts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("plugin_codex_json"), .{});
    const says = try startupSaysOf(a, "codex", parsed.object);
    try testing.expectEqual(@as(usize, 3), says.blocks.len);
    // A question to wait on, never a box whose input box lets a line in.
    try testing.expect(!says.ready_without_agent);
    try testing.expect(!says.tools_from_second_turn);

    // **One machine, one version**: codex-cli 0.154.0 on Windows 11, a
    // terminal about 109 columns wide, read with terminal_read on
    // 2026-10-18 (task 1686 r3). Copied verbatim, leading spaces kept. Only
    // the question is matched: what follows it on its line wraps with the
    // width, and the last line differs between a first start and a later
    // one ("Press enter to continue" with or without "and create a
    // sandbox..."). The sandbox sentence is matched by its first words: the
    // whole of it is longer than a declared text may be, and wraps sooner.
    try testing.expectEqual(StartupSays.Verdict.blocked, says.verdict(
        \\  Welcome to Codex, OpenAI's command-line coding agent
        \\
        \\> You are in D:\polter\t1686\r3\work
        \\
        \\  Do you trust the contents of this directory? Working with untrusted contents comes with higher risk of
        \\  prompt injection. Trusting the directory allows project-local config, hooks, and exec policies to load.
        \\
        \\› 1. Yes, continue
        \\  2. No, quit
        \\
        \\  Press enter to continue and create a sandbox...
    ));
    try testing.expectEqual(StartupSays.Verdict.blocked, says.verdict(
        \\  Tip: New Build faster with Codex.
        \\
        \\
        \\  Set up the Codex agent sandbox to protect your files and control network access. Learn more
        \\  <https://developers.openai.com/codex/windows>
        \\
        \\› 1. Set up default sandbox (requires Administrator permissions)
        \\  2. Use non-admin sandbox (higher risk if prompt injected)
        \\  3. Quit
        \\
        \\  Press enter to confirm or esc to go back
    ));
    // Seen for a codex started by hand and for one started by role_launch
    // alike (task 1748). Its default runs `npm install -g`, so a return
    // typed into it would change the machine's codex.
    try testing.expectEqual(StartupSays.Verdict.blocked, says.verdict(
        \\  ✨ Update available! 0.154.0 -> 0.163.0
        \\  Release notes: https://github.com/openai/codex/releases/latest
        \\
        \\› 1. Update now (runs `npm install -g @openai/codex`)
        \\  2. Skip
        \\  3. Skip until next version
        \\  Press enter to continue
    ));
    try testing.expectEqual(StartupSays.Verdict.neither, says.verdict("› Ask Codex to do anything\n"));
}

test "1746: a line meant for agy's second turn waits for its first to be over" {
    const says: StartupSays = .{ .blocks = &.{"Do you trust the contents of this project?"}, .ready_says = &.{"? for shortcuts"}, .ready_without_agent = true, .tools_from_second_turn = true };
    const working = "> You are the supervisor...\n\n  Thinking...\n";
    const box = ">\n────\n? for shortcuts\n";
    // Its hooks say the turn is still going: not over, whatever the screen.
    try testing.expect(!says.firstTurnOver(false, box));
    // The hook first, the box later (task 1746, round two): over only once
    // the box shows.
    try testing.expect(!says.firstTurnOver(true, working));
    try testing.expect(says.firstTurnOver(true, box));
    // They do not: its input box, and only that.
    try testing.expect(!says.firstTurnOver(null, working));
    try testing.expect(says.firstTurnOver(null, box));
    try testing.expect(!says.firstTurnOver(null, "Do you trust the contents of this project?\n> Yes\n? for shortcuts\n"));
}

test "1668: a declared screen text says a box is up only in the bottom rows" {
    const says: ScreenSays = .{ .awaiting_approval = &.{"Do you want to proceed?"}, .next_option = .arrow_down };
    try testing.expect(says.awaitsApproval(" Bash command\n   rm -rf dist/\n Do you want to proceed?\n ❯ 1. Yes\n\n\n"));
    try testing.expect(!says.awaitsApproval("$ ls\nREADME.md\n"));

    // The same words above the bottom rows are scrollback: a box answered.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, " Do you want to proceed?\n");
    for (0..ScreenSays.rows) |_| try buf.appendSlice(testing.allocator, "⏺ done\n");
    try testing.expect(!says.awaitsApproval(buf.items));
}

test "1668: which CLI it is decides whose screen texts are read, and silence is not a no" {
    const codex: Manifest = .{ .key = "codex", .exec = "p", .screen_says = .{ .awaiting_approval = &.{" to run tool \""}, .next_option = .arrow_down } };
    const silent: Manifest = .{ .key = "opencode", .exec = "p" };
    const all = [_]Manifest{ silent, codex };
    const box = "  Allow the polter MCP server to run tool \"me\"?\n  › 1. Allow\n";
    const none = "› Ask Codex to do anything\n";

    try testing.expectEqual(ScreenVerdict.box, screenVerdict(&all, "codex", box));
    try testing.expectEqual(ScreenVerdict.no_box, screenVerdict(&all, "codex", none));
    // A CLI that declares nothing: whatever is on the screen, not known.
    try testing.expectEqual(ScreenVerdict.unknown, screenVerdict(&all, "opencode", box));
    try testing.expectEqual(ScreenVerdict.unknown, screenVerdict(&all, "antigravity", none));
    // Not known which CLI: a declared box showing is a box; its absence is
    // not a no.
    try testing.expectEqual(ScreenVerdict.box, screenVerdict(&all, null, box));
    try testing.expectEqual(ScreenVerdict.unknown, screenVerdict(&all, null, none));
}

test "1668: a screen text too short to mean a box, or not text, is not taken" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"screen_says":{"awaiting_approval":{"contains":["","Allow","a\u0007bell text","Do you want to proceed?",7]}}}
    , .{});
    const says = try screenSaysOf(a, "x", parsed.object);
    try testing.expectEqual(@as(usize, 1), says.awaiting_approval.len);
    try testing.expectEqualStrings("Do you want to proceed?", says.awaiting_approval[0]);
}

test "1668: the shipped Codex manifest declares the boxes Codex 0.163 draws" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("plugin_codex_json"), .{});
    const says = try screenSaysOf(a, "codex", parsed.object);
    // Measured on the screen in c1668-01 (issue-fix/1668-B1-evidence).
    try testing.expect(says.awaitsApproval("• Calling polter.me\n  Allow the polter MCP server to run tool \"me\"?\n  › 1. Allow   Run the tool and continue\n"));
    // From codex-rs/tui/src/bottom_pane/approval_overlay.rs, rust-v0.163.0.
    try testing.expect(says.awaitsApproval("  Would you like to run the following command?\n  $ zig build test\n› 1. Yes, proceed\n"));
    try testing.expect(says.awaitsApproval("  Would you like to make the following edits?\n"));
    // Its idle prompt is not a box.
    try testing.expect(!says.awaitsApproval("› Ask Codex to do anything\n  ? for shortcuts\n"));
}

// -- task 2021: a box declined at the terminal -------------------------------
//
// The screens are what 0x373c read off Claude Code 2.1.304 on the mac test
// account on 2026-10-22, five seconds after each answer (the group's seq
// 314): the part after the last prompt, as measured, over the bottom every
// one of them ended on. Read through the shipped plugin.json, so what is
// tested is what is declared.

const claude_bottom =
    \\
    \\
    \\
    \\
    \\
    \\
    \\
    \\
    \\
    \\
    \\
    \\
    \\○ low · /effort
    \\────────────────────────────────────────────────────────────────────────────────
    \\❯ 
    \\────────────────────────────────────────────────────────────────────────────────
    \\  ⏸ manual mode on
;

fn shippedDeclined(arena: Allocator) !DeclinedSays {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const text = std.Io.Dir.cwd().readFileAlloc(threaded.io(), "plugins/claude-code/plugin.json", arena, .limited(1024 * 1024)) catch |err| {
        std.debug.print("cannot read plugins/claude-code/plugin.json ({t}). Run `zig build test` from the repository root.\n", .{err});
        return error.ShippedPluginUnreadable;
    };
    const obj = (try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{})).object;
    const says = try declinedSaysOf(arena, "claude-code", obj);
    try testing.expect(says.declared());
    return says;
}

test "2021: a Bash box declined with Esc, or with No and nothing typed, is read as declined" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const says = try shippedDeclined(arena.allocator());

    const esc =
        \\❯ Use the Bash tool to run exactly this command: ls -la /tmp | head -3
        \\  Thought for 1s, listed 1 directory, ran 1 shell command
        \\  ⎿  Interrupted · What should Claude do instead?
        \\
        \\✻ Worked for 1s · done 6:23
    ++ claude_bottom;
    try testing.expectEqualStrings("Interrupted · What should Claude do instead?", says.declinedSaid(esc).?);

    const no =
        \\❯ Use the Bash tool to run exactly this command: ls -la /var | head -3
        \\  Thought for 1s, listed 1 directory, ran 1 shell command
        \\  ⎿  Interrupted · What should Claude do instead?
        \\
        \\✻ Brewed for 0s · done 6:26
    ++ claude_bottom;
    try testing.expectEqualStrings("Interrupted · What should Claude do instead?", says.declinedSaid(no).?);
}

test "2021: an edit box declined with Esc, or with No and nothing typed, is read as declined" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const says = try shippedDeclined(arena.allocator());

    const esc =
        \\❯ Change the first line of README.md to "# Shop Web (edit test)"
        \\⏺ Update(README.md)
        \\  ⎿  User rejected update to README.md
        \\      1 -# shop-web
        \\      1 +# Shop Web (edit test)
        \\      2
        \\      3  A tiny demo shop.
        \\
        \\✻ Baked for 1s · done 6:28
    ++ claude_bottom;
    try testing.expectEqualStrings("User rejected update to", says.declinedSaid(esc).?);

    // Its prompt scrolled off above a long diff: everything on the screen
    // is after it.
    const no =
        \\⏺ Update(README.md)
        \\  ⎿  User rejected update to README.md
        \\      1 -# shop-web
        \\      1 +# Shop Web (edit test)
        \\      2
        \\      3  A tiny demo shop.
        \\
        \\✻ Crunched for 0s · done 6:29
    ++ claude_bottom;
    try testing.expectEqualStrings("User rejected update to", says.declinedSaid(no).?);
}

test "2021: declined with feedback, or approved, the Bash box is not read as declined" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const says = try shippedDeclined(arena.allocator());

    const feedback =
        \\❯ Use the Bash tool to run exactly this command: ls -la /usr | head -3
        \\  Thought for 1s, listed 1 directory
        \\⏺ OK
        \\✻ Churned for 1s · done 6:27
    ++ claude_bottom;
    try testing.expectEqual(@as(?[]const u8, null), says.declinedSaid(feedback));

    const approved =
        \\❯ Use the Bash tool to run exactly this command: ls -la /tmp | head -3
        \\  Thought for 2s, listed 1 directory, ran 1 shell command
        \\⏺ Ran it. Output:
        \\  lrwxr-xr-x@ 1 root  wheel  11  5月 21 16:57 /tmp -> private/tmp
        \\✻ Worked for 2s · done 6:31
    ++ claude_bottom;
    try testing.expectEqual(@as(?[]const u8, null), says.declinedSaid(approved));
}

test "2021: an edit declined with feedback reads as declined -- its hooks have ended the wait already" {
    // The screen alone cannot tell this one from a plain No: the same
    // line is there. What tells them apart is that its turn went on and
    // `Stop` fired, so the state is no longer a hook's wait and the screen
    // is never read for it (`Bus.wantsDeclined`).
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const says = try shippedDeclined(arena.allocator());
    const feedback =
        \\❯ Change the first line of README.md to "# Shop Web (edit test)"
        \\⏺ Update(README.md)
        \\  ⎿  User rejected update to README.md
        \\      1 -# shop-web
        \\      1 +# Shop Web (edit test)
        \\⏺ OK
        \\✻ Cooked for 1s · done 6:30
    ++ claude_bottom;
    try testing.expectEqualStrings("User rejected update to", says.declinedSaid(feedback).?);
}

test "2021: a box declined turns ago, under this turn's box still open, is not this one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const says = try shippedDeclined(arena.allocator());

    const open =
        \\❯ Use the Bash tool to run exactly this command: ls -la /tmp | head -3
        \\  Thought for 1s, listed 1 directory, ran 1 shell command
        \\  ⎿  Interrupted · What should Claude do instead?
        \\
        \\✻ Worked for 1s · done 6:23
        \\
        \\❯ Use the Bash tool to run exactly this command: ls -la /etc | head -3
        \\
        \\⏺ Bash(ls -la /etc | head -3)
        \\
        \\ Bash command
        \\
        \\   ls -la /etc | head -3
        \\
        \\ Do you want to proceed?
        \\ ❯ 1. Yes
        \\   2. Yes, and don't ask again for ls commands in this project
        \\   3. Yes, and allow reading from etc/ from this project
        \\   4. No
        \\
        \\ Esc to cancel · Tab to amend
    ;
    try testing.expectEqual(@as(?[]const u8, null), says.declinedSaid(open));

    // The same, with the earlier decline and this turn's box in one turn:
    // the box being up is what says it is not over.
    const same_turn =
        \\❯ Edit README.md, then run ls
        \\⏺ Update(README.md)
        \\  ⎿  User rejected update to README.md
        \\⏺ Bash(ls)
        \\ Do you want to proceed?
        \\ ❯ 1. Yes
        \\   2. No
        \\ Esc to cancel · Tab to amend
        \\✻ Worked for 1s · done 6:23
    ;
    try testing.expectEqual(@as(?[]const u8, null), says.declinedSaid(same_turn));

    // Declined, and the turn's end not drawn yet.
    const drawing =
        \\❯ Use the Bash tool to run exactly this command: ls -la /tmp | head -3
        \\  ⎿  Interrupted · What should Claude do instead?
    ++ claude_bottom;
    try testing.expectEqual(@as(?[]const u8, null), says.declinedSaid(drawing));

    // And the earlier turn's decline, under a turn that is over and was not.
    const after =
        \\❯ Use the Bash tool to run exactly this command: ls -la /tmp | head -3
        \\  ⎿  Interrupted · What should Claude do instead?
        \\✻ Worked for 1s · done 6:23
        \\❯ What is in /tmp?
        \\⏺ A symlink to private/tmp.
        \\✻ Worked for 2s · done 6:24
    ++ claude_bottom;
    try testing.expectEqual(@as(?[]const u8, null), says.declinedSaid(after));
}

test "2021: declined_says that leaves a key out is not read at all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const no_box = (try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"declined_says":{"contains":["Interrupted · What should Claude do instead?"],"turn_from":"❯ ","turn_done_starts":"✻ ","turn_done_has":" · done "}}
    , .{})).object;
    try testing.expect(!(try declinedSaysOf(a, "x", no_box)).declared());
    const no_done = (try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"declined_says":{"contains":["Interrupted · What should Claude do instead?"],"turn_from":"❯ ","box":["Esc to cancel"]}}
    , .{})).object;
    try testing.expect(!(try declinedSaysOf(a, "x", no_done)).declared());
}
