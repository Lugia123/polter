#!/usr/bin/env python3
"""A mouse button that goes down once must come up once.

**The defect, measured on the real machine:** four Ctrl+clicks on a link
produced eight `open_url` dispatches -- the browser was called twice for every
click, strictly, never once and never three times.

The cause is a Win32 fact with no warning attached: **`ReleaseCapture` sends
`WM_CAPTURECHANGED` to the window that had the capture**, exactly as a stolen
capture does. The two are indistinguishable at the window procedure, so the
ordinary click path ran

    WM_LBUTTONUP -> release -> ReleaseCapture() -> WM_CAPTURECHANGED -> release

and the core, which opens a link once per release
(`if (button == .left and action == .release)` in `Surface.zig`), opened it
twice. **Nothing on either side could see it**: both releases are well formed,
both arrive at the surface they belong to, and the log shows two of everything
without anything saying the second was not asked for.

# What this checks

Every send of `MOUSE_RELEASE` -- and of `MOUSE_PRESS` -- must go through the
one pair of helpers that keeps the count. A window procedure that calls the
raw forwarder is a second place the pairing can be got wrong, and the shape of
getting it wrong is a duplicate that reads exactly like a repeat the user
asked for.

# What this does not check

  * **That the pairing itself is right.** `release_left` returning false when
    the button was never down is a fact about its body, not about its callers.
  * **Anything on the machine.** That four clicks now produce four dispatches
    is WT's reading and cannot be taken here: this file reads text.

Run:  python3 windows/tools/one-release-per-press.py
Exit: 0 when the raw forwarder is reached only through the counted pair.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "host", "src"))

# The helpers that are allowed to send one, and nothing else.
GATEKEEPERS = ("fn press_left(", "fn release_left(")
SEND = re.compile(r"\bmouse_button\s*\(([^;]*?)\)\s*;", re.S)
KINDS = re.compile(r"MOUSE_(PRESS|RELEASE)\b")


def strip_comments(text: str) -> str:
    """`//` comments blanked, newlines kept.

    ⚠️ This file reads text, and the comments it is checking *describe* the
    calls -- the note on `LEFT_DOWN_PANE` spells out `mouse_button(pane,
    MOUSE_PRESS, ...)` in prose. Without this pass that prose is a call site,
    and the gate reports a defect that is a sentence. The same trap has been
    hit four times in this directory now.
    """
    return re.sub(r"//[^\n]*", "", text)


def enclosing_fn(src: str, at: int) -> str:
    """The `fn NAME(` that most recently opened before `at`."""
    best = ""
    for m in re.finditer(r"\bfn\s+(\w+)\s*\(", src[:at]):
        best = m.group(1)
    return best


def scan(src: str):
    """`(problems, sends)` -- every send, and the ones outside the pair."""
    clean = strip_comments(src)
    problems, sends = [], []
    for m in SEND.finditer(clean):
        kind = KINDS.search(m.group(1))
        if not kind:
            continue
        line = clean[: m.start()].count("\n") + 1
        owner = enclosing_fn(clean, m.start())
        sends.append((owner, kind.group(1), line))
        if f"fn {owner}(" in GATEKEEPERS:
            continue
        problems.append(
            f"`{owner}` (tabs.rs:{line}) sends MOUSE_{kind.group(1)} straight to the "
            f"forwarder. Every press and release has to go through `press_left` / "
            f"`release_left`, which are what keep one press to one release -- a "
            f"second path is a second place the pairing can be wrong, and a "
            f"duplicate release is indistinguishable from a click the user made."
        )
    return problems, sends


# -- self-test ---------------------------------------------------------------

CANARY_BAD = '''
fn release_left(pane: HWND) -> bool {
    mouse_button(pane, crate::ffi::MOUSE_RELEASE, crate::ffi::MOUSE_LEFT);
    true
}
fn surface_wndproc() {
    WM_CAPTURECHANGED => {
        mouse_button(hwnd, crate::ffi::MOUSE_RELEASE, crate::ffi::MOUSE_LEFT);
    }
}
'''
CANARY_OK = CANARY_BAD.replace(
    "        mouse_button(hwnd, crate::ffi::MOUSE_RELEASE, crate::ffi::MOUSE_LEFT);\n",
    "        release_left(hwnd);\n",
)
CANARY_PROSE = CANARY_OK.replace(
    "fn surface_wndproc() {",
    "// was: mouse_button(hwnd, crate::ffi::MOUSE_RELEASE, crate::ffi::MOUSE_LEFT);\n"
    "fn surface_wndproc() {",
)


def self_test() -> None:
    if not scan(CANARY_BAD)[0]:
        print("FAIL: a window procedure sending a raw release was not reported.")
        sys.exit(2)
    if scan(CANARY_OK)[0]:
        print("FAIL: a release sent through the pair was reported anyway.")
        sys.exit(2)
    if scan(CANARY_PROSE)[0]:
        print("FAIL: a call written in a comment was read as a call. Prose is not "
              "code, and this checker reads text.")
        sys.exit(2)
    print("probe self-test: OK (raw send reported, guarded send accepted, prose ignored)")


def main() -> int:
    self_test()
    src = open(os.path.join(SRC, "tabs.rs"), encoding="utf-8").read()
    problems, sends = scan(src)
    if not sends:
        print("FAIL: no `mouse_button` send was found in tabs.rs at all. A parser "
              "that cannot find its subject must say so, not pass.")
        return 1

    print(f"{len(sends)} send(s) of a mouse button in tabs.rs:")
    for owner, kind, line in sends:
        print(f"  {kind:7} from `{owner}` (tabs.rs:{line})")
    print("NOT CHECKED: whether the pairing itself is right, and anything at all "
          "about what happens on the machine.")

    if problems:
        print()
        for p in problems:
            print(f"FAIL: {p}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
