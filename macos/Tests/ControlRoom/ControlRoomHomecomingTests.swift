import Foundation
import Testing
@testable import Ghostty

/// The keyboard in a terminal's own tab after the control room gives the
/// terminal back (`ControlRoomHomecoming`), and the search bar that moves
/// with it (`ControlRoomMovedSearches`).
struct ControlRoomHomecomingTests {
    typealias Homecoming = ControlRoomHomecoming
    typealias Home = ControlRoomHomecoming.Home

    /// Its own tab with the view back in it, nothing holding the keyboard,
    /// and the tab still counting it as the pane that has it.
    private let arrived = Home(attached: true, isFocusedPane: true, keyboardIsUnclaimed: true)
    /// The same tab before its pane has drawn again.
    private let notYet = Home(attached: false, isFocusedPane: true, keyboardIsUnclaimed: true)

    // MARK: The keyboard goes back when the view has arrived, not before

    @Test func aTerminalGivenBackBehindAnotherTabGetsTheKeyboardWhenItsViewArrives() {
        // What was wrong: the one attempt was made a moment after the
        // return, before the pane had drawn, and nothing tried again.
        var home = Homecoming()
        home.returned("a1", wanted: false)

        let got1 = home.settle("a1", home: notYet)
        #expect(got1 == [])
        let got2 = home.settle("a1", home: notYet)
        #expect(got2 == [])
        let got3 = home.settle("a1", home: arrived)
        #expect(got3 == [.takeKeyboard])
    }

    @Test func itIsHandedTheKeyboardOncePerReturn() {
        var home = Homecoming()
        home.returned("a1", wanted: false)
        let got4 = home.settle("a1", home: arrived)
        #expect(got4 == [.takeKeyboard])
        // The window becoming key afterwards, the view moving again: the
        // person may have put the keyboard elsewhere since.
        let got5 = home.settle("a1", home: arrived)
        #expect(got5 == [])
        #expect(home.awaited.isEmpty)
    }

    @Test func aTerminalNobodyGaveBackIsLeftAlone() {
        var home = Homecoming()
        let got6 = home.settle("a1", home: arrived)
        #expect(got6 == [])
        home.returned("a2", wanted: false)
        let got7 = home.settle("a1", home: arrived)
        #expect(got7 == [])
        #expect(home.awaited == ["a2": false])
    }

    @Test func itDoesNotTakeTheKeyboardFromAnotherPane() {
        var taken = Homecoming()
        taken.returned("a1", wanted: false)
        // Another pane of its tab has the keyboard.
        let other = Home(attached: true, isFocusedPane: true, keyboardIsUnclaimed: false)
        let got8 = taken.settle("a1", home: other)
        #expect(got8 == [])

        var moved = Homecoming()
        moved.returned("a1", wanted: false)
        // Its tab counts another pane as the focused one.
        let elsewhere = Home(attached: true, isFocusedPane: false, keyboardIsUnclaimed: true)
        let got9 = moved.settle("a1", home: elsewhere)
        #expect(got9 == [])
    }

    @Test func askedForBackItGetsTheKeyboardAndItsWindowComesForward() {
        var home = Homecoming()
        home.returned("a1", wanted: true)
        let got10 = home.settle("a1", home: notYet)
        #expect(got10 == [])
        // Whatever its tab thought was focused: the person pressed for it.
        let elsewhere = Home(attached: true, isFocusedPane: false, keyboardIsUnclaimed: false)
        let got11 = home.settle("a1", home: elsewhere)
        #expect(got11 == [.makeKey, .takeKeyboard])
    }

    @Test func borrowedAgainBeforeItArrivedItIsNotComingHome() {
        var home = Homecoming()
        home.returned("a1", wanted: false)
        home.cancelled("a1")
        let got12 = home.settle("a1", home: arrived)
        #expect(got12 == [])
    }

    @Test func twoTerminalsOnTheirWayHomeAreBothRemembered() {
        // Switching groups quickly: the second is given back before the
        // first one's tab has drawn.
        var home = Homecoming()
        home.returned("a1", wanted: false)
        home.returned("a2", wanted: false)
        let got13 = home.settle("a2", home: arrived)
        #expect(got13 == [.takeKeyboard])
        let got14 = home.settle("a1", home: arrived)
        #expect(got14 == [.takeKeyboard])
    }

    // MARK: Its own window stays where it is while it is lent

    @Test func somethingDoneToALentTerminalDoesNotBringItsOwnWindowForward() {
        #expect(!Homecoming.homeComesForward(lent: true))
        #expect(Homecoming.homeComesForward(lent: false))
    }

    // MARK: The search bar

    private final class Search {}

    @Test func aSearchBarThatOnlyMovedDoesNotTakeTheKeyboard() {
        var moves = ControlRoomMovedSearches<Search>()
        let search = Search()

        // Opened by the person: it takes the keyboard.
        let got15 = moves.mayTakeKeyboard(search)
        #expect(got15)

        // Its terminal goes into the control room, then back.
        moves.moved(search)
        let got16 = moves.mayTakeKeyboard(search)
        #expect(!got16)
        moves.moved(search)
        let got17 = moves.mayTakeKeyboard(search)
        #expect(!got17)

        // Appearing again for another reason, it behaves as it always did.
        let got18 = moves.mayTakeKeyboard(search)
        #expect(got18)
    }

    @Test func aSearchOpenedAfterTheMoveIsNotHeldBack() {
        var moves = ControlRoomMovedSearches<Search>()
        var old: Search? = Search()
        moves.moved(old!)
        // That search is closed before its bar was ever drawn again.
        old = nil
        let fresh = Search()
        let got19 = moves.mayTakeKeyboard(fresh)
        #expect(got19)
    }

    @Test func movedTwiceBeforeItWasDrawnItIsHeldBackOnce() {
        var moves = ControlRoomMovedSearches<Search>()
        let search = Search()
        let other = Search()
        moves.moved(search)
        moves.moved(search)
        let got20 = moves.mayTakeKeyboard(other)
        #expect(got20)
        let got21 = moves.mayTakeKeyboard(search)
        #expect(!got21)
        let got22 = moves.mayTakeKeyboard(search)
        #expect(got22)
    }
}
