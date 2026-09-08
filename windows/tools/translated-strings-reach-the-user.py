#!/usr/bin/env python3
"""A string routed through gettext on a platform that has no gettext is English.

**The defect this exists for was shipped by the change that added the note
warning about it.** `windows/host/src/i18n.rs` says "a string that has not been
translated yet shows in English", and `src/input/command.zig`'s menu test says
a label "wrapped for translation and never translated ... renders in English on
a Chinese machine". Both were written while wrapping sixty-three Chinese menu
labels in `tr()` -- and on Windows every one of them then rendered in English,
because on Windows there is no translation to be had at all.

# Why nothing else could see it

  * `msgfmt --check` says the catalogue is well formed. It is.
  * `translations-still-attach.py` says no translation was orphaned. None was.
  * `command.zig`'s menu test asks `zh_CN.po` what a label means. It answers.
  * `cargo check` compiles a call to a function that returns its argument.

Every one of those asks **"is there a translation?"**. Not one asks **"can the
host reach it?"** -- and the two answers are the same on the machine the port
is written on and never the same on Windows. That is the whole gap this file
stands in.

# The fact it reads

`src/build/Config.zig` decides `i18n` per target, and Windows falls to the
`else` arm. When that arm is `false`:

    i18n._()  ->  `if (comptime !build_config.i18n) return msgid;`

-- the lookup is compiled out before it happens. `ghostty_translate` returns
the msgid, `tr()` returns the msgid, and the msgid is English. **It is not
"untranslated yet". It is untranslatable, by construction, until the build
changes.**

Run:  python3 windows/tools/translated-strings-reach-the-user.py
Exit: 0 when nothing user-visible depends on a lookup this platform cannot do,
      or when every such string is on the bill below.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(ROOT, "windows", "host", "src")

# **A bill, not an approval.** Every entry is a string a Windows user reads in
# English. They are here rather than in the failure list for one reason: they
# were English *before* they were wrapped, so they are a standing gap and not
# a regression -- and a gate that is red from its first day is one people learn
# to scroll past.
#
# **Keyed by the msgid**, so fixing one means deleting its line: a count would
# let somebody wrap a new Chinese label, remove one of these, and stay level.
#
# ⚠️ **The way off this list is not to translate them.** It is to make
# `build_config.i18n` true for Windows -- which needs libintl bundled for the
# mingw target, an `install()` on a path the Windows package actually takes,
# a real `.windows` arm in `os/i18n.zig`, and `bind_textdomain_codeset` to
# UTF-8 so the answer is not returned in the ANSI code page. That is one task,
# not eleven, and the day it lands this whole list goes at once.
OWED_UNTRANSLATABLE = {
    "Save",
    "Enabled",
    "Open config file…",
    "About Polter",
    "Esc or click to dismiss",
    "MIT licensed. A fork of Ghostty.",
    "What it is handed: {}",
    "Subscribes to nothing, so Polter has nothing to hand it and will not start it.",
    "Keeps the conversations",
    "Notifies you",
    "Sets your agent up to reach Polter",
}

MARKED = re.compile(r"\b(?:tr|n_)\(\s*\"((?:[^\"\\]|\\.)*)\"")


def strip_comments(text: str) -> str:
    """`//` comments blanked, newlines kept. This file reads text, and the
    files it reads *discuss* `tr("…")` in prose -- including the note that
    explains this very gate."""
    return re.sub(r"//[^\n]*", "", text)


def windows_i18n_is_on(config_zig: str) -> bool | None:
    """Whether `build_config.i18n` is true for a Windows target.

    `None` when the rule cannot be read, which is reported rather than
    assumed: a parser that loses its subject must not answer "fine".
    """
    m = re.search(r"config\.i18n\s*=\s*b\.option\(", config_zig)
    if not m:
        return None
    tail = config_zig[m.end() : m.end() + 1200]
    sw = re.search(r"orelse\s+switch\s*\([^)]*\)\s*\{(.*?)\};", tail, re.S)
    if not sw:
        return None
    body = sw.group(1)
    for line in body.split("\n"):
        if ".windows" in line:
            return "true" in line
    els = re.search(r"else\s*=>\s*(\w+)", body)
    if not els:
        return None
    return els.group(1) == "true"


def marked_strings(src_dir: str):
    out = []
    for name in sorted(os.listdir(src_dir)):
        if not name.endswith(".rs"):
            continue
        text = strip_comments(open(os.path.join(src_dir, name), encoding="utf-8").read())
        # The module that defines the markers talks about them; its own
        # definitions are not user-visible strings.
        if name == "i18n.rs":
            continue
        for m in MARKED.finditer(text):
            out.append((name, text[: m.start()].count("\n") + 1, m.group(1)))
    return out


# -- self-test ---------------------------------------------------------------

CONFIG_OFF = 'config.i18n = b.option(bool, "i18n", "x") orelse switch (t) {\n' \
             "    .macos, .ios => true,\n    else => false,\n};"
CONFIG_ON = CONFIG_OFF.replace("    .macos, .ios => true,", "    .macos, .windows => true,")
CONFIG_ELSE_TRUE = CONFIG_OFF.replace("else => false", "else => true")


def self_test() -> None:
    if windows_i18n_is_on(CONFIG_OFF) is not False:
        print("FAIL: an `else => false` rule was not read as i18n being off for Windows.")
        sys.exit(2)
    if windows_i18n_is_on(CONFIG_ON) is not True:
        print("FAIL: Windows listed among the true arms was not read as on.")
        sys.exit(2)
    if windows_i18n_is_on(CONFIG_ELSE_TRUE) is not True:
        print("FAIL: an `else => true` rule was not read as on.")
        sys.exit(2)
    if windows_i18n_is_on("nothing here") is not None:
        print("FAIL: an unreadable rule answered instead of saying so.")
        sys.exit(2)
    if MARKED.search('// tr("prose about tr")') is None:
        print("FAIL: the pattern does not match at all; the scan would find nothing "
              "and read as a clean tree.")
        sys.exit(2)
    print("probe self-test: OK (off, on, else-true and unreadable are told apart)")


def main() -> int:
    self_test()
    config_zig = open(os.path.join(ROOT, "src", "build", "Config.zig"), encoding="utf-8").read()
    on = windows_i18n_is_on(config_zig)
    if on is None:
        print("FAIL: could not read the `config.i18n` rule out of src/build/Config.zig. "
              "A parser that cannot find its subject must say so, not pass.")
        return 1

    strings = marked_strings(SRC)
    print(f"build_config.i18n for a Windows target: {'on' if on else 'OFF'}")
    print(f"{len(strings)} user-visible string(s) in windows/host/src go through `tr`/`n_`.")
    if on:
        print("Nothing to report: the lookup exists on this platform.")
        return 0

    print("NOT CHECKED: whether the English msgid is a *good* thing to show. It is "
          "a fact about the build, not a judgement about the word.")
    unowed = []
    for name, line, msgid in strings:
        if msgid in OWED_UNTRANSLATABLE:
            continue
        unowed.append((name, line, msgid))
    print(f"  {len(strings) - len(unowed)} of them are on the bill in OWED_UNTRANSLATABLE.")

    seen = {m for _, _, m in strings}
    stale = sorted(OWED_UNTRANSLATABLE - seen)
    problems = []
    for name, line, msgid in unowed:
        problems.append(
            f"{name}:{line} shows {msgid!r} to the user through `tr`, and on Windows "
            f"`tr` returns its argument -- `build_config.i18n` is false for this "
            f"target, so the lookup is compiled out. The user reads the English."
        )
    for msgid in stale:
        problems.append(
            f"{msgid!r} is on the bill and no longer goes through `tr`. Delete the "
            f"line: a name that outlives its reason is an exemption nobody granted."
        )

    if problems:
        print()
        for p in problems:
            print(f"FAIL: {p}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
