#!/usr/bin/env python3
"""The thread names task 454 added are still there.

# Why a checker for logging

An instrument is deleted the way a comment is: it looks like noise until the
day somebody needs it, and the day they need it is a day nobody is reading
this file. This one was added because a real investigation stopped for the
want of it: a hung process was sampled and showed **39 threads, two of them
identifiable** -- the window thread (via `GetWindowThreadProcessId`) and the
watchdog (because it names itself in its own lines). "Is this a cycle or is it
congestion" could not be answered, and the answer was "I cannot answer it with
the tools I have".

# What is checked

  1. Every `thread::Builder::new()` either names its thread or carries a
     `// unnamed-thread:` line above it saying why it need not be findable.
  2. The UI thread names itself.
  3. Something still calls `SetThreadDescription`, so the names exist where a
     sampler can reach them and not only in the log.

# NOT CHECKED

  * **That the names reach a reader.** `SetThreadDescription` puts them where
    `Get-Process` cannot see them; the `[thread] tid=… name=…` line is what a
    reader greps. This file checks that the call and the line exist together,
    not that either works on a real machine.
  * **Threads this host does not create.** libghostty's own threads are
    started inside the core and this host never holds their handles: **they
    stay unnamed, and that is a gap, not an oversight.**
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "host", "src")


def strip_comments(src):
    return "\n".join(re.sub(r"//.*", "", ln) for ln in src.split("\n"))


EXCUSED = re.compile(r"^//\s*" + "unnamed-thread" + r":")


def excused_above(lines, line_no):
    """A `// unnamed-thread:` in the comment block above the spawn.

    Anchored at the start of the comment line: prose that merely *names* the
    prefix -- including this file's own documentation -- is not an excuse.
    """
    i = line_no - 2
    while i >= 0:
        stripped = lines[i].strip()
        if stripped.startswith("//"):
            if EXCUSED.search(stripped):
                return True
            i -= 1
            continue
        if not stripped:
            i -= 1
            continue
        return False
    return False


def findings(sources):
    out = []
    for name, src in sorted(sources.items()):
        plain = strip_comments(src)
        lines = src.split("\n")
        for m in re.finditer(r"thread::Builder::new\(\)", plain):
            line = plain[: m.start()].count("\n") + 1
            # ⚠️ **The naming call is the first statement of the closure, which
            # is a long way past `Builder::new()`**: the builder chain, the
            # `.name(...)`, the `.spawn(move || {` and often a paragraph of
            # comment sit in between. The first draft looked 400 characters
            # ahead and reported the watchdog -- **which names itself** -- so
            # the checker's own first run was three false positives out of
            # three. The window is the closure, not a guess.
            body = plain[m.end() : m.end() + 3000]
            if "name_this_thread" in body:
                continue
            if excused_above(lines, line):
                continue
            out.append(
                f"{name} line {line}: a thread is spawned without `name_this_thread`. A "
                "Rust thread name is invisible to Windows and to anything sampling the "
                "process, which is how 39 threads came to have two identifiable ones. "
                "Name it, or write `// unnamed-thread:` above it saying why it does not "
                "need to be findable"
            )

    main = strip_comments(sources.get("main.rs", ""))
    if 'name_this_thread("polter-ui")' not in main:
        out.append("main.rs: the UI thread does not name itself")
    # ⚠️ **The call, not the symbol.** The `use` line that imports it contains
    # the name too, so `"SetThreadDescription" in main` stayed true with the
    # call replaced by `Ok(())` -- the mutation compiled and the gate went
    # green. The open parenthesis is what separates an import from a call.
    if "SetThreadDescription(" not in main:
        out.append("main.rs: nothing calls `SetThreadDescription`; the names would exist only in the log")
    return out


GOOD = {
    "main.rs": '''
    name_this_thread("polter-ui");
    use windows::Win32::System::Threading::{GetCurrentThread, SetThreadDescription};
    pub fn name_this_thread(name: &str) { SetThreadDescription(x, y); }
    let t = std::thread::Builder::new().name("w".into()).spawn(move || {
        crate::name_this_thread("polter-watchdog");
    });
''',
}


def self_test():
    def case(**over):
        s = dict(GOOD)
        s.update(over)
        return s

    cases = [
        ("the shape today", case(), 0),
        ("a thread spawned unnamed",
         case(**{"main.rs": GOOD["main.rs"].replace('crate::name_this_thread("polter-watchdog");', "")}), 1),
        ("the UI thread losing its name",
         case(**{"main.rs": GOOD["main.rs"].replace('name_this_thread("polter-ui");', "")}), 1),
        # ⚠️ The `use` line survives the removal and still spells the name.
        # The first draft matched the bare symbol, so this mutation -- which
        # compiles -- left the gate green.
        ("the description call removed, the import and the line kept",
         case(**{"main.rs": GOOD["main.rs"].replace(
             "SetThreadDescription(x, y);", "let _set: Result<()> = Ok(());")}), 1),
        # ⚠️ The watchdog names itself **inside the closure**, well past the
        # builder -- the shape that made this checker's first run report three
        # threads that were all fine.
        ("the naming call far inside the closure",
         case(**{"main.rs": GOOD["main.rs"].replace(
             'crate::name_this_thread("polter-watchdog");',
             "// " + ("filler comment line\n    " * 20) + '\n    crate::name_this_thread("polter-watchdog");')}), 0),
        # ⚠️ Prose that merely spells the prefix mid-sentence is not an
        # excuse -- this file's own documentation spells it, and so does the
        # finding text. Without the start-of-line anchor a paragraph like
        # this one would excuse the thread underneath it.
        ("prose naming the prefix, which is not an excuse",
         case(**{"main.rs": GOOD["main.rs"].replace(
             'crate::name_this_thread("polter-watchdog");', "")
             .replace("let t = std::thread::Builder::new()",
                      "// this thread would need an unnamed-thread: line to be excused\n    let t = std::thread::Builder::new()")}), 1),
        ("an excused thread",
         case(**{"main.rs": GOOD["main.rs"].replace(
             'crate::name_this_thread("polter-watchdog");', "")
             .replace("let t = std::thread::Builder::new()",
                      "// unnamed-thread: it panics on purpose and is joined at once.\n    let t = std::thread::Builder::new()")}), 0),
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
        print("probe self-test: OK (an unnamed thread, the UI thread unnamed, the description "
              "call removed with its import kept, a naming call deep in the closure, and an "
              "excused thread, and prose that only names the prefix)")
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
    n = sum(strip_comments(s).count("name_this_thread(") for s in sources.values())
    print(f"{n} `name_this_thread` call site(s), including its definition")
    print("NOT CHECKED: that the names reach a reader, and libghostty's own threads, which "
          "this host never holds a handle to.")
    for f in found:
        print(f"HIT    {f}")
    if found:
        print(f"\n{len(found)} problem(s): an instrument is missing.")
        return 1
    print("OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
