#!/usr/bin/env python3
"""Find calls made while the `STATE` guard from `tabs::state()` is still alive.

The host keeps its whole model behind one mutex. Taking it twice on one thread
is not a slow lock, it is a hang: the second `state()` waits five seconds and
then panics naming both ends. That is a good failure, but it is a failure at
runtime, and the shape is easy to write by accident because the second take is
usually several calls away and looks like an ordinary helper.

Two things this does that a hand-written check does not:

  * **The set of lock-taking functions is derived, not listed.** A hand-written
    list is what let the original deadlock through: `take_id` took the lock,
    nobody had thought of it as a locker, and it was called inside a struct
    literal that was itself inside a guard's scope. Here anything that calls
    `state()` is a locker, and so is anything that calls one of those, to a
    fixed point.

  * **Files come from a glob, not a list.** A module added next week is scanned
    without anyone remembering to add it, which is the same class of omission
    one level up.

Exit: 0 if the hits match KNOWN exactly, 1 otherwise.
"""

import glob
import os
import re
import sys

# Findings that are understood and accepted. Empty means the rule holds
# everywhere; a new key here needs a sentence saying why it is safe, not just
# a name -- an entry without a reason is how a real hit gets parked forever.
KNOWN: dict[str, str] = {}


def strip_comments(src: str) -> str:
    """`state()` inside a comment is not a call.

    Added after this exact false positive: a comment explaining the lock made
    its own module look like a locker, which then made every caller of that
    module look like one too. One bad line, and the derived set inflates until
    the output is noise.
    """
    return "\n".join(re.sub(r"//.*$", "", line) for line in src.split("\n"))


def function_bodies(src: str) -> dict[str, str]:
    """Map function name to its body, by brace balance."""
    out: dict[str, str] = {}
    for m in re.finditer(r'\n(?:pub )?(?:unsafe )?(?:extern "system" )?fn (\w+)', src):
        try:
            start = src.index("{", m.end())
        except ValueError:
            continue
        depth, j = 0, start
        while j < len(src):
            if src[j] == "{":
                depth += 1
            elif src[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        out[m.group(1)] = src[start:j]
    return out


def derive_lockers(sources: dict[str, str]) -> set[str]:
    """Everything that reaches `state()`, transitively."""
    bodies = {}
    for name, src in sources.items():
        for fn, body in function_bodies(src).items():
            bodies[(name, fn)] = body

    lockers = {k for k, body in bodies.items() if re.search(r"\bstate\(\)", body)}
    changed = True
    while changed:
        changed = False
        for k, body in bodies.items():
            if k in lockers:
                continue
            for _, callee in lockers:
                if re.search(r"\b%s\s*\(" % re.escape(callee), body):
                    lockers.add(k)
                    changed = True
                    break
    return {fn for _, fn in lockers}


def scan(sources: dict[str, str], lockers: set[str]):
    """Yield (file, line, called_lockers) for every guard that outlives a call."""
    for name, src in sources.items():
        lines = src.split("\n")
        for i, line in enumerate(lines):
            m = re.search(r"let (?:mut )?(\w+)\s*=\s*(?:tabs::)?state\(\);", line)
            if not m:
                continue
            guard = m.group(1)
            pos = sum(len(x) + 1 for x in lines[:i])

            # Walk out to the enclosing block, then forward to its close: that
            # span is where the guard is alive.
            depth, k = 0, pos
            while k > 0:
                if src[k] == "}":
                    depth -= 1
                elif src[k] == "{":
                    depth += 1
                    if depth == 1:
                        break
                k -= 1
            depth, end = 0, len(src)
            for p in range(k, len(src)):
                if src[p] == "{":
                    depth += 1
                elif src[p] == "}":
                    depth -= 1
                    if depth == 0:
                        end = p
                        break
            scope = src[pos:end]

            # An explicit `drop(guard)` ends it early; calls after that are fine.
            dm = re.search(r"drop\(\s*%s\s*\)" % re.escape(guard), scope)
            if dm:
                scope = scope[: dm.start()]

            hits = sorted(
                {
                    fn
                    for fn in lockers
                    if re.search(r"(?<![.\w])%s\s*\(" % re.escape(fn), scope)
                }
            )
            if hits:
                yield name, i + 1, guard, hits


# --------------------------------------------------------------- self-test
#
# **Both directions, because the two ways this tool can lie are different.**
# A probe that has stopped matching reports zero and reads exactly like a clean
# tree -- that is the failure we have hit repeatedly, and it is what the
# positive canary is for. A probe that fires on everything is caught by nobody
# unless something clean is fed to it, which is what the negative canary is
# for: without it, "the drop is honoured" is an assumption about our own code.

CANARY_BAD = {
    "canary": """
fn take_id() -> u32 {
    let st = state();
    st.next
}

fn create() {
    let mut st = state();
    st.tabs.push(Tab { id: take_id() });
}
"""
}

CANARY_OK = {
    "canary": """
fn take_id() -> u32 {
    let st = state();
    st.next
}

fn create() {
    let mut st = state();
    st.dirty = true;
    drop(st);
    let id = take_id();
}
"""
}


def self_test() -> None:
    bad = list(scan(CANARY_BAD, derive_lockers(CANARY_BAD)))
    if not bad:
        print("FAIL: the probe cannot see the re-entrant shape it was written for.")
        sys.exit(1)
    ok = list(scan(CANARY_OK, derive_lockers(CANARY_OK)))
    if ok:
        print(f"FAIL: the probe fires on code that releases the guard first: {ok}")
        sys.exit(1)
    print("probe self-test: OK (sees the re-entrant shape, ignores the released one)")


def main() -> int:
    self_test()

    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host", "src")
    paths = sorted(glob.glob(os.path.join(root, "*.rs")))

    # **A gate that scanned nothing exits 0 and reads as green.**
    # Measured, not assumed: pointed at a tree where `windows/host/src/` is empty,
    # this gate printed `scanned 0 files` and then its own all-clear, and returned
    # 0. **The count was already on the screen -- nothing acted on it.**
    #
    # `ps1-parses.py` is the model. What has to be non-empty is the *subject set*,
    # not the hit count: zero hits is a real pass, zero files is not an answer.
    if not paths:
        print(f"FAIL: no .rs file under {root}; this gate is looking in the "
              f"wrong place. It did not find a clean tree -- it found nothing "
              f"to look at, and those two exit the same way unless this line "
              f"exists.")
        return 1

    sources = {}
    for path in paths:
        with open(path, encoding="utf-8") as fh:
            sources[os.path.basename(path)[:-3]] = strip_comments(fh.read())

    lockers = derive_lockers(sources)
    print(f"scanned {len(paths)} files; {len(lockers)} functions reach the lock\n")

    unexpected = []
    for name, line, guard, hits in scan(sources, lockers):
        where = f"{name}.rs:{line}"
        if name + ".rs" in KNOWN:
            print(f"known  {where}  guard `{guard}` -> {hits}")
            continue
        unexpected.append(where)
        print(f"HIT    {where}  guard `{guard}` is alive across {hits}")

    if unexpected:
        print(f"\n{len(unexpected)} unexpected; each one is a five-second panic waiting.")
        return 1
    print("no unexpected hits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
