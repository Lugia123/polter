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

**NOT CHECKED: whether a gate that exits non-zero does so for the right
reason.** See `CAVEATS` below -- one gate passes here on its ratchet rather
than on a subject-set guard, and this gate says so out loud every run rather
than counting it as proven.
"""

import glob
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
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

# Out of scope, with the reason. `tools/no-local-identifiers.py` at the repo
# root takes its subject set from `git ls-files`, not from a glob, so "a tree
# with empty directories" is not its control at all -- its control is "a git
# repo with no tracked files". Running it here would go non-zero because there
# is no repo, which is a pass for a reason that proves nothing.
OUT_OF_SCOPE = "tools/no-local-identifiers.py (subject set comes from git, not a glob)"


def build_empty_tree(gates, extra=()):
    """A tree where every gate's subject is present but empty."""
    top = tempfile.mkdtemp(prefix="gates-fail-on-empty-")
    tools = os.path.join(top, "windows", "tools")
    for d in ("windows/tools", "windows/host/src", "docs/windows", "src", "include/ghostty"):
        os.makedirs(os.path.join(top, *d.split("/")), exist_ok=True)
    for g in gates:
        shutil.copy2(os.path.join(HERE, g), tools)
    for name, body in extra:
        with open(os.path.join(tools, name), "w", encoding="utf-8") as fh:
            fh.write(body)
    return top, tools


def run(tools, name):
    try:
        p = subprocess.run([sys.executable, name], cwd=tools,
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
    good = "import sys\nprint('FAIL: nothing to scan')\nsys.exit(1)\n"
    bad = "print('scanned 0 files')\nprint('OK: all clear')\n"
    top, tools = build_empty_tree([], extra=(("zz_probe_good.py", good),
                                             ("zz_probe_bad.py", bad)))
    try:
        rc_good, _ = run(tools, "zz_probe_good.py")
        rc_bad, _ = run(tools, "zz_probe_bad.py")
    finally:
        shutil.rmtree(top, ignore_errors=True)
    if rc_good == 0 or rc_bad != 0:
        print(f"FAIL: self-test broken (guarded probe exited {rc_good}, "
              f"unguarded probe exited {rc_bad}); this gate cannot tell the "
              f"two apart, so nothing below it means anything.")
        return False
    print("probe self-test: OK (a guarded gate passes, an unguarded one is caught)")
    return True


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

    top, tools = build_empty_tree(gates)
    try:
        results = [(g,) + run(tools, g) for g in gates]
    finally:
        shutil.rmtree(top, ignore_errors=True)

    print(f"ran {len(results)} gate(s) against a tree with empty subjects\n")

    green = [r for r in results if r[1] == 0]
    for name, rc, last in results:
        if rc == 0:
            print(f"  SLEPT  {name}: exit 0 -- {last}")

    for name, why in sorted(CAVEATS.items()):
        if any(n == name for n, _, _ in results):
            print(f"  NOTE   {name}: passes, but not on a subject-set guard.\n"
                  f"         {why}")
    print(f"  SKIP   {OUT_OF_SCOPE}")
    print()

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

    print(f"every gate refuses to pass on an empty tree "
          f"({len(results) - len(CAVEATS)} on a subject-set guard, "
          f"{len(CAVEATS)} noted above).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
