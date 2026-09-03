#!/bin/sh
# Tell Claude Code that Polter is here.
#
# Polter puts a socket path and a token in every terminal's environment, which
# is everything an agent needs to *reach* it. What that does not do is make the
# tools appear: an MCP client only loads servers it has been configured with,
# so an agent in a directory nobody registered has the socket, the token, and
# no way to use either.
#
# **The implementation lives in `_sdk/provision.sh`; this file is the
# answers.** That split is the point: "what shape does a runtime read" has a
# different answer for every agent CLI, and there are eight of them now. What
# they need is identical -- register a server, mirror the skills -- and only
# the shape differs, so only the shape belongs here. See
# `docs/poltergeist/provisioning.md`.

set -eu

. "$(dirname "$0")/../_sdk/provision.sh"

POLTER_HOST_KEY=claude-code
POLTER_HOST_LABEL="Claude Code"
POLTER_HOST_BIN=claude

# Registration goes through `claude mcp`, not through the file. The
# user-scoped config is `~/.claude.json`, which holds that user's entire Claude
# Code setup; parsing and re-serialising it to add one key would reformat the
# whole thing and reorder every key in it. The tool that owns the file knows
# how to edit it, so it is asked to.
host_mcp_current() {
  claude mcp get polter 2>/dev/null || true
}

# `add` refuses a name that is already there, so a stale entry goes first. A
# failure on the remove is ignored: the common case is that there was nothing
# to remove.
#
# `--` separates our arguments from the served command's, so a future flag on
# the served side cannot be read as one of ours.
host_mcp_register() {
  version=$1 version_key=$2 exe=$3 scope=$4

  claude mcp remove --scope "$scope" polter >/dev/null 2>&1 || true
  claude mcp add --scope "$scope" polter \
    -e "$version_key=$version" \
    -- "$exe" +mcp
}

host_skills_dir() {
  printf '%s/.claude/skills' "$home"
}

# The file this CLI reads on every turn. **User level, never a project
# file**: a project's CLAUDE.md belongs to whoever owns the repository, and
# Polter being installed on this machine is not a fact about their
# repository. The block is marked and is taken back out if the parameter
# is switched off; see `polter_rules_apply` in the SDK.
host_rules_file() {
  printf '%s/.claude/CLAUDE.md' "$home"
}

polter_provision_main
