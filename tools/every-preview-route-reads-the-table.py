#!/usr/bin/env python3
r"""Every reader of the preview tables reads the one table, and the tables are
sound.

# Why this exists

The `polter-file://` request route and the Content-Type a preview answers with
are each written once per host: `windows/preview-route/src/lib.rs` and
`macos/Sources/Features/Preview/PreviewRoutes.swift`. Two hosts, two languages,
each green on its own -- and until 2026-11-01 nothing looked at both at once.
The route held up only because the test seat compared the two by hand; the
Content-Type did not, and the two had quietly parted on `.css` (`text/css`
against `text/plain`) and `.json`, while both hosts send
`X-Content-Type-Options: nosniff`. That is a stylesheet which renders on one
machine and prints on the other.

What fixes it is a table of `input -> expected` that both readers run:
`test/fixtures/preview-routes.tsv` and `test/fixtures/preview-types.tsv`. This
gate is the half of that arrangement a test cannot do for itself -- the shape
`tools/every-project-filename-rule-reads-the-table.py` has, for the same reason.

# The two halves, and which one catches what

  1. Here: each reader's file, or its test, names the table's path, the table
     parses, and `# rows:` matches. That catches "never wired up" and "wired up
     but the table is broken".
  2. In each reader: the test asserts it read exactly `# rows: N` rows. That
     catches "wired up, reads nothing" -- a reader that finds no rows passes
     every per-row assertion, and fails that one.

Neither half can stand in for the other. The Windows host has **one**
implementation of the Content-Type table (`polter_preview_route::content_type`,
imported by `preview_page.rs`), so on that side the fixture is the only thing
that could disagree with anything; macOS cannot call a Rust crate, so the
fixture is what holds the two hosts' answers together.

# NOT CHECKED

- Whether either reader's tests actually run or pass. This machine cannot run
  the Windows host's tests at all (`windows/host` needs WebView2); that is the
  Windows test machine's, and `preview_page.rs` says so.
- Whether the expected column is *right*. A table whose answers are all wrong
  and consistent passes here. The two hosts agreeing is what is measured, not
  the answers being what a browser would do.
- The empty request, which no route row can carry: a row whose `url` is empty
  ends in tabs and gets trimmed into a three-column one. Both readers assert
  `resolve("")` in their own tests instead.
"""

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Each table, the files that read it, and how many columns it has. **The files
# are the readers themselves where the reader contains the table lookup**
# (Rust's `include_str!`) and the test files where it does not (the Swift side
# reads the fixture from its test, as `ProjectFilenameTableTests` does).
TABLES = [
    {
        "path": "test/fixtures/preview-routes.tsv",
        "columns": 5,
        "header": "case\tverdict\ttoken\trel\turl",
        # The route rows and the type rows have no column in common, so the
        # "one input twice" check names it per table.
        "key": 0,
        "key_name": "case",
        "consumers": [
            "windows/preview-route/src/lib.rs",
            "macos/Tests/Preview/PreviewRoutesTests.swift",
        ],
    },
    {
        "path": "test/fixtures/preview-types.tsv",
        "columns": 3,
        "header": "path\ttype\twhy",
        "key": 0,
        "key_name": "path",
        "consumers": [
            "windows/preview-route/src/lib.rs",
            "macos/Tests/Preview/PreviewRoutesTests.swift",
        ],
    },
]

# One reader, both tables, and one of them is Swift: what each row of each
# table is expected to produce is asserted by whoever reads it. A reader that
# names the table but never parses it is the "wired up, reads nothing" half --
# in the reader, not here.
PENDING = {}


def check_table(table, problems):
    """The table itself: readable, sound, and its own count true."""
    path = ROOT / table["path"]
    name = table["path"]
    try:
        raw = path.read_bytes()
    except OSError as e:
        problems.append(f"{name}: cannot read: {e}")
        return 0
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as e:
        problems.append(
            f"{name}: not ASCII at byte {e.start} -- URLs and types are ASCII, so a "
            f"non-ASCII byte here is a character an editor or an IME put in"
        )
        return 0

    crlf = text.count("\r\n")
    if crlf:
        problems.append(
            f"{name}: {crlf} CRLF line ending(s) -- a Windows checkout gets one anyway, "
            f"so a checked-in one means the file was written on Windows and every "
            f"reader has to strip it"
        )

    declared = None
    rows = 0
    seen = {}
    eol_tab = []
    for number, line in enumerate(text.split("\n"), 1):
        if not line:
            continue
        if line.startswith("#"):
            if line.startswith("# rows:"):
                body = line[len("# rows:"):]
                if body != f" {body.strip()}" or not body.strip().isdigit():
                    problems.append(
                        f"{name}:{number}: {line!r} is not `# rows: N` -- write it the one "
                        f"way, or the two readers' parsers become the thing that has to agree"
                    )
                else:
                    declared = int(body.strip())
            continue
        if line.endswith("\t"):
            eol_tab.append(number)
        fields = line.split("\t")
        if fields[0] == table["header"].split("\t")[0] and rows == 0:
            # The header line: the column names, once, before any row. Both
            # readers skip a line by its first field, so a header whose later
            # names were reordered would be read as neither a header nor a
            # row by one of them.
            if line != table["header"]:
                problems.append(f"{name}:{number}: header is {line!r}, want {table['header']!r}")
            continue
        if len(fields) != table["columns"]:
            problems.append(
                f"{name}:{number}: {len(fields)} fields, want {table['columns']} -- split on the "
                f"tab only, and a row that ends in one was trimmed by an editor"
            )
            continue
        key = fields[table["key"]]
        if key in seen:
            problems.append(
                f"{name}:{number}: same {table['key_name']} as line {seen[key]} -- the row adds "
                f"no coverage but still counts toward `# rows`, which is exactly what that count "
                f"cannot see"
            )
        seen.setdefault(key, number)
        rows += 1

    if eol_tab:
        problems.append(
            f"{name}: line(s) {eol_tab} end in a tab, so the last column is empty -- that is the "
            f"shape an editor trims into a short row"
        )
    if declared is None:
        problems.append(f"{name}: no `# rows: N` line -- both readers assert against it")
    elif declared != rows:
        problems.append(f"{name}: `# rows: {declared}` but {rows} data rows")
    if rows == 0:
        problems.append(f"{name}: no data rows -- an empty table makes every reader vacuously green")
    return rows


def check_consumers(table, problems):
    """Each reader names the table. That, and only that."""
    wired = []
    for consumer in table["consumers"]:
        try:
            text = (ROOT / consumer).read_text(encoding="utf-8")
        except OSError as e:
            problems.append(f"{consumer}: cannot read: {e}")
            continue
        names_table = table["path"] in text
        if consumer in PENDING:
            if names_table:
                problems.append(
                    f"{consumer}: now reads {table['path']} but is still in PENDING "
                    f"({PENDING[consumer]}) -- remove the exemption"
                )
            else:
                print(f"      pending: {consumer} -- {PENDING[consumer]}")
            continue
        if not names_table:
            problems.append(f"{consumer}: doesn't refer to {table['path']}")
        else:
            wired.append(consumer)
    return wired


def main():
    problems = []
    for table in TABLES:
        try:
            rows = check_table(table, problems)
        except Exception as e:  # a gate that crashes is a gate that scans nothing
            problems.append(f"{table['path']}: the check itself raised {e!r}")
            continue
        wired = check_consumers(table, problems)
        if not wired:
            problems.append(
                f"{table['path']}: no reader is wired to it -- nothing holds the two hosts together"
            )
        else:
            print(f"{table['path']}: {rows} rows; wired: {len(wired)} of {len(table['consumers'])}")

    if problems:
        print("FAIL: the preview tables are not holding the two hosts together:")
        for p in problems:
            print(f"      {p}")
        return 1

    print(
        "NOT CHECKED: that either reader's tests run or pass (the Windows host's cannot run "
        "here at all); whether the expected column is right."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
