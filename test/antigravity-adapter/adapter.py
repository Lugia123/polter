#!/usr/bin/env python3
"""The Antigravity adapter's three answers, in a throwaway HOME.

Task 1682. Runs the shipped `plugins/antigravity/adapter.py` as Polter does --
the file itself, the request as its second argument -- against files written
here. No `agy` is run or needed.

    python3 test/antigravity-adapter/adapter.py

Exit 0 when every case holds.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ADAPTER = os.path.join(ROOT, "plugins", "antigravity", "adapter.py")
POLTER = "/Applications/Polter.app/Contents/MacOS/polter"
ROLES = os.path.join(ROOT, "src", "poltergeist", "roles")

failures = []


def check(case, ok, what):
    print("%s  %s: %s" % ("ok  " if ok else "FAIL", case, what))
    if not ok:
        failures.append("%s: %s" % (case, what))


def ask(question, req, home):
    # HOME too: the adapter looks for `~/.local/bin/agy` beside PATH.
    p = subprocess.run([ADAPTER, question, json.dumps(req)], capture_output=True, text=True, timeout=30,
                       env={"PATH": "/usr/bin:/bin", "HOME": home})
    if p.returncode != 0:
        raise SystemExit("adapter %s exited %d: %s" % (question, p.returncode, p.stderr))
    return json.loads(p.stdout)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def read_text(path):
    with open(path) as f:
        return f.read()


def skill(path, name, description):
    write(os.path.join(path, "SKILL.md"), "---\nname: %s\ndescription: %s\n---\n\nBody.\n" % (name, description))


def main():
    root = tempfile.mkdtemp(prefix="agy-adapter-")
    try:
        home = os.path.join(root, "home")
        cwd = os.path.join(root, "work")
        os.makedirs(cwd)
        g = os.path.join(home, ".gemini")
        skill(os.path.join(g, "config", "skills", "polter-supervising"), "polter-supervising", "mind terminals")
        skill(os.path.join(g, "config", "skills", "deploy"), "deploy", "the person's")
        # `name` is optional: the folder's name stands in.
        write(os.path.join(g, "config", "skills", "nameless", "SKILL.md"),
              "---\ndescription: no name\n---\n")
        skill(os.path.join(cwd, ".agents", "skills", "deploy"), "deploy", "the project's")
        # Gemini CLI's skills are not this CLI's.
        skill(os.path.join(g, "skills", "polter-old"), "polter-old", "Gemini CLI's")
        write(os.path.join(g, "config", "mcp_config.json"), json.dumps({"mcpServers": {
            "polter": {"command": POLTER, "args": ["+mcp"], "env": {"POLTER_AGENT_CLI": "antigravity"}},
            "argus": {"command": "/opt/bin/argus", "args": ["--token", "s3cret"], "env": {"KEY": "s3cret"}},
            "docs": {"serverUrl": "https://user:pw@mcp.example.com/x"},
            "off": {"command": "/x", "disabled": True},
        }}))

        inv = ask("inventory", {"version": 1, "cwd": cwd, "home": home}, home)
        ids = {i["id"]: i for i in inv["items"]}
        check("inventory", inv["installed"] is False, "no agy anywhere is not installed")
        check("inventory", inv.get("resume") is True, "resume is offered")
        check("inventory", set(ids) == {"skill:polter-supervising", "skill:deploy", "skill:nameless",
                                        "mcp:polter", "mcp:argus", "mcp:docs"},
              "the skills and servers it reads, and nothing of Gemini CLI's (%s)" % sorted(ids))
        check("inventory", ids["skill:deploy"]["source"] == "project", "the project's skill takes the shared id")
        check("inventory", ids["mcp:polter"]["locked"] is True and ids["mcp:argus"]["locked"] is False,
              "polter is locked, nothing else")
        text = json.dumps(inv)
        check("inventory", "s3cret" not in text and "pw@" not in text and "user:" not in text,
              "nothing secret in the answer")
        check("inventory", ids["mcp:docs"]["detail"] == "http · mcp.example.com"
              and ids["mcp:argus"]["detail"] == "stdio · argus", "a server is its transport and host or file")

        # agy where the installer puts it.
        write(os.path.join(home, ".local", "bin", "agy"), "#!/bin/sh\nexit 0\n")
        os.chmod(os.path.join(home, ".local", "bin", "agy"), 0o755)
        check("inventory", ask("inventory", {"version": 1, "cwd": None, "home": home}, home)["installed"] is True,
              "~/.local/bin/agy is installed")

        req = {"version": 1, "cwd": cwd, "home": home, "polter": POLTER, "session": None,
               "role": {"key": "w", "name": "W", "instructions": "Report with task_progress."},
               "cli": {"skills": {"default": True, "except": ["skill:polter-supervising", "skill:deploy"]},
                       "mcp": {"default": False, "except": []}, "model": "gemini-x-flash", "args": ["--effort", "low"]}}
        out = ask("launch", req, home)
        check("launch", out["argv"] == ["agy", "--model", "gemini-x-flash", "--effort", "low"],
              "agy, the model, then the role's own arguments (%s)" % out["argv"])
        notes = " ".join(out["notes"])
        # polter-supervising off (deploy is the project's and is kept); argus
        # and docs off (polter is locked).
        check("launch", "1 skill(s) and 2 MCP server(s)" in notes, "the note counts what was not switched off")
        check("launch", "instructions" in notes, "the instructions not passed are said")
        check("launch", "hooks" not in out, "no hooks file: no hooks claimed")

        plugin = os.path.join(g, "config", "plugins", "polter")
        write(os.path.join(plugin, "hooks.json"),
              json.dumps({"polter": {"Stop": [{"type": "command",
                                               "command": "'%s' +hook --cli antigravity Stop" % POLTER}]}}))
        check("launch", "hooks" not in ask("launch", req, home),
              "hooks in a directory with no plugin.json are not loaded, so not claimed")
        write(os.path.join(plugin, "plugin.json"), '{"name": "polter"}\n')
        out = ask("launch", req, home)
        check("launch", out.get("hooks") is True and out.get("hooks_heard") == "first_turn",
              "Polter's hooks for this Polter: hooks, heard from the first turn")
        other = dict(req, polter="/elsewhere/polter")
        check("launch", "hooks" not in ask("launch", other, home), "another Polter's hooks are not this one's")
        # The person switched the plugin off in Antigravity.
        config = os.path.join(g, "config", "config.json")
        write(config, json.dumps({"plugins": {"polter": {"enabled": False}, "x": {"enabled": True}}}))
        out = ask("launch", req, home)
        check("launch", "hooks" not in out and "switched off in Antigravity" in " ".join(out["notes"]),
              "a plugin switched off in Antigravity: no hooks claimed, and that is said")
        write(config, json.dumps({"plugins": {"polter": {"enabled": True}}}))
        check("launch", ask("launch", req, home).get("hooks") is True, "switched back on: hooks again")

        # Launch options, from `agy --help`: two lines of it as 1.4.0 prints them.
        check("options", ask("inventory", {"version": 1, "cwd": None, "home": home}, home)["options"] == [],
              "a help that says nothing offers nothing")
        # On stderr, where agy 1.4.2 writes it.
        write(os.path.join(home, ".local", "bin", "agy"), "#!/bin/sh\n[ \"$1\" = --help ] || exit 3\ncat >&2 <<'EOF'\n"
              "Usage of agy:\n"
              "  --mode                          Set the agent execution mode for this session (accept-edits, auto, plan)\n"
              "  --model                         Model for the current CLI session\nEOF\n")
        opts = ask("inventory", {"version": 1, "cwd": None, "home": home}, home)["options"]
        check("options", [o["key"] for o in opts] == ["mode"]
              and [v["value"] for v in opts[0]["values"]] == ["accept-edits", "auto", "plan"]
              and opts[0]["values"][1]["args"] == ["--mode", "auto"],
              "--mode is offered with the three values this agy lists (%s)" % opts)
        picked = dict(req, cli=dict(req["cli"], options={"mode": "auto"}))
        check("options", ask("launch", picked, home)["argv"] == ["agy", "--model", "gemini-x-flash", "--mode", "auto",
                                                                  "--effort", "low"],
              "a picked mode becomes its flag, before the role's own arguments")
        bad = ask("launch", dict(req, cli=dict(req["cli"], options={"mode": "yolo"})), home)
        check("options", "--mode" not in bad["argv"] and "not a value this version takes" in " ".join(bad["notes"]),
              "a value this agy does not list is left out, and said")
        twice = dict(req, cli=dict(req["cli"], options={"mode": "auto"}, args=["--mode=plan"]))
        out = ask("launch", twice, home)
        check("options", out["argv"].count("--mode") == 0 and "--mode=plan" in out["argv"]
              and "already give" in " ".join(out["notes"]),
              "a mode the extra arguments already give is theirs")
        # Not offered above, where the help has no line for it; 1.4.2's has.
        agy = os.path.join(home, ".local", "bin", "agy")
        no_skip = read_text(agy)
        write(agy, "#!/bin/sh\n[ \"$1\" = --help ] || exit 3\ncat >&2 <<'EOF'\n"
              "Usage of agy:\n"
              "  --dangerously-skip-permissions  Auto-approve all tool permission requests without prompting\n"
              "  --mode                          Set the agent execution mode for this session (accept-edits, auto, plan)\nEOF\n")
        opts = ask("inventory", {"version": 1, "cwd": None, "home": home}, home)["options"]
        skip = next((o for o in opts if o["key"] == "skip_permissions"), None)
        check("options", [o["key"] for o in opts] == ["mode", "skip_permissions"] and skip is not None
              and skip["values"] == [{"value": "skip-all", "args": ["--dangerously-skip-permissions"]},
                                     {"value": "ask", "args": []}]
              and skip.get("default") == "skip-all" and "shell" in skip["label"],
              "--dangerously-skip-permissions is offered on by default, with ask beside it, "
              "and its label says shell commands too (%s)" % opts)
        # The criterion (task 1682): a role that says nothing gets it; ask takes it out.
        check("options", ask("launch", req, home)["argv"] == ["agy", "--model", "gemini-x-flash",
                                                               "--dangerously-skip-permissions", "--effort", "low"],
              "a role that picks nothing starts agy with --dangerously-skip-permissions")
        off = dict(req, cli=dict(req["cli"], options={"skip_permissions": "ask"}))
        check("options", ask("launch", off, home)["argv"] == ["agy", "--model", "gemini-x-flash", "--effort", "low"],
              "skip_permissions=ask starts it without")
        given = ask("launch", dict(req, cli=dict(req["cli"], args=["--dangerously-skip-permissions"])), home)
        check("options", given["argv"].count("--dangerously-skip-permissions") == 1
              and not any("already give" in n for n in given["notes"]),
              "the role's own arguments giving it already: once, and no note about a default")
        both = dict(req, cli=dict(req["cli"], options={"mode": "plan"}))
        check("options", ask("launch", both, home)["argv"] == ["agy", "--model", "gemini-x-flash", "--mode", "plan",
                                                                "--dangerously-skip-permissions", "--effort", "low"],
              "a picked mode, and the default beside it")
        # Each official role that starts in Antigravity picks nothing, so gets it.
        for name in sorted(os.listdir(ROLES)):
            if not name.endswith(".json"):
                continue
            role = json.load(open(os.path.join(ROLES, name)))
            ag = (role.get("clis") or {}).get("antigravity")
            check("official", ag is not None, "%s starts in Antigravity" % role["key"])
            r = dict(req, role=dict(req.get("role") or {}, key=role["key"]), cli=dict(ag or {}))
            check("official", "--dangerously-skip-permissions" in ask("launch", r, home)["argv"],
                  "%s's agy is started with --dangerously-skip-permissions" % role["key"])
        write(agy, no_skip)

        # Resume: only a conversation whose record is on this machine.
        sid = "055a398f-db14-4c5f-abbb-1bf03f8120a7"
        out = ask("launch", dict(req, session=sid), home)
        check("resume", "--conversation" not in out["argv"] and "not on this machine" in " ".join(out["notes"]),
              "a conversation with no record here starts a new one, and that is said")
        record = os.path.join(g, "antigravity-cli", "conversations", sid + ".db")
        write(record, "")
        out = ask("launch", dict(req, session=sid), home)
        check("resume", out["argv"] == ["agy", "--model", "gemini-x-flash", "--conversation", sid, "--effort", "low"],
              "a conversation recorded here goes on, before the role's own arguments (%s)" % out["argv"])
        out = ask("launch", dict(req, session="../../etc/passwd"), home)
        check("resume", "--conversation" not in out["argv"] and "not an Antigravity conversation id" in " ".join(out["notes"]),
              "an id of the wrong shape is not passed on")
        for theirs in (["-c"], ["--continue"], ["--conversation", "x"], ["--conversation=x"]):
            out = ask("launch", dict(req, session=sid, cli=dict(req["cli"], args=theirs)), home)
            check("resume", out["argv"].count("--conversation") == theirs.count("--conversation")
                  and sid not in out["argv"] and "choose a conversation" in " ".join(out["notes"]),
                  "the role's own %s is left to choose" % theirs[0])
        out = ask("launch", req, home)
        check("resume", "--conversation" not in out["argv"], "no session asked, none passed")

        def who(env, pid=None):
            return ask("identify", {"version": 1, "cwd": cwd, "home": home, "pid": pid, "env": env}, home)

        me = who({"POLTER_AGENT_CLI": "antigravity", "POLTER_REGISTERED": "1"})
        check("identify", me["me"] is True and me["session"] is None and me["quit"] is None,
              "its own marker is it; holding no record, no session; no quit")
        # This process holds the record open, as agy would.
        with open(record, "rb"):
            me = who({"POLTER_AGENT_CLI": "antigravity"}, pid=os.getpid())
        check("identify", me["session"] == sid and isinstance(me["session_written_ms"], int),
              "the one record it holds open is its conversation (%s)" % me["session"])
        other = os.path.join(g, "antigravity-cli", "conversations", "6c0e8f43-1b5e-4c55-9a39-d9a0a6c3b0f1.db")
        write(other, "")
        with open(record, "rb"), open(other, "rb"):
            me = who({"POLTER_AGENT_CLI": "antigravity"}, pid=os.getpid())
        check("identify", me["session"] is None, "holding two, it cannot say which")
        check("identify", who({"POLTER_AGENT_CLI": "codex"}, pid=os.getpid())["me"] is False,
              "Codex's marker is not it")
        check("identify", who({"POLTER_REGISTERED": "1"}, pid=os.getpid())["me"] is False,
              "no marker and a parent that is not agy is not it")
    finally:
        shutil.rmtree(root, ignore_errors=True)

    print()
    if failures:
        print("%d failed" % len(failures))
        return 1
    print("every case holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
