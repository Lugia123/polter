#!/usr/bin/env python3
"""Nothing pushes to the renderer's mailbox without a bound and a wake-up.

# What this is and is not

**It is a net, not the rule.** The rule is the wrapper: delivery to the
renderer's mailbox goes through one function whose signature has no
unbounded variant, so writing the old shape is not expressible. This file
catches the case where somebody reaches around it -- which is cheap to do
by hand and which the type system, on its own, does not forbid.

**It is deliberately the weakest of the three checks** that came out of this
work. The other two are unit tests and they assert behaviour: that a push
about to wait wakes the consumer *before* it waits, and that a caller on a
full mailbox gets control back. Those are the criteria. This is the thing
that notices a thirteenth call site appearing.

# NOT CHECKED

  * **That a failed delivery releases what the message owned.** Three of the
    converted sites hand over an arena the renderer would have freed, and a
    dropped message hands it back. That pairing is enforced by the leak
    detector in the test allocator, not here.
  * **The other mailboxes.** The app mailbox and the surface mailbox have the
    same shape and have **not** been swept -- there are seven unbounded waits
    on them in `Surface.zig` alone. They are a separate piece of work and
    saying so here is the point: a green run of this file is not a claim
    about them.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# Assembled, so this file's own prose cannot satisfy the rule it states.
FOREVER = "." + "forever"
INSTANT = "." + "instant"
WAKER_SET = "mailbox.waker" + " = "
WAIT_CALL = "wakeup." + "wait("
EXCUSE = re.compile(r"^\s*//\s*" + "unbounded-push" + r":")

WATCHED = [
    os.path.join("src", "Surface.zig"),
    os.path.join("src", "termio", "Termio.zig"),
]

WIRING = os.path.join("src", "renderer", "Thread.zig")

CEILING_READ = "poltergeist-render-mailbox-" + "capacity"
CEILING_SET = "capacity_limit" + " = "


def strip_comments(src):
    return "\n".join(re.sub(r"//.*", "", ln) for ln in src.split("\n"))


def excused_above(lines, line_no):
    i = line_no - 2
    while i >= 0:
        t = lines[i].strip()
        if t.startswith("//"):
            if EXCUSE.search(t):
                return True
            i -= 1
            continue
        if not t:
            i -= 1
            continue
        return False
    return False


def wiring_findings(src):
    """The mechanism is only as good as the one line that connects it.

    ⚠️ **This rule exists because mutation found the hole, not because anybody
    predicted it.** Every behavioural test installs its own waker by hand, so all of
    them stayed green with the product's own assignment deleted -- a complete
    mechanism wired to nothing. That is the same shape as task 508: a call
    that succeeds and reaches nobody.
    """
    out = []
    plain = strip_comments(src)
    set_at = plain.find(WAKER_SET)
    wait_at = plain.find(WAIT_CALL)
    if set_at < 0:
        out.append(
            "renderer/Thread.zig: the mailbox is never given a waker. Every test can "
            "install one by hand and pass while the shipped queue has none, which is a "
            "mechanism connected to nothing"
        )
    elif "null" in plain[set_at : set_at + 60]:
        out.append(
            "renderer/Thread.zig: the mailbox's waker is set to nothing. A queue with no "
            "waker cannot tell anybody it is about to wait"
        )
    # ⭐ **The switch is only as good as its one wiring line, same as the
    # waker.** A field that exists on every queue and is set on none of them
    # gives a machine "the mailbox never filled", which is exactly what a
    # working full-mailbox path also gives. ⚠️ **Field present is not switch
    # wired**, and only one of those two can be seen from the outside.
    # 🔴 **The condition, not the mention.** Mutation replaced the whole
    # guard with `if (false)` and left every line inside it intact -- so both
    # of the rules below still found their strings and the gate stayed green
    # with the switch permanently off. **A setting that is read inside a
    # branch nothing takes has been read in exactly the sense a regex can
    # see and in no other sense.** This is the fourth time tonight that a
    # checker matched a place the name appears instead of a place it is used.
    guard = "if (config.@\"" + CEILING_READ + "\" > 0)"
    if guard not in plain:
        out.append(
            "renderer/Thread.zig: the capacity setting is not what decides whether the "
            "ceiling is applied. Reading it inside a branch that is never taken reads, "
            "to everything except a running program, exactly like reading it"
        )
    if CEILING_READ not in plain:
        out.append(
            "renderer/Thread.zig: nothing reads the mailbox-capacity setting, so the "
            "only way to reach a full mailbox is the fault that was fixed -- and then "
            "'never filled' and 'handled correctly' are the same observation"
        )
    elif CEILING_SET not in plain:
        out.append(
            "renderer/Thread.zig: the capacity setting is read but never applied to the "
            "mailbox"
        )
    if wait_at < 0:
        out.append("renderer/Thread.zig: nothing waits on the wake-up handle any more")
    elif set_at >= 0 and set_at > wait_at:
        out.append(
            "renderer/Thread.zig: the waker is installed after the wait is armed. The "
            "handle it must point at is the one this thread waits on, and the ordering "
            "is what makes that true rather than hoped for"
        )
    return out


def findings(sources):
    out = []
    for name, src in sorted(sources.items()):
        plain = strip_comments(src)
        lines = src.split("\n")
        for m in re.finditer(r"renderer_(?:thread\.mailbox|mailbox)\.push\(", plain):
            line = plain[: m.start()].count("\n") + 1
            if excused_above(lines, line):
                continue
            # ⚠️ **A non-blocking push is not this rule's business.** Termio
            # drops `reset_cursor_blink` on purpose and says so on the way
            # out; that is the loud-drop path, and forcing it through a
            # wrapper built for bounded *waiting* would change what it does.
            # The first draft reported it, which would have made the fix look
            # like it had missed a site.
            tail = plain[m.end() : m.end() + 400]
            if INSTANT in tail.split(";")[0]:
                continue
            out.append(
                f"{name} line {line}: this reaches past the wrapper and pushes to the "
                "renderer's mailbox directly. The wrapper is what makes two rules hold "
                "without anybody remembering them -- a bound on the wait, and a wake-up "
                "after a delivery. Use it, or write an `unbounded-push:` line above "
                "saying why this one may wait with no bound"
            )
    return out


GOOD = {
    "Surface.zig": '''
    _ = rendererpkg.Thread.send(self.renderer_thread.mailbox, w, msg);
''',
    "Termio.zig": '''
    _ = renderer.Thread.send(self.renderer_mailbox, w, .{ .resize = size });
''',
}


def self_test():
    def case(**over):
        s = dict(GOOD)
        s.update(over)
        return s

    cases = [
        ("the shape today", case(), 0),
        ("a direct push that reaches past the wrapper",
         case(**{"Surface.zig": "_ = self.renderer_thread.mailbox.push(io, msg, x);\n"}), 1),
        # ⚠️ **The deliberate non-blocking drop must not be reported.** The
        # first draft did report it, and a fix that appears to have skipped a
        # site reads exactly like a fix that missed one.
        ("the loud instant drop, which is not this rule's business",
         case(**{"Termio.zig": "_ = self.renderer_mailbox.push(io, m, .{ ." + "instant = {} });\n"}), 0),
        # ⚠️ The shape that has cost this project several rounds: prose that
        # names what the rule looks for, with the code gone.
        ("a comment naming the pattern, code removed",
         case(**{"Surface.zig": "// this used to be a direct renderer_thread.mailbox.push call\n"}), 0),
        ("an excused one",
         case(**{"Termio.zig": "// unbounded-push: the reason.\n"
                 "_ = self.renderer_mailbox.push(io, m, .{ ." + "forever = {} });\n"}), 0),
    ]
    CEIL = ('if (config.@"poltergeist-render-mailbox-capacity" > 0) {\n'
            '        mailbox.capacity_limit = 2;\n    }\n    ')
    wiring_cases = [
        ("the wiring as it stands",
         CEIL + "self.mailbox.waker = wakerFor(&self.wakeup);\n    self.wakeup.wait(&loop, &c);", 0),
        ("the wiring deleted",
         CEIL + "self.wakeup.wait(&loop, &c);", 1),
        ("the waker set to nothing",
         CEIL + "self.mailbox.waker = null;\n    self.wakeup.wait(&loop, &c);", 1),
        # ⚠️ **The exact mutation that walked past the first version**: the
        # guard turned into a constant false, every line inside it untouched.
        ("the ceiling behind a branch nothing takes",
         'if (false) {\n        mailbox.capacity_limit = config.@"poltergeist-render-mailbox-capacity";\n    }\n'
         "    self.mailbox.waker = wakerFor(&self.wakeup);\n    self.wakeup.wait(&loop, &c);", 1),
        ("the capacity setting never read",
         "self.mailbox.waker = wakerFor(&self.wakeup);\n    self.wakeup.wait(&loop, &c);", 2),
        ("the capacity setting read but not applied",
         'x = config.@"poltergeist-render-mailbox-capacity";\n'
         "    self.mailbox.waker = wakerFor(&self.wakeup);\n    self.wakeup.wait(&loop, &c);", 2),
        ("the wiring after the wait is armed",
         CEIL + "self.wakeup.wait(&loop, &c);\n    self.mailbox.waker = wakerFor(&self.wakeup);", 1),
        # ⚠️ Prose naming the assignment must not stand in for it.
        ("a comment where the wiring used to be",
         CEIL + "// self.mailbox.waker = wakerFor(&self.wakeup);\n    self.wakeup.wait(&loop, &c);", 1),
    ]
    ok = True
    for what, src, want in wiring_cases:
        got = wiring_findings(src)
        if len(got) != want:
            print(f"probe self-test FAILED: {what} gave {len(got)}, expected {want}:")
            for g in got:
                print(f"    {g}")
            ok = False
    for what, sources, want in cases:
        got = findings(sources)
        if len(got) != want:
            print(f"probe self-test FAILED: {what} gave {len(got)}, expected {want}:")
            for g in got:
                print(f"    {g}")
            ok = False
    if ok:
        print("probe self-test: OK (a direct push, the deliberate instant drop left alone, a "
              "comment that only names the pattern, an excused site, and four ways for the "
              "waker's one wiring line to go wrong, and the capacity switch unread or unapplied)")
    return ok


def main():
    if not self_test():
        return 1
    sources = {}
    for rel in WATCHED:
        path = os.path.join(ROOT, rel)
        try:
            with open(path, encoding="utf-8") as fh:
                sources[os.path.basename(rel)] = fh.read()
        except OSError as e:
            print(f"cannot read {rel}: {e}")
            return 1

    try:
        with open(os.path.join(ROOT, WIRING), encoding="utf-8") as fh:
            found = findings(sources) + wiring_findings(fh.read())
    except OSError as e:
        print(f"cannot read {WIRING}: {e}")
        return 1
    print(f"{len(sources)} file(s) swept for direct pushes, plus the one line that wires "
          "the waker to the handle its thread waits on.")
    print("NOT CHECKED: that a dropped message releases what it owned (the test "
          "allocator's leak detector does that), and the app and surface mailboxes.")
    for f in found:
        print(f"HIT    {f}")
    if found:
        print(f"\n{len(found)} problem(s): something can wait with no bound.")
        return 1
    print("OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
