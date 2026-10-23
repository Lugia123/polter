//! May this URL be opened, and who chose it? (task 2122)
//!
//! An `open_url` carries a `kind`, and one of them is not like the others.
//! `text`, `html` and `unknown` come from something the person at the
//! keyboard did -- a path they clicked, a file the host was asked to show.
//! **`osc8` is a hyperlink emitted by whatever is running in the terminal**:
//! a program, a remote host over ssh, the output of `cat` on a file somebody
//! else wrote. OSC 8 exists so that the text shown can differ from the
//! target, and the targets worth worrying about are not web pages: a
//! `file:` URL or a bare path is handed to whatever the system runs for it,
//! and every registered protocol handler is a program taking an argument
//! from a stranger.
//!
//! **The decision is here, once, for every host.** It was the Windows
//! host's alone (`polter-urlpolicy`); macOS had its own (`UntrustedURL`),
//! which let `file:` through to the default application -- measured: an
//! OSC 8 link to `file:///etc/hosts` opened it in TextEdit -- and the core,
//! told "no" by the Windows host, opened the link itself with
//! `internal_os.open`, which is the very thing the host had refused
//! (`rundll32 url.dll,FileProtocolHandler`, measured 73 ms after the
//! refusal). So a link the core refuses is never offered to the host, and
//! never opened by the core.
//!
//! **The default is refusal.** A scheme not on the list is not opened when
//! the terminal chose it: a handler some other program installs tomorrow
//! arrives without anything here changing, and a list of what is allowed is
//! the only shape in which that arrival is safe.

const std = @import("std");

pub const Verdict = union(enum) {
    open,
    /// Not opened, and why, for the log line: a refusal that says nothing
    /// cannot be told from a link that never arrived.
    refuse: []const u8,
};

/// The schemes an OSC 8 hyperlink may use. Short on purpose: the ones a
/// hyperlink in terminal output is for, each ending at a program whose job
/// is to be handed a URL by a stranger.
const osc8_allowed = [_][]const u8{ "http", "https", "mailto" };

/// The decision for `url`, chosen by the terminal (`osc8`) or by the person.
pub fn verdict(osc8: bool, url_raw: []const u8) Verdict {
    const url = std.mem.trim(u8, url_raw, " \t");
    if (url.len == 0) return .{ .refuse = "the URL is empty" };
    // A control character is a mistake or an attempt to make the log line
    // and the target disagree, whoever chose the URL.
    for (url) |c| if (c < 0x20 or c == 0x7f) return .{ .refuse = "the URL contains a control character" };

    if (!osc8) return .open;

    var buf: [32]u8 = undefined;
    const s = scheme(url, &buf) orelse return .{
        .refuse = "an OSC 8 hyperlink with no scheme is a path, and a path from terminal output is a file the system would open by its association",
    };
    for (osc8_allowed) |allowed| if (std.mem.eql(u8, s, allowed)) return .open;
    return .{
        .refuse = "an OSC 8 hyperlink may only use http, https or mailto: the scheme was chosen by whatever is running in the terminal, and every other one ends at a program that acts on it",
    };
}

/// The scheme of `url`, lowercased into `buf`, or null when it has none.
///
/// **Not a parser.** RFC 3986: a letter, then letters, digits, `+`, `-` or
/// `.`, up to the first `:`. A Windows drive letter is not a scheme -- a
/// one-letter prefix is a path -- so `C:\Users\…` is refused as the path it
/// is rather than as an unknown scheme `c`.
pub fn scheme(url: []const u8, buf: []u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
    const head = url[0..colon];
    if (head.len < 2 or head.len > buf.len) return null;
    if (!std.ascii.isAlphabetic(head[0])) return null;
    for (head) |c| if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return null;
    return std.ascii.lowerString(buf[0..head.len], head);
}

const testing = std.testing;

fn refused(v: Verdict) bool {
    return v == .refuse;
}

test "2122: a hyperlink from terminal output may be a web page or a mail address" {
    for ([_][]const u8{
        "https://example.com/x",
        "http://example.com",
        "mailto:someone@example.com",
        // Case-insensitive, or a check could be passed by shouting.
        "HTTPS://example.com",
        "HtTpS://example.com",
    }) |u| try testing.expect(verdict(true, u) == .open);
}

test "2122: a hyperlink from terminal output never reaches a file, a path or another program" {
    for ([_][]const u8{
        "file:///etc/hosts",
        "file:///C:/Windows/System32/calc.exe",
        "file://server/share/x.bat",
        "/Applications/Calculator.app",
        "~/Downloads/x.command",
        "ms-settings:windowsupdate",
        "javascript:alert(1)",
        "vbscript:x",
        "search-ms:query=x",
        "shell:startup",
        "x-apple.systempreferences:com.apple.preference.security",
        "C:\\Users\\somebody\\thing.lnk",
        "\\\\attacker\\share\\payload.exe",
        "//attacker/share/payload.exe",
        "./relative.bat",
        "zoommtg://x",
        "some-app-installed-tomorrow://x",
    }) |u| {
        if (!refused(verdict(true, u))) {
            std.debug.print("an OSC 8 hyperlink to {s} was allowed\n", .{u});
            return error.TestExpectedRefusal;
        }
    }
}

test "2122: what the person chose is opened as asked, a control character whoever chose it is not" {
    try testing.expect(verdict(false, "C:\\Users\\somebody\\ghostty\\config") == .open);
    try testing.expect(verdict(false, "file:///etc/hosts") == .open);
    try testing.expect(verdict(false, "https://example.com") == .open);
    try testing.expect(refused(verdict(true, "https://example.com\nrm -rf")));
    try testing.expect(refused(verdict(false, "https://example.com\x00x")));
    try testing.expect(refused(verdict(false, "  ")));
}

test "2122: a drive letter is not a scheme" {
    var buf: [32]u8 = undefined;
    try testing.expect(scheme("C:\\Windows", &buf) == null);
    try testing.expectEqualStrings("https", scheme("HTTPS://x", &buf).?);
    try testing.expectEqualStrings("mailto", scheme("mailto:a@b", &buf).?);
    try testing.expect(scheme("no-colon-here", &buf) == null);
    try testing.expect(scheme("1foo:bar", &buf) == null);
}
