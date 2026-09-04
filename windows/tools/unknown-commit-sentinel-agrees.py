#!/usr/bin/env python3
"""The two languages must write the "no commit" sentinel the same way.

# The rope between two literals

A build that cannot name its own commit stamps a placeholder into its version
string. The value is written twice, once in each language, with nothing
between them:

    src/build/Config.zig        const unknown_commit = "0000000";
    windows/host/src/main.rs    const CORE_UNKNOWN: &str = "0000000";

The Zig one is what the core *stamps*; the Rust one is what the host
*recognises*. They are one agreement kept in two places.

# What goes wrong, established by construction rather than by argument

`core_commit` in the host rejects the sentinel by **comparing it to its own
constant**, not by its shape. Running the four combinations through a copy of
that function:

    zig="0000000"    rust="0000000"      -> not checked          (correct)
    zig="0000000000" rust="0000000"      -> read as commit "0000000000"  BUG
    zig="0000000"    rust="0000000000"   -> read as commit "0000000"     BUG
    zig="0000000000" rust="0000000000"   -> not checked          (correct)
    zig="deadbee"    rust="deadbee"      -> not checked          (correct)

**Only disagreement is dangerous, and it is dangerous in both directions.**
Changing both sides together is safe whatever the new value -- even a value
shaped exactly like a real hash -- because the host special-cases whatever its
own constant says.

That is worth stating plainly because the obvious worry is the opposite one:
that a binding which only checks "the two are equal" would be blind to "both
were changed to the same wrong value". **For this pair it is not**, and the
reason is in `core_commit`, not in the binding.

When they do disagree, the failure is the one `log_pairing`'s own comment
rules out: a `MISMATCH` raised **on a perfectly matched pair**, and *"the alarm
would be believed once and ignored thereafter"*.

# The second check, which equality does not give

The sentinel must also be a value no real commit can take. Equality says the
two sides agree; it does not say they agree on something safe. A sentinel of
`deadbee` parses as "not checked" correctly -- until the day a real build's
abbreviated hash *is* `deadbee`, and that build is then read as having no
commit at all. All-zeros is the choice that cannot collide, so that is what is
asserted.

# What this cannot see, and where that check lives instead

**That `core_commit` still special-cases the sentinel at all.** Delete the
`tail == CORE_UNKNOWN` clause and both assertions here still hold, while
`0000000` becomes seven hex digits and is read as a commit. That one is pinned
by a unit test beside the function, in `main.rs` -- **which runs only on
Windows**, the same split task 203 exists because of. Said here so the split
is known rather than assumed away.

Exit: 0 if the two agree and the value is safe, 1 otherwise.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
ZIG = os.path.join(ROOT, "src", "build", "Config.zig")
RUST = os.path.join(ROOT, "windows", "host", "src", "main.rs")

ZIG_RE = re.compile(r'(?m)^const unknown_commit\s*=\s*"([^"]*)"\s*;')
RUST_RE = re.compile(r'(?m)^const CORE_UNKNOWN:\s*&str\s*=\s*"([^"]*)"\s*;')


def literal(path: str, pattern: re.Pattern) -> str | None:
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as fh:
        m = pattern.search(fh.read())
    return m.group(1) if m else None


# --------------------------------------------------------------- self-test
#
# Both directions. A probe that has stopped matching reports nothing and reads
# like agreement, which is the failure this whole directory keeps meeting; and
# a probe that matches anything would pass a commented-out declaration.

CANARY_ZIG_OK = 'const unknown_commit = "0000000";\n'
CANARY_ZIG_COMMENTED = '// const unknown_commit = "beef";\n'
CANARY_RUST_OK = 'const CORE_UNKNOWN: &str = "0000000";\n'


def self_test() -> None:
    if ZIG_RE.search(CANARY_ZIG_OK) is None or RUST_RE.search(CANARY_RUST_OK) is None:
        print("FAIL: the probe cannot see a declaration it wrote itself; the "
              "shape it looks for is no longer the shape either file uses.")
        sys.exit(1)
    if ZIG_RE.search(CANARY_ZIG_COMMENTED) is not None:
        print("FAIL: a commented-out declaration was read as the real one.")
        sys.exit(1)
    print("probe self-test: OK (sees a declaration, ignores a commented one)")


def main() -> int:
    self_test()

    zig = literal(ZIG, ZIG_RE)
    rust = literal(RUST, RUST_RE)

    # **Not finding a declaration is a failure, not a pass.** A gate whose
    # pattern has gone stale prints nothing and exits 0, which is the shape
    # `lock-reentry.py` sat in for as long as the symbol it looked for had
    # been gone.
    if zig is None:
        print(f"FAIL: no `const unknown_commit = \"...\";` in {ZIG}. Either it "
              f"moved or it was renamed -- and until this is pointed at it, a "
              f"green run here would mean only that there was nothing to read.")
        return 1
    if rust is None:
        print(f"FAIL: no `const CORE_UNKNOWN: &str = \"...\";` in {RUST}. Same "
              f"reading as above.")
        return 1

    print(f"zig  {os.path.relpath(ZIG, ROOT)}: unknown_commit = {zig!r}")
    print(f"rust {os.path.relpath(RUST, ROOT)}: CORE_UNKNOWN   = {rust!r}\n")

    if zig != rust:
        print(
            f"MISMATCH: the core stamps {zig!r} and the host looks for {rust!r}.\n"
            f"\n"
            f"A build that cannot name its commit will stamp {zig!r}; the host "
            f"will not recognise that as the sentinel, will find it parses as "
            f"an ordinary abbreviated hash, and will report MISMATCH **on a "
            f"pair that matches**. `log_pairing`'s own comment is about that "
            f"outcome: the alarm would be believed once and ignored thereafter."
        )
        return 1

    if zig.strip("0") != "" or zig == "":
        print(
            f"UNSAFE SENTINEL: both sides agree on {zig!r}, and they may -- but "
            f"the marker for 'no commit' has to be a value no real commit can "
            f"be. {zig!r} is not all zeros, so the day some build's abbreviated "
            f"hash equals it, that build is read as having no commit at all."
        )
        return 1

    print("the two sides write the same sentinel, and it is one no commit can be")
    return 0


if __name__ == "__main__":
    sys.exit(main())
