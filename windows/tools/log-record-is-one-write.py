#!/usr/bin/env python3
"""A log record is one write, or it is not a line.

**The defect, as it was read off the test machine:**

    w1 [action] config_changeinfo(generic_renderer): [rsz] ...

Two records on one line. The first half is the host's `plogf`; the second is
libghostty's `std.log`, and both land in the same file -- on Windows the core
has no sink but stderr, and `adopt_std_handles` points stderr at the log so
that "the window is gone" cannot quietly also mean "the log is gone".

**Why this matters more than it looks.** Every "verified" in this port is read
out of that file. A record that is eaten or glued is not a cosmetic problem:
the reader either chases a defect that is not there, or -- worse -- reads a
thing that happened as a thing that did not.

# It is not the overwriting family, and that was checked rather than assumed

Task 214 recorded a different shape: standard streams written *positionally*
from logical position 0, so one writer lands on top of another. That is not
this. Both writers here are **append** handles -- `log_line` opens
`OpenOptions::append`, and `adopt_std_handles` opens `FILE_APPEND_DATA` -- so
every individual write goes to the end of the file as one atomic operation and
nothing is ever overwritten. The measured symptom is pure concatenation with
no bytes lost, which is what tells the two families apart.

What actually happens is that **one logical record is more than one write**,
and the other writer's write lands in the gap. Both sides do it, and both were
measured before anything was changed:

  * the host: `writeln!(f, "{s}")` on an unbuffered `File` issues **two**
    writes -- the text, then a lone `"\n"`. `fmt::write` walks the format
    pieces and each piece is its own `write_all`.
  * the core: `main_ghostty.zig`'s `logFn` hands `lockStderr` a **64-byte**
    buffer and prints the whole line through it, so a line longer than 64
    bytes is drained in pieces. A 73-byte line measured as **three** writes.

**Fixing one side is not enough, and that is the reading that matters.** With
two appenders and four combinations, over 800 records each: both broken, ~350
glued lines; only the host fixed, ~350; only the core fixed, ~70; both fixed,
**0**, repeated three times. The host's split is the one that produces the
exact shape quoted above, which is why it is the tempting place to stop.

# What this asserts

  1. **Host.** Any function under `windows/host/src` that opens `log_path()`
     -- or writes to `std::io::stderr()`, which on this platform may *be* the
     log file -- must not use `write!`/`writeln!`. It must hand the sink one
     buffer that already ends in a newline. `alarm` is the shape to copy; it
     arrived there for a different reason (it may not allocate) and has been
     correct all along.

     **Default-include**: a function is in scope because it opens the log, not
     because it is on a list, so the next logger written is in scope the day
     it is written.

  2. **Core.** `main_ghostty.zig`'s `logFn` must give `lockStderr` a buffer a
     log line fits in. 64 bytes is not one.

**NOT CHECKED, and each can be true while this is green:**

  * that a record longer than the core's buffer is one write. It is not --
    it cannot be, with a fixed buffer and no bound on a log line. This moves
    the tearing from "most lines" to "lines over the buffer size"; it does
    not abolish it.
  * that the two are the only writers. A tester running
    `polter-host.exe > out.log 2>&1` hands this process a stderr that is
    **not** an append handle, and `adopt_std_handles` deliberately leaves a
    handle it was given alone. Two writers with independent file pointers is
    the *other* family, and nothing here looks for it.
  * anything about ordering. Records still arrive interleaved; this only
    asks that each one occupies its own line.

Run:  python3 windows/tools/log-record-is-one-write.py
Exit: 0 when every log record is a single write.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "host", "src"))
CORE = os.path.normpath(os.path.join(HERE, "..", "..", "src", "main_ghostty.zig"))

# A line a log record fits in. 64 bytes does not; the resize line that was
# seen torn on the machine is 73.
MIN_CORE_BUFFER = 1024

FMT_MACRO = re.compile(r"\b(write|writeln)!\s*\(")
OPENS_THE_LOG = re.compile(r"\blog_path\s*\(\)|\bstd::io::stderr\s*\(\)")
EXEMPT = re.compile(r"//\s*more than one write:\s*(\S.*)")


def strip_comments(text: str) -> str:
    """Comments out. Not string bodies: a format string is the subject here."""
    return re.sub(r"//[^\n]*", "", text)


def fns(src: str):
    """`(name, body, line)` for every `fn` in one file, by brace matching."""
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


def analyse_host(files: dict):
    bad = []
    for name, src in sorted(files.items()):
        for fn, body, line in fns(src):
            if not OPENS_THE_LOG.search(strip_comments(body)):
                continue
            if EXEMPT.search(body):
                continue
            m = FMT_MACRO.search(strip_comments(body))
            if m:
                bad.append(
                    f"{name}:{line}: `{fn}` writes a log record with "
                    f"`{m.group(1)}!`. That is one write per format piece, so "
                    "the newline is its own write and the other writer's line "
                    "lands in front of it. Build the record with its newline "
                    "and hand the sink one buffer -- `alarm` is the shape.")
    return bad


def analyse_core(core_src: str):
    bad = []
    m = re.search(r"\bfn logFn\b", core_src)
    if not m:
        bad.append("main_ghostty.zig has no `logFn`; nothing to check, which "
                   "is not a pass.")
        return bad
    body = core_src[m.start() : m.start() + 4000]
    if "lockStderr" not in body:
        bad.append("`logFn` no longer calls `lockStderr`; this check has lost "
                   "its subject and is reporting on nothing.")
        return bad
    sizes = [int(x) for x in re.findall(r"var\s+buf\s*:\s*\[(\d+)\]u8", body)]
    if not sizes:
        bad.append("`logFn` gives `lockStderr` a buffer this cannot size.")
    for n in sizes:
        if n < MIN_CORE_BUFFER:
            bad.append(
                f"main_ghostty.zig: `logFn` prints through a {n}-byte buffer. "
                "A log line longer than that is drained in pieces, and the "
                "host's next append lands between them -- which is half of "
                f"the glued line. Needs at least {MIN_CORE_BUFFER}.")
    return bad


# -- self-test ---------------------------------------------------------------
#
# Both directions, before the tree is read, so a broken probe cannot report a
# clean tree.

HOST_TODAY = {"main.rs": '''
fn log_line(msg: &str) {
    if let Ok(mut f) = std::fs::OpenOptions::new().append(true).open(log_path()) {
        let _ = writeln!(f, "{s}");
    }
}
'''}
HOST_FIXED = {"main.rs": '''
fn log_line(msg: &str) {
    let mut s = format!("[{}] {}", now_str(), msg);
    s.push('\\n');
    if let Ok(mut f) = std::fs::OpenOptions::new().append(true).open(log_path()) {
        let _ = f.write_all(s.as_bytes());
    }
}
'''}
HOST_ELSEWHERE = {"strip.rs": '''
fn label(&self) -> String {
    let mut s = String::new();
    let _ = writeln!(s, "{}", self.name);
    s
}
'''}
HOST_EXEMPT = {"main.rs": '''
fn odd_one(msg: &str) {
    // more than one write: the reason, written where the next reader is
    if let Ok(mut f) = std::fs::OpenOptions::new().append(true).open(log_path()) {
        let _ = writeln!(f, "{msg}");
    }
}
'''}

CORE_TODAY = "fn logFn(x: u8) void {\n  var buf: [64]u8 = undefined;\n  const stderr = std.debug.lockStderr(&buf);\n}"
CORE_FIXED = "fn logFn(x: u8) void {\n  var buf: [4096]u8 = undefined;\n  const stderr = std.debug.lockStderr(&buf);\n}"

if not analyse_host(HOST_TODAY):
    print("FAIL: the probe cannot see a log record written with `writeln!`.")
    sys.exit(1)
if analyse_host(HOST_FIXED):
    print("FAIL: the probe rejects a logger that hands the sink one buffer -- "
          "it would be edited away within a day.")
    sys.exit(1)
if analyse_host(HOST_ELSEWHERE):
    print("FAIL: the probe fires on a `writeln!` into a String, which is not a "
          "log record and has no second writer to race.")
    sys.exit(1)
if analyse_host(HOST_EXEMPT):
    print("FAIL: the probe does not read the `// more than one write:` reason, "
          "so a genuine one cannot be recorded.")
    sys.exit(1)
if not analyse_core(CORE_TODAY):
    print("FAIL: the probe cannot see a 64-byte stderr buffer.")
    sys.exit(1)
if analyse_core(CORE_FIXED):
    print("FAIL: the probe rejects a buffer a log line fits in.")
    sys.exit(1)

# -- the tree ----------------------------------------------------------------

files = {}
if os.path.isdir(SRC):
    for name in sorted(os.listdir(SRC)):
        if name.endswith(".rs"):
            with open(os.path.join(SRC, name), encoding="utf-8") as fh:
                files[name] = fh.read()

core_src = ""
if os.path.isfile(CORE):
    with open(CORE, encoding="utf-8") as fh:
        core_src = fh.read()

print(f"read {len(files)} host file(s) and {len(core_src)} byte(s) of main_ghostty.zig")

# **Subject-set guard.** A gate that read nothing prints its all-clear and
# exits 0, which is indistinguishable from one that read the tree.
if "main.rs" not in files or not core_src:
    print()
    print("FAIL: main.rs or src/main_ghostty.zig is missing, so there was "
          "nothing to check. Not a pass.")
    sys.exit(1)

problems = analyse_host(files) + analyse_core(core_src)
if not problems:
    print("OK: every log record is handed to its sink as one write.")
    print("NOT CHECKED: a record longer than the core's buffer is still torn, "
          "and a stderr this process was *given* is not an append handle at "
          "all -- that is the overwriting family and nothing here looks for it.")
    sys.exit(0)

print()
for line in problems:
    print("  " + line)
print()
print(f"FAIL: {len(problems)} record(s) that are more than one write.")
sys.exit(1)
