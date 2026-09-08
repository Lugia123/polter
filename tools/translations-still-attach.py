#!/usr/bin/env python3
"""A translation must still be attached to a string the program contains.

# The defect, measured rather than argued

Change the wording of one user-visible string and the old `msgid` leaves
`po/com.lugia.polter.pot`. The next `msgmerge` -- run by
`src/build/GhosttyI18n.zig` with `--no-fuzzy-matching` -- then moves that
entry, translation and all, into the obsolete `#~` block at the end of every
catalogue, and puts the new wording in as `msgstr ""`.

Measured here, by rewording exactly one `msgid` in the real template and
merging all 32 catalogues:

    control  (template unchanged)      0 catalogues,  0 entries dropped
    reworded (one msgid changed)      32 catalogues, 32 entries dropped
    -> attributable to the rewording: 32, exactly one per catalogue

**The control cell is what makes that 32 a reading rather than a guess**: a
merge that changes nothing drops nothing, so every one of the 32 is the
rewording's. It also caught a wrong instrument -- the first version of this
measurement reported 6 catalogues and 16 entries for the control, because the
regex it used could not read the multi-line form `msgmerge` rewraps long
strings into. See `BASELINE_ADRIFT` below.

# What actually goes wrong, said precisely

**The translation is not deleted.** It is kept, verbatim, as an obsolete
entry:

    #~ msgid "Open in Ghostty"
    #~ msgstr "Адкрыць у Ghostty"

What is lost is its *effect*: the new wording is untranslated in all 32
languages, and nothing anywhere says so. `msgfmt --statistics` is no help --
it counts what is in the file, and the file now has one more untranslated
entry and one more obsolete one, which is not a shape a total can show.

**Fuzzy matching would not fix that, and it is worth knowing why before
reaching for it.** With `--no-fuzzy-matching` removed, all 32 catalogues get
the old text back on the new entry, marked `#, fuzzy` -- and a fuzzy entry is
**not compiled into the `.mo`**. Constructed and checked with `msgfmt`: a
`#, fuzzy` entry's text appears zero times in the compiled catalogue, a plain
one's once. So fuzzy changes the *recoverability* (a translator sees the old
words next to the new ones) and not the *runtime outcome*. Whichever way that
flag goes, the silence is what this file is for.

# The two checks, and why they are two

  1. **Adrift** -- a live, translated entry whose `msgid` is not in the
     template. That is the residue a rewording leaves behind before anybody
     merges, and it is a state, checkable at any moment.
  2. **Vanished with translations** -- comparing the template in the working
     tree against the one in `HEAD`: a `msgid` that has just left the template
     and that catalogues still translate. That is the *transition*, and it is
     the one that would have named the strings lost when the hold's wording
     changed.

The first is a ratchet, because there are sixteen of them today and blocking
every commit until six languages are revisited would punish the wrong people.
The second is not: it fires only on a change being made right now, by whoever
is making it.

# NOT CHECKED

  * **Whether the new wording gets translated.** That is a person's job, and
    no check can tell a missing translation from one nobody has done yet.
  * **Whether an obsolete entry is still a good translation of anything.**
    Deciding that is exactly what fuzzy matching guesses at and what a
    translator settles.
  * **Plural forms are read only through `msgstr[0]`.** A catalogue whose
    zeroth plural is empty while a later one is filled reads here as
    untranslated. No such entry exists today; it is a limit of the reader,
    stated rather than discovered.
"""

import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PO_DIR = os.path.join(ROOT, "po")
POT = os.path.join(PO_DIR, "com.lugia.polter.pot")

# **Zero, and it was very nearly sixteen.** The first measurement of this said
# six catalogues held sixteen adrift translations, and that number came from a
# regex written quickly for the measurement -- one that read `msgstr "..."` on
# a single line and could not see the multi-line form `msgmerge` rewraps long
# strings into. The parser written for this gate disagreed, and the gate was
# right: nothing is adrift.
#
# **Two readers of one fact, and the careless one was mine.** Had the
# measurement been the only reader, the report would have carried a standing
# debt that does not exist -- and in the direction that makes the alarm louder.
#
# Going *up* means a rewording landed and its translations were left pointing
# at the old words; going *down* is not possible from zero, which is the point
# of being at zero.
BASELINE_ADRIFT = 0


def unquote(chunk):
    """The string a run of adjacent `"..."` literals spells."""
    out = []
    for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', chunk):
        out.append(m.group(1))
    return "".join(out)


def entries(src):
    """`(msgid, msgstr, obsolete)` for every entry in a `.po`/`.pot`."""
    out = []
    for blk in re.split(r"\n\s*\n", src):
        if not blk.strip():
            continue
        obsolete = blk.lstrip().startswith("#~")
        # Drop comment lines, but keep `#~` bodies by stripping the marker --
        # an obsolete entry is still an entry and this file needs to see it.
        body = "\n".join(
            re.sub(r"^#~\s?", "", ln)
            for ln in blk.split("\n")
            if not re.match(r"^\s*#[^~]", ln) and not re.match(r"^\s*#$", ln)
        )
        mid = re.search(r"^msgid((?:\s*\"(?:[^\"\\]|\\.)*\")+)", body, re.M)
        if not mid:
            continue
        # Plurals: the zeroth form stands in. See NOT CHECKED.
        mstr = re.search(r"^msgstr(?:\[0\])?((?:\s*\"(?:[^\"\\]|\\.)*\")+)", body, re.M)
        out.append((unquote(mid.group(1)), unquote(mstr.group(1)) if mstr else "", obsolete))
    return out


def template_ids(src):
    return {mid for mid, _, obs in entries(src) if mid and not obs}


def adrift(po_src, pot_ids):
    """Live, translated entries whose msgid the template does not have."""
    return sorted(
        mid
        for mid, mstr, obs in entries(po_src)
        if mid and mstr and not obs and mid not in pot_ids
    )


def self_test():
    pot = 'msgid ""\nmsgstr ""\n\nmsgid "Kept"\nmsgstr ""\n'
    good = 'msgid ""\nmsgstr ""\n\nmsgid "Kept"\nmsgstr "K"\n'
    gone = good + '\nmsgid "Reworded away"\nmsgstr "R"\n'
    obs = good + '\n#~ msgid "Reworded away"\n#~ msgstr "R"\n'
    untr = good + '\nmsgid "Reworded away"\nmsgstr ""\n'
    multi = good + '\nmsgid ""\n"Two "\n"parts"\nmsgstr "T"\n'
    ids = template_ids(pot)
    cases = [
        ("the clean shape", good, []),
        ("a translation the template lost", gone, ["Reworded away"]),
        ("the same one, already retired to #~", obs, []),
        ("an untranslated entry is not adrift", untr, []),
        ("a msgid spelled over several lines", multi, ["Two parts"]),
    ]
    for what, src, want in cases:
        got = adrift(src, ids)
        if got != want:
            print(f"probe self-test FAILED: {what} gave {got}, expected {want}")
            return False
    if template_ids(pot) != {"Kept"}:
        print("probe self-test FAILED: the template reader is wrong")
        return False
    print("probe self-test: OK (clean, adrift, retired, untranslated, multi-line msgid)")
    return True


def vanished_from_template(pot_ids, catalogues):
    """msgids the template had at HEAD, has lost, and catalogues translate.

    Returns `None` when there is nothing to compare against -- no git, or the
    template is unchanged -- which is not a failure and is said out loud, so
    that "this check found nothing" and "this check did not run" are never the
    same line.
    """
    try:
        head = subprocess.run(
            ["git", "-C", ROOT, "show", "HEAD:po/com.lugia.polter.pot"],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if head.returncode != 0:
        return None
    was = template_ids(head.stdout)
    if was == pot_ids:
        return None
    lost = was - pot_ids
    out = {}
    for name, src in catalogues.items():
        for mid, mstr, obs in entries(src):
            if mid in lost and mstr and not obs:
                out.setdefault(mid, []).append(name)
    return out


def main():
    if not self_test():
        return 1
    try:
        with open(POT, encoding="utf-8") as fh:
            pot_src = fh.read()
    except OSError as e:
        print(f"cannot read po/com.lugia.polter.pot: {e}")
        return 1
    pot_ids = template_ids(pot_src)
    files = sorted(glob.glob(os.path.join(PO_DIR, "*.po")))
    if not files or not pot_ids:
        print(f"read {len(files)} catalogue(s) and {len(pot_ids)} template string(s); "
              "with nothing to compare this check proves nothing, so it fails")
        return 1
    catalogues = {}
    for p in files:
        with open(p, encoding="utf-8") as fh:
            catalogues[os.path.basename(p)] = fh.read()

    print(f"read {len(files)} catalogue(s) against {len(pot_ids)} template string(s)")

    rc = 0
    van = vanished_from_template(pot_ids, catalogues)
    if van is None:
        print("template unchanged against HEAD (or no git here): "
              "the rewording check had nothing to compare and did not run")
    elif not van:
        print("template changed against HEAD, and no string it lost is translated anywhere")
    else:
        for mid, where in sorted(van.items()):
            print(f"LOST   {mid!r} left the template and {len(where)} catalogue(s) "
                  f"translate it: {', '.join(where[:6])}"
                  f"{' …' if len(where) > 6 else ''}")
        print(f"\n{len(van)} reworded string(s) will go untranslated in every language that "
              "had them. The old text is not gone -- `msgmerge` keeps it as `#~` -- but "
              "nothing will use it and nothing else would have told you.")
        rc = 1

    n = 0
    for name, src in catalogues.items():
        for mid in adrift(src, pot_ids):
            print(f"ADRIFT {name}: {mid!r} is translated but the template has no such string")
            n += 1
    if n == BASELINE_ADRIFT:
        print(f"\n{n} translation(s) already point at strings the template does not have "
              f"(baseline {BASELINE_ADRIFT}).")
    elif n > BASELINE_ADRIFT:
        print(f"\n{n} adrift, baseline {BASELINE_ADRIFT}. Something was reworded and its "
              "translations were left pointing at the old words.")
        rc = 1
    else:
        print(f"\nFAIL, and it is good news: {BASELINE_ADRIFT - n} fewer than the baseline. "
              f"Set BASELINE_ADRIFT = {n}.")
        rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
