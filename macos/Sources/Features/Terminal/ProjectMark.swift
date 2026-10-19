import Foundation

/// The mark of a page of a project on a window tab (task 1796): two
/// stacked pages outlined in the project's colour, and a glow of that
/// colour round them, as the user chose it (design 1796 v6, "S").
///
/// Both are worked out here, without a window, so the two hosts draw the
/// same thing from the same numbers (`ControlRoomLook.ProjectMark`):
///
/// - `shapes` are the pages, on the glyphs' 14-unit artboard: filled in
///   order, a level of 0 cutting a hole. The back page is drawn only where
///   the front one is not.
/// - `glow` is how much glow each pixel round the mark gets, 0 to 1. Only
///   this coverage is blurred; the colour is the project's everywhere. It is
///   laid on with screen -- `out = bg + (screen(bg, c) - bg) * a` -- which
///   never makes a pixel darker than what is under it. **Never a layer's
///   shadow**: a shadow is laid on with source-over, which darkens a light
///   tab, and follows the lines, which leaves no clear core -- the grey ring
///   the user saw in v5.
/// - `strength` is how strong a mark is in each state: a tab not in front
///   has its mark mixed toward the tab's ground, and its glow is that much
///   weaker.
///
/// The Windows host has the same as `project_mark.rs` in the control-room
/// crate; `tools/control-room-hosts-agree.py` holds the two to one table.
enum ProjectMark {
    private typealias PM = ControlRoomLook.ProjectMark

    enum State: String, CaseIterable {
        case rest, hover, selected
    }

    /// How much of the project's colour a mark in `state` has, 0 to 1.
    static func strength(_ state: State, dark: Bool) -> Double {
        switch (state, dark) {
        case (.selected, _): return PM.selected
        case (.hover, true): return PM.hoverDark
        case (.hover, false): return PM.hoverLight
        case (.rest, true): return PM.restDark
        case (.rest, false): return PM.restLight
        }
    }

    /// A rounded rectangle on the artboard, and how much colour it leaves.
    struct Shape: Equatable {
        let x: Double, y: Double, w: Double, h: Double, radius: Double
        let level: Double
    }

    /// The two pages, on the artboard (`ControlRoomLook.Status.artboard`
    /// units a side).
    static var shapes: [Shape] {
        func ring(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [Shape] {
            let l = PM.line
            return [
                Shape(x: x0, y: y0, w: x1 - x0, h: y1 - y0, radius: PM.pageRadius, level: 1),
                Shape(x: x0 + l, y: y0 + l, w: x1 - x0 - 2 * l, h: y1 - y0 - 2 * l, radius: max(PM.pageRadius - l, 0), level: 0),
            ]
        }
        let k = PM.frontClear
        // The back page stops short of the front one, so the glow shows
        // inside the front page too.
        let clear = Shape(
            x: PM.frontX0 - k, y: PM.frontY0 - k,
            w: PM.frontX1 - PM.frontX0 + 2 * k, h: PM.frontY1 - PM.frontY0 + 2 * k,
            radius: PM.pageRadius + k, level: 0)
        return ring(PM.backX0, PM.backY0, PM.backX1, PM.backY1) + [clear]
            + ring(PM.frontX0, PM.frontY0, PM.frontX1, PM.frontY1)
    }

    /// How much glow each pixel round a mark gets, in a square of `side`
    /// pixels whose top left is `reach` points above and left of the mark's.
    struct Glow: Equatable {
        let reach: Double
        let side: Int
        /// Row by row from the top, 0 to 1.
        let a: [Double]

        func at(_ x: Int, _ y: Int) -> Double {
            x >= 0 && y >= 0 && x < side && y < side ? a[y * side + x] : 0
        }

        /// Every pixel's coverage added up: one number to compare two hosts
        /// by.
        var total: Double { a.reduce(0, +) }
    }

    /// Points round the mark's square that the glow can reach: its circle
    /// and three of its blur's sigmas, whole.
    static var reach: Double {
        (PM.glowRadius + 3 * PM.glowBlur - ControlRoomLook.Status.artboard / 2).rounded(.up)
    }

    /// The glow of a mark drawn `scale` pixels a point, at `strength`.
    static func glow(scale: Double, strength: Double) -> Glow {
        let reach = Self.reach
        let artboard = ControlRoomLook.Status.artboard
        let side = Int(((artboard + 2 * reach) * scale).rounded(.up))
        func pt(_ i: Int) -> Double { (Double(i) + 0.5) / scale - reach }
        let mid = artboard / 2
        let (gap, cr) = (PM.coreGap, PM.coreRadius)
        let half = mid + gap

        var disc = [Double](repeating: 0, count: side * side)
        var core = [Double](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let (px, py) = (pt(x), pt(y))
                let d = ((px - mid) * (px - mid) + (py - mid) * (py - mid)).squareRoot()
                disc[y * side + x] = min(max((PM.glowRadius - d) * scale + 0.5, 0), 1)
                // The signed distance to the core's rounded square.
                let qx = abs(px - mid) - (half - cr)
                let qy = abs(py - mid) - (half - cr)
                let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
                let sd = outside + min(max(qx, qy), 0) - cr
                core[y * side + x] = min(max(0.5 - sd * scale, 0), 1)
            }
        }
        let blurredDisc = blur(disc, side: side, sigma: PM.glowBlur * scale)
        let blurredCore = blur(core, side: side, sigma: PM.coreBlur * scale)
        let k = PM.glowStrength * strength
        let a = zip(blurredDisc, blurredCore).map { d, c in min(max(d * k * (1 - c * (1 - PM.coreKeep)), 0), 1) }
        return Glow(reach: reach, side: side, a: a)
    }

    /// A Gaussian blur of `sigma` pixels, across and then down; what is past
    /// the edge counts as 0. The same sums in the same order as
    /// `project_mark.rs`, so the two hosts' totals agree.
    private static func blur(_ v: [Double], side: Int, sigma: Double) -> [Double] {
        guard sigma > 0 else { return v }
        let r = Int((3 * sigma).rounded(.up))
        var kernel = (-r...r).map { i in exp(-Double(i * i) / (2 * sigma * sigma)) }
        let sum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / sum }
        func pass(_ src: [Double], across: Bool) -> [Double] {
            var out = [Double](repeating: 0, count: side * side)
            for y in 0..<side {
                for x in 0..<side {
                    var acc = 0.0
                    for (j, w) in kernel.enumerated() {
                        let o = j - r
                        let (sx, sy) = across ? (x + o, y) : (x, y + o)
                        if sx >= 0, sy >= 0, sx < side, sy < side {
                            acc += w * src[sy * side + sx]
                        }
                    }
                    out[y * side + x] = acc
                }
            }
            return out
        }
        return pass(pass(v, across: true), across: false)
    }
}
