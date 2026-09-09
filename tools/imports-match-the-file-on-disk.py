#!/usr/bin/env python3
"""Every `@import` of a repo file spells the filename the way the disk does.

# Why this exists

macOS is case-insensitive by default and Linux is not, so
`@import("../poltergeist/server.zig")` for a file named `Server.zig` builds
cleanly on the machine it was written on and fails to find the file
everywhere else. Nothing local can catch it: the compiler is handed a name
the filesystem happily resolves.

It was written that way here once, in an afternoon's work, by somebody who
had just read the file with a lowercase path in a shell command -- also
resolved -- and copied that spelling into the import. The mistake is one
character and it is invisible until somebody else builds.

# What it checks

Only imports that name a path inside this repository. Package names
(`std`, `xev`, `build_options`, anything with no `/` and no `.zig`) are the
build system's business, not the filesystem's.

# The false positive this gate had on its first run, and why it is exempt

`src/build/uucode_config.zig` imports `config.zig` while `src/build/` holds
a `Config.zig`, and every sibling in that directory imports `Config.zig`.
That is exactly the shape this gate is looking for, so it reported it -- and
the report was wrong. That file is compiled inside the uucode dependency's
module, where the name resolves to something else entirely; "correcting" it
to `Config.zig` makes the build fail with eight `import of file outside
module path` errors.

**The argument that it was a typo was a good one and it was wrong**: same
directory, one file spelled differently from all its siblings. What settled
it was building both ways, not the reasoning. So the exemption is by module,
not by filename, and it is here rather than in a side list because the
reason is the point.

# NOT CHECKED

- **Whether the target exists at all.** A missing file fails the build on
  every platform, so it needs no gate; this one is about a file that exists
  under a different spelling.
- **Which module a file is compiled in.** This reads paths on disk, and a
  `.zig` file's module membership is decided in `build.zig`. That is why the
  exemption above has to be named by hand: a file compiled in another
  module's root resolves its imports against that root, and nothing here can
  see it.
- **`@embedFile`, `@cImport`, include paths, or build.zig's own paths.**
  Same failure mode, not swept here -- said so it is not mistaken for
  covered.
"""

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# `@import("...")` where the argument looks like a path to a file in the
# tree: it ends in .zig. Anything else is a package name.
IMPORT = re.compile(r'@import\("([^"]+\.zig)"\)')

# Files compiled inside another module's root, where an import resolves
# against that root and not against this directory. Verified by building
# both ways, not by reading -- see the note at the top of this file.
#
# Each entry is a repo-relative path and the reason it is here. Adding one
# without building both ways is how this list stops meaning anything.
FOREIGN_MODULE = {
    "src/build/uucode_config.zig":
        "compiled in the uucode dependency's module; `config.zig` there is "
        "not `src/build/Config.zig`, and pointing it at that one fails with "
        "`import of file outside module path`",
}


def strip_comments(text: str) -> str:
    """Drop `//` comments before searching.

    Doc comments in this tree quote imports while explaining them, and a
    check that matched those would report on prose. It would also stay green
    after the real import was deleted, which is the worse half.
    """
    out = []
    for line in text.splitlines():
        i = line.find("//")
        out.append(line if i < 0 else line[:i])
    return "\n".join(out)


def real_case(path: Path) -> str | None:
    """The name the directory actually holds, or None if there is no match.

    `Path.exists()` is useless here -- on a case-insensitive filesystem it
    says yes to the wrong spelling, which is the whole bug. So the directory
    is listed and the name compared exactly.
    """
    parent = path.parent
    if not parent.is_dir():
        return None
    for entry in os.listdir(parent):
        if entry == path.name:
            return entry
        if entry.lower() == path.name.lower():
            return entry
    return None


def self_test() -> None:
    """Run on every invocation, because a probe in a file nobody runs is
    a probe that stops being run."""
    here = Path(__file__).resolve()
    exact = real_case(here)
    assert exact == here.name, f"probe: exact spelling not found ({exact})"

    wrong = here.with_name(here.name.upper())
    if wrong.name != here.name:
        found = real_case(wrong)
        assert found == here.name, (
            "probe: a wrong-case name did not resolve back to the real one -- "
            "this gate cannot work on this filesystem"
        )
    print("probe self-test: OK (a wrong-case name resolves to the real one)")


def main() -> int:
    self_test()

    problems: list[str] = []
    exempt: list[str] = []
    files = 0
    imports = 0

    for path in ROOT.rglob("*.zig"):
        rel = path.relative_to(ROOT)
        if rel.parts[0] in ("vendor", "zig-out", "zig-cache", ".zig-cache"):
            continue
        if rel.as_posix() in FOREIGN_MODULE:
            exempt.append(rel.as_posix())
            continue
        files += 1
        try:
            text = strip_comments(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError):
            continue

        for m in IMPORT.finditer(text):
            spelled = m.group(1)
            target = (path.parent / spelled).resolve()
            try:
                target.relative_to(ROOT)
            except ValueError:
                continue  # outside the tree; not ours to judge
            imports += 1
            actual = real_case(target)
            if actual is None:
                continue  # missing entirely: the build says so on every OS
            if actual != target.name:
                problems.append(
                    f"{rel}: @import(\"{spelled}\") but the file is named "
                    f"{actual!r}.\n"
                    "      This builds on a case-insensitive filesystem and "
                    "fails to find the file on Linux."
                )

    if problems:
        print("FAIL: an import spells a filename differently from the disk:")
        for p in problems:
            print(f"      {p}")
        return 1

    print(f"{imports} in-tree @import(s) across {files} .zig file(s): every "
          f"one spells its target the way the disk does.")
    for e in exempt:
        print(f"      exempt (foreign module): {e} -- {FOREIGN_MODULE[e]}")
    print("NOT CHECKED: @embedFile, @cImport, include paths, build.zig paths.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
