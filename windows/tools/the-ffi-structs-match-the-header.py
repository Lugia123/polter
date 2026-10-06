#!/usr/bin/env python3
"""Every struct the host declares by hand has the layout `ghostty.h` has.

**Why this is a gate and not a comment.** `ffi.rs` does not come from the
header. Each `#[repr(C)]` struct in it is typed by hand, so when the header
adds, removes or reorders a field and the Rust side is not touched, `cargo`
builds the host exactly as before and the host reads every field after the
change from the wrong offset. That is what `ghostty_clipboard_content_s`
growing a `len` did in the 0.8 upstream merge (see `a4e13545a`), and it is
what adding `scrollback_restore` to `ghostty_surface_config_s` would do next.

**Two links, and each one is checked by something that cannot be talked
round:**

1. The C side is measured, not read: clang (`zig cc`, target
   `x86_64-windows-gnu`, the same compiler and target the DLL is built with)
   dumps the record layout of every paired struct. Nothing here parses C.
2. The Rust side is asserted by rustc: the numbers are written into
   `windows/host/src/ffi_layout.rs` as `offset_of!`/`size_of`/`align_of`
   asserts, which `ffi.rs` pulls in with `include!`. A Rust struct that does
   not match fails `cargo check --target x86_64-pc-windows-gnu`.

This script is the link between them: it regenerates that file from the
header and **fails when the checked-in copy differs**, i.e. when the header
changed and nobody regenerated. `--write` regenerates it; after that, cargo
says which Rust field is now wrong.

**How fields are paired: by position.** The C members are the record's
top-level members in declaration order; the Rust fields are the struct's
fields in declaration order **minus any named `_pad*`**, which stand for
padding the C compiler inserts and have no C member. A differing count is a
failure of its own, reported before any number is generated.

**Names are compared too, because positions alone cannot see a swap.** Two
same-sized members exchanged in the header leave every offset where it was,
so a Rust struct that still has them in the old order passes every layout
assert and reads each one as the other. Each Rust field must carry its C
member's name unless `RENAMED` says otherwise; the five there are the whole
list of deliberate differences today. What is still not caught: a member
whose *type* changes to another of the same size (`int32_t` to `uint32_t`).

**Coverage is default-include.** Every `#[repr(C)]` struct under
`windows/host/src/` must be in `PAIRS` or in `NOT_CHECKED` with its reason;
one in neither fails the gate. A whitelist would put the next hand-written
struct outside the check by default.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "include" / "ghostty.h"
SRC = ROOT / "windows" / "host" / "src"
OUT = SRC / "ffi_layout.rs"
TARGET = "x86_64-windows-gnu"

# (file under windows/host/src, Rust struct, path the asserts use, C typedef)
PAIRS = [
    ("ffi.rs", "LayoutOut", "LayoutOut", "ghostty_action_poltergeist_layout_out_s"),
    ("ffi.rs", "ScreenshotOut", "ScreenshotOut", "ghostty_action_poltergeist_screenshot_out_s"),
    ("ffi.rs", "PoltergeistMark", "PoltergeistMark", "ghostty_action_poltergeist_mark_s"),
    ("ffi.rs", "PersonaMark", "PersonaMark", "ghostty_poltergeist_persona_s"),
    ("ffi.rs", "PersonaRow", "PersonaRow", "ghostty_persona_s"),
    ("ffi.rs", "ClipboardContent", "ClipboardContent", "ghostty_clipboard_content_s"),
    ("ffi.rs", "ClipboardComplete", "ClipboardComplete", "ghostty_clipboard_complete_s"),
    ("ffi.rs", "ClipboardConfirm", "ClipboardConfirm", "ghostty_clipboard_confirm_s"),
    ("ffi.rs", "Target", "Target", "ghostty_target_s"),
    ("ffi.rs", "Action", "Action", "ghostty_action_s"),
    ("ffi.rs", "KeyEvent", "KeyEvent", "ghostty_input_key_s"),
    ("ffi.rs", "RuntimeConfig", "RuntimeConfig", "ghostty_runtime_config_s"),
    ("ffi.rs", "ConfigColor", "ConfigColor", "ghostty_config_color_s"),
    ("ffi.rs", "SurfaceConfig", "SurfaceConfig", "ghostty_surface_config_s"),
    ("ffi.rs", "SetTitlePayload", "SetTitlePayload", "ghostty_action_set_title_s"),
    ("ffi.rs", "GString", "GString", "ghostty_string_s"),
    ("ffi.rs", "Info", "Info", "ghostty_info_s"),
    ("ffi.rs", "Diagnostic", "Diagnostic", "ghostty_diagnostic_s"),
    ("ffi.rs", "Keybind", "Keybind", "ghostty_keybind_s"),
    ("ffi.rs", "Point", "Point", "ghostty_point_s"),
    ("ffi.rs", "Selection", "Selection", "ghostty_selection_s"),
    ("ffi.rs", "Text", "Text", "ghostty_text_s"),
    ("keys.rs", "TriggerC", "crate::keys::TriggerC", "ghostty_input_trigger_s"),
]

# (Rust struct, Rust field) -> C member, where the two names differ on purpose.
# Anything else must match by name; a stale row here is a failure too.
RENAMED = {
    ("Target", "surface"): "target",
    ("Action", "payload"): "action",
    ("SurfaceConfig", "platform_hwnd"): "platform",
    ("Selection", "tl"): "top_left",
    ("Selection", "br"): "bottom_right",
}

# Structs that are `#[repr(C)]` but not asserted here, each with the reason.
# Printed every run: an exception nobody sees is an exception nobody revisits.
NOT_CHECKED = {
    ("osk.rs", "ITipInvocationVtbl"): "a COM vtable, not from ghostty.h",
    ("shell.rs", "OsVersionInfoW"): "Win32's OSVERSIONINFOW, not from ghostty.h",
    ("palette.rs", "CommandC"):
        "mirrors ghostty_command_s but is declared inside a function, so "
        "asserts at module scope cannot name it",
    ("palette.rs", "CommandList"):
        "mirrors ghostty_config_command_list_s; function-local, as above",
    ("quick.rs", "SizeOne"):
        "mirrors ghostty_quick_terminal_size_s; function-local, as above",
    ("quick.rs", "SizeBoth"):
        "mirrors ghostty_config_quick_terminal_size_s; function-local, as above",
}


def strip_comments(s: str) -> str:
    return re.sub(r"//[^\n]*", "", s)


def split_top(s: str) -> list[str]:
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([{<":
            depth += 1
        elif ch in ")]}>":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return [x.strip() for x in out if x.strip()]


def rust_fields(text: str, name: str, errors: list[str]):
    # Comments go first: `// union { nsview | uiview | hwnd }` on a field
    # would otherwise end the body at its `}`.
    text = strip_comments(text)
    ms = list(re.finditer(r"\bstruct\s+" + name + r"\s*\{", text))
    if len(ms) != 1:
        errors.append(f"struct {name}: expected one definition, found {len(ms)}")
        return None
    body = text[ms[0].end():text.index("}", ms[0].end())]
    fields = []
    for f in split_top(body):
        f = re.sub(r"#\[[^\]]*\]", "", f).strip()
        m = re.match(r"(?:pub(?:\([^)]*\))?\s+)?(\w+)\s*:", f)
        if not m:
            errors.append(f"struct {name}: cannot read field `{f[:60]}`")
            return None
        fields.append(m.group(1))
    return fields


def repr_c_structs():
    """Every `#[repr(C)]` struct under SRC, as (file, name)."""
    found = set()
    attr = r"(?:\s*(?:#\[[^\]]*\]|///[^\n]*))*"
    # `repr(C, align(8))` counts too: that is the spelling `Action` needs.
    pat = re.compile(r"#\[repr\(C(?:\s*,[^\]]*)?\)\]" + attr + r"\s*(?:pub(?:\([^)]*\))?\s+)?struct\s+(\w+)")
    for p in sorted(SRC.glob("*.rs")):
        if p == OUT:
            continue
        for m in pat.finditer(p.read_text(encoding="utf-8")):
            found.add((p.name, m.group(1)))
    return found


def c_layouts(names: list[str], errors: list[str]):
    zig = shutil.which("zig")
    if zig is None:
        errors.append("zig is not on PATH; the C side cannot be measured")
        return None
    with tempfile.TemporaryDirectory() as d:
        probe = Path(d) / "probe.c"
        lines = ['#include "ghostty.h"']
        lines += [f"int layout_probe_{i} = sizeof({n});" for i, n in enumerate(names)]
        probe.write_text("\n".join(lines) + "\n", encoding="utf-8")
        p = subprocess.run(
            # `-c -o`, not `-fsyntax-only`: clang dumps the layouts either
            # way, but zig then looks for the object file it was not given
            # and fails the run with `FileNotFound` after a complete dump.
            [zig, "cc", "-target", TARGET, "-c", "-o", str(Path(d) / "probe.o"),
             "-Xclang", "-fdump-record-layouts", "-I", str(HEADER.parent), str(probe)],
            capture_output=True, text=True)
    if p.returncode != 0:
        errors.append("clang could not lay out the header:\n" + p.stderr.strip()[-2000:])
        return None
    out = {}
    for block in p.stdout.split("*** Dumping AST Record Layout"):
        lines = block.strip("\n").splitlines()
        if not lines:
            continue
        head = re.match(r"^\s*0 \| (\S+)$", lines[0])
        if not head or head.group(1) not in names or head.group(1) in out:
            continue
        members, size, align = [], None, None
        for l in lines[1:]:
            m = re.match(r"^\s*(\d+) \|   (\S.*)$", l)
            if m:
                members.append((m.group(2).split()[-1].lstrip("*"), int(m.group(1))))
                continue
            m = re.search(r"\[sizeof=(\d+), align=(\d+)", l)
            if m:
                size, align = int(m.group(1)), int(m.group(2))
                break
        out[head.group(1)] = (members, size, align)
    for n in names:
        if n not in out or out[n][1] is None:
            errors.append(f"{n}: no record layout in clang's dump")
    return out


def generate(rows) -> str:
    lines = [
        "// @generated by windows/tools/the-ffi-structs-match-the-header.py -- do not edit.",
        "// Regenerate with `python3 windows/tools/the-ffi-structs-match-the-header.py --write`,",
        "// then `cargo check --target x86_64-pc-windows-gnu` says which Rust field is wrong.",
        f"// Every number is clang's layout of include/ghostty.h for {TARGET}.",
        "// Included by ffi.rs so that private structs and fields are in scope.",
        "// One `const` per assert: const evaluation stops at the first panic in a",
        "// block, and a gate that names one mismatch per build hides the others.",
    ]
    for path, cname, pairs, size, align in rows:
        lines.append("")
        lines.append(f"// {path} <- {cname}")
        lines.append(f'const _: () = assert!(std::mem::size_of::<{path}>() == {size}, "size of {path} != sizeof({cname})");')
        lines.append(f'const _: () = assert!(std::mem::align_of::<{path}>() == {align}, "align of {path} != alignof({cname})");')
        for rf, cf, off in pairs:
            lines.append(
                f'const _: () = assert!(std::mem::offset_of!({path}, {rf}) == {off}, "{path}.{rf} is not at {cname}.{cf}");')
    return "\n".join(lines) + "\n"


def main() -> int:
    write = "--write" in sys.argv[1:]
    errors: list[str] = []
    if not HEADER.is_file() or not (SRC / "ffi.rs").is_file():
        print(f"FAIL: missing {HEADER if not HEADER.is_file() else SRC / 'ffi.rs'}")
        return 1

    # Coverage first: a struct this gate has never heard of is the case it
    # exists for.
    declared = repr_c_structs()
    paired = {(f, r) for f, r, _, _ in PAIRS}
    for fr in sorted(declared - paired - set(NOT_CHECKED)):
        errors.append(f"{fr[0]}: `#[repr(C)] struct {fr[1]}` is neither in PAIRS nor in NOT_CHECKED")
    for fr in sorted((paired | set(NOT_CHECKED)) - declared):
        errors.append(f"{fr[0]}: `{fr[1]}` is listed here but no longer declared `#[repr(C)]` there")
    for (f, r), why in sorted(NOT_CHECKED.items()):
        print(f"not checked  {f}:{r} -- {why}")

    layouts = c_layouts([c for _, _, _, c in PAIRS], errors)
    rows = []
    used_renames = set()
    if layouts is not None:
        texts = {}
        for f, rname, path, cname in PAIRS:
            if f not in texts:
                texts[f] = (SRC / f).read_text(encoding="utf-8")
            rf = rust_fields(texts[f], rname, errors)
            if rf is None or cname not in layouts:
                continue
            members, size, align = layouts[cname]
            real = [x for x in rf if not x.startswith("_pad")]
            if len(real) != len(members):
                errors.append(
                    f"MISMATCH {f}:{rname} has {len(real)} fields ({', '.join(real)}); "
                    f"{cname} has {len(members)} ({', '.join(m for m, _ in members)})")
                continue
            pairs = [(r, m, off) for r, (m, off) in zip(real, members)]
            named = [(r, m) for r, m, _ in pairs if RENAMED.get((rname, r), r) != m]
            if named:
                errors.append(
                    f"MISMATCH {f}:{rname} field names differ from {cname} by position: "
                    + ", ".join(f"{r} vs {m}" for r, m in named)
                    + " (reordered in one of them, or a rename RENAMED does not list)")
                continue
            used_renames.update((rname, r) for r, _, _ in pairs if (rname, r) in RENAMED)
            rows.append((path, cname, pairs, size, align))
            print(f"paired       {f}:{rname} <- {cname}: {len(real)} fields, size {size}, align {align}")

    if len(rows) == len(PAIRS):
        for k in sorted(set(RENAMED) - used_renames):
            errors.append(f"RENAMED lists {k[0]}.{k[1]}, which is no longer a paired field")
    print(f"paired {len(rows)} of {len(PAIRS)} structs; "
          f"{len(declared)} `#[repr(C)]` structs declared under windows/host/src")
    if errors:
        for e in errors:
            print("FAIL: " + e)
        return 1
    if not rows or len(rows) != len(PAIRS):
        print("FAIL: not every pair was compared")
        return 1

    want = generate(rows)
    if write:
        OUT.write_text(want, encoding="utf-8")
        print(f"wrote {OUT.relative_to(ROOT)} ({want.count('assert!')} asserts)")
        return 0
    have = OUT.read_text(encoding="utf-8") if OUT.is_file() else ""
    if have != want:
        print(f"FAIL: {OUT.relative_to(ROOT)} does not match include/ghostty.h; "
              f"rerun with --write, then cargo check --target x86_64-pc-windows-gnu")
        return 1
    print(f"ok: {OUT.relative_to(ROOT)} matches the header ({want.count('assert!')} asserts)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
