#!/usr/bin/env python3
"""Find log lines about one window that do not say which window.

**Written before the second window exists, which is the only time it can be
checked against a tree where the right answer is known.** With one frame every
line is unambiguous by accident. With two, a line like

    [strip] click -> activate Tab(3)

has no answer to "which window?" -- and it does not turn red when that
happens, it turns *unreadable*. A criterion that fails gets looked at; one
that can no longer be judged gets believed.

**Every line is per-window until someone writes down why it is not**, and the
writing-down happens at the line, not in a list here. Three ways for a tagged
log call to be in order:

  * `wlogf!(frame, ...)` -- about one window, and says which.
  * `plogf!(...)` with `// process-wide: <reason>` on the line above -- not
    about any window, and says why.
  * plain `logf!` naming a `TabId` or `PaneId` -- already unambiguous, because
    those come from one counter shared by every window.

Anything else is unclassified, and unclassified is what the ratchet counts.

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

# How many of the remaining unclassified sites to print with their line
# numbers. A number, not all of them: a reader needs somewhere to start.
LIST_LINES = 12

# How many per-window lines were still untagged when this ratchet was set.
#
# **Measured, not chosen**, and it has gone up once on purpose:
#
#   221  `372b5cece`  the default flipped from a six-tag whitelist to
#                     "everything, unless declared"
#   217  `98af8cff5`  the four `[menu]` lines that show and dispatch a menu
#                     for one window were tagged
#   191  this commit  8: `search.rs` 4 process-wide + 1 tagged, `hud.rs` 3
#                     process-wide. All 8 had been unclassified, so this time
#                     the drop and the conversion count agree.
#   199  7019467de    5, and the batch was budgeted at 18. `divider.rs` gave
#                     2 process-wide (the window class) + 3 tagged, `dnd.rs`
#                     gave 1 (OLE init). **The other 13 are left, and each is
#                     left for a stated reason** -- see the report; the short
#                     version is that they are about a *pane* or an overlay
#                     rather than about a frame, and the identity they would
#                     need does not exist yet.
#
#                     Six conversions produced a drop of five: `[div] sync:`
#                     was already exempt for naming "panes", so tagging it
#                     moved it between two columns without changing the count.
#                     **"Drop == conversions" is the wrong equation; the right
#                     one is "drop == conversions that were unclassified".**
#   204  6d5796283    21 declared process-wide at the call site: 11 in
#                     `plugins.rs` (manifests, settings files, the catalog on
#                     disk) and 10 in `settings_ui.rs` (the three singleton
#                     windows and the config they show). One hand this time,
#                     and the drop matched the count exactly.
#   225  f93827b5b    **two hands, one commit, on purpose.**
#                       11  `palette.rs` -- 10 declared process-wide at the
#                           call site, 1 tagged (`[palette] shown at`, which
#                           can name the frame `show()` already positions
#                           itself against)
#                        1  `menu.rs` -- `[menu] CreatePopupMenu failed` now
#                           carries a frame, because `build` gained one.
#                           **That change is W1's, not this batch's author's.**
#                     12 = 1 + 11, and the arithmetic is what said a second
#                     hand had been in the tree: the drop was one larger than
#                     the lines this author had classified.
#
#                     They land together because they cannot land apart. The
#                     `menu.rs` change lowers the real count the moment it is
#                     committed, and a baseline still reading 237 would then
#                     fail for everybody -- a gate red for work already done
#                     blocks the innocent. So the change and the baseline it
#                     moves belong in one commit.
#   237  e7ad63d6f    17 of `menu.rs`'s 18 unclassified lines were declared
#                     process-wide at the call site. The 18th, `CreatePopupMenu
#                     failed`, is left on purpose -- see below.
#   254  c45e3ba71    the tag table was deleted; its 37 declarations became
#                     unclassified again, because a declaration by tag was
#                     never true for a tag that is half one thing and half
#                     the other. **The rise is the rule getting stricter, not
#                     a regression** -- and it is written here rather than
#                     left for someone to discover as an unexplained jump.
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
# 106 -> 77: `dnd.rs` 8, `ctxmenu.rs` 6 of 7, `hud.rs` 6, `keyseq.rs` 6,
# `overlay.rs` 3. The one `ctxmenu.rs` keeps is `on_poltergeist_mark`, which is
# about one terminal and is not given it -- a `plogf!` there would be a false
# claim, so it stays visible instead.
# 170 (this commit): `reopen.rs`'s last 3. `remember` now takes the frame *and*
# an `Option<TabId>`. The option is not a missing argument -- the put-back
# after a failed reopen names a tab destroyed long ago, and inventing an id
# there would be the only line in the file whose subject does not exist.
BASELINE_UNTAGGED = 77

# **There is no table of process-wide tags here, and there used to be.**
# It was a second place where a fact lived, and it could not be right: `[menu]`
# is four lines about a window and eighteen about a static table, so no answer
# for the tag as a whole was true. The declaration now sits on the line that
# makes the claim -- `plogf!` with a `// process-wide: <reason>` above it --
# where the person writing it knows which of the two they are writing.
PROCESS_WIDE_COMMENT = re.compile(r"//\s*process-wide:\s*(\S.*)$")

# Something process-unique in the call's ARGUMENTS makes the window implicit.
# **Arguments only, not the message text.** Matching the text exempted two
# lines in `strip.rs` because the English word "id" appeared in a sentence.
ALREADY_NAMED = re.compile(r"\bid\b|TabId|PaneId|pane|surface|\.id")


# **One list, read twice.** The macro names used to be spelled out in both
# regexes below, and the two lists disagreeing is not a hypothetical: a macro
# missing from the first is a site this checker cannot see, and one missing
# from the second is a site it cannot even count as unseen. `hlogf!` was added
# to the first and would have been forgotten in the second.
MACROS = ("wlogf", "plogf", "alogf", "hlogf", "logf")


def sites(src: str):
    """Yield (offset, macro, tag, args) for every tagged log call.

    The first argument of `wlogf!` is matched loosely on purpose: it may be
    `frame`, `self.frame`, `g.menu`, `HWND(h)`. The first version required a
    plain identifier and so **did not see** those call sites at all -- they
    counted as neither tagged nor untagged, which is the worst of the three.
    """
    for m in re.finditer(
        r"\b(" + "|".join(MACROS) + r")!\(\s*((?:[^,\"()]|\([^()]*\))*,\s*)?\"(\[[a-z]+\])([^\"]*)\"",
        src,
    ):
        depth, k = 1, m.end()
        while k < len(src) and depth > 0:
            if src[k] == "(":
                depth += 1
            elif src[k] == ")":
                depth -= 1
            k += 1
        # **A log call inside a doc comment is not a call.** `winid.rs`
        # documents both macros with worked examples, and counting those made
        # this report a declaration that does not exist -- the same class of
        # false positive `lock-reentry.py` records having hit, where a comment
        # explaining the lock made its own module look like a locker.
        bol = src.rfind("\n", 0, m.start()) + 1
        if src[bol:m.start()].lstrip().startswith("//"):
            continue
        yield m.start(), m.group(1), m.group(3), src[m.end():k]


def untagged_calls(src: str) -> int:
    """Log calls with no `[tag]` at all -- structurally invisible to `sites`.

    Reported rather than ignored: a checker that can say how much it cannot see
    is a different instrument from one that implies it saw everything.
    """
    total = len(re.findall(r"\b(?:" + "|".join(MACROS) + r")!\(", src))
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
// process-wide: the executable's own identity, one per process
plogf!("[build] sha256 {}", sha);
"""

# `plogf!` without its sentence. **A separate canary because it is a separate
# failure**: the line is out of the count either way, so without this the
# checker would let `plogf!` be used as a way to make a number go down.
CANARY_UNREASONED = 'plogf!("[menu] built {} groups", n);'

# `alogf!` must be seen and accepted; if this checker stops knowing the name,
# thirty-odd sites go invisible and the count falls for a reason that is not
# work being done.
CANARY_ALOGF = 'alogf!(origin, "[action] new_tab");'
CANARY_HLOGF = 'hlogf!(hwnd, "[drop] {:?} revoked", hwnd.0);'

# A reason spread over two lines, with the marker on the first. **Its own
# canary because the rule changed for it**: requiring the marker on the line
# immediately above silently rejected every two-line reason, and the failure
# read as "this line has no reason" rather than "the checker only looks up one
# line".
CANARY_TWO_LINE = """
// process-wide: OLE is initialised once for the process, before any
// drop target exists; no window is involved in the answer
plogf!("[drop] OleInitialize -> 0x{:08x}", hr);
"""
# The shape the first version could not see at all.
CANARY_FIELD = 'wlogf!(self.frame, "[strip] moved to {},{}", x, y);'


def bad_sites(src: str, name: str):
    """Unclassified sites, and `plogf!` sites whose reason is missing."""
    lines = src.split("\n")
    for start, macro, tag, args in sites(src):
        line_no = src[:start].count("\n") + 1
        # `alogf!(origin, ...)` is `wlogf!` when the action named a window and
        # `plogf!` when it did not -- both halves are inside the macro, with
        # the reason written there once. **Spelled out here on purpose**: a
        # macro this checker has never heard of is a site it cannot see, and
        # an invisible site reads exactly like a classified one.
        # `hlogf!(hwnd, ...)` is the same shape one level down: `wlogf!` when
        # the handle resolves to a *registered* frame and `plogf!` when it does
        # not, with the reason written once at the macro. The resolution is the
        # point -- `winid::of` names any handle it is given, so a pane or a null
        # would otherwise mint a window number for a window that does not exist.
        if macro in ("wlogf", "alogf", "hlogf") or ALREADY_NAMED.search(args):
            continue
        if macro == "plogf":
            # The reason is the point. `plogf!` on its own only moves a line
            # out of the count; the sentence above it is what a reader gets.
            # **The whole comment block above, not just the line above.**
            # A reason worth reading is sometimes two lines, and requiring it
            # to fit on one would buy shorter reasons rather than better ones.
            # The marker may sit anywhere in the contiguous run of `//` lines
            # immediately above the call.
            found = False
            i = line_no - 2
            while i >= 0 and lines[i].strip().startswith("//"):
                if PROCESS_WIDE_COMMENT.search(lines[i]):
                    found = True
                    break
                i -= 1
            if not found:
                yield name, line_no, f"{tag} plogf! with no `// process-wide:` reason"
            continue
        yield name, line_no, tag


def self_test() -> None:
    for name, canary in (("alogf", CANARY_ALOGF), ("hlogf", CANARY_HLOGF)):
        if not list(sites(canary)):
            print(f"FAIL: `{name}!` is not seen as a log site at all -- every one of "
                  "them reads exactly like a classified line, and they are not "
                  "even counted among the calls this checker cannot see.")
            sys.exit(2)
        if list(bad_sites(canary, "<canary>")):
            print(f"FAIL: `{name}!` was reported as unclassified.")
            sys.exit(2)
    seen = list(sites(CANARY_ALOGF))
    if len(seen) != 1 or seen[0][1] != "alogf":
        print(f"FAIL: `alogf!` is not recognised as a log site: {seen}")
        sys.exit(1)
    if list(bad_sites(CANARY_ALOGF, "<canary>")):
        print("FAIL: `alogf!` is reported as unclassified; it names its window by construction.")
        sys.exit(1)
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
    unreasoned = list(bad_sites(CANARY_UNREASONED, "<canary>"))
    if not unreasoned:
        print("FAIL: `plogf!` with no `// process-wide:` reason was accepted; the macro "
              "would then be a way to lower the count without saying anything.")
        sys.exit(1)
    spread = list(bad_sites(CANARY_TWO_LINE, "<canary>"))
    if spread:
        print(f"FAIL: a reason spread over two lines was rejected: {spread}")
        sys.exit(1)
    print("probe self-test: OK (unclassified seen, reasoned/exempt ignored, "
          "unreasoned plogf! caught, field-expression sites visible)")


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
            if macro == "wlogf":
                tagged += 1
            elif macro == "plogf":
                process += 1
            elif ALREADY_NAMED.search(args):
                exempt += 1
        bad.extend(bad_sites(src, name))

    summary_at = (tagged, exempt, process, invisible)

    # **The unreasoned `plogf!` sites are listed one by one, with line
    # numbers.** They are individually actionable -- somebody wrote the macro
    # and left out the sentence -- unlike the bulk below, which is a backlog
    # to be classified rather than a mistake to be corrected. Counting one as
    # "declared" in the summary above would also make that line disagree with
    # this one about the same site, so it is subtracted there.
    unreasoned = [h for h in bad if "no `// process-wide:`" in h[2]]
    for name, line, what in unreasoned:
        print(f"  {name}:{line}  {what}")
    process -= len(unreasoned)

    from collections import Counter
    rest = [h for h in bad if h not in unreasoned]
    for tag, n in Counter(t for _, _, t in rest).most_common():
        where = sorted({f for f, _, t in rest if t == tag})
        print(f"  {tag:12s} {n:3d} unclassified   ({', '.join(where)})")

    # **And where they are.** A per-tag count says how much is left; it does
    # not say what to open. The floor for this checker is "inject one untagged
    # line and see it named", and until this loop existed the answer was a
    # number that moved -- true, but not something anybody could act on
    # without grepping the tag themselves. Capped, because the point is to
    # give a reader somewhere to start, not to print the whole backlog.
    if rest:
        # Everything, when the count went *up*: that is the moment somebody
        # needs to find the line they just added, and a capped list sorted by
        # file name is unlikely to contain it.
        cap = len(rest) if n > BASELINE_UNTAGGED else LIST_LINES
        shown = sorted(rest, key=lambda h: (h[0], h[1]))[:cap]
        for name, line, tag in shown:
            print(f"       {name}:{line}  {tag}")
        if len(rest) > len(shown):
            print(f"       ... and {len(rest) - len(shown)} more")

    n = len(bad)
    tagged, exempt, process, invisible = summary_at
    print(f"scanned {len(paths)} files: {tagged} tagged, {exempt} name a tab or pane, "
          f"{process - len(unreasoned)} declared process-wide at the call site")
    print(f"  {invisible} log calls carry no [tag] at all and are not examined\n")
    print(f"{n} per-window log lines say nothing about which window "
          f"(baseline {BASELINE_UNTAGGED}).")

    if n > BASELINE_UNTAGGED:
        added = n - BASELINE_UNTAGGED
        print(f"FAIL: {added} more than the baseline. A per-window log line was added "
              f"without a window\n      identity. It reads fine today and stops being "
              f"readable the day there are two\n      windows -- which is not a day anyone "
              f"will connect to this commit.\n"
              f"      `wlogf!(frame, ...)` if it is about one window; `plogf!` with a\n"
              f"      `// process-wide: <reason>` line above it if it is not.")
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
