#!/usr/bin/env python3
"""A swap-chain permit must come back exactly once, and before anything waits.

The renderer's swap chain hands out a fixed number of frames through a
semaphore. `nextFrame` takes a permit and blocks -- with no timeout -- until
one is free; `releaseFrame` gives it back. Both ways of getting that wrong are
silent, and both were in the tree at once:

**Released twice.** `drawFrame` armed an unconditional `errdefer
releaseFrame()` and then, once the frame context existed, a `defer
complete()` that also releases on every exit including the failing ones. Any
error after that point posted the semaphore twice. An over-posted semaphore
hands out more permits than there are frames, so the CPU writes frame state
the GPU is still reading -- the precise race the swap chain exists to
prevent, showing up as tearing or flickering cells and never as anything
that names a semaphore.

**Released too late.** `frameCompleted` reported renderer health into the app
mailbox -- a *blocking* send, drained by the UI thread -- and released the
permit afterwards. A UI thread busy long enough to fill that mailbox parked
the renderer thread there, so the permit never came back, so the next
`nextFrame` blocked forever and the pane stopped drawing permanently. A
moment of slowness became a dead surface.

⚠️ **This is a structural check.** It reads the order of statements, not what
happens at runtime, and the failures above are concurrency timing: no unit
test in this repo exercises either. In particular it **cannot see an early
return** that skips the release entirely, and it cannot tell whether the
send it is keeping behind the release is really the only one that can wait.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GENERIC = ROOT / "src" / "renderer" / "generic.zig"

RELEASE = re.compile(r"\bswap_chain\.releaseFrame\s*\(")
ERRDEFER_RELEASE = re.compile(r"errdefer\s+(?P<guard>if\s*\([^)]*\)\s*)?self\.swap_chain\.releaseFrame")
COMPLETE = re.compile(r"defer\s+frame_ctx\.complete\s*\(")
BLOCKING_SEND = re.compile(r"\.forever\b")


def body_of(text: str, fn: str) -> str | None:
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


def double_release(body: str) -> bool:
    """True when an error path can release the frame twice."""
    ed = ERRDEFER_RELEASE.search(body)
    if not ed:
        return False
    if not COMPLETE.search(body):
        return False  # nothing else releases; the errdefer is the only path
    # The errdefer is fine only if it is conditional, so it can be disarmed
    # once the thing that also releases has taken over.
    return ed.group("guard") is None


def late_release(body: str) -> str | None:
    """The blocking send that happens before the permit comes back, if any."""
    rel = RELEASE.search(body)
    if rel is None:
        return "nothing releases the frame at all"
    send = BLOCKING_SEND.search(body)
    if send is None:
        return None
    if send.start() < rel.start():
        return "a blocking send runs before the permit is returned"
    return None


def main() -> int:
    # The probes are the two defects as they were actually written, against
    # the two shapes that fix them.
    bad_double = "errdefer self.swap_chain.releaseFrame();\nvar frame_ctx = x;\ndefer frame_ctx.complete(sync);"
    good_double = "var owned = true;\nerrdefer if (owned) self.swap_chain.releaseFrame();\nvar frame_ctx = x;\nowned = false;\ndefer frame_ctx.complete(sync);"
    bad_late = '_ = self.surface_mailbox.push(.{ .h = h }, .{ .forever = {} });\nself.swap_chain.releaseFrame();'
    good_late = 'self.swap_chain.releaseFrame();\n_ = self.surface_mailbox.push(.{ .h = h }, .{ .forever = {} });'

    probe_ok = (
        double_release(bad_double)
        and not double_release(good_double)
        and late_release(bad_late)
        and not late_release(good_late)
    )
    print(
        "probe self-test:",
        "OK (a double release and a late release are both told apart)"
        if probe_ok
        else "FAILED -- the reader is broken, so nothing below means anything",
    )
    if not probe_ok:
        return 2

    text = GENERIC.read_text(encoding="utf-8")
    draw = body_of(text, "drawFrame")
    completed = body_of(text, "frameCompleted")

    # ⚠️ **Nothing to look at is not a pass.** If either function has been
    # renamed this reads nothing and would otherwise report a healthy tree.
    missing = [n for n, b in (("drawFrame", draw), ("frameCompleted", completed)) if b is None]
    if missing:
        print(
            "FAIL: could not find " + ", ".join(missing) + " in src/renderer/generic.zig.\n"
            "      Either they were renamed, or this checker reads a shape that no\n"
            "      longer exists. Passing would say 'the permit is handled correctly'\n"
            "      about code it never looked at."
        )
        return 1

    print("2 swap-chain permit sites were read (drawFrame, frameCompleted).")
    problems = []
    if double_release(draw):
        problems.append(
            "drawFrame: an unconditional `errdefer releaseFrame` coexists with "
            "`defer frame_ctx.complete`, which also releases -- an error after "
            "the context is created posts the semaphore twice"
        )
    late = late_release(completed)
    if late:
        problems.append("frameCompleted: " + late)

    if problems:
        print("FAIL: a swap-chain permit is not returned exactly once and first:")
        for p in problems:
            print(f"      {p}")
        return 1

    print("Nothing to report: the permit is returned once, and before anything that waits.")
    print(
        "NOT CHECKED: early returns that skip the release entirely, whether the\n"
        "             `.forever` found is the only call that can wait, and anything\n"
        "             about the actual interleaving at runtime."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
