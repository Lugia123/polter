#!/usr/bin/env python3
"""The core's names for "why a change could not be read", the Mac's and Windows' agree.

# Why this exists (task 1514)

The role library showed the core's English sentence in a Chinese interface:
"Your changes weren't read: this copy was not saved from Polter, ...". The
core now writes, beside each sentence, a name for it (`official.WhyCode` in
`src/poltergeist/official.zig`) and the window says the named sentence in
the person's language (`OfficialWhy` in
`macos/Sources/Features/Roles/OfficialWhy.swift`).

**A name on one side only fails silently.** The window falls back to the
core's English for a name it does not know -- correctly, since an older
window may meet a newer core -- so a reason added to the core and not to
the window shows in English again, with nothing anywhere saying so. That is
the defect this task fixed, coming back one case at a time.

The Windows window does the same since task 1507 (`Why` in
`windows/settings-shell/src/official.rs`), with the same fallback, so the
same silence.

So: the set of names in the Zig enum, the set of raw values in the Swift
enum and the set of codes in the Rust enum must be equal.

# NOT CHECKED

- That a sentence says the same thing on every side; only that each has it.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ZIG = ROOT / "src" / "poltergeist" / "official.zig"
SWIFT = ROOT / "macos" / "Sources" / "Features" / "Roles" / "OfficialWhy.swift"
RUST = ROOT / "windows" / "settings-shell" / "src" / "official.rs"

ZIG_ENUM = re.compile(r"pub const WhyCode = enum \{(.*?)\};", re.S)
ZIG_CASE = re.compile(r"^\s*([a-z_]+),\s*$", re.M)
SWIFT_CASE = re.compile(r'^\s*case\s+\w+\s*=\s*"([a-z_]+)"\s*$', re.M)
# `Why::code`: one `Why::X => "x",` per line. The sentences are `n_("...")`
# and do not match.
RUST_FN = re.compile(r"pub fn code\(self\) -> &'static str \{(.*?)\n    \}", re.S)
RUST_CASE = re.compile(r'^\s*Why::\w+\s*=>\s*"([a-z_]+)",\s*$', re.M)


def zig_names(text: str) -> set[str]:
    m = ZIG_ENUM.search(text)
    return set(ZIG_CASE.findall(m.group(1))) if m else set()


def swift_names(text: str) -> set[str]:
    return set(SWIFT_CASE.findall(text))


def rust_names(text: str) -> set[str]:
    m = RUST_FN.search(text)
    return set(RUST_CASE.findall(m.group(1))) if m else set()


def self_test() -> None:
    z = "pub const WhyCode = enum {\n    a_b,\n    c,\n};\n"
    assert zig_names(z) == {"a_b", "c"}, zig_names(z)
    s = 'enum X: String {\n    case aB = "a_b"\n    case c = "c"\n    case notOne = 3\n}\n'
    assert swift_names(s) == {"a_b", "c"}, swift_names(s)
    assert zig_names("const X = enum { a };") == set()
    r = ("    pub fn code(self) -> &'static str {\n        match self {\n"
         "            Why::AB => \"a_b\",\n            Why::C => \"c\",\n        }\n    }\n"
         "    pub fn msgid(self) -> &'static str {\n            Why::AB => n_(\"x\"),\n    }\n")
    assert rust_names(r) == {"a_b", "c"}, rust_names(r)
    print("probe self-test: OK")


def main() -> int:
    self_test()
    zig = zig_names(ZIG.read_text(encoding="utf-8")) if ZIG.is_file() else set()
    swift = swift_names(SWIFT.read_text(encoding="utf-8")) if SWIFT.is_file() else set()
    rust = rust_names(RUST.read_text(encoding="utf-8")) if RUST.is_file() else set()
    # A check that read nothing on either side agrees with everything.
    if not zig:
        print(f"FAIL: no `WhyCode` names read from {ZIG.relative_to(ROOT)}")
        return 1
    if not swift:
        print(f"FAIL: no `OfficialWhy` cases read from {SWIFT.relative_to(ROOT)}")
        return 1
    if not rust:
        print(f"FAIL: no `Why::code` names read from {RUST.relative_to(ROOT)}")
        return 1
    problems = []
    for name in sorted(zig - swift):
        problems.append(f"{name}: the core names it and the Mac window does not -- "
                        "it will show in English in a Chinese interface")
    for name in sorted(swift - zig):
        problems.append(f"{name}: the Mac window knows it and the core never writes it")
    for name in sorted(zig - rust):
        problems.append(f"{name}: the core names it and the Windows window does not -- "
                        "it will show in English in a Chinese interface")
    for name in sorted(rust - zig):
        problems.append(f"{name}: the Windows window knows it and the core never writes it")
    if problems:
        print("FAIL: the reasons a change could not be read disagree between the core and a window:")
        for p in problems:
            print("      " + p)
        return 1
    print(f"ok: {len(zig)} reasons, the same names in the core, the Mac window and the Windows window")
    return 0


if __name__ == "__main__":
    sys.exit(main())
