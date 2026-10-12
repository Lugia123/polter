import CoreGraphics
import Foundation
import Testing
@testable import Ghostty

/// The control room coming back after a restart into the group of tabs it
/// was in (`ControlRoomRules.groupToRejoin`), and the pane that keeps its
/// window's keyboard when a lent terminal's tab is rearranged.
struct ControlRoomRestartTests {
    private let main = CGRect(x: 60, y: 80, width: 1400, height: 860)
    private let other = CGRect(x: 940, y: 250, width: 840, height: 800)

    @Test func itGoesBackIntoTheGroupRestoredToItsFrame() {
        // What a real restart did: three terminal tabs in one frame, and
        // the control room alone in that same frame.
        let back = ControlRoomRules.groupToRejoin(wasTabbed: true, alone: true, frame: main, groups: [other, main])
        #expect(back == 1)
    }

    @Test func withItsGroupGoneItStaysAWindowOfItsOwn() {
        let gone = ControlRoomRules.groupToRejoin(wasTabbed: true, alone: true, frame: main, groups: [other])
        #expect(gone == nil)
        let none = ControlRoomRules.groupToRejoin(wasTabbed: true, alone: true, frame: main, groups: [])
        #expect(none == nil)
    }

    @Test func aControlRoomThatWasAWindowOfItsOwnIsNotPutInAGroup() {
        // The same frame as a group of terminals, by chance.
        let own = ControlRoomRules.groupToRejoin(wasTabbed: false, alone: true, frame: main, groups: [main])
        #expect(own == nil)
        // A state written before this was kept says nothing either way.
        let old = ControlRoomRules.groupToRejoin(wasTabbed: nil, alone: true, frame: main, groups: [main])
        #expect(old == nil)
    }

    @Test func oneTheSystemAlreadyPutBackIsLeftWhereItIs() {
        let placed = ControlRoomRules.groupToRejoin(wasTabbed: true, alone: false, frame: main, groups: [main])
        #expect(placed == nil)
    }

    @Test func whatIsKeptSaysWhetherItWasATabAndInFront() throws {
        let kept = ControlRoomRules.Restorable(selection: "web-app", tabbed: true, inFront: false)
        let back = ControlRoomRules.Restorable.decode(kept.encoded())
        #expect(back == kept)
        #expect(back?.tabbed == true)
        #expect(back?.inFront == false)

        // A state from the build before: it still reads, and says nothing
        // about tabs.
        let before = Data(#"{"version":1,"selection":"billing"}"#.utf8)
        let old = ControlRoomRules.Restorable.decode(before)
        #expect(old?.selection == "billing")
        #expect(old?.tabbed == nil)
    }

    @Test func rearrangingALentTerminalsTabLeavesTheKeyboardWithThePaneThatHadIt() {
        // Another pane had that window's keyboard: it gets it back.
        #expect(ControlRoomHomecoming.focusedPaneKeepsKeyboard(focusedPaneIsLent: false))
        // The lent terminal itself had it: its keyboard is in the control room.
        #expect(!ControlRoomHomecoming.focusedPaneKeepsKeyboard(focusedPaneIsLent: true))
    }
}
