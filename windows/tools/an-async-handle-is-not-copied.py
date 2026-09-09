#!/usr/bin/env python3
"""A wakeup handle is held by value only by whoever created it.

**Written from a pane that stopped repainting and a `notify` that reported
success.** `xev.Async` is one type with two implementations that keep their
state in different places. On Linux and the BSDs the struct holds a single
descriptor, so the object that matters lives in the kernel and a copy of the
struct still refers to it. The IOCP implementation keeps everything --
including the field `wait()` fills in with the loop and completion to post to
-- inside the struct.

So a copy taken before `wait()` runs is a handle with nothing to wake. Calling
`notify()` on it takes the other branch, sets a flag nobody reads, **returns
success and wakes nobody.** It does not fail, it does not log, and the same
source is correct on Linux.

That is what happened here: the terminal's IO side was handed a copy of the
renderer thread's handle, so output arriving from the program could not wake
the renderer. Keyboard and mouse used the original, so a terminal being typed
into looked healthy, and a pane whose program writes while nobody touches it
froze until the window was touched again.

**The rule.** A file may hold `xev.Async` fields by value only if it creates
that many of them itself. Holding one by value without creating it means it
came from somewhere else -- which is the copy. Handles that come from
elsewhere are held as `*xev.Async`.

⚠️ **What this does not cover.** It does not see a *containing* struct being
copied: a type that legitimately owns a handle can still be copied wholesale,
and the copy is just as dead. `termio.Mailbox` is copied exactly that way
today and is safe only because the copy happens before `wait()` -- which is
timing, not structure. That is out of reach for a reader that looks at
declarations.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "src"

# A struct field holding the handle by value. Indented or not; the name is
# whatever the field is called.
BY_VALUE = re.compile(r"^[ \t]*([A-Za-z_]\w*): xev\.Async,\s*$", re.MULTILINE)

# Creating one. A file that creates N may hold N by value.
CREATES = re.compile(r"xev\.Async\.init\s*\(")

# Mentions the type at all, so files with nothing to say are not subjects.
MENTIONS = re.compile(r"\bxev\.Async\b")

# ⚠️ Exceptions are named with the reason. An empty reason is not an
# exception.
EXEMPT: dict[str, str] = {}


def offenders(text: str) -> int:
    """How many handles this text holds by value beyond the ones it creates."""
    return max(0, len(BY_VALUE.findall(text)) - len(CREATES.findall(text)))


def main() -> int:
    # The probe is the defect as it was actually written against the fix.
    bad = "renderer_wakeup: xev.Async,\n"
    good_owner = "wakeup: xev.Async,\nvar w = try xev.Async.init();\n"
    good_ptr = "renderer_wakeup: *xev.Async,\n"
    probe_ok = (
        offenders(bad) == 1
        and offenders(good_owner) == 0
        and offenders(good_ptr) == 0
        and MENTIONS.search(bad)
    )
    print(
        "probe self-test:",
        "OK (a borrowed copy, an owner's own handle and a pointer are told apart)"
        if probe_ok
        else "FAILED -- the reader is broken, so nothing below means anything",
    )
    if not probe_ok:
        return 2

    subjects = 0
    bad_files = []
    for path in sorted(SRC.rglob("*.zig")):
        rel = path.relative_to(ROOT).as_posix()
        if rel in EXEMPT:
            continue
        text = path.read_text(encoding="utf-8")
        if not MENTIONS.search(text):
            continue
        subjects += 1
        n = offenders(text)
        if n:
            for m in BY_VALUE.finditer(text):
                line = text[: m.start()].count("\n") + 1
                bad_files.append((rel, line, m.group(1)))

    # ⚠️ **Nothing to look at is not a pass.** If the type were renamed this
    # loop would find no subjects and return 0, which reads exactly like a
    # tree where every handle is held correctly.
    if subjects == 0:
        print(
            "FAIL: no file under src/ mentions xev.Async at all. Either the type\n"
            "      was renamed or this checker reads for a shape that no longer\n"
            "      exists. Passing would say 'no handle is copied' about no handles."
        )
        return 1

    print(f"{subjects} file(s) under src/ mentioning xev.Async were read.")
    if bad_files:
        print("FAIL: a wakeup handle is held by value by something that did not create it:")
        for rel, line, name in bad_files:
            print(f"      {rel} line {line}: `{name}: xev.Async`")
        print(
            "      A handle that came from somewhere else must be held as\n"
            "      `*xev.Async`. Copied, its `notify` returns success and wakes\n"
            "      nobody -- on Windows only, and without a word in the log."
        )
        return 1

    print("Nothing to report: every handle held by value is held by its creator.")
    print(
        "NOT CHECKED: a struct that owns a handle being copied wholesale (the copy\n"
        "             is just as dead; `termio.Mailbox` is copied and is safe only\n"
        "             because it happens before `wait()`), handles passed as\n"
        "             function parameters, and anything about runtime behaviour."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
