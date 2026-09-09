#!/usr/bin/env python3
"""A log budget shared by every renderer answers about the wrong one.

**Written from an investigation that two instruments failed the same way.**
`[rsz]` and `[blit]` both existed, both were exactly the lines needed to tell
"the pane is drawing nothing" apart from "the pane is not drawing", and both
capped themselves with a file-level `var` -- one counter for the whole
process. The first surface to draw spent the entire budget during startup, so
every pane opened afterwards was silent from birth. Filtering the log for the
pane under investigation returned nothing at all, and a reader who has not
been told about the cap reads that as "that code never ran".

⚠️ **Raising the cap does not fix this**; it moves the moment it runs out.
The budget has to belong to the renderer, so each one gets its own.

**What this reads.** Any Zig file under `src/renderer/` that carries an
instrumentation budget -- a declaration whose name ends in `_log_count` or
`_log_max`, or a `LogBudget` field. A budget is well-formed when its mutable
half is reached through an instance (`self.`), and ill-formed when it is a
container-level `var`, which in Zig is process-global state.

⚠️ **Default include, exceptions carry a reason.** A new counter under
`src/renderer/` is a subject unless it is listed in `EXEMPT` with why.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RENDERER = ROOT / "src" / "renderer"

# A container-level mutable counter: `var` at column zero (Zig file scope) or
# indented inside a `pub fn` type-returning block but not inside a struct
# field list. We read the simple, checkable half: a file-scope `var` whose
# name looks like a logging counter.
FILE_SCOPE_VAR = re.compile(r"^var\s+(\w*log\w*)\b", re.MULTILINE)

# The shape that is fine: the counter is reached through an instance.
PER_INSTANCE = re.compile(r"\bself\.\w*log\w*\.(take|hasRoom|spent)\b")

# Names that mention a budget at all, so a file with no instrumentation is
# not counted as a subject.
MENTIONS_BUDGET = re.compile(r"\w*_log_(count|max)\b|\bLogBudget\b")

# ⚠️ Exceptions are named with the reason they are not subjects. An empty
# reason is not an exception.
EXEMPT: dict[str, str] = {}


def main() -> int:
    # The probe: the defect's real shape against the fixed shape. A reader
    # that has stopped telling these apart is broken, and nothing it says
    # below about the tree would mean anything.
    bad = "var rsz_log_count: usize = 0;\nconst rsz_log_max: usize = 20;\n"
    good = (
        "const rsz_log_max: usize = 20;\n"
        "rsz_log: renderer.LogBudget = .{ .max = rsz_log_max },\n"
        "if (self.rsz_log.hasRoom() or size_changed) { _ = self.rsz_log.take(); }\n"
    )
    probe_ok = (
        FILE_SCOPE_VAR.search(bad)
        and not PER_INSTANCE.search(bad)
        and not FILE_SCOPE_VAR.search(good)
        and PER_INSTANCE.search(good)
        and MENTIONS_BUDGET.search(bad)
        and MENTIONS_BUDGET.search(good)
    )
    print(
        "probe self-test:",
        "OK (a process-wide counter and a per-instance budget are told apart)"
        if probe_ok
        else "FAILED -- the reader is broken, so nothing below means anything",
    )
    if not probe_ok:
        return 2

    subjects = 0
    shared = []
    for path in sorted(RENDERER.rglob("*.zig")):
        rel = path.relative_to(ROOT).as_posix()
        if rel in EXEMPT:
            continue
        text = path.read_text(encoding="utf-8")
        if not MENTIONS_BUDGET.search(text):
            continue
        subjects += 1
        for m in FILE_SCOPE_VAR.finditer(text):
            line = text[: m.start()].count("\n") + 1
            shared.append((rel, line, m.group(1)))

    # ⚠️ **Nothing to look at is not a pass.** If the shapes this reads have
    # moved, the loop above finds no subjects and returns 0 -- which is
    # indistinguishable from a tree where every budget is per renderer.
    if subjects == 0:
        print(
            "FAIL: no instrumentation budget was found under src/renderer/ at all.\n"
            "      Either the instruments were removed, or this checker is reading\n"
            "      for a shape that no longer exists. Passing would say 'every\n"
            "      budget is per renderer' about no budgets."
        )
        return 1

    print(f"{subjects} file(s) under src/renderer/ carrying a log budget were read.")
    if shared:
        print("FAIL: a logging budget is process-global, not per renderer:")
        for rel, line, name in shared:
            print(f"      {rel} line {line}: `var {name}`")
        print(
            "      One counter for every surface means the first pane to draw spends\n"
            "      it all, and every pane opened later is silent from birth. A reader\n"
            "      filtering for that pane sees nothing, which reads exactly like the\n"
            "      code never running."
        )
        return 1

    print("Nothing to report: every log budget under src/renderer/ is per instance.")
    print(
        "NOT CHECKED: whether the budget is *large enough* for any particular\n"
        "             investigation, whether the lines it permits are the useful\n"
        "             ones, and budgets outside src/renderer/."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
