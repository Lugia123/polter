import AppKit
import Foundation
import Testing
@testable import Ghostty

/// What a split tree is **as bytes** when a window's state is saved, today.
///
/// Every other test of this format writes something and reads it back, and
/// a round trip is green for any format that agrees with itself -- a
/// renamed key, a reordered enum, a value that used to be left out and is
/// now written, all pass it. These hold the bytes: each expected string
/// below was written out by hand from the encoder's source (`SplitTree`'s
/// `Codable` extensions) and not pasted from a run.
///
/// **Why now.** Stacking (control-room.md, 12.6.2) adds to the tree, and
/// its first promise is that a tree with no stack in it is stored exactly
/// as it is today: same keys, same version, same bytes. That promise is
/// this file. It has to stay green, unedited, through every step that
/// follows.
///
/// **The project file is not pinned here any more.** It was, while a
/// project was one tab written as format 1. It is format 2 now, and its
/// bytes are held where all three of its writers are held to them:
/// `test/project-format/`, made by `src/Project.zig` and only read by this
/// host (`SharedProjectFilesTests`) and the Windows one. A second copy of
/// those bytes here would be a second thing to disagree with.
///
/// Keys are sorted (`.sortedKeys`) so that the bytes are one thing and not
/// whatever order a dictionary gave that day. Window restoration does not
/// ask for an order, so this pins what is written and not the order it
/// comes in.
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
}
