#!/usr/bin/env python3
"""Every menu that has "Keep Agents Out of This Terminal" has "Don't Start
Workers in This Terminal" right after it -- on macOS and on Windows.

# Why (task 1699)

The two are one family: the shield keeps every agent out, the workers mark
keeps agents from being *started* in a terminal the user keeps for their own
commands. The user ruled that wherever the first is offered the second is
offered beside it, in both hosts. A row that went into two menus of three
goes unnoticed: nothing else compares the menus (the role submenu did exactly
this once, which is why `the-role-submenu-is-wherever-the-agent-rows-are.py`
exists).

# What is checked

**Default-include: the shield row decides which files are menus.** A file is
a menu with the agent rows because its code -- comments and Rust
`#[cfg(test)]` modules stripped -- carries the shield row:

  * macOS Swift (`macos/Sources`): `#selector(...poltergeistToggleShielded(_:))`.
    The next `#selector(` in the file must be
    `...poltergeistToggleWorkersRefused(_:)`. That covers the menus that
    build their rows in code and the menu bar's ticks (`validateMenuItem`).
  * macOS menu bar (`MainMenu.xib`): the `<menuItem>` whose action is
    `poltergeistToggleShielded:` must be followed directly by the one whose
    action is `poltergeistToggleWorkersRefused:`.
  * Windows (`windows/host/src/*.rs`): the binding string
    `"poltergeist_toggle_shielded"`. The next `"poltergeist_` string after it
    must be `"poltergeist_toggle_workers_refused"`.

Fewer than three menus found on either host is a finding: a check whose
subject has vanished would otherwise pass.

# NOT CHECKED

  * Whether the row is drawn, ticked or does anything: this reads source.
  * The label's spelling (the menus' translations are checked elsewhere).
  * GTK.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MAC = os.path.join(ROOT, "macos", "Sources")
XIB = os.path.join(MAC, "App", "Base.lproj", "MainMenu.xib")
WIN = os.path.join(ROOT, "windows", "host", "src")


def strip_comments(text):
    """Drop `//` comments, leaving string literals (Swift and Rust alike)."""
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


def followed(code, item, shield, workers, where):
    """Each match of `shield` must have `workers` as the next match of `item`."""
    found = []
    items = list(re.finditer(item, code))
    for n, m in enumerate(items):
        if not re.fullmatch(shield, m.group(0)):
            continue
        line = code.count("\n", 0, m.start()) + 1
        nxt = items[n + 1].group(0) if n + 1 < len(items) else None
        if nxt is None or not re.fullmatch(workers, nxt):
            found.append(f"{where}:{line}: the shield row is not followed by the workers row (next: {nxt or 'nothing'})")
    return found


def mac():
    findings, menus = [], []
    for dirpath, _, files in os.walk(MAC):
        for f in sorted(files):
            if not f.endswith(".swift"):
                continue
            path = os.path.join(dirpath, f)
            with open(path, encoding="utf-8") as fh:
                code = strip_comments(fh.read())
            if not re.search(r"#selector\((\w+\.)?poltergeistToggleShielded\(_:\)\)", code):
                continue
            rel = os.path.relpath(path, ROOT)
            menus.append(rel)
            findings += followed(code, r"#selector\([\w.]+\(_:\)\)",
                                 r"#selector\((\w+\.)?poltergeistToggleShielded\(_:\)\)",
                                 r"#selector\((\w+\.)?poltergeistToggleWorkersRefused\(_:\)\)", rel)
    if os.path.exists(XIB):
        with open(XIB, encoding="utf-8") as fh:
            xib = fh.read()
        rel = os.path.relpath(XIB, ROOT)
        if 'selector="poltergeistToggleShielded:"' in xib:
            menus.append(rel)
            findings += followed(xib, r'<action selector="\w+:"',
                                 r'<action selector="poltergeistToggleShielded:"',
                                 r'<action selector="poltergeistToggleWorkersRefused:"', rel)
    return findings, menus


def windows():
    findings, menus = [], []
    if not os.path.isdir(WIN):
        return [f"{WIN} does not exist -- nothing to scan"], menus
    for f in sorted(os.listdir(WIN)):
        if not f.endswith(".rs"):
            continue
        with open(os.path.join(WIN, f), encoding="utf-8") as fh:
            code = strip_test_modules(strip_comments(fh.read()))
        if '"poltergeist_toggle_shielded"' not in code:
            continue
        rel = os.path.relpath(os.path.join(WIN, f), ROOT)
        menus.append(rel)
        findings += followed(code, r'"poltergeist_\w+"', r'"poltergeist_toggle_shielded"',
                             r'"poltergeist_toggle_workers_refused"', rel)
    return findings, menus


def main():
    findings = []
    for host, scan in (("macOS", mac), ("Windows", windows)):
        found, menus = scan()
        print(f"{host}: menus with the shield row: {', '.join(menus) or 'none'}")
        findings += found
        if len(menus) < 3:
            findings.append(f"{host}: only {len(menus)} menu(s) with the shield row found, expected at least 3: "
                            "the row moved or the scan is blind")
    for x in findings:
        print(f"FAIL: {x}")
    if findings:
        return 1
    print("OK: the workers row follows the shield row in every menu of both hosts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
