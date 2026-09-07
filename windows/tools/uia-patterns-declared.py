#!/usr/bin/env python3
"""A UI Automation provider that offers no pattern is read-only. Say so.

**What this is for.** `uia.rs` publishes a tree of providers. A client that
finds an element can *read* it from `GetPropertyValue` no matter what; what
decides whether the client can **act** on it is `GetPatternProvider`. A
provider that answers `Err(gone())` to every pattern is an element you can see
and cannot touch -- and the client's only remaining move is to synthesise a
click at a coordinate, which is the thing this tree exists to replace.

**The failure this catches is silence.** A provider with no pattern is not an
error at any level: it compiles, the element appears in the tree with a name
and a control type, and an automation dump of it looks healthy. The only way
to find out is to try to press it, on a real machine, with a real client. That
round trip is the expensive one this port keeps paying.

So: **every provider is in scope by default**, and one that offers no pattern
has to say why, next to the code, in the form

    // no pattern: <why this element is read-only>

Nothing here says the patterns offered are the *right* ones, and nothing here
can say whether they work -- **UI Automation cannot be exercised on the
machine this port is written on at all.** This gate answers one question,
"does every element in the tree either offer a way to act on it or explain why
not", and it answers it where the code is written rather than after a real
machine has been booked.

Run:  python3 windows/tools/uia-patterns-declared.py
Exit: 0 when every provider offers a pattern or carries a written reason.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "host", "src"))

REASON = re.compile(r"//\s*no pattern:\s*(\S.*)")


def without_comments(text: str) -> str:
    """The text with `//` comments blanked, newlines kept.

    ⚠️ **This checker reads text, so prose that names a symbol is read as the
    symbol.** The comment this gate exists to encourage --

        // `SelectionItemPattern` belongs here and is not implemented

    -- names a pattern, and without this pass it counted as *offering* one:
    the provider it was apologising for would have passed. The same trap has
    now been hit three times in `windows/tools` (twice while writing the
    checkers themselves), which is why the blanking is a named function rather
    than an inline `re.sub` somebody can miss.
    """
    return re.sub(r"//[^\n]*", "", text)
# `if id == UIA_<something>PatternId` is how a pattern is offered. The `_id`
# spelling in the signature is a hint and not the rule: what counts is whether
# any pattern id is compared at all.
OFFER = re.compile(r"\bUIA_(\w+)PatternId\b")


def providers(src: str):
    """`(name, body, line)` for every `GetPatternProvider` in the file."""
    out = []
    for m in re.finditer(
        r"impl\s+IRawElementProviderSimple_Impl\s+for\s+(\w+)_Impl\s*\{", src
    ):
        name = m.group(1)
        # The body of that impl block, by brace depth.
        i, depth = m.end() - 1, 0
        while i < len(src):
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        block = src[m.end() : i]
        g = re.search(r"fn GetPatternProvider\s*\([^)]*\)[^{]*\{", block)
        if not g:
            out.append((name, None, src[: m.start()].count("\n") + 1))
            continue
        j, d = g.end() - 1, 0
        while j < len(block):
            if block[j] == "{":
                d += 1
            elif block[j] == "}":
                d -= 1
                if d == 0:
                    break
            j += 1
        body = block[g.end() : j]
        line = src[: m.end() + g.start()].count("\n") + 1
        out.append((name, body, line))
    return out


def scan(src: str):
    """`(problems, offering, excused)`."""
    problems, offering, excused = [], [], []
    for name, body, line in providers(src):
        if body is None:
            problems.append(
                f"{name} implements IRawElementProviderSimple with no "
                f"GetPatternProvider at all (line {line})"
            )
            continue
        offers = sorted(set(OFFER.findall(without_comments(body))))
        if offers:
            offering.append(f"{name}: {', '.join(offers)}")
            continue
        reason = REASON.search(body)
        if reason:
            excused.append(f"{name}: {reason.group(1).strip()}")
            continue
        problems.append(
            f"{name} offers no pattern and gives no reason (line {line}). A "
            f"client can read this element and cannot act on it, and nothing "
            f"about that is visible from a tree dump. Offer a pattern, or "
            f"write `// no pattern: <why>` in the body."
        )
    return problems, offering, excused


# -- self-test ---------------------------------------------------------------
#
# **A gate that has never been red and a gate that does not exist look the same
# when green**, so both directions are asserted here, before the tree is read.

CANARY_BARE = '''
impl IRawElementProviderSimple_Impl for Thing_Impl {
    fn ProviderOptions(&self) -> WResult<ProviderOptions> { Ok(x) }
    fn GetPatternProvider(&self, _id: UIA_PATTERN_ID) -> WResult<IUnknown> {
        Err(gone())
    }
}
'''
CANARY_OFFERS = CANARY_BARE.replace(
    "        Err(gone())",
    "        if id == UIA_InvokePatternId { return Ok(p.into()); }\n        Err(gone())",
)
CANARY_EXCUSED = CANARY_BARE.replace(
    "        Err(gone())",
    "        // no pattern: it is a container, and containers are not pressed\n"
    "        Err(gone())",
)
# A comment that merely *names* a pattern must not count as offering one --
# the same trap `_cb_action.py` fell into, where prose was read as code.
CANARY_COMMENT_ONLY = CANARY_BARE.replace(
    "        Err(gone())",
    "        // UIA_InvokePatternId belongs here and is not implemented\n"
    "        Err(gone())",
)


def self_test() -> None:
    if not scan(CANARY_BARE)[0]:
        print("FAIL: a provider offering no pattern and giving no reason was not reported.")
        sys.exit(2)
    if scan(CANARY_OFFERS)[0]:
        print("FAIL: a provider that does offer a pattern was reported anyway.")
        sys.exit(2)
    if scan(CANARY_EXCUSED)[0]:
        print("FAIL: `// no pattern:` did not excuse a read-only provider.")
        sys.exit(2)
    if not scan(CANARY_COMMENT_ONLY)[0]:
        print("FAIL: a comment naming a pattern was read as offering it. Prose is "
              "not code, and this checker reads text.")
        sys.exit(2)
    print("probe self-test: OK (bare, offering, excused, and comment-only are told apart)")


def main() -> int:
    self_test()
    path = os.path.join(SRC, "uia.rs")
    src = open(path, encoding="utf-8").read()
    problems, offering, excused = scan(src)

    print(f"scanned {len(providers(src))} provider(s) in uia.rs")
    for o in offering:
        print(f"  acts:   {o}")
    for e in excused:
        print(f"  reads:  {e}")
    print("NOT CHECKED: whether the patterns offered are the right ones, and "
          "whether any of them work. UI Automation cannot be exercised on the "
          "machine this port is written on -- only a real client on a real "
          "machine can say that a tab actually activates.")

    if problems:
        print()
        for p in problems:
            print(f"FAIL: {p}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
