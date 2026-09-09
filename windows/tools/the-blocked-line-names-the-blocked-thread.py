#!/usr/bin/env python3
"""The alarm's thread id must be the thread that stopped, not the one noticing.

**Written from a wrong conclusion that was published.** The watchdog's alarm
ended `tid=N`. `N` was `GetCurrentThreadId()` read *inside* the watchdog
thread, so it named the watchdog. The only reader this line has ever had is
somebody about to suspend a thread and take its stack -- that is what the line
is for -- and they were handed the one thread in the process that is running
by definition. The stack came back with `sleep` on top, `thread_start` at the
bottom and `Instant::now` in the middle. Four symbols, all consistent, all
about the wrong thread, and the reading taken from them ("the main thread is
not stuck where we thought") went out before anybody noticed.

⚠️ **A wrong identifier does not look wrong.** It resolves, it symbolises, it
produces a plausible stack. Nothing downstream can catch it, because
downstream has no second opinion about which thread was meant.

# Why this checker reads a binding and not a word

The obvious check is "the alarm line mentions a thread id". **That assertion
was true the whole time it was wrong**, and it is the same shape as an
assertion this repository has already been caught by once: proving a field
appears in a log line, rather than proving it holds the answer to the question
the line asks.

So this reads the argument. `start_watchdog` reads `GetCurrentThreadId()`
twice -- once on the main thread before the watchdog is spawned, once inside
the spawned closure. Which one an argument is, is decided by **where its `let`
sits relative to the `spawn` call**, not by what it is called. The identifier
handed to `blocked_line` in the `blocked_tid` position must be bound before
the spawn; the one in the `wd_tid` position must be bound inside it.

That is what makes the decisive mutation catchable: move the outer `let` into
the closure and change nothing else. Every name is identical, the line still
prints two ids with two labels, the code still compiles -- and both ids now
name the watchdog.

WHAT THIS CHECKS
----------------

  1. `blocked_line` takes `blocked_tid` and `wd_tid`, and no parameter is the
     bare name `tid` -- a name that says which thread it is is half the fix.
  2. The `blocked_tid` argument at the call site is an identifier whose `let`
     is *before* the spawn.
  3. The `wd_tid` argument is an identifier whose `let` is *inside* it.
  4. No `[wd]` line anywhere in the file writes a bare `tid=` field. Both
     lines in this family are read by the same person for the same purpose,
     and the healthy one had the same defect in a quieter form.

**NOT CHECKED:**

  * **That `main_tid` is the main thread's.** It is read at the top of
    `start_watchdog`, which is called from `main`; this checker takes the
    binding position as the evidence and does not follow the call graph.
  * **That the line reaches anybody.** `alarm` writes to a held handle and
    the whole path is unallocating; whether the bytes arrive is what
    `alarm_line_fits` and the truncation test are for, and those run on
    Windows.
  * **Other files.** The alarm is here. A second watchdog elsewhere would be
    a subject this does not have.

Run:  python3 windows/tools/the-blocked-line-names-the-blocked-thread.py
Exit: 0 when the alarm hands its reader the thread that stopped.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAIN = ROOT / "windows" / "host" / "src" / "main.rs"

BLOCKED = "blocked_tid"
WATCHDOG = "wd_tid"


def mask(src: str, keep_strings: bool = False) -> str:
    """Comments blanked; string bodies blanked or kept, line count preserved.

    Comments go because a checker that reads the prose explaining itself tests
    nothing.

    ⚠️ **Strings need a lexer, not a regex, and finding that out cost a
    canary.** The obvious way to collect Rust string literals is to pair
    quotes over the raw file -- and the doc comments in this file contain
    apostrophes and quotation marks, so the pairing walks straight through
    them and hands back spans of prose. The check that read those spans found
    two "literals", both of them comment text, and passed a mutation it was
    written to catch. Comments are removed first here, by the same pass, so
    the quotes that remain are the ones the compiler sees.
    """
    out = []
    i, n, in_str = 0, len(src), False
    while i < n:
        c = src[i]
        if not in_str:
            if src.startswith("//", i):
                j = src.find("\n", i)
                j = n if j < 0 else j
                out.append(" " * (j - i))
                i = j
            elif src.startswith("/*", i):
                j = src.find("*/", i + 2)
                j = n if j < 0 else j + 2
                out.append("".join(ch if ch == "\n" else " " for ch in src[i:j]))
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


def balanced_span(code: str, open_at: int) -> str:
    """The text inside the parentheses that start at `open_at`."""
    depth = 0
    for i in range(open_at, len(code)):
        if code[i] == "(":
            depth += 1
        elif code[i] == ")":
            depth -= 1
            if depth == 0:
                return code[open_at + 1 : i]
    return ""


def split_args(text: str) -> list:
    """Top-level comma split, so a nested call stays one argument."""
    out, depth, cur = [], 0, ""
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def bare_ident(arg: str):
    """`main_tid as u64` -> `main_tid`; anything else -> None."""
    a = re.sub(r"\bas\s+\w+\b", "", arg).strip()
    return a if re.fullmatch(r"[A-Za-z_]\w*", a) else None


def check(src: str) -> list:
    code = mask(src)
    problems = []

    # 1. the signature
    at = code.find("fn blocked_line(")
    if at < 0:
        return ["main.rs: `blocked_line` is gone; this checker is watching nothing."]
    params = split_args(balanced_span(code, code.index("(", at)))
    names = [p.split(":")[0].strip() for p in params]
    for want in (BLOCKED, WATCHDOG):
        if want not in names:
            problems.append(
                f"main.rs: `blocked_line` has no `{want}` parameter (it takes "
                f"{names}). Both threads have to be named; an unnamed one is "
                f"read as whichever the reader was hoping for."
            )
    if "tid" in names:
        problems.append(
            "main.rs: `blocked_line` still takes a parameter called `tid`. The "
            "reader of this line is about to suspend a thread -- the name has "
            "to say which one."
        )
    if problems:
        return problems

    # 2/3. the argument bindings, relative to the spawn
    wd = code.find("fn start_watchdog(")
    if wd < 0:
        return ["main.rs: `start_watchdog` is gone."]
    spawn = code.find(".spawn(", wd)
    call = code.find("blocked_line(", spawn)
    if spawn < 0 or call < 0:
        return ["main.rs: could not find the spawn and the alarm call in order."]
    args = split_args(balanced_span(code, code.index("(", call)))
    if len(args) != len(names):
        return [
            f"main.rs: the alarm is called with {len(args)} arguments and "
            f"`blocked_line` takes {len(names)}; nothing below can be trusted."
        ]

    def binding_of(ident: str):
        """Offset of `let <ident> = ...GetCurrentThreadId()`, or None."""
        m = re.search(
            rf"\blet\s+{re.escape(ident)}\s*=[^;]*GetCurrentThreadId\s*\(\s*\)",
            code[wd:],
        )
        return wd + m.start() if m else None

    for want, must_be_before_spawn, whose in (
        (BLOCKED, True, "the thread that stopped"),
        (WATCHDOG, False, "this watchdog"),
    ):
        arg = args[names.index(want)]
        ident = bare_ident(arg)
        if ident is None:
            problems.append(
                f"main.rs: the `{want}` argument is {arg!r}, which this cannot "
                f"trace to a binding. It has to be a plain identifier read from "
                f"GetCurrentThreadId, so that where it was read is checkable."
            )
            continue
        where = binding_of(ident)
        if where is None:
            problems.append(
                f"main.rs: `{ident}` is passed as `{want}` but is not bound from "
                f"GetCurrentThreadId inside `start_watchdog`."
            )
            continue
        before = where < spawn
        if before != must_be_before_spawn:
            side = "before the spawn" if must_be_before_spawn else "inside the closure"
            got = "before the spawn" if before else "inside the closure"
            problems.append(
                f"main.rs: `{want}` is `{ident}`, read {got}, and it has to be "
                f"read {side} -- it names {whose}. ⚠️ The name is not the "
                f"evidence here and cannot be: an id read in the wrong place "
                f"still resolves, still symbolises, and still produces a stack "
                f"somebody will believe."
            )

    # 4. no bare `tid=` field on any watchdog line
    #
    # **The alarm's text is spelled one fragment per call**, so looking for a
    # `[wd]` prefix and a `tid=` in the same string literal finds neither: the
    # prefix is in one `l.s` and the field is in another, six calls later.
    # This first stitches the alarm back together, then reads every other
    # literal that carries the tag.
    lexed = mask(src, keep_strings=True)
    start = lexed.index("fn blocked_line(")
    end = lexed.index("\n}\n", start)
    alarm_text = "".join(
        re.findall(r'l\.s\("((?:[^"\\]|\\.)*)"\)', lexed[start:end], re.S)
    )
    subjects = [("the alarm line", alarm_text)]
    # `re.S`, because a Rust string literal may carry a backslash line
    # continuation and `.` does not match a newline by default. Without it the
    # healthy watchdog line -- which is written that way -- was not matched at
    # all, and this check silently had one subject instead of two.
    for lit in re.findall(r'"((?:[^"\\]|\\.)*)"', lexed, re.S):
        if "[wd]" in lit:
            subjects.append(("a `[wd]` line", lit))
    for what, text in subjects:
        for f in re.finditer(r"(?<![A-Za-z_])tid=", text):
            problems.append(
                f"main.rs: {what} writes a bare `tid=` field "
                f"({text[max(0, f.start() - 20) : f.end() + 4].strip()!r}). Say "
                f"which thread: `{BLOCKED}=` or `{WATCHDOG}=` or `main_tid=`. "
                f"⚠️ This line's reader is about to suspend a thread."
            )
    return problems


CANARIES = [
    (
        "the watchdog's own id in the blocked slot",
        1,
        """
fn blocked_line(pid: u64, blocked_tid: u64, wd_tid: u64) -> Line { }
fn start_watchdog() {
    let main_tid = unsafe { GetCurrentThreadId() };
    let spawned = std::thread::Builder::new().spawn(move || {
        let tid = unsafe { GetCurrentThreadId() };
        let mut l = blocked_line(pid as u64, tid as u64, tid as u64);
    });
}
""",
    ),
    (
        "the two swapped",
        2,
        """
fn blocked_line(pid: u64, blocked_tid: u64, wd_tid: u64) -> Line { }
fn start_watchdog() {
    let main_tid = unsafe { GetCurrentThreadId() };
    let spawned = std::thread::Builder::new().spawn(move || {
        let tid = unsafe { GetCurrentThreadId() };
        let mut l = blocked_line(pid as u64, tid as u64, main_tid as u64);
    });
}
""",
    ),
    (
        "the outer let moved inside, every name unchanged",
        1,
        """
fn blocked_line(pid: u64, blocked_tid: u64, wd_tid: u64) -> Line { }
fn start_watchdog() {
    let spawned = std::thread::Builder::new().spawn(move || {
        let main_tid = unsafe { GetCurrentThreadId() };
        let tid = unsafe { GetCurrentThreadId() };
        let mut l = blocked_line(pid as u64, main_tid as u64, tid as u64);
    });
}
""",
    ),
    (
        "correct",
        0,
        """
fn blocked_line(pid: u64, blocked_tid: u64, wd_tid: u64) -> Line { }
fn start_watchdog() {
    let main_tid = unsafe { GetCurrentThreadId() };
    let spawned = std::thread::Builder::new().spawn(move || {
        let tid = unsafe { GetCurrentThreadId() };
        let mut l = blocked_line(pid as u64, main_tid as u64, tid as u64);
    });
}
""",
    ),
    # The field name put back the way it was, while every binding stays right.
    # The fragment carrying it does not contain the tag, which is why this is
    # a separate canary from the one below.
    (
        "the alarm's own field renamed back to a bare tid=",
        1,
        """
fn blocked_line(pid: u64, blocked_tid: u64, wd_tid: u64) -> Line {
    l.s("[wd] pid=");
    l.u(pid);
    l.s("), tid=");
    l.u(blocked_tid);
    l.s(" wd_tid=");
    l.u(wd_tid);
}
fn start_watchdog() {
    let main_tid = unsafe { GetCurrentThreadId() };
    let spawned = std::thread::Builder::new().spawn(move || {
        let tid = unsafe { GetCurrentThreadId() };
        let mut l = blocked_line(pid as u64, main_tid as u64, tid as u64);
    });
}
""",
    ),
    (
        "a bare tid= field on a watchdog line",
        1,
        """
fn blocked_line(pid: u64, blocked_tid: u64, wd_tid: u64) -> Line { }
fn start_watchdog() {
    let main_tid = unsafe { GetCurrentThreadId() };
    let spawned = std::thread::Builder::new().spawn(move || {
        let tid = unsafe { GetCurrentThreadId() };
        wd_log(&format!("[wd] pid={pid} tid={tid} up"));
        let mut l = blocked_line(pid as u64, main_tid as u64, tid as u64);
    });
}
""",
    ),
    # Three, because the signature check reports each missing name and the
    # bare one separately and stops there: with the parameters wrong there is
    # nothing downstream worth reading.
    (
        "the parameter went back to being called tid",
        3,
        """
fn blocked_line(pid: u64, tid: u64) -> Line { }
fn start_watchdog() {
    let main_tid = unsafe { GetCurrentThreadId() };
    let spawned = std::thread::Builder::new().spawn(move || {
        let tid = unsafe { GetCurrentThreadId() };
        let mut l = blocked_line(pid as u64, tid as u64);
    });
}
""",
    ),
]


def selftest() -> list:
    bad = []
    for name, want, src in CANARIES:
        got = len(check(src))
        if got != want:
            bad.append(f"self-test {name!r}: expected {want} problem(s), got {got}")
    return bad


def main() -> int:
    bad = selftest()
    if bad:
        print("This checker is broken; it was not run against the tree.")
        for b in bad:
            print("  " + b)
        return 1
    problems = check(MAIN.read_text(encoding="utf8"))
    if problems:
        for p in problems:
            print("  " + p)
        print(f"{len(problems)} problem(s).")
        return 1
    print("the alarm hands its reader the thread that stopped.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
