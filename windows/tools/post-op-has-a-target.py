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

seen = list(scan(CANARY_BAD, "<canary>"))
if len(seen) != 3:
    print(f"FAIL: the probe cannot see a targetless queueing call (saw {len(seen)} of 3).")
    sys.exit(1)
if list(scan(CANARY_OK, "<canary>")):
    print("FAIL: the probe fires on calls that already name their window.")
    sys.exit(1)
print("probe self-test: OK (sees a targetless call, ignores a targeted one and the definition)")

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host", "src")
files = sorted(glob.glob(os.path.join(root, "*.rs")))
untargeted = []
calls = 0
for path in files:
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    calls += len(re.findall(QUEUEING, src))
    for ln, args in scan(src, path):
        untargeted.append((os.path.basename(path), ln, args))

print(f"scanned {len(files)} files; {calls} queueing call(s) or definitions")
for name, ln, args in untargeted:
    print(f"  {name}:{ln}  post_op with {len(args)} argument(s): does not name a window")

print(f"\n{len(untargeted)} queueing call(s) do not name a target window.")
if untargeted:
    print(
        "FAIL: a queued op with no address runs on whichever window drains it.\n"
        "      `post_op(frame, op, from)` -- the frame the action came from,\n"
        "      resolved from its target surface, never `frame_hwnd()`."
    )
    sys.exit(1)
print("none: every queued op says which window it is for.")
sys.exit(0)
