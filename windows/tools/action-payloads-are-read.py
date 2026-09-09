#!/usr/bin/env python3
"""Every action whose C struct carries something must be seen to read it.

**Written because one arm dropped a payload for months and nothing said so.**
`GHOSTTY_ACTION_NEW_TAB` carries a `working_directory`; the arm queued an op
with no field for it, so every tab opened wherever the asking terminal stood
-- including the ones `terminal_open` had been given a directory for and had
checked existed. **It was silent**: the host's `starting in` line only exists
where a directory does, so the log had nothing to disagree with the request,
and the reply was a bare `ok`.

The shape that made it invisible is worth catching rather than remembering:
**an action that carries data, and an arm that names the action without ever
touching the data.** This reads `include/ghostty.h` for the actions whose
payload is a struct with at least one field, then reads `cb_action`'s arms and
asks whether each such arm mentions any decoder at all.

**What this cannot see**: an arm that decodes the payload and then ignores the
value. That is a different defect and needs a different reader; this one is
about the payload never being looked at.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "include" / "ghostty.h"
MAIN = ROOT / "windows" / "host" / "src" / "main.rs"

# **The exceptions are computed, not listed.** A hand-written list of names
# is the thing nobody maintains, and a new action would land outside it --
# where "outside" looks exactly like "already considered". An arm is excused
# only by something visible in the arm itself:
#
#   1. it hands the whole action to a helper (`something::perform(&action …)`),
#      which is where the decoding then happens;
#   2. it answers by name and performs nothing (`// refuses:` / `// owed:`),
#      so there is no value to act on;
#   3. it says in one line why the payload is not for it
#      (`// payload-unused: <why>`).
#
# Anything else with a struct payload has to be seen reading it.
HANDS_OFF = re.compile(r"::\w+\(\s*&?action\b")
ANSWERED_BY_NAME = re.compile(r"//\s*(refuses|owed):")
REASONED = re.compile(r"//\s*payload-unused:")


def struct_fields(header: str, name: str) -> int:
    """How many fields the payload struct for `name` has, or -1 if it is not
    a struct (a bare enum or nothing)."""
    m = re.search(
        r"typedef struct \{([^}]*)\}\s*" + re.escape(name) + r"\s*;", header, re.S
    )
    if not m:
        return -1
    body = m.group(1)
    return len([l for l in body.split(";") if l.strip()])


def main() -> int:
    header = HEADER.read_text(encoding="utf-8")
    main_src = MAIN.read_text(encoding="utf-8")

    # The union tells us which tag has which payload type.
    um = re.search(r"typedef union \{(.*?)\}\s*ghostty_action_u;", header, re.S)
    if not um:
        print("cannot find ghostty_action_u in the header")
        return 2
    payloads = {}
    for line in um.group(1).split("\n"):
        m = re.match(r"\s*(\w+)\s+(\w+);", line)
        if m:
            payloads[m.group(2)] = m.group(1)

    # `cb_action`'s arms, with their bodies.
    cb = main_src[main_src.index("extern \"C\" fn cb_action") :]
    cb = cb[: cb.index("\n}\n")]
    arms = {}
    for m in re.finditer(r"(?:ffi::)?(ACTION_[A-Z0-9_]+) =>", cb):
        start = m.end()
        nxt = re.search(r"\n        (?:ffi::)?ACTION_[A-Z0-9_]+ =>|\n        _ =>", cb[start:])
        arms[m.group(1)] = cb[start : start + (nxt.start() if nxt else len(cb) - start)]

    probe_ok = struct_fields(header, "ghostty_action_new_tab_s") == 1
    print(
        "probe self-test:",
        "OK (a one-field payload struct is seen as carrying something)"
        if probe_ok
        else "FAILED -- the header reader is broken, so nothing below means anything",
    )
    if not probe_ok:
        return 2

    missing = []
    checked = 0
    for field, typ in payloads.items():
        n = struct_fields(header, typ)
        if n <= 0:
            continue  # a bare enum or an empty struct: nothing to drop
        tag = "ACTION_" + field.upper()
        body = arms.get(tag)
        if body is None:
            continue  # this host has no arm for it; a different checker's job
        # The comment block above the arm is part of the arm for this
        # purpose: that is where `// refuses:` and the reason line live.
        above = cb[: cb.index(tag)].rsplit("\n\n", 1)[-1] if tag in cb else ""
        context = above + body
        if HANDS_OFF.search(body):
            continue
        if ANSWERED_BY_NAME.search(context):
            continue
        if REASONED.search(context):
            continue
        checked += 1
        # Any decoder at all. The names are `as_*`; a bare `as_i32` counts,
        # because a one-field payload is often just that.
        if not re.search(r"action\.as_\w+\(", body):
            missing.append((tag, typ, n))

    print(f"{checked} arm(s) whose action carries a struct payload were read.")
    if missing:
        print("FAIL: an arm names an action that carries data and never reads it:")
        for tag, typ, n in missing:
            print(f"      {tag}: {typ} has {n} field(s), and the arm calls no decoder")
        print(
            "      An action that carries a directory, a mode or a name, dropped here,\n"
            "      is silent: the host does the default thing and no line disagrees."
        )
        return 1

    print("Nothing to report: every arm that is handed data looks at it.")
    print(
        "NOT CHECKED: whether the value read is then used. An arm that decodes a\n"
        "             payload and ignores it passes this and is a real defect."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
