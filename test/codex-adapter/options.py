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

      --dangerously-bypass-approvals-and-sandbox
          Skip all confirmation prompts and execute commands without sandboxing. EXTREMELY
          DANGEROUS.

  -a, --ask-for-approval <APPROVAL_POLICY>
          Configure when the model requires human approval before executing a command

          Possible values:
          - on-request: The model decides when to ask the user for approval
          - never:      Never ask for user approval Execution failures are immediately returned to
            the model

      --search
          Enable live web search.
"""

# A Codex older than the two flags: the same help without them (0.163's own
# `--help` did not have `--approve-for-me`). One value-less answer fewer, and
# no default: a role with no pick must run exactly as it did.
CODEX_HELP_OLD = CODEX_HELP.replace(
    "      --approve-for-me\n"
    "          Route approval requests through automatic review using the workspace-write sandbox\n\n"
    "      --dangerously-bypass-approvals-and-sandbox\n"
    "          Skip all confirmation prompts and execute commands without sandboxing. EXTREMELY\n"
    "          DANGEROUS.\n\n", "")


def load(name, help_text):
    path = os.path.join(ROOT, "plugins", name, "adapter.py")
    spec = importlib.util.spec_from_file_location("adapter_" + name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # The CLI is not run: its help is the text above.
    module.help_text = lambda _binary: help_text
    return module


# The refusal a launch answers with when the extra arguments contradict
# themselves: `main` asks `approval_clash` and raises `Refused` before any
# flag is built (task 2679).
def refused(module, picked, extra):
    return module.approval_clash(list(extra))


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
    # One drop-down, four answers, each with the argv it stands for; the two
    # value-less flags first, then the policies a legacy role picked
    # (task 2679).
    check("codex's approval answers, in order",
          [(v["value"], v["args"]) for v in offered["approval"]["values"]],
          [("approve-for-me", ["--approve-for-me"]),
           ("bypass", ["--dangerously-bypass-approvals-and-sandbox"]),
           ("on-request", ["--ask-for-approval", "on-request"]),
           ("never", ["--ask-for-approval", "never"])])
    check("codex's approval default is Polter's", offered["approval"].get("default"), "approve-for-me")
    check("codex's short spellings", (offered["sandbox"]["aliases"], offered["approval"]["aliases"]),
          (["-s"], ["-a"]))
    check("a help that lists nothing offers nothing", codex.launch_options("Usage: codex\n"), [])

    # A Codex older than the two flags: no default is offered at all, so a
    # role that picked nothing runs exactly as it did.
    old = {o["key"]: o for o in codex.launch_options(CODEX_HELP_OLD)}
    check("an old codex offers the policies alone",
          [v["value"] for v in old["approval"]["values"]], ["on-request", "never"])
    check("... and no default", "default" in old["approval"], False)

    def applied(picked, extra=None):
        notes = []
        return codex.apply_options({"options": picked}, list(extra or []), notes), notes

    # **A role that picked nothing** gets Polter's default: automatic review
    # in the workspace-write sandbox.
    got, notes = applied({})
    check("nothing picked: --approve-for-me", got, ["--approve-for-me"])
    check("... and nothing to say", notes, [])

    # **A legacy role keeps its own answer.** Its policy is a value like any
    # other, so it is not overruled by the default and does not read back as
    # something it never chose.
    got, notes = applied({"approval": "never"})
    check("a legacy pick is its own flag", got, ["--ask-for-approval", "never"])
    check("... and the default is not added", "--approve-for-me" in got, False)
    check("... and nothing to say", notes, [])

    # **A person who changes the drop-down overrides it**: the same key, so
    # the old value is simply gone.
    got, _ = applied({"approval": "approve-for-me"})
    check("picking the default over a legacy value overrides it", got, ["--approve-for-me"])
    got, _ = applied({"approval": "bypass"})
    check("picking the dangerous one is its own flag", got,
          ["--dangerously-bypass-approvals-and-sandbox"])

    # A sandbox is the person's to pick only beside a manual policy.
    got, notes = applied({"approval": "never", "sandbox": "read-only"})
    check("a sandbox beside a policy goes on", got,
          ["--ask-for-approval", "never", "--sandbox", "read-only"])
    check("... and nothing to say", notes, [])
    for approve in ("approve-for-me", "bypass"):
        got, notes = applied({"approval": approve, "sandbox": "read-only"})
        check("a sandbox beside %s is left out" % approve, got, [codex.flag_for(approve)])
        check("... and says so", notes,
              ['Launch option "sandbox" left out: %s brings its own sandbox.'
               % codex.flag_for(approve)])
    got, notes = applied({"sandbox": "read-only"})
    check("a sandbox alone: no default approval on top", got, ["--sandbox", "read-only"])
    check("... and says so", notes,
          ["No approval setting was added: the role picked a sandbox, and "
           "--approve-for-me would bring its own."])

    # **The extra arguments are the role's own words**, and `launch` appends
    # them after these flags: what they already give is not added twice, and
    # the pick they cover is left out instead. The default is silent when it
    # is exactly what they give, and said when it is not.
    got, notes = applied({}, ["--approve-for-me"])
    check("extra --approve-for-me is not given twice", got, [])
    check("... and nothing to say", notes, [])
    got, notes = applied({}, ["--search"])
    check("an unrelated --search leaves the default to go on", got, ["--approve-for-me"])
    check("... and --search is not eaten", "--search" in got, False)
    check("... and nothing to say", notes, [])
    got, notes = applied({"approval": "bypass"}, ["--approve-for-me"])
    check("extra wins over the pick", got, [])
    check("... and says so", notes,
          ['Launch option "approval" left out: the extra arguments already give --approve-for-me.'])
    got, notes = applied({}, ["-a", "never"])
    check("extra -a keeps the default out", got, [])
    check("... and says so", notes,
          ["No approval setting was added: the role's own --ask-for-approval decides."])

    for extra in (["-s", "read-only"], ["--sandbox", "read-only"], ["--sandbox=read-only"], ["-s=read-only"]):
        notes = []
        got = codex.apply_options({"options": {"sandbox": "workspace-write"}}, extra, notes)
        check("extra %s keeps the picked sandbox out" % " ".join(extra), got, [])
        check("... and says why", notes,
              ["No approval setting was added: the role's own --sandbox decides.",
               'Launch option "sandbox" left out: the extra arguments already give --sandbox.'])

    # **Two answers in the role's own words are refused**, with what to
    # remove: Codex accepts both (measured on 0.166.0) and documents no
    # precedence, so resolving it would be choosing a privilege level.
    check("both value-less flags are refused",
          refused(codex, {}, ["--approve-for-me", "--dangerously-bypass-approvals-and-sandbox"]),
          "The extra arguments give --approve-for-me and --dangerously-bypass-approvals-and-sandbox; "
          "they cannot both be how approvals are handled. Keep the one you want.")
    check("a flag and a policy are refused",
          refused(codex, {}, ["--approve-for-me", "-a", "never"]),
          "The extra arguments give --approve-for-me and --ask-for-approval; "
          "they cannot both be how approvals are handled. Keep the one you want.")
    check("a flag and a sandbox are refused",
          refused(codex, {}, ["--dangerously-bypass-approvals-and-sandbox", "--sandbox=read-only"]),
          "The extra arguments give --dangerously-bypass-approvals-and-sandbox and --sandbox; "
          "--dangerously-bypass-approvals-and-sandbox brings its own sandbox. Keep the one you want.")
    check("a policy with a sandbox is not a clash",
          refused(codex, {}, ["-a", "never", "-s", "read-only"]), None)

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

    # The old help: no default, and the role's own policy still its own.
    old_module = load("codex", CODEX_HELP_OLD)
    notes = []
    check("an old codex gets no default approval",
          old_module.apply_options({"options": {}}, [], notes), [])
    check("... and says so", notes,
          ["No approval setting was added: this Codex does not take --approve-for-me "
           "(its --help does not list it)."])
    notes = []
    check("... and a legacy policy still goes on",
          old_module.apply_options({"options": {"approval": "never"}}, [], notes),
          ["--ask-for-approval", "never"])
    check("... and nothing to say", notes, [])

    # An option key absent, and one that is not an object at all: `launch`
    # reads `cli.options` once, the same way. There the default still stands
    # -- a Codex role with nothing configured is the case it is for.
    check("no options at all still gets the default",
          codex.apply_options({}, [], []), ["--approve-for-me"])
    check("options that are not an object still get the default",
          codex.apply_options({"options": ["read-only"]}, [], []), ["--approve-for-me"])

    print("%d failed" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
