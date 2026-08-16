#!/bin/sh
# POST the notice to a URL.
#
# The example plugin, and a real one: this is all a notification plugin
# has to be. Polter writes one line of JSON on stdin; exit 0 means sent.
#
# Adapt the payload for whatever you are posting to -- what is here is a
# plain JSON object, which ntfy and most webhook receivers accept as-is.
# For Feishu you would want {"msg_type":"text","content":{"text":...}}.

set -eu

notice=$(cat)

# Everything Polter knows is in that JSON. `params` holds your configured
# values with any references already resolved, so `url` here is a URL and
# never `cmd:something`.
url=$(printf '%s' "$notice" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')

if [ -z "$url" ]; then
  echo "webhook: no url configured" >&2
  exit 1
fi

title=$(printf '%s' "$notice" | sed -n 's/.*"title":"\([^"]*\)".*/\1/p')
body=$(printf '%s' "$notice" | sed -n 's/.*"body":"\([^"]*\)".*/\1/p')

# --fail so a 4xx or 5xx becomes a non-zero exit, which is how Polter
# learns this did not arrive. Without it curl reports success for a 500.
curl --fail --silent --show-error \
  --max-time 8 \
  -H 'Content-Type: application/json' \
  -d "{\"title\":$(printf '%s' "$title" | sed 's/.*/"&"/'),\"text\":$(printf '%s' "$body" | sed 's/.*/"&"/')}" \
  "$url" >/dev/null
