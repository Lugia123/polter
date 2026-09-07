#!/usr/bin/env python3
"""Two handles on one log file, and only one of them appends.

**The other half of task 283.** That one was the *glued line* -- two records
sharing one line because a record was more than one write. Both writers there
appended, so nothing was ever lost; the bytes were all present and one
newline was in the wrong place. This is the family next door, and it is worse:

    a handle with its own file pointer, writing over records another
    writer already appended.

The two are told apart by one thing, and it is the discriminant this gate is
named for: **overwriting loses bytes; interleaving loses none.**

# When it can happen at all, which is narrower than it first looks

It needs both handles on **the same file**, and there is exactly one way to
arrange that:

  * `POLTER_HOST_LOG` pinned to some path, and the process started as
    `polter-host.exe > that-path 2>&1`. Somebody wanting one file with
    everything in it does precisely this.

Not, on its own, `polter-host.exe > out.log 2>&1`: with no pin the host logs
to `polter-host-<pid>.log`, a different file, and the two never meet. That
distinction is worth stating because the first write-up of this defect said
the redirect alone was enough, and it is not.

# What it costs, measured

An equivalent pair of handles on one file -- one `O_APPEND`, one ordinary --
500 records each, three runs. The only thing changed between the two cells is
the second handle's kind:

    given handle with its own pointer:  59000B handed over, ~53000B on disk,
                                        ~6000B lost; host records 398/500
    both handles appending:             59000B handed over,  59000B on disk,
                                        0B lost; host records 500/500

**The loss is asymmetric**: the host's records are the ones destroyed, because
the other writer sits at a low offset and writes upwards through what the host
appended. So the file that survives is the one that looks like the core is
fine and the host stopped logging.

# The rule this pins

`adopt_std_handles` leaves a handle it was *given* alone, and that rule is
right: a tester who redirected asked for that file, and an agent CLI handed us
a pipe it speaks JSON-RPC over. **Neither reason survives contact with the
collision case**, and the exception is narrower than the rule:

  * the tester asked for *that file* -- an append handle on the same file is
    the same file;
  * the pipe cannot be confused with the log, because a pipe has no file
    identity for `GetFileInformationByHandle` to return.

So: every handle the process was given must be classified by **file identity**
against the log, and one that turns out to be the log must be re-pointed at an
append handle rather than left as it is.

**NOT CHECKED -- and this is the important half.**

  * **This gate reads text; it cannot run Windows.** That the classification
    is correct at runtime, that `GetFileInformationByHandle` answers the way
    it is assumed to for a shell redirect, and that a pipe really does fail
    it, are all unverified here. The real-machine criterion is one line in the
    log:

        [stdio] ... was handed to us already pointing at THIS log file

    with the file afterwards containing every record both writers wrote.

  * whether anything *else* in the process opens the log with its own pointer.
    Only the standard handles are looked at.

Run:  python3 windows/tools/log-writers-cannot-overwrite.py
Exit: 0 when a given handle that names the log is rescued rather than left.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "host", "src"))


def strip_comments(text: str) -> str:
    """Comments out. **This file's own prose names every symbol below**, and
    so does the function's; a checker counting a comment would pass on a tree
    where the classification exists only in a sentence explaining it."""
    return re.sub(r"//[^\n]*", "", text)


def body_of(src: str, name: str):
    m = re.search(r"\bfn\s+%s\s*\(" % re.escape(name), src)
    if not m:
        return None
    brace = src.find("{", m.end() - 1)
    if brace < 0:
        return None
    depth, k = 0, brace
    while k < len(src):
        if src[k] == "{":
            depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0:
                break
        k += 1
    return src[brace : k + 1]


def analyse(src: str):
    bad = []

    ident = body_of(src, "file_identity")
    if ident is None:
        bad.append(
            "there is no `file_identity`: nothing in this host can tell whether "
            "a handle it was given is the very file it logs to, so the "
            "collision cannot be noticed, let alone answered.")
    elif "GetFileInformationByHandle" not in strip_comments(ident):
        bad.append(
            "`file_identity` does not call `GetFileInformationByHandle`. Two "
            "files are the same file when volume and file index agree; a path "
            "comparison reads `out.log`, `.\\out.log` and an 8.3 name as three "
            "different files, and a pipe as a fourth.")

    adopt = body_of(src, "adopt_std_handles")
    if adopt is None:
        bad.append("there is no `adopt_std_handles`, so this gate has lost its "
                   "subject and is reporting on nothing.")
        return bad

    clean = strip_comments(adopt)
    if "file_identity" not in clean:
        bad.append(
            "`adopt_std_handles` never asks what file a given handle names. A "
            "handle carrying its own file pointer into this log overwrites "
            "records the host appended -- measured at ~100 records of 500 lost "
            "-- and the loss is silent, because a handle that was left alone "
            "leaves no line behind.")
        return bad

    # The classification has to have a third outcome. Two is the old shape:
    # missing -> adopt, given -> leave.
    sets = re.findall(r"SetStdHandle\s*\(", clean)
    if len(sets) < 2:
        bad.append(
            "`adopt_std_handles` calls `SetStdHandle` fewer than twice, so it "
            "cannot have both outcomes: the handle Windows never gave us, and "
            "the one it gave us that turns out to be this very log file. "
            "Noticing the collision and then leaving the handle in place is "
            "the same corruption with a comment on it.")
    return bad


# -- self-test ---------------------------------------------------------------
#
# Both directions, and the middle case, before the tree is read.

OLD_SHAPE = '''
fn adopt_std_handles() -> String {
    let have = |id: STD_HANDLE| -> bool { true };
    let missing: Vec<(STD_HANDLE, &str)> = [].into_iter().filter(|(id, _)| !have(*id)).collect();
    if missing.is_empty() { return "leaving them alone".to_string(); }
    for (id, name) in missing { match unsafe { SetStdHandle(id, file) } { Ok(()) => {}, Err(_) => {} } }
    line
}
'''

NOTICES_BUT_LEAVES = '''
fn file_identity(h: HANDLE) -> Option<(u32, u64)> {
    unsafe { GetFileInformationByHandle(h, &mut info).ok()? };
    Some((info.dwVolumeSerialNumber, 0))
}
fn adopt_std_handles() -> String {
    if file_identity(h) == log_id { plogf!("[stdio] the given handle is this log file"); }
    for (id, name) in missing { let _ = unsafe { SetStdHandle(id, file) }; }
    line
}
'''

FIXED = '''
fn file_identity(h: HANDLE) -> Option<(u32, u64)> {
    unsafe { GetFileInformationByHandle(h, &mut info).ok()? };
    Some((info.dwVolumeSerialNumber, 0))
}
fn adopt_std_handles() -> String {
    match (file_identity(h), log_id) {
        (Some(a), Some(b)) if a == b => colliding.push((id, name)),
        _ => untouched.push(name),
    }
    for (id, name) in missing { let _ = unsafe { SetStdHandle(id, file) }; }
    for (id, name) in colliding { let _ = unsafe { SetStdHandle(id, file) }; }
    line
}
'''

if not any("never asks what file" in l for l in analyse(OLD_SHAPE)):
    print("FAIL: the probe cannot see the shape that only ever adopts the "
          "handles Windows withheld -- which is the shape that shipped.")
    sys.exit(1)
if not any("fewer than twice" in l for l in analyse(NOTICES_BUT_LEAVES)):
    print("FAIL: the probe passes a host that notices the collision and leaves "
          "the handle in place. That is the same corruption with a comment on "
          "it, and it is the most likely way this gets half-fixed.")
    sys.exit(1)
if analyse(FIXED):
    print("FAIL: the probe rejects a host that classifies by file identity and "
          "rescues the colliding handle -- it would be edited away within a day.")
    for line in analyse(FIXED):
        print("  " + line)
    sys.exit(1)

# -- the tree ----------------------------------------------------------------

path = os.path.join(SRC, "main.rs")
src = ""
if os.path.isfile(path):
    with open(path, encoding="utf-8") as fh:
        src = fh.read()

print(f"read {len(src)} byte(s) of windows/host/src/main.rs")
if not src:
    print()
    print("FAIL: main.rs is missing, so there was nothing to check. Not a pass.")
    sys.exit(1)

problems = analyse(src)
if not problems:
    print("OK: a standard handle that names this log file is re-opened for "
          "append rather than left with its own file pointer.")
    print("NOT CHECKED: any of this at runtime. The machine-side criterion is "
          "the `[stdio] ... already pointing at THIS log file` line, plus a "
          "file that afterwards holds every record both writers wrote.")
    sys.exit(0)

print()
for line in problems:
    print("  " + line)
print()
print(f"FAIL: {len(problems)} problem(s).")
sys.exit(1)
