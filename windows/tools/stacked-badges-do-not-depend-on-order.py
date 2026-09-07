#!/usr/bin/env python3
"""Two badges over one corner, and a position that remembers when it was set.

Measured on the machine, as a single-variable pair -- the same two states, set
in the two possible orders:

    order A (secure first, then read-only):  both badges at 196,126,
                                             and the read-only line has no
                                             `stacked` clause at all
    order B (read-only already on, then secure): secure at 196,162,
                                             `stacked under read-only: 1`

**The yielding works. It is computed once, at the moment the PASSWORD badge
turns on, and never again.** Turn read-only on afterwards and the badge that
is already up does not move, so the two draw on top of each other -- and two
badges at one point are one badge as far as the person can tell. They read
whichever won the z-order and act on the other.

# The rule this asks for, in one sentence

> **Badges that share the pane's top-left corner are stacked downward in one
> fixed order, and each one's slot is its position among those *currently
> lit*, recomputed from the live state whenever any of them changes.**

It has to be one sentence, and it has to be about the *set that is lit* rather
than about *what happened*, because the next badge added to that corner would
otherwise reintroduce this defect in a form nobody recognises. Today the
corner has two occupants -- measured: `ro_proc` and `sec_proc` both anchor at
`fr.left + sc(16), fr.top + sc(16)`, while `link_proc` sits at the pane's
bottom-left, `scroll_proc` at its right edge, and `size_proc` is not
pane-anchored. Two is not the number the rule is written for; the rule is
written so the number can change.

# What this checks

  1. **No badge computes its own offset inline.** A conditional written at one
     badge's site is a decision made in one badge's timeline, which is exactly
     what produced order-dependence.
  2. **Every writer of a stacking state syncs every badge in that stack**, not
     only its own. `on_readonly_for` posting only to `HWND_RO` is the whole of
     the defect: the other badge is never told the world changed under it.

**NOT CHECKED, and the split matters more than the checks:**

  * **that the badges do not overlap on screen.** This machine has no windows.
    What is checkable here is that *the position is a pure function of the live
    state*, and that both writers wake both badges; whether the result looks
    right is a real-machine reading. The criterion for that is at the bottom of
    this file, in the form somebody can run.
  * badges that share some *other* anchor. Only the top-left stack is modelled.
  * a pane too narrow for the left badges and the right-edge scrollbar to miss
    each other. Different question, no answer here.

# The criterion this cannot run

On the machine, one pane, **both orders, and the second one is the one that
was broken**:

  1. Turn secure input on (a password prompt, or the palette row). Note the
     badge's `x,y` from `[hud] secure input on ... badge at X,Y`.
  2. **Now** turn read-only on. The `[hud]` line for the secure badge must
     appear **again**, with a different Y and `stacked under read-only: 1`.
     No second line at all is this defect, unfixed.
  3. Turn read-only off again. The secure badge must move **back** up, and say
     so. (The reverse of the same bug: a badge left stacked under a badge that
     is no longer there sits in mid-air with a gap above it.)
  4. Both badges legible at once, neither on top of the other -- the only cell
     a person can answer.

Run:  python3 windows/tools/stacked-badges-do-not-depend-on-order.py
Exit: 0 when the stack is a function of the live state, not of the order.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HUD = os.path.normpath(os.path.join(HERE, "..", "host", "src", "hud.rs"))

# The badges that share the pane's top-left corner, and the state each is
# driven by. Two entries today; the point of the rule is that a third is one
# line here and no change anywhere else.
STACK = {"ro_proc": "READONLY", "sec_proc": "SECURE"}
WRITERS = {"on_readonly_for": "HWND_RO", "on_secure_input": "HWND_SEC"}
WINDOWS = ["HWND_RO", "HWND_SEC"]


def strip_comments(text: str) -> str:
    """Comments out. This file's own prose spells every symbol below, and the
    hud spends more lines explaining a badge than drawing it."""
    return re.sub(r"//[^\n]*", "", text)


def body_of(src: str, header: str):
    at = src.find(header)
    if at < 0:
        return None
    brace = src.find("{", at)
    depth, k = 0, brace
    while k < len(src):
        if src[k] == "{":
            depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0:
                return src[brace : k + 1]
        k += 1
    return None


def analyse(src: str):
    code = strip_comments(src)
    bad = []
    looked = 0

    for fn in STACK:
        body = body_of(code, f'fn {fn}(')
        if body is None:
            bad.append(f"`{fn}` is gone; this gate has lost half its subject "
                       "and would otherwise report a clean stack.")
            continue
        looked += 1
        # 1. the offset must not be decided at the badge's own site
        if re.search(r"if\s+stacked|if\s+is_readonly_for|if\s+is_secure_for", body):
            bad.append(
                f"`{fn}` decides its own offset inline. That decision is made "
                "in one badge's timeline, so it is right only if that badge "
                "was the last to change -- which is the order-dependence "
                "measured on the machine: turn the other state on afterwards "
                "and this badge never moves. Ask a shared function for the "
                "slot instead.")

    for writer, own in WRITERS.items():
        body = body_of(code, f"fn {writer}(")
        if body is None:
            bad.append(f"`{writer}` is gone; nothing is known about who wakes "
                       "the badges when its state changes.")
            continue
        looked += 1
        # **Follow what it delegates to.** The repair moves the posting into
        # one `sync_corner`, so the writer's own body names neither window --
        # and a check that reads only the writer reports the fix as the
        # defect. Measured: it did, the first time this ran against the
        # repaired file. Same lesson as `hidden-overlay-hands-back-the-
        # foreground.py`, which had to learn it about `overlay.rs`.
        reach = body
        for call in set(re.findall(r"\b([a-z_][a-z0-9_]*)\s*\(", body)):
            helper = body_of(code, f"fn {call}(")
            if helper is not None and helper != body:
                reach += "\n" + helper
        missing = [w for w in WINDOWS if w not in reach]
        if missing:
            bad.append(
                f"`{writer}` wakes {own} and not {', '.join(missing)}. A badge "
                "that is already up is never told the world changed under it, "
                "so it keeps the position it was given when it appeared. "
                "Every writer of a stacking state has to wake the whole "
                "stack.")
    return bad, looked


# -- self-test ---------------------------------------------------------------

BROKEN = '''
unsafe extern "system" fn ro_proc(hwnd: HWND) -> LRESULT {
    let y = fr.top + sc(16);
}
unsafe extern "system" fn sec_proc(hwnd: HWND) -> LRESULT {
    let stacked = is_readonly_for(surface);
    let y = fr.top + sc(16) + if stacked { sc(HEIGHT + 6) } else { 0 };
}
pub fn on_readonly_for(surface: usize, on: bool) {
    let h = HWND_RO.load(Ordering::Acquire);
    PostMessageW(Some(HWND(h)), WM_HUD_SYNC, WPARAM(surface), LPARAM(0));
}
pub fn on_secure_input(surface: usize, mode: i32) -> bool {
    let h = HWND_SEC.load(Ordering::Acquire);
    PostMessageW(Some(HWND(h)), WM_HUD_SYNC, WPARAM(surface), LPARAM(0));
}
'''

FIXED = '''
unsafe extern "system" fn ro_proc(hwnd: HWND) -> LRESULT {
    let y = fr.top + sc(16) + sc(corner_slot(surface, Corner::ReadOnly) * (HEIGHT + 6));
}
unsafe extern "system" fn sec_proc(hwnd: HWND) -> LRESULT {
    let y = fr.top + sc(16) + sc(corner_slot(surface, Corner::Secure) * (HEIGHT + 6));
}
fn sync_corner(surface: usize) {
    for slot in [&HWND_RO, &HWND_SEC] { post(slot, surface); }
}
pub fn on_readonly_for(surface: usize, on: bool) {
    sync_corner(surface);
}
pub fn on_secure_input(surface: usize, mode: i32) -> bool {
    sync_corner(surface);
}
'''

HALF_A_STACK = FIXED.replace(
    "for slot in [&HWND_RO, &HWND_SEC] { post(slot, surface); }",
    "post(&HWND_SEC, surface);")

COMMENT_ONLY = FIXED.replace(
    "pub fn on_readonly_for(surface: usize, on: bool) {",
    "pub fn on_readonly_for(surface: usize, on: bool) {\n    // if stacked, HWND_SEC")

for sample, want_red, label in (
    (BROKEN, True, "the shape that shipped: an inline `if stacked`, and each "
                   "writer waking only its own badge"),
    (FIXED, False, "a shared slot function and a shared sync -- the writers "
                   "name neither window, so this only passes if the check "
                   "follows what they delegate to"),
    (HALF_A_STACK, True,
     "a shared sync that wakes only half the stack -- moving the bug into a "
     "helper is the tidiest way to keep it"),
    (COMMENT_ONLY, False,
     "a *comment* mentioning the other badge -- this gate strips comments, "
     "because this repository has had three checkers read one as code"),
):
    got = bool(analyse(sample)[0])
    if got != want_red:
        print(f"FAIL: the probe {'misses' if want_red else 'fires on'} {label}.")
        sys.exit(1)
if analyse(FIXED)[1] != len(STACK) + len(WRITERS):
    print("FAIL: the probe did not look at every badge and every writer, so "
          "its silence does not cover them.")
    sys.exit(1)

# -- the tree ----------------------------------------------------------------

src = open(HUD, encoding="utf-8").read() if os.path.isfile(HUD) else ""
problems, looked = analyse(src)
print(f"read hud.rs ({len(src)} bytes); looked at {looked} badge(s) and writer(s)")

if not src or looked == 0:
    print()
    print("FAIL: hud.rs was not read, or none of the badges were found. There "
          "was nothing to check. Not a pass.")
    sys.exit(1)

if not problems:
    print("OK: the corner stack is a function of the live state, and every "
          "writer wakes the whole stack.")
    print("NOT CHECKED: that they do not overlap on screen. See the criterion "
          "in this file's header -- it needs a pane and a person.")
    sys.exit(0)

print()
for line in problems:
    print("  " + line)
print()
print(f"FAIL: {len(problems)} way(s) for the stack to depend on the order.")
sys.exit(1)
