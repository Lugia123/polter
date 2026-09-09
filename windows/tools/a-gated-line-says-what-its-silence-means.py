#!/usr/bin/env python3
"""A log line that can decline to speak must say what its silence means.

**Written from a reading that was wrong for two hours and looked right the
whole time.** A resize instrument produced no lines during an investigation;
that absence was read as "this check point was never reached", and four
candidate causes were struck off it. A second reader then found, in the same
log, a pane that was demonstrably drawing while the same instrument said
nothing -- and the source said why: the line is capped after a fixed number of
frames, with an escape that is false whenever nothing is being resized. The
silence was the design working. Nothing had been ruled out.

# The general shape

Most log statements say something when control reaches them. Some do not:
they sit behind a counter, a budget, a one-shot latch, a modulo, a stopwatch
or a command-line flag, and whether they speak depends on state that has
nothing to do with the event. For those, "no such line in the log" is not one
fact. It can mean any of:

  * the code never ran,
  * the code ran and the gate was shut,
  * the code ran, the gate was open, and the event did not happen.

**A reader cannot tell these apart from the log**, and the two that get
confused are the first two. So the author -- who is the only person holding
the answer -- has to write it down next to the gate.

# Why this is not "every gated line needs a comment"

A rule that says "put a comment here" is satisfied by a comment that says
nothing, and a checker enforcing it goes green over a tree full of `// this is
gated`. **The requirement is a verdict, not a sentence**, so this reads a
fixed vocabulary and nothing else. There are three answers and the author has
to pick one:

    absence: proves nothing
    absence: means it was not reached
    absence: depends -- <why, on this line, not empty>

Picking is the work. A wrong pick is still a claim somebody can find and
argue with, which is more than silence offers.

A fourth marker exists for a different answer:

    not-gated: <reason>

for a statement this file's detector flags whose condition **is** the event
being reported -- a failure report, not a suppressor. That is a real and
common shape (a window class that would not register), and saying so is a
judgement too: it is exactly the judgement that was got wrong upstream, where
a condition that looked like an event turned out to be false in every steady
state.

# What was already here, and what none of it covered

This tree had 53 checkers before this one. Four are adjacent:

  * the per-renderer budget rule asks *where* an instrumentation budget lives
    (per instance, not per process), inside one directory. It says nothing
    about whether the silence of the capped line can be read -- **and it is
    green today on the very line that was misread.**
  * the heartbeat rule asks whether a wakeup is reported before the work
    rather than after, in one file, and its own header says it cannot see
    whether the line is ever reached.
  * the dropped-message rule asks that a discarded non-blocking send leave a
    trace. That is about the send, not about whether the trace speaks.
  * the swallowed-action rule asks that an early return log at all. It
    requires the line to exist; it does not ask whether it fires.

Stated as one sentence, and it is the reason this file exists:

**every existing checker asks whether the line is there, where its budget
lives, or what order it is in -- none of them asks whether its silence can be
read.**

# Subjects

Rust under `windows/host/src/` and Zig under `src/renderer/` and
`src/termio/`. A log statement is a subject when a condition enclosing it, in
the same function, matches the gate vocabulary below.

⚠️ **Default include.** A statement the detector flags is a subject until
somebody writes one of the four markers next to it. There is no file list to
be added to.

⚠️ **The ledger, and what it is not.** `PENDING` names the sites that were
flagged when this file was written and have not been judged yet. It is a debt
that has to shrink, not an exemption: an entry whose condition is edited falls
out of the ledger and must be judged, and an entry that is judged must be
removed from the ledger or this goes red. **A gate that ships red teaches
people to skip it**, which is why the debt is written down rather than
pretended away.

# The one place the verdict is checked against the code

A verdict is a sentence and a sentence can be made false by an edit somewhere
else. For a cap that a written criterion reads back, that is not an academic
risk: the comment says the silence means "nothing changed", somebody deletes
the escape, and the comment survives to keep saying it. `ESCAPE_SITES` names
those caps and requires the binding to still be a disjunction. It is
deliberately a short list -- everywhere else this file believes the author,
because a checker that tried to verify every verdict would be a checker
nobody could keep true.

# Two floors on the detector, and what each one caught

`SUBJECT_FLOOR` is the number of statements found when this was written, and
`VOCABULARY_CENSUS` is how many distinct conditions each alternative of the
vocabulary matched. The census exists because the total alone was proved
insufficient in the writing: breaking one alternative moved nothing, since
that alternative had been matching nothing all along and other spellings
covered the same sites. Four of the sixteen are at zero today. They are kept,
and the census records the zero, so nobody has to guess later whether an
alternative is dead or merely unlucky.

**NOT CHECKED:**

  * **How long a throttle waits.** `THROTTLED_SITES` requires the predicate
    to be there, not that its interval is any particular length: changing one
    second to five leaves this quiet. Pinning the number would make the entry
    a place to argue about a constant, and the number that matters is a
    property of the machine and the workload, not of the source.
  * **That the verdict is right.** This reads which of three words was
    chosen. Choosing wrong produces a wrong claim in a findable place, which
    is the improvement on offer; it is not a proof. `ESCAPE_SITES` is the one
    exception and it covers a single cap.
  * **That the line is ever reached.** An early return above it, or a level
    the sink drops, leaves the same silence.
  * **Gate shapes the vocabulary does not name.** The detector is text over a
    curated list. A suppressor spelled some other way is not flagged -- and a
    subject that was never flagged looks exactly like one that passed. The two
    floors notice the detector *getting* worse; neither can notice it having
    been incomplete from the first day, and no arrangement of them could.
  * **Prose.** A document telling somebody to read one of these lines is
    where the damage was actually done, and this does not read documents.
    That gap is deliberate and named here so it is not mistaken for coverage.

Run:  python3 windows/tools/a-gated-line-says-what-its-silence-means.py
Exit: 0 when every flagged statement outside the ledger carries a verdict.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

SUBJECT_DIRS = [
    (ROOT / "windows" / "host" / "src", "*.rs"),
    (ROOT / "src" / "renderer", "**/*.zig"),
    (ROOT / "src" / "termio", "**/*.zig"),
]

# A log statement, in either language.
LOG = re.compile(r"\b(?:logf|wlogf|plogf|hlogf|alogf)!|\blog\.(?:info|warn|err|debug)\s*\(")

# The gate vocabulary. Each of these, in a condition enclosing a log
# statement, means "whether this speaks depends on more than getting here".
GATE = re.compile(
    r"fetch_add"
    r"|\.take\(\)"
    r"|hasRoom\(\)"
    r"|shouldReport\("
    r"|\.swap\(true"
    r"|\.swap\(1"
    r"|complained"
    r"|\bverbose\b"
    r"|%\s*\d[\d_]*\s*=="
    r"|<=\s*\d"
    r"|>=\s*\d"
    r"|==\s*\d[\d_]*\b"
    r"|elapsed\(\)"
    r"|_LOGGED"
    r"|_ANNOUNCED"
    # `first` earns its place on one real gate -- a divider drag that says why
    # it is going nowhere once per drag rather than once per mouse message --
    # and costs two entries in the ledger where the name means something else.
    # Two entries is the cheaper mistake: a vocabulary that misses a
    # suppressor produces a subject nobody ever looks at.
    r"|\bfirst\b"
    # A predicate whose name ends in `_due` is a rate limit by convention in
    # this tree, and a rate limit is a suppressor: the call says nothing about
    # the event, only about how recently the line last spoke.
    r"|_due\("
)

# The four markers. Horizontal whitespace only -- `\s*` matches a newline, and
# a marker with its reason on the *next* line would then be satisfied by
# whatever happened to follow, which is the failure this spelling avoids.
H = r"[^\S\n]"
VERDICTS = [
    re.compile(rf"//{H}*absence:{H}+proves{H}+nothing\b"),
    re.compile(rf"//{H}*absence:{H}+means{H}+it{H}+was{H}+not{H}+reached\b"),
    re.compile(rf"//{H}*absence:{H}+depends{H}+--{H}+\S"),
    re.compile(rf"//{H}*not-gated:{H}+\S"),
]

COMMENT = re.compile(r"^\s*(?://|/\*|\*)")
BLANK = re.compile(r"^\s*$")

# Sites flagged when this was written and not yet judged. Keyed by file and by
# the text of the gating condition, so that editing the condition drops the
# entry and forces a judgement at exactly the moment somebody is looking at it.
PENDING = {
    ('src/renderer/opengl/wgl.zig', 'if (format == 0) {'),
    ('windows/host/src/ctxmenu.rs', 'if mark.is_none() && !PG_NEVER_TOLD_LOGGED.swap(true, Ordering::AcqRel) {'),
    ('windows/host/src/divider.rs', 'if RegisterClassExW(&wc) == 0 {'),
    ('windows/host/src/hud.rs', 'if RegisterClassExW(&wc) == 0 {'),
    ('windows/host/src/hud.rs', 'if surface == 0 {'),
    ('windows/host/src/keys.rs', 'if addr == 0 {'),
    ('windows/host/src/keyseq.rs', 'if RegisterClassExW(&wc) == 0 {'),
    ('windows/host/src/main.rs', 'if !MISMATCH_LOGGED.swap(true, Ordering::Relaxed) {'),
    ('windows/host/src/main.rs', 'if !first.0.is_null() && ime_init(first) {'),
    ('windows/host/src/main.rs', 'if content.is_null() || n == 0 {'),
    ('windows/host/src/main.rs', 'if first || n % 500 == 0 {'),
    ('windows/host/src/main.rs', 'if id == 0 {'),
    ('windows/host/src/main.rs', 'if n <= 40 {'),
    ('windows/host/src/main.rs', 'if n == 0 {'),
    ('windows/host/src/main.rs', 'if n == 0 || n >= buf.len() {'),
    ('windows/host/src/main.rs', 'if n == 40 {'),
    ('windows/host/src/main.rs', 'if s.ptr.is_null() || s.len == 0 {'),
    ('windows/host/src/main.rs', 'if seen > 0 && returned == 0 {'),
    ('windows/host/src/main.rs', 'if selfresize && ticks == 625 {'),
    ('windows/host/src/main.rs', 'if selfresize && ticks == 750 {'),
    ('windows/host/src/main.rs', 'if selftest_running && ticks > 250 && ticks % 150 == 0 && step < script.len() {'),
    ('windows/host/src/main.rs', 'if selftest_running && ticks > 250 && ticks % 150 == 75 && step > 0 {'),
    ('windows/host/src/main.rs', 'if ticks % 12 == 0 {'),
    ('windows/host/src/main.rs', 'if unsafe { RegisterClassExW(&wc) } == 0 {'),
    ('windows/host/src/main.rs', 'if unsafe { RegisterClassExW(&wc2) } == 0 {'),
    ('windows/host/src/notify.rs', 'if RegisterClassExW(&wc) == 0 {'),
    ('windows/host/src/palette.rs', 'if RegisterClassExW(&wc) == 0 {'),
    ('windows/host/src/quick.rs', 'if RegisterClassExW(&wc) == 0 {'),
    ('windows/host/src/reload.rs', 'if RegisterClassW(&wc) == 0 {'),
    ('windows/host/src/search.rs', 'if RegisterClassExW(&wc) == 0 {'),
    ('windows/host/src/settings_ui.rs', 'if RegisterClassExW(&wc) == 0 {'),
    ('windows/host/src/strip.rs', 'if chosen == 0 {'),
    ('windows/host/src/tabs.rs', 'if count(frame) == 0 {'),
    ('windows/host/src/tabs.rs', 'if h == 0 || w <= 0 {'),
    ('windows/host/src/tabs.rs', 'if m <= 5 {'),
    ('windows/host/src/tabs.rs', 'if n <= 10 {'),
    ('windows/host/src/tabs.rs', 'if n <= 400 {'),
    ('windows/host/src/tabs.rs', 'if n <= 5 || paged {'),
    ('windows/host/src/taskbar.rs', 'if RegisterClassExW(&wc) == 0 {'),
    ('windows/host/src/winid.rs', 'if left == 0 {'),
}

# The number of statements the detector found when this was written. A drop
# means the detector got worse, and a detector that finds nothing is a
# checker that passes everything.
SUBJECT_FLOOR = 78

# Caps that a written criterion reads back, and which must therefore keep an
# escape that is true whenever there is something new to say.
#
# **This is the one place where the verdict is checked against the code**, and
# it is here because the verdict alone is not enough for these: the comment
# above such a cap says the silence means "nothing changed", and deleting the
# escape turns that sentence into a lie without touching it. Everywhere else
# this file believes what the author wrote; for a line somebody is grading a
# release against, believing the comment is how the last one got through.
#
# An entry is (file, binding, why). The binding's initialiser must contain a
# disjunction: a bare count has no escape.
ESCAPE_SITES = [
    (
        "windows/host/src/tabs.rs",
        "verbose",
        "the per-pane layout lines are the verdict for two of the three cells "
        "in docs/windows/split-target-criteria.md; a bare count made that "
        "criterion unable to fail after the first forty layouts of the process",
    ),
]

BINDING = "let {} ="

# Lines that must stay behind a rate limit, and the predicate that provides it.
#
# **The same reasoning as `ESCAPE_SITES`, pointing the other way.** There the
# risk is a cap losing its escape and the comment above it staying true-looking;
# here it is a throttle being taken off and nothing noticing until a disk fills.
# Removing a throttle does not make this file's ordinary check fail -- an
# unthrottled line is simply not a subject any more, and a checker that goes
# quiet when its subject disappears is the failure mode this repository keeps
# meeting. So the requirement is written down separately.
#
# An entry is (file, tag, predicate, why). Every log statement whose format
# string carries the tag must sit inside a condition that calls the predicate.
THROTTLED_SITES = [
    (
        "windows/host/src/hud.rs",
        "[hud] scrollbar",
        "scroll_line_due",
        "the core sends one scrollbar update per render; measured at 30 renders "
        "a second this line was 75% of the entire log, about 150 MB a day for "
        "one window, and a disk filling up does not look like a logging problem "
        "when it happens",
    ),
]

# How many distinct conditions each alternative of the vocabulary matched when
# this was written.
#
# **Recorded because a count floor over the whole tree is a weak instrument.**
# The first attempt to prove the floor could go red broke one alternative and
# nothing happened -- the total did not move, because that alternative was
# matching nothing in the first place and other spellings caught the same
# sites. A census makes both facts visible: which alternatives are actually
# doing the work, and which are there for a shape that does not exist today.
# An alternative that was load-bearing and stops being so is a regression;
# one that was already at zero is a bet on a future spelling, and is allowed
# to stay at zero.
VOCABULARY_CENSUS = {
    r"fetch_add": 0,
    r"\.take\(\)": 1,
    r"hasRoom\(\)": 2,
    r"shouldReport\(": 3,
    r"\.swap\(true": 2,
    r"\.swap\(1": 1,
    r"complained": 0,
    r"\bverbose\b": 1,
    r"%\s*\d[\d_]*\s*==": 7,
    r"<=\s*\d": 8,
    r">=\s*\d": 0,
    r"==\s*\d[\d_]*\b": 29,
    r"elapsed\(\)": 0,
    r"_LOGGED": 2,
    r"_ANNOUNCED": 1,
    r"\bfirst\b": 3,
    r"_due\(": 1,
}


def mask(src: str, keep_comments: bool, keep_strings: bool = False) -> str:
    """The source with string bodies blanked, and comments blanked or kept.

    **Two modes because the two questions are opposites.** Finding the gate
    means reading code and not comments -- a checker that reads the prose
    explaining itself tests nothing, which this repository has now watched
    happen twice. Finding the verdict means reading comments and not code, and
    above all not strings: a marker quoted inside a string literal is text
    about a marker, and accepting it would let a line be excused by a message
    that merely mentions the excuse.

    Line count is preserved exactly, including across a backslash line
    continuation inside a string -- getting that wrong shifts every line
    number after the first multi-line string, which is a way to be
    confidently wrong about where everything is.
    """
    out = []
    i = 0
    n = len(src)
    in_str = False
    while i < n:
        c = src[i]
        if not in_str:
            if src.startswith("//", i):
                j = src.find("\n", i)
                j = n if j < 0 else j
                out.append(src[i:j] if keep_comments else " " * (j - i))
                i = j
            elif src.startswith("/*", i):
                j = src.find("*/", i + 2)
                j = n if j < 0 else j + 2
                chunk = src[i:j]
                out.append(
                    chunk
                    if keep_comments
                    else "".join(ch if ch == "\n" else " " for ch in chunk)
                )
                i = j
            elif c == '"':
                out.append('"')
                i += 1
                in_str = True
            else:
                out.append(c)
                i += 1
        else:
            if c == "\\":
                nxt = src[i + 1] if i + 1 < n else ""
                if keep_strings:
                    out.append(src[i : i + 2])
                else:
                    out.append(" " + ("\n" if nxt == "\n" else " "))
                i += 2
            elif c == '"':
                out.append('"')
                i += 1
                in_str = False
            elif c == "\n":
                out.append("\n")
                i += 1
            else:
                out.append(c if keep_strings else " ")
                i += 1
    return "".join(out)


COND_START = re.compile(r"^\}?\s*(?:else\s+if|if|while|match)\b")


def normalise(cond: str) -> str:
    """A condition as the ledger keys it.

    String bodies are already blanked by `mask`, so collapsing runs of spaces
    makes the key independent of what was inside a quoted argument. That
    matters more than it looks: those strings are translated, and a ledger
    keyed on their contents would go red the day somebody edits a message,
    naming a file nobody had touched.
    """
    return re.sub(r"\s+", " ", cond).strip()


def flagged(src: str):
    """(line_no, condition_text) for every gated log statement.

    Line numbers are 1-based and index the original text.
    """
    code = mask(src, keep_comments=False).split("\n")
    stack = []
    depth = 0
    pending = None
    pending_at = None
    pending_parens = 0
    awaiting_brace = False
    found = []
    for i, line in enumerate(code):
        stripped = line.strip()
        if pending is None and COND_START.match(stripped):
            pending = stripped
            pending_at = i + 1
            pending_parens = 0
        elif pending is not None:
            pending += " " + stripped
        if pending is not None:
            pending_parens += line.count("(") - line.count(")")
        opens = line.count("{")
        closes = line.count("}")

        # **A condition that finished without opening a block guards the rest
        # of its own line and nothing after it.** Left set, it attaches itself
        # to whatever opens a block next -- which in one match statement here
        # paired a single-line guard in one arm with a log call in another,
        # naming a real condition and a real line that have nothing to do with
        # each other. That is the most persuasive shape a wrong answer takes.
        #
        # ⚠️ **But the brace may simply be on the next line.** Zig is written
        # that way when a condition wraps, and dropping the condition there
        # loses the subject in silence: the site stops being a subject and
        # looks exactly like one that passed. So a finished condition waits
        # exactly one line, and is kept only if that line *begins* with the
        # brace. `match x {` on the following line is a different statement.
        #
        # Found by rebasing onto a tree where the renderer thread's heartbeat
        # had been wrapped across two lines. **The count floor did not notice
        # -- the per-alternative census did.**
        if awaiting_brace:
            if not stripped.startswith("{"):
                pending = None
                pending_at = None
            awaiting_brace = False

        for _ in range(opens):
            depth += 1
            stack.append((depth, pending_at, pending))
            pending = None
            pending_at = None
        if pending is not None and opens == 0 and pending_parens <= 0 and stripped:
            awaiting_brace = True
        for _ in range(closes):
            stack = [x for x in stack if x[0] < depth]
            depth -= 1
        here = [c for _, _, c in stack if c and GATE.search(c)]
        here_at = [ln for _, ln, c in stack if c and GATE.search(c)]
        if LOG.search(line) and here:
            found.append((i + 1, normalise(here[-1]), here_at[-1]))
    return found


def block_above(lines, at: int) -> str:
    """The unbroken run of comment lines immediately above line `at`.

    **Not "the previous N lines".** A fixed window was tried first and it read
    past the thing it was looking at: a marker written for one gate sat
    twenty-seven lines above an unrelated one, and the unrelated one came back
    judged. A comment block stops at the first line of code, so a verdict can
    only ever excuse the statement it was actually written above.
    """
    out = []
    i = at - 2
    while i >= 0 and BLANK.match(lines[i]):
        i -= 1
    while i >= 0 and COMMENT.match(lines[i]):
        out.append(lines[i])
        i -= 1
    return "\n".join(out)


def has_verdict(comment_lines, log_at: int, gate_at) -> bool:
    """A verdict may sit above the statement or above the gate that shuts it.

    Both are places a reader meets the question, and which one is right
    depends on whether the gate covers one statement or several.
    """
    windows = [block_above(comment_lines, log_at)]
    if gate_at:
        windows.append(block_above(comment_lines, gate_at))
    return any(v.search(w) for w in windows for v in VERDICTS)


def scan():
    problems = []
    seen_pending = set()
    all_conditions = []
    total = 0
    for base, pattern in SUBJECT_DIRS:
        for path in sorted(base.glob(pattern)):
            rel = path.relative_to(ROOT).as_posix()
            src = path.read_text(encoding="utf8")
            prose = mask(src, keep_comments=True).split("\n")
            for line_no, cond, gate_at in flagged(src):
                total += 1
                all_conditions.append((rel, cond, line_no))
                key = (rel, cond)
                if has_verdict(prose, line_no, gate_at):
                    if key in PENDING:
                        seen_pending.add(key)
                        problems.append(
                            f"{rel}:{line_no} has been judged but is still in the "
                            f"ledger; remove it from PENDING -- a ledger that keeps "
                            f"settled debts stops being read"
                        )
                    continue
                if key in PENDING:
                    seen_pending.add(key)
                    continue
                problems.append(
                    f"{rel}:{line_no} is gated by `{cond}` and says nothing about "
                    f"what its silence means. Put one of `absence: proves nothing`, "
                    f"`absence: means it was not reached`, `absence: depends -- why` "
                    f"or `not-gated: why` in the comment block directly above "
                    f"it, or above its gate."
                )
    conds = {c for _, c, _ in all_conditions}
    for alt, was in sorted(VOCABULARY_CENSUS.items()):
        now = sum(1 for c in conds if re.search(alt, c))
        if now < was:
            problems.append(
                f"vocabulary `{alt}` matched {was} conditions when this was "
                f"written and matches {now} now. Either those gates went away "
                f"or the alternative stopped working; the second one is silent."
            )

    for rel, tag, predicate, why in THROTTLED_SITES:
        src_t = (ROOT / rel).read_text(encoding="utf8")
        code_t = mask(src_t, keep_comments=False)
        held = 0
        for line_no, cond, _ in flagged(src_t):
            if predicate in cond:
                held += 1
        # **Counted with the comments gone and the strings kept**, which is the
        # only view where "a log line carries this tag" is the question being
        # asked. On the raw text a doc comment that quotes the tag -- and the
        # one above `SCROLL_SAID` nearly does -- would be counted as a line.
        literal = mask(src_t, keep_comments=False, keep_strings=True)
        raw_hits = len(re.findall(re.escape(tag), literal))
        if raw_hits == 0:
            problems.append(
                f"{rel}: no log line carries `{tag}` any more. If it was "
                f"renamed this entry is protecting nothing; if it was deleted, "
                f"say so here."
            )
        elif held < raw_hits:
            problems.append(
                f"{rel}: {raw_hits} line(s) carry `{tag}` and only {held} sit "
                f"behind `{predicate}`. They have to stay throttled because "
                f"{why}."
            )

    for rel, binding, why in ESCAPE_SITES:
        src = (ROOT / rel).read_text(encoding="utf8")
        code = mask(src, keep_comments=False)
        needle = BINDING.format(binding)
        at = code.find(needle)
        if at < 0:
            problems.append(
                f"{rel}: `{binding}` is gone. It was the cap on a line that "
                f"{why}. If it moved, this entry is protecting nothing."
            )
            continue
        end = code.find(";", at)
        rhs = code[at + len(needle) : end if end > at else at + len(needle)]
        if "||" not in rhs and " or " not in rhs:
            problems.append(
                f"{rel}: `{binding}` is a cap with no escape ({rhs.strip()!r}). "
                f"It needs one because {why}."
            )

    for key in sorted(PENDING - seen_pending):
        problems.append(
            f"{key[0]}: the ledger names a gate `{key[1]}` that no longer exists "
            f"there. Either it was judged and the entry should go, or it moved and "
            f"the entry is now protecting nothing."
        )
    return total, problems


CANARIES = [
    # A gated statement with no verdict is caught.
    ("bare", 1, """
fn f() {
    let n = C.fetch_add(1, Relaxed) + 1;
    if n <= 40 {
        logf!("[x] hello");
    }
}
"""),
    # The same, with a verdict, is not.
    ("judged", 0, """
fn f() {
    let n = C.fetch_add(1, Relaxed) + 1;
    // absence: proves nothing
    if n <= 40 {
        logf!("[x] hello");
    }
}
"""),
    # A marker with no reason after it must not be satisfied by the next line.
    # This is the `\\s*`-matches-a-newline trap, spelled out as a test.
    ("reasonless", 1, """
fn f() {
    let n = C.fetch_add(1, Relaxed) + 1;
    // absence: depends --
    if n <= 40 {
        logf!("[x] hello");
    }
}
"""),
    # The dismissal marker also satisfies it.
    ("dismissed", 0, """
fn f() {
    let n = C.fetch_add(1, Relaxed) + 1;
    // not-gated: n is the count being reported
    if n <= 40 {
        logf!("[x] hello");
    }
}
"""),
    # A verdict *below* the statement does not count: the reader meets the
    # gate first.
    ("below", 1, """
fn f() {
    let n = C.fetch_add(1, Relaxed) + 1;
    if n <= 40 {
        logf!("[x] hello");
    }
    // absence: proves nothing
}
"""),
    # An ungated log statement is not a subject at all.
    ("ungated", 0, """
fn f() {
    logf!("[x] hello");
}
"""),
    # A verdict that appears only inside a string is not a verdict.
    ("in a string", 1, """
fn f() {
    let n = C.fetch_add(1, Relaxed) + 1;
    let s = "// absence: proves nothing";
    if n <= 40 {
        logf!("[x] hello");
    }
}
"""),
    # Zig, and a budget spelled the other way.
    ("zig budget", 1, """
fn draw() void {
    if (self.present_log.take()) {
        log.info("[y] there", .{});
    }
}
"""),
    # A verdict written for one gate must not excuse a different one further
    # down. This is the fixed-window trap, kept as a test because a fixed
    # window is the obvious first implementation and it passed the tree.
    ("neighbour", 1, """
fn f() {
    let n = C.fetch_add(1, Relaxed) + 1;
    // absence: proves nothing
    if n <= 40 {
        logf!("[x] one");
    }
    let a = 1;
    let b = 2;
    let m = D.fetch_add(1, Relaxed) + 1;
    if m <= 40 {
        logf!("[x] two");
    }
}
"""),
    # A conditional with no block of its own gates the rest of its line and
    # stops there. Left carrying forward it attached itself to the next block
    # that happened to open, which is how an unrelated statement in a later
    # match arm came back flagged.
    ("braceless", 0, """
fn f() {
    if (n == 0) do_something();
    match x {
        A => {
            log.warn("[y] unrelated", .{});
        },
    }
}
"""),
    # A condition wrapped onto two lines with its brace alone on a third is
    # still a gate. Losing it costs a subject in silence, which is the one
    # failure mode a checker cannot report about itself.
    ("wrapped condition, brace on its own line", 1, """
fn draw() void {
    if (build_config.log_render_phase or
        rendererpkg.shouldReport(t.wakeups, heartbeat_interval))
    {
        log.info("[rthread] r={x}", .{});
    }
}
"""),
    # A line continuation inside a string must not shift the line numbers: the
    # verdict below is 4 real lines above the statement and must be found.
    ("continuation", 0, '''
fn f() {
    logf!(
        "a very long line that carries on \\
         onto the next one"
    );
    let n = C.fetch_add(1, Relaxed) + 1;
    // absence: proves nothing
    if n <= 40 {
        logf!("[x] hello");
    }
}
'''),
]


def selftest() -> list:
    bad = []
    for name, want, src in CANARIES:
        prose = mask(src, keep_comments=True).split("\n")
        hits = [ln for ln, _, g in flagged(src) if not has_verdict(prose, ln, g)]
        if len(hits) != want:
            bad.append(
                f"self-test {name!r}: expected {want} unjudged, got {len(hits)} "
                f"at {hits}"
            )
    return bad


def main() -> int:
    bad = selftest()
    if bad:
        print("This checker is broken; it was not run against the tree.")
        for b in bad:
            print("  " + b)
        return 1

    total, problems = scan()
    print(f"gated log statements found: {total} (floor {SUBJECT_FLOOR})")
    print(f"ledger entries not yet judged: {len(PENDING)}")
    if total < SUBJECT_FLOOR:
        problems.append(
            f"the detector found {total} statements, below the recorded floor of "
            f"{SUBJECT_FLOOR}. A checker that stops finding its subjects passes "
            f"everything, and it passes quietly."
        )
    if problems:
        for p in problems:
            print("  " + p)
        print(f"{len(problems)} problem(s).")
        return 1
    print("every gated statement outside the ledger says what its silence means.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
