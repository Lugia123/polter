#!/usr/bin/env python3
"""The diagnosis of a defect must not be written where that defect destroys it.

`adopt_std_handles` classifies each standard handle into one of three states
and, in the collision case, re-points it at an append handle so the two
writers stop overwriting each other. **Its entire verdict is one `[stdio]`
line, and that line goes into the log file** -- which, in exactly the
configuration the verdict is about, is the file being overwritten.

Measured on the machine (`POLTER_HOST_LOG` pinned, and the process started
with `> that-same-file 2>&1`):

    the file holds 207 lines, every one of them the core's `info:`
    banner / [stdio] / [build] / [win] / [res] / [loop] -- grepped one by
    one, all null
    no per-pid log anywhere on the disk (2758 entries searched)

So **not one host record survived** -- and the record that would have said why
is a host record. The instrument and the subject are the same file.

# What that costs, concretely, and why it is this gate rather than a fix

"The rescue did not happen" has at least two causes and they need opposite
repairs:

  * `file_identity` did not recognise the shell's handle as the same file, so
    the host never classified it as a collision -- a bug in the recognition;
  * it did classify it and left the handle alone anyway -- a bug in the
    action, and the exact shape
    `log-writers-cannot-overwrite.py`'s middle self-test was written to catch.

**Nothing in the tree can tell those apart today**, because the only place the
answer is written is the place that gets destroyed. That is the whole defect.

# The rule

The stdio verdict must reach at least one sink that **cannot be the file it is
about**. Both properties are needed and neither is obvious:

  * not `log_path()` -- that is the file under discussion;
  * not a name the collision could take. `POLTER_HOST_LOG` pins `log_path()`
    and nothing else, and a per-pid name cannot be a redirect target because
    nobody can name a pid before the process exists. A **fixed** sidecar name
    would be redirectable and would have to argue its way out of this family;
    a per-pid one is out of it by construction, which is the same reasoning
    that put the pid in the main log's name.

**`OutputDebugStringW` does not satisfy this on its own**, and the reason is a
measurement this machine cannot make: with no listener attached the string is
discarded, so a run with nothing watching records nothing. Whether anything
listens on the test machine is not knowable from here -- so it may be an
*additional* sink and never the only one. A gate cannot check "is somebody
listening"; it can check that something durable is also written, and that is
what it checks.

**NOT CHECKED:**

  * that the sidecar is actually written at runtime, or that its directory is
    writable. If the exe sits somewhere read-only the sidecar fails and the
    only report of that failure is... the main log. That circle does not
    close, and saying so is better than pretending it does.
  * what the verdict *says*. A sink that survives carrying a line that does
    not separate "did not recognise" from "recognised and did nothing" would
    pass this and answer nothing. The header of `adopt_std_handles` is where
    that content is argued; the machine criterion below is how it is read.

# The criterion this cannot run

On the machine, `set POLTER_HOST_LOG=C:\\x.log` then
`polter-host.exe > C:\\x.log 2>&1`:

  1. `polter-host-stdio-<pid>.log` exists beside the exe **and** holds the
     verdict. If it does not, nothing below can be answered and this defect is
     not fixed.
  2. That verdict names, per stream: whether it was given, what
     `file_identity` returned for it, what it returned for the log, and which
     of the three classes it landed in.
  3. **That is what settles task 317**: `identity=None` or two different
     identities means the recognition failed; identities equal with the class
     still `left alone` means the recognition worked and the action did not.
  4. Negative control, without which cell 1 proves nothing: run **without**
     the pin and without the redirect. The sidecar must still appear, and its
     verdict must say `left alone` / `no console` rather than a collision --
     otherwise the sidecar is reporting a collision that is not there and cell
     3 cannot be trusted.

Run:  python3 windows/tools/stdio-verdict-survives-its-own-defect.py
Exit: 0 when the verdict reaches a sink the defect cannot destroy.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.normpath(os.path.join(HERE, "..", "host", "src", "main.rs"))


EXEMPT = re.compile(r"//\s*no verdict here:\s*\S")


def strip_comments(text: str) -> str:
    """Comments out, **string literals kept**: the sink's name lives in one."""
    return re.sub(r"//[^\n]*", "", text)


def body_of(src: str, header: str):
    at = src.find(header)
    if at < 0:
        return None
    brace = src.find("{", at)
    depth, k = 0, brace
    while k < len(src):
        if src[k] == "{":
            depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0:
                return src[brace : k + 1]
        k += 1
    return None


def analyse(src: str):
    code = strip_comments(src)  # for the code questions

    bad = []

    fn = body_of(code, "fn adopt_std_handles(")
    if fn is None:
        bad.append("there is no `adopt_std_handles`; this gate has lost its "
                   "subject and would otherwise report a clean tree.")
        return bad, 0

    # **Followed to a fixed point, not one hop.** The repair puts the sink two
    # calls away -- the classifier calls `with_verdict`, which calls
    # `write_stdio_verdict`, which holds the name -- and a one-hop walk
    # reported the repair as the defect. That is the third time in this round
    # a checker has been narrower than the delegation it was checking
    # (`hidden-overlay-hands-back-the-foreground.py` had to learn it about
    # `overlay.rs`, `stacked-badges-do-not-depend-on-order.py` about
    # `sync_corner`), so this one walks until nothing new is added rather than
    # picking a number and being wrong again.
    reach = fn
    seen = set()
    frontier = [fn]
    while frontier:
        nxt = []
        for chunk in frontier:
            for call in set(re.findall(r"\b([a-z_][a-z0-9_]*)\s*\(", chunk)):
                if call in seen:
                    continue
                seen.add(call)
                helper = body_of(code, f"fn {call}(")
                if helper is not None and helper != fn:
                    reach += "\n" + helper
                    nxt.append(helper)
        frontier = nxt

    # **A file name, not merely a string containing the word.** The first
    # version looked for any literal with `stdio` in it and matched the
    # verdict line itself -- every one of them is tagged `[stdio]` -- so a
    # host that wrote nowhere but the log passed by quoting its own tag. It
    # has to look like a name: the word and an extension.
    sidecar = re.search(r'"[^"]*stdio[^"]*\.log[^"]*"', reach)
    if not sidecar:
        bad.append(
            "the stdio verdict goes only into the log file, which in the "
            "configuration the verdict is about is the file being overwritten "
            "-- measured on the machine: 207 lines, not one of them a host "
            "record. Write it to a sink the collision cannot take, and make "
            "that sink per-pid so it cannot be a redirect target either.")
        return bad, 1

    # **Every exit, not just the existence of a sink.** A sink that two of
    # three `return`s reach is a sink the third cannot use, and the third was
    # the one that mattered: the branch where the log file could not be opened
    # is precisely the branch on which nothing else this host writes reaches
    # anybody. **Measured**: this gate was green with that branch returning a
    # bare string.
    #
    # This is the fourth time in this round a checker has asked whether a
    # mechanism exists instead of whether everything goes through it. The
    # first three were about following delegation one hop too few; this one is
    # about paths rather than calls, so counting `return`s is the shape of the
    # question.
    # **The exemption is looked for in the *unstripped* body.**
    # `strip_comments` runs first, so a `// no verdict here:` written at the
    # exit is gone by the time the returns are walked -- and the first version
    # of this check duly rejected its own exemption canary. `strip_comments`
    # keeps newlines, so line numbers line up between the two copies and the
    # comment can be found where it was written. Same trap as
    # `hang-instrument-carries-its-blindness.py`, which had to keep string
    # literals for the opposite reason.
    raw_fn = body_of(src, "fn adopt_std_handles(") or ""
    raw_lines = raw_fn.split("\n")
    for m in re.finditer(r"\breturn\b([^;]*);", fn):
        stmt = m.group(0)
        if "with_verdict" in stmt:
            continue
        line = fn.count("\n", 0, m.start()) + 1
        near = "\n".join(raw_lines[max(0, line - 4) : line])
        if EXEMPT.search(near):
            continue
        bad.append(
            f"`adopt_std_handles` has a `return` (about {line} lines in) that "
            "does not go through the verdict writer, so on that path the "
            "surviving copy is never written. If that path is the one where "
            "the log cannot be opened, it is the path on which nothing this "
            "host says reaches anybody -- and it is the one a person is "
            "reading the sidecar to understand. Route it through "
            "`with_verdict`, or write `// no verdict here: <reason>` on it.")

    name = sidecar.group(0)
    if "{}" not in name and "{" not in name:
        bad.append(
            f"the extra sink {name} has a fixed name. A fixed name can be "
            "redirected onto, so it is inside the family it is supposed to "
            "escape. Put the pid in it: nobody can name a pid before the "
            "process exists, which is the same argument that put one in the "
            "main log's name.")
    if "process::id" not in reach and "GetCurrentProcessId" not in reach:
        bad.append(
            "the extra sink's name has a placeholder but nothing fills it "
            "with this process's id, so two runs would write to one file -- "
            "the defect the main log's per-pid name exists to prevent.")
    return bad, 1


# -- self-test ---------------------------------------------------------------

ONLY_THE_LOG = '''
fn adopt_std_handles() -> String {
    let mut line = String::from("[stdio]");
    line.push_str(" no console: stdout now points at this log file");
    line
}
'''
FIXED_NAME = '''
fn adopt_std_handles() -> String {
    write_sidecar("verdict");
    String::from("[stdio] ok")
}
fn write_sidecar(v: &str) {
    let p = exe.with_file_name("polter-host-stdio.log");
    let _ = std::fs::write(p, v);
}
'''
PER_PID = '''
fn adopt_std_handles() -> String {
    write_sidecar("verdict");
    String::from("[stdio] ok")
}
fn write_sidecar(v: &str) {
    let p = exe.with_file_name(format!("polter-host-stdio-{}.log", std::process::id()));
    let _ = std::fs::write(p, v);
}
'''
# The verdict line is tagged `[stdio]`; that must not read as a sink's name.
TAG_LOOKS_LIKE_A_NAME = '''
fn adopt_std_handles() -> String {
    let mut line = String::from("[stdio]");
    line.push_str(" stdout now points at this log file");
    line
}
'''

# A sink that exists, reached by one exit and not the other. **This is the
# shape that was merged**, and the shape this gate was green on.
SINK_NOT_ON_EVERY_PATH = '''
fn adopt_std_handles() -> String {
    if nothing_to_do {
        return with_verdict(String::from("[stdio] ok"));
    }
    let Ok(file) = file else {
        return format!("[stdio] the log file could not be opened");
    };
    with_verdict(String::from("[stdio] acted"))
}
fn with_verdict(line: String) -> String {
    let name = format!("polter-host-stdio-{}.log", std::process::id());
    line
}
'''

EXCUSED_EXIT = SINK_NOT_ON_EVERY_PATH.replace(
    '        return format!("[stdio] the log file could not be opened");',
    '        // no verdict here: this branch cannot reach any sink at all\n'
    '        return format!("[stdio] the log file could not be opened");')

# The sink two calls away: what the repair actually looks like.
TWO_HOPS = '''
fn adopt_std_handles() -> String {
    with_verdict(String::from("[stdio] ok"))
}
fn with_verdict(line: String) -> String {
    write_stdio_verdict(&line);
    line
}
fn write_stdio_verdict(v: &str) -> Option<PathBuf> {
    let name = format!("polter-host-stdio-{}.log", std::process::id());
    None
}
'''

COMMENT_ONLY = ONLY_THE_LOG.replace(
    'fn adopt_std_handles() -> String {',
    'fn adopt_std_handles() -> String {\n    // writes polter-host-stdio-{pid}.log too')

for sample, want_red, label in (
    (ONLY_THE_LOG, True, "a verdict that goes only into the file it is about"),
    (FIXED_NAME, True,
     "a sidecar with a fixed name -- redirectable, so still inside the family"),
    (PER_PID, False, "a per-pid sidecar, which no redirect can name in advance"),
    (SINK_NOT_ON_EVERY_PATH, True,
     "a sink that exists and that one exit does not reach. **This is what "
     "shipped**: the gate asked whether a surviving sink existed, not whether "
     "every path reached it, and the path it missed was the one where nothing "
     "else the host writes gets out"),
    (EXCUSED_EXIT, False,
     "the same, with `// no verdict here:` written on the exit -- the "
     "exemption has to be possible, and it has to be at the exit rather than "
     "in a list somewhere else"),
    (TWO_HOPS, False,
     "a sink two calls away -- which is what the repair looks like, and what "
     "the one-hop version of this probe reported as the defect"),
    (TAG_LOOKS_LIKE_A_NAME, True,
     "a host that writes only to the log, whose verdict line is tagged "
     "`[stdio]`. **Measured**: the first version of this probe accepted it, "
     "because it looked for the word rather than for a name"),
    (COMMENT_ONLY, True,
     "a *comment* promising a sidecar. This repository has had three checkers "
     "read a comment as code; this one strips them"),
):
    got = bool(analyse(sample)[0])
    if got != want_red:
        print(f"FAIL: the probe {'misses' if want_red else 'fires on'} {label}.")
        sys.exit(1)

# -- the tree ----------------------------------------------------------------

src = open(MAIN, encoding="utf-8").read() if os.path.isfile(MAIN) else ""
problems, looked = analyse(src)
print(f"read main.rs ({len(src)} bytes); {looked} classifier examined")

if not src or looked == 0:
    print()
    print("FAIL: main.rs was not read, or `adopt_std_handles` was not found. "
          "Nothing was checked. Not a pass.")
    sys.exit(1)

if not problems:
    print("OK: the stdio verdict reaches a sink the collision cannot destroy.")
    print("NOT CHECKED: that it is written at runtime, that its directory is "
          "writable, or that what it says separates the two causes. See the "
          "criterion in this file's header.")
    sys.exit(0)

print()
for line in problems:
    print("  " + line)
print()
print(f"FAIL: {len(problems)} way(s) for the diagnosis to die with its subject.")
sys.exit(1)
