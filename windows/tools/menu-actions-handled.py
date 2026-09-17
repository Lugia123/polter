#!/usr/bin/env python3
"""Menu rows that name an action nobody handles.

**The defect this is here to stop, as it actually happened.** «文件 ▸ 新建窗口»
was not greyed, it could be clicked, and clicking it did nothing at all --
no window, no error, and **not one line in the log**. The core had parsed the
binding, performed it, and handed `GHOSTTY_ACTION_NEW_WINDOW` to the host;
`cb_action` fell through to `_ => false`, which is silent. Nothing anywhere
was wrong enough to say so.

**Three things it could have been, and they look identical from the chair:**
the menu row names an action that does not exist, the action exists and the
host does not answer it, or the action is answered and did nothing this time.
The first is caught by `assert_actions_exist` in `menu.rs`. The third is a
state, and the self-test's `nothing-to-do (state)` bucket reports it. **This
tool is the second one.**

The rule, which is computed rather than declared:

  * A menu row names an action. If `ffi.rs` declares `ACTION_<NAME>` then the
    core hands that action to the host by that name, so `cb_action` must have
    a branch for it.
  * If it has no branch, the row must be **greyed** -- and greyed *for a
    written reason*: `// greyed: <why>` next to whatever decides it, the same
    shape as `// process-wide:` in the log checker. "Greyed" alone is not
    enough, because greying a row is also how somebody makes this tool go
    quiet.
  * An action with no `ACTION_<NAME>` constant is outside this check: the core
    performs it itself and never asks the host. That number is printed rather
    than left implicit -- **a checker that cannot say how much it does not see
    is indistinguishable from one that sees everything.**

**The other side of the same coin, and the reason it is here.** The rule above
catches "not greyed and does nothing". It does not catch a row that *was*
usable and quietly became greyed: the gate stays green, the person sees a grey
row, and nothing anywhere says why it went grey. So every row that is greyed
**by a decision** -- not by the state of the moment -- must carry the same
`// greyed: <why>` next to whatever decides it. A row greyed **by state**
(there is nothing to reopen yet) is a different thing and is counted
separately: its greyness moves, and a number that moves is a reading.

Exit: 0 if the unreasoned count equals the baseline **and every row of every
      table could be read**, 1 otherwise.

# The third thing it checks, and why it was added

**A checker that stops seeing a row reads exactly like a clean tree.** On
2026-09-14 task 561 wrapped every label in `menu.rs` as `n_("…")` so the msgid
could reach the catalogue. The two regexes that found rows wanted a quote
immediately after the label position; they found `n_(` and **skipped**. The
reading fell from 88 rows scanned / 46 reaching the host / 1 greyed by state to
31 / 15 / 0, and the exit code stayed 0 the whole way -- including the greyed
count, whose whole value is "exactly one row is greyed by state" and which an
empty scan satisfies for free.

So the table reader below does not look for rows that match a shape. It
**accounts for every element of every row table**, and a label it has not been
taught to read is a failure with a name printed beside it. Wrappers are named
in `LABEL_WRAPPERS` with the reason each one is safe; anything else is red.

# What this does NOT check, and which gate does

**"Is there an arm" and "does the arm do anything" are different questions.**
This one finds a menu row naming an action `cb_action` has no branch for --
clicking it does nothing and logs nothing. It says nothing about a branch that
exists, answers `true`, and performs nothing; that is
`action-arms-act.py`, and it exists because a hand-sweep of eighteen such arms
left two behind.

Two gates rather than one because an action can fail either without failing
the other, in both directions. They share one reading of the source
(`_cb_action.py`) so that the arms are parsed once.
"""

import glob
import os
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cb_action  # noqa: E402
import sys

# **Measured, not chosen.** Two classes, counted together because the remedy is
# the same line of text: rows with no `cb_action` branch and no `// greyed:`
# reason, and rows greyed by a decision with no reason. **Zero today**, and it
# got there rather than starting there: the two that were left were both
# `move_tab_to_new_window` -- the strip row greyed by `enabled()`, and the same
# row's action falling through `cb_action` -- and task 272 wired the action and
# ungreyed the row, so both went at once. (The three rows `menu.rs` greys on
# purpose -- `语言…`, `Polter 帮助`, `检查更新…` -- were never
# counted here; they carry `// greyed:` reasons this tool can read.)
#
# Going *up* means somebody added a row that does nothing when clicked, or
# greyed one without saying why. Going *down* is not possible from zero, which
# is the point of getting here: the ratchet stops being a place to park work.
BASELINE_UNREASONED = 0

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host", "src")

GREYED_REASON = re.compile(r"//\s*greyed:\s*(\S.*)$")


def action_shaped(s: str) -> bool:
    return bool(s) and all(c in "abcdefghijklmnopqrstuvwxyz0123456789_:," for c in s)


# ------------------------------------------------------- reading the tables
#
# **Why this is a parser and not a pair of regexes.** It was two regexes, and
# on 2026-09-14 task 561 wrapped every label in `menu.rs` as `n_("…")` so the
# msgid could reach the catalogue. Both regexes wanted a quote immediately
# after the label position, found none, and **skipped the row**. The reading
# went from 88 rows scanned / 46 reaching the host / 1 greyed by state to
# 31 / 15 / 0 -- and the exit code stayed 0 the whole way. Fifty-seven rows
# left this checker's sight and nothing anywhere said so.
#
# So the shape below is not "find rows that look like this". It is **"account
# for every element of every row table, and say so out loud when one cannot be
# read"**. A wrapper this file has not been taught is a failure, not a skip.

#: Calls that wrap a label without changing it. **The value is the reason**,
#: the same bargain `// greyed:` strikes with a greyed row: a name on this list
#: is a promise that the call returns its string argument unchanged, and the
#: reason is where the next person checks that promise.
LABEL_WRAPPERS = {
    "n_": "i18n.rs: marks a msgid for xgettext and returns it unchanged",
    "tr": "i18n.rs: looks the msgid up at run time; the msgid is the fallback",
}


def mask(src: str) -> str:
    """`src` with every string body, char literal and comment blanked out.

    Same length as `src`, so an index into one is an index into the other.
    Depth and comma finding run on the mask; slices are taken from the source.
    """
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            depth = 0
            while i < n:
                if src.startswith("/*", i):
                    depth += 1
                    out[i] = out[i + 1] = " "
                    i += 2
                    continue
                if src.startswith("*/", i):
                    depth -= 1
                    out[i] = out[i + 1] = " "
                    i += 2
                    if depth == 0:
                        break
                    continue
                if src[i] != "\n":
                    out[i] = " "
                i += 1
            continue
        if c == "r" and i + 1 < n and src[i + 1] in '#"':
            j = i + 1
            hashes = 0
            while j < n and src[j] == "#":
                hashes += 1
                j += 1
            if j < n and src[j] == '"':
                term = '"' + "#" * hashes
                k = src.find(term, j + 1)
                k = n if k < 0 else k
                for p in range(j + 1, min(k, n)):
                    if src[p] != "\n":
                        out[p] = " "
                i = min(k + len(term), n)
                continue
        if c == '"':
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    out[j] = " "
                    if j + 1 < n:
                        out[j + 1] = " "
                    j += 2
                    continue
                if src[j] == '"':
                    break
                if src[j] != "\n":
                    out[j] = " "
                j += 1
            i = j + 1
            continue
        if c == "'":
            # A char literal, or a lifetime. Only the first has a closing quote
            # a couple of characters along, and reading `'static` as a string
            # is the mistake that makes `xgettext` warn twelve times on this
            # very file.
            m = re.match(r"'(?:\\.|[^'\\])'", src[i:])
            if m:
                for p in range(i + 1, i + m.end() - 1):
                    out[p] = " "
                i += m.end()
                continue
            i += 1
            continue
        i += 1
    return "".join(out)


def matching(msk: str, start: int) -> int:
    """Index just past the bracket opened at `start`."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    want = [pairs[msk[start]]]
    i = start + 1
    while i < len(msk) and want:
        c = msk[i]
        if c in pairs:
            want.append(pairs[c])
        elif c == want[-1]:
            want.pop()
        i += 1
    return i


def trim(text: str, msk: str):
    """`text` with leading and trailing whitespace **and comments** removed.

    Trimmed by the mask rather than by the text, because a comment is
    whitespace to a parser and prose to `str.strip`. Both were wrong once:
    a comment between two elements put `// **The hold, and…` where a label
    goes, and a comment **inside an argument list** -- which `ctxmenu.rs`
    really has, eight lines of it before the label -- did the same one level
    in. Returns the trimmed text, its mask, and how far in it started.
    """
    lead = len(msk) - len(msk.lstrip())
    t, m = text[lead:], msk[lead:]
    tail = len(m) - len(m.rstrip())
    if tail:
        t, m = t[: len(t) - tail], m[: len(m) - tail]
    return t, m, lead


def split_top_level(body: str, msk: str):
    """`body` split on the commas that are not inside anything.

    Yields `(text, mask, offset)` -- the mask travels with the text because
    every consumer has to trim comments off its piece, and a consumer holding
    text without its mask cannot.
    """
    out = []
    depth = 0
    start = 0
    for i, c in enumerate(msk):
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            out.append((body[start:i], msk[start:i], start))
            start = i + 1
    if msk[start:].strip():
        out.append((body[start:], msk[start:], start))
    return out


ARRAY_DECL = re.compile(r"(?m)^(?:pub(?:\([^)]*\))?\s+)?(?:static|const)\s+([A-Z_][A-Z_0-9]*)\s*:[^=;]*?=\s*&\[")
STRING_LIT = re.compile(r'"((?:[^"\\]|\\.)*)"')


def carries_prose(text: str) -> bool:
    """Does this table hold words a person reads, rather than action names?

    **The question decides what gets checked at all, so it is asked the
    inclusive way**: a table is in unless every string in it is an action
    name. A new table of labels is therefore checked the day it appears, and
    a table nobody thought about is not silently outside.
    """
    for m in STRING_LIT.finditer(text):
        s = m.group(1)
        if s and not action_shaped(s):
            return True
    return False


def label_of(expr: str):
    """The msgid a label expression names, or why it cannot be read.

    Returns `(literal, None)` when it reads, `(None, expr)` when it does not.
    **The second is a failure, never a skip** -- see the note at the top of
    this section for what a skip cost.
    """
    e = expr.strip()
    m = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', e)
    if m:
        return m.group(1), None
    m = re.fullmatch(r'([A-Za-z_][A-Za-z_0-9]*)\s*\(\s*"((?:[^"\\]|\\.)*)"\s*,?\s*\)', e)
    if m and m.group(1) in LABEL_WRAPPERS:
        return m.group(2), None
    return None, e


def element_parts(text: str, msk: str):
    """One table element, read as a dict, or `None` for a separator.

    Four shapes, and the split between them is made on punctuation rather than
    on a list of constructor names: a `Row { … }` literal, a call, a bare
    tuple, and a name standing for one of those. **A shape this does not know
    comes back with a `?` in front of it** -- the caller turns that into a
    printed failure, never a skip.
    """
    t, tm, off = trim(text, msk)
    if not tm:
        return None
    brace = tm.find("{")
    if brace >= 0 and re.match(r"[A-Za-z_][A-Za-z_0-9]*\s*\{", tm):
        inner_end = matching(tm, brace)
        fields = split_top_level(t[brace + 1 : inner_end - 1], tm[brace + 1 : inner_end - 1])
        out = {"label": None, "action": None, "enabled": None, "at": off + brace + 1}
        for ftext, fmsk, foff in fields:
            ft, fm, flead = trim(ftext, fmsk)
            for key in ("label:", "action:", "enabled:"):
                if not ft.startswith(key):
                    continue
                vt, _vm, vlead = trim(ft[len(key) :], fm[len(key) :])
                if key == "label:":
                    out["label"] = vt
                    out["at"] = off + brace + 1 + foff + flead + len(key) + vlead
                elif key == "action:":
                    a = STRING_LIT.search(vt)
                    out["action"] = a.group(1) if a else None
                else:
                    out["enabled"] = vt.replace("Enable::", "")
        return out
    if re.match(r"([A-Za-z_][A-Za-z_0-9]*)?\s*\(", tm):
        paren = tm.index("(")
        end = matching(tm, paren)
        args = split_top_level(t[paren + 1 : end - 1], tm[paren + 1 : end - 1])
        if not args:
            return None  # `sep()` -- a separator carries no label
        lt, _lm, llead = trim(args[0][0], args[0][1])
        action = None
        if len(args) > 1:
            at1, _am1, _al = trim(args[1][0], args[1][1])
            a = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', at1)
            if a and action_shaped(a.group(1)):
                action = a.group(1)
        return {
            "label": lt,
            "action": action,
            "enabled": None,
            "at": off + paren + 1 + args[0][2] + llead,
        }
    if re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", t):
        return {"label": "NAME:" + t, "action": None, "enabled": None, "at": off}
    return {"label": "?" + t, "action": None, "enabled": None, "at": off}


def named_const(src: str, msk: str, name: str):
    """The right-hand side of `const NAME: … = …;`, for an element that is a
    name rather than a literal (`SEP`). Unresolvable is a failure, not a skip:
    a name this cannot follow is a row nobody is checking."""
    m = re.search(r"(?m)^(?:pub\s+)?const\s+%s\s*:[^=;]*=\s*" % re.escape(name), msk)
    if not m:
        return None
    end = msk.find(";", m.end())
    if end < 0:
        return None
    return src[m.end() : end], msk[m.end() : end]


def table_rows(whole: str):
    """Every row of every table in one file, and every element that could not
    be read.

    The second return value is the whole point of this function existing. See
    the note above `LABEL_WRAPPERS`.
    """
    body = whole.split("#[cfg(test)]")[0]
    bmask = mask(body)
    rows, unparsed, greys = [], [], []
    for tname, btext, bm, boff in row_tables_in(body, bmask):
        for etext, emsk, eoff in split_top_level(btext, bm):
            parts = element_parts(etext, emsk)
            if parts is None or parts["label"] is None:
                continue
            at = boff + eoff + parts["at"]
            line = body[:at].count("\n") + 1
            expr = parts["label"]
            if expr.startswith("NAME:"):
                got = named_const(body, bmask, expr[5:])
                if got is None:
                    unparsed.append((tname, expr[5:], line))
                    continue
                inner = element_parts(got[0], got[1])
                if inner is None or inner["label"] is None:
                    continue
                expr = inner["label"]
                parts["action"] = parts["action"] or inner["action"]
                parts["enabled"] = parts["enabled"] or inner["enabled"]
            lit, bad = label_of(expr)
            if bad is not None:
                unparsed.append((tname, bad, line))
                continue
            if parts["enabled"] is not None and lit:
                greys.append((lit, parts["enabled"], at))
            if parts["action"] and lit:
                rows.append((lit, parts["action"], line))
    return rows, unparsed, greys


def row_tables_in(body: str, bmask: str):
    for m in ARRAY_DECL.finditer(bmask):
        open_at = m.end() - 1
        close_at = matching(bmask, open_at)
        inner = body[open_at + 1 : close_at - 1]
        if not carries_prose(inner):
            continue
        yield m.group(1), inner, bmask[open_at + 1 : close_at - 1], open_at + 1


def enum_arms(src: str, msk: str, fn_name: str):
    """`{variant: (expression, offset)}` for one `fn <name>(self) { match self {…} }`.

    `None` when the function or its match cannot be found, or when an arm is
    not `Enum::Variant => …`. **`None` is a failure the caller prints**, not an
    empty dict: the version this replaces returned `{}` on a miss, and a `{}`
    here and a menu with no rows in it are the same reading.
    """
    m = re.search(r"fn %s\(self\)[^{]*\{" % re.escape(fn_name), msk)
    if not m:
        return None
    end = matching(msk, m.end() - 1)
    inner, inner_m, base = src[m.end() : end - 1], msk[m.end() : end - 1], m.end()
    mm = re.search(r"match\s+self\s*\{", inner_m)
    if not mm:
        return None
    arms_end = matching(inner_m, mm.end() - 1)
    at, am, abase = (
        inner[mm.end() : arms_end - 1],
        inner_m[mm.end() : arms_end - 1],
        base + mm.end(),
    )
    out = {}
    for atext, amsk, aoff in split_top_level(at, am):
        t, tm, lead = trim(atext, amsk)
        if not tm:
            continue
        k = re.match(r"\w+::(\w+)\s*=>\s*", t)
        if not k:
            return None
        out[k.group(1)] = (t[k.end() :], abase + aoff + lead + k.end())
    return out or None


def paired_match_rows(whole: str):
    """The tab menu keeps labels and actions in two `match` arms over one enum,
    so the two halves are never adjacent. Joined on the variant name.

    **This half went blind too, and later.** Task 561 wrapped `menu.rs`; the
    row reader was rebuilt for it and this function was not, so when the same
    wrapping reached `strip.rs`'s `fn label` its regex stopped matching and all
    eight tab rows left the count -- 88 to 80, exit code 0. Measured on the
    working tree while fixing the first half. So the reading here goes through
    the same `label_of`, and an arm it cannot read is reported.
    """
    src = whole.split("#[cfg(test)]")[0]
    msk = mask(src)
    labels = enum_arms(src, msk, "label")
    actions = enum_arms(src, msk, "action")
    if labels is None or actions is None:
        which = "label" if labels is None else "action"
        return [], [("TabCmd", "fn %s(self) could not be read at all" % which, 0)]
    rows, unparsed = [], []
    for variant, (expr, at) in labels.items():
        line = src[:at].count("\n") + 1
        lit, bad = label_of(expr)
        if bad is not None:
            unparsed.append(("TabCmd::" + variant, bad, line))
            continue
        if variant not in actions:
            unparsed.append(("TabCmd::" + variant, "no arm in fn action(self)", line))
            continue
        act_lit, act_bad = label_of(actions[variant][0])
        if act_bad is not None:
            unparsed.append(("TabCmd::" + variant, act_bad, line))
            continue
        rows.append((lit, act_lit, line))
    return rows, unparsed


def menu_rows():
    """Every row of every menu, with where it came from.

    Also carries, per file, the elements that could not be read and the
    greyness each row declares -- both read out of the same walk over the
    tables, so there is no second parser to fall out of step with this one.
    """
    out = []
    for name, kind in (
        ("menu.rs", "tables"),
        ("ctxmenu.rs", "tables"),
        ("strip.rs", "tables"),
        ("strip.rs", "paired"),
    ):
        path = os.path.join(ROOT, name)
        with open(path, encoding="utf-8") as fh:
            whole = fh.read()
        if kind == "tables":
            rows, unparsed, greys = table_rows(whole)
        else:
            rows, unparsed = paired_match_rows(whole)
            greys = []
        out.append((name, kind, rows, whole, unparsed, greys))
    return out


def handled_tags(main_src: str):
    """The `ACTION_*` constants `cb_action` has a branch for.

    **The walk itself lives in `_cb_action.py`**, shared with
    `action-arms-act.py`. The two gates ask different questions of these arms
    -- this one "is there a branch", that one "does the branch do anything" --
    and a second walker would be a second reader of one fact. Moving it out
    changed no number here: 43 arms naming 46 constants, before and after.

    It is parsed as match arms rather than by searching the body because the
    spellings vary in three ways that each cost a wrong answer when guessed:
    `ffi::ACTION_X` and bare `ACTION_X` are both used, or-patterns (`A | B =>`)
    put two names on one arm, and a body-wide search would also collect the
    constants mentioned inside arm *bodies*.
    """
    tags = set()
    arms = 0
    for pattern, _body, _line in _cb_action.arms(main_src):
        found = _cb_action.tags_of(pattern)
        if found:
            arms += 1
            tags.update(found)
    return tags, arms


def declared_constants(ffi_src: str):
    return set(re.findall(r"^pub const (ACTION_[A-Z0-9_]+):", ffi_src, re.M))


# `strip.rs` decides greyness in a function over the enum instead of in the
# table, so that one is read on its own.
ENUM_ENABLED = re.compile(r"fn enabled\(self\)[^{]*\{")

#: `enabled:` values that mean "greyed by a decision somebody made".
DECIDED_GREY = ("No", "false")
#: …and the ones that mean "live". Everything else is greyed **by state**:
#: its greyness is a fact about right now, and a number that moves is a
#: reading rather than a constant.
LIVE = ("Yes", "true")


def enum_greyed(whole: str):
    """The variants `fn enabled(self)` greys, and whether it could be read.

    **Two shapes are understood and a third is a failure.** `true` greys
    nothing; `!matches!(self, A | B)` greys A and B. Anything else is reported,
    because the version this replaces was a single regex that returned no
    variants for a body it did not understand -- and "greys nothing" and
    "could not tell" printed the same number.
    """
    src = whole.split("#[cfg(test)]")[0]
    msk = mask(src)
    m = ENUM_ENABLED.search(msk)
    if not m:
        return [], []
    end = matching(msk, m.end() - 1)
    body, _bm, _lead = trim(src[m.end() : end - 1], msk[m.end() : end - 1])
    line = src[: m.start()].count("\n") + 1
    if body == "true":
        return [], []
    mm = re.fullmatch(r"!matches!\(\s*self\s*,([\s\S]*)\)", body)
    if mm:
        return re.findall(r"\w+::(\w+)", mm.group(1)), []
    return [], [("fn enabled(self)", body, line)]


def statically_greyed(src: str, greys, enum_variants):
    """Rows greyed by a decision, with whether a reason is written beside them.

    **Not the same question as "is it greyed".** A row can be grey because
    somebody wrote down why, or because greying it was the cheapest way to
    make a checker stop talking -- and the two are indistinguishable from the
    row itself.

    `greys` comes from the table walk rather than from a pattern of its own.
    That is deliberate: the reading this whole file lost in task 561 was lost
    because the greyness check had **its own** regex for finding a label, so a
    label the row reader could not see was a label the grey reader could not
    see either -- twice the blindness, once the warning, which was none.
    """
    for label, state, at in greys:
        if state in DECIDED_GREY:
            yield label, reason_near_index(src, at)
    m = ENUM_ENABLED.search(mask(src))
    for variant in enum_variants:
        yield variant, reason_near_index(src, m.start() if m else 0)


def state_greyed(greys):
    """Rows whose greyness is a fact about right now, not a decision."""
    for label, state, _at in greys:
        if state not in DECIDED_GREY and state not in LIVE:
            yield label, state


def reason_near_index(src: str, idx: int) -> bool:
    lines = src.splitlines()
    at = src[:idx].count("\n")
    return any(GREYED_REASON.search(l) for l in lines[max(0, at - 12) : at + 7])


def greyed_reason_near(src: str, action: str) -> bool:
    """Is there a `// greyed: <reason>` within sight of this action's row?

    **Both directions, and that was not the first guess.** Looking only
    backwards from the action's own text found nothing in `strip.rs`: the
    action lives in one `match` arm and what greys it is a `fn enabled` further
    down, so the reason sits *after* every mention of the name. The floor for
    this tool caught it -- adding the reason changed no number -- which is the
    same failure this tool exists to stop, one level up: a check that cannot
    see the thing it is asking for reads exactly like a check that is satisfied.
    """
    lines = src.splitlines()
    for m in re.finditer(re.escape(action), src):
        at = src[: m.start()].count("\n")
        for line in lines[max(0, at - 12) : at + 7]:
            if GREYED_REASON.search(line):
                return True
    return False


# --------------------------------------------------------------- self-test
#
# Both directions, and the two spellings that have each already produced a
# wrong answer. A probe that stopped matching would report zero unhandled rows
# and read exactly like a clean tree.
CANARY_MAIN = '''
extern "C" fn cb_action(_app: App, target: Target, action: Action) -> bool {
    match action.tag {
        ffi::ACTION_TOGGLE_COMMAND_PALETTE => { true }
        ACTION_NEW_WINDOW => { true }
        ACTION_MOUSE_SHAPE | ACTION_MOUSE_VISIBILITY => true,
        ffi::ACTION_CLOSE_WINDOW | ffi::ACTION_QUIT => {
            logf!("[action] close_window/quit tag={}", action.tag);
            true
        }
        _ => false,
    }
}
'''


# The table reader's own canary. **It is the shape the reader actually meets**
# -- a wrapped label, a bare one, a comment sitting between two elements, a row
# greyed by a decision, one greyed by state, and a separator -- because a probe
# that is tidier than the source proves nothing about the source.
CANARY_TABLE = '''
const CANARY_ROWS: &[Row] = &[
    act(n_("New Window"), "new_window"),
    act("Plain Label", "new_tab"),
    // A comment between two elements. This is not decoration: trimming the
    // element with `str.strip` instead of with the mask put this sentence
    // where a label goes, and every row after it read as unparseable.
    Row { label: n_("Greyed Always"), action: Some("check_for_updates"), enabled: Enable::No },
    Row { label: "Greyed Now", action: Some("close_tab:this"), enabled: Enable::WhenReopenable },
    sep(),
];
'''


# The paired half's canary. It went blind three hours after the table half did
# and for the same reason, so it gets the same treatment: read it forwards, and
# read a wrapper it has not been taught backwards.
CANARY_ENUM = '''
impl TabCmd {
    fn label(self) -> &'static str {
        match self {
            TabCmd::Close => n_("Close Tab"),
            TabCmd::Rename => "Rename Tab",
        }
    }
    fn action(self) -> &'static str {
        match self {
            TabCmd::Close => "close_tab:this",
            TabCmd::Rename => "rename_tab",
        }
    }
}
'''


def self_test() -> None:
    tags, arms = handled_tags(CANARY_MAIN)
    want = {
        "ACTION_TOGGLE_COMMAND_PALETTE",  # the `ffi::` spelling
        "ACTION_NEW_WINDOW",              # the bare spelling
        "ACTION_MOUSE_SHAPE",             # an or-pattern, first half
        "ACTION_MOUSE_VISIBILITY",        # an or-pattern, second half
        "ACTION_CLOSE_WINDOW",            # an or-pattern with the prefix
        "ACTION_QUIT",
    }
    missing = want - tags
    if missing:
        print(f"FAIL: the arm parser cannot see {sorted(missing)}.")
        sys.exit(1)
    if arms != 4:
        print(f"FAIL: the arm parser saw {arms} arms in a four-arm match.")
        sys.exit(1)
    # And it must not invent handling: a name mentioned only inside an arm body
    # is not a branch.
    if "ACTION_RENDER" in handled_tags(
        CANARY_MAIN.replace('logf!("[action] close_window/quit tag={}", action.tag);',
                            'let _ = ffi::ACTION_RENDER;')
    )[0]:
        print("FAIL: the arm parser counts names used inside an arm body as handled.")
        sys.exit(1)
    if not GREYED_REASON.search("    // greyed: no second frame exists yet"):
        print("FAIL: the reason pattern does not match its own shape.")
        sys.exit(1)
    if GREYED_REASON.search("    // greyed because nobody wrote it"):
        print("FAIL: the reason pattern accepts a comment with no `greyed:` marker.")
        sys.exit(1)
    # ---- the table reader, in both directions.
    rows, unparsed, greys = table_rows(CANARY_TABLE)
    if unparsed:
        print(f"FAIL: the table reader cannot read its own canary: {unparsed}")
        sys.exit(1)
    want_rows = [
        ("New Window", "new_window"),
        ("Plain Label", "new_tab"),
        ("Greyed Always", "check_for_updates"),
        ("Greyed Now", "close_tab:this"),
    ]
    if [(l, a) for l, a, _ in rows] != want_rows:
        print(f"FAIL: the table reader read {[(l, a) for l, a, _ in rows]}, wanted {want_rows}.")
        sys.exit(1)
    if [(l, g) for l, g, _ in greys] != [("Greyed Always", "No"), ("Greyed Now", "WhenReopenable")]:
        print(f"FAIL: the greyness read out of the canary is {[(l, g) for l, g, _ in greys]}.")
        sys.exit(1)
    if [l for l, _ in statically_greyed(CANARY_TABLE, greys, [])] != ["Greyed Always"]:
        print("FAIL: the decided-grey split does not hold on the canary.")
        sys.exit(1)
    if [l for l, _ in state_greyed(greys)] != ["Greyed Now"]:
        print("FAIL: the state-grey split does not hold on the canary.")
        sys.exit(1)

    # **And the direction task 561 went, which is the one that cost 57 rows.**
    # A wrapper this file has not been taught must be a printed failure. If
    # this probe ever passes silently, the checker is back to skipping rows and
    # reading like a clean tree while it does it.
    unknown = CANARY_TABLE.replace('n_("New Window")', 'LOCALISE("New Window")')
    rows2, unparsed2, greys2 = table_rows(unknown)
    if not unparsed2:
        print(
            "FAIL: an unknown label wrapper was skipped instead of reported. That is the "
            "exact failure this reader replaced: the row leaves the count and nothing says so."
        )
        sys.exit(1)
    if any(l == "New Window" for l, _, _ in rows2):
        print("FAIL: a label it says it cannot read still came back as a row.")
        sys.exit(1)
    if len(rows2) != len(rows) - 1:
        print(f"FAIL: an unreadable label cost {len(rows) - len(rows2)} rows, wanted 1.")
        sys.exit(1)

    # The same, one field along: greyness is read from the same walk, so an
    # unreadable label has to take its grey row with it rather than leaving a
    # grey count that quietly went down.
    unknown_grey = CANARY_TABLE.replace('n_("Greyed Always")', 'LOCALISE("Greyed Always")')
    _r3, unparsed3, greys3 = table_rows(unknown_grey)
    if not unparsed3 or any(l == "Greyed Always" for l, _, _ in greys3):
        print("FAIL: an unreadable label on a greyed row did not reach the unreadable list.")
        sys.exit(1)

    # ---- the paired half, forwards and backwards.
    prows, punparsed = paired_match_rows(CANARY_ENUM)
    if punparsed or [(l, a) for l, a, _ in prows] != [
        ("Close Tab", "close_tab:this"),
        ("Rename Tab", "rename_tab"),
    ]:
        print(f"FAIL: the paired reader read {prows} / {punparsed} from its canary.")
        sys.exit(1)
    _pr2, pu2 = paired_match_rows(CANARY_ENUM.replace('n_("Close Tab")', 'LOCALISE("Close Tab")'))
    if not pu2:
        print("FAIL: the paired reader skipped an unknown wrapper instead of reporting it.")
        sys.exit(1)
    _pr3, pu3 = paired_match_rows(CANARY_ENUM.replace("fn label(self)", "fn caption(self)"))
    if not pu3:
        print(
            "FAIL: with no `fn label` at all the paired reader returned quietly. An enum it "
            "cannot find and an enum with no rows are the same reading, which is the bug."
        )
        sys.exit(1)

    # ---- the enum-greyness reader: two shapes understood, a third reported.
    if enum_greyed("fn enabled(self) -> bool {\n        true\n    }") != ([], []):
        print("FAIL: `fn enabled { true }` should grey nothing and read cleanly.")
        sys.exit(1)
    greyed_two = enum_greyed(
        "fn enabled(self) -> bool {\n        !matches!(self, X::A | X::B)\n    }"
    )
    if greyed_two != (["A", "B"], []):
        print(f"FAIL: the `!matches!` shape read as {greyed_two}.")
        sys.exit(1)
    _v, unread_enum = enum_greyed(
        "fn enabled(self) -> bool {\n        self.thing().is_some()\n    }"
    )
    if not unread_enum:
        print(
            "FAIL: a `fn enabled` body it does not understand greyed nothing and said nothing. "
            "'greys nothing' and 'could not tell' must not print the same number."
        )
        sys.exit(1)

    print(
        "probe self-test: OK (both spellings, or-patterns, arm bodies excluded, reason shape "
        "pinned; the table reader reads wrapped and bare labels across a comment, splits "
        "decided from state greyness, and reports an unknown wrapper rather than skipping it; "
        "the paired reader does the same and speaks up when it cannot find the enum at all; "
        "and an `fn enabled` body it cannot read is reported rather than counted as zero)"
    )


def main() -> int:
    self_test()
    with open(os.path.join(ROOT, "main.rs"), encoding="utf-8") as fh:
        main_src = fh.read()
    with open(os.path.join(ROOT, "ffi.rs"), encoding="utf-8") as fh:
        ffi_src = fh.read()

    handled, arms = handled_tags(main_src)
    declared = declared_constants(ffi_src)

    unreasoned_grey = []
    decided_grey = []
    state_grey = []
    unreadable = []
    total = reaches_host = ok = greyed = 0
    core_only = 0
    hosts_own = 0
    bad = []
    seen_files = set()
    for name, kind, rows, whole, unparsed, greys in menu_rows():
        unreadable += [(name, table, what, line) for table, what, line in unparsed]
        if name not in seen_files:
            seen_files.add(name)
            enum_variants, enum_unparsed = enum_greyed(whole)
            unreadable += [(name, t, w, l) for t, w, l in enum_unparsed]
            for label, has_reason in statically_greyed(whole, greys, enum_variants):
                decided_grey.append((name, label))
                if not has_reason:
                    unreasoned_grey.append((name, label))
            for label, how in state_greyed(greys):
                state_grey.append((name, label, how))
        for label, action, line in rows:
            total += 1
            if action.startswith("__polter_") or action.startswith("host:"):
                hosts_own += 1
                continue
            const = "ACTION_" + action.split(":")[0].upper()
            if const not in declared:
                core_only += 1
                continue
            reaches_host += 1
            if const in handled:
                ok += 1
            elif greyed_reason_near(whole, action):
                greyed += 1
            else:
                bad.append((name, kind, label, action, const, line))

    print(
        f"cb_action: {arms} arms naming {len(handled)} of the {len(declared)} "
        f"ACTION_* constants ffi.rs declares"
    )
    print(
        f"menu rows: {total} scanned; {hosts_own} the host's own; {core_only} name an action "
        f"the core performs itself (no ACTION_* constant, outside this check); "
        f"{reaches_host} reach the host -- {ok} handled, {greyed} greyed with a written reason"
    )

    # **Both halves of the fraction, because the top one is true of nothing.**
    # "0 greyed without a reason" is what a clean tree says and it is also what
    # a tree this could not read says -- task 561 printed exactly that while 57
    # rows were outside its sight. Printing how many were found makes the zero
    # a reading rather than a sentence.
    print(
        f"greyed rows: {len(unreasoned_grey)} of {len(decided_grey)} greyed by a decision "
        f"have no `// greyed:` reason; "
        f"{len(state_grey)} greyed by state "
        + (f"({', '.join(l for _, l, _ in state_grey)})" if state_grey else "(none)")
    )
    for name, label in unreasoned_grey:
        print(
            f"GREY   {name}  {label!r} is greyed and nothing says why. A row that was usable "
            f"and went grey looks exactly like one that was always grey."
        )
        print(f"       Write `// greyed: <why>` beside whatever decides it.")

    for name, kind, label, action, const, line in bad:
        where = f"{name}:{line}" if line else f"{name} ({kind})"
        print(
            f"HIT    {where}  {label!r} runs `{action}` -> {const}, which cb_action does not "
            f"handle. Clicking it does nothing and logs nothing."
        )
        print(
            f"       Either add the branch, or grey the row and write `// greyed: <why>` "
            f"beside whatever decides it."
        )

    # **Before the ratchet, because this one has no baseline to park it in.**
    # A row nobody could read is not a smaller version of a row that does
    # nothing when clicked -- it is this file not knowing what it is looking
    # at, and every number printed above is short by one for each of them.
    for name, table, what, line in unreadable:
        print(
            f"UNREAD {name}:{line}  in `{table}`, this label cannot be read: {what.strip()!r}"
        )
        print(
            f"       Rows are counted by reading every element of every table, so a label "
            f"this does not understand is a row that silently leaves the count -- which is "
            f"exactly how 57 of them left it in task 561."
        )
        print(
            f"       If the wrapper returns its argument unchanged, add it to "
            f"LABEL_WRAPPERS with the reason. If it does not, this row's label is not a "
            f"msgid and the menu is not saying what you think it says."
        )
    if unreadable:
        print(
            f"\n{len(unreadable)} table element(s) could not be read. Every count above is "
            f"short by that many, and none of them would have said so."
        )
        return 1

    n = len(bad) + len(unreasoned_grey)
    if n == BASELINE_UNREASONED:
        print(f"{n} row(s) unhandled and unreasoned (baseline {BASELINE_UNREASONED}).")
        return 0
    if n > BASELINE_UNREASONED:
        print(f"\n{n} unhandled and unreasoned, baseline {BASELINE_UNREASONED}. A row that "
              f"does nothing when clicked, and says nothing when it does.")
        return 1
    print(f"\nFAIL, and it is good news: {BASELINE_UNREASONED - n} fewer than the baseline.")
    print(f"      Set BASELINE_UNREASONED = {n}.")
    print("      A baseline left above the real number lets the work roll back for free.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
