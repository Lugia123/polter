#!/usr/bin/env python3
"""A rollout Codex is still writing is read, not refused (task 1749).

A running Codex keeps its own rollout open for writing. On Windows a reader
that does not share writing is refused, and `adapter.ps1` read the first line
with `StreamReader($Path)`: it threw "being used by another process" for the
very session a take-over is for, its catch swallowed that, and every live
Codex read as "its session was not found" (measured on codex 0.154, task 1749
round two). Every read of a rollout now goes through `Open-SharedRead`
(read access, sharing read and write).

Two halves:

  1. **The source, on every system.** In `plugins/codex/adapter.ps1`: no
     `StreamReader` is made from a path, nothing uses `OpenRead`,
     `Open-SharedRead` shares writing, and `Get-SessionMeta` reads through it.
     This is a text check -- it is the half that can redden off Windows.
  2. **A live writer, on Windows only.** The rollout is held open for
     appending by this process while `adapter.ps1 identify` names the session
     from it. ⚠️ Not run elsewhere, on purpose: .NET on macOS and Linux does
     not refuse a reader because another process writes (measured here with
     pwsh 7: a writer sharing only reading, and `StreamReader($Path)` still
     read), so this half is green there whatever the adapter does.

    python3 test/codex-adapter/shared-read.py

Exit 0 when every case that can run here holds.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ADAPTER = os.path.join(ROOT, "plugins", "codex", "adapter.ps1")

failures = []


def check(case, ok, what):
    print("%s  %s: %s" % ("ok  " if ok else "FAIL", case, what))
    if not ok:
        failures.append("%s: %s" % (case, what))


def function_body(src, name):
    """The text of PowerShell function `name`, up to the next function."""
    m = re.search(r"(?m)^function %s\b.*?(?=^function |\Z)" % re.escape(name), src, re.S)
    return m.group(0) if m else ""


def source():
    src = open(ADAPTER, encoding="ascii").read()
    # Code only: a comment may name what is not done.
    code = "\n".join(line for line in src.splitlines() if not line.lstrip().startswith("#"))
    check("source", not re.search(r"StreamReader\(\s*\$(Path|path|f|file)\b", code),
          "no StreamReader is made from a path (one from a stream is how Open-SharedRead reads)")
    check("source", "OpenRead(" not in code, "nothing opens a file with OpenRead, which does not share writing")
    shared = function_body(src, "Open-SharedRead")
    check("source", "FileShare]::ReadWrite" in shared and "FileAccess]::Read" in shared,
          "Open-SharedRead opens for reading and shares read and write")
    check("source", "Open-SharedRead" in function_body(src, "Get-SessionMeta"),
          "Get-SessionMeta, which reads every rollout, reads through Open-SharedRead")


def live():
    # SHARED_READ_LIVE=1 runs it anyway, to see that the script itself works.
    if os.name != "nt" and os.environ.get("SHARED_READ_LIVE") != "1":
        print("skip  live: not Windows -- .NET here does not refuse a reader because another process writes, "
              "so this half cannot tell the old adapter from the new one")
        return
    ps = shutil.which("powershell") or shutil.which("pwsh")
    if not ps:
        print("skip  live: no PowerShell")
        return
    base = tempfile.mkdtemp(prefix="codex-shared-read-")
    sidecar = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"])
    try:
        chome = os.path.join(base, "codex")
        work = os.path.join(base, "work")
        day = os.path.join(chome, "sessions", "2026", "10", "18")
        os.makedirs(day)
        os.makedirs(work)
        time.sleep(1.2)
        now = int(time.time() * 1000)
        h = "%012x" % now
        sid = "%s-%s-7000-8000-%012x" % (h[:8], h[8:], 1)
        iso = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now / 1000)) + ".%03dZ" % (now % 1000)
        path = os.path.join(day, "rollout-2026-10-18T06-00-00-%s.jsonl" % sid)
        with open(path, "w", encoding="utf-8") as f:
            f.write(json.dumps({"type": "session_meta", "payload": {"id": sid, "cwd": work, "timestamp": iso}}) + "\n")
        # Held open for writing, as a running Codex holds its own.
        writer = open(path, "a", encoding="utf-8")
        try:
            writer.write(json.dumps({"type": "event"}) + "\n")
            writer.flush()
            req = {"version": 1, "cwd": work, "home": base, "pid": None, "sidecar_pid": sidecar.pid,
                   "env": {"POLTER_AGENT_CLI": "codex"}}
            env = dict(os.environ, CODEX_HOME=chome)
            p = subprocess.run([ps, "-NoProfile", "-NonInteractive", "-File", ADAPTER, "identify", json.dumps(req)],
                               capture_output=True, text=True, encoding="utf-8", timeout=60, env=env)
            got = json.loads(p.stdout) if p.returncode == 0 else {}
            check("live", got.get("session") == sid,
                  "a rollout held open for writing is read and its session named (%s)" % got.get("notes"))
        finally:
            writer.close()
    finally:
        sidecar.kill()
        sidecar.wait()
        shutil.rmtree(base, ignore_errors=True)


def main():
    source()
    live()
    if failures:
        print("\n%d failed" % len(failures))
        return 1
    print("every case that can run here holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
