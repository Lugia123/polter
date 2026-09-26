#!/usr/bin/env python3
"""Every `.py` directly in a gate directory is a gate, and nothing else is.

**Why this one exists.** "Run all the gates" has no checked-in definition. It
is whatever loop the person running them writes -- `tools/*.py` plus
`windows/tools/*.py` -- and `gates-fail-on-empty.py` has its own, a glob of
`windows/tools/*.py`. Those agree only while the directory holds nothing but
gates. `_cb_action.py` was a shared module *and* a check in one file, and the
`_` prefix put it on different sides of different lists: a loop skipping `_*`
counted 85 where one that did not counted 86, and the meta-gate counted it as
a gate whose empty-tree refusal was a crash. Which of those numbers was "all
the gates" depended on who was asked.

Making the lists equal today would not stop them parting again. This makes
the one thing that parts them unable to pass:

  1. **No `_`-prefixed script** in either directory. The prefix is the only
     reason a hand-written loop would skip a file, so with none present every
     reasonable loop sees the same set.
  2. **No script imports another.** A file that others import is a module,
     and a module in the gate directory is a gate to every glob. Shared code
     goes in `windows/tools/lib/`, which no loop and no glob here descends
     into.
  3. **Nothing in `lib/` runs as a script.** A module with a `__main__` is a
     check hiding where no loop looks; the check goes next to the gates under
     its own name (as `cb-action-arms-are-found.py` did).

The subject is both directories, and it is asked for first: either one
missing, or holding no `.py`, is a FAIL rather than nothing to complain about.

Run:  python3 windows/tools/every-script-here-is-a-gate.py
Exit: 0 when both directories hold only gates and lib/ holds only modules.
"""

import ast
import glob
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
GATE_DIRS = [os.path.join(ROOT, "tools"), HERE]
LIB = os.path.join(HERE, "lib")


def rel(p: str) -> str:
    return os.path.relpath(p, ROOT)


def imported_names(path: str):
    """Top-level names a file imports, as the first dotted component."""
    with open(path, encoding="utf-8") as fh:
        tree = ast.parse(fh.read(), filename=path)
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                yield a.name.split(".")[0]
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            yield node.module.split(".")[0]


def runs_as_script(path: str) -> bool:
    """Does the file have an `if __name__ == "__main__":` block?"""
    with open(path, encoding="utf-8") as fh:
        tree = ast.parse(fh.read(), filename=path)
    for node in ast.walk(tree):
        if isinstance(node, ast.Compare) and isinstance(node.left, ast.Name) \
                and node.left.id == "__name__":
            for c in node.comparators:
                if isinstance(c, ast.Constant) and c.value == "__main__":
                    return True
    return False


def main() -> int:
    gates = []
    for d in GATE_DIRS:
        found = sorted(glob.glob(os.path.join(d, "*.py")))
        if not os.path.isdir(d) or not found:
            print(f"FAIL: {rel(d)}/ is missing or holds no .py. This check's "
                  f"subject is both gate directories, and one of them is not "
                  f"here -- that is looking in the wrong place, not a clean run.")
            return 1
        gates += found

    problems = []

    for g in gates:
        if os.path.basename(g).startswith("_"):
            problems.append(
                f"{rel(g)}: starts with `_`. A loop that skips `_*` and one "
                f"that does not now count different sets. If it is a gate, "
                f"name it like one; if it is shared code, move it to "
                f"{rel(LIB)}/.")

    stems = {os.path.splitext(os.path.basename(g))[0]: g for g in gates}
    for g in gates:
        for name in sorted(set(imported_names(g))):
            if name in stems:
                problems.append(
                    f"{rel(g)} imports {rel(stems[name])}: a file other gates "
                    f"import is a module, and here every file is a gate. Move "
                    f"the shared part to {rel(LIB)}/.")

    for m in sorted(glob.glob(os.path.join(LIB, "*.py"))):
        if runs_as_script(m):
            problems.append(
                f"{rel(m)}: has a `__main__` block. Nothing runs files in "
                f"lib/, so a check there is one no loop ever runs; give it its "
                f"own gate next to the others.")

    print(f"looked at {len(gates)} gate script(s) in "
          f"{', '.join(rel(d) + '/' for d in GATE_DIRS)} and "
          f"{len(glob.glob(os.path.join(LIB, '*.py')))} module(s) in {rel(LIB)}/")

    if problems:
        print()
        for p in problems:
            print(f"  {p}")
        print()
        print(f"FAIL: {len(problems)} file(s) are not one thing. Every .py in a "
              f"gate directory must be a gate, and nothing a gate imports may "
              f"be one, or \"all the gates\" means different sets to different "
              f"runners.")
        return 1

    print("OK: every script in a gate directory is a gate; shared code is in lib/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
