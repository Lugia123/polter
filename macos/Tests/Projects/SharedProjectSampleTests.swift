import Testing
import Foundation
@testable import Ghostty

/// **The same file `src/Project.zig` and `windows/host/src/project.rs` check
/// against.** `test/project-format/all_fields.json` is one project with every
/// field of the format filled in. The project format has three
/// implementations and no compiler sees more than one of them, so each checks
/// itself against this sample: every key in it survives that implementation's
/// read-then-write, and that implementation has no field the sample lacks.
///
/// Adding a field to the format: add it to the sample first; the check in
/// each implementation that has not caught up then fails and names the key.
enum SharedProjectSample {
    /// Where the sample lives, found from this file's own path -- the tests
    /// only ever run from a checkout.
    static var url: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Projects
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // the repository
            .appendingPathComponent("test/project-format/all_fields.json")
    }

    /// One line per disagreement, each naming the file to change. Empty when
    /// this implementation and the sample agree.
    static func problems(sampleAt url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        let sample = try JSONSerialization.jsonObject(with: data)
        let written = try JSONSerialization.jsonObject(with: try ProjectFile.decode(from: data).encoded())

        // What this build writes with every field it has filled in. Adding an
        // associated value to `.leaf` or `.split`, or a stored property to
        // `ProjectFile`, is a compile error here until it is given a value.
        let ownLeaf = ProjectNode.leaf(cwd: "c", title: "t", history: "h", scrollback: "5.snap")
        let ownSplit = ProjectNode.split(direction: .horizontal, ratio: 0.5, left: ownLeaf, right: ownLeaf)
        let ownFile = ProjectFile(name: "n", savedAt: 1, root: ownSplit, nextScrollback: 9)
        let own = try JSONSerialization.jsonObject(with: try ownFile.encoded())

        var problems: [String] = []
        let want = keySets(sample), got = keySets(written), mine = keySets(own)
        for what in ["snapshot", "leaf", "split"] {
            let w = want[what] ?? [], g = got[what] ?? [], m = mine[what] ?? []
            for key in w.subtracting(g).sorted() {
                problems.append(
                    "macos/Sources/Features/Projects/ProjectDocument.swift loses \(what).\(key): it is in "
                        + "test/project-format/all_fields.json but does not come back out of decode + encode "
                        + "-- carry it in ProjectFile/ProjectNode, CodingKeys, init(from:) and encode(to:)")
            }
            for key in g.union(m).subtracting(w).sorted() {
                problems.append(
                    "macos/Sources/Features/Projects/ProjectDocument.swift writes \(what).\(key), which "
                        + "test/project-format/all_fields.json does not have -- add it there, then to "
                        + "src/Project.zig and windows/host/src/project.rs, whose tests read the same file")
            }
        }

        // The case the key comparison cannot see: a value this build has
        // that `encode(to:)` never writes and the sample does not have
        // either. The payload's labels are the JSON keys today.
        for (node, what) in [(ownLeaf, "leaf"), (ownSplit, "split")] {
            for label in payloadLabels(node) where !(mine[what] ?? []).contains(label) {
                problems.append(
                    "ProjectNode.\(what) has `\(label)` but encode(to:) in "
                        + "macos/Sources/Features/Projects/ProjectDocument.swift does not write \(what).\(label)")
            }
        }
        let stored = Mirror(reflecting: ownFile).children.count
        let topKeys = (mine["snapshot"] ?? []).count
        if stored != topKeys {
            problems.append(
                "ProjectFile has \(stored) stored properties but encodes \(topKeys) top-level keys "
                    + "-- one of them is not in CodingKeys in macos/Sources/Features/Projects/ProjectDocument.swift")
        }

        // Same keys is not same values: an encoder that swapped `cwd` and
        // `title` passes everything above.
        if problems.isEmpty, !(sample as AnyObject).isEqual(written) {
            problems.append(
                "macos/Sources/Features/Projects/ProjectDocument.swift read + wrote the shared sample back as "
                    + (String(data: try ProjectFile.decode(from: data).encoded(), encoding: .utf8) ?? "?"))
        }
        return problems
    }

    /// The keys found on each kind of object in a project file, `kind`
    /// itself left out -- it is the discriminator, not a field.
    static func keySets(_ file: Any) -> [String: Set<String>] {
        var sets: [String: Set<String>] = ["snapshot": [], "leaf": [], "split": []]
        func walk(_ node: Any?) {
            guard let obj = node as? [String: Any], let kind = obj["kind"] as? String else { return }
            sets[kind, default: []].formUnion(obj.keys.filter { $0 != "kind" })
            if kind == "split" {
                walk(obj["left"])
                walk(obj["right"])
            }
        }
        guard let top = file as? [String: Any] else { return sets }
        sets["snapshot"] = Set(top.keys)
        walk(top["root"])
        return sets
    }

    /// The labels of an enum case's associated values, e.g. `cwd`, `title`,
    /// `history` for `.leaf`.
    static func payloadLabels(_ node: ProjectNode) -> [String] {
        guard let payload = Mirror(reflecting: node).children.first?.value else { return [] }
        return Mirror(reflecting: payload).children.compactMap(\.label)
    }
}

@Suite
struct SharedProjectSampleTests {
    @Test func sharedSampleSurvivesThisBuildAndThisBuildWritesNothingItLacks() throws {
        let problems = try SharedProjectSample.problems(sampleAt: SharedProjectSample.url)
        #expect(problems.isEmpty, "\n\(problems.joined(separator: "\n"))")
    }
}
