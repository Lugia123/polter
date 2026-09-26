#!/usr/bin/env python3
"""Every enum constant the host writes out by hand has the value `ghostty.h` has.

**Why this exists.** `the-ffi-structs-match-the-header.py` holds the hand-
typed *structs* in `windows/host/src` to the header. Nothing held the hand-
typed *constants*: `pub const BINDING_PERFORMABLE: u8 = 1 << 3;` is a number
somebody copied out of an enum. When issue #30 added
`GHOSTTY_BINDING_FLAGS_MENU = 1 << 4` to the header, deleting the Rust
mirror of it entirely left the struct gate exiting 0 with the same reading
to the character -- because it looks at layouts, and a new enumerator
changes no layout. A mirror that is missing, or present with the wrong
value, compiles on both sides and quietly means something else.

# What it checks

1. **Values, measured.** For every Rust `const` that mirrors a header
   enumerator, clang (`zig cc`, target `x86_64-windows-gnu`, the target the
   DLL is built for) is handed `_Static_assert(ENUMERATOR == rust_value)`.
   The C side is computed by the compiler, never read: most of these
   enumerators have no written value at all and are numbered by position.
   A right name with a wrong value -- `1 << 4` becoming `1 << 5` -- is the
   dangerous case, and it is exactly what this assertion catches.
2. **Completeness, where it is promised.** An enum in `COMPLETE` is mirrored
   whole: an enumerator the header gains must get a Rust mirror, or the
   enum must move to `PARTIAL` with a reason. An enum in `PARTIAL` is
   mirrored only as far as the host uses it; there, only what is mirrored
   is checked.
3. **Nothing extra.** A Rust const in a mirror family (same file, same
   prefix as consts that do match) that matches no enumerator fails: a typo,
   or a mirror of something the header no longer has. This is how
   `KEY_RELEASE/PRESS/REPEAT` in `ffi.rs` were found -- mirrors of
   `GHOSTTY_ACTION_*` under another name that nothing had checked.
4. **Every mirrored enum is classified.** An enum with a Rust mirror that is
   in neither `COMPLETE` nor `PARTIAL` fails -- someone has to decide.

How names pair: a Rust const `X` mirrors `GHOSTTY_X`, unless `RENAMED` says
otherwise.

# NOT CHECKED -- written here for people, not as a condition that passes

- Struct layouts: that is `the-ffi-structs-match-the-header.py`.
- Function signatures (argument types, return types, calling convention):
  nothing checks those. `the-clipboard-abi-matches-the-header.py` covers one.
- Swift. The macOS app imports `ghostty.h` directly, so every value it uses
  comes from the compiler and cannot drift; an enumerator Swift simply never
  names (e.g. an `OptionSet` member not added) is not a wrong value, and
  nothing here looks for it.
- The Zig side of the header (the enums are kept in step with Zig by hand;
  `Binding.Flags.cval`'s test covers the binding flags only).
- A mirror written as anything but a literal or `a << b`: it fails as
  unreadable rather than being skipped.
- Consts outside a mirror family that happen to mean a header value.
"""

import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
HEADER = ROOT / "include" / "ghostty.h"
SRC = ROOT / "windows" / "host" / "src"
TARGET = "x86_64-windows-gnu"

# (file, rust name) -> header enumerator, for mirrors that don't spell
# themselves GHOSTTY_ + their own name.
RENAMED = {
    ("ffi.rs", "BINDING_CONSUMED"): "GHOSTTY_BINDING_FLAGS_CONSUMED",
    ("ffi.rs", "BINDING_ALL"): "GHOSTTY_BINDING_FLAGS_ALL",
    ("ffi.rs", "BINDING_GLOBAL"): "GHOSTTY_BINDING_FLAGS_GLOBAL",
    ("ffi.rs", "BINDING_PERFORMABLE"): "GHOSTTY_BINDING_FLAGS_PERFORMABLE",
    ("ffi.rs", "BINDING_MENU"): "GHOSTTY_BINDING_FLAGS_MENU",
    ("keys.rs", "BINDING_FLAG_PERFORMABLE"): "GHOSTTY_BINDING_FLAGS_PERFORMABLE",
    ("ffi.rs", "KEY_RELEASE"): "GHOSTTY_ACTION_RELEASE",
    ("ffi.rs", "KEY_PRESS"): "GHOSTTY_ACTION_PRESS",
    ("ffi.rs", "KEY_REPEAT"): "GHOSTTY_ACTION_REPEAT",
}

# Mirrored whole, across all of windows/host/src.
COMPLETE = {
    "ghostty_binding_flags_e",
    "ghostty_action_tag_e",
    "ghostty_action_goto_tab_e",
    "ghostty_action_inspector_e",
    "ghostty_action_progress_report_state_e",
    "ghostty_action_quit_timer_e",
    "ghostty_action_secure_input_e",
    "ghostty_clipboard_read_result_e",
    "ghostty_clipboard_request_e",
    "ghostty_input_action_e",
    "ghostty_input_mods_e",
    "ghostty_input_mouse_state_e",
    "ghostty_input_trigger_tag_e",
    "ghostty_point_tag_e",
    "ghostty_target_tag_e",
}

# Mirrored only as far as the host uses them.
PARTIAL = {
    "ghostty_input_key_e": "the host names the keys it translates or tests for, not all 176",
    "ghostty_input_mouse_button_e": "the host sends left/right/middle and 'unknown'; the rest have no Windows source",
    "ghostty_platform_e": "a Windows host only ever says it is WIN32",
    "ghostty_clipboard_e": "the host has no primary selection to name",
}

CONST = re.compile(r"^\s*(?:pub(?:\([a-z]+\))?\s+)?const\s+([A-Z][A-Z0-9_]+)\s*:\s*[\w:]+\s*=\s*([^;]+);", re.M)
LITERAL = re.compile(r"-?(?:0x[0-9a-fA-F_]+|\d[\d_]*)")
SHIFT = re.compile(r"(\d+)\s*<<\s*(\d+)")


def header_enums(text):
    """enumerator -> enum name, from `typedef enum { ... } name;` blocks."""
    out = {}
    for m in re.finditer(r"typedef enum\s*\{(.*?)\}\s*(\w+)\s*;", text, re.S):
        body = re.sub(r"//[^\n]*", "", m.group(1))
        for name in re.findall(r"^\s*(GHOSTTY_[A-Z0-9_]+)\s*(?:=|,|$)", body, re.M):
            out[name] = m.group(2)
    return out


def rust_value(expr):
    expr = expr.strip()
    if LITERAL.fullmatch(expr):
        return int(expr.replace("_", ""), 0)
    m = SHIFT.fullmatch(expr)
    if m:
        return int(m.group(1)) << int(m.group(2))
    return None


def family_prefix(names):
    p = os.path.commonprefix(names)
    return p[: p.rfind("_") + 1] if "_" in p else ""


def main():
    problems = []
    try:
        enums = header_enums(HEADER.read_text(encoding="utf-8"))
    except OSError as e:
        print(f"FAIL: cannot read {HEADER}: {e}")
        return 1

    mirrors = []  # (file, rust name, enumerator, value)
    per_file_consts = {}
    for path in sorted(glob.glob(str(SRC / "*.rs"))):
        fname = os.path.basename(path)
        consts = CONST.findall(Path(path).read_text(encoding="utf-8"))
        per_file_consts[fname] = consts
        for name, expr in consts:
            c = RENAMED.get((fname, name)) or ("GHOSTTY_" + name if "GHOSTTY_" + name in enums else None)
            if c is None:
                continue
            if c not in enums:
                problems.append(f"{fname}: {name} is mapped to {c}, which the header doesn't have")
                continue
            v = rust_value(expr)
            if v is None:
                problems.append(f"{fname}: {name} = {expr.strip()} -- not a literal or `a << b`, so it can't be checked; write it as one")
                continue
            mirrors.append((fname, name, c, v))

    if not mirrors:
        print(f"FAIL: found no Rust mirror of any {HEADER.name} enumerator under {SRC} -- nothing was checked")
        return 1

    # 3. extras: consts in a mirror family that match nothing.
    for fname, consts in per_file_consts.items():
        by_enum = {}
        for f, n, c, _ in mirrors:
            if f == fname:
                by_enum.setdefault(enums[c], []).append(n)
        prefixes = {family_prefix(ns) for ns in by_enum.values()} - {""}
        mirrored = {n for f, n, _, _ in mirrors if f == fname}
        for name, _ in consts:
            if name not in mirrored and any(name.startswith(p) for p in prefixes):
                problems.append(f"{fname}: {name} looks like a mirror (prefix {next(p for p in prefixes if name.startswith(p))}) but matches no enumerator in {HEADER.name} -- a typo, a rename RENAMED doesn't know, or something the header dropped")

    # 4. classification, and 2. completeness.
    touched = {enums[c] for _, _, c, _ in mirrors}
    for e in sorted(touched - COMPLETE - set(PARTIAL)):
        problems.append(f"{e}: has Rust mirrors but is in neither COMPLETE nor PARTIAL -- decide which")
    for e in sorted(COMPLETE):
        want = {n for n, en in enums.items() if en == e}
        if not want:
            problems.append(f"{e}: in COMPLETE but not in {HEADER.name}")
            continue
        have = {c for _, _, c, _ in mirrors if enums[c] == e}
        for missing in sorted(want - have):
            problems.append(f"{e}: {missing} has no Rust mirror, and this enum is mirrored whole (COMPLETE)")

    # 1. values, by the compiler.
    zig = shutil.which("zig")
    if zig is None:
        problems.append("zig is not on PATH -- the values were not checked")
    else:
        with tempfile.TemporaryDirectory() as d:
            probe = Path(d) / "probe.c"
            lines = [f'#include "{HEADER.name}"']
            for i, (f, n, c, v) in enumerate(mirrors):
                lines.append(f'_Static_assert((long long)({c}) == (long long)({v}LL), "MIRROR {i}");')
            probe.write_text("\n".join(lines) + "\n")
            p = subprocess.run(
                # `-c -o`, not `-fsyntax-only`: zig cc answers the latter with
                # a spurious FileNotFound (same note as the struct gate's).
                [zig, "cc", "-target", TARGET, "-c", "-o", str(Path(d) / "probe.o"),
                 "-I", str(HEADER.parent), str(probe)],
                capture_output=True, text=True)
            failed = sorted({int(x) for x in re.findall(r"MIRROR (\d+)", p.stderr)})
            # clang follows each failure with "expression evaluates to
            # 'C == RUST'" on the same probe line; line N holds mirror N-2.
            actual = {int(line) - 2: c_val for line, c_val in re.findall(
                r"probe\.c:(\d+):\d+: note: expression evaluates to '(-?\d+) == ", p.stderr)}
            for i in failed:
                f, n, c, v = mirrors[i]
                says = actual.get(i, "something else")
                problems.append(f"{f}: {n} = {v}, but {c} is {says} in {HEADER.name} (by clang)")
            if p.returncode != 0 and not failed:
                problems.append("clang failed on the probe for another reason:\n" + p.stderr.strip()[-1500:])

    if problems:
        print("FAIL: the host's hand-written copies of ghostty.h enum constants disagree with it:")
        for x in problems:
            print(f"      {x}")
        return 1

    files = sorted({f for f, _, _, _ in mirrors})
    print(f"checked {len(mirrors)} mirrors of {len(touched)} enums in {len(files)} files ({', '.join(files)}) against {HEADER.name}, values by clang ({TARGET})")
    print(f"      complete: {len(COMPLETE)} enums; partial: {len(PARTIAL)} ({', '.join(sorted(PARTIAL))})")
    print("NOT CHECKED: struct layouts (the-ffi-structs gate), function signatures, Swift (imports the header), the Zig side of the header.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
