#!/usr/bin/env python3
"""`ghostty_cli_try_action` is called once, and only behind the one predicate.

# The defect this is the floor for, and it has already happened once

The host has to answer "does this command line ask for a CLI action?" **before**
`ghostty_init` -- and it used to answer it with its own rule,
`args.skip(1).any(|a| a.starts_with('+'))`. The core's rule is not that:
`--help` and `-h` fall back to `+help`, `--version` is `+version` outright, and
`-e` cuts the search off. So `polter-cli.exe --help` was a line the core would
have run `help` for, the host's guard was false, `ghostty_cli_try_action` was
never called, and the run went on to load the API, make a frame, make a tab,
spawn a shell and enter the message loop.

**`--help` started a full resident instance, and nothing said so.** The symptom
is a window appearing, not an error; `--help` is an argument a reader assumes
is only a question, and the assumption was the reader's, not the program's.

Task 238 moved the rule into `windows/cliargs`, where it has tests that run on
the machine the port is written on. **It said in so many words what it did not
do:** "I did not add a gate to pin that the `cli_try_action` call site is
guarded by this one predicate. It holds today by reading, not by a checker."
This is that gate.

# Three decisions ride on this one predicate, not one

    main.rs  owns_the_log()          a CLI action must not delete the GUI
                                     instance's pinned log file
    main.rs  the GHOSTTY_LOG branch  a CLI action is a TUI and owns stderr;
                                     logging there scribbles over it
    main.rs  the dispatch            whether to hand over to the core at all

So a second, divergent rule in the host does not just misroute the dispatch --
it silently moves where the log goes. That is why the check below is not only
"is the call guarded" but "is there one rule".

# What is checked

  R1  exactly one call to `cli_try_action` in the host
  R2  it sits inside a branch guarded by `cli_action_requested()`
  R3  `cli_action_in` decides nothing itself -- it hands straight to
      `polter_cliargs::asks_for_a_cli_action`

# NOT CHECKED, and the first one is the bigger question

  * **Whether the host's rule agrees with the core's.** This pins that there
    is *one* rule and that it is used in the right places; whether that one is
    a correct mirror of `cli/action.zig`'s `detectIter` is the `cliargs`
    crate's own tests, and **those are a mirror somebody wrote by hand** -- the
    core can change `detectIter` and nothing here or there turns red. "One
    rule" and "the right rule" are different properties and this gate only has
    the first.
  * **The two deliberate divergences are not defects and this says nothing
    about them.** `cliargs`'s header records both: `argv[0]` is skipped here
    and walked by the core, and `+a +b` / `+nonsense` are reported as actions
    here while the core turns them into a `DetectError`. Both are written down
    with their reasons. A checker that flagged them would be arguing with a
    decision rather than guarding it.
  * **It reads text.** A call reached through an alias, a function pointer
    stored elsewhere, or a macro would not be seen.

Run:  python3 windows/tools/one-rule-for-a-cli-action.py
Exit: 0 when there is one call, one guard, and one rule.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, "..", "host", "src", "main.rs")

GUARD = "cli_action_requested()"
RULE = "polter_cliargs::asks_for_a_cli_action"


def strip_tests(src):
    """The file with **each** of its `#[cfg(test)]` modules cut out.

    The tests call the predicate on purpose and assert on both answers; a
    checker that counted them would report its own subject's coverage as a
    defect.

    ⚠️ **Not "everything above the first one", which is what this did first.**
    `main.rs` has six test modules interleaved with real code and the first is
    at line 190 of 6174 -- so that version threw away 97% of the file,
    including the dispatch this gate exists to look at. It did not report a
    wrong answer only because the "nothing asks the predicate" guard below
    fired first and stopped the run. **A guard catching the consequence of a
    broken parse is luck, not coverage**, and on a tree where the predicate
    happened to be mentioned early it would have reported "`cli_try_action` is
    called 0 times" -- a true statement about a body this had mutilated.
    """
    out, i = [], 0
    for start, end in test_spans(src):
        out.append(src[i:start])
        i = end
    out.append(src[i:])
    return "".join(out)


def test_spans(src):
    """`(start, end)` of every `#[cfg(test)]` module, in order.

    Kept separate from the strip so that **line numbers can be reported
    against the real file**. Counting newlines in the stripped text gives
    numbers that are smaller than the truth and point at other code -- a
    reader who opens `main.rs` at the line this printed finds something
    unrelated, and the report is worse than one with no line numbers at all.
    """
    spans, i = [], 0
    while True:
        at = src.find("#[cfg(test)]", i)
        if at < 0:
            return spans
        brace = src.find("{", at)
        if brace < 0:
            return spans
        depth, k = 0, brace
        while k < len(src):
            if src[k] == "{":
                depth += 1
            elif src[k] == "}":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        spans.append((at, k + 1))
        i = k + 1


def body_of(src, sig):
    """The `{...}` of the function whose signature line contains `sig`."""
    at = src.find(sig)
    if at < 0:
        return None
    open_brace = src.find("{", at)
    if open_brace < 0:
        return None
    depth, i = 0, open_brace
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[open_brace + 1 : i]
        i += 1
    return None


def enclosing_condition(src, at):
    """The nearest enclosing `if <cond> {` around offset `at`, or None.

    **Blocks that are not `if` are walked through, not reported.** The call
    sits inside `unsafe { ... }` inside the `if`, and a version of this that
    stopped at the first `{` answered `unsafe` -- which is a true statement
    about the text and the wrong answer to the question, so it failed the good
    shape and would have failed every correct tree.

    The walk stops at the enclosing function: an `if` outside the function this
    call is in is not its guard, and reporting one would be worse than
    reporting none.
    """
    depth, i = 0, at
    while i > 0:
        i -= 1
        c = src[i]
        if c == "}":
            depth += 1
        elif c == "{":
            if depth == 0:
                line_start = src.rfind("\n", 0, i) + 1
                head = src[line_start:i].strip()
                m = re.match(r"^if\s+(.*?)\s*$", head)
                if m:
                    return m.group(1)
                if head.startswith("fn ") or " fn " in head:
                    return None
                # `unsafe`, a bare block, a `match` arm: keep going outward.
                continue
            depth -= 1
    return None


def findings(src):
    out = []
    body = strip_tests(src)

    # R1 -- the call, not the binding. `sym!(internal, "ghostty_cli_try_action")`
    # and the struct field are the other two mentions and are not calls.
    calls = [m.start() for m in re.finditer(r"\.\s*cli_try_action\s*\)\s*\(", body)]
    if len(calls) != 1:
        out.append(
            f"`cli_try_action` is called {len(calls)} time(s); there must be exactly one. "
            "A second call site is a second answer to \"is this a CLI action\", and the "
            "answer decides where the log goes as well as what runs"
        )
        # Without exactly one there is nothing to ask R2 about.
        return out

    # R2 -- and the guard is named, not merely present somewhere above.
    cond = enclosing_condition(body, calls[0])
    if cond is None:
        out.append(
            "the call to `cli_try_action` is not inside any `if` block. It must be guarded "
            f"by `{GUARD}`; unguarded, every ordinary run hands over to the core"
        )
    elif GUARD not in cond:
        out.append(
            f"the call to `cli_try_action` is guarded by `{cond}`, not by `{GUARD}`. "
            "That is the shape the `--help` defect had: a guard of the host's own that "
            "disagrees with the core, and a `--help` that starts a resident instance"
        )

    # R3 -- one rule, and it is the crate's.
    rule_body = body_of(body, "fn cli_action_in(")
    if rule_body is None:
        out.append(
            "`fn cli_action_in(` was not found. Either it was renamed -- in which case this "
            "gate is looking at nothing and says so rather than passing -- or the host no "
            "longer routes the question through one function"
        )
    else:
        if RULE not in rule_body:
            out.append(
                f"`cli_action_in` does not hand the question to `{RULE}`. The rule lives in "
                "`windows/cliargs` because that is where it can be tested on the machine "
                "this port is written on; a copy here is a second rule that nothing tests"
            )
        # It must *hand over*, not decide. Any branching of its own is the
        # beginning of the second rule.
        for token in ("if ", "match ", "starts_with", "||", "&&"):
            if token in rule_body:
                out.append(
                    f"`cli_action_in` contains `{token.strip()}`: it is deciding, not handing "
                    f"over. Whatever it decides is a rule that `{RULE}`'s tests do not cover"
                )
                break
    return out


GOOD = '''
fn owns_the_log() -> bool { *OWNS.get_or_init(|| !cli_action_requested()) }
fn cli_action_requested() -> bool { cli_action_in(std::env::args()) }
fn cli_action_in(args: impl Iterator<Item = String>) -> bool {
    polter_cliargs::asks_for_a_cli_action(args)
}
fn main() {
    if cli_action_requested() {
        unsafe { (api_box.cli_try_action)() };
    }
}
#[cfg(test)]
mod t { fn x() { unsafe { (api_box.cli_try_action)() }; } }
'''


def self_test():
    """Every shape this can go wrong in, planted and caught.

    The historical defect is one of them, spelled the way it was actually
    written -- **a gate whose floor is a real past failure does not need an
    invented one.**
    """
    cases = [
        ("the shape today", GOOD, 0),
        ("the `--help` defect: the host's own guard",
         GOOD.replace("if cli_action_requested() {",
                      "if std::env::args().skip(1).any(|a| a.starts_with('+')) {"), 1),
        ("a second call site",
         GOOD.replace("fn main() {", "fn other() { unsafe { (api_box.cli_try_action)() }; }\nfn main() {"), 1),
        ("no guard at all",
         GOOD.replace("    if cli_action_requested() {\n        unsafe { (api_box.cli_try_action)() };\n    }\n",
                      "    unsafe { (api_box.cli_try_action)() };\n"), 1),
        ("a second rule in the host",
         GOOD.replace("    polter_cliargs::asks_for_a_cli_action(args)\n",
                      "    if args.count() > 1 { true } else { false }\n"), 2),
        ("the rule renamed away",
         GOOD.replace("fn cli_action_in(", "fn cli_action_gone("), 1),
        # **The strip's own case.** A test module *before* the real code is
        # the shape `main.rs` actually has, and the first version of
        # `strip_tests` truncated at it and threw the program away.
        ("a test module before the code",
         "#[cfg(test)]\nmod early { fn q() { let _ = cli_action_requested(); } }\n" + GOOD, 0),
    ]
    for what, src, want in cases:
        got = len(findings(src))
        if got != want:
            print(f"probe self-test FAILED: {what} gave {got} finding(s), expected {want}:")
            for f in findings(src):
                print(f"    {f}")
            return False
    if findings(GOOD):
        print("probe self-test FAILED: the good shape produced findings")
        return False
    print("probe self-test: OK (the historical --help guard, a second call site, "
          "no guard, a second rule, the rule renamed away)")
    return True


def main():
    if not self_test():
        return 1
    try:
        with open(MAIN, encoding="utf-8") as fh:
            src = fh.read()
    except OSError as e:
        # Missing is a failure, not a skip: a gate that shrugs when its subject
        # is gone stops existing the first time somebody moves a file.
        print(f"cannot read windows/host/src/main.rs: {e}")
        return 1

    body = strip_tests(src)
    # **The floor for the strip, and it is a shape rather than a count.** If
    # the test-module walk eats real code, it eats `fn main` with it -- and a
    # count of what survived would need maintaining every time a test module
    # is added or removed.
    if "fn main(" not in body:
        print("after removing the `#[cfg(test)]` modules there is no `fn main(` left: "
              "the strip ate the program, so every reading below would be of a file that "
              "does not exist")
        return 1
    # **Line numbers against the file somebody will open**, not against the
    # stripped copy this gate reads.
    spans = test_spans(src)
    in_test = lambda at: any(a <= at < b for a, b in spans)
    readers = [
        src[: m.start()].count("\n") + 1
        for m in re.finditer(re.escape(GUARD), src)
        if not in_test(m.start())
        and not src[src.rfind("\n", 0, m.start()) + 1 : m.start()].lstrip().startswith("fn ")
    ]
    print(f"read main.rs: `{GUARD}` is asked at line(s) {', '.join(map(str, readers)) or '(none)'}")
    if not readers:
        print("nothing asks the predicate at all; this gate has no subject and that is a failure")
        return 1

    found = findings(src)
    for f in found:
        print(f"HIT    main.rs  {f}")
    if found:
        print(f"\n{len(found)} problem(s): the CLI-action question is answered in more than "
              "one way, or the answer is not the one guarding the handover.")
        return 1
    print("OK: one call to `cli_try_action`, behind `cli_action_requested()`, "
          "and the rule itself is `windows/cliargs`'s.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
