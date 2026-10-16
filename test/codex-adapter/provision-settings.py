#!/usr/bin/env python3
"""The Codex plugin's `manual_out_of_daemon` setting comes back out byte for byte.

Task 1674. Turned on, the plugin writes one marked line,
`daemon_auto_start = false`, into `[features]` in Codex's config.toml (and a
marked `[features]` header with a blank line in front of it when there was
no such table). Turned off, it takes back exactly what it wrote: **the file
afterwards is the file before, to the byte** -- the blank line it put in
included, which the first version left behind. A setting the person wrote
themselves is never touched.

Runs the shipped `plugins/codex/provision.sh` (with `/bin/sh`) and, when a
PowerShell is there, `provision.ps1`, each loaded with
`POLTER_PROVISION_FUNCTIONS_ONLY=1` so that only the one step is called.

    python3 test/codex-adapter/provision-settings.py

Exit 0 when every case holds for every shell that ran.
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(os.path.dirname(os.path.dirname(HERE)), "plugins", "codex")
MARK = "# set by Polter"

CASES = {
    "no [features] table": 'model = "x"\n\n[tui]\ntheme = "dark"\n',
    "no table, file ends in a blank line": 'model = "x"\n\n',
    "a [features] table of the person's": 'model = "x"\n\n[features]\nhooks = true\n\n[tui]\ntheme = "dark"\n',
    "an empty file": "",
}
THEIRS = '[features]\ndaemon_auto_start = true\n'


def sh_step(chome, want):
    script = (
        'set -- ; . "$0"; '
        'POLTER_HELLO=\'{"params":{"manual_out_of_daemon":"' + want + '"}}\'; '
        'wrote=no; host_settings_apply'
    )
    return subprocess.run(["/bin/sh", "-c", script, os.path.join(PLUGIN, "provision.sh")],
                          env=dict(os.environ, POLTER_PROVISION_FUNCTIONS_ONLY="1", CODEX_HOME=chome),
                          capture_output=True, text=True, timeout=30)


def ps_step(ps, chome, want):
    command = (
        ". '" + os.path.join(PLUGIN, "provision.ps1") + "'; "
        "$script:PolterParams = [pscustomobject]@{ manual_out_of_daemon = '" + want + "' }; "
        "Set-HostSettings"
    )
    return subprocess.run([ps, "-NoProfile", "-NonInteractive", "-Command", command],
                          env=dict(os.environ, POLTER_PROVISION_FUNCTIONS_ONLY="1", CODEX_HOME=chome),
                          capture_output=True, text=True, timeout=60)


def check(label, step):
    ok = True
    for name, original in CASES.items():
        base = tempfile.mkdtemp(prefix="p1674s-")
        try:
            path = os.path.join(base, "config.toml")
            with open(path, "wb") as f:
                f.write(original.encode())
            r1 = step(base, "yes")
            once = open(path, "rb").read()
            r2 = step(base, "yes")
            twice = open(path, "rb").read()
            r3 = step(base, "no")
            back = open(path, "rb").read()
            on = once.count(MARK.encode()) >= 1 and b"daemon_auto_start = false" in once
            good = r1.returncode == 0 and r2.returncode == 0 and r3.returncode == 0 and on \
                and twice == once and back == original.encode()
            print("%s  %-5s %s" % ("ok  " if good else "FAIL", label, name))
            if not good:
                ok = False
                print("      on=%s again-unchanged=%s back-byte-for-byte=%s" % (on, twice == once, back == original.encode()))
                print("      original=%r\n      back    =%r" % (original, back.decode()))
                for r in (r1, r2, r3):
                    if r.returncode != 0:
                        print("      exit %d: %s" % (r.returncode, (r.stderr or r.stdout).strip()[-300:]))
        finally:
            shutil.rmtree(base, ignore_errors=True)

    base = tempfile.mkdtemp(prefix="p1674s-")
    try:
        path = os.path.join(base, "config.toml")
        with open(path, "w") as f:
            f.write(THEIRS)
        step(base, "yes")
        after_yes = open(path).read()
        step(base, "no")
        after_no = open(path).read()
        good = after_yes == THEIRS and after_no == THEIRS
        print("%s  %-5s the person's own daemon_auto_start, on and off" % ("ok  " if good else "FAIL", label))
        ok = ok and good
    finally:
        shutil.rmtree(base, ignore_errors=True)
    return ok


def main():
    ok = check("sh", sh_step)
    ps = shutil.which("pwsh") or shutil.which("powershell")
    if ps:
        ok = check("ps1", lambda chome, want: ps_step(ps, chome, want)) and ok
    else:
        print("no PowerShell here; provision.ps1 not run")
    print("all hold" if ok else "SOME DO NOT HOLD")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
