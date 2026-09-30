#!/bin/sh
# Start a second, isolated Polter for a GUI test on a Mac where the user's own
# Polter is running -- and refuse to start one that cannot be isolated.
#
#     tools/mac-test-instance.sh <path/to/Polter.app> [<args for -e ...>]
#
# Extra config flags for the instance (they must come before `-e`, so they
# cannot ride in the command): MAC_TEST_EXTRA_FLAGS='--copy-on-select=false'.
# This is how a floor breaks one thing on purpose without a rebuild.
#
# Default command is `-e /bin/sh`. Prints `pid=`, `state=`, `socket=` and
# `bundle=` lines; everything the test does afterwards should name that pid
# (see tools/mac-drive.sh, tools/mac-hid.swift) and nothing else.
#
# What each step keeps out of the user's session, all measured 2026-09-26
# (#832):
#
# 1. **Bundle id must not be the user's.** AppKit keeps restorable window
#    state per bundle id (the `com.apple.appkit.restoration_storage` service;
#    there is no `~/Library/Saved Application State` on this machine), and
#    UserDefaults are per bundle id too. A `.debug` build restores the last
#    *test* instance's windows -- measured with a marker directory. A Release
#    build is `com.lugia.polter`, the user's own id: it would restore the
#    user's windows and write its own back over them. So that is refused here,
#    before anything runs, not detected afterwards. There is no override.
# 2. **`XDG_STATE_HOME` points at a fresh temporary directory.** Otherwise the
#    instance shares `~/.local/state/polter` with the user: it reads
#    `session.json` (the ⌘⇧T stack) and writes it on supervisor events, and
#    its chat, task and archive logs land beside the user's. It must be
#    **short**: the agent socket lives under it and AF_UNIX paths stop at 104
#    bytes. Under a long temporary directory it was 150 and the instance came up
#    without its RPC (`could not open the agent socket err=error.PathTooLong`)
#    -- up, and looking fine.
# 3. **`--window-save-state=never`**: no restore at launch at all. Log line:
#    `skip restoration: window-save-state=never`.
# 4. **`--poltergeist-register-mcp=false`**, and the user's
#    `mcpServers.polter` entry in `~/.claude.json` compared whole before and
#    after. Not its sha (other sessions write that file all the time) and not
#    its mtime.
# 5. **Inherited `GHOSTTY_*` / `POLTER_*` / `CLAUDE*` dropped**: a shell inside
#    the user's Polter carries the user's socket and token. `CLAUDE*` (no
#    underscore required: `CLAUDECODE=1` is one of them) is what a Claude Code
#    session exports to the commands it runs -- `CLAUDE_CODE_SESSION_ID`,
#    `CLAUDE_CODE_CHILD_SESSION`, its messaging socket and token. Started from
#    inside a session, the instance handed them on to the claude in its own
#    terminal, which then ran as a child of the session that started the
#    instance and wrote no transcript of its own (test-mac, 2026-09-28: run 1
#    was void because of it, #880).
# 6. **The config is a file of its own**, `<state>/config/polter/isolated-test.polter`,
#    given as `GHOSTTY_CONFIG_PATH` (and `XDG_CONFIG_HOME=<state>/config`).
#    Without it, ⌘, (open_config) opened the *user's* config in TextEdit
#    (#830, 2026-09-27). Isolating XDG_CONFIG_HOME alone does not stop that:
#    on macOS open_config tries Application Support first
#    (`src/config/edit.zig` configPathCandidates), that path is built from the
#    core's compile-time bundle id (not the app's Info.plist) -- the user's directory
#    even for a `.debug` build -- and when no candidate exists it *creates*
#    one. With GHOSTTY_CONFIG_PATH set the Swift side loads only that file
#    (`Config(at:)`, no default files) and ⌘, opens it; the candidate search
#    never runs. The odd filename is on purpose: a window titled
#    `config.polter` would not say which one was opened.
#    The role library follows the same variable: under it the core keeps
#    `personas.json` beside that file (`PersonaStore.defaultPath`), so the
#    instance's roles are `<state>/config/polter/personas.json`, not the
#    user's (#976; before it they were the user's, isolation or not).
# 7. **`--config-default-files=false`** stays as a second guard behind 6: it
#    is from before 6 existed (9bc1ef038), and it still keeps the user's
#    default files out if a build ever ignores GHOSTTY_CONFIG_PATH. Until
#    #981 it also threw away the isolated file itself -- the core counted
#    everything loaded before the command line as "default files" -- so the
#    instance ran on no config: config errors never showed and the settings
#    form's writes had no effect. The core now keeps a file the host loaded
#    in place of the default ones (`Config.discardDefaultFiles`), so
#    MAC_TEST_EXTRA_FLAGS='--config-default-files=true' is no longer needed.
#
# ⚠️ What this does not stop: launching activates the new app, so it takes
# the foreground from whoever was using the machine -- the user, if they are
# there. This script gives the foreground back to whichever app had it, as
# soon as the new instance has a window, and prints how long it held it. The
# gap is not zero; keystrokes typed into it go to the test instance.
set -eu

die() { printf 'mac-test-instance: %s\n' "$*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: mac-test-instance.sh <path/to/Polter.app> [<args for -e ...>]"
app=$1
shift
[ $# -gt 0 ] || set -- /bin/sh

plist="$app/Contents/Info.plist"
exe="$app/Contents/MacOS/polter"
[ -f "$plist" ] || die "no Info.plist at $plist"
[ -x "$exe" ] || die "no executable at $exe"
case "$(cd "$app" && pwd -P)" in
    /Applications/*) die "refusing: $app is an installed copy, not a build under test" ;;
esac

# --- 1. The bundle id gate. -------------------------------------------------
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null) \
    || die "could not read CFBundleIdentifier from $plist"
[ -n "$bundle" ] || die "empty CFBundleIdentifier in $plist"
installed=""
if [ -f /Applications/Polter.app/Contents/Info.plist ]; then
    installed=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/Polter.app/Contents/Info.plist 2>/dev/null || true)
fi
if [ "$bundle" = "com.lugia.polter" ] || [ "$bundle" = "$installed" ]; then
    die "refusing: $app has bundle id '$bundle', the same as the user's Polter; it would restore and overwrite the user's windows and share their defaults. Test a Debug build (com.lugia.polter.debug)."
fi

# --- 2. Short state directory. ----------------------------------------------
# A restart test has to come back to the same state directory: projects and
# the session live there, and a fresh one per launch would make "still bound
# after a restart" fail for the method's sake. MAC_TEST_STATE_DIR reuses one,
# and only one this script made (under /tmp/polter-test.*).
if [ -n "${MAC_TEST_STATE_DIR-}" ]; then
    case "$MAC_TEST_STATE_DIR" in
        /tmp/polter-test.*) ;;
        *) die "MAC_TEST_STATE_DIR must be a directory this script made (/tmp/polter-test.*), got $MAC_TEST_STATE_DIR" ;;
    esac
    [ -d "$MAC_TEST_STATE_DIR" ] || die "no such state directory: $MAC_TEST_STATE_DIR"
    state=$MAC_TEST_STATE_DIR
else
    state=$(mktemp -d /tmp/polter-test.XXXX) || die "mktemp failed"
fi
probe="$state/polter/polter-0123456789abcdef.sock"
[ "${#probe}" -lt 104 ] || die "state directory $state is too long for an AF_UNIX socket (${#probe} bytes)"

# --- 6. A config file of the instance's own. --------------------------------
config_file="$state/config/polter/isolated-test.polter"
mkdir -p "$state/config/polter" || die "could not create $state/config/polter"
[ -f "$config_file" ] || printf '# Config of a test instance started by tools/mac-test-instance.sh.\n# Isolated on purpose; nothing here is the user'"'"'s.\n' > "$config_file" \
    || die "could not write $config_file"

# --- 4. The user's MCP registration, before. --------------------------------
mcp_entry() {
    python3 -c 'import json,os;print(json.dumps(json.load(open(os.path.expanduser("~/.claude.json"))).get("mcpServers",{}).get("polter"),sort_keys=True))'
}
mcp_before=$(mcp_entry) || die "could not read ~/.claude.json"

front_pid() { lsappinfo info -only pid "$(lsappinfo front)" 2>/dev/null | sed 's/[^0-9]//g'; }
was_front=$(front_pid)

# --- 3, 5. Start it. --------------------------------------------------------
for v in $(env | cut -d= -f1 | grep -E '^(GHOSTTY_|POLTER_|CLAUDE)' || true); do unset "$v"; done
XDG_STATE_HOME=$state XDG_CONFIG_HOME="$state/config" GHOSTTY_CONFIG_PATH="$config_file" nohup "$exe" \
    --poltergeist-register-mcp=false \
    --config-default-files=false \
    --window-save-state=never \
    ${MAC_TEST_EXTRA_FLAGS-} \
    -e "$@" >"$state/stdout.log" 2>&1 &
pid=$!
start=$(date +%s)

kill_it() { kill -9 "$pid" 2>/dev/null || true; }

# Wait for a window (the app is not usable, and not in front, before that).
has_window() {
    osascript -l JavaScript - "$pid" <<'EOF'
ObjC.import('CoreGraphics');
function run(argv) {
  const pid = parseInt(argv[0], 10);
  const l = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0));
  for (let i = 0; i < l.count; i++) {
    const w = l.objectAtIndex(i);
    if (w.objectForKey('kCGWindowOwnerPID').js === pid && w.objectForKey('kCGWindowLayer').js === 0) return 'yes';
  }
  return 'no';
}
EOF
}
i=0
until [ "$(has_window)" = yes ]; do
    kill -0 "$pid" 2>/dev/null || die "pid $pid exited before opening a window; see $state/stdout.log"
    i=$((i + 1))
    [ $i -lt 60 ] || { kill_it; die "pid $pid opened no window in 30s (display asleep?); killed"; }
    sleep 0.5
done

# Give the foreground back.
now_front=$(front_pid)
if [ "$now_front" = "$pid" ] && [ -n "$was_front" ] && [ "$was_front" != "$pid" ]; then
    osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($was_front).activateWithOptions(0);" >/dev/null 2>&1 || true
    printf 'foreground: taken from pid %s for ~%ss, given back\n' "$was_front" "$(( $(date +%s) - start ))"
fi

# --- After: runtime bundle id, MCP registration. ----------------------------
running=$(lsappinfo info -only bundleID "$pid" 2>/dev/null | sed -n 's/.*="\(.*\)"/\1/p')
[ "$running" = "$bundle" ] || { kill_it; die "pid $pid runs as bundle '$running', expected '$bundle'; killed"; }

mcp_after=$(mcp_entry) || { kill_it; die "could not re-read ~/.claude.json; killed"; }
if [ "$mcp_after" != "$mcp_before" ]; then
    kill_it
    printf 'before: %s\nafter:  %s\n' "$mcp_before" "$mcp_after" >&2
    die "the user's mcpServers.polter entry changed; killed pid $pid. Put the 'before' value back by hand."
fi

sock=""
i=0
while [ -z "$sock" ] && [ $i -lt 20 ]; do
    sock=$(ls "$state"/polter/polter-*.sock 2>/dev/null | head -n 1 || true)
    [ -n "$sock" ] || sleep 0.5
    i=$((i + 1))
done

printf 'pid=%s\nstate=%s\nsocket=%s\nbundle=%s\nconfig=%s\n' "$pid" "$state" "${sock:-none}" "$bundle" "$config_file"
