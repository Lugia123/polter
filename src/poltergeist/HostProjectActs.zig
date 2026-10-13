//! What a host says to the core about projects, as a host writes it.
//!
//! `testdata/host_project_acts.txt` holds one request to a line. They are
//! **not written by this file**: the macOS host's test
//! (`macos/Tests/Projects/ProjectLinkTests.swift`) builds each with the
//! code the app sends with and holds its bytes against the same lines. So a
//! line here is what a host sends, and this is the core reading it -- the
//! two halves of the contract in `dev-docs/poltergeist/projects.md`
//! checked against one file neither made up for itself.
const std = @import("std");
const ControlAct = @import("ControlAct.zig");

const lines = @embedFile("testdata/host_project_acts.txt");

test "HostProjectActs: every request a host writes about projects is one the core reads, as what the host meant" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, lines, "\n"), '\n');

    // Everything, two projects: one open with a supervisor, one closed.
    {
        const act = try ControlAct.parse(aa, it.next().?);
        const list = act.projects;
        try testing.expectEqual(@as(usize, 2), list.len);
        try testing.expectEqualStrings("web-app", list[0].name);
        try testing.expectEqualStrings("web-app", list[0].group.?);
        try testing.expectEqual(@as(usize, 3), list[0].pages);
        try testing.expectEqual(@as(usize, 2), list[0].open.?.len);
        try testing.expectEqual(@as(usize, 2), list[0].open.?[0].len);
        try testing.expectEqual(@as(u64, 0xa1), list[0].open.?[0][0]);
        try testing.expectEqual(@as(u64, 0xb1), list[0].open.?[0][1]);
        try testing.expectEqual(@as(u64, 0xb2), list[0].open.?[1][0]);
        try testing.expectEqual(@as(?u64, 0xa1), list[0].supervisor);
        try testing.expectEqualStrings("notes \"2\" 写", list[1].name);
        try testing.expect(list[1].group == null);
        try testing.expectEqual(@as(usize, 1), list[1].pages);
        try testing.expect(list[1].open == null);
        try testing.expect(list[1].supervisor == null);
    }
    // No project at all is still a statement.
    try testing.expectEqual(@as(usize, 0), (try ControlAct.parse(aa, it.next().?)).projects.len);
    {
        const act = try ControlAct.parse(aa, it.next().?);
        try testing.expectEqualStrings("web-app", act.project_failed.name);
        try testing.expectEqual(ControlAct.ProjectFailure.not_found, act.project_failed.why);
    }
    try testing.expectEqual(ControlAct.ProjectFailure.unreadable, (try ControlAct.parse(aa, it.next().?)).project_failed.why);
    try testing.expectEqual(@as(u64, 0xb2), (try ControlAct.parse(aa, it.next().?)).project_remove);
    {
        const act = try ControlAct.parse(aa, it.next().?);
        try testing.expectEqualStrings("web-app", act.project_rename.from);
        try testing.expectEqualStrings("storefront", act.project_rename.to);
    }
    // Nothing in the file this did not read.
    try testing.expect(it.next() == null);
}
