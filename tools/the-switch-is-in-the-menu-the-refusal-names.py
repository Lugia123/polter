#!/usr/bin/env python3
"""A refusal that names a menu names one the switch is actually in.

# The defect this is the floor for

`AuthoriseOff` told the user, word for word, that the switch is off *until
they switch it on from that terminal's own tab menu*. The tab strip's
right-click menu has nine rows and **that is not one of them** -- measured on
the machine by pulling the popup's whole structure tree. The switch lives in
the terminal's own right-click menu and in the app menu.

Nothing was broken. The sentence simply sent the person to a menu with no
switch in it, **at the moment they most needed to find it** -- their worker
was stopped on a prompt, which is why they were reading a refusal at all.

⚠️ And it was three sentences, not one: the same claim was in the tool
descriptions and in two shipped skills, because they were written from each
other.

# What is checked

The claim and the menus, in that order:

  1. **Collect every place that says where the switch is** -- the `AuthoriseOff`
     text, the tool descriptions, the skills.
  2. **Whichever menu they name must contain it.** Naming the *tab* menu
     requires `TabCmd::MayAuthorise`-style row in the strip's `TAB_MENU`;
     naming the terminal's own right-click menu requires the item in
     `ctxmenu.rs` **and** in the macOS surface menu, since the sentence is
     read on both platforms.

⚠️ **Default-include**: a new sentence that names a menu is checked because it
names one, not because it was added to a list here.

# NOT CHECKED

  * **Whether the item is reachable** -- that it is drawn, enabled, and does
    something. This reads menu definitions, not a running program. WT read the
    real popup once; that is a reading, not a floor.
  * **Menus this port does not define in these files** (GTK has neither the
    switch nor a menu for it -- a named gap, not an oversight).
  * **Wording quality.** A sentence naming the right menu badly passes here.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")

CLAIMS = [
    "src/poltergeist/rpc.zig",
    "src/cli/mcp.zig",
    "src/poltergeist/skills/supervising.md",
    "src/poltergeist/skills/reading-a-terminal.md",
]
STRIP = "windows/host/src/strip.rs"
CTXMENU = "windows/host/src/ctxmenu.rs"
MACSURFACE = "macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift"

# "... own tab menu" and "... own right-click menu", in either spelling, and
# tolerant of the line break a `++` chain or a wrapped paragraph puts in.
TAB_CLAIM = re.compile(r"own\s+(?:\"\s*\+\+\s*\n\s*\")?tab\s*(?:\"\s*\+\+\s*\n\s*\")?menu", re.I)
CTX_CLAIM = re.compile(r"own\s+(?:\"\s*\+\+\s*\n\s*\")?right-click\s*(?:\"\s*\+\+\s*\n\s*\")?menu", re.I)

# What each menu must contain for the corresponding claim to be true.
IN_TAB_MENU = re.compile(r"TAB_MENU[^;]*MayAuthorise", re.S)
IN_CTXMENU = re.compile(r"poltergeist_toggle_authorise")
IN_MAC_SURFACE = re.compile(r"poltergeistToggleAuthorise")


def findings(sources):
    out = []
    claims_tab = []
    claims_ctx = []
    for name in CLAIMS:
        src = sources.get(name, "")
        if TAB_CLAIM.search(src):
            claims_tab.append(name)
        if CTX_CLAIM.search(src):
            claims_ctx.append(name)

    if not claims_tab and not claims_ctx:
        out.append(
            "nothing says where the switch is any more. The refusal is the only place a "
            "person finds out, so saying nothing is its own defect -- and it would make "
            "every check below pass by having nothing to check"
        )

    if claims_tab and not IN_TAB_MENU.search(sources.get(STRIP, "")):
        out.append(
            "the refusal sends the user to that terminal's tab menu, and the tab strip's "
            f"menu has no such row ({', '.join(claims_tab)}). The person reading this has a "
            "worker stopped on a prompt; the sentence hands them a menu with no switch in it"
        )
    if claims_ctx:
        if not IN_CTXMENU.search(sources.get(CTXMENU, "")):
            out.append(
                "the refusal sends the user to the terminal's own right-click menu, and the "
                "Windows context menu does not have the item"
            )
        if not IN_MAC_SURFACE.search(sources.get(MACSURFACE, "")):
            out.append(
                "the refusal sends the user to the terminal's own right-click menu, and the "
                "macOS surface menu does not have the item. The same sentence is read on "
                "both platforms, so it has to be true on both"
            )
    return out


GOOD = {
    "src/poltergeist/rpc.zig": 'switch it on from that terminal\'s own right-click menu, or the app menu',
    "src/cli/mcp.zig": "from that terminal's own right-click menu",
    "src/poltergeist/skills/supervising.md": "from that terminal's own right-click menu",
    "src/poltergeist/skills/reading-a-terminal.md": "its own right-click menu",
    STRIP: "const TAB_MENU: &[Option<TabCmd>] = &[ Some(TabCmd::Shield) ];",
    CTXMENU: 'checkable("…", "poltergeist_toggle_authorise", Tick::PgMayAuthorise)',
    MACSURFACE: "@objc func poltergeistToggleAuthorise(_ sender: Any) {}",
}


def self_test():
    def case(**over):
        s = dict(GOOD)
        s.update(over)
        return s

    cases = [
        ("the shape today", case(), 0),
        # The decoy is the sentence as it actually stood, wrapped the way the
        # `++` chain wrapped it.
        ("the tab menu named, as it stood",
         case(**{"src/poltergeist/rpc.zig":
                 'It is off until they switch it on from that " ++\n "terminal\'s own tab menu, and'}), 1),
        ("the tab menu named and the row really there",
         case(**{"src/poltergeist/rpc.zig": "from that terminal's own tab menu",
                 STRIP: "const TAB_MENU: &[Option<TabCmd>] = &[ Some(TabCmd::MayAuthorise) ];"}), 0),
        ("right-click named, Windows item gone",
         case(**{CTXMENU: "checkable(\"…\", \"poltergeist_toggle_shielded\", Tick::PgShield)"}), 1),
        ("right-click named, macOS item gone",
         case(**{MACSURFACE: "// nothing here"}), 1),
        ("nobody says where it is",
         case(**{"src/poltergeist/rpc.zig": "the user has not allowed it",
                 "src/cli/mcp.zig": "refused with AuthoriseOff",
                 "src/poltergeist/skills/supervising.md": "a switch you cannot set",
                 "src/poltergeist/skills/reading-a-terminal.md": "a switch you cannot set"}), 1),
    ]
    ok = True
    for what, sources, want in cases:
        got = findings(sources)
        if len(got) != want:
            print(f"probe self-test FAILED: {what} gave {len(got)} finding(s), expected {want}:")
            for f in got:
                print(f"    {f}")
            ok = False
    if ok:
        print("probe self-test: OK (the tab menu named while absent, named while present, "
              "each platform's item gone, and nobody saying where it is)")
    return ok


def main():
    if not self_test():
        return 1
    sources = {}
    for name in CLAIMS + [STRIP, CTXMENU, MACSURFACE]:
        try:
            with open(os.path.join(ROOT, name), encoding="utf-8") as fh:
                sources[name] = fh.read()
        except OSError as e:
            print(f"cannot read {name}: {e}")
            return 1

    named = [n for n in CLAIMS if CTX_CLAIM.search(sources[n]) or TAB_CLAIM.search(sources[n])]
    print(f"{len(named)} place(s) say where the switch is: {', '.join(named)}")
    print("NOT CHECKED: whether the item is drawn, enabled, and works -- this reads menu "
          "definitions, not a running program.")
    found = findings(sources)
    for f in found:
        print(f"HIT    {f}")
    if found:
        print(f"\n{len(found)} problem(s): a refusal is naming a menu the switch is not in.")
        return 1
    print("OK: every sentence names a menu that has it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
