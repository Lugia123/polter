import Foundation
import Testing
@testable import Ghostty

/// **Every key of every fixture, taken away, and then put to a kind it is
/// not** (group seq 309), as the Windows host's tests do: each answer still
/// reads -- but for `group` -- and names the key in `missing`, or the key is
/// one the host does not read. The same fixtures, the same unread keys.
struct ControlRoomEveryKeyTests {
    static let dir = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("windows/control-room/testdata")

    /// The keys the host does not read, and why (the Windows host's lists).
    static let unreadResources = [
        "raw": "the readings as numbers; the core writes every word the host draws",
        "r4": "says only that the fourth line is the curve, drawn from `points`",
        "later": "a key put in the nulls fixture for no build to know",
        "page": "the request's own word, which the answer repeats",
        "start_ms": "the axis's words are the core's; nothing is placed by time",
        "cell_ms": "likewise",
    ]
    static let unreadTasks = [
        "later": "a key put in the nulls fixture for no build to know",
        "page": "the request's own word, which the answer repeats",
    ]

    static func paths(_ v: Any, _ path: String, _ out: inout [String]) {
        if let o = v as? [String: Any] {
            for (k, x) in o {
                let p = path.isEmpty ? k : "\(path).\(k)"
                out.append(p)
                paths(x, p, &out)
            }
        } else if let a = v as? [Any] {
            for (i, x) in a.enumerated() { paths(x, "\(path)[\(i)]", &out) }
        }
    }

    static func parts(_ path: String) -> [(String, Int?)] {
        path.split(separator: ".").map { part in
            if let b = part.firstIndex(of: "[") {
                return (String(part[..<b]), Int(part[part.index(after: b)..<part.index(before: part.endIndex)]))
            }
            return (String(part), nil)
        }
    }

    static func edited(_ v: Any, _ path: String, _ with: Any?) -> Any {
        func walk(_ v: Any, _ rest: ArraySlice<(String, Int?)>) -> Any {
            guard var o = v as? [String: Any], let (name, index) = rest.first, let child = o[name] else { return v }
            if let i = index {
                guard var a = child as? [Any], i < a.count else { return v }
                a[i] = walk(a[i], rest.dropFirst())
                o[name] = a
            } else if rest.count == 1 {
                o[name] = with
            } else {
                o[name] = walk(child, rest.dropFirst())
            }
            return o
        }
        return walk(v, ArraySlice(parts(path)))
    }

    static func get(_ v: Any, _ path: String) -> Any? {
        var cur: Any? = v
        for (name, index) in parts(path) {
            cur = (cur as? [String: Any])?[name]
            if let i = index { cur = (cur as? [Any]).flatMap { i < $0.count ? $0[i] : nil } }
        }
        return cur
    }

    static func isBool(_ x: Any?) -> Bool {
        guard let n = x as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    func check(files: [String], unread: [String: String], decode: (Data) throws -> [String]) throws {
        var unsaid: [String] = []
        var checked = 0
        for file in files {
            let v = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.dir.appendingPathComponent(file)))
            // Whole, nothing is missing: what is said below is the edit's.
            #expect(try decode(JSONSerialization.data(withJSONObject: v)) == [], Comment(rawValue: file))
            var all: [String] = []
            Self.paths(v, "", &all)
            let kinds: [Any?] = [nil, true, ["x": true]]
            for path in all {
                for with in kinds {
                    let data = try JSONSerialization.data(withJSONObject: Self.edited(v, path, with))
                    if path == "group" {
                        #expect(throws: (any Error).self) { try decode(data) }
                        continue
                    }
                    let missing: [String]
                    do { missing = try decode(data) } catch {
                        Issue.record("\(path) (\(String(describing: with))): \(error)")
                        continue
                    }
                    let said = missing.contains { m in
                        path == m || path.hasPrefix(m + ".") || path.hasPrefix(m + "[") || m.hasPrefix(path + ".") || m.hasPrefix(path + "[")
                    }
                    let isUnread = Self.parts(path).contains { unread[$0.0] != nil }
                    let old = Self.get(v, path)
                    let sameKind = (with.map(Self.isBool) == true && Self.isBool(old)) || (with is [String: Any] && old is [String: Any])
                    if !(said || isUnread || sameKind) {
                        let key = Self.parts(path).map(\.0).joined(separator: ".")
                        let what = "\(key) (\(with == nil ? "taken away" : with is [String: Any] ? "an object" : "a yes/no"))"
                        if !unsaid.contains(what) { unsaid.append(what) }
                    }
                    checked += 1
                }
            }
        }
        #expect(unsaid == [], "nothing said for these")
        #expect(checked > 300)
    }

    @Test func testEveryResourcesKey() throws {
        try check(files: ["resources-day.json", "resources-week.json", "resources-nulls.json"], unread: Self.unreadResources) { try ControlRoomResources.decode($0).missing }
    }

    @Test func testEveryTasksKey() throws {
        try check(files: ["tasks-open.json", "tasks-closed.json", "tasks-nulls.json"], unread: Self.unreadTasks) { try ControlRoomTasks.decode($0).missing }
    }
}
