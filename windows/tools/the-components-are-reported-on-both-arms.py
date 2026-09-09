#!/usr/bin/env python3
"""The numbers behind a decision are reported where it is made, not on one arm.

**Written from an instrument that measured nothing for a whole release.** The
renderer computes `needs_redraw` from four quantities and then either draws a
frame or takes an early return. The four were printed inside the early
return, because whoever added them -- me -- pictured a frozen pane taking that
branch.

On Windows it never does. Every wakeup of a completely idle terminal computes
`needs_redraw = true` and draws a full frame, so across 168 measured phase
lines that branch was entered exactly zero times. The verdict was visible in
every log and the four numbers that say *why* it holds were in none of them,
which is the one question the investigation needed answered.

⚠️ **An instrument on one arm of a branch is a bet on which way it goes.**
While the question is open both arms are candidates, so the reading has to sit
where the answer is computed.

**What this reads.** The phase line carrying the components must appear
between the end of the expression that computes the verdict and the `if` that
branches on it -- not nested inside either arm.

⚠️ It reads position, not truth: a line placed correctly that prints the wrong
quantities passes here.

⚠️ **On the empty-tree control this gate is saved by the wrong mechanism.**
`gates-fail-on-empty.py` builds a tree with the subject *directories* present
but empty; the file this reads is then missing entirely, so it exits non-zero
by raising rather than by noticing it had nothing to look at. The guard below
-- the one that fails when the names have moved -- is therefore never
exercised by that control, and a change that removed it would not be caught
there. It was checked by hand instead: with the guard replaced by `return []`,
the empty-tree control still reported every gate as guarded.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GENERIC = ROOT / "src" / "renderer" / "generic.zig"

VERDICT = re.compile(r"const needs_redraw =")
BRANCH = re.compile(r"if \(!needs_redraw\) \{")
COMPONENTS = re.compile(r'"\[rphase\][^"]*at=decide[^"]*"')


def verdict(text: str) -> list[str]:
    """Every way the components fail to be readable on both arms."""
    v = VERDICT.search(text)
    b = BRANCH.search(text)
    c = COMPONENTS.search(text)
    if not v:
        return ["the expression computing the verdict was not found"]
    if not b:
        return ["the branch on the verdict was not found"]
    if not c:
        return ["no phase line reports the components at all"]
    if c.start() > b.start():
        return [
            "the components are reported after the branch begins, so they are "
            "on one arm only -- whichever arm the machine does not take, the "
            "numbers cannot be read"
        ]
    if c.start() < v.start():
        return [
            "the components are reported before the verdict is computed, so "
            "the line cannot carry the verdict it is about"
        ]
    return []


def main() -> int:
    good = 'const needs_redraw =\n a or b;\nlog.info("[rphase] x at=decide y", .{});\nif (!needs_redraw) {\n r();\n}'
    # ⚠️ The bad case is the real regression: the line still exists, still
    # prints the same five numbers, and is one indentation level away from
    # never being printed at all.
    bad = 'const needs_redraw =\n a or b;\nif (!needs_redraw) {\n log.info("[rphase] x at=decide y", .{});\n r();\n}'
    probe_ok = not verdict(good) and verdict(bad)
    print(
        "probe self-test:",
        "OK (a reading at the decision and one inside an arm are told apart)"
        if probe_ok
        else "FAILED -- the reader is broken, so nothing below means anything",
    )
    if not probe_ok:
        return 2

    text = GENERIC.read_text(encoding="utf-8")

    # ⚠️ **Nothing to look at is not a pass.** If the names moved, the checks
    # below find nothing, and returning 0 would report a sound instrument in a
    # tree that has none.
    problems = verdict(text)

    print("1 decision site was read (needs_redraw, in src/renderer/generic.zig).")
    if problems:
        print("FAIL: the numbers behind the decision are not readable both ways:")
        for p in problems:
            print(f"      {p}")
        return 1

    print("Nothing to report: the components are reported where the verdict is computed.")
    print(
        "NOT CHECKED: whether the quantities printed are the right ones, whether\n"
        "             the line is compiled in (it sits behind a build switch), and\n"
        "             every other instrument in the file."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
