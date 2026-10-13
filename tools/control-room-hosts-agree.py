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
what each frame is -- the glyph and the word being the pair the core gives
for the title's right end, `held` among them; what the core says of every group's
supervisor (its state, whether one can be started, why the last try made
none, the role and the directory), what it says of the supervisor each
group last had (the CLI a start uses, the role and the CLI the last one
was, when it was last heard from) and whether a start goes on with its
session and why not -- with every one of the eight reasons the core can
give, as each side spells it; who the core says is working in every
terminal (which of its three answers, each as each side spells it; the role,
the CLI and the session as written, with "not said" told from empty; and the
terminal that opened it); the English sentence each side makes of each
reason (none for the two that need none), what the two sessions a start
can use are called, what a start sends for every state of that choice, and
the sentence about the last supervisor for thirteen mixes of what is known
of it and of where the person has picked to start -- its directory said
only when that is elsewhere, its CLI by the core's name and by its key
when the core has none (`ControlRoomStartChoice`; `scene::resume_note`, `last_supervisor_said`,
`act::session_sent`) -- the roles one can be started in and
whether there is a choice; when a group just made is selected; where a tab
the core asked for goes, for every asker and every place the control room
can be (forty cases); whether a split asked of a terminal is made, borrowed
by the control room or not, asked by an agent through the core or by a key
(`ControlRoomRules.newSplit` and `lend::may_split`); the English of what the right-hand side says of a
group with no supervisor for each of the six reasons the core gives for a
try having made none (`cli_not_found` and `cli_did_not_start`, which a
launcher reports itself, among them), while one is starting and with none;
the English of what the person is told for each of
fifteen names the core gives for not making a group or not starting a
supervisor; how the first line of a waiting row is shared out when it
is too narrow -- the status word whole, the group's name cut only by it, who
is waiting in what is left and not at all when nothing is
(`ControlRoomLine1.fit` and `scene::place_line`), on sixteen made-up rows:
who gets how wide and which of them is cut; that neither side has a row
for a terminal in no group (the rows above are each side's list as it is
drawn); every terminal that is in no group (`ungrouped`), as the row it
would have were one drawn -- its row's identity, the section it goes in, its title,
glyph and words, who waits and for what with every line, what an act on it
hands back, and the terminal the right-hand side then shows; which rows are
marked seen by being looked at, and
after how long, what the title of the frame on the right says while it
holds each row's terminal (that terminal's own name, glyph and word -- the
supervisor's, not the row's), and the request marking each row seen sends (a group's
name, or the terminal of a row that is in no group); the list's two
headings -- the count, what the rows are called and the form of the number
as the core wrote them, and the English sentence each side makes of that; the selection chip's slide -- whether it moves at all (from
one tab to another, with motion off, from nowhere, to where it already is),
when it starts back down and when it is still, and at sixteen moments of a
slide along the tab bar and of one down the list how far it has to go, how
it is stretched, how far it is lifted and whether it is over, to six
places; the panel's size and every rectangle in it -- a waiting row's
height follows what it waits on, by the nominal count of lines; how what each
waiting row waits on is fitted (the lines each step gets, the steps said only
as a number), and the fitting rule itself on fourteen made-up commands; the
nominal count on six strings; and
where the arrow keys take the selection from every row; and the allowance
block as each side read it -- every account opened out and every one in the
line, word for word and number for number, each of their windows -- and how
high each side makes the block and where its parts start; and the strip of
tabs over a pane that holds a stack -- on eighteen made-up stacks, where each
tab is and how wide, which is in front, where a hairline stands, which are
cut short, which go behind `more`, where `more`, the plus and the status are,
the same stacks with the other candidate for the least width, and which
member's glyph `more` carries for three orders the core might hand in -- and
a tab's nominal width for five names.

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
  * Where the allowance block stands in the panel, and anything it says in
    words. `windows/control-room` reads the block and adds up its height;
    the Windows host does not draw it yet, so there is no rectangle there
    to compare the macOS one with.
  * Where a pane's frame and the terminal in it go, and what the frame
    draws. On Windows that is arithmetic in the crate (`pane::frame_px`,
    `well_px`, `build`); on macOS it is SwiftUI's layout, with nothing to
    print. The crate's own tests hold it.
  * What the right-hand side says for a terminal in no group that is not
    shown (closed, or in its own tab), and the word after its name on the
    bar. On Windows that is the crate's scene; on macOS it is in the view.
    Each side's own tests hold the same sentences and the same word.
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
    "macos/Sources/Features/ControlRoom/ControlRoomStartChoice.swift",
    "macos/Sources/Features/ControlRoom/ControlRoomLending.swift",
    "macos/Sources/Features/ControlRoom/ControlRoomQuota.swift",
    "macos/Sources/Features/ControlRoom/PaneStackStrip.swift",
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
// The whole list, the terminals that are in no group among its rows: both
// hosts draw those now, so the list, its layout, its arrow keys and the row
// that breathes are compared with them in. What each of those rows is on
// its own is compared again below (`lone`).
let whole = snapshot
let list = ControlRoomList(snapshot: snapshot)

print("count waiting=\(list.waitingCount) quiet=\(list.quietCount)")
// The two headings: what the core wrote (`header_waiting` /
// `header_quiet`, which count the rows drawn: the groups'), and the sentence each
// side makes of it -- in English, as each side's table has it.
for (name, h, says) in [("waiting", list.waitingHeader, list.waitingHeaderText), ("quiet", list.quietHeader, list.quietHeaderText)] {
    let core = h.map { "\($0.count) of=\($0.of.rawValue) number=\($0.number.rawValue)" } ?? "-"
    print("heading \(name) core=\(core) says=\(quote(says))")
}

// Where a control room opens, and whose choice the selection then is.
print("open_on \(snapshot.open_on ?? "-")")
let firstRow = list.rows.first?.id
for (current, opening) in [(nil, true), (nil, false), (firstRow, true), (firstRow, false)] as [(String?, Bool)] {
    let start = ControlRoomRules.selection(current: current, opening: opening, openOn: snapshot.open_on)
    print("opening current=\(current ?? "-") opening=\(opening) selects=\(start.id ?? "-") persons=\(start.isThePersons)")
}
for r in list.waiting { row("waiting", r) }
for r in list.quiet { row("quiet", r) }
// What each row is called, and for a terminal in no group which terminal it
// is and which frame its own pane wears.
for r in list.rows {
    print("rowname id=\(r.id) name=\(quote(r.name)) alone=\(r.alone?.terminal ?? "-") pane=\(r.alone?.pane.rawValue ?? "-")")
}
// The terminals in no group. Neither host draws a row for one (task 1485,
// and the rows printed above are compared without them); what such a row
// would say is still compared, through the switch nothing in the app
// turns on.
let everything = ControlRoomList(snapshot: whole, loneRows: true)
let alone = everything.rows.filter { $0.alone != nil }
print("lone \(alone.count)")
for r in alone {
    let section = everything.waiting.contains { $0.id == r.id } ? "waiting" : "quiet"
    let since = r.target.map { String($0.sinceMs) } ?? "-"
    let event = r.target?.eventMs.map { String($0) } ?? "-"
    print("lone row=\(r.id) section=\(section) title=\(quote(r.name)) shown=\(shownName(r.shown)) word=\(quote(r.word)) "
        + "who=\(r.waiter.is.rawValue) name=\(quote(r.waiter.name)) form=\(r.what.form.rawValue) "
        + "code=\(r.what.isCode) lines=\(r.what.lines.count) unseen=\(r.unseen) "
        + "terminal=\(r.target?.terminal ?? "-") since=\(since) event=\(event) shows=\(whole.terminal(shownFor: r.id) ?? "-")")
    print("lone cut row=\(r.id) cut=\(r.what.cut.rawValue)")
    for (n, line) in r.what.drawn.enumerated() {
        print("lone what row=\(r.id) n=\(n) line=\(quote(line))")
    }
}
// The first line of a waiting row, when it is too narrow for the name, who
// is waiting and the status word: who keeps its width and who gives way.
// The same cases on both sides, in the same units.
let line1: [(Int, Int, Int?, Int)] = [
    (80, 0, 100, 40), (80, 0, 400, 40), (500, 0, 90, 40), (274, 0, 90, 40), (266, 0, 90, 40), (265, 0, 90, 40),
    (250, 0, 90, 40), (300, 0, nil, 40), (400, 0, nil, 40), (66, 0, 67, 40), (187, 0, 510, 40), (465, 0, 149, 40),
    (80, 292, 50, 40), (10, 262, 50, 40), (80, 0, 400, 0), (400, 0, nil, 0),
]
for (name, narrower, who, word) in line1 {
    let width = 322 - narrower
    let fit = ControlRoomLine1.fit(width: Double(width), gap: 8, name: Double(name), who: who.map(Double.init), word: Double(word))
    let whoSays = fit.who.map { "\(Int($0)) cut=\($0 < Double(who ?? 0))" } ?? "-"
    print("line1 width=\(width) name=\(name) who=\(who.map(String.init) ?? "-") word=\(word) "
        + "-> name=\(Int(fit.name)) cut=\(fit.name < Double(name)) who=\(whoSays)")
}
// The bare id is not a row, and a group's row is not one of these.
let bare = whole.ungrouped?.contains { ControlRoomList.rowId(ofTerminal: $0.id) == "0x00000000000000c1" } == true ? "0x00000000000000c1" : "-"
let asGroup = whole.ungrouped?.contains { ControlRoomList.rowId(ofTerminal: $0.id) == "web-app" } == true ? "web-app" : "-"
print("lone shows bare-id=\(bare) group=\(asGroup)")

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

// A group's supervisor, a group just made, where a new tab goes, and what a
// refusal of either act says.
for r in list.rows {
    if let s = r.start {
        print("start id=\(r.id) state=\(s.state.rawValue) can=\(s.canStart) failed=\(s.failed.rawValue) "
            + "role=\(s.role ?? "-") cwd=\(quote(s.cwd))")
    } else {
        print("start id=\(r.id) -")
    }
    // What the core says of the last supervisor, and whether a start goes
    // on with its session.
    if let l = r.start?.last {
        print("start_last id=\(r.id) cli=\(l.cli ?? "-") last_role=\(l.role ?? "-") "
            + "last_cli=\(l.lastCli ?? "-") heard_ms=\(l.heardMs.map { String($0) } ?? "-") "
            + "resume=\(l.canResume) why=\(l.why.rawValue) dir_is_last=\(l.cwdIsTheLastSupervisors) "
            + "cli_label=\(l.cliLabel.map(quote) ?? "-") last_cli_label=\(l.lastCliLabel.map(quote) ?? "-")")
    } else {
        print("start_last id=\(r.id) -")
    }
}
for why in ControlRoomList.SupervisorStart.ResumeWhy.allCases {
    print("resume_why \(why.rawValue)")
}
// Who the core says is working in every terminal: which of its three
// answers, the three words a project's pane keeps, and who opened it.
for t in snapshot.terminals ?? [] {
    if let w = t.who {
        print("who id=\(t.id) is=\(w.is.rawValue) role=\(w.role.map(quote) ?? "-") "
            + "cli=\(w.cli.map(quote) ?? "-") session=\(w.session.map(quote) ?? "-") "
            + "opened_by=\(w.opened_by ?? "-")")
    } else {
        print("who id=\(t.id) -")
    }
}
for one in ControlRoomSnapshot.Terminal.Who.Is.allCases {
    print("who_is \(one.rawValue)")
}
// What the right-hand side makes of that (`ControlRoomStartChoice`): the
// sentence for each reason a start will not go on with the last session
// (none for the two that need none), what the two sessions are called,
// what a start sends for every state of the choice, and the sentence about
// the last supervisor for each mix of what is known of it.
// Whether a split asked of a terminal is made: of one the control room has
// borrowed, for an agent (asked through the core) and not for a key.
for lent in [false, true] {
    for core in [false, true] {
        let made = ControlRoomRules.newSplit(lent: lent, answerWanted: core) == .split
        print("new_split lent=\(lent) asked_by_core=\(core) made=\(made)")
    }
}
for why in ControlRoomList.SupervisorStart.ResumeWhy.allCases {
    print("resume_note \(why.rawValue) says=\(ControlRoomStartChoice.resumeNote(why).map(quote) ?? "-")")
}
for session in ControlRoomStartChoice.Session.allCases {
    print("session_option \(session.rawValue) says=\(quote(ControlRoomStartChoice.optionText(session)))")
}
for offered in [true, false] {
    for picked in [nil, ControlRoomStartChoice.Session.last, .new] as [ControlRoomStartChoice.Session?] {
        let sent = ControlRoomStartChoice.sessionSent(offered: offered, picked: picked)
        print("session_sent offered=\(offered) picked=\(picked?.rawValue ?? "-") sends=\(sent?.rawValue ?? "-")")
    }
}
do {
    typealias Start = ControlRoomList.SupervisorStart
    // (name, heard, the directory, it is the last supervisor's, its CLI, the core's name for it,
    //  the directory the person picked, can go on)
    let cases: [(String, Int64?, String, Bool, String?, String?, String?, Bool)] = [
        ("unpicked", 1, "/Users/me/work", true, "claude-code", "Claude Code", nil, true),
        ("picked-the-same", 1, "/Users/me/work", true, "claude-code", "Claude Code", "/Users/me/work", true),
        ("picked-elsewhere", 1, "/Users/me/work", true, "claude-code", "Claude Code", "/srv/other", true),
        ("home-itself", 1, "/Users/me", true, "claude-code", "Claude Code", "/srv/other", true),
        ("no-name-for-the-cli", 1, "/Users/me/work", true, "claude-code", nil, "/srv/other", false),
        ("an-empty-name", 1, "/Users/me/work", true, "claude-code", "", nil, false),
        ("directory-is-a-guess", 1, "/Users/me/work", false, "claude-code", "Claude Code", "/srv/other", true),
        ("no-directory", 1, "", true, "codex", nil, "/srv/other", false),
        ("cli-not-written", 1, "/Users/me/work", true, nil, nil, "/srv/other", false),
        ("cli-not-written-unpicked", 1, "/Users/me/work", true, nil, nil, nil, false),
        ("cli-empty", 1, "/Users/me/work", true, "", "Claude Code", "/srv/other", false),
        ("never-recorded", nil, "/Users/me/work", true, "claude-code", "Claude Code", "/srv/other", false),
    ]
    for (name, heard, cwd, isLast, cli, label, picked, can) in cases {
        let start = Start(state: .absent, canStart: true, failed: Start.Failure.none, role: nil, cwd: cwd,
                          last: .init(cli: "claude-code", role: nil, lastCli: cli, heardMs: heard, canResume: can,
                                      why: can ? .none : .noSession, cwdIsTheLastSupervisors: isLast,
                                      cliLabel: "Claude Code", lastCliLabel: label))
        let said = ControlRoomStartChoice.lastSupervisorText(start, startingIn: picked, home: "/Users/me")
        print("last_said \(name) offers=\(ControlRoomStartChoice.offersSession(start)) says=\(said.map(quote) ?? "-")")
    }
    let old = Start(state: .absent, canStart: true, failed: Start.Failure.none, role: nil, cwd: "/Users/me/work")
    print("last_said core-says-nothing offers=\(ControlRoomStartChoice.offersSession(old)) "
        + "says=\(ControlRoomStartChoice.lastSupervisorText(old, home: "/Users/me").map(quote) ?? "-")")
}
// What the right-hand side says of a group with no supervisor, for every
// reason the core gives for the last try having made none -- the two a
// launcher reports itself among them -- and while one is on its way.
for failed in ControlRoomList.SupervisorStart.Failure.allCases {
    let start = ControlRoomList.SupervisorStart(state: .failed, canStart: true, failed: failed, role: nil, cwd: "")
    print("start_says state=failed failed=\(failed.rawValue) "
        + "says=\(quote(ControlRoomLending.words(for: .noSupervisor(group: "g"), start: start)))")
}
for state in [ControlRoomList.SupervisorStart.State.starting, .absent] {
    let start = ControlRoomList.SupervisorStart(state: state, canStart: false, failed: .none, role: nil, cwd: "")
    print("start_says state=\(state.rawValue) failed=none "
        + "says=\(quote(ControlRoomLending.words(for: .noSupervisor(group: "g"), start: start)))")
}
print("start_roles choose=\(list.chooseSupervisorRole)")
for role in list.supervisorRoles {
    print("start_role key=\(role.key) name=\(quote(role.name))")
}
for awaited in ["billing", "not-yet", nil] as [String?] {
    print("made awaited=\(awaited ?? "-") select=\(ControlRoomRules.madeGroupToSelect(awaited, in: list.rows) ?? "-")")
}
let tabAskers: [(lent: Bool, hasHome: Bool)?] = [nil, (false, false), (false, true), (true, false), (true, true)]
func homeName(_ h: ControlRoomRules.NewTab.Home) -> String {
    switch h {
    case .askers: return "askers"
    case .controlRooms: return "control_rooms"
    case .frontmost: return "frontmost"
    }
}
for asker in tabAskers {
    for bits in 0..<16 {
        let (person, front, beside, any) = (bits & 8 != 0, bits & 4 != 0, bits & 2 != 0, bits & 1 != 0)
        let to: String
        switch ControlRoomRules.newTab(asker: asker, byPerson: person, controlRoomInFront: front, tabsBesideControlRoom: beside, anyTerminalWindow: any) {
        case .inFront(let h): to = "in_front(\(homeName(h)))"
        case .behind(let h): to = "behind(\(homeName(h)))"
        case .ownWindow: to = "own_window"
        case .refused: to = "refused"
        }
        let who = asker.map { "lent=\($0.lent),home=\($0.hasHome)" } ?? "app"
        print("new_tab asker=\(who) person=\(person) front=\(front) beside=\(beside) any=\(any) -> \(to)")
    }
}
for name in ["BadName", "GroupExists", "TooManyGroups", "HasSupervisor", "AlreadyStarting", "NoSupervisorRole", "NoSuchPersona",
             "NotASupervisorRole", "NoCli", "NotAbsolute", "NoSuchDirectory", "NotADirectory", "OpenFailed", "NoRuntime", "NoExecutable"] {
    print("refusal \(name) says=\(quote(ControlRoomActions.Refusal(name: name).message))")
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
                + "name=\(quote(d.title.name)) shown=\(d.title.shown.rawValue) word=\(quote(d.title.word))")
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
// What the title of the frame on the right says while it holds each row's
// terminal: that terminal's own name, glyph and word.
for r in list.rows {
    if let t = r.supervisor {
        print("frame_title row=\(r.id) name=\(quote(t.name)) shown=\(shownName(t.shown)) word=\(quote(t.word))")
    } else {
        print("frame_title row=\(r.id) -")
    }
}
// What marking a row seen sends, for every row as if nobody had looked at
// it: a group's by the group's name, a lone terminal's by the terminal.
for r in list.rows {
    let sends = ControlRoomActions.seen(rowId: r.id, in: list.rows)
        .flatMap { try? JSONSerialization.data(withJSONObject: ControlRoomActions.request(for: $0), options: [.sortedKeys]) }
        .map { String(decoding: $0, as: UTF8.self) } ?? "-"
    print("seen_sends row=\(r.id) \(sends)")
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

func windowsText(_ ws: [ControlRoomQuota.Window]) -> String {
    ws.map { "\($0.span.rawValue):\($0.used):\($0.live):\($0.resets_ms)" }.joined(separator: ",")
}
func agoText(_ a: ControlRoomQuota.Ago?) -> String { a.map { "\($0.unit.rawValue):\($0.n)" } ?? "-" }
if let q = list.quota {
    for a in q.alerts {
        print("quota alert family=\(a.family.rawValue) level=\(a.level.rawValue) span=\(a.span.rawValue) "
            + "used=\(a.used) resets=\(a.resets_ms) when=\(a.when.form.rawValue):\(a.when.n) "
            + "stale=\(agoText(a.stale)) way_out=\(a.way_out?.rawValue ?? "-") at=\(a.at_ms) "
            + "windows=\(windowsText(a.windows))")
    }
    if let line = q.line {
        print("quota line label=\(line.label.rawValue) entries=\(line.entries.count)")
        for e in line.entries {
            print("quota entry family=\(e.family.rawValue) state=\(e.state.rawValue) "
                + "used=\(e.used.map { String($0) } ?? "-") span=\(e.span?.rawValue ?? "-") "
                + "stale=\(agoText(e.stale)) at=\(e.at_ms.map { String($0) } ?? "-") "
                + "windows=\(windowsText(e.windows))")
        }
    } else {
        print("quota line none")
    }
    let ql = ControlRoomQuotaLayout(quota: q)
    for p in ql.parts {
        print("quota part y=\(f(p.y)) h=\(f(p.height)) note=\(p.note)")
    }
    print("quota height=\(f(ql.height)) line_y=\(ql.lineY.map { f($0) } ?? "-")")
} else {
    print("quota none")
}

let stripCases: [([CGFloat], Int, CGFloat, CGFloat)] = [
    ([], 0, 400, 0),
    ([60], 0, 300, 0),
    ([100, 60, 60], 1, 400, 50),
    ([60, 60, 60, 60], 0, 600, 0),
    ([60, 60, 60, 60], 2, 600, 0),
    ([60, 60, 60, 60], 3, 600, 0),
    ([200, 60, 200, 60], 1, 460, 0),
    ([200, 60, 200, 60], 0, 460, 0),
    ([200, 72, 200, 200], 1, 336, 0),
    ([200, 72, 200, 200], 1, 335, 0),
    ([100, 100, 100, 100, 100, 100, 100, 100], 6, 400, 0),
    ([100, 100, 100, 100, 100, 100, 100, 100], 1, 400, 0),
    ([120, 80], 0, 200, 60),
    ([120, 80], 0, 330, 60),
    ([60, 60], 7, 400, 0),
    ([94, 70, 48, 126, 56, 150, 78], 3, 520, 70),
    ([94, 70, 48, 126, 56, 150, 78, 94, 56, 142, 78, 56], 9, 520, 70),
    ([300], 0, 100, 40),
]
for (n, c) in stripCases.enumerated() {
    let sl = PaneStackStripLayout(wants: c.0, current: c.1, width: c.2, status: c.3)
    let tabs = sl.tabs.map { t in
        "\(t.member)@\(f(t.x))+\(f(t.width))\(t.current ? "*" : "")\(t.separatorBefore ? "|" : "")\(t.squeezed ? "~" : "")"
    }
    let status = sl.status.map { "\(f($0.lowerBound))..\(f($0.upperBound))" } ?? "-"
    print("strip \(n) tabs=[\(tabs.joined(separator: " "))] hidden=[\(sl.hidden.map(String.init).joined(separator: ","))] "
        + "more=\(sl.moreX.map { f($0) } ?? "-") add=\(f(sl.addX)) status=\(status)")
}
for (n, c) in stripCases.enumerated() {
    let sl = PaneStackStripLayout(wants: c.0, current: c.1, width: c.2, status: c.3, minWidth: 68)
    let widths = sl.tabs.map { "\($0.member):\(f($0.width))" }
    let table = PaneStackStripLayout(wants: c.0, current: c.1, width: c.2, status: c.3)
    let carried = [[6, 4, 0, 2], [0, 2, 4, 9, 11], []].map { table.behindMore(urgent: $0).map(String.init) ?? "-" }
    print("strip \(n) at68=[\(widths.joined(separator: " "))] hidden68=\(sl.hidden.count) carries=\(carried.joined(separator: "/"))")
}
for name in ["", "api", "frontend", "任务", "billing-worker"] {
    print("strip nominal \(quote(name)) plain=\(f(PaneStackStripLayout.nominalWidth(name: name, glyph: false))) "
        + "glyph=\(f(PaneStackStripLayout.nominalWidth(name: name, glyph: true)))")
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
// The chip's slide: whether it moves, when it starts down, when it is
// still, and where it is at the same moments on both sides.
func g(_ v: Double) -> String { String(format: "%.6f", v) }
func planName(_ p: ControlRoomChipSlide.Plan) -> String {
    switch p {
    case .jump: return "jump"
    case let .slide(dx, dy): return "slide dx=\(g(dx)) dy=\(g(dy))"
    }
}
let tabWas = CGRect(x: 0, y: 0, width: 293, height: 24), tabNow = CGRect(x: 588, y: 0, width: 292, height: 24)
let rowWas = CGRect(x: 6, y: 38, width: 368, height: 100), rowNow = CGRect(x: 6, y: 146, width: 368, height: 80)
print("slide plan tab still=false \(planName(ControlRoomChipSlide.plan(from: tabWas, to: tabNow, reduceMotion: false)))")
print("slide plan tab still=true \(planName(ControlRoomChipSlide.plan(from: tabWas, to: tabNow, reduceMotion: true)))")
print("slide plan row still=false \(planName(ControlRoomChipSlide.plan(from: rowWas, to: rowNow, reduceMotion: false)))")
print("slide plan nowhere still=false \(planName(ControlRoomChipSlide.plan(from: nil, to: tabNow, reduceMotion: false)))")
print("slide plan same still=false \(planName(ControlRoomChipSlide.plan(from: tabNow, to: tabNow, reduceMotion: false)))")
print("slide lands_at=\(g(ControlRoomChipSlide.landsAt)) duration=\(g(ControlRoomChipSlide.duration))")
let moments: [Double] = [0, 0.01, 0.035, 0.07, 0.1, 0.11, 0.15, 0.2, 0.26, 0.3, 0.36, 0.4, 0.405, 0.41, 0.5, 1]
for (name, dx, dy, scale) in [("tab", -587.5, 0.0, ControlRoomLook.Selection.liftScaleWindowTab),
                              ("row", 0.0, -98.0, ControlRoomLook.Selection.liftScaleRow)] {
    for t in moments {
        let s = ControlRoomChipSlide.sample(at: t, dx: dx, dy: dy, liftScale: scale)
        print("slide \(name) t=\(g(t)) dx=\(g(s.dx)) dy=\(g(s.dy)) along=\(g(s.along)) across=\(g(s.across)) "
            + "lift=\(g(ControlRoomChipSlide.lift(at: t))) over=\(t >= ControlRoomChipSlide.duration)")
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
