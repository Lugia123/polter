//! What a terminal, and a group, wants from the person: the one place that
//! decides it.
//!
//! Every number and every order the control room shows -- "N waiting for
//! you", which row is on top, which glyph a tab carries -- comes out of the
//! functions here. A host that compares kinds or counts rows itself is a
//! defect (dev-docs/poltergeist/control-room.md, 4.3 and 5.4).
//!
//! **Pure.** Nothing here reads a clock, a screen, or the bus. The caller
//! hands in what the machine knows (`Facts`) and the time, and gets back
//! plain values with no pointers in them, so the next piece -- the snapshot
//! and its change notice -- can copy them out as they are.
//!
//! **No field has a default.** A caller that forgets one gets a compile
//! error naming it; the written-out constants (`Facts.none`,
//! `Thresholds.defaults`, `Snooze.none`) are what to start from.
//!
//! The value of this type is a group's attention; `Status` is one
//! terminal's.

const Attention = @This();

const std = @import("std");
const i18n = @import("../os/i18n.zig");
const Bus = @import("Bus.zig");
const Sampler = @import("Sampler.zig");

pub const Id = Bus.Id;

/// What it comes to, after bubbling and snoozing.
kind: Kind,

/// What it would be if nobody had snoozed it. The same as `kind` unless
/// `kind` is `snoozed`.
under: Kind,

/// When it entered `under`. Pressing it again does not move this.
since_ms: u64,

/// Whose state this is.
what: What,

source: Source,

/// How old the evidence is, or null when there is none to age.
age_ms: ?u64,

/// The terminal this is about, which is what "N waiting" counts. Null when
/// no terminal is behind it.
terminal: ?Id,

/// The nine kinds of 4.3, in its order, and `snoozed` after them. The
/// integer is the sort rank.
pub const Kind = enum(u8) {
    needs_approval = 1,
    needs_answer = 2,
    failed = 3,
    suspect_stuck = 4,
    done_unseen = 5,
    quiet_unknown = 6,
    working = 7,
    idle = 8,
    unattended = 9,
    snoozed = 10,

    /// Cannot move until the person does something.
    pub fn needsMe(self: Kind) bool {
        return switch (self) {
            .needs_approval, .needs_answer, .failed, .suspect_stuck => true,
            .done_unseen, .quiet_unknown, .working, .idle, .unattended, .snoozed => false,
        };
    }

    /// Stopped, and not looked at yet. Listed, never counted or notified.
    pub fn unseen(self: Kind) bool {
        return switch (self) {
            .done_unseen, .quiet_unknown => true,
            .needs_approval, .needs_answer, .failed, .suspect_stuck => false,
            .working, .idle, .unattended, .snoozed => false,
        };
    }
};

pub const What = union(enum) {
    /// The supervisor's own state, or a lone terminal's.
    own,
    /// A worker's, bubbled up; the id says which.
    worker: Id,
    /// Nobody alive is behind it.
    nobody,
};

/// Which signal decided the kind.
pub const Source = enum {
    hook,
    /// The terminal's title, as its plugin declared (task 1656): a CLI with
    /// no hooks that says in its title that it is waiting.
    title,
    /// Hooks were configured and never spoke.
    hook_missing,
    screen,
    /// The sampler failed: the kind was decided without a screen reading.
    screen_unreadable,
    process,
    /// Its agent left the terminal and nothing has come back (task 1762):
    /// whatever its hooks last said no longer holds, and neither does
    /// anything the screen says -- a shell is drawing there now.
    agent_left,
    self_report,
    off_duty,
    none,
};

/// What is known of the screen. Three answers, because "nobody is measuring"
/// and "the measuring failed" are both different from any number.
pub const Screen = union(enum) {
    unmeasured,
    /// Sampling failed, since when.
    unreadable: u64,
    /// Unchanged for this long.
    still_ms: u64,

    /// From what the bus keeps: `Bus.samplingOf`, `Bus.quietMs`, and when
    /// the sampling was found to have failed.
    pub fn of(sampling: ?Bus.Sampling, quiet_ms: u64, failed_since_ms: u64) Screen {
        const s = sampling orelse return .unmeasured;
        return switch (s) {
            .starting => .unmeasured,
            .running => .{ .still_ms = quiet_ms },
            .failed => .{ .unreadable = failed_since_ms },
        };
    }
};

pub const Process = union(enum) {
    running,
    /// The agent went away on its own and left the terminal; when.
    agent_exited: u64,
    /// The agent is no longer there, since when, and nothing says whether
    /// it failed or the person closed it. Not a failure: what its hooks
    /// last said no longer holds, and the screen is what is left to read.
    agent_left: u64,
    /// The terminal itself is gone, or the user closed the agent.
    gone,
};

/// T1, T2 and the two fixed waits. Taken from the configuration that
/// already exists; there is no second set.
pub const Thresholds = struct {
    /// T1: `poltergeist-quiescence-after`.
    screen_still_ms: u64,
    /// T2: `poltergeist-calls-silent-after`. Zero switches that clock off.
    calls_silent_ms: u64,
    hooks_expected_ms: u64,
    /// How long a worker may wait on its supervisor before the group shows it.
    bubble_after_ms: u64,

    pub const defaults: Thresholds = from(.{}, .{});

    pub fn from(sampler: Sampler.Config, bus: Bus.Config) Thresholds {
        return .{
            .screen_still_ms = sampler.quiescence_ms,
            .calls_silent_ms = bus.calls_silent_after_ms,
            .hooks_expected_ms = Bus.hooks_expected_timeout_ms,
            .bubble_after_ms = 60 * std.time.ms_per_s,
        };
    }
};

/// What the machine knows about one terminal.
pub const Facts = struct {
    id: Id,
    hooks: Bus.Hooks,
    state: Bus.AgentState,
    /// Whether `state` came from the hooks or from the title.
    said_by: Bus.SaidBy,
    /// When `state` last changed.
    state_since_ms: u64,
    /// When the wait for the hooks began, or null while it has not
    /// (`Bus.Agent.expected_ms`).
    expected_ms: ?u64,
    /// When a hook event last arrived, if that is recorded.
    last_event_ms: ?u64,
    waiting_on_background: bool,
    screen: Screen,
    /// Null when the terminal has never called a Polter tool.
    call_silent_ms: ?u64,
    process: Process,
    duty: Bus.Duty,
    /// When the person last looked, or null if never.
    seen_ms: ?u64,
    /// When the agent last said, in its own report, that it needs an answer.
    raised_ms: ?u64,
    /// Whether a supervisor may answer this terminal's permission prompt
    /// (`Bus.answer`). It decides whose a prompt is in its first minute
    /// (`ofGroup`).
    answer: Bus.Answer,
    held: bool,
    shielded: bool,

    /// What the bus does not keep, and whoever asks it for `Facts` supplies.
    pub const Outside = struct {
        process: Process,
        seen_ms: ?u64,
        raised_ms: ?u64,

        pub const none: Outside = .{ .process = .running, .seen_ms = null, .raised_ms = null };
    };

    /// A plain terminal nothing is known about.
    pub const none: Facts = .{
        .id = 0,
        .hooks = .none,
        .state = .idle,
        .said_by = .hooks,
        .state_since_ms = 0,
        .expected_ms = 0,
        .last_event_ms = null,
        .waiting_on_background = false,
        .screen = .unmeasured,
        .call_silent_ms = null,
        .process = .running,
        .duty = .on,
        .seen_ms = null,
        .raised_ms = null,
        .answer = .allowed,
        .held = false,
        .shielded = false,
    };
};

/// One terminal's kind, and what it carries along untouched.
pub const Status = struct {
    id: Id,
    kind: Kind,
    since_ms: u64,
    source: Source,
    age_ms: ?u64,
    /// Carried so that "could not read the screen" is drawn rather than
    /// dropped.
    screen: Screen,
    /// Whether the terminal is still there.
    alive: bool,
    duty: Bus.Duty,
    /// Whether a supervisor may answer this terminal's prompt.
    answer: Bus.Answer,
    /// Modifiers. They take no part in any merging here.
    held: bool,
    shielded: bool,
};

pub fn classify(f: Facts, t: Thresholds, now_ms: u64) Status {
    const Core = struct { kind: Kind, since_ms: u64, source: Source, age_ms: ?u64 };
    const hook_age = now_ms -| (f.last_event_ms orelse f.state_since_ms);

    var c: Core = decided: {
        // A process that is gone overrules whatever the hooks last said.
        switch (f.process) {
            .running => {},
            // **Said as what it is** (task 1762), never worked out from the
            // screen: a shell drawing where an agent was is not an agent
            // working, nor one stuck. Listed for the person until they have
            // looked, then nothing more.
            .agent_left => |at| break :decided .{
                .kind = if (seenSince(f.seen_ms, at)) .idle else .quiet_unknown,
                .since_ms = at,
                .source = .agent_left,
                .age_ms = now_ms -| at,
            },
            .agent_exited => |at| break :decided .{
                .kind = .failed,
                .since_ms = at,
                .source = .process,
                .age_ms = now_ms -| at,
            },
            .gone => break :decided .{
                .kind = .idle,
                .since_ms = f.state_since_ms,
                .source = .process,
                .age_ms = null,
            },
        }

        if (Bus.Agent.spoke(f.hooks, f.said_by) and f.process == .running) {
            const kind: Kind, const since: u64 = switch (f.state) {
                .awaiting_approval => .{ .needs_approval, f.state_since_ms },
                .awaiting_input => .{ .needs_answer, f.state_since_ms },
                .failed => .{ .failed, f.state_since_ms },
                // Working, for as long as a screen may be still before it
                // is asked about; past that, the same "stuck?" -- a retry
                // nobody ends goes on for ever (task 1777, #734).
                .retrying => if (now_ms -| f.state_since_ms >= t.screen_still_ms)
                    .{ .suspect_stuck, f.state_since_ms +| t.screen_still_ms }
                else
                    .{ .working, f.state_since_ms },
                .in_turn => if (stuckSince(f, t, now_ms)) |at|
                    .{ .suspect_stuck, at }
                else
                    .{ .working, f.state_since_ms },
                .ended => if (f.waiting_on_background)
                    .{ .working, f.state_since_ms }
                else if (seenSince(f.seen_ms, f.state_since_ms))
                    .{ .idle, f.state_since_ms }
                else
                    .{ .done_unseen, f.state_since_ms },
                .idle => .{ .idle, f.state_since_ms },
            };
            const source: Source = if (f.hooks == .live) .hook else .title;
            break :decided .{ .kind = kind, .since_ms = since, .source = source, .age_ms = hook_age };
        }

        if (f.hooks == .expected and f.process == .running) {
            if (f.expected_ms) |began| if (now_ms -| began >= t.hooks_expected_ms) break :decided .{
                .kind = .suspect_stuck,
                .since_ms = began +| t.hooks_expected_ms,
                .source = .hook_missing,
                .age_ms = now_ms -| began,
            };
            // Started with hooks that have not spoken yet: at its prompt,
            // not at work. Its screen moves while it starts and draws, and
            // read by the screen it was drawn as working (c1669-04); a
            // turn would have said so through those hooks.
            break :decided .{
                .kind = .idle,
                .since_ms = f.state_since_ms,
                .source = .none,
                .age_ms = null,
            };
        }

        // No hooks to go on: the screen is all there is.
        switch (f.screen) {
            .unmeasured => break :decided .{
                .kind = .idle,
                .since_ms = f.state_since_ms,
                .source = .none,
                .age_ms = null,
            },
            // Not a reading, so neither "still" nor "idle" may be said of
            // it. It goes where the person will look.
            .unreadable => |at| break :decided .{
                .kind = .quiet_unknown,
                .since_ms = at,
                .source = .screen_unreadable,
                .age_ms = null,
            },
            .still_ms => |still| {
                const stopped_ms = now_ms -| still;
                const kind: Kind = if (still < t.screen_still_ms)
                    .working
                else if (seenSince(f.seen_ms, stopped_ms))
                    .idle
                else
                    .quiet_unknown;
                break :decided .{
                    .kind = kind,
                    .since_ms = if (kind == .working) stopped_ms else stopped_ms +| t.screen_still_ms,
                    .source = .screen,
                    .age_ms = 0,
                };
            },
        }
    };

    // The agent's own report may raise, never lower, and never rename an
    // approval or a failure. It lapses when the state it was said in ends.
    if (f.raised_ms) |at| {
        const may = switch (c.kind) {
            .needs_approval, .needs_answer, .failed => false,
            .suspect_stuck, .done_unseen, .quiet_unknown, .working, .idle => true,
            .unattended, .snoozed => false,
        };
        if (may and f.process == .running and at >= f.state_since_ms) c = .{
            .kind = .needs_answer,
            .since_ms = at,
            .source = .self_report,
            .age_ms = now_ms -| at,
        };
    }

    return .{
        .id = f.id,
        .kind = c.kind,
        .since_ms = c.since_ms,
        .source = c.source,
        .age_ms = c.age_ms,
        .screen = f.screen,
        .alive = f.process != .gone,
        .duty = f.duty,
        .answer = f.answer,
        .held = f.held,
        .shielded = f.shielded,
    };
}

fn seenSince(seen_ms: ?u64, at_ms: u64) bool {
    const seen = seen_ms orelse return false;
    return seen >= at_ms;
}

/// When an agent in a turn became suspect, or null if it is not: the screen
/// still for T1 and no tool call for T2. A clock that says nothing -- T2
/// set to zero, or a terminal that has never called a tool -- has no vote,
/// and the screen decides alone. A screen that could not be read is not a
/// still screen.
fn stuckSince(f: Facts, t: Thresholds, now_ms: u64) ?u64 {
    const still = switch (f.screen) {
        .still_ms => |ms| ms,
        .unmeasured, .unreadable => return null,
    };
    if (still < t.screen_still_ms) return null;
    var at = (now_ms -| still) +| t.screen_still_ms;

    if (t.calls_silent_ms != 0) if (f.call_silent_ms) |silent| {
        if (silent < t.calls_silent_ms) return null;
        at = @max(at, (now_ms -| silent) +| t.calls_silent_ms);
    };

    return @max(at, f.state_since_ms);
}

/// The next moment `classify` could answer differently with no event in
/// between -- a threshold being crossed -- or null when only an event can
/// change it. What lets the caller sleep until then instead of polling.
pub fn nextChange(f: Facts, t: Thresholds, now_ms: u64) ?u64 {
    const at: u64 = at: {
        switch (f.process) {
            .running => {},
            // Only an event changes it: the person looking, or an agent.
            .agent_left, .agent_exited, .gone => return null,
        }
        if (Bus.Agent.spoke(f.hooks, f.said_by)) {
            if (f.state == .retrying) break :at f.state_since_ms +| t.screen_still_ms;
            if (f.state != .in_turn) return null;
            var at = stillAt(f, t, now_ms) orelse return null;
            if (t.calls_silent_ms != 0) if (f.call_silent_ms) |silent| {
                at = @max(at, (now_ms -| silent) +| t.calls_silent_ms);
            };
            break :at @max(at, f.state_since_ms);
        }
        if (f.hooks == .expected) {
            // A wait that has not begun ends by a line being typed, not
            // by the clock.
            const began = f.expected_ms orelse return null;
            const due = began +| t.hooks_expected_ms;
            if (due > now_ms) break :at due;
            return null;
        }
        break :at stillAt(f, t, now_ms) orelse return null;
    };
    return if (at > now_ms) at else null;
}

/// When a measured screen will have been still for T1.
fn stillAt(f: Facts, t: Thresholds, now_ms: u64) ?u64 {
    return switch (f.screen) {
        .still_ms => |ms| (now_ms -| ms) +| t.screen_still_ms,
        .unmeasured, .unreadable => null,
    };
}

/// "Known, leave it": until the state changes again, or until a time.
pub const Snooze = union(enum) {
    none,
    /// Set at this time; ends when the state changes after it.
    until_change: u64,
    until_ms: u64,

    fn holds(self: Snooze, since_ms: u64, now_ms: u64) bool {
        return switch (self) {
            .none => false,
            .until_change => |at| since_ms <= at,
            .until_ms => |until| now_ms < until,
        };
    }
};

pub const Group = struct {
    /// Null when the group has no supervisor.
    steward: ?Status,
    workers: []const Status,
    snooze: Snooze,
    /// When the group last had anything happen; the `since_ms` of a group
    /// nobody is in.
    last_ms: u64,
};

/// A terminal standing on its own (4.6), in the same terms as a group.
pub fn ofTerminal(s: Status) Attention {
    // Off duty is in no count, whatever it was doing when it clocked off.
    if (s.duty == .off) return .{
        .kind = .idle,
        .under = .idle,
        .since_ms = s.since_ms,
        .what = .own,
        .source = .off_duty,
        .age_ms = null,
        .terminal = s.id,
    };
    return .{
        .kind = s.kind,
        .under = s.kind,
        .since_ms = s.since_ms,
        .what = .own,
        .source = s.source,
        .age_ms = s.age_ms,
        .terminal = s.id,
    };
}

pub fn ofGroup(g: Group, t: Thresholds, now_ms: u64) Attention {
    var any_alive = false;
    var best: ?Attention = null;
    // Whether there is a supervisor to give a worker's first minute to.
    var minded = false;

    if (g.steward) |s| {
        if (s.alive) {
            any_alive = true;
            minded = s.duty == .on;
            best = ofTerminal(s);
        }
    }

    for (g.workers) |w| {
        if (!w.alive) continue;
        any_alive = true;
        if (w.duty == .off) continue;
        switch (w.kind) {
            .needs_approval, .failed => {},
            else => continue,
        }
        // The supervisor gets the first minute to deal with it -- when
        // there is something it can do. A prompt it may not answer (the
        // person switched that off, or shielded the terminal) is the
        // person's from the first second: a minute spent waiting for
        // somebody who is not allowed to act is a minute of nothing.
        //
        // And when there is somebody to give it to: a group with no
        // supervisor, or one whose supervisor has gone or clocked off, has
        // nobody who would use the minute (the user's ruling, 2026-10-13).
        if (minded and firstMinuteIsTheSupervisors(w) and now_ms -| w.since_ms <= t.bubble_after_ms) continue;

        var a = ofTerminal(w);
        a.what = .{ .worker = w.id };
        if (best) |b| {
            if (before(a, b)) best = a;
        } else best = a;
    }

    var a = best orelse if (any_alive) Attention{
        // Workers and no supervisor, and none of them stuck on one.
        .kind = .idle,
        .under = .idle,
        .since_ms = g.last_ms,
        .what = .nobody,
        .source = .none,
        .age_ms = null,
        .terminal = null,
    } else return .{
        .kind = .unattended,
        .under = .unattended,
        .since_ms = g.last_ms,
        .what = .nobody,
        .source = .none,
        .age_ms = null,
        .terminal = null,
    };

    if (g.snooze.holds(a.since_ms, now_ms)) a.kind = .snoozed;
    return a;
}

/// Whether a worker's trouble is its supervisor's to deal with before it is
/// shown to the person. A failure always is. A permission prompt is when
/// the supervisor may answer it.
pub fn firstMinuteIsTheSupervisors(w: Status) bool {
    return switch (w.kind) {
        .needs_approval => switch (w.answer) {
            .allowed => true,
            .off, .shielded => false,
        },
        .needs_answer, .failed, .suspect_stuck, .done_unseen, .quiet_unknown, .working, .idle, .unattended, .snoozed => true,
    };
}

pub fn needsMe(a: Attention) bool {
    return a.kind.needsMe();
}

pub fn unseen(a: Attention) bool {
    return a.kind.unseen();
}

/// The sort key: kind first, then longest-waiting first. The terminal id
/// settles a tie so that two rows never trade places on their own.
pub fn before(a: Attention, b: Attention) bool {
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    if (a.since_ms != b.since_ms) return a.since_ms < b.since_ms;
    return (a.terminal orelse std.math.maxInt(Id)) < (b.terminal orelse std.math.maxInt(Id));
}

pub fn sort(items: []Attention) void {
    std.mem.sort(Attention, items, {}, struct {
        fn lt(_: void, a: Attention, b: Attention) bool {
            return before(a, b);
        }
    }.lt);
}

/// The terminals behind the rows that need the person, each counted once:
/// one supervisor minding three groups is one (4.4).
///
/// **Not the number the person is shown.** The control room's `needs_me`
/// counted this way until a real window showed four rows and a 3 on the
/// Dock; it now counts rows (`ControlRoom.build`). This stays for whoever
/// wants "how many terminals" -- a notification that must not fire three
/// times for one supervisor.
pub fn needsMeCount(rows: []const Attention) usize {
    var n: usize = 0;
    for (rows, 0..) |a, i| {
        if (!needsMe(a)) continue;
        const counted = for (rows[0..i]) |prev| {
            if (!needsMe(prev)) continue;
            if (sameTerminal(prev, a)) break true;
        } else false;
        if (!counted) n += 1;
    }
    return n;
}

fn sameTerminal(a: Attention, b: Attention) bool {
    const x = a.terminal orelse return false;
    const y = b.terminal orelse return false;
    return x == y;
}

/// The four things the person is shown, highest first, and nothing.
pub const Shown = enum(u8) {
    needs_you = 0,
    trouble = 1,
    done_unseen = 2,
    working = 3,
    none = 4,
};

/// The words beside the glyph, which say which one it is.
pub const Word = enum {
    needs_approval,
    needs_answer,
    failed,
    suspect_stuck,
    done_unseen,
    working,
    quiet_unknown,
    screen_unreadable,
    agent_left,
    unattended,
    snoozed,
    off_duty,
    none,

    /// The words, **in English, as the msgid both hosts translate** (task
    /// 1522): the mac app in `Localizable.strings`, Windows in `po/`, the
    /// same way as the settings form's labels. They were Chinese literals,
    /// and so were Chinese in an English window on both hosts -- the core
    /// does not know the person's language, so it cannot pick the words in
    /// it; it can only say which words, and let the host say them.
    /// `tools/control-room-words-are-translated.py` checks that each one
    /// has a translation on both hosts.
    pub fn text(self: Word) [:0]const u8 {
        return switch (self) {
            .needs_approval => i18n.N_("Awaiting approval"),
            .needs_answer => i18n.N_("Awaiting input"),
            .failed => i18n.N_("Failed"),
            .suspect_stuck => i18n.N_("Maybe stuck"),
            .done_unseen => i18n.N_("Done, not looked at"),
            .working => i18n.N_("Working"),
            .quiet_unknown => i18n.N_("Stopped, cause unknown"), // 暂定
            .screen_unreadable => i18n.N_("Screen unreadable"), // 暂定
            .agent_left => i18n.N_("Agent left"),
            .unattended => i18n.N_("Unattended"), // 暂定
            .snoozed => i18n.N_("Set aside"), // 暂定
            .off_duty => i18n.N_("Off duty"), // 暂定
            .none => "",
        };
    }
};

/// What a pane's title says when its terminal is held and nobody is waiting
/// on it (`ControlRoom.Bar`). Here with the other words so that one file
/// holds every word the control room draws, for the translators and for
/// the check that each one has been translated.
pub const held_text = i18n.N_("Held");

pub const Display = struct {
    shown: Shown,
    word: Word,
};

/// The merge table of 3.5 item 2: the one place a kind becomes something
/// drawn. Rows marked 暂定 are the supervisor's stand-in for what the
/// design has not settled; change them here and nowhere else.
pub fn displayOf(kind: Kind) Display {
    return switch (kind) {
        .needs_approval => .{ .shown = .needs_you, .word = .needs_approval },
        .needs_answer => .{ .shown = .needs_you, .word = .needs_answer },
        .failed => .{ .shown = .trouble, .word = .failed },
        .suspect_stuck => .{ .shown = .trouble, .word = .suspect_stuck },
        .done_unseen => .{ .shown = .done_unseen, .word = .done_unseen },
        .quiet_unknown => .{ .shown = .done_unseen, .word = .quiet_unknown }, // 暂定
        .working => .{ .shown = .working, .word = .working },
        .idle => .{ .shown = .none, .word = .none },
        .unattended => .{ .shown = .none, .word = .unattended }, // 暂定
        .snoozed => .{ .shown = .none, .word = .snoozed }, // 暂定
    };
}

/// One terminal, as drawn. Held and shielded are not in here: they are
/// modifiers, and stay on the `Status`.
pub fn display(s: Status) Display {
    if (s.duty == .off) return .{ .shown = .none, .word = .off_duty }; // 暂定
    var d = displayOf(s.kind);
    if (s.source == .screen_unreadable) d.word = .screen_unreadable; // 暂定
    // Seen or not, it says what happened (task 1762).
    if (s.source == .agent_left) d.word = .agent_left;
    return d;
}

/// Where a single glyph stands for several terminals.
pub const Place = enum {
    /// A window tab. 暂定: no spinner here, so that every glyph in a row of
    /// tabs is one worth a look.
    window_tab,
    elsewhere,

    fn drawsWorking(self: Place) bool {
        return switch (self) {
            .window_tab => false,
            .elsewhere => true,
        };
    }
};

pub const Top = struct {
    shown: Shown,
    /// Which of the terminals it was; the longest-waiting of the highest.
    index: ?usize,

    pub const none: Top = .{ .shown = .none, .index = null };
};

/// The one glyph for a set of terminals -- everything in a window tab,
/// everything in a stack: the highest of them.
pub fn top(statuses: []const Status, place: Place) Top {
    var best: Top = .none;
    var best_since: u64 = 0;
    for (statuses, 0..) |s, i| {
        const shown = display(s).shown;
        if (shown == .none) continue;
        if (shown == .working and !place.drawsWorking()) continue;
        const higher = @intFromEnum(shown) < @intFromEnum(best.shown);
        const older = shown == best.shown and s.since_ms < best_since;
        if (higher or older) {
            best = .{ .shown = shown, .index = i };
            best_since = s.since_ms;
        }
    }
    return best;
}

const testing = std.testing;
const T = Thresholds.defaults;
const min = std.time.ms_per_min;
const now: u64 = 100 * min;

fn hooked(id: Id, state: Bus.AgentState, since_ms: u64) Facts {
    var f: Facts = .none;
    f.id = id;
    f.hooks = .live;
    f.state = state;
    f.state_since_ms = since_ms;
    return f;
}

fn status(id: Id, state: Bus.AgentState, since_ms: u64) Status {
    return classify(hooked(id, state, since_ms), T, now);
}

test "Attention: the thresholds are the configured ones" {
    try testing.expectEqual(@as(u64, 3 * min), T.screen_still_ms);
    try testing.expectEqual(@as(u64, 15 * min), T.calls_silent_ms);
    try testing.expectEqual(Bus.hooks_expected_timeout_ms, T.hooks_expected_ms);
    const custom = Thresholds.from(.{ .quiescence_ms = 7 }, .{ .calls_silent_after_ms = 9 });
    try testing.expectEqual(@as(u64, 7), custom.screen_still_ms);
    try testing.expectEqual(@as(u64, 9), custom.calls_silent_ms);
}

test "Attention: a hook state decides approval, answer and failure" {
    const approval = status(1, .awaiting_approval, 40 * min);
    try testing.expectEqual(Kind.needs_approval, approval.kind);
    try testing.expectEqual(@as(u64, 40 * min), approval.since_ms);
    try testing.expectEqual(Source.hook, approval.source);
    try testing.expectEqual(@as(?u64, 60 * min), approval.age_ms);
    try testing.expectEqual(Kind.needs_answer, status(1, .awaiting_input, 0).kind);
    try testing.expectEqual(Kind.failed, status(1, .failed, 0).kind);
}

test "Attention: the age is read off the last event, not the last change" {
    var f = hooked(1, .in_turn, 40 * min);
    f.last_event_ms = 99 * min;
    try testing.expectEqual(@as(?u64, 1 * min), classify(f, T, now).age_ms);
}

test "Attention: an agent that exited is a failure whatever its hooks last said" {
    var f = hooked(1, .in_turn, 40 * min);
    f.process = .{ .agent_exited = 90 * min };
    const s = classify(f, T, now);
    try testing.expectEqual(Kind.failed, s.kind);
    try testing.expectEqual(Source.process, s.source);
    try testing.expectEqual(@as(u64, 90 * min), s.since_ms);
    try testing.expect(s.alive);

    f.process = .gone;
    const gone = classify(f, T, now);
    try testing.expectEqual(Kind.idle, gone.kind);
    try testing.expect(!gone.alive);
}

test "Attention: an agent that left for no known reason is not called a failure" {
    var f = hooked(1, .awaiting_approval, 40 * min);
    f.process = .{ .agent_left = 90 * min };
    // The approval it was waiting on went with it.
    const s = classify(f, T, now);
    try testing.expect(s.kind != .failed and s.kind != .needs_approval);
    try testing.expectEqual(Source.agent_left, s.source);
    try testing.expect(s.alive);
}

test "1762: an agent that left is said to have left, whatever its hooks or its screen say" {
    // In the middle of a turn when it went, the case that read "Working"
    // for good.
    var f = hooked(1, .in_turn, 40 * min);
    f.process = .{ .agent_left = 90 * min };
    // A shell drawing, a still screen, no tool call for an hour: none of it
    // is an agent working or stuck.
    for ([_]Screen{ .unmeasured, .{ .still_ms = 0 }, .{ .still_ms = 1 * min }, .{ .still_ms = 60 * min } }) |screen| {
        f.screen = screen;
        f.call_silent_ms = 60 * min;
        const s = classify(f, T, now);
        try testing.expectEqual(Kind.quiet_unknown, s.kind);
        try testing.expectEqual(Source.agent_left, s.source);
        try testing.expectEqual(@as(u64, 90 * min), s.since_ms);
        const d = display(s);
        try testing.expectEqual(Word.agent_left, d.word);
    }
    // Looked at since it went: nothing more to say but what happened.
    f.seen_ms = 91 * min;
    const seen = classify(f, T, now);
    try testing.expectEqual(Kind.idle, seen.kind);
    try testing.expectEqual(Word.agent_left, display(seen).word);
    try testing.expectEqualStrings("Agent left", display(seen).word.text());
    // And only an event changes it.
    try testing.expectEqual(@as(?u64, null), nextChange(f, T, now));
}

/// The same facts `dt` later, with no event in between.
fn later(f: Facts, dt: u64) Facts {
    var out = f;
    switch (out.screen) {
        .still_ms => |*ms| ms.* += dt,
        .unmeasured, .unreadable => {},
    }
    if (out.call_silent_ms) |*ms| ms.* += dt;
    return out;
}

test "Attention: the next change is the threshold, and nothing changes before it" {
    var turn = hooked(1, .in_turn, 90 * min);
    turn.screen = .{ .still_ms = 1 * min };
    turn.call_silent_ms = 5 * min;

    var plain: Facts = .none;
    plain.screen = .{ .still_ms = 1 * min };

    var promised: Facts = .none;
    promised.hooks = .expected;
    promised.expected_ms = now - 1000;

    const cases = [_]struct { Facts, u64 }{
        .{ turn, now + 10 * min }, // T2 is the later of the two clocks
        .{ plain, now + 2 * min },
        .{ promised, now - 1000 + Bus.hooks_expected_timeout_ms },
    };
    for (cases) |c| {
        const f, const want = c;
        const at = nextChange(f, T, now) orelse return error.TestExpectedAWake;
        try testing.expectEqual(want, at);
        const before_it = classify(later(f, at - 1 - now), T, at - 1);
        const at_it = classify(later(f, at - now), T, at);
        try testing.expectEqual(classify(f, T, now).kind, before_it.kind);
        try testing.expect(at_it.kind != before_it.kind);
        // And once crossed there is nothing further to wait for.
        try testing.expectEqual(@as(?u64, null), nextChange(later(f, at - now), T, at));
    }
}

test "Attention: what only an event can change has no next change" {
    try testing.expectEqual(@as(?u64, null), nextChange(Facts.none, T, now));
    try testing.expectEqual(@as(?u64, null), nextChange(hooked(1, .awaiting_approval, 0), T, now));
    try testing.expectEqual(@as(?u64, null), nextChange(hooked(1, .ended, 0), T, now));
    // In a turn with nothing measuring the screen: no clock to cross.
    try testing.expectEqual(@as(?u64, null), nextChange(hooked(1, .in_turn, 0), T, now));
    var dead = hooked(1, .in_turn, 0);
    dead.screen = .{ .still_ms = 0 };
    dead.process = .gone;
    try testing.expectEqual(@as(?u64, null), nextChange(dead, T, now));
}

test "Attention: in a turn, still for T1 and silent for T2, is suspect" {
    var f = hooked(1, .in_turn, 10 * min);
    f.screen = .{ .still_ms = 20 * min };
    f.call_silent_ms = 30 * min;
    const s = classify(f, T, now);
    try testing.expectEqual(Kind.suspect_stuck, s.kind);
    // Still since 80, so past T1 at 83; silent since 70, so past T2 at 85.
    try testing.expectEqual(@as(u64, 85 * min), s.since_ms);

    // Either clock short of its threshold, and it is working.
    f.call_silent_ms = 14 * min;
    try testing.expectEqual(Kind.working, classify(f, T, now).kind);
    f.call_silent_ms = 30 * min;
    f.screen = .{ .still_ms = 2 * min };
    try testing.expectEqual(Kind.working, classify(f, T, now).kind);
}

test "Attention: a call clock that says nothing leaves it to the screen" {
    var f = hooked(1, .in_turn, 10 * min);
    f.screen = .{ .still_ms = 20 * min };
    f.call_silent_ms = null;
    try testing.expectEqual(Kind.suspect_stuck, classify(f, T, now).kind);

    var off = T;
    off.calls_silent_ms = 0;
    f.call_silent_ms = 1;
    try testing.expectEqual(Kind.suspect_stuck, classify(f, off, now).kind);
}

test "Attention: hooks that were promised and never came are suspect" {
    var f: Facts = .none;
    f.hooks = .expected;
    f.expected_ms = 50 * min;
    const s = classify(f, T, now);
    try testing.expectEqual(Kind.suspect_stuck, s.kind);
    try testing.expectEqual(Source.hook_missing, s.source);
    try testing.expectEqual(50 * min + Bus.hooks_expected_timeout_ms, s.since_ms);

    f.expected_ms = now - 1000;
    try testing.expectEqual(Kind.idle, classify(f, T, now).kind);
}

test "1668: hooks whose wait has not begun are not suspect, and no clock will make them" {
    var f: Facts = .none;
    f.hooks = .expected;
    f.expected_ms = null;
    try testing.expect(classify(f, T, now).kind != .suspect_stuck);
    try testing.expect(nextChange(f, T, now) == null);

    // Once a line has started it, it is the wait it always was.
    f.expected_ms = 50 * min;
    try testing.expectEqual(Kind.suspect_stuck, classify(f, T, now).kind);
}

test "1668: an agent whose hooks have not spoken yet is at its prompt, not at work" {
    var f: Facts = .none;
    f.hooks = .expected;
    f.expected_ms = null;
    // Drawn a second ago, as a CLI starting up is.
    f.screen = .{ .still_ms = 1000 };
    try testing.expectEqual(Kind.idle, classify(f, T, now).kind);
    f.expected_ms = now - 1000;
    try testing.expectEqual(Kind.idle, classify(f, T, now).kind);
}

test "Attention: a finished turn is unseen until it is looked at" {
    var f = hooked(1, .ended, 40 * min);
    try testing.expectEqual(Kind.done_unseen, classify(f, T, now).kind);
    f.seen_ms = 39 * min;
    try testing.expectEqual(Kind.done_unseen, classify(f, T, now).kind);
    f.seen_ms = 41 * min;
    try testing.expectEqual(Kind.idle, classify(f, T, now).kind);
}

test "Attention: a finished turn with background work is still working" {
    var f = hooked(1, .ended, 40 * min);
    f.waiting_on_background = true;
    try testing.expectEqual(Kind.working, classify(f, T, now).kind);
}

test "Attention: without hooks the screen decides" {
    var f: Facts = .none;
    f.screen = .{ .still_ms = 1 * min };
    try testing.expectEqual(Kind.working, classify(f, T, now).kind);

    f.screen = .{ .still_ms = 10 * min };
    const quiet = classify(f, T, now);
    try testing.expectEqual(Kind.quiet_unknown, quiet.kind);
    try testing.expectEqual(Source.screen, quiet.source);
    try testing.expectEqual(@as(u64, 93 * min), quiet.since_ms);

    f.seen_ms = 95 * min;
    try testing.expectEqual(Kind.idle, classify(f, T, now).kind);

    try testing.expectEqual(Kind.idle, classify(Facts.none, T, now).kind);
}

test "Attention: a screen that could not be read is not an idle one" {
    // Nothing but the screen to go on, and the sampler failed.
    var plain: Facts = .none;
    plain.screen = Screen.of(.failed, 0, 70 * min);
    const s = classify(plain, T, now);
    try testing.expectEqual(Screen{ .unreadable = 70 * min }, s.screen);
    try testing.expect(s.kind != .idle);
    try testing.expectEqual(Source.screen_unreadable, s.source);
    try testing.expectEqual(Word.screen_unreadable, display(s).word);

    // In a turn and long silent: with no reading it is not called stuck.
    var turn = hooked(2, .in_turn, 10 * min);
    turn.call_silent_ms = 60 * min;
    turn.screen = Screen.of(.failed, 0, 70 * min);
    try testing.expectEqual(Kind.working, classify(turn, T, now).kind);

    // Not measured at all is a third answer, and not a number either.
    try testing.expectEqual(Screen.unmeasured, Screen.of(null, 5, 0));
    try testing.expectEqual(Screen.unmeasured, Screen.of(.starting, 5, 0));
    try testing.expectEqual(Screen{ .still_ms = 5 }, Screen.of(.running, 5, 0));
}

test "Attention: a self-report raises to needs-answer and never lowers" {
    var done = hooked(1, .ended, 40 * min);
    done.raised_ms = 41 * min;
    const raised = classify(done, T, now);
    try testing.expectEqual(Kind.needs_answer, raised.kind);
    try testing.expectEqual(Source.self_report, raised.source);
    try testing.expectEqual(@as(u64, 41 * min), raised.since_ms);

    var failed = hooked(1, .failed, 40 * min);
    failed.raised_ms = 41 * min;
    try testing.expectEqual(Kind.failed, classify(failed, T, now).kind);

    var approval = hooked(1, .awaiting_approval, 40 * min);
    approval.raised_ms = 41 * min;
    try testing.expectEqual(Kind.needs_approval, classify(approval, T, now).kind);

    // Said in a state that has since ended: it no longer holds.
    var stale = hooked(1, .in_turn, 50 * min);
    stale.raised_ms = 41 * min;
    try testing.expectEqual(Kind.working, classify(stale, T, now).kind);
}

test "Attention: held and shielded are carried and change nothing" {
    var f = hooked(1, .awaiting_approval, 40 * min);
    const bare = classify(f, T, now);
    f.held = true;
    f.shielded = true;
    const s = classify(f, T, now);
    try testing.expect(s.held and s.shielded);
    try testing.expectEqual(bare.kind, s.kind);
    try testing.expectEqual(display(bare), display(s));
}

test "Attention: a group takes its supervisor's kind" {
    const g: Group = .{
        .steward = status(1, .in_turn, 40 * min),
        .workers = &.{status(2, .ended, 30 * min)},
        .snooze = .none,
        .last_ms = 0,
    };
    const a = ofGroup(g, T, now);
    try testing.expectEqual(Kind.working, a.kind);
    try testing.expectEqual(What.own, a.what);
    try testing.expectEqual(@as(?Id, 1), a.terminal);
}

test "Attention: a worker left waiting past a minute shows on the group" {
    const late = now - 61 * std.time.ms_per_s;
    const g: Group = .{
        .steward = status(1, .in_turn, 40 * min),
        .workers = &.{ status(2, .in_turn, 0), status(3, .awaiting_approval, late) },
        .snooze = .none,
        .last_ms = 0,
    };
    const a = ofGroup(g, T, now);
    try testing.expectEqual(Kind.needs_approval, a.kind);
    try testing.expectEqual(What{ .worker = 3 }, a.what);
    try testing.expectEqual(@as(?Id, 3), a.terminal);
    try testing.expectEqual(late, a.since_ms);

    const failed: Group = .{
        .steward = status(1, .in_turn, 40 * min),
        .workers = &.{status(4, .failed, late)},
        .snooze = .none,
        .last_ms = 0,
    };
    try testing.expectEqual(What{ .worker = 4 }, ofGroup(failed, T, now).what);
}

test "Attention: a worker's first minute is its supervisor's to handle" {
    const fresh = now - 30 * std.time.ms_per_s;
    const g: Group = .{
        .steward = status(1, .in_turn, 40 * min),
        .workers = &.{status(3, .awaiting_approval, fresh)},
        .snooze = .none,
        .last_ms = 0,
    };
    const a = ofGroup(g, T, now);
    try testing.expectEqual(Kind.working, a.kind);
    try testing.expectEqual(What.own, a.what);
}

test "Attention: a prompt the supervisor may not answer is the person's from the first second" {
    const fresh = now - 30 * std.time.ms_per_s;
    // Allowed: the minute is the supervisor's, and the group is working.
    var w = status(3, .awaiting_approval, fresh);
    try testing.expectEqual(Bus.Answer.allowed, w.answer);
    const steward = status(1, .in_turn, 40 * min);
    try testing.expectEqual(Kind.working, ofGroup(.{ .steward = steward, .workers = &.{w}, .snooze = .none, .last_ms = 0 }, T, now).kind);

    // Switched off, or shielded: nobody but the person can, so it is theirs now.
    for ([_]Bus.Answer{ .off, .shielded }) |no| {
        w.answer = no;
        const a = ofGroup(.{ .steward = steward, .workers = &.{w}, .snooze = .none, .last_ms = 0 }, T, now);
        try testing.expectEqual(Kind.needs_approval, a.kind);
        try testing.expectEqual(What{ .worker = 3 }, a.what);
    }

    // A failure is not something to answer: its first minute stays the
    // supervisor's whatever the switch says.
    var failed = status(4, .failed, fresh);
    failed.answer = .off;
    try testing.expectEqual(Kind.working, ofGroup(.{ .steward = steward, .workers = &.{failed}, .snooze = .none, .last_ms = 0 }, T, now).kind);
}

test "Attention: with no supervisor to give it to, a worker's first minute is the person's" {
    const fresh = now - 30 * std.time.ms_per_s;
    const w = status(3, .awaiting_approval, fresh);
    const failed = status(4, .failed, fresh);

    // No supervisor at all.
    for ([_]Status{ w, failed }) |worker| {
        const a = ofGroup(.{ .steward = null, .workers = &.{worker}, .snooze = .none, .last_ms = 0 }, T, now);
        try testing.expectEqual(worker.kind, a.kind);
        try testing.expectEqual(What{ .worker = worker.id }, a.what);
    }

    // One that has clocked off, and one whose terminal is gone.
    var off = status(1, .in_turn, 40 * min);
    off.duty = .off;
    try testing.expectEqual(Kind.needs_approval, ofGroup(.{ .steward = off, .workers = &.{w}, .snooze = .none, .last_ms = 0 }, T, now).kind);
    var gone = status(1, .in_turn, 40 * min);
    gone.alive = false;
    try testing.expectEqual(Kind.needs_approval, ofGroup(.{ .steward = gone, .workers = &.{w}, .snooze = .none, .last_ms = 0 }, T, now).kind);

    // One that is there and on duty keeps its minute.
    try testing.expectEqual(Kind.working, ofGroup(.{ .steward = status(1, .in_turn, 40 * min), .workers = &.{w}, .snooze = .none, .last_ms = 0 }, T, now).kind);
}

test "Attention: only approval and failure bubble, and not past a higher supervisor" {
    const late = now - 5 * min;
    // A worker waiting on an answer is its supervisor's business.
    const answer: Group = .{
        .steward = status(1, .in_turn, 40 * min),
        .workers = &.{status(2, .awaiting_input, late)},
        .snooze = .none,
        .last_ms = 0,
    };
    try testing.expectEqual(Kind.working, ofGroup(answer, T, now).kind);

    // The supervisor's own approval outranks a worker's failure.
    const both: Group = .{
        .steward = status(1, .awaiting_approval, 99 * min),
        .workers = &.{status(2, .failed, late)},
        .snooze = .none,
        .last_ms = 0,
    };
    try testing.expectEqual(What.own, ofGroup(both, T, now).what);

    // A worker that clocked off bubbles nothing.
    var off = status(2, .failed, late);
    off.duty = .off;
    const clocked: Group = .{
        .steward = status(1, .in_turn, 40 * min),
        .workers = &.{off},
        .snooze = .none,
        .last_ms = 0,
    };
    try testing.expectEqual(Kind.working, ofGroup(clocked, T, now).kind);
}

test "Attention: a snoozed group is snoozed and does not need me" {
    var g: Group = .{
        .steward = status(1, .awaiting_approval, 40 * min),
        .workers = &.{},
        .snooze = .{ .until_change = 50 * min },
        .last_ms = 0,
    };
    const a = ofGroup(g, T, now);
    try testing.expectEqual(Kind.snoozed, a.kind);
    try testing.expectEqual(Kind.needs_approval, a.under);
    try testing.expect(!needsMe(a));
    try testing.expectEqual(@as(usize, 0), needsMeCount(&.{a}));

    // The state changed after the snooze: it is back.
    g.steward = status(1, .awaiting_approval, 60 * min);
    try testing.expectEqual(Kind.needs_approval, ofGroup(g, T, now).kind);

    g.snooze = .{ .until_ms = now + 1 };
    try testing.expectEqual(Kind.snoozed, ofGroup(g, T, now).kind);
    g.snooze = .{ .until_ms = now };
    try testing.expectEqual(Kind.needs_approval, ofGroup(g, T, now).kind);
}

test "Attention: a group with nobody alive is unattended" {
    var dead = status(1, .awaiting_approval, 40 * min);
    dead.alive = false;
    const g: Group = .{ .steward = dead, .workers = &.{}, .snooze = .none, .last_ms = 7 };
    const a = ofGroup(g, T, now);
    try testing.expectEqual(Kind.unattended, a.kind);
    try testing.expectEqual(@as(?Id, null), a.terminal);
    try testing.expectEqual(@as(u64, 7), a.since_ms);

    const empty: Group = .{ .steward = null, .workers = &.{}, .snooze = .none, .last_ms = 7 };
    try testing.expectEqual(Kind.unattended, ofGroup(empty, T, now).kind);

    const orphans: Group = .{
        .steward = null,
        .workers = &.{status(2, .in_turn, 0)},
        .snooze = .none,
        .last_ms = 7,
    };
    try testing.expectEqual(Kind.idle, ofGroup(orphans, T, now).kind);
}

test "Attention: needs-me is kinds one to four, unseen is five and six" {
    for (std.enums.values(Kind)) |k| {
        const n = @intFromEnum(k);
        try testing.expectEqual(n >= 1 and n <= 4, k.needsMe());
        try testing.expectEqual(n == 5 or n == 6, k.unseen());
    }
}

test "Attention: waiting on approval sorts ahead of working" {
    // The working one has been at it far longer; kind still comes first.
    var rows = [_]Attention{
        ofTerminal(status(1, .in_turn, 1 * min)),
        ofTerminal(status(2, .ended, 50 * min)),
        ofTerminal(status(3, .awaiting_approval, 90 * min)),
    };
    sort(&rows);
    try testing.expectEqual(@as(?Id, 3), rows[0].terminal);
    try testing.expectEqual(@as(?Id, 2), rows[1].terminal);
    try testing.expectEqual(@as(?Id, 1), rows[2].terminal);
}

test "Attention: within a kind the longest-waiting is on top" {
    var rows = [_]Attention{
        ofTerminal(status(1, .awaiting_approval, 90 * min)),
        ofTerminal(status(2, .awaiting_approval, 20 * min)),
        ofTerminal(status(4, .awaiting_approval, 50 * min)),
        ofTerminal(status(3, .awaiting_approval, 50 * min)),
    };
    sort(&rows);
    try testing.expectEqual(@as(?Id, 2), rows[0].terminal);
    try testing.expectEqual(@as(?Id, 3), rows[1].terminal);
    try testing.expectEqual(@as(?Id, 4), rows[2].terminal);
    try testing.expectEqual(@as(?Id, 1), rows[3].terminal);
}

test "Attention: one supervisor minding three groups is one waiting" {
    const boss = status(1, .awaiting_approval, 40 * min);
    const g: Group = .{ .steward = boss, .workers = &.{}, .snooze = .none, .last_ms = 0 };
    const other: Group = .{
        .steward = status(2, .failed, 40 * min),
        .workers = &.{},
        .snooze = .none,
        .last_ms = 0,
    };
    const busy: Group = .{
        .steward = status(3, .in_turn, 40 * min),
        .workers = &.{},
        .snooze = .none,
        .last_ms = 0,
    };
    const three = [_]Attention{ ofGroup(g, T, now), ofGroup(g, T, now), ofGroup(g, T, now) };
    try testing.expectEqual(@as(usize, 1), needsMeCount(&three));

    const mixed = [_]Attention{
        ofGroup(g, T, now),
        ofGroup(busy, T, now),
        ofGroup(g, T, now),
        ofGroup(other, T, now),
        ofGroup(g, T, now),
    };
    try testing.expectEqual(@as(usize, 2), needsMeCount(&mixed));
}

test "Attention: the merge table" {
    const Row = struct { Kind, Shown, []const u8 };
    const rows = [_]Row{
        .{ .needs_approval, .needs_you, "Awaiting approval" },
        .{ .needs_answer, .needs_you, "Awaiting input" },
        .{ .failed, .trouble, "Failed" },
        .{ .suspect_stuck, .trouble, "Maybe stuck" },
        .{ .done_unseen, .done_unseen, "Done, not looked at" },
        .{ .quiet_unknown, .done_unseen, "Stopped, cause unknown" },
        .{ .working, .working, "Working" },
        .{ .idle, .none, "" },
        .{ .unattended, .none, "Unattended" },
        .{ .snoozed, .none, "Set aside" },
    };
    try testing.expectEqual(std.enums.values(Kind).len, rows.len);
    for (rows) |row| {
        const d = displayOf(row[0]);
        try testing.expectEqual(row[1], d.shown);
        try testing.expectEqualStrings(row[2], d.word.text());
    }
}

test "Attention: a failure is trouble, not waiting for you" {
    try testing.expectEqual(Shown.trouble, displayOf(.failed).shown);
}

test "Attention: off duty draws nothing and is in no count" {
    var s = status(1, .awaiting_approval, 40 * min);
    s.duty = .off;
    try testing.expectEqual(Shown.none, display(s).shown);
    try testing.expectEqual(Top.none, top(&.{s}, .elsewhere));
    const a = ofTerminal(s);
    try testing.expect(!needsMe(a));
    try testing.expectEqual(@as(usize, 0), needsMeCount(&.{a}));
}

test "Attention: one glyph for several takes the highest" {
    const working = status(1, .in_turn, 1 * min);
    const done = status(2, .ended, 2 * min);
    const failed = status(3, .failed, 3 * min);
    const approval = status(4, .awaiting_approval, 90 * min);
    const answer = status(5, .awaiting_input, 80 * min);
    const idle = status(6, .idle, 0);

    try testing.expectEqual(Top.none, top(&.{}, .elsewhere));
    try testing.expectEqual(Top.none, top(&.{idle}, .elsewhere));
    try testing.expectEqual(Shown.working, top(&.{ idle, working }, .elsewhere).shown);
    try testing.expectEqual(Shown.done_unseen, top(&.{ working, done }, .elsewhere).shown);
    try testing.expectEqual(Shown.trouble, top(&.{ working, failed, done }, .elsewhere).shown);

    const all = [_]Status{ working, done, failed, approval, answer, idle };
    const t = top(&all, .elsewhere);
    try testing.expectEqual(Shown.needs_you, t.shown);
    // Of the two waiting for you, the one that has waited longer.
    try testing.expectEqual(@as(?usize, 4), t.index);
}

test "Attention: a window tab does not draw working" {
    const working = status(1, .in_turn, 1 * min);
    const done = status(2, .ended, 2 * min);
    try testing.expectEqual(Top.none, top(&.{working}, .window_tab));
    try testing.expectEqual(Shown.working, top(&.{working}, .elsewhere).shown);
    try testing.expectEqual(Shown.done_unseen, top(&.{ working, done }, .window_tab).shown);
}

test "1777: retrying is working until a screen would have been asked about, then stuck" {
    var f: Facts = .none;
    f.hooks = .live;
    f.state = .retrying;
    f.state_since_ms = 10_000;
    f.last_event_ms = 10_000;
    // A retry's screen moves -- its countdown -- so nothing else would say.
    f.screen = .{ .still_ms = 300 };
    const t: Thresholds = .defaults;

    const early = classify(f, t, 10_000 + t.screen_still_ms - 1);
    try testing.expectEqual(Kind.working, early.kind);
    try testing.expectEqual(Source.hook, early.source);
    // And the classification is looked at again when it would change.
    try testing.expectEqual(@as(?u64, 10_000 + t.screen_still_ms), nextChange(f, t, 10_000 + t.screen_still_ms - 1));

    const late = classify(f, t, 10_000 + t.screen_still_ms);
    try testing.expectEqual(Kind.suspect_stuck, late.kind);
    try testing.expectEqual(@as(u64, 10_000 + t.screen_still_ms), late.since_ms);
}

test "1656: a title that says it waits is a card waiting on approval, said to come from the title" {
    var f: Facts = .none;
    f.said_by = .title;
    f.state = .awaiting_approval;
    f.state_since_ms = 4_000;
    f.last_event_ms = 4_000;
    // What Codex's screen does under its box: never still.
    f.screen = .{ .still_ms = 300 };
    const s = classify(f, .defaults, 9_000);
    try testing.expectEqual(Kind.needs_approval, s.kind);
    try testing.expectEqual(Source.title, s.source);
    try testing.expectEqual(@as(u64, 4_000), s.since_ms);

    // The same facts with no title behind them are a screen and nothing else.
    f.said_by = .hooks;
    try testing.expect(classify(f, .defaults, 9_000).kind != .needs_approval);
}
