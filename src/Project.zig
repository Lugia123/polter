//! A project: a set of tabs together with the windows they sit in. Each tab
//! is a split tree; each pane of it has its directory and title, which
//! command-history file (see `CommandHistory.zig`) is its own, and who was
//! working in it -- so that opening the project again rebuilds every window
//! and every tab, and gives each pane back what it had.
//!
//! **This is not `poltergeist/Session.zig`.** Session.zig is material for a
//! restart: it is written continuously, its groups come back from disk with
//! nobody in them on purpose, and deciding which terminal on screen now is
//! which one from last night is left to a person. None of that applies
//! here. Loading a project is not a guess about which pane is which --
//! there is no ambiguity to leave to a person, because the whole tree is
//! the record. The two files read similarly (tolerant of the state
//! directory not existing yet) because that shape has already been proven
//! out in this codebase, not because they are the same kind of file.
//!
//! **Reading is strict, on purpose, which is the other way this deviates
//! from Session.zig.** Session.zig treats a corrupt file as no different
//! from a missing one, because it is background material nobody asked for
//! by name. A project is the opposite: the user picked it by name and is
//! about to act on what comes back. Handing back half a tree -- the left
//! child of a split with no right child, because the file happened to be
//! cut off in a syntactically-still-valid place -- would rebuild a tab that
//! silently drops a pane the user had open. So `read` returns a named error
//! instead: `error.NotFound` when there is no such project, `error.Corrupt`
//! when the file exists but couldn't be read whole, `error.TooNew` when a
//! later build wrote it. Nothing in between.
//!
//! ## The file
//!
//! Three implementations read and write it -- this one,
//! `windows/projectfile/src/lib.rs` and
//! `macos/Sources/Features/Projects/ProjectDocument.swift` -- and what they
//! write is **the same bytes**, which `test/project-format/` holds them to:
//! this file makes the bytes there from values written out in its tests,
//! and the other two only read them and compare (`test/project-format/README.md`).
//!
//! A file is one of two formats.
//!
//! **Format 1** (no `format` key) is what was written while a project was
//! one tab: `name`, `saved_at`, `root` (that tab's tree), `next_scrollback`.
//! It is read as a project of one window with one tab, the window's frame
//! not recorded and every pane's occupant not known. It is never written.
//!
//! **Format 2** is what is written, always, in this order and with no
//! space anywhere:
//!
//!     {"format":2,"name":S,"saved_at":I,"root":{"kind":"moved-to-windows"},
//!      "group":S,"next_scrollback":I,"windows":[WINDOW,...]}
//!     WINDOW  {"frame":{"origin":"top_left"|"bottom_left","x":N,"y":N,
//!              "width":N,"height":N},"front":I,"tabs":[{"root":NODE},...]}
//!     NODE    {"kind":"split","direction":"horizontal"|"vertical","ratio":N,
//!              "left":NODE,"right":NODE}
//!           | LEAF
//!           | {"kind":"stack","shown":I,"members":[LEAF,LEAF,...]}
//!     LEAF    {"kind":"leaf","cwd":S,"title":S,"history":S,"scrollback":S,
//!              "by_supervisor":true,"agent":AGENT}
//!     AGENT   {"kind":"unknown"} | {"kind":"none"}
//!           | {"kind":"agent","role":S,"cli":S,"session":S,"supervisor":B}
//!
//! `group`, `next_scrollback` and `frame` are left out when there is none;
//! so is any string of a leaf or an agent that is empty, and `by_supervisor`
//! when it is not true. Everything else is
//! always there, and a format 2 file without it is `Corrupt`.
//!
//!   - A string is its UTF-8 bytes between quotes, with `"` and `\` each
//!     behind a backslash and every byte below 0x20 as `\u00xx` in lower
//!     case. Nothing else is escaped: not `/`, not U+007F, not anything
//!     past ASCII.
//!   - `I` is a whole number in decimal.
//!   - `N` is the shortest decimal that reads back as the same double,
//!     written out in full and never with an exponent; a whole value has no
//!     point (`1`, not `1.0`). A value that is not finite cannot be written:
//!     the write fails.
//!
//! A `stack` is several terminals in one pane. Its members are leaves and
//! nothing else, there are at least two of them, and `shown` is the index
//! of the one in front; a stack that is not that -- one member, a split
//! among them, `shown` past the end -- is `Corrupt`, in what is read and
//! in what is asked to be written alike. It is not put right: any way of
//! putting it right is deciding which terminal a person no longer has.
//!
//! **Once a build that writes format 2 has been released, a new kind of
//! node means a new format number.** `stack` and `by_supervisor` were both
//! added to format 2 without one, and that was sound only because no
//! release had format 2 in it (measured when `stack` went in: no tag held
//! the commit that brought format 2; the newest release read format 1
//! only). A released build that meets a kind it does not know says
//! "corrupt", which is the wrong word for "newer than me" -- `TooNew`
//! exists so that it can say the right one, and it can only say it when
//! the number went up.
//!
//! `root` is in a format 2 file only so that a build from before windows
//! refuses it: such a build reads `name`, `saved_at` and `root` and nothing
//! else, and without this it would open a project of several tabs as one
//! with no panes and save that over it. All three of those builds answer a
//! node of a kind they do not know with "corrupt". This build never reads it.
//!
//! **What a read puts right, and says nothing more about.** A `scrollback`
//! that is not a name this format writes reads as none. So does one an
//! earlier pane of the file already has (windows in order, tabs in order,
//! left before right): two panes writing one snapshot is the thing the
//! numbering exists to prevent. And a project has at most one supervisor:
//! **a file in which two or more panes say they are it reads with none of
//! them being it** -- which of them it was cannot be told from the file, and
//! whoever opens a project starts its supervisor without asking.
const Project = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.project);

/// How a split arranges its two children.
///
/// The trap, inherited by every port of this shape so far (see
/// `macos/Sources/Features/Splits/SplitTree.swift` and
/// `windows/split-tree/src/lib.rs`): `horizontal` means the children sit
/// side by side, so the *divider* between them is a vertical line.
/// `vertical` means one above the other. The name describes the
/// arrangement, not the divider.
pub const Direction = enum {
    horizontal,
    vertical,
};

/// A pane: one leaf of the tree.
pub const Leaf = struct {
    /// Where the pane was working.
    cwd: []const u8,

    /// What the pane's tab/title said.
    title: []const u8,

    /// An opaque handle to this pane's history, or empty if it never ran a
    /// command that got captured. What it means is shell-dependent, which
    /// is why this is not called `history_file`:
    ///
    ///   - For shells whose history a Ghostty-owned file can drive (bash,
    ///     zsh), it's a filename under `CommandHistory.defaultDir` -- a
    ///     sibling of the projects directory, not inside it, because a
    ///     pane's history outlives any one project it gets saved into.
    ///   - For fish, it's a *session name*: fish keys its own history
    ///     store by the `fish_history` variable, which has to be set in
    ///     the environment before fish starts, and there is no file Ghostty
    ///     can hand it after the fact. Restoring a fish pane means spawning
    ///     it with `fish_history` set to this value, not pointing it at a
    ///     path.
    ///
    /// Never assume it's a path you can open directly -- check the pane's
    /// shell first.
    history: []const u8,

    /// This pane's scrollback snapshot, as a name relative to the project
    /// file's snapshot directory: `<ASCII digits>.snap`, or empty for none.
    /// Never a path. The directory is derived by whoever reads the file,
    /// from the file's own path (`<file without its extension>.scrollback/`),
    /// never by sanitizing the project name again -- the three
    /// implementations sanitize names differently (issue #23).
    ///
    /// The number belongs to the pane for its whole life, not to its place
    /// in the tree: swapping two panes must not swap their histories.
    ///
    /// Only a name `isScrollbackName` accepts is read; anything else reads
    /// as empty. The core deletes a snapshot it cannot decode, so this one
    /// field makes a project file a list of files the core may delete, and
    /// `../../elsewhere/keep.snap` passes the core's own `.snap` check.
    scrollback: []const u8,

    /// Whether the project's supervisor opened this pane -- a worker's
    /// pane, in the supervisor's own tab or one it opened.
    ///
    /// **On the pane and not in `agent`**: the agent leaves and the pane is
    /// then nobody's, and it is still a pane the supervisor opened, which
    /// is what lets the supervisor use it again rather than open another.
    /// A project has one group and one supervisor, so which supervisor
    /// need not be said. `false` is also what a pane reads as when nothing
    /// recorded it: the two are not told apart, because both mean "not one
    /// the supervisor may take for its own".
    by_supervisor: bool,

    /// Who was working in this pane.
    agent: Agent,
};

/// Who was working in a pane when the project was saved.
///
/// **Nobody and not known are two answers, and neither is a default.** A
/// pane a person ran a shell in has `none`; a pane out of a format 1 file,
/// or one whose host could not tell, has `unknown`. Reading the first as the
/// second would bring a worker's pane back as a plain shell without a word,
/// and reading the second as the first would say of a plain shell that
/// nobody can say what it was.
pub const Agent = union(enum) {
    /// Nothing recorded who, if anybody, was here.
    unknown,
    /// Nobody: a pane with no agent in it.
    none,
    agent: Who,
};

/// The agent in a pane. `role`, `cli` and `session` are the words
/// `poltergeist/Chat.zig`'s `LastSupervisor` keeps under the same names in
/// a group's own file, and mean what they mean there: each is empty when
/// the agent had none or nobody could tell which.
pub const Who = struct {
    /// The key of the role it wore.
    role: []const u8,
    /// The key of its agent CLI (`agent_cli.Adapter.key`).
    cli: []const u8,
    /// The session its CLI said it was in, as the CLI wrote it.
    session: []const u8,
    /// Whether it is the supervisor of the project's group. At most one
    /// pane of a project is, and `parse` never hands back two (see the
    /// module comment).
    supervisor: bool,
};

/// Whether `name` is a snapshot name this format writes: 1 to 20 ASCII
/// digits, then `.snap`, and nothing else -- so no separator, drive or `..`
/// can get through. The same rule as `is_scrollback_name` in
/// `windows/host/src/project.rs` and `ProjectScrollback.isSnapshotFilename`
/// on macOS.
pub fn isScrollbackName(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".snap")) return false;
    const digits = name[0 .. name.len - ".snap".len];
    if (digits.len == 0 or digits.len > 20) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// A split: two children divided in some direction at some ratio.
pub const Split = struct {
    direction: Direction,

    /// Fraction of the space the left/top child gets, `0.0` to `1.0`.
    ratio: f64,

    left: *const Node,
    right: *const Node,
};

/// Several terminals in one pane: one showing, the others behind it, a row
/// of tabs over the pane to choose between them.
///
/// A stack takes the place of a pane, so its members are panes -- never a
/// split, never another stack -- and it has at least two: **one terminal in
/// a pane is a `leaf`, not a stack of one**, which keeps every project
/// without a stack the bytes it always was. Each member is a whole pane
/// with its own directory, history, snapshot and occupant; the order is the
/// order of the tabs.
pub const Stack = struct {
    /// The index, in `members`, of the one that is showing.
    shown: usize,
    members: []const Leaf,
};

/// One node in the layout tree: a pane, a pane that holds several
/// terminals, or a split of two more nodes.
pub const Node = union(enum) {
    leaf: Leaf,
    stack: Stack,
    split: Split,
};

/// One tab: a tree of panes.
pub const Tab = struct {
    root: *const Node,
};

/// Which corner of the screen a `Frame` is measured from. The hosts do not
/// agree -- AppKit measures up from the bottom left, Win32 down from the top
/// left -- and the same four numbers are two different places.
pub const Origin = enum {
    top_left,
    bottom_left,
};

/// Where a window was and how big, **as its host had it and nothing more**:
/// in that host's own units, from the corner `origin` names. The screen it
/// was on may not be there when the project is opened again, and bringing a
/// window back onto a screen that is belongs to whoever opens it -- this
/// only says where it was.
pub const Frame = struct {
    origin: Origin,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

/// One window: its tabs in the order they stood, and which was in front.
pub const Window = struct {
    /// Null when nothing recorded it, which is every window out of a
    /// format 1 file.
    frame: ?Frame,

    /// The index, in `tabs`, of the tab that was showing.
    front: usize,

    /// Never empty: a window with no tab is not a window.
    tabs: []const Tab,
};

/// The whole saved project.
pub const Snapshot = struct {
    /// The name the user gave it. Also what the file on disk is named
    /// after -- see `pathFor`.
    name: []const u8,

    /// When it was saved, Unix seconds.
    saved_at: i64,

    /// The group this project is the project of, or null for a project
    /// with no group. A project has at most one.
    group: ?[]const u8,

    /// The windows, in an order that stays the same from one save to the
    /// next -- not the order they are stacked in on screen, which would
    /// reorder the file every time a person clicked on another window.
    /// Empty for a project
    /// with nothing in it (a format 1 file with no `root`): that is not a
    /// corrupt file, so it round-trips rather than erroring.
    windows: []const Window,

    /// The next scrollback snapshot number this project will hand out
    /// (`next_scrollback` on the wire), or null in a file written before
    /// snapshots existed. **One counter for the whole project**, whatever
    /// window or tab a pane is in: every snapshot of a project is in one
    /// directory, so two tabs each counting from zero would write one file.
    /// Only ever grows, so a number that belonged to a
    /// pane since closed is never handed to a new one -- which would open
    /// the new pane with the old one's history.
    ///
    /// Read and written back even though nothing here allocates: a writer
    /// that dropped a counter it did not use would reset it for the
    /// implementations that do. Anything but a non-negative integer reads
    /// as null, the same as `windows/host/src/project.rs` (`as_u64`).
    next_scrollback: ?u64,

    /// The tree of the first window's first tab, or null for a project
    /// with nothing in it. What a caller that still thinks of a project as
    /// one tab has to go on.
    pub fn firstTab(self: Snapshot) ?*const Node {
        if (self.windows.len == 0) return null;
        return self.windows[0].tabs[0].root;
    }
};

// **No field of the file's shape may have a default.** This format has
// three implementations -- this file, `windows/projectfile/src/lib.rs`, and
// `macos/Sources/Features/Projects/ProjectDocument.swift` -- and nothing
// compiles all three. A field added here with `= ""` compiles everywhere
// it is not mentioned, `parseNode` included, so the reader could silently
// never fill it. Without a default, every place that builds one of these
// is a compile error naming the field until it says what goes there.
//
// What this cannot see is the other two implementations: the files under
// `test/project-format/` do that. They are made here, from values the
// tests below spell out, and the other two read each one and have to write
// the same bytes back.
comptime {
    for (.{ Leaf, Who, Stack, Split, Tab, Frame, Window, Snapshot }) |T| {
        for (std.meta.fields(T)) |f| {
            if (f.default_value_ptr != null) @compileError(
                @typeName(T) ++ "." ++ f.name ++
                    " has a default value; fields of the project file may not" ++
                    " (see the comment above this check in src/Project.zig)",
            );
        }
    }
}

/// One entry from `list`: enough to show a picker without reading every
/// file whole.
pub const Entry = struct {
    name: []const u8,
    saved_at: i64,
};

pub const ReadError = error{
    /// No project by this name exists.
    NotFound,

    /// A project by this name exists but the file could not be read as a
    /// complete, well-formed project. Covers JSON that won't parse at all
    /// (e.g. truncated mid-token) and JSON that parses but is missing a
    /// field a complete project must have (e.g. a split with no `right`) --
    /// both are the same promise to the caller: never a half a tree.
    Corrupt,

    /// The file says it is of a format later than `format_version`: a
    /// build newer than this one wrote it. **Not `Corrupt`, and never read
    /// as format 1**: the file is whole, and what this build would make of
    /// it -- the keys it happens to know, the rest dropped -- is a project
    /// with panes missing that the next save would put on disk.
    TooNew,

    /// `name` sanitizes to nothing a file can be named -- see
    /// `sanitizeFilename`. Reading (or writing, or renaming to) a name
    /// like that can never have succeeded, so this is not a variant of
    /// `NotFound`.
    InvalidName,
} || Allocator.Error;

/// Where projects live, given the state directory Ghostty's xdg helper
/// (`src/os/xdg.zig`'s `state`) returns for the `polter` subdir -- the
/// same root `poltergeist/Session.zig` and friends use. `projects` is a
/// sibling of what lives directly there (`session.json`, `chat/`, ...),
/// not nested inside any of it: a project is a terminal feature, not a
/// Poltergeist one, and has to work with Poltergeist entirely absent.
pub fn defaultDir(alloc: Allocator, state_dir: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(alloc, &.{ state_dir, "projects" });
}

/// The path a project with this name is stored at, under `dir`
/// (`defaultDir`'s return value). Caller owns the returned path.
///
/// The name is sanitized into a filename by the rule in `sanitizeFilename`
/// (the same rule as macOS and Windows, pinned by one table they all run).
/// Two names
/// that sanitize to the same filename collide -- last write wins -- which
/// is an accepted rough edge for a first version, the same trade Session.zig
/// makes elsewhere in this codebase for the sake of not needing a second,
/// stable identifier the user never sees. The `name` field inside the file
/// is what's authoritative for display either way.
///
/// `error.InvalidName` for an empty name, the only name nothing survives
/// sanitizing: every other scalar or byte becomes itself or `_`. This used to
/// fall back to a fixed filename instead, which was worse in two ways at
/// once: `list` filters by `.json` and the fallback didn't have that
/// suffix, so a project saved under it was unfindable forever; and even
/// fixing the suffix would only have moved the bug, since that fallback
/// name collides with any project a user names "project" literally --
/// except this collision silently overwrites the whole file, `name` field
/// included, which is not the accepted rough edge above, because that one
/// only ever happens between two names a user actually chose.
pub fn pathFor(alloc: Allocator, dir: []const u8, name: []const u8) (error{InvalidName} || Allocator.Error)![]const u8 {
    const filename = try sanitizeFilename(alloc, name);
    defer alloc.free(filename);
    return std.fs.path.join(alloc, &.{ dir, filename });
}

/// Past this many UTF-8 bytes (the `.json` not counted) a name is cut.
const max_filename_len = 200;

/// Where the rule lives, relative to the repository root. Read by the test
/// "every row of the shared filename table", as are the macOS and Windows
/// implementations' tests (issue #838).
const filename_table_path = "test/fixtures/project-filenames.tsv";

/// The rule that turns a project name into a filename. It is written three
/// times -- here, `sanitize_filename` in `windows/projectname/src/lib.rs`, and
/// `macos/Sources/Features/Projects/ProjectFilename.swift` -- and the three
/// disagreed for most of their lives without anything noticing (issue #23),
/// so the rule is pinned by `test/fixtures/project-filenames.tsv`, which all
/// three run row by row.
///
///   - Walk the name by Unicode scalar. No normalization: NFC and NFD
///     spellings of one name are two filenames.
///   - **Not by grapheme cluster.** The three standard libraries carry
///     different Unicode versions, so a grapheme cut cannot be guaranteed to
///     agree between them. A scalar is the same scalar in all three.
///   - Replace with `_`: every scalar up to U+001F, U+007F, `/`, `\`, and the
///     seven NTFS refuses in a filename, `: * ? " < > |`. (`:` is the one
///     that matters most: NTFS takes `a:b.json` without an error and writes an
///     alternate data stream of a file called `a`.)
///   - Stop before the scalar that would take the result past
///     `max_filename_len` UTF-8 bytes, never inside it -- cutting mid-scalar
///     leaves bytes that are not UTF-8, which APFS refuses as a filename.
///   - Nothing left (only an empty name) is `error.InvalidName`.
///   - Append `.json`.
///
/// **Bytes that are not UTF-8 each become `_`.** Only this implementation
/// needs this rule, because only it can be handed such input: the name is a
/// byte slice here, and a string in Swift and Rust cannot hold invalid
/// UTF-8. It is the same replacement the rule already makes, extended, so
/// the rule stays a total function from bytes to a filename -- a failure
/// path only Zig could reach would be exactly the kind of one-sided
/// behaviour issue #23 was about. Pinned by this file's own test, not the
/// shared table, whose inputs are UTF-8 by construction.
fn sanitizeFilename(alloc: Allocator, name: []const u8) (error{InvalidName} || Allocator.Error)![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    var i: usize = 0;
    while (i < name.len) {
        // One step is one scalar, or one byte that does not start one.
        const scalar: ?[]const u8 = scalar: {
            const len = std.unicode.utf8ByteSequenceLength(name[i]) catch break :scalar null;
            if (i + len > name.len) break :scalar null;
            _ = std.unicode.utf8Decode(name[i..][0..len]) catch break :scalar null;
            break :scalar name[i..][0..len];
        };
        const step = if (scalar) |sc| sc.len else 1;
        const out: []const u8 = if (scalar) |sc|
            if (sc.len == 1 and replaced(sc[0])) "_" else sc
        else
            "_";

        if (buf.items.len + out.len > max_filename_len) break;
        try buf.appendSlice(alloc, out);
        i += step;
    }

    if (buf.items.len == 0) {
        return error.InvalidName;
    }

    try buf.appendSlice(alloc, ".json");
    return buf.toOwnedSlice(alloc);
}

/// The single-byte scalars the rule replaces with `_`. Every one of them is
/// ASCII, so a multi-byte scalar is never replaced.
fn replaced(c: u8) bool {
    return switch (c) {
        0...0x1f, 0x7f, '/', '\\', ':', '*', '?', '"', '<', '>', '|' => true,
        else => false,
    };
}

/// The format this build writes, and the latest it reads.
pub const format_version: u32 = 2;

/// Write the snapshot, replacing whatever project of this name was there.
///
/// Written whole and atomically: a half-written project file would be
/// exactly the "half a tree" this whole module exists to never hand back.
pub fn write(
    alloc: Allocator,
    io: std.Io,
    dir: []const u8,
    snapshot: Snapshot,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    try emit(&buf.writer, snapshot);

    const path = try pathFor(alloc, dir, snapshot.name);
    defer alloc.free(path);
    const filename = std.fs.path.basename(path);

    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);

    var atomic = try d.createFileAtomic(io, filename, .{
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
        .replace = true,
    });
    defer atomic.deinit(io);

    try atomic.file.writeStreamingAll(io, buf.written());
    try atomic.replace(io);
}

pub const EmitError = std.Io.Writer.Error || error{
    /// A ratio or a frame holds a value that is not a finite number, which
    /// the file has no way to say.
    NotFinite,
    /// A stack with fewer than two members, or whose `shown` is none of
    /// them. Refused rather than written as something else: one member is
    /// a `leaf`, and it is whoever built the tree that knows which.
    BadStack,
};

/// The bytes of `snapshot` as a format 2 file. **Written by hand rather than
/// through `std.json`**, because the three implementations have to write the
/// same bytes and three JSON libraries do not: they order keys differently,
/// one escapes `/`, and each prints a double its own way. The rules are in
/// the module comment; every one of them is in this function and the four
/// below it.
pub fn emit(w: *std.Io.Writer, snapshot: Snapshot) EmitError!void {
    try w.print("{{\"format\":{d},\"name\":", .{format_version});
    try emitString(w, snapshot.name);
    try w.print(",\"saved_at\":{d}", .{snapshot.saved_at});
    try w.writeAll(",\"root\":{\"kind\":\"" ++ moved_kind ++ "\"}");
    if (snapshot.group) |group| if (group.len > 0) {
        try w.writeAll(",\"group\":");
        try emitString(w, group);
    };
    if (snapshot.next_scrollback) |n| try w.print(",\"next_scrollback\":{d}", .{n});
    try w.writeAll(",\"windows\":[");
    for (snapshot.windows, 0..) |window, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('{');
        if (window.frame) |frame| {
            try w.writeAll("\"frame\":{\"origin\":\"");
            try w.writeAll(@tagName(frame.origin));
            try w.writeAll("\",\"x\":");
            try emitNumber(w, frame.x);
            try w.writeAll(",\"y\":");
            try emitNumber(w, frame.y);
            try w.writeAll(",\"width\":");
            try emitNumber(w, frame.width);
            try w.writeAll(",\"height\":");
            try emitNumber(w, frame.height);
            try w.writeAll("},");
        }
        try w.print("\"front\":{d},\"tabs\":[", .{window.front});
        for (window.tabs, 0..) |tab, j| {
            if (j > 0) try w.writeByte(',');
            try w.writeAll("{\"root\":");
            try emitNode(w, tab.root.*);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
}

/// The kind of the node a format 2 file has under `root`, which no build
/// reads as a node -- see the module comment.
const moved_kind = "moved-to-windows";

fn emitNode(w: *std.Io.Writer, node: Node) EmitError!void {
    switch (node) {
        .leaf => |leaf| try emitLeaf(w, leaf),
        .stack => |stack| {
            if (stack.members.len < 2 or stack.shown >= stack.members.len) return error.BadStack;
            try w.print("{{\"kind\":\"stack\",\"shown\":{d},\"members\":[", .{stack.shown});
            for (stack.members, 0..) |member, i| {
                if (i > 0) try w.writeByte(',');
                try emitLeaf(w, member);
            }
            try w.writeAll("]}");
        },
        .split => |split| {
            try w.writeAll("{\"kind\":\"split\",\"direction\":\"");
            try w.writeAll(@tagName(split.direction));
            try w.writeAll("\",\"ratio\":");
            try emitNumber(w, split.ratio);
            try w.writeAll(",\"left\":");
            try emitNode(w, split.left.*);
            try w.writeAll(",\"right\":");
            try emitNode(w, split.right.*);
            try w.writeByte('}');
        },
    }
}

fn emitLeaf(w: *std.Io.Writer, leaf: Leaf) EmitError!void {
    try w.writeAll("{\"kind\":\"leaf\"");
    try emitField(w, "cwd", leaf.cwd);
    try emitField(w, "title", leaf.title);
    try emitField(w, "history", leaf.history);
    try emitField(w, "scrollback", leaf.scrollback);
    if (leaf.by_supervisor) try w.writeAll(",\"by_supervisor\":true");
    try w.writeAll(",\"agent\":{\"kind\":\"");
    try w.writeAll(@tagName(leaf.agent));
    try w.writeByte('"');
    switch (leaf.agent) {
        .unknown, .none => {},
        .agent => |who| {
            try emitField(w, "role", who.role);
            try emitField(w, "cli", who.cli);
            try emitField(w, "session", who.session);
            try w.writeAll(if (who.supervisor) ",\"supervisor\":true" else ",\"supervisor\":false");
        },
    }
    try w.writeAll("}}");
}

/// `,"key":"value"`, or nothing when the value is empty.
fn emitField(w: *std.Io.Writer, comptime key: []const u8, value: []const u8) EmitError!void {
    if (value.len == 0) return;
    try w.writeAll(",\"" ++ key ++ "\":");
    try emitString(w, value);
}

fn emitString(w: *std.Io.Writer, value: []const u8) EmitError!void {
    try w.writeByte('"');
    for (value) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn emitNumber(w: *std.Io.Writer, value: f64) EmitError!void {
    if (!std.math.isFinite(value)) return error.NotFinite;
    try w.print("{d}", .{value});
}

/// Read a project by name. Everything it borrows comes from `arena`.
pub fn read(arena: Allocator, io: std.Io, dir: []const u8, name: []const u8) ReadError!Snapshot {
    const path = try pathFor(arena, dir, name);

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };

    return parse(arena, bytes);
}

/// What a read keeps track of across the whole file, to put right the two
/// things the module comment says it puts right.
const Fixups = struct {
    /// Every snapshot name a pane read so far has.
    scrollback: std.StringHashMapUnmanaged(void) = .empty,
    /// Every pane that says it is the supervisor.
    supervisors: std.ArrayListUnmanaged(*Agent) = .empty,
};

/// The same, for bytes already in hand.
pub fn parse(arena: Allocator, bytes: []const u8) ReadError!Snapshot {
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        bytes,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };

    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.Corrupt,
    };

    // The format first, and before anything is made of the rest: a file
    // from a later build is refused whole, not read for the keys this
    // build happens to share with it.
    const format: u32 = if (obj.get("format")) |v| switch (v) {
        .integer => |n| format: {
            if (n < 1) return error.Corrupt;
            if (n > format_version) {
                log.warn(
                    "project file is format {d}; this build reads up to {d} -- a later build wrote it",
                    .{ n, format_version },
                );
                return error.TooNew;
            }
            break :format @intCast(n);
        },
        else => return error.Corrupt,
    } else 1;

    const name = switch (obj.get("name") orelse return error.Corrupt) {
        .string => |s| s,
        else => return error.Corrupt,
    };

    const saved_at: i64 = switch (obj.get("saved_at") orelse return error.Corrupt) {
        .integer => |n| n,
        else => return error.Corrupt,
    };

    const next_scrollback: ?u64 = if (obj.get("next_scrollback")) |v| switch (v) {
        .integer => |n| std.math.cast(u64, n),
        else => null,
    } else null;

    var fixups: Fixups = .{};

    const windows: []const Window = if (format == 1) one: {
        // One tab is one window with that tab in it; no `root` is a
        // project with nothing in it.
        const root = try parseNode(arena, obj.get("root") orelse break :one &.{}, format, &fixups);
        const tabs = try arena.alloc(Tab, 1);
        tabs[0] = .{ .root = root };
        const windows = try arena.alloc(Window, 1);
        windows[0] = .{ .frame = null, .front = 0, .tabs = tabs };
        break :one windows;
    } else try parseWindows(arena, obj.get("windows") orelse return error.Corrupt, format, &fixups);

    const group: ?[]const u8 = if (format == 1) null else if (obj.get("group")) |v| switch (v) {
        .string => |s| if (s.len > 0) s else null,
        else => return error.Corrupt,
    } else null;

    if (fixups.supervisors.items.len > 1) {
        log.warn(
            "project '{s}' has {d} panes that each say they are the supervisor; read as having none",
            .{ name, fixups.supervisors.items.len },
        );
        for (fixups.supervisors.items) |agent| agent.agent.supervisor = false;
    }

    return .{
        .name = name,
        .saved_at = saved_at,
        .group = group,
        .windows = windows,
        .next_scrollback = next_scrollback,
    };
}

fn parseWindows(arena: Allocator, value: std.json.Value, format: u32, fixups: *Fixups) ReadError![]const Window {
    const items = switch (value) {
        .array => |a| a.items,
        else => return error.Corrupt,
    };
    const windows = try arena.alloc(Window, items.len);
    for (items, windows) |item, *window| {
        const obj = switch (item) {
            .object => |o| o,
            else => return error.Corrupt,
        };

        const frame: ?Frame = if (obj.get("frame")) |v| frame: {
            const f = switch (v) {
                .object => |o| o,
                else => return error.Corrupt,
            };
            const origin = switch (f.get("origin") orelse return error.Corrupt) {
                .string => |s| std.meta.stringToEnum(Origin, s) orelse return error.Corrupt,
                else => return error.Corrupt,
            };
            break :frame .{
                .origin = origin,
                .x = try numberOf(f.get("x")),
                .y = try numberOf(f.get("y")),
                .width = try numberOf(f.get("width")),
                .height = try numberOf(f.get("height")),
            };
        } else null;

        const tab_items = switch (obj.get("tabs") orelse return error.Corrupt) {
            .array => |a| a.items,
            else => return error.Corrupt,
        };
        if (tab_items.len == 0) return error.Corrupt;
        const tabs = try arena.alloc(Tab, tab_items.len);
        for (tab_items, tabs) |tab_item, *tab| {
            const tab_obj = switch (tab_item) {
                .object => |o| o,
                else => return error.Corrupt,
            };
            tab.* = .{ .root = try parseNode(arena, tab_obj.get("root") orelse return error.Corrupt, format, fixups) };
        }

        const front: usize = switch (obj.get("front") orelse return error.Corrupt) {
            .integer => |n| std.math.cast(usize, n) orelse return error.Corrupt,
            else => return error.Corrupt,
        };
        if (front >= tabs.len) return error.Corrupt;

        window.* = .{ .frame = frame, .front = front, .tabs = tabs };
    }
    return windows;
}

fn numberOf(v: ?std.json.Value) ReadError!f64 {
    return switch (v orelse return error.Corrupt) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        // A whole number too big for an i64, which is how `std.json` hands
        // back the `1000000000000000000000` this format writes for 1e21.
        .number_string => |text| std.fmt.parseFloat(f64, text) catch error.Corrupt,
        else => error.Corrupt,
    };
}

fn parseNode(arena: Allocator, value: std.json.Value, format: u32, fixups: *Fixups) ReadError!*Node {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.Corrupt,
    };

    const kind = switch (obj.get("kind") orelse return error.Corrupt) {
        .string => |s| s,
        else => return error.Corrupt,
    };

    const node = try arena.create(Node);

    if (std.mem.eql(u8, kind, "leaf")) {
        node.* = .{ .leaf = try parseLeaf(arena, obj, format, fixups) };
        try noteSupervisor(arena, &node.leaf, fixups);
        return node;
    }

    if (std.mem.eql(u8, kind, "stack")) {
        // Format 1 has no such node. And nothing about a stack is put
        // right: see the module comment.
        if (format == 1) return error.Corrupt;
        const items = switch (obj.get("members") orelse return error.Corrupt) {
            .array => |a| a.items,
            else => return error.Corrupt,
        };
        if (items.len < 2) return error.Corrupt;
        const members = try arena.alloc(Leaf, items.len);
        for (items, members) |item, *member| {
            const m = switch (item) {
                .object => |o| o,
                else => return error.Corrupt,
            };
            // A pane and nothing else: not a split, not another stack.
            switch (m.get("kind") orelse return error.Corrupt) {
                .string => |k| if (!std.mem.eql(u8, k, "leaf")) return error.Corrupt,
                else => return error.Corrupt,
            }
            member.* = try parseLeaf(arena, m, format, fixups);
            try noteSupervisor(arena, member, fixups);
        }
        const shown: usize = switch (obj.get("shown") orelse return error.Corrupt) {
            .integer => |n| std.math.cast(usize, n) orelse return error.Corrupt,
            else => return error.Corrupt,
        };
        if (shown >= members.len) return error.Corrupt;
        node.* = .{ .stack = .{ .shown = shown, .members = members } };
        return node;
    }

    if (std.mem.eql(u8, kind, "split")) {
        const direction_str = switch (obj.get("direction") orelse return error.Corrupt) {
            .string => |s| s,
            else => return error.Corrupt,
        };
        const direction = std.meta.stringToEnum(Direction, direction_str) orelse return error.Corrupt;

        const ratio = try numberOf(obj.get("ratio"));

        // Both children are required. A split with only a `left` is
        // exactly the "half a tree" this reader promises never to hand
        // back, so a missing child fails the whole read rather than
        // producing a lopsided node.
        const left = try parseNode(arena, obj.get("left") orelse return error.Corrupt, format, fixups);
        const right = try parseNode(arena, obj.get("right") orelse return error.Corrupt, format, fixups);

        node.* = .{ .split = .{
            .direction = direction,
            .ratio = ratio,
            .left = left,
            .right = right,
        } };
        return node;
    }

    return error.Corrupt;
}

/// One pane, out of an object already known to be of kind `leaf`.
fn parseLeaf(arena: Allocator, obj: std.json.ObjectMap, format: u32, fixups: *Fixups) ReadError!Leaf {
    // Invalid is absent, not corrupt: one bad field should not cost
    // the whole project, and an absent snapshot is an empty pane. A
    // name an earlier pane has is absent for the same reason.
    const scrollback: []const u8 = scrollback: {
        const name = optionalStr(obj.get("scrollback")) orelse break :scrollback "";
        if (!isScrollbackName(name)) break :scrollback "";
        const seen = try fixups.scrollback.getOrPut(arena, name);
        break :scrollback if (seen.found_existing) "" else name;
    };
    return .{
        .cwd = optionalStr(obj.get("cwd")) orelse "",
        .title = optionalStr(obj.get("title")) orelse "",
        .history = optionalStr(obj.get("history")) orelse "",
        .scrollback = scrollback,
        // New with format 2 and strict as the agent is: absent is
        // false, anything but a boolean is a damaged file.
        .by_supervisor = if (format == 1) false else if (obj.get("by_supervisor")) |v| switch (v) {
            .bool => |b| b,
            else => return error.Corrupt,
        } else false,
        // A format 1 file never said, whatever keys it has.
        .agent = if (format == 1) .unknown else try parseAgent(obj.get("agent") orelse return error.Corrupt),
    };
}

/// Remember a pane that says it is the supervisor's, by where it now
/// lives, so that `parse` can take the claim back from all of them.
fn noteSupervisor(arena: Allocator, leaf: *Leaf, fixups: *Fixups) ReadError!void {
    switch (leaf.agent) {
        .agent => |who| if (who.supervisor) try fixups.supervisors.append(arena, &leaf.agent),
        .unknown, .none => {},
    }
}

/// Strict where the rest of a leaf is not: these keys are new with format
/// 2, so nothing older wrote them any other way, and "an agent, but of a
/// kind this build cannot name" is not something to guess at.
fn parseAgent(value: std.json.Value) ReadError!Agent {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.Corrupt,
    };
    const kind = switch (obj.get("kind") orelse return error.Corrupt) {
        .string => |s| s,
        else => return error.Corrupt,
    };
    if (std.mem.eql(u8, kind, "unknown")) return .unknown;
    if (std.mem.eql(u8, kind, "none")) return .none;
    if (!std.mem.eql(u8, kind, "agent")) return error.Corrupt;
    return .{ .agent = .{
        .role = try strictStr(obj.get("role")),
        .cli = try strictStr(obj.get("cli")),
        .session = try strictStr(obj.get("session")),
        .supervisor = switch (obj.get("supervisor") orelse return error.Corrupt) {
            .bool => |b| b,
            else => return error.Corrupt,
        },
    } };
}

/// Absent is empty; anything but a string is `Corrupt`.
fn strictStr(v: ?std.json.Value) ReadError![]const u8 {
    return switch (v orelse return "") {
        .string => |s| s,
        else => error.Corrupt,
    };
}

fn optionalStr(v: ?std.json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Delete a saved project. `error.NotFound` if there was no such project.
pub fn delete(alloc: Allocator, io: std.Io, dir: []const u8, name: []const u8) !void {
    const path = try pathFor(alloc, dir, name);
    defer alloc.free(path);

    const filename = std.fs.path.basename(path);
    var d = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return error.NotFound;
    defer d.close(io);

    d.deleteFile(io, filename) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return err,
    };
}

/// Rename a saved project: same windows, same history file references, new
/// display name -- and, since the filename is derived from the name (see
/// `pathFor`), a new file. `error.NotFound` if `old_name` doesn't exist.
///
/// Not atomic across the two files: the new file is written before the old
/// one is removed, so a crash in between leaves both on disk rather than
/// neither. That is the safe order to fail in -- the project still exists
/// under one of the two names either way.
pub fn rename(
    alloc: Allocator,
    io: std.Io,
    dir: []const u8,
    old_name: []const u8,
    new_name: []const u8,
) !void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    // Everything the project has, under the new name: its windows, its
    // group and its counter go with it.
    var renamed = try read(arena.allocator(), io, dir, old_name);
    renamed.name = new_name;
    try write(alloc, io, dir, renamed);

    if (!std.mem.eql(u8, old_name, new_name)) {
        delete(alloc, io, dir, old_name) catch |err| switch (err) {
            // The old file is already gone (e.g. both names sanitize to
            // the same filename, so the write above replaced it in
            // place) -- not a failure of the rename.
            error.NotFound => {},
            else => return err,
        };
    }
}

/// List saved projects. Best-effort: an entry this build cannot make sense
/// of is skipped rather than failing the whole listing, because this is an
/// inventory for a picker, not a load -- unlike `read`, nobody asked for
/// any one of these by name yet. Everything is arena-owned.
pub fn list(arena: Allocator, io: std.Io, dir: []const u8) Allocator.Error![]Entry {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;

    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return entries.items;
    defer d.close(io);

    var it = d.iterate();
    while (true) {
        const dirent = it.next(io) catch break orelse break;
        if (dirent.kind != .file) continue;
        if (!std.mem.endsWith(u8, dirent.name, ".json")) continue;

        const bytes = d.readFileAlloc(
            io,
            dirent.name,
            arena,
            .limited(64 * 1024 * 1024),
        ) catch continue;

        const snapshot = parse(arena, bytes) catch continue;
        try entries.append(arena, .{ .name = snapshot.name, .saved_at = snapshot.saved_at });
    }

    return entries.items;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

fn tmpDir(alloc: Allocator, io: std.Io) ![]const u8 {
    var raw: [6]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(alloc, "/tmp/polter-project-{x}", .{&raw});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

/// A project of one window with one tab, the way every project was before
/// format 2; no `root` is a project with nothing in it.
fn oneTab(arena: Allocator, name: []const u8, saved_at: i64, root: ?*const Node, next_scrollback: ?u64) !Snapshot {
    const windows: []const Window = if (root) |r| windows: {
        const tabs = try arena.alloc(Tab, 1);
        tabs[0] = .{ .root = r };
        const windows = try arena.alloc(Window, 1);
        windows[0] = .{ .frame = null, .front = 0, .tabs = tabs };
        break :windows windows;
    } else &.{};
    return .{ .name = name, .saved_at = saved_at, .group = null, .windows = windows, .next_scrollback = next_scrollback };
}

fn expectLeavesEqual(al: Leaf, bl: Leaf) !void {
    try testing.expectEqualStrings(al.cwd, bl.cwd);
    try testing.expectEqualStrings(al.title, bl.title);
    try testing.expectEqualStrings(al.history, bl.history);
    try testing.expectEqualStrings(al.scrollback, bl.scrollback);
    try testing.expectEqual(al.by_supervisor, bl.by_supervisor);
    try testing.expectEqualDeep(al.agent, bl.agent);
}

fn expectNodesEqual(a: Node, b: Node) !void {
    switch (a) {
        .leaf => |al| {
            const bl = switch (b) {
                .leaf => |v| v,
                .stack, .split => return error.TestExpectedEqual,
            };
            try expectLeavesEqual(al, bl);
        },
        .stack => |as| {
            const bs = switch (b) {
                .stack => |v| v,
                .leaf, .split => return error.TestExpectedEqual,
            };
            try testing.expectEqual(as.shown, bs.shown);
            try testing.expectEqual(as.members.len, bs.members.len);
            for (as.members, bs.members) |am, bm| try expectLeavesEqual(am, bm);
        },
        .split => |as| {
            const bs = switch (b) {
                .split => |v| v,
                .leaf, .stack => return error.TestExpectedEqual,
            };
            try testing.expectEqual(as.direction, bs.direction);
            try testing.expectEqual(as.ratio, bs.ratio);
            try expectNodesEqual(as.left.*, bs.left.*);
            try expectNodesEqual(as.right.*, bs.right.*);
        },
    }
}

test "what is written comes back exactly" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const left: Node = .{ .leaf = .{ .cwd = "/work/repo", .title = "✳ retry.py", .history = "a1b2c3.history", .scrollback = "0.snap", .by_supervisor = false, .agent = .unknown } };
    const right: Node = .{ .leaf = .{ .cwd = "/work/repo/tests", .title = "✳ tests", .history = "", .scrollback = "", .by_supervisor = false, .agent = .unknown } };
    const root: Node = .{ .split = .{
        .direction = .horizontal,
        .ratio = 0.62,
        .left = &left,
        .right = &right,
    } };

    const snapshot = try oneTab(alloc, "写 retry 装饰器", 1_757_000_000, &root, 4);

    try write(alloc, io, dir, snapshot);

    const back = try read(alloc, io, dir, "写 retry 装饰器");
    try testing.expectEqualStrings(snapshot.name, back.name);
    try testing.expectEqual(snapshot.saved_at, back.saved_at);
    try testing.expectEqual(snapshot.next_scrollback, back.next_scrollback);
    try expectNodesEqual(root, back.firstTab().?.*);
}

test "a project with no layout round-trips as an empty root" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try write(alloc, io, dir, try oneTab(alloc, "blank", 1, null, null));

    const back = try read(alloc, io, dir, "blank");
    try testing.expect(back.firstTab() == null);
}

test "a nested tree round-trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const a: Node = .{ .leaf = .{ .cwd = "/a", .title = "", .history = "", .scrollback = "", .by_supervisor = false, .agent = .unknown } };
    const b: Node = .{ .leaf = .{ .cwd = "/b", .title = "", .history = "", .scrollback = "", .by_supervisor = false, .agent = .unknown } };
    const c: Node = .{ .leaf = .{ .cwd = "/c", .title = "", .history = "", .scrollback = "", .by_supervisor = false, .agent = .unknown } };
    const inner: Node = .{ .split = .{ .direction = .vertical, .ratio = 0.5, .left = &b, .right = &c } };
    const root: Node = .{ .split = .{ .direction = .horizontal, .ratio = 0.3, .left = &a, .right = &inner } };

    try write(alloc, io, dir, try oneTab(alloc, "nested", 2, &root, null));

    const back = try read(alloc, io, dir, "nested");
    try expectNodesEqual(root, back.firstTab().?.*);
}

test "reading a project that was never saved is a named error, not a crash" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try testing.expectError(error.NotFound, read(alloc, io, dir, "no such project"));
}

test "reading from a directory that does not exist yet is NotFound too" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testing.expectError(
        error.NotFound,
        read(alloc, io, "/tmp/polter-project-does-not-exist-9c1f", "whatever"),
    );
}

test "a truncated file does not read out half a tree" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const left: Node = .{ .leaf = .{ .cwd = "/a", .title = "", .history = "", .scrollback = "", .by_supervisor = false, .agent = .unknown } };
    const right: Node = .{ .leaf = .{ .cwd = "/b", .title = "", .history = "", .scrollback = "", .by_supervisor = false, .agent = .unknown } };
    const root: Node = .{ .split = .{ .direction = .horizontal, .ratio = 0.5, .left = &left, .right = &right } };
    try write(alloc, io, dir, try oneTab(alloc, "cutoff", 3, &root, null));

    // Cut the file off partway through, the way a crash mid-write might
    // leave it (atomic replace makes this specific case unreachable in
    // practice, but the reader shouldn't rely on the writer for safety).
    const path = try pathFor(alloc, dir, "cutoff");
    const whole = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1024 * 1024));
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    {
        var f = try d.createFile(io, std.fs.path.basename(path), .{});
        defer f.close(io);
        try f.writeStreamingAll(io, whole[0 .. whole.len / 2]);
    }

    try testing.expectError(error.Corrupt, read(alloc, io, dir, "cutoff"));
}

test "a split missing its right child is Corrupt, not a lopsided tree" {
    // Syntactically valid JSON -- this is not the truncation case above --
    // but semantically incomplete. The strict field check has to catch
    // this on its own; a truncated-JSON test alone wouldn't exercise it.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes =
        \\{"name":"lopsided","saved_at":4,"root":{"kind":"split",
        \\"direction":"horizontal","ratio":0.5,
        \\"left":{"kind":"leaf","cwd":"/a"}}}
    ;

    try testing.expectError(error.Corrupt, parse(alloc, bytes));
}

test "an empty name is rejected at write, not saved unfindably" {
    // The bug W3 found mirroring this algorithm: sanitizing an empty (or
    // all-illegal-characters) name used to fall back to a fixed filename
    // with no `.json` suffix, so `list` -- which filters by that suffix --
    // could never find it again. The project existed, forever, invisibly.
    // Rejecting it here is the fix; see `pathFor`'s doc comment for the
    // second trap a bare suffix fix would have opened (a collision with a
    // project named "project" that overwrites *its* `name` field too).
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try testing.expectError(error.InvalidName, write(alloc, io, dir, try oneTab(alloc, "", 1, null, null)));

    // Nothing was written under any name a picker could show.
    const entries = try list(alloc, io, dir);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "a name made entirely of illegal characters still sanitizes to something, and is fine" {
    // Sanitizing substitutes one-for-one ('/' -> '_', a control byte ->
    // '_'), it never drops a byte outright -- so the only name that
    // sanitizes to nothing is one with nothing in it to begin with.
    // Worth a test precisely because it looks like it should hit the same
    // bug and doesn't: this is the case `pathFor`'s doc comment says still
    // round-trips like any other name.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try write(alloc, io, dir, try oneTab(alloc, "/", 2, null, null));
    const back = try read(alloc, io, dir, "/");
    try testing.expectEqualStrings("/", back.name);
}

test "delete removes a project and reading it after is NotFound" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try write(alloc, io, dir, try oneTab(alloc, "gone soon", 5, null, null));
    try delete(alloc, io, dir, "gone soon");

    try testing.expectError(error.NotFound, read(alloc, io, dir, "gone soon"));
}

test "deleting a project that doesn't exist is a named error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try testing.expectError(error.NotFound, delete(alloc, io, dir, "never existed"));
}

test "rename keeps the tree and moves the name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const leaf: Node = .{ .leaf = .{ .cwd = "/work", .title = "", .history = "", .scrollback = "", .by_supervisor = false, .agent = .unknown } };
    try write(alloc, io, dir, try oneTab(alloc, "old name", 6, &leaf, 3));

    try rename(alloc, io, dir, "old name", "new name");

    const back = try read(alloc, io, dir, "new name");
    try testing.expectEqualStrings("new name", back.name);
    try testing.expectEqual(@as(i64, 6), back.saved_at);
    // Dropping the counter on a rename would let the next save hand out a
    // number a closed pane still has a snapshot under.
    try testing.expectEqual(@as(?u64, 3), back.next_scrollback);
    try expectNodesEqual(leaf, back.firstTab().?.*);

    try testing.expectError(error.NotFound, read(alloc, io, dir, "old name"));
}

test "list finds every saved project and skips a corrupt one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try tmpDir(alloc, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try write(alloc, io, dir, try oneTab(alloc, "alpha", 10, null, null));
    try write(alloc, io, dir, try oneTab(alloc, "beta", 20, null, null));

    {
        var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
        defer d.close(io);
        var f = try d.createFile(io, "garbage.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "{not json");
    }

    const entries = try list(alloc, io, dir);
    try testing.expectEqual(@as(usize, 2), entries.len);

    var saw_alpha = false;
    var saw_beta = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "alpha")) saw_alpha = true;
        if (std.mem.eql(u8, e.name, "beta")) saw_beta = true;
    }
    try testing.expect(saw_alpha);
    try testing.expect(saw_beta);
}

test "listing a directory that does not exist yet is empty, not an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const entries = try list(alloc, io, "/tmp/polter-project-does-not-exist-4a1f");
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "a scrollback name that could name anything but a snapshot here reads as empty" {
    // Accepted: what a writer of this format produces.
    for ([_][]const u8{ "0.snap", "7.snap", "12345678901234567890.snap" }) |ok| {
        try testing.expect(isScrollbackName(ok));
    }
    // Refused: a path, a separator, a drive, no digits, too many digits,
    // something that is not a digit, the wrong suffix.
    for ([_][]const u8{
        "../../elsewhere/keep.snap", "/abs/0.snap", "a/0.snap",                   "..\\0.snap",
        "C:0.snap",                  ".snap",       "123456789012345678901.snap", "1a.snap",
        "-1.snap",                   "0.snap/",     "0.SNAP",                     "0.snapx",
        "",
    }) |bad| {
        try testing.expect(!isScrollbackName(bad));
    }

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const snap = try parse(arena.allocator(),
        \\{"name":"p","saved_at":1,"root":{"kind":"split","direction":"vertical","ratio":0.5,
        \\  "left":{"kind":"leaf","cwd":"/a","scrollback":"../../elsewhere/keep.snap"},
        \\  "right":{"kind":"leaf","cwd":"/b","scrollback":"4.snap"}}}
    );
    // The bad name costs that one field, not the project.
    try testing.expectEqualStrings("", snap.firstTab().?.split.left.leaf.scrollback);
    try testing.expectEqualStrings("/a", snap.firstTab().?.split.left.leaf.cwd);
    try testing.expectEqualStrings("4.snap", snap.firstTab().?.split.right.leaf.scrollback);
}

test "every row of the shared filename table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const table = std.Io.Dir.cwd().readFileAlloc(
        io,
        filename_table_path,
        alloc,
        .limited(1024 * 1024),
    ) catch |err| {
        std.debug.print(
            "cannot read the filename table {s} ({s}): this test runs from the repository root\n",
            .{ filename_table_path, @errorName(err) },
        );
        return err;
    };

    var declared: ?usize = null;
    var rows: usize = 0;
    var failed: usize = 0;
    var lines = std.mem.splitScalar(u8, table, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        // Only a trailing \r goes (a Windows checkout). Never trim: the
        // empty-name row *starts* with a tab, and trimming it would shift
        // every column of that row one to the left.
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            if (std.mem.startsWith(u8, line, "# rows: ")) {
                declared = try std.fmt.parseInt(usize, line["# rows: ".len..], 10);
            }
            continue;
        }

        var field: [4][]const u8 = undefined;
        var count: usize = 0;
        var fields = std.mem.splitScalar(u8, line, '\t');
        while (fields.next()) |f| : (count += 1) {
            if (count < field.len) field[count] = f;
        }
        if (count != field.len) {
            std.debug.print(
                "{s}:{d}: {d} fields, want 4 (input, expected, status, note)\n",
                .{ filename_table_path, number, count },
            );
            return error.TestUnexpectedResult;
        }
        const input_hex, const expected_hex, const status, const note = field;
        rows += 1;

        const input = try alloc.alloc(u8, input_hex.len / 2);
        _ = try std.fmt.hexToBytes(input, input_hex);

        const got: []const u8 = sanitizeFilename(alloc, input) catch |err| switch (err) {
            error.InvalidName => "ERR:InvalidName",
            else => return err,
        };
        const want: []const u8 = if (std.mem.eql(u8, expected_hex, "ERR:InvalidName"))
            expected_hex
        else want: {
            const bytes = try alloc.alloc(u8, expected_hex.len / 2);
            _ = try std.fmt.hexToBytes(bytes, expected_hex);
            break :want bytes;
        };

        // `draft` rows are run and counted, not asserted: see the table's
        // header.
        if (std.mem.eql(u8, status, "draft")) continue;
        if (!std.mem.eql(u8, got, want)) {
            failed += 1;
            std.debug.print(
                "{s}:{d} ({s}): src/Project.zig sanitizeFilename gave {x} want {x}\n",
                .{ filename_table_path, number, note, got, want },
            );
        }
    }

    // A reader that finds nothing, or finds less than the table has, passes
    // every row it did find. This is what fails it.
    const want_rows = declared orelse {
        std.debug.print("{s}: no '# rows: N' line\n", .{filename_table_path});
        return error.TestUnexpectedResult;
    };
    if (rows != want_rows or rows == 0) {
        std.debug.print("{s}: read {d} rows, the table says {d}\n", .{ filename_table_path, rows, want_rows });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 0), failed);
}

test "bytes that are not UTF-8 each become an underscore, and nothing is cut inside a scalar" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]struct { in: []const u8, want: []const u8 }{
        // A byte that starts nothing.
        .{ .in = "\xff", .want = "_.json" },
        // A lone continuation byte.
        .{ .in = "a\x80b", .want = "a_b.json" },
        // `写` cut after two of its three bytes: both left over.
        .{ .in = "a\xe5\x86", .want = "a__.json" },
        // Two bytes of `写`, then a character that is not a continuation.
        .{ .in = "\xe5\x86z", .want = "__z.json" },
        // An overlong `/`: not UTF-8, so not a separator either -- two
        // underscores, not one.
        .{ .in = "\xc0\xaf", .want = "__.json" },
        // A surrogate half.
        .{ .in = "\xed\xa0\x80", .want = "___.json" },
        // Past U+10FFFF.
        .{ .in = "\xf4\x90\x80\x80", .want = "____.json" },
        // Valid scalars around the invalid ones are kept as they are.
        .{ .in = "\xe5\x86\x99\xff\xe5\x86\x99", .want = "\xe5\x86\x99_\xe5\x86\x99.json" },
    };
    for (cases) |c| {
        const got = try sanitizeFilename(alloc, c.in);
        try testing.expectEqualSlices(u8, c.want, got);
        try testing.expect(std.unicode.utf8ValidateSlice(got));
    }

    // Each invalid byte counts one toward the cap, like the `_` it becomes.
    const long = [_]u8{0xff} ** 250;
    const got = try sanitizeFilename(alloc, &long);
    try testing.expectEqual(@as(usize, max_filename_len + ".json".len), got.len);
}

test "a format 1 file reads as one window with one tab, and nobody knows who was in its panes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const snap = try parse(arena.allocator(),
        \\{"name":"old","saved_at":7,"next_scrollback":2,"group":"not a format 1 key",
        \\ "root":{"kind":"leaf","cwd":"/a","scrollback":"1.snap",
        \\         "agent":{"kind":"agent","supervisor":true}}}
    );
    try testing.expectEqual(@as(usize, 1), snap.windows.len);
    try testing.expectEqual(@as(?Frame, null), snap.windows[0].frame);
    try testing.expectEqual(@as(usize, 0), snap.windows[0].front);
    try testing.expectEqual(@as(usize, 1), snap.windows[0].tabs.len);
    try testing.expectEqual(@as(?[]const u8, null), snap.group);
    try testing.expectEqual(@as(?u64, 2), snap.next_scrollback);
    const leaf = snap.firstTab().?.leaf;
    try testing.expectEqualStrings("/a", leaf.cwd);
    try testing.expectEqualStrings("1.snap", leaf.scrollback);
    // Not `none`, and not the agent the stray key describes.
    try testing.expectEqual(Agent.unknown, leaf.agent);

    // No `root` is a project with nothing in it, not a corrupt one.
    const blank = try parse(arena.allocator(), "{\"name\":\"blank\",\"saved_at\":1}");
    try testing.expectEqual(@as(usize, 0), blank.windows.len);
    try testing.expect(blank.firstTab() == null);
}

test "a file from a later format is refused as too new, and is never read as format 1" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // It has everything a format 1 file has. Read as one, it is a project
    // of one pane, and the next save writes that over whatever it was.
    try testing.expectError(error.TooNew, parse(alloc,
        \\{"format":3,"name":"later","saved_at":1,"root":{"kind":"leaf","cwd":"/a"}}
    ));
    try testing.expectError(error.TooNew, parse(alloc, "{\"format\":9000,\"name\":\"n\",\"saved_at\":1,\"windows\":[]}"));

    // A `format` that is not a version at all is a damaged file.
    for ([_][]const u8{ "0", "-1", "\"2\"", "2.0", "null", "true", "[2]" }) |bad| {
        const bytes = try std.fmt.allocPrint(alloc, "{{\"format\":{s},\"name\":\"n\",\"saved_at\":1,\"windows\":[]}}", .{bad});
        try testing.expectError(error.Corrupt, parse(alloc, bytes));
    }

    // And `format: 1` said out loud is format 1.
    const one = try parse(alloc, "{\"format\":1,\"name\":\"n\",\"saved_at\":1,\"root\":{\"kind\":\"leaf\"}}");
    try testing.expectEqual(@as(usize, 1), one.windows.len);
}

test "a format 2 file that lacks what format 2 always writes is corrupt" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const leaf = "{\"kind\":\"leaf\",\"agent\":{\"kind\":\"none\"}}";
    const cases = [_]struct { what: []const u8, windows: []const u8 }{
        .{ .what = "no tabs key", .windows = "[{\"front\":0}]" },
        .{ .what = "a window with no tab", .windows = "[{\"front\":0,\"tabs\":[]}]" },
        .{ .what = "no front", .windows = "[{\"tabs\":[{\"root\":" ++ leaf ++ "}]}]" },
        .{ .what = "front past the last tab", .windows = "[{\"front\":1,\"tabs\":[{\"root\":" ++ leaf ++ "}]}]" },
        .{ .what = "front below zero", .windows = "[{\"front\":-1,\"tabs\":[{\"root\":" ++ leaf ++ "}]}]" },
        .{ .what = "a tab with no root", .windows = "[{\"front\":0,\"tabs\":[{}]}]" },
        .{ .what = "a leaf that does not say who", .windows = "[{\"front\":0,\"tabs\":[{\"root\":{\"kind\":\"leaf\"}}]}]" },
        .{ .what = "an agent of no kind this build names", .windows = "[{\"front\":0,\"tabs\":[{\"root\":{\"kind\":\"leaf\",\"agent\":{\"kind\":\"robot\"}}}]}]" },
        .{ .what = "an agent that does not say whether it supervises", .windows = "[{\"front\":0,\"tabs\":[{\"root\":{\"kind\":\"leaf\",\"agent\":{\"kind\":\"agent\"}}}]}]" },
        .{ .what = "an agent whose role is not text", .windows = "[{\"front\":0,\"tabs\":[{\"root\":{\"kind\":\"leaf\",\"agent\":{\"kind\":\"agent\",\"role\":1,\"supervisor\":false}}}]}]" },
        .{ .what = "a stack of one", .windows = "[{\"front\":0,\"tabs\":[{\"root\":{\"kind\":\"stack\",\"shown\":0,\"members\":[" ++ leaf ++ "]}}]}]" },
        .{ .what = "a stack of none", .windows = "[{\"front\":0,\"tabs\":[{\"root\":{\"kind\":\"stack\",\"shown\":0,\"members\":[]}}]}]" },
        .{ .what = "a stack showing a member it has not", .windows = "[{\"front\":0,\"tabs\":[{\"root\":{\"kind\":\"stack\",\"shown\":2,\"members\":[" ++ leaf ++ "," ++ leaf ++ "]}}]}]" },
        .{ .what = "a stack showing a member below zero", .windows = "[{\"front\":0,\"tabs\":[{\"root\":{\"kind\":\"stack\",\"shown\":-1,\"members\":[" ++ leaf ++ "," ++ leaf ++ "]}}]}]" },
        .{ .what = "a stack that does not say which shows", .windows = "[{\"front\":0,\"tabs\":[{\"root\":{\"kind\":\"stack\",\"members\":[" ++ leaf ++ "," ++ leaf ++ "]}}]}]" },
        .{ .what = "a stack with no members key", .windows = "[{\"front\":0,\"tabs\":[{\"root\":{\"kind\":\"stack\",\"shown\":0}}]}]" },
        .{ .what = "a stack with a split in it", .windows = "[{\"front\":0,\"tabs\":[{\"root\":{\"kind\":\"stack\",\"shown\":0,\"members\":[" ++ leaf ++ ",{\"kind\":\"split\",\"direction\":\"horizontal\",\"ratio\":0.5,\"left\":" ++ leaf ++ ",\"right\":" ++ leaf ++ "}]}}]}]" },
        // Everything a leaf needs, under another kind: it is the kind that
        // is refused, not something that happens to be missing.
        .{ .what = "a stack with a member that says it is a split", .windows = "[{\"front\":0,\"tabs\":[{\"root\":{\"kind\":\"stack\",\"shown\":0,\"members\":[" ++ leaf ++ ",{\"kind\":\"split\",\"agent\":{\"kind\":\"none\"}}]}}]}]" },
        .{ .what = "a stack with a stack in it", .windows = "[{\"front\":0,\"tabs\":[{\"root\":{\"kind\":\"stack\",\"shown\":0,\"members\":[" ++ leaf ++ ",{\"kind\":\"stack\",\"shown\":0,\"members\":[" ++ leaf ++ "," ++ leaf ++ "]}]}}]}]" },
        .{ .what = "a by_supervisor that is not yes or no", .windows = "[{\"front\":0,\"tabs\":[{\"root\":{\"kind\":\"leaf\",\"by_supervisor\":1,\"agent\":{\"kind\":\"none\"}}}]}]" },
        .{ .what = "a frame from no corner", .windows = "[{\"frame\":{\"x\":0,\"y\":0,\"width\":1,\"height\":1},\"front\":0,\"tabs\":[{\"root\":" ++ leaf ++ "}]}]" },
        .{ .what = "a frame missing a side", .windows = "[{\"frame\":{\"origin\":\"top_left\",\"x\":0,\"y\":0,\"width\":1},\"front\":0,\"tabs\":[{\"root\":" ++ leaf ++ "}]}]" },
        .{ .what = "windows that are not a list", .windows = "{}" },
    };
    for (cases) |c| {
        const bytes = try std.fmt.allocPrint(alloc, "{{\"format\":2,\"name\":\"n\",\"saved_at\":1,\"windows\":{s}}}", .{c.windows});
        testing.expectError(error.Corrupt, parse(alloc, bytes)) catch |err| {
            std.debug.print("{s}: read without complaint\n", .{c.what});
            return err;
        };
    }
    // No `windows` at all -- which is what a format 1 file looks like to a
    // reader that only checked the number.
    try testing.expectError(error.Corrupt, parse(alloc, "{\"format\":2,\"name\":\"n\",\"saved_at\":1,\"root\":" ++ leaf ++ "}"));
    // The control: the same shape, whole, reads.
    const ok = try parse(alloc, "{\"format\":2,\"name\":\"n\",\"saved_at\":1,\"windows\":[{\"front\":0,\"tabs\":[{\"root\":" ++ leaf ++ "}]}]}");
    try testing.expectEqual(Agent.none, ok.firstTab().?.leaf.agent);
}

test "a stack is at least two panes with one of them showing, to write as to read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pane: Leaf = .{ .cwd = "", .title = "", .history = "", .scrollback = "", .by_supervisor = false, .agent = .none };
    const bad = [_]Stack{
        // One terminal in a pane is a leaf, and it is not this that turns
        // it into one.
        .{ .shown = 0, .members = &.{pane} },
        .{ .shown = 0, .members = &.{} },
        .{ .shown = 2, .members = &.{ pane, pane } },
    };
    for (bad) |stack| {
        const root: Node = .{ .stack = stack };
        var buf: std.Io.Writer.Allocating = .init(alloc);
        try testing.expectError(error.BadStack, emit(&buf.writer, try oneTab(alloc, "n", 1, &root, null)));
    }

    // Format 1 has no such node: a file that old with one in it is damaged.
    try testing.expectError(error.Corrupt, parse(alloc,
        \\{"name":"old","saved_at":1,"root":{"kind":"stack","shown":0,
        \\ "members":[{"kind":"leaf","cwd":"/a"},{"kind":"leaf","cwd":"/b"}]}}
    ));
}

test "a ratio that is not a finite number cannot be written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const leaf: Node = .{ .leaf = .{ .cwd = "", .title = "", .history = "", .scrollback = "", .by_supervisor = false, .agent = .none } };
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |bad| {
        const root: Node = .{ .split = .{ .direction = .horizontal, .ratio = bad, .left = &leaf, .right = &leaf } };
        var buf: std.Io.Writer.Allocating = .init(alloc);
        try testing.expectError(error.NotFinite, emit(&buf.writer, try oneTab(alloc, "n", 1, &root, null)));
    }
}

// -- the shared files ----------------------------------------------------------
//
// `test/project-format/` is the judge between the three implementations of
// this format. Every file in it is listed in `index.txt` there, and is one
// of three kinds:
//
//   same     `<stem>.json` is a format 2 file. Read and written back, it
//            is the same bytes.
//   from     `<stem>.in.json` is something else that has to be read -- a
//            format 1 file, or a file a read puts right. Read and written,
//            it is the bytes of `<stem>.json`.
//   refused  `<stem>.in.json` must not be read: it is from a later format.
//
// **The bytes are made here and nowhere else.** Each `<stem>.json` is what
// `emit` gives for a value spelled out below, so it is not a file that
// happened to round-trip: the reader is checked against the value, and the
// file against the writer. The other two implementations do not make any of
// them; they read `index.txt` and compare. The `.in.json` files are written
// by hand, since no build writes them.
//
// To change the format: change the values, create an empty file named
// `test/project-format/REGENERATE`, run this test once (it rewrites every
// `<stem>.json` and `index.txt`, and then fails so that the run is not
// taken for a pass), delete `REGENERATE`, and read the diff. It lives under
// `test/`, outside this module's package path, so nothing here can be
// `@embedFile`d; the files are read at test time relative to the repository
// root, which is where `zig build test` runs. Not finding one is a
// failure, never a skip.

const shared_dir = "test/project-format";

const Shared = struct {
    const Kind = enum { same, from, refused };

    kind: Kind,
    stem: []const u8,
    /// What the file reads as. Not looked at for `refused`.
    value: Snapshot,

    fn leaf(comptime cwd: []const u8, comptime scrollback: []const u8, comptime agent: Agent) *const Node {
        return &.{ .leaf = .{ .cwd = cwd, .title = "", .history = "", .scrollback = scrollback, .by_supervisor = false, .agent = agent } };
    }

    /// A pane the project's supervisor opened.
    fn opened(comptime cwd: []const u8, comptime agent: Agent) *const Node {
        return &.{ .leaf = .{ .cwd = cwd, .title = "", .history = "", .scrollback = "", .by_supervisor = true, .agent = agent } };
    }

    fn split(comptime direction: Direction, comptime ratio: f64, comptime left: *const Node, comptime right: *const Node) *const Node {
        return &.{ .split = .{ .direction = direction, .ratio = ratio, .left = left, .right = right } };
    }

    const supervisor: Agent = .{ .agent = .{
        .role = "polter-supervisor",
        .cli = "claude-code",
        .session = "eed9173b-c1fc-4493-aa00-187bacdc94cf",
        .supervisor = true,
    } };

    fn worker(comptime supervises: bool) Agent {
        return .{ .agent = .{ .role = "polter-dev", .cli = "codex", .session = "", .supervisor = supervises } };
    }

    const all = [_]Shared{
        // What every project file was before format 2.
        .{ .kind = .from, .stem = "format_1", .value = .{
            .name = "every field",
            .saved_at = 1757000000,
            .group = null,
            .next_scrollback = 12,
            .windows = &.{.{ .frame = null, .front = 0, .tabs = &.{.{ .root = split(
                .vertical,
                0.25,
                &.{ .leaf = .{ .cwd = "/work/left", .title = "left title", .history = "left.history", .scrollback = "3.snap", .by_supervisor = false, .agent = .unknown } },
                &.{ .leaf = .{ .cwd = "/work/right", .title = "right title", .history = "right.history", .scrollback = "8.snap", .by_supervisor = false, .agent = .unknown } },
            ) }} }},
        } },
        // A format 1 file with no tab in it.
        .{ .kind = .from, .stem = "format_1_empty", .value = .{
            .name = "nothing in it",
            .saved_at = 5,
            .group = null,
            .next_scrollback = null,
            .windows = &.{},
        } },
        // The smallest thing format 2 writes for a real project.
        .{ .kind = .same, .stem = "one_tab", .value = .{
            .name = "one tab",
            .saved_at = 1757000001,
            .group = null,
            .next_scrollback = 1,
            .windows = &.{.{
                .frame = .{ .origin = .bottom_left, .x = 120, .y = 80, .width = 1280, .height = 800 },
                .front = 0,
                .tabs = &.{.{ .root = &.{ .leaf = .{ .cwd = "/work", .title = "zsh", .history = "a1b2c3.history", .scrollback = "0.snap", .by_supervisor = false, .agent = .none } } }},
            }},
        } },
        // Several windows, several tabs, and every way a string or a number
        // is written differently by three JSON libraries left to themselves.
        .{ .kind = .same, .stem = "windows_and_tabs", .value = .{
            .name = "写 retry 装饰器 \"v2\" a/b",
            .saved_at = -1,
            .group = null,
            .next_scrollback = 9007199254740993,
            .windows = &.{
                .{
                    .frame = .{ .origin = .top_left, .x = -1920, .y = 0.5, .width = 1707.3333333333333, .height = 1e21 },
                    .front = 2,
                    .tabs = &.{
                        .{ .root = split(
                            .horizontal,
                            0.62,
                            &.{ .leaf = .{
                                .cwd = "C:\\work\\repo",
                                .title = "a \"quoted\" title, a backslash \\, a tab\t, a line\n, 中文, ✳ and 🧪",
                                .history = "a1b2c3.history",
                                .scrollback = "0.snap",
                                .by_supervisor = false,
                                .agent = .none,
                            } },
                            &.{ .leaf = .{ .cwd = "", .title = "", .history = "", .scrollback = "", .by_supervisor = false, .agent = .unknown } },
                        ) },
                        .{ .root = &.{ .leaf = .{
                            .cwd = "/a/b",
                            .title = "\x01\x1f\x7f</script>\u{2028}",
                            .history = "",
                            .scrollback = "12345678901234567890.snap",
                            .by_supervisor = false,
                            .agent = worker(false),
                        } } },
                        .{ .root = split(
                            .vertical,
                            0.30000000000000004,
                            split(.horizontal, 0.0000001, leaf("/x", "", .none), leaf("/y", "", .none)),
                            split(
                                .vertical,
                                1,
                                split(.horizontal, 0.3333333333333333, leaf("/p", "7.snap", .none), leaf("/q", "", .none)),
                                split(.horizontal, 5e-324, leaf("/r", "", .none), split(.vertical, 123456789.125, leaf("/s", "", .none), leaf("/t", "", .none))),
                            ),
                        ) },
                    },
                },
                .{
                    .frame = null,
                    .front = 0,
                    .tabs = &.{.{ .root = leaf("/tmp", "8.snap", .unknown) }},
                },
            },
        } },
        // A project with its supervisor, a worker, a plain shell, and a
        // pane nobody could say anything about -- the four things a pane
        // can be.
        .{
            .kind = .same,
            .stem = "supervisor",
            .value = .{
                .name = "with a supervisor",
                .saved_at = 1757000002,
                .group = null,
                .next_scrollback = null,
                .windows = &.{.{
                    .frame = .{ .origin = .bottom_left, .x = 0, .y = 0, .width = 1440, .height = 900 },
                    .front = 1,
                    .tabs = &.{
                        // This ratio is one a JSON reader that parses numbers
                        // the quick way gets wrong by one in the last place
                        // (measured: serde_json without `float_roundtrip` reads
                        // it as ...696), and then writes back different digits.
                        .{ .root = split(.horizontal, 0.9856906946328695, leaf("/work/repo", "", supervisor), opened("/work/repo", worker(false))) },
                        // The second pane is one the supervisor opened and
                        // whose agent has since left: nobody's, and still
                        // the supervisor's to use again.
                        .{ .root = split(.vertical, 0.5, opened("/work/repo", .none), leaf("", "", .unknown)) },
                    },
                }},
            },
        },
        // The project of a group.
        .{ .kind = .same, .stem = "group", .value = .{
            .name = "polter 0.10 群",
            .saved_at = 1757000003,
            .group = "polter 0.10 群",
            .next_scrollback = 2,
            .windows = &.{.{
                .frame = null,
                .front = 0,
                .tabs = &.{.{ .root = leaf("/work/repo", "1.snap", supervisor) }},
            }},
        } },
        // Three panes each say they are the supervisor: none of them is,
        // and what they otherwise were is kept.
        .{ .kind = .from, .stem = "two_supervisors", .value = .{
            .name = "two supervisors",
            .saved_at = 1757000004,
            .group = "g",
            .next_scrollback = null,
            .windows = &.{
                .{ .frame = null, .front = 0, .tabs = &.{
                    .{ .root = split(.horizontal, 0.5, leaf("/a", "", worker(false)), leaf("/b", "", .none)) },
                    .{ .root = leaf("/c", "", worker(false)) },
                } },
                .{ .frame = null, .front = 0, .tabs = &.{.{ .root = &.{ .leaf = .{
                    .cwd = "/d",
                    .title = "",
                    .history = "",
                    .scrollback = "",
                    .by_supervisor = false,
                    .agent = .{ .agent = .{ .role = "polter-supervisor", .cli = "claude-code", .session = "s-2", .supervisor = false } },
                } } }} },
            },
        } },
        // One snapshot name on three panes, in two tabs and two windows:
        // the first keeps it. And a name that is not a snapshot's.
        .{ .kind = .from, .stem = "duplicate_scrollback", .value = .{
            .name = "one snapshot, three panes",
            .saved_at = 1757000005,
            .group = null,
            .next_scrollback = 4,
            .windows = &.{
                .{ .frame = null, .front = 1, .tabs = &.{
                    .{ .root = split(.horizontal, 0.5, leaf("/a", "3.snap", .none), leaf("/b", "", .none)) },
                    .{ .root = leaf("/c", "", .none) },
                } },
                .{ .frame = null, .front = 0, .tabs = &.{.{ .root = split(.vertical, 0.5, leaf("/d", "", .none), leaf("/e", "2.snap", .none)) }} },
            },
        } },
        // A pane that holds three terminals, the second showing, beside a
        // plain pane; and a tab that is nothing but a stack. The supervisor
        // is a member that is not in front, and a member is a pane the
        // supervisor opened.
        .{ .kind = .same, .stem = "stack", .value = .{
            .name = "a stack",
            .saved_at = 1757000007,
            .group = "g",
            .next_scrollback = 6,
            .windows = &.{.{
                .frame = null,
                .front = 0,
                .tabs = &.{
                    .{ .root = split(
                        .horizontal,
                        0.5,
                        &.{ .stack = .{ .shown = 1, .members = &.{
                            .{ .cwd = "/work/repo", .title = "supervisor", .history = "s.history", .scrollback = "0.snap", .by_supervisor = false, .agent = supervisor },
                            .{ .cwd = "/work/repo/a", .title = "", .history = "", .scrollback = "1.snap", .by_supervisor = true, .agent = worker(false) },
                            .{ .cwd = "", .title = "", .history = "", .scrollback = "", .by_supervisor = false, .agent = .unknown },
                        } } },
                        leaf("/work/repo/b", "2.snap", .none),
                    ) },
                    .{ .root = &.{ .stack = .{ .shown = 0, .members = &.{
                        .{ .cwd = "/x", .title = "", .history = "", .scrollback = "4.snap", .by_supervisor = false, .agent = .none },
                        .{ .cwd = "/y", .title = "", .history = "", .scrollback = "5.snap", .by_supervisor = false, .agent = .none },
                    } } } },
                },
            }},
        } },
        // What a read puts right, inside a stack as anywhere: two members
        // say they are the supervisor, so neither is; and the snapshot one
        // member has is not also the next one's, nor the pane's beside it.
        .{ .kind = .from, .stem = "stack_put_right", .value = .{
            .name = "a stack put right",
            .saved_at = 1757000008,
            .group = null,
            .next_scrollback = 2,
            .windows = &.{.{ .frame = null, .front = 0, .tabs = &.{.{ .root = split(
                .vertical,
                0.5,
                &.{ .stack = .{ .shown = 0, .members = &.{
                    .{ .cwd = "/a", .title = "", .history = "", .scrollback = "1.snap", .by_supervisor = false, .agent = worker(false) },
                    .{ .cwd = "/b", .title = "", .history = "", .scrollback = "", .by_supervisor = false, .agent = worker(false) },
                } } },
                leaf("/c", "", .none),
            ) }} }},
        } },
        .{ .kind = .refused, .stem = "too_new", .value = undefined },
    };
};

fn expectSnapshotsEqual(want: Snapshot, got: Snapshot) !void {
    try testing.expectEqualStrings(want.name, got.name);
    try testing.expectEqual(want.saved_at, got.saved_at);
    try testing.expectEqual(want.next_scrollback, got.next_scrollback);
    try testing.expectEqual(want.group == null, got.group == null);
    if (want.group) |g| try testing.expectEqualStrings(g, got.group.?);
    try testing.expectEqual(want.windows.len, got.windows.len);
    for (want.windows, got.windows) |w, g| {
        try testing.expectEqual(w.frame, g.frame);
        try testing.expectEqual(w.front, g.front);
        try testing.expectEqual(w.tabs.len, g.tabs.len);
        for (w.tabs, g.tabs) |wt, gt| try expectNodesEqual(wt.root.*, gt.root.*);
    }
}

test "the files under test/project-format are what this build writes, and what it reads them as" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, shared_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("cannot open {s} ({s}): this test runs from the repository root\n", .{ shared_dir, @errorName(err) });
        return err;
    };
    defer dir.close(io);

    const regenerate = if (dir.access(io, "REGENERATE", .{})) |_| true else |_| false;

    var index: std.Io.Writer.Allocating = .init(alloc);
    for (Shared.all) |f| try index.writer.print("{s}\t{s}\n", .{ @tagName(f.kind), f.stem });

    var files_named: usize = 0;
    for (Shared.all) |f| {
        const in_name = try std.fmt.allocPrint(alloc, "{s}.in.json", .{f.stem});
        const out_name = try std.fmt.allocPrint(alloc, "{s}.json", .{f.stem});

        if (f.kind == .refused) {
            files_named += 1;
            const in = try dir.readFileAlloc(io, in_name, alloc, .limited(1024 * 1024));
            try testing.expectError(error.TooNew, parse(alloc, in));
            continue;
        }

        var made: std.Io.Writer.Allocating = .init(alloc);
        try emit(&made.writer, f.value);
        if (regenerate) {
            var file = try dir.createFile(io, out_name, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, made.written());
        }

        // The file is what the writer makes of the value...
        files_named += 1;
        const on_disk = dir.readFileAlloc(io, out_name, alloc, .limited(1024 * 1024)) catch |err| {
            std.debug.print("{s}/{s}: {s}\n", .{ shared_dir, out_name, @errorName(err) });
            return err;
        };
        testing.expectEqualStrings(on_disk, made.written()) catch |err| {
            std.debug.print("{s}/{s} is not what emit writes for the value in src/Project.zig\n", .{ shared_dir, out_name });
            return err;
        };

        // ...and the reader makes the value of the file.
        const back = try parse(alloc, on_disk);
        expectSnapshotsEqual(f.value, back) catch |err| {
            std.debug.print("{s}/{s} does not read as the value in src/Project.zig\n", .{ shared_dir, out_name });
            return err;
        };

        if (f.kind == .from) {
            files_named += 1;
            const in = try dir.readFileAlloc(io, in_name, alloc, .limited(1024 * 1024));
            const read_in = try parse(alloc, in);
            expectSnapshotsEqual(f.value, read_in) catch |err| {
                std.debug.print("{s}/{s} does not read as the value in src/Project.zig\n", .{ shared_dir, in_name });
                return err;
            };
            var rewritten: std.Io.Writer.Allocating = .init(alloc);
            try emit(&rewritten.writer, read_in);
            try testing.expectEqualStrings(on_disk, rewritten.written());
        }
    }

    if (regenerate) {
        var file = try dir.createFile(io, "index.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, index.written());
    }
    const index_on_disk = try dir.readFileAlloc(io, "index.txt", alloc, .limited(1024 * 1024));
    try testing.expectEqualStrings(index_on_disk, index.written());

    // No file here that nothing above looked at: a file the index does not
    // name is one the other two implementations never read either.
    var json_files: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".json")) json_files += 1;
    }
    try testing.expectEqual(files_named, json_files);

    if (regenerate) {
        std.debug.print("{s}: rewritten because REGENERATE is there -- delete it and run again\n", .{shared_dir});
        return error.RegeneratedNotChecked;
    }
}

test "a build from before windows cannot take a format 2 file for a project with no panes" {
    // Such a build reads `name`, `saved_at` and `root`. What it finds under
    // `root` has to be something it refuses.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var made: std.Io.Writer.Allocating = .init(alloc);
    try emit(&made.writer, Shared.all[2].value);
    const file = try std.json.parseFromSliceLeaky(std.json.Value, alloc, made.written(), .{});
    const root = file.object.get("root").?.object;
    const kind = root.get("kind").?.string;
    try testing.expect(!std.mem.eql(u8, kind, "leaf"));
    try testing.expect(!std.mem.eql(u8, kind, "split"));
}
