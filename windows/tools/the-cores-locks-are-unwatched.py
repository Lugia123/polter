#!/usr/bin/env python3
"""Keep the written account of an unwatched area from going stale.

# What this is, and the first thing to know is what it is not

**This finds no re-entrancy bug, and green here does not mean the core is
safe.** `lock-reentry.py` next door hunts a guard held across a call that can
come back round; it reads `windows/host/src/*.rs` and **nothing else**. Its own
docstring says so, and says why widening it would be wrong: Zig spells the same
idea as `mutex.lock()` with `defer mutex.unlock()`, so the guard runs to the end
of the enclosing block -- "everything after the lock is held" is a different
analysis from following a binding's lifetime, and a widened regex would produce
a field of false positives that the next person would narrow back out. That
judgement stands; this file does not reopen it.

What is left over from that judgement is a **written account of a gap**: the
core has the same hazard, one file has dozens of critical sections, nobody
checks any of them, and the count of risky sites is unknown. **An account like
that is exactly the thing that goes quietly out of date** -- and this
repository has already paid for that once, in the same file: `status.md` cited
`lock-reentry.py` as the reason not to write another checker, and the sentence
it rested on had stopped being true.

So: this re-derives every number and every citation in that account, and fails
when one of them stops matching. **The ledger cannot rot.**

# Why the numbers moved here, and what was wrong with the old one

The account said "`src/Surface.zig` alone contains **97** mutex uses". Two
things about that number:

  * **It carries no method.** Counting `mutex` as a word gives 116 lines, 118
    occurrences, 106 with comments stripped, and 96 if you count calls. A
    number nobody can re-derive cannot be maintained, so it can only go stale.
  * **Re-derived with the method below, today it is 96, not 97.** That is not
    "the old number was wrong": without a recorded method the two are not
    comparable, and the difference may be the method rather than any drift.
    It is written down as an unexplained one, which is what an unexplained one
    should look like.

The method, so the next reading is comparable: **strip `//` comments, then
count `.mutex.<name>(` occurrences.** It counts calls made on a mutex, which is
the thing the hazard is about, and it does not count the word appearing in a
type, a field name or a sentence.

# The four claims

  1. **How much there is.** 96 calls in `src/Surface.zig`, in a 48/48 split of
     `lockUncancelable` and `unlock`. A change either way wants a look: this is
     the size of the unchecked area.
  2. **Where the core took care.** Two sites deliberately drop the lock across
     a call and take it back in a `defer` -- the paste arms of
     `mouseButtonCallback`, with the comment *"Pasting can trigger a lock grab
     in complete clipboard request so we need to unlock."* **Going down is a
     safety regression**, not a tidy-up: it is the core's own evidence that it
     knows the hazard is real.
  3. **What kind of lock it is.** `renderer_state.mutex` is a `std.Io.Mutex`,
     which is not reentrant. If it ever becomes a reentrant lock the gap
     changes character and this account should be rewritten rather than
     maintained.
  4. **That the area really is unwatched.** `lock-reentry.py` still scans
     `windows/host/src/*.rs` only. If somebody widens it to the core, this file
     is describing a gap that no longer exists and should be deleted.

# NOT CHECKED

  * **Any actual re-entrancy in the core.** Not one site here is analysed. The
    count of *risky* sites remains unknown, which is what the account says and
    what this preserves.
  * **Mutexes outside `src/Surface.zig`.** It is the file the account named,
    because it is the worst one; the rest of the core is not counted and its
    silence here means nothing.
  * **Whether the two careful sites are still correct**, only that they are
    still there in the shape the account describes.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
SURFACE = os.path.join(ROOT, "src", "Surface.zig")
STATE = os.path.join(ROOT, "src", "renderer", "State.zig")
LOCK_GATE = os.path.join(HERE, "lock-reentry.py")

# Claim 1. Re-derive with `mutex_calls`; the split is named so a *new* call
# name shows up as a mismatch rather than as a number that happens to add up.
CALLS = 96
SPLIT = {"lockUncancelable": 48, "unlock": 48}

# Claim 2. Down is a safety regression; up means somebody found another.
CAREFUL_SITES = 2


def strip_comments(src):
    return "\n".join(re.sub(r"//.*", "", ln) for ln in src.split("\n"))


def mutex_calls(src):
    """`.mutex.<name>(` occurrences, comments removed. The stated method."""
    return re.findall(r"\.mutex\.([A-Za-z_][A-Za-z_0-9]*)\(", strip_comments(src))


def careful_sites(src):
    """Lines that drop the lock and take it back in a following `defer`.

    The window is three lines: the `defer` sits directly under the `unlock` in
    both of today's sites, and a wider window would start pairing an unlock
    with somebody else's relock.
    """
    lines = strip_comments(src).split("\n")
    out = []
    for i, ln in enumerate(lines):
        if ".mutex.unlock(" not in ln:
            continue
        ahead = "\n".join(lines[i + 1 : i + 4])
        if re.search(r"defer\s+.*\.mutex\.lockUncancelable\(", ahead):
            out.append(i + 1)
    return out


def self_test():
    good = (
        "a.mutex.unlock(io);\n"
        "defer a.mutex.lockUncancelable(io);\n"
        "b.mutex.lockUncancelable(io);\n"
    )
    commented = "// a.mutex.unlock(io);\n// defer a.mutex.lockUncancelable(io);\n"
    far = (
        "a.mutex.unlock(io);\n\n\n\n"
        "defer a.mutex.lockUncancelable(io);\n"
    )
    cases = [
        ("the shape the core uses", good, 3, 1),
        ("the same thing written in a comment", commented, 0, 0),
        ("a relock too far away to be this unlock's", far, 2, 0),
    ]
    for what, src, want_calls, want_sites in cases:
        c, s = len(mutex_calls(src)), len(careful_sites(src))
        if (c, s) != (want_calls, want_sites):
            print(f"probe self-test FAILED: {what} gave {c} call(s)/{s} site(s), "
                  f"expected {want_calls}/{want_sites}")
            return False
    print("probe self-test: OK (the real shape, the same words in a comment, "
          "a relock too far away)")
    return True


def read(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError as e:
        # Missing is a failure, not a skip: an account whose subject has moved
        # is an account nobody is keeping.
        print(f"cannot read {what}: {e}")
        return None


def main():
    if not self_test():
        return 1
    surface = read(SURFACE, "src/Surface.zig")
    state = read(STATE, "src/renderer/State.zig")
    gate = read(LOCK_GATE, "windows/tools/lock-reentry.py")
    if surface is None or state is None or gate is None:
        return 1

    calls = mutex_calls(surface)
    split = {}
    for name in calls:
        split[name] = split.get(name, 0) + 1
    sites = careful_sites(surface)
    print(f"src/Surface.zig: {len(calls)} mutex call(s) "
          f"({', '.join(f'{v} {k}' for k, v in sorted(split.items()))}); "
          f"{len(sites)} site(s) drop the lock and take it back")

    out = []
    if len(calls) != CALLS or split != SPLIT:
        out.append(
            f"the size of the unchecked area moved: the account says {CALLS} call(s) "
            f"{SPLIT}, the file has {len(calls)} {split}. Re-read it and write the new "
            "number here -- **with its method**, which is what the last one was missing"
        )
    if len(sites) < CAREFUL_SITES:
        out.append(
            f"only {len(sites)} site(s) now drop the lock across the call, down from "
            f"{CAREFUL_SITES} (lines {sites}). Those are the core's own precautions "
            "against exactly the hazard nothing checks -- removing one is a safety "
            "change, not a cleanup"
        )
    elif len(sites) > CAREFUL_SITES:
        out.append(
            f"{len(sites)} site(s) now drop the lock, up from {CAREFUL_SITES}. Good news, "
            f"and the account should say so: set CAREFUL_SITES = {len(sites)}"
        )
    if not re.search(r"mutex:\s*\*std\.Io\.Mutex", state):
        out.append(
            "`renderer_state.mutex` is no longer declared `*std.Io.Mutex` in "
            "src/renderer/State.zig. The whole account rests on it being a lock that is "
            "not reentrant; if that changed, rewrite the account rather than update it"
        )
    # **The glob expression, not the whole file.** The first version of this
    # asked whether `"src"` appeared anywhere in `lock-reentry.py` -- and it
    # does, in the `os.path.join(..., "host", "src")` that points at the Rust,
    # and again in the prose that explains why the core is *not* scanned. It
    # reported the gap closed on a tree where nothing had changed: **a
    # detector made of real symbols with the relation read backwards**, which
    # is the shape this repository keeps meeting. So only the argument of
    # `glob.glob(` is read, which is the one place that decides what is
    # scanned.
    globs = re.findall(r"glob\.glob\(([^)]*)\)", gate)
    if not globs:
        out.append(
            "lock-reentry.py no longer collects its files with `glob.glob(`, so this "
            "file can no longer tell what it scans. Re-read it: either the gap moved or "
            "this check did"
        )
    elif any(".zig" in g for g in globs):
        out.append(
            "lock-reentry.py globs `.zig` now. If it really scans the core, this file "
            "describes a gap that has been closed and should be deleted rather than "
            "kept green"
        )

    for o in out:
        print(f"HIT    {o}")
    if out:
        print(f"\n{len(out)} claim(s) in the account of the core's unwatched locks no "
              "longer match the tree.")
        return 1
    print("OK: the gap is still the gap that was written down -- **which is not the same "
          "as the core being safe**. Nothing here analyses a single one of those "
          f"{len(calls)} calls.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
