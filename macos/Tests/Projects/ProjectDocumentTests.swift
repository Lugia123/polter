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
        let left = ProjectNode.leaf(cwd: "/work/repo", title: "left pane", history: "", scrollback: "")
        let right = ProjectNode.leaf(cwd: "/work/repo/tests", title: "right pane", history: "", scrollback: "")
        let root = ProjectNode.split(direction: .horizontal, ratio: 0.37, left: left, right: right)
        let file = ProjectFile(name: "two panes", savedAt: 1_757_000_000, root: root, nextScrollback: nil)

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
        let file = ProjectFile(name: "empty", savedAt: 0, root: nil, nextScrollback: nil)
        let decoded = try ProjectFile.decode(from: try file.encoded())
        #expect(decoded.root == nil)
        #expect(decoded.paneCount == 0)
    }

    @Test func paneCountCountsAllLeavesInNestedSplits() {
        let a: ProjectNode = .leaf(cwd: "/a", title: "", history: "", scrollback: "")
        let b: ProjectNode = .leaf(cwd: "/b", title: "", history: "", scrollback: "")
        let c: ProjectNode = .leaf(cwd: "/c", title: "", history: "", scrollback: "")
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
        #expect(left == .leaf(cwd: "/work/repo", title: "✳ retry.py", history: "a1b2c3.history", scrollback: ""))
        #expect(right == .leaf(cwd: "/work/repo/tests", title: "✳ tests", history: "", scrollback: ""))
    }

    /// `saved_at` must be a JSON integer: `Project.zig`'s reader rejects a
    /// float (`.integer => |n| n, else => error.Corrupt`). Encoding
    /// `Date` via `.secondsSince1970` would print a decimal here instead --
    /// this is the test that would have caught it.
    @Test func encodesSavedAtAsAPlainInteger() throws {
        let file = ProjectFile(name: "x", savedAt: 1_757_000_000, root: nil, nextScrollback: nil)
        let text = try #require(String(bytes: try file.encoded(), encoding: .utf8))
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

    /// Forward compatibility: a file written by a newer build -- one that
    /// added a field this build has never heard of, at the top level, on a
    /// leaf, or on a split -- must still open, with everything this build
    /// does know decoded exactly. Adding a field to this format means
    /// adding it three times (`src/Project.zig`, `windows/host/src/project.rs`,
    /// and here), and the ports don't ship in lockstep; a reader that
    /// rejected unknown keys would make every added field a breaking change.
    ///
    /// An unknown node *kind* is a different thing and still fails -- see
    /// `unknownNodeKindFailsToDecode`.
    @Test func unknownFieldsAreIgnoredNotRejected() throws {
        let json = """
        {
          "name": "from the future",
          "saved_at": 1757000000,
          "top_level_from_the_future": {"nested": [1, 2, 3]},
          "root": {
            "kind": "split",
            "direction": "vertical",
            "ratio": 0.25,
            "split_from_the_future": true,
            "left": {
              "kind": "leaf",
              "cwd": "/a",
              "history": "h.history",
              "leaf_from_the_future": "0.snap"
            },
            "right": { "kind": "leaf", "cwd": "/b", "another_one": 42 }
          }
        }
        """

        let file = try ProjectFile.decode(from: Data(json.utf8))
        #expect(file.name == "from the future")
        #expect(file.savedAt == 1_757_000_000)
        #expect(file.root == .split(
            direction: .vertical,
            ratio: 0.25,
            left: .leaf(cwd: "/a", title: "", history: "h.history", scrollback: ""),
            right: .leaf(cwd: "/b", title: "", history: "", scrollback: "")))
    }

    // MARK: - Scrollback

    /// The new field has to survive *this* encoder, not just be readable:
    /// a writer that forgot to emit `scrollback` would still decode every
    /// fixture fine and quietly save projects that restore empty screens.
    @Test func scrollbackIsWrittenAndReadBack() throws {
        let leaf = ProjectNode.leaf(cwd: "/a", title: "", history: "", scrollback: "3.snap")
        let file = ProjectFile(name: "x", savedAt: 0, root: leaf, nextScrollback: nil)
        let data = try file.encoded()

        let text = try #require(String(bytes: data, encoding: .utf8))
        #expect(text.contains("\"scrollback\":\"3.snap\""))
        #expect(try ProjectFile.decode(from: data).root == leaf)
    }

    /// An empty `scrollback` is left out rather than written as `""`, the
    /// same as `cwd`/`title`/`history` -- so a project saved with the
    /// feature off is byte-for-byte what it was before the field existed.
    @Test func emptyScrollbackIsOmitted() throws {
        let file = ProjectFile(name: "x", savedAt: 0, root: .leaf(cwd: "/a", title: "", history: "", scrollback: ""), nextScrollback: nil)
        let text = try #require(String(bytes: try file.encoded(), encoding: .utf8))
        #expect(!text.contains("scrollback"))
    }

    /// The core deletes a snapshot it can't decode, so a project file must
    /// not be able to point it anywhere but its own snapshot directory. A
    /// value that isn't a plain `<n>.snap` reads as "no scrollback", and
    /// the rest of the pane -- and the project -- still opens.
    @Test func scrollbackThatIsNotAPlainSnapshotNameIsDropped() throws {
        for hostile in ["../../x.snap", "/etc/passwd", "a/0.snap", ".snap", "0.snap.tmp", "0x1.snap", "١.snap"] {
            let json = """
            {"name": "x", "saved_at": 0, "root": {"kind": "leaf", "cwd": "/a", "scrollback": \(String(reflecting: hostile))}}
            """
            let file = try ProjectFile.decode(from: Data(json.utf8))
            #expect(file.root == .leaf(cwd: "/a", title: "", history: "", scrollback: ""), "\(hostile)")
        }
    }

    /// A listing still skips a file it can't read -- as `Project.zig` and
    /// `project.rs` do -- but no longer silently: every skip is reported,
    /// so a project that vanished from the picker leaves a trace.
    @Test func aListingReportsEveryFileItSkips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("polter-project-listing-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let good = dir.appendingPathComponent("good.json")
        let bad = dir.appendingPathComponent("bad.json")
        let gone = dir.appendingPathComponent("gone.json")
        try ProjectFile(name: "good", savedAt: 1, root: nil, nextScrollback: nil).encoded().write(to: good)
        try Data("{not json".utf8).write(to: bad)

        var skipped: [URL] = []
        let listed = ProjectListing.decode([good, bad, gone]) { url, _ in skipped.append(url) }
        #expect(listed.map(\.file.name) == ["good"])
        #expect(skipped == [bad, gone])
    }

    /// `next_scrollback` is read from the key the other ports write, not
    /// just round-tripped through this file's own encoder: a round trip
    /// stays green if both directions agree on a wrong key.
    @Test func nextScrollbackIsReadFromTheSharedKey() throws {
        let json = #"{"name": "x", "saved_at": 0, "next_scrollback": 7}"#
        #expect(try ProjectFile.decode(from: Data(json.utf8)).nextScrollback == 7)

        let text = try #require(String(bytes: ProjectFile(name: "x", savedAt: 0, root: nil, nextScrollback: 7).encoded(), encoding: .utf8))
        #expect(text.contains(#""next_scrollback":7"#))
    }

    /// A file written before the counter existed -- or by a port that
    /// doesn't write it -- still opens, with the counter absent.
    @Test func aFileWithoutNextScrollbackStillOpens() throws {
        let json = #"{"name": "old", "saved_at": 1757000000, "root": {"kind": "leaf", "cwd": "/a", "scrollback": "3.snap"}}"#
        let file = try ProjectFile.decode(from: Data(json.utf8))
        #expect(file.nextScrollback == nil)
        #expect(file.scrollbackFilenames == ["3.snap"])
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
