#!/usr/bin/env python3
"""Find Win32 calls that dispatch messages while a `RefCell` borrow is live.

This is a lint, not a proof. It exists because the rule it checks had been
rediscovered independently in `tabs.rs` and `tsf.rs` and then, in `palette.rs`,
was not known at all: `SetWindowTextW` inside `borrow_mut` sends `WM_SETTEXT`
synchronously to a subclassed window procedure whose first line borrows, and the
palette panicked the first time a user ever opened it.

`palette.rs` and `search.rs` no longer rely on the rule -- their window handles
live outside the `RefCell`, so a borrow hands out no window to call anything on.
The modules listed below still do rely on it, and this script is how that
reliance stays visible.

**A hit is not automatically a bug.** Whether one is depends on two facts that
are not at the call site: whether the target window is subclassed, and whether
that subclass borrows the same cell. Both were checked by hand on 2026-09-01;
the notes below record the answers, and a *new* hit means nobody has checked.

Run:  python3 windows/tools/borrow-across-dispatch.py
Exit: 0 if the hits match KNOWN exactly, 1 otherwise.
"""

import glob
import os
import re
import sys

# Win32 calls that deliver a message synchronously before returning. The read
# side matters as much as the write side: `GetWindowTextW` sends `WM_GETTEXT`.
DISPATCH = [
    "SetWindowTextW", "GetWindowTextW", "GetWindowTextLengthW", "SendMessageW",
    "SendDlgItemMessageW", "SetFocus", "SetWindowPos", "ShowWindow",
    "EnableWindow", "DestroyWindow", "CreateWindowExW", "SetParent",
    "MoveWindow", "UpdateWindow", "SetWindowLongPtrW", "TrackPopupMenu",
    "CallWindowProcW", "RedrawWindow", "SetCapture", "ReleaseCapture",
    "SetMenu", "SetWindowRgn",
]

# Sites checked by hand and found safe, with the reason. The reason is the
# point: it is what a new reader would otherwise have to re-derive.
KNOWN = {
    "divider.rs": "div_proc handles only WM_SETCURSOR/WM_LBUTTONDOWN/"
                  "WM_MOUSEMOVE; nothing sent during create or move reaches "
                  "it, so it all falls to DefWindowProc. Adding a WM_SIZE or "
                  "WM_WINDOWPOSCHANGED arm that borrows makes this a crash.",
}

# `settings_ui.rs` used to be in KNOWN. **Its reason was wrong, and the page
# aborted the first time a user opened it with any plugin installed.** The
# reason said:
#
#     "the targets are stock EDIT/COMBOBOX/BUTTON controls and this file
#      subclasses nothing, so the messages go to the system's procedures,
#      which never touch ST."
#
# Every clause of that is true. The conclusion does not follow, and the gap is
# worth naming because it is the gap a reader will fall into again:
#
#   **a message does not have to reach a subclass to reach us.** A custom-drawn
#   BUTTON sends `WM_NOTIFY`/`NM_CUSTOMDRAW` to its **parent**, and the parent
#   is our window procedure. `SetWindowTextW` on such a button therefore ran
#   `draw_button`, which borrowed `ST`, while `rebuild_fields` held
#   `borrow_mut`. `panic = abort`; the process went.
#
# So when writing a reason here, "who is subclassed" is only half the
# question. The other half is **what this window's own procedure handles** --
# `WM_NOTIFY`, `WM_DRAWITEM`, `WM_MEASUREITEM`, `WM_CTLCOLOR*`, `WM_COMMAND`
# are all messages a *stock* child sends to *us*.
#
# The entry is gone rather than corrected because the code no longer relies on
# the rule: `settings_ui.rs` sends every message with the cell released, and
# the one value the drawing path needs (`font`) was taken out of the cell
# altogether, so a borrow is not something the paint can meet.
#
# `divider.rs` below is reasoned the same way ("div_proc handles only ...").
# **That reason is about the child's own procedure and does not consider the
# parent path either** -- it happens to hold today only because
# `NM_CUSTOMDRAW` appears nowhere outside `settings_ui.rs` and no parent
# touches `divider.rs`'s cell. It has not been re-certified against the
# question above; the day a frame grows a `WM_NOTIFY` arm, it needs to be.


def strip_comments(src):
    """Blank out comments, keeping every newline so line numbers survive.

    **This file matches Win32 call names as raw text**, and a comment is raw
    text. Two ways that bites, and this repository has met the second one
    already in another gate:

      - a comment *inside* a borrow that names `SetWindowTextW` while
        explaining why the call was moved out reports a hit that is not there;
      - and the wrapper resolution below would read that same comment as a
        function body and register the enclosing function as a dispatcher.

    Both make the gate say something false about code that is right, which
    costs more than a miss: a reader who checks one and finds nothing stops
    believing the others.
    """
    out, i, n = [], 0, len(src)
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(ch if ch == "\n" else " " for ch in src[i:j]))
            i = j
        elif src[i] == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(src[i:j])
            i = j
        else:
            out.append(src[i])
            i += 1
    return "".join(out)


def local_dispatchers(src):
    """Functions in this file that dispatch, so a call to one counts as one.

    **The gate was blind to exactly this, and it is the call that crashed.**
    `settings_ui.rs` wraps `SetWindowTextW` in a three-line `set_text`, and
    `set_text(e, "Enabled")` inside a `borrow_mut` is what aborted the
    process. The block was reported only because an unrelated `SendMessageW`
    happened to sit beside it; with the wrapper alone, this file printed a
    clean report. Measured, not assumed -- see the self-test below.

    **Any local function that reaches a dispatching call counts**, not only
    short ones. A size cut-off would put new code outside the check by
    default, and "the new thing is exempt until someone notices" is how a
    whitelist comes to describe the past rather than the present.
    """
    names = set()
    for m in re.finditer(r"\bfn\s+(\w+)\s*(?:<[^>]*>)?\s*\(", src):
        name = m.group(1)
        brace = src.find("{", m.end())
        if brace < 0:
            continue
        depth, end = 0, len(src)
        for q in range(brace, len(src)):
            if src[q] == "{":
                depth += 1
            elif src[q] == "}":
                depth -= 1
                if depth == 0:
                    end = q
                    break
        body = src[brace:end]
        if any(re.search(r"\b" + d + r"\b", body) for d in DISPATCH):
            names.add(name)
    return sorted(names)


def scan_mutex_guard(src, path, dispatch=None):
    """The same rule for `tabs::state()`, whose guard is a `MutexGuard`.

    **A third shape, and neither tool saw it.** `lock-reentry.py` asks whether
    the guard outlives a call that takes the lock *again*, matched by function
    name -- and `SetWindowPos` is not such a function, it is a call that
    delivers `WM_SIZE` to a window procedure on this thread which then takes
    it. The check above asks the same question of `RefCell`, but keys on the
    literal word `borrow`, which a `MutexGuard` does not contain, so it never
    looked. Between the two, a `state()` guard held across a dispatching call
    was checked by nobody.

    That is not a hypothetical: it is one of the two deadlocks this host
    already had (`layout()` holding `STATE` across `SetWindowPos`). It is
    safe there today only because someone hand-arranged that function as
    "pure work under the lock, Windows calls after it" -- a structure with
    nothing testing that it stays that way. Reinstating that exact shape and
    running both tools produced two clean reports.
    """
    lines = src.split("\n")
    for i, line in enumerate(lines):
        m = re.search(r"let (?:mut )?(\w+)\s*=\s*(?:tabs::)?state\(\);", line)
        if not m:
            continue
        guard = m.group(1)
        pos = sum(len(x) + 1 for x in lines[:i])

        # Out to the enclosing block, then forward to its close: the guard is
        # alive over that span. Same walk as `lock-reentry.py` does.
        depth, k = 0, pos
        while k > 0:
            if src[k] == "}":
                depth -= 1
            elif src[k] == "{":
                depth += 1
                if depth == 1:
                    break
            k -= 1
        depth, end = 0, len(src)
        for q in range(k, len(src)):
            if src[q] == "{":
                depth += 1
            elif src[q] == "}":
                depth -= 1
                if depth == 0:
                    end = q
                    break
        scope = src[pos:end]

        # `drop(guard)` ends it early; this is how `surface_of` reaches into
        # another module safely, and how `layout` is meant to be read.
        dm = re.search(r"drop\(\s*%s\s*\)" % re.escape(guard), scope)
        if dm:
            scope = scope[: dm.start()]

        hits = sorted({d for d in (dispatch or DISPATCH) if re.search(r"\b" + d + r"\b", scope)})
        if hits:
            yield (path, i + 1, hits)


def scan(src, path):
    src = strip_comments(src)
    # The file's own wrappers, added to the names looked for. Computed per
    # file on purpose: a wrapper is a fact about one module, and a global
    # list would need editing every time somebody writes another one.
    dispatch = sorted(set(DISPATCH) | set(local_dispatchers(src)))
    yield from scan_mutex_guard(src, path, dispatch)
    lines = src.split("\n")
    for i, line in enumerate(lines):
        if not re.search(r"\b\w+\.with\(\|", line):
            continue
        depth, body = 0, []
        for j in range(i, min(i + 120, len(lines))):
            body.append(lines[j])
            depth += lines[j].count("(") - lines[j].count(")")
            if j > i and depth <= 0:
                break
        text = "\n".join(body)
        if "borrow" not in text:
            continue
        tail = text[text.find("borrow"):]
        hits = sorted({d for d in dispatch if re.search(r"\b" + d + r"\b", tail)})
        if hits:
            yield (path, i + 1, hits)


# Negative control. A probe that cannot see the bug it was written for reports
# a clean tree for the wrong reason, so prove it can before trusting a zero.
CANARY = '''
fn f() {
    STATE.with(|c| {
        if let Some(st) = c.borrow_mut().as_mut() {
            let _ = SetWindowTextW(st.edit, w!(""));
        }
    });
}
'''
if not list(scan(CANARY, "<canary>")):
    print("FAIL: the probe cannot see the panic it was written for.")
    sys.exit(1)

# The mutex half, in both directions. The bad one is the shape `layout()`
# already had once; the good one is the shape it has now, and without it
# "the drop is honoured" would be an assumption about our own code rather
# than something this file checks.
CANARY_MUTEX_BAD = '''
fn layout() {
    let mut st = state();
    st.dirty = true;
    unsafe { SetWindowPos(hw, None, 0, 0, 1, 1, SWP_NOZORDER); }
}
'''
CANARY_MUTEX_OK = '''
fn layout() {
    let place = {
        let st = state();
        st.places.clone()
    };
    unsafe { SetWindowPos(hw, None, 0, 0, 1, 1, SWP_NOZORDER); }
}
'''
if not list(scan_mutex_guard(CANARY_MUTEX_BAD, "<canary>")):
    print("FAIL: the probe cannot see a STATE guard held across a dispatching call.")
    sys.exit(1)
if list(scan_mutex_guard(CANARY_MUTEX_OK, "<canary>")):
    print("FAIL: the probe fires on work that takes its copy and drops the guard first.")
    sys.exit(1)

# The wrapper the gate used to be blind to. **This is the shape that crashed**:
# `settings_ui.rs` called `set_text` -- three lines around `SetWindowTextW` --
# inside a `borrow_mut`, and with the literal name nowhere in the block this
# file printed a clean report. The block was flagged only because an unrelated
# `SendMessageW` sat beside it, so the report was right by accident.
CANARY_WRAPPER = '''
fn set_text(h: HWND, s: &str) {
    let _ = unsafe { SetWindowTextW(h, PCWSTR(w.as_ptr())) };
}

fn rebuild() {
    ST.with(|c| {
        let mut st = c.borrow_mut();
        set_text(st.save_btn, "Save");
    });
}
'''
if not list(scan(CANARY_WRAPPER, "<canary>")):
    print("FAIL: the probe cannot see a dispatching call made through this file's "
          "own wrapper -- which is the call that crashed the settings page.")
    sys.exit(1)

# And the other direction. A comment is raw text to a regex, so a note *about*
# a dispatching call -- the kind written next to one that was deliberately
# moved out -- must not read as the call itself. A gate that fires on its own
# explanation teaches people to ignore it.
CANARY_COMMENT = '''
fn rebuild() {
    ST.with(|c| {
        let mut st = c.borrow_mut();
        // SetWindowTextW used to be here; it is below, with nothing borrowed.
        st.save_btn = b;
    });
}
'''
if list(scan(CANARY_COMMENT, "<canary>")):
    print("FAIL: the probe fires on a comment that merely names a dispatching call.")
    sys.exit(1)

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host", "src")
found, unexpected = {}, []
for path in sorted(glob.glob(os.path.join(root, "*.rs"))):
    name = os.path.basename(path)
    with open(path, encoding="utf-8") as fh:
        for _, ln, hits in scan(fh.read(), name):
            found.setdefault(name, []).append((ln, hits))

print("probe self-test: OK (RefCell borrow, STATE guard, local wrappers, "
      "and comments ignored)")
print(f"scanned {len(glob.glob(os.path.join(root, '*.rs')))} files\n")
for name, sites in sorted(found.items()):
    note = KNOWN.get(name)
    for ln, hits in sites:
        print(f"  {name}:{ln}  {', '.join(hits)}")
    if note:
        print(f"    checked, safe: {note}\n")
    else:
        unexpected.append(name)
        print("    *** NOT IN THE CHECKED LIST -- someone must check it ***\n")

if unexpected:
    print(f"FAIL: {len(set(unexpected))} unchecked file(s): {sorted(set(unexpected))}")
    sys.exit(1)
missing = sorted(set(KNOWN) - set(found))
if missing:
    print(f"note: {missing} no longer hit; drop them from KNOWN.")
print("OK: every hit is one that was checked by hand.")
