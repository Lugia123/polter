#!/usr/bin/env python3
"""Talk to Polter from a plugin: sixty lines, no vocabulary of its own.

**This is not an SDK.** There is no function here called `group_post`, and
there never will be one. A plugin speaks the *same wire protocol an agent
speaks over MCP* -- a unix socket, an `auth` line, then one JSON object per
line -- so everything the tool surface grows, a plugin has the same day, and
there is no second list of methods for anybody to forget to update. The last
time this project kept a second list of what plugins could be, it went wrong
twice in the same file.

What is here is therefore only the transport -- of which there are two, and
the second one is `tell` at the bottom of this file: the socket carries calls
*out*, and the plugin's own standard output carries reports *back*.

Usage:

    from polter import Polter

    hello = json.loads(sys.stdin.readline())
    with Polter.from_hello(hello) as polter:
        print(polter.call("terminal_list"))

`Polter.from_hello` reads `socket` and `token` out of the greeting the host
writes. Both are absent when Polter's agent socket is off, and `from_hello`
returns `None` then rather than raising: a plugin that only stores events has
nothing to call and must not fail because it cannot.

**What a plugin may call is not decided here.** It is `"wants": {"calls":
[...]}` in the manifest, the host enforces it, and a method that is not in
that list comes back as a refusal naming the missing declaration. That is on
purpose: the user reads the manifest before switching a plugin on, and a
declaration that could be widened at run time would make that reading
worthless.

Python 3.8, standard library only -- under a Polter launched from the Dock
`/usr/bin/env python3` is the system interpreter, not whatever is on a
developer's PATH.
"""

import json
import socket
import sys


class PolterError(Exception):
    """A refusal from Polter, with the code it gave."""

    def __init__(self, code, message):
        Exception.__init__(self, "%s: %s" % (code, message))
        self.code = code
        self.message = message


class Polter:
    """One connection. Authenticated on open, one JSON object per line."""

    def __init__(self, path, token, timeout=10.0):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.stream = self.sock.makefile("rwb")
        self._send({"method": "auth", "params": {"token": token}})
        self._recv()

    @classmethod
    def from_hello(cls, hello, timeout=10.0):
        """Connect using the socket and token in the host's greeting.

        `None` when the greeting carries neither, which is what a plugin sees
        when Polter's agent socket is switched off. Not an error: a plugin
        that only stores what it is handed has nothing to call.
        """
        path = hello.get("socket")
        token = hello.get("token")
        if not path or not token:
            return None
        return cls(path, token, timeout)

    def call(self, method, **params):
        """One call. Returns the reply, raises `PolterError` on a refusal.

        `method` is the name an agent uses -- there is no translation layer,
        because a translation layer is a second vocabulary.
        """
        request = {"method": method}
        if params:
            request["params"] = params
        self._send(request)
        return self._recv()

    def _send(self, obj):
        self.stream.write(json.dumps(obj).encode("utf-8") + b"\n")
        self.stream.flush()

    def _recv(self):
        line = self.stream.readline()
        if not line:
            raise PolterError("Disconnected", "Polter closed the connection")
        reply = json.loads(line.decode("utf-8"))
        if reply.get("ok") is False:
            raise PolterError(
                reply.get("code", "Failed"),
                reply.get("message", "no reason given"),
            )
        return reply

    def close(self):
        try:
            self.stream.close()
        finally:
            self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def tell(text, stream=None):
    """Put one line in front of the user, on the channel you already have.

    Reporting its own state is **part of the protocol, not a capability**, so
    there is nothing to declare in `wants.calls` and nothing to be granted: a
    plugin saying "I could not write that file" is the same fact, on the same
    path, as the host saying "that plugin will not start". It is written on
    standard output -- the channel this plugin already answers on -- as a line
    of its own:

        {"tell": "could not write the skill file: permission denied"}

    and the host prints it where the person at the keyboard will see it. This
    is not `notify_user`: that is a supervisor's method, closed to plugins,
    and it answers an agent with a string rather than reaching anybody.

    **Say the consequence, not only the fault.** The host cannot check this --
    no string test can tell "failed" from "the agent will start with no
    memory of this", and a check that guessed would be believed -- so it is
    yours to keep. You know what your failure costs the user; Polter does not.

    Write it *before* your acknowledgement, or on the same line by adding
    `"ok"` to it. The host reads reports until it gets an answer, so a line
    with only a `tell` in it does not count as one.

    Whatever you pass is treated as untrusted by the host: control characters
    are stripped and the line is clamped to fit a terminal message. Nothing is
    lost by that -- the whole of it is in this plugin's log either way.
    """
    out = stream or sys.stdout
    out.write(json.dumps({"tell": text}, separators=(",", ":")) + "\n")
    out.flush()
