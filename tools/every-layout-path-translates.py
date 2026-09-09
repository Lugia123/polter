#!/usr/bin/env python3
"""Both answers from a layout call come back in the caller's namespace.

# The defect this is the floor for

`terminal_layout` crosses two numberings. A caller writes the **terminal ids**
it uses everywhere else; the apprt owns the tree and knows its panes by a
private numbering **no tool hands out**. Task 406 put the translation in the
core -- the only side that holds the map -- and wired it into the request and
into the reply.

**It was not wired into the refusal.** Measured on the machine:

    the layout leaves out terminal 0x1e066b80000, which is in this tab.

That number is a surface handle, in a sentence telling the caller to go look
at a terminal. Feeding it to `terminal_read` fails, and nothing in the
sentence says why. ⚠️ **The reply was right and the refusal was wrong**, which
is the shape that survives review: whoever checked 406 checked the path that
succeeds.

# What is checked

`poltergeistLayout` in `src/App.zig` has three outcomes. Two of them carry
text out of the apprt, and **both must pass it through a translation**:

  * `.applied` -- the reply, a JSON tree (`layoutSurfacesToIds`).
  * `.refused` -- prose (`layoutHandlesInText`).

Anything that hands the apprt's own words straight to the caller
(`alloc.dupe(u8, said)`) is the defect above. ⚠️ **Default-include**: a fourth
outcome added later is checked too, because the rule is "text that came from
the apprt is translated", not a list of the two that exist today.

# NOT CHECKED

  * **Whether the translation is right.** That is
    `"a refusal names terminals, and leaves every other number alone"` in
    `src/App.zig`, which runs in the repo-root suite and holds the scan to
    leaving unrecognised numbers exactly as they were.
  * **Text the apprt writes into its own log**, which never crosses this
    boundary and is read by somebody who has the apprt's numbering in front
    of them anyway.
  * **The `error.UnknownPane` sentence** written on this side. It names no
    handle at all, by construction -- there is nothing in it to translate.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "..", "src", "App.zig")

FN = re.compile(r"\bfn\s+poltergeistLayout\s*\(")
# The value the apprt wrote, handed out untranslated.
RAW = re.compile(r"alloc\.dupe\(\s*u8\s*,\s*said\s*\)")
TRANSLATES = re.compile(r"\b(layoutSurfacesToIds|layoutHandlesInText)\s*\(")


def strip_comments(src):
    return "\n".join(re.sub(r"//.*", "", ln) for ln in src.split("\n"))


def body_of(src, start):
    i = src.find("{", start)
    if i < 0:
        return ""
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i : j + 1]
    return src[i:]


def findings(src):
    out = []
    plain = strip_comments(src)
    m = FN.search(plain)
    if not m:
        out.append(
            "`poltergeistLayout` is gone from App.zig. Either it was renamed or the layout "
            "call moved; this checker cannot follow it, and a silent pass here would be the "
            "same as no checker"
        )
        return out

    body = body_of(plain, m.end())
    for r in RAW.finditer(body):
        line = plain[: m.end()].count("\n") + body[: r.start()].count("\n") + 1
        out.append(
            f"App.zig line {line}: text from the apprt is handed to the caller untranslated. "
            "Whatever handles are in it are in the apprt's numbering, and a caller who feeds "
            "one to terminal_read gets an error about an id it was just given"
        )

    n = len(TRANSLATES.findall(body))
    if n < 2:
        out.append(
            f"`poltergeistLayout` translates on {n} of its outgoing paths. Both the reply and "
            "the refusal carry text out of the apprt, and 406 wired only the reply -- which is "
            "the defect this file is the floor for"
        )
    return out


GOOD = """
fn poltergeistLayout(ctx: *anyopaque) !LayoutAnswer {
    return switch (out.result) {
        .unsupported => error.LayoutUnsupported,
        .refused => .{ .applied = false, .text = try self.layoutHandlesInText(alloc, said) },
        .applied => .{ .applied = true, .text = try self.layoutSurfacesToIds(alloc, said) },
    };
}
"""


def self_test():
    cases = [
        ("the shape today", GOOD, 0),
        # The decoy is the line as it actually stood: a decoy the scan would
        # not have matched anyway proves nothing about the scan.
        ("the refusal handed over raw, as it stood",
         GOOD.replace("try self.layoutHandlesInText(alloc, said)", "try alloc.dupe(u8, said)"), 2),
        ("the reply handed over raw",
         GOOD.replace("try self.layoutSurfacesToIds(alloc, said)", "try alloc.dupe(u8, said)"), 2),
        ("the same line in a comment only",
         GOOD + "// it used to be try alloc.dupe(u8, said) here\n", 0),
        ("a third outgoing path added without one",
         GOOD.replace(".applied => .{ .applied = true, .text = try self.layoutSurfacesToIds(alloc, said) },",
                      ".applied => .{ .applied = true, .text = try self.layoutSurfacesToIds(alloc, said) },\n"
                      "        .partial => .{ .applied = false, .text = try alloc.dupe(u8, said) },"), 1),
        ("the function renamed away", GOOD.replace("poltergeistLayout", "layoutV2"), 1),
    ]
    ok = True
    for what, src, want in cases:
        got = findings(src)
        if len(got) != want:
            print(f"probe self-test FAILED: {what} gave {len(got)} finding(s), expected {want}:")
            for f in got:
                print(f"    {f}")
            ok = False
    if ok:
        print("probe self-test: OK (the refusal raw, the reply raw, a comment, a third path "
              "added without a translation, and the function renamed away)")
    return ok


def main():
    if not self_test():
        return 1
    try:
        with open(APP, encoding="utf-8") as fh:
            src = fh.read()
    except OSError as e:
        print(f"cannot read src/App.zig: {e}")
        return 1

    found = findings(src)
    plain = strip_comments(src)
    m = FN.search(plain)
    n = len(TRANSLATES.findall(body_of(plain, m.end()))) if m else 0
    print(f"App.zig: poltergeistLayout translates on {n} outgoing path(s); no apprt text "
          "reaches the caller unrewritten")
    print("NOT CHECKED: whether the translation is right -- that is the App.zig test "
          '"a refusal names terminals, and leaves every other number alone", in the '
          "repo-root suite.")
    for f in found:
        print(f"HIT    {f}")
    if found:
        print(f"\n{len(found)} problem(s): a layout answer is leaving in the wrong namespace.")
        return 1
    print("OK: both outgoing paths translate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
