#!/bin/sh
# Tell Google's Gemini CLI that Polter is here.
#
# The implementation is in `_sdk/provision.sh`; this file is the answers.
# See docs/poltergeist/provisioning.md.

set -eu

. "$(dirname "$0")/../_sdk/provision.sh"

POLTER_HOST_KEY=gemini
POLTER_HOST_LABEL="Gemini CLI"
POLTER_HOST_BIN=gemini

# `~/.gemini/settings.json`, key `mcpServers`. Written through the CLI rather
# than by hand for the reason every host here is: that file holds the user's
# whole setup, and re-serialising it to add one key reorders all of it.
host_mcp_current() {
  gemini mcp list 2>/dev/null | grep polter || true
}

host_mcp_register() {
  version=$1 version_key=$2 exe=$3 scope=$4

  gemini mcp remove polter >/dev/null 2>&1 || true
  gemini mcp add --scope user polter -e "$version_key=$version" -- "$exe" +mcp
}

host_skills_dir() {
  printf '%s/.gemini/skills' "$home"
}

polter_provision_main
