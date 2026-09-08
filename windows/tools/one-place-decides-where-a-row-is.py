#!/usr/bin/env python3
"""The palette's row geometry is worked out in one place, and only one.

# The defect this is the floor for

`uia.rs` answered `BoundingRectangle` with the **window's** rectangle for every
one of the palette's rows. Measured on the machine: ninety rows, all
`x=440 y=52 w=560 h=350`. A client cannot see that it has been given the same
answer ninety times -- it takes the centre of the rectangle, clicks, and **the
click succeeds and runs a different command**.

The comment that chose it said a row rectangle would be "a second copy of the
geometry `palette.rs` paints with". **The second copy already existed**: the
`WM_LBUTTONDOWN` hit test carried the inverse of the same formula. So the
choice had never been one copy against two; it was two against three.

There is now one, `row_rect_at`, and three callers: the painter, the hit test,
and the provider. **That is the property this file exists to keep**, because
losing it costs nothing visible -- a second copy agrees with the first until
the day somebody changes one of them, and then a click selects one row and
runs another.

# What is checked

  1. **The row's `y` is computed once.** The shape
     `sc(EDIT_H) + n * sc(ROW_H)` -- in any spelling this can recognise --
     may appear in `palette.rs` exactly once, inside `row_rect_at`.
  2. **The inverse is not written down at all.** `(y - ...) / ...` over the
     same two constants is how the hit test used to disagree with the painter
     at a boundary.
  3. **The provider asks rather than derives.** `uia.rs` must mention
     `palette::row_rect` and must not mention `ROW_H` or `EDIT_H`.

# NOT CHECKED

  * **Whether the formula is right.** That is `row_geometry_tests` in
    `palette.rs`, and those run only on Windows -- the host crate does not
    build for the machine this checker runs on. This file guards the *shape*,
    not the arithmetic.
  * **Whether the rectangle matches what is drawn on a real screen.** One
    function cannot disagree with itself, which is the point, but "what the
    painter computes" and "what the user sees" are still two things and only a
    machine can compare them.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PALETTE = os.path.join(HERE, "..", "host", "src", "palette.rs")
UIA = os.path.join(HERE, "..", "host", "src", "uia.rs")


def strip_comments(src):
    return "\n".join(re.sub(r"//.*", "", ln) for ln in src.split("\n"))


def findings(palette_src, uia_src):
    out = []
    p = strip_comments(palette_src)
    u = strip_comments(uia_src)

    forward = re.findall(r"sc\(\s*EDIT_H\s*\)\s*\+", p)
    if len(forward) != 1:
        out.append(
            f"the row's `y` is worked out {len(forward)} time(s) in palette.rs; it must be "
            "worked out once, in `row_rect_at`. A second copy agrees with the first until "
            "somebody changes one, and then a click selects one row and runs another"
        )
    inverse = re.findall(r"-\s*sc\(\s*EDIT_H\s*\)\s*\)\s*/\s*sc\(\s*ROW_H\s*\)", p)
    if inverse:
        out.append(
            "the inverse of the row formula is written out in palette.rs. That is what the "
            "hit test used to carry, and an inverse is a second chance to disagree with the "
            "thing it is the inverse of -- at a boundary it selects one row and runs another"
        )
    if "palette::row_rect" not in u:
        out.append(
            "uia.rs does not ask `palette::row_rect`. If the provider works a row's place "
            "out for itself, it is the second copy again -- and the client cannot see that "
            "the answer is wrong, it just clicks and runs something else"
        )
    for name in ("ROW_H", "EDIT_H"):
        if re.search(r"\b%s\b" % name, u):
            out.append(
                f"uia.rs mentions `{name}`. The provider must ask where a row is, not know"
            )
    return out


GOOD_P = """
fn row_rect_at(top: usize, dpi: i32, width: i32, index: usize) -> Option<RECT> {
    let y = sc(EDIT_H) + n as i32 * sc(ROW_H);
    Some(RECT { left: 0, top: y, right: width, bottom: y + sc(ROW_H) })
}
fn paint() { let r = row_rect_at(st.top, dpi, rc.right, idx); }
fn hit() { let i = row_at_y(st.top, dpi, rc.right, y); }
"""
GOOD_U = "fn BoundingRectangle() { crate::palette::row_rect(self.index) }\n"


def self_test():
    cases = [
        ("the shape today", GOOD_P, GOOD_U, 0),
        ("the painter growing its own copy",
         GOOD_P + "fn paint2() { let y = sc(EDIT_H) + n * sc(ROW_H); }\n", GOOD_U, 1),
        ("the inverse back in the hit test",
         GOOD_P + "fn hit2() { let row = (y - sc(EDIT_H)) / sc(ROW_H); }\n", GOOD_U, 1),
        ("the provider deriving instead of asking",
         GOOD_P, "fn BoundingRectangle() { let y = EDIT_H + i * ROW_H; }\n", 3),
        # **Comments must not count**, and the decoys carry the whole shape --
        # a decoy that the scan would not have matched anyway proves nothing.
        ("the same formulas in comments only",
         GOOD_P + "// let y = sc(EDIT_H) + n * sc(ROW_H);\n"
                  "// let row = (y - sc(EDIT_H)) / sc(ROW_H);\n",
         GOOD_U + "// ROW_H and EDIT_H are palette.rs's business\n", 0),
    ]
    for what, ps, us, want in cases:
        got = len(findings(ps, us))
        if got != want:
            print(f"probe self-test FAILED: {what} gave {got} finding(s), expected {want}:")
            for f in findings(ps, us):
                print(f"    {f}")
            return False
    print("probe self-test: OK (second forward copy, the inverse, a deriving provider, "
          "the same formulas in comments)")
    return True


def main():
    if not self_test():
        return 1
    try:
        with open(PALETTE, encoding="utf-8") as fh:
            p = fh.read()
        with open(UIA, encoding="utf-8") as fh:
            u = fh.read()
    except OSError as e:
        print(f"cannot read the palette or the provider: {e}")
        return 1
    found = findings(p, u)
    n = len(re.findall(r"row_rect_at\(", strip_comments(p)))
    print(f"palette.rs: the row formula is written once and called {n - 1} time(s) besides "
          "its own definition; uia.rs asks for it rather than deriving it")
    for f in found:
        print(f"HIT    {f}")
    if found:
        print(f"\n{len(found)} problem(s): more than one place decides where a palette row is.")
        return 1
    print("OK: one formula, and the provider asks it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
