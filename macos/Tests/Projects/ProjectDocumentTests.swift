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
        let left = ProjectNode.leaf(cwd: "/work/repo", title: "left pane", history: "", scrollback: "", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .unknown)
        let right = ProjectNode.leaf(cwd: "/work/repo/tests", title: "right pane", history: "", scrollback: "", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .unknown)
        let root = ProjectNode.split(direction: .horizontal, ratio: 0.37, left: left, right: right)
        let file = ProjectFile.oneTab(name: "two panes", savedAt: 1_757_000_000, root: root, nextScrollback: nil)

        let decoded = try ProjectFile.decode(from: try file.encoded())

        guard case .split(let direction, let ratio, let decodedLeft, let decodedRight) = try #require(decoded.firstTab) else {
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
        let file = ProjectFile.oneTab(name: "empty", savedAt: 0, root: nil, nextScrollback: nil)
        let decoded = try ProjectFile.decode(from: try file.encoded())
        #expect(decoded.firstTab == nil)
        #expect(decoded.paneCount == 0)
    }

    @Test func paneCountCountsAllLeavesInNestedSplits() {
        let a: ProjectNode = .leaf(cwd: "/a", title: "", history: "", scrollback: "", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .unknown)
        let b: ProjectNode = .leaf(cwd: "/b", title: "", history: "", scrollback: "", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .unknown)
        let c: ProjectNode = .leaf(cwd: "/c", title: "", history: "", scrollback: "", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .unknown)
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

        guard case .split(let direction, let ratio, let left, let right) = try #require(file.firstTab) else {
            Issue.record("root did not decode as a split")
            return
        }
        #expect(direction == .horizontal)
        #expect(ratio == 0.62)
        #expect(left == .leaf(cwd: "/work/repo", title: "✳ retry.py", history: "a1b2c3.history", scrollback: "", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .unknown))
        #expect(right == .leaf(cwd: "/work/repo/tests", title: "✳ tests", history: "", scrollback: "", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .unknown))
    }

    /// `saved_at` must be a JSON integer: `Project.zig`'s reader rejects a
    /// float (`.integer => |n| n, else => error.Corrupt`). Encoding
    /// `Date` via `.secondsSince1970` would print a decimal here instead --
    /// this is the test that would have caught it.
    @Test func encodesSavedAtAsAPlainInteger() throws {
        let file = ProjectFile.oneTab(name: "x", savedAt: 1_757_000_000, root: nil, nextScrollback: nil)
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
        #expect(file.firstTab == .split(
            direction: .vertical,
            ratio: 0.25,
            left: .leaf(cwd: "/a", title: "", history: "h.history", scrollback: "", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .unknown),
            right: .leaf(cwd: "/b", title: "", history: "", scrollback: "", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .unknown)))
    }

    // MARK: - Scrollback

    /// The new field has to survive *this* encoder, not just be readable:
    /// a writer that forgot to emit `scrollback` would still decode every
    /// fixture fine and quietly save projects that restore empty screens.
    @Test func scrollbackIsWrittenAndReadBack() throws {
        let leaf = ProjectNode.leaf(cwd: "/a", title: "", history: "", scrollback: "3.snap", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .unknown)
        let file = ProjectFile.oneTab(name: "x", savedAt: 0, root: leaf, nextScrollback: nil)
        let data = try file.encoded()

        let text = try #require(String(bytes: data, encoding: .utf8))
        #expect(text.contains("\"scrollback\":\"3.snap\""))
        #expect(try ProjectFile.decode(from: data).firstTab == leaf)
    }

    /// An empty `scrollback` is left out rather than written as `""`, the
    /// same as `cwd`/`title`/`history` -- so a project saved with the
    /// feature off is byte-for-byte what it was before the field existed.
    @Test func emptyScrollbackIsOmitted() throws {
        let file = ProjectFile.oneTab(name: "x", savedAt: 0, root: .leaf(cwd: "/a", title: "", history: "", scrollback: "", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .unknown), nextScrollback: nil)
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
            #expect(file.firstTab == .leaf(cwd: "/a", title: "", history: "", scrollback: "", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .unknown), "\(hostile)")
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
        try ProjectFile.oneTab(name: "good", savedAt: 1, root: nil, nextScrollback: nil).encoded().write(to: good)
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

        let text = try #require(String(bytes: ProjectFile.oneTab(name: "x", savedAt: 0, root: nil, nextScrollback: 7).encoded(), encoding: .utf8))
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

// MARK: - Format 3: the user's marks on a pane (task 1699)

@Suite
struct ProjectPaneMarksFileTests {
    private static func file(format: Int, leaf keys: String) -> Data {
        Data("{\"format\":\(format),\"name\":\"n\",\"saved_at\":1,\"windows\":[{\"front\":0,\"tabs\":[{\"root\":{\"kind\":\"leaf\",\(keys)\"agent\":{\"kind\":\"none\"}}}]}]}".utf8)
    }

    private static func leaf(
        _ cwd: String, seat: Bool = false, color: PaneColor = .none, refused: Bool = false, shielded: Bool = false,
        agent: ProjectAgent = .none
    ) -> ProjectNode {
        .leaf(cwd: cwd, title: "", history: "", scrollback: "", bySupervisor: false, supervisorSeat: seat,
              color: color, workersRefused: refused, shielded: shielded, agent: agent)
    }

    /// Read as the default, the next save would write the default over what
    /// the user set -- the silent loss format 3 exists to prevent.
    @Test func aMarkThisBuildDoesNotWriteIsAnErrorNeverTheDefault() throws {
        let cases: [(String, String)] = [
            ("a colour this build does not name", #""color":"magenta","#),
            ("a colour that is not text", #""color":5,"#),
            ("a colour that is null", #""color":null,"#),
            ("workers said the way that is never written", #""workers":"allowed","#),
            ("workers that is not a word this build writes", #""workers":"some","#),
            ("a shield written false", #""shielded":false,"#),
            ("a shield that is not yes", #""shielded":1,"#),
            ("a seat written false", #""supervisor_seat":false,"#),
            ("a seat that is not yes", #""supervisor_seat":"yes","#),
        ]
        for (what, keys) in cases {
            #expect(throws: (any Error).self, "\(what): read without complaint") {
                try ProjectFile.decode(from: Self.file(format: 3, leaf: keys))
            }
        }
        // The control: each of the four, said the way it is written, reads.
        let ok = try ProjectFile.decode(from: Self.file(
            format: 3, leaf: #""supervisor_seat":true,"color":"yellow","workers":"refused","shielded":true,"#))
        #expect(ok.firstTab == Self.leaf("", seat: true, color: .yellow, refused: true, shielded: true))
        // And a format 2 file that happens to carry them never reads them.
        let two = try ProjectFile.decode(from: Self.file(format: 2, leaf: #""color":"magenta","shielded":false,"#))
        #expect(two.firstTab == Self.leaf(""))
    }

    /// The bytes, key for key in the order `Project.zig` writes them, each
    /// left out when it is the default.
    @Test func theMarksAreWrittenAfterBySupervisorInTheirOrder() throws {
        let all = ProjectNode.leaf(
            cwd: "/w", title: "t", history: "", scrollback: "0.snap", bySupervisor: true, supervisorSeat: true,
            color: .graphite, workersRefused: true, shielded: true, agent: .none)
        var out = ""
        try ProjectFileWriting.node(all, into: &out)
        #expect(out == #"{"kind":"leaf","cwd":"/w","title":"t","scrollback":"0.snap","by_supervisor":true,"supervisor_seat":true,"color":"graphite","workers":"refused","shielded":true,"agent":{"kind":"none"}}"#)
        out = ""
        try ProjectFileWriting.node(Self.leaf("/w"), into: &out)
        #expect(out == #"{"kind":"leaf","cwd":"/w","agent":{"kind":"none"}}"#)
        // `none` is the default and is not written, whatever the enum says.
        for color in PaneColor.allCases where color != .none {
            out = ""
            try ProjectFileWriting.node(Self.leaf("", color: color), into: &out)
            #expect(out.contains("\"color\":\"\(color.name)\""))
        }
    }

    /// Before format 3 the seat was wherever the supervisor's agent was.
    @Test func aFormat2FilesSeatIsThePaneOfTheSupervisorsAgent() throws {
        let boss = ProjectAgent.agent(role: "polter-supervisor", cli: "claude-code", session: "s", supervisor: true)
        let json = #"{"format":2,"name":"n","saved_at":1,"windows":[{"front":0,"tabs":[{"root":{"kind":"split","direction":"horizontal","ratio":0.5,"left":{"kind":"leaf","cwd":"/a","agent":{"kind":"agent","role":"polter-supervisor","cli":"claude-code","session":"s","supervisor":true}},"right":{"kind":"leaf","cwd":"/b","agent":{"kind":"none"}}}}]}]}"#
        let file = try ProjectFile.decode(from: Data(json.utf8))
        #expect(file.firstTab == .split(
            direction: .horizontal, ratio: 0.5, left: Self.leaf("/a", seat: true, agent: boss), right: Self.leaf("/b")))
        // In format 3 the seat is only `supervisor_seat`: the agent says
        // who was the supervisor, not where it sits.
        let three = json.replacingOccurrences(of: #""format":2"#, with: #""format":3"#)
        #expect(try ProjectFile.decode(from: Data(three.utf8)).firstTab == .split(
            direction: .horizontal, ratio: 0.5, left: Self.leaf("/a", agent: boss), right: Self.leaf("/b")))
    }

    /// Two panes that each say they are the seat: neither is -- and on its
    /// own, apart from the two-supervisors rule.
    @Test func twoSeatsReadAsNone() throws {
        let boss = ProjectAgent.agent(role: "r", cli: "c", session: "", supervisor: true)
        let two = ProjectFile.oneTab(name: "n", savedAt: 1, root: .split(
            direction: .horizontal, ratio: 0.5,
            left: Self.leaf("/a", seat: true, color: .purple, agent: boss), right: Self.leaf("/b", seat: true)), nextScrollback: nil)
        let read = try ProjectFile.decode(from: two.encoded())
        #expect(read.firstTab == .split(
            direction: .horizontal, ratio: 0.5,
            left: Self.leaf("/a", color: .purple, agent: boss), right: Self.leaf("/b")))
        // One seat is kept.
        let one = ProjectFile.oneTab(name: "n", savedAt: 1, root: Self.leaf("/a", seat: true), nextScrollback: nil)
        #expect(try ProjectFile.decode(from: one.encoded()) == one)
    }
}
