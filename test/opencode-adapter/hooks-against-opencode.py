#!/usr/bin/env python3
"""Polter's opencode plugin and a role's switches, run by a real opencode.

Task 1777. What `adapter.py` (beside this file) checks is the launch the
adapter writes; this hands that launch to the opencode on this machine and
reads what came of it. Nothing is spent and nothing of the person's is read
or written:

  * a throwaway `HOME` (and `XDG_*`), so opencode's configuration, database
    and cache are made here and thrown away;
  * a stand-in model: a local OpenAI-compatible server on 127.0.0.1 that
    answers from a script, keeps what it was sent, and fails on purpose when
    told to (`FAIL400`, `FAIL429`), or asks to run a command (`RUNCMD`);
  * a stand-in Polter: `POLTER_HOOK_EXE` names a script that writes down each
    `+hook` it is run as -- its arguments and its stdin -- and does nothing;
  * a stand-in MCP server, `probe`, which the role switches off, beside a
    skill it switches off and one it leaves on.

opencode is driven through `opencode serve` and its HTTP API -- a session,
four turns, a permission answered, an abort -- rather than its TUI: `opencode
run` exits as a turn ends, before the plugin's last event is out.

    python3 test/opencode-adapter/hooks-against-opencode.py

Skips (exit 0, says so) when there is no `opencode` here. Exit 0 when every
case holds; the events seen are printed either way.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ADAPTER = os.path.join(ROOT, "plugins", "opencode", "adapter.py")

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
        if "RUNCMD" in text and msgs[-1].get("role") == "user":
            send(chunk({"role": "assistant", "tool_calls": [{"index": 0, "id": "call_1", "type": "function",
                 "function": {"name": "bash", "arguments": json.dumps({"command": "echo oc-probe", "description": "Probe"})}}]}))
            send(chunk({}, "tool_calls"))
        else:
            send(chunk({"role": "assistant", "content": "pong from the stand-in model"}))
            send(chunk({}, "stop"))
        send({"id": "c1", "object": "chat.completion.chunk", "created": 0, "model": "m", "choices": [],
              "usage": {"prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7}})
        self.wfile.write(b"data: [DONE]\n\n")
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


def main():
    base = tempfile.mkdtemp(prefix="oc1777-live-")
    try:
        return run(base)
    finally:
        shutil.rmtree(base, ignore_errors=True)


def run(base):
    opencode = shutil.which("opencode")
    if not opencode:
        print("skip: no opencode on PATH")
        return 0

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
    with open(os.path.join(home, ".config", "opencode", "opencode.json"), "w") as f:
        json.dump({"mcp": {"probe": {"type": "local", "command": [sys.executable, os.path.join(base, "fake-mcp.py")]}}}, f)

    model_port, serve_port = free_port(), free_port()
    model_log = os.path.join(base, "model.log")

    # The launch, as the adapter writes it for a role that switches off
    # `noisy` and `probe` -- with the stand-in Polter where the real one goes.
    req = {"version": 1, "cwd": cwd, "home": home, "polter": os.path.join(base, "fake-polter"), "session": None,
           "role": {}, "cli": {"skills": {"default": True, "except": ["skill:noisy"]},
                               "mcp": {"default": True, "except": ["mcp:probe"]}}}
    p = subprocess.run([ADAPTER, "launch", json.dumps(req)], capture_output=True, text=True, timeout=30,
                       env={"PATH": os.path.dirname(opencode) + ":/usr/bin:/bin", "HOME": home})
    launch = json.loads(p.stdout)
    check("launch", launch.get("hooks") is True, "the adapter gave this opencode Polter's hooks: %s" % launch["notes"])
    content = json.loads(launch["env"]["OPENCODE_CONFIG_CONTENT"])
    # The stand-in model is the test's, not the role's.
    content["model"] = "fake/m"
    content["provider"] = {"fake": {"npm": "@ai-sdk/openai-compatible", "models": {"m": {"name": "m"}},
                                    "options": {"baseURL": "http://127.0.0.1:%d/v1" % model_port, "apiKey": "x"}}}
    content["permission"]["bash"] = "ask"

    env = dict(launch["env"], OPENCODE_CONFIG_CONTENT=json.dumps(content), PATH=os.path.dirname(opencode) + ":/usr/bin:/bin",
               HOME=home, XDG_CONFIG_HOME=home + "/.config", XDG_DATA_HOME=home + "/.local/share",
               XDG_STATE_HOME=home + "/.local/state", XDG_CACHE_HOME=home + "/.cache",
               OPENCODE_DISABLE_DEFAULT_PLUGINS="1", OPENCODE_DISABLE_MODELS_FETCH="1")
    model = subprocess.Popen([sys.executable, os.path.join(base, "fake-model.py"), str(model_port), model_log])
    serve = subprocess.Popen([opencode, "serve", "--port", str(serve_port)], cwd=cwd, env=env,
                             stdout=open(os.path.join(base, "serve.log"), "w"), stderr=subprocess.STDOUT)
    q = "?directory=" + urllib.request.quote(cwd)

    def call(method, path, body=None, timeout=60):
        r = urllib.request.Request("http://127.0.0.1:%d%s%s" % (serve_port, path, q), method=method,
                                   data=None if body is None else json.dumps(body).encode(),
                                   headers={"content-type": "application/json"})
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            t = resp.read()
            return json.loads(t) if t else None

    def events():
        out = []
        for name in sorted(os.listdir(calls)):
            if name.endswith(".argv"):
                with open(os.path.join(calls, name)) as f:
                    argv = f.read().split()
                with open(os.path.join(calls, name[:-5] + ".json")) as f:
                    out.append((argv, json.load(f)))
        return out

    def wait_for(name, since, secs=30):
        end = time.time() + secs
        while time.time() < end:
            if any(argv[-1] == name for argv, _ in events()[since:]):
                return True
            time.sleep(0.3)
        return False

    msg = lambda t: {"parts": [{"type": "text", "text": t}]}
    try:
        for _ in range(120):
            try:
                call("GET", "/session")
                break
            except Exception:
                time.sleep(0.5)
        sid = call("POST", "/session", {})["id"]
        n = len(events())
        call("POST", "/session/%s/message" % sid, msg("hello probe"), 90)
        check("turn", wait_for("session.idle", n), "a turn ends in an idle")
        n = len(events())
        call("POST", "/session/%s/prompt_async" % sid, msg("RUNCMD please"))
        check("approval", wait_for("permission.asked", n), "a command to approve is asked about")
        perms = call("GET", "/permission")
        call("POST", "/permission/%s/reply" % perms[0]["id"], {"reply": "once"})
        check("approval", wait_for("session.idle", n, 40), "and once answered, the turn ends")
        n = len(events())
        try:
            call("POST", "/session/%s/message" % sid, msg("FAIL400 now"), 60)
        except Exception:
            pass
        check("error", wait_for("session.error", n) and wait_for("session.idle", n), "an API error, then idle")
        n = len(events())
        call("POST", "/session/%s/prompt_async" % sid, msg("FAIL429 now"))
        check("retry", wait_for("session.retry", n), "a rate limit is retried, and said")
        call("POST", "/session/%s/abort" % sid, {})
        check("abort", wait_for("session.error", n, 15), "an abort is an error")
        time.sleep(2)
    finally:
        serve.terminate()
        model.terminate()
        try:
            serve.wait(10)
        except subprocess.TimeoutExpired:
            serve.kill()
        model.wait(5)

    seen = events()
    print("events seen, in order:")
    for argv, payload in seen:
        extra = payload.get("polter") or {}
        print("   %-22s %s" % (argv[-1], json.dumps(extra)[:90]))

    check("hooks", all(a[:3] == ["+hook", "--cli", "opencode"] for a, _ in seen) and seen,
          "every call is `+hook --cli opencode <event>`")
    check("hooks", all(p.get("type") in ("session.status", a[-1]) for a, p in seen),
          "each names the event it carries")
    idles = [p["polter"] for a, p in seen if a[-1] == "session.idle"]
    answers = [i["answer"] for i in idles if not i.get("error")]
    check("answer", answers[:2] == ["pong from the stand-in model"] * 2,
          "a turn that ended says what it answered: %s" % answers)
    check("answer", len(answers) == 2,
          "and only those two: every idle after an error or an abort carries the error (%s)" % idles)
    order = [a[-1] for a, _ in seen]
    for want in ("session.created", "chat.message", "tool.execute.before", "permission.asked",
                 "permission.replied", "tool.execute.after"):
        check("events", want in order, "%s was said" % want)
    errors = [p["properties"]["error"]["name"] for a, p in seen if a[-1] == "session.error"]
    check("events", errors == ["APIError", "MessageAbortedError"], "the two errors, by name: %s" % errors)

    # The role's switches, read off what opencode sent the model.
    with open(model_log) as f:
        bodies = [json.loads(line) for line in f if line.strip()]
    tools = set()
    skill_text = ""
    for b in bodies:
        for t in b.get("tools") or []:
            fn = t.get("function") or {}
            tools.add(fn.get("name"))
            if fn.get("name") == "skill":
                skill_text = fn.get("description") or ""
    check("switches", "bash" in tools and not any(t and t.startswith("probe_") for t in tools),
          "the switched-off server's tools are not the model's: %s" % sorted(t for t in tools if t))
    check("switches", "kept" in skill_text and "noisy" not in skill_text,
          "the switched-off skill is not in the list the model is given, the other one is")

    print("all hold" if not failures else "%d DO NOT HOLD" % len(failures))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
