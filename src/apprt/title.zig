//! The title an apprt keeps for a surface on the core's behalf: what
//! `terminal_list`, the chat's member names and the task panel's owners read
//! (through `getTitle`), as opposed to whatever the window shows.
//!
//! **A name somebody chose outranks the one the program reports.** A
//! `set_title` with `explicit` set -- `set_surface_title`, a caller naming a
//! terminal on purpose -- pins the stored title; from then on a title the
//! program reports (OSC 0/2, and a shell with shell integration sends one at
//! every prompt) is remembered but does not replace it. Both hosts already
//! did this for what they *show* (macOS `setExplicitTitle`, Windows
//! `title_override`); the stored title did not, so a worker named "worker A"
//! read as "worker A" on its tab and as whatever its shell or agent last
//! said everywhere Polter reports it (issue #9, measured: one prompt was
//! enough).
//!
//! **Nothing changes for a surface nobody has named.** Until an explicit
//! title arrives, every reported title is stored exactly as before.
//!
//! **And the pin can be taken back**: an explicit *empty* title unpins,
//! and the stored title returns to the program's latest one. That is the
//! meaning an empty name already has on macOS when a person renames a tab,
//! and `set_surface_title:` (nothing after the colon) is how a caller says it.
const Title = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

/// What `getTitle` answers: the pinned name while there is one, otherwise
/// the program's latest title. Null until anything has been set.
current: ?[:0]const u8 = null,

/// The program's latest title, kept while pinned so unpinning can return
/// to it rather than to nothing.
reported: ?[:0]const u8 = null,

/// Whether `current` is a name somebody chose.
pinned: bool = false,

pub fn deinit(self: *Title, alloc: Allocator) void {
    if (self.current) |v| alloc.free(v);
    if (self.reported) |v| alloc.free(v);
    self.* = .{};
}

/// Take a `set_title`. `explicit` is `apprt.action.SetTitle.explicit`.
pub fn set(self: *Title, alloc: Allocator, title: []const u8, explicit: bool) Allocator.Error!void {
    if (!explicit) {
        try replace(alloc, &self.reported, title);
        if (!self.pinned) try replace(alloc, &self.current, title);
        return;
    }

    if (title.len == 0) {
        // Unpin: back to following the program.
        self.pinned = false;
        if (self.reported) |r| {
            try replace(alloc, &self.current, r);
        } else if (self.current) |v| {
            alloc.free(v);
            self.current = null;
        }
        return;
    }

    try replace(alloc, &self.current, title);
    self.pinned = true;
}

fn replace(alloc: Allocator, slot: *?[:0]const u8, value: []const u8) Allocator.Error!void {
    const copy = try alloc.dupeZ(u8, value);
    if (slot.*) |old| alloc.free(old);
    slot.* = copy;
}

const testing = std.testing;

fn expectCurrent(t: Title, want: ?[]const u8) !void {
    if (want) |w| {
        try testing.expectEqualStrings(w, t.current orelse return error.TestExpectedEqual);
    } else {
        try testing.expect(t.current == null);
    }
}

test "a surface nobody has named follows every title the program reports" {
    // The half of the change that must be no change at all.
    var t: Title = .{};
    defer t.deinit(testing.allocator);

    try t.set(testing.allocator, "zsh", false);
    try expectCurrent(t, "zsh");
    try t.set(testing.allocator, "Qwen - demo", false);
    try expectCurrent(t, "Qwen - demo");
    try t.set(testing.allocator, "~/work", false);
    try expectCurrent(t, "~/work");
}

test "a name somebody chose outlasts the next title the program reports" {
    // Issue #9: `set_surface_title:NAME-A`, then one prompt, used to leave
    // the program's title in `terminal_list`.
    var t: Title = .{};
    defer t.deinit(testing.allocator);

    try t.set(testing.allocator, "~/work", false);
    try t.set(testing.allocator, "NAME-A", true);
    try expectCurrent(t, "NAME-A");
    try t.set(testing.allocator, "PROG-X", false);
    try expectCurrent(t, "NAME-A");
    try t.set(testing.allocator, "~/work", false);
    try expectCurrent(t, "NAME-A");

    // A second chosen name replaces the first.
    try t.set(testing.allocator, "NAME-B", true);
    try expectCurrent(t, "NAME-B");
}

test "an empty chosen name gives the title back to the program" {
    var t: Title = .{};
    defer t.deinit(testing.allocator);

    // The whole round trip on one line: name it, the program speaks and
    // does not win, unpin, the program speaks and does. Without the last
    // step `set_surface_title:` could do nothing at all and look right.
    try t.set(testing.allocator, "~/work", false);
    try t.set(testing.allocator, "NAME-A", true);
    try t.set(testing.allocator, "PROG-X", false);
    try expectCurrent(t, "NAME-A");

    // Unpinning returns to what the program said last while pinned, not to
    // what it said before the name was set.
    try t.set(testing.allocator, "", true);
    try expectCurrent(t, "PROG-X");

    // And from here it follows the program again.
    try t.set(testing.allocator, "~/elsewhere", false);
    try expectCurrent(t, "~/elsewhere");
}

test "unpinning before the program has said anything leaves no title" {
    var t: Title = .{};
    defer t.deinit(testing.allocator);

    try t.set(testing.allocator, "NAME-A", true);
    try t.set(testing.allocator, "", true);
    try expectCurrent(t, null);
}
