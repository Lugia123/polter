//! Tidying tabs and panes by moving them (task 1571).
//!
//! **A move, never a close and a reopen.** The user, 2026-10-15: closing a
//! terminal to open it again somewhere tidier cuts the session in it --
//! the process, the scrollback, the agent's conversation. Everything here
//! is about saying *which* terminals a call moves, so the rules can be
//! asked of every one of them before anything moves, and the caller can be
//! told afterwards where each one went.
//!
//! Pure functions over the layout text and over two readings of where
//! terminals were, so that the parts a refusal depends on can be tested
//! without an apprt. What actually moves is the apprt's: it owns the tree.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Id = u64;

/// Where a `terminal_layout` puts its shape when it is not a tab that is
/// already there.
pub const Into = union(enum) {
    /// The tab `id` names.
    none,
    /// A new tab in the window of this terminal, to the right of its tab.
    new_tab_beside: Id,
    /// A new window.
    new_window,

    /// The terminal this names, when it names one.
    pub fn terminal(self: Into) ?Id {
        return switch (self) {
            .new_tab_beside => |id| id,
            .none, .new_window => null,
        };
    }
};

/// How deep a layout may nest. A split nests one object per level, so this
/// is a hundred splits inside each other -- far past anything a screen
/// holds, and a cap is what lets the walk below need no allocation.
pub const max_depth = 128;

/// The terminal ids a layout's `pane` cells name, in the order written.
///
/// **Read token by token, without building the tree**, because the place
/// that has to ask is `rpc.authorize`, which has no allocator -- and asking
/// there is the point: a shield that only the target id was checked against
/// let any shielded pane of the same tab be rearranged (the hole task 1571
/// closed). The caller hands in a buffer for the scanner's own bookkeeping;
/// an escaped key such as `"\u0070ane"` is decoded into it, so a key
/// spelled oddly is still the key the apprt will read.
pub const PaneIter = struct {
    alloc: Allocator,
    scanner: std.json.Scanner,
    frames: [max_depth]Frame = undefined,
    depth: usize = 0,
    /// The last key read was `pane`, so the value after it is a terminal.
    pane_next: bool = false,

    const Frame = struct { object: bool, key_next: bool };

    pub const Error = error{BadLayout};

    pub fn init(alloc: Allocator, layout: []const u8) PaneIter {
        return .{ .alloc = alloc, .scanner = .initCompleteInput(alloc, layout) };
    }

    pub fn deinit(self: *PaneIter) void {
        self.scanner.deinit();
    }

    /// The next id, or null at the end.
    pub fn next(self: *PaneIter) Error!?Id {
        while (true) {
            const tok = self.scanner.nextAlloc(self.alloc, .alloc_if_needed) catch
                return error.BadLayout;
            switch (tok) {
                .end_of_document => return null,
                .object_begin, .array_begin => {
                    self.valueSeen();
                    if (self.depth == max_depth) return error.BadLayout;
                    self.frames[self.depth] = .{ .object = tok == .object_begin, .key_next = true };
                    self.depth += 1;
                },
                .object_end, .array_end => {
                    if (self.depth == 0) return error.BadLayout;
                    self.depth -= 1;
                },
                .string => |s| if (try self.text(s)) |id| return id,
                .allocated_string => |s| if (try self.text(s)) |id| return id,
                .number, .allocated_number, .true, .false, .null => self.valueSeen(),
                .partial_number,
                .partial_string,
                .partial_string_escaped_1,
                .partial_string_escaped_2,
                .partial_string_escaped_3,
                .partial_string_escaped_4,
                => return error.BadLayout,
            }
        }
    }

    /// A string: a key, which is remembered, or a value, which is an id
    /// when the key before it was `pane`.
    fn text(self: *PaneIter, s: []const u8) Error!?Id {
        if (self.keyNext()) {
            self.frames[self.depth - 1].key_next = false;
            self.pane_next = std.mem.eql(u8, s, "pane");
            return null;
        }
        const was_pane = self.pane_next;
        self.valueSeen();
        if (!was_pane) return null;
        // The same reading `App.rewriteLayoutValue` gives it, so the id
        // checked here is the id that is moved.
        return std.fmt.parseUnsigned(Id, s, 0) catch error.BadLayout;
    }

    fn keyNext(self: *const PaneIter) bool {
        if (self.depth == 0) return false;
        const f = self.frames[self.depth - 1];
        return f.object and f.key_next;
    }

    /// A value was read: the container it is in expects a key next.
    fn valueSeen(self: *PaneIter) void {
        self.pane_next = false;
        if (self.depth > 0) self.frames[self.depth - 1].key_next = true;
    }
};

/// A buffer big enough for `PaneIter`'s bookkeeping on any layout under
/// `max_depth`: the scanner's nesting stack is a bit per level, and the
/// rest is room for a key or an id that had to be unescaped.
pub const scan_buffer_len = 4096;

/// Whether a layout holds a `stack` cell anywhere. Asked where stacks are
/// not built (Windows), so that a shape with one is refused before anything
/// moves rather than half applied.
pub fn hasStack(alloc: Allocator, layout: []const u8) error{BadLayout}!bool {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, layout, .{}) catch
        return error.BadLayout;
    defer parsed.deinit();
    return valueHasStack(parsed.value);
}

fn valueHasStack(v: std.json.Value) bool {
    switch (v) {
        .object => |o| {
            if (o.contains("stack")) return true;
            for (o.values()) |child| if (valueHasStack(child)) return true;
        },
        .array => |a| for (a.items) |child| if (valueHasStack(child)) return true,
        else => {},
    }
    return false;
}

/// Where one terminal is, as the apprt answered for it. Null fields are
/// "nobody said", never "nowhere".
pub const Where = struct {
    window: ?u64 = null,
    tab: ?u64 = null,
    tab_index: ?u32 = null,

    fn sameTab(a: Where, b: Where) bool {
        return a.tab != null and a.tab == b.tab and a.window == b.window;
    }
};

/// A terminal that a call moved to another tab or window.
pub const Move = struct {
    id: Id,
    from: Where,
    to: Where,
};

/// The terminals whose tab changed between two readings, in the order
/// `ids` gives them. `before[i]` and `after[i]` are where `ids[i]` was.
///
/// **Two readings, one before and one after**, rather than a guess from
/// the shape: the apprt is the side that moved things, and asking it again
/// is the one answer that cannot disagree with what is on screen. A
/// terminal for which either reading is missing is left out rather than
/// reported as moved from or to nowhere.
pub fn moves(
    alloc: Allocator,
    ids: []const Id,
    before: []const Where,
    after: []const Where,
) Allocator.Error![]Move {
    std.debug.assert(ids.len == before.len and ids.len == after.len);
    var out: std.ArrayList(Move) = .empty;
    errdefer out.deinit(alloc);
    for (ids, before, after) |id, b, a| {
        if (b.tab == null or a.tab == null) continue;
        if (Where.sameTab(b, a)) continue;
        try out.append(alloc, .{ .id = id, .from = b, .to = a });
    }
    return out.toOwnedSlice(alloc);
}

/// The apprt's reply with `"moved"` added: every terminal that changed tab,
/// with where it was and where it is. Ids are written `0x…`, as every other
/// id in the reply is. A reply that is not an object is handed back as it
/// was -- it is the apprt's text, and losing it would be worse.
pub fn withMoves(alloc: Allocator, reply: []const u8, list: []const Move) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, reply, .{}) catch
        return alloc.dupe(u8, reply);
    defer parsed.deinit();
    if (parsed.value != .object) return alloc.dupe(u8, reply);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var arr: std.json.Array = .init(aa);
    for (list) |m| {
        var o: std.json.ObjectMap = .empty;
        // As `terminal_list` writes it, all sixteen digits (task 1600).
        try o.put(aa, "id", .{ .string = try std.fmt.allocPrint(aa, "0x{x:0>16}", .{m.id}) });
        try o.put(aa, "from", try whereValue(aa, m.from));
        try o.put(aa, "to", try whereValue(aa, m.to));
        try arr.append(.{ .object = o });
    }
    try parsed.value.object.put(parsed.arena.allocator(), "moved", .{ .array = arr });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    errdefer buf.deinit();
    std.json.Stringify.value(parsed.value, .{}, &buf.writer) catch return error.OutOfMemory;
    return buf.toOwnedSlice();
}

fn whereValue(aa: Allocator, w: Where) !std.json.Value {
    var o: std.json.ObjectMap = .empty;
    // The window and tab keys go out as the numbers `terminal_list` gives,
    // so a caller can compare them with what it read there. Written as the
    // digits themselves: a key is a u64, and the parser's integer is not.
    try o.put(aa, "window", if (w.window) |v| .{ .number_string = try std.fmt.allocPrint(aa, "{d}", .{v}) } else .null);
    try o.put(aa, "tab", if (w.tab) |v| .{ .number_string = try std.fmt.allocPrint(aa, "{d}", .{v}) } else .null);
    try o.put(aa, "tab_index", if (w.tab_index) |v| .{ .integer = v } else .null);
    return .{ .object = o };
}

const testing = std.testing;

fn collect(layout: []const u8, out: []Id) !usize {
    var buf: [scan_buffer_len]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    var it: PaneIter = .init(fba.allocator(), layout);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |id| : (n += 1) out[n] = id;
    return n;
}

test "tidying: every pane cell is named, at any depth and inside a stack" {
    var ids: [8]Id = undefined;
    const n = try collect(
        \\{"split":"h","ratio":0.5,"left":{"pane":"0x1a"},
        \\ "right":{"split":"v","left":{"stack":[{"pane":"0x2b"},{"new":{"cwd":"/tmp"}},{"pane":"12"}],"shown":1},
        \\  "right":{"new":null}}}
    , &ids);
    try testing.expectEqualSlices(Id, &.{ 0x1a, 0x2b, 12 }, ids[0..n]);
}

test "tidying: a key that is spelled with an escape is still the key" {
    // The apprt reads the layout with a JSON parser, which decodes this to
    // `pane`; a walk that compared the raw bytes would miss the terminal and
    // let a shielded one through.
    var ids: [4]Id = undefined;
    const n = try collect("{\"\\u0070ane\":\"0x7\"}", &ids);
    try testing.expectEqualSlices(Id, &.{0x7}, ids[0..n]);
}

test "tidying: a value that is the word pane is not a key" {
    var ids: [4]Id = undefined;
    const n = try collect("{\"split\":\"pane\",\"left\":{\"new\":{\"cwd\":\"pane\"}},\"right\":{\"pane\":\"0x3\"}}", &ids);
    try testing.expectEqualSlices(Id, &.{0x3}, ids[0..n]);
}

test "tidying: a pane that is not a number refuses the whole layout" {
    var ids: [4]Id = undefined;
    try testing.expectError(error.BadLayout, collect("{\"pane\":\"me\"}", &ids));
}

test "tidying: stacks are found wherever they are" {
    try testing.expect(try hasStack(testing.allocator, "{\"split\":\"h\",\"left\":{\"pane\":\"1\"},\"right\":{\"stack\":[{\"pane\":\"2\"},{\"new\":null}]}}"));
    try testing.expect(!try hasStack(testing.allocator, "{\"split\":\"h\",\"left\":{\"pane\":\"1\"},\"right\":{\"new\":null}}"));
}

test "tidying: only a terminal whose tab changed is reported as moved" {
    const ids = [_]Id{ 1, 2, 3 };
    const before = [_]Where{
        .{ .window = 10, .tab = 100, .tab_index = 0 },
        .{ .window = 10, .tab = 101, .tab_index = 1 },
        .{ .window = 10, .tab = 100, .tab_index = 0 },
    };
    const after = [_]Where{
        .{ .window = 10, .tab = 100, .tab_index = 0 },
        .{ .window = 10, .tab = 100, .tab_index = 0 },
        .{ .window = 11, .tab = 200, .tab_index = 0 },
    };
    const got = try moves(testing.allocator, &ids, &before, &after);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(@as(Id, 2), got[0].id);
    try testing.expectEqual(@as(?u64, 101), got[0].from.tab);
    try testing.expectEqual(@as(Id, 3), got[1].id);
    try testing.expectEqual(@as(?u64, 11), got[1].to.window);
}

test "tidying: a terminal nobody could place is not reported as moved" {
    const got = try moves(testing.allocator, &.{1}, &.{.{}}, &.{.{ .window = 1, .tab = 2 }});
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "tidying: the reply carries the moves beside the layout" {
    const list = [_]Move{.{
        .id = 0x2a,
        .from = .{ .window = 1, .tab = 2, .tab_index = 3 },
        .to = .{ .window = 1, .tab = 4, .tab_index = 0 },
    }};
    const out = try withMoves(testing.allocator, "{\"layout\":{\"pane\":\"0x2a\"}}", &list);
    defer testing.allocator.free(out);
    // The moved terminal's id as terminal_list writes it, sixteen digits
    // (task 1600); the layout's own cells are the reply's, rewritten
    // elsewhere.
    try testing.expectEqualStrings(
        "{\"layout\":{\"pane\":\"0x2a\"},\"moved\":[{\"id\":\"0x000000000000002a\",\"from\":{\"window\":1,\"tab\":2,\"tab_index\":3},\"to\":{\"window\":1,\"tab\":4,\"tab_index\":0}}]}",
        out,
    );
}
