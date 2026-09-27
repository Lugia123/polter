#!/usr/bin/env python3
r"""Every implementation of the project filename rule reads the one table.

# Why this exists

The rule that turns a project name into a filename is written three times
-- `src/Project.zig`, `windows/projectname/src/lib.rs`, and
`macos/Sources/Features/Projects/ProjectFilename.swift` -- and for most of
its life the three disagreed without anything noticing (issue #23): Zig cut
by byte and could split a character, Swift cut by Character and could
overflow the filesystem on emoji, Rust pushed each UTF-8 byte as a char and
wrote mojibake. Each was self-consistent, so each one's own tests were green.

A rule isn't a field, so a shared sample file can't hold it. What can is a
table of `input -> expected filename` that all three run:
`test/fixtures/project-filenames.tsv`. This gate is the half of that
arrangement a test can't do for itself: seeing that each of the three is
wired to the table at all.

# The two halves, and which one catches what

  1. Here: each consumer's test file names the table's path. That catches
     "never wired up" -- and only that. A name appearing is not the table
     being used.
  2. In each consumer: the test asserts it ran exactly `# rows: N` rows.
     That catches "wired up, reads nothing" -- a reader that finds no rows
     passes every per-row assertion, and fails that one.

Neither half can stand in for the other.

# Consumers not wired up yet

`PENDING` names the consumers whose implementation of the new rule hasn't
landed, with who owns it. A pending consumer that already names the table
fails this gate: the exemption has outlived its reason and must go, or it
would go on excusing that file after it breaks.

# NOT CHECKED

- Whether any consumer's test actually runs, or passes. That is its own
  test suite's job (and the row-count assertion's).
- Whether the expected column is *right*. It was produced by the macOS
  implementation and cross-checked against an independent reimplementation
  (#838); a wrong rule written consistently everywhere passes here.
- The `draft` rows' expectations: see the table's header.
"""

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TABLE = "test/fixtures/project-filenames.tsv"

CONSUMERS = [
    "macos/Tests/Projects/ProjectFilenameTableTests.swift",
    "windows/projectname/src/lib.rs",
    "src/Project.zig",
]

PENDING = {}

STATUSES = {"ok", "draft"}


def check_table(problems):
    path = ROOT / TABLE
    try:
        raw = path.read_bytes()
    except OSError as e:
        problems.append(f"{TABLE}: cannot read: {e}")
        return 0
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as e:
        problems.append(f"{TABLE}: not ASCII at byte {e.start} -- the data is hex so nothing can rewrite it; keep the notes ASCII too")
        return 0

    declared = None
    rows = 0
    seen = {}
    for number, line in enumerate(text.split("\n"), 1):
        line = line.rstrip("\r")
        if not line:
            continue
        if line.startswith("#"):
            if line.startswith("# rows: "):
                try:
                    declared = int(line[len("# rows: "):])
                except ValueError:
                    problems.append(f"{TABLE}:{number}: '# rows:' is not a number")
            continue
        fields = line.split("\t")
        if len(fields) != 4:
            problems.append(f"{TABLE}:{number}: {len(fields)} fields, want 4 (input, expected, status, note)")
            continue
        source, expected, status, _ = fields
        if source in seen:
            problems.append(f"{TABLE}:{number}: same input as line {seen[source]} -- the row adds no coverage but still counts toward '# rows', which is exactly what that count can't see")
        seen.setdefault(source, number)
        try:
            bytes.fromhex(source).decode("utf-8")
        except ValueError:
            problems.append(f"{TABLE}:{number}: input is not hex of valid UTF-8")
        if expected != "ERR:InvalidName":
            try:
                if not bytes.fromhex(expected).decode("utf-8").endswith(".json"):
                    problems.append(f"{TABLE}:{number}: expected filename doesn't end in .json")
            except ValueError:
                problems.append(f"{TABLE}:{number}: expected is neither ERR:InvalidName nor hex of valid UTF-8")
        if status not in STATUSES:
            problems.append(f"{TABLE}:{number}: status '{status}', want one of {sorted(STATUSES)}")
        rows += 1

    if declared is None:
        problems.append(f"{TABLE}: no '# rows: N' line -- consumers assert against it")
    elif declared != rows:
        problems.append(f"{TABLE}: '# rows: {declared}' but {rows} data rows")
    if rows == 0:
        problems.append(f"{TABLE}: no data rows -- an empty table would make every consumer vacuously green")
    return rows


def check_consumers(problems):
    wired = []
    for consumer in CONSUMERS:
        try:
            text = (ROOT / consumer).read_text(encoding="utf-8")
        except OSError as e:
            problems.append(f"{consumer}: cannot read: {e}")
            continue
        names_table = TABLE in text
        if consumer in PENDING:
            if names_table:
                problems.append(f"{consumer}: now reads {TABLE} but is still in PENDING ({PENDING[consumer]}) -- remove the exemption")
            else:
                print(f"      pending: {consumer} -- {PENDING[consumer]}")
            continue
        if not names_table:
            problems.append(f"{consumer}: doesn't refer to {TABLE}")
        else:
            wired.append(consumer)
    return wired


def main():
    problems = []
    rows = check_table(problems)
    wired = check_consumers(problems)
    if not wired:
        problems.append("no consumer is wired to the table -- nothing holds the rule")

    if problems:
        print("FAIL: the project filename table is not holding the three implementations together:")
        for p in problems:
            print(f"      {p}")
        return 1

    print(f"{TABLE}: {rows} rows; wired: {len(wired)} of {len(CONSUMERS)} ({', '.join(wired)})")
    print("NOT CHECKED: that the consumers' tests run or pass; that the expected column is right; the draft rows.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
