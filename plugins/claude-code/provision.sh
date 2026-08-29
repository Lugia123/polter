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
# **It is resident, like every plugin now.** There is no `kind` any more:
# `"wants": {"events": ["provision"]}` in plugin.json is the whole of what
# makes this a provisioning plugin. So the shape is the one every plugin
# has -- a greeting, then a line of events, then one acknowledgement per
# line -- rather than a third contract of its own:
#
#   host -> {"hello":1,"plugin":"claude-code","cursor":0,
#            "events":["provision"],"groups":[],"calls":[],
#            "socket":"/…/polter-ab12.sock","token":"…",
#            "params":{"scope":"user","skills":"yes"}}
#   this -> {"ok":true}
#   host -> {"cursor":0,"through":3,"events":[
#              {"n":3,"kind":"provision","exe":"/path/to/polter",
#               "version":"1.2.3","version_key":"POLTER_REGISTERED",
#               "home":"/Users/you",
#               "skills":[{"name":"supervising","path":"/…/supervising.md"}]}]}
#   this -> {"ok":true}
#
# **What that cost, and it is a real one.** Exiting non-zero used to put a
# sentence on the user's screen while the first terminal was still being
# built. Nothing here is synchronous with a terminal opening any more, so a
# refusal reaches the person through Polter's log, through `plugin_list`'s
# note -- which says `backing_off` or `dormant` in so many words and which an
# agent can read -- and through `plugin_test`. What is gone is the unprompted
# line on the screen.
#
# What answering `{"ok":false}` still buys is the retry: the host backs off
# and offers the same event again, where a one-shot that exited non-zero was
# simply never run again until the next launch. A machine whose `claude` was
# being upgraded at the moment Polter started used to lose provisioning for
# the whole session.
#
# **Only acknowledgements may go to stdout.** Anything else is judged
# misconduct and the process is killed. Diagnostics go to stderr, which is
# Polter's log.

set -eu

# One value out of the line. Every key used here appears once, which is what
# makes this safe with sed rather than a JSON parser -- `sed` is greedy, so a
# repeated key would silently give the last one.
field() {
  printf '%s' "$line" | sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p"
}

# Everything the old one-shot did, now with a return code instead of an exit
# code. Nothing inside it changed: the same read-before-write, the same
# staleness marker, the same three checks before a stale skill is pruned.
provision() {
  line=$1

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
    return 1
  fi

  # No Claude Code on this machine. **Not a failure**: the agent here may be
  # something else entirely, and Polter works the same either way. Exiting
  # non-zero would put a message on the screen of every user who does not use
  # it, every launch.
  if ! command -v claude >/dev/null 2>&1; then
    return 0
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
      return 1
    fi
  fi

  [ "$want_skills" = yes ] || return 0

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
  [ -n "$skills" ] || return 0

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
      return 1
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
      return 1
    fi

    if ! printf '%s\n' "$rendered" > "$dir/SKILL.md"; then
      echo "claude-code: could not write the skill $name" >&2
      return 1
    fi
  done || status=1

  [ "$status" = 0 ] || return "$status"

  # --- skills that are no longer shipped --------------------------------------
  #
  # Installing without removing is not synchronising. A skill deleted from
  # Polter went on living in every machine that had ever been given it: the
  # three `mode-*` skills went with the work modes they described, and months
  # later were still in `~/.claude/skills/`, still being matched against what
  # users asked for, still telling agents to call a tool that no longer
  # exists. Nothing anywhere would ever have taken them away.
  #
  # **The `polter-` prefix is treated as this plugin's namespace**, not merely
  # as a way of avoiding collisions. That is a wider claim on the user's
  # directory than "we will not overwrite your files", and it is made
  # deliberately: the alternative -- deleting only entries carrying a marker
  # we started writing today -- cannot remove the three skills that prompted
  # this, which is to say it cannot fix the bug it was written for.
  #
  # Three checks narrow the claim to what this plugin actually writes. A
  # directory holding anything besides a single `SKILL.md`, or whose
  # frontmatter names something other than itself, is somebody else's and is
  # left alone even under the prefix.
  #
  # Pruning only ever runs after a clean install pass, and only when the line
  # actually parsed into a list of skills: an empty list is far more likely to
  # be a parse that failed than a release that ships nothing, and acting on it
  # would delete every skill on the machine.

  shipped=$(printf '%s\n' "$skills" | sed 's/},{/}\
  {/g' | sed -n 's/.*"name":"\([^"]*\)".*/polter-\1/p')

  [ -n "$shipped" ] || return 0

  for dir in "$home/.claude/skills"/polter-*; do
    [ -d "$dir" ] || continue

    base=${dir##*/}

    printf '%s\n' "$shipped" | grep -qxF "$base" && continue

    # Exactly one entry, and it is the file this plugin writes. A skill that
    # grew a `references/` or a script is not one of ours.
    [ "$(ls -A "$dir")" = "SKILL.md" ] || continue

    # And it calls itself what its directory calls it, which is a thing this
    # plugin guarantees on the way in.
    declared=$(awk '
      NR == 1 && $0 == "---" { fm = 1; next }
      fm == 1 && $0 == "---" { exit }
      fm == 1 && /^name: / { sub(/^name: /, ""); print; exit }
    ' "$dir/SKILL.md")
    [ "$declared" = "$base" ] || continue

    # Failure is not fatal. A skill that could not be removed is stale, which
    # is what it already was; taking the user's whole tool surface down over
    # it would be the worse trade.
    if rm -rf "$dir"; then
      echo "claude-code: removed $base, which Polter no longer ships" >&2
    else
      echo "claude-code: could not remove the stale skill $base" >&2
    fi
  done

  return 0
}

# --- the protocol -----------------------------------------------------------
#
# One acknowledgement per line the host writes, the greeting included. The
# host arms a deadline before each write and waits for a line back; a plugin
# that reads the greeting and then sits waiting for a batch is killed on
# `timeout_ms`, restarted, and killed again -- a restart loop that looks,
# from the plugin's side, exactly like idling.

# `printf` and nothing else on stdout, ever. Both `dash` and `bash` flush the
# shell's own output after each builtin, so a line written here is a line the
# host can read -- there is nothing to flush by hand and no way to do it in
# POSIX sh if there were.
ack() {
  printf '{"ok":%s}\n' "$1"
}

IFS= read -r hello || exit 0

case "$hello" in
  *'"hello"'*) ack true ;;
  *)
    echo "claude-code: the first line was not a handshake" >&2
    ack false
    exit 2
    ;;
esac

# The events. `provision` is the only kind this subscribes to, so anything
# else is passed over -- the host will not send one, and a plugin that trusts
# the host to filter is a plugin that breaks the day its subscription grows.
#
# An empty batch is a heartbeat: it proves this process is still here, and it
# gets the same yes as anything else.
while IFS= read -r batch; do
  [ -n "$batch" ] || continue

  case "$batch" in
    *'"kind":"provision"'*) ;;
    *)
      ack true
      continue
      ;;
  esac

  if provision "$batch"; then
    ack true
  else
    # "Not now", not misconduct. The host backs off and offers the same
    # event again, which is the whole thing being resident buys here.
    ack false
  fi
done

exit 0
