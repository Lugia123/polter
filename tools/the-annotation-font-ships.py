#!/usr/bin/env python3
"""The screenshot tool's font is in the tree, is the file it says it is, and is installed.

**Why this exists.** The screenshot tool draws text with one font it brings
along -- Noto Sans SC Regular -- so that an annotation is the same glyphs on
macOS and on Windows (`dev-docs/poltergeist/screenshot.md`, 9.1). The failure
that rule invites is quiet: take the file away, or stop installing it, and
both hosts still start, still take screenshots, and draw the text in whatever
the system offers. Nothing is red; the two platforms have simply stopped
matching. The hosts log it when the file is missing, but a log line is read
by whoever goes looking, and nobody goes looking for a font.

So the chain is checked link by link, here, where a missing link is a
failure and not a fallback:

  1. **The font is in the repository and is the file `fonts/README.md`
     describes**: present, an OpenType/CFF file, and the exact bytes pinned
     below. A "small tidy-up" that swaps in another weight, another subset
     or a re-export changes every annotation both hosts draw; that has to be
     a decision somebody makes by changing the hash, with the README.
  2. **Its license is beside it**: `fonts/OFL.txt`, carrying the copyright
     line and the SIL Open Font License 1.1 text. The OFL requires both to
     travel with the font.
  3. **`zig build` installs that directory** to `share/ghostty/polter/fonts`
     -- which is where both hosts look, as `<resources dir>/polter/fonts/`.
     Read from `src/build/GhosttyResources.zig`: the step has to name the
     source directory and the install subdirectory. The license rides along
     because the only exclusion is `.md`.
  4. **When there is a build tree, the product has it.** If
     `zig-out/share/ghostty` exists, the font and the license have to be in
     it, byte for byte. This is the one face that looks at what was built
     rather than at what would be.

NOT CHECKED
  * That a host actually loads the file. The macOS and Windows hosts each
    build their own path from their resources directory; this gate does not
    read them, and a host that looks somewhere else passes it.
  * That a *package* has it. The Windows release package and the macOS app
    bundle are assembled from `zig-out/share`; face 4 checks that tree, not
    the zip or the `.app`. A package built from a stale or partial `share/`
    is not seen here.
  * Face 4 says nothing when there is no build tree, and says so.
  * Whether the font covers a given character. It is the Simplified Chinese
    subset by choice.

Run:  python3 tools/the-annotation-font-ships.py
Exit: 0 when every face that could be checked holds; 1 otherwise.
"""

import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))

FONT_NAME = "NotoSansSC-Regular.otf"
LICENSE_NAME = "OFL.txt"
FONT = os.path.join(ROOT, "fonts", FONT_NAME)
LICENSE = os.path.join(ROOT, "fonts", LICENSE_NAME)
RESOURCES = os.path.join(ROOT, "src", "build", "GhosttyResources.zig")
BUILT = os.path.join(ROOT, "zig-out", "share", "ghostty")

# Noto Sans SC Regular 2.004, `Sans/SubsetOTF/SC/NotoSansSC-Regular.otf` of
# github.com/notofonts/noto-cjk, fetched 2026-10-06.
FONT_BYTES = 8331336
FONT_SHA256 = "faa6c9df652116dde789d351359f3d7e5d2285a2b2a1f04a2d7244df706d5ea9"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    problems = []

    # Face 1.
    if not os.path.isfile(FONT):
        problems.append(f"fonts/{FONT_NAME} is not in the tree.")
    else:
        with open(FONT, "rb") as f:
            magic = f.read(4)
        size = os.path.getsize(FONT)
        if magic != b"OTTO":
            problems.append(
                f"fonts/{FONT_NAME} does not start with `OTTO`: it is not an "
                "OpenType/CFF font (a Git LFS pointer or an HTML error page "
                "saved under this name starts with something else)."
            )
        elif size != FONT_BYTES or sha256(FONT) != FONT_SHA256:
            problems.append(
                f"fonts/{FONT_NAME} is not the file this gate pins "
                f"({size} bytes; expected {FONT_BYTES} with sha256 {FONT_SHA256[:16]}...). "
                "If the font was changed on purpose, change the pin and "
                "fonts/README.md in the same commit."
            )

    # Face 2.
    if not os.path.isfile(LICENSE):
        problems.append(f"fonts/{LICENSE_NAME} is not in the tree: the OFL has to travel with the font.")
    else:
        text = open(LICENSE, encoding="utf-8", errors="replace").read()
        if "SIL OPEN FONT LICENSE Version 1.1" not in text:
            problems.append(f"fonts/{LICENSE_NAME} does not contain the SIL Open Font License 1.1 text.")
        # A year after the mark: the license's own text says "Copyright
        # Holder" a dozen times, and that is not a copyright line.
        if not re.search(r"(©|Copyright\s*\(c\)|Copyright)\s*\d{4}", text):
            problems.append(f"fonts/{LICENSE_NAME} carries no copyright line; the OFL requires one.")

    # Face 3.
    if not os.path.isfile(RESOURCES):
        problems.append("src/build/GhosttyResources.zig is not in the tree, so nothing installs the font.")
    else:
        zig = open(RESOURCES, encoding="utf-8").read()
        # One install step that names both ends. Comments are stripped so a
        # note describing the step cannot stand in for it.
        code = "\n".join(line for line in zig.split("\n") if not line.lstrip().startswith("//"))
        # The step is one `addInstallDirectory(.{ ... })` whose literal has
        # nested braces in it, so it is cut out by position rather than by
        # one expression: from the call that names the source directory to
        # the `});` that closes it.
        step = None
        at = code.find('b.path("fonts")')
        if at != -1:
            start = code.rfind("addInstallDirectory(", 0, at)
            end = code.find("});", at)
            if start != -1 and end != -1 and "addInstallDirectory(" not in code[start + 1:at]:
                body = code[start:end]
                if re.search(r'pathJoin\(&\.\{\s*"ghostty",\s*"polter",\s*"fonts"\s*,?\s*\}\)', body):
                    step = body
        if step is None:
            problems.append(
                "src/build/GhosttyResources.zig has no step installing `fonts/` to "
                "`share/ghostty/polter/fonts`: the font is in the tree and in no build."
            )
        elif re.search(r'exclude_extensions\s*=\s*&\.\{[^}]*"\.(otf|txt)"', step):
            problems.append(
                "the step that installs `fonts/` excludes `.otf` or `.txt`, "
                "which is the font or its license."
            )

    # Face 4.
    built_note = None
    if os.path.isdir(BUILT):
        for name, source in ((FONT_NAME, FONT), (LICENSE_NAME, LICENSE)):
            out = os.path.join(BUILT, "polter", "fonts", name)
            if not os.path.isfile(out):
                problems.append(
                    f"zig-out/share/ghostty/polter/fonts/{name} is missing from the build tree "
                    "that is here. Rebuild; a package made from this tree would ship without it."
                )
            elif os.path.isfile(source) and sha256(out) != sha256(source):
                problems.append(
                    f"zig-out/share/ghostty/polter/fonts/{name} differs from fonts/{name}: "
                    "the build tree is stale."
                )
    else:
        built_note = "no zig-out/share/ghostty here, so the built copy was not looked at"

    if problems:
        print("FAIL: the screenshot tool's font would not reach both hosts as described:")
        for p in problems:
            print("      " + p)
        return 1

    print(
        f"OK: fonts/{FONT_NAME} is the pinned file ({FONT_BYTES} bytes), its license is beside it, "
        "and the build installs both to share/ghostty/polter/fonts."
    )
    if built_note:
        print("NOT CHECKED: " + built_note + ".")
    print("NOT CHECKED: that either host loads it; that a package or app bundle contains it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
