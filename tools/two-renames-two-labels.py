#!/usr/bin/env python3
r"""Two different rename operations must not end up wearing the same label.

# The defect this watches, which is still open

There are two "rename tab" operations and they do different things:

  * `rename_tab` edits the title in place on the tab strip (`strip.rs`)
  * `prompt_tab_title` opens the title overlay (`ctxmenu.rs`, `menu.rs`)

Today they are told apart in English by **one invisible character** --
`Rename Tab...` with three ASCII dots against `Rename Tab` + U+2026 -- which
is issue #15 and is a product decision, not this gate's business. What this
gate is for is the consequence nobody was watching: **merging the two
catalogue entries breaks one of the two menu rows and nothing goes red.**

# Why it reads the source and not `po/`

The warning used to exist only as two hand-written `#` comments in
`po/zh_CN.po`, which protects exactly one language: the template carried
nothing, so a translator starting any other language got two entries one
invisible character apart and no note. The repository already had the right
mechanism -- a `// TRANSLATORS:` line above the call, extracted by
`--add-comments=TRANSLATORS:` (`src/build/GhosttyI18n.zig`) -- so the note
now lives at the call and reaches every language through the template.

Measured with xgettext 1.0 rather than assumed: `--add-comments=TAG` takes
the comment **from the tag line onward**, and it does not require the tag to
begin the block; an ordinary note above it is simply dropped. So a
TRANSLATORS line can be appended directly above a call that already has
comments. (⚠️ `xgettext` on PATH here is conda's 0.21, which cannot read
Rust at all; the build uses a newer one.)

# The invariant, written so that fixing #15 does not make it go red

  1. The two operations never share a label. True whatever the labels say,
     so it survives a rewording.
  2. **Only while they differ by nothing but the ellipsis**, each call site
     carries a TRANSLATORS note naming the other action. Reword either label
     into something distinguishable and this clause stops applying on its
     own -- the gate does not have to be deleted, and nobody has to remember
     it is here.

Merge them and it is red today and after the fix. Drop a note while they are
still one character apart and it is red. Fix #15 properly and it stays green
with no edit here.

# What it does not check

  * whether the labels are *good* -- that is #15
  * the generated `po/*.pot` and `po/*.po`; those come from the source this
    reads, and checking them would only measure when somebody last ran the
    i18n step
  * the macOS side, which has `the-mac-strings-still-have-a-chinese-half.py`
  * that the two actions really do different things; it reads labels
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The two operations, and every file where one of them writes its label. A
# file listed here with no label at all is a failure, not a pass: a reader of
# source text that finds nothing must say so rather than report success.
SITES = {
    # Each site is found by the **action** it is wired to, not by the words
    # on it. A floor proved why: keying on the literal "Rename Tab" made the
    # gate go blind the moment either label was reworded -- which is exactly
    # what fixing #15 does, so the gate would have broken on the fix it is
    # meant to survive.
    "rename_tab": [
        ("windows/host/src/strip.rs", r'TabCmd::Rename => n_\("([^"]*)"\)'),
    ],
    "prompt_tab_title": [
        ("windows/host/src/ctxmenu.rs", r'item\(n_\("([^"]*)"\), "prompt_tab_title"\)'),
        ("windows/host/src/menu.rs", r'act\(n_\("([^"]*)"\), "prompt_tab_title"\)'),
    ],
}

# A note that tells a translator these two are not duplicates has to name the
# other action; "do not merge" on its own does not say what would be lost.
NOTE_MUST_MENTION = ["DIFFERENT action", "merge"]

# How far above the call a TRANSLATORS block may start. Four lines of note
# plus room to grow; xgettext itself has no limit, this is only so that a
# note about something else further up cannot be mistaken for this one.
NOTE_WINDOW = 8



def ellipsis_normalised(s: str) -> str:
    return s.replace("…", "...")


def main() -> int:
    problems: list[str] = []
    found: dict[str, set[str]] = {}
    calls: list[tuple[str, int, str, list[str]]] = []
    scanned = 0

    for action, sites in SITES.items():
        labels: set[str] = set()
        for rel, pattern in sites:
            path = ROOT / rel
            if not path.exists():
                problems.append(f"{rel}: listed in SITES and not on disk")
                continue
            lines = path.read_text(encoding="utf-8").splitlines()
            scanned += 1
            rx = re.compile(pattern)
            hits = 0
            for i, line in enumerate(lines):
                m = rx.search(line)
                if not m:
                    continue
                hits += 1
                labels.add(m.group(1))
                above = lines[max(0, i - NOTE_WINDOW) : i]
                calls.append((rel, i + 1, m.group(1), above))
            if hits == 0:
                problems.append(
                    f"{rel}: nothing matched {pattern!r}, so the {action} label "
                    f"could not be read. Either the call moved or it is written "
                    f"differently now; either way this gate has gone blind and "
                    f"must not report success."
                )
        found[action] = labels

    if problems:
        for p in problems:
            print(f"FAIL {p}")
        return 1

    a, b = found["rename_tab"], found["prompt_tab_title"]

    shared = a & b
    if shared:
        for s in sorted(shared):
            print(
                f"FAIL both rename_tab and prompt_tab_title are labelled {s!r}. "
                f"They do different things -- rename_tab edits in place on the "
                f"tab strip, prompt_tab_title opens the overlay -- so two menu "
                f"rows now say the same thing and do not. See issue #15."
            )
        return 1

    one_char_apart = {ellipsis_normalised(x) for x in a} == {
        ellipsis_normalised(x) for x in b
    }
    if not one_char_apart:
        print(
            f"ok the two labels are distinguishable without counting dots: "
            f"{sorted(a)} vs {sorted(b)}"
        )
        print(f"scanned {scanned} file(s); the TRANSLATORS clause does not apply")
        return 0

    for rel, lineno, label, above in calls:
        block = [ln.strip() for ln in above if ln.strip().startswith("//")]
        note = "\n".join(block)
        if "TRANSLATORS:" not in note:
            print(
                f"FAIL {rel}:{lineno}: {label!r} has no TRANSLATORS note in the "
                f"{NOTE_WINDOW} lines above it. While the two labels are one "
                f"invisible character apart, that note is the only thing "
                f"standing between a tidy-up and a menu row left in English."
            )
            return 1
        missing = [m for m in NOTE_MUST_MENTION if m not in note]
        if missing:
            print(
                f"FAIL {rel}:{lineno}: the TRANSLATORS note for {label!r} does "
                f"not say the near-identical entry is a different action "
                f"(missing {missing!r}). A note that says only 'do not merge' "
                f"does not tell the translator what would be lost."
            )
            return 1

    print(f"ok two rename operations, two labels: {sorted(a)} vs {sorted(b)}")
    print(
        f"scanned {scanned} file(s), {len(calls)} call site(s); "
        f"each carries a TRANSLATORS note naming the other action"
    )
    print("NOT CHECKED: whether the labels are good -- that is issue #15")
    return 0


if __name__ == "__main__":
    sys.exit(main())
