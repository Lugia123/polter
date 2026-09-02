#!/bin/sh
# Tell Moonshot's Kimi CLI that Polter is here.
#
# The implementation is in `_sdk/provision.sh`; this file is the answers.
# See docs/poltergeist/provisioning.md.

set -eu

. "$(dirname "$0")/../_sdk/provision.sh"

POLTER_HOST_KEY=kimi
POLTER_HOST_LABEL="Kimi CLI"
POLTER_HOST_BIN=kimi

# Kimi keeps TOML config and has a `kimi mcp` subcommand group. The exact
# flags below come from its documentation and have not been run against a real
# install; the failure they would produce is loud (`status=failed step=mcp`
# plus a notification), which is the point of it being loud.
host_mcp_current() {
  kimi mcp list 2>/dev/null | grep polter || true
}

host_mcp_register() {
  version=$1 version_key=$2 exe=$3 scope=$4

  kimi mcp remove polter >/dev/null 2>&1 || true
  kimi mcp add polter --env "$version_key=$version" -- "$exe" +mcp
}

# **Unverified**, so nothing rather than a guess. See `qwen-code`.
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
