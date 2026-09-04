#!/usr/bin/env python3
"""Line-number references, which drift and do not say that they have.

A pointer written as `file.rs:‹digits›` names a place that moves. Any edit
above it -- an edit with nothing to do with what was being pointed at --
slides the target, and **the reference does not break, it lies**. It does not
404. It sends the reader to some unrelated code and lets them conclude they
misread it.

**This is measured, not feared.** `s4.md` points at `log_line` by line number
and names line 506. It is at 520: fourteen lines of drift, on a reference that
carries a rule ("every criterion line goes through `logf!`, never
`println!`"). Nobody edited that sentence and nothing went red.

**And the shortest possible feedback loop for it happened in one session**: two
documents pointed at a line in this very directory, giving its number as 307;
the same author, in the same hour, added a comment block above it and pushed it
to 311. Writing the reference and invalidating it were the same afternoon.

(The prose above deliberately spells those numbers the one way this checker
does not match -- see the boundary note. A checker that flags the sentence
explaining it is a checker somebody turns off.)

The fix at the call site is free: name the symbol. `keyseq.rs::mods_label`,
`Config.zig`'s `Keybinds.init`, `Set.putFlags`'s `track_reverse`. A symbol
survives edits above it, and when it is renamed **a search finds the
reference**. A line number is found by nobody.

WHAT THIS CHECKS
----------------

Two spellings, because checking one and calling it done is the mistake that
produced this file. A grep for the first form was written, announced, and run
-- and it missed the two freshest references in the tree, because they were
written the other way:

  1. `path.ext:‹digits›` -- a filename, a colon, a number, and any range or
     list hanging off the same colon.
  2. `第 N 行` -- the same reference in Chinese, which form (1) cannot see.
     **Only when a file is named beside it**, on the same line and within a
     short reach: either an actual filename with an extension, or one of the
     words that stands in for one (`该文件`, `本文件`, ...). Without that
     guard this form is mostly noise -- see the boundary below.

WHAT THIS DOES NOT CHECK
------------------------

The edge is the useful half of a checker's documentation, so:

  * **English prose spellings** -- "line 42", "lines 10-20". Not matched.
    They do not appear in this tree today; adding them is a one-line change
    to `PATTERNS` and a new baseline.
  * **Anything outside this port.** The scan is `docs/windows/`,
    `windows/host/src/` and `windows/tools/`. `docs/` at large belongs to
    upstream Ghostty and is not this ratchet's business -- including it would
    raise the number with references nobody here maintains, and a ratchet
    whose number moves for reasons the reader cannot act on is a ratchet the
    reader learns to re-baseline without looking.
  * **Whether the number is currently right.** It cannot know. It objects to
    the form, because the form is what makes being wrong invisible.

**A ratchet, not a pass/fail.** There were 77 of these when this was written
(76 in the first spelling, 1 in the second).
Failing outright would block every commit until somebody finishes a mechanical
job, and until then it blocks the innocent. So the number is pinned: going up
fails (a new drifting reference), going down also fails, with the number to
write in -- otherwise progress rolls back silently, which is the failure this
whole file is about.

Exit: 0 if the count equals the baseline, 1 otherwise.
"""

import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")

# The scan. See the boundary note above for why it stops here.
GLOBS = (
    "docs/windows/*.md",
    "windows/host/src/*.rs",
    "windows/tools/*.py",
)

# 1. `name.ext:12`, `name.ext:12,34`, `name.ext:12-20`.
#    The extension list is what this tree actually cites; a bare `foo:12` is
#    not matched, so timestamps (`02:19`) and ratios stay out by construction.
PATH_LINE = re.compile(
    r"\b[A-Za-z0-9_.\-/\\]+\.(?:rs|py|zig|md|toml|ps1|swift|rc|manifest|h|c)"
    r"\s*:\s*\d+(?:\s*[,\-]\s*\d+)*"
)
# 2. The same thing in Chinese -- **but only when a file is named beside it.**
#
# `第 N 行` on its own is mostly not a source reference in this tree. It is the
# fourth row of a table, the first line of a pasted log, "the log stopped at
# line 24". Five of the eight occurrences here are that, and **a checker with a
# five-to-one false-positive rate is a checker somebody turns off** -- and the
# person who turns it off does not come back. So the number has to be tied to a
# file to count: a real filename with an extension, or one of the words that
# stands in for one.
CN_LINE = re.compile(r"第\s*\d+\s*行")
CN_NEEDS_FILE = re.compile(
    r"(?:\.(?:rs|py|zig|md|toml|ps1|swift|rc|manifest|h|c)\b|该文件|本文件|同一文件|同一个文件|该脚本|本脚本)"
)
# How far back to look for it. Same line only: a filename on the previous line
# is a different sentence, and reaching into it is how the guard would quietly
# stop guarding.
CN_REACH = 60

PATTERNS = (("path", PATH_LINE),)

# How many references were in the tree when this ratchet was set.
#
# **Measured, not chosen.** Lower it as they are replaced with symbol names;
# the check tells you the number to write.
BASELINE = 77

# Print at most this many, with their line numbers. A reader needs somewhere
# to start, not the whole list.
LIST_LINES = 12

# Everything below this marker in *this* file is the self-test, and is not
# scanned. **The canaries have to contain real references to be canaries**,
# and a checker that counted its own probes would report a number that moves
# when the probes change -- which is a second thing the baseline would be
# tracking without saying so.
SELF_TEST_MARKER = "# ---- self-test ----"


def body(path: str, src: str) -> str:
    """The part of a file this check looks at."""
    if os.path.abspath(path) == os.path.abspath(__file__):
        return src.split(SELF_TEST_MARKER)[0]
    return src


def hits_in(src: str):
    """Every reference, as `(offset, kind, text)`."""
    out = []
    for kind, pat in PATTERNS:
        for m in pat.finditer(src):
            out.append((m.start(), kind, m.group(0)))
    for m in CN_LINE.finditer(src):
        line_start = src.rfind("\n", 0, m.start()) + 1
        back = src[max(line_start, m.start() - CN_REACH):m.start()]
        if CN_NEEDS_FILE.search(back):
            out.append((m.start(), "cn", m.group(0)))
    out.sort()
    return out


def line_of(src: str, at: int) -> int:
    return src[:at].count("\n") + 1


def scan():
    found = []
    files = 0
    for pattern in GLOBS:
        for path in sorted(glob.glob(os.path.join(ROOT, pattern))):
            if "__pycache__" in path:
                continue
            try:
                with open(path, encoding="utf-8") as fh:
                    src = body(path, fh.read())
            except (OSError, UnicodeDecodeError):
                continue
            files += 1
            for at, kind, text in hits_in(src):
                found.append((os.path.relpath(path, ROOT), line_of(src, at), kind, text))
    return files, found


# ---- self-test ----
#
# **Both directions, and the second one is the one that keeps this check
# alive.** A checker that also flags version numbers and timestamps gets
# switched off within a day, and the person who switches it off does not come
# back. So the things that must *not* match are pinned as hard as the things
# that must.

CANARY_HIT = """
`log_line` is at main.rs:506, and the rule lives there.
See Config.zig:6920-6924 and settings_ui.rs:968,1316,1644.
`hlogf!` 被无条件算作已分类（该文件第 307 行）。
`keycodes.zig` 里 Win 列为 0x0000 的，线性扫描第一个撞上的是第 184 行。
"""

# **Every line below is a real occurrence from this tree, not an invented one.**
# Five of the eight `第 N 行` in `docs/windows` are these: table rows, lines of a
# pasted log, "the log stopped at line 24". They were flagged by the first
# version of this check, which is how the guard above came to exist -- so they
# are kept here as the specimens they are. A constructed near-miss proves that
# the author imagined the failure; these prove it happened.
CANARY_MISS = """
> **第 4 行这个区间和它 2026-08-31 之前的写法数值上接近**
> ⚠️ **第 1 行是状态相关的，不是一个静态结论。**
    **「日志停在第 24 行、进程还在、什么都不发生」**
    这四行被贴进群里至少五次,每次都只有第 2 行被核对。
| `[reopen] opener installed` 在第 16 行 | 死锁那次也在第 16 行 |
The core version is 0.16 and the build is 1.2.3.
The log line reads [02:19:07.442] and the next is at 02:20:09.100.
SM_CXVSCROLL=17, and the ratio is 4:3, and port 8080 is free.
See `keyseq.rs::mods_label` and `Config.zig`'s `Keybinds.init`.
A path with no line: windows/host/src/winid.rs, and a range 10-20.
"""


def self_test() -> bool:
    got = [t for _, _, t in hits_in(CANARY_HIT)]
    want = {
        "main.rs:506",
        "Config.zig:6920-6924",
        "settings_ui.rs:968,1316,1644",
        "第 307 行",
        "第 184 行",
    }
    missing = want - set(got)
    if missing:
        print(f"probe self-test FAILED: these were not seen: {sorted(missing)}")
        return False

    noise = [t for _, _, t in hits_in(CANARY_MISS)]
    if noise:
        print(f"probe self-test FAILED: these were flagged and must not be: {noise}")
        return False

    print(
        "probe self-test: OK (both spellings and their ranges are seen; versions, "
        "timestamps, ratios, ports and symbol references are not)"
    )
    return True


def main() -> int:
    if not self_test():
        return 1

    files, found = scan()
    n = len(found)
    by_kind = {}
    for _, _, kind, _ in found:
        by_kind[kind] = by_kind.get(kind, 0) + 1

    print(
        f"scanned {files} files: {n} line-number reference(s) "
        f"({by_kind.get('path', 0)} as `file.ext:N`, {by_kind.get('cn', 0)} as `第 N 行`)"
    )

    if n != BASELINE:
        shown = found if n > BASELINE else found[:LIST_LINES]
        for path, line, _kind, text in shown:
            print(f"       {path}:{line}  {text}")
        if len(found) > len(shown):
            print(f"       ... and {len(found) - len(shown)} more")

    if n > BASELINE:
        print(
            f"\nFAIL: {n - BASELINE} more than the baseline ({BASELINE}). A reference was "
            f"added that\n"
            f"      points at a line rather than at a name. It is right today and says "
            f"nothing\n"
            f"      on the day it stops being right. Name the symbol instead:\n"
            f"      `keyseq.rs::mods_label`, `Config.zig`'s `Keybinds.init`."
        )
        return 1

    if n < BASELINE:
        print(
            f"\nFAIL, and it is good news: {BASELINE - n} fewer than the baseline.\n"
            f"      Set BASELINE = {n}.\n"
            f"      Failing on the way down is deliberate: otherwise the count creeps "
            f"back up\n"
            f"      to a baseline nobody re-measured, and nothing says so."
        )
        return 1

    print(f"line-number references: {n}, unchanged from the baseline")
    return 0


if __name__ == "__main__":
    sys.exit(main())
