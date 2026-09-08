#!/usr/bin/env python3
"""Every application manifest in the port parses, with a real XML parser.

**Why this is a gate and not a note.** A manifest that does not parse is not a
cosmetic fault: the loader refuses the exe, so the program does not start. And
every signal a build produces stays green while it happens -- `windres` copies
the bytes without reading them, the `.rsrc` section is present, the manifest
text is inside the exe, `cargo build` exits 0. The port shipped exactly that:
two hyphens in a row inside the manifest's own comment, which XML forbids, and
an exe nobody could launch. The prose in that comment was inert to the reader
in the way comments usually are, and not inert at all to the parser.

`build.rs` has its own check, because that is the one that has to run on every
build with no interpreter available. This file is the second opinion, and it is
a different *kind* of reading: `expat`, a real parser, rather than the small
hand-written scanner in `build.rs`. A hand-written scanner that is wrong about
XML is wrong quietly.

**What this does not check:** whether the manifest says the right thing. A
well-formed manifest that asks for the wrong assembly version, or drops the
Common-Controls dependency altogether, passes here -- that is the reader's
job, and the comment in the file is where the reasons live. It also cannot
read a *built* exe: what ships is verified by building one and parsing the
bytes back out, which is not something a checkout can do.
"""

import os
import re
import sys
import xml.dom.minidom
import xml.parsers.expat

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))

# A manifest whose comment carries the house dash. **The canary is the defect
# that actually happened**, not a hypothetical malformation: the point is that
# this file would have caught it.
CANARY_BAD = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<!-- comctl32 v5 -- the Windows 95 look -->
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0"/>
"""
CANARY_OK = CANARY_BAD.replace("v5 -- the", "v5, the")


def fault(text: str) -> str | None:
    try:
        xml.dom.minidom.parseString(text)
        return None
    except xml.parsers.expat.ExpatError as e:
        return str(e)


def self_test() -> None:
    if fault(CANARY_BAD) is None:
        print("FAIL: two hyphens inside a comment parsed cleanly. That is the "
              "defect this gate exists for, so the gate is not reading anything.")
        sys.exit(2)
    if fault(CANARY_OK) is not None:
        print(f"FAIL: a well-formed manifest was rejected: {fault(CANARY_OK)}")
        sys.exit(2)


def build_rs_still_guards(path: str) -> list[str]:
    """`build.rs` must fail the build, before it does anything else.

    **Checked rather than assumed.** This file is not run by `cargo build`, so
    if the guard in `build.rs` is deleted or demoted to a warning, nothing at
    build time notices and a broken manifest reaches an exe again. The three
    properties are: the check is called, it is fatal, and it happens before the
    early return for a non-Windows target -- a check that only runs on some
    targets is a check that a person on another machine does not have.
    """
    src = open(path, encoding="utf-8").read()
    problems = []
    # **The definition is not a call.** Looking for the bare name matches
    # `fn manifest_fault(...)` and reports a guard that is defined and never
    # run as present -- which is the exact state a deleted call leaves behind.
    calls = [m.start() for m in re.finditer(r"(?<!fn )\bmanifest_fault\s*\(", src)]
    if not calls:
        problems.append(
            "build.rs no longer calls `manifest_fault`; the guard may still be "
            "defined in the file, which is not the same as running"
        )
        return problems
    call = calls[0]
    after = src[call : call + 1200]
    if "panic!" not in after:
        problems.append("build.rs reads the manifest but no longer fails the build")
    if 'cargo:warning' in after.split("panic!")[0]:
        problems.append("build.rs demoted the malformed-manifest stop to a warning")
    target_gate = src.find('std::env::var("TARGET")')
    if target_gate != -1 and target_gate < call:
        problems.append(
            "build.rs checks the manifest only after the target early-return, so a "
            "host-target build does not check it"
        )
    return problems


# The element whose absence is the rule, assembled at run time from two
# halves. **Spelling it out here would break the rule this checks**: the
# manifest's own comment explains that a documented absence which answers
# "present" to every search is worse than no documentation, and a checker that
# lives in the same tree is one more thing a `git grep` finds. So the literal
# is never written and this comment does not write it either.
AWARENESS_ELEMENT = "dpi" + "aware"


def awareness_element_absent(src):
    """The manifest must not spell the DPI element, in the manifest's casing.

    # The rule, and why it is a rule rather than a preference

    `main.rs` asks for per-monitor awareness with an API call at startup. When
    a manifest and a call both speak, **the manifest wins and the call fails,
    returning false and saying nothing** -- so one of them has to be the only
    one, and it is the call.

    # Why the tally that used to sit next to this rule is gone

    The manifest's comment used to record what a case *insensitive* search
    answers: 7. Measured again on one tree at one moment:

        debug build     7
        release build   4

    Both readings were taken the same way and neither is wrong. **The figure is
    a property of an artefact, not of the source, and neither reading recorded
    which artefact.** It is self-referential as well: the paragraph stating the
    number ships inside the exe and is one of the things counted, so writing it
    down changes it.

    What is checkable from a checkout is the rule, so that is what is here.

    # NOT CHECKED: the built exe

    The property that matters is about what ships, and no checkout can read it.
    The reading, for whoever has a build:

        python3 -c "b=open(EXE,'rb').read(); w=('dpi'+'aware').encode(); \
                    print(b.count(w), b.lower().count(w))"

    The first number is the rule and must be 0. The second is the tally above:
    non-zero, every hit the awareness *call*, and worth no more than a glance.
    """
    out = []
    if AWARENESS_ELEMENT in src:
        out.append(
            "spells the DPI element in the casing a manifest uses. The manifest then "
            "wins over `main.rs`'s call, which fails silently and returns false; and a "
            "documented absence that answers \"present\" to every search is worse than "
            "no documentation"
        )
    return out


def main() -> int:
    self_test()
    found = []
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in ("target", ".git")]
        for f in files:
            if f.endswith(".manifest"):
                found.append(os.path.join(base, f))
    if not found:
        # A gate that scans nothing must say so rather than pass. If the
        # manifest is renamed or moved, the port silently loses this check.
        print("FAIL: no .manifest file was found under windows/ at all.")
        return 1

    bad = 0
    for p in sorted(found):
        rel = os.path.relpath(p, ROOT)
        why = fault(open(p, encoding="utf-8").read())
        if why:
            bad += 1
            print(f"FAIL: {rel} is not well-formed XML: {why}")
            print("      An exe that embeds this does not start, and the build "
                  "that produced it exits 0.")
        else:
            print(f"  {rel}: parses")
        for problem in awareness_element_absent(open(p, encoding="utf-8").read()):
            bad += 1
            print(f"FAIL: {rel} {problem}")

    for problem in build_rs_still_guards(os.path.join(ROOT, "host", "build.rs")):
        bad += 1
        print(f"FAIL: {problem}")

    print(f"scanned {len(found)} manifest(s) with expat, and checked that none "
          f"declares DPI awareness; it cannot tell whether they say the right thing "
          f"otherwise, and it cannot read a built exe -- see "
          f"`awareness_element_absent` for the command that does.")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
