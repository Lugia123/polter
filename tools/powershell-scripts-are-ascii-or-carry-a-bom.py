#!/usr/bin/env python3
"""Every tracked PowerShell script is pure ASCII, or starts with a BOM.

**Why this one exists** (task 1691). Windows PowerShell 5.1 reads a script
that has no byte-order mark in the machine's ANSI code page, not in UTF-8. On
a Chinese-locale Windows that is 936 (GBK). Task 1678 put U+2028 and U+2029
into `adapter.ps1` as the characters themselves, inside a regex character
class:

    [regex]::Split($Text, "\\r\\n|[\\n\\r\\x0b...\\x85<U+2028><U+2029>]")

Read as GBK those six bytes are not two characters but a run of double-byte
pairs, and the pattern handed to .NET is no longer the one that was written.
`inventory` threw on the Chinese test machine (task 1686) and nowhere else.
Every check on the Mac was green, because pwsh 7 reads a no-BOM file as UTF-8
-- `ps1-parses.py` included: it parses with that same pwsh, and the file
parses fine even read as GBK, since the string still ends at its quote.

**Tracked files only**, like the leak gate: a new script is invisible here
until it has been `git add`ed.

The fix was the escape `\\u2028\\u2029`, which the regex engine reads and the
file does not need non-ASCII bytes for. This gate is the general form: a
script whose bytes are all below 0x80 reads the same in every code page, and a
script with a BOM is read as what the BOM says. **Anything else means
something different depending on where it runs**, and that includes comments:
a comment is harmless only for as long as no lead byte lands next to
something that matters.

The subject is every `.ps1` / `.psm1` / `.psd1` that git tracks, from the top
of the repository whatever directory this runs from. **None found is a FAIL**:
"scanned 0" and "all clean" must not share an exit code.

Run:  python3 tools/powershell-scripts-are-ascii-or-carry-a-bom.py
Exit: 0 when every tracked script is ASCII or starts with a BOM; 1 otherwise,
      or when there is nothing to scan.
"""

import os
import subprocess
import sys

EXTS = (".ps1", ".psm1", ".psd1")

# UTF-8, UTF-16 LE, UTF-16 BE. PowerShell 5.1 honours all three.
BOMS = (b"\xef\xbb\xbf", b"\xff\xfe", b"\xfe\xff")


def problems(data: bytes):
    """[(line number, the non-ASCII text on it)], empty when the bytes are fine."""
    if data.startswith(BOMS):
        return []
    out = []
    for n, line in enumerate(data.split(b"\n"), 1):
        if any(b >= 0x80 for b in line):
            text = line.decode("utf-8", "replace")
            out.append((n, "".join(c for c in text if ord(c) >= 0x80)))
    return out


# Self-test, in both directions, with the shape that got through: the line from
# task 1678, without a BOM, must be caught; the same bytes with a BOM, and the
# escaped form without one, must not.
REAL = 'Split($Text, "[\\x85  ]")\n'.encode("utf-8")
FIXED = 'Split($Text, "[\\x85\\u2028\\u2029]")\n'.encode("utf-8")
if problems(REAL) != [(1, "  ")]:
    print("FAIL: the probe does not see raw U+2028/U+2029 in a no-BOM script -- "
          "the defect it was written for.")
    sys.exit(1)
if problems(b"\xef\xbb\xbf" + REAL) or problems(FIXED):
    print("FAIL: the probe rejects a script with a BOM, or the escaped form.")
    sys.exit(1)
print("probe self-test: OK (sees the raw characters, accepts a BOM and the escape)")

top = subprocess.run(
    ["git", "rev-parse", "--show-toplevel"], capture_output=True, check=True, text=True
).stdout.strip()
listed = subprocess.run(
    ["git", "ls-files", "-z"], cwd=top, capture_output=True, check=True
).stdout
scripts = sorted(
    p for p in (x.decode("utf-8", "replace") for x in listed.split(b"\0") if x)
    if p.lower().endswith(EXTS)
)
if not scripts:
    print("FAIL: scanned 0 tracked PowerShell scripts; this gate is looking in "
          "the wrong place.")
    sys.exit(1)

bad = 0
for path in scripts:
    try:
        with open(os.path.join(top, path), "rb") as fh:
            data = fh.read()
    except OSError as e:
        # Tracked but unreadable (deleted in the working tree, say) is not clean.
        print(f"  {path}: COULD NOT READ -- {e}")
        bad += 1
        continue
    found = problems(data)
    if not found:
        continue
    bad += 1
    print(f"  {path}: non-ASCII without a BOM")
    for n, chars in found[:5]:
        print(f"      line {n}: {chars!r}")
    if len(found) > 5:
        print(f"      ... and {len(found) - 5} more line(s)")

print()
print(f"scanned {len(scripts)} tracked PowerShell script(s); {bad} would read "
      "differently under a non-UTF-8 code page.")
if bad:
    print("  Write the character as an escape (`\\u2028` in a regex, `[char]0x2028`")
    print("  in an expression), keep comments ASCII, or save the file with a BOM.")
sys.exit(1 if bad else 0)
