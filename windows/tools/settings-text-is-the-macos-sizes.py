#!/usr/bin/env python3
"""Windows: the settings and project windows set their text in the system's
faces at the macOS sizes, from one table.

**The rule** (task 1550, the mac/Windows parity decision 3): the interface
face is the system's message font (`uifont::ui_face`, Microsoft YaHei UI on a
Chinese Windows, Segoe UI on an English one), the fixed-width face is
`uifont::mono_face`, and the sizes are the macOS window's -- body 13,
headings 13 semibold, the About name 17 -- written once, in
`polter_settings_shell::type_size`.

It had been Segoe UI written by name in each window at 14 and 15, and
Consolas at 12 or 13: on a Chinese machine the Latin letters were Segoe's
and the Chinese ones a linked face's, so a number inside a sentence read a
size smaller than the words round it (task 1541, seen in the control room).

**Checked, in the files named in `SCOPE`:**

  1. no face is written by name -- no `w!("Segoe UI")`, `w!("Consolas")`,
     `w!("Cascadia Mono")`;
  2. every font is made through `uifont::ui(dpi, SIZE, ..)`, `uifont::mono`,
     `make_font(dpi, SIZE, ..)` (a file's own wrapper over `uifont::ui`) or
     `uifont::make(dpi, SIZE, ..)`, and SIZE is `type_size::…` or the
     wrapper's own parameter `px` -- **never a number**;
  3. `type_size` holds BODY 13, HEADING 13, TITLE 17, MONO 13.

**Fails on empty**: a scope file missing, or no font call found in all of
them, is a FAIL.

# What this cannot see

  * The icon font (`uifont::icon_face`), which is not text.
  * Text the system draws (`TaskDialogIndirect`), in the system's font.
  * Whether the menu-font floor holds -- `no-text-below-the-menu-font.py`.

Run:  python3 windows/tools/settings-text-is-the-macos-sizes.py
Exit: 0 when every font in scope comes from the table.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "host", "src")
SHELL = os.path.join(HERE, "..", "settings-shell", "src", "lib.rs")

# The settings window and its sections, and the project windows.
SCOPE = [
    "settings_win.rs",
    "general_ui.rs",
    "roles_ui.rs",
    "plugins_ui.rs",
    "projects_ui.rs",
    "project_picker.rs",
    "logs_ui.rs",
]

FACE_BY_NAME = re.compile(r'w!\("(Segoe UI|Consolas|Cascadia Mono)"\)')
# A font made with a size: the size is the second argument.
CALL = re.compile(r"\b(?:uifont::ui|uifont::make|make_font)\(\s*[A-Za-z_][\w.]*\s*,\s*([^,()]+)")
WANT = {"BODY": 13, "HEADING": 13, "TITLE": 17, "MONO": 13}


def strip_comments(text):
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


def main():
    bad = []
    calls = 0
    for name in SCOPE:
        path = os.path.join(SRC, name)
        try:
            with open(path, encoding="utf-8") as f:
                text = strip_comments(f.read())
        except OSError as e:
            print(f"FAIL: cannot read host/src/{name}: {e}")
            return 1
        for m in FACE_BY_NAME.finditer(text):
            line = text.count("\n", 0, m.start()) + 1
            bad.append(f"host/src/{name}:{line}: a face by name, {m.group(0)} -- use uifont::ui_face / mono_face")
        for m in CALL.finditer(text):
            # The wrappers' own definitions name their parameter, not a size.
            before = text[max(0, m.start() - 3):m.start()]
            if before.endswith("fn "):
                continue
            calls += 1
            size = m.group(1).strip()
            if size == "px" or "type_size::" in size:
                continue
            line = text.count("\n", 0, m.start()) + 1
            bad.append(f"host/src/{name}:{line}: a font at `{size}` -- the size comes from polter_settings_shell::type_size")
    if calls == 0:
        print("FAIL: found no font made in the settings or project windows")
        return 1

    try:
        with open(SHELL, encoding="utf-8") as f:
            shell = f.read()
    except OSError as e:
        print(f"FAIL: cannot read settings-shell/src/lib.rs: {e}")
        return 1
    table = re.search(r"pub mod type_size \{(.*?)\n\}", shell, re.S)
    if not table:
        bad.append("settings-shell/src/lib.rs: no `pub mod type_size`")
    else:
        for k, v in WANT.items():
            m = re.search(r"pub const " + k + r": i32 = (\d+);", table.group(1))
            if not m:
                bad.append(f"type_size::{k} is missing")
            elif int(m.group(1)) != v:
                bad.append(f"type_size::{k} = {m.group(1)}, the macOS size is {v}")

    if bad:
        print(f"FAIL: {len(bad)} font(s) not from the table:")
        for b in bad:
            print(f"  {b}")
        return 1
    print(f"OK: {calls} fonts in {len(SCOPE)} files take the system's faces at the macOS sizes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
