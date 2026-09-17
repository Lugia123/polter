//! What each agent CLI on this machine already has -- **read only**.
//!
//! `dev-docs/poltergeist/roles.md` section four draws the line this file
//! sits on: *"谁发出去的，谁才收得回"*. Polter maintains its own tool
//! surface and the upstreams a user handed to a slot; everything else a
//! host has installed by itself is **listed and never touched**.
//!
//! The reason it is listed at all is stated there too, and it is the whole
//! point of this module: a role that does not give an agent `argus` has not
//! taken `argus` away if the host installed it globally. Without this list
//! the role editor would show a role that looks airtight and is not, and the
//! user would have no way to find that out. **Being able to see what a role
//! does not cover is what makes the role honest.**
//!
//! Three things this deliberately does not do:
//!
//!   * **It never writes.** Not a file, not a directory, not a flag. There
//!     is no code path here that opens anything for writing, and that is
//!     meant to stay checkable by reading the imports.
//!   * **It never reads a value out of an `env` block.** Every host's MCP
//!     entry carries one and it is where API keys live. Names and commands
//!     are what a person needs to recognise a server; the secrets are not,
//!     and a list that carried them would end up on a screen, in a log, and
//!     in an agent's context. Only key *names* leave this file.
//!   * **It does not guess a path.** Four of the seven hosts have no
//!     confirmed skills directory (see `provisioning.md` section four, and
//!     the `printf ''` in their `provision.sh`). Those report
//!     `unknown_location`, which is not the same answer as `absent`.
//!
//! # Four states, because two of them get confused
//!
//! `provisioning.md` section seven is about exactly one failure: *"「你没装
//! 这个 CLI」和「装了但注册失败」长得一模一样"*. Reading has the same shape
//! and one more case, so there are four:
//!
//! | state | what it means | is it a problem |
//! | --- | --- | --- |
//! | `unknown_location` | nobody has confirmed where this host keeps it | no, but it is not evidence of anything either |
//! | `absent` | the path is known and there is nothing there | **no** |
//! | `read` | it was read | no |
//! | `failed` | it is there and could not be read or parsed | **yes, say so** |
//!
//! An empty `read` and an `absent` are also different answers, and both are
//! different from `failed`. A caller that renders all four as "nothing here"
//! has thrown away the distinction this file exists to keep.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.poltergeist);

/// Largest config file we will read. `~/.claude.json` is the big one --
/// 300 KB on the machine this was written against, because it carries a
/// per-project block for every directory the user has ever run in.
///
/// Over the limit is `failed`, not `absent`: the file is there and we did
/// not read it, which is the one thing a user needs told.
const max_config_bytes = 8 * 1024 * 1024;

/// The agent CLIs `provisioning.md` section four names. The keys match the
/// `POLTER_HOST_KEY` in each `plugins/<host>/provision.sh`, so that a host
/// added there and not here is a name that does not resolve rather than a
/// row that silently goes missing.
pub const Host = enum {
    claude_code,
    codex,
    gemini,
    qwen_code,
    opencode,
    deepseek,
    kimi,

    /// What `plugins/<host>/provision.sh` calls `POLTER_HOST_LABEL`.
    pub fn label(self: Host) []const u8 {
        return switch (self) {
            .claude_code => "Claude Code",
            .codex => "Codex CLI",
            .gemini => "Gemini CLI",
            .qwen_code => "Qwen Code",
            .opencode => "opencode",
            .deepseek => "DeepSeek-TUI",
            .kimi => "Kimi CLI",
        };
    }

    /// The binary name, so PATH can answer whether this host is on the
    /// machine at all. `POLTER_HOST_BIN`.
    pub fn binary(self: Host) []const u8 {
        return switch (self) {
            .claude_code => "claude",
            .codex => "codex",
            .gemini => "gemini",
            .qwen_code => "qwen",
            .opencode => "opencode",
            .deepseek => "deepseek",
            .kimi => "kimi",
        };
    }

    /// The key Polter registers itself under, so a reader can tell
    /// Polter's own entry apart from the user's.
    pub const polter_entry = "polter";

    /// What a slot entry's key starts with.
    ///
    /// `roles.md` 3.4: handing an upstream to Polter rewrites the host
    /// config's `argus` into `polter:argus`, carrying the command and the
    /// environment over unchanged. So the number of slots registered on
    /// this machine is countable from the same files this module already
    /// reads -- see `Report.slotBudget`.
    pub const slot_prefix = "polter:";
};

/// How a config file is written. It decides which parser runs, and it is
/// the thing `provisioning.md` warns about twice: *"Codex 的键是
/// `mcp_servers`，别家是 `mcpServers`，而且它是 TOML。照着别家抄一定错。"*
const Shape = enum {
    /// A JSON object at `key`, whose member names are the server names.
    json_object,
    /// TOML `[key.<name>]` table headers.
    toml_tables,
};

/// Where one host keeps its MCP registrations.
const McpFile = struct {
    /// Relative to the user's home directory.
    rel_path: []const u8,
    /// The top-level key. **Not the same word everywhere**; see `Shape`.
    key: []const u8,
    shape: Shape,
};

/// `null` when nobody has confirmed it. Kimi is the one: `provisioning.md`
/// has "TOML" and "待核" in the same row, and a guessed path read is a row
/// on a screen that says "nothing installed" on no evidence at all.
fn mcpFile(host: Host) ?McpFile {
    return switch (host) {
        .claude_code => .{ .rel_path = ".claude.json", .key = "mcpServers", .shape = .json_object },
        .codex => .{ .rel_path = ".codex/config.toml", .key = "mcp_servers", .shape = .toml_tables },
        .gemini => .{ .rel_path = ".gemini/settings.json", .key = "mcpServers", .shape = .json_object },
        .qwen_code => .{ .rel_path = ".qwen/settings.json", .key = "mcpServers", .shape = .json_object },
        // Nested under `mcp`, and the structure differs as well -- for a
        // list of names that does not matter, for anything more it does.
        .opencode => .{ .rel_path = ".config/opencode/opencode.json", .key = "mcp", .shape = .json_object },
        .deepseek => .{ .rel_path = ".deepseek/mcp.json", .key = "mcpServers", .shape = .json_object },
        .kimi => null,
    };
}

/// The user-level skills directory, or `null` where `host_skills_dir`
/// returns the empty string. Four of the seven do, and the comment beside
/// each of them says why: *"写文件进一个猜出来的目录，比一个都不写更糟"*.
/// Reading has the milder version of the same problem -- a guess that finds
/// nothing reports "no skills" and looks like an answer.
fn skillsDir(host: Host) ?[]const u8 {
    return switch (host) {
        .claude_code => ".claude/skills",
        .codex => ".codex/skills",
        .gemini => ".gemini/skills",
        .qwen_code, .opencode, .deepseek, .kimi => null,
    };
}

/// How well one part of one host could be read.
pub const Status = enum {
    /// Nobody has confirmed where this host keeps this. **Not evidence of
    /// anything**: it is not "there is none", it is "we did not look".
    unknown_location,

    /// The path is known and there is nothing at it. This is the ordinary
    /// answer for a host that is not installed, and it **is not a problem**.
    absent,

    /// Read. `items` is what was in it, and an empty `items` here means the
    /// file really was empty of them -- which `absent` does not.
    read,

    /// It is there and we could not read or parse it. **This is the one to
    /// put in front of the user**, with `detail`.
    failed,
};

/// What sort of thing an item is.
pub const Kind = enum { mcp, skill, plugin };

/// Where it was configured.
pub const Origin = enum {
    /// The host's user-level config: it applies to every terminal on this
    /// machine, which is the fact that makes it interesting to a role.
    user,
    /// Scoped to one project directory.
    project,
};

/// One thing a host has.
pub const Item = struct {
    kind: Kind,
    /// The name the host knows it by. For a plugin that is the host's own
    /// `name@marketplace` spelling, kept verbatim for the same reason a
    /// slot does not rename a tool: it is what the user will search for.
    name: []const u8,
    /// Whether the host has it switched on, where the host has such a
    /// switch. `null` means this host has no notion of enabling this kind
    /// of thing -- **not** that it is off.
    enabled: ?bool = null,
    origin: Origin = .user,
    /// The project this is scoped to, when `origin == .project`.
    project: ?[]const u8 = null,
    /// True when this is Polter's own registration rather than the user's.
    /// A role editor that shows `polter` in the same list as everything
    /// else invites the user to wonder why they cannot remove it.
    ours: bool = false,
};

/// One part of one host: what was looked at, how it went, what was in it.
pub const Section = struct {
    status: Status,
    /// The file or directory that was looked at. `null` only when
    /// `status == .unknown_location`, where there was nothing to look at.
    path: ?[]const u8 = null,
    /// Why, when `status == .failed`. A sentence for a person.
    detail: ?[]const u8 = null,
    items: []const Item = &.{},
};

/// Everything known about one host.
pub const HostReport = struct {
    host: Host,
    label: []const u8,
    /// Whether the binary is on PATH. It is the cheap half of
    /// `provisioning.md`'s point that *"探测是免费的，注册不是"*, and here
    /// it is what separates "no config because this host is not installed"
    /// from "installed and never configured" -- two `absent`s that mean
    /// different things.
    on_path: bool,
    mcp: Section,
    skills: Section,
    plugins: Section,

    /// How many of `mcp.items` are Polter slots (`polter:<name>`).
    ///
    /// This is the per-host half of the connection budget in
    /// `personas-contract.md` 4.1. It is counted rather than guessed
    /// because it is countable: a slot is a `polter:`-prefixed entry in
    /// exactly the file above.
    slots: usize,
};

/// The whole scan. Everything in it is owned by `arena`.
pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    hosts: []const HostReport,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The `M` in `personas-contract.md` 4.1's `K x (2 + M)`.
    ///
    /// # Why the maximum and not the sum
    ///
    /// A slot process is an MCP server entry in **one** host's config, and
    /// a terminal runs **one** agent CLI. So a terminal starting its agent
    /// starts that host's slots and no others: the connections a terminal
    /// can consume are capped by whichever host registered the most, not
    /// by every host added together. Summing over a machine that has both
    /// Claude Code and Codex installed overstates the worst case, and an
    /// overstated worst case buys a default that is larger than it needs
    /// to be.
    ///
    /// # Why `complete` is not decoration
    ///
    /// A host whose config could not be read (`failed`) or whose config
    /// location nobody has confirmed (`unknown_location`) contributes a
    /// count of zero, and **zero here is not a reading** -- it is the
    /// absence of one. If that host is on PATH, it may be running with any
    /// number of slots. So the count comes back with a flag saying whether
    /// anything was unreadable, and a caller sizing a limit off `max`
    /// while ignoring `complete` is sizing it off a number that was never
    /// measured. `false` does not mean the number is wrong; it means it is
    /// a floor rather than a bound.
    pub fn slotBudget(self: Report) SlotBudget {
        var out: SlotBudget = .{ .max = 0, .complete = true };
        for (self.hosts) |h| {
            if (h.slots > out.max) out.max = h.slots;

            // Only a host that is actually on this machine can be running
            // slots we failed to count. One that is not installed has none
            // whatever its config file says, so it cannot make the answer
            // incomplete.
            if (!h.on_path) continue;
            switch (h.mcp.status) {
                .read, .absent => {},
                .failed, .unknown_location => out.complete = false,
            }
        }
        return out;
    }
};

pub const SlotBudget = struct {
    /// The largest number of Polter slots any one host has registered.
    max: usize,
    /// False when some installed host's MCP config could not be read, so
    /// `max` is a floor rather than the answer.
    complete: bool,
};

/// What to look at. Separated out so the tests can point the whole thing at
/// a fixture directory instead of somebody's home.
pub const Options = struct {
    /// The user's home directory.
    home: []const u8,
    /// The `PATH` to search for host binaries, in the platform's own
    /// separator. `null` skips the search and reports `on_path = false`
    /// for everyone -- which a caller must not read as "nothing installed".
    path_env: ?[]const u8 = null,
    /// A project directory to additionally report project-scoped entries
    /// for. `null` reports user-level only.
    ///
    /// This is per-terminal: a tab has a working directory, and the MCP
    /// servers that reach an agent in it are the user-level ones plus that
    /// project's. A role editor showing only the first would be describing
    /// a different terminal than the one it is open on.
    project: ?[]const u8 = null,
};

/// Read what every host has. Never writes anything.
pub fn scan(alloc: Allocator, io: std.Io, opts: Options) Allocator.Error!Report {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var hosts: std.ArrayList(HostReport) = .empty;

    for (std.enums.values(Host)) |host| {
        const mcp_section = readMcp(aa, io, host, opts);
        try hosts.append(aa, .{
            .host = host,
            .label = host.label(),
            .on_path = if (opts.path_env) |p| onPath(io, p, host.binary()) else false,
            .mcp = mcp_section,
            .skills = readSkills(aa, io, host, opts.home),
            .plugins = readPlugins(aa, io, host, opts.home),
            .slots = countSlots(mcp_section),
        });
    }

    return .{ .arena = arena, .hosts = try hosts.toOwnedSlice(aa) };
}

/// How many of a host's MCP entries are Polter slots.
///
/// **User-scoped only.** A project-scoped entry reaches an agent started
/// in that one directory; the budget is about how many terminals can be
/// open at once, and mixing the two would count a slot that most of those
/// terminals will never start.
fn countSlots(sec: Section) usize {
    var n: usize = 0;
    for (sec.items) |item| {
        if (item.origin != .user) continue;
        if (std.mem.startsWith(u8, item.name, Host.slot_prefix)) n += 1;
    }
    return n;
}

/// Is `name` an executable file in one of `path_env`'s directories?
///
/// Looked up rather than run. Running a host binary to ask its version
/// would be a side effect on somebody's machine from something that
/// advertises itself as read-only, and it would be slow seven times over.
fn onPath(io: std.Io, path_env: []const u8, name: []const u8) bool {
    const sep = if (@import("builtin").os.tag == .windows) ';' else ':';
    var it = std.mem.tokenizeScalar(u8, path_env, sep);
    while (it.next()) |dir_path| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const joined = std.fmt.bufPrint(
            &buf,
            "{s}{c}{s}",
            .{ dir_path, std.fs.path.sep, name },
        ) catch continue;
        const st = std.Io.Dir.cwd().statFile(io, joined, .{}) catch continue;
        if (st.kind == .directory) continue;
        return true;
    }
    return false;
}

/// Join `home` with a relative path, arena-owned.
fn homePath(aa: Allocator, home: []const u8, rel: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(aa, "{s}{c}{s}", .{ home, std.fs.path.sep, rel });
}

fn readMcp(aa: Allocator, io: std.Io, host: Host, opts: Options) Section {
    const spec = mcpFile(host) orelse return .{ .status = .unknown_location };

    const path = homePath(aa, opts.home, spec.rel_path) catch
        return .{ .status = .failed, .detail = "out of memory" };

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        aa,
        .limited(max_config_bytes),
    ) catch |err| return switch (err) {
        error.FileNotFound => .{ .status = .absent, .path = path },
        // **Deliberately not `absent`.** The file is there; we did not
        // read it. Those are different answers and the whole module is
        // built around not letting them collapse.
        else => .{
            .status = .failed,
            .path = path,
            .detail = std.fmt.allocPrint(
                aa,
                "读不了这个文件：{t}",
                .{err},
            ) catch "读不了这个文件",
        },
    };

    return switch (spec.shape) {
        .json_object => readMcpJson(aa, bytes, path, spec.key, opts.project),
        .toml_tables => readMcpToml(aa, bytes, path, spec.key, .mcp),
    };
}

fn readMcpJson(
    aa: Allocator,
    bytes: []const u8,
    path: []const u8,
    key: []const u8,
    project: ?[]const u8,
) Section {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, bytes, .{}) catch
        return .{
            .status = .failed,
            .path = path,
            .detail = "这个文件不是合法的 JSON",
        };

    const root = switch (parsed) {
        .object => |o| o,
        else => return .{
            .status = .failed,
            .path = path,
            .detail = "这个文件的顶层不是一个 JSON 对象",
        },
    };

    var items: std.ArrayList(Item) = .empty;

    if (root.get(key)) |v| switch (v) {
        .object => |servers| {
            var it = servers.iterator();
            while (it.next()) |e| {
                // **Only the name.** The value beside it holds `env`, and
                // that is where the API keys are. See the module comment.
                items.append(aa, .{
                    .kind = .mcp,
                    .name = e.key_ptr.*,
                    .ours = std.mem.eql(u8, e.key_ptr.*, Host.polter_entry),
                }) catch {};
            }
        },
        // The key is there and is not an object. That is a malformed
        // config, not an empty one.
        else => return .{
            .status = .failed,
            .path = path,
            .detail = std.fmt.allocPrint(
                aa,
                "`{s}` 在这个文件里不是一个对象",
                .{key},
            ) catch "配置里那个键的形状不对",
        },
    };

    // Project-scoped entries, where the host keeps them in the same file.
    // Claude Code is the one that does: `projects.<path>.mcpServers`.
    if (project) |dir| if (root.get("projects")) |v| switch (v) {
        .object => |projects| if (projects.get(dir)) |pv| switch (pv) {
            .object => |po| if (po.get(key)) |sv| switch (sv) {
                .object => |servers| {
                    var it = servers.iterator();
                    while (it.next()) |e| items.append(aa, .{
                        .kind = .mcp,
                        .name = e.key_ptr.*,
                        .origin = .project,
                        .project = dir,
                        .ours = std.mem.eql(u8, e.key_ptr.*, Host.polter_entry),
                    }) catch {};
                },
                else => {},
            },
            else => {},
        },
        else => {},
    };

    return .{
        .status = .read,
        .path = path,
        .items = items.toOwnedSlice(aa) catch &.{},
    };
}

/// Pull `[<key>.<name>]` table headers out of a TOML file.
///
/// # Why a line scan and not a parser
///
/// There is no TOML parser in the tree and one is a large thing to bring in
/// for a list of names. What is read here is a table header, which is a
/// single line with a fixed shape -- so the scan is the whole grammar of
/// what it claims to read, rather than a simplification of a bigger one.
///
/// # The failure a scanner like this has, and the guard against it
///
/// TOML can also spell this as one inline table
/// (`mcp_servers = { argus = { … } }`), and a scan for `[mcp_servers.` sees
/// **nothing** in that file. An empty list and a file written the other way
/// are then the same output -- a reader going blind with a zero exit, which
/// is the shape that gets believed.
///
/// So: if the key appears anywhere in the file and no header matched, this
/// returns `failed` naming the reason. It is allowed to be wrong in the
/// direction of saying "go and look yourself"; it is not allowed to be
/// wrong in the direction of "there are none".
fn readMcpToml(
    aa: Allocator,
    bytes: []const u8,
    path: []const u8,
    key: []const u8,
    kind: Kind,
) Section {
    var items: std.ArrayList(Item) = .empty;

    const prefix = std.fmt.allocPrint(aa, "[{s}.", .{key}) catch
        return .{ .status = .failed, .path = path, .detail = "out of memory" };

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        if (!std.mem.endsWith(u8, line, "]")) continue;

        const inner = line[prefix.len .. line.len - 1];
        // `[mcp_servers.serena.env]` is a sub-table of a server already
        // listed, not another server.
        if (std.mem.indexOfScalar(u8, inner, '.') != null) continue;

        // Codex quotes a name that needs it (`[plugins."a@b"]`). The
        // quotes are the file's, not the name's.
        const name = std.mem.trim(u8, inner, "\"'");
        if (name.len == 0) continue;

        items.append(aa, .{
            .kind = kind,
            .name = name,
            .ours = std.mem.eql(u8, name, Host.polter_entry),
        }) catch {};
    }

    if (items.items.len == 0 and std.mem.indexOf(u8, bytes, key) != null) {
        return .{
            .status = .failed,
            .path = path,
            .detail = std.fmt.allocPrint(
                aa,
                "这个文件里有 `{s}`，但没有一个 `[{s}.<名字>]` 表头" ++
                    "——大概是写成了内联表，这里读不出来，请自己看一眼",
                .{ key, key },
            ) catch "这个文件的写法这里读不出来",
        };
    }

    return .{
        .status = .read,
        .path = path,
        .items = items.toOwnedSlice(aa) catch &.{},
    };
}

/// Every directory in the host's user-level skills directory is a skill.
///
/// The name is the directory name, which is what the host matches on and
/// therefore what the user will recognise. The frontmatter inside is not
/// read: a list of names is what a role editor shows, and opening several
/// hundred markdown files to build one is a cost with no buyer.
fn readSkills(aa: Allocator, io: std.Io, host: Host, home: []const u8) Section {
    const rel = skillsDir(host) orelse return .{ .status = .unknown_location };

    const path = homePath(aa, home, rel) catch
        return .{ .status = .failed, .detail = "out of memory" };

    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound, error.NotDir => .{ .status = .absent, .path = path },
            else => .{
                .status = .failed,
                .path = path,
                .detail = std.fmt.allocPrint(aa, "打不开这个目录：{t}", .{err}) catch
                    "打不开这个目录",
            },
        };
    };
    defer dir.close(io);

    var items: std.ArrayList(Item) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        // `readdir` reports `unknown` on some filesystems; the same stat
        // fallback the group log uses.
        const kind = if (entry.kind != .unknown) entry.kind else k: {
            const st = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch
                continue;
            break :k st.kind;
        };
        if (kind != .directory) continue;

        const name = aa.dupe(u8, entry.name) catch continue;
        items.append(aa, .{ .kind = .skill, .name = name }) catch {};
    }

    return .{
        .status = .read,
        .path = path,
        .items = items.toOwnedSlice(aa) catch &.{},
    };
}

/// Plugins, where a host has such a thing.
///
/// Claude Code is the only one here with both halves: what is installed
/// (`~/.claude/plugins/installed_plugins.json`) and what is switched on
/// (`~/.claude/settings.json`, `enabledPlugins`). Reporting only the first
/// would put a plugin the user turned off in the same row as one they use,
/// and it is exactly a disabled plugin that a role's `disable_host_plugins`
/// hint is about.
///
/// Codex keeps its own in `config.toml` as `[plugins."<name@marketplace>"]`
/// tables, which the same scanner reads.
///
/// The rest report `unknown_location`: it is not that they have no plugins,
/// it is that nobody has checked where they keep them.
fn readPlugins(aa: Allocator, io: std.Io, host: Host, home: []const u8) Section {
    switch (host) {
        .claude_code => {},
        .codex => {
            const path = homePath(aa, home, ".codex/config.toml") catch
                return .{ .status = .failed, .detail = "out of memory" };
            const bytes = std.Io.Dir.cwd().readFileAlloc(
                io,
                path,
                aa,
                .limited(max_config_bytes),
            ) catch |err| return switch (err) {
                error.FileNotFound => .{ .status = .absent, .path = path },
                else => .{
                    .status = .failed,
                    .path = path,
                    .detail = std.fmt.allocPrint(aa, "读不了这个文件：{t}", .{err}) catch
                        "读不了这个文件",
                },
            };
            return readMcpToml(aa, bytes, path, "plugins", .plugin);
        },
        else => return .{ .status = .unknown_location },
    }

    const path = homePath(aa, home, ".claude/plugins/installed_plugins.json") catch
        return .{ .status = .failed, .detail = "out of memory" };

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        aa,
        .limited(max_config_bytes),
    ) catch |err| return switch (err) {
        error.FileNotFound => .{ .status = .absent, .path = path },
        else => .{
            .status = .failed,
            .path = path,
            .detail = std.fmt.allocPrint(aa, "读不了这个文件：{t}", .{err}) catch
                "读不了这个文件",
        },
    };

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, bytes, .{}) catch
        return .{ .status = .failed, .path = path, .detail = "这个文件不是合法的 JSON" };

    const root = switch (parsed) {
        .object => |o| o,
        else => return .{
            .status = .failed,
            .path = path,
            .detail = "这个文件的顶层不是一个 JSON 对象",
        },
    };

    // The on/off switches live in a different file, and a plugin missing
    // from it is on -- so `null` here would be wrong and `false` would be
    // wrong; the map is read first and consulted per name.
    const enabled = readEnabledPlugins(aa, io, home);

    var items: std.ArrayList(Item) = .empty;

    if (root.get("plugins")) |v| switch (v) {
        .object => |plugins| {
            var it = plugins.iterator();
            while (it.next()) |e| items.append(aa, .{
                .kind = .plugin,
                .name = e.key_ptr.*,
                .enabled = enabled.get(e.key_ptr.*),
            }) catch {};
        },
        else => return .{
            .status = .failed,
            .path = path,
            .detail = "`plugins` 在这个文件里不是一个对象",
        },
    };

    return .{
        .status = .read,
        .path = path,
        .items = items.toOwnedSlice(aa) catch &.{},
    };
}

/// `enabledPlugins` out of the host's settings file.
///
/// A name that is not in the map is **not** disabled -- it simply has no
/// entry, and the host's default applies. So this returns a map and the
/// caller stores the `?bool` it gets back, rather than defaulting to false
/// somewhere in the middle where nobody would see it happen.
fn readEnabledPlugins(
    aa: Allocator,
    io: std.Io,
    home: []const u8,
) std.StringHashMapUnmanaged(bool) {
    var out: std.StringHashMapUnmanaged(bool) = .empty;

    const path = homePath(aa, home, ".claude/settings.json") catch return out;
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        aa,
        .limited(max_config_bytes),
    ) catch return out;

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, bytes, .{}) catch
        return out;
    const root = switch (parsed) {
        .object => |o| o,
        else => return out,
    };
    const v = root.get("enabledPlugins") orelse return out;
    const map = switch (v) {
        .object => |o| o,
        else => return out,
    };

    var it = map.iterator();
    while (it.next()) |e| switch (e.value_ptr.*) {
        .bool => |b| out.put(aa, e.key_ptr.*, b) catch {},
        else => {},
    };
    return out;
}

/// Write the report as JSON, for a host UI that is not Zig.
///
/// Both ends of the role editor are somebody else's language -- Swift on
/// macOS, Rust on Windows -- and both want the same list. One serializer
/// here is what keeps them from writing two readers that disagree.
///
/// `status` is spelled out rather than reduced to a boolean, because the
/// four states are the module's whole point and a serializer is exactly
/// where three of them would quietly become "false".
pub fn writeJson(report: Report, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const budget = report.slotBudget();
    try w.print(
        \\{{"slot_budget":{{"max":{d},"complete":{}}},"hosts":[
    , .{ budget.max, budget.complete });
    for (report.hosts, 0..) |h, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(
            \\{{"key":"{t}","label":{f},"on_path":{},"slots":{d}
        , .{ h.host, std.json.fmt(h.label, .{}), h.on_path, h.slots });
        try w.writeAll(",\"mcp\":");
        try writeSection(h.mcp, w);
        try w.writeAll(",\"skills\":");
        try writeSection(h.skills, w);
        try w.writeAll(",\"plugins\":");
        try writeSection(h.plugins, w);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

fn writeSection(sec: Section, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{{\"status\":\"{t}\"", .{sec.status});
    if (sec.path) |p| try w.print(",\"path\":{f}", .{std.json.fmt(p, .{})});
    if (sec.detail) |d| try w.print(",\"detail\":{f}", .{std.json.fmt(d, .{})});
    try w.writeAll(",\"items\":[");
    for (sec.items, 0..) |item, i| {
        if (i > 0) try w.writeAll(",");
        try w.print(
            \\{{"kind":"{t}","name":{f},"origin":"{t}","ours":{}
        , .{ item.kind, std.json.fmt(item.name, .{}), item.origin, item.ours });
        if (item.enabled) |e| try w.print(",\"enabled\":{}", .{e});
        if (item.project) |p| try w.print(",\"project\":{f}", .{std.json.fmt(p, .{})});
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

// -- tests -------------------------------------------------------------

const testing = std.testing;

/// Build a fixture home under a temp directory and return an absolute path
/// to it. Writing here is the test's, not the module's.
const Fixture = struct {
    home: []u8,
    io: std.Io,

    fn init(alloc: Allocator, io: std.Io) !Fixture {
        var raw: [6]u8 = undefined;
        io.random(&raw);
        const home = try std.fmt.allocPrint(alloc, "/tmp/polter-inventory-{x}", .{&raw});
        try std.Io.Dir.cwd().createDirPath(io, home);
        return .{ .home = home, .io = io };
    }

    fn deinit(self: *Fixture, alloc: Allocator) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.home) catch {};
        alloc.free(self.home);
    }

    fn write(self: *Fixture, alloc: Allocator, rel: []const u8, bytes: []const u8) !void {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ self.home, rel });
        defer alloc.free(path);
        if (std.fs.path.dirname(path)) |d| {
            try std.Io.Dir.cwd().createDirPath(self.io, d);
        }
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes });
    }

    fn mkdirs(self: *Fixture, alloc: Allocator, rel: []const u8) !void {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ self.home, rel });
        defer alloc.free(path);
        try std.Io.Dir.cwd().createDirPath(self.io, path);
    }

    fn find(report: Report, host: Host) HostReport {
        for (report.hosts) |h| if (h.host == host) return h;
        unreachable;
    }
};

fn names(sec: Section, alloc: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (sec.items) |i| try out.append(alloc, i.name);
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

test "inventory: an empty home is absent everywhere, and absent is not failed" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fix: Fixture = try .init(testing.allocator, io);
    defer fix.deinit(testing.allocator);

    var report = try scan(testing.allocator, io, .{ .home = fix.home });
    defer report.deinit();

    for (report.hosts) |h| {
        try testing.expect(h.mcp.status != .failed);
        try testing.expect(h.skills.status != .failed);
        try testing.expect(h.plugins.status != .failed);
    }

    // Kimi's MCP location is the unconfirmed one, and it must not be
    // reported as "nothing installed".
    try testing.expectEqual(Status.unknown_location, Fixture.find(report, .kimi).mcp.status);
    try testing.expectEqual(Status.absent, Fixture.find(report, .claude_code).mcp.status);
    try testing.expectEqual(
        Status.unknown_location,
        Fixture.find(report, .opencode).skills.status,
    );
}

test "inventory: reads each host's own spelling of the key" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fix: Fixture = try .init(testing.allocator, io);
    defer fix.deinit(testing.allocator);

    try fix.write(testing.allocator, ".claude.json",
        \\{"mcpServers":{"argus":{"command":"x","env":{"TOKEN":"s3cret"}},"polter":{}}}
    );
    // TOML, underscore, table headers -- and a sub-table that is not a
    // server of its own.
    try fix.write(testing.allocator, ".codex/config.toml",
        \\[mcp_servers.pencil]
        \\command = "x"
        \\[mcp_servers.serena]
        \\command = "y"
        \\[mcp_servers.serena.env]
        \\KEY = "s3cret"
    );
    // Nested under `mcp`, not `mcpServers`.
    try fix.write(testing.allocator, ".config/opencode/opencode.json",
        \\{"mcp":{"vision":{},"pencil":{}}}
    );

    var report = try scan(testing.allocator, io, .{ .home = fix.home });
    defer report.deinit();

    const claude = Fixture.find(report, .claude_code).mcp;
    try testing.expectEqual(Status.read, claude.status);
    const claude_names = try names(claude, testing.allocator);
    defer testing.allocator.free(claude_names);
    try testing.expectEqual(@as(usize, 2), claude_names.len);
    try testing.expectEqualStrings("argus", claude_names[0]);
    try testing.expectEqualStrings("polter", claude_names[1]);

    // Polter's own entry is marked as such.
    for (claude.items) |i| {
        if (std.mem.eql(u8, i.name, "polter")) try testing.expect(i.ours);
        if (std.mem.eql(u8, i.name, "argus")) try testing.expect(!i.ours);
    }

    const codex = Fixture.find(report, .codex).mcp;
    try testing.expectEqual(Status.read, codex.status);
    const codex_names = try names(codex, testing.allocator);
    defer testing.allocator.free(codex_names);
    try testing.expectEqual(@as(usize, 2), codex_names.len);
    try testing.expectEqualStrings("pencil", codex_names[0]);
    try testing.expectEqualStrings("serena", codex_names[1]);

    const oc = Fixture.find(report, .opencode).mcp;
    try testing.expectEqual(Status.read, oc.status);
    try testing.expectEqual(@as(usize, 2), oc.items.len);
}

test "inventory: no secret from an env block reaches the report" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fix: Fixture = try .init(testing.allocator, io);
    defer fix.deinit(testing.allocator);

    try fix.write(testing.allocator, ".claude.json",
        \\{"mcpServers":{"argus":{"command":"x","env":{"API_KEY":"sk-do-not-leak"}}}}
    );
    try fix.write(testing.allocator, ".codex/config.toml",
        \\[mcp_servers.serena]
        \\command = "y"
        \\[mcp_servers.serena.env]
        \\API_KEY = "sk-do-not-leak"
    );

    var report = try scan(testing.allocator, io, .{ .home = fix.home });
    defer report.deinit();

    // The floor: assert against the serialized bytes, because that is what
    // actually leaves this process. An assertion on the struct would pass
    // for a serializer that went and read the file again.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeJson(report, &out.writer);

    try testing.expect(std.mem.indexOf(u8, out.written(), "sk-do-not-leak") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "API_KEY") == null);
    // The control: the names we *do* mean to carry are in there, so this
    // is not passing because the report came out empty.
    try testing.expect(std.mem.indexOf(u8, out.written(), "argus") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "serena") != null);
}

test "inventory: a file that is there and unreadable is failed, not absent" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fix: Fixture = try .init(testing.allocator, io);
    defer fix.deinit(testing.allocator);

    try fix.write(testing.allocator, ".gemini/settings.json", "{ this is not json");

    var report = try scan(testing.allocator, io, .{ .home = fix.home });
    defer report.deinit();

    const g = Fixture.find(report, .gemini).mcp;
    try testing.expectEqual(Status.failed, g.status);
    try testing.expect(g.detail != null);
    try testing.expect(g.path != null);
}

test "inventory: an inline table is failed rather than silently empty" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fix: Fixture = try .init(testing.allocator, io);
    defer fix.deinit(testing.allocator);

    // The form the line scanner cannot read. It must say so.
    try fix.write(testing.allocator, ".codex/config.toml",
        \\mcp_servers = { pencil = { command = "x" } }
    );

    var report = try scan(testing.allocator, io, .{ .home = fix.home });
    defer report.deinit();

    const c = Fixture.find(report, .codex).mcp;
    try testing.expectEqual(Status.failed, c.status);

    // The control for that assertion: a file with no mention of the key at
    // all is `read` with nothing in it, so `failed` above is the scanner
    // noticing the key, not it failing on every file.
    var fix2: Fixture = try .init(testing.allocator, io);
    defer fix2.deinit(testing.allocator);
    try fix2.write(testing.allocator, ".codex/config.toml", "[features]\nweb = true\n");

    var report2 = try scan(testing.allocator, io, .{ .home = fix2.home });
    defer report2.deinit();
    const c2 = Fixture.find(report2, .codex).mcp;
    try testing.expectEqual(Status.read, c2.status);
    try testing.expectEqual(@as(usize, 0), c2.items.len);
}

test "inventory: skills are the directories, files beside them are not" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fix: Fixture = try .init(testing.allocator, io);
    defer fix.deinit(testing.allocator);

    try fix.mkdirs(testing.allocator, ".claude/skills/alpha");
    try fix.mkdirs(testing.allocator, ".claude/skills/beta");
    try fix.write(testing.allocator, ".claude/skills/README.md", "not a skill");

    var report = try scan(testing.allocator, io, .{ .home = fix.home });
    defer report.deinit();

    const s = Fixture.find(report, .claude_code).skills;
    try testing.expectEqual(Status.read, s.status);
    const got = try names(s, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("alpha", got[0]);
    try testing.expectEqualStrings("beta", got[1]);
}

test "inventory: a plugin the user switched off is not the same as one they did not" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fix: Fixture = try .init(testing.allocator, io);
    defer fix.deinit(testing.allocator);

    try fix.write(testing.allocator, ".claude/plugins/installed_plugins.json",
        \\{"version":2,"plugins":{"on@market":[{"version":"1"}],
        \\"off@market":[{"version":"1"}],"unsaid@market":[{"version":"1"}]}}
    );
    try fix.write(testing.allocator, ".claude/settings.json",
        \\{"enabledPlugins":{"on@market":true,"off@market":false}}
    );

    var report = try scan(testing.allocator, io, .{ .home = fix.home });
    defer report.deinit();

    const p = Fixture.find(report, .claude_code).plugins;
    try testing.expectEqual(Status.read, p.status);
    try testing.expectEqual(@as(usize, 3), p.items.len);

    for (p.items) |i| {
        if (std.mem.eql(u8, i.name, "on@market")) {
            try testing.expectEqual(@as(?bool, true), i.enabled);
        } else if (std.mem.eql(u8, i.name, "off@market")) {
            try testing.expectEqual(@as(?bool, false), i.enabled);
        } else {
            // Not in the settings file at all. `null`, and **not** false:
            // the host's default applies, and pretending we know which it
            // is would be an inference formatted as a reading.
            try testing.expectEqual(@as(?bool, null), i.enabled);
        }
    }
}

test "inventory: project-scoped servers are reported as such, and only when asked" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fix: Fixture = try .init(testing.allocator, io);
    defer fix.deinit(testing.allocator);

    try fix.write(testing.allocator, ".claude.json",
        \\{"mcpServers":{"global":{}},
        \\"projects":{"/work/a":{"mcpServers":{"only-in-a":{}}},
        \\"/work/b":{"mcpServers":{"only-in-b":{}}}}}
    );

    {
        var report = try scan(testing.allocator, io, .{ .home = fix.home });
        defer report.deinit();
        const m = Fixture.find(report, .claude_code).mcp;
        try testing.expectEqual(@as(usize, 1), m.items.len);
        try testing.expectEqualStrings("global", m.items[0].name);
    }

    {
        var report = try scan(testing.allocator, io, .{
            .home = fix.home,
            .project = "/work/a",
        });
        defer report.deinit();
        const m = Fixture.find(report, .claude_code).mcp;
        const got = try names(m, testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(usize, 2), got.len);
        try testing.expectEqualStrings("global", got[0]);
        try testing.expectEqualStrings("only-in-a", got[1]);

        for (m.items) |i| {
            if (std.mem.eql(u8, i.name, "only-in-a")) {
                try testing.expectEqual(Origin.project, i.origin);
                try testing.expectEqualStrings("/work/a", i.project.?);
            } else {
                try testing.expectEqual(Origin.user, i.origin);
            }
        }
    }
}

test "inventory: PATH decides on_path, and a missing PATH is not an answer" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fix: Fixture = try .init(testing.allocator, io);
    defer fix.deinit(testing.allocator);

    // A file named like a host binary, in a directory we will put on the
    // fake PATH.
    try fix.mkdirs(testing.allocator, "bin");
    try fix.write(testing.allocator, "bin/claude", "#!/bin/sh\n");

    const bin = try std.fmt.allocPrint(
        testing.allocator,
        "{s}{c}bin",
        .{ fix.home, std.fs.path.sep },
    );
    defer testing.allocator.free(bin);

    var report = try scan(testing.allocator, io, .{ .home = fix.home, .path_env = bin });
    defer report.deinit();

    try testing.expect(Fixture.find(report, .claude_code).on_path);
    try testing.expect(!Fixture.find(report, .codex).on_path);
}

test "inventory: the four states survive serialization" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fix: Fixture = try .init(testing.allocator, io);
    defer fix.deinit(testing.allocator);

    try fix.write(testing.allocator, ".gemini/settings.json", "{ not json");
    try fix.write(testing.allocator, ".claude.json", "{\"mcpServers\":{\"a\":{}}}");

    var report = try scan(testing.allocator, io, .{ .home = fix.home });
    defer report.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeJson(report, &out.writer);

    const s = out.written();
    // All four spellings appear, so a consumer cannot have been handed a
    // boolean in place of the distinction.
    try testing.expect(std.mem.indexOf(u8, s, "\"status\":\"failed\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"status\":\"read\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"status\":\"absent\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"status\":\"unknown_location\"") != null);

    // And it is parseable JSON, which the hand-rolled writer above is
    // exactly the sort of thing to get wrong.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, s, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 7), parsed.value.object.get("hosts").?.array.items.len);
}

test "inventory: the slot budget is the biggest host, not every host added up" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fix: Fixture = try .init(testing.allocator, io);
    defer fix.deinit(testing.allocator);

    // Four slots under Claude Code, two under Codex, plus ordinary
    // entries that are not slots at all.
    try fix.write(testing.allocator, ".claude.json",
        \\{"mcpServers":{"polter":{},"polter:argus":{},"polter:kanban":{},
        \\"polter:tinia":{},"polter:pencil":{},"chrome_devtools":{}}}
    );
    try fix.write(testing.allocator, ".codex/config.toml",
        \\[mcp_servers.polter]
        \\[mcp_servers."polter:argus"]
        \\[mcp_servers."polter:kanban"]
        \\[mcp_servers.serena]
    );

    var report = try scan(testing.allocator, io, .{ .home = fix.home });
    defer report.deinit();

    try testing.expectEqual(@as(usize, 4), Fixture.find(report, .claude_code).slots);
    try testing.expectEqual(@as(usize, 2), Fixture.find(report, .codex).slots);

    // `polter` itself is not a slot: it is Polter's own tool surface, and
    // counting it would add one connection per host that does not exist.
    try testing.expect(Fixture.find(report, .claude_code).mcp.items.len == 6);

    const budget = report.slotBudget();
    // 4, not 6. A terminal runs one agent CLI, so it starts one host's
    // slots -- see `slotBudget` for why the sum would overstate it.
    try testing.expectEqual(@as(usize, 4), budget.max);
    try testing.expect(budget.complete);
}

test "inventory: a host that is installed and unreadable makes the budget a floor" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fix: Fixture = try .init(testing.allocator, io);
    defer fix.deinit(testing.allocator);

    try fix.write(testing.allocator, ".claude.json",
        \\{"mcpServers":{"polter:argus":{}}}
    );
    // Present, installed, and unparseable.
    try fix.write(testing.allocator, ".gemini/settings.json", "{ not json");

    try fix.mkdirs(testing.allocator, "bin");
    try fix.write(testing.allocator, "bin/gemini", "#!/bin/sh\n");
    const bin = try std.fmt.allocPrint(
        testing.allocator,
        "{s}{c}bin",
        .{ fix.home, std.fs.path.sep },
    );
    defer testing.allocator.free(bin);

    {
        var report = try scan(testing.allocator, io, .{
            .home = fix.home,
            .path_env = bin,
        });
        defer report.deinit();
        const budget = report.slotBudget();
        try testing.expectEqual(@as(usize, 1), budget.max);
        // Gemini is on PATH and its config could not be read, so nobody
        // knows how many slots it has. `max` is a floor.
        try testing.expect(!budget.complete);
    }

    {
        // The control. Same unreadable file, but the binary is not on this
        // PATH -- a host that is not installed cannot be running slots, so
        // the same failure no longer makes the answer incomplete. Without
        // this cell, `complete == false` above would also be produced by a
        // rule that simply never returns true.
        var report = try scan(testing.allocator, io, .{ .home = fix.home });
        defer report.deinit();
        try testing.expect(report.slotBudget().complete);
    }
}
