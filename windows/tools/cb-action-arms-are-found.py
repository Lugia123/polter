#!/usr/bin/env python3
"""Does the shared walk of `cb_action`'s arms still find them?

Five gates read `cb_action` through one parser, `lib/cb_action.py`:
`menu-actions-handled.py`, `action-arms-act.py`,
`app-actions-need-no-window.py`, `poltergeist-close-and-hold-are-wired.py` and
`reload-config-rereads.py`. This asks the one question they all depend on:
that the walk still returns arms, and that enough of them name `ACTION_*`
constants to be the real match rather than a fragment of it.

**It used to be the `__main__` of the parser itself**, as `_cb_action.py`,
and that one file carried two roles. The loops that run the gates disagreed
about which role counted -- one skipping `_*`, the meta-gate not -- and on an
empty tree it exited 1 by crashing on the missing file, so
`gates-fail-on-empty.py` recorded a refusal when the check had never run.

**So the subject is asked for before anything is parsed.** A missing
`main.rs`, or a `main.rs` with no `cb_action` match in it, is a FAIL that says
so -- not a traceback, and not zero arms read as a result.

Measured when it was split out (2026-09-27): blinding the parser to
`ACTION_*` turns all five importing gates red on their own, so for that
mutation this is a second guard rather than the only one. It stays because it
is the one that names the parser as the thing that broke.

Run:  python3 windows/tools/cb-action-arms-are-found.py
Exit: 0 when the walk finds at least `MIN_NAMED` arms naming `ACTION_*`;
      1 when `main.rs`, the function or its match is missing, or too few arms.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN_RS = os.path.join(HERE, "..", "host", "src", "main.rs")

# 75 of 81 arms named an `ACTION_*` constant when this was written; ten is far
# enough below that to survive ordinary churn and far enough above zero that a
# walk which has wandered into the wrong braces cannot reach it.
MIN_NAMED = 10


def main() -> int:
    # **Is the subject here?** Asked first, and answered with a FAIL: a gate
    # that crashes on a missing file exits non-zero too, and that exit code
    # cannot be told apart from this refusal by anything that only reads it.
    if not os.path.isfile(MAIN_RS):
        print(f"FAIL: {os.path.normpath(MAIN_RS)} does not exist, so there are "
              f"no arms to find. This is not a clean run -- it is looking in "
              f"the wrong place.")
        return 1

    with open(MAIN_RS, encoding="utf-8") as fh:
        src = fh.read()

    # A regex, not `in`: `extern "C" fn cb_action` is a prefix of any
    # `cb_action_*` beside it, and a substring test passed with the function
    # renamed to `cb_actionz` (measured when this was written).
    for needle, pattern in (('extern "C" fn cb_action(', r'extern "C" fn cb_action\s*\('),
                            ("match action.tag {", r"match action\.tag \{")):
        if not re.search(pattern, src):
            print(f"FAIL: main.rs has no `{needle}`. The walk starts there, so "
                  f"either the function moved or it was renamed -- and every "
                  f"gate that imports lib/cb_action.py would crash or read "
                  f"nothing.")
            return 1

    # Imported only now, so the questions above are answered even where lib/
    # is not -- a tree holding just this script still gets a FAIL that names
    # what is missing, not a ModuleNotFoundError.
    sys.path.insert(0, os.path.join(HERE, "lib"))
    import cb_action

    all_arms = list(cb_action.arms(src))
    named = [a for a in all_arms if cb_action.tags_of(a[0])]
    print(f"parsed {len(all_arms)} arm(s), {len(named)} of them naming "
          f"ACTION_* constants")

    if len(named) < MIN_NAMED:
        print()
        print(f"FAIL: fewer than {MIN_NAMED} is too few to be real. The walk "
              f"has stopped matching the source, and the gates that import "
              f"it are reading whatever it returns instead.")
        return 1

    print("OK: the shared walk still finds cb_action's arms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
