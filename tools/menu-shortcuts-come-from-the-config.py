#!/usr/bin/env python3
r"""A menu item whose shortcut is synced from the config has none in the xib.

# Why this exists

`AppDelegate.syncMenuShortcuts` gives every menu item it lists its shortcut
at runtime, from the config's keybinds, at launch and on every reload --
and when the config has no shortcut it can show for that action, it
*clears* the item's `keyEquivalent`. So a `keyEquivalent` written into
`MainMenu.xib` on one of those items never takes effect: it is overwritten
by the config's, or wiped.

That is a silent failure with a long way round. Issue #30 was first
diagnosed as "the xib is missing ⌘V" -- the missing attribute was the
*result* of the wipe, not its cause -- and adding it would have changed
nothing at all. This gate makes the next person hear about it at the line
they wrote, with the reason, instead of finding out an evening later.

# What it checks

Every `syncMenuShortcut(config, action: "...", menuItem: self.X)` in
`AppDelegate.swift`: that outlet `X` exists in the xib, and that the menu
item it points at carries no non-empty `keyEquivalent`.

Only the key counts. Interface Builder writes an empty
`<modifierMask key="keyEquivalentModifierMask"/>` into most items, and a
mask with no key is no shortcut; this gate's first draft read that element
as one and flagged fifty items that have none.

# NOT CHECKED

- **Which items are synced is read from source text.** The list is the
  calls this finds, not whatever `syncMenuShortcuts` really does at
  runtime. To keep that reader from going blind quietly, the number of
  literal calls must equal the number parsed, and must not be zero -- a
  call written another way (a variable action, a helper) is reported rather
  than skipped. A call that bypasses `syncMenuShortcut` entirely is not
  seen at all.
- Menu items that are not synced may carry a `keyEquivalent`; those do take
  effect, and are not this gate's business.
- Whether the config's shortcut is the one anybody wants on the menu.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DELEGATE = "macos/Sources/App/AppDelegate.swift"
XIB = "macos/Sources/App/Base.lproj/MainMenu.xib"

LITERAL_CALL = re.compile(r'\bsyncMenuShortcut\(config, action: "')
PAIR = re.compile(r'\bsyncMenuShortcut\(config, action: "([^"]+)", menuItem: self\.(\w+)\)')
OUTLET = re.compile(r'<outlet property="(\w+)" destination="([\w-]+)"')


def menu_item_tag(xib, item_id):
    """The opening tag of the menuItem with this id, or None."""
    m = re.search(r'<menuItem\b[^>]*\bid="' + re.escape(item_id) + r'"[^>]*>', xib)
    return m.group(0) if m else None


def line_of(xib, needle):
    return xib[:xib.index(needle)].count("\n") + 1


def main():
    delegate = (ROOT / DELEGATE).read_text(encoding="utf-8")
    xib = (ROOT / XIB).read_text(encoding="utf-8")

    problems = []
    literal = len(LITERAL_CALL.findall(delegate))
    pairs = PAIR.findall(delegate)
    if not pairs:
        problems.append(f"{DELEGATE}: found no syncMenuShortcut(config, action: \"...\", menuItem: self.X) calls -- the reader has gone blind")
    if literal != len(pairs):
        problems.append(f"{DELEGATE}: {literal} literal syncMenuShortcut calls but {len(pairs)} parsed -- one is written in a shape this gate doesn't read")

    outlets = dict(OUTLET.findall(xib))
    for action, outlet in pairs:
        item_id = outlets.get(outlet)
        if item_id is None:
            problems.append(f"{XIB}: no outlet '{outlet}' (synced for '{action}')")
            continue
        tag = menu_item_tag(xib, item_id)
        if tag is None:
            problems.append(f"{XIB}: outlet '{outlet}' points at '{item_id}', which is not a menuItem")
            continue
        key = re.search(r'keyEquivalent="([^"]*)"', tag)
        if key and key.group(1):
            problems.append(
                f"{XIB}:{line_of(xib, tag)}: '{action}' ({outlet}) has a shortcut in the xib -- "
                f"syncMenuShortcut sets this item's shortcut from the config at launch and wipes it when "
                f"the config has none it can show, so this never takes effect. Bind it in the config "
                f"(src/config/Config.zig Keybinds.init) instead.")

    if problems:
        print("FAIL: a shortcut written in the xib would be silently replaced at runtime:")
        for p in problems:
            print(f"      {p}")
        return 1

    print(f"{len(pairs)} synced menu items checked in {XIB}: none carries a shortcut of its own.")
    print("NOT CHECKED: items synced some other way than a literal syncMenuShortcut call; unsynced items.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
