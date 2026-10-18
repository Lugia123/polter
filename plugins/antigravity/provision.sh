#!/bin/sh
# Tell Google's Antigravity CLI (`agy`) that Polter is here.
#
# The implementation is in `_sdk/provision.sh`; this file is the answers.
# See dev-docs/poltergeist/provisioning.md.
#
# Task 1682. **Where things go was read off `agy` 1.4.0 itself**: the
# customization guide it ships (`builtin/skills/agy-customizations/`), and
# `agy plugin list --json` / `agy plugin validate` run against a home made
# for the purpose. What has not been measured yet -- a session started with
# all of this in place -- is said where it matters.
#
# It is the CLI Google moved personal accounts to from Gemini CLI on
# 2026-06-18, and it keeps its files under the same `~/.gemini` -- but not
# the same files: Gemini CLI's `settings.json`, `skills/` and `GEMINI.md` are
# not this plugin's, and it never touches them.
#
# **Everything is one directory of Polter's own: an Antigravity plugin.**
# `agy` discovers a plugin as any directory under `~/.gemini/config/plugins/`
# holding a `plugin.json`, and loads the MCP servers (`mcp_config.json`),
# hooks (`hooks.json`), rules (`rules/`) and skills (`skills/`) inside it.
# Measured: with all four in `~/.gemini/config/plugins/polter/`,
# `agy plugin list --json` lists `polter` with each of them, and without the
# `plugin.json` it lists nothing. So none of the person's own files is
# edited -- not their `mcp_config.json`, not a `hooks.json` of theirs, not a
# rules file they write in -- and taking Polter away is removing one
# directory.

set -eu

. "$(dirname "$0")/../_sdk/provision.sh"

POLTER_HOST_KEY=antigravity
POLTER_HOST_LABEL="Antigravity CLI"
POLTER_HOST_BIN=agy

# The plugin's directory. Its name is the one `agy` keeps the person's
# on/off choice under (`config.json`, `plugins.<directory name>`), so it is
# fixed rather than per build.
agy_plugin_dir() {
  printf '%s/.gemini/config/plugins/polter' "$home"
}

# The manifest is what makes the directory a plugin. It names nothing else:
# `agy plugin validate` accepts `{"name": ...}` alone, and a field it does
# not know is one more thing for a later release to object to.
agy_manifest() {
  _d=$(agy_plugin_dir)
  _want='{"name": "polter"}'
  if [ -f "$_d/plugin.json" ] && [ "$(cat "$_d/plugin.json")" = "$_want" ]; then
    return 0
  fi
  mkdir -p "$_d" || return 1
  printf '%s\n' "$_want" >"$_d/plugin.json" || return 1
  wrote=yes
}

# **There is an `agy mcp add`, and it is not used**: it writes the person's
# global `~/.gemini/config/mcp_config.json` (measured), and the plugin's own
# file keeps Polter out of theirs. The file is the common shape --
# `mcpServers`, each entry a `command` with `args` and `env` beside it -- so
# it is edited like the B family's (provisioning.md).
config() {
  printf '%s/mcp_config.json' "$(agy_plugin_dir)"
}

# What the polter entry's `env` carries besides the version, so that
# Polter's server can say which CLI started it -- the same marker the Codex
# plugin writes (`plugins/codex/provision.sh`), read by this plugin's
# `adapter.py identify`.
POLTER_AGY_MARKER=POLTER_AGENT_CLI

host_mcp_current() {
  polter_json_read "$(config)" \
    'e = (d.get("mcpServers") or {}).get("polter")
# Nothing at all when there is no entry: any output reads as somebody
# else'"'"'s registration (`registration=other`).
if not isinstance(e, dict):
    raise SystemExit(0)
env = e.get("env") or {}
print(env.get("POLTER_REGISTERED", ""), env.get("POLTER_AGENT_CLI", ""))
print(e.get("command", ""))'
}

# An entry this build wrote before it carried the marker is this build's,
# at this version, and cannot say which CLI it serves.
host_mcp_complete() {
  case "$1" in
    *" antigravity"*) return 0 ;;
    *) return 1 ;;
  esac
}

# **This is enough for Polter to know the terminal** (TEST-CASES L0-06,
# measured 2026-10-18 on 1.4.0). `+mcp` finds its terminal by
# `GHOSTTY_POLTER_SOCKET` and `GHOSTTY_POLTER_TOKEN` in its own environment,
# and Codex drops both (#1645); `agy` does not. A stand-in server in a
# plugin got the whole environment of the terminal `agy` was started in,
# both variables and `GHOSTTY_SURFACE_ID` included, with the entry's `env`
# added on top and `PLUGIN_ROOT` / `PLUGIN_DATA` beside it; its parent was
# `agy` itself and its working directory the plugin's. It is started when
# first needed -- the first prompt, or opening `/mcp` -- not at launch.
#
# Its name is the plugin's and the server's joined: `/mcp` listed a server
# `probe` in plugin `polterprobe` as `polterprobe_probe`, so Polter's is
# `polter_polter` there.
host_mcp_register() {
  version=$1 version_key=$2 exe=$3 scope=$4

  agy_manifest || return 1
  POLTER_EXE=$exe POLTER_VER=$version POLTER_KEY=$version_key POLTER_MARK=$POLTER_AGY_MARKER \
  polter_json_edit "$(config)" \
    'import os
d.setdefault("mcpServers", {})["polter"] = {
    "command": os.environ["POLTER_EXE"],
    "args": ["+mcp"],
    "env": {
        os.environ["POLTER_KEY"]: os.environ["POLTER_VER"],
        os.environ["POLTER_MARK"]: "antigravity",
    },
}'
}

# --- hooks -------------------------------------------------------------------
#
# **In the plugin's own `hooks.json`.** Antigravity has no per-run way to add
# a hook (nothing like Codex's `-c`); a plugin's hooks run in every session
# while the plugin is on, which is what a global file would do too, without
# the file being the person's. Its top-level keys are hook names, each a
# group of events ("docs/hooks"), so Polter's are under `polter`; `hooks=no`
# takes that one key back out.
#
# Because they run in every session, they also run for an `agy` started by
# hand, and for one started outside Polter -- where `+hook` finds no socket
# and exits 0 having done nothing (adapters.md 3.3).
#
# Two things the documentation does not settle, measured 2026-10-18 on
# 1.4.0 with a stand-in plugin whose hooks answered nothing:
#
#   * **H1. An empty stdout is "no decision".** `+hook` never writes to
#     stdout, and the guide calls `decision` required in the answers to
#     `PreToolUse` and `Stop`. With nothing on stdout, a `run_command` was
#     neither blocked nor waved through: the approval box came up as it does
#     without a hook, and once approved the command ran and the turn ended.
#   * **H2. A new hook is not held for review.** The log said
#     `loaded 1 named hooks from 1 hooks.json file(s)` at startup and no box
#     asked about it. The one box at startup is the folder-trust question,
#     asked once per directory, before any hook or server runs.
#
# The command goes through `sh -c` and runs in the directory holding
# `hooks.json` (the guide, "Hook Handler Fields"), so the path is quoted for
# a shell (`shlex.quote`).
#
# The events, and what each becomes, are `agent_event.zig`'s
# (`antigravity`). `PostInvocation` is not taken: it is a step inside a turn,
# and `Stop` says when the turn is over.
POLTER_AGY_HOOKS_KEY=polter

# Seconds. `+hook` gives up on Polter well before this; the default is 30,
# and a hook that waits that long on a Polter that is not answering would
# hold the agent up as long.
POLTER_AGY_HOOK_TIMEOUT=3

agy_hooks_file() {
  printf '%s/hooks.json' "$(agy_plugin_dir)"
}

agy_want_hooks() {
  [ "$(polter_param hooks yes)" = yes ]
}

host_settings_apply() {
  # Whatever else this run wrote into the directory -- the rules, just
  # before this -- is not a plugin without it.
  agy_manifest || return 1
  agy_rules_tidy
  agy_hooks_apply || return 1
  agy_approve_tidy
}

agy_hooks_apply() {
  f=$(agy_hooks_file)
  if agy_want_hooks; then want=yes; else want=no; fi

  # Nothing to take out of a file that is not there.
  if [ "$want" = no ] && [ ! -f "$f" ]; then
    return 0
  fi

  # Read before writing: written only when Polter's entry is not already
  # exactly this one, or is there and should not be.
  _before=
  [ -f "$f" ] && _before=$(cksum <"$f")

  POLTER_EXE=$exe POLTER_WANT=$want POLTER_TIMEOUT=$POLTER_AGY_HOOK_TIMEOUT \
  POLTER_HOOKS_KEY=$POLTER_AGY_HOOKS_KEY \
  polter_json_edit "$f" \
    'import os, shlex
key = os.environ["POLTER_HOOKS_KEY"]
quoted = shlex.quote(os.environ["POLTER_EXE"])
def handler(event):
    return {"type": "command",
            "command": "%s +hook --cli antigravity %s" % (quoted, event),
            "timeout": int(os.environ["POLTER_TIMEOUT"])}
# SessionStart, PreInvocation and Stop take their handlers directly; the
# tool events take matcher groups ("docs/hooks").
mine = {
    "SessionStart": [handler("SessionStart")],
    "PreInvocation": [handler("PreInvocation")],
    "PreToolUse": [{"matcher": "*", "hooks": [handler("PreToolUse")]}],
    "PostToolUse": [{"matcher": "*", "hooks": [handler("PostToolUse")]}],
    "Stop": [handler("Stop")],
}
if os.environ["POLTER_WANT"] == "yes":
    if d.get(key) != mine:
        d[key] = mine
else:
    # Only an entry that is recognisably Polter'"'"'s: one whose commands are
    # all `+hook --cli antigravity`. A `polter` of somebody else'"'"'s stays.
    have = d.get(key)
    if isinstance(have, dict) and "+hook --cli antigravity" in json.dumps(have):
        del d[key]' || return 1

  # A file that is now an empty object holds nothing; it goes, so that
  # turning hooks off leaves no hooks file behind.
  if [ "$want" = no ] && [ -f "$f" ] && [ "$(tr -d ' \n\t' <"$f")" = "{}" ]; then
    rm -f "$f"
  fi

  _after=
  [ -f "$f" ] && _after=$(cksum <"$f")
  if [ "$_before" != "$_after" ]; then
    wrote=yes
    if [ "$want" = yes ]; then
      say "hooks: Polter's entry written under \"$POLTER_AGY_HOOKS_KEY\" in $f"
    else
      say "hooks: Polter's entry taken out of $f"
    fi
  fi
  return 0
}

# --- no hook says yes for Polter's tools --------------------------------------
#
# **agy asks before every call to one of Polter's tools, and nothing this
# plugin can write stops it** (task 1682, measured on agy 1.4.2):
# - a `PreToolUse` hook answering `{"decision": "allow"}` for a call to
#   `polter_polter` was run, read that call, answered allow -- and agy put
#   its box up a millisecond later, with Polter's other hook taken out too;
# - `{"permissions": {"allow": ["mcp(polter_polter/me)"]}}`, the rule agy
#   itself writes for "always allow ... (Persist to settings.json)", does
#   nothing in this plugin's directory, nor does `mcp(polter_polter/*)`.
# What works is the person's own choice: "always allow" in the box, which
# agy writes into their own settings.json, or `--dangerously-skip-permissions`
# (every tool, shell commands included), offered as a launch option.
#
# A build before this one could write such a hook (`polter-approve`, running
# `approve.py`) when asked to. It did nothing but run on every tool call, so
# it is taken out wherever it is found.
POLTER_AGY_APPROVE_KEY=polter-approve

agy_approve_tidy() {
  f=$(agy_hooks_file)
  script="$(agy_plugin_dir)/approve.py"
  [ -f "$script" ] && rm -f "$script" && wrote=yes
  [ -f "$f" ] || return 0
  grep -q "\"$POLTER_AGY_APPROVE_KEY\"" "$f" || return 0
  _before=$(cksum <"$f")
  POLTER_KEY=$POLTER_AGY_APPROVE_KEY \
  polter_json_edit "$f" \
    'import os
key = os.environ["POLTER_KEY"]
have = d.get(key)
if isinstance(have, dict) and "approve.py" in json.dumps(have):
    del d[key]' || return 0
  if [ "$(tr -d ' \n\t' <"$f")" = "{}" ]; then
    rm -f "$f"
  fi
  _after=
  [ -f "$f" ] && _after=$(cksum <"$f")
  [ "$_before" != "$_after" ] && wrote=yes
  return 0
}

# A skill is a folder with a SKILL.md whose frontmatter has a `name` and a
# `description` (the guide's "docs/skills") -- the shape Polter's skills
# already have -- and a plugin's are under `skills/`. Measured:
# `agy plugin list --json` lists a skill put there by its name.
host_skills_dir() {
  printf '%s/skills' "$(agy_plugin_dir)"
}

# A plugin's rules are the files under its `rules/`, merged into every
# session while it is on ("docs/plugins"; `AGENTS.md` is the name the guide
# recommends). The file is Polter's alone, so the block is all it holds.
#
# **Not `~/.gemini/GEMINI.md`.** The web documentation calls that the
# global rules file; the guide `agy` ships does not mention it, and it is
# the file the Gemini CLI plugin wrote its block into. A block an older
# Polter left there is #1681's to clear, not this plugin's to take over.
host_rules_file() {
  printf '%s/rules/AGENTS.md' "$(agy_plugin_dir)"
}

# `rules=no` takes the block out and leaves an empty file; an empty file is
# a rule with nothing in it, so it goes, and the directory with it.
agy_rules_tidy() {
  _r=$(host_rules_file)
  if [ -f "$_r" ] && [ ! -s "$_r" ]; then
    rm -f "$_r"
    rmdir "${_r%/*}" 2>/dev/null || :
  fi
}

[ "${POLTER_PROVISION_FUNCTIONS_ONLY:-}" = 1 ] || polter_provision_main
