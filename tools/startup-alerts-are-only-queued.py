#!/usr/bin/env python3
"""Nothing that runs while a window is being made may show an alert.

`Surface.init` calls `App.ensureChatLog` before the surface's core exists, and
`App.addSurface` has by then already put that surface in `App.surfaces`. An
alert shown from there is shown on `surfaces.items[0].core()` -- which is a
terminal that is not there yet. On Windows that was the host dying at start,
0xc0000005, whenever a group rename could not be continued: the new "tell the
person" code in `noteLogProblem` called `poltergeistAlert`, and a green
build, a green test run and every other gate had nothing to say about it.

The rule that makes this impossible to repeat by accident: **the only
function that shows an alert on a surface is reached from the message the
app loop delivers (`.poltergeist_alert => |line| ...`) or from the flush at
the end of `Surface.init`.** Anything else that has something to say queues
it (`poltergeist_alerts.append`); the flush shows it when there is somewhere
to show it.

So, in src/App.zig:

  * `poltergeistAlert(` may be called only on the line that handles the
    `.poltergeist_alert` message;
  * `showPoltergeistAlert(` may be called only from `poltergeistAlert` and
    `flushPoltergeistAlerts`.

`--self-test` (run first by every normal run) plants both offences in a
scratch file and checks the gate goes red on each. Green says only that no
new route to the screen has been added; it cannot say a route that is already
allowed is reached at a safe time.

Exit 0 and `scanned N lines` with N > 0, or non-zero.
"""

import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

FN = re.compile(r"^(?:pub\s+)?fn\s+(\w+)\s*\(")
CALL_ALERT = re.compile(r"\bpoltergeistAlert\(")
CALL_SHOW = re.compile(r"\bshowPoltergeistAlert\(")


def check(path):
    problems = []
    lines = 0
    current = None
    with open(path, encoding="utf-8") as f:
        for n, raw in enumerate(f, 1):
            lines += 1
            line = raw.split("//")[0]
            m = FN.match(line)
            if m:
                current = m.group(1)
                continue
            if CALL_ALERT.search(line) and ".poltergeist_alert =>" not in line:
                problems.append(
                    f"{path}:{n}: calls poltergeistAlert() outside the message handler. It shows the alert on "
                    "a surface at once; during Surface.init that surface has no core yet. Queue it: "
                    "self.poltergeist_alerts.append(self.alloc, line)."
                )
            if CALL_SHOW.search(line) and current not in ("poltergeistAlert", "flushPoltergeistAlerts"):
                problems.append(
                    f"{path}:{n}: calls showPoltergeistAlert() from {current or 'file scope'}; only "
                    "poltergeistAlert and flushPoltergeistAlerts may."
                )
    return lines, problems


def self_test():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "App.zig")
        with open(p, "w") as f:
            f.write(
                "fn noteLogProblem(self: *App) void {\n"
                "    self.poltergeistAlert(line);\n"
                "}\n"
                "fn somethingElse(self: *App) void {\n"
                "    self.showPoltergeistAlert(s, line);\n"
                "}\n"
            )
        lines, problems = check(p)
        if lines == 0 or len(problems) < 2:
            print(f"self-test: the gate did not go red on planted offences ({len(problems)} of 2 found)")
            return False
    return True


def main():
    if not self_test():
        return 1
    if "--self-test" in sys.argv:
        print("self-test ok")
        return 0
    path = os.path.join(ROOT, "src/App.zig")
    if not os.path.isfile(path):
        print("scanned 0 lines; src/App.zig is not here, and a gate that looks at nothing is not green")
        return 1
    lines, problems = check(path)
    for p in problems:
        print(p)
    print(f"scanned {lines} lines")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
