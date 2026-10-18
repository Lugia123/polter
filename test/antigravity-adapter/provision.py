#!/usr/bin/env python3
"""The Antigravity plugin's provision, run whole against a stand-in `agy`.

Task 1682. Runs the shipped `plugins/antigravity/provision.sh` with `/bin/sh`
the way Polter does -- a greeting, then one `provision` batch, an answer
read back for each -- in a throwaway HOME, with an `agy` on PATH that is a
two-line script and is never called. **No real `agy`, no account, no
network.** What it proves is what this repository writes into `~/.gemini`:
one plugin directory of Polter's, `~/.gemini/config/plugins/polter/`, and
nothing of the person's. That Antigravity loads it is measured separately
(`agy plugin list --json`, in the task's record).

    python3 test/antigravity-adapter/provision.py

Cases, each against a fresh HOME unless it says otherwise:

  1. A home with nothing in it: the manifest, the MCP entry (with the
     marker), Polter's hooks under `polter` with five events, the skill,
     the rules block -- all in the plugin directory -- and the status says
     something was written.
  2. Again, unchanged: the status does not say `provisioned` and not a
     byte of any of the five files moved.
  3. A home with the person's own global `mcp_config.json` and `hooks.json`,
     and the block the Gemini CLI plugin left in GEMINI.md: not a byte of
     any of them moves.
  4. `hooks=no`: Polter's entry goes; a file that held only Polter's goes
     with it.
  5. `hooks=no` with a `polter` hook entry that is not Polter's: kept.
  6. A Polter path with a space and a quote in it: each hook's command
     splits, the way a shell would, back into that path and `+hook`.
  7. No `agy` on PATH: `status=absent`, and `~/.gemini` is not made.
  8. `rules=no`: the rules file and its directory go; the manifest stays.
  9. approve_tools (off by default, so asked for): the script says yes to a call to Polter's server and to
     nothing else -- another server, a `ServerName` hidden in a call's own
     arguments, a shell command; `approve_tools=no` takes it and its hook out.

Exit 0 when every case holds.
"""

import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PLUGIN = os.path.join(ROOT, "plugins", "antigravity", "provision.sh")
EXE = "/Applications/Polter Test.app/Contents/MacOS/it's polter"
EVENTS = {"SessionStart", "PreInvocation", "PreToolUse", "PostToolUse", "Stop"}

failures = []


def check(case, ok, what):
    print("%s  %s: %s" % ("ok  " if ok else "FAIL", case, what))
    if not ok:
        failures.append("%s: %s" % (case, what))


def flat(obj):
    # The SDK reads the lines with `sed`, field by field: compact JSON.
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


def run(root, params, with_agy=True, version="1.2.3", exe=EXE):
    home = os.path.join(root, "home")
    os.makedirs(home, exist_ok=True)
    bindir = os.path.join(root, "bin")
    os.makedirs(bindir, exist_ok=True)
    agy = os.path.join(bindir, "agy")
    if with_agy:
        with open(agy, "w") as f:
            f.write("#!/bin/sh\necho 'the stand-in agy was called' >&2\nexit 9\n")
        os.chmod(agy, 0o755)
    elif os.path.exists(agy):
        os.remove(agy)
    skill = os.path.join(root, "mine.md")
    with open(skill, "w") as f:
        f.write("---\nname: mine\nversion: 1\ndescription: a skill for the test\n---\n\nBody.\n")

    hello = {"hello": 1, "plugin": "antigravity", "params": dict({"scope": "user", "skills": "yes"}, **params)}
    # The parameters flat beside each other, as the greeting carries them.
    line1 = flat(hello)
    batch = flat({"batch": 1, "events": [{"kind": "provision", "n": 1, "exe": exe, "version": version,
                                           "version_key": "POLTER_REGISTERED", "home": home,
                                           "skills": [{"name": "mine", "path": skill}]}]})
    env = {"PATH": bindir + ":/usr/bin:/bin", "HOME": home, "TMPDIR": root}
    p = subprocess.run(["/bin/sh", PLUGIN], input=line1 + "\n" + batch + "\n", env=env,
                       capture_output=True, text=True, timeout=60)
    acks = [l for l in p.stdout.splitlines() if l.startswith('{"ok"')]
    return home, p.stderr, acks


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def plugin_dir(home):
    return os.path.join(home, ".gemini", "config", "plugins", "polter")


def files(home):
    d = plugin_dir(home)
    return {
        "manifest": os.path.join(d, "plugin.json"),
        "mcp": os.path.join(d, "mcp_config.json"),
        "hooks": os.path.join(d, "hooks.json"),
        "skill": os.path.join(d, "skills", "polter-mine", "SKILL.md"),
        "rules": os.path.join(d, "rules", "AGENTS.md"),
        "approve": os.path.join(d, "approve.py"),
    }


def persons_files(home):
    """The person's own files: Antigravity's global ones, and Gemini CLI's."""
    g = os.path.join(home, ".gemini")
    return {
        "mcp": os.path.join(g, "config", "mcp_config.json"),
        "hooks": os.path.join(g, "config", "hooks.json"),
        "rules": os.path.join(g, "GEMINI.md"),
    }


def jload(data):
    """The JSON in `data` (what `read` gave), or None when there was no file --
    so a file that is missing fails its check instead of crashing the run."""
    return None if data is None else json.loads(data)


def fresh():
    return tempfile.mkdtemp(prefix="agy-prov-")


def main():
    roots = []
    try:
        # 1 and 2.
        root = fresh(); roots.append(root)
        home, err, acks = run(root, {})
        f = files(home)
        check("1", acks == ['{"ok":true}', '{"ok":true}'], "both lines answered yes (%s)" % acks)
        check("1", "status=provisioned" in err, "the status says something was written")
        check("1", "the stand-in agy was called" not in err, "agy itself was never run")
        check("1", jload(read(f["manifest"])) == {"name": "polter"}, "the manifest names the plugin")
        mcp = jload(read(f["mcp"])) or {}
        entry = (mcp.get("mcpServers") or {}).get("polter")
        check("1", entry == {"command": EXE, "args": ["+mcp"],
                             "env": {"POLTER_REGISTERED": "1.2.3", "POLTER_AGENT_CLI": "antigravity"}},
              "the MCP entry is the command, +mcp, the version and the marker")
        hooks = jload(read(f["hooks"])) or {}
        check("1", sorted(hooks) == ["polter"] and set(hooks.get("polter") or ()) == EVENTS,
              "hooks.json holds polter with %s" % sorted(EVENTS))
        check("1", read(f["skill"]) is not None and b"name: polter-mine" in read(f["skill"]),
              "the skill is there under its polter- name")
        check("1", read(f["rules"]) is not None and read(f["rules"]).count(b"BEGIN POLTER") == 1,
              "the plugin's rules file has one block")
        made = sorted(os.path.relpath(os.path.join(d, n), home)
                      for d, dirs, names in os.walk(os.path.join(home, ".gemini")) for n in names)
        check("1", read(f["approve"]) is None, "approve_tools is off unless asked for: no approve.py")
        check("1", made == sorted(os.path.relpath(v, home) for k, v in f.items() if k != "approve"),
              "nothing outside the plugin directory was made (%s)" % made)

        before = {k: read(v) for k, v in f.items()}
        home, err, acks = run(root, {})
        check("2", "status=provisioned" not in err and "status=unchanged" in err,
              "the second run says unchanged (%s)" % [l for l in err.splitlines() if "status=" in l])
        check("2", {k: read(v) for k, v in f.items()} == before, "not a byte of the five files moved")

        # 3.
        root = fresh(); roots.append(root)
        home = os.path.join(root, "home")
        t = persons_files(home)
        os.makedirs(os.path.dirname(t["mcp"]))
        with open(t["mcp"], "w") as h:
            json.dump({"mcpServers": {"argus": {"command": "/opt/argus", "env": {"TOKEN": "secret"}}},
                       "theirs": 1}, h)
        with open(t["hooks"], "w") as h:
            json.dump({"mine": {"Stop": [{"type": "command", "command": "./mine.sh"}]}}, h)
        with open(t["rules"], "w") as h:
            h.write("my notes\n\n<!-- BEGIN POLTER (managed -- rewritten by Polter; edit above or below) -->\n"
                    "an old block from the Gemini CLI plugin\n<!-- END POLTER -->\n\nmore notes\n")
        before = {k: read(v) for k, v in t.items()}
        home, err, acks = run(root, {})
        check("3", "status=provisioned" in err, "Polter's plugin was written")
        for k in t:
            check("3", read(t[k]) == before[k], "the person's %s did not move" % os.path.relpath(t[k], home))
        f = files(home)
        check("3", "polter" in ((jload(read(f["mcp"])) or {}).get("mcpServers") or {})
              and "argus" not in ((jload(read(f["mcp"])) or {}).get("mcpServers") or {}),
              "and nothing of theirs was copied into Polter's")

        # 4. The same home: hooks off.
        home, err, acks = run(root, {"hooks": "no", "approve_tools": "no"})
        check("4", read(f["hooks"]) is None, "Polter's hooks file is gone")
        check("4", "status=provisioned" in err, "taking it out is a write")
        check("4", read(t["hooks"]) == before["hooks"], "the person's global hooks.json did not move")
        root = fresh(); roots.append(root)
        home, _, _ = run(root, {})
        home, err, _ = run(root, {"hooks": "no", "approve_tools": "no"})
        check("4", read(files(home)["hooks"]) is None, "a hooks.json that held only Polter's is gone")
        home, err, _ = run(root, {"hooks": "no", "approve_tools": "no"})
        check("4", "status=unchanged" in err, "and with nothing to take out, nothing is written")

        # 5.
        root = fresh(); roots.append(root)
        home = os.path.join(root, "home")
        f = files(home)
        os.makedirs(os.path.dirname(f["hooks"]))
        theirs = {"polter": {"Stop": [{"type": "command", "command": "/usr/local/bin/notify"}]}}
        with open(f["hooks"], "w") as h:
            json.dump(theirs, h)
        run(root, {"hooks": "no", "approve_tools": "no"})
        got = read(f["hooks"])
        check("5", got is not None and json.loads(got) == theirs, "a polter entry that is not Polter's is kept")

        # 6. Case 1's home was written with a path holding a space and a quote.
        hooks = jload(read(files(os.path.join(roots[0], "home"))["hooks"]))["polter"]
        commands = [hooks[e][0]["command"] for e in ("SessionStart", "PreInvocation", "Stop")]
        commands += [hooks[e][0]["hooks"][0]["command"] for e in ("PreToolUse", "PostToolUse")]
        split = [shlex.split(c) for c in commands]
        check("6", all(s[:4] == [EXE, "+hook", "--cli", "antigravity"] and len(s) == 5 for s in split),
              "every command splits back into the path, +hook --cli antigravity and its event")
        check("6", sorted(s[4] for s in split) == sorted(EVENTS), "each event names itself")
        check("6", all(h[0].get("timeout") == 3 for h in hooks.values() if "type" in h[0])
              and all(h[0]["matcher"] == "*" for h in (hooks["PreToolUse"], hooks["PostToolUse"])),
              "a 3 s timeout, and the tool events match every tool")

        # 7.
        root = fresh(); roots.append(root)
        home, err, acks = run(root, {}, with_agy=False)
        check("7", "status=absent" in err, "no agy is said as absent")
        check("7", not os.path.exists(os.path.join(home, ".gemini")), "and ~/.gemini is not made")

        # 8.
        root = fresh(); roots.append(root)
        home, _, _ = run(root, {})
        f = files(home)
        home, err, _ = run(root, {"rules": "no"})
        check("8", read(f["rules"]) is None and not os.path.exists(os.path.dirname(f["rules"])),
              "the rules file and its directory are gone")
        check("8", read(f["manifest"]) is not None and read(f["mcp"]) is not None, "the rest of the plugin stays")
        check("8", "status=provisioned" in err, "taking it out is a write")

        # 9. (approve_tools is off by default: asked for here.)
        root = fresh(); roots.append(root)
        home, _, _ = run(root, {"approve_tools": "yes"})
        f = files(home)
        hook = (jload(read(f["hooks"])) or {}).get("polter-approve") or {}
        group = (hook.get("PreToolUse") or [{}])[0]
        # Every tool: `call_mcp_tool` as a matcher was measured never to run it
        # for an MCP call. The script tells MCP calls from the rest (below).
        check("9", group.get("matcher") == "*", "the hook sees every tool call")
        cmd = shlex.split(group.get("hooks", [{}])[0].get("command", "x"))
        def answer(payload):
            r = subprocess.run(cmd, input=json.dumps(payload), capture_output=True, text=True, timeout=30)
            return r.returncode, r.stdout
        polter = {"toolCall": {"name": "call_mcp_tool", "args": {"ServerName": "polter_polter", "ToolName": "me", "Arguments": {}}}}
        check("9", answer(polter) == (0, '{"decision": "allow"}'), "a call to Polter's server is allowed (%s)" % (answer(polter),))
        other = {"toolCall": {"name": "call_mcp_tool", "args": {"ServerName": "github_github", "ToolName": "push"}}}
        check("9", answer(other) == (0, ""), "another server's is left to agy")
        hidden = {"toolCall": {"name": "call_mcp_tool", "args": {"ServerName": "evil_evil", "Arguments": {"ServerName": "polter_polter"}}}}
        check("9", answer(hidden) == (0, ""), "a ServerName inside the call's own arguments is not the server")
        shell = {"toolCall": {"name": "run_command", "args": {"CommandLine": "rm -rf /", "ServerName": "polter_polter"}}}
        check("9", answer(shell) == (0, ""), "a tool that is not an MCP call is not allowed")
        bad = subprocess.run(cmd, input="not json", capture_output=True, text=True, timeout=30)
        check("9", (bad.returncode, bad.stdout) == (0, ""), "a payload that does not parse is no opinion")
        home, err, _ = run(root, {"approve_tools": "no"})
        hooks = jload(read(f["hooks"])) or {}
        check("9", "polter-approve" not in hooks and "polter" in hooks and read(f["approve"]) is None,
              "approve_tools=no takes the hook and the script out, and leaves Polter's other hooks")
    finally:
        for r in roots:
            shutil.rmtree(r, ignore_errors=True)

    print()
    if failures:
        print("%d failed" % len(failures))
        return 1
    print("every case holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
