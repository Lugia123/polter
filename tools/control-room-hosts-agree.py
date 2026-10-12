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
  * macOS: `ControlRoomList.swift`, `ControlRoomLook.swift`,
    `ControlRoomActions.swift` and `ControlRoomRules.swift` from
    `macos/Sources/Features/ControlRoom/`,
    and `macos/Sources/Features/Terminal/TabAccessory.swift` -- **the same
    source files the app compiles**, linked into a throwaway SwiftPM package
    with a `main.swift` that prints the same lines. No app is built and
    nothing is launched.

Both read `src/poltergeist/testdata/control_snapshot.json`, the fixture a
Zig test holds to what `ControlRoom.zig` actually produces.

**What is compared**: the two counts in the headers; the group a control
room opens on, and what is then selected and whether it is the person's
own choice, for a control room just opened and one long open, with and
without a selection standing; every row -- its
section, its place, its glyph, its words, who is waiting (which of the
core's five answers, and the name), what it waits on (which of the core's
four forms, whether that is set as code, how many lines, whether the core
says that is all of it, and every line as the row sets it, the mark for a
missing part included), its "N more", whether the core says nobody has
looked at it, and the terminal and two moments an act on it hands back;
which row of the list breathes, with nothing in front
and with each tab that holds a waiting terminal in front; which terminal
breathes among one window's tabs, for the same fronts, and in a window that
holds none; every window tab the snapshot lists -- its glyph, whether that
glyph is drawn on a tab at all, and whether it breathes, for the same
fronts -- a tab it does not list, and for each of the five glyphs whether a
window tab draws it; which frame the pane of every terminal wears
(`PaneFrame.drawn` and `pane::drawn`) -- every terminal the snapshot lists,
one it does not and none at all, in a split tab, alone in its tab, with the
setting off and in the quick terminal: the frame, the name, the glyph and
the word -- whether the tab's ground then shows, and the English word for
what each frame is; which rows are marked seen by being looked at, and
after how long; the panel's size and every rectangle in it -- a waiting row's
height follows what it waits on, by the nominal count of lines; how what each
waiting row waits on is fitted (the lines each step gets, the steps said only
as a number), and the fitting rule itself on fourteen made-up commands; the
nominal count on six strings; and
where the arrow keys take the selection from every row.

**NOT COMPARED, and why.**

  * The snapshot's own `now_ms`. The macOS list does not keep it, so one
    side has nothing to print.
  * The words "who is waiting" becomes ("Supervisor", "<name>, via the
    supervisor"). Compared is which of the core's answers each side read;
    each side's own tests hold the words.
  * What is around the seen rule: that the selection moving on, or the
    control room not being in front, calls the mark off. Each side's own
    tests hold that; here the wait is over at once and it is in front.
  * A snapshot with no `unseen` or no `tabs`. The macOS host reads one as
    nothing unseen and no tabs; `windows/control-room` refuses it, as it
    does one with no `pulses`. The fixture has all three.
  * A front tab that is not in the window asked about. The macOS list is
    told only the tab; the crate is told the window too. Each front is
    asked with the window that tab is in, which is the only way a host asks.
  * Translated text. Both sides print the English they start from.
  * Where a pane's frame and the terminal in it go, and what the frame
    draws. On Windows that is arithmetic in the crate (`pane::frame_px`,
    `well_px`, `build`); on macOS it is SwiftUI's layout, with nothing to
    print. The crate's own tests hold it.
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
    "macos/Sources/Features/ControlRoom/ControlRoomActions.swift",
    "macos/Sources/Features/ControlRoom/ControlRoomRules.swift",
    "macos/Sources/Features/ControlRoom/ControlRoomLending.swift",
    "macos/Sources/Features/ControlRoom/PaneFrame.swift",
    "macos/Sources/Features/Terminal/TabAccessory.swift",
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
    let since = r.target.map { String($0.sinceMs) } ?? "-"
    let event = r.target?.eventMs.map { String($0) } ?? "-"
    print("row section=\(section) id=\(r.id) shown=\(shownName(r.shown)) word=\(quote(r.word)) "
        + "who=\(r.waiter.is.rawValue) name=\(quote(r.waiter.name)) form=\(r.what.form.rawValue) "
        + "code=\(r.what.isCode) lines=\(r.what.lines.count) others=\(r.others) "
        + "unseen=\(r.unseen) terminal=\(r.target?.terminal ?? "-") since=\(since) event=\(event)")
    print("cut id=\(r.id) cut=\(r.what.cut.rawValue)")
    for (n, line) in r.what.drawn.enumerated() {
        print("what id=\(r.id) n=\(n) line=\(quote(line))")
    }
}

let args = CommandLine.arguments
guard args.count == 3, let height = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: dump <snapshot.json> <height>\n".utf8))
    exit(2)
}
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let snapshot: ControlRoomSnapshot
do {
    snapshot = try JSONDecoder().decode(ControlRoomSnapshot.self, from: data)
} catch {
    FileHandle.standardError.write(Data("the snapshot does not decode: \(error)\n".utf8))
    exit(1)
}
let list = ControlRoomList(snapshot: snapshot)

print("count waiting=\(list.waitingCount) quiet=\(list.quietCount)")

// Where a control room opens, and whose choice the selection then is.
print("open_on \(snapshot.open_on ?? "-")")
let firstRow = list.rows.first?.id
for (current, opening) in [(nil, true), (nil, false), (firstRow, true), (firstRow, false)] as [(String?, Bool)] {
    let start = ControlRoomRules.selection(current: current, opening: opening, openOn: snapshot.open_on)
    print("opening current=\(current ?? "-") opening=\(opening) selects=\(start.id ?? "-") persons=\(start.isThePersons)")
}
for r in list.waiting { row("waiting", r) }
for r in list.quiet { row("quiet", r) }

// Which glyph breathes: with nothing in front, and with each tab that
// holds a waiting terminal in front.
let pulses = snapshot.pulses ?? []
var fronts: [String?] = [nil]
var windows: [String] = []
for p in pulses {
    if let tab = p.tab, !fronts.contains(tab) { fronts.append(tab) }
    if let window = p.window, !windows.contains(window) { windows.append(window) }
}
// And a window none of them is in.
windows.append("0x00000000000000ff")
print("pulses \(pulses.count)")
for front in fronts {
    let breathing = ControlRoomList(snapshot: snapshot, showing: front).rows.filter { $0.pulses }.map { $0.id }
    print("pulse list showing=\(front ?? "-") rows=\(breathing.isEmpty ? "-" : breathing.joined(separator: ","))")
}
for window in windows {
    for front in fronts {
        let p = ControlRoomPulse.first(of: pulses, inWindow: window, notIn: front)
        print("pulse window=\(window) showing=\(front ?? "-") terminal=\(p?.terminal ?? "-") tab=\(p?.tab ?? "-")")
    }
}

// What each window tab carries, for the same fronts; then a tab the core
// does not list, and every glyph there is.
let tabs = snapshot.tabs ?? []
print("tabs \(tabs.count)")
for t in tabs {
    print("tab \(t.tab) window=\(t.window ?? "-") shown=\(shownName(t.shown)) "
        + "draws=\(TabAccessory.drawsOnWindowTab(t.shown))")
    guard let window = t.window else { continue }
    for front in fronts {
        let st = ControlRoomPulse.status(ofTab: t.tab, inWindow: window, showing: front, in: snapshot)
        print("tab_status tab=\(t.tab) showing=\(front ?? "-") shown=\(shownName(st.shown)) pulses=\(st.pulses)")
    }
}
let unlisted = ControlRoomPulse.status(
    ofTab: "0x00000000000000fe", inWindow: windows[0], showing: nil, in: snapshot)
print("tab_status tab=unlisted showing=- shown=\(shownName(unlisted.shown)) pulses=\(unlisted.pulses)")
for s in ControlRoomList.Shown.allCases {
    print("tab_draws shown=\(shownName(s)) draws=\(TabAccessory.drawsOnWindowTab(s))")
}

// The frame each pane of a split terminal tab wears.
let terminals = snapshot.terminals ?? []
var paneIDs: [String?] = terminals.map { $0.id }
paneIDs.append("0x00000000000000fe")
paneIDs.append(nil)
print("panes \(terminals.count)")
let panePlaces: [(String, PaneFrame.Place)] = [
    ("split", .init(enabled: true, quickTerminal: false, alone: false)),
    ("alone", .init(enabled: true, quickTerminal: false, alone: true)),
    ("off", .init(enabled: false, quickTerminal: false, alone: false)),
    ("quick", .init(enabled: true, quickTerminal: true, alone: false)),
]
for (placeName, place) in panePlaces {
    var all: [PaneFrame.Drawn?] = []
    for id in paneIDs {
        let d = PaneFrame.drawn(terminal: id, ownName: "own", at: place, in: terminals)
        if let d {
            print("pane place=\(placeName) terminal=\(id ?? "-") wears=\(d.wears.rawValue) "
                + "name=\(quote(d.title.name)) shown=\(shownName(d.title.shown)) word=\(quote(d.title.word))")
        } else {
            print("pane place=\(placeName) terminal=\(id ?? "-") wears=-")
        }
        all.append(d)
    }
    print("pane_ground place=\(placeName) shows=\(PaneFrame.groundShows(all))")
}
let noSnapshot = PaneFrame.drawn(terminal: "0x00000000000000a1", ownName: "own", at: panePlaces[0].1, in: nil)
print("pane no-snapshot wears=\(noSnapshot?.wears.rawValue ?? "-") name=\(quote(noSnapshot?.title.name ?? ""))")
for w in PaneFrame.Kind.allCases {
    print("pane_role wears=\(w.rawValue) word=\(PaneFrame.roleWord(w).map(quote) ?? "-")")
}

// Looking at a row: which are marked seen, and after how long. The wait is
// over at once and the control room is in front.
for r in list.rows {
    var said = "-"
    let tracker = ControlRoomSeenTracker(
        later: { after, work in
            said = "after=\(f(CGFloat(after)))"
            work()
        },
        isInFront: { true },
        markSeen: { said += " marks=\($0)" })
    tracker.selectionChanged(to: r)
    print("seen row=\(r.id) \(said)")
}

// Which terminal is shown on the right, through one script of events: what
// each asks to be done, in order, and what the right side shows after it.
// (`present: false` is the Windows side's `Gone`; its `Elsewhere` -- a
// supervisor in another window, which macOS moves and Windows does not --
// has no counterpart here and is not in the script.)
do {
    var lending = ControlRoomLending()
    func sel(_ g: String?, _ s: String?, _ present: Bool) -> ControlRoomLending.Event {
        .selected(group: g, supervisor: s, present: present)
    }
    let script: [(String, ControlRoomLending.Event)] = [
        ("select a/t1", sel("a", "t1", true)), ("select b/t2", sel("b", "t2", true)),
        ("select b/t2 again", sel("b", "t2", true)), ("select c/t2", sel("c", "t2", true)),
        ("select d/none", sel("d", nil, false)), ("select a/t1", sel("a", "t1", true)),
        ("reclaim t1", .reclaimed(terminal: "t1")), ("select a/t1", sel("a", "t1", true)),
        ("ask", .askedFor), ("ask again", .askedFor), ("home gone t9", .homeGone(terminal: "t9")),
        ("home gone t1", .homeGone(terminal: "t1")), ("select a/t1 gone", sel("a", "t1", false)),
        ("select a/t1", sel("a", "t1", true)), ("select a/t1 gone", sel("a", "t1", false)),
        ("select a/t1", sel("a", "t1", true)), ("close", .closing), ("close again", .closing),
        ("select nothing", sel(nil, nil, false)),
    ]
    for (n, (name, event)) in script.enumerated() {
        let effects = lending.handle(event).map { effect -> String in
            switch effect {
            case let .giveBack(terminal, toHome, focus): return "back(\(terminal),home=\(toHome),focus=\(focus))"
            case let .borrow(loan): return "borrow(\(loan.group),\(loan.terminal))"
            }
        }
        var shows: String
        switch lending.detail {
        case .nothingSelected: shows = "nothing"
        case let .noSupervisor(group): shows = "no-supervisor(\(group))"
        case let .supervisorGone(group): shows = "gone(\(group))"
        case let .takenBack(loan): shows = "taken-back(\(loan.group),\(loan.terminal))"
        case let .terminal(loan): shows = "terminal(\(loan.group),\(loan.terminal))"
        }
        let loan = lending.loan.map { "\($0.group),\($0.terminal)" } ?? "-"
        print("lend \(n) \(quote(name)) does=[\(effects.joined(separator: " "))] shows=\(shows) loan=\(loan)")
    }
}

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
for r in list.waiting {
    let fit = lay.fits[r.id] ?? .none
    print("fit id=\(r.id) lines=\(fit.lines.map(String.init).joined(separator: "+")) hidden=\(fit.hidden) drawn=\(fit.drawn)")
}
print("ask w=\(f(ControlRoomListLayout.askWidth))")
let fits: [[Int]] = [
    [], [1], [2], [5], [1, 1], [3, 1], [1, 3], [2, 2], [1, 1, 1], [4, 4, 4], [2, 1, 1, 1],
    [1, 1, 1, 1, 1, 1], [1, 1, 1, 1, 1, 1, 1], [9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9],
]
for wanted in fits {
    let fit = ControlRoomAskFit.fit(needed: wanted)
    print("fit-of \(wanted.map(String.init).joined(separator: "+")) "
        + "lines=\(fit.lines.map(String.init).joined(separator: "+")) hidden=\(fit.hidden) drawn=\(fit.drawn)")
}
let nominal = [
    "", "git push", "rm -rf dist/ .cache/ node_modules/.vite && x",
    "01234567890123456789012345678901234567890", "012345678901234567890123456789012345678901",
    "发票编号要按租户分开，还是全局连续？分开的话，旧发票要不要一起改编号？",
]
for text in nominal {
    print("nominal \(quote(text)) lines=\(ControlRoomList.nominalLines(text))")
}
rect("separator", lay.separator)
rect("quiet_header", lay.quietHeader)
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
    print("NOT COMPARED: the snapshot's own now_ms (the macOS list does not keep it); "
          "a snapshot with no unseen or no tabs; what calls a seen mark off; "
          "translated text; anything drawn.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
