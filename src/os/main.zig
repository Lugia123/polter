//! The "os" package contains utilities for interfacing with the operating
//! system. These aren't restricted to syscalls or low-level operations, butos/main.zig
//! also OS-specific features and conventions.

const builtin = @import("builtin");
const std = @import("std");

const dbus = @import("dbus.zig");
const desktop = @import("desktop.zig");
const file = @import("file.zig");
const flatpak = @import("flatpak.zig");
const homedir = @import("homedir.zig");
const locale = @import("locale.zig");
const mouse = @import("mouse.zig");
const openpkg = @import("open.zig");
const pipepkg = @import("pipe.zig");
const resourcesdir = @import("resourcesdir.zig");
const systemd = @import("systemd.zig");
const kernel_info = @import("kernel_info.zig");

// Namespaces
pub const cgroup = @import("cgroup.zig");
pub const edit = @import("edit.zig");
pub const hostname = @import("hostname.zig");
pub const i18n = @import("i18n.zig");
pub const mach = @import("mach.zig");
pub const path = @import("path.zig");
pub const passwd = @import("passwd.zig");
pub const xdg = @import("xdg.zig");
pub const windows = @import("windows.zig");
pub const macos = @import("macos.zig");
pub const shell = @import("shell.zig");
pub const stderr = @import("stderr.zig");
pub const uri = @import("uri.zig");

// Functions and types
pub const CFReleaseThread = @import("cf_release_thread.zig");
pub const TempDir = @import("TempDir.zig");
pub const launchedFromDesktop = desktop.launchedFromDesktop;
pub const launchedByDbusActivation = dbus.launchedByDbusActivation;
pub const launchedBySystemd = systemd.launchedBySystemd;
pub const desktopEnvironment = desktop.desktopEnvironment;
pub const rlimit = file.rlimit;
pub const fixMaxFiles = file.fixMaxFiles;
pub const restoreMaxFiles = file.restoreMaxFiles;
pub const randomTmpPath = file.randomTmpPath;
pub const isFlatpak = flatpak.isFlatpak;
pub const FlatpakHostCommand = flatpak.FlatpakHostCommand;
pub const home = homedir.home;
pub const expandHome = homedir.expandHome;
pub const ensureLocale = locale.ensureLocale;
pub const clickInterval = mouse.clickInterval;
pub const open = openpkg.open;
pub const OpenType = openpkg.Type;
pub const pipe = pipepkg.pipe;
pub const resourcesDir = resourcesdir.resourcesDir;
pub const ResourcesDir = resourcesdir.ResourcesDir;
pub const ShellEscapeWriter = shell.ShellEscapeWriter;
pub const getKernelInfo = kernel_info.getKernelInfo;
pub const getConfigEditCommand = edit.getConfigEditCommand;

test {
    _ = file;
    _ = stderr;
    _ = edit;
    _ = i18n;
    _ = path;
    _ = uri;
    _ = shell;

    if (comptime builtin.os.tag == .linux) {
        _ = kernel_info;
    } else if (comptime builtin.os.tag.isDarwin()) {
        _ = mach;
        _ = macos;
    }
}

/// `struct tm`, and the one function that fills it in.
///
/// Declared here because the standard library has neither, and both the
/// chat window and the notifier need to turn a Unix timestamp into a local
/// time of day. Declared in full even though only two fields are read:
/// `localtime_r` writes into whatever it is handed, so a struct short by a
/// field is a buffer overrun. The first nine members are POSIX; the last
/// two are a BSD extension that both macOS and glibc have.
pub const Tm = extern struct {
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

const time_c = struct {
    extern "c" fn localtime_r(timep: *const i64, result: *Tm) ?*Tm;

    /// The Windows CRT's answer. Not a spelling difference: the arguments
    /// are the other way round, it reports failure through a return code
    /// rather than a null, and the `struct tm` it fills is the nine POSIX
    /// members with neither of the BSD ones after them.
    extern "c" fn _localtime64_s(result: *Tm, timep: *const i64) c_int;
};

/// A Unix timestamp as a local wall-clock time.
pub fn localtime_r(timep: *const i64, result: *Tm) ?*Tm {
    switch (builtin.os.tag) {
        .windows => {
            // Zeroed first because the Windows CRT stops after `isdst`, and
            // `gmtoff` and `zone` would otherwise be whatever the caller's
            // stack held. Nothing reads those two today -- they are here so
            // that a platform whose `localtime_r` writes them has somewhere
            // to put them -- but handing back uninitialised memory as
            // though it were a time zone is the sort of thing that is only
            // ever found later and by accident.
            result.* = std.mem.zeroes(Tm);
            if (time_c._localtime64_s(result, timep) != 0) return null;
            return result;
        },
        else => return time_c.localtime_r(timep, result),
    }
}
