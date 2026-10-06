import Foundation

/// Drawing one icon of the screenshot toolbar into a button cell
/// (`dev-docs/poltergeist/screenshot.md`, 9.8.5).
///
/// The icons are data (`ShotLook`, generated from
/// `src/input/screenshot-look.json`) and this is the one rule that turns
/// them into pixels. The Windows host has the same rule in
/// `windows/shots/src/icon.rs` and the generator has it in Python; the three
/// do the arithmetic in the same order, and each host's test is that its own
/// answer is the generator's (`ShotLook.Icon.ink`). That is what makes the
/// two toolbars one toolbar: CoreGraphics would stroke these paths well, and
/// differently from anything the other host has.
///
/// **The rule.** The 24-unit artboard is `points * scale` pixels on a side,
/// centred in the cell. A pixel's coverage by a part is the share of its
/// sixteen sample points -- a 4 x 4 grid -- that are inside the fill
/// (even-odd), or within half the stroke's width of the path, which is
/// exactly what a stroke with round caps and round joins is. A curve is
/// sixteen straight pieces. Parts are laid over one another in order.
///
/// What comes out is coverage, not colour: the caller tints it.
enum ShotIconRaster {
    /// A curve becomes this many straight pieces.
    private static let cubicSteps = 16
    /// A pixel is sampled on a grid this many points on a side.
    private static let grid = 4

    /// An icon's coverage: `cell * cell` bytes, top row first, 0 to 255.
    struct Mask: Equatable {
        var cell: Int
        var alpha: [UInt8]

        /// Where the ink is: the pixels at least half covered. All zeros
        /// when there are none.
        var ink: InkBox {
            var x0 = cell, y0 = cell, x1 = -1, y1 = -1, n = 0
            for y in 0..<cell {
                for x in 0..<cell where alpha[y * cell + x] >= 128 {
                    n += 1
                    x0 = min(x0, x)
                    x1 = max(x1, x)
                    y0 = min(y0, y)
                    y1 = max(y1, y)
                }
            }
            guard n > 0 else { return InkBox(x: 0, y: 0, w: 0, h: 0, count: 0) }
            return InkBox(x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1, count: n)
        }
    }

    /// The box of the pixels at least half covered, and how many there are.
    struct InkBox: Equatable {
        var x: Int
        var y: Int
        var w: Int
        var h: Int
        var count: Int
    }

    /// One straight piece of a path, in pixels.
    private struct Seg {
        var x1: Double
        var y1: Double
        var x2: Double
        var y2: Double
    }

    private typealias Sub = (points: [(x: Double, y: Double)], closed: Bool)

    /// Each subpath as points in pixels, and whether it was closed.
    private static func polylines(_ cmds: [ShotLook.Cmd], f: Double, off: Double) -> [Sub] {
        var subs: [Sub] = []
        for c in cmds {
            switch c {
            case let .move(x, y):
                subs.append((points: [(x: x * f + off, y: y * f + off)], closed: false))
            case let .line(x, y):
                guard !subs.isEmpty else { continue }
                subs[subs.count - 1].points.append((x: x * f + off, y: y * f + off))
            case let .cubic(ax, ay, bx, by, ex, ey):
                guard let start = subs.last?.points.last else { continue }
                let x0 = start.x, y0 = start.y
                let x1 = ax * f + off, y1 = ay * f + off
                let x2 = bx * f + off, y2 = by * f + off
                let x3 = ex * f + off, y3 = ey * f + off
                for s in 1...cubicSteps {
                    let t = Double(s) / Double(cubicSteps)
                    let u = 1.0 - t
                    let a = u * u * u
                    let b = 3.0 * u * u * t
                    let cc = 3.0 * u * t * t
                    let d = t * t * t
                    subs[subs.count - 1].points.append(
                        (x: a * x0 + b * x1 + cc * x2 + d * x3, y: a * y0 + b * y1 + cc * y2 + d * y3))
                }
            case .close:
                guard !subs.isEmpty else { continue }
                subs[subs.count - 1].closed = true
            }
        }
        return subs
    }

    /// The pieces of the subpaths; `closeAll` joins every end to its start,
    /// which is what a fill does with a path nobody closed.
    private static func segments(_ subs: [Sub], closeAll: Bool) -> [Seg] {
        var segs: [Seg] = []
        for sub in subs {
            let pts = sub.points
            if pts.count > 1 {
                for i in 0..<(pts.count - 1) {
                    segs.append(Seg(x1: pts[i].x, y1: pts[i].y, x2: pts[i + 1].x, y2: pts[i + 1].y))
                }
                if sub.closed || closeAll {
                    segs.append(Seg(x1: pts[pts.count - 1].x, y1: pts[pts.count - 1].y, x2: pts[0].x, y2: pts[0].y))
                }
            }
        }
        return segs
    }

    /// The square of the distance from a point to a piece.
    private static func dist2(_ px: Double, _ py: Double, _ seg: Seg) -> Double {
        let dx = seg.x2 - seg.x1, dy = seg.y2 - seg.y1
        let ll = dx * dx + dy * dy
        var t = 0.0
        if ll > 0.0 {
            t = ((px - seg.x1) * dx + (py - seg.y1) * dy) / ll
            if t < 0.0 {
                t = 0.0
            } else if t > 1.0 {
                t = 1.0
            }
        }
        let ex = seg.x1 + t * dx - px, ey = seg.y1 + t * dy - py
        return ex * ex + ey * ey
    }

    /// Even-odd: whether a ray to the right crosses the edges an odd number
    /// of times.
    private static func inside(_ px: Double, _ py: Double, _ edges: [Seg]) -> Bool {
        var odd = false
        for e in edges where (e.y1 > py) != (e.y2 > py) {
            if px < (e.x2 - e.x1) * (py - e.y1) / (e.y2 - e.y1) + e.x1 {
                odd.toggle()
            }
        }
        return odd
    }

    /// `icon` drawn into a cell `cell` pixels on a side, on a display scaled
    /// by `scale`. A cell smaller than the artboard cuts the icon off; it is
    /// not made to fit.
    static func mask(_ icon: ShotLook.Icon, cell: Int, scale: Double) -> Mask {
        let cell = max(cell, 0)
        let f = ShotLook.IconGrid.points * scale / ShotLook.IconGrid.artboard
        let off = (Double(cell) - ShotLook.IconGrid.points * scale) / 2.0
        var alpha = [Double](repeating: 0, count: cell * cell)
        for part in icon.parts {
            let subs = polylines(part.cmds, f: f, off: off)
            let fill = part.paint == .fill || part.paint == .fillAndStroke
            let stroke = part.paint == .stroke || part.paint == .fillAndStroke
            let half = stroke ? part.width * f / 2.0 : 0.0
            let half2 = half * half
            let outline = segments(subs, closeAll: false)
            let edges = fill ? segments(subs, closeAll: true) : []

            // Nothing of the part is outside its points' box grown by half
            // the stroke, so only those pixels are looked at.
            var l = Double.infinity, t = Double.infinity, r = -Double.infinity, b = -Double.infinity
            for sub in subs {
                for p in sub.points {
                    l = min(l, p.x)
                    t = min(t, p.y)
                    r = max(r, p.x)
                    b = max(b, p.y)
                }
            }
            guard l.isFinite else { continue }
            let xLo = max(Int((l - half).rounded(.down)), 0)
            let xHi = min(max(Int((r + half).rounded(.up)), 0), cell)
            let yLo = max(Int((t - half).rounded(.down)), 0)
            let yHi = min(max(Int((b + half).rounded(.up)), 0), cell)
            guard xLo < xHi, yLo < yHi else { continue }

            for py in yLo..<yHi {
                for px in xLo..<xHi {
                    var hits = 0
                    for j in 0..<grid {
                        for i in 0..<grid {
                            let sx = Double(px) + (Double(i) + 0.5) / Double(grid)
                            let sy = Double(py) + (Double(j) + 0.5) / Double(grid)
                            var on = fill && inside(sx, sy, edges)
                            if !on && stroke {
                                on = outline.contains { dist2(sx, sy, $0) <= half2 }
                            }
                            if on { hits += 1 }
                        }
                    }
                    if hits > 0 {
                        let cov = Double(hits) / Double(grid * grid) * part.opacity
                        let k = py * cell + px
                        alpha[k] += cov * (1.0 - alpha[k])
                    }
                }
            }
        }
        return Mask(cell: cell, alpha: alpha.map { UInt8(($0 * 255.0 + 0.5).rounded(.down)) })
    }
}
