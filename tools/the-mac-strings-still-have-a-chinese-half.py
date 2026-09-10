#!/usr/bin/env python3
r"""Every user-visible string in the macOS app has a Chinese half, or a reason.

# The defect, found by a user rather than by anything here

This repository has two translation systems and only one of them was
guarded. The gettext catalogues under `po/` have
`translations-still-attach.py` watching thirty-two languages. The macOS side
-- `macos/Sources/App/*.lproj/*.strings` -- had nothing, and drifted until a
menu item and a whole settings page were English in a Chinese build.

**The file itself had already written down how it would happen.** The first
two lines of `zh-Hans.lproj/Localizable.strings` say: the key is the English
text, so changing the English means changing this too, *or it falls back to
English silently and nothing reports it*. That is a complete description of
the failure mode, sitting one line above the strings it describes, for
however long it took somebody to notice the menu was in the wrong language.
Writing a hazard down is not the same as watching for it.

# The two checks, and why they are two

  1. **Every key in `Base.lproj` has one in `zh-Hans.lproj`.** This is the
     drift the header warns about: a reworded English string leaves its
     translation behind, attached to a key nothing looks up any more.

  2. **A user-visible Swift literal goes through `String(localized:)`.**
     Check 1 cannot see this one at all -- a string that never entered the
     table is not a key that lost its translation, it is a key that was
     never there, and a table can be perfectly in sync while half the
     interface bypasses it. That is what was actually wrong here: sixty-nine
     literals across fifteen files, and the `.strings` files were 55 for 55.

# The exemptions, and why they are written here

Three kinds of literal are not translatable, and each carries its reason in
`EXEMPT` rather than sitting on a list somebody has to trust:

  * the application's own name,
  * a format string with no words in it (`"\(a)/\(b)"`),
  * an identifier that happens to be spelled like a sentence.

**Written as reasons, not as a bare whitelist**, because a whitelist puts
every new case outside the check by default -- which is the wrong direction
for a check whose whole job is to notice new cases.

# NOT CHECKED

- **Whether the Chinese is right.** This sees that a key has a value. A
  value that says the wrong thing passes every assertion here, and only a
  person reading it can tell. That is the larger half of translating and
  none of it is mechanical.
- **The other thirty-one languages.** The macOS app ships Base and
  zh-Hans; `po/` is where the rest live, and `translations-still-attach.py`
  is what watches them.
- **A `String(localized:` whose literal is on the next line.** The scan
  reads the call and the literal that follows it on the same line. Broken
  across lines for width, a string quietly stops being asked for -- so the
  two places that were long enough to want it carry a comment saying they
  have to stay on one line.
- **Text that reaches the screen without passing any of the calls named
  above.** A `String` handed to something this does not list is invisible
  here. `KeybindsModel.note` was exactly that -- four sentences returned
  from a computed property, on screen in the shortcuts window, and green
  under this file until somebody read the window.
"""

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "macos" / "Sources"
BASE_DIR = MAC / "App" / "Base.lproj"
ZH_DIR = MAC / "App" / "zh-Hans.lproj"

# `Text("…")` and its relatives. The call is what makes a literal
# user-visible: the same words as an argument to something else are usually
# a key, a symbol name, or an identifier.
# The SwiftUI half and the AppKit half.
#
# **The AppKit half was missing, and the gap had a shape.** This file's first
# version watched only the SwiftUI calls, so a menu item built in code --
# `NSMenuItem(title: "Rename Tab...")` -- passed a green gate and shipped in
# English next to menu items from the xib that were in Chinese. The window
# title of the shortcuts window did the same. Every one of these puts text on
# screen; which framework drew it is not the question being asked.
CALL = re.compile(
    r'\b(Text|Button|Label|TextField|SecureField|Toggle|Picker|'
    r'navigationTitle|help|confirmationDialog|alert|'
    r'NSMenuItem\(title:|NSMenu\(title:|addItem\(withTitle:|'
    r'addButton\(withTitle:|setAccessibilityLabel)\(?\s*"'
)

# `x.messageText = "..."`, `window.title = "..."`: assignment, not a call, so
# the pattern above cannot see them.
ASSIGN = re.compile(
    r'\.(messageText|informativeText|title|placeholderString|'
    r'stringValue|toolTip|label)\s*=\s*"'
)


def swift_literal_at(line: str, start: int):
    r"""The whole Swift string literal beginning at `start`, or None.

    **A regex cannot do this, and getting it wrong is not a near miss.** A
    Swift literal may contain `\(...)` interpolation, and that interpolation
    may contain string literals of its own -- `"\(xs.joined(separator: ", "))"`
    has four quotes in it and the second one is not the end. A `"[^"]*"`
    pattern stops at that second quote and hands back
    `What it is handed: \(xs.joined(separator: `, which is not a string this
    program contains. Everything downstream then judges a literal nobody
    wrote: this check called that one untranslated, and the rewrite that
    followed cut the line in half.

    So the scan is by hand: count interpolation depth, and only a quote at
    depth zero closes the literal.
    """
    i = start
    depth = 0
    while i < len(line):
        c = line[i]
        if c == "\\":
            if line[i + 1:i + 2] == "(":
                depth += 1
                i += 2
                continue
            i += 2
            continue
        if depth > 0:
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            i += 1
            continue
        if c == '"':
            return line[start:i]
        i += 1
    return None


def visible_literals(line: str):
    """Every user-visible literal on this line, with what shows it."""
    for m in CALL.finditer(line):
        text = swift_literal_at(line, m.end())
        if text is not None:
            yield m.group(1).rstrip("(").rstrip(":").split("(")[0], text
    for m in ASSIGN.finditer(line):
        text = swift_literal_at(line, m.end())
        if text is not None:
            yield m.group(1), text

STRINGS_ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)
XIB_TITLE = re.compile(r'<menuItem\b[^>]*?\btitle="([^"]*)"[^>]*?\bid="([^"]*)"')
XIB_TITLE_REV = re.compile(r'<menuItem\b[^>]*?\bid="([^"]*)"[^>]*?\btitle="([^"]*)"')

# Each entry is the literal and why it is not translatable. Adding one
# without a reason is how this list stops meaning anything.
EXEMPT = {
    "Polter": "the application's own name; it is the same word in every language",
    "Ghostty": "the name of the project this is built on",
    "GitHub": "a proper noun, and the name on the button of the site it opens",
    "Docs": "the label on a link to English-language documentation",
}


# The `=> comptime &.{}` arms of the command table: actions the core names no
# command for. The capture keeps the tags stacked above the arm as well as the
# one on the arm's own line, because that is how the file lists them.
NO_COMMAND = re.compile(
    r"((?:\s*\.\w+,\n)*\s*\.(\w+),?\s*)=>\s*comptime\s*&\.\{\s*\}"
)

LOCALIZED = re.compile(r'(?:String\(localized:|NSLocalizedString\()\s*"')


def interpolation_to_format(key: str) -> str:
    r"""The key as the .strings table spells it.

    `String(localized: "n: \(x)")` does not look up `n: \(x)`. The compiler
    turns each interpolation into a format specifier, so the table's key is
    `n: %@` -- and a check comparing the source text to the table would call
    every interpolated string missing and be wrong every time.
    """
    out, i, depth = [], 0, 0
    while i < len(key):
        c = key[i]
        if depth == 0 and c == "\\" and key[i + 1:i + 2] == "(":
            depth, i = 1, i + 2
            out.append("%@")
            continue
        if depth:
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            i += 1
            continue
        if c == "\\":
            # **Swift escapes are the source's, not the table's.** A literal
            # written `"execute \\"%@\\"?"` is the string `execute "%@"?`, and
            # that -- without the backslashes -- is the key the table holds.
            # Leaving them in asks the .strings file for a key nobody can
            # write, and the check would stay red however much Chinese was
            # added.
            out.append(unescape(key[i:i + 2]))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def is_formatting_only(text: str) -> bool:
    """A literal with no words in it -- only interpolation and punctuation.

    `"\\(selected + 1)/\\(total)"` has nothing to translate: every character
    a reader sees comes from the values. Detected rather than exempted by
    name, because there is no judgement in it.
    """
    without_interpolation = re.sub(r"\\\([^)]*\)", "", text)
    return re.search(r"[A-Za-z]{2,}", without_interpolation) is None


def looks_like_an_identifier(text: str) -> bool:
    """`"some_action"` or `"a.b.c"` -- a name, not a sentence."""
    return re.fullmatch(r"[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*", text) is not None


def unescape(text: str) -> str:
    r"""`\n` and `\"` as the byte they stand for.

    **Both sides of every comparison here go through this.** The key is the
    same string whether it is being read out of Swift source or out of a
    .strings file, but the two spell it with their own escapes; normalising
    one side and not the other reports a difference that only exists in the
    spelling.
    """
    out, i = [], 0
    while i < len(text):
        if text[i] == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            out.append({"n": "\n", "t": "\t", "r": "\r"}.get(nxt, nxt))
            i += 2
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def strings_keys(path: Path) -> dict:
    if not path.is_file():
        return {}
    return {
        unescape(k): v
        for k, v in STRINGS_ENTRY.findall(path.read_text(encoding="utf-8"))
    }


def self_test() -> None:
    """Run every time, because a probe in a file nobody runs stops being run."""
    assert is_formatting_only(r"\(selected + 1)/\(total)"), "probe: pure interpolation not seen"
    assert not is_formatting_only(r"Version: \(v)"), "probe: a real word was called formatting"
    assert looks_like_an_identifier("poltergeist_toggle_held"), "probe: identifier not seen"
    assert not looks_like_an_identifier("Update Available"), "probe: a sentence called an identifier"

    sample = 'Text("Update Available")'
    assert list(visible_literals(sample)), "probe: a visible literal was not matched"
    assert not list(visible_literals('foo("Update Available")')), \
        "probe: a non-visible call was matched"

    # The one that broke this file: a literal whose interpolation contains a
    # string of its own. A `"[^"]*"` scan reads it as ending at the third
    # quote, and every judgement after that is about text nobody wrote.
    nested = 'Text("What it is handed: \\(said.joined(separator: ", "))")'
    got = [t for _, t in visible_literals(nested)]
    assert got == ['What it is handed: \\(said.joined(separator: ", "))'], \
        f"probe: nested interpolation was cut short -- {got!r}"

    pure = 'Text("\\(selected + 1)/\\(searchState.total, default: "?")")'
    got = [t for _, t in visible_literals(pure)]
    assert got and is_formatting_only(got[0]), \
        f"probe: a pure-interpolation literal was not seen as one -- {got!r}"

    assert interpolation_to_format('n: \\(x + 1) of \\(y)') == "n: %@ of %@", \
        "probe: interpolation was not turned into the key the table holds"
    assert interpolation_to_format("plain") == "plain"
    assert interpolation_to_format(r'execute \"\(f)\"?') == 'execute "%@"?', \
        "probe: a Swift escape was carried into the key the table holds"

    # The command-table pattern, against the shape the file actually uses:
    # tags stacked above the arm, and one on the arm's own line.
    sample = "        .goto_tab,\n        .resize_split,\n        => comptime &.{},\n"
    got = [m for m in NO_COMMAND.finditer(sample)]
    assert got, "probe: the `no command` arm shape was not matched"
    tags = re.findall(r"\.(\w+)\s*,", got[0].group(1)) + [got[0].group(2)]
    assert set(tags) == {"goto_tab", "resize_split"}, f"probe: read {tags!r}"
    assert not NO_COMMAND.search("        .text => comptime &.{.{\n"), \
        "probe: an arm that does name a command was read as naming none"

    print("probe self-test: OK (nested interpolation, format keys, call and arm shapes)")


def main() -> int:
    self_test()

    problems: list[str] = []

    # 1. Every Base key has a zh-Hans one.
    for name in ("Localizable.strings", "MainMenu.strings"):
        base = strings_keys(BASE_DIR / name)
        zh = strings_keys(ZH_DIR / name)
        if name == "Localizable.strings" and not base:
            problems.append(
                f"{name}: no Base entries were read. Either the file moved or this "
                "check stopped being able to parse it -- and a check that finds "
                "nothing passes everything."
            )
        for key in base:
            if key not in zh:
                problems.append(
                    f"{name}: {key!r} is in Base and not in zh-Hans.\n"
                    "      The key is the English text, so rewording the English "
                    "leaves the old translation attached to a key nothing looks "
                    "up. Nothing reports that at runtime: the interface simply "
                    "comes back in English."
                )

    # The menu is a xib rather than a table, so its keys are `<id>.title`.
    xib = MAC / "App" / "Base.lproj" / "MainMenu.xib"
    menu_zh = strings_keys(ZH_DIR / "MainMenu.strings")
    if xib.is_file():
        text = xib.read_text(encoding="utf-8")
        items = {i: t for t, i in XIB_TITLE.findall(text)}
        items.update({i: t for i, t in XIB_TITLE_REV.findall(text)})
        if not items:
            problems.append(
                "MainMenu.xib: no menu items were read, so this check is watching "
                "nothing."
            )
        for ident, title in items.items():
            if title in EXEMPT:
                continue
            if f"{ident}.title" not in menu_zh:
                problems.append(
                    f"MainMenu.xib: {title!r} ({ident}) has no zh-Hans title.\n"
                    "      It will show in English in a Chinese build, and nothing "
                    "will say so."
                )

    # 3. Every key the Swift code asks for is answered in Chinese.
    #
    # Checks 1 and 2 leave a gap exactly the shape of this night's work.
    # Check 1 compares two tables to each other, so a key in neither is in
    # agreement; check 2 only asks that a literal go through
    # `String(localized:)`, and a wrapped literal with no entry behind it
    # renders its own English. So sixty-four strings were wrapped, both
    # checks went green, and not one Chinese word had been written. This is
    # the check that asks for the words.
    localized_zh = strings_keys(ZH_DIR / "Localizable.strings")
    asked_for: dict[str, str] = {}

    # 2. No user-visible Swift literal bypasses `String(localized:)`.
    swift_files = 0
    for path in sorted(MAC.rglob("*.swift")):
        if "/build/" in str(path):
            continue
        swift_files += 1
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if "String(localized:" in line or "NSLocalizedString" in line:
                for m in LOCALIZED.finditer(line):
                    key = swift_literal_at(line, m.end())
                    if key is None or is_formatting_only(key):
                        continue
                    asked_for.setdefault(interpolation_to_format(key),
                                         f"{path.relative_to(ROOT)}:{n}")
                continue
            for call, literal in visible_literals(line):
                if literal in EXEMPT:
                    continue
                if is_formatting_only(literal) or looks_like_an_identifier(literal):
                    continue
                rel = path.relative_to(ROOT)
                problems.append(
                    f"{rel}:{n}: {call}({literal!r}) is a bare literal.\n"
                    "      Wrap it in `String(localized:, comment:)` and add the "
                    "Chinese to zh-Hans.lproj/Localizable.strings. A string that "
                    "never enters the table cannot be found missing from it, which "
                    "is why the tables were 55 for 55 while sixty-nine literals "
                    "went straight to the screen."
                )

    if swift_files == 0:
        problems.append(
            "no Swift files were read at all -- this check is watching nothing."
        )

    for key, where in sorted(asked_for.items()):
        if key not in localized_zh:
            problems.append(
                f"{where}: {key!r} is asked for and has no Chinese.\n"
                "      `String(localized:)` falls back to the key itself, so this "
                "renders the English sentence in a Chinese build and no warning "
                "is printed anywhere. Add it to zh-Hans.lproj/Localizable.strings."
            )

    # 4. Every action the core gives no command for has a name here.
    #
    # The keybind listing takes its names from the core's command list. The
    # thirty-one actions with `=> comptime &.{}` have none -- deliberately,
    # and for reasons written beside them -- so without an entry keyed by the
    # tag that page shows `goto_tab` in a row of ⌘1 ⌘2 ⌘3, which is what the
    # user reported as "neither Chinese nor English".
    #
    # **The set is read here rather than listed here.** A hand-kept copy would
    # be right on the day it was written; this way an action that loses its
    # command starts failing this check on the next run.
    command_zig = ROOT / "src" / "input" / "command.zig"
    if command_zig.is_file():
        text = command_zig.read_text(encoding="utf-8")
        arms = list(NO_COMMAND.finditer(text))
        if not arms:
            problems.append(
                "src/input/command.zig: no `=> comptime &.{}` arms were read, "
                "so this check is watching nothing. Either the file's shape "
                "changed or the pattern stopped matching -- and a check that "
                "finds nothing passes everything."
            )
        for m in arms:
            tags = re.findall(r"\.(\w+)\s*,", m.group(1)) + [m.group(2)]
            for tag in tags:
                if tag not in localized_zh:
                    problems.append(
                        f"src/input/command.zig: the action {tag!r} has no "
                        "command and no name.\n"
                        "      The keybind listing will print the tag itself. "
                        "Add a name for it, keyed by the tag, to both "
                        "Localizable.strings tables."
                    )

    if problems:
        print("FAIL: the macOS interface has English with no Chinese behind it:")
        for p in problems:
            print(f"      {p}")
        return 1

    print(
        f"{swift_files} Swift file(s) and two .strings tables read: every "
        "user-visible string goes through the table, and every key in Base has "
        "one in zh-Hans."
    )
    for k, why in EXEMPT.items():
        print(f"      exempt: {k!r} -- {why}")
    print(
        "NOT CHECKED: whether the Chinese is right; the thirty-one languages "
        "under po/; a `String(localized:` whose literal is on the next line; "
        "text reaching the screen through a call this does not list."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
