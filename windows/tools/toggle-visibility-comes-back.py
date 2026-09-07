#!/usr/bin/env python3
"""Hiding every window is only half of `toggle_visibility`.

The dangerous half is the second one. An implementation that hides all the
windows and cannot bring them back leaves a running process with no window,
no taskbar button worth pressing, and no way in from the keyboard -- and it
looks, from the chair, exactly like the application quit. The first press is
the one that gets tested; the second is the one that matters.

# What this can check here, and what it cannot

**It cannot check the round trip.** That is a window-manager fact and this
machine has no window manager to ask. What it *can* check are the two ways
the round trip is lost in the source, both of which have precedent in this
port:

  1. **The set that comes back must be the set that went away.** Showing
     `winid::all()` again is the tempting shortcut and it is wrong in a way
     nobody sees until it happens: a window the person had already minimised
     comes back up, and a window made while everything was away gets
     "restored" having never been hidden. macOS keeps a `hiddenState` for
     precisely this and its comment says so. So: something must be *stored*
     when hiding and *read* when showing.

  2. **The window that had the keyboard must be the one that gets it back**,
     and it must be remembered rather than derived. Deriving it means
     `overlay_frame()` -- "window 1" -- which is the answer `5351b0147` spent
     a commit removing from every overlay in this host, because with two
     windows open it is right half the time and looks right all of it.

# The criterion this cannot run, written out so somebody can

On the machine, with **two** windows open and the second one in front:

  1. Press the binding. Every terminal window goes away. The log says
     `[win] toggle_visibility: hid N window(s); GetForegroundWindow now ...`
     and the tail of that line must **not** say `STILL ONE OF OURS` -- if it
     does, the keyboard is going into a hidden window and this is task 300
     again at whole-application scale.
  2. Press it again. **All N come back**, and the log's
     `brought back N window(s) ... GetForegroundWindow now ...` ends with
     `the window that had it`.
  3. **The window that is in front is window 2, the one that was in front
     before.** Not window 1. This is the cell that a source check cannot see
     and the one that catches the mistake this host has already made in four
     other places.
  4. Negative control: minimise window 1 by hand first, then do 1 and 2.
     Window 1 must still be minimised afterwards -- it was not ours to hide,
     so it is not ours to restore.

Run:  python3 windows/tools/toggle-visibility-comes-back.py
Exit: 0 when the source keeps what it hid and remembers who had the keyboard.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "host", "src"))


def strip_comments(text: str) -> str:
    return re.sub(r"//[^\n]*", "", text)


def analyse(files: dict):
    bad = []
    # **The files that *define* it, not the ones that mention it.** Joining
    # every file naming `toggle_visibility` pulls in `main.rs`, whose arm is
    # one line and whose other four thousand contain `overlay_frame` for
    # unrelated reasons -- and the first run of this gate duly reported the
    # implementation for reaching at window 1, which it does not do. **A false
    # positive assembled out of real symbols reads exactly like a finding**,
    # which is why the subject set is the definition site.
    hits = [
        n for n, s in files.items()
        if re.search(r"\bfn\s+toggle_visibility\s*\(", strip_comments(s))
    ]
    if not hits:
        bad.append(
            "no file defines `toggle_visibility`. The core hands the host "
            "`GHOSTTY_ACTION_TOGGLE_VISIBILITY` and `cb_action` falls through "
            "to `_ => false`: the binding does nothing and says nothing.")
        return bad, hits

    impl = "\n".join(strip_comments(files[n]) for n in hits)

    if "SW_HIDE" not in impl:
        bad.append("nothing in the implementation hides a window, so whatever "
                   "`toggle_visibility` does, it is not this.")
    # 1. a stored set, written and read
    stored = re.search(r"\bHIDDEN\b", impl)
    if not stored or impl.count("HIDDEN") < 2:
        bad.append(
            "the windows that were hidden are not recorded and read back. "
            "Showing `winid::all()` again brings up windows this host never "
            "hid -- one the person had minimised, one made while everything "
            "was away -- and undoing somebody else's decision is not what a "
            "toggle is.")
    # 2. the foreground is remembered, not derived
    if "was_foreground" not in impl:
        bad.append(
            "the window that had the keyboard is not remembered, so bringing "
            "them back has to guess which one to put in front.")
    if "overlay_frame" in impl:
        bad.append(
            "the implementation reaches for `overlay_frame()`, which is "
            "\"window 1\". That is the answer this host spent a commit "
            "removing from every overlay: with two windows open it is right "
            "half the time and looks right all of it.")
    return bad, hits


# -- self-test ---------------------------------------------------------------

MISSING = {"winnav.rs": "pub fn close_all() -> bool { true }\n"}
NO_MEMORY = {"winnav.rs": '''
pub fn toggle_visibility() -> bool {
    for f in winid::all() { unsafe { let _ = ShowWindow(f, SW_HIDE); } }
    true
}
'''}
WINDOW_ONE = {"winnav.rs": '''
static HIDDEN: Mutex<Option<Hidden>> = Mutex::new(None);
struct Hidden { frames: Vec<isize>, was_foreground: isize }
pub fn toggle_visibility() -> bool {
    let _ = HIDDEN.lock();
    unsafe { let _ = ShowWindow(f, SW_HIDE); }
    let _ = SetForegroundWindow(crate::tabs::overlay_frame());
    true
}
'''}
GOOD = {"winnav.rs": '''
static HIDDEN: Mutex<Option<Hidden>> = Mutex::new(None);
struct Hidden { frames: Vec<isize>, was_foreground: isize }
pub fn toggle_visibility() -> bool {
    let mut slot = HIDDEN.lock();
    unsafe { let _ = ShowWindow(f, SW_HIDE); }
    let want = HWND(state.was_foreground as *mut c_void);
    let _ = unsafe { SetForegroundWindow(want) };
    true
}
'''}

for sample, want, label in (
    (MISSING, "no file defines", "an action nobody implements"),
    (NO_MEMORY, "not recorded and read back", "hiding without recording what was hidden"),
    (WINDOW_ONE, "window 1", "putting window 1 in front instead of the one that had it"),
):
    if not any(want in line for line in analyse(sample)[0]):
        print(f"FAIL: the probe cannot see {label}.")
        sys.exit(1)
if analyse(GOOD)[0]:
    print("FAIL: the probe rejects an implementation that records what it hid "
          "and remembers who had the keyboard.")
    for line in analyse(GOOD)[0]:
        print("  " + line)
    sys.exit(1)

# -- the tree ----------------------------------------------------------------

files = {}
if os.path.isdir(SRC):
    for name in sorted(os.listdir(SRC)):
        if name.endswith(".rs"):
            with open(os.path.join(SRC, name), encoding="utf-8") as fh:
                files[name] = fh.read()

problems, hits = analyse(files)
print(f"read {len(files)} file(s); `toggle_visibility` named in: "
      + (", ".join(hits) if hits else "(none)"))

if not files:
    print()
    print("FAIL: no source was read. Not a pass.")
    sys.exit(1)

if not problems:
    print("OK: what was hidden is recorded, and the window that had the "
          "keyboard is remembered.")
    print("NOT CHECKED: the round trip itself. See the criterion in this "
          "file's header -- it needs two windows and a machine.")
    sys.exit(0)

print()
for line in problems:
    print("  " + line)
print()
print(f"FAIL: {len(problems)} problem(s) in the way this comes back.")
sys.exit(1)
