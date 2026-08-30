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

# **opencode has no `mcp add`, so this one edits the user's file**, with all
# the care that requires -- see `polter_json_edit`. It is also the host whose
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

polter_provision_main
