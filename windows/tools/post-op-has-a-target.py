#!/usr/bin/env python3
"""Every `post_op` call must name the window it is for.

The host's queued mutations used to go onto one process-wide queue, and
`post_op` woke `frame_hwnd()` to drain it. With one window that was correct by
coincidence. With two, an action queued from window 2 ran on window 1 -- a new
tab appearing in the window you were not looking at, with a log that read
entirely normally, because nothing in the queue recorded an address to be
wrong about.

`post_op(frame, op, from)` makes the address a parameter, so **the compiler is
the enumerator**: a call that does not name a window does not build, and a
twenty-first call site cannot be added without answering the question. This
file is the second reading of the same fact, and it exists for the case the
compiler cannot see -- a signature loosened later to make a call site "just
work", which would silently return the whole tree to the old behaviour.

**It asserts zero, not twenty.** Twenty is today's number; a batch that splits
or merges arms changes it, and a count baked in here would go red once and
then be edited to the new number by whoever was in a hurry. Zero is the
property.

There is a second, narrower thing it refuses: `frame_hwnd()` in the target
position. That names *a* window, so the first check is satisfied and the
result is the old bug wearing an address. It is caught here by its literal
spelling and nothing else -- **this is not a check that the window is the
right one**, which is not decidable from the text and would go wrong in both
directions. It is a check against one specific expression whose own
documentation already forbids this use:

    /// **Not "the frame", though every one of its callers was written when
    /// that was the same thing.** Each remaining call site is a place that
    /// has not yet been asked which window it means.

Passing that to a queue is not breaking a rule invented here; it is
contradicting the function being called.
"""

import glob
import os
import re
import sys

# **Both names, because eighteen of the twenty arms reach the queue through
# the second one.** `cb_action` resolves the originating window once and hands
# it to `queue_from`, which calls `post_op`. Checking only `post_op` would
# leave the eighteen arms guarded by nothing but the compiler -- which is a
# real guard, and is exactly the guard this file exists to be a second reading
# of. Both take their target as the first argument, so one rule covers both.
QUEUEING = r"(?<![\w.])(?:tabs::)?(?:post_op|queue_from)\s*\("


def split_args(text):
    """Top-level comma-separated arguments of a call, given the text after `(`.

    Depth-aware over `()[]{}` and blind inside string and char literals, so a
    struct literal argument (`Op::SetTabTitle { surface: s, title: t }`) counts
    as one argument rather than two. Returns None if the call is unterminated
    in the text given.
    """
    args, depth, cur, i = [], 0, [], 0
    in_str = in_chr = False
    while i < len(text):
        c = text[i]
        if in_str:
            if c == "\\":
                cur.append(text[i : i + 2])
                i += 2
                continue
            if c == '"':
                in_str = False
        elif in_chr:
            if c == "\\":
                cur.append(text[i : i + 2])
                i += 2
                continue
            if c == "'":
                in_chr = False
        elif c == '"':
            in_str = True
        elif c == "'":
            # A lifetime (`&'static str`) is not a char literal.
            if not re.match(r"'[a-zA-Z_]", text[i:]):
                in_chr = True
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                args.append("".join(cur).strip())
                return [a for a in args if a != ""]
            depth -= 1
        elif c == "," and depth == 0:
            args.append("".join(cur).strip())
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    return None


def scan_first_window(src):
    """Yield (line, arg) for queueing calls whose target is `frame_hwnd()`.

    Deliberately literal. The failure it catches is real and specific -- the
    first window standing in for the originating one -- and any attempt to
    generalise it into "is this the right window?" would need to know what the
    call meant, which the text does not say.
    """
    for m in re.finditer(QUEUEING, src):
        head = src.rfind("fn ", max(0, m.start() - 40), m.start())
        if head != -1 and re.fullmatch(r"post_op|queue_from", src[head + 3 : m.start()].strip()):
            continue
        args = split_args(src[m.end():])
        if not args:
            continue
        if re.search(r"\bframe_hwnd\s*\(", args[0]):
            yield (src.count("\n", 0, m.start()) + 1, args[0])


def scan(src, path):
    """Yield (line, args) for every `post_op` *call* with fewer than 3 args."""
    for m in re.finditer(QUEUEING, src):
        # The definition is not a call.
        head = src.rfind("fn ", max(0, m.start() - 40), m.start())
        if head != -1 and re.fullmatch(r"post_op|queue_from", src[head + 3 : m.start()].strip()):
            continue
        args = split_args(src[m.end():])
        if args is None:
            continue
        if len(args) < 3:
            yield (src.count("\n", 0, m.start()) + 1, args)


# Negative control, both directions. A scanner that reports zero because it
# cannot see anything reads exactly like one that reports zero because the tree
# is clean -- which is the whole failure this project keeps meeting.
CANARY_BAD = '''
fn f() {
    tabs::post_op(Op::SetTabTitle { surface: s as usize, title: t });
    post_op(Op::NewTab);
    queue_from(Op::NewTab, "new_tab action");
}
'''
CANARY_OK = '''
fn f() {
    tabs::post_op(frame, Op::SetTabTitle { surface: s as usize, title: t }, "set_title action");
    post_op(frame, Op::NewTab, "reopen stack");
    queue_from(origin, Op::NewTab, "new_tab action");
    pub fn post_op(frame: HWND, op: Op, from: &'static str) {}
    fn queue_from(origin: Option<HWND>, op: tabs::Op, from: &'static str) -> bool {}
}
'''

FIRST_WINDOW_BAD = '''
fn f() {
    post_op(frame_hwnd(), Op::NewTab, "new_tab action");
    queue_from(Some(tabs::frame_hwnd()), Op::NewTab, "new_tab action");
}
'''
FIRST_WINDOW_OK = '''
fn f() {
    let elsewhere = tabs::frame_hwnd();
    post_op(frame, Op::NewTab, "new_tab action");
    queue_from(origin, Op::NewTab, "new_tab action");
}
'''
if len(list(scan_first_window(FIRST_WINDOW_BAD))) != 2:
    print("FAIL: the probe cannot see frame_hwnd() used as a target.")
    sys.exit(1)
if list(scan_first_window(FIRST_WINDOW_OK)):
    print("FAIL: the probe fires on a targeted call, or on frame_hwnd() used elsewhere.")
    sys.exit(1)

seen = list(scan(CANARY_BAD, "<canary>"))
if len(seen) != 3:
    print(f"FAIL: the probe cannot see a targetless queueing call (saw {len(seen)} of 3).")
    sys.exit(1)
if list(scan(CANARY_OK, "<canary>")):
    print("FAIL: the probe fires on calls that already name their window.")
    sys.exit(1)
print(
    "probe self-test: OK (sees a targetless call and a frame_hwnd() target,\n"
    "                     ignores a targeted one, the definition, and frame_hwnd() elsewhere)"
)

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host", "src")
files = sorted(glob.glob(os.path.join(root, "*.rs")))

# **A gate that scanned nothing exits 0 and reads as green.**
# Measured, not assumed: pointed at a tree where `windows/host/src/` is empty,
# this gate printed `scanned 0 files` and then its own all-clear, and returned
# 0. **The count was already on the screen -- nothing acted on it.**
#
# `ps1-parses.py` is the model. What has to be non-empty is the *subject set*,
# not the hit count: zero hits is a real pass, zero files is not an answer.
if not files:
    print(f"FAIL: no .rs file under {root}; this gate is looking in the wrong "
          f"place. It did not find a clean tree -- it found nothing to look "
          f"at, and those two exit the same way unless this line exists.")
    sys.exit(1)

untargeted = []
first_window = []
calls = 0
for path in files:
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    calls += len(re.findall(QUEUEING, src))
    for ln, args in scan(src, path):
        untargeted.append((os.path.basename(path), ln, args))
    for ln, arg in scan_first_window(src):
        first_window.append((os.path.basename(path), ln, arg))

print(f"scanned {len(files)} files; {calls} queueing call(s) or definitions")
for name, ln, args in untargeted:
    print(f"  {name}:{ln}  post_op with {len(args)} argument(s): does not name a window")

for name, ln, arg in first_window:
    print(f"  {name}:{ln}  target is `{arg}`")

print(f"\n{len(untargeted)} queueing call(s) do not name a target window.")
print(f"{len(first_window)} queueing call(s) pass the first window as the target.")
if untargeted:
    print(
        "FAIL: a queued op with no address runs on whichever window drains it.\n"
        "      `post_op(frame, op, from)` -- the frame the action came from,\n"
        "      resolved from its target surface, never `frame_hwnd()`."
    )
    sys.exit(1)
if first_window:
    print(
        "FAIL: `frame_hwnd()` is the first window, not the window that asked.\n"
        "      Its own documentation says so:\n"
        '        /// **Not "the frame", though every one of its callers was\n'
        "        /// written when that was the same thing.**\n"
        "      Passing it here satisfies `post_op`'s signature and restores the\n"
        "      exact behaviour that signature was added to remove: every queued\n"
        "      op running on window 1. Resolve the originating window instead --\n"
        "      `origin_window(&target)`, or `frame_of_pane` where there is no\n"
        "      target -- and refuse when there is none."
    )
    sys.exit(1)
print("none: every queued op says which window it is for, and none of them says `the first one`.")
sys.exit(0)
