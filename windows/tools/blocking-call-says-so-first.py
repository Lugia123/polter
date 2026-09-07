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
because it is a genuinely unbounded call on this host's **main thread**: it
enters the shell, which may start a process, load handlers, or put up UI of
its own, and this host has no timeout on it.

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


def announced(src: str, line: int) -> bool:
    """Is there a log call naming `ShellExecuteW` in the lines just above?"""
    lines = strip_comments(src).split("\n")
    lo = max(0, line - 1 - REACH)
    window = "\n".join(lines[lo : line - 1])
    for m in LOG.finditer(window):
        # The macro's arguments, to the end of that statement.
        rest = window[m.end() : m.end() + 600]
        if CALL in rest:
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
                    f"{name}:{line}: `{CALL}` is called with nothing above it "
                    "saying so. It runs on the main thread and can take as long "
                    "as the shell takes; when it does not come back, the log's "
                    "silence looks exactly like a click that never arrived and "
                    "like a branch that refused without logging. Write the line "
                    "before the call, and have it name the call.")
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
    print("NOT CHECKED: every other main-thread call that can block forever. "
          "This gate knows one name.")
    sys.exit(0)

print()
for line in problems:
    print("  " + line)
print()
print(f"FAIL: {len(problems)} call(s) that can hang without saying so first.")
sys.exit(1)
