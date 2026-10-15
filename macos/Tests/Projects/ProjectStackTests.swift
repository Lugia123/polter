import AppKit
import Foundation
import Testing
@testable import Ghostty

/// A pane holding a stack, in a project (format 3, `Project.zig`'s module
/// comment): what goes into the file from a split tree, and what comes out
/// of it. The bytes of a format 3 file are held in `test/project-format/`
/// (`stacked`, read by `SharedProjectFilesTests`); this is what decides
/// which terminals are in it.
struct ProjectStackTests {
    typealias Tree = SplitTree<MockView>

    /// Terminals 1...5, each saved with its own directory and snapshot.
    private final class Terminals {
        let views = (1...5).map { _ in MockView() }
        func number(_ view: MockView) -> Int { (views.firstIndex { $0 === view } ?? -1) + 1 }
        func view(_ n: Int) -> MockView { views[n - 1] }
        func leaf(_ view: MockView) -> ProjectNode {
            let n = number(view)
            return .leaf(cwd: "/\(n)", title: "t\(n)", history: "", scrollback: "\(n).snap", agent: .none)
        }
    }

    private static func leaf(_ n: Int, agent: ProjectAgent = .none) -> ProjectNode {
        .leaf(cwd: "/\(n)", title: "t\(n)", history: "", scrollback: "\(n).snap", agent: agent)
    }

    /// 1 | 3, the right pane holding 2, 3, 4 with 3 in front.
    private static func stackedTree(_ t: Terminals) throws -> Tree {
        var tree = try Tree(view: t.view(1)).inserting(view: t.view(2), at: t.view(1), direction: .right)
        tree = try tree.stacking(t.view(3), onto: t.view(2))
        tree = try tree.stacking(t.view(4), onto: t.view(3))
        return try tree.showing(t.view(3))
    }

    private static func capture(_ tree: Tree, _ t: Terminals) throws -> ProjectNode {
        ProjectNode.capturing(try #require(tree.root), in: tree, leaf: t.leaf)
    }

    private static func project(_ root: ProjectNode) -> ProjectFile {
        .oneTab(name: "p", savedAt: 1, root: root, nextScrollback: 6)
    }

    // MARK: Saved

    @Test func aStackedPaneIsSavedAsEveryTerminalInItsOrderAndWhichOneShows() throws {
        let t = Terminals()
        let got = try Self.capture(try Self.stackedTree(t), t)
        let want = ProjectNode.split(
            direction: .horizontal, ratio: 0.5,
            left: Self.leaf(1),
            right: .stack(shown: 1, members: [Self.leaf(2), Self.leaf(3), Self.leaf(4)]))
        #expect(got == want)
    }

    @Test func aTreeWithNoStackIsSavedAsItAlwaysWasAndWrittenAsFormat2() throws {
        let t = Terminals()
        let tree = try Tree(view: t.view(1)).inserting(view: t.view(2), at: t.view(1), direction: .right)
        let got = try Self.capture(tree, t)
        #expect(got == .split(direction: .horizontal, ratio: 0.5, left: Self.leaf(1), right: Self.leaf(2)))
        let file = Self.project(got)
        #expect(file.format == 2)
        let text = try #require(String(bytes: try file.encoded(), encoding: .utf8))
        #expect(text.hasPrefix(#"{"format":2,"#))
    }

    @Test func aProjectWithAStackIsWrittenAsFormat3AndReadsBackTheSame() throws {
        let t = Terminals()
        let file = Self.project(try Self.capture(try Self.stackedTree(t), t))
        #expect(file.format == 3)
        let bytes = try file.encoded()
        let text = try #require(String(bytes: bytes, encoding: .utf8))
        #expect(text.hasPrefix(#"{"format":3,"#))
        // The stack as the module comment spells it, members in order.
        #expect(text.contains(
            #"{"kind":"stack","shown":1,"members":[{"kind":"leaf","cwd":"/2","title":"t2","scrollback":"2.snap","agent":{"kind":"none"}},"#
            + #"{"kind":"leaf","cwd":"/3","title":"t3","scrollback":"3.snap","agent":{"kind":"none"}},"#
            + #"{"kind":"leaf","cwd":"/4","title":"t4","scrollback":"4.snap","agent":{"kind":"none"}}]}"#))
        #expect(try ProjectFile.decode(from: bytes) == file)
    }

    @Test func theSnapshotsOfTheTerminalsBehindAreTheProjectsToo() throws {
        // What a save keeps; a name left out is a snapshot it deletes.
        let t = Terminals()
        let file = Self.project(try Self.capture(try Self.stackedTree(t), t))
        #expect(Set(file.scrollbackFilenames) == ["1.snap", "2.snap", "3.snap", "4.snap"])
        // A stack is one pane, as the settings window counts them.
        #expect(file.paneCount == 2)
    }

    @Test func aTerminalPutIntoAPaneOrTakenOutIsALayoutChangeAndShowingAnotherIsNot() throws {
        let t = Terminals()
        let tree = try Self.stackedTree(t)
        let was = try Self.capture(tree, t).layout
        #expect(try Self.capture(try tree.showing(t.view(4)), t).layout == was)
        #expect(try Self.capture(try tree.stacking(t.view(5), onto: t.view(3)), t).layout != was)
        #expect(try Self.capture(try tree.removing(member: t.view(2)), t).layout != was)
    }

    // MARK: Opened

    @Test func aSavedStackOpensWithEveryTerminalInItsOrderAndTheSameOneShowing() throws {
        let root = ProjectNode.split(
            direction: .vertical, ratio: 0.25,
            left: Self.leaf(1),
            right: .stack(shown: 2, members: [Self.leaf(2), Self.leaf(3), Self.leaf(4)]))
        var made: [String] = []
        var byCwd: [String: MockView] = [:]
        let tree: Tree = root.building { leaf in
            guard case .leaf(let cwd, _, _, _, _) = leaf else { return MockView() }
            made.append(cwd)
            let view = MockView()
            byCwd[cwd] = view
            return view
        }
        // One terminal for each, the ones behind included, and no more.
        #expect(made == ["/1", "/2", "/3", "/4"])
        let stack = try #require(tree.stacks.count == 1 ? tree.stacks.first : nil)
        #expect(stack.members.map(\.id) == ["/2", "/3", "/4"].map { byCwd[$0]!.id })
        #expect(stack.shown == byCwd["/4"]!.id)
        #expect(tree.shownLeaves().map(\.id) == ["/1", "/4"].map { byCwd[$0]!.id })
        #expect(tree.members().count == 4)
    }

    @Test func savedReadAndOpenedItIsTheTreeItWas() throws {
        let t = Terminals()
        let file = Self.project(try Self.capture(try Self.stackedTree(t), t))
        let back = try ProjectFile.decode(from: try file.encoded())
        let u = Terminals()
        let opened: Tree = try #require(back.firstTab).building { leaf in
            guard case .leaf(let cwd, _, _, _, _) = leaf, let n = Int(cwd.dropFirst()) else { return MockView() }
            return u.view(n)
        }
        #expect(try Self.capture(opened, u) == file.firstTab)
        #expect(opened.isShown(u.view(3)))
        #expect(!opened.isShown(u.view(2)))
        #expect(!opened.isShown(u.view(4)))
    }

    // MARK: Refused

    private static func file(format: Int, root: String) -> Data {
        Data(#"{"format":\#(format),"name":"n","saved_at":1,"root":{"kind":"moved-to-windows"},"windows":[{"front":0,"tabs":[{"root":\#(root)}]}]}"#.utf8)
    }

    private static let a = #"{"kind":"leaf","cwd":"/a","agent":{"kind":"none"}}"#
    private static let b = #"{"kind":"leaf","cwd":"/b","agent":{"kind":"none"}}"#

    @Test func aStackIsReadOnlyFromFormat3OnlyOfTerminalsAndNeverOfOne() throws {
        // The control: this one is read.
        let fits = try ProjectFile.decode(from: Self.file(format: 3, root: #"{"kind":"stack","shown":1,"members":[\#(Self.a),\#(Self.b)]}"#))
        #expect(fits.firstTab?.shownLeaf == .leaf(cwd: "/b", title: "", history: "", scrollback: "", agent: .none))

        for (format, root) in [
            (2, #"{"kind":"stack","shown":0,"members":[\#(Self.a),\#(Self.b)]}"#),
            (3, #"{"kind":"stack","shown":0,"members":[\#(Self.a)]}"#),
            (3, #"{"kind":"stack","shown":0,"members":[]}"#),
            (3, #"{"kind":"stack","shown":2,"members":[\#(Self.a),\#(Self.b)]}"#),
            (3, #"{"kind":"stack","shown":-1,"members":[\#(Self.a),\#(Self.b)]}"#),
            (3, #"{"kind":"stack","members":[\#(Self.a),\#(Self.b)]}"#),
            (3, #"{"kind":"stack","shown":0,"members":[\#(Self.a),{"kind":"split","direction":"horizontal","ratio":0.5,"left":\#(Self.a),"right":\#(Self.b)}]}"#),
        ] {
            do {
                let file = try ProjectFile.decode(from: Self.file(format: format, root: root))
                Issue.record("read, and should not have been: format \(format), \(root) -> \(file)")
            } catch {}
        }
    }

    @Test func aStackThatBreaksItsRuleIsNotWritten() {
        for bad: ProjectNode in [
            .stack(shown: 0, members: [Self.leaf(1)]),
            .stack(shown: 2, members: [Self.leaf(1), Self.leaf(2)]),
            .stack(shown: 0, members: [Self.leaf(1), .stack(shown: 0, members: [Self.leaf(2), Self.leaf(3)])]),
        ] {
            #expect(throws: ProjectFileError.notAStack) { try Self.project(bad).encoded() }
        }
    }

    @Test func aSupervisorBehindInAStackCountsAsOneOfTwoAndNeitherIsIt() throws {
        let sup = ProjectAgent.agent(role: "r", cli: "", session: "", supervisor: true)
        let file = Self.project(.split(
            direction: .horizontal, ratio: 0.5,
            left: Self.leaf(1, agent: sup),
            right: .stack(shown: 0, members: [Self.leaf(2), Self.leaf(3, agent: sup)])))
        let back = try ProjectFile.decode(from: try file.encoded())
        #expect(back.tabs.reduce(0) { $0 + $1.supervisorCount } == 0)
    }
}
