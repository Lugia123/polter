#!/usr/bin/env python3
"""The pane count a split announces must be the tab the split acted on.

**Written from a line that was wrong every time it mattered and looked right
every time it was read.** `split_pane` ended with

    [split] NewSplit::Down -> pane 27 (cwd inherited); 3 panes in this tab

and the number came from `pane_count(frame)`, which counted the panes of the
*active* tab. A split does not have to happen in the active tab:
`acting_tab` picks the tab holding the pane the caller named, so
`terminal_action(id=A, "new_split:down")` against a pane in a background tab
lands somewhere the active tab knows nothing about. That is not a corner
case -- it is the exact shape `docs/windows/split-target-criteria.md` was
written to test, and the cell that tests it is the one where the two tabs
differ by construction.

⚠️ **A count with no subject cannot be seen to be wrong.** The number was
plausible, of the right order, and moved when panes moved. Nothing about it
said it was answering a different question from the one its own sentence
asked.

# What this checks, and why not the text

The tempting assertion is that the line mentions a tab. **That assertion was
true while the line was wrong**, and it is the same shape as the watchdog
alarm that printed a thread id -- the right *kind* of value, from the wrong
place. The lesson from that gate is the rule here: **check where the value
came from, not what the sentence says about it.**

So: `split_pane` reaches the tab it is modifying through one identifier --
the one it hands to `tabs.get_mut(...)`. The count must be taken with that
same identifier. Anything else is a number about a different tab, however it
is spelled.

That makes the decisive mutation catchable and the decisive non-mutation
quiet:

  * pass a different index that is a perfectly good `usize`
    (`active_index(frame)`, or a local bound from it) -- red;
  * rename the identifier everywhere and change nothing else -- green,
    because the name was never the evidence.

WHAT THIS CHECKS
----------------

  1. The counting function takes a tab index at all. A version that does not
     cannot be called wrongly, and cannot be called rightly either.
  2. Inside `split_pane`, every call to it passes exactly the identifier that
     the function gives to `tabs.get_mut`.
  3. The tab-less `pane_count(` is gone and stays gone -- a function that
     answers about the active tab, sitting next to callers that act on
     another one, is the trap this was.

**NOT CHECKED:**

  * **That `acting_tab` picks the right tab.** This checks that the count and
    the mutation agree about which tab; if both are wrong they agree.
  * **Other callers.** The rule is stated for `split_pane`, which is where
    the acting tab and the active tab can differ. `close_pane` and the tab
    commands take the tab they are given.
  * **That the line is ever printed.** It is not gated, but that is
    `a-gated-line-says-what-its-silence-means.py`'s subject, not this one.

Run:  python3 windows/tools/a-count-names-the-tab-it-counted.py
Exit: 0 when the announced count is about the tab that was split.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TABS = ROOT / "windows" / "host" / "src" / "tabs.rs"

FUNCTION = "fn split_pane("
COUNTER = "tab_pane_count"
BANNED = "pane_count("
REACHES_THE_TAB = re.compile(r"\btabs\s*\.\s*get_mut\s*\(\s*([A-Za-z_]\w*)\s*\)")


def mask(src: str) -> str:
    """Comments and string bodies blanked, line count preserved.

    Comments go because a checker that reads the prose explaining itself
    tests nothing -- this repository has watched that happen more than once.
    Strings go because the log line here names the tab in its own text, and a
    check that accepted that would pass on the defect it was written for.
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
    """The braced body of the item starting at `at`."""
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


def args_at(code: str, open_at: int) -> list:
    """Top-level comma split of the parenthesised list starting at `open_at`."""
    depth, cur, out = 0, "", []
    for i in range(open_at, len(code)):
        ch = code[i]
        if ch in "([{":
            depth += 1
            if depth == 1:
                continue
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                out.append(cur.strip())
                return out
        if ch == "," and depth == 1:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    return out


def check(src: str) -> list:
    code = mask(src)
    problems = []

    # 1. the counter takes a tab index
    sig = re.search(rf"fn\s+{COUNTER}\s*\(([^)]*)\)", code)
    if not sig:
        return [
            f"tabs.rs: `{COUNTER}` is gone. The count it took was the one that "
            f"had to name its tab; without it there is nothing here to check."
        ]
    params = [p.split(":")[0].strip() for p in sig.group(1).split(",") if p.strip()]
    if len(params) < 2:
        problems.append(
            f"tabs.rs: `{COUNTER}` takes {params} and so cannot be told which "
            f"tab to count. A count that cannot be asked about a tab cannot be "
            f"checked against the one that was modified."
        )

    # 3. the tab-less version is gone
    #
    # Reported once however many times it appears: the declaration and its
    # calls are one fault, and a checker that says the same sentence four
    # times trains people to read the first line and stop.
    back = len(re.findall(rf"(?<![A-Za-z_]){re.escape(BANNED)}", code))
    if back:
        problems.append(
            f"tabs.rs: `{BANNED}` is back ({back} occurrence(s)). It answers "
            f"about the active tab, and the callers near it act on a tab chosen "
            f"by `acting_tab`; the two differ in exactly the case anybody is "
            f"testing."
        )

    at = code.find(FUNCTION)
    if at < 0:
        return problems + ["tabs.rs: `split_pane` is gone."]
    body = body_of(code, at)

    # which identifier reaches the tab that is modified
    reached = REACHES_THE_TAB.findall(body)
    if not reached:
        return problems + [
            "tabs.rs: `split_pane` no longer reaches its tab through "
            "`tabs.get_mut(<ident>)`, so this cannot tell which tab it acted "
            "on. ⚠️ That is not a pass: it is the check losing its subject."
        ]
    acted = set(reached)

    # 2. every count in this function is taken with that identifier
    seen = 0
    for m in re.finditer(rf"(?<![A-Za-z_]){re.escape(COUNTER)}\s*\(", body):
        seen += 1
        args = args_at(body, body.index("(", m.start() + len(COUNTER) - 1))
        if len(args) < 2:
            problems.append(
                f"tabs.rs: `{COUNTER}` is called in `split_pane` with {args}; "
                f"it has to be told which tab."
            )
            continue
        given = args[1]
        if given not in acted:
            problems.append(
                f"tabs.rs: `split_pane` modifies the tab it reaches as "
                f"{sorted(acted)}, and counts the panes of `{given}`. ⚠️ These "
                f"have to be the same value, not the same kind of value: a "
                f"count taken from a different index is a plausible number "
                f"about a tab the sentence is not describing, and nothing "
                f"downstream can tell."
            )
    if seen == 0:
        problems.append(
            f"tabs.rs: `split_pane` announces a split without calling "
            f"`{COUNTER}`. If the count moved, this check moved with it and "
            f"nobody was told."
        )
    return problems


CANARIES = [
    ("correct", 0, """
fn tab_pane_count(frame: HWND, tab_idx: usize) -> Option<(TabId, usize)> { }
fn split_pane() -> bool {
    let idx = acting_tab(&win, at);
    match win.tabs.get_mut(tab_idx) { Some(tab) => { tab.panes.push(pane); } }
    match tab_pane_count(frame, tab_idx) { Some((tab, panes)) => wlogf!(f, "x") }
}
"""),
    # The right kind of value from the wrong place, spelled inline.
    ("an index from somewhere else, inline", 1, """
fn tab_pane_count(frame: HWND, tab_idx: usize) -> Option<(TabId, usize)> { }
fn split_pane() -> bool {
    match win.tabs.get_mut(tab_idx) { Some(tab) => { tab.panes.push(pane); } }
    match tab_pane_count(frame, active_index(frame)) { Some((t, p)) => wlogf!(f, "x") }
}
"""),
    # The same, laundered through a local: a plain identifier, right type,
    # wrong provenance. This is the shape a name-matching check misses.
    ("an index from somewhere else, via a local", 1, """
fn tab_pane_count(frame: HWND, tab_idx: usize) -> Option<(TabId, usize)> { }
fn split_pane() -> bool {
    match win.tabs.get_mut(tab_idx) { Some(tab) => { tab.panes.push(pane); } }
    let other = active_index(frame);
    match tab_pane_count(frame, other) { Some((t, p)) => wlogf!(f, "x") }
}
"""),
    # ⭐ The negative control. Every name changes, nothing else does; the check
    # must stay quiet, because the name was never the evidence.
    ("renamed throughout", 0, """
fn tab_pane_count(frame: HWND, which: usize) -> Option<(TabId, usize)> { }
fn split_pane() -> bool {
    let acted_on = acting_tab(&win, at);
    match win.tabs.get_mut(acted_on) { Some(tab) => { tab.panes.push(pane); } }
    match tab_pane_count(frame, acted_on) { Some((tab, panes)) => wlogf!(f, "x") }
}
"""),
    ("the tab-less counter is back", 2, """
fn tab_pane_count(frame: HWND, tab_idx: usize) -> Option<(TabId, usize)> { }
fn pane_count(frame: HWND) -> usize { }
fn split_pane() -> bool {
    match win.tabs.get_mut(tab_idx) { Some(tab) => { tab.panes.push(pane); } }
    logf!("[split] {} panes in this tab", pane_count(frame));
}
"""),
    # A mention inside a comment or a string is not a call.
    ("named only in prose", 0, """
fn tab_pane_count(frame: HWND, tab_idx: usize) -> Option<(TabId, usize)> { }
fn split_pane() -> bool {
    // this used to be pane_count(frame), which counted the active tab
    let msg = "pane_count(frame) was the old one";
    match win.tabs.get_mut(tab_idx) { Some(tab) => { tab.panes.push(pane); } }
    match tab_pane_count(frame, tab_idx) { Some((tab, panes)) => wlogf!(f, "x") }
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
    print("the split's pane count is taken from the tab the split acted on.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
