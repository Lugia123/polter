import AppKit
import Foundation
import Testing
@testable import Ghostty

/// What a split tree and a project file are **as bytes**, today.
///
/// Every other test of these two formats writes something and reads it
/// back, and a round trip is green for any format that agrees with itself
/// -- a renamed key, a reordered enum, a value that used to be left out and
/// is now written, all pass it. These hold the bytes: each expected string
/// below was written out by hand from the encoders' source
/// (`SplitTree`'s `Codable` extensions, `ProjectNode.encode(to:)`) and not
/// pasted from a run.
///
/// **Why now.** Stacking (control-room.md, 12.6.2) adds to the tree, and
/// its first promise is that a tree with no stack in it is stored exactly
/// as it is today: same keys, same version, same bytes. That promise is
/// this file. It has to stay green, unedited, through every step that
/// follows.
///
/// Keys are sorted (`.sortedKeys`) so that the bytes are one thing and not
/// whatever order a dictionary gave that day. The project file already
/// writes them sorted; window restoration does not ask for an order, so
/// for the tree this pins what is written and not the order it comes in.
struct StoredBytesTests {
    private static func view(_ n: Int) -> MockView {
        MockView(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")!)
    }

    private static func leaf(_ n: Int) -> String {
        #"{"view":{"id":"00000000-0000-0000-0000-00000000000\#(n)"}}"#
    }

    private static func bytes(_ tree: SplitTree<MockView>) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try #require(String(bytes: try encoder.encode(tree), encoding: .utf8))
    }

    // MARK: The tree, as window restoration stores it

    @Test func anEmptyTreeIsItsVersionAndNothingElse() throws {
        let got = try Self.bytes(SplitTree<MockView>())
        #expect(got == #"{"version":1}"#)
    }

    @Test func oneTerminalIsOneViewUnderRoot() throws {
        let got = try Self.bytes(SplitTree<MockView>(view: Self.view(1)))
        #expect(got == #"{"root":\#(Self.leaf(1)),"version":1}"#)
    }

    @Test func leftAndRightIsASplitWithItsDirectionRatioAndTwoChildren() throws {
        let tree = SplitTree<MockView>(
            root: .split(.init(direction: .horizontal, ratio: 0.5,
                               left: .leaf(view: Self.view(1)), right: .leaf(view: Self.view(2)))),
            zoomed: nil)
        let got = try Self.bytes(tree)
        let want = #"{"root":{"split":{"direction":{"horizontal":{}},"left":\#(Self.leaf(1)),"#
            + #""ratio":0.5,"right":\#(Self.leaf(2))}},"version":1}"#
        #expect(got == want)
    }

    /// 1 | (2 over (3 | 4)), three splits deep, with three different ratios.
    private static func nested() -> (tree: SplitTree<MockView>.Node, four: MockView) {
        let four = view(4)
        let inner: SplitTree<MockView>.Node = .split(.init(
            direction: .horizontal, ratio: 0.75, left: .leaf(view: view(3)), right: .leaf(view: four)))
        let middle: SplitTree<MockView>.Node = .split(.init(
            direction: .vertical, ratio: 0.25, left: .leaf(view: view(2)), right: inner))
        return (.split(.init(direction: .horizontal, ratio: 0.5, left: .leaf(view: view(1)), right: middle)), four)
    }

    private static let nestedRoot =
        #"{"split":{"direction":{"horizontal":{}},"left":\#(leaf(1)),"ratio":0.5,"#
        + #""right":{"split":{"direction":{"vertical":{}},"left":\#(leaf(2)),"ratio":0.25,"#
        + #""right":{"split":{"direction":{"horizontal":{}},"left":\#(leaf(3)),"ratio":0.75,"#
        + #""right":\#(leaf(4))}}}}}}"#

    @Test func threeSplitsDeepNestsOnTheRight() throws {
        let got = try Self.bytes(SplitTree<MockView>(root: Self.nested().tree, zoomed: nil))
        #expect(got == #"{"root":\#(Self.nestedRoot),"version":1}"#)
    }

    @Test func theZoomedPaneIsStoredAsThePathToIt() throws {
        let (root, four) = Self.nested()
        let got = try Self.bytes(SplitTree<MockView>(root: root, zoomed: .leaf(view: four)))
        let want = #"{"root":\#(Self.nestedRoot),"version":1,"#
            + #""zoomed":{"path":[{"right":{}},{"right":{}},{"right":{}}]}}"#
        #expect(got == want)
    }

    // MARK: The project file, as this host writes it

    private static func project(_ file: ProjectFile) throws -> String {
        try #require(String(bytes: try file.encoded(), encoding: .utf8))
    }

    @Test func aProjectWithNoLayoutIsItsNameAndWhenItWasSaved() throws {
        let got = try Self.project(ProjectFile(name: "empty", savedAt: 1_757_000_000, root: nil, nextScrollback: nil))
        #expect(got == #"{"name":"empty","saved_at":1757000000}"#)
    }

    @Test func aProjectOfOneTerminalWritesOnlyTheFieldsItHas() throws {
        let file = ProjectFile(
            name: "one", savedAt: 1_757_000_000,
            root: .leaf(cwd: "/work/repo", title: "", history: "", scrollback: ""), nextScrollback: nil)
        let got = try Self.project(file)
        // A slash is written escaped by this host's encoder; the core's
        // writer does not escape it (`Project.zig` holds its own bytes).
        #expect(got == #"{"name":"one","root":{"cwd":"\/work\/repo","kind":"leaf"},"saved_at":1757000000}"#)
    }

    @Test func aProjectOfTwoTerminalsSideBySide() throws {
        let file = ProjectFile(
            name: "写 retry 装饰器", savedAt: 1_757_000_000,
            root: .split(
                direction: .horizontal, ratio: 0.62,
                left: .leaf(cwd: "/work/repo", title: "✳ retry.py", history: "a1b2c3.history", scrollback: "0.snap"),
                right: .leaf(cwd: "/work/repo/tests", title: "✳ tests", history: "", scrollback: "")),
            nextScrollback: 4)
        let got = try Self.project(file)
        let want = #"{"name":"写 retry 装饰器","next_scrollback":4,"root":{"direction":"horizontal","kind":"split","#
            + #""left":{"cwd":"\/work\/repo","history":"a1b2c3.history","kind":"leaf","scrollback":"0.snap","#
            + #""title":"✳ retry.py"},"ratio":0.62,"#
            + #""right":{"cwd":"\/work\/repo\/tests","kind":"leaf","title":"✳ tests"}},"saved_at":1757000000}"#
        #expect(got == want)
    }

    @Test func aProjectThreeSplitsDeep() throws {
        func pane(_ name: String) -> ProjectNode { .leaf(cwd: "", title: name, history: "", scrollback: "") }
        let inner: ProjectNode = .split(direction: .horizontal, ratio: 0.75, left: pane("c"), right: pane("d"))
        let middle: ProjectNode = .split(direction: .vertical, ratio: 0.25, left: pane("b"), right: inner)
        let file = ProjectFile(
            name: "deep", savedAt: 1,
            root: .split(direction: .horizontal, ratio: 0.5, left: pane("a"), right: middle), nextScrollback: nil)
        let got = try Self.project(file)
        let want = #"{"name":"deep","root":{"direction":"horizontal","kind":"split","left":{"kind":"leaf","title":"a"},"#
            + #""ratio":0.5,"right":{"direction":"vertical","kind":"split","left":{"kind":"leaf","title":"b"},"#
            + #""ratio":0.25,"right":{"direction":"horizontal","kind":"split","left":{"kind":"leaf","title":"c"},"#
            + #""ratio":0.75,"right":{"kind":"leaf","title":"d"}}}},"saved_at":1}"#
        #expect(got == want)
    }
}
