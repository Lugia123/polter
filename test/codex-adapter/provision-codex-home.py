#!/usr/bin/env python3
"""Every path the Codex plugin writes follows `CODEX_HOME`, as Codex does.

Task 1707. `config.toml` was found through `$CODEX_HOME` (else `~/.codex`),
but the skills directory and the rules file (`AGENTS.md`) were built from the
home directory alone. With `CODEX_HOME` set, Polter wrote its `polter-*`
skills and its rules block into the person's own `~/.codex`, and the Codex
that ran -- which reads `$CODEX_HOME/skills` and `$CODEX_HOME/AGENTS.md` --
never saw them.

For each shell, with a throwaway home and once with `CODEX_HOME` set and once
without:

- `config.toml`, the skills directory and the rules file all sit under the
  directory Codex uses (`$CODEX_HOME`, else `<home>/.codex`);
- the rules step writes its block there and nowhere else -- the other
  candidate directory is not even created -- and switched off it takes the
  block back out of the same file (the removal path), the person's own lines
  kept.

Runs the shipped `plugins/codex/provision.sh` (with `/bin/sh`) and, when a
PowerShell is there, `provision.ps1`, each loaded with
`POLTER_PROVISION_FUNCTIONS_ONLY=1` so that only these steps are called.

    python3 test/codex-adapter/provision-codex-home.py

Exit 0 when every case holds for every shell that ran.
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(os.path.dirname(os.path.dirname(HERE)), "plugins", "codex")
BEGIN = "<!-- BEGIN POLTER (managed"
THEIRS = "# my own notes\n"


def env_for(home, chome):
    env = dict(os.environ, POLTER_PROVISION_FUNCTIONS_ONLY="1", HOME=home)
    env.pop("CODEX_HOME", None)
    if chome is not None:
        env["CODEX_HOME"] = chome
    return env


def sh_run(home, chome, want_rules):
    script = (
        'h="$1"; set -- ; . "$0"; home="$h"; wrote=no; POLTER_WANT_RULES=' + want_rules + '; '
        'printf "config=%s\\n" "$(codex_config)"; '
        'printf "skills=%s\\n" "$(host_skills_dir)"; '
        'printf "rules=%s\\n" "$(host_rules_file)"; '
        'polter_rules_apply || exit 9'
    )
    return subprocess.run(["/bin/sh", "-c", script, os.path.join(PLUGIN, "provision.sh"), home],
                          env=env_for(home, chome), capture_output=True, text=True, timeout=30)


def ps_run(ps, home, chome, want_rules):
    command = (
        ". '" + os.path.join(PLUGIN, "provision.ps1") + "'; "
        "$script:PolterHome = '" + home + "'; "
        "$script:PolterWantRules = '" + want_rules + "'; "
        "'config=' + (Get-CodexConfig); "
        "'skills=' + (Get-HostSkillsDir); "
        "'rules=' + (Get-HostRulesFile); "
        "if (-not (Set-PolterRules)) { exit 9 }"
    )
    return subprocess.run([ps, "-NoProfile", "-NonInteractive", "-Command", command],
                          env=env_for(home, chome), capture_output=True, text=True, timeout=60)


def paths_of(out):
    got = {}
    for line in out.splitlines():
        key, sep, value = line.partition("=")
        if sep and key in ("config", "skills", "rules"):
            got[key] = os.path.normpath(value.strip())
    return got


def check(label, run):
    ok = True
    for name, isolated in (("CODEX_HOME set", True), ("CODEX_HOME not set", False)):
        base = tempfile.mkdtemp(prefix="p1707-")
        try:
            home = os.path.join(base, "home")
            os.makedirs(home)
            chome = os.path.join(base, "codexhome") if isolated else None
            used = chome if isolated else os.path.join(home, ".codex")
            other = os.path.join(home, ".codex") if isolated else os.path.join(base, "codexhome")
            os.makedirs(used)
            rules = os.path.join(used, "AGENTS.md")
            with open(rules, "w") as f:
                f.write(THEIRS)

            r1 = run(home, chome, "yes")
            got = paths_of(r1.stdout)
            want = {
                "config": os.path.join(used, "config.toml"),
                "skills": os.path.join(used, "skills"),
                "rules": rules,
            }
            on = open(rules).read()
            r2 = run(home, chome, "no")
            back = open(rules).read()

            good_paths = got == want
            good_on = r1.returncode == 0 and BEGIN in on and on.startswith(THEIRS)
            good_other = not os.path.exists(other)
            # The block comes back out of the same file. Not byte for byte: the
            # SDK's removal leaves the blank line it put in front of the
            # block, in both shells -- older than this task and not its subject.
            good_back = r2.returncode == 0 and BEGIN not in back and back.rstrip("\n") == THEIRS.rstrip("\n")
            good = good_paths and good_on and good_other and good_back
            print("%s  %-4s %s" % ("ok  " if good else "FAIL", label, name))
            if not good:
                ok = False
                print("      paths=%s rules-written-there=%s other-untouched=%s removed-again=%s"
                      % (good_paths, good_on, good_other, good_back))
                for k in want:
                    if got.get(k) != want[k]:
                        print("      %s: got %s, want %s" % (k, got.get(k), want[k]))
                for r in (r1, r2):
                    if r.returncode != 0:
                        print("      exit %d: %s" % (r.returncode, (r.stderr or r.stdout).strip()[-300:]))
                if not good_back:
                    print("      before=%r\n      back  =%r" % (THEIRS, back))
        finally:
            shutil.rmtree(base, ignore_errors=True)
    return ok


def main():
    ok = check("sh", sh_run)
    ps = shutil.which("pwsh") or shutil.which("powershell")
    if ps:
        ok = check("ps1", lambda home, chome, want: ps_run(ps, home, chome, want)) and ok
    else:
        print("no PowerShell here; provision.ps1 not run")
    print("all hold" if ok else "SOME DO NOT HOLD")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
