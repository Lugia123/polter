#!/usr/bin/env python3
"""Every file a plugin's manifest names for Polter to start is executable.

**Why this exists** (task 1667). On macOS and Linux Polter starts a plugin's
`exec` and an agent CLI's `adapter` by executing the file itself
(`Plugin.launchKindFor`: everything but `.ps1`, `.cmd` and `.bat` is
`.direct`), so the file's own executable bit is what decides whether it runs.
`plugins/codex/adapter.py` arrived as mode 100644. Every test passed -- the
tests beside `agent_cli.zig` write the adapter out themselves with 0755, and
the comparison script hands it to `python3` -- and in the product `+launch`
printed `adapter.py could not be run (AccessDenied)` and dropped the person
back at a shell prompt. The build copies the mode it finds
(`addInstallDirectory`), so the bit in the repository is the bit in the app.

Checked for every `plugins/<dir>/plugin.json`, on `exec` and `agent_cli.adapter`
(the `_windows` names are started through PowerShell or `cmd`, and need no bit):

  1. **The file is there.**
  2. **It is executable in the working tree** (the owner's `x`).
  3. **Git records it as 100755**, when Git records it at all. A file only
     marked with `git add -N` has no mode of its own yet -- the commit takes
     the working tree's -- so for those face 2 is the one that counts, and
     the line says so. An untracked file is said too.
  4. **When there is a build tree** (`zig-out/share/ghostty/polter/plugins`),
     the installed copy of each file is executable as well.

NOT CHECKED
  * Windows, where no bit is involved; that a `.ps1` parses there is
    `windows/tools/manifest-parses.py`'s side, not this one's.
  * The macOS app bundle and the release packages: face 4 reads `zig-out`,
    which they are assembled from, not the bundle itself.
  * That a shebang names an interpreter this machine has.

Run:  python3 tools/the-files-a-plugin-names-can-be-started.py
Exit: 0 when every file holds; 1 otherwise, including when no manifest was
found to check.
"""

import json
import os
import stat
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
PLUGINS = os.path.join(ROOT, "plugins")
BUILT = os.path.join(ROOT, "zig-out", "share", "ghostty", "polter", "plugins")

# Started by an interpreter Polter names, never executed directly.
NOT_DIRECT = (".ps1", ".cmd", ".bat")
EMPTY_BLOB = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"


def git_modes():
    """`relative path -> (mode, blob)` as the index has them, or None."""
    try:
        out = subprocess.run(["git", "-C", ROOT, "ls-files", "-s", "-z", "--", "plugins"],
                             capture_output=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    modes = {}
    for entry in out.split(b"\0"):
        if not entry:
            continue
        meta, path = entry.split(b"\t", 1)
        mode, blob, _ = meta.decode().split(" ")
        modes[path.decode("utf-8", "replace")] = (mode, blob)
    return modes


def executable(path):
    try:
        return bool(os.stat(path).st_mode & stat.S_IXUSR)
    except OSError:
        return False


def named(manifest):
    """The files of this manifest Polter executes directly, with the key that names them."""
    out = []
    if isinstance(manifest.get("exec"), str):
        out.append(("exec", manifest["exec"]))
    cli = manifest.get("agent_cli")
    if isinstance(cli, dict) and isinstance(cli.get("adapter"), str):
        out.append(("agent_cli.adapter", cli["adapter"]))
    return [(k, v) for k, v in out if not v.lower().endswith(NOT_DIRECT)]


def main():
    problems = []
    notes = []
    modes = git_modes()
    if modes is None:
        notes.append("git could not be asked; face 3 was not checked")
    manifests = 0
    files = 0

    try:
        dirs = sorted(os.listdir(PLUGINS))
    except OSError:
        dirs = []
    for d in dirs:
        path = os.path.join(PLUGINS, d, "plugin.json")
        if not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8") as f:
                manifest = json.load(f)
        except (OSError, ValueError) as e:
            problems.append("plugins/%s/plugin.json: does not read (%s)" % (d, e))
            continue
        manifests += 1
        for key, name in named(manifest):
            files += 1
            rel = "plugins/%s/%s" % (d, name)
            full = os.path.join(PLUGINS, d, name)
            if not os.path.isfile(full):
                problems.append("%s (%s): no such file" % (rel, key))
                continue
            if not executable(full):
                problems.append("%s (%s): not executable in the working tree; Polter would get AccessDenied starting it" % (rel, key))
            if modes is not None:
                entry = modes.get(rel)
                if entry is None:
                    notes.append("%s: untracked; only the working tree was checked" % rel)
                elif entry[1] == EMPTY_BLOB and os.path.getsize(full) > 0:
                    notes.append("%s: marked with git add -N; the commit takes the working tree's mode" % rel)
                elif entry[0] != "100755":
                    problems.append("%s (%s): git records mode %s, not 100755" % (rel, key, entry[0]))
            if os.path.isdir(BUILT):
                built = os.path.join(BUILT, d, name)
                if os.path.isfile(built) and not executable(built):
                    problems.append("zig-out/.../plugins/%s/%s: installed without its executable bit" % (d, name))

    if not os.path.isdir(BUILT):
        notes.append("no build tree; face 4 was not checked")
    for n in notes:
        print("note: " + n)
    print("scanned %d manifest(s), %d file(s) Polter executes directly" % (manifests, files))
    if manifests == 0 or files == 0:
        print("FAIL: nothing to check -- the plugins directory was not found or names no file")
        return 1
    for p in problems:
        print("FAIL: " + p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
