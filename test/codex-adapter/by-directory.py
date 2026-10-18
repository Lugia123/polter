#!/usr/bin/env python3
"""Which Codex session `identify` names in a directory: never another's.

Task 1749. A Codex started by hand has no hooks, so a take-over finds its
session in the records: those written in the last day for this directory,
matched to **when this Codex's Polter server started** (`by_directory` in
`plugins/codex/adapter.py`, `Get-ByDirectory` in `adapter.ps1`). Codex writes
a session's record with the first turn, 15 to 50 s after it started
(measured on Windows, codex 0.154), so for that long the only record in the
directory may be another Codex's -- and a take-over that went on with it
would carry on somebody else's conversation.

Runs `adapter.py`, and `adapter.ps1` when a PowerShell is there, as Polter
does, against records written here; a `sleep` stands in for the sidecar, so
its start is now. No `codex` is run.

    python3 test/codex-adapter/by-directory.py

Exit 0 when every case holds for every adapter run.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PLUGIN = os.path.join(ROOT, "plugins", "codex")

failures = []


def check(case, ok, what):
    print("%s  %s: %s" % ("ok  " if ok else "FAIL", case, what))
    if not ok:
        failures.append("%s: %s" % (case, what))


def record(day, cwd, started_ms, tail):
    """A session record as Codex writes it: its start in `session_meta`."""
    h = "%012x" % started_ms
    sid = "%s-%s-7000-8000-%012x" % (h[:8], h[8:], tail)
    iso = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(started_ms / 1000)) + ".%03dZ" % (started_ms % 1000)
    with open(os.path.join(day, "rollout-2026-10-18T06-00-00-%s.jsonl" % sid), "w") as f:
        f.write(json.dumps({"type": "session_meta", "payload": {"id": sid, "cwd": cwd, "timestamp": iso}}) + "\n")
    return sid


def identify(cmd, home, cwd, sidecar):
    req = {"version": 1, "cwd": cwd, "home": home, "pid": None, "sidecar_pid": sidecar,
           "env": {"POLTER_AGENT_CLI": "codex"}}
    env = {k: v for k, v in os.environ.items() if k != "CODEX_HOME"}
    p = subprocess.run(cmd + ["identify", json.dumps(req)], capture_output=True, text=True, encoding="utf-8", timeout=60, env=env)
    if p.returncode != 0:
        raise SystemExit("identify exited %d: %s" % (p.returncode, p.stderr))
    return json.loads(p.stdout)


def main():
    adapters = [("py", [sys.executable, os.path.join(PLUGIN, "adapter.py")])]
    ps = shutil.which("pwsh") or shutil.which("powershell")
    if ps:
        adapters.append(("ps1", [ps, "-NoProfile", "-NonInteractive", "-File", os.path.join(PLUGIN, "adapter.ps1")]))
    else:
        print("no PowerShell here; adapter.ps1 not run")

    base = tempfile.mkdtemp(prefix="codex-by-dir-")
    sidecar = subprocess.Popen(["sleep", "120"])
    try:
        home = os.path.join(base, "home")
        work = os.path.join(base, "work")
        os.makedirs(work)
        day = os.path.join(home, ".codex", "sessions", "2026", "10", "18")
        os.makedirs(day)
        time.sleep(1.2)
        now = int(time.time() * 1000)

        # Another Codex in this directory, started two and a half minutes
        # before this one; this one's own record is not written yet.
        theirs = record(day, work, now - 150000, 1)
        for name, cmd in adapters:
            got = identify(cmd, home, work, sidecar.pid)
            check(name, got["session"] is None,
                  "the one record here is another Codex's and this one's is not written yet: none is named (%s)"
                  % got["notes"])

        # This one's first turn writes its record, started with its server.
        mine = record(day, work, now - 1000, 2)
        for name, cmd in adapters:
            got = identify(cmd, home, work, sidecar.pid)
            check(name, got["session"] == mine and got["session"] != theirs,
                  "its own record, written, is named and the other is not (%s)" % got["session"])

        # No start to match to: none, whatever the directory holds -- also
        # when it holds just one record.
        solo = os.path.join(base, "solo")
        os.makedirs(solo)
        record(day, solo, now - 150000, 3)
        for name, cmd in adapters:
            got = identify(cmd, home, solo, None)
            check(name, got["session"] is None,
                  "no sidecar to time and one record in the directory: none is named (%s)" % got["notes"])
            got = identify(cmd, home, work, None)
            check(name, got["session"] is None, "no sidecar to time and two records: none is named")
    finally:
        sidecar.kill()
        sidecar.wait()
        shutil.rmtree(base, ignore_errors=True)

    if failures:
        print("\n%d failed" % len(failures))
        return 1
    print("every case holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
