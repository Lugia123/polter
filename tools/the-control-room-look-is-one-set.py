#!/usr/bin/env python3
"""The control room's look is one set of data, and both hosts have exactly it.

The control room is drawn by two hosts and is meant to be one thing
(`dev-docs/poltergeist/control-room.md`, 3.5). What it looks like is written
once, in `src/input/control-room-look.json`, and
`tools/gen-control-room-look.py` writes it out as
`windows/control-room/src/look.rs` and
`macos/Sources/Features/ControlRoom/ControlRoomLook.swift`.

What this gate holds:

  1. **Both generated files are byte for byte what the data makes now.** A
     value changed in the data and not regenerated, or a generated file
     touched by hand, is red, and the message names the first line that
     differs.
  2. **Nothing is set smaller than 13.** Every size in `numbers.font` is at
     least `font.min`, and `font.min` is at least 13 -- the floor is this
     gate's, so lowering `min` in the data does not lower it.
  3. **Where a status word is not red is in the data, and for the reason the
     data gives.** `text_on` says, per surface and theme, whether the word is
     written in the status colour or in the main text colour. This checks
     every cell against the rule the table states: the status colour where it
     reaches `threshold` against that surface, the fallback where it does
     not. And it checks the choice is still marked `tentative`, because the
     user has not ruled on it; when they do, the mark comes off here and in
     the data together.
  4. **No host writes those colours itself.** No source file of either host,
     other than the two generated ones, contains the hex of a status colour.
     A host that did would have its own copy of rule 3, which is what the
     table exists to prevent.
  5. **The data names no machine.** No home-directory path and no e-mail
     address in the data or in what is generated from it.

What it does not hold:

  * That either host draws from the generated file. Nothing does yet.
  * That the data says what the design says. The design is not in this
    repository; each value names the file it was read from, and that is all.
  * That contrast is sufficient anywhere else. `gen-control-room-look.py
    --contrast` prints every pair; which of them should stop a commit is not
    decided, so that is a report.

Run:  python3 tools/the-control-room-look-is-one-set.py
Exit: 0 when everything above holds; 1 otherwise.
"""

import glob
import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
GENERATOR = os.path.join(HERE, "gen-control-room-look.py")

FLOOR = 13
NOT_A_SIZE = ("weight_", "line_height_")
HOST_SOURCES = ("macos/Sources/**/*.swift", "windows/*/src/**/*.rs")
STATUS_COLOURS = ("attention", "attention_text", "problem", "problem_text")
LOCAL = (re.compile(r"/Users/|/home/|[A-Za-z]:\\\\Users"), re.compile(r"[\w.+-]+@[\w-]+\.[A-Za-z]{2,}"))


def main():
    if not os.path.isfile(GENERATOR):
        print("FAIL: tools/gen-control-room-look.py is not in the tree, so nothing says what the generated files should be.")
        return 1
    spec = importlib.util.spec_from_file_location("gen_control_room_look", GENERATOR)
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)

    try:
        files, d = gen.generate(ROOT)
    except gen.Bad as e:
        print(f"FAIL: {e}")
        return 1

    problems = []
    data = d["data"]

    # 1: each generated file is what the data makes.
    for path, text in files.items():
        full = os.path.join(ROOT, path)
        if not os.path.isfile(full):
            problems.append(f"{path} is not in the tree. Run `{gen.COMMAND}`.")
            continue
        have = open(full, encoding="utf-8", newline="").read()
        if have != text:
            want_lines, have_lines = text.split("\n"), have.split("\n")
            at = next((i for i, (a, b) in enumerate(zip(want_lines, have_lines)) if a != b),
                      min(len(want_lines), len(have_lines)))
            problems.append(
                f"{path} is not what {gen.DATA} makes (first difference at line {at + 1}). "
                f"If the data changed, run `{gen.COMMAND}`; if this file was edited, "
                "it is generated -- put the change in the data."
            )

    # 2: nothing smaller than 13.
    font = dict((k, v) for k, v, _, _, _ in next((items for g, _, items in d["groups"] if g == "font"), []))
    sizes = {k: v for k, v in font.items() if k != "min" and not k.startswith(NOT_A_SIZE)}
    if "min" not in font:
        problems.append("numbers.font has no `min`: nothing says what the smallest size is.")
    else:
        if font["min"] < FLOOR:
            problems.append(f"numbers.font.min is {font['min']}; nothing in the control room is set below {FLOOR}.")
        for k, v in sizes.items():
            if v < max(font["min"], FLOOR):
                problems.append(f"numbers.font.{k} is {v}, below the smallest size ({max(font['min'], FLOOR)}).")
    if not sizes:
        problems.append("numbers.font lists no sizes: no size was looked at.")

    # 3: where the status word is not red.
    rule = data.get("text_on") or {}
    role, fallback, bar = rule.get("role"), rule.get("fallback"), rule.get("threshold")
    cells = 0
    if not d["words"] or not isinstance(bar, (int, float)):
        problems.append("text_on is missing, or has no `threshold`: where a status word is not red is not in the data.")
    else:
        pal = d["palette"]
        for surface, colour, light, dark in d["words"]:
            for t, (theme, pick) in enumerate((("light", light), ("dark", dark))):
                cells += 1
                r = gen.ratio(pal[role][t], pal[colour][t])
                want = role if r >= bar else fallback
                if pick != want:
                    problems.append(
                        f"text_on.surfaces.{surface}.{theme} is `{pick}`, but `{role}` on `{colour}` is "
                        f"{r:.2f} against a threshold of {bar}, which makes it `{want}`."
                    )
        if f"text_on.{role}" not in d["tentative"]:
            problems.append(
                "text_on is no longer marked `tentative`. If the user has ruled on it, take this check "
                "out with the mark; if not, the mark was lost."
            )

    # 4: no host has its own copy of the status colours.
    pal = d["palette"]
    needles = sorted({"%02X%02X%02X" % pal[k][t][:3] for k in STATUS_COLOURS if k in pal for t in (0, 1)})
    generated = {os.path.normpath(os.path.join(ROOT, p)) for p in files}
    scanned = 0
    for pattern in HOST_SOURCES:
        for full in glob.glob(os.path.join(ROOT, pattern), recursive=True):
            if os.path.normpath(full) in generated:
                continue
            scanned += 1
            text = open(full, encoding="utf-8", errors="replace").read().upper()
            for n in needles:
                if n in text:
                    problems.append(
                        f"{os.path.relpath(full, ROOT)} contains {n}, one of the control room's status colours. "
                        f"Hosts read them from the generated file; the value belongs in {gen.DATA}."
                    )
    if len(needles) < 2:
        problems.append("the data has no status colours to look for in the hosts.")
    if scanned == 0:
        problems.append("no host source was looked at: neither macos/Sources nor windows/*/src has a file in it.")

    # 5: no machine is named.
    for path, text in [(gen.DATA, open(os.path.join(ROOT, gen.DATA), encoding="utf-8").read())] + list(files.items()):
        for pat in LOCAL:
            m = pat.search(text)
            if m:
                problems.append(f"{path} contains `{m.group(0)}`: a path or an address from somebody's machine.")

    if problems:
        print("FAIL: the control room's look is not one set:")
        for p in problems:
            print("      " + p)
        return 1

    print(
        f"OK: {len(files)} generated files are what {gen.DATA} makes; {len(sizes)} sizes, none below {FLOOR}; "
        f"{cells} cells of text_on follow its threshold ({bar}); {scanned} host sources hold none of "
        f"{len(needles)} status colours; {len(d['tentative'])} values still tentative."
    )
    print("NOT CHECKED: that either host draws from it; that the data matches the design; contrast outside text_on (see --contrast).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
