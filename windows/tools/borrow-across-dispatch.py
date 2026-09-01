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
    "settings_ui.rs": "the targets are stock EDIT/COMBOBOX/BUTTON controls and "
                      "this file subclasses nothing, so the messages go to the "
                      "system's procedures, which never touch ST.",
}


def scan_mutex_guard(src, path):
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

        hits = sorted({d for d in DISPATCH if re.search(r"\b" + d + r"\b", scope)})
        if hits:
            yield (path, i + 1, hits)


def scan(src, path):
    yield from scan_mutex_guard(src, path)
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
        hits = sorted({d for d in DISPATCH if re.search(r"\b" + d + r"\b", tail)})
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

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host", "src")
found, unexpected = {}, []
for path in sorted(glob.glob(os.path.join(root, "*.rs"))):
    name = os.path.basename(path)
    with open(path, encoding="utf-8") as fh:
        for _, ln, hits in scan(fh.read(), name):
            found.setdefault(name, []).append((ln, hits))

print("probe self-test: OK (RefCell borrow and STATE guard, both directions)")
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
