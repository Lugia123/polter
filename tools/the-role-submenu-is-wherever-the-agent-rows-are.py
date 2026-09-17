#!/usr/bin/env python3
r"""The macOS `Role` submenu is in every menu the per-terminal agent rows are in.

# The defect this is the floor for

The four per-terminal agent rows -- supervisor, supervise, shield, authorise --
are in three places on macOS: the menu bar's Agents menu, the tab strip's
right-click menu, and the terminal's own right-click menu. The role submenu,
added later, went into the two right-click menus and **not** into the menu
bar. Nothing went red, because nothing was comparing the three.

It is the shape that hides best: the feature exists, it works, and two of the
three ways a person reaches for it have it. Somebody who learned the menu bar
is the place where per-terminal agent things live looks there, does not find
it, and concludes the feature is not built.

# What is checked

**Default-include, and the rows decide, not a list here.** A menu is one of
"these three" because it carries the shield row, not because its filename is
written down as a menu that ought to. A fourth menu that grows the agent rows
tomorrow is checked from the moment it does.

  1. Each macOS menu-building file that carries the shield row must also
     build the role item -- and it must build it by calling the shared
     builder, not by writing a second copy of the submenu.
  2. The menu bar's copy is in a nib, so its two halves are checked
     separately: the item is inside the Agents submenu in the nib, and the
     delegate that fills it is wired to that same item in `AppDelegate`.
     Either half alone is a row that is there and stays empty, or a builder
     that runs for nothing.
  3. If no file carries the shield row at all, that is a finding. A check
     whose subject has vanished passes silently otherwise.

Comments are stripped from the Swift before any of it is matched. A file that
merely *talks* about the builder in a doc comment is a file that does not call
it, and this check exists precisely because prose and code disagreed.

# NOT CHECKED

  * **Whether the item is drawn, enabled, ticked correctly, or does
    anything.** This reads menu definitions, not a running program. What the
    submenu contains is `macos/Tests/Personas/PersonaMenuTests.swift`'s, and
    that it contains the same thing in all three places is what calling one
    builder buys -- this file checks the call, not the contents.
  * **The GTK and Windows menus.** Windows builds its own tree in
    `windows/host/src/menu.rs` and has its own tests; GTK has neither the
    rows nor the submenu.
  * **Wording, order, and where in the menu the item sits.** A role item at
    the wrong end of the Agents menu passes here.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")

XIB = "macos/Sources/App/Base.lproj/MainMenu.xib"
APPDELEGATE = "macos/Sources/App/AppDelegate.swift"
SWIFT_MENUS = [
    "macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift",
    "macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift",
]

# The row that says "this menu carries the per-terminal agent actions".
SHIELD_SWIFT = re.compile(r"poltergeistToggleShielded")
SHIELD_XIB = re.compile(r'selector="poltergeistToggleShielded:"')

# The shared builder, called rather than mentioned.
BUILDS_ROLE = re.compile(r"PersonaMenu\s*\.\s*(?:makeItem|configure)\s*\(")

# The nib half: an outlet on the delegate pointing at a menu item.
OUTLET = re.compile(r'<outlet\s+property="menuPoltergeistPersona"\s+destination="([^"]+)"')

# The delegate half: the item is declared and something is attached to it.
OUTLET_DECLARED = re.compile(r"@IBOutlet[^\n]*\bmenuPoltergeistPersona\b")
OUTLET_ATTACHED = re.compile(r"\bmenuPoltergeistPersona\b[^\n]*\battach\s*\(")

BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT = re.compile(r"//[^\n]*")


def code_only(src):
    """Swift with its comments removed.

    Crude on purpose: it does not know about comment markers inside string
    literals, which would only ever make this check stricter, never looser.
    """
    return LINE_COMMENT.sub("", BLOCK_COMMENT.sub("", src))


def submenu_block(xib, title):
    """The text of one `<menu key="submenu" title="...">` element."""
    start = re.search(r'<menu key="submenu" title="%s"' % re.escape(title), xib)
    if not start:
        return None
    depth = 0
    for tag in re.finditer(r"<(/?)menu\b", xib[start.start():]):
        depth += -1 if tag.group(1) else 1
        if depth == 0:
            return xib[start.start():start.start() + tag.end()]
    return None


def findings(sources):
    out = []
    carriers = []

    for name in SWIFT_MENUS:
        src = code_only(sources.get(name, ""))
        if not SHIELD_SWIFT.search(src):
            continue
        carriers.append(name)
        if not BUILDS_ROLE.search(src):
            out.append(
                f"{name} builds the per-terminal agent rows and no role item. "
                "Two of the three menus having it is what hid this for a whole "
                "feature's worth of work"
            )

    xib = sources.get(XIB, "")
    agents = submenu_block(xib, "Agents")
    if agents is None:
        out.append(
            f"{XIB} has no Agents submenu. Either it was renamed -- in which case "
            "this check is reading the wrong tree -- or the menu bar lost the rows"
        )
    elif SHIELD_XIB.search(agents):
        carriers.append(XIB)
        outlet = OUTLET.search(xib)
        if not outlet:
            out.append(
                "the menu bar's Agents menu carries the agent rows and has no role "
                "item: nothing in the nib is wired to the delegate as one"
            )
        elif ('id="%s"' % outlet.group(1)) not in agents:
            out.append(
                "the menu bar's role item is wired up but is not in the Agents "
                "submenu, which is where the rows it belongs with are"
            )
        delegate = code_only(sources.get(APPDELEGATE, ""))
        if not OUTLET_DECLARED.search(delegate):
            out.append(
                f"{APPDELEGATE} does not declare the role item's outlet, so the nib's "
                "row is connected to nothing and stays empty"
            )
        elif not OUTLET_ATTACHED.search(delegate):
            out.append(
                f"{APPDELEGATE} declares the role item's outlet and never attaches the "
                "menu to it. An item with no submenu is a dead row, and it looks "
                "exactly like a feature that was never built"
            )

    if not carriers:
        out.append(
            "no macOS menu carries the per-terminal agent rows any more. Every check "
            "above would pass by having nothing to check"
        )
    return out


# ------------------------------------------------------------------ self-test

GOOD_XIB = """
<menuItem title="Agents" id="pg0-Mn-Ma1">
  <menu key="submenu" title="Agents" id="pg0-Mn-Ma2">
    <items>
      <menuItem title="Keep Agents Out of This Terminal" id="pg9-Sh-Ld1">
        <connections><action selector="poltergeistToggleShielded:" target="-1" id="pg9"/></connections>
      </menuItem>
      <menuItem title="Role" id="pgB-Ro-Le1"/>
    </items>
  </menu>
</menuItem>
<outlet property="menuPoltergeistPersona" destination="pgB-Ro-Le1" id="pgB-Ou-Tl1"/>
"""

GOOD = {
    XIB: GOOD_XIB,
    APPDELEGATE: (
        "    @IBOutlet private var menuPoltergeistPersona: NSMenuItem?\n"
        "    if let item = menuPoltergeistPersona { personaMenuBar.attach(to: item) }\n"
    ),
    SWIFT_MENUS[0]: (
        "#selector(TerminalController.poltergeistToggleShielded(_:))\n"
        "menu.addItem(PersonaMenu.makeItem(state: s, personas: p, personasKnown: k, target: t))\n"
    ),
    SWIFT_MENUS[1]: (
        "action: #selector(poltergeistToggleShielded(_:))\n"
        "menu.addItem(PersonaMenu.makeItem(state: s, personas: p, personasKnown: k, target: self))\n"
    ),
}


def self_test():
    def case(**over):
        s = dict(GOOD)
        s.update(over)
        return s

    # The decoy for check 1 is the shape the defect actually had on the two
    # right-click menus before the builder existed: the submenu written out by
    # hand, beside prose naming the thing it is not calling.
    handwritten = (
        "action: #selector(poltergeistToggleShielded(_:))\n"
        "/// Same submenu as the tab strip's, built by PersonaMenu.\n"
        "let role = NSMenuItem(title: \"Role\", action: nil, keyEquivalent: \"\")\n"
        "role.submenu = NSMenu()\n"
    )

    cases = [
        ("the shape today", case(), 0),
        ("the menu bar has the rows and no role item",
         case(**{XIB: GOOD_XIB.replace(
             '<menuItem title="Role" id="pgB-Ro-Le1"/>', "").replace(
             '<outlet property="menuPoltergeistPersona" destination="pgB-Ro-Le1" id="pgB-Ou-Tl1"/>',
             "")}), 1),
        ("the nib's item is outside the Agents submenu",
         case(**{XIB: GOOD_XIB.replace('<menuItem title="Role" id="pgB-Ro-Le1"/>', "")}), 1),
        ("the outlet is never declared",
         case(**{APPDELEGATE: "// no outlet here"}), 1),
        ("declared and never attached",
         case(**{APPDELEGATE: "@IBOutlet private var menuPoltergeistPersona: NSMenuItem?"}), 1),
        ("a right-click menu writes its own copy instead of calling the builder",
         case(**{SWIFT_MENUS[1]: handwritten}), 1),
        ("the builder is named in a comment and not called",
         case(**{SWIFT_MENUS[0]:
                 "#selector(TerminalController.poltergeistToggleShielded(_:))\n"
                 "// built by PersonaMenu.makeItem(...) elsewhere\n"}), 1),
        ("the rows are gone from everywhere",
         case(**{XIB: GOOD_XIB.replace("poltergeistToggleShielded:", "somethingElse:"),
                 SWIFT_MENUS[0]: "// nothing", SWIFT_MENUS[1]: "// nothing"}), 1),
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
        print("probe self-test: OK (menu bar without the item, the item outside the group, "
              "each half of the wiring missing, a hand-written copy, a builder named only in "
              "a comment, and the rows gone from everywhere)")
    return ok


def main():
    if not self_test():
        return 1

    sources = {}
    for name in [XIB, APPDELEGATE] + SWIFT_MENUS:
        try:
            with open(os.path.join(ROOT, name), encoding="utf-8") as fh:
                sources[name] = fh.read()
        except OSError as e:
            print(f"cannot read {name}: {e}")
            return 1

    carriers = [n for n in SWIFT_MENUS if SHIELD_SWIFT.search(code_only(sources[n]))]
    agents = submenu_block(sources[XIB], "Agents")
    if agents and SHIELD_XIB.search(agents):
        carriers.append(XIB)
    print(f"{len(carriers)} macOS menu(s) carry the per-terminal agent rows: "
          f"{', '.join(carriers) if carriers else '(none)'}")
    print("NOT CHECKED: that the item is drawn, enabled or ticked right -- this reads "
          "menu definitions, not a running program.")

    found = findings(sources)
    for f in found:
        print(f"HIT    {f}")
    if found:
        print(f"\n{len(found)} problem(s): a menu has the agent rows without the role item.")
        return 1
    print("OK: every menu with the agent rows builds the role item from the shared builder.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
