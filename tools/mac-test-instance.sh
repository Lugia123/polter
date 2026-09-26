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
# 5. **Inherited `GHOSTTY_*` / `POLTER_*` dropped**: a shell inside the
#    user's Polter carries the user's socket and token.
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
state=$(mktemp -d /tmp/polter-test.XXXX) || die "mktemp failed"
probe="$state/polter/polter-0123456789abcdef.sock"
[ "${#probe}" -lt 104 ] || die "state directory $state is too long for an AF_UNIX socket (${#probe} bytes)"

# --- 4. The user's MCP registration, before. --------------------------------
mcp_entry() {
    python3 -c 'import json,os;print(json.dumps(json.load(open(os.path.expanduser("~/.claude.json"))).get("mcpServers",{}).get("polter"),sort_keys=True))'
}
mcp_before=$(mcp_entry) || die "could not read ~/.claude.json"

front_pid() { lsappinfo info -only pid "$(lsappinfo front)" 2>/dev/null | sed 's/[^0-9]//g'; }
was_front=$(front_pid)

# --- 3, 5. Start it. --------------------------------------------------------
for v in $(env | cut -d= -f1 | grep -E '^(GHOSTTY|POLTER)_' || true); do unset "$v"; done
XDG_STATE_HOME=$state nohup "$exe" \
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

printf 'pid=%s\nstate=%s\nsocket=%s\nbundle=%s\n' "$pid" "$state" "${sock:-none}" "$bundle"
