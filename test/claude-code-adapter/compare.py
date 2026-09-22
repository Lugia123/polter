#!/usr/bin/env python3
"""Do `adapter.py` and `adapter.ps1` give the same answers?

`plugins/claude-code/adapter.ps1` is a port of `adapter.py`, and the two are
the same adapter on two systems: the one Polter runs on Windows, the other
everywhere else. A difference between them is a role that behaves one way on
a Mac and another on Windows, and nothing else would show it. So this feeds
both the same requests over the same files and compares what comes out.

    python3 test/claude-code-adapter/compare.py              # from the repo root
    python3 test/claude-code-adapter/compare.py --ps pwsh    # a specific PowerShell
    python3 test/claude-code-adapter/compare.py --keep       # leave the files behind

Needs Python 3 (to run `adapter.py`) and a PowerShell: on Windows the default
is `powershell`, which is Windows PowerShell 5.1 -- **the one Polter starts
the adapter with** (`Plugin.launchArgvFor`), started with the same flags; on
anything else, `pwsh`.

# What is compared

For every request in `fixtures.json`:

  1. **The exit code.** Always.
  2. **The answer, byte for byte**, when both succeed -- after the
     normalisation below and nothing else.
  3. **That the PowerShell answer is formatted exactly as Python formats
     JSON**: its bytes are compared with `json.dumps(json.loads(them),
     ensure_ascii=False) + "\\n"`. Step 2 compares values; this is what makes
     it byte for byte rather than "the same JSON".

# What is normalised, and why each one is allowed to differ

  N1. **`argv[0]` on Windows.** `adapter.py` answers `claude`; `adapter.ps1`
      answers the program itself -- an absolute path ending in `claude.exe`,
      or `node.exe` followed by Claude Code's `.js` -- because npm's
      `claude.cmd` is a batch file and a role's instructions must not go
      through `cmd.exe`. The shape is checked (one of those two), then the
      prefix is replaced by `claude` and the rest compared as usual. What it
      resolved to is printed. Not normalised off Windows: both say `claude`.
  N2. **`installed` on Windows.** `adapter.py` looks for a file named exactly
      `claude`, which Windows does not have, so it says `false` there on any
      machine. Printed, not compared. Compared everywhere else.
  N3. **The text after "Could not read <file>: "** in a note. That is the
      JSON reader's own error message -- Python's `json` module against
      .NET's -- and the wording is theirs, not ours. The note, which file it
      names and where it sits are compared; the reader's sentence is not.

Nothing else is normalised: paths inside the answers do not appear (an
answer names servers and skills, never where they live), and the fixtures
use `/` in every path an answer does carry, which both platforms' `basename`
read the same way.

# Known differences the fixtures stay away from

A float inside the user's own `--settings` JSON (`1e5` is written back by
Python as `100000.0`, by the PowerShell side as its source spelled it), and
astral characters sorted against U+E000..U+FFFF (Python sorts code points,
.NET UTF-16 units). Neither is reachable from a role written by the window.

Exit: 0 when every request agrees, 1 otherwise.
"""

import argparse
import collections
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PLUGIN = os.path.join(ROOT, "plugins", "claude-code")
ON_WINDOWS = os.name == "nt"


def substitute(value, paths):
    if isinstance(value, str):
        for k, v in paths.items():
            value = value.replace("{" + k + "}", v)
        return value
    if isinstance(value, list):
        return [substitute(v, paths) for v in value]
    if isinstance(value, dict):
        return {substitute(k, paths): substitute(v, paths) for k, v in value.items()}
    return value


def materialise(files, base):
    paths = {k: os.path.join(base, k.lower()) for k in ("HOME", "HOME2", "CWD")}
    for k in paths.values():
        os.makedirs(k, exist_ok=True)
    for rel, content in files.items():
        top, rest = rel.split("/", 1)
        full = os.path.join(paths[top], *rest.split("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        if isinstance(content, dict):
            data = json.dumps(substitute(content["json"], paths), ensure_ascii=False, indent=2)
        else:
            data = substitute(content, paths)
        # Bytes, so a `\r\n` in the fixture stays `\r\n` on disk everywhere.
        with open(full, "wb") as f:
            f.write(data.encode("utf-8"))
    return paths


def run(argv, env):
    p = subprocess.run(argv, capture_output=True, env=env)
    return p.returncode, p.stdout, p.stderr.decode("utf-8", "replace").strip()


def normalise(answer, ps_side, report):
    """N1 and N3 on a parsed answer. `ps_side` says which adapter it came from."""
    if ON_WINDOWS and ps_side and isinstance(answer.get("argv"), list) and answer["argv"]:
        argv = answer["argv"]
        first = argv[0]
        if isinstance(first, str) and os.path.isabs(first) and first.lower().endswith("claude.exe"):
            report.append("argv[0] resolved to " + first)
            answer["argv"] = ["claude"] + argv[1:]
        elif (len(argv) > 1 and isinstance(first, str) and first.lower().endswith("node.exe")
              and isinstance(argv[1], str) and argv[1].lower().endswith(".js")):
            report.append("argv[0:2] resolved to %s %s" % (first, argv[1]))
            answer["argv"] = ["claude"] + argv[2:]
        else:
            report.append("argv[0] is %r, which is neither claude.exe nor node.exe + .js" % (first,))
    if isinstance(answer.get("notes"), list):
        out = []
        for n in answer["notes"]:
            if isinstance(n, str) and n.startswith("Could not read ") and ": " in n:
                n = n[: n.index(": ", len("Could not read ")) + 2] + "<reader's message>"
            out.append(n)
        answer["notes"] = out
    if ON_WINDOWS and "installed" in answer:
        report.append("installed = %s (%s, not compared on Windows)" % (answer["installed"], "ps1" if ps_side else "py"))
        answer["installed"] = None
    return answer


def first_difference(a, b):
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return min(len(a), len(b))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ps", default="powershell" if ON_WINDOWS else "pwsh",
                    help="the PowerShell to run adapter.ps1 with")
    ap.add_argument("--keep", action="store_true", help="leave the fixture files behind")
    args = ap.parse_args()

    ps = shutil.which(args.ps)
    if ps is None:
        print("no %s on PATH: this compares two adapters and can only run one of them, so it fails" % args.ps)
        return 1

    with open(os.path.join(HERE, "fixtures.json"), encoding="utf-8") as f:
        fixtures = json.load(f)

    base = tempfile.mkdtemp(prefix="polter-adapter-")
    try:
        paths = materialise(fixtures["files"], base)
        env = dict(os.environ)
        # The request without a home falls back to these, and so do the
        # places the POSIX side looks for `claude` besides `PATH`.
        env["HOME"] = paths["HOME"]
        env["USERPROFILE"] = paths["HOME"]
        # **Measured on the Windows test machine, and it cost this script its
        # own floor.** Python on Windows writes a redirected stdout in the
        # system code page, so `adapter.py` died with `UnicodeEncodeError` on
        # the emoji in the fixtures and exited 1 -- four of the twelve
        # requests. That is a difference in the harness, not in the adapters,
        # and it is worse than a false alarm: the control that proves this
        # script can tell the two apart (break `adapter.ps1` on purpose and
        # watch it go red) **passed while broken**, because the same four
        # requests were red before and after. `PYTHONUTF8=1` is what Polter's
        # own adapter is not affected by -- it reads and writes bytes -- and
        # what makes the Python side comparable here.
        env["PYTHONUTF8"] = "1"
        # And it is outranked by this one, which a machine may already have
        # set to its code page, so the harness takes it off rather than
        # leaving the fix conditional on somebody's environment.
        env.pop("PYTHONIOENCODING", None)

        py_cmd = [sys.executable, os.path.join(PLUGIN, "adapter.py")]
        # **The same flags Polter starts it with** (`Plugin.launchArgvFor`),
        # so this is the invocation that ships rather than a friendlier one.
        ps_cmd = [ps, "-NoProfile", "-NonInteractive"]
        if ON_WINDOWS:
            ps_cmd += ["-ExecutionPolicy", "Bypass"]
        ps_cmd += ["-File", os.path.join(PLUGIN, "adapter.ps1")]

        print("python:     %s" % sys.executable)
        print("powershell: %s" % ps)
        print("fixtures:   %s%s" % (base, "" if args.keep else " (removed afterwards)"))
        failures = 0
        for case in fixtures["requests"]:
            if "raw" in case:
                request = case["raw"]
            else:
                request = json.dumps(substitute(case["request"], paths), ensure_ascii=False)
            q = case["question"]
            rc_py, out_py, err_py = run(py_cmd + [q, request], env)
            rc_ps, out_ps, err_ps = run(ps_cmd + [q, request], env)
            report = []
            ok = True
            # A request that carries a real JSON object is one both adapters
            # answer. `adapter.py` failing on one of those is this script's
            # own footing giving way -- say so in those words, because the
            # first time it happened it read as the adapters disagreeing.
            if "raw" not in case and rc_py != 0:
                report.append("adapter.py itself failed (exit %d). That is this harness, "
                              "not a difference between the adapters." % rc_py)
            if rc_py != rc_ps:
                ok = False
                report.append("exit codes differ: py %d, ps1 %d" % (rc_py, rc_ps))
                if err_ps:
                    report.append("ps1 stderr: " + err_ps)
                if err_py:
                    report.append("py stderr: " + err_py)
            elif rc_py == 0:
                try:
                    a = json.loads(out_py.decode("utf-8"), object_pairs_hook=collections.OrderedDict)
                    b = json.loads(out_ps.decode("utf-8"), object_pairs_hook=collections.OrderedDict)
                except ValueError as e:
                    ok = False
                    report.append("an answer is not JSON: %s" % e)
                else:
                    canon = (json.dumps(b, ensure_ascii=False) + "\n").encode("utf-8")
                    if canon != out_ps:
                        ok = False
                        i = first_difference(canon, out_ps)
                        report.append("ps1 is not formatted as json.dumps formats it, from byte %d: %r vs %r"
                                      % (i, out_ps[i:i + 40], canon[i:i + 40]))
                    sa = json.dumps(normalise(a, False, report), ensure_ascii=False)
                    sb = json.dumps(normalise(b, True, report), ensure_ascii=False)
                    if sa != sb:
                        ok = False
                        i = first_difference(sa, sb)
                        report.append("answers differ from character %d:\n      py:  %s\n      ps1: %s"
                                      % (i, sa[max(0, i - 60):i + 80], sb[max(0, i - 60):i + 80]))
            status = "same" if ok else "DIFFERENT"
            print("%-9s %-10s %s (exit %d)" % (status, q, case["name"], rc_py))
            for r in report:
                print("          " + r)
            failures += 0 if ok else 1
        print()
        n = len(fixtures["requests"])
        if failures:
            print("%d of %d request(s) answered differently" % (failures, n))
            return 1
        print("all %d request(s) answered the same" % n)
        return 0
    finally:
        if not args.keep:
            shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
