#!/usr/bin/env python3
"""Two sidecars started by a Codex app-server daemon must not both be one terminal.

Task 1674, measured in the test session: signed in to a ChatGPT account, a
Codex typed by hand runs its session in Codex's shared app-server daemon, and
the daemon starts `polter +mcp` for every session with the environment of the
terminal that started the daemon. A second terminal's Codex was answered by
`me` with the first terminal's id, and what it posted was posted as the first
terminal.

This runs a built `polter` the way that daemon does: a stand-in program
called `codex`, with `app-server` on its command line, starts two sidecars
carrying the same inherited `GHOSTTY_POLTER_SOCKET` and token. The socket is
a recorder. **Neither sidecar may connect with that identity**, and each must
answer a tool call with the reason. The control is the same two sidecars
started by a `codex` without `app-server` (a TUI): both connect, as a
terminal's sidecar always has.

    python3 test/codex-adapter/daemon-sidecars.py <path to polter>

POSIX only. Exit 0 when both halves hold.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

REQUESTS = (
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n'
    '{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"me","arguments":{}}}\n'
)


def recorder(path, seen, stop):
    s = socket.socket(socket.AF_UNIX)
    s.bind(path)
    s.listen(8)
    s.settimeout(0.2)
    conns = []
    while not stop.is_set():
        try:
            c, _ = s.accept()
        except socket.timeout:
            continue
        c.settimeout(2)
        try:
            first = c.recv(65536).split(b"\n")[0]
        except socket.timeout:
            first = b""
        seen.append(first.decode("utf-8", "replace"))
        conns.append(c)
    for c in conns:
        c.close()
    s.close()


def run(polter, base, label, daemon):
    """Start two sidecars under a stand-in `codex`; return (auths, replies)."""
    work = os.path.join(base, label)
    os.makedirs(work)
    stand = os.path.join(work, "codex")
    shutil.copyfile("/bin/sh", stand)
    os.chmod(stand, 0o755)
    with open(os.path.join(work, "req"), "w") as f:
        f.write(REQUESTS)
    seen, stop = [], threading.Event()
    t = threading.Thread(target=recorder, args=(os.path.join(work, "s"), seen, stop))
    t.start()
    time.sleep(0.2)
    script = (
        '"$P" +mcp < req > out1 2>/dev/null & a=$!; '
        '"$P" +mcp < req > out2 2>/dev/null & b=$!; '
        'sleep 3; kill $a $b 2>/dev/null; wait'
    )
    argv = [stand, "-c", script] + (["app-server", "--listen", "unix://"] if daemon else ["--no-daemon"])
    # Nothing of this machine's own agent rides along into what is recorded.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("CLAUDE", "AI_AGENT", "GHOSTTY_", "CODEX"))}
    env.update(P=polter, GHOSTTY_POLTER_SOCKET="s", GHOSTTY_POLTER_TOKEN="inherited-token")
    subprocess.run(argv, cwd=work, env=env, timeout=30)
    stop.set()
    t.join()
    replies = []
    for name in ("out1", "out2"):
        with open(os.path.join(work, name)) as f:
            replies.append(f.read())
    return seen, replies


def main():
    if len(sys.argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    polter = os.path.abspath(sys.argv[1])
    base = tempfile.mkdtemp(prefix="p1674-")
    ok = True
    try:
        auths, replies = run(polter, base, "daemon", True)
        print("under the daemon: %d connection(s) to the inherited socket" % len(auths))
        if auths:
            ok = False
            print("  FAIL: a sidecar connected as the inherited terminal: %s" % auths)
        for i, r in enumerate(replies, 1):
            lines = [json.loads(l) for l in r.splitlines() if l.strip()]
            call = next((l for l in lines if l.get("id") == 2), None)
            text = call["result"]["content"][0]["text"] if call and "result" in call else ""
            told = call is not None and call["result"].get("isError") is True and "--no-daemon" in text
            print("  sidecar %d: initialize %s, me refused with the reason: %s" % (
                i, "answered" if any(l.get("id") == 1 for l in lines) else "MISSING", told))
            ok = ok and told

        auths, _ = run(polter, base, "tui", False)
        print("under a Codex TUI (control): %d connection(s)" % len(auths))
        if len(auths) != 2 or not all('"auth"' in a for a in auths):
            ok = False
            print("  FAIL: a terminal's sidecars should both connect: %s" % auths)
    finally:
        shutil.rmtree(base, ignore_errors=True)
    print("holds" if ok else "DOES NOT HOLD")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
