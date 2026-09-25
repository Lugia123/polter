#!/usr/bin/env python3
"""The clipboard entry points the host writes by hand must match ghostty.h.

**Written because this mismatch is silent everywhere else.** `ffi.rs` does not
come from the header: every `extern "C" fn` type in it is typed by hand, and
`ghostty_surface_complete_clipboard_request` is resolved from the DLL by name.
So when the header changes a signature and keeps the name, `cargo` compiles
the host as before and the host calls the new function with the old argument
list. Nothing goes red; the paste just does the wrong thing at run time.

The case that prompted it (the 0.8 upstream merge): upstream changed
`read_clipboard_cb` from `bool` to `ghostty_clipboard_read_result_e`, where
`STARTED = 0`. A host still returning `bool` answers "started" when it has no
text and "unavailable" when it has -- exactly inverted -- and ctrl+v breaks.

What is compared, per entry point: **the argument count, each argument's
type, and the kind of the return value** (`void` / `bool` / an integer-like
enum). Argument types go through `C_TO_RS`, a table of the C spellings this
ABI uses and the Rust spelling each one must have. **A C type missing from
the table fails the gate** rather than passing: upstream's other change to
`confirm_read_clipboard_cb` kept the count at four and only turned
`const char*` into `const ghostty_clipboard_confirm_s*`, which a count alone
cannot see. Parameter names in the header are ignored.

Also compared: **the field count of `ghostty_clipboard_content_s`** against
the host's `ClipboardContent`. `write_clipboard_cb` hands the host an *array*
of these, so an extra field in the header changes the stride and every
element after the first is read from the wrong place.

`ghostty_surface_deny_clipboard_request` is compared the same way as
`complete`, since it too is resolved by name. And the field counts of
`ghostty_clipboard_complete_s` / `ghostty_clipboard_confirm_s` against
`ClipboardComplete` / `ClipboardConfirm`: those are read through a pointer,
so a missing field moves every field after it. **Field types and order are
not compared** -- only the count.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "include" / "ghostty.h"
FFI = ROOT / "windows" / "host" / "src" / "ffi.rs"


def split_args(s: str) -> list[str]:
    """Top-level comma split; `void` alone means no arguments."""
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([{<":
            depth += 1
        elif ch in ")]}>":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    if out == ["void"]:
        return []
    return out


# C spelling (whitespace removed, parameter name stripped) -> Rust spelling.
# Add a row only after checking the Rust side really has that layout.
C_TO_RS = {
    "void*": "*mut c_void",
    "constchar*": "*const c_char",
    "ghostty_surface_t": "Surface",
    "ghostty_clipboard_e": "u32",
    "ghostty_clipboard_request_e": "u32",
    "bool": "bool",
    "size_t": "usize",
    "constchar*const*": "*const *const c_char",
    "constghostty_clipboard_confirm_s*": "*const ClipboardConfirm",
    "constghostty_clipboard_complete_s*": "*const ClipboardComplete",
}


def c_type(arg: str) -> str:
    """`const char* name` -> `constchar*`; unnamed args pass through."""
    t = re.sub(r"\s+", " ", arg.strip())
    m = re.match(r"^(.*?[\*\s])(\w+)$", t)
    if m and m.group(1).strip() and m.group(2) not in C_TO_RS and not m.group(2).endswith(("_t", "_e", "_s")):
        t = m.group(1)
    return t.replace(" ", "")


def rs_type(arg: str) -> str:
    t = re.sub(r"\s+", " ", arg.strip())
    if ":" in t and not t.startswith("*"):
        t = t.split(":", 1)[1].strip()
    return t


def ret_kind_c(ret: str) -> str:
    ret = ret.strip()
    if ret == "void":
        return "void"
    if ret == "bool":
        return "bool"
    if ret.endswith("_e") or ret in ("int", "int32_t", "uint32_t", "uintptr_t"):
        return "int"
    return "other:" + ret


def ret_kind_rs(ret: str | None) -> str:
    if ret is None:
        return "void"
    ret = ret.strip()
    if ret == "bool":
        return "bool"
    if ret in ("i32", "u32", "c_int", "c_uint", "usize"):
        return "int"
    return "other:" + ret


# Four entry points and three structs. A shape whose regex stops matching
# is an error of its own (`one`), and this total catches it being skipped.
TOTAL = 7


def one(pattern: str, text: str, what: str, errors: list[str]):
    ms = list(re.finditer(pattern, text, re.S))
    if len(ms) != 1:
        errors.append(f"{what}: expected exactly one definition, found {len(ms)}")
        return None
    return ms[0]


def main() -> int:
    errors: list[str] = []
    if not HEADER.is_file() or not FFI.is_file():
        print(f"FAIL: missing {HEADER if not HEADER.is_file() else FFI}")
        return 1
    h = HEADER.read_text(encoding="utf-8")
    r = FFI.read_text(encoding="utf-8")
    for name, text in (("ghostty.h", h), ("ffi.rs", r)):
        if re.search(r"^(<<<<<<<|>>>>>>>) ", text, re.M):
            errors.append(f"{name} still has conflict markers")

    # (label, header regex -> (ret, args), rust regex -> (args, ret?))
    entries = [
        (
            "read_clipboard_cb",
            r"typedef\s+(\w+)\s*\(\*ghostty_runtime_read_clipboard_cb\)\s*\((.*?)\)\s*;",
            r"pub type ReadClipboardCb\s*=\s*extern \"C\" fn\((.*?)\)\s*(?:->\s*([\w:]+))?\s*;",
        ),
        (
            "confirm_read_clipboard_cb",
            r"typedef\s+(\w+)\s*\(\*ghostty_runtime_confirm_read_clipboard_cb\)\s*\((.*?)\)\s*;",
            r"pub type ConfirmReadClipboardCb\s*=\s*extern \"C\" fn\((.*?)\)\s*(?:->\s*([\w:]+))?\s*;",
        ),
        (
            "ghostty_surface_complete_clipboard_request",
            r"GHOSTTY_API\s+(\w+)\s+ghostty_surface_complete_clipboard_request\s*\((.*?)\)\s*;",
            r"pub surface_complete_clipboard_request:\s*unsafe extern \"C\" fn\((.*?)\)\s*(?:->\s*([\w:]+))?\s*,",
        ),
        (
            "ghostty_surface_deny_clipboard_request",
            r"GHOSTTY_API\s+(\w+)\s+ghostty_surface_deny_clipboard_request\s*\((.*?)\)\s*;",
            r"pub surface_deny_clipboard_request:\s*unsafe extern \"C\" fn\((.*?)\)\s*(?:->\s*([\w:]+))?\s*,",
        ),
    ]
    checked = 0
    for label, hre, rre in entries:
        hm = one(hre, h, f"ghostty.h {label}", errors)
        rm = one(rre, r, f"ffi.rs {label}", errors)
        if not hm or not rm:
            continue
        hargs, rargs = split_args(hm.group(2)), split_args(rm.group(1))
        hret, rret = ret_kind_c(hm.group(1)), ret_kind_rs(rm.group(2))
        checked += 1
        line = f"{label}: header {len(hargs)} args -> {hret}; host {len(rargs)} args -> {rret}"
        bad = []
        if len(hargs) == len(rargs):
            for i, (ha, ra) in enumerate(zip(hargs, rargs)):
                ct = c_type(ha)
                want = C_TO_RS.get(ct)
                if want is None:
                    bad.append(f"arg {i} C type `{ct}` is not in C_TO_RS")
                elif rs_type(ra) != want:
                    bad.append(f"arg {i} `{ha.strip()}` wants `{want}`, host has `{rs_type(ra)}`")
        if len(hargs) != len(rargs) or hret != rret or bad:
            errors.append("MISMATCH " + line + "".join("; " + b for b in bad))
        else:
            print("ok   " + line)

    # Field counts. `content_s` is an array element, so a missing field
    # shifts every element after the first; `complete_s` and `confirm_s` are
    # read by pointer, so a missing field shifts every field after it.
    structs = [
        ("ghostty_clipboard_content_s", "ClipboardContent"),
        ("ghostty_clipboard_complete_s", "ClipboardComplete"),
        ("ghostty_clipboard_confirm_s", "ClipboardConfirm"),
    ]
    for cname, rname in structs:
        hm = one(r"typedef struct \{([^}]*)\}\s*" + cname + r"\s*;", h,
                 f"ghostty.h {cname}", errors)
        rm = one(r"pub struct " + rname + r"\s*\{([^}]*)\}", r,
                 f"ffi.rs {rname}", errors)
        if not hm or not rm:
            continue
        hf = len([l for l in re.sub(r"//[^\n]*", "", hm.group(1)).split(";") if l.strip()])
        rf = len([l for l in re.sub(r"//[^\n]*", "", rm.group(1)).split(",") if l.strip()])
        checked += 1
        line = f"{cname}: header {hf} fields; host {rf} fields"
        if hf != rf:
            errors.append("MISMATCH " + line + " (layout differs)")
        else:
            print("ok   " + line)

    print(f"compared {checked} of {TOTAL} clipboard ABI shapes")
    if errors:
        for e in errors:
            print("FAIL: " + e)
        return 1
    if checked != TOTAL:
        print("FAIL: not every shape was compared")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
