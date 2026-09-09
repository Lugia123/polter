#!/usr/bin/env python3
"""A user action that is refused must say so, on the line it is refused.

**The incident, and why it cost a day rather than a minute.** `split_pane`
gave up in four places with a bare `return`. `run_ops` prints `[ops] running
NewSplit` before every op, unconditionally -- so a swallowed split left a log
that said, in order: the host received the action, and then nothing. That is
not "no information". It is **the exact shape of a host that did its part and
a core that would not draw**, which is what task 440 is about, and it was read
as evidence for 440 for an afternoon before anybody read the function.

Six functions in the census were in that state. The worst was not the noisiest
one: `focus_pane_at` swallows a *click*, does not go through the op queue at
all, and so left no line even saying a click had happened -- while the screen
still looked right and the keystrokes went to a terminal the user was not
looking at.

# What this gate asserts

For each function in `SUBJECTS`: **every `return` that leaves the function
early has a log call between it and the `{` that opens its block.**

That is a deliberately mechanical rule, and it is the one that reddens for the
failure this exists to stop: delete the `wlogf!` above any of those returns and
this fails, which is the "prove the criterion can catch it" requirement --
removing a log line is the change a future edit would actually make.

# What it does NOT check, and the second one is the real hole

  * **that the line says something true.** It reads for a log call, not for
    its wording. A line that names the wrong action passes here.
  * ⚠️ **every other function in the host.** `SUBJECTS` is a list, and a list
    is a whitelist: a new user-action function with silent exits is outside
    this gate by default, which is the wrong default and is named here rather
    than hidden. The census that produced this list covered one syntactic
    shape (`let Some/Ok(..) = .. else`) and did **not** systematically cover
    bare `if cond { return; }` or `?` propagation -- so the list is "the ones
    we found", never "the ones there are".
  * the final expression of a function that returns a value. Only `return`
    statements are read, so a function whose last line is `false` is not
    asked to explain itself.
"""

import re
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "host" / "src"

# The census of task 441/452. Each entry is a user action that a person
# performs and that used to be able to vanish without a word.
SUBJECTS = [
    ("tabs.rs", "split_pane"),        # 448: new split
    ("tabs.rs", "close_pane"),        # close one pane
    ("tabs.rs", "focus_pane_at"),     # 450: click to change pane
    ("tabs.rs", "destroy_tab_at"),    # close a tab
    ("divider.rs", "drag_to"),        # drag a divider
    ("strip.rs", "show_overflow_menu"),  # the tab overflow button
]

LOG = re.compile(r"\b[wpah]?logf!|\blog_line\b|\bsay\(")

# **The escape hatch, and why it is a comment with a reason in it rather than
# a second list.** Some early exits should stay quiet: dismissing a menu is
# the user saying "never mind", and a line per dismissal is noise that pushes
# the interesting lines out of the log. A second whitelist in this file would
# put that judgement where nobody editing the function will see it. A marker
# on the line puts it in front of the next person to touch it, and the reason
# is mandatory -- a bare marker does not satisfy the pattern.
#
# ⚠️ These are counted and printed every run. An exemption nobody re-reads is
# how a gate quietly stops covering the thing it was written for.
#
# ⚠️ `[^\S\n]` rather than `\s`: `\s` matches a newline, so `\s*\S` after the
# colon would find the first non-space character *on the next line* -- which
# is the `return` itself. A marker with no reason would then have exempted
# the very thing it fails to explain. The self-test below is what caught it.
SILENT_OK = re.compile(r"//[^\S\n]*silent-ok:[^\S\n]*\S")
FN = "fn {}("

# ---- the second layer.
#
# **A log at the exit is half the fix, and on its own it is the half that
# reads worse.** `run_ops` already prints `[ops] running NewSplit` before
# every op; an action that fails quietly therefore produces "it started" and
# nothing else, which is a stronger wrong impression than no lines at all.
# So the functions that *have* a caller able to say what happened must have
# one: the call site owns an outcome line.
#
# Each entry is (file, callee, how many lines after the call to look in).
OUTCOME = [
    ("tabs.rs", "split_pane", 6),
    ("tabs.rs", "close_pane", 6),
]


def body_of(text: str, name: str):
    """The function's body, as a list of (line_number, line)."""
    i = text.find(FN.format(name))
    if i < 0:
        return None
    j = text.find("{", i)
    if j < 0:
        return None
    depth = 0
    k = j
    while k < len(text):
        if text[k] == "{":
            depth += 1
        elif text[k] == "}":
            depth -= 1
            if depth == 0:
                break
        k += 1
    first_line = text[:j].count("\n")
    return list(enumerate(text[j : k + 1].split("\n"), start=first_line + 1))


def silent_returns(lines):
    """Early `return`s with no log call between them and their block's `{`.

    Depth is counted in braces. When a `return` is seen at depth d, the search
    goes back to the line that took the depth to d, and asks whether anything
    in between logs. That is what makes an announcement three lines above a
    return count, and one in a *sibling* block not count.
    """
    out = []
    exempt = []
    depth = 0
    opened_at = {}
    for idx, (lineno, line) in enumerate(lines):
        code = line.split("//")[0]
        if re.search(r"\breturn\b", code) and depth > 0:
            start = opened_at.get(depth, 0)
            # The marker may sit on the return or anywhere in its block.
            block = "\n".join(l for _, l in lines[start : idx + 1])
            if SILENT_OK.search(block):
                exempt.append((lineno, line.strip()[:70]))
                continue
            window = "\n".join(l.split("//")[0] for _, l in lines[start:idx])
            if not LOG.search(window):
                out.append((lineno, line.strip()[:70]))
        for ch in code:
            if ch == "{":
                depth += 1
                opened_at[depth] = idx
            elif ch == "}":
                depth -= 1
    return out, exempt


def main() -> int:
    # ---- self-test: the reader must tell the two shapes apart.
    good = [
        (1, "fn f() {"),
        (2, "    let Some(x) = y() else {"),
        (3, '        wlogf!(frame, "[t] refused: gone");'),
        (4, "        return false;"),
        (5, "    };"),
        (6, "}"),
    ]
    bad = [
        (1, "fn f() {"),
        (2, "    let Some(x) = y() else {"),
        (3, "        return false;"),
        (4, "    };"),
        (5, "}"),
    ]
    # ⚠️ The decoy is the shape that would make this gate useless if the
    # window search were wrong: a log in a *sibling* block, which a reader
    # that scanned the whole function would accept.
    decoy = [
        (1, "fn f() {"),
        (2, "    if a {"),
        (3, '        wlogf!(frame, "[t] something else entirely");'),
        (4, "    }"),
        (5, "    let Some(x) = y() else {"),
        (6, "        return false;"),
        (7, "    };"),
        (8, "}"),
    ]
    marked = [
        (1, "fn f() {"),
        (2, "    if a {"),
        (3, "        // silent-ok: the user dismissed it"),
        (4, "        return;"),
        (5, "    }"),
        (6, "}"),
    ]
    bare = [
        (1, "fn f() {"),
        (2, "    if a {"),
        (3, "        // silent-ok:"),
        (4, "        return;"),
        (5, "    }"),
        (6, "}"),
    ]
    ok = (
        not silent_returns(good)[0]
        and len(silent_returns(bad)[0]) == 1
        and len(silent_returns(decoy)[0]) == 1
        and not silent_returns(marked)[0]
        and len(silent_returns(marked)[1]) == 1
        # A marker with no reason is not a marker.
        and len(silent_returns(bare)[0]) == 1
    )
    print(
        "probe self-test:",
        "OK (announced / silent / sibling-block log / marked / marker with no reason)"
        if ok
        else "FAILED -- the reader is broken, so nothing below means anything",
    )
    if not ok:
        return 2

    findings = []
    exempted = []
    checked = 0
    returns_seen = 0
    for fname, func in SUBJECTS:
        path = SRC / fname
        if not path.exists():
            print(f"FAIL: {fname} is not there any more; SUBJECTS is stale.")
            return 1
        lines = body_of(path.read_text(encoding="utf-8"), func)
        if lines is None:
            print(
                f"FAIL: `fn {func}(` was not found in {fname}.\n"
                f"      It was renamed or removed, and this gate has been\n"
                f"      checking nothing about it since. Update SUBJECTS."
            )
            return 1
        checked += 1
        returns_seen += sum(
            1 for _, l in lines if re.search(r"\breturn\b", l.split("//")[0])
        )
        found, ex = silent_returns(lines)
        for lineno, snippet in found:
            findings.append((fname, func, lineno, snippet))
        for lineno, snippet in ex:
            exempted.append((fname, func, lineno, snippet))

    # **Nothing to look at is not a pass**: see gates-fail-on-empty.py.
    if checked == 0 or returns_seen == 0:
        print(
            f"FAIL: {checked} function(s) read, {returns_seen} `return`(s) among them.\n"
            "      A subject set with nothing in it cannot report that everything\n"
            "      in it is fine."
        )
        return 1

    print(f"{checked} user-action function(s) read; {returns_seen} `return`(s) in them.")
    if exempted:
        print(f"{len(exempted)} deliberately silent, each with a written reason:")
        for fname, func, lineno, snippet in exempted:
            print(f"      {fname}:{lineno}  in `{func}`:  {snippet}")
    if findings:
        print("FAIL: a user action is refused without a word:")
        for fname, func, lineno, snippet in findings:
            print(f"      {fname}:{lineno}  in `{func}`:  {snippet}")
        print(
            "      Add a log call in the same block, above the `return`, naming the\n"
            "      action and why it did not happen -- see `create_tab_with`. A user\n"
            "      whose click did nothing has no other way to find out why, and a\n"
            "      silent refusal here reads downstream as a rendering fault."
        )
        return 1

    # ---- second layer: the call site turns the value into a line.
    missing = []
    calls = 0
    for fname, callee, span in OUTCOME:
        text = (SRC / fname).read_text(encoding="utf-8").split("\n")
        for i, line in enumerate(text):
            # The definition is not a call site.
            if f"{callee}(" not in line or f"fn {callee}(" in line:
                continue
            calls += 1
            if not LOG.search("\n".join(text[i : i + span])):
                missing.append((fname, i + 1, callee))
    if calls == 0:
        print(
            "FAIL: no call site was found for any of "
            f"{', '.join(c for _, c, _ in OUTCOME)}.\n"
            "      They were renamed or inlined, and this half of the gate has\n"
            "      been checking nothing."
        )
        return 1
    print(f"{calls} call site(s) of the two-layer functions read.")
    if missing:
        print("FAIL: a call site takes the answer and does not write it down:")
        for fname, lineno, callee in missing:
            print(f"      {fname}:{lineno}  calls `{callee}` and logs no outcome")
        print(
            "      `[ops] running <op>` is already printed for every op. Without an\n"
            "      outcome line next to the call, a refused action looks exactly like\n"
            "      a host that acted and a renderer that did not -- which is the\n"
            "      reading that cost task 440 an afternoon."
        )
        return 1

    print("Nothing to report: every early return in these functions says why,")
    print("and every call site of the two-layer functions records the outcome.")
    print(
        "NOT CHECKED: whether the wording is true; every user-action function outside\n"
        "             SUBJECTS (a whitelist, and named as the wrong default in the\n"
        "             docstring); bare `if cond { return; }` and `?` elsewhere in the\n"
        "             host, which the census behind SUBJECTS did not systematically\n"
        "             cover."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
