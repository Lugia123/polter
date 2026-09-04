#!/usr/bin/env python3
"""The shipped manifests and the test that asserts them must say the same thing.

# Why this exists, and why it is here rather than in the test

`plugins.rs` has a test that reads `plugins/*/plugin.json` through
`include_str!` and asserts which parameters each one declares. It is a good
test. **It cannot run on the machine where the breakage happens.**

Measured, not assumed:

    cargo test --target x86_64-pc-windows-gnu -p polter-host the_shipped_manifests
    -> process didn't exit successfully: ...polter_host-....exe (exit status: 126)

126 is "this machine cannot execute that binary". The port is developed and
merged on a Mac; only `cargo check` reaches this code there, **and a data
disagreement is not a type error** -- a JSON file gaining a parameter while a
Rust literal keeps the old list compiles perfectly.

That is exactly how it broke: a commit added `rules` to three manifests, the
expectation was not updated, and the merge that brought it in was green on the
machine that made it. **The subject lives in two subtrees (`plugins/` and
`windows/host/src/`) and the only thing connecting them ran on neither of the
machines that could have caught it in time.**

So this is the same fact with a second place to be read: the test on Windows,
this gate wherever anybody is standing.

# What it checks, in both directions

  * every manifest named in the expectation matches the file on disk;
  * **every manifest that declares parameters is named in the expectation.**
    Default-include: a plugin added next week with two parameters and no entry
    would otherwise be outside the check by default, which is the wrong way
    round. A manifest with no parameters may be absent, and is listed anyway.

Exit: 0 if the two agree, 1 otherwise.
"""

import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
RUST = os.path.join(ROOT, "windows", "host", "src", "plugins.rs")


def strip_line_comments(src: str) -> str:
    """Blank `//` comments **without touching string literals.**

    ⚠️ **The table this reads is made of string literals**, so the usual trick
    of blanking strings as well would erase the subject. And the naive
    opposite -- `re.sub(r"//.*", "", line)` -- cuts a string containing `//`
    in half.

    Both halves of that trap have been paid for here already: a criterion in
    this repo counted the symbol names written in doc comments as if they were
    code, and on the same day a `findstr` for a log marker matched the prose
    describing it. **A gate that reads source as text has to say which of the
    two mistakes it is not making**, and the self-test below holds it to both.

    Width and line count are preserved so offsets and line numbers survive.
    """
    out = list(src)
    i, n, in_str = 0, len(src), False
    while i < n:
        c = src[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
        elif c == '"':
            in_str = True
            i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
        else:
            i += 1
    return "".join(out)


def manifests_under_test(src: str) -> dict[str, str]:
    """`include_str!` is the real link between the two subtrees; read that."""
    out = {}
    for m in re.finditer(
        r'include_str!\(\s*"((?:\.\./)+plugins/([\w.-]+)/plugin\.json)"\s*\)', src
    ):
        out[m.group(2)] = m.group(1)
    return out


TABLE_HEAD = re.compile(r"let expected:\s*Vec<\(String,\s*Vec<String>\)>\s*=\s*\[")
ENTRY = re.compile(r'\(\s*"([\w.-]+)"\s*,\s*&\[([^\]]*)\]\s*\[\.\.\]\s*\)')


def expectation(src: str) -> dict[str, list[str]] | None:
    """The literal table, or None if it is no longer where this looks."""
    m = TABLE_HEAD.search(src)
    if not m:
        return None
    depth, i = 0, m.end() - 1
    while i < len(src):
        if src[i] == "[":
            depth += 1
        elif src[i] == "]":
            depth -= 1
            if depth == 0:
                break
        i += 1
    body = src[m.end() - 1 : i + 1]
    out = {}
    for e in ENTRY.finditer(body):
        names = sorted(re.findall(r'"([\w.-]+)"', e.group(2)))
        out[e.group(1)] = names
    return out


def declared(path: str) -> list[str]:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    props = (doc.get("params") or {}).get("properties") or {}
    return sorted(props)


# --------------------------------------------------------------- self-test
#
# **Three things, and the third is the one this file could get wrong quietly.**
# It sees a real table; it does not fire on a table that agrees; and it reads
# source as *text*, so it has to prove which of the two textual traps it is
# avoiding -- a commented-out entry must not count as one, and a `//` inside a
# a string literal must not start a comment.

CANARY = '''
    const ARCHIVE: &str = include_str!("../../../plugins/archive/plugin.json");
    // const GHOST: &str = include_str!("../../../plugins/ghost/plugin.json");
    fn note() -> &'static str { "see https://example.com/a//b for the shape" }
    #[test]
    fn t() {
        let expected: Vec<(String, Vec<String>)> = [
            ("archive", &["dir", "sign_key"][..]),
            // ("ghost", &["boo"][..]),
            ("kimi", &[][..]),
        ]
        .iter()
        .collect();
    }
'''


def self_test() -> None:
    blanked = strip_line_comments(CANARY)
    table = expectation(blanked)
    if table is None:
        print("FAIL: the probe cannot find a table it wrote itself; the anchor "
              "in `expectation` no longer matches the shape in plugins.rs.")
        sys.exit(1)
    if table != {"archive": ["dir", "sign_key"], "kimi": []}:
        print(f"FAIL: a commented-out entry was counted as one, or a real one "
              f"was lost: {table}")
        sys.exit(1)
    if set(manifests_under_test(blanked)) != {"archive"}:
        print(f"FAIL: a commented-out `include_str!` was counted: "
              f"{sorted(manifests_under_test(blanked))}")
        sys.exit(1)
    # The other half of the same trap: the `//` in a URL is not a comment, so
    # the text after it must survive.
    if "example.com/a//b" not in blanked:
        print("FAIL: a `//` inside a string literal was treated as a comment, "
              "which silently deletes whatever followed it on that line.")
        sys.exit(1)
    print("probe self-test: OK (reads the table, ignores commented entries, "
          "leaves `//` inside strings alone)")


def main() -> int:
    self_test()

    paths = sorted(glob.glob(os.path.join(ROOT, "plugins", "*", "plugin.json")))
    # **Zero files is not a clean tree, it is a gate looking in the wrong
    # place**, and the two exit the same way unless this says so. The lesson is
    # `gates-fail-on-empty.py`'s, and the reason it is repeated here rather
    # than trusted is `lock-reentry.py`: that gate derived an empty set and
    # printed `0 functions reach the lock` before its own all-clear, every run,
    # for as long as the symbol it looked for had been gone.
    if not paths:
        print(f"FAIL: no plugin.json under {os.path.join(ROOT, 'plugins')}. "
              f"This gate found nothing to look at, which is not the same as "
              f"finding nothing wrong.")
        return 1
    if not os.path.exists(RUST):
        print(f"FAIL: {RUST} is not there, so there is no expectation to "
              f"compare against.")
        return 1

    with open(RUST, encoding="utf-8") as fh:
        src = strip_line_comments(fh.read())

    table = expectation(src)
    if table is None:
        print("FAIL: the expectation table is no longer where this looks for "
              "it (`let expected: Vec<(String, Vec<String>)> = [`). Either it "
              "moved or the test was rewritten -- **and until this is pointed "
              "at the new shape, a green run here would mean only that there "
              "was nothing to compare.**")
        return 1
    under_test = manifests_under_test(src)
    on_disk = {os.path.basename(os.path.dirname(p)): p for p in paths}

    print(f"{len(on_disk)} shipped manifests; {len(under_test)} reached by "
          f"`include_str!`; {len(table)} in the expectation\n")

    bad = []
    for key in sorted(set(table) | set(under_test)):
        path = on_disk.get(key)
        if path is None:
            bad.append(f"{key}: named in plugins.rs, but no plugins/{key}/plugin.json")
            continue
        want = table.get(key)
        if want is None:
            bad.append(f"{key}: read by `include_str!` but absent from the expectation")
            continue
        got = declared(path)
        if got != want:
            add = [p for p in got if p not in want]
            gone = [p for p in want if p not in got]
            detail = ", ".join(
                ([f"gained {add}"] if add else []) + ([f"lost {gone}"] if gone else [])
            )
            bad.append(f"{key}: manifest says {got}, plugins.rs expects {want} ({detail})")
        else:
            print(f"agree  {key}: {got}")

    # Default-include: params with no entry are the shape nobody would notice.
    for key, path in sorted(on_disk.items()):
        if key in table:
            continue
        got = declared(path)
        if got:
            bad.append(
                f"{key}: declares {got} and is in no expectation at all -- add "
                f"it to `the_shipped_manifests_declare_the_parameters_they_declare`"
            )
        else:
            print(f"absent {key}: declares no parameters, so no entry is needed")

    if bad:
        print("\n" + "\n".join(f"MISMATCH  {b}" for b in bad))
        print(
            f"\n{len(bad)} disagreement(s). The Windows test asserts this too, "
            f"but it cannot run on the machine most likely to break it."
        )
        return 1
    print("\nthe manifests and the expectation agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
