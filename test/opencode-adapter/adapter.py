#!/usr/bin/env python3
"""The opencode adapter's three answers, in a throwaway HOME.

Task 1777. Runs the shipped `plugins/opencode/adapter.py` as Polter does --
the file itself, the request as its second argument -- against files written
here, with a stand-in `opencode` on `PATH` that only answers `--version`.
opencode's database is a stand-in too: a `session` table with the columns
the adapter reads, which are opencode 1.2.10's (read off a real one with
`sqlite3 -readonly`). `hooks-against-opencode.py` beside this file is the
other half: the same launch handed to a real opencode.

    python3 test/opencode-adapter/adapter.py

Exit 0 when every case holds.
"""

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ADAPTER = os.path.join(ROOT, "plugins", "opencode", "adapter.py")
HOOKS = os.path.join(ROOT, "plugins", "opencode", "polter-hooks.js")
POLTER = "/Applications/Polter.app/Contents/MacOS/polter"

failures = []


def check(case, ok, what):
    print("%s  %s: %s" % ("ok  " if ok else "FAIL", case, what))
    if not ok:
        failures.append("%s: %s" % (case, what))


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def skill(path, name, description="d"):
    write(os.path.join(path, "SKILL.md"), "---\nname: %s\ndescription: %s\n---\nbody\n" % (name, description))


class Rig:
    def __init__(self, version="1.2.10"):
        self.base = tempfile.mkdtemp(prefix="oc1777-")
        self.home = os.path.join(self.base, "home")
        self.cwd = os.path.join(self.base, "proj")
        self.bin = os.path.join(self.base, "bin")
        os.makedirs(self.cwd)
        os.makedirs(self.bin)
        self.version(version)

    def version(self, said):
        write(os.path.join(self.bin, "opencode"), "#!/bin/sh\n[ \"$1\" = --version ] && echo '%s'\nexit 0\n" % said)
        os.chmod(os.path.join(self.bin, "opencode"), 0o755)

    def ask(self, question, req):
        req = dict({"version": 1, "home": self.home, "cwd": self.cwd}, **req)
        p = subprocess.run([ADAPTER, question, json.dumps(req)], capture_output=True, text=True, timeout=30,
                           env={"PATH": self.bin + ":/usr/bin:/bin", "HOME": self.home})
        if p.returncode != 0:
            raise SystemExit("adapter %s exited %d: %s" % (question, p.returncode, p.stderr))
        return json.loads(p.stdout)

    def sessions(self, rows):
        path = os.path.join(self.home, ".local", "share", "opencode", "opencode.db")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        con = sqlite3.connect(path)
        con.execute("create table if not exists session (id text primary key, project_id text, parent_id text, "
                    "slug text, directory text, title text, version text, time_created integer, time_updated integer)")
        con.executemany("insert into session (id, project_id, parent_id, directory, time_created, time_updated) "
                        "values (?, 'p', ?, ?, ?, ?)", rows)
        con.commit()
        con.close()

    def close(self):
        shutil.rmtree(self.base, ignore_errors=True)


def config_of(answer):
    return json.loads(answer["env"]["OPENCODE_CONFIG_CONTENT"])


def main():
    # --- inventory ---------------------------------------------------------
    r = Rig()
    try:
        skill(os.path.join(r.home, ".config", "opencode", "skills", "mine"), "mine")
        skill(os.path.join(r.home, ".config", "opencode", "skills", "deep", "nested"), "nested")
        skill(os.path.join(r.home, ".claude", "skills", "from-claude"), "from-claude")
        skill(os.path.join(r.home, ".claude", "skills", "mine"), "mine", "the Claude Code copy")
        skill(os.path.join(r.cwd, ".opencode", "skills", "theirs"), "theirs")
        write(os.path.join(r.home, ".config", "opencode", "skills", "nodesc", "SKILL.md"), "---\nname: nodesc\n---\n")
        write(os.path.join(r.home, ".config", "opencode", "opencode.json"), json.dumps({"mcp": {
            "polter": {"type": "local", "command": ["/x/polter", "+mcp"], "environment": {"SECRET": "hunter2"}},
            "chrome-devtools": {"type": "local", "command": ["npx", "chrome-devtools-mcp"]},
            "off": {"type": "local", "command": ["x"], "enabled": False},
            "web": {"type": "remote", "url": "https://user:pw@mcp.example.com/sse"}}}))
        inv = r.ask("inventory", {})
        by = {i["id"]: i for i in inv["items"]}
        check("inventory", inv["installed"] and inv["resume"], "installed, and sessions can be gone on with")
        check("inventory", {"skill:mine", "skill:nested", "skill:from-claude", "skill:theirs"} <= set(by),
              "skills from opencode's directory at any depth, from ~/.claude/skills, and the project's")
        check("inventory", by["skill:mine"]["description"] == "d",
              "a skill in both places is opencode's own copy, the one it loads")
        check("inventory", "skill:nodesc" not in by, "a skill without a description is skipped, as opencode does")
        check("inventory", by["skill:theirs"]["source"] == "project", "the project's skill says so")
        check("inventory", by["mcp:polter"]["locked"] and "mcp:off" not in by,
              "Polter's server is locked; one switched off in the file is not listed")
        check("inventory", "hunter2" not in json.dumps(inv) and "pw@" not in json.dumps(inv),
              "nothing out of an environment table or a URL's credentials")
        check("inventory", by["mcp:web"]["detail"] == "http · mcp.example.com", "a remote server by its host")
    finally:
        r.close()

    # --- launch ------------------------------------------------------------
    r = Rig()
    try:
        skill(os.path.join(r.home, ".config", "opencode", "skills", "noisy"), "noisy")
        skill(os.path.join(r.cwd, ".opencode", "skills", "theirs"), "theirs")
        write(os.path.join(r.home, ".config", "opencode", "opencode.json"), json.dumps({"mcp": {
            "polter": {"type": "local", "command": ["/x/polter", "+mcp"]},
            "chrome-devtools": {"type": "local", "command": ["npx", "chrome-devtools-mcp"]}}}))

        plain = r.ask("launch", {"polter": POLTER, "session": None, "role": {}, "cli": {}})
        cfg = config_of(plain)
        check("launch", plain["argv"] == ["opencode"], "a role that says nothing starts plain opencode: %s" % plain["argv"])
        check("launch", plain.get("hooks") is True and plain.get("hooks_heard") == "first_turn",
              "with Polter's hooks, heard from its first turn")
        check("launch", plain["env"].get("POLTER_HOOK_EXE") == POLTER, "the plugin is told which Polter to run")
        check("launch", plain["env"].get("OPENCODE_DISABLE_AUTOUPDATE") == "1", "no upgrade under a role's feet")
        plug = cfg.get("plugin") or [""]
        check("launch", len(plug) == 1 and urllib.parse.unquote(plug[0]) == "file://" + HOOKS
              and os.path.isfile(HOOKS), "the plugin is the one beside the adapter, as a file:// URL: %s" % plug)
        check("launch", cfg.get("permission") == {"polter_*": "allow"},
              "Polter's tools are allowed and nothing is denied: %s" % cfg.get("permission"))

        role = r.ask("launch", {"polter": POLTER, "session": None, "role": {"model": "fake/m",
                                                                            "instructions": "You are a worker."},
                                "cli": {"skills": {"default": False}, "mcp": {"default": False}}})
        perm = config_of(role)["permission"]
        check("launch", perm.get("skill") == {"noisy": "deny"},
              "a skill switched off is denied by name, and the project's is left alone: %s" % perm)
        check("launch", perm.get("chrome-devtools_*") == "deny" and perm.get("polter_*") == "allow",
              "a server switched off has its tools denied; Polter's never are")
        check("launch", role["argv"] == ["opencode", "-m", "fake/m", "--prompt", "You are a worker."],
              "the model, and the instructions as the first prompt: %s" % role["argv"])
        check("launch", role["summary"] == "1 skill(s) and 1 MCP server(s) switched off", role["summary"])

        given = r.ask("launch", {"polter": POLTER, "session": None, "role": {"instructions": "x"},
                                 "cli": {"args": ["--prompt", "mine"]}})
        check("launch", given["argv"] == ["opencode", "--prompt", "mine"],
              "the role's own first prompt is kept, the instructions not added: %s" % given["argv"])

        none = r.ask("launch", {"polter": None, "session": None, "role": {}, "cli": {}})
        check("launch", "hooks" not in none and "plugin" not in config_of(none) and "POLTER_HOOK_EXE" not in none["env"],
              "no Polter path: no hooks, and no plugin loaded")

        r.version("1.2.9")
        old = r.ask("launch", {"polter": POLTER, "session": None, "role": {}, "cli": {}})
        check("launch", "hooks" not in old and "plugin" not in config_of(old)
              and any("older than 1.2.10" in n for n in old["notes"]), "an older opencode: no hooks, and a note")
        r.version("opencode, no version here")
        unread = r.ask("launch", {"polter": POLTER, "session": None, "role": {}, "cli": {}})
        check("launch", "hooks" not in unread and any("version" in n for n in unread["notes"]),
              "a version that cannot be read counts as too old")
        r.version("1.19.3")
        newer = r.ask("launch", {"polter": POLTER, "session": None, "role": {}, "cli": {}})
        check("launch", newer.get("hooks") is True, "a newer one has them")
    finally:
        r.close()

    # --- resume ------------------------------------------------------------
    r = Rig()
    try:
        now = int(time.time() * 1000)
        r.sessions([("ses_3742eb0bdffeurmQf36G8sg3vk", None, r.cwd, now - 60000, now - 1000)])
        on = r.ask("launch", {"polter": POLTER, "session": "ses_3742eb0bdffeurmQf36G8sg3vk",
                              "role": {"instructions": "x"}, "cli": {}})
        check("resume", on["argv"] == ["opencode", "-s", "ses_3742eb0bdffeurmQf36G8sg3vk"],
              "a session on this machine is gone on with, without the instructions again: %s" % on["argv"])
        gone = r.ask("launch", {"polter": POLTER, "session": "ses_notHere", "role": {}, "cli": {}})
        check("resume", gone["argv"] == ["opencode"] and any("not on this machine" in n for n in gone["notes"]),
              "one that is not here starts a new session, and says so")
        odd = r.ask("launch", {"polter": POLTER, "session": "../../x", "role": {}, "cli": {}})
        check("resume", odd["argv"] == ["opencode"] and any("not an opencode session id" in n for n in odd["notes"]),
              "something not shaped like an id is not passed on")
        mine = r.ask("launch", {"polter": POLTER, "session": "ses_3742eb0bdffeurmQf36G8sg3vk", "role": {},
                                "cli": {"args": ["-c"]}})
        check("resume", mine["argv"] == ["opencode", "-c"], "the role's own choice of session wins")
    finally:
        r.close()
    r = Rig()
    try:
        none = r.ask("launch", {"polter": POLTER, "session": "ses_3742eb0bdffeurmQf36G8sg3vk", "role": {}, "cli": {}})
        check("resume", none["argv"] == ["opencode"] and any("could not be read" in n for n in none["notes"]),
              "no database at all: a new session, and why")
    finally:
        r.close()

    # --- identify ----------------------------------------------------------
    r = Rig()
    try:
        # This test's own process stands in for opencode: it started a
        # moment ago, which is all `identify` asks of it.
        pid = os.getpid()
        now = int(time.time() * 1000)
        ask = lambda env: r.ask("identify", {"pid": pid, "env": env})
        check("identify", ask({"POLTER_AGENT_CLI": "codex"})["me"] is False, "another CLI's marker is a no")
        check("identify", ask({})["me"] is False, "no marker, and a parent that is not opencode: no")
        empty = ask({"POLTER_AGENT_CLI": "opencode"})
        check("identify", empty["me"] and empty["session"] is None and empty["quit"] is None,
              "the marker is a yes; no database, no session; no quit")
        r.sessions([("ses_old", None, r.cwd, now - 86400000, now - 86000000),
                    ("ses_child", "ses_new", r.cwd, now, now),
                    ("ses_elsewhere", None, "/somewhere/else", now, now),
                    ("ses_new", None, r.cwd, now, now + 5)])
        one = ask({"POLTER_AGENT_CLI": "opencode"})
        check("identify", one["session"] == "ses_new" and one["session_written_ms"] == now + 5,
              "this directory's one top-level session begun since it started: %s" % one["session"])
        r.sessions([("ses_second", None, r.cwd, now + 10, now + 10)])
        two = ask({"POLTER_AGENT_CLI": "opencode"})
        check("identify", two["session"] is None and any("which is this one is not known" in n for n in two["notes"]),
              "two of them: none is named")
    finally:
        r.close()

    print("all hold" if not failures else "%d DO NOT HOLD" % len(failures))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
