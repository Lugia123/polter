#!/usr/bin/env python3
"""A tab is not always a terminal, and every place that asks has to say so.

**The rule** (dev-docs/windows/control-room.md, 2.1). A tab used to be a split
tree of panes and nothing else: `Tab` had `tree`, `panes` and `focused` as
fields, and 87 places in `tabs.rs` read them. The control room's tab has no
terminal in it. Leaving the fields there and the pane list empty would have
kept all 87 compiling, each with whatever answer an empty list happens to
give -- focus that goes nowhere, a window that closes without asking, a
screen reader handed pane 0.

So the three fields moved into `Body::Terminal`, and what is inside a tab is
asked through `Tab::kind`, `Tab::front`, `Tab::panes` and `Tab::terminal`.
That only holds while two things stay true, and this reads for both:

  1. **`Tab` has no `tree`, `panes` or `focused` field.** Putting one back is
     how a tab becomes "a terminal, usually" again.
  2. **`Body`, `Front` and `Kind` are matched in full wherever they are
     matched**: no `_ =>` arm in a `match` over one, no `if let`, no
     `while let`, no `matches!`, no `let ... else`. A third kind of tab then
     fails to compile at every one of them, with the compiler naming the
     place. A wildcard would send it quietly down whichever arm was written
     second.

**What is read.** `windows/host/src/*.rs`, comments and string literals
removed.

**NOT CHECKED.**

  * Whether an arm does the right thing. This finds an arm that is missing,
    not one that is wrong.
  * `Option<&Terminal>` from `Tab::terminal()`: a caller may write `let Some(t)
    = tab.terminal() else { ... }`, and what it does in the `else` is its own
    to get right. That is the design -- the caller has to write the `else` --
    and it is why the split actions each log their refusal.
  * A `match` whose scrutinee is one of the three but none of whose arms names
    a variant (every arm a binding). Nothing here is written that way.
  * `Kind` in a file that reaches it some way other than naming
    `polter_control_room::rules` (a re-export, an alias). The settings pages
    have enums of their own called `Kind`, so the name alone cannot be read.
  * A wildcard nested inside a tuple or `Some(..)` pattern alongside a variant
    of another enum. The arms are read as text, at the top level of the
    `match` only.

`probe self-test` plants each offender in a scratch source and checks it is
caught, and that the shapes the host actually uses are not.

Run:  python3 windows/tools/a-tab-body-is-matched-in-full.py
Exit: 0, with `scanned N files` (N > 0) and a non-zero count of matches over
      a tab's kind; non-zero otherwise.
"""

import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(ROOT, "windows", "host", "src")

# `Kind` is a common name: the settings pages have enums called that too. It
# is the tab's only in a file that takes it from the control room's rules.
TAKES_KIND = re.compile(r"polter_control_room::rules::(?:\{[^}]*\bKind\b|Kind\b)|\brules::Kind\b")


def rules_for(code):
    """The patterns for one file: `Body` and `Front` always, `Kind` where it is the tab's."""
    names = "Body|Front|Kind" if TAKES_KIND.search(code) else "Body|Front"
    variant = re.compile(r"\b(?:%s)::[A-Z]\w*" % names)
    forbidden = [
        (re.compile(r"\b(?:if|while)\s+let\b[^=;{]*\b(?:%s)::[A-Z]" % names),
         "`if let` / `while let` over a tab's kind: the other kinds fall through unnamed"),
        (re.compile(r"\bmatches!\s*\([^;{}]*?\b(?:%s)::[A-Z]" % names),
         "`matches!` over a tab's kind: the other kinds are a silent `false`"),
        (re.compile(r"\blet\s+(?:Some\()?(?:\w+::)*(?:%s)::[A-Z][^=;]*=[^;{]*\belse\b" % names),
         "`let ... else` over a tab's kind: the other kinds share one unnamed `else`"),
    ]
    return variant, forbidden


WILDCARD = re.compile(r"(?:^|[,}\n])\s*_\s*(?:=>|if\b)")
FIELDS = ("tree", "panes", "focused")

# Below this the reading is not believable: the host matches a tab's kind in
# a dozen places, and a parser that stopped finding them would report a clean
# tree.
MIN_MATCHES = 8


def strip(src):
    """Rust source with comments and literals blanked, newlines kept."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        two = src[i:i + 2]
        if two == "//":
            j = src.find("\n", i)
            j = n if j < 0 else j
            i = j
        elif two == "/*":
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(ch if ch == "\n" else " " for ch in src[i:j]))
            i = j
        elif c == "r" and re.match(r'r#*"', src[i:]):
            hashes = len(re.match(r"r(#*)", src[i:]).group(1))
            end = '"' + "#" * hashes
            j = src.find(end, i + 2 + hashes)
            j = n if j < 0 else j + len(end)
            out.append('""' + "".join(ch if ch == "\n" else " " for ch in src[i + 2:j]))
            i = j
        elif c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            j = min(j + 1, n)
            out.append('""' + "".join(ch if ch == "\n" else " " for ch in src[i + 2:j]))
            i = j
        elif c == "'" and re.match(r"'(?:\\.[^']*|[^'\\])'", src[i:]):
            j = i + len(re.match(r"'(?:\\.[^']*|[^'\\])'", src[i:]).group(0))
            out.append("' '")
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def match_blocks(code):
    """Each `match`'s arms as text at the top level of its block, with where it starts."""
    for m in re.finditer(r"\bmatch\b", code):
        i = m.end()
        depth = 0
        # The scrutinee ends at the first `{` outside any bracket.
        while i < len(code):
            ch = code[i]
            if ch in "([":
                depth += 1
            elif ch in ")]":
                depth -= 1
            elif ch == "{" and depth == 0:
                break
            elif ch == ";" and depth == 0:
                i = len(code)
                break
            i += 1
        if i >= len(code):
            continue
        start = i
        level = 0
        top = []
        while i < len(code):
            ch = code[i]
            if ch == "{":
                level += 1
                if level > 1:
                    top.append("}")  # an arm's block, collapsed to its end
            elif ch == "}":
                level -= 1
                if level == 0:
                    break
            elif level == 1:
                top.append(ch)
            i += 1
        yield code.count("\n", 0, start) + 1, "".join(top)


def findings(src):
    """`(line, what)` for everything wrong in one source, and how many matches over a kind it has."""
    code = strip(src)
    out = []
    VARIANT, FORBIDDEN = rules_for(src)
    for rx, why in FORBIDDEN:
        for m in rx.finditer(code):
            out.append((code.count("\n", 0, m.start()) + 1, why))
    kinds = 0
    for line, arms in match_blocks(code):
        # Only the patterns: what is left of each `=>`.
        patterns = "\n".join(part.rsplit("\n", 1)[-1] if "\n" in part else part for part in arms.split("=>")[:-1])
        if not VARIANT.search(patterns):
            continue
        kinds += 1
        if WILDCARD.search("\n" + arms):
            out.append((line, "a `_` arm in a `match` over a tab's kind: a new kind would take it without a word"))
    struct = re.search(r"\bpub\s+struct\s+Tab\s*\{(.*?)\n\}", code, re.S)
    if struct:
        for field in FIELDS:
            if re.search(r"^\s*(?:pub\s+)?%s\s*:" % field, struct.group(1), re.M):
                out.append((
                    code.count("\n", 0, struct.start()) + 1,
                    "`Tab` has a `%s` field again: a tab is then a terminal whether or not it is one" % field,
                ))
    return out, kinds, struct is not None


GOOD = """
use polter_control_room::rules::{self, Kind};
pub struct Tab {
    pub id: TabId,
    pub body: Body,
}
fn kind(t: &Tab) -> Kind {
    match &t.body {
        Body::Terminal(_) => Kind::Terminal,
        Body::ControlRoom(_) => Kind::ControlRoom,
    }
}
fn front(t: &Tab) {
    match t.front() {
        Front::Pane(p) => { let _ = match p.id { 0 => 1, _ => 2 }; }
        Front::Room(_) => {}
        Front::NoPane => {}
    }
    // if let Body::Terminal(t) = &tab.body {} -- in a comment, not code
    let s = "matches!(x, Kind::Terminal)";
    let Some(term) = t.terminal() else { return };
    match tabs::front_kind(frame) {
        Some(Kind::ControlRoom) => {}
        Some(Kind::Terminal) | None => {}
    }
}
"""


def self_test():
    cases = [
        ("the shapes the host uses", GOOD, 0),
        ("a wildcard arm", GOOD + "fn f(t:&Tab){ match &t.body { Body::Terminal(x) => {}, _ => {} } }\n", 1),
        ("a wildcard arm after a block arm",
         GOOD + "fn f(t:&Tab){ match t.kind() {\n Kind::Terminal => { a(); }\n _ => {}\n } }\n", 1),
        ("a guarded wildcard", GOOD + "fn f(t:&Tab){ match t.kind() { Kind::Terminal => 1, _ if x => 2, Kind::ControlRoom => 3 } }\n", 1),
        ("if let", GOOD + "fn f(t:&Tab){ if let Body::Terminal(x) = &t.body { } }\n", 1),
        ("while let", GOOD + "fn f(t:&Tab){ while let Front::Pane(p) = t.front() { } }\n", 1),
        ("matches!", GOOD + "fn f(t:&Tab)->bool{ matches!(t.kind(), Kind::Terminal) }\n", 1),
        ("let else", GOOD + "fn f(t:&Tab){ let Body::Terminal(x) = &t.body else { return }; }\n", 1),
        ("another enum that happens to be called Kind, in a file that does not take the tab's",
         "enum Kind { A, B }\nfn f(k: Kind) -> bool { matches!(k, Kind::A) }\n"
         "fn g(t:&Tab){ match &t.body { Body::Terminal(_) => {}, Body::ControlRoom(_) => {} }\n"
         " match t.front() { Front::Pane(_) => {}, Front::Room(_) => {}, Front::NoPane => {} }\n"
         " match t.front() { Front::Pane(_) => {}, Front::Room(_) => {}, Front::NoPane => {} } }\n", 0),
        ("the field put back", GOOD.replace("    pub body: Body,\n", "    pub body: Body,\n    pub panes: Vec<Pane>,\n"), 1),
        ("all three fields put back",
         GOOD.replace("    pub body: Body,\n", "    pub tree: Tree,\n    pub panes: Vec<Pane>,\n    pub focused: PaneId,\n"), 3),
    ]
    for what, src, want in cases:
        got, kinds, _ = findings(src)
        if len(got) != want:
            print(f"probe self-test FAILED: {what} gave {len(got)} finding(s), expected {want}: {got}")
            return False
        if kinds < 3:
            print(f"probe self-test FAILED: {what}: only {kinds} match(es) over a kind were seen, 3 are there")
            return False
    print("probe self-test: OK (wildcard arm, guarded wildcard, if let, while let, matches!, "
          "let-else and the fields put back are caught; comments, strings and inner matches are not)")
    return True


def main():
    if not self_test():
        return 1
    files = sorted(glob.glob(os.path.join(SRC, "*.rs")))
    if not files:
        print(f"FAIL: no source found under {os.path.relpath(SRC, ROOT)}; nothing was checked")
        return 1
    bad = []
    kinds = 0
    saw_tab = False
    for path in files:
        with open(path, encoding="utf-8") as fh:
            got, n, has_tab = findings(fh.read())
        kinds += n
        saw_tab = saw_tab or has_tab
        bad.extend((os.path.relpath(path, ROOT), line, why) for line, why in got)
    print(f"scanned {len(files)} files: {kinds} match(es) over a tab's kind")
    if not saw_tab:
        print("FAIL: `pub struct Tab` was not found, so its fields were not read. If it moved or "
              "was renamed, this has to follow it.")
        return 1
    if kinds < MIN_MATCHES:
        print(f"FAIL: only {kinds} match(es) over a tab's kind were found, expected at least "
              f"{MIN_MATCHES}. Either they were all removed or this stopped recognising them; "
              "in both cases nothing was checked.")
        return 1
    if bad:
        for path, line, why in bad:
            print(f"FAIL: {path}:{line}: {why}")
        print(f"\n{len(bad)} place(s) where a tab's kind is not matched in full.")
        return 1
    print("a tab's kind is matched in full everywhere it is matched")
    return 0


if __name__ == "__main__":
    sys.exit(main())
