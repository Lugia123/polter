#!/usr/bin/env python3
"""The Windows catalogue reader knows one form per message, and only one.

`src/os/i18n.zig` reads the installed `.mo` itself on Windows -- there is no
libintl on that platform -- and what it implements is the plain case: one
msgid, one translation, found by a bytewise binary search over the originals
table. Two things in the `.mo` format are outside that case:

  * **A message with a context.** gettext stores it under the key
    `context \\x04 msgid`, not under `msgid`. `_` is called with the bare
    msgid, so the search misses and the user reads the English.

  * **A message with plural forms.** The translations are stored NUL-separated
    inside one entry. The reader returns a pointer into that entry, and a C
    caller reading to the first NUL gets the singular -- for every count.

**Neither is a crash and neither is loud.** Both come out as a string that is
merely wrong, on a platform none of the people who write the catalogues run.

Today neither exists: **33 catalogues in `po/` (32 `.po` and the `.pot`),
0 lines beginning with the plural keyword, 0 beginning with the context
keyword.** That reading is what makes the reader's simplicity safe, and it is
a reading about today. This gate is here so the day it stops being true is a
red build rather than a translation that quietly stops appearing.

The way off this gate is not to delete it. It is to teach the reader the two
cases -- both are a few lines each -- and then this file has nothing to say.

Run:  python3 windows/tools/one-form-per-message.py
Exit: 0 while every message in every catalogue has exactly one form and no
      context.
"""

import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
PO_DIR = os.path.join(ROOT, "po")

# **Built from halves.** This file describes the keywords it looks for, and a
# scanner that searched for a string this docstring contains would find its
# own prose and report a catalogue that is clean. Writing them in pieces means
# the text above can say what it means without becoming the thing being
# counted.
PLURAL_KW = "msgid" + "_plural"
CONTEXT_KW = "msg" + "ctxt"

# The two things in source that make gettext write those keywords. `C_` is in
# `xgettext`'s keyword list in `src/build/GhosttyI18n.zig` (`--keyword=C_:1c,2`)
# and would put a context into the template; `ngettext` is the plural API and
# is not called anywhere today.
#
# **Source as well as catalogues** because the catalogues lag: a `C_(...)`
# added today does not reach `po/` until somebody runs the translations step,
# and between those two moments the string is silently English on Windows.
SOURCE_MARKERS = {
    "a message with a context": re.compile(r"(?<![A-Za-z0-9_])C_\s*\("),
    "the plural lookup": re.compile(r"(?<![A-Za-z0-9_])n?gettext\s*\("),
}

SOURCE_DIRS = (
    os.path.join(ROOT, "src"),
    os.path.join(ROOT, "windows", "host", "src"),
)
SOURCE_SUFFIXES = (".zig", ".rs")

# `os/i18n.zig` declares `dgettext` and calls it; that is the singular lookup
# this reader replaces, not a plural one. Its own file is the one place the
# marker regex above is expected to fire.
SOURCE_EXEMPT = {
    os.path.join("src", "os", "i18n.zig"):
        "declares and calls `dgettext`, the singular lookup itself",
}


def catalog_findings(path: str):
    """Lines of `path` that begin with either keyword, as `(lineno, keyword)`.

    Only at the start of a line: the keywords also appear inside translated
    strings and inside translator comments, and neither is a message this
    reader will be asked for.
    """
    out = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh, 1):
            for kw in (PLURAL_KW, CONTEXT_KW):
                if line.startswith(kw):
                    out.append((i, kw))
    return out


def strip_comments(text: str, suffix: str) -> str:
    """`//` comments blanked, newlines kept.

    Both languages scanned use `//`. The files being read *discuss* these
    markers -- `GhosttyI18n.zig` names the keyword it passes to `xgettext` --
    and a scanner that counts prose reports a defect that is a sentence.
    """
    del suffix
    return re.sub(r"//[^\n]*", "", text)


def source_findings():
    out = []
    scanned = 0
    for base in SOURCE_DIRS:
        for dirpath, _, names in os.walk(base):
            for name in sorted(names):
                if not name.endswith(SOURCE_SUFFIXES):
                    continue
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, ROOT)
                if rel in SOURCE_EXEMPT:
                    continue
                with open(full, encoding="utf-8", errors="replace") as fh:
                    text = strip_comments(fh.read(), name)
                scanned += 1
                for what, pattern in SOURCE_MARKERS.items():
                    for m in pattern.finditer(text):
                        out.append((rel, text[: m.start()].count("\n") + 1, what))
    return scanned, out


# -- self-test ---------------------------------------------------------------

CLEAN_PO = (
    'msgid ""\n'
    'msgstr "Content-Type: text/plain; charset=UTF-8\\n"\n'
    "\n"
    'msgid "Save"\n'
    'msgstr "保存"\n'
    "\n"
    "# a translator note mentioning " + PLURAL_KW + " and " + CONTEXT_KW + "\n"
    'msgid "Enabled"\n'
    'msgstr "启用"\n'
)
PLURAL_PO = CLEAN_PO + '\n' + PLURAL_KW + ' "%d tabs"\nmsgstr[0] "%d"\n'
CONTEXT_PO = CLEAN_PO + '\n' + CONTEXT_KW + ' "menu"\nmsgid "Open"\nmsgstr ""\n'


def self_test(tmp: str) -> bool:
    cases = (("clean", CLEAN_PO, 0), ("plural", PLURAL_PO, 1), ("context", CONTEXT_PO, 1))
    for name, body, want in cases:
        path = os.path.join(tmp, f"{name}.po")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        got = len(catalog_findings(path))
        if got != want:
            print(f"FAIL: self-test broken -- the {name} catalogue gave {got} "
                  f"finding(s), expected {want}. A scanner that cannot tell "
                  f"these apart says nothing about `po/`.")
            return False

    # The source patterns, against text that must and must not match. The
    # near-misses are the ones that would make this gate red on a clean tree
    # and get it switched off.
    hits = SOURCE_MARKERS["a message with a context"]
    if not hits.search('C_("menu", "Open")'):
        print("FAIL: the context marker pattern does not match a call to it.")
        return False
    for benign in ('LC_ALL', 'const LC_(x)', 'ABC_(y)'):
        if hits.search(benign):
            print(f"FAIL: the context marker pattern matches {benign!r}.")
            return False
    plural = SOURCE_MARKERS["the plural lookup"]
    if not plural.search("ngettext(a, b, n)"):
        print("FAIL: the plural pattern does not match a call to it.")
        return False
    if plural.search("_ = xngettext(a)"):
        print("FAIL: the plural pattern matches an identifier that ends in it.")
        return False

    print("probe self-test: OK (plural, context and a clean catalogue are told "
          "apart; the source patterns match their calls and not their "
          "look-alikes)")
    return True


def main() -> int:
    import tempfile
    tmp = tempfile.mkdtemp(prefix="one-form-per-message-")
    try:
        if not self_test(tmp):
            return 2
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)

    catalogs = sorted(glob.glob(os.path.join(PO_DIR, "*.po")) +
                      glob.glob(os.path.join(PO_DIR, "*.pot")))
    if not catalogs:
        print(f"FAIL: no catalogues found under {PO_DIR}. This gate's whole "
              f"subject is what is in them; finding none is not a clean "
              f"result, it is a broken scan.")
        return 1

    problems = []
    entries = 0
    for path in catalogs:
        with open(path, encoding="utf-8", errors="replace") as fh:
            entries += sum(1 for line in fh if line.startswith("msgid "))
        for lineno, kw in catalog_findings(path):
            rel = os.path.relpath(path, ROOT)
            problems.append(
                f"{rel}:{lineno} begins with `{kw}`. The Windows reader in "
                f"`src/os/i18n.zig` looks a message up by its msgid alone and "
                f"returns the whole entry as one string, so this message comes "
                f"out as the English msgid or as its first form for every "
                f"count. Teach the reader this case, or drop the message."
            )

    scanned, hits = source_findings()
    if not scanned:
        print("FAIL: no source files were scanned for the markers that produce "
              "these entries. Half this gate looked at nothing.")
        return 1
    for rel, lineno, what in hits:
        problems.append(
            f"{rel}:{lineno} uses {what}. Nothing in `src/os/i18n.zig` handles "
            f"it on Windows, and it will reach `po/` the next time the "
            f"translations step runs."
        )

    print(f"{len(catalogs)} catalogue(s) in po/, {entries} msgid line(s) scanned.")
    print(f"{scanned} source file(s) scanned for the two markers that "
          f"produce them.")
    print("NOT CHECKED: whether a translation is *correct*, and whether a "
          "catalogue omitted from `src/os/i18n_locales.zig` is ever loaded. "
          "This gate is about the shape of an entry, not its content.")

    for name, why in sorted(SOURCE_EXEMPT.items()):
        print(f"exempt: {name} -- {why}")

    if problems:
        print()
        for p in problems:
            print(f"FAIL: {p}")
        return 1

    print("OK: every message has one form and no context.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
