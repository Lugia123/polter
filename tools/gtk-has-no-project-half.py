#!/usr/bin/env python3
"""GTK has no project feature, and the documents say so, and the two agree.

**Why this exists (issue #27).** Projects -- save a tab, open it again, bring
back each pane's command history and scrollback -- are wired on macOS and
Windows and not at all on GTK. That was decided, not forgotten: there is no
Linux machine to run the GTK app on, so an implementation could only ever
reach *Built* (see `ROADMAP.md`), and four of the eleven pieces are UI. The
same issue counted those pieces against the macOS side and found none that
GTK *cannot* do, so the decision is an ordering and can be reversed the day
a machine exists.

What it guards against is not somebody doing the work. It is **half of it
arriving unannounced**: a restore field passed through here, a capture
called there, each small and each compiling, until GTK has a project feature
nobody has run and the documents still say it has none -- or the other way
round, the documents quietly start describing GTK as "a small piece" again,
which is what `dev-docs/project-scrollback.md` said until this file existed.

So it holds three things together, and whoever makes GTK support projects
deletes this file and rewrites both documents **in the same commit**:

  1. No project symbol appears in GTK's code. Comments are ignored, so a note
     that names one is fine. (At dc6a1b475 the pattern below has 0 hits even
     with comments included; the two GNOME wiki links #27 found matched a
     looser `Project` grep, not this.)
  2. **The `history_filename` arm in `application.zig` is still the
     `unimplemented` stub.** Checked positively: if the arm cannot be found
     at all, that is a failure, not a pass. A check for "no project symbols"
     is trivially green on a tree where the file moved or the arm was
     rewritten into something this pattern does not recognise.
  3. Both documents still carry the statement.

**Blind-reader guard.** Fewer than `MIN_GTK_FILES` `.zig` files under
`src/apprt/gtk/` is a failure: a moved directory would otherwise make face 1
scan nothing and pass.

NOT CHECKED: a project feature reached from GTK through a file outside
`src/apprt/gtk/` (the core is shared, so the core's own project code is
expected to exist and is not this file's subject).

Run:  python3 tools/gtk-has-no-project-half.py
Exit: 0 when all three faces hold.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))

GTK = os.path.join(ROOT, "src", "apprt", "gtk")
APPLICATION = os.path.join(GTK, "class", "application.zig")

# 56 `.zig` files under src/apprt/gtk at dc6a1b475 (`find src/apprt/gtk -name
# '*.zig' | wc -l`); the floor is well below that on purpose, so that ordinary
# churn never trips it and a moved or emptied directory always does.
MIN_GTK_FILES = 30

# Face 1. Names a GTK project feature would have to use. `Project.` is the
# core's file-format module; the other four are how a surface is restored
# and captured.
SYMBOLS = re.compile(
    r"\bProject\.|Project\.zig|_history_restore|_scrollback_restore"
    r"|captureScrollback|capture_scrollback"
)

# Face 2. The stub arm: `.history_filename` (possibly among other tags) then
# a body that logs "unimplemented" and returns false.
STUB = re.compile(
    r"\.history_filename\s*,\s*(?:\.\w+\s*,\s*)*=>\s*\{\s*"
    r"log\.warn\(\s*\"unimplemented action=\{\}\"\s*,\s*\.\{\s*action\s*\}\s*\)\s*;\s*"
    r"return\s+false\s*;\s*\}"
)

# Face 3. The statements, one per document.
DOCS = {
    os.path.join(ROOT, "ROADMAP.md"): "**Projects do not exist on GTK**",
    os.path.join(ROOT, "dev-docs", "project-scrollback.md"): "**不做，也不是「一小块」。**",
}


def strip_comments(text):
    # Zig has only `//` comments (`///` and `//!` included). A `//` inside a
    # string literal would be cut too; the only effect is a symbol hidden
    # after one, which none of the names above plausibly is.
    return re.sub(r"//[^\n]*", "", text)


def rel(p):
    return os.path.relpath(p, ROOT)


def main():
    problems = []

    files = []
    for dirpath, _dirs, names in os.walk(GTK):
        files += [os.path.join(dirpath, n) for n in names if n.endswith(".zig")]
    files.sort()
    if len(files) < MIN_GTK_FILES:
        print(
            f"FAIL: found {len(files)} .zig files under {rel(GTK)} (need at least "
            f"{MIN_GTK_FILES}) -- the directory moved or emptied, and every check "
            f"below would pass on nothing"
        )
        return 1

    # Face 1.
    hits = 0
    for p in files:
        with open(p, encoding="utf-8") as f:
            code = strip_comments(f.read())
        for m in SYMBOLS.finditer(code):
            line = code.count("\n", 0, m.start()) + 1
            problems.append(
                f"face 1: {rel(p)}:{line} uses {m.group(0)!r} -- a project feature on "
                f"GTK; see this file's docstring for what has to change with it"
            )
            hits += 1

    # Face 2.
    if not os.path.isfile(APPLICATION):
        problems.append(f"face 2: {rel(APPLICATION)} is gone, so the stub arm cannot be found")
    else:
        with open(APPLICATION, encoding="utf-8") as f:
            code = strip_comments(f.read())
        arms = len(re.findall(r"\.history_filename\b", code))
        stubs = len(STUB.findall(code))
        if stubs != 1 or arms != 1:
            problems.append(
                f"face 2: {rel(APPLICATION)} has {arms} `.history_filename` and {stubs} "
                f"`unimplemented` stub arm(s); expected exactly one of each -- the action "
                f"is handled now, or the stub changed shape and this can no longer see it"
            )

    # Face 3.
    for path, needle in DOCS.items():
        if not os.path.isfile(path):
            problems.append(f"face 3: {rel(path)} is gone")
            continue
        with open(path, encoding="utf-8") as f:
            if needle not in f.read():
                problems.append(f"face 3: {rel(path)} no longer says {needle}")

    print(
        f"scanned {len(files)} GTK .zig files: {hits} project symbol(s); "
        f"stub arm checked; {len(DOCS)} documents checked"
    )
    if problems:
        for p in problems:
            print("FAIL " + p)
        return 1
    print("ok: GTK has no project half, and both documents say so")
    return 0


if __name__ == "__main__":
    sys.exit(main())
