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
  * **Whether a page with rows is in the accessibility tree at all.** This
    checker used to require it: every `*_row_rect_at` had to be asked about by
    `uia.rs`. That is a real claim and worth keeping -- **it is task 418** --
    but it is a different claim from this file's subject, and a checker that
    asserts two things cannot tell you which of them broke. The plugin list
    made the ambiguity concrete: it became the first page with a row formula
    and no provider, so the rule fired at a refactor that was entirely right.
    ⚠️ **The direction that remains is the one that is this subject**: a
    provider must ask rather than work a row's place out for itself. The
    reverse -- every table must have a provider -- is gone from here.
    **Written down because a rule that is removed and not accounted for leaves
    a weaker checker and no trace of why.**
  * **The plugin list's arithmetic.** It now has `plugin_row_rect_at` and its
    click asks it, so the shape is covered here; whether the rectangle is the
    one drawn is still a question only a machine can answer. The pair it used
    to carry is worth remembering as the cleanest example of this family:
    the painter went forwards and the click divided back, and
    **`(y - PAD*sc/96)` is negative in the padding above the first row, where
    Rust's integer division truncates toward zero -- so `-1 / 42` is `0` and
    the padding selected row 0.** Two formulas that agree everywhere anyone
    would think to click, and disagree only where nobody looks.
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
    """Every row formula there is, as `(file, function)` pairs.

    **This is the default-include part.** A page is a page because it has the
    function, not because it is written down here.

    ⚠️ **Every one of them, not the first one in each file.** This used to
    return a dict keyed by file, so a file with two formulas contributed one
    -- and adding a second to `settings_ui.rs` silently dropped the first from
    the subject set. The checker stayed green, its output stayed the same
    length, and it had stopped watching a page. **That is this file's own
    subject happening one level up**: not "the formula got a second copy", but
    "the thing the checker was looking at got swapped for another one", and
    the two are indistinguishable in a passing run.
    """
    out = []
    for name, src in sorted(sources.items()):
        if name == UIA_NAME:
            continue
        for m in DEFINES_PAGE.finditer(strip_comments(src)):
            out.append((name, m.group(1)))
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
    for name, fn in found:
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
        # **The reverse-direction rule used to be here and has been split out.**
        #
        # It required every page with a row formula to be asked about by
        # `uia.rs` -- which is a claim that every page with rows belongs in the
        # accessibility tree. True, and worth doing, and **not this checker's
        # subject**: this one is "one place decides where a row is". A checker
        # that asserts two things cannot tell you which of them broke, and the
        # first page without a provider (the plugin list) made exactly that
        # ambiguity concrete. It is task 418 now.
        #
        # ⚠️ The direction that remains is the one that is this subject: a
        # provider must **ask** rather than work a row's place out for itself.
        # That is checked below, per `BoundingRectangle`.
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
        # Three, not four: the fourth was the reverse-direction rule that went
        # to task 418. The three that remain are all this subject -- a
        # provider knowing a layout instead of asking for it -- and the phrase
        # below pins that, so this cell cannot start passing on some other
        # rule's finding the way the third-page cell did.
        ("a provider that derives instead of asking",
         case(u="fn BoundingRectangle(&self) -> WResult<UiaRect> { let y = EDIT_H + i * ROW_H; }\n"
                "fn BoundingRectangle(&self) -> WResult<UiaRect> { Ok(crate::settings_ui::kb_row_rect(i)) }\n"),
         3, "must ask where a row is"),
        ("the same formulas in comments only",
         case(p=GOOD_P + "// let y = sc(EDIT_H) + n as i32 * sc(ROW_H);\n"
                         "// let row = (y - sc(EDIT_H)) / sc(ROW_H);\n",
              u=GOOD_U + "// ROW_H and EDIT_H are palette.rs's business\n"), 0),
        # **The one the old version could not do.** A page nobody added to a
        # list is still a page, and it is held to the same rule.
        #
        # ⚠️ **This cell used to prove something else.** Its page carried only
        # a definition -- no second copy, no inverse -- so the single finding
        # it produced came from the reverse-direction rule ("uia.rs does not
        # ask this page"), not from the subject. It read like a guard on the
        # subject for as long as both rules lived here, and when the reverse
        # rule was split out to task 418 the cell went silently empty. **A
        # self-test that passes by testing the wrong rule is the shape this
        # whole file exists to catch**, so the page now carries the thing the
        # subject is about, and the assertion names which finding it wants.
        ("a third page nobody told the checker about",
         case(extra={"tasklist.rs": """
const TL_TOP: i32 = 40;
const TL_ROW_H: i32 = 20;
fn tl_row_rect_at(top: usize, dpi: i32, width: i32, index: usize) -> Option<RECT> {
    let sc = |v: i32| v * dpi / 96;
    let y = sc(TL_TOP) + n as i32 * sc(TL_ROW_H);
    Some(RECT { left: 0, top: y, right: width, bottom: y + sc(TL_ROW_H) })
}
fn tl_paint2() {
    let sc = |v: i32| v * dpi / 96;
    let y = sc(TL_TOP) + n as i32 * sc(TL_ROW_H);
}
"""}), 1, "worked out"),
        # **Two formulas in one file, and only one of them has a second
        # copy.** Without this cell the subject set could quietly shrink to
        # one formula per file again -- which is how a whole page stopped
        # being watched while the output stayed the same length and the exit
        # code stayed 0. The finding must name the formula that actually has
        # the copy, so the cell cannot be satisfied by noticing the other one.
        ("two formulas in one file, one of them copied",
         case(k=GOOD_K + """
const P_ROW_H: i32 = 30;
const P_PAD: i32 = 12;
fn plug_row_rect_at(dpi: i32, index: usize) -> RECT {
    let s = |v: i32| v * dpi / 96;
    let y = s(P_PAD) + index as i32 * s(P_ROW_H);
    RECT { left: 0, top: y, right: 0, bottom: y + s(P_ROW_H) }
}
fn plug_paint2() {
    let s = |v: i32| v * dpi / 96;
    let y = s(P_PAD) + i as i32 * s(P_ROW_H);
}
"""), 1, "plug_row_rect_at"),
        ("every page gone", {UIA_NAME: GOOD_U}, 1),
    ]
    ok = True
    for entry in cases:
        what, sources, want = entry[0], entry[1], entry[2]
        # **The count is not the claim.** A cell can produce the right number
        # of findings from the wrong rule -- this one did, for as long as two
        # rules lived here -- so a cell may also name a phrase its finding has
        # to contain.
        must_contain = entry[3] if len(entry) > 3 else None
        got = findings(sources)
        if len(got) != want:
            print(f"probe self-test FAILED: {what} gave {len(got)} finding(s), expected {want}:")
            for f in got:
                print(f"    {f}")
            ok = False
        elif must_contain and not any(must_contain in f for f in got):
            print(f"probe self-test FAILED: {what} gave {want} finding(s), but none of them "
                  f"is the one this cell is about ({must_contain!r}):")
            for f in got:
                print(f"    {f}")
            ok = False
    if ok:
        print("probe self-test: OK (a second forward copy in two spellings, the inverse, a "
              "deriving provider, comments, an unlisted third page, two formulas in one "
              "file, and no pages at all)")
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
    for name, fn in found:
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
