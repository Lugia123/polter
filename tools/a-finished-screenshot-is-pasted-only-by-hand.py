#!/usr/bin/env python3
r"""Finishing a screenshot types nothing into a terminal; only a paste does.

# Why this exists

A finished screenshot used to be sent straight into the pane that had the
keyboard when it was triggered, if Polter was in front: its path, then its
annotation line, and for a long screenshot one tile after another. The person
who wanted it somewhere else had to delete it first, so that was taken out
(#1114, `dev-docs/poltergeist/screenshot.md` section 3.4). What is left is the
other road, which was always there: the image is on the clipboard, and a
paste made by hand finds the saved file and the line that goes with it. What
finishing used to send -- a long screenshot's tiles one at a time included --
that paste sends now, into the pane that was pasted into.

Nothing a test can run sees this. Both hosts finish a screenshot inside their
window code -- an overlay, the clipboard, a surface -- and the part that was
removed is a call that puts text into a surface. Putting it back would
compile, pass every test in both hosts, and read as a feature. This gate is
the condition that it has not come back.

# What it checks

macOS, `macos/Sources/Features/Screenshot/*.swift`:
- no file there calls `sendText(`. The one call that sends a screenshot's
  later pieces is in `Ghostty.App.swift`, inside the clipboard read.
- `ScreenshotController.swift` still remembers the finished file
  (`ImagePasteService.shared.remember(`), and `Ghostty.App.swift` still asks
  what follows the path on a paste (`ImagePasteService.shared.followUps(for:`)
  -- or the paste would find nothing and this gate would be guarding an
  absence.

Windows, `windows/host/src`:
- in `shot.rs`, `surface_text` is called only inside `fn paste_notes`, and
  the queue it drains is pushed to only inside `fn paste_later`.
- `paste_later(` is called from one place in the host: `fn image_text` in
  `shots.rs`, the clipboard read.
- `fn finish` in `shot.rs` still calls `crate::shots::remember(`.

Function bodies are found by brace matching from the `fn` line; `//` comments
are dropped before anything is searched, so prose may name these calls.

# NOT CHECKED

- That a paste really produces the paths and then the line: the pure halves
  are tested where they live (`ImagePaste.Cache`, `polter_shots::paste`), the
  wiring is a real-machine cell.
- Text put into a surface some other way (a key event, a different C call).
  Only the calls named above are read.
- An agent's screenshots. They never touched the clipboard or a pane and do
  not go through either `finish`.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAC_SHOT = ROOT / "macos" / "Sources" / "Features" / "Screenshot"
MAC_APP = ROOT / "macos" / "Sources" / "Ghostty" / "Ghostty.App.swift"
WIN_SRC = ROOT / "windows" / "host" / "src"

COMMENT = re.compile(r"//[^\n]*")


def code(path):
    """The file with `//` comments blanked, line count kept."""
    return COMMENT.sub("", path.read_text(encoding="utf-8"))


def body_span(text, name):
    """(start, end) of `fn name`'s body, or None."""
    m = re.search(r"\bfn\s+" + re.escape(name) + r"\s*\(", text)
    if not m:
        return None
    open_at = text.find("{", m.end())
    if open_at < 0:
        return None
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return (open_at, i + 1)
    return None


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def main():
    problems = []
    scanned = 0

    # ---- macOS
    swift = sorted(MAC_SHOT.glob("*.swift")) if MAC_SHOT.is_dir() else []
    controller = MAC_SHOT / "ScreenshotController.swift"
    for path in swift:
        scanned += 1
        text = code(path)
        for m in re.finditer(r"\bsendText\s*\(", text):
            problems.append(
                f"{path.relative_to(ROOT)}:{line_of(text, m.start())}: sendText( in the screenshot "
                f"feature -- a finished screenshot is not typed into a terminal; the person pastes it"
            )
    if controller not in swift:
        problems.append(f"{controller.relative_to(ROOT)}: not found, so nothing was checked on macOS")
    elif "ImagePasteService.shared.remember(" not in code(controller):
        problems.append(
            f"{controller.relative_to(ROOT)}: no ImagePasteService.shared.remember( -- a paste by "
            f"hand would not find the finished screenshot's file"
        )
    if not MAC_APP.is_file():
        problems.append(f"{MAC_APP.relative_to(ROOT)}: not found")
    else:
        scanned += 1
        if "ImagePasteService.shared.followUps(for:" not in code(MAC_APP):
            problems.append(
                f"{MAC_APP.relative_to(ROOT)}: the clipboard read no longer asks what follows a "
                f"screenshot's path (ImagePasteService.shared.followUps(for:)"
            )

    # ---- Windows
    shot = WIN_SRC / "shot.rs"
    shots = WIN_SRC / "shots.rs"
    if not shot.is_file() or not shots.is_file():
        problems.append("windows/host/src/shot.rs or shots.rs: not found, so nothing was checked on Windows")
    else:
        text = code(shot)
        scanned += 1
        spans = {name: body_span(text, name) for name in ("paste_notes", "paste_later", "finish")}
        for name, span in spans.items():
            if span is None:
                problems.append(f"windows/host/src/shot.rs: fn {name} not found")
        if all(spans.values()):
            def inside(pos, name):
                a, b = spans[name]
                return a <= pos < b

            for m in re.finditer(r"\bsurface_text\b", text):
                if not inside(m.start(), "paste_notes"):
                    problems.append(
                        f"windows/host/src/shot.rs:{line_of(text, m.start())}: surface_text outside "
                        f"fn paste_notes -- finishing a screenshot pastes nothing"
                    )
            pushes = list(re.finditer(r"\bNOTES\b[^;]*?\.push\s*\(", text, re.S))
            if not pushes:
                problems.append("windows/host/src/shot.rs: nothing pushes to NOTES; the paste's second line is gone")
            for m in pushes:
                if not inside(m.start(), "paste_later"):
                    problems.append(
                        f"windows/host/src/shot.rs:{line_of(text, m.start())}: NOTES is pushed to outside "
                        f"fn paste_later"
                    )
            a, b = spans["finish"]
            if "crate::shots::remember(" not in text[a:b]:
                problems.append(
                    "windows/host/src/shot.rs: fn finish no longer calls crate::shots::remember( -- a paste "
                    "by hand would not find the finished screenshot's file"
                )

        callers = []
        for path in sorted(WIN_SRC.rglob("*.rs")):
            scanned += 1
            t = code(path)
            for m in re.finditer(r"\bpaste_later\s*\(", t):
                if path == shot and re.search(r"\bfn\s+$", t[: m.start()]):
                    continue  # the definition
                callers.append((path, t, m.start()))
        if not callers:
            problems.append("windows/host/src: nothing calls paste_later; the paste's second line is gone")
        for path, t, pos in callers:
            span = body_span(t, "image_text") if path == shots else None
            if span is None or not (span[0] <= pos < span[1]):
                problems.append(
                    f"{path.relative_to(ROOT)}:{line_of(t, pos)}: paste_later( called outside "
                    f"shots.rs's fn image_text (the clipboard read)"
                )

    if scanned == 0:
        print("FAIL: scanned 0 files; neither host's screenshot code was found")
        return 1
    if problems:
        print(f"FAIL: {len(problems)} problem(s) in {scanned} file(s) scanned")
        for p in problems:
            print("  " + p)
        return 1
    print(f"OK: finishing a screenshot pastes nothing in either host ({scanned} file(s) scanned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
