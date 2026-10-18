//! The control room's "Fix" button on a card that reads "Failed" (task
//! 1560): the core types a paragraph into the card's supervisor saying who
//! failed, with what and when, and leaves what to do about it to that
//! supervisor -- go on, retry, say "done", or close it.
//!
//! **Nothing here clears a failure.** A failure is cleared by the failed
//! terminal's next event and by nothing else; this only tells somebody who
//! can bring that event about. There is no "force clear", on purpose.
//!
//! Four pieces, each a pure function with its own tests:
//!
//!   * `offered` -- which cards have the button: those whose word is
//!     `failed`, and no other.
//!   * `plan` -- the paragraph and who it is typed into: the supervisor,
//!     about its workers and itself; or, with no supervisor, each failed
//!     terminal about itself.
//!   * `deliver` -- the road a `group_post` mention takes: kept in the
//!     group, then typed with a return, refused by the same names
//!     (`NoAgent`, `UserPresent`, `DraftInLine`, ...).
//!   * `Sent` / `stateOf` -- "notified" stands until the card changes: the
//!     set of failed terminals or when they failed.

const ControlFix = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Attention = @import("Attention.zig");
const Bus = @import("Bus.zig");
const ControlRoom = @import("ControlRoom.zig");
const i18n = @import("../os/i18n.zig");
const Typist = @import("rpc.zig").Typist;

pub const Id = Bus.Id;

/// What a card's button is.
pub const State = enum {
    /// No button: the card does not read "Failed".
    none,
    /// "Fix", to be pressed.
    offered,
    /// "Supervisor notified", greyed, until the card changes.
    sent,
};

/// Whether a card with this word has the button. The word and not the
/// kind: a terminal off duty, or one whose screen cannot be read, is not
/// drawn "Failed" whatever its kind, and the button goes with what is
/// drawn.
pub fn offered(word: Attention.Word) bool {
    return switch (word) {
        .failed => true,
        .needs_approval,
        .needs_answer,
        .suspect_stuck,
        .done_unseen,
        .working,
        .quiet_unknown,
        .screen_unreadable,
        .agent_left,
        .unattended,
        .snoozed,
        .off_duty,
        .none,
        => false,
    };
}

/// One failed terminal under a card.
pub const Failing = struct {
    id: Id,
    /// Its title; empty when it has none.
    title: []const u8,
    /// What failed, as the CLI said it (`server_error`, `rate_limit`), or
    /// `process_exited`. Empty when nothing said.
    what: []const u8,
    /// When it failed: the bus's clock, for the stamp, and the wall's,
    /// for the sentence.
    since_ms: u64,
    at_wall_ms: u64,
};

/// Which card: a group's, or a terminal's that is in no group.
pub const Key = union(enum) {
    group: []const u8,
    terminal: Id,
};

/// A card, as much of it as the button needs.
pub const Card = struct {
    key: Key,
    /// The group's supervisor; null for a group without one and for a
    /// terminal on its own.
    steward: ?Id,
    failing: []const Failing,
    state: State,
};

/// What tells one moment of a card from another: who would be told, who
/// failed, and when. The same failures told to the same terminal are the
/// same press, however often the card is redrawn.
///
/// **No group's name in it**, so a rename neither loses a press nor needs
/// re-keying (`tools/group-names-are-registered.py`). Two cards that would
/// tell the same terminal about the same failures share it, which is right:
/// pressing either would type the same paragraph into the same place.
pub fn stampOf(steward: ?Id, failing: []const Failing) u64 {
    var h: std.hash.Wyhash = .init(0x1560);
    const to: Id = steward orelse 0;
    h.update(std.mem.asBytes(&to));
    for (failing) |f| {
        h.update(std.mem.asBytes(&f.id));
        h.update(std.mem.asBytes(&f.since_ms));
    }
    return h.final();
}

/// The presses that have been made (`stampOf`). Eight bytes a press, kept
/// for the run: a stamp whose moment has passed is never matched again, and
/// a run sees few failures.
pub const Sent = struct {
    stamps: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub fn deinit(self: *Sent, alloc: Allocator) void {
        self.stamps.deinit(alloc);
        self.* = undefined;
    }

    pub fn mark(self: *Sent, alloc: Allocator, stamp: u64) Allocator.Error!void {
        try self.stamps.put(alloc, stamp, {});
    }

    pub fn has(self: *const Sent, stamp: u64) bool {
        return self.stamps.contains(stamp);
    }
};

/// The button on a card drawn with `word`, whose supervisor is `steward`,
/// failing as `failing`.
pub fn stateOf(word: Attention.Word, sent: *const Sent, steward: ?Id, failing: []const Failing) State {
    if (!offered(word) or failing.len == 0) return .none;
    return if (sent.has(stampOf(steward, failing))) .sent else .offered;
}

/// One paragraph to type into one terminal.
pub const Delivery = struct {
    to: Id,
    text: []const u8,
};

/// How a moment reads in a sentence; `daylog.stamp` in the app, a fixed
/// string in a test.
pub const Clock = *const fn (buf: *[19]u8, at_ms: i64) []const u8;

/// A msgid in the person's language: `i18n._` in the app, `english` (the
/// msgid itself) or a catalogue in a test.
pub const Tr = *const fn (msgid: [:0]const u8) []const u8;

pub fn english(msgid: [:0]const u8) []const u8 {
    return msgid;
}

/// What the paragraph is written with: the clock its moments are read by
/// and the language its words are in.
///
/// **The interface's language**, the one the menus are in: the paragraph
/// is something the person caused, typed where they may well read it, and
/// the core already speaks to them in that language wherever it writes
/// into a terminal itself (the line above a restored scrollback). An agent
/// reads either.
pub const Voice = struct {
    clock: Clock,
    tr: Tr,
};

/// What the paragraph starts with, in every language: one string that a
/// supervisor, its skill (`supervising.md`) and anybody reading the group
/// can look for, whatever language the person who pressed it uses.
/// Translated, it would be one marker per language, and the skill would
/// have to list them all.
pub const tag = "[Polter fix]";

// The paragraph's words. English msgids; `{1}`, `{2}` filled by
// `ControlRoom.Say.fill`, as the control room's own sentences are.
const words = struct {
    const who = i18n.N_("Terminal {1} ({2})");
    const who_bare = i18n.N_("Terminal {1}");
    const unknown = i18n.N_("cause unknown");
    /// What failed, then when.
    const what_when = i18n.N_("{1}, {2}");
    /// Who, then what and when.
    const failed = i18n.N_("{1} failed: {2}.");
    const own = i18n.N_("Your last turn failed: {1}.");
    const own_among = i18n.N_("Your own last turn failed: {1}.");
    const many = i18n.N_("{1} failures here:");
    // One literal: `xgettext` reads this file as C and does not follow `++`.
    const worker_ask = i18n.N_("Read it with terminal_read first to see where it stopped: if it had not finished, have it carry on (terminal_send it to continue or retry); if it had finished, have it say one line that it is done (that line clears the failure), or close it once it is no longer needed. Say in the group when you have dealt with it.");
    const each_ask = i18n.N_("For each terminal that failed: {1}");
    const own_ask = i18n.N_("Decide whether your last turn finished: if not, carry on; if it did, say so in one line.");
    const self_ask = i18n.N_("For yourself: {1}");
    /// Two sentences side by side: a space in English, nothing in Chinese.
    const join = i18n.N_("{1} {2}");
};

/// Who is told, and what. One paragraph to the supervisor when there is
/// one, naming every failed terminal under the card; otherwise one to each
/// failed terminal, about itself.
pub fn plan(arena: Allocator, card: Card, voice: Voice) Allocator.Error![]const Delivery {
    if (card.steward) |steward| {
        const text = try paragraph(arena, steward, card.failing, voice);
        const out = try arena.alloc(Delivery, 1);
        out[0] = .{ .to = steward, .text = text };
        return out;
    }
    const out = try arena.alloc(Delivery, card.failing.len);
    for (card.failing, out) |f, *d| d.* = .{
        .to = f.id,
        .text = try paragraph(arena, f.id, &.{f}, voice),
    };
    return out;
}

/// The paragraph typed into `to` about `failing`, of which `to` itself may
/// be one: the tag, then the sentences in the person's language.
pub fn paragraph(arena: Allocator, to: Id, failing: []const Failing, voice: Voice) Allocator.Error![]const u8 {
    const body = try sentences(arena, to, failing, voice);
    return std.fmt.allocPrint(arena, "{s} {s}", .{ tag, body });
}

fn fill(arena: Allocator, voice: Voice, msgid: [:0]const u8, args: []const []const u8) Allocator.Error![]const u8 {
    return ControlRoom.Say.fill(arena, voice.tr(msgid), args);
}

fn join(arena: Allocator, voice: Voice, a: []const u8, b: []const u8) Allocator.Error![]const u8 {
    return fill(arena, voice, words.join, &.{ a, b });
}

fn sentences(arena: Allocator, to: Id, failing: []const Failing, voice: Voice) Allocator.Error![]const u8 {
    var own: ?Failing = null;
    var workers: usize = 0;
    for (failing) |f| {
        if (f.id == to) own = f else workers += 1;
    }

    // One of them: the sentence the supervisor wrote.
    if (failing.len == 1) {
        const f = failing[0];
        if (own != null) return join(
            arena,
            voice,
            try fill(arena, voice, words.own, &.{try whatWhen(arena, f, voice)}),
            voice.tr(words.own_ask),
        );
        return join(
            arena,
            voice,
            try fill(arena, voice, words.failed, &.{ try who(arena, f, voice), try whatWhen(arena, f, voice) }),
            voice.tr(words.worker_ask),
        );
    }

    // Several: each named in turn, then what to do about each kind.
    var out = try fill(arena, voice, words.many, &.{try std.fmt.allocPrint(arena, "{d}", .{failing.len})});
    for (failing) |f| {
        const said = if (f.id == to)
            try fill(arena, voice, words.own_among, &.{try whatWhen(arena, f, voice)})
        else
            try fill(arena, voice, words.failed, &.{ try who(arena, f, voice), try whatWhen(arena, f, voice) });
        out = try join(arena, voice, out, said);
    }
    if (workers > 0) out = try join(arena, voice, out, try fill(arena, voice, words.each_ask, &.{voice.tr(words.worker_ask)}));
    if (own != null) out = try join(arena, voice, out, try fill(arena, voice, words.self_ask, &.{voice.tr(words.own_ask)}));
    return out;
}

fn who(arena: Allocator, f: Failing, voice: Voice) Allocator.Error![]const u8 {
    const id = try std.fmt.allocPrint(arena, "0x{x:0>16}", .{f.id});
    if (f.title.len > 0) return fill(arena, voice, words.who, &.{ f.title, id });
    return fill(arena, voice, words.who_bare, &.{id});
}

fn whatWhen(arena: Allocator, f: Failing, voice: Voice) Allocator.Error![]const u8 {
    const what = if (f.what.len > 0) f.what else voice.tr(words.unknown);
    var buf: [19]u8 = undefined;
    const at = voice.clock(&buf, @intCast(@min(f.at_wall_ms, std.math.maxInt(i64))));
    return fill(arena, voice, words.what_when, &.{ what, at });
}

/// What delivering needs from outside this file.
pub const Port = struct {
    ctx: *anyopaque,
    /// Whether an agent is connected from that terminal right now.
    agentPresent: *const fn (ctx: *anyopaque, id: Id) bool,
    /// Keep `text` in `group` from the person, naming `to`, and type it
    /// into each of `to` with a return, as `typist` -- `group_post`'s road,
    /// which fills in each one's `err`.
    post: *const fn (ctx: *anyopaque, group: []const u8, text: []const u8, to: []Target, typist: Typist) anyerror!void,
    /// Type `text` into a terminal that is in no group, with a return, as
    /// `typist`.
    send: *const fn (ctx: *anyopaque, id: Id, text: []const u8, typist: Typist) anyerror!void,
};

pub const Target = struct {
    to: Id,
    err: ?anyerror = null,
};

/// Carry a plan out. Every paragraph is kept in the group, whether or not
/// it can be typed; the first refusal is returned, by name, after all of
/// them have been tried.
///
/// **Nobody listening, nothing typed**: a terminal with no agent connected
/// is a bare shell, and a paragraph typed there with a return is run as a
/// command. `NoAgent`, the same gate a mention has.
pub fn deliver(key: Key, deliveries: []const Delivery, port: Port) anyerror!void {
    // **Typed as the person, from elsewhere** (task 1738): they pressed
    // "Fix" in the control room, so a key that reached the terminal a
    // moment ago -- most likely their own -- does not hold it back. Half a
    // line there, a permission box, a word being composed still do.
    const typist: Typist = .person_elsewhere;
    var first: ?anyerror = null;
    for (deliveries) |d| {
        const present = port.agentPresent(port.ctx, d.to);
        switch (key) {
            .group => |group| {
                var one = [_]Target{.{ .to = d.to }};
                const to: []Target = if (present) &one else &.{};
                try port.post(port.ctx, group, d.text, to, typist);
                if (!present) {
                    if (first == null) first = error.NoAgent;
                } else if (one[0].err) |err| {
                    if (first == null) first = err;
                }
            },
            .terminal => {
                if (!present) {
                    if (first == null) first = error.NoAgent;
                    continue;
                }
                port.send(port.ctx, d.to, d.text, typist) catch |err| {
                    if (first == null) first = err;
                };
            },
        }
    }
    if (first) |err| return err;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn fixedClock(buf: *[19]u8, at_ms: i64) []const u8 {
    return std.fmt.bufPrint(buf, "T{d}", .{@divFloor(at_ms, 1000)}) catch unreachable;
}

const boss: Id = 0xb055;
const w1: Id = 0xa1;
const w2: Id = 0xa2;

fn failed(id: Id, title: []const u8, what: []const u8, at_s: u64) Failing {
    return .{ .id = id, .title = title, .what = what, .since_ms = at_s * 1000, .at_wall_ms = at_s * 1000 };
}

test "ControlFix: the button is on a card that reads Failed, and on no other" {
    for (std.enums.values(Attention.Word)) |word| {
        try testing.expectEqual(word == .failed, offered(word));
    }
    // What the kinds are drawn as: only `failed` is.
    for (std.enums.values(Attention.Kind)) |kind| {
        try testing.expectEqual(kind == .failed, offered(Attention.displayOf(kind).word));
    }
}

const en: Voice = .{ .clock = fixedClock, .tr = english };

const worker_ask_en = "Read it with terminal_read first to see where it stopped: if it had not finished, have it carry on (terminal_send it to continue or retry); if it had finished, have it say one line that it is done (that line clears the failure), or close it once it is no longer needed. Say in the group when you have dealt with it.";
const own_ask_en = "Decide whether your last turn finished: if not, carry on; if it did, say so in one line.";

test "ControlFix: a worker that failed: the supervisor is told who, with what and when, and what to do" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try plan(arena.allocator(), .{
        .key = .{ .group = "build" },
        .steward = boss,
        .failing = &.{failed(w1, "api", "server_error", 7)},
        .state = .offered,
    }, en);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(boss, out[0].to);
    try testing.expectEqualStrings(
        "[Polter fix] Terminal api (0x00000000000000a1) failed: server_error, T7. " ++ worker_ask_en,
        out[0].text,
    );
}

test "ControlFix: the supervisor that failed is told about itself" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try plan(arena.allocator(), .{
        .key = .{ .group = "build" },
        .steward = boss,
        .failing = &.{failed(boss, "boss", "rate_limit", 9)},
        .state = .offered,
    }, en);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(boss, out[0].to);
    try testing.expectEqualStrings("[Polter fix] Your last turn failed: rate_limit, T9. " ++ own_ask_en, out[0].text);
}

const three = [_]Failing{ failed(w1, "api", "server_error", 7), failed(w2, "", "", 8), failed(boss, "boss", "rate_limit", 9) };

test "ControlFix: several failed under one card: one paragraph, each named in turn" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try plan(arena.allocator(), .{
        .key = .{ .group = "build" },
        .steward = boss,
        .failing = &three,
        .state = .offered,
    }, en);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(boss, out[0].to);
    try testing.expectEqualStrings(
        "[Polter fix] 3 failures here: " ++
            "Terminal api (0x00000000000000a1) failed: server_error, T7. " ++
            "Terminal 0x00000000000000a2 failed: cause unknown, T8. " ++
            "Your own last turn failed: rate_limit, T9. " ++
            "For each terminal that failed: " ++ worker_ask_en ++ " " ++
            "For yourself: " ++ own_ask_en,
        out[0].text,
    );
}

test "ControlFix: no supervisor: each failed terminal is told about itself" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try plan(arena.allocator(), .{
        .key = .{ .group = "loose" },
        .steward = null,
        .failing = &.{ failed(w1, "api", "server_error", 7), failed(w2, "web", "rate_limit", 8) },
        .state = .offered,
    }, en);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(w1, out[0].to);
    try testing.expectEqualStrings("[Polter fix] Your last turn failed: server_error, T7. " ++ own_ask_en, out[0].text);
    try testing.expectEqual(w2, out[1].to);
    try testing.expectEqualStrings("[Polter fix] Your last turn failed: rate_limit, T8. " ++ own_ask_en, out[1].text);
}

/// `po/zh_CN.po` as a translator, the way gettext reads it: what the
/// catalogue says, or the msgid where it says nothing.
const Zh = struct {
    var catalogue: []const u8 = "";
    var arena: ?*std.heap.ArenaAllocator = null;

    fn tr(msgid: [:0]const u8) []const u8 {
        const found = i18n.po_text.lookup(arena.?.allocator(), catalogue, msgid) catch return msgid;
        const said = found orelse return msgid;
        return if (said.len == 0) msgid else said;
    }
};

test "ControlFix: in Chinese, every word of the paragraph comes from zh_CN.po, and the tag does not change" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    Zh.catalogue = std.Io.Dir.cwd().readFileAlloc(threaded.io(), "po/zh_CN.po", a, .limited(4 * 1024 * 1024)) catch |err| {
        std.debug.print("cannot read po/zh_CN.po ({t}). Run `zig build test` from the repository root.\n", .{err});
        return error.SourceUnreadable;
    };
    Zh.arena = &arena;
    defer Zh.arena = null;
    const zh: Voice = .{ .clock = fixedClock, .tr = Zh.tr };

    const worker_ask_zh = "请先 terminal_read 看它停在哪：没做完，就让它接着做（terminal_send 叫它继续或重试）；" ++
        "已经做完了，就让它回一句完成（这一句会消掉出错），或者在不再需要时关掉它。处理完在群里说一声。";
    const own_ask_zh = "请判断上一轮做完没有：没做完就接着做；做完了就回一句完成。";

    const worker = try plan(a, .{ .key = .{ .group = "build" }, .steward = boss, .failing = &.{three[0]}, .state = .offered }, zh);
    try testing.expectEqualStrings(
        "[Polter fix] 终端 api（0x00000000000000a1）出错了：server_error，T7。" ++ worker_ask_zh,
        worker[0].text,
    );

    const own = try plan(a, .{ .key = .{ .group = "build" }, .steward = boss, .failing = &.{three[2]}, .state = .offered }, zh);
    try testing.expectEqualStrings("[Polter fix] 你上一轮出错了：rate_limit，T9。" ++ own_ask_zh, own[0].text);

    const many = try plan(a, .{ .key = .{ .group = "build" }, .steward = boss, .failing = &three, .state = .offered }, zh);
    try testing.expectEqualStrings(
        "[Polter fix] 这里有 3 处出错：" ++
            "终端 api（0x00000000000000a1）出错了：server_error，T7。" ++
            "终端 0x00000000000000a2 出错了：原因不明，T8。" ++
            "你自己上一轮出错了：rate_limit，T9。" ++
            "对每个出错的终端，" ++ worker_ask_zh ++
            "你自己：" ++ own_ask_zh,
        many[0].text,
    );
}

test "ControlFix: notified stands until the card changes" {
    var sent: Sent = .{};
    defer sent.deinit(testing.allocator);
    const now = [_]Failing{failed(w1, "api", "server_error", 7)};

    try testing.expectEqual(State.offered, stateOf(.failed, &sent, boss, &now));
    try sent.mark(testing.allocator, stampOf(boss, &now));
    try testing.expectEqual(State.sent, stateOf(.failed, &sent, boss, &now));
    // Marked again, as after a second press: one mark, not two.
    try sent.mark(testing.allocator, stampOf(boss, &now));
    try testing.expectEqual(@as(u32, 1), sent.stamps.count());

    // It failed again, later: a new moment, and the button again.
    const again = [_]Failing{failed(w1, "api", "server_error", 70)};
    try testing.expectEqual(State.offered, stateOf(.failed, &sent, boss, &again));
    // Another one failed beside it.
    const more = [_]Failing{ now[0], failed(w2, "web", "", 8) };
    try testing.expectEqual(State.offered, stateOf(.failed, &sent, boss, &more));
    // No longer failed: no button at all.
    try testing.expectEqual(State.none, stateOf(.working, &sent, boss, &now));
    // The same failure, told to somebody else -- another group's
    // supervisor, or the terminal itself: not this press.
    try testing.expectEqual(State.offered, stateOf(.failed, &sent, w2, &now));
    try testing.expectEqual(State.offered, stateOf(.failed, &sent, null, &now));
    // Drawn Failed with nobody failing under it: nothing to tell anyone.
    try testing.expectEqual(State.none, stateOf(.failed, &sent, boss, &.{}));
}

/// A port that writes down what it was asked to do.
const Recorder = struct {
    absent: []const Id = &.{},
    refuse: ?anyerror = null,
    posts: std.ArrayListUnmanaged(Post) = .empty,
    sends: std.ArrayListUnmanaged(Id) = .empty,
    /// Who the last post and the last send were to be typed as.
    post_who: ?Typist = null,
    send_who: ?Typist = null,

    const Post = struct { group: []const u8, text: []const u8, typed: ?Id };

    fn deinit(self: *Recorder) void {
        self.posts.deinit(testing.allocator);
        self.sends.deinit(testing.allocator);
    }

    fn port(self: *Recorder) Port {
        return .{ .ctx = self, .agentPresent = agentPresent, .post = post, .send = send };
    }

    fn agentPresent(ctx: *anyopaque, id: Id) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        return std.mem.indexOfScalar(Id, self.absent, id) == null;
    }

    fn post(ctx: *anyopaque, group: []const u8, text: []const u8, to: []Target, typist: Typist) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.post_who = typist;
        for (to) |*t| t.err = self.refuse;
        try self.posts.append(testing.allocator, .{
            .group = group,
            .text = text,
            .typed = if (to.len > 0 and self.refuse == null) to[0].to else null,
        });
    }

    fn send(ctx: *anyopaque, id: Id, _: []const u8, typist: Typist) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.send_who = typist;
        if (self.refuse) |err| return err;
        try self.sends.append(testing.allocator, id);
    }
};

test "ControlFix: a group's fix is kept in the group and typed into the supervisor" {
    var r: Recorder = .{};
    defer r.deinit();
    try deliver(.{ .group = "build" }, &.{.{ .to = boss, .text = "x" }}, r.port());
    try testing.expectEqual(@as(usize, 1), r.posts.items.len);
    try testing.expectEqualStrings("build", r.posts.items[0].group);
    try testing.expectEqualStrings("x", r.posts.items[0].text);
    try testing.expectEqual(@as(?Id, boss), r.posts.items[0].typed);
    try testing.expectEqual(@as(usize, 0), r.sends.items.len);
    // The person pressed it: not held back by the keyboard clock (task 1738).
    const posted_as = r.post_who;
    try testing.expectEqual(@as(?Typist, .person_elsewhere), posted_as);
}

test "ControlFix: a refused typing is said by its name, and the paragraph is still kept" {
    var r: Recorder = .{ .refuse = error.UserPresent };
    defer r.deinit();
    try testing.expectError(error.UserPresent, deliver(.{ .group = "build" }, &.{.{ .to = boss, .text = "x" }}, r.port()));
    try testing.expectEqual(@as(usize, 1), r.posts.items.len);
}

test "ControlFix: nobody listening: kept, not typed, and refused as NoAgent" {
    var r: Recorder = .{ .absent = &.{boss} };
    defer r.deinit();
    try testing.expectError(error.NoAgent, deliver(.{ .group = "build" }, &.{.{ .to = boss, .text = "x" }}, r.port()));
    try testing.expectEqual(@as(usize, 1), r.posts.items.len);
    try testing.expectEqual(@as(?Id, null), r.posts.items[0].typed);

    // A terminal in no group: nothing to keep it in, and nothing typed.
    var lone: Recorder = .{ .absent = &.{w1} };
    defer lone.deinit();
    try testing.expectError(error.NoAgent, deliver(.{ .terminal = w1 }, &.{.{ .to = w1, .text = "x" }}, lone.port()));
    try testing.expectEqual(@as(usize, 0), lone.posts.items.len);
    try testing.expectEqual(@as(usize, 0), lone.sends.items.len);
}

test "ControlFix: a terminal in no group is typed into, and nothing is posted" {
    var r: Recorder = .{};
    defer r.deinit();
    try deliver(.{ .terminal = w1 }, &.{.{ .to = w1, .text = "x" }}, r.port());
    try testing.expectEqual(@as(usize, 0), r.posts.items.len);
    try testing.expectEqualSlices(Id, &.{w1}, r.sends.items);
    // The person pressed it here too (task 1738).
    const sent_as = r.send_who;
    try testing.expectEqual(@as(?Typist, .person_elsewhere), sent_as);
}

test "ControlFix: several to tell: every one is tried, and the first refusal is the answer" {
    var r: Recorder = .{ .absent = &.{w1} };
    defer r.deinit();
    try testing.expectError(error.NoAgent, deliver(
        .{ .group = "loose" },
        &.{ .{ .to = w1, .text = "a" }, .{ .to = w2, .text = "b" } },
        r.port(),
    ));
    try testing.expectEqual(@as(usize, 2), r.posts.items.len);
    try testing.expectEqual(@as(?Id, null), r.posts.items[0].typed);
    try testing.expectEqual(@as(?Id, w2), r.posts.items[1].typed);
}
