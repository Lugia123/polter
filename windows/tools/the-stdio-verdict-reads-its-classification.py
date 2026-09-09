#!/usr/bin/env python3
"""The stdio verdict says what it read, not what somebody expected it to read.

# The defect this is the floor for

`adopt_std_handles` classifies the standard handles into three kinds. On the
one path where the log file cannot be opened at all, it wrote a verdict that
stated flatly:

    libghostty's log and any panic backtrace have NO sink this run

**Measured false.** In the run that printed it, the core wrote **193 records**
into the very file the reader was being told was empty. The reason is in the
classification the same function had just computed: a *colliding* handle is by
definition one that already points at the log file, so failing to re-point it
leaves it pointing there. What the failure establishes is that **this function
re-pointed nothing** -- not that the core has nowhere to write, which was
decided before the process started, by whoever started it.

⚠️ **The two facts had been written as one sentence**, and the person reading
this verdict is deciding whether their core log went missing. The wrong one of
the two sends them to look in the wrong place -- at exactly the moment the log
is the only thing they have.

# What is checked

  1. **The verdict asks.** The failure path must call `core_sink_note(`; that
     function answers from the counts rather than from a sentence written in
     advance.
  2. **No verdict text asserts the absence of a sink.** Anywhere in `main.rs`,
     outside comments, a string claiming there is no sink is the shape that
     was measured false. Comments are stripped first: the paragraphs
     explaining this rule name the wording, and a checker that flagged its own
     explanation is a checker somebody turns off.
  3. **The function it asks is still there**, by definition, so that renaming
     it away cannot pass by making rule 1 vacuous.

# NOT CHECKED

  * **Whether the sentences are true.** `core_sink_note` has unit tests beside
    it (`core_sink_note_tests`) that hold the collision case to "still point at
    this log file" and the missing case to "lost this run". ⚠️ Those run only
    on Windows -- the host crate does not build for the machine this checker
    runs on -- so they are compiled, not run.
  * **Streams that were given and name something else** (a pipe, a console,
    another file). They are in neither count, they were never this function's
    to move, and where their output goes is not something the process can read
    back. **Unmeasured, not absent.**
  * **Every other verdict in this host.** The scan is one file and one family
    of claim; a verdict elsewhere that overstates what it read is not seen
    here.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, "..", "host", "src", "main.rs")

ASKS = "core_sink_note("
DEFINES = re.compile(r"\bfn\s+core_sink_note\s*\(")
# Built from halves so this file can describe the wording without matching a
# copy of itself if the scan is ever pointed at this directory.
NO_SINK = re.compile(r"\bno\s+" + "sink", re.IGNORECASE)
ADOPTS = re.compile(r"\bfn\s+adopt_std_handles\s*\(")


def adopt_body(plain):
    m = ADOPTS.search(plain)
    return body_of(plain, m.end()) if m else ""


def strip_comments(src):
    return "\n".join(re.sub(r"//.*", "", ln) for ln in src.split("\n"))


def body_of(src, start):
    """The braced block that starts at or after `start`."""
    i = src.find("{", start)
    if i < 0:
        return ""
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i : j + 1]
    return src[i:]


def findings(src):
    out = []
    plain = strip_comments(src)

    if not DEFINES.search(plain):
        out.append(
            "`core_sink_note` is gone. The verdict then has nothing to ask, and rule 1 "
            "below would pass by being vacuous -- which is why this is checked first"
        )
    elif ASKS not in adopt_body(plain):
        # ⚠️ **Counted inside `adopt_std_handles`, not across the file.** The
        # unit tests beside it call this function too, so a file-wide count
        # stays satisfied by them while the verdict itself has stopped asking
        # -- a rule that cannot fail on its own is not a rule.
        out.append(
            "the stdio verdict does not call `core_sink_note`. Whatever it says about "
            "libghostty's output is then written in advance rather than read from the "
            "classification -- the shape that told a reader the log was empty while 193 "
            "core records were going into it"
        )

    for m in NO_SINK.finditer(plain):
        line = plain[: m.start()].count("\n") + 1
        out.append(
            f"main.rs line {line}: a verdict claims there is no sink. That is a claim about "
            "where the core writes, which this process did not read and cannot: a collided "
            "handle already points at the log file, and not re-pointing it leaves it pointing "
            "there"
        )
    return out


GOOD = '''
fn core_sink_note(missing: usize, colliding: usize) -> &'static str {
    match (missing > 0, colliding > 0) {
        (false, true) => "Those streams still point at this log file.",
        _ => "lost this run",
    }
}
fn adopt_std_handles() -> String {
    let why = format!("[stdio] {} could not be opened; {}", names, core_sink_note(m.len(), c.len()));
}
'''


def self_test():
    cases = [
        ("the shape today", GOOD, 0),
        # The decoy carries the whole wording: one the scan would not have
        # matched anyway proves nothing about the scan.
        ("the sentence written in advance, back again",
         GOOD.replace("core_sink_note(m.len(), c.len())",
                      '"libghostty\'s log and any panic backtrace have NO sink this run"'),
         2),
        ("the same wording in a comment only",
         GOOD + "// it used to say the streams have NO sink this run\n", 0),
        ("the function renamed away",
         GOOD.replace("core_sink_note", "sink_note_v2"), 1),
        # The call still exists in the file, in the tests -- and the verdict
        # has stopped asking. A file-wide count would sit here green.
        ("the call moved out of the verdict",
         GOOD.replace("core_sink_note(m.len(), c.len())", '"written in advance"')
             + "#[cfg(test)]\nmod t { fn x() { core_sink_note(1, 0); } }\n", 1),
        ("a second verdict that asserts it",
         GOOD + 'fn other() { let s = "the core has no sink"; }\n', 1),
    ]
    ok = True
    for what, src, want in cases:
        got = findings(src)
        if len(got) != want:
            print(f"probe self-test FAILED: {what} gave {len(got)} finding(s), expected {want}:")
            for f in got:
                print(f"    {f}")
            ok = False
    if ok:
        print("probe self-test: OK (the advance sentence, the same wording in a comment, the "
              "function renamed away, the call moved out of the verdict, and a second "
              "verdict asserting it)")
    return ok


def main():
    if not self_test():
        return 1
    try:
        with open(MAIN, encoding="utf-8") as fh:
            src = fh.read()
    except OSError as e:
        print(f"cannot read the host's main.rs: {e}")
        return 1

    found = findings(src)
    plain = strip_comments(src)
    print(f"main.rs: the stdio verdict asks `core_sink_note` "
          f"({plain.count(ASKS) - 1} call site(s)) and asserts no absent sink of its own")
    print("NOT CHECKED: whether those sentences are true. That is `core_sink_note_tests`, "
          "which is compiled here and run only on Windows.")
    for f in found:
        print(f"HIT    {f}")
    if found:
        print(f"\n{len(found)} problem(s): a verdict is saying more than it read.")
        return 1
    print("OK: the verdict reads its own classification.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
