#!/bin/sh
# Tell Alibaba's Qwen Code that Polter is here.
#
# The implementation is in `_sdk/provision.sh`; this file is the answers.
# See docs/poltergeist/provisioning.md.

set -eu

. "$(dirname "$0")/../_sdk/provision.sh"

POLTER_HOST_KEY=qwen-code
POLTER_HOST_LABEL="Qwen Code"
POLTER_HOST_BIN=qwen

# **Qwen Code is a fork of gemini-cli**, so this file is nearly its sibling:
# `~/.qwen/settings.json`, key `mcpServers`, a `qwen mcp` subcommand of the
# same shape. That is not a coincidence to be pleased about -- it means an
# upstream change lands on Gemini CLI, Qwen Code and iFlow at once, and all
# three of these files break together. Whoever fixes one should check the
# other two.
host_mcp_current() {
  qwen mcp list 2>/dev/null | grep polter || true
}

host_mcp_register() {
  version=$1 version_key=$2 exe=$3 scope=$4

  qwen mcp remove polter >/dev/null 2>&1 || true
  qwen mcp add --scope user polter -e "$version_key=$version" -- "$exe" +mcp
}

# **Unverified.** Qwen Code advertises Skills, but its user-level directory is
# not stated in the documentation read on 2026-08-30. Printing nothing means
# MCP only, which is a degradation and not a failure -- the tools arrive, and
# the tool-family map in `initialize` arrives with them. Fill this in once
# somebody has checked it on a machine that has Qwen Code, and not before:
# writing files into a guessed directory is worse than writing none.
host_skills_dir() {
  printf ''
}

polter_provision_main
