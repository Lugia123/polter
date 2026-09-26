#!/usr/bin/env python3
"""Every host flag the Windows host reads is in the table, and every flag in
the table is read.

**Why this exists (issue #21).** The host's own command-line flags live under
`--polter-host-`, which the core skips on purpose; `windows/cliargs`'s
`HOST_FLAGS` is the list the host accepts, and a flag not on it is refused at
start-up. That leaves two ways for a flag to go quiet, and neither shows up
anywhere else:

  * The host reads a name that is **not** in the table (`has("draw-on-pain")`).
    `HostFlags::has` panics on it -- but only when that line runs, and a flag
    read on a rare path would sit there until somebody took that path.
  * The table lists a name that **nothing reads**. Then the flag is accepted
    on the command line and does nothing: #21 again, one flag at a time.

⚠️ **`paint-requests-are-answered.py` is not a guard for this**, although it
mentions `--polter-host-draw-on-paint` in its prose: it keys on
`surface_refresh` / `ValidateRect`, and misspelling the flag name leaves it
green (measured when this gate was written).

Reads names only from calls spelt `host_flags().has("…")` or
`host_flags().value("…")` in `windows/host/src/*.rs`. **NOT CHECKED**: a flag
read some other way -- which `HostFlags` makes impossible unless someone goes
back to `std::env::args()`, and that is what `std::env::args` below is for.

Run:  python3 windows/tools/host-flags-are-in-the-table.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TABLE = ROOT / "windows" / "cliargs" / "src" / "lib.rs"
SRC = ROOT / "windows" / "host" / "src"

READ = re.compile(r'host_flags\(\)\s*\.\s*(?:has|value)\(\s*"([a-z0-9-]+)"\s*\)')
ROW = re.compile(r'^\s*\("([a-z0-9-]+)",\s*Takes::\w+\),\s*$', re.M)
# A flag read around the table: the thing this gate cannot see by name, so it
# refuses the shape instead. `cli_action_in(std::env::args())` is the CLI
# action question, not a flag read, and is the one allowed spelling.
RAW_ARGS = re.compile(r"std::env::args\(\)")
ALLOWED_RAW = re.compile(
    r"cli_action_in\(std::env::args\(\)\)"
    r"|polter_cliargs::host_flags\(std::env::args\(\)\)"
    r"|let mine: Vec<String> = std::env::args\(\)\.collect\(\)"
)


def strip_comments(text: str) -> str:
    return re.sub(r"//[^\n]*", "", text)


def main() -> int:
    problems = []
    if not TABLE.is_file():
        print(f"FAIL: missing {TABLE}")
        return 1
    table_text = TABLE.read_text(encoding="utf-8")
    body = table_text.split("pub const HOST_FLAGS", 1)
    rows = set(ROW.findall(body[1].split("];", 1)[0])) if len(body) == 2 else set()
    if not rows:
        print("FAIL: read no rows out of HOST_FLAGS -- the table moved or its shape changed")
        return 1

    used = {}
    files = sorted(SRC.glob("*.rs"))
    for p in files:
        text = strip_comments(p.read_text(encoding="utf-8"))
        for m in READ.finditer(text):
            used.setdefault(m.group(1), []).append(p.name)
        for m in RAW_ARGS.finditer(text):
            line = text[text.rfind("\n", 0, m.start()) + 1 : text.find("\n", m.end())]
            if not ALLOWED_RAW.search(line):
                problems.append(f"{p.name}: reads std::env::args() directly -- flags go through host_flags(): {line.strip()}")
    if not files or not used:
        print(f"FAIL: scanned {len(files)} files and found {len(used)} flag reads -- nothing to check")
        return 1

    for name, where in sorted(used.items()):
        if name not in rows:
            problems.append(f"{', '.join(sorted(set(where)))}: reads --polter-host-{name}, which is not in HOST_FLAGS")
    for name in sorted(rows - set(used)):
        problems.append(f"HOST_FLAGS lists --polter-host-{name}, which nothing reads")

    print(f"scanned {len(files)} files: {len(used)} flags read, {len(rows)} in HOST_FLAGS")
    if problems:
        for p in problems:
            print("FAIL: " + p)
        return 1
    print("ok: every flag read is in the table, and every flag in the table is read")
    return 0


if __name__ == "__main__":
    sys.exit(main())
