#!/usr/bin/env python3
"""`orelse` beside `and` is parenthesised, or the reason is written down.

# The defect this is the floor for

`src/build/Config.zig` decides whether to build the macOS app:

    config.emit_macos_app = b.option(bool, "emit-macos-app", ...) orelse
        !config.emit_lib_vt and config.emit_xcframework;

⚠️ **`orelse` binds tighter than `and`**, so that reads
`(option orelse !emit_lib_vt) and emit_xcframework` -- the `and` applies to the
**explicit** value too. `-Demit-macos-app=true` together with
`-Demit-xcframework=false` therefore leaves it false: the build exits 0 having
compiled no Swift at all, and nothing says so.

Measured 2026-09-09 on one tree, one day apart in the same session:

    -Demit-macos-app=true                            296/296 steps, xcodebuild x1
    -Demit-macos-app=true -Demit-xcframework=false    39/39 steps, xcodebuild x0

and confirmed by construction -- `opt orelse true and false` is `false`, while
`opt orelse (true and false)` is `true`.

**This is what makes a wrong belief durable**: the flag was habitually added
for speed, so "mac exit 0" was collected many times without a single line of
Swift being compiled, and each of those readings looked like the others.

# What is checked

In `src/build/`, an assignment that puts `orelse` and `and`/`or` in the same
expression without parentheses must carry a `// precedence:` comment saying
what it actually means. **Parentheses or a sentence -- either is fine; silence
is not.**

⚠️ **Default-include.** A new one written tomorrow is caught because of its
shape, not because it was added to a list here.

# NOT CHECKED

  * **Whether the grouping is the intended one.** A parenthesised expression
    passes whatever it means; this only makes the reader's question visible.
  * **The rest of the tree.** The scan is `src/build/`, where a wrong grouping
    silently changes what gets built. Elsewhere the same shape is a bug like
    any other and shows up in tests.
  * **`catch`**, which has the same precedence and the same trap. Nothing in
    `src/build/` mixes it with `and`/`or` today; add it here the day one does.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD_DIR = os.path.join(HERE, "..", "src", "build")

MIXES = re.compile(r"\borelse\b")
LOGIC = re.compile(r"\b(and|or)\b")
EXCUSED = re.compile(r"//\s*precedence:")


def strip_comments(text):
    """Comments blanked, line structure kept, so offsets still map to lines."""
    return "\n".join(re.sub(r"//.*", "", ln) for ln in text.split("\n"))


def excused_for_statement(lines, line_no):
    """Is there a `// precedence:` in the comment block above this statement?

    Walks upwards from the operator's line and stops at the previous
    statement, which is the first line whose **code** contains a `;`.

    ⚠️ Two drafts of this were wrong in opposite directions, and both reported
    the thing that had just been explained to them:

      * splitting the file on `;` cut the excuse in half, because the excuse
        contains one ("not a drive-by fix; the ...");
      * looking only at the line above the operator found an *argument*,
        because `b.option(...)` spans four lines.

    A scanner that reads comments has to treat them as prose -- and a scanner
    that reads statements has to know where they start.
    """
    i = line_no - 2  # zero-based, the line above
    while i >= 0:
        raw = lines[i]
        stripped = raw.strip()
        code = re.sub(r"//.*", "", raw)
        if ";" in code:
            return False
        if stripped.startswith("//"):
            if EXCUSED.search(stripped):
                return True
        i -= 1
    return False


def findings(sources):
    out = []
    for name, src in sorted(sources.items()):
        lines = src.split("\n")
        plain = strip_comments(src)
        for m in MIXES.finditer(plain):
            end = plain.find(";", m.end())
            tail = plain[m.end() : end if end >= 0 else len(plain)]
            if not LOGIC.search(tail):
                continue
            if "(" in tail and ")" in tail:
                # The author made the grouping visible. Whether it is the
                # right one is not this file's question.
                continue
            line = plain[: m.start()].count("\n") + 1
            # ⚠️ **The excuse sits above the statement, not above the
            # `orelse`.** `b.option(...)` spans four lines here, so the line
            # above the operator is an argument -- the second draft looked
            # there and reported the thing that had been explained to it, one
            # line short of the explanation.
            if excused_for_statement(lines, line):
                continue
            out.append(
                f"{name} line {line}: `orelse` and `{LOGIC.search(tail).group(1)}` in one "
                "expression with no parentheses. `orelse` binds tighter, so the logical "
                "operator applies to the explicit value as well -- which is how "
                "-Demit-macos-app=true came to mean false. Parenthesise it, or write "
                "`// precedence:` above it saying what it means and why it stays"
            )
    return out


GOOD = {
    "Config.zig": """
    // precedence: reads (option orelse !lib_vt) and xcframework, left as is.
    config.emit_macos_app = b.option(bool, "emit-macos-app", "") orelse
        !config.emit_lib_vt and config.emit_xcframework;
    config.other = b.option(bool, "other", "") orelse (a and b);
    config.plain = b.option(bool, "plain", "") orelse false;
"""
}


def self_test():
    cases = [
        ("the shape today", GOOD, 0),
        # The decoy is the line as it actually stood, comment and all removed.
        ("the excuse taken away, as it stood",
         {"Config.zig": GOOD["Config.zig"].replace(
             "    // precedence: reads (option orelse !lib_vt) and xcframework, left as is.\n", "")},
         1),
        ("a new one written tomorrow",
         {"Config.zig": GOOD["Config.zig"] + "    config.fresh = opt orelse x and y;\n"}, 1),
        ("parenthesised instead of excused",
         {"Config.zig": GOOD["Config.zig"].replace(
             "    // precedence: reads (option orelse !lib_vt) and xcframework, left as is.\n", ""
         ).replace("orelse\n        !config.emit_lib_vt and config.emit_xcframework;",
                   "orelse (!config.emit_lib_vt and config.emit_xcframework);")}, 0),
        # ⚠️ The excuse with a semicolon in it -- the shape that broke the
        # first draft of this file, which split statements on `;`.
        ("an excuse that contains a semicolon",
         {"Config.zig": """
    // precedence: reads (option orelse !lib_vt) and xcframework; left as is
    // because parenthesising would change what an existing command does.
    config.emit_macos_app = opt orelse !config.emit_lib_vt and config.emit_xcframework;
"""}, 0),
        # The excuse above a call that spans several lines: the operator's
        # own previous line is an argument, not a comment.
        ("an excuse above a multi-line call",
         {"Config.zig": """
    // precedence: reads (option orelse !lib_vt) and xcframework, left as is.
    config.emit_macos_app = b.option(
        bool,
        "emit-macos-app",
        "Build and install the macOS app bundle.",
    ) orelse !config.emit_lib_vt and config.emit_xcframework;
"""}, 0),
        ("the logical operator before the orelse, not after",
         {"Config.zig": "    config.x = (a and b) orelse c;\n"}, 0),
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
        print("probe self-test: OK (the excuse removed, a new one, parentheses instead, and "
              "an operator that is not swallowed, an excuse with a semicolon in it, and one "
              "above a multi-line call)")
    return ok


def main():
    if not self_test():
        return 1
    sources = {}
    try:
        for name in sorted(os.listdir(BUILD_DIR)):
            if name.endswith(".zig"):
                with open(os.path.join(BUILD_DIR, name), encoding="utf-8") as fh:
                    sources[name] = fh.read()
    except OSError as e:
        print(f"cannot read src/build: {e}")
        return 1

    found = findings(sources)
    n = sum(len(MIXES.findall(s)) for s in sources.values())
    print(f"src/build: {len(sources)} file(s), {n} `orelse`(s); every one that meets a "
          "logical operator is either parenthesised or explained")
    print("NOT CHECKED: whether the grouping is the intended one -- parentheses pass "
          "whatever they mean.")
    for f in found:
        print(f"HIT    {f}")
    if found:
        print(f"\n{len(found)} problem(s): an expression means something other than it reads.")
        return 1
    print("OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
