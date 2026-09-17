#!/bin/sh
# Drive a macOS app under test from the command line: screenshot it, read its
# menu structure, click one of its menu items. The equivalent of what `argus`
# gives us on Windows, built out of what the system already ships --
# `screencapture`, `osascript` and the accessibility API behind System Events.
#
# Everything here needs one permission: **Accessibility**, granted to the
# *responsible* process, which is the app that owns the terminal this runs in
# (`Polter` on this machine), not to `osascript` and not to this script. See
# `dev-docs/macos/driving-the-mac-app.md` -- the reasoning there is what makes
# the error messages below readable.
#
# The target is always named by **pid**. Not by name: three processes on this
# machine are called `polter` and picking by name picks one of them at random.
# Not by "does it have the menu I am about to test for" either -- that is the
# thing under test, and using it to choose the target is circular.
#
# Exit codes are the point of this script. A driving channel that cannot fail
# is worse than none, so every step below has a way to come back non-zero, and
# `dev-docs/macos/driving-the-mac-app.md` records which line each failure
# lands on.
set -eu

die() { printf 'mac-drive: %s\n' "$*" >&2; exit 1; }

usage() {
    cat >&2 <<'USAGE'
usage: mac-drive.sh <pid> shot <out.png>
       mac-drive.sh <pid> tree [<menu-bar-item>]
       mac-drive.sh <pid> click <menu-bar-item> <menu-item>
       mac-drive.sh <pid> windows
USAGE
    exit 2
}

[ $# -ge 2 ] || usage
pid=$1
action=$2
shift 2

case "$pid" in
    ''|*[!0-9]*) die "pid must be a number, got '$pid'" ;;
esac

# --- The guard. -------------------------------------------------------------
#
# This script sends real keystrokes and real clicks. The person running it has
# their own copy of the app open and is working in it; driving *that* one would
# type into their session. So the target must be a build under test, and the
# test for "under test" is that its binary does not live in /Applications.
#
# This is a refusal, not a warning: there is no flag to override it. If a
# future caller genuinely needs to drive an installed copy, that is a new
# argument and a new conversation, not a flag somebody can pass by accident.
exe=$(ps -o comm= -p "$pid" 2>/dev/null) || die "no process with pid $pid"
[ -n "$exe" ] || die "no process with pid $pid"
case "$exe" in
    /Applications/*)
        die "refusing to drive $pid: $exe is an installed copy, not a build under test"
        ;;
esac

# --- The second guard, and why it is shaped like a loop. --------------------
#
# The guard above reads `ps`. Everything below drives the accessibility API.
# Those are two different views of the machine and a check in one does not
# constrain the other.
#
# **Do not write `set p to first process whose unix id is N`.** That expression
# evaluates to a reference *by name* -- `«class pcap» "polter" of application
# "System Events"` -- and not to the process it matched. Every later use of `p`
# re-resolves that name, so on a machine with three processes called `polter`
# it silently hands you the first one. Measured, in one script:
#
#     set p to first process whose unix id is 49549
#     unix id of p                                    --> 22650   (wrong)
#     unix id of (first process whose unix id is 49549) --> 49549 (right)
#
# 22650 was the user's own session. A driver built on the first spelling reads
# plausible-looking data off the wrong window and then types into it.
#
# So the target is resolved by walking the list -- list elements are a snapshot
# -- and the identity is asserted on the object itself, inside the same
# `osascript` invocation that acts on it. `file of process` cannot be the
# identity check: two copies of one app share a bundle identifier and System
# Events answers `/Applications/Polter.app` for both, the installed one and a
# build running out of a worktree.
#
# $1: the AppleScript body. It runs with `p` bound to the target and must
#     `return`.
comm=$(basename "$exe")

on_target() {
    osascript 2>&1 <<EOF
tell application "System Events"
  repeat with p in (every process whose name is "$comm")
    if (unix id of p) is $pid then
$1
    end if
  end repeat
  error "System Events cannot reach a process named $comm with unix id $pid"
end tell
EOF
}

require_process() {
    out=$(on_target '      return name of p') \
        || die "pid $pid is not a process System Events can see: $out"
    [ -n "$out" ] || die "pid $pid resolved to an empty name"
    printf '%s' "$out"
}

case "$action" in
shot)
    [ $# -eq 1 ] || usage
    out=$1
    # -x: no camera sound. Note this captures the *screen*, not the window:
    # screencapture needs Screen Recording, which is a different permission
    # from Accessibility and is granted to the same responsible process.
    #
    # An unauthorised screencapture prints "could not create image from
    # display", exits 1 and **writes no file** -- so the file check below is
    # not belt-and-braces, it is the check that catches a half-failure.
    screencapture -x "$out" || die "screencapture failed (Screen Recording not granted to the responsible process?)"
    [ -s "$out" ] || die "screencapture exited 0 but produced no file at $out"
    printf '%s\n' "$out"
    ;;

tree)
    name=$(require_process)
    if [ $# -eq 0 ]; then
        on_target '      return name of every menu bar item of menu bar 1 of p' \
            || die "could not read the menu bar of pid $pid ($name)"
    else
        bar=$1
        # Do not assume the language. On this machine the menu bar items come
        # back in English ("File", "View") while the items inside them are in
        # Chinese ("关于 Polter", "最小化"). Read, then match.
        on_target "      return name of every menu item of menu 1 of menu bar item \"$bar\" of menu bar 1 of p" \
            || die "could not read menu '$bar' of pid $pid ($name)"
    fi
    ;;

windows)
    name=$(require_process)
    on_target '      if (count of windows of p) is 0 then return {(unix id of p), 0}
      return {(unix id of p), (count of windows of p), name of every window of p, position of window 1 of p}' \
        || die "could not read the windows of pid $pid ($name)"
    ;;

click)
    [ $# -eq 2 ] || usage
    bar=$1
    item=$2
    name=$(require_process)

    # Two separate failures, kept separate on purpose: a menu that is not
    # there and an item that is not there are different mistakes, and a
    # caller that gets one message for both cannot tell a typo in the menu
    # name from a menu whose contents changed.
    on_target "      return name of menu bar item \"$bar\" of menu bar 1 of p" \
        || die "no menu bar item '$bar' on pid $pid ($name)"

    on_target "      return name of menu item \"$item\" of menu 1 of menu bar item \"$bar\" of menu bar 1 of p" \
        || die "no menu item '$item' under '$bar' on pid $pid ($name)"

    on_target "      click menu item \"$item\" of menu 1 of menu bar item \"$bar\" of menu bar 1 of p
      return \"clicked\"" \
        || die "found '$bar' > '$item' on pid $pid ($name) but clicking it failed"
    printf 'clicked %s > %s\n' "$bar" "$item"
    ;;

*)
    usage
    ;;
esac
