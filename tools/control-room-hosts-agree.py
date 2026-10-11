#!/usr/bin/env python3
"""The macOS host and the Windows host make the same thing of one snapshot.

**Why.** The control room is drawn twice, by two programs in two languages,
from one document the core writes. Each side has its own tests and each can
be green while the two disagree -- a row height read from the wrong constant,
a section a row lands in, where the arrow key goes from the last row. Nobody
looks at both screens at once. This runs both sides over the same snapshot
and compares what they say, line by line.

**What is run.**

  * Windows: `windows/control-room` (a crate with no dependencies), through
    `examples/dump.rs`.
  * macOS: `macos/Sources/Features/ControlRoom/ControlRoomList.swift` and
    `ControlRoomLook.swift` -- **the same source files the app compiles**,
    linked into a throwaway SwiftPM package with a `main.swift` that prints
    the same lines. No app is built and nothing is launched.

Both read `src/poltergeist/testdata/control_snapshot.json`, the fixture a
Zig test holds to what `ControlRoom.zig` actually produces.

**What is compared**: the clock; the two counts in the headers; every row --
its section, its place, its glyph, its words, its detail, whether the detail
is set as code, its minutes, its "N more"; the panel's size and every
rectangle in it; and where the arrow keys take the selection from every row.

**NOT COMPARED, and why.**

  * `pulses` and the time band. The macOS host does not read either from the
    snapshot yet (`pulses: false`, `timeBand: nil` in `init(snapshot:)`), so
    there is nothing on that side to compare with. The layout is therefore
    compared with no lanes. When the macOS side takes them, add them to both
    dumps -- until then the Windows crate's own tests are all that hold them.
  * Translated text. Both sides print the English they start from.
  * Anything drawn. This compares numbers and strings, not pixels.
  * That the app links these files the way the package does. It is the same
    source; it is not the same binary.

**Needs** `cargo` and `swift` on the path, and takes about a minute. Without
either it fails and says which: a comparison that quietly skipped would be a
comparison nobody ran.

`--self-test` (also run first by every normal run) hands the comparison two
dumps that differ in one line and checks it says so.

Exit 0 and `compared N lines` with N > 0, or non-zero.
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

FIXTURE = "src/poltergeist/testdata/control_snapshot.json"
SWIFT_SOURCES = [
    "macos/Sources/Features/ControlRoom/ControlRoomList.swift",
    "macos/Sources/Features/ControlRoom/ControlRoomLook.swift",
]
CRATE = "windows/control-room"
HEIGHT = "800"

PACKAGE = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "ControlRoomDump",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "dump", path: "Sources/dump")]
)
"""

MAIN = r'''
import CoreGraphics
import Foundation

// The same lines `windows/control-room/examples/dump.rs` prints.

func quote(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if c.value < 0x20 { out += String(format: "\\u%04x", c.value) } else { out.unicodeScalars.append(c) }
        }
    }
    return out + "\""
}

func f(_ v: CGFloat) -> String { String(format: "%.3f", Double(v)) }

func rect(_ name: String, _ r: CGRect) {
    print("rect \(name) x=\(f(r.minX)) y=\(f(r.minY)) w=\(f(r.width)) h=\(f(r.height))")
}

func shownName(_ s: ControlRoomList.Shown) -> String {
    switch s {
    case .needsYou: return "needs_you"
    case .trouble: return "trouble"
    case .doneUnseen: return "done_unseen"
    case .working: return "working"
    case .none: return "none"
    }
}

func row(_ section: String, _ r: ControlRoomList.Row) {
    let waited = r.waitedMin.map(String.init) ?? "-"
    print("row section=\(section) id=\(r.id) shown=\(shownName(r.shown)) word=\(quote(r.word)) "
        + "detail=\(quote(r.detail)) code=\(r.detailIsCode) waited=\(waited) others=\(r.others)")
}

let args = CommandLine.arguments
guard args.count == 3, let height = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: dump <snapshot.json> <height>\n".utf8))
    exit(2)
}
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let list: ControlRoomList
do {
    list = try ControlRoomList.decode(snapshot: data)
} catch {
    FileHandle.standardError.write(Data("the snapshot does not decode: \(error)\n".utf8))
    exit(1)
}

print("now_ms \(list.nowMs)")
print("count waiting=\(list.waitingCount) quiet=\(list.quietCount)")
for r in list.waiting { row("waiting", r) }
for r in list.quiet { row("quiet", r) }

let lay = ControlRoomListLayout(list: list, height: CGFloat(height))
print("size w=\(f(lay.size.width)) h=\(f(lay.size.height))")
rect("header", lay.header)
for r in list.rows {
    guard let frame = lay.rows[r.id] else {
        print("rect row:\(r.id) MISSING")
        continue
    }
    rect("row:\(r.id)", frame)
}
rect("separator", lay.separator)
rect("quiet_header", lay.quietHeader)
rect("band_header", lay.bandHeader)
rect("axis", lay.axis)

let ids: [String?] = [nil] + list.rows.map { Optional($0.id) }
for from in ids {
    for step in [-1, 1] {
        let to = ControlRoomList.move(from, by: step, in: list.rows) ?? "-"
        print("move from=\(from ?? "-") step=\(step) to=\(to)")
    }
}
'''


def compare(mac, win):
    """The lines that differ, as (line number, mac, windows)."""
    a = mac.splitlines()
    b = win.splitlines()
    out = []
    for i in range(max(len(a), len(b))):
        x = a[i] if i < len(a) else "<nothing>"
        y = b[i] if i < len(b) else "<nothing>"
        if x != y:
            out.append((i + 1, x, y))
    return out, max(len(a), len(b))


def self_test():
    same = "count waiting=4 quiet=3\nrect header x=6.000 y=6.000 w=296.000 h=32.000\n"
    other = same.replace("h=32.000", "h=28.000")
    diffs, n = compare(same, other)
    if n != 2 or len(diffs) != 1 or diffs[0][0] != 2:
        return "self-test: two dumps differing in one line were not reported as that"
    if compare(same, same)[0]:
        return "self-test: two identical dumps were reported as different"
    if not compare(same, same + "move from=- step=1 to=x\n")[0]:
        return "self-test: a line one side has and the other does not was not reported"
    return None


def run(cmd, cwd, env=None):
    return subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)


def main():
    if "--self-test" in sys.argv:
        problem = self_test()
        print(problem or "self-test: a planted disagreement is reported")
        return 1 if problem else 0

    problem = self_test()
    if problem:
        print(f"FAIL: {problem}")
        return 1

    missing = [p for p in [FIXTURE, *SWIFT_SOURCES, os.path.join(CRATE, "Cargo.toml")]
               if not os.path.isfile(os.path.join(ROOT, p))]
    if missing:
        print("FAIL: nothing to compare -- these are not there:")
        for p in missing:
            print(f"  {p}")
        return 1
    for tool in ("cargo", "swift"):
        if shutil.which(tool) is None:
            print(f"FAIL: `{tool}` is not on the path, so one side cannot be run. "
                  "This comparison is not skipped; run it where both are.")
            return 1

    fixture = os.path.join(ROOT, FIXTURE)
    work = tempfile.mkdtemp(prefix="control-room-agree-")
    try:
        # -- Windows: the crate ------------------------------------------------
        env = dict(os.environ, CARGO_TARGET_DIR=os.path.join(work, "cargo"))
        cmd = ["cargo", "run", "-q", "-p", "polter-control-room", "--example", "dump"]
        win = run(cmd + ["--offline", "--", fixture, HEIGHT], os.path.join(ROOT, "windows"), env)
        if win.returncode != 0 and "offline" in win.stderr:
            win = run(cmd + ["--", fixture, HEIGHT], os.path.join(ROOT, "windows"), env)
        if win.returncode != 0:
            print("FAIL: the Windows side did not run:")
            print(win.stderr.strip()[-2000:])
            return 1

        # -- macOS: the app's own source files, in a package -------------------
        src = os.path.join(work, "pkg", "Sources", "dump")
        os.makedirs(src)
        with open(os.path.join(work, "pkg", "Package.swift"), "w") as f:
            f.write(PACKAGE)
        with open(os.path.join(src, "main.swift"), "w") as f:
            f.write(MAIN)
        for p in SWIFT_SOURCES:
            os.symlink(os.path.join(ROOT, p), os.path.join(src, os.path.basename(p)))
        built = run(["swift", "build", "-c", "debug"], os.path.join(work, "pkg"))
        if built.returncode != 0:
            print("FAIL: the macOS side did not build:")
            print((built.stdout + built.stderr).strip()[-3000:])
            return 1
        mac = run([os.path.join(work, "pkg", ".build", "debug", "dump"), fixture, HEIGHT], work)
        if mac.returncode != 0:
            print("FAIL: the macOS side did not run:")
            print(mac.stderr.strip()[-2000:])
            return 1
    finally:
        shutil.rmtree(work, ignore_errors=True)

    diffs, n = compare(mac.stdout, win.stdout)
    if n == 0:
        print("FAIL: both sides printed nothing, so nothing was compared")
        return 1
    if diffs:
        print(f"FAIL: the two hosts disagree on {len(diffs)} of {n} lines.")
        for line, x, y in diffs[:40]:
            print(f"  line {line}")
            print(f"    macOS:   {x}")
            print(f"    Windows: {y}")
        return 1

    print(f"compared {n} lines: the macOS host and the Windows host agree")
    print("NOT COMPARED: pulses, the time band (the macOS host does not read them "
          "from the snapshot yet); translated text; anything drawn.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
