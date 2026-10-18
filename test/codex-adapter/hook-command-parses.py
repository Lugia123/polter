#!/usr/bin/env python3
"""Does the hook line the Codex adapter writes for Windows parse in PowerShell?

Task 1748. On Windows, Codex runs a hook as
`powershell.exe -NoProfile -Command "<line>"` (measured on the test machine,
Codex 0.154). The line used to be `"<polter>" +hook --cli codex <Event>`:
to PowerShell a string, then a `+` with nothing it can add -- a ParserError,
exit 1, and Polter never started. Every hook of every Codex on Windows
failed that way, which read as "hooks expected, never heard".

So this asks PowerShell's own parser about the line, on paths that are hard
for it, and checks what it reads, not only that it reads:

  1. no parse errors;
  2. one command, called with `&`;
  3. whose name is the path, character for character -- nothing expanded,
     no quote lost;
  4. whose arguments are `+hook --cli codex <Event>` and nothing else.

And that the two twins agree: `hooks.py` and `hooks.ps1` write the same line
and the same trusted hash for it (Codex runs the hook only when the hash
matches what it computes itself).

The control: the old line must *not* parse. Without it a parser that
accepted anything would make every case above pass.

What it does not check: the layer between Codex and PowerShell -- how
`powershell.exe` takes the line off its command line. That is Windows' and
is checked on the machine (the report gives the command).

    python3 test/codex-adapter/hook-command-parses.py     # needs pwsh

Exit: 0 all hold; 1 one does not; 2 no pwsh to ask.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "plugins", "codex"))
import hooks  # noqa: E402

PATHS = [
    r"C:\polter\polter-host.exe",
    r"D:\polter\t1745\pkg\polter-host.exe",
    r"C:\Program Files\Polter\polter-host.exe",
    r"C:\Users\O'Brien\Polter\polter-host.exe",
    r"C:\Users\a$b\${env:X}\$(whoami)\polter-host.exe",
    "C:\\Users\\back`tick\\polter-host.exe",
    r"C:\A & B\x;y\(1)\[2]\100%\polter-host.exe",
    "C:\\用户\\测试 目录\\polter-host.exe",
]


def main():
    pwsh = shutil.which("pwsh")
    if not pwsh:
        print("NOT RUN: no pwsh on this machine to ask")
        return 2
    cases = []
    for path in PATHS:
        for event, label in hooks.EVENTS:
            cases.append({"path": path, "event": event, "label": label})
    old = '"%s" +hook --cli codex SessionStart' % PATHS[0]
    cases.append({"line": old})

    with tempfile.TemporaryDirectory() as tmp:
        f = os.path.join(tmp, "cases.json")
        with open(f, "w", encoding="utf-8") as out:
            json.dump(cases, out, ensure_ascii=False)
        r = subprocess.run(
            [pwsh, "-NoProfile", "-NonInteractive", "-File", os.path.join(HERE, "hook-command-parses.ps1"),
             "-Hooks", os.path.join(ROOT, "plugins", "codex", "hooks.ps1"), "-Cases", f],
            capture_output=True, text=True, encoding="utf-8")
    if r.returncode != 0:
        print("FAIL: pwsh exited %d\n%s" % (r.returncode, r.stderr[-2000:]))
        return 1
    got = json.loads(r.stdout)

    bad = []
    for case, seen in zip(cases, got):
        if "line" in case:
            # The control.
            if seen["errors"] == 0:
                bad.append("the old line parsed, so this check sees nothing: %s" % case["line"])
            continue
        path, event, label = case["path"], case["event"], case["label"]
        py_line = hooks.hook_command(path, event, True)
        where = "%s %s" % (event, path)
        if py_line != seen["line"]:
            bad.append("%s: hooks.py writes %r, hooks.ps1 %r" % (where, py_line, seen["line"]))
        if hooks.trusted_hash(label, py_line) != seen["hash"]:
            bad.append("%s: the twins hash the line differently" % where)
        if seen["errors"] != 0:
            bad.append("%s: %d parse error(s) in %r" % (where, seen["errors"], seen["line"]))
        if seen["op"] != "Ampersand":
            bad.append("%s: called with %r, not &" % (where, seen["op"]))
        if seen["name"] != path:
            bad.append("%s: PowerShell reads the program as %r" % (where, seen["name"]))
        if seen["args"] != ["+hook", "--cli", "codex", event]:
            bad.append("%s: PowerShell reads the arguments as %r" % (where, seen["args"]))

    n = len(cases) - 1
    if bad:
        print("FAIL: %d problem(s) across %d lines" % (len(bad), n))
        for b in bad[:20]:
            print("  " + b)
        return 1
    print("OK: %d lines (%d paths x %d events) parse in PowerShell as & '<path>' +hook --cli codex <Event>, "
          "the twins agree on line and hash, and the old line does not parse." % (n, len(PATHS), len(hooks.EVENTS)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
