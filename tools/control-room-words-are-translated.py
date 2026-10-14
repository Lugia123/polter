#!/usr/bin/env python3
"""Every word the control room draws beside a glyph has a translation on
both hosts, and the core writes none of them in a language of its own.

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
     `zh-Hans.lproj` (with Chinese in it), and has a `msgstr` in
     `po/zh_CN.po`;
  2. `Word.text` and `held_text` hold no CJK literal: the words are said by
     the hosts, not by the core.

Finding no words at all is a failure, not a pass: a table that moved or was
renamed would otherwise leave this green with nothing checked.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TABLE = ROOT / "src/poltergeist/Attention.zig"
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
    for p in (TABLE, BASE, ZH, PO):
        if not p.is_file():
            print(f"FAIL: {p.relative_to(ROOT)} is not there")
            return 1
    src = TABLE.read_text()
    words = re.findall(r'i18n\.N_\("([^"]+)"\)', src)
    if not words:
        print(f"FAIL: no N_(\"…\") words found in {TABLE.relative_to(ROOT)}; the table moved or this check is reading the wrong file")
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

    # 1. Both hosts can say each one.
    base, zh, po = strings_table(BASE), strings_table(ZH), po_table(PO)
    for w in words:
        if w not in base:
            problems.append(f'"{w}": not in {BASE.relative_to(ROOT)}')
        if not CJK.search(zh.get(w, "")):
            problems.append(f'"{w}": no Chinese for it in {ZH.relative_to(ROOT)} ({zh.get(w)!r})')
        if not po.get(w):
            problems.append(f'"{w}": no msgstr in {PO.relative_to(ROOT)}')

    if problems:
        for p in problems:
            print("FAIL:", p)
        return 1
    print(f"OK: {len(words)} control-room words, each translated on both hosts; the core writes none in Chinese")
    return 0


if __name__ == "__main__":
    sys.exit(main())
