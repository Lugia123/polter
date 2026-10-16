#!/bin/sh
# Tell OpenAI's Codex CLI that Polter is here.
#
# The implementation is in `_sdk/provision.sh`; this file is the answers.
# See dev-docs/poltergeist/provisioning.md.

set -eu

. "$(dirname "$0")/../_sdk/provision.sh"

POLTER_HOST_KEY=codex
POLTER_HOST_LABEL="Codex CLI"
POLTER_HOST_BIN=codex

# **Codex is the one that does not look like the others.** Its config is TOML
# at `~/.codex/config.toml` and its table is `mcp_servers`, with an
# underscore, where every other host in this directory uses JSON and
# `mcpServers`. Copying a sibling here produces a file Codex reads as empty
# and reports nothing about. `codex mcp` writes the entry; the two lines it
# has no flags for -- `env_vars` and the approval mode -- go into that
# entry's table and nowhere else (`codex_table_apply`). The difference is
# worth stating where
# somebody adding the next host will read it.
#
# **`--json`, because the plain form hides the one thing asked of it**
# (#1645). `codex mcp get` prints every env value as `*****`, so the version
# marker was never found in it: every start judged the entry stale and
# removed and re-added it, rewriting the user's config.toml each time and
# moving its `[mcp_servers.*]` tables about. The JSON form gives the values,
# and `env_vars` with them. A Codex too old for `--json` falls back to the
# plain form, which is the old behaviour and no worse.
host_mcp_current() {
  codex mcp get polter --json 2>/dev/null || codex mcp get polter 2>/dev/null || true
}

# **What Codex lets through to the server** (#1645). Codex hands an MCP
# server it starts a fixed short list of variables -- HOME, PATH, USER, LANG
# and a few more, measured -- plus what the entry's `env` sets. The two
# `+mcp` needs to find Polter are per terminal, so they cannot go in `env`;
# without them `+mcp` exits at once and every Polter tool fails in Codex.
# `env_vars` names variables to pass through from Codex's own environment,
# which is the terminal's. `+mcp` reads no others (src/cli/mcp.zig).
POLTER_CODEX_ENV_VARS='env_vars = ["GHOSTTY_POLTER_SOCKET", "GHOSTTY_POLTER_TOKEN"]'

# **Polter's own tools are not asked about one by one** (#1653). Codex's
# default for an MCP server's tools is `auto`, which asks before every call to
# a tool not annotated read-only -- and none of Polter's is -- so a worker
# stopped at "Allow the polter MCP server to run tool "me"?" before its first
# report, with nobody at the keyboard. `approve` is Codex's "never ask"
# (`requires_mcp_tool_approval_for_mode` in codex-rs/core/src/mcp_tool_call.rs).
# Set on the `polter` table only: the user's other servers and their global
# approval policy are not this plugin's to change. `approve_tools=no` takes
# the line back out.
POLTER_CODEX_APPROVE='default_tools_approval_mode = "approve"'

codex_want_approve() {
  [ "$(polter_param approve_tools yes)" = yes ]
}

# The lines of the `[mcp_servers.polter]` table itself, header excluded,
# straight from the file: `codex mcp get --json` does not carry the approval
# mode (0.163.0, measured), and the plain form hides the env values.
codex_polter_table() {
  f=$(codex_config)
  [ -f "$f" ] || return 0
  awk '
    /^[ \t]*\[/ { inside = ($0 ~ /^[ \t]*\[[ \t]*mcp_servers\.polter[ \t]*\][ \t]*$/); next }
    inside { print }
  ' "$f"
}

host_mcp_complete() {
  case "$1" in
    *'"env_vars"'*GHOSTTY_POLTER_SOCKET*GHOSTTY_POLTER_TOKEN*) ;;
    *) return 1 ;;
  esac
  approves=no
  codex_polter_table | grep -Eq "^[[:space:]]*default_tools_approval_mode[[:space:]]*=[[:space:]]*[\"']approve[\"']" && approves=yes
  if codex_want_approve; then [ "$approves" = yes ]; else [ "$approves" = no ]; fi
}

# Where Codex keeps it: `$CODEX_HOME`, else `~/.codex` -- the same rule
# `codex mcp add` followed when it wrote the entry.
codex_config() {
  printf '%s/config.toml' "${CODEX_HOME:-$home/.codex}"
}

# Put `env_vars`, and the approval mode when `approve_tools` is yes, into the
# `[mcp_servers.polter]` table `codex mcp add` has just written. `codex mcp
# add` has a flag for neither.
#
# **Inside that one table and nowhere else**: the line goes straight under
# its header, any `env_vars = ...` line already in it is dropped first, and
# every other line of the file is copied as it was. So the entry carries it,
# and `codex mcp remove polter` -- which deletes the table -- takes it away
# with nothing left behind. Written through a copy that keeps the file's mode
# and moved into place, so a reader never sees half a file.
codex_table_apply() {
  f=$(codex_config)
  if [ ! -f "$f" ]; then
    echo "no $f after \`codex mcp add\`" >&2
    return 1
  fi
  tmp="$f.polter-tmp"
  cp -p "$f" "$tmp" || return 1
  approve=
  if codex_want_approve; then approve=$POLTER_CODEX_APPROVE; fi
  if ! awk -v add="$POLTER_CODEX_ENV_VARS" -v approve="$approve" '
    /^[ \t]*\[/ {
      inside = ($0 ~ /^[ \t]*\[[ \t]*mcp_servers\.polter[ \t]*\][ \t]*$/)
      print
      if (inside) { print add; if (approve != "") print approve; found = 1 }
      next
    }
    inside && /^[ \t]*(env_vars|default_tools_approval_mode)[ \t]*=/ { next }
    { print }
    END { if (!found) exit 3 }
  ' "$f" >"$tmp"; then
    rm -f "$tmp"
    echo "no [mcp_servers.polter] table in $f to put env_vars in" >&2
    return 1
  fi
  mv "$tmp" "$f"
}

host_mcp_register() {
  version=$1 version_key=$2 exe=$3 scope=$4

  # `scope` is not passed on: Codex has no user/local split to pass it to.
  # Its user config is the only one `codex mcp add` writes, which is the
  # scope this plugin wants anyway.
  codex mcp remove polter >/dev/null 2>&1 || true
  codex mcp add polter --env "$version_key=$version" -- "$exe" +mcp || return 1
  codex_table_apply
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
