#!/usr/bin/env python3
"""Windows: the settings window's grid is the macOS one, value for value.

**Why.** Both hosts lay the settings window out on one grid (settings.md
§2.3a): the bands, the columns, the padding, the gaps. The numbers are
written twice -- `macos/Sources/Features/Settings/SettingsLayout.swift` and
the `grid` module of `windows/settings-shell/src/lib.rs` -- and the comment
on each says the other has "the same names and values". Nothing held them
to it (the mac-win parity audit, task 1548), so a change on one side would
leave the two windows a few pixels apart with nothing to say so. Task 1550
added this.

**What is compared**, macOS name = Windows name:

    top = TOP, bottom = BOTTOM, sidebar = SIDEBAR, list = LIST,
    control = CONTROL_H, pad = PAD, rowGap = ROW_GAP, groupGap = GROUP_GAP,
    label = LABEL_W, labelGap = LABEL_GAP, padSidebar = PAD_SIDEBAR

and the sidebar row: its highlight is a control high (`SECTION_ROW_H` =
`control`, the macOS `SettingsRow`'s `minHeight`) with round corners of the
radius the `SettingsRow` draws (`cornerRadius: 6` = `SECTION_ROW_RADIUS`).

**Fails on empty**: either file missing, or any name not found in it, is a
FAIL, not a pass with fewer comparisons.

# What this cannot see

  * Whether the views place themselves *on* these numbers. Each side has its
    own tests for that (`SettingsLayoutTests`, the settings-shell tests).
  * The 2-point gap between sidebar rows: macOS gets it from the list's own
    spacing, which no constant names.

Run:  python3 windows/tools/settings-grid-is-the-macos-grid.py
Exit: 0 when every pair is equal.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
SWIFT = os.path.join(ROOT, "macos", "Sources", "Features", "Settings", "SettingsLayout.swift")
SWIFT_ROW = os.path.join(ROOT, "macos", "Sources", "Features", "Settings", "SettingsRootView.swift")
RUST = os.path.join(ROOT, "windows", "settings-shell", "src", "lib.rs")

PAIRS = [
    ("top", "TOP"),
    ("bottom", "BOTTOM"),
    ("sidebar", "SIDEBAR"),
    ("list", "LIST"),
    ("control", "CONTROL_H"),
    ("pad", "PAD"),
    ("rowGap", "ROW_GAP"),
    ("groupGap", "GROUP_GAP"),
    ("label", "LABEL_W"),
    ("labelGap", "LABEL_GAP"),
    ("padSidebar", "PAD_SIDEBAR"),
]


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        print(f"FAIL: cannot read {os.path.relpath(path, ROOT)}: {e}")
        sys.exit(1)


def main():
    swift = read(SWIFT)
    row = read(SWIFT_ROW)
    rust = read(RUST)
    grid = re.search(r"pub mod grid \{(.*?)\n\}", rust, re.S)
    if not grid:
        print("FAIL: no `pub mod grid` in windows/settings-shell/src/lib.rs")
        return 1
    grid = grid.group(1)

    def mac(name):
        m = re.search(r"static let " + re.escape(name) + r": CGFloat = (\d+)\b", swift)
        return int(m.group(1)) if m else None

    def win(name):
        m = re.search(r"pub const " + re.escape(name) + r": i32 = (\d+);", grid)
        return int(m.group(1)) if m else None

    bad = []
    compared = 0
    for m_name, w_name in PAIRS:
        a, b = mac(m_name), win(w_name)
        if a is None or b is None:
            bad.append(f"{m_name} / {w_name}: not found ({'macOS' if a is None else 'Windows'} side)")
            continue
        compared += 1
        if a != b:
            bad.append(f"{m_name} = {a} on macOS, {w_name} = {b} on Windows")

    # The sidebar row.
    row_h, radius = win("SECTION_ROW_H"), win("SECTION_ROW_RADIUS")
    settings_row = re.search(r"struct SettingsRow<.*?\n\}", row, re.S)
    mac_radius = re.search(r"cornerRadius: (\d+)", settings_row.group(0)) if settings_row else None
    if row_h is None or radius is None or mac_radius is None:
        bad.append("the sidebar row: SECTION_ROW_H / SECTION_ROW_RADIUS / SettingsRow's cornerRadius not found")
    else:
        compared += 2
        if row_h != mac("control"):
            bad.append(f"SECTION_ROW_H = {row_h}, but a macOS SettingsRow is `control` = {mac('control')} high")
        if radius != int(mac_radius.group(1)):
            bad.append(f"SECTION_ROW_RADIUS = {radius}, but SettingsRow's corners are {mac_radius.group(1)}")

    if compared == 0:
        print("FAIL: compared nothing")
        return 1
    if bad:
        print(f"FAIL: the settings grids differ ({len(bad)} of {len(PAIRS) + 2}):")
        for b in bad:
            print(f"  {b}")
        return 1
    print(f"OK: {compared} settings grid values are the same on macOS and Windows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
