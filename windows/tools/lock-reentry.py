#!/usr/bin/env python3
"""Find calls made while a guard over the host's one state mutex is still alive.

The host keeps its whole model behind one mutex. Taking it twice on one thread
is not a slow lock, it is a hang: the second take waits five seconds and then
panics naming both ends. That is a good failure, but it is a failure at
runtime, and the shape is easy to write by accident because the second take is
usually several calls away and looks like an ordinary helper.

Two things this does that a hand-written check does not:

  * **The set of lock-taking functions is derived, not listed.** A hand-written
    list is what let the original deadlock through: `take_id` took the lock,
    nobody had thought of it as a locker, and it was called inside a struct
    literal that was itself inside a guard's scope. Here anything that reaches
    the mutex is a locker, and so is anything that calls one of those, to a
    fixed point.

  * **Files come from a glob, not a list.** A module added next week is scanned
    without anyone remembering to add it, which is the same class of omission
    one level up.

**And the root of that derivation is derived too, which is the repair this
file exists in the state it does because of.** See below.

# The two years this gate spent green with nothing in its sights

Written before G1, it seeded the fixed point from the literal string
`state()` -- the single accessor of the day -- and matched guard sites with
`let x = state();`. `ecf53ae8d` deleted `state()`, replacing it with `reg()`
and the three public ways in (`window`, `shared`, `with_windows`). **Both
halves of this file died on that commit and neither said so:**

    scanned 26 files; 0 functions reach the lock

    no unexpected hits                                    (exit 0)

`0 functions reach the lock` is the whole story and it was printed every run.
Nothing read it, because a gate that exits 0 after printing its own all-clear
is indistinguishable from a gate that looked at everything and found nothing.
That cost more than a gate nobody runs: `status.md` 47 cites this file as the
reason not to write another check for the shape, and that citation was made
*after* G1 -- **the reasoning rested on a sentence that had stopped being true.**

## So the seed is derived, and there is a floor under it

The docstring above has always claimed the locker set is derived rather than
listed. It was -- **except for the one literal it grew from**, and that literal
is what went stale. Renaming the seed to `reg()` would arm the same device
again for whoever renames it next.

The root is now found by looking for what actually takes the lock: a
module-level `static NAME: Mutex<...>` in `tabs.rs`, and the functions whose
bodies call `.lock()` / `.try_lock()` on it. Rename `reg` to anything and this
still finds it.

**That is not enough on its own, and the floor is what makes it safe.** Any
derivation can stop matching -- the static could move, the lock could be
wrapped in something with a different method name. So: **an empty root set, or
an empty locker set, is a failure, not a pass.** Zero files was already a
failure here for exactly this reason (`gates-fail-on-empty.py`); zero lockers
is the same sentence one level in. **Of everything in this repair, that line is
the only part that does not depend on the author having guessed today's
vocabulary correctly** -- the rest is a better guess, and a better guess is
still a guess.

# Guard shapes

Under G1 a guard is bound in more ways than `let x = state();`, and the
lifetime differs by shape. Getting this wrong in either direction is a lie, so
they are handled separately rather than approximated by one regex:

    let Some(w) = window(f) else { ... };     to the end of the enclosing block
    let mut s = shared();                     (the `else` arm is not in scope --
    let w = window(f)?;                        the temporary is dropped first)

    if let Some(w) = window(f) { ... }        the block, and its `else` if any
    match window(f) { ... }                   the whole match, both arms
                                              (a locker in the `None` arm still
                                               deadlocks -- the temporary lives
                                               to the end of the expression)

    window(f).map(|w| ...).unwrap_or(d);      to the end of the statement
                                              (an unbound temporary guard lives
                                               that long, not to the `)`)

    with_windows(|ws| { ... })                the closure body, and nothing
                                              after: this one returns `R`, not
                                              a guard, so the lock is released
                                              at the call's end

The last distinction is derived from the signature (`impl Fn` in the parameter
list), not from the names, for the same reason as everything else here.

# Known gaps, stated rather than left to be discovered

**Only functions at column zero are parsed.** `fn` inside an `impl` block or
inside `mod tests` is indented and is invisible to this file, both as a
possible locker and as a place a guard site could hide. That is a reach gap of
the same family this repair was about, and it is written here rather than
fixed because fixing it is a different change with a different floor.

Exit: 0 if the hits match KNOWN exactly, 1 otherwise.
"""

import glob
import os
import re
import sys

# Findings that are understood and accepted. Empty means the rule holds
# everywhere; a new key here needs a sentence saying why it is safe, not just
# a name -- an entry without a reason is how a real hit gets parked forever.
KNOWN: dict[str, str] = {}

# The module that owns the lock. Named once, and the floor below fires if this
# stops being where the mutex lives.
OWNER = "tabs"


def blank_noncode(src: str) -> str:
    """Replace comments and string contents with spaces, byte for byte.

    **Two false positives, and they arrive from opposite directions.**

    A locker's name inside a *comment* is not a call. That one is old: a
    comment explaining the lock made its own module look like a locker, which
    then made every caller of that module look like one too. One bad line, and
    the derived set inflates until the output is noise.

    A locker's name inside a *string* is not a call either, and that one was
    measured on this repair rather than remembered. The rewritten scan found
    `winid.rs::created` -- and the "call" it had found was the word `window` in
    `"[win] w{} created; {} window(s)"`. It reported a live guard across
    `count()` on the same line, **which is a sentence that reads exactly like
    a real finding.**

    Done in one left-to-right pass rather than two, because the two-pass
    version is wrong in both orders: strip comments first and `"http://x"`
    loses half its text; blank strings first and a comment containing a quote
    swallows the code after it.

    **Width is preserved** -- spaces in, newlines kept -- because every offset
    and line number this file prints is an index into what comes back.
    """
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            depth = 0
            while i < n:
                if src.startswith("/*", i):
                    depth += 1
                    out[i] = out[i + 1] = " "
                    i += 2
                    continue
                if src.startswith("*/", i):
                    depth -= 1
                    out[i] = out[i + 1] = " "
                    i += 2
                    if depth == 0:
                        break
                    continue
                if src[i] != "\n":
                    out[i] = " "
                i += 1
        elif c == "r" and (m := re.match(r'r(#*)"', src[i:])):
            # `r"..."`, `r#"..."#`, and so on: the terminator carries the
            # same number of hashes, which is the whole point of the form.
            close = '"' + m.group(1)
            j = src.find(close, i + m.end())
            j = n if j < 0 else j + len(close)
            for k in range(i, j):
                if src[k] != "\n":
                    out[k] = " "
            i = j
        elif c == '"':
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == '"':
                    j += 1
                    break
                j += 1
            for k in range(i, min(j, n)):
                if src[k] != "\n":
                    out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out)


# `^` in multiline mode, not `\n`: a declaration on the first line of a file
# has no newline before it. Found on the F2 floor tree, where a hand-written
# `tabs.rs` beginning with the static was read as having none -- and the gate
# then reported a different failure, confidently.
FN_RE = re.compile(
    r'(?m)^(?:pub(?:\([\w:]+\))? )?(?:unsafe )?(?:extern "system" )?fn (\w+)'
)


def close_of(src: str, open_idx: int) -> int:
    """Index of the brace/paren matching the one at `open_idx`."""
    pair = {"{": "}", "(": ")", "[": "]"}[src[open_idx]]
    depth = 0
    for j in range(open_idx, len(src)):
        if src[j] == src[open_idx]:
            depth += 1
        elif src[j] == pair:
            depth -= 1
            if depth == 0:
                return j
    return len(src)


def functions(src: str) -> dict[str, tuple[str, str]]:
    """Map function name to (signature, body). Column-zero functions only."""
    out: dict[str, tuple[str, str]] = {}
    for m in FN_RE.finditer(src):
        try:
            start = src.index("{", m.end())
        except ValueError:
            continue
        out[m.group(1)] = (src[m.end():start], src[start:close_of(src, start)])
    return out


def derive_roots(sources: dict[str, str]) -> set[str]:
    """Functions that take the mutex itself.

    **Not a name this file knows.** The anchor is the declaration of the lock
    -- a module-level `static NAME: Mutex<...>` in the owning module -- and a
    root is any function there that calls `.lock()` or `.try_lock()` on it.
    Statics declared inside a `mod` or an `fn` are indented and deliberately
    do not count: `tabs.rs` has one of those (`ONE_AT_A_TIME`, a serialiser
    for the tests) and it guards something else entirely.
    """
    src = sources.get(OWNER)
    if src is None:
        return set()
    statics = re.findall(
        r"(?m)^static (\w+)\s*:\s*(?:std::sync::)?Mutex<", src
    )
    if not statics:
        return set()
    taking = re.compile(
        r"\b(?:%s)\s*\.\s*(?:try_)?lock\s*\(" % "|".join(map(re.escape, statics))
    )
    return {fn for fn, (_sig, body) in functions(src).items() if taking.search(body)}


def derive_lockers(sources: dict[str, str], roots: set[str]) -> set[str]:
    """Everything that reaches a root, transitively."""
    bodies = {}
    for name, src in sources.items():
        for fn, (_sig, body) in functions(src).items():
            bodies[(name, fn)] = body

    lockers = {k for k in bodies if k[1] in roots}
    changed = True
    while changed:
        changed = False
        for k, body in bodies.items():
            if k in lockers:
                continue
            for _, callee in lockers:
                if callee == k[1]:
                    continue
                if re.search(r"(?<![.\w])%s\s*\(" % re.escape(callee), body):
                    lockers.add(k)
                    changed = True
                    break
    return {fn for _, fn in lockers}


def acquirers(sources: dict[str, str], roots: set[str]) -> dict[str, bool]:
    """The ways a caller takes the lock -> True if it hands back a guard.

    A root is one. So is any function in the owning module that calls a root
    directly: those are the public doors G1 left (`window`, `shared`,
    `with_windows`). **Whether the lock outlives the call is read off the
    signature, not off the name**: one that takes a closure (`impl Fn`) runs
    it and releases, so its scope is the closure body and nothing after.
    """
    out = {r: True for r in roots}
    src = sources.get(OWNER, "")
    if not roots:
        return out
    # The guard types, read off the module rather than off their names: a
    # guard is a thing that derefs to the state behind the lock.
    guards = set(re.findall(r"(?m)^impl (?:std::ops::)?Deref for (\w+)", src))
    returns_guard = re.compile(
        r"->[^{]*\b(?:%s)\b" % "|".join(map(re.escape, guards))
    ) if guards else None
    reaches_root = re.compile(
        r"(?<![.\w])(?:%s)\s*\(" % "|".join(map(re.escape, roots))
    )
    for fn, (sig, body) in functions(src).items():
        if fn in roots or not reaches_root.search(body):
            continue
        # **Taking the lock and handing back a guard are different jobs.**
        # `count(frame)` reaches the lock and returns a `usize`; the lock is
        # gone by the time the caller has the number, so nothing after that
        # call is under it. Measured on S1, where treating every lock-reaching
        # accessor as a door produced 50 hits against the one real bug --
        # **49 sentences that each named real functions.** One of the four
        # public doors G1 left does the same thing (`with_windows` returns
        # `R`), which is why the closure test is not enough on its own.
        if "impl Fn" in sig:
            # A door whose lock lives exactly as long as the closure it runs.
            out[fn] = False
        elif returns_guard is not None and returns_guard.search(sig):
            out[fn] = True
    return out


def consuming_chain(src: str, i: int) -> bool:
    """True if the chain starting at `i` turns the guard into something else."""
    if not CHAINED.match(src, i):
        return False
    p = i
    while (m := CHAIN_STEP.match(src, p)):
        # A *field* of a guard is not a guard either -- `shared().initial_input`
        # is an `Option`, and this file called it a live guard once already.
        if m.group(2) is None or m.group(1) not in CHAIN_KEEPS_GUARD:
            return True
        p = close_of(src, m.end() - 1) + 1
    return False


def line_start(src: str, i: int) -> int:
    j = src.rfind("\n", 0, i)
    return 0 if j < 0 else j + 1


def end_of_statement(src: str, i: int, limit: int) -> int:
    """Index after the `;` that ends the statement containing `i`."""
    depth = 0
    for j in range(i, min(limit, len(src))):
        c = src[j]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return j
            depth -= 1
        elif c == ";" and depth == 0:
            return j + 1
    return limit


def enclosing_block(src: str, i: int) -> tuple[int, int] | None:
    """(open, close) of the innermost block containing `i`, or None at top level."""
    depth, k = 0, i
    while k > 0:
        if src[k] == "}":
            depth -= 1
        elif src[k] == "{":
            depth += 1
            if depth == 1:
                return k, close_of(src, k)
        k -= 1
    return None


def next_block_after(src: str, i: int, limit: int) -> tuple[int, int] | None:
    """The `{ ... }` opening at `i` or just after it, skipping the scrutinee."""
    depth = 0
    for j in range(i, min(limit, len(src))):
        c = src[j]
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif c == "{" and depth == 0:
            return j, close_of(src, j)
        elif c == ";" and depth == 0:
            return None
    return None


# **`let x = window(f).map(..);` does not bind a guard.** The chain consumes
# it, `x` is whatever the chain returned, and the guard was a temporary that
# died at the `;`. Treating the binding as the guard is how four of the five
# hits on the first clean run of the rewrite were produced -- `strip.rs::state_line`
# claimed a `String` named `model` was holding the lock across three calls,
# **and it named three real functions doing it**, which is what a true finding
# looks like. A bare `?` or a `let ... else` is not a chain; a `.` is.
#
# **But two methods do hand the guard straight back**, and treating those as a
# chain would be the same lie in the other direction -- a narrowing invented by
# this very fix. `unwrap` and `expect` return the inner value untouched, so
# `let w = window(f).unwrap();` binds a real guard for the rest of the block.
# Every other method in the chain transforms it, and the transformed thing is
# not a guard. The list is short because it is the list of methods that return
# what they were given; a longer one would be a guess.
CHAIN_KEEPS_GUARD = ("unwrap", "expect")
CHAINED = re.compile(r"\s*[.?]?\s*\.")
CHAIN_STEP = re.compile(r"\s*\??\s*\.\s*(\w+)\s*(\()?")
ACQUIRE_HEAD_BLOCK = re.compile(r"\b(?:if\s+let|while\s+let|match)\b")
ACQUIRE_HEAD_LET = re.compile(r"\blet\b")
BIND_NAME = re.compile(r"\blet\s+(?:mut\s+)?(?:\w+\s*\(\s*)?(?:mut\s+)?(\w+)")


# The shapes a guard can be bound in. The self-test requires one live example
# of **each**, not a count of hits: a count is met by one shape firing six
# times, and a shape that quietly stops being recognised is exactly the
# narrowing this whole file is a repair for.
SHAPES = ("let", "let-else", "if-let", "match", "temporary", "closure")


def guard_scopes(src: str, acq: dict[str, bool]):
    """Yield (offset, scope_text, guard_name, shape) for every live-guard span."""
    if not acq:
        return
    pat = re.compile(
        r"(?<![.\w])(?:tabs::|crate::tabs::)?(%s)\s*\("
        % "|".join(map(re.escape, sorted(acq, key=len, reverse=True)))
    )
    for m in pat.finditer(src):
        name = m.group(1)
        # `fn window(` is where the door is built, not a place it is opened.
        if re.search(r"\bfn\s+$", src[:m.start()]):
            continue
        enc = enclosing_block(src, m.start())
        if enc is None:
            continue
        args_open = src.index("(", m.end() - 1)
        args_close = close_of(src, args_open)

        if not acq[name]:
            # Closure-scoped: the lock is alive for the closure it is handed,
            # and released when the call returns.
            for c in re.finditer(r"\|[^|\n]*\|", src[args_open:args_close]):
                body = src[args_open + c.end():args_close]
                yield args_open + c.end(), body, "the %s closure" % name, "closure"
            continue

        ls = line_start(src, m.start())
        head = src[ls:m.start()]
        block_end = enc[1]

        if ACQUIRE_HEAD_BLOCK.search(head):
            blk = next_block_after(src, args_close + 1, block_end)
            if blk is None:
                continue
            open_i, close_i = blk
            # `if let ... {} else {}` -- the temporary outlives the then-block.
            tail = src[close_i + 1: close_i + 8]
            if re.match(r"\s*else\b", tail):
                nxt = next_block_after(src, close_i + 1, block_end)
                if nxt:
                    close_i = nxt[1]
            shape = "match" if re.search(r"\bmatch\b", head) else "if-let"
            yield open_i, src[open_i:close_i], "the %s scrutinee" % name, shape
            continue

        if ACQUIRE_HEAD_LET.search(head) and not consuming_chain(src, args_close + 1):
            stmt_end = end_of_statement(src, args_close + 1, block_end)
            b = BIND_NAME.search(head)
            guard = b.group(1) if b else "the guard"
            scope = src[stmt_end:block_end]
            # An explicit `drop(guard)` ends it early.
            dm = re.search(r"drop\(\s*%s\s*\)" % re.escape(guard), scope)
            if dm:
                scope = scope[: dm.start()]
            shape = "let-else" if re.search(r"\belse\b", src[args_close:stmt_end]) \
                else "let"
            yield stmt_end, scope, guard, shape
            continue

        # Unbound temporary: alive to the end of the statement, which is past
        # the closing paren of any method chained onto it.
        stmt_end = end_of_statement(src, args_close + 1, block_end)
        yield args_close, src[args_close:stmt_end], "the %s temporary" % name, \
            "temporary"


def scan(sources: dict[str, str], lockers: set[str], acq: dict[str, bool]):
    """Yield (file, line, guard, shape, called_lockers) for a guard outliving a call."""
    hit_pat = {
        fn: re.compile(r"(?<![.\w])%s\s*\(" % re.escape(fn)) for fn in lockers
    }
    for name, src in sources.items():
        for at, scope, guard, shape in guard_scopes(src, acq):
            hits = sorted({fn for fn, p in hit_pat.items() if p.search(scope)})
            if hits:
                yield name, src.count("\n", 0, at) + 1, guard, shape, hits


# --------------------------------------------------------------- self-test
#
# **Both directions, because the two ways this tool can lie are different.**
# A probe that has stopped matching reports zero and reads exactly like a clean
# tree -- that is the failure we have hit repeatedly, and it is what the
# positive canary is for. A probe that fires on everything is caught by nobody
# unless something clean is fed to it, which is what the negative canary is
# for: without it, "the drop is honoured" is an assumption about our own code.
#
# **These are written in today's vocabulary, and the previous pair not being
# was the point.** They said `state()`, so they went on printing
# `probe self-test: OK` for every run of the two years in which no `state()`
# existed anywhere. **A self-test phrased in the tool's own vocabulary cannot
# detect that vocabulary expiring** -- it agrees with the tool about a word
# neither of them shares with the code any more. So the canaries below declare
# the mutex and derive their roots the same way a real scan does, and if the
# accessors are renamed these stop compiling in the reader's head at the same
# moment the derivation stops matching.

_CANARY_OWNER = """
static STATE: Mutex<Registry> = Mutex::new(Registry::new());

struct Guard {
    inner: std::sync::MutexGuard<'static, Registry>,
}

impl std::ops::Deref for Guard {
    type Target = Registry;
    fn deref(&self) -> &Registry {
        &self.inner
    }
}

impl std::ops::Deref for WinGuard {
    type Target = WindowState;
    fn deref(&self) -> &WindowState {
        &self.inner.windows[self.at]
    }
}

impl std::ops::Deref for SharedGuard {
    type Target = State;
    fn deref(&self) -> &State {
        &self.inner.shared
    }
}

fn reg() -> Guard {
    Guard { inner: STATE.try_lock().unwrap() }
}

// Reaches the lock and hands back a number, not a guard: not a door.
pub fn count(frame: HWND) -> usize {
    reg().windows.len()
}

pub fn window(frame: HWND) -> Option<WinGuard> {
    let g = reg();
    let at = g.windows.iter().position(|w| w.frame == frame)?;
    Some(WinGuard { inner: g, at })
}

pub fn shared() -> SharedGuard {
    SharedGuard { inner: reg() }
}

pub fn with_windows<R>(f: impl FnOnce(&[WindowState]) -> R) -> R {
    let g = reg();
    f(&g.windows)
}
"""

# One entry per guard shape, so a shape that stops being recognised is a
# failure here rather than a silent narrowing in the field.
CANARY_BAD = {
    "tabs": _CANARY_OWNER,
    "canary": """
fn take_cwd(s: usize) -> String {
    let mut sh = shared();
    sh.pending.remove(&s)
}

fn plain_let(s: usize) {
    let mut sh = shared();
    sh.next += take_cwd(s).len();
}

fn let_else(frame: HWND) {
    let Some(mut win) = window(frame) else {
        return;
    };
    win.tabs.push(Tab { cwd: take_cwd(0) });
}

fn if_let(frame: HWND) {
    if let Some(mut win) = window(frame) {
        win.title = take_cwd(1);
    }
}

fn matched(frame: HWND) {
    match window(frame) {
        Some(_) => {}
        None => {
            take_cwd(2);
        }
    }
}

fn temporary(frame: HWND) -> usize {
    window(frame).map(|w| w.tabs.len()).unwrap_or(take_cwd(3).len())
}

fn unwrapped(frame: HWND) {
    let mut win = window(frame).unwrap();
    win.title = take_cwd(4);
}

fn inside_the_chain(frame: HWND) -> usize {
    window(frame).map(|w| w.tabs.len() + take_cwd(5).len()).unwrap_or(0)
}

fn in_closure(frame: HWND) {
    with_windows(|ws| {
        take_cwd(ws.len());
    });
}
""",
}

CANARY_OK = {
    "tabs": _CANARY_OWNER,
    "canary": """
fn take_cwd(s: usize) -> String {
    let mut sh = shared();
    sh.pending.remove(&s)
}

fn read_it_first(frame: HWND) {
    let cwd = take_cwd(0);
    let Some(mut win) = window(frame) else {
        return;
    };
    win.tabs.push(Tab { cwd });
}

fn dropped_first(frame: HWND) {
    let Some(mut win) = window(frame) else {
        return;
    };
    win.dirty = true;
    drop(win);
    take_cwd(1);
}

fn after_the_if(frame: HWND) {
    if let Some(mut win) = window(frame) {
        win.dirty = true;
    }
    take_cwd(2);
}

// **The negative control for the door test.** `count` reaches the lock and
// returns a number; the lock is released before the caller has it. Calling
// this a door is what produced 49 of S1's 50 hits.
fn a_lock_reaching_call_is_not_a_door(frame: HWND) -> usize {
    let n = count(frame);
    take_cwd(n).len()
}

// A field read is a chain step too, and it was the last of the four on the
// real tree: `shared().initial_input.take()` bound an `Option`, not a guard.
fn field_of_a_guard(s: usize) -> usize {
    let taken = shared().pending.len();
    take_cwd(taken).len()
}

// **The negative control for `consuming_chain`.** `model` is a `String`; the
// guard died at the `;`. Before that distinction existed this file called
// four of these live guards on the real tree, naming real functions each
// time. Remove the check and this canary is what says so.
fn chain_result_is_not_a_guard(frame: HWND) -> usize {
    let model = window(frame).map(|w| w.tabs.len()).unwrap_or(0);
    take_cwd(model).len()
}

fn after_the_closure(frame: HWND) -> usize {
    let n = with_windows(|ws| ws.len());
    take_cwd(n).len()
}
""",
}


def _canary(sources):
    roots = derive_roots(sources)
    return roots, list(scan(sources, derive_lockers(sources, roots),
                            acquirers(sources, roots)))


def self_test() -> None:
    roots, bad = _canary(CANARY_BAD)
    if not roots:
        print("FAIL: the canary declares a mutex and this found no function "
              "taking it -- the root derivation, not the canary, is what "
              "broke.")
        sys.exit(1)
    seen = {sh for _f, _l, _g, sh, _h in bad}
    missing = [sh for sh in SHAPES if sh not in seen]
    if missing:
        print(f"FAIL: the probe no longer sees these guard shapes: {missing} "
              f"(it saw {sorted(seen)}). A shape dropping out here is the same "
              f"narrowing that left this gate green for two years.")
        sys.exit(1)
    _roots, ok = _canary(CANARY_OK)
    if ok:
        print(f"FAIL: the probe fires on code that releases the guard first: {ok}")
        sys.exit(1)
    print(f"probe self-test: OK (roots {sorted(roots)}; sees all "
          f"{len(SHAPES)} re-entrant shapes, ignores the four released ones)")


def main() -> int:
    self_test()

    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host", "src")
    paths = sorted(glob.glob(os.path.join(root, "*.rs")))

    # **A gate that scanned nothing exits 0 and reads as green.**
    # Measured, not assumed: pointed at a tree where `windows/host/src/` is empty,
    # this gate printed `scanned 0 files` and then its own all-clear, and returned
    # 0. **The count was already on the screen -- nothing acted on it.**
    #
    # `ps1-parses.py` is the model. What has to be non-empty is the *subject set*,
    # not the hit count: zero hits is a real pass, zero files is not an answer.
    if not paths:
        print(f"FAIL: no .rs file under {root}; this gate is looking in the "
              f"wrong place. It did not find a clean tree -- it found nothing "
              f"to look at, and those two exit the same way unless this line "
              f"exists.")
        return 1

    sources = {}
    for path in paths:
        with open(path, encoding="utf-8") as fh:
            sources[os.path.basename(path)[:-3]] = blank_noncode(fh.read())

    roots = derive_roots(sources)
    lockers = derive_lockers(sources, roots)
    acq = acquirers(sources, roots)
    sites = sum(len(list(guard_scopes(src, acq))) for src in sources.values())
    print(f"scanned {len(paths)} files; roots {sorted(roots) or '(none)'}; "
          f"{len(acq)} ways in; {len(lockers)} functions reach the lock; "
          f"{sites} guard sites\n")

    # **The same sentence as the file guard, one level in.** An empty root set
    # or an empty locker set is what this gate looked like for the whole of its
    # dead period: it printed `0 functions reach the lock` and then `no
    # unexpected hits`, and the zero was the entire diagnosis. Zero hits is a
    # real pass. Zero lockers is not an answer.
    #
    # This is the only line here that survives the author having guessed
    # today's accessor names wrongly, which is why it is a hard failure and not
    # a warning.
    if not roots:
        print(f"FAIL: no function in `{OWNER}.rs` takes a module-level "
              f"`Mutex` static. Either the lock moved, or it is no longer "
              f"taken by a name this looks for -- and until that is fixed "
              f"this gate is scanning {len(paths)} files for nothing.")
        return 1
    if lockers <= roots:
        print(f"FAIL: nothing outside {sorted(roots)} reaches the lock, which "
              f"cannot be true of a tree that compiles -- the fixed point has "
              f"stopped matching call sites. A green run from here would mean "
              f"only that there was nothing to look for.")
        return 1
    # **The half that died silently last time.** The locker set can be
    # perfectly derived while the scan finds nowhere to apply it: that is
    # exactly what happened to `let x = state();`, which matched nothing from
    # G1 onward and said so only by not appearing. A tree with 163 lockers and
    # no guard sites is not a clean tree, it is an unread one.
    if not sites:
        print(f"FAIL: {len(lockers)} functions reach the lock and not one "
              f"guard site was found in {len(paths)} files. The shapes this "
              f"looks for are not the shapes the code is written in; every "
              f"hit it could report is unreachable.")
        return 1

    unexpected = []
    for name, line, guard, shape, hits in scan(sources, lockers, acq):
        where = f"{name}.rs:{line}"
        if name + ".rs" in KNOWN:
            print(f"known  {where}  ({shape}) guard `{guard}` -> {hits}")
            continue
        unexpected.append(where)
        print(f"HIT    {where}  ({shape}) guard `{guard}` is alive across {hits}")

    if unexpected:
        print(f"\n{len(unexpected)} unexpected; each one is a five-second panic waiting.")
        return 1
    print("no unexpected hits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
