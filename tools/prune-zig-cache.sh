#!/bin/sh
# Keep the Zig build cache from growing without bound.
#
# Zig's cache is content-addressed and append-only. Every build whose inputs
# differ by so much as one flag writes a fresh entry under `.zig-cache/o/`,
# and nothing ever removes one: there is no eviction, no budget, no
# `zig build --gc`. On this repository that reached 263 GB across 9,992
# entries in thirty days, while a clean build plus the full test suite needs
# about 3 GB across 800. The rest was never looked at again.
#
# ## Why this wipes rather than prunes
#
# Deleting old `o/` entries and keeping the recent ones is the obvious idea
# and it does not work. Measured on this repository:
#
#   * Removing live `o/` entries does not cause a rebuild. The manifests in
#     `.zig-cache/h/` still name them, so the next build dies with
#     `failed to spawn build runner .zig-cache/o/<hash>/build: FileNotFound`
#     -- and it does not heal on a retry. It fails the same way every time
#     until the manifests go too.
#   * Removing `.zig-cache/h/` recovers, at the price of a **full** rebuild
#     (52.7s here, against 56.7s from nothing at all) -- and the surviving
#     `o/` entries are then orphaned rather than reused. The cache grew from
#     4.4 GB to 6.4 GB across that recovery.
#
# So a partial prune costs a full rebuild *and* leaves the disk worse than
# before. The cache is all-or-nothing, and this script treats it that way:
# leave it alone while it is a reasonable size, and wipe it whole when it is
# not. One full rebuild occasionally beats one after every prune.
#
#   tools/prune-zig-cache.sh              wipe if over 20 GB, else leave it
#   tools/prune-zig-cache.sh --max-gb 5   a tighter ceiling
#   tools/prune-zig-cache.sh --all        wipe unconditionally
#   tools/prune-zig-cache.sh --dry-run    say what would happen
#
# What is *not* touched: `~/.cache/zig`, the global package cache holding
# the dependencies fetched from `build.zig.zon` (761 MB, 30 packages here).
# Removing that is the only thing that would make a build go to the network.

set -eu

max_gb=20
all=0
dry=0

while [ $# -gt 0 ]; do
  case "$1" in
    --max-gb) max_gb="$2"; shift 2 ;;
    --all) all=1; shift ;;
    --dry-run|-n) dry=1; shift ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "prune-zig-cache: unknown option $1" >&2; exit 2 ;;
  esac
done

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache="$root/.zig-cache"

[ -d "$cache" ] || { echo "no .zig-cache in $root; nothing to do"; exit 0; }

used_kb=$(du -sk "$cache" 2>/dev/null | awk '{print $1}')
used_gb=$(awk -v k="$used_kb" 'BEGIN { printf "%.1f", k/1048576 }')
budget_kb=$((max_gb * 1048576))
entries=$(find "$cache/o" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')

if [ "$all" -eq 0 ] && [ "$used_kb" -le "$budget_kb" ]; then
  echo "zig cache ${used_gb} GB in $entries entries, under the ${max_gb} GB ceiling; left alone"
  exit 0
fi

if [ "$dry" -eq 1 ]; then
  echo "would remove all of $cache (${used_gb} GB, $entries entries); next build would be a full one"
  exit 0
fi

rm -rf "$cache"
echo "zig cache ${used_gb} GB removed; the next build is a full one (~1 min)"
