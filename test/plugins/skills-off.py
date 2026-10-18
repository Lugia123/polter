#!/usr/bin/env python3
"""`skills = no` takes back the skills Polter installed, and only those.

Task 1698. "no" used to mean "install nothing more": every `polter-*` skill
an earlier launch had written stayed in the host's skills directory, still
matched against what the user asked for. Switched off, the plugin now removes
what it can tell is its own -- by the same checks that prune a skill Polter no
longer ships: under the `polter-` prefix, a directory holding a single
`SKILL.md`, whose frontmatter names the directory.

Drives the shipped `claude-code` plugin through the real protocol (a greeting
line, then one `provision` batch), with a throwaway `HOME` and a stub `claude`
on `PATH`, under `/bin/sh` and, when a PowerShell is there, `provision.ps1`.
Cases:

- yes, then no: what yes installed goes, and so does an older skill of ours;
  a user's skill, a `polter-` directory somebody added a file to, and one
  whose frontmatter names something else all stay;
- never installed: no skills directory before, none after, nothing claimed;
- a directory of the user's own skills only: every one is still there;
- a value that is neither yes nor no removes nothing.

POSIX only (the stub `claude` is a shell script).

    python3 test/plugins/skills-off.py

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
KEY = "claude-code"

SOURCE = "---\nname: mine\nversion: 1\ndescription: a skill for the test\n---\n\nBody.\n"


def rig():
    base = tempfile.mkdtemp(prefix="p1698-")
    # Laid out the way the bundle lays it out: the plugin finds its library
    # by walking `../_sdk` from its own directory.
    for d in (KEY, "_sdk"):
        shutil.copytree(os.path.join(PLUGINS, d), os.path.join(base, d))
    os.makedirs(os.path.join(base, "home"))
    os.makedirs(os.path.join(base, "bin"))
    stub = os.path.join(base, "bin", "claude")
    with open(stub, "w") as f:
        f.write("#!/bin/sh\nexit 0\n")
    os.chmod(stub, 0o755)
    with open(os.path.join(base, "mine.md"), "w") as f:
        f.write(SOURCE)
    return base


def run(shell, base, skills):
    home = os.path.join(base, "home")
    # Compact, as the host writes it: `provision.sh` reads these with `sed`.
    hello = json.dumps({"hello": 1, "plugin": KEY, "cursor": 0, "events": ["provision"], "groups": "",
                        "calls": [], "params": {"scope": "user", "skills": skills}}, separators=(",", ":"))
    batch = json.dumps({"cursor": 0, "through": 1, "events": [{
        "n": 1, "kind": "provision", "at_ms": 1786819271275, "exe": "/nowhere/polter",
        "version": "1.2.3", "version_key": "POLTER_REGISTERED", "home": home,
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


def put(skills_dir, name, declared, extra=False):
    d = os.path.join(skills_dir, name)
    os.makedirs(d)
    with open(os.path.join(d, "SKILL.md"), "w") as f:
        f.write("---\nname: %s\n---\n\nSomebody's.\n" % declared)
    if extra:
        with open(os.path.join(d, "notes.md"), "w") as f:
            f.write("not ours\n")


def users_skills(skills_dir):
    os.makedirs(skills_dir, exist_ok=True)
    put(skills_dir, "their-skill", "their-skill")
    put(skills_dir, "polter-kept", "polter-kept", extra=True)
    put(skills_dir, "polter-alias", "someone-elses")


USERS = ("their-skill/SKILL.md", "polter-kept/SKILL.md", "polter-kept/notes.md", "polter-alias/SKILL.md")


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

    # yes, then no.
    base = rig()
    try:
        sd = os.path.join(base, "home", ".claude", "skills")
        users_skills(sd)
        ran, r1 = run(shell, base, "yes")
        installed = os.path.isfile(os.path.join(sd, "polter-mine", "SKILL.md"))
        verdict("yes installs polter-mine (the case below starts from it)", ran and installed,
                "ran=%s installed=%s" % (ran, installed), r1)
        # Put in after the yes pass, which would have pruned it as no longer
        # shipped: an older skill of ours, from a build without the stamp.
        put(sd, "polter-old", "polter-old")
        ran, r2 = run(shell, base, "no")
        mine_gone = not os.path.exists(os.path.join(sd, "polter-mine"))
        old_gone = not os.path.exists(os.path.join(sd, "polter-old"))
        kept = [p for p in USERS if not os.path.isfile(os.path.join(sd, p))]
        said = "because skills is set to no" in r2.stderr and "status=provisioned" in r2.stderr
        verdict("yes then no: ours go, the user's stay", ran and mine_gone and old_gone and not kept and said,
                "ran=%s polter-mine-gone=%s polter-old-gone=%s missing-user-files=%s said=%s"
                % (ran, mine_gone, old_gone, kept, said), r2)
    finally:
        shutil.rmtree(base, ignore_errors=True)

    # Never installed.
    base = rig()
    try:
        sd = os.path.join(base, "home", ".claude", "skills")
        ran, r = run(shell, base, "no")
        none = not os.path.exists(sd)
        # `status=provisioned` is not asked: the first launch registers the
        # MCP server, which is a write of its own.
        quiet = "removed" not in r.stderr
        verdict("never installed: nothing made, nothing claimed", ran and none and quiet,
                "ran=%s no-skills-dir=%s nothing-claimed=%s" % (ran, none, quiet), r)
    finally:
        shutil.rmtree(base, ignore_errors=True)

    # Only the user's own skills.
    base = rig()
    try:
        sd = os.path.join(base, "home", ".claude", "skills")
        users_skills(sd)
        ran, r = run(shell, base, "no")
        missing = [p for p in USERS if not os.path.isfile(os.path.join(sd, p))]
        quiet = "removed" not in r.stderr
        verdict("only the user's skills: every one stays", ran and not missing and quiet,
                "ran=%s missing=%s nothing-removed=%s" % (ran, missing, quiet), r)
    finally:
        shutil.rmtree(base, ignore_errors=True)

    # A value nobody recognises.
    base = rig()
    try:
        sd = os.path.join(base, "home", ".claude", "skills")
        run(shell, base, "yes")
        ran, r = run(shell, base, "maybe")
        stays = os.path.isfile(os.path.join(sd, "polter-mine", "SKILL.md"))
        verdict("an unknown value removes nothing", ran and stays, "ran=%s polter-mine-stays=%s" % (ran, stays), r)
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
