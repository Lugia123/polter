#!/usr/bin/env python3
"""The two version schemes must count commits from the same fork point.

# The rope between two literals

Task 649 gave the Windows host its own `POLTER_VERSION` (`update.rs`,
`build.rs`'s `emit_polter_version`), computed to land on the same numbers as
the macOS bundle version -- `X.Y.Z` where `Z` is commits since this fork
began. Both sides need to agree on *where the fork began*, and that agreement
is written twice, once in each language, with nothing between them:

    src/build/PolterVersion.zig    const fork_point = "f81dcadc82ea2afdcf2dc92929037701122f05b5";
    windows/host/build.rs          const POLTER_FORK_POINT: &str = "f81dcadc82ea2afdcf2dc92929037701122f05b5";

# What goes wrong, and why it would not be caught earlier

If the two hashes drift, each side still computes a well-formed version --
`git rev-list --count <its own hash>..HEAD` never fails just because the hash
names an unexpected commit. **The build stays green on both platforms.** The
only symptom is two different patch numbers for a build cut from the same
commit -- `0.6.657` on one side, `0.6.658` on the other -- and that symptom
is invisible until someone cuts a release and compares the two, where it
reads as a mistake in the release process rather than in either source file.

A comment saying "must stay equal" is not a check: this repository has
already met "an honest note about blindness satisfies the gate" once, and a
drifted constant with an accurate comment above it is exactly that shape.

Exit: 0 if the two literals agree, 1 otherwise.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
ZIG = os.path.join(ROOT, "src", "build", "PolterVersion.zig")
RUST = os.path.join(ROOT, "windows", "host", "build.rs")

ZIG_RE = re.compile(r'(?m)^const fork_point\s*=\s*"([0-9a-f]*)"\s*;')
RUST_RE = re.compile(r'(?m)^const POLTER_FORK_POINT:\s*&str\s*=\s*"([0-9a-f]*)"\s*;')


def literal(path: str, pattern: re.Pattern) -> str | None:
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as fh:
        m = pattern.search(fh.read())
    return m.group(1) if m else None


# --------------------------------------------------------------- self-test
#
# Both directions, same reason as `unknown-commit-sentinel-agrees.py`: a probe
# that stopped matching reports nothing and reads like agreement, and a probe
# that matches anything would pass a commented-out declaration.

CANARY_ZIG_OK = 'const fork_point = "f81dcadc82ea2afdcf2dc92929037701122f05b5";\n'
CANARY_ZIG_COMMENTED = '// const fork_point = "deadbeef";\n'
CANARY_RUST_OK = 'const POLTER_FORK_POINT: &str = "f81dcadc82ea2afdcf2dc92929037701122f05b5";\n'


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
        print(f"FAIL: no `const fork_point = \"...\";` in {ZIG}. Either it moved "
              f"or was renamed -- and until this is pointed at it, a green run "
              f"here would mean only that there was nothing to read.")
        return 1
    if rust is None:
        print(f"FAIL: no `const POLTER_FORK_POINT: &str = \"...\";` in {RUST}. "
              f"Same reading as above.")
        return 1

    print(f"zig  {os.path.relpath(ZIG, ROOT)}: fork_point         = {zig!r}")
    print(f"rust {os.path.relpath(RUST, ROOT)}: POLTER_FORK_POINT  = {rust!r}\n")

    if len(zig) != 40 or len(rust) != 40:
        print(
            f"FAIL: a git commit hash is 40 hex characters; zig is {len(zig)}, "
            f"rust is {len(rust)}. One of the two literals is not a full SHA, "
            f"which this check cannot compare with any confidence."
        )
        return 1

    if zig != rust:
        print(
            f"MISMATCH: `PolterVersion.zig` counts commits from {zig!r} and "
            f"`build.rs` counts from {rust!r}.\n"
            f"\n"
            f"A commit built on both platforms from the same tree will get two "
            f"different patch numbers -- macOS's `CFBundleShortVersionString` "
            f"and Windows's `update.rs::VERSION` disagreeing on a build that is "
            f"otherwise identical, which reads as a release-process mistake "
            f"rather than as what it is: these two constants drifted."
        )
        return 1

    print("the two sides count commits from the same fork point")
    return 0


if __name__ == "__main__":
    sys.exit(main())
