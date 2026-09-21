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

# Two shapes, not one (task 654)

`surface_refresh` is how a *terminal* pane answers: it is asynchronous, it
posts to the renderer thread, and the arm itself never touches a pixel. The
inspector's `WM_PAINT` (`inspector.rs`) is a different, later-arriving window
that answers the same question a different, equally real way: it renders
*synchronously*, in the same call, and presents with `SwapBuffers` before
`ValidateRect` runs. Both are "asked for pixels before saying the pixels are
fine"; only the first is `surface_refresh`, so a checker that only knew that
one read the second as the defect it is not.

**The second shape, precisely**: the arm -- or a function in this same file
that the arm calls directly -- calls both `ghostty_inspector_opengl_render`
(the pixels) and `SwapBuffers` (presenting them) in code that is not inside an
`if false { ... }` block. The `if false` exclusion is not decoration: it is
what makes "the call is gone but the text is still in the file" (commenting
out by disabling, the way this repository prefers over deleting a line and
risking a compile error standing in for a floor) actually register as gone
here too.

⚠️ **One level of call-following, not a general call graph.** `sync_paint_fns`
looks at top-level `fn` bodies in the same file for the two markers; an arm
that calls a function which calls *another* function that renders is invisible
to it. That is deliberate: the inspector's shape is arm -> one local `fn` ->
the two calls, and reading further is exactly the kind of call-graph work a
regex-based checker should not be trusted to do silently.
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

# The second shape (task 654): synchronous render-then-present, the way a
# window with its own GL context answers instead of posting to a renderer
# thread. Both must appear, in code `strip_comments` and `strip_dead_if_false`
# have not removed.
RENDERS = re.compile(r"inspector_opengl_render")
SWAPS = re.compile(r"\bSwapBuffers\s*\(")

FN_HEADER = re.compile(r"\bfn\s+(\w+)\s*\([^;{]*\{")


def strip_comments(text: str) -> str:
    """`//` comments out, newlines kept so line numbers still point at the
    file. `paint`'s own doc comment names `ghostty_inspector_opengl_render`
    in prose -- without this, that line alone would satisfy `RENDERS` and the
    `if false` test in the report this task asked for would not turn red.
    Load-bearing for the same reason `a-position-is-not-an-identity.py`'s
    copy of this function is: a checker that reads a comment as code has
    happened in this repository more than once.
    """
    return re.sub(r"//[^\n]*", "", text)


def _balanced(text: str, open_at: int) -> int:
    """Index just past the `{` at `open_at`'s matching `}`."""
    depth = 1
    i = open_at + 1
    while i < len(text) and depth:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    return i


def strip_dead_if_false(body: str) -> str:
    """Remove the contents of every `if false { ... }` block.

    **Why this exists at all.** This repository disables code by wrapping it
    in `if false { ... }` rather than deleting the line, precisely so a
    compile error cannot stand in for a floor going red (see `windows/AGENTS.md`
    and the memory this task's report cites). A checker that greps the whole
    function body for a marker cannot tell "this call runs" from "this call's
    text is still here, behind `if false`" -- so disabling the call this way
    would silently keep satisfying a naive version of this check. Stripping
    the dead block's contents first is what makes disabling the render call
    inside `paint()` actually turn this checker red again, which is the floor
    task 654's report was required to demonstrate.
    """
    out = []
    i = 0
    for m in re.finditer(r"\bif\s+false\s*\{", body):
        if m.start() < i:
            continue  # inside a block already stripped
        out.append(body[i : m.start()])
        end = _balanced(body, m.end() - 1)
        i = end
    out.append(body[i:])
    return "".join(out)


def top_level_fns(text: str):
    """`(name, body)` for every top-level `fn` in this file, brace-balanced."""
    for m in FN_HEADER.finditer(text):
        open_at = m.end() - 1
        end = _balanced(text, open_at)
        yield m.group(1), text[open_at + 1 : end - 1]


def sync_paint_fns(text: str) -> set:
    """Names of `fn`s in this file that render and present synchronously."""
    found = set()
    for name, body in top_level_fns(strip_comments(text)):
        live = strip_dead_if_false(body)
        if RENDERS.search(live) and SWAPS.search(live):
            found.add(name)
    return found


def arm_asks_sync(body: str, sync_fns: set) -> bool:
    """Whether an arm's body itself renders+presents, or calls a `fn` that
    does -- in either case, only in code that is not `if false`-disabled
    and not commented out."""
    live = strip_dead_if_false(strip_comments(body))
    if RENDERS.search(live) and SWAPS.search(live):
        return True
    return any(re.search(rf"\b{re.escape(name)}\s*\(", live) for name in sync_fns)


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

    # The second probe: the synchronous shape, read the same two ways an
    # inspector-style window actually is -- inline in the arm, and one call
    # away in a helper `fn` -- plus the `if false` exclusion that is the
    # whole reason `strip_dead_if_false` exists.
    sync_file = (
        "fn paint(hwnd: HWND) {\n"
        "    (api().inspector_opengl_render)(insp);\n"
        "    let _ = SwapBuffers(hdc);\n"
        "}\n"
        "fn disabled_paint(hwnd: HWND) {\n"
        "    if false {\n"
        "        (api().inspector_opengl_render)(insp);\n"
        "    }\n"
        "    let _ = SwapBuffers(hdc);\n"
        "}\n"
    )
    sync_fns = sync_paint_fns(sync_file)
    inline_body = "(api().inspector_opengl_render)(insp); let _ = SwapBuffers(hdc); let _ = ValidateRect(Some(hwnd), None);"
    call_body = "paint(hwnd); let _ = ValidateRect(Some(hwnd), None);"
    disabled_call_body = "disabled_paint(hwnd); let _ = ValidateRect(Some(hwnd), None);"
    sync_probe_ok = (
        "paint" in sync_fns
        and "disabled_paint" not in sync_fns  # its only render call is if-false'd
        and arm_asks_sync(inline_body, sync_fns)
        and arm_asks_sync(call_body, sync_fns)
        and not arm_asks_sync(disabled_call_body, sync_fns)
        and not arm_asks_sync("let _ = ValidateRect(Some(hwnd), None);", sync_fns)
    )
    print(
        "sync-paint probe self-test:",
        "OK (inline, one-call-away, and if-false-disabled are told apart)"
        if sync_probe_ok
        else "FAILED -- the sync-shape reader is broken, so nothing below means anything",
    )
    if not sync_probe_ok:
        return 2

    swallowed = []
    checked = 0
    for path in sorted(SRC.glob("*.rs")):
        text = path.read_text(encoding="utf-8")
        fns = sync_paint_fns(text)
        for off, body in arms(text):
            if not VALIDATES.search(body):
                continue  # this arm paints some other way; not this checker's subject
            checked += 1
            if not ASKS.search(body) and not arm_asks_sync(body, fns):
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

    print(
        "Nothing to report: every arm that validates has asked for pixels first, "
        "asynchronously (`surface_refresh`) or synchronously (renders and "
        "`SwapBuffers`, in the arm or one `fn` away)."
    )
    print(
        "NOT CHECKED: arms that paint without `ValidateRect` (`BeginPaint`/`EndPaint`\n"
        "             validate on their own); a synchronous render more than one\n"
        "             `fn` call away from the arm; and whether the pixels asked for,\n"
        "             by either shape, actually arrive."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
