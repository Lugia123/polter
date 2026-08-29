#!/bin/sh
# Talk to Polter from a shell plugin. Two functions, no vocabulary.
#
# **This is not an SDK.** There is no function here per tool, and there never
# will be one: a plugin speaks the same wire protocol an agent speaks over
# MCP, so a method added to the tool surface is available to a plugin the same
# day and there is no second list for anybody to forget to update.
#
# Two transports, not one: the socket carries calls out, and this plugin's own
# standard output carries reports back. `polter_tell` at the bottom is the
# second of those.
#
#   . "$(dirname "$0")/../_sdk/polter.sh"
#   polter_open "$hello" || echo "no socket; only events" >&2
#   polter_call '{"method":"terminal_list"}'
#
# `polter_open` takes the host's greeting line and pulls `socket` and `token`
# out of it. It returns non-zero when the greeting carries neither, which is
# what a plugin sees when Polter's agent socket is off -- not an error, just
# nothing to call.
#
# Needs a `nc` that speaks unix sockets (`nc -U`), which is BSD nc on macOS
# and `openbsd-netcat` on Linux. A shell has no socket of its own; a plugin
# that needs one without `nc` is a plugin better written in something else,
# and `polter.py` beside this file is sixty lines.
#
# What a plugin may call is `"wants": {"calls": [...]}` in its manifest, the
# host enforces it, and a method not in that list comes back as a refusal
# naming the missing declaration.

POLTER_SOCKET=
POLTER_TOKEN=

polter_open() {
  _hello=$1
  POLTER_SOCKET=$(printf '%s' "$_hello" | sed -n 's/.*"socket":"\([^"]*\)".*/\1/p')
  POLTER_TOKEN=$(printf '%s' "$_hello" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  [ -n "$POLTER_SOCKET" ] && [ -n "$POLTER_TOKEN" ]
}

# One call, one reply on stdout.
#
# A connection per call, which is the honest shape for a shell: keeping one
# open needs a coprocess and a second file descriptor, and a plugin that calls
# Polter often enough for that to matter is one that wants `polter.py`. The
# handshake is the first line either way, so nothing is skipped.
polter_call() {
  [ -n "$POLTER_SOCKET" ] || return 1
  {
    printf '{"method":"auth","params":{"token":"%s"}}\n' "$POLTER_TOKEN"
    printf '%s\n' "$1"
  } | nc -U "$POLTER_SOCKET" | sed -n '2p'
}

# A refusal is `{"ok":false,"code":"…","message":"…"}` on one line, so a
# caller that only wants to know whether it worked can look for `"ok":true`.
# The code is worth reading: `NotDeclared` means the manifest, not the
# permissions.
polter_ok() {
  case "$1" in
    *'"ok":true'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Put one line in front of the user, on the channel this plugin already has.
#
# Reporting its own state is part of the protocol rather than a capability, so
# there is nothing to declare and nothing to be granted: a plugin saying "I
# could not write that file" travels the same path the host's own "that plugin
# will not start" travels. It is a line of its own on standard output:
#
#   {"tell":"could not write the skill file: permission denied"}
#
# Write it *before* the acknowledgement for this batch. The host reads reports
# until it gets an answer, so this line does not count as one.
#
# **Say the consequence, not only the fault.** Nothing checks it -- no string
# test can tell "failed" from "so the agent starts with no memory of this",
# and a check that guessed would be believed. You know what your failure costs
# the user; Polter does not.
#
# The text is escaped for JSON here only as far as a shell reasonably can:
# backslashes, double quotes and the control characters a `\n` would produce.
# The host strips control characters and clamps the length either way, so the
# worst a odd byte can do is come out as a space.
polter_tell() {
  printf '{"tell":"%s"}\n' "$(
    printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
  )"
}
