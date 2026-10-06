#!/usr/bin/env python3
"""macOS: no text in the settings and project windows is set smaller than a menu item.

**The rule** (dev-docs/poltergeist/settings.md §2.3b, the user's own): the
smallest text in the settings window -- every section of it -- and in the
project windows (Save as Project, Load Project, the ask before closing) is
the size of the system's menu font. Not "about 13": whatever
`NSFont.menuFont(ofSize: 0).pointSize` answers on the machine it runs on.

**Why a gate and not a review.** Before this, 67 places in these four
directories were set in `.caption` (10 pt), `.caption2` (10), `.subheadline`
(11), `.callout` (12) or a literal `size: 12`, against a menu font of 13.
Each one was a reasonable-looking line; `.caption` under a control is what
SwiftUI's own samples do. The next one will look just as reasonable, so the
smaller styles are refused here by name, and there is one thing to write
instead: `SettingsFont.minimum` (or `.minimumMonospaced`).

What is refused, in `macos/Sources/Features/{Settings,Projects,Roles,Plugins}`:

  1. the text styles smaller than the menu font: `.caption`, `.caption2`,
     `.footnote`, `.subheadline`, `.callout`;
  2. a font size written as a number: `.system(size: 12)`, `ofSize: 11`,
     `withSize(10)` (`ofSize: 0` is how AppKit is asked for a font's own
     default, and is the one number allowed);
  3. AppKit's small sizes by name: `smallSystemFontSize`, `labelFontSize`;
  4. `.controlSize(.small)` / `.controlSize(.mini)`, which shrink a control's
     text with it -- except on a line that is a bare `ProgressView()`, or
     where the next line is `.labelsHidden()`: neither has text to shrink.

And `SettingsFont` itself must take its size from `NSFont.menuFont(ofSize: 0)`
and contain no number of its own.

# What this cannot see

  * **Text the system draws**: an `NSAlert`'s message and informative text,
    tooltips (`.help`), an `NSSavePanel`. Measured on the machine this was
    written on (Darwin 25.5), an `NSAlert` sets all of its text and buttons
    at 13 pt, the menu font's size; older systems were not measured.
  * **Whether a larger style is really larger.** `.body` and `.headline` are
    13 pt on macOS, equal to the menu font, and are let through by name. If
    a future system made the menu font larger than `.body`, this gate would
    stay green and be wrong.
  * **A scale applied after the font**: `.scaleEffect`, `.minimumScaleFactor`
    are not looked for (none exists in these directories today).
  * **A view outside these four directories** that a settings section embeds.
  * **Whether the text fits** once it is larger. That is a screenshot's job
    (settings.md §2.3a), not this file's.

Run:  python3 tools/no-text-below-the-menu-font.py
Exit: 0 when nothing in scope is set below the menu font, 1 otherwise.
"""

import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FEATURES = os.path.join(HERE, "..", "macos", "Sources", "Features")
DIRS = ("Settings", "Projects", "Roles", "Plugins")
SOURCE = os.path.join(FEATURES, "Settings", "SettingsFont.swift")

SMALL_STYLE = re.compile(r"\.(caption2|caption|footnote|subheadline|callout)\b")
LITERAL_SIZE = re.compile(r"\b(?:size|ofSize|fixedSize)\s*:\s*(\d+(?:\.\d+)?)|\bwithSize\(\s*(\d+(?:\.\d+)?)")
SMALL_NAME = re.compile(r"\b(smallSystemFontSize|labelFontSize)\b")
SMALL_CONTROL = re.compile(r"\.controlSize\(\s*\.(small|mini)\s*\)")


def code(line: str) -> str:
    """The line without its `//` comment."""
    cut = line.find("//")
    return line[:cut] if cut >= 0 else line


def scan(path: str):
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    hits = []
    for i, raw in enumerate(lines):
        line = code(raw)
        for m in SMALL_STYLE.finditer(line):
            hits.append((i + 1, f"text style .{m.group(1)} is smaller than the menu font"))
        for m in LITERAL_SIZE.finditer(line):
            number = m.group(1) or m.group(2)
            if "Font" not in line and "font" not in line and ".system(" not in line:
                continue
            if float(number) != 0:
                hits.append((i + 1, f"a font size written as a number ({number})"))
        for m in SMALL_NAME.finditer(line):
            hits.append((i + 1, f"NSFont.{m.group(1)} is smaller than the menu font"))
        for m in SMALL_CONTROL.finditer(line):
            following = next((code(l).strip() for l in lines[i + 1:] if l.strip()), "")
            if "ProgressView()" in line or following.startswith(".labelsHidden()"):
                continue
            hits.append((i + 1, f".controlSize(.{m.group(1)}) shrinks the control's text"))
    return hits


def main() -> int:
    files = []
    for d in DIRS:
        found = sorted(glob.glob(os.path.join(FEATURES, d, "*.swift")))
        if not found:
            print(f"FAIL: no .swift files under macos/Sources/Features/{d} -- nothing was checked there")
            return 1
        files += found

    if not os.path.isfile(SOURCE):
        print("FAIL: macos/Sources/Features/Settings/SettingsFont.swift is missing -- the one source of the smallest size")
        return 1
    with open(SOURCE, encoding="utf-8") as fh:
        source = "\n".join(code(l) for l in fh.read().split("\n"))
    bad = 0
    if "NSFont.menuFont(ofSize: 0).pointSize" not in source:
        print("FAIL: SettingsFont does not take its size from NSFont.menuFont(ofSize: 0).pointSize")
        bad += 1

    uses = 0
    for path in files:
        rel = os.path.relpath(path, os.path.join(HERE, ".."))
        with open(path, encoding="utf-8") as fh:
            uses += len(re.findall(r"\bSettingsFont\.minimum", "\n".join(code(l) for l in fh.read().split("\n"))))
        for line, what in scan(path):
            print(f"{rel}:{line}: {what}")
            bad += 1

    print(f"scanned {len(files)} swift files in {len(DIRS)} directories; {uses} uses of SettingsFont.minimum*; {bad} below the menu font")
    if uses == 0:
        print("FAIL: nothing in scope uses SettingsFont -- the scan is not looking at the windows it is about")
        return 1
    if bad:
        print("FAIL: set these in SettingsFont.minimum / .minimumMonospaced (settings.md §2.3b)")
        return 1
    print("OK: no text in the settings and project windows is set below the menu font")
    return 0


if __name__ == "__main__":
    sys.exit(main())
