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
  rm -f "$POLTER_CODEX_STUCK"
  _s=0
  _out=$(codex_call /dev/null mcp get polter --json) || _s=$?
  if [ "$_s" -eq 124 ]; then return 124; fi
  if [ "$_s" -ne 0 ]; then
    _s=0
    _out=$(codex_call /dev/null mcp get polter) || _s=$?
    if [ "$_s" -eq 124 ]; then return 124; fi
  fi
  printf '%s' "$_out"
  return 0
}

# **Every `codex` this file runs is bounded** (task 1667). Signed in to a
# ChatGPT account in the test session, Codex sat in one of these subcommands
# for over three minutes, and provisioning sat with it: nothing written,
# nothing in the log. Inferred, not caught in the act: the subcommands load
# the same config the TUI does, and the TUI has been seen to wait on the
# network there ("workspace routing discovery timed out", task 1640).
#
# So each call gets `POLTER_CODEX_SECONDS`, its whole process group is stopped
# when that runs out (`polter_bounded`), the log says which call and that
# it was stopped, and **nothing more is asked of Codex in this batch** -- a
# CLI that did not answer one question is not going to answer the next, and
# four of them in a row would outlast the plugin's own deadline. The SDK
# then leaves the registration alone, does the rest, and reports `failed`,
# so Polter offers the whole thing again later.
POLTER_CODEX_SECONDS=8
POLTER_CODEX_STUCK="${TMPDIR:-/tmp}/polter-codex-stuck.$$"
trap 'rm -f "$POLTER_CODEX_STUCK"' EXIT

# `codex_call ERR ARG...`: `codex ARG...`, bounded; ERR as `polter_bounded`'s.
codex_call() {
  _err=$1
  shift
  if [ -e "$POLTER_CODEX_STUCK" ]; then return 124; fi
  _status=0
  polter_bounded "$POLTER_CODEX_SECONDS" "$_err" codex "$@" || _status=$?
  if [ "$_status" -eq 124 ]; then
    : >"$POLTER_CODEX_STUCK"
    say "\`codex $*\` did not answer within ${POLTER_CODEX_SECONDS}s and was stopped; nothing more is asked of codex this time"
  fi
  return "$_status"
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

# **Which CLI started the server** (#1667). Codex gives an MCP server nothing
# that says Codex -- not its name, not its session (measured on 0.163.0) --
# and a Polter that cannot tell what is running in a terminal cannot take it
# over (`identify`, plugins/codex/adapter.py). The entry's own `env` is the
# one thing that does reach the server, so it carries this. Only the name is
# matched in what `codex mcp get` prints: the plain form hides every value.
POLTER_CODEX_MARKER=POLTER_AGENT_CLI

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
  case "$1" in
    *"$POLTER_CODEX_MARKER"*) ;;
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
  # Nothing to remove is the common case, and fine; not answering is not.
  _s=0
  codex_call /dev/null mcp remove polter >/dev/null || _s=$?
  if [ "$_s" -eq 124 ]; then return 124; fi
  codex_call - mcp add polter --env "$version_key=$version" --env "$POLTER_CODEX_MARKER=codex" -- "$exe" +mcp || return $?
  codex_table_apply
}

# **Keeping a Codex typed by hand out of the shared daemon** (task 1674).
# Signed in to a ChatGPT account, a hand-started Codex runs its session in one
# app-server daemon shared by every terminal, and Polter cannot tell which
# terminal such a session belongs to: its sidecar refuses to act as any
# (src/cli/mcp.zig, `unclaimed`). `[features] daemon_auto_start = false`
# (Codex 0.163, a stable feature) keeps it in its own process instead, as
# `--no-daemon` does for a role launch. It is the person's global Codex
# setting, so it is a parameter, off unless they turn it on.
#
# **Only this one line, and only ours.** It carries a marker comment; turning
# the parameter off takes out the marked line and nothing else, and a
# `daemon_auto_start` the person wrote themselves is left as it is, either
# way, and said in the log.
POLTER_CODEX_DAEMON_MARK='# set by Polter: hand-started Codex stays out of the shared app-server daemon'

codex_want_no_daemon() {
  [ "$(polter_param manual_out_of_daemon no)" = yes ]
}

host_settings_apply() {
  f=$(codex_config)
  want=no
  codex_want_no_daemon && want=yes
  have=no
  theirs=no
  if [ -f "$f" ]; then
    grep -Fq "$POLTER_CODEX_DAEMON_MARK" "$f" && have=yes
    grep -v -F "$POLTER_CODEX_DAEMON_MARK" "$f" | grep -Eq '(^|[.[:space:]])daemon_auto_start[[:space:]]*=' && theirs=yes
  fi
  [ "$want" = "$have" ] && return 0
  if [ "$want" = yes ] && [ "$theirs" = yes ]; then
    say "daemon_auto_start: left alone, $f already sets it"
    return 0
  fi
  if [ "$want" = yes ]; then
    mkdir -p "$(dirname "$f")" || return 1
    [ -f "$f" ] || : >"$f" || return 1
  fi
  tmp="$f.polter-tmp"
  cp -p "$f" "$tmp" || return 1
  # A `[features]` table this made is marked as well, and goes again when
  # taking the line out leaves it empty; one the person had stays.
  if ! awk -v want="$want" -v line="daemon_auto_start = false $POLTER_CODEX_DAEMON_MARK" \
    -v head="[features] $POLTER_CODEX_DAEMON_MARK" -v mark="$POLTER_CODEX_DAEMON_MARK" '
    function flush() { if (blank) { print ""; blank = 0 } }
    { lines[++n] = $0 }
    END {
      for (i = 1; i <= n; i++) {
        l = lines[i]
        # One blank line is held back at a time -- the one right in front of
        # whatever comes next -- so it can go with a header of ours.
        if (l == "") { flush(); blank = 1; continue }
        if (index(l, mark) && l !~ /^[ \t]*\[/) continue
        if (index(l, mark) && l ~ /^[ \t]*\[/) {
          # Our own table: kept only if something other than our line is in it.
          if (want == "yes") { flush(); print l; print line; done = 1; continue }
          other = 0
          for (j = i + 1; j <= n && lines[j] !~ /^[ \t]*\[/; j++)
            if (lines[j] !~ /^[ \t]*(#.*)?$/ && !index(lines[j], mark)) other = 1
          # Gone with it: the one blank line put in front of it when it was
          # made (task 1674), so that taking it back gives the file back
          # byte for byte.
          if (other) { flush(); print l } else blank = 0
          continue
        }
        if (l ~ /^[ \t]*\[[ \t]*features[ \t]*\][ \t]*(#.*)?$/) {
          flush()
          print l
          if (want == "yes") { print line; done = 1 }
          continue
        }
        flush()
        print l
      }
      flush()
      if (want == "yes" && !done) { print ""; print head; print line }
    }
  ' "$f" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$f" || return 1
  wrote=yes
  # **The person's daemon is not stopped** (task 1674): it may be running
  # their sessions. The line says when the setting will start to count.
  if [ "$want" = yes ]; then
    say "daemon_auto_start: set to false; an app-server daemon already running is not stopped and keeps its sessions, so this takes effect once it has exited (or after signing in again or a restart)"
  else
    say "daemon_auto_start: taken back out"
  fi
  return 0
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


# A test that only wants the functions above (`test/codex-adapter/
# provision-settings.py`) sets this, and nothing is read from stdin.
[ "${POLTER_PROVISION_FUNCTIONS_ONLY:-}" = 1 ] || polter_provision_main
