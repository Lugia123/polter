#!/usr/bin/env python3
"""The Windows host writes no file the core writes too (#1513).

**Why this one exists.** The host kept its window geometry in
`%LOCALAPPDATA%\\polter\\session.json`. The core keeps its session -- what
`session_recall` hands a supervisor after a restart -- in
`<state>\\polter\\session.json`, and on Windows `<state>` falls back to
`LOCALAPPDATA` exactly as the host's directory does. So on every machine
that sets neither `XDG_STATE_HOME` nor `XDG_CONFIG_HOME`, which is every
ordinary one, the two were the same file. Each replaced it whole and neither
read the other's half: the host wrote on the first activation of every run,
and the core's record was gone -- an empty `session_recall`, and a restored
group's members written away as `[]`. Or the core wrote last, and the window
came back in the default place. Nothing failed; both sides were well formed.

**What is checked.** Every name the host joins directly onto Polter's own
directory -- `plugins::user_dir()?.parent()?.join(NAME)`, the one way the
host reaches that directory -- is collected, a constant argument resolved
to its literal. Each must not appear as a string literal in the core's Zig
(`src/`, test blocks and comments left out), which is where the core's names
for what it keeps there are written.

A join that only *reads* an older build's file under a core name says so at
the end of its line with `// gate: read-only`, and is then held to that: the
function it is in may be called only inside `read_to_string(...)`.

**NOT CHECKED:** names the host builds at run time (`format!`), files it
writes below a subdirectory (`plugins\\`, `logs\\`), and names the core puts
together from pieces rather than writes whole. A core literal that is only
ever read, never written, still counts as the core's.

Run:  python3 windows/tools/host-files-are-not-the-cores.py
Exit: 0 when no name is shared; 1 when one is, or when nothing was found.
"""

import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))

JOIN = re.compile(r"user_dir\(\)\?\s*\.parent\(\)\?\s*\.join\(\s*(\"[^\"]+\"|[A-Za-z_][A-Za-z0-9_]*)\s*\)")
CONST = re.compile(r"\bconst\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*&(?:'static\s+)?str\s*=\s*\"([^\"]+)\"")
MARKER = "// gate: read-only"
FN = re.compile(r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")


def host_names(files):
    """(name, file, line, read_only, fn) for every join onto Polter's directory."""
    out = []
    for path in files:
        src = open(path, encoding="utf-8").read()
        consts = dict(CONST.findall(src))
        fn = None
        for n, line in enumerate(src.splitlines(), 1):
            m = FN.search(line)
            if m:
                fn = m.group(1)
            for j in JOIN.finditer(line):
                arg = j.group(1)
                if arg.startswith('"'):
                    name = arg[1:-1]
                elif arg in consts:
                    name = consts[arg]
                else:
                    # A name this cannot resolve is not a name it can clear.
                    out.append((None, path, n, False, fn, arg))
                    continue
                out.append((name, path, n, MARKER in line, fn, arg))
    return out


def core_literals(files):
    """Every string literal in the core's Zig, outside tests and comments."""
    lits = {}
    lit = re.compile(r'"((?:[^"\\]|\\.)*)"')
    for path in files:
        depth_in_test = None
        depth = 0
        for n, raw in enumerate(open(path, encoding="utf-8"), 1):
            line = raw.split("//", 1)[0] if not raw.lstrip().startswith("\\\\") else ""
            if depth_in_test is None and re.match(r"\s*test\b", raw):
                depth_in_test = depth
            if depth_in_test is None:
                for m in lit.finditer(line):
                    lits.setdefault(m.group(1), (path, n))
            depth += line.count("{") - line.count("}")
            if depth_in_test is not None and depth <= depth_in_test and "}" in line:
                depth_in_test = None
    return lits


def only_read(path, fn):
    """Every call of `fn` in `path` is inside `read_to_string(`."""
    src = open(path, encoding="utf-8").read()
    calls = [m.start() for m in re.finditer(rf"(?<!fn ){re.escape(fn)}\(\)", src)]
    if not calls:
        return False
    for at in calls:
        start = src.rfind("\n", 0, at) + 1
        if "read_to_string(" not in src[start:at]:
            return False
    return True


def collisions(hosts, lits):
    bad = []
    for name, path, n, read_only, fn, arg in hosts:
        if name is None:
            bad.append(f"{rel(path)}:{n}: joins `{arg}`, which this cannot resolve to a name")
            continue
        if name not in lits:
            continue
        if read_only:
            if fn and only_read(path, fn):
                continue
            bad.append(f"{rel(path)}:{n}: `{name}` is marked read-only, but `{fn}()` is used other "
                       f"than inside read_to_string(...)")
            continue
        cpath, cn = lits[name]
        bad.append(f"{rel(path)}:{n}: the host writes `{name}` in Polter's directory, and the core "
                   f"names it too ({rel(cpath)}:{cn})")
    return bad


def rel(p):
    return os.path.relpath(p, ROOT)


def self_test():
    """The defect this exists for, as it was: it has to be found."""
    import tempfile
    d = tempfile.mkdtemp(prefix="host-files-gate-")
    rs = os.path.join(d, "session.rs")
    zig = os.path.join(d, "Session.zig")
    with open(rs, "w", encoding="utf-8") as f:
        f.write('fn path() -> Option<PathBuf> {\n'
                '    Some(crate::plugins::user_dir()?.parent()?.join("session.json"))\n}\n')
    with open(zig, "w", encoding="utf-8") as f:
        f.write('pub fn defaultPath(alloc: Allocator, state_dir: []const u8) ![]const u8 {\n'
                '    return std.fs.path.join(alloc, &.{ state_dir, "session.json" });\n}\n'
                'test "only here" {\n    _ = "host-window.json";\n}\n')
    found = collisions(host_names([rs]), core_literals([zig]))
    ok = open(rs, encoding="utf-8").read().replace('"session.json"', '"host-window.json"')
    with open(rs, "w", encoding="utf-8") as f:
        f.write(ok)
    clean = collisions(host_names([rs]), core_literals([zig]))
    if len(found) != 1 or clean:
        print(f"FAIL: self-test: the old collision gave {found}, the renamed file gave {clean}. "
              "The gate is not reading what it says it reads.")
        sys.exit(2)


def main():
    self_test()
    rs = sorted(glob.glob(os.path.join(ROOT, "windows", "*", "src", "**", "*.rs"), recursive=True))
    zig = sorted(glob.glob(os.path.join(ROOT, "src", "**", "*.zig"), recursive=True))
    hosts = host_names(rs)
    lits = core_literals(zig)
    print(f"scanned {len(rs)} host .rs file(s), {len(zig)} core .zig file(s); "
          f"{len(hosts)} join(s) onto Polter's directory: "
          + ", ".join(sorted({h[0] or '?' for h in hosts})))
    if not rs or not zig or not hosts:
        print("FAIL: nothing to compare. A gate that found no host file names has checked nothing.")
        return 1
    bad = collisions(hosts, lits)
    for b in bad:
        print("FAIL: " + b)
    if bad:
        return 1
    print("OK: no file name the host writes in Polter's directory is one the core uses.")
    print("NOT CHECKED: names built at run time, files below a subdirectory, names the core assembles.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
