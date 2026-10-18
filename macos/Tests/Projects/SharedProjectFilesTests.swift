import Testing
import Foundation
@testable import Ghostty

/// **The files `src/Project.zig` makes, read here and written back.**
///
/// The project format has three implementations and no compiler sees more
/// than one of them. `test/project-format/` is what holds them together:
/// `src/Project.zig`'s tests make each `<stem>.json` there from a value
/// spelled out in that file, and this implementation and
/// `windows/projectfile` read every one and have to write the same bytes
/// back. Nothing here makes those files -- a file this build wrote and then
/// read back would be green whatever it had got wrong.
///
/// `index.txt` says what each is: `same` (read and written, it is the same
/// bytes), `from` (`<stem>.in.json` read and written is the bytes of
/// `<stem>.json`), `refused` (`<stem>.in.json` is from a later format and
/// must not be read).
enum SharedProjectFiles {
    /// Where the files live, found from this file's own path -- the tests
    /// only ever run from a checkout.
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath() // the logic-test package links this file
            .deletingLastPathComponent() // Projects
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // the repository
            .appendingPathComponent("test/project-format")
    }

    struct Reading {
        var rows = 0
        var named = 0
        var problems: [String] = []
    }

    static func read(_ directory: URL) throws -> Reading {
        var reading = Reading()
        let index = try String(contentsOf: directory.appendingPathComponent("index.txt"), encoding: .utf8)
        func bytes(_ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name)) }
        func text(_ data: Data) -> String { String(bytes: data, encoding: .utf8) ?? "<not UTF-8>" }

        for line in index.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 2 else {
                reading.problems.append("index.txt: '\(line)' is not `kind<TAB>stem`")
                continue
            }
            let (kind, stem) = (parts[0], parts[1])
            reading.rows += 1
            switch kind {
            case "same":
                reading.named += 1
                let want = try bytes("\(stem).json")
                let got = try ProjectFile.decode(from: want).encoded()
                if got != want {
                    reading.problems.append("\(stem).json did not come back as it went in:\n  want \(text(want))\n  got  \(text(got))")
                }

            case "from":
                reading.named += 2
                let want = try bytes("\(stem).json")
                let got = try ProjectFile.decode(from: try bytes("\(stem).in.json")).encoded()
                if got != want {
                    reading.problems.append("\(stem).in.json was not written as \(stem).json:\n  want \(text(want))\n  got  \(text(got))")
                }
                // What it was written as reads, and stays as it is.
                let again = try ProjectFile.decode(from: want).encoded()
                if again != want {
                    reading.problems.append("\(stem).json did not come back as it went in:\n  want \(text(want))\n  got  \(text(again))")
                }

            case "refused":
                reading.named += 1
                do {
                    let file = try ProjectFile.decode(from: try bytes("\(stem).in.json"))
                    reading.problems.append("\(stem).in.json must be refused as too new, and read as \(file)")
                } catch ProjectFileError.tooNew {
                    // The refusal asked for.
                } catch {
                    reading.problems.append("\(stem).in.json must be refused as too new, and was refused as \(error)")
                }

            default:
                reading.problems.append("index.txt: unknown kind '\(kind)'")
            }
        }

        // No file here that the index does not name.
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.count
        if onDisk != reading.named {
            reading.problems.append(
                "test/project-format has \(onDisk) .json file(s) and index.txt names \(reading.named)")
        }
        return reading
    }
}

@Suite
struct SharedProjectFilesTests {
    private typealias Writing = ProjectFileWriting

    @Test func everySharedFileIsReadAndWrittenBackAsTheSameBytes() throws {
        let reading = try SharedProjectFiles.read(SharedProjectFiles.directory)
        #expect(reading.problems.isEmpty, "\n\(reading.problems.joined(separator: "\n"))")
        // A reader that found nothing passed every row it found.
        #expect(reading.rows >= 15, "index.txt has \(reading.rows) rows; there were 15 when this was written")
    }

    /// The rules for a string and a number, said here as well as in the
    /// shared files so that a failure names the rule.
    @Test func aStringAndANumberAreWrittenOneWay() throws {
        var s = ""
        Writing.string("a/b \"q\" \\ \t\n\u{1}\u{1f}\u{7f} 写 🧪 \u{2028}", into: &s)
        #expect(s == "\"a/b \\\"q\\\" \\\\ \\u0009\\u000a\\u0001\\u001f\u{7f} 写 🧪 \u{2028}\"")

        let cases: [(Double, String)] = [
            (0.62, "0.62"),
            (1.0, "1"),
            (0.0, "0"),
            (0.1 + 0.2, "0.30000000000000004"),
            (1e-7, "0.0000001"),
            (1e21, "1000000000000000000000"),
            (-1920.0, "-1920"),
            (123456789.125, "123456789.125"),
            (0.0001, "0.0001"),
            (1.5e-5, "0.000015"),
            (1e16, "10000000000000000"),
            (1234567890123456789.0, "1234567890123456800"),
        ]
        for (value, want) in cases {
            #expect(try Writing.number(value) == want)
            // And it reads back as the double it was written for.
            #expect(Double(try Writing.number(value)) == value)
        }
        for bad in [Double.nan, .infinity, -.infinity] {
            #expect(throws: ProjectFileError.notFinite) { try Writing.number(bad) }
            let leaf = ProjectNode.leaf(cwd: "", title: "", titleChosen: false, history: "", scrollback: "", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .none)
            let root = ProjectNode.split(direction: .horizontal, ratio: bad, left: leaf, right: leaf)
            #expect(throws: ProjectFileError.notFinite) {
                try ProjectFile.oneTab(name: "n", savedAt: 1, root: root, nextScrollback: nil).encoded()
            }
        }
    }

    @Test func aFormat1FileReadsAsOneWindowWithOneTabAndNobodyKnowsWhoWasInItsPanes() throws {
        let json = #"""
        {"name":"old","saved_at":7,"next_scrollback":2,"group":"not a format 1 key",
         "root":{"kind":"leaf","cwd":"/a","scrollback":"1.snap","agent":{"kind":"agent","supervisor":true}}}
        """#
        let file = try ProjectFile.decode(from: Data(json.utf8))
        // Not `.none`, and not the agent the stray key describes.
        let leaf = ProjectNode.leaf(cwd: "/a", title: "", titleChosen: false, history: "", scrollback: "1.snap", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .unknown)
        #expect(file == ProjectFile(
            name: "old", savedAt: 7, group: nil,
            windows: [ProjectWindow(frame: nil, front: 0, tabs: [ProjectTab(root: leaf, title: "")])],
            nextScrollback: 2))
        #expect(try ProjectFile.format(of: Data(json.utf8)) == 1)

        // No `root` is a project with nothing in it, not a damaged one.
        let blank = try ProjectFile.decode(from: Data(#"{"name":"blank","saved_at":1}"#.utf8))
        #expect(blank.windows.isEmpty)
        #expect(blank.firstTab == nil)
    }

    @Test func aFileFromALaterFormatIsRefusedAsTooNewAndIsNeverReadAsFormat1() throws {
        // It has everything a format 1 file has. Read as one, it is a
        // project of one pane, and the next save writes that over whatever
        // it was.
        let later = Data(#"{"format":4,"name":"later","saved_at":1,"root":{"kind":"leaf","cwd":"/a"}}"#.utf8)
        #expect(throws: ProjectFileError.tooNew(found: 4)) { try ProjectFile.decode(from: later) }
        #expect(throws: ProjectFileError.tooNew(found: 4)) { try ProjectFile.format(of: later) }
        #expect("\(ProjectFileError.tooNew(found: 4))".contains("format 4"))
        #expect("\(ProjectFileError.tooNew(found: 4))".contains("reads up to format 3"))

        // A `format` that is not a version at all is a damaged file -- and
        // not a too-new one.
        for bad in ["0", "-1", "\"2\"", "null", "true", "[2]"] {
            let data = Data("{\"format\":\(bad),\"name\":\"n\",\"saved_at\":1,\"windows\":[]}".utf8)
            do {
                let file = try ProjectFile.decode(from: data)
                Issue.record("format \(bad) read as \(file)")
            } catch is ProjectFileError {
                Issue.record("format \(bad) was called too new")
            } catch {}
        }

        // And `format: 1` said out loud is format 1.
        let one = try ProjectFile.decode(from: Data(#"{"format":1,"name":"n","saved_at":1,"root":{"kind":"leaf"}}"#.utf8))
        #expect(one.windows.count == 1)
    }

    @Test func aFormat2FileThatLacksWhatFormat2AlwaysWritesIsRefused() throws {
        let leaf = #"{"kind":"leaf","agent":{"kind":"none"}}"#
        let cases: [(String, String)] = [
            ("no tabs key", #"[{"front":0}]"#),
            ("a window with no tab", #"[{"front":0,"tabs":[]}]"#),
            ("no front", #"[{"tabs":[{"root":\#(leaf)}]}]"#),
            ("front past the last tab", #"[{"front":1,"tabs":[{"root":\#(leaf)}]}]"#),
            ("front below zero", #"[{"front":-1,"tabs":[{"root":\#(leaf)}]}]"#),
            ("a tab with no root", #"[{"front":0,"tabs":[{}]}]"#),
            ("a leaf that does not say who", #"[{"front":0,"tabs":[{"root":{"kind":"leaf"}}]}]"#),
            ("an agent of no kind this build names", #"[{"front":0,"tabs":[{"root":{"kind":"leaf","agent":{"kind":"robot"}}}]}]"#),
            ("an agent that does not say whether it supervises", #"[{"front":0,"tabs":[{"root":{"kind":"leaf","agent":{"kind":"agent"}}}]}]"#),
            ("an agent whose role is not text", #"[{"front":0,"tabs":[{"root":{"kind":"leaf","agent":{"kind":"agent","role":1,"supervisor":false}}}]}]"#),
            ("an agent whose role is null", #"[{"front":0,"tabs":[{"root":{"kind":"leaf","agent":{"kind":"agent","role":null,"supervisor":false}}}]}]"#),
            ("a stack of one", #"[{"front":0,"tabs":[{"root":{"kind":"stack","shown":0,"members":[\#(leaf)]}}]}]"#),
            ("a stack of none", #"[{"front":0,"tabs":[{"root":{"kind":"stack","shown":0,"members":[]}}]}]"#),
            ("a stack showing a member it has not", #"[{"front":0,"tabs":[{"root":{"kind":"stack","shown":2,"members":[\#(leaf),\#(leaf)]}}]}]"#),
            ("a stack showing a member below zero", #"[{"front":0,"tabs":[{"root":{"kind":"stack","shown":-1,"members":[\#(leaf),\#(leaf)]}}]}]"#),
            ("a stack that does not say which shows", #"[{"front":0,"tabs":[{"root":{"kind":"stack","members":[\#(leaf),\#(leaf)]}}]}]"#),
            ("a stack with no members key", #"[{"front":0,"tabs":[{"root":{"kind":"stack","shown":0}}]}]"#),
            ("a stack with a split in it", #"[{"front":0,"tabs":[{"root":{"kind":"stack","shown":0,"members":[\#(leaf),{"kind":"split","direction":"horizontal","ratio":0.5,"left":\#(leaf),"right":\#(leaf)}]}}]}]"#),
            ("a stack with a member that says it is a split", #"[{"front":0,"tabs":[{"root":{"kind":"stack","shown":0,"members":[\#(leaf),{"kind":"split","agent":{"kind":"none"}}]}}]}]"#),
            ("a stack with a stack in it", #"[{"front":0,"tabs":[{"root":{"kind":"stack","shown":0,"members":[\#(leaf),{"kind":"stack","shown":0,"members":[\#(leaf),\#(leaf)]}]}}]}]"#),
            ("a by_supervisor that is not yes or no", #"[{"front":0,"tabs":[{"root":{"kind":"leaf","by_supervisor":1,"agent":{"kind":"none"}}}]}]"#),
            ("a by_supervisor that is null", #"[{"front":0,"tabs":[{"root":{"kind":"leaf","by_supervisor":null,"agent":{"kind":"none"}}}]}]"#),
            ("a frame from no corner", #"[{"frame":{"x":0,"y":0,"width":1,"height":1},"front":0,"tabs":[{"root":\#(leaf)}]}]"#),
            ("a frame missing a side", #"[{"frame":{"origin":"top_left","x":0,"y":0,"width":1},"front":0,"tabs":[{"root":\#(leaf)}]}]"#),
            ("windows that are not a list", "{}"),
        ]
        for (what, windows) in cases {
            let data = Data("{\"format\":2,\"name\":\"n\",\"saved_at\":1,\"windows\":\(windows)}".utf8)
            #expect(throws: (any Error).self, "\(what): read without complaint") { try ProjectFile.decode(from: data) }
        }
        // No `windows` at all -- what a format 1 file looks like to a reader
        // that only checked the number.
        #expect(throws: (any Error).self) {
            try ProjectFile.decode(from: Data("{\"format\":2,\"name\":\"n\",\"saved_at\":1,\"root\":\(leaf)}".utf8))
        }
        // The control: the same shape, whole, reads.
        let whole = Data("{\"format\":2,\"name\":\"n\",\"saved_at\":1,\"windows\":[{\"front\":0,\"tabs\":[{\"root\":\(leaf)}]}]}".utf8)
        #expect(try ProjectFile.decode(from: whole).firstTab == .leaf(cwd: "", title: "", titleChosen: false, history: "", scrollback: "", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .none))
    }

    // MARK: A stack

    /// A stack is at least two panes with one of them showing -- to write
    /// as to read. One terminal in a pane is a leaf, and it is `stacked`
    /// that knows so, not the writer.
    @Test func aStackIsAtLeastTwoPanesWithOneOfThemShowing() throws {
        let a = leaf("/a", "0.snap"), b = leaf("/b", "3.snap")
        #expect(ProjectNode.stacked(shown: 0, members: []) == nil)
        #expect(ProjectNode.stacked(shown: 0, members: [a]) == a)
        #expect(ProjectNode.stacked(shown: 1, members: [a, b]) == .stack(shown: 1, members: [a, b]))
        // `shown` past the end is the last, so what is built can be written.
        #expect(ProjectNode.stacked(shown: 7, members: [a, b]) == .stack(shown: 1, members: [a, b]))

        func written(_ root: ProjectNode) throws -> Data {
            try ProjectFile.oneTab(name: "n", savedAt: 1, root: root, nextScrollback: nil).encoded()
        }
        let split = ProjectNode.split(direction: .horizontal, ratio: 0.5, left: a, right: b)
        for bad in [
            ProjectNode.stack(shown: 0, members: [a]),
            .stack(shown: 0, members: []),
            .stack(shown: 2, members: [a, b]),
            .stack(shown: -1, members: [a, b]),
            .stack(shown: 0, members: [a, split]),
            .stack(shown: 0, members: [a, .stack(shown: 0, members: [a, b])]),
        ] {
            #expect(throws: ProjectFileError.badStack) { try written(bad) }
        }
        // A good one comes back as it went.
        let good = ProjectNode.split(direction: .vertical, ratio: 0.5, left: .stack(shown: 1, members: [a, b]), right: leaf("/c"))
        #expect(try ProjectFile.decode(from: written(good)).firstTab == good)

        // Format 1 has no such node: a file that old with one in it is damaged.
        let old = #"{"name":"old","saved_at":1,"root":{"kind":"stack","shown":0,"members":[{"kind":"leaf","cwd":"/a"},{"kind":"leaf","cwd":"/b"}]}}"#
        #expect(throws: (any Error).self) { try ProjectFile.decode(from: Data(old.utf8)) }
    }

    /// Its members are panes like any other: counted, named and walked in
    /// their order -- and to the layout the whole stack is one pane.
    @Test func theMembersOfAStackArePanesLikeAnyOther() {
        let a = leaf("/a", "0.snap"), b = leaf("/b", "3.snap")
        let root = ProjectNode.split(direction: .horizontal, ratio: 0.5, left: .stack(shown: 1, members: [a, b]), right: leaf("/c", "1.snap"))
        #expect(root.leafCount == 3)
        #expect(root.scrollbackFilenames == ["0.snap", "3.snap", "1.snap"])
        #expect(root.layout == .split(.horizontal, .pane, .pane))
        // Who is in front, and how many there are, is not layout.
        let other = ProjectNode.split(direction: .horizontal, ratio: 0.5, left: .stack(shown: 0, members: [a, b, leaf("/d")]), right: leaf("/c"))
        #expect(other.layout == root.layout)
        #expect(ProjectNode.split(direction: .horizontal, ratio: 0.5, left: a, right: leaf("/c")).layout == root.layout)
    }

    // MARK: The whole project

    private func leaf(_ cwd: String, _ scrollback: String = "") -> ProjectNode {
        .leaf(cwd: cwd, title: "", titleChosen: false, history: "", scrollback: scrollback, bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .none)
    }

    private var threeTabs: ProjectFile {
        ProjectFile(
            name: "p", savedAt: 1, group: "g",
            windows: [
                ProjectWindow(
                    frame: ProjectFrame(origin: .bottomLeft, x: 1, y: 2, width: 3, height: 4),
                    front: 1,
                    tabs: [ProjectTab(root: leaf("/first", "0.snap"), title: ""), ProjectTab(root: leaf("/second", "4.snap"), title: "")]),
                ProjectWindow(frame: nil, front: 0, tabs: [ProjectTab(root: leaf("/other window", "2.snap"), title: "")]),
            ],
            nextScrollback: 5)
    }

    /// Every snapshot of a project is in one directory, so what a save
    /// counts as taken -- and must not prune -- is every name in every tab.
    @Test func theSnapshotNamesOfAProjectAreThoseOfEveryTabAndWindow() {
        #expect(threeTabs.scrollbackFilenames == ["0.snap", "4.snap", "2.snap"])
        // And a number handed out for a new pane is past all of them,
        // whichever tab it is in.
        var allocator = ProjectScrollback.Allocator(project: "p", storedNext: nil, inUse: threeTabs.scrollbackFilenames)
        #expect(allocator.snapshot(for: nil, allocate: true)?.filename == "5.snap")
    }

    /// The name and the time change; the windows, the group and the counter
    /// go with the project.
    @Test func aProjectUnderAnotherNameKeepsEverythingElse() {
        let was = threeTabs
        let now = was.with(name: "q", savedAt: 9)
        #expect(now.name == "q")
        #expect(now.savedAt == 9)
        #expect(now.windows == was.windows)
        #expect(now.group == was.group)
        #expect(now.nextScrollback == was.nextScrollback)
    }
}
