import Foundation
import Testing
@testable import Ghostty

/// The program scrolling a long screenshot to the bottom (task 1196, 1;
/// specification 9.6).
struct ShotAutoScrollTests {
    private func run(_ steps: [ShotStitcher.Step], full: [Bool]? = nil) -> (stop: ShotAutoScroll.Stop?, at: Int) {
        var machine = ShotAutoScroll()
        for (i, step) in steps.enumerated() {
            if let stop = machine.record(step, full: full?[i] ?? false) { return (stop, i + 1) }
        }
        return (nil, steps.count)
    }

    @Test func theBottomIsAFewStepsRunningThatAddedNothing() {
        let still: [ShotStitcher.Step] = Array(repeating: .unchanged, count: 4)
        #expect(run([.first, .added(300), .added(300)] + still).stop == .bottom)
        #expect(run([.first, .added(300)] + still).at == 6, "the fourth of them")
        // Three are not enough: a page loading what it was scrolled to.
        #expect(run([.first, .added(300), .unchanged, .unchanged, .unchanged]).stop == nil)
        // Something new in the middle starts the count again.
        #expect(run([.added(300), .unchanged, .unchanged, .unchanged, .added(10), .unchanged, .unchanged, .unchanged]).stop == nil)
        // The rubber band at the end: it moves and comes back, and nothing is
        // added.
        #expect(run([.added(300), .back, .seen, .unchanged, .back]).stop == .bottom)
    }

    @Test func theHeightLimitEndsItWhicheverWayItIsSaid() {
        #expect(run([.added(300), .full]).stop == .limit)
        #expect(run([.added(300), .added(20)], full: [false, true]).stop == .limit)
    }

    @Test func aPageThatCannotBeFollowedEndsItAfterAFewFramesThatCouldNotBeJoined() {
        #expect(run([.added(300), .lost, .lost, .lost, .lost]).stop == .lost)
        #expect(run([.added(300), .lost, .lost, .lost]).stop == nil)
        #expect(run([.lost, .lost, .lost, .added(5), .lost, .lost, .lost]).stop == nil, "a joined frame clears it")
        #expect(run([.lost, .lost, .wrongSize, .moving]).stop == .lost)
        // It is not the bottom, and the bottom is not it.
        #expect(run([.lost, .unchanged, .lost, .unchanged, .lost, .unchanged, .lost]).stop == nil)
    }

    @Test func aStepIsAFifthLessThanAScreenAndInPointsNotPixels() {
        // The agent's: 80 per cent of the height, in four steps.
        #expect(ShotAutoScroll.step(height: 1000, scale: 1) == 200)
        #expect(ShotAutoScroll.step(height: 1000, scale: 2) == 100)
        #expect(ShotAutoScroll.step(height: 1680, scale: 2) == 168)
        #expect(ShotAutoScroll.step(height: 3, scale: 2) == 1, "never nothing")
        // So a frame overlaps the one before by a good deal more than the
        // stitcher asks for.
        for height in [300, 840, 1680, 2400] {
            let step = ShotAutoScroll.step(height: height, scale: 1)
            #expect(height - step >= height / 2)
        }
    }
}
