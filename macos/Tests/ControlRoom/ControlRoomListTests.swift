import CoreGraphics
import Foundation
import Testing
@testable import Ghostty

/// The group list's arithmetic: what a row says, where things are, where the
/// selection goes, how the chip gets there.
///
/// **What these are not.** Nothing here asks which rows there should be or
/// what order they are in. That is the core's, and a test of it here would
/// be the host deciding it a second time.
struct ControlRoomListTests {
    typealias Look = ControlRoomLook
    let list = ControlRoomList.sample

    // MARK: What a row says

    @Test func othersAreSaidOnlyWhenThereAreSome() {
        // The words are the translation table's; what is this code's is
        // whether anything is said, and that the number said is the one given.
        #expect(ControlRoomList.othersText(0) == nil)
        let one = ControlRoomList.othersText(1) ?? ""
        #expect(one.contains("1"))
        let three = ControlRoomList.othersText(3) ?? ""
        #expect(three.contains("3") && !three.contains("1"))
    }

    @Test func theTooltipIsEveryStepWholeAndThereIsNoneForNothing() {
        let command = ControlRoomList.tooltip(for: list.waiting[1])
        #expect(command == "rm -rf dist/ .cache/ node_modules/.vite\n&& npm ci\n&& npm run build -- --mode production")
        let nothing = ControlRoomList.tooltip(for: list.quiet[3])
        #expect(nothing == nil)
    }

    @Test func theCountsShownAreTheOnesHandedIn() {
        // Not `waiting.count`: a list handed 7 says 7 whatever it holds.
        var odd = list
        odd.waitingCount = 7
        odd.quietCount = 0
        #expect(odd.waiting.count == 4)
        #expect(odd.waitingCount == 7)
        #expect(odd.quietCount == 0)
    }

    // MARK: From the core's snapshot

    /// The core's shape, cut down to two groups that wait and one that does
    /// not. Field for field what `ControlRoom.zig` writes, including ones
    /// this side does not read.
    private let snapshot = Data("""
    { "rev": 9, "now_ms": 6000000, "needs_me": 2, "groups_needing_me": 5, "groups_other": 8,
      "groups": [
        { "name": "web-app", "brief": "", "steward": "0x00000000000000a1",
          "needs_me": true, "unseen": false, "shown": "needs_you", "word": "needs_approval", "text": "等批准",
          "waiter": {"is": "worker_via_supervisor", "name": "ios-build"},
          "reason": {"from": "hook_note", "text": "Bash(rm -rf dist/ && npm ci)", "missing": null},
          "what": {"cut": "none", "form": "command", "lines": ["rm -rf dist/", "&& npm ci"]},
          "more": 1, "same_as": null, "members": [] },
        { "name": "infra", "needs_me": false, "unseen": true, "shown": "done_unseen", "word": "done_unseen",
          "text": "做完了，没看", "waiter": {"is": "none", "name": ""},
          "reason": {"from": "last_turn", "text": "", "missing": "no_turn_kept"},
          "what": {"cut": "none", "form": "none", "lines": []}, "more": 0, "same_as": null },
        { "name": "web-app-docs", "needs_me": true, "unseen": false, "shown": "trouble", "word": "failed",
          "text": "出错", "waiter": {"is": "supervisor", "name": ""},
          "reason": {"from": "hook_detail", "text": "限流", "missing": null},
          "what": {"cut": "none", "form": "words", "lines": ["限流"]}, "more": 0, "same_as": "web-app" }
      ], "ungrouped": [], "terminals": [], "tabs": [] }
    """.utf8)

    @Test func aRowIsACopyOfWhatTheSnapshotSays() throws {
        let made = try ControlRoomList.decode(snapshot: snapshot)
        let row = made.waiting[0]
        #expect(row.id == "web-app")
        #expect(row.shown == .needsYou)
        #expect(row.word == "等批准")
        // Who is waiting and for what are the core's, copied: the steps as
        // it cut them, none joined and none dropped.
        #expect(row.waiter == ControlRoomList.Waiter(is: .workerViaSupervisor, name: "ios-build"))
        #expect(row.what.form == .command)
        #expect(row.what.lines == ["rm -rf dist/", "&& npm ci"])
        #expect(row.what.isCode == true)
        #expect(row.others == 1)
    }

    @Test func theCountsAreTheSnapshotsAndNotTheNumberOfRows() throws {
        // The snapshot says 5 and 8 while holding 2 and 1: the list says 5 and 8.
        let made = try ControlRoomList.decode(snapshot: snapshot)
        #expect(made.waiting.count == 2)
        #expect(made.quiet.count == 1)
        #expect(made.waitingCount == 5)
        #expect(made.quietCount == 8)
    }

    @Test func eachRowGoesWhereItsOwnFlagSaysAndKeepsTheSnapshotsOrder() throws {
        let made = try ControlRoomList.decode(snapshot: snapshot)
        let waiting = made.waiting.map(\.id)
        #expect(waiting == ["web-app", "web-app-docs"])
        let quiet = made.quiet.map(\.id)
        #expect(quiet == ["infra"])
        #expect(made.quiet[0].waiter == .none)
        #expect(made.quiet[0].what == .none)
    }

    @Test func whetherItIsSetAsCodeIsTheCoresFormAndNotWhereTheWordsCameFrom() throws {
        // The second waiting row's words came from a hook too, and are a
        // sentence: the core says `words`.
        let made = try ControlRoomList.decode(snapshot: snapshot)
        let row = made.waiting[1]
        #expect(row.what.form == .words)
        #expect(row.what.isCode == false)
        #expect(row.waiter.is == .supervisor)
    }

    @Test func aPartIsMarkedWhereTheRestWouldBeAndNeverShownAsTheWhole() throws {
        typealias What = ControlRoomList.What
        let whole = What(cut: .none, form: .words, lines: ["用哪个分支？"])
        #expect(whole.drawn == ["用哪个分支？"])
        // The end of a turn: something came before it.
        let end = What(cut: .head, form: .words, lines: ["先切一半，还是一次切完？"])
        #expect(end.drawn == ["… 先切一半，还是一次切完？"])
        // A summary that reached its limit: something may come after, and
        // the mark goes after the last step, not after each.
        let start = What(cut: .tail, form: .command, lines: ["rm -rf dist/", "&& npm ci --prefer-off"])
        #expect(start.drawn == ["rm -rf dist/", "&& npm ci --prefer-off …"])
        #expect(What(cut: .tail, form: .none, lines: []).drawn.isEmpty)

        // Everything that shows a row shows the mark: read out, the
        // pointer's tooltip, the line of a row that needs nothing.
        var row = list.waiting[0]
        row.what = end
        #expect(ControlRoomList.spoken(row).contains("… 先切一半"))
        #expect(ControlRoomList.tooltip(for: row) == "… 先切一半，还是一次切完？")
        #expect(ControlRoomList.quietText(row) == "… 先切一半，还是一次切完？")
        // And the row is as high as the marked lines, not the bare ones.
        var asked: [String] = []
        var marked = list
        marked.waiting[0] = row
        _ = ControlRoomListLayout(list: marked, height: 824) { text, _ in
            asked.append(text)
            return 1
        }
        #expect(asked.contains("… 先切一半，还是一次切完？"))

        // The core's word, copied: the fixture's "done, not looked at" row
        // is the last line of a longer turn.
        let made = try ControlRoomList.decode(snapshot: Self.fixture())
        let infra = try #require(made.rows.first { $0.id == "infra" })
        #expect(infra.what.cut == .head)
        let web = try #require(made.rows.first { $0.id == "web-app" })
        #expect(web.what.cut == .none)
    }

    @Test func aSnapshotThatDoesNotSayWhoWaitsOrForWhatIsNotRead() {
        // Not read as "nobody" and "nothing": a row that silently lost what
        // it waits on would look like a group with nothing to say.
        let text = String(bytes: snapshot, encoding: .utf8) ?? ""
        for field in ["\"waiter\"", "\"what\""] {
            let cut = text.replacingOccurrences(of: field, with: "\"gone\"")
            #expect(cut != text)
            #expect(throws: DecodingError.self) {
                try ControlRoomList.decode(snapshot: Data(cut.utf8))
            }
        }
        let odd = text.replacingOccurrences(of: "\"form\": \"command\"", with: "\"form\": \"poem\"")
        #expect(odd != text)
        #expect(throws: DecodingError.self) {
            try ControlRoomList.decode(snapshot: Data(odd.utf8))
        }
        // Whether it is all of it has to be said too: left out, or a word
        // this build does not know, is not read as "all of it".
        for bad in ["\"cut\": \"none\", \"form\": \"command\"": "\"form\": \"command\"",
                    "\"cut\": \"none\", \"form\": \"words\"": "\"cut\": \"middle\", \"form\": \"words\""] {
            let cut = text.replacingOccurrences(of: bad.key, with: bad.value)
            #expect(cut != text)
            #expect(throws: DecodingError.self) {
                try ControlRoomList.decode(snapshot: Data(cut.utf8))
            }
        }
    }

    @Test func aGlyphTheHostDoesNotKnowIsAnErrorNotABlank() {
        let odd = Data((String(bytes: snapshot, encoding: .utf8) ?? "")
            .replacingOccurrences(of: "\"done_unseen\", \"word\"", with: "\"sparkles\", \"word\"").utf8)
        #expect(throws: DecodingError.self) {
            try ControlRoomList.decode(snapshot: odd)
        }
    }

    // MARK: The core's own fixture

    /// The snapshot the core's tests build and check against the code that
    /// writes it. Read from the tree, so a change of shape there is seen here.
    static func fixture() throws -> Data {
        let here = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("src/poltergeist/testdata/control_snapshot.json"))
    }

    @Test func theCoresFixtureDecodesIntoItsEightGroups() throws {
        let made = try ControlRoomList.decode(snapshot: Self.fixture())
        // The groups, in the core's order -- and after them the terminal
        // that waits in no group.
        let waiting = made.waiting.map(\.id)
        #expect(waiting == ["web-app", "web-app-docs", "mobile", "billing", "docs-site", "terminal:0x00000000000000c1"])
        let quiet = made.quiet.map(\.id)
        #expect(quiet == ["infra", "design-system", "notes"])
        // The counts are the core's, and are of the rows under each
        // heading: six wait, the lone terminal among them.
        #expect(made.waitingCount == 6)
        #expect(made.quietCount == 3)
    }

    // MARK: A terminal in no group

    @Test func aTerminalWaitingInNoGroupHasARowSoTheListShowsWhatTheDockCounts() throws {
        // The Dock's number is `needs_me`: every terminal waiting, each
        // once. The groups' rows carry all of them but the ones in no
        // group, and those were not drawn: the Dock said 6 over five rows.
        let snapshot = try JSONDecoder().decode(ControlRoomSnapshot.self, from: Self.fixture())
        let made = ControlRoomList(snapshot: snapshot)
        let alone = made.waiting.filter { $0.alone != nil }
        let lone = try #require(snapshot.ungrouped)
        #expect(alone.count == lone.filter(\.needs_me).count)
        #expect(alone.count == 1)

        let row = try #require(alone.first)
        #expect(row.alone == ControlRoomList.Alone(terminal: "0x00000000000000c1", title: "zsh — ~/work", pane: .plain))
        // It is called by its title, and is a copy of what the core says.
        #expect(row.name == "zsh — ~/work")
        #expect(row.shown == .needsYou)
        #expect(row.word == "等批准")
        #expect(row.waiter.is == .terminal)
        #expect(row.what.form == .command)
        #expect(row.what.lines == ["git push"])
        #expect(row.others == 0)
        #expect(row.target == ControlRoomList.Target(terminal: "0x00000000000000c1", sinceMs: 5_940_000, eventMs: 5_940_000))
        // Nothing to start: it is not a group without a supervisor.
        #expect(row.start == nil)
        // Nobody is named beside it: the row is the terminal.
        let who = ControlRoomList.waiterText(row.waiter)
        #expect(who == nil)
    }

    @Test func aLoneTerminalsRowCannotBeMistakenForAGroups() throws {
        // A group may be named anything in letters, digits and hyphens --
        // including what a terminal's id looks like.
        let id = ControlRoomList.rowId(ofTerminal: "0x00000000000000c1")
        #expect(id.contains(":"))
        #expect(id != "0x00000000000000c1")

        var snapshot = try JSONDecoder().decode(ControlRoomSnapshot.self, from: Self.fixture())
        // The right-hand side shows that terminal itself; a group's row
        // still shows its supervisor; a row that is neither shows nothing.
        let shownForLone = snapshot.terminal(shownFor: id)
        #expect(shownForLone == "0x00000000000000c1")
        let shownForGroup = snapshot.terminal(shownFor: "web-app")
        #expect(shownForGroup == "0x00000000000000a1")
        let shownForTheBareId = snapshot.terminal(shownFor: "0x00000000000000c1")
        #expect(shownForTheBareId == nil)
        // And with none listed there are none, not an error.
        snapshot.ungrouped = nil
        let without = ControlRoomList(snapshot: snapshot)
        let anyAlone = without.rows.contains { $0.alone != nil }
        #expect(!anyAlone)
        let gone = snapshot.terminal(shownFor: id)
        #expect(gone == nil)
    }

    @Test func aLoneTerminalGoesInTheSectionItsOwnWordSaysAndBreathesWhenItIsFirst() throws {
        var snapshot = try JSONDecoder().decode(ControlRoomSnapshot.self, from: Self.fixture())
        var one = try #require(snapshot.ungrouped?.first)
        // Needing nothing, it is with the quiet rows, after the groups.
        one.needs_me = false
        snapshot.ungrouped = [one]
        let quiet = ControlRoomList(snapshot: snapshot)
        let last = quiet.quiet.last?.id
        #expect(last == "terminal:0x00000000000000c1")
        let stillWaiting = quiet.waiting.contains { $0.alone != nil }
        #expect(!stillWaiting)

        // The one glyph that breathes is the first the core lists. When
        // that is this terminal, in no group, it is this row and no group's.
        one.needs_me = true
        snapshot.ungrouped = [one]
        snapshot.pulses = [ControlRoomSnapshot.Pulse(terminal: "0x00000000000000c1", window: nil, tab: nil, group: nil)]
        let breathing = ControlRoomList(snapshot: snapshot).rows.filter(\.pulses).map(\.id)
        #expect(breathing == ["terminal:0x00000000000000c1"])
        // Another terminal in no group breathing is not this one.
        snapshot.pulses = [ControlRoomSnapshot.Pulse(terminal: "0x00000000000000ff", window: nil, tab: nil, group: nil)]
        let other = ControlRoomList(snapshot: snapshot).rows.filter(\.pulses).map(\.id)
        #expect(other == [])
    }

    @Test func theBarOverTheRightSideSaysSupervisorOnlyOfASupervisor() {
        let title = ControlRoomList.SupervisorTitle(name: "zsh", shown: .needsYou, word: "等批准")
        var row = ControlRoomList.Row(
            id: "terminal:0x1", shown: .needsYou, word: "等批准", waiter: .init(is: .terminal, name: ""),
            what: .none, others: 0, pulses: false, supervisor: title,
            alone: .init(terminal: "0x1", title: "zsh", pane: .plain))
        // An ordinary agent on its own: its name, and no title to hang the
        // word "Supervisor" on.
        let plain = ControlRoomList.detailBar(row: row, selection: row.id, holdsTerminal: true, title: title)
        #expect(plain.title == nil)
        #expect(plain.caption == "zsh")
        row.alone?.pane = .worker
        let worker = ControlRoomList.detailBar(row: row, selection: row.id, holdsTerminal: true, title: title)
        #expect(worker.title == nil)
        // A supervisor that has made no group is one.
        row.alone?.pane = .supervisor
        let supervisor = ControlRoomList.detailBar(row: row, selection: row.id, holdsTerminal: true, title: title)
        #expect(supervisor.title == title)
        #expect(supervisor.caption == nil)
        // A group's row is as it was: the title with a terminal, the
        // group's name with a sentence.
        row.alone = nil
        row.id = "web-app"
        let group = ControlRoomList.detailBar(row: row, selection: "web-app", holdsTerminal: true, title: title)
        #expect(group.title == title)
        let sentence = ControlRoomList.detailBar(row: row, selection: "web-app", holdsTerminal: false, title: nil)
        #expect(sentence.title == nil)
        #expect(sentence.caption == "web-app")
        // A lone row with a sentence is named by its title, never its id.
        row.alone = .init(terminal: "0x1", title: "zsh", pane: .plain)
        row.id = "terminal:0x1"
        let closed = ControlRoomList.detailBar(row: row, selection: row.id, holdsTerminal: false, title: nil)
        #expect(closed.caption == "zsh")
    }

    @Test func lookingAtALoneTerminalsRowIsToldLikeAGroups() {
        // This used to assert the opposite -- nothing was asked of the core
        // for a row in no group, because `seen` could only name a group. It
        // can name a terminal now (task 1469), so the row is looked at by
        // the same rule; what is then sent is `ControlRoomActions.seen`.
        var waits = 0
        var marked: [String] = []
        let tracker = ControlRoomSeenTracker(
            dwell: 0, later: { _, work in waits += 1; work() }, isInFront: { true }, markSeen: { marked.append($0) })
        var row = ControlRoomList.Row(
            id: "terminal:0x1", shown: .doneUnseen, word: "", waiter: .none, what: .none, others: 0, pulses: false,
            unseen: true, alone: .init(terminal: "0x1", title: "zsh", pane: .plain))
        // Selected while not looked at: told once.
        tracker.selectionChanged(to: row)
        #expect(marked == ["terminal:0x1"])
        // Looked at, then it stops again while still selected: told again.
        row.unseen = false
        tracker.listChanged(to: row)
        row.unseen = true
        tracker.listChanged(to: row)
        #expect(waits == 2)
        #expect(marked == ["terminal:0x1", "terminal:0x1"])
        // And what it is told as is the terminal, not a group by that id.
        #expect(ControlRoomActions.seen(rowId: row.id, in: [row]) == .seenTerminal("0x1"))
    }

    // MARK: The first line of a waiting row

    @Test func theGroupsNameIsNeverWhatGivesWayToWhoIsWaiting() {
        // 322 across, 8 between things: a short name, a status word, and a
        // worker whose title is far longer than the line.
        let fit = ControlRoomLine1.fit(width: 322, gap: 8, name: 80, who: 400, word: 40)
        // The name is whole.
        #expect(fit.name == 80)
        // Who is waiting has what is left -- 322 less the word, the name
        // and the two gaps -- and is cut to it.
        let who = fit.who
        #expect(who == 186.0)
        // With room for everything nothing is cut.
        let roomy = ControlRoomLine1.fit(width: 322, gap: 8, name: 80, who: 100, word: 40)
        #expect(roomy == .init(name: 80, who: 100))
    }

    @Test func aNameTooLongIsCutOnlyByTheStatusWordAndThenNobodyIsNamed() {
        let fit = ControlRoomLine1.fit(width: 322, gap: 8, name: 500, who: 90, word: 40)
        // Up to the status word and its gap, and no further.
        #expect(fit.name == 322 - 40 - 8)
        // There is no room left to name who waits: not drawn, rather than
        // drawn at no width.
        #expect(fit.who == nil)
        // A name that just fits leaves nothing either.
        let exact = ControlRoomLine1.fit(width: 322, gap: 8, name: 274, who: 90, word: 40)
        #expect(exact == .init(name: 274, who: nil))
        // One that leaves a little leaves that little.
        let little = ControlRoomLine1.fit(width: 322, gap: 8, name: 250, who: 90, word: 40)
        #expect(little == .init(name: 250, who: 16))
    }

    @Test func aRowWithNobodyToNameOrNoStatusWordGivesTheNameTheRoom() {
        let nobody = ControlRoomLine1.fit(width: 322, gap: 8, name: 300, who: nil, word: 40)
        #expect(nobody == .init(name: 274, who: nil))
        // No status word takes no room and no gap.
        let wordless = ControlRoomLine1.fit(width: 322, gap: 8, name: 400, who: nil, word: 0)
        #expect(wordless == .init(name: 322, who: nil))
        // Nothing is ever a negative width.
        let tiny = ControlRoomLine1.fit(width: 30, gap: 8, name: 80, who: 50, word: 40)
        #expect(tiny == .init(name: 0, who: nil))
    }

    // MARK: A note under the header

    @Test func whatIsSaidUnderTheHeaderMovesTheRowsDownAndCoversNone() throws {
        let plain = ControlRoomListLayout(list: list, height: 824)
        let noted = ControlRoomListLayout(list: list, height: 824, noteUnderHeader: 36)
        // The header stays; every row, the separator and the second header
        // are lower by the note's height, so the note has that room to
        // itself.
        #expect(noted.header == plain.header)
        for row in list.rows {
            let was = try #require(plain.rows[row.id])
            let now = try #require(noted.rows[row.id])
            #expect(now == was.offsetBy(dx: 0, dy: 36))
        }
        #expect(noted.separator == plain.separator.offsetBy(dx: 0, dy: 36))
        #expect(noted.quietHeader == plain.quietHeader.offsetBy(dx: 0, dy: 36))
        let first = try #require(noted.rows[list.waiting[0].id])
        #expect(first.minY >= noted.header.maxY + 36)
        // With nothing said nothing moves.
        let none = ControlRoomListLayout(list: list, height: 824, noteUnderHeader: 0)
        #expect(none == plain)
    }

    @Test func theCoresFixtureSaysWhoWaitsAndForWhat() throws {
        let made = try ControlRoomList.decode(snapshot: Self.fixture())
        let web = try #require(made.rows.first { $0.id == "web-app" })
        #expect(web.waiter.is == .supervisor)
        #expect(web.what.form == .command)
        #expect(web.what.lines == [
            "rm -rf dist/ .cache/ node_modules/.vite", "&& npm ci", "&& npm run build -- --mode production",
        ])
        let mobile = try #require(made.rows.first { $0.id == "mobile" })
        #expect(mobile.waiter == ControlRoomList.Waiter(is: .workerViaSupervisor, name: "ios-build"))
        let billing = try #require(made.rows.first { $0.id == "billing" })
        #expect(billing.what.form == .words)
        #expect(billing.what.isCode == false)
        // Nobody waits on a row that needs nothing; it may still say what
        // the group is doing.
        let design = try #require(made.rows.first { $0.id == "design-system" })
        #expect(design.waiter == .none)
        #expect(design.what.lines == ["改按钮的三种尺寸"])
        let notes = try #require(made.rows.first { $0.id == "notes" })
        #expect(notes.what == .none)
    }

    @Test func nothingInTheCoresFixtureSaysHowLong() throws {
        // The minutes and the band of today's waiting were taken out (the
        // user's ruling, 2026-10-13).
        let text = String(bytes: try Self.fixture(), encoding: .utf8) ?? ""
        #expect(!text.isEmpty)
        for gone in ["waited_min", "\"band\"", "total_min", "\"lanes\"", "\"spans\""] {
            #expect(!text.contains(gone), "the fixture says \(gone) again")
        }
    }

    @Test func theRowThatBreathesIsTheFirstInTheCoresListNotAlreadyInFront() throws {
        // The fixture's list: billing's terminal (tab …22), then web-app's
        // (tab …21, row web-app-docs), then two with no row.
        let nothingInFront = try ControlRoomList.decode(snapshot: Self.fixture())
        let breathing = nothingInFront.rows.filter(\.pulses).map(\.id)
        #expect(breathing == ["billing"])

        // With billing's own tab in front it is not billing: the person is
        // already looking at that one. The next in the list is.
        let billingInFront = try ControlRoomList.decode(
            snapshot: Self.fixture(), showing: "0x0000000000000022")
        let next = billingInFront.rows.filter(\.pulses).map(\.id)
        #expect(next == ["web-app-docs"])
    }

    @Test func aRowCarriesBackTheMomentsItWasDrawnFrom() throws {
        let made = try ControlRoomList.decode(snapshot: Self.fixture())
        let target = made.waiting[0].target
        #expect(target?.terminal == "0x00000000000000a1")
        #expect(target?.sinceMs == 5_760_000)
        #expect(target?.eventMs != nil)
    }

    // MARK: Where the selection goes

    @Test func arrowKeysWalkTheListedOrderAcrossBothSections() {
        let rows = list.rows
        let order = rows.map(\.id)
        #expect(order == ["billing", "web-app", "mobile", "docs-site", "infra", "design-system", "search", "notes"])
        let down = ControlRoomList.move("docs-site", by: 1, in: rows)
        #expect(down == "infra")
        let up = ControlRoomList.move("infra", by: -1, in: rows)
        #expect(up == "docs-site")
    }

    @Test func theSelectionStopsAtTheEnds() {
        let rows = list.rows
        let top = ControlRoomList.move("billing", by: -1, in: rows)
        #expect(top == "billing")
        let bottom = ControlRoomList.move("notes", by: 1, in: rows)
        #expect(bottom == "notes")
    }

    @Test func withNothingSelectedAStepLandsOnTheNearEnd() {
        let rows = list.rows
        let down = ControlRoomList.move(nil, by: 1, in: rows)
        #expect(down == "billing")
        let up = ControlRoomList.move(nil, by: -1, in: rows)
        #expect(up == "notes")
        let gone = ControlRoomList.move("no-such-group", by: 1, in: rows)
        #expect(gone == "billing")
        let empty = ControlRoomList.move("web-app", by: 1, in: [])
        #expect(empty == nil)
    }

    // MARK: Where things are

    /// The design's panel (v18, direction A) is 380 wide and 824 high. A
    /// waiting row is 40 and 20 a line of what it waits on; by the nominal
    /// count the sample's four are three lines, three, two and one.
    @Test func theWaitingRowsAreAsHighAsWhatTheyWaitOn() {
        let layout = ControlRoomListLayout(list: list, height: 824)
        #expect(layout.size == CGSize(width: 380, height: 824))
        #expect(layout.header == CGRect(x: 6, y: 6, width: 368, height: 32))
        #expect(layout.rows["billing"] == CGRect(x: 6, y: 38, width: 368, height: 100))
        #expect(layout.rows["web-app"] == CGRect(x: 6, y: 146, width: 368, height: 100))
        #expect(layout.rows["mobile"] == CGRect(x: 6, y: 254, width: 368, height: 80))
        #expect(layout.rows["docs-site"] == CGRect(x: 6, y: 342, width: 368, height: 60))
        #expect(ControlRoomListLayout.askWidth == 322)
        #expect(layout.fits["web-app"] == ControlRoomAskFit(lines: [1, 1, 1], hidden: 0))
        #expect(layout.fits["billing"] == ControlRoomAskFit(lines: [3], hidden: 0))
        #expect(layout.fits["infra"] == nil)
    }

    @Test func theQuietSectionFollowsTheSeparator() {
        let layout = ControlRoomListLayout(list: list, height: 824)
        #expect(layout.separator == CGRect(x: 18, y: 418, width: 344, height: 0.5))
        #expect(layout.quietHeader == CGRect(x: 6, y: 422.5, width: 368, height: 32))
        #expect(layout.rows["infra"] == CGRect(x: 6, y: 454.5, width: 368, height: 28))
        #expect(layout.rows["design-system"] == CGRect(x: 6, y: 482.5, width: 368, height: 28))
    }

    @Test func whenTheCoreSaysNobodyWaitsTheGroupsFollowTheOneHeader() {
        var nobody = list
        nobody.quiet = list.rows
        nobody.waiting = []
        nobody.waitingCount = 0
        let layout = ControlRoomListLayout(list: nobody, height: 824)
        #expect(layout.quietHeader.height == 0)
        #expect(layout.separator.height == 0)
        #expect(layout.rows["billing"] == CGRect(x: 6, y: 38, width: 368, height: 28))
        // The core's count, not the rows: a list that says 2 with no rows
        // in it still has its second header.
        nobody.waitingCount = 2
        let said = ControlRoomListLayout(list: nobody, height: 824)
        #expect(said.quietHeader.height == 32)
        let none = ControlRoomList.headerText(waiting: 0)
        #expect(!none.contains("0"))
        let some = ControlRoomList.headerText(waiting: 4)
        #expect(some.contains("4"))
    }

    @Test func aRowIsAsHighAsTheHostMeasuredItAndTheMeasureIsToldTheFace() {
        var asked: [String: Bool] = [:]
        let layout = ControlRoomListLayout(list: list, height: 824) { text, code in
            asked[text] = code
            return 4
        }
        // A sentence gets the three lines there are; three steps one each.
        #expect(layout.fits["docs-site"] == ControlRoomAskFit(lines: [3], hidden: 0))
        #expect(layout.rows["docs-site"]?.height == 100)
        #expect(layout.fits["web-app"] == ControlRoomAskFit(lines: [1, 1, 1], hidden: 0))
        #expect(asked["&& npm ci"] == true)
        #expect(asked["调用次数用完了，13:40 恢复。"] == false)
    }

    @Test func anotherTerminalWaitingIsALineOfItsOwn() {
        var more = list
        more.waiting[3].others = 2
        let layout = ControlRoomListLayout(list: more, height: 824)
        #expect(layout.rows["docs-site"]?.height == 80)
    }

    // MARK: What is cut

    @Test func whatIsCutIsTheEndOfALineAndNeverAStep() {
        let maxLines = Int(Look.Side.askMaxLines)
        let maxSteps = Int(Look.Side.askMaxSteps)
        #expect(maxLines == 3 && maxSteps == 6)
        #expect(ControlRoomAskFit.fit(needed: []) == .none)
        // A sentence: as many lines as it wants, up to the ceiling.
        #expect(ControlRoomAskFit.fit(needed: [2]).lines == [2])
        #expect(ControlRoomAskFit.fit(needed: [9]).lines == [3])
        // Each step a line first; what is left to the earliest that needs it.
        #expect(ControlRoomAskFit.fit(needed: [3, 1]).lines == [2, 1])
        #expect(ControlRoomAskFit.fit(needed: [1, 3]).lines == [1, 2])
        #expect(ControlRoomAskFit.fit(needed: [2, 2]).lines == [2, 1])
        #expect(ControlRoomAskFit.fit(needed: [9, 9, 9]).lines == [1, 1, 1])
        // More steps than lines: the row grows by a line a step.
        #expect(ControlRoomAskFit.fit(needed: [2, 1, 1, 1]) == ControlRoomAskFit(lines: [1, 1, 1, 1], hidden: 0))
        #expect(ControlRoomAskFit.fit(needed: Array(repeating: 1, count: 7))
            == ControlRoomAskFit(lines: [1, 1, 1, 1, 1], hidden: 2))

        // **Every step has a line or is counted, however long and however
        // many.**
        for steps in 1...20 {
            for want in [1, 2, 9] {
                let fit = ControlRoomAskFit.fit(needed: Array(repeating: want, count: steps))
                let every = fit.lines.allSatisfy { $0 >= 1 }
                #expect(every, "\(steps) steps wanting \(want): \(fit)")
                let shown = fit.lines.endIndex
                #expect(shown + fit.hidden == steps, "\(steps) steps wanting \(want): a step is neither shown nor counted")
                if steps <= maxSteps {
                    #expect(fit.hidden == 0)
                } else {
                    #expect(fit.drawn == maxSteps)
                }
                if steps <= maxLines {
                    #expect(fit.drawn <= maxLines)
                }
            }
        }
        #expect(ControlRoomList.hiddenStepsText(0) == nil)
        let two = ControlRoomList.hiddenStepsText(2) ?? ""
        #expect(two.contains("2"))
    }

    @Test func withNoFontALineIsFortyOneCellsAndAWideCharacterIsTwo() {
        #expect(ControlRoomList.nominalLines("") == 1)
        #expect(ControlRoomList.nominalLines(String(repeating: "x", count: 41)) == 1)
        #expect(ControlRoomList.nominalLines(String(repeating: "x", count: 42)) == 2)
        #expect(ControlRoomList.nominalLines(String(repeating: "票", count: 20)) == 1)
        #expect(ControlRoomList.nominalLines(String(repeating: "票", count: 21)) == 2)
    }

    // MARK: Who waits, in words

    @Test func whoWaitsIsSaidFromTheCoresWordAndNothingElse() {
        typealias Waiter = ControlRoomList.Waiter
        #expect(ControlRoomList.waiterText(Waiter(is: .none, name: "x")) == nil)
        #expect(ControlRoomList.waiterText(Waiter(is: .terminal, name: "x")) == nil)
        let own = ControlRoomList.waiterText(Waiter(is: .supervisor, name: "")) ?? ""
        #expect(!own.isEmpty && !own.contains("ios-build"))
        let through = ControlRoomList.waiterText(Waiter(is: .workerViaSupervisor, name: "ios-build")) ?? ""
        #expect(through.contains("ios-build") && through != "ios-build")
        #expect(ControlRoomList.waiterText(Waiter(is: .worker, name: "lint")) == "lint")
    }

    @Test func aRowReadOutSaysWhichGroupWhoWaitsAndEveryStepWhole() {
        for row in list.rows {
            let said = ControlRoomList.spoken(row)
            #expect(said.hasPrefix(row.id))
            if let who = ControlRoomList.waiterText(row.waiter) {
                #expect(said.contains(who), "\(said) does not say who is waiting")
            }
            if !row.word.isEmpty { #expect(said.contains(row.word)) }
            for line in row.what.lines {
                #expect(said.contains(line), "\(said) leaves out \(line)")
            }
        }
        // Nine steps: the row draws five and a number; read out, all nine.
        let nine = (1...9).map { "&& ./step-\($0).sh" }
        var long = list.waiting[1]
        long.what = .init(cut: .none, form: .command, lines: nine)
        let said = ControlRoomList.spoken(long)
        let all = nine.allSatisfy { said.contains($0) }
        #expect(all)
    }

    @Test func aGroupThatNeedsNothingSaysWhatItIsDoingOrItsStatusOrNothing() {
        let doing = ControlRoomList.quietText(list.quiet[1])
        #expect(doing == "在改按钮的三种尺寸")
        var unknown = list.quiet[1]
        unknown.what = .none
        #expect(ControlRoomList.quietText(unknown) == "在干活")
        #expect(ControlRoomList.quietText(list.quiet[3]) == "")
    }

    @Test func theChipRestsExactlyOnItsRowAndNowhereForARowNotListed() {
        let layout = ControlRoomListLayout(list: list, height: 824)
        #expect(layout.chip(for: "billing") == layout.rows["billing"])
        #expect(layout.chip(for: "infra") == layout.rows["infra"])
        #expect(layout.chip(for: nil) == nil)
        #expect(layout.chip(for: "no-such-group") == nil)
    }

    // MARK: How the chip moves

    @Test func theChipStartsAtRestAndSettlesOnItsRow() {
        let start = ControlRoomChipSpring.progress(at: 0)
        #expect(start == 0)
        let settled = ControlRoomChipSpring.progress(at: 1.5)
        #expect(abs(settled - 1) < 0.001)
    }

    @Test func theChipOvershootsByAboutFourPercentAndComesBack() {
        // The design: "about 0.26 s to its furthest, about 4% past".
        let peak = stride(from: 0.0, through: 1.0, by: 0.001)
            .map { ($0, ControlRoomChipSpring.progress(at: $0)) }
            .max { $0.1 < $1.1 }!
        #expect(peak.1 > 1.03 && peak.1 < 1.05)
        #expect(peak.0 > 0.24 && peak.0 < 0.28)
        let said = ControlRoomChipSpring.overshoot()
        #expect(abs((peak.1 - 1) - said) < 0.001)
    }

    @Test func aCriticallyDampedChipNeverPassesItsRow() {
        // The other candidate for the tentative `spring_damping`.
        let highest = stride(from: 0.0, through: 2.0, by: 0.001)
            .map { ControlRoomChipSpring.progress(at: $0, damping: 1) }
            .max()!
        #expect(highest <= 1)
        // A fifth of a second in it is most of the way and is a number: the
        // under-damped formula divides by zero here.
        let partway = ControlRoomChipSpring.progress(at: 0.2, damping: 1)
        #expect(abs(partway - 0.863) < 0.001)
        let said = ControlRoomChipSpring.overshoot(damping: 1)
        #expect(said == 0)
    }

    // MARK: One slide, written out

    @Test func aChipSlidesOnlyWhenThereIsSomewhereToComeFromAndMotionIsAllowed() {
        let was = CGRect(x: 0, y: 0, width: 293, height: 24)
        let now = CGRect(x: 588, y: 0, width: 292, height: 24)
        let slides = ControlRoomChipSlide.plan(from: was, to: now, reduceMotion: false)
        #expect(slides == .slide(dx: -587.5, dy: 0))
        // Reduce Motion: it is simply there.
        let reduced = ControlRoomChipSlide.plan(from: was, to: now, reduceMotion: true)
        #expect(reduced == .jump)
        let fromNowhere = ControlRoomChipSlide.plan(from: nil, to: now, reduceMotion: false)
        #expect(fromNowhere == .jump)
        let toItself = ControlRoomChipSlide.plan(from: now, to: now, reduceMotion: false)
        #expect(toItself == .jump)
        // Down a list is a slide as much as along a bar.
        let down = ControlRoomChipSlide.plan(from: CGRect(x: 6, y: 38, width: 368, height: 100),
                                             to: CGRect(x: 6, y: 146, width: 368, height: 80), reduceMotion: false)
        #expect(down == .slide(dx: 0, dy: -98))
    }

    @Test func theSlideIsOverWhenItStaysWithinTheTablesFractionOfItsEnd() {
        let end = ControlRoomChipSlide.duration
        // The design: "still at about 0.45 s".
        #expect(end > 0.38 && end < 0.47)
        let after = stride(from: end, through: end + 2, by: 0.001)
            .map { abs(1 - ControlRoomChipSpring.progress(at: $0)) }
            .max()!
        #expect(after <= Look.Selection.settledWithin)
        let justBefore = abs(1 - ControlRoomChipSpring.progress(at: end - 0.002))
        #expect(justBefore > Look.Selection.settledWithin)
    }

    @Test func theChipIsUpForTheWayAndDownByTheTimeItIsStill() {
        let lands = ControlRoomChipSlide.landsAt
        // It starts down with three tenths of the way still to go.
        let gone = ControlRoomChipSpring.progress(at: lands)
        #expect(abs(gone - (1 - Look.Selection.liftLandsWithRemaining)) < 0.01)
        #expect(lands > Look.Selection.liftIn && lands < ControlRoomChipSlide.duration)

        let atStart = ControlRoomChipSlide.lift(at: 0)
        #expect(atStart == 0)
        let halfUp = ControlRoomChipSlide.lift(at: Look.Selection.liftIn / 2)
        #expect(abs(halfUp - 0.5) < 0.001)
        let up = ControlRoomChipSlide.lift(at: (Look.Selection.liftIn + lands) / 2)
        #expect(up == 1)
        let atEnd = ControlRoomChipSlide.lift(at: ControlRoomChipSlide.duration)
        #expect(atEnd == 0)
        // And it only comes down once it has started to.
        let falling = stride(from: lands, through: ControlRoomChipSlide.duration, by: 0.005)
            .map { ControlRoomChipSlide.lift(at: $0) }
        let neverRises = zip(falling, falling.dropFirst()).allSatisfy { $0 >= $1 }
        #expect(neverRises)
    }

    @Test func aSlideStartsWhereTheChipWasAndEndsExactlyAtRest() {
        let scale = Look.Selection.liftScaleWindowTab
        let samples = ControlRoomChipSlide.samples(dx: -587.5, dy: 0, liftScale: scale)
        let expected = Int((ControlRoomChipSlide.duration * Look.Selection.slideSamplesPerSecond).rounded(.up)) + 1
        #expect(samples.count == expected)
        #expect(samples.first == .init(dx: -587.5, dy: 0, along: 1, across: 1))
        // The last is rest itself, not nearly: when the animation is taken
        // off, nothing may jump.
        #expect(samples.last == .init(dx: 0, dy: 0, along: 1, across: 1))

        // It passes its place by about 4% of the way and comes back.
        let furthestPast = samples.map(\.dx).max()!
        #expect(furthestPast > 587.5 * 0.03 && furthestPast < 587.5 * 0.05)

        // In the air it is larger by the table's lift, longer along the way
        // by no more than the stretch, and never wider across than lifted.
        let longest = samples.map(\.along).max()!
        #expect(longest > 1 + scale)
        #expect(longest <= (1 + scale) * (1 + Look.Selection.stretchAlong))
        let widest = samples.map(\.across).max()!
        #expect(widest <= 1 + scale)
        let narrowest = samples.map(\.across).min()!
        #expect(narrowest >= 1 - Look.Selection.squeezeAcross)
    }

    @Test func theSpringsSpeedIsHowFastItsProgressChanges() {
        for t in [0.02, 0.1, 0.2, 0.3] {
            let h = 1e-6
            let measured = (ControlRoomChipSpring.progress(at: t + h) - ControlRoomChipSpring.progress(at: t - h)) / (2 * h)
            let said = ControlRoomChipSpring.speed(at: t)
            #expect(abs(measured - said) < 1e-4)
        }
    }

    // MARK: The glyphs' motion

    @Test func thePulseGoesFromFullToTheTablesMinimumAndBack() {
        let period = Look.Status.waitingPulsePeriod
        let full = ControlRoomGlyph.pulse(at: 0)
        #expect(full == 1)
        let low = ControlRoomGlyph.pulse(at: period / 2)
        #expect(abs(low - Look.Status.waitingPulseMinOpacity) < 1e-9)
        let again = ControlRoomGlyph.pulse(at: period)
        #expect(abs(again - 1) < 1e-9)
    }

    @Test func theSpinnerStepsThroughEveryLineOncePerTurn() {
        let period = Look.Status.workingSpinPeriod
        let steps = Int(Look.Status.workingSpinSteps)
        let seen = (0..<steps).map { ControlRoomGlyph.spinStep(at: (Double($0) + 0.5) * period / Double(steps)) }
        #expect(seen == Array(0..<steps))
        let held = ControlRoomGlyph.spinStep(at: 0.01)
        #expect(held == 0)
    }
}
