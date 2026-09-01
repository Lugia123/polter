#!/usr/bin/env python3
"""Check that the watchdog's output path shares nothing with the thread it watches.

Two properties, and the difference between them matters:

  * **No stdout anywhere in the watchdog thread.** `log_line` opens with
    `println!`, which takes Rust's global stdout lock. The main thread uses the
    same function, so a main thread stuck inside a write -- stdout redirected
    into a pipe whose reader stopped, which is how this binary is run on the
    test machine -- holds that lock. A watchdog that called it would block on
    its own `println!`, and its silence reads exactly like "the watchdog never
    started".

  * **No allocation on the alarm branch.** That branch runs precisely when the
    main thread is not running, and one reason a thread stops running is that
    it holds the process heap lock. `format!`, `String`, and even opening a
    file (the path becomes a wide string) all want the heap.

⚠️ **What this cannot see.** It reads names, so it catches the allocating
calls that are spelled out. The heap lock is not a name: a helper that
allocates two calls away, or a trait method that boxes, passes this check.
**Green here means "no allocating call is written on that branch", not "that
branch cannot allocate".** The second claim is not one this tool can make, and
today's habit is to say so in the output rather than let a reader upgrade it.

Exit: 0 clean, 1 otherwise.
"""

import os
import re
import sys

STDOUT_CALLS = ["logf!", "println!", "print!", "eprintln!", "eprint!", "wd_log"]
ALLOCATING = ["format!", "to_string()", "String::", "to_owned()", "vec!", "wd_log", ".open("]


def body_after(src: str, needle: str) -> str:
    """The brace-balanced block that starts at the first `{` after `needle`."""
    i = src.index(needle)
    start = src.index("{", i)
    depth, j = 0, start
    while j < len(src):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[start : j + 1]
        j += 1
    return src[start:]


def check(src: str):
    """Yield (rule, offender) pairs."""
    try:
        thread = body_after(src, "fn start_watchdog(")
    except ValueError:
        yield ("missing", "start_watchdog not found -- this tool is checking nothing")
        return

    # The spawn closure only; the function's own tail may legitimately use
    # `logf!` to report that the thread failed to start, which happens on the
    # main thread and is not the path under test.
    try:
        closure = body_after(thread, ".spawn(")
    except ValueError:
        yield ("missing", "the spawned closure was not found")
        return

    for name in STDOUT_CALLS:
        if name == "wd_log":
            continue  # wd_log is allowed in the healthy cadence; see below.
        if name in closure:
            yield ("stdout", name)

    # **Polarity.** Without this the tool blesses a text block, not a branch:
    # swap the two arms of `if pong == seq` and the allocation-free code would
    # go on to serve `PUMP BUSY` -- the case that is not a fault -- while the
    # real alarm allocated again, and every check below would still pass.
    try:
        answered = body_after(closure, "if pong == seq {")
        after = closure[closure.index(answered) + len(answered) :].lstrip()
        if not after.startswith("else if let Some(f) = alarm_file.as_ref()"):
            yield (
                "polarity",
                "the allocation-free block is no longer the `else` of "
                "`if pong == seq` -- it may now be serving the non-fault case",
            )
            return
    except ValueError:
        yield ("missing", "`if pong == seq {` was not found -- polarity unknown")
        return

    try:
        alarm = body_after(closure, "alarm_file.as_ref()")
    except ValueError:
        yield ("missing", "the alarm branch was not found")
        return

    for name in ALLOCATING:
        if name in alarm:
            yield ("alloc", name)


CANARY_SWAPPED = """
fn start_watchdog() {
    let x = std::thread::Builder::new().spawn(move || {
        loop {
            wd_log("[wd] watching");
            if pong == seq {
                let mut l = Line::new();
                alarm(f, &l);
            } else if let Some(f) = alarm_file.as_ref() {
                wd_log(&format!("busy {}", n));
            }
        }
    });
}
"""

CANARY_BAD = """
fn start_watchdog() {
    let x = std::thread::Builder::new().spawn(move || {
        loop {
            logf!("[wd] tick");
            if pong == seq {
                wd_log("busy");
            } else if let Some(f) = alarm_file.as_ref() {
                wd_log(&format!("blocked {}", n));
            }
        }
    });
}
"""

CANARY_OK = """
fn start_watchdog() {
    let x = std::thread::Builder::new().spawn(move || {
        loop {
            wd_log("[wd] watching");
            if pong == seq {
                wd_log("busy");
            } else if let Some(f) = alarm_file.as_ref() {
                let mut l = Line::new();
                l.s("[wd] blocked");
                alarm(f, &l);
            }
        }
    });
}
"""


def main() -> int:
    bad = list(check(CANARY_BAD))
    if not {r for r, _ in bad} >= {"stdout", "alloc"}:
        print(f"FAIL: the probe misses the shapes it was written for: {bad}")
        return 1
    swapped = [r for r, _ in check(CANARY_SWAPPED)]
    if "polarity" not in swapped and "alloc" not in swapped:
        print("FAIL: the probe does not notice the two arms being swapped")
        return 1

    ok = list(check(CANARY_OK))
    if ok:
        print(f"FAIL: the probe fires on a clean watchdog: {ok}")
        return 1
    print("probe self-test: OK (sees stdout and allocation, ignores the clean form)")

    path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "host", "src", "main.rs"
    )
    with open(path, encoding="utf-8") as fh:
        src = re.sub(r"//.*$", "", fh.read(), flags=re.M)

    hits = list(check(src))
    for rule, name in hits:
        print(f"HIT  [{rule}] {name}")
    if hits:
        return 1

    print("main.rs: no stdout in the watchdog thread, no allocating call on the alarm branch")
    print("NOT CHECKED: whether that branch can allocate indirectly -- names only")
    print("NOT CHECKED: polarity is matched as text; a rewrite that keeps the")
    print("             behaviour but not the spelling reads as a polarity change")
    return 0


if __name__ == "__main__":
    sys.exit(main())
