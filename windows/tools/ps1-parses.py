#!/usr/bin/env python3
# The docstring below contains PowerShell, which is full of backslashes; raw so
# Python does not read `\.` as an escape it does not know.
r"""Do the PowerShell scripts in this directory parse?

This gate exists for the same reason `manifest-parses.py` does, and the two
failures are the same failure in different file types:

  * a manifest with two hyphens in an XML comment shipped inside the exe and
    the exe would not start;
  * a `.ps1` with a comma inside a hashtable literal was committed, and every
    mode of the criterion script it belongs to was unrunnable.

Both were **embedded / committed successfully**, and both were broken. Nothing
in the build or the review said so, because in both cases the thing that
notices is a parser and no parser was being run.

# Why regexes were not enough here, measured rather than assumed

The change that broke it was **comments only**, and it was checked before
committing -- block-comment pairing and brace balance, both by script, both
green. They could not have caught it: they count symbols, and this is a
**context-dependent** parse error.

The context was narrowed with the parser rather than reasoned about, and the
first answer was wrong. It is not "legal in an assignment, illegal in a
hashtable" -- measured, all three of these:

    $x = @{ Type = $e.Name -replace '^A\.', '' }              0 errors
    $s.Add([pscustomobject]@{ Type = $e.Name -replace ... })   5 errors
    $s.Add([pscustomobject]@{ Type = ($e.Name -replace ...) }) 0 errors

**A hashtable literal at statement level takes the comma without complaint.**
It is fatal only when that hashtable is an *argument to a method call*, where
the comma is claimed by the argument list -- which is why the reported error
was "Missing ')' in method call" and not anything about hashtables. The
identical expression appears in both contexts in the file that broke.

A check that counts symbols is blind, by construction, to a character meaning
different things in different places.

So this gate does not look for the mistake. It runs the language's own parser.

# What it can and cannot say

It uses `pwsh` (PowerShell 7), which is what exists on the machine the port is
written on. **The scripts are meant to run under Windows PowerShell 5.1**,
which is a different runtime with different assemblies available -- so:

  * **parses** here means the grammar is satisfied. The 5.1 parser agreed with
    this one on the failure that prompted this file: 15 errors, first at line
    342, both places.
  * it says **nothing** about whether the script runs: `Add-Type
    -AssemblyName UIAutomationClient` succeeds on 5.1 and fails on 7, and no
    parser will tell you that.

That distinction is the whole reason `docs/windows/uia.md` still says a change
to those scripts is unverified until a real machine has run one.

# If `pwsh` is missing this gate FAILS rather than passing

A check that reports success when its instrument is absent is the exact shape
this repository has spent a night finding in five other disguises. "I looked
and found nothing" and "I could not look" must not print the same thing, and
the only way to keep them apart in an exit code is to fail.

Run:  python3 windows/tools/ps1-parses.py
Exit: 0 if every script parses, 1 if any fails or if `pwsh` is unavailable.
"""

import glob
import os
import shutil
import subprocess
import sys
import tempfile

# The path arrives in the environment rather than as an argument. **`pwsh
# -Command <script> <path>` does not bind that path to `$args`** -- the first
# draft did exactly that, and every file came back "could not be read", which
# the self-test below reported as the parenthesised form being rejected. The
# self-test caught a broken gate, which is the whole reason gates here carry
# one.
PARSE = r"""
$errs = $null; $toks = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($env:PS1_PARSE_TARGET, [ref]$toks, [ref]$errs)
Write-Output "COUNT=$($errs.Count)"
$errs | ForEach-Object {
    Write-Output ("LINE={0}: {1}" -f $_.Extent.StartLineNumber, $_.Message)
}
"""


def parse(pwsh, path):
    """Returns (error count, first few messages)."""
    env = dict(os.environ, PS1_PARSE_TARGET=os.path.abspath(path))
    out = subprocess.run(
        [pwsh, "-NoProfile", "-Command", PARSE],
        capture_output=True,
        text=True,
        env=env,
    )
    count, msgs = None, []
    for line in out.stdout.splitlines():
        if line.startswith("COUNT="):
            count = int(line[6:])
        elif line.startswith("LINE="):
            msgs.append(line[5:])
    if count is None:
        # The parser did not answer at all. **Not "no errors"** -- see the
        # header: not being able to look is a different thing from looking.
        return None, [out.stderr.strip() or "pwsh produced no COUNT line"]
    return count, msgs


pwsh = shutil.which("pwsh") or shutil.which("powershell")
if not pwsh:
    print("NOT CHECKED: no `pwsh` on PATH, so nothing here was parsed.")
    print()
    print("  This is a failure and not a skip. The scripts in this directory")
    print("  cannot be validated by reading -- the defect this gate was written")
    print("  for was invisible to brace counting and to block-comment pairing,")
    print("  both of which passed on the broken file.")
    print()
    print("  macOS/Linux:  brew install powershell   (or your package manager)")
    sys.exit(1)

here = os.path.dirname(os.path.abspath(__file__))

# Self-test, in both directions, using the exact shape that got through.
#
# **The bad sample is the real one**, reduced from what was committed rather
# than invented: the hashtable has to be inside the method call, because that
# is the part that makes it fatal. An earlier version of this sample left the
# call out and parsed cleanly -- the self-test then reported that the probe
# could not see the defect, which is exactly what it is for.
BAD = """
$sink = New-Object System.Collections.ArrayList
[void]$sink.Add([pscustomobject]@{
    Type = $e.Name -replace '^A\\.', ''
})
"""
GOOD = """
$sink = New-Object System.Collections.ArrayList
[void]$sink.Add([pscustomobject]@{
    Type = ($e.Name -replace '^A\\.', '')
})
"""
with tempfile.TemporaryDirectory() as d:
    bad_p = os.path.join(d, "bad.ps1")
    good_p = os.path.join(d, "good.ps1")
    with open(bad_p, "w") as fh:
        fh.write(BAD)
    with open(good_p, "w") as fh:
        fh.write(GOOD)

    n_bad, _ = parse(pwsh, bad_p)
    n_good, why = parse(pwsh, good_p)

    if n_bad is None or n_bad == 0:
        print("FAIL: the probe cannot see a comma inside a hashtable literal -- "
              "the defect it was written for.")
        sys.exit(1)
    if n_good is None or n_good != 0:
        print("FAIL: the probe rejects the parenthesised form, which is the fix. "
              f"({why})")
        sys.exit(1)

print(f"probe self-test: OK (sees the hashtable comma, accepts the parenthesised form)")
print(f"parser: {pwsh}")

scripts = sorted(glob.glob(os.path.join(here, "*.ps1")))
if not scripts:
    print("FAIL: no .ps1 found; this gate is looking in the wrong place.")
    sys.exit(1)

bad = 0
for path in scripts:
    name = os.path.basename(path)
    count, msgs = parse(pwsh, path)
    if count is None:
        print(f"  {name}: COULD NOT PARSE -- {msgs[0]}")
        bad += 1
        continue
    if count == 0:
        print(f"  {name}: parses")
        continue
    bad += 1
    print(f"  {name}: {count} error(s)")
    for m in msgs[:5]:
        print(f"      {m}")
    if count > 5:
        print(f"      ... and {count - 5} more")

print()
print(f"scanned {len(scripts)} script(s) with {os.path.basename(pwsh)}'s own parser.")
print("NOT CHECKED: whether they RUN. These target Windows PowerShell 5.1, whose")
print("             assemblies (UIAutomationClient, System.IO.Pipes) this parser")
print("             knows nothing about. A change here is unverified until a real")
print("             machine has run one -- see docs/windows/uia.md.")

sys.exit(1 if bad else 0)
