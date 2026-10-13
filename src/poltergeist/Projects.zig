//! Which project is which group's: the one-to-one tie between them, kept
//! in step across two programs that each own half of it.
//!
//! **The halves.** A group is the core's: its record is
//! `<state>/chat/<group>/group.json`, and that is where the tie is written
//! (`Chat.ProjectTie`). A project is the host's: it reads and writes the
//! project file, it knows which tab is a page of which project, and it is
//! the only one that can open one. The project file carries the group's
//! name too (`Project.zig`, `group`), but **the group's record is the one
//! that counts** and the project's is a mirror -- with one exception, in
//! `reconcile`, for a group whose record lost the key.
//!
//! **How the two talk.** Neither sends the other events.
//!
//!   * The host *states* everything it knows about projects, whole, each
//!     time any of it changes (`ControlAct`, `{"act":"projects",...}`):
//!     every project, the group its file names, how many pages it has, and
//!     -- when it is open -- which terminals are on which page and which
//!     one is in the supervisor's pane. A statement replaces the last one.
//!     Losing one costs nothing: the next says it all again.
//!   * The core answers with *orders* in the control room's snapshot
//!     (`project_orders`): what the host has to do for its half to match --
//!     open this project, make one, tie one, rename one, put a tab in one.
//!     An order is worked out afresh from the tie and the last statement
//!     every time, so it stays there until the host has done it and said
//!     so, and is gone the moment it has. Nothing is acknowledged.
//!
//! Until the host has stated anything, what projects there are is **not
//! known** -- which is not "there are none". Nothing is tied, untied or
//! ordered on not knowing, so a host that never states (every host before
//! this) sees exactly what it saw before.
//!
//! **A tie is offered, not guessed.** An old group gets a project when it
//! is taken up -- a supervisor is started for it or joins it -- and only
//! when there is one way to read the situation (`Why`). Anything else is
//! left alone and said, and the supervisor has a tool to say which
//! (`group_project`).
//!
//! This file decides and holds no group by name: what a group's tie *is*
//! lives in `Chat`, and what `reconcile` works out is handed back for the
//! app to carry out.

const Projects = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Bus = @import("Bus.zig");
const Chat = @import("Chat.zig");

pub const Id = Bus.Id;
pub const Tie = Chat.ProjectTie;

/// One project, as the host last described it.
pub const Stated = struct {
    name: []const u8,
    /// The group its file names; null when it names none.
    group: ?[]const u8,
    /// How many pages (tabs) it has, open or not.
    pages: usize,
    /// When it is open: the terminals on each page, in the pages' order.
    /// Null when it is not open. A page that is in the project and closed
    /// just now is not in here.
    open: ?[]const []const Id,
    /// When it is open: the terminal in the pane its file marks as the
    /// supervisor's. Null when it is not open, or marks none.
    supervisor: ?Id,
    /// When it is open: the terminals in the panes its file marks as
    /// opened by its supervisor, whoever is in them now. Empty when it is
    /// not open, or marks none. This is how "the supervisor's own panes"
    /// outlives a restart: terminal ids do not, the file's mark does, and
    /// the host says here which terminals the marked panes are this time.
    workers: []const Id,

    fn holds(self: Stated, terminal: Id) bool {
        const pages = self.open orelse return false;
        for (pages) |page| {
            if (std.mem.indexOfScalar(Id, page, terminal) != null) return true;
        }
        return false;
    }
};

alloc: Allocator,

/// What the host last stated, and the arena it is in. Null until it has
/// stated anything: not known, which is not an empty list.
stated: ?[]const Stated = null,
arena: ?std.heap.ArenaAllocator = null,

/// Every terminal a statement has ever shown on a page of a project, in
/// this run. A tab its supervisor opened is ordered into the group's
/// project until it is seen there once; after that, somebody taking it out
/// again is their say and is not undone.
settled: std.AutoHashMapUnmanaged(Id, void) = .empty,

pub fn init(alloc: Allocator) Projects {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *Projects) void {
    if (self.arena) |*a| a.deinit();
    self.settled.deinit(self.alloc);
    self.* = undefined;
}

pub const ParseError = error{ BadRequest, OutOfMemory };

/// Read the `list` of a statement. What it returns borrows from `arena`.
///
/// Strict, because it replaces everything known: an entry that does not
/// read, two projects of one name, or one terminal on the pages of two
/// projects, and the whole statement is refused and the last one stands.
/// Half a statement would untie the groups whose projects were in the
/// other half.
pub fn parse(arena: Allocator, value: std.json.Value) ParseError![]const Stated {
    const items = switch (value) {
        .array => |a| a.items,
        else => return error.BadRequest,
    };
    const out = try arena.alloc(Stated, items.len);
    var seen: std.AutoHashMapUnmanaged(Id, void) = .empty;
    for (items, out, 0..) |item, *o, i| {
        const obj = switch (item) {
            .object => |v| v,
            else => return error.BadRequest,
        };
        const name = switch (obj.get("name") orelse return error.BadRequest) {
            .string => |s| s,
            else => return error.BadRequest,
        };
        if (name.len == 0) return error.BadRequest;
        for (out[0..i]) |before| {
            if (std.mem.eql(u8, before.name, name)) return error.BadRequest;
        }
        const group: ?[]const u8 = switch (obj.get("group") orelse return error.BadRequest) {
            .null => null,
            .string => |s| if (s.len > 0) s else return error.BadRequest,
            else => return error.BadRequest,
        };
        const pages: usize = switch (obj.get("pages") orelse return error.BadRequest) {
            .integer => |n| if (n >= 0) @intCast(n) else return error.BadRequest,
            else => return error.BadRequest,
        };
        const open: ?[]const []const Id = switch (obj.get("open") orelse return error.BadRequest) {
            .null => null,
            .array => |listed| open: {
                const made = try arena.alloc([]const Id, listed.items.len);
                for (listed.items, made) |page, *m| {
                    const ids = switch (page) {
                        .array => |p| p.items,
                        else => return error.BadRequest,
                    };
                    const row = try arena.alloc(Id, ids.len);
                    for (ids, row) |id, *r| {
                        r.* = try idOf(id);
                        const gop = try seen.getOrPut(arena, r.*);
                        if (gop.found_existing) return error.BadRequest;
                    }
                    m.* = row;
                }
                break :open made;
            },
            else => return error.BadRequest,
        };
        const supervisor: ?Id = switch (obj.get("supervisor") orelse return error.BadRequest) {
            .null => null,
            else => |v| try idOf(v),
        };
        const workers: []const Id = switch (obj.get("workers") orelse return error.BadRequest) {
            .array => |listed| workers: {
                const made = try arena.alloc(Id, listed.items.len);
                for (listed.items, made) |id, *m| m.* = try idOf(id);
                break :workers made;
            },
            else => return error.BadRequest,
        };
        o.* = .{ .name = name, .group = group, .pages = pages, .open = open, .supervisor = supervisor, .workers = workers };
        // Like the supervisor's pane: a pane of this project, or the
        // statement contradicts itself.
        for (workers) |w| if (!o.holds(w)) return error.BadRequest;
        // The supervisor's pane is a pane of the project: one that is on
        // none of its pages is a statement that contradicts itself.
        if (supervisor) |s| if (!o.holds(s)) return error.BadRequest;
    }
    return out;
}

fn idOf(v: std.json.Value) error{BadRequest}!Id {
    const s = switch (v) {
        .string => |s| s,
        else => return error.BadRequest,
    };
    if (s.len != 18 or !std.mem.startsWith(u8, s, "0x")) return error.BadRequest;
    return std.fmt.parseInt(u64, s[2..], 16) catch error.BadRequest;
}

/// Take a statement as everything the host knows. Copies it.
pub fn state(self: *Projects, list: []const Stated) Allocator.Error!void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const kept = try aa.alloc(Stated, list.len);
    for (list, kept) |p, *k| {
        k.* = .{
            .name = try aa.dupe(u8, p.name),
            .group = if (p.group) |g| try aa.dupe(u8, g) else null,
            .pages = p.pages,
            .open = if (p.open) |pages| open: {
                const made = try aa.alloc([]const Id, pages.len);
                for (pages, made) |page, *m| m.* = try aa.dupe(Id, page);
                break :open made;
            } else null,
            .supervisor = p.supervisor,
            .workers = try aa.dupe(Id, p.workers),
        };
        if (p.open) |pages| for (pages) |page| {
            for (page) |id| try self.settled.put(self.alloc, id, {});
        };
    }

    if (self.arena) |*old| old.deinit();
    self.arena = arena;
    self.stated = kept;
}

/// The project by that name in the last statement; null when there is
/// none, and when nothing has been stated.
pub fn find(self: *const Projects, name: []const u8) ?Stated {
    const list = self.stated orelse return null;
    for (list) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// The open project that has `terminal` on one of its pages.
pub fn projectOf(self: *const Projects, terminal: Id) ?Stated {
    const list = self.stated orelse return null;
    for (list) |p| {
        if (p.holds(terminal)) return p;
    }
    return null;
}

/// A terminal that has been seen on a page of a project in this run is no
/// longer waited for; a closed terminal is no longer anything.
pub fn forget(self: *Projects, terminal: Id) void {
    _ = self.settled.remove(terminal);
}

// -- what is worked out -------------------------------------------------------

/// A group, as far as the tie is concerned.
pub const GroupView = struct {
    name: []const u8,
    tie: Tie,
    /// Its supervisor by the control room's rule; null when it has none.
    steward: ?Id,
    /// How many of its open members are supervisors.
    supervisors: usize,
    /// The supervisor that took it up in this run, if one did
    /// (`Chat.ProjectClaim`).
    claim: ?Chat.ProjectClaim,
    /// A supervisor is being started for it and is waiting for its project
    /// to be opened.
    awaiting_open: bool,
};

/// A terminal an agent opened, and the terminal that agent is in.
pub const Opened = struct { terminal: Id, by: Id };

/// Where a group stands with a project, in one word.
pub const Why = enum {
    /// It has one, and nothing is in the way.
    none,
    /// The host has not said what projects there are.
    projects_unknown,
    /// It has none and no supervisor has taken it up in this run: an old
    /// group nobody has used yet. It is started by picking a directory.
    not_taken_up,
    /// Its supervisor said it has no project (`group_project`, `drop`).
    declined,
    /// It is being given one: the host has an order for it.
    pending,
    /// The supervisor that took it up is no longer its supervisor.
    no_supervisor,
    /// It has more than one supervisor in it, and which one's tab would be
    /// the project is not the core's to pick.
    other_supervisor,
    /// The supervisor that took it up is the supervisor of several groups
    /// with no project, and its one tab cannot be all of theirs.
    supervisor_of_several,
    /// The supervisor that took it up is already the supervisor of a group
    /// that has a project.
    supervisor_has_project,
    /// The tab that supervisor is in belongs to a project that is another
    /// group's.
    project_has_group,
    /// There is already a project by this group's name, and it is not the
    /// one that supervisor's tab is in. A group's project bears its name.
    project_name_taken,
    /// More than one project file says it is this group's.
    several_projects,
};

/// What the host is asked to do.
pub const Order = struct {
    order: Kind,
    /// The project it is about, by the name the host has it under.
    project: []const u8,
    /// `open`, `create`, `bind`: the group it is for. `set_group`: the
    /// group the file is to name, null to name none. Null otherwise.
    group: ?[]const u8,
    /// `bind`, `rename`: the name the project is to have afterwards.
    to: ?[]const u8,
    /// `create`, `bind`: the terminal whose tab is the project's page, and
    /// whose pane is the supervisor's. `add_tab`: the terminal whose tab
    /// is to become a page. Null otherwise.
    terminal: ?Id,

    pub const Kind = enum {
        /// Open the project (switch to it if it is open) and state it: the
        /// core types the launch line into the supervisor's pane itself.
        open,
        /// Make a project of this name, of one page: the tab `terminal` is
        /// in. Name `group` in it and mark that pane the supervisor's.
        create,
        /// Tie an existing project that has no group: name `group` in it,
        /// mark `terminal`'s pane the supervisor's, and rename it `to`.
        bind,
        /// Write the group the file names: a mirror that fell behind.
        set_group,
        /// Rename the project file (and what goes with it) to `to`.
        rename,
        /// Put the tab `terminal` is in into the project, as a page.
        add_tab,
    };
};

/// What the core does to its own half.
pub const Commit = struct {
    group: []const u8,
    /// The project it is now tied to, by the host's name for it; null when
    /// the tie is dropped because the project is gone.
    project: ?[]const u8,
};

pub const Standing = struct {
    group: []const u8,
    why: Why,
};

pub const Outcome = struct {
    /// In the order of the groups handed in, one each.
    standings: []const Standing,
    orders: []const Order,
    commits: []const Commit,
};

/// Where every group stands, what the host is to do, and what the core is
/// to write down. Everything returned borrows from `arena`, the groups
/// handed in and the last statement.
///
/// **Nothing here is carried out.** A commit is the app's to apply to
/// `Chat` and the group's record; this is then asked again and says what
/// is left.
///
/// How the two halves are put right when they disagree:
///
///   * the group says a project the host does not have -> the tie is
///     dropped (the file is gone; the group is started by directory again);
///   * the group says project P and P's file names another group or none
///     -> the file is put right (`set_group`);
///   * another file also names this group -> that one is cleared;
///   * a file names a group that is not there, or one that declined -> it
///     is cleared;
///   * **a file names a group that has no tie, and it is the only one that
///     does -> the group takes it.** The one case where the mirror wins: a
///     build from before the tie rewrites `group.json` whole and drops the
///     key, and the project file is then the only record left;
///   * the tied project's name is not the group's -> `rename`, unless that
///     name is another project's.
pub fn reconcile(
    self: *const Projects,
    arena: Allocator,
    groups: []const GroupView,
    opened: []const Opened,
) Allocator.Error!Outcome {
    var orders: std.ArrayListUnmanaged(Order) = .empty;
    const standings = try arena.alloc(Standing, groups.len);

    const list = self.stated orelse {
        // Not known. The one thing still asked for is a project a start is
        // waiting on: whoever reads the order can open it, and will then
        // have something to state.
        for (groups, standings) |g, *s| {
            s.* = .{ .group = g.name, .why = switch (g.tie) {
                .bound => .none,
                .declined => .declined,
                .undecided => .projects_unknown,
            } };
            if (g.tie == .bound and g.awaiting_open) try orders.append(arena, .{
                .order = .open,
                .project = g.tie.bound,
                .group = g.name,
                .to = null,
                .terminal = null,
            });
        }
        return .{ .standings = standings, .orders = orders.items, .commits = &.{} };
    };

    var commits: std.ArrayListUnmanaged(Commit) = .empty;
    for (groups, standings) |g, *s| {
        s.* = .{ .group = g.name, .why = try self.standingOf(arena, list, groups, g, opened, &orders, &commits) };
    }

    // A file that names a group that is not there -- unless it is some
    // group's own project, which has just been told what to name.
    for (list) |p| {
        const named = p.group orelse continue;
        for (groups) |g| {
            if (std.mem.eql(u8, g.name, named)) break;
            if (g.tie == .bound and std.mem.eql(u8, g.tie.bound, p.name)) break;
        } else try orders.append(arena, .{
            .order = .set_group,
            .project = p.name,
            .group = null,
            .to = null,
            .terminal = null,
        });
    }

    return .{ .standings = standings, .orders = orders.items, .commits = commits.items };
}

fn standingOf(
    self: *const Projects,
    arena: Allocator,
    list: []const Stated,
    groups: []const GroupView,
    g: GroupView,
    opened: []const Opened,
    orders: *std.ArrayListUnmanaged(Order),
    commits: *std.ArrayListUnmanaged(Commit),
) Allocator.Error!Why {
    const clear: Order = .{ .order = .set_group, .project = "", .group = null, .to = null, .terminal = null };

    switch (g.tie) {
        .bound => |name| {
            const p = self.find(name) orelse {
                // Gone. The group goes back to being started by directory,
                // and is not offered a project again until it is taken up
                // again: the person who deleted one did not ask for another.
                try commits.append(arena, .{ .group = g.name, .project = null });
                return .not_taken_up;
            };
            if (p.group == null or !std.mem.eql(u8, p.group.?, g.name)) try orders.append(arena, .{
                .order = .set_group,
                .project = p.name,
                .group = g.name,
                .to = null,
                .terminal = null,
            });
            for (list) |q| {
                if (std.mem.eql(u8, q.name, p.name)) continue;
                if (q.group == null or !std.mem.eql(u8, q.group.?, g.name)) continue;
                var o = clear;
                o.project = q.name;
                try orders.append(arena, o);
            }
            if (g.awaiting_open) try orders.append(arena, .{
                .order = .open,
                .project = p.name,
                .group = g.name,
                .to = null,
                .terminal = null,
            });
            // What its supervisor opened and no project has yet.
            if (g.steward) |boss| for (opened) |o| {
                if (o.by != boss) continue;
                if (self.settled.contains(o.terminal)) continue;
                if (self.projectOf(o.terminal) != null) continue;
                try orders.append(arena, .{
                    .order = .add_tab,
                    .project = p.name,
                    .group = null,
                    .to = null,
                    .terminal = o.terminal,
                });
            };
            // A group's project bears its name.
            if (!std.mem.eql(u8, p.name, g.name)) {
                if (self.find(g.name) != null) return .project_name_taken;
                try orders.append(arena, .{
                    .order = .rename,
                    .project = p.name,
                    .group = null,
                    .to = g.name,
                    .terminal = null,
                });
            }
            return .none;
        },
        .declined => {
            for (list) |q| {
                if (q.group == null or !std.mem.eql(u8, q.group.?, g.name)) continue;
                var o = clear;
                o.project = q.name;
                try orders.append(arena, o);
            }
            return .declined;
        },
        .undecided => {},
    }

    // No tie. A file that says it is this group's is taken at its word
    // when it is the only one.
    var claimant: ?Stated = null;
    var claimants: usize = 0;
    for (list) |q| {
        if (q.group == null or !std.mem.eql(u8, q.group.?, g.name)) continue;
        claimants += 1;
        claimant = q;
    }
    if (claimants > 1) return .several_projects;
    if (claimant) |q| {
        try commits.append(arena, .{ .group = g.name, .project = q.name });
        return .pending;
    }

    const claim = g.claim orelse return .not_taken_up;
    return self.offer(arena, groups, g, claim, orders);
}

/// What taking a group up comes to: an order for the host, or the reason
/// there is none. `orders` may be null to ask without ordering anything
/// (`judge`).
fn offer(
    self: *const Projects,
    arena: Allocator,
    groups: []const GroupView,
    g: GroupView,
    claim: Chat.ProjectClaim,
    orders: ?*std.ArrayListUnmanaged(Order),
) Allocator.Error!Why {
    const boss = claim.terminal;
    if (g.steward == null or g.steward.? != boss) return .no_supervisor;

    // Said outright, the supervisor has answered the two questions below
    // itself. Left to the core, either is a reason to leave it alone.
    if (!claim.said) {
        if (g.supervisors > 1) return .other_supervisor;
        var untied: usize = 0;
        for (groups) |other| {
            if (other.steward == null or other.steward.? != boss) continue;
            switch (other.tie) {
                .bound => return .supervisor_has_project,
                .undecided => untied += 1,
                .declined => {},
            }
        }
        if (untied > 1) return .supervisor_of_several;
    }

    if (self.projectOf(boss)) |p| {
        // Its tab is a page of a project already. (One that named this
        // group would have been taken at its word before this was asked.)
        if (p.group != null) return .project_has_group;
        if (!std.mem.eql(u8, p.name, g.name) and self.find(g.name) != null) return .project_name_taken;
        if (orders) |o| try o.append(arena, .{
            .order = .bind,
            .project = p.name,
            .group = g.name,
            .to = g.name,
            .terminal = boss,
        });
        return .pending;
    }

    if (self.find(g.name) != null) return .project_name_taken;
    if (orders) |o| try o.append(arena, .{
        .order = .create,
        .project = g.name,
        .group = g.name,
        .to = null,
        .terminal = boss,
    });
    return .pending;
}

/// What a supervisor saying "this group uses the project I am in" would
/// come to, before it is taken as said: `pending` when the host would be
/// given an order, `none` when the group already has that very project,
/// and otherwise the reason nothing would happen. Orders nothing.
pub fn judge(
    self: *const Projects,
    arena: Allocator,
    groups: []const GroupView,
    group: []const u8,
    terminal: Id,
) Allocator.Error!Why {
    if (self.stated == null) return .projects_unknown;
    for (groups) |g| {
        if (!std.mem.eql(u8, g.name, group)) continue;
        switch (g.tie) {
            // It has one. The same one is nothing to do; another is a
            // second project for one group.
            .bound => |name| {
                const p = self.projectOf(terminal) orelse return .project_has_group;
                return if (std.mem.eql(u8, p.name, name)) .none else .project_has_group;
            },
            .declined, .undecided => {},
        }
        return self.offer(arena, groups, g, .{ .terminal = terminal, .said = true }, null);
    }
    return .no_supervisor;
}

/// The group tied to the project the host has under `name`; null when no
/// group is.
pub fn groupOf(groups: []const GroupView, name: []const u8) ?[]const u8 {
    for (groups) |g| {
        if (g.tie == .bound and std.mem.eql(u8, g.tie.bound, name)) return g.name;
    }
    return null;
}

/// What `group_project` answers a supervisor that asked for a tie it
/// cannot have.
pub const ToolRefusal = error{
    /// The interface has not told Polter what projects there are.
    ProjectsUnknown,
    /// The caller is not that group's supervisor.
    NotItsSupervisor,
    /// The group has a project already, or the project the caller is in
    /// is another group's. One group, one project.
    ProjectHasGroup,
    /// A project by the group's name exists, and it is not the caller's.
    ProjectNameTaken,
};

/// Whether what `judge` came to is a refusal. Null for the two that are
/// not: an order is on its way (`pending`), or there is nothing to do
/// (`none`).
pub fn refusalOf(why: Why) ?ToolRefusal {
    return switch (why) {
        .none, .pending => null,
        .projects_unknown => error.ProjectsUnknown,
        .project_has_group, .several_projects, .supervisor_has_project => error.ProjectHasGroup,
        .project_name_taken => error.ProjectNameTaken,
        // What only applies to a tie the core works out by itself reads,
        // to somebody asking outright, as not being the one to ask.
        .no_supervisor,
        .not_taken_up,
        .declined,
        .other_supervisor,
        .supervisor_of_several,
        => error.NotItsSupervisor,
    };
}

pub const RemoveRefusal = error{ ProjectsUnknown, NotInAProject, SupervisorPage };

/// Whether the page `terminal` is on may be taken out of its project.
///
/// **The page a group's supervisor is on stays in that group's project.**
/// A project with its supervisor's page taken out is one that opens with
/// nobody to start, which is the broken thing a group having exactly one
/// project is there to rule out. Any other page may go, and so may the
/// supervisor's page of a project that is not its group's.
pub fn mayRemove(self: *const Projects, groups: []const GroupView, terminal: Id) RemoveRefusal!void {
    if (self.stated == null) return error.ProjectsUnknown;
    const p = self.projectOf(terminal) orelse return error.NotInAProject;
    const page = for (p.open.?) |ids| {
        if (std.mem.indexOfScalar(Id, ids, terminal) != null) break ids;
    } else unreachable;
    for (groups) |g| {
        if (g.tie != .bound or !std.mem.eql(u8, g.tie.bound, p.name)) continue;
        const boss = g.steward orelse continue;
        if (std.mem.indexOfScalar(Id, page, boss) != null) return error.SupervisorPage;
    }
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn stateJson(p: *Projects, json: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    try p.state(try parse(arena.allocator(), v));
}

fn view(name: []const u8, tie: Tie, steward: ?Id, claim: ?Chat.ProjectClaim) GroupView {
    return .{
        .name = name,
        .tie = tie,
        .steward = steward,
        .supervisors = if (steward == null) 0 else 1,
        .claim = claim,
        .awaiting_open = false,
    };
}

fn took(terminal: Id) Chat.ProjectClaim {
    return .{ .terminal = terminal, .said = false };
}

fn expectOrder(want: Order, got: Order) !void {
    try testing.expectEqual(want.order, got.order);
    try testing.expectEqualStrings(want.project, got.project);
    try testing.expectEqualStrings(want.group orelse "<null>", got.group orelse "<null>");
    try testing.expectEqualStrings(want.to orelse "<null>", got.to orelse "<null>");
    try testing.expectEqual(want.terminal, got.terminal);
}

test "Projects: a statement is read whole or not at all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const read = struct {
        fn f(a: Allocator, json: []const u8) ParseError![]const Stated {
            const v = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch return error.BadRequest;
            return parse(a, v);
        }
    }.f;

    const list = try read(aa,
        \\[{"name":"web-app","group":"web-app","pages":2,
        \\  "open":[["0x00000000000000a1","0x00000000000000b1"],["0x00000000000000b2"]],
        \\  "supervisor":"0x00000000000000a1","workers":[]},
        \\ {"name":"notes","group":null,"pages":1,"open":null,"supervisor":null,"workers":[]}]
    );
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("web-app", list[0].group.?);
    try testing.expectEqual(@as(usize, 2), list[0].open.?.len);
    try testing.expectEqual(@as(Id, 0xb1), list[0].open.?[0][1]);
    try testing.expectEqual(@as(?Id, 0xa1), list[0].supervisor);
    try testing.expectEqual(@as(?[]const u8, null), list[1].group);
    try testing.expect(list[1].open == null);
    try testing.expectEqual(@as(usize, 0), (try read(aa, "[]")).len);

    // Every key is said, each time: one left out is not "none".
    const bad = [_][]const u8{
        "{}",
        "[7]",
        \\[{"group":null,"pages":1,"open":null,"supervisor":null,"workers":[]}]
        ,
        \\[{"name":"","group":null,"pages":1,"open":null,"supervisor":null,"workers":[]}]
        ,
        \\[{"name":"a","pages":1,"open":null,"supervisor":null,"workers":[]}]
        ,
        \\[{"name":"a","group":"","pages":1,"open":null,"supervisor":null,"workers":[]}]
        ,
        \\[{"name":"a","group":null,"open":null,"supervisor":null,"workers":[]}]
        ,
        \\[{"name":"a","group":null,"pages":-1,"open":null,"supervisor":null,"workers":[]}]
        ,
        \\[{"name":"a","group":null,"pages":1,"supervisor":null,"workers":[]}]
        ,
        \\[{"name":"a","group":null,"pages":1,"open":null}]
        ,
        \\[{"name":"a","group":null,"pages":1,"open":[["161"]],"supervisor":null,"workers":[]}]
        ,
        // Two projects of one name; one terminal on the pages of two.
        \\[{"name":"a","group":null,"pages":1,"open":null,"supervisor":null,"workers":[]},
        \\ {"name":"a","group":null,"pages":1,"open":null,"supervisor":null,"workers":[]}]
        ,
        \\[{"name":"a","group":null,"pages":1,"open":[["0x00000000000000a1"]],"supervisor":null,"workers":[]},
        \\ {"name":"b","group":null,"pages":1,"open":[["0x00000000000000a1"]],"supervisor":null,"workers":[]}]
        ,
        // A supervisor's pane that is on none of its pages, open or not.
        \\[{"name":"a","group":null,"pages":1,"open":[["0x00000000000000a1"]],"supervisor":"0x00000000000000a2","workers":[]}]
        ,
        \\[{"name":"a","group":null,"pages":1,"open":null,"supervisor":"0x00000000000000a2","workers":[]}]
        ,
    };
    for (bad) |b| try testing.expectError(error.BadRequest, read(aa, b));
}

test "Projects: before the host has said anything, nothing is known and nothing is done" {
    var p: Projects = .init(testing.allocator);
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var waiting = view("tied", .{ .bound = "tied" }, null, null);
    waiting.awaiting_open = true;
    const groups = [_]GroupView{
        view("old", .undecided, 0xa1, took(0xa1)),
        view("said-no", .declined, null, null),
        waiting,
    };
    const out = try p.reconcile(arena.allocator(), &groups, &.{});
    try testing.expectEqual(Why.projects_unknown, out.standings[0].why);
    try testing.expectEqual(Why.declined, out.standings[1].why);
    try testing.expectEqual(Why.none, out.standings[2].why);
    // Not untied for a project nobody has had the chance to state.
    try testing.expectEqual(@as(usize, 0), out.commits.len);
    // The one order: a start is waiting for that project to be opened.
    try testing.expectEqual(@as(usize, 1), out.orders.len);
    try expectOrder(.{ .order = .open, .project = "tied", .group = "tied", .to = null, .terminal = null }, out.orders[0]);

    try testing.expectEqual(Why.projects_unknown, try p.judge(arena.allocator(), &groups, "old", 0xa1));

    // Stated, with nothing in it: known, and there are none.
    try stateJson(&p, "[]");
    const known = try p.reconcile(arena.allocator(), &groups, &.{});
    try testing.expectEqual(Why.pending, known.standings[0].why);
}

test "Projects: an old group taken up by its one supervisor gets a project of its own name, or the one its tab is in" {
    var p: Projects = .init(testing.allocator);
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Nobody has taken it up: nothing is offered, whoever is in it.
    try stateJson(&p, "[]");
    var out = try p.reconcile(aa, &.{view("old", .undecided, 0xa1, null)}, &.{});
    try testing.expectEqual(Why.not_taken_up, out.standings[0].why);
    try testing.expectEqual(@as(usize, 0), out.orders.len);

    // Taken up, its tab in no project: one is made, by the group's name.
    out = try p.reconcile(aa, &.{view("old", .undecided, 0xa1, took(0xa1))}, &.{});
    try testing.expectEqual(Why.pending, out.standings[0].why);
    try testing.expectEqual(@as(usize, 1), out.orders.len);
    try expectOrder(.{ .order = .create, .project = "old", .group = "old", .to = null, .terminal = 0xa1 }, out.orders[0]);
    // Nothing is written down until the host has made it.
    try testing.expectEqual(@as(usize, 0), out.commits.len);

    // Its tab is a page of a project with no group: that one is tied, and
    // takes the group's name.
    try stateJson(&p,
        \\[{"name":"scratch","group":null,"pages":1,"open":[["0x00000000000000a1"]],"supervisor":null,"workers":[]}]
    );
    out = try p.reconcile(aa, &.{view("old", .undecided, 0xa1, took(0xa1))}, &.{});
    try testing.expectEqual(Why.pending, out.standings[0].why);
    try expectOrder(.{ .order = .bind, .project = "scratch", .group = "old", .to = "old", .terminal = 0xa1 }, out.orders[0]);

    // The host did it and said so: the file names the group, and the group
    // takes it -- under whatever name the host has it by now.
    try stateJson(&p,
        \\[{"name":"scratch","group":"old","pages":1,"open":[["0x00000000000000a1"]],"supervisor":"0x00000000000000a1","workers":[]}]
    );
    out = try p.reconcile(aa, &.{view("old", .undecided, 0xa1, took(0xa1))}, &.{});
    try testing.expectEqual(@as(usize, 1), out.commits.len);
    try testing.expectEqualStrings("old", out.commits[0].group);
    try testing.expectEqualStrings("scratch", out.commits[0].project.?);

    // Tied, and not yet renamed: that is the one thing left to do.
    out = try p.reconcile(aa, &.{view("old", .{ .bound = "scratch" }, 0xa1, null)}, &.{});
    try testing.expectEqual(Why.none, out.standings[0].why);
    try testing.expectEqual(@as(usize, 1), out.orders.len);
    try expectOrder(.{ .order = .rename, .project = "scratch", .group = null, .to = "old", .terminal = null }, out.orders[0]);
    try testing.expectEqual(@as(usize, 0), out.commits.len);

    // Renamed: the two halves agree and there is nothing to do.
    try stateJson(&p,
        \\[{"name":"old","group":"old","pages":1,"open":[["0x00000000000000a1"]],"supervisor":"0x00000000000000a1","workers":[]}]
    );
    out = try p.reconcile(aa, &.{view("old", .{ .bound = "old" }, 0xa1, null)}, &.{});
    try testing.expectEqual(Why.none, out.standings[0].why);
    try testing.expectEqual(@as(usize, 0), out.orders.len);
    try testing.expectEqual(@as(usize, 0), out.commits.len);
}

test "Projects: where there is more than one way to read it, nothing is done and the reason is said" {
    var p: Projects = .init(testing.allocator);
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try stateJson(&p,
        \\[{"name":"theirs","group":"theirs","pages":1,"open":[["0x00000000000000c1"]],"supervisor":"0x00000000000000c1","workers":[]},
        \\ {"name":"taken","group":null,"pages":1,"open":null,"supervisor":null,"workers":[]},
        \\ {"name":"twice","group":"dup","pages":1,"open":null,"supervisor":null,"workers":[]},
        \\ {"name":"twice-b","group":"dup","pages":1,"open":null,"supervisor":null,"workers":[]}]
    );

    var two_bosses = view("two-bosses", .undecided, 0xa1, took(0xa1));
    two_bosses.supervisors = 2;
    const groups = [_]GroupView{
        // The supervisor that took it up has gone, or was never its.
        view("left", .undecided, null, took(0xa9)),
        view("not-its", .undecided, 0xa8, took(0xa9)),
        two_bosses,
        // One supervisor, two groups with no project: its tab cannot be both.
        view("one-of-two", .undecided, 0xa2, took(0xa2)),
        view("two-of-two", .undecided, 0xa2, took(0xa2)),
        // Already the supervisor of a group that has a project.
        view("theirs", .{ .bound = "theirs" }, 0xc1, null),
        view("second", .undecided, 0xc1, took(0xc1)),
        // A project by the group's name is there, and it is not this tab's.
        view("taken", .undecided, 0xa3, took(0xa3)),
        // Two files say they are its.
        view("dup", .undecided, 0xa4, took(0xa4)),
    };
    const out = try p.reconcile(aa, &groups, &.{});
    const want = [_]Why{
        .no_supervisor,
        .no_supervisor,
        .other_supervisor,
        .supervisor_of_several,
        .supervisor_of_several,
        .none,
        .supervisor_has_project,
        .project_name_taken,
        .several_projects,
    };
    for (want, out.standings) |w, s| {
        testing.expectEqual(w, s.why) catch |err| {
            std.debug.print("group {s}\n", .{s.group});
            return err;
        };
    }
    // And nothing at all is ordered or written down for any of them.
    try testing.expectEqual(@as(usize, 0), out.orders.len);
    try testing.expectEqual(@as(usize, 0), out.commits.len);

    // Its tab is a page of a project that is another group's.
    const in_theirs = [_]GroupView{
        view("theirs", .{ .bound = "theirs" }, 0xc2, null),
        view("mine", .undecided, 0xc1, took(0xc1)),
    };
    const held = try p.reconcile(aa, &in_theirs, &.{});
    try testing.expectEqual(Why.project_has_group, held.standings[1].why);
    // (The two files naming `dup`, which is not a group here, are told to
    // name nobody; nothing is made or tied.)
    for (held.orders) |o| try testing.expectEqual(Order.Kind.set_group, o.order);
}

test "Projects: the supervisor saying so settles what the core would not pick, and nothing else" {
    var p: Projects = .init(testing.allocator);
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try stateJson(&p,
        \\[{"name":"theirs","group":"theirs","pages":1,"open":[["0x00000000000000c1"]],"supervisor":"0x00000000000000c1","workers":[]},
        \\ {"name":"taken","group":null,"pages":1,"open":null,"supervisor":null,"workers":[]}]
    );
    var two_bosses = view("two-bosses", .undecided, 0xa1, null);
    two_bosses.supervisors = 2;
    const groups = [_]GroupView{
        two_bosses,
        view("one-of-two", .undecided, 0xa2, null),
        view("two-of-two", .undecided, 0xa2, null),
        view("theirs", .{ .bound = "theirs" }, 0xc1, null),
        view("second", .undecided, 0xc1, null),
        view("taken", .undecided, 0xa3, null),
        view("said-no", .declined, 0xa5, null),
    };
    // Which supervisor, and which of its groups: its to say.
    try testing.expectEqual(Why.pending, try p.judge(aa, &groups, "two-bosses", 0xa1));
    try testing.expectEqual(Why.pending, try p.judge(aa, &groups, "one-of-two", 0xa2));
    // Having said no before is not a reason against saying yes now.
    try testing.expectEqual(Why.pending, try p.judge(aa, &groups, "said-no", 0xa5));
    // The same project it already has: nothing to do, and not a refusal.
    try testing.expectEqual(Why.none, try p.judge(aa, &groups, "theirs", 0xc1));

    // One to one is not its to waive: a project that has a group, a group
    // that has a project, a name that is another project's.
    try testing.expectEqual(Why.project_has_group, try p.judge(aa, &groups, "second", 0xc1));
    try testing.expectEqual(Why.project_has_group, try p.judge(aa, &groups, "theirs", 0xa1));
    try testing.expectEqual(Why.project_name_taken, try p.judge(aa, &groups, "taken", 0xa3));
    // Nor is being the group's supervisor.
    try testing.expectEqual(Why.no_supervisor, try p.judge(aa, &groups, "two-bosses", 0xa9));
    try testing.expectEqual(Why.no_supervisor, try p.judge(aa, &groups, "not-a-group", 0xa1));

    // Said, it is carried out by the same road: the claim, then the order.
    var said = two_bosses;
    said.claim = .{ .terminal = 0xa1, .said = true };
    const out = try p.reconcile(aa, &.{said}, &.{});
    try testing.expectEqual(Why.pending, out.standings[0].why);
    try expectOrder(.{ .order = .create, .project = "two-bosses", .group = "two-bosses", .to = null, .terminal = 0xa1 }, out.orders[0]);
}

test "Projects: the two halves disagreeing is put right, and the group's record is the one that counts" {
    var p: Projects = .init(testing.allocator);
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try stateJson(&p,
        \\[{"name":"web-app","group":null,"pages":3,"open":null,"supervisor":null,"workers":[]},
        \\ {"name":"copy-of-web-app","group":"web-app","pages":3,"open":null,"supervisor":null,"workers":[]},
        \\ {"name":"orphan","group":"long-gone","pages":1,"open":null,"supervisor":null,"workers":[]},
        \\ {"name":"refused","group":"said-no","pages":1,"open":null,"supervisor":null,"workers":[]},
        \\ {"name":"kept","group":"lost-its-key","pages":2,"open":null,"supervisor":null,"workers":[]}]
    );
    const groups = [_]GroupView{
        // Its file stopped naming it, and a copy of the file names it too.
        view("web-app", .{ .bound = "web-app" }, null, null),
        // Its project file is gone.
        view("deleted", .{ .bound = "deleted" }, 0xa1, took(0xa1)),
        view("said-no", .declined, null, null),
        // No tie on record, and exactly one file that says it is its.
        view("lost-its-key", .undecided, null, null),
    };
    const out = try p.reconcile(aa, &groups, &.{});

    try testing.expectEqual(Why.none, out.standings[0].why);
    // Gone: untied, and **not** offered another on the spot, though its
    // supervisor is right there.
    try testing.expectEqual(Why.not_taken_up, out.standings[1].why);
    try testing.expectEqual(Why.declined, out.standings[2].why);
    try testing.expectEqual(Why.pending, out.standings[3].why);

    try testing.expectEqual(@as(usize, 2), out.commits.len);
    try testing.expectEqualStrings("deleted", out.commits[0].group);
    try testing.expectEqual(@as(?[]const u8, null), out.commits[0].project);
    try testing.expectEqualStrings("lost-its-key", out.commits[1].group);
    try testing.expectEqualStrings("kept", out.commits[1].project.?);

    try testing.expectEqual(@as(usize, 4), out.orders.len);
    try expectOrder(.{ .order = .set_group, .project = "web-app", .group = "web-app", .to = null, .terminal = null }, out.orders[0]);
    try expectOrder(.{ .order = .set_group, .project = "copy-of-web-app", .group = null, .to = null, .terminal = null }, out.orders[1]);
    try expectOrder(.{ .order = .set_group, .project = "refused", .group = null, .to = null, .terminal = null }, out.orders[2]);
    try expectOrder(.{ .order = .set_group, .project = "orphan", .group = null, .to = null, .terminal = null }, out.orders[3]);
}

test "Projects: a group renamed has its project renamed after it, unless the name is another's" {
    var p: Projects = .init(testing.allocator);
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // The group was `web-app` and is `storefront` now; its tie still names
    // the project as the host has it.
    try stateJson(&p,
        \\[{"name":"web-app","group":"web-app","pages":2,"open":null,"supervisor":null,"workers":[]}]
    );
    var out = try p.reconcile(aa, &.{view("storefront", .{ .bound = "web-app" }, null, null)}, &.{});
    try testing.expectEqual(Why.none, out.standings[0].why);
    try testing.expectEqual(@as(usize, 2), out.orders.len);
    try expectOrder(.{ .order = .set_group, .project = "web-app", .group = "storefront", .to = null, .terminal = null }, out.orders[0]);
    try expectOrder(.{ .order = .rename, .project = "web-app", .group = null, .to = "storefront", .terminal = null }, out.orders[1]);

    // There is a `storefront` already: still tied, not renamed, and said.
    try stateJson(&p,
        \\[{"name":"web-app","group":"storefront","pages":2,"open":null,"supervisor":null,"workers":[]},
        \\ {"name":"storefront","group":null,"pages":1,"open":null,"supervisor":null,"workers":[]}]
    );
    out = try p.reconcile(aa, &.{view("storefront", .{ .bound = "web-app" }, null, null)}, &.{});
    try testing.expectEqual(Why.project_name_taken, out.standings[0].why);
    try testing.expectEqual(@as(usize, 0), out.orders.len);
    try testing.expectEqual(@as(usize, 0), out.commits.len);
}

test "Projects: a tab the supervisor opened goes into its group's project once, and a start waits for the project to be opened" {
    var p: Projects = .init(testing.allocator);
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try stateJson(&p,
        \\[{"name":"web-app","group":"web-app","pages":1,"open":[["0x00000000000000a1"]],"supervisor":"0x00000000000000a1","workers":[]},
        \\ {"name":"other","group":null,"pages":1,"open":[["0x00000000000000d1"]],"supervisor":null,"workers":[]}]
    );
    const groups = [_]GroupView{view("web-app", .{ .bound = "web-app" }, 0xa1, null)};
    const opened = [_]Opened{
        .{ .terminal = 0xb1, .by = 0xa1 },
        // Somebody else's supervisor opened this one.
        .{ .terminal = 0xb2, .by = 0xa9 },
        // Its own, and already a page of another project.
        .{ .terminal = 0xd1, .by = 0xa1 },
    };
    var out = try p.reconcile(aa, &groups, &opened);
    try testing.expectEqual(@as(usize, 1), out.orders.len);
    try expectOrder(.{ .order = .add_tab, .project = "web-app", .group = null, .to = null, .terminal = 0xb1 }, out.orders[0]);

    // The host put it in and said so: nothing more is asked.
    try stateJson(&p,
        \\[{"name":"web-app","group":"web-app","pages":2,"open":[["0x00000000000000a1"],["0x00000000000000b1"]],"supervisor":"0x00000000000000a1","workers":[]}]
    );
    out = try p.reconcile(aa, &groups, &opened[0..1].*);
    try testing.expectEqual(@as(usize, 0), out.orders.len);

    // Somebody took it out again: that is their say, and it is not put back.
    try stateJson(&p,
        \\[{"name":"web-app","group":"web-app","pages":1,"open":[["0x00000000000000a1"]],"supervisor":"0x00000000000000a1","workers":[]}]
    );
    out = try p.reconcile(aa, &groups, &opened[0..1].*);
    try testing.expectEqual(@as(usize, 0), out.orders.len);
    // A terminal that closed is nothing any more; the same id again is new.
    p.forget(0xb1);
    out = try p.reconcile(aa, &groups, &opened[0..1].*);
    try testing.expectEqual(@as(usize, 1), out.orders.len);

    // A start waiting on it: the one order, for as long as it waits.
    var waiting = groups[0];
    waiting.steward = null;
    waiting.awaiting_open = true;
    out = try p.reconcile(aa, &.{waiting}, &.{});
    try testing.expectEqual(@as(usize, 1), out.orders.len);
    try expectOrder(.{ .order = .open, .project = "web-app", .group = "web-app", .to = null, .terminal = null }, out.orders[0]);
}

test "Projects: the page a group's supervisor is on cannot be taken out of that group's project" {
    var p: Projects = .init(testing.allocator);
    defer p.deinit();

    const groups = [_]GroupView{
        view("web-app", .{ .bound = "web-app" }, 0xa1, null),
        view("loose", .undecided, 0xa7, null),
    };
    // Before anything is stated there is nothing to answer from.
    try testing.expectError(error.ProjectsUnknown, p.mayRemove(&groups, 0xa1));

    try stateJson(&p,
        \\[{"name":"web-app","group":"web-app","pages":2,
        \\  "open":[["0x00000000000000a1","0x00000000000000b1"],["0x00000000000000b2"]],
        \\  "supervisor":"0x00000000000000a1","workers":[]},
        \\ {"name":"scratch","group":null,"pages":1,"open":[["0x00000000000000a7"]],"supervisor":null,"workers":[]}]
    );
    // The supervisor's own pane, and the pane beside it on the same page.
    try testing.expectError(error.SupervisorPage, p.mayRemove(&groups, 0xa1));
    try testing.expectError(error.SupervisorPage, p.mayRemove(&groups, 0xb1));
    // Another page of the same project.
    try p.mayRemove(&groups, 0xb2);
    // A supervisor's page of a project that is not its group's.
    try p.mayRemove(&groups, 0xa7);
    try testing.expectError(error.NotInAProject, p.mayRemove(&groups, 0xee));

    try testing.expectEqualStrings("web-app", groupOf(&groups, "web-app").?);
    try testing.expectEqual(@as(?[]const u8, null), groupOf(&groups, "scratch"));
}

test "Projects: which answers refuse a supervisor that asked, and with what" {
    // The two that are not refusals.
    try testing.expectEqual(@as(?ToolRefusal, null), refusalOf(.pending));
    try testing.expectEqual(@as(?ToolRefusal, null), refusalOf(.none));

    try testing.expectEqual(@as(?ToolRefusal, error.ProjectsUnknown), refusalOf(.projects_unknown));
    try testing.expectEqual(@as(?ToolRefusal, error.ProjectHasGroup), refusalOf(.project_has_group));
    try testing.expectEqual(@as(?ToolRefusal, error.ProjectNameTaken), refusalOf(.project_name_taken));
    try testing.expectEqual(@as(?ToolRefusal, error.NotItsSupervisor), refusalOf(.no_supervisor));
    // Every other word is some refusal: nothing a tie cannot be made for
    // is answered as though it had been.
    for (std.enums.values(Why)) |why| {
        if (why == .pending or why == .none) continue;
        try testing.expect(refusalOf(why) != null);
    }
}

test "Projects: the panes a project's supervisor opened are said with it, each one a pane of that project" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const read = struct {
        fn f(a: Allocator, json: []const u8) ParseError![]const Stated {
            const v = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch return error.BadRequest;
            return parse(a, v);
        }
    }.f;

    const list = try read(aa,
        \\[{"name":"web-app","group":"web-app","pages":2,
        \\  "open":[["0x00000000000000a1","0x00000000000000b1"],["0x00000000000000b2"]],
        \\  "supervisor":"0x00000000000000a1","workers":["0x00000000000000b1","0x00000000000000b2"]}]
    );
    try testing.expectEqualSlices(Id, &.{ 0xb1, 0xb2 }, list[0].workers);

    // Kept as said, in the order said.
    var p: Projects = .init(testing.allocator);
    defer p.deinit();
    try p.state(list);
    try testing.expectEqualSlices(Id, &.{ 0xb1, 0xb2 }, p.find("web-app").?.workers);

    for ([_][]const u8{
        // Left out is not "none": the key is said, empty when there are none.
        \\[{"name":"a","group":null,"pages":1,"open":null,"supervisor":null}]
        ,
        \\[{"name":"a","group":null,"pages":1,"open":null,"supervisor":null,"workers":null}]
        ,
        \\[{"name":"a","group":null,"pages":1,"open":null,"supervisor":null,"workers":["161"]}]
        ,
        // A pane that is on none of this project's pages, open or not.
        \\[{"name":"a","group":null,"pages":1,"open":[["0x00000000000000a1"]],"supervisor":null,"workers":["0x00000000000000b9"]}]
        ,
        \\[{"name":"a","group":null,"pages":1,"open":null,"supervisor":null,"workers":["0x00000000000000b9"]}]
        ,
    }) |bad| try testing.expectError(error.BadRequest, read(aa, bad));
}
