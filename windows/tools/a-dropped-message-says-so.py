#!/usr/bin/env python3
"""A non-blocking send that is thrown away leaves no trace that it happened.

**Written from a full mailbox that nobody could see.** A pane stopped
repainting; its renderer thread had stopped draining its mailbox; the queue
filled; and the first thing to notice was the *UI thread*, minutes later,
blocking forever on the next blocking send. In between, the one signal that
would have named the cause -- "the renderer mailbox is full" -- was produced
once or twice a second and discarded, because the send that produced it was
non-blocking and its result was assigned to `_`.

⚠️ **This is worse than no signal.** The log of a terminal whose renderer
died looks exactly like the log of a quiet, healthy one. Every reader who
went looking read the silence as "nothing is being queued".

**The rule.** A non-blocking send (`.instant`) returns whether it succeeded.
Either read that value -- log it, retry it, count it -- or say in a comment
next to it why losing this particular message costs nothing. `_ =` with no
reason is the shape that produced the invisible failure.

⚠️ **Default include.** Every `.instant` send in `src/` is a subject. The
exception is not a list of files; it is a sentence next to the call.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "src"

# A non-blocking send. The timeout may be written `.instant` or `.{ .instant = {} }`.
INSTANT = re.compile(r"\.instant\b")

# The result being thrown away: `_ = <something>` opening the statement that
# the `.instant` belongs to.
DISCARDED = re.compile(r"^\s*_\s*=\s")

# A reason has to be about the loss, not about what the message is. "Send the
# tick to the surface" is a description; "losing one costs nothing" is a
# reason.
REASON = re.compile(
    r"\b(lose|loses|losing|lost|drop|drops|dropped|discard|discarded|"
    r"not worth blocking|best.effort)\b",
    re.IGNORECASE,
)


def statements(text: str):
    """Yield (line_no, statement_text, preceding_comment_block) per `.instant`.

    ⚠️ **The statement is cut on `;` at bracket depth zero, not on line
    shape.** A send is routinely written across four lines with the `_ =` on
    the first and the `.instant` on the third; any reader that looks at "the
    line the match is on", or that stops as soon as the text it has gathered
    happens to balance, sees `.{ .instant = {} },` and decides the result was
    not discarded. That reader reports zero findings on a tree full of them,
    and zero findings is what a clean tree looks like.
    """
    # Depth counts only the brackets an *expression* nests in. Counting `{}`
    # too would keep the depth at one or more everywhere inside a function
    # body, so no `;` would ever be seen at depth zero and the reader would
    # find nothing at all.
    depth = 0
    start = 0
    for i, ch in enumerate(text):
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif ch in "{}" and depth == 0:
            start = i + 1
        elif ch == ";" and depth == 0:
            stmt = text[start : i + 1]
            if INSTANT.search(stmt):
                # ⚠️ The cut runs from the previous `;`, so any comment
                # written above the call is part of this slice. Split it off
                # explicitly -- leaving it attached makes every commented
                # call look like it does not begin with `_ =`, which silently
                # empties the subject set.
                comment_lines = []
                body_lines = []
                for raw in stmt.split("\n"):
                    if not body_lines and (
                        not raw.strip() or raw.strip().startswith("//")
                    ):
                        comment_lines.append(raw)
                    else:
                        body_lines.append(raw)
                body = "\n".join(body_lines).strip()
                line_no = text[: start + len("\n".join(comment_lines))].count("\n") + 1
                yield line_no, body, "\n".join(comment_lines)
            start = i + 1
        elif ch == "\n" and depth == 0 and not text[start : i + 1].strip():
            start = i + 1


def main() -> int:
    # The probe carries the defect's real shape and the two accepted shapes.
    bad = "    _ = self.renderer_mailbox.push(global.io(), .{\n        .reset_cursor_blink = {},\n    }, .{ .instant = {} });\n"
    read = "    if (self.mailbox.push(msg, .{ .instant = {} }) == 0) {\n        log.warn(\"full\", .{});\n    }\n"
    excused = "    // Losing one to a full mailbox costs nothing.\n    _ = io.mailbox.push(msg, .{ .instant = {} });\n"

    def verdict(text: str) -> bool:
        """True when this text would be reported as a silent drop."""
        for _, stmt, comment in statements(text):
            first = stmt
            if DISCARDED.match(first) and not REASON.search(comment):
                return True
        return False

    probe_ok = verdict(bad) and not verdict(read) and not verdict(excused)
    print(
        "probe self-test:",
        "OK (a silent discard, a read result and an excused loss are told apart)"
        if probe_ok
        else "FAILED -- the reader is broken, so nothing below means anything",
    )
    if not probe_ok:
        return 2

    subjects = 0
    silent = []
    for path in sorted(SRC.rglob("*.zig")):
        text = path.read_text(encoding="utf-8")
        for line_no, stmt, comment in statements(text):
            first = stmt
            if not DISCARDED.match(first):
                continue
            subjects += 1
            if not REASON.search(comment):
                silent.append((path.relative_to(ROOT).as_posix(), line_no))

    # ⚠️ **Nothing to look at is not a pass.** A reader that no longer finds
    # the shape returns 0, and that is indistinguishable from a tree in which
    # every discarded send carries its reason.
    if subjects == 0:
        print(
            "FAIL: no discarded non-blocking send was found in src/ at all -- either\n"
            "      the shape this reads has changed, or the reader is broken. Passing\n"
            "      here would say 'every drop is accounted for' about no drops."
        )
        return 1

    print(f"{subjects} discarded non-blocking send(s) were read.")
    if silent:
        print("FAIL: a non-blocking send is discarded without saying why the loss is ok:")
        for rel, line in silent:
            print(f"      {rel} line {line}")
        print(
            "      Either read the result -- count it, log it, retry it -- or write the\n"
            "      reason next to it. A send that fails silently makes a full mailbox\n"
            "      look exactly like an idle one."
        )
        return 1

    print("Nothing to report: every discarded non-blocking send says why the loss is ok.")
    print(
        "NOT CHECKED: whether the stated reason is true, whether the messages whose\n"
        "             result *is* read are handled correctly, and blocking sends."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
