//! The shape both of Polter's on-disk records share: one directory per
//! caller-chosen name, one file per local day, one JSON object per line.
//!
//! This lives in its own file because two things need it and there must be
//! exactly one of it. A group name and a terminal name are the same kind of
//! thing -- picked by a person, able to hold any byte, and about to become a
//! directory name -- so if each writer brought its own encoding, one state
//! directory would end up holding two rules that disagree about where a
//! given name's files go. That is not duplicated code; it is two writers
//! saying different things about the same directory.
//!
//! `ChatLog` writes `<state>/chat/<group>/<day>.jsonl` through this, and the
//! terminal transcript writes `<state>/terminals/<terminal>/<day>.jsonl`.
//! What is *in* a line is each writer's own business; where the line lands,
//! and what a day is, is decided here.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.poltergeist);

/// The most one day's file in the record holds before that day carries on
/// in a `.partN` file beside it.
///
/// The same number as `rotate_bytes` and for an unrelated reason: nothing
/// in the record is ever moved aside or overwritten, so this bounds how
/// large a single file somebody opens in `less` gets, not how much disk
/// the record takes. See "the record" below.
pub const day_bytes: u64 = 8 * 1024 * 1024;

/// Longest one name's directory component may get once encoded.
pub const max_segment: usize = 200;

/// Open for reading and writing, creating with 0600 if it is not there.
///
/// Owner-only because the contents are code, file paths and stack traces
/// out of the user's own work -- a real privacy surface rather than a
/// formality. Same reasoning, and the same mode, as the ssh cache.
///
/// Readable as well as writable because recovering the seq and paging
/// backwards both have to read the very file this handle is appending to.
/// A second read-only handle would work and would be worse: two views of
/// one file, one of them not knowing about `written`, and a page that
/// stops just short of the message somebody is scrolling up to find.
pub fn openAppend(io: std.Io, path: []const u8) !std.Io.File {
    const file = std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = false,
        .permissions = if (builtin.os.tag != .windows and std.posix.mode_t != u0)
            .fromMode(0o600)
        else
            .default_file,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => try std.Io.Dir.openFileAbsolute(
            io,
            path,
            .{ .mode = .read_write },
        ),
        else => return err,
    };
    return file;
}

// -- the record -------------------------------------------------------------
//
// Two shapes, and the difference between them is the whole of this half of
// the file.
//
// `chat.jsonl` is the **stream**. One flat file, rotated by size, two
// generations. It is what the archive follows, and everything that makes
// following it cheap -- one file, one offset, one inode -- rests on it
// staying that shape. Being bounded, it forgets.
//
// `<group>/<YYYY-MM-DD>.jsonl` is the **record**. It is what a person greps
// at nine the next morning and what `group_history` pages through. Nothing
// in it is ever rotated, renamed or removed, so it reaches back further
// than the stream does: the record, not the stream, is the more complete of
// the two. Which is why "if the record breaks, replay the stream" is a
// promise made nowhere here -- it would only ever be true of the last 16MB.
//
// Why group and day, rather than size. A group is the unit a person already
// thinks in ("that Kairos business last night"), and a day is the only
// boundary that is naturally bounded -- a group can live for months, a day
// cannot. The boundaries size-based rotation produces mean nothing to
// anybody: no one has ever wanted to read the second generation.
//
// The record has no size ceiling, and that is what "nothing is ever
// removed" means when written out. The machine this was built on holds
// 2.8MB of chat from a fortnight, so the honest thing is to say the number
// rather than to build a mechanism for it.

/// The record: one directory per group, one file per day, under `dir`.
pub const Tree = struct {
    /// Given a file and its length, the largest sequence number in it.
    pub const Probe = *const fn (
        alloc: Allocator,
        io: std.Io,
        file: std.Io.File,
        end: u64,
    ) ?u64;

    alloc: Allocator,
    io: std.Io,

    /// The root the per-name directories hang under -- `<state>/chat` for
    /// the chat record, `<state>/terminals` for the terminal transcript.
    /// Borrowed from whoever owns the tree.
    dir: []const u8,

    /// What this tree calls itself in a warning. Borrowed and static.
    label: []const u8 = "day log",

    /// How to read the highest sequence number back out of a finished
    /// file, or null when the lines here carry no such number.
    ///
    /// A tree stores whatever bytes it is handed, so it cannot know what a
    /// sequence number looks like in them -- the chat record numbers every
    /// line and needs `head` to find where to resume filling in; a
    /// terminal transcript numbers nothing and never asks. Null is the
    /// honest answer for the second: `head` then says "cannot tell", which
    /// is exactly what its callers already have to handle.
    probe: ?Probe = null,

    /// The day file being appended to, if any.
    ///
    /// One at a time rather than one per group: messages arrive one at a
    /// time, and the open a group switch costs is nothing beside the work
    /// that produced the message.
    cur: ?Cur = null,

    /// Reading and writing fail the way the stream's do: once out loud,
    /// then quietly.
    warned: bool = false,

    const Cur = struct {
        /// The raw group name, so that a switch is noticed without
        /// encoding every message's group a second time. Owned.
        group: []const u8,
        day: u32,
        part: u32,
        file: std.Io.File,
        written: u64,
    };

    /// One file in a group's directory, as its name says it is.
    pub const DayFile = struct {
        day: u32,
        part: u32,

        /// Newest first, which is the direction `history` walks.
        fn newestFirst(_: void, a: DayFile, b: DayFile) bool {
            if (a.day != b.day) return a.day > b.day;
            return a.part > b.part;
        }
    };

    pub const Days = std.ArrayListUnmanaged(DayFile);

    const Opened = struct { file: std.Io.File, written: u64 };

    /// A wall against a day that never stops. Eight gigabytes in one group
    /// on one day is not a case worth carrying code for; past it the last
    /// part simply keeps growing, which loses nothing.
    const max_parts: u32 = 1000;

    pub fn deinit(self: *Tree) void {
        self.close();
        self.* = undefined;
    }

    pub fn close(self: *Tree) void {
        if (self.cur) |*c| {
            c.file.close(self.io);
            self.alloc.free(c.group);
        }
        self.cur = null;
    }

    /// Put one already-rendered line into its group's file for the day.
    ///
    /// Handed the bytes `append` has just written to the stream rather than
    /// rendering them again: the two files then hold the same line byte for
    /// byte, and there is no second renderer to drift.
    ///
    /// **Every failure here is a warning and nothing else, deliberately.**
    /// The stream is what the archive follows and what hands out seq; a full
    /// disk or an unwritable directory must not turn "the record is worse
    /// off" into "the message is gone". It is also why a later reader should
    /// not "fix" this by propagating the error: a gap left here is found and
    /// filled by `backfill` on the next start, because how far the record
    /// goes is measured off the files rather than remembered.
    pub fn write(self: *Tree, group: []const u8, at_ms: i64, line: []const u8) void {
        self.ensure(group, dayOf(at_ms), line.len) catch |err| {
            self.warnOnce(err);
            return;
        };

        const c = &self.cur.?;
        c.file.writePositionalAll(self.io, line, c.written) catch |err| {
            self.warnOnce(err);
            // Closed rather than kept: reopening on the next message is
            // the cheapest thing that can recover a handle which has gone
            // bad underneath us.
            self.close();
            return;
        };
        c.written += line.len;
    }

    /// Leave `cur` open on the file this message belongs in.
    pub fn ensure(self: *Tree, group: []const u8, day: u32, want: usize) !void {
        if (self.cur) |*c| {
            if (c.day == day and std.mem.eql(u8, c.group, group)) {
                if (c.written + want <= day_bytes) return;

                // The day is not over, so the day does not end here. It
                // carries on in the part beside it, and nothing is moved
                // aside or dropped to make room.
                const opened = try self.openPart(group, day, c.part + 1);
                c.file.close(self.io);
                c.file = opened.file;
                c.part += 1;
                c.written = opened.written;
                return;
            }
        }

        self.close();

        // How far into the day the parts have got. Probed rather than
        // assumed, because a restart in the middle of a busy day has to
        // land on the end of it and not on top of its beginning.
        var part: u32 = 1;
        var opened = try self.openPart(group, day, part);
        while (opened.written + want > day_bytes and part < max_parts) {
            opened.file.close(self.io);
            part += 1;
            opened = try self.openPart(group, day, part);
        }
        errdefer opened.file.close(self.io);

        const owned = try self.alloc.dupe(u8, group);
        self.cur = .{
            .group = owned,
            .day = day,
            .part = part,
            .file = opened.file,
            .written = opened.written,
        };
    }

    /// Open one part for appending, making the group's directory if it is
    /// not there yet.
    pub fn openPart(self: *Tree, group: []const u8, day: u32, part: u32) !Opened {
        const path = try self.partPath(self.alloc, group, day, part);
        defer self.alloc.free(path);

        if (std.fs.path.dirname(path)) |parent| {
            std.Io.Dir.cwd().createDirPath(self.io, parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        const file = try openAppend(self.io, path);
        errdefer file.close(self.io);

        var written = if (file.stat(self.io)) |st| st.size else |_| 0;

        // The same invariant the stream keeps, for the same reason: a
        // newline ends a line and nothing else does, so a run that died
        // mid-write does not get its half line joined onto the next one.
        if (written > 0) {
            var last: [1]u8 = undefined;
            const n = file.readPositionalAll(self.io, &last, written - 1) catch 0;
            if (n == 1 and last[0] != '\n') {
                file.writePositionalAll(self.io, "\n", written) catch {};
                written += 1;
            }
        }

        return .{ .file = file, .written = written };
    }

    /// `<dir>/<encoded group>/<YYYY-MM-DD>.jsonl`, or `.partN.jsonl` past
    /// the first. Caller owns it.
    pub fn partPath(
        self: *const Tree,
        alloc: Allocator,
        group: []const u8,
        day: u32,
        part: u32,
    ) Allocator.Error![]u8 {
        const seg = try encodeSegment(alloc, group);
        defer alloc.free(seg);

        var buf: [64]u8 = undefined;
        return std.fs.path.join(alloc, &.{ self.dir, seg, nameOf(&buf, .{
            .day = day,
            .part = part,
        }) });
    }

    /// What a day file is called.
    fn nameOf(buf: *[64]u8, d: DayFile) []const u8 {
        var ymd: [16]u8 = undefined;
        return (if (d.part <= 1)
            std.fmt.bufPrint(buf, "{s}.jsonl", .{dayName(&ymd, d.day)})
        else
            std.fmt.bufPrint(buf, "{s}.part{d}.jsonl", .{ dayName(&ymd, d.day), d.part })) catch
            unreachable;
    }

    /// `YYYY-MM-DD` out of the packed `YYYYMMDD` a day is carried as.
    ///
    /// Packed as one integer rather than carried as a string because it is
    /// also the sort key `history` walks by, and comparing two `u32` needs
    /// nothing to own or free.
    fn dayName(buf: *[16]u8, day: u32) []const u8 {
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
            day / 10000,
            (day / 100) % 100,
            day % 100,
        }) catch unreachable;
    }

    /// The day file `name` is, or null when it is not one.
    fn parseDayFile(name: []const u8) ?DayFile {
        if (!std.mem.endsWith(u8, name, ".jsonl")) return null;
        const stem = name[0 .. name.len - ".jsonl".len];
        if (stem.len < 10) return null;

        const day = parseDay(stem[0..10]) orelse return null;
        const rest = stem[10..];
        if (rest.len == 0) return .{ .day = day, .part = 1 };

        if (!std.mem.startsWith(u8, rest, ".part")) return null;
        const n = std.fmt.parseUnsigned(u32, rest[".part".len..], 10) catch return null;

        // `.part1` is not a name this writes, so a file called that came
        // from somewhere else and would sort into the same place as the
        // day's first part.
        if (n < 2) return null;
        return .{ .day = day, .part = n };
    }

    /// `YYYY-MM-DD` back into the packed integer, or null.
    fn parseDay(s: []const u8) ?u32 {
        if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
        const y = std.fmt.parseUnsigned(u32, s[0..4], 10) catch return null;
        const m = std.fmt.parseUnsigned(u32, s[5..7], 10) catch return null;
        const d = std.fmt.parseUnsigned(u32, s[8..10], 10) catch return null;
        if (m < 1 or m > 12 or d < 1 or d > 31) return null;
        return y * 10000 + m * 100 + d;
    }

    /// Every day file a group has, newest first. Caller owns the list.
    pub fn days(self: *const Tree, alloc: Allocator, group: []const u8) Allocator.Error!Days {
        const seg = try encodeSegment(alloc, group);
        defer alloc.free(seg);
        return self.daysIn(alloc, seg);
    }

    /// The same, for a directory name that is already encoded.
    pub fn daysIn(self: *const Tree, alloc: Allocator, seg: []const u8) Allocator.Error!Days {
        var out: Days = .empty;
        errdefer out.deinit(alloc);

        const path = try std.fs.path.join(alloc, &.{ self.dir, seg });
        defer alloc.free(path);

        // A group nothing was ever said in has no directory, and that is
        // an answer rather than a failure: it has no days.
        var d = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return out;
        defer d.close(self.io);

        var it = d.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind == .directory) continue;
            const parsed = parseDayFile(entry.name) orelse continue;
            try out.append(alloc, parsed);
        }

        std.mem.sort(DayFile, out.items, {}, DayFile.newestFirst);
        return out;
    }

    /// The highest seq the record already holds, or null when that cannot
    /// be worked out.
    ///
    /// Null is a real answer and the callers are written to know it. The
    /// only thing that reads this is `backfill`, and filling in from a
    /// floor nobody is sure of would write a second copy of messages that
    /// are already there. A record short by a stretch is fixed by the next
    /// start; a record holding everything twice is fixed by nothing.
    pub fn head(self: *Tree) ?u64 {
        if (self.probe == null) return null;
        var d = std.Io.Dir.cwd().openDir(self.io, self.dir, .{ .iterate = true }) catch
            return null;
        defer d.close(self.io);

        var best: u64 = 0;
        var it = d.iterate();
        while (it.next(self.io) catch null) |entry| {
            // `readdir` reports `unknown` on some filesystems, and the flat
            // stream files live in this directory too.
            const kind = if (entry.kind != .unknown) entry.kind else k: {
                const st = d.statFile(self.io, entry.name, .{
                    .follow_symlinks = false,
                }) catch continue;
                break :k st.kind;
            };
            if (kind != .directory) continue;

            const got = self.groupHead(entry.name) orelse return null;
            best = @max(best, got);
        }
        return best;
    }

    /// The highest seq in one group's newest day file, or null when it
    /// holds lines but none that can be read.
    ///
    /// The newest file is enough: the record is written in seq order, so a
    /// group's largest number is always in its last file.
    pub fn groupHead(self: *Tree, seg: []const u8) ?u64 {
        var list = self.daysIn(self.alloc, seg) catch return null;
        defer list.deinit(self.alloc);

        // A directory with no day files in it is not part of the record.
        if (list.items.len == 0) return 0;

        var buf: [64]u8 = undefined;
        const path = std.fs.path.join(self.alloc, &.{
            self.dir,
            seg,
            nameOf(&buf, list.items[0]),
        }) catch return null;
        defer self.alloc.free(path);

        const file = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch return null;
        defer file.close(self.io);

        const probe = self.probe orelse return null;
        const end = if (file.stat(self.io)) |st| st.size else |_| return null;
        if (end == 0) return 0;
        return probe(self.alloc, self.io, file, end);
    }

    fn warnOnce(self: *Tree, err: anyerror) void {
        if (self.warned) return;
        self.warned = true;
        log.warn(
            "{s}: could not write the record under {s} err={}",
            .{ self.label, self.dir, err },
        );
    }
};

/// A group name as one path segment, and nothing else.
///
/// Every byte outside `[A-Za-z0-9._-]` becomes `%XX`, and a leading `.` is
/// escaped as well -- which is what disposes of `.`, `..` and hidden
/// directories in one rule rather than three special cases.
///
/// **Injective, and that is the requirement.** Replacing the awkward bytes
/// with `_` would be shorter and would put `a/b` and `a_b` in the same
/// directory, silently interleaving two groups' records. Percent-encoding
/// keeps every distinct name distinct while leaving the ordinary ones
/// exactly as they were: `kairos-15r` stays `kairos-15r`.
///
/// `Chat.isValidName` already holds group names to 48 bytes of
/// `[a-z0-9-]`, so nothing arriving through the model needs any of this.
/// It is here for what does not arrive that way -- a line read back out of
/// a hand-edited file, or a caller that went around the model -- because a
/// path built out of somebody else's string is exactly the kind of thing
/// that should not depend on a check made in another file.
pub fn encodeSegment(alloc: Allocator, group: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, group.len + 24);

    var truncated = false;
    for (group, 0..) |c, i| {
        // Whole units only, so the cut below can never land inside a `%XX`
        // and turn one name into a prefix of another.
        if (out.items.len + 3 > max_segment - 20) {
            truncated = true;
            break;
        }

        const plain = switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => true,
            // A leading dot is the whole of what makes `.` and `..`, so it
            // is the one position where a dot is not plain.
            '.' => i != 0,
            else => false,
        };

        if (plain) {
            try out.append(alloc, c);
        } else {
            const hex = "0123456789ABCDEF";
            try out.appendSlice(alloc, &[_]u8{ '%', hex[c >> 4], hex[c & 0xf] });
        }
    }

    if (truncated) {
        // `%%` cannot come out of the loop above -- every `%` it writes is
        // followed by two hex digits -- so this marks a shortened name
        // unambiguously, and the hash keeps two long names apart.
        var buf: [20]u8 = undefined;
        const tag = std.fmt.bufPrint(&buf, "%%{x:0>16}", .{
            std.hash.Wyhash.hash(0, group),
        }) catch unreachable;
        try out.appendSlice(alloc, tag);
    }

    // An empty name would be no segment at all, which would put the file
    // straight into `chat/` beside the stream. One byte that the loop
    // cannot produce says "empty" without colliding with anything.
    if (out.items.len == 0) try out.append(alloc, '%');

    return out.toOwnedSlice(alloc);
}

/// `struct tm`, declared here because the standard library has no binding
/// for it and no timezone handling of its own.
///
/// Declared in full even though three fields are read: `localtime_r` writes
/// into whatever it is given, so a struct short by a field is a buffer
/// overrun. The first nine are POSIX; the last two are a BSD extension that
/// both macOS and glibc have.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timep: *const i64, result: *Tm) ?*Tm;

/// Which day a message belongs to, packed as `YYYYMMDD`.
///
/// The reader's own day rather than UTC, for the same reason the chat
/// window shows local times: somebody asking what happened last night means
/// their night. A file dated eight hours off is worse than no date at all,
/// because it looks right.
///
/// UTC is the fallback rather than the rule -- if libc will not say, a day
/// that may be off by one still beats no file to write into.
pub fn dayOf(at_ms: i64) u32 {
    const secs: i64 = @divFloor(at_ms, std.time.ms_per_s);

    var tm: Tm = undefined;
    if (localtime_r(&secs, &tm) != null) {
        const y: i64 = @as(i64, tm.year) + 1900;
        const m: i64 = @as(i64, tm.mon) + 1;
        const d: i64 = tm.mday;
        if (y >= 0 and y <= 9999 and m >= 1 and m <= 12 and d >= 1 and d <= 31)
            return @intCast(y * 10000 + m * 100 + d);
    }

    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(secs, 0)) };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return @as(u32, yd.year) * 10000 +
        @as(u32, md.month.numeric()) * 100 +
        md.day_index + 1;
}

/// `YYYY-MM-DD HH:MM:SS`, in the reader's own timezone.
///
/// Here rather than in the one file that needs it, because this file
/// already owns the answer to "what does Polter call a moment in time on
/// disk" -- `dayOf` names the day the same way, off the same `localtime_r`,
/// for the same reason. A second formatter somewhere else would be a second
/// answer, and the two would eventually disagree about the timezone, which
/// is the one thing about a timestamp nobody checks.
///
/// Local rather than UTC, and `dayOf`'s reason applies unchanged: somebody
/// reading a plugin's log at nine the next morning is asking what happened
/// *last night*, and a line stamped eight hours off is worse than a line
/// with no stamp at all, because it looks right.
pub fn stamp(buf: *[19]u8, at_ms: i64) []const u8 {
    const secs: i64 = @divFloor(at_ms, std.time.ms_per_s);

    var tm: Tm = undefined;
    if (localtime_r(&secs, &tm) != null) return render(buf, .{
        .y = @as(i64, tm.year) + 1900,
        .mo = @as(i64, tm.mon) + 1,
        .d = tm.mday,
        .h = tm.hour,
        .mi = tm.min,
        .s = tm.sec,
    });

    // Same fallback as `dayOf`: if libc will not say, a stamp that may be
    // hours off still beats a line with nothing on it.
    const day = dayOf(at_ms);
    const in_day: i64 = @mod(secs, std.time.s_per_day);
    return render(buf, .{
        .y = day / 10000,
        .mo = @mod(@divTrunc(day, 100), 100),
        .d = @mod(day, 100),
        .h = @divTrunc(in_day, std.time.s_per_hour),
        .mi = @mod(@divTrunc(in_day, std.time.s_per_min), 60),
        .s = @mod(in_day, 60),
    });
}

/// The six numbers, clamped into the widths the format has room for.
///
/// Clamped rather than asserted: `bufPrint` into a buffer sized for four
/// digits of year fails on a five-digit one, and the only thing to do with
/// that failure at the point a log line is being written is to have made it
/// impossible.
fn render(buf: *[19]u8, at: struct { y: i64, mo: i64, d: i64, h: i64, mi: i64, s: i64 }) []const u8 {
    const clamp = struct {
        fn to(v: i64, hi: i64) u32 {
            return @intCast(@min(@max(v, 0), hi));
        }
    };

    return std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}",
        .{
            clamp.to(at.y, 9999),
            clamp.to(at.mo, 12),
            clamp.to(at.d, 31),
            clamp.to(at.h, 23),
            clamp.to(at.mi, 59),

            // 60 and 61 are legal in `struct tm`, which has leap seconds.
            clamp.to(at.s, 59),
        },
    ) catch unreachable;
}

const testing = std.testing;

test "a stamp is a fixed nineteen characters, whatever the moment" {
    // Fixed width is the point: these lines are read in a column, and a
    // stamp that is sometimes eighteen characters makes every line after it
    // in a `less` window land somewhere else.
    for ([_]i64{
        0,
        1,
        -1,
        1_786_819_271_275,
        std.math.maxInt(i32) * @as(i64, 1000),

        // Past what four digits of year can hold, which is where a
        // formatter that trusted its input would fail rather than clamp.
        300_000_000_000_000,
    }) |at_ms| {
        var buf: [19]u8 = undefined;
        const said = stamp(&buf, at_ms);
        try testing.expectEqual(@as(usize, 19), said.len);
        try testing.expectEqual(@as(u8, '-'), said[4]);
        try testing.expectEqual(@as(u8, '-'), said[7]);
        try testing.expectEqual(@as(u8, ' '), said[10]);
        try testing.expectEqual(@as(u8, ':'), said[13]);
        try testing.expectEqual(@as(u8, ':'), said[16]);
    }
}

test "an ordinary name comes through a directory name unchanged" {
    const alloc = testing.allocator;

    const plain = try encodeSegment(alloc, "kairos-15r");
    defer alloc.free(plain);
    try testing.expectEqualStrings("kairos-15r", plain);
}

test "a name that means somewhere else is still one path segment" {
    const alloc = testing.allocator;

    // Every one of these would escape the tree if it were used raw, and
    // none of them may come out holding a separator or a lone dot.
    for ([_][]const u8{
        "a/b",
        "..",
        ".",
        "../../etc/passwd",
        ".hidden",
        "",
        "with space",
        "\x00null",
    }) |name| {
        const seg = try encodeSegment(alloc, name);
        defer alloc.free(seg);

        try testing.expect(seg.len > 0);
        try testing.expect(std.mem.indexOfScalar(u8, seg, '/') == null);
        try testing.expect(std.mem.indexOfScalar(u8, seg, 0) == null);
        try testing.expect(seg[0] != '.');
        try testing.expect(!std.mem.eql(u8, seg, "."));
        try testing.expect(!std.mem.eql(u8, seg, ".."));
    }
}

test "two names that differ end up in two directories" {
    const alloc = testing.allocator;

    // The point of percent-encoding rather than replacing the awkward
    // bytes: `a/b` and `a_b` must not share a directory.
    const a = try encodeSegment(alloc, "a/b");
    defer alloc.free(a);
    const b = try encodeSegment(alloc, "a_b");
    defer alloc.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));

    const dot = try encodeSegment(alloc, ".");
    defer alloc.free(dot);
    const dots = try encodeSegment(alloc, "..");
    defer alloc.free(dots);
    try testing.expect(!std.mem.eql(u8, dot, dots));
}

test "a name too long to be a directory is cut, marked, and still distinct" {
    const alloc = testing.allocator;

    var one: [400]u8 = @splat('x');
    var two: [400]u8 = @splat('x');
    two[399] = 'y';

    const a = try encodeSegment(alloc, &one);
    defer alloc.free(a);
    const b = try encodeSegment(alloc, &two);
    defer alloc.free(b);

    try testing.expect(a.len <= max_segment);
    try testing.expect(b.len <= max_segment);

    // `%%` is a sequence the encoder itself cannot produce, so it says
    // "shortened here" without any chance of being read as data.
    try testing.expect(std.mem.indexOf(u8, a, "%%") != null);

    // Two long names that differ only past the cut still land apart.
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "the day a moment belongs to is also the order the days sort in" {
    // Same instant, so the same day, whatever the machine's timezone is.
    const at: i64 = 1_724_800_000_000;
    try testing.expectEqual(dayOf(at), dayOf(at));

    const day = dayOf(at);
    const y = day / 10000;
    const m = (day / 100) % 100;
    const d = day % 100;
    try testing.expect(y >= 2024 and y <= 9999);
    try testing.expect(m >= 1 and m <= 12);
    try testing.expect(d >= 1 and d <= 31);

    // Packed `YYYYMMDD` is a sort key: later is larger, and it stays so
    // across the month and year boundaries a plain field-wise compare
    // would get wrong.
    try testing.expect(dayOf(at) < dayOf(at + 40 * std.time.ms_per_day));
    try testing.expect(dayOf(at) < dayOf(at + 400 * std.time.ms_per_day));
}

test "a day file's name says which day and which part it is" {
    var buf: [64]u8 = undefined;

    const first = Tree.nameOf(&buf, .{ .day = 20260828, .part = 1 });
    try testing.expectEqualStrings("2026-08-28.jsonl", first);

    const second = Tree.nameOf(&buf, .{ .day = 20260828, .part = 2 });
    try testing.expectEqualStrings("2026-08-28.part2.jsonl", second);

    // And back again, because listing a directory is how the parts of a
    // day are found.
    const parsed = Tree.parseDayFile("2026-08-28.part2.jsonl").?;
    try testing.expectEqual(@as(u32, 20260828), parsed.day);
    try testing.expectEqual(@as(u32, 2), parsed.part);

    try testing.expectEqual(@as(u32, 1), Tree.parseDayFile("2026-08-28.jsonl").?.part);

    // `.part1` is not a name this writes, so a file called that came from
    // somewhere else and must not sort on top of the day's first part.
    try testing.expect(Tree.parseDayFile("2026-08-28.part1.jsonl") == null);
    try testing.expect(Tree.parseDayFile("2026-08-28.txt") == null);
    try testing.expect(Tree.parseDayFile("notes.jsonl") == null);
    try testing.expect(Tree.parseDayFile("2026-13-28.jsonl") == null);
}

test "a tree whose lines carry no number says so rather than guessing" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tree: Tree = .{ .alloc = alloc, .io = io, .dir = ".", .label = "test log" };
    defer tree.deinit();

    // No probe means the lines here hold no sequence number, and `head`
    // must answer "cannot tell" rather than 0 -- a caller that took 0 for
    // an answer would fill the record in from the beginning again.
    try testing.expect(tree.head() == null);
}
