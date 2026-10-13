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

    @Test func theListTakesTheKeyboardOnlyWhenNobodyHasIt() {
        // A restored window is its own first responder: nobody has the keyboard.
        #expect(ControlRoomRules.listTakesKeyboard(firstResponderIsTheWindow: true) == true)
        // A terminal clicked into, or the list itself, keeps it.
        #expect(ControlRoomRules.listTakesKeyboard(firstResponderIsTheWindow: false) == false)
    }
}

/// Where a tab the core asked for goes, and which group is selected once
/// the person has made one.
struct ControlRoomNewTabTests {
    typealias Rules = ControlRoomRules

    /// Every answer to the three questions that are only about the
    /// application.
    private static let rooms: [(Bool, Bool, Bool)] = [true, false].flatMap { front in
        [true, false].flatMap { beside in [true, false].map { any in (front, beside, any) } }
    }

    @Test func aTabAskedFromATerminalTheControlRoomHasBorrowedOpensInItsOwnWindowBehind() {
        // The defect: this used to open nothing at all, and say it had.
        for (front, beside, any) in Self.rooms {
            let plan = Rules.newTab(asker: (lent: true, hasHome: true), byPerson: false, controlRoomInFront: front,
                                    tabsBesideControlRoom: beside, anyTerminalWindow: any)
            #expect(plan == .behind(.askers))
        }
    }

    @Test func aTabAskedFromATerminalInItsOwnTabOpensBesideItInFrontAsItAlwaysDid() {
        for (front, beside, any) in Self.rooms {
            let plan = Rules.newTab(asker: (lent: false, hasHome: true), byPerson: false, controlRoomInFront: front,
                                    tabsBesideControlRoom: beside, anyTerminalWindow: any)
            #expect(plan == .inFront(of: .askers))
        }
    }

    @Test func aTabAskedFromATerminalNoWindowHoldsIsRefusedAndNotSilentlyDropped() {
        for lent in [true, false] {
            let plan = Rules.newTab(asker: (lent: lent, hasHome: false), byPerson: false, controlRoomInFront: true,
                                    tabsBesideControlRoom: true, anyTerminalWindow: true)
            #expect(plan == .refused)
        }
    }

    @Test func aTabAnAgentAskedForDoesNotBringTheApplicationInFrontOfAnother() {
        // The person is in another application and an agent opens itself
        // a terminal: the tab opens, and they keep the keyboard.
        let agentBehind = Rules.newTabActivates(answerWanted: true, appIsActive: false)
        #expect(!agentBehind)
        // Already in front, nothing changes for anybody.
        let agentInFront = Rules.newTabActivates(answerWanted: true, appIsActive: true)
        #expect(agentInFront)
        // A key, a menu item, the Dock's menu: theirs comes forward, as it
        // always has -- the Dock's menu is used from behind.
        let theirsBehind = Rules.newTabActivates(answerWanted: false, appIsActive: false)
        #expect(theirsBehind)
        let theirsInFront = Rules.newTabActivates(answerWanted: false, appIsActive: true)
        #expect(theirsInFront)
    }

    @Test func aTabTheApplicationAsksForGoesBesideTheControlRoomBehindItWhileThatIsInFront() {
        // The control room starting a supervisor: the person stays where
        // they are.
        let beside = Rules.newTab(asker: nil, byPerson: false, controlRoomInFront: true,
                                  tabsBesideControlRoom: true, anyTerminalWindow: true)
        #expect(beside == .behind(.controlRooms))
        // Alone in its window: the terminal window used last takes it.
        let elsewhere = Rules.newTab(asker: nil, byPerson: false, controlRoomInFront: true,
                                     tabsBesideControlRoom: false, anyTerminalWindow: true)
        #expect(elsewhere == .inFront(of: .frontmost))
        // Not in front: an ordinary new tab.
        let ordinary = Rules.newTab(asker: nil, byPerson: false, controlRoomInFront: false,
                                    tabsBesideControlRoom: true, anyTerminalWindow: true)
        #expect(ordinary == .inFront(of: .frontmost))
    }

    @Test func aTabAskedForFromAControlRoomThatIsTheOnlyWindowBecomesATabOfItBehind() {
        // The defect (the user, 2026-10-13): starting a supervisor from a
        // control room with no terminal window anywhere opened a second
        // window.
        let alone = Rules.newTab(asker: nil, byPerson: false, controlRoomInFront: true,
                                 tabsBesideControlRoom: false, anyTerminalWindow: false)
        #expect(alone == .behind(.controlRooms))
        // Not where the person is, and nothing to put a tab in: a window
        // of its own, as before.
        let nowhere = Rules.newTab(asker: nil, byPerson: false, controlRoomInFront: false,
                                   tabsBesideControlRoom: false, anyTerminalWindow: false)
        #expect(nowhere == .ownWindow)
    }

    @Test func aTabThePersonAsksForOnTheControlRoomComesInFrontInItsWindow() {
        // New Tab pressed on the control room: the person is going there.
        // Behind is for a tab the application asked for.
        for (beside, any) in [(true, true), (false, false)] {
            let theirs = Rules.newTab(asker: nil, byPerson: true, controlRoomInFront: true,
                                      tabsBesideControlRoom: beside, anyTerminalWindow: any)
            #expect(theirs == .inFront(of: .controlRooms))
            let apps = Rules.newTab(asker: nil, byPerson: false, controlRoomInFront: true,
                                    tabsBesideControlRoom: beside, anyTerminalWindow: any)
            #expect(apps == .behind(.controlRooms))
        }
        // Who asked changes nothing anywhere else.
        for (front, beside, any) in Self.rooms where !(front && (beside || !any)) {
            let theirs = Rules.newTab(asker: nil, byPerson: true, controlRoomInFront: front,
                                      tabsBesideControlRoom: beside, anyTerminalWindow: any)
            let apps = Rules.newTab(asker: nil, byPerson: false, controlRoomInFront: front,
                                    tabsBesideControlRoom: beside, anyTerminalWindow: any)
            #expect(theirs == apps)
        }
    }

    @Test func aGroupThePersonMadeIsSelectedOnlyOnceTheCoreListsIt() {
        let rows = ControlRoomList.sample.rows
        #expect(Rules.madeGroupToSelect("billing", in: rows) == "billing")
        // Not listed yet: the list on screen is from before it existed.
        #expect(Rules.madeGroupToSelect("brand-new", in: rows) == nil)
        #expect(Rules.madeGroupToSelect(nil, in: rows) == nil)
    }
}

/// A new tab asked of a terminal whose window may not take one: who is told.
struct ControlRoomNewTabAnswerTests {
    typealias Rules = ControlRoomRules

    @Test func anOrdinaryTerminalWindowWithATitleBarOpensItWhoeverAsked() {
        for lent in [true, false] {
            for wanted in [true, false] {
                let answer = Rules.newTabAnswer(lent: lent, homeTakesTabs: true, decorations: true, answerWanted: wanted)
                #expect(answer == .open)
            }
        }
    }

    @Test func anAgentIsToldNoAndThePersonIsShownNothing() {
        // The two that used to answer "done" with a dialog and no terminal.
        let quick = Rules.newTabAnswer(lent: false, homeTakesTabs: false, decorations: true, answerWanted: true)
        let bare = Rules.newTabAnswer(lent: false, homeTakesTabs: true, decorations: false, answerWanted: true)
        for answer in [quick, bare] {
            guard case .refuseToTheCore = answer else {
                Issue.record("an agent's request was not refused to the core: \(answer)")
                continue
            }
        }
        // And they say which it was.
        #expect(quick != bare)
    }

    @Test func aKeyPressIsStillAnsweredToThePerson() {
        let quick = Rules.newTabAnswer(lent: false, homeTakesTabs: false, decorations: true, answerWanted: false)
        #expect(quick == .tellThePerson)
        let bare = Rules.newTabAnswer(lent: false, homeTakesTabs: true, decorations: false, answerWanted: false)
        #expect(bare == .tellThePerson)
    }

    @Test func aBorrowedTerminalIsNeverAnsweredWithADialogAboutAWindowBehindTheControlRoom() {
        for wanted in [true, false] {
            let answer = Rules.newTabAnswer(lent: true, homeTakesTabs: false, decorations: true, answerWanted: wanted)
            guard case .refuseToTheCore = answer else {
                Issue.record("a borrowed terminal was answered with \(answer)")
                continue
            }
        }
    }
}
