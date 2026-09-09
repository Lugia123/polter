#!/usr/bin/env python3
"""Every way the agent socket turns a connection away must say which one it was.

# What this is for

A refused connection is the only thing an agent CLI ever learns about, and
the only thing it learns is `CONNECTION_CLOSED`. Whatever the server does
before it closes is the whole of the channel: there is no session to answer
in, no terminal to type into, and the client cannot ask a second time.

The path this guards had three refusals and one of them was silent. Missing
socket and bad token both wrote a sentence; **all slots in use** wrote a
`log.warn` and closed. `GHOSTTY_LOG` is unset for almost everybody, so the
measured result was an agent CLI showing `CONNECTION_CLOSED`, a cache file
saying `EndOfStream`, and -- because the slots stay full while those agents
live -- *every terminal opened afterwards behaving the same way*. It took
reading a constant out of the source to find the cause.

`cli/mcp.zig::complain` had already written the argument down for its own
half of this path: *"a diagnostic that was written and then thrown away
costs more than none, because its author believes the user has been told."*
One file over, the same path, and this half did not get it. That is what a
gate is for.

# What it checks

1. The full-slots refusal in `server.zig` writes on the socket before it
   closes. A `log.warn` there is not a diagnostic anyone will read.
2. The refusal code is one string, named in both files, so the client's
   match cannot silently stop matching. Two literals that must agree and are
   never compared are a protocol nobody is holding.
3. `cli/mcp.zig` matches that code and prints for the person, on stderr --
   never stdout, which is the protocol stream.

# NOT CHECKED

- **Whether the sentences are true.** A refusal naming the wrong reason
  passes every assertion here.
- **Whether the person ever sees it.** The client's stderr reaches an MCP log
  file; whether an agent CLI puts it in front of anybody is not ours.
- **Refusals added elsewhere.** The subjects are named, so a fourth way to
  turn a connection away starts out unwatched -- said here rather than
  guarded, which is writing it down and not a criterion.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "src" / "poltergeist" / "server.zig"
CLIENT = ROOT / "src" / "cli" / "mcp.zig"

# The name of the constant, not its value: the value is what the two files
# have to agree on, and reading it from one of them is the point.
CODE_DECL = re.compile(
    r'pub const full_refusal_code\s*=\s*"([A-Za-z0-9_]+)"'
)


def strip_comments(text: str) -> str:
    """Drop `//` comments before searching.

    A scanner that reads the prose explaining it is measuring nothing: this
    file's own subject names appear in the doc comments beside them, and a
    check that matched those would stay green after the code was removed.
    Learned the hard way one gate over, where exactly that happened.
    """
    out = []
    for line in text.splitlines():
        i = line.find("//")
        out.append(line if i < 0 else line[:i])
    return "\n".join(out)


def self_test() -> None:
    """Two shapes that must be told apart, run on every invocation.

    A gate whose probes live only in a test file is a gate whose probes stop
    being run. These are cheap enough to run always, and their output is the
    first line so that a silent pass is visibly a pass.
    """
    speaks = 'self.refuseFull(stream);\n    stream.close(self.io);'
    silent = 'log.warn("too many", .{});\n    stream.close(self.io);'
    assert refusal_speaks(speaks), "probe: a refusal that writes was not seen"
    assert not refusal_speaks(silent), "probe: a silent refusal was let through"
    print(
        "probe self-test: OK "
        "(a refusal that writes and one that only logs are told apart)"
    )


def refusal_speaks(body: str) -> bool:
    """Is there a write on the socket before the close?"""
    close = body.find("stream.close")
    if close < 0:
        return False
    return "refuseFull" in body[:close]


def main() -> int:
    self_test()

    server = SERVER.read_text(encoding="utf-8")
    client = CLIENT.read_text(encoding="utf-8")
    server_code = strip_comments(server)
    client_code = strip_comments(client)

    problems: list[str] = []

    # 1. The refusal writes before it closes.
    #
    # Anchored on `claimSlot ... orelse`, which is the branch itself rather
    # than a line number or a nearby comment. If that expression is renamed
    # the gate goes red rather than quietly watching nothing -- an empty
    # subject set is the failure this whole file exists to prevent.
    m = re.search(
        r"claimSlot\([^)]*\)\s*orelse\s*\{(.*?)\n        \};",
        server_code,
        re.S,
    )
    if m is None:
        problems.append(
            "server.zig: could not find the full-slots refusal "
            "(`claimSlot(...) orelse {`). If it moved, move this check with "
            "it; if it is gone, so is the thing being guarded."
        )
    elif not refusal_speaks(m.group(1)):
        problems.append(
            "server.zig: the full-slots refusal closes the connection "
            "without writing on it first.\n"
            "      A `log.warn` is not a diagnostic: GHOSTTY_LOG is unset "
            "for almost everybody who reaches this, and the client has no "
            "session to be told in afterwards. Call `refuseFull` before "
            "`stream.close` -- see `cli/mcp.zig::complain` for why."
        )

    # 2. One code, named in both files.
    decl = CODE_DECL.search(server)
    if decl is None:
        problems.append(
            "server.zig: `pub const full_refusal_code` is gone. The client "
            "matches on it; a literal in each file that nothing compares is "
            "a protocol nobody is holding."
        )
    else:
        code = decl.group(1)
        if "full_refusal_code" not in client_code:
            problems.append(
                f"cli/mcp.zig: does not reference `full_refusal_code` "
                f"(currently {code!r}).\n"
                "      Matching the literal instead means the day somebody "
                "edits one of the two, the refusal silently stops being "
                "recognised and the user is back to `EndOfStream`."
            )

    # 3. The client says it to the person, on stderr.
    if "full_refusal_code" in client_code:
        after = client_code.split("full_refusal_code", 1)[1][:1200]
        if "stderr" not in after:
            problems.append(
                "cli/mcp.zig: the full-slots branch does not write to "
                "stderr.\n"
                "      stdout is the JSON-RPC stream -- a diagnostic there "
                "trades a silent failure for a corrupt one."
            )

    if problems:
        print("FAIL: a refusal on the agent socket says nothing:")
        for p in problems:
            print(f"      {p}")
        return 1

    print(
        "The agent socket's refusals were read: the full-slots branch writes "
        "before it closes, and the client matches the shared code and tells "
        "the person on stderr."
    )
    print(
        "NOT CHECKED: whether the sentences are true; whether any agent CLI "
        "shows the user its server's stderr; refusals added somewhere other "
        "than the branch named here."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
