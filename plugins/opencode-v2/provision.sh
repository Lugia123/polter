#!/bin/sh
# Tell opencode that Polter is here.
#
# The implementation is in `_sdk/provision.sh`; this file is the answers.
# See dev-docs/poltergeist/provisioning.md.

set -eu

. "$(dirname "$0")/../_sdk/provision.sh"

# **`opencode`, not `opencode-v2`** (task 2237): the key is the host, and
# the host is opencode -- the same binary, the same `mcp` key, the same
# `~/.config/opencode/opencode.json`. What the split separates is which
# *version* a plugin declares it serves, and that is answered by the
# adapter's inventory (`serves`), not here. `inventory.zig`'s `Host` enum
# names hosts for the settings page's inventory rows, so this one is not
# added to it: it would be a second row over one file.
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
    'e = (d.get("mcp") or {}).get("polter")
# Nothing at all when there is no entry: any output reads as somebody
# else'"'"'s registration (`registration=other`, task 1930).
if not isinstance(e, dict):
    raise SystemExit(0)
env = e.get("environment") or {}
print(env.get("POLTER_REGISTERED", ""), env.get("POLTER_AGENT_CLI", ""))
print(" ".join(e.get("command") or []))'
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

# **Confirmed** (tasks 1777, 1806; opencode 2.0.32): a user's skills are
# `~/.config/opencode/{skill,skills}/**/SKILL.md`
# (`core/src/config/plugin/skill.ts`).
host_skills_dir() {
  printf '%s/.config/opencode/skills' "$home"
}

# ⚠️ **opencode reads `~/.claude/skills/**` as well**
# (`core/src/config/plugin/compatibility.ts`, unless the person's
# environment says `OPENCODE_DISABLE_CLAUDE_CODE`), so where the Claude Code
# plugin has mirrored Polter's skills it already sees them, and a copy here
# would be a second skill of one name. So when they are there, none go here,
# and the ones an earlier launch put here are taken back (task 1806: one
# copy, the Claude Code plugin's). Not switched off in opencode instead: that
# would hide the person's own Claude skills from it as well.
host_skills_shared_dir() {
  printf '%s/.claude/skills' "$home"
}

# `~/.config/opencode/AGENTS.md` (task 1806, opencode 2.0.32,
# `core/src/config/plugin/instruction.ts`): the person's rules file, read
# with every `AGENTS.md` found walking up from the project. **2.0 reads no
# `CLAUDE.md` at all**, so this file hides nothing of the person's by being
# there -- 1.x read the first of it and `~/.claude/CLAUDE.md`, which is why
# this used to stay away when there was a CLAUDE.md. Only the marked block
# is Polter's; everything outside it is left as it was.
host_rules_file() {
  printf '%s/.config/opencode/AGENTS.md' "$home"
}

polter_provision_main
