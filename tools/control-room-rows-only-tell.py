#!/usr/bin/env python3
"""A row of the control room tells; it does not answer for the person.

For one build the rows that were waiting for an approval carried a tick and a
cross, with `Y` and `N` beside them. The user looked at the picture and took
them off (2026-10-12): a row is too small to show what would be approved, and
what an agent asks is often not a yes or a no. The row says somebody is
waiting and for what -- the glyph, the word, the reason, the minutes, "and N
more" -- and the person goes into the terminal.

The core still takes `approve`, `refuse` and `reply`
(`src/poltergeist/ControlAct.zig`), and each host still has the few lines
that know how to write them. **What must not come back is a way to send one
from the control room's window.** So this refuses, in the hosts' control-room
sources:

  1. Making one of the three answering acts anywhere but the file that
     defines them: `.approve(…)`, `.refuse(…)`, `.reply(…)` in Swift outside
     `ControlRoomActions.swift`; `Act::Approve`, `Act::Refuse`, `Act::Reply`
     in the Windows host (`windows/host/src/control_room*.rs`; the crate
     `windows/control-room` is where they are defined and is not scanned for
     this).
  2. In the macOS list (`ControlRoomListView.swift`): more than the one
     button it has, which is "new group"; any named accessibility action;
     any closure handed in for acting on a row.
  3. The names the buttons went by, anywhere: `ControlRoomRowActs`,
     `ControlRoomActButtons`, `approvable`.

**NOT CHECKED.**

  * A way of answering that goes round these names -- a JSON request built
    by hand, a key sent to the terminal directly.
  * Whether what a row draws is enough to know what is being asked.
  * The Windows host's own drawing of a row: it is GDI, and a button there
    would be a rectangle and a hit test, which this cannot tell from any
    other.
  * Tests.

`--self-test` (also run first by every normal run) plants each offender in a
scratch file and checks it is caught, and that what is allowed is not.

Exit 0 and `scanned N files` with N > 0, or non-zero.
"""

import glob
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

SWIFT_GLOB = "macos/Sources/Features/ControlRoom/*.swift"
RUST_GLOB = "windows/host/src/control_room*.rs"
GENERATED = {"ControlRoomLook.swift"}
# Where the three acts are defined and written out.
DEFINES = "ControlRoomActions.swift"
LIST = "ControlRoomListView.swift"

NAMES = re.compile(r"\b(?:ControlRoomRowActs|ControlRoomActButtons|approvable)\b")
SWIFT_ACT = re.compile(r"\.\s*(?:approve|refuse|reply)\s*\(")
RUST_ACT = re.compile(r"\bAct\s*::\s*(?:Approve|Refuse|Reply)\b")
BUTTON = re.compile(r"\bButton\s*[\(\{]")
A11Y_ACTION = re.compile(r"\.\s*accessibilityAction\s*\(")
ROW_CLOSURE = re.compile(r"\bvar\s+on(?:Act|Approve|Refuse|Reply|Answer)\b")
# The list has one button: "new group".
LIST_BUTTONS = 1


def strip(text):
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return "\n".join(re.sub(r"//.*$", "", line) for line in text.split("\n"))


def scan(path, name=None):
    name = name or os.path.basename(path)
    with open(path, encoding="utf-8") as f:
        code = strip(f.read())
    hits = []
    buttons = []
    for n, line in enumerate(code.split("\n"), 1):
        if NAMES.search(line):
            hits.append((n, "a name the row's buttons went by", line.strip()))
            continue
        if name.endswith(".rs"):
            if RUST_ACT.search(line):
                hits.append((n, "makes an answering act", line.strip()))
            continue
        if name != DEFINES and SWIFT_ACT.search(line):
            hits.append((n, "makes an answering act", line.strip()))
            continue
        if name == LIST:
            if BUTTON.search(line):
                buttons.append((n, line.strip()))
            if A11Y_ACTION.search(line):
                hits.append((n, "a named action on a row", line.strip()))
            elif ROW_CLOSURE.search(line):
                hits.append((n, "a closure for acting on a row", line.strip()))
    for n, line in buttons[LIST_BUTTONS:]:
        hits.append((n, f"a button in the list beyond the {LIST_BUTTONS} it has", line))
    return hits


def self_test():
    cases = [
        ("ControlRoomController.swift", "try actions.perform(.approve(target))", True),
        ("ControlRoomController.swift", "send(.refuse(row.target))", True),
        ("ControlRoomSource.swift", "act = .reply(target, text: words)", True),
        ("ControlRoomActions.swift", "case .approve(let target): return aimed(\"approve\", at: target)", False),
        ("ControlRoomController.swift", "try actions.perform(.seen(group: group))", False),
        ("ControlRoomController.swift", "// it used to say .approve(target) here", False),
        ("ControlRoomListView.swift", "Button(action: onNewGroup) {", False),
        ("ControlRoomListView.swift", "Button(action: onNewGroup) {\nButton { press(row) } label: {", True),
        ("ControlRoomListView.swift", ".accessibilityAction(named: Text(\"Approve\")) { go() }", True),
        ("ControlRoomListView.swift", "var onAct: (Row) -> Void = { _ in }", True),
        ("ControlRoomListView.swift", ".accessibilityAddTraits(.isButton)", False),
        ("ControlRoomList.swift", "var approvable: Bool = false", True),
        ("ControlRoomView.swift", "ControlRoomActButtons(tint: a, quiet: b) { _ in }", True),
        ("control_room.rs", "let act = Act::Approve { row };", True),
        ("control_room.rs", "let act = Act::Seen { group: &row.id };", False),
        ("control_room_keys.rs", "// Act::Refuse was sent from here", False),
    ]
    with tempfile.TemporaryDirectory() as d:
        for i, (name, text, want) in enumerate(cases):
            p = os.path.join(d, f"{i}.txt")
            with open(p, "w", encoding="utf-8") as f:
                f.write(text + "\n")
            hit = bool(scan(p, name))
            if hit != want:
                return (f"self-test: `{text}` in {name} was {'caught' if hit else 'not caught'}, "
                        f"and should {'not ' if not want else ''}have been")
    return None


def main():
    problem = self_test()
    if "--self-test" in sys.argv:
        print(problem or "self-test: each planted offender is caught, each allowed spelling is not")
        return 1 if problem else 0
    if problem:
        print(f"FAIL: {problem}")
        return 1

    swift = [p for p in sorted(glob.glob(os.path.join(ROOT, SWIFT_GLOB)))
             if os.path.basename(p) not in GENERATED]
    rust = sorted(glob.glob(os.path.join(ROOT, RUST_GLOB)))
    if not swift and not rust:
        print("FAIL: scanned 0 files -- no control-room host sources were found, so nothing was checked")
        return 1
    if swift and not any(os.path.basename(p) == LIST for p in swift):
        print(f"FAIL: {LIST} is not among the macOS control-room sources; the list was not checked")
        return 1

    bad = 0
    for path in swift + rust:
        for n, what, line in scan(path):
            bad += 1
            print(f"{os.path.relpath(path, ROOT)}:{n}: {what}: {line}")

    print(f"scanned {len(swift) + len(rust)} files ({len(swift)} Swift, {len(rust)} Rust)")
    if bad:
        print(f"FAIL: {bad} line(s) that put an answer on a row of the control room. A row only tells; "
              "the person answers in the terminal (control-room.md, 3.2).")
        return 1
    print("OK: nothing in the control room's window approves, refuses or replies")
    print("NOT CHECKED: an answer sent round these names; whether a row says enough; "
          "the Windows host's own drawing of a row; tests.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
