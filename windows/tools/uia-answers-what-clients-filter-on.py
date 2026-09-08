#!/usr/bin/env python3
"""A property this provider never answers is a property a client fills in.

Measured on the machine, on the eleventh package: **every element this host
published reported `IsEnabled=false`** -- the tab strip, every tab item, the
terminal document, and all ninety command-palette rows, without exception.

Nothing was disabled. `UIA_IsEnabledPropertyId` was simply not handled, so it
fell through `GetPropertyValue`'s `_ => variant_empty()` and the client
supplied a default.

# Why an unanswered property costs more than a missing feature

**Filtering on `IsEnabled` is the first thing an automation client does.** So
an unanswered one is not "a property nobody reads": it removes the element
from every enumeration that matters. The host then reads as a program with no
operable elements in it, and the client falls back to clicking screenshot
coordinates -- which is the most expensive and least reproducible part of
testing this port.

**And the failure is silent in the direction that hurts.** A provider that
answers wrongly can be caught by reading the answer; a provider that does not
answer produces a plausible value with nobody's name on it.

# The rule

Every `GetPropertyValue` in `uia.rs` that answers `UIA_NamePropertyId` --
which is to say, every element this host publishes as a thing with a name --
must also answer `UIA_IsEnabledPropertyId`.

`Name` is the right trigger rather than a list of element kinds: an element
worth naming is an element a client will enumerate, and enumerating is exactly
when the filter runs. A new provider added next week is in scope the day it
gets a name, which is the property a list of kinds would not have.

**NOT CHECKED, and the second one is the reason the machine cell exists:**

  * **that the answer is right.** This reads which property ids appear in a
    match; it cannot see whether `IsEnabled` is derived from anything real.
    A provider answering a hard-coded `true` passes this and is the same
    defect with the sign flipped -- **and worse, because a constant `false`
    is noticed the first time somebody looks and a constant `true` is
    believed.** Where the value comes from is argued at `window_enabled`, and
    read on the machine.
  * every other property a client filters on. This gate knows one pair.

# The criterion this cannot run

On the machine, with any UIA client (Inspect, Accessibility Insights, the
`uia-tree-dump.ps1` in this directory), **three states must be tellable
apart** -- and the third is where this defect was hiding:

  1. **operable**: `IsEnabled=true` on the tab strip, the tabs, the terminal
     document and the palette rows, with the window in its ordinary state.
  2. **genuinely disabled**: put up the modal paste confirmation
     (`hang-readings.md` §4 makes one on demand: a `cmd.exe` pane, two lines
     on the clipboard, `Ctrl+V`, and leave the box up). Windows disables an
     owner while a modal is up, so the frame **and** its children must now
     report `IsEnabled=false`. **If they still say true, the value is a
     constant and this gate passed a lie.**
  3. **not answered at all**: the state this task is about. Tell it from (2)
     by reading the property's *source*: a client that reports the property as
     unsupported, or `uia-tree-dump.ps1` showing no `IsEnabled` entry, is (3);
     an element that reports `false` **while the window is not disabled** is
     also (3) wearing (2)'s clothes.

Run:  python3 windows/tools/uia-answers-what-clients-filter-on.py
Exit: 0 when every named element also answers what clients filter on.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
UIA = os.path.normpath(os.path.join(HERE, "..", "host", "src", "uia.rs"))

NEEDS = "UIA_NamePropertyId"
MUST_ALSO = "UIA_IsEnabledPropertyId"
EXEMPT = re.compile(r"//\s*no IsEnabled here:\s*\S")


def strip_comments(text: str) -> str:
    """Comments out for the code question, kept for the exemption.

    Two copies, because this file's own prose names both property ids a dozen
    times and an exemption is written as a comment -- the same split
    `stdio-verdict-survives-its-own-defect.py` had to learn.
    """
    return re.sub(r"//[^\n]*", "", text)


def bodies(src: str):
    """`(line, body)` for every `GetPropertyValue`, by brace matching."""
    for m in re.finditer(r"fn GetPropertyValue\s*\(", src):
        brace = src.find("{", m.end() - 1)
        if brace < 0:
            continue
        depth, k = 0, brace
        while k < len(src):
            if src[k] == "{":
                depth += 1
            elif src[k] == "}":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        yield src.count("\n", 0, m.start()) + 1, src[brace : k + 1]


def analyse(src: str):
    clean = strip_comments(src)
    bad, named = [], 0
    raw = list(bodies(src))
    for (line, body), (_, raw_body) in zip(bodies(clean), raw):
        if NEEDS not in body:
            continue
        named += 1
        if MUST_ALSO in body:
            continue
        if EXEMPT.search(raw_body):
            continue
        bad.append(
            f"uia.rs:{line}: this element answers `{NEEDS}` and not "
            f"`{MUST_ALSO}`. An unanswered property is not one nobody reads -- "
            "it is the one clients filter on first, so the element is dropped "
            "from every enumeration and the host reads as having nothing "
            "operable in it. Answer it from something real, or write "
            "`// no IsEnabled here: <reason>` in the match.")
    return bad, named


# -- self-test ---------------------------------------------------------------

MISSING = '''
fn GetPropertyValue(&self, id: UIA_PROPERTY_ID) -> WResult<VARIANT> {
    Ok(match id {
        UIA_NamePropertyId => variant_bstr("Tabs"),
        _ => variant_empty(),
    })
}
'''
ANSWERED = '''
fn GetPropertyValue(&self, id: UIA_PROPERTY_ID) -> WResult<VARIANT> {
    Ok(match id {
        UIA_NamePropertyId => variant_bstr("Tabs"),
        UIA_IsEnabledPropertyId => variant_bool(window_enabled(self.hwnd())),
        _ => variant_empty(),
    })
}
'''
UNNAMED = '''
fn GetPropertyValue(&self, id: UIA_PROPERTY_ID) -> WResult<VARIANT> {
    Ok(match id {
        UIA_ControlTypePropertyId => variant_i4(1),
        _ => variant_empty(),
    })
}
'''
EXCUSED = MISSING.replace(
    '        _ => variant_empty(),',
    '        // no IsEnabled here: this element is a label and never operable\n'
    '        _ => variant_empty(),')
COMMENT_ONLY = MISSING.replace(
    'fn GetPropertyValue(&self, id: UIA_PROPERTY_ID) -> WResult<VARIANT> {',
    'fn GetPropertyValue(&self, id: UIA_PROPERTY_ID) -> WResult<VARIANT> {\n'
    '    // UIA_IsEnabledPropertyId is handled somewhere, honest')

for sample, want_red, label in (
    (MISSING, True, "a named element that does not answer IsEnabled"),
    (ANSWERED, False, "one that answers it"),
    (UNNAMED, False, "an element with no name, which no client enumerates by"),
    (EXCUSED, False, "one with the reason written in the match"),
    (COMMENT_ONLY, True,
     "a *comment* claiming the property is handled. This repository has had "
     "four checkers read a comment as code"),
):
    got = bool(analyse(sample)[0])
    if got != want_red:
        print(f"FAIL: the probe {'misses' if want_red else 'fires on'} {label}.")
        sys.exit(1)
if analyse(ANSWERED)[1] != 1:
    print("FAIL: the probe did not count the element it looked at, so its "
          "silence covers nothing.")
    sys.exit(1)

# -- the tree ----------------------------------------------------------------

src = open(UIA, encoding="utf-8").read() if os.path.isfile(UIA) else ""
problems, named = analyse(src)
print(f"read uia.rs ({len(src)} bytes); {named} element(s) that publish a name")

# **Subject-set guard.** No named element is not a clean provider, it is a
# gate that found nothing -- and it prints the same all-clear either way.
if not src or named == 0:
    print()
    print("FAIL: uia.rs was not read, or no element publishes a name. There "
          "was nothing to check. Not a pass.")
    sys.exit(1)

if not problems:
    print("OK: every named element also answers what clients filter on.")
    print("NOT CHECKED: whether the answer is right -- a hard-coded `true` "
          "passes this. See the three-state criterion in this file's header.")
    sys.exit(0)

print()
for line in problems:
    print("  " + line)
print()
print(f"FAIL: {len(problems)} element(s) a client will filter out.")
sys.exit(1)
