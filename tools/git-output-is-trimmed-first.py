#!/usr/bin/env python3
"""`git`'s trailing newline must be removed before anything rewrites it.

# The defect this exists for

`src/build/GitVersion.zig` asks git for the branch name, then rewrites every
character outside `[0-9A-Za-z-]` into `-` so the value is legal in a semantic
version pre-release identifier. Git's output ends in a newline, and a newline
is outside that set -- so the rewrite turned it into a hyphen, and **every
build's version string carried a trailing `-`**:

    version_string = "1.3.2-HEAD-+1ca47f03b"
    version_pre    = "HEAD-"

**There was a `trimEnd` on that value.** It ran after the rewrite, where there
was no longer any whitespace to find, and a hyphen is legal in a pre-release
identifier so nothing downstream objected. ⚠️ **A call that cannot fire is
worse than a missing one**: anyone reading that line concluded the value was
trimmed. That is why this reached a shipped version string.

# Why a gate and not a test

`src/build/*.zig` is build-time code. **Measured, not assumed**: a
`test { try std.testing.expect(false); }` placed in `GitVersion.zig` leaves
`zig build test` at `85/85` and exit 0 -- the file is not in the test graph, so
a test there is never compiled, let alone run. A criterion written there would
look like one and never fire.

# What is checked

Inside `src/build/`, every block that binds the result of a `runAllowFail`
whose argv begins with `git` must trim that result **before** any loop that
writes through a pointer into it. Order, not presence: presence was already
true when this was broken.

Run:  python3 tools/git-output-is-trimmed-first.py
Exit: 0 when every git output is trimmed before it is rewritten.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
BUILD_DIR = os.path.join(ROOT, "src", "build")

# **A bill, not an approval.** `gtk.zig` also calls `runAllowFail`, but it asks
# `pkg-config`, not git, and it reads the answer with `indexOf` -- a substring
# search that a trailing newline cannot disturb. It is excluded by the argv
# check below rather than by name; this entry records that the exclusion was
# looked at rather than assumed.
NOT_GIT = "src/build/gtk.zig runs pkg-config, and reads it with indexOf"

# A loop that writes through a pointer into a slice: `for (x) |*c| { ... }`.
REWRITE = re.compile(r"\bfor\s*\([^)]*\)\s*\|\s*\*")
TRIM = re.compile(r"\bstd\.mem\.trim(?:End|Start)?\s*\(")


def strip_comments(text: str) -> str:
    """`//` comments blanked, newlines kept.

    This file's subject *discusses* `trimEnd` and rewriting loops in prose --
    including the comment this change added, which explains the order. A
    scanner that counted those would find the trim it was looking for in a
    sentence about the trim.
    """
    return re.sub(r"//[^\n]*", "", text)


def blocks_reading_git(code: str):
    """Each `runAllowFail(...)` whose argv starts with `git`, as
    `(offset, block_text)` where the block runs to the end of the enclosing
    labelled block or the next `runAllowFail`, whichever comes first."""
    out = []
    calls = [m.start() for m in re.finditer(r"\brunAllowFail\s*\(", code)]
    for i, at in enumerate(calls):
        end = calls[i + 1] if i + 1 < len(calls) else len(code)
        region = code[at:end]
        # The argv is the first argument; git calls name it as a bare string.
        head = region[:400]
        if not re.search(r'"git"', head):
            continue
        out.append((at, region))
    return out


def problems_in(rel: str, code: str):
    found = []
    for at, region in blocks_reading_git(code):
        rewrite = REWRITE.search(region)
        if not rewrite:
            # Nothing rewrites this value, so the order cannot be wrong. Whether
            # it is trimmed at all is a different question and not this gate's.
            continue
        trim = TRIM.search(region)
        line = code[:at].count("\n") + 1
        if trim is None:
            found.append(
                f"{rel}:{line} rewrites a git result with a `for (…) |*c|` loop and "
                f"never trims it. Git ends its output with a newline and the loop "
                f"will turn that newline into whatever the loop's replacement "
                f"character is."
            )
        elif trim.start() > rewrite.start():
            found.append(
                f"{rel}:{line} trims a git result *after* rewriting it. By then the "
                f"trailing newline is no longer whitespace, so the trim finds "
                f"nothing -- which is exactly how `version_pre` came to be "
                f"\"HEAD-\" while a `trimEnd` sat in the same function."
            )
    return found


# -- self-test ---------------------------------------------------------------

RIGHT = '''
    const tmp = b.runAllowFail(&.{ "git", "rev-parse" }, &code, .ignore) catch return err;
    const trimmed = tmp[0..std.mem.trimEnd(u8, tmp, "\\r\\n ").len];
    for (trimmed) |*c| { if (!ok(c.*)) c.* = '-'; }
'''

WRONG = '''
    const tmp = b.runAllowFail(&.{ "git", "rev-parse" }, &code, .ignore) catch return err;
    for (tmp) |*c| { if (!ok(c.*)) c.* = '-'; }
    const trimmed = std.mem.trimEnd(u8, tmp, "\\r\\n ");
'''

NONE = '''
    const tmp = b.runAllowFail(&.{ "git", "rev-parse" }, &code, .ignore) catch return err;
    for (tmp) |*c| { if (!ok(c.*)) c.* = '-'; }
'''

NOT_A_GIT_CALL = '''
    const out = b.runAllowFail(&.{ "pkg-config", "--variable=targets" }, &code, .ignore) catch return .{};
    for (out) |*c| { c.* = 'x'; }
'''

PROSE = '''
    // Trim first, then rewrite: std.mem.trimEnd before the for (x) |*c| loop.
    const tmp = b.runAllowFail(&.{ "git", "rev-parse" }, &code, .ignore) catch return err;
    const trimmed = tmp[0..std.mem.trimEnd(u8, tmp, "\\r\\n ").len];
    for (trimmed) |*c| { if (!ok(c.*)) c.* = '-'; }
'''


def self_test() -> bool:
    cases = (
        ("the right order", RIGHT, 0),
        ("the wrong order", WRONG, 1),
        ("no trim at all", NONE, 1),
        ("not a git call", NOT_A_GIT_CALL, 0),
        ("prose about the rule", PROSE, 0),
    )
    for name, body, want in cases:
        got = len(problems_in("probe.zig", strip_comments(body)))
        if got != want:
            print(
                f"FAIL: self-test broken -- {name} gave {got} finding(s), expected "
                f"{want}. A checker that cannot tell these apart says nothing "
                f"about src/build."
            )
            return False
    print(
        "probe self-test: OK (right order, wrong order, no trim, a non-git call "
        "and prose about the rule are told apart)"
    )
    return True


def main() -> int:
    if not self_test():
        return 2

    files = sorted(
        n for n in os.listdir(BUILD_DIR) if n.endswith(".zig")
    ) if os.path.isdir(BUILD_DIR) else []
    if not files:
        print(
            f"FAIL: no .zig files under {BUILD_DIR}. This gate's whole subject is "
            f"what is in them; finding none is a broken scan, not a clean result."
        )
        return 1

    scanned = 0
    git_calls = 0
    problems = []
    for name in files:
        path = os.path.join(BUILD_DIR, name)
        code = strip_comments(open(path, encoding="utf-8", errors="replace").read())
        scanned += 1
        rel = os.path.relpath(path, ROOT)
        git_calls += len(blocks_reading_git(code))
        problems.extend(problems_in(rel, code))

    print(f"{scanned} file(s) under src/build, {git_calls} call(s) that run git.")
    print(f"not git: {NOT_GIT}")
    print(
        "NOT CHECKED: whether a git result that nothing rewrites is trimmed at "
        "all. That value cannot acquire a hyphen, which is the failure this "
        "gate exists for; a trailing newline in it is a different bug."
    )

    if problems:
        print()
        for p in problems:
            print(f"FAIL: {p}")
        return 1

    print("OK: every git result that gets rewritten is trimmed first.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
