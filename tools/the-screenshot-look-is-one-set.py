#!/usr/bin/env python3
"""The screenshot overlay's look is one set of data, and both hosts have it.

**Why this exists.** The frozen-screen overlay is drawn by two hosts and is
meant to be one overlay (`dev-docs/poltergeist/screenshot.md`, 9.8). Its
first version was two hand-written copies of the same shapes, five of whose
sixteen icons were glyphs of whichever system font each host had. The icons'
ink ran from 8 to 16 points wide and from 6 to 20 tall, the two platforms
differed from each other, and every test was green: nothing compared them.

So the look is data -- `src/input/screenshot-look.json` -- and
`tools/gen-screenshot-look.py` writes it out as `windows/shots/src/look.rs`
and `macos/Sources/Features/Screenshot/ShotLook.swift`. The ways that
arrangement goes quietly wrong are what this gate looks for:

  1. **The data was changed and the generator was not run.** Both hosts keep
     building, from yesterday's numbers.
  2. **A generated file was edited by hand.** That host is now alone, and
     the next run of the generator silently takes the edit away.
  3. **One generated file is missing.** A host with no `look` is a host
     still drawing from its own copy.
  All three are one check: each file, byte for byte, is what the generator
  makes of the data now.

  4. **An icon's ink leaves the live area.** The artboard is 24 units and
     the ink stays inside 2..22, stroke included, so that every icon sits in
     its cell with the same margin. One icon is allowed out, by name and by
     how far (`outside_live` in the data); an exception that names an icon
     which is in fact inside, or whose box has moved, is stale and is a
     failure too.
  5. **The five sizes of T stop being five sizes.** Each is wider and taller
     than the one before.
  6. **The toolbar loses an icon.** Sixteen buttons and five sizes; a set of
     no icons is never a pass.

NOT CHECKED
  * That either host *draws* from `look`. Until each host's toolbar is
    rewired, the old drawing code is still what is on screen; this gate
    passes all the same.
  * That the two hosts' rasterisers agree. That is each host's own test
    (`windows/shots/src/icon.rs`, `macos/Tests/Screenshot/
    ShotIconRasterTests.swift`), against the ink boxes the generator puts in
    both files.
  * That the data says what the specification says. Section 9.8 is prose;
    nothing reads it.

Run:  python3 tools/the-screenshot-look-is-one-set.py
Exit: 0 when everything above holds; 1 otherwise.
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
GENERATOR = os.path.join(HERE, "gen-screenshot-look.py")

TOOLBAR = 16
SIZES = 5
# How far a box may be from the one the data pins for it, in artboard units.
PINNED = 0.002


def main():
    if not os.path.isfile(GENERATOR):
        print("FAIL: tools/gen-screenshot-look.py is not in the tree, so nothing says what the generated files should be.")
        return 1
    spec = importlib.util.spec_from_file_location("gen_screenshot_look", GENERATOR)
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)

    try:
        files, data, icons = gen.generate(ROOT)
    except gen.Bad as e:
        print(f"FAIL: {e}")
        return 1

    problems = []

    # 1-3: each generated file is what the data makes.
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

    # 6: the set is whole.
    by_key = {i["key"]: i for i in icons}
    toolbar = data.get("toolbar_icons") or []
    sizes = data.get("font_icons") or []
    if len(toolbar) != TOOLBAR:
        problems.append(f"toolbar_icons lists {len(toolbar)} icons; the toolbar has {TOOLBAR} buttons.")
    if len(sizes) != SIZES:
        problems.append(f"font_icons lists {len(sizes)} icons; there are {SIZES} font sizes.")
    listed = set(toolbar) | set(sizes)
    for key in by_key:
        if key not in listed:
            problems.append(f"icon {key} is in no list: nothing would ever draw it.")

    # 4: the ink stays in the live area.
    grid = data["icon_grid"]
    lo, hi = grid["live_min"], grid["live_max"]
    allowed = data.get("outside_live") or {}
    checked = 0
    for key, icon in by_key.items():
        box = gen.outline_box(icon["parts"])
        checked += 1
        outside = box[0] < lo - 1e-9 or box[1] < lo - 1e-9 or box[2] > hi + 1e-9 or box[3] > hi + 1e-9
        said = ", ".join(f"{v:.3f}" for v in box)
        if key in allowed:
            pinned = allowed[key]
            if not outside:
                problems.append(
                    f"outside_live names {key}, whose ink ({said}) is inside {lo}..{hi}: "
                    "the exception is stale, take it out."
                )
            elif len(pinned) != 4 or any(abs(a - b) > PINNED for a, b in zip(box, pinned)):
                problems.append(
                    f"{key}'s ink is ({said}); outside_live pins it at {pinned}. "
                    "An icon allowed out of the live area is allowed out by exactly that much."
                )
        elif outside:
            problems.append(
                f"{key}'s ink ({said}: left, top, right, bottom, stroke included) leaves the live area {lo}..{hi}."
            )
    for key in allowed:
        if key not in by_key:
            problems.append(f"outside_live names {key}, which is not an icon.")

    # 5: the sizes of T grow.
    boxes = [gen.outline_box(by_key[k]["parts"]) for k in sizes if k in by_key]
    for n in range(1, len(boxes)):
        w0, h0 = boxes[n - 1][2] - boxes[n - 1][0], boxes[n - 1][3] - boxes[n - 1][1]
        w1, h1 = boxes[n][2] - boxes[n][0], boxes[n][3] - boxes[n][1]
        if not (w1 > w0 and h1 > h0):
            problems.append(
                f"font size {n + 1} ({w1:.2f} x {h1:.2f}) is not both wider and taller than size {n} ({w0:.2f} x {h0:.2f})."
            )

    if checked == 0:
        problems.append("no icons were looked at.")

    if problems:
        print("FAIL: the screenshot overlay's look is not one set:")
        for p in problems:
            print("      " + p)
        return 1

    print(
        f"OK: {len(files)} generated files are what {gen.DATA} makes; {checked} icons "
        f"({len(toolbar)} buttons, {len(sizes)} sizes of T), {checked - len(allowed)} inside the live area "
        f"and {len(allowed)} out of it by a pinned amount."
    )
    print("NOT CHECKED: that either host draws from it; that the two rasterisers agree (each host's own test).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
