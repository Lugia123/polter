#!/usr/bin/env python3
"""Do the Codex `adapter.py` and `adapter.ps1` give the same answers?

`plugins/codex/adapter.ps1` is a port of `adapter.py`: the one Polter runs on
Windows and the one it runs everywhere else. A difference between them is a
role that behaves one way on a Mac and another on Windows. So this feeds both
the same requests over the same files and compares what comes out -- the
exit code always, and the answer byte for byte when both succeed, after the
normalisation below and nothing else. It is `test/claude-code-adapter/` for
the second adapter, smaller, with its fixtures in this file.

    python3 test/codex-adapter/compare.py              # from the repo root
    python3 test/codex-adapter/compare.py --ps pwsh    # a specific PowerShell

What is normalised, and why each may differ:

  N1. **`argv[0]` on Windows.** `adapter.py` answers `codex`; `adapter.ps1`
      the program behind npm's `codex.cmd` -- `node.exe` and Codex's
      `codex.js`, or a `codex.exe` -- because a role's instructions must not
      go through `cmd.exe`. The shape is checked, then replaced by `codex`.
  N2. **`installed` on Windows**, where `adapter.py` looks for a file named
      exactly `codex`. Printed, not compared.
  N3. **The text after "Could not read <file>: "** in a note: the reader's
      own error message (Python's against .NET's).

`identify` against a live process is compared only off Windows, where the
pid exists: a stand-in program called `codex` (a copy of `/bin/sh`) holds a
rollout open, as the real one was measured to.

Exit: 0 when every request agrees, 1 otherwise.
"""

import argparse
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
ON_WINDOWS = os.name == "nt"
SESSION = "01a14638-8e88-7993-b863-bd9d4c1a0ba8"

FILES = {
    "HOME/.codex/config.toml": (
        'model = "gpt-5.6-luna"\n'
        'developer_instructions = "mine"\n'
        "# a comment\n"
        "[mcp_servers.polter]\n"
        'command = "/Applications/Polter.app/Contents/MacOS/polter"\n'
        'args = ["+mcp"]\n'
        "[mcp_servers.polter.env]\n"
        'POLTER_AGENT_CLI = "codex"\n'
        "[mcp_servers.pencil]\n"
        'command = "/opt/pencil/bin/pencil-mcp"\n'
        'args = ["--api-key", "hunter2"]\n'
        '[mcp_servers."docs"]\n'
        'url = "https://user:pw@docs.example.com/mcp"\n'
        "[mcp_servers.gone]\n"
        'command = "/bin/gone"\n'
        "enabled = false\n"
        "[mcp_servers.has.dot]\n"
        "command = 'C:\\tools\\x.exe'\n"
        "[[profiles]]\n"
        'name = "x"\n'
        "[broken\n"
    ),
    "HOME/.codex/skills/pdf/SKILL.md": "---\nname: pdf\ndescription: Mine.\n---\n",
    "HOME/.codex/skills/folded/SKILL.md": "---\nname: folded\ndescription: >\n  One line\n  and another.\n---\n",
    "HOME/.codex/skills/.system/imagegen/SKILL.md": "---\nname: imagegen\ndescription: \"Images.\"\n---\n",
    "HOME/.agents/skills/writer/SKILL.md": "---\nname: writer\ndescription: Write \u00e9.\n---\n",
    "HOME/.agents/skills/noname/SKILL.md": "---\ndescription: No name.\n---\n",
    "CWD/.agents/skills/\u63d0\u4ea4/SKILL.md": "---\nname: \u63d0\u4ea4\ndescription: Commit.\n---\n",
    "CWD/.codex/skills/pdf/SKILL.md": "---\nname: pdf\ndescription: Ours.\n---\n",
    "CWD/.codex/config.toml": "[mcp_servers.shared]\nurl = \"https://shared.example.com/x\"\n",
    "HOME/.codex/sessions/2026/10/17/rollout-2026-10-17T01-00-00-" + SESSION + ".jsonl":
        '{"type":"session_meta","payload":{"session_id":"' + SESSION + '","cwd":"{CWD}"}}\n',
}


# Codex 0.163.0's own `--help`, the part the launch options are read from
# (task 1677; the text `test/codex-adapter/options.py` holds the adapter to).
CODEX_HELP = """\
Usage: codex [OPTIONS] [PROMPT]

Options:
  -s, --sandbox <SANDBOX_MODE>
          Select the sandbox policy to use when executing model-generated shell commands

          [possible values: read-only, workspace-write, danger-full-access]

      --approve-for-me
          Route approval requests through automatic review using the workspace-write sandbox

  -a, --ask-for-approval <APPROVAL_POLICY>
          Configure when the model requires human approval before executing a command

          Possible values:
          - on-request: The model decides when to ask the user for approval
          - never:      Never ask for user approval Execution failures are immediately returned to
            the model

      --search
          Enable live web search.
"""


def option_requests(paths):
    """Asked with a stand-in `codex` first on PATH that prints CODEX_HELP."""
    home, cwd = paths["HOME"], paths["CWD"]
    role = {"key": "r", "name": "r"}

    def launch(name, options, args=None):
        cli = {"skills": {"default": True, "except": []}, "mcp": {"default": True, "except": []},
               "args": args or [], "options": options}
        return (name, "launch", {"version": 1, "cwd": cwd, "home": home, "polter": None,
                                 "session": None, "role": role, "cli": cli})

    return [
        ("options: what --help lists, with the short spellings", "inventory", {"version": 1, "cwd": None, "home": home}),
        launch("options: both picked, after the hooks", {"sandbox": "workspace-write", "approval": "never"}),
        launch("options: -s x in the extra arguments keeps the sandbox out", {"sandbox": "read-only", "approval": "on-request"}, ["-s", "danger-full-access"]),
        launch("options: -s=x too", {"sandbox": "read-only"}, ["-s=danger-full-access"]),
        launch("options: --sandbox=x and -a x", {"sandbox": "read-only", "approval": "never"}, ["--sandbox=workspace-write", "-a", "never"]),
        launch("options: a value it does not list, a key it does not have, no value", {"sandbox": "yolo", "model": "x", "approval": None}),
        launch("options: not an object is no options", ["read-only"]),
    ]


def requests(paths):
    home, cwd = paths["HOME"], paths["CWD"]
    role = {"key": "r", "name": "r", "instructions": "say \"hi\"\nthen stop\x7f \u4e2d\u6587 & | ^"}
    off = {"skills": {"default": False, "except": ["skill:writer"]},
           "mcp": {"default": True, "except": ["mcp:pencil", "mcp:polter", "mcp:has"]},
           "model": "gpt-5.6-luna"}

    def launch(name, session=None, cli=off, r=role, polter=None, cwd_=cwd):
        return (name, "launch", {"version": 1, "cwd": cwd_, "home": home, "polter": polter,
                                 "session": session, "role": r, "cli": cli})

    out = [
        ("inventory with a directory", "inventory", {"version": 1, "cwd": cwd, "home": home}),
        ("inventory without one", "inventory", {"version": 1, "cwd": None, "home": home}),
        ("inventory of an empty home", "inventory", {"version": 1, "cwd": None, "home": paths["HOME2"]}),
        launch("launch: switch things off"),
        launch("launch: no directory", cwd_=None),
        launch("launch: everything on", cli={}, r={"key": "e", "name": "e"}),
        launch("launch: a session that is here", session=SESSION),
        launch("launch: a session that is not", session="99999999-1111-4222-8333-444455556666"),
        launch("launch: a session name", session="latest"),
        launch("launch: the role chose", session=SESSION, cli=dict(off, args=["resume", "--last"])),
        launch("launch: a Polter path, with the hooks of task 1668", polter="/x/polter"),
        ("identify: the marker, no pid", "identify",
         {"version": 1, "cwd": None, "home": home, "pid": None, "env": {"POLTER_AGENT_CLI": "codex"}}),
        ("identify: by directory, no pid", "identify",
         {"version": 1, "cwd": cwd, "home": home, "pid": None, "env": {"POLTER_AGENT_CLI": "codex"}}),
        ("identify: by directory, another directory", "identify",
         {"version": 1, "cwd": paths["HOME2"], "home": home, "pid": None, "env": {"POLTER_AGENT_CLI": "codex"}}),
        ("identify: nothing to go on", "identify",
         {"version": 1, "cwd": None, "home": home, "pid": None, "env": {"POLTER_REGISTERED": "1"}}),
    ]
    if not ON_WINDOWS:
        out.append(("identify: a parent that is not Codex", "identify",
                    {"version": 1, "cwd": None, "home": home, "pid": os.getpid(), "env": {"POLTER_REGISTERED": "1"}}))
    return out


def normalise(answer, ps_side, report):
    if ON_WINDOWS and ps_side and isinstance(answer.get("argv"), list) and answer["argv"]:
        argv = answer["argv"]
        first = argv[0]
        if isinstance(first, str) and first.lower().endswith("codex.exe"):
            report.append("argv[0] resolved to " + first)
            answer["argv"] = ["codex"] + argv[1:]
        elif len(argv) > 1 and str(first).lower().endswith("node.exe") and str(argv[1]).lower().endswith(".js"):
            report.append("argv[0:2] resolved to %s %s" % (first, argv[1]))
            answer["argv"] = ["codex"] + argv[2:]
        else:
            report.append("argv[0] is %r, which is neither codex.exe nor node.exe + .js" % (first,))
    if isinstance(answer.get("notes"), list):
        out = []
        for n in answer["notes"]:
            if isinstance(n, str) and n.startswith("Could not read ") and ": " in n:
                n = n[: n.index(": ", len("Could not read ")) + 2] + "<reader's message>"
            out.append(n)
        answer["notes"] = out
    if ON_WINDOWS and "installed" in answer:
        report.append("installed = %s (not compared on Windows)" % answer["installed"])
        answer["installed"] = None
    return answer


def run(argv, env):
    p = subprocess.run(argv, capture_output=True, env=env)
    return p.returncode, p.stdout, p.stderr.decode("utf-8", "replace").strip()


def compare(name, question, req, py, ps, env):
    raw = json.dumps(req, ensure_ascii=False)
    a = run(py + [question, raw], env)
    b = run(ps + [question, raw], env)
    report = []
    ok = a[0] == b[0]
    if not ok:
        report.append("exit %d (py) vs %d (ps1): %s | %s" % (a[0], b[0], a[2], b[2]))
    elif a[0] == 0:
        try:
            pa = json.loads(a[1].decode("utf-8"))
            pb = json.loads(b[1].decode("utf-8"))
        except ValueError as e:
            report.append("not JSON: %s" % e)
            ok = False
        else:
            canon = (json.dumps(pb, ensure_ascii=False) + "\n").encode("utf-8")
            if canon != b[1]:
                ok = False
                report.append("ps1 is not formatted as Python formats JSON")
            na = json.dumps(normalise(pa, False, report), ensure_ascii=False)
            nb = json.dumps(normalise(pb, True, report), ensure_ascii=False)
            if na != nb:
                ok = False
                i = next((k for k in range(min(len(na), len(nb))) if na[k] != nb[k]), min(len(na), len(nb)))
                report.append("first difference at %d:\n  py  %s\n  ps1 %s" % (i, na[max(0, i - 60):i + 60], nb[max(0, i - 60):i + 60]))
    print("%s  %s" % ("ok  " if ok else "DIFF", name))
    for r in report:
        print("      " + r)
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ps", default="powershell" if ON_WINDOWS else "pwsh")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    base = tempfile.mkdtemp(prefix="polter-codex-compare-")
    try:
        paths = {k: os.path.join(base, k.lower()) for k in ("HOME", "HOME2", "CWD")}
        for p in paths.values():
            os.makedirs(p, exist_ok=True)
        for rel, content in FILES.items():
            top, rest = rel.split("/", 1)
            full = os.path.join(paths[top], *rest.split("/"))
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "wb") as f:
                f.write(content.replace("{CWD}", paths["CWD"]).encode("utf-8"))

        env = dict(os.environ)
        env.pop("CODEX_HOME", None)
        py = [sys.executable, os.path.join(PLUGIN, "adapter.py")]
        ps = [args.ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
              os.path.join(PLUGIN, "adapter.ps1")]
        if not ON_WINDOWS:
            ps = [args.ps, "-NoProfile", "-NonInteractive", "-File", os.path.join(PLUGIN, "adapter.ps1")]

        # **No real Codex is ever started here, `--help` included** (task
        # 1678): an inventory now asks the CLI for its launch options, and a
        # reading that depends on which Codex this machine has is not a
        # reading -- nor may the Windows test machine start an agent CLI.
        # POSIX: a stand-in first on PATH that prints CODEX_HELP. Windows,
        # where `adapter.ps1` takes only a `codex.exe` or npm's shim and a
        # shell script cannot stand in: no Codex to be found at all, and
        # the launch options are said to be skipped.
        if ON_WINDOWS:
            env["PATH"] = os.pathsep.join(d for d in env.get("PATH", "").split(os.pathsep)
                                          if not any(os.path.exists(os.path.join(d, "codex" + x))
                                                     for x in ("", ".exe", ".cmd", ".bat", ".ps1")))
            env["APPDATA"] = base
        else:
            fake = os.path.join(base, "help-bin")
            os.makedirs(fake)
            with open(os.path.join(fake, "codex"), "w", encoding="utf-8") as f:
                f.write("#!/bin/sh\nif [ \"$1\" = --help ]; then cat <<'POLTER_HELP'\n%sPOLTER_HELP\nexit 0\nfi\nexit 1\n" % CODEX_HELP)
            os.chmod(os.path.join(fake, "codex"), 0o755)
            env["PATH"] = fake + os.pathsep + env.get("PATH", "")

        good = True
        for name, question, req in requests(paths):
            good = compare(name, question, req, py, ps, env) and good
        if ON_WINDOWS:
            print("skipped   the launch options (need a stand-in codex, POSIX only)")
        else:
            for name, question, req in option_requests(paths):
                good = compare(name, question, req, py, ps, env) and good

        if not ON_WINDOWS:
            stand = os.path.join(base, "bin", "codex")
            os.makedirs(os.path.dirname(stand))
            shutil.copyfile("/bin/sh", stand)
            os.chmod(stand, 0o755)
            rollout = os.path.join(paths["HOME"], ".codex", "sessions", "2026", "10", "17",
                                   "rollout-2026-10-17T01-00-00-%s.jsonl" % SESSION)
            child = subprocess.Popen([stand, "-c", "exec 3>>'%s'; sleep 30" % rollout])
            try:
                time.sleep(0.5)
                req = {"version": 1, "cwd": None, "home": paths["HOME"], "pid": child.pid,
                       "env": {"POLTER_REGISTERED": "1"}}
                good = compare("identify: a Codex holding its rollout open", "identify", req, py, ps, env) and good
            finally:
                child.kill()
                child.wait()

            # Two Codex sessions in one directory, told apart by when each
            # started against when this one's sidecar did (task 1667).
            sidecar = subprocess.Popen(["/bin/sleep", "30"])
            try:
                now = int(time.time() * 1000)
                twin_dir = os.path.join(base, "twin")
                os.makedirs(twin_dir)
                day = os.path.join(paths["HOME"], ".codex", "sessions", "2026", "10", "18")
                os.makedirs(day, exist_ok=True)
                for ms, tail in ((now, 1), (now - 300000, 2)):
                    h = "%012x" % ms
                    sid = "%s-%s-7000-8000-%012x" % (h[:8], h[8:], tail)
                    with open(os.path.join(day, "rollout-2026-10-18T06-00-00-%s.jsonl" % sid), "w") as f:
                        # As Codex writes it: the start as an ISO time (task 1674).
                        iso = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms / 1000)) + ".%03dZ" % (ms % 1000)
                        f.write(json.dumps({"type": "session_meta", "payload": {
                            "session_id": sid, "cwd": twin_dir, "timestamp": iso}}) + "\n")
                time.sleep(0.5)
                req = {"version": 1, "cwd": twin_dir, "home": paths["HOME"], "pid": None, "sidecar_pid": sidecar.pid,
                       "env": {"POLTER_AGENT_CLI": "codex"}}
                good = compare("identify: two in one directory, told apart by start", "identify", req, py, ps, env) and good
            finally:
                sidecar.kill()
                sidecar.wait()
        print("all agree" if good else "THEY DIFFER")
        return 0 if good else 1
    finally:
        if args.keep:
            print("left in " + base)
        else:
            shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
