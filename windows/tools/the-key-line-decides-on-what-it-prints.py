#!/usr/bin/env python3
"""What decides whether the key line speaks must see all of what it prints.

The `[key] msg=… vk=… mods=… -> surface_key=…` line is the only evidence that
a keystroke reached the core. Its gate was:

    let modded = ev_mods & (MODS_CTRL | MODS_ALT | MODS_SUPER) != 0;
    if n <= 20 || modded { … }

**Three bits of a value the line prints in full.** Shift is not in that mask,
so after the twentieth key of the process a bare key and a shift-only
combination stopped being reported for ever, while `Ctrl-C` went on speaking.
`docs/windows/keys.md` reads a missing `[key]` line into a verdict row -- and
for a control key that reading is sound, which is what made the hole so hard
to see: the criterion worked every time anybody tried it.

⚠️ **The counter was not the fault.** A throttle is fine. The fault is that
the throttle's escape was computed from a *subset* of the event, so whole
classes of key had no escape at all, and nothing in the line said which class
it was looking at.

# The rule

**Something in the condition must have been given the whole event.** Not the
mask -- the value the line reports. A decision taken from part of a thing,
about a line that reports all of it, cannot be read back: you cannot tell,
from the log, which keys were eligible to appear in it.

Stated so it survives a rewrite: at least one disjunct of the gate must be an
identifier bound from a call that receives `ev_mods` **unmasked**. How the
callee decides is not this file's business -- first-of-its-kind, a rate limit
per key, a sampler -- only that it was allowed to see what the line claims.

**Names are not the evidence.** The disjunct, the binding and the callee may
all be renamed together and this stays quiet; that is the negative control in
the self-test, and a checker that pinned the names would be measuring them.

**NOT CHECKED:**

  * **That the callee is any good.** It may return `false` always. This says
    what it was shown, not what it does with it -- there is no way to check
    the second by reading text, and pretending otherwise would be worse than
    the gap.
  * **Other log lines.** The rule is stated for the one line whose absence a
    written criterion reads. Generalising it to "every gated line must see
    its own fields" would sweep in throttles that are deliberately coarse.
  * **The counter's size.** Twenty is not defended here; it does not need to
    be, once there is an escape that does not depend on it.

Run:  python3 windows/tools/the-key-line-decides-on-what-it-prints.py
Exit: 0 when the gate was shown the whole event.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KEYS = ROOT / "windows" / "host" / "src" / "keys.rs"

NEEDLE = '"[key] msg=0x{:x} vk='
# The field whose loss started this: the modifiers, printed whole.
WHOLE = "ev_mods"


def mask(src: str) -> str:
    """Comments and string bodies blanked, line count preserved.

    The docstring of the function under test quotes the broken mask verbatim,
    and so does this file. A checker that read raw text would find its own
    explanation and report on that.
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
                out.append(" ")
                i += 1
    return "".join(out)


def enclosing_condition(code: str, at: int):
    """The nearest `if …{` whose body contains `at`."""
    best = None
    for m in re.finditer(r"\bif\s+([^\n{]+?)\s*\{", code[:at]):
        best = m
    return best.group(1) if best else None


def split_or(cond: str) -> list:
    """Top-level `||` split."""
    out, depth, cur = [], 0, ""
    i = 0
    while i < len(cond):
        ch = cond[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if depth == 0 and cond.startswith("||", i):
            out.append(cur.strip())
            cur = ""
            i += 2
            continue
        cur += ch
        i += 1
    out.append(cur.strip())
    return [x for x in out if x]


def call_args(code: str, open_at: int) -> str:
    depth = 0
    for i in range(open_at, len(code)):
        if code[i] == "(":
            depth += 1
        elif code[i] == ")":
            depth -= 1
            if depth == 0:
                return code[open_at + 1 : i]
    return ""


def check(src: str) -> list:
    code = mask(src)
    raw_at = src.find(NEEDLE)
    if raw_at < 0:
        return [
            f"keys.rs: the line {NEEDLE} is gone. If it was renamed this checker "
            f"has been asserting nothing; if it was removed, the criterion in "
            f"docs/windows/keys.md that reads its absence has to go with it."
        ]
    at = code.find("logf!", max(0, raw_at - 200))
    at = at if at >= 0 else raw_at
    cond = enclosing_condition(code, at)
    if cond is None:
        # No gate at all: every key speaks. Nothing to check and nothing wrong.
        return []

    # The line must still print the whole value, or the rule below is about
    # something the reader never sees.
    stmt_end = code.find(";", at)
    if WHOLE not in code[at:stmt_end]:
        return [
            f"keys.rs: the key line no longer prints `{WHOLE}`. The rule here is "
            f"that its gate must see everything the line reports, so if the line "
            f"stopped reporting the modifiers this entry needs rewriting, not "
            f"passing."
        ]

    problems = []
    shown = []
    for term in split_or(cond):
        ident = term.strip()
        if not re.fullmatch(r"[A-Za-z_]\w*", ident):
            continue
        b = re.search(rf"\blet\s+{re.escape(ident)}\s*=\s*([A-Za-z_][\w:]*)\s*\(", code)
        if not b:
            continue
        args = call_args(code, code.index("(", b.end() - 1))
        # `ev_mods` must arrive whole: as its own argument, not inside a mask.
        for a in args.split(","):
            a = a.strip()
            if a == WHOLE:
                shown.append((ident, b.group(1)))
                break
    if not shown:
        problems.append(
            f"keys.rs: nothing in the key line's gate `{cond.strip()}` was given "
            f"`{WHOLE}` whole. ⚠️ The gate then decides from part of an event "
            f"whose whole it prints, and no reader can tell from the log which "
            f"keys were eligible to appear in it -- which is how a mask without "
            f"shift silenced every bare key past the twentieth while `Ctrl-C` "
            f"went on speaking."
        )
    return problems


CANARIES = [
    ("the defect: a mask and a counter, nothing else", 1, """
fn on_key() {
    let n = KEYS_LOGGED.fetch_add(1, Relaxed) + 1;
    let modded = ev_mods & (MODS_CTRL | MODS_ALT | MODS_SUPER) != 0;
    if n <= 20 || modded {
        logf!("[key] msg=0x{:x} vk={} mods=0x{:x}", msg, vk, ev_mods);
    }
}
"""),
    ("an escape that was shown the whole value", 0, """
fn on_key() {
    let n = KEYS_LOGGED.fetch_add(1, Relaxed) + 1;
    let modded = ev_mods & (MODS_CTRL | MODS_ALT | MODS_SUPER) != 0;
    let novel = first_of_its_kind(msg, vk, ev_mods, consumed_by_core);
    if n <= 20 || modded || novel {
        logf!("[key] msg=0x{:x} vk={} mods=0x{:x}", msg, vk, ev_mods);
    }
}
"""),
    # ⚠️ The same escape, handed the masked value. The shape is identical and
    # the defect is back one level down.
    ("the escape given the mask instead", 1, """
fn on_key() {
    let n = KEYS_LOGGED.fetch_add(1, Relaxed) + 1;
    let modded = ev_mods & (MODS_CTRL | MODS_ALT | MODS_SUPER) != 0;
    let novel = first_of_its_kind(msg, vk, ev_mods & MODS_CTRL, consumed_by_core);
    if n <= 20 || modded || novel {
        logf!("[key] msg=0x{:x} vk={} mods=0x{:x}", msg, vk, ev_mods);
    }
}
"""),
    # ⭐ The negative control: disjunct, binding and callee all renamed.
    ("renamed throughout", 0, """
fn on_key() {
    let n = KEYS_LOGGED.fetch_add(1, Relaxed) + 1;
    let modded = ev_mods & (MODS_CTRL | MODS_ALT | MODS_SUPER) != 0;
    let unseen = never_reported_before(msg, vk, ev_mods, consumed_by_core);
    if n <= 20 || modded || unseen {
        logf!("[key] msg=0x{:x} vk={} mods=0x{:x}", msg, vk, ev_mods);
    }
}
"""),
    # No gate at all is not this file's problem.
    ("no gate", 0, """
fn on_key() {
    logf!("[key] msg=0x{:x} vk={} mods=0x{:x}", msg, vk, ev_mods);
}
"""),
    # The prose quoting the broken mask must not be read as code.
    ("the mask quoted only in a comment", 0, """
fn on_key() {
    // It used to be `if n <= 20 || modded` with modded from
    // `ev_mods & (MODS_CTRL | MODS_ALT | MODS_SUPER)`, which dropped shift.
    let novel = first_of_its_kind(msg, vk, ev_mods, consumed_by_core);
    if novel {
        logf!("[key] msg=0x{:x} vk={} mods=0x{:x}", msg, vk, ev_mods);
    }
}
"""),
]


def selftest() -> list:
    bad = []
    for name, want, src in CANARIES:
        got = check(src)
        if len(got) != want:
            bad.append(f"self-test {name!r}: expected {want}, got {len(got)}: {got}")
    return bad


def main() -> int:
    bad = selftest()
    if bad:
        print("This checker is broken; it was not run against the tree.")
        for b in bad:
            print("  " + b)
        return 1
    problems = check(KEYS.read_text(encoding="utf8"))
    if problems:
        for p in problems:
            print("  " + p)
        print(f"{len(problems)} problem(s).")
        return 1
    print("the key line's gate was shown the whole event it reports.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
