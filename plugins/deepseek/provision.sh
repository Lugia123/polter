#!/bin/sh
# Tell DeepSeek-TUI that Polter is here.
#
# The implementation is in `_sdk/provision.sh`; this file is the answers.
# See docs/poltergeist/provisioning.md.
#
# **DeepSeek ships no CLI of its own.** V4-Pro is a model; the terminal agents
# for it are third-party, and this one targets DeepSeek-TUI, which is the one
# with a documented config path (`~/.deepseek/mcp.json`, the `deepseek`
# command). That makes this file different in kind from its siblings: every
# other host here is a vendor maintaining its own interface, and a third-party
# project can change its config shape without telling anybody. When it does,
# the breakage will look to a user exactly like Polter breaking. So this one
# is written to fail loudly and to say whose file it was reading.

set -eu

. "$(dirname "$0")/../_sdk/provision.sh"

POLTER_HOST_KEY=deepseek
POLTER_HOST_LABEL="DeepSeek-TUI"
POLTER_HOST_BIN=deepseek

config() {
  printf '%s/.deepseek/mcp.json' "$home"
}

host_mcp_current() {
  polter_json_read "$(config)" \
    'p = (d.get("mcpServers") or {}).get("polter", {});
print(p.get("command", ""), (p.get("env") or {}).get("POLTER_REGISTERED", ""))'
}

host_mcp_register() {
  version=$1 version_key=$2 exe=$3 scope=$4

  POLTER_EXE=$exe POLTER_VER=$version POLTER_KEY=$version_key \
  polter_json_edit "$(config)" \
    'import os
d.setdefault("mcpServers", {})["polter"] = {
    "command": os.environ["POLTER_EXE"],
    "args": ["+mcp"],
    "env": {os.environ["POLTER_KEY"]: os.environ["POLTER_VER"]},
}'
}

# DeepSeek-TUI documents no skills mechanism. MCP only, which the tool-family
# map in `initialize` and `skill_read` between them make workable.
host_skills_dir() {
  printf ''
}

polter_provision_main
