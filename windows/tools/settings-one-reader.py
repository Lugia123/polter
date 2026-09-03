#!/usr/bin/env python3
"""Two readers of the **settings file**, disagreeing about it.

**This checker is about `settings.json` and nothing else.** It was called
`one-reader-per-fact.py`, and that name promised something it has never
delivered: it reads as "every fact in this tree has one reader", and it is
green whatever any other fact does. A green light that says more than it
checked is the kind that gets quoted as "already ruled out" -- so the name
now says the subject, and the boundary below says the rest.

**Three times on one page, and the same shape each time.** The plugin settings
page showed a plugin as off with empty fields while the core ran it from the
values a release shipped; it showed a ticked box for a `{"flag": true}` the
core had already discarded; it showed English where the plugin carried a
translation. None of them was "the page read the wrong file". Every one was
**two readers of the same file that understood it differently** -- and each
time the page was the more convincing of the two and the wrong one.

**So this checks the number of readers, not correctness.** Whether the rule is
right is a question about requirements and it changes; how many places
implement it is a question about the code and it should not. A checker that
tried to compare the page's understanding with the core's would be asserting a
semantic property it cannot see, and it would say so in neither direction.

Three facts, one reader each:

  1. **Which bytes.** Settings files are read in exactly one function, and
     that function has exactly one caller.
  2. **What counts as a value.** The rule that a non-string is not a value
     lives inside that one reader's parse, which likewise has one caller.
  3. **Which file, in what order.** The user's file before the shipped one is
     decided in one place, and the writer's single path is not a second
     opinion about it.

WHAT THIS DOES NOT CHECK
------------------------

**The most useful half of a checker's documentation is its edge**, because a
reader who knows what it covers still has to guess at what it does not, and
the guess is generous every time.

- **Any fact other than the settings file.** The scan is textual and matches
  on `settings_path` and `settings.json`; a source file containing neither is
  invisible to it no matter how many readers its own facts have.

  The case that named this boundary: **"how many terminal windows exist" had
  two holders and they disagreed.** `tabs::Registry` counted down to 0 while
  `winid::FRAMES` still said 1 -- and they disagreed *at the moment the
  number was used to decide something*, which is the only moment that
  matters: the count is what "the last window closed, so quit" reads, so the
  process kept running with no windows on screen. This checker was green
  throughout, correctly: `winid.rs` and `tabs.rs` do not contain a single
  token it looks for. Fixing `winid::of` made the two agree again, but
  **nothing decided which of them owns that fact** -- today they agree because
  they happen to stay in step, which is the state this checker exists to
  refuse for `settings.json` and does not police anywhere else.

- **A read whose path was computed a few lines earlier into a local with an
  innocent name.** The check follows the words, so a reader that launders the
  path through `let p = ...;` three statements up is invisible. That is why
  it prints how many reads it looked at, not only how many it objected to.

- **Whether the one reader is right.** See above: it counts readers.

Exit: 0 when no settings fact has a second reader, 1 otherwise.
"""

import glob
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host", "src")

# The one function allowed to read a settings file, and the one allowed to
# decide what its values mean. **Not a list of exceptions**: these are the
# names of the single readers, and the point of the check is that no second
# name joins them.
THE_READER = "read_first"
THE_PARSE = "parse_settings"
THE_ORDER = "read_settings"
THE_WRITER = "save"

SETTINGS_WORDS = ("settings_path", "settings.json")


def enclosing_fn(src: str, at: int) -> str:
    """The name of the function the offset sits in, or `""`."""
    head = src[:at]
    hits = list(re.finditer(r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)", head))
    return hits[-1].group(1) if hits else ""


def body(src: str) -> str:
    """Everything above the file's own tests, with comments blanked.

    A test may legitimately call the reader directly; that is what a test of a
    reader looks like. **And a comment that names the reader is not a second
    reader** -- the first version of this tool counted the sentence explaining
    `read_first` as a caller of it, which is the same class of mistake the
    tool exists to catch: reading words and calling them code.
    """
    src = src.split("#[cfg(test)]")[0]
    out = []
    for line in src.split("\n"):
        cut = line.find("//")
        out.append(line[:cut] if cut >= 0 else line)
    return "\n".join(out)


def line_of(src: str, at: int) -> int:
    return src[:at].count("\n") + 1


def scan():
    reads = 0
    hits = []
    callers = {THE_READER: [], THE_PARSE: []}
    order_sites = []
    path_sites = []

    for path in sorted(glob.glob(os.path.join(ROOT, "*.rs"))):
        name = os.path.basename(path)
        with open(path, encoding="utf-8") as fh:
            src = body(fh.read())

        # 1. every file read, and which of them are settings reads
        for m in re.finditer(r"read_to_string\s*\(([^;]{0,120})", src):
            reads += 1
            arg = m.group(1)
            if not any(w in arg for w in SETTINGS_WORDS):
                continue
            fn = enclosing_fn(src, m.start())
            if fn != THE_READER:
                hits.append((name, line_of(src, m.start()), fn,
                             f"reads a settings file outside `{THE_READER}`"))

        # 2/3. who calls the one reader and the one parse
        for target in (THE_READER, THE_PARSE):
            for m in re.finditer(r"\b%s\s*\(" % target, src):
                # **A definition is not a call**, and `enclosing_fn` cannot
                # tell: at `fn read_first(`, the name it walks back to is the
                # function *above*. Counted that way, every reader looked like
                # it had two callers -- a number that was wrong in the
                # direction that reads as suspicious rather than as clean,
                # which is the only reason it was noticed.
                if re.search(r"\bfn\s+$", src[: m.start()]):
                    continue
                callers[target].append((name, line_of(src, m.start()), enclosing_fn(src, m.start())))

        # 3. which file, in what order
        for m in re.finditer(r'"settings\.json"', src):
            order_sites.append((name, line_of(src, m.start()), enclosing_fn(src, m.start())))
        for m in re.finditer(r"\bsettings_path\s*\(", src):
            # Its own definition is not a use of it.
            if re.search(r"\bfn\s+$", src[: m.start()]):
                continue
            path_sites.append((name, line_of(src, m.start()), enclosing_fn(src, m.start())))

    for target, allowed in ((THE_READER, THE_ORDER), (THE_PARSE, THE_READER)):
        for name, line, fn in callers[target]:
            if fn != allowed:
                hits.append((name, line, fn,
                             f"calls `{target}`, which only `{allowed}` may call"))

    for name, line, fn in order_sites:
        if fn != THE_ORDER:
            hits.append((name, line, fn,
                         f"names the shipped settings file outside `{THE_ORDER}`"))

    for name, line, fn in path_sites:
        if fn not in (THE_ORDER, THE_WRITER):
            hits.append((name, line, fn,
                         f"uses the user's settings path outside `{THE_ORDER}` (read) "
                         f"and `{THE_WRITER}` (write)"))

    return reads, hits, callers, order_sites, path_sites


# --------------------------------------------------------------- self-test
#
# Both directions. A probe that stopped matching would report nothing and read
# exactly like a tree with one reader per fact.
CANARY_OK = '''
fn read_settings(key: &str, dir: &Path) -> (bool, Map) {
    let mut paths: Vec<PathBuf> = Vec::new();
    if let Some(p) = settings_path(key) { paths.push(p); }
    paths.push(dir.join("settings.json"));
    read_first(key, &paths)
}
fn read_first(key: &str, paths: &[PathBuf]) -> (bool, Map) {
    for path in paths {
        let Ok(text) = std::fs::read_to_string(path) else { continue };
        return parse_settings(key, &text);
    }
    (false, Map::new())
}
fn parse_settings(key: &str, text: &str) -> (bool, Map) { todo!() }
fn save(key: &str) { let _ = settings_path(key); }
'''

CANARY_BAD = '''
fn somewhere_else(key: &str) -> bool {
    let p = settings_path(key).unwrap();
    let text = std::fs::read_to_string(&p).unwrap();
    text.contains("enabled")
}
'''


def check_text(src: str):
    """The scan above, over one string, for the canaries."""
    out = []
    for m in re.finditer(r"read_to_string\s*\(([^;]{0,120})", src):
        if any(w in m.group(1) for w in SETTINGS_WORDS):
            fn = enclosing_fn(src, m.start())
            if fn != THE_READER:
                out.append((line_of(src, m.start()), fn))
    for m in re.finditer(r"\bsettings_path\s*\(", src):
        if re.search(r"\bfn\s+$", src[: m.start()]):
            continue
        fn = enclosing_fn(src, m.start())
        if fn not in (THE_ORDER, THE_WRITER):
            out.append((line_of(src, m.start()), fn))
    return out


CANARY_DEFINITION = '''
fn read_first(key: &str, paths: &[PathBuf]) -> (bool, Map) { todo!() }
'''


def self_test() -> None:
    # A definition must not be counted as a call: the count is the whole
    # reading, and one that inflates by one per definition is a count nobody
    # can act on.
    defs = [m for m in re.finditer(r"\bread_first\s*\(", CANARY_DEFINITION)
            if not re.search(r"\bfn\s+$", CANARY_DEFINITION[: m.start()])]
    if defs:
        print("FAIL: a definition is being counted as a call.")
        sys.exit(1)
    if check_text(CANARY_OK):
        print(f"FAIL: the probe objects to code that already has one reader: {check_text(CANARY_OK)}")
        sys.exit(1)
    bad = check_text(CANARY_BAD)
    if not bad:
        print("FAIL: the probe cannot see a second reader of the settings file.")
        sys.exit(1)
    if not any(fn == "somewhere_else" for _, fn in bad):
        print(f"FAIL: the probe saw a second reader but not which function: {bad}")
        sys.exit(1)
    print("probe self-test: OK (one-reader code passes, a second reader is seen and named)")


def main() -> int:
    self_test()

    # **A gate that scanned nothing exits 0 and reads as green.**
    # Measured, not assumed: pointed at a tree where `windows/host/src/` is
    # empty, this gate printed `looked at 0 file reads` and then
    # `one reader per fact`, and returned 0. The count was already on the
    # screen -- nothing acted on it, and "the reading exists and nobody looked
    # at it" is the same failure the gate itself is about.
    #
    # `ps1-parses.py` is the model: `if not scripts: FAIL; sys.exit(1)`.
    # The subject set, not the hit count, is what has to be non-empty --
    # zero hits is a real pass, zero files is not an answer.
    sources = sorted(glob.glob(os.path.join(ROOT, "*.rs")))
    if not sources:
        print(f"FAIL: no .rs file under {ROOT}; this gate is looking in the "
              f"wrong place. **It did not find a clean tree -- it found "
              f"nothing to look at, and those two exit the same way unless "
              f"this line exists.**")
        return 1

    reads, hits, callers, order_sites, path_sites = scan()
    print(f"scanned {len(sources)} file(s)")

    print(
        f"looked at {reads} file reads; "
        f"`{THE_READER}` has {len(callers[THE_READER])} caller(s), "
        f"`{THE_PARSE}` has {len(callers[THE_PARSE])}; "
        f"the shipped file is named in {len(order_sites)} place(s); "
        f"the user's path is used in {len(path_sites)}"
    )

    for name, line, fn, why in hits:
        where = f"in `{fn}`" if fn else "at file scope"
        print(f"HIT    {name}:{line}  {where} {why}")

    if hits:
        print(
            f"\n{len(hits)} second reader(s). **Not a wrong answer -- a second answer.** "
            f"Two readers of one file disagree eventually, and the page is the one people "
            f"believe."
        )
        return 1
    print("one reader per fact")
    return 0


if __name__ == "__main__":
    sys.exit(main())
