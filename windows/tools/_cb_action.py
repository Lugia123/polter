"""The arms of `cb_action`, read once.

**Two gates ask questions about these arms and neither should parse them
itself.** `menu-actions-handled.py` asks which `ACTION_*` constants have a
branch; `action-arms-act.py` asks whether a branch that answers `true`
actually does anything. Those are different questions about the same text, and
a second walker would be a second reader of one fact -- the shape this
repository has opened three tasks about.

The walk is the one `menu-actions-handled.py` had, moved here unchanged in
behaviour and widened to hand back the arm's body as well as its pattern. It
is a brace/paren walk rather than a regex because the spellings vary in ways
that each cost a wrong answer when guessed: `ffi::ACTION_X` and bare
`ACTION_X` both appear, or-patterns put two names on one arm, and arm bodies
mention `ACTION_` constants of their own that a body-wide search would collect.
"""

import re


def _match_body(main_src: str):
    """The text inside `match action.tag { ... }`, and where it starts."""
    at = main_src.index('extern "C" fn cb_action')
    m = main_src.index("match action.tag {", at)
    open_brace = main_src.index("{", m)
    depth, k = 0, open_brace
    while k < len(main_src):
        if main_src[k] == "{":
            depth += 1
        elif main_src[k] == "}":
            depth -= 1
            if depth == 0:
                break
        k += 1
    return main_src[open_brace + 1 : k], open_brace + 1


def arms(main_src: str):
    """Yield `(pattern, body, line)` for every arm of `cb_action`.

    `line` is 1-based in the whole file, pointing at the `=>`, so a report can
    send somebody straight to it.
    """
    body, offset = _match_body(main_src)

    depth = 0
    pattern_start = 0
    arrow = None
    pat = ""
    i = 0
    while i < len(body):
        c = body[i]
        if c in "{([":
            depth += 1
        elif c in "})]":
            depth -= 1
            if depth == 0:
                # An arm body that was a block just ended.
                if arrow is not None:
                    yield pat, body[arrow:i + 1], line_of(main_src, offset + arrow)
                    arrow = None
                pattern_start = i + 1
        elif c == "," and depth == 0:
            # An arm body that was an expression just ended.
            if arrow is not None:
                yield pat, body[arrow:i], line_of(main_src, offset + arrow)
                arrow = None
            pattern_start = i + 1
        elif body[i : i + 2] == "=>" and depth == 0:
            pat = body[pattern_start:i]
            arrow = i + 2
            i += 1
        i += 1

    if arrow is not None:
        yield pat, body[arrow:], line_of(main_src, offset + arrow)


def line_of(src: str, pos: int) -> int:
    return src.count("\n", 0, pos) + 1




def tags_of(pattern: str):
    """The `ACTION_*` constants an arm's pattern names."""
    return re.findall(r"\bACTION_[A-Z0-9_]+", pattern)


if __name__ == "__main__":
    # **This file is in `windows/tools/*.py` and will be run by the loop that
    # runs the gates, so it must not be a silent zero.** A helper that prints
    # nothing and exits 0 is indistinguishable from a gate that passes, which
    # is the shape this directory keeps finding.
    #
    # So when run directly it does the one useful thing it can: prove the walk
    # still finds arms. **Both gates that import it go quiet in the same way
    # if this breaks** -- `menu-actions-handled.py` would report zero arms and
    # conclude every menu row is fine, and `action-arms-act.py` would report
    # no lying arms. Two green reports, one broken parser.
    import os
    import sys

    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "..", "host", "src", "main.rs"), encoding="utf-8") as fh:
        src = fh.read()

    all_arms = list(arms(src))
    named = [a for a in all_arms if tags_of(a[0])]

    print("not a gate: the shared reading of `cb_action`'s arms, used by "
          "menu-actions-handled.py and action-arms-act.py")
    print(f"  parsed {len(all_arms)} arm(s), {len(named)} of them naming ACTION_* constants")

    if len(named) < 10:
        print()
        print("FAIL: that is too few to be real. The walk has stopped matching the "
              "source, and **both gates that use it would report clean** -- one "
              "finding no unhandled menu rows, the other no lying arms.")
        sys.exit(1)
