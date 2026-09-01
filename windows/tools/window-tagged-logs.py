#!/usr/bin/env python3
"""Find log lines about one window that do not say which window.

**Written before the second window exists, which is the only time it can be
checked against a tree where the right answer is known.** With one frame every
line is unambiguous by accident. With two, a line like

    [strip] click -> activate Tab(3)

has no answer to "which window?" -- and it does not turn red when that
happens, it turns *unreadable*. A criterion that fails gets looked at; one that
can no longer be judged gets believed. So the tag goes in now, and this keeps
it in.

**A line is exempt when it already names something process-unique.** `TabId`
and `PaneId` come from one counter shared by every window (`State.next_id`), so
a line naming one is already unambiguous and does not need a second name. That
is why this checks a property, not a file list: `[clip] read kind=0 pane=7`
needs no window tag, and adding one would be noise.

Exit: 0 if every ambiguous site uses `wlogf!`, 1 otherwise.
"""

import glob
import os
import re
import sys

# Tags whose lines describe the state of one window.
PER_WINDOW = {"[strip]", "[tab]", "[layout]", "[session]", "[tabmenu]", "[stripmenu]"}

# Something process-unique in the line makes the window implicit.
ALREADY_NAMED = re.compile(r"\bid\b|TabId|pane |pane=|surface|\.id")

# Sites that are understood to stay untagged. A name alone is not enough here:
# an entry without a reason is how a real gap gets parked forever.
KNOWN: dict[str, str] = {}


def sites(src: str):
    """Yield (offset, macro, tag, tail) for every log call with a tag."""
    for m in re.finditer(r"\b(w?logf)!\(\s*\n?\s*(?:[\w:]+\s*,\s*)?\"(\[[a-z]+\])([^\"]*)\"", src):
        start = m.start()
        depth, k = 1, m.end()
        while k < len(src) and depth > 0:
            if src[k] == "(":
                depth += 1
            elif src[k] == ")":
                depth -= 1
            k += 1
        yield start, m.group(1), m.group(2), m.group(3) + src[m.end():k]


def scan(src: str, name: str):
    for start, macro, tag, tail in sites(src):
        if tag not in PER_WINDOW:
            continue
        if ALREADY_NAMED.search(tail):
            continue
        if macro == "wlogf":
            continue
        line = src[:start].count("\n") + 1
        yield name, line, tag


# --------------------------------------------------------------- self-test
#
# Both directions. A probe that has stopped matching reports zero and reads
# exactly like a clean tree -- the failure this repository has hit repeatedly.
# And a probe that fires on everything is caught by nobody unless something
# clean is fed to it, which is what the second canary is for: without it,
# "an id exempts the line" is an assumption about our own rules.
CANARY_BAD = 'logf!("[strip] click -> activate at {},{}", x, y);'
CANARY_OK = """
wlogf!(frame, "[strip] click -> activate at {},{}", x, y);
logf!("[clip] read kind={} pane={} -> {} chars", kind, pane, n);
logf!("[strip] close {:?}", id);
logf!("[menu] built 6 groups");
"""


def self_test() -> None:
    if not list(scan(CANARY_BAD, "<canary>")):
        print("FAIL: the probe cannot see an untagged per-window line.")
        sys.exit(1)
    noise = list(scan(CANARY_OK, "<canary>"))
    if noise:
        print(f"FAIL: the probe fires on lines that are already unambiguous: {noise}")
        sys.exit(1)
    print("probe self-test: OK (sees an untagged line, ignores tagged and id-bearing ones)")


def main() -> int:
    self_test()
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host", "src")
    paths = sorted(glob.glob(os.path.join(root, "*.rs")))

    total, tagged, exempt, bad = 0, 0, 0, []
    for path in paths:
        name = os.path.basename(path)
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        for _, macro, tag, tail in sites(src):
            if tag not in PER_WINDOW:
                continue
            total += 1
            if macro == "wlogf":
                tagged += 1
            elif ALREADY_NAMED.search(tail):
                exempt += 1
        for hit in scan(src, name):
            if hit[0] in KNOWN:
                print(f"known  {hit[0]}:{hit[1]}  {hit[2]}")
                continue
            bad.append(hit)

    print(f"scanned {len(paths)} files; {total} per-window log lines: "
          f"{tagged} tagged, {exempt} already name a tab or pane")
    if bad:
        for name, line, tag in bad:
            print(f"HIT    {name}:{line}  {tag} says nothing about which window")
        print(f"\n{len(bad)} untagged. With a second window these lines stop being "
              f"readable, and nothing else reports that.")
        return 1
    print("no untagged per-window lines")
    return 0


if __name__ == "__main__":
    sys.exit(main())
