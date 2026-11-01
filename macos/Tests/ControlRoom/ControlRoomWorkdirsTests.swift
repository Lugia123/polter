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
