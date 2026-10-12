import Foundation
import Testing
@testable import Ghostty

/// The list's two headings: what they say is the core's, down to whether
/// the rows are called groups and whether there is one of them.
struct ControlRoomHeaderTests {
    typealias Header = ControlRoomList.Header

    private static func snapshot(waiting: String?, quiet: String?, groups: Int = 1, other: Int = 0) -> Data {
        let headers = [waiting.map { #""header_waiting": \#($0),"# }, quiet.map { #""header_quiet": \#($0),"# }]
            .compactMap { $0 }.joined(separator: " ")
        return Data("""
        { "rev": 2, "now_ms": 1, "needs_me": 3, "groups_needing_me": \(groups), "groups_other": \(other),
          \(headers) "groups": [] }
        """.utf8)
    }

    @Test func theHeadingIsTheCoresCountAndNotTheGroupsWhenLoneTerminalsAreListed() throws {
        // One group waits and two terminals on their own do: the heading
        // says three, as the Dock does, and does not call them groups.
        let list = try ControlRoomList.decode(snapshot: Self.snapshot(
            waiting: #"{"count":3,"of":"rows","number":"other"}"#,
            quiet: #"{"count":1,"of":"rows","number":"one"}"#))
        #expect(list.waitingCount == 3)
        #expect(list.quietCount == 1)
        #expect(list.waitingHeader == Header(count: 3, of: .rows, number: .other))
        let said = list.waitingHeaderText
        #expect(said == ControlRoomList.headerText(Header(count: 3, of: .rows, number: .other)))
        #expect(said.contains("3"))
        #expect(!said.localizedCaseInsensitiveContains("group"))
    }

    @Test func everyFormOfTheFirstHeadingIsItsOwnSentence() {
        let none = ControlRoomList.headerText(Header(count: 0, of: .groups, number: .none))
        let oneGroup = ControlRoomList.headerText(Header(count: 1, of: .groups, number: .one))
        let groups = ControlRoomList.headerText(Header(count: 4, of: .groups, number: .other))
        let rows = ControlRoomList.headerText(Header(count: 4, of: .rows, number: .other))
        #expect(Set([none, oneGroup, groups, rows]).count == 4)
        // One group is "group", several are "groups": the core said which,
        // and it is not worked out from the count here.
        #expect(oneGroup.contains("1 group "))
        #expect(groups.contains("4 groups "))
        #expect(!none.contains("0"))
        // The number handed in is the number written, whatever it is: the
        // form is `number`'s to say.
        let odd = ControlRoomList.headerText(Header(count: 7, of: .groups, number: .one))
        #expect(odd.contains("7 group "))
    }

    @Test func theSecondHeadingFollowsTheSameRule() {
        let oneGroup = ControlRoomList.quietHeaderText(Header(count: 1, of: .groups, number: .one))
        let groups = ControlRoomList.quietHeaderText(Header(count: 3, of: .groups, number: .other))
        let oneRow = ControlRoomList.quietHeaderText(Header(count: 1, of: .rows, number: .one))
        let rows = ControlRoomList.quietHeaderText(Header(count: 3, of: .rows, number: .other))
        #expect(Set([oneGroup, groups, oneRow, rows]).count == 4)
        #expect(oneGroup.contains("1 group needs"))
        #expect(groups.contains("3 groups need "))
        #expect(!rows.localizedCaseInsensitiveContains("group"))
        #expect(!oneRow.localizedCaseInsensitiveContains("group"))
    }

    @Test func aSnapshotWithoutTheHeadingsIsWrittenFromTheGroupsAsItAlwaysWas() throws {
        let list = try ControlRoomList.decode(snapshot: Self.snapshot(waiting: nil, quiet: nil, groups: 5, other: 8))
        #expect(list.waitingHeader == nil)
        #expect(list.waitingCount == 5)
        #expect(list.quietCount == 8)
        #expect(list.waitingHeaderText == ControlRoomList.headerText(waiting: 5))
        #expect(list.quietHeaderText.contains("8"))
    }

    @Test func theCoresFixtureSaysSixWaitingAndThreeGroupsThatNeedNothing() throws {
        let list = try ControlRoomList.decode(snapshot: ControlRoomListTests.fixture())
        #expect(list.waitingHeader == Header(count: 6, of: .rows, number: .other))
        #expect(list.quietHeader == Header(count: 3, of: .groups, number: .other))
        // The heading and the rows under it are the same number.
        #expect(list.waiting.count == 6)
        #expect(list.quiet.count == 3)
    }
}
