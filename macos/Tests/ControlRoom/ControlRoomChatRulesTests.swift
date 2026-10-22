import Foundation
import Testing
@testable import Ghostty

struct ChatTests {
    typealias C = ControlRoomChatRules

    /// What a real shell hands the program for the quoted argument.
    func throughShell(_ quoted: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf '%s' " + quoted]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
    }

    @Test func testAGroupNameReachesTheProgramAsOneArgumentUnchanged() throws {
        for group in ["polter", "it's mine", "a b", "$HOME", "`id`", "x'; rm -rf y; '", "群聊 1", "\\'\\"] {
            #expect(try throughShell(C.shellQuoted("--group=" + group)) == "--group=" + group)
        }
    }

    @Test func testTheCommandIsPolterChatWithTheGroup() {
        #expect(C.command(group: "polter") == "polter +chat '--group=polter' --embedded")
        #expect(C.command(group: "it's") == "polter +chat '--group=it'\\''s' --embedded")
    }

    @Test func testFourKeptTheOldestOtherThanTheFrontGoes() {
        let order = ["a", "b", "c", "d"]
        #expect(C.overKept(order, front: "d") == [])
        #expect(C.overKept(order + ["e"], front: "e") == ["a"])
        // The one in front is never the one that goes, however old.
        #expect(C.overKept(order + ["e"], front: "a") == ["b"])
        #expect(C.overKept(order + ["e", "f"], front: "f") == ["a", "b"])
        #expect(same(C.kept, 4))
    }

    @Test func testLookingAtAChatPutsItLast() {
        #expect(C.lookedAt("b", in: ["a", "b", "c"]) == ["a", "c", "b"])
        #expect(C.lookedAt("c", in: ["a", "b", "c"]) == ["a", "b", "c"])
        // One not there yet is made by the caller and appended there.
        #expect(C.lookedAt("z", in: ["a"]) == ["a"])
        // Looked at in turn: a, b, c, a -- then b is the oldest.
        var order: [String] = []
        for g in ["a", "b", "c"] { order.append(g) }
        order = C.lookedAt("a", in: order)
        #expect(C.overKept(order + ["d", "e"], front: "e") == ["b"])
    }
}

struct RequestTests {
    @Test func testAGroupNameIsAJSONStringThatReadsBackUnchanged() throws {
        for group in ["polter", "say \"hi\"", "a\\b", "line\nbreak\ttab\r", "\u{1}\u{1f}", "群聊 1", "emoji 🫠"] {
            let q = ControlRoomPageRequest.quoted(group)
            let back = try JSONSerialization.jsonObject(with: Data("[\(q)]".utf8)) as? [String]
            #expect(back == [group])
        }
        #expect(ControlRoomResources.request(group: "a\"b", span: .day, since: 0) == "{\"page\":\"resources\",\"group\":\"a\\\"b\",\"span\":\"day\",\"since\":0}")
    }
}

/// Both sides one type, so that a literal takes the other side's -- what
/// XCTAssertEqual's one generic parameter did.
private func same<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
