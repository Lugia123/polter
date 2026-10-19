#!/usr/bin/env python3
"""Polter's opencode plugin and a role's switches, run by a real opencode.

Tasks 1777 and 1806. What `adapter.py` (beside this file) checks is the
launch the adapter writes; this hands that launch to the opencode on this
machine -- its TUI, in a pty, as Polter starts it -- and reads what came of
it. Nothing is spent and nothing of the person's is read or written:

  * a throwaway `HOME` (and `XDG_*`), so opencode's configuration, database,
    state and cache are made here and thrown away;
  * a stand-in model: a local OpenAI-compatible server on 127.0.0.1 that
    answers from a script and keeps what it was sent. Told to, it fails
    (`FAIL400`, `FAIL429`), asks to run a command (`RUNCMD`), asks a question
    (`ASKQ`), starts a subagent (`SUBAGENT`), or answers slowly enough to be
    stopped (`SLOWLY`);
  * a stand-in Polter: `POLTER_HOOK_EXE` names a script that writes down
    each `+hook` it is run as -- its arguments and its stdin -- and does
    nothing;
  * a stand-in MCP server under two names, `probe`, which the role switches
    off, and `other`, which it leaves on; and two skills, `noisy` off and
    `kept` on. The one left on of each is what says the other is missing for
    the switch and not for some other reason.

**Driven by the hooks, not by the screen**: each step waits for the event
the plugin should have said -- an approval waits for `permission.asked`
before it presses Enter -- so what is tested is the plugin, and a TUI that
draws differently does not move the test. The screen is read only for an
answer being under way and for a conversation being back. opencode 2.0's
HTTP API is not used: the TUI is what Polter runs, and `--standalone` -- a
server of the TUI's own -- is part of what is tested (no shared service is
left behind).

    python3 test/opencode-adapter/hooks-against-opencode.py

Skips (exit 0, says so) when there is no `opencode` here, or one older than
2.0. Exit 0 when every case holds; the events seen are printed either way.
"""

import fcntl
import json
import os
import pty
import re
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ADAPTER = os.path.join(ROOT, "plugins", "opencode", "adapter.py")
HOOKS = os.path.join(ROOT, "plugins", "opencode", "polter-hooks")

failures = []


def check(case, ok, what):
    print("%s  %s: %s" % ("ok  " if ok else "FAIL", case, what))
    if not ok:
        failures.append("%s: %s" % (case, what))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


# The payload first and the arguments last, each moved into place whole: a
# call is read once its `.argv` is there, and by then its `.json` is too.
# One at a time -- the plugin runs them in turn -- so the count is its number.
FAKE_POLTER = """#!/bin/sh
d=%s
n=$(ls "$d" | grep -c '[.]argv$')
f=$(printf '%%s/%%04d' "$d" "$n")
cat > "$f.json.tmp" && mv "$f.json.tmp" "$f.json"
printf '%%s\\n' "$*" > "$f.argv.tmp" && mv "$f.argv.tmp" "$f.argv"
exit 0
"""

FAKE_MODEL = r'''
import json, sys, http.server, time
def chunk(delta, finish=None):
    return {"id": "c1", "object": "chat.completion.chunk", "created": 0, "model": "m",
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        with open(sys.argv[2], "a") as f:
            f.write(json.dumps(body) + "\n")
        msgs = body.get("messages", [])
        user = next((m for m in reversed(msgs) if m.get("role") == "user"), {})
        text = user.get("content")
        if isinstance(text, list): text = " ".join(p.get("text", "") for p in text if isinstance(p, dict))
        text = text or ""
        for word, code in (("FAIL429", 429), ("FAIL400", 400)):
            if word in text:
                self.send_response(code); self.send_header("content-type", "application/json"); self.end_headers()
                self.wfile.write(json.dumps({"error": {"message": "probe %d" % code}}).encode()); return
        if not body.get("stream"):
            self.send_response(200); self.send_header("content-type", "application/json"); self.end_headers()
            self.wfile.write(json.dumps({"id": "t", "object": "chat.completion", "created": 0, "model": "m",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "Probe"}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}).encode()); return
        self.send_response(200); self.send_header("content-type", "text/event-stream"); self.end_headers()
        def send(o): self.wfile.write(("data: " + json.dumps(o) + "\n\n").encode()); self.wfile.flush()
        last_user = msgs[-1].get("role") == "user"
        def call(name, args):
            send(chunk({"role": "assistant", "tool_calls": [{"index": 0, "id": "call_" + name, "type": "function",
                 "function": {"name": name, "arguments": json.dumps(args)}}]}))
            send(chunk({}, "tool_calls"))
        try:
            if "ASKQ" in text and last_user:
                call("question", {"questions": [{"question": "Which colour probe?", "header": "Colour",
                     "options": [{"label": "Red", "description": "r"}, {"label": "Blue", "description": "b"}]}]})
            elif "SUBAGENT" in text and last_user:
                call("subagent", {"agent": "explore", "description": "probe child", "prompt": "child says hello"})
            elif "SLOWLY" in text and last_user:
                send(chunk({"role": "assistant", "content": "slow start "}))
                for i in range(60):
                    time.sleep(1); send(chunk({"content": "tick%d " % i}))
                send(chunk({}, "stop"))
            elif "RUNCMD" in text and last_user:
                call("shell", {"command": "echo oc-probe"})
            else:
                send(chunk({"role": "assistant", "content": "pong from the stand-in model"}))
                send(chunk({}, "stop"))
            send({"id": "c1", "object": "chat.completion.chunk", "created": 0, "model": "m", "choices": [],
                  "usage": {"prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7}})
            self.wfile.write(b"data: [DONE]\n\n")
        except (BrokenPipeError, ConnectionResetError):
            pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
'''

# Enough of MCP for opencode to list a server's tools.
FAKE_MCP = r'''
import json, sys
for line in sys.stdin:
    msg = json.loads(line)
    if "id" not in msg: continue
    m = msg.get("method")
    if m == "initialize":
        res = {"protocolVersion": msg["params"].get("protocolVersion", "2025-06-18"), "capabilities": {"tools": {}},
               "serverInfo": {"name": "probe", "version": "1"}}
    elif m == "tools/list":
        res = {"tools": [{"name": "ping", "description": "probe tool", "inputSchema": {"type": "object", "properties": {}}}]}
    else:
        res = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": res}) + "\n"); sys.stdout.flush()
'''

ESC = "\x1b"
# What is left of a TUI's output with its escape sequences taken out: enough
# to find a word it drew in one piece.
ANSI = re.compile(rb"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[P^_][^\x1b]*\x1b\\|\x1b[@-Z\\-_]")


class Tui:
    """opencode's TUI in a pty, answered the way a terminal answers it."""

    def __init__(self, argv, env, cwd, cols=110, rows=40):
        self.raw = bytearray()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            os.execvpe(argv[0], argv, env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def pump(self, secs):
        end = time.time() + secs
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.1)
            if not r:
                continue
            try:
                b = os.read(self.fd, 65536)
            except OSError:
                return
            if not b:
                return
            self.raw.extend(b)
            # The queries a TUI waits on: where the cursor is, what the
            # terminal is, its colours, its keyboard protocol.
            if b"\x1b[6n" in b:
                os.write(self.fd, b"\x1b[1;1R")
            if b"\x1b[c" in b or b"\x1b[0c" in b:
                os.write(self.fd, b"\x1b[?62;22c")
            if b"\x1b]11;?" in b:
                os.write(self.fd, b"\x1b]11;rgb:0000/0000/0000\x1b\\")
            if b"\x1b]10;?" in b:
                os.write(self.fd, b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\")
            if b"\x1b[?u" in b:
                os.write(self.fd, b"\x1b[?0u")

    def text(self):
        return ANSI.sub(b"", bytes(self.raw)).decode("utf-8", "replace")

    def wait_text(self, word, secs):
        end = time.time() + secs
        while time.time() < end:
            self.pump(0.3)
            if word in self.text():
                return True
        return False

    def type(self, text):
        os.write(self.fd, text.encode())
        self.pump(0.6)
        os.write(self.fd, b"\r")

    def key(self, k):
        os.write(self.fd, k.encode())
        self.pump(0.3)

    def stop(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.kill(self.pid, sig)
            except OSError:
                pass
            end = time.time() + 5
            while time.time() < end:
                self.pump(0.1)
                try:
                    if os.waitpid(self.pid, os.WNOHANG)[0] == self.pid:
                        os.close(self.fd)
                        return
                except ChildProcessError:
                    os.close(self.fd)
                    return
        os.close(self.fd)


def adapter(question, req, home, opencode):
    p = subprocess.run([ADAPTER, question, json.dumps(req)], capture_output=True, text=True, timeout=30,
                       env={"PATH": os.path.dirname(opencode) + ":/usr/bin:/bin", "HOME": home})
    return json.loads(p.stdout)


def main():
    opencode = shutil.which("opencode")
    if not opencode:
        print("skip: no opencode on PATH")
        return 0
    out = subprocess.run([opencode, "--version"], capture_output=True, text=True, timeout=30).stdout
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", out)
    if not m or int(m.group(1)) < 2:
        print("skip: opencode %s is not 2.0 or later" % out.strip())
        return 0
    base = tempfile.mkdtemp(prefix="oc1806-live-")
    try:
        return run(base, opencode)
    finally:
        shutil.rmtree(base, ignore_errors=True)


def run(base, opencode):
    home, cwd, calls = (os.path.join(base, d) for d in ("home", "proj", "calls"))
    for d in (home, cwd, calls):
        os.makedirs(d)
    with open(os.path.join(base, "fake-polter"), "w") as f:
        f.write(FAKE_POLTER % calls)
    os.chmod(os.path.join(base, "fake-polter"), 0o755)
    for name, src in (("fake-model.py", FAKE_MODEL), ("fake-mcp.py", FAKE_MCP)):
        with open(os.path.join(base, name), "w") as f:
            f.write(src)
    for name in ("noisy", "kept"):
        d = os.path.join(home, ".config", "opencode", "skills", name)
        os.makedirs(d)
        with open(os.path.join(d, "SKILL.md"), "w") as f:
            f.write("---\nname: %s\ndescription: probe skill %s\n---\nbody\n" % (name, name))
    mcp = [sys.executable, os.path.join(base, "fake-mcp.py")]
    with open(os.path.join(home, ".config", "opencode", "opencode.json"), "w") as f:
        json.dump({"mcp": {"probe": {"type": "local", "command": mcp}, "other": {"type": "local", "command": mcp}}}, f)
    plugin_before = sorted(os.listdir(HOOKS))

    model_port = free_port()
    model_log = os.path.join(base, "model.log")
    model = subprocess.Popen([sys.executable, os.path.join(base, "fake-model.py"), str(model_port), model_log],
                             stderr=subprocess.DEVNULL)

    # The launch, as the adapter writes it for a role that switches off
    # `noisy` and `probe` and names a model -- with the stand-in Polter
    # where the real one goes. The role's first prompt is the first turn.
    req = {"version": 1, "cwd": cwd, "home": home, "polter": os.path.join(base, "fake-polter"), "session": None,
           "role": {"model": "fake/m", "instructions": "hello probe"},
           "cli": {"skills": {"default": True, "except": ["skill:noisy"]},
                   "mcp": {"default": True, "except": ["mcp:probe"]}}}
    launch = adapter("launch", req, home, opencode)
    check("launch", launch.get("hooks") is True, "the adapter gave this opencode Polter's hooks: %s" % launch["notes"])
    check("launch", launch["argv"][:2] == ["opencode", "--standalone"], "on a server of its own: %s" % launch["argv"])
    content = json.loads(launch["env"]["OPENCODE_CONFIG_CONTENT"])
    # The stand-in model's provider is the test's, not the role's.
    content["provider"] = {"fake": {"npm": "@ai-sdk/openai-compatible", "models": {"m": {"name": "m"}},
                                    "options": {"baseURL": "http://127.0.0.1:%d/v1" % model_port, "apiKey": "x"}}}
    content["permission"]["bash"] = "ask"

    env = dict(launch["env"], OPENCODE_CONFIG_CONTENT=json.dumps(content), PATH=os.path.dirname(opencode) + ":/usr/bin:/bin",
               HOME=home, XDG_CONFIG_HOME=home + "/.config", XDG_DATA_HOME=home + "/.local/share",
               XDG_STATE_HOME=home + "/.local/state", XDG_CACHE_HOME=home + "/.cache", TERM="xterm-256color",
               OPENCODE_DISABLE_MODELS_FETCH="1")

    # A record that is not one JSON object is two `+hook`s at once into one
    # slot -- two copies of the plugin, which is what a shared service made
    # (measured with `--standalone` taken out). It is kept, as not an event,
    # for `hooks` below to fail on, and the rest of the run goes on.
    def events():
        seen = []
        for name in sorted(os.listdir(calls)):
            if name.endswith(".argv"):
                with open(os.path.join(calls, name)) as f:
                    argv = f.read().split()
                with open(os.path.join(calls, name[:-5] + ".json")) as f:
                    text = f.read()
                try:
                    seen.append((argv, json.loads(text)))
                except ValueError:
                    seen.append((argv, {"unreadable": text[:200]}))
        return seen

    def wait_for(tui, name, since, secs=40):
        end = time.time() + secs
        while time.time() < end:
            tui.pump(0.3)
            for argv, payload in events()[since:]:
                if argv[-1] == name and isinstance(payload.get("data"), dict):
                    return payload
        return None

    tui = Tui(launch["argv"], env, cwd)
    sid = None
    try:
        # The first turn is the role's instructions, typed and sent by the
        # TUI itself (`--prompt`).
        n = 0
        check("prompt", wait_for(tui, "session.created", n) is not None, "the role's first prompt makes a session")
        done = wait_for(tui, "session.execution.succeeded", n)
        check("turn", done is not None and done["polter"].get("answer") == "pong from the stand-in model",
              "the first prompt is a turn that ends with its answer: %s" % (done and done["polter"]))
        sid = done and done["data"]["sessionID"]

        n = len(events())
        tui.type("RUNCMD please")
        asked = wait_for(tui, "permission.asked", n)
        check("approval", asked is not None and asked["data"].get("action") == "shell"
              and asked["data"].get("resources") == ["echo oc-probe"],
              "a command to approve is asked about, by its action and command: %s" % (asked and asked["data"]))
        tui.pump(1)
        tui.key("\r")
        check("approval", wait_for(tui, "permission.replied", n) is not None, "and answered at the box")
        check("approval", wait_for(tui, "session.execution.succeeded", n) is not None, "and the turn ends")

        n = len(events())
        tui.type("ASKQ now")
        form = wait_for(tui, "form.created", n)
        check("question", form is not None and form["data"]["form"]["metadata"]["kind"] == "question",
              "a question is a form of kind question")
        tui.pump(1)
        tui.key("\r")
        check("question", wait_for(tui, "form.replied", n) is not None, "and its answer is said")
        check("question", wait_for(tui, "session.execution.succeeded", n) is not None, "and the turn ends")

        n = len(events())
        tui.type("SUBAGENT go")
        sub_done = wait_for(tui, "session.execution.succeeded", n)
        sub = events()[n:]
        check("subagent", sub_done is not None and all((p.get("data", {}).get("sessionID") or sid) == sid for _, p in sub),
              "a subagent's own session says nothing: every event is the terminal's session's (%d)" % len(sub))
        check("subagent", [a[-1] for a, _ in sub].count("session.execution.succeeded") == 1,
              "one end, the terminal's turn's")

        n = len(events())
        tui.type("SLOWLY please")
        check("interrupt", tui.wait_text("tick2", 30), "a slow answer is under way")
        tui.key(ESC)
        tui.key(ESC)
        stopped = wait_for(tui, "session.execution.interrupted", n, 15)
        check("interrupt", stopped is not None and stopped["data"].get("reason") == "user",
              "Esc twice stops the turn, said as interrupted: %s" % (stopped and stopped["data"]))

        n = len(events())
        tui.type("FAIL400 now")
        failed = wait_for(tui, "session.execution.failed", n)
        check("error", failed is not None and failed["data"]["error"].get("type") == "provider.invalid-request",
              "an API error ends the turn, with its type: %s" % (failed and failed["data"]["error"]))

        n = len(events())
        tui.type("FAIL429 now")
        retry = wait_for(tui, "session.retry.scheduled", n)
        check("retry", retry is not None and isinstance(retry["data"].get("attempt"), int)
              and retry["data"]["error"].get("type") == "provider.rate-limit",
              "a rate limit is retried, and said with its attempt: %s" % (retry and retry["data"].get("attempt")))
        tui.key(ESC)
        tui.key(ESC)
        check("retry", wait_for(tui, "session.execution.interrupted", n, 15) is not None, "and Esc stops the retrying")
    finally:
        tui.stop()

    # Going on with that session: the adapter passes it on, and the TUI
    # opens it -- its next turn is that session's, and no new one is made.
    req2 = dict(req, session=sid, role={"model": "fake/m"})
    again = adapter("launch", req2, home, opencode)
    check("resume", sid is not None and again["argv"][-2:] == ["-s", sid], "the session is passed on: %s" % again["argv"])
    env2 = dict(env, OPENCODE_CONFIG_CONTENT=json.dumps(dict(json.loads(again["env"]["OPENCODE_CONFIG_CONTENT"]),
                                                              provider=content["provider"])))
    tui = Tui(again["argv"], env2, cwd)
    try:
        # Not read off the screen: what it draws of an old conversation is
        # in pieces once its escapes are taken out. Its next turn says.
        tui.pump(6)
        n = len(events())
        tui.type("hello again")
        began = wait_for(tui, "session.execution.started", n)
        check("resume", began is not None and began["data"]["sessionID"] == sid
              and "session.created" not in [a[-1] for a, _ in events()[n:]],
              "the next turn is the old session's, and no session is made")
        wait_for(tui, "session.execution.succeeded", n)
    finally:
        tui.stop()
        model.terminate()
        model.wait(5)

    seen = events()
    print("events seen, in order:")
    for argv, payload in seen:
        print("   %-30s %s" % (argv[-1], json.dumps(payload.get("polter") or {})[:80]))

    check("hooks", seen and all(a[:3] == ["+hook", "--cli", "opencode"] for a, _ in seen),
          "every call is `+hook --cli opencode <event>`")
    check("hooks", all(p.get("type") == a[-1] and isinstance(p.get("data"), dict) for a, p in seen),
          "each names the event it carries, and carries opencode's `data`")
    order = [a[-1] for a, _ in seen]
    for want in ("tool.execute.before", "tool.execute.after"):
        check("events", want in order, "%s was said" % want)

    # No shared service was started, or left behind.
    state = os.path.join(home, ".local", "state", "opencode", "service.json")
    left = subprocess.run(["pgrep", "-f", "opencode serve --service"], capture_output=True, text=True).stdout.split()
    mine = [p for p in left if ("HOME=" + home) in subprocess.run(["ps", "-E", "-o", "command=", "-p", p],
                                                                  capture_output=True, text=True).stdout]
    check("standalone", not os.path.exists(state) and not mine,
          "no background service: no service.json, no `serve --service` of this HOME (%s)" % mine)
    check("standalone", sorted(os.listdir(HOOKS)) == plugin_before, "nothing was written into the plugin's directory")

    # The role's switches, read off what opencode sent the model: the skills
    # in its instructions, the MCP servers' tools in the `execute` tool's.
    with open(model_log) as f:
        sent = f.read()
    check("switches", "<id>kept</id>" in sent and "<id>noisy</id>" not in sent,
          "the switched-off skill is not in the list the model is given, the other one is")
    check("switches", "tools.other.ping" in sent and "tools.probe.ping" not in sent,
          "the switched-off server's tools are not the model's, the other one's are")

    print("all hold" if not failures else "%d DO NOT HOLD" % len(failures))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
