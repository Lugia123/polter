#!/usr/bin/env python3
"""Every word the control room draws beside a glyph, and every sentence of
the core's own under a row's name, has a translation on both hosts, and the
core writes none of them in a language of its own.

# Why

The core picks the words beside each glyph ("Awaiting approval",
"Working", "Held") in `src/poltergeist/Attention.zig`. Until task 1522 it
wrote them as Chinese literals, and both hosts drew whatever it wrote: an
English window said 无人看管 on a group's row (the tenth mac run found that
one; all twelve were the same). The core does not know the person's
language, so it now writes English msgids, marked `N_`, and each host says
them in the person's language -- the mac app from `Localizable.strings`,
Windows from `po/`.

That moves the failure, it does not end it: a word added to the table and
to neither host's catalogue is drawn as its English msgid in a Chinese
window, and nothing anywhere says so. A test on either host cannot see it
-- each runs in English, where the msgid *is* the word. So this checks the
catalogues against the table instead:

  1. every `N_("…")` in `Attention.zig` is in `Base.lproj` and in
     `zh-Hans.lproj` (translated: not missing, empty or the English
     again), and has a `msgstr` in `po/zh_CN.po`;
  2. `Word.text` and `held_text` hold no CJK literal: the words are said by
     the hosts, not by the core.

The same holds for the sentences under a row's name that the core writes
itself ("The process exited", "Screen still for {1} min"; task 1525): they
are templates in `ControlRoom.zig`'s `Say.templateOf`, marked `N_`, with
`{N}` where the arguments go, and both checks cover them -- a translation
must also keep every `{N}` the English has, or an argument would vanish.

Finding no words at all is a failure, not a pass: a table that moved or was
renamed would otherwise leave this green with nothing checked.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TABLE = ROOT / "src/poltergeist/Attention.zig"
SENTENCES = ROOT / "src/poltergeist/ControlRoom.zig"
BASE = ROOT / "macos/Sources/App/Base.lproj/Localizable.strings"
ZH = ROOT / "macos/Sources/App/zh-Hans.lproj/Localizable.strings"
PO = ROOT / "po/zh_CN.po"

CJK = re.compile(r"[㐀-鿿]")


def strings_table(path: Path) -> dict:
    out = {}
    for m in re.finditer(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', path.read_text(), re.M):
        out[m.group(1)] = m.group(2)
    return out


def po_table(path: Path) -> dict:
    out = {}
    for m in re.finditer(r'^msgid "((?:[^"\\]|\\.)*)"\nmsgstr "((?:[^"\\]|\\.)*)"$', path.read_text(), re.M):
        out[m.group(1)] = m.group(2)
    return out


def main() -> int:
    for p in (TABLE, SENTENCES, BASE, ZH, PO):
        if not p.is_file():
            print(f"FAIL: {p.relative_to(ROOT)} is not there")
            return 1
    src = TABLE.read_text()
    words = re.findall(r'i18n\.N_\("([^"]+)"\)', src)
    if not words:
        print(f"FAIL: no N_(\"…\") words found in {TABLE.relative_to(ROOT)}; the table moved or this check is reading the wrong file")
        return 1
    sentences_src = SENTENCES.read_text()
    tmpl = re.search(r"pub fn templateOf\(key: Key\)[^{]*\{(.*?)\n    \}", sentences_src, re.S)
    if not tmpl:
        print(f"FAIL: `Say.templateOf` not found in {SENTENCES.relative_to(ROOT)}; it moved or this check is reading the wrong file")
        return 1
    sentences = re.findall(r'i18n\.N_\("([^"]+)"\)', tmpl.group(1))
    if not sentences:
        print(f"FAIL: no N_(\"…\") templates in `Say.templateOf`")
        return 1

    problems = []

    # 2. No language of the core's own in the words it picks.
    fn = re.search(r"pub fn text\(self: Word\)[^{]*\{(.*?)\n    \}", src, re.S)
    if not fn:
        problems.append("Attention.zig: `pub fn text(self: Word)` not found")
    elif CJK.search(re.sub(r"//.*", "", fn.group(1))):  # its 暂定 comments are not words
        problems.append("Attention.zig: Word.text writes a CJK literal; write an English msgid in N_ and translate it on both hosts")
    held = re.search(r"pub const held_text = (.*);", src)
    if not held:
        problems.append("Attention.zig: `held_text` not found")
    elif CJK.search(re.sub(r"//.*", "", held.group(1))):
        problems.append("Attention.zig: held_text is a CJK literal")
    if CJK.search(re.sub(r"//.*", "", tmpl.group(1))):
        problems.append("ControlRoom.zig: Say.templateOf writes a CJK literal; write an English msgid in N_ and translate it on both hosts")

    # 1. Both hosts can say each one.
    base, zh, po = strings_table(BASE), strings_table(ZH), po_table(PO)
    for w in words + sentences:
        if w not in base:
            problems.append(f'"{w}": not in {BASE.relative_to(ROOT)}')
        # Translated, not copied: "{1}: {2}" is "{1}：{2}", which has no
        # Chinese character in it and is still a translation.
        if zh.get(w) in (None, "", w):
            problems.append(f'"{w}": not translated in {ZH.relative_to(ROOT)} ({zh.get(w)!r})')
        if not po.get(w):
            problems.append(f'"{w}": no msgstr in {PO.relative_to(ROOT)}')
        # Every argument the English takes, each translation keeps.
        want = sorted(set(re.findall(r"\{[1-9]\}", w)))
        for where, said in ((ZH, zh.get(w, "")), (PO, po.get(w, ""))):
            if said and sorted(set(re.findall(r"\{[1-9]\}", said))) != want:
                problems.append(f'"{w}": the translation in {where.relative_to(ROOT)} has {sorted(set(re.findall(r"[{][1-9][}]", said)))}, the English {want}')

    if problems:
        for p in problems:
            print("FAIL:", p)
        return 1
    print(f"OK: {len(words)} control-room words and {len(sentences)} sentences, each translated on both hosts with its arguments; the core writes none in Chinese")
    return 0


if __name__ == "__main__":
    sys.exit(main())
