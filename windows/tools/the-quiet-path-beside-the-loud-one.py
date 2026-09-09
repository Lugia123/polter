#!/usr/bin/env python3
"""Five failure paths that now use the loud path already beside them.

# The family

Task 486 swept `windows/host/` for one shape: a module that already has a way
of saying a thing went wrong, and a second path through the same code that
fails without using it. Eleven were found; these are the five that were fixed,
and this file is what stops each one going quiet again.

**Each rule names the loud path it is protecting**, because the fix in every
case was to reuse something that was already there -- no new machinery, and
therefore nothing that reads as new machinery when it is removed.

# NOT CHECKED

  * **That the words are the right words.** A rule here can tell that a line
    exists and that it is not the neighbouring line's; whether a reader can
    act on it is not something a regex knows.
  * **That the failure it reports can actually happen on a real machine.**
    None of these five have been seen fire; they are paths whose silence was
    the finding, not paths known to be taken.
  * **The other six from that sweep**, which are still open: two in `winnav`
    and four listed as doubtful.

# On writing the strings

The literals a rule matches are **assembled here rather than spelled out**,
and the prose above never writes one whole. A checker whose own text contains
what it looks for goes green on a file that has lost the thing entirely; that
has cost this project several rounds, most recently on the import line for
`SetThreadDescription`, which spelled the symbol a rule was hunting for.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "host", "src")

# Assembled, never written whole -- see the note above.
NOT_QUEUED = "; not " + "queued"
NOT_RUN = "; not " + "run"
DROPPED_OLDEST = "dropped " + "oldest"
VALUE_SET = "value" + "_set="
FRAMECHANGED = "frame" + "changed="
STAYED_IN_SCREEN = "stayed in " + "screen coordinates"


def strip_comments(src):
    """Comments out, so a rule cannot be satisfied by prose about it.

    Crude on purpose: it is a line-wise removal of `//` to end of line, which
    over-deletes inside a string literal that contains a double slash. No line
    any rule here looks for has one.
    """
    return "\n".join(re.sub(r"//.*", "", ln) for ln in src.split("\n"))


def body_of(src, header):
    """The text from `header` to the end of the function it starts.

    Braces are counted on the comment-stripped text, so a `{` inside a comment
    cannot end a body early.
    """
    i = src.find(header)
    if i < 0:
        return None
    depth = 0
    started = False
    for j in range(i, len(src)):
        c = src[j]
        if c == "{":
            depth += 1
            started = True
        elif c == "}":
            depth -= 1
            if started and depth == 0:
                return src[i : j + 1]
    return src[i:]


def binding_of(body, var):
    """The initialiser of `let <var> = ...;`, braces and parens balanced.

    ⚠️ **Why a rule needs this and not just the field name.** A rule that
    asserts the field is printed is satisfied by a field printing a constant:

        let ok = true;
        let _unused = unsafe { TheCall(..) };

    -- the call still there, its answer thrown away, the line unchanged, and
    nothing red. That is not a hypothetical; it was built against this file
    and it worked. Naming the discard form does not close it either, because
    the discard can be spelled any number of ways. **The assertion has to be
    that the printed variable comes from the call**, which is what this reads.
    """
    m = re.search(r"let\s+(?:mut\s+)?" + re.escape(var) + r"\s*(?::[^=]*)?=", body)
    if not m:
        return None
    depth = 0
    for j in range(m.end(), len(body)):
        c = body[j]
        if c in "{([":
            depth += 1
        elif c in "})]":
            depth -= 1
        elif c == ";" and depth == 0:
            return body[m.end():j]
    return body[m.end():]


def findings(sources):
    out = []

    def plain(name):
        return strip_comments(sources.get(name, ""))

    # ---- #5 `run_ops`: the drain's refusal, told apart from the way in's.
    tabs = plain("tabs.rs")
    run_ops = body_of(tabs, "pub fn run_ops(")
    if run_ops is None:
        out.append("tabs.rs: `run_ops` is gone; the rule below cannot be applied")
    else:
        if NOT_RUN not in run_ops:
            out.append(
                "tabs.rs `run_ops`: the drain returns without saying so. The way in "
                "refuses with a line and this is the way out; a queue that accepted "
                "work and never answers reads as a pump that stopped dispatching, "
                "which is a different fault entirely"
            )
        if NOT_QUEUED in run_ops:
            out.append(
                "tabs.rs `run_ops`: it refuses in the way in's words. The two have to "
                "differ by their verb or a reader cannot tell which half went quiet"
            )
    if NOT_QUEUED not in tabs:
        out.append("tabs.rs: `post_op`'s refusal is gone; there is no loud path left to match")

    # ---- #3 `on_nc_right_click`: the conversion is one of the refusals.
    nc = body_of(plain("strip.rs"), "pub fn on_nc_right_click(")
    if nc is None:
        out.append("strip.rs: `on_nc_right_click` is gone; the rule below cannot be applied")
    else:
        if "let _ = ScreenToClient(" in nc or "let _ = unsafe { ScreenToClient(" in nc:
            out.append(
                "strip.rs `on_nc_right_click`: the coordinate conversion is discarded "
                "again. On failure the point stays in screen space and the test below "
                "refuses it for being past the strip -- one of this function's own "
                "real refusals, standing in for a failure with no name of its own"
            )
        if STAYED_IN_SCREEN not in nc:
            out.append(
                "strip.rs `on_nc_right_click`: the conversion has no refusal of its own"
            )
        conv = binding_of(nc, "converted")
        if conv is None or "ScreenToClient(" not in conv:
            out.append(
                "strip.rs `on_nc_right_click`: the flag the refusal turns on does not come "
                "from the conversion call. A constant here leaves the refusal in place and "
                "unreachable, which reads exactly like the conversion never failing"
            )

    # ---- #4 the redo side of the bound says what it dropped.
    reopen = plain("reopen.rs")
    note = body_of(reopen, "pub fn note_reopened(")
    if note is None:
        out.append("reopen.rs: `note_reopened` is gone; the rule below cannot be applied")
    elif DROPPED_OLDEST not in note:
        out.append(
            "reopen.rs `note_reopened`: the redo stack drops its oldest entry without "
            "a word. The undo side has said it since it was written, and states why on "
            "the line: the bound working and an entry going missing look the same from "
            "the far side"
        )
    if note is not None:
        drop = binding_of(note, "dropped")
        if drop is None or ".remove(" not in drop:
            out.append(
                "reopen.rs `note_reopened`: the entry the line names does not come from the "
                "removal, so the line can go on naming something that was not dropped"
            )
    if reopen.count(DROPPED_OLDEST) < 2:
        out.append(
            "reopen.rs: only one half of the bound reports what it dropped; both do"
        )

    # ---- #1 the progress value is reported beside the state.
    apply_body = body_of(plain("taskbar.rs"), "fn apply(job: Job)")
    if apply_body is None:
        out.append("taskbar.rs: `apply` is gone; the rule below cannot be applied")
    else:
        if "let _ = unsafe { list.SetProgressValue(" in apply_body:
            out.append(
                "taskbar.rs `apply`: the progress value's result is discarded again, two "
                "lines from a sibling that is matched and reported. The bar then keeps "
                "the previous number while the line names the new one"
            )
        if VALUE_SET not in apply_body:
            out.append("taskbar.rs `apply`: the value's fate is not on either outcome line")
        vs = binding_of(apply_body, "value_set")
        if vs is None or "SetProgressValue(" not in vs:
            out.append(
                "taskbar.rs `apply`: the field on the outcome lines does not come from the "
                "call it is about. Printed from a constant it reports a success nobody "
                "measured, which is worse than the silence it replaced"
            )

    # ---- #2 the frame-changed call joins the line that reports the rest.
    init = body_of(plain("shell.rs"), "pub fn init_frame(")
    if init is None:
        out.append("shell.rs: `init_frame` is gone; the rule below cannot be applied")
    else:
        # ⚠️ **The `unsafe` block is part of the shape.** The first draft
        # matched only the bare form, and the call here sits inside an
        # `unsafe { .. }` -- so the mutation that put the result back into a
        # discard compiled and this rule stayed green. Both spellings, and the
        # same reading applied to the sibling rules above.
        if re.search(r"let\s+_\s*=\s*(unsafe\s*\{\s*)?SetWindowPos\(", init):
            out.append(
                "shell.rs `init_frame`: the frame-changed call is discarded again. Every "
                "attribute above it can be reported as set while nothing on screen moves, "
                "which is what a build too old for those attributes also looks like"
            )
        if FRAMECHANGED not in init:
            out.append("shell.rs `init_frame`: its result is not on the line that reports the rest")
        fc = binding_of(init, "ok_framechanged")
        if fc is None or "SetWindowPos(" not in fc:
            out.append(
                "shell.rs `init_frame`: the field on that line does not come from the call "
                "it is about. Printed from a constant it joins five measured answers with "
                "one asserted one, and nothing on the line says which is which"
            )
    return out


GOOD = {
    "tabs.rs": '''
pub fn post_op(frame: HWND, op: Op, from: &'static str) {
    plogf!("[ops] {} from {} names no live window ({:?}); not queued", name, from, frame.0);
}
pub fn run_ops(frame: HWND) {
    let Some(mut w) = window(frame) else {
        crate::plogf!("[ops] #{}: {:?} names no live window; not run", n, frame.0);
        return;
    };
}
''',
    "strip.rs": '''
pub fn on_nc_right_click(frame: HWND, x: i32, y: i32) -> bool {
    let converted = unsafe { ScreenToClient(frame, &mut pt) }.as_bool();
    let refused: Option<&str> = if !converted {
        Some("the point stayed in screen coordinates")
    } else { None };
}
''',
    "reopen.rs": '''
pub fn remember(frame: HWND) {
    plogf!("[reopen] dropped oldest {:?} to stay at {}", d.chosen_title, LIMIT);
}
pub fn note_reopened(frame: HWND, id: TabId) {
    while r.len() > LIMIT {
        let dropped = r.remove(0);
        plogf!("[redo] dropped oldest {:?} to stay at {}", dropped.tab, LIMIT);
    }
}
''',
    "taskbar.rs": '''
fn apply(job: Job) {
    let value_set = match pct { Some(p) => Some(unsafe { list.SetProgressValue(h, p, 100) }.is_ok()), _ => None };
    match unsafe { list.SetProgressState(h, f) } {
        Ok(()) => wlogf!(h, "[taskbar] progress value_set={value_set:?} shown"),
        Err(e) => wlogf!(h, "[taskbar] failed: {e:?} (value_set={value_set:?})"),
    }
}
''',
    "shell.rs": '''
pub fn init_frame(hwnd: HWND) {
    let ok_framechanged = unsafe { SetWindowPos(hwnd, None, 0, 0, 0, 0, SWP_FRAMECHANGED) }.is_ok();
    logf!("[shell] extend={} framechanged={}", ok_extend, ok_framechanged);
}
''',
}


def self_test():
    def case(**over):
        s = dict(GOOD)
        s.update(over)
        return s

    prose_only = dict(GOOD)
    # ⚠️ The shape that has cost this project several rounds: the line is gone
    # and a comment in its place spells what the rule looks for.
    prose_only["shell.rs"] = GOOD["shell.rs"].replace(
        'let ok_framechanged = unsafe { SetWindowPos(hwnd, None, 0, 0, 0, 0, SWP_FRAMECHANGED) }.is_ok();\n'
        '    logf!("[shell] extend={} framechanged={}", ok_extend, ok_framechanged);',
        '// this used to report framechanged= on the line below\n'
        '    let _ = SetWindowPos(hwnd, None, 0, 0, 0, 0, SWP_FRAMECHANGED);\n'
        '    logf!("[shell] extend={}", ok_extend);',
    )

    cases = [
        ("the shape today", case(), 0),
        ("the drain going quiet again",
         case(**{"tabs.rs": GOOD["tabs.rs"].replace(
             'crate::plogf!("[ops] #{}: {:?} names no live window; not run", n, frame.0);\n        ', "")}), 1),
        ("the drain wearing the way in's words",
         case(**{"tabs.rs": GOOD["tabs.rs"].replace(
             '{:?} names no live window; not run', '{:?} names no live window; not queued')}), 2),
        # Two findings, not one: the drain has lost its own words *and* taken
        # the way in's. Both are true of that mutation and both are worth
        # printing, so the expected count is what the rules actually say.
        ("the conversion discarded again",
         case(**{"strip.rs": GOOD["strip.rs"]
                 .replace('let converted = unsafe { ScreenToClient(frame, &mut pt) }.as_bool();',
                          'let _ = unsafe { ScreenToClient(frame, &mut pt) };')
                 .replace('if !converted {\n        Some("the point stayed in screen coordinates")\n    } else {',
                          'if false {\n        Some("x")\n    } else {')}), 3),
        ("the redo side dropping in silence",
         case(**{"reopen.rs": GOOD["reopen.rs"].replace(
             '        plogf!("[redo] dropped oldest {:?} to stay at {}", dropped.tab, LIMIT);\n', "")}), 2),
        ("the progress value discarded again",
         case(**{"taskbar.rs": GOOD["taskbar.rs"].replace(
             'let value_set = match pct { Some(p) => Some(unsafe { list.SetProgressValue(h, p, 100) }.is_ok()), _ => None };',
             'let _ = unsafe { list.SetProgressValue(h, p, 100) };')
             .replace(' value_set={value_set:?}', '').replace(' (value_set={value_set:?})', '')}), 3),
        # Three, not two: the line lost the field *and* the flag stopped
        # coming from the call, which are two separate things to have lost.
        ("the frame-changed call discarded again", prose_only, 3),
        # ⚠️ The exact mutation the first draft of the rule above missed:
        # the discard wrapped in the `unsafe` block the real call sits in.
        ("the frame-changed call discarded inside its unsafe block",
         case(**{"shell.rs": GOOD["shell.rs"]
                 .replace("let ok_framechanged = unsafe { SetWindowPos(hwnd, None, 0, 0, 0, 0, SWP_FRAMECHANGED) }.is_ok();",
                          "let ok_framechanged = true;\n    let _ = unsafe { SetWindowPos(hwnd, None, 0, 0, 0, 0, SWP_FRAMECHANGED) };")}), 2),
        # ⚠️ ⭐ **The hole a reviewer built against the first version of this
        # file, and it worked**: the call stays, its answer is thrown away
        # under a name that is not `_`, the flag becomes a constant, and the
        # log line is not touched at all. Every earlier rule here was happy --
        # the field was printed, and the discard was not spelled the one way
        # they knew. This is the decoy in its real shape, one cell per site.
        ("the frame-changed flag printed from a constant",
         case(**{"shell.rs": GOOD["shell.rs"].replace(
             "let ok_framechanged = unsafe { SetWindowPos(hwnd, None, 0, 0, 0, 0, SWP_FRAMECHANGED) }.is_ok();",
             "let ok_framechanged = true;\n    let _unused = unsafe { SetWindowPos(hwnd, None, 0, 0, 0, 0, SWP_FRAMECHANGED) };")}), 1),
        ("the progress value printed from a constant",
         case(**{"taskbar.rs": GOOD["taskbar.rs"].replace(
             "let value_set = match pct { Some(p) => Some(unsafe { list.SetProgressValue(h, p, 100) }.is_ok()), _ => None };",
             "let value_set = Some(true);\n    let _unused = unsafe { list.SetProgressValue(h, p, 100) };")}), 1),
        ("the conversion flag set from a constant",
         case(**{"strip.rs": GOOD["strip.rs"].replace(
             "let converted = unsafe { ScreenToClient(frame, &mut pt) }.as_bool();",
             "let converted = true;\n    let _unused = unsafe { ScreenToClient(frame, &mut pt) };")}), 1),
        ("the redo line naming something it did not remove",
         case(**{"reopen.rs": GOOD["reopen.rs"].replace(
             "let dropped = r.remove(0);", "let dropped = r[0].clone();")}), 1),
        ("the loud path it copies being deleted",
         case(**{"tabs.rs": GOOD["tabs.rs"].replace(
             ' names no live window ({:?}); not queued', ' has no window ({:?})')}), 1),
    ]
    ok = True
    for what, sources, want in cases:
        got = findings(sources)
        if len(got) != want:
            print(f"probe self-test FAILED: {what} gave {len(got)} finding(s), expected {want}:")
            for f in got:
                print(f"    {f}")
            ok = False
    if ok:
        print("probe self-test: OK (each of the five going quiet again, the drain wearing "
              "the way in's words, a comment left in place of a deleted line, and the loud "
              "path itself being deleted, a discard hidden in an unsafe block, and each of "
              "the four printed fields coming from a constant instead of its call)")
    return ok


def main():
    if not self_test():
        return 1
    sources = {}
    try:
        for name in sorted(os.listdir(SRC)):
            if name.endswith(".rs"):
                with open(os.path.join(SRC, name), encoding="utf-8") as fh:
                    sources[name] = fh.read()
    except OSError as e:
        print(f"cannot read the host sources: {e}")
        return 1

    found = findings(sources)
    print("5 quiet paths from task 486, each protected by the loud path already beside it.")
    print("NOT CHECKED: that the words read well, that any of the five can fire on a real "
          "machine, and the six from that sweep that are still open.")
    for f in found:
        print(f"HIT    {f}")
    if found:
        print(f"\n{len(found)} problem(s): a path went quiet again.")
        return 1
    print("OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
