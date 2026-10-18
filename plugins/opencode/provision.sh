#!/bin/sh
# Tell opencode that Polter is here.
#
# The implementation is in `_sdk/provision.sh`; this file is the answers.
# See dev-docs/poltergeist/provisioning.md.

set -eu

. "$(dirname "$0")/../_sdk/provision.sh"

POLTER_HOST_KEY=opencode
POLTER_HOST_LABEL="opencode"
POLTER_HOST_BIN=opencode

# **`opencode mcp add` exists, and it still cannot be used.** The comment
# here used to say opencode had no such subcommand; as of opencode 1.2.10 it
# does -- `opencode mcp` offers `add`, `list`, `auth`, `logout`, `debug`.
# **Measured 2026-09-01: `opencode mcp add` takes no arguments at all.** It is
# an interactive wizard; run with stdin closed it prints `Enter MCP server
# name` and waits. There is nothing to pass a name and a command to.
#
# So the conclusion this file was written on is unchanged, **but its reason
# is not the one it used to give**, and the difference matters: somebody who
# reads `opencode mcp add` in the help and "fixes" this plugin to call it will
# produce a plugin that hangs until the host's `timeout_ms` kills it.
#
# **What opencode itself confirmed, which is the part nobody had checked.**
# Written by this plugin into a scratch `$HOME` and then read back by
# `opencode mcp list`:
#
#     ●  ✗ polter  failed
#          ENOENT: no such file or directory, posix_spawn '/opt/polter/polter'
#          /opt/polter/polter +mcp
#     └  1 server(s)
#
# It found the entry, understood `mcp` / `type` / `command`-as-a-list, and
# went as far as trying to spawn it -- the `ENOENT` is the fake path in the
# fixture, not a rejection. Until then every test of this shape had asked our
# own reader whether our own writer had written what we expected.
#
# **This one edits the user's file**, with all the care that requires -- see
# `polter_json_edit`. It is also the host whose
# shape is furthest from the rest: the key is `mcp`, not `mcpServers`, and an
# entry is an object with `type` and `command` as a list, not a `command`
# string with `args` beside it. Copying a sibling into this file produces a
# config opencode reads and silently ignores.
config() {
  printf '%s/.config/opencode/opencode.json' "$home"
}

# What the polter entry's `environment` carries besides the version, so that
# Polter's server can say which CLI started it -- the same marker the Codex
# and Antigravity plugins write, read by an adapter's `identify` (task 1777).
# opencode hands a local MCP server its whole environment with the entry's
# `environment` on top (`mcp/index.ts` at v1.2.10: `...process.env,
# ...mcp.environment`), so the terminal's socket and token reach `+mcp`
# anyway; what nothing in that environment says is "opencode".
POLTER_OPENCODE_MARKER=POLTER_AGENT_CLI

host_mcp_current() {
  polter_json_read "$(config)" \
    'env = (d.get("mcp") or {}).get("polter", {}).get("environment", {})
print(env.get("POLTER_REGISTERED", ""), env.get("POLTER_AGENT_CLI", ""))
print(" ".join((d.get("mcp") or {}).get("polter", {}).get("command", [])))'
}

# An entry this build wrote before it carried the marker is this build's,
# at this version, and cannot say which CLI it serves.
host_mcp_complete() {
  case "$1" in
    *" opencode"*) return 0 ;;
    *) return 1 ;;
  esac
}

host_mcp_register() {
  version=$1 version_key=$2 exe=$3 scope=$4

  POLTER_EXE=$exe POLTER_VER=$version POLTER_KEY=$version_key POLTER_MARK=$POLTER_OPENCODE_MARKER \
  polter_json_edit "$(config)" \
    'import os
d.setdefault("mcp", {})["polter"] = {
    "type": "local",
    "command": [os.environ["POLTER_EXE"], "+mcp"],
    "enabled": True,
    "environment": {
        os.environ["POLTER_KEY"]: os.environ["POLTER_VER"],
        os.environ["POLTER_MARK"]: "opencode",
    },
}'
}

# **Confirmed** (task 1777, opencode 1.2.10): a user's skills are
# `~/.config/opencode/{skill,skills}/**/SKILL.md` (`skill/skill.ts`,
# `OPENCODE_SKILL_PATTERN`), and this machine's opencode already keeps two
# there.
#
# ⚠️ **opencode reads `~/.claude/skills/**` as well**, so where the Claude
# Code plugin has mirrored Polter's skills it already sees them, and a copy
# here gives two files with one name. Measured with `opencode debug skill`
# in a scratch `$HOME`, one `polter-probe` in each directory: **one skill is
# listed, the copy here**, and opencode's log says `duplicate skill name`
# at WARN; nothing fails. (Only here: the one under `.claude`. Only under
# `.claude`: that one.) So it is installed unconditionally -- it wins over a
# Claude Code copy that may be another build's, and it is still there for a
# person who has no Claude Code plugin at all.
host_skills_dir() {
  printf '%s/.config/opencode/skills' "$home"
}

# **The first of three that exists, and only that one** (task 1777, opencode
# 1.2.10, `session/instruction.ts` `globalFiles`): `$OPENCODE_CONFIG_DIR/
# AGENTS.md`, then `~/.config/opencode/AGENTS.md`, then `~/.claude/CLAUDE.md`
# -- the loop breaks at the first file it finds.
#
# ⚠️ So **creating** `~/.config/opencode/AGENTS.md` would switch the person's
# `~/.claude/CLAUDE.md` off for opencode: everything they wrote there would
# stop reaching it, for the sake of our one paragraph. When opencode has no
# AGENTS.md of its own and does read a CLAUDE.md, nothing is written -- that
# CLAUDE.md is the Claude Code plugin's rules file, and with its `rules` on
# it already carries this block. Into an AGENTS.md that is already there, or
# into a new one when there is no CLAUDE.md to hide, the block goes as it
# does for every other host. (`OPENCODE_CONFIG_DIR` is a per-launch
# variable, not something this machine's provision can see.)
host_rules_file() {
  agents="$home/.config/opencode/AGENTS.md"
  if [ -f "$agents" ] || [ ! -f "$home/.claude/CLAUDE.md" ]; then
    printf '%s' "$agents"
  fi
}

polter_provision_main
