import AppKit
import Foundation
import Testing
@testable import Ghostty

/// A split tree with a stack in it, as window restoration stores it
/// (control-room.md, 12.6.2, "存盘 1 → 2"), and what is read back.
///
/// **Bytes first.** A round trip is green for any format that agrees with
/// itself, so every stored form below is a string written out by hand from
/// the encoder's source, not pasted from a run, and the round trips come
/// after it. `StoredBytesTests` holds the other half of the promise: a tree
/// with no stack is written as version 1, exactly as before.
struct StoredStackTests {
    typealias Tree = SplitTree<MockView>

    private static func view(_ n: Int) -> MockView {
        MockView(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")!)
    }

    private static func id(_ n: Int) -> String {
        #"{"id":"00000000-0000-0000-0000-00000000000\#(n)"}"#
    }

    private static func leaf(_ n: Int) -> String {
        #"{"view":\#(id(n))}"#
    }

    private static func bytes(_ tree: Tree) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try #require(String(bytes: try encoder.encode(tree), encoding: .utf8))
    }

    private static func decoded(_ text: String) throws -> Tree {
        try JSONDecoder().decode(Tree.self, from: Data(text.utf8))
    }

    /// Whether `text` was refused; a tree read out of it is not handed out
    /// of the closure (see `SplitStackTests.refusal`).
    private static func refused(_ text: String) -> Bool {
        do {
            _ = try decoded(text)
            return false
        } catch {
            return true
        }
    }

    private static func ids(_ views: [MockView]) -> [UUID] { views.map(\.id) }

    /// 1 | 3, and the right pane holds 2, 3, 4 in that order with 3 in
    /// front: one behind it on each side, so where the shown one goes back
    /// in is not the end of the list by accident.
    private static func stacked() throws -> (tree: Tree, views: [MockView]) {
        let v = (1...4).map(view)
        var tree = try Tree(view: v[0]).inserting(view: v[1], at: v[0], direction: .right)
        tree = try tree.stacking(v[2], onto: v[1])
        tree = try tree.stacking(v[3], onto: v[2])
        tree = try tree.showing(v[2])
        return (tree, v)
    }

    private static let splitOneThree =
        #"{"split":{"direction":{"horizontal":{}},"left":\#(leaf(1)),"ratio":0.5,"right":\#(leaf(3))}}"#

    private static let stackedText =
        #"{"root":\#(splitOneThree),"#
        + #""stacks":[{"behind":[\#(id(2)),\#(id(4))],"pane":{"path":[{"right":{}}]},"shown":1}],"#
        + #""version":2}"#

    // MARK: Written

    @Test func aStackIsVersionTwoWithThePanesPathAndOnlyTheTerminalsBehind() throws {
        let got = try Self.bytes(try Self.stacked().tree)
        #expect(got == Self.stackedText)
    }

    @Test func stacksAreWrittenInTheOrderOfTheirPanesNotTheOrderTheyWereMade() throws {
        // 1 | 2, each with one behind it; the right one is stacked first.
        let v = (1...4).map(Self.view)
        var tree = try Tree(view: v[0]).inserting(view: v[1], at: v[0], direction: .right)
        tree = try tree.stacking(v[3], onto: v[1])
        tree = try tree.stacking(v[2], onto: v[0])
        let got = try Self.bytes(tree)
        let want = #"{"root":{"split":{"direction":{"horizontal":{}},"left":\#(Self.leaf(3)),"ratio":0.5,"#
            + #""right":\#(Self.leaf(4))}},"stacks":["#
            + #"{"behind":[\#(Self.id(1))],"pane":{"path":[{"left":{}}]},"shown":1},"#
            + #"{"behind":[\#(Self.id(2))],"pane":{"path":[{"right":{}}]},"shown":1}],"version":2}"#
        #expect(got == want)
    }

    @Test func aZoomedStackedPaneKeepsBothItsZoomAndItsStack() throws {
        let (tree, v) = try Self.stacked()
        let zoomed = tree.zooming(.leaf(view: v[2]))
        let got = try Self.bytes(zoomed)
        let want = #"{"root":\#(Self.splitOneThree),"#
            + #""stacks":[{"behind":[\#(Self.id(2)),\#(Self.id(4))],"pane":{"path":[{"right":{}}]},"shown":1}],"#
            + #""version":2,"zoomed":{"path":[{"right":{}}]}}"#
        #expect(got == want)
    }

    // MARK: Read

    @Test func aStoredStackComesBackWithItsMembersInOrderAndTheSameOneInFront() throws {
        let tree = try Self.decoded(Self.stackedText)
        let stack = try #require(tree.stacks.count == 1 ? tree.stacks.first : nil)
        #expect(stack.members.map(\.id) == [2, 3, 4].map { Self.view($0).id })
        #expect(stack.shown == Self.view(3).id)
        #expect(Self.ids(tree.shownLeaves()) == [1, 3].map { Self.view($0).id })
        // The shown member **is** the view in the pane, not a second one
        // made from a second copy: a terminal decoded twice is two
        // terminals.
        let front = try #require(tree.shownLeaves().last)
        #expect(stack.members[1] === front)
        #expect(tree.members().count == 4)
    }

    @Test func readAndWrittenAgainItIsTheSameBytes() throws {
        #expect(try Self.bytes(try Self.decoded(Self.stackedText)) == Self.stackedText)
    }

    @Test func aWindowSavedBeforeStacksStillReads() throws {
        // Written by hand as a build before stacks wrote it: version 1 and
        // no `stacks` key at all.
        let old = #"{"root":\#(Self.splitOneThree),"version":1,"zoomed":{"path":[{"left":{}}]}}"#
        let tree = try Self.decoded(old)
        #expect(tree.stacks.isEmpty)
        #expect(Self.ids(tree.shownLeaves()) == [1, 3].map { Self.view($0).id })
        #expect(tree.zoomed != nil)
        #expect(try Self.bytes(tree) == old)
    }

    @Test func takenApartAfterReadingItIsVersionOneAgain() throws {
        var tree = try Self.decoded(Self.stackedText)
        let behind = try #require(tree.stacks.first).members.filter { $0.id != Self.view(3).id }
        for view in behind { tree = try tree.removing(member: view) }
        #expect(try Self.bytes(tree) == #"{"root":\#(Self.splitOneThree),"version":1}"#)
    }

    // MARK: Refused

    @Test func aLaterVersionIsRefused() {
        #expect(Self.refused(#"{"root":\#(Self.leaf(1)),"version":3}"#))
    }

    @Test func versionTwoWithoutItsStacksIsRefused() {
        #expect(Self.refused(#"{"root":\#(Self.leaf(1)),"version":2}"#))
    }

    @Test func aStackThatDoesNotFitItsTreeIsRefused() {
        func with(_ stacks: String) -> String {
            #"{"root":\#(Self.splitOneThree),"stacks":[\#(stacks)],"version":2}"#
        }
        let fits = #"{"behind":[\#(Self.id(2))],"pane":{"path":[{"right":{}}]},"shown":0}"#
        #expect(!Self.refused(with(fits)), "the control: this one fits")

        // Its path is the split, not a pane.
        #expect(Self.refused(with(#"{"behind":[\#(Self.id(2))],"pane":{"path":[]},"shown":0}"#)))
        // Its path goes nowhere.
        #expect(Self.refused(with(#"{"behind":[\#(Self.id(2))],"pane":{"path":[{"right":{}},{"left":{}}]},"shown":0}"#)))
        // Nobody behind: a pane of one is a leaf, not a stack.
        #expect(Self.refused(with(#"{"behind":[],"pane":{"path":[{"right":{}}]},"shown":0}"#)))
        // The shown one put back past the end, or before the start.
        #expect(Self.refused(with(#"{"behind":[\#(Self.id(2))],"pane":{"path":[{"right":{}}]},"shown":2}"#)))
        #expect(Self.refused(with(#"{"behind":[\#(Self.id(2))],"pane":{"path":[{"right":{}}]},"shown":-1}"#)))
        // One pane, two stacks.
        #expect(Self.refused(with(fits + "," + #"{"behind":[\#(Self.id(4))],"pane":{"path":[{"right":{}}]},"shown":0}"#)))
    }
}
