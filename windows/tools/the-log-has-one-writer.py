#!/usr/bin/env python3
"""Every record this host writes goes through one handle it holds.

**Three times in one file, and each one was a separate silence.** `log_line`,
`wd_log` and the watchdog's alarm handle each opened the log file for
themselves, once per record, and each was written as "if that worked, write".
Pin the log with `POLTER_HOST_LOG` and redirect a shell onto the same file and
all three opens fail -- so the reading off the machine was 130 lines in the
log, **not one of them this host's**, and nothing anywhere saying why
(task 317).

⚠️ **The sharpest instance is the one that reported the others.** The watchdog
notices when it cannot open its alarm handle and says so through `wd_log` --
which opened the same file the same way. **The sentence "I could not open my
alarm handle" was swallowed by the thing it was reporting.**

A fourth turned up when this checker was written: the panic hook opened the
file itself too, so the one record that exists to explain a crash was the one
most able to vanish. It went onto the sink as part of the same change.

# The rule, and the alternative it points at

A function that opens a file **and** names the log in the same body must be
`Sink::direct`, or say why not.

The alternative is not "open it differently". It is `Sink`: **one handle,
opened once and held, that `log_line`, `wd_log`, the watchdog's alarm and the
panic hook all write through -- and which falls back to the per-pid sidecar
when the file cannot be opened at all.** That is the sentence this checker
exists to send somebody to, because "your open is wrong" invites a different
open, which is the same defect spelled another way.

# Why the whole function body

The first version of this rule, as it was proposed, matched one spelling --
the one `log_line` happened to use. **Three of the four real instances would
have passed it**: one creates rather than opens, one goes through the Win32
call directly, and one had bound the path to a local two lines earlier so the
path function's name was nowhere near the call. Matching a spelling is how a
checker comes to be green beside the thing it forbids.

So the question is asked of the function: does this body open a file, and does
this body name the log? Coarse, and deliberately -- the false positives it
produces are real handles to the real file, and each one is either the sink or
an exception with its reason written next to it.

**NOT CHECKED, and the first is most of the family:**

  * ⚠️ **whether the sink is used correctly.** This reads text. It cannot see
    a handle used without its file pointer moved to the end -- which is task
    298's defect, where records are overwritten and the log looks healthy
    while losing them. **Green here means nobody opened the file behind the
    sink's back, not that the log is right.**
  * a second path function. Somebody who writes one and opens that is outside
    this rule, and this cannot see it.
  * anything outside this one file.

Run:  python3 windows/tools/the-log-has-one-writer.py
Exit: 0 when every opener in the file is the sink or carries its reason.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.normpath(os.path.join(HERE, "..", "host", "src", "main.rs"))

# The ways a file gets opened here. Four spellings, because the instances used
# four -- see the note above about matching one.
OPENERS = re.compile(r"OpenOptions|File::create|File::open|CreateFileW")

# The ways the log is named. `PANIC_LOG` is on this list because the panic
# hook bound the path to a local first, which is how a name-based rule loses
# sight of it.
NAMES_LOG = re.compile(r"log_path\s*\(\s*\)|PANIC_LOG")

# The function allowed to do both.
SINK = "fn direct("

# An exception, with its reason on the same line. The reason is the point:
# without it this degrades into a list of things somebody switched off.
EXEMPT = re.compile(r"//\s*not the log sink:\s*\S")


def strip_comments(text: str) -> str:
    """Comments out for the code question, newlines kept for line numbers.

    The exception is read from the text *with* its comments, because that is
    where an exception lives. Which half to strip depends on where the thing
    being asked about is, and this file needs both halves.
    """
    return re.sub(r"//[^\n]*", "", text)


def functions(src: str):
    """`(line, name, body)` for every `fn`, by brace matching."""
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
        yield src.count("\n", 0, m.start()) + 1, m.group(1), src[brace : k + 1]


def analyse(src: str):
    """Returns (problems, openers) -- the count is the subject-set guard."""
    clean = strip_comments(src)
    bad, openers = [], 0
    for (line, name, body), (_, _, raw) in zip(functions(clean), functions(src)):
        if not OPENERS.search(body):
            continue
        if not NAMES_LOG.search(body):
            continue
        openers += 1
        if name == SINK[3:-1]:
            continue
        if EXEMPT.search(raw):
            continue
        bad.append(
            f"main.rs:{line}: `{name}` opens a file and names the log in the "
            "same body, and it is not the sink. Every record this host writes "
            "goes through one handle it holds -- `Sink` -- which `log_line`, "
            "`wd_log`, the watchdog's alarm and the panic hook all share, and "
            "which falls back to the per-pid sidecar when the file cannot be "
            "opened at all. Opening it here is how the host came to write 130 "
            "lines of somebody else's log and none of its own, silently, three "
            "times over. Use the sink, or write `// not the log sink: <reason>` "
            "and say why this one cannot.")
    return bad, openers


# -- self-test ---------------------------------------------------------------

def fn(name, body):
    return "fn %s() {\n%s\n}\n" % (name, body)


REOPENS = fn("log_line", '    if let Ok(mut f) = OpenOptions::new().append(true).open(log_path()) {\n        let _ = f.write_all(s);\n    }')
THE_SINK = fn("direct", '    match OpenOptions::new().append(true).open(log_path()) {\n        Ok(f) => f,\n    }')
EXCUSED = fn("write_log_bom", '    // not the log sink: it truncates on purpose, and it runs before the\n    // sink is chosen\n    let f = File::create(log_path());')
# **The three spellings the proposed rule would have missed.** Each is a real
# handle to the real file, arrived at by a different route.
CREATES = fn("write_log_bom", "    let f = File::create(log_path());")
# The Win32 spelling, in the shape the real one has: the path is built from
# the path function a few lines above the call. ⚠️ **That is also the limit of
# this rule** -- a body that gets the wide path from somewhere else names
# nothing this can see, and the first draft of this sample made exactly that
# mistake and was caught by the self-test rather than by the tree.
WIN32 = fn("adopt", "    let wide = log_path().encode_wide();\n"
                    "    let h = unsafe { CreateFileW(wide.as_ptr(), FILE_APPEND_DATA.0) };")
VIA_LOCAL = fn("panic_hook", '    let path = PANIC_LOG.get().unwrap();\n    let f = OpenOptions::new().append(true).open(path);')
# Opens something, but not this file.
OTHER_FILE = fn("write_stdio_verdict", '    let f = OpenOptions::new().append(true).open(&sidecar);')
# Names the log, opens nothing.
NAMES_ONLY = fn("banner", '    logf!("log={}", log_path().display());')

for sample, want_red, label in (
    (REOPENS, True, "a record writer opening the file for itself -- the 317 shape"),
    (THE_SINK, False, "the sink itself, which is the one that may"),
    (EXCUSED, False, "an exception with its reason on the line"),
    (CREATES, True, "a create rather than an open -- one of the spellings the "
                    "rule as first proposed would have passed"),
    (WIN32, True, "the Win32 call, another one it would have passed"),
    (VIA_LOCAL, True, "the path bound to a local first, so the path function's "
                      "name is nowhere near the call -- the third"),
    (OTHER_FILE, False, "an opener that names a different file"),
    (NAMES_ONLY, False, "a function that names the log and opens nothing"),
):
    got = bool(analyse(sample)[0])
    if got != want_red:
        print(f"FAIL: the probe {'misses' if want_red else 'fires on'} {label}.")
        sys.exit(1)

if analyse(REOPENS)[1] != 1:
    print("FAIL: the probe does not count what it looked at, so its silence "
          "cannot be told from having read nothing.")
    sys.exit(1)

# -- the tree ----------------------------------------------------------------

src = open(MAIN, encoding="utf-8").read() if os.path.isfile(MAIN) else ""
problems, openers = analyse(src)
print(f"read main.rs ({len(src)} bytes); {openers} function(s) that open a file "
      f"and name the log")

# **Subject-set guard.** Zero is not a clean file: the sink is in there, and so
# are the two exceptions. Zero means the walk found nothing and the all-clear
# below would say the same thing either way.
if not src or openers == 0:
    print()
    print("FAIL: main.rs was not read, or nothing in it opens the log at all -- "
          "not even the sink. There was nothing to check. Not a pass.")
    sys.exit(1)

if not problems:
    print("OK: the sink is the only writer, and every exception carries its reason.")
    print("NOT CHECKED: whether the sink is used correctly -- a handle written "
          "through without its file pointer moved to the end overwrites records "
          "and this cannot see it. Green means nobody opened the file behind "
          "the sink's back, not that the log is right.")
    sys.exit(0)

print()
for line in problems:
    print("  " + line)
print()
print(f"FAIL: {len(problems)} function(s) opening the log outside the sink.")
sys.exit(1)
