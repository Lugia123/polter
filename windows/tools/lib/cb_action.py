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

**This is a module and only a module.** It lives in `lib/` rather than next
to the gates because everything directly in `windows/tools/` is a gate: the
loops that run "all the gates" glob `*.py` there, and so does
`gates-fail-on-empty.py`. When this file sat among them as `_cb_action.py`, a
loop that skipped `_*` and the meta-gate that did not counted two different
sets, and its self-check crashed on an empty tree instead of refusing. The
check that the walk still finds arms is `cb-action-arms-are-found.py`, and
`every-script-here-is-a-gate.py` keeps the two roles from sharing a file
again.
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
