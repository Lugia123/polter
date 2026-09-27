#!/usr/bin/env python3
"""The workspace's pure crates pass their tests, on whatever machine runs this.

**Why this exists.** A rule that has to agree across platforms is moved out
of `polter-host` into a zero-dependency crate precisely so its tests can run
off Windows (`windows/Cargo.toml` says why for each). But moving it only
makes the tests *runnable*; nothing in the delivery flow ran them. `zig build
test` does not touch cargo, and on a Mac the only cargo command anyone runs
is `cargo test --no-run --target x86_64-pc-windows-gnu -p polter-host`, which
compiles tests and runs none.

Measured on the project filename rule (issue #23), when it still lived in
`polter-host`: changing its 200-byte cap to 199 turned the Zig and Swift
copies' table tests red, and left the Rust copy with `--no-run` at exit 0 and
the table gate green. Three copies pinned by one table, and the pin on one of
them never ran where the code was written. Moving that rule into
`polter-projectname` fixed where it *can* run; this gate is what runs it.

**Every member is in, unless `EXCLUDED` says why not.** A list of crates to
test would leave the next pure crate out by default -- the wrong way round
for a check whose subject is tests nobody runs.

**A crate that ran no unit test fails.** `cargo test` on a crate with none,
or with a filter that matched nothing, prints `0 passed` and exits 0; that
is not a pure crate that passed, it is a check that looked at nothing.

Run:  python3 windows/tools/pure-crates-pass-their-tests.py
Exit: 0 when `cargo test` passes for every member not in `EXCLUDED`, and each
      of them ran at least one unit test.
"""

import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WINDOWS = os.path.normpath(os.path.join(HERE, ".."))
WORKSPACE = os.path.join(WINDOWS, "Cargo.toml")

EXCLUDED = {
    "polter-host": "pulls in `windows`, whose own dependencies do not compile for a "
            "non-Windows target, so `cargo test` there is impossible off "
            "Windows; its tests are compiled with `cargo test --no-run "
            "--target x86_64-pc-windows-gnu` and run on the Windows machine",
}


def workspace_packages(cargo):
    """Package names cargo itself counts as workspace members.

    Asked of cargo rather than read out of `members = [...]`: a path
    dependency inside the workspace directory is a member whether or not it
    is listed, and a reader of that line would miss it without saying so.
    """
    p = subprocess.run([cargo, "metadata", "--no-deps", "--format-version", "1"],
                       cwd=WINDOWS, capture_output=True, text=True)
    if p.returncode != 0:
        return None, p.stderr.strip().splitlines()[-1:] or ["(no output)"]
    meta = json.loads(p.stdout)
    ids = set(meta["workspace_members"])
    return sorted(pk["name"] for pk in meta["packages"] if pk["id"] in ids), None


def main() -> int:
    # **Is the subject here?** Each of these is a FAIL that names what is
    # missing, never a pass on nothing.
    if not os.path.isfile(WORKSPACE):
        print(f"FAIL: {os.path.relpath(WORKSPACE, WINDOWS + '/..')} does not "
              f"exist, so there are no crates to test. That is looking in the "
              f"wrong place, not a clean run.")
        return 1
    cargo = shutil.which("cargo")
    if not cargo:
        print("FAIL: `cargo` is not on PATH. These crates exist so their tests "
              "run on this machine; skipping them quietly is what this gate "
              "is here to stop.")
        return 1

    listed, err = workspace_packages(cargo)
    if not listed:
        print(f"FAIL: cargo reports no workspace members in windows/ "
              f"({err[0] if err else 'empty list'}); this gate cannot tell "
              f"which crates it is meant to test.")
        return 1

    unknown = sorted(set(EXCLUDED) - set(listed))
    if unknown:
        print(f"FAIL: EXCLUDED names {unknown}, which are not workspace "
              f"members. An exemption that outlived its crate would go on "
              f"excusing whatever takes the name next.")
        return 1

    packages = [n for n in listed if n not in EXCLUDED]
    if not packages:
        print("FAIL: every workspace member is excluded, so nothing is tested.")
        return 1

    cmd = [cargo, "test"] + [a for p in packages for a in ("-p", p)]
    # One stream, not stdout + stderr: cargo prints `Running ...` on stderr
    # and each `test result:` on stdout, and concatenating the two loses the
    # order that says which result belongs to which crate. (The first version
    # did that, and the zero-test check below is what caught it.)
    p = subprocess.run(cmd, cwd=WINDOWS, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True)
    out = p.stdout

    # `Running unittests src/lib.rs (.../deps/polter_x-<hash>)` is followed by
    # that binary's `test result:` line; doc-tests are reported separately
    # and do not count as the crate having been tested.
    ran = {}
    current = None
    for line in out.splitlines():
        r = re.search(r"Running unittests \S+ \(.*[/\\]([A-Za-z0-9_]+)-[0-9a-f]+(\.exe)?\)", line)
        if r:
            current = r.group(1).replace("_", "-")
            continue
        t = re.search(r"test result: \w+\. (\d+) passed; (\d+) failed", line)
        if t and current:
            ran[current] = ran.get(current, 0) + int(t.group(1))
            current = None
        elif line.strip().startswith("Doc-tests"):
            current = None

    print(f"cargo test for {len(packages)} crate(s): "
          + ", ".join(f"{n} ({ran.get(n, 0)} unit test(s))" for n in packages))
    print(f"  skipped: " + "; ".join(f"{m} -- {why}" for m, why in sorted(EXCLUDED.items())))

    if p.returncode != 0:
        print()
        tail = [l for l in out.splitlines() if l.strip()][-25:]
        print("\n".join("  " + l for l in tail))
        print()
        print(f"FAIL: `{' '.join(cmd[1:])}` exited {p.returncode}.")
        return 1

    idle = sorted(n for n in packages if ran.get(n, 0) == 0)
    if idle:
        print()
        print(f"FAIL: {', '.join(idle)} ran no unit test. A crate that exists so "
              f"its rule can be tested off Windows, and tests nothing, is a "
              f"check that looked at nothing.")
        return 1

    print("OK: every pure crate's tests ran and passed here")
    return 0


if __name__ == "__main__":
    sys.exit(main())
