#!/usr/bin/env python3
"""Does every entry in the landed-but-unverified ledger say its state and how it closes?

`docs/windows/status.md` §五之一之二 is where work that has landed but is not
yet proven lives. Two things went wrong with it on the day it was created, and
both are structural rather than careless:

**Four states were being written as one.** The four entries in it were all
filed as "landed, unverified" and were in fact four different states -- one
verified, one unverified, one verified in half, and one that **cannot be
observed at all** on the shipping build. Reading them as one list makes the
debt look larger than it is and hides the entry nobody can ever discharge.

**An entry with a clear closing condition still hung there.** §五's item 7 said
"the next real-machine log settles this in one line". That log arrived, it did
settle it, and the entry stayed -- because **the settling happened somewhere
else and nobody came back to strike it out.**

So an entry has to carry two things, and this gate checks that it does:

    **状态**：未验 · **销案**：<what would strike this out>

# The four words, and why four

`已验` / `未验` / `半验` / `不可观测` -- measured, not chosen: on the day this
was written the section held four entries and **each of the four states had
exactly one**. Two words would have collapsed the half-verified one into a lie
in whichever direction it was rounded, and would have left the unobservable one
looking like ordinary debt somebody could pick up.

`半验` and `不可观测` must say which half / why, in parentheses. A bare
`半验` is the same collapse one level down.

# What this gate does NOT reach

**Only §五之一之二.** §五 above it is an older, mixed list -- some items have
landed, some were never started, and "verified / unverified" does not apply to
work that does not exist. Forcing this format there would produce a state word
for every entry and a true one for some of them.

**It checks structure, not truth.** Nothing here can tell whether `已验` is
honest or whether a closing condition is achievable. It catches the entry that
says nothing, which is the one that rots quietly.

Run:  python3 windows/tools/ledger-entries-say-their-state.py
Exit: 0 when every entry in that section carries a state and a closing
      condition, or an exemption that says why it cannot.
"""

import os
import re
import sys

SECTION = "## 五之一之二"
ENTRY = re.compile(r"^### （[一二三四五六七八九十]+）")
STATE = re.compile(r"\*\*状态\*\*：(已验|未验|半验|不可观测)([^\n]*)")
CLOSES = re.compile(r"\*\*销案\*\*：(\S[^\n]*)")
EXEMPT = re.compile(r"<!--\s*状态豁免：(\S[^>]*?)\s*-->")

# `半验` and `不可观测` are claims with a missing half; the half has to be
# written where the word is.
NEEDS_WHY = ("半验", "不可观测")


def section_of(src: str):
    """The lines of §五之一之二, and the line number each starts at."""
    lines = src.split("\n")
    start = None
    for i, line in enumerate(lines):
        if line.startswith(SECTION):
            start = i
            continue
        if start is not None and line.startswith("## ") and i > start:
            return lines[start:i], start + 1
    if start is None:
        return None, 0
    return lines[start:], start + 1


def entries(src: str):
    """Yield `(title, line, body)` for each `### （N）` entry in the section."""
    body, offset = section_of(src)
    if body is None:
        return
    starts = [i for i, line in enumerate(body) if ENTRY.match(line)]
    for n, i in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(body)
        yield body[i].strip(), offset + i, "\n".join(body[i:end])


def check(entry_body: str):
    """`[]` when the entry is well formed, else the complaints."""
    if EXEMPT.search(entry_body):
        return []

    bad = []
    m = STATE.search(entry_body)
    if not m:
        bad.append("no **状态**： line (must be 已验 / 未验 / 半验 / 不可观测)")
    elif m.group(1) in NEEDS_WHY and "（" not in m.group(2) and "(" not in m.group(2):
        bad.append(f"**状态**：{m.group(1)} without saying which half / why, in brackets")

    if not CLOSES.search(entry_body):
        bad.append("no **销案**： line (what would strike this entry out)")
    return bad


# -- self-test ---------------------------------------------------------------
#
# **Run before the tree is read**, so a broken probe cannot report a clean
# ledger. Each sample is one of the ways an entry can be wrong, plus the two
# that must pass.

def _wrap(entry):
    return SECTION + "、x\n\n" + entry + "\n\n## 五之二、y\n"


GOOD = _wrap("### （一）任务 1：a\n\n**状态**：未验 · **销案**：WT 跑完那六格\n")
GOOD_HALF = _wrap("### （一）任务 1：a\n\n**状态**：半验（锁序已验，投递验不了）· **销案**：一台会投递事件的机器\n")
NO_STATE = _wrap("### （一）任务 1：a\n\n**销案**：WT 跑完那六格\n")
NO_CLOSE = _wrap("### （一）任务 1：a\n\n**状态**：未验\n")
BARE_HALF = _wrap("### （一）任务 1：a\n\n**状态**：半验 · **销案**：那台机器\n")
EXCUSED = _wrap("### （一）任务 1：a\n\n<!-- 状态豁免：这条是别人的账，格式由他们定 -->\n")

for name, sample, want in (
    ("a well-formed entry", GOOD, 0),
    ("半验 with its half named", GOOD_HALF, 0),
    ("an entry with no state", NO_STATE, 1),
    ("an entry with no closing condition", NO_CLOSE, 1),
    ("a bare 半验", BARE_HALF, 1),
    ("an entry with a written exemption", EXCUSED, 0),
):
    got = sum(len(check(b)) for _, _, b in entries(sample))
    if (got > 0) != (want > 0):
        print(f"FAIL: the probe is wrong about {name}: {got} complaint(s), expected "
              f"{'some' if want else 'none'}.")
        sys.exit(1)

# **The section walk itself**, because everything above would pass on a file
# where the section cannot be found: zero entries, zero complaints, green.
# A gate that reports clean because it read nothing is the shape this
# directory keeps meeting.
if len(list(entries(_wrap("### （一）x\n\n**状态**：未验 · **销案**：y\n")))) != 1:
    print("FAIL: the probe cannot find an entry it just constructed.")
    sys.exit(1)

# The three above are unit checks on `check` and `entries`. **They are not the
# same as the script going red**, and the two can come apart at the reporting,
# so all three were also injected end to end against a copy of the real file:
# removing a `**状态**：` line, flattening a `半验（…）` to a bare `半验`, and
# renaming the section so it cannot be found. Each gave `exit=1` with the
# matching message. **A pure function passing its own test is not the same as
# the script failing**, and only the second is what anybody will see.
print("probe self-test: OK (state, closing condition, bare 半验, exemption, and "
      "the section walk)")

# -- the tree ----------------------------------------------------------------

here = os.path.dirname(os.path.abspath(__file__))
path = os.path.join(here, "..", "..", "docs", "windows", "status.md")
with open(path, encoding="utf-8") as fh:
    src = fh.read()

found = list(entries(src))
if not found:
    print()
    print(f"FAIL: no entries found under `{SECTION}` in docs/windows/status.md.")
    print("      Either the section was renamed or the heading shape changed --")
    print("      **and this gate would otherwise report a clean ledger for a file")
    print("      it could not read.**")
    sys.exit(1)

print(f"scanned `{SECTION}`: {len(found)} entr{'y' if len(found) == 1 else 'ies'}")
print()

bad = 0
for title, line, body in found:
    problems = check(body)
    if not problems:
        state = STATE.search(body)
        excused = EXEMPT.search(body)
        label = f"状态：{state.group(1)}" if state else f"豁免：{excused.group(1)}"
        print(f"      status.md:{line}  {title}")
        print(f"          {label}")
        continue
    bad += 1
    print(f"  ***  status.md:{line}  {title}")
    for p in problems:
        print(f"          {p}")
print()

if not bad:
    print(f"OK: all {len(found)} entries say what state they are in and what would "
          f"close them.")
    sys.exit(0)

print(f"FAIL: {bad} of {len(found)} entries do not say their state or how they close.")
print()
print("      **Floor when this gate was written: 4 of 4.** The section had no")
print("      format at all: two of its four entries carried a state in prose")
print("      (\"landed, unverified\") and two carried nothing, because there was")
print("      nothing to copy. None of the four was machine-readable.")
print()
print("      Each entry needs a line of this shape:")
print()
print("          **状态**：未验 · **销案**：<what would strike this out>")
print()
print("      `半验` and `不可观测` must name the half or the reason in brackets.")
print("      An entry that genuinely cannot carry one says so instead:")
print()
print("          <!-- 状态豁免：<why> -->")
sys.exit(1)
