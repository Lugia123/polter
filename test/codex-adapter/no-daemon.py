#!/usr/bin/env python3
"""`--no-daemon` goes on a role's command line only when this Codex takes it.

Task 1712. Both adapters put `--no-daemon` on every launch, because Codex
0.163 runs a session in its shared app-server daemon otherwise (task 1667).
Codex 0.154 has no daemon and no such flag: it refused it as an unexpected
argument and exited, so a role -- and a resume, which carries the same flag --
never started on the Windows test machine.

Now the flag is passed when the CLI's own `--help` lists it, and left out with
a note when it does not or when the help cannot be read. For `adapter.py` and,
when a PowerShell is there, `adapter.ps1`, with a stand-in `codex` first on
`PATH`:

  * a 0.163 help (lists `--no-daemon`): new and resumed launches carry it,
    right after `codex` / `codex resume <id>`, and say nothing about it;
  * a 0.154 help (does not): neither carries it, and a note says why;
  * a help that cannot be read (the stand-in exits 1): neither carries it,
    and a note says the help could not be read;
  * and `codex --help` is started once per launch, not once per question.

POSIX only (the stand-in is a shell script).

    python3 test/codex-adapter/no-daemon.py      # from the repo root

Exit 0 when every case holds for every adapter that ran.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(os.path.dirname(os.path.dirname(HERE)), "plugins", "codex")
SESSION = "019a1468-a7f0-7a51-9c0e-1d2e3f405162"

# The parts that matter, as 0.163.0 prints them (read off `codex --help` on
# this Mac) ...
HELP_NEW = """\
Usage: codex [OPTIONS] [PROMPT]

Options:
  -s, --sandbox <SANDBOX_MODE>
          [possible values: read-only, workspace-write, danger-full-access]

      --no-alt-screen
          Disable alternate screen mode

      --no-daemon
          Run without the shared background server, even if it is already running

  -h, --help
          Print help (see a summary with '-h')
"""

# ... and the same help without the flag, as 0.154.0 has it: the Windows test
# machine's Codex suggested `--no-alt-screen` when handed `--no-daemon`.
HELP_OLD = HELP_NEW.replace(
    "      --no-daemon\n          Run without the shared background server, even if it is already running\n\n", "")

NOT_TAKEN = "This Codex does not take --no-daemon (its --help does not list it), so it was left out."
UNREAD = "Could not read codex --help, so --no-daemon was left out"


def stand_in(base, name, help_text):
    d = os.path.join(base, "bin-" + name)
    os.makedirs(d)
    log = os.path.join(base, "help-calls-" + name)
    with open(os.path.join(d, "codex"), "w") as f:
        if help_text is None:
            f.write("#!/bin/sh\necho x >> '%s'\nexit 1\n" % log)
        else:
            f.write("#!/bin/sh\nif [ \"$1\" = --help ]; then echo x >> '%s'; cat <<'POLTER_HELP'\n%sPOLTER_HELP\nexit 0\nfi\nexit 1\n"
                    % (log, help_text))
    os.chmod(os.path.join(d, "codex"), 0o755)
    return d, log


def ask(argv, env, req):
    p = subprocess.run(argv + ["launch", json.dumps(req)], capture_output=True, env=env, timeout=60)
    if p.returncode != 0:
        return None, p.stderr.decode("utf-8", "replace").strip()[-400:]
    return json.loads(p.stdout.decode("utf-8")), ""


def main():
    base = tempfile.mkdtemp(prefix="p1712-")
    ok = True
    try:
        home = os.path.join(base, "home")
        cwd = os.path.join(base, "cwd")
        os.makedirs(cwd)
        day = os.path.join(home, ".codex", "sessions", "2026", "10", "17")
        os.makedirs(day)
        with open(os.path.join(day, "rollout-2026-10-17T01-00-00-%s.jsonl" % SESSION), "w") as f:
            f.write('{"type":"session_meta","payload":{"session_id":"%s","cwd":"%s"}}\n' % (SESSION, cwd))

        adapters = [("py", [sys.executable, os.path.join(PLUGIN, "adapter.py")])]
        ps = shutil.which("pwsh") or shutil.which("powershell")
        if ps:
            adapters.append(("ps1", [ps, "-NoProfile", "-NonInteractive", "-File", os.path.join(PLUGIN, "adapter.ps1")]))
        else:
            print("no PowerShell here; adapter.ps1 not run")

        role = {"key": "r", "name": "r"}
        # A launch option too, so the options read `--help` as well and the
        # once-per-launch count is a count of something.
        cli = {"model": "m", "options": {"sandbox": "read-only"}}
        cases = [("0.163 help", HELP_NEW, True, None),
                 ("0.154 help", HELP_OLD, False, NOT_TAKEN),
                 ("unreadable help", None, False, UNREAD)]
        for label, argv in adapters:
            for name, text, wanted, note in cases:
                for session in (None, SESSION):
                    tag = "%s-%s-%s" % (label, name.split()[0], "resume" if session else "new")
                    bindir, log = stand_in(base, tag, text)
                    env = dict(os.environ, HOME=home, PATH=bindir + os.pathsep + os.environ.get("PATH", ""))
                    env.pop("CODEX_HOME", None)
                    req = {"version": 1, "cwd": cwd, "home": home, "polter": None,
                           "session": session, "role": role, "cli": cli}
                    answer, err = ask(argv, env, req)
                    what = "%-4s %-16s %s" % (label, name, "resume" if session else "new")
                    if answer is None:
                        print("FAIL  %s  (adapter failed: %s)" % (what, err))
                        ok = False
                        continue
                    av = answer["argv"]
                    notes = answer.get("notes") or []
                    head = ["codex", "resume", SESSION] if session else ["codex"]
                    started = av[:len(head)] == head
                    has = "--no-daemon" in av
                    placed = (av[len(head)] == "--no-daemon") if wanted else not has
                    said = [n for n in notes if "--no-daemon" in n]
                    said_ok = (said == []) if note is None else (len(said) == 1 and said[0].startswith(note))
                    calls = len(open(log).read().split()) if os.path.exists(log) else 0
                    good = started and placed and said_ok and calls == 1
                    print("%s  %s" % ("ok  " if good else "FAIL", what))
                    if not good:
                        ok = False
                        print("      argv=%s" % av)
                        print("      notes about it=%s  --help started %d time(s)" % (said, calls))
    finally:
        shutil.rmtree(base, ignore_errors=True)
    print("all hold" if ok else "SOME DO NOT HOLD")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
