//! The request surface Poltergeist exposes to agents, and the permission
//! matrix that governs it.
//!
//! An agent never talks to this directly. It speaks MCP to a sidecar
//! process, which speaks this over a local socket. The split matters for
//! trust: the sidecar's identity comes from `GHOSTTY_SURFACE_ID`, injected
//! by the host into the pty's environment, so an agent cannot claim to be a
//! terminal it is not.
//!
//! This file is pure -- it decides what is permitted, not how to do it. The
//! doing lives in the app, which has the surfaces. Keeping the matrix here
//! means it can be tested exhaustively without a terminal, a socket, or an
//! agent. See `docs/poltergeist/mcp.md`.

const std = @import("std");

const Bus = @import("Bus.zig");
const Chat = @import("Chat.zig");
const Plugin = @import("Plugin.zig");
const Tasks = @import("Tasks.zig");
pub const actions = @import("actions.zig");
pub const keys = @import("keys.zig");
const secret = @import("secret.zig");

const log = std.log.scoped(.poltergeist);

pub const Method = enum {
    /// Which terminal am I, what is my role, and is the user holding me
    /// to my work.
    me,

    /// Every terminal that is open, with its quiescence duration and
    /// duty state. Durations and bookkeeping only -- never screen contents.
    terminal_list,

    /// What has happened that the supervisor has not been shown yet.
    ///
    /// Reading consumes: the same thing is not handed over twice. This is
    /// the supervisor asking of its own accord, so unlike the scheduled
    /// hand-over it is never held back -- choosing to look is not an
    /// interruption. Use it after finishing something, rather than waiting
    /// to be told.
    notices,

    /// Who is in a group, so a reader can see who is there rather than
    /// inferring it from who has spoken.
    group_members,

    /// Say what a group is for. The supervisor's own note, for reading
    /// back hours later when it no longer remembers why it made this one.
    group_set_brief,

    /// Ask for the person to be told something.
    ///
    /// The program never decides that a human is needed -- it cannot read
    /// a screen and would not know an authorisation prompt from a spinner.
    /// You looked; you say so. Whether it actually reaches them depends on
    /// what they have configured and, for scheduling questions, on the
    /// hour.
    notify_user,

    /// What last night's arrangement was, as written down before the
    /// restart.
    ///
    /// Read-only, and nothing acts on it. Which terminal on screen now is
    /// which one from the notes is a judgement, and it is yours -- the
    /// program guessing would attach one terminal's supervision to another
    /// and look fine doing it.
    session_recall,

    /// Read what is on another terminal's screen.
    terminal_read,

    /// Type into another terminal, as if the user had.
    terminal_send,

    /// Mark a terminal as done for the day.
    clock_out,

    /// Put a terminal back on duty.
    clock_in,

    /// Change how long this terminal must be still before the supervisor
    /// hears about it.
    set_quiescence_threshold,

    /// Put a terminal under supervision, or take it out again.
    ///
    /// The supervisor's, because arranging who is minded is the same kind
    /// of decision as arranging who talks to whom. Note what it grants:
    /// a terminal under supervision can be read and typed into, so this is
    /// the tool that decides reach.
    set_watch,

    /// Read one of Poltergeist's skills: the text describing how to do this
    /// job. Any terminal may read one; they are instructions, not reach.
    skill_read,

    /// Make a group, or take one away. The supervisor's alone: it decides
    /// who talks to whom.
    group_create,
    group_destroy,

    /// Put a terminal in a group or take it out, choosing what it sees of
    /// what was said before. The supervisor's alone.
    group_add,
    group_remove,

    /// Replace a stretch of a group's history with a summary. The
    /// supervisor's alone -- it is the one that can judge what a
    /// conversation amounted to.
    group_compact,

    /// Which groups am I in.
    group_list,

    /// Say something to a group, or read what has been said.
    group_post,
    group_read,

    /// Read further back than the group still holds, out of the log on
    /// disk. Page with `log_seq`, which is the log's own number and the
    /// only cursor that survives a restart.
    group_history,

    /// What plugins are installed, whether each is switched on, what it
    /// takes, and -- for a resident one -- how it is getting on.
    ///
    /// Values are never handed back in plain text. A reference is shown as
    /// the user wrote it, because where a secret lives is not the secret;
    /// a literal is not shown at all.
    plugin_list,

    /// Write a plugin's settings for the user.
    ///
    /// What it will not write is the point: no `cmd:` reference, because
    /// that is a command Polter runs later, outside whatever authorises
    /// this call; and no plaintext into a parameter the plugin marks
    /// secret. It also will not switch a plugin off.
    plugin_configure,

    /// Try a notification plugin for real, or say how a resident one is
    /// getting on. Nothing is started for an archive plugin: two copies
    /// would push the same cursor.
    plugin_test,

    /// What the user has configured, or the lines of it for one key.
    ///
    /// Read only. The point is that a supervisor can tell what it is working
    /// under -- the hours it may not disturb anybody, whether it may take
    /// itself off duty -- rather than discovering it by being refused.
    config_get,

    /// Open a terminal in this window, starting in a chosen directory.
    ///
    /// Separate from `terminal_action` and its `new_tab` because a tab
    /// opened that way starts where the terminal that opened it is standing.
    /// Four pieces of work in four directories cannot be set up that way at
    /// all.
    terminal_open,

    /// Do to a terminal what the menu bar does: any of the terminal's own
    /// keybinding actions, by the name the config file uses.
    ///
    /// One tool rather than fifty, because the menu already funnels into one
    /// dispatcher and this is that dispatcher. An agent and a person
    /// therefore take the same code path.
    terminal_action,

    /// Every action `terminal_action` will take, and which of them want a
    /// value. A tool face that cannot be enumerated is one an agent has to
    /// guess at.
    terminal_actions,

    /// Press a key in a terminal: `ctrl+c`, `escape`, `ctrl+shift+k`.
    ///
    /// Separate from `terminal_send` because the two go down different
    /// pipes and must keep doing so. `terminal_send` pastes, and the paste
    /// path replaces every control byte with a space -- that is xterm's
    /// guard against commands hidden inside pasted text, and relaxing it
    /// would put every existing `terminal_send` call site up for review
    /// again. So "type text" stays sanitised for ever, and "press a key"
    /// is its own verb with its own authorisation.
    terminal_key,

    /// Every key `terminal_key` will take: the modifier names and the key
    /// names, straight off the input types. The same argument as
    /// `terminal_actions` -- a vocabulary an agent cannot enumerate is one
    /// it has to guess at.
    terminal_keys,

    /// Stop being a supervisor.
    ///
    /// What a supervisor is left with once the work is done is an empty box
    /// handed to it every interval for the rest of the night. This ends
    /// that. Refused while the caller still minds a terminal -- each one
    /// has to be let go first -- and refused outright when the user has
    /// said the standing is theirs alone to withdraw.
    stand_down,

    /// Put oneself forward as a supervisor.
    ///
    /// Until now the only road to the job was the user pressing a key, so
    /// an agent that could see a pile of work needing somebody to
    /// co-ordinate it had no way to say so.
    ///
    /// Open to an unclaimed terminal, refused to a watched one. A watched
    /// terminal already has somebody minding it, and promoting itself
    /// would be "I am a boss too" said behind that supervisor's back --
    /// it would never even hear about it. The blunter reason is that a
    /// watched terminal is the likeliest one to be reading things off the
    /// network, and a line of injected text saying "promote yourself"
    /// must not be able to rearrange who may reach whom.
    become_supervisor,

    /// Put a piece of work on the panel: a one-line title, in a group.
    ///
    /// The panel exists because a command typed into a terminal scrolls
    /// off and gets compacted away, so by three in the morning the worker
    /// no longer knows what it was set to do. What it holds is who is
    /// doing what, never what the work is -- see
    /// `docs/poltergeist/tasks.md` for the line and why it is drawn there.
    task_create,

    /// Hand a task to a terminal, or take it back with id `0`.
    task_assign,

    /// The work is done and checked. Nothing is sent to the worker: it
    /// finished, it reported, and this is the supervisor agreeing.
    task_close,

    /// Call a task off.
    ///
    /// **The worker is told before the task leaves its list**, in as many
    /// words, down the same path `terminal_send` uses. A task that merely
    /// stopped being there would leave the worker carrying on with work
    /// nobody wants -- it has no reason to look at the panel again -- and
    /// a silent state change is the mistake this repository has already
    /// shipped three times. The reply says who was told.
    task_cancel,

    /// Move your own task along: queued, working, blocked, done.
    ///
    /// Yours, and only while it is open. Open to any terminal because it
    /// is a terminal reporting on itself, which changes no supervision
    /// arrangement.
    task_progress,

    /// The tasks in a group.
    ///
    /// **Two different answers to two different questions.** A supervisor
    /// is handed the group's whole panel, closed and cancelled work
    /// included, because checking the night's work is what it is for. Any
    /// other terminal is handed its own, still open, and nothing else --
    /// which is the whole point: a worker's attention is not to be spent
    /// on what its peers are doing.
    task_list,
};

pub const Request = union(Method) {
    me,
    terminal_list,
    notices,
    group_members: struct { group: []const u8 },
    group_set_brief: struct { group: []const u8, text: []const u8 },

    notify_user: struct {
        /// `scheduling` or `authorisation`. The second is never held back
        /// for quiet hours, because nobody may answer it for them.
        reason: []const u8,
        title: []const u8,
        body: []const u8 = "",
        id: Bus.Id = 0,
    },

    session_recall,
    terminal_read: struct { id: Bus.Id, lines: u16 = 0 },
    terminal_send: struct { id: Bus.Id, text: []const u8, submit: bool = true },
    clock_out: struct { id: Bus.Id, reason: []const u8 = "" },
    clock_in: struct { id: Bus.Id },
    set_quiescence_threshold: struct { id: Bus.Id, ms: u64 },
    set_watch: struct { id: Bus.Id, watch: bool },
    skill_read: struct { name: []const u8 },

    group_create: struct { group: []const u8 },
    group_destroy: struct { group: []const u8 },
    group_add: struct { group: []const u8, id: Bus.Id, history: History = .none },
    group_remove: struct { group: []const u8, id: Bus.Id },
    group_compact: struct { group: []const u8, through: u64, summary: []const u8 },
    group_list,
    group_post: struct { group: []const u8, text: []const u8 },
    group_read: struct { group: []const u8, since: u64 = 0 },
    group_history: struct { group: []const u8, before_seq: u64 = 0, limit: u64 = 0 },

    plugin_list: struct { key: []const u8 = "" },
    plugin_configure: struct {
        key: []const u8,

        // Named for the wire key exactly. The parser derives which
        // parameters a method accepts from these field names, so a field
        // called `enable` reading a key called `enabled` would make every
        // correct request look like it carried an unknown parameter.
        enabled: ?bool = null,
        params: []const Plugin.Param = &.{},
    },
    plugin_test: struct { key: []const u8 },

    config_get: struct { key: []const u8 = "" },
    terminal_open: struct { cwd: []const u8 = "", watch: bool = false },
    terminal_action: struct { id: Bus.Id, action: []const u8 },
    terminal_actions,
    terminal_key: struct { id: Bus.Id, key: []const u8 },
    terminal_keys,

    stand_down,
    become_supervisor,

    task_create: struct { group: []const u8, title: []const u8 },
    task_assign: struct { task: u64, id: Bus.Id },
    task_close: struct { task: u64 },
    task_cancel: struct { task: u64 },
    task_progress: struct { task: u64, progress: []const u8 },
    task_list: struct { group: []const u8 },
};

/// How much text one `group_read` reply may carry.
///
/// The protocol is one JSON object per line, and both readers take a line
/// into a fixed buffer -- so a reply larger than that buffer is not a slow
/// reply, it is `StreamTooLong` and a connection that never recovers,
/// because the next attempt asks for the same range again.
///
/// A group holds up to a thousand messages of up to eight kilobytes each,
/// so an unbounded reply had eight megabytes of headroom over a sixty-four
/// kilobyte buffer. It took a few days of real use to get there.
///
/// The budget is over the *raw* text. JSON escaping inflates it, and worst
/// of all for CJK: `std.json` writes a three-byte character as a six-byte
/// `\uXXXX` escape, so Chinese doubles. The figure below leaves room for
/// that doubling inside the smaller of the two read buffers.
pub const read_budget_bytes: usize = 96 * 1024;

/// Keep the oldest messages that fit the budget.
///
/// Oldest first, not newest: the caller polls with a cursor, so handing
/// back the front of the range lets it advance and ask again. Nothing is
/// lost, it only arrives in instalments. Handing back the newest instead
/// would strand everything before them behind a cursor that had already
/// moved past.
pub fn capMessages(lines: []const ChatLine) struct {
    lines: []const ChatLine,
    more: bool,
} {
    var used: usize = 0;
    for (lines, 0..) |line, i| {
        used += line.text.len + line.author.len;
        if (used > read_budget_bytes) {
            // At least one, however big it is: returning none would have
            // the caller poll forever without its cursor ever moving.
            //
            // **And say that it was cut.** A capped batch is otherwise
            // indistinguishable from the end of the conversation, and a
            // reader stops one screenful in believing it has everything --
            // which is what froze the conversations view for two days.
            return .{ .lines = lines[0..@max(i, 1)], .more = true };
        }
    }
    return .{ .lines = lines, .more = false };
}

/// How many messages one `group_history` reply carries when the caller does
/// not say, and the most it will carry however loudly it asks.
const default_history_limit: usize = 50;
const max_history_limit: usize = 200;

/// Keep the newest messages that fit the budget.
///
/// The mirror of `capMessages`, and the direction is the whole point: a
/// history caller pages *backwards*, so what it carries on from is the
/// oldest line it was handed. Dropping from the old end leaves the range
/// contiguous with what it already holds; dropping from the new end would
/// leave a hole it can never ask for again.
pub fn capHistory(lines: []const ChatLine) struct {
    lines: []const ChatLine,
    more: bool,
} {
    var used: usize = 0;
    var i: usize = lines.len;
    while (i > 0) {
        i -= 1;
        used += lines[i].text.len + lines[i].author.len;
        if (used > read_budget_bytes) {
            // At least one, however big it is, for the same reason
            // `capMessages` keeps one: a reply of nothing tells the caller
            // it has reached the beginning when it has not.
            return .{ .lines = lines[@min(i + 1, lines.len - 1)..], .more = true };
        }
    }
    return .{ .lines = lines, .more = false };
}

pub const History = @import("Chat.zig").History;

pub const Error = error{
    /// The caller's role does not permit this method.
    NotPermitted,

    /// No terminal by that id.
    UnknownTerminal,

    /// The user is holding this terminal to its work, so it may not be
    /// clocked off.
    TerminalHeld,

    /// A watched terminal may not promote itself to supervisor.
    AlreadyWatched,

    /// A terminal aimed a call at itself that would come back to it, or
    /// would take it away before the reply could. Not every self-aimed
    /// call is one of those -- see `selfPermitted`.
    SelfTarget,

    /// Something that belongs to another supervisor: a group it made, or a
    /// terminal it has already claimed the notices of.
    ///
    /// No longer the reach refusal. Reach is `Supervised` now, and the two
    /// were worth splitting: this one is answered by "that is somebody
    /// else's", and that one by "you are not a supervisor".
    NotYours,

    /// The target carries a supervision mark and the caller is not a
    /// supervisor.
    Supervised,

    /// The user has put this terminal out of reach of the tool surface.
    /// Refused to everyone, supervisors and plugins included.
    Shielded,

    /// The caller is a plugin, and this method's meaning depends on which
    /// terminal is asking -- who authored it, who is in the group, whose
    /// box of notices it is, which window a new tab opens in.
    ///
    /// Not a second rulebook for plugins. It is one fact about them said
    /// once: a plugin is not a terminal, so there is no terminal for the
    /// method to be about. See `callableByPlugin`.
    NotATerminal,

    /// The caller is a plugin and its manifest did not declare this method
    /// in `wants.calls`.
    ///
    /// Refused **before** anything else is considered, and it can only ever
    /// narrow: a call has to pass this and the reachability rule both, so
    /// nothing a plugin declares can widen what it may do.
    NotDeclared,
};

/// Whether a plugin may call this method at all.
///
/// **Exhaustive, with no `else`.** A method added later will not compile
/// until somebody has said which side of this line it is on, which is the
/// property the old `Kind` switch did not have: there, a forgotten case was
/// a silent omission, and it happened twice.
///
/// The open set is the one that names no caller: reading and operating a
/// terminal, reading the configuration, reading a skill, listing plugins.
/// A plugin doing those is an ordinary unmarked caller and is judged by
/// exactly the same reachability rule as an agent -- it may touch terminals
/// that carry no mark, and a `shielded` terminal is refused to it the same
/// way it is refused to a supervisor.
///
/// The closed set is closed for one of two reasons, and neither is "plugins
/// are less trusted":
///
///   - **The method is a supervisor's.** A plugin is never a supervisor
///     (`Bus.Caller`), so `requiresSupervisor` already refuses it -- with
///     the same error and the same sentence an ordinary terminal gets, which
///     is the parity being claimed. That covers `notify_user`, `set_watch`,
///     the clock, the group tools and all three plugin tools.
///   - **The method is about who is asking.** `group_post` needs an author
///     and `group_read` needs a member; a plugin is in no group. `me`,
///     `notices`, `stand_down` and `become_supervisor` are about a standing
///     it does not have. `terminal_open` opens a tab in the caller's own
///     window and a plugin has none.
///
/// What is left open is therefore reading and operating a terminal, reading
/// the configuration, and reading a skill -- which is not a small surface:
/// it is everything an unmarked agent may do, judged by the same rule.
///
/// Both of those have a route out that is not a special case: group
/// membership for the first, and the user granting standing in the settings
/// -- the way `held` and `shielded` are set -- for the second. Neither is
/// built here, and saying so plainly beats a plugin author reading this list
/// and guessing why.
pub fn callableByPlugin(method: Method) bool {
    return switch (method) {
        // Seeing what is here, and operating it. Nothing in these depends
        // on which terminal is asking; what may be reached depends on the
        // *target's* mark, and that check is `authorize`'s and is the same
        // one an agent goes through.
        .terminal_list,
        .terminal_read,
        .terminal_send,
        .terminal_action,
        .terminal_actions,
        .terminal_key,
        .terminal_keys,

        // Reading. The configuration and the skills are instructions and
        // settings, not reach.
        .config_get,
        .skill_read,
        => true,

        // About the caller: its identity, its standing, its box, its window.
        .me,
        .notices,
        .stand_down,
        .become_supervisor,
        .session_recall,
        .terminal_open,

        // About a membership a plugin does not have.
        .group_members,
        .group_list,
        .group_post,
        .group_read,
        .group_history,

        // The supervisor's own. `requiresSupervisor` refuses these to a
        // plugin already; they are named here too so this list reads as the
        // whole answer rather than half of one.
        .group_set_brief,
        .group_create,
        .group_destroy,
        .group_add,
        .group_remove,
        .group_compact,
        .notify_user,
        .clock_out,
        .clock_in,
        .set_quiescence_threshold,
        .set_watch,

        // The plugin tools. All three are the supervisor's already, so
        // `requiresSupervisor` is what actually refuses them; they are named
        // here so this list reads as the whole answer rather than half of
        // one, and so that a later decision to open one to terminals does
        // not open it to plugins by omission. A plugin that could rewrite
        // another plugin's settings -- or its own -- would be a way round
        // every check `plugin_configure` makes on behalf of the user.
        .plugin_list,
        .plugin_configure,
        .plugin_test,

        // The panel. Four of these are the supervisor's, so
        // `requiresSupervisor` is what actually refuses them; they are
        // named here for the same reason the plugin tools are, so this
        // list reads as the whole answer.
        //
        // The other two are about who is asking and there is no answer for
        // a plugin: `task_progress` moves *your own* task and a plugin owns
        // none, and `task_list` hands a terminal its own work -- a plugin
        // asking would either get nothing, which is a lie dressed as an
        // answer, or the supervisor's whole panel, which is somebody
        // else's arrangement.
        .task_create,
        .task_assign,
        .task_close,
        .task_cancel,
        .task_progress,
        .task_list,
        => false,
    };
}

/// Whether a method needs the caller to be a supervisor.
///
/// This is about the *method*, not the target -- who may be reached is
/// `authorize`'s reach rule, and the two used to be tangled together.
///
/// The line that is left here is narrow and specific: **a method that
/// changes the supervision arrangement itself is the supervisor's.**
/// `set_watch`, `clock_out`, `clock_in`, `set_quiescence_threshold`, the
/// group tools -- these decide who is minded, who is on duty, and who hears
/// about it. Operating a terminal is not on that list any more: reading a
/// screen, typing into one, pressing a key, doing a menu action are open,
/// and the reach rule alone decides which terminal they may be pointed at.
///
/// The reason for keeping the arrangement tools closed is concrete. If
/// `set_watch` were open, any terminal could claim any other and there
/// would be a second, looser road to standing than `become_supervisor` --
/// which at least refuses a terminal that is already being watched.
pub fn requiresSupervisor(method: Method) bool {
    return switch (method) {
        // Every terminal may ask about itself.
        .me => false,

        // The one method whose whole point is to be reachable by a
        // terminal that is *not* a supervisor. Requiring the standing it
        // is asking for would make it unreachable by everyone who could
        // ever want it. The role is judged in the handler instead, where
        // an unclaimed terminal is let through and a watched one is not.
        .become_supervisor => false,

        // The supervisor's own box of reports. Nothing else fills it and
        // nobody else has one, so there is nothing here for a terminal
        // without the standing to read.
        .notices,

        // The four that change the supervision arrangement rather than
        // operating a terminal. `set_watch` is the load-bearing one: open
        // it and a terminal nobody put in charge of anything could collect
        // other terminals, which is a wider standing than
        // `become_supervisor` grants and with none of its checks.
        .clock_out,
        .clock_in,
        .set_quiescence_threshold,
        .set_watch,

        .group_set_brief,
        .session_recall,
        .notify_user,
        => true,

        // Seeing what is here. Open, because the rule above is about
        // methods that *change* the supervision arrangement and this one
        // changes nothing -- it was left on the closed side by inheritance
        // rather than by that rule, and the two disagreed.
        //
        // Closed, it also made the rest of this pointless: reaching a
        // terminal takes its id, ids come from here, and an agent that
        // cannot list has none. It could operate exactly the terminals it
        // had been told about by other means, which is nothing.
        //
        // What it discloses is the marks, and that is the right direction:
        // an agent can see which terminals are a supervisor's, watched, or
        // shielded, and therefore which it must not touch -- before it
        // tries, rather than by being refused.
        .terminal_list,

        // Operating a terminal. Open, and what decides whether the call
        // goes through is the target's own mark -- see `authorize`. The
        // user's case is an agent in one tab that has to stop and restart
        // a server running in another, watched by nobody, in front of the
        // person rather than hidden in a background process. Requiring the
        // supervisor's standing for that made the standing a formality to
        // be claimed rather than a role.
        .terminal_read,
        .terminal_send,
        .terminal_action,
        .terminal_key,

        // The catalogues that go with them. A tool an agent may call but
        // whose vocabulary it may not list is a tool it has to guess at,
        // and a guess comes back as `UnknownAction`, which reads as a
        // refusal by the terminal rather than as a typo.
        .terminal_actions,
        .terminal_keys,
        => false,

        // Skills are instructions, not reach. A watched terminal reading
        // how supervision works learns nothing it could not be told, and
        // refusing would mean an agent cannot find out why it was nudged.
        .skill_read => false,

        // Who talks to whom is the supervisor's to arrange, the same way
        // who is watched is. A terminal that could make its own groups and
        // pull others into them would be building a structure the user
        // never set up.
        .group_create,
        .group_destroy,
        .group_add,
        .group_remove,
        .group_compact,
        => true,

        // Talking inside a group it was already put in, though, is not
        // steering. The star topology exists so no agent can put text in
        // another's input box uninvited; a message the recipient has to go
        // and fetch is the opposite of that, and a team that cannot talk to
        // each other is not a team.
        .group_list,
        .group_post,
        .group_read,
        .group_history,
        .group_members,
        => false,

        // A new tool lands on the supervisor's side unless there is an
        // argument for it not to, and for these three there is the
        // opposite: setting up a plugin decides what leaves this machine
        // and through what credential, and testing one puts a notification
        // in front of the person. A watched terminal has no business in
        // either.
        .plugin_list,
        .plugin_configure,
        .plugin_test,

        // Only a supervisor has anything to stand down from. `Bus` says so
        // again for itself rather than trusting this to have run.
        .stand_down,

        // Putting another terminal in the window is arranging the work,
        // which is the supervisor's half of the job.
        .terminal_open,

        // The settings it is working under are the supervisor's business;
        // a watched terminal has `me` for the parts that concern it.
        .config_get,

        // Making, handing out, closing and calling off work is arranging
        // the work, which is the same kind of decision as arranging who is
        // minded -- the rule at the top of this function, applied. A
        // terminal that could put tasks on other terminals would be
        // supervising without ever having been made a supervisor, which is
        // the exact hole `set_watch` is closed to prevent.
        //
        // `task_cancel` carries a second reason of its own: it types into
        // another terminal. Whatever else it is, it is reach.
        .task_create,
        .task_assign,
        .task_close,
        .task_cancel,
        => true,

        // Reporting on your own work, and reading what you were given.
        // Neither changes the arrangement: the first moves a task the
        // caller already owns, and the second is answered with the
        // caller's own tasks. Closed, this would leave a worker unable to
        // find out what it was set to do, which is the problem the panel
        // was built for.
        .task_progress,
        .task_list,
        => false,
    };
}

/// Whether a method targets another terminal, and so must be checked
/// against the bus for existence.
pub fn targetsTerminal(method: Method) bool {
    return switch (method) {
        .me,
        .terminal_list,
        .notices,
        .session_recall,
        .notify_user,
        .skill_read,
        .group_create,
        .group_destroy,
        .group_compact,
        .group_list,
        .group_post,
        .group_read,
        .group_history,
        .group_members,
        .group_set_brief,

        // A plugin is a setting of this machine, not of any terminal. The
        // one that names a terminal at all -- `plugin_test`, so the test
        // notification can say who asked -- takes that from the caller,
        // not from a parameter.
        .plugin_list,
        .plugin_configure,
        .plugin_test,

        // Both name the caller, and the caller is not a parameter.
        .stand_down,
        .become_supervisor,

        // Catalogues, not errands.
        .terminal_actions,
        .terminal_keys,

        // It makes a terminal rather than naming one.
        .terminal_open,

        // Names a setting, not a terminal.
        .config_get,

        // These name a task, which is not a terminal. `task_cancel` does
        // reach one -- it types the cancellation into the worker's
        // terminal -- but it does so through the *task*, and the task's
        // owner is not a parameter the caller gets to choose.
        .task_create,
        .task_close,
        .task_cancel,
        .task_progress,
        .task_list,
        => false,

        // Both name another terminal, so both go through the self-target
        // check: a supervisor arranging its own supervision is a knot, not
        // a feature.
        .set_watch,
        => true,

        // Names a terminal, and unlike the one above there is nothing odd
        // about naming your own: a supervisor opening a tab or changing its
        // own font size is an ordinary thing to want.
        .terminal_action,
        .terminal_key,
        => true,

        // These name a terminal to put in or take out of a group. Checked
        // for existence so a typo fails rather than vanishing. `task_assign`
        // is the same shape and wants the same check for a sharper reason:
        // a task handed to a mistyped id is a task nobody is doing and
        // nobody can be told about when it is called off.
        .group_add,
        .group_remove,
        .task_assign,
        .terminal_read,
        .terminal_send,
        .clock_out,
        .clock_in,
        .set_quiescence_threshold,
        => true,
    };
}

/// The target terminal, if this request has one.
pub fn target(req: Request) ?Bus.Id {
    return switch (req) {
        .me,
        .terminal_list,
        .notices,
        .skill_read,
        .group_create,
        .group_destroy,
        .group_compact,
        .group_list,
        .group_post,
        .group_read,
        .group_history,
        .group_members,
        .group_set_brief,
        .session_recall,
        .notify_user,
        .plugin_list,
        .plugin_configure,
        .plugin_test,
        .stand_down,
        .become_supervisor,
        .terminal_actions,
        .terminal_keys,
        .terminal_open,
        .config_get,

        // Named here rather than left to the `inline else` below, because
        // that one reads `v.id` off whatever payload has one and these
        // carry a task number instead. A method that reached the self-target
        // gate by falling through is how `terminal_action` came to be
        // refused without anybody deciding it should be.
        .task_create,
        .task_close,
        .task_cancel,
        .task_progress,
        .task_list,
        => null,

        inline .group_add, .group_remove, .task_assign => |v| v.id,
        inline else => |v| v.id,
    };
}

/// Whether a request that names the caller's own terminal is nonetheless
/// allowed through.
///
/// One method is, and only in part. `terminal_action` is a whole menu
/// behind a single name, and the menu is not of one kind: `new_split`
/// says nothing back to the caller and `close_surface` removes it. Which
/// is which is `actions.selfSafe`, and it is a judgement -- the union
/// carries no bit for it -- so that is where it is written down, once,
/// exhaustively.
///
/// **The `else` here is deny, and that is the difference between this and
/// the fallthrough it is fixing.** `target`'s `inline else => |v| v.id`
/// silently *widened* what reached the self-target gate, which is how
/// `terminal_action` got refused without anybody deciding it should be.
/// A method added later and forgotten here is refused at its own terminal:
/// wrong, but wrong in the direction that costs a turn and nothing else,
/// and the caller is told plainly rather than surprised.
pub fn selfPermitted(req: Request) bool {
    return switch (req) {
        .terminal_action => |v| actions.selfSafe(actions.nameOf(v.action)),
        else => false,
    };
}

/// Decide whether `caller` may make this request.
///
/// Note what is *not* here: there is no way to hold a terminal to its work
/// or to let one go. That is deliberate and is what makes the ban on
/// clocking off a held terminal worth anything -- a supervisor that could
/// lift the hold would simply lift it and then clock off. The hold is the
/// user's, set from the menu, and this surface cannot even read it back:
/// what it sees is `held` on the terminal's entry, which it may act on but
/// not change.
///
/// There is also no tool for answering a permission prompt on another
/// agent's behalf, and there will not be one. See `docs/poltergeist/`.
pub fn authorize(bus: *const Bus, caller: Bus.Caller, req: Request) Error!void {
    const method: Method = req;

    // A plugin's own declaration first, because it is the narrowest gate
    // and the cheapest: a call it never said it makes is refused before
    // anything else is looked at. It cannot conflict with the rules below
    // -- it only ever subtracts, and a call has to pass this *and* them.
    if (caller.pluginKey()) |key| {
        if (!declares(caller, method)) {
            log.debug(
                "plugin {s}: {t} is not in its wants.calls, so it is refused",
                .{ key, method },
            );
            return error.NotDeclared;
        }
    }

    // A plugin is never a supervisor, so this refuses every method that
    // changes the supervision arrangement without a second list saying so.
    //
    // **Asked before the plugin-shaped refusal below**, on purpose: a
    // supervisor's method is refused to a plugin for the same reason and
    // with the same sentence it is refused to an ordinary terminal. That is
    // the parity being claimed -- one rule, one answer -- and an earlier
    // "you are not a terminal" would hide it behind a second explanation.
    const supervisor = if (caller.terminalId()) |id| bus.isSupervisor(id) else false;
    if (requiresSupervisor(method) and !supervisor) {
        return error.NotPermitted;
    }

    // Then the one fact about a plugin that is not a rule about plugins: it
    // is not a terminal, so a method that is about which terminal is asking
    // has nothing to be about.
    if (caller.pluginKey() != null and !callableByPlugin(method)) {
        return error.NotATerminal;
    }

    if (target(req)) |id| {
        // **What this gate refuses is a call that comes back to the
        // caller, or one that takes the caller away mid-call.**
        //
        // The first is the loop: `terminal_send` and `terminal_key` put
        // bytes on your own stdin and `terminal_read` hands them back, so
        // an agent aimed at itself types, reads what it typed, and types
        // again with no natural end. `set_watch` is the same knot in the
        // supervision arrangement rather than in text.
        //
        // The second is not a loop at all. `close_surface` on yourself
        // does happen -- and then the socket the reply was going down is
        // gone, so the caller learns nothing about a call that succeeded.
        //
        // Neither is true of most of `terminal_action`, and that is the
        // correction here. A menu item is a one-off with nothing to say
        // back, and `new_split:right` on your own id is a terminal giving
        // itself a second pane to run a server in -- a thing agents
        // actually want and had no way to get. `terminal_action` was
        // never judged against the rule above: it carries an `id`, and
        // `target` ends in `inline else => |v| v.id`, so it arrived at
        // this gate by falling through rather than by anybody deciding.
        // `selfPermitted` is where the deciding happens, and for actions
        // it is `actions.selfSafe`.
        //
        // A plugin is no terminal, so there is nothing here for it to be:
        // it never matches, and it is judged entirely by the target's mark
        // below.
        if (caller.isTerminal(id) and !selfPermitted(req)) return error.SelfTarget;

        // The shield first, because it is the one answer that does not
        // depend on who is asking. See `Bus.Entry.shielded`: a shield that
        // only held off non-supervisors would be worth nothing, because
        // `become_supervisor` lets any unmarked terminal promote itself in
        // a single call and then walk straight through it.
        // Asked of everyone, and the plugin surface is exactly why it is
        // asked here and not inside some caller-shaped branch: the last
        // time a second way in was opened -- `terminal_action` -- it went
        // in with no check at all and could reach past `set_watch`'s
        // supervisor gate and lift a `held` the user had set. Every door
        // reopens every question.
        if (bus.isShielded(id)) return error.Shielded;

        // **Reach is decided by the target, not by the relationship.**
        //
        // A supervisor may reach any Polter terminal. Anyone else may
        // reach a terminal that carries no mark -- one the bus has never
        // heard of, or one it knows and has filed as `none`.
        //
        // The reasoning is the user's and it is worth writing down,
        // because it inverts what this used to do. An unmarked terminal is
        // one the program knows nothing about: it cannot tell whether an
        // agent is running in there or a person is reading their mail, and
        // it is not going to guess. So it does not take a position. What
        // it *can* see is a mark, and a mark means somebody arranged
        // something -- this terminal is supervising, or somebody is
        // watching it -- and rearranging another party's arrangement is
        // not a stranger's to do.
        //
        // Note what is *not* being expressed: there is no notion of peers
        // here. One watched terminal cannot touch another watched
        // terminal, and the reason is not that they are equals. It is that
        // the other one is marked.
        //
        // And note what this gives up. Two supervisors can now interrupt
        // and restart each other, which the old ownership rule made
        // impossible and which is exactly the case the user wanted: a
        // plugin that only reloads on restart needs somebody able to stop
        // the other terminal and start it again.
        if (!supervisor) {
            switch (bus.roleOf(id)) {
                .supervisor, .watched => return error.Supervised,

                // Unmarked, or unknown to the bus, which `roleOf` reports
                // as the same thing because it is the same thing: no marks.
                .none => {},
            }
        }

        // Deliberately no existence check here any more. It used to refuse
        // an id the bus had never registered, which under the old rule was
        // safe because reach required a relationship the bus recorded.
        // Under this rule an unregistered terminal is the *open* case, so
        // refusing it here would refuse precisely the terminals the rule
        // exists to allow.
        //
        // Whether the id names a terminal at all is the host's question,
        // and the host is the side that knows -- it answers
        // `UnknownTerminal` when it does not. `set_watch` always worked
        // this way and needed a special case to say so; now everything
        // does and the special case is gone.
    }

    // Refuse a clock-out the bus would refuse anyway, so the sidecar gets
    // the real reason instead of a generic failure. The bus is still the
    // authority; this only makes the answer honest earlier.
    //
    // Conditional on the entry existing, which it need not: a clock-out
    // naming a terminal the bus has never seen is answered by the bus
    // itself with `UnknownTerminal`.
    if (req == .clock_out) {
        if (bus.get(req.clock_out.id)) |e| {
            if (e.held) return error.TerminalHeld;
        }
    }
}

/// Whether a plugin caller declared `method` in its manifest.
///
/// A terminal declares nothing and is not asked. **The empty list refuses
/// everything**, which is the direction a missing declaration has to fail
/// in: a manifest with no `calls` is one whose author never thought about
/// this, and the user reading it before installing was told the plugin calls
/// nothing.
fn declares(caller: Bus.Caller, method: Method) bool {
    return switch (caller) {
        .terminal => true,
        .plugin => |p| p.mayCall(@tagName(method)),
    };
}

/// Whether the app has a terminal by this id open.
///
/// Only ever asked about an id the bus does not know, and only where a
/// mistake would be recorded rather than answered -- see `group_add`. A
/// host that cannot say is treated as not saying no: inventing a refusal
/// out of an allocation failure would be worse than letting the call
/// through, because the caller would go and correct an id that was right.
fn isOpenTerminal(alloc: std.mem.Allocator, host: Host, id: Bus.Id) bool {
    const places = host.openTerminals(alloc) catch return true;
    defer alloc.free(places);
    for (places) |place| if (place.id == id) return true;
    return false;
}

/// A stable string for each error, for the sidecar to hand back to the
/// agent. Agents read these, so they say what to do about it.
pub fn errorMessage(err: Error) []const u8 {
    return switch (err) {
        error.NotPermitted => "not permitted: only a supervisor may do this",
        error.UnknownTerminal => "no terminal with that id",
        error.TerminalHeld => "the user is holding this terminal to its work and it cannot clock out; only the user can release it",
        error.AlreadyWatched => "a watched terminal may not promote itself; " ++
            "ask its supervisor, or ask the user",
        error.SelfTarget => "not at your own terminal: reading your own screen, typing " ++
            "into your own input and closing yourself are a loop or a reply you would " ++
            "never receive. terminal_action is the exception -- most actions are fine " ++
            "on your own id, new_split included, and terminal_actions marks the ones " ++
            "that are not with self_safe: false",
        error.NotYours => "that one is another supervisor's: it made the group, or it " ++
            "has already claimed that terminal's notices. Leave it to them, or ask the user",
        error.Supervised => "that terminal is marked -- it is a supervisor, or somebody " ++
            "is watching it -- and only a supervisor may reach a marked terminal. " ++
            "Terminals carrying no mark are open to you. If co-ordinating is your job, " ++
            "call become_supervisor and try again; otherwise ask the user",
        error.Shielded => "the user has put that terminal out of reach of these tools, " ++
            "and nothing here lifts that -- not being a supervisor, not being a plugin, " ++
            "not anything. Ask the person at the keyboard",
        error.NotATerminal => "this is a plugin, and that call is about which terminal is " ++
            "asking -- who wrote the message, who is in the group, whose window a new tab " ++
            "opens in. A plugin is not a terminal, so there is nothing for it to be. What " ++
            "is open to a plugin is reading and operating terminals that carry no mark",
        error.NotDeclared => "this plugin's manifest did not list that call in " ++
            "\"wants\": {\"calls\": [...]}. Add it there and the user will see it before " ++
            "they switch the plugin on; nothing here can grant it at run time",
    };
}

// -- tests ------------------------------------------------------------------

/// A terminal caller, for the tests that were written before there was any
/// other kind. `Bus.Caller` is a union now because a plugin is not a
/// terminal; every one of these calls is about a terminal and says so.
fn term(id: Bus.Id) Bus.Caller {
    return .{ .terminal = id };
}

const testing = std.testing;

const boss: Bus.Id = 0x1111;
const worker: Bus.Id = 0x2222;
const other: Bus.Id = 0x3333;

fn testBus(alloc: std.mem.Allocator) !Bus {
    var b: Bus = .init(alloc, .{});
    errdefer b.deinit();
    try b.addSupervisor(boss);
    try b.watch(worker, boss);
    return b;
}

test "only what changes the arrangement needs the supervisor" {
    // The line this draws moved, and this switch is where it is written
    // down. It used to be "anything that reaches another terminal"; it is
    // now "anything that changes the supervision arrangement". Reading a
    // screen and typing into one crossed over, and which terminal they may
    // be pointed at is `authorize`'s reach rule instead.
    //
    // Exhaustive on purpose: a method added without an opinion does not
    // compile.
    for (std.enums.values(Method)) |m| {
        const open = switch (m) {
            .me,
            .skill_read,

            // Open on purpose, and the only method here that is open
            // *because* of who cannot call it: requiring the supervisor's
            // standing would make it unreachable by every terminal that
            // could ever want it. What a watched terminal may do with it
            // is decided in the handler, not here.
            .become_supervisor,

            .group_list,
            .group_post,
            .group_read,
            .group_history,
            .group_members,

            // Operating a terminal, and the catalogues that go with it.
            // Open since the reach rule moved to the target: which
            // terminal these may be pointed at is decided by what that
            // terminal is marked as, not by the caller's standing.
            .terminal_read,
            .terminal_send,
            .terminal_action,
            .terminal_actions,
            .terminal_key,
            .terminal_keys,

            // Seeing what is here. Reaching a terminal takes its id and
            // ids come from here, so closing this closed everything above
            // it too -- and it changes no arrangement, which is the only
            // thing the closed side is for.
            .terminal_list,

            // Reporting on your own work, and reading what you were
            // given. Neither changes the arrangement.
            .task_progress,
            .task_list,
            => true,

            // Writing what a group is for is arranging, not talking.
            // Reading last night's arrangement, likewise.
            .group_set_brief,
            .session_recall,
            .notify_user,

            .notices,
            .clock_out,
            .clock_in,
            .set_quiescence_threshold,
            .set_watch,
            .group_create,
            .group_destroy,
            .group_add,
            .group_remove,
            .group_compact,

            // Configuring a plugin decides what leaves this machine and
            // under what credential; testing one puts something in front
            // of the person. Neither is a watched terminal's to do.
            .plugin_list,
            .plugin_configure,
            .plugin_test,
            .stand_down,
            .terminal_open,
            .config_get,

            // Making, handing out, closing and calling off work is
            // arranging the work.
            .task_create,
            .task_assign,
            .task_close,
            .task_cancel,
            => false,
        };
        try testing.expectEqual(!open, requiresSupervisor(m));
    }
}

test "a setting can be asked for by name, and a wrong name says so" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fake: FakeHost = .{};

    {
        const res = try dispatch(alloc, &b, fake.host(), term(boss), .{ .config_get = .{
            .key = "poltergeist-watch",
        } });
        try testing.expectEqualStrings("poltergeist-watch = false\n", res.text);
    }

    {
        // No key is everything, which is how an agent finds out what the
        // names are without being told them.
        const res = try dispatch(alloc, &b, fake.host(), term(boss), .{ .config_get = .{} });
        try testing.expect(std.mem.indexOf(u8, res.text, "poltergeist-notify") != null);
    }

    {
        const res = try dispatch(alloc, &b, fake.host(), term(boss), .{ .config_get = .{
            .key = "not-a-setting",
        } });
        try testing.expectEqualStrings("NoSuchKey", res.failed.code);
    }
}

test "a key matches the whole name, not a prefix of it" {
    // `poltergeist-watch` must not answer with `poltergeist-watch-harder`
    // if upstream ever adds one: an agent reading a setting it did not ask
    // for is worse than one told there is no such key.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{ .config = "poltergeist-watch-harder = true\n" };

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{ .config_get = .{
        .key = "poltergeist-watch",
    } });
    try testing.expectEqualStrings("NoSuchKey", res.failed.code);
}

test "opening a terminal names it when it is there, and does not pretend when it is not" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        // The runtime got to it before the call returned.
        var fake: FakeHost = .{ .open_result = 0x3333 };
        const res = try dispatch(alloc, &b, fake.host(), term(boss), .{ .terminal_open = .{
            .cwd = "/tmp/work",
        } });
        try testing.expectEqual(@as(?Bus.Id, 0x3333), res.opened.id);
        try testing.expectEqualStrings("/tmp/work", fake.opened.?.cwd);

        // Opened from the caller's own terminal, which is what puts it in
        // the caller's window.
        try testing.expectEqual(boss, fake.opened.?.by);

        // Not asked for, so not claimed.
        try testing.expect(!res.opened.watching);
        try testing.expect(!b.minds(boss, 0x3333));
    }

    {
        // It has not appeared yet. Null rather than an error: the tab is on
        // its way, and saying it failed would have the caller open a second.
        var fake: FakeHost = .{ .open_result = null };
        const res = try dispatch(alloc, &b, fake.host(), term(boss), .{ .terminal_open = .{} });
        try testing.expect(res.opened.id == null);
        try testing.expect(!res.opened.watching);
    }
}

test "a terminal opened to be minded is claimed on the way" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{ .open_result = 0x4444 };

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{ .terminal_open = .{
        .cwd = "/tmp/work",
        .watch = true,
    } });

    try testing.expect(res.opened.watching);
    try testing.expect(b.minds(boss, 0x4444));
}

test "a directory that is not there stops the terminal being opened" {
    // Refused rather than opened somewhere else in silence: a terminal that
    // quietly started in the wrong place is one the supervisor will hand
    // work to believing it is somewhere it is not.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var missing: FakeHost = .{ .open_error = error.NoSuchDirectory };
    const gone = try dispatch(arena.allocator(), &b, missing.host(), term(boss), .{ .terminal_open = .{
        .cwd = "/no/such/place",
    } });
    try testing.expectEqualStrings("NoSuchDirectory", gone.failed.code);

    var relative: FakeHost = .{ .open_error = error.NotAbsolute };
    const rel = try dispatch(arena.allocator(), &b, relative.host(), term(boss), .{ .terminal_open = .{
        .cwd = "work",
    } });
    try testing.expectEqualStrings("BadParams", rel.failed.code);
}

test "an action goes through to the terminal exactly as it was written" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{ .terminal_action = .{
        .id = worker,
        .action = "goto_split:left",
    } });
    try testing.expectEqual(wire.Response.ok, res);

    // Value and all. Splitting it here and rejoining it in the host would
    // be two chances to get the same string wrong.
    try testing.expectEqualStrings("goto_split:left", fake.acted.?.action);
    try testing.expectEqual(worker, fake.acted.?.id);
}

test "an action nobody has heard of is named as such, not blamed on the terminal" {
    // Two different mistakes wanting two different answers: a name that
    // does not exist is the caller's typo, and a terminal that would not do
    // it is the terminal's business. One message for both sends somebody
    // looking at the wrong thing.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{ .terminal_action = .{
        .id = worker,
        .action = "make_me_a_sandwich",
    } });
    try testing.expectEqualStrings("UnknownAction", res.failed.code);

    // And the host was never troubled with it.
    try testing.expect(fake.acted == null);

    const empty = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{ .terminal_action = .{
        .id = worker,
        .action = "",
    } });
    try testing.expectEqualStrings("BadParams", empty.failed.code);
}

test "Polter's own switches are refused, and never reach the terminal" {
    // The hold's documentation says it is worth nothing if the supervisor
    // can lift it and clock the terminal off a moment later. With the
    // keybinding family open through this tool, that sequence worked --
    // confirmed on a real machine: `clock_out` answered "only the user can
    // release it", `terminal_action` lifted the hold, and the next
    // `clock_out` went through.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    for ([_][]const u8{
        "poltergeist_toggle_held",
        "poltergeist_toggle_shielded",
        "poltergeist_toggle_watch",
        "poltergeist_supervisor",
    }) |name| {
        const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{
            .terminal_action = .{ .id = worker, .action = name },
        });

        // Checked as a tag before the code is read. Reading `.failed` off
        // an `ok` response is a panic, and a panic says how this broke
        // rather than what went wrong -- which, for the test standing
        // guard over a permission rule, is the wrong half.
        if (res != .failed) {
            std.debug.print("{s} was not refused\n", .{name});
            return error.GovernedActionWentThrough;
        }
        try testing.expectEqualStrings("NotPermitted", res.failed.code);

        // Refused here, so the host never sees it. A check that let the
        // call through and undid it afterwards would still have pressed
        // the switch.
        try testing.expect(fake.acted == null);
    }

    // Said as "not this one", not as "no such thing" -- the action is real
    // and a caller told otherwise goes hunting for a typo it did not make.
    try testing.expect(actions.known("poltergeist_toggle_held"));

    // And an ordinary menu item still goes through, so this is a rule
    // about a family rather than a tool that stopped working.
    const ok = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{
        .terminal_action = .{ .id = worker, .action = "new_tab" },
    });
    try testing.expectEqual(wire.Response.ok, ok);
    try testing.expect(fake.acted != null);
}

test "closing a terminal in the arrangement does not stop to ask" {
    // The bug: a supervisor asked to close a worker it was minding, the
    // terminal put up the same confirmation a misclicking user would get,
    // and the supervisor sat there -- it cannot see a dialog and it cannot
    // press one. `worker` is `watched` in `testBus`.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{
        .terminal_action = .{ .id = worker, .action = "close_surface" },
    });
    try testing.expectEqual(wire.Response.ok, res);
    try testing.expect(!fake.acted.?.confirm_close);

    // The other marked kind, and the one easy to leave out because it is
    // rarer: a supervisor is in the arrangement too.
    try b.addSupervisor(other);
    fake.acted = null;
    const sup = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{
        .terminal_action = .{ .id = other, .action = "close_surface" },
    });
    try testing.expectEqual(wire.Response.ok, sup);
    try testing.expect(!fake.acted.?.confirm_close);
}

test "closing an unmarked terminal still asks, and the ask is not reported as done" {
    // **The half of the rule that is easy to write out of existence.** A
    // terminal carrying no mark is one the program knows nothing about --
    // it cannot tell an agent from a person reading their mail -- and the
    // confirmation is the only thing standing between it and a tool call.
    // A fix phrased as "close_surface does not confirm" would pass the
    // test above and delete this.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    // `other` is unmarked: `testBus` never registers it.
    try testing.expectEqual(Bus.Role.none, b.roleOf(other));

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{
        .terminal_action = .{ .id = other, .action = "close_surface" },
    });
    try testing.expectEqual(wire.Response.ok, res);
    try testing.expect(fake.acted.?.confirm_close);

    // And when the host says the dialog actually went up, the answer is
    // not `ok`. This is the second bug: `rt_surface.close` returns as soon
    // as the request is handed over, so before this the agent was told the
    // terminal had closed while it sat there behind a box.
    var asking: FakeHost = .{ .action_error = error.CloseAwaitingConfirm };
    const waiting = try dispatch(arena.allocator(), &b, asking.host(), term(boss), .{
        .terminal_action = .{ .id = other, .action = "close_surface" },
    });
    if (waiting != .failed) return error.AwaitingConfirmReportedAsDone;
    try testing.expectEqualStrings("AwaitingConfirmation", waiting.failed.code);
}

test "closing a tab or a window answers the same way closing a surface does" {
    // The two bugs `close_surface` had, still open on `close_tab` and
    // `close_window` until now: the dialog went up where nobody could press
    // it, and the call answered `{"ok":true}` for a tab that was still
    // there. This is this surface's half of the fix -- the flag is computed
    // and handed over for these two exactly as it is for `close_surface`,
    // and a host saying the dialog went up is not reported as done.
    //
    // The other half is `App.poltergeistPerformAction` and the apprt, and
    // **it has no test host**: nothing below this vtable is exercised by any
    // test in this repository. Gutting that wiring entirely leaves the whole
    // suite green. Do not read this test as covering it.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    for ([_][]const u8{ "close_tab", "close_window", "close_tab:other" }) |action| {
        // Marked: no dialog, because there is nobody at that tab.
        var fake: FakeHost = .{};
        const marked = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{
            .terminal_action = .{ .id = worker, .action = action },
        });
        try testing.expectEqual(wire.Response.ok, marked);
        try testing.expect(!fake.acted.?.confirm_close);

        // Unmarked: the dialog stays, same as a surface.
        var plain: FakeHost = .{};
        const unmarked = try dispatch(arena.allocator(), &b, plain.host(), term(boss), .{
            .terminal_action = .{ .id = other, .action = action },
        });
        try testing.expectEqual(wire.Response.ok, unmarked);
        try testing.expect(plain.acted.?.confirm_close);

        // And the dialog going up is never `ok`. This is the one that
        // matters most: an agent told `ok` walks away from a window that is
        // still open, and everything it does next is built on that.
        var asking: FakeHost = .{ .action_error = error.CloseAwaitingConfirm };
        const waiting = try dispatch(arena.allocator(), &b, asking.host(), term(boss), .{
            .terminal_action = .{ .id = other, .action = action },
        });
        if (waiting != .failed) return error.AwaitingConfirmReportedAsDone;
        try testing.expectEqualStrings("AwaitingConfirmation", waiting.failed.code);
    }
}

test "the confirm answer is about closing and nothing else carries it" {
    // Every other action gets the flag too -- it is one parameter on one
    // vtable entry -- and the value it gets is still the honest one for
    // the target, so a future action that closes something cannot be
    // handed "do not ask" by accident. What this pins is that a mark does
    // not change what a non-closing action does: `new_tab` on a watched
    // terminal is `new_tab`.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{
        .terminal_action = .{ .id = worker, .action = "new_tab" },
    });
    try testing.expectEqual(wire.Response.ok, res);
    try testing.expectEqualStrings("new_tab", fake.acted.?.action);
}

test "a known action with an unusable value is the value's fault" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{ .action_error = error.InvalidAction };

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{ .terminal_action = .{
        .id = worker,
        .action = "goto_split:sideways",
    } });
    try testing.expectEqualStrings("BadParams", res.failed.code);
}

test "the actions can be listed, and the list is the union itself" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .terminal_actions);
    try testing.expectEqual(actions.all.len, res.actions.len);

    // Not a handful somebody typed out. Ninety-two at the time of writing,
    // against a menu bar of about sixty once its section headings are
    // dropped -- the vocabulary is a superset of the menu, which is the
    // whole reason this is one tool and not fifty.
    try testing.expect(res.actions.len > 50);
}

test "a watched terminal still cannot arrange the work" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    // These stayed closed when reading and typing opened up. Opening a tab
    // and reading the settings are the supervisor's half of the job, and
    // `terminal_action` on a *marked* terminal is refused for the other
    // reason -- what the target is.
    for ([_]Request{
        .{ .terminal_open = .{ .cwd = "/tmp" } },
        .{ .config_get = .{} },
    }) |req| {
        const res = try dispatch(arena.allocator(), &b, fake.host(), term(worker), req);
        try testing.expectEqualStrings("NotPermitted", res.failed.code);
    }

    const marked = try dispatch(
        arena.allocator(),
        &b,
        fake.host(),
        term(worker),
        .{ .terminal_action = .{ .id = boss, .action = "new_tab" } },
    );
    try testing.expectEqualStrings("Supervised", marked.failed.code);
    try testing.expect(fake.acted == null);

    // But the catalogue is open, because a tool you may call and whose
    // vocabulary you may not read is one you have to guess at.
    const list = try dispatch(arena.allocator(), &b, fake.host(), term(worker), .terminal_actions);
    try testing.expect(list.actions.len > 50);
}

test "a key goes to the host as written, and a key that is not one never gets there" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fake: FakeHost = .{};

    const ok = try dispatch(alloc, &b, fake.host(), term(boss), .{
        .terminal_key = .{ .id = worker, .key = "ctrl+c" },
    });
    try testing.expect(ok == .ok);
    try testing.expectEqualStrings("ctrl+c", fake.keyed.?.key);
    try testing.expectEqual(worker, fake.keyed.?.id);

    // Checked here so a spelling mistake is answered as one rather than as
    // a refusal by the terminal -- the same argument `terminal_action`
    // makes, and the same reason the host is never reached.
    fake.keyed = null;
    const bad = try dispatch(alloc, &b, fake.host(), term(boss), .{
        .terminal_key = .{ .id = worker, .key = "ctrl+nonsense" },
    });
    try testing.expectEqualStrings("BadKey", bad.failed.code);
    try testing.expect(fake.keyed == null);

    // A plain character is not refused for being dangerous. It is refused
    // because it would do nothing: `terminal_send` is where text goes, and
    // the message says so.
    const plain = try dispatch(alloc, &b, fake.host(), term(boss), .{
        .terminal_key = .{ .id = worker, .key = "a" },
    });
    try testing.expectEqualStrings("BadKey", plain.failed.code);
    try testing.expect(std.mem.indexOf(u8, plain.failed.message, "terminal_send") != null);
    try testing.expect(fake.keyed == null);
}

test "pressing a key is not typing text, and the two do not share a pipe" {
    // The distinction the tool exists for. `terminal_send` goes through
    // the paste path, which replaces 0x03 and ESC with spaces -- xterm's
    // guard against commands hidden inside a paste. Widening it would put
    // every `terminal_send` call site up for review again, so the key
    // press is a second verb with its own authorisation instead.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    _ = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{
        .terminal_key = .{ .id = worker, .key = "ctrl+c" },
    });

    // It went down the key path, not the text one.
    try testing.expect(fake.sent == null);
    try testing.expect(fake.keyed != null);

    // And the stripping table really would have eaten it, which is the
    // premise the whole design rests on rather than something to assume.
    // 0x03 is Ctrl-C; `encode` replaces it with a space, so the terminal
    // on the other end would have seen a space.
    const inputpkg = @import("../input.zig");
    var buf: [3]u8 = .{ 'a', 0x03, 'b' };
    const parts = inputpkg.paste.encode(@as([]u8, &buf), .{ .bracketed = false });
    try testing.expectEqualStrings("a b", parts[1]);
}

test "the key vocabulary can be listed, and comes off the input types" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .terminal_keys);
    try testing.expectEqual(keys.names.len, res.keys.names.len);
    try testing.expectEqual(keys.modifiers.len, res.keys.modifiers.len);
    try testing.expect(res.keys.names.len > 100);

    // Open to a watched terminal too, for the same reason
    // `terminal_actions` is: guessing at a name is how an agent gets a
    // refusal that reads like the terminal said no.
    const also = try dispatch(arena.allocator(), &b, fake.host(), term(worker), .terminal_keys);
    try testing.expect(also.keys.names.len > 100);
}

test "standing down is refused until every terminal has been let go" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fake: FakeHost = .{};

    {
        const res = try dispatch(alloc, &b, fake.host(), term(boss), .stand_down);
        try testing.expectEqualStrings("StillMinding", res.failed.code);
        try testing.expect(b.isSupervisor(boss));

        // The host is not told about a refusal: nothing changed, so there
        // is no tab to redraw and no note to write.
        try testing.expect(fake.stood_down == null);
    }

    b.unwatch(worker);

    {
        const res = try dispatch(alloc, &b, fake.host(), term(boss), .stand_down);
        try testing.expectEqual(wire.Response.ok, res);
        try testing.expect(!b.isSupervisor(boss));
        try testing.expectEqual(@as(?Bus.Id, boss), fake.stood_down);
    }
}

test "a supervisor the user has pinned cannot stand itself down" {
    var b: Bus = .init(testing.allocator, .{ .stand_down_allowed = false });
    defer b.deinit();
    try b.addSupervisor(boss);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .stand_down);

    // A distinct code rather than a plain refusal, for the reason a held
    // terminal's `clock_out` gets one: "not permitted" reads as the caller
    // having got something wrong, and this is the user having spoken.
    try testing.expectEqualStrings("StandingInstruction", res.failed.code);
    try testing.expect(b.isSupervisor(boss));
    try testing.expect(fake.stood_down == null);
}

test "a watched terminal cannot stand down from a standing it never had" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    // Stopped by `authorize`, before the bus is ever asked.
    const res = try dispatch(arena.allocator(), &b, fake.host(), term(worker), .stand_down);
    try testing.expectEqualStrings("NotPermitted", res.failed.code);
    try testing.expect(fake.stood_down == null);
}

test "a watched terminal can talk in a group but cannot arrange one" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    // Talking: allowed.
    const posted = try dispatch(testing.allocator, &b, fake.host(), term(worker), .{
        .group_post = .{ .group = "build", .text = "build is green" },
    });
    try testing.expect(posted == .ok);
    try testing.expectEqualStrings("build is green", fake.posted.?.text);
    try testing.expectEqualStrings("build", fake.posted.?.group);

    // Making a group, or pulling somebody into one: refused.
    for ([_]Request{
        .{ .group_create = .{ .group = "mine" } },
        .{ .group_add = .{ .group = "build", .id = boss } },
        .{ .group_remove = .{ .group = "build", .id = boss } },
        .{ .group_compact = .{ .group = "build", .through = 1, .summary = "x" } },
        .{ .group_destroy = .{ .group = "build" } },
    }) |req| {
        const res = try dispatch(testing.allocator, &b, fake.host(), term(worker), req);
        try testing.expectEqualStrings("NotPermitted", res.failed.code);
    }
}

test "a group with terminals in it is not destroyed, and an empty one is" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    // The refusal. What is being checked is the sentence, because that
    // sentence is the whole of what the person pressing `d` in the chat
    // view sees: the view sends `group_destroy` and prints whatever comes
    // back along the bottom.
    {
        var fake: FakeHost = .{ .group_active = true };
        const res = try dispatch(
            testing.allocator,
            &b,
            fake.host(),
            term(boss),
            .{ .group_destroy = .{ .group = "build" } },
        );
        try testing.expectEqualStrings("GroupActive", res.failed.code);
        try testing.expect(std.mem.indexOf(
            u8,
            res.failed.message,
            "group_remove",
        ) != null);
        try testing.expect(!fake.destroyed);
    }

    // The other half, and the reason this is one test rather than two: a
    // refusal that refused everything would pass the half above on its
    // own. An empty group goes.
    {
        var fake: FakeHost = .{};
        const res = try dispatch(
            testing.allocator,
            &b,
            fake.host(),
            term(boss),
            .{ .group_destroy = .{ .group = "build" } },
        );
        try testing.expect(res == .ok);
        try testing.expect(fake.destroyed);
    }
}

test "the supervisor chooses what a terminal it adds can see" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    _ = try dispatch(testing.allocator, &b, fake.host(), term(boss), .{
        .group_add = .{ .group = "build", .id = worker, .history = .none },
    });
    try testing.expectEqual(History.none, fake.added.?.history);

    _ = try dispatch(testing.allocator, &b, fake.host(), term(boss), .{
        .group_add = .{ .group = "build", .id = worker, .history = .all },
    });
    try testing.expectEqual(History.all, fake.added.?.history);
}

test "adding a terminal that does not exist is refused" {
    // The check moved out of `authorize` when the reach rule changed --
    // an unregistered id is the *open* case there now -- and landed in
    // the handler, where it asks the bus and then the host. It has to
    // survive somewhere: a group is a record, so a mistyped id becomes a
    // member that never speaks and that nothing ever mentions again.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(testing.allocator, &b, fake.host(), term(boss), .{
        .group_add = .{ .group = "build", .id = 0xdead },
    });
    try testing.expectEqualStrings("UnknownTerminal", res.failed.code);

    // But an id the host knows and the bus does not is fine, which is the
    // case that used to be impossible: an ordinary tab nobody watches.
    const places = [_]Place{.{ .id = 0x7777 }};
    var open_host: FakeHost = .{ .open = &places };
    const ok = try dispatch(testing.allocator, &b, open_host.host(), term(boss), .{
        .group_add = .{ .group = "build", .id = 0x7777 },
    });
    try testing.expect(ok == .ok);
}

test "a supervisor can be pulled into another supervisor's group" {
    // Blocked outright until now, and not by anything about groups.
    // `group_add` names a terminal, so it went through the reach check,
    // and `minds(boss, other)` is false for every supervisor -- a
    // supervisor has no minder. Two supervisors therefore had no way to be
    // put in one conversation.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    try b.addSupervisor(other);
    var fake: FakeHost = .{};

    const res = try dispatch(testing.allocator, &b, fake.host(), term(boss), .{
        .group_add = .{ .group = "build", .id = other },
    });
    try testing.expect(res == .ok);
    try testing.expectEqual(other, fake.added.?.id);
}

test "compacting carries the summary the supervisor wrote" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    _ = try dispatch(testing.allocator, &b, fake.host(), term(boss), .{
        .group_compact = .{
            .group = "build",
            .through = 42,
            .summary = "they argued about the build",
        },
    });

    try testing.expectEqual(@as(u64, 42), fake.compacted.?.through);
    try testing.expectEqualStrings("they argued about the build", fake.compacted.?.summary);
    try testing.expectEqual(boss, fake.compacted.?.by);
}

test "what the chat log refuses comes back as something to act on" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{ .refuse = true };

    const res = try dispatch(testing.allocator, &b, fake.host(), term(worker), .{
        .group_post = .{ .group = "nope", .text = "hello" },
    });
    try testing.expectEqualStrings("NoSuchGroup", res.failed.code);
    try testing.expect(res.failed.message.len > 0);
}

test "group_list names the groups a terminal is in" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(testing.allocator, &b, fake.host(), term(worker), .group_list);
    defer {
        for (res.groups) |g| {
            testing.allocator.free(g.name);
            if (g.brief.len > 0) testing.allocator.free(g.brief);
        }
        testing.allocator.free(res.groups);
    }
    try testing.expectEqual(@as(usize, 1), res.groups.len);
    try testing.expectEqualStrings("build", res.groups[0].name);
}

test "group_read asks for the group it was given" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(testing.allocator, &b, fake.host(), term(worker), .{
        .group_read = .{ .group = "research", .since = 7 },
    });
    defer {
        for (res.messages.lines) |m| {
            testing.allocator.free(m.text);
            testing.allocator.free(m.author);
        }
        testing.allocator.free(res.messages.lines);
    }
    try testing.expectEqualStrings("research", fake.read_group.?);
    try testing.expectEqual(@as(u64, 8), res.messages.lines[0].seq);
}

test "a watched terminal cannot touch anything that carries a mark" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try authorize(&b, term(worker), .me);

    // Not a supervisor, so the arrangement tools are closed to it whoever
    // it names. `notices` stands for the group here because it is the
    // supervisor's own box; listing is not one of these and is checked
    // just below.
    try testing.expectError(error.NotPermitted, authorize(&b, term(worker), .notices));
    try testing.expectError(error.NotPermitted, authorize(&b, term(worker), .{
        .clock_out = .{ .id = worker },
    }));

    // But it may see what is here. Ids come from the listing, so a
    // terminal that cannot list cannot reach anything either -- closing
    // this would quietly close everything the reach rule opened.
    try authorize(&b, term(worker), .terminal_list);

    // And the tools that *are* open to it are refused here because of what
    // the target is, not because of what the caller is: `boss` is a
    // supervisor. Note the error -- `Supervised`, which says the target is
    // marked, rather than `NotPermitted`, which would say the method was
    // out of reach.
    try testing.expectError(error.Supervised, authorize(&b, term(worker), .{
        .terminal_read = .{ .id = boss },
    }));
    try testing.expectError(error.Supervised, authorize(&b, term(worker), .{
        .terminal_send = .{ .id = boss, .text = "hello" },
    }));

    // A second watched terminal is refused too, and the reason is worth
    // being exact about: **not** because the two are peers. There is no
    // such notion here. It is because the other one carries a mark.
    try b.watch(other, boss);
    try testing.expectError(error.Supervised, authorize(&b, term(worker), .{
        .terminal_send = .{ .id = other, .text = "hello" },
    }));
}

test "an unmarked terminal is open to a caller that is nobody in particular" {
    // The rule in one test, and the user's sentence for it: a terminal
    // carrying no mark is one the program cannot tell anything about -- it
    // has no way to know whether an agent is in there -- so it does not
    // take a position and lets the call through.
    //
    // The case it exists for: an agent in one tab running `./start.sh` in
    // another, interrupting it and starting it again after a change, where
    // the person can see it happen rather than it going on inside a
    // background process.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    // Registered and unmarked.
    try b.register(other);
    try testing.expectEqual(Bus.Role.none, b.roleOf(other));

    try authorize(&b, term(worker), .{ .terminal_read = .{ .id = other } });
    try authorize(&b, term(worker), .{ .terminal_send = .{ .id = other, .text = "./start.sh" } });
    try authorize(&b, term(worker), .{ .terminal_key = .{ .id = other, .key = "ctrl+c" } });
    try authorize(&b, term(worker), .{ .terminal_action = .{ .id = other, .action = "new_tab" } });

    // And a terminal the bus has never registered at all is the same case,
    // because it is the same fact: no marks. Whether the id names a
    // terminal is the host's question and the host answers it.
    try authorize(&b, term(worker), .{ .terminal_read = .{ .id = 0xdead } });
}

test "a shielded terminal is refused to everyone, supervisors included" {
    // The one absolute in here. It has to be absolute because
    // `become_supervisor` is open to any unmarked terminal: a shield that
    // only stopped non-supervisors would be one call away from being
    // walked around, and a protection with a published bypass is worse
    // than none.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try b.register(other);
    try b.setShielded(other, true, .user);

    // The caller here is a supervisor, which is as much standing as this
    // surface has to offer.
    try testing.expect(b.isSupervisor(boss));
    try testing.expectError(error.Shielded, authorize(&b, term(boss), .{
        .terminal_read = .{ .id = other },
    }));
    try testing.expectError(error.Shielded, authorize(&b, term(boss), .{
        .terminal_send = .{ .id = other, .text = "hello" },
    }));
    try testing.expectError(error.Shielded, authorize(&b, term(boss), .{
        .terminal_key = .{ .id = other, .key = "ctrl+c" },
    }));
    try testing.expectError(error.Shielded, authorize(&b, term(boss), .{
        .terminal_action = .{ .id = other, .action = "new_tab" },
    }));
    try testing.expectError(error.Shielded, authorize(&b, term(boss), .{
        .set_watch = .{ .id = other, .watch = true },
    }));
    try testing.expectError(error.Shielded, authorize(&b, term(boss), .{
        .clock_out = .{ .id = other },
    }));

    // A shielded terminal that is also being watched is still shielded,
    // and the shield is the answer given -- it is the one that cannot be
    // argued with.
    try b.watch(other, boss);
    try testing.expectError(error.Shielded, authorize(&b, term(boss), .{
        .terminal_read = .{ .id = other },
    }));

    // Lifted by the user, and it is open again on the ordinary rule.
    try b.setShielded(other, false, .user);
    try authorize(&b, term(boss), .{ .terminal_read = .{ .id = other } });
}

test "a shield is not something a supervisor can take off" {
    // Stated here as well as in `Bus`, because the two halves have to
    // agree: the surface refuses to reach a shielded terminal, and the bus
    // refuses to unshield one for anybody but the user. Either half alone
    // would be a guarantee with a door in it.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try b.register(other);
    try b.setShielded(other, true, .user);

    try testing.expectError(
        error.NotPermitted,
        b.setShielded(other, false, .supervisor),
    );
    try testing.expect(b.isShielded(other));

    // And there is no method for it either, so there is nothing to route.
    for (std.enums.values(Method)) |m| {
        try testing.expect(std.mem.indexOf(u8, @tagName(m), "shield") == null);
    }
}

test "the supervisor may reach a watched terminal" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try authorize(&b, term(boss), .terminal_list);
    try authorize(&b, term(boss), .{ .terminal_read = .{ .id = worker } });
    try authorize(&b, term(boss), .{ .terminal_send = .{ .id = worker, .text = "继续" } });
    try authorize(&b, term(boss), .{ .clock_out = .{ .id = worker } });
}

test "a terminal cannot aim a call back at itself" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try testing.expectError(error.SelfTarget, authorize(&b, term(boss), .{
        .terminal_send = .{ .id = boss, .text = "loop" },
    }));
    try testing.expectError(error.SelfTarget, authorize(&b, term(boss), .{
        .terminal_read = .{ .id = boss },
    }));
    try testing.expectError(error.SelfTarget, authorize(&b, term(boss), .{
        .terminal_key = .{ .id = boss, .key = "ctrl+c" },
    }));
}

test "a terminal may split itself, but not close itself" {
    // The correction. `terminal_action` used to be refused at the caller's
    // own id along with everything else, not because anybody decided it
    // should be but because `target` hands back its `id` from a
    // fallthrough prong. Splitting your own tab to get a pane to run
    // something in is the case the user asked for and it now goes through.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    for ([_][]const u8{
        "new_split:right",
        "new_split:down",
        "goto_split:left",
        "toggle_split_zoom",
        "resize_split:up,10",
        "equalize_splits",
        "new_tab",
        "set_surface_title:builder",
    }) |name| {
        authorize(&b, term(boss), .{
            .terminal_action = .{ .id = boss, .action = name },
        }) catch |err| {
            std.debug.print("\n{s} should be allowed at one's own id, got {t}\n", .{ name, err });
            return error.TestUnexpectedResult;
        };
    }

    // And the ones that are still refused, for the two separate reasons.
    // These are the negative half: without them the test above would pass
    // just as well against a gate that had been deleted outright.
    for ([_][]const u8{
        // Would come back to the caller.
        "text:hello",
        "csi:5A",
        "esc:a",
        "cursor_key",
        "paste_from_clipboard",
        "paste_from_selection",
        "write_screen_file:paste",
        "write_scrollback_file:paste",
        "write_selection_file:paste",

        // Would take the caller away mid-call.
        "close_surface",
        "close_tab",
        "close_window",
        "close_all_windows",
        "quit",
        "crash",
    }) |name| {
        try testing.expectError(error.SelfTarget, authorize(&b, term(boss), .{
            .terminal_action = .{ .id = boss, .action = name },
        }));

        // The same action at somebody else's terminal is not this
        // gate's business, and never was: a supervisor closing a worker's
        // terminal is an ordinary errand. The refusal is about *whose*.
        try authorize(&b, term(boss), .{
            .terminal_action = .{ .id = worker, .action = name },
        });
    }
}

test "an unmarked terminal may split itself too" {
    // Not a supervisor's privilege. This one carries no mark and nobody
    // is watching it, so it walks the reach rule's open path -- the point
    // being that the self-target gate is what used to stop it, and
    // nothing else does.
    const unmarked: Bus.Id = 0x5151;
    var b: Bus = .init(testing.allocator, .{});
    defer b.deinit();

    try authorize(&b, term(unmarked), .{
        .terminal_action = .{ .id = unmarked, .action = "new_split:right" },
    });
    try testing.expectError(error.SelfTarget, authorize(&b, term(unmarked), .{
        .terminal_action = .{ .id = unmarked, .action = "close_surface" },
    }));
}

test "aiming a governed action at yourself is answered as governed, not as self" {
    // Ordering, and it is the whole reason the family sits on the true
    // side of `selfSafeTag`. `SelfTarget` would send the caller reading
    // about loops; what it needs to hear is which tool carries the rules
    // instead. So `authorize` lets it past and the handler refuses it.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    try authorize(&b, term(boss), .{
        .terminal_action = .{ .id = boss, .action = "poltergeist_toggle_held" },
    });

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{
        .terminal_action = .{ .id = boss, .action = "poltergeist_toggle_held" },
    });
    try testing.expectEqualStrings("NotPermitted", res.failed.code);
}

test "a typo aimed at yourself is a typo, not a self-target" {
    // `selfSafe` answers true for a name that is not an action at all, so
    // the caller is told about its spelling rather than about loops.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    try authorize(&b, term(boss), .{
        .terminal_action = .{ .id = boss, .action = "new_splt:right" },
    });

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{
        .terminal_action = .{ .id = boss, .action = "new_splt:right" },
    });
    try testing.expectEqualStrings("UnknownAction", res.failed.code);
}

test "an unknown target is the host's question, not this one's" {
    // This used to refuse an id the bus had never registered. It cannot
    // any more without contradicting the rule: an unregistered terminal
    // carries no mark, and no mark is precisely the open case. So the
    // check moved to the host, which is the side that knows whether an id
    // is a terminal at all, and answers `UnknownTerminal` when it is not.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try authorize(&b, term(boss), .{ .terminal_read = .{ .id = 0xdead } });

    var fake: FakeHost = .{ .refuse = true };
    const res = try dispatch(testing.allocator, &b, fake.host(), term(boss), .{
        .terminal_read = .{ .id = 0xdead },
    });
    try testing.expectEqualStrings("ReadFailed", res.failed.code);
}

test "with no supervisor named, the arrangement tools are still shut" {
    var b: Bus = .init(testing.allocator, .{});
    defer b.deinit();
    try b.watch(worker, boss);

    try authorize(&b, term(worker), .me);
    try authorize(&b, term(worker), .terminal_list);

    // Nobody holds the standing, so nothing that changes the arrangement
    // is available -- not even to the terminal that would benefit.
    try testing.expectError(error.NotPermitted, authorize(&b, term(worker), .notices));
    try testing.expectError(error.NotPermitted, authorize(&b, term(worker), .{
        .clock_in = .{ .id = worker },
    }));
}

test "clock_out is refused for a held terminal" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try b.setHeld(worker, true, .user);
    try testing.expectError(error.TerminalHeld, authorize(&b, term(boss), .{
        .clock_out = .{ .id = worker },
    }));

    // Clocking a terminal back in is never refused: coming back to work is
    // not the dangerous direction.
    try authorize(&b, term(boss), .{ .clock_in = .{ .id = worker } });
}

test "the hold cannot be reached from this surface at all" {
    // There is deliberately no method for it. The ban on clocking off a
    // held terminal is only worth something if the hold itself cannot be
    // lifted from the same place -- and unlike the work modes this
    // replaced, there is no scheduling story that wants it either: the
    // supervisor decides on every wake-up whether there is more worth
    // doing, which is the judgement a mode switch was standing in for.
    for (std.enums.values(Method)) |m| {
        const name = @tagName(m);
        try testing.expect(std.mem.indexOf(u8, name, "held") == null);
        try testing.expect(std.mem.indexOf(u8, name, "work_mode") == null);
    }

    // And the bus refuses it however the request is routed.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    try testing.expectError(
        error.NotPermitted,
        b.setHeld(worker, true, .supervisor),
    );
}

test "there is no tool for answering another agent's permission prompt" {
    // `terminal_send` is a general text primitive and that is all there is.
    // A dedicated approve/deny tool would make it one step to hand away
    // another agent's safety model, so there is none.
    for (std.enums.values(Method)) |m| {
        const name = @tagName(m);
        try testing.expect(std.mem.indexOf(u8, name, "approve") == null);
        try testing.expect(std.mem.indexOf(u8, name, "confirm") == null);
        try testing.expect(std.mem.indexOf(u8, name, "permission") == null);
    }
}

test "target reports the terminal a request acts on" {
    try testing.expect(target(.me) == null);
    try testing.expect(target(.terminal_list) == null);
    try testing.expectEqual(worker, target(.{ .terminal_read = .{ .id = worker } }).?);
    try testing.expectEqual(worker, target(.{ .clock_out = .{ .id = worker } }).?);
    try testing.expectEqual(
        worker,
        target(.{ .set_quiescence_threshold = .{ .id = worker, .ms = 1000 } }).?,
    );
}

test "targetsTerminal agrees with target" {
    try testing.expect(!targetsTerminal(.me));
    try testing.expect(!targetsTerminal(.terminal_list));
    try testing.expect(targetsTerminal(.terminal_read));
    try testing.expect(targetsTerminal(.set_quiescence_threshold));
    try testing.expect(!targetsTerminal(.group_history));
}

test "every error has a message that says what to do" {
    const errs = [_]Error{
        error.NotPermitted,
        error.UnknownTerminal,
        error.TerminalHeld,
        error.AlreadyWatched,
        error.SelfTarget,
        error.NotYours,
        error.Supervised,
        error.Shielded,
    };
    for (errs) |e| {
        const msg = errorMessage(e);
        try testing.expect(msg.len > 0);
        // Lowercase start, no trailing period: these are appended to the
        // sidecar's own framing rather than read as sentences.
        try testing.expect(msg[0] >= 'a' and msg[0] <= 'z');
        try testing.expect(msg[msg.len - 1] != '.');
    }
}

test "letting a terminal go stops the reports and opens it to everyone" {
    // Twice rewritten, and the history is the point. First it said
    // unwatching stopped the reports but left the supervisor able to read
    // the terminal. Then it said the opposite -- reach followed who was
    // minding what, so letting go was giving up.
    //
    // Now neither. Letting go takes the mark off, and a terminal with no
    // mark is open to anybody, which is exactly what an ordinary shell in
    // an ordinary tab should be. The supervisor keeps its reach because
    // supervisors reach everything; what it loses is the notices.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try authorize(&b, term(boss), .{ .terminal_read = .{ .id = worker } });

    // A terminal that is not a supervisor cannot touch it while it is
    // marked.
    try b.addSupervisor(other);
    b.removeSupervisor(other);
    try testing.expectError(error.Supervised, authorize(&b, term(other), .{
        .terminal_read = .{ .id = worker },
    }));

    b.unwatch(worker);
    try testing.expectEqual(Bus.Role.none, b.roleOf(worker));

    try authorize(&b, term(boss), .{ .terminal_read = .{ .id = worker } });
    try authorize(&b, term(other), .{ .terminal_read = .{ .id = worker } });

    // The arrangement tools are still the supervisor's, though. Seeing
    // what is here is not one of them.
    try authorize(&b, term(worker), .terminal_list);
    try testing.expectError(error.NotPermitted, authorize(&b, term(worker), .notices));
}

test "a supervisor stood down immediately loses its reach into marked terminals" {
    // What standing down costs, now that reach is the target's mark: not
    // the ability to touch anything, but the ability to touch anything
    // that is marked. The terminals it was minding are released along with
    // it, so this has to mark one under somebody else to have a marked
    // terminal left to be refused by.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    try b.addSupervisor(other);

    try authorize(&b, term(boss), .{ .terminal_read = .{ .id = worker } });

    b.removeSupervisor(boss);
    try b.watch(worker, other);

    try testing.expectError(error.Supervised, authorize(&b, term(boss), .{
        .terminal_read = .{ .id = worker },
    }));

    // The arrangement tools go too, and with a different error, because
    // they are refused for a different reason: the method, not the target.
    try testing.expectError(error.NotPermitted, authorize(&b, term(boss), .{
        .clock_out = .{ .id = worker },
    }));
}

test "one supervisor may reach another's terminals, and the other supervisor too" {
    // The exact reversal of what this file used to assert, and it is the
    // change the user asked for. It read: "the property that makes several
    // supervisors safe -- without it, naming a second supervisor would
    // hand it every worker in the window."
    //
    // What that cost was the case for having two supervisors at all. Two
    // agents co-ordinating a build cannot restart each other, and a plugin
    // that only takes effect on restart cannot be reloaded without the
    // person doing it by hand. Ownership stays for notices and for groups;
    // it is no longer a fence.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try b.addSupervisor(other);

    // A supervisor that is not minding `worker` may still reach it.
    try authorize(&b, term(other), .{ .terminal_read = .{ .id = worker } });
    try authorize(&b, term(other), .{ .terminal_send = .{ .id = worker, .text = "hello" } });

    // And the two supervisors may reach each other, which is the scenario
    // in as many words: stop the other one, then start it again.
    try authorize(&b, term(boss), .{ .terminal_key = .{ .id = other, .key = "ctrl+c" } });
    try authorize(&b, term(boss), .{ .terminal_send = .{ .id = other, .text = "./run.sh" } });
    try authorize(&b, term(other), .{ .terminal_key = .{ .id = boss, .key = "ctrl+c" } });

    // The one that is minding it still can, and still gets the notices --
    // which is what `watched_by` is left meaning.
    try authorize(&b, term(boss), .{ .terminal_read = .{ .id = worker } });
    try testing.expect(b.minds(boss, worker));
    try testing.expect(!b.minds(other, worker));
}

test "a supervisor may pull another supervisor into a group" {
    // This was blocked by the reach rule rather than by anything about
    // groups: `group_add` names a terminal, so it went through the same
    // check, and `minds(boss, other)` is false for a supervisor -- a
    // supervisor has no minder. So a supervisor could never be added to
    // anything, and two of them had no way to talk.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    try b.addSupervisor(other);

    try authorize(&b, term(boss), .{ .group_add = .{ .group = "build", .id = other } });

    // Still the supervisor's tool, though: arranging who talks to whom did
    // not become everybody's.
    try testing.expectError(error.NotPermitted, authorize(&b, term(worker), .{
        .group_add = .{ .group = "build", .id = other },
    }));
}

test "a terminal already minded is not quietly taken over" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try b.addSupervisor(other);
    try testing.expectError(error.AlreadyWatched, b.watch(worker, other));

    // Still the first one's.
    try testing.expect(b.minds(boss, worker));
}

// -- dispatch ---------------------------------------------------------------

const wire = @import("wire.zig");

/// Most screen text one reply may carry, comfortably under what the sidecar
/// will read back.
const max_text_bytes = 128 * 1024;

/// One message as it goes out on the wire.
pub const ChatLine = struct {
    seq: u64,

    /// Where this sits in the log on disk, or 0 when it was never written
    /// down. This is the cursor `group_history` pages by; `seq` is the
    /// group's own count and does not survive a restart.
    log_seq: u64 = 0,

    from: Bus.Id,

    /// What the terminal that said this was called at the time, which is
    /// the same string its tab is showing. Carried so that a reader can
    /// tell which window a message came from; an id cannot be matched
    /// against anything on screen.
    author: []const u8,

    /// Unix milliseconds, so this can be shown as a time of day. The log
    /// itself runs on a monotonic clock -- right for measuring stillness,
    /// useless for saying when somebody spoke -- and the host converts.
    at_ms: i64,

    /// True when this stands in for messages the supervisor compacted away.
    summary: bool,

    text: []const u8,
};

/// One plugin as `plugin_list` reports it.
pub const PluginView = struct {
    key: []const u8,
    name: []const u8 = "",

    enabled: bool = false,

    /// Exactly what the manifest declared. Handed over unread so an agent
    /// can tell the user what it is about to switch on.
    ///
    /// **`events` is what `kind` was**, and it is a list rather than one
    /// word because a plugin may subscribe to several -- which under `kind`
    /// took two plugins and a new enum member to express. A reader that
    /// wants "is this a notification channel" asks whether `terminal.quiet`
    /// is in here.
    events: []const []const u8 = &.{},

    /// Which tool methods the manifest says it calls. Enforced, so this is
    /// the whole of what it may ask for, not a hint.
    calls: []const []const u8 = &.{},

    groups: []const []const u8 = &.{},
    network: bool = false,
    exec: []const []const u8 = &.{},

    params: []const PluginParamView = &.{},

    /// Only for a resident plugin that is actually running: `starting`,
    /// `feeding`, `backing_off`, `dormant`, `stopped`. Empty otherwise.
    state: []const u8 = "",
    cursor: u64 = 0,
    failures: u32 = 0,

    /// Why nothing is happening, when nothing is. Empty when it is fine.
    note: []const u8 = "",
};

pub const PluginParamView = struct {
    name: []const u8,
    title: []const u8 = "",
    required: bool = false,
    secret: bool = false,
    choices: []const []const u8 = &.{},

    /// How the value is held: `unset`, `env:`, `file:`, `keychain:`,
    /// `cmd:`, or `literal`. This is what says a value is there at all,
    /// so that saying nothing about the value itself costs no information
    /// anybody needs.
    holds: []const u8 = "unset",

    /// The value, and only when showing it cannot leak anything: a
    /// reference is shown as written, and a literal only when `choices`
    /// pins it to a fixed set. Empty in every other case.
    shown: []const u8 = "",

    /// Set when the file holds a parameter the manifest does not declare.
    /// Shown rather than hidden: an audit has to see everything that is
    /// in the file, including what should not be.
    undeclared: bool = false,
};

/// How one parameter looks in a listing, given what the manifest declares
/// and what the settings file holds.
///
/// Allocation-free: every slice borrows from `spec` or from `value`, both
/// of which the host owns and which outlive the response it is building.
///
/// The host calls this rather than working the rules out again while it
/// fills in a `PluginView`. A redaction rule that lives in two places is
/// one that can be exhaustively tested in the copy that does not ship.
pub fn viewOf(spec: Plugin.ParamSpec, value: []const u8) PluginParamView {
    const held = secret.classify(value);

    return .{
        .name = spec.name,
        .title = spec.title,
        .required = spec.required,
        .secret = spec.secret,
        .choices = spec.choices,

        // `secret.text` rather than a second list of prefix spellings, for
        // the same reason `classify` is the only thing that recognises one.
        .holds = if (value.len == 0)
            "unset"
        else if (held) |p|
            secret.text(p)
        else
            "literal",

        .shown = if (value.len == 0)
            ""
        else if (held != null)
            // Every reference, `cmd:` included: reading back what the user
            // wrote is not the same act as writing a new payload, and a
            // supervisor cannot tell a wrong variable name from a right one
            // without seeing it.
            value
        else if (spec.choices.len > 0 and spec.allows(value))
            // A closed set cannot hold a password -- but only of a value
            // actually in the set. An off-list literal reached the file by
            // hand, which is precisely the case where nobody knows what is
            // in it.
            value
        else
            "",
    };
}

/// How a parameter the manifest does not declare looks in a listing.
///
/// Judged against an empty spec on purpose: nothing may be assumed about a
/// name the manifest has never heard of. `secret` therefore reads false,
/// which cannot loosen anything -- the display rules never consult it.
pub fn undeclaredView(name: []const u8, value: []const u8) PluginParamView {
    var v = viewOf(.{ .name = name }, value);
    v.undeclared = true;
    return v;
}

/// What this surface will and will not write into a plugin's settings.
///
/// Pure, and the sentences are static: an agent reads them, so each one
/// has to say what to do instead, and a test has to be able to compare
/// them.
pub const Guard = struct {
    /// Where a `file:` reference may point: the user's polter config and
    /// state directories, absolute and with `~` already expanded. The host
    /// supplies them because only it knows them. **Empty refuses every
    /// `file:` reference**, which is the safe direction when they could
    /// not be worked out.
    roots: []const []const u8 = &.{},

    pub const max_value_bytes: usize = 4096;
    pub const max_params: usize = 32;

    pub const Verdict = union(enum) {
        allowed,
        refused: []const u8,
    };

    /// Every sentence this surface refuses with, named.
    ///
    /// Named rather than written where they are returned because two things
    /// have to know *which* rule fired: `dispatch`, which appends the list
    /// of takeable values to one of them and to no other, and a test, which
    /// would otherwise be substring-matching a paragraph.
    pub const refusal = struct {
        pub const too_long = "that value is longer than 4096 bytes; " ++
            "a configured value is a reference or a short string, never a document.";

        pub const control = "that value has a control character in it. " ++
            "A configured value is one line of text; write it on one line, " ++
            "or put it in a file and give a file: reference.";

        pub const cmd = "a cmd: reference is a command Polter runs later, " ++
            "on its own, outside whatever authorises you now -- so this surface will not " ++
            "write one. Use env:NAME, keychain:service/account, or file: under the polter " ++
            "config directory to name something the user has already put there. If a cmd: " ++
            "line is really what is wanted, the user writes that one themselves.";

        pub const file_outside = "a file: reference written through this surface has to name a file under the " ++
            "user's polter config or state directory -- that is where a file put there " ++
            "to be a plugin's credential lives. Move it there, or use " ++
            "keychain:service/account instead.";

        /// Separate from `file_outside`, which would be telling somebody to
        /// move a file that is already exactly where it belongs.
        pub const file_tilde = "a file: reference written through this surface has to be an absolute path -- " ++
            "a leading ~ is expanded later, when the plugin is called, and what it expands " ++
            "to then is not something this check can know now. Write the path out in full, " ++
            "under the user's polter config or state directory.";

        pub const plaintext_secret = "this parameter holds a credential and will not be written " ++
            "in plain text. Give a reference instead: env:NAME, keychain:service/account, " ++
            "or file: under the polter config directory. If the user has not put the " ++
            "secret anywhere yet, ask them to -- that is theirs to do, not yours.";

        pub const not_a_choice = "that is not one of the values this parameter takes.";

        pub const switching_off = "switching a plugin off is the user's to do. It is the channel " ++
            "they hear about things on, and an agent quieting it is not a configuration " ++
            "change. Say what you would switch off and why, and leave it to them.";

        /// Shaped like `switching_off` because it is the same act. A plugin
        /// whose required parameter is gone is a plugin that will not run.
        pub const clearing_required = "clearing a parameter the plugin requires is switching it off by " ++
            "another name, and that is the user's to do -- it is the channel they hear " ++
            "about things on. Say what you would clear and why, and leave it to them.";

        /// The third shape of the same act, and the quietest of them.
        ///
        /// `switching_off` and `clearing_required` both refuse making a
        /// channel stop working by taking something away. Pointing a
        /// credential that already works at somewhere else does it by
        /// putting something in: `env:NOT_A_REAL_NAME` is a well-formed
        /// reference, so every rule above it passes, and the failure
        /// arrives hours later as a notification that quietly did not go.
        /// Unattended is exactly when that channel is the only way the
        /// person hears anything, and exactly when nobody is watching the
        /// log line that says it failed to resolve.
        pub const repointing = "this parameter already names where its credential lives, and " ++
            "moving it somewhere else is the user's to do. A reference that resolves to " ++
            "nothing fails at the moment the plugin is called, hours later and out of " ++
            "sight, which is the same as switching the channel off. Say what you would " ++
            "point it at and why, and leave the change to them.";
    };

    /// Whether `value` may be written into `spec`.
    pub fn value(self: Guard, spec: Plugin.ParamSpec, v: []const u8) Verdict {
        // Emptying a parameter the plugin cannot run without reaches the
        // same place as `enabling(false)` by a route that never says so,
        // and the refusal there would mean nothing if this one were open.
        if (v.len == 0 and spec.required) return .{ .refused = refusal.clearing_required };

        // Otherwise empty is how a parameter is unset, so it is not a value
        // being written and none of the rules below are about it.
        if (v.len == 0) return .allowed;

        if (v.len > max_value_bytes) return .{ .refused = refusal.too_long };

        for (v) |c| {
            if (c < 0x20) return .{ .refused = refusal.control };
        }

        // Exhaustive over `secret.Prefix` on purpose. A fifth kind of
        // reference cannot be added over there and quietly treated as an
        // inert literal here: this stops compiling until somebody says
        // what it is.
        if (secret.classify(v)) |p| switch (p) {
            .cmd => return .{ .refused = refusal.cmd },

            .file => {
                const path = secret.body(v, p);

                // `roots` are absolute and containment is decided on the
                // text, so a tilde can never match one -- and a rule that
                // can never say yes has to say why rather than fall through
                // to a sentence about moving the file somewhere it is.
                if (std.mem.startsWith(u8, path, "~")) {
                    return .{ .refused = refusal.file_tilde };
                }
                if (!self.underRoot(path)) return .{ .refused = refusal.file_outside };
            },

            // These two carry data out of somewhere the user has already
            // put it. Neither introduces anything to run.
            .env, .keychain => {},
        };

        // Only a literal can be a plaintext credential; a reference is an
        // address, and an address is not the thing.
        if (spec.secret and secret.classify(v) == null) {
            return .{ .refused = refusal.plaintext_secret };
        }

        // A reference is not checked against the choices: what it resolves
        // to is not known until the plugin is called, and refusing it here
        // would mean guessing.
        if (spec.choices.len > 0 and !spec.allows(v) and secret.classify(v) == null) {
            return .{ .refused = refusal.not_a_choice };
        }

        return .allowed;
    }

    /// Whether the surface may set `enabled` to `to`.
    ///
    /// The asymmetry is the point, and it has a precedent that still
    /// holds: `clockOff` is the supervisor's alone and is refused for a
    /// held terminal, while `clockOn` is open to either of them, because
    /// coming back to work is not the dangerous direction. Both rules
    /// guard the same direction -- the one that ends with somebody hearing
    /// nothing.
    ///
    /// Switching a plugin on introduces no new code -- the script was
    /// already on disk -- and points at the person hearing more. Switching
    /// one off points at them hearing nothing.
    pub fn enabling(to: bool) Verdict {
        if (to) return .allowed;
        return .{ .refused = refusal.switching_off };
    }

    /// Whether a credential that is already pointed somewhere may be
    /// pointed somewhere else through this surface.
    ///
    /// The same asymmetry `enabling` draws, for the same reason. Setting a
    /// credential that is not set yet is help: the channel does not work,
    /// and afterwards it might. Moving one that is already working is not
    /// help in the same sense -- the only thing it can do that the user
    /// would notice is stop the channel -- and this surface cannot tell
    /// the two apart, because whether a reference resolves is not knowable
    /// until the plugin is called and a vault that is locked now may be
    /// open then.
    ///
    /// `holds` comes from the listing rather than from the manifest: it is
    /// the one part of this decision that depends on what is already
    /// written down.
    pub fn repointing(spec: Plugin.ParamSpec, holds: []const u8) Verdict {
        if (!spec.secret) return .allowed;
        if (std.mem.eql(u8, holds, "unset")) return .allowed;
        return .{ .refused = refusal.repointing };
    }

    /// Whether a `file:` path is under one of `roots`.
    ///
    /// Decided on the text, not by asking the filesystem: the file may not
    /// exist yet, and an answer that depends on what happens to be there
    /// is an answer that changes between the check and the write.
    /// A `..` component anywhere refuses, so containment cannot be walked
    /// out of.
    pub fn underRoot(self: Guard, path: []const u8) bool {
        // No roots means they could not be worked out, and a guess at
        // containment is worse than a refusal somebody can read about.
        if (self.roots.len == 0) return false;

        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, "..")) return false;
        }

        for (self.roots) |root| {
            if (root.len == 0) continue;
            const trimmed = if (root[root.len - 1] == '/')
                root[0 .. root.len - 1]
            else
                root;

            if (!std.mem.startsWith(u8, path, trimmed)) continue;

            // A prefix is not containment: `/x/polterhouse` starts with
            // `/x/polter` and is somewhere else entirely.
            const rest = path[trimmed.len..];
            if (rest.len > 1 and rest[0] == '/') return true;
        }
        return false;
    }
};

/// A batch read back out of the log on disk.
pub const ChatPage = struct {
    lines: []const ChatLine,

    /// Whether there is older still to ask for.
    more: bool,
};

/// One member of a group.
pub const ChatMember = struct {
    id: Bus.Id,
    title: []const u8,
};

/// One group as it appears in a listing.
///
/// `brief` is empty for the watched terminals -- not because the text is
/// secret, but because it is a memo, and a note you might have to justify
/// to your peers stops being worth writing. The supervisor wrote it; the
/// person at the keyboard owns the machine. This is the first place a
/// reply depends on who asked; the reasoning is the same as
/// `history: none`, that visibility is reckoned per person rather than
/// per datum.
pub const ChatGroupInfo = struct {
    name: []const u8,
    brief: []const u8,
};

/// One task as it goes out over the wire.
///
/// The state and the progress travel as their names rather than as
/// numbers, so a reply is readable by a person and an agent alike and
/// adding a value later does not renumber the ones already in use.
/// Who has a task and what it is called, for the sentence a cancellation
/// types into that terminal.
///
/// A named type rather than an anonymous one because it crosses a vtable,
/// and two anonymous structs written the same way are two different types.
pub const TaskOwner = struct {
    owner: Bus.Id,
    title: []const u8,
};

pub const TaskView = struct {
    id: u64,
    title: []const u8,
    owner: Bus.Id,
    state: []const u8,
    progress: []const u8,
};

/// What the app must supply for a request to be carried out.
///
/// An interface rather than a direct dependency on `App` so the dispatch
/// rules can be tested against a fake. It is deliberately narrow: reading a
/// screen, typing into one, and two numbers. Anything wider would invite
/// the tool surface to grow capabilities that were never argued for.
/// A terminal and the two things about it that can be put back.
///
/// Where it was working and what its tab said. Deliberately not "what was
/// running in it": that may be an agent whose session can be resumed, or it
/// may be a shell with a half-finished build in it, and only the first of
/// those can be restored by a command. The directory and the name are true
/// of both.
pub const Place = struct {
    id: Bus.Id,
    cwd: []const u8 = "",
    title: []const u8 = "",
};

pub const Host = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The visible screen, or the last `lines` rows when non-zero.
        /// Returned memory belongs to the caller's allocator.
        readTerminal: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            id: Bus.Id,
            lines: u16,
        ) anyerror![]const u8,

        /// Type text into a terminal as if the user had.
        sendText: *const fn (
            ctx: *anyopaque,
            id: Bus.Id,
            text: []const u8,
            submit: bool,
        ) anyerror!void,

        /// The configuration as text, or the lines for one key.
        ///
        /// Text rather than a parsed value: the settings have thirty-odd
        /// types between them and an agent reading `09:00-22:00` needs no
        /// more structure than the config file itself gives it.
        configText: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            key: []const u8,
        ) anyerror![]const u8,

        /// Open a terminal in `by`'s window, starting in `cwd`.
        ///
        /// Answers with the new terminal's id when one has appeared by the
        /// time it returns, and null when the runtime has not got to it yet.
        /// Null is not a failure: the tab is on its way and `terminal_list`
        /// will have it. Blocking here would park this thread on work the
        /// UI thread has to do.
        openTerminal: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            cwd: []const u8,
            by: Bus.Id,
        ) anyerror!?Bus.Id,

        /// Do one of the terminal's own keybinding actions to it.
        ///
        /// `action` is the string the config file uses, value and all --
        /// `new_tab`, `goto_split:left`. Parsing it belongs to the host,
        /// which is the side that has the parser; this surface only checks
        /// that the name is one that exists, so that a typo comes back as a
        /// typo rather than as "the terminal refused".
        ///
        /// `confirm_close` is `actions.confirmsClose` already answered for
        /// this target, and it is a parameter rather than something the
        /// host works out for itself for one reason: it is the answer for
        /// **a close asked for through this surface**, and the host cannot
        /// tell that from a close the user asked for -- the two arrive at
        /// `Surface.performBindingAction` identical, which is the bug this
        /// carries the fix for. Ignored by every action that does not close
        /// a surface.
        ///
        /// Answers `error.CloseAwaitingConfirm` when the close it was asked
        /// for raised the confirmation instead of closing. Not a failure of
        /// the request -- the close was asked for and the dialog is up --
        /// but not a success either, and the caller has to be told which.
        performAction: *const fn (
            ctx: *anyopaque,
            id: Bus.Id,
            action: []const u8,
            confirm_close: bool,
        ) anyerror!void,

        /// Press a key in a terminal, as if the person at the keyboard had.
        ///
        /// `key` is a keybinding trigger written the way the config file
        /// writes one -- `ctrl+c`, `escape`, `ctrl+shift+k`. Parsed on both
        /// sides for different reasons: here, so a spelling mistake is
        /// answered as a spelling mistake rather than as a refusal by the
        /// terminal; and by the host, which is the side holding the
        /// keyboard path.
        sendKey: *const fn (
            ctx: *anyopaque,
            id: Bus.Id,
            key: []const u8,
        ) anyerror!void,

        /// How long that terminal's screen has been unchanged.
        quietMs: *const fn (ctx: *anyopaque, id: Bus.Id) u64,

        /// Start or stop sampling a terminal's screen.
        ///
        /// Separate from the bus entry because they are separate facts: the
        /// entry says a terminal is meant to be watched, and this makes
        /// something actually look at it. Marked without this, a terminal
        /// reports nothing and looks broken rather than unwatched.
        setWatching: *const fn (
            ctx: *anyopaque,
            id: Bus.Id,
            watching: bool,
        ) anyerror!void,

        /// A supervisor has just stopped being one.
        ///
        /// The bus entry is already changed by the time this is called;
        /// what the host does with it is everything outside the bus -- the
        /// tab mark that says who is in charge, and the session notes that
        /// tomorrow will be read back from. Nothing can fail here: the
        /// standing is already gone, and a note that did not save is not a
        /// reason to pretend otherwise.
        stoodDown: *const fn (ctx: *anyopaque, id: Bus.Id) void,

        /// Every terminal the app has open, minded or not.
        ///
        /// The bus only knows terminals somebody put under watch, and
        /// after a restart that is none of them -- which is exactly when
        /// the supervisor needs to see what is on screen in order to match
        /// it against last night's notes. Asking the host instead is the
        /// difference between a restore procedure that can be carried out
        /// and one that can only be written down.
        ///
        /// Where and what it is called, and nothing else: no screen
        /// contents, and no measurement of terminals nobody asked to be
        /// measured. Returned memory belongs to the caller's allocator.
        openTerminals: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
        ) anyerror![]const Place,

        /// Everything the supervisor has not been shown, cleared as it is
        /// read. Empty when there is nothing waiting. Returned memory
        /// belongs to the caller's allocator.
        ///
        /// Goes through the host rather than straight to the bus because
        /// the clock does: the bus is given time, it does not keep it.
        drainNotices: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            to: Bus.Id,
        ) anyerror![]const u8,

        /// Change how long it must be still before it is reported.
        setThreshold: *const fn (
            ctx: *anyopaque,
            id: Bus.Id,
            ms: u64,
        ) anyerror!void,

        /// The prose of one skill. Returned memory belongs to the caller's
        /// allocator.
        readSkill: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            name: []const u8,
        ) anyerror![]const u8,

        chatCreate: *const fn (ctx: *anyopaque, group: []const u8, by: Bus.Id) anyerror!void,
        chatDestroy: *const fn (ctx: *anyopaque, group: []const u8) anyerror!void,

        chatAdd: *const fn (
            ctx: *anyopaque,
            group: []const u8,
            id: Bus.Id,
            history: History,
        ) anyerror!void,

        chatRemove: *const fn (
            ctx: *anyopaque,
            group: []const u8,
            id: Bus.Id,
        ) anyerror!void,

        chatCompact: *const fn (
            ctx: *anyopaque,
            group: []const u8,
            through: u64,
            summary: []const u8,
            by: Bus.Id,
        ) anyerror!void,

        chatPost: *const fn (
            ctx: *anyopaque,
            group: []const u8,
            from: Bus.Id,
            text: []const u8,
        ) anyerror!void,

        /// Groups `id` is in. The slice and the names inside it must belong
        /// to `alloc`.
        /// Who is in a group, with what each one is currently called.
        /// Returned memory belongs to the caller's allocator.
        /// Who made a group, so the tools that rearrange one can refuse a
        /// supervisor that did not.
        chatOwner: *const fn (ctx: *anyopaque, group: []const u8) anyerror!Bus.Id,

        chatMembers: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            group: []const u8,
        ) anyerror![]const ChatMember,

        /// Say what a group is for. Replaces whatever was there.
        chatSetBrief: *const fn (
            ctx: *anyopaque,
            group: []const u8,
            text: []const u8,
        ) anyerror!void,

        /// The groups this terminal is in.
        ///
        /// `want_brief` decides whether each group's note comes along.
        /// Passed down rather than filtered afterwards: a note that was
        /// never fetched cannot be leaked by a later mistake, and there is
        /// nothing to free.
        ///
        /// Returned memory belongs to the caller's allocator.
        /// Tell the person something, through whatever they configured.
        ///
        /// Returns what came of it, as a sentence to hand back -- the
        /// supervisor has to know whether the message actually went
        /// anywhere, because if it did not, waiting for an answer is
        /// waiting for nothing.
        notifyUser: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            reason: []const u8,
            title: []const u8,
            body: []const u8,
            id: Bus.Id,
        ) anyerror![]const u8,

        /// Last night's arrangement, as JSON. Empty when there is none.
        ///
        /// Handed over as text rather than parsed into types: the program
        /// does nothing with it, and every field it would parse is one
        /// more thing to keep in step for no reader's benefit.
        sessionRecall: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
        ) anyerror![]const u8,

        chatGroupInfo: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            id: Bus.Id,
            want_brief: bool,
        ) anyerror![]ChatGroupInfo,

        chatGroups: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            id: Bus.Id,
        ) anyerror![]const []const u8,

        /// Messages `id` has not seen in `group`, above `since`.
        ///
        /// Both the slice and the text inside it must belong to `alloc`.
        /// Borrowing from the log would not survive: the reply is written
        /// by the connection thread after the app thread has moved on, and
        /// the log trims itself as it grows.
        chatRead: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            group: []const u8,
            id: Bus.Id,
            since: u64,
        ) anyerror![]const ChatLine,

        /// Messages older than `before_seq` in `group`, out of the log on
        /// disk.
        ///
        /// The host is the one that knows whether `id` is in the group at
        /// all and how far back its view is allowed to reach; this surface
        /// only asks. Both the slice and the strings inside it must belong
        /// to `alloc`.
        chatHistory: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            group: []const u8,
            id: Bus.Id,
            before_seq: u64,
            limit: usize,
        ) anyerror!ChatPage,

        /// Every plugin installed -- **including the ones switched off**,
        /// because the question this answers is "what is here and is it
        /// on". `key` empty means all of them. Returned memory belongs to
        /// `alloc`.
        pluginList: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            key: []const u8,
        ) anyerror![]const PluginView,

        /// The directories a `file:` reference written through this surface
        /// may point into: the user's polter config and state directories,
        /// absolute and with `~` already expanded.
        ///
        /// Empty when they cannot be worked out, and that refuses every
        /// `file:` reference rather than guessing at containment.
        pluginRoots: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
        ) anyerror![]const []const u8,

        /// Write a plugin's settings file.
        ///
        /// Everything this surface refuses has already been refused; what
        /// is left is the write and saying what it does and does not take
        /// effect on. Returns a sentence for the agent.
        pluginConfigure: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            key: []const u8,
            enable: ?bool,
            params: []const Plugin.Param,
        ) anyerror![]const u8,

        /// Send through one notification plugin for real, or say how a
        /// resident one is getting on. Returns a sentence.
        ///
        /// `by` is here so the test notification's own wording can say
        /// which terminal asked for it -- which is why the host writes that
        /// wording and the tool takes no free text.
        pluginTest: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            key: []const u8,
            by: Bus.Id,
        ) anyerror![]const u8,

        /// Put a task on a group's panel. Answers with its number.
        taskCreate: *const fn (
            ctx: *anyopaque,
            group: []const u8,
            title: []const u8,
        ) anyerror!u64,

        /// Hand a task to a terminal, or take it back with `0`.
        taskAssign: *const fn (
            ctx: *anyopaque,
            task: u64,
            id: Bus.Id,
        ) anyerror!void,

        taskClose: *const fn (ctx: *anyopaque, task: u64) anyerror!void,

        /// Who has a task, and what it is called.
        ///
        /// Asked before a cancellation, because the worker has to be told
        /// and the message has to name the work. Fails with `NoSuchTask`
        /// where there is none. The title belongs to the host.
        taskOwner: *const fn (ctx: *anyopaque, task: u64) anyerror!TaskOwner,

        /// Mark a task cancelled. **The worker has already been told**;
        /// `dispatch` does the telling and only gets here if it worked.
        taskCancel: *const fn (ctx: *anyopaque, task: u64) anyerror!void,

        /// A worker moving its own task along. Refused for anyone else's.
        taskProgress: *const fn (
            ctx: *anyopaque,
            task: u64,
            by: Bus.Id,
            progress: []const u8,
        ) anyerror!void,

        /// The tasks in a group.
        ///
        /// `whole_panel` decides which of the two questions is being
        /// answered -- the group's entire panel, or `who`'s own open work.
        /// Passed down rather than filtered afterwards, the same way
        /// `chatGroupInfo` takes `want_brief`: what was never fetched
        /// cannot be handed over by a later mistake.
        ///
        /// Returned memory belongs to `alloc`.
        taskList: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            group: []const u8,
            who: Bus.Id,
            whole_panel: bool,
        ) anyerror![]const TaskView,
    };

    fn readTerminal(
        self: Host,
        alloc: std.mem.Allocator,
        id: Bus.Id,
        lines: u16,
    ) anyerror![]const u8 {
        return self.vtable.readTerminal(self.ctx, alloc, id, lines);
    }

    fn sendText(self: Host, id: Bus.Id, text: []const u8, submit: bool) anyerror!void {
        return self.vtable.sendText(self.ctx, id, text, submit);
    }

    fn sendKey(self: Host, id: Bus.Id, key: []const u8) anyerror!void {
        return self.vtable.sendKey(self.ctx, id, key);
    }

    fn performAction(
        self: Host,
        id: Bus.Id,
        action: []const u8,
        confirm_close: bool,
    ) anyerror!void {
        return self.vtable.performAction(self.ctx, id, action, confirm_close);
    }

    fn configText(
        self: Host,
        alloc: std.mem.Allocator,
        key: []const u8,
    ) anyerror![]const u8 {
        return self.vtable.configText(self.ctx, alloc, key);
    }

    fn openTerminal(
        self: Host,
        alloc: std.mem.Allocator,
        cwd: []const u8,
        by: Bus.Id,
    ) anyerror!?Bus.Id {
        return self.vtable.openTerminal(self.ctx, alloc, cwd, by);
    }

    fn quietMs(self: Host, id: Bus.Id) u64 {
        return self.vtable.quietMs(self.ctx, id);
    }

    fn openTerminals(self: Host, alloc: std.mem.Allocator) anyerror![]const Place {
        return self.vtable.openTerminals(self.ctx, alloc);
    }

    fn setWatching(self: Host, id: Bus.Id, watching: bool) anyerror!void {
        return self.vtable.setWatching(self.ctx, id, watching);
    }

    fn stoodDown(self: Host, id: Bus.Id) void {
        return self.vtable.stoodDown(self.ctx, id);
    }

    fn drainNotices(self: Host, alloc: std.mem.Allocator, to: Bus.Id) anyerror![]const u8 {
        return self.vtable.drainNotices(self.ctx, alloc, to);
    }

    fn notifyUser(
        self: Host,
        alloc: std.mem.Allocator,
        reason: []const u8,
        title: []const u8,
        body: []const u8,
        id: Bus.Id,
    ) anyerror![]const u8 {
        return self.vtable.notifyUser(self.ctx, alloc, reason, title, body, id);
    }

    fn sessionRecall(self: Host, alloc: std.mem.Allocator) anyerror![]const u8 {
        return self.vtable.sessionRecall(self.ctx, alloc);
    }

    fn chatSetBrief(self: Host, group: []const u8, text: []const u8) anyerror!void {
        return self.vtable.chatSetBrief(self.ctx, group, text);
    }

    fn chatGroupInfo(
        self: Host,
        alloc: std.mem.Allocator,
        id: Bus.Id,
        want_brief: bool,
    ) anyerror![]ChatGroupInfo {
        return self.vtable.chatGroupInfo(self.ctx, alloc, id, want_brief);
    }

    fn chatOwner(self: Host, group: []const u8) anyerror!Bus.Id {
        return self.vtable.chatOwner(self.ctx, group);
    }

    /// Refuse a supervisor rearranging a group that is not its own.
    ///
    /// A group nobody can be found for is left alone rather than refused:
    /// the group tools already answer `NoSuchGroup` where that matters,
    /// and turning a lookup failure into a permission failure would say
    /// the wrong thing.
    fn ownsGroup(self: Host, group: []const u8, caller: Bus.Id) bool {
        const owner = self.chatOwner(group) catch return true;

        // A group with no supervisor behind it is anyone's to take up.
        //
        // That is what a shell restored after a restart is: the record
        // says a group called `build` existed and what it was for, and
        // says nothing about which supervisor made it, because that was a
        // `Surface.id` and those do not survive the process. `Chat`
        // therefore hands it back owned by `user_id`, and the person at
        // the keyboard is never a caller here.
        //
        // Read as an owner rather than as "no owner", this would refuse
        // every supervisor the one operation the restore exists to allow:
        // putting this morning's terminals into last night's group. The
        // first supervisor to take it up would find it locked, and locked
        // to nobody.
        if (owner == Chat.user_id) return true;

        return owner == caller;
    }

    fn chatMembers(
        self: Host,
        alloc: std.mem.Allocator,
        group: []const u8,
    ) anyerror![]const ChatMember {
        return self.vtable.chatMembers(self.ctx, alloc, group);
    }

    fn setThreshold(self: Host, id: Bus.Id, ms: u64) anyerror!void {
        return self.vtable.setThreshold(self.ctx, id, ms);
    }

    fn readSkill(
        self: Host,
        alloc: std.mem.Allocator,
        name: []const u8,
    ) anyerror![]const u8 {
        return self.vtable.readSkill(self.ctx, alloc, name);
    }

    fn chatCreate(self: Host, group: []const u8, by: Bus.Id) anyerror!void {
        return self.vtable.chatCreate(self.ctx, group, by);
    }

    fn chatDestroy(self: Host, group: []const u8) anyerror!void {
        return self.vtable.chatDestroy(self.ctx, group);
    }

    fn chatAdd(
        self: Host,
        group: []const u8,
        id: Bus.Id,
        history: History,
    ) anyerror!void {
        return self.vtable.chatAdd(self.ctx, group, id, history);
    }

    fn chatRemove(self: Host, group: []const u8, id: Bus.Id) anyerror!void {
        return self.vtable.chatRemove(self.ctx, group, id);
    }

    fn chatCompact(
        self: Host,
        group: []const u8,
        through: u64,
        summary: []const u8,
        by: Bus.Id,
    ) anyerror!void {
        return self.vtable.chatCompact(self.ctx, group, through, summary, by);
    }

    fn chatPost(
        self: Host,
        group: []const u8,
        from: Bus.Id,
        text: []const u8,
    ) anyerror!void {
        return self.vtable.chatPost(self.ctx, group, from, text);
    }

    fn chatGroups(
        self: Host,
        alloc: std.mem.Allocator,
        id: Bus.Id,
    ) anyerror![]const []const u8 {
        return self.vtable.chatGroups(self.ctx, alloc, id);
    }

    fn chatRead(
        self: Host,
        alloc: std.mem.Allocator,
        group: []const u8,
        id: Bus.Id,
        since: u64,
    ) anyerror![]const ChatLine {
        return self.vtable.chatRead(self.ctx, alloc, group, id, since);
    }

    fn chatHistory(
        self: Host,
        alloc: std.mem.Allocator,
        group: []const u8,
        id: Bus.Id,
        before_seq: u64,
        limit: usize,
    ) anyerror!ChatPage {
        return self.vtable.chatHistory(self.ctx, alloc, group, id, before_seq, limit);
    }

    fn pluginList(
        self: Host,
        alloc: std.mem.Allocator,
        key: []const u8,
    ) anyerror![]const PluginView {
        return self.vtable.pluginList(self.ctx, alloc, key);
    }

    fn pluginRoots(
        self: Host,
        alloc: std.mem.Allocator,
    ) anyerror![]const []const u8 {
        return self.vtable.pluginRoots(self.ctx, alloc);
    }

    fn pluginConfigure(
        self: Host,
        alloc: std.mem.Allocator,
        key: []const u8,
        enable: ?bool,
        params: []const Plugin.Param,
    ) anyerror![]const u8 {
        return self.vtable.pluginConfigure(self.ctx, alloc, key, enable, params);
    }

    fn pluginTest(
        self: Host,
        alloc: std.mem.Allocator,
        key: []const u8,
        by: Bus.Id,
    ) anyerror![]const u8 {
        return self.vtable.pluginTest(self.ctx, alloc, key, by);
    }

    fn taskCreate(self: Host, group: []const u8, title: []const u8) anyerror!u64 {
        return self.vtable.taskCreate(self.ctx, group, title);
    }

    fn taskAssign(self: Host, task: u64, id: Bus.Id) anyerror!void {
        return self.vtable.taskAssign(self.ctx, task, id);
    }

    fn taskClose(self: Host, task: u64) anyerror!void {
        return self.vtable.taskClose(self.ctx, task);
    }

    fn taskOwner(self: Host, task: u64) anyerror!TaskOwner {
        return self.vtable.taskOwner(self.ctx, task);
    }

    fn taskCancel(self: Host, task: u64) anyerror!void {
        return self.vtable.taskCancel(self.ctx, task);
    }

    fn taskProgress(
        self: Host,
        task: u64,
        by: Bus.Id,
        progress: []const u8,
    ) anyerror!void {
        return self.vtable.taskProgress(self.ctx, task, by, progress);
    }

    fn taskList(
        self: Host,
        alloc: std.mem.Allocator,
        group: []const u8,
        who: Bus.Id,
        whole_panel: bool,
    ) anyerror![]const TaskView {
        return self.vtable.taskList(self.ctx, alloc, group, who, whole_panel);
    }
};

/// Carry out one request on behalf of `caller`.
///
/// Authorization happens first and is never skipped: every path out of this
/// function that touches the host has been through `authorize`.
///
/// Anything the host itself refuses comes back as a failure response rather
/// than an error, because the agent on the other end needs to be told what
/// happened -- a silent failure would have it waiting on something that is
/// never going to occur.
pub fn dispatch(
    alloc: std.mem.Allocator,
    bus: *Bus,
    host: Host,
    who: Bus.Caller,
    req: Request,
) std.mem.Allocator.Error!wire.Response {
    authorize(bus, who, req) catch |err| return failure(err);

    // Everything below this line that names a terminal has already been
    // refused for a plugin: `callableByPlugin` is exhaustive over `Method`
    // and `authorize` turns a false into `NotATerminal` before anything
    // gets here. This is that guarantee written down where it is *used*
    // rather than only where it is decided -- a plugin that somehow reached
    // one of those branches is refused again, and never quietly acts as
    // terminal zero, which is the user.
    const caller: Bus.Id = who.terminalId() orelse Bus.not_a_terminal;

    switch (req) {
        .me => return .{ .me = describe(bus, host, caller) },

        .terminal_list => {
            var list: std.ArrayListUnmanaged(wire.TerminalInfo) = .empty;
            defer list.deinit(alloc);

            // Every terminal on screen, not only the ones the bus knows.
            // After a restart the bus knows none of them, and a list that
            // is empty precisely when the supervisor needs it is not a
            // list. Falling back to the bus keeps the tool working for a
            // host that cannot enumerate.
            if (host.openTerminals(alloc)) |places| {
                // The array is ours to release; the strings inside it are
                // not. They are handed on into the response and outlive
                // this list, so only the slice is freed here.
                defer alloc.free(places);

                for (places) |place| {
                    var info = describe(bus, host, place.id);
                    info.cwd = place.cwd;
                    info.title = place.title;
                    try list.append(alloc, info);
                }
            } else |err| {
                log.warn("poltergeist: could not list terminals err={}", .{err});

                var it = bus.entries.iterator();
                while (it.next()) |kv| {
                    try list.append(alloc, describe(bus, host, kv.key_ptr.*));
                }
            }

            // Sorted so that repeated calls read the same way; a hash map's
            // order is not stable and an agent comparing two listings would
            // see phantom movement.
            const owned = try list.toOwnedSlice(alloc);
            std.mem.sort(wire.TerminalInfo, owned, {}, lessById);
            return .{ .terminals = owned };
        },

        .notices => {
            // Empty is a normal answer, and a common one. It is not an
            // error and it is not silence -- the supervisor asked, and the
            // truthful reply is that nothing is waiting.
            const line = host.drainNotices(alloc, caller) catch
                return hostFailure("ReadFailed", "could not read the notices");
            return .{ .text = line };
        },

        .notify_user => |p| {
            const said = host.notifyUser(alloc, p.reason, p.title, p.body, p.id) catch
                return hostFailure("NotifyFailed", "could not attempt to notify");
            return .{ .text = said };
        },

        .session_recall => {
            const text = host.sessionRecall(alloc) catch
                return hostFailure("ReadFailed", "could not read last night's notes");
            return .{ .text = text };
        },

        .group_set_brief => |p| {
            if (!host.ownsGroup(p.group, caller)) return failure(error.NotYours);
            host.chatSetBrief(p.group, p.text) catch
                return hostFailure("NoSuchGroup", "no group by that name");
            return .ok;
        },

        .group_members => |p| {
            const members = host.chatMembers(alloc, p.group) catch
                return hostFailure("NoSuchGroup", "no group by that name");
            return .{ .members = members };
        },

        .terminal_read => |p| {
            // Accepted in the wire format for forward compatibility, but
            // refused rather than ignored: an agent that asked for
            // scrollback and silently got the visible screen would reason
            // about rows it never saw.
            if (p.lines != 0) return hostFailure(
                "NotImplemented",
                "reading scrollback is not available; omit `lines` for the visible screen",
            );

            const text = host.readTerminal(alloc, p.id, 0) catch
                return hostFailure("ReadFailed", "could not read that terminal");

            // Bounded so one reply cannot exceed what the sidecar will
            // read. A truncated screen with a note beats a desynchronised
            // connection.
            if (text.len > max_text_bytes) {
                defer alloc.free(text);
                return .{ .text = try std.fmt.allocPrint(
                    alloc,
                    "[truncated to the last {d} bytes]\n{s}",
                    .{ max_text_bytes, text[text.len - max_text_bytes ..] },
                ) };
            }

            return .{ .text = text };
        },

        .terminal_send => |p| {
            host.sendText(p.id, p.text, p.submit) catch
                return hostFailure("SendFailed", "could not type into that terminal");
            return .ok;
        },

        .config_get => |p| {
            const text = host.configText(alloc, p.key) catch |err| return switch (err) {
                error.NoSuchKey => hostFailure(
                    "NoSuchKey",
                    try std.fmt.allocPrint(
                        alloc,
                        "there is no setting called {s}. Ask with no key at all to see " ++
                            "every one of them.",
                        .{p.key},
                    ),
                ),
                error.NoConfig => hostFailure(
                    "NoConfig",
                    "the configuration has not been read yet.",
                ),
                else => hostFailure("ConfigFailed", "could not read the configuration"),
            };

            // The whole file is tens of kilobytes and there is no cursor to
            // page it with, so a request for all of it is cut to the same
            // budget a conversation gets rather than filling somebody's
            // context with defaults they did not ask about.
            if (text.len > read_budget_bytes) return .{ .text = text[0..read_budget_bytes] };
            return .{ .text = text };
        },

        .terminal_open => |p| {
            const opened = host.openTerminal(alloc, p.cwd, caller) catch |err| return switch (err) {
                error.NotAbsolute => hostFailure(
                    "BadParams",
                    "a working directory has to be an absolute path.",
                ),
                error.NoSuchDirectory, error.NotADirectory => hostFailure(
                    "NoSuchDirectory",
                    "there is no directory there. A terminal opened into nowhere would " ++
                        "start somewhere else without saying so, which is worse than not " ++
                        "opening it.",
                ),
                else => hostFailure("OpenFailed", "could not open a terminal"),
            };

            // Claimed straight away when asked for, because a supervisor
            // opening a terminal has almost always opened it to mind it, and
            // the alternative is a second call that can fail on its own.
            var watching = false;
            if (opened) |id| {
                if (p.watch) {
                    bus.watch(id, caller) catch {};
                    host.setWatching(id, true) catch {};
                    watching = bus.minds(caller, id);
                }
            }

            return .{ .opened = .{ .id = opened, .watching = watching } };
        },

        .terminal_action => |p| {
            if (p.action.len == 0) return hostFailure(
                "BadParams",
                "an action is needed; terminal_actions lists them.",
            );

            // Checked here so an unknown name is answered as an unknown
            // name. Left to the parser it would come back as a refusal from
            // the terminal, which reads as "it would not do that" rather
            // than "there is no such thing".
            if (!actions.known(actions.nameOf(p.action))) return hostFailure(
                "UnknownAction",
                try std.fmt.allocPrint(
                    alloc,
                    "there is no action called {s}. terminal_actions lists them, " ++
                        "and the names are the ones the config file uses.",
                    .{actions.nameOf(p.action)},
                ),
            );

            // Poltergeist's own switches are the user's, and each has a
            // tool here that carries the rules. Left open, this was a
            // second road to all of them with nothing on it: an agent
            // could lift a hold with `poltergeist_toggle_held` and clock
            // the terminal off a moment later -- the exact sequence the
            // hold's own documentation calls the thing it exists to
            // prevent, and one that was confirmed working on a real
            // machine before this check existed.
            if (actions.governed(actions.nameOf(p.action))) return hostFailure(
                "NotPermitted",
                try std.fmt.allocPrint(
                    alloc,
                    "{s} is one of Polter's own controls, and this surface does " ++
                        "not press it. Watching is set_watch, standing is " ++
                        "become_supervisor, and the hold and the shield are the " ++
                        "user's alone -- ask the person at the keyboard.",
                    .{actions.nameOf(p.action)},
                ),
            );

            // **Who asked, decided here, because here is the only place
            // that knows.** Everything below this line -- the host, the
            // surface, `performBindingAction` -- sees a close and cannot
            // tell it from the user's, by design: `actions.zig` opens by
            // saying an agent and a person take the same code path, and
            // that is right for the other ninety actions. Closing is the
            // one where the two want different answers, so the difference
            // is carried down from the one point that has it rather than
            // rediscovered at the bottom.
            //
            // The target's mark answers it, not the caller's standing --
            // the same judgement the reach rule above makes, and for the
            // same reason. See `actions.confirmsClose`.
            const confirm_close = actions.confirmsClose(.{ .tool = bus.roleOf(p.id) });

            host.performAction(p.id, p.action, confirm_close) catch |err| return switch (err) {
                error.UnknownTerminal => failure(error.UnknownTerminal),

                // The close went in and the user is being asked. Said as a
                // failure because the two answers this surface has are
                // "done" and "not done", and a terminal still sitting
                // there behind a dialog is not done. Answering `ok` here
                // is what the agent was doing before, and it is worse than
                // useless: it goes away satisfied while the thing it asked
                // for waits on a person it cannot reach.
                error.CloseAwaitingConfirm => hostFailure(
                    "AwaitingConfirmation",
                    "the close was asked for, something is still running, and the " ++
                        "user has been asked to confirm -- so nothing has closed yet. " ++
                        "Three ways to get here: the terminal carries no mark, so it " ++
                        "keeps the confirmation an unmarked terminal is entitled to; " ++
                        "or it is in readonly, which is the user locking it on purpose " ++
                        "and is not something a mark waives; or you asked for a tab or " ++
                        "window and one of the other terminals in it is in one of those " ++
                        "two states. Nothing here can press that button. Either wait " ++
                        "and check terminal_list, or ask the person at the keyboard.",
                ),

                // The name exists, so this is the value: `goto_split` with
                // no direction, `increase_font_size:lots`.
                error.InvalidAction => hostFailure(
                    "BadParams",
                    try std.fmt.allocPrint(
                        alloc,
                        "{s} did not parse. Actions take their value after a colon, " ++
                            "written the way the config file writes it.",
                        .{p.action},
                    ),
                ),

                else => hostFailure(
                    "ActionFailed",
                    "the terminal would not do that just now",
                ),
            };
            return .ok;
        },

        .terminal_actions => return .{ .actions = actions.all },

        .terminal_key => |p| {
            // Checked here so that a spelling mistake is answered as one.
            // Same argument as `terminal_action`: left to the host it
            // would come back as "the terminal would not do that", which
            // reads as a refusal rather than as a typo.
            _ = keys.parse(p.key) catch |err| return hostFailure(
                "BadKey",
                keys.refusal(err),
            );

            host.sendKey(p.id, p.key) catch |err| return switch (err) {
                error.UnknownTerminal,
                error.NoSuchTerminal,
                => failure(error.UnknownTerminal),

                // The terminal's child process is gone, so there is
                // nothing on the other end of the keyboard. Said plainly,
                // because "press ctrl+c" on a terminal whose process
                // already exited is a supervisor working from a stale
                // picture, and the fix is to go and read the screen.
                error.ChildExited => hostFailure(
                    "ChildExited",
                    "that terminal's process has already exited, so there is nothing " ++
                        "there to press a key at. Read it to see what happened.",
                ),

                else => hostFailure(
                    "KeyFailed",
                    "the terminal would not take that key just now",
                ),
            };
            return .ok;
        },

        .terminal_keys => return .{ .keys = .{
            .modifiers = keys.modifiers,
            .names = keys.names,
        } },

        .clock_out => |p| {
            bus.clockOff(p.id, .supervisor) catch |err| return switch (err) {
                error.TerminalHeld => failure(error.TerminalHeld),
                error.UnknownTerminal => failure(error.UnknownTerminal),
                error.NotPermitted => failure(error.NotPermitted),
            };
            return .ok;
        },

        .clock_in => |p| {
            bus.clockOn(p.id) catch return failure(error.UnknownTerminal);
            return .ok;
        },

        .set_quiescence_threshold => |p| {
            host.setThreshold(p.id, p.ms) catch
                return hostFailure("ThresholdFailed", "could not change that threshold");
            return .ok;
        },

        .set_watch => |p| {
            // The host goes first, because it is the side that knows
            // whether this id is a terminal at all. Recording the bus entry
            // first would leave a phantom behind when it is not -- one that
            // shows up in `terminal_list` and can never be read.
            host.setWatching(p.id, p.watch) catch
                return failure(error.UnknownTerminal);

            if (p.watch) {
                bus.watch(p.id, caller) catch |err| switch (err) {
                    // Two supervisors typing into one input box is, to the
                    // agent in it, being given orders by two people at
                    // once. Refused rather than silently taken over.
                    error.AlreadyWatched => return failure(error.NotYours),
                    error.OutOfMemory => return hostFailure(
                        "WatchFailed",
                        "could not watch that terminal",
                    ),
                };
            } else {
                // Only the supervisor minding it may let it go.
                if (!bus.minds(caller, p.id)) return failure(error.NotYours);
                bus.unwatch(p.id);
            }

            return .ok;
        },

        .stand_down => {
            bus.standDown(caller) catch |err| switch (err) {
                // Not reachable through `authorize`, which has already
                // asked the same question. Answered anyway, because a rule
                // that only holds while somebody else remembers to check
                // is not a rule the bus is keeping.
                error.NotASupervisor => return hostFailure(
                    "NotASupervisor",
                    "you are not a supervisor, so there is nothing to stand down from.",
                ),

                // Deliberately not `NotPermitted`, for the same reason
                // `StandingInstruction` is not: one reads as the caller
                // having made a mistake, and this is the user having said
                // something that is not the supervisor's to unsay.
                error.NotPermitted => return hostFailure(
                    "StandingInstruction",
                    "the user has said that being a supervisor is theirs to withdraw, " ++
                        "not yours. Say in the group that you have finished and why, and " ++
                        "leave the standing to them.",
                ),

                // The count rather than a bare refusal: what to do next is
                // to go and release them, and how many there are is how
                // much of it is left.
                error.StillMinding => return hostFailure(
                    "StillMinding",
                    try std.fmt.allocPrint(
                        alloc,
                        "you are still minding {d} terminal(s). Standing down releases " ++
                            "nobody -- let each one go with set_watch(id, false) first, so " ++
                            "that each release is a thing you decided, then stand down.",
                        .{bus.mindCount(caller)},
                    ),
                ),
            };

            host.stoodDown(caller);
            return .ok;
        },

        .become_supervisor => return switch (bus.roleOf(caller)) {
            // Already the job. Said plainly rather than refused: an agent
            // told "not permitted" would go looking for what it did wrong.
            .supervisor => wire.Response{ .text = "you are already a supervisor" },

            // The hard one. Its supervisor is not consulted and would
            // never learn of it, and a watched terminal is the likeliest
            // place for a line of injected text to arrive -- so this is
            // refused in code rather than left to anybody's judgement.
            .watched => failure(error.AlreadyWatched),

            .none => blk: {
                bus.addSupervisor(caller) catch break :blk hostFailure(
                    "PromoteFailed",
                    "could not take up the supervisor's standing",
                );
                break :blk wire.Response{ .text = "you are a supervisor now" };
            },
        },

        .skill_read => |p| {
            const body = host.readSkill(alloc, p.name) catch
                return hostFailure("NoSuchSkill", "no skill by that name");
            return .{ .skill = .{ .name = p.name, .body = body } };
        },

        .group_create => |p| {
            host.chatCreate(p.group, caller) catch |err| return chatFailure(err);
            return .ok;
        },

        .group_destroy => |p| {
            if (!host.ownsGroup(p.group, caller)) return failure(error.NotYours);
            host.chatDestroy(p.group) catch |err| return chatFailure(err);
            return .ok;
        },

        .group_add => |p| {
            if (!host.ownsGroup(p.group, caller)) return failure(error.NotYours);

            // A typo here used to be caught by `authorize`, which refused
            // any id the bus had never registered. It cannot any more: the
            // reach rule treats an unregistered terminal as the open case,
            // so refusing one there would refuse exactly what the rule
            // exists to allow.
            //
            // The check has to stay somewhere, though, because group
            // membership is a record that outlives the call: a mistyped id
            // added to a group is a member that never speaks and never
            // leaves, and nothing would ever say so. So it is asked of the
            // two sides that could know -- the bus, and failing that the
            // host's list of open terminals.
            if (bus.get(p.id) == null and !isOpenTerminal(alloc, host, p.id)) {
                return failure(error.UnknownTerminal);
            }

            host.chatAdd(p.group, p.id, p.history) catch |err| return chatFailure(err);
            return .ok;
        },

        .group_remove => |p| {
            if (!host.ownsGroup(p.group, caller)) return failure(error.NotYours);
            host.chatRemove(p.group, p.id) catch |err| return chatFailure(err);
            return .ok;
        },

        .group_compact => |p| {
            host.chatCompact(p.group, p.through, p.summary, caller) catch |err|
                return chatFailure(err);
            return .ok;
        },

        .group_list => {
            // The brief goes to the supervisor, who wrote it, and to the
            // person at the keyboard, whose machine this is -- they face
            // the same question of what a group called "build" was for.
            //
            // Not to the other members. The reason is not secrecy: it is
            // that a note you might have to justify to your peers stops
            // being worth writing, and this one's whole value is that it
            // can be written carelessly.
            const want_brief = bus.isSupervisor(caller) or
                caller == Chat.user_id;

            const groups = host.chatGroupInfo(alloc, caller, want_brief) catch
                return hostFailure("ListFailed", "could not list groups");
            return .{ .groups = groups };
        },

        .group_post => |p| {
            host.chatPost(p.group, caller, p.text) catch |err| return chatFailure(err);
            return .ok;
        },

        .group_read => |p| {
            const lines = host.chatRead(alloc, p.group, caller, p.since) catch |err|
                return chatFailure(err);
            const capped = capMessages(lines);
            return .{ .messages = .{ .lines = capped.lines, .more = capped.more } };
        },

        .group_history => |p| {
            const want: usize = if (p.limit == 0)
                default_history_limit
            else
                @intCast(@min(p.limit, @as(u64, max_history_limit)));

            const page = host.chatHistory(alloc, p.group, caller, p.before_seq, want) catch |err|
                return chatFailure(err);

            // Two ways there can be more: the log said so, or the budget
            // cut the batch short. Either leaves something older that the
            // caller has not been handed.
            const capped = capHistory(page.lines);
            return .{ .messages = .{ .lines = capped.lines, .more = page.more or capped.more } };
        },

        .task_create => |p| {
            // The group's, so a supervisor cannot put work on a panel it
            // does not own -- the same rule the rest of the group tools
            // keep, for the same reason: two supervisors in one window
            // must not be able to rearrange each other's arrangements.
            if (!host.ownsGroup(p.group, caller)) return failure(error.NotYours);

            const id = host.taskCreate(p.group, p.title) catch |err| return taskFailure(err);
            return .{ .task = id };
        },

        .task_assign => |p| {
            // The same existence check `group_add` makes, and for a
            // sharper reason: a task on a mistyped id is a task nobody is
            // doing, and when it is called off there is nobody to tell.
            if (p.id != 0 and bus.get(p.id) == null and !isOpenTerminal(alloc, host, p.id)) {
                return failure(error.UnknownTerminal);
            }

            host.taskAssign(p.task, p.id) catch |err| return taskFailure(err);
            return .ok;
        },

        .task_close => |p| {
            host.taskClose(p.task) catch |err| return taskFailure(err);
            return .ok;
        },

        .task_cancel => |p| {
            // **Say it, then remove it, and this order is the whole of
            // the tool.** A worker whose task simply stopped being on the
            // panel has no reason to look at the panel again: it carries
            // on with work nobody wants. That is a silent state change,
            // and this repository has already shipped three.
            //
            // The order lives here rather than in the host on purpose.
            // The host is the app, which has no tests of its own; this
            // file is pure and its rules are checked exhaustively, so
            // putting the sequence here is what makes "told first" a thing
            // a test can hold onto rather than a comment somebody keeps.
            const what = host.taskOwner(p.task) catch |err| return taskFailure(err);

            var told: []const u8 = " Nobody was on it, so there was nobody to tell.";
            if (what.owner != 0) {
                const line = try std.fmt.allocPrint(
                    alloc,
                    "[polter] Task {d} (\"{s}\") has been cancelled. Stop working on it.",
                    .{ p.task, what.title },
                );

                // **Nothing is cancelled if this fails.** Answering `ok`
                // for a message nobody heard would have the supervisor
                // stop thinking about work that is still being done, which
                // is worse than refusing.
                host.sendText(what.owner, line, true) catch |err|
                    return taskFailure(err);

                told = " The terminal working on it was told to stop.";
            }

            // Only now.
            host.taskCancel(p.task) catch |err| return taskFailure(err);

            // A sentence, not `ok`: the supervisor has to know whether
            // anybody was actually told.
            return .{ .text = try std.fmt.allocPrint(
                alloc,
                "Task {d} cancelled.{s}",
                .{ p.task, told },
            ) };
        },

        .task_progress => |p| {
            host.taskProgress(p.task, caller, p.progress) catch |err|
                return taskFailure(err);
            return .ok;
        },

        .task_list => |p| {
            // **The two filters, chosen here and nowhere else.** A
            // supervisor is asking what the night's work looks like; a
            // worker is asking what it is meant to be doing. The person at
            // the keyboard reads the panel through the conversations view,
            // which comes through this same call as the user -- id zero,
            // never a supervisor on the bus -- so they are named here too.
            const whole_panel = bus.isSupervisor(caller) or caller == Chat.user_id;

            const list = host.taskList(alloc, p.group, caller, whole_panel) catch |err|
                return taskFailure(err);
            return .{ .tasks = list };
        },

        .plugin_list => |p| {
            const list = host.pluginList(alloc, p.key) catch |err| return switch (err) {
                // An unknown key is not an empty listing. `[]` reads as
                // "you have no plugins installed", which is a different
                // thing to tell somebody and a much more alarming one.
                error.NoSuchPlugin => hostFailure(
                    "UnknownPlugin",
                    try unknownPluginMessage(alloc, p.key),
                ),
                error.NotImplemented => hostFailure("NotImplemented", not_wired_up),
                else => hostFailure("HostRefused", "could not read the plugin list"),
            };
            return .{ .plugins = list };
        },

        .plugin_configure => |p| {
            // Order is what makes this whole-or-nothing: every check below
            // returns before the host is touched, so a request refused
            // anywhere leaves nothing half written. Nothing in the types
            // enforces that; only this sequence does.
            if (p.key.len == 0) return hostFailure(
                "UnknownPlugin",
                "a plugin key is needed; plugin_list shows what is installed.",
            );

            const list = host.pluginList(alloc, p.key) catch |err| return switch (err) {
                error.NoSuchPlugin => hostFailure(
                    "UnknownPlugin",
                    try unknownPluginMessage(alloc, p.key),
                ),
                error.NotImplemented => hostFailure("NotImplemented", not_wired_up),
                else => hostFailure("HostRefused", "could not read the plugin list"),
            };

            // By key rather than by taking the first: an empty key means
            // *all of them* to `pluginList`, and `[0]` would quietly
            // configure whichever plugin happened to come back.
            const view = for (list) |v| {
                if (std.mem.eql(u8, v.key, p.key)) break v;
            } else return hostFailure(
                "UnknownPlugin",
                try unknownPluginMessage(alloc, p.key),
            );

            if (p.enabled == null and p.params.len == 0) return hostFailure(
                "NothingToDo",
                "nothing to change: give enabled, or params, or both.",
            );

            if (p.params.len > Guard.max_params) return hostFailure(
                "TooManyParameters",
                "that is more parameters than any plugin has; send the ones that need changing.",
            );

            if (p.enabled) |to| switch (Guard.enabling(to)) {
                .allowed => {},
                .refused => |msg| return hostFailure("Refused", msg),
            };

            // A manifest that declares no parameters has none this surface
            // may set -- the same rule `wants` follows, where saying
            // nothing is asking for nothing.
            var declared: usize = 0;
            for (view.params) |pv| {
                if (!pv.undeclared) declared += 1;
            }
            if (p.params.len > 0 and declared == 0) return hostFailure(
                "NoParameters",
                try std.fmt.allocPrint(
                    alloc,
                    "{s} declares no parameters in its plugin.json, so there is nothing " ++
                        "here to set. Only whether it is switched on can be changed.",
                    .{p.key},
                ),
            );

            // Roots that could not be read refuse every `file:` rather than
            // guessing at containment, which is what the vtable already
            // promises about an empty list.
            const roots = host.pluginRoots(alloc) catch |err| blk: {
                log.warn("poltergeist: could not work out the plugin directories err={}", .{err});
                break :blk &[_][]const u8{};
            };
            const guard: Guard = .{ .roots = roots };

            for (p.params) |change| {
                const pv = declaredParam(view, change.name) orelse return hostFailure(
                    "UnknownParameter",
                    try std.fmt.allocPrint(alloc, "{s} has no parameter called {s}. It takes: {s}.", .{
                        p.key,
                        change.name,
                        try declaredNames(alloc, view),
                    }),
                );

                // Before `value`, because what is already there decides
                // this one and nothing about the new value can change it.
                switch (Guard.repointing(specFrom(pv), pv.holds)) {
                    .allowed => {},
                    .refused => |msg| return hostFailure(
                        "Refused",
                        try std.fmt.allocPrint(alloc, "{s}: {s}", .{ change.name, msg }),
                    ),
                }

                switch (guard.value(specFrom(pv), change.value)) {
                    .allowed => {},
                    .refused => |msg| {
                        // The one refusal that cannot say what to do next on
                        // its own: which values are taken is the plugin's,
                        // not the rule's. Compared by content, because a
                        // sentence being one interned literal is not
                        // something to build a decision on.
                        const said = if (std.mem.eql(u8, msg, Guard.refusal.not_a_choice))
                            try std.fmt.allocPrint(alloc, "{s}: {s} It takes: {s}.", .{
                                change.name,
                                msg,
                                try joined(alloc, pv.choices),
                            })
                        else
                            try std.fmt.allocPrint(alloc, "{s}: {s}", .{ change.name, msg });

                        return hostFailure("Refused", said);
                    },
                }
            }

            const said = host.pluginConfigure(alloc, p.key, p.enabled, p.params) catch |err|
                return switch (err) {
                    error.NoSuchPlugin => hostFailure(
                        "UnknownPlugin",
                        try unknownPluginMessage(alloc, p.key),
                    ),
                    error.NotImplemented => hostFailure("NotImplemented", not_wired_up),
                    else => hostFailure("HostRefused", "the plugin's settings could not be written"),
                };
            return .{ .text = said };
        },

        .plugin_test => |p| {
            if (p.key.len == 0) return hostFailure(
                "UnknownPlugin",
                "a plugin key is needed; plugin_list shows what is installed.",
            );

            // `caller` and no free text: the wording of a test notification
            // is the host's, and it says which terminal asked for it. A
            // tool that took a title and a body would be a way out to the
            // person that `notify_user`'s own rules never saw.
            const said = host.pluginTest(alloc, p.key, caller) catch |err| return switch (err) {
                error.NoSuchPlugin => hostFailure(
                    "UnknownPlugin",
                    try unknownPluginMessage(alloc, p.key),
                ),

                // The minute is counted in the host, which is where there is
                // somewhere to keep the last time. Dispatch is a free
                // function and holds nothing between calls.
                error.TooSoon => hostFailure(
                    "TooSoon",
                    "a plugin was tested less than a minute ago; wait before sending the person another one.",
                ),
                error.NotImplemented => hostFailure("NotImplemented", not_wired_up),
                else => hostFailure("HostRefused", "the plugin could not be tested"),
            };
            return .{ .text = said };
        },
    }
}

fn lessById(_: void, a: wire.TerminalInfo, b: wire.TerminalInfo) bool {
    return a.id < b.id;
}

fn describe(bus: *const Bus, host: Host, id: Bus.Id) wire.TerminalInfo {
    // A terminal with no entry is one nobody has put under watch. It gets
    // its identity and nothing else: quiet time is not measured for it, and
    // saying `0` would claim it was busy this instant.
    const e = bus.get(id) orelse return .{ .id = id };

    return .{
        .id = id,
        .role = e.role,
        .duty = e.duty,
        .held = e.held,
        .shielded = e.shielded,
        // Null rather than zero when nothing has ever sampled it. Zero
        // here means "moving this instant", which is a claim, and a
        // terminal nobody has looked at yet gives no grounds for one.
        .quiet_ms = if (bus.observed(id)) host.quietMs(id) else null,
        .watching = e.role == .watched,
        .rounds = e.rounds,
    };
}

fn failure(err: Error) wire.Response {
    return .{ .failed = .{ .code = @errorName(err), .message = errorMessage(err) } };
}

/// Turn what the chat log refused into something an agent can act on.
fn chatFailure(err: anyerror) wire.Response {
    return switch (err) {
        error.NoSuchGroup => hostFailure("NoSuchGroup", "no group by that name"),
        // An empty group has nobody in it to disturb; one with terminals
        // in it is a conversation they are working in, and taking it away
        // is something done to them rather than to a name. So the members
        // come out first, deliberately, and this says how.
        error.GroupActive => hostFailure(
            "GroupActive",
            "that group still has terminals in it. Take them out with group_remove first -- destroying it would drop them from a conversation without telling them.",
        ),
        error.GroupExists => hostFailure("GroupExists", "a group by that name already exists"),
        error.NotAMember => hostFailure("NotAMember", "you are not in that group"),
        error.TooManyGroups => hostFailure("TooManyGroups", "there are already too many groups"),
        error.BadName => hostFailure("BadName", "group names may use lowercase letters, digits and dashes"),
        error.Empty => hostFailure("Empty", "there is nothing there to send or to compact"),
        else => hostFailure("ChatFailed", "the group could not do that"),
    };
}

/// Said when the host has the tools but this build has not wired them up.
///
/// Kept distinct from `HostRefused` so a half-landed build says the true
/// thing: "not built yet" and "tried and would not" ask for different next
/// moves from whoever reads it.
const not_wired_up = "the plugin tools are not wired up in this build yet";

/// A panel failure, in the words the agent needs.
///
/// Separate from `chatFailure` rather than folded into it because the
/// answers are different sentences: "that is not your task" is something a
/// worker can act on, and "no group by that name" is not.
fn taskFailure(err: anyerror) wire.Response {
    return switch (err) {
        error.NoSuchTask => hostFailure(
            "NoSuchTask",
            "no task by that number. task_list shows what there is.",
        ),
        error.NotYours => hostFailure(
            "NotYours",
            "that task is somebody else's. task_list shows yours.",
        ),
        error.NotOpen => hostFailure(
            "NotOpen",
            "that task is closed or was cancelled, so there is nothing to move.",
        ),
        error.BadTitle => hostFailure(
            "BadTitle",
            "a task needs a one-line title.",
        ),
        error.BadProgress => hostFailure(
            "BadProgress",
            "progress is one of: queued, working, blocked, done.",
        ),
        error.TooManyTasks => hostFailure(
            "TooManyTasks",
            "this panel is full. Close what is finished.",
        ),
        error.NoSuchGroup => hostFailure("NoSuchGroup", "no group by that name"),

        // The one failure the caller has to act on. The task is still
        // open, on purpose: a cancellation nobody heard is not a
        // cancellation, and saying `ok` would have the supervisor stop
        // thinking about work that is still being done.
        // The worker's terminal is showing the user why its process
        // died. Same answer as a terminal that is gone: it cannot be told,
        // so the task is not cancelled.
        error.ChildExited,
        error.NoSuchTerminal,
        error.OwnerGone,
        => hostFailure(
            "OwnerGone",
            "the terminal working on that is gone, so it could not be told to stop. " ++
                "The task is still open: assign it to nobody with task_assign if you " ++
                "want it off somebody's list.",
        ),
        // Somebody is at that keyboard right now, so nothing was typed
        // into it -- the same guard every other write to a terminal keeps.
        // The task is untouched, and asking again in a moment works.
        error.UserPresent => hostFailure(
            "NotTold",
            "somebody is typing in that terminal, so it was not told and the task " ++
                "is still open. Try again in a moment.",
        ),
        error.NotImplemented => hostFailure("NotImplemented", not_wired_up),
        else => hostFailure("HostRefused", "the panel could not do that"),
    };
}

fn unknownPluginMessage(
    alloc: std.mem.Allocator,
    key: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        alloc,
        "no plugin called {s} is installed. plugin_list shows what is.",
        .{key},
    );
}

/// The spec a listed parameter came from, for handing back to `Guard`.
///
/// `holds` and `shown` are how the value looks once it is written down;
/// none of the rules is about them.
fn specFrom(v: PluginParamView) Plugin.ParamSpec {
    return .{
        .name = v.name,
        .title = v.title,
        .required = v.required,
        .secret = v.secret,
        .choices = v.choices,
    };
}

/// The parameter by that name, but only if the manifest declares one.
///
/// Skipping the undeclared entries is the whole point of the loop. They are
/// in the listing so that an audit sees everything the file holds; matching
/// one here would let an agent set any name that already happens to be in
/// there -- and an undeclared name carries no `secret` flag, so the
/// plaintext rule would never apply to it.
fn declaredParam(view: PluginView, name: []const u8) ?PluginParamView {
    for (view.params) |p| {
        if (p.undeclared) continue;
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// The names a plugin takes, for the message that has just refused one it
/// does not. Declared only: a name that is in the file but not in the
/// manifest is not something to suggest writing more of.
fn declaredNames(
    alloc: std.mem.Allocator,
    view: PluginView,
) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (view.params) |p| {
        if (p.undeclared) continue;
        if (out.items.len > 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, p.name);
    }
    return out.items;
}

fn joined(
    alloc: std.mem.Allocator,
    items: []const []const u8,
) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (items) |it| {
        if (out.items.len > 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, it);
    }
    return out.items;
}

fn hostFailure(code: []const u8, message: []const u8) wire.Response {
    return .{ .failed = .{ .code = code, .message = message } };
}

// -- dispatch tests ---------------------------------------------------------

/// What the fake host reports as installed.
///
/// Two, because the rules have two shapes to be tried against: a plugin
/// with one open, required parameter, and one declaring both a closed set
/// and a parameter its author marked a credential.
const fake_plugins = [_]PluginView{
    .{
        .key = "webhook",
        .name = "Webhook",
        .events = &.{"terminal.quiet"},
        .params = &.{
            .{ .name = "url", .required = true },
        },
    },
    .{
        .key = "chat-archive",
        .name = "Chat archive",
        .events = &.{"chat"},
        .params = &.{
            .{
                .name = "backend",
                .required = true,
                .choices = &.{ "postgres", "file" },
                .holds = "literal",
                .shown = "file",
            },
            .{ .name = "dsn", .secret = true },
        },
    },
};

const fake_roots = [_][]const u8{"/tmp/polter-fake-config/polter"};
/// A host that records what it was asked to do and can be told to refuse.
const FakeHost = struct {
    sent: ?struct { id: Bus.Id, text: []const u8, submit: bool } = null,

    /// Make typing fail the way a real terminal can: its process has gone,
    /// or somebody is at the keyboard.
    send_error: ?anyerror = null,
    set_to: ?struct { id: Bus.Id, ms: u64 } = null,
    read_count: usize = 0,
    refuse: bool = false,
    posted: ?struct { group: []const u8, from: Bus.Id, text: []const u8 } = null,
    added: ?struct { group: []const u8, id: Bus.Id, history: History } = null,
    compacted: ?struct { group: []const u8, through: u64, summary: []const u8, by: Bus.Id } = null,
    read_group: ?[]const u8 = null,
    quiet_ms: u64 = 0,

    /// What the last `group_history` asked for, and what the fake says
    /// about there being older still.
    history_asked: ?struct { group: []const u8, before_seq: u64, limit: usize } = null,
    history_more: bool = false,

    /// Which terminal told the host it had stood down, if any did.
    stood_down: ?Bus.Id = null,

    /// The last action asked for, and what the fake does with it.
    ///
    /// `confirm_close` is recorded rather than ignored because it is the
    /// one thing about a close that this surface decides and the host only
    /// carries out -- a test that watched the action string alone could not
    /// tell "close it" from "close it, asking first".
    acted: ?struct {
        id: Bus.Id,
        action: []const u8,
        confirm_close: bool = true,
    } = null,
    action_error: ?anyerror = null,

    /// The last key asked for, and what the fake does with it.
    keyed: ?struct { id: Bus.Id, key: []const u8 } = null,
    key_error: ?anyerror = null,

    /// The last terminal asked for, what the fake hands back, and how it
    /// can be made to refuse.
    opened: ?struct { cwd: []const u8, by: Bus.Id } = null,
    open_result: ?Bus.Id = null,
    open_error: ?anyerror = null,

    /// What the fake calls its configuration.
    config: []const u8 = "poltergeist-watch = false\npoltergeist-notify = feishu\n",
    config_error: ?anyerror = null,

    /// What `notices` hands back, and how many times it was asked.
    notices: []const u8 = "",
    drained: usize = 0,

    /// The last brief that was written, if any.
    brief_set: ?struct { group: []const u8, text: []const u8 } = null,

    /// What `session_recall` hands back.
    session: []const u8 = "",

    /// The reason of the last notification asked for.
    notified: ?[]const u8 = null,

    /// What is on screen, whether or not the bus knows about any of it.
    open: []const Place = &.{},

    /// Whether the last `set_watch` asked to start or stop sampling.
    watching: ?bool = null,

    /// Who the fake says made every group. Null means the usual boss.
    group_owner: ?Bus.Id = null,

    /// What `pluginList` reports. Two plugins by default so the tests
    /// exercise both shapes there are: a notification plugin with one
    /// required parameter, and an archive one declaring both a closed set
    /// and a credential.
    plugins: []const PluginView = &fake_plugins,

    /// Raised by every plugin call, for the failures that only the host can
    /// know about -- an unknown key, a test asked for too soon.
    plugin_error: ?anyerror = null,

    /// The directories a `file:` reference may point into.
    roots: []const []const u8 = &fake_roots,

    /// What was actually written. Every refusal test asserts this is still
    /// null: whole-or-nothing comes from dispatch's ordering alone, and
    /// nothing in the types would notice a reordering.
    configured: ?struct {
        key: []const u8,
        enable: ?bool,
        params: []const Plugin.Param,
    } = null,

    /// The last plugin a test was asked for, and who asked.
    tested: ?struct { key: []const u8, by: Bus.Id } = null,

    /// A real panel, so the two filters can be watched disagreeing rather
    /// than described. Null for the tests that do not care.
    panel: ?*Tasks = null,

    /// Stands in for a group that still has terminals working in it. The
    /// crossing that decides this is the host's -- it is the only party
    /// that knows which terminals are open -- so what is testable here is
    /// what the agent is told when the answer comes back yes.
    group_active: bool = false,

    /// Whether a group was actually taken off the list.
    destroyed: bool = false,

    fn host(self: *FakeHost) Host {
        return .{ .ctx = self, .vtable = &.{
            .readTerminal = read,
            .sendText = send,
            .sendKey = sendKey,
            .performAction = performAction,
            .openTerminal = openTerminal,
            .configText = configText,
            .quietMs = quietMs,
            .openTerminals = openTerminals,
            .setWatching = setWatching,
            .stoodDown = stoodDown,
            .drainNotices = drainNotices,
            .setThreshold = setThreshold,
            .readSkill = readSkill,
            .chatCreate = chatCreate,
            .chatDestroy = chatDestroy,
            .chatAdd = chatAdd,
            .chatRemove = chatRemove,
            .chatCompact = chatCompact,
            .chatPost = chatPost,
            .notifyUser = notifyUser,
            .sessionRecall = sessionRecall,
            .chatSetBrief = chatSetBrief,
            .chatGroupInfo = chatGroupInfo,
            .chatOwner = chatOwner,
            .chatMembers = chatMembers,
            .chatGroups = chatGroups,
            .chatRead = chatRead,
            .chatHistory = chatHistory,
            .pluginList = pluginList,
            .pluginRoots = pluginRoots,
            .pluginConfigure = pluginConfigure,
            .pluginTest = pluginTest,
            .taskCreate = taskCreate,
            .taskAssign = taskAssign,
            .taskClose = taskClose,
            .taskOwner = taskOwner,
            .taskCancel = taskCancel,
            .taskProgress = taskProgress,
            .taskList = taskList,
        } };
    }

    fn pluginList(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        key: []const u8,
    ) anyerror![]const PluginView {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.plugin_error) |err| return err;

        // An empty key means all of them, which is the contract the vtable
        // states and the reason dispatch may not take the first entry.
        var out: std.ArrayListUnmanaged(PluginView) = .empty;
        for (self.plugins) |v| {
            if (key.len > 0 and !std.mem.eql(u8, v.key, key)) continue;
            try out.append(alloc, v);
        }
        return out.items;
    }

    fn pluginRoots(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![]const []const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        return alloc.dupe([]const u8, self.roots);
    }

    fn pluginConfigure(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        key: []const u8,
        enable: ?bool,
        params: []const Plugin.Param,
    ) anyerror![]const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.plugin_error) |err| return err;
        self.configured = .{ .key = key, .enable = enable, .params = params };
        return alloc.dupe(u8, "written");
    }

    fn pluginTest(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        key: []const u8,
        by: Bus.Id,
    ) anyerror![]const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.plugin_error) |err| return err;
        self.tested = .{ .key = key, .by = by };
        return alloc.dupe(u8, "tested");
    }

    fn taskCreate(ctx: *anyopaque, group: []const u8, title: []const u8) anyerror!u64 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        const panel = self.panel orelse return error.NotImplemented;
        return panel.create(group, title);
    }

    fn taskAssign(ctx: *anyopaque, task: u64, id: Bus.Id) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        const panel = self.panel orelse return error.NotImplemented;
        return panel.assign(task, id);
    }

    fn taskClose(ctx: *anyopaque, task: u64) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        const panel = self.panel orelse return error.NotImplemented;
        return panel.close(task);
    }

    fn taskOwner(ctx: *anyopaque, task: u64) anyerror!TaskOwner {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        const panel = self.panel orelse return error.NotImplemented;
        const t = panel.get(task) orelse return error.NoSuchTask;
        return .{ .owner = t.owner, .title = t.title };
    }

    fn taskCancel(ctx: *anyopaque, task: u64) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        const panel = self.panel orelse return error.NotImplemented;
        return panel.cancel(task);
    }

    fn taskProgress(
        ctx: *anyopaque,
        task: u64,
        by: Bus.Id,
        progress: []const u8,
    ) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        const panel = self.panel orelse return error.NotImplemented;
        const value = std.meta.stringToEnum(Tasks.Progress, progress) orelse
            return error.BadProgress;
        return panel.setProgress(task, by, value);
    }

    fn taskList(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        group: []const u8,
        who: Bus.Id,
        whole_panel: bool,
    ) anyerror![]const TaskView {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        const panel = self.panel orelse return error.NotImplemented;

        const list = if (whole_panel)
            try panel.inGroup(alloc, group)
        else
            try panel.forWorker(alloc, group, who);
        defer alloc.free(list);

        const out = try alloc.alloc(TaskView, list.len);
        for (list, 0..) |t, i| out[i] = .{
            .id = t.id,
            .title = t.title,
            .owner = t.owner,
            .state = @tagName(t.state),
            .progress = @tagName(t.progress),
        };
        return out;
    }

    fn chatOwner(ctx: *anyopaque, _: []const u8) anyerror!Bus.Id {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        return self.group_owner orelse boss;
    }

    fn chatCreate(ctx: *anyopaque, _: []const u8, _: Bus.Id) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.GroupExists;
    }

    fn chatDestroy(ctx: *anyopaque, _: []const u8) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NoSuchGroup;
        if (self.group_active) return error.GroupActive;
        self.destroyed = true;
    }

    fn chatAdd(
        ctx: *anyopaque,
        group: []const u8,
        id: Bus.Id,
        history: History,
    ) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NoSuchGroup;
        self.added = .{ .group = group, .id = id, .history = history };
    }

    fn chatRemove(ctx: *anyopaque, _: []const u8, _: Bus.Id) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NoSuchGroup;
    }

    fn chatCompact(
        ctx: *anyopaque,
        group: []const u8,
        through: u64,
        summary: []const u8,
        by: Bus.Id,
    ) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NoSuchGroup;
        self.compacted = .{
            .group = group,
            .through = through,
            .summary = summary,
            .by = by,
        };
    }

    fn chatPost(
        ctx: *anyopaque,
        group: []const u8,
        from: Bus.Id,
        text: []const u8,
    ) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NoSuchGroup;
        self.posted = .{ .group = group, .from = from, .text = text };
    }

    fn chatGroupInfo(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        _: Bus.Id,
        want_brief: bool,
    ) anyerror![]ChatGroupInfo {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.ListFailed;

        const out = try alloc.alloc(ChatGroupInfo, 1);
        out[0] = .{
            .name = try alloc.dupe(u8, "build"),
            .brief = if (want_brief)
                try alloc.dupe(u8, "写 retry 装饰器")
            else
                "",
        };
        return out;
    }

    fn notifyUser(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        reason: []const u8,
        _: []const u8,
        _: []const u8,
        _: Bus.Id,
    ) anyerror![]const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NotifyFailed;
        self.notified = reason;
        return alloc.dupe(u8, "sent to 1 of 1");
    }

    fn sessionRecall(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![]const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.ReadFailed;
        return alloc.dupe(u8, self.session);
    }

    fn chatSetBrief(ctx: *anyopaque, group: []const u8, text: []const u8) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NoSuchGroup;
        self.brief_set = .{ .group = group, .text = text };
    }

    fn chatMembers(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        _: []const u8,
    ) anyerror![]const ChatMember {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NoSuchGroup;

        const out = try alloc.alloc(ChatMember, 1);
        out[0] = .{ .id = 0x9999, .title = try alloc.dupe(u8, "a terminal") };
        return out;
    }

    fn chatGroups(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        _: Bus.Id,
    ) anyerror![]const []const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NoSuchGroup;

        const names = try alloc.alloc([]const u8, 1);
        names[0] = try alloc.dupe(u8, "build");
        return names;
    }

    fn chatRead(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        group: []const u8,
        _: Bus.Id,
        since: u64,
    ) anyerror![]const ChatLine {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NotAMember;
        self.read_group = group;

        const one = try alloc.alloc(ChatLine, 1);
        one[0] = .{
            .seq = since + 1,
            .from = 0x9999,
            .author = try alloc.dupe(u8, "a terminal"),
            .at_ms = 0,
            .summary = false,
            .text = try alloc.dupe(u8, "hello"),
        };
        return one;
    }

    fn chatHistory(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        group: []const u8,
        _: Bus.Id,
        before_seq: u64,
        limit: usize,
    ) anyerror!ChatPage {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.NotAMember;
        self.history_asked = .{
            .group = group,
            .before_seq = before_seq,
            .limit = limit,
        };

        const one = try alloc.alloc(ChatLine, 1);
        one[0] = .{
            // No group seq: the log never recorded one, and the real host
            // does not invent one either.
            .seq = 0,
            .log_seq = if (before_seq == 0) 999 else before_seq - 1,
            .from = 0x9999,
            .author = try alloc.dupe(u8, "a terminal"),
            .at_ms = 0,
            .summary = false,
            .text = try alloc.dupe(u8, "said earlier"),
        };
        return .{ .lines = one, .more = self.history_more };
    }

    fn readSkill(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        name: []const u8,
    ) anyerror![]const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.Refused;
        return std.fmt.allocPrint(alloc, "prose for {s}", .{name});
    }

    fn read(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        _: Bus.Id,
        _: u16,
    ) anyerror![]const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.Refused;
        self.read_count += 1;
        return alloc.dupe(u8, "screen contents");
    }

    fn send(ctx: *anyopaque, id: Bus.Id, text: []const u8, submit: bool) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.Refused;
        if (self.send_error) |err| return err;
        self.sent = .{ .id = id, .text = text, .submit = submit };
    }

    fn quietMs(ctx: *anyopaque, _: Bus.Id) u64 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        return self.quiet_ms;
    }

    fn openTerminals(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
    ) anyerror![]const Place {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        return alloc.dupe(Place, self.open);
    }

    fn configText(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        key: []const u8,
    ) anyerror![]const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.config_error) |err| return err;
        if (key.len == 0) return alloc.dupe(u8, self.config);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        var it = std.mem.splitScalar(u8, self.config, '\n');
        while (it.next()) |line| {
            if (!std.mem.startsWith(u8, line, key)) continue;
            if (!std.mem.startsWith(u8, line[key.len..], " =")) continue;
            try out.appendSlice(alloc, line);
            try out.append(alloc, '\n');
        }
        if (out.items.len == 0) return error.NoSuchKey;
        return out.items;
    }

    fn openTerminal(
        ctx: *anyopaque,
        _: std.mem.Allocator,
        cwd: []const u8,
        by: Bus.Id,
    ) anyerror!?Bus.Id {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.open_error) |err| return err;
        self.opened = .{ .cwd = cwd, .by = by };
        return self.open_result;
    }

    fn sendKey(ctx: *anyopaque, id: Bus.Id, k: []const u8) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.key_error) |err| return err;
        self.keyed = .{ .id = id, .key = k };
    }

    fn performAction(
        ctx: *anyopaque,
        id: Bus.Id,
        action: []const u8,
        confirm_close: bool,
    ) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.action_error) |err| return err;
        self.acted = .{ .id = id, .action = action, .confirm_close = confirm_close };
    }

    fn stoodDown(ctx: *anyopaque, id: Bus.Id) void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        self.stood_down = id;
    }

    fn setWatching(ctx: *anyopaque, _: Bus.Id, watching: bool) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        self.watching = watching;
    }

    fn drainNotices(ctx: *anyopaque, alloc: std.mem.Allocator, _: Bus.Id) anyerror![]const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.Refused;
        self.drained += 1;
        return alloc.dupe(u8, self.notices);
    }

    fn setThreshold(ctx: *anyopaque, id: Bus.Id, ms: u64) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (self.refuse) return error.Refused;
        self.set_to = .{ .id = id, .ms = ms };
    }
};

test "dispatch refuses an unauthorized request before touching the host" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(testing.allocator, &b, fake.host(), term(worker), .{
        .terminal_read = .{ .id = boss },
    });

    // `Supervised`, not `NotPermitted`: the method is open to this caller
    // and the target is what refused it. The two answers send an agent
    // somewhere different, which is the reason for having both.
    try testing.expectEqualStrings("Supervised", res.failed.code);
    try testing.expectEqual(@as(usize, 0), fake.read_count);

    // And one the method itself is closed to, for the contrast.
    const closed = try dispatch(testing.allocator, &b, fake.host(), term(worker), .{
        .clock_out = .{ .id = boss },
    });
    try testing.expectEqualStrings("NotPermitted", closed.failed.code);
}

test "the supervisor can read and type into a watched terminal" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    const read = try dispatch(testing.allocator, &b, fake.host(), term(boss), .{
        .terminal_read = .{ .id = worker },
    });
    defer testing.allocator.free(read.text);
    try testing.expectEqualStrings("screen contents", read.text);

    const sent = try dispatch(testing.allocator, &b, fake.host(), term(boss), .{
        .terminal_send = .{ .id = worker, .text = "继续", .submit = true },
    });
    try testing.expect(sent == .ok);
    try testing.expectEqualStrings("继续", fake.sent.?.text);
    try testing.expectEqual(worker, fake.sent.?.id);
}

test "a host refusal comes back as a failure the agent can read" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{ .refuse = true };

    const res = try dispatch(testing.allocator, &b, fake.host(), term(boss), .{
        .terminal_send = .{ .id = worker, .text = "x" },
    });
    try testing.expectEqualStrings("SendFailed", res.failed.code);
    try testing.expect(res.failed.message.len > 0);
}

test "clock_out through dispatch still obeys the hold" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    try b.setHeld(worker, true, .user);
    const res = try dispatch(testing.allocator, &b, fake.host(), term(boss), .{
        .clock_out = .{ .id = worker },
    });

    try testing.expectEqualStrings("TerminalHeld", res.failed.code);
    try testing.expectEqual(Bus.Duty.on, b.get(worker).?.duty);
}

test "terminal_list is sorted so two listings can be compared" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    try b.watch(0xaaaa, boss);
    try b.watch(0x0001, boss);

    const open = [_]Place{
        .{ .id = 0xaaaa }, .{ .id = 0x0001 }, .{ .id = boss }, .{ .id = worker },
    };
    var fake: FakeHost = .{ .open = &open };

    const res = try dispatch(testing.allocator, &b, fake.host(), term(boss), .terminal_list);
    defer testing.allocator.free(res.terminals);

    try testing.expect(res.terminals.len >= 4);
    for (res.terminals[1..], 0..) |info, i| {
        try testing.expect(res.terminals[i].id < info.id);
    }
}

test "terminal_list says which terminals are out of reach before anything is refused" {
    // Not a duplicate of the wire test. That one proves the field reaches
    // the JSON once something puts it in `TerminalInfo`; this one proves
    // `describe` puts it there, which is the step that can be dropped
    // without a single test noticing -- the two halves are in different
    // files and neither is enough on its own.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try b.watch(0x5151, boss);
    try b.setShielded(0x5151, true, .user);

    const open = [_]Place{
        .{ .id = boss },
        .{ .id = 0x5151 },
        // Never registered with the bus at all: `describe` takes its early
        // exit for this one, so the default has to be the open case.
        .{ .id = 0x7272 },
    };
    var fake: FakeHost = .{ .open = &open };

    const res = try dispatch(testing.allocator, &b, fake.host(), term(boss), .terminal_list);
    defer testing.allocator.free(res.terminals);

    var shielded: ?wire.TerminalInfo = null;
    var stranger: ?wire.TerminalInfo = null;
    for (res.terminals) |info| {
        if (info.id == 0x5151) shielded = info;
        if (info.id == 0x7272) stranger = info;
    }

    try testing.expect((shielded orelse return error.NotListed).shielded);
    try testing.expect(!(stranger orelse return error.NotListed).shielded);
}

test "a terminal nobody is watching is still listed, with where it is" {
    // The restore case, and the reason this list stopped coming from the
    // bus. After a restart nothing is under watch -- so a list built from
    // the bus is empty exactly when the supervisor needs it to match last
    // night's notes against what is on screen.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    const open = [_]Place{
        .{ .id = boss, .cwd = "/work", .title = "supervisor" },
        .{ .id = 0x5151, .cwd = "/work/alpha", .title = "◑ colstat" },
    };
    var fake: FakeHost = .{ .open = &open, .quiet_ms = 4242 };

    const res = try dispatch(testing.allocator, &b, fake.host(), term(boss), .terminal_list);
    defer testing.allocator.free(res.terminals);

    var found: ?wire.TerminalInfo = null;
    for (res.terminals) |info| if (info.id == 0x5151) {
        found = info;
    };
    const stranger = found orelse return error.NotListed;

    // Enough to put it back: where it was, and what it was called.
    try testing.expectEqualStrings("/work/alpha", stranger.cwd);
    try testing.expectEqualStrings("◑ colstat", stranger.title);

    // And nothing that would have to be measured to be true. The fake
    // would happily answer 4242ms; a terminal nobody samples has no
    // quiet time, and `0` would read as "busy this instant".
    try testing.expect(!stranger.watching);
    try testing.expectEqual(Bus.Role.none, stranger.role);
    try testing.expect(stranger.quiet_ms == null);
    try testing.expect(stranger.rounds == null);
}

test "me works for a terminal that supervises nothing" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{ .quiet_ms = 4242 };

    // Sampled at least once, or the duration comes back null -- see the
    // test below, which is about exactly that.
    _ = b.report(worker, .{ .quiescent = .{
        .quiet_ms = 4242,
        .silent_ms = 4242,
        .changed_rows = 0,
        .total_rows = 24,
    } }, 4242);

    const res = try dispatch(testing.allocator, &b, fake.host(), term(worker), .me);
    try testing.expectEqual(worker, res.me.id);
    try testing.expectEqual(Bus.Role.watched, res.me.role);
    try testing.expectEqual(@as(u64, 4242), res.me.quiet_ms);
    try testing.expect(res.me.watching);
}

test "a terminal nothing has sampled reports no duration, not a huge one" {
    // It used to report how long the *program* had been running: the last
    // event time defaulted to zero, so "now minus never" came back as
    // hours. A terminal opened a minute ago and working flat out was
    // described to its supervisor as still for half a day -- and quiet
    // time is the whole basis on which a supervisor decides to intervene.
    //
    // Null, not zero: zero says "moving this instant", which is a claim,
    // and nothing has looked at this terminal to make one.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{ .quiet_ms = 46_292_971 };

    const res = try dispatch(testing.allocator, &b, fake.host(), term(worker), .me);
    try testing.expectEqual(Bus.Role.watched, res.me.role);
    try testing.expect(res.me.quiet_ms == null);
}

test "any terminal may read a skill" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    // A watched terminal can read how supervision works. These are
    // instructions, not reach, and refusing would mean an agent cannot find
    // out why it was nudged.
    const res = try dispatch(testing.allocator, &b, fake.host(), term(worker), .{
        .skill_read = .{ .name = "supervising" },
    });
    defer testing.allocator.free(res.skill.body);
    try testing.expectEqualStrings("supervising", res.skill.name);
    try testing.expectEqualStrings("prose for supervising", res.skill.body);
}

test "an unknown skill fails rather than returning nothing" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{ .refuse = true };

    const res = try dispatch(testing.allocator, &b, fake.host(), term(boss), .{
        .skill_read = .{ .name = "no-such-skill" },
    });
    try testing.expectEqualStrings("NoSuchSkill", res.failed.code);
}

test "an unclaimed terminal may put itself forward as supervisor" {
    // Until now the only road to the job was the user pressing a key, so
    // an agent that could see work needing somebody to co-ordinate it had
    // no way at all to say so.
    var b: Bus = .init(testing.allocator, .{});
    defer b.deinit();
    var fake: FakeHost = .{};
    try b.register(worker);

    const res = try dispatch(
        testing.allocator,
        &b,
        fake.host(),
        term(worker),
        .become_supervisor,
    );
    try testing.expect(res == .text);
    try testing.expect(b.isSupervisor(worker));
}

test "a terminal the bus has never heard of may still put itself forward" {
    // Being unknown is the most unclaimed a terminal can be. Refusing here
    // would mean the tool only worked for terminals somebody had already
    // taken an interest in, which is the opposite of who it is for.
    var b: Bus = .init(testing.allocator, .{});
    defer b.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(
        testing.allocator,
        &b,
        fake.host(),
        term(0x5151),
        .become_supervisor,
    );
    try testing.expect(res == .text);
    try testing.expect(b.isSupervisor(0x5151));
}

test "a watched terminal may not put itself forward" {
    // The hard one. Its supervisor is not consulted and would never learn
    // of it; and a watched terminal is the likeliest place for injected
    // text to arrive, so "promote yourself" must not be a sentence that
    // rearranges who may reach whom.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(
        testing.allocator,
        &b,
        fake.host(),
        term(worker),
        .become_supervisor,
    );
    try testing.expectEqualStrings("AlreadyWatched", res.failed.code);
    try testing.expectEqual(Bus.Role.watched, b.get(worker).?.role);
    try testing.expect(!b.isSupervisor(worker));

    // And the message points somewhere it can actually go, rather than
    // leaving it to guess.
    try testing.expect(std.mem.indexOf(u8, res.failed.message, "supervisor") != null);
}

test "a supervisor putting itself forward is told so, not refused" {
    // Refusing would read as "you did something wrong" and send the agent
    // looking for another way in. It did nothing wrong; it is already
    // what it was asking to be.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(
        testing.allocator,
        &b,
        fake.host(),
        term(boss),
        .become_supervisor,
    );
    try testing.expect(res == .text);
    try testing.expect(std.mem.indexOf(u8, res.text, "already") != null);
    try testing.expect(b.isSupervisor(boss));
}

test "a supervisor that stood down may put itself forward again" {
    // Decided deliberately. `stand_down` exists to end the empty box
    // handed over every interval for the rest of the night; what it
    // guards against is a supervisor quietly carrying on. Coming back is
    // a deliberate act that leaves a record, which is the opposite of
    // quietly carrying on -- so there is no "has stood down" mark, and
    // nothing here to check for one.
    var b: Bus = .init(testing.allocator, .{});
    defer b.deinit();
    var fake: FakeHost = .{};
    try b.addSupervisor(boss);

    const down = try dispatch(
        testing.allocator,
        &b,
        fake.host(),
        term(boss),
        .stand_down,
    );
    try testing.expect(down == .ok);
    try testing.expect(!b.isSupervisor(boss));
    try testing.expectEqual(Bus.Role.none, b.roleOf(boss));

    const up = try dispatch(
        testing.allocator,
        &b,
        fake.host(),
        term(boss),
        .become_supervisor,
    );
    try testing.expect(up == .text);
    try testing.expect(b.isSupervisor(boss));
}

test "become_supervisor is open to everyone, targets nobody, and names no id" {
    // Three separate switches, each exhaustive, each with a different
    // consequence if this method is filed under the wrong arm.
    //
    // `requiresSupervisor` true would make it unreachable by exactly the
    // terminals it exists for. `targetsTerminal` true would send it
    // through the self-target and existence checks meant for a request
    // that names somebody else. `target` returning an id would mean it
    // acted on a terminal the caller chose, which is a far larger power
    // than the one being added: promoting *another* terminal.
    try testing.expect(!requiresSupervisor(.become_supervisor));
    try testing.expect(!targetsTerminal(.become_supervisor));
    try testing.expect(target(.become_supervisor) == null);
}

test "reading the notices is the supervisor's alone" {
    // A watched terminal reading the supervisor's box would learn which of
    // its peers had gone quiet and for how long -- a picture of the whole
    // room that its own role never granted it.
    try testing.expect(requiresSupervisor(.notices));
}

test "notices hands back what is waiting and clears it" {
    var b: Bus = .init(testing.allocator, .{});
    defer b.deinit();
    try b.addSupervisor(boss);

    var fake: FakeHost = .{ .notices = "[poltergeist] 0x2222 quiet 90s" };
    const host = fake.host();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const res = try dispatch(arena.allocator(), &b, host, term(boss), .notices);
    try testing.expectEqualStrings("[poltergeist] 0x2222 quiet 90s", res.text);
    try testing.expectEqual(@as(usize, 1), fake.drained);
}

test "an empty box is an answer, not a failure" {
    // The supervisor asked and nothing is waiting. That is worth saying
    // plainly rather than as an error it would have to interpret.
    var b: Bus = .init(testing.allocator, .{});
    defer b.deinit();
    try b.addSupervisor(boss);

    var fake: FakeHost = .{};
    const host = fake.host();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const res = try dispatch(arena.allocator(), &b, host, term(boss), .notices);
    try testing.expectEqualStrings("", res.text);
}

test "a group's brief is the supervisor's alone to write" {
    // Saying what a group is for is arranging it, which is the same
    // authority as making one.
    try testing.expect(requiresSupervisor(.group_set_brief));
}

test "only the supervisor's listing carries the brief" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The supervisor sees what it wrote.
    const mine = try dispatch(alloc, &b, fake.host(), term(boss), .group_list);
    try testing.expect(mine.groups[0].brief.len > 0);

    // A member gets the group but not the note. Not an error -- asking
    // which groups you are in is a fair question.
    const theirs = try dispatch(alloc, &b, fake.host(), term(worker), .group_list);
    try testing.expectEqualStrings("build", theirs.groups[0].name);
    try testing.expectEqualStrings("", theirs.groups[0].brief);
}

test "setting a brief reaches the host with what was written" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{
        .group_set_brief = .{ .group = "build", .text = "写 retry 装饰器" },
    });
    try testing.expectEqual(wire.Response.ok, res);
    try testing.expectEqualStrings("build", fake.brief_set.?.group);
    try testing.expectEqualStrings("写 retry 装饰器", fake.brief_set.?.text);
}

test "the person at the keyboard sees the brief too" {
    // Not because they wrote it, but because it is their machine and they
    // face the same question the supervisor does: what was "build" for?
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const res = try dispatch(
        arena.allocator(),
        &b,
        fake.host(),
        term(Chat.user_id),
        .group_list,
    );
    try testing.expect(res.groups[0].brief.len > 0);
}

test "a reply is capped so it cannot outgrow the line buffer" {
    // The failure this prevents is not a slow reply, it is `StreamTooLong`
    // and a connection that never recovers: the next attempt asks for the
    // same range and fails the same way. It took a few days of real use to
    // reach, because it needs a group with a few hundred long messages in
    // it.
    const big = "x" ** 8192;

    var lines: [64]ChatLine = undefined;
    for (&lines, 0..) |*line, i| line.* = .{
        .seq = i,
        .from = 1,
        .author = "worker",
        .at_ms = 0,
        .summary = false,
        .text = big,
    };

    const kept = capMessages(&lines).lines;
    try testing.expect(kept.len < lines.len);

    var total: usize = 0;
    for (kept) |line| total += line.text.len + line.author.len;

    // Inside the budget, and not so far inside that a caller polling one
    // instalment at a time would be here all day.
    try testing.expect(total <= read_budget_bytes + big.len);
    try testing.expect(kept.len > 1);
}

test "one message larger than the whole budget is still delivered" {
    // Returning nothing would leave the caller polling forever with a
    // cursor that never moves -- a quieter failure than the one this
    // replaced, and a worse one.
    const huge = "y" ** (128 * 1024);
    const lines = [_]ChatLine{.{
        .seq = 1,
        .from = 1,
        .author = "worker",
        .at_ms = 0,
        .summary = false,
        .text = huge,
    }};

    try testing.expectEqual(@as(usize, 1), capMessages(&lines).lines.len);
}

test "a reply that fits is passed through whole" {
    const lines = [_]ChatLine{
        .{ .seq = 1, .from = 1, .author = "a", .at_ms = 0, .summary = false, .text = "hello" },
        .{ .seq = 2, .from = 2, .author = "b", .at_ms = 0, .summary = false, .text = "there" },
    };
    try testing.expectEqual(@as(usize, 2), capMessages(&lines).lines.len);
}

test "set_watch works on a terminal nobody is watching, which is the point" {
    // The bug this catches: every other tool here acts on a terminal
    // already under supervision, so the permission check required the
    // target to be known -- and `set_watch` inherited it. That made it
    // refuse every terminal it was for, because a terminal you are about
    // to start watching is by definition not being watched yet.
    //
    // The first version of this test used a terminal the fixture had
    // already watched, and passed while the tool was unusable.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    const stranger: Bus.Id = 0x5151;
    try testing.expect(b.get(stranger) == null);

    try authorize(&b, term(boss), .{ .set_watch = .{ .id = stranger, .watch = true } });
}

test "only the supervisor may start watching a terminal" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try testing.expectError(
        error.NotPermitted,
        authorize(&b, term(worker), .{ .set_watch = .{ .id = 0x5151, .watch = true } }),
    );
}

test "a supervisor cannot put itself under its own supervision" {
    // A knot rather than a feature: the supervisor is not one of the
    // terminals it watches, and the keybind path says so too.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    try testing.expectError(
        error.SelfTarget,
        authorize(&b, term(boss), .{ .set_watch = .{ .id = boss, .watch = true } }),
    );
}

test "clocking out a terminal the bus never heard of is refused by the bus" {
    // `authorize` no longer refuses an unregistered id -- see the reach
    // rule -- so the refusal has to come from the side that has somewhere
    // to record the answer, and it does. Checked through `dispatch` rather
    // than through `authorize`, because that is where the answer now is.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    try authorize(&b, term(boss), .{ .clock_out = .{ .id = 0x5151 } });

    const res = try dispatch(testing.allocator, &b, fake.host(), term(boss), .{
        .clock_out = .{ .id = 0x5151 },
    });
    try testing.expectEqualStrings("UnknownTerminal", res.failed.code);
}

test "a group belongs to the supervisor that made it" {
    // With one supervisor this could not come up. With several, any of
    // them could otherwise destroy another's group or pull terminals out
    // of it, and the first anybody would know is that a conversation had
    // stopped working.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    try b.addSupervisor(other);

    var fake: FakeHost = .{ .group_owner = boss };

    // The one that made it may rearrange it.
    _ = try dispatch(testing.allocator, &b, fake.host(), term(boss), .{
        .group_set_brief = .{ .group = "build", .text = "what this is for" },
    });

    // The other supervisor may not, however senior it feels.
    const refused = try dispatch(testing.allocator, &b, fake.host(), term(other), .{
        .group_destroy = .{ .group = "build" },
    });
    try testing.expectEqualStrings("NotYours", refused.failed.code);
}

test "talking in a group you were added to is not rearranging it" {
    // Membership and ownership are different things: the point of a group
    // is that the terminals in it can talk, and only the arranging is the
    // supervisor's.
    var b = try testBus(testing.allocator);
    defer b.deinit();

    var fake: FakeHost = .{ .group_owner = other };

    _ = try dispatch(testing.allocator, &b, fake.host(), term(worker), .{
        .group_post = .{ .group = "build", .text = "signature is settled" },
    });
}

test "a capped reply says it was capped" {
    // Without this a reader that gets the budget's worth stops there,
    // believing it has the whole conversation. The conversations view did
    // exactly that for two days: 324 messages in the log, 35 on screen,
    // and every poll asking from the beginning and getting the same
    // oldest batch back.
    const big = "x" ** 8192;

    var lines: [64]ChatLine = undefined;
    for (&lines, 0..) |*line, i| line.* = .{
        .seq = i,
        .from = 1,
        .author = "worker",
        .at_ms = 0,
        .summary = false,
        .text = big,
    };

    const capped = capMessages(&lines);
    try testing.expect(capped.lines.len < lines.len);
    try testing.expect(capped.more);
}

test "a reply that fits says there is no more" {
    const lines = [_]ChatLine{
        .{ .seq = 1, .from = 1, .author = "a", .at_ms = 0, .summary = false, .text = "hello" },
    };

    const capped = capMessages(&lines);
    try testing.expectEqual(@as(usize, 1), capped.lines.len);
    try testing.expect(!capped.more);
}

/// Run one `group_history` against the fake and free what comes back.
///
/// The fake hands back a single line, so the reply is always the whole
/// allocation rather than a tail of it -- `capHistory` returns a subslice,
/// and the testing allocator cannot free one of those.
fn historyOnce(
    b: *Bus,
    fake: *FakeHost,
    caller: Bus.Id,
    req: Request,
) !void {
    const res = try dispatch(testing.allocator, b, fake.host(), term(caller), req);
    for (res.messages.lines) |m| {
        testing.allocator.free(m.text);
        testing.allocator.free(m.author);
    }
    testing.allocator.free(res.messages.lines);
}

test "group_history is open to a terminal already in the group" {
    // The tool that reads a conversation backwards is the same kind of act
    // as reading it forwards, and the view the user themselves types into
    // is not a supervisor either. Making this one supervisor-only would
    // shut the person at the keyboard out of their own scrollback.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(testing.allocator, &b, fake.host(), term(worker), .{
        .group_history = .{ .group = "build" },
    });
    defer {
        for (res.messages.lines) |m| {
            testing.allocator.free(m.text);
            testing.allocator.free(m.author);
        }
        testing.allocator.free(res.messages.lines);
    }
    try testing.expect(res == .messages);
}

test "a terminal outside the group is told so rather than handed the log" {
    // Being open to every terminal is not the same as being open to every
    // caller: the file on disk holds every group at once, so the one place
    // membership is checked has to be the host, and its refusal has to
    // reach the agent as words it can act on.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{ .refuse = true };

    const res = try dispatch(testing.allocator, &b, fake.host(), term(worker), .{
        .group_history = .{ .group = "build", .before_seq = 10432 },
    });
    try testing.expectEqualStrings("NotAMember", res.failed.code);
    try testing.expect(res.failed.message.len > 0);
}

test "group_history asks for the cursor and limit it was given" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    try historyOnce(&b, &fake, worker, .{
        .group_history = .{ .group = "build", .before_seq = 10432, .limit = 50 },
    });

    try testing.expectEqualStrings("build", fake.history_asked.?.group);
    try testing.expectEqual(@as(u64, 10432), fake.history_asked.?.before_seq);
    try testing.expectEqual(@as(usize, 50), fake.history_asked.?.limit);
}

test "a history request with no limit gets the default" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    try historyOnce(&b, &fake, worker, .{ .group_history = .{ .group = "build" } });
    try testing.expectEqual(default_history_limit, fake.history_asked.?.limit);
}

test "a limit past the ceiling is brought down to it" {
    // An agent that asks for five thousand messages is not going to read
    // them, and the reply would not fit down the line anyway.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    try historyOnce(&b, &fake, worker, .{
        .group_history = .{ .group = "build", .limit = 5000 },
    });
    try testing.expectEqual(max_history_limit, fake.history_asked.?.limit);
}

test "a history message carries no group seq" {
    // Inventing one would be worse than leaving it empty: an agent would
    // hand it straight back as `group_compact`'s `through`, and that
    // number counts something else entirely.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(testing.allocator, &b, fake.host(), term(worker), .{
        .group_history = .{ .group = "build", .before_seq = 42 },
    });
    defer {
        for (res.messages.lines) |m| {
            testing.allocator.free(m.text);
            testing.allocator.free(m.author);
        }
        testing.allocator.free(res.messages.lines);
    }

    try testing.expectEqual(@as(u64, 0), res.messages.lines[0].seq);
    try testing.expect(res.messages.lines[0].log_seq != 0);
}

test "a host that says there is more is believed even when nothing was capped" {
    // One short line is nowhere near the budget, so the only thing that
    // can say there is older still is the log itself.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var fake: FakeHost = .{ .history_more = true };

    const res = try dispatch(testing.allocator, &b, fake.host(), term(worker), .{
        .group_history = .{ .group = "build" },
    });
    defer {
        for (res.messages.lines) |m| {
            testing.allocator.free(m.text);
            testing.allocator.free(m.author);
        }
        testing.allocator.free(res.messages.lines);
    }

    try testing.expect(res.messages.more);
}

test "capHistory keeps the newest, because a history caller pages backwards" {
    // The mistake this catches passes a length check: cap the batch from
    // the wrong end and the caller's next `before_seq` points past the
    // stretch it was just handed, leaving a hole nothing will ever fill.
    const big = "x" ** 8192;

    var lines: [64]ChatLine = undefined;
    for (&lines, 0..) |*line, i| line.* = .{
        .seq = 0,
        .log_seq = 1000 + i,
        .from = 1,
        .author = "worker",
        .at_ms = 0,
        .summary = false,
        .text = big,
    };

    const capped = capHistory(&lines);
    try testing.expect(capped.lines.len < lines.len);
    try testing.expect(capped.more);

    // The newest survived and the oldest was the part dropped.
    try testing.expectEqual(
        lines[lines.len - 1].log_seq,
        capped.lines[capped.lines.len - 1].log_seq,
    );
    try testing.expect(capped.lines[0].log_seq > lines[0].log_seq);
}

test "one history message larger than the whole budget is still delivered" {
    const huge = "y" ** (128 * 1024);
    const lines = [_]ChatLine{.{
        .seq = 0,
        .log_seq = 7,
        .from = 1,
        .author = "worker",
        .at_ms = 0,
        .summary = false,
        .text = huge,
    }};

    try testing.expectEqual(@as(usize, 1), capHistory(&lines).lines.len);
}

test "an empty history batch is the beginning, not a cut one" {
    // The walk backwards ends here, and the budget has nothing to say
    // about it. Claiming `more` on nothing would have the view ask again
    // for the same emptiness every time somebody holds page-up.
    const capped = capHistory(&.{});
    try testing.expectEqual(@as(usize, 0), capped.lines.len);
    try testing.expect(!capped.more);
}

test "a history batch that fits says there is no more" {
    const lines = [_]ChatLine{
        .{ .seq = 0, .log_seq = 1, .from = 1, .author = "a", .at_ms = 0, .summary = false, .text = "hello" },
        .{ .seq = 0, .log_seq = 2, .from = 2, .author = "b", .at_ms = 0, .summary = false, .text = "there" },
    };

    const capped = capHistory(&lines);
    try testing.expectEqual(@as(usize, 2), capped.lines.len);
    try testing.expect(!capped.more);
}

test {
    // Zig only analyses what is referenced. Without this, a public
    // declaration that nothing has called yet -- `Guard`, and the view
    // types the plugin tools hand back -- would not be compiled at all, and
    // the group picking it up would find out by breaking the build rather
    // than by reading it here.
    testing.refAllDecls(@This());
}

test "the plugin tools are the supervisor's" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fake: FakeHost = .{};

    for ([_]Request{
        .{ .plugin_list = .{} },
        .{ .plugin_configure = .{ .key = "webhook", .enabled = true } },
        .{ .plugin_test = .{ .key = "webhook" } },
    }) |req| {
        // A watched terminal is turned away before anything else about the
        // request is looked at.
        const refused = try dispatch(alloc, &b, fake.host(), term(worker), req);
        try testing.expectEqualStrings("NotPermitted", refused.failed.code);

        // And the supervisor is not, whatever else becomes of the request.
        const res = try dispatch(alloc, &b, fake.host(), term(boss), req);
        const code = switch (res) {
            .failed => |f| f.code,
            else => "",
        };
        try testing.expect(!std.mem.eql(u8, "NotPermitted", code));
    }
}

test "a cmd: reference is refused however it is written" {
    const g: Guard = .{ .roots = &.{"/home/u/.config/polter"} };
    const open: Plugin.ParamSpec = .{ .name = "url" };
    const credential: Plugin.ParamSpec = .{ .name = "dsn", .secret = true };

    try testing.expectEqualStrings(Guard.refusal.cmd, g.value(open, "cmd:x").refused);

    // The bare prefix too: what makes it a command is the prefix, not there
    // being something after it.
    try testing.expectEqualStrings(Guard.refusal.cmd, g.value(open, "cmd:").refused);

    // Case-sensitive, deliberately: `resolve` would send `CMD:x` as the
    // five characters it is and never run it, so refusing it here would be
    // refusing an inert literal. It is still caught the moment the
    // parameter is one that holds a credential -- both halves pinned, so
    // neither can drift into being an accident.
    try testing.expect(g.value(open, "CMD:x") == .allowed);
    try testing.expectEqualStrings(
        Guard.refusal.plaintext_secret,
        g.value(credential, "CMD:x").refused,
    );

    // End to end, and nothing reaches the settings file.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{ .plugin_configure = .{
        .key = "webhook",
        .params = &.{.{ .name = "url", .value = "cmd:curl https://elsewhere" }},
    } });
    try testing.expectEqualStrings("Refused", res.failed.code);
    try testing.expect(fake.configured == null);
}

test "a credential already pointed somewhere is not re-pointed here" {
    // The third way to switch a channel off, and the quietest. `enabled:
    // false` is refused and clearing a required parameter is refused, but
    // `env:NOT_A_REAL_NAME` is a well-formed reference that passes every
    // other rule and fails hours later, at the moment the plugin is
    // called, with nobody watching.
    const set: Plugin.ParamSpec = .{ .name = "dsn", .secret = true };
    const open: Plugin.ParamSpec = .{ .name = "schema" };

    try testing.expectEqualStrings(
        Guard.refusal.repointing,
        Guard.repointing(set, "env:").refused,
    );
    try testing.expectEqualStrings(
        Guard.refusal.repointing,
        Guard.repointing(set, "keychain:").refused,
    );

    // Setting one that is not set yet is the helpful direction, and stays
    // open: the channel does not work now and might afterwards.
    try testing.expect(Guard.repointing(set, "unset") == .allowed);

    // And a parameter that holds no credential is nobody's channel.
    try testing.expect(Guard.repointing(open, "literal") == .allowed);

    // End to end, and nothing reaches the settings file.
    const configured = [_]PluginView{.{
        .key = "chat-archive",
        .events = &.{"chat"},
        .params = &.{
            .{ .name = "dsn", .secret = true, .holds = "env:", .shown = "env:POLTER_PG" },
        },
    }};

    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{ .plugins = &configured };

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{ .plugin_configure = .{
        .key = "chat-archive",
        .params = &.{.{ .name = "dsn", .value = "env:NOT_A_REAL_NAME" }},
    } });
    try testing.expectEqualStrings("Refused", res.failed.code);
    try testing.expect(fake.configured == null);
}

test "a secret parameter will not take a plaintext value" {
    const g: Guard = .{ .roots = &.{"/home/u/.config/polter"} };
    const s: Plugin.ParamSpec = .{ .name = "dsn", .secret = true };

    try testing.expectEqualStrings(
        Guard.refusal.plaintext_secret,
        g.value(s, "postgresql://u:pw@h:5432/db").refused,
    );

    // The three that name somewhere the user has already put the thing.
    try testing.expect(g.value(s, "env:POLTER_PG") == .allowed);
    try testing.expect(g.value(s, "keychain:polter/pg") == .allowed);
    try testing.expect(g.value(s, "file:/home/u/.config/polter/pg.key") == .allowed);

    // Ordering, pinned: `cmd:` is refused as a command before it is ever
    // weighed as a way of holding a credential.
    try testing.expectEqualStrings(Guard.refusal.cmd, g.value(s, "cmd:op read op://x").refused);
}

test "a file: reference has to be under the polter directories" {
    const g: Guard = .{ .roots = &.{
        "/home/u/.config/polter",
        "/home/u/.local/state/polter",
    } };
    const p: Plugin.ParamSpec = .{ .name = "dsn", .secret = true };

    try testing.expect(g.value(p, "file:/home/u/.config/polter/pg.key") == .allowed);
    try testing.expect(g.value(p, "file:/home/u/.local/state/polter/pg.key") == .allowed);

    try testing.expectEqualStrings(
        Guard.refusal.file_outside,
        g.value(p, "file:/etc/passwd").refused,
    );

    // A prefix is not containment.
    try testing.expectEqualStrings(
        Guard.refusal.file_outside,
        g.value(p, "file:/home/u/.config/polterhouse/pg.key").refused,
    );

    // A `..` anywhere, so containment cannot be walked out of.
    try testing.expectEqualStrings(
        Guard.refusal.file_outside,
        g.value(p, "file:/home/u/.config/polter/../../.ssh/id_rsa").refused,
    );

    // The root names a directory; a reference has to name a file in it.
    try testing.expect(!g.underRoot("/home/u/.config/polter"));
    try testing.expect(!g.underRoot("/home/u/.config/polter/"));

    // No roots means they could not be worked out, and every reference is
    // refused rather than guessed at.
    const none: Guard = .{};
    try testing.expect(!none.underRoot("/home/u/.config/polter/pg.key"));
    try testing.expectEqualStrings(
        Guard.refusal.file_outside,
        none.value(p, "file:/home/u/.config/polter/pg.key").refused,
    );

    // A tilde gets its own sentence. `roots` are absolute and containment
    // is decided on the text, so this can never be under one -- and
    // `file_outside` would be telling somebody to move a file that is
    // already exactly where it belongs.
    try testing.expectEqualStrings(
        Guard.refusal.file_tilde,
        g.value(p, "file:~/.config/polter/pg.key").refused,
    );
}

test "switching a plugin off is refused and switching one on is not" {
    try testing.expect(Guard.enabling(true) == .allowed);
    try testing.expectEqualStrings(Guard.refusal.switching_off, Guard.enabling(false).refused);

    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    // A perfectly good parameter alongside the request to switch off. The
    // whole request drops; there is no half of it that lands.
    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{ .plugin_configure = .{
        .key = "webhook",
        .enabled = false,
        .params = &.{.{ .name = "url", .value = "env:POLTER_WEBHOOK" }},
    } });
    try testing.expectEqualStrings("Refused", res.failed.code);
    try testing.expect(fake.configured == null);
}

test "every reference prefix secret.zig knows is judged by the guard" {
    // A fifth prefix added to `secret.zig` and nowhere else stops the
    // build, because `Guard.value` switches exhaustively. This says the
    // other half out loud: each one lands somewhere named, so nobody can
    // add one and let it fall through as an inert literal.
    const g: Guard = .{ .roots = &.{"/home/u/.config/polter"} };
    const spec: Plugin.ParamSpec = .{ .name = "dsn", .secret = true };

    inline for (comptime std.enums.values(secret.Prefix)) |p| {
        const v = comptime std.fmt.comptimePrint("{s}x", .{secret.text(p)});
        const verdict = g.value(spec, v);
        switch (p) {
            // Runs something later, on nobody's authority.
            .cmd => try testing.expectEqualStrings(Guard.refusal.cmd, verdict.refused),

            // Names a file, and where the file is decides it. `x` is not
            // under any root.
            .file => try testing.expectEqualStrings(Guard.refusal.file_outside, verdict.refused),

            // Carry data out of somewhere the user already put it.
            .env, .keychain => try testing.expect(verdict == .allowed),
        }
    }
}

test "a listing never shows a value that could be a secret" {
    const open: Plugin.ParamSpec = .{ .name = "dsn" };

    // Every reference is shown as written: where a secret lives is not the
    // secret, and a supervisor cannot tell a wrong variable name from a
    // right one without seeing it.
    inline for (comptime std.enums.values(secret.Prefix)) |p| {
        const v = comptime std.fmt.comptimePrint("{s}NAME", .{secret.text(p)});
        const got = viewOf(open, v);
        try testing.expectEqualStrings(secret.text(p), got.holds);
        try testing.expectEqualStrings(v, got.shown);
    }

    // A literal with nothing pinning it says that it is there and no more.
    const bare = viewOf(open, "postgresql://u:pw@h/db");
    try testing.expectEqualStrings("literal", bare.holds);
    try testing.expectEqualStrings("", bare.shown);

    const enumerated: Plugin.ParamSpec = .{
        .name = "backend",
        .choices = &.{ "postgres", "file" },
    };
    const in_set = viewOf(enumerated, "postgres");
    try testing.expectEqualStrings("literal", in_set.holds);
    try testing.expectEqualStrings("postgres", in_set.shown);

    // Off the list, so the closed set is not what is holding it. The only
    // way it got into the file is by hand, which is the case where nobody
    // knows what is in there.
    try testing.expectEqualStrings("", viewOf(enumerated, "mysql://u:pw@h/db").shown);

    // Marked a credential: never, whatever else is true of it.
    const credential: Plugin.ParamSpec = .{ .name = "dsn", .secret = true };
    try testing.expectEqualStrings("", viewOf(credential, "hunter2").shown);

    const unset = viewOf(open, "");
    try testing.expectEqualStrings("unset", unset.holds);
    try testing.expectEqualStrings("", unset.shown);

    // A name the manifest never declared is judged against nothing, so a
    // literal in it is never shown -- and it is still listed, because an
    // audit has to see what is in the file.
    const stray = undeclaredView("whatever", "hunter2");
    try testing.expect(stray.undeclared);
    try testing.expectEqualStrings("literal", stray.holds);
    try testing.expectEqualStrings("", stray.shown);
}

test "a parameter the manifest does not declare cannot be set" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        var fake: FakeHost = .{};
        const res = try dispatch(alloc, &b, fake.host(), term(boss), .{ .plugin_configure = .{
            .key = "webhook",
            .params = &.{.{ .name = "endpoint", .value = "env:POLTER_WEBHOOK" }},
        } });
        try testing.expectEqualStrings("UnknownParameter", res.failed.code);

        // Saying what it does take is what stops the next attempt being a
        // guess at another name.
        try testing.expect(std.mem.indexOf(u8, res.failed.message, "url") != null);
        try testing.expect(fake.configured == null);
    }

    {
        // A manifest declaring none has none to set, the same rule `wants`
        // follows: saying nothing is asking for nothing.
        const bare = [_]PluginView{.{ .key = "bare", .events = &.{"terminal.quiet"} }};
        var fake: FakeHost = .{ .plugins = &bare };
        const res = try dispatch(alloc, &b, fake.host(), term(boss), .{ .plugin_configure = .{
            .key = "bare",
            .params = &.{.{ .name = "url", .value = "env:POLTER_WEBHOOK" }},
        } });
        try testing.expectEqualStrings("NoParameters", res.failed.code);
        try testing.expect(fake.configured == null);
    }

    {
        // The hole worth naming: the name IS in the settings file, as an
        // entry the manifest does not declare. Matching on the name alone
        // would let it through -- and an undeclared name carries no
        // `secret` flag, so the plaintext rule would never look at it.
        const stray = [_]PluginView{.{
            .key = "webhook",
            .events = &.{"terminal.quiet"},
            .params = &.{
                .{ .name = "url", .required = true },
                .{ .name = "smuggled", .holds = "literal", .undeclared = true },
            },
        }};
        var fake: FakeHost = .{ .plugins = &stray };
        const res = try dispatch(alloc, &b, fake.host(), term(boss), .{ .plugin_configure = .{
            .key = "webhook",
            .params = &.{.{ .name = "smuggled", .value = "hunter2" }},
        } });
        try testing.expectEqualStrings("UnknownParameter", res.failed.code);
        try testing.expect(fake.configured == null);
    }
}

test "a control character in a value is refused" {
    const g: Guard = .{};
    const spec: Plugin.ParamSpec = .{ .name = "note" };

    for ([_][]const u8{ "a\nb", "a\rb", "a\tb", "a\x00b", "a\x1bb" }) |v| {
        try testing.expectEqualStrings(Guard.refusal.control, g.value(spec, v).refused);
    }

    // The length boundary, from both sides of it.
    const fits = [_]u8{'x'} ** Guard.max_value_bytes;
    try testing.expect(g.value(spec, &fits) == .allowed);

    const over = [_]u8{'x'} ** (Guard.max_value_bytes + 1);
    try testing.expectEqualStrings(Guard.refusal.too_long, g.value(spec, &over).refused);
}

test "a required parameter cannot be emptied through this surface" {
    const g: Guard = .{};

    try testing.expectEqualStrings(
        Guard.refusal.clearing_required,
        g.value(.{ .name = "url", .required = true }, "").refused,
    );

    // Not required, so an empty value still means what an empty value is
    // for: take this one out again.
    try testing.expect(g.value(.{ .name = "schema" }, "") == .allowed);

    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    // Clearing `url` mutes the notification channel without ever asking to
    // switch anything off, which is the whole reason this rule is here.
    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{ .plugin_configure = .{
        .key = "webhook",
        .params = &.{.{ .name = "url", .value = "" }},
    } });
    try testing.expectEqualStrings("Refused", res.failed.code);
    try testing.expect(fake.configured == null);
}

test "a value the parameter does not take is refused with the ones it does" {
    const g: Guard = .{};
    const spec: Plugin.ParamSpec = .{
        .name = "backend",
        .choices = &.{ "postgres", "file" },
    };

    try testing.expectEqualStrings(Guard.refusal.not_a_choice, g.value(spec, "mysql").refused);
    try testing.expect(g.value(spec, "postgres") == .allowed);

    // A reference is not weighed against the set: what it resolves to is
    // not known until the plugin is called, and refusing it here would be
    // guessing at it.
    try testing.expect(g.value(spec, "env:POLTER_BACKEND") == .allowed);

    var b = try testBus(testing.allocator);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeHost = .{};

    const res = try dispatch(arena.allocator(), &b, fake.host(), term(boss), .{ .plugin_configure = .{
        .key = "chat-archive",
        .params = &.{.{ .name = "backend", .value = "mysql" }},
    } });
    try testing.expectEqualStrings("Refused", res.failed.code);

    // This is the one refusal that cannot say what to do next on its own:
    // which values are taken belongs to the plugin, not to the rule. So
    // dispatch appends them -- and it decides to by comparing the sentence
    // by content, never by trusting two literals to be the same pointer.
    try testing.expect(std.mem.indexOf(u8, res.failed.message, "backend") != null);
    try testing.expect(std.mem.indexOf(u8, res.failed.message, "postgres, file") != null);
    try testing.expect(fake.configured == null);
}

test "the shipped manifests mark their credentials, so the guard has something to refuse" {
    // `Guard` only refuses a plaintext credential where the manifest says
    // one is a credential, so every rule above is worth exactly what the
    // shipped `plugin.json` files declare. Nothing else in the build reads
    // them at compile time, which means an author dropping `"secret": true`
    // would turn `plugin_configure` into a way to put a long-lived
    // credential of an agent's choosing on the user's disk in plaintext --
    // and every test in this file would still pass. This is the one that
    // would not.
    //
    // Embedded rather than read at runtime: a test that goes to the
    // filesystem passes when the file is missing, and missing is the
    // failure being guarded against.
    const shipped = [_]struct {
        manifest: []const u8,
        /// The parameters whose value is a credential, whatever they are
        /// named. A signing key does not look like a password and is one:
        /// whoever holds it can rewrite the archive and sign it again, so
        /// every line in it goes back to saying whatever they like.
        credentials: []const []const u8,
    }{
        .{
            .manifest = @embedFile("plugin_manifest_archive"),
            .credentials = &.{"sign_key"},
        },
    };

    // A list with nothing in it would make everything below pass by not
    // running, which is worse than having no test at all: a security check
    // that cannot fail reads, from the outside, exactly like one that keeps
    // passing. When the last shipped plugin holding a credential goes, this
    // is what says so.
    try testing.expect(shipped.len > 0);

    inline for (shipped) |s| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            testing.allocator,
            s.manifest,
            .{},
        );
        defer parsed.deinit();

        const properties = parsed.value.object
            .get("params").?.object
            .get("properties").?.object;

        for (s.credentials) |name| {
            const field = properties.get(name) orelse {
                std.debug.print("a shipped manifest no longer declares {s}\n", .{name});
                return error.CredentialParameterGone;
            };

            const marked = switch (field.object.get("secret") orelse .null) {
                .bool => |b| b,
                else => false,
            };
            try testing.expect(marked);

            // And the rule that only fires because of it. A guard with no
            // roots, so nothing but the marking is deciding this.
            const g: Guard = .{};
            const spec: Plugin.ParamSpec = .{ .name = name, .secret = marked };
            try testing.expectEqualStrings(
                Guard.refusal.plaintext_secret,
                g.value(spec, "https://attacker.example/collect").refused,
            );
        }
    }
}

// -- the plugin surface -----------------------------------------------------
//
// A plugin is the second door onto this tool surface, and the first one --
// `terminal_action` -- went in with no permission check at all: it could
// reach past `set_watch`'s supervisor gate and lift a `held` the user had
// set. So every gate is asked again here, from the other side of the door,
// rather than assumed to hold because it holds for terminals.

/// A plugin caller that declared everything, for the tests about the rules
/// that are *not* `wants.calls`.
fn plug(calls: []const []const u8) Bus.Caller {
    return .{ .plugin = .{ .key = "chat-archive", .calls = calls } };
}

test "a plugin is fed what it subscribed to and refused what it did not" {
    // The whole of what `Kind` used to decide, and the thing that made it
    // worth deleting: what a plugin is comes out of its own manifest, and
    // there is no list of kinds anywhere for a fourth one to be missing
    // from.
    const notifier: Plugin.Wants = .{ .events = &.{.terminal_quiet} };
    const archive: Plugin.Wants = .{ .events = &.{.chat}, .groups = &.{"*"} };
    const both: Plugin.Wants = .{
        .events = &.{ .chat, .terminal_quiet },
        .groups = &.{"build"},
    };

    try testing.expect(notifier.subscribes(.terminal_quiet));
    try testing.expect(!notifier.subscribes(.chat));
    try testing.expect(!notifier.subscribes(.provision));

    try testing.expect(archive.subscribes(.chat));
    try testing.expect(!archive.subscribes(.terminal_quiet));

    // One plugin, two subscriptions. Under `Kind` this was not expressible
    // at all: it took two plugins, or a fourth enum member.
    try testing.expect(both.subscribes(.chat));
    try testing.expect(both.subscribes(.terminal_quiet));
    try testing.expect(!both.subscribes(.provision));

    // No `"*"` for events, deliberately. A group is a name the user made
    // up and cannot be enumerated; the events are a closed set in
    // `Plugin.Event`, so a star would mean "and everything added after I
    // was written", which is a subscription to code that does not exist.
    const starred: Plugin.Wants = .{ .events = &.{}, .groups = &.{"*"} };
    try testing.expect(!starred.subscribes(.chat));
    try testing.expect(starred.empty());
}

test "a plugin's calls are what its manifest declared, and nothing near them" {
    var b: Bus = .init(testing.allocator, .{});
    defer b.deinit();

    const unmarked: Bus.Id = 0x2222;
    try b.register(unmarked);

    // Declared, and it goes through: a plugin is an ordinary unmarked
    // caller and reaches an unmarked terminal exactly as an agent does.
    try authorize(&b, plug(&.{"terminal_read"}), .{
        .terminal_read = .{ .id = unmarked },
    });

    // Not declared. Refused before anything else is even looked at, and
    // the refusal names the manifest rather than the permissions -- the fix
    // is a line in `plugin.json`, and a message about standing would send
    // the author hunting in the wrong file.
    try testing.expectError(error.NotDeclared, authorize(&b, plug(&.{"terminal_read"}), .{
        .terminal_send = .{ .id = unmarked, .text = "rm -rf /" },
    }));

    // The empty list refuses everything. That is the direction a missing
    // declaration has to fail in: the user read the manifest before
    // switching this on and was told it calls nothing.
    try testing.expectError(error.NotDeclared, authorize(&b, plug(&.{}), .{
        .terminal_read = .{ .id = unmarked },
    }));

    // And a declaration can only ever narrow. Declaring a supervisor's
    // method does not make a plugin a supervisor: it passes the manifest
    // gate and is refused by the next one -- with the same error and the
    // same sentence an ordinary terminal gets, which is the parity being
    // claimed.
    try testing.expectError(error.NotPermitted, authorize(&b, plug(&.{"set_watch"}), .{
        .set_watch = .{ .id = unmarked, .watch = true },
    }));
}

test "a plugin is never the boss, whatever it declares" {
    // The adopted default, and the direction it was chosen for: widening is
    // easy and narrowing after somebody has built on the wider rule is not.
    var b: Bus = .init(testing.allocator, .{});
    defer b.deinit();

    const chief: Bus.Id = 0x1111;
    const minded: Bus.Id = 0x2222;
    try b.register(chief);
    try b.register(minded);
    try b.addSupervisor(chief);
    try b.watch(minded, chief);

    // Every method that changes the supervision arrangement. A plugin has
    // no terminal, so `bus.isSupervisor` has nothing to be true of, and
    // each of these is refused without a second list saying "not plugins".
    try testing.expectError(error.NotPermitted, authorize(&b, plug(&.{"set_watch"}), .{
        .set_watch = .{ .id = minded, .watch = false },
    }));
    try testing.expectError(error.NotPermitted, authorize(&b, plug(&.{"clock_out"}), .{
        .clock_out = .{ .id = minded },
    }));
    try testing.expectError(error.NotPermitted, authorize(&b, plug(&.{"notify_user"}), .{
        .notify_user = .{ .reason = "authorisation", .title = "t" },
    }));

    // And it cannot promote itself out of that. `become_supervisor` is the
    // one method whose whole point is to be reachable by a caller that is
    // not a supervisor yet -- so it is not closed by `requiresSupervisor`,
    // and it has to be closed here or the default above is one call deep.
    try testing.expectError(error.NotATerminal, authorize(
        &b,
        plug(&.{"become_supervisor"}),
        .become_supervisor,
    ));

    // A marked terminal is therefore out of reach: the reach rule opens
    // marked terminals to supervisors only, and a plugin is never one.
    // Both marks, because they are two different marks.
    try testing.expectError(error.Supervised, authorize(&b, plug(&.{"terminal_read"}), .{
        .terminal_read = .{ .id = minded },
    }));
    try testing.expectError(error.Supervised, authorize(&b, plug(&.{"terminal_read"}), .{
        .terminal_read = .{ .id = chief },
    }));

    // What is open to it is what is open to any unmarked caller.
    const nobody: Bus.Id = 0x3333;
    try b.register(nobody);
    try authorize(&b, plug(&.{"terminal_read"}), .{ .terminal_read = .{ .id = nobody } });
}

test "a shielded terminal is out of reach of a plugin too" {
    // `shielded` is the user's, and it is absolute. It was already absolute
    // against a supervisor; the reason to prove it separately here is that
    // the last second door -- `terminal_action` -- went in with no check at
    // all and could walk past `set_watch`'s gate and lift a `held`. Every
    // door reopens every question.
    var b: Bus = .init(testing.allocator, .{});
    defer b.deinit();

    const guarded: Bus.Id = 0x4444;
    try b.register(guarded);
    try b.setShielded(guarded, true, .user);

    // Every method that touches a terminal, not one of them. A shield that
    // held off reading and not typing would be worth nothing.
    try testing.expectError(error.Shielded, authorize(&b, plug(&.{"terminal_read"}), .{
        .terminal_read = .{ .id = guarded },
    }));
    try testing.expectError(error.Shielded, authorize(&b, plug(&.{"terminal_send"}), .{
        .terminal_send = .{ .id = guarded, .text = "hello" },
    }));
    try testing.expectError(error.Shielded, authorize(&b, plug(&.{"terminal_key"}), .{
        .terminal_key = .{ .id = guarded, .key = "ctrl+c" },
    }));

    // `terminal_action` by name. This is the one that was found to be a
    // bypass with no permission check whatsoever, and a plugin calling it
    // is the same hole reopened from a new side.
    try testing.expectError(error.Shielded, authorize(&b, plug(&.{"terminal_action"}), .{
        .terminal_action = .{ .id = guarded, .action = "new_tab" },
    }));

    // And the shield is asked *before* the manifest gate is passed, which
    // is to say it does not matter what the plugin declared: an undeclared
    // call is refused for being undeclared, a declared one for the shield,
    // and there is no order of the two that lets it through.
    try testing.expectError(error.NotDeclared, authorize(&b, plug(&.{}), .{
        .terminal_action = .{ .id = guarded, .action = "new_tab" },
    }));

    // Take the shield off and the same call goes through, so the test above
    // is measuring the shield and not something else refusing anyway.
    try b.setShielded(guarded, false, .user);
    try authorize(&b, plug(&.{"terminal_action"}), .{
        .terminal_action = .{ .id = guarded, .action = "new_tab" },
    });
}

test "a plugin cannot be a terminal, and the methods that need one say so" {
    var b: Bus = .init(testing.allocator, .{});
    defer b.deinit();

    // Everything whose meaning is "who is asking": the author of a message,
    // a member of a group, the owner of a box of notices, the window a new
    // tab opens in. A plugin has no answer to any of them, and the refusal
    // says that rather than letting it act as some terminal.
    try testing.expectError(error.NotATerminal, authorize(&b, plug(&.{"me"}), .me));
    try testing.expectError(error.NotATerminal, authorize(&b, plug(&.{"group_post"}), .{
        .group_post = .{ .group = "build", .text = "hello" },
    }));
    try testing.expectError(error.NotATerminal, authorize(&b, plug(&.{"group_read"}), .{
        .group_read = .{ .group = "build" },
    }));
    // `terminal_open` is a supervisor's method as well, so the supervisor
    // rule reaches it first; `callableByPlugin` names it too, so a later
    // decision to open it to ordinary terminals does not open it to plugins
    // by omission -- which is precisely the shape of the bug this round
    // exists to stop.
    try testing.expectError(error.NotPermitted, authorize(&b, plug(&.{"terminal_open"}), .{
        .terminal_open = .{ .cwd = "/tmp" },
    }));
    try testing.expect(!callableByPlugin(.terminal_open));

    // Nor may it rewrite plugin settings -- its own included. That would be
    // a way round every check `plugin_configure` makes on the user's
    // behalf. It happens to be a supervisor's method as well, so the
    // refusal is the supervisor one; `callableByPlugin` names it too, so it
    // stays closed if that ever changes.
    try testing.expectError(error.NotPermitted, authorize(&b, plug(&.{"plugin_configure"}), .{
        .plugin_configure = .{ .key = "chat-archive", .enabled = true },
    }));
    try testing.expect(!callableByPlugin(.plugin_configure));
    try testing.expect(!callableByPlugin(.plugin_list));
    try testing.expect(!callableByPlugin(.plugin_test));

    // The union is what makes this structural rather than a rule: there is
    // no `Bus.Id` in a plugin caller, so there is nothing for it to name.
    try testing.expect(plug(&.{}).terminalId() == null);
    try testing.expect(!plug(&.{}).isTerminal(0));
    try testing.expect(!plug(&.{}).isTerminal(Bus.not_a_terminal));
}

// -- the panel --------------------------------------------------------------

/// A bus, a fake host and a real panel, wired together the way the app
/// wires them.
fn panelFixture(panel: *Tasks) FakeHost {
    return .{ .panel = panel, .open = &.{
        .{ .id = worker, .title = "worker" },
        .{ .id = other, .title = "other" },
    } };
}

test "making and handing out work is the supervisor's" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var panel: Tasks = .init(testing.allocator, .{});
    defer panel.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fake = panelFixture(&panel);

    const made = try dispatch(alloc, &b, fake.host(), term(boss), .{ .task_create = .{
        .group = "build",
        .title = "get the core building",
    } });
    try testing.expectEqual(@as(u64, 1), made.task);

    // The watched terminal may not make its own, nor hand one out, nor
    // close or cancel one. Four separate calls because a single switch arm
    // covering all four is exactly what a later edit splits.
    for ([_]Request{
        .{ .task_create = .{ .group = "build", .title = "mine" } },
        .{ .task_assign = .{ .task = 1, .id = other } },
        .{ .task_close = .{ .task = 1 } },
        .{ .task_cancel = .{ .task = 1 } },
    }) |req| {
        const res = try dispatch(alloc, &b, fake.host(), term(worker), req);
        try testing.expectEqualStrings("NotPermitted", res.failed.code);
    }
}

test "a worker sees its own open work and nothing else" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var panel: Tasks = .init(testing.allocator, .{});
    defer panel.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fake = panelFixture(&panel);

    const mine = try panel.create("build", "mine");
    try panel.assign(mine, worker);

    const theirs = try panel.create("build", "theirs");
    try panel.assign(theirs, other);

    const shut = try panel.create("build", "shut");
    try panel.assign(shut, worker);
    try panel.close(shut);

    {
        const res = try dispatch(alloc, &b, fake.host(), term(worker), .{ .task_list = .{
            .group = "build",
        } });
        try testing.expectEqual(@as(usize, 1), res.tasks.len);
        try testing.expectEqualStrings("mine", res.tasks[0].title);
    }

    // And the supervisor sees all three, closed one included: the two are
    // different questions and it must be possible to tell them apart from
    // out here, not only inside the model.
    {
        const res = try dispatch(alloc, &b, fake.host(), term(boss), .{ .task_list = .{
            .group = "build",
        } });
        try testing.expectEqual(@as(usize, 3), res.tasks.len);
    }

    // So does the person at the keyboard, who is no supervisor on the bus.
    {
        const res = try dispatch(alloc, &b, fake.host(), term(Chat.user_id), .{ .task_list = .{
            .group = "build",
        } });
        try testing.expectEqual(@as(usize, 3), res.tasks.len);
    }
}

test "a closed task is gone from the worker and still on the panel" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var panel: Tasks = .init(testing.allocator, .{});
    defer panel.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fake = panelFixture(&panel);

    const id = try panel.create("build", "one");
    try panel.assign(id, worker);

    // Visible before.
    {
        const res = try dispatch(alloc, &b, fake.host(), term(worker), .{ .task_list = .{
            .group = "build",
        } });
        try testing.expectEqual(@as(usize, 1), res.tasks.len);
    }

    _ = try dispatch(alloc, &b, fake.host(), term(boss), .{ .task_close = .{ .task = id } });

    {
        const res = try dispatch(alloc, &b, fake.host(), term(worker), .{ .task_list = .{
            .group = "build",
        } });
        try testing.expectEqual(@as(usize, 0), res.tasks.len);
    }
    {
        const res = try dispatch(alloc, &b, fake.host(), term(boss), .{ .task_list = .{
            .group = "build",
        } });
        try testing.expectEqual(@as(usize, 1), res.tasks.len);
        try testing.expectEqualStrings("closed", res.tasks[0].state);
    }
}

test "cancelling says so to the worker before the task goes" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var panel: Tasks = .init(testing.allocator, .{});
    defer panel.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fake = panelFixture(&panel);

    const id = try panel.create("build", "never mind");
    try panel.assign(id, worker);

    try testing.expect(fake.sent == null);
    const res = try dispatch(alloc, &b, fake.host(), term(boss), .{ .task_cancel = .{
        .task = id,
    } });

    // The whole rule, asserted rather than described: something was typed,
    // it went to the terminal that had the task, it was submitted rather
    // than left sitting in an input box, and it says what happened and
    // which task.
    try testing.expect(fake.sent != null);
    try testing.expectEqual(worker, fake.sent.?.id);
    try testing.expect(fake.sent.?.submit);
    try testing.expect(std.mem.indexOf(u8, fake.sent.?.text, "cancelled") != null);
    try testing.expect(std.mem.indexOf(u8, fake.sent.?.text, "never mind") != null);

    try testing.expectEqual(Tasks.State.cancelled, panel.get(id).?.state);

    // And the supervisor is told that somebody was told, rather than `ok`.
    try testing.expect(std.mem.indexOf(u8, res.text, "told to stop") != null);
}

test "a cancellation the worker could not be told leaves the task standing" {
    // The negative control for the one above. If the send fails and the
    // task is cancelled anyway, the supervisor stops thinking about work
    // that is still being done -- which is the silent state change the
    // whole ordering exists to prevent, arriving by the back door.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var panel: Tasks = .init(testing.allocator, .{});
    defer panel.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fake = panelFixture(&panel);

    // The way a terminal whose process has gone answers.
    fake.send_error = error.ChildExited;

    const id = try panel.create("build", "never mind");
    try panel.assign(id, worker);

    const res = try dispatch(alloc, &b, fake.host(), term(boss), .{ .task_cancel = .{
        .task = id,
    } });
    try testing.expectEqualStrings("OwnerGone", res.failed.code);
    try testing.expect(fake.sent == null);
    try testing.expectEqual(Tasks.State.open, panel.get(id).?.state);
}

test "closing sends nothing, because the worker already reported" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var panel: Tasks = .init(testing.allocator, .{});
    defer panel.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fake = panelFixture(&panel);

    const id = try panel.create("build", "one");
    try panel.assign(id, worker);
    _ = try dispatch(alloc, &b, fake.host(), term(boss), .{ .task_close = .{ .task = id } });
    try testing.expect(fake.sent == null);
}

test "a worker may move its own task and is refused another's" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var panel: Tasks = .init(testing.allocator, .{});
    defer panel.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fake = panelFixture(&panel);

    const mine = try panel.create("build", "mine");
    try panel.assign(mine, worker);
    const theirs = try panel.create("build", "theirs");
    try panel.assign(theirs, other);

    _ = try dispatch(alloc, &b, fake.host(), term(worker), .{ .task_progress = .{
        .task = mine,
        .progress = "blocked",
    } });
    try testing.expectEqual(Tasks.Progress.blocked, panel.get(mine).?.progress);

    const res = try dispatch(alloc, &b, fake.host(), term(worker), .{ .task_progress = .{
        .task = theirs,
        .progress = "done",
    } });
    try testing.expectEqualStrings("NotYours", res.failed.code);
    try testing.expectEqual(Tasks.Progress.queued, panel.get(theirs).?.progress);

    // And a word that is not one of the four is a mistake said out loud
    // rather than a silent no-op.
    const bad = try dispatch(alloc, &b, fake.host(), term(worker), .{ .task_progress = .{
        .task = mine,
        .progress = "nearly",
    } });
    try testing.expectEqualStrings("BadProgress", bad.failed.code);
}

test "progress on a cancelled task refuses, so a missed cancellation is heard" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var panel: Tasks = .init(testing.allocator, .{});
    defer panel.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fake = panelFixture(&panel);

    const id = try panel.create("build", "one");
    try panel.assign(id, worker);
    _ = try dispatch(alloc, &b, fake.host(), term(boss), .{ .task_cancel = .{ .task = id } });

    const res = try dispatch(alloc, &b, fake.host(), term(worker), .{ .task_progress = .{
        .task = id,
        .progress = "working",
    } });
    try testing.expectEqualStrings("NotOpen", res.failed.code);
}

test "work cannot be put on a group somebody else made" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var panel: Tasks = .init(testing.allocator, .{});
    defer panel.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fake = panelFixture(&panel);
    fake.group_owner = other;

    const res = try dispatch(alloc, &b, fake.host(), term(boss), .{ .task_create = .{
        .group = "build",
        .title = "one",
    } });
    try testing.expectEqualStrings("NotYours", res.failed.code);
}

test "a task handed to an id nobody has is refused" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var panel: Tasks = .init(testing.allocator, .{});
    defer panel.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fake: FakeHost = .{ .panel = &panel, .open = &.{} };

    const id = try panel.create("build", "one");
    const res = try dispatch(alloc, &b, fake.host(), term(boss), .{ .task_assign = .{
        .task = id,
        .id = 0x9999,
    } });
    try testing.expectEqualStrings("UnknownTerminal", res.failed.code);
    try testing.expectEqual(Tasks.nobody, panel.get(id).?.owner);

    // Zero is not a terminal and does not go through that check: it is how
    // a task is taken back off somebody.
    _ = try dispatch(alloc, &b, fake.host(), term(boss), .{ .task_assign = .{
        .task = id,
        .id = 0,
    } });
}

test "a shielded terminal cannot be given work" {
    var b = try testBus(testing.allocator);
    defer b.deinit();
    try b.register(other);
    try b.setShielded(other, true, .user);

    var panel: Tasks = .init(testing.allocator, .{});
    defer panel.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fake = panelFixture(&panel);

    const id = try panel.create("build", "one");
    const res = try dispatch(alloc, &b, fake.host(), term(boss), .{ .task_assign = .{
        .task = id,
        .id = other,
    } });
    try testing.expectEqualStrings("Shielded", res.failed.code);
}

test "no panel tool is a plugin's" {
    var b = try testBus(testing.allocator);
    defer b.deinit();

    for ([_]Method{
        .task_create,
        .task_assign,
        .task_close,
        .task_cancel,
        .task_progress,
        .task_list,
    }) |m| {
        try testing.expect(!callableByPlugin(m));
    }

    // And declaring it changes nothing: the declaration can only ever
    // narrow.
    try testing.expectError(error.NotPermitted, authorize(
        &b,
        plug(&.{"task_create"}),
        .{ .task_create = .{ .group = "build", .title = "one" } },
    ));
    try testing.expectError(error.NotATerminal, authorize(
        &b,
        plug(&.{"task_list"}),
        .{ .task_list = .{ .group = "build" } },
    ));
}

test "the whole life of a task, as it goes over the wire" {
    // Every other panel test builds a `Request` by hand. This one starts
    // from the JSON an agent's sidecar actually sends and ends at the JSON
    // it gets back, because the two ends are where the mistakes that unit
    // tests cannot see live: a parameter the parser does not know is
    // dropped silently, and a reply field nobody writes is a reply the
    // agent reads as absent rather than as zero.
    var b = try testBus(testing.allocator);
    defer b.deinit();
    var panel: Tasks = .init(testing.allocator, .{});
    defer panel.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fake = panelFixture(&panel);

    const Step = struct {
        who: Bus.Id,
        line: []const u8,
        want: []const u8,
    };

    for ([_]Step{
        // The supervisor makes it.
        .{
            .who = boss,
            .line =
            \\{"method":"task_create","params":{"group":"build","title":"get the core building"}}
            ,
            .want = "\"task\":1",
        },

        // ...and hands it out.
        .{
            .who = boss,
            .line =
            \\{"method":"task_assign","params":{"task":1,"id":"0x2222"}}
            ,
            .want = "\"ok\":true",
        },

        // The worker finds it, and finds only it.
        .{
            .who = worker,
            .line =
            \\{"method":"task_list","params":{"group":"build"}}
            ,
            .want = "get the core building",
        },

        // ...says where it has got to...
        .{
            .who = worker,
            .line =
            \\{"method":"task_progress","params":{"task":1,"progress":"working"}}
            ,
            .want = "\"ok\":true",
        },

        // ...and reports.
        .{
            .who = worker,
            .line =
            \\{"method":"group_post","params":{"group":"build","text":"task 1: core builds"}}
            ,
            .want = "\"ok\":true",
        },

        // The supervisor checks and closes.
        .{
            .who = boss,
            .line =
            \\{"method":"task_close","params":{"task":1}}
            ,
            .want = "\"ok\":true",
        },
    }) |step| {
        var parsed = try wire.parseRequest(alloc, step.line);
        defer parsed.deinit();

        const res = try dispatch(alloc, &b, fake.host(), term(step.who), parsed.value);

        var out: std.Io.Writer.Allocating = .init(alloc);
        try wire.writeResponse(&out.writer, res);

        if (std.mem.indexOf(u8, out.written(), step.want) == null) {
            std.debug.print("\n{s}\n  ->{s}", .{ step.line, out.written() });
            return error.TestUnexpectedResult;
        }
    }

    // Closed: gone from the worker, still on the panel for the person.
    {
        var parsed = try wire.parseRequest(alloc,
            \\{"method":"task_list","params":{"group":"build"}}
        );
        defer parsed.deinit();

        const mine = try dispatch(alloc, &b, fake.host(), term(worker), parsed.value);
        try testing.expectEqual(@as(usize, 0), mine.tasks.len);

        const all = try dispatch(alloc, &b, fake.host(), term(Chat.user_id), parsed.value);
        try testing.expectEqual(@as(usize, 1), all.tasks.len);
        try testing.expectEqualStrings("closed", all.tasks[0].state);
        try testing.expectEqualStrings("working", all.tasks[0].progress);
    }
}

test "a misspelled panel parameter is a mistake, not a different call" {
    // The guard `set_watch` cost us: a key the method does not know used to
    // be dropped and the reply said `ok`. Every one of these would
    // otherwise fall back to a default and do something the caller did not
    // ask for -- `task` missing is task zero, `progress` missing is no
    // change at all.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    for ([_][]const u8{
        \\{"method":"task_create","params":{"group":"build","titel":"typo"}}
        ,
        \\{"method":"task_assign","params":{"task":1,"terminal":"0x2222"}}
        ,
        \\{"method":"task_progress","params":{"task":1,"state":"working"}}
        ,
        \\{"method":"task_list","params":{"grp":"build"}}
        ,
        \\{"method":"task_cancel","params":{}}
        ,
    }) |line| {
        try testing.expectError(error.BadParams, wire.parseRequest(alloc, line));
    }
}
