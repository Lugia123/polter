#!/usr/bin/env python3
r"""A quit is called off in one place, so everything a quit started can be called off with it.

# Why this exists

Switching the language offers "Restart Now", which starts a process that
waits for this app to exit and then reopens it, and then asks the app to
quit. The quit can be refused -- a terminal still running something brings
up "Quit Polter?" with a Cancel -- and for as long as the refusals were
written out where each was needed (three places, two of them inside async
Tasks) none of them stopped the waiting process. It sat there until the next
quit, hours later, and reopened the app (issue #12).

The fix makes a refusal a function: `cancelTermination()` answers
`.terminateCancel`, `cancelTerminationLater()` answers
`reply(toApplicationShouldTerminate: false)`, and both call off the pending
relaunch first. That only holds while nothing refuses a quit any other way,
and a refusal written inline somewhere new would compile, behave, and
quietly bring the bug back. This gate is that condition.

Note what the obvious alternative fix does: moving the relaunch to
`applicationWillTerminate` needs a "relaunch pending" flag, and a refused
quit that does not clear it reopens the app on the next quit just the same.
The defect moves from a live process to a stale boolean; it does not go.
Either way the refusals have to be in one place.

# What it checks

In every `.swift` file under `macos/Sources`: each
`reply(toApplicationShouldTerminate: false)` and each `.terminateCancel`
lies inside the body of `cancelTermination` or `cancelTerminationLater` in
`AppDelegate.swift`. Bodies are found by brace matching from the `func`
line. Both functions must exist, and each must hold its refusal, or the
gate fails rather than finding nothing to object to.

# NOT CHECKED

- That the two functions call off the relaunch: their own code and tests.
- A refusal spelled another way (a stored `NSApplication.TerminateReply`
  value, `reply(toApplicationShouldTerminate: someBool)` that happens to be
  false). Only the two literal forms are read.
- Comments are not stripped: a comment that quotes either form outside the
  two functions fails the gate. Say "the refusal" in prose instead.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "macos" / "Sources"
HOME = SOURCES / "App" / "AppDelegate.swift"
ALLOWED = ("cancelTermination", "cancelTerminationLater")
REFUSALS = (
    re.compile(r"reply\(toApplicationShouldTerminate:\s*false\)"),
    re.compile(r"\.terminateCancel\b"),
)


def body_span(text, name):
    """(start, end) character offsets of `func name(...)`'s body, or None."""
    m = re.search(r"\bfunc\s+" + re.escape(name) + r"\s*\(", text)
    if m is None:
        return None
    open_at = text.find("{", m.end())
    if open_at < 0:
        return None
    depth = 0
    for i in range(open_at, len(text)):
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return (open_at, i)
    return None


def line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def main():
    problems = []
    files = sorted(SOURCES.rglob("*.swift"))
    if not files:
        print(f"FAIL: no Swift files under {SOURCES} -- nothing was checked")
        return 1

    try:
        home = HOME.read_text(encoding="utf-8")
    except OSError as e:
        print(f"FAIL: cannot read {HOME}: {e}")
        return 1
    spans = {}
    for name in ALLOWED:
        span = body_span(home, name)
        if span is None:
            problems.append(f"{HOME.relative_to(ROOT)}: no func {name} -- the one place a quit is called off is gone")
        else:
            spans[name] = span

    found = 0
    inside = {name: 0 for name in spans}
    for path in files:
        text = path.read_text(encoding="utf-8")
        rel = path.relative_to(ROOT)
        for pattern in REFUSALS:
            for m in pattern.finditer(text):
                found += 1
                owner = next((n for n, (a, b) in spans.items() if path == HOME and a < m.start() < b), None)
                if owner:
                    inside[owner] += 1
                    continue
                problems.append(
                    f"{rel}:{line_of(text, m.start())}: `{m.group(0)}` outside {' / '.join(ALLOWED)} -- "
                    f"a quit refused here would leave a pending relaunch running (issue #12); "
                    f"call cancelTermination() or await cancelTerminationLater() instead")

    for name, n in inside.items():
        if n == 0:
            problems.append(f"{HOME.relative_to(ROOT)}: {name} holds no refusal -- it no longer calls the quit off")

    if problems:
        print("FAIL: a quit is being called off somewhere other than the one place that also calls off what it started:")
        for p in problems:
            print(f"      {p}")
        return 1

    print(f"{found} refusal(s) across {len(files)} Swift files, all inside {' / '.join(ALLOWED)}.")
    print("NOT CHECKED: refusals spelled another way; that the two functions call off the relaunch.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
