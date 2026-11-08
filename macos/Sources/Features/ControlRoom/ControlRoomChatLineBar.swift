import CoreGraphics
import Foundation

/// **The index bar in line space** (task 3081, design §29.7 rules 4-5).
///
/// The bar's whole input is three integers: the line at the viewport's bottom
/// edge `b`, the loaded line count `total`, and how many lines fill one
/// viewport `fill`. The arithmetic here is static and free of any view, so the
/// thumb's place and size and the line a drag lands on can be held by a test
/// without a window on screen.
///
/// **The travel is the scrollable part, not the document.** The newest end
/// (`b == 1`) is the bottom of the track; the top is the clamp `b == maxLine`
/// = `total - fill + 1`, where the oldest line's top meets the viewport's top
/// edge. A document that fits on one screen has `scrollable == 0`: a full
/// thumb and no travel.
///
/// **One drawn tick stands for `stepLines` lines** once the lines outnumber
/// the marks the track can hold, which is what makes a long night's drag move
/// in jumps rather than a pixel at a time (the person's own words, §29).
enum ControlRoomChatLineBar {
    /// What the bar draws, and how far one drag step moves.
    struct Geometry: Equatable {
        var trackH: CGFloat
        var thumbH: CGFloat
        var thumbY: CGFloat
        /// Lines one drawn tick and one drag step stand for. At least 1.
        var stepLines: Int
        /// `max(0, total - fill)`: how many line steps separate the newest
        /// end from the clamp.
        var scrollableLines: Int
        /// The clamp: the largest `b` the model allows.
        var maxLine: Int
    }

    /// `b`, `total` and `fill` in; the thumb's place and size out. `minThumb`
    /// and `tickSpacing` are passed in so this file holds no look table.
    static func geometry(
        b: Int,
        totalLines: Int,
        fillLines: Int,
        trackH: CGFloat,
        minThumb: CGFloat,
        tickSpacing: CGFloat
    ) -> Geometry {
        let total = max(0, totalLines)
        let fill = min(max(0, fillLines), total)
        let scrollable = max(0, total - fill)
        let maxLine = scrollable + 1
        let bottomLine = min(max(1, b), maxLine)

        let thumbH: CGFloat
        if trackH <= 0 {
            thumbH = 0
        } else if total == 0 {
            thumbH = trackH
        } else {
            let ratio = CGFloat(fill) / CGFloat(total)
            thumbH = min(trackH, max(minThumb, trackH * ratio))
        }
        let travel = max(0, trackH - thumbH)
        // The thumb sits at the bottom at `b == 1` and at the top at the
        // clamp. `scrollable == 0` has nothing to travel and no position to
        // read, so the thumb stays at the track's start.
        let fractionFromTop: Double = scrollable == 0
            ? 0
            : Double(scrollable - (bottomLine - 1)) / Double(scrollable)
        let thumbY = travel * CGFloat(fractionFromTop)

        let spacing = max(1, tickSpacing)
        let capacity = max(1, Int(floor(trackH / spacing)))
        let stepLines = scrollable == 0
            ? 1
            : max(1, Int((Double(scrollable) / Double(capacity)).rounded(.up)))
        return Geometry(
            trackH: trackH,
            thumbH: thumbH,
            thumbY: thumbY,
            stepLines: stepLines,
            scrollableLines: scrollable,
            maxLine: maxLine
        )
    }

    /// **The line a drag position asks for.** `fraction` is the thumb's
    /// position on its travel: `0` is the top of the track (oldest), `1` the
    /// bottom (newest) -- the same value `ControlRoomChatIndexBar.dragFraction`
    /// returns. The answer is snapped to a drawn step and clamped to
    /// `[1, maxLine]`.
    static func seekLine(
        fraction: Double,
        totalLines: Int,
        fillLines: Int,
        stepLines: Int
    ) -> Int {
        let total = max(0, totalLines)
        let fill = min(max(0, fillLines), total)
        let scrollable = max(0, total - fill)
        guard scrollable > 0 else { return 1 }
        let steps = max(1, stepLines)
        let position = min(1, max(0, fraction))
        let raw = (1 - position) * Double(scrollable)
        let snapped = (raw / Double(steps)).rounded() * Double(steps)
        let offset = min(Double(scrollable), max(0, snapped))
        return 1 + Int(offset)
    }

    /// Where the drawn ticks go, as fractions of the track, the ends
    /// included. One tick per step; a single mark when there is no travel.
    static func tickFractions(
        totalLines: Int,
        fillLines: Int,
        stepLines: Int
    ) -> [Double] {
        let total = max(0, totalLines)
        let fill = min(max(0, fillLines), total)
        let scrollable = max(0, total - fill)
        guard scrollable > 0 else { return [0] }
        let steps = max(1, stepLines)
        let count = max(2, Int((Double(scrollable) / Double(steps)).rounded(.up)) + 1)
        return (0..<count).map { Double($0) / Double(count - 1) }
    }
}
