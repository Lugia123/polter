#!/usr/bin/env python3
"""A call that can never return must say so before it is made, not after.

**The incident.** Ctrl+click on an OSC 8 link and the main thread stopped
forever. What the log had to say about it was **nothing at all**:
`links.rs`'s `on_open_url` wrote a line on every way *out* -- no URL, refused,
and the result after `ShellExecuteW` returned -- and not one byte on the way
in. So "it went in and never came out" was not something the log said; it was
something somebody worked out from the fact that none of the exit lines were
there, which took half an hour and two process dumps.

**The absence of a line is the same shape for three different things**: the
click never arrived, the URL was refused by a branch that forgot to log, or
the call is still running. One line written *before* the call tells all three
apart on sight, and it costs one `write_all`.

# The rule

Every `ShellExecuteW` call site in `windows/host/src` must be preceded, in the
same function, by a log line **that names the call**. Naming it is the point:
a generic line above the call says a click was handled, and the reader still
has to know that this is the last thing before a call that can hang. A line
that says which call it is about, and what its being the last line means,
turns the diagnosis into a read.

`ShellExecuteW` is the subject because it is what the incident was, and
because it is a genuinely unbounded call: it enters the shell, which may start
a process, load handlers, or put up UI of its own, and this host has no
timeout on it.

# What task 324 changed, and why this gate did not become pointless

**It no longer runs on the window thread.** 292's cause turned out to be two
adjacent opens where the first is cold (~155 ms against 14 ms warm), both
hangs stopping at a byte-identical `ntdll.dll+0x163fd4`; the repair was to
stop the thread that owns every window from waiting for it. So the sentence
"this hangs the application" is no longer what a missing line costs.

**The rule survives the repair, and it is worth saying why rather than
assuming it.** What the announcement buys is now *attribution*: the call runs
on a worker nobody is watching, so if it never returns there is no window
freezing to notice and no exception to catch -- there is a thread that is
simply not there any more. The line before it is the only thing that says a
worker went out, and the absent "returned" line is the only thing that says it
did not come back. **A silence that used to be loud is now completely quiet,
which makes the announcement matter more rather than less.**

The subject set shrank from three call sites to one: `links.rs`, `osk.rs` and
`main.rs`'s `open_config` arm all go through `shellopen::detached` now. If a
later change removes that one too, the subject-set guard at the bottom fails
rather than reporting a clean tree -- **a gate with nothing left to look at
must not be able to pass**, which is the shape this directory exists for.

**NOT CHECKED, and the second one is the bigger hole:**

  * that the line is written before the call *at runtime*. Reading the source
    cannot see a logger that buffers, and this host's does not -- `log_line`
    opens, writes and flushes per record -- but that is a fact about another
    file, not something this gate reads.
  * **every other call on the main thread that can block forever.** This gate
    knows one name. `SendMessageW` to a window in another process, a modal
    dialog, a COM call into a shell extension, a synchronous read from a pipe
    -- all of them have this shape, and none of them are in this subject set.
    A green here means "the call we already got burned by announces itself",
    not "the main thread cannot hang silently".

Run:  python3 windows/tools/blocking-call-says-so-first.py
Exit: 0 when every ShellExecuteW call announces itself first.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "host", "src"))

CALL = "ShellExecuteW"
LOG = re.compile(r"\b(alogf|wlogf|plogf|logf|hlogf)!\s*\(")
# How far above the call a line may sit and still be "before it". Generous,
# because the call is usually wrapped in `unsafe {` and a few argument lines.
REACH = 18


def strip_comments(text: str) -> str:
    """Comments out, **string bodies kept**.

    The opposite of what most of these gates do, and deliberately: the thing
    being checked is what the log line *says*, which lives inside a string. A
    comment mentioning the call must not count as announcing it -- that is the
    exact failure the reason comments in this directory are prone to.
    """
    return re.sub(r"//[^\n]*", "", text)


def call_sites(src: str):
    """Line numbers of real `ShellExecuteW` calls -- not the `use` that imports
    it, and not a mention in a comment."""
    clean = strip_comments(src)
    for m in re.finditer(re.escape(CALL) + r"\s*\(", clean):
        line = clean.count("\n", 0, m.start()) + 1
        start = clean.rfind("\n", 0, m.start()) + 1
        if clean[start : m.start()].lstrip().startswith("use "):
            continue
        yield line


def enclosing_fn(src: str, line: int) -> str:
    """The body of the `fn` that contains `line`.

    **The window used to be a fixed number of lines above the call, and task
    324 broke that** without breaking anything real: the announcement is now
    written before the worker is spawned and the call happens inside the
    closure, forty lines down. The two are still in one function, and one
    function is what "before this call" actually means -- a line count was
    always a proxy for it, and the proxy is what went wrong.
    """
    clean = strip_comments(src)
    at = 0
    for m in re.finditer(r"\bfn\s+[A-Za-z_][A-Za-z0-9_]*\s*[(<]", clean):
        if clean.count("\n", 0, m.start()) + 1 <= line:
            at = m.start()
        else:
            break
    brace = clean.find("{", at)
    if brace < 0:
        return clean
    depth, k = 0, brace
    while k < len(clean):
        if clean[k] == "{":
            depth += 1
        elif clean[k] == "}":
            depth -= 1
            if depth == 0:
                return clean[brace : k + 1]
        k += 1
    return clean[brace:]


def announced(src: str, line: int) -> bool:
    """Is there a log call naming `ShellExecuteW` **before** it, same function?

    **Both halves, and the second one was briefly lost.** Widening the window
    from "the lines above" to "the enclosing function" made the function's
    *result* line -- `ShellExecuteW returned {} in {}ms` -- count as the
    announcement, because it names the call too. That is the exact defect this
    gate exists for: 292's whole point was that every line was written on a
    way *out*, and a check that accepts one of them has stopped asking the
    question. Measured: a mutation blanking the real announcement left this
    green until the position test below was added.
    """
    window = enclosing_fn(src, line)
    call_at = window.find(CALL + "(")
    if call_at < 0:
        call_at = len(window)
    for m in LOG.finditer(window):
        if m.start() > call_at:
            continue
        # **The macro's own arguments, matched by parentheses -- not "the next
        # 600 characters".** Once the search window became the whole function
        # it contained the call itself, and a lookahead by length then counted
        # `ShellExecuteW(` *the call* as if it were the announcement naming
        # it: a generic line above a call passed. Measured, on this file's own
        # `GENERIC_LINE` sample, the moment the window changed.
        depth, k = 0, m.end() - 1
        while k < len(window):
            if window[k] == "(":
                depth += 1
            elif window[k] == ")":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        if CALL in window[m.end() : k]:
            return True
    return False


def analyse(files: dict):
    bad = []
    sites = 0
    for name, src in sorted(files.items()):
        for line in call_sites(src):
            sites += 1
            if not announced(src, line):
                bad.append(
                    f"{name}:{line}: `{CALL}` is called with nothing in the "
                    "same function saying so. It can take as long as the shell "
                    "takes and, on the path task 292 found, can stop returning "
                    "at all; when it does, the silence looks exactly like a "
                    "click that never arrived and like a branch that refused "
                    "without logging. Write the line before the call, and have "
                    "it name the call.")
    return bad, sites


# -- self-test ---------------------------------------------------------------

SILENT = {"links.rs": '''
pub fn on_open_url(frame: Option<HWND>, kind: i32, url: Option<String>) -> bool {
    let target = expand_home(url.trim());
    let ok = shell_open(&target);
    wlogf!(f, "[link] open_url kind={kind} {target:?} -> {ok}");
    ok
}
fn shell_open(url: &str) -> bool {
    let r = unsafe { ShellExecuteW(None, w!("open"), PCWSTR(wide.as_ptr()), n, n, SW_SHOWNORMAL) };
    r.0 as usize > 32
}
'''}

GENERIC_LINE = {"links.rs": '''
fn shell_open(url: &str) -> bool {
    wlogf!(f, "[link] opening a URL");
    let r = unsafe { ShellExecuteW(None, w!("open"), PCWSTR(wide.as_ptr()), n, n, SW_SHOWNORMAL) };
    r.0 as usize > 32
}
'''}

ANNOUNCED = {"links.rs": '''
fn shell_open(url: &str) -> bool {
    wlogf!(f, "[link] handing {url:?} to ShellExecuteW on the main thread; if this is the last line, it did not return");
    let r = unsafe { ShellExecuteW(None, w!("open"), PCWSTR(wide.as_ptr()), n, n, SW_SHOWNORMAL) };
    r.0 as usize > 32
}
'''}

COMMENT_ONLY = {"links.rs": '''
fn shell_open(url: &str) -> bool {
    // about to call ShellExecuteW, which can block the main thread
    let r = unsafe { ShellExecuteW(None, w!("open"), PCWSTR(wide.as_ptr()), n, n, SW_SHOWNORMAL) };
    r.0 as usize > 32
}
'''}

IMPORT_ONLY = {"links.rs": "use windows::Win32::UI::Shell::ShellExecuteW;\n"}

if not analyse(SILENT)[0]:
    print("FAIL: the probe cannot see a call with no line above it -- which is "
          "the state that cost half an hour and two dumps.")
    sys.exit(1)
if not analyse(GENERIC_LINE)[0]:
    print("FAIL: the probe accepts a line that does not name the call. A reader "
          "then still has to know that this line is the last thing before "
          "something that can hang, which is the knowledge the line exists to "
          "replace.")
    sys.exit(1)
if analyse(ANNOUNCED)[0]:
    print("FAIL: the probe rejects a call that announces itself by name -- it "
          "would be edited away within a day.")
    sys.exit(1)
if not analyse(COMMENT_ONLY)[0]:
    print("FAIL: the probe counts a *comment* naming the call as an "
          "announcement. A comment is not in the log.")
    sys.exit(1)
if analyse(IMPORT_ONLY)[1] != 0:
    print("FAIL: the probe counts the `use` that imports the function as a call "
          "site, so it would demand a log line above an import.")
    sys.exit(1)

# -- the tree ----------------------------------------------------------------

files = {}
if os.path.isdir(SRC):
    for name in sorted(os.listdir(SRC)):
        if name.endswith(".rs"):
            with open(os.path.join(SRC, name), encoding="utf-8") as fh:
                files[name] = fh.read()

problems, sites = analyse(files)
print(f"read {len(files)} file(s); {sites} `{CALL}` call site(s)")

# **Subject-set guard.** Zero call sites is not a clean tree, it is a gate
# that read nothing -- and it would print its all-clear either way.
if not files or sites == 0:
    print()
    print(f"FAIL: no `{CALL}` call site was found, so there was nothing to "
          "check. Not a pass.")
    sys.exit(1)

if not problems:
    print(f"OK: every `{CALL}` call names itself in the log before it runs.")
    print("NOT CHECKED: every other call that can block forever, on any thread. "
          "This gate knows one name.")
    sys.exit(0)

print()
for line in problems:
    print("  " + line)
print()
print(f"FAIL: {len(problems)} call(s) that can hang without saying so first.")
sys.exit(1)
