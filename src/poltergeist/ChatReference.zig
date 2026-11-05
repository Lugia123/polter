//! Recognize an exact file reference in a stored message. Parsing grants no access.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Error = Allocator.Error || error{ ReferenceNotFound, NotAFileReference };

/// Raw Markdown destinations (including escapes) are compared before decoding.
/// Plain absolute paths must occupy a whole token; prose substrings are not references.
pub fn path(alloc: Allocator, text: []const u8, original: []const u8) Error![]const u8 {
    var found = false;
    var markdown = false;
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] != ']' or text[i + 1] != '(' or escaped(text, i) or !hasLabel(text, i)) continue;
        var start = i + 2;
        while (start < text.len and (text[start] == ' ' or text[start] == '\t')) start += 1;
        var end = start;
        if (start < text.len and text[start] == '<') {
            start += 1;
            end = start;
            while (end < text.len and (text[end] != '>' or escaped(text, end)) and text[end] != '\n') : (end += 1) {}
            if (end == text.len or text[end] != '>') continue;
            var close = end + 1;
            while (close < text.len and (text[close] == ' ' or text[close] == '\t')) close += 1;
            if (close == text.len or text[close] != ')') continue;
        } else {
            var depth: usize = 0;
            while (end < text.len) : (end += 1) {
                if (escaped(text, end)) continue;
                if (text[end] == '(') depth += 1;
                if (text[end] == ')') {
                    if (depth == 0) break;
                    depth -= 1;
                }
                if (std.ascii.isWhitespace(text[end])) break;
            }
            if (end == text.len or text[end] != ')') continue;
        }
        if (std.mem.eql(u8, text[start..end], original)) {
            found = true;
            markdown = true;
            break;
        }
    }
    if (!found and isAbsolute(original)) {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, original)) |n| {
            const end = n + original.len;
            if ((n == 0 or boundary(text[n - 1])) and (end == text.len or boundary(text[end]))) {
                found = true;
                break;
            }
            at = n + 1;
        }
    }
    if (!found) return error.ReferenceNotFound;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    i = 0;
    while (i < original.len) : (i += 1) {
        if (markdown and original[i] == '\\' and i + 1 < original.len and std.ascii.isPunctuation(original[i + 1])) i += 1;
        out.writer.writeByte(original[i]) catch return error.OutOfMemory;
    }
    const result = try out.toOwnedSlice();
    // Only local paths: no file://, network, protocol handlers or HTML.
    if (std.mem.indexOfScalar(u8, result, 0) != null or std.mem.startsWith(u8, result, "//") or
        std.mem.startsWith(u8, result, "\\\\") or (std.mem.indexOfScalar(u8, result, ':') != null and !windowsDrive(result)))
    {
        alloc.free(result);
        return error.NotAFileReference;
    }
    return result;
}
fn hasLabel(text: []const u8, close: usize) bool {
    var depth: usize = 1;
    var n = close;
    while (n > 0) {
        n -= 1;
        if (escaped(text, n)) continue;
        if (text[n] == ']') depth += 1;
        if (text[n] == '[') {
            depth -= 1;
            if (depth == 0) return true;
        }
    }
    return false;
}
fn escaped(text: []const u8, at: usize) bool {
    var n = at;
    while (n > 0 and text[n - 1] == '\\') : (n -= 1) {}
    return (at - n) % 2 != 0;
}
fn boundary(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == '`' or c == '<' or c == '>' or c == '"' or c == '\'';
}
fn windowsDrive(p: []const u8) bool {
    return p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '/' or p[2] == '\\');
}
pub fn isAbsolute(p: []const u8) bool {
    return (p.len > 0 and p[0] == '/') or windowsDrive(p);
}

test "2976 reference exact destination is distinct from a prose substring" {
    const a = std.testing.allocator;
    const p = try path(a, "[source](/work/a\\(b\\).zig)", "/work/a\\(b\\).zig");
    defer a.free(p);
    try std.testing.expectEqualStrings("/work/a(b).zig", p);
    try std.testing.expectError(error.ReferenceNotFound, path(a, "private/work/a.zig.backup", "/work/a.zig"));
    try std.testing.expectError(error.NotAFileReference, path(a, "[link](https://example.org)", "https://example.org"));
    const plain = try path(a, "file `/work/a.zig` is here", "/work/a.zig");
    defer a.free(plain);
    try std.testing.expectEqualStrings("/work/a.zig", plain);
}
