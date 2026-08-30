#!/bin/sh
# Provisioning, minus the part that differs per agent CLI.
#
# **What every host needs is the same; what every host reads is not.** Register
# an MCP server so Polter's tools appear, and mirror Polter's skills where that
# host looks for skills. The two jobs do not change. The shape of the answer
# changes for every CLI, and that is the whole of what a host plugin says.
#
# So this file is the implementation and a host plugin is a declaration:
#
#   #!/bin/sh
#   set -eu
#   . "$(dirname "$0")/../_sdk/provision.sh"
#
#   POLTER_HOST_KEY=codex
#   POLTER_HOST_LABEL="Codex CLI"
#   POLTER_HOST_BIN=codex
#
#   host_mcp_current()  { codex mcp get polter 2>/dev/null || true; }
#   host_mcp_register() { codex mcp add polter --env "$2=$1" -- "$3" +mcp; }
#   host_skills_dir()   { printf '%s/.codex/skills' "$home"; }
#
#   polter_provision_main
#
# **Each host stays its own plugin, sharing this rather than being merged into
# one.** A single plugin with a table of hosts would take all of them down with
# the first failure, and its `wants.exec` would have to name every binary --
# every machine declaring the seven CLIs it does not have. What is shared here
# is the implementation, not the identity.
#
# **POSIX `sh`.** Same reasoning as the plugins that source it: Ghostty builds
# no application on Windows (`apprt.Runtime.default` answers `.none`), so there
# is no plugin host there for this to fail in.

# --- what a host must define ------------------------------------------------
#
#   POLTER_HOST_KEY      short name, used as the log prefix
#   POLTER_HOST_LABEL    what a person calls it, used in notifications
#   POLTER_HOST_BIN      the binary whose presence means "this host is here"
#
#   host_mcp_current()   prints the current registration, empty if none.
#                        Only ever tested for substrings, so any format does.
#   host_mcp_register()  $1 version  $2 version_key  $3 exe  $4 scope
#                        Registers; non-zero means it failed.
#   host_skills_dir()    prints the user-level skills directory, using $home.
#                        **Printing nothing means this host has no skills**,
#                        which is a degradation and not a failure: the tools
#                        still arrive, and the tool-family map in `initialize`
#                        arrives with them. See docs/poltergeist/provisioning.md.

# One value out of the line. Every key used here appears once, which is what
# makes this safe with sed rather than a JSON parser -- `sed` is greedy, so a
# repeated key would silently give the last one.
field() {
  printf '%s' "$line" | sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p"
}

say() {
  echo "$POLTER_HOST_KEY: $*" >&2
}

# **Three states, and they used to be two.**
#
# `claude-code` returned silently when its binary was missing, which was right
# while it was the only one: the agent on this machine may be something else.
# With eight of these, every machine has six or seven plugins quietly doing
# nothing, and in the log "you do not have this CLI" and "you have it and the
# registration failed" read identically. That is the shape the Dock-launch bug
# hid in for months.
#
# So the state is named, every time, in a form somebody can grep:
#
#   absent       the binary is not on PATH. Not a problem, say so once.
#   provisioned  something was actually written. Silent when nothing changed.
#   failed       the binary is here and a step did not work. The user is told.
#
# `failed` is the only one that reaches a person unprompted, and it goes
# through `polter_tell`, which means it must be written before the batch is
# acknowledged. See `_sdk/polter.sh`.
polter_tell() {
  printf '{"tell":"%s"}\n' "$(
    printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
  )"
}

fail() {
  say "status=failed step=$1 -- $2"
  polter_tell "$POLTER_HOST_LABEL: $2. Polter's tools will not appear in it until this is fixed."
  return 1
}

# --- editing a config file, for the hosts with no `mcp add` -----------------
#
# **This is the other kind of host, and it is not the same job wearing a
# different hat.** A CLI with an `mcp add` subcommand owns its own file: its
# format, its locking, its migrations are its problem. A host without one
# makes them ours. opencode and DeepSeek-TUI are in that position.
#
# So the three properties that make it survivable are here rather than copied
# into each of them:
#
#   1. **A file that does not parse is never written.** Overwriting somebody's
#      config because we could not read it is the one outcome worth refusing
#      outright -- it is unrecoverable and it is our fault.
#   2. **The write is atomic.** Temp file beside the target, then rename. A
#      half-written config is a CLI that will not start.
#   3. **A missing file is an empty object, not an error.** First run on a
#      machine that has the CLI installed and never configured it.
#
# `python3` does the parsing. Hand-rolling JSON edits in `sed` is how a config
# acquires a trailing comma at 3am, and this is a user's file. When it is not
# there, this fails loudly rather than falling back to something clever: an
# agent CLI without Polter's tools is a disappointment, and a mangled config
# is a broken machine.
#
# $1 target file. $2 python source, run with `d` bound to the parsed object;
# whatever it leaves in `d` is written back.
polter_json_edit() {
  target=$1 code=$2

  if ! command -v python3 >/dev/null 2>&1; then
    say "status=failed step=mcp -- no python3, and this host has no \`mcp add\` to use instead"
    polter_tell "$POLTER_HOST_LABEL: registering needs python3 to edit $target safely, and there is none on PATH."
    return 1
  fi

  mkdir -p "$(dirname "$target")" || return 1

  python3 - "$target" <<PYEOF
import json, os, sys, tempfile

path = sys.argv[1]

if os.path.exists(path):
    with open(path, encoding="utf-8") as fh:
        raw = fh.read()
    if raw.strip():
        try:
            d = json.loads(raw)
        except Exception as e:
            # Refused, not repaired. See property 1 above.
            sys.stderr.write("cannot parse %s (%s); refusing to overwrite it\n" % (path, e))
            sys.exit(1)
    else:
        d = {}
else:
    d = {}

if not isinstance(d, dict):
    sys.stderr.write("%s is not a JSON object; refusing to overwrite it\n" % path)
    sys.exit(1)

$code

# Beside the target so the rename stays on one filesystem.
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(d, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, path)
except Exception:
    os.unlink(tmp)
    raise
PYEOF
}

# Read one value back out, for the staleness test. Prints nothing when the
# file is missing or unreadable, which reads as "not registered" -- the safe
# direction, because it costs one redundant write and never a missed one.
polter_json_read() {
  target=$1 code=$2
  command -v python3 >/dev/null 2>&1 || return 0
  [ -f "$target" ] || return 0
  python3 - "$target" 2>/dev/null <<PYEOF || true
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    raise SystemExit(0)
$code
PYEOF
}

# --- the work ---------------------------------------------------------------

polter_provision() {
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
    say "status=failed step=parse -- the line from Polter had no exe or home in it"
    return 1
  fi

  if ! command -v "$POLTER_HOST_BIN" >/dev/null 2>&1; then
    say "status=absent -- no \`$POLTER_HOST_BIN\` on PATH ($PATH). Nothing to do; not an error."
    return 0
  fi

  wrote=no
  note=

  # --- the MCP server -------------------------------------------------------
  #
  # Read before writing. These files are rewritten by the CLI that owns them
  # while it runs, and rewriting one at every launch for no reason is asking
  # for the one race that eats somebody's settings.
  #
  # The path alone would catch a move or a reinstall elsewhere but not a build
  # whose arguments or protocol changed while living at the same path -- which
  # is every in-place upgrade. The version marker is what makes "written by a
  # different build" visible, and it is why `host_mcp_register` is handed the
  # key and the value rather than being trusted to invent one.
  current=$(host_mcp_current)

  stale=yes
  case "$current" in
    *"$exe"*)
      case "$current" in
        *"$version"*) stale=no ;;
      esac
      ;;
  esac

  if [ "$stale" = yes ]; then
    # **stdout is discarded; stderr is not.** A CLI's chatter on success is
    # noise, but the sentence explaining a failure is the only useful thing
    # in the whole exchange -- and for the hosts whose registration is a
    # config edit, it is the difference between "could not register" and
    # "your opencode.json has a syntax error on line 12". Swallowing both
    # streams threw that away, which was found the first time this file
    # refused a broken config and said nothing about why.
    if ! host_mcp_register "$version" "$version_key" "$exe" "$scope" >/dev/null; then
      fail mcp "could not register the MCP server"
      return 1
    fi
    wrote=yes
  fi

  [ "$want_skills" = yes ] || { polter_provision_done; return 0; }

  skills_dir=$(host_skills_dir)
  if [ -z "$skills_dir" ]; then
    # Not a failure: somebody reading this log should be able to tell "this
    # host has no skills" from "the skills step broke". But it is carried on
    # `note` rather than said here, because a line printed at every launch is
    # a line nobody reads -- and with eight of these plugins it is eight of
    # them per launch. It surfaces only alongside a write that happened.
    note=" skills=unsupported -- MCP only; the tool map in \`initialize\` and \`skill_read\` cover it"
    polter_provision_done
    return 0
  fi

  # --- the skills -----------------------------------------------------------
  #
  # Polter's skills are reachable through `skill_read`, which an agent has to
  # think to call. A host's own skills are found by its runtime and matched
  # against what the user asked for -- which is why a supervisor told to mind
  # some terminals reached for a subagent and never looked for `supervising`.
  # Two mechanisms sharing a word; only one of them does any matching.
  #
  # Installed under `polter-`, so nothing the user wrote is overwritten and
  # `/polter-supervising` says where it came from.

  skills=$(printf '%s' "$line" | sed -n 's/.*"skills":\[\([^]]*\)\].*/\1/p')
  [ -n "$skills" ] || { polter_provision_done; return 0; }

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
      say "status=failed step=skills -- no readable source for skill $name at $path"
      return 1
    fi

    dir="$skills_dir/polter-$name"

    # The whole file, frontmatter and all -- a skill without frontmatter is
    # not one any of these runtimes will load. An earlier version installed
    # bodies alone and produced files that looked right in a directory
    # listing and did nothing.
    #
    # The name inside the frontmatter has to match the directory, or the
    # runtime lists it under a name the user cannot type. Rewritten in the
    # frontmatter only: a `name:` line in the prose is prose.
    #
    # **And it is stamped with the build that wrote it.** `version: 1` in
    # these files is hand-written and never changes, so an installed skill
    # could not say which Polter it came from. That is the same gap the
    # version key exists for on the MCP side, and it closes its own loop: the
    # stamp is part of the contents, so a new build changes the contents, so
    # the "written only when it differs" test below fires by itself. Nothing
    # separate has to notice that an install went stale -- and a separate
    # staleness check maintained by hand is the next thing that would rot.
    #
    # The cost, so nobody reads it as a bug: every new build rewrites all the
    # skills once, on the first launch after the upgrade, even when not a word
    # of prose changed. It did come from a different build.
    #
    # Only the installed copy is stamped. The file under
    # `src/poltergeist/skills/` and the one in the bundle stay byte for byte
    # identical, because a diff between them is how anybody checks what a
    # release actually shipped.
    rendered=$(awk -v build="$version" '
      NR == 1 && $0 == "---" { fm = 1; print; next }
      fm == 1 && $0 == "---" {
        if (build != "") print "polter-build: " build
        fm = 0
        print
        next
      }
      fm == 1 && /^polter-build: / { next }
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
      say "status=failed step=skills -- could not make $dir"
      return 1
    fi

    if ! printf '%s\n' "$rendered" > "$dir/SKILL.md"; then
      say "status=failed step=skills -- could not write the skill $name"
      return 1
    fi
  done || status=1

  if [ "$status" != 0 ]; then
    polter_tell "$POLTER_HOST_LABEL: Polter's skills could not be installed. The agent will still have the tools, but will be far less likely to reach for them."
    return "$status"
  fi

  # --- skills that are no longer shipped ------------------------------------
  #
  # Installing without removing is not synchronising. A skill deleted from
  # Polter went on living in every machine that had ever been given it: the
  # three `mode-*` skills went with the work modes they described, and months
  # later were still installed, still being matched against what users asked
  # for, still telling agents to call a tool that no longer exists. Nothing
  # anywhere would ever have taken them away.
  #
  # **The `polter-` prefix is treated as this plugin's namespace**, not merely
  # as a way of avoiding collisions. That is a wider claim on the user's
  # directory than "we will not overwrite your files", and it is made
  # deliberately: the alternative -- deleting only entries carrying a marker
  # we started writing today -- cannot remove the skills that prompted this,
  # which is to say it cannot fix the bug it was written for.
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

  [ -n "$shipped" ] || { polter_provision_done; return 0; }

  for dir in "$skills_dir"/polter-*; do
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
      say "removed $base, which Polter no longer ships"
      wrote=yes
    else
      say "could not remove the stale skill $base"
    fi
  done

  polter_provision_done
  return 0
}

# Said only when something was actually written. This runs at every launch,
# and a line per launch per host is eight lines of nothing in every log.
polter_provision_done() {
  [ "$wrote" = yes ] || return 0
  say "status=provisioned${note:-}"
}

# --- the protocol -----------------------------------------------------------
#
# One acknowledgement per line the host writes, the greeting included. The
# host arms a deadline before each write and waits for a line back; a plugin
# that reads the greeting and then sits waiting for a batch is killed on
# `timeout_ms`, restarted, and killed again -- a restart loop that looks, from
# the plugin's side, exactly like idling.
#
# **Only acknowledgements and reports may go to stdout.** Anything else is
# judged misconduct and the process is killed. Diagnostics go to stderr, which
# is this plugin's log.
#
# `printf` and nothing else on stdout, ever. Both `dash` and `bash` flush the
# shell's own output after each builtin, so a line written here is a line the
# host can read -- there is nothing to flush by hand and no way to do it in
# POSIX sh if there were.
ack() {
  printf '{"ok":%s}\n' "$1"
}

polter_provision_main() {
  IFS= read -r hello || exit 0

  case "$hello" in
    *'"hello"'*) ack true ;;
    *)
      say "the first line was not a handshake"
      ack false
      exit 2
      ;;
  esac

  # `provision` is the only kind this subscribes to, so anything else is
  # passed over -- the host will not send one, and a plugin that trusts the
  # host to filter is a plugin that breaks the day its subscription grows.
  #
  # An empty batch is a heartbeat: it proves this process is still here, and
  # it gets the same yes as anything else.
  while IFS= read -r batch; do
    [ -n "$batch" ] || continue

    case "$batch" in
      *'"kind":"provision"'*) ;;
      *)
        ack true
        continue
        ;;
    esac

    if polter_provision "$batch"; then
      ack true
    else
      # "Not now", not misconduct. The host backs off and offers the same
      # event again, which is the whole thing being resident buys here: a
      # machine whose CLI was being upgraded at the moment Polter started
      # used to lose provisioning for the entire session.
      ack false
    fi
  done

  exit 0
}
