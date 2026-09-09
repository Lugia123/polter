#!/usr/bin/env python3
"""A name somebody chose and a name a program announced must not queue the
same thing.

**Written from a defect that had no wrong line in it.** `set_tab_title` (a
person's keybinding, or a supervisor naming a worker so somebody can find it)
and `set_title` (the program's own OSC 0/2) both queued
`Op::SetTabTitle { surface, title }` -- the identical op, with nothing in it
to say which was which. So the host could not prefer one, the last writer won,
and the program writes at every prompt. A name set by hand survived until the
next `cd`.

⚠️ **Nothing about that is visible in a log or a reply.** Both paths report
success, the tab shows a name the whole time, and the name it shows is the
wrong one only later. The only thing to check is that the two paths still
carry the distinction.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAIN = ROOT / "windows" / "host" / "src" / "main.rs"

# The two arms and what each must say about `explicit`.
WANT = {
    "ACTION_SET_TAB_TITLE": ("true", "a name somebody chose outranks the program's"),
    "ACTION_SET_TITLE": ("false", "the program's own title is a default, not a choice"),
}


def arm_body(src: str, tag: str) -> str:
    """The text of one `cb_action` arm, from its tag to the next arm."""
    m = re.search(r"(?:ffi::)?%s\s*=>" % re.escape(tag), src)
    if not m:
        return ""
    rest = src[m.end():]
    nxt = re.search(r"\n        (?:ffi::)?ACTION_[A-Z0-9_]+\s*=>|\n        _\s*=>", rest)
    return rest[: nxt.start()] if nxt else rest


def main() -> int:
    src = MAIN.read_text(encoding="utf-8")

    good = "Op::SetTabTitle { surface: s as usize, title: t, explicit: true }"
    bad = "Op::SetTabTitle { surface: s as usize, title: t }"
    probe_ok = re.search(r"explicit:\s*true", good) and not re.search(r"explicit:\s*\w+", bad)
    print(
        "probe self-test:",
        "OK (an op that carries the distinction and one that does not are told apart)"
        if probe_ok
        else "FAILED -- the reader is broken, so nothing below means anything",
    )
    if not probe_ok:
        return 2

    problems = []
    checked = 0
    for tag, (want, why) in sorted(WANT.items()):
        body = arm_body(src, tag)
        if not body:
            problems.append(f"{tag}: no arm found. Either it has gone or this reader has")
            continue
        if "Op::SetTabTitle" not in body:
            # This arm no longer names a tab. Not a fault -- but not this
            # checker's subject either, and saying so beats counting it.
            print(f"NOTE   {tag} no longer queues a tab title; nothing to check here")
            continue
        checked += 1
        if not re.search(r"explicit:\s*%s\b" % want, body):
            problems.append(
                f"{tag} queues a tab title without `explicit: {want}` ({why}). "
                "Two paths that queue the same op cannot be ranked, and the one that "
                "writes most often wins -- which is the program, at every prompt"
            )

    # ⚠️ Nothing to look at is not a pass: a reader that stopped finding these
    # arms would return 0 with a clean line, and that is indistinguishable from
    # a tree where both are right.
    if checked == 0:
        print("FAIL: neither title arm was found queueing a tab title -- this checker is "
              "looking in the wrong place")
        return 1

    print(f"{checked} title arm(s) read.")
    if problems:
        print("FAIL:")
        for p in problems:
            print(f"      {p}")
        return 1
    print("Nothing to report: an explicit name and a program's title are told apart at "
          "the point they are queued.")
    print("NOT CHECKED: what the queue does with the distinction, and whether a pinned "
          "name is what the strip paints. Those are the host's own tests, on Windows.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
