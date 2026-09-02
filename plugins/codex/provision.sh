#!/bin/sh
# Tell OpenAI's Codex CLI that Polter is here.
#
# The implementation is in `_sdk/provision.sh`; this file is the answers.
# See docs/poltergeist/provisioning.md.

set -eu

. "$(dirname "$0")/../_sdk/provision.sh"

POLTER_HOST_KEY=codex
POLTER_HOST_LABEL="Codex CLI"
POLTER_HOST_BIN=codex

# **Codex is the one that does not look like the others.** Its config is TOML
# at `~/.codex/config.toml` and its table is `mcp_servers`, with an
# underscore, where every other host in this directory uses JSON and
# `mcpServers`. Copying a sibling here produces a file Codex reads as empty
# and reports nothing about. It is never written by hand anyway -- `codex mcp`
# owns that file -- but the difference is worth stating where somebody adding
# the next host will read it.
host_mcp_current() {
  codex mcp get polter 2>/dev/null || true
}

host_mcp_register() {
  version=$1 version_key=$2 exe=$3 scope=$4

  # `scope` is not passed on: Codex has no user/local split to pass it to.
  # Its user config is the only one `codex mcp add` writes, which is the
  # scope this plugin wants anyway.
  codex mcp remove polter >/dev/null 2>&1 || true
  codex mcp add polter --env "$version_key=$version" -- "$exe" +mcp
}

# Codex took the Agent Skills standard in January 2026 and looks in the same
# place the others do. It also reads an `openai.yaml` beside `SKILL.md` for UI
# metadata; we write none, and it is optional -- a skill without one loads.
host_skills_dir() {
  printf '%s/.codex/skills' "$home"
}

# The file this CLI reads on every turn. **User level, never a project
# file**: a project's AGENTS.md belongs to whoever owns the repository, and
# Polter being installed on this machine is not a fact about their
# repository. The block is marked and is taken back out if the parameter
# is switched off; see `polter_rules_apply` in the SDK.
host_rules_file() {
  printf '%s/.codex/AGENTS.md' "$home"
}

polter_provision_main
