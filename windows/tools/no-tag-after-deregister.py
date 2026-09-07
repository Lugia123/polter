#!/usr/bin/env python3
"""Asking for a window's number after taking it out of the register.

    pub fn window_finished(frame: HWND) {
        let left = destroyed(frame);          // removes it from FRAMES
        ...
        crate::wlogf!(frame, "[win] {} window(s) remain; ...", left);
    }

`wlogf!` resolves the number through `winid::of`, `of` answers from `FRAMES`,
and `destroyed` has just taken the entry out. So `tag` returns `w?` and the
line about the second-to-last window goes into the log with no window on it.
Read off the machine: `1 window(s) remain` printed as `w?`, and it was about
`w1`.

**The rule was already known one function down.** `destroyed` itself reads
`of(frame)` before its `retain` and carries a comment saying why -- *"Read
before the removal, and that ordering is now load-bearing ... after the
`retain` below this frame has no number at all and this line would say
`w0`."* The knowledge existed, it was written down, and it was re-broken one
call up. That is what this gate is for: a rule a person learned once does not
carry to the next site by itself.

# Why a missing number is worse here than it looks

Every window-tagged line in this log is a reader's only handle on *which*
terminal a fact belongs to. One line that says `w?` does not read as broken --
it reads as a line about something else, or gets attributed to whichever
window the reader had in mind. **An unreadable line is worse than a missing
one**, because a missing line is noticed.

# What this checks

Inside one function: a call to `winid::destroyed(x)` followed by a
window-tagged log (`wlogf!(x, ...)`) or a `tag(x)`/`of(x)` using the **same**
handle. The fix is either to take the tag before the removal, or -- when the
sentence is really about the process rather than about the window that just
went -- to say so with `plogf!` and a `// process-wide:` reason.

**NOT CHECKED:**

  * the same shape across function boundaries. A caller that deregisters and
    then hands the handle to something that logs is invisible here.
  * any other way a number goes missing. `of` returns 0 for a handle that was
    never registered and for one that is not a window at all, and neither is
    this.
  * whether the tag that *is* printed is the right one.

Run:  python3 windows/tools/no-tag-after-deregister.py
Exit: 0 when no function asks for a number it has just removed.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "host", "src"))

DEREGISTER = re.compile(r"\b(?:winid::)?destroyed\s*\(\s*(\w+)\s*\)")
TAGGED = re.compile(r"\bwlogf!\s*\(\s*(\w+)\s*,|\b(?:winid::)?(?:tag|of)\s*\(\s*(\w+)\s*\)")


def strip_comments(text: str) -> str:
    """Comments out. The prose in this repository quotes these calls by name."""
    return re.sub(r"//[^\n]*", "", text)


def fns(src: str):
    """`(name, body, line)` for every `fn`, by brace matching."""
    for m in re.finditer(r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*[(<]", src):
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
        yield m.group(1), src[brace : k + 1], src.count("\n", 0, m.start()) + 1


def before_tests(src: str) -> str:
    """The file down to its first `#[cfg(test)]`.

    **A test that names a deregistered window on purpose is not this defect.**
    `winid.rs` has one whose whole point is to call `tag` three times after
    `destroyed` and assert the count did not move -- it is the floor for the
    rule that naming a gone window must not re-register it. The first run of
    this gate reported it, and it read exactly like a finding because it is
    made of the same two calls in the same order. The difference is what
    happens to the answer: a test asserts on it, a log line prints it.
    """
    return src.split("#[cfg(test)]")[0]


def analyse(files: dict):
    bad = []
    looked = 0
    for name, src in sorted(files.items()):
        code = strip_comments(before_tests(src))
        for fn, body, line in fns(code):
            drops = [(m.group(1), m.end()) for m in DEREGISTER.finditer(body)]
            if not drops:
                continue
            looked += 1
            for handle, at in drops:
                for m in TAGGED.finditer(body[at:]):
                    used = m.group(1) or m.group(2) or m.group(3)
                    if used != handle:
                        continue
                    bad.append(
                        f"{name}:{line}: `{fn}` takes `{handle}` out of the "
                        "register with `destroyed`, then asks for its number "
                        "again. `of` answers from that register, so the number "
                        "is gone and the line prints `w?` -- about a window it "
                        "cannot name. Take the tag before the removal, or say "
                        "`plogf!` with a `// process-wide:` reason if the "
                        "sentence is about the process.")
                    break
    return bad, looked


# -- self-test ---------------------------------------------------------------

BROKEN = {"winid.rs": '''
pub fn window_finished(frame: HWND) {
    let left = destroyed(frame);
    if left == 0 { post_quit(); } else {
        crate::wlogf!(frame, "[win] {} window(s) remain; the process stays", left);
    }
}
'''}
TAG_FIRST = {"winid.rs": '''
pub fn window_finished(frame: HWND) {
    let w = tag(frame);
    let left = destroyed(frame);
    if left == 0 { post_quit(); } else {
        crate::logf!("{} [win] {} window(s) remain", w, left);
    }
}
'''}
PROCESS_WIDE = {"winid.rs": '''
pub fn window_finished(frame: HWND) {
    let left = destroyed(frame);
    if left == 0 { post_quit(); } else {
        crate::plogf!("[win] {} window(s) remain; the process stays", left);
    }
}
'''}
IN_A_TEST = {"winid.rs": '''
pub fn nothing() {}
#[cfg(test)]
mod tests {
    #[test]
    fn naming_a_destroyed_window_does_not_put_it_back() {
        assert_eq!(destroyed(w1), 1);
        let _ = tag(w1);
    }
}
'''}

OTHER_HANDLE = {"winid.rs": '''
pub fn window_finished(frame: HWND) {
    let left = destroyed(frame);
    crate::wlogf!(other, "[win] {} window(s) remain", left);
}
'''}

for sample, want_red, label in (
    (BROKEN, True, "a tagged log after the handle was deregistered"),
    (TAG_FIRST, False, "taking the tag before the removal"),
    (PROCESS_WIDE, False, "saying the sentence is about the process instead"),
    (IN_A_TEST, False,
     "a test that names a deregistered window on purpose -- which is the "
     "floor for the rule, not a breach of it. Measured: the first run of this "
     "gate reported `winid.rs`'s own test"),
    (OTHER_HANDLE, False, "a tagged log about a *different*, still-registered window"),
):
    got = bool(analyse(sample)[0])
    if got != want_red:
        print(f"FAIL: the probe {'misses' if want_red else 'fires on'} {label}.")
        sys.exit(1)

# -- the tree ----------------------------------------------------------------

files = {}
if os.path.isdir(SRC):
    for name in sorted(os.listdir(SRC)):
        if name.endswith(".rs"):
            with open(os.path.join(SRC, name), encoding="utf-8") as fh:
                files[name] = fh.read()

problems, looked = analyse(files)
print(f"read {len(files)} file(s); {looked} function(s) deregister a window")

# **Subject-set guard.** No deregistering function is not a clean tree, it is
# a gate that found nothing to look at -- and it prints the same all-clear.
if looked == 0:
    print()
    print("FAIL: no function calls `destroyed`, so there was nothing to check. "
          "Not a pass.")
    sys.exit(1)

if not problems:
    print("OK: no function asks for a window number it has just removed.")
    print("NOT CHECKED: the same shape across function boundaries, and any "
          "other way a number goes missing.")
    sys.exit(0)

print()
for line in problems:
    print("  " + line)
print()
print(f"FAIL: {len(problems)} line(s) that will print `w?`.")
sys.exit(1)
