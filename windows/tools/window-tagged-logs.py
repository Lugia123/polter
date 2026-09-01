#!/usr/bin/env python3
"""Find log lines about one window that do not say which window.

**Written before the second window exists, which is the only time it can be
checked against a tree where the right answer is known.** With one frame every
line is unambiguous by accident. With two, a line like

    [strip] click -> activate Tab(3)

has no answer to "which window?" -- and it does not turn red when that
happens, it turns *unreadable*. A criterion that fails gets looked at; one
that can no longer be judged gets believed.

**Every tag is per-window until someone writes down why it is not.** The first
version had this the other way round -- a whitelist of six tags -- and the
default was wrong in the direction that matters: a *new* tag was unchecked by
default, and new tags are exactly what multi-window code produces. The list
below is therefore the exceptions, and each one carries its reason, because a
name on its own is how a real gap gets parked.

**A line is also exempt when it already names something process-unique.**
`TabId` and `PaneId` come from one counter shared by every window
(`State.next_id`), so a line naming one is already unambiguous. That claim is
not left as prose: `check_ids_are_process_wide` below fails if the counter ever
stops being single.

**A ratchet, not a pass/fail.** 221 lines were already untagged when this
check was written, and the two obvious ways to handle that are both wrong.
Failing outright would block every commit until someone finishes a mechanical
job -- **and until then it blocks the innocent, not the guilty.** Reporting
without failing makes it, in the words this file is trying to live up to,
indistinguishable from a checker nobody runs.

So the number is pinned. Going *up* fails, because somebody added a line that
will be unreadable the day there are two windows. Going *down* also fails,
with the number to write in -- **otherwise the progress silently rolls back
and nothing says so.** Only standing still is quiet, and the outstanding count
is printed on every run, so nobody gets to forget it is there.

Exit: 0 if the untagged count equals the baseline, 1 otherwise.
"""

import glob
import os
import re
import sys

# How many per-window lines were still untagged when this ratchet was set.
#
# **Measured, not chosen.** 221 on `372b5cece` (2026-09-02), the commit at
# which this check's default was flipped from a whitelist of six tags to
# "everything, unless declared". 217 after the four `[menu]` lines that show
# and dispatch a menu for one window were tagged.
#
# **The remainder is not one mechanical job.** Reading the untagged lines
# tag by tag shows most of them are not about a window at all -- `[menu] built
# 6 groups, 55 items`, `[palette] loaded 42 commands from the core`,
# `[quick] read_config ...` are facts about a table or the process. Those need
# a declaration with a reason, not a window identity, and the declaration this
# file offers is per *tag*, which cannot express "this tag is sometimes one and
# sometimes the other". `[menu]` is exactly that: 4 of its 22 lines are about a
# window and 18 are about the static menu table.
#
# **Lower this number when it drops.** The check insists on it, because a
# baseline that is allowed to be stale is a baseline that hides a regression
# behind work somebody else did.
BASELINE_UNTAGGED = 217

# Tags whose lines are NOT about one particular window. Each needs a reason.
PROCESS_WIDE = {
    "[build]": "the executable's own identity: one sha and size per process",
    "[wd]": "the watchdog thread, which watches the process, not a window",
    "[loop]": "the single message loop; one thread pumps every window",
    "[plug]": "plugin settings files, shared by the whole process",
    "[set]": "the settings window is deliberately one per process (S4-B ruling)",
    "[selftest]": "a whole-process self test",
    "[win]": "this tag *is* the frame-to-name pairing; tagging it would be circular",
}

# Something process-unique in the call's ARGUMENTS makes the window implicit.
# **Arguments only, not the message text.** Matching the text exempted two
# lines in `strip.rs` because the English word "id" appeared in a sentence.
ALREADY_NAMED = re.compile(r"\bid\b|TabId|PaneId|pane|surface|\.id")


def sites(src: str):
    """Yield (offset, macro, tag, args) for every tagged log call.

    The first argument of `wlogf!` is matched loosely on purpose: it may be
    `frame`, `self.frame`, `g.menu`, `HWND(h)`. The first version required a
    plain identifier and so **did not see** those call sites at all -- they
    counted as neither tagged nor untagged, which is the worst of the three.
    """
    for m in re.finditer(
        r"\b(w?logf)!\(\s*((?:[^,\"()]|\([^()]*\))*,\s*)?\"(\[[a-z]+\])([^\"]*)\"",
        src,
    ):
        depth, k = 1, m.end()
        while k < len(src) and depth > 0:
            if src[k] == "(":
                depth += 1
            elif src[k] == ")":
                depth -= 1
            k += 1
        yield m.start(), m.group(1), m.group(3), src[m.end():k]


def untagged_calls(src: str) -> int:
    """Log calls with no `[tag]` at all -- structurally invisible to `sites`.

    Reported rather than ignored: a checker that can say how much it cannot see
    is a different instrument from one that implies it saw everything.
    """
    total = len(re.findall(r"\b(?:w?logf)!\(", src))
    return total - sum(1 for _ in sites(src))


def check_ids_are_process_wide(root: str) -> list[str]:
    """The exemption above rests on ids being unique across windows.

    That is true because one counter hands them out. **Checked, not asserted:**
    the day someone gives each window its own counter -- a natural thing to do
    while splitting the state -- every `pane=7` in the log stops identifying
    anything, and this would otherwise keep reporting a clean tree.
    """
    src = open(os.path.join(root, "tabs.rs"), encoding="utf-8").read()
    problems = []
    if len(re.findall(r"\bnext_id\s*:\s*u64", src)) != 1:
        problems.append("`next_id` is no longer a single field on one State")
    if len(re.findall(r"^fn take_id\(\)", src, re.M)) != 1:
        problems.append("`take_id` is no longer the single id source")
    return problems


# --------------------------------------------------------------- self-test
CANARY_BAD = 'logf!("[strip] click -> activate at {},{}", x, y);'
CANARY_OK = """
wlogf!(frame, "[strip] click -> activate at {},{}", x, y);
logf!("[clip] read kind={} pane={} -> {} chars", kind, pane, n);
logf!("[strip] close {:?}", id);
logf!("[build] sha256 {}", sha);
"""
# The shape the first version could not see at all.
CANARY_FIELD = 'wlogf!(self.frame, "[strip] moved to {},{}", x, y);'


def bad_sites(src: str, name: str):
    for start, macro, tag, args in sites(src):
        if tag in PROCESS_WIDE or macro == "wlogf" or ALREADY_NAMED.search(args):
            continue
        yield name, src[:start].count("\n") + 1, tag


def self_test() -> None:
    if not list(bad_sites(CANARY_BAD, "<canary>")):
        print("FAIL: the probe cannot see an untagged per-window line.")
        sys.exit(1)
    noise = list(bad_sites(CANARY_OK, "<canary>"))
    if noise:
        print(f"FAIL: the probe fires on lines that are already unambiguous: {noise}")
        sys.exit(1)
    # **The third canary exists because the second one cannot catch this.**
    # A site the regex does not match produces no finding either way, so an
    # invisible call site and a correct one look identical from the outside.
    seen = list(sites(CANARY_FIELD))
    if len(seen) != 1 or seen[0][1] != "wlogf":
        print("FAIL: the probe cannot see `wlogf!(self.frame, ...)`; such sites "
              "would count as neither tagged nor untagged.")
        sys.exit(1)
    print("probe self-test: OK (untagged seen, exempt ignored, field-expression sites visible)")


def main() -> int:
    self_test()
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host", "src")

    for problem in check_ids_are_process_wide(root):
        print(f"FAIL: {problem}.\n      Lines exempted for naming a tab or pane no longer "
              f"identify one window's tab.")
        return 1

    paths = sorted(glob.glob(os.path.join(root, "*.rs")))
    tagged = exempt = process = invisible = 0
    bad = []
    for path in paths:
        name = os.path.basename(path)
        src = open(path, encoding="utf-8").read()
        invisible += untagged_calls(src)
        for _, macro, tag, args in sites(src):
            if tag in PROCESS_WIDE:
                process += 1
            elif macro == "wlogf":
                tagged += 1
            elif ALREADY_NAMED.search(args):
                exempt += 1
        bad.extend(bad_sites(src, name))

    print(f"scanned {len(paths)} files: {tagged} tagged, {exempt} name a tab or pane, "
          f"{process} process-wide by declaration")
    print(f"  {invisible} log calls carry no [tag] at all and are not examined")

    from collections import Counter
    for tag, n in Counter(t for _, _, t in bad).most_common():
        where = sorted({f for f, _, t in bad if t == tag})
        print(f"  {tag:12s} {n:3d} untagged   ({', '.join(where)})")

    n = len(bad)
    print(f"\n{n} per-window log lines say nothing about which window "
          f"(baseline {BASELINE_UNTAGGED}).")

    if n > BASELINE_UNTAGGED:
        added = n - BASELINE_UNTAGGED
        print(f"FAIL: {added} more than the baseline. A per-window log line was added "
              f"without a window\n      identity. It reads fine today and stops being "
              f"readable the day there are two\n      windows -- which is not a day anyone "
              f"will connect to this commit. Use `wlogf!(frame, ...)`,\n      or declare the "
              f"tag in PROCESS_WIDE with the reason it is not about one window.")
        return 1

    if n < BASELINE_UNTAGGED:
        print(f"FAIL, and it is good news: {BASELINE_UNTAGGED - n} fewer than the baseline.\n"
              f"      Set BASELINE_UNTAGGED = {n}.\n"
              f"      This fails on purpose. A baseline left above the real number lets the "
              f"work\n      roll back for free, and the next person to add an untagged line "
              f"would pass.")
        return 1

    print("at the baseline: nothing new went untagged.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
