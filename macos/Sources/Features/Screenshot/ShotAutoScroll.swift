import Foundation

/// When a long screenshot that scrolls by itself is at the bottom, and when
/// it gives up (`dev-docs/poltergeist/screenshot.md`, 9.6).
///
/// The program scrolls the page a step at a time, takes a frame after each
/// and joins it (`ShotStitcher`). This is only the decision after each
/// frame, so that it can be tested without a page, a wheel or a screen.
///
/// **The bottom** is a run of steps that added nothing new: a page that is
/// at its end does not move, or moves and comes back (the rubber band), and
/// either way nothing is added. One such step is not the end -- a page
/// still loading the picture it was scrolled to is the same -- so it takes
/// `bottomAfter` in a row.
struct ShotAutoScroll {
    enum Stop: Equatable {
        /// Nothing new for `bottomAfter` steps running.
        case bottom
        /// The picture reached `ShotStitcher.maxHeight`.
        case limit
        /// `lostAfter` frames running could not be joined to the picture:
        /// the page is not being followed -- someone else scrolled it, or
        /// it jumps.
        case lost
    }

    static let bottomAfter = 4
    static let lostAfter = 4

    /// How far one step scrolls, in points: a fifth of the region's height
    /// less than a whole screen, so that every frame overlaps the one
    /// before by far more than the stitcher needs (`ShotAgent.Scroll`).
    static func step(height pixels: Int, scale: Double) -> Int {
        max(Int((Double(ShotAgent.Scroll.step(height: pixels)) / max(scale, 1)).rounded()), 1)
    }

    private(set) var still = 0
    private(set) var lostRun = 0
    private(set) var steps = 0
    /// How many rows were added by all the steps.
    private(set) var added = 0

    /// What happened to the frame taken after a step. Nil: scroll again.
    mutating func record(_ step: ShotStitcher.Step, full: Bool) -> Stop? {
        steps += 1
        switch step {
        case let .added(rows):
            still = 0
            lostRun = 0
            added += rows
        case .full:
            return .limit
        case .lost, .wrongSize, .moving:
            // A frame that could not be used: neither new nor the same.
            lostRun += 1
        case .unchanged, .seen, .back:
            still += 1
            lostRun = 0
        case .first:
            break
        }
        if full { return .limit }
        if lostRun >= Self.lostAfter { return .lost }
        if still >= Self.bottomAfter { return .bottom }
        return nil
    }
}
