#!/usr/bin/env python3
"""A build switch that takes an artifact away says that it did.

# The defect this is the floor for

In `build.zig`, `-Demit-lib-vt` and `ghostty-internal.dll` are two arms of the
same `if`. Passing `-Demit-lib-vt` therefore **removes** the internal library
from the build -- and the build exits 0 with nothing said. One command written
to produce both produces one of them.

**Nobody found this in a build log, because it was not in one.** It was found
by looking at the DLL's byte count and noticing the file was from an earlier
build. ⚠️ A missing artifact and a stale artifact are the same on disk, and a
successful exit code covers both.

The fix is a sentence, not a failure: `-Demit-lib-vt` on its own is an
ordinary build, and erroring would break every caller who only wants the vt
library. **Two artifacts means two commands** -- and this is the line where
somebody finds that out.

# What is checked

The `else if (!config.emit_lib_vt)` chain in `build.zig` must end in an `else`
that **says something** (`std.log.warn`). That is the arm taken when the
switch is on, and an arm that is empty is exactly the silence this is about.

⚠️ It checks the shape, not the words: a warning that says the wrong thing
passes here. What it makes impossible is *no* warning.

# NOT CHECKED

  * **That the message is true or useful.** For that, run the build:

        zig build -Demit-lib-vt -Dtarget=x86_64-windows-gnu -Demit-macos-app=false

    and look for `are exclusive` in the output. Measured that way today; this
    file exists so the line cannot quietly go away between such runs.
  * **Other exclusive pairs in `build.zig`.** There may be more; this is the
    floor for the one that was measured, not a survey.
  * **Whether the artifact really is absent.** That is the byte count on disk,
    and only a real build answers it.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "..", "build.zig")

ARM = re.compile(r"\}\s*else\s+if\s*\(\s*!\s*config\.emit_lib_vt\s*\)\s*\{")
SPEAKS = re.compile(r"std\.log\.(warn|err|info)\s*\(")


def strip_comments(src):
    return "\n".join(re.sub(r"//.*", "", ln) for ln in src.split("\n"))


def block_after(src, open_brace):
    """The text of the block whose `{` is at `open_brace`, and where it ends."""
    depth = 0
    for j in range(open_brace, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[open_brace : j + 1], j + 1
    return src[open_brace:], len(src)


def findings(src):
    plain = strip_comments(src)
    m = ARM.search(plain)
    if not m:
        return [
            "build.zig no longer has the `!config.emit_lib_vt` arm. Either the exclusivity "
            "is gone -- in which case say so and delete this checker -- or it moved, and a "
            "silent pass here would be the same as no checker"
        ]

    _, end = block_after(plain, m.end() - 1)
    tail = plain[end:]
    rest = tail.lstrip()
    if not rest.startswith("else"):
        return [
            "the `!config.emit_lib_vt` arm has no `else`. That is the branch taken when the "
            "switch is on -- the build that quietly does not produce ghostty-internal.dll -- "
            "and with no arm there, it produces nothing to read either"
        ]

    body, _ = block_after(tail, tail.index("{", tail.index("else")))
    if not SPEAKS.search(body):
        return [
            "the `else` taken when -Demit-lib-vt is on says nothing. A build that drops an "
            "artifact and exits 0 is indistinguishable from one that built it, and the only "
            "way this was ever noticed was a byte count on disk"
        ]
    return []


GOOD = """
    if (config.app_runtime != .none) {
        exe.install();
    } else if (!config.emit_lib_vt) {
        lib_shared.install("ghostty-internal.dll");
    } else {
        std.log.warn("-Demit-lib-vt is set, so ghostty-internal.dll is NOT built", .{});
    }
"""


def self_test():
    cases = [
        ("the shape today", GOOD, 0),
        # The decoy is the code as it actually stood: the arm simply ended.
        ("the silent version, as it stood",
         GOOD[: GOOD.index("    } else {")] + "    }\n", 1),
        ("an else that does nothing",
         GOOD.replace('std.log.warn("-Demit-lib-vt is set, so ghostty-internal.dll is NOT built", .{});', ""), 1),
        ("the warning in a comment only",
         GOOD.replace('std.log.warn("-Demit-lib-vt is set, so ghostty-internal.dll is NOT built", .{});',
                      "// std.log.warn(...) used to be here"), 1),
        ("the arm gone entirely",
         GOOD.replace("} else if (!config.emit_lib_vt) {", "} else if (false) {"), 1),
    ]
    ok = True
    for what, src, want in cases:
        got = findings(src)
        if len(got) != want:
            print(f"probe self-test FAILED: {what} gave {len(got)} finding(s), expected {want}:")
            for f in got:
                print(f"    {f}")
            ok = False
    if ok:
        print("probe self-test: OK (the silent arm, an empty else, the warning commented out, "
              "and the arm gone)")
    return ok


def main():
    if not self_test():
        return 1
    try:
        with open(BUILD, encoding="utf-8") as fh:
            src = fh.read()
    except OSError as e:
        print(f"cannot read build.zig: {e}")
        return 1

    found = findings(src)
    print("build.zig: the -Demit-lib-vt arm has an else, and it speaks")
    print("NOT CHECKED: whether the message is true. Run "
          "`zig build -Demit-lib-vt -Dtarget=x86_64-windows-gnu -Demit-macos-app=false` "
          "and look for `are exclusive`.")
    for f in found:
        print(f"HIT    {f}")
    if found:
        print(f"\n{len(found)} problem(s): a switch takes an artifact away without saying so.")
        return 1
    print("OK: the exclusive switch says so.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
