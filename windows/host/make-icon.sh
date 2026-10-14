#!/bin/sh
# Make windows/host/polter.ico from Polter's icon (task 1510).
#
# Usage: windows/host/make-icon.sh        (from anywhere; needs rsvg-convert
#                                          and ImageMagick's `magick`)
#
# **The source is images/polter-icon.svg**, the complete tile (rounded purple
# square included) from a266ec6cb "Polter's own icon". Not
# macos/Assets.xcassets/AppIconImage.imageset: that is still Ghostty's ghost.
# images/Polter.icon is the same drawing with the outer tile removed, because
# macOS draws that shape itself; Windows does not, so it takes the full tile.
#
# **Every size is rendered from the vector**, not shrunk from one big bitmap:
# a 16-pixel icon resampled from 256 is blurrier than one drawn at 16.
#
# The sizes are the ones Windows asks for at 100-250% scaling: 16/20/24/32/40/
# 48 for title bars, the taskbar, Alt+Tab and Explorer's small views, 64 and
# 256 for the large ones. ImageMagick stores 256 as PNG inside the .ico and
# the rest as bitmaps, which is what every Windows version since Vista reads.
#
# The output is committed, so building the host needs neither tool.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
src="$here/../../images/polter-icon.svg"
out="$here/polter.ico"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pngs=""
for n in 16 20 24 32 40 48 64 256; do
    rsvg-convert -w "$n" -h "$n" "$src" -o "$tmp/$n.png"
    pngs="$pngs $tmp/$n.png"
done
# shellcheck disable=SC2086 # one argument per file, on purpose
magick $pngs "$out"
echo "wrote $out"
