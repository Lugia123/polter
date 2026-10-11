import AppKit
import Foundation
import Testing
@testable import Ghostty

/// The control room as a tab: one in the application, where a new one goes,
/// what closing it involves, what survives a restart, and that its list is
/// fetched only when the source says it changed.
struct ControlRoomRulesTests {
    typealias Rules = ControlRoomRules

    // MARK: One in the application

    @Test func whileItIsOpenATriggerOnlyEverSelectsIt() {
        // Whatever the window in front is like: no second control room.
        let withTabs = Rules.trigger(isOpen: true, parentTakesTabs: true)
        #expect(withTabs == .select)
        let withoutTabs = Rules.trigger(isOpen: true, parentTakesTabs: false)
        #expect(withoutTabs == .select)
        let noWindow = Rules.trigger(isOpen: true, parentTakesTabs: nil)
        #expect(noWindow == .select)
    }

    @Test func closedItOpensAsATabWhereThereIsATerminalWindowThatTakesTabs() {
        let made = Rules.trigger(isOpen: false, parentTakesTabs: true)
        #expect(made == .openAsFirstTab)
    }

    @Test func closedWithNowhereToPutATabItOpensInItsOwnWindow() {
        // A titlebar style with no tabs, and no terminal window at all.
        let noTabs = Rules.trigger(isOpen: false, parentTakesTabs: false)
        #expect(noTabs == .openInOwnWindow)
        let noWindow = Rules.trigger(isOpen: false, parentTakesTabs: nil)
        #expect(noWindow == .openInOwnWindow)
    }

    // MARK: Closing

    @Test func closingItsTabNeverAsks() {
        let step = Rules.closeTab()
        #expect(step == .close)
    }

    @Test func closingTheWindowFromItIsTheTerminalTabsToAgreeTo() {
        let beside = Rules.closeWindow(terminalTabsBeside: 2)
        #expect(beside == .askATerminalTab)
        let one = Rules.closeWindow(terminalTabsBeside: 1)
        #expect(one == .askATerminalTab)
        let alone = Rules.closeWindow(terminalTabsBeside: 0)
        #expect(alone == .close)
    }

    @Test func aCloseOfOneTabClosesOnlyThisOne() {
        for first in [true, false] {
            let step = Rules.closeRequest(wholeWindow: false, isFirstTab: first, terminalTabsBeside: 3)
            #expect(step == .closeSelf)
        }
    }

    @Test func whenTheWindowGoesAndThisIsTheFirstTabItIsTheOneThatActs() {
        // Only the first tab acts on "the window". The control room opens
        // first, so if it left this to someone else the window would stay.
        let withTerminals = Rules.closeRequest(wholeWindow: true, isFirstTab: true, terminalTabsBeside: 2)
        #expect(withTerminals == .askATerminalTab)
        let alone = Rules.closeRequest(wholeWindow: true, isFirstTab: true, terminalTabsBeside: 0)
        #expect(alone == .closeSelf)
    }

    @Test func whenTheWindowGoesAndAnotherTabIsFirstThatTabAnswersForIt() {
        let step = Rules.closeRequest(wholeWindow: true, isFirstTab: false, terminalTabsBeside: 2)
        #expect(step == .leaveItToTheFirstTab)
    }

    // MARK: Going to a tab by number

    private let command: UInt = 1 << 20
    private var bound: [Rules.Chord?] {
        (1...9).map { Rules.Chord(key: "\($0)", modifiers: command) }
    }

    @Test func theNumberWrittenOnATabGoesToThatTab() {
        let second = Rules.tabIndex(for: .init(key: "2", modifiers: command), shortcuts: bound, tabCount: 4)
        #expect(second == 1)
        let first = Rules.tabIndex(for: .init(key: "1", modifiers: command), shortcuts: bound, tabCount: 4)
        #expect(first == 0)
    }

    @Test func aNumberPastTheLastTabGoesToTheLast() {
        let ninth = Rules.tabIndex(for: .init(key: "9", modifiers: command), shortcuts: bound, tabCount: 3)
        #expect(ninth == 2)
    }

    @Test func aKeyThatIsNotOneOfThoseShortcutsIsLeftAlone() {
        let bare = Rules.tabIndex(for: .init(key: "2", modifiers: 0), shortcuts: bound, tabCount: 4)
        #expect(bare == nil)
        let other = Rules.tabIndex(for: .init(key: "t", modifiers: command), shortcuts: bound, tabCount: 4)
        #expect(other == nil)
        let more = Rules.tabIndex(for: .init(key: "2", modifiers: command | 1 << 17), shortcuts: bound, tabCount: 4)
        #expect(more == nil)
    }

    @Test func anUnboundNumberIsSkippedAndTheOthersKeepTheirPlaces() {
        var some = bound
        some[1] = nil
        let second = Rules.tabIndex(for: .init(key: "2", modifiers: command), shortcuts: some, tabCount: 4)
        #expect(second == nil)
        let third = Rules.tabIndex(for: .init(key: "3", modifiers: command), shortcuts: some, tabCount: 4)
        #expect(third == 2)
        let noTabs = Rules.tabIndex(for: .init(key: "1", modifiers: command), shortcuts: bound, tabCount: 0)
        #expect(noTabs == nil)
    }

    // MARK: Across a restart

    @Test func whatIsKeptComesBackAsItWas() {
        let kept = Rules.Restorable(selection: "billing")
        let back = Rules.Restorable.decode(kept.encoded())
        #expect(back == kept)
        #expect(back?.selection == "billing")

        let none = Rules.Restorable(selection: nil)
        let backNone = Rules.Restorable.decode(none.encoded())
        #expect(backNone == none)
        #expect(backNone?.selection == nil)
    }

    @Test func aStateThisBuildDidNotWriteIsNoState() {
        let missing = Rules.Restorable.decode(nil)
        #expect(missing == nil)
        let garbage = Rules.Restorable.decode(Data("not json".utf8))
        #expect(garbage == nil)
        let later = Rules.Restorable.decode(Data(#"{"version": 2, "selection": "billing"}"#.utf8))
        #expect(later == nil)
        let current = Rules.Restorable.decode(Data(#"{"version": 1, "selection": "billing"}"#.utf8))
        #expect(current?.selection == "billing")
    }

    @Test func aKeptSelectionIsUsedOnlyIfThatGroupIsStillListed() {
        let rows = ControlRoomList.sample.rows
        let still = Rules.restoredSelection("billing", in: rows)
        #expect(still == "billing")
        let gone = Rules.restoredSelection("closed-last-night", in: rows)
        #expect(gone == nil)
        let none = Rules.restoredSelection(nil, in: rows)
        #expect(none == nil)
    }

    // MARK: The list is fetched when the source says so, and only then

    private final class CountingSource: ControlRoomSnapshotSource {
        var onChange: (() -> Void)?
        var fetches = 0
        var waiting = 3

        var nothingYet = false

        func snapshot() -> ControlRoomList? {
            fetches += 1
            if nothingYet { return nil }
            var list = ControlRoomList.sample
            list.waitingCount = waiting
            return list
        }
    }

    @Test func theListIsTakenOnceAtTheStartAndOncePerNotice() {
        let source = CountingSource()
        let model = ControlRoomModel(source: source)
        #expect(source.fetches == 1)
        #expect(model.list?.waitingCount == 3)

        source.waiting = 5
        // Changed, and nobody was told: the model must not have looked.
        #expect(source.fetches == 1)
        #expect(model.list?.waitingCount == 3)

        source.onChange?()
        #expect(source.fetches == 2)
        #expect(model.list?.waitingCount == 5)

        source.onChange?()
        source.onChange?()
        #expect(source.fetches == 4)
    }

    @Test @MainActor func nothingFetchesWhileNothingIsSaid() {
        // Half a second with the run loop turning, which is what a timer
        // needs in order to fire. (Sleeping instead proves nothing: with no
        // run loop running, a timer in the model would never fire either,
        // and the count would stay 1 for the wrong reason.)
        let source = CountingSource()
        let model = ControlRoomModel(source: source)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        #expect(source.fetches == 1)
        #expect(model.selection == nil)
    }

    @Test func noSnapshotYetIsNoListAndNotAnEmptyOne() {
        let source = CountingSource()
        source.nothingYet = true
        let model = ControlRoomModel(source: source, selection: "billing")
        #expect(model.list == nil)
        // The selection kept from last time waits for a list to check it against.
        #expect(model.selection == "billing")

        source.nothingYet = false
        source.onChange?()
        #expect(model.list?.waitingCount == 3)
        #expect(model.selection == "billing")
    }

    @Test func aNoticeWithNothingReadableBehindItKeepsWhatIsShown() {
        let source = CountingSource()
        let model = ControlRoomModel(source: source)
        source.nothingYet = true
        source.onChange?()
        #expect(source.fetches == 2)
        #expect(model.list?.waitingCount == 3)
    }

    @Test func aSelectedGroupThatIsNoLongerListedIsDeselected() {
        let source = CountingSource()
        let model = ControlRoomModel(source: source, selection: "closed-last-night")
        // Not checked until a list arrives by notice...
        #expect(model.selection == "closed-last-night")
        source.onChange?()
        #expect(model.selection == nil)
    }

    // MARK: The core's snapshot, through its buffer rule

    /// A stand-in for `ghostty_app_control_snapshot`: writes when it fits,
    /// one NUL after, and always returns the real length.
    private final class FakeCore {
        var json = ""
        var calls: [Int] = []

        func fetch(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int {
            calls.append(capacity)
            let bytes = Array(json.utf8)
            if let buffer, bytes.count + 1 <= capacity {
                for (i, byte) in bytes.enumerated() { buffer[i] = CChar(bitPattern: byte) }
                buffer[bytes.count] = 0
            }
            return bytes.count
        }
    }

    private let oneGroup = """
    { "rev": 2, "now_ms": 1, "needs_me": 1, "groups_needing_me": 1, "groups_other": 0, "groups": [
      { "name": "发票-billing", "needs_me": true, "shown": "needs_you", "text": "等回答", "waited_min": 11,
        "reason": {"from": "hook_detail", "text": "「发票编号要按租户分开吗？」", "missing": null},
        "more": 0, "same_as": null } ] }
    """

    @Test func theCoresBytesComeBackWholeIncludingWhatIsNotAscii() {
        let core = FakeCore()
        core.json = oneGroup
        let data = ControlRoomCoreSource.read(core.fetch)
        #expect(data == Data(oneGroup.utf8))
        // Asked for the length, then for the bytes with room for the NUL.
        #expect(core.calls == [0, oneGroup.utf8.count + 1])
    }

    @Test func zeroBytesFromTheCoreIsNoSnapshot() {
        let core = FakeCore()
        let data = ControlRoomCoreSource.read(core.fetch)
        #expect(data == nil)
        #expect(core.calls == [0])
        let source = ControlRoomCoreSource(center: NotificationCenter(), fetch: core.fetch)
        let list = source.snapshot()
        #expect(list == nil)
    }

    @Test func aSnapshotThisBuildCannotReadIsNoSnapshotRatherThanAnEmptyList() {
        let core = FakeCore()
        core.json = #"{"rev": 1, "groups": "not a list"}"#
        let source = ControlRoomCoreSource(center: NotificationCenter(), fetch: core.fetch)
        let list = source.snapshot()
        #expect(list == nil)
    }

    @Test func theCoreSourceFetchesOnTheNoticeAndOnlyThen() {
        let center = NotificationCenter()
        let core = FakeCore()
        core.json = oneGroup
        let source = ControlRoomCoreSource(center: center, fetch: core.fetch)
        let model = ControlRoomModel(source: source)
        #expect(model.list?.waiting.first?.id == "发票-billing")
        #expect(model.list?.waiting.first?.waitedMin == 11)
        let afterStart = core.calls.count
        #expect(afterStart == 2)

        // The core's bytes change and nobody says so: nothing is fetched.
        core.json = oneGroup.replacingOccurrences(of: "\"waited_min\": 11", with: "\"waited_min\": 12")
        #expect(core.calls.count == afterStart)
        #expect(model.list?.waiting.first?.waitedMin == 11)

        center.post(name: ControlRoomCoreSource.changed, object: nil)
        #expect(core.calls.count == afterStart + 2)
        #expect(model.list?.waiting.first?.waitedMin == 12)

        // Another notification altogether is not a notice.
        center.post(name: Notification.Name("something-else"), object: nil)
        #expect(core.calls.count == afterStart + 2)
    }

    @Test func theModelStartsOnTheSelectionItIsGiven() {
        let model = ControlRoomModel(source: CountingSource(), selection: "billing")
        #expect(model.selection == "billing")
    }

    // MARK: The right-hand side holds what it is lent and gives it back

    @Test @MainActor func aPaneThatWasLentIsHandedBackAndNeverDropped() {
        let container = ControlRoomDetailContainer()
        #expect(container.hostedGroup == nil)
        let nothing = container.giveBack()
        #expect(nothing == nil)

        let first = NSView()
        let displaced = container.host(first, for: "web-app")
        #expect(displaced == nil)
        #expect(container.hostedGroup == "web-app")
        #expect(first.superview === container)

        // Lending a second one hands the first back to the caller.
        let second = NSView()
        let back = container.host(second, for: "billing")
        #expect(back === first)
        #expect(first.superview == nil)
        #expect(container.hostedGroup == "billing")
        #expect(container.subviews.count == 1)

        let last = container.giveBack()
        #expect(last === second)
        #expect(second.superview == nil)
        #expect(container.hostedGroup == nil)
        #expect(container.subviews.isEmpty)
    }
}
