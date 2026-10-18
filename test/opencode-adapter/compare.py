#!/usr/bin/env python3
"""Do the opencode `adapter.py` and `adapter.ps1` give the same answers?

Task 1781. `plugins/opencode/adapter.ps1` is a port of `adapter.py`: the one
Polter runs on Windows and the one it runs everywhere else. So this feeds both
the same requests over the same files -- skills at several depths, two
configuration files, a JSONC one, and an opencode database -- and compares
what comes out, byte for byte. The database is read by `adapter.py` through
Python's `sqlite3` and by `adapter.ps1` through the system's SQLite library
(`winsqlite3.dll` on Windows, `libsqlite3` here), so the same answer from
both is also the PowerShell reader working.

A stand-in `opencode` on `PATH` answers `--version`.

    python3 test/opencode-adapter/compare.py              # from the repo root
    python3 test/opencode-adapter/compare.py --ps pwsh    # a specific PowerShell

Skips (exit 0, says so) with no PowerShell. Exit 0 when every request agrees,
1 otherwise.
"""

import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PLUGIN = os.path.join(ROOT, "plugins", "opencode")
POLTER = "/Applications/Polter.app/Contents/MacOS/polter"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def skill(path, name, description):
    write(os.path.join(path, "SKILL.md"), "---\nname: %s\ndescription: %s\n---\nbody\n" % (name, description))


def rig(base, version="1.2.10"):
    home, cwd, bin_dir = (os.path.join(base, d) for d in ("home", "proj 中", "bin"))
    skill(os.path.join(home, ".config", "opencode", "skills", "mine"), "mine", "Mine.")
    skill(os.path.join(home, ".config", "opencode", "skills", "deep", "nested"), "nested", "Foldedé.")
    write(os.path.join(home, ".config", "opencode", "skills", "nodesc", "SKILL.md"), "---\nname: nodesc\n---\n")
    skill(os.path.join(home, ".claude", "skills", "mine"), "mine", "The Claude Code copy.")
    skill(os.path.join(home, ".claude", "skills", "from-claude"), "from-claude", "Claude's.")
    skill(os.path.join(home, ".agents", "skills", "agents"), "agents", "Agents'.")
    skill(os.path.join(cwd, ".opencode", "skills", "theirs"), "theirs", "Theirs.")
    skill(os.path.join(cwd, ".claude", "skills", "mine"), "mine", "The project's.")
    write(os.path.join(home, ".config", "opencode", "opencode.json"), json.dumps({"mcp": {
        "polter": {"type": "local", "command": ["/x/polter", "+mcp"], "environment": {"SECRET": "hunter2"}},
        "chrome devtools": {"type": "local", "command": ["npx", "chrome-devtools-mcp"]},
        "off": {"type": "local", "command": ["x"], "enabled": False},
        "web": {"type": "remote", "url": "https://user:pw@mcp.example.com/sse"},
        "odd": "not an object"}}))
    write(os.path.join(home, ".config", "opencode", "config.json"), "{ not json")
    write(os.path.join(home, ".config", "opencode", "opencode.jsonc"), "{ // comments\n}")
    write(os.path.join(cwd, "opencode.json"), json.dumps({"mcp": {"shared": {"type": "local", "command": ["s"]}}}))
    write(os.path.join(bin_dir, "opencode"), "#!/bin/sh\n[ \"$1\" = --version ] && echo '%s'\nexit 0\n" % version)
    os.chmod(os.path.join(bin_dir, "opencode"), 0o755)
    now = int(time.time() * 1000)
    db = os.path.join(home, ".local", "share", "opencode", "opencode.db")
    os.makedirs(os.path.dirname(db), exist_ok=True)
    con = sqlite3.connect(db)
    con.execute("pragma journal_mode=wal")
    con.execute("create table session (id text primary key, project_id text, parent_id text, slug text, "
                "directory text, title text, version text, time_created integer, time_updated integer)")
    con.executemany("insert into session (id, project_id, parent_id, directory, time_created, time_updated) "
                    "values (?, 'p', ?, ?, ?, ?)",
                    [("ses_old", None, cwd, now - 86400000, now - 86000000),
                     ("ses_new", None, cwd, now, now + 5),
                     ("ses_child", "ses_new", cwd, now, now),
                     ("ses_elsewhere", None, "/else", now, now)])
    con.commit()
    # **Left open, as opencode leaves it**: a database in WAL mode is read
    # through its `-shm` and `-wal`, which are there while opencode runs. A
    # read-only reader cannot make them; with them gone, both readers say
    # they cannot read the sessions, which is the safe side.
    return home, cwd, bin_dir, con


def requests(home, cwd):
    base = {"version": 1, "home": home, "cwd": cwd}
    me = {"POLTER_AGENT_CLI": "opencode"}
    yield "inventory", "inventory", dict(base)
    yield "inventory, no directory", "inventory", dict(base, cwd=None)
    yield "launch, plain", "launch", dict(base, polter=POLTER, session=None, role={}, cli={})
    yield "launch, no polter", "launch", dict(base, polter=None, session=None, role={}, cli={})
    yield "launch, switches", "launch", dict(base, polter=POLTER, session=None,
                                             role={"model": "fake/m", "instructions": "Be \"careful\"\nand 中文."},
                                             cli={"skills": {"default": False}, "mcp": {"default": True, "except": ["mcp:chrome devtools"]}})
    yield "launch, own prompt", "launch", dict(base, polter=POLTER, session=None, role={"instructions": "x"},
                                               cli={"args": ["--prompt", "mine"]})
    yield "launch, resume", "launch", dict(base, polter=POLTER, session="ses_new", role={"instructions": "x"}, cli={})
    yield "launch, resume gone", "launch", dict(base, polter=POLTER, session="ses_gone", role={}, cli={})
    yield "launch, resume odd", "launch", dict(base, polter=POLTER, session="../x", role={}, cli={})
    yield "launch, resume not a string", "launch", dict(base, polter=POLTER, session=7, role={}, cli={})
    yield "launch, own session", "launch", dict(base, polter=POLTER, session="ses_new", role={}, cli={"args": ["-c"]})
    yield "identify, another CLI", "identify", dict(base, pid=os.getpid(), env={"POLTER_AGENT_CLI": "codex"})
    yield "identify, no marker", "identify", dict(base, pid=os.getpid(), env={})
    yield "identify, by pid", "identify", dict(base, pid=os.getpid(), env=me)
    yield "identify, by sidecar", "identify", dict(base, pid=None, sidecar_pid=os.getpid(), env=me)
    yield "identify, neither", "identify", dict(base, pid=None, env=me)
    yield "identify, no directory", "identify", dict(base, pid=os.getpid(), env=me, cwd=None)


def norm(out):
    try:
        answer = json.loads(out)
    except ValueError:
        return out
    notes = answer.get("notes")
    if isinstance(notes, list):
        answer["notes"] = [n.split(": ", 1)[0] + ": <reader's message>" if isinstance(n, str) and n.startswith("Could not read ")
                           else n for n in notes]
    return json.dumps(answer, ensure_ascii=False)


def run(argv, question, req, bin_dir, home):
    env = {"PATH": bin_dir + ":/usr/bin:/bin", "HOME": home}
    p = subprocess.run(argv + [question, json.dumps(req)], capture_output=True, text=True, timeout=120, env=env)
    return p.returncode, p.stdout, p.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ps", default=shutil.which("pwsh") or shutil.which("powershell"))
    a = ap.parse_args()
    if not a.ps:
        print("skip: no PowerShell here")
        return 0
    base = tempfile.mkdtemp(prefix="oc1781-")
    bad = 0
    try:
        home, cwd, bin_dir, writer = rig(base)
        py = [os.path.join(PLUGIN, "adapter.py")]
        ps = [a.ps, "-NoProfile", "-NonInteractive", "-File", os.path.join(PLUGIN, "adapter.ps1")]
        for label, question, req in requests(home, cwd):
            r1 = run(py, question, req, bin_dir, home)
            r2 = run(ps, question, req, bin_dir, home)
            # N1: the text after "Could not read <file>: " is the parser's
            # own message, Python's against .NET's.
            same = r1[0] == r2[0] and (r1[0] != 0 or norm(r1[1]) == norm(r2[1]))
            print("%s  %s" % ("ok  " if same else "DIFF", label))
            if not same:
                bad += 1
                print("      py  exit %d: %s%s" % (r1[0], r1[1].strip()[:1500], r1[2].strip()[-400:]))
                print("      ps1 exit %d: %s%s" % (r2[0], r2[1].strip()[:1500], r2[2].strip()[-400:]))
        # And what was compared is worth comparing: the database was read.
        r = run(py, "identify", dict(version=1, home=home, cwd=cwd, pid=os.getpid(), env={"POLTER_AGENT_CLI": "opencode"}),
                bin_dir, home)
        named = json.loads(r[1])["session"] == "ses_new"
        print("%s  the database was read (identify names ses_new)" % ("ok  " if named else "FAIL"))
        bad += 0 if named else 1
    finally:
        shutil.rmtree(base, ignore_errors=True)
    print("all agree" if not bad else "%d DIFFER" % bad)
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
