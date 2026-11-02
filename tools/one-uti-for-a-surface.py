#!/usr/bin/env python3
r"""A type this app exports is one identifier written in two files, and they agree.

# The defect this watches

Pane dragging on macOS hands a surface's UUID to the drop target through a
custom `UTType`. That type is defined by **two strings that must be identical**:

  * `macos/Ghostty-Info.plist`'s `UTExportedTypeDeclarations[].UTTypeIdentifier`
    -- the only thing that puts the name in the system's type database;
  * `UTType(exportedAs: "...")` in the Swift that uses it.

`7de0cab17` ("Rename the fork to Polter") changed the first and left the
second, and **nothing about it failed to compile**. What it did instead:

    Transferable+Extension.swift:13   itemProvider.registeredTypeIdentifiers
                                          .compactMap { UTType($0) }
    Transferable+Extension.swift:14   guard !types.isEmpty else { return nil }
    SurfaceDragSource.swift:249       guard let pasteboardItem = ... else { return }

`NSItemProvider` registers the name the *code* exports, and no bundle on the
machine declares that name any more, so `UTType(string)` returns nil, the
`compactMap` drops it, `pasteboardItem()` returns nil, and the drag source
returns before `beginDraggingSession`. The grab handle still appeared and the
cursor still turned into a hand -- the start of the gesture was never broken,
only everything after it -- so it read as "the drop targets are broken" and
was hunted in the drop zones for a day. Measured on the installed app
(`/Applications/Polter.app`, 0.11.2310): the binary carries the **old** bundle
id's type name twice and the current one zero times, while its `Info.plist`
declares only the current one. Neither string is written here -- this file is
tracked and the repository is public, and the pair is already spelled in the
two files it is about.

# The invariant

Two sets, and they are equal:

  * every identifier any `.swift` under `macos/Sources` passes to
    `UTType(exportedAs:)`;
  * every `UTTypeIdentifier` in every `*Info.plist` under `macos/`.

Equal, not merely "the plist contains the code's" -- a declaration with no
exporter is dead weight that the next reader will take for a live type.
Equality is also what makes the two mistakes symmetric: renaming one side and
renaming the other out of step are the same failure here.

# Why it is written as a set and not as one pair

Naming the type in this file would make the gate blind the moment somebody
renames it properly: the literal would not match, the scan would find nothing,
and a scan that finds nothing must go red -- so the gate would break on the
very change it exists to survive. The two sides are read as sets and compared,
so any rename stays green as long as both halves move together.

# The empty tree

Both subjects are missing under `windows/tools/gates-fail-on-empty.py`, which
runs this file from an empty repository. Each is asked for by name first and
**FAILs naming it** rather than being read and crashing: a crash exits 1 like
a refusal but says nothing about this gate having noticed anything.

# What it does not check

  * whether the identifier is a *good* name, or whether the type carries the
    right conformance (`public.data`, in the plist);
  * the same pair on the Windows host, whose drag payload is not a `UTType`;
  * that the pasteboard type built from this `UTType` (`NSPasteboard+...`) is
    the one the drop targets ask for -- `TerminalSplitTreeView`'s
    `.onDrop(of: [.ghosttySurfaceId])` uses the same Swift constant, so it
    moves with it;
  * types declared by a bundle that is not in this repository.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Where each half is looked for. The Swift side is a whole tree because that is
# where a new exported type will be written; the plist side is a whole tree for
# the same reason.
SWIFT_ROOT = os.path.join("macos", "Sources")
PLIST_ROOT = "macos"

# `UTType(exportedAs: "com.example.thing")`, anything before it on the line.
EXPORTED_AS = re.compile(r'UTType\(\s*exportedAs:\s*"([^"]+)"')

# One `<key>UTTypeIdentifier</key>` followed by one `<string>...</string>`,
# allowing whitespace and comments between them the way plist XML does.
UTI_KEY = re.compile(
    r"<key>\s*UTTypeIdentifier\s*</key>\s*(?:<!--.*?-->\s*)*<string>\s*([^<\s]+)\s*</string>",
    re.DOTALL,
)

# Directories that are build output, not source: a copied plist in a build
# directory is the *same* declaration seen twice, and scanning it would make a
# stale copy look like a disagreement.
SKIP_DIRS = {"build", ".build", "DerivedData", "xcframework", ".git"}


def walk(root: str, suffix: str):
    """Every file under `root` ending in `suffix`, skipping build output."""
    for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, root)):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in sorted(filenames):
            if name.endswith(suffix):
                yield os.path.join(dirpath, name)


def read(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def main() -> int:
    problems: list[str] = []
    at: dict[str, list[str]] = {}

    # --- the Swift half -----------------------------------------------------
    swift_root = os.path.join(ROOT, SWIFT_ROOT)
    if not os.path.isdir(swift_root):
        print(f"FAIL: {SWIFT_ROOT}/ is not there. This gate reads the "
              f"`UTType(exportedAs:)` identifiers out of it; with the tree "
              f"missing it has nothing to look at, which is not a clean tree.")
        return 1

    swift_files = list(walk(SWIFT_ROOT, ".swift"))
    if not swift_files:
        print(f"FAIL: no .swift file under {SWIFT_ROOT}/. Nothing was scanned, "
              f"so a pass here would mean nothing.")
        return 1
    for path in swift_files:
        rel = os.path.relpath(path, ROOT)
        for i, line in enumerate(read(path).splitlines()):
            for ident in EXPORTED_AS.findall(line):
                at.setdefault(ident, []).append(f"{rel}:{i + 1}")

    if not at:
        print(f"FAIL: no `UTType(exportedAs:)` anywhere under {SWIFT_ROOT}/ "
              f"({len(swift_files)} file(s) scanned). Either the app no longer "
              f"exports a type -- in which case delete this gate -- or the call "
              f"is written differently now and this gate has gone blind. It must "
              f"not report success either way.")
        return 1

    # --- the plist half -----------------------------------------------------
    plists = [p for p in walk(PLIST_ROOT, "Info.plist")]
    if not plists:
        print(f"FAIL: no *Info.plist under {PLIST_ROOT}/. Nothing was scanned.")
        return 1

    declared: dict[str, list[str]] = {}
    plists_with_declarations = 0
    for path in plists:
        rel = os.path.relpath(path, ROOT)
        body = read(path)
        ids = UTI_KEY.findall(body)
        if ids:
            plists_with_declarations += 1
        for ident in ids:
            declared.setdefault(ident, []).append(rel)

    if plists_with_declarations == 0:
        print(f"FAIL: none of the {len(plists)} *Info.plist file(s) under "
              f"{PLIST_ROOT}/ declares a UTTypeIdentifier. The app's exported "
              f"types are what this gate holds the Swift half to; with no "
              f"declaration at all every exported type is in the state that "
              f"lost pane dragging, and with nothing to read this gate cannot "
              f"say so.")
        return 1

    # --- the comparison -----------------------------------------------------
    for ident in sorted(set(at) - set(declared)):
        where = ", ".join(at[ident])
        print(f"FAIL: {ident!r} is exported in Swift ({where}) and declared in "
              f"no Info.plist. `NSItemProvider` registers this name, and no "
              f"bundle puts it in the system's type database, so `UTType(string)` "
              f"for it is nil -- `Transferable+Extension.swift`'s compactMap "
              f"drops it and `pasteboardItem()` returns nil. Add it to "
              f"macos/Ghostty-Info.plist's UTExportedTypeDeclarations.")
        problems.append(ident)

    for ident in sorted(set(declared) - set(at)):
        where = ", ".join(declared[ident])
        print(f"FAIL: {ident!r} is declared in {where} and no `.swift` under "
              f"{SWIFT_ROOT}/ exports it. A declaration nothing uses is a type "
              f"the next reader will believe is live; either export it or take "
              f"it out.")
        problems.append(ident)

    if problems:
        return 1

    pairs = ", ".join(f"{ident} ({len(at[ident])} use(s), {len(declared[ident])} declaration(s))"
                      for ident in sorted(at))
    print(f"ok one identifier per exported type, declared and exported the same: {pairs}")
    print(f"scanned {len(swift_files)} .swift file(s) under {SWIFT_ROOT}/ and "
          f"{len(plists)} *Info.plist under {PLIST_ROOT}/ "
          f"({plists_with_declarations} with declarations)")
    print("NOT CHECKED: whether the identifier is a good name or the type conforms "
          "to the right thing, and the Windows host, whose payload is not a UTType")
    return 0


if __name__ == "__main__":
    sys.exit(main())
