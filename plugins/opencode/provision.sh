#!/bin/sh
# Tell opencode that Polter is here.
#
# The implementation is in `_sdk/provision.sh`; this file is the answers.
# See docs/poltergeist/provisioning.md.

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

host_mcp_current() {
  polter_json_read "$(config)" \
    'print((d.get("mcp") or {}).get("polter", {}).get("environment", {}).get("POLTER_REGISTERED", ""));
print(" ".join((d.get("mcp") or {}).get("polter", {}).get("command", [])))'
}

host_mcp_register() {
  version=$1 version_key=$2 exe=$3 scope=$4

  POLTER_EXE=$exe POLTER_VER=$version POLTER_KEY=$version_key \
  polter_json_edit "$(config)" \
    'import os
d.setdefault("mcp", {})["polter"] = {
    "type": "local",
    "command": [os.environ["POLTER_EXE"], "+mcp"],
    "enabled": True,
    "environment": {os.environ["POLTER_KEY"]: os.environ["POLTER_VER"]},
}'
}

# **Unverified.** opencode is listed among the agents that took the Agent
# Skills standard, but its user-level directory was not confirmed on
# 2026-08-30. Nothing rather than a guess: MCP only is a degradation, files
# written into the wrong directory are litter on somebody's machine.
host_skills_dir() {
  printf ''
}

# **Nothing, on purpose.** This CLI may well read a rules file on every
# turn, but which one is a convention nobody here has checked -- and
# writing into the wrong file in somebody's home directory is worse than
# not writing. The sentence it would have carried is still reachable
# through `skill_read`. Fill this in once the convention is confirmed.
host_rules_file() {
  printf ''
}

polter_provision_main
