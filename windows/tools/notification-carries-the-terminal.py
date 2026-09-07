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

**What it checks, exactly.** For every arm of `cb_action` that calls into
another host module -- **every one, whether or not the arm looks up a
surface**:

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
  - **An arm that hands over the wrong module's business.** Scope is "calls
    into another module", so a call this file has no opinion about still has
    to satisfy the rule or carry a reason.

**The hole this used to have, because it is the reason for the shape above.**
Until task 288 the first line of the loop was

    if "target_surface(" not in text and "target.surface" not in text: continue

-- a **whitelist by spelling**. An arm that got the surface any other way was
not failed by it, it was never read, and the output was identical to the
output for an arm that passed. It cost exactly what that costs: two arms were
refactored to take the surface from a one-line helper, both left the check
without a sound, and the run afterwards looked like a correct reading of a
tree with three new arms in it.

**`MIN_CARRYING_ARMS` did not catch it and could not.** It is a count, and the
count went *up* -- 11 to 12 -- because a third arm joined in the same change.
A ratchet on a total cannot tell "one left and two joined" from "one joined";
`action-arms-act.py` in this directory learned the same thing and keys its
list by name for the same reason. The count is still here, and it is still
worth having, but the reach it was guarding is now guarded by the scope rule
instead: an arm can only leave this check by no longer calling another module
at all.

**And the file already said so.** The paragraph by `EXEMPT` has read "Default
is *must carry*, and the exception is the thing that has to be argued: a
checker whose default is *out of scope unless listed* says nothing about the
case nobody thought of" since the first version. That was true of the
exemption mechanism and false of the scope filter twelve lines further down,
and nothing compares a file's prose against its own behaviour.

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
#
#   8 (task 161): ACTION_MOUSE_SHAPE and ACTION_MOUSE_VISIBILITY joined, both
#                 keying `mouse.rs` on the surface the action names. A pointer
#                 shape stored once for the process is the same defect this
#                 gate was written for, one pane over.
#   9 (task 273): ACTION_COLOR_CHANGE joined. OSC 10/11 is per surface -- with
#                 a split, one pane's background says nothing about the
#                 other's, and the frame is around both -- so the arm resolves
#                 the surface and `termcolor.rs` keys on it. The other four
#                 arms in that batch (open_url, desktop_notification,
#                 progress_report, command_finished) are about the *window*
#                 and do not carry one; they take `origin` and nothing else.
#  10, 11 (tasks 254 and 271): ACTION_RELOAD_CONFIG and ACTION_POLTERGEIST_CLOSE
#                 joined. Both are surface-targeted in the case that matters:
#                 a *soft* reload is aimed at one surface whose conditional
#                 state moved, and every scope `poltergeist_close` can ask for
#                 is expressed relative to the target's tab -- resolving
#                 either against the tab in front would take the wrong
#                 terminal and look entirely normal doing it.
#  12, 13, 14 (task 273, second batch): ACTION_SELECTION_CHANGED,
#                 ACTION_MOUSE_OVER_LINK and ACTION_SCROLLBAR joined. All
#                 three are facts about one pane: a program in a background
#                 tab can change a selection, the pointer is over one pane,
#                 and each pane scrolls on its own. Resolving any of them
#                 against the tab in front would be right about the window and
#                 wrong about the terminal.
#
#                 ⚠️ **Two of the three were briefly invisible to this gate**,
#                 and the way they were is worth keeping. They resolved the
#                 surface through a helper -- `surface_key(&target)` -- and
#                 this gate decides scope by looking for `target_surface(` as
#                 text, so the arms were skipped entirely rather than failed.
#                 The count stayed at 12 and looked like a correct reading of
#                 a tree with three new arms in it. Anything that moves
#                 `target_surface(` out of an arm takes that arm out of this
#                 check with no sign at either end.
MIN_CARRYING_ARMS = 14

# The notifications that carry no address **today**, by `TAG -> module::fn`.
#
# # A bill, not an approval
#
# **Nothing on this list is correct.** Each one is a call that tells another
# module something happened without saying which terminal or which window it
# happened in, and with two windows open none of them can be read. They are
# recorded so this gate can be green on a tree that already contains them:
# **a gate that is red from its first day is a gate people learn to scroll
# past, and the line they learn to scroll past is where the next real one
# dies.**
#
# **Keyed by name, never by count.** `action-arms-act.py` in this directory
# has the same rule and says why: a count would let somebody fix one, add a
# new addressless call, and stay at the same number -- the total agrees while
# the membership changed. That is the same shape as using a position for an
# identity, which this port has already paid for once.
#
# **Removing a name is required, not optional.** When one is fixed the gate
# goes red for the opposite reason; see the loop at the end of `analyse`.
#
# # Where each of these came from
#
# All eight appeared the moment the scope filter came out, which is the whole
# argument for taking it out: every one of them had been in the tree, unread
# by this gate, since the arm was written.
#
#   `palette::request_toggle` -- one palette window for the process, posted to
#       `HWND_PALETTE`; which frame it opens over is decided elsewhere. With
#       two windows it can open over the one that did not ask.
#   `search::on_end`, `search::on_count` -- **the sharpest of the eight,
#       because the same feature already knows better.** `search::on_start` in
#       the arm above takes `target_surface(&target)`, with a comment saying
#       that without it "the host knows a search is open and not whose". End
#       and the two counts do not carry it, so a count can land on a search
#       belonging to another surface.
#   `keyseq::on_key_sequence`, `keyseq::on_key_table` -- one pending-key
#       indicator for the process, same shape as the palette.
#   `prompt::request_float` -- floating is a property of a *window*, and the
#       arm has `origin` in its hand when it calls this.
#   `reopen::redo_last` -- its twin `reopen::reopen_last(frame)` takes the
#       window. One pair, two answers; at most one of them is right.
OWED_ADDRESSLESS = {
    "ACTION_TOGGLE_COMMAND_PALETTE -> palette::request_toggle",
    "ACTION_END_SEARCH -> search::on_end",
    "ACTION_SEARCH_TOTAL -> search::on_count",
    "ACTION_SEARCH_SELECTED -> search::on_count",
    "ACTION_KEY_SEQUENCE -> keyseq::on_key_sequence",
    "ACTION_KEY_TABLE -> keyseq::on_key_table",
    "ACTION_FLOAT_WINDOW -> prompt::request_float",
    "ACTION_REDO -> reopen::redo_last",
}

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


def analyse(main_src: str, modules: dict[str, str], reconcile_bill: bool = False):
    """(problems, arms_seen, carrying_arms, exemptions).

    `reconcile_bill` turns on the "a name on the bill that is no longer owed
    is itself a failure" half. **Off for the canaries and on for the real
    tree**, because the bill names arms in `main.rs` and a fixture that
    contains none of them would report all eight as paid off -- which would
    make every self-test fail for a reason that has nothing to do with what it
    is testing. That is not hypothetical: it is what happened the first time
    this was wired up, and the message it produced named the wrong canary.
    """
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
    owed_seen: set[str] = set()
    for tag, _, text in arms:
        # **Every arm that notifies another module is in scope.** There used to
        # be a filter here -- `if "target_surface(" not in text: continue` --
        # and it is the reason this gate exists in the shape it now has. See
        # the module note; the short version is that an arm which resolved the
        # surface through a helper was not *failed* by that line, it was never
        # read, and nothing at either end said so.
        # **Calls are found in the blanked copy, arguments and reasons read
        # from the real one.** `strip_text` preserves length and offsets
        # character for character, so the two line up.
        #
        # ⚠️ This is not tidiness. Without it a *comment* that names a call --
        # `// ... it reads `winid::all()` itself` -- is parsed as a call, and
        # the exemption written above the real call gets attributed to the
        # imaginary one. That happened while task 288 was being written, in a
        # comment added by the same change, and the gate reported an exemption
        # for a function the arm never calls.
        blanked = strip_text(text)
        calls = [
            (c.group(1), c.group(2), split_args(text[c.end() :]), c.start())
            for c in re.finditer(r"\b(?:crate::)?(\w+)::(\w+)\s*\(", blanked)
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
                # **The wording no longer claims the arm resolved a
                # surface**, because under the rule above most of these have
                # not: the finding is that the notification has no address at
                # all, which is true whether or not this particular arm went
                # and looked one up.
                key = f"{tag} -> {mod}::{fn}"
                if key in OWED_ADDRESSLESS:
                    owed_seen.add(key)
                    continue
                problems.append(
                    f"{tag} notifies {mod}::{fn}({', '.join(params) or ''}), which "
                    f"has nowhere to put a terminal or a window. With two windows "
                    f"open, nothing in that call says which one it is about. Pass "
                    f"the surface or the frame, or write "
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

    # **A name on the bill that is no longer owed fails too.** Same reason
    # `action-arms-act.py` gives for its own list: a list that only ever
    # shrinks keeps a slot open for whatever takes that name next, and a slot
    # that outlives its reason is an exemption nobody granted.
    for key in sorted(set(OWED_ADDRESSLESS) - owed_seen) if reconcile_bill else []:
        problems.append(
            f"{key} is on the addressless bill and no longer needs to be -- "
            f"either it now carries an address, or the arm or call is gone. "
            f"Delete the line from OWED_ADDRESSLESS."
        )
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
# **The arm that started task 288.** It has the surface and hands it over, but
# it never writes `target_surface(` -- a helper does that. Under the filter
# this gate used to open with, this arm was not read at all, and the output
# was indistinguishable from the output for an arm that passed.
CANARY_MAIN_HELPER = CANARY_MAIN_BAD.replace(
    "let found = target_surface(&target).is_some_and(|s| tabs::mark(s));",
    "let surface = surface_key(&target);",
).replace("ctxmenu::on_mark(role, shielded)", "ctxmenu::on_mark(surface, role, shielded)")
# The same helper-shaped arm, but dropping the fact on the floor. This is the
# original defect wearing the clothes that used to make it invisible.
CANARY_MAIN_HELPER_BAD = CANARY_MAIN_BAD.replace(
    "let found = target_surface(&target).is_some_and(|s| tabs::mark(s));",
    "let surface = surface_key(&target);",
)
CANARY_MAIN_NO_SURFACE_EXEMPT = CANARY_MAIN_NO_SURFACE.replace(
    "            ctxmenu::on_mark(role, shielded);",
    "            // carries no terminal: it is one overlay for the process\n"
    "            ctxmenu::on_mark(role, shielded);",
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
    # ⚠️ **These four replaced an assertion that pinned the opposite rule**, and
    # the polarity is spelled out at each one because a reversed reading of a
    # green/red table is not visible in the table. What used to be here was
    #
    #     if probs(CANARY_MAIN_NO_SURFACE, CANARY_MODS_BAD): FAIL
    #
    # -- "an arm that resolves no surface must NOT be reported", which is the
    # whitelist default task 288 removed.
    #
    # (1) An arm that notifies without an address IS reported, whether or not
    #     it went and looked a surface up. This is the new rule, stated as the
    #     assertion that would fail if the filter came back.
    if not probs(CANARY_MAIN_NO_SURFACE, CANARY_MODS_BAD):
        print("FAIL: an arm that notifies a module with nowhere to put a terminal "
              "was not reported. If the scope filter came back, this is where.")
        sys.exit(2)
    # (2) ...and a written reason still excuses it. Without this the new
    #     default would have no way out and the gate would be red forever,
    #     which is the failure mode the bill exists to avoid.
    if probs(CANARY_MAIN_NO_SURFACE_EXEMPT, CANARY_MODS_BAD):
        print("FAIL: `// carries no terminal:` did not excuse an arm that has no "
              "surface to give.")
        sys.exit(2)
    # (3) An arm that resolves the surface through a helper and passes it is
    #     read and accepted. **This is the case the old filter could not see
    #     at all**, and seeing it is the whole of task 288.
    if probs(CANARY_MAIN_HELPER, CANARY_MODS_OK):
        print("FAIL: an arm that gets the surface from a helper and passes it on "
              "was reported.")
        sys.exit(2)
    if analyse(CANARY_MAIN_HELPER, CANARY_MODS_OK)[2] != 1:
        print("FAIL: an arm that gets the surface from a helper was not counted as "
              "carrying one. That is the exact reading that went 11 -> 12 instead "
              "of 11 -> 14 and looked correct.")
        sys.exit(2)
    # (4) ...and the same shape with the fact dropped IS reported. Without
    #     this one, (3) alone could be satisfied by a checker that reads
    #     nothing at all.
    if not probs(CANARY_MAIN_HELPER_BAD, CANARY_MODS_BAD):
        print("FAIL: an arm that gets the surface from a helper and then notifies "
              "without it was not reported.")
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

    problems, arms, carrying, exemptions = analyse(main_src, mods, reconcile_bill=True)
    print(f"scanned {arms} arms of `cb_action` against {len(mods)} modules "
          f"-- every arm that notifies one, not only those naming "
          f"`target_surface(`: {carrying} carry a surface into the notification")
    for e in exemptions:
        print(f"  exempt: {e}")
    # **Printed, not merely tolerated.** A bill nobody sees is an exemption
    # nobody granted, and the whole argument for keeping these out of the
    # failure list is that they stay visible instead.
    print(f"  {len(OWED_ADDRESSLESS)} call(s) still carry no address at all, "
          f"listed by name in OWED_ADDRESSLESS:")
    for key in sorted(OWED_ADDRESSLESS):
        print(f"    owed: {key}")
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
