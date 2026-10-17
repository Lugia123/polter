#!/usr/bin/env python3
"""The launch options both adapters offer, and what a role's pick becomes.

Task 1677. An adapter reads which values a CLI takes for its unattended
settings from that CLI's own `--help` (`launch_options`) and turns a role's
pick into flags (`apply_options`). This holds the two to the help texts
below -- copied from Claude Code 2.1.302 and Codex 0.163.0, the versions
they were measured on -- so it needs neither CLI installed:

  * every value each help lists is offered, in its order, and nothing else;
  * a short spelling (`-s, --sandbox`) is the same flag: extra arguments
    that give `-s x` keep a picked sandbox out, with a note, rather than
    handing Codex the flag twice;
  * a value the CLI does not list, or an option it does not have, adds no
    flag and says so.

    python3 test/codex-adapter/options.py      # from the repo root

Exit: 0 when every case holds, 1 otherwise.
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

CLAUDE_HELP = """\
Usage: claude [options] [command] [prompt]

Options:
  --model <model>                       Model for the current session.
  --permission-mode <mode>              Permission mode to use for the session
                                        (choices: "acceptEdits", "auto",
                                        "bypassPermissions", "manual",
                                        "dontAsk", "plan")
  -r, --resume [value]                  Resume a conversation by session ID
"""

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


def load(name, help_text):
    path = os.path.join(ROOT, "plugins", name, "adapter.py")
    spec = importlib.util.spec_from_file_location("adapter_" + name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # The CLI is not run: its help is the text above.
    module.help_text = lambda _binary: help_text
    return module


failures = []


def check(name, got, want):
    if got == want:
        print("ok   %s" % name)
    else:
        print("FAIL %s\n     got  %r\n     want %r" % (name, got, want))
        failures.append(name)


def main():
    claude = load("claude-code", CLAUDE_HELP)
    codex = load("codex", CODEX_HELP)

    offered = {o["key"]: o for o in claude.launch_options(CLAUDE_HELP)}
    check("claude offers permission_mode alone", sorted(offered), ["permission_mode"])
    check("claude's modes, in its order",
          [v["value"] for v in offered["permission_mode"]["values"]],
          ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"])
    check("claude's mode has no short spelling", offered["permission_mode"]["aliases"], [])

    offered = {o["key"]: o for o in codex.launch_options(CODEX_HELP)}
    check("codex offers approval and sandbox", sorted(offered), ["approval", "sandbox"])
    check("codex's sandbox values", [v["value"] for v in offered["sandbox"]["values"]],
          ["read-only", "workspace-write", "danger-full-access"])
    check("codex's approval values", [v["value"] for v in offered["approval"]["values"]],
          ["on-request", "never"])
    check("codex's short spellings", (offered["sandbox"]["aliases"], offered["approval"]["aliases"]),
          (["-s"], ["-a"]))
    check("a help that lists nothing offers nothing", codex.launch_options("Usage: codex\n"), [])

    pick = {"options": {"sandbox": "workspace-write", "approval": "never"}}
    notes = []
    # In the order the role wrote them.
    check("a pick becomes its flags", codex.apply_options(pick, [], notes),
          ["--sandbox", "workspace-write", "--ask-for-approval", "never"])
    check("... and says nothing", notes, [])

    for extra in (["-s", "read-only"], ["--sandbox", "read-only"], ["--sandbox=read-only"], ["-s=read-only"]):
        notes = []
        got = codex.apply_options({"options": {"sandbox": "workspace-write"}}, extra, notes)
        check("extra %s keeps the picked sandbox out" % " ".join(extra), got, [])
        check("... and says why", notes,
              ['Launch option "sandbox" left out: the extra arguments already give --sandbox.'])

    notes = []
    check("a value the CLI does not list adds nothing",
          codex.apply_options({"options": {"approval": "sometimes"}}, [], notes), [])
    check("... and says so", notes,
          ['Launch option approval="sometimes" is not a value this version takes; left out.'])
    notes = []
    check("an option the CLI does not have adds nothing",
          claude.apply_options({"options": {"sandbox": "read-only"}}, [], notes), [])
    check("... and says so", notes,
          ['Launch option "sandbox" is not one this version offers; left out.'])
    notes = []
    check("claude: a picked mode becomes --permission-mode",
          claude.apply_options({"options": {"permission_mode": "auto"}}, ["--verbose"], notes),
          ["--permission-mode", "auto"])

    print("%d failed" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
