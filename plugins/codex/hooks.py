"""Codex's hooks, as `-c` arguments for the command line that starts it.

Task 1668. The adapter's `launch` puts what `hook_args` returns on the
Codex command line and answers `"hooks": true, "hooks_heard":
"first_turn"`. Each hook runs `<polter> +hook --cli codex <Event>`, which
reads the payload on stdin, hands it to this terminal's Polter, and always
exits 0 with nothing on stdout -- so a hook never decides anything for
Codex (an empty stdout is "no decision", codex-rs/hooks/src/events/*.rs).

**Why the trust hashes.** Codex runs a hook from the user's config or from
`-c` only once it is trusted: its `hooks.state."<key>".trusted_hash` matches
the hook as written. An untrusted hook does not run, and the TUI opens a
review of it at startup, in front of the prompt. So the same `-c` that adds
the hooks says they are trusted -- these hooks and no others. The other
way, `--dangerously-bypass-hook-trust`, would run every untrusted hook the
user or the project has, unreviewed; it is not used.

The key and the hash are Codex's own (rust-v0.163.0):
- key: `<source>:<event label>:<group>:<handler>`, where the source of a `-c`
  is the made-up path `<session-flags>/config.toml` resolved against `/`
  (`synthetic_layer_path`, hooks/src/engine/discovery.rs; `hook_key`,
  hooks/src/lib.rs). Windows resolves it against `C:\\` -- see
  `session_flags_source`.
- hash: `sha256:` and the hex SHA-256 of the hook's normalized identity --
  `{"event_name": <label>, "hooks": [<handler>]}` with every object's keys
  sorted, as compact JSON (`hook_hash`, discovery.rs; `version_for_toml`,
  config/src/fingerprint.rs). The handler is normalized: `timeout` always
  present, `async` always present, nothing that was not given.

A mistake in either is not silent: the hook does not run and Codex shows
its review at startup, on the screen.
"""

import hashlib
import json

# Codex's hook names, and the label each has in a trust key
# (`hook_event_key_label`). The ones Polter translates
# (`agent_event.zig`, `codex`); `SessionEnd` is left out -- an exit is seen
# from the process -- and so are the compaction and subagent hooks.
EVENTS = (
    ("SessionStart", "session_start"),
    ("UserPromptSubmit", "user_prompt_submit"),
    ("Stop", "stop"),
    ("Interrupt", "interrupt"),
    ("PermissionRequest", "permission_request"),
    ("PreToolUse", "pre_tool_use"),
    ("PostToolUse", "post_tool_use"),
)

# Seconds. `+hook` gives up on Polter well before this; the number is
# only what Codex waits before it stops waiting for the hook. Codex clamps
# `Interrupt` to at most 3 and this is under that.
TIMEOUT_S = 3


def session_flags_source(windows):
    """Where Codex says a `-c` hook came from, as the start of its key."""
    if windows:
        return "C:\\<session-flags>\\config.toml"
    return "/<session-flags>/config.toml"


def sh_quote(s):
    """`s` as one word for `sh`: Codex runs a hook's command with
    `$SHELL -lc`."""
    return "'" + s.replace("'", "'\\''") + "'"


def ps_quote(s):
    """`s` as one single-quoted PowerShell string: nothing in it is expanded
    -- not `$`, not a backtick -- and a quote is written twice."""
    return "'" + s.replace("'", "''") + "'"


def hook_command(polter, event, windows):
    """The command line one hook runs."""
    if windows:
        # **PowerShell, not `cmd.exe`** (task 1748, measured on the Windows
        # machine, Codex 0.154): Codex runs a hook as
        # `powershell.exe -NoProfile -Command "<line>"`. A line that starts
        # with a quoted path is a string to PowerShell, and the `+` after it
        # an operator: `"<polter>" +hook ...` is a ParserError, exit 1, and
        # Polter never runs -- every hook of every Codex on Windows failed so.
        # The call operator makes the path a command, and single quotes keep
        # every character of it as it is.
        return "& %s +hook --cli codex %s" % (ps_quote(polter), event)
    return "%s +hook --cli codex %s" % (sh_quote(polter), event)


def handler(command):
    """One hook, as Codex normalizes it before hashing."""
    return {"type": "command", "command": command, "timeout": TIMEOUT_S, "async": False}


def trusted_hash(label, command):
    identity = {"event_name": label, "hooks": [handler(command)]}
    text = json.dumps(identity, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()


def toml_string(s):
    """A TOML basic string. JSON's escapes are TOML's for everything a
    path and a few words can hold."""
    return json.dumps(s, ensure_ascii=False)


def hook_args(polter, windows=False):
    """The `-c` arguments that add Polter's hooks to one Codex, trusted.

    One `-c` per hook, and one for the trust of all of them: the trust keys
    have dots in them (`config.toml`), and a `-c` key is split on its dots,
    so they go inside the value of `hooks.state`, where TOML quotes them.
    """
    args = []
    state = []
    source = session_flags_source(windows)
    for event, label in EVENTS:
        command = hook_command(polter, event, windows)
        args += [
            "-c",
            "hooks.%s=[{hooks=[{type=\"command\",command=%s,timeout=%d}]}]"
            % (event, toml_string(command), TIMEOUT_S),
        ]
        key = "%s:%s:0:0" % (source, label)
        state.append("%s={trusted_hash=%s}" % (toml_string(key), toml_string(trusted_hash(label, command))))
    args += ["-c", "hooks.state={%s}" % ",".join(state)]
    return args


if __name__ == "__main__":
    # `python3 hooks.py <polter> [windows]`: the arguments, one per line,
    # for looking at and for the cells that check them against Codex.
    import sys

    for a in hook_args(sys.argv[1], len(sys.argv) > 2 and sys.argv[2] == "windows"):
        print(a)
