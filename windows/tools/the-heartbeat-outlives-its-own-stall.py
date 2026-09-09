#!/usr/bin/env python3
"""A heartbeat printed after the work cannot report the work not finishing.

**Written from a pane that stopped repainting for reasons nobody could
separate.** Two explanations survived every reading: the renderer thread was
alive and returning early every time it woke, or it had stopped inside its
own callback and would never wake again. From outside the two are identical
-- the pane holds its last frame either way, the surface still answers, the
locks are still gettable, frames are still presented by other paths.

The heartbeat exists to separate them, and it can only do that if it is
**reported before the work and confirmed after**. A single line at the end
says "this callback finished", which is exactly the case that is not in
question; the one that matters -- a callback that started and never came back
-- prints nothing at all, and nothing at all is what a thread that was never
woken also prints.

**The rule.** In the renderer thread's wakeup callback: the counter is
incremented and reported before the mailbox is drained, and the completion
counter is incremented after the work. A final log line whose `wakeup` is one
ahead of its `completed` is then the signature of a stall, and the reader can
say where it stopped rather than only that it stopped.

⚠️ This is a structural check. **It cannot see whether the line is ever
reached** -- an early return above it, or a log sink that drops `info`, both
leave the same silence this instrument was built to interpret.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
THREAD = ROOT / "src" / "renderer" / "Thread.zig"

STARTED = re.compile(r"\bwakeups\s*\+=\s*1")
REPORTED = re.compile(r'log\.\w+\("\[rthread\]')
WORK = re.compile(r"\bdrainMailbox\s*\(")
COMPLETED = re.compile(r"\bwakeups_completed\s*\+=\s*1")


def body_of(text: str, fn: str) -> str | None:
    """The body of `fn fn(...) ... {  }`, by brace matching."""
    m = re.search(r"\bfn\s+" + re.escape(fn) + r"\b", text)
    if not m:
        return None
    i = text.index("{", m.end())
    depth = 1
    j = i + 1
    while j < len(text) and depth:
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
        j += 1
    return text[i + 1 : j - 1]


def verdict(body: str) -> list[str]:
    """Every way this body's heartbeat fails to survive a stall."""
    problems = []
    started = STARTED.search(body)
    reported = REPORTED.search(body)
    work = WORK.search(body)
    completed = COMPLETED.search(body)
    if not started or not reported:
        problems.append("no heartbeat is reported at all")
        return problems
    if not work:
        problems.append("the work this heartbeat brackets was not found")
        return problems
    if reported.start() > work.start():
        problems.append(
            "the heartbeat is reported after the work, so a callback that "
            "never returns prints nothing"
        )
    if not completed:
        problems.append(
            "nothing marks the callback as completed, so a line cannot say "
            "whether the thread came back out"
        )
    elif completed.start() < work.start():
        problems.append(
            "completion is recorded before the work, so it says nothing about "
            "the work finishing"
        )
    return problems


def main() -> int:
    good = 'wakeups += 1; log.info("[rthread] x", .{}); drainMailbox(); wakeups_completed += 1;'
    # ⚠️ The probe's bad case is the real regression: the line still exists,
    # still says the same thing, and is one move away from useless.
    bad = 'wakeups += 1; drainMailbox(); log.info("[rthread] x", .{}); wakeups_completed += 1;'
    probe_ok = not verdict(good) and verdict(bad)
    print(
        "probe self-test:",
        "OK (a heartbeat before the work and after it are told apart)"
        if probe_ok
        else "FAILED -- the reader is broken, so nothing below means anything",
    )
    if not probe_ok:
        return 2

    text = THREAD.read_text(encoding="utf-8")
    body = body_of(text, "wakeupCallback")

    # ⚠️ **Nothing to look at is not a pass.** If the callback has been
    # renamed, `body` is None and an early `return 0` would report a healthy
    # instrument in a tree that has none.
    if body is None:
        print(
            "FAIL: wakeupCallback was not found in src/renderer/Thread.zig -- either\n"
            "      it was renamed, or this checker is reading the wrong file. Passing\n"
            "      would say 'the heartbeat is sound' about no heartbeat."
        )
        return 1

    print("1 renderer wakeup callback was read.")
    problems = verdict(body)
    if problems:
        print("FAIL: the renderer thread's heartbeat cannot report its own stall:")
        for p in problems:
            print(f"      {p}")
        return 1

    print("Nothing to report: the heartbeat is reported before the work and confirmed after.")
    print(
        "NOT CHECKED: whether the line is reached (an early return above it looks\n"
        "             the same as a stall), whether the sink keeps `info`, and the\n"
        "             heartbeat's interval."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
