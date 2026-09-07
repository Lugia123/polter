#!/usr/bin/env python3
"""Naming a hang-detecting API without naming what it cannot see.

`IsHungAppWindow`, `SendMessageTimeout(WM_NULL)` and PowerShell's
`Process.Responding` all answer one question -- **has this window processed a
message lately** -- and are routinely read as answering a different one: *is
this application stuck*. A nested modal loop (a `MessageBoxW`, a menu, a
window move/size) **keeps pumping**, so all three answer "fine" while the
person has been unable to use the window for two and a half minutes.

Measured on 2026-09-03 and recorded in `docs/windows/status.md`:

    state                 SendMessageTimeout(WM_NULL)   IsHungAppWindow
    healthy               ok=true 14ms                  false
    modal box, 152 s      ok=true 0ms                   false   <- false green
    really hung           ok=false 2999ms               true

# Why a gate and not a note

**The blindness was already written down**, correctly, in `status.md`, next to
the table. It did not stop the family being used as a "not hung" reading in
the round after -- because the *next* person met the API somewhere else, in a
task, in a message, in a different file, where the caveat was not.

This repository has now had the same shape four times in one round: a rule
learned, written into a comment, and broken again one call up. **A comment is
not a defence; a checker is.** So: every place in the tree that names one of
these APIs must, within a few lines, either name what it is blind to or point
at `docs/windows/hang-readings.md`, which holds the whole reading.

# Scope, and the class this is really for

The third class is the one that gets missed and the one that does the damage:
not product code and not a probe, but **prose -- a doc or a task that tells
somebody to use it**. That is what the next person copies. So this reads
`.md`, `.rs`, `.zig`, `.py` and `.ps1` alike, under `docs/`, `src/` and
`windows/`, and it reads **this file too**: a gate that names the API and does
not carry the caveat would be its own first offender.

**NOT CHECKED:**

  * that the caveat, where present, is correct. This looks for the word, not
    for the argument.
  * anything outside the repository. The real users of this family are real-
    machine probes and criteria written in tasks and messages, which is where
    the void readings came from and where no checker reaches. That is what
    `docs/windows/hang-readings.md` is for.
  * the other direction: a *correct* use ("did this window pump in 5s") is not
    distinguished from a wrong one. Both must carry the caveat; only one of
    them needed it.

Run:  python3 windows/tools/hang-instrument-carries-its-blindness.py
Exit: 0 when every mention carries its blindness or points at the reading.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
DOC = "docs/windows/hang-readings.md"

INSTRUMENT = re.compile(r"IsHungAppWindow|SendMessageTimeout|Process\.Responding|\.Responding\b")
# Either the blindness by name, or a pointer at the file that holds it.
CAVEAT = re.compile(r"模态|modal|hang-readings|失明|blind")
REACH = 6

SUBJECTS = ("docs", "src", "windows")
EXTENSIONS = (".md", ".rs", ".zig", ".py", ".ps1")


def files_to_read():
    for top in SUBJECTS:
        base = os.path.join(ROOT, top)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if not d.startswith(".") and d != "zig-cache"]
            for name in filenames:
                if name.endswith(EXTENSIONS):
                    yield os.path.relpath(os.path.join(dirpath, name), ROOT)


SELF = os.path.join("windows", "tools", os.path.basename(__file__))


def analyse(sources: dict):
    """`sources` maps path -> text. Returns (problems, mentions, elsewhere).

    `elsewhere` counts mentions in files **other than this one**, and it is
    what the subject-set guard reads. This gate names the family a dozen times
    in its own prose, so "did I find any mentions" is a question it can answer
    yes to while having read nothing but itself -- which is exactly the shape
    `gates-fail-on-empty.py` exists to catch, and which it caught here.
    """
    bad = []
    mentions = 0
    elsewhere = 0
    for path, text in sorted(sources.items()):
        lines = text.split("\n")
        for i, line in enumerate(lines):
            if not INSTRUMENT.search(line):
                continue
            mentions += 1
            if os.path.normpath(path) != SELF:
                elsewhere += 1
            lo = max(0, i - REACH)
            window = "\n".join(lines[lo : i + REACH + 1])
            if CAVEAT.search(window):
                continue
            bad.append(
                f"{path}:{i + 1}: names a hang-detecting API with nothing "
                "nearby saying what it cannot see. A nested modal loop keeps "
                "pumping, so this family answers \"fine\" while the window has "
                "been unusable for minutes -- and the next person to read this "
                f"line is the one who will use it as a \"not hung\" reading. "
                f"Name the blindness, or point at {DOC}.")
    return bad, mentions, elsewhere


# -- self-test ---------------------------------------------------------------

BARE = {"docs/x.md": "用 `IsHungAppWindow` 判一下卡没卡。\n"}
WITH_CAVEAT = {"docs/x.md": "模态循环下它会答「没卡」。\n用 `IsHungAppWindow` 判窗口有没有泵消息。\n"}
WITH_POINTER = {"docs/x.md": "`IsHungAppWindow` -- 边界见 docs/windows/hang-readings.md\n"}
FAR_AWAY = {"docs/x.md": "模态\n" + "\n" * 20 + "`IsHungAppWindow`\n"}
# **This gate reads itself**, so the sample below carries the caveat the rule
# asks for -- a modal loop is what these instruments are blind to. Excluding
# this file instead would have been the easier fix and the wrong one: a
# checker outside its own subject set is the shape it exists to catch.
RESPONDING = {"windows/p.ps1": "(Get-Process -Id $p).Responding\n"}

for sample, want_red, label in (
    (BARE, True, "a bare mention with no caveat"),
    (WITH_CAVEAT, False, "a mention whose caveat is on the line above"),
    (WITH_POINTER, False, "a mention that points at the reading"),
    (FAR_AWAY, True,
     "a caveat twenty lines away -- out of sight is the same as absent for "
     "somebody reading the line they came for"),
    (RESPONDING, True,
     "PowerShell's `.Responding` -- the same family, blind to the same modal "
     "loop, under a name that does not look like it"),
):
    got = bool(analyse(sample)[0])
    if got != want_red:
        print(f"FAIL: the probe {'misses' if want_red else 'fires on'} {label}.")
        sys.exit(1)
if analyse(BARE)[1] != 1 or analyse(BARE)[2] != 1:
    print("FAIL: the probe does not count the mentions it looked at, so its "
          "silence cannot be told from having read nothing.")
    sys.exit(1)

# -- the tree ----------------------------------------------------------------

sources = {}
for path in files_to_read():
    try:
        with open(os.path.join(ROOT, path), encoding="utf-8") as fh:
            sources[path] = fh.read()
    except (UnicodeDecodeError, OSError):
        continue

problems, mentions, elsewhere = analyse(sources)
print(f"read {len(sources)} file(s); {mentions} mention(s) of the family, "
      f"{elsewhere} of them outside this checker")

# **Subject-set guard, and it counts mentions that are not this file's own.**
# Zero is not a clean tree: this family is named in `status.md` and in the
# reading, so zero means the walk found nothing. **Counting every mention
# would not do**, because this checker's own prose names the family a dozen
# times -- it would pass on an empty tree by reading itself, which is what
# `gates-fail-on-empty.py` reported when this file was first written.
if elsewhere == 0:
    print()
    print("FAIL: every mention found was in this checker itself, so the tree "
          "was not read. Not a pass.")
    sys.exit(1)

if not problems:
    print("OK: every mention carries its blindness or points at the reading.")
    print(f"NOT CHECKED: whether the caveat is right, and anything outside the "
          f"repository -- the probes and criteria that used this family live "
          f"in tasks and on the machine. See {DOC}.")
    sys.exit(0)

print()
for line in problems:
    print("  " + line)
print()
print(f"FAIL: {len(problems)} mention(s) without their blindness.")
sys.exit(1)
