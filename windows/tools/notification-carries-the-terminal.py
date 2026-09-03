#!/usr/bin/env python3
"""A `cb_action` arm that knows which terminal must say so when it tells
somebody.

**This exists because of a defect no other gate could see.** The
`poltergeist_mark` arm resolved the surface an action was aimed at, handed it
to `tabs::set_mark_for_surface`, and then called
`ctxmenu::on_poltergeist_mark(role, shielded)` -- the notification, without the
one fact that says what it is a notification *about*. The menu's own log line
therefore could not say which terminal, or which window, the mark was for, and
"a mark arrived" and "a mark arrived for a pane you cannot see" printed the
same sentence.

Restoring that defect leaves `window-tagged-logs.py` at the same number, exit
0, and the tree still builds. The count it reports moved when the defect was
fixed, but only as a consequence; the thing being fixed was invisible to it.
That is what this file is for.

**What it checks, exactly.** For every arm of `cb_action` that resolves the
target's surface *and* calls into another host module:

  A. the function it calls must have a parameter that carries a surface --
     named `surface`, or typed `Surface`. This is the shape the original defect
     had: the fact was available at the call site and the callee had nowhere to
     put it.
  B. that parameter must not be handed a bare null literal at the call site.
     Removing the argument and passing `null_mut()` instead compiles, keeps the
     signature honest-looking, and reproduces the original behaviour exactly.
     `surface.unwrap_or(std::ptr::null_mut())` is not this: the null is the
     tail of an expression that carries the surface when there is one.

**What it cannot see, and this is the more useful half.**

  - **"Takes it and passes the wrong one."** An arm that hands over
    `target.surface` when the right answer was some other surface satisfies
    both rules. Nothing here reads what the value means.
  - **"Takes it and ignores it."** A callee may accept the surface and never
    use it -- log the same sentence it always did, key nothing on it. That is
    exactly the shape of tonight's `quick.rs` scale: a value accepted and
    discarded, with every static reading of it green.
  - **"Names a window, but the wrong one."** Whether the log line that results
    is tagged with the surface's window or with whichever window happens to be
    in front is not a question about signatures. Replacing the lookup with
    "the window in front" leaves this gate and every other one green.
  - **An arm that stops resolving a surface altogether** drops out of scope
    rather than failing -- a checker whose reach shrinks as the code gets
    worse. `MIN_CARRYING_ARMS` below is the ratchet against that: it is one
    number, not a second hand-written list of arms.

So this gate says "the fact was carried", never "the right fact was carried,
and used". The second one is answered on the machine, by marking a background
pane in a second window and reading which `w` the two lines print.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "host", "src"))

# Arms that resolve a surface and notify another module. **A number rather
# than a list**: a list of arm names would be a second place where the set
# lives, and it would need editing every time an action is added. Lower it
# only when an action is genuinely removed, and say which in the comment.
#
#   5 (this commit): ACTION_PROMPT_TITLE, ACTION_READONLY, ACTION_PWD,
#                    ACTION_POLTERGEIST_MARK, ACTION_NEW_WINDOW.
MIN_CARRYING_ARMS = 6

# The call is deliberately identity-free, with the reason written next to it.
# **Default is "must carry"**, and the exception is the thing that has to be
# argued: a checker whose default is "out of scope unless listed" says nothing
# about the case nobody thought of, which is the only case that matters.
EXEMPT = re.compile(r"//\s*carries no terminal:\s*(\S.*)$")

NULL_LITERAL = re.compile(
    r"^(?:std::)?ptr::null_mut\(\)$|^std::ptr::null_mut\(\)$|^0\s+as\s+\*mut\b"
)


def strip_text(src: str) -> str:
    """The source with string literals and comments blanked out.

    **Counting braces without this is how the first run of this file merged
    four arms into one**: `alogf!(origin, "[action] readonly={}", on)` has a
    `{` and a `}` in a format string, and the arm splitter counted them. The
    result was not an error, it was a wrong answer that looked like three
    findings -- which is the failure mode a parser must not have.

    Length is preserved character for character, and newlines are kept even
    inside a blanked literal, so offsets and line numbers still line up with
    the real source. Both are asserted in the self-test: a blanking pass that
    quietly shortens the text moves every line number this file prints.
    """
    out = list(src)
    i, n = 0, len(src)

    def blank(a: int, b: int) -> None:
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        if src[i] == '"':
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == '"':
                    break
                j += 1
            blank(i, j + 1)
            i = j + 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            blank(i, j)
            i = j
        else:
            i += 1
    return "".join(out)


def brace_body(src: str, start: int) -> str:
    """The `{...}` block beginning at or after `start`, braces balanced."""
    blank = strip_text(src)
    i = blank.index("{", start)
    depth, k = 0, i
    while k < len(src):
        if blank[k] == "{":
            depth += 1
        elif blank[k] == "}":
            depth -= 1
            if depth == 0:
                return src[i + 1 : k]
        k += 1
    return ""


def split_args(text: str) -> list[str]:
    """Top-level comma-separated arguments of a call, `(` already consumed."""
    out, depth, cur = [], 1, ""
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                out.append(cur)
                return [a.strip() for a in out]
        if depth == 1 and ch == ",":
            out.append(cur)
            cur = ""
        else:
            cur += ch
    return [a.strip() for a in out]


def params_of(src: str, fn: str) -> list[str] | None:
    """The parameter list of `fn` as written, or `None` if it is not here."""
    m = re.search(r"\bfn\s+" + re.escape(fn) + r"\s*(?:<[^>]*>)?\s*\(", src)
    if not m:
        return None
    return split_args(src[m.end() :])


def carries_identity(param: str) -> tuple[bool, bool]:
    """(carries something, carries a surface specifically).

    **A window counts too.** `winid::close_requested(frame, via)` is told which
    window it is about; demanding a surface there would be demanding the wrong
    fact. What the rule refuses is a notification told *neither* -- which is
    what `on_poltergeist_mark(role, shielded)` was.
    """
    name = param.split(":")[0].strip()
    type_ = param.split(":", 1)[1] if ":" in param else ""
    surface = name == "surface" or "Surface" in type_
    window = name in ("frame", "hwnd", "window") or "HWND" in type_
    return (surface or window, surface)


def arms_of(body: str):
    """Top-level `TAG => {...}` arms of the `match`, with their line offsets."""
    lines = body.split("\n")
    blank = strip_text(body).split("\n")
    arms, cur, depth = [], None, 0
    for n, line in enumerate(lines):
        if depth <= 0:
            m = re.match(r"\s{8}(?:ffi::)?([A-Z][A-Z_0-9]+)\s*=>", line)
            if m:
                cur = (m.group(1), n, [])
                arms.append(cur)
                depth = 0
        if cur is not None:
            cur[2].append(line)
            depth += blank[n].count("{") - blank[n].count("}")
    return [(tag, n, "\n".join(ls)) for tag, n, ls in arms]


def analyse(main_src: str, modules: dict[str, str]):
    """(problems, arms_seen, carrying_arms, exemptions)."""
    m = re.search(r'extern\s+"C"\s+fn\s+cb_action', main_src)
    if not m:
        # **Not a pass.** A rename or a reformat that this parser cannot follow
        # would otherwise scan nothing and report a clean tree, which is the
        # one failure mode a checker must not have.
        return (["`cb_action` was not found in main.rs at all"], 0, 0, [])
    body = brace_body(main_src, m.end())
    arms = arms_of(body)
    if not arms:
        return (["`cb_action` was found but no arms were parsed out of it"], 0, 0, [])

    known = set(modules)
    problems, carrying, exemptions = [], 0, []
    for tag, _, text in arms:
        if "target_surface(" not in text and "target.surface" not in text:
            continue
        calls = [
            (c.group(1), c.group(2), split_args(text[c.end() :]), c.start())
            for c in re.finditer(r"\b(?:crate::)?(\w+)::(\w+)\s*\(", text)
            if c.group(1) in known
        ]
        if not calls:
            continue
        counted = False
        for mod, fn, args, at in calls:
            before = text[:at].rsplit("\n", 3)[-3:]
            reason = None
            for line in reversed(before):
                hit = EXEMPT.search(line)
                if hit:
                    reason = hit.group(1)
                    break
            if reason:
                exemptions.append(f"{tag} -> {mod}::{fn}: {reason}")
                continue
            params = params_of(modules[mod], fn)
            if params is None:
                problems.append(
                    f"{tag} calls {mod}::{fn}, which is not defined in {mod}.rs "
                    f"-- this gate could not read its parameters"
                )
                continue
            idx = [i for i, p in enumerate(params) if carries_identity(p)[1]]
            any_id = [i for i, p in enumerate(params) if carries_identity(p)[0]]
            if not any_id:
                problems.append(
                    f"{tag} resolves the target's surface and then calls "
                    f"{mod}::{fn}({', '.join(params) or ''}), which has nowhere to "
                    f"put it. The arm knows which terminal; the notification does "
                    f"not. Add the surface, or write "
                    f"`// carries no terminal: <reason>` above the call."
                )
                continue
            counted = counted or bool(idx)
            for i in idx:
                if i < len(args) and NULL_LITERAL.match(args[i]):
                    problems.append(
                        f"{tag} passes a bare null to {mod}::{fn}'s "
                        f"`{params[i].strip()}` while the arm has the surface. "
                        f"The signature still looks right and it still compiles; "
                        f"the notification is back to saying nothing."
                    )
        if counted:
            carrying += 1
    return (problems, len(arms), carrying, exemptions)


# --------------------------------------------------------------- self-test
CANARY_MAIN_BAD = '''
extern "C" fn cb_action(_app: App, target: Target, action: Action) -> bool {
    let origin = origin_window(&target);
    match action.tag {
        ffi::ACTION_MARK => {
            let found = target_surface(&target).is_some_and(|s| tabs::mark(s));
            ctxmenu::on_mark(role, shielded);
            true
        }
    }
}
'''
CANARY_MAIN_OK = CANARY_MAIN_BAD.replace(
    "ctxmenu::on_mark(role, shielded)", "ctxmenu::on_mark(surface, role, shielded)"
)
CANARY_MAIN_NULL = CANARY_MAIN_BAD.replace(
    "ctxmenu::on_mark(role, shielded)",
    "ctxmenu::on_mark(std::ptr::null_mut(), role, shielded)",
)
CANARY_MAIN_UNWRAP = CANARY_MAIN_BAD.replace(
    "ctxmenu::on_mark(role, shielded)",
    "ctxmenu::on_mark(surface.unwrap_or(std::ptr::null_mut()), role, shielded)",
)
CANARY_MAIN_EXEMPT = CANARY_MAIN_BAD.replace(
    "            ctxmenu::on_mark(role, shielded);",
    "            // carries no terminal: it is a repaint request, not a notification\n"
    "            ctxmenu::on_mark(role, shielded);",
)
CANARY_MAIN_NO_SURFACE = CANARY_MAIN_BAD.replace(
    "let found = target_surface(&target).is_some_and(|s| tabs::mark(s));", ""
)
# `tabs::mark` is in the canary because a real arm calls into the state module
# as well as the notification, and both go through the same rule. It takes the
# surface, so it is the "already right" half of the fixture.
CANARY_MODS_BAD = {
    "ctxmenu": "pub fn on_mark(role: i32, shielded: bool) {}",
    "tabs": "pub fn mark(surface: Surface) -> bool { true }",
}
CANARY_MODS_OK = {
    "ctxmenu": "pub fn on_mark(surface: Surface, role: i32, shielded: bool) {}",
    "tabs": "pub fn mark(surface: Surface) -> bool { true }",
}


CANARY_BRACES = '''
extern "C" fn cb_action(_app: App, target: Target, action: Action) -> bool {
    match action.tag {
        ffi::ACTION_ONE => {
            alogf!(origin, "[action] readonly={} surface={:?}", on, s);
            true
        }
        ffi::ACTION_MARK => {
            let found = target_surface(&target).is_some_and(|s| tabs::mark(s));
            ctxmenu::on_mark(role, shielded);
            true
        }
    }
}
'''


def self_test() -> None:
    def probs(main, mods):
        return analyse(main, mods)[0]

    # **The parser's own failure, canaried first.** Braces inside a format
    # string merged four real arms into one on this file's first run and turned
    # three correct arms into three findings. A wrong parse does not announce
    # itself; it announces something else.
    blanked = strip_text(CANARY_BRACES)
    if len(blanked) != len(CANARY_BRACES):
        print("FAIL: blanking changed the length of the source, so every offset "
              "and line number this file reports is off by an unknown amount.")
        sys.exit(2)
    if blanked.count("\n") != CANARY_BRACES.count("\n"):
        print("FAIL: blanking ate a newline; line numbers no longer line up.")
        sys.exit(2)
    if "{}" in blanked or "{:?}" in blanked:
        print("FAIL: braces inside a string literal survived blanking; the arm "
              "splitter will count them and merge arms.")
        sys.exit(2)
    body = brace_body(CANARY_BRACES, CANARY_BRACES.index("cb_action"))
    tags = [t for t, _, _ in arms_of(body)]
    if tags != ["ACTION_ONE", "ACTION_MARK"]:
        print(f"FAIL: the arm splitter found {tags} instead of two separate arms.")
        sys.exit(2)

    if not probs(CANARY_MAIN_BAD, CANARY_MODS_BAD):
        print("FAIL: the original defect -- an arm that resolves the surface and "
              "notifies without it -- was not reported.")
        sys.exit(2)
    if probs(CANARY_MAIN_OK, CANARY_MODS_OK):
        print("FAIL: an arm that does pass the surface was reported anyway.")
        sys.exit(2)
    if not probs(CANARY_MAIN_NULL, CANARY_MODS_OK):
        print("FAIL: a bare null passed into the surface parameter was accepted. "
              "That compiles and reproduces the defect with the signature intact.")
        sys.exit(2)
    if probs(CANARY_MAIN_UNWRAP, CANARY_MODS_OK):
        print("FAIL: `surface.unwrap_or(null_mut())` was read as a bare null. The "
              "null there is the absent case of a value that is carried.")
        sys.exit(2)
    if probs(CANARY_MAIN_EXEMPT, CANARY_MODS_BAD):
        print("FAIL: `// carries no terminal:` did not exempt the call.")
        sys.exit(2)
    # An arm with nothing to carry is out of scope -- and *that* is the hole
    # `MIN_CARRYING_ARMS` exists for, so it is asserted here rather than left
    # as an assumption.
    if probs(CANARY_MAIN_NO_SURFACE, CANARY_MODS_BAD):
        print("FAIL: an arm that resolves no surface was reported.")
        sys.exit(2)
    if analyse(CANARY_MAIN_NO_SURFACE, CANARY_MODS_BAD)[2] != 0:
        print("FAIL: an arm that resolves no surface was counted as carrying one.")
        sys.exit(2)
    if analyse("fn something_else() {}", CANARY_MODS_BAD)[1] != 0:
        print("FAIL: a file with no `cb_action` was scanned as if it had one.")
        sys.exit(2)
    if not analyse("fn something_else() {}", CANARY_MODS_BAD)[0]:
        print("FAIL: a file with no `cb_action` reported no problem. A parser that "
              "cannot find its subject must say so, not pass.")
        sys.exit(2)


def main() -> int:
    self_test()
    main_src = open(os.path.join(SRC, "main.rs"), encoding="utf-8").read()
    mods = {}
    for name in re.findall(r"^\s*(?:pub )?mod (\w+);", main_src, re.M):
        path = os.path.join(SRC, f"{name}.rs")
        if os.path.exists(path):
            mods[name] = open(path, encoding="utf-8").read()

    problems, arms, carrying, exemptions = analyse(main_src, mods)
    print(f"scanned {arms} arms of `cb_action` against {len(mods)} modules: "
          f"{carrying} resolve the target's surface and notify another module")
    for e in exemptions:
        print(f"  exempt: {e}")
    print("  it cannot see: a wrong surface, a surface taken and ignored, or a "
          "log line tagged with the window in front instead of the surface's.")

    if problems:
        for p in problems:
            print(f"\nFAIL: {p}")
        return 1
    if carrying < MIN_CARRYING_ARMS:
        print(f"\nFAIL: {carrying} arms carry a surface into a notification, and the "
              f"floor is {MIN_CARRYING_ARMS}. An arm that stops resolving the "
              f"surface leaves this check's scope silently, so the count is the "
              f"only thing that notices. If an action was removed, lower "
              f"MIN_CARRYING_ARMS and say which.")
        return 1
    if carrying > MIN_CARRYING_ARMS:
        print(f"\nFAIL, and it is good news: {carrying} arms carry one now. "
              f"Set MIN_CARRYING_ARMS = {carrying}.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
