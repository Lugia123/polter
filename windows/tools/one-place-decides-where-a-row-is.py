#!/usr/bin/env python3
"""A list's row geometry is worked out in one place, and only one.

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

# Why this file was rewritten

It named `palette.rs` and read nothing else. When the keybind page was given
its own element tree (task 360) it arrived with its own row formula and its
own provider, and **this checker said nothing at all** -- it printed a green
line about the palette while the second instance of the very thing it guards
was being built one file over. A checker with a list of what it covers puts
every new case outside itself by default, and the day it goes quiet is the day
something new was written.

So it no longer has a list. **It finds the pages.** Any file under `host/src`
that defines a `..._row_rect_at` is a page, and every one of them is held to
the same rules; a page that has no such function is caught from the other end,
because a provider that answers a rectangle without asking anybody for it is a
finding on its own.

# What is checked

  1. **The row's `y` is worked out once per page.** The multiply that turns a
     row number into an offset may appear once, inside that page's
     `row_rect_at`. *Which* scaled height it multiplies by is how a page's
     formula is told from another list in the same file -- `settings_ui.rs`
     holds two lists and only one of them is a page here.
  2. **The inverse is not written down at all.** Dividing back from a `y` to a
     row number is how the hit test used to disagree with the painter at a
     boundary.
  3. **Every `BoundingRectangle` asks.** In `uia.rs` each one must call
     something whose name ends in `_rect`/`_rects`, and none of them may name
     a page's layout constants. A provider that knows where a row is, is the
     second copy again.

⚠️ A page's painter usually has a scaling closure of its own -- `s` next to
the definition's `sc` -- so both spellings count. A rule that only knew the
one the definition uses stayed green through a painter that had grown its own
copy, which is the first draft of this file and the reason that case is in the
self-test.

# NOT CHECKED

  * **Whether any formula is right.** The geometry tests in `palette.rs` and
    `settings_ui.rs` say that, and they run only on Windows -- the host crate
    does not build for the machine this checker runs on. This file guards the
    *shape*, not the arithmetic.
  * **Whether a rectangle matches what is drawn on a real screen.** One
    function cannot disagree with itself, which is the point, but "what the
    painter computes" and "what the user sees" are still two things and only a
    machine can compare them.
  * **The plugin list in `settings_ui.rs`**, which is the same shape and is
    *not* covered: its painter works a row out at line 1666 and its click
    handler divides back at line 1514 -- **two copies, one of them an
    inverse**, which is exactly the pair the palette's bug was made of. It is
    outside this checker because nothing reads it but itself: that page has no
    provider, so a disagreement between those two lines can misplace a click
    at a row boundary but cannot lie to a client about where a row is. Written
    down here rather than left to be discovered, because a checker that walked
    past it silently would be the same failure this file was rewritten for.
    ⚠️ **If that page ever gets a provider, it must get a `row_rect_at`
    first**, and then this checker covers it with no change.
  * **A page that paints rows and defines no `row_rect_at` at all**, if its
    provider also never answers a per-row rectangle. There is then nothing to
    disagree about yet -- and the moment a provider is written for it, rule 3
    has it.
  * **Scrolling, DPI and where the client area is on screen.** A row's
    rectangle passes through a published snapshot and `ClientToScreen` before
    a client sees it, and neither is read here.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "host", "src")
UIA_NAME = "uia.rs"

DEFINES_PAGE = re.compile(r"\bfn\s+(\w*row_rect_at)\s*\(")
ASKS = re.compile(r"\b\w+_rects?\s*\(")
# The scaled height a row number is multiplied by, in either spelling of the
# scaling call.
HEIGHT_IN = re.compile(r"\*\s*sc?\(\s*([A-Z][A-Z_0-9]*)\s*\)")


def forward(h):
    return re.compile(r"\*\s*sc?\(\s*%s\s*\)" % re.escape(h))


def inverse(h):
    # `(y - top) / (H * sc / 96)` and `/ s(H)` alike: anything that divides
    # the row height back out of a coordinate.
    return re.compile(r"/\s*\(?\s*(?:sc?\()?\s*%s\b" % re.escape(h))


def strip_comments(src):
    return "\n".join(re.sub(r"//.*", "", ln) for ln in src.split("\n"))


def body_of(src, start):
    """The braced block that starts at or after `start`."""
    i = src.find("{", start)
    if i < 0:
        return ""
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i : j + 1]
    return src[i:]


def pages(sources):
    """Every source that defines a row formula, and the name of that function.

    **This is the default-include part.** A new page is a page because it has
    the function, not because it is written down here.
    """
    out = {}
    for name, src in sources.items():
        if name == UIA_NAME:
            continue
        m = DEFINES_PAGE.search(strip_comments(src))
        if m:
            out[name] = m.group(1)
    return out


def layout_constants(src, fn_name):
    """The `i32` constants the page's formula is written in terms of."""
    plain = strip_comments(src)
    declared = set(re.findall(r"\bconst\s+([A-Z][A-Z_0-9]*)\s*:\s*i32", plain))
    m = re.search(r"\bfn\s+%s\s*\(" % re.escape(fn_name), plain)
    if not m:
        return set()
    body = body_of(plain, m.end())
    return {c for c in declared if re.search(r"\b%s\b" % c, body)}


def findings(sources):
    out = []
    uia = strip_comments(sources.get(UIA_NAME, ""))
    found = pages(sources)

    if not found:
        out.append(
            "no file under host/src defines a `row_rect_at`. Either this checker's search "
            "stopped matching or the one place that decides where a row is has gone; both "
            "are worth stopping for"
        )

    banned = {}
    for name, fn in sorted(found.items()):
        plain = strip_comments(sources[name])
        m = re.search(r"\bfn\s+%s\s*\(" % re.escape(fn), plain)
        body = body_of(plain, m.end()) if m else ""
        heights = HEIGHT_IN.findall(body)
        if len(heights) != 1:
            out.append(
                f"{name}: `{fn}` multiplies a row number by {len(heights)} scaled height(s); "
                "this checker reads the one it uses to tell that page's formula from any "
                "other list in the same file, and cannot do that with none or several"
            )
            continue
        h = heights[0]
        rest = plain.replace(body, "", 1)
        elsewhere = forward(h).findall(rest)
        if elsewhere:
            out.append(
                f"{name}: the row's `y` is worked out {len(elsewhere)} more time(s) outside "
                f"`{fn}`. A second copy agrees with the first until somebody changes one, "
                "and then a click selects one row and runs another"
            )
        if inverse(h).search(rest):
            out.append(
                f"{name}: the inverse of the row formula is written out, over `{h}`. That is "
                "what the palette's hit test used to carry, and an inverse is a second chance "
                "to disagree with the thing it is the inverse of -- at a boundary it selects "
                "one row and runs another"
            )
        asked = fn[: -len("_at")]  # `row_rect_at` -> `row_rect`
        module = name[:-3]
        if f"{module}::{asked}" not in uia:
            out.append(
                f"uia.rs does not ask `{module}::{asked}`. If the provider works a row's "
                "place out for itself, it is the second copy again -- and the client cannot "
                "see that the answer is wrong, it just clicks and runs something else"
            )
        for c in layout_constants(sources[name], fn):
            banned[c] = name

    for c, name in sorted(banned.items()):
        if re.search(r"\b%s\b" % c, uia):
            out.append(
                f"uia.rs mentions `{c}`, which is {name}'s layout. The provider must ask "
                "where a row is, not know"
            )

    for m in re.finditer(r"\bfn\s+BoundingRectangle\s*\(", uia):
        body = body_of(uia, m.end())
        if not ASKS.search(body):
            line = uia[: m.start()].count("\n") + 1
            out.append(
                f"uia.rs:{line}: a `BoundingRectangle` answers without asking anything for "
                "a rectangle. Whatever it works out there is a second copy of a layout, and "
                "a wrong rectangle is invisible to the client that clicks it"
            )
    return out


# The decoys carry the whole shape: one that the scan would not have matched
# anyway proves nothing about the scan.
GOOD_P = """
const ROW_H: i32 = 26;
const EDIT_H: i32 = 30;
fn row_rect_at(top: usize, dpi: i32, width: i32, index: usize) -> Option<RECT> {
    let sc = |v: i32| v * dpi / 96;
    let y = sc(EDIT_H) + n as i32 * sc(ROW_H);
    Some(RECT { left: 0, top: y, right: width, bottom: y + sc(ROW_H) })
}
fn paint() { let r = row_rect_at(st.top, dpi, rc.right, idx); }
"""
GOOD_K = """
const KB_HEADER: i32 = 56;
const KB_ROW_H: i32 = 24;
fn kb_row_rect_at(top: usize, dpi: i32, width: i32, index: usize) -> Option<RECT> {
    let sc = |v: i32| v * dpi / 96;
    let y = sc(PAD + KB_HEADER) + n as i32 * sc(KB_ROW_H);
    Some(RECT { left: 0, top: y, right: width, bottom: y + sc(KB_ROW_H) })
}
"""
GOOD_U = """
fn BoundingRectangle(&self) -> WResult<UiaRect> { Ok(crate::palette::row_rect(self.index)) }
fn BoundingRectangle(&self) -> WResult<UiaRect> { Ok(crate::settings_ui::kb_row_rect(i)) }
"""


def self_test():
    def case(p=GOOD_P, k=GOOD_K, u=GOOD_U, extra=None):
        s = {"palette.rs": p, "settings_ui.rs": k, UIA_NAME: u}
        if extra:
            s.update(extra)
        return s

    cases = [
        ("the shape today", case(), 0),
        ("the painter growing its own copy",
         case(p=GOOD_P + "fn paint2() { let y = sc(EDIT_H) + n as i32 * sc(ROW_H); }\n"), 1),
        # **The spelling that got past the first draft of this rule.** A page's
        # painter has a scaling closure of its own, so a second copy does not
        # have to look like the definition to be one.
        ("the painter's copy written with the page's own scaler",
         case(k=GOOD_K + "fn kb_paint() { let y = s(PAD + KB_HEADER) + o as i32 * s(KB_ROW_H); }\n"), 1),
        ("the inverse back in the hit test",
         case(p=GOOD_P + "fn hit2() { let row = (y - sc(EDIT_H)) / sc(ROW_H); }\n"), 1),
        ("a provider that derives instead of asking",
         case(u="fn BoundingRectangle(&self) -> WResult<UiaRect> { let y = EDIT_H + i * ROW_H; }\n"
                "fn BoundingRectangle(&self) -> WResult<UiaRect> { Ok(crate::settings_ui::kb_row_rect(i)) }\n"),
         4),
        ("the same formulas in comments only",
         case(p=GOOD_P + "// let y = sc(EDIT_H) + n as i32 * sc(ROW_H);\n"
                         "// let row = (y - sc(EDIT_H)) / sc(ROW_H);\n",
              u=GOOD_U + "// ROW_H and EDIT_H are palette.rs's business\n"), 0),
        # **The one the old version could not do.** A page nobody added to a
        # list is still a page, and its provider is held to the same rule.
        ("a third page nobody told the checker about",
         case(extra={"tasklist.rs": """
const TL_TOP: i32 = 40;
const TL_ROW_H: i32 = 20;
fn tl_row_rect_at(top: usize, dpi: i32, width: i32, index: usize) -> Option<RECT> {
    let sc = |v: i32| v * dpi / 96;
    let y = sc(TL_TOP) + n as i32 * sc(TL_ROW_H);
    Some(RECT { left: 0, top: y, right: width, bottom: y + sc(TL_ROW_H) })
}
"""}), 1),
        ("every page gone", {UIA_NAME: GOOD_U}, 1),
    ]
    ok = True
    for what, sources, want in cases:
        got = findings(sources)
        if len(got) != want:
            print(f"probe self-test FAILED: {what} gave {len(got)} finding(s), expected {want}:")
            for f in got:
                print(f"    {f}")
            ok = False
    if ok:
        print("probe self-test: OK (a second forward copy in two spellings, the inverse, a "
              "deriving provider, comments, an unlisted third page, and no pages at all)")
    return ok


def main():
    if not self_test():
        return 1
    try:
        sources = {}
        for name in sorted(os.listdir(SRC)):
            if name.endswith(".rs"):
                with open(os.path.join(SRC, name), encoding="utf-8") as fh:
                    sources[name] = fh.read()
    except OSError as e:
        print(f"cannot read host/src: {e}")
        return 1

    found = pages(sources)
    for name, fn in sorted(found.items()):
        n = len(re.findall(r"\b%s\s*\(" % re.escape(fn), strip_comments(sources[name])))
        print(f"{name}: `{fn}` is written once and called {n - 1} time(s) besides its own "
              "definition")
    n_bounds = len(
        re.findall(r"\bfn\s+BoundingRectangle\s*\(", strip_comments(sources.get(UIA_NAME, "")))
    )
    print(f"uia.rs: {n_bounds} BoundingRectangle(s), each asking for a rectangle rather than "
          "working one out")

    problems = findings(sources)
    for f in problems:
        print(f"HIT    {f}")
    if problems:
        print(f"\n{len(problems)} problem(s): more than one place decides where a row is.")
        return 1
    print("OK: one formula per page, and every provider asks.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
