#!/usr/bin/env python3
"""A callback argument the core computed is used, or the reason is written.

# The defect this is the floor for

The core decides whether closing a surface should ask first --
`Surface.close` calls `needsConfirmQuit`, which weighs the
`confirm-close-surface` setting, whether the child process has already exited,
and whether the cursor is at a prompt -- and hands the answer to the host as
the second argument of the close callback.

**The host wrote it `_confirm` and closed the pane.** Every keybinding and
every tool call that closed a busy tab did so without a word, and the record
it left said the close succeeded. Task 422.

⚠️ **This is the third member of a family this port keeps meeting**: task 408
(`ghostty_surface_refresh` exported and never bound), task 420
(`title_override` present and not read). The shape is always **the concept is
already in the code, wired to nothing** -- and an argument spelled with a
leading underscore is that shape at its most compact, because the compiler is
*satisfied*: the underscore is how you tell it you meant to ignore this.

# What is checked

Every `extern "C" fn` **with a body** under `windows/host/src`: no parameter
may be spelled with a leading underscore unless a `// unused-arg:` comment
above the function says why. ⚠️ **Default-include** -- a callback added
tomorrow is covered because it is a callback, not because it was listed here.

# NOT CHECKED

  * **Whether a used argument is used correctly.** `confirm` reaching a
    `MessageBoxW` and `confirm` reaching a log line both pass.
  * **Arguments that are used wrongly rather than ignored.** The underscore is
    a very specific admission; a callback that reads the argument and then
    ignores what it said is invisible here.
  * **The Zig side.** Whether the core computes the right answer is
    `needsConfirmQuit`'s business and has its own tests.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "windows", "host", "src")

DEF = re.compile(r"^(?:pub\s+)?(?:unsafe\s+)?extern\s+\"C\"\s+fn\s+(\w+)\s*\(", re.M)
EXCUSED = re.compile(r"^//\s*unused-arg:")


def strip_comments(src):
    return "\n".join(re.sub(r"//.*", "", ln) for ln in src.split("\n"))


def params_of(plain, open_paren):
    depth = 0
    for j in range(open_paren, len(plain)):
        if plain[j] == "(":
            depth += 1
        elif plain[j] == ")":
            depth -= 1
            if depth == 0:
                return plain[open_paren + 1 : j]
    return ""


def excused_above(lines, line_no):
    i = line_no - 2
    while i >= 0:
        stripped = lines[i].strip()
        if stripped.startswith("//"):
            if EXCUSED.search(stripped):
                return True
            i -= 1
            continue
        if not stripped:
            i -= 1
            continue
        return False
    return False


def findings(sources):
    out = []
    for name, src in sorted(sources.items()):
        plain = strip_comments(src)
        lines = src.split("\n")
        for m in DEF.finditer(plain):
            fn = m.group(1)
            params = params_of(plain, m.end() - 1)
            ignored = [
                p.split(":")[0].strip()
                for p in params.split(",")
                if re.match(r"\s*_\w", p)
            ]
            if not ignored:
                continue
            line = plain[: m.start()].count("\n") + 1
            if excused_above(lines, line):
                continue
            out.append(
                f"{name} line {line}: `{fn}` ignores {', '.join(ignored)}. An argument the "
                "core computed and this host spelled with an underscore is the shape task "
                "422 was: the answer arrived and was discarded, and the compiler was happy "
                "about it. Use it, or write `// unused-arg:` above the function saying what "
                "is in it and why nothing is lost"
            )
    return out


GOOD = {
    "main.rs": '''
// unused-arg: nothing to wake; the message loop is the wakeup.
extern "C" fn cb_wakeup(_ud: *mut c_void) {}

extern "C" fn cb_close_surface(ud: *mut c_void, confirm: bool) {
    let _ = (ud, confirm);
}
'''
}


def self_test():
    cases = [
        ("the shape today", GOOD, 0),
        # The decoy is the line exactly as it stood before task 422.
        ("the close callback discarding it again, as it stood",
         {"main.rs": GOOD["main.rs"].replace(
             "cb_close_surface(ud: *mut c_void, confirm: bool)",
             "cb_close_surface(ud: *mut c_void, _confirm: bool)")}, 1),
        ("the excuse taken away",
         {"main.rs": GOOD["main.rs"].replace(
             "// unused-arg: nothing to wake; the message loop is the wakeup.\n", "")}, 1),
        ("a new callback written tomorrow",
         {"main.rs": GOOD["main.rs"] + 'extern "C" fn cb_new(_x: bool) {}\n'}, 1),
        ("a multi-line signature",
         {"main.rs": GOOD["main.rs"] + 'extern "C" fn cb_wide(\n    a: u32,\n    _b: bool,\n) {}\n'}, 1),
        # An excuse must be an excuse, not prose that mentions one.
        ("prose naming the excuse prefix",
         {"main.rs": GOOD["main.rs"].replace(
             "// unused-arg: nothing to wake; the message loop is the wakeup.",
             "// this one would need a `// unused-arg:` note if it ignored anything")}, 1),
    ]
    ok = True
    for what, sources, want in cases:
        got = findings(sources)
        if len(got) != want:
            print(f"probe self-test FAILED: {what} gave {len(got)} finding(s), expected {want}:")
            for f in got:
                print(f"    {f}")
            ok = False
    if ok:
        print("probe self-test: OK (the close callback as it stood, the excuse removed, a new "
              "callback, a multi-line signature, and prose that only names the prefix)")
    return ok


def main():
    if not self_test():
        return 1
    sources = {}
    try:
        for name in sorted(os.listdir(SRC)):
            if name.endswith(".rs"):
                with open(os.path.join(SRC, name), encoding="utf-8") as fh:
                    sources[name] = fh.read()
    except OSError as e:
        print(f"cannot read the host sources: {e}")
        return 1

    n = sum(len(DEF.findall(strip_comments(s))) for s in sources.values())
    print(f"{len(sources)} host source(s), {n} extern \"C\" fn definition(s); every ignored "
          "argument is either used or excused")
    print("NOT CHECKED: whether a used argument is used correctly -- reaching a log line "
          "passes here.")
    found = findings(sources)
    for f in found:
        print(f"HIT    {f}")
    if found:
        print(f"\n{len(found)} problem(s): an answer the core computed is being discarded.")
        return 1
    print("OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
