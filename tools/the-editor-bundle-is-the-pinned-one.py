#!/usr/bin/env python3
r"""The editor bundle is the one `tools/build-codemirror` pins, and it loads
nothing off the network.

# Why this exists

`plugins/edit-text` ships a built CodeMirror 6 (`plugins/edit-text/page/
vendor/codemirror.bundle.js`, `polter-artifacts/2145/PLAN.md` §2.2). **Polter
compiles nothing for a plugin**, so that file is committed rather than built:
what ships is whatever somebody last ran the build and copied in, and nothing
in `zig build`, in the tests, or in CI would notice if it were the wrong one.
Two failures that look exactly like success:

  * **It is not the build the lock file describes.** `package-lock.json` pins
    every version, the README says the bundle comes from it, and the two part
    the first time somebody upgrades a dependency without re-running the build
    -- and a stale bundle is a bundle with the old bugs and, if the reason for
    the upgrade was a fix, without it.
  * **It reaches the network.** A plugin page runs with `network: false`, a
    CSP of `default-src 'none'` and a rule list that blocks everything but the
    plugin's own scheme, so a bundle that fetched something would simply fail
    -- silently, in a page somebody has to debug. Anything that must not be in
    there is cheapest to catch here.

The sha256 is the pin, because it is the one value that cannot be satisfied by
a file that is merely *a* CodeMirror build: `BUNDLE.sha256` and the bundle have
to be written together, and copying a new bundle without updating it is red.

# What it checks

  1. `plugins/edit-text/page/vendor/codemirror.bundle.js` exists, is not
     empty, and its sha256 is the one `tools/build-codemirror/BUNDLE.sha256`
     names. A missing bundle, a missing sha file, or an empty sha file is a
     FAIL rather than nothing to complain about.
  2. `tools/build-codemirror/` carries `package.json`, `package-lock.json`,
     `entry.js` and `build.mjs` -- so the instruction for producing the file
     is in the tree beside it, rather than in a commit message.
  3. **The bundle reaches no network.** Every `http://` / `https://` in the
     file is examined, and the **only** two shapes allowed are:
       * an XML namespace inside a `data:` URI -- `drawSelection`'s SVG caret
         is `<svg xmlns="http://www.w3.org/2000/svg" …>`, which every stock
         CodeMirror build contains, describes nothing fetchable, and cannot be
         removed without reimplementing that extension;
       * an `xmlns` declaration spelled outside a `data:` URI, same thing.
     Anything else -- a URL in a `fetch(...)`, an `import(...)`, a string a
     script assigns to `src` -- is a FAIL. **The address is judged, not the
     scheme**: `https://` in a comment or a namespace is inert, and a rule
     that failed on the string alone would fail on every real CodeMirror
     build, which is a gate everybody routes around.
  4. For the same reason, the loader APIs are refused by name: `fetch(`,
     `XMLHttpRequest`, `WebSocket`, `importScripts`, `navigator.sendBeacon`.
     A bundle may contain none of them and be complete; one that contains any
     is either reaching the network or is about to.

# NOT CHECKED

  * That the bundle is *reproducible* from the lock file -- that needs `npm
    install`, which needs the network, and a gate that downloads dependencies
    on every run is a gate that fails on a train. What is measured is the pin
    (face 1) and the contents (faces 3, 4).
  * That the versions in `package.json` and `package-lock.json` agree in every
    field npm records. Face 2 asserts the files are there; npm owns their
    contents, and hand-checking a lock file is how it gets edited by hand.
  * The mac app bundle and the release packages: those are assembled from
    `zig-out`, which is built from the tree this gate reads.
  * Whether the CodeMirror *licence* notice is complete. `vendor/LICENSE`
    carries it; that it is right is a reader's job.

Run:  python3 tools/the-editor-bundle-is-the-pinned-one.py
Exit: 0 when the bundle is the pinned one and reaches nothing; 1 otherwise,
      including when the bundle or the sha file is not there at all.
"""

import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))

TOOL = os.path.join(ROOT, "tools", "build-codemirror")
BUNDLE = os.path.join(
    ROOT, "plugins", "edit-text", "page", "vendor", "codemirror.bundle.js")
SHA_FILE = os.path.join(TOOL, "BUNDLE.sha256")

# What the build is, and has to still be: the instruction beside the product.
BUILD_FILES = ["package.json", "package-lock.json", "entry.js", "build.mjs"]

# Loader APIs a bundle of an editor has no use for. Refused by name, because
# these are what a network reach is actually spelled with.
FORBIDDEN = [
    ("fetch(", "the Fetch API"),
    ("XMLHttpRequest", "XMLHttpRequest"),
    ("WebSocket", "a WebSocket"),
    ("importScripts", "importScripts"),
    ("sendBeacon", "navigator.sendBeacon"),
]

# Where an `http(s)://` may legitimately appear, and why each is inert:
#   * inside a `data:` URI -- an inline SVG's XML namespace, which is a name
#     (`http://www.w3.org/2000/svg`), not an address anything fetches;
#   * an `xmlns` declaration, same name in the same role.
DATA_URI = re.compile(rb"data:[a-zA-Z0-9.+-]*/[a-zA-Z0-9.+-]*[;,]", re.I)
XMLNS = re.compile(rb"xmlns\s*=\s*[\"']\s*$", re.I)
URL = re.compile(rb"https?://", re.I)


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def reaches_network(data):
    """`http(s)://` occurrences that are neither a `data:` URI's namespace nor
    an `xmlns` declaration. Returns [(offset, the text around it)]."""
    out = []
    for m in URL.finditer(data):
        start = m.start()

        # Inside a `data:` URI? Walk back to the nearest `data:` and see
        # whether a `,` or `;` has been passed -- which is where the payload
        # begins. Bounded so a stray `data:` megabytes earlier cannot make
        # every later URL look exempt.
        window = data[max(0, start - 4096):start]
        if DATA_URI.search(window):
            after = window[DATA_URI.search(window).end():]
            # Nothing but the payload may sit between the media type and here.
            if b"://" not in after:
                continue

        # `xmlns="http://…"` / `xmlns='http://…'`.
        if XMLNS.search(data[max(0, start - 32):start]):
            continue

        out.append((start, data[max(0, start - 60):start + 80]))
    return out


def main():
    problems = []
    notes = []

    if not os.path.isfile(BUNDLE):
        print("FAIL: no bundle at plugins/edit-text/page/vendor/codemirror.bundle.js")
        print("FAIL: nothing to check -- the plugin's page has no editor in it")
        return 1

    if not os.path.isfile(SHA_FILE):
        print("FAIL: no tools/build-codemirror/BUNDLE.sha256, so the bundle is unpinned")
        return 1

    with open(SHA_FILE, encoding="utf-8") as f:
        pinned = f.read().strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", pinned):
        print("FAIL: BUNDLE.sha256 does not hold one sha256 (%r)" % pinned)
        return 1

    size = os.path.getsize(BUNDLE)
    if size == 0:
        print("FAIL: the bundle is empty")
        return 1

    actual = sha256_of(BUNDLE)
    if actual != pinned:
        problems.append(
            "the bundle is not the pinned build: sha256 is %s, BUNDLE.sha256 says %s "
            "(a new bundle and its sha are written together; re-run "
            "tools/build-codemirror and update the sha)" % (actual, pinned))

    for name in BUILD_FILES:
        if not os.path.isfile(os.path.join(TOOL, name)):
            problems.append("tools/build-codemirror/%s is missing, so the bundle cannot be rebuilt" % name)

    with open(BUNDLE, "rb") as f:
        data = f.read()

    for needle, what in FORBIDDEN:
        if needle.encode() in data:
            problems.append("the bundle contains %s (%r)" % (what, needle))

    reach = reaches_network(data)
    for offset, around in reach[:5]:
        problems.append(
            "the bundle carries an address at offset %d that is not a data: URI's "
            "namespace: %r" % (offset, around))
    if len(reach) > 5:
        problems.append("…and %d more" % (len(reach) - 5))

    if not problems:
        notes.append("bundle sha256 %s, %d bytes" % (actual[:16], size))

    for n in notes:
        print("note: " + n)
    print("scanned the editor bundle at plugins/edit-text/page/vendor/codemirror.bundle.js")
    for p in problems:
        print("FAIL: " + p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
