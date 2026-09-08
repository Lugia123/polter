const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const global = @import("../global.zig");
// **The array, not the module.** It was imported as the module, and the two
// declarations that use it -- `locales_map` and `staticLocale` -- were written
// against the array. Neither compiled, and neither had to: nothing in the tree
// referenced them, and Zig does not analyse a container-level declaration
// nobody uses. See the test at the bottom of this file, which is what now
// forces both to be compiled on every build.
const locales = @import("i18n_locales.zig").locales;

const log = std.log.scoped(.i18n);

/// Set for faster membership lookup of locales.
pub const locales_map = map: {
    var kvs: [locales.len]struct { []const u8 } = undefined;
    for (locales, 0..) |locale, i| kvs[i] = .{locale};
    break :map std.StaticStringMap(void).initComptime(kvs);
};

pub const InitError = error{
    InvalidResourcesDir,
    OutOfMemory,
};

/// Initialize i18n support for the application. This should be
/// called automatically by the global state initialization
/// in global.zig.
///
/// This calls `bindtextdomain` for gettext with the proper directory
/// of translations. This does NOT call `textdomain` as we don't
/// want to set the domain for the entire application since this is also
/// used by libghostty.
pub fn init(resources_dir: []const u8) InitError!void {
    if (comptime !build_config.i18n) return;

    switch (builtin.os.tag) {
        // **Windows has no libintl to bind a domain to.** It reads the
        // installed catalogue itself; `loadWindowsCatalog` is the whole of
        // it and `_` below is the only thing that consults the result.
        .windows => {
            const share_dir = std.fs.path.dirname(resources_dir) orelse
                return error.InvalidResourcesDir;
            windows_catalog = loadWindowsCatalog(share_dir);
        },

        else => {
            // Our resources dir is always nested below the share dir that
            // is standard for translations.
            const share_dir = std.fs.path.dirname(resources_dir) orelse
                return error.InvalidResourcesDir;

            // Build our locale path
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrintZ(&buf, "{s}/locale", .{share_dir}) catch
                return error.OutOfMemory;

            // Bind our bundle ID to the given locale path
            log.debug("binding domain={s} path={s}", .{ build_config.bundle_id, path });
            _ = bindtextdomain(build_config.bundle_id, path.ptr) orelse
                return error.OutOfMemory;
        },
    }
}

/// Set the global gettext domain to our bundle ID, allowing unqualified
/// `gettext` (`_`) calls to look up translations for our application.
///
/// This should only be called for apprts that are fully owning the
/// Ghostty application. This should not be called for libghostty users.
pub fn initGlobalDomain() error{OutOfMemory}!void {
    if (comptime !build_config.i18n) return;
    switch (builtin.os.tag) {
        // **There is no global domain here to set.** `_` reads the one
        // catalogue `init` loaded for this application, and a libghostty
        // user on Windows gets the same one -- the separation this call
        // exists to preserve is a libintl concept that does not apply.
        .windows => return,

        else => _ = textdomain(build_config.bundle_id) orelse
            return error.OutOfMemory,
    }
}

/// Translate a message for the Ghostty domain.
///
/// If this is called at comptime, the direct msgid is returned without
/// translation. This still allows the string to be marked for translation
/// while remaining usable in comptime contexts.
pub fn _(msgid: [*:0]const u8) [*:0]const u8 {
    if (comptime !build_config.i18n) return msgid;
    if (@inComptime()) return msgid;

    switch (builtin.os.tag) {
        // **Windows does not link gettext**; see `Mo` below.
        //
        // ⚠️ **There is no `bind_textdomain_codeset` here and none is
        // needed.** Under libintl that call stops the library recoding the
        // catalogue's UTF-8 into the process's ANSI code page on the way
        // out. Nothing here recodes anything: the pointer this returns
        // points at the bytes `msgfmt` wrote, and those are UTF-8 because
        // every `.po` in `po/` is. A build that instead *linked* libintl
        // for Windows would need the call, which is why it is written down
        // rather than left to be noticed.
        .windows => {
            const mo = windows_catalog orelse return msgid;
            const found = mo.lookup(std.mem.span(msgid)) orelse return msgid;
            return found.ptr;
        },

        else => return dgettext(build_config.bundle_id, msgid),
    }
}

/// Mark a string for translation without translating it immediately.
pub fn N_(msgid: [:0]const u8) [:0]const u8 {
    return msgid;
}

/// Canonicalize a locale name from a platform-specific value to
/// a POSIX-compliant value. This is a thin layer over the unexported
/// gnulib-lib function in gettext that does this already.
///
/// The gnulib-lib function modifies the buffer in place but has
/// zero bounds checking, so we do a bit extra to ensure we don't
/// overflow the buffer. This is likely slightly more expensive but
/// this isn't a hot path so it should be fine.
///
/// The buffer must be at least 16 bytes long. This ensures we can
/// fit the longest possible hardcoded locale name. Additionally,
/// it should be at least as long as locale in case the locale
/// is unchanged.
///
/// Here is the logic for macOS, but other platforms also have
/// their own canonicalization logic:
///
/// https://github.com/coreutils/gnulib/blob/5b92dd0a45c8d27f13a21076b57095ea5e220870/lib/localename.c#L1171
pub fn canonicalizeLocale(
    buf: []u8,
    locale: []const u8,
) error{NoSpaceLeft}![:0]const u8 {
    if (comptime !build_config.i18n) {
        if (buf.len < locale.len + 1) return error.NoSpaceLeft;
        @memcpy(buf[0..locale.len], locale);
        buf[locale.len] = 0;
        return buf[0..locale.len :0];
    }

    // Fix zh locales for macOS
    if (fixZhLocale(locale)) |fixed| {
        if (buf.len < fixed.len + 1) return error.NoSpaceLeft;
        @memcpy(buf[0..fixed.len], fixed);
        buf[fixed.len] = 0;
        return buf[0..fixed.len :0];
    }

    // **Windows has no libintl to hand the rest to.** Nothing on this
    // platform calls this today -- its only caller is the Cocoa path in
    // `os/locale.zig` -- but a `pub` function whose body would not link is
    // a trap laid for whoever calls it first. The zh mapping above still
    // applies; what is skipped is only the gnulib canonicalizer.
    if (comptime builtin.os.tag == .windows) {
        if (buf.len < locale.len + 1) return error.NoSpaceLeft;
        @memcpy(buf[0..locale.len], locale);
        buf[locale.len] = 0;
        return buf[0..locale.len :0];
    }

    // Buffer must be 16 or at least as long as the locale and null term
    if (buf.len < @max(16, locale.len + 1)) return error.NoSpaceLeft;

    // Copy our locale into the buffer since it modifies in place.
    // This must be null-terminated.
    @memcpy(buf[0..locale.len], locale);
    buf[locale.len] = 0;

    _libintl_locale_name_canonicalize(buf[0..locale.len :0]);

    // Convert the null-terminated result buffer into a slice. We
    // need to search for the null terminator and slice it back.
    // We have to use `buf` since `slice` len will exclude the
    // null.
    const slice = std.mem.sliceTo(buf, 0);
    return buf[0..slice.len :0];
}

/// Handles some zh locales canonicalization because internal libintl
/// canonicalization function doesn't handle correctly in these cases.
fn fixZhLocale(locale: []const u8) ?[:0]const u8 {
    var it = std.mem.splitScalar(u8, locale, '-');
    const name = it.next() orelse return null;
    if (!std.mem.eql(u8, name, "zh")) return null;

    const script = it.next() orelse return null;
    const region = it.next() orelse return null;

    if (std.mem.eql(u8, script, "Hans")) {
        if (std.mem.eql(u8, region, "SG")) return "zh_SG";
        return "zh_CN";
    }

    if (std.mem.eql(u8, script, "Hant")) {
        if (std.mem.eql(u8, region, "MO")) return "zh_MO";
        if (std.mem.eql(u8, region, "HK")) return "zh_HK";
        return "zh_TW";
    }

    return null;
}

/// This can be called at any point a compile-time-known locale is
/// available. This will use comptime to verify the locale is supported.
pub fn staticLocale(comptime v: [*:0]const u8) [*:0]const u8 {
    return comptime found: {
        for (locales) |locale| {
            if (std.mem.eql(u8, locale, std.mem.span(v))) break :found locale;
        }

        @compileError("unsupported locale: " ++ std.mem.span(v));
    };
}

// Manually include function definitions for the gettext functions
// as libintl.h isn't always easily available (e.g. in musl)
extern fn bindtextdomain(domainname: [*:0]const u8, dirname: [*:0]const u8) ?[*:0]const u8;
extern fn textdomain(domainname: [*:0]const u8) ?[*:0]const u8;
extern fn dgettext(domainname: [*:0]const u8, msgid: [*:0]const u8) [*:0]const u8;

// This is only available if we're building libintl from source
// since its otherwise not exported. We only need it on macOS
// currently but probably will on Windows as well.
extern fn _libintl_locale_name_canonicalize(name: [*:0]u8) void;

// -- Finding and loading the catalogue on Windows ----------------------------

/// The catalogue `init` found, if it found one.
///
/// **Written once, by `init`, before any other thread exists**, and read
/// without a lock thereafter -- `global.zig` calls `init` from the same place
/// it sets up everything else, long before a surface or a renderer starts.
///
/// The bytes it points into are allocated from the page allocator and
/// deliberately never freed: `_` hands pointers straight into them to C
/// callers who keep them, so there is no moment at which freeing would be
/// safe. The page allocator rather than the global GPA so that a leak which
/// is the design does not get reported as one that is not.
var windows_catalog: ?Mo = null;

/// `GetUserDefaultLocaleName` writes a BCP-47 name -- `de-DE`, `zh-Hans-CN` --
/// into a buffer of at most `LOCALE_NAME_MAX_LENGTH` (85) WTF-16 units.
///
/// Declared here rather than in `os/windows.zig` because it is the only
/// caller and because everything this platform does differently about
/// translation is meant to be readable in one file.
extern "kernel32" fn GetUserDefaultLocaleName(
    lpLocaleName: [*]u16,
    cchLocaleName: i32,
) callconv(.winapi) i32;

/// The locale the user asked for, in whatever spelling the source uses.
///
/// `LANG` first, so the override every other platform has works here too --
/// it is also the only way a test or a bug report can ask for a specific
/// language without changing a system setting.
fn windowsRequestedLocale(buf: []u8) ?[]const u8 {
    if (global.environ().getAlloc(global.alloc(), "LANG")) |v| {
        defer global.alloc().free(v);
        if (v.len > 0 and v.len <= buf.len) {
            @memcpy(buf[0..v.len], v);
            return buf[0..v.len];
        }
    } else |_| {}

    var wide: [85]u16 = undefined;
    const n = GetUserDefaultLocaleName(&wide, wide.len);
    // The count includes the terminator, so 0 and 1 are both "nothing".
    if (n <= 1) return null;
    const written = std.unicode.utf16LeToUtf8(buf, wide[0 .. @as(usize, @intCast(n)) - 1]) catch
        return null;
    return buf[0..written];
}

/// The entry of `i18n_locales.zig` that best answers `requested`, or null if
/// none does.
///
/// **Returns a pointer into that static list**, so there is nothing to free
/// and nothing that can outlive its buffer.
fn matchLocale(requested: []const u8) ?[:0]const u8 {
    // `LANG` carries an encoding suffix (`zh_CN.UTF-8`); the Windows API
    // does not. Everything we install is UTF-8 either way.
    var name = requested;
    if (std.mem.indexOfScalar(u8, name, '.')) |i| name = name[0..i];
    if (name.len == 0) return null;

    // `zh-Hans-CN` and friends. The mapping already existed for macOS, which
    // gets the same spellings out of Cocoa.
    if (fixZhLocale(name)) |fixed| name = fixed;

    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name, 0..) |ch, i| buf[i] = if (ch == '-') '_' else ch;
    const norm = buf[0..name.len];

    for (locales) |l| if (std.mem.eql(u8, l, norm)) return l;

    // Language alone. `i18n_locales.zig` says outright that its ordering is
    // what decides this case: "if we know the user requested `zh` but has no
    // script code, then we'd pick the first locale that matches `zh`".
    const lang = norm[0 .. std.mem.indexOfScalar(u8, norm, '_') orelse norm.len];
    for (locales) |l| {
        if (l.len >= lang.len and
            std.mem.eql(u8, l[0..lang.len], lang) and
            (l.len == lang.len or l[lang.len] == '_')) return l;
    }

    return null;
}

/// Read the installed `.mo` for this user's language.
///
/// **Every failure here is silent to the user and returns null**, which makes
/// `_` return its msgid -- English. There is no state in which this reports a
/// problem by showing something other than a real string.
fn loadWindowsCatalog(share_dir: []const u8) ?Mo {
    const sep = std.fs.path.sep_str;

    var name_buf: [128]u8 = undefined;
    const requested = windowsRequestedLocale(&name_buf) orelse {
        log.info("no locale name from the environment or the OS", .{});
        return null;
    };
    const locale = matchLocale(requested) orelse {
        log.info("no translation shipped for locale={s}", .{requested});
        return null;
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        // `sep_str` rather than a literal slash: `resources_dir` arrives with
        // backslashes from `std.fs.path.join`, and a path that is half one and
        // half the other works but reads, in a log line, like a bug.
        "{s}" ++ sep ++ "locale" ++ sep ++ "{s}" ++ sep ++ "LC_MESSAGES" ++ sep ++ "{s}.mo",
        .{ share_dir, locale, build_config.bundle_id },
    ) catch return null;

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        global.io(),
        path,
        std.heap.page_allocator,
        // The largest catalogue in `po/` compiles to about 31 KB. The limit
        // is here so a file that is not one of ours cannot be read into
        // memory in its entirety before being rejected.
        .limited(8 * 1024 * 1024),
    ) catch |err| {
        log.info("no catalog path={s} err={}", .{ path, err });
        return null;
    };

    const mo = Mo.init(bytes) orelse {
        log.warn("catalog is not a readable .mo path={s}", .{path});
        std.heap.page_allocator.free(bytes);
        return null;
    };

    log.info(
        "loaded catalog locale={s} entries={d} path={s}",
        .{ locale, mo.count, path },
    );
    return mo;
}

// -- A `.mo` catalogue, read without libintl ---------------------------------
//
// **Why the platform has its own gettext.** Every other target goes through
// libintl: `bindtextdomain` tells it where the catalogues are and `dgettext`
// answers out of them. `pkg/libintl` says in its own header that it
// is "only for macOS" and that its `config.h` was generated on a Mac and
// copied in, so pointing a Windows build at libintl means porting a package
// nobody here can test the configuration of. A `.mo` file is a hash table and
// two string tables in a documented format; reading one is the smaller half of
// that job, and it is the half that can be tested on this machine.
//
// **What is deliberately not here**: `msgctxt` (which gettext encodes as
// `context \x04 msgid`, so a lookup for the bare msgid simply misses) and
// plural forms (`msgstr[0]` and friends, stored NUL-separated inside one
// entry, of which this returns the first). Neither is used by any catalogue in
// `po/` -- see `windows/tools/one-form-per-message.py`, which goes red the day
// one is, because on that day this file quietly starts giving the wrong answer
// rather than a missing one.
//
// **Being wrong here costs a fallback, not a crash.** Every rejection below
// returns null, `translate` turns null into the msgid, and the msgid is
// English. That is the same thing a Windows user saw before this existed.
const Mo = struct {
    /// The whole file. Every offset in the tables indexes into this.
    bytes: []const u8,

    /// `.mo` files exist in both byte orders; the magic says which.
    endian: std.builtin.Endian,

    /// Number of strings, and the offsets of the two parallel tables of
    /// `(length, offset)` pairs -- originals and translations.
    count: u32,
    orig: u32,
    trans: u32,

    /// The magic as it reads when the file's byte order matches ours.
    const magic: u32 = 0x950412de;

    /// The header is seven `u32`s: magic, revision, count, originals table,
    /// translations table, hash size, hash offset. The hash table is not used
    /// here -- see `lookup` -- so only the first five are read, and shrinking
    /// this to twenty leaves every test in this file green. It stays at the
    /// format's own header size because that is what makes a file a `.mo`,
    /// not because anything below depends on the last eight bytes existing.
    const header_len = 7 * 4;

    /// `null` for anything this reader will not read. **A file it rejects is
    /// a file whose msgids come back untranslated**, which is the same
    /// outcome as no catalogue at all.
    fn init(bytes: []const u8) ?Mo {
        if (bytes.len < header_len) return null;

        const magic_read = std.mem.readInt(u32, bytes[0..4], .little);
        const endian: std.builtin.Endian = if (magic_read == magic)
            .little
        else if (@byteSwap(magic_read) == magic)
            .big
        else
            return null;

        // Only major revision 0 is defined. A later one may lay the tables
        // out differently, and reading them anyway is how a well-formed file
        // of a format we do not know becomes an out-of-bounds read.
        const revision = std.mem.readInt(u32, bytes[4..8], endian);
        if (revision >> 16 != 0) return null;

        const self: Mo = .{
            .bytes = bytes,
            .endian = endian,
            .count = std.mem.readInt(u32, bytes[8..12], endian),
            .orig = std.mem.readInt(u32, bytes[12..16], endian),
            .trans = std.mem.readInt(u32, bytes[16..20], endian),
        };

        // **`count`, `orig` and `trans` are not checked here.** They were, and
        // both mutations of that check -- deleting it, and computing the
        // table span in wrapping `u32` -- left every test in this file green,
        // because `str` bounds-checks each entry on its own and `lookup`
        // never asks for one past `count`. A second copy of an invariant that
        // no test can tell apart from its absence is a copy that can rot into
        // disagreeing with the first.
        return self;
    }

    /// The `i`th string of the table at `table`, or `null` if its
    /// `(length, offset)` pair does not describe a NUL-terminated run of
    /// bytes inside the file.
    ///
    /// The terminator is checked rather than assumed: `_` hands its result
    /// straight to C as a `[*:0]const u8`, so a length that stops one byte
    /// short of a NUL in a corrupt file would be a read off the end of the
    /// allocation at the *caller's* leisure, far from here.
    fn str(self: Mo, table: u32, i: u32) ?[:0]const u8 {
        const entry: u64 = @as(u64, table) + @as(u64, i) * 8;
        if (entry + 8 > self.bytes.len) return null;
        const at: usize = @intCast(entry);

        const len = std.mem.readInt(u32, self.bytes[at..][0..4], self.endian);
        const off = std.mem.readInt(u32, self.bytes[at + 4 ..][0..4], self.endian);

        // `+ 1` for the terminator, which the format stores but does not
        // count in the length.
        if (@as(u64, off) + @as(u64, len) + 1 > self.bytes.len) return null;
        const start: usize = @intCast(off);
        if (self.bytes[start + len] != 0) return null;

        return self.bytes.ptr[start..][0..len :0];
    }

    /// The translation of `msgid`, or `null` if there is not one.
    ///
    /// **Binary search, not the file's hash table.** The originals table is
    /// required to be sorted bytewise, which is what makes `msgfmt`'s hash
    /// optional; searching it needs no second structure to validate. And if
    /// a file arrives unsorted, the search misses and the caller gets the
    /// msgid -- whereas trusting a hash table means trusting offsets that
    /// were never checked against anything.
    fn lookup(self: Mo, msgid: []const u8) ?[:0]const u8 {
        var lo: u32 = 0;
        var hi: u32 = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const key = self.str(self.orig, mid) orelse return null;
            if (std.mem.order(u8, key, msgid) == .lt) lo = mid + 1 else hi = mid;
        }
        if (lo >= self.count) return null;

        const key = self.str(self.orig, lo) orelse return null;
        if (!std.mem.eql(u8, key, msgid)) return null;

        const value = self.str(self.trans, lo) orelse return null;

        // An entry with an empty translation is one `msgfmt` kept because the
        // `.po` had the msgid and no `msgstr`. Answering with it would blank
        // the string; the msgid is what the user should see.
        if (value.len == 0) return null;

        return value;
    }
};

test "canonicalizeLocale darwin" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const testing = std.testing;
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("en_US", try canonicalizeLocale(&buf, "en_US"));
    try testing.expectEqualStrings("zh_CN", try canonicalizeLocale(&buf, "zh-Hans"));
    try testing.expectEqualStrings("zh_TW", try canonicalizeLocale(&buf, "zh-Hant"));

    try testing.expectEqualStrings("zh_CN", try canonicalizeLocale(&buf, "zh-Hans-CN"));
    try testing.expectEqualStrings("zh_SG", try canonicalizeLocale(&buf, "zh-Hans-SG"));
    try testing.expectEqualStrings("zh_TW", try canonicalizeLocale(&buf, "zh-Hant-TW"));
    try testing.expectEqualStrings("zh_HK", try canonicalizeLocale(&buf, "zh-Hant-HK"));
    try testing.expectEqualStrings("zh_MO", try canonicalizeLocale(&buf, "zh-Hant-MO"));

    // This is just an edge case I want to make sure we're aware of:
    // canonicalizeLocale does not handle encodings and will turn them into
    // underscores. We should parse them out before calling this function.
    try testing.expectEqualStrings("en_US.UTF_8", try canonicalizeLocale(&buf, "en_US.UTF-8"));
}

test "_ returns msgid at comptime" {
    const testing = std.testing;

    const msgid = comptime @"_"("Ghostty");
    try testing.expectEqualStrings("Ghostty", std.mem.span(msgid));
}

// -- Tests for the `.mo` reader ----------------------------------------------
//
// These run on every platform, not just Windows: the reader is plain byte
// handling, and a parser that is only compiled for the machine nobody here
// has is a parser nobody here has run.

/// A `.mo` built from `pairs`, which **must be sorted bytewise by msgid** --
/// the format requires it and `lookup` relies on it.
///
/// This exists so the malformed cases below can each start from a file that
/// is known good and change exactly one thing. A corruption applied to a file
/// whose provenance is "I typed some bytes" proves nothing about which change
/// caused the rejection.
fn buildMo(
    alloc: std.mem.Allocator,
    endian: std.builtin.Endian,
    pairs: []const [2][]const u8,
) ![]u8 {
    const n: u32 = @intCast(pairs.len);
    const orig_table: u32 = 28;
    const trans_table: u32 = orig_table + n * 8;
    const strings: u32 = trans_table + n * 8;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendNTimes(alloc, 0, strings);

    // Header. The hash table is left at size 0 / offset 0: it is optional,
    // and this reader never reads it.
    std.mem.writeInt(u32, out.items[0..4], Mo.magic, endian);
    std.mem.writeInt(u32, out.items[4..8], 0, endian);
    std.mem.writeInt(u32, out.items[8..12], n, endian);
    std.mem.writeInt(u32, out.items[12..16], orig_table, endian);
    std.mem.writeInt(u32, out.items[16..20], trans_table, endian);

    for (pairs, 0..) |pair, i| {
        for (pair, 0..) |s, half| {
            const off: u32 = @intCast(out.items.len);
            try out.appendSlice(alloc, s);
            try out.append(alloc, 0);

            const table = if (half == 0) orig_table else trans_table;
            const at = table + @as(u32, @intCast(i)) * 8;
            std.mem.writeInt(u32, out.items[at..][0..4], @intCast(s.len), endian);
            std.mem.writeInt(u32, out.items[at + 4 ..][0..4], off, endian);
        }
    }

    return out.toOwnedSlice(alloc);
}

/// What `_` will do with these bytes, without any of the global state.
fn lookupIn(bytes: []const u8, msgid: []const u8) ?[:0]const u8 {
    const mo = Mo.init(bytes) orelse return null;
    return mo.lookup(msgid);
}

const test_pairs: []const [2][]const u8 = &.{
    .{ "", "Content-Type: text/plain; charset=UTF-8\n" },
    .{ "Enabled", "启用" },
    .{ "Open config file…", "打开配置文件…" },
    .{ "Save", "保存" },
    .{ "Untranslated", "" },
};

test "mo: a catalogue answers, in either byte order" {
    const alloc = std.testing.allocator;
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        const bytes = try buildMo(alloc, endian, test_pairs);
        defer alloc.free(bytes);

        try std.testing.expectEqualStrings("保存", lookupIn(bytes, "Save").?);
        try std.testing.expectEqualStrings("启用", lookupIn(bytes, "Enabled").?);
        try std.testing.expectEqualStrings(
            "打开配置文件…",
            lookupIn(bytes, "Open config file…").?,
        );

        // A msgid that is not in the catalogue, one that sorts before every
        // entry and one that sorts after every entry: the three ways a binary
        // search can walk off its range.
        try std.testing.expect(lookupIn(bytes, "Nope") == null);
        try std.testing.expect(lookupIn(bytes, "\x01") == null);
        try std.testing.expect(lookupIn(bytes, "zzzz") == null);

        // Present but empty. `msgfmt` keeps these; answering with one would
        // replace a readable English word with nothing at all.
        try std.testing.expect(lookupIn(bytes, "Untranslated") == null);
    }
}

test "mo: nothing this reader rejects can be told apart from having no catalogue" {
    const alloc = std.testing.allocator;
    const good = try buildMo(alloc, .little, test_pairs);
    defer alloc.free(good);

    // **Truncation at every length.** A `.mo` is arrived at over a network,
    // out of an installer, or off a disk that filled up; the interesting
    // lengths are not the ones anybody would think to list.
    // **The property is not that a truncated file answers nothing.** One cut
    // after the first entry still holds that entry whole, and answering for
    // it is correct. What must never happen is an answer that is not the
    // translation -- which is what reading past a table into whatever
    // follows would produce.
    for (0..good.len) |n| {
        if (lookupIn(good[0..n], "Save")) |v|
            try std.testing.expectEqualStrings("保存", v);
        if (lookupIn(good[0..n], "")) |v|
            try std.testing.expectEqualStrings(test_pairs[0][1], v);
    }

    const Damage = struct {
        name: []const u8,
        at: usize,
        value: u32,
        endian: std.builtin.Endian,
    };
    // Each writes one `u32` over one header field of a known-good file.
    const damage = [_]Damage{
        .{ .name = "magic", .at = 0, .value = 0xdead_beef, .endian = .little },
        // Major revision 1. The minor half is deliberately left non-zero to
        // pin that it is the *major* half being read.
        .{ .name = "revision", .at = 4, .value = 0x0001_0002, .endian = .little },
        .{ .name = "count", .at = 8, .value = 0xffff_ffff, .endian = .little },
        // 2^29 entries: `count * 8` is exactly 2^32, which wraps to zero in
        // 32 bits and would make a table of four gigabytes look empty.
        .{ .name = "count wraps u32", .at = 8, .value = 0x2000_0000, .endian = .little },
        .{ .name = "originals table past the end", .at = 12, .value = 0xffff_0000, .endian = .little },
        .{ .name = "translations table past the end", .at = 16, .value = 0xffff_0000, .endian = .little },
    };
    for (damage) |d| {
        const bytes = try alloc.dupe(u8, good);
        defer alloc.free(bytes);
        std.mem.writeInt(u32, bytes[d.at..][0..4], d.value, d.endian);
        try std.testing.expect(lookupIn(bytes, "Save") == null);
    }
}

test "mo: an entry pointing outside the file is not read" {
    const alloc = std.testing.allocator;

    // The entry for "Save" is the fourth, so its pair sits at
    // `orig_table + 3*8`. Damage is applied to that pair specifically: a
    // corruption of some *other* entry would be rejected for the wrong
    // reason and the test would pass without exercising anything.
    const n: u32 = @intCast(test_pairs.len);
    const save_orig = 28 + 3 * 8;
    const save_trans = 28 + n * 8 + 3 * 8;

    { // offset past the end of the file
        const bytes = try buildMo(alloc, .little, test_pairs);
        defer alloc.free(bytes);
        std.mem.writeInt(u32, bytes[save_orig + 4 ..][0..4], 0xffff_0000, .little);
        try std.testing.expect(lookupIn(bytes, "Save") == null);
    }
    { // length that runs off the end from a valid offset
        const bytes = try buildMo(alloc, .little, test_pairs);
        defer alloc.free(bytes);
        std.mem.writeInt(u32, bytes[save_trans..][0..4], 0xffff_ffff, .little);
        try std.testing.expect(lookupIn(bytes, "Save") == null);
    }
    { // in bounds, but the byte where the terminator should be is not one
        const bytes = try buildMo(alloc, .little, test_pairs);
        defer alloc.free(bytes);
        const len = std.mem.readInt(u32, bytes[save_trans..][0..4], .little);
        std.mem.writeInt(u32, bytes[save_trans..][0..4], len - 1, .little);
        try std.testing.expect(lookupIn(bytes, "Save") == null);
    }
    { // the last entry's translation, with the file ending exactly at its
      // final byte -- so the terminator check is the only thing that can
      // catch it
        const bytes = try buildMo(alloc, .little, test_pairs);
        defer alloc.free(bytes);
        try std.testing.expect(lookupIn(bytes[0 .. bytes.len - 1], "Untranslated") == null);
    }
}

test "mo: an unsorted catalogue misses rather than misreads" {
    const alloc = std.testing.allocator;
    // Sorted the wrong way round. Binary search on this finds some entries
    // and not others; what matters is that it never returns a translation
    // belonging to a different msgid.
    const reversed: []const [2][]const u8 = &.{
        .{ "Save", "保存" },
        .{ "Enabled", "启用" },
        .{ "", "header" },
    };
    const bytes = try buildMo(alloc, .little, reversed);
    defer alloc.free(bytes);

    for ([_][]const u8{ "Save", "Enabled", "", "Nope" }) |msgid| {
        if (lookupIn(bytes, msgid)) |got| {
            // Whatever it found must be that msgid's own translation.
            const want = for (reversed) |pair| {
                if (std.mem.eql(u8, pair[0], msgid)) break pair[1];
            } else unreachable;
            try std.testing.expectEqualStrings(want, got);
        }
    }
}

test "mo: msgfmt's own output reads the same way this reader believes it does" {
    // **The one test that is not written against my belief about the
    // format.** Everything above builds its input with `buildMo`, which
    // encodes that belief; if the belief were wrong they would all still
    // pass. This one hands a `.po` to the real `msgfmt` -- already a build
    // dependency, see `src/build/GhosttyI18n.zig` -- and reads what comes
    // back.
    //
    // Skipped, loudly, when `msgfmt` is not installed. That is a real hole:
    // on a machine without gettext the format belief is unchecked.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const po =
        \\msgid ""
        \\msgstr "Content-Type: text/plain; charset=UTF-8\n"
        \\
        \\msgid "Save"
        \\msgstr "保存"
        \\
        \\msgid "Open config file…"
        \\msgstr "打开配置文件…"
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "t.po", .data = po });

    // Spawned with the temporary directory as its working directory, so the
    // arguments can be relative and the test needs no absolute path.
    var child = std.process.spawn(std.testing.io, .{
        .argv = &.{ "msgfmt", "-o", "t.mo", "t.po" },
        .cwd = .{ .dir = tmp.dir },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    switch (child.wait(std.testing.io) catch return error.SkipZigTest) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    const bytes = try tmp.dir.readFileAlloc(
        std.testing.io,
        "t.mo",
        alloc,
        .limited(1024 * 1024),
    );
    defer alloc.free(bytes);

    try std.testing.expectEqualStrings("保存", lookupIn(bytes, "Save").?);
    try std.testing.expectEqualStrings(
        "打开配置文件…",
        lookupIn(bytes, "Open config file…").?,
    );
    try std.testing.expect(lookupIn(bytes, "Save ") == null);

    // And the same file truncated, which is the case the format's own
    // guarantees say nothing about.
    for (0..bytes.len) |n| {
        if (lookupIn(bytes[0..n], "Save")) |v|
            try std.testing.expectEqualStrings("保存", v);
    }
}

test "locale: the shipped catalogue chosen for a user's language" {
    // **This runs everywhere, and the code it tests is only reached on
    // Windows.** It is plain string handling, and the thing it decides --
    // which of thirty-two languages a person is shown -- is not something to
    // find out about from a bug report on a machine nobody here has.
    const expect = std.testing.expectEqualStrings;

    // Exactly as `i18n_locales.zig` spells them.
    try expect("zh_CN", matchLocale("zh_CN").?);
    try expect("pt_BR", matchLocale("pt_BR").?);

    // What `GetUserDefaultLocaleName` hands back: BCP-47, with a dash.
    try expect("zh_CN", matchLocale("zh-CN").?);
    try expect("pt_BR", matchLocale("pt-BR").?);

    // With a script subtag, which is the form Windows uses for Chinese and
    // the one `fixZhLocale` was written for.
    try expect("zh_CN", matchLocale("zh-Hans-CN").?);
    try expect("zh_TW", matchLocale("zh-Hant-TW").?);

    // A `LANG` with an encoding suffix, which is how it arrives on every
    // other platform and therefore how somebody will set it here.
    try expect("zh_CN", matchLocale("zh_CN.UTF-8").?);
    try expect("de", matchLocale("de_DE.UTF-8").?);

    // **The suffix has to come off before the match, not after.** Leaving it
    // on makes the exact match miss and the language fallback answer instead,
    // and for these two the fallback is a different language: the list's
    // first `zh` is `zh_CN` and its first `es` is `es_BO`. Every other
    // spelling above survives that mistake, which is why these are here.
    try expect("zh_TW", matchLocale("zh_TW.UTF-8").?);
    try expect("es_ES", matchLocale("es_ES.UTF-8").?);

    // A region we do not ship, falling back to the language. The list's own
    // ordering decides which one, and it says so: "the first locale that
    // matches".
    try expect("de", matchLocale("de-AT").?);
    try expect("de", matchLocale("de").?);
    try expect("zh_CN", matchLocale("zh").?);
    try expect("es_BO", matchLocale("es-CL").?);

    // **The near-misses.** A prefix match that ignored the separator would
    // hand a Danish user German, because `da` and `de` are not the pair to
    // worry about but `nb` and `nb_NO` are -- and `ca` sits one letter from
    // nothing at all.
    try expect("ca", matchLocale("ca-ES").?);
    try std.testing.expect(matchLocale("d") == null);
    try std.testing.expect(matchLocale("dee") == null);
    try std.testing.expect(matchLocale("") == null);
    try std.testing.expect(matchLocale(".UTF-8") == null);
    try std.testing.expect(matchLocale("en") == null);
    try std.testing.expect(matchLocale("en_US") == null);

    // Longer than the buffer it normalises into. Refused rather than
    // truncated: a truncated name could match a language nobody asked for.
    try std.testing.expect(matchLocale("de-" ++ "x" ** 200) == null);
}

test "locales_map and staticLocale are compiled at all" {
    // **Neither of these had ever been compiled.** Nothing in the tree
    // referenced either one, and Zig does not analyse a container-level
    // declaration nobody uses -- so five compile errors sat in them, from
    // three unrelated causes: the module imported where the array was meant
    // (three sites), a `[*:0]const u8` handed to `std.mem.eql` where a slice
    // was wanted, and a `return` from inside a `comptime` block. All five
    // were found one at a time, because a compiler that stops at the first
    // error and a file with one error produce the same output.
    //
    // **This test is the only thing keeping them compiled.** Delete it and
    // the next person to break them gets a green build, exactly as before.
    // What it asserts is deliberately thin -- being reachable is the whole
    // point, and a thicker assertion would suggest the behaviour was the
    // thing at risk.
    const testing = std.testing;

    // **The general form of the same guard.** `refAllDecls` forces every
    // container-level declaration in this file to be analysed -- measured,
    // not assumed: a `const` whose initialiser has a type error and a `fn`
    // whose body has one are both caught by it, and by nothing else short of
    // referencing them by hand. See `docs/preview-manual.md`.
    testing.refAllDecls(@This());

    try testing.expect(locales_map.get("zh_CN") != null);
    try testing.expect(locales_map.get("pt_BR") != null);
    try testing.expect(locales_map.get("en_US") == null);
    try testing.expectEqual(locales.len, locales_map.kvs.len);

    // `staticLocale` is comptime-only, so calling it is what compiles it.
    try testing.expectEqualStrings("zh_CN", std.mem.span(staticLocale("zh_CN")));
    try testing.expectEqualStrings("da", std.mem.span(staticLocale("da")));
}
