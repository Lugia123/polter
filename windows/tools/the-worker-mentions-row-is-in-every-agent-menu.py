#!/usr/bin/env python3
"""The worker-mentions switch is in every menu the agent rows are in, spelled
the same in each, and shown or hidden by the one rule in `worker_mentions.rs`.

# The defect this is the floor for

Task 575's switch -- "Let Workers Name Each Other Directly" -- belongs in
three menus on this port: the menu bar's Agents menu (`menu.rs`), the tab
strip's right-click menu (`strip.rs`) and the terminal's own right-click menu
(`ctxmenu.rs`). The contract (`dev-docs/poltergeist/mentions.md` §6) says so
because 582 already had it happen once on macOS: the role submenu went into
two of the three menus and nothing went red, since nothing compared them
(`tools/the-role-submenu-is-wherever-the-agent-rows-are.py` is that floor,
and it reads macOS only).

The row also has a label, a binding string and a "supervisor only" rule. The
rule lives once, in `worker_mentions.rs` (the first draft wrote "is a
supervisor" as a bare `1` in two menus). **The label and binding string are
written out in each table, on purpose**: the tables are read by
`src/input/command.zig`'s `menu labels reach the palette` and by
`menu-actions-handled.py`, and both read literals -- the Zig one skipped a
row whose label was a path to a `const`, silently, in two of three tables.
So three copies it is, and this file is what keeps them the same.

# What is checked

**Default-include: the rows decide which files are menus, not a list here.**
A file is an agent menu because its code -- comments and `#[cfg(test)]`
modules stripped -- carries the shield row's binding string. A fourth menu
that grows the agent rows tomorrow is checked from the moment it does.

  1. The reference spellings are read out of `worker_mentions.rs` -- its
     `LABEL` and `ACTION` consts -- rather than written down here.
  2. Every agent menu spells the label as `n_("<LABEL>")` and the binding as
     `"<ACTION>"`, exactly. A copy that drifts is a click that does nothing
     (`binding_action` returns false, silently) or words that miss their
     translation.
  3. Every agent menu asks `worker_mentions::offered`. The literals alone are
     a row that could still be drawn on a worker.
  4. If fewer than three agent menus are found, or the two consts cannot be
     read, that is a finding. A check whose subject has vanished passes
     silently otherwise.

# NOT CHECKED

  * **Whether the row is drawn, ticked, hidden on a worker or does
    anything.** This reads source, not a running program. The pure half
    (`offered`, `ticked`) has tests in `worker_mentions.rs` that run under a
    bare `rustc --test`; the per-menu halves have tests in each file that run
    on Windows only.
  * **That the core has the binding.** `src/input/Binding.zig` is the core's.
  * **macOS and GTK.**
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "host", "src")

SHIELD = '"poltergeist_toggle_shielded"'
HOME = "worker_mentions.rs"
RULE = "worker_mentions::offered"


def reference(code, name):
    """`pub const NAME: &str = "...";` out of `worker_mentions.rs`, or None."""
    m = re.search(r'pub\s+const\s+%s\s*:\s*&str\s*=\s*"((?:[^"\\]|\\.)*)"\s*;' % name, code)
    return m.group(1) if m else None


def strip_comments(text):
    """Drop `//` comments (doc comments included), leaving string literals.

    A line is cut at the first `//` that is not inside a string. Good enough
    for these files: none of them has `//` inside a string on a row line, and
    a miss here errs towards *more* code, i.e. towards a finding.
    """
    out = []
    for line in text.splitlines():
        in_str = False
        cut = len(line)
        i = 0
        while i < len(line):
            c = line[i]
            if c == "\\" and in_str:
                i += 2
                continue
            if c == '"':
                in_str = not in_str
            elif not in_str and line.startswith("//", i):
                cut = i
                break
            i += 1
        out.append(line[:cut])
    return "\n".join(out)


def strip_test_modules(code):
    """Remove every `#[cfg(test)] mod x { ... }` block, braces matched."""
    while True:
        m = re.search(r"#\[cfg\(test\)\]\s*(pub\s+)?mod\s+\w+\s*\{", code)
        if not m:
            return code
        depth = 0
        i = m.end() - 1
        while i < len(code):
            if code[i] == "{":
                depth += 1
            elif code[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        code = code[: m.start()] + code[i + 1 :]


def main():
    if not os.path.isdir(SRC):
        print(f"FAIL: {SRC} does not exist -- nothing to scan")
        return 1
    files = sorted(f for f in os.listdir(SRC) if f.endswith(".rs"))
    findings = []
    label = action = None
    if HOME in files:
        with open(os.path.join(SRC, HOME), encoding="utf-8") as fh:
            home = strip_comments(fh.read())
        label, action = reference(home, "LABEL"), reference(home, "ACTION")
    if label is None or action is None:
        print(f"FAIL: could not read `LABEL` and `ACTION` out of {HOME}: nothing to hold the menus to")
        return 1
    want = (f'n_("{label}")', f'"{action}"')
    menus = []
    for f in files:
        if f == HOME:
            continue
        with open(os.path.join(SRC, f), encoding="utf-8") as fh:
            code = strip_test_modules(strip_comments(fh.read()))
        if SHIELD not in code:
            continue
        menus.append(f)
        for lit in want:
            if lit not in code:
                findings.append(f"{f}: carries the agent rows but never spells {lit}")
        if RULE not in code:
            findings.append(f"{f}: carries the agent rows but never asks {RULE}")

    print(f"scanned {len(files)} files; agent menus: {', '.join(menus) or 'none'}")
    print(f"reference: label {label!r}, action {action!r} (from {HOME})")
    if len(menus) < 3:
        findings.append(
            f"only {len(menus)} agent menu(s) found, expected at least 3 "
            "(menu.rs, strip.rs, ctxmenu.rs): the shield row moved or the scan is blind"
        )
    for x in findings:
        print(f"FAIL: {x}")
    if findings:
        return 1
    print("OK: the worker-mentions row is in every agent menu, spelled as the reference")
    return 0


if __name__ == "__main__":
    sys.exit(main())
