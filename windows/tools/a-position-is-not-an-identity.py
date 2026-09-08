#!/usr/bin/env python3
"""Where an element sits is not what an element is.

**Twice now in this repository**, and both times the tree looked correct while
the answer was somebody else's element:

  * `081bc0546` -- a window *number* that was really a position in `FRAMES`.
    Close a window and the next one to open inherited the number, so a
    runtime id a client had written down came to mean a different window.
  * task 331 -- a UIA `Navigate` arm that computed its own sibling position
    as "the tab's index, plus one for the tab list". That was a correct
    position for exactly as long as every tab contributed one document; the
    first split made it name the neighbour.

**The second occurrence is what makes this a rule rather than an accident.**
And the thing worth gating is not the wrong number -- it is the *shape*: a
position worked out by arithmetic, in a method whose whole job is to hand back
the element next to this one.

# The rule

Inside a `Navigate` in `uia.rs`, an index may not be written as an integer.
Not `+ 1`, not a bare `0`, not `- 1`. If a position is computed at all, it is
computed by **finding this element in a list of identities**.

That is the alternative, and it is why the rule is not merely a prohibition:

    fn root_children_ided(frame) -> Vec<(RootChild, Fragment)>   // id + element
    step_among_root_children(frame, RootChild::Document(tab, pane), direction)

-- one function produces the children *with their identities*, the arm asks
where **it** is in that list, and both come out of a **single snapshot**. The
last part is not decoration: two snapshots a moment apart, with a pane closing
in between, turn a correct index back into the neighbour's element.

**Without the alternative spelled out, this gate teaches the wrong lesson.**
The natural response to "your `+ 1` is wrong" is `+ 2`, which is the same
defect one element later.

# Comments are stripped, and that is load-bearing here

The repair for 331 quotes the arithmetic it removed, in a comment, so that the
next reader knows what used to stand there. A checker that matched raw text
would fire on the repair -- **the fifth time in this repository that a checker
read a comment as code**. So the subject is the code, and the comments come
out first. `strip_comments` keeps the newlines, so line numbers still point at
the file.

# NOT CHECKED, and the first one is most of the family

  * ⚠️ **whether "find yourself by identity" is done correctly.** This reads
    text. It cannot see that the identity list and the element list come from
    one snapshot, cannot see a pane closing between two of them, and cannot
    see an identity that fails to distinguish two elements. **A green here is
    "no arithmetic position in a `Navigate`", not "this family is gone."**
  * everything outside `uia.rs`, and inside it everything that is not a
    `Navigate`. The same shape in a hit test or a property arm is out of
    scope on purpose: a gate wide enough to catch every index in the port
    would fire on every correct one, and a gate people cannot live with gets
    widened until it means nothing.
  * the reverse direction: an index built from a *variable* that is itself a
    position is invisible here. `let i = idx_of_tab; step(kids, i, dir)`
    passes.

Run:  python3 windows/tools/a-position-is-not-an-identity.py
Exit: 0 when no `Navigate` in `uia.rs` works out a position by arithmetic.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
UIA = os.path.normpath(os.path.join(HERE, "..", "host", "src", "uia.rs"))

# An integer standing alone: `1`, `0`. Not `0x…`, not `f.0`, not `u64`.
LITERAL = re.compile(r"(?<![\w.])\d+(?![\w.])")

# The places a position is spent. Anything else is not an index.
INDEXERS = ("step(", ".get(", ".nth(", ".skip(", ".take(")

ALTERNATIVE = (
    "compute the position by identity instead: have the function that builds "
    "the children hand back `(identity, element)` pairs and ask where *this* "
    "element is in that one list -- `step_among_root_children(frame, "
    "RootChild::Document(tab, pane), direction)`. One snapshot, no arithmetic."
)


def strip_comments(text: str) -> str:
    """Comments out, newlines kept so line numbers still point at the file.

    Load-bearing: the repair this gate protects quotes the arithmetic it
    removed, in a comment. Matching raw text would report the fix as the
    defect, which this repository has now done four times.
    """
    return re.sub(r"//[^\n]*", "", text)


def args_of(src: str, start: int):
    """The top-level arguments of the call whose `(` is at `start`."""
    depth, k, out, cur = 0, start, [], ""
    while k < len(src):
        c = src[k]
        if c in "([{":
            depth += 1
            if depth == 1:
                k += 1
                continue
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                out.append(cur)
                return out
        if depth == 1 and c == ",":
            out.append(cur)
            cur = ""
        else:
            cur += c
        k += 1
    return out


def navigate_bodies(src: str):
    """`(line, body)` for every `fn Navigate`, by brace matching."""
    for m in re.finditer(r"fn Navigate\s*\(", src):
        brace = src.find("{", m.end() - 1)
        if brace < 0:
            continue
        depth, k = 0, brace
        while k < len(src):
            if src[k] == "{":
                depth += 1
            elif src[k] == "}":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        yield src.count("\n", 0, m.start()) + 1, brace, src[brace : k + 1]


def analyse(src: str):
    """Returns (problems, navigates, indexers) -- the last two are the guard."""
    clean = strip_comments(src)
    bad, navigates, indexers = [], 0, 0
    for line, off, body in navigate_bodies(clean):
        navigates += 1
        for name in INDEXERS:
            for m in re.finditer(re.escape(name), body):
                args = args_of(body, m.end() - 1)
                # `step(items, idx, direction)` spends its *second* argument
                # as the position; the one-argument forms spend their first.
                spent = args[1:2] if name == "step(" else args[:1]
                for a in spent:
                    indexers += 1
                    if not LITERAL.search(a):
                        continue
                    at = line + body.count("\n", 0, m.start())
                    bad.append(
                        f"uia.rs:{at}: this `Navigate` works out a position "
                        f"with a number -- the index spent at `{name}…)` is "
                        f"`{a.strip()}`. A position "
                        "is right only for the arrangement it was derived in: "
                        "`t + 1` was correct until a tab held two documents, "
                        "and then it named the neighbour while the tree still "
                        f"looked right. Do not correct the arithmetic -- {ALTERNATIVE}")
    return bad, navigates, indexers


# -- self-test ---------------------------------------------------------------

def nav(inner: str) -> str:
    return ("fn Navigate(&self, direction: NavigateDirection) -> WResult<Frag> {\n"
            "    match direction {\n" + inner + "\n    }\n}\n")


ARITHMETIC = nav("        step(root_children(frame), t + 1, direction)")
CONSTANT = nav("        step(root_children(frame), 0, direction)")
BY_IDENTITY = nav("        step_among_root_children(frame, RootChild::TabList, direction)")
FROM_POSITION_LOOKUP = nav(
    "        let Some(idx) = kids.iter().position(|(k, _)| *k == me) else { return Err(gone()) };\n"
    "        step(items, idx, direction)")
IN_A_COMMENT = nav(
    "        // what stood here was `step(root_children(frame), t + 1, direction)`\n"
    "        step_among_root_children(frame, RootChild::TabList, direction)")
# **The reverse control.** The same arithmetic somewhere that is not a
# `Navigate` must pass: this gate is narrow on purpose, and a gate that fires
# on every index in the file is one that gets widened until it means nothing.
NOT_NAVIGATE = ("fn strip_height(&self) -> u32 {\n"
                "    let rows = self.rows.get(n + 1);\n"
                "    rows.unwrap_or(0)\n"
                "}\n")
# A `Navigate` that spends no index at all is not evidence of anything; the
# guard below is what keeps that from reading as a pass.
NO_INDEX = nav("        Ok(WindowRoot { frame: self.frame }.into())")

for sample, want_red, label in (
    (ARITHMETIC, True, "the 331 shape: a sibling position as `the tab's index + 1`"),
    (CONSTANT, True, "a hard-coded position -- a second copy of where an element sits"),
    (BY_IDENTITY, False, "the alternative: the element found by identity"),
    (FROM_POSITION_LOOKUP, False,
     "an index that came out of a `position` lookup rather than a sum"),
    (IN_A_COMMENT, False,
     "the arithmetic quoted in a comment by the repair that removed it -- "
     "four checkers in this repository have reported the fix as the defect"),
    (NOT_NAVIGATE, False,
     "the same arithmetic outside a `Navigate`, which is deliberately out of "
     "scope"),
    (NO_INDEX, False, "a `Navigate` that spends no index"),
):
    got = bool(analyse(sample)[0])
    if got != want_red:
        print(f"FAIL: the probe {'misses' if want_red else 'fires on'} {label}.")
        sys.exit(1)

if analyse(ARITHMETIC)[1] != 1 or analyse(ARITHMETIC)[2] != 1:
    print("FAIL: the probe does not count the methods and the indexes it "
          "looked at, so its silence cannot be told from having read nothing.")
    sys.exit(1)

# -- the tree ----------------------------------------------------------------

src = open(UIA, encoding="utf-8").read() if os.path.isfile(UIA) else ""
problems, navigates, indexers = analyse(src)
print(f"read uia.rs ({len(src)} bytes); {navigates} Navigate method(s), "
      f"{indexers} index(es) spent in them")

# **Subject-set guard.** Zero `Navigate` methods is not a clean provider, it
# is a gate that read nothing -- and it prints the same all-clear either way.
# The index count is *not* part of the guard: a file whose every arm found
# itself by identity would legitimately spend no index, and requiring one
# would make the finished state fail.
if not src or navigates == 0:
    print()
    print("FAIL: uia.rs was not read, or it has no Navigate method. There was "
          "nothing to check. Not a pass.")
    sys.exit(1)

if not problems:
    print("OK: no Navigate works out a position by arithmetic.")
    print("NOT CHECKED: whether finding-by-identity is done right -- the "
          "single-snapshot part especially. This reads text; a green here "
          "means no arithmetic position, not that the family is gone.")
    sys.exit(0)

print()
for line in problems:
    print("  " + line)
print()
print(f"FAIL: {len(problems)} position(s) worked out by arithmetic.")
sys.exit(1)
