#!/usr/bin/env python3
"""A `WM_PAINT` that validates without drawing is a paint request thrown away.

**Written from a defect whose every readable layer was correct.** After a
rearrangement a pane sat showing the frame it had drawn for where it used to
be: the tree was right, the geometry was right, `terminal_read` returned the
right text, and the screen was old. Nothing had asked for a new frame -- the
pane's `WM_PAINT` fell straight through to `ValidateRect`, which tells Windows
the pixels are fine, and nothing had made them fine.

⚠️ **That shape is silent by construction.** `ValidateRect` cannot fail, the
window is not damaged afterwards, and every log line in the system is about a
layer that was already correct. The only thing to check is the shape itself:
**an arm that validates must also have asked for pixels.**

⚠️ **The first version of this checker could not catch the defect it was
written for**, and a mutation showed it: the arm asked for pixels behind
`--draw-on-paint` and swallowed them everywhere else, so "the arm mentions a
request" was satisfied while the shipped path threw the request away. What is
required is the *shipped* answer -- `surface_refresh`, which schedules a
render on any build. `surface_draw` behind a flag is an experiment, not an
answer.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "windows" / "host" / "src"

# **The shipped answer, not any answer.** `surface_draw` sits behind
# `--draw-on-paint`; an arm that only has that one answers nobody's paint
# request in an ordinary build.
ASKS = re.compile(r"surface_refresh\s*\)")
VALIDATES = re.compile(r"\bValidateRect\s*\(")


def arms(text: str):
    """Every `WM_PAINT => { ... }` arm in a window procedure, with its body."""
    for m in re.finditer(r"WM_PAINT\s*=>\s*\{", text):
        depth = 1
        i = m.end()
        while i < len(text) and depth:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        yield m.start(), text[m.end() : i]


def main() -> int:
    # The probe: a body that validates and asks is fine; one that only
    # validates is not. Both shapes are checked here, so a reader that has
    # stopped seeing either is caught before its answer is used.
    good = "(api().surface_refresh)(s); let _ = ValidateRect(Some(hwnd), None);"
    # ⚠️ The probe's bad case is the defect's real shape, not an empty arm:
    # a request that exists only behind the experiment flag.
    bad = (
        "if crate::draw_on_paint() { (api().surface_draw)(s); } "
        "let _ = ValidateRect(Some(hwnd), None);"
    )
    probe_ok = (
        VALIDATES.search(good)
        and ASKS.search(good)
        and VALIDATES.search(bad)
        and not ASKS.search(bad)
    )
    print(
        "probe self-test:",
        "OK (validating with a request and without are told apart)"
        if probe_ok
        else "FAILED -- the reader is broken, so nothing below means anything",
    )
    if not probe_ok:
        return 2

    swallowed = []
    checked = 0
    for path in sorted(SRC.glob("*.rs")):
        text = path.read_text(encoding="utf-8")
        for off, body in arms(text):
            if not VALIDATES.search(body):
                continue  # this arm paints some other way; not this checker's subject
            checked += 1
            if not ASKS.search(body):
                line = text[:off].count("\n") + 1
                swallowed.append((path.name, line))

    # ⚠️ **Nothing to look at is not a pass.** A reader that has stopped
    # finding the arms returns 0 with a clean-looking line, and that exit code
    # is indistinguishable from a tree where every arm is fine. The subject
    # set is what has to be non-empty; zero *hits* is a real answer, zero
    # *subjects* is not an answer at all.
    if checked == 0:
        print(
            "FAIL: no WM_PAINT arm that validates was found at all -- this checker is\n"
            "      looking in the wrong place, or the shape it reads has changed.\n"
            "      Passing here would say 'every arm is fine' about no arms."
        )
        return 1

    print(f"{checked} WM_PAINT arm(s) that validate the window were read.")
    if swallowed:
        print("FAIL: a WM_PAINT arm validates the window without asking for pixels:")
        for name, line in swallowed:
            print(f"      {name} line {line}")
        print(
            "      `ValidateRect` tells Windows the pixels are fine. If nothing drew\n"
            "      them, the window keeps whatever it had -- and no layer anybody\n"
            "      reads will disagree."
        )
        return 1

    print("Nothing to report: every arm that validates has asked for pixels first.")
    print(
        "NOT CHECKED: arms that paint without `ValidateRect` (`BeginPaint`/`EndPaint`\n"
        "             validate on their own), and whether the pixels asked for arrive."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
