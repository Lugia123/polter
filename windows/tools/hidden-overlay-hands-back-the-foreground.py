#!/usr/bin/env python3
"""An overlay that hides itself must not still be the foreground window.

**The incident.** Run a command from the command palette. The palette hides
itself, as designed. Every keystroke after that goes nowhere, and **nothing on
the screen has changed** -- there is no window to see, so there is nothing to
point at and nothing to close. Only a real mouse click on the terminal gets
the keyboard back. What was read off the machine:

    GetForegroundWindow() = 0x50022A
    GetClassNameW         = PolterCommandPalette
    IsWindowVisible       = False
    GetWindowRect         = 440,150..1000,500      (on-screen, normal size)

So it is not drawn off-screen and not zero-sized. It is hidden, and it is
still the foreground window.

# Two different things, and the code only ever did one of them

`hide()` calls `ShowWindow(SW_HIDE)` and then `overlay::focus_back`, which
calls `SetFocus`. **`SetFocus` moves the focus within the calling thread; it
does not change the foreground window.** Those are separate pieces of Windows
state and nothing in this host was setting the second one. That much is a fact
about the source, and it matches the reading exactly.

**What is deliberately NOT claimed here**: that the missing owner window is
*why* Windows did not reassign activation by itself. A top-level `WS_POPUP`
created with `hWndParent = None` has no owner to fall back to, and that is
documented behaviour -- but it is not something that can be measured on the
machine this port is written on, so it stays an explanation rather than a
finding. The remedy does not depend on it: hand the foreground back **and read
it back**, and the answer is a reading whatever Windows would have done.

# The rule, and why it is a family and not a site

Every file that creates a **top-level** window and hides it again has to
answer this. There are four acceptable answers and the first two mean the
question never arises:

  * `WS_EX_NOACTIVATE` -- it never takes activation, so it cannot keep it.
  * an owner (`GWLP_HWNDPARENT`) -- Windows hands activation to the owner.
  * it hands the foreground back itself and reads it back.
  * a written reason: `// hides without handing the foreground back: <why>`.

A **child** window (`WS_CHILD`) is out of scope by construction: a child
cannot be the foreground window. That exclusion is computed from the create
call, not from a list, which is the difference between "this one is fine" and
"nobody looked at this one".

**This is default-include on purpose.** The palette is what was reported, and
the palette is not the only one -- the find bar is created with the same three
flags, takes focus into an edit the same way, and hides itself the same way.
Fixing the reported one and shipping would have left an identical hole one
file over, in the overlay people open more often.

# The question has to be asked about the process, not about this window

**The first version of this gate passed a host that did not work**, and the
way it passed is the part worth keeping. `foreground_back` began:

    let fg = GetForegroundWindow();
    if fg != me { ...  "left alone"; return; }

which reads as a courtesy -- do not yank the keyboard out of another
application's window -- and the motivation is right. **The question is wrong.**
At the instant an overlay hides, which of this process's windows holds the
foreground is exactly the thing in flux: on the machine, that read came back
as the *frame*, so the guard concluded "not mine, leave it" and returned, and
three seconds later the foreground was the hidden overlay. The log showed one
line, `left alone`, which reads entirely normal.

**No structural check can see "it returned early".** What it can see is *what
the decision was made about*. So: the decision to hand the foreground back
must not turn on whether the foreground is **this one window**. Whether to
yield is a question about the process -- is anything of ours in front -- and
that answer does not change while Windows is reassigning activation between
two of our own windows.

**NOT CHECKED:**

  * anything at runtime. This reads source. **And a green here has already
    once meant nothing**, which is why the machine criterion below is not
    optional and why its last cell does not involve an API at all.
  * whether the window handed back to is the *right* one. Handing the
    foreground to "window 1" when two are open is the defect
    `5351b0147` had just finished removing from these same overlays, and no
    text check can tell the two apart.
  * overlays that `DestroyWindow` instead of hiding.

# The criterion this cannot run, in the form somebody can

Per overlay -- the palette, the find bar, **and the quick terminal**, which
has the same shape:

  0. **Check the premise first, and record it.** WT's earlier find-bar run was
     a false negative: `Ctrl+Shift+F` produced no `[overlay] search took
     focus` line at all, so the bar had never opened and the run measured
     nothing. Open it, and write down `opened fg=<hwnd> class=[...]
     visible=True` **before** sampling. A negative whose premise did not hold
     is not a reading.
  1. Then make it close itself the way a person does (run a command, press
     Escape, press the hotkey again).
  2. **`left alone` is a failure.** The broken version printed that sentence
     and meant "I asked too early"; a working one prints it only when somebody
     else's window really has the foreground. So the line must carry its own
     evidence -- `pid <n> class "<name>"` -- and the pid must not be this
     process. **Measured twice on the machine, both red, both through this
     one branch**: the palette left the foreground on a hidden
     `PolterCommandPalette` for 3.9s and the find bar on a hidden
     `PolterSearch` for 2.6s. It is one door's timing, not two overlays'
     oversights.
  3. **Read back:** `GetForegroundWindow()` must equal the frame's handle. Not
     "not the overlay" -- *equal to the frame*. The log line
     `[overlay] <who> hid ... GetForegroundWindow now <hwnd>: ...` carries the
     comparison; its tail must read `the window that had it`.
  4. **Then type, without touching the mouse.** The characters must appear in
     the terminal. This is the cell that matters most and the only one that
     depends on no API's instantaneous semantics: it is the thing the person
     actually hit, and the previous round passed every other check while
     failing this one.
  5. Negative control, so cell 4 can be trusted: before the fix, the same keys
     produce **nothing**, and one mouse click on the terminal makes typing work
     again. Use two different strings so the two are told apart on screen.

Run:  python3 windows/tools/hidden-overlay-hands-back-the-foreground.py
Exit: 0 when every self-hiding top-level overlay answers the question.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "host", "src"))

REASON = re.compile(r"//\s*hides without handing the foreground back:\s*(\S.*)")


def strip_comments(text: str) -> str:
    return re.sub(r"//[^\n]*", "", text)


def create_args(code: str):
    """The balanced argument list of every `CreateWindowExW` call.

    Balanced rather than a regex to the first `)`, because these calls run to
    a dozen lines and contain `Some(...)`, `WINDOW_STYLE(...)` and casts. A
    truncated read would classify a `WS_CHILD` window as top-level, and this
    gate would then demand a foreground handback from a child window -- noise,
    which is how a gate gets switched off.
    """
    for m in re.finditer(r"CreateWindowExW\s*\(", code):
        i = code.index("(", m.start())
        depth, k = 0, i
        while k < len(code):
            if code[k] == "(":
                depth += 1
            elif code[k] == ")":
                depth -= 1
                if depth == 0:
                    yield code[i + 1 : k]
                    break
            k += 1


# How far after `SW_HIDE` the handback may sit and still be part of hiding.
REACH = 22


def hands_back_at_the_hide(code: str) -> bool:
    """Is the foreground given back **where the window is hidden**?

    **Anywhere-in-the-file is the wrong question, and it was asked first.**
    The first version of this gate accepted any mention of
    `SetForegroundWindow` in the file, and excused `quick.rs` on the strength
    of one -- which turned out to be in its *show* path, where the panel
    **takes** the foreground. It never gave it back at all. A rule that reads
    a file-wide mention cannot tell taking from returning, and the file it
    excused had the very defect being looked for.
    """
    lines = code.split("\n")
    for i, line in enumerate(lines):
        if "SW_HIDE" not in line:
            continue
        window = "\n".join(lines[i : i + REACH])
        if "foreground_back" in window or "SetForegroundWindow" in window:
            return True
    return False


# `if fg != me {` and its spellings: a foreground read compared against the
# window being hidden, deciding an early return.
# The comparison has to **decide control flow**, not label a log line.
#
# The first version of this pattern stopped at the comparison, and it then
# fired on the fix: the repaired `foreground_back` compares `fg == me` to
# record *which* of our windows had the foreground, purely so the log can say
# so. **A checker that cannot tell a guard from a label reports the repair as
# the defect** -- and it was assembled out of the right symbols, so it read
# exactly like a finding. Requiring the `return` is what separates the two.
OWN_IDENTITY = re.compile(
    r"if\s+\w+\s*(?:!=|==)\s*(?:me|self|hwnd|us)\b[\s\S]{0,240}?\breturn\b"
)


def decides_on_its_own_identity(code: str) -> bool:
    """Is the handback gated on *this window* being the foreground?

    The shape that shipped and did not work. It is not a typo and it is not
    laziness -- it reads as the right courtesy -- so it is worth a check of
    its own rather than a note somebody is expected to remember.
    """
    return OWN_IDENTITY.search(code) is not None


LEFT_ALONE = re.compile(r'"[^"]*left alone[^"]*"')


def leaving_alone_shows_whose(code: str) -> bool:
    """When it declines to act, does the line say *whose* window has it?

    **`left alone` is the sentence the broken version printed**, and there it
    meant "I asked before Windows had finished moving the foreground". A
    reader cannot tell that from "another application really has it" unless
    the line names the owner. So a decline must be evidenced: the process id,
    and the class of the window that has it.

    No `left alone` at all is fine -- an implementation that always hands back
    has nothing to evidence.
    """
    hits = LEFT_ALONE.findall(code)
    if not hits:
        return True
    return all("pid" in h and "class" in h for h in hits)


def classify(name: str, src: str, shared: str = ""):
    """`(verdict, why)`. `verdict` is "red", `"identity"`, or a reason string.

    `shared` is the text of the helper this file delegates to. **Following
    that edge is not a refinement, it is the difference between this gate
    working and not**: the handback lives in `overlay.rs` for the three
    overlays that share it, so a check that only reads the hiding file sees
    `foreground_back(...)`, calls it answered, and never looks at how. That is
    exactly what the first version did, and it passed a host whose shared
    helper returned early every time.
    """
    code = strip_comments(src)
    if "SW_HIDE" not in code:
        return None, "does not hide a window"
    creates = list(create_args(code))
    if not creates:
        return None, "creates no windows of its own"
    tops = [a for a in creates if "WS_CHILD" not in a]
    if not tops:
        return None, "creates only child windows, which are never the foreground window"
    if "WS_EX_NOACTIVATE" in code:
        return None, "WS_EX_NOACTIVATE: never takes activation"
    if "GWLP_HWNDPARENT" in code:
        return None, "has an owner, so Windows hands activation back"
    if hands_back_at_the_hide(code):
        joined = code + "\n" + shared
        if decides_on_its_own_identity(joined):
            return "identity", None
        if not leaving_alone_shows_whose(joined):
            return "unevidenced", None
        return None, "hands the foreground back where it hides"
    if REASON.search(src):
        return None, "a written reason: " + REASON.search(src).group(1)
    return "red", None


def analyse(files: dict):
    bad, excused = [], []
    # The shared helper, read once and handed to every file that delegates to
    # it. Named rather than discovered, because "the file that holds the
    # handback" is a fact about this host and not a pattern.
    shared = strip_comments(files.get("overlay.rs", ""))
    for name, src in sorted(files.items()):
        verdict, why = classify(name, src, shared if name != "overlay.rs" else "")
        if verdict == "unevidenced":
            bad.append(
                f"{name}: the foreground is sometimes left alone, and the line "
                "that says so does not say whose window has it. `left alone` "
                "is what the broken version printed when it had asked too "
                "early -- the same words, a different fact. Put the pid and "
                "the class of the foreground window in the line, so a reader "
                "decides instead of believing.")
        elif verdict == "identity":
            bad.append(
                f"{name}: the foreground is handed back only when "
                "`GetForegroundWindow()` is already this very window. At the "
                "instant an overlay hides, which of this process's windows "
                "holds the foreground is the thing in flux -- on the machine "
                "that read came back as the frame, so this branch said `left "
                "alone` and returned, and the keyboard went into the hidden "
                "window. Ask about the process (is anything of ours in "
                "front), not about this window.")
        elif verdict == "red":
            bad.append(
                f"{name}: creates a top-level window and hides it, and does "
                "nothing about the foreground. `SetFocus` moves focus inside "
                "this thread; it does not move the foreground window. A hidden "
                "window that is still foreground swallows every keystroke with "
                "nothing on screen to say where they went.")
        elif why and "does not hide" not in why:
            excused.append(f"{name}: {why}")
    return bad, excused


# -- self-test ---------------------------------------------------------------

BROKEN = {"palette.rs": '''
fn init() { let h = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST, w!("X"), w!("P"), WS_POPUP, 0,0,1,1, None, None, Some(hinst), None); }
fn hide() { let _ = ShowWindow(me, SW_HIDE); crate::overlay::focus_back(PREV_FOCUS.get(), "palette"); }
'''}
CHILD = {"divider.rs": '''
fn init() { let h = CreateWindowExW(WINDOW_EX_STYLE::default(), w!("D"), None, WS_CHILD | WS_CLIPSIBLINGS, 0,0,0,0, Some(frame), None, Some(hinst), None); }
fn hide() { let _ = ShowWindow(d.hwnd, SW_HIDE); }
'''}
NOACTIVATE = {"hud.rs": '''
fn init() { let h = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOPMOST, w!("H"), None, WS_POPUP, 0,0,1,1, None, None, Some(hinst), None); }
fn hide() { let _ = ShowWindow(me, SW_HIDE); }
'''}
OWNED = {"settings_ui.rs": '''
fn init() { let h = CreateWindowExW(WINDOW_EX_STYLE::default(), w!("S"), w!("S"), WS_POPUP, 0,0,1,1, None, None, Some(hinst), None);
            SetWindowLongPtrW(h, GWLP_HWNDPARENT, frame.0 as isize); }
fn hide() { let _ = ShowWindow(me, SW_HIDE); }
'''}
TAKES_BUT_NEVER_RETURNS = {"quick.rs": '''
fn init() { let h = CreateWindowExW(WS_EX_TOOLWINDOW, w!("Q"), w!("Q"), WS_POPUP, 0,0,1,1, None, None, Some(hinst), None); }
fn show() { let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE); let _ = SetForegroundWindow(hwnd); }
fn hide() { let _ = ShowWindow(hwnd, SW_HIDE); plogf!("[quick] hidden"); }
'''}

UNEVIDENCED_DECLINE = {
    "palette.rs": '''
fn init() { let h = CreateWindowExW(WS_EX_TOOLWINDOW, w!("X"), w!("P"), WS_POPUP, 0,0,1,1, None, None, Some(hinst), None); }
fn hide() { let _ = ShowWindow(me, SW_HIDE); crate::overlay::foreground_back(me, prev, "palette"); }
''',
    "overlay.rs": '''
pub fn foreground_back(me: HWND, prev: HWND, who: &str) {
    let fg = GetForegroundWindow();
    if pid != GetCurrentProcessId() { hlogf!(frame(), "the foreground is not ours -- left alone"); return; }
    let _ = SetForegroundWindow(GetAncestor(prev, GA_ROOT));
}
''',
}

LABELS_BUT_DOES_NOT_GATE = {
    "palette.rs": '''
fn init() { let h = CreateWindowExW(WS_EX_TOOLWINDOW, w!("X"), w!("P"), WS_POPUP, 0,0,1,1, None, None, Some(hinst), None); }
fn hide() { let _ = ShowWindow(me, SW_HIDE); crate::overlay::foreground_back(me, prev, "palette"); }
''',
    "overlay.rs": '''
pub fn foreground_back(me: HWND, prev: HWND, who: &str) {
    let fg = GetForegroundWindow();
    if pid != GetCurrentProcessId() { hlogf!(frame(), "another process"); return; }
    let was = if fg == me { "this overlay" } else { "another of ours" };
    let _ = SetForegroundWindow(GetAncestor(prev, GA_ROOT));
    hlogf!(frame(), "was {}", was);
}
''',
}

DELEGATES_TO_A_BROKEN_HELPER = {
    "palette.rs": '''
fn init() { let h = CreateWindowExW(WS_EX_TOOLWINDOW, w!("X"), w!("P"), WS_POPUP, 0,0,1,1, None, None, Some(hinst), None); }
fn hide() { let _ = ShowWindow(me, SW_HIDE); crate::overlay::foreground_back(me, prev, "palette"); }
''',
    "overlay.rs": '''
pub fn foreground_back(me: HWND, prev: HWND, who: &str) {
    let fg = GetForegroundWindow();
    if fg != me { hlogf!(frame(), "left alone"); return; }
    let _ = SetForegroundWindow(GetAncestor(prev, GA_ROOT));
}
''',
}

ASKS_ABOUT_ITSELF = {"palette.rs": '''
fn init() { let h = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST, w!("X"), w!("P"), WS_POPUP, 0,0,1,1, None, None, Some(hinst), None); }
fn hide() {
    let _ = ShowWindow(me, SW_HIDE);
    let fg = GetForegroundWindow();
    if fg != me { hlogf!(frame(), "left alone"); return; }
    let _ = SetForegroundWindow(want);
}
'''}

FIXED = {"palette.rs": '''
fn init() { let h = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST, w!("X"), w!("P"), WS_POPUP, 0,0,1,1, None, None, Some(hinst), None); }
fn hide() { let _ = ShowWindow(me, SW_HIDE); crate::overlay::foreground_back(me, PREV_FOCUS.get(), "palette"); }
'''}
EXCUSED = {"odd.rs": '''
fn init() { let h = CreateWindowExW(WS_EX_TOOLWINDOW, w!("X"), w!("P"), WS_POPUP, 0,0,1,1, None, None, Some(hinst), None); }
// hides without handing the foreground back: it is never shown while anything else is running
fn hide() { let _ = ShowWindow(me, SW_HIDE); }
'''}

for sample, want_red, label in (
    (BROKEN, True, "a self-hiding popup that does nothing about the foreground"),
    (TAKES_BUT_NEVER_RETURNS, True,
     "a popup whose only `SetForegroundWindow` is in its *show* path -- it "
     "takes the foreground and never returns it, and a file-wide search for "
     "the name excuses it. This one was measured, not imagined: it is what "
     "the first version of this gate did to `quick.rs`"),
    (ASKS_ABOUT_ITSELF, True,
     "a handback gated on `fg != me` -- the shape that shipped, passed this "
     "gate's first version, and did not work"),
    (DELEGATES_TO_A_BROKEN_HELPER, True,
     "a file that delegates to a shared helper which decides on its own "
     "identity. **This is the one that matters**: it is the real code's "
     "shape, and the version of this gate that did not follow the edge "
     "reported it clean"),
    (LABELS_BUT_DOES_NOT_GATE, False,
     "a helper that compares against its own handle only to *label* a log "
     "line, having already decided on the process. This is the repair, and "
     "the first version of the pattern reported it as the defect"),
    (UNEVIDENCED_DECLINE, True,
     "a decline that prints `left alone` without saying whose window has the "
     "foreground -- the same sentence the broken version printed, and no way "
     "to tell the two apart from a log"),
    (CHILD, False, "a WS_CHILD window, which can never be the foreground window"),
    (NOACTIVATE, False, "a WS_EX_NOACTIVATE popup, which never takes activation"),
    (OWNED, False, "a popup with an owner, which Windows hands activation back for"),
    (FIXED, False, "a popup that hands the foreground back itself"),
    (EXCUSED, False, "a popup with the reason written next to it"),
):
    got = bool(analyse(sample)[0])
    if got != want_red:
        print(f"FAIL: the probe {'misses' if want_red else 'fires on'} {label}.")
        sys.exit(1)

# -- the tree ----------------------------------------------------------------

files = {}
if os.path.isdir(SRC):
    for name in sorted(os.listdir(SRC)):
        if name.endswith(".rs"):
            with open(os.path.join(SRC, name), encoding="utf-8") as fh:
                files[name] = fh.read()

problems, excused = analyse(files)
print(f"read {len(files)} file(s)")
# **What it did not have to ask about, by name.** A checker that cannot say
# how much it excluded is indistinguishable from one that examined nothing.
for line in excused:
    print(f"  not asked -- {line}")

if not files or not excused:
    print()
    print("FAIL: no self-hiding window was classified at all, so there was "
          "nothing to check. Not a pass.")
    sys.exit(1)

if not problems:
    print("OK: every self-hiding top-level overlay answers for the foreground.")
    print("NOT CHECKED: any of it at runtime, and not whether the window handed "
          "back to is the right one when two are open.")
    sys.exit(0)

print()
for line in problems:
    print("  " + line)
print()
print(f"FAIL: {len(problems)} overlay(s) that can hide and keep the keyboard.")
sys.exit(1)
