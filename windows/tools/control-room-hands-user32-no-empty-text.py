#!/usr/bin/env python3
"""The control room's panel never hands the system text with nothing in it.

**The defect this is the floor for** (task 1439). On its first real machine
the panel killed the host on every opening that had a row with a status in
it -- four out of four: Application Error 1000, faulting module `USER32.dll`,
`0xc0000005`, and nothing in the host's log after `[control-room] opened as`.

The panel draws its words with `DrawTextW` and measures them with
`GetTextExtentPoint32W`, both given a counted slice. A scene carries words
that are empty on purpose -- a group nobody waits on has a status with no
word, a wait can come with no reason -- and an empty `Vec<u16>` is a count of
0 and a pointer to nothing. `USER32` on Windows 11 build 26200 reads through
that pointer. The screenshot overlay died of the same thing before the panel
did (task 1199).

**The rule.** In `windows/host/src/control_room.rs`:

  1. `DrawTextW(` appears in `draw_text` and nowhere else;
     `GetTextExtentPoint32W(` in `text_width` and nowhere else.
  2. Each of those two functions asks `scene::draws(text)` and returns when
     the answer is no, **before** the call.
  3. No other call that takes text to draw or measure (`TextOutW`,
     `ExtTextOutW`, `DrawTextExW`, `TabbedTextOutW`, `GetTextExtentExPointW`)
     is in the file at all: a new one goes through the two above or is added
     here with its own question.

**What is read.** That one file, comments and string literals removed.

**NOT CHECKED.**

  * **The other thirty-odd `DrawTextW` calls in the host** (`strip.rs`,
    `palette.rs`, the settings pages, ...). Each has its own caller and its
    own reason the text is not empty, or none; nobody has gone through them.
    This is the panel's floor and says nothing about them.
  * **That `USER32` does what the paragraph above says.** It is read from two
    crashes with the same signature and from the code; there was no dump
    either time. What this holds is that the panel no longer does the thing,
    whatever the thing would have done.
  * **`scene::draws` itself** -- that it refuses the empty string is a test in
    `windows/control-room/src/scene.rs`, next to the one that shows the
    core's own fixture producing such text.
  * Text that is not empty and still draws nothing (a lone combining mark).

`probe self-test` plants each offender in a scratch source and checks it is
caught, and that the file as it should be is not.

Run:  python3 windows/tools/control-room-hands-user32-no-empty-text.py
Exit: 0, with `scanned 1 file` and the two calls counted (2, not 0);
      non-zero otherwise.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
FILE = os.path.join("windows", "host", "src", "control_room.rs")

# call -> the one function it may be made from
HOMES = {
    "DrawTextW": "draw_text",
    "GetTextExtentPoint32W": "text_width",
}
OTHERS = ("TextOutW", "ExtTextOutW", "DrawTextExW", "TabbedTextOutW", "GetTextExtentExPointW")
QUESTION = re.compile(r"if\s+!\s*scene::draws\(\s*text\s*\)\s*\{\s*return\b[^;]*;\s*\}")


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


def findings(src):
    """`(problems, calls)`: what is wrong, and how many guarded calls were read."""
    code = strip(src)
    funcs = functions(code)
    out = []
    calls = 0
    for call, home in HOMES.items():
        sites = [m.start() for m in re.finditer(r"\b%s\s*\(" % call, code)]
        if not sites:
            out.append(
                f"`{call}(` is not in the file at all. Either the panel stopped drawing words "
                "with it -- then this gate is about nothing and must be rewritten for whatever "
                "it uses now -- or the reading is broken"
            )
            continue
        for at in sites:
            inside = owner(funcs, at)
            if inside is None or inside[0] != home:
                where = inside[0] if inside else "no function"
                out.append(
                    f"line {line_of(code, at)}: `{call}(` in `{where}`, outside `{home}`. Text that "
                    f"reaches it has not been asked `scene::draws`: an empty one is a count of 0 "
                    "and a pointer to nothing, and USER32 reads through it (task 1439)"
                )
                continue
            asked = QUESTION.search(code, inside[1], at)
            if not asked:
                out.append(
                    f"line {line_of(code, at)}: `{home}` calls `{call}(` without first returning "
                    "when `!scene::draws(text)`. The question has to come before the call, in "
                    "this function, as `if !scene::draws(text) { return ...; }`"
                )
                continue
            calls += 1
    for call in OTHERS:
        for m in re.finditer(r"\b%s\s*\(" % call, code):
            out.append(
                f"line {line_of(code, m.start())}: `{call}(` -- another way of handing text to the "
                "system, with no question in front of it. Draw through `draw_text`, measure "
                "through `text_width`, or add the call to this gate with its own guard"
            )
    return out, calls


GOOD = """
unsafe fn draw_text(dc: HDC, font: HFONT, color: Rgba, text: &str, mut r: RECT, how: DRAW_TEXT_FORMAT) {
    if !scene::draws(text) {
        return;
    }
    unsafe {
        let mut wide: Vec<u16> = text.encode_utf16().collect();
        DrawTextW(dc, &mut wide, &mut r, how);
    }
}
unsafe fn text_width(dc: HDC, font: HFONT, text: &str) -> i32 {
    if !scene::draws(text) {
        return 0;
    }
    unsafe {
        let wide: Vec<u16> = text.encode_utf16().collect();
        let mut size = SIZE::default();
        let _ = GetTextExtentPoint32W(dc, &wide, &mut size);
        size.cx
    }
}
unsafe fn paint_piece(dc: HDC, text: &str, r: RECT) {
    // DrawTextW(dc, ...) in a comment is not a call
    unsafe { draw_text(dc, font, color, text, r, DT_LEFT) };
    let s = "DrawTextW(";
}
"""


def self_test():
    cases = [
        ("the file as it should be", GOOD, 0),
        # What was there: the call made straight from the painting code.
        ("a second DrawTextW, in the painter",
         GOOD + "\nunsafe fn paint_items(dc: HDC, text: &str) { unsafe { let mut w: Vec<u16> = text.encode_utf16().collect(); DrawTextW(dc, &mut w, &mut r, DT_LEFT); } }\n", 1),
        ("the question taken out of draw_text, the code still compiling",
         GOOD.replace("    if !scene::draws(text) {\n        return;\n    }", "    if !scene::draws(text) {}", 1), 1),
        ("the question taken out of text_width",
         GOOD.replace("    if !scene::draws(text) {\n        return 0;\n    }", "", 1), 1),
        ("the question after the call",
         GOOD.replace(
             "    if !scene::draws(text) {\n        return;\n    }\n    unsafe {\n        let mut wide: Vec<u16> = text.encode_utf16().collect();\n        DrawTextW(dc, &mut wide, &mut r, how);\n    }",
             "    unsafe {\n        let mut wide: Vec<u16> = text.encode_utf16().collect();\n        DrawTextW(dc, &mut wide, &mut r, how);\n    }\n    if !scene::draws(text) {\n        return;\n    }", 1), 1),
        ("the question asked of something else",
         GOOD.replace("if !scene::draws(text) {\n        return;", "if !scene::draws(other) {\n        return;", 1), 1),
        ("a measuring call outside text_width",
         GOOD + "\nfn width(dc: HDC, w: &[u16]) { let mut s = SIZE::default(); unsafe { let _ = GetTextExtentPoint32W(dc, w, &mut s); } }\n", 1),
        ("TextOutW, which nothing guards",
         GOOD + "\nfn other(dc: HDC, w: &[u16]) { unsafe { let _ = TextOutW(dc, 0, 0, w); } }\n", 1),
        ("no DrawTextW left to read",
         GOOD.replace("DrawTextW(dc, &mut wide, &mut r, how);", "", 1), 1),
        ("an empty file", "", 2),
    ]
    bad = 0
    for name, src, want in cases:
        got, _ = findings(src)
        if len(got) != want:
            bad += 1
            print(f"SELF-TEST FAILED: {name}: wanted {want} finding(s), got {len(got)}")
            for g in got:
                print(f"    {g}")
    # And the count the real run reports is the number of guarded calls.
    _, calls = findings(GOOD)
    if calls != 2:
        bad += 1
        print(f"SELF-TEST FAILED: the good file has 2 guarded calls, counted {calls}")
    return bad


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "probe" and sys.argv[2:] == ["self-test"]:
        bad = self_test()
        print("self-test: %s" % ("FAILED" if bad else "ok"))
        return 1 if bad else 0

    if self_test():
        print("the gate's own self-test fails; its reading of the tree is not to be believed")
        return 1

    root = sys.argv[1] if len(sys.argv) > 1 else ROOT
    path = os.path.join(root, FILE)
    if not os.path.isfile(path):
        print(f"scanned 0 files: {FILE} is not there. Nothing was checked, which is not a pass")
        return 1
    with open(path, encoding="utf-8") as f:
        src = f.read()
    out, calls = findings(src)
    print(f"scanned 1 file ({FILE}); {calls} guarded call(s) of {len(HOMES)}")
    if out:
        for line in out:
            print(f"FAIL {FILE}: {line}")
        return 1
    if calls != len(HOMES):
        print(f"FAIL: read {calls} guarded call(s) and expected {len(HOMES)}")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
