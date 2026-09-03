#!/usr/bin/env python3
"""Does a `cb_action` arm that answers `true` actually do anything?

`cb_action` returns a boolean to the core, and that boolean is a claim: **the
host performed this action.** The core believes it. An action it believes was
performed is one it stops looking for another route for -- so an arm that
returns `true` and does nothing is not an unfinished feature, it is a lie the
core has no way to check.

    ACTION_MOUSE_SHAPE | ACTION_MOUSE_VISIBILITY => true,

That is what this gate is for. **The repository has already cleaned this shape
once** -- eighteen arms that returned `true` unconditionally -- and these
survived, which is what a hand-sweep leaves behind: the instances go and
nothing stops the next one.

# Why not a whitelist

Every arm is in scope by default and an exemption is written next to the arm:

    // answers true: <why doing nothing is the correct answer here>
    ACTION_SOMETHING => true,

A whitelist would put **new** arms outside the check, and a new arm is exactly
what this exists to catch. The reason has to be written where the arm is,
because that is where somebody changing it will be.

# Two shapes, reported apart

  * **`true` with nothing at all.** The clearest case.
  * **`true` after only a log.** Also a claim that was not met -- a line in
    our log is not a bell rung or a message shown -- but it is worth telling
    apart, because the fix is usually smaller and the arm at least leaves a
    trace.

# How this differs from `menu-actions-handled.py`, and why they are two

They sit next to each other and the easy failure is each assuming the other
covers it, so:

  * that one asks **"is there an arm at all?"** -- a menu row naming an action
    `cb_action` has no branch for does nothing when clicked;
  * this one asks **"does the arm do what it says?"** -- a branch exists,
    answers yes, and performs nothing.

An action can pass one and fail the other in both directions, so neither
subsumes the other. **They do share their reading of the source**:
`_cb_action.py` walks the arms once and both import it, because "the arms of
`cb_action`" is one fact and this repository has spent a night on facts with
two readers.

Run:  python3 windows/tools/action-arms-act.py
Exit: 0 when every arm that answers `true` either acts or carries a reason.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cb_action as cb  # noqa: E402

LOG = re.compile(r"\b(alogf|wlogf|plogf|logf|hlogf)!\s*\(")
CALL = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*(?:::[A-Za-z_][A-Za-z0-9_]*\s*)*\(")
REASON = re.compile(r"//\s*answers true:\s*(\S.*)")

# Words that look like calls and are not: control flow, and the constructors
# that appear in every `match` and `if let` in this file.
NOT_CALLS = {"if", "match", "return", "while", "for", "unsafe", "Some", "None", "Ok", "Err"}


def strip_noise(text: str) -> str:
    """Comments and string bodies out, so neither can look like a call.

    A comment naming a function, or a log format string containing `(`, would
    otherwise read as work being done -- **the failure being that an arm doing
    nothing but explaining itself would pass**, which is the exact opposite of
    what a reason comment is supposed to buy.
    """
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r'"(\\.|[^"\\])*"', '""', text)
    return text


def classify(body: str):
    """`None` if the arm acts; otherwise `"bare"` or `"log-only"`."""
    clean = strip_noise(body)
    if not re.search(r"\btrue\b", clean):
        return None
    logged = LOG.search(clean) is not None
    without_logs = LOG.sub("IGNORED(", clean)
    calls = [c for c in CALL.findall(without_logs) if c not in NOT_CALLS and c != "IGNORED"]
    if calls:
        return None
    return "log-only" if logged else "bare"


def reason_for(main_src: str, line: int) -> str | None:
    """A `// answers true:` note on the arm or in the few lines above it."""
    lines = main_src.split("\n")
    lo = max(0, line - 8)
    for text in lines[lo:line]:
        m = REASON.search(text)
        if m:
            return m.group(1).strip()
    return None


def scan(main_src: str):
    for pattern, body, line in cb.arms(main_src):
        tags = cb.tags_of(pattern)
        if not tags:
            continue
        kind = classify(body)
        if kind is None:
            continue
        yield line, " | ".join(tags), kind, reason_for(main_src, line)


# -- self-test ---------------------------------------------------------------
#
# **A gate that has never been red and a gate that does not exist look the
# same when green.** These four samples are the whole of what it claims, in
# both directions, and they run before the tree is read so a broken probe
# cannot report a clean tree.

CANARY = '''
extern "C" fn cb_action(_app: App, target: Target, action: Action) -> bool {
    match action.tag {
        ACTION_ACTS => {
            queue_from(origin, Op::Thing, "because");
            true
        }
        ACTION_BARE => true,
        ACTION_LOG_ONLY => {
            alogf!(origin, "[action] noted");
            true
        }
        // answers true: the core only wants to be told, and being told is all
        // this platform has to do.
        ACTION_EXCUSED => true,
        _ => false,
    }
}
'''

found = {tags: (kind, why) for _, tags, kind, why in scan(CANARY)}

if "ACTION_BARE" not in found or found["ACTION_BARE"][0] != "bare":
    print("FAIL: the probe cannot see an arm that answers `true` and does nothing.")
    sys.exit(1)
if "ACTION_LOG_ONLY" not in found or found["ACTION_LOG_ONLY"][0] != "log-only":
    print("FAIL: the probe cannot tell a log-only arm from one that acts.")
    sys.exit(1)
if "ACTION_ACTS" in found:
    print("FAIL: the probe fires on an arm that does the work -- it would be "
          "ignored within a day.")
    sys.exit(1)
if found.get("ACTION_EXCUSED", (None, None))[1] is None:
    print("FAIL: the probe does not read the `// answers true:` reason, so "
          "there is no way to record a genuine one.")
    sys.exit(1)

print("probe self-test: OK (bare, log-only, acting, and excused -- all four)")

# -- the tree ----------------------------------------------------------------

here = os.path.dirname(os.path.abspath(__file__))
main_rs = os.path.join(here, "..", "host", "src", "main.rs")
with open(main_rs, encoding="utf-8") as fh:
    src = fh.read()

hits = list(scan(src))
unreasoned = [h for h in hits if h[3] is None]

print(f"scanned `cb_action`: {sum(1 for _ in cb.arms(src))} arms")
print()

for line, tags, kind, why in hits:
    mark = "     " if why else "*** "
    print(f"  {mark}main.rs:{line}  {tags}")
    print(f"       answers true, {'and only logs' if kind == 'log-only' else 'and does nothing'}")
    if why:
        print(f"       reason: {why}")
print()

if not unreasoned:
    print(f"OK: {len(hits)} arm(s) answer `true` without acting, and each says why.")
    sys.exit(0)

print(f"FAIL: {len(unreasoned)} arm(s) tell the core an action was performed and "
      f"perform nothing.")
print("      The core stops looking for another route for an action it believes")
print("      was done, so this is not an unfinished feature -- it is a claim it")
print("      cannot check.")
print()
print("      Either do the work, or return false, or -- if doing nothing really")
print("      is correct here -- write the reason beside the arm:")
print()
print("          // answers true: <why nothing is the right answer>")
print()
print("      **Floor when this gate was written: 2 bare, 3 log-only.** If you are")
print("      reading a different number, something moved; find out which before")
print("      changing the arm you came for.")
sys.exit(1)
