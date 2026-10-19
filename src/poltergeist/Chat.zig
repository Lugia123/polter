//! Groups the terminals talk in.
//!
//! A group is made by the supervisor, which decides who is in it and
//! whether a terminal joining late sees what was said before it arrived.
//! There are no direct messages: a conversation between two terminals is a
//! group with two terminals in it, which is one set of rules instead of two.
//!
//! Kept apart from `Bus`, which is about supervision: who may talk to whom
//! is not who may steer whom, and running them together would make that
//! easy to confuse.
//!
//! What a terminal is *told* when a message arrives is only that there is
//! one, and where. The body is fetched by asking. See
//! `dev-docs/poltergeist/mcp.md`.
//!
//! Pure: time arrives as a parameter, and the only allocation is the log.

const Chat = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");
const Attention = @import("Attention.zig");

pub const Id = Bus.Id;

/// The person at the keyboard.
///
/// Zero, which `Surface.id` is documented never to be, so it cannot
/// collide with a terminal. The user is put in every group as it is made:
/// these are conversations happening on their machine, and a window they
/// can read but not answer in would be a strange thing to build.
pub const user_id: Id = 0;

/// What a terminal added to a group is shown of what came before.
pub const History = enum {
    /// Nothing. The conversation starts for them now.
    none,

    /// Everything still in the log.
    all,
};

pub const Message = struct {
    /// Monotonic within its group, so one cursor per group is enough.
    seq: u64,

    /// Where this landed in the on-disk log, or 0 for a message that
    /// was never written down -- the log is off, or the write failed.
    /// Zero means the view cannot page back past this one.
    log_seq: u64 = 0,

    from: Id,
    at_ms: u64,

    /// True when this stands in for messages the supervisor compacted
    /// away, so a reader can tell a summary from something somebody
    /// actually said.
    summary: bool = false,

    /// Owned by the group.
    text: []const u8,

    /// The terminals this message was addressed to by name, and so should
    /// interrupt even when nothing else in the group would (`waking`).
    ///
    /// The terminals it was *delivered to*, which is not always the ones the
    /// author named: a worker naming a worker is redirected to its
    /// supervisor unless that supervisor has said otherwise
    /// (`Bus.Entry.worker_mentions`), and it is the supervisor who is woken.
    /// Who was originally named is in `text`, for people to read.
    ///
    /// Owned by the group. Empty for nearly every message.
    mentions: []const Id = &.{},

    fn release(self: Message, alloc: Allocator) void {
        alloc.free(self.text);
        if (self.mentions.len > 0) alloc.free(self.mentions);
    }
};

pub const Config = struct {
    /// Messages kept per group before the oldest start falling off.
    max_messages: usize = 1000,

    /// Longest single message. Agents paste log fragments at each other,
    /// and one of them should not be able to fill a group by itself.
    max_text_bytes: usize = 8 * 1024,

    /// Most groups that may exist at once.
    max_groups: usize = 32,
};

pub const Error = error{
    NoSuchGroup,
    GroupExists,
    NotAMember,
    TooManyGroups,
    BadName,

    /// A supervisor is already being started for this group.
    AlreadyStarting,

    /// Nothing to say, or nothing to compact.
    Empty,

    /// A post named somebody who is not in the group. The whole post is
    /// refused: nothing is added and nobody is typed into.
    MentionNotAMember,

    /// A post named its own author.
    MentionSelf,

    /// A post named more terminals than `max_mentions`.
    TooManyMentions,
} || Allocator.Error;

/// Most terminals one post may name. Each one is a line typed into somebody's
/// terminal with a return after it; a post naming the whole group is what a
/// group post already is, without the interruption.
pub const max_mentions = 16;

const Member = struct {
    /// Messages at or below this are not shown to this member: it was
    /// added without history, and this is where its view begins.
    floor: u64 = 0,

    /// Highest seq this member has been shown.
    cursor: u64 = 0,

    /// Whether this member was ever kept out of anything.
    ///
    /// `floor` cannot answer this. A compaction raises the floor of a
    /// member that was barred from nothing -- the summary takes the seq of
    /// the last message it replaces, so the floor has to move past it for
    /// that member to be shown the summary at all. Reading `floor > 0` as
    /// "kept out of something" therefore says yes to a member who was
    /// given the whole history, and `App.chatHistory` acts on exactly that
    /// pair: barred, with no log seq to bound the walk, means hand back
    /// nothing. One compaction would otherwise close `group_history` for
    /// the whole group -- and reaching what a compaction took away is the
    /// only reason that tool exists.
    barred: bool = false,

    /// The log seq of the newest message this member is barred from, or 0
    /// when nothing is barred.
    ///
    /// `floor` says the same thing in the group's own numbering, and that
    /// one cannot bound a walk over the log: the two counters are not
    /// comparable. Without this, a terminal added with `history: none`
    /// could read through `group_history` exactly what it was kept out of.
    log_floor: u64 = 0,

    /// When it was last told this group had messages, for rate limiting.
    last_told_ms: ?u64 = null,

    /// The newest message this member has been told is waiting. A sweep
    /// tells it again only about something newer: sweeps now also run when
    /// a notice is come back for, and without this every one of them would
    /// say "N new messages" about the same N.
    told_seq: u64 = 0,

    /// What it takes to find this terminal again after a restart.
    ///
    /// Recorded by the host when the member joins, because these are facts
    /// the host already has -- asking the supervisor to restate them only
    /// adds a chance to get them wrong.
    ///
    /// None of it is used by the program. It is material handed back to
    /// the supervisor so *it* can work out what to resume and where; see
    /// `dev-docs/poltergeist/supervisor.md`. `Surface.id` is a fresh random
    /// number every run, so it is worthless for this and is not kept.
    footing: Footing = .{},
};

/// Where a member was working, in the words a person would use.
///
/// Two fields, deliberately. The directory is what `claude -r` needs to
/// be run in; the title is how a person tells one terminal from another.
///
/// **The command it was started with is not kept.** Resuming does not
/// replay it -- `claude -r` is a different command from `claude` -- and
/// the title already answers "which one is worker-core". A field nobody
/// reads is a field that goes stale without anyone noticing.
///
/// All owned by the chat. Empty where the host did not know: a bare shell
/// may have no title, and the directory is only known once the shell has
/// reported one.
pub const Footing = struct {
    cwd: []const u8 = "",
    title: []const u8 = "",

    fn deinit(self: *Footing, alloc: Allocator) void {
        if (self.cwd.len > 0) alloc.free(self.cwd);
        if (self.title.len > 0) alloc.free(self.title);
        self.* = .{};
    }

    fn dupe(self: Footing, alloc: Allocator) Allocator.Error!Footing {
        var out: Footing = .{};
        errdefer out.deinit(alloc);

        if (self.cwd.len > 0) out.cwd = try alloc.dupe(u8, self.cwd);
        if (self.title.len > 0) out.title = try alloc.dupe(u8, self.title);
        return out;
    }
};

const Group = struct {
    /// Owned by the chat, and also the key it is stored under.
    name: []const u8,
    created_by: Id,
    next_seq: u64 = 1,
    log: std.ArrayListUnmanaged(Message) = .empty,
    members: std.AutoHashMapUnmanaged(Id, Member) = .empty,

    /// What this group is for, in the supervisor's own words. Owned.
    ///
    /// A memo it writes to itself: after eight hours `group_list` says
    /// "build, research, nightly" and the session that named them has long
    /// since lost that context -- which is exactly when it has to decide
    /// which one still needs watching.
    ///
    /// Opaque to the program. It is never parsed, never matched on, and has
    /// no status of its own; see `dev-docs/poltergeist/mcp.md` for why that
    /// last part is the line between keeping a note and managing a task.
    brief: []const u8 = "",

    /// When anything was last said in here, for the order the list is in.
    ///
    /// Kept as its own field rather than read off the back of `log`,
    /// because `log` is a working set: it trims, the supervisor compacts
    /// it on purpose, and a group restored after a restart has none at
    /// all. Every one of those would make a group that was busy last night
    /// look like a group nobody has ever used.
    last_ms: u64 = 0,

    /// What the person has said about this group in the control room. This
    /// is what is written down and comes back.
    marks: Marks = .none,

    /// When, on the bus's clock and in this run, the person last looked and
    /// last snoozed. Null for a mark that came back off disk: nothing that
    /// has happened in this run has been seen yet, and a restart is a
    /// change of state as far as a snooze is concerned.
    seen_run_ms: ?u64 = null,
    snoozed_run_ms: ?u64 = null,

    /// The supervisor this group last had: where it worked, what it was
    /// and the session it was in. Owned. It is written down (`GroupLog`)
    /// and comes back, because the morning after is when it is asked for:
    /// the group is there, its supervisor is not, and the person is about
    /// to start one.
    last_supervisor: LastSupervisor = .none,

    /// A supervisor the person is starting for this group from the control
    /// room, until it is one or has failed to be. This run's only.
    start: ?Start = null,

    /// The terminal the control room started as this group's supervisor,
    /// once it was one. This run's only: it is how that terminal's `me`
    /// says which group it was started for.
    started: ?Id = null,

    /// The project this group is tied to, or that it has none. Owned;
    /// written down (`GroupLog`) and comes back.
    project: ProjectTie = .undecided,

    /// The supervisor that took this group up in this run: what offering
    /// an old group a project goes by (`Projects`). This run's only.
    project_claim: ?ProjectClaim = null,

    /// How many times the person answered "Not Now" to joining the group
    /// to the project of its name (task 1713). Written down; after two the
    /// question is not put again, and only the banner stays.
    project_not_now: u8 = 0,
    /// "Not Now" was said in this run: the question waits for the next
    /// one. This run's only.
    project_not_now_said: bool = false,

    fn deinit(self: *Group, alloc: Allocator) void {
        for (self.log.items) |m| m.release(alloc);
        self.log.deinit(alloc);
        if (self.brief.len > 0) alloc.free(self.brief);
        self.last_supervisor.free(alloc);
        self.project.free(alloc);

        var it = self.members.valueIterator();
        while (it.next()) |m| m.footing.deinit(alloc);
        self.members.deinit(alloc);
        alloc.free(self.name);
    }

    fn head(self: *const Group) u64 {
        return self.next_seq - 1;
    }
};

alloc: Allocator,
config: Config,

/// Keyed by name, which is what agents use to refer to one.
groups: std.StringHashMapUnmanaged(Group) = .empty,

pub fn init(alloc: Allocator, config: Config) Chat {
    return .{ .alloc = alloc, .config = config };
}

pub fn deinit(self: *Chat) void {
    var it = self.groups.valueIterator();
    while (it.next()) |g| g.deinit(self.alloc);
    self.groups.deinit(self.alloc);
    self.* = undefined;
}

/// Group names get passed around by agents, so they are restricted rather
/// than sanitised: lowercase, digits and dashes.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > 48) return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

/// Make a group. The creator is its first member and sees everything in
/// it, there being nothing yet to miss.
pub fn create(self: *Chat, name: []const u8, by: Id) Error!void {
    if (!isValidName(name)) return error.BadName;
    if (self.groups.contains(name)) return error.GroupExists;
    if (self.groups.count() >= self.config.max_groups) return error.TooManyGroups;

    const owned = try self.alloc.dupe(u8, name);

    // No `errdefer` on `owned` itself: from here on the group owns it, and
    // `Group.deinit` frees it. Two errdefers over one allocation would free
    // it twice on the way out of a failed `put`.
    var group: Group = .{ .name = owned, .created_by = by };
    errdefer group.deinit(self.alloc);
    try group.members.put(self.alloc, by, .{});

    try self.groups.put(self.alloc, owned, group);
}

/// Put back a group that existed before the restart -- its name, its note,
/// and when it was last used. **Not its members.**
///
/// This is where the line drawn in `README.md`'s third open question is
/// actually cut, and the cut is not a compromise. That question refused to
/// restore a conversation automatically because doing so would need the
/// program to decide "is this terminal on screen now the one that was in
/// this group last night", which is a judgement, and judgements belong to
/// the supervisor (P1). **That argument is only about the members.** A
/// group's name is a string; putting a string back needs nobody to decide
/// anything.
///
/// So the program restores what needs no judgement and the supervisor
/// restores what does. A shell comes back with nobody in it but the person
/// at the keyboard, and stays that way until a supervisor puts terminals
/// in it -- which is the exact meaning of taking a group up again.
///
/// The creator is `user_id`, which is not a claim that the person made it:
/// it is the absence of one. Who made it is not written down anywhere the
/// record can answer, and a made-up owner would be worse than none --
/// `rpc` reads owner zero as "no supervisor's to keep", so the first one
/// to take the group up can, rather than nobody ever being able to.
pub fn restoreShell(
    self: *Chat,
    name: []const u8,
    brief: []const u8,
    last_ms: u64,
    /// What the person had said about it in the control room, off the same
    /// record. **Not optional**: these were written down from the start and
    /// read back by nobody, so a snooze "until four" ended at every restart
    /// and nothing looked wrong. A caller with none to give says `.none`.
    marks: Marks,
) Error!void {
    // Already here means this is a second start of the same run, or a
    // group the supervisor has just made. Either way what is in memory is
    // newer than what is on disk, and the disk does not get to overwrite
    // it.
    if (self.groups.contains(name)) return error.GroupExists;

    try self.create(name, user_id);

    const group = self.groups.getPtr(name).?;
    group.last_ms = last_ms;

    // After `create`, so a note too long to store leaves a group with no
    // note rather than no group.
    //
    // The cut is discarded here and nowhere else: this is a brief coming
    // back off disk, so whatever cut there was happened when it was first
    // written, and was reported then. Telling anybody now would be
    // reporting a restart as if it were an edit.
    if (brief.len > 0) _ = try self.setBrief(name, brief);

    // As marks that came back, not as marks made now: nothing that happens
    // in this run has been looked at yet (`restoreMarks`).
    try self.restoreMarks(name, marks);
}

/// Whether anybody is working in this group right now.
///
/// **The membership list crossed with the terminals that actually exist,
/// not the list on its own.** A member is an id somebody wrote down once;
/// a live terminal is one the host still has open. The list alone is only
/// as true as the code that prunes it -- `Surface.deinit` takes a closing
/// terminal out of every group through `forget`, and if that one call ever
/// stopped happening, every group a closed terminal was ever in would read
/// as active for ever. A rule that is right only while some other file has
/// no bugs in it is a rule that has handed its correctness to that file.
/// So this asks the question directly instead, and would still answer it
/// correctly if the pruning went away.
///
/// One condition, not a chain of them: the question is "is any member of
/// this group a terminal that is open", and that is what is computed. What
/// changed against counting members is which set is being asked about, not
/// how many tests there are.
///
/// `live` is the ids the host has open now, passed in because this file is
/// the model -- it has no windows, no clock and no disk, and giving it the
/// app to ask would be the end of that. The person at the keyboard needs
/// no special case: `user_id` is zero and a terminal id is documented
/// never to be, so the user is never in `live`, and a group with nobody
/// but them in it is inactive -- which is exactly what it is.
///
/// O(live), where `live` is however many terminals are open. Single
/// figures, and a hash lookup each.
pub fn isActive(self: *const Chat, name: []const u8, live: []const Id) bool {
    const group = self.groups.getPtr(name) orelse return false;
    for (live) |id| if (group.members.contains(id)) return true;
    return false;
}

/// Set what a group is for. Only the supervisor gets here; the caller
/// checks that, because the chat does not know about roles.
///
/// Replaces rather than appends: it is one note, kept current, not a
/// history of intentions.
///
/// **Returns what was actually stored, and the caller may not ignore it.**
/// This used to return nothing, so a brief too long to keep was cut here
/// in silence and `group_set_brief` answered `ok`. That is the same shape
/// as the bug this whole area was opened for: what the writer sees is not
/// what the reader gets. A supervisor's round-opening brief is exactly the
/// text that runs long, and the part that falls off the end is the part
/// written last -- which, in the one real case, was the list of rules.
///
/// A count rather than a flag, because "it was cut" is not actionable and
/// "you wrote N and M were kept" is. Returning it forces the question to
/// be answered at every call site: `void` is what let it go unasked.
pub fn setBrief(
    self: *Chat,
    name: []const u8,
    text: []const u8,
) Error!Kept {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;

    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const kept = utf8Cut(trimmed, self.config.max_text_bytes);

    // Copied before the old one goes, so a failure here leaves the
    // previous note intact rather than blanking it.
    const owned = try self.alloc.dupe(u8, kept);
    if (group.brief.len > 0) self.alloc.free(group.brief);
    group.brief = owned;

    return .{ .given = trimmed.len, .kept = kept.len };
}

/// What `setBrief` did with the text it was handed.
///
/// `given` is after trimming, so trailing whitespace is not reported as
/// something that went missing.
pub const Kept = struct {
    given: usize,
    kept: usize,

    /// Whether anything fell off the end.
    pub fn cut(self: Kept) bool {
        return self.kept < self.given;
    }
};

/// What the person has said about a group: that they looked at it, and that
/// they want it left alone for now. Times are the wall clock's, because
/// this is what is written to disk and read back in another run.
pub const Marks = struct {
    seen_ms: ?u64,
    snooze: Snooze,
    /// Kept at the front of its section in the control room (task 1659).
    pinned: bool,
    /// No system notification about it while this stands; its card is
    /// shown as ever (task 1659).
    mute: Mute,
    /// When it was archived, on the wall clock; null while it is listed.
    /// An archived group is off the control room's list and raises no
    /// notification, and nothing else changes: its terminals, its talk and
    /// its panel go on (task 1659).
    archived_ms: ?u64,

    pub const none: Marks = .{
        .seen_ms = null,
        .snooze = .none,
        .pinned = false,
        .mute = .none,
        .archived_ms = null,
    };

    pub const Mute = union(enum) {
        none,
        /// Until this moment on the wall clock, and then not: an expired
        /// mute reads as `none` (`muteOf`) without anybody clearing it.
        until: u64,
        forever,
    };

    pub const Snooze = union(enum) {
        none,
        /// Set at this time; ends when the group's state next changes.
        next_event: u64,
        until: struct { at_ms: u64, until_ms: u64 },
    };
};

pub fn marksOf(self: *const Chat, name: []const u8) Error!Marks {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    return group.marks;
}

/// The person looked at this group. `now_ms` is the bus's clock, `wall_ms`
/// the real one; both are kept, because what there is to have seen is
/// timed on the first and what is written down has to be the second.
pub fn markSeen(self: *Chat, name: []const u8, now_ms: u64, wall_ms: u64) Error!void {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    group.marks.seen_ms = wall_ms;
    group.seen_run_ms = now_ms;
}

/// When the person last looked, on the bus's clock, or null if they have
/// not in this run.
pub fn seenRunMs(self: *const Chat, name: []const u8) ?u64 {
    const group = self.groups.getPtr(name) orelse return null;
    return group.seen_run_ms;
}

pub fn setSnooze(self: *Chat, name: []const u8, snooze: Marks.Snooze, now_ms: u64) Error!void {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    group.marks.snooze = snooze;
    group.snoozed_run_ms = if (snooze == .none) null else now_ms;
}

/// The group's snooze in the terms `Attention` judges it in: on the bus's
/// clock, as of now.
pub fn snoozeOf(self: *const Chat, name: []const u8, now_ms: u64, wall_ms: u64) Attention.Snooze {
    const group = self.groups.getPtr(name) orelse return .none;
    return switch (group.marks.snooze) {
        .none => .none,
        .next_event => .{ .until_change = group.snoozed_run_ms orelse 0 },
        .until => |u| .{ .until_ms = now_ms +| (u.until_ms -| wall_ms) },
    };
}

pub fn setPinned(self: *Chat, name: []const u8, pinned: bool) Error!void {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    group.marks.pinned = pinned;
}

pub fn setMute(self: *Chat, name: []const u8, mute: Marks.Mute) Error!void {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    group.marks.mute = mute;
}

/// The group's mute as it stands at `wall_ms`: one whose moment has passed
/// is over, whatever is still written down.
pub fn muteOf(self: *const Chat, name: []const u8, wall_ms: u64) Marks.Mute {
    const group = self.groups.getPtr(name) orelse return .none;
    return switch (group.marks.mute) {
        .until => |until| if (until > wall_ms) group.marks.mute else .none,
        .none, .forever => group.marks.mute,
    };
}

/// Archive the group at `wall_ms`, or with null take it out of the archive.
/// Archiving again keeps the first moment.
pub fn setArchived(self: *Chat, name: []const u8, wall_ms: ?u64) Error!void {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    if (wall_ms != null and group.marks.archived_ms != null) return;
    group.marks.archived_ms = wall_ms;
}

/// Put back what the disk remembered of the person's marks on a group.
pub fn restoreMarks(self: *Chat, name: []const u8, marks: Marks) Error!void {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    group.marks = marks;
    group.seen_run_ms = null;
    group.snoozed_run_ms = null;
}

/// When anything was last said in this group; the wall clock's.
pub fn lastMsOf(self: *const Chat, name: []const u8) u64 {
    const group = self.groups.getPtr(name) orelse return 0;
    return group.last_ms;
}

/// Who made this group.
///
/// With several supervisors in a window, a group belongs to the one that
/// made it: otherwise any supervisor could destroy another's group, or
/// pull terminals out of it, and the first anybody would know is that a
/// conversation had stopped working.
pub fn createdBy(self: *const Chat, name: []const u8) Error!Id {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    return group.created_by;
}

/// Whether `id` is in `name`. False for a group that is not there at all.
pub fn hasMember(self: *const Chat, name: []const u8, id: Id) bool {
    const group = self.groups.getPtr(name) orelse return false;
    return group.members.contains(id);
}

/// What a group is for, or empty when nobody has said.
///
/// Everybody who can see the group can see this -- it is how a round of
/// work is handed over, not a memo the supervisor keeps to itself. It is
/// still not carried by `read`: it belongs to the group, not to any one
/// message, and repeating it in the stream would bury the conversation.
pub fn briefOf(self: *const Chat, name: []const u8) Error![]const u8 {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    return group.brief;
}

pub fn destroy(self: *Chat, name: []const u8) Error!void {
    const entry = self.groups.fetchRemove(name) orelse return error.NoSuchGroup;
    var group = entry.value;
    group.deinit(self.alloc);
}

/// Give a group a new name. It is the same group: its members, what each
/// can see, where each has read to, its note, its owner and its messages
/// are all kept, because nothing is copied -- the one entry is re-keyed.
///
/// The check on the new name is `isValidName`, the same function `create`
/// uses. Renaming to the name it already has succeeds and changes nothing.
///
/// Memory only. What is on disk under the old name is `GroupRename`'s, and
/// it has already been dealt with by the time this is called.
///
/// Nothing can fail after the group leaves the table: every allocation
/// happens first, so a refusal leaves the group exactly where it was.
pub fn rename(self: *Chat, old: []const u8, new: []const u8) Error!void {
    if (!self.groups.contains(old)) return error.NoSuchGroup;
    if (!isValidName(new)) return error.BadName;
    if (std.mem.eql(u8, old, new)) return;
    if (self.groups.contains(new)) return error.GroupExists;

    const owned = try self.alloc.dupe(u8, new);
    errdefer self.alloc.free(owned);
    try self.groups.ensureUnusedCapacity(self.alloc, 1);

    var group = self.groups.fetchRemove(old).?.value;
    self.alloc.free(group.name);
    group.name = owned;
    self.groups.putAssumeCapacity(owned, group);
}

/// Put a terminal in a group, deciding what it sees of what came before.
pub fn add(
    self: *Chat,
    name: []const u8,
    id: Id,
    history: History,
    footing: Footing,
) Error!void {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;

    // Already in it: leave its view alone rather than silently rewriting
    // what it can see.
    if (group.members.contains(id)) return;

    var owned = try footing.dupe(self.alloc);
    errdefer owned.deinit(self.alloc);

    try group.members.put(self.alloc, id, switch (history) {
        // Nothing before now, and nothing waiting. The same line drawn
        // twice: once in the group's numbering, once in the log's, because
        // reading back through the log is bounded by the latter and there
        // is no converting between them.
        .none => .{
            .floor = group.head(),
            .cursor = group.head(),
            .barred = true,

            // Only as far as what the group still holds. The file very
            // often holds more -- after a restart the group is empty while
            // last night is still on disk -- and the model cannot see that
            // far. `setLogFloor` is how the host finishes this off.
            .log_floor = if (group.log.items.len > 0)
                group.log.items[group.log.items.len - 1].log_seq
            else
                0,
            .footing = owned,
        },

        // Everything, and all of it unread and worth fetching.
        .all => .{ .floor = 0, .cursor = 0, .footing = owned },
    });
}

/// Where a member was working, or null if it is not in this group.
pub fn footingOf(self: *const Chat, name: []const u8, id: Id) ?Footing {
    const group = self.groups.getPtr(name) orelse return null;
    const m = group.members.get(id) orelse return null;
    return m.footing;
}

/// Update where a member is working.
///
/// A terminal's title changes as it works, and its directory can too. The
/// record has to follow, or a restart tomorrow would resume it wherever
/// it happened to be when it joined.
pub fn setFooting(self: *Chat, name: []const u8, id: Id, footing: Footing) Error!void {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    const m = group.members.getPtr(id) orelse return error.NotAMember;

    var owned = try footing.dupe(self.alloc);
    errdefer owned.deinit(self.alloc);

    m.footing.deinit(self.alloc);
    m.footing = owned;
}

pub fn remove(self: *Chat, name: []const u8, id: Id) Error!void {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    if (group.members.fetchRemove(id)) |kv| {
        var m = kv.value;
        m.footing.deinit(self.alloc);
    }
}

pub fn isMember(self: *const Chat, name: []const u8, id: Id) bool {
    const group = self.groups.getPtr(name) orelse return false;
    return group.members.contains(id);
}

/// Whether two terminals are members of at least one group together.
///
/// Membership and nothing finer: not who made the group, not whether
/// either has read anything in it. A group restored after a restart has
/// its name and nobody in it, so it joins nobody to anybody until they are
/// added back -- which is the same judgement `group_list` leaves to the
/// supervisor.
pub fn sharesGroup(self: *const Chat, one: Id, other: Id) bool {
    var it = self.groups.valueIterator();
    while (it.next()) |group| {
        if (group.members.contains(one) and group.members.contains(other)) return true;
    }
    return false;
}

/// The answer the bus asks for when a watched terminal has no minder and
/// there is more than one supervisor to hear about it (#1064): the ones in
/// a group with it. The chat depends on the bus, never the other way
/// round, so the bus names the question (`Bus.Peers`) and this is the only
/// place that knows groups are how it is answered.
///
/// ⚠️ Holds a pointer to this chat: for the length of one call, not to be
/// kept.
pub fn peers(self: *const Chat) Bus.Peers {
    return .{ .ctx = self, .shareFn = sharesGroupOpaque };
}

test "Chat: \"Not Now\" to joining a project holds for the run, and after twice for good (#1713)" {
    var chat = testChat();
    defer chat.deinit();
    try chat.create("polter", 0x1);
    try testing.expect(chat.projectAsk("polter"));
    try testing.expectEqual(@as(u8, 1), try chat.sayProjectNotNow("polter"));
    try testing.expect(!chat.projectAsk("polter"));
    // Saying it again in the same run counts once.
    try testing.expectEqual(@as(u8, 1), try chat.sayProjectNotNow("polter"));

    // The next start: what was written down comes back, and it is asked once more.
    var next = testChat();
    defer next.deinit();
    try next.create("polter", 0x1);
    next.restoreProjectNotNow("polter", 1);
    try testing.expect(next.projectAsk("polter"));
    try testing.expectEqual(@as(u8, 2), try next.sayProjectNotNow("polter"));

    // And the one after: never again.
    var last = testChat();
    defer last.deinit();
    try last.create("polter", 0x1);
    last.restoreProjectNotNow("polter", 2);
    try testing.expect(!last.projectAsk("polter"));
    try testing.expect(!last.projectAsk("nope"));
    try testing.expectError(error.NoSuchGroup, last.sayProjectNotNow("nope"));
}

test "#1265: a renamed group is the same group" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("old", boss);
    try chat.add("old", a, .none, .{ .cwd = "/work", .title = "worker" });
    _ = try chat.setBrief("old", "the note");
    const first = try chat.post("old", boss, "before", 1);
    _ = try chat.post("old", boss, "second", 2);
    chat.setLogFloor("old", a, 77);
    const floor_before = try chat.floorOf("old", a);

    try chat.rename("old", "new");

    // Not under the old name any more, and not under two names.
    try testing.expect(!chat.exists("old"));
    try testing.expect(chat.exists("new"));
    try testing.expectEqual(@as(u32, 1), chat.groups.count());

    // Members, their floors, the note, the owner: all of it came along.
    try testing.expectEqualStrings("the note", try chat.briefOf("new"));
    try testing.expectEqual(boss, chat.groups.get("new").?.created_by);
    const floor_after = try chat.floorOf("new", a);
    try testing.expectEqual(floor_before, floor_after);
    try testing.expectEqual(@as(u64, 77), floor_after.log_seq);
    try testing.expectEqualStrings("/work", chat.footingOf("new", a).?.cwd);
    try testing.expectEqualStrings("worker", chat.footingOf("new", a).?.title);

    // The words said before the rename are readable under the new name.
    const batch = try chat.read(testing.allocator, "new", boss, 0, .unlimited);
    defer testing.allocator.free(batch.messages);
    try testing.expectEqual(@as(usize, 2), batch.messages.len);
    try testing.expectEqualStrings("before", batch.messages[0].text);
    try testing.expectEqual(first.seq, batch.messages[0].seq);

    // And the next message carries on the same numbering.
    const next = try chat.post("new", boss, "after", 3);
    try testing.expectEqual(first.seq + 2, next.seq);
}

test "#1265: renaming is refused by name, and a refusal changes nothing" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("old", boss);
    try chat.create("taken", boss);
    _ = try chat.setBrief("old", "kept");

    try testing.expectError(error.NoSuchGroup, chat.rename("nope", "fresh"));
    try testing.expectError(error.BadName, chat.rename("old", "Has Spaces"));
    try testing.expectError(error.BadName, chat.rename("old", "../escape"));
    try testing.expectError(error.BadName, chat.rename("old", ""));
    try testing.expectError(error.GroupExists, chat.rename("old", "taken"));

    try testing.expect(chat.exists("old"));
    try testing.expect(chat.exists("taken"));
    try testing.expectEqualStrings("kept", try chat.briefOf("old"));

    // Same name: a success that does nothing.
    try chat.rename("old", "old");
    try testing.expect(chat.exists("old"));
}

test "#1265: a group with terminals in it can be renamed" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("old", boss);
    try chat.add("old", a, .all, .{});
    try chat.add("old", b, .all, .{});
    try chat.rename("old", "new");

    var live = [_]Id{ a, b };
    try testing.expect(chat.isActive("new", &live));
}

fn sharesGroupOpaque(ctx: ?*const anyopaque, supervisor: Id, terminal: Id) bool {
    const self: *const Chat = @ptrCast(@alignCast(ctx.?));
    return self.sharesGroup(supervisor, terminal);
}

/// Where a member's view of a group begins, in both numberings.
pub const Floor = struct { seq: u64 = 0, log_seq: u64 = 0, barred: bool = false };

/// Where this member's view of the group begins, in both numberings.
///
/// One call rather than two, because membership and how far back the
/// member may look are the same fact: a reader that asked "is it in the
/// group" and stopped there would hand a terminal added with
/// `history: none` everything it was added specifically not to see.
pub fn floorOf(self: *const Chat, name: []const u8, id: Id) Error!Floor {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    const m = group.members.get(id) orelse return error.NotAMember;
    return .{ .seq = m.floor, .log_seq = m.log_floor, .barred = m.barred };
}

pub fn exists(self: *const Chat, name: []const u8) bool {
    return self.groups.contains(name);
}

// -- a supervisor being started from the control room -------------------------

/// A supervisor on its way to a group: asked for in the control room, not
/// one yet.
///
/// It is three waits in a row, and each can fail on its own: for the tab
/// (`terminal` is null), for the agent in it to connect, and then nothing --
/// the terminal is put in the group and this is cleared. **A wait that ran
/// out is not cleared**: it stays, reading as failed, so the control room
/// can say which wait it was instead of going back to a button as though
/// nothing had been tried.
pub const Start = struct {
    /// The terminal it is being started in; null until the tab exists.
    terminal: ?Id,
    /// Past this, the wait it is in has failed.
    deadline_ms: u64,
    /// Set when it failed for a reason that is not a wait running out.
    failed: StartFailure = .none,
    /// Whether it was started to go on with the last supervisor's session.
    /// A try that did and made no supervisor is a reason not to try the
    /// same session again by default (`StartView.resuming`).
    resuming: bool,
    /// How its terminal comes to be: a tab asked for, or the group's
    /// project opened by the host (`Projects`, the `open` order).
    by: StartBy,
    /// The CLI in its tab is asking the person a question before it will
    /// start -- Antigravity's folder trust box (`Plugin.StartupSays`).
    /// While it is, the wait does not run out (`startAsking`): the answer
    /// is the person's, and nobody else may give it (task 1746).
    asking: bool,
};

pub const StartBy = enum { directory, project };

/// Why a start did not make a supervisor.
pub const StartFailure = enum {
    none,
    /// The tab for it never appeared.
    terminal_never_opened,
    /// It was to start in its group's project, and the host never said the
    /// project was open (task 1794). Not `terminal_never_opened`: a project
    /// that did open with no pane marked for its supervisor is started in a
    /// new tab of it instead (`startByDirectory`), so what is left here is
    /// the project itself not coming.
    project_never_opened,
    /// The tab is there and no agent connected from it: the CLI did not
    /// start, or started and never reached Polter.
    agent_never_connected,
    /// Its terminal was closed before the agent connected.
    terminal_closed,
    /// `+launch` said so itself, in the tab: the CLI's program is not
    /// there to run.
    cli_not_found,
    /// `+launch` said so itself: something else stopped it before the CLI
    /// ran. The tab has the line that says what.
    cli_did_not_start,
};

/// The reason a start failed for, when its launcher said its CLI did not
/// start. A mapping and nothing else, here so that it can be tested
/// without an app.
pub fn startFailureOf(why: @import("agent_event.zig").LaunchFailure) StartFailure {
    return switch (why) {
        .not_found => .cli_not_found,
        .failed => .cli_did_not_start,
        // Started and gone, or never heard from: either way no agent
        // reached Polter (task 1712).
        .exited, .no_agent => .agent_never_connected,
    };
}

/// What the control room shows of a start.
pub const StartView = struct {
    state: enum { none, starting, failed },
    failed: StartFailure,
    terminal: ?Id,
    /// When a start that is still waiting stops waiting; null otherwise.
    /// What the snapshot asks to be woken at.
    deadline_ms: ?u64,
    /// The start this is of was to go on with the last session.
    resuming: bool,
    /// How its terminal comes to be; null when there is no start.
    by: ?StartBy,
    /// Its CLI is waiting for the person to answer a question in its tab
    /// (`Start.asking`). Only ever with `starting`.
    asking: bool,

    pub const none: StartView = .{ .state = .none, .failed = .none, .terminal = null, .deadline_ms = null, .resuming = false, .by = null, .asking = false };
};

/// Where `name`'s start stands at `now_ms`.
pub fn startOf(self: *const Chat, name: []const u8, now_ms: u64) StartView {
    const group = self.groups.getPtr(name) orelse return .none;
    const s = group.start orelse return .none;
    if (s.failed != .none) return .{ .state = .failed, .failed = s.failed, .terminal = s.terminal, .deadline_ms = null, .resuming = s.resuming, .by = s.by, .asking = false };
    if (now_ms > s.deadline_ms) return .{
        .state = .failed,
        .failed = timedOut(s.by, s.terminal != null),
        .terminal = s.terminal,
        .deadline_ms = null,
        .resuming = s.resuming,
        .by = s.by,
        .asking = false,
    };
    return .{ .state = .starting, .failed = .none, .terminal = s.terminal, .deadline_ms = s.deadline_ms, .resuming = s.resuming, .by = s.by, .asking = s.asking };
}

/// Why a start that ran out of time failed: what it was still waiting for
/// (task 1794). A start in a project that never got a terminal was waiting
/// for the project; one in a directory, for its tab.
pub fn timedOut(by: StartBy, has_terminal: bool) StartFailure {
    if (has_terminal) return .agent_never_connected;
    return switch (by) {
        .project => .project_never_opened,
        .directory => .terminal_never_opened,
    };
}

/// A start waiting for its project, which the host has stated open with no
/// pane marked as the supervisor's, goes on as a start in a directory
/// (task 1794): its tab is the next one, and `deadline_ms` is the tab's.
/// Answers whether it was such a start; any other is left as it is.
pub fn startByDirectory(self: *Chat, name: []const u8, deadline_ms: u64) bool {
    const group = self.groups.getPtr(name) orelse return false;
    const s = if (group.start) |*v| v else return false;
    if (s.by != .project or s.terminal != null or s.failed != .none) return false;
    s.by = .directory;
    s.deadline_ms = deadline_ms;
    return true;
}

/// Begin a start: the tab has been asked for and is waited for until
/// `deadline_ms`. Refused while one is still waiting; one that failed is
/// replaced, which is what trying again is.
///
/// `resuming` says whether it is to go on with the last supervisor's
/// session; it is kept so that a try which did and failed can be told
/// from one that started afresh and failed.
pub fn beginStart(self: *Chat, name: []const u8, now_ms: u64, deadline_ms: u64, resuming: bool, by: StartBy) Error!void {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    if (self.startOf(name, now_ms).state == .starting) return error.AlreadyStarting;
    group.start = .{ .terminal = null, .deadline_ms = deadline_ms, .resuming = resuming, .by = by, .asking = false };
}

/// The tab exists: it is `terminal`, and its agent is waited for until
/// `deadline_ms`.
pub fn startOpened(self: *Chat, name: []const u8, terminal: Id, deadline_ms: u64) void {
    const group = self.groups.getPtr(name) orelse return;
    const s = if (group.start) |*v| v else return;
    if (s.failed != .none) return;
    s.terminal = terminal;
    s.deadline_ms = deadline_ms;
}

/// Whether the CLI in a start's tab is asking the person something now
/// (`Start.asking`). While it is, the wait for its agent is held at
/// `deadline_ms` or later -- the same minute again, counted from the last
/// time the question was seen up, so a person who takes their time over it
/// is not told the start failed, and the wait runs again once it is gone.
/// Only a start that has its tab and is still waiting is touched. Answers
/// whether what the control room shows of it changed.
pub fn startAsking(self: *Chat, name: []const u8, asking: bool, deadline_ms: u64, now_ms: u64) bool {
    const group = self.groups.getPtr(name) orelse return false;
    const s = if (group.start) |*v| v else return false;
    if (s.terminal == null or s.failed != .none or now_ms > s.deadline_ms) return false;
    if (asking) s.deadline_ms = @max(s.deadline_ms, deadline_ms);
    const changed = s.asking != asking;
    s.asking = asking;
    return changed;
}

/// The group whose start is still waiting for its tab, if there is one.
/// A terminal that has just appeared for the person's launch is that tab.
pub fn startAwaitingTerminal(self: *const Chat, now_ms: u64) ?[]const u8 {
    var it = self.groups.valueIterator();
    while (it.next()) |g| {
        const s = g.start orelse continue;
        // One waiting for its project is waiting for the host to say
        // which terminal, not for the next tab anybody opens: opening a
        // project makes many.
        if (s.by != .directory) continue;
        if (s.terminal == null and s.failed == .none and now_ms <= s.deadline_ms) return g.name;
    }
    return null;
}

/// Whether `name`'s start is still waiting for the host to open its
/// project and say which terminal is the supervisor's.
pub fn startAwaitingProject(self: *const Chat, name: []const u8, now_ms: u64) bool {
    const group = self.groups.getPtr(name) orelse return false;
    const s = group.start orelse return false;
    return s.by == .project and s.terminal == null and s.failed == .none and now_ms <= s.deadline_ms;
}

/// The group `terminal` is being started as the supervisor of, while that
/// is still being waited for.
pub fn startingIn(self: *const Chat, terminal: Id, now_ms: u64) ?[]const u8 {
    var it = self.groups.valueIterator();
    while (it.next()) |g| {
        const s = g.start orelse continue;
        if (s.terminal != null and s.terminal.? == terminal and s.failed == .none and
            now_ms <= s.deadline_ms) return g.name;
    }
    return null;
}

/// The start is over: it made a supervisor, or the person's next try
/// replaces it.
pub fn endStart(self: *Chat, name: []const u8) void {
    const group = self.groups.getPtr(name) orelse return;
    group.start = null;
}

/// The start made a supervisor: `terminal` is it. The start is over, and
/// that terminal is remembered as the one this group was started with.
pub fn startMade(self: *Chat, name: []const u8, terminal: Id) void {
    const group = self.groups.getPtr(name) orelse return;
    group.start = null;
    group.started = terminal;
}

/// The group the control room started `terminal` as the supervisor of, in
/// this run; null for a terminal that was not started that way. When it
/// was started for more than one, the one whose name sorts first -- the
/// same answer every time.
pub fn startedFor(self: *const Chat, terminal: Id) ?[]const u8 {
    var best: ?[]const u8 = null;
    var it = self.groups.valueIterator();
    while (it.next()) |g| {
        if (g.started == null or g.started.? != terminal) continue;
        if (best == null or std.mem.lessThan(u8, g.name, best.?)) best = g.name;
    }
    return best;
}

/// The start failed, for a reason that is not a wait running out.
pub fn failStart(self: *Chat, name: []const u8, why: StartFailure) void {
    const group = self.groups.getPtr(name) orelse return;
    if (group.start) |*s| {
        if (s.failed == .none) s.failed = why;
    }
}

/// A group's tie to a project (`Projects`). One group, one project; the
/// project bears the group's name once the host has caught up, and until
/// then `bound` holds the name the host has it under.
///
/// **Three answers, and the first two are not the same "no".** A record
/// from before there were ties is `undecided`: nobody has said, and the
/// group is offered a project when a supervisor takes it up. `declined`
/// is its supervisor saying it has none, and it is offered nothing until
/// the supervisor says otherwise.
pub const ProjectTie = union(enum) {
    undecided,
    declined,
    /// The project's name, owned by whoever holds the tie.
    bound: []const u8,

    pub fn eql(self: ProjectTie, other: ProjectTie) bool {
        return switch (self) {
            .undecided => other == .undecided,
            .declined => other == .declined,
            .bound => |name| other == .bound and std.mem.eql(u8, name, other.bound),
        };
    }

    pub fn dupe(self: ProjectTie, alloc: Allocator) Allocator.Error!ProjectTie {
        return switch (self) {
            .undecided, .declined => self,
            .bound => |name| .{ .bound = try alloc.dupe(u8, name) },
        };
    }

    /// Only for one `dupe` made.
    pub fn free(self: ProjectTie, alloc: Allocator) void {
        switch (self) {
            .undecided, .declined => {},
            .bound => |name| alloc.free(name),
        }
    }
};

/// A supervisor taking a group up: started for it, joining it, making it,
/// or saying outright that the group uses the project it is in.
pub const ProjectClaim = struct {
    terminal: Id,
    /// Said by the supervisor (`group_project`), not worked out. What the
    /// core would not pick between -- which of two supervisors, which of a
    /// supervisor's two groups -- the supervisor has then picked.
    said: bool,
};

/// `name`'s tie to a project; `undecided` for a group that is not there.
/// Borrowed until the next `setProject` for it.
pub fn projectOf(self: *const Chat, name: []const u8) ProjectTie {
    const group = self.groups.getPtr(name) orelse return .undecided;
    return group.project;
}

/// Replace `name`'s tie. True when it changed.
pub fn setProject(self: *Chat, name: []const u8, tie: ProjectTie) Error!bool {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    if (group.project.eql(tie)) return false;
    const owned = try tie.dupe(self.alloc);
    group.project.free(self.alloc);
    group.project = owned;
    return true;
}

/// The most times "Not Now" may be said before the question stops being
/// put: once in a run, and once more at the next start (task 1713).
pub const project_not_now_most = 2;

/// Whether the person should be asked to join `name` to the project of its
/// name now, given that one is in the way (`Projects.Why.project_name_taken`):
/// not when "Not Now" was said in this run, nor after it was said
/// `project_not_now_most` times. A group that is not there is never asked.
pub fn projectAsk(self: *const Chat, name: []const u8) bool {
    const group = self.groups.getPtr(name) orelse return false;
    return !group.project_not_now_said and group.project_not_now < project_not_now_most;
}

/// Say "Not Now" for `name`: not again in this run. Returns the count to
/// write down.
pub fn sayProjectNotNow(self: *Chat, name: []const u8) Error!u8 {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    if (!group.project_not_now_said) group.project_not_now +|= 1;
    group.project_not_now_said = true;
    return group.project_not_now;
}

/// Put back what was written down (`GroupLog.Shell.project_not_now`).
pub fn restoreProjectNotNow(self: *Chat, name: []const u8, times: u8) void {
    const group = self.groups.getPtr(name) orelse return;
    group.project_not_now = times;
}

pub fn projectClaimOf(self: *const Chat, name: []const u8) ?ProjectClaim {
    const group = self.groups.getPtr(name) orelse return null;
    return group.project_claim;
}

/// Record, or with null take back, that a supervisor took `name` up. One
/// that was said outright is not replaced by one that was only worked
/// out: joining a group again does not unsay what its supervisor said.
pub fn setProjectClaim(self: *Chat, name: []const u8, claim: ?ProjectClaim) void {
    const group = self.groups.getPtr(name) orelse return;
    if (claim) |c| if (group.project_claim) |was| {
        if (was.said and !c.said and was.terminal == c.terminal) return;
    };
    group.project_claim = claim;
}

/// The supervisor a group last had, as far as anybody wrote it down.
///
/// **A part nobody knows is empty, and that is the only thing empty
/// means.** There are no defaults, so a writer that carried four of these
/// over and forgot the fifth does not compile; `none` is the record of a
/// group nobody has minded, written out in full.
///
/// Two things here look alike and are kept apart:
///
///   * `heard_ms == null` -- no supervisor was ever recorded for this
///     group (every record from before this was kept; a group nobody
///     minded). It may still have a `dir`: one made up afterwards out of
///     the old session snapshot, which `dir_from` says.
///   * `heard_ms` set and `session` empty -- there was a supervisor, and
///     its CLI never said which session it was in.
pub const LastSupervisor = struct {
    /// Where it was working. Empty when nobody has said.
    dir: []const u8,
    /// How `dir` was come by. `none` exactly when `dir` is empty.
    dir_from: DirFrom,
    /// The key of the role it wore; empty when it wore none, or nobody
    /// wrote it down.
    role: []const u8,
    /// The key of its agent CLI (`agent_cli.Adapter.key`); empty when not
    /// known.
    cli: []const u8,
    /// The session its CLI said it was in, as the CLI wrote it; empty
    /// when it never said.
    session: []const u8,
    /// When it was last heard from, on the real clock. Null when no
    /// supervisor was ever recorded.
    heard_ms: ?u64,

    pub const DirFrom = enum {
        none,
        /// A supervisor of this group was working there.
        supervisor,
        /// Nobody recorded a supervisor's directory for this group; this
        /// is where the terminal that was its supervisor stood in the
        /// session snapshot of the run before (`Session`). A guess about
        /// an old group, made once, and said to be one.
        session_snapshot,
    };

    pub const none: LastSupervisor = .{
        .dir = "",
        .dir_from = .none,
        .role = "",
        .cli = "",
        .session = "",
        .heard_ms = null,
    };

    pub fn isNone(self: LastSupervisor) bool {
        return self.dir.len == 0 and self.role.len == 0 and self.cli.len == 0 and
            self.session.len == 0 and self.heard_ms == null;
    }

    /// Whether everything but `heard_ms` is the same.
    pub fn sameWho(self: LastSupervisor, other: LastSupervisor) bool {
        return self.dir_from == other.dir_from and
            std.mem.eql(u8, self.dir, other.dir) and
            std.mem.eql(u8, self.role, other.role) and
            std.mem.eql(u8, self.cli, other.cli) and
            std.mem.eql(u8, self.session, other.session);
    }

    /// A copy whose strings belong to `alloc`; give it back with `free`.
    pub fn dupe(self: LastSupervisor, alloc: Allocator) Allocator.Error!LastSupervisor {
        const dir = try alloc.dupe(u8, self.dir);
        errdefer alloc.free(dir);
        const role = try alloc.dupe(u8, self.role);
        errdefer alloc.free(role);
        const cli = try alloc.dupe(u8, self.cli);
        errdefer alloc.free(cli);
        const session = try alloc.dupe(u8, self.session);
        return .{
            .dir = dir,
            .dir_from = self.dir_from,
            .role = role,
            .cli = cli,
            .session = session,
            .heard_ms = self.heard_ms,
        };
    }

    /// Only for one `dupe` made, or `none`.
    pub fn free(self: LastSupervisor, alloc: Allocator) void {
        alloc.free(self.dir);
        alloc.free(self.role);
        alloc.free(self.cli);
        alloc.free(self.session);
    }
};

/// What `setLastSupervisor` changed.
pub const LastChange = enum {
    /// Nothing at all.
    same,
    /// Only when it was last heard from.
    heard,
    /// Where it is, what it is, or the session it is in.
    who,
};

/// What is written down of `name`'s last supervisor; `none` when nothing
/// is, and for a group that is not there. Borrowed until the next
/// `setLastSupervisor` for it.
pub fn lastSupervisorOf(self: *const Chat, name: []const u8) LastSupervisor {
    const group = self.groups.getPtr(name) orelse return .none;
    return group.last_supervisor;
}

/// Whether any group has a session written down for its last supervisor:
/// the one thing that makes it worth asking the agent CLIs' adapters what
/// they can go on with.
pub fn anySessionKept(self: *const Chat) bool {
    var it = self.groups.valueIterator();
    while (it.next()) |g| {
        if (g.last_supervisor.session.len > 0) return true;
    }
    return false;
}

/// Where `name`'s supervisor was last working; empty when nobody said.
pub fn supervisorDirOf(self: *const Chat, name: []const u8) []const u8 {
    return self.lastSupervisorOf(name).dir;
}

/// Replace what is written down of `name`'s last supervisor with `last`,
/// whole. Says what that changed, so the caller knows whether it is worth
/// a write to disk.
pub fn setLastSupervisor(self: *Chat, name: []const u8, last: LastSupervisor) Error!LastChange {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    const was = group.last_supervisor;
    if (was.sameWho(last)) {
        if (was.heard_ms == last.heard_ms) return .same;
        group.last_supervisor.heard_ms = last.heard_ms;
        return .heard;
    }
    const owned = try last.dupe(self.alloc);
    was.free(self.alloc);
    group.last_supervisor = owned;
    return .who;
}

/// The directory most of `name`'s terminals are working in; empty when
/// none of them has said. Between two equally common ones, the one that
/// sorts first -- so the same group gives the same answer every time.
pub fn commonDirOf(self: *const Chat, name: []const u8) []const u8 {
    const group = self.groups.getPtr(name) orelse return "";
    var best: []const u8 = "";
    var best_n: usize = 0;
    var it = group.members.valueIterator();
    while (it.next()) |m| {
        const dir = m.footing.cwd;
        if (dir.len == 0) continue;
        var n: usize = 0;
        var jt = group.members.valueIterator();
        while (jt.next()) |o| {
            if (std.mem.eql(u8, o.footing.cwd, dir)) n += 1;
        }
        if (n > best_n or (n == best_n and std.mem.lessThan(u8, dir, best))) {
            best = dir;
            best_n = n;
        }
    }
    return best;
}

/// Forget a terminal everywhere, for example because it closed.
pub fn forget(self: *Chat, id: Id) void {
    var it = self.groups.valueIterator();
    while (it.next()) |g| {
        if (g.members.fetchRemove(id)) |kv| {
            var m = kv.value;
            m.footing.deinit(self.alloc);
        }
    }
    // A supervisor that was on its way here in that terminal is not coming.
    _ = self.startTerminalClosed(id);
}

/// The terminal a supervisor was being started in has been closed: the
/// start has failed, now, whatever is left of its wait. True when there
/// was such a start.
///
/// **Its own door, apart from `forget`.** `forget` is the terminal being
/// destroyed, and on macOS that is not when its tab is closed: the tab is
/// kept, terminal and all, for as long as the close can be undone. So the
/// person closed the tab, the control room went on saying "starting" over
/// a tab that was no longer there, and the sentence that it had been
/// closed arrived whenever the terminal was finally let go -- fifteen to
/// forty-odd seconds later on a real window (2026-10-13). The host says
/// when the tab closes; this is what it says it to.
pub fn startTerminalClosed(self: *Chat, id: Id) bool {
    var any = false;
    var it = self.groups.valueIterator();
    while (it.next()) |g| {
        if (g.start) |*s| {
            if (s.terminal != null and s.terminal.? == id and s.failed == .none) {
                s.failed = .terminal_closed;
                any = true;
            }
        }
    }
    return any;
}

/// Say something to a group.
/// What one `post` did: where it landed, and how much of it landed.
///
/// **`wrote` is not optional and not a flag**, for the reason `Kept`
/// already gives where it was introduced for briefs: "it was cut" is not
/// actionable and "you wrote N bytes and M were kept" is. It is returned
/// rather than logged because the writer is the only one who can do
/// anything about it, and the writer is not reading our logs.
///
/// Before this, a message over `max_text_bytes` was trimmed in silence and
/// `post` answered with a sequence number, so a supervisor who wrote a long
/// instruction saw `ok` and believed all of it had been said. The readers
/// got the first eight kilobytes and no sign that there had been more --
/// the same shape as the brief that no member could read.
pub const Posted = struct {
    seq: u64,
    wrote: Kept,
};

pub fn post(
    self: *Chat,
    name: []const u8,
    from: Id,
    text: []const u8,
    now_ms: u64,
) Error!Posted {
    return self.postMentioning(name, from, text, &.{}, now_ms);
}

/// `post`, addressed to some of the group by name. See `Message.mentions`.
///
/// **Checked whole before anything is added**: one name that is not in the
/// group refuses the post, so there is never a message out there that some
/// of its addressees were silently dropped from. Duplicates are collapsed.
pub fn postMentioning(
    self: *Chat,
    name: []const u8,
    from: Id,
    text: []const u8,
    mentions: []const Id,
    now_ms: u64,
) Error!Posted {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    if (!group.members.contains(from)) return error.NotAMember;
    if (mentions.len > max_mentions) return error.TooManyMentions;

    var buf: [max_mentions]Id = undefined;
    var n: usize = 0;
    for (mentions) |id| {
        if (id == from) return error.MentionSelf;
        if (!group.members.contains(id)) return error.MentionNotAMember;
        if (std.mem.indexOfScalar(Id, buf[0..n], id) != null) continue;
        buf[n] = id;
        n += 1;
    }

    return self.append(group, from, text, now_ms, false, buf[0..n]);
}

/// The text of one message as the group holds it -- trimmed and, if it was
/// over the limit, cut -- or null if it is not in the group any more.
pub fn messageText(self: *const Chat, name: []const u8, seq: u64) ?[]const u8 {
    const group = self.groups.getPtr(name) orelse return null;
    var i = group.log.items.len;
    while (i > 0) {
        i -= 1;
        const m = group.log.items[i];
        if (m.seq == seq) return m.text;
        if (m.seq < seq) break;
    }
    return null;
}

/// Record that `id` has just been interrupted about this group by some other
/// route than a notice -- a mention typed straight into it -- so the notice
/// sweep that follows the same post does not type a second line in behind it.
pub fn markTold(self: *Chat, name: []const u8, id: Id, now_ms: u64) void {
    const group = self.groups.getPtr(name) orelse return;
    const who = group.members.getPtr(id) orelse return;
    who.last_told_ms = now_ms;
    who.told_seq = group.head();
}

/// Record where a message landed in the log.
///
/// The host calls this after appending, because only it has the file.
/// Nothing here can fail and nothing here allocates: a message that
/// has already been trimmed or compacted away is simply not there any
/// more, which is not a mistake, it is later.
pub fn setLogSeq(self: *Chat, name: []const u8, seq: u64, log_seq: u64) void {
    const group = self.groups.getPtr(name) orelse return;

    // From the back, because this is almost always the message that was
    // just posted.
    var i = group.log.items.len;
    while (i > 0) {
        i -= 1;
        const m = &group.log.items[i];
        if (m.seq > seq) continue;
        if (m.seq == seq) m.log_seq = log_seq;
        break;
    }

    // Keep the invariant the log floor is defined by: it is the log seq of
    // the newest message the member is barred from. A member held back at
    // or past this message has just learnt where that bar sits on disk.
    var it = group.members.valueIterator();
    while (it.next()) |m| {
        if (m.floor < seq) continue;
        m.log_floor = @max(m.log_floor, log_seq);
    }
}

/// Bar a member from everything the log already held when it joined.
///
/// `add` draws the line at the newest message the group still has, which
/// is the best the model can do and is not far enough: after a restart the
/// group is empty and the line falls to zero, while `chat.jsonl` still
/// holds every word of last night under the same group name. A terminal
/// added with `history: none` would be kept out of that in `group_read`
/// and handed all of it by `group_history`.
///
/// So the host, which is the only one holding the file, says where the log
/// had got to. Never lowers an existing bar: two callers can only ever
/// know about more that is hidden, never less.
pub fn setLogFloor(self: *Chat, name: []const u8, id: Id, log_seq: u64) void {
    const group = self.groups.getPtr(name) orelse return;
    const m = group.members.getPtr(id) orelse return;
    m.log_floor = @max(m.log_floor, log_seq);
}

/// `text` cut to at most `limit` bytes without splitting a character.
///
/// A blind cut at a byte offset can land inside a multi-byte sequence, and
/// the leftover bytes are then not a character at all. That does not stay
/// contained: the JSON writer answers invalid UTF-8 with an array of
/// numbers instead of a string, so a reader asking for one agent's message
/// would be handed a list of byte values.
fn utf8Cut(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;

    // Back up over continuation bytes to the start of the character the
    // limit fell inside of.
    var i = limit;
    while (i > 0 and text[i] & 0xC0 == 0x80) i -= 1;
    return text[0..i];
}

/// Whether anything `who` may see and has not been handed, written by
/// somebody other than `id`, comes before `seq`.
fn unreadBefore(group: *const Group, who: Member, id: Id, seq: u64) bool {
    for (group.log.items) |m| {
        if (m.seq >= seq) break;
        if (m.seq <= who.cursor or m.seq <= who.floor) continue;
        if (m.from != id) return true;
    }
    return false;
}

fn append(
    self: *Chat,
    group: *Group,
    from: Id,
    text: []const u8,
    now_ms: u64,
    summary: bool,
    mentions: []const Id,
) Error!Posted {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.Empty;

    const kept = utf8Cut(trimmed, self.config.max_text_bytes);
    const owned = try self.alloc.dupe(u8, kept);
    errdefer self.alloc.free(owned);
    const named: []const Id = if (mentions.len == 0) &.{} else try self.alloc.dupe(Id, mentions);
    errdefer if (named.len > 0) self.alloc.free(named);

    const seq = group.next_seq;
    group.next_seq += 1;

    try group.log.append(self.alloc, .{
        .seq = seq,
        .from = from,
        .at_ms = now_ms,
        .summary = summary,
        .text = owned,
        .mentions = named,
    });

    // The sender has seen its own message by definition -- **and nothing
    // else by posting it.** This used to set the cursor to the new message
    // outright, which also claimed on the sender's behalf everything between
    // where it had read to and here: a message that arrived after its last
    // read and before its own next post was skipped by every later read
    // that did not name a `since`, and `unread` stopped counting it, so no
    // notice ever came for it either. Three in one night, one of them a
    // delivery (2026-10-13). So the cursor moves only when nothing the
    // sender may see, from anybody else, lies before this message unread.
    // Left where it was, the next read hands over what was missed, and the
    // sender's own words after it.
    if (group.members.getPtr(from)) |m| {
        if (!unreadBefore(group, m.*, from, seq)) m.cursor = seq;
    }

    // Never backwards. The clock arrives as a parameter here and a caller
    // replaying old lines into a live group would otherwise make the group
    // look staler than it is.
    if (now_ms > group.last_ms) group.last_ms = now_ms;

    self.trim(group);
    return .{ .seq = seq, .wrote = .{ .given = trimmed.len, .kept = kept.len } };
}

fn trim(self: *Chat, group: *Group) void {
    if (group.log.items.len <= self.config.max_messages) return;

    const drop = group.log.items.len - self.config.max_messages;
    for (group.log.items[0..drop]) |m| m.release(self.alloc);
    std.mem.copyForwards(
        Message,
        group.log.items[0 .. group.log.items.len - drop],
        group.log.items[drop..],
    );
    group.log.shrinkRetainingCapacity(group.log.items.len - drop);
}

/// Replace everything up to and including `through` with one summary the
/// supervisor wrote.
///
/// The supervisor writes the summary and the program does the replacing,
/// which is the division used everywhere else here: judging what a
/// conversation amounted to is not something code can do, and rewriting a
/// log correctly is not something a prompt should be trusted with.
///
/// The summary keeps the seq of the last message it replaces, so a member
/// that had not caught up is left with something to read rather than a gap.
pub fn compact(
    self: *Chat,
    name: []const u8,
    through: u64,
    summary: []const u8,
    by: Id,
    now_ms: u64,
) Error!Posted {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;

    const trimmed = std.mem.trim(u8, summary, " \t\r\n");
    if (trimmed.len == 0) return error.Empty;

    // Where the replaced range ends.
    var cut: usize = 0;
    while (cut < group.log.items.len and group.log.items[cut].seq <= through) {
        cut += 1;
    }

    // Nothing covered: refuse rather than leave a summary standing for
    // messages it did not replace.
    if (cut == 0) return error.Empty;

    const kept = utf8Cut(trimmed, self.config.max_text_bytes);
    const owned = try self.alloc.dupe(u8, kept);
    errdefer self.alloc.free(owned);

    // Both ends of the range being replaced, read before the texts go.
    const first_seq = group.log.items[0].seq;
    const seq = group.log.items[cut - 1].seq;
    const cut_log_seq = group.log.items[cut - 1].log_seq;
    for (group.log.items[0..cut]) |m| m.release(self.alloc);

    if (cut > 1) {
        std.mem.copyForwards(
            Message,
            group.log.items[1 .. group.log.items.len - (cut - 1)],
            group.log.items[cut..],
        );
        group.log.shrinkRetainingCapacity(group.log.items.len - (cut - 1));
    }

    group.log.items[0] = .{
        .seq = seq,
        .from = by,
        .at_ms = now_ms,
        .summary = true,
        .text = owned,
    };

    // Where each member now stands. Nobody's cursor moves: what somebody
    // has already read stays read, and dragging a cursor back would turn a
    // compaction into a pile of new messages for a member who was up to
    // date -- the opposite of what compacting is for.
    var it = group.members.valueIterator();
    while (it.next()) |m| {
        // Already looking past the whole range: nothing here concerns them.
        if (m.floor >= seq) continue;

        if (m.floor < first_seq) {
            // The entire range was theirs to see, so the summary stands in
            // for it.
            m.floor = seq - 1;
        } else {
            // They were held back from part of this range -- by joining with
            // `.none`, or by an earlier compaction. The summary covers what
            // they were kept out of, so it is not theirs to read either.
            // Hiding it costs them a recap; showing it would hand over the
            // history they were deliberately not given.
            m.floor = seq;
            m.log_floor = @max(m.log_floor, cut_log_seq);
        }
    }

    // **The same answer a post gives, for the same reason.** A summary is
    // the one message that stands in for everything it replaced, so a
    // summary quietly cut is a stretch of the conversation that nobody can
    // recover from the group -- and the supervisor who wrote it was told
    // `ok`.
    return .{ .seq = seq, .wrote = .{ .given = trimmed.len, .kept = kept.len } };
}

/// How much text this group is carrying, in bytes.
///
/// **What has not been compacted away**, which is the useful reading: the
/// messages a compaction replaces are freed from here, so this number falls
/// when one happens and climbs again afterwards. It is what the reminder to
/// compact is measured against.
///
/// The text only. Authors, ids and timestamps are the same handful of bytes
/// on every line and counting them would make the number about the number of
/// messages, which `log.items.len` already says.
pub fn bytesOf(self: *const Chat, name: []const u8) usize {
    const group = self.groups.getPtr(name) orelse return 0;

    var total: usize = 0;
    for (group.log.items) |m| total += m.text.len;
    return total;
}

/// How many messages `id` has not been shown in this group.
pub fn unread(self: *const Chat, name: []const u8, id: Id) usize {
    const group = self.groups.getPtr(name) orelse return 0;
    const who = group.members.get(id) orelse return 0;

    var n: usize = 0;
    for (group.log.items) |m| {
        if (m.seq <= who.cursor) continue;
        if (m.seq <= who.floor) continue;
        if (m.from == id) continue;
        n += 1;
    }
    return n;
}

/// How many unread messages this member should be *interrupted* for.
///
/// **Not `unread` with a filter bolted on, and the two are meant to be
/// able to disagree.** A watched terminal has every one of its messages
/// unread and nothing worth waking it for, and the next time it looks it
/// still gets all of them. Folding these into one number would turn "do
/// not interrupt" into "cannot see", which is the opposite of the point.
///
/// `role` is the *reader's* standing, and it is asked for rather than
/// looked up because roles live on the bus and the chat is not going to
/// guess at one.
///
/// # The rule, and what it used to be
///
/// **Only a supervisor is woken.** What stood here was "**a terminal
/// somebody is minding is not the group's to interrupt**" -- true, and it
/// only covered `watched`, so everything else was told: supervisors, and
/// **every terminal carrying no mark at all**.
///
/// ⚠️ **Task 413, reported by the user**: release a worker and it keeps
/// getting told. Nothing in the release does that; the release moves it from
/// `watched` to `none`, and `none` was the bucket that *is* told. **So
/// letting a worker go quietly turned its group notices back on.**
///
/// The old reasoning for telling an unmarked terminal was "nobody is
/// directing it, so the group is the only channel it has". That is a reason
/// to let it **see** the messages, and it does -- `unread` still counts every
/// one of them and `group_read` still hands them over. It is not a reason to
/// **interrupt** it, and interrupting is what this number decides. The two
/// were already meant to be able to disagree; see the paragraph above.
///
/// **What a notice actually is**: a line typed into that terminal's input
/// box. For a supervisor that is its box and reading it is its job. For
/// anybody else it is an interruption with **no next step that anyone asked
/// for** -- a released worker holds no task and answers to nobody, and a
/// terminal the person is reading in gets a line pushed into their shell
/// prompt.
///
/// ⚠️ **What this costs, and it is a real cost**: an unmarked terminal is no
/// longer told, including one a person is sitting at. They keep the
/// conversations window (`poltergeist_toggle_chat`), which is where a person
/// reads a group; what they lose is a nudge in a terminal. **A released
/// agent loses nothing it was going to act on.**
///
/// ⚠️ **And what this cannot see**: a released worker and a terminal the
/// person is reading in are **the same thing to this code** -- both carry no
/// mark, and nothing here can tell them apart. That is why the rule is drawn
/// on "who acts on it" rather than on "who is it". See
/// `dev-docs/poltergeist/tasks.md`.
///
/// # The one exception: being named
///
/// **A message that names this member interrupts it whatever its role**
/// (`Message.mentions`, `dev-docs/poltergeist/mentions.md` part four). The
/// author said who it was for, so "nobody is expecting anything of it" is no
/// longer true of that message. Only the named messages count: a watched
/// terminal named once in a group of twenty unread is woken for one, and a
/// member not named in anything is woken for exactly what it was before --
/// nothing.
pub fn waking(self: *const Chat, name: []const u8, id: Id, role: Bus.Role) usize {
    return switch (role) {
        .supervisor => self.unread(name, id),

        // Minded: its supervisor types into it, and the group cannot compete
        // with that channel. Unmarked: nobody is expecting anything of it.
        // Unless the message said it was for them.
        .watched, .none => self.unreadNaming(name, id),
    };
}

/// How many of `id`'s unread messages in this group name it.
fn unreadNaming(self: *const Chat, name: []const u8, id: Id) usize {
    const group = self.groups.getPtr(name) orelse return 0;
    const who = group.members.get(id) orelse return 0;

    var n: usize = 0;
    for (group.log.items) |m| {
        if (m.seq <= who.cursor) continue;
        if (m.seq <= who.floor) continue;
        if (m.from == id) continue;
        if (std.mem.indexOfScalar(Id, m.mentions, id) == null) continue;
        n += 1;
    }
    return n;
}

/// Total unread across every group `id` is in.
pub fn unreadTotal(self: *const Chat, id: Id) usize {
    var n: usize = 0;
    var it = self.groups.keyIterator();
    while (it.next()) |name| n += self.unread(name.*, id);
    return n;
}

/// How much one batch may carry.
///
/// **The budget lives in the call that decides what to hand over**, and that
/// is the whole of task 579. It used to live in the caller: `read` returned
/// everything and marked the member as having seen all of it, and then
/// `rpc.capMessages` cut the reply down to what would fit on one socket
/// line. Each half was right. Together they lost messages -- what fell off
/// the end had already been marked read on the way past, so it was never
/// offered again, `unread` said nothing was waiting, and a supervisor read
/// the same oldest batch three times without ever reaching the message that
/// said a tree had been given up.
///
/// One rule, and it is now impossible to write code that breaks it: **the
/// call that decides what is delivered is the one that moves the cursor.**
pub const Budget = struct {
    /// Raw message text, in bytes.
    bytes: usize,

    /// What the caller will add for each line on top of its text -- the
    /// author's name, the JSON scaffolding around it. Counted here because
    /// the caller cannot cut the batch afterwards without putting the two
    /// halves back out of step.
    per_line: usize = 0,

    /// No limit. For callers that are not writing to a socket -- the tests
    /// below, mostly. Spelled out rather than left as a magic number so
    /// that "this one really is unbounded" is a decision on the page.
    pub const unlimited: Budget = .{ .bytes = std.math.maxInt(usize) };
};

/// What one `read` handed over.
pub const Batch = struct {
    messages: []const Message,

    /// Whether the budget cut it short. **Without this a capped batch is
    /// indistinguishable from the end of the conversation**, and a reader
    /// stops one screenful in believing it has everything.
    more: bool,
};

/// What `id` may see in this group after `since`, oldest first, up to
/// `budget` -- and `id` is marked as having seen exactly that much.
///
/// `since` is **exclusive**: it is the sequence number of the last message
/// the caller already holds, so the reply starts at `since + 1`. Passing the
/// `seq` of a message you have been given will never hand it to you twice,
/// and will never skip the one after it.
///
/// **`null` means "carry on from where I am"** -- it resumes from this
/// member's own cursor. That is what makes a caller which never passes
/// `since`, which is every caller that just wants to know what is new,
/// advance instead of being handed the same oldest batch forever. Passing
/// `0` is a different instruction and still means "from the beginning of
/// what I may see"; the two were one value, and that is the defect.
///
/// The slice is the caller's; the texts inside it still belong to the
/// group, so a caller that keeps them must copy.
pub fn read(
    self: *Chat,
    alloc: Allocator,
    name: []const u8,
    id: Id,
    since: ?u64,
    budget: Budget,
) Error!Batch {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    const who = group.members.getPtr(id) orelse return error.NotAMember;

    // **Absent resumes; a number is obeyed, including zero.** They are two
    // instructions and they used to be one value: a caller that never said
    // `since` got the same oldest batch every time, and a caller that meant
    // "from the beginning" had no way to say so. Given a number, it is the
    // caller's own claim about what it holds and it is taken at face value
    // in both directions -- asking again for an older range gets it.
    const after = since orelse who.cursor;

    var out: std.ArrayListUnmanaged(Message) = .empty;
    errdefer out.deinit(alloc);

    var used: usize = 0;
    var more = false;
    for (group.log.items) |m| {
        if (m.seq <= after) continue;
        if (m.seq <= who.floor) continue;

        used += m.text.len + budget.per_line;
        if (used > budget.bytes and out.items.len > 0) {
            // **At least one, however big it is.** A reply of nothing would
            // have the caller poll forever without its cursor ever moving,
            // which is the same standstill by another route.
            more = true;
            break;
        }

        try out.append(alloc, m);
    }

    // **Exactly what went out, and not one message further.** The old line
    // here reached for the newest message in the log instead, which is the
    // defect: it claimed on the member's behalf to have seen things that
    // were about to be cut off the end of this very reply.
    if (out.items.len > 0) {
        const delivered = out.items[out.items.len - 1].seq;
        if (delivered > who.cursor) who.cursor = delivered;
    }

    return .{ .messages = try out.toOwnedSlice(alloc), .more = more };
}

/// Who is in this group, sorted so two listings can be compared.
///
/// Ids only. What to call each one is not the chat's business: it knows
/// terminals by the id the host assigned, and the host is the one that can
/// turn that into whatever the tab currently says.
/// How many terminals are in the group besides the person.
pub fn othersIn(self: *const Chat, name: []const u8) Error!usize {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;
    const n = group.members.count();
    return if (group.members.contains(user_id)) n - 1 else n;
}

pub fn membersOf(
    self: *const Chat,
    alloc: Allocator,
    name: []const u8,
) Error![]const Id {
    const group = self.groups.getPtr(name) orelse return error.NoSuchGroup;

    var out: std.ArrayListUnmanaged(Id) = .empty;
    errdefer out.deinit(alloc);

    var it = group.members.keyIterator();
    while (it.next()) |id| try out.append(alloc, id.*);

    const owned = try out.toOwnedSlice(alloc);
    std.mem.sort(Id, owned, {}, std.sort.asc(Id));
    return owned;
}

/// The groups `id` is in, in the order they should be shown.
///
/// **Groups with somebody in them first, then the rest newest-spoken
/// first.** The list never expires -- a group is kept for as long as its
/// records are, because there is no telling when the person will want last
/// Tuesday's back -- so without an order the useful ones sink under the
/// old ones as the weeks go by.
///
/// Active means `isActive`: a member of the group is a terminal that is
/// open right now. `live` is that set of open ids, and it is the same
/// judgement the refusal to destroy an active group uses -- one definition
/// of the word, in one function, so the order the list is drawn in and
/// what may be deleted from it cannot drift apart. It also lines up with
/// what a restart does: nothing comes back with members, so the morning
/// after, every group is inactive until the supervisor puts terminals into
/// the one it wants -- and that is precisely what taking a group up again
/// means.
///
/// The name breaks ties, so two listings taken a moment apart can still be
/// compared.
///
/// The names belong to the chat, so a caller that keeps them must copy.
pub fn groupsFor(
    self: *const Chat,
    alloc: Allocator,
    id: Id,
    live: []const Id,
) Allocator.Error![]const []const u8 {
    return self.groupsSeenBy(alloc, id, live, false);
}

/// The same, optionally including groups `id` is not in.
///
/// **`all` is for whoever is arranging the groups, and it exists because of
/// what a restart leaves behind.** A group comes back from disk as a shell:
/// its name and its note, and nobody in it but the person at the keyboard,
/// because deciding which terminal on screen now is which one from last
/// night is a judgement (`restoreShell`). That is right, and it had one
/// consequence nobody followed through: a supervisor asking `group_list`
/// after a restart is not a member of anything, so it is told there are no
/// groups -- and concludes last night is gone and starts over, on top of a
/// panel that is still there.
///
/// A worker still sees only its own. What its peers are arranged into is
/// not its business and would only cost it context. This is the same split
/// `task_list` makes, for the same reason.
pub fn groupsSeenBy(
    self: *const Chat,
    alloc: Allocator,
    id: Id,
    live: []const Id,
    all: bool,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(alloc);

    var it = self.groups.iterator();
    while (it.next()) |kv| {
        if (all or kv.value_ptr.members.contains(id)) try out.append(alloc, kv.key_ptr.*);
    }

    const owned = try out.toOwnedSlice(alloc);
    std.mem.sort([]const u8, owned, Order{ .chat = self, .live = live }, lessThan);
    return owned;
}

/// What `lessThan` needs to answer: the groups, and which terminals are
/// open. Two things rather than one because the second is not the chat's
/// to know.
const Order = struct { chat: *const Chat, live: []const Id };

fn lessThan(ctx: Order, lhs: []const u8, rhs: []const u8) bool {
    const l_live = ctx.chat.isActive(lhs, ctx.live);
    const r_live = ctx.chat.isActive(rhs, ctx.live);
    if (l_live != r_live) return l_live;

    const l = ctx.chat.groups.getPtr(lhs).?;
    const r = ctx.chat.groups.getPtr(rhs).?;
    if (l.last_ms != r.last_ms) return l.last_ms > r.last_ms;

    return std.mem.order(u8, lhs, rhs) == .lt;
}

/// Whether `id` should be told this group has messages waiting.
///
/// Asked of `waking`, not of `unread`: whether there is anything worth
/// interrupting this member for is the first question, and the rate limit
/// is the second. A watched terminal never gets as far as the clock.
pub fn shouldNotify(
    self: *Chat,
    name: []const u8,
    id: Id,
    now_ms: u64,
    gap_ms: u64,
    role: Bus.Role,
) bool {
    if (self.waking(name, id, role) == 0) return false;

    const group = self.groups.getPtr(name) orelse return false;
    const who = group.members.getPtr(id) orelse return false;

    // Nothing has arrived since it was last told: once is enough.
    if (group.head() <= who.told_seq) return false;

    if (who.last_told_ms) |last| {
        if (now_ms -| last < gap_ms) return false;
    }
    who.last_told_ms = now_ms;
    who.told_seq = group.head();
    return true;
}

/// A notice typed into `id` was refused: whatever it was told is waiting,
/// it was not told. The gap still runs from the attempt; when it is over,
/// the sweep that comes back says it again.
pub fn noticeRefused(self: *Chat, id: Id) void {
    var it = self.groups.valueIterator();
    while (it.next()) |g| {
        if (g.members.getPtr(id)) |m| m.told_seq = 0;
    }
}

/// How long until `id` may be told about this group, when it has something
/// worth being told about and was told too recently; null when there is
/// nothing to wait for -- nothing waiting, or it may be told now.
///
/// **`shouldNotify` saying no is two different answers**, and only one of
/// them ends by itself. Nothing is swept again until the next post, so a
/// message that arrived inside the gap was simply never announced (the
/// night of 2026-10-13: two messages twenty-two seconds apart, one notice).
/// Whoever sweeps comes back after this long.
pub fn notifyWaitMs(
    self: *const Chat,
    name: []const u8,
    id: Id,
    now_ms: u64,
    gap_ms: u64,
    role: Bus.Role,
) ?u64 {
    if (self.waking(name, id, role) == 0) return null;
    const group = self.groups.getPtr(name) orelse return null;
    const who = group.members.getPtr(id) orelse return null;
    if (group.head() <= who.told_seq) return null;
    const last = who.last_told_ms orelse return null;
    const since = now_ms -| last;
    if (since >= gap_ms) return null;
    return gap_ms - since;
}

/// The line a terminal is given when a group has messages waiting.
///
/// A count, a group name, and how to fetch. Never the messages: an agent's
/// context is for its own work, and going to look is its own decision.
pub fn formatNotice(
    name: []const u8,
    count: usize,
    buf: []u8,
) std.fmt.BufPrintError![]u8 {
    return std.fmt.bufPrint(
        buf,
        "[poltergeist] {d} new message{s} in \"{s}\". Read them with group_read.",
        .{ count, if (count == 1) "" else "s", name },
    );
}

/// How a terminal is named inside message text: `@` and the first eight hex
/// digits of its id, then its title as it was at that moment.
///
/// The id and not only the title because a title is changed at will, and
/// somebody reading the record tomorrow has to know who was meant tonight.
/// Eight digits because the full sixteen are unreadable in a sentence and
/// eight are already one in four billion.
pub fn writeName(w: *std.Io.Writer, id: Id, title: []const u8) std.Io.Writer.Error!void {
    var hex: [16]u8 = undefined;
    const digits = std.fmt.bufPrint(&hex, "{x}", .{id}) catch unreachable;
    try w.print("@{s}", .{digits[0..@min(digits.len, 8)]});
    if (title.len > 0) try w.print(" {s}", .{title});
}

/// The one line typed into a named terminal, with a return after it.
///
/// Everything on one line: a message's line breaks are folded to spaces,
/// because a bare shell -- which is a terminal a group may contain -- runs
/// each line as it arrives (`terminal_send`'s `UnbracketedMultiline`). The
/// group keeps the text as it was written; this is only the delivery.
///
/// `stored` is the text as the group holds it, with the names already
/// written in by the caller -- so what is typed and what is kept say the
/// same names, frozen at the same moment.
pub fn formatDelivery(
    alloc: Allocator,
    group: []const u8,
    seq: u64,
    from: Id,
    from_title: []const u8,
    stored: []const u8,
) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    w.print("[poltergeist] {s} #{d} ", .{ group, seq }) catch return error.OutOfMemory;
    writeName(w, from, from_title) catch return error.OutOfMemory;
    w.writeAll(": ") catch return error.OutOfMemory;
    for (stored) |c| w.writeByte(switch (c) {
        '\r', '\n', '\t' => ' ',
        else => c,
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const boss: Id = 0x1111;
const a: Id = 0x2222;
const b: Id = 0x3333;

fn testChat() Chat {
    return .init(testing.allocator, .{});
}

test "the user's id cannot collide with a terminal's" {
    // Surface.id is documented never to be zero, which is what makes zero
    // safe to reserve.
    try testing.expect(user_id == 0);
}

test "a group starts with its creator in it" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try testing.expect(chat.isMember("build", boss));
    try testing.expect(!chat.isMember("build", a));
}

test "#1064: a terminal the user watched reports to the supervisor it is in a group with, not to every one" {
    // The real chat behind the real bus, in the shape that was measured:
    // two supervisors on unrelated work, a terminal watched from the tab
    // menu (so nobody's), and the `no tool call` clock running on it.
    var chat = testChat();
    defer chat.deinit();
    var bus: Bus = .init(testing.allocator, .{});
    defer bus.deinit();

    const s1: Id = 0x1111;
    const s2: Id = 0x4444;
    const w: Id = 0x2222;
    try bus.addSupervisor(s1);
    try bus.addSupervisor(s2);
    try bus.watch(w, null);

    try chat.create("video", s1);
    try chat.add("video", w, .all, .{});
    try chat.create("port", s2);

    try testing.expect(chat.sharesGroup(s1, w));
    try testing.expect(!chat.sharesGroup(s2, w));

    const late = 16 * std.time.ms_per_min;
    bus.noteCall(w, 0);
    try testing.expect(bus.considerCalls(late));

    // The scheduled hand-over to the unrelated supervisor: nothing, and
    // none of the three the notice gets is spent on it.
    var buf: [255]u8 = undefined;
    const stray = bus.drainIfDue(s2, late, &buf, chat.peers());
    try testing.expect(stray == null);
    try testing.expectEqual(@as(u8, 0), bus.get(w).?.silent_handed);

    const line = bus.drainIfDue(s1, late, &buf, chat.peers()) orelse
        return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, line, "0x0000000000002222 no tool call 16m") != null);
    try testing.expectEqual(@as(u8, 1), bus.get(w).?.silent_handed);

    // Put in a group with the second one as well, and it hears too: the
    // rule is membership, not who got there first.
    try chat.add("port", w, .all, .{});
    const both = bus.drain(s2, late, &buf, chat.peers());
    try testing.expect(both != null);
}

test "#1064: a lone supervisor hears a terminal the user watched, in a group with it or not" {
    var chat = testChat();
    defer chat.deinit();
    var bus: Bus = .init(testing.allocator, .{});
    defer bus.deinit();

    const s1: Id = 0x1111;
    const w: Id = 0x2222;
    try bus.addSupervisor(s1);
    try bus.watch(w, null);
    try testing.expect(!chat.sharesGroup(s1, w));

    const late = 16 * std.time.ms_per_min;
    bus.noteCall(w, 0);
    try testing.expect(bus.considerCalls(late));

    var buf: [255]u8 = undefined;
    const line = bus.drain(s1, late, &buf, chat.peers());
    try testing.expect(line != null);
}

test "group names are restricted" {
    var chat = testChat();
    defer chat.deinit();

    try testing.expectError(error.BadName, chat.create("Has Spaces", boss));
    try testing.expectError(error.BadName, chat.create("../escape", boss));
    try testing.expectError(error.BadName, chat.create("", boss));
    try chat.create("build-2", boss);
}

test "a group cannot be made twice" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try testing.expectError(error.GroupExists, chat.create("build", boss));
}

test "there can be several groups at once" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.create("research", boss);
    try chat.add("build", a, .none, .{});
    try chat.add("research", b, .none, .{});

    _ = try chat.post("build", boss, "for the builders", 0);
    try testing.expectEqual(@as(usize, 1), chat.unread("build", a));
    try testing.expectEqual(@as(usize, 0), chat.unread("research", b));
}

test "a shell left by a restart is invisible to the one who has to take it up" {
    // The failure this is written from, in full: Polter restarts, the
    // groups come back as shells with nobody in them, a supervisor asks
    // what groups there are, is told none, and rebuilds a group that is
    // sitting right there with its note intact and its task panel behind
    // it. Every part of that behaved as designed.
    const alloc = testing.allocator;
    var chat = testChat();
    defer chat.deinit();

    // What `restoreShell` leaves: the group exists and only the user is in
    // it.
    try chat.restoreShell("windows-port", "the port", 1_000, .none);

    {
        const mine = try chat.groupsFor(alloc, boss, &.{});
        defer alloc.free(mine);
        try testing.expectEqual(@as(usize, 0), mine.len);
    }

    // Asking for all of them finds it, which is what a supervisor needs
    // before it can decide anything about it.
    {
        const every = try chat.groupsSeenBy(alloc, boss, &.{}, true);
        defer alloc.free(every);
        try testing.expectEqual(@as(usize, 1), every.len);
        try testing.expectEqualStrings("windows-port", every[0]);
    }

    // And the listing can say which it is, so "there and not yours" is
    // distinguishable from "yours".
    try testing.expect(!chat.hasMember("windows-port", boss));
    try testing.expect(chat.hasMember("windows-port", user_id));

    try chat.add("windows-port", boss, .all, .{});
    try testing.expect(chat.hasMember("windows-port", boss));

    const mine = try chat.groupsFor(alloc, boss, &.{});
    defer alloc.free(mine);
    try testing.expectEqual(@as(usize, 1), mine.len);
}

test "a worker is shown its own groups and nobody else's" {
    // The other half, and the reason `all` is a parameter rather than the
    // new behaviour: what its peers are arranged into is not a worker's
    // business, and would cost it context to be told.
    const alloc = testing.allocator;
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.create("research", boss);
    try chat.add("build", a, .none, .{});

    const mine = try chat.groupsFor(alloc, a, &.{});
    defer alloc.free(mine);
    try testing.expectEqual(@as(usize, 1), mine.len);
    try testing.expectEqualStrings("build", mine[0]);
}

test "only members may post" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try testing.expectError(error.NotAMember, chat.post("build", a, "hi", 0));

    try chat.add("build", a, .none, .{});
    _ = try chat.post("build", a, "hi", 0);
}

test "a group that does not exist refuses everything" {
    var chat = testChat();
    defer chat.deinit();

    try testing.expectError(error.NoSuchGroup, chat.post("nope", boss, "hi", 0));
    try testing.expectError(error.NoSuchGroup, chat.add("nope", a, .none, .{}));
    try testing.expectError(error.NoSuchGroup, chat.destroy("nope"));
    try testing.expectError(
        error.NoSuchGroup,
        chat.read(testing.allocator, "nope", boss, 0, .unlimited),
    );
}

test "a terminal added without history sees nothing that came before" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    _ = try chat.post("build", boss, "old one", 0);
    _ = try chat.post("build", boss, "old two", 1);

    try chat.add("build", a, .none, .{});
    try testing.expectEqual(@as(usize, 0), chat.unread("build", a));

    const seen = (try chat.read(testing.allocator, "build", a, 0, .unlimited)).messages;
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 0), seen.len);

    _ = try chat.post("build", boss, "fresh", 2);
    try testing.expectEqual(@as(usize, 1), chat.unread("build", a));
}

test "a terminal added with history sees everything still in the log" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    _ = try chat.post("build", boss, "old one", 0);
    _ = try chat.post("build", boss, "old two", 1);

    try chat.add("build", a, .all, .{});
    try testing.expectEqual(@as(usize, 2), chat.unread("build", a));

    const seen = (try chat.read(testing.allocator, "build", a, 0, .unlimited)).messages;
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 2), seen.len);
    try testing.expectEqualStrings("old one", seen[0].text);
}

test "adding somebody already in a group leaves their view alone" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none, .{});
    _ = try chat.post("build", boss, "after", 0);

    // A second add with `.all` must not hand them the backlog they were
    // deliberately kept out of.
    try chat.add("build", a, .all, .{});
    try testing.expectEqual(@as(usize, 1), chat.unread("build", a));
}

test "removing a member stops them reading" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all, .{});
    try chat.remove("build", a);

    try testing.expectError(
        error.NotAMember,
        chat.read(testing.allocator, "build", a, 0, .unlimited),
    );
    try testing.expectEqual(@as(usize, 0), chat.unread("build", a));
}

test "a two terminal group is what a direct message used to be" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("boss-and-a", boss);
    try chat.add("boss-and-a", a, .none, .{});
    try chat.create("everyone", boss);
    try chat.add("everyone", a, .none, .{});
    try chat.add("everyone", b, .none, .{});

    _ = try chat.post("boss-and-a", boss, "just between us", 0);

    try testing.expectEqual(@as(usize, 1), chat.unread("boss-and-a", a));
    try testing.expectEqual(@as(usize, 0), chat.unread("everyone", b));
    try testing.expect(!chat.isMember("boss-and-a", b));
}

test "reading marks seen, and a cursor picks up where it left off" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none, .{});
    const first = (try chat.post("build", boss, "one", 0)).seq;
    _ = try chat.post("build", boss, "two", 1);

    try testing.expectEqual(@as(usize, 2), chat.unread("build", a));

    const rest = (try chat.read(testing.allocator, "build", a, first, .unlimited)).messages;
    defer testing.allocator.free(rest);
    try testing.expectEqual(@as(usize, 1), rest.len);
    try testing.expectEqualStrings("two", rest[0].text);
    try testing.expectEqual(@as(usize, 0), chat.unread("build", a));
}

test "compacting replaces what it covers with one summary" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all, .{});
    for (0..5) |i| {
        var buf: [8]u8 = undefined;
        _ = try chat.post("build", boss, try std.fmt.bufPrint(&buf, "m{d}", .{i}), i);
    }
    _ = try chat.post("build", boss, "kept", 9);

    const at = (try chat.compact("build", 5, "we argued about the build", boss, 10)).seq;
    try testing.expectEqual(@as(u64, 5), at);

    const seen = (try chat.read(testing.allocator, "build", a, 0, .unlimited)).messages;
    defer testing.allocator.free(seen);

    try testing.expectEqual(@as(usize, 2), seen.len);
    try testing.expect(seen[0].summary);
    try testing.expectEqualStrings("we argued about the build", seen[0].text);
    try testing.expect(!seen[1].summary);
    try testing.expectEqualStrings("kept", seen[1].text);
}

test "compacting leaves somebody who had not caught up with the summary" {
    // The point of leaving a summary is that a member behind the cut sees
    // what it stood for rather than a hole.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all, .{});
    for (0..4) |i| {
        var buf: [8]u8 = undefined;
        _ = try chat.post("build", boss, try std.fmt.bufPrint(&buf, "m{d}", .{i}), i);
    }

    _ = try chat.compact("build", 4, "the gist of it", boss, 5);

    const seen = (try chat.read(testing.allocator, "build", a, 0, .unlimited)).messages;
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 1), seen.len);
    try testing.expectEqualStrings("the gist of it", seen[0].text);
}

test "compacting does not make read messages unread again" {
    // A member who was up to date must stay up to date. Dragging a cursor
    // back to the cut turned a compaction into a pile of "new" messages
    // for exactly the members who had nothing new to read, and the notice
    // they then got pointed at messages they had already been shown.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all, .{});
    for (0..10) |i| {
        var buf: [8]u8 = undefined;
        _ = try chat.post("build", boss, try std.fmt.bufPrint(&buf, "m{d}", .{i}), i);
    }

    // Caught up on everything.
    const first = (try chat.read(testing.allocator, "build", a, 0, .unlimited)).messages;
    testing.allocator.free(first);
    try testing.expectEqual(@as(usize, 0), chat.unread("build", a));

    // Compacting the first half changes nothing about what is unread.
    _ = try chat.compact("build", 5, "the gist", boss, 11);
    try testing.expectEqual(@as(usize, 0), chat.unread("build", a));
    try testing.expectEqual(@as(usize, 0), chat.unreadTotal(a));
}

test "compacting does not hand over history a member was kept out of" {
    // Joining with `.none` is a promise that what came before is not
    // theirs to read. A summary written across that boundary would break
    // the promise by other means, so they do not get shown it.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    _ = try chat.post("build", boss, "the prod credentials are in vault", 1);
    _ = try chat.post("build", boss, "and the rotation plan is quarterly", 2);

    // Deliberately started with a clean slate.
    try chat.add("build", a, .none, .{});
    try testing.expectEqual(@as(usize, 0), chat.unread("build", a));

    _ = try chat.post("build", boss, "anyway, the build is green", 3);
    _ = try chat.compact("build", 3, "credentials, rotation, and a green build", boss, 4);

    const seen = (try chat.read(testing.allocator, "build", a, 0, .unlimited)).messages;
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 0), seen.len);
}

test "a message is cut on a character boundary, not a byte one" {
    // Half a character is not a character, and the JSON writer answers
    // invalid UTF-8 with an array of numbers -- so a reader would be
    // handed byte values instead of a message.
    var chat = testChat();
    defer chat.deinit();
    chat.config.max_text_bytes = 8;

    try chat.create("build", boss);

    // Three-byte characters against a limit that falls mid-character.
    _ = try chat.post("build", boss, "日日日", 1);

    const seen = (try chat.read(testing.allocator, "build", boss, 0, .unlimited)).messages;
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 1), seen.len);
    try testing.expect(std.unicode.utf8ValidateSlice(seen[0].text));
    try testing.expectEqualStrings("日日", seen[0].text);
}

test "compacting nothing is refused rather than leaving a stray summary" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    _ = try chat.post("build", boss, "one", 0);

    // Nothing at or below seq 0.
    try testing.expectError(error.Empty, chat.compact("build", 0, "nothing", boss, 1));
    try testing.expectEqual(
        @as(usize, 1),
        chat.groups.getPtr("build").?.log.items.len,
    );
}

test "an empty summary is refused" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    _ = try chat.post("build", boss, "one", 0);
    try testing.expectError(error.Empty, chat.compact("build", 1, "  ", boss, 1));
}

test "compacting shrinks what a later read has to carry" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all, .{});
    for (0..20) |i| {
        var buf: [16]u8 = undefined;
        _ = try chat.post("build", boss, try std.fmt.bufPrint(&buf, "chatter {d}", .{i}), i);
    }

    _ = try chat.compact("build", 20, "twenty lines of chatter", boss, 21);

    const seen = (try chat.read(testing.allocator, "build", a, 0, .unlimited)).messages;
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 1), seen.len);
}

test "empty messages are refused" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try testing.expectError(error.Empty, chat.post("build", boss, "", 0));
    try testing.expectError(error.Empty, chat.post("build", boss, " \n\t ", 0));
}

test "one message cannot fill a group by itself" {
    var chat: Chat = .init(testing.allocator, .{ .max_text_bytes = 16 });
    defer chat.deinit();

    try chat.create("build", boss);
    _ = try chat.post("build", boss, "x" ** 100, 0);
    try testing.expectEqual(
        @as(usize, 16),
        chat.groups.getPtr("build").?.log.items[0].text.len,
    );
}

test "a group's log is capped and the oldest go first" {
    var chat: Chat = .init(testing.allocator, .{ .max_messages = 3 });
    defer chat.deinit();

    try chat.create("build", boss);
    for (0..5) |i| {
        var buf: [8]u8 = undefined;
        _ = try chat.post("build", boss, try std.fmt.bufPrint(&buf, "m{d}", .{i}), i);
    }

    const log = chat.groups.getPtr("build").?.log.items;
    try testing.expectEqual(@as(usize, 3), log.len);
    try testing.expectEqualStrings("m2", log[0].text);
}

test "there is a limit on how many groups can exist" {
    var chat: Chat = .init(testing.allocator, .{ .max_groups = 2 });
    defer chat.deinit();

    try chat.create("one", boss);
    try chat.create("two", boss);
    try testing.expectError(error.TooManyGroups, chat.create("three", boss));

    try chat.destroy("one");
    try chat.create("three", boss);
}

test "a restored shell has its name and its note and nobody in it" {
    var chat = testChat();
    defer chat.deinit();

    try chat.restoreShell("build", "\u{591c}\u{73ed}\u{90a3}\u{644a}\u{6d3b}", 1_700_000_000_000, .none);

    try testing.expect(chat.exists("build"));
    try testing.expectEqualStrings("\u{591c}\u{73ed}\u{90a3}\u{644a}\u{6d3b}", try chat.briefOf("build"));

    // The negative half, and the point of the whole thing: the shell is
    // back, the members are not. Only the person at the keyboard is in it,
    // which is what makes it inactive until a supervisor takes it up.
    try testing.expect(!chat.isActive("build", &.{ a, boss }));
    try testing.expect(chat.isMember("build", user_id));
    try testing.expect(!chat.isMember("build", a));
    try testing.expect(!chat.isMember("build", boss));

    const members = try chat.membersOf(testing.allocator, "build");
    defer testing.allocator.free(members);
    try testing.expectEqual(@as(usize, 1), members.len);
}

test "a restored shell does not overwrite the live group of the same name" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    _ = try chat.setBrief("build", "live");
    try chat.add("build", a, .none, .{});

    try testing.expectError(error.GroupExists, chat.restoreShell("build", "stale", 1, .none));

    try testing.expectEqualStrings("live", try chat.briefOf("build"));
    try testing.expect(chat.isMember("build", a));
}

test "groups with somebody in them sort above groups with nobody" {
    var chat = testChat();
    defer chat.deinit();

    // `quiet` spoke most recently of the three and still sorts last: it
    // has no terminals in it. That is the whole rule in one case.
    try chat.restoreShell("quiet", "", 900, .none);

    try chat.restoreShell("older", "", 100, .none);
    try chat.add("older", a, .all, .{});

    try chat.restoreShell("newer", "", 200, .none);
    try chat.add("newer", b, .all, .{});

    const list = try chat.groupsFor(testing.allocator, user_id, &.{ a, b });
    defer testing.allocator.free(list);

    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("newer", list[0]);
    try testing.expectEqualStrings("older", list[1]);
    try testing.expectEqualStrings("quiet", list[2]);
}

test "who is active is counted from the terminals, not from the user" {
    var chat = testChat();
    defer chat.deinit();

    // `loud` spoke most recently and has nobody in it but the person at
    // the keyboard. `quiet` spoke first and has a terminal working in it.
    //
    // This is the case that says *which* count is being used, and it is
    // the one the obvious mistake fails: the person is put in every group
    // as it is made, so counting members would make both of these active,
    // hand the decision to the times, and put `loud` first.
    try chat.restoreShell("loud", "", 900, .none);
    try chat.restoreShell("quiet", "", 100, .none);
    try chat.add("quiet", a, .all, .{});

    try testing.expect(!chat.isActive("loud", &.{a}));
    try testing.expect(chat.isActive("quiet", &.{a}));

    const list = try chat.groupsFor(testing.allocator, user_id, &.{a});
    defer testing.allocator.free(list);

    try testing.expectEqualStrings("quiet", list[0]);
    try testing.expectEqualStrings("loud", list[1]);
}

test "a member whose terminal is gone does not make its group active" {
    var chat = testChat();
    defer chat.deinit();

    // The whole point of crossing the two sets. `a` is on the membership
    // list of `stale` and is not open any more; `b` is on the list of
    // `busy` and is. Nothing about the two groups differs except that.
    //
    // A criterion that read the list alone would call both of these
    // active, and `stale` would be undeletable for ever -- which is the
    // shape of the bug this is written against, not a hypothetical: the
    // list is pruned by one call in `Surface.deinit`, and this holds
    // whether or not that call runs.
    // Made with `restoreShell` rather than `create` so the only members
    // are the ones named here: `create` puts the terminal that made the
    // group in it, which is a member like any other and would blur what
    // this test is about.
    try chat.restoreShell("stale", "", 100, .none);
    try chat.add("stale", a, .all, .{});
    try chat.restoreShell("busy", "", 100, .none);
    try chat.add("busy", b, .all, .{});

    const live: []const Id = &.{b};

    try testing.expect(!chat.isActive("stale", live));
    try testing.expect(chat.isActive("busy", live));

    // And the negative control on the other side: with nobody open at all,
    // neither is active, so a passing case above cannot have come from
    // `isActive` simply answering true whenever a group has members.
    try testing.expect(!chat.isActive("stale", &.{}));
    try testing.expect(!chat.isActive("busy", &.{}));

    // A live id that is in neither group does not make one active either
    // -- the intersection is with *this group's* members, not with the
    // terminals that happen to be open.
    try testing.expect(!chat.isActive("stale", &.{boss}));
    try testing.expect(!chat.isActive("busy", &.{boss}));

    // The person at the keyboard is in both and neither is active. That
    // is the case counting members gets wrong, and it needs no rule of its
    // own here: `user_id` is zero, a terminal id is documented never to
    // be, so the user is not in `live` and the intersection misses them.
    try testing.expect(chat.isMember("stale", user_id));
    try testing.expect(chat.isMember("busy", user_id));

    // A group nobody ever made is not active, rather than crashing.
    try testing.expect(!chat.isActive("nope", live));
}

test "a group that is spoken in moves to the front of the live ones" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("one", boss);
    try chat.add("one", user_id, .all, .{});
    try chat.create("two", boss);
    try chat.add("two", user_id, .all, .{});

    // Both live, neither spoken in: the name breaks the tie.
    {
        const list = try chat.groupsFor(testing.allocator, user_id, &.{});
        defer testing.allocator.free(list);
        try testing.expectEqualStrings("one", list[0]);
    }

    _ = try chat.post("two", boss, "hello", 5_000);

    const list = try chat.groupsFor(testing.allocator, user_id, &.{});
    defer testing.allocator.free(list);
    try testing.expectEqualStrings("two", list[0]);
    try testing.expectEqualStrings("one", list[1]);
}

test "groupsFor lists what a terminal is in, sorted" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("zebra", boss);
    try chat.create("alpha", boss);
    try chat.create("other", boss);
    try chat.add("zebra", a, .none, .{});
    try chat.add("alpha", a, .none, .{});

    const mine = try chat.groupsFor(testing.allocator, a, &.{a});
    defer testing.allocator.free(mine);

    try testing.expectEqual(@as(usize, 2), mine.len);
    try testing.expectEqualStrings("alpha", mine[0]);
    try testing.expectEqualStrings("zebra", mine[1]);
}

test "unreadTotal counts across every group" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("one", boss);
    try chat.create("two", boss);
    try chat.add("one", a, .none, .{});
    try chat.add("two", a, .none, .{});

    _ = try chat.post("one", boss, "x", 0);
    _ = try chat.post("two", boss, "y", 1);
    _ = try chat.post("two", boss, "z", 2);

    try testing.expectEqual(@as(usize, 3), chat.unreadTotal(a));
}

test "1787: what Polter says in a group signed with its supervisor wakes nobody but the person" {
    // `App.sayStartLineGivenUp`: the record has no author for Polter, so the
    // line is signed with the supervisor it is about and names nobody. It
    // must not come back to that supervisor as something to read, nor wake
    // anybody else in the group -- only be there in the record.
    var chat = testChat();
    defer chat.deinit();
    try chat.create("c1b", boss);
    try chat.add("c1b", a, .none, .{});
    _ = try chat.post("c1b", boss, "[Polter] This supervisor's second message was not typed: no agent connected from its terminal within 60s.", 0);

    try testing.expectEqual(@as(usize, 0), chat.waking("c1b", boss, .supervisor));
    try testing.expectEqual(@as(usize, 0), chat.unread("c1b", boss));
    try testing.expectEqual(@as(usize, 0), chat.waking("c1b", a, .watched));
    // In the record all the same, for whoever reads the group -- the
    // control room shows it to the person.
    try testing.expectEqual(@as(usize, 1), chat.unread("c1b", a));
}

test "a terminal is never unread to itself" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none, .{});
    _ = try chat.post("build", a, "mine", 0);

    try testing.expectEqual(@as(usize, 0), chat.unread("build", a));
    try testing.expectEqual(@as(usize, 1), chat.unread("build", boss));
}

test "notices are rate limited per group and per terminal" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none, .{});
    _ = try chat.post("build", boss, "one", 0);

    try testing.expect(chat.shouldNotify("build", a, 0, 1000, .supervisor));
    try testing.expect(!chat.shouldNotify("build", a, 500, 1000, .supervisor));

    _ = try chat.post("build", boss, "two", 900);
    try testing.expect(chat.shouldNotify("build", a, 1000, 1000, .supervisor));
}

test "letting a worker go does not turn its notices back on" {
    // ⭐ **Task 413, as one assertion.** The defect was not in the release: it
    // was that `watched` and `none` were on opposite sides of this rule, so
    // the release moved a terminal from the silent bucket into the told one.
    // **Nothing in the release path had to be wrong for that to happen.**
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none, .{});
    _ = try chat.post("build", boss, "one", 0);

    // While it is being minded: silent, because its supervisor types into it.
    try testing.expectEqual(@as(usize, 0), chat.waking("build", a, .watched));

    // Released. **This is the cell that was red before 413.**
    try testing.expectEqual(@as(usize, 0), chat.waking("build", a, .none));
}

test "an unmarked terminal is not woken and still sees everything" {
    // The distinction the two numbers exist to keep, and the reason `waking`
    // is not `unread` with a filter on it: a terminal that is not
    // interrupted still has everything waiting for it the moment it looks.
    // ⚠️ Named apart from the older cell of the same shape, which asks this
    // of a *watched* terminal -- 413 added the unmarked one, and folding the
    // two would leave one of the roles untested.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none, .{});
    _ = try chat.post("build", boss, "one", 0);
    _ = try chat.post("build", boss, "two", 0);

    try testing.expectEqual(@as(usize, 0), chat.waking("build", a, .none));
    try testing.expectEqual(@as(usize, 2), chat.unread("build", a));
}

test "a supervisor is the one that is woken" {
    // The other side of the rule, kept as its own cell: silencing everybody
    // would pass the two above and take away the box a supervisor works out
    // of.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none, .{});
    _ = try chat.post("build", boss, "one", 0);

    try testing.expectEqual(@as(usize, 1), chat.waking("build", a, .supervisor));
}

test "being noisy in one group does not silence another" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("one", boss);
    try chat.create("two", boss);
    try chat.add("one", a, .none, .{});
    try chat.add("two", a, .none, .{});

    _ = try chat.post("one", boss, "x", 0);
    _ = try chat.post("two", boss, "y", 0);

    try testing.expect(chat.shouldNotify("one", a, 0, 60_000, .supervisor));
    try testing.expect(chat.shouldNotify("two", a, 0, 60_000, .supervisor));
}

test "forgetting a terminal takes it out of every group" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("one", boss);
    try chat.create("two", boss);
    try chat.add("one", a, .none, .{});
    try chat.add("two", a, .none, .{});

    chat.forget(a);
    try testing.expect(!chat.isMember("one", a));
    try testing.expect(!chat.isMember("two", a));
}

test "destroying a group takes its messages with it" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    _ = try chat.post("build", boss, "something", 0);
    try chat.destroy("build");

    try testing.expect(!chat.exists("build"));
    try testing.expectError(error.NoSuchGroup, chat.post("build", boss, "again", 1));
}

test "a notice names the group but never quotes it" {
    var buf: [256]u8 = undefined;

    const one = try formatNotice("build", 1, &buf);
    try testing.expect(std.mem.indexOf(u8, one, "1 new message ") != null);
    try testing.expect(std.mem.indexOf(u8, one, "\"build\"") != null);
    try testing.expect(std.mem.indexOf(u8, one, "group_read") != null);

    const many = try formatNotice("build", 4, &buf);
    try testing.expect(std.mem.indexOf(u8, many, "4 new messages") != null);
}

test "a group's brief is kept and replaced, not appended to" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try testing.expectEqualStrings("", try chat.briefOf("build"));

    _ = try chat.setBrief("build", "写 retry 装饰器，B 定接口 C 写测试");
    try testing.expectEqualStrings(
        "写 retry 装饰器，B 定接口 C 写测试",
        try chat.briefOf("build"),
    );

    // One note kept current, not a history of intentions.
    _ = try chat.setBrief("build", "接口定了，现在等测试");
    try testing.expectEqualStrings("接口定了，现在等测试", try chat.briefOf("build"));
}

test "zz574 setBrief says how much of the brief it kept" {
    // The floor this is here to hold: a brief too long to store used to be
    // cut in silence, and the only real one to hit the limit was a round's
    // opening instructions whose last section was the rules. "It was cut"
    // is not enough to act on; the two numbers are.
    var chat = testChat();
    defer chat.deinit();
    chat.config.max_text_bytes = 8;

    try chat.create("build", boss);

    const fits = try chat.setBrief("build", "日日");
    try testing.expectEqual(@as(usize, 6), fits.given);
    try testing.expectEqual(@as(usize, 6), fits.kept);
    try testing.expect(!fits.cut());

    const cut = try chat.setBrief("build", "日日日");
    try testing.expectEqual(@as(usize, 9), cut.given);
    try testing.expectEqual(@as(usize, 6), cut.kept);
    try testing.expect(cut.cut());

    // Trailing whitespace is not something that went missing: `given` is
    // measured after the trim, so trimming alone never reads as a cut.
    const spaced = try chat.setBrief("build", "  日日  ");
    try testing.expect(!spaced.cut());
}

test "a brief is cut on a character boundary like any other text" {
    var chat = testChat();
    defer chat.deinit();
    chat.config.max_text_bytes = 8;

    try chat.create("build", boss);
    _ = try chat.setBrief("build", "日日日");

    const brief = try chat.briefOf("build");
    try testing.expect(std.unicode.utf8ValidateSlice(brief));
    try testing.expectEqualStrings("日日", brief);
}

test "a brief does not appear in the messages" {
    // It is a memo the supervisor writes to itself. Reading the group must
    // not hand it to the members.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all, .{});
    _ = try chat.setBrief("build", "这个群在等 B 定接口");
    _ = try chat.post("build", boss, "开始吧", 1);

    const seen = (try chat.read(testing.allocator, "build", a, 0, .unlimited)).messages;
    defer testing.allocator.free(seen);

    try testing.expectEqual(@as(usize, 1), seen.len);
    try testing.expectEqualStrings("开始吧", seen[0].text);
}

test "asking about a group that is not there says so" {
    var chat = testChat();
    defer chat.deinit();

    try testing.expectError(error.NoSuchGroup, chat.briefOf("nope"));
    try testing.expectError(error.NoSuchGroup, chat.setBrief("nope", "x"));
}

test "a member's footing is kept so it can be found again tomorrow" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all, .{
        .cwd = "/work/repo",
        .title = "✳ Write retry.py",
    });

    const f = chat.footingOf("build", a).?;
    try testing.expectEqualStrings("/work/repo", f.cwd);
    try testing.expectEqualStrings("✳ Write retry.py", f.title);
}

test "footing follows a terminal as its title changes" {
    // A tab's title moves with the work. A record frozen at join time
    // would send tomorrow's restart to wherever it happened to start.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all, .{ .cwd = "/work", .title = "zsh" });

    try chat.setFooting("build", a, .{
        .cwd = "/work/repo",
        .title = "✳ Write retry.py",
    });

    const f = chat.footingOf("build", a).?;
    try testing.expectEqualStrings("/work/repo", f.cwd);
    try testing.expectEqualStrings("✳ Write retry.py", f.title);
}

test "a member with nothing known about it is still a member" {
    // A bare shell may have no title, and the host may not know its
    // directory. That is a member with an empty footing, not an error.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all, .{});

    const f = chat.footingOf("build", a).?;
    try testing.expectEqualStrings("", f.cwd);
    try testing.expect(chat.isMember("build", a));
}

test "footing goes away with the member" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all, .{ .cwd = "/work", .title = "t" });
    try chat.remove("build", a);

    try testing.expect(chat.footingOf("build", a) == null);
}

test "forgetting a terminal releases what was known about it" {
    // Same path as a closed surface. The leak check in the allocator is
    // the real assertion here.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.create("research", boss);
    try chat.add("build", a, .all, .{ .cwd = "/work", .title = "t" });
    try chat.add("research", a, .all, .{ .cwd = "/other", .title = "u" });

    chat.forget(a);
    try testing.expect(chat.footingOf("build", a) == null);
    try testing.expect(chat.footingOf("research", a) == null);
}

test "a closed terminal keeps the footing it had" {
    // The moment a terminal goes away is the moment its last known
    // position becomes the only thing a restart has to go on. Updating it
    // with "we no longer know" would throw that away precisely then.
    //
    // The chat cannot see terminals, so it enforces nothing here; this
    // pins the shape the host relies on -- an empty update is the host's
    // to skip, and a real one replaces cleanly.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all, .{ .cwd = "/work/repo", .title = "✳ retry" });

    // What the host does when it learned something new.
    try chat.setFooting("build", a, .{ .cwd = "/work/repo", .title = "✳ tests" });
    try testing.expectEqualStrings("✳ tests", chat.footingOf("build", a).?.title);

    // What it must not do when it learned nothing -- shown here as the
    // effect that would follow if it did.
    try chat.setFooting("build", a, .{});
    try testing.expectEqualStrings("", chat.footingOf("build", a).?.cwd);
}

test "a posted message learns where it landed on disk" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all, .{});

    const seq = (try chat.post("build", a, "hello", 100)).seq;

    {
        const got = (try chat.read(testing.allocator, "build", boss, 0, .unlimited)).messages;
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(u64, 0), got[0].log_seq);
    }

    chat.setLogSeq("build", seq, 10432);

    {
        const got = (try chat.read(testing.allocator, "build", boss, 0, .unlimited)).messages;
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(u64, 10432), got[0].log_seq);
    }
}

test "a member added without history is barred in both numberings" {
    // Two counters saying the same thing, because neither can bound the
    // other: `floor` bounds a walk over what the group still holds, and
    // `log_floor` bounds a walk over the file.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    const seq = (try chat.post("build", boss, "before you arrived", 100)).seq;
    chat.setLogSeq("build", seq, 500);

    try chat.add("build", a, .none, .{});

    const floor = try chat.floorOf("build", a);
    try testing.expectEqual(seq, floor.seq);
    try testing.expectEqual(@as(u64, 500), floor.log_seq);

    // And somebody who was given the history is bounded by nothing.
    try testing.expectEqual(Floor{ .seq = 0, .log_seq = 0 }, try chat.floorOf("build", boss));
}

test "a message logged after a member joined raises that member's log floor" {
    // The host appends and backfills in that order, so the group is told
    // about the log seq after the fact. The bar has to move with it or a
    // `.none` member could read past its own floor.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    const seq = (try chat.post("build", boss, "before you arrived", 100)).seq;
    try chat.add("build", a, .none, .{});

    try testing.expectEqual(@as(u64, 0), (try chat.floorOf("build", a)).log_seq);
    chat.setLogSeq("build", seq, 500);
    try testing.expectEqual(@as(u64, 500), (try chat.floorOf("build", a)).log_seq);
}

test "joining an empty group is not the same as joining an empty log" {
    // The case this exists for is a restart: the supervisor makes the
    // group again under the name the notes gave it, and adds a terminal
    // with no history. The group is empty, so `add` can only draw the line
    // at zero -- and zero is no line at all while the file still holds
    // last night under that same name.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none, .{});
    try testing.expectEqual(@as(u64, 0), (try chat.floorOf("build", a)).log_seq);

    // What the host does about it, knowing where the file had got to.
    chat.setLogFloor("build", a, 10432);
    try testing.expectEqual(@as(u64, 10432), (try chat.floorOf("build", a)).log_seq);
}

test "the log floor is a bar, and a bar is never lowered" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    const seq = (try chat.post("build", boss, "before you arrived", 100)).seq;
    chat.setLogSeq("build", seq, 500);
    try chat.add("build", a, .none, .{});

    // Already barred as far as 500 by what the group itself holds. A host
    // saying the log stops earlier than that does not open it back up.
    chat.setLogFloor("build", a, 300);
    try testing.expectEqual(@as(u64, 500), (try chat.floorOf("build", a)).log_seq);
}

test "a member given the history has no log floor to raise" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .all, .{});
    try testing.expectEqual(@as(u64, 0), (try chat.floorOf("build", a)).log_seq);
}

test "compacting does not make a full-history member look barred" {
    // The floor of a member that was kept out of nothing still moves when
    // the group is compacted -- the summary carries the seq of the last
    // message it replaces, so the floor has to pass it for the summary to
    // be readable at all. What must not move is `barred`.
    //
    // `App.chatHistory` used to ask `floor.seq > 0` instead, which this
    // arrangement answers yes to. The effect was that one `group_compact`
    // shut `group_history` off for every member of the group, and it was
    // found the way it would be found in use: a supervisor read an empty
    // page as "the log is gone" while the day files sat on disk with a
    // night in them.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    const s1 = (try chat.post("build", boss, "one", 100)).seq;
    chat.setLogSeq("build", s1, 1866);
    const s2 = (try chat.post("build", boss, "two", 101)).seq;
    chat.setLogSeq("build", s2, 1867);

    try chat.add("build", a, .all, .{});
    try testing.expectEqual(Floor{ .seq = 0, .log_seq = 0 }, try chat.floorOf("build", a));

    _ = try chat.compact("build", s2, "what those two amounted to", boss, 200);

    const floor = try chat.floorOf("build", a);
    try testing.expect(floor.seq > 0);
    try testing.expect(!floor.barred);
}

test "compacting does not unbar a member that joined without history" {
    // The other direction of the same fix, because loosening the test
    // `App.chatHistory` makes is exactly how it would be got wrong: a
    // member added with `.none` must still be barred afterwards, and still
    // bounded at the log seq it was barred at.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    const s1 = (try chat.post("build", boss, "before you arrived", 100)).seq;
    chat.setLogSeq("build", s1, 1866);

    try chat.add("build", a, .none, .{});
    try testing.expect((try chat.floorOf("build", a)).barred);

    const s2 = (try chat.post("build", boss, "after", 101)).seq;
    chat.setLogSeq("build", s2, 1867);
    _ = try chat.compact("build", s2, "what those amounted to", boss, 200);

    const floor = try chat.floorOf("build", a);
    try testing.expect(floor.barred);
    try testing.expectEqual(@as(u64, 1867), floor.log_seq);
}

test "a watched terminal is not woken, whoever spoke" {
    // The rule is about the *reader*, so both directions have to be shown:
    // the supervisor's own message and a peer's are equally not this
    // terminal's to be interrupted by. Its supervisor reaches it by typing
    // into it, and that is the channel that is meant to work.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none, .{});
    try chat.add("build", b, .none, .{});

    _ = try chat.post("build", boss, "here is the plan", 0);
    try testing.expectEqual(@as(usize, 0), chat.waking("build", a, .watched));
    try testing.expect(!chat.shouldNotify("build", a, 0, 1000, .watched));

    _ = try chat.post("build", b, "core is green", 1);
    try testing.expectEqual(@as(usize, 0), chat.waking("build", a, .watched));
    try testing.expect(!chat.shouldNotify("build", a, 1, 1000, .watched));
}

test "an unminded terminal is woken by both, because the group is all it has" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none, .{});
    try chat.add("build", b, .none, .{});

    _ = try chat.post("build", boss, "here is the plan", 0);
    try testing.expectEqual(@as(usize, 1), chat.waking("build", a, .supervisor));
    try testing.expect(chat.shouldNotify("build", a, 0, 1000, .supervisor));

    _ = try chat.post("build", b, "core is green", 1);
    try testing.expectEqual(@as(usize, 2), chat.waking("build", a, .supervisor));
}

test "a supervisor is woken by both, because that is how it hears" {
    var chat = testChat();
    defer chat.deinit();

    const boss2: Id = 0x4444;

    try chat.create("build", boss);
    try chat.add("build", boss2, .none, .{});
    try chat.add("build", a, .none, .{});

    _ = try chat.post("build", boss2, "here is the plan", 0);
    try testing.expectEqual(@as(usize, 1), chat.waking("build", boss, .supervisor));

    _ = try chat.post("build", a, "core is green", 1);
    try testing.expectEqual(@as(usize, 2), chat.waking("build", boss, .supervisor));
}

test "not being woken is not being kept out" {
    // The line the whole thing rests on, and the one that is easiest to
    // lose: `a` is watched and never interrupted, and still has every
    // message unread, still reads all of them, and reads each once.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none, .{});
    try chat.add("build", b, .none, .{});

    _ = try chat.post("build", boss, "here is the plan", 0);
    _ = try chat.post("build", b, "core is green", 1);

    try testing.expectEqual(@as(usize, 0), chat.waking("build", a, .watched));
    try testing.expectEqual(@as(usize, 2), chat.unread("build", a));
    try testing.expectEqual(@as(usize, 2), chat.unreadTotal(a));

    const seen = (try chat.read(testing.allocator, "build", a, 0, .unlimited)).messages;
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 2), seen.len);
    try testing.expectEqualStrings("here is the plan", seen[0].text);
    try testing.expectEqualStrings("core is green", seen[1].text);
    try testing.expectEqual(@as(usize, 0), chat.unread("build", a));

    // And what it may see is still decided by its floor, not by this: it
    // joined with `.none`, so anything said before it arrived stays hidden.
    try chat.add("build", 0x5555, .none, .{});
    _ = try chat.post("build", boss, "after", 2);
    const late = (try chat.read(testing.allocator, "build", 0x5555, 0, .unlimited)).messages;
    defer testing.allocator.free(late);
    try testing.expectEqual(@as(usize, 1), late.len);
}

test "a named member is woken for what names it, and nobody else is woken at all" {
    // Task 575, part four of the contract. ⭐ **The second half is the
    // point**: the obvious way to get the first half right is to wake
    // everybody, and every assertion about the named member would still
    // pass. `b` is the positive control -- in the group, unread, not named.
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none, .{});
    try chat.add("build", b, .none, .{});

    _ = try chat.post("build", boss, "for everybody", 0);
    _ = try chat.postMentioning("build", boss, "for a", &.{a}, 1);

    // Both can see both messages -- `unread` is untouched by naming.
    try testing.expectEqual(@as(usize, 2), chat.unread("build", a));
    try testing.expectEqual(@as(usize, 2), chat.unread("build", b));

    // `a` is woken for the one that names it, whatever its standing.
    try testing.expectEqual(@as(usize, 1), chat.waking("build", a, .watched));
    try testing.expectEqual(@as(usize, 1), chat.waking("build", a, .none));

    // `b` is exactly where it was before mentions existed.
    try testing.expectEqual(@as(usize, 0), chat.waking("build", b, .watched));
    try testing.expectEqual(@as(usize, 0), chat.waking("build", b, .none));
    try testing.expect(!chat.shouldNotify("build", b, 0, 1000, .watched));

    // A supervisor was already woken for everything; naming adds nothing.
    try testing.expectEqual(@as(usize, 2), chat.waking("build", a, .supervisor));

    // Having read it, `a` is not woken again for it.
    const seen = (try chat.read(testing.allocator, "build", a, null, .unlimited)).messages;
    defer testing.allocator.free(seen);
    try testing.expectEqual(@as(usize, 0), chat.waking("build", a, .watched));
}

test "one name that is not in the group refuses the whole post" {
    var chat = testChat();
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none, .{});

    try testing.expectError(
        error.MentionNotAMember,
        chat.postMentioning("build", boss, "hello", &.{ a, 0xdead }, 0),
    );
    try testing.expectError(
        error.MentionSelf,
        chat.postMentioning("build", boss, "hello", &.{boss}, 0),
    );

    // Nothing landed, and nobody has anything waiting.
    try testing.expectEqual(@as(usize, 0), chat.unread("build", a));
    try testing.expectEqual(@as(usize, 0), chat.groups.getPtr("build").?.log.items.len);
}

test "a mention typed into a terminal is one line with the names frozen in it" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeName(&aw.writer, 0x2528abcdef012345, "M-core");
    try testing.expectEqualStrings("@2528abcd M-core", aw.written());

    const line = try formatDelivery(testing.allocator, "build", 7, 0x1111, "boss", "@2222 w\nrun it\r\nnow");
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("[poltergeist] build #7 @1111 boss: @2222 w run it  now", line);
    try testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
}

test "named messages that fall off the end or are compacted are freed" {
    // `testing.allocator` is the assertion: a leaked `mentions` slice fails
    // the test at `deinit`.
    var chat: Chat = .init(testing.allocator, .{ .max_messages = 2 });
    defer chat.deinit();

    try chat.create("build", boss);
    try chat.add("build", a, .none, .{});
    _ = try chat.postMentioning("build", boss, "one", &.{a}, 0);
    _ = try chat.postMentioning("build", boss, "two", &.{ a, a }, 1);
    _ = try chat.postMentioning("build", boss, "three", &.{a}, 2);
    try testing.expectEqual(@as(usize, 1), chat.groups.getPtr("build").?.log.items[0].mentions.len);
    _ = try chat.compact("build", 3, "summary", boss, 3);
}

test "ControlRoom marks: seen and snooze are kept per group and survive a rename" {
    var chat = testChat();
    defer chat.deinit();
    try chat.create("build", 7);

    try testing.expectEqual(Marks.none, try chat.marksOf("build"));
    try testing.expectEqual(@as(?u64, null), chat.seenRunMs("build"));
    try testing.expectError(error.NoSuchGroup, chat.markSeen("nope", 1, 2));

    try chat.markSeen("build", 5_000, 1_700_000_000_000);
    try chat.setSnooze("build", .{ .next_event = 1_700_000_000_500 }, 5_500);
    try chat.rename("build", "nightly");

    const m = try chat.marksOf("nightly");
    try testing.expectEqual(@as(?u64, 1_700_000_000_000), m.seen_ms);
    try testing.expectEqual(@as(?u64, 5_000), chat.seenRunMs("nightly"));
    try testing.expectEqual(Attention.Snooze{ .until_change = 5_500 }, chat.snoozeOf("nightly", 6_000, 0));
}

test "ControlRoom marks: a timed snooze is carried from the wall clock onto the bus clock" {
    var chat = testChat();
    defer chat.deinit();
    try chat.create("build", 7);

    const wall: u64 = 1_700_000_000_000;
    try chat.setSnooze("build", .{ .until = .{ .at_ms = wall, .until_ms = wall + 90_000 } }, 1_000);
    try testing.expectEqual(Attention.Snooze{ .until_ms = 4_000 + 60_000 }, chat.snoozeOf("build", 4_000, wall + 30_000));
    // Past it on the wall clock: over, whatever the bus clock says.
    try testing.expectEqual(Attention.Snooze{ .until_ms = 4_000 }, chat.snoozeOf("build", 4_000, wall + 99_000));

    try chat.setSnooze("build", .none, 5_000);
    try testing.expectEqual(Attention.Snooze.none, chat.snoozeOf("build", 6_000, wall));
}

test "ControlRoom marks: marks that came back off disk have seen nothing in this run" {
    var chat = testChat();
    defer chat.deinit();
    try chat.restoreShell("build", "", 0, .none);
    var marks: Marks = .none;
    marks.seen_ms = 1_700_000_000_000;
    marks.snooze = .{ .next_event = 1_700_000_000_000 };
    try chat.restoreMarks("build", marks);

    try testing.expectEqual(@as(?u64, 1_700_000_000_000), (try chat.marksOf("build")).seen_ms);
    try testing.expectEqual(@as(?u64, null), chat.seenRunMs("build"));
    try testing.expectEqual(Attention.Snooze{ .until_change = 0 }, chat.snoozeOf("build", 9_000, 1_700_000_100_000));
}

test "ControlRoom start: while its CLI asks the person a question, the wait for its agent does not run out" {
    var chat = testChat();
    defer chat.deinit();
    try chat.restoreShell("build", "", 0, .none);

    try chat.beginStart("build", 1_000, 11_000, false, .directory);
    // No tab yet: nothing to be asking in.
    try testing.expect(!chat.startAsking("build", true, 999_000, 2_000));
    try testing.expect(!chat.startOf("build", 2_000).asking);

    chat.startOpened("build", 0xA, 2_000 + 60_000);
    // The trust box is up, seen again and again: each sighting holds the
    // wait a minute past it.
    try testing.expect(chat.startAsking("build", true, 50_000 + 60_000, 50_000));
    try testing.expect(!chat.startAsking("build", true, 100_000 + 60_000, 100_000));
    const held = chat.startOf("build", 150_000);
    try testing.expect(held.state == .starting);
    try testing.expect(held.asking);
    try testing.expectEqual(@as(?u64, 160_000), held.deadline_ms);

    // Answered: the wait runs again from the last sighting, and runs out.
    try testing.expect(chat.startAsking("build", false, 155_000 + 60_000, 155_000));
    const answered = chat.startOf("build", 160_000);
    try testing.expect(answered.state == .starting);
    try testing.expect(!answered.asking);
    const silent = chat.startOf("build", 160_001);
    try testing.expectEqual(StartFailure.agent_never_connected, silent.failed);
    try testing.expect(!silent.asking);
    // A start that has run out is not brought back by a box seen late.
    try testing.expect(!chat.startAsking("build", true, 999_000, 160_001));
    try testing.expect(chat.startOf("build", 160_001).state == .failed);
}

test "ControlRoom start: a supervisor on its way waits for its tab, then for its agent, and each wait can run out" {
    var chat = testChat();
    defer chat.deinit();
    try chat.restoreShell("build", "", 0, .none);

    try testing.expectEqual(StartView.none, chat.startOf("build", 1_000));
    try testing.expectError(error.NoSuchGroup, chat.beginStart("nope", 1_000, 11_000, false, .directory));

    try chat.beginStart("build", 1_000, 11_000, false, .directory);
    try testing.expectEqualStrings("build", chat.startAwaitingTerminal(2_000).?);
    const waiting = chat.startOf("build", 2_000);
    try testing.expect(waiting.state == .starting);
    try testing.expectEqual(@as(?Id, null), waiting.terminal);
    try testing.expectEqual(@as(?u64, 11_000), waiting.deadline_ms);
    // A second press while the first is still waiting starts nothing.
    try testing.expectError(error.AlreadyStarting, chat.beginStart("build", 2_000, 12_000, false, .directory));

    // The tab never came.
    const no_tab = chat.startOf("build", 11_001);
    try testing.expect(no_tab.state == .failed);
    try testing.expectEqual(StartFailure.terminal_never_opened, no_tab.failed);
    try testing.expectEqual(@as(?[]const u8, null), chat.startAwaitingTerminal(11_001));

    // Trying again replaces what failed.
    try chat.beginStart("build", 12_000, 22_000, false, .directory);
    chat.startOpened("build", 0xa1, 72_000);
    try testing.expectEqual(@as(?[]const u8, null), chat.startAwaitingTerminal(13_000));
    try testing.expectEqualStrings("build", chat.startingIn(0xa1, 13_000).?);
    try testing.expectEqual(@as(?[]const u8, null), chat.startingIn(0xa2, 13_000));
    const opened = chat.startOf("build", 13_000);
    try testing.expect(opened.state == .starting);
    try testing.expectEqual(@as(?Id, 0xa1), opened.terminal);

    // The tab is there and nobody connected from it.
    const silent = chat.startOf("build", 72_001);
    try testing.expect(silent.state == .failed);
    try testing.expectEqual(StartFailure.agent_never_connected, silent.failed);
    try testing.expectEqual(@as(?[]const u8, null), chat.startingIn(0xa1, 72_001));

    chat.endStart("build");
    try testing.expectEqual(StartView.none, chat.startOf("build", 72_001));
}

test "ControlRoom start: closing the terminal a supervisor was starting in fails the start, and it survives a rename" {
    var chat = testChat();
    defer chat.deinit();
    try chat.restoreShell("build", "", 0, .none);
    try chat.beginStart("build", 1_000, 11_000, false, .directory);
    chat.startOpened("build", 0xa1, 61_000);

    try chat.rename("build", "nightly");
    try testing.expectEqualStrings("nightly", chat.startingIn(0xa1, 2_000).?);

    chat.forget(0xa2);
    try testing.expect(chat.startOf("nightly", 2_000).state == .starting);
    chat.forget(0xa1);
    const closed = chat.startOf("nightly", 2_000);
    try testing.expect(closed.state == .failed);
    try testing.expectEqual(StartFailure.terminal_closed, closed.failed);
    // And stays that, however long ago the deadline was.
    try testing.expectEqual(StartFailure.terminal_closed, chat.startOf("nightly", 999_000).failed);
}

test "ControlRoom start: where a supervisor is started -- the last one's directory, kept, and what most members are in" {
    var chat = testChat();
    defer chat.deinit();
    try chat.restoreShell("build", "", 0, .none);

    try testing.expectEqualStrings("", chat.supervisorDirOf("build"));
    try testing.expectEqualStrings("", chat.commonDirOf("build"));

    var last: LastSupervisor = .none;
    last.dir = "/work/repo";
    last.dir_from = .supervisor;
    try testing.expectEqual(LastChange.who, try chat.setLastSupervisor("build", last));
    // The same again is not a change.
    try testing.expectEqual(LastChange.same, try chat.setLastSupervisor("build", last));
    try testing.expectEqualStrings("/work/repo", chat.supervisorDirOf("build"));
    try chat.rename("build", "nightly");
    try testing.expectEqualStrings("/work/repo", chat.supervisorDirOf("nightly"));

    try chat.add("nightly", 0xb1, .all, .{ .cwd = "/z/one", .title = "" });
    try chat.add("nightly", 0xb2, .all, .{ .cwd = "/a/two", .title = "" });
    // One each: the one that sorts first, every time.
    try testing.expectEqualStrings("/a/two", chat.commonDirOf("nightly"));
    try chat.add("nightly", 0xb3, .all, .{ .cwd = "/z/one", .title = "" });
    try chat.add("nightly", 0xb4, .all, .{});
    try testing.expectEqualStrings("/z/one", chat.commonDirOf("nightly"));
}

test "ControlRoom marks: a group comes back from disk with what the person had said about it" {
    var chat = testChat();
    defer chat.deinit();
    const wall: u64 = 1_700_000_000_000;
    var marks: Marks = .none;
    marks.seen_ms = wall;
    marks.snooze = .{ .until = .{ .at_ms = wall, .until_ms = wall + 3_600_000 } };
    try chat.restoreShell("build", "", 0, marks);

    // Still put aside until the hour is up, across the restart...
    try testing.expectEqual(@as(?u64, wall), (try chat.marksOf("build")).seen_ms);
    try testing.expectEqual(Attention.Snooze{ .until_ms = 5_000 + 1_800_000 }, chat.snoozeOf("build", 5_000, wall + 1_800_000));
    // ...and nothing in this run has been looked at: what finishes after
    // the restart is not already seen because something was seen before it.
    try testing.expectEqual(@as(?u64, null), chat.seenRunMs("build"));

    // A group nobody marked comes back with none.
    try chat.restoreShell("quiet", "", 0, .none);
    try testing.expectEqual(Marks.none, try chat.marksOf("quiet"));
    try testing.expectEqual(Attention.Snooze.none, chat.snoozeOf("quiet", 5_000, wall));
}

test "group cursor: posting does not carry the poster past what it had not read" {
    // The night this is from: three messages reached a supervisor between
    // its last read and its own next post, and it never saw any of them --
    // one of them a delivery.
    var chat = testChat();
    defer chat.deinit();
    try chat.create("build", boss);
    try chat.add("build", a, .all, .{});

    // The supervisor reads up to n.
    const n = (try chat.post("build", a, "started", 0)).seq;
    {
        const got = (try chat.read(testing.allocator, "build", boss, null, .unlimited)).messages;
        defer testing.allocator.free(got);
        try testing.expectEqual(n, got[got.len - 1].seq);
    }

    // A worker posts n+1; before reading it, the supervisor posts n+2.
    const missed = (try chat.post("build", a, "delivered: all green", 1)).seq;
    const own = (try chat.post("build", boss, "next task is out", 2)).seq;
    try testing.expectEqual(n + 1, missed);
    try testing.expectEqual(n + 2, own);

    // It is still unread, and still counted as such...
    try testing.expectEqual(@as(usize, 1), chat.unread("build", boss));
    try testing.expectEqual(@as(usize, 1), chat.waking("build", boss, .supervisor));

    // ...and a read that says nothing about where to start hands it over.
    const got = (try chat.read(testing.allocator, "build", boss, null, .unlimited)).messages;
    defer testing.allocator.free(got);
    try testing.expect(got.len >= 1);
    try testing.expectEqual(missed, got[0].seq);
    try testing.expectEqualStrings("delivered: all green", got[0].text);
    try testing.expectEqual(@as(usize, 0), chat.unread("build", boss));

    // Nothing is handed over twice afterwards.
    const again = (try chat.read(testing.allocator, "build", boss, null, .unlimited)).messages;
    defer testing.allocator.free(again);
    try testing.expectEqual(@as(usize, 0), again.len);
}

test "group cursor: a poster that was up to date stays up to date, and is not handed its own words back" {
    var chat = testChat();
    defer chat.deinit();
    try chat.create("build", boss);
    try chat.add("build", a, .all, .{});

    _ = try chat.post("build", a, "one", 0);
    {
        const got = (try chat.read(testing.allocator, "build", boss, null, .unlimited)).messages;
        defer testing.allocator.free(got);
    }
    // Nothing unread in between: its own post, and the one after, move it.
    _ = try chat.post("build", boss, "two", 1);
    _ = try chat.post("build", boss, "three", 2);
    const got = (try chat.read(testing.allocator, "build", boss, null, .unlimited)).messages;
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);

    // A member kept out of what came before it (`history: none`) is not
    // held back by messages it may not see.
    try chat.add("build", b, .none, .{});
    _ = try chat.post("build", b, "hello", 3);
    const none = (try chat.read(testing.allocator, "build", b, null, .unlimited)).messages;
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "group notice: a message that arrives inside the gap is told when the gap is over, not never" {
    // 7119 and 7120 were twenty-two seconds apart. The second fell inside
    // the thirty-second gap after the first one's notice, and nothing ever
    // came back for it.
    var chat = testChat();
    defer chat.deinit();
    try chat.create("build", boss);
    try chat.add("build", a, .all, .{});
    const gap: u64 = 30_000;

    _ = try chat.post("build", a, "one", 1_000);
    try testing.expectEqual(@as(?u64, null), chat.notifyWaitMs("build", boss, 1_000, gap, .supervisor));
    try testing.expect(chat.shouldNotify("build", boss, 1_000, gap, .supervisor));

    // Twenty-two seconds later, another. Not told now...
    _ = try chat.post("build", a, "two", 23_000);
    try testing.expect(!chat.shouldNotify("build", boss, 23_000, gap, .supervisor));
    // ...and that is a wait with an end, which the caller comes back at.
    try testing.expectEqual(@as(?u64, 8_000), chat.notifyWaitMs("build", boss, 23_000, gap, .supervisor));
    try testing.expectEqual(@as(?u64, null), chat.notifyWaitMs("build", boss, 31_000, gap, .supervisor));
    try testing.expect(chat.shouldNotify("build", boss, 31_000, gap, .supervisor));

    // Told about everything there is: a sweep that comes round again --
    // they run without a post now -- says nothing and waits for nothing.
    try testing.expect(!chat.shouldNotify("build", boss, 90_000, gap, .supervisor));
    try testing.expectEqual(@as(?u64, null), chat.notifyWaitMs("build", boss, 90_000, gap, .supervisor));
    // Unless that notice never reached it: then it was not told.
    chat.noticeRefused(boss);
    try testing.expect(chat.shouldNotify("build", boss, 90_000, gap, .supervisor));

    // Nothing worth waking for is not a wait: a watched terminal named in
    // nothing, and a reader that has read it all.
    try testing.expectEqual(@as(?u64, null), chat.notifyWaitMs("build", boss, 32_000, gap, .watched));
    {
        const got = (try chat.read(testing.allocator, "build", boss, null, .unlimited)).messages;
        defer testing.allocator.free(got);
    }
    try testing.expectEqual(@as(?u64, null), chat.notifyWaitMs("build", boss, 32_000, gap, .supervisor));
}

test "ControlRoom resume: a group's last supervisor is replaced whole, and says what that changed" {
    var chat = testChat();
    defer chat.deinit();
    try chat.restoreShell("build", "", 0, .none);

    // Nothing written down is `none`, for a group that is there and one
    // that is not.
    try testing.expect(chat.lastSupervisorOf("build").isNone());
    try testing.expect(chat.lastSupervisorOf("nope").isNone());
    try testing.expect(!chat.anySessionKept());
    try testing.expectError(error.NoSuchGroup, chat.setLastSupervisor("nope", .none));

    const first: LastSupervisor = .{
        .dir = "/work/repo",
        .dir_from = .supervisor,
        .role = "polter-supervisor",
        .cli = "claude-code",
        .session = "s-1",
        .heard_ms = 100,
    };
    try testing.expectEqual(LastChange.who, try chat.setLastSupervisor("build", first));
    try testing.expectEqual(LastChange.same, try chat.setLastSupervisor("build", first));
    try testing.expect(chat.anySessionKept());

    // Heard from again and nothing else: not worth a write by itself.
    var later = first;
    later.heard_ms = 200;
    try testing.expectEqual(LastChange.heard, try chat.setLastSupervisor("build", later));
    try testing.expectEqual(@as(?u64, 200), chat.lastSupervisorOf("build").heard_ms);

    // Each part on its own is a change of who.
    inline for (.{ "dir", "role", "cli", "session" }) |field| {
        var other = chat.lastSupervisorOf("build");
        @field(other, field) = "something-else";
        try testing.expectEqual(LastChange.who, try chat.setLastSupervisor("build", other));
        try testing.expectEqualStrings("something-else", @field(chat.lastSupervisorOf("build"), field));
    }

    // What is not known now is written as not known: a session that the
    // new record does not have is gone, not carried over.
    var cleared = chat.lastSupervisorOf("build");
    cleared.session = "";
    try testing.expectEqual(LastChange.who, try chat.setLastSupervisor("build", cleared));
    try testing.expectEqualStrings("", chat.lastSupervisorOf("build").session);
    try testing.expect(!chat.anySessionKept());

    // A record built out of the one the chat holds is copied before the
    // old one is let go.
    var same_dir = chat.lastSupervisorOf("build");
    same_dir.role = "night-lead";
    try testing.expectEqual(LastChange.who, try chat.setLastSupervisor("build", same_dir));
    try testing.expectEqualStrings("something-else", chat.lastSupervisorOf("build").dir);

    // It goes with the group when the group is renamed.
    try chat.rename("build", "nightly");
    try testing.expectEqualStrings("night-lead", chat.lastSupervisorOf("nightly").role);
}

test "ControlRoom resume: a start says whether it went on with the last session, and the terminal it made is remembered" {
    var chat = testChat();
    defer chat.deinit();
    try chat.restoreShell("build", "", 0, .none);
    try chat.restoreShell("alpha", "", 0, .none);

    // A start that went on with the last session and ran out of time reads
    // as one that did; a new one that failed does not.
    try chat.beginStart("build", 1_000, 11_000, true, .directory);
    try testing.expect(chat.startOf("build", 2_000).resuming);
    const out_of_time = chat.startOf("build", 11_001);
    try testing.expectEqual(StartFailure.terminal_never_opened, out_of_time.failed);
    try testing.expect(out_of_time.resuming);

    try chat.beginStart("build", 12_000, 22_000, false, .directory);
    chat.startOpened("build", 0xa1, 72_000);
    chat.failStart("build", .cli_not_found);
    try testing.expect(!chat.startOf("build", 13_000).resuming);
    try testing.expect(!StartView.none.resuming);

    // Nobody was started for anything yet.
    try testing.expectEqual(@as(?[]const u8, null), chat.startedFor(0xa1));

    try chat.beginStart("build", 80_000, 90_000, true, .directory);
    chat.startOpened("build", 0xa1, 140_000);
    chat.startMade("build", 0xa1);
    try testing.expectEqual(@as(@TypeOf(chat.startOf("build", 0).state), .none), chat.startOf("build", 81_000).state);
    try testing.expectEqualStrings("build", chat.startedFor(0xa1).?);
    try testing.expectEqual(@as(?[]const u8, null), chat.startedFor(0xa2));

    // Started for two: the same answer every time, the name that sorts
    // first. And it follows a rename.
    try chat.beginStart("alpha", 80_000, 90_000, false, .directory);
    chat.startMade("alpha", 0xa1);
    try testing.expectEqualStrings("alpha", chat.startedFor(0xa1).?);
    try chat.rename("alpha", "zeta");
    try testing.expectEqualStrings("build", chat.startedFor(0xa1).?);
}

test "Projects: a group's tie is one of three, kept across a rename, and a start by project waits for no tab" {
    var chat = testChat();
    defer chat.deinit();
    try chat.restoreShell("build", "", 0, .none);
    try chat.restoreShell("other", "", 0, .none);

    // Nobody has said, for a group that is there and one that is not.
    try testing.expect(chat.projectOf("build") == .undecided);
    try testing.expect(chat.projectOf("nope") == .undecided);
    try testing.expectError(error.NoSuchGroup, chat.setProject("nope", .declined));

    try testing.expect(try chat.setProject("build", .{ .bound = "scratch" }));
    try testing.expect(!try chat.setProject("build", .{ .bound = "scratch" }));
    try testing.expectEqualStrings("scratch", chat.projectOf("build").bound);
    // A tie built out of the one the chat holds is copied before the old
    // one is let go.
    try testing.expect(!try chat.setProject("build", chat.projectOf("build")));
    try testing.expect(try chat.setProject("build", .{ .bound = "build" }));
    // It goes with the group, under the name the host still has it by.
    try chat.rename("build", "nightly");
    try testing.expectEqualStrings("build", chat.projectOf("nightly").bound);
    // Said to have none is not nobody having said.
    try testing.expect(try chat.setProject("nightly", .declined));
    try testing.expect(chat.projectOf("nightly") == .declined);
    try testing.expect(try chat.setProject("nightly", .undecided));

    // Taken up: worked out, then said -- and joining again does not unsay it.
    try testing.expectEqual(@as(?ProjectClaim, null), chat.projectClaimOf("nightly"));
    chat.setProjectClaim("nightly", .{ .terminal = 0xa1, .said = false });
    try testing.expect(!chat.projectClaimOf("nightly").?.said);
    chat.setProjectClaim("nightly", .{ .terminal = 0xa1, .said = true });
    chat.setProjectClaim("nightly", .{ .terminal = 0xa1, .said = false });
    try testing.expect(chat.projectClaimOf("nightly").?.said);
    // Another supervisor taking it up is another claim.
    chat.setProjectClaim("nightly", .{ .terminal = 0xa2, .said = false });
    try testing.expectEqual(@as(Id, 0xa2), chat.projectClaimOf("nightly").?.terminal);
    chat.setProjectClaim("nightly", null);
    try testing.expectEqual(@as(?ProjectClaim, null), chat.projectClaimOf("nightly"));

    // A start that opens the group's project: it waits for the host to say
    // which terminal, and **the next tab anybody opens is not it**.
    try chat.beginStart("nightly", 1_000, 31_000, false, .project);
    try testing.expect(chat.startAwaitingProject("nightly", 2_000));
    try testing.expectEqual(@as(?[]const u8, null), chat.startAwaitingTerminal(2_000));
    try testing.expectEqual(StartBy.project, chat.startOf("nightly", 2_000).by.?);
    // A start by directory beside it is the one a new tab belongs to.
    try chat.beginStart("other", 1_000, 11_000, false, .directory);
    try testing.expectEqualStrings("other", chat.startAwaitingTerminal(2_000).?);
    try testing.expect(!chat.startAwaitingProject("other", 2_000));

    // Told its terminal, it is waiting for the agent and no longer for the
    // project; out of time, it is not waiting at all.
    chat.startOpened("nightly", 0xa1, 91_000);
    try testing.expect(!chat.startAwaitingProject("nightly", 3_000));
    try testing.expectEqualStrings("nightly", chat.startingIn(0xa1, 3_000).?);
    chat.endStart("nightly");
    try chat.beginStart("nightly", 100_000, 130_000, false, .project);
    try testing.expect(!chat.startAwaitingProject("nightly", 130_001));
    // Waiting for its project, not for a tab: it says so (task 1794).
    try testing.expectEqual(StartFailure.project_never_opened, chat.startOf("nightly", 130_001).failed);
    try testing.expect(StartView.none.by == null);
}

test "task 1794: a start that ran out of time says what it was waiting for, and a project start can go on in a directory" {
    // What it was waiting for, three ways.
    try testing.expectEqual(StartFailure.terminal_never_opened, timedOut(.directory, false));
    try testing.expectEqual(StartFailure.project_never_opened, timedOut(.project, false));
    try testing.expectEqual(StartFailure.agent_never_connected, timedOut(.project, true));
    try testing.expectEqual(StartFailure.agent_never_connected, timedOut(.directory, true));

    var chat = testChat();
    defer chat.deinit();
    try chat.restoreShell("nightly", "", 0, .none);
    try chat.restoreShell("other", "", 0, .none);

    // A project start whose project opened with no supervisor's pane goes
    // on as a start in a directory: the next tab is its, with a tab's time.
    try chat.beginStart("nightly", 1_000, 31_000, false, .project);
    try testing.expect(chat.startByDirectory("nightly", 21_000));
    try testing.expectEqual(StartBy.directory, chat.startOf("nightly", 2_000).by.?);
    try testing.expectEqualStrings("nightly", chat.startAwaitingTerminal(2_000).?);
    try testing.expect(!chat.startAwaitingProject("nightly", 2_000));
    try testing.expectEqual(StartFailure.terminal_never_opened, chat.startOf("nightly", 21_001).failed);

    // Only such a start: one in a directory already, or one with its
    // terminal, is left as it is.
    try chat.beginStart("other", 1_000, 11_000, false, .directory);
    try testing.expect(!chat.startByDirectory("other", 99_000));
    try testing.expectEqual(@as(?u64, 11_000), chat.startOf("other", 2_000).deadline_ms);
    chat.endStart("nightly");
    try chat.beginStart("nightly", 40_000, 70_000, false, .project);
    chat.startOpened("nightly", 0xa1, 90_000);
    try testing.expect(!chat.startByDirectory("nightly", 99_000));
    try testing.expectEqual(StartBy.project, chat.startOf("nightly", 41_000).by.?);
}
