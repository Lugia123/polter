#!/usr/bin/env python3
"""Menu rows that name an action nobody handles.

**The defect this is here to stop, as it actually happened.** «文件 ▸ 新建窗口»
was not greyed, it could be clicked, and clicking it did nothing at all --
no window, no error, and **not one line in the log**. The core had parsed the
binding, performed it, and handed `GHOSTTY_ACTION_NEW_WINDOW` to the host;
`cb_action` fell through to `_ => false`, which is silent. Nothing anywhere
was wrong enough to say so.

**Three things it could have been, and they look identical from the chair:**
the menu row names an action that does not exist, the action exists and the
host does not answer it, or the action is answered and did nothing this time.
The first is caught by `assert_actions_exist` in `menu.rs`. The third is a
state, and the self-test's `nothing-to-do (state)` bucket reports it. **This
tool is the second one.**

The rule, which is computed rather than declared:

  * A menu row names an action. If `ffi.rs` declares `ACTION_<NAME>` then the
    core hands that action to the host by that name, so `cb_action` must have
    a branch for it.
  * If it has no branch, the row must be **greyed** -- and greyed *for a
    written reason*: `// greyed: <why>` next to whatever decides it, the same
    shape as `// process-wide:` in the log checker. "Greyed" alone is not
    enough, because greying a row is also how somebody makes this tool go
    quiet.
  * An action with no `ACTION_<NAME>` constant is outside this check: the core
    performs it itself and never asks the host. That number is printed rather
    than left implicit -- **a checker that cannot say how much it does not see
    is indistinguishable from one that sees everything.**

Exit: 0 if the unreasoned count equals the baseline, 1 otherwise.
"""

import glob
import os
import re
import sys

# **Measured, not chosen.** Rows that have no `cb_action` branch and no
# `// greyed:` reason. One today: `move_tab_to_new_window`, whose row is greyed
# in `strip.rs` with a paragraph explaining exactly why -- in a doc comment on
# `enabled()`, not in the form this tool can read. Going *up* means somebody
# added a row that will do nothing when clicked. Going *down* means the reason
# got written down, and the number here should follow it.
BASELINE_UNREASONED = 1

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host", "src")

GREYED_REASON = re.compile(r"//\s*greyed:\s*(\S.*)$")


def action_shaped(s: str) -> bool:
    return bool(s) and all(c in "abcdefghijklmnopqrstuvwxyz0123456789_:," for c in s)


def gap_is_row_punctuation(gap: str) -> bool:
    gap = gap.replace("action: Some(", "", 1)
    return all(c in " \t\r\n," for c in gap)


def adjacent_rows(src: str):
    """Rows written as two adjacent string literals."""
    i = 0
    while True:
        o1 = src.find('"', i)
        if o1 < 0:
            return
        c1 = src.find('"', o1 + 1)
        if c1 < 0:
            return
        label = src[o1 + 1 : c1]
        i = c1 + 1
        o2 = src.find('"', i)
        if o2 < 0:
            return
        if not gap_is_row_punctuation(src[c1 + 1 : o2]):
            continue
        c2 = src.find('"', o2 + 1)
        if c2 < 0:
            return
        action = src[o2 + 1 : c2]
        if not action_shaped(action) or not label or action_shaped(label):
            continue
        yield label, action, src[:o1].count("\n") + 1


def paired_match_rows(src: str):
    """The tab menu keeps labels and actions in two `match` arms over one enum,
    so the two halves are never adjacent. Joined on the variant name."""

    def arms(fn):
        m = re.search(r"fn %s\(self\)[^\{]*\{\s*match self \{(.*?)\n        \}" % fn, src, re.S)
        return dict(re.findall(r"(\w+)::(\w+) => \"([^\"]*)\"", m.group(1))and
                    [(k, v) for _, k, v in re.findall(r"(\w+)::(\w+) => \"([^\"]*)\"", m.group(1))]) if m else {}

    labels, actions = arms("label"), arms("action")
    for key, label in labels.items():
        if key in actions:
            yield label, actions[key], 0


def menu_rows():
    """Every row of every menu, with where it came from."""
    out = []
    for name, kind in (
        ("menu.rs", "adjacent"),
        ("ctxmenu.rs", "adjacent"),
        ("strip.rs", "adjacent"),
        ("strip.rs", "paired"),
    ):
        path = os.path.join(ROOT, name)
        with open(path, encoding="utf-8") as fh:
            whole = fh.read()
        body = whole.split("#[cfg(test)]")[0]
        rows = list(adjacent_rows(body)) if kind == "adjacent" else list(paired_match_rows(whole))
        out.append((name, kind, rows, whole))
    return out


def handled_tags(main_src: str):
    """The `ACTION_*` constants `cb_action` has a branch for.

    **Parsed as match arms, not by searching the body**, because the spellings
    vary in three ways that each cost a wrong answer when guessed: `ffi::ACTION_X`
    and bare `ACTION_X` are both used, and or-patterns (`A | B =>`) put two
    names on one arm. Counting occurrences of `ACTION_` in the function body
    instead would also collect the ones mentioned inside arm *bodies*.
    """
    at = main_src.index('extern "C" fn cb_action')
    # The `match` the arms live in, not the function's own braces.
    m = main_src.index("match action.tag {", at)
    open_brace = main_src.index("{", m)
    depth, k = 0, open_brace
    while k < len(main_src):
        if main_src[k] == "{":
            depth += 1
        elif main_src[k] == "}":
            depth -= 1
            if depth == 0:
                break
        k += 1
    body = main_src[open_brace + 1 : k]

    tags = set()
    arms = 0
    depth = 0
    pattern_start = 0
    i = 0
    while i < len(body):
        c = body[i]
        if c in "{([":
            depth += 1
        elif c in "})]":
            depth -= 1
            if depth == 0:
                pattern_start = i + 1  # an arm body just ended
        elif c == "," and depth == 0:
            pattern_start = i + 1
        elif body[i : i + 2] == "=>" and depth == 0:
            pattern = body[pattern_start:i]
            found = re.findall(r"\bACTION_[A-Z0-9_]+", pattern)
            if found:
                arms += 1
                tags.update(found)
            pattern_start = i + 2
            i += 1
        i += 1
    return tags, arms


def declared_constants(ffi_src: str):
    return set(re.findall(r"^pub const (ACTION_[A-Z0-9_]+):", ffi_src, re.M))


def greyed_reason_near(src: str, action: str) -> bool:
    """Is there a `// greyed: <reason>` within sight of this action's row?

    **Both directions, and that was not the first guess.** Looking only
    backwards from the action's own text found nothing in `strip.rs`: the
    action lives in one `match` arm and what greys it is a `fn enabled` further
    down, so the reason sits *after* every mention of the name. The floor for
    this tool caught it -- adding the reason changed no number -- which is the
    same failure this tool exists to stop, one level up: a check that cannot
    see the thing it is asking for reads exactly like a check that is satisfied.
    """
    lines = src.splitlines()
    for m in re.finditer(re.escape(action), src):
        at = src[: m.start()].count("\n")
        for line in lines[max(0, at - 12) : at + 7]:
            if GREYED_REASON.search(line):
                return True
    return False


# --------------------------------------------------------------- self-test
#
# Both directions, and the two spellings that have each already produced a
# wrong answer. A probe that stopped matching would report zero unhandled rows
# and read exactly like a clean tree.
CANARY_MAIN = '''
extern "C" fn cb_action(_app: App, target: Target, action: Action) -> bool {
    match action.tag {
        ffi::ACTION_TOGGLE_COMMAND_PALETTE => { true }
        ACTION_NEW_WINDOW => { true }
        ACTION_MOUSE_SHAPE | ACTION_MOUSE_VISIBILITY => true,
        ffi::ACTION_CLOSE_WINDOW | ffi::ACTION_QUIT => {
            logf!("[action] close_window/quit tag={}", action.tag);
            true
        }
        _ => false,
    }
}
'''


def self_test() -> None:
    tags, arms = handled_tags(CANARY_MAIN)
    want = {
        "ACTION_TOGGLE_COMMAND_PALETTE",  # the `ffi::` spelling
        "ACTION_NEW_WINDOW",              # the bare spelling
        "ACTION_MOUSE_SHAPE",             # an or-pattern, first half
        "ACTION_MOUSE_VISIBILITY",        # an or-pattern, second half
        "ACTION_CLOSE_WINDOW",            # an or-pattern with the prefix
        "ACTION_QUIT",
    }
    missing = want - tags
    if missing:
        print(f"FAIL: the arm parser cannot see {sorted(missing)}.")
        sys.exit(1)
    if arms != 4:
        print(f"FAIL: the arm parser saw {arms} arms in a four-arm match.")
        sys.exit(1)
    # And it must not invent handling: a name mentioned only inside an arm body
    # is not a branch.
    if "ACTION_RENDER" in handled_tags(
        CANARY_MAIN.replace('logf!("[action] close_window/quit tag={}", action.tag);',
                            'let _ = ffi::ACTION_RENDER;')
    )[0]:
        print("FAIL: the arm parser counts names used inside an arm body as handled.")
        sys.exit(1)
    if not GREYED_REASON.search("    // greyed: no second frame exists yet"):
        print("FAIL: the reason pattern does not match its own shape.")
        sys.exit(1)
    if GREYED_REASON.search("    // greyed because nobody wrote it"):
        print("FAIL: the reason pattern accepts a comment with no `greyed:` marker.")
        sys.exit(1)
    print("probe self-test: OK (both spellings, or-patterns, arm bodies excluded, reason shape pinned)")


def main() -> int:
    self_test()
    with open(os.path.join(ROOT, "main.rs"), encoding="utf-8") as fh:
        main_src = fh.read()
    with open(os.path.join(ROOT, "ffi.rs"), encoding="utf-8") as fh:
        ffi_src = fh.read()

    handled, arms = handled_tags(main_src)
    declared = declared_constants(ffi_src)

    total = reaches_host = ok = greyed = 0
    core_only = 0
    hosts_own = 0
    bad = []
    for name, kind, rows, whole in menu_rows():
        for label, action, line in rows:
            total += 1
            if action.startswith("__polter_") or action.startswith("host:"):
                hosts_own += 1
                continue
            const = "ACTION_" + action.split(":")[0].upper()
            if const not in declared:
                core_only += 1
                continue
            reaches_host += 1
            if const in handled:
                ok += 1
            elif greyed_reason_near(whole, action):
                greyed += 1
            else:
                bad.append((name, kind, label, action, const, line))

    print(
        f"cb_action: {arms} arms naming {len(handled)} of the {len(declared)} "
        f"ACTION_* constants ffi.rs declares"
    )
    print(
        f"menu rows: {total} scanned; {hosts_own} the host's own; {core_only} name an action "
        f"the core performs itself (no ACTION_* constant, outside this check); "
        f"{reaches_host} reach the host -- {ok} handled, {greyed} greyed with a written reason"
    )

    for name, kind, label, action, const, line in bad:
        where = f"{name}:{line}" if line else f"{name} ({kind})"
        print(
            f"HIT    {where}  {label!r} runs `{action}` -> {const}, which cb_action does not "
            f"handle. Clicking it does nothing and logs nothing."
        )
        print(
            f"       Either add the branch, or grey the row and write `// greyed: <why>` "
            f"beside whatever decides it."
        )

    n = len(bad)
    if n == BASELINE_UNREASONED:
        print(f"{n} row(s) unhandled and unreasoned (baseline {BASELINE_UNREASONED}).")
        return 0
    if n > BASELINE_UNREASONED:
        print(f"\n{n} unhandled and unreasoned, baseline {BASELINE_UNREASONED}. A row that "
              f"does nothing when clicked, and says nothing when it does.")
        return 1
    print(f"\nFAIL, and it is good news: {BASELINE_UNREASONED - n} fewer than the baseline.")
    print(f"      Set BASELINE_UNREASONED = {n}.")
    print("      A baseline left above the real number lets the work roll back for free.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
