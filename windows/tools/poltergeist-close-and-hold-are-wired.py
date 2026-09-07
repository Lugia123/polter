#!/usr/bin/env python3
"""The two Poltergeist routes this host does not answer.

Two facts, one gate, because they are one sentence: **an agent can be told a
thing happened that did not, and a person has no way to say the thing that
only a person may say.**

# 1. `poltergeist_close` writes its result, or the agent is told a lie

`ghostty_action_poltergeist_close_s` carries `result`, an out parameter. The
core initialises it to `UNSUPPORTED` -- zero on purpose, so that an apprt
which quietly does nothing is reported as having done nothing -- and reads it
back the moment the callback returns. `PoltergeistClose.Result.toolAnswer`
in `src/apprt/action.zig` turns those three values into what the agent's
`terminal_action` tool says.

So there are two ways to be wrong here and they fail in opposite directions:

  * **no arm at all.** `cb_action` falls through to `_ => false`, the result
    stays `UNSUPPORTED`, and the agent is told the action was ignored. That
    is honest, and it is what the host does today -- closing a tab through
    the tool surface answers `unsupported` on Windows.
  * **an arm that closes and does not write.** The tab goes and the agent is
    still told it was ignored. **This is the worse one**, and it is the one
    that arrives the moment somebody adds the arm without reading the header,
    because everything looks right on screen.

The check is therefore not "is there an arm" -- `menu-actions-handled.py`
would ask that, and cannot here, because no menu row names this action -- but
"does the arm reach a write of the result".

# 2. `poltergeist_toggle_held` has a way in, and only a person's way in

The hold is the one Poltergeist state a supervisor may not set: a supervisor
that could lift it could clock the terminal off a moment later, which is what
the hold exists to prevent. `Bus.setHeld` refuses anything but `.user`, and
`Surface.zig` passes `.user` because a keybind is a person -- **so every host
route into this action is the host asserting that a person did it.**

`76fa175ba` took the row off all three menus; `1ca47f03b` closed the palette
door it had left open. What is left is a gate with no switch. This asks for
the switch back, on the one surface where the assertion is true: a menu row.
And it asks for **only** that -- the action's name must appear in `menu.rs`
and nowhere else under `windows/host/src`, because any second site is a
second claim that a person did this, and the next one to be added will not
be a menu.

**NOT CHECKED: whether the site that names it is really person-only.** A menu
row clicked by a person and a menu row driven by a self-test are the same
text. This counts sites; it cannot read intent.

Run:  python3 windows/tools/poltergeist-close-and-hold-are-wired.py
Exit: 0 when the close writes its result and the hold has exactly one door.
"""

import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host", "src")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cb_action as cb  # noqa: E402

HELD = "poltergeist_toggle_held"


def strip_noise(text: str) -> str:
    """Comments and string bodies out, for the code questions only.

    **Not used for the hold count**, where the action's name lives inside a
    string literal and stripping it would make every site invisible -- a
    checker that reported "one door" because it could see none.
    """
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r'"(\\.|[^"\\])*"', '""', text)
    return text


QUALIFIED = re.compile(r"\b(?:crate::)?([a-z_][a-z0-9_]*)::[A-Za-z_][A-Za-z0-9_]*\s*\(")
CALL = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")


def declares(src: str) -> set:
    return set(re.findall(r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*[(<]", src))


def reachable(arm_body: str, files: dict) -> str:
    """The arm plus the whole text of every host file it hands off to.

    Per file rather than per call, for the reason `reload-config-rereads.py`
    sets out at length: the work an action arm does mostly happens on the
    other side of a `PostMessage`, and no call edge crosses it.
    """
    clean = strip_noise(arm_body)
    # **Stripped per file, then joined.** Stripping the joined text instead
    # let one unbalanced quote -- a Rust `'"'` char literal, a `"` inside a
    # doc comment -- pair with a quote in the *next* file and swallow
    # everything between them. That is how this gate reported a write it was
    # holding in its own hand: the text was there and the span containing it
    # had been eaten. A checker whose subject can silently shrink is the
    # family of defect this directory exists for.
    text = strip_noise(arm_body)
    wanted = {m + ".rs" for m in QUALIFIED.findall(clean)}
    bare = set(CALL.findall(clean))
    for name, src in files.items():
        if name != "main.rs" and bare & declares(src):
            wanted.add(name)
    for name in sorted(wanted):
        if name in files:
            text += "\n" + strip_noise(files[name])
    return text


def analyse(files: dict):
    bad = []
    main_src = files.get("main.rs", "")
    ffi_src = files.get("ffi.rs", "")

    # --- 1. the close ------------------------------------------------------
    if "ACTION_POLTERGEIST_CLOSE" not in ffi_src:
        bad.append("ffi.rs declares no ACTION_POLTERGEIST_CLOSE constant.")

    arms = [(cb.tags_of(p), b, ln) for p, b, ln in cb.arms(main_src)]
    close = [(b, ln) for t, b, ln in arms if "ACTION_POLTERGEIST_CLOSE" in t]
    if not close:
        bad.append(
            "`cb_action` has no arm for ACTION_POLTERGEIST_CLOSE: it falls "
            "through to `_ => false`, the core's `result` cell keeps the "
            "`UNSUPPORTED` it was initialised to, and an agent closing a tab "
            "through the tool surface is told the action was ignored.")
    for body, line in close:
        text = reachable(body, files)
        wrote = re.search(r"POLTERGEIST_CLOSE_RESULT_[A-Z_]+", text) and re.search(
            r"(?:write\s*\(|write_unaligned\s*\(|\*\s*[A-Za-z_][A-Za-z0-9_]*\s*=)", text)
        if not wrote:
            bad.append(
                f"main.rs:{line}: the ACTION_POLTERGEIST_CLOSE arm never writes "
                "through `result`. The tab closes and the agent is still told "
                "the action was ignored, because the core reads back the "
                "`UNSUPPORTED` it put there.")

    # --- 2. the hold -------------------------------------------------------
    #
    # Counted over the raw text: the name lives in a string literal, so the
    # stripped copy would show no doors at all and call that a pass.
    doors = sorted(name for name, src in files.items() if HELD in src)
    if not doors:
        bad.append(
            f"`{HELD}` appears nowhere under windows/host/src. The action "
            "exists, the bus rule that only a keypress may work it exists, and "
            "`clock_out` still refuses a held terminal -- there is simply no "
            "switch on this platform.")
    elif doors != ["menu.rs"]:
        bad.append(
            f"`{HELD}` is named in {', '.join(doors)}. The hold is the one "
            "state only the person at the keyboard may set, so every site is a "
            "claim that a person did it: it belongs in menu.rs and nowhere "
            "else.")
    return bad


# -- self-test ---------------------------------------------------------------
#
# Both directions, before the tree is read, so a broken probe cannot report a
# clean tree.

GOOD = {
    "main.rs": '''
        extern "C" fn cb_action(_app: App, target: Target, action: Action) -> bool {
            match action.tag {
                ffi::ACTION_POLTERGEIST_CLOSE => { polterclose::perform(&action) }
                _ => false,
            }
        }
    ''',
    "ffi.rs": "pub const ACTION_POLTERGEIST_CLOSE: u32 = 71;\npub const POLTERGEIST_CLOSE_RESULT_CLOSED: i32 = 1;\n",
    "polterclose.rs": '''
        pub fn perform(a: &Action) -> bool {
            unsafe { p.write(ffi::POLTERGEIST_CLOSE_RESULT_CLOSED) };
            true
        }
    ''',
    "menu.rs": 'act("\\u4fdd\\u6301", "poltergeist_toggle_held"),\n',
}

TODAY = {
    "main.rs": '''
        extern "C" fn cb_action(_app: App, target: Target, action: Action) -> bool {
            match action.tag {
                ACTION_RING_BELL => true,
                _ => false,
            }
        }
    ''',
    "ffi.rs": "pub const ACTION_POLTERGEIST_CLOSE: u32 = 71;\n",
    "menu.rs": 'act("\\u91cd\\u8f7d\\u914d\\u7f6e", "reload_config"),\n',
}

LEAKY = dict(GOOD)
LEAKY["palette.rs"] = 'const EXTRA: &str = "poltergeist_toggle_held";\n'

WROTE_NOTHING = dict(GOOD)
WROTE_NOTHING["polterclose.rs"] = "pub fn perform(a: &Action) -> bool { close_tab(f, id); true }\n"

_bad = analyse(GOOD)
if _bad:
    print("FAIL: the probe rejects a host that does both things asked of it.")
    for line in _bad:
        print("  " + line)
    sys.exit(1)
if not any("no arm for ACTION_POLTERGEIST_CLOSE" in l for l in analyse(TODAY)):
    print("FAIL: the probe cannot see a missing close arm.")
    sys.exit(1)
if not any("appears nowhere" in l for l in analyse(TODAY)):
    print("FAIL: the probe cannot see that the hold has no door at all.")
    sys.exit(1)
if not any("is named in" in l for l in analyse(LEAKY)):
    print("FAIL: the probe cannot see a second door into the hold -- which is "
          "the one this repository has already had to close twice.")
    sys.exit(1)
if not any("never writes through `result`" in l for l in analyse(WROTE_NOTHING)):
    print("FAIL: the probe cannot tell a close that reports itself from one "
          "that closes the tab and lets the agent believe nothing happened.")
    sys.exit(1)

# -- the tree ----------------------------------------------------------------

files = {}
if os.path.isdir(ROOT):
    for name in sorted(os.listdir(ROOT)):
        if name.endswith(".rs"):
            with open(os.path.join(ROOT, name), encoding="utf-8") as fh:
                files[name] = fh.read()

print(f"read {len(files)} file(s) from windows/host/src")
if "main.rs" not in files or "ffi.rs" not in files or "menu.rs" not in files:
    print()
    print("FAIL: main.rs, ffi.rs or menu.rs is missing, so there was nothing to "
          "check. Not a pass.")
    sys.exit(1)

problems = analyse(files)
if not problems:
    print("OK: poltergeist_close reports what it did, and the hold has exactly "
          "one door.")
    print("NOT CHECKED: whether that door is really person-only -- a row a "
          "self-test clicks is the same text as a row a person clicks.")
    sys.exit(0)

print()
for line in problems:
    print("  " + line)
print()
print(f"FAIL: {len(problems)} problem(s).")
sys.exit(1)
