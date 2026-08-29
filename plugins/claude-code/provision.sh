#!/bin/sh
# Tell Claude Code that Polter is here.
#
# Polter puts a socket path and a token in every terminal's environment,
# which is everything an agent needs to *reach* it. What that does not do is
# make the tools appear: an MCP client only loads servers it has been
# configured with, so an agent in a directory nobody registered has the
# socket, the token, and no way to use either.
#
# This used to be Zig inside Polter itself. It is a plugin because "what
# shape does a runtime read" has a different answer for every agent CLI, and
# with it hard-coded there was nowhere for anybody to put the answer for
# theirs. Polter's side is the data; this file is the translation.
#
# Polter writes one line of JSON on stdin:
#
#   {"event":"provision","exe":"/path/to/polter","version":"1.2.3",
#    "version_key":"POLTER_REGISTERED","home":"/Users/you",
#    "skills":[{"name":"supervising","path":"/…/supervising.md"}],
#    "params":{"scope":"user","skills":"yes"}}
#
# Exit 0 means the runtime knows about Polter now. Anything else is put on
# the user's screen -- not in the log and not handed to the agent, because
# what failed here is the agent's tool surface and the agent is therefore
# the one party that will not get the message.

set -eu

line=$(cat)

# One value out of the line. Every key used here appears once, which is what
# makes this safe with sed rather than a JSON parser -- `sed` is greedy, so a
# repeated key would silently give the last one.
field() {
  printf '%s' "$line" | sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p"
}

exe=$(field exe)
version=$(field version)
version_key=$(field version_key)
home=$(field home)

scope=$(field scope)
[ -n "$scope" ] || scope=user

want_skills=$(field skills)
[ -n "$want_skills" ] || want_skills=yes

if [ -z "$exe" ] || [ -z "$home" ]; then
  echo "claude-code: the line from Polter had no exe or home in it" >&2
  exit 1
fi

# No Claude Code on this machine. **Not a failure**: the agent here may be
# something else entirely, and Polter works the same either way. Exiting
# non-zero would put a message on the screen of every user who does not use
# it, every launch.
if ! command -v claude >/dev/null 2>&1; then
  exit 0
fi

# --- the MCP server ---------------------------------------------------------
#
# Registration goes through `claude mcp`, not through the file. The
# user-scoped config is ~/.claude.json, which holds that user's entire Claude
# Code setup; parsing and re-serialising it to add one key would reformat the
# whole thing and reorder every key in it. The tool that owns the file knows
# how to edit it, so it is asked to.

# Read before writing. This file is rewritten by Claude Code itself while it
# runs, and rewriting it at every launch for no reason is asking for the one
# race that eats somebody's settings.
#
# The path alone would catch a move or a reinstall elsewhere but not a build
# whose arguments or protocol changed while living at the same path -- which
# is every in-place upgrade. The marker is what makes "written by a different
# build" visible.
current=$(claude mcp get polter 2>/dev/null || true)

stale=yes
case "$current" in
  *"$exe"*)
    case "$current" in
      *"$version"*) stale=no ;;
    esac
    ;;
esac

if [ "$stale" = yes ]; then
  # `add` refuses a name that is already there, so a stale entry goes first.
  # A failure here is ignored: the common case is that there was nothing to
  # remove.
  claude mcp remove --scope "$scope" polter >/dev/null 2>&1 || true

  # `--` separates our arguments from the served command's, so a future flag
  # on the served side cannot be read as one of ours.
  if ! claude mcp add --scope "$scope" polter \
      -e "$version_key=$version" \
      -- "$exe" +mcp >/dev/null 2>&1; then
    echo "claude-code: could not register the MCP server" >&2
    exit 1
  fi
fi

[ "$want_skills" = yes ] || exit 0

# --- the skills -------------------------------------------------------------
#
# Polter's skills are reachable through `skill_read`, which an agent has to
# think to call. Claude Code's own are found by the runtime and matched
# against what the user asked for -- which is why a supervisor told to mind
# some terminals reached for the subagent tool in its system prompt and never
# looked for `supervising` at all. Two mechanisms sharing a word; only one of
# them does any matching.
#
# Installed under `polter-`, so nothing the user wrote themselves is
# overwritten and `/polter-supervising` says where it came from.

skills=$(printf '%s' "$line" | sed -n 's/.*"skills":\[\([^]]*\)\].*/\1/p')
[ -n "$skills" ] || exit 0

status=0

# One object per line, so the loop below reads a whole skill at a time. The
# trailing newline matters: `read` at end of input without one returns false
# and the loop body never runs, which looks exactly like "no skills".
printf '%s\n' "$skills" | sed 's/},{/}\
{/g' | while IFS= read -r item; do
  name=$(printf '%s' "$item" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
  path=$(printf '%s' "$item" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')

  [ -n "$name" ] && [ -n "$path" ] || continue

  if [ ! -r "$path" ]; then
    echo "claude-code: no readable source for skill $name at $path" >&2
    exit 1
  fi

  dir="$home/.claude/skills/polter-$name"

  # The whole file, frontmatter and all -- a Claude Code skill without
  # frontmatter is not a skill it will load at all. An earlier version
  # installed bodies alone and produced five files that looked right in a
  # directory listing and did nothing.
  #
  # The name inside the frontmatter has to match the directory, or the
  # runtime lists it under a name the user cannot type. Rewritten in the
  # frontmatter only: a `name:` line in the prose is prose.
  rendered=$(awk '
    NR == 1 && $0 == "---" { fm = 1; print; next }
    fm == 1 && $0 == "---" { fm = 0; print; next }
    fm == 1 && /^name: / { sub(/^name: /, "name: polter-"); print; next }
    { print }
  ' "$path")

  # Written only when it differs. This runs at every start, and rewriting a
  # file the runtime may be reading, for no reason, is asking for the one
  # race that makes a skill vanish mid-session.
  if [ -f "$dir/SKILL.md" ]; then
    if [ "$rendered" = "$(cat "$dir/SKILL.md")" ]; then
      continue
    fi
  fi

  if ! mkdir -p "$dir"; then
    echo "claude-code: could not make $dir" >&2
    exit 1
  fi

  if ! printf '%s\n' "$rendered" > "$dir/SKILL.md"; then
    echo "claude-code: could not write the skill $name" >&2
    exit 1
  fi
done || status=1

exit "$status"
