#!/usr/bin/env python3
""""Check for updates" reaches the network only when a person asks it to.

# The promise this pins, and where it is made

The user decided this in as many words: check for updates does not run in
the background, at startup, or on a timer -- it runs when, and only when, a
person clicks the menu row or the palette command. That promise is written
as a public commitment in four documents this repository ships to readers
who never see the source: `README.md`, `README_CN.md`, `SECURITY.md` and
`ROADMAP.md`. A promise written in prose and enforced nowhere is one
edit away from becoming false without any of those four files noticing --
someone adds a startup check or a timer six months from now, for an
unrelated reason, and nothing here says the commitment just broke.

# What is checked, on both platforms

Two call patterns per platform: the entry point a menu row or palette
command reaches, and the function that actually issues the request one
level inside it. Every call site of all four, anywhere in the scanned
tree, must sit inside the one context each is allowed to be called from:

  Windows (Rust, `windows/host/src/*.rs`):
    `update::check(`   -- only inside the `ACTION_CHECK_FOR_UPDATES` arm
                          of `cb_action`'s `match` in `main.rs`.
    `fetch_latest(`    -- only inside `update::check`'s own body in
                          `update.rs` (the function `update::check` spawns
                          a thread to run). `fetch_latest` is a private
                          `fn`, so Rust's own visibility rules already
                          confine its callers to this file; checking it
                          here is a second, textual reading of the same
                          fact -- not a redundant one, since it is what
                          this gate's floor test on the Rust side can
                          actually exercise without needing a real
                          compiler.

  macOS (Swift, `macos/Sources/**/*.swift`):
    `beginGitHubCheck(` -- only inside `UpdateController.checkForUpdates()`'s
                          own body, or inside a `retry:` closure literal
                          (the "try again" button on the error screen,
                          which is still a person clicking something).
    `makeCheckTask(`    -- only inside `UpdateController.beginGitHubCheck()`'s
                          own body -- the one place today that builds the
                          actual `URLSessionDataTask`.

**Two tiers, not one flat allow-list, because the real call graph is two
tiers.** `checkForUpdates()` (and `retry:`) is where a person's click
lands; `beginGitHubCheck()` and `update::check()`'s spawned thread are
where the network call is actually issued, one hop further in. A checker
that only watched the outer tier would wave through a `makeCheckTask(` or
`fetch_latest(` call added directly to a third, unrelated function -- which
is exactly the shape a background-check regression would take, since
nobody adding one reaches for the existing helper by way of a menu click.

# What this cannot see

  * **A call reached through a third name.** This reads two literal call
    patterns per platform; a wrapper function that calls `beginGitHubCheck`
    and is itself called from somewhere else is invisible to it, and so is
    renaming any of the four patterns without updating this file.
  * **Sparkle's own automatic-check machinery**, which this task's report
    found still exists (`SPUUpdater`, gated on a `nil` feed URL so it has
    nothing to ask). This file does not read Sparkle at all; the commitment
    it pins is about the GitHub check these two platforms added, not about
    auditing every update mechanism Sparkle ships with.
  * **Whether `checkForUpdates()` and the `ACTION_CHECK_FOR_UPDATES` arm are
    themselves reached only by a click.** That is `menu-actions-handled.py`
    and the menu wiring's job on the Windows side, and ordinary Cocoa
    target-action wiring on macOS; this file starts from "an arm/function
    already believed to be manual" and checks that nothing *else* reaches
    the network directly.
  * **A call added and never committed, or committed to a file this glob
    does not cover.** `windows/host/src/*.rs` is flat (no subdirectories
    today); `macos/Sources/**/*.swift` is recursive. A future subdirectory
    under `windows/host/src/` would need this file's glob widened.
"""

import os
import re
import sys
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")

RUST_SRC = Path(ROOT) / "windows" / "host" / "src"
SWIFT_SRC = Path(ROOT) / "macos" / "Sources"

PROMISE_DOCS = ["README.md", "README_CN.md", "SECURITY.md", "ROADMAP.md"]


def strip_comments(text: str) -> str:
    """`//` comments out, newlines kept so line numbers still point at the
    file. Rust and Swift share this comment syntax, so one function serves
    both. Load-bearing the same way it has been in this tree before: a
    mention of `beginGitHubCheck` or `update::check` in prose -- and both
    files this reads are full of such prose -- must not read as a call.
    """
    return re.sub(r"//[^\n]*", "", text)


def _balanced(text: str, open_at: int) -> int:
    """Index just past the `{` at `open_at`'s matching `}`."""
    depth = 1
    i = open_at + 1
    while i < len(text) and depth:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    return i


def fn_bodies(text: str, header: "re.Pattern") -> list:
    """Every brace-balanced body of a `header`-matching function/closure in
    `text`, as `(start, end)` byte spans. `header` must match up to and
    including the opening `{`."""
    spans = []
    for m in header.finditer(text):
        if any(s <= m.start() < e for s, e in spans):
            continue  # a header matched inside a span already taken
        open_at = m.end() - 1
        end = _balanced(text, open_at)
        spans.append((open_at + 1, end - 1))
    return spans


def arm_span(text: str, tag: str):
    """The extent of one `match` arm: `TAG => { ... }` (brace-balanced) or
    the bare-expression form `TAG => expr,` (everything up to the next
    comma at the arm's own nesting depth). `None` if `tag` is not found."""
    m = re.search(re.escape(tag) + r"\s*=>", text)
    if not m:
        return None
    i = m.end()
    while i < len(text) and text[i] in " \t\r\n":
        i += 1
    if i < len(text) and text[i] == "{":
        end = _balanced(text, i)
        return (i + 1, end - 1)
    depth = 0
    j = i
    while j < len(text):
        c = text[j]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            break
        j += 1
    return (i, j)


RUST_CHECK_CALL = re.compile(r"\bupdate::check\s*\(")
RUST_FETCH_CALL = re.compile(r"\bfetch_latest\s*\(")
SWIFT_BEGIN_CALL = re.compile(r"\bbeginGitHubCheck\s*\(")
SWIFT_MAKECHECK_CALL = re.compile(r"\bmakeCheckTask\s*\(")

RUST_CHECK_FN = re.compile(r"\bfn\s+check\s*\([^)]*\)\s*(?:->\s*\w+\s*)?\{")
SWIFT_CHECKFORUPDATES_FN = re.compile(r"\bfunc\s+checkForUpdates\s*\(\s*\)\s*\{")
SWIFT_BEGIN_FN = re.compile(r"\bfunc\s+beginGitHubCheck\s*\(\s*\)\s*\{")
SWIFT_RETRY_CLOSURE = re.compile(r"\bretry:\s*\{")


def line_of(text: str, offset: int) -> int:
    return text[:offset].count("\n") + 1


def in_any(offset: int, spans) -> bool:
    return any(s <= offset < e for s, e in spans)


def is_definition(text: str, start: int) -> bool:
    """Whether the identifier at `start` is the one being *declared*
    (`fn fetch_latest(` / `func beginGitHubCheck(` / `static func
    makeCheckTask(`), not called. `update::check(` never collides with this
    -- Rust declares as `fn check`, never `fn update::check` -- so this only
    needs to guard the three bare names."""
    before = text[:start].rstrip()
    return before.endswith("fn") or before.endswith("func")


def check_pattern(name: str, files, call_re, allowed_spans_of):
    """One entry-point pattern: every call site across `files` must fall
    inside `allowed_spans_of(text)`. Returns (checked_count, violations)."""
    checked = 0
    violations = []
    for path in files:
        text = strip_comments(path.read_text(encoding="utf-8"))
        allowed = allowed_spans_of(text)
        for m in call_re.finditer(text):
            if is_definition(text, m.start()):
                continue  # `fn fetch_latest(` etc. -- the declaration, not a call
            checked += 1
            if not in_any(m.start(), allowed):
                violations.append((path, line_of(text, m.start())))
    return checked, violations


def main() -> int:
    # -- probe self-test: each pattern's allowed-context reader, told apart
    # from a call sitting just outside it. Run before anything below is
    # trusted.
    rust_arm_good = "ACTION_CHECK_FOR_UPDATES => update::check(origin),\nACTION_X => other(),"
    rust_arm_bad = "ACTION_X => other(),\nfn startup() { update::check(None); }"
    rust_check_good = "fn check(origin: Option<HWND>) -> bool {\n    fetch_latest();\n}\n"
    rust_check_bad = "fn check(origin: Option<HWND>) -> bool {\n}\nfn other() {\n    fetch_latest();\n}\n"

    swift_outer_good = (
        "func checkForUpdates() {\n    beginGitHubCheck()\n}\n"
        "func other() {\n    let retry: () -> Void = {\n        beginGitHubCheck()\n    }\n}\n"
    )
    swift_outer_bad = "func other() {\n    beginGitHubCheck()\n}\n"
    swift_inner_good = "func beginGitHubCheck() {\n    makeCheckTask(currentVersion: v) { _ in }\n}\n"
    swift_inner_bad = "func other() {\n    makeCheckTask(currentVersion: v) { _ in }\n}\n"

    def spans_for_arm(text):
        s = arm_span(text, "ACTION_CHECK_FOR_UPDATES")
        return [s] if s else []

    def spans_for_check_fn(text):
        return fn_bodies(text, RUST_CHECK_FN)

    def spans_for_outer(text):
        return fn_bodies(text, SWIFT_CHECKFORUPDATES_FN) + fn_bodies(text, SWIFT_RETRY_CLOSURE)

    def spans_for_inner(text):
        return fn_bodies(text, SWIFT_BEGIN_FN)

    probe_ok = (
        in_any(RUST_CHECK_CALL.search(rust_arm_good).start(), spans_for_arm(rust_arm_good))
        and not in_any(
            RUST_CHECK_CALL.search(rust_arm_bad).start(), spans_for_arm(rust_arm_bad)
        )
        and in_any(
            RUST_FETCH_CALL.search(rust_check_good).start(), spans_for_check_fn(rust_check_good)
        )
        and not in_any(
            RUST_FETCH_CALL.search(rust_check_bad).start(), spans_for_check_fn(rust_check_bad)
        )
        and in_any(
            SWIFT_BEGIN_CALL.search(swift_outer_good).start(), spans_for_outer(swift_outer_good)
        )
        and not in_any(
            SWIFT_BEGIN_CALL.search(swift_outer_bad).start(), spans_for_outer(swift_outer_bad)
        )
        and in_any(
            SWIFT_MAKECHECK_CALL.search(swift_inner_good).start(),
            spans_for_inner(swift_inner_good),
        )
        and not in_any(
            SWIFT_MAKECHECK_CALL.search(swift_inner_bad).start(),
            spans_for_inner(swift_inner_bad),
        )
    )
    print(
        "probe self-test:",
        "OK (each pattern's allowed context and a call just outside it are told apart)"
        if probe_ok
        else "FAILED -- the reader is broken, so nothing below means anything",
    )
    if not probe_ok:
        return 2

    rust_files = sorted(RUST_SRC.glob("*.rs"))
    swift_files = sorted(SWIFT_SRC.rglob("*.swift"))

    patterns = [
        ("update::check(", rust_files, RUST_CHECK_CALL, spans_for_arm),
        ("fetch_latest(", rust_files, RUST_FETCH_CALL, spans_for_check_fn),
        ("beginGitHubCheck(", swift_files, SWIFT_BEGIN_CALL, spans_for_outer),
        ("makeCheckTask(", swift_files, SWIFT_MAKECHECK_CALL, spans_for_inner),
    ]

    # ⚠️ Nothing to look at is not a pass -- see this repository's other
    # gates for why zero *subjects* and zero *hits* must read apart.
    total_checked = 0
    all_violations = []
    for name, files, call_re, allowed_of in patterns:
        checked, violations = check_pattern(name, files, call_re, allowed_of)
        total_checked += checked
        print(f"{name} {checked} call site(s) read.")
        all_violations.extend((name, p, ln) for p, ln in violations)

    if total_checked == 0:
        print(
            "FAIL: none of the four entry-point patterns were found anywhere in the\n"
            "      scanned tree -- this checker is looking in the wrong place, or the\n"
            "      names it reads have changed. Passing here would say 'every call is\n"
            "      manual' about no calls."
        )
        return 1

    for doc in PROMISE_DOCS:
        if not (Path(ROOT) / doc).exists():
            print(f"FAIL: {doc} is one of the documents this gate is pinning, and it is gone.")
            return 1

    if all_violations:
        print(
            "FAIL: a network-check entry point is reachable from outside the manual\n"
            "      path README.md / README_CN.md / SECURITY.md / ROADMAP.md promise:"
        )
        for name, path, ln in all_violations:
            print(f"      {path.relative_to(ROOT)}:{ln} calls {name} outside its allowed context")
        return 1

    print(
        "Nothing to report: every call to update::check/fetch_latest/"
        "beginGitHubCheck/makeCheckTask sits inside the context a person's click "
        "reaches."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
