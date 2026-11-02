//! Answering a CLI's own startup question -- the folder trust box -- by
//! pressing the key its plugin declares for it, once per question, for a
//! terminal Polter is itself starting (task 2674).
//!
//! **Why this exists at all.** Until this task the only door that pressed a
//! startup question's key was `terminal_answer_prompt`, which a *supervisor
//! on another terminal* calls (`rpc.startupAnswerRefusal`). That covers a
//! worker. It does not cover the **supervisor itself**: nobody is minding
//! it, `Chat.Start.asking` is set and the person is told to go and answer
//! it, and the control room's start sits there. A trust box in a directory
//! Codex has not seen therefore stops the one terminal every group needs.
//!
//! **The question, asked once.** The state kept here is per terminal and
//! per question: what was answered, whether the key reached the program,
//! and how many attempts it has taken. The rules it enforces are the ones
//! the user set out for this task, each with the reason it is a rule:
//!
//!   * **the same question is answered once, however long it stays up.**
//!     A box redrawn every second is not a box to press at every second,
//!     and a second return at a trust box goes into whatever the CLI put
//!     up next. So a claim is *not* aged out on a clock: it stays until the
//!     question is gone for two consecutive looks (see `gone_ticks`, and
//!     why two and not one), until a *different* declared question is the
//!     one on the screen, or until the terminal is gone or its start ends;
//!   * **the record is written before the key is sent**, and a record that
//!     cannot be written means no key is sent (`look` returns
//!     `error.OutOfMemory`, which the caller must treat as "do nothing
//!     this time"). The other order -- send, then remember -- has a window
//!     in which a successful answer is followed by a tick that does not
//!     know it already answered, and presses again;
//!   * **a key that did not reach the program is not an answer.** The
//!     caller must say which happened (`sent` / `failed`), and a failed
//!     attempt is retried, but at most `max_tries` times: a CLI that will
//!     not take the key is not one to hammer twice a second forever;
//!   * **only a key that was actually sent spends an attempt.** A tick
//!     that presses nothing -- the person is at the keyboard, the terminal
//!     is switched off or shielded, its process has exited -- is not an
//!     attempt and does not count against `max_tries`. The budget is for
//!     keys that went out and did nothing, so that a CLI taking no keys is
//!     not hammered forever; it is not a budget for *looks*. **This was a
//!     defect**: the look used to move `tries` before any of those facts
//!     were judged, so three ticks of somebody typing spent the whole
//!     budget without a key being sent -- the box stayed up and every look
//!     after it said `gave_up`, however long they stopped typing and
//!     however soon the terminal was switched back on;
//!   * **it is nobody's to answer where the person said no.** The
//!     permission is not judged here -- the caller asks `Bus.answer` (the
//!     one place `may_authorise` and the shield are combined) before it
//!     calls `look`, so there is no second copy of that rule to drift.
//!
//! **What is stored is a copy, not the plugin's slice.** The question text
//! handed in comes from `poltergeist_says`, which lives in the plugin
//! arena; that arena is rebuilt when the plugins are reloaded
//! (`App.ensurePlugins`), and a claim holding a slice into it would be
//! pointing at freed bytes from then on. So the text is duplicated here,
//! into this struct's own allocator, and freed with it.
//!
//! Its own file for the reason `OwedTells` is one: the bookkeeping is
//! tested without an app. `App` reads the screen, judges the permission and
//! presses the key; this file only decides whether that may happen now.

const StartupAnswers = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");
const Id = Bus.Id;

/// How many times a key that did not reach the program is tried before the
/// question is let go. **Bounded on purpose**: a terminal whose CLI takes
/// no keys (it has exited, or its pty is not being read) refuses every
/// attempt, and a retry with no bound is a loop that never stops and never
/// says so. Three attempts is `max_tries` ticks, and the caller's tick is
/// seconds apart.
pub const max_tries = 3;

/// Looks with nothing of ours on the screen before a claim is forgotten.
/// **Two, not one, and the second look is the whole point**: the screen is
/// read at one instant, and a CLI redrawing its box can be caught between
/// two frames -- one look that finds nothing is not evidence the question
/// was answered. Two consecutive looks is a weaker claim than "the box is
/// gone for certain", but the failure it prevents is asymmetric: a claim
/// kept too long costs one question going unanswered (the person answers it
/// as they always could), while a claim dropped too early costs a second
/// return at a box that is still up.
const gone_ticks_to_forget = 2;

alloc: Allocator,

/// One per terminal, and only for a terminal with a question being dealt
/// with. Nothing is kept for a terminal with no startup question.
claims: std.AutoArrayHashMapUnmanaged(Id, Claim) = .empty,

pub const Claim = struct {
    /// The declared text of the question this claim is about, owned here.
    /// It is the *matched declaration's* text (`StartupSays.Answer.contains`),
    /// never the screen's: a box that redraws its own lines still matches
    /// the same declaration, and so is still the same question.
    question: []u8,
    /// When it was first claimed.
    at_ms: u64,
    /// **Keys actually sent** at this question, successful or not.
    /// `max_tries` means given up. Moved by `look`, which the caller may
    /// reach only through `poll`/`consider` -- so a tick the gate refused
    /// never moves it. See `poll` for why that order matters.
    tries: u8,
    /// The key reached the program. From here the question is answered,
    /// whatever its box goes on doing.
    answered: bool,
    /// `.gave_up` has been said for this question already. **Said once**:
    /// the verdict is returned on the look that gives up and not on the
    /// looks after it, so a caller that logs what it is told logs one line
    /// per question rather than one every two seconds forever.
    gave_up_said: bool,
    /// Looks in a row that found nothing of ours on the screen.
    gone_ticks: u8,
};

/// What the caller is to do about the question it just saw.
pub const Verdict = union(enum) {
    /// Press the declared key now. The claim is already recorded, so this
    /// answer cannot be given twice.
    answer,
    /// Nothing to do: no question, one already answered, or one whose
    /// attempt it is not time for yet.
    wait,
    /// Every attempt has failed and nothing more will be sent for this
    /// question. **Returned once**, on the look that gives up, so that a
    /// caller which says so says it once.
    gave_up,
};

pub fn deinit(self: *StartupAnswers) void {
    for (self.claims.values()) |c| self.alloc.free(c.question);
    self.claims.deinit(self.alloc);
}

/// Forget everything about `id`. For a terminal that is gone, and for one
/// whose start has ended -- the next start in that terminal is another
/// question, asked on its own terms.
pub fn forget(self: *StartupAnswers, id: Id) void {
    if (self.claims.fetchSwapRemove(id)) |kv| self.alloc.free(kv.value.question);
}

pub fn count(self: *const StartupAnswers) usize {
    return self.claims.count();
}

/// What is already answered for `id`, for the log and for the tests.
pub fn claimOf(self: *const StartupAnswers, id: Id) ?Claim {
    return self.claims.get(id);
}

/// One look at `id`, and what to do about it. `question` is the declared
/// text of the answer that matched what is on the screen, or null when
/// nothing of this CLI's is answered by its plugin -- an ordinary screen, a
/// question the plugin recognises but does not answer, one already answered
/// and gone, or a screen read that failed.
///
/// **The claim for `answer` is written here, before the caller sends
/// anything**, and an allocation that fails is returned as an error rather
/// than swallowed: the caller must send nothing this time. See the header
/// for why that order is the one that matters.
pub fn look(self: *StartupAnswers, id: Id, question: ?[]const u8, now_ms: u64) Allocator.Error!Verdict {
    // **Nothing is inserted until there is something to keep.** An earlier
    // version took the entry up front with `getOrPut` and read
    // `found_existing` -- which put a claim in the map with an
    // *uninitialized* `question` pointer on every look that found no
    // question at all, and the next look then freed that pointer. The
    // negative-control test found it (segfault at 0xaaaa…, the allocator's
    // fill pattern). So the map is asked, not made, until a question is
    // really here.
    const q = question orelse {
        const c = self.claims.getPtr(id) orelse return .wait;
        c.gone_ticks += 1;
        if (c.gone_ticks >= gone_ticks_to_forget) {
            self.alloc.free(c.question);
            _ = self.claims.swapRemove(id);
        }
        return .wait;
    };

    if (self.claims.getPtr(id)) |c| {
        // The same question, still on the screen: nothing new to do, and
        // the look counts as having seen it.
        if (std.mem.eql(u8, c.question, q)) {
            c.gone_ticks = 0;
            if (c.answered) return .wait;
            if (c.tries >= max_tries) {
                if (c.gave_up_said) return .wait;
                c.gave_up_said = true;
                return .gave_up;
            }
            // An attempt that failed: tried again, up to the bound. The
            // claim is already written, so there is nothing to record and
            // nothing that can fail between here and the key.
            c.tries += 1;
            return .answer;
        }
        // A different declared question is the one up. The one this claim
        // was about is gone -- answered, declined, or replaced by the CLI's
        // next box -- so this is a new question and is answered on its own
        // terms. **The new text is taken before the old is freed**, so a
        // failed allocation leaves the claim as it was rather than with a
        // dangling pointer.
        const copy = try self.alloc.dupe(u8, q);
        self.alloc.free(c.question);
        c.* = .{ .question = copy, .at_ms = now_ms, .tries = 1, .answered = false, .gave_up_said = false, .gone_ticks = 0 };
        return .answer;
    }

    // Nothing held: a question of this CLI's, answerable, and not one
    // Polter has dealt with. The copy is taken before the entry exists, so
    // an allocation that fails leaves no entry behind.
    const copy = try self.alloc.dupe(u8, q);
    errdefer self.alloc.free(copy);
    const gop = try self.claims.getOrPut(self.alloc, id);
    gop.value_ptr.* = .{ .question = copy, .at_ms = now_ms, .tries = 1, .answered = false, .gave_up_said = false, .gone_ticks = 0 };
    return .answer;
}

/// One poll of `id`: `look` where Polter may press, and a look that cannot
/// spend the attempt budget where it may not.
///
/// **`allowed` is the caller's `gate(...) == .press`, and the order is the
/// whole point.** `look` spends an attempt, and the caller used to reach it
/// before the person typing, the permission and the dead child were judged
/// -- so a tick that pressed nothing spent the budget anyway, and three
/// ticks of somebody typing, or of a terminal switched off, ended the
/// question with no key ever sent. Judged first, the budget is only ever
/// spent by a tick that is really going to press.
///
/// A question that is up and may not be pressed is left **exactly** as it
/// was: `.wait`, `tries` unmoved, and the look counted as having seen the
/// question (`gone_ticks = 0`) so it cannot be forgotten for being "gone"
/// on a tick that can see it. A question that is *gone* is still cleaned up
/// the same two looks as before, which is why this is not simply "do
/// nothing when not allowed": the claim has to be let go after the box
/// disappears whoever is at the keyboard.
pub fn poll(
    self: *StartupAnswers,
    id: Id,
    question: ?[]const u8,
    now_ms: u64,
    allowed: bool,
) Allocator.Error!Verdict {
    if (allowed) return self.look(id, question, now_ms);
    if (question != null) {
        // **A look that sees the question is a look that saw it**, even
        // when it may not press: `gone_ticks` counts looks in a row that
        // found *nothing*, and leaving it to run on here would let the
        // sequence "nothing, question (gated), nothing" forget a claim
        // whose box is still on the screen -- and the next permitted tick
        // would press a second return at it. Nothing else moves: `tries` is
        // what the gate protects, and this is not an attempt.
        if (self.claims.getPtr(id)) |c| c.gone_ticks = 0;
        return .wait;
    }
    return self.look(id, null, now_ms);
}

/// One tick of the whole judgement: the gate and the look, in that order,
/// as **one call**. `App.answerStartupQuestions` measures the three facts
/// and calls this; nothing else combines them, so what the tests hold is
/// the order the program runs and not a copy of it.
///
/// `gate` is returned so the caller can say *why* it is not pressing, which
/// is the same reason the two halves are one call: split, a caller that
/// forgot to judge before looking would spend the attempt budget on a tick
/// that sends nothing -- the defect this signature exists to make
/// impossible to write by accident.
pub const Considered = struct { gate: Gate, verdict: Verdict };

pub fn consider(
    self: *StartupAnswers,
    id: Id,
    question: ?[]const u8,
    now_ms: u64,
    permission: Bus.Answer,
    child_exited: bool,
    person_typing: bool,
) Allocator.Error!Considered {
    const g = gate(permission, child_exited, person_typing);
    const v = try self.poll(id, question, now_ms, g == .press);
    return .{ .gate = g, .verdict = v };
}

/// The key reached the program. **Not "the box is gone"** -- whether the
/// question was answered is the CLI's to know and the screen's to show, and
/// this only records that Polter has done its part, so that it does not do
/// it again.
pub fn sent(self: *StartupAnswers, id: Id) void {
    const c = self.claims.getPtr(id) orelse return;
    c.answered = true;
    c.gone_ticks = 0;
}

/// The key did not reach the program: the surface said no (a binding took
/// it, it encoded to nothing, the surface closed), or the call failed. The
/// claim is kept so the question is not answered twice over, and `tries`
/// was already moved by the `answer` verdict that led here -- so this only
/// has to say so.
pub fn failed(self: *StartupAnswers, id: Id) void {
    const c = self.claims.getPtr(id) orelse return;
    c.answered = false;
}

pub fn gaveUp(self: *const StartupAnswers, id: Id) bool {
    const c = self.claims.get(id) orelse return false;
    return !c.answered and c.tries >= max_tries;
}

/// What may be pressed at a question the plugin answers, given everything
/// outside this file that is a reason not to. **Pure, and the only place
/// those reasons are combined**, so that each one can be held by a test
/// without an app: `App.answerStartupQuestions` measures the three facts
/// and calls this, and does nothing the verdict does not say.
///
/// The caller measures:
///   * `permission` -- `Bus.answer(id)`, the one place `may_authorise` and
///     the shield are combined. Anything but `.allowed` means the person
///     said no, here or for every terminal, or took the terminal out of
///     reach. **Not re-derived here**: a second reading of those two marks
///     is a second rule, and the two would drift.
///   * `child_exited` -- the CLI is gone, and a key sent to a dead pty is
///     one nobody receives.
///   * `person_typing` -- a real key within the quiet window, or an input
///     method composing (`Surface.presenceForMove`). Injected keys never
///     count: they put the clock back.
pub const Gate = enum { press, wait, leave_it };

pub fn gate(
    permission: Bus.Answer,
    child_exited: bool,
    person_typing: bool,
) Gate {
    // The person's word first, and it is not a wait: a terminal they
    // switched off or shielded keeps its question until they answer it, and
    // a later tick is not going to change that on its own.
    if (permission != .allowed) return .leave_it;
    // Also not a wait: nothing about a process that has exited is going to
    // change by looking again.
    if (child_exited) return .leave_it;
    // This one *is* a wait: the person is most likely answering the box
    // right now, and a key pressed under their hands is the defect the
    // question exists to avoid.
    if (person_typing) return .wait;
    return .press;
}
const testing = std.testing;

fn freeAll(a: *StartupAnswers) void {
    a.deinit();
}

test "2674: a question is answered once, however long its box stays up" {
    var a: StartupAnswers = .{ .alloc = testing.allocator };
    defer freeAll(&a);

    try testing.expectEqual(Verdict.answer, try a.look(0xa1, "Trust this folder?", 1_000));
    try testing.expectEqual(@as(usize, 1), a.count());
    a.sent(0xa1);

    // The box is redrawn for a long time -- far past any interval a timer
    // would have used. Not a second key.
    var t: u64 = 1_000;
    while (t < 600_000) : (t += 2_000) {
        try testing.expectEqual(Verdict.wait, try a.look(0xa1, "Trust this folder?", t));
    }
    try testing.expectEqual(@as(u8, 1), a.claimOf(0xa1).?.tries);
    try testing.expect(a.claimOf(0xa1).?.answered);
}

test "2674: a key that did not reach the program is retried, and then let go" {
    var a: StartupAnswers = .{ .alloc = testing.allocator };
    defer freeAll(&a);

    // First attempt.
    try testing.expectEqual(Verdict.answer, try a.look(0xb1, "Trust this folder?", 0));
    a.failed(0xb1);
    // It is not yet given up, and the next look is another attempt -- not a
    // verdict that leaves the caller waiting forever.
    try testing.expectEqual(Verdict.answer, try a.look(0xb1, "Trust this folder?", 2_000));
    a.failed(0xb1);
    try testing.expectEqual(Verdict.answer, try a.look(0xb1, "Trust this folder?", 4_000));
    a.failed(0xb1);
    // Bounded: no more keys, whoever looks again.
    try testing.expectEqual(Verdict.gave_up, try a.look(0xb1, "Trust this folder?", 6_000));
    // **Said once**, not on every look after it: the caller logs what it is
    // told, and a line every two seconds forever is not a report.
    try testing.expectEqual(Verdict.wait, try a.look(0xb1, "Trust this folder?", 8_000));
    try testing.expectEqual(Verdict.wait, try a.look(0xb1, "Trust this folder?", 10_000));
    try testing.expect(a.gaveUp(0xb1));
    try testing.expectEqual(@as(u8, max_tries), a.claimOf(0xb1).?.tries);

    // A terminal nobody ever answered for is not "given up".
    try testing.expect(!a.gaveUp(0xb2));
}

test "2674: a claim is forgotten two looks after nothing of ours is on the screen" {
    var a: StartupAnswers = .{ .alloc = testing.allocator };
    defer freeAll(&a);

    try testing.expectEqual(Verdict.answer, try a.look(0xc1, "Trust this folder?", 0));
    a.sent(0xc1);

    // **One look with nothing is not evidence.** A box redrawn can be
    // caught between frames, and clearing on it would answer a question
    // that is still up all over again.
    try testing.expectEqual(Verdict.wait, try a.look(0xc1, null, 2_000));
    try testing.expectEqual(@as(usize, 1), a.count());
    // And the box is back: still answered, still nothing to do.
    try testing.expectEqual(Verdict.wait, try a.look(0xc1, "Trust this folder?", 4_000));
    try testing.expectEqual(@as(u8, 0), a.claimOf(0xc1).?.gone_ticks);

    // Gone for two looks running: forgotten.
    try testing.expectEqual(Verdict.wait, try a.look(0xc1, null, 6_000));
    try testing.expectEqual(Verdict.wait, try a.look(0xc1, null, 8_000));
    try testing.expectEqual(@as(usize, 0), a.count());

    // And a question after that is a new question, answered on its own
    // terms -- which is what "the next start is another question" means.
    try testing.expectEqual(Verdict.answer, try a.look(0xc1, "Trust this folder?", 10_000));
}

test "2674: a different declared question is a different question" {
    var a: StartupAnswers = .{ .alloc = testing.allocator };
    defer freeAll(&a);

    try testing.expectEqual(Verdict.answer, try a.look(0xd1, "Trust this folder?", 0));
    a.sent(0xd1);
    try testing.expectEqual(Verdict.wait, try a.look(0xd1, "Trust this folder?", 2_000));

    // The CLI's next box, answered by its own declaration: a new question,
    // and answered once.
    try testing.expectEqual(Verdict.answer, try a.look(0xd1, "Do you trust the contents of this directory?", 4_000));
    try testing.expectEqualStrings("Do you trust the contents of this directory?", a.claimOf(0xd1).?.question);
    a.sent(0xd1);
    try testing.expectEqual(Verdict.wait, try a.look(0xd1, "Do you trust the contents of this directory?", 6_000));
    try testing.expectEqual(@as(usize, 1), a.count());
}

test "2674: the question kept is a copy, not the plugin's own bytes" {
    var a: StartupAnswers = .{ .alloc = testing.allocator };
    defer freeAll(&a);

    // What the plugin arena holds is not this file's to keep: the text is
    // handed in on a stack buffer here and scribbled over straight after,
    // which is what a reload of the plugins looks like from this side.
    var theirs: [32]u8 = undefined;
    const q = "Trust this folder?";
    @memcpy(theirs[0..q.len], q);
    try testing.expectEqual(Verdict.answer, try a.look(0xe1, theirs[0..q.len], 0));
    a.sent(0xe1);
    @memset(&theirs, 0);
    try testing.expectEqualStrings("Trust this folder?", a.claimOf(0xe1).?.question);
    // And it still matches the same question on the next look.
    try testing.expectEqual(Verdict.wait, try a.look(0xe1, q, 2_000));
}

test "2674: forgetting a terminal takes its claim with it, and the memory with it" {
    var a: StartupAnswers = .{ .alloc = testing.allocator };
    defer freeAll(&a);

    try testing.expectEqual(Verdict.answer, try a.look(0xf1, "Trust this folder?", 0));
    a.sent(0xf1);
    try testing.expectEqual(@as(usize, 1), a.count());
    a.forget(0xf1);
    try testing.expectEqual(@as(usize, 0), a.count());
    // The terminal came back as a new terminal: answered again.
    try testing.expectEqual(Verdict.answer, try a.look(0xf1, "Trust this folder?", 2_000));

    // `forget` for a terminal with nothing kept is not a mistake.
    a.forget(0xf2);
    try testing.expectEqual(@as(usize, 1), a.count());
}

test "2674: two terminals being started at once keep their own questions" {
    // **Two supervisors started together is the ordinary case** -- the
    // control room starts one per group, and a supervisor can start its
    // first worker while it is still coming up. A single `?Id` for the
    // whole app would let the second start take the first one's claim, so
    // the state is per terminal and this holds it there.
    var a: StartupAnswers = .{ .alloc = testing.allocator };
    defer freeAll(&a);

    try testing.expectEqual(Verdict.answer, try a.look(0x11, "Trust this folder?", 0));
    try testing.expectEqual(Verdict.answer, try a.look(0x22, "Trust this folder?", 0));
    a.sent(0x11);
    try testing.expectEqual(@as(usize, 2), a.count());

    // One answered, one not: the other is still to press, and the answered
    // one is not.
    try testing.expectEqual(Verdict.wait, try a.look(0x11, "Trust this folder?", 2_000));
    try testing.expectEqual(Verdict.answer, try a.look(0x22, "Trust this folder?", 2_000));
    a.sent(0x22);

    // And one terminal's question going does not touch the other's.
    a.forget(0x11);
    try testing.expectEqual(@as(usize, 1), a.count());
    try testing.expect(a.claimOf(0x22) != null);
    try testing.expect(a.claimOf(0x11) == null);
}

test "2674: what may be pressed at a startup question, and what may not" {
    // The ordinary case: the person's default, a live process, nobody at
    // the keyboard.
    try testing.expectEqual(Gate.press, gate(.allowed, false, false));

    // **The person's word is not a wait.** A terminal switched off
    // (`Answer.off`) or shielded is left with its question for as long as
    // it takes them; looking again in two seconds does not change it, and a
    // verdict of `wait` would be this program promising itself something it
    // cannot deliver.
    try testing.expectEqual(Gate.leave_it, gate(.off, false, false));
    try testing.expectEqual(Gate.leave_it, gate(.shielded, false, false));
    // And neither of the two is undone by the other facts being fine.
    try testing.expectEqual(Gate.leave_it, gate(.off, false, true));
    try testing.expectEqual(Gate.leave_it, gate(.shielded, true, false));

    // A CLI whose process is gone takes no keys, and no amount of looking
    // brings it back.
    try testing.expectEqual(Gate.leave_it, gate(.allowed, true, false));
    try testing.expectEqual(Gate.leave_it, gate(.allowed, true, true));

    // **Somebody at the keyboard is a wait, not a refusal**: they are most
    // likely answering the box this moment, and the question is looked at
    // again when they have stopped.
    try testing.expectEqual(Gate.wait, gate(.allowed, false, true));
}

test "2674: a question the plugin does not answer is not answered at all" {
    // The negative control for the whole file: `unanswerable` and `none`
    // both reach here as "no question of ours", and neither is a question
    // to claim -- so nothing is pressed, and nothing is remembered either
    // (a claim taken for a box the plugin does not answer would be a claim
    // that never clears, since the box never matches a declaration).
    var a: StartupAnswers = .{ .alloc = testing.allocator };
    defer freeAll(&a);

    try testing.expectEqual(Verdict.wait, try a.look(0x31, null, 0));
    try testing.expectEqual(Verdict.wait, try a.look(0x31, null, 2_000));
    try testing.expectEqual(Verdict.wait, try a.look(0x31, null, 600_000));
    try testing.expectEqual(@as(usize, 0), a.count());
    try testing.expect(a.claimOf(0x31) == null);
}

// The three below go through `consider` -- the call `App` makes -- rather
// than `look` or `gate` alone, because the defect they pin is in the
// *order* of the two: a look reached before the gate spends the attempt
// budget on ticks that press nothing. A test of `gate` by itself cannot see
// that, and neither can one of `look`.

test "2674: somebody typing for many ticks does not spend the attempt budget" {
    var a: StartupAnswers = .{ .alloc = testing.allocator };
    defer freeAll(&a);

    // The person is at this terminal, tick after tick, far past
    // `max_tries`: every one of them is a wait, and **not one of them is an
    // attempt**.
    var t: u64 = 0;
    while (t < 20_000) : (t += 2_000) {
        const d = try a.consider(0x41, "Trust this folder?", t, .allowed, false, true);
        try testing.expectEqual(Gate.wait, d.gate);
        try testing.expectEqual(Verdict.wait, d.verdict);
    }
    // Nothing was claimed, because nothing was ever pressed.
    try testing.expectEqual(@as(usize, 0), a.count());

    // They stop. **The question is still there to be answered** -- which is
    // the whole of the defect: before, the budget was spent by the ticks
    // above and this look said `gave_up` with no key ever sent.
    const d = try a.consider(0x41, "Trust this folder?", t, .allowed, false, false);
    try testing.expectEqual(Gate.press, d.gate);
    try testing.expectEqual(Verdict.answer, d.verdict);
    try testing.expectEqual(@as(u8, 1), a.claimOf(0x41).?.tries);
    a.sent(0x41);

    // And once answered, more typing does not start it over.
    const after = try a.consider(0x41, "Trust this folder?", t + 2_000, .allowed, false, true);
    try testing.expectEqual(Gate.wait, after.gate);
    try testing.expectEqual(Verdict.wait, after.verdict);
    try testing.expectEqual(@as(u8, 1), a.claimOf(0x41).?.tries);
}

test "2674: a terminal switched off for many ticks answers as soon as it is back on" {
    var a: StartupAnswers = .{ .alloc = testing.allocator };
    defer freeAll(&a);

    // Switched off (or shielded): the answer is the person's, and looking
    // again does not change it -- and does not spend the budget either.
    for ([_]Bus.Answer{ .off, .shielded, .off, .shielded }) |p| {
        const d = try a.consider(0x51, "Trust this folder?", 1_000, p, false, false);
        try testing.expectEqual(Gate.leave_it, d.gate);
        try testing.expectEqual(Verdict.wait, d.verdict);
    }
    try testing.expectEqual(@as(usize, 0), a.count());

    // Switched back on: the question is pressed, first try, no budget gone.
    const d = try a.consider(0x51, "Trust this folder?", 9_000, .allowed, false, false);
    try testing.expectEqual(Gate.press, d.gate);
    try testing.expectEqual(Verdict.answer, d.verdict);
    try testing.expectEqual(@as(u8, 1), a.claimOf(0x51).?.tries);
    a.sent(0x51);

    // **And a claim is still cleaned up while nothing may be pressed.**
    // Not-pressing is not "do nothing": the box goes away, and the two
    // looks that say so must forget it whether or not the terminal is
    // switched on -- otherwise the claim outlives its question.
    try testing.expectEqual(Verdict.wait, (try a.consider(0x51, null, 11_000, .off, false, false)).verdict);
    try testing.expectEqual(@as(usize, 1), a.count());
    try testing.expectEqual(Verdict.wait, (try a.consider(0x51, null, 13_000, .allowed, false, false)).verdict);
    try testing.expectEqual(@as(usize, 0), a.count());
}

test "2674: a gated look that still sees the box does not count towards forgetting it" {
    // The other half of the same fix, and its own defect if got wrong: a
    // gated tick does not touch the claim, so it must not look *after* the
    // box is gone either. "Nothing, box (switched off), nothing" is not two
    // looks that found nothing -- the box is still on the screen, and
    // forgetting it here would let the next permitted tick press a second
    // return at a box that never went away.
    var a: StartupAnswers = .{ .alloc = testing.allocator };
    defer freeAll(&a);

    try testing.expectEqual(Verdict.answer, try a.look(0x53, "Trust this folder?", 0));
    a.sent(0x53);

    // One look that found nothing, then the box again while switched off,
    // then another that finds nothing.
    try testing.expectEqual(Verdict.wait, (try a.consider(0x53, null, 1_000, .allowed, false, false)).verdict);
    try testing.expectEqual(Verdict.wait, (try a.consider(0x53, "Trust this folder?", 3_000, .off, false, false)).verdict);
    try testing.expectEqual(Verdict.wait, (try a.consider(0x53, null, 5_000, .allowed, false, false)).verdict);
    // **Still remembered**, and still answered: not a second key.
    try testing.expectEqual(@as(usize, 1), a.count());
    try testing.expect(a.claimOf(0x53).?.answered);

    // Two looks with nothing, in a row, still forget it -- the rule the
    // file started with is not weakened by the gate.
    try testing.expectEqual(Verdict.wait, (try a.consider(0x53, null, 7_000, .allowed, false, false)).verdict);
    try testing.expectEqual(@as(usize, 0), a.count());
}

test "2674: keys that did not arrive are still bounded at three, and only those spend it" {
    var a: StartupAnswers = .{ .alloc = testing.allocator };
    defer freeAll(&a);

    // Three presses, each of which did not reach the program. **These are
    // what the budget is for**, and they are what moves it.
    var t: u64 = 0;
    var n: u8 = 0;
    while (n < max_tries) : (n += 1) {
        const d = try a.consider(0x61, "Trust this folder?", t, .allowed, false, false);
        try testing.expectEqual(Verdict.answer, d.verdict);
        a.failed(0x61);
        t += 2_000;
    }
    try testing.expectEqual(@as(u8, max_tries), a.claimOf(0x61).?.tries);

    // Bounded, and said once -- no key goes out any more, whatever the gate
    // would allow.
    const gave_up = try a.consider(0x61, "Trust this folder?", t, .allowed, false, false);
    try testing.expectEqual(Gate.press, gave_up.gate);
    try testing.expectEqual(Verdict.gave_up, gave_up.verdict);
    const again = try a.consider(0x61, "Trust this folder?", t + 2_000, .allowed, false, false);
    try testing.expectEqual(Verdict.wait, again.verdict);
    try testing.expect(a.gaveUp(0x61));

    // A tick that presses nothing in between does not change the count in
    // either direction: the bound is on keys sent, not on looks.
    try testing.expectEqual(Verdict.wait, (try a.consider(0x61, "Trust this folder?", t + 4_000, .off, false, false)).verdict);
    try testing.expectEqual(@as(u8, max_tries), a.claimOf(0x61).?.tries);
}
