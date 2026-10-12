//! A shell command, cut into the steps a person would read it as.
//!
//! `rm -rf dist/ && npm ci && npm run build` is three things that will
//! happen, and on one line the middle one is easy to read past. The control
//! room shows what an agent is waiting to run one step to a line
//! (dev-docs/poltergeist/control-room.md, 3.2), so the dangerous step has a
//! line of its own. This is where the cutting is done, once, for every host.
//!
//! **A step starts at a joiner**: `&&`, `||`, `|`, `|&`, `;`, or a new line.
//! The joiner stays at the front of the step it introduces (`&& npm ci`),
//! because it says how the step is reached; a new line introduces a step
//! with nothing in front of it.
//!
//! **Only a joiner the shell itself would act on is one.** Nothing is cut
//! inside single or double quotes, `$'…'`, a backslash escape, `$(…)`, a
//! backquoted command, `(…)`, `{ …; }`, `${…}`, a comment, or the body of a
//! here-document. `;;` is a `case` clause's end and is not cut either. A
//! backslash at the end of a line joins it to the next, as it does for the
//! shell.
//!
//! **What does not parse is not cut**: a quote or a bracket left open, or a
//! here-document whose end never comes, and the whole command comes back as
//! one step. A command that is not shell at all mostly comes back whole for
//! the same reason; where it happens to contain a bare `;` it is cut there,
//! which is still every character of it, in order.
//!
//! Nothing is dropped and nothing is rewritten: the steps, joined in order,
//! are the command with the white space between steps collapsed.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The steps of `command`, in order. Each is a slice of `command`, trimmed.
/// Never empty unless `command` is blank.
pub fn split(arena: Allocator, command: []const u8) Allocator.Error![]const []const u8 {
    const whole = std.mem.trim(u8, command, " \t\r\n");
    if (whole.len == 0) return &.{};

    var steps: std.ArrayListUnmanaged([]const u8) = .empty;
    const ok = cut(arena, whole, &steps) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (!ok or steps.items.len == 0) {
        const one = try arena.alloc([]const u8, 1);
        one[0] = whole;
        return one;
    }
    return steps.items;
}

/// A here-document that has been opened on the current line and whose body
/// starts on the next.
const Heredoc = struct {
    word: []const u8,
    strip_tabs: bool,
};

fn cut(arena: Allocator, s: []const u8, steps: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!bool {
    var start: usize = 0;
    var i: usize = 0;
    // Brackets open at the top level: `(`, `{` as a word, and `$(`.
    var depth: usize = 0;
    var pending: std.ArrayListUnmanaged(Heredoc) = .empty;
    var word_start = true;

    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '\\' => {
                // The next character is itself, whatever it is.
                i += if (i + 1 < s.len) 2 else 1;
                word_start = false;
                continue;
            },
            '\'' => {
                i = (skipSingle(s, i) orelse return false);
                word_start = false;
                continue;
            },
            '"' => {
                i = (skipDouble(s, i) orelse return false);
                word_start = false;
                continue;
            },
            '`' => {
                i = (skipBackquote(s, i) orelse return false);
                word_start = false;
                continue;
            },
            '$' => {
                if (i + 1 < s.len) switch (s[i + 1]) {
                    '(' => {
                        i = (skipParens(s, i + 1) orelse return false);
                        word_start = false;
                        continue;
                    },
                    '{' => {
                        i = (skipBraces(s, i + 1) orelse return false);
                        word_start = false;
                        continue;
                    },
                    '\'' => {
                        i = (skipAnsi(s, i + 1) orelse return false);
                        word_start = false;
                        continue;
                    },
                    else => {},
                };
                i += 1;
                word_start = false;
                continue;
            },
            '#' => {
                if (word_start) {
                    // A comment runs to the end of its line.
                    while (i < s.len and s[i] != '\n') i += 1;
                    continue;
                }
                i += 1;
                continue;
            },
            '(' => {
                depth += 1;
                i += 1;
                word_start = true;
                continue;
            },
            ')' => {
                if (depth == 0) return false;
                depth -= 1;
                i += 1;
                word_start = false;
                continue;
            },
            '{' => {
                // A group only when it stands as a word of its own.
                if (word_start and (i + 1 >= s.len or isBlank(s[i + 1]) or s[i + 1] == '\n')) depth += 1;
                i += 1;
                word_start = false;
                continue;
            },
            '}' => {
                if (word_start and depth > 0) depth -= 1;
                i += 1;
                word_start = false;
                continue;
            },
            '<' => {
                if (std.mem.startsWith(u8, s[i..], "<<<")) {
                    // A here-string: its word is on this line.
                    i += 3;
                    word_start = true;
                    continue;
                }
                if (heredocAt(s, i)) |h| {
                    try pending.append(arena, h.doc);
                    i = h.end;
                    word_start = false;
                    continue;
                }
                i += 1;
                word_start = false;
                continue;
            },
            '\n' => {
                // The bodies of the here-documents opened on this line come
                // first, and belong to the step that opened them.
                var at = i + 1;
                for (pending.items) |doc| {
                    at = (skipHeredoc(s, at, doc) orelse return false);
                }
                const had_docs = pending.items.len > 0;
                pending.clearRetainingCapacity();
                if (depth == 0) {
                    const end = if (had_docs) at else i;
                    try push(arena, steps, s[start..end]);
                    start = at;
                }
                i = at;
                word_start = true;
                continue;
            },
            ';', '|', '&' => {
                const len = joinerAt(s, i);
                if (len == 0 or depth > 0) {
                    // `;;`, a lone `&`, `>&`, `&>`: not a place to cut.
                    i += @max(len, notJoinerLen(s, i));
                    word_start = true;
                    continue;
                }
                try push(arena, steps, s[start..i]);
                start = i;
                i += len;
                word_start = true;
                continue;
            },
            else => {
                word_start = isBlank(c);
                i += 1;
            },
        }
    }
    if (depth != 0 or pending.items.len != 0) return false;
    try push(arena, steps, s[start..]);
    return true;
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

/// A step, trimmed. One that is nothing but a joiner -- the `;` at the end
/// of a line -- is added to the step before it, so no line is a bare `;`.
fn push(arena: Allocator, steps: *std.ArrayListUnmanaged([]const u8), raw: []const u8) Allocator.Error!void {
    const step = std.mem.trim(u8, raw, " \t\r\n");
    if (step.len == 0) return;
    if (steps.items.len > 0 and joinerAt(step, 0) == step.len) {
        const last = &steps.items[steps.items.len - 1];
        // Both are slices of the same command, the joiner after the step.
        const from = @intFromPtr(last.ptr);
        const to = @intFromPtr(step.ptr) + step.len;
        if (to > from) {
            last.* = last.ptr[0 .. to - from];
            return;
        }
    }
    try steps.append(arena, step);
}

/// How long the joiner at `i` is; 0 when what is there is not one.
fn joinerAt(s: []const u8, i: usize) usize {
    const next: u8 = if (i + 1 < s.len) s[i + 1] else 0;
    const prev: u8 = if (i > 0) s[i - 1] else 0;
    return switch (s[i]) {
        ';' => if (next == ';' or prev == ';') 0 else 1,
        '|' => if (next == '|' or next == '&') 2 else 1,
        '&' => if (next == '&') 2 else 0,
        else => 0,
    };
}

/// How many characters to step over at a `;`, `|` or `&` that is not a
/// joiner: both of `;;`, otherwise the one.
fn notJoinerLen(s: []const u8, i: usize) usize {
    if (s[i] == ';' and i + 1 < s.len and s[i + 1] == ';') return 2;
    return 1;
}

/// From an opening `'` to just past its closing one.
fn skipSingle(s: []const u8, open: usize) ?usize {
    const close = std.mem.indexOfScalarPos(u8, s, open + 1, '\'') orelse return null;
    return close + 1;
}

/// From the `'` of `$'…'` to just past its end; a backslash escapes here.
fn skipAnsi(s: []const u8, open: usize) ?usize {
    var i = open + 1;
    while (i < s.len) : (i += 1) switch (s[i]) {
        '\\' => i += 1,
        '\'' => return i + 1,
        else => {},
    };
    return null;
}

/// From an opening `"` to just past its closing one. A backslash escapes,
/// and a `$(…)` or a backquoted command inside may hold quotes of its own.
fn skipDouble(s: []const u8, open: usize) ?usize {
    var i = open + 1;
    while (i < s.len) switch (s[i]) {
        '\\' => i += 2,
        '"' => return i + 1,
        '`' => i = skipBackquote(s, i) orelse return null,
        '$' => {
            if (i + 1 < s.len and s[i + 1] == '(') {
                i = skipParens(s, i + 1) orelse return null;
            } else if (i + 1 < s.len and s[i + 1] == '{') {
                i = skipBraces(s, i + 1) orelse return null;
            } else i += 1;
        },
        else => i += 1,
    };
    return null;
}

/// From an opening backquote to just past its closing one.
fn skipBackquote(s: []const u8, open: usize) ?usize {
    var i = open + 1;
    while (i < s.len) : (i += 1) switch (s[i]) {
        '\\' => i += 1,
        '`' => return i + 1,
        else => {},
    };
    return null;
}

/// From an opening `(` to just past the `)` that closes it.
fn skipParens(s: []const u8, open: usize) ?usize {
    var i = open + 1;
    var depth: usize = 1;
    while (i < s.len) switch (s[i]) {
        '\\' => i += 2,
        '\'' => i = skipSingle(s, i) orelse return null,
        '"' => i = skipDouble(s, i) orelse return null,
        '`' => i = skipBackquote(s, i) orelse return null,
        '(' => {
            depth += 1;
            i += 1;
        },
        ')' => {
            depth -= 1;
            i += 1;
            if (depth == 0) return i;
        },
        else => i += 1,
    };
    return null;
}

/// From the `{` of `${…}` to just past its `}`.
fn skipBraces(s: []const u8, open: usize) ?usize {
    var i = open + 1;
    var depth: usize = 1;
    while (i < s.len) switch (s[i]) {
        '\\' => i += 2,
        '\'' => i = skipSingle(s, i) orelse return null,
        '"' => i = skipDouble(s, i) orelse return null,
        '{' => {
            depth += 1;
            i += 1;
        },
        '}' => {
            depth -= 1;
            i += 1;
            if (depth == 0) return i;
        },
        else => i += 1,
    };
    return null;
}

/// The here-document opened at `i`, if `<<` starts one there (and not the
/// `<<<` of a here-string), and where its opening word ends.
fn heredocAt(s: []const u8, i: usize) ?struct { doc: Heredoc, end: usize } {
    if (!std.mem.startsWith(u8, s[i..], "<<")) return null;
    if (std.mem.startsWith(u8, s[i..], "<<<")) return null;
    var at = i + 2;
    var strip_tabs = false;
    if (at < s.len and s[at] == '-') {
        strip_tabs = true;
        at += 1;
    }
    while (at < s.len and isBlank(s[at])) at += 1;
    if (at >= s.len) return null;

    // The word may be quoted, which changes how the body is read and not
    // where it ends.
    if (s[at] == '\'' or s[at] == '"') {
        const close = std.mem.indexOfScalarPos(u8, s, at + 1, s[at]) orelse return null;
        if (close == at + 1) return null;
        return .{ .doc = .{ .word = s[at + 1 .. close], .strip_tabs = strip_tabs }, .end = close + 1 };
    }
    var end = at;
    if (s[end] == '\\') end += 1;
    const word_from = end;
    while (end < s.len and (std.ascii.isAlphanumeric(s[end]) or s[end] == '_' or s[end] == '-' or s[end] == '.')) end += 1;
    if (end == word_from) return null;
    return .{ .doc = .{ .word = s[word_from..end], .strip_tabs = strip_tabs }, .end = end };
}

/// From the start of a here-document's body to just past the line that
/// ends it.
fn skipHeredoc(s: []const u8, from: usize, doc: Heredoc) ?usize {
    var at = from;
    while (at <= s.len) {
        const eol = std.mem.indexOfScalarPos(u8, s, at, '\n') orelse s.len;
        var line = s[at..eol];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (doc.strip_tabs) line = std.mem.trimStart(u8, line, "\t");
        if (std.mem.eql(u8, line, doc.word)) return @min(eol + 1, s.len);
        if (eol >= s.len) return null;
        at = eol + 1;
    }
    return null;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

fn expectSteps(command: []const u8, want: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try split(arena.allocator(), command);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "ShellSteps: one step to a joiner, and the joiner leads its step" {
    try expectSteps(
        "rm -rf dist/ .cache/ node_modules/.vite && npm ci && npm run build -- --mode production",
        &.{ "rm -rf dist/ .cache/ node_modules/.vite", "&& npm ci", "&& npm run build -- --mode production" },
    );
    try expectSteps("make || echo failed", &.{ "make", "|| echo failed" });
    try expectSteps("cat a.log | grep ERROR | wc -l", &.{ "cat a.log", "| grep ERROR", "| wc -l" });
    try expectSteps("cd web; npm test; cd ..", &.{ "cd web", "; npm test", "; cd .." });
    try expectSteps("make 2>&1 |& tee log", &.{ "make 2>&1", "|& tee log" });
    try expectSteps("git push --force-with-lease origin release/2.4", &.{"git push --force-with-lease origin release/2.4"});
}

test "ShellSteps: nothing is cut inside quotes" {
    try expectSteps("git commit -m \"fix; build && ship | done\"", &.{"git commit -m \"fix; build && ship | done\""});
    try expectSteps("echo 'a && b; c | d' && ls", &.{ "echo 'a && b; c | d'", "&& ls" });
    try expectSteps("printf $'a;b\\'c;d' ; ls", &.{ "printf $'a;b\\'c;d'", "; ls" });
    try expectSteps("echo \"say \\\"hi; there\\\"\" && ls", &.{ "echo \"say \\\"hi; there\\\"\"", "&& ls" });
    // A quote inside the other kind of quote is a character.
    try expectSteps("echo \"it's; fine\" | cat", &.{ "echo \"it's; fine\"", "| cat" });
}

test "ShellSteps: nothing is cut after a backslash" {
    try expectSteps("echo a\\;b \\&\\& c && ls", &.{ "echo a\\;b \\&\\& c", "&& ls" });
    try expectSteps("find . -name '*.o' -exec rm {} \\; && ls", &.{ "find . -name '*.o' -exec rm {} \\;", "&& ls" });
    // A backslash at the end of a line carries on to the next.
    try expectSteps("docker run \\\n  -v a:b \\\n  img && ls", &.{ "docker run \\\n  -v a:b \\\n  img", "&& ls" });
}

test "ShellSteps: nothing is cut inside a substitution, a subshell or a group" {
    try expectSteps("echo $(cd a && ls | wc -l) && pwd", &.{ "echo $(cd a && ls | wc -l)", "&& pwd" });
    try expectSteps("echo `cd a; ls` ; pwd", &.{ "echo `cd a; ls`", "; pwd" });
    try expectSteps("(cd a && make) && echo ok", &.{ "(cd a && make)", "&& echo ok" });
    try expectSteps("{ cd a; make; } || exit 1", &.{ "{ cd a; make; }", "|| exit 1" });
    try expectSteps("echo ${x:-a;b} && ls", &.{ "echo ${x:-a;b}", "&& ls" });
    try expectSteps("echo \"n=$(ls | wc -l); ok\" && ls", &.{ "echo \"n=$(ls | wc -l); ok\"", "&& ls" });
    try expectSteps("echo $(echo \")\" ; echo \"(\") && ls", &.{ "echo $(echo \")\" ; echo \"(\")", "&& ls" });
}

test "ShellSteps: a here-document's body stays with the step that opened it" {
    try expectSteps(
        "cat <<EOF > a.txt && ls\none; two && three\n| four\nEOF\necho done",
        &.{ "cat <<EOF > a.txt", "&& ls\none; two && three\n| four\nEOF", "echo done" },
    );
    try expectSteps("cat <<'END'\na; b\nEND", &.{"cat <<'END'\na; b\nEND"});
    try expectSteps("cat <<-EOF\n\ta && b\n\tEOF\nls", &.{ "cat <<-EOF\n\ta && b\n\tEOF", "ls" });
    // A here-string is not a here-document.
    try expectSteps("grep x <<< \"a;b\" && ls", &.{ "grep x <<< \"a;b\"", "&& ls" });
}

test "ShellSteps: a new line is a new step, a comment is not cut, and ;; is left alone" {
    try expectSteps("set -e\nnpm ci\nnpm test", &.{ "set -e", "npm ci", "npm test" });
    try expectSteps("ls # a; b && c\npwd", &.{ "ls # a; b && c", "pwd" });
    try expectSteps("echo a#b; ls", &.{ "echo a#b", "; ls" });
    // A `case` has a `)` with no `(`: it does not parse here, and is whole.
    try expectSteps("case $x in a) ls;; b) pwd;; esac && echo ok", &.{"case $x in a) ls;; b) pwd;; esac && echo ok"});
    try expectSteps("f() { a;; }", &.{"f() { a;; }"});
    try expectSteps("sleep 5 & wait", &.{"sleep 5 & wait"});
    try expectSteps("make >out 2>&1 && ls", &.{ "make >out 2>&1", "&& ls" });
    // The `;` that ends a line is not a step of its own.
    try expectSteps("ls; pwd;", &.{ "ls", "; pwd;" });
}

test "ShellSteps: what does not parse comes back whole" {
    try expectSteps("echo \"unclosed && ls", &.{"echo \"unclosed && ls"});
    try expectSteps("echo 'unclosed; ls", &.{"echo 'unclosed; ls"});
    try expectSteps("echo $(ls && pwd", &.{"echo $(ls && pwd"});
    try expectSteps("ls ) && pwd", &.{"ls ) && pwd"});
    try expectSteps("cat <<EOF\nnever ends && ls", &.{"cat <<EOF\nnever ends && ls"});
    try expectSteps("   ", &.{});
    try expectSteps("  ls  ", &.{"ls"});
}

test "ShellSteps: every character survives, in order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const commands = [_][]const u8{
        "rm -rf dist/ && npm ci && npm run build",
        "a | b || c ; d && e",
        "echo \"x; y\" && (cd a; ls) | wc -l; echo `date; id`",
        "cat <<EOF && ls\nbody; here\nEOF\npwd",
    };
    for (commands) |command| {
        const steps = try split(arena.allocator(), command);
        var joined: std.ArrayListUnmanaged(u8) = .empty;
        for (steps) |step| for (step) |c| {
            if (c != ' ' and c != '\n') try joined.append(arena.allocator(), c);
        };
        var want: std.ArrayListUnmanaged(u8) = .empty;
        for (command) |c| {
            if (c != ' ' and c != '\n') try want.append(arena.allocator(), c);
        }
        try testing.expectEqualStrings(want.items, joined.items);
    }
}
