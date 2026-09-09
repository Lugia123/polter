#!/usr/bin/env python3
"""A click may not point the window at a tab before checking the tab is there.

`focus_pane_at` wrote `win.active = tab_idx` and *then* looked the tab up,
with an `if let` that had no `else`. When the lookup missed, the window was
already pointing at an index that names no tab -- and `layout` reads exactly
that field: `if i != win.active` is true for every tab, so every tab is
hidden, nothing is placed, and **the window goes blank**. The only line left
was `focus_active`'s "nothing to focus: the active tab has no focused pane",
which is true and is about something else. Somebody chasing a blank window is
told the tab has no focus, not that the tab is gone and that this click is
what aimed at it.

⚠️ **Adding an `else` would not have been the fix.** The write had already
happened by then; a line in the `else` annotates a blank window. Doing the
lookup first makes "`active` names a tab that is not there" a state this
function cannot produce.

# Why this checks an order and not a shape

The tempting rule is "that `if let` must have an `else`". It is the wrong
rule twice over. It passes the broken version the moment somebody adds a line
there, and it fails the correct version written any of the other ways --
`match`, `let ... else`, an early return -- none of which has an `else` at
all. **A checker whose default is "unfamiliar spelling means wrong" gets
turned off by the first person who writes correct code.**

So the rule is about the sequence, and it is deliberately narrow: **in
`focus_pane_at`, the assignment to `active` must come after the lookup that
confirms the index.** One function, one ordering, stated where a reader of
that function will meet it.

**Names are not the evidence.** The check pairs the assignment and the lookup
by the identifier they share, whatever it is called; renaming it everywhere
leaves this quiet, which is the point -- a checker that pins a name is
measuring the name.

**NOT CHECKED:**

  * **Anywhere else.** Other writers of `active` (`set_active`, the tab
    commands) are handed an index they clamp themselves. Extending this to
    "every write to `active`" would take in code with a different, correct
    discipline and is a separate argument.
  * **That the miss is reachable.** Today it is not: it needs `tabs` to
    change between `pane_of` and `window(frame)`, and nothing off the UI
    thread writes `tabs`. That is a property of the rest of the file and can
    stop being true without this function changing.
  * **That the failure says anything.** The line in the miss path is
    `a-swallowed-action-says-so.py`'s subject; this file only cares that the
    field is not written first.

Run:  python3 windows/tools/the-active-tab-is-confirmed-before-it-is-set.py
Exit: 0 when the index is confirmed before it is committed.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TABS = ROOT / "windows" / "host" / "src" / "tabs.rs"
FUNCTION = "fn focus_pane_at("

# `<anything>.active = <ident>;` -- the commit.
COMMIT = re.compile(r"\.\s*active\s*=\s*([A-Za-z_]\w*)\s*;")
# `tabs.get_mut(<ident>)` / `tabs.get(<ident>)` -- the confirmation.
CONFIRM = re.compile(r"\btabs\s*\.\s*get(?:_mut)?\s*\(\s*([A-Za-z_]\w*)\s*\)")


def mask(src: str) -> str:
    """Comments and string bodies blanked, line count preserved.

    ⚠️ **Not optional here, and the reason is a few lines away.** The comment
    above the code this checks spells out the broken ordering verbatim, so a
    checker reading raw text would find `active = tab_idx` in the prose
    explaining why that ordering is wrong -- before the real one, and would
    report the fixed code as broken. Reading its own explanation has already
    cost this repository a green gate and a red one.
    """
    out = []
    i, n, in_str = 0, len(src), False
    while i < n:
        c = src[i]
        if not in_str:
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
            elif c == '"':
                out.append('"')
                i += 1
                in_str = True
            else:
                out.append(c)
                i += 1
        else:
            if c == "\\":
                nxt = src[i + 1] if i + 1 < n else ""
                out.append(" " + ("\n" if nxt == "\n" else " "))
                i += 2
            elif c == '"':
                out.append('"')
                i += 1
                in_str = False
            elif c == "\n":
                out.append("\n")
                i += 1
            else:
                out.append(" ")
                i += 1
    return "".join(out)


def body_of(code: str, at: int) -> str:
    start = code.find("{", at)
    if start < 0:
        return ""
    depth = 0
    for i in range(start, len(code)):
        if code[i] == "{":
            depth += 1
        elif code[i] == "}":
            depth -= 1
            if depth == 0:
                return code[start : i + 1]
    return code[start:]


def check(src: str) -> list:
    code = mask(src)
    at = code.find(FUNCTION)
    if at < 0:
        return [
            "tabs.rs: `focus_pane_at` is gone. This checker was watching one "
            "function and no longer has it; that is not a pass."
        ]
    body = body_of(code, at)

    commits = list(COMMIT.finditer(body))
    if not commits:
        return [
            "tabs.rs: `focus_pane_at` no longer assigns to `active`. If the "
            "commit moved somewhere else this entry protects nothing -- say so "
            "here rather than leaving it quiet."
        ]

    problems = []
    for m in commits:
        ident = m.group(1)
        confirmed_at = [
            c.start() for c in CONFIRM.finditer(body) if c.group(1) == ident
        ]
        if not confirmed_at:
            problems.append(
                f"tabs.rs: `focus_pane_at` sets `active = {ident}` and never "
                f"looks `{ident}` up in `tabs`. The window would then point at "
                f"an index nothing has confirmed exists, and `layout` hides "
                f"every tab whose position differs from it."
            )
            continue
        if min(confirmed_at) > m.start():
            problems.append(
                f"tabs.rs: `focus_pane_at` sets `active = {ident}` before it "
                f"confirms `{ident}` names a tab. ⚠️ Order, not spelling: once "
                f"that field is written the window is already pointing at a tab "
                f"that may not be there, and every later line -- including one "
                f"in an `else` -- describes a window that has already gone "
                f"blank."
            )
    return problems


CANARIES = [
    ("confirmed first", 0, """
pub fn focus_pane_at(hwnd: HWND) {
    let was = (win.active, win.tabs.get(win.active).map(|t| t.focused));
    let Some(tab) = win.tabs.get_mut(tab_idx) else { break 'commit None; };
    tab.focused = id;
    win.active = tab_idx;
}
"""),
    # The original defect.
    ("committed first, with an if let and no else", 1, """
pub fn focus_pane_at(hwnd: HWND) {
    let was = (win.active, win.tabs.get(win.active).map(|t| t.focused));
    win.active = tab_idx;
    if let Some(tab) = win.tabs.get_mut(tab_idx) { tab.focused = id; }
}
"""),
    # ⚠️ The rule this file exists to *not* be: an `else` does not repair it.
    ("committed first, with an else that speaks", 1, """
pub fn focus_pane_at(hwnd: HWND) {
    win.active = tab_idx;
    if let Some(tab) = win.tabs.get_mut(tab_idx) {
        tab.focused = id;
    } else {
        wlogf!(frame, "[pane] that tab is gone");
    }
}
"""),
    # ⭐ The negative control: every name changes, nothing else does.
    ("renamed throughout", 0, """
pub fn focus_pane_at(hwnd: HWND) {
    let Some(tab) = win.tabs.get_mut(wanted) else { break 'commit None; };
    tab.focused = id;
    win.active = wanted;
}
"""),
    # Written with `match` instead, and correctly. No `else` anywhere.
    ("match, confirmed first", 0, """
pub fn focus_pane_at(hwnd: HWND) {
    match win.tabs.get_mut(tab_idx) {
        Some(tab) => { tab.focused = id; }
        None => return,
    }
    win.active = tab_idx;
}
"""),
    ("committed without ever confirming", 1, """
pub fn focus_pane_at(hwnd: HWND) {
    win.active = tab_idx;
    focus_active(frame);
}
"""),
    # The prose above the real code spells the broken order out verbatim.
    ("the broken order quoted in a comment", 0, """
pub fn focus_pane_at(hwnd: HWND) {
    // This used to write `win.active = tab_idx` first and only then look the
    // tab up with `win.tabs.get_mut(tab_idx)`, which is the wrong order.
    let Some(tab) = win.tabs.get_mut(tab_idx) else { break 'commit None; };
    tab.focused = id;
    win.active = tab_idx;
}
"""),
]


def selftest() -> list:
    bad = []
    for name, want, src in CANARIES:
        got = check(src)
        if len(got) != want:
            bad.append(f"self-test {name!r}: expected {want}, got {len(got)}: {got}")
    return bad


def main() -> int:
    bad = selftest()
    if bad:
        print("This checker is broken; it was not run against the tree.")
        for b in bad:
            print("  " + b)
        return 1
    problems = check(TABS.read_text(encoding="utf8"))
    if problems:
        for p in problems:
            print("  " + p)
        print(f"{len(problems)} problem(s).")
        return 1
    print("the active tab index is confirmed before it is committed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
