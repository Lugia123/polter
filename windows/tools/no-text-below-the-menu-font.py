#!/usr/bin/env python3
"""Windows: the settings and project windows make their fonts in one place, and it has a floor.

**The rule** (dev-docs/poltergeist/settings.md §2.3b, the user's own): no
text in the settings window or the project windows is smaller than the
system's menu font -- `lfMenuFont` of `NONCLIENTMETRICSW`, asked for at the
window's DPI, never a number written here.

**How that is held.** A size cannot be checked by reading: the menu font's
is only known on the machine, and it moves with Settings > Accessibility >
Text size. So this checks the thing that *can* be read -- that there is only
one way to make a font:

  1. `host/src/uifont.rs` is the only file among these windows that calls
     `CreateFontW` (once), and it gets the height from
     `polter_settings_shell::text_px(.., menu_px(dpi))`, where `menu_px`
     reads `lfMenuFont` through `SystemParametersInfoForDpi`;
  2. `text_px` in `settings-shell/src/lib.rs` ends in `.max(menu_px)`. Its
     arithmetic is tested there (`cargo test -p polter-settings-shell
     text_`), which `pure-crates-pass-their-tests.py` runs;
  3. no other file in scope calls `CreateFontW` / `CreateFontIndirectW`, or
     takes a stock font (`DEFAULT_GUI_FONT` is 11 px at every DPI; this is
     what the rename box was drawn in).

**In scope: every `host/src/*.rs` that is not named below.** A new window is
covered the day it is added, without anybody remembering this file.

# What this cannot see

  * **A control that was never sent `WM_SETFONT`.** An `EDIT` or `BUTTON`
    with no font is drawn in the system font, which does not scale with DPI.
    Nothing textual separates "set three lines later" from "never set".
  * **Text the system draws**: `TaskDialogIndirect`, `MessageBoxW`. They use
    the system's message font, which the same Text size setting moves.
  * **Whether a row is tall enough** for the text it now holds when Text
    size is turned up. The rows are laid out in DPI-scaled pixels, not in
    text heights; that is a real-machine check, and settings.md says so.
  * **The windows named in `NOT_THESE_WINDOWS`**, which draw over the
    terminal and were outside the task this rule came from.

Run:  python3 windows/tools/no-text-below-the-menu-font.py
Exit: 0 when the one source is intact and nothing in scope goes around it.
"""

import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "host", "src")
SHELL = os.path.join(HERE, "..", "settings-shell", "src", "lib.rs")
THE_SOURCE = "uifont.rs"

# Not the settings window and not a project window: each of these draws on
# top of a terminal (HUD, pending-key sign, command palette, search bar, tab
# strip), or on top of the whole screen (`shot.rs`, the screenshot overlay,
# whose text is drawn into the picture at sizes the person picks). The rule
# was given for the windows below, and these were left as they are rather
# than changed unseen. **Not a list to add a settings file
# to**: a file that makes text for the windows in `THESE_WINDOWS` belongs in
# scope.
NOT_THESE_WINDOWS = {"hud.rs", "keyseq.rs", "palette.rs", "search.rs", "shot.rs", "strip.rs"}

# The windows the rule names. They have to be found: if one was renamed, the
# scan is no longer looking at what this file says it is about.
THESE_WINDOWS = {
    "settings_win.rs", "general_ui.rs", "plugins_ui.rs", "projects_ui.rs",
    "roles_ui.rs", "project_picker.rs", "prompt.rs",
}

GOES_AROUND = re.compile(
    r"\b(CreateFontW|CreateFontIndirectW|CreateFontIndirectExW|DEFAULT_GUI_FONT|SYSTEM_FONT|"
    r"SYSTEM_FIXED_FONT|ANSI_VAR_FONT|ANSI_FIXED_FONT|OEM_FIXED_FONT|DEVICE_DEFAULT_FONT)\b")


def code(src: str) -> str:
    """The source with `//` comments blanked, line numbers kept."""
    out = []
    for line in src.split("\n"):
        cut = line.find("//")
        out.append(line[:cut] if cut >= 0 else line)
    return "\n".join(out)


def read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return code(fh.read())


def main() -> int:
    files = sorted(glob.glob(os.path.join(SRC, "*.rs")))
    names = {os.path.basename(p) for p in files}
    missing = sorted((THESE_WINDOWS | {THE_SOURCE}) - names)
    if missing:
        print(f"FAIL: not found under windows/host/src: {', '.join(missing)} -- the windows this is about were not scanned")
        return 1
    if not os.path.isfile(SHELL):
        print("FAIL: windows/settings-shell/src/lib.rs is missing")
        return 1

    bad = 0

    source = read(os.path.join(SRC, THE_SOURCE))
    made = len(re.findall(r"\bCreateFontW\(", source))
    if made != 1:
        print(f"FAIL: uifont.rs calls CreateFontW {made} times; one font-maker is the point")
        bad += 1
    for needle, why in [
        ("SystemParametersInfoForDpi(", "the menu font is asked for at the window's DPI"),
        ("lfMenuFont", "the floor is the menu font"),
        ("polter_settings_shell::text_px(", "the height goes through the tested floor"),
    ]:
        if needle not in source:
            print(f"FAIL: uifont.rs no longer contains `{needle}` -- {why}")
            bad += 1
    m = re.search(r"CreateFontW\(\s*([^,]+),", source)
    if m and re.search(r"\d", m.group(1)):
        print(f"FAIL: uifont.rs passes CreateFontW a height with a number in it (`{m.group(1).strip()}`)")
        bad += 1

    shell = read(SHELL)
    fn = re.search(r"pub fn text_px\([^)]*\)\s*->\s*i32\s*\{(.*?)\n\}", shell, re.S)
    if not fn:
        print("FAIL: polter_settings_shell::text_px was not found")
        bad += 1
    elif ".max(menu_px)" not in fn.group(1):
        print("FAIL: polter_settings_shell::text_px no longer ends in .max(menu_px) -- the floor is gone")
        bad += 1

    scanned = 0
    for path in files:
        name = os.path.basename(path)
        if name == THE_SOURCE or name in NOT_THESE_WINDOWS:
            continue
        scanned += 1
        for i, line in enumerate(read(path).split("\n")):
            for hit in GOES_AROUND.finditer(line):
                print(f"windows/host/src/{name}:{i + 1}: {hit.group(1)} -- a font made or taken outside uifont.rs")
                bad += 1

    print(f"scanned {scanned} host sources ({len(THESE_WINDOWS)} named windows among them, {len(NOT_THESE_WINDOWS)} left out by name); {bad} problems")
    if scanned == 0:
        print("FAIL: nothing was scanned")
        return 1
    if bad:
        print("FAIL: make the font with crate::uifont::make (settings.md §2.3b)")
        return 1
    print("OK: one font-maker, floored at the menu font, and nothing in scope goes around it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
