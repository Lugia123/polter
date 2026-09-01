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


def scan(src, path):
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

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host", "src")
found, unexpected = {}, []
for path in sorted(glob.glob(os.path.join(root, "*.rs"))):
    name = os.path.basename(path)
    with open(path, encoding="utf-8") as fh:
        for _, ln, hits in scan(fh.read(), name):
            found.setdefault(name, []).append((ln, hits))

print("probe self-test: OK (it sees the known panic shape)")
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
