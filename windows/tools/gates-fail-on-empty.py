#!/usr/bin/env python3
"""Every gate in this directory must fail when it has nothing to look at.

**Why this one exists.** A gate that scanned zero files prints its all-clear
and returns 0, and that is indistinguishable from a gate that scanned the
whole tree and found nothing wrong. Four of the sixteen gates here were in
exactly that state, and the way it was found was not by reading them -- it was
by pointing them at a tree where `windows/host/src/` is empty and looking at
the exit codes:

    borrow-across-dispatch.py   `scanned 0 files`          -> `OK: ...`      exit 0
    lock-reentry.py             `scanned 0 files; 0 ...`   -> `no unexpected hits`  exit 0
    post-op-has-a-target.py     `scanned 0 files; ...`     -> `none: ...`    exit 0
    settings-one-reader.py      `looked at 0 file reads`   -> `one reader per fact` exit 0

**All four printed the zero and then said OK.** The reading was on the screen
the whole time and nothing acted on it.

**This gate asserts behaviour, not text, and that is the whole reason it can
exist.** The family these four belong to -- "the reach of the instrument and
the shape of the thing being measured are not the same set" -- was judged
*not* gateable, because its instances live in a config default, a process
name, a shell image name, a regex matching itself: five different carriers, no
common textual shape, and any pattern wide enough to catch them all would
report every correct `Get-Process` and every correct default in the tree.

The two judgements come from one criterion, and they are the two sides of it:

    single carrier + assert behaviour   -> a gate can exist, and its false
                                           positive rate is structurally zero
    scattered carriers + match text     -> it cannot; write it down instead

Here the carrier is single (one directory of sibling scripts, all of which
end in an exit code) and the assertion is a run, not a pattern. There is
nothing to be wrong about: either the gate exits non-zero on an empty tree or
it does not.

**The repository-root gates are in scope too** (issue #41). `tools/*.py` used
to be outside this check altogether, and one of them was named here only to be
skipped: `tools/no-local-identifiers.py`, the gate between this machine and a
public repository. This file already said what its control was -- "a git repo
with no tracked files" -- and nobody ran it. Run, it exited 0: `scanned 0
tracked files`, `no unexpected hits`. So was `a-callback-does-not-discard-the-
cores-answer.py` (`0 host source(s)` -> `OK.`), and so was `imports-match-the-
file-on-disk.py` (`0 .zig file(s)`). The empty tree is now a git repository
with nothing tracked, so a gate that reads its subjects from git gets its real
control, and both sets are run in it.

A second cell, for the leak gate alone: **run from a subdirectory it must still
scan the whole repository.** `git ls-files` lists the current directory and
below, and the gate used to scan only that (measured: a leak one level up,
`scanned 1 tracked files`, exit 0). That is not an empty-subject failure, it
is a partial one, so it is checked by count: from `sub/` of a repository with
two tracked files, it has to say it scanned two.

**A crash is not a refusal** (issue #40). An uncaught exception exits 1, the
same code as `sys.exit(1)`, so for most of this file's life a gate whose guard
had been replaced by a crash was counted as refusing -- measured: with the
`if not files:` guard of `tools/git-output-is-trimmed-first.py` turned into
`return [][0]`, this gate exited 0 and reported "85 on a subject-set guard".
So each gate runs under a small wrapper that turns an uncaught exception into
exit code `CRASH_RC`, told apart by behaviour rather than by looking for
"Traceback" in the output. The gates that crash on an empty tree today are
named in `KNOWN_CRASHES`; any other gate that crashes fails this one, and so
does a named gate that has stopped crashing, so the list can only shrink.

**NOT CHECKED: whether a refusal is for the right reason.** A gate that exits
non-zero without crashing is counted as refusing, whether its message is "I
found nothing to look at" or "a file I need is missing" (issue #44 sorts the
root set by that). See also `CAVEATS` below -- one gate refuses on its
ratchet rather than on a subject-set guard.
"""

import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# The repository-root set. See the module docstring: it was outside this check.
ROOT_TOOLS = os.path.normpath(os.path.join(HERE, "..", "..", "tools"))
PER_GATE_TIMEOUT = 90

# Default-include. Every `.py` next to this file is a gate until something
# says otherwise, and an exception has to carry its reason -- a whitelist
# would put each newly added gate outside the check by default, which is the
# wrong way round for a check whose whole subject is things nobody looked at.
EXCLUDED = {
    os.path.basename(__file__):
        "itself: it builds the empty tree, so it is not one of the subjects",
}

# Gates that exit non-zero on an empty tree for a reason that is *not* a
# subject-set guard. They pass the assertion below, but the pass does not mean
# what a pass usually means here, so they are named rather than counted.
CAVEATS = {
    "line-number-references.py":
        "exits 1 on the ratchet (0 references is below BASELINE), not because "
        "it noticed it had nothing to scan -- and its subject glob picks up "
        "the copied gate scripts themselves, so an empty tree is not an empty "
        "subject for it. Being saved by another mechanism is not the same as "
        "having this guard.",
}

# The leak gate, which also gets the subdirectory cell below.
LEAK_GATE = "no-local-identifiers.py"

# Gates whose subject is the gate directories themselves. The tree above has to
# fill both directories to run the gates at all, so for these it is not an
# empty subject, and their clean exit there says nothing -- measured: once
# `tools/` was copied in, `every-script-here-is-a-gate.py` said OK. Each is run
# instead in a tree holding only itself, where `tools/` is empty, and has to
# refuse there.
GATES_ARE_THE_SUBJECT = {"every-script-here-is-a-gate.py"}

# Exit code the wrapper below uses for an uncaught exception. No gate here
# exits with it on purpose (checked when this was written).
CRASH_RC = 97

# Runs a gate as `python <gate>` would -- `__main__`, argv, its own directory
# first on sys.path -- except that an exception nobody caught ends in
# CRASH_RC instead of 1. SystemExit passes through untouched, so a gate's own
# `sys.exit(n)` is n here too.
WRAPPER = (
    "import os, runpy, sys, traceback\n"
    "script = sys.argv[1]\n"
    "sys.argv = sys.argv[1:]\n"
    "sys.path.insert(0, os.path.dirname(os.path.abspath(script)))\n"
    "try:\n"
    "    runpy.run_path(script, run_name='__main__')\n"
    "except SystemExit:\n"
    "    raise\n"
    "except BaseException:\n"
    "    traceback.print_exc()\n"
    "    sys.stderr.flush()\n"
    f"    os._exit({CRASH_RC})\n"
)

# Gates that refuse the empty tree by crashing rather than by saying why --
# every one of them by reading a fixed file that is not there
# (FileNotFoundError). Measured 2026-09-27 on `4ccdb004f`: 23 of 86. Named
# `tools/<x>` for the repository-root set, bare for this directory.
#
# **This list may only shrink.** A gate on it that stops crashing fails this
# gate until its line is removed, so the list cannot go on excusing a gate
# that has been fixed -- or one whose crash has turned into something else.
# Fixing one: ask for the file before reading it, and FAIL naming it.
KNOWN_CRASHES = {
    "a-count-names-the-tab-it-counted.py",
    "a-gated-line-says-what-its-silence-means.py",
    "a-refusal-says-which-one.py",
    "action-arms-act.py",
    "action-payloads-are-read.py",
    "app-actions-need-no-window.py",
    "explicit-titles-are-distinguishable.py",
    "ledger-entries-say-their-state.py",
    "menu-actions-handled.py",
    "notification-carries-the-terminal.py",
    "one-release-per-press.py",
    "state-names-a-window.py",
    "the-active-tab-is-confirmed-before-it-is-set.py",
    "the-blocked-line-names-the-blocked-thread.py",
    "the-components-are-reported-on-both-arms.py",
    "the-frames-permit-comes-back.py",
    "the-heartbeat-outlives-its-own-stall.py",
    "the-key-line-decides-on-what-it-prints.py",
    "tools/menu-shortcuts-come-from-the-config.py",
    "translated-strings-reach-the-user.py",
    "uia-patterns-declared.py",
    "watchdog-alarm-path.py",
    "window-tagged-logs.py",
}


def git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def build_empty_tree(gates, extra=(), root_gates=()):
    """A tree where every gate's subject is present but empty.

    **It is a git repository with nothing tracked**, because that -- not a
    directory with no repository -- is the empty subject of a gate that reads
    `git ls-files`. Without a repository such a gate crashes and goes
    non-zero, which is a pass here for a reason that proves nothing.
    """
    top = tempfile.mkdtemp(prefix="gates-fail-on-empty-")
    tools = os.path.join(top, "windows", "tools")
    for d in ("windows/tools", "windows/host/src", "dev-docs/windows", "src",
              "include/ghostty", "tools"):
        os.makedirs(os.path.join(top, *d.split("/")), exist_ok=True)
    git(top, "init", "-q")
    for g in gates:
        shutil.copy2(os.path.join(HERE, g), tools)
    # The shared modules come along: they are code the gates run, not a
    # subject. Without them every gate that imports one dies on
    # ModuleNotFoundError before its own guard runs -- measured when lib/ was
    # introduced, two gates that refused the empty tree with a FAIL became two
    # that crashed, and this gate reported the same totals either way.
    # `glob("*.py")` does not descend into lib/, so nothing in it is a subject.
    lib = os.path.join(HERE, "lib")
    if os.path.isdir(lib):
        shutil.copytree(lib, os.path.join(tools, "lib"),
                        ignore=shutil.ignore_patterns("__pycache__"))
    for g in root_gates:
        shutil.copy2(os.path.join(ROOT_TOOLS, g), os.path.join(top, "tools"))
    for name, body in extra:
        with open(os.path.join(tools, name), "w", encoding="utf-8") as fh:
            fh.write(body)
    return top, tools


def run(cwd, name):
    try:
        p = subprocess.run([sys.executable, "-c", WRAPPER, name], cwd=cwd,
                           capture_output=True, text=True,
                           timeout=PER_GATE_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, f"timed out after {PER_GATE_TIMEOUT}s"
    last = [l for l in (p.stdout + p.stderr).splitlines() if l.strip()]
    return p.returncode, (last[-1][:100] if last else "(no output)")


def self_test():
    """Two planted gates: one that would slip through, one that would not.

    Without this, a checker that mis-copies the scripts, or runs them in a
    directory where they all crash, reports every gate as passing and says
    nothing. **A checker whose failing case is never exercised is the fifth
    gate of the four above.**
    """
    # The guarded probe imports every shared module first, the way a real
    # gate does, so a tree built without lib/ makes it crash -- and a crash is
    # caught below by what it printed, since its exit code is 1 either way.
    mods = sorted(os.path.splitext(os.path.basename(m))[0]
                  for m in glob.glob(os.path.join(HERE, "lib", "*.py")))
    good = ("import os, sys\n"
            "sys.path.insert(0, os.path.join(os.path.dirname("
            "os.path.abspath(__file__)), 'lib'))\n"
            + "".join(f"import {m}\n" for m in mods)
            + "print('FAIL: nothing to scan')\nsys.exit(1)\n")
    bad = "print('scanned 0 files')\nprint('OK: all clear')\n"
    # A gate whose guard is a crash: exits 1 like the guarded one, and has to
    # be told apart from it by the wrapper, not by its exit code.
    crash = "open('this-file-is-not-in-the-empty-tree.txt').read()\n"
    top, tools = build_empty_tree([], extra=(("zz_probe_good.py", good),
                                             ("zz_probe_bad.py", bad),
                                             ("zz_probe_crash.py", crash)))
    try:
        rc_good, said_good = run(tools, "zz_probe_good.py")
        rc_bad, _ = run(tools, "zz_probe_bad.py")
        rc_crash, _ = run(tools, "zz_probe_crash.py")
    finally:
        shutil.rmtree(top, ignore_errors=True)
    if rc_good in (0, CRASH_RC) or rc_bad != 0 or rc_crash != CRASH_RC:
        print(f"FAIL: self-test broken (guarded probe exited {rc_good}, "
              f"unguarded probe exited {rc_bad}, crashing probe exited "
              f"{rc_crash}, expected 1 / 0 / {CRASH_RC}); this gate cannot "
              f"tell the three apart, so nothing below it means anything.")
        return False
    if not said_good.startswith("FAIL: nothing to scan"):
        print(f"FAIL: self-test broken: the guarded probe did not reach its "
              f"own refusal ({said_good!r}). If that is an ImportError, the "
              f"empty tree is missing lib/, and every gate that imports from "
              f"it is refusing by crashing rather than by its guard.")
        return False
    print("probe self-test: OK (a guarded gate passes, an unguarded one is "
          "caught, a crashing one is told apart from a refusal)")
    return True


def leak_gate_scans_the_whole_repo():
    """The subdirectory cell: two tracked files, run from `sub/`, must scan two.

    Returns a problem string, or None. Read by count, not by exit code, because
    both files are clean and the failure this catches is a partial scan that
    exits 0 -- the same code as the full scan.
    """
    top = tempfile.mkdtemp(prefix="gates-leak-subdir-")
    try:
        os.makedirs(os.path.join(top, "sub"))
        for rel in ("top.txt", os.path.join("sub", "below.txt")):
            with open(os.path.join(top, rel), "w", encoding="utf-8") as fh:
                fh.write("nothing to see\n")
        git(top, "init", "-q")
        git(top, "add", "top.txt", os.path.join("sub", "below.txt"))
        rc, out = run_full(os.path.join(top, "sub"), os.path.join(ROOT_TOOLS, LEAK_GATE))
    finally:
        shutil.rmtree(top, ignore_errors=True)
    m = re.search(r"scanned (\d+) tracked files", out)
    if rc != 0 or m is None or m.group(1) != "2":
        seen = m.group(1) if m else "no count"
        return (f"tools/{LEAK_GATE} run from a subdirectory of a repository with 2 "
                f"tracked files: exit {rc}, scanned {seen}. It has to scan the whole "
                f"repository, wherever it is run from.")
    return None


def run_full(cwd, script):
    try:
        p = subprocess.run([sys.executable, script], cwd=cwd, capture_output=True,
                           text=True, timeout=PER_GATE_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, f"timed out after {PER_GATE_TIMEOUT}s"
    return p.returncode, p.stdout + p.stderr


def main() -> int:
    if not self_test():
        return 1

    gates = sorted(os.path.basename(p) for p in glob.glob(os.path.join(HERE, "*.py"))
                   if os.path.basename(p) not in EXCLUDED)

    # **Do not become the fifth.** Zero gates found is not a clean result; it
    # is this gate failing to look, wearing the same exit code as success.
    if not gates:
        print(f"FAIL: no gate scripts found next to {HERE}. This is not a "
              f"clean run -- it is this gate scanning nothing, which is the "
              f"exact failure it exists to catch.")
        return 1

    root_gates = sorted(os.path.basename(p) for p in glob.glob(os.path.join(ROOT_TOOLS, "*.py")))
    if not root_gates:
        print(f"FAIL: no gate scripts found in tools/ at the repository root. That set "
              f"is in scope; finding none is this gate failing to look.")
        return 1

    top, tools = build_empty_tree(gates, root_gates=root_gates)
    try:
        results = [(g,) + run(tools, g) for g in gates
                   if g not in GATES_ARE_THE_SUBJECT]
        # Run from the empty tree's root, which is where they are run from.
        results += [(f"tools/{g}",) + run(top, os.path.join("tools", g)) for g in root_gates]
    finally:
        shutil.rmtree(top, ignore_errors=True)
    for g in sorted(GATES_ARE_THE_SUBJECT & set(gates)):
        top, tools = build_empty_tree([g])
        try:
            results.append((g,) + run(tools, g))
        finally:
            shutil.rmtree(top, ignore_errors=True)

    print(f"ran {len(results)} gate(s) against a tree with empty subjects "
          f"({len(gates)} in windows/tools, {len(root_gates)} in tools/), "
          f"the tree being a git repository with nothing tracked\n")

    green = [r for r in results if r[1] == 0]
    for name, rc, last in results:
        if rc == 0:
            print(f"  SLEPT  {name}: exit 0 -- {last}")

    crashed = {name: last for name, rc, last in results if rc == CRASH_RC}
    ran = {name for name, _, _ in results}
    unexpected = sorted(set(crashed) - KNOWN_CRASHES)
    recovered = sorted(n for n in KNOWN_CRASHES if n in ran and n not in crashed)
    vanished = sorted(n for n in KNOWN_CRASHES if n not in ran)
    for name in unexpected:
        print(f"  CRASH  {name}: {crashed[name]}")
    for name in recovered:
        print(f"  FIXED  {name}: no longer crashes -- take it out of KNOWN_CRASHES")
    for name in vanished:
        print(f"  GONE   {name}: named in KNOWN_CRASHES, but no such gate ran")

    for name, why in sorted(CAVEATS.items()):
        if any(n == name for n, _, _ in results):
            print(f"  NOTE   {name}: passes, but not on a subject-set guard.\n"
                  f"         {why}")
    print()

    partial = leak_gate_scans_the_whole_repo()
    if partial:
        print(f"  PARTIAL {partial}\n")
    else:
        print(f"  OK     tools/{LEAK_GATE} scans the whole repository from a subdirectory\n")

    if green:
        print(f"{len(green)} gate(s) returned 0 with nothing to scan.\n"
              f"**That exit code is indistinguishable from a clean tree.** A "
              f"gate must not be able to pass by failing to look.\n"
              f"The fix is two lines, and `ps1-parses.py` is the model:\n"
              f"    if not subjects:\n"
              f"        print('FAIL: nothing found; looking in the wrong place')\n"
              f"        sys.exit(1)\n"
              f"What has to be non-empty is the *subject set*, not the hit "
              f"count: zero hits is a real pass, zero files is not an answer.")
        return 1
    if unexpected:
        print(f"{len(unexpected)} gate(s) refused the empty tree by crashing, and "
              f"are not in KNOWN_CRASHES.\n**A crash exits 1 like a refusal, but "
              f"it says nothing about the gate having noticed**: it is whatever "
              f"the tree happened to be missing. Ask for the subject first and "
              f"FAIL naming it.")
        return 1
    if recovered or vanished:
        print("KNOWN_CRASHES names gate(s) that no longer crash here. Remove "
              "them: a list that excuses a fixed gate would go on excusing it "
              "after it breaks again.")
        return 1
    if partial:
        return 1

    refused = len(results) - len(crashed) - len(CAVEATS)
    print(f"every gate refuses to pass on an empty tree: {refused} without "
          f"crashing, {len(crashed)} by crashing (all named in KNOWN_CRASHES), "
          f"{len(CAVEATS)} noted above.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
