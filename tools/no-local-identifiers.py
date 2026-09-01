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

Exit: 0 if every hit is in KNOWN, 1 otherwise.
"""

import re
import subprocess
import sys

# The identifiers that mean "this came off the developer's machine".
NEEDLES = [
    re.compile(r"lugia", re.I),
]

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
                bad.append((path, line, m.group(0)))
    return bad


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
    if not self_test():
        return 1
    hits = scan()
    print(f"scanned {len(tracked_files())} tracked files; "
          f"{len(KNOWN)} paths allowed with a written reason")
    if not hits:
        print("\nno unexpected hits")
        return 0
    print()
    for path, line, text in hits:
        print(f"HIT    {path}:{line}  {text!r}")
    print(f"\n{len(hits)} unexpected; this repository is public.")
    print("Either replace the identifier, or add the path to KNOWN with a reason.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
