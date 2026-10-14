import Testing
import Foundation
@testable import Ghostty

/// Where a pane is picked up (task 1508): by its title when it has one, by
/// the handle when it has none, and `drag-handle` decides whether at all.
struct SurfaceDragGripTests {
    private typealias Grip = SurfaceDragGrip

    // MARK: - Title or handle

    @Test func aTitledPaneIsPickedUpByItsTitle() {
        let place = Grip.place(setting: .auto, titled: true, lent: false, fullscreen: false, split: true)
        #expect(place == .title)
    }

    @Test func aPaneWithNoTitleKeepsTheHandle() {
        let place = Grip.place(setting: .auto, titled: false, lent: false, fullscreen: false, split: false)
        #expect(place == .handle)
    }

    @Test func aTitledPaneAloneInItsTabIsPickedUpByItsTitle() {
        // A supervisor or a worker wears its frame even alone.
        let place = Grip.place(setting: .auto, titled: true, lent: false, fullscreen: false, split: false)
        #expect(place == .title)
    }

    // MARK: - drag-handle

    @Test func neverMeansTheTitleDoesNotDrag() {
        let place = Grip.place(setting: .never, titled: true, lent: false, fullscreen: false, split: true)
        #expect(place == .none)
    }

    @Test func neverMeansNoHandle() {
        let place = Grip.place(setting: .never, titled: false, lent: false, fullscreen: false, split: true)
        #expect(place == .none)
    }

    @Test func alwaysDragsByTheTitleEvenFullscreenAndAlone() {
        let place = Grip.place(setting: .always, titled: true, lent: false, fullscreen: true, split: false)
        #expect(place == .title)
    }

    @Test func alwaysKeepsTheHandleFullscreenAndAlone() {
        let place = Grip.place(setting: .always, titled: false, lent: false, fullscreen: true, split: false)
        #expect(place == .handle)
    }

    @Test func autoFullscreenAloneCannotBePickedUpByTheTitle() {
        let place = Grip.place(setting: .auto, titled: true, lent: false, fullscreen: true, split: false)
        #expect(place == .none)
    }

    @Test func autoFullscreenAloneHasNoHandle() {
        let place = Grip.place(setting: .auto, titled: false, lent: false, fullscreen: true, split: false)
        #expect(place == .none)
    }

    @Test func autoFullscreenSplitDragsByTheTitle() {
        let place = Grip.place(setting: .auto, titled: true, lent: false, fullscreen: true, split: true)
        #expect(place == .title)
    }

    // MARK: - Lent to the control room

    @Test func aLentPaneCannotBePickedUp() {
        let place = Grip.place(setting: .always, titled: true, lent: true, fullscreen: false, split: true)
        #expect(place == .none)
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
