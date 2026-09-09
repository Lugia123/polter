#!/usr/bin/env python3
"""The floor everybody runs does not compile one of the apprt paths.

**Measured, twice, on this repository.** A real compile error in `src/App.zig`
-- a field read on an enum that had been renamed -- sat in the tree while
`zig build test` reported **86/86 steps, 4140/4161 tests, 0 failed**. Nothing
about that reading was wrong; it simply does not cover the code in question.

# Why the fast floor cannot see it

The test binary is built for one apprt. A function that only another apprt
calls is **never analysed**: Zig analyses what is reached, so a body nobody in
that build reaches is a body no error can come out of. The line that broke was
in `src/App.zig` -- a file the test build *does* compile -- which is why "it is
in the test build's files" is not the question. **The question is whether
anything reaches it.**

⚠️ It also means the obvious probe does not work: a bad `const` at the top of
an apprt file is not analysed either, so seeding one and seeing green proves
nothing. The seed has to be **inside a function that path actually calls**.
That was learned by trying the wrong one first.

# What this runs, and why this exact command

`zig build -Demit-xcframework=true -Demit-macos-app=false`

`build.zig` compiles the xcframework when **either** flag is set, and runs
xcodebuild only for `emit_macos_app`. So this pair is the one that **compiles
the other apprt's path without invoking Xcode** -- which makes it affordable
enough to be a floor rather than a release step.

**The measurement that chose it**, taken by seeding the real defect back in
(`if (result == .will_split)` -> `.split` in `src/App.zig`):

    zig build test -Demit-xcframework=false -Demit-macos-app=false
        -> 86/86 steps, 4140/4161 tests, 0 failed          (blind)
    zig build -Demit-xcframework=true -Demit-macos-app=false
        -> error: no field named 'split' in enum ...        (red)

Roughly 29 seconds warm. **That is the price of this file**, and it is charged
to everybody who runs the gate sweep; there is no cheaper mechanism, because
the only thing that can find a compile error is a compiler.

# ⚠️ NOT CHECKED

  * **Linux and Windows hosts.** The path this compiles exists only on macOS,
    so on any other host this abstains -- loudly, in one line, rather than
    printing an all-clear that would mean something else.
  * ⚠️ **That the flags still mean what they meant.** This names them; if a
    later change makes `-Demit-xcframework=true` stop compiling that path,
    this file goes **green while blind**, which is the failure it exists to
    end. There is no way to detect that from here. The defence is that the
    command is written once, in `BUILD`, so somebody changing the build has
    one place to come and look -- and this sentence to find when they do.
  * **Only one apprt.** GTK has the same hole and this does not cover it.
  * Anything the compiler does not object to. A path that compiles and is
    wrong is not this file's subject.

Run:  python3 tools/one-apprt-is-outside-the-fast-floor.py
Exit: 0 when the apprt path the fast floor skips still compiles.
"""

import os
import platform
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))

# **Written once.** Everything about this file that a build change could
# invalidate is this list; see the second NOT CHECKED note.
BUILD = ["zig", "build", "-Demit-xcframework=true", "-Demit-macos-app=false"]

# What the fast floor runs, for the message only. Kept here so the two
# commands can be read side by side, which is the whole point being made.
FAST_FLOOR = "zig build test -Demit-xcframework=false -Demit-macos-app=false"

TIMEOUT = 900


def main() -> int:
    if platform.system() != "Darwin":
        # **Abstaining, and saying so.** The path compiled here is macOS's; a
        # bare "OK" on a Linux host would be a sentence about something else.
        print("this host is not macOS, so the path this checks does not exist here")
        print("ABSTAINED: nothing was compiled and nothing was checked. "
              "On macOS this runs:")
        print("  " + " ".join(BUILD))
        return 0

    if not os.path.isfile(os.path.join(ROOT, "build.zig")):
        print("FAIL: no build.zig at the repository root; nothing was built. "
              "Not a pass.")
        return 1

    started = time.time()
    try:
        r = subprocess.run(
            BUILD,
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
        )
    except FileNotFoundError:
        print("FAIL: zig is not on PATH, so the apprt path was not compiled. "
              "Not a pass.")
        return 1
    except subprocess.TimeoutExpired:
        print(f"FAIL: the build did not finish in {TIMEOUT}s, so the apprt "
              "path was not compiled. Not a pass.")
        return 1

    took = time.time() - started
    print(f"compiled the apprt path the fast floor skips in {took:.0f}s")
    print("  " + " ".join(BUILD))

    if r.returncode == 0:
        print("OK: it still compiles.")
        print(f"NOT CHECKED: that `{FAST_FLOOR}` covers it -- it does not, "
              "which is why this file exists; and nothing here can tell you "
              "the flags still mean what they meant.")
        return 0

    print()
    for line in (r.stderr or "").splitlines():
        if "error:" in line:
            print("  " + line.strip())
    print()
    print("FAIL: the apprt path does not compile, and the fast floor cannot "
          "see it.")
    print(f"      `{FAST_FLOOR}` will report every step and every test green "
          "with this error in the tree -- measured, twice.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
