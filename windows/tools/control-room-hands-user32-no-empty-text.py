#!/usr/bin/env python3
"""The Windows host never hands the system text with nothing in it.

**The defect this is the floor for.** Three windows killed the host the same
way: the screenshot overlay (task 1199), the control room's panel (task
1439: four openings out of four), and Manage Projects (task 1871: three dumps
out of three, `USER32+0x24702` reading address `0x2`). Each drew a string
that was empty on purpose -- a status with no word, a wait with no reason, a
Color line whose value is the swatches drawn over it.

`DrawTextW`, `TextOutW` and the `GetTextExtent*` calls take a counted slice.
An empty `Vec<u16>` is a count of 0 and a pointer to nothing (`0x2`), and
`USER32` on Windows 11 build 26200 reads through that pointer.

**The rule** (task 1872), over every `.rs` file under `windows/host/src`:

  1. `DrawTextW(`, `TextOutW(`, `GetTextExtentPoint32W(` and
     `GetTextExtentExPointW(` appear in `gdi_text.rs` and nowhere else, each
     in its one function there (`HOMES`).
  2. Each of those functions asks `draws(text)` -- `if !draws(text) { ... }`
     with a `return` in it -- **before** the call.
  3. No other call that hands text to the system (`OTHERS`) is anywhere in
     the tree: a new one gets a function in `gdi_text.rs` and a line here.

**What is read.** Every file, comments and string literals removed, so a
name in a comment or a message is not a call.

**NOT CHECKED.**

  * **That `USER32` does what the paragraph above says.** Read from the
    crashes; the third one had dumps, the address read was `0x2`. What this
    holds is that the host no longer does the thing.
  * **`draws` itself** -- that it refuses the empty slice, and what a measure
    of nothing answers, are tests in `gdi_text.rs`, which run on Windows.
  * Text that is not empty and still draws nothing (a lone combining mark).
  * Calls made through a function pointer, `windows_sys`, or `link!` of
    their own -- there are none, and this reads names.

`probe self-test` plants each offender in a scratch tree and checks it is
caught, and that the tree as it should be is not.

Run:  python3 windows/tools/control-room-hands-user32-no-empty-text.py [root]
Exit: 0, with `scanned N file(s)` (N > 1) and 4 guarded call(s) of 4;
      non-zero otherwise.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
SRC = os.path.join("windows", "host", "src")
HOME_FILE = "gdi_text.rs"

# call -> the one function in gdi_text.rs it may be made from
HOMES = {
    "DrawTextW": "draw_text_w",
    "TextOutW": "text_out_w",
    "GetTextExtentPoint32W": "get_text_extent_point32_w",
    "GetTextExtentExPointW": "get_text_extent_ex_point_w",
}
OTHERS = (
    "DrawTextExW",
    "ExtTextOutW",
    "TabbedTextOutW",
    "PolyTextOutW",
    "GetTextExtentPointW",
    "GetTabbedTextExtentW",
    "GetCharacterPlacementW",
    "DrawStateW",
    "GrayStringW",
)
QUESTION = re.compile(r"if\s+!\s*draws\(\s*text\s*\)\s*\{")


def strip(src):
    """Rust source with comments and literals blanked, newlines kept."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        two = src[i:i + 2]
        if two == "//":
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif two == "/*":
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(ch if ch == "\n" else " " for ch in src[i:j]))
            i = j
        elif c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            j = min(j + 1, n)
            out.append('""' + "".join(ch if ch == "\n" else " " for ch in src[i + 2:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def functions(code):
    """`(name, start, end)` for every `fn` with a body, by brace matching."""
    out = []
    for m in re.finditer(r"\bfn\s+(\w+)\s*(?:<[^>{]*>)?\s*\(", code):
        i = code.find("{", m.end())
        semi = code.find(";", m.end())
        if i < 0 or (0 <= semi < i):
            continue
        depth, j = 0, i
        while j < len(code):
            if code[j] == "{":
                depth += 1
            elif code[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        out.append((m.group(1), i, j + 1))
    return out


def owner(funcs, at):
    """The innermost function a position is inside."""
    best = None
    for name, start, end in funcs:
        if start <= at < end and (best is None or start > best[1]):
            best = (name, start, end)
    return best


def line_of(code, at):
    return code.count("\n", 0, at) + 1


def block_end(code, brace):
    """The index just past the `}` that closes the `{` at `brace`."""
    depth = 0
    for j in range(brace, len(code)):
        if code[j] == "{":
            depth += 1
        elif code[j] == "}":
            depth -= 1
            if depth == 0:
                return j + 1
    return len(code)


def asked_before(code, start, at):
    """Whether `if !draws(text) { ... return ... }` comes between `start` and `at`."""
    for m in QUESTION.finditer(code, start, at):
        end = block_end(code, m.end() - 1)
        if end <= at and re.search(r"\breturn\b", code[m.end():end]):
            return True
    return False


def calls_in(code, name):
    return [m.start() for m in re.finditer(r"(?<![\w:])%s\s*\(" % name, code)]


def findings(tree):
    """`(problems, guarded)` for `tree`, a {relative path: source} map."""
    out = []
    guarded = 0
    home = tree.get(HOME_FILE)
    for rel, src in sorted(tree.items()):
        code = strip(src)
        funcs = functions(code)
        for call, fn in HOMES.items():
            for at in calls_in(code, call):
                if rel != HOME_FILE:
                    out.append(
                        f"{rel}:{line_of(code, at)}: `{call}(` outside `{HOME_FILE}`. Call "
                        f"`crate::gdi_text::{fn}` instead, which does not hand an empty string "
                        "over: an empty one is a count of 0 and a pointer to nothing, and USER32 "
                        "reads through it (tasks 1199, 1439, 1871)"
                    )
                    continue
                inside = owner(funcs, at)
                if inside is None or inside[0] != fn:
                    where = inside[0] if inside else "no function"
                    out.append(f"{rel}:{line_of(code, at)}: `{call}(` in `{where}`, not in `{fn}`")
                    continue
                if not asked_before(code, inside[1], at):
                    out.append(
                        f"{rel}:{line_of(code, at)}: `{fn}` calls `{call}(` without first returning "
                        "when `!draws(text)`. The question has to come before the call, in this "
                        "function, as `if !draws(text) { ...; return ...; }`"
                    )
                    continue
                guarded += 1
        for call in OTHERS:
            for at in calls_in(code, call):
                out.append(
                    f"{rel}:{line_of(code, at)}: `{call}(` -- another way of handing text to the "
                    f"system, with no question in front of it. Give it a function in `{HOME_FILE}` "
                    "that asks `draws`, and add it to this gate"
                )
    if home is None:
        out.append(f"`{HOME_FILE}` is not in the tree: there is nowhere the calls may be made")
    else:
        code = strip(home)
        for call, fn in HOMES.items():
            if not calls_in(code, call):
                out.append(
                    f"`{call}(` is not in `{HOME_FILE}` at all. Either nothing draws with it any "
                    "more -- then take it out of HOMES -- or the reading is broken"
                )
    return out, guarded


GOOD_HOME = """
use windows::Win32::Graphics::Gdi::{DrawTextW, TextOutW};
pub fn draws(text: &[u16]) -> bool { !text.is_empty() }
pub unsafe fn draw_text_w(hdc: HDC, text: &mut [u16], r: *mut RECT, how: DRAW_TEXT_FORMAT) -> i32 {
    if !draws(text) {
        if how.0 & DT_CALCRECT.0 != 0 && !r.is_null() {
            unsafe { (*r).right = (*r).left; }
        }
        return 0;
    }
    unsafe { DrawTextW(hdc, text, r, how) }
}
pub unsafe fn text_out_w(hdc: HDC, x: i32, y: i32, text: &[u16]) -> BOOL {
    if !draws(text) {
        return BOOL(1);
    }
    unsafe { TextOutW(hdc, x, y, text) }
}
pub unsafe fn get_text_extent_point32_w(hdc: HDC, text: &[u16], size: *mut SIZE) -> BOOL {
    if !draws(text) {
        return BOOL(1);
    }
    unsafe { GetTextExtentPoint32W(hdc, text, size) }
}
pub unsafe fn get_text_extent_ex_point_w(hdc: HDC, text: &[u16], m: i32, f: Option<*mut i32>, d: Option<*mut i32>, size: *mut SIZE) -> BOOL {
    if !draws(text) {
        return BOOL(1);
    }
    unsafe { GetTextExtentExPointW(hdc, PCWSTR(text.as_ptr()), text.len() as i32, m, f, d, size) }
}
"""
GOOD_CALLER = """
fn paint(dc: HDC, s: &str, r: &mut RECT) {
    // DrawTextW(dc, ...) in a comment is not a call
    let mut w: Vec<u16> = s.encode_utf16().collect();
    unsafe { crate::gdi_text::draw_text_w(dc, &mut w, r, DT_LEFT) };
    let msg = "TextOutW(";
}
"""


def self_test():
    good = {HOME_FILE: GOOD_HOME, "strip.rs": GOOD_CALLER}
    def with_(rel, src):
        t = dict(good)
        t[rel] = src
        return t
    cases = [
        ("the tree as it should be", good, 0),
        # What was there: the call made straight from a window's painting code.
        ("a DrawTextW in another file",
         with_("projects_ui.rs", "fn draw_text(hdc: HDC, s: &str) { let mut w: Vec<u16> = s.encode_utf16().collect(); unsafe { DrawTextW(hdc, &mut w, &mut r, DT_LEFT); } }\n"), 1),
        ("one guarded by its own question, still in another file",
         with_("control_room.rs", "fn draw_text(dc: HDC, text: &str) { if !scene::draws(text) { return; } unsafe { DrawTextW(dc, &mut w, &mut r, how); } }\n"), 1),
        ("the question hollowed out, the code still compiling",
         with_(HOME_FILE, GOOD_HOME.replace("        return 0;\n", "", 1)), 1),
        ("the question taken out of text_out_w",
         with_(HOME_FILE, GOOD_HOME.replace("    if !draws(text) {\n        return BOOL(1);\n    }\n    unsafe { TextOutW", "    unsafe { TextOutW", 1)), 1),
        ("the question after the call",
         with_(HOME_FILE, GOOD_HOME.replace(
             "    if !draws(text) {\n        return BOOL(1);\n    }\n    unsafe { GetTextExtentPoint32W(hdc, text, size) }",
             "    let r = unsafe { GetTextExtentPoint32W(hdc, text, size) };\n    if !draws(text) {\n        return BOOL(1);\n    }\n    r", 1)), 1),
        ("the question asked of something else",
         with_(HOME_FILE, GOOD_HOME.replace("if !draws(text) {\n        return BOOL(1);\n    }\n    unsafe { TextOutW", "if !draws(other) {\n        return BOOL(1);\n    }\n    unsafe { TextOutW", 1)), 1),
        ("a second call in the home file, outside its function",
         with_(HOME_FILE, GOOD_HOME + "\nfn other(hdc: HDC, w: &[u16]) { unsafe { let _ = TextOutW(hdc, 0, 0, w); } }\n"), 1),
        ("ExtTextOutW, which nothing guards",
         with_("shot.rs", "fn other(dc: HDC, w: &[u16]) { unsafe { let _ = ExtTextOutW(dc, 0, 0, 0, None, w, None); } }\n"), 1),
        ("no DrawTextW left in the home file",
         with_(HOME_FILE, GOOD_HOME.replace("    unsafe { DrawTextW(hdc, text, r, how) }", "    0", 1)), 1),
        ("no home file", {"strip.rs": GOOD_CALLER}, 1),
    ]
    bad = 0
    for name, tree, want in cases:
        got, _ = findings(tree)
        if len(got) != want:
            bad += 1
            print(f"SELF-TEST FAILED: {name}: wanted {want} finding(s), got {len(got)}")
            for g in got:
                print(f"    {g}")
    _, guarded = findings(good)
    if guarded != len(HOMES):
        bad += 1
        print(f"SELF-TEST FAILED: the good tree has {len(HOMES)} guarded calls, counted {guarded}")
    return bad


def read_tree(root):
    base = os.path.join(root, SRC)
    tree = {}
    for dirpath, _, names in os.walk(base):
        for n in names:
            if n.endswith(".rs"):
                path = os.path.join(dirpath, n)
                with open(path, encoding="utf-8") as f:
                    tree[os.path.relpath(path, base)] = f.read()
    return tree


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "probe" and sys.argv[2:] == ["self-test"]:
        bad = self_test()
        print("self-test: %s" % ("FAILED" if bad else "ok"))
        return 1 if bad else 0

    if self_test():
        print("the gate's own self-test fails; its reading of the tree is not to be believed")
        return 1

    root = sys.argv[1] if len(sys.argv) > 1 else ROOT
    tree = read_tree(root)
    if not tree:
        print(f"scanned 0 files: there is no {SRC} under {root}. Nothing was checked, which is not a pass")
        return 1
    out, guarded = findings(tree)
    print(f"scanned {len(tree)} file(s) under {SRC}; {guarded} guarded call(s) of {len(HOMES)} in {HOME_FILE}")
    for line in out:
        print(f"FAIL {line}")
    if out:
        return 1
    if guarded != len(HOMES):
        print(f"FAIL: read {guarded} guarded call(s) and expected {len(HOMES)}")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
