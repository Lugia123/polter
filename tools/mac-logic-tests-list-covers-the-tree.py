#!/usr/bin/env python3
"""Every macOS source and test file is on the logic tests' list, one side or the other.

**Why.** `tools/mac-logic-tests` runs the macOS host's logic tests without
starting the app, from a list of which files go into its package
(`tools/mac-logic-tests.json`). A test file nobody put on the list is a test
nobody runs, and nothing says so: the run is green without it. That is how a
test stayed red on the main line for a night -- each branch's own package
left out the other's half.

This is the part of that script that needs no compiler, as a gate: it asks
the script to check its list against the tree and build nothing. It takes a
fraction of a second, so it can run wherever the gates run; the tests
themselves are run by `tools/mac-logic-tests` (and by
`tools/pre-push-full-test`).

FAIL when a `.swift` file under a watched directory is on neither side of
the list, when a listed file is not in the tree, when something is left out
with no reason given, or when there is nothing to check at all.

NOT CHECKED: that the package builds; that any test passes; that a file
listed as going in is really exercised by a test.

Run:  python3 tools/mac-logic-tests-list-covers-the-tree.py
Exit: 0 when the list covers the tree; non-zero otherwise.
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "mac-logic-tests")


def main() -> int:
    if not os.path.isfile(SCRIPT):
        print("FAIL: tools/mac-logic-tests is not here, so there is no list to check and nothing was checked.")
        return 1
    p = subprocess.run([sys.executable, SCRIPT, "--check-list"], capture_output=True, text=True)
    sys.stdout.write(p.stdout)
    sys.stderr.write(p.stderr)
    if p.returncode != 0 and "FAIL" not in p.stdout:
        print("FAIL: tools/mac-logic-tests --check-list exited %d without saying why." % p.returncode)
    return p.returncode


if __name__ == "__main__":
    sys.exit(main())
