#!/usr/bin/env python3
"""Nothing may reach a window's state without saying which window.

The host kept its whole model behind one `state()` that took no arguments and
handed back everything. Seventy-three call sites used it, and every one of them
was a place that had not been asked which window it meant -- while reading
exactly like a place that had. With one window they were all right. With two,
the first window is the answer to every question nobody asked.

`state()` is gone. There are three ways in, and each says what it can reach:

    window(frame)      one window, named
    shared()           the three process-wide fields, and *no* window
    with_windows(..)   a scan over every window, for a key that is unique in
                       the process (an HWND, a Surface, a PaneId)

**The compiler is the enumerator** -- a call that does not name a window does
not build. This file is the second reading, for the thing the compiler cannot
see: a fourth way in, added later, that takes no window and reaches one anyway.

It asserts **zero**, not seventy-three. Seventy-three was the number of call
sites the day the split was made; it changes with every batch, and a count
baked in here would go red once and then be edited to the new number by
whoever was in a hurry. Zero is the property.

Exit: 0 when every window-reaching entry point names a window or declares why
it does not; 1 otherwise.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TABS = os.path.join(HERE, "..", "host", "src", "tabs.rs")

# What counts as reaching the window list.
#
# **`with_windows` is in here too, and that is not belt-and-braces.** Widening
# it was the difference between catching `overlay_frame` and not: that function
# takes no window, calls `with_windows`, and returns the *first* one -- which
# is precisely the shape this whole cell exists to remove. A rule that only
# watched the raw lock would have let the next one of those through, because
# the next one will be written the way this one was.
REACHES = re.compile(r"\breg\(\)|\bwith_windows(?:_mut)?\s*\(")

# A function may be window-free if it says so on the line above, in the same
# shape `plogf!` declares a process-wide log line. The reason is required: a
# bare marker is a way to silence this without thinking, which is what a
# checker with an allowlist becomes.
FREE = re.compile(r"^\s*//\s*window-free:\s*\S")


def functions(src):
    """Yield (name, header_line_index, is_pub, takes_hwnd, body)."""
    lines = src.split("\n")
    for i, line in enumerate(lines):
        m = re.match(r"^(pub )?(?:#\[track_caller\]\s*)?fn (\w+)(.*)$", line)
        if not m:
            continue
        # Signature may wrap; gather until the opening brace.
        sig, j = line, i
        while "{" not in sig and j + 1 < len(lines):
            j += 1
            sig += lines[j]
        depth, body, k = 0, [], j
        for k in range(j, len(lines)):
            depth += lines[k].count("{") - lines[k].count("}")
            body.append(lines[k])
            if depth <= 0 and k > j:
                break
        # **Parameters only.** Looking for `HWND` anywhere in the signature
        # matched the *return* type, so `fn overlay_frame() -> HWND` -- which
        # takes no window and answers with the first one -- read as a function
        # that names its window. That is the exact shape being hunted, and the
        # check was blind to it.
        params = sig[sig.find("(") + 1 : sig.rfind(")")] if "(" in sig else ""
        yield (m.group(2), i, bool(m.group(1)), "HWND" in params, "\n".join(body))


def offenders(src):
    """Entry points that can reach the window list without naming a window."""
    lines = src.split("\n")
    out = []
    for name, at, is_pub, takes_hwnd, body in functions(src):
        if not REACHES.search(body):
            continue
        if name in ("reg", "with_windows", "with_windows_mut"):
            # The scan primitives themselves; they are declared below like
            # everything else, but they must not match on their own name.
            if name == "reg":
                continue
        if takes_hwnd:
            continue
        # **The contiguous comment block above, not just the line above.** A
        # reason worth writing is often two lines, and a checker that only
        # reads one of them teaches people to write one-line reasons -- or,
        # worse, to put the marker last so the tool sees it, which puts the
        # marker and the reason in the wrong order for a human. Attributes
        # (`#[track_caller]`) may sit between the block and the `fn`.
        declared = False
        k = at - 1
        while k >= 0:
            t = lines[k].strip()
            if t.startswith("#["):
                k -= 1
                continue
            if not (t.startswith("//") or t.startswith("///")):
                break
            if FREE.match(lines[k]):
                declared = True
                break
            k -= 1
        if declared:
            continue
        out.append((name, at + 1, is_pub))
    return out


# Negative control, both directions: a probe that cannot see the shape it was
# written for reports zero for the wrong reason.
CANARY_BAD = """
fn reg() -> Guard { }

pub fn state() -> Guard {
    reg()
}
"""
CANARY_OK = """
fn reg() -> Guard { }

pub fn window(frame: HWND) -> Option<WinGuard> {
    let g = reg();
}

// window-free: the three process-wide fields, and it cannot reach a window
pub fn shared() -> SharedGuard {
    SharedGuard { inner: reg() }
}
"""

bad = offenders(CANARY_BAD)
if [n for n, _, _ in bad] != ["state"]:
    print(f"FAIL: the probe cannot see a window-free accessor (saw {bad}).")
    sys.exit(1)
if offenders(CANARY_OK):
    print("FAIL: the probe fires on a named accessor or on a declared one.")
    sys.exit(1)
print("probe self-test: OK (sees an undeclared window-free accessor,")
print("                     ignores one that names a window and one that declares itself)")

with open(TABS, encoding="utf-8") as fh:
    src = fh.read()

# The literal check the criterion names, so a reintroduction under the old
# name is caught by its own spelling as well as by the rule above.
if re.search(r"^\s*(pub )?fn state\(\s*\)", src, re.M):
    print("FAIL: `fn state()` is back. It is the function this cell removed:")
    print("      it hands out a window's state to a caller that named none.")
    sys.exit(1)

found = offenders(src)
free_count = len(re.findall(r"^\s*//\s*window-free:", src, re.M))
print(f"tabs.rs: {free_count} entry point(s) declared window-free, with a reason")
for name, ln, is_pub in found:
    print(f"  tabs.rs:{ln}  {'pub ' if is_pub else ''}fn {name} reaches the window list "
          f"and names no window")

print(f"\n{len(found)} accessor(s) can reach a window without naming one.")
if found:
    print(
        "FAIL: an accessor that takes no window still answers for one -- and the\n"
        "      window it answers for is whichever happens to be first. Take an\n"
        "      `HWND`, or write `// window-free: <reason>` above it if it\n"
        "      genuinely reaches no window (`shared`), or scans all of them for a\n"
        "      process-unique key (`with_windows`)."
    )
    sys.exit(1)
print("none: every way into the model names a window, scans all of them, or says why not.")
sys.exit(0)
