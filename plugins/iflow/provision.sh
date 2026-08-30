#!/bin/sh
# Tell iFlow CLI (心流) that Polter is here.
#
# The implementation is in `_sdk/provision.sh`; this file is the answers.
# See docs/poltergeist/provisioning.md.

set -eu

. "$(dirname "$0")/../_sdk/provision.sh"

POLTER_HOST_KEY=iflow
POLTER_HOST_LABEL="iFlow CLI"
POLTER_HOST_BIN=iflow

# `~/.iflow/settings.json`, key `mcpServers`, `iflow mcp add <name> <command>`.
# The third of the gemini-cli-shaped hosts; see the note in `qwen-code` about
# all three breaking together.
host_mcp_current() {
  iflow mcp list 2>/dev/null | grep polter || true
}

host_mcp_register() {
  version=$1 version_key=$2 exe=$3 scope=$4

  iflow mcp remove polter >/dev/null 2>&1 || true
  iflow mcp add polter -e "$version_key=$version" -- "$exe" +mcp
}

# iFlow's documentation has a Skill page whose contents were not read on
# 2026-08-30. **Unverified**, so nothing rather than a guess. See `qwen-code`.
host_skills_dir() {
  printf ''
}

polter_provision_main
