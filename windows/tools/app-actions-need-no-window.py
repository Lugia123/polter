#!/usr/bin/env python3
"""An action the core sends with no window must not be answered by asking for one.

**The defect this exists for, in one line from a real machine:**

    [action] toggle_quick_terminal
    [ops] ToggleQuickTerminal from toggle_quick_terminal action:
          the action names no window; not queued

The core performs `toggle_quick_terminal` as `performAction(.app, ...)`, always.
An `.app` target carries no surface, so `origin_window` answers `None`, so
`queue_from` refuses -- **correctly**, because its whole job is to stop an
action that names no window from running on a window somebody guessed. The
arm was asking it a question with no right answer.

**Nothing else could see this.** The arm exists, so `menu-actions-handled.py`
is satisfied. It returns `queue_from`'s `false` rather than a bare one, so
`action-arms-act.py` is satisfied. It compiles, it runs, it logs a refusal
that reads like a considered decision -- and the feature has never worked
through any of its three doors, because the keybinding, the menu row and the
palette entry all reach the same core action.

# What this checks

For every action the core **only ever** performs with `.app`, the arm in
`cb_action` must not route it through `queue_from(origin, ...)`. Such an arm
is dead: `origin` is `None` on every call it will ever receive.

The list of app-targeted actions is read from the core rather than written
here, because a list written here is a second copy of a fact -- and the day
an action changes target is exactly the day nobody updates the copy.

# What this does not check

  * **Whether the arm does the right thing instead.** `close_all_windows`
    reads `winid::all()` itself and `open_config` asks the shell; both are
    fine and this file cannot tell you why.
  * **Actions performed both ways.** An action sent with `.app` *and* with a
    surface is out of scope: `origin` is sometimes `Some`, so `queue_from` is
    a reasonable thing to ask, and whether the app-targeted case is handled
    is a question about the arm's body that text cannot answer.
  * **Anything about the op itself.** That `Op::ToggleQuickTerminal` never
    looks at the frame it was queued against is why the fix is what it is,
    and it is not something this gate reads.

Run:  python3 windows/tools/app-actions-need-no-window.py
Exit: 0 when no app-targeted action's arm demands a window.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(ROOT, "windows", "host", "src")

sys.path.insert(0, HERE)
import _cb_action as cb  # noqa: E402


def top_level_args(text: str, i: int) -> list[str]:
    """The arguments of a call whose `(` has just been consumed."""
    depth, cur, out = 0, "", []
    while i < len(text):
        c = text[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                out.append(cur)
                break
            depth -= 1
        if depth == 0 and c == ",":
            out.append(cur)
            cur = ""
        else:
            cur += c
        i += 1
    return [" ".join(a.split()) for a in out]


def targets_of_actions(root: str) -> dict[str, set]:
    """`action name -> {"app", "surface"}`, read out of the core.

    **Comments are stripped first.** This file reads text, and the core's
    comments quote calls -- a prose example of `performAction(.app, ...)`
    read as a call would put an action in this set that nothing performs.
    That trap has been hit three times in this directory.
    """
    out: dict[str, set] = {}
    files = [os.path.join(root, "src", "App.zig"), os.path.join(root, "src", "Surface.zig")]
    apprt = os.path.join(root, "src", "apprt")
    files += [os.path.join(apprt, f) for f in sorted(os.listdir(apprt)) if f.endswith(".zig")]
    for path in files:
        if not os.path.exists(path):
            continue
        text = re.sub(r"//[^\n]*", "", open(path, encoding="utf-8").read())
        for m in re.finditer(r"performAction\(", text):
            args = top_level_args(text, m.end())
            if len(args) < 2 or not args[1].startswith("."):
                continue
            name = args[1][1:]
            out.setdefault(name, set()).add("app" if args[0] == ".app" else "surface")
    return out


def scan(main_src: str, targets: dict[str, set]):
    """`(problems, checked)` -- checked is the app-only arms that were read."""
    always_app = {k for k, v in targets.items() if v == {"app"}}
    problems, checked = [], []
    for pattern, body, line in cb.arms(main_src):
        for tag in cb.tags_of(pattern):
            name = tag.replace("ACTION_", "").lower()
            if name not in always_app:
                continue
            checked.append(tag)
            if "queue_from(origin" in body:
                problems.append(
                    f"{tag} (main.rs:{line}) routes through `queue_from(origin, ...)`, and "
                    f"the core performs `{name}` only as `performAction(.app, ...)`. "
                    f"`origin` is `None` on every call this arm will ever get, so it "
                    f"refuses every time and the feature has no working door -- the "
                    f"keybinding, the menu row and the palette entry all arrive here."
                )
    return problems, checked


# -- self-test ---------------------------------------------------------------

CANARY_MAIN = '''
extern "C" fn cb_action(_app: App, target: Target, action: Action) -> bool {
    let origin = origin_window(&target);
    match action.tag {
        ffi::ACTION_APPWIDE => {
            alogf!(origin, "[action] appwide");
            queue_from(origin, Op::Appwide, "appwide action")
        }
        ffi::ACTION_PERSURFACE => {
            queue_from(origin, Op::PerSurface, "per-surface action")
        }
    }
}
'''
CANARY_FIXED = CANARY_MAIN.replace(
    'queue_from(origin, Op::Appwide, "appwide action")',
    "appwide::request()",
)
CANARY_TARGETS = {"appwide": {"app"}, "persurface": {"surface"}}


def self_test() -> None:
    probs, checked = scan(CANARY_MAIN, CANARY_TARGETS)
    if not probs:
        print("FAIL: an app-targeted arm that demands a window was not reported.")
        sys.exit(2)
    if any("PERSURFACE" in p for p in probs):
        print("FAIL: a surface-targeted arm was reported. `queue_from` is the right "
              "question there.")
        sys.exit(2)
    if scan(CANARY_FIXED, CANARY_TARGETS)[0]:
        print("FAIL: an app-targeted arm that does not ask for a window was reported.")
        sys.exit(2)
    if "ACTION_APPWIDE" not in checked:
        print("FAIL: the app-targeted arm was not even read.")
        sys.exit(2)
    print("probe self-test: OK (app-only reported, surface-targeted ignored, fixed arm clears)")


def main() -> int:
    self_test()
    targets = targets_of_actions(ROOT)
    always_app = sorted(k for k, v in targets.items() if v == {"app"})
    if not targets:
        print("FAIL: no `performAction` call was parsed out of the core at all. A "
              "parser that cannot find its subject must say so, not pass.")
        return 1

    main_src = open(os.path.join(SRC, "main.rs"), encoding="utf-8").read()
    problems, checked = scan(main_src, targets)

    print(f"read {len(targets)} action(s) from the core; "
          f"{len(always_app)} are performed only with `.app`:")
    for a in always_app:
        print(f"  app-only: {a}")
    print(f"{len(checked)} of them have an arm in `cb_action`, and were checked.")
    print("NOT CHECKED: whether an arm that asks for no window does the right thing "
          "instead, and actions the core performs both ways.")

    if problems:
        print()
        for p in problems:
            print(f"FAIL: {p}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
