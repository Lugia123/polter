import Testing
import Foundation
@testable import Ghostty

@Suite
struct ProjectDocumentTests {
    // MARK: - Round trip

    /// The floor this file exists to hold: a save/load that silently
    /// hardcoded `ratio: 0.5` (the same trap `SplitTree.inserting` sets
    /// the ratio to when a split is first created) would pass any test
    /// that only checks pane count or directories. This one doesn't.
    @Test func roundTripPreservesRatioNotJustShape() throws {
        let left = ProjectNode.leaf(cwd: "/work/repo", title: "left pane", history: "")
        let right = ProjectNode.leaf(cwd: "/work/repo/tests", title: "right pane", history: "")
        let root = ProjectNode.split(direction: .horizontal, ratio: 0.37, left: left, right: right)
        let file = ProjectFile(name: "two panes", savedAt: 1_757_000_000, root: root)

        let decoded = try ProjectFile.decode(from: try file.encoded())

        guard case .split(let direction, let ratio, let decodedLeft, let decodedRight) = try #require(decoded.root) else {
            Issue.record("root did not decode as a split")
            return
        }
        #expect(direction == .horizontal)
        #expect(ratio == 0.37)
        #expect(decodedLeft == left)
        #expect(decodedRight == right)
        #expect(decoded.name == "two panes")
        #expect(decoded.savedAt == 1_757_000_000)
        #expect(decoded.paneCount == 2)
    }

    @Test func emptyProjectRoundTrips() throws {
        let file = ProjectFile(name: "empty", savedAt: 0, root: nil)
        let decoded = try ProjectFile.decode(from: try file.encoded())
        #expect(decoded.root == nil)
        #expect(decoded.paneCount == 0)
    }

    @Test func paneCountCountsAllLeavesInNestedSplits() {
        let a: ProjectNode = .leaf(cwd: "/a", title: "", history: "")
        let b: ProjectNode = .leaf(cwd: "/b", title: "", history: "")
        let c: ProjectNode = .leaf(cwd: "/c", title: "", history: "")
        let inner: ProjectNode = .split(direction: .vertical, ratio: 0.5, left: b, right: c)
        let root: ProjectNode = .split(direction: .horizontal, ratio: 0.3, left: a, right: inner)
        #expect(root.leafCount == 3)
    }

    // MARK: - Interop with `src/Project.zig`

    /// Not a round trip of this file's own encoder -- a fixture shaped
    /// exactly like `Project.zig`'s `write()` output (the same values as
    /// its own test, "what is written comes back exactly"), decoded here.
    /// A round trip through only this file's encoder would stay green even
    /// if the key names or shape quietly drifted from the real contract;
    /// this is what actually proves the two sides agree.
    @Test func decodesWhatTheCoreWouldWrite() throws {
        let json = """
        {
          "name": "写 retry 装饰器",
          "saved_at": 1757000000,
          "root": {
            "kind": "split",
            "direction": "horizontal",
            "ratio": 0.62,
            "left": {
              "kind": "leaf",
              "cwd": "/work/repo",
              "title": "✳ retry.py",
              "history": "a1b2c3.history"
            },
            "right": {
              "kind": "leaf",
              "cwd": "/work/repo/tests",
              "title": "✳ tests"
            }
          }
        }
        """

        let file = try ProjectFile.decode(from: Data(json.utf8))
        #expect(file.name == "写 retry 装饰器")
        #expect(file.savedAt == 1_757_000_000)

        guard case .split(let direction, let ratio, let left, let right) = try #require(file.root) else {
            Issue.record("root did not decode as a split")
            return
        }
        #expect(direction == .horizontal)
        #expect(ratio == 0.62)
        #expect(left == .leaf(cwd: "/work/repo", title: "✳ retry.py", history: "a1b2c3.history"))
        #expect(right == .leaf(cwd: "/work/repo/tests", title: "✳ tests", history: ""))
    }

    /// `saved_at` must be a JSON integer: `Project.zig`'s reader rejects a
    /// float (`.integer => |n| n, else => error.Corrupt`). Encoding
    /// `Date` via `.secondsSince1970` would print a decimal here instead --
    /// this is the test that would have caught it.
    @Test func encodesSavedAtAsAPlainInteger() throws {
        let file = ProjectFile(name: "x", savedAt: 1_757_000_000, root: nil)
        let text = String(decoding: try file.encoded(), as: UTF8.self)
        #expect(text.contains("\"saved_at\":1757000000"))
        #expect(!text.contains("1757000000.0"))
    }

    /// A split missing a child is exactly the "half a tree" this format's
    /// readers -- on every platform -- promise never to hand back.
    @Test func splitMissingAChildFailsTheWholeDecode() {
        let json = """
        {
          "name": "x",
          "saved_at": 0,
          "root": {
            "kind": "split",
            "direction": "horizontal",
            "ratio": 0.5,
            "left": { "kind": "leaf", "cwd": "/a" }
          }
        }
        """
        #expect(throws: (any Error).self) {
            try ProjectFile.decode(from: Data(json.utf8))
        }
    }

    @Test func unknownNodeKindFailsToDecode() {
        let json = """
        {"name": "x", "saved_at": 0, "root": {"kind": "gazebo"}}
        """
        #expect(throws: (any Error).self) {
            try ProjectFile.decode(from: Data(json.utf8))
        }
    }
}
