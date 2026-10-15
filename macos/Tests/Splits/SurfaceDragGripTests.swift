import Testing
import Foundation
@testable import Ghostty

/// Where a pane is picked up (task 1508): by its title when it has one, by
/// the handle when it has none, and `drag-handle` decides whether at all.
struct SurfaceDragGripTests {
    private typealias Grip = SurfaceDragGrip

    private func place(
        _ setting: Grip.Setting, titled: Bool = false, lent: Bool = false, controlRoom: Bool = false, split: Bool
    ) -> Grip.Place {
        Grip.place(setting: setting, titled: titled, lent: lent, controlRoom: controlRoom, split: split)
    }

    // MARK: - Title or handle

    @Test func aTitledPaneIsPickedUpByItsTitle() {
        #expect(place(.auto, titled: true, split: true) == .title)
    }

    @Test func aPaneWithNoTitleKeepsTheHandle() {
        #expect(place(.auto, split: true) == .handle)
    }

    @Test func aStackedPaneHasNoHandleAndIsPickedUpByItsTabs() {
        // Task 1582: the `⋯` over a stacked terminal is gone; its tabs are
        // where it is picked up, as a title is.
        #expect(Grip.place(setting: .auto, titled: false, lent: false, controlRoom: false, split: true, stacked: true) == .title)
        #expect(Grip.place(setting: .always, titled: false, lent: false, controlRoom: false, split: false, stacked: true) == .title)
        #expect(Grip.place(setting: .never, titled: false, lent: false, controlRoom: false, split: true, stacked: true) == .none)
    }

    @Test func aStackTabDragsUnlessDraggingIsOffAndIsAlwaysAClickWhenItCannot() {
        // In a tab of one pane too: a member dragged out of its stack has
        // somewhere to go.
        #expect(Grip.stackTabGrip(setting: .auto, lent: false, controlRoom: false) == .drag)
        #expect(Grip.stackTabGrip(setting: .always, lent: false, controlRoom: false) == .drag)
        #expect(Grip.stackTabGrip(setting: .never, lent: false, controlRoom: false) == .click)
        #expect(Grip.stackTabGrip(setting: .auto, lent: false, controlRoom: true) == .click)
        #expect(Grip.stackTabGrip(setting: .auto, lent: true, controlRoom: false) == .none)
    }

    // MARK: - A tab of one pane (task 1566)

    @Test func autoAloneInItsTabHasNoHandle() {
        // Fullscreen or not, and a stack alone in its tab too: the pane
        // has no title then, and is no split. It moves by its tab.
        #expect(place(.auto, split: false) == .none)
    }

    @Test func autoAloneInItsTabCannotBePickedUpByTheTitle() {
        // A supervisor or a worker wears its frame even alone.
        #expect(place(.auto, titled: true, split: false) == .none)
    }

    @Test func alwaysKeepsTheHandleAloneInItsTab() {
        #expect(place(.always, split: false) == .handle)
    }

    @Test func alwaysDragsByTheTitleAloneInItsTab() {
        #expect(place(.always, titled: true, split: false) == .title)
    }

    @Test func neverAloneInItsTabIsNothing() {
        #expect(place(.never, split: false) == .none)
        #expect(place(.never, titled: true, split: false) == .none)
    }

    // MARK: - What a title does (task 1514)

    @Test func neverStillLetsTheTitleBeClicked() {
        let grip = Grip.titleGrip(setting: .never, lent: false, split: true)
        #expect(grip == .click)
    }

    @Test func autoAloneStillLetsTheTitleBeClicked() {
        let grip = Grip.titleGrip(setting: .auto, lent: false, split: false)
        #expect(grip == .click)
    }

    @Test func aTitleThatDragsIsAlsoClicked() {
        let auto = Grip.titleGrip(setting: .auto, lent: false, split: true)
        let always = Grip.titleGrip(setting: .always, lent: false, split: false)
        #expect(auto == .drag)
        #expect(always == .drag)
    }

    @Test func aLentPanesTitleTakesNoClickWhateverTheSetting() {
        for setting in [Grip.Setting.always, .auto, .never] {
            let grip = Grip.titleGrip(setting: setting, lent: true, split: true)
            #expect(grip == .none)
        }
    }

    // MARK: - drag-handle in a split: as it was

    @Test func neverMeansTheTitleDoesNotDrag() {
        #expect(place(.never, titled: true, split: true) == .none)
    }

    @Test func neverMeansNoHandle() {
        #expect(place(.never, split: true) == .none)
    }

    @Test func alwaysInASplitIsTheTitleOrTheHandle() {
        #expect(place(.always, titled: true, split: true) == .title)
        #expect(place(.always, split: true) == .handle)
    }

    // MARK: - Lent to the control room

    @Test func aLentPaneCannotBePickedUp() {
        #expect(place(.always, titled: true, lent: true, split: true) == .none)
    }

    @Test func theTerminalOnTheControlRoomsRightHandSideIsNeverPickedUp() {
        // Task 1566: `always` included. Its window is the control room's,
        // so `split` reads false -- but it is nothing either way.
        for setting in [Grip.Setting.always, .auto, .never] {
            for split in [false, true] {
                #expect(place(setting, controlRoom: true, split: split) == .none)
                #expect(place(setting, titled: true, controlRoom: true, split: split) == .none)
            }
        }
    }

    // MARK: - Click or drag

    @Test func underTheThresholdIsAClick() {
        let moved = Grip.isDrag(from: .zero, to: CGPoint(x: 2, y: 3), threshold: Grip.titleDragThreshold)
        #expect(!moved)
    }

    @Test func atTheThresholdIsADrag() {
        let moved = Grip.isDrag(from: .zero, to: CGPoint(x: 0, y: 4), threshold: Grip.titleDragThreshold)
        #expect(moved)
    }

    @Test func theThresholdIsADistanceNotPerAxis() {
        // 3 and 3 is under 4 on each axis and 4.24 apart.
        let moved = Grip.isDrag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 13, y: 7), threshold: Grip.titleDragThreshold)
        #expect(moved)
    }

    @Test func theTitleThresholdIsFourPoints() {
        #expect(Grip.titleDragThreshold == 4)
    }

    @Test func theHandleDragsOnTheFirstMovementAsItAlwaysHas() {
        let moved = Grip.isDrag(from: .zero, to: .zero, threshold: 0)
        #expect(moved)
    }
}
