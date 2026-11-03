import Foundation
import Testing

@testable import Ghostty

/// The working directories of a group, and which one a file belongs to
/// (`ControlRoomWorkdirs`).
///
/// The page's own answer is the core's (`Workdirs.writeJson`, held to
/// `testdata/control_snapshot.json` and its own tests); what is tested here
/// is the host's half -- the request it builds and the reading of the
/// answer, including the one thing that is easy to get wrong in a way
/// nothing would notice: **which directory a file is judged to be in**.
struct ControlRoomWorkdirsTests {
    typealias Workdirs = ControlRoomWorkdirs

    private func page(_ dirs: String, group: String = "polter") -> String {
        """
        {"page":"workdirs","group":"\(group)","dirs":[\(dirs)]}
        """
    }

    private func dir(_ id: String, _ path: String, readable: Bool = true) -> String {
        """
        {"id":"\(id)","path":"\(path)","short":"\(path)","kind":"terminal",\
        "tree_name":null,"who":[],"also_in":[],"readable":\(readable),\
        "why":null,"editing":0}
        """
    }

    // MARK: The request

    @Test func theRequestAsksForTheWorkdirsPageOfOneGroup() {
        #expect(Workdirs.request(group: "polter")
            == #"{"page":"workdirs","group":"polter"}"#)
    }

    @Test func aGroupNameIsQuotedRatherThanPasted() {
        let request = Workdirs.request(group: "a\"b")
        #expect(request.contains(#""group":"a\"b""#))
        #expect((try? JSONSerialization.jsonObject(with: Data(request.utf8))) != nil)
    }

    // MARK: Reading the page

    /// Every key this reader takes, off the page the core really sends.
    ///
    /// ⚠️ **And the page sends more than this.** `kind` and `tree_name` are
    /// in the JSON below on purpose: they are the keys the host
    /// deliberately does **not** decode. A host draws the control room and
    /// does not decide what it says, and the gate holding that rule
    /// (`tools/control-room-hosts-do-not-decide.py`) refuses a host that
    /// reads `kind` at all -- there is nothing a kind is for except
    /// comparing it. So this test's job is two-fold: the keys it does take
    /// are read right, and the ones it does not take do not stop the page
    /// from being read (they were in the fixture the whole time).
    @Test func everyKeyThePageSendsIsRead() throws {
        let text = page("""
        {"id":"0123456789abcdef","path":"/Users/x/w","short":"~/w","kind":"tree",
         "tree_name":"wt-2634","who":[{"id":"0x1","title":"开发","role":"worker"}],
         "also_in":["other"],"readable":true,"why":null,"editing":3}
        """)
        let answer = try Workdirs.read(text).get()
        #expect(answer.page == "workdirs")
        #expect(answer.group == "polter")
        let d = try #require(answer.dirs.first)
        #expect(d.id == "0123456789abcdef")
        #expect(d.path == "/Users/x/w")
        #expect(d.short == "~/w")
        #expect(d.who == [Workdirs.Dir.Who(id: "0x1", title: "开发", role: "worker")])
        #expect(d.also_in == ["other"])
        #expect(d.readable)
        #expect(d.why == nil)
        #expect(d.editing == 3)
    }

    /// A row nothing may be read from keeps its reason: the page draws it
    /// and says why, and a reader that dropped it would draw a row that
    /// looks readable and is not.
    @Test func aRowNothingMayBeReadFromKeepsItsReason() throws {
        let text = page(#"{"id":"abcd","path":"/","short":"/","kind":"terminal","tree_name":null,"who":[],"also_in":[],"readable":false,"why":"too_wide","editing":0}"#)
        let answer = try Workdirs.read(text).get()
        #expect(answer.dirs.first?.readable == false)
        #expect(answer.dirs.first?.why == "too_wide")
    }

    @Test func anAnswerThatIsNotThePageIsRefused() {
        for text in ["", "not json", "[]", #"{"page":"tasks"}"#, #"{"page":"workdirs","group":"g"}"#] {
            #expect(Workdirs.read(text) == .failure(.notJSON), "at \(text)")
        }
    }

    /// ⚠️ **The core saying no is not the answer being unreadable.** The
    /// core answers every page in one wire shape, refusals included:
    /// `renderWorkdirs`'s first line is
    /// `{"error":"NoSuchGroup"}` for a group it does not have. Reading that
    /// as `notJSON` would say a well-formed JSON document could not be
    /// parsed, and would drop the core's own word for what was wrong --
    /// which is the only thing that tells a person looking at a blank pane
    /// whether the group is gone or the page is broken.
    ///
    /// The three sibling pages have had this branch since they were
    /// written; this one was the fourth and was missing it. The test seat
    /// built a one-file probe against this exact file and ran the core's
    /// real refusal through it (`evid`, task 2634).
    @Test func theCoresOwnRefusalIsNotAParseFailure() {
        #expect(Workdirs.read(#"{"error":"NoSuchGroup"}"#) == .failure(.refused("NoSuchGroup")))
        #expect(Workdirs.read(#"{"error":"BadRequest"}"#) == .failure(.refused("BadRequest")))
        // And the answer to "is this JSON" is yes: `{"error":…}` is a
        // document, which is the whole point of keeping it apart from
        // `notJSON`.
        #expect((try? JSONSerialization.jsonObject(
            with: Data(#"{"error":"NoSuchGroup"}"#.utf8))) != nil)
    }

    /// The two failures say two different things, and a caller can act on
    /// the difference: `refused` never left the host and has the core's
    /// word for why, `notJSON` means the answer was not an answer.
    @Test func theTwoFailuresAreNotTheSameValue() {
        #expect(Workdirs.Failure.refused("NoSuchGroup") != Workdirs.Failure.notJSON)
    }

    @Test func aGroupWithNoDirectoriesIsAnEmptyListAndNotAFailure() throws {
        let answer = try Workdirs.read(page("")).get()
        #expect(answer.dirs.isEmpty)
    }

    // MARK: Which directory a file is in

    /// **The near one, not the first one.** A worktree standing inside the
    /// person's own directory is two rows, and a file in the worktree
    /// belongs to the worktree: the other answer is a ticket for a
    /// directory that merely contains the one the file is in.
    @Test func aFileBelongsToTheNearestDirectoryThatContainsIt() throws {
        let answer = try Workdirs.read(page([
            dir("aaaaaaaaaaaaaaaa", "/Users/x"),
            dir("bbbbbbbbbbbbbbbb", "/Users/x/proj"),
            dir("cccccccccccccccc", "/Users/x/proj/wt-2634"),
        ].joined(separator: ","))).get()

        #expect(Workdirs.directory(holding: "/Users/x/proj/wt-2634/src/a.zig", in: answer)?.id
                == "cccccccccccccccc")
        #expect(Workdirs.directory(holding: "/Users/x/proj/README.md", in: answer)?.id
                == "bbbbbbbbbbbbbbbb")
        #expect(Workdirs.directory(holding: "/Users/x/.zshrc", in: answer)?.id
                == "aaaaaaaaaaaaaaaa")
        // Nothing above every row.
        #expect(Workdirs.directory(holding: "/etc/hosts", in: answer) == nil)
    }

    /// **On components, not on characters.** `/a/bc` is not inside `/a/b`,
    /// and a plain `hasPrefix` says it is -- which would mint a ticket out
    /// of a directory the file is not in, and the core would refuse it in
    /// words that read like a bug in the core.
    @Test func aSiblingWithAPrefixNamesakeIsNotInside() throws {
        let answer = try Workdirs.read(page([
            dir("aaaaaaaaaaaaaaaa", "/Users/x/proj"),
        ].joined(separator: ","))).get()
        #expect(Workdirs.directory(holding: "/Users/x/proj/a.md", in: answer) != nil)
        #expect(Workdirs.directory(holding: "/Users/x/proj-backup/a.md", in: answer) == nil)
        #expect(Workdirs.directory(holding: "/Users/x/projection/a.md", in: answer) == nil)
        // The row itself, exactly.
        #expect(Workdirs.directory(holding: "/Users/x/proj", in: answer) != nil)
    }

    /// The root is the one directory whose own path already ends in the
    /// separator: `/` contains `/etc`, and a test that added a second slash
    /// would answer no.
    @Test func theRootContainsWhatIsUnderIt() {
        #expect(Workdirs.contains("/", "/etc/hosts"))
        #expect(Workdirs.contains("/", "/"))
        #expect(!Workdirs.contains("/etc", "/"))
    }

    /// **A row nothing may be read from is passed over**, not returned: the
    /// core refuses a ticket for one (`too_wide`), and a caller that asked
    /// anyway would be asking for a refusal it could have predicted. With
    /// only an unreadable row holding the file, there is no directory to
    /// mint from -- and that is the answer, not the unreadable row.
    @Test func anUnreadableRowIsNotADirectoryToMintFrom() throws {
        let answer = try Workdirs.read(page([
            dir("aaaaaaaaaaaaaaaa", "/Users/x", readable: false),
            dir("bbbbbbbbbbbbbbbb", "/Users/x/proj", readable: true),
        ].joined(separator: ","))).get()
        #expect(Workdirs.directory(holding: "/Users/x/proj/a.md", in: answer)?.id
                == "bbbbbbbbbbbbbbbb")
        // Under the unreadable row only: nothing.
        #expect(Workdirs.directory(holding: "/Users/x/other/a.md", in: answer) == nil)
    }

    @Test func noDirectoriesAtAllIsNoDirectory() throws {
        let answer = try Workdirs.read(page("")).get()
        #expect(Workdirs.directory(holding: "/Users/x/a.md", in: answer) == nil)
    }

    /// **Nil is where the asking stops.** No row holds the file means there
    /// is no working directory to mint from, and a host that sent
    /// `files_open` anyway would be sending a path with nothing behind it:
    /// the core's refusal would name the core's rules instead of the simple
    /// fact that this file is not in a directory this group has.
    @Test func aFileNoRowHoldsIsRefusedWithoutMinting() throws {
        let answer = try Workdirs.read(page([
            dir("aaaaaaaaaaaaaaaa", "/Users/x/proj"),
        ].joined(separator: ","))).get()
        #expect(Workdirs.mint(holding: "/Users/x/proj/a.md", in: answer)
                == .success(Workdirs.Mint(workdirId: "aaaaaaaaaaaaaaaa", path: "/Users/x/proj/a.md")))
        #expect(Workdirs.mint(holding: "/etc/hosts", in: answer)
                == .failure(.refused(Workdirs.noDirectory)))
    }

    /// And the same when the only row that holds it is one nothing may be
    /// read from: the refusal names that, rather than minting against
    /// `readable: false` and letting the core say `too_wide`.
    @Test func aFileOnlyAnUnreadableRowHoldsIsRefused() throws {
        let answer = try Workdirs.read(page([
            dir("aaaaaaaaaaaaaaaa", "/Users/x", readable: false),
        ].joined(separator: ","))).get()
        #expect(Workdirs.mint(holding: "/Users/x/a.md", in: answer)
                == .failure(.refused(Workdirs.noDirectory)))
    }
}

// MARK: - Which roots are open

/// The working-directories page's tree, which roots of it are open, and the
/// three ways the design opens and shuts them (task 2643, #2140 M4/W4;
/// `2140/v3/src/12-trees-overflow-mac-dark.html`).
///
/// **Tested here rather than through the page** because the page is a
/// `sources.out` file: it draws from a model and is not in the package that
/// runs with no app (`tools/mac-logic-tests.json`). The rules below are the
/// whole of what the page does with a click, so holding them here is holding
/// the page's behaviour -- and what is left in the view is the drawing.
struct ControlRoomWorkdirsTreeTests {
    typealias Tree = ControlRoomWorkdirs.Tree

    private let ids = ["a", "b", "c"]

    /// **A root nobody has touched is open**, which is the design's default
    /// (根默认展开到第一层, `2145/PLAN.md` §2.5).
    ///
    /// ⚠️ This is the assertion the storage choice is for. The state is the
    /// set of *shut* ids, so an untouched root is open because it is absent
    /// -- and a set of *open* ids would answer the opposite here while every
    /// other test below still passed. It is also the bit that keeps "nobody
    /// has decided" apart from "somebody opened it": those two are the same
    /// picture today and would stop being the same the day the default
    /// moves.
    @Test func aRootNobodyHasTouchedIsOpen() {
        let tree = Tree()
        #expect(tree.isOpen("a"))
        #expect(tree.isOpen("b"))
        #expect(tree.isOpen("c"))
    }

    /// A plain click turns one root over and **leaves the others where they
    /// were**: the design draws several roots open at once.
    @Test func aPlainClickTurnsOneRootOverAndLeavesTheOthers() {
        var tree = Tree()
        tree.toggle("b")
        #expect(tree.isOpen("a"))
        #expect(!tree.isOpen("b"))
        #expect(tree.isOpen("c"))

        tree.toggle("b")
        #expect(tree.isOpen("b"))
        #expect(tree.isOpen("a"))
        #expect(tree.isOpen("c"))
    }

    /// ⌥-click: this one opens and every other one shuts. It is the only
    /// gesture that shuts a root the person did not point at, which is what
    /// makes it worth a test of its own.
    @Test func optionClickLeavesExactlyTheOnePointedAtOpen() {
        var tree = Tree()
        tree.solo("b", among: ids)
        #expect(!tree.isOpen("a"))
        #expect(tree.isOpen("b"))
        #expect(!tree.isOpen("c"))

        // And the other way round: the one that was open shuts, the one
        // pointed at opens.
        tree.solo("c", among: ids)
        #expect(!tree.isOpen("a"))
        #expect(!tree.isOpen("b"))
        #expect(tree.isOpen("c"))
    }

    /// ⌥-click on the one root that is already alone leaves it **open**.
    ///
    /// ⚠️ A click that shut the root it was pointed at would be `toggle`
    /// wearing another key, and the design's gesture is "only this one".
    @Test func optionClickOnTheOnlyOpenRootLeavesItOpen() {
        var tree = Tree()
        tree.solo("b", among: ids)
        tree.solo("b", among: ids)
        #expect(tree.isOpen("b"))
        #expect(!tree.isOpen("a"))
        #expect(!tree.isOpen("c"))
    }

    @Test func collapseAllShutsEveryRoot() {
        var tree = Tree()
        tree.collapseAll(ids)
        #expect(!tree.isOpen("a"))
        #expect(!tree.isOpen("b"))
        #expect(!tree.isOpen("c"))
    }

    /// A root that has gone stops being remembered, so the **same id coming
    /// back comes back open** rather than wearing the decision somebody made
    /// about it before it left.
    ///
    /// A group's workdirs come and go as terminals enter and leave
    /// directories (`Workdirs.compute` is worked out afresh on every ask),
    /// so an id that returns is a directory the group has again -- and a
    /// page that opened it shut would be answering from a decision about a
    /// directory that was, for a while, not there.
    @Test func aRootThatGoesAndComesBackIsOpenAgain() {
        var tree = Tree()
        tree.toggle("b")
        tree.toggle("c")
        #expect(!tree.isOpen("b"))

        // `b` leaves; only `a` and `c` are still the group's.
        tree.keep(only: ["a", "c"])
        #expect(!tree.isOpen("c"), "a root that is still here keeps its state")

        // ... and later `b` is a directory of the group again.
        tree.keep(only: ["a", "b", "c"])
        #expect(tree.isOpen("b"))
    }

    /// Nothing else in the struct answers a question about what is open
    /// beyond `isOpen`: the set is the storage, and a caller that read
    /// `shut` to decide something would be the second answer the storage
    /// choice exists to prevent. (The property is `private(set)`, so this
    /// test is about the *reading* side being the one method.)
    @Test func theOnlyQuestionIsWhetherARootIsOpen() {
        var tree = Tree()
        #expect(tree.isOpen("a"))
        tree.collapseAll(ids)
        #expect(!tree.isOpen("a"))
    }

    // MARK: The selected row

    /// A click puts the selection on that row, and **the row before it is
    /// not selected any more**. One assertion each way, because one slot can
    /// be wrong in both: a selection that never moves (the second `#expect`
    /// fails) and a selection that moves to two rows at once (the first
    /// fails).
    @Test func theSelectionMovesToTheRowClickedAndOffTheOneBeforeIt() {
        var tree = Tree()
        #expect(!tree.isSelected("a"))
        #expect(!tree.isSelected("b"))

        tree.select("a")
        #expect(tree.isSelected("a"))
        #expect(!tree.isSelected("b"))

        tree.select("b")
        #expect(!tree.isSelected("a"), "the row the click left must not still be selected")
        #expect(tree.isSelected("b"))
    }

    /// A click on nothing moves the selection off every row: nil and a row
    /// are two different states, and a `Bool` per row could not say the
    /// first one at all.
    @Test func aClickOnNothingSelectsNoRow() {
        var tree = Tree()
        tree.select("a")
        tree.select(nil)
        #expect(!tree.isSelected("a"))
        #expect(!tree.isSelected("b"))
    }

    /// **A root that leaves the group's list does not take the selection
    /// with it.** What is selected is a file, and a file does not stop being
    /// the open one because the directory holding it left `workdirs` for a
    /// moment (`Workdirs.compute` is worked out afresh on every ask).
    @Test func aSelectionSurvivesARootGoingAwayAndComingBack() {
        var tree = Tree()
        tree.toggle("b")
        tree.select("f1")
        #expect(!tree.isOpen("b"))

        // `b` is not one of the group's directories for a while. `keep` drops
        // the decision made about it -- which is the whole point of the
        // method -- so `b` reads as open again rather than as shut.
        tree.keep(only: ["a", "c"])
        #expect(tree.isOpen("b"), "a root that is gone is not a shut root")
        #expect(tree.isSelected("f1"), "and what is open in the pane beside it did not move")
    }
}

// MARK: - The activity bar at the left of the page

/// The left-hand column of the working-directories page (task 2670 S3; the
/// v3 design's `files4.css`, `.actbar`).
///
/// **Two icons, a button, and one fold**, and every one of them is a rule
/// the page would otherwise carry in a `sources.out` file no test can reach.
struct ControlRoomWorkdirsActivityTests {
    typealias Activity = ControlRoomWorkdirs.Activity

    /// The page opens on the explorer with the column drawn and 「最近改过」
    /// unfolded: the design's first picture, and a column that started shut
    /// would be a page with nothing on it.
    @Test func thePageOpensOnTheExplorerWithTheColumnDrawn() {
        let a = Activity()
        #expect(a.icon == .explorer)
        #expect(a.open)
        #expect(!a.recentFolded)
    }

    /// **The one already in front shuts the column when it is pressed**
    /// (the supervisor's scope: 再点一次当前图标就收起), and stays in front:
    /// the same press brings it back rather than moving to the other icon.
    @Test func pressingTheIconAlreadyInFrontShutsTheColumnAndLeavesItInFront() {
        var a = Activity()
        a.press(.explorer)
        #expect(!a.open)
        #expect(a.icon == .explorer, "the press must not walk to the other icon on its way shut")

        a.press(.explorer)
        #expect(a.open)
        #expect(a.icon == .explorer)
    }

    /// The other icon comes in front, and **the column opens if it was
    /// shut**: on a shut column a press that only changed the icon would be
    /// a click with nothing to see.
    @Test func anotherIconComesInFrontAndOpensAShutColumn() {
        var a = Activity()
        a.press(.search)
        #expect(a.icon == .search)
        #expect(a.open)

        a.press(.search)
        #expect(!a.open)
        a.press(.explorer)
        #expect(a.icon == .explorer)
        #expect(a.open, "a press that changes the icon must not leave the column shut")
    }

    /// The button at the foot of the bar folds the column and **does not
    /// touch which icon is in front**: it is the same fold from the other
    /// end, not a third state.
    @Test func theFootButtonFoldsTheColumnAndChangesNoIcon() {
        var a = Activity()
        a.press(.search)
        a.toggle()
        #expect(!a.open)
        #expect(a.icon == .search)
        a.toggle()
        #expect(a.open)
        #expect(a.icon == .search)
    }

    /// 「最近改过」's chevron is one bit: it folds and unfolds, and nothing
    /// else about the page moves with it.
    @Test func theRecentChevronFoldsAndUnfoldsThatSectionOnly() {
        var a = Activity()
        a.press(.explorer) // shut the column, so the state beside it is not the default
        let icon = a.icon
        let open = a.open
        a.toggleRecent()
        #expect(a.recentFolded)
        #expect(a.icon == icon)
        #expect(a.open == open)
        a.toggleRecent()
        #expect(!a.recentFolded)
    }

    /// There are **two** icons and they are the explorer and the search: the
    /// supervisor's scope for this task is 活动栏只放 2 个图标, and a third
    /// added later is a third thing the page has to answer a press about.
    @Test func thereAreExactlyTwoIcons() {
        #expect(Activity.Icon.allCases == [.explorer, .search])
    }

    /// **Every mark the bar and the tree draw is readable, and the two
    /// chevrons are two different drawings.**
    ///
    /// The floor here is the parse: a string with a command this does not
    /// know draws **nothing**, so an icon whose string was mistyped would be
    /// an empty box rather than a slightly-wrong icon -- and an empty box
    /// reads like a design with no icon at all. Each mark's count is the
    /// number of `<path>` (or `<circle>`) elements the design draws for it
    /// (`build2665.py`'s `IC_EXPLORER` / `IC_SEARCH` / `IC_COLLAPSE`, and
    /// `TW_SHUT` / `TW_OPEN`).
    @Test func everyMarkIsReadableAndTheTwoChevronsDiffer() {
        typealias Mark = ControlRoomWorkdirs.Mark
        #expect(ControlRoomWorkdirs.unreadableMarks.isEmpty,
                "a mark the parser could not read: \(ControlRoomWorkdirs.unreadableMarks)")
        #expect(Mark.explorer.art.count == 3)
        #expect(Mark.search.art.count == 2, "the ring and the handle")
        #expect(Mark.collapseSidebar.art.count == 2, "the box and the divider")
        #expect(Mark.chevronShut.art.count == 1)
        #expect(Mark.chevronOpen.art.count == 1)
        // The sidebar's refresh button is one path in the design
        // (`build2665.py`'s `IC_REFRESH`, task 2699), and it is the mark the
        // page had no way to press before this task: every level in `Levels`
        // was kept for as long as the page stayed on the group.
        #expect(Mark.refresh.art.count == 1, "the arc and the arrow are one path")
        #expect(Mark.chevronShut.segments != Mark.chevronOpen.segments, "shut and open are two drawings")
        // The two artboards are the design's: the bar's three are 20-unit,
        // the chevrons and the sidebar's refresh button 14.
        #expect(Mark.explorer.artboard == 20)
        #expect(Mark.chevronOpen.artboard == 14)
        #expect(Mark.refresh.artboard == 14, "`.sb-btn svg` is 14 beside the tree's own 14")
    }

    /// **The search mark's ring is a circle**, which is the one thing in
    /// these five that is not already a path: the design draws it as an SVG
    /// `<circle>`, and it is copied as two half-turn arcs. A circle read as
    /// nothing, or as one arc that stops half way, would be a magnifier with
    /// a bite out of it.
    @Test func theSearchMarksRingIsAWholeCircle() {
        typealias Mark = ControlRoomWorkdirs.Mark
        let ring = ControlRoomWorkdirs.Segment.parse(Mark.search.art[0])
        #expect(!ring.isEmpty, "the ring did not read at all")
        guard case .move(let start) = ring[0] else {
            Issue.record("the ring does not begin with a move")
            return
        }
        #expect(abs(start.x - 13.5) < 1e-9 && abs(start.y - 8.5) < 1e-9, "began at \(start)")
        // It comes back round to where it opened: the last curve's end is
        // the move's own point, one whole turn later. (The trailing `z` is a
        // `.close` and is stepped over -- it is the design saying the ring is
        // shut, not a second end point.)
        let curves = ring.compactMap { if case .cubic(let c1, let c2, let p) = $0 { return (c1, c2, p) } else { return nil } }
        #expect(curves.count >= 2, "a circle is at least two pieces: \(ring.count) segment(s)")
        guard let end = curves.last?.2 else {
            Issue.record("the ring has no curve at all")
            return
        }
        #expect(abs(end.x - start.x) < 1e-9 && abs(end.y - start.y) < 1e-9,
                "the ring closes where it opened, not at \(end)")
    }
}

// MARK: - Which icon a tree row carries

/// The eight monochrome icons of the file tree (task 2670 S4;
/// `polter-artifacts/2665/v3/src/build2665.py`'s `get_node_icon`, lines
/// 84-143).
struct ControlRoomWorkdirsGlyphTests {
    typealias Glyph = ControlRoomWorkdirs.Glyph

    /// The design's rule, name by name: a folder, and the five extensions it
    /// distinguishes.
    @Test func theDesignsExtensionsPickTheDesignsIcons() {
        #expect(Glyph.of(name: "src", isDir: true, open: false) == .folderShut)
        #expect(Glyph.of(name: "src", isDir: true, open: true) == .folderOpen)
        #expect(Glyph.of(name: "BulkBar.tsx", isDir: false, open: false) == .fileTS)
        #expect(Glyph.of(name: "tasks.ts", isDir: false, open: false) == .fileTS)
        #expect(Glyph.of(name: "Client.swift", isDir: false, open: false) == .fileSwift)
        #expect(Glyph.of(name: "server.zig", isDir: false, open: false) == .fileZig)
        #expect(Glyph.of(name: "bulk-edit.md", isDir: false, open: false) == .fileMD)
        #expect(Glyph.of(name: "README.markdown", isDir: false, open: false) == .fileMD)
        #expect(Glyph.of(name: "package.json", isDir: false, open: false) == .fileJSON)
        // Everything else, which is most of a working directory.
        #expect(Glyph.of(name: "styles.css", isDir: false, open: false) == .fileOther)
        #expect(Glyph.of(name: "Makefile", isDir: false, open: false) == .fileOther)
    }

    /// **A directory is a folder whatever it is called.** `src.zig` is a
    /// directory if the core says so, and the extension must not win: the
    /// core's `is_dir` is the fact, and the name is only read for the rest.
    @Test func aDirectoryIsAFolderWhateverItIsCalled() {
        #expect(Glyph.of(name: "src.zig", isDir: true, open: false) == .folderShut)
        #expect(Glyph.of(name: "package.json", isDir: true, open: true) == .folderOpen)
    }

    /// Case does not matter, and the last dot is the one that counts.
    ///
    /// ⚠️ **The design lower-cases the extension**, and this follows it:
    /// `Makefile.ZIG` and `a.b.zig` are both zig. A rule that read the first
    /// dot, or that was case-sensitive, would draw a different icon for a
    /// file the design draws this one for.
    @Test func theExtensionIsTheLastDotLowerCased() {
        #expect(Glyph.of(name: "A.SWIFT", isDir: false, open: false) == .fileSwift)
        #expect(Glyph.of(name: "a.b.Zig", isDir: false, open: false) == .fileZig)
        #expect(Glyph.`extension`(of: "a.b.Zig") == "zig")
        #expect(Glyph.`extension`(of: "Makefile") == "")
    }

    /// ⚠️ **A name with no dot is not a bug and a leading dot is not
    /// special**, which is what the design's `name.split(".")[-1]` really
    /// does. `.gitignore` is read as extension `gitignore`, so it draws the
    /// general file icon rather than a folder's -- and a file literally
    /// called `.md` draws the markdown icon.
    ///
    /// Pinned rather than corrected: "a dot-file has no extension" is a rule
    /// the design does not have, and the two differ on exactly the names a
    /// working directory is full of. The day somebody wants the other rule,
    /// this assertion is where it is decided.
    @Test func aLeadingDotIsNotSpecialBecauseTheDesignSplitsOnTheLastDot() {
        #expect(Glyph.`extension`(of: ".gitignore") == "gitignore")
        #expect(Glyph.of(name: ".gitignore", isDir: false, open: false) == .fileOther)
        #expect(Glyph.`extension`(of: ".md") == "md")
        #expect(Glyph.of(name: ".md", isDir: false, open: false) == .fileMD)
        // A trailing dot is an empty extension and not a crash.
        #expect(Glyph.`extension`(of: "weird.") == "")
        #expect(Glyph.of(name: "weird.", isDir: false, open: false) == .fileOther)
    }

    /// **Every one of the eight drawings is readable, and reads to the
    /// drawing the design's string says.**
    ///
    /// The floor for this test is the parse itself: a string with a command
    /// this does not know draws **nothing** rather than a slightly-wrong
    /// icon, so the eight are asked here rather than trusted. The counts are
    /// the number of `<path>` elements in `build2665.py` lines 84-143 --
    /// one for each folder, two for the page and its fold plus one for the
    /// mark.
    @Test func allEightDrawingsAreReadableAndAreTheDesignsPaths() {
        #expect(Glyph.unreadable.isEmpty, "a drawing the parser could not read: \(Glyph.unreadable)")
        #expect(Glyph.allCases.count == 8)
        #expect(Glyph.folderShut.segments.count == 1)
        #expect(Glyph.folderOpen.segments.count == 1)
        for g in [Glyph.fileTS, .fileSwift, .fileZig, .fileMD, .fileJSON] {
            #expect(g.art.count == 3, "\(g): the design draws page, fold and mark")
            #expect(g.segments.count == 3)
            // The sheet and the fold are the same two strings in all five.
            #expect(g.art[0] == Glyph.fileBody)
            #expect(g.art[1] == Glyph.fileFold)
        }
        #expect(Glyph.fileOther.art.count == 2, "the general file is the sheet and its fold, with no mark")
    }

    /// The two folders are two different drawings, and the five marks are
    /// five different ones: an icon that read as its neighbour's would put
    /// the wrong mark on every row of a kind and nothing would say so.
    @Test func noTwoGlyphsDrawTheSameThing() {
        var seen: [String] = []
        for g in Glyph.allCases {
            let key = g.art.joined(separator: "|")
            #expect(!seen.contains(key), "\(g) draws what an earlier one draws")
            seen.append(key)
        }
    }

    /// The parser reads the arc, because `fileBody`'s four corners are arcs
    /// and a corner left unread is a page with square corners.
    ///
    /// ⚠️ **Its two flags are single characters**, which is the thing that
    /// goes wrong quietly: `a1 1 0 011 1` is radius 1, radius 1, rotation 0,
    /// **large 0, sweep 1**, then 1 and 1 -- where a reader that took `011`
    /// as a number would read rotation 0, large 11... and get a different
    /// arc, or none.
    @Test func theArcsFlagsAreSingleCharactersAndNotNumbers() {
        let one = Glyph.parse("M1 1a1 1 0 011 1")
        // One cubic out of the arc, ending where the string says.
        #expect(one.count == 2, "a move and one arc piece: \(one)")
        if case .cubic(_, _, let end) = one[1] {
            #expect(abs(end.x - 2) < 1e-9 && abs(end.y - 2) < 1e-9, "ended at \(end)")
        } else {
            Issue.record("the arc was not read as a cubic: \(one[1])")
        }
        // The same arc with the flags spelled apart is the same arc.
        #expect(Glyph.parse("M1 1a1 1 0 0 1 1 1") == one)
    }

    /// A string with something the parser does not know is **no segments**,
    /// not a half-drawing: a dropped `c` in a hand-edited string would
    /// otherwise draw a page missing its mark, which reads as a design with
    /// no mark rather than as a string nobody could read.
    @Test func aStringWithAnUnknownCommandReadsAsNothing() {
        #expect(Glyph.parse("M1 1Q2 2 3 3").isEmpty, "an unread command is not skipped")
        #expect(Glyph.parse("M1 1L").isEmpty, "a command with no arguments is nothing")
        #expect(Glyph.parse("").isEmpty)
        // And what it does know still reads.
        #expect(!Glyph.parse("M1 1L2 2Z").isEmpty)
    }
}

// MARK: - Looking for a file by name

/// The search over file names (task 2670 S5). **Not one file is read**: the
/// only thing looked at is the names a `files_list` already handed over, and
/// every assertion below is about names and counts.
struct ControlRoomWorkdirsSearchTests {
    typealias Search = ControlRoomWorkdirs.Search
    typealias Level = ControlRoomWorkdirs.Level
    typealias Levels = ControlRoomWorkdirs.Levels
    typealias Place = ControlRoomWorkdirs.Search.Place

    private func root(_ id: String, _ path: String) -> Place {
        Place(workdirId: id, path: path, rel: "")
    }

    private func level(_ rows: [(String, Bool)]) -> Level {
        Level(entries: rows.map { .init(name: $0.0, is_dir: $0.1) }, more: 0)
    }

    /// A round of the walk, **through the page's own door** (`round`), with a
    /// table answering what the page would have asked the core.
    ///
    /// ⚠️ **`round` and not a hand-rolled `while let place = next(...)` loop.**
    /// `next` hands a place over by *taking it out of the queue*, and what
    /// puts it back into the walk's accounting is the caller: `round` records
    /// either the level it read (`Levels.keep`) or the refusal it got
    /// (`Levels.keepRefusal`). A loop that collected what `next` returned and
    /// answered nothing would drop every directory on the floor -- which is
    /// exactly what an earlier draft of these tests did, and it read as
    /// "the walk ends at the roots" rather than as a loop nobody answered.
    ///
    /// `table` is the core: a directory it does not name comes back empty,
    /// which is what an empty directory in the core's answer means.
    @discardableResult
    private func round(_ search: inout Search, _ levels: inout Levels,
                       budget: Int = 64,
                       table: [String: [(String, Bool)]] = [:],
                       asked: inout [Place]) -> Int {
        var n = 0
        search.round(in: &levels, budget: budget) { place in
            asked.append(place)
            n += 1
            return .success(self.level(table[place.path] ?? []))
        }
        return n
    }

    /// Walk the whole way, one round big enough for the tree in the fixture.
    private func walk(_ search: inout Search, _ levels: inout Levels,
                      table: [String: [(String, Bool)]] = [:], reads: Int = 64) -> [Place] {
        var asked: [Place] = []
        _ = round(&search, &levels, budget: reads, table: table, asked: &asked)
        return asked
    }

    // MARK: What a name is compared against

    /// The whole matching rule: **the query contained in the name, case
    /// ignored**, and nothing wider. Not a prefix, not a glob, not a regular
    /// expression -- the design's other options (case, whole word) are not in
    /// the scope this round, and a rule wider than this one is a rule the
    /// field has nowhere to explain.
    @Test func aNameMatchesWhenItContainsTheQueryWhateverTheCase() {
        #expect(Search.matches(name: "BulkBar.tsx", query: "bulk"))
        #expect(Search.matches(name: "bulkbar.tsx", query: "BULK"))
        // Contained anywhere, not at the front.
        #expect(Search.matches(name: "src/routes/tasks.ts", query: "tasks"))
        // And not a prefix-only or whole-name rule.
        #expect(Search.matches(name: "aBulkBar.tsx", query: "bulk"))
        #expect(!Search.matches(name: "BulkBar.tsx", query: "bulkbars"))
        // `.` is a character and not a wildcard: a regular expression here
        // would match `BulkXBar.tsx` and this must not.
        #expect(!Search.matches(name: "BulkXBar.tsx", query: "bulk.bar"))
        #expect(Search.matches(name: "Bulk.Bar.tsx", query: "bulk.bar"))
    }

    /// **An empty query matches nothing.** A search nobody has typed into
    /// shows no results rather than every file in the group, which is what
    /// `contains("")` would say if the guard were not there (every string
    /// contains the empty one).
    @Test func anEmptyQueryMatchesNothing() {
        #expect(!Search.matches(name: "anything", query: ""))
        #expect(!Search.matches(name: "", query: ""))
        // And the same through a whole walk: no hits, ever.
        var s = Search(roots: [root("w", "/w")], query: "")
        var levels = Levels()
        levels.keep(level([("a.md", false), ("src", true)]), at: "/w")
        _ = walk(&s, &levels)
        #expect(s.hits.isEmpty)
    }

    // MARK: The walk

    /// A search starts at the roots, and the roots are what it looks at
    /// first: one directory per root, before anything under them.
    ///
    /// **Two rounds of one ask each**, so that the order is what is being
    /// read and not the size of the tree: the first round spends its whole
    /// budget on the first root, and the second on the second -- which is
    /// only true if a root comes before anything under a root.
    @Test func theWalkStartsAtEveryRoot() {
        var s = Search(roots: [root("a", "/a"), root("b", "/b")], query: "x")
        var levels = Levels()
        var asked: [Place] = []
        _ = round(&s, &levels, budget: 1, asked: &asked)
        #expect(asked.map(\.path) == ["/a"], "the roots are looked at before anything under them")

        asked = []
        _ = round(&s, &levels, budget: 1, asked: &asked)
        #expect(asked.map(\.path) == ["/b"], "and the second root before anything under the first")
        #expect(s.hits.isEmpty)
    }

    /// A directory that matches is **not a hit**: it is somewhere further to
    /// look. This is the difference between a search of file names and a
    /// search of everything.
    ///
    /// ⚠️ **"Somewhere further to look" is the walk entering it**, and not
    /// its staying in `queue`: `next` hands a directory over by taking it out
    /// of the queue, so what says a matching directory was followed is the
    /// *ask* made about it -- which is what is read below.
    @Test func aDirectoryThatMatchesIsWalkedAndNotReported() {
        var s = Search(roots: [root("w", "/w")], query: "src")
        var levels = Levels()
        levels.keep(level([("src", true), ("main.swift", false)]), at: "/w")
        var asked: [Place] = []
        _ = round(&s, &levels, table: ["/w/src": [("other.txt", false)]], asked: &asked)
        #expect(s.hits.map(\.name) == [], "a directory called `src` is not a file named `src`")
        #expect(asked.map(\.path) == ["/w/src"], "and it is somewhere further to look")
        #expect(levels.hasAsked("/w"), "the root came out of the store rather than being asked for again")
    }

    /// The path of a hit is built from **the root the core sent plus the
    /// names the core sent** -- never from anything the host made up -- and
    /// the `rel` of a place is where it sits under its root, which is what
    /// `files_list` wants.
    ///
    /// The root itself is asked for here (nothing is in the store), which is
    /// what makes its own `rel` readable: it is `""`, the ticket's own path.
    @Test func aPathIsTheRootAndTheNamesTheCoreSent() {
        var s = Search(roots: [root("w", "/Users/x/w")], query: "a.zig")
        var levels = Levels()
        var asked: [Place] = []
        _ = round(&s, &levels,
                  table: ["/Users/x/w": [("src", true), ("b.md", false)],
                          "/Users/x/w/src": [("a.zig", false)]],
                  asked: &asked)
        #expect(asked.map(\.rel) == ["", "src"])
        #expect(asked[1].path == "/Users/x/w/src")
        #expect(asked[1].workdirId == "w")
        #expect(s.hits == [Search.Hit(workdirId: "w", path: "/Users/x/w/src/a.zig", name: "a.zig")])
    }

    /// A level already in the page's store is folded in rather than asked
    /// for again: that is the whole reason the page keeps its levels, and a
    /// second search over a tree already walked must not re-read it.
    @Test func aLevelAlreadyReadIsFoldedInAndNotAskedForAgain() {
        var s = Search(roots: [root("w", "/w")], query: "a.md")
        var levels = Levels()
        levels.keep(level([("a.md", false), ("sub", true)]), at: "/w")
        let asked = walk(&s, &levels)
        #expect(asked.map(\.path) == ["/w/sub"], "only the directory nobody has read is a question")
        #expect(s.hits.map(\.name) == ["a.md"])
    }

    /// A directory whose read was **refused** is stepped over rather than
    /// asked for a second time: the core already said it may not be listed,
    /// and asking again is the same refusal spent twice.
    @Test func aRefusedDirectoryIsNotAskedForAgain() {
        var s = Search(roots: [root("w", "/w")], query: "a.md")
        var levels = Levels()
        levels.keep(level([("sub", true), ("a.md", false)]), at: "/w")
        levels.keepRefusal(.refusedFile(code: "access", why: "too wide"), at: "/w/sub")
        let asked = walk(&s, &levels)
        #expect(asked.isEmpty, "the refused directory is not a question and not a hit")
        #expect(s.done)
        #expect(s.hits.map(\.name) == ["a.md"])
    }

    /// The hits come out in **the order the walk met them**, which is the
    /// core's order (`Listing.zig`: directories first, then by name), and
    /// never a sort worked out here.
    ///
    /// ⚠️ A sort written here would be a second answer about what a search
    /// found, and `tools/control-room-hosts-do-not-decide.py` refuses a host
    /// that sorts at all. The level below is handed over in an order that is
    /// **not** alphabetical on purpose, so a sort would show up.
    ///
    /// The query is `x.txt` rather than `x` on purpose: every one of these
    /// names contains an `x`, so a one-letter query would match all three and
    /// the order read off the result would be the fixture's, not the walk's.
    @Test func theHitsComeOutInTheOrderTheWalkMetThem() {
        var s = Search(roots: [root("w", "/w")], query: "x.txt")
        var levels = Levels()
        levels.keep(level([("vote.txt", false), ("ax.txt", false), ("bx.txt", false)]), at: "/w")
        _ = walk(&s, &levels)
        #expect(s.hits.map(\.name) == ["ax.txt", "bx.txt"], "the core's order, taken as given")
    }

    // MARK: The two caps

    /// **Two hundred names, and the search stops reading at the two
    /// hundredth** (the supervisor's ruling: 最多 200 条). What matched past
    /// it is counted and no more is read.
    @Test func twoHundredNamesIsTheMostOneSearchAnswersWith() {
        let n = Search.max_results + 5
        var s = Search(roots: [root("w", "/w")], query: "a")
        var levels = Levels()
        levels.keep(level((0..<n).map { ("a\($0).txt", false) }), at: "/w")
        _ = walk(&s, &levels)
        #expect(s.hits.count == Search.max_results)
        #expect(s.more == 5, "the five past the cap are counted, not shown")
        #expect(s.capped, "and the walk says it stopped at the cap rather than at the end")
        #expect(s.done)
    }

    /// A walk that simply ran out is **not** capped: the two are told apart
    /// because one of them means 「还有 N 个」 and the other does not.
    @Test func aWalkThatEndedIsNotCapped() {
        var s = Search(roots: [root("w", "/w")], query: "a")
        var levels = Levels()
        levels.keep(level([("a.txt", false)]), at: "/w")
        _ = walk(&s, &levels)
        #expect(s.done)
        #expect(!s.capped)
        #expect(s.more == 0)
    }

    /// **A round reads a few directories and stops, leaving the rest of the
    /// walk in the queue** — which is what `moreToCome` is for, and why it is
    /// its own question rather than `!done` under another name.
    ///
    /// ⚠️ The two states it separates are the two sentences the page can
    /// draw: 「还在找」 and 「没有这个名字的文件」. A search that gave up after
    /// its round and reported the second one would be saying there is no such
    /// file when nobody looked.
    ///
    /// The first round's whole budget goes on the root -- the one directory
    /// nobody has read -- and reading it is what puts `a`, `b` and `c` in the
    /// queue; the second round then spends its own budget on the first of
    /// them. **Nothing is in the store to begin with**, so the root is a
    /// question and not a fold-in.
    @Test func aRoundReadsABudgetAndLeavesTheRestOfTheWalkInTheQueue() {
        var s = Search(roots: [root("w", "/w")], query: "zzz")
        var levels = Levels()
        var asked: [Place] = []
        _ = round(&s, &levels, budget: 1,
                  table: ["/w": [("a", true), ("b", true), ("c", true)]], asked: &asked)
        #expect(asked.map(\.path) == ["/w"], "the root is the first directory nobody has read")
        #expect(s.moreToCome, "three directories nobody has read is more to come")

        // A round with a budget of one reads one of them and leaves two.
        var one: [String] = []
        s.round(in: &levels, budget: 1) { place in
            one.append(place.path)
            return .success(Level(entries: [], more: 0))
        }
        #expect(one == ["/w/a"])
        #expect(s.moreToCome, "and there is still more after it")
    }

    /// A walk whose queue emptied has nothing more to come, and **that** is
    /// the state in which "no file by that name" is the truth.
    @Test func aWalkThatEmptiedItsQueueHasNothingMoreToCome() {
        var s = Search(roots: [root("w", "/w")], query: "zzz")
        var levels = Levels()
        levels.keep(level([("a.txt", false)]), at: "/w")
        _ = walk(&s, &levels)
        #expect(s.queue.isEmpty)
        #expect(!s.moreToCome)
        #expect(!s.capped)
    }

    /// At the results cap there is nothing more to come either: the search
    /// stopped because it had two hundred names, and looking further would
    /// count matches it has already decided not to show.
    @Test func atTheResultsCapNothingMoreIsToCome() {
        var s = Search(roots: [root("w", "/w")], query: "a")
        var levels = Levels()
        levels.keep(level((0..<(Search.max_results + 3)).map { ("a\($0).txt", false) }), at: "/w")
        _ = walk(&s, &levels)
        #expect(s.capped)
        #expect(!s.moreToCome)
    }

    /// **A round asks the core, and what the core refuses is remembered
    /// rather than asked for again** — and one refused directory does not
    /// stop the walk to the others.
    ///
    /// This is the whole of the page's side in one cell: `ask` is handed in
    /// (the page passes the core, a test passes a table), and what the walk
    /// decides around a refusal is a value.
    ///
    /// The query is `a.md` and the root holds a file by that name too, so the
    /// assertion at the end reads **which directory the hit came from**: the
    /// root is folded in from the store first, and only then are `bad` and
    /// `good` asked about.
    @Test func aRefusalIsRememberedAndTheWalkGoesOn() {
        var s = Search(roots: [root("w", "/w")], query: "a.md")
        var levels = Levels()
        levels.keep(level([("bad", true), ("good", true), ("a.md", false)]), at: "/w")
        var asked: [String] = []
        s.round(in: &levels) { place in
            asked.append(place.path)
            if place.path == "/w/bad" {
                return .failure(.refusedFile(code: "access", why: "too wide"))
            }
            return .success(place.path == "/w/good"
                            ? Level(entries: [.init(name: "a.md", is_dir: false)], more: 0)
                            : Level(entries: [], more: 0))
        }
        #expect(asked == ["/w/bad", "/w/good"], "the refusal does not stop the walk")
        #expect(levels.refusal("/w/bad") == .refusedFile(code: "access", why: "too wide"))
        #expect(s.hits.map(\.path) == ["/w/a.md", "/w/good/a.md"],
                "the root's own hit first, then the one under `good`")

        // And the next round does not ask about the refused one again.
        asked = []
        s.round(in: &levels) { place in
            asked.append(place.path)
            return .success(Level(entries: [], more: 0))
        }
        #expect(asked == [], "a refused directory is not asked for a second time")
    }

    /// The budget is spent on **asks** and not on directories the page
    /// already read: a level in the store costs nothing, and charging for it
    /// would make a second search over a walked tree slower for no reason.
    @Test func aLevelAlreadyInTheStoreCostsNothingFromTheBudget() {
        var s = Search(roots: [root("w", "/w")], query: "a.md")
        var levels = Levels()
        levels.keep(level([("a.md", false), ("sub", true)]), at: "/w")
        var asked: [String] = []
        s.round(in: &levels, budget: 1) { place in
            asked.append(place.path)
            return .success(Level(entries: [], more: 0))
        }
        #expect(asked == ["/w/sub"], "the root was folded in from the store without spending the round on it")
        #expect(s.hits.map(\.name) == ["a.md"])
    }

    // MARK: The two tabs

    /// **「搜内容」 is drawn and does not work**; 「搜文件名」 is what this
    /// round searches, and it is the tab the page opens on. The rule is here
    /// so the page cannot decide for itself which tab works -- the day
    /// contents are searched, this bit moves and the page follows.
    @Test func theContentTabIsDrawnAndGreyedAndTheFilenameTabIsTheOneThatWorks() {
        #expect(!Search.Mode.content.enabled)
        #expect(Search.Mode.filename.enabled)
        #expect(Search.mode == .filename, "a field under a greyed tab is a field nothing can be typed into")
        #expect(Search.Mode.allCases == [.content, .filename])
    }
}

// MARK: - What is in a directory

/// One level of a directory: the request, the reading of the answer, and the
/// memory of what has been asked for (task 2668).
///
/// **Held here rather than through the page** for `Tree`'s reason: the page
/// is a `sources.out` file, so a rule written in it could only be checked on
/// a running application. Everything below is a value.
struct ControlRoomWorkdirsLevelsTests {
    typealias Workdirs = ControlRoomWorkdirs
    typealias Level = ControlRoomWorkdirs.Level
    typealias Levels = ControlRoomWorkdirs.Levels

    private func answer(_ entries: String, more: Int = 0) -> String {
        #"{"entries":[\#(entries)],"more":\#(more)}"#
    }

    private func row(_ name: String, dir: Bool) -> String {
        #"{"name":"\#(name)","is_dir":\#(dir)}"#
    }

    // MARK: The request

    @Test func theRequestAsksForOneLevelOfTheTicketsDirectory() {
        #expect(Workdirs.listingRequest(token: "ab", rel: "")
            == #"{"method":"files_list","params":{"token":"ab","rel":""}}"#)
    }

    /// A name with a quote or a backslash in it builds a request that is
    /// still JSON, on `ControlRoomPageRequest.quoted`'s reason: the core
    /// would otherwise answer a parse failure about text this host wrote.
    @Test func aNameInTheRequestIsQuotedRatherThanPasted() {
        let request = Workdirs.listingRequest(token: "t", rel: "a\"b\\c")
        #expect(request.contains(#""rel":"a\"b\\c""#))
        #expect((try? JSONSerialization.jsonObject(with: Data(request.utf8))) != nil)
    }

    // MARK: Reading the answer

    @Test func aLevelReadsInTheCoresOrderAndWithItsCount() throws {
        let level = try Workdirs.readListing(
            answer([row("src", dir: true), row("a.tsx", dir: false), row("b.zig", dir: false)].joined(separator: ","),
                   more: 7)
        ).get()
        #expect(level.entries.map(\.name) == ["src", "a.tsx", "b.zig"])
        #expect(level.entries.map(\.is_dir) == [true, false, false])
        #expect(level.more == 7)
    }

    /// An empty directory is an answer, and not a failure: the page draws a
    /// directory with nothing in it, which is not the same thing as a
    /// directory it could not read.
    @Test func anEmptyLevelIsAnAnswerAndNotAFailure() throws {
        let level = try Workdirs.readListing(answer("")).get()
        #expect(level.entries.isEmpty)
        #expect(level.more == 0)
    }

    /// **The files door refuses in its own shape**, which is not the page
    /// door's `{"error":…}`: a code, a reason and the core's own sentence.
    /// Folding this into `notJSON` would throw the sentence away, and folding
    /// it into `refused` would lose which of the two doors answered.
    @Test func theFilesDoorsRefusalKeepsTheCoresSentence() {
        let text = #"{"refused":"access","reason":"outside","why":"it is not in this working directory"}"#
        #expect(Workdirs.readListing(text)
            == .failure(.refusedFile(code: "access", why: "it is not in this working directory")))
        // The door's own bad-request answer has no sentence, and is still
        // read as a refusal rather than as a broken document.
        #expect(Workdirs.readListing(#"{"refused":"bad_request","why":"BadParams"}"#)
            == .failure(.refusedFile(code: "bad_request", why: "BadParams")))
        #expect(Workdirs.readListing(#"{"refused":"no_ticket"}"#)
            == .failure(.refusedFile(code: "no_ticket", why: nil)))
        // And it is not the page door's refusal, nor a parse failure.
        #expect(Workdirs.readListing(text) != .failure(.notJSON))
        #expect(Workdirs.readListing(text) != .failure(.refused("access")))
    }

    @Test func anAnswerThatIsNotALevelIsNotJSON() {
        #expect(Workdirs.readListing("not json at all") == .failure(.notJSON))
        // A well-formed document of the wrong shape, too.
        #expect(Workdirs.readListing(#"{"entries":[]}"#) == .failure(.notJSON))
    }

    // MARK: What has been asked for

    /// **A directory nobody has asked about is not a directory whose level
    /// is empty**, and the two must be told apart: the first must be asked
    /// about, the second must not be asked about again on every redraw.
    @Test func askedAboutAndEmptyAreTwoDifferentStates() {
        var levels = Levels()
        #expect(!levels.hasAsked("/w/src"))
        levels.keep(Level(entries: [], more: 0), at: "/w/src")
        #expect(levels.hasAsked("/w/src"))
        #expect(levels.level("/w/src")?.entries.isEmpty == true)
    }

    /// **A refusal is remembered, and is not an empty level.** A page that
    /// stored it as one would draw "this directory is empty" where the core
    /// said "this directory may not be read", and would go on saying it.
    @Test func aRefusalIsNotStoredAsAnEmptyLevel() {
        var levels = Levels()
        levels.keepRefusal(.refusedFile(code: "access", why: "too wide"), at: "/w")
        #expect(levels.hasAsked("/w"), "it was asked about, so it is not asked again")
        #expect(levels.level("/w") == nil, "and it is not an empty directory")
        #expect(levels.refusal("/w") == .refusedFile(code: "access", why: "too wide"))

        // The other way round: a level read later replaces the refusal.
        levels.keep(Level(entries: [], more: 0), at: "/w")
        #expect(levels.refusal("/w") == nil)
        #expect(levels.level("/w") != nil)
    }

    /// A directory that is gone and comes back is asked about afresh rather
    /// than showing what was in it before, which is what `forget` is for.
    @Test func forgetDropsEveryLevelAndEveryRefusal() {
        var levels = Levels()
        levels.keep(Level(entries: [.init(name: "a", is_dir: false)], more: 0), at: "/w")
        levels.keepRefusal(.notJSON, at: "/w/sub")
        levels.toggle("/w")
        levels.forget()
        #expect(!levels.hasAsked("/w"))
        #expect(levels.refusal("/w/sub") == nil)
        #expect(!levels.isOpen("/w"), "a directory that comes back comes back shut, and has to be asked for again")
    }

    /// **`forget` gives the tickets up too**, and that is not the same thing
    /// as dropping the levels: a ticket is minted for one workdir of one
    /// group, so one kept across a change of group is a token this page would
    /// go on listing with against a directory the new group may not have --
    /// and the core's answer to that (`no_workdir`) would be drawn as a
    /// directory it may not read rather than as the page's own mistake.
    @Test func forgetGivesTheTicketsBackToo() {
        var levels = Levels()
        levels.keepTicket("aaaa", for: "w1")
        levels.keepTicket("bbbb", for: "w2")
        #expect(levels.ticket("w1") == "aaaa")
        levels.forget()
        #expect(levels.ticket("w1") == nil, "a ticket belongs to the group it was minted for")
        #expect(levels.ticket("w2") == nil)
    }

    // MARK: Asking again without leaving the group (task 2699)

    /// **`refresh` forgets what a directory holds and nothing else.** It is
    /// the person's own press (the sidebar's 刷新文件 / 刷新搜索), so the
    /// group has not changed and the directories under it are the same ones
    /// -- which is exactly what makes it not `forget`.
    ///
    /// What it drops is the two things a `files_list` answered: the level and
    /// the refusal. A directory that was refused may be readable now, and one
    /// that was read may hold something new; `hasAsked` goes back to false for
    /// both, which is what makes the page ask again.
    @Test func refreshDropsEveryLevelAndRefusal() {
        var levels = Levels()
        levels.keep(Level(entries: [.init(name: "a", is_dir: false)], more: 0), at: "/w")
        levels.keepRefusal(.notJSON, at: "/w/sub")
        #expect(levels.hasAsked("/w"))
        #expect(levels.hasAsked("/w/sub"))

        levels.refresh()
        #expect(!levels.hasAsked("/w"), "the level is gone, so the directory is asked about again")
        #expect(!levels.hasAsked("/w/sub"), "and a refusal may not hold the second time")
        #expect(levels.level("/w") == nil)
        #expect(levels.refusal("/w/sub") == nil)
    }

    /// ⚠️ **`refresh` keeps the tickets, and that is the half that must not
    /// go.** Every ticket this page holds is a `.workdir` one on a root of
    /// the group in front (`ControlRoomWorkdirsPage.ticket(for:path:)`), and
    /// the group has not changed -- so dropping them would mint a fresh one
    /// per root on every press and spend the core's ledger
    /// (`Tickets.max_tickets`) on directories the person is looking at right
    /// now, pushing other hosts' tickets out of it.
    ///
    /// This is the assertion that would have caught a `refresh` written as
    /// `forget` under a second name, which is what it looks like it is for.
    @Test func refreshKeepsTheTicketsTheGroupStillCovers() {
        var levels = Levels()
        levels.keepTicket("aaaa", for: "w1")
        levels.refresh()
        #expect(levels.ticket("w1") == "aaaa", "the same workdir of the same group is the same ticket")
    }

    /// ⚠️ **`refresh` keeps the open directories**, because they are the same
    /// directories: `forget`'s reason for dropping them is that after a change
    /// of group a directory "comes back" as one the group had before, and
    /// nothing comes back here. A press that folded the person's tree as a
    /// side effect of asking it a question would be the same defect a level
    /// over.
    @Test func refreshLeavesTheOpenDirectoriesOpen() {
        var levels = Levels()
        levels.toggle("/w")
        levels.toggle("/w/src")
        levels.refresh()
        #expect(levels.isOpen("/w"))
        #expect(levels.isOpen("/w/src"))
    }

    /// **The open directories are readable as paths, and they are still there
    /// after a refresh** -- which is what makes the page able to ask about
    /// them again at all: after the levels are dropped the tree's rows no
    /// longer name them (`nodes(under:in:)` walks the levels), so a page that
    /// looked for the open directories among the rows would find a root and
    /// nothing under it.
    @Test func theOpenDirectoriesAreKeptAsPathsAndSurviveARefresh() {
        var levels = Levels()
        levels.toggle("/w/src")
        levels.toggle("/w/docs")
        #expect(Set(levels.openDirectories) == ["/w/src", "/w/docs"])
        levels.refresh()
        #expect(Set(levels.openDirectories) == ["/w/src", "/w/docs"])
    }

    /// **The first ticket for a workdir wins**, so a second ask does not
    /// replace the one the page has been listing with: the two are the same
    /// tree, and keeping the later one would be a token for a workdir whose
    /// earlier token is still in the core's ledger.
    @Test func aSecondTicketForOneRootDoesNotReplaceTheFirst() {        var levels = Levels()
        levels.keepTicket("aaaa", for: "w1")
        levels.keepTicket("bbbb", for: "w1")
        #expect(levels.ticket("w1") == "aaaa")
        // A different workdir is a different ticket.
        levels.keepTicket("cccc", for: "w2")
        #expect(levels.ticket("w2") == "cccc")
    }

    // MARK: Which directories under a root are open

    /// **A directory under a root starts shut**, which is what makes the
    /// tree lazy: a level is a `files_list` the core has to walk, so a page
    /// that drew every directory open would read the whole tree the first
    /// time a root was opened (the supervisor's scope for task 2670: 文件树
    /// 按目录懒加载).
    ///
    /// ⚠️ **The opposite of `Tree`'s default for a root**, and deliberately:
    /// a root is one `workdirs` row the page was already given, so opening
    /// it costs nothing, and a directory under it costs a directory read.
    /// The two types keep the same *kind* of bit -- the one that tells "not
    /// decided" from "decided" -- pointed at whichever default is free.
    @Test func aDirectoryNobodyHasTouchedIsShutAndOneClickOpensIt() {
        var levels = Levels()
        #expect(!levels.isOpen("/w/src"))
        levels.toggle("/w/src")
        #expect(levels.isOpen("/w/src"))
        levels.toggle("/w/src")
        #expect(!levels.isOpen("/w/src"))
    }

    /// Shutting one directory leaves its neighbour alone, and the set is by
    /// path: two directories are two of them.
    @Test func openingOneDirectoryLeavesItsNeighbourAlone() {
        var levels = Levels()
        levels.toggle("/w/src")
        #expect(!levels.isOpen("/w/docs"))
    }
}

// MARK: - The rows the tree draws

/// The rows under one root (task 2670 S4). **What is tested here is what the
/// walk into a lazy tree decides**: which rows there are, their paths, their
/// depth, and that a directory nobody has opened is not walked into.
///
/// Nothing here is about a glyph or a colour -- which icon a row gets is
/// `ControlRoomWorkdirsGlyphTests`', and where a row goes is the page's.
struct ControlRoomWorkdirsNodeTests {
    typealias Workdirs = ControlRoomWorkdirs
    typealias Level = ControlRoomWorkdirs.Level
    typealias Levels = ControlRoomWorkdirs.Levels
    typealias Node = ControlRoomWorkdirs.Node

    private func root(_ id: String, _ path: String) -> Workdirs.Dir {
        Workdirs.Dir(id: id, path: path, short: path, who: [], also_in: [],
                     readable: true, why: nil, editing: 0)
    }

    private func level(_ rows: [(String, Bool)]) -> Level {
        Level(entries: rows.map { .init(name: $0.0, is_dir: $0.1) }, more: 0)
    }

    /// **A directory nobody has opened is not walked into**, which is what
    /// 「文件树按目录懒加载」 means: its level may not even be in the store, and
    /// a walk that guessed at it would draw rows for a `files_list` nobody
    /// asked for.
    @Test func aDirectoryNobodyHasOpenedHasNoRowsUnderIt() {
        var levels = Levels()
        levels.keep(level([("src", true), ("a.md", false)]), at: "/w")
        levels.keep(level([("deep.md", false)]), at: "/w/src")
        let rows = Workdirs.nodes(under: root("w", "/w"), in: levels)
        #expect(rows.map(\.name) == ["src", "a.md"], "the level is there, but the directory is shut")
        #expect(rows.map(\.depth) == [1, 1])
    }

    /// Opened, it is walked into, and its rows are one level deeper.
    @Test func anOpenedDirectorysRowsComeAfterItselfAndOneDeeper() {
        var levels = Levels()
        levels.keep(level([("src", true), ("a.md", false)]), at: "/w")
        levels.keep(level([("lib", true), ("deep.md", false)]), at: "/w/src")
        levels.toggle("/w/src")
        let rows = Workdirs.nodes(under: root("w", "/w"), in: levels)
        #expect(rows.map(\.name) == ["src", "lib", "deep.md", "a.md"],
                "a directory's own rows come straight after it")
        #expect(rows.map(\.depth) == [1, 2, 2, 1])
    }

    /// Every path is **the root's own path with the core's names joined on**,
    /// and every `rel` is where that sits under the root -- which is what
    /// `files_list` takes. Nothing here is a path the host worked out for
    /// itself.
    @Test func everyPathIsTheRootsPathPlusTheCoresNames() {
        var levels = Levels()
        levels.keep(level([("src", true)]), at: "/Users/x/w")
        levels.keep(level([("deep", true)]), at: "/Users/x/w/src")
        levels.toggle("/Users/x/w/src")
        levels.toggle("/Users/x/w/src/deep")
        let rows = Workdirs.nodes(under: root("w", "/Users/x/w"), in: levels)
        #expect(rows.map(\.path) == ["/Users/x/w/src", "/Users/x/w/src/deep"])
        #expect(rows.map(\.rel) == ["src", "src/deep"])
        #expect(rows.map(\.isDir) == [true, true])
    }

    /// **A root nobody has read draws nothing**, and not an empty sentence
    /// either -- the page says what an unread root looks like, and a walk
    /// that invented a row here would be drawing a directory that was never
    /// listed.
    @Test func aRootWhoseLevelIsNotInTheStoreHasNoRows() {
        let rows = Workdirs.nodes(under: root("w", "/w"), in: Levels())
        #expect(rows.isEmpty)
    }

    /// The order is **the core's**, kept as it arrived: a level that comes in
    /// a deliberately unsorted order is drawn in that order.
    @Test func theRowsComeOutInTheCoresOrderAndAreNotSortedHere() {
        var levels = Levels()
        levels.keep(level([("zeta.md", false), ("alpha.md", false), ("mid.md", false)]), at: "/w")
        let rows = Workdirs.nodes(under: root("w", "/w"), in: levels)
        #expect(rows.map(\.name) == ["zeta.md", "alpha.md", "mid.md"])
    }
}

/// How wide the left column is, and what a drag may ask for (task 2719 S3).
///
/// The two values are tested apart on purpose: `asked` is what the person
/// dragged to, `drawn` is what a window of a given width can hold. A rule
/// that kept only one of them would pass a drag test and then reset the
/// person's width the first time they narrowed the window.
struct ControlRoomWorkdirsSplitTests {
    typealias Split = ControlRoomWorkdirs.Split

    // MARK: What a drag may ask for

    @Test func aDragInsideTheRangeIsKeptAsItIs() {
        #expect(Split.asked(300) == 300)
    }

    @Test func aDragUnderTheNarrowestIsTheNarrowest() {
        #expect(Split.asked(100) == Split.minSide)
    }

    @Test func aDragPastTheWidestIsTheWidest() {
        #expect(Split.asked(900) == Split.maxSide)
    }

    /// A container wide enough to hold what was asked for draws exactly it.
    @Test func aWideWindowDrawsWhatWasAskedFor() {
        #expect(Split.drawn(wanted: 296, container: 1200) == 296)
    }

    /// **The workbench keeps its least width**, and the column gives up the
    /// rest: 500 - 240 = 260.
    @Test func aNarrowWindowSqueezesTheColumnAndNotTheWorkbench() {
        #expect(Split.drawn(wanted: 296, container: 500) == 260)
        #expect(Split.drawn(wanted: 296, container: 500) + Split.minRight == 500)
    }

    /// A window too narrow for both gives the workbench its least width and
    /// the column what is left -- **including nothing**.
    @Test func aWindowTooNarrowForBothDrawsNoColumnRatherThanOverflowing() {
        #expect(Split.drawn(wanted: 296, container: 200) == 0)
        #expect(Split.drawn(wanted: 296, container: 240) == 0)
    }

    /// The squeeze is applied to whatever was asked for, so a column already
    /// dragged narrow is not made wider by a small window.
    @Test func aSqueezeNeverWidensAColumnThatWasAskedToBeNarrow() {
        #expect(Split.drawn(wanted: 180, container: 500) == 180)
    }

    /// **The width asked for survives the squeeze.** The same value is drawn
    /// at 260 in a 500-wide window and at its full 296 in a wide one again:
    /// this is what stops a narrowed window from eating the person's choice.
    @Test func theWidthAskedForComesBackWhenTheWindowIsWideAgain() {
        let asked = Split.asked(296)
        #expect(Split.drawn(wanted: asked, container: 500) == 260)
        #expect(Split.drawn(wanted: asked, container: 1200) == 296)
    }

    /// Nothing is drawn past the design's widest, however much room there is.
    @Test func aVeryWideWindowStillStopsAtTheWidest() {
        #expect(Split.drawn(wanted: 600, container: 5000) == Split.maxSide)
    }
}
