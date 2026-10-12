#!/usr/bin/env python3
"""A host draws the control room; it does not decide what the control room says.

**The rule** (dev-docs/poltergeist/control-room.md, 5.4 and the floors of
13.1): which rows there are, their order, which of them need the person, how
many, and which glyph each carries are worked out once, in the core, and
arrive in the snapshot as fields. A host that compares a kind, counts rows or
sorts them is deciding it a second time -- and the second answer is the one
on screen. It compiles, it looks right on the day it is written, and it stops
matching the taskbar badge the first time the core's rule moves.

**What is read.**

  * `windows/control-room/src/*.rs` and `windows/control-room/examples/*.rs`
    -- the Windows host's control-room logic -- apart from the generated
    `look.rs`, test modules, and comments.
  * `windows/host/src/control_room*.rs`, when the host grows them.
  * `macos/Sources/Features/ControlRoom/*.swift`, apart from the generated
    `ControlRoomLook.swift`, and comments.

**What is refused**, in code:

  1. Reading the core's `kind` (or `under`) at all. A host has `shown` for
     the glyph and `text` for the words; there is nothing a kind is for
     except comparing it.
  2. Counting rows: the length of `waiting`, `quiet`, `groups` or `rows`.
     The header numbers are `groups_needing_me` / `groups_other`, and the
     badge is `needs_me`.
  3. Sorting. The rows come in order, and `pulses` comes in order.
  4. Comparing times to pick a winner: `min_by` / `max_by` and their kin.
  5. Working out whether the one waiting is the supervisor: `steward`
     compared with a terminal (`terminal`, `attention`, `about`) on one
     line. The core says who waits (`waiter.is`: the supervisor itself, a
     worker through it, a worker of a group with none, a terminal alone),
     and a host that compares the two ids has its own answer for the day
     the core's rule about a worker's first minute moves. Finding the
     supervisor's member by its id (`$0.id == steward`) is not this.

Counting the *lines* of what a row waits on is not refused: how many there
are is how tall the row is, which is layout. Neither is the index of the last
row (`rows.count - 1`, `rows.len() - 1`): that is where the arrow key stops,
not a number anybody is shown.

**NOT CHECKED.**

  * A count or a comparison written some way this does not recognise -- a
    hand-rolled loop with a counter, `fold`, an index compared with a
    literal. This is a list of the spellings somebody would reach for, not a
    proof.
  * Anything a host does with the *drawn* rows that amounts to a decision
    without touching these names.
  * Tests. A test may count what it was handed.

`--self-test` (also run first by every normal run) plants each kind of
offender in a scratch file and checks it is caught, and that the allowed
spellings are not.

Exit 0 and `scanned N files` with N > 0, or non-zero.
"""

import glob
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

RUST_GLOBS = [
    "windows/control-room/src/*.rs",
    "windows/control-room/examples/*.rs",
    "windows/host/src/control_room*.rs",
]
SWIFT_GLOBS = ["macos/Sources/Features/ControlRoom/*.swift"]
GENERATED = {"look.rs", "ControlRoomLook.swift"}
TEST_FILES = {"fixture_tests.rs"}

ROWS = r"(?:waiting|quiet|groups|rows(?:\(\))?)"

LAST_INDEX = re.compile(r"\s*\)?\s*-\s*1\b")

# `steward` on one side of a comparison and a terminal on the other.
TERMINAL = r"(?:terminal|attention|about)\b"
IS_SUPERVISOR = re.compile(
    r"\bsteward\b[^;\n]*[=!]=[^;\n]*" + TERMINAL + r"|" + TERMINAL + r"[^;\n]*[=!]=[^;\n]*\bsteward\b")
WHO = "works out whether the supervisor is the one waiting"

RUST_RULES = [
    ("reads the core's kind", re.compile(r'"(?:kind|under)"|\.\s*(?:kind|under)\b')),
    ("counts rows", re.compile(ROWS + r"\s*\.\s*(?:len|count)\s*\(")),
    ("counts rows", re.compile(ROWS + r"\b[^;\n]*\.\s*filter\s*\([^;\n]*\.\s*count\s*\(")),
    ("sorts", re.compile(r"\.\s*sort(?:_by|_by_key|_unstable|_unstable_by|_unstable_by_key)?\s*\(")),
    ("picks a winner by comparing", re.compile(r"\.\s*(?:min|max)_by(?:_key)?\s*\(")),
    (WHO, IS_SUPERVISOR),
]
SWIFT_RULES = [
    ("reads the core's kind", re.compile(r'"(?:kind|under)"|\.\s*(?:kind|under)\b|\bvar\s+(?:kind|under)\b')),
    ("counts rows", re.compile(r"\b" + ROWS + r"\s*\.\s*count\b")),
    ("counts rows", re.compile(r"\b" + ROWS + r"\b[^\n]*\.\s*filter\b[^\n]*\.\s*count\b")),
    ("sorts", re.compile(r"\.\s*(?:sort|sorted)\s*[\(\{]")),
    ("picks a winner by comparing", re.compile(r"\.\s*(?:min|max)\s*\(\s*by\s*:")),
    (WHO, IS_SUPERVISOR),
]


def strip_rust(text):
    """Code only: no comments, no string contents except field names, no test modules."""
    # A `#[cfg(test)] mod … { … }` at the end of a file is the convention here.
    cut = re.search(r"#\[cfg\(test\)\]\s*mod\s+\w+\s*\{", text)
    if cut:
        text = text[: cut.start()]
    out = []
    for line in text.split("\n"):
        out.append(re.sub(r"//.*$", "", line))
    return "\n".join(out)


def strip_swift(text):
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return "\n".join(re.sub(r"//.*$", "", line) for line in text.split("\n"))


def scan(path, rules, strip):
    with open(path, encoding="utf-8") as f:
        code = strip(f.read())
    hits = []
    for n, line in enumerate(code.split("\n"), 1):
        for what, rule in rules:
            m = rule.search(line)
            if not m:
                continue
            # The last row's index is a bound, not a count.
            if what == "counts rows" and LAST_INDEX.match(line[m.end():]):
                continue
            hits.append((n, what, line.strip()))
            break
    return hits


def self_test():
    rust_bad = [
        'let n = list.waiting.len();',
        'let n = self.quiet.len() + 1;',
        'let n = snapshot.groups.iter().filter(|g| g.needs_me).count();',
        'let k = field(v, path, "kind")?;',
        'if group.kind == "failed" { }',
        'rows.sort_by(|a, b| a.since_ms.cmp(&b.since_ms));',
        'let first = pulses.iter().min_by_key(|p| p.since_ms);',
        'let own = row.steward == row.terminal;',
        'if g.terminal.as_deref() != g.steward.as_deref() { via() }',
    ]
    rust_ok = [
        'let lines = row.what.lines.len();',
        'match w.is { WaiterIs::Supervisor => own(), _ => other() }',
        'let loan = Loan { group: with.id.clone(), terminal: with.steward.clone().unwrap() };',
        'for row in &list.waiting {',
        'waiting_count: s.groups_needing_me,',
        'if g.needs_me { waiting.push(row); }',
        '// the core\'s `kind` is not a field here',
        'pulses.iter().find(|p| p.window.as_deref() == window)',
        'let to = (at + step).clamp(0, rows.len() - 1);',
    ]
    swift_bad = [
        'let n = list.waiting.count',
        'Text("\\(snapshot.groups.count)")',
        'let n = snapshot.groups.filter { $0.needs_me }.count',
        'var kind: String',
        'if group.kind == "failed" {',
        'let rows = snapshot.groups.sorted { $0.name < $1.name }',
        'if group.attention?.terminal == steward {',
        'let own = group.steward == row.target?.terminal',
    ]
    swift_ok = [
        'let count = CGFloat(row.what.lines.count)',
        'let member = group.members?.first(where: { $0.id == steward })',
        'if row.waiter.is == .supervisor { return supervisor }',
        'waiting: rows.filter { $0.0 }.map { $0.1 },',
        'waitingCount: snapshot.groups_needing_me,',
        '/// not `waiting.count`',
        'return rows[min(max(at + step, 0), rows.count - 1)].id',
    ]
    with tempfile.TemporaryDirectory() as d:
        for name, lines, rules, strip, want in [
            ("bad.rs", rust_bad, RUST_RULES, strip_rust, True),
            ("ok.rs", rust_ok, RUST_RULES, strip_rust, False),
            ("bad.swift", swift_bad, SWIFT_RULES, strip_swift, True),
            ("ok.swift", swift_ok, SWIFT_RULES, strip_swift, False),
        ]:
            for i, line in enumerate(lines):
                p = os.path.join(d, f"{i}-{name}")
                with open(p, "w", encoding="utf-8") as f:
                    f.write(line + "\n")
                hit = bool(scan(p, rules, strip))
                if hit != want:
                    return (f"self-test: `{line}` was {'caught' if hit else 'not caught'}, "
                            f"and should {'not ' if not want else ''}have been")
    return None


def files(patterns):
    out = []
    for pattern in patterns:
        for p in sorted(glob.glob(os.path.join(ROOT, pattern))):
            base = os.path.basename(p)
            if base in GENERATED or base in TEST_FILES:
                continue
            out.append(p)
    return out


def main():
    problem = self_test()
    if "--self-test" in sys.argv:
        print(problem or "self-test: each planted offender is caught, each allowed spelling is not")
        return 1 if problem else 0
    if problem:
        print(f"FAIL: {problem}")
        return 1

    rust = files(RUST_GLOBS)
    swift = files(SWIFT_GLOBS)
    if not rust and not swift:
        print("FAIL: scanned 0 files -- no control-room host sources were found, "
              "so nothing was checked")
        return 1

    bad = 0
    for path, rules, strip in [(p, RUST_RULES, strip_rust) for p in rust] + \
                              [(p, SWIFT_RULES, strip_swift) for p in swift]:
        for n, what, line in scan(path, rules, strip):
            bad += 1
            print(f"{os.path.relpath(path, ROOT)}:{n}: {what}: {line}")

    print(f"scanned {len(rust) + len(swift)} files ({len(rust)} Rust, {len(swift)} Swift)")
    if bad:
        print(f"FAIL: {bad} line(s) where a host decides what the snapshot already says. "
              "Read the field the core sends (`shown`, `text`, `needs_me`, `waiter`, "
              "`groups_needing_me`, `groups_other`, the order of `groups` and `pulses`) "
              "instead of working it out.")
        return 1
    print("OK: no host compares a kind, counts rows, or sorts them")
    return 0


if __name__ == "__main__":
    sys.exit(main())
