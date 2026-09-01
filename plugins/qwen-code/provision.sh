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
# upstream change lands on Gemini CLI and Qwen Code at once, and both of
# these files break together. Whoever fixes one should check the other.
# (iFlow CLI was the third of this shape; its service closed on 2026-04-17
# and the plugin went with it.)
# **The staleness check reads the config file; registration still goes
# through the CLI.** Those are two different rules and only one of them was
# ever in force here.
#
# `qwen mcp list` cannot answer this question. It prints the command and
# its arguments -- `polter: /opt/polter/polter +mcp (stdio) - Disconnected` --
# and **never the environment**, which is where the version marker lives. It
# also prints that listing on **stderr**, so the old `2>/dev/null | grep`
# read an empty string no matter what. Either fault alone makes `stale`
# always yes; together they made this plugin **rewrite the user's settings on
# every single launch**, which is the exact race the read-before-write exists
# to prevent (`MCP server "polter" is already configured ... updated in user
# settings.` on run two, and every run after). **Not measured**: nobody has run `qwen mcp list` and looked. Qwen Code
# is a fork of gemini-cli and its `mcp` subcommand group has the same five
# verbs, so the same hole is expected -- but expected is not measured, and
# the only reason this change is safe to make unmeasured is the paragraph
# below.
#
# **Reading their file is not writing it.** The rule this plugin follows is
# "the tool that owns the file knows how to edit it", and it still holds:
# `host_mcp_register` goes through `qwen mcp add` and nothing here ever
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
  polter_json_read "$home/.qwen/settings.json" \
    'p = (d.get("mcpServers") or {}).get("polter", {});
print(p.get("command", ""), (p.get("env") or {}).get("POLTER_REGISTERED", ""))'
}

host_mcp_register() {
  version=$1 version_key=$2 exe=$3 scope=$4

  # `remove` leaves a `"mcpServers": {}` behind in a file that had no such
  # key. Harmless to the CLI, and left alone on purpose: "the tool that owns
  # the file knows how to edit it" is the rule this plugin follows, and the
  # rule does not promise the tool puts everything back the way it found it.
  qwen mcp remove polter >/dev/null 2>&1 || true

  # **`-e` goes last, after the positional arguments, and it may not be moved.**
  #
  # `qwen mcp add` takes `<name> <command> [args...]`, and `-e` is an *array*
  # option. yargs makes an array option greedy -- it swallows every following
  # token that does not look like an option -- and `--` ends parsing, so what
  # comes after it is not counted as a positional either. Written the obvious
  # way:
  #
  #     qwen mcp add --scope user polter -e KEY=V -- "$exe" +mcp
  #
  # the parser sees exactly one positional and refuses the whole call:
  #
  #     Not enough non-option arguments: got 1, need at least 2
  #
  # **This was wrong on every platform from the day it was written.** It was
  # found while porting to Windows only because that is where one of these
  # plugins was first run against a real qwen; on macOS and Linux it had been
  # failing silently into `status=failed step=mcp` the whole time.
  #
  # **The cost of the fix, so nobody undoes it.** Dropping `--` means a
  # served-side argument that looks like an option would be read as one of
  # `qwen`'s. That is safe today only because `+mcp` begins with `+`.
  # **Whoever adds a flag on the served side has to come back here.**
  #
  # There may be a form that keeps both -- `-e=KEY=V` might not be greedy --
  # but it has not been measured, and a guess is what put this line here in the
  # first place.
  #
  # Measured on qwen 0.15.11, 2026-09-01: exit 0, and the entry it wrote was
  # read back and checked. An exit code alone would not have caught the original
  # either, because the original did exit non-zero -- what nothing checked was
  # that anybody ever ran it.
  qwen mcp add --scope user polter "$exe" +mcp -e "$version_key=$version"
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
