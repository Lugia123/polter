#!/usr/bin/env python3
"""The `opencode` plugin's three answers: who started the server, where the
skills go, and which rules file is written.

Tasks 1777, 1806. Drives the shipped `opencode` plugin through the real protocol (a
greeting line, then one `provision` batch), with a throwaway `HOME` and a stub
`opencode` on `PATH`, under `/bin/sh` and, when a PowerShell is there,
`provision.ps1`. Cases:

- a fresh home: the `polter` entry's `environment` names `opencode`
  (`POLTER_AGENT_CLI`), the skill lands in `~/.config/opencode/skills`, and
  `~/.config/opencode/AGENTS.md` is made with the block;
- the same build again writes nothing;
- an entry this build wrote before it carried the marker is written again;
- a `~/.claude/CLAUDE.md` and no opencode `AGENTS.md`: the `AGENTS.md` is
  made all the same -- opencode 2.0 reads no `CLAUDE.md`, so it hides nothing
  (1.x read the first of the two, which is why this used to be "none made")
  -- and `CLAUDE.md` is not touched;
- Polter's skills already under `~/.claude/skills`, which opencode reads too:
  none go into opencode's own directory, the copies an earlier launch put
  there are taken back, and a skill of the person's there is left;
- both there: the block goes into `AGENTS.md`, what the person wrote there
  stays, `CLAUDE.md` is not touched;
- rules = no after yes: the block comes back out, the rest of the file stays.

POSIX only (the stub `opencode` is a shell script).

    python3 test/plugins/opencode-provision.py

Exit 0 when every case holds for every shell that ran.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGINS = os.path.join(os.path.dirname(os.path.dirname(HERE)), "plugins")
KEY = "opencode"

SOURCE = "---\nname: mine\nversion: 1\ndescription: a skill for the test\n---\n\nBody.\n"
BEGIN = "<!-- BEGIN POLTER (managed"
END = "<!-- END POLTER -->"


def rig():
    base = tempfile.mkdtemp(prefix="p1777-")
    # Laid out the way the bundle lays it out: the plugin finds its library
    # by walking `../_sdk` from its own directory.
    for d in (KEY, "_sdk"):
        shutil.copytree(os.path.join(PLUGINS, d), os.path.join(base, d))
    os.makedirs(os.path.join(base, "home"))
    os.makedirs(os.path.join(base, "bin"))
    stub = os.path.join(base, "bin", "opencode")
    with open(stub, "w") as f:
        f.write("#!/bin/sh\nexit 0\n")
    os.chmod(stub, 0o755)
    with open(os.path.join(base, "mine.md"), "w") as f:
        f.write(SOURCE)
    return base


def run(shell, base, rules="yes", version="1.2.3"):
    home = os.path.join(base, "home")
    # Compact, as the host writes it: `provision.sh` reads these with `sed`.
    hello = json.dumps({"hello": 1, "plugin": KEY, "cursor": 0, "events": ["provision"], "groups": "",
                        "calls": [], "params": {"skills": "yes", "rules": rules}}, separators=(",", ":"))
    batch = json.dumps({"cursor": 0, "through": 1, "events": [{
        "n": 1, "kind": "provision", "at_ms": 1786819271275, "exe": "/nowhere/polter",
        "version": version, "version_key": "POLTER_REGISTERED", "home": home,
        "skills": [{"name": "mine", "path": os.path.join(base, "mine.md")}]}]}, separators=(",", ":"))
    if shell == "sh":
        argv = ["/bin/sh", os.path.join(base, KEY, "provision.sh")]
    else:
        argv = [shell, "-NoProfile", "-NonInteractive", "-File", os.path.join(base, KEY, "provision.ps1")]
    env = dict(os.environ, HOME=home, PATH=os.path.join(base, "bin") + ":/usr/bin:/bin:/opt/homebrew/bin")
    r = subprocess.run(argv, input=hello + "\n" + batch + "\n", env=env,
                       capture_output=True, text=True, timeout=60)
    acks = [l.replace(" ", "") for l in r.stdout.splitlines() if '"ok"' in l]
    ok = r.returncode == 0 and acks == ['{"ok":true}'] * 2
    return ok, r


def path(base, *rel):
    return os.path.join(base, "home", *rel)


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def write(p, text):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)


def entry(base):
    d = json.loads(read(path(base, ".config", "opencode", "opencode.json")))
    return d["mcp"]["polter"]


def check(label, shell):
    ok = True

    def verdict(name, good, detail, r=None):
        nonlocal ok
        print("%s  %-4s %s" % ("ok  " if good else "FAIL", label, name))
        if not good:
            ok = False
            print("      " + detail)
            if r is not None:
                print("      exit %d, stderr: %s" % (r.returncode, r.stderr.strip()[-600:]))

    agents = (".config", "opencode", "AGENTS.md")
    claude = (".claude", "CLAUDE.md")

    # A fresh home, then the same build again.
    base = rig()
    try:
        ran, r = run(shell, base)
        e = entry(base) if ran else {}
        env = e.get("environment", {})
        marked = env.get("POLTER_AGENT_CLI") == "opencode" and env.get("POLTER_REGISTERED") == "1.2.3"
        verdict("fresh: the entry says opencode, beside the version", ran and marked,
                "ran=%s environment=%s" % (ran, env), r)
        skill = os.path.isfile(path(base, ".config", "opencode", "skills", "polter-mine", "SKILL.md"))
        verdict("fresh: the skill is in ~/.config/opencode/skills", skill, "polter-mine missing", r)
        block = os.path.isfile(path(base, *agents)) and BEGIN in read(path(base, *agents))
        verdict("fresh, no CLAUDE.md: AGENTS.md is made with the block", block, "no block in AGENTS.md", r)

        ran, r = run(shell, base)
        quiet = ran and "status=provisioned" not in r.stderr
        verdict("the same build again writes nothing", quiet, "ran=%s" % ran, r)
    finally:
        shutil.rmtree(base, ignore_errors=True)

    # An entry this build wrote before it carried the marker.
    base = rig()
    try:
        write(path(base, ".config", "opencode", "opencode.json"), json.dumps({"mcp": {"polter": {
            "type": "local", "command": ["/nowhere/polter", "+mcp"], "enabled": True,
            "environment": {"POLTER_REGISTERED": "1.2.3"}}}}))
        ran, r = run(shell, base)
        again = ran and entry(base)["environment"].get("POLTER_AGENT_CLI") == "opencode"
        verdict("an entry without the marker is written again", again,
                "ran=%s environment=%s" % (ran, entry(base).get("environment")), r)
    finally:
        shutil.rmtree(base, ignore_errors=True)

    # CLAUDE.md there, no AGENTS.md of opencode's.
    base = rig()
    try:
        mine = "# mine\n\nThe person's own words.\n"
        write(path(base, *claude), mine)
        ran, r = run(shell, base)
        made = os.path.isfile(path(base, *agents)) and BEGIN in read(path(base, *agents))
        same = read(path(base, *claude)) == mine
        verdict("CLAUDE.md and no AGENTS.md: AGENTS.md is made with the block, CLAUDE.md untouched",
                ran and made and same, "ran=%s agents-block=%s claude-unchanged=%s" % (ran, made, same), r)
    finally:
        shutil.rmtree(base, ignore_errors=True)

    # Polter's skills under ~/.claude/skills (the Claude Code plugin's), one
    # copy of ours left in opencode's directory by an earlier launch, and a
    # skill of the person's beside it.
    base = rig()
    try:
        own = path(base, ".config", "opencode", "skills")
        write(path(base, ".claude", "skills", "polter-mine", "SKILL.md"),
              "---\nname: polter-mine\ndescription: the Claude Code plugin's copy\n---\n")
        write(os.path.join(own, "polter-mine", "SKILL.md"), "---\nname: polter-mine\ndescription: ours, from before\n---\n")
        write(os.path.join(own, "theirs", "SKILL.md"), "---\nname: theirs\ndescription: the person's\n---\n")
        ran, r = run(shell, base)
        gone = not os.path.exists(os.path.join(own, "polter-mine"))
        kept = os.path.isfile(os.path.join(own, "theirs", "SKILL.md")) and \
            os.path.isfile(path(base, ".claude", "skills", "polter-mine", "SKILL.md"))
        said = "skills=shared" in r.stderr
        verdict("skills under ~/.claude/skills: none in opencode's, ours taken back, the person's and Claude's kept",
                ran and gone and kept and said,
                "ran=%s ours-gone=%s others-kept=%s said-shared=%s" % (ran, gone, kept, said), r)
    finally:
        shutil.rmtree(base, ignore_errors=True)

    # Both there, then rules = no.
    base = rig()
    try:
        mine = "# mine\n\nThe person's own words.\n"
        write(path(base, *claude), mine)
        theirs = "# opencode rules\n\nKeep this.\n"
        write(path(base, *agents), theirs)
        ran, r = run(shell, base)
        text = read(path(base, *agents))
        both = ran and text.startswith(theirs) and BEGIN in text and END in text
        same = read(path(base, *claude)) == mine
        verdict("both there: the block goes into AGENTS.md after theirs, CLAUDE.md untouched", both and same,
                "ran=%s agents=%r claude-unchanged=%s" % (ran, text[:200], same), r)

        ran, r = run(shell, base, rules="no")
        text = read(path(base, *agents))
        gone = ran and BEGIN not in text and text.startswith(theirs.rstrip("\n"))
        verdict("rules = no: the block comes out, theirs stays", gone, "ran=%s agents=%r" % (ran, text[:200]), r)
    finally:
        shutil.rmtree(base, ignore_errors=True)

    return ok


def main():
    ok = check("sh", "sh")
    ps = shutil.which("pwsh") or shutil.which("powershell")
    if ps:
        ok = check("ps1", ps) and ok
    else:
        print("no PowerShell here; provision.ps1 not run")
    print("all hold" if ok else "SOME DO NOT HOLD")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
