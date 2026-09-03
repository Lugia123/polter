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
Exit: 0 when every arm that answers `true` acts, carries a reason, or is on
      the bill below -- and the bill matches the tree exactly.
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


# The arms that answer `true` without acting **today**, by the constant they
# name. Measured, not chosen: 2 bare and 3 log-only when this gate was written.
#
# # This is a bill, not an approval
#
# **Nothing on this list is correct.** Each one still tells the core an action
# was performed and performs nothing; they are recorded so that the gate can
# be green on a tree that already contains them, because a gate that is red
# from its first day is a gate people learn to scroll past -- and the line they
# learn to scroll past is where the next real one dies.
#
# **Keyed by name, never by count.** A count would let somebody fix
# `ACTION_RING_BELL`, add a new lying arm, and stay at five: the total agrees
# while the membership changed. That is the same shape as using a position for
# an identity, which this port has already paid for once.
#
# **Removing a name is required, not optional.** When an arm is fixed the gate
# goes red for the opposite reason -- a debt listed that is no longer owed --
# because a list that only ever shrinks keeps a slot open for whatever takes
# that name next, and a slot that outlives its reason is an exemption nobody
# granted.
OWED = {
    "ACTION_MOUSE_SHAPE",
    "ACTION_MOUSE_VISIBILITY",
    "ACTION_RENDER",
    "ACTION_RENDERER_HEALTH",
    "ACTION_RING_BELL",
    "ACTION_SHOW_CHILD_EXITED",
}


def verdict(now, owed):
    """`(newly lying, listed but no longer lying)`.

    Split out so both directions can be pinned by the self-test. **The second
    return value is the one an author will be tempted to drop**, and it is the
    half that keeps the list from turning into a permanent exemption.
    """
    return sorted(set(now) - set(owed)), sorted(set(owed) - set(now))


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
# same when green.** These samples are the whole of what this claims, in both
# directions, and they run before the tree is read so a broken probe cannot
# report a clean tree.
#
# The ratchet halves were also measured end to end on the real tree rather
# than only through `verdict`, by copying this file, editing `OWED`, and
# running it: dropping a name that is still lying gave `exit=1` with "not on
# the list", and adding a name that is not gave `exit=1` with "no longer
# lie". **A pure function passing its own unit test is not the same as the
# script going red**, and the two can come apart at the reporting.

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

# The ratchet, in both directions. **The second assertion is the one that
# stops the list becoming a permanent exemption**, and it is the reason this is
# a function rather than two lines of set arithmetic inside the report.
_new, _settled = verdict({"A", "B"}, {"B", "C"})
if _new != ["A"]:
    print("FAIL: the probe does not notice an arm that is lying and not on the list.")
    sys.exit(1)
if _settled != ["C"]:
    print("FAIL: the probe does not notice a debt that has been paid and left on "
          "the list -- so the list would go on excusing whatever takes that name.")
    sys.exit(1)

print("probe self-test: OK (bare, log-only, acting, excused; ratchet both ways)")

# -- the tree ----------------------------------------------------------------

here = os.path.dirname(os.path.abspath(__file__))
main_rs = os.path.join(here, "..", "host", "src", "main.rs")
with open(main_rs, encoding="utf-8") as fh:
    src = fh.read()

hits = list(scan(src))
lying = {tag for _, tags, _, why in hits if why is None for tag in tags.split(" | ")}
new, settled = verdict(lying, OWED)

print(f"scanned `cb_action`: {sum(1 for _ in cb.arms(src))} arms")
print()

for line, tags, kind, why in hits:
    names = set(tags.split(" | "))
    if why:
        mark = "excused"
    elif names - OWED:
        mark = "NEW    "
    else:
        mark = "owed   "
    print(f"  {mark} main.rs:{line}  {tags}")
    print(f"          answers true, {'and only logs' if kind == 'log-only' else 'and does nothing'}")
    if why:
        print(f"          reason: {why}")
print()

if not new and not settled:
    print(f"OK: {len(lying)} action(s) across {len(hits)} arm(s) still owe the core "
          f"an implementation, and they are the ones on the bill.")
    print("    None of them is correct. They are recorded so this gate can be read,")
    print("    not because doing nothing became the right answer.")
    sys.exit(0)

if new:
    print(f"FAIL: {len(new)} arm(s) tell the core an action was performed and perform")
    print("      nothing, and are not on the list:")
    for t in new:
        print(f"        {t}")
    print()
    print("      The core stops looking for another route for an action it believes")
    print("      was done, so this is not an unfinished feature -- it is a claim it")
    print("      cannot check. Either do the work, or return false, or -- if doing")
    print("      nothing really is correct here -- write the reason beside the arm:")
    print()
    print("          // answers true: <why nothing is the right answer>")
    print()
    print("      Adding it to OWED is the last resort, not the first: that list is")
    print("      a bill.")

if settled:
    print(f"FAIL, and it is good news: {len(settled)} arm(s) on the list no longer")
    print("      lie to the core. Remove them from OWED in this file:")
    for t in settled:
        print(f"        {t}")
    print()
    print("      This fails on purpose. A list that only ever shrinks by accident")
    print("      keeps a slot open for whatever takes that name next, and that slot")
    print("      is an exemption nobody granted.")

sys.exit(1)
