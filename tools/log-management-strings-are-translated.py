#!/usr/bin/env python3
"""Every sentence Settings > General > Log Management shows has a Chinese
translation on both hosts, and none is drawn without going through one.

# Why

A person with a Chinese interface saw this page half in English (task 1535,
0.10.1924). Every test of the page runs in English, where an English key
*is* the text, so a string with no translation -- or one drawn straight
from a literal -- is green everywhere and English on the screen. This reads
the page's sources against the catalogues instead:

  1. mac: every `String(localized: "…")` in `LogManagement*.swift`, and the
     ones in the settings shell and the control room whose comment says
     they are this page's (`日志管理`), is in `Base.lproj` and translated in
     `zh-Hans.lproj` -- present, not empty, not the English again -- with
     the same format specifiers (`%@`, `%1$@`, `%lld`, …);
  2. Windows: every `tr("…")` and `n_("…")` in `logs_ui.rs` and the
     settings shell's `logs.rs`, and the page's name and bottom-band
     button in the shared files, has a `msgstr` in `po/zh_CN.po` that is
     not fuzzy, with the same specifiers;
  3. neither page draws an English literal of its own: no `Text("…")`,
     `Button("…")` or `Text(verbatim: "…")` on the mac but the unit "MB",
     no `draw_text`/`make_button` given a literal on Windows.

Finding no strings in any one source is a failure, not a pass: a file that
moved would otherwise leave this green with nothing checked.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAC = ROOT / "macos/Sources"
MAC_PAGE = [MAC / "Features/Settings/LogManagement.swift", MAC / "Features/Settings/LogManagementRules.swift"]
# Shared files: only the strings whose comment names this page.
MAC_SHARED = [MAC / "Features/Settings/GeneralSection.swift", MAC / "Features/Settings/GeneralRules.swift", MAC / "Features/ControlRoom/ControlRoomRetentionNotice.swift"]
BASE = MAC / "App/Base.lproj/Localizable.strings"
ZH = MAC / "App/zh-Hans.lproj/Localizable.strings"
WIN = [ROOT / "windows/host/src/logs_ui.rs", ROOT / "windows/settings-shell/src/logs.rs"]
PO = ROOT / "po/zh_CN.po"
# Shared files on Windows: the page's name and its bottom-band button,
# named here because nothing in those files marks them as this page's.
WIN_SHARED = [
    (ROOT / "windows/settings-shell/src/general.rs", 'n_("Log Management")'),
    (ROOT / "windows/host/src/general_ui.rs", 'Group::Logs => vec![(ID_REVEAL_LOGS, tr("Show in Explorer"))]'),
]

# The units a page may write as they are: the same in both languages.
VERBATIM_OK = {"MB"}

LOCALIZED = re.compile(r'String\(localized: "((?:[^"\\]|\\.)*)"(?:, comment: "((?:[^"\\]|\\.)*)")?')
SPEC = re.compile(r"%(?:\d+\$)?(?:@|lld|ld|d|s)")


def rel(p: Path) -> str:
    return str(p.relative_to(ROOT))


def strings_table(path: Path) -> dict:
    out = {}
    for m in re.finditer(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', path.read_text(), re.M):
        out[m.group(1)] = m.group(2)
    return out


def po_unquote(chunk: str) -> str:
    return "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', chunk))


def po_table(path: Path) -> dict:
    """msgid -> (msgstr, fuzzy), with continuation lines joined."""
    out = {}
    for m in re.finditer(r'((?:^#.*\n)*)^msgid ((?:".*"\n)+)^msgstr ((?:".*"\n?)+)', path.read_text(), re.M):
        out[po_unquote(m.group(2))] = (po_unquote(m.group(3)), "fuzzy" in m.group(1))
    return out


def specs(s: str) -> list:
    return sorted(SPEC.findall(s))


def main() -> int:
    for p in MAC_PAGE + MAC_SHARED + WIN + [p for p, _ in WIN_SHARED] + [BASE, ZH, PO]:
        if not p.is_file():
            print(f"FAIL: {rel(p)} is not there")
            return 1

    problems = []
    base, zh, po = strings_table(BASE), strings_table(ZH), po_table(PO)

    # 1. mac.
    mac_keys = []
    for p in MAC_PAGE:
        found = [m.group(1) for m in LOCALIZED.finditer(p.read_text())]
        if not found:
            problems.append(f"{rel(p)}: no String(localized:) found; the page moved or this check reads the wrong file")
        mac_keys += found
    for p in MAC_SHARED:
        found = [m.group(1) for m in LOCALIZED.finditer(p.read_text()) if "日志管理" in (m.group(2) or "")]
        if not found:
            problems.append(f"{rel(p)}: no String(localized:) whose comment says 日志管理; it moved or this check reads the wrong file")
        mac_keys += found
    for k in dict.fromkeys(mac_keys):
        if k not in base:
            problems.append(f'mac "{k}": not in {rel(BASE)}')
        said = zh.get(k)
        if said in (None, "", k):
            problems.append(f'mac "{k}": not translated in {rel(ZH)} ({said!r})')
        elif specs(said) != specs(k):
            problems.append(f'mac "{k}": {rel(ZH)} has {specs(said)}, the English {specs(k)}')

    # 3. mac literals that skip the table.
    for p in MAC_PAGE:
        for n, line in enumerate(p.read_text().splitlines(), 1):
            for m in re.finditer(r'\b(?:Text|Button|Label)\((verbatim: )?"((?:[^"\\]|\\.)*)"', line):
                if m.group(2) == "" or (m.group(1) and m.group(2) in VERBATIM_OK):
                    continue
                problems.append(f"{rel(p)}:{n}: draws the literal \"{m.group(2)}\" without a translation")

    # 2. Windows.
    win_ids = []
    for p in WIN:
        found = re.findall(r'\b(?:tr|n_)\("((?:[^"\\]|\\.)*)"\)', p.read_text())
        if not found:
            problems.append(f"{rel(p)}: no tr(\"…\")/n_(\"…\") found; the page moved or this check reads the wrong file")
        win_ids += found
    for p, call in WIN_SHARED:
        if call not in p.read_text():
            problems.append(f"{rel(p)}: `{call}` not found; it moved or this check reads the wrong file")
        else:
            win_ids += re.findall(r'(?:tr|n_)\("((?:[^"\\]|\\.)*)"\)', call)
    for i in dict.fromkeys(win_ids):
        said, fuzzy = po.get(i, ("", False))
        if not said:
            problems.append(f'Windows "{i}": no msgstr in {rel(PO)}')
        elif fuzzy:
            problems.append(f'Windows "{i}": the msgstr in {rel(PO)} is fuzzy, which msgfmt leaves out')
        elif specs(said) != specs(i):
            problems.append(f'Windows "{i}": {rel(PO)} has {specs(said)}, the English {specs(i)}')

    # 3. Windows literals that skip the catalogue.
    ui = WIN[0]
    for n, line in enumerate(ui.read_text().splitlines(), 1):
        for m in re.finditer(r'\b(?:draw_text\(\s*\w+,|make_button\(\s*[\w:]+,)\s*&?"((?:[^"\\]|\\.)*)"', line):
            if re.search(r"[A-Za-z]", m.group(1)) and m.group(1) not in VERBATIM_OK:
                problems.append(f"{rel(ui)}:{n}: draws the literal \"{m.group(1)}\" without a translation")

    if problems:
        for p in problems:
            print("FAIL:", p)
        return 1
    print(f"OK: Log Management's {len(set(mac_keys))} mac strings and {len(set(win_ids))} Windows msgids each have a Chinese translation with their format specifiers, and neither page draws an English literal")
    return 0


if __name__ == "__main__":
    sys.exit(main())
