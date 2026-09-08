const builtin = @import("builtin");
const std = @import("std");
const inputpkg = @import("../input.zig");
const global = @import("../global.zig");
const String = @import("../main_c.zig").String;

const Config = @import("Config.zig");
const c_get = @import("c_get.zig");
const edit = @import("edit.zig");
const Key = @import("key.zig").Key;

const log = std.log.scoped(.config);

/// Create a new configuration filled with the initial default values.
export fn ghostty_config_new() ?*Config {
    const result = global.alloc().create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = Config.default(global.alloc()) catch |err| {
        log.err("error creating config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

export fn ghostty_config_free(ptr: ?*Config) void {
    if (ptr) |v| {
        v.deinit();
        global.alloc().destroy(v);
    }
}

/// Deep clone the configuration.
export fn ghostty_config_clone(self: *Config) ?*Config {
    const result = global.alloc().create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = self.clone(global.alloc()) catch |err| {
        log.err("error cloning config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

/// Load the configuration from the CLI args.
export fn ghostty_config_load_cli_args(self: *Config) void {
    self.loadCliArgs(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from the default file locations. This
/// is usually done first. The default file locations are locations
/// such as the home directory.
export fn ghostty_config_load_default_files(self: *Config) void {
    self.loadDefaultFiles(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from a specific file path.
/// The path must be null-terminated.
export fn ghostty_config_load_file(self: *Config, path: [*:0]const u8) void {
    const path_slice = std.mem.span(path);
    self.loadFile(global.alloc(), path_slice) catch |err| {
        log.err("error loading config from file path={s} err={}", .{ path_slice, err });
    };
}

/// Load the configuration from the user-specified configuration
/// file locations in the previously loaded configuration. This will
/// recursively continue to load up to a built-in limit.
export fn ghostty_config_load_recursive_files(self: *Config) void {
    self.loadRecursiveFiles(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

export fn ghostty_config_finalize(self: *Config) void {
    self.finalize() catch |err| {
        log.err("error finalizing config err={}", .{err});
    };
}

export fn ghostty_config_get(
    self: *Config,
    ptr: *anyopaque,
    key_str: [*]const u8,
    len: usize,
) bool {
    @setEvalBranchQuota(10_000);
    const key = std.meta.stringToEnum(Key, key_str[0..len]) orelse return false;
    return c_get.get(self, key, ptr);
}

export fn ghostty_config_trigger(
    self: *Config,
    str: [*]const u8,
    len: usize,
) inputpkg.Binding.Trigger.C {
    return config_trigger_(self, str[0..len]) catch |err| err: {
        log.err("error finding trigger err={}", .{err});
        break :err .{};
    };
}

fn config_trigger_(
    self: *Config,
    str: []const u8,
) !inputpkg.Binding.Trigger.C {
    const action = try inputpkg.Binding.Action.parse(str);
    const trigger: inputpkg.Binding.Trigger = self.keybind.set.getTrigger(action) orelse .{};
    return trigger.cval();
}

/// One row of the keybind listing: either a binding, or an action that has
/// no binding at all.
///
/// **Why this exists next to `ghostty_config_trigger` rather than replacing
/// it.** That one answers "what key runs this action?" out of
/// `Binding.Set.reverse`, and the reverse map deliberately omits
/// `performable` bindings so that GUI toolkits do not register them as menu
/// accelerators. That omission is correct for menus and wrong for a listing:
/// a page built on it shows the same blanks the menu shows. This reads the
/// forward table instead. **`ghostty_config_trigger` is not changed.**
pub const Keybind = extern struct {
    /// The action's stable tag, e.g. `goto_tab`. **Static storage, never
    /// null, and never freed by the caller** -- it is the pointer to a
    /// comptime `@tagName`. That is what makes this whole API allocation
    /// free and why there is no matching `_free`.
    action: [*]const u8,
    action_len: usize,

    /// True when this row is a real binding. **False means "this action
    /// exists and has no key today"**, which is the only way an action like
    /// `toggle_secure_input` can appear in a listing at all.
    bound: bool,

    /// Meaningful only when `bound`. Deliberately a struct rather than a
    /// string: macOS renders this as `⌘3` and Windows as `Ctrl+3`, so the
    /// formatting belongs to the host.
    trigger: inputpkg.Binding.Trigger.C,

    /// Bits of `ghostty_binding_flags_e`. `PERFORMABLE` is the one that
    /// matters to a listing: it is why the binding is absent from the
    /// reverse map and therefore from the menu.
    flags: inputpkg.Binding.Flags.C,

    /// True when the binding is reached through a leader-key sequence, in
    /// which case `trigger` is only its **first** step.
    ///
    /// ⚠️ **Zero real data stands behind this field today.** The default
    /// configuration contains no sequenced bindings -- measured, not
    /// assumed -- so nothing in the tree exercises it. Treat it as declared
    /// rather than verified.
    sequence: bool,
};

/// Walks the keybind listing in a fixed order, either counting the rows or
/// picking one out.
///
/// The order is: every binding in `Set.bindings` in insertion order (an
/// `ArrayHashMap`, so this is stable), then every action that never appeared,
/// in declaration order. Both halves are deterministic, which is what lets a
/// caller pair an index with a row across two calls.
const KeybindWalk = struct {
    want: ?u32,
    at: u32 = 0,
    found: ?Keybind = null,

    const Tag = std.meta.Tag(inputpkg.Binding.Action);

    fn emit(self: *KeybindWalk, row: Keybind) void {
        if (self.want) |w| {
            if (w == self.at) self.found = row;
        }
        self.at += 1;
    }

    fn action(
        self: *KeybindWalk,
        seen: *std.EnumSet(Tag),
        a: inputpkg.Binding.Action,
        trigger: inputpkg.Binding.Trigger,
        flags: inputpkg.Binding.Flags,
        sequence: bool,
    ) void {
        seen.insert(a);
        const name = @tagName(a);
        self.emit(.{
            .action = name.ptr,
            .action_len = name.len,
            .bound = true,
            .trigger = trigger.cval(),
            .flags = flags.cval(),
            .sequence = sequence,
        });
    }

    fn set(
        self: *KeybindWalk,
        seen: *std.EnumSet(Tag),
        s: *const inputpkg.Binding.Set,
        leader: ?inputpkg.Binding.Trigger,
    ) void {
        var it = s.bindings.iterator();
        while (it.next()) |entry| {
            // A sequenced binding reports its *first* step, which is the
            // leader we descended through.
            const trigger = leader orelse entry.key_ptr.*;
            switch (entry.value_ptr.*) {
                .leaf => |leaf| self.action(
                    seen,
                    leaf.action,
                    trigger,
                    leaf.flags,
                    leader != null,
                ),

                // One trigger, several actions. Each gets its own row rather
                // than being collapsed: a listing that showed only the first
                // would be lying about what the key does.
                .leaf_chained => |chained| for (chained.actions.items) |a| self.action(
                    seen,
                    a,
                    trigger,
                    chained.flags,
                    leader != null,
                ),

                .leader => |sub| self.set(seen, sub, trigger),
            }
        }
    }
};

fn keybindWalk(self: *Config, want: ?u32) KeybindWalk {
    var walk: KeybindWalk = .{ .want = want };
    var seen: std.EnumSet(KeybindWalk.Tag) = .initEmpty();

    // ⚠️ **The root set only.** `Keybinds.tables` holds named key tables and
    // `cli/list_keybinds.zig` does walk them, so that command and this API
    // will report different row counts for a configuration that uses them.
    // Whether any exist in practice is **not measured**, which is not the
    // same as "there are none".
    walk.set(&seen, &self.keybind.set, null);

    inline for (@typeInfo(inputpkg.Binding.Action).@"union".fields, 0..) |field, i| {
        const tag: KeybindWalk.Tag = @enumFromInt(i);
        if (!seen.contains(tag)) walk.emit(.{
            .action = field.name.ptr,
            .action_len = field.name.len,
            .bound = false,
            .trigger = .{},
            .flags = 0,
            .sequence = false,
        });
    }

    return walk;
}

/// The number of rows in the keybind listing.
export fn ghostty_config_keybind_count(self: *Config) u32 {
    return keybindWalk(self, null).at;
}

/// Row `idx` of the keybind listing, `0 <= idx < ghostty_config_keybind_count`.
///
/// An out-of-range index gives a row with `action_len == 0`, which is not a
/// value any real row can take.
export fn ghostty_config_keybind(self: *Config, idx: u32) Keybind {
    return keybindWalk(self, idx).found orelse .{
        .action = "".ptr,
        .action_len = 0,
        .bound = false,
        .trigger = .{},
        .flags = 0,
        .sequence = false,
    };
}

export fn ghostty_config_diagnostics_count(self: *Config) u32 {
    return @intCast(self._diagnostics.items().len);
}

export fn ghostty_config_get_diagnostic(self: *Config, idx: u32) Diagnostic {
    const items = self._diagnostics.items();
    if (idx >= items.len) return .{};
    const message = self._diagnostics.precompute.messages.items[idx];
    return .{ .message = message.ptr };
}

export fn ghostty_config_open_path() String {
    const path = edit.openPath(global.alloc()) catch |err| {
        log.err("error opening config in editor err={}", .{err});
        return .empty;
    };

    return .fromSlice(path);
}

/// Sync with ghostty_diagnostic_s
const Diagnostic = extern struct {
    message: [*:0]const u8 = "",
};

test "ghostty_config_get: bool" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.maximize = true;

    var out = false;
    const key = "maximize";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expect(out);
}

test "ghostty_config_get: enum" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"window-theme" = .dark;

    var out: [*:0]const u8 = undefined;
    const key = "window-theme";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    const str = std.mem.sliceTo(out, 0);
    try testing.expectEqualStrings("dark", str);
}

test "ghostty_config_get: optional null returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"unfocused-split-fill" = null;

    var out: Config.Color.C = undefined;
    const key = "unfocused-split-fill";
    try testing.expect(!ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
}

test "ghostty_config_get: unknown key returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var out = false;
    const key = "not-a-real-key";
    try testing.expect(!ghostty_config_get(&cfg, &out, key, key.len));
}

test "ghostty_config_get: optional string null returns true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.title = null;

    var out: ?[*:0]const u8 = undefined;
    const key = "title";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expect(out == null);
}

test "ghostty_config_get: float" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"background-opacity" = 0.42;

    var out: f64 = 0;
    const key = "background-opacity";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expectApproxEqAbs(@as(f64, 0.42), out, 0.000001);
}

test "ghostty_config_get: struct cval conversion" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.background = .{ .r = 12, .g = 34, .b = 56 };

    var out: Config.Color.C = undefined;
    const key = "background";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expectEqual(@as(u8, 12), out.r);
    try testing.expectEqual(@as(u8, 34), out.g);
    try testing.expectEqual(@as(u8, 56), out.b);
}

test "ghostty_config_trigger: default keybind" {
    const testing = std.testing;

    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    // Default commands should be fetchable through config_trigger_
    {
        const trigger = try config_trigger_(&cfg, "open_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    {
        const trigger = try config_trigger_(&cfg, "reload_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    // Performable bindings are not tracked in the reverse map,
    // so config_trigger_ should return a default (empty) trigger.
    if (comptime builtin.target.os.tag.isDarwin()) {
        const next = try config_trigger_(&cfg, "navigate_search:next");
        try testing.expectEqual(.physical, next.tag);
        try testing.expectEqual(.unidentified, next.key.physical);

        const prev = try config_trigger_(&cfg, "navigate_search:previous");
        try testing.expectEqual(.physical, prev.tag);
        try testing.expectEqual(.unidentified, prev.key.physical);
    }
    {
        const trigger = try config_trigger_(&cfg, "adjust_selection:left");
        try testing.expectEqual(.physical, trigger.tag);
        try testing.expectEqual(.unidentified, trigger.key.physical);
    }
}

test "keybind listing: every action appears exactly once as a row or a binding" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    const n = ghostty_config_keybind_count(&cfg);
    const Tag = std.meta.Tag(inputpkg.Binding.Action);
    var seen: std.EnumSet(Tag) = .initEmpty();

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const row = ghostty_config_keybind(&cfg, i);
        try testing.expect(row.action_len > 0);
        const name = row.action[0..row.action_len];
        const tag = std.meta.stringToEnum(Tag, name) orelse {
            std.debug.print("row {d} names something that is not an action: {s}\n", .{ i, name });
            return error.TestUnexpectedResult;
        };
        seen.insert(tag);
    }

    // **The row count of the page.** Every action the core knows about has
    // at least one row, which is what makes this a map of what exists rather
    // than a list of keys the reader already presses.
    try testing.expectEqual(
        @typeInfo(inputpkg.Binding.Action).@"union".fields.len,
        seen.count(),
    );
}

test "keybind listing: an action with no key at all still gets a row" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    // `toggle_secure_input` has no default binding on any platform, and on
    // Windows the core's automatic detection is not implemented either. A
    // listing that only walked bindings would leave the one protection a
    // user has to turn on by hand invisible.
    var found = false;
    const n = ghostty_config_keybind_count(&cfg);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const row = ghostty_config_keybind(&cfg, i);
        if (!std.mem.eql(u8, row.action[0..row.action_len], "toggle_secure_input")) continue;
        found = true;
        try testing.expect(!row.bound);
    }
    try testing.expect(found);
}

test "keybind listing: shows the bindings the reverse map hides" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    // **This is the whole reason the API exists.** An action bound only by
    // `performable` triggers is absent from `Set.reverse`, so
    // `ghostty_config_trigger` reports it as having no key -- and so does
    // every menu built on that. Each such action must still arrive here with
    // `bound = true`.
    const performable_bit = (inputpkg.Binding.Flags{ .performable = true }).cval();

    var checked: usize = 0;
    const n = ghostty_config_keybind_count(&cfg);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const row = ghostty_config_keybind(&cfg, i);
        if (!row.bound) continue;

        const name = row.action[0..row.action_len];
        const tag = std.meta.stringToEnum(
            std.meta.Tag(inputpkg.Binding.Action),
            name,
        ).?;

        // Ask the reverse map the way a menu does. Only actions it cannot
        // answer for are the subject here.
        const hidden = switch (tag) {
            inline else => |t| cfg.keybind.set.getTrigger(
                @unionInit(inputpkg.Binding.Action, @tagName(t), undefined),
            ) == null,
        };
        if (!hidden) continue;

        try testing.expect(row.flags & performable_bit != 0);
        checked += 1;
    }

    // **Not vacuous.** If the default configuration ever stops containing a
    // performable-only binding this goes red rather than passing on an empty
    // loop, because at that point the defect this API exists for could come
    // back unnoticed.
    try testing.expect(checked > 0);
}

test "keybind listing: an index past the end is not a row" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    const n = ghostty_config_keybind_count(&cfg);
    const row = ghostty_config_keybind(&cfg, n);
    try testing.expectEqual(@as(usize, 0), row.action_len);
    try testing.expect(!row.bound);
}
