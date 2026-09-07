#!/usr/bin/env python3
"""The shipped executable has to carry the product's name, spelled `Polter`.

# What was wrong, measured on the artefact

`polter-host.exe` contained **no version resource at all**. Searching the
built binary for `VS_VERSION_INFO`, `FileDescription` and `ProductName` as
UTF-16 gave zero hits each, while `Polter` -- the window class names and
friends -- gave thirty. The source agreed: `windows/host/polter.rc` was one
line, the manifest, and nothing else.

**An exe with no friendly name has one everywhere anyway: its file name.**
That is one gap with several exits -- the notification's attribution line
(where somebody noticed it, task 294), Task Manager's "Name" column, the
taskbar's hover tooltip, the file properties dialog, the UAC prompt. Fixing
the notification code would have fixed one exit in five.

# Why a gate, and why this one is shaped like `shipped-params-agree.py`

The rule is written down -- `windows/AGENTS.md`, "Names": *user-visible strings
are Polter; internal artefacts keep their own names.* Nothing enforced it, and
**the class has now come up four times**: the front door in English while
everything behind it was not, one feature under three names, the settings page
still in English, and this. Four of the same shape is not four oversights.

The subject is a data file whose correctness only becomes visible on Windows,
in a dialog, and no test that runs on the machine this port is written on can
open that dialog -- the same situation `shipped-params-agree.py` describes for
the plugin manifests, and the same answer: read the file wherever anybody is
standing.

# NOT CHECKED, and the second one is the bigger hole

  * **This reads `polter.rc`, not the built exe.** A `windres` that silently
    dropped the block, or a build that never ran it, passes here.
    `build.rs` already warns loudly when `windres` cannot be run; what neither
    it nor this covers is "it ran and produced nothing". The reading that
    would cover it -- searching the built binary for the UTF-16 strings -- is
    the one used to establish the defect in the first place, and it needs a
    build, which a gate here does not do.
  * **Whether Windows uses `FileDescription` as the friendly name is not
    something this can check, or the machine it runs on can.** The gate
    asserts the file says `Polter`; that this makes the notification say
    `Polter` is a claim about Windows, tested by looking at Windows.
  * **The wider class -- a user-visible string that is in English, or is the
    internal name, or is three different names for one feature -- is not
    gateable from text and this does not pretend to be.** There is no pattern
    that separates "a label a person reads" from "an identifier that happens
    to be a word", and one wide enough to catch them all would report every
    correct string in the tree. That half stays a rule people follow, and the
    carriers `AGENTS.md` names (window class, default title, log header,
    binary name, AppUserModelID, mutex, registry) are where to look by hand.

Run:  python3 windows/tools/exe-says-its-own-name.py
Exit: 0 when the version resource is there and says `Polter` in both places,
      and the language block agrees with itself.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RC = os.path.join(HERE, "..", "host", "polter.rc")

# The two fields Windows shows a person. `InternalName` and `OriginalFilename`
# are deliberately not here: `AGENTS.md` puts internal artefact names on the
# other side of the line, and they are the file's own name by definition.
USER_FACING = {"FileDescription": "Polter", "ProductName": "Polter"}

# Below this the parse is not believable: the block has four values and a
# translation, and a regex that stopped matching would find none of them and
# report a clean run.
MIN_VALUES = 4


def findings(src):
    """Everything wrong with one `.rc`, as a list of sentences."""
    out = []

    if "VS_VERSION_INFO" not in src or "VERSIONINFO" not in src:
        out.append(
            "there is no VS_VERSION_INFO block: the exe carries no name of its own, so "
            "Windows shows its file name -- in the notification, in Task Manager, in the "
            "taskbar tooltip and in the file properties dialog"
        )
        return out

    values = dict(re.findall(r'VALUE\s+"([A-Za-z]+)"\s*,\s*"([^"]*)"', src))
    if len(values) < MIN_VALUES:
        out.append(
            f"only {len(values)} VALUE entries parsed, expected at least {MIN_VALUES}. "
            "A block this tool cannot read contributes nothing and reads exactly like a "
            "correct one"
        )
        return out

    for field, want in USER_FACING.items():
        got = values.get(field)
        if got is None:
            out.append(f"{field} is missing; it is what a person is shown, and it must say {want!r}")
        elif got != want:
            out.append(
                f"{field} is {got!r}, and user-visible strings are {want!r} "
                "(windows/AGENTS.md, \"Names\")"
            )

    for field, got in values.items():
        if not got.strip():
            out.append(
                f"{field} is empty. An absent field shows nothing; an empty one is a blank "
                "line in the properties dialog"
            )

    # **The language block and the translation must agree, and disagreeing is
    # silent.** The shell looks the strings up under the code page named by
    # `Translation`; a block filed under a different one is simply not found,
    # and the dialog goes back to showing nothing at all.
    block = re.search(r'BLOCK\s+"([0-9A-Fa-f]{8})"', src)
    trans = re.search(r'VALUE\s+"Translation"\s*,\s*0x([0-9A-Fa-f]+)\s*,\s*0x([0-9A-Fa-f]+)', src)
    if not block or not trans:
        out.append("the language BLOCK or the Translation value is missing or unreadable")
    else:
        want = f"{int(trans.group(1), 16):04x}{int(trans.group(2), 16):04x}"
        if block.group(1).lower() != want:
            out.append(
                f'BLOCK "{block.group(1)}" and Translation 0x{trans.group(1)},0x{trans.group(2)} '
                f'disagree (the block would have to be "{want.upper()}"). The shell looks the '
                "strings up under the translation it is told, finds nothing under the other "
                "one, and shows no name -- which is what this file exists to stop"
            )
    return out


GOOD = '''
VS_VERSION_INFO VERSIONINFO
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904B0"
    BEGIN
      VALUE "FileDescription", "Polter"
      VALUE "ProductName",     "Polter"
      VALUE "InternalName",    "polter-host"
      VALUE "OriginalFilename","polter-host.exe"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x0409, 0x04B0
  END
END
'''


def self_test():
    """Each way this can be wrong, planted and caught.

    **A checker whose failing cases are never exercised reports a clean tree
    whatever it is pointed at**, which is the shape every gate in this
    directory carries a probe against.
    """
    cases = [
        ("the real shape", GOOD, 0),
        ("no version block", '1 RT_MANIFEST "polter.manifest"\n', 1),
        ("the internal name in a user-facing field",
         GOOD.replace('VALUE "FileDescription", "Polter"',
                      'VALUE "FileDescription", "polter-host.exe"'), 1),
        ("an empty field",
         GOOD.replace('VALUE "ProductName",     "Polter"',
                      'VALUE "ProductName",     ""'), 2),
        ("the block filed under another language",
         GOOD.replace('BLOCK "040904B0"', 'BLOCK "080904B0"'), 1),
        ("a block this tool cannot read",
         "VS_VERSION_INFO VERSIONINFO\nBEGIN\nEND\n", 1),
    ]
    for what, src, want in cases:
        got = len(findings(src))
        if got != want:
            print(f"probe self-test FAILED: {what} gave {got} finding(s), expected {want}")
            return False
    # And the sanity check the others rest on: the good shape has to be the
    # one that passes, or every "expected 1" above is satisfied by a gate that
    # complains about everything.
    if findings(GOOD):
        print("probe self-test FAILED: the good shape produced findings")
        return False
    print("probe self-test: OK (missing block, internal name, empty field, "
          "language mismatch, unreadable block)")
    return True


def main():
    if not self_test():
        return 1

    try:
        with open(RC, encoding="utf-8") as fh:
            src = fh.read()
    except OSError as e:
        # **Missing is a failure, not a skip.** A gate that shrugs when its
        # subject is not there is a gate that stops existing the first time
        # somebody moves the file, and nothing says so.
        print(f"cannot read {os.path.relpath(RC, os.path.join(HERE, '..', '..'))}: {e}")
        return 1
    if not src.strip():
        print("polter.rc is empty; there is nothing to check and that is a failure")
        return 1

    found = findings(src)
    n_values = len(re.findall(r'VALUE\s+"[A-Za-z]+"\s*,\s*"', src))
    print(f"read polter.rc: {n_values} string value(s) in the version resource")
    if found:
        for f in found:
            print(f"HIT    polter.rc  {f}")
        print(f"\n{len(found)} problem(s) with the name this executable gives itself.")
        return 1
    print("OK: the exe names itself `Polter` in both fields a person is shown, "
          "and the language block agrees with its own translation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
