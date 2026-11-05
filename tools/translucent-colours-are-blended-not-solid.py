#!/usr/bin/env python3
"""A translucent look colour written straight into `rgb(...)` is a tripwire.

`control_room::rgb` (`windows/host/src/control_room.rs`) turns an `Rgba`
into a `COLORREF` and **drops alpha**. A solid brush made from a translucent
colour therefore paints its RGB as though it were opaque: task 2978 M1 was
exactly that -- the located message row came out solid blue and a found word
solid yellow, where the design has 8%/28% tints. The compositing fill is
`control_room::fill_rgba`, which uses `AlphaBlend` (source-over).

**What this gate catches**, and it is deliberately narrow: a window is
scanned one line at a time for a **literal** `rgb(` on the same line as
`theme.<name>`, where `<name>` is a colour whose light or dark value carries
`@a` with a < 1. Hairlines (`line`, `line_faint`, one device pixel wide and
painted solid before this rule) are named exceptions.

**What it cannot see** -- measured, not guessed: fed task 2978's own B22
state, it caught 2 of the 3 bare uses and **missed the worst one** (the
located row), because that call site read
`let fill = theme.search_target; ... rgb(fill)`. The same blind spots, all
of which this script reports `OK` for:

  * a colour put in a local first (`let c = theme.search_hit; rgb(c)`), and
    in particular the located row's real B22 shape
    `let fill = if lit { theme.search_target } else { … }; rgb(fill)` —
    the second review reproduced this form and got `OK`;
  * a call split over lines (`rgb(\\n    theme.search_hit\\n)`);
  * a field destructured out of the theme (`let Theme { search_hit, .. }`);
  * a `COLORREF(...)` assembled by hand instead of through `rgb`.

So **`OK` is not proof that translucency is composited**; it is proof that
no one wrote the direct one-line form again. The proof is `fill_rgba` and
the readings of the pixels on a real window.

A self-test runs first and holds the direct form and the hairline exception:
if the matcher stops recognising either, the gate fails rather than passing
quietly. It also asserts the alias form is *not* recognised, so widening the
scope is a deliberate edit here, not an accident.

Run:  python3 tools/translucent-colours-are-blended-not-solid.py
Exit: 0 when the narrow rule holds and the self-test agrees; 1 otherwise
      (including when nothing was scanned).
"""

import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
DATA = "src/input/control-room-look.json"
HOST_SOURCES = "windows/*/src/**/*.rs"

# One-pixel separators painted solid before this rule existed.
HAIRLINES = {"line", "line_faint"}

RGB_CALL = re.compile(r"\brgb\(")
THEME_FIELD = re.compile(r"theme\.([A-Za-z_][A-Za-z0-9_]*)")


def translucent(colours):
    """The colour names this gate protects: a < 1 in either theme."""
    out = set()
    for name, value in colours.items():
        if not isinstance(value, dict):
            continue
        for theme in ("light", "dark"):
            text = value.get(theme)
            if not isinstance(text, str) or "@" not in text:
                continue
            try:
                alpha = float(text.rsplit("@", 1)[1])
            except ValueError:
                continue
            if alpha < 1.0:
                out.add(name)
    return out


def flagged(line, alpha):
    """The translucent fields a single line hands to `rgb(...)`."""
    if not RGB_CALL.search(line):
        return []
    return [
        m.group(1)
        for m in THEME_FIELD.finditer(line)
        if m.group(1) in alpha and m.group(1) not in HAIRLINES
    ]


def self_test():
    """The matcher's own cases. A wrong matcher must not read as a clean tree."""
    alpha = {"search_hit", "line", "line_faint"}
    cases = [
        ("CreateSolidBrush(rgb(theme.search_hit))", ["search_hit"]),
        ("rgb(theme.line)", []),
        ("rgb(theme.line_faint)", []),
        ("let fill = theme.search_target; rgb(fill)", []),
        ("rgb(", []),
    ]
    for line, want in cases:
        got = flagged(line, alpha)
        if got != want:
            print(f"FAIL: self-test: {line!r} gave {got!r}, wanted {want!r}")
            return False
    return True


def main():
    if not self_test():
        return 1
    if not os.path.isdir(os.path.join(ROOT, "windows")):
        print(f"not a Polter checkout: {ROOT} has no windows/ in it")
        return 1
    data_path = os.path.join(ROOT, DATA)
    if not os.path.isfile(data_path):
        print(f"FAIL: {DATA} is missing, so no colour can be checked.")
        return 1
    with open(data_path, encoding="utf-8") as f:
        data = json.load(f)
    alpha = translucent(data.get("colors", {}))
    if not alpha:
        print(f"FAIL: {DATA} names no translucent colour; the rule has nothing to read.")
        return 1

    problems = []
    scanned = 0
    for pattern in HOST_SOURCES.split():
        for path in sorted(glob.glob(os.path.join(ROOT, pattern), recursive=True)):
            scanned += 1
            rel = os.path.relpath(path, ROOT)
            with open(path, encoding="utf-8", errors="replace") as f:
                for number, line in enumerate(f, 1):
                    for name in flagged(line, alpha):
                        problems.append(
                            f"{rel}:{number}: `{name}` is translucent but goes through rgb(...): {line.strip()}"
                        )
    if scanned == 0:
        problems.append(f"no host source was looked at: {HOST_SOURCES} matched no file.")

    if problems:
        print("FAIL: a translucent colour is painted as a solid brush:")
        for p in problems:
            print("      " + p)
        return 1

    print(
        f"OK (narrow rule): {scanned} Windows host sources hold no one-line bare rgb(...) of "
        f"the {len(alpha)} translucent colours (hairlines allowed: {', '.join(sorted(HAIRLINES))})."
    )
    print(
        "NOT CHECKED: local aliases (`let c = theme.x; rgb(c)`), calls split over lines, "
        "destructured themes, hand-built COLORREF; the macOS host; that anything is drawn at all."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
