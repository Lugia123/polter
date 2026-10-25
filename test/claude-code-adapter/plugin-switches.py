#!/usr/bin/env python3
"""The two switches on the Claude Code plugin's page reach `--settings` (task 2235).

`tui` and `autoScrollEnabled` are the first settings on that page that are
about *a session* rather than about registration. They travel: Polter reads
the plugin's own file (`Plugin.settingsFor`, one answer to "which settings
are in force") and writes the values into the `launch` request as `params`;
the adapter turns them into the one inline `--settings` it already builds.

This holds the adapter to that, and it is deliberately **not** a copy of
`compare.py`. That one answers "do the two adapters agree", which is a
different question: two adapters that both wrote `"tui": "classic"` would
agree, byte for byte, and be wrong in the same way. Here the expected
`--settings` is written out as Claude Code's own vocabulary -- measured on
2.1.310 (`claude doctor` rejects anything else, see the note below) -- so
this is where "classic" -> `"default"` is actually pinned.

    python3 test/claude-code-adapter/plugin-switches.py
    python3 test/claude-code-adapter/plugin-switches.py --ps pwsh

Both adapters are run, because both ship; a reading from `adapter.py` alone
is a reading about half of this plugin. With no PowerShell on PATH the
PowerShell half says SKIPPED and the exit code is still 0 -- which is why
`compare.py` is the gate that refuses to run without one and this is the
test that says what the values must be.

⚠️ **Why a value nobody knows is left out rather than passed on.** Measured
on 2.1.310: `claude doctor` with an inline `--settings` holding one invalid
value reports `Invalid settings` naming that key, and the binary's own
reader discards the whole inline object -- so a hand-edited file saying
`"tui": "sepia"` would take the session's `hooks`, its skill switches and
its `statusLine` with it. An agent with no Polter tools at all, from a typo
on a page about renderers. The note is what keeps that from being silent.

Exit: 0 when every case holds for every adapter that ran, 1 otherwise.
"""

import argparse
import collections
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PLUGIN = os.path.join(ROOT, "plugins", "claude-code")

DEFAULT_CLI = {
    "skills": {"default": True, "except": []},
    "mcp": {"default": True, "except": []},
    "model": None,
    "args": [],
}


def request(params=None, cli=None):
    req = {
        "version": 1,
        "cwd": None,
        "home": "/tmp",
        "role": {"key": "plain", "name": "Plain", "instructions": None},
        "cli": cli if cli is not None else dict(DEFAULT_CLI),
    }
    if params is not None:
        req["params"] = params
    return req


def run(argv, req):
    """One adapter, one `launch`. Returns (answer, stderr)."""
    p = subprocess.run(argv + ["launch", json.dumps(req, ensure_ascii=False)],
                       capture_output=True, text=True, timeout=60,
                       env=dict(os.environ, HOME="/tmp", PYTHONUTF8="1"))
    if p.returncode != 0:
        return None, (p.stderr or p.stdout).strip()
    return json.loads(p.stdout, object_pairs_hook=collections.OrderedDict), ""


def settings_of(answer):
    """The one inline `--settings`, as an object. None when there is none.

    Given twice, Claude Code's second replaces the first rather than merging
    with it, so there being exactly one is part of what is checked here and
    not an assumption: a second one would silently switch off everything the
    first said.
    """
    argv = answer.get("argv") or []
    found = []
    i = 0
    while i < len(argv):
        if argv[i] == "--settings":
            found.append(argv[i + 1])
            i += 2
        elif argv[i].startswith("--settings="):
            found.append(argv[i][len("--settings="):])
            i += 1
        else:
            i += 1
    if not found:
        return None
    if len(found) > 1:
        raise AssertionError("more than one --settings: %r" % (found,))
    value = json.loads(found[0], object_pairs_hook=collections.OrderedDict)
    if not isinstance(value, dict):
        raise AssertionError("--settings is not an object: %r" % (value,))
    return value


CASES = [
    # name, params, the keys expected in --settings (absent keys checked too)
    ("tui fullscreen is Claude Code's \"fullscreen\"",
     {"tui": "fullscreen"}, [("tui", "fullscreen"), ("autoScrollEnabled", None)]),
    ("classic is Claude Code's \"default\", not the word on the menu",
     {"tui": "classic"}, [("tui", "default"), ("autoScrollEnabled", None)]),
    ("follow writes nothing, so the person's own file decides",
     {"tui": "follow"}, [("tui", None), ("autoScrollEnabled", None)]),
    ("both follow is the same as saying nothing",
     {"tui": "follow", "autoScrollEnabled": "follow"}, [("tui", None), ("autoScrollEnabled", None)]),
    ("auto-scroll on is the boolean true, not the string \"true\"",
     {"autoScrollEnabled": "on"}, [("autoScrollEnabled", True)]),
    ("auto-scroll off is the boolean false",
     {"autoScrollEnabled": "off"}, [("autoScrollEnabled", False)]),
    ("both together, and in the manifest's order",
     {"tui": "classic", "autoScrollEnabled": "on"}, [("tui", "default"), ("autoScrollEnabled", True)]),
]


def check(name, got, want, failures):
    if got == want:
        print("ok    %s" % name)
    else:
        print("FAIL  %s\n      got  %r\n      want %r" % (name, got, want))
        failures.append(name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ps", default="powershell" if os.name == "nt" else "pwsh")
    args = ap.parse_args()

    adapters = [("adapter.py", [sys.executable, os.path.join(PLUGIN, "adapter.py")])]
    ps = shutil.which(args.ps)
    if ps is None:
        print("SKIPPED adapter.ps1: no %s on PATH" % args.ps)
    else:
        cmd = [ps, "-NoProfile", "-NonInteractive"]
        if os.name == "nt":
            cmd += ["-ExecutionPolicy", "Bypass"]
        cmd += ["-File", os.path.join(PLUGIN, "adapter.ps1")]
        adapters.append(("adapter.ps1", cmd))
    print("adapters: %s\n" % ", ".join(n for n, _ in adapters))

    failures = []
    for label, argv in adapters:
        for name, params, want in CASES:
            answer, err = run(argv, request(params))
            if answer is None:
                check("%s: %s" % (label, name), "the adapter failed: " + err, "an answer", failures)
                continue
            try:
                got = settings_of(answer)
            except (AssertionError, ValueError) as e:
                check("%s: %s" % (label, name), str(e), "one readable --settings", failures)
                continue
            got = got or {}
            check("%s: %s" % (label, name),
                  [(k, got.get(k)) for k, _ in want],
                  [(k, v) for k, v in want],
                  failures)

        # Nothing named at all: an adapter started by a `+launch` from a
        # Polter older than this key. That has to be an ordinary session.
        answer, err = run(argv, request())
        if answer is None:
            check("%s: no params at all" % label, "the adapter failed: " + err, "an answer", failures)
        else:
            check("%s: no params at all is an ordinary session" % label,
                  settings_of(answer), None, failures)

        # A value this version does not know: left out, and said out loud.
        answer, err = run(argv, request({"tui": "sepia", "autoScrollEnabled": "on"}))
        if answer is None:
            check("%s: an unknown value" % label, "the adapter failed: " + err, "an answer", failures)
        else:
            got = settings_of(answer) or {}
            check("%s: an unknown value is left out, and the known one still goes" % label,
                  (got.get("tui"), got.get("autoScrollEnabled")), (None, True), failures)
            named = [n for n in (answer.get("notes") or []) if "sepia" in n]
            check("%s: ... and a note names the value that was left out" % label,
                  len(named), 1, failures)

        # The role's own arguments already give a `--settings` that is a
        # file. Writing to it is what this adapter never does, so the
        # switches cannot be applied -- and that is worth a note rather than
        # silence, because the person set them on a page that now does
        # nothing.
        answer, err = run(argv, request({"tui": "fullscreen"},
                                        cli=dict(DEFAULT_CLI, args=["--settings", "/etc/claude/role.json"])))
        if answer is None:
            check("%s: a --settings that is a file" % label, "the adapter failed: " + err, "an answer", failures)
        else:
            argv_out = answer.get("argv") or []
            check("%s: a file --settings is left exactly where the role put it" % label,
                  [a for a in argv_out if a == "/etc/claude/role.json"], ["/etc/claude/role.json"], failures)
            said = [n for n in (answer.get("notes") or []) if "not applied" in n]
            check("%s: ... and a note says the switches were not applied" % label,
                  len(said), 1, failures)

        # A `params` that is not an object at all -- a list, say -- is "no
        # settings", the same as the key being absent, **on both branches**.
        # The branch that matters here is the one where the role's
        # `--settings` is a file: that is the one `adapter.py` used to read
        # `.get` off whatever it was handed, so a hand-made request with a
        # list there would have killed it where the PowerShell one shrugged.
        answer, err = run(argv, {"version": 1, "cwd": None, "home": "/tmp",
                                 "role": {"key": "plain", "name": "Plain", "instructions": None},
                                 "cli": dict(DEFAULT_CLI, args=["--settings", "/etc/claude/role.json"]),
                                 "params": [1, 2]})
        if answer is None:
            check("%s: params that is a list beside a file --settings" % label,
                  "the adapter failed: " + err, "an answer", failures)
        else:
            argv_out = answer.get("argv") or []
            check("%s: a list where params should be is no params, on the file branch too" % label,
                  [a for a in argv_out if a == "/etc/claude/role.json"], ["/etc/claude/role.json"], failures)

        # The role's own inline `--settings` is merged into the same object
        # rather than given twice, and the switches go in beside it.
        answer, err = run(argv, request({"tui": "classic"},
                                        cli=dict(DEFAULT_CLI, args=["--settings", '{"theme": "dark"}'])))
        if answer is None:
            check("%s: beside the role's own inline --settings" % label, "the adapter failed: " + err, "an answer", failures)
        else:
            got = settings_of(answer) or {}
            check("%s: the role's own key and the switch share one object" % label,
                  (got.get("theme"), got.get("tui")), ("dark", "default"), failures)

        # **The role's own key for one of these wins over the page.** A role
        # that pins `tui` for its own reasons -- recording its screen, say --
        # is saying what this session starts with; the page is about what a
        # session starts with when the role says nothing. The other switch,
        # which the role did not name, is still applied.
        answer, err = run(argv, request({"tui": "fullscreen", "autoScrollEnabled": "off"},
                                        cli=dict(DEFAULT_CLI, args=["--settings", '{"tui": "default"}'])))
        if answer is None:
            check("%s: the role's own key for a switch" % label, "the adapter failed: " + err, "an answer", failures)
        else:
            got = settings_of(answer) or {}
            check("%s: a switch the role wrote itself is not overruled by the page" % label,
                  (got.get("tui"), got.get("autoScrollEnabled")), ("default", False), failures)
            check("%s: ... and the switch the role did not write still goes" % label,
                  got.get("autoScrollEnabled"), False, failures)

    if failures:
        print("\n%d case(s) failed" % len(failures))
        return 1
    print("\nevery case held for %d adapter(s)" % len(adapters))
    return 0


if __name__ == "__main__":
    sys.exit(main())
