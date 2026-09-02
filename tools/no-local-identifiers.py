#!/usr/bin/env python3
"""Find the machine owner's identifiers in files that are about to be published.

This repository is public. Nothing here is secret, but the person developing
it is not the subject, and their username, home directory and scratch paths
get typed in by accident: you work in your own shell, and your home directory
is sitting in the prompt while you write a test fixture.

**Why this exists rather than a grep in a checklist.** The check that ran
before this one matched `/Users/lugia` -- with a forward slash. This is a
Windows port, so paths get written the other way round, and
`C:\\Users\\lugia\\notes.txt` in a test went in and was published. Same
username, different separator, no hit. A pattern narrow enough to be quiet is
narrow enough to miss the thing it was written for.

So: match the identifier and nothing else about how it was written. That
finds the fork's own product identity too -- `com.lugia.polter`, the GitHub
URLs -- which is deliberate and must stay. Those live in KNOWN with a reason
each, the same shape `windows/tools/borrow-across-dispatch.py` uses: an
allowed hit is one somebody wrote down a reason for, not one the pattern was
bent around.

A SECOND KIND OF IDENTIFIER, AND WHY IT CANNOT BE WRITTEN DOWN
--------------------------------------------------------------

The names above are safe to spell here: `lugia` is already the fork's public
identity, in the bundle id and the repository URL. **A test machine's host
name is not**, and one of those was published in a document before this
section existed. This checker was green throughout, correctly -- its needle
list said nothing about host names, and **a green light says only "the things
it knows about are absent", never "nothing that should have been stopped is
here"**.

The obvious repair does not work, and it is worth saying which one: taking
this machine's own host name from the environment and searching for that.
**It would not have caught this.** The name that leaked belongs to the *test*
machine, and this runs on the developer's -- so it would have stayed green,
for a reason that sounds thorough.

The repair that does work has a trap of its own. **Writing the host name into
`NEEDLES` publishes it**: this file is tracked, and the repository is public.
A checker that must name the thing it is looking for is itself inside the
thing being published -- the same shape as
`windows/tools/line-number-references.py`, whose first find was its own
documentation.

So the second list holds **digests, not names**. Every `[A-Za-z0-9-]` token in
every tracked file is lower-cased and hashed, and the digest is looked up.
That keeps the property the first list has and the reason it works: **it is a
membership test over a closed set, and answers no semantic question at all.**
This checker has never asked "is this a user name"; it asks whether `lugia`
is present. It does not ask "is this a host name" either.

**Its output is inside the published surface too**, so a digest hit prints the
path, the line and the digest -- never the matched text. A checker that
announced the name it just found would complete the leak in the log of the run
that caught it.

To add a machine: `python3 tools/no-local-identifiers.py --digest`, type the
name, paste the line it prints. **The name never has to be spoken, written in
a message, or known by whoever adds it to the list.**

WHAT THIS DOES NOT CHECK
------------------------

**The most useful half of a checker's documentation is its edge**, because a
reader who knows what it covers still guesses generously about the rest.

  * **Any machine nobody remembered to add.** The digest list knows exactly
    the machines somebody typed in. A brand-new machine's name leaks and this
    stays green -- **which is precisely the shape of the incident that
    produced it**: that machine was in use all evening and nobody thought its
    name would reach a document.

    So state the capability exactly: **"the same machine's name will not leak
    twice"**, not "host names will not leak". Those are very different
    sentences and the second is the one a reader assumes.

    **The action that follows, because nothing will prompt you to do it:**
    every time a new machine joins, add a digest line. The completeness of a
    closed set is a habit, not a mechanism, and this file cannot make it one.

  * **A hit inside an allowed path.** `KNOWN` allows by *path*: every hit in
    one of those files is skipped, not just the ones the reason describes. A
    genuinely new local path appearing in `project.pbxproj` would go unseen.

  * **Whether an identifier should be secret.** It matches what it was told
    to match. `lugia` is on the list and is public on purpose; the digests are
    on the list because somebody decided they should not be.

WHY THIS ONE SHOULD NOT BE WIDENED WITH A HEURISTIC
---------------------------------------------------

**When the costs are asymmetric, more coverage is not better.**

`windows/tools/line-number-references.py` missing one costs a reader an
afternoon chasing a reference that drifted. **This one missing one costs a
public leak that is already pushed** -- it stays in the history, and no later
commit takes it back.

The temptation is a heuristic: flag anything that *looks* like a machine name.
It would catch more, and it would also flag ordinary words, and then somebody
would loosen it. Everywhere else in this tree the note reads "a checker that
cries wolf gets switched off, and the person who switches it off does not come
back" -- **here the conclusion is the opposite one: a checker that gets
loosened once is leaking from then on.** So: an explicit list, exact matches,
and no guessing.

Exit: 0 if every hit is in KNOWN, 1 otherwise.
"""

import hashlib
import re
import subprocess
import sys

# The identifiers that mean "this came off the developer's machine".
NEEDLES = [
    re.compile(r"lugia", re.I),
]

# Identifiers that must not be published and cannot be written here, as
# `digest -> what it is for`. **Never the value**: see the header.
#
# The comment beside each one says what the machine is, not what it is called.
# Without that, nobody dares delete a line six months from now -- and a list
# that only grows is a list that eventually matches something by accident.
#
# Empty on purpose: whoever knows a name adds it with `--digest`, and this
# file never learns it.
HASHED_NEEDLES: dict[str, str] = {
    "d3727f45330d": "Windows test machine, added 2026-09-03 after its name reached two docs",
    # "0123456789ab": "the Windows test machine, added 2026-09",
}

# Tokens shorter than this are not considered. Three is the shortest a host
# name can be, and it keeps the scan from hashing every `if`, `to` and `of`
# in the tree.
MIN_TOKEN = 3

TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{%d,}" % (MIN_TOKEN - 1))


def digest(token: str) -> str:
    """The stored form of a name. Lower-cased first, so `BUILDBOX` and
    `buildbox` are one entry rather than two."""
    return hashlib.sha256(token.lower().encode("utf-8")).hexdigest()[:12]


# Hits that are the fork's own identity, or a documented reason to keep it.
# key: "path:needle-text-lowered" -> why it may stay.
KNOWN = {
    "src/build_config.zig": "bundle id com.lugia.polter is the application's identity",
    "src/apprt/gtk/build/info.zig": "GTK application id, same identity as the bundle id",
    "src/main_ghostty.zig": "log predicate in a comment quotes the bundle id",
    "src/build/PolterVersion.zig": "names the fork's own remote, Lugia123/polter",
    "macos/Ghostty-Info.plist": "pasteboard type derived from the bundle id",
    "macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift":
        "NSUserInterfaceItemIdentifier values namespaced by the bundle id",
    "macos/Sources/Features/About/AboutView.swift": "links to the fork's public repository",
    "macos/Sources/App/AppDelegate.swift": "links to the fork's public documentation",
    # **This one is here rather than skipped, and the difference matters.**
    # An earlier version of this file excluded the whole xcodeproj path, which
    # is the shape this checker exists to argue against: bending the pattern
    # around a hit instead of writing down why the hit may stay. The nine
    # PRODUCT_BUNDLE_IDENTIFIER lines in it are the application's identity on
    # disk -- change them and an installed copy becomes a different app, with
    # its preferences, keychain items and TCC grants no longer its own.
    "macos/Ghostty.xcodeproj/project.pbxproj":
        "PRODUCT_BUNDLE_IDENTIFIER values; changing them re-identifies the app",
    # **It finds itself, which is the right answer and worth saying.** A
    # checker for a name has to contain the name -- in what it searches for,
    # in the reasons above, and in the self-test samples, which have to be
    # literal or they are testing a variable rather than a spelling. Run it
    # over itself and it reports every one of those, correctly. The reason it
    # may stay is that the identifier is already public in the bundle id and
    # the repository URL; what must not leak is a *path* off this machine, and
    # there is none here.
    "tools/no-local-identifiers.py":
        "names the identifier it searches for, in its samples and its reasons",
}


def tracked_files():
    out = subprocess.run(
        ["git", "ls-files", "-z"], capture_output=True, check=True
    ).stdout
    return [p.decode("utf-8", "replace") for p in out.split(b"\0") if p]


def scan():
    bad = []
    for path in tracked_files():
        if path.endswith((".lock", ".png", ".jpg", ".ico", ".icns", ".ttf")):
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        for needle in NEEDLES:
            for m in needle.finditer(text):
                if path in KNOWN:
                    continue
                line = text.count("\n", 0, m.start()) + 1
                bad.append((path, line, m.group(0), None))

        # The digest list. **Reported without the text that matched**: this
        # output goes into terminals and CI logs, which are part of the
        # published surface too, and a checker that announced the name it just
        # found would finish the leak it caught.
        #
        # **Skipped entirely while the list is empty**, which is the state
        # this ships in. Tokenising ~6,000 files for a lookup that cannot hit
        # is waste; with one entry present it was measured at **1.7s** for the
        # whole tree, which is the real cost of turning it on. The machinery
        # is exercised by `digest_self_test` either way, so it does not ship
        # having never run.
        if HASHED_NEEDLES and path not in KNOWN:
            for m in TOKEN.finditer(text):
                why = HASHED_NEEDLES.get(digest(m.group(0)))
                if why is None:
                    continue
                line = text.count("\n", 0, m.start()) + 1
                bad.append((path, line, None, why))
    return bad


# A machine that does not exist, for the digest probes. **Its digest is not in
# `HASHED_NEEDLES`**, so this file does not report itself -- the third time
# today a checker in this tree has had to be kept from finding its own
# apparatus. (The other two: a documentation example, and the line a checker
# prints when it succeeds.)
CANARY_HOST = "buildbox-7"


def digest_self_test():
    """The digest path, end to end, in memory.

    **It has to be exercised here because it is switched off in the tree
    scan.** With no entries in `HASHED_NEEDLES` the scan skips tokenising
    altogether -- 6,000 files' worth of hashing for a lookup that cannot hit
    is not worth doing -- which means the machinery would otherwise ship
    having never run, and the first person to add a digest would be its first
    test. That is the arrangement this whole tree spent an evening arguing
    against.
    """
    table = {digest(CANARY_HOST): "the imaginary machine in this probe"}

    # It must be found where it really appears: inside a path, a prompt, a
    # UNC share -- not only standing alone.
    for sample in (
        CANARY_HOST,
        rf"\\{CANARY_HOST}\share\logs",
        f"PS C:\\> hostname\n{CANARY_HOST}\n",
        f"copied from {CANARY_HOST.upper()} at 03:12",
    ):
        found = any(table.get(digest(m.group(0))) for m in TOKEN.finditer(sample))
        if not found:
            print(f"self-test FAILED: the digest probe missed {sample!r}")
            return False

    # **The half that keeps it from being widened into a guess.** A near miss
    # is a different machine, and a checker that matched it would be matching
    # shapes rather than names -- which is the thing the header refuses.
    for sample in (
        "buildbox-8",
        "buildbox",
        "build-box-7",
        "the build box, seven of them",
        "windows/host/src/main.rs and 0x1a009c",
    ):
        if any(table.get(digest(m.group(0))) for m in TOKEN.finditer(sample)):
            print(f"self-test FAILED: the digest probe matched {sample!r}, which is not it")
            return False

    # **The floor.** If `digest` ignored its argument -- returned a constant,
    # or the empty string -- every "must not match" case above would still
    # pass, because nothing would be in the table to match. Two different
    # names have to hash differently, and the same name the same way.
    if digest("a") == digest("b"):
        print("self-test FAILED: digest is not a function of its argument")
        return False
    if digest(CANARY_HOST) != digest(CANARY_HOST.upper()):
        print("self-test FAILED: digest is case-sensitive; it must not be")
        return False

    print("probe self-test: OK (digests: found in paths, prompts and UNC shares; "
          "near misses and ordinary text refused)")
    return True


def print_digest_line():
    """`--digest`: turn a name into a line to paste, without saying it.

    **Read without echo, and never printed back.** The point of the digest
    list is that a name can be guarded by somebody who does not have to write
    it down -- in this file, in a message, or in a shell history. Echoing it
    here would undo that in the one place built to prevent it.
    """
    import getpass

    if sys.stdin.isatty():
        name = getpass.getpass("machine name (not echoed): ")
    else:
        name = sys.stdin.readline()
    name = name.strip()
    if not name:
        print("nothing read; no line produced")
        return 1
    print("\nPaste this into HASHED_NEEDLES, and replace the comment with what")
    print("the machine is -- not what it is called:\n")
    print(f'    "{digest(name)}": "TODO: which machine, and when it was added",')
    return 0


def self_test():
    """The probe has to see the shape it was written for, in both spellings.

    A checker that only ever prints zero reads the same as a clean tree, and
    this one was written *because* the previous check printed zero on a real
    hit -- so it says out loud that it can still see one.
    """
    samples = [
        r"C:\Users\lugia\notes.txt",   # the spelling that got through before
        "/Users/lugia/claude",
        "/home/lugia",
        "lugiadeMacBook-Pro-3",        # the machine name contains it too
    ]
    for s in samples:
        if not any(n.search(s) for n in NEEDLES):
            print(f"self-test FAILED: {s!r} not matched")
            return False
    if any(n.search("ghostty is a terminal") for n in NEEDLES):
        print("self-test FAILED: matched a line with no identifier in it")
        return False
    print("probe self-test: OK (both separators, the bare name, and the host name)")
    return True


def main():
    if "--digest" in sys.argv:
        return print_digest_line()
    if not self_test():
        return 1
    if not digest_self_test():
        return 1
    hits = scan()
    print(f"scanned {len(tracked_files())} tracked files; "
          f"{len(KNOWN)} paths allowed with a written reason")
    if not hits:
        print("\nno unexpected hits")
        return 0
    print()
    for path, line, text, why in hits:
        if text is None:
            # No value printed. See `scan`.
            print(f"HIT    {path}:{line}  a name from the digest list ({why})")
        else:
            print(f"HIT    {path}:{line}  {text!r}")
    print(f"\n{len(hits)} unexpected; this repository is public.")
    print("Either replace the identifier, or add the path to KNOWN with a reason.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
