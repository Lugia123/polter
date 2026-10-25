//! The agent launchers a person adds of their own (task 2156): a name, the
//! agent CLI underneath (`base`, a plugin's `agent_cli` key), the command
//! that starts it -- a wrapper of theirs that keeps its own token and in
//! the end execs the real CLI with the arguments it was given -- and any
//! plain environment variables and arguments to add.
//!
//! **Only the custom ones are here.** The preset ones are the plugins'
//! `agent_cli` sections and are listed from those; the window and the
//! tools put the two in one table.
//!
//! **Nothing here looks at a token.** The person's command keeps it; a
//! token written straight into `env` or `args` is the person's choice and
//! is kept as written. What is shown anywhere but the settings form --
//! the log, the group, a tool's answer -- is a variable's name, never its
//! value (`writeSafe`).
//!
//! **Which roles may use a launcher is kept with the launcher** (`roles`),
//! not with the role: a launcher deleted takes its switches with it, a new
//! one is off for every role, and an official role -- whose own fields are
//! Polter's -- is switched on here without an override of its own.
//!
//! How one starts: the base CLI's adapter is asked for its launch as for
//! the base CLI itself, wearing the role's choices for it, and then
//! `rewrite` puts this launcher's command where the CLI's own program was,
//! adds its arguments at the end and its variables to the environment. So
//! nothing in the core or in any plugin changes for a new launcher.

const Launchers = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_key_len = 64;
pub const max_bytes = 256 * 1024;

pub const Env = struct {
    name: []const u8,
    value: []const u8,
};

pub const Launcher = struct {
    key: []const u8,
    name: []const u8,
    /// The agent CLI underneath: a plugin's `agent_cli` key.
    base: []const u8,
    /// An absolute path, `~/` already expanded (`expandHome`).
    command: []const u8,
    env: []const Env = &.{},
    args: []const []const u8 = &.{},
    /// Roles this launcher is switched on for, by key.
    roles: []const []const u8 = &.{},

    pub fn enabledFor(self: Launcher, role: []const u8) bool {
        for (self.roles) |r| if (std.mem.eql(u8, r, role)) return true;
        return false;
    }
};

pub const Error = error{
    BadKey,
    BadName,
    /// The base is not an agent CLI this machine has a plugin for.
    UnknownBase,
    /// Not an absolute path. A launch from the Dock has almost no `PATH`.
    CommandNotAbsolute,
    BadEnvName,
    /// The key is a preset's: a custom launcher may not hide one.
    KeyTaken,
    NoSuchLauncher,
    OutOfMemory,
};

pub fn isValidKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key_len) return false;
    for (key) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

fn isValidEnvName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| switch (c) {
        'A'...'Z', 'a'...'z', '_' => {},
        '0'...'9' => if (i == 0) return false,
        else => return false,
    };
    return true;
}

/// Whether `path` is absolute on either system: `/…`, `C:\…`, `C:/…` or
/// `\\server\…`. Checked as text, so a Windows path is judged right on a
/// Mac that holds the settings and the reverse.
pub fn isAbsolute(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return true;
    if (path.len >= 2 and path[0] == '\\' and path[1] == '\\') return true;
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) return true;
    return false;
}

/// `~/…` as the home directory's, for a person who wrote it so in the
/// form; anything else as it is. In `aa`.
pub fn expandHome(aa: Allocator, path: []const u8, home: ?[]const u8) Allocator.Error![]const u8 {
    if (std.mem.eql(u8, path, "~")) return if (home) |h| aa.dupe(u8, h) else path;
    if (path.len >= 2 and path[0] == '~' and (path[1] == '/' or path[1] == '\\')) {
        const h = home orelse return path;
        return std.mem.concat(aa, u8, &.{ std.mem.trimEnd(u8, h, "/\\"), path[1..] });
    }
    return path;
}

/// A launcher before it is kept: every rule here, none about tokens.
/// `bases` are the agent CLIs this machine has a plugin for, which are
/// also the keys a custom launcher may not take.
pub fn validate(l: Launcher, bases: []const []const u8) Error!void {
    if (!isValidKey(l.key)) return error.BadKey;
    for (bases) |b| if (std.mem.eql(u8, b, l.key)) return error.KeyTaken;
    if (std.mem.trim(u8, l.name, " \t\r\n").len == 0) return error.BadName;
    for (bases) |b| {
        if (std.mem.eql(u8, b, l.base)) break;
    } else return error.UnknownBase;
    if (!isAbsolute(l.command)) return error.CommandNotAbsolute;
    for (l.env) |e| if (!isValidEnvName(e.name)) return error.BadEnvName;
}

// --------------------------------------------------------------- starting

pub const Os = enum { posix, windows };

/// The words that run `command` on `os`, before the CLI's own arguments.
/// A script on Windows cannot be started as a program: a `.ps1` is handed
/// to PowerShell and a `.cmd` or `.bat` to `cmd /c`. Anything else -- an
/// `.exe`, or any file on POSIX, where the script's own `#!` line runs it --
/// is run as it is.
pub fn wrapCommand(command: []const u8, os: Os) []const []const u8 {
    if (os == .windows) {
        const ext = std.fs.path.extension(command);
        if (std.ascii.eqlIgnoreCase(ext, ".ps1")) return &.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" };
        if (std.ascii.eqlIgnoreCase(ext, ".cmd") or std.ascii.eqlIgnoreCase(ext, ".bat")) return &.{ "cmd", "/c" };
    }
    return &.{};
}

/// The base CLI's command line, `argv`, started through `l` instead: its
/// program replaced by the launcher's command (wrapped for `os`), the rest
/// of what the adapter built kept in order, and the launcher's own
/// arguments after it. In `aa`.
pub fn rewrite(aa: Allocator, argv: []const []const u8, l: Launcher, os: Os) Allocator.Error![]const []const u8 {
    const wrap = wrapCommand(l.command, os);
    const rest = if (argv.len > 0) argv[1..] else argv;
    const out = try aa.alloc([]const u8, wrap.len + 1 + rest.len + l.args.len);
    @memcpy(out[0..wrap.len], wrap);
    out[wrap.len] = l.command;
    @memcpy(out[wrap.len + 1 ..][0..rest.len], rest);
    @memcpy(out[wrap.len + 1 + rest.len ..], l.args);
    return out;
}

// ----------------------------------------------------------------- the set

pub const Set = struct {
    launchers: []const Launcher = &.{},

    pub fn find(self: Set, key: []const u8) ?Launcher {
        for (self.launchers) |l| if (std.mem.eql(u8, l.key, key)) return l;
        return null;
    }
};

/// `set` with `l` in it, replacing the one with its key where it stands or
/// added at the end. An edit keeps the roles it was switched on for unless
/// it says otherwise (`keep_roles`). In `aa`.
pub fn put(aa: Allocator, set: Set, l: Launcher, keep_roles: bool) Allocator.Error!Set {
    var out: std.ArrayList(Launcher) = .empty;
    var replaced = false;
    for (set.launchers) |old| {
        if (std.mem.eql(u8, old.key, l.key)) {
            var n = l;
            if (keep_roles) n.roles = old.roles;
            try out.append(aa, n);
            replaced = true;
        } else try out.append(aa, old);
    }
    if (!replaced) try out.append(aa, l);
    return .{ .launchers = try out.toOwnedSlice(aa) };
}

/// `set` without the launcher `key`; its role switches go with it.
pub fn delete(aa: Allocator, set: Set, key: []const u8) Error!Set {
    var out: std.ArrayList(Launcher) = .empty;
    var found = false;
    for (set.launchers) |l| {
        if (std.mem.eql(u8, l.key, key)) {
            found = true;
            continue;
        }
        try out.append(aa, l);
    }
    if (!found) return error.NoSuchLauncher;
    return .{ .launchers = try out.toOwnedSlice(aa) };
}

/// `set` with launcher `key` switched on or off for `role`.
pub fn setRole(aa: Allocator, set: Set, key: []const u8, role: []const u8, on: bool) Error!Set {
    const out = try aa.dupe(Launcher, set.launchers);
    for (out) |*l| {
        if (!std.mem.eql(u8, l.key, key)) continue;
        var roles: std.ArrayList([]const u8) = .empty;
        for (l.roles) |r| if (!std.mem.eql(u8, r, role)) try roles.append(aa, r);
        if (on) try roles.append(aa, role);
        l.roles = try roles.toOwnedSlice(aa);
        return .{ .launchers = out };
    }
    return error.NoSuchLauncher;
}

/// Roles switched on for a launcher that is gone, or for a role key that
/// is gone, are dropped; how many is returned, for a line in the log.
pub fn forgetRolesNotIn(aa: Allocator, set: Set, roles: []const []const u8) Allocator.Error!struct { set: Set, dropped: usize } {
    const out = try aa.dupe(Launcher, set.launchers);
    var dropped: usize = 0;
    for (out) |*l| {
        var kept: std.ArrayList([]const u8) = .empty;
        for (l.roles) |r| {
            for (roles) |known| {
                if (std.mem.eql(u8, known, r)) break;
            } else {
                dropped += 1;
                continue;
            }
            try kept.append(aa, r);
        }
        l.roles = try kept.toOwnedSlice(aa);
    }
    return .{ .set = .{ .launchers = out }, .dropped = dropped };
}

// ----------------------------------------------------------------- the file

/// `launchers.json`, beside the role library.
pub fn pathBeside(alloc: Allocator, personas_path: []const u8) Allocator.Error![]const u8 {
    const dir = std.fs.path.dirname(personas_path) orelse ".";
    return std.fs.path.join(alloc, &.{ dir, "launchers.json" });
}

/// The file as read. An entry that does not read -- a key not allowed, a
/// field missing -- is left out and counted (`skipped`), never a reason
/// for the rest not to start.
pub fn parseLeaky(aa: Allocator, bytes: []const u8) error{ BadFile, OutOfMemory }!struct { set: Set, skipped: usize } {
    const doc = std.json.parseFromSliceLeaky(std.json.Value, aa, bytes, .{}) catch return error.BadFile;
    const obj = switch (doc) {
        .object => |o| o,
        else => return error.BadFile,
    };
    const arr = switch (obj.get("launchers") orelse return .{ .set = .{}, .skipped = 0 }) {
        .array => |a| a,
        else => return error.BadFile,
    };
    var out: std.ArrayList(Launcher) = .empty;
    var skipped: usize = 0;
    for (arr.items) |v| {
        const l = launcherOf(aa, v) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                skipped += 1;
                continue;
            },
        };
        try out.append(aa, l);
    }
    return .{ .set = .{ .launchers = try out.toOwnedSlice(aa) }, .skipped = skipped };
}

/// One launcher as a tool or the settings form sends it. In `aa`.
pub fn parseOneLeaky(aa: Allocator, bytes: []const u8) error{ Bad, OutOfMemory }!Launcher {
    const v = std.json.parseFromSliceLeaky(std.json.Value, aa, bytes, .{}) catch return error.Bad;
    return launcherOf(aa, v);
}

fn str(o: std.json.ObjectMap, k: []const u8) error{Bad}![]const u8 {
    return switch (o.get(k) orelse return error.Bad) {
        .string => |s| s,
        else => error.Bad,
    };
}

fn strings(aa: Allocator, o: std.json.ObjectMap, k: []const u8) error{ Bad, OutOfMemory }![]const []const u8 {
    const v = o.get(k) orelse return &.{};
    const a = switch (v) {
        .array => |a| a,
        .null => return &.{},
        else => return error.Bad,
    };
    const out = try aa.alloc([]const u8, a.items.len);
    for (a.items, out) |x, *d| d.* = switch (x) {
        .string => |s| s,
        else => return error.Bad,
    };
    return out;
}

fn launcherOf(aa: Allocator, v: std.json.Value) error{ Bad, OutOfMemory }!Launcher {
    const o = switch (v) {
        .object => |o| o,
        else => return error.Bad,
    };
    const key = try str(o, "key");
    if (!isValidKey(key)) return error.Bad;
    var env: std.ArrayList(Env) = .empty;
    if (o.get("env")) |ev| switch (ev) {
        .array => |a| for (a.items) |e| {
            const eo = switch (e) {
                .object => |x| x,
                else => return error.Bad,
            };
            try env.append(aa, .{ .name = try str(eo, "name"), .value = try str(eo, "value") });
        },
        .null => {},
        else => return error.Bad,
    };
    return .{
        .key = key,
        .name = try str(o, "name"),
        .base = try str(o, "base"),
        .command = try str(o, "command"),
        .env = try env.toOwnedSlice(aa),
        .args = try strings(aa, o, "args"),
        .roles = try strings(aa, o, "roles"),
    };
}

fn jstr(s: []const u8) std.json.Formatter([]const u8) {
    return std.json.fmt(s, .{});
}

/// A list of strings as JSON. Public because `writeOwn` writes each one's
/// roles with it.
pub fn writeStrings(w: *std.Io.Writer, list: []const []const u8) std.Io.Writer.Error!void {
    try w.writeAll("[");
    for (list, 0..) |s, i| try w.print("{s}{f}", .{ if (i == 0) "" else ",", jstr(s) });
    try w.writeAll("]");
}

/// The Agent CLIs of the person's own as a JSON array, each with the roles
/// it is switched on for: what `ghostty_app_agent_clis` hands every host
/// that lists a role's CLIs (task 2156 v5). **Duck-typed on purpose**:
/// `App.ownClis` answers with `ControlRoom.OwnCli`, which is these four
/// fields, and this file must not depend on `ControlRoom` to say so.
///
/// **A variable's name, never its value, and no command**: this is what the
/// role library and both hosts' `Role ▸` menus draw, and they have no
/// business with a token. `writeSafe` is the form's own, which does.
pub fn writeOwn(w: *std.Io.Writer, own: anytype) std.Io.Writer.Error!void {
    try w.writeAll("[");
    for (own, 0..) |o, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"key\":{f},\"name\":{f},\"base\":{f},\"roles\":", .{
            jstr(o.key), jstr(o.name), jstr(o.base),
        });
        try writeStrings(w, o.roles);
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

/// The file, values and all: only ever written to the person's own
/// settings directory.
pub fn writeFile(w: *std.Io.Writer, set: Set) std.Io.Writer.Error!void {
    try w.writeAll("{\"version\":1,\"launchers\":[");
    for (set.launchers, 0..) |l, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"key\":{f},\"name\":{f},\"base\":{f},\"command\":{f},\"env\":[", .{ jstr(l.key), jstr(l.name), jstr(l.base), jstr(l.command) });
        for (l.env, 0..) |e, j| try w.print("{s}{{\"name\":{f},\"value\":{f}}}", .{ if (j == 0) "" else ",", jstr(e.name), jstr(e.value) });
        try w.writeAll("],\"args\":");
        try writeStrings(w, l.args);
        try w.writeAll(",\"roles\":");
        try writeStrings(w, l.roles);
        try w.writeAll("}");
    }
    try w.writeAll("]}\n");
}

/// One launcher as anybody but the settings form is shown it: the
/// variables by name only, the arguments counted, never written out -- a
/// token may be in either, and this goes to logs, groups and agents.
pub fn writeSafe(w: *std.Io.Writer, l: Launcher) std.Io.Writer.Error!void {
    try w.print("{{\"key\":{f},\"name\":{f},\"base\":{f},\"command\":{f},\"env_names\":[", .{ jstr(l.key), jstr(l.name), jstr(l.base), jstr(l.command) });
    for (l.env, 0..) |e, i| try w.print("{s}{f}", .{ if (i == 0) "" else ",", jstr(e.name) });
    try w.print("],\"args\":{d},\"roles\":", .{l.args.len});
    try writeStrings(w, l.roles);
    try w.writeAll("}");
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

const deepseek: Launcher = .{
    .key = "claude-deepseek-flash",
    .name = "Claude · DeepSeek flash",
    .base = "claude-code",
    .command = "/home/me/boclaw/claude-boclaw",
    .env = &.{.{ .name = "ANTHROPIC_MODEL", .value = "deepseek-flash" }},
    .args = &.{"--verbose"},
};

test "2156: a launcher is a known base, an absolute command, plain names -- and no token is looked at" {
    const bases = [_][]const u8{ "claude-code", "codex" };
    try validate(deepseek, &bases);
    var l = deepseek;
    l.base = "gemini";
    try testing.expectError(error.UnknownBase, validate(l, &bases));
    l = deepseek;
    l.command = "claude-boclaw";
    try testing.expectError(error.CommandNotAbsolute, validate(l, &bases));
    l = deepseek;
    l.key = "codex";
    try testing.expectError(error.KeyTaken, validate(l, &bases));
    l = deepseek;
    l.env = &.{.{ .name = "1BAD", .value = "" }};
    try testing.expectError(error.BadEnvName, validate(l, &bases));
    // A token written straight in is the person's to write.
    l = deepseek;
    l.env = &.{.{ .name = "ANTHROPIC_AUTH_TOKEN", .value = "sk-live-123" }};
    try validate(l, &bases);
    try testing.expect(isAbsolute("C:\\tools\\claude.cmd"));
    try testing.expect(isAbsolute("\\\\srv\\share\\x.ps1"));
}

test "2156: ~/ is the home directory's, before it is kept" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try expandHome(arena.allocator(), "~/boclaw/claude-boclaw", "/home/me/");
    try testing.expectEqualStrings("/home/me/boclaw/claude-boclaw", got);
    try testing.expectEqualStrings("/bin/x", try expandHome(arena.allocator(), "/bin/x", "/home/me"));
}

test "2156: the base CLI's command line, started through the launcher" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const argv = [_][]const u8{ "claude", "--settings", "{}", "--model", "sonnet" };
    const got = try rewrite(aa, &argv, deepseek, .posix);
    const want = [_][]const u8{ "/home/me/boclaw/claude-boclaw", "--settings", "{}", "--model", "sonnet", "--verbose" };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| try testing.expectEqualStrings(a, b);
}

test "2156: a script on Windows is handed to what runs it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var l = deepseek;
    l.args = &.{};
    l.command = "C:\\tools\\claude-gw.PS1";
    const ps = try rewrite(aa, &.{ "claude", "-r" }, l, .windows);
    try testing.expectEqualStrings("powershell", ps[0]);
    try testing.expectEqualStrings("-File", ps[4]);
    try testing.expectEqualStrings(l.command, ps[5]);
    try testing.expectEqualStrings("-r", ps[6]);
    l.command = "C:\\tools\\claude-gw.cmd";
    const cmd = try rewrite(aa, &.{"claude"}, l, .windows);
    try testing.expectEqualStrings("cmd", cmd[0]);
    try testing.expectEqualStrings("/c", cmd[1]);
    try testing.expectEqualStrings(l.command, cmd[2]);
    l.command = "C:\\tools\\claude-gw.bat";
    try testing.expectEqual(@as(usize, 2), wrapCommand(l.command, .windows).len);
    l.command = "C:\\tools\\claude-gw.exe";
    try testing.expectEqual(@as(usize, 0), wrapCommand(l.command, .windows).len);
    // POSIX runs a script by its own #! line.
    try testing.expectEqual(@as(usize, 0), wrapCommand("/x/gw.cmd", .posix).len);
}

test "2156: a new launcher is off for every role, and its switches go when it does" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var set = try put(aa, .{}, deepseek, true);
    try testing.expect(!set.find(deepseek.key).?.enabledFor("polter-tester"));
    set = try setRole(aa, set, deepseek.key, "polter-tester", true);
    try testing.expect(set.find(deepseek.key).?.enabledFor("polter-tester"));
    // An edit keeps the switches.
    var edited = deepseek;
    edited.name = "renamed";
    set = try put(aa, set, edited, true);
    try testing.expect(set.find(deepseek.key).?.enabledFor("polter-tester"));
    // **A form that carries the roles is taken at its word** (this slice):
    // the Agent CLI page is where they are ticked, so an edit that unticked
    // one has to untick it here -- `keep_roles` false, which is what
    // `settingsPutLauncher` asks for.
    set = try put(aa, set, edited, true);
    set = try put(aa, set, edited, false);
    try testing.expect(!set.find(deepseek.key).?.enabledFor("polter-tester"));
    set = try setRole(aa, set, deepseek.key, "polter-tester", true);

    // A role that is gone is dropped from the switches.
    const f = try forgetRolesNotIn(aa, set, &.{"polter-supervisor"});
    try testing.expectEqual(@as(usize, 1), f.dropped);
    set = try delete(aa, f.set, deepseek.key);
    try testing.expect(set.find(deepseek.key) == null);
    try testing.expectError(error.NoSuchLauncher, delete(aa, set, deepseek.key));
}

test "2156: the file reads back, an entry that does not read is skipped, and what is shown has no values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var withRole = deepseek;
    withRole.roles = &.{"polter-tester"};
    var out: std.Io.Writer.Allocating = .init(aa);
    try writeFile(&out.writer, .{ .launchers = &.{withRole} });
    const back = try parseLeaky(aa, out.written());
    try testing.expectEqual(@as(usize, 0), back.skipped);
    const l = back.set.launchers[0];
    try testing.expectEqualStrings("deepseek-flash", l.env[0].value);
    try testing.expect(l.enabledFor("polter-tester"));

    const broken = try parseLeaky(aa, "{\"launchers\":[{\"key\":\"Bad Key\"},{\"key\":\"ok\",\"name\":\"n\",\"base\":\"codex\",\"command\":\"/x\"}]}");
    try testing.expectEqual(@as(usize, 1), broken.skipped);
    try testing.expectEqualStrings("ok", broken.set.launchers[0].key);

    var secret = withRole;
    secret.env = &.{.{ .name = "ANTHROPIC_AUTH_TOKEN", .value = "sk-live-SECRET" }};
    var safe: std.Io.Writer.Allocating = .init(aa);
    try writeSafe(&safe.writer, secret);
    try testing.expect(std.mem.indexOf(u8, safe.written(), "sk-live-SECRET") == null);
    try testing.expect(std.mem.indexOf(u8, safe.written(), "ANTHROPIC_AUTH_TOKEN") != null);
    try testing.expect(std.mem.indexOf(u8, safe.written(), "\"value\"") == null);
    try testing.expect(std.mem.indexOf(u8, safe.written(), "--verbose") == null);
}

test "2156 v5: what every host is given of the person's own is their names and their switches -- never a value, never a command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const own = [_]struct {
        key: []const u8,
        name: []const u8,
        base: []const u8,
        roles: []const []const u8,
    }{
        .{ .key = deepseek.key, .name = deepseek.name, .base = deepseek.base, .roles = &.{"polter-tester"} },
    };
    var out: std.Io.Writer.Allocating = .init(aa);
    try writeOwn(&out.writer, &own);
    const text = out.written();
    try testing.expectEqualStrings(
        "[{\"key\":\"claude-deepseek-flash\",\"name\":\"Claude · DeepSeek flash\",\"base\":\"claude-code\",\"roles\":[\"polter-tester\"]}]",
        text,
    );
    // The command and the variables' values are the settings form's own
    // (`writeSafe`); every other reader of the person's own is given this,
    // and it carries neither. (`"deepseek-flash"` with its quotes is the
    // variable's value; the key ends `-deepseek-flash"`, no quote in front.)
    try testing.expect(std.mem.indexOf(u8, text, "boclaw") == null);
    try testing.expect(std.mem.indexOf(u8, text, "\"deepseek-flash\"") == null);
    try testing.expect(std.mem.indexOf(u8, text, "ANTHROPIC_MODEL") == null);
    try testing.expect(std.mem.indexOf(u8, text, "command") == null);
    try testing.expect(std.mem.indexOf(u8, text, "env") == null);
    // It reads back as the same thing: this is what the two hosts parse.
    const Parsed = struct { key: []const u8, name: []const u8, base: []const u8, roles: []const []const u8 };
    const got = try std.json.parseFromSlice([]const Parsed, aa, text, .{ .ignore_unknown_fields = true });
    defer got.deinit();
    try testing.expectEqual(@as(usize, 1), got.value.len);
    try testing.expectEqualStrings("claude-deepseek-flash", got.value[0].key);
    try testing.expectEqualStrings("polter-tester", got.value[0].roles[0]);
}
