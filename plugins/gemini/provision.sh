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
# **The staleness check reads the config file; registration still goes
# through the CLI.** Those are two different rules and only one of them was
# ever in force here.
#
# `gemini mcp list` cannot answer this question. It prints the command and
# its arguments -- `polter: /opt/polter/polter +mcp (stdio) - Disconnected` --
# and **never the environment**, which is where the version marker lives. It
# also prints that listing on **stderr**, so the old `2>/dev/null | grep`
# read an empty string no matter what. Either fault alone makes `stale`
# always yes; together they made this plugin **rewrite the user's settings on
# every single launch**, which is the exact race the read-before-write exists
# to prevent (`MCP server "polter" is already configured ... updated in user
# settings.` on run two, and every run after). Measured on gemini 0.33.1.
#
# **Reading their file is not writing it.** The rule this plugin follows is
# "the tool that owns the file knows how to edit it", and it still holds:
# `host_mcp_register` goes through `gemini mcp add` and nothing here ever
# writes a byte. Reading it to decide whether that call is needed at all is
# what `opencode` and `deepseek` already do for their half.
#
# **The degradation is the old behaviour.** `polter_json_read` prints nothing
# when there is no `python3`, when the file is missing, or when it does not
# parse -- all of which read as "not registered", which costs one redundant
# write and never a missed one. So this cannot be worse than what it
# replaces, which is why it was safe to apply to both forks at once.
# `python3` is deliberately **not** added to `wants.exec`: unlike `opencode`
# and `deepseek`, this plugin still works without it.
host_mcp_current() {
  polter_json_read "$home/.gemini/settings.json" \
    'p = (d.get("mcpServers") or {}).get("polter", {});
print(p.get("command", ""), (p.get("env") or {}).get("POLTER_REGISTERED", ""))'
}

host_mcp_register() {
  version=$1 version_key=$2 exe=$3 scope=$4

  # `remove` leaves a `"mcpServers": {}` behind in a file that had no such
  # key. Harmless to the CLI, and left alone on purpose: "the tool that owns
  # the file knows how to edit it" is the rule this plugin follows, and the
  # rule does not promise the tool puts everything back the way it found it.
  gemini mcp remove polter >/dev/null 2>&1 || true

  # **`-e` goes last, after the positional arguments, and it may not be moved.**
  #
  # `gemini mcp add` takes `<name> <command> [args...]`, and `-e` is an *array*
  # option. yargs makes an array option greedy -- it swallows every following
  # token that does not look like an option -- and `--` ends parsing, so what
  # comes after it is not counted as a positional either. Written the obvious
  # way:
  #
  #     gemini mcp add --scope user polter -e KEY=V -- "$exe" +mcp
  #
  # the parser sees exactly one positional and refuses the whole call:
  #
  #     Not enough non-option arguments: got 1, need at least 2
  #
  # **This was wrong on every platform from the day it was written.** It was
  # found while porting to Windows only because that is where one of these
  # plugins was first run against a real gemini; on macOS and Linux it had been
  # failing silently into `status=failed step=mcp` the whole time.
  #
  # **The cost of the fix, so nobody undoes it.** Dropping `--` means a
  # served-side argument that looks like an option would be read as one of
  # `gemini`'s. That is safe today only because `+mcp` begins with `+`.
  # **Whoever adds a flag on the served side has to come back here.**
  #
  # There may be a form that keeps both -- `-e=KEY=V` might not be greedy --
  # but it has not been measured, and a guess is what put this line here in the
  # first place.
  #
  # Measured on gemini 0.15.11, 2026-09-01: exit 0, and the entry it wrote was
  # read back and checked. An exit code alone would not have caught the original
  # either, because the original did exit non-zero -- what nothing checked was
  # that anybody ever ran it.
  gemini mcp add --scope user polter "$exe" +mcp -e "$version_key=$version"
}

host_skills_dir() {
  printf '%s/.gemini/skills' "$home"
}

polter_provision_main
